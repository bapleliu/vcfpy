"""Cython-based wrapper around htslib, enabling vcfpy to use faster I/O

Based on code from cyvcf2.
"""

from __future__ import print_function

# Python imports

import locale
import os
import sys

from vcfpy import OrderedDict
from vcfpy.header import Header, build_header_parsers, HeaderLine, SamplesInfos
from vcfpy.warn_utils import WarningHelper

# Cython imports

from libc cimport stdlib
from cython cimport view

#: Encoding to use for byte/string conversion
ENC = locale.getpreferredencoding()

# Overcome lack of __file__ in cython
import inspect
if not hasattr(sys.modules[__name__], '__file__'):
    __file__ = inspect.getfile(inspect.currentframe())


cdef to_bytes(s, enc=ENC):
    """Helper function for ensuring ``bytes`` type"""
    if not isinstance(s, bytes):
        return s.encode(enc)
    return s


cdef from_bytes(s):
    """Helper function for ensuring ``string`` type"""
    if isinstance(s, bytes):
        try:
            return s.decode(ENC)
        except UnicodeDecodeError:
            return s.decode('utf8')
    return s


cdef class _ReaderImpl(object):
    """Wrapper for read-only VCFFile objects

    Implements public, non-static interface of vcfpy.reader.Reader
    """

    cdef readonly str path
    cdef readonly str tabix_path
    cdef readonly bint lazy
    cdef readonly int threads
    cdef VCFFile _vcf_file
    cdef readonly object header

    def __init__(self, fname, tabix_path=None, lazy=False, samples=None, threads=None):
        # Interpret special file name '-'
        if fname == b'-' or fname == '-':
            fname = b'/dev/stdin'
        fname = to_bytes(fname)
        # Assign properties
        self.path = from_bytes(fname)
        self.tabix_path = from_bytes(tabix_path)
        self.lazy = lazy
        self.threads = threads or 1
        # Construct internal VCFFile
        self._vcf_file = VCFFile(fname, b'rb', lazy, samples, threads)
        # Load header into vcfpy.header.Header object
        self.header = self._vcf_file.load_header()

    def __iter__(self):
        return self._vcf_file

    # TODO: add orig_samples property that returns regardless of limiting to set of samples

    property samples:
        """SamplesInfos object with sample information"""
        def __get__(self):
            return self._vcf_file.samples


cdef inline HeaderLineFactory newHeaderLineFactory(bcf_hdr_t * hdr, object warning_helper):
    cdef HeaderLineFactory result = HeaderLineFactory.__init__(HeaderLineFactory)
    result.hdr = hdr
    result.warning_helper = warning_helper
    result.parsers = build_header_parsers()
    return result


cdef class HeaderLineFactory:
    """Helper class for converting from ``bcf_hdr_t`` entries to ``vcfpy.header.Header`` objects

    Constructed with ``newHeaderLineFactory()``
    """

    cdef bcf_hdr_t * hdr
    cdef object warning_helper
    cdef dict parsers

    cdef object build(self, bcf_hrec_t * hrec):
        if hrec.type == BCF_HL_GEN:
            return self._build_generic(hrec)
        else:
            return self._build_parsed(hrec)

    cdef object _build_parsed(self, bcf_hrec_t * hrec):
        mapping = OrderedDict(
            (from_bytes(hrec.keys[i]), from_bytes(hrec.vals[i]))
            for i in range(hrec.nkeys))
        mapping_s = ','.join('%s=%s' % (k, repr(v)) for k, v in mapping.items())
        key = from_bytes(hrec.key)
        parser = self.parsers.get(key, self.parsers['__default__'])
        return parser.parse_key_value(key, mapping_s)

    cdef object _build_generic(self, bcf_hrec_t * hrec):
        """Build "generic" header line, just key/value mapping, e.g., used for storing command lines"""
        return HeaderLine(from_bytes(hrec.key), from_bytes(hrec.value))


cdef class VCFFile(object):
    """Representation of BCF/VCF file"""
    cdef htsFile *hts
    cdef bcf_hdr_t *hdr
    cdef tbx_t *idx
    cdef hts_idx_t *hidx
    cdef int n_samples
    cdef int PASS
    cdef bytes fname
    cdef bint lazy
    #: vcfpy.headre.SamplesInfo object
    cdef public object samples
    cdef list _seqnames
    # holds a lookup of format field -> type.
    cdef dict format_types

    def __init__(self, fname, mode='r', lazy=False, samples=None, threads=None):
        # Open file and balk out in the case of errors
        if not os.path.exists(fname):
            raise Exception("bad path: %s" % fname)
        fname, mode = to_bytes(fname), to_bytes(mode)
        self.hts = hts_open(fname, mode)
        if self.hts == NULL:
            raise IOError("Error opening %s" % fname)
        if self.hts.format.format != vcf and self.hts.format.format != bcf:
            raise IOError("%s if not valid bcf or vcf" % fname)

        # Read BCF header
        cdef bcf_hdr_t *hdr
        hdr = self.hdr = bcf_hdr_read(self.hts)
        # Set samples to be pulled out, if only limited to a sub set
        # TODO: pure python implementation is lacking this
        if samples is not None:
            self.set_samples(samples)
        self.n_samples = bcf_hdr_nsamples(self.hdr)
        # Extract SamplesInfos from header, possibly after limiting to subset
        if samples is None:
            samples = self.get_samples()
        self.samples = SamplesInfos(samples)
        # Initialize members
        self.PASS = -1
        self.fname = to_bytes(fname)
        self.lazy = lazy
        self._seqnames = []
        self.format_types = {}
        if threads is not None:
            self.set_threads(threads)

    def set_threads(self, int n):
        """Sets number of reader/writer threads in this object's htsfile"""
        v = hts_set_threads(self.hts, n)
        if v < 0:
            raise Exception("error setting number of threads: %d" % v)

    def set_samples(self, samples):
        """Set the samples to be pulled from the VCF; this must be called before any iteration.
        Parameters
        ----------
        samples: list
            list of samples to extract.
        """
        if samples is None:
            samples = "-".encode()
        if isinstance(samples, list):
            samples = to_bytes(",".join(samples))
        else:
            samples = to_bytes(samples)

        ret = bcf_hdr_set_samples(self.hdr, <const char *>samples, 0)
        assert ret >= 0, ("error setting samples", ret)
        if ret != 0 and samples != "-":
            s = samples.split(",")
            if ret < len(s):
                # TODO: update name, makes no sense here
                sys.stderr.write("warning: not all samples in PED found in VCF\n")

    def get_samples(self):
        """Return list of samples from file
        """
        return [from_bytes(self.hdr.samples[i])
                for i in range(0, bcf_hdr_nsamples(self.hdr))]

    cdef object load_header(self):
        """Load header information into vcfpy.header.Header"""
        wh = WarningHelper()
        cdef HeaderLineFactory factory = newHeaderLineFactory(self.hdr, wh)
        factory.build(self.hdr.hrec[0])
        lines = [factory.build(self.hdr.hrec[i]) for i in range(self.hdr.nhrec)]
        return Header(lines, self.samples, wh)

    def __next__(self):
        cdef bcf1_t *b = bcf_init()
        cdef int ret
        with nogil:
            ret = bcf_read(self.hts, self.hdr, b)
        if ret >= 0:
            return newRecord(b, self)
        else:
            bcf_destroy(b)
        raise StopIteration

    def __dealloc__(self):
        """Deallocation for VCFFile

        - deallocate header struct
        - close HTS file
        - free any index-related memory
        """
        if self.hdr != NULL:
            bcf_hdr_destroy(self.hdr)
            self.hdr = NULL
        if self.hts != NULL:
            hts_close(self.hts)
            self.hts = NULL
        if self.idx != NULL:
            tbx_destroy(self.idx)
        if self.hidx != NULL:
            hts_idx_destroy(self.hidx)


cdef class Record(object):
    #: Pointer to the C struct with the BCF record
    cdef bcf1_t *b
    #: Reference to the owning VCFFile
    cdef VCFFile vcf

    def __init__(self, *args, **kwargs):
        raise TypeError("Variant object cannot be instantiated directly.")

    def __cinit__(self):
        self.b = NULL

    def __repr__(self):
        return "Record(%s:%d %s/%s)" % (self.CHROM, self.POS, self.REF, ",".join(self.ALT))

    def __str__(self):
        cdef kstring_t s
        s.s, s.l, s.m = NULL, 0, 0
        vcf_format(self.vcf.hdr, self.b, &s)
        try:
            return s.s[:s.l].decode()
        finally:
            stdlib.free(s.s)

    def __dealloc__(self):
        """Perform deallocation

        - free associated BCF record
        - free all allocated buffers
        """
        if self.b is not NULL:
            bcf_destroy(self.b)
            self.b = NULL

    property CHROM:
        """Return string with the chromosome name"""
        def __get__(self):
            return bcf_hdr_id2name(self.vcf.hdr, self.b.rid).decode()

    property POS:
        """``int`` with 1-based start position of variant"""
        def __get__(self):
            return self.b.pos + 1

    property ID:
        """Return value of ID from the VCF field"""
        def __get__(self):
            cdef char *id = self.b.d.id
            if id == b'.':
                return []
            else:
                return id.decode().split(';')

    property REF:
        """Return ``str`` with reference allele"""
        def __get__(self):
            return self.b.d.allele[0].decode()

    property ALT:
        """Alternative alleles, list of ``str`` for now"""
        def __get__(self):
            cdef int i
            return [self.b.d.allele[i].decode() for i in range(1, self.b.n_allele)]

    property QUAL:
        """The quality value, can be ``None``"""
        def __get__(self):
            cdef float q = self.b.qual
            if bcf_float_is_missing(q):
                return None
            else:
                return q

    property FILTER:
        """Value of the FILTER field from VCF, as list of strings"""
        def __get__(self):
            cdef int i
            cdef int n = self.b.d.n_flt
            if n == 1:
                if self.vcf.PASS != -1:
                    if self.b.d.flt[0] == self.vcf.PASS:
                        return []
                else:
                    v = bcf_hdr_int2id(self.vcf.hdr, BCF_DT_ID, self.b.d.flt[0])
                    if v == b'PASS':
                        self.vcf.PASS = self.b.d.flt[0]
                        return ['PASS']
                    return v
            if n == 0:
                return []
            return b';'.join(bcf_hdr_int2id(self.vcf.hdr, BCF_DT_ID, self.b.d.flt[i]) for i in range(n))


cdef inline Record newRecord(bcf1_t *b, VCFFile vcf):
    """Construct new Record object in ``bcf1_t`` ``*b`` and with ``VCFFile`` ``vcf``
    """
    cdef Record rec = Record.__new__(Record)
    rec.b = b
    if not vcf.lazy:
        with nogil:
            bcf_unpack(rec.b, 15)
    else:
        with nogil:
            bcf_unpack(rec.b, 1|2|4)
    rec.vcf = vcf
    return rec

