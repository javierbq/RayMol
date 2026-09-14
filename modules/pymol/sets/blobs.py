"""Bytes in and out of the `blobs` table: chain CIFs and metric arrays.

Content-addressed by the sha256 of the UNCOMPRESSED bytes, so the same chain arriving
from a .pdb import and from a `get_cifstr` round trip matches whether or not the two
gzip identically. The gzip header's mtime is pinned to zero for the same reason from
the other side: identical text gives identical stored bytes, which keeps `VACUUM INTO`
copies byte-comparable.

Arrays are stored raw, not compressed: float32 confidence tracks do not compress
usefully and a PAE matrix is read back whole for a plot, where a decode step per open
would show. The saving for PAE comes from `u8q` instead -- 0.125 A steps over 0-31.75
lose nothing a plot can show and are a quarter of f32.

Standard library only (gzip, hashlib, struct, array): numpy is not in the app bundle.
"""
import array
import gzip
import hashlib
import struct
import sys

from .errors import SetInputError

#: gzip level for CIF text. The MSA store uses the same for an a3m; -9 buys a few per
#: cent for several times the CPU on a 1000-file import.
CIF_GZIP_LEVEL = 6

#: The u8q byte that means "absent". Values quantise into 0..254.
U8Q_ABSENT = 255
_U8Q_STEPS = 254

_NAN = float('nan')
_F32_MIN = -3.4028234663852886e38
_F32_MAX = 3.4028234663852886e38


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def encode_cif(text):
    """(hash, gz_bytes, size) for one chain's mmCIF text."""
    if not isinstance(text, str):
        raise SetInputError('a chain CIF must be text, got %s' % type(text).__name__)
    raw = text.encode('utf-8')
    return sha256_hex(raw), gzip.compress(raw, CIF_GZIP_LEVEL, mtime=0), len(raw)


def decode_cif(gz_bytes):
    try:
        return gzip.decompress(gz_bytes).decode('utf-8')
    except (OSError, EOFError, UnicodeDecodeError) as exc:
        raise SetInputError('corrupt CIF blob: %s' % exc)


def _f32_array(values):
    """An array('f') of `values` with None as NaN, or raise on a non-number."""
    out = array.array('f')
    try:
        out.extend(_NAN if v is None else float(v) for v in values)
    except (TypeError, ValueError) as exc:
        raise SetInputError('array values must be numbers or None: %s' % exc)
    except OverflowError:
        raise SetInputError('array value does not fit a float32')
    return out


def encode_f32(values):
    """Little-endian float32 bytes; None becomes NaN."""
    out = _f32_array(values)
    if sys.byteorder == 'big':
        out.byteswap()
    return out.tobytes()


def decode_f32(blob, n):
    """`n` floats from little-endian float32 bytes; NaN becomes None."""
    if len(blob) != 4 * n:
        raise SetInputError('f32 blob holds %d bytes, expected %d for %d values'
                            % (len(blob), 4 * n, n))
    out = array.array('f')
    out.frombytes(blob)
    if sys.byteorder == 'big':
        out.byteswap()
    return [None if v != v else v for v in out]


def encode_u8q(values, lo, hi):
    """(bytes, scale, offset) quantising `values` into 0..254 over [lo, hi].

    value = offset + scale * byte. Out-of-range values are clamped rather than refused:
    a PAE of 31.8 against a declared 31.75 ceiling is the tool's rounding, not a bad
    input, and the plot cannot show the difference. None is stored as 255.
    """
    lo = float(lo)
    hi = float(hi)
    if hi < lo:
        raise SetInputError('u8q range is inverted: lo=%r > hi=%r' % (lo, hi))
    scale = (hi - lo) / _U8Q_STEPS if hi > lo else 1.0
    out = bytearray()
    try:
        for v in values:
            if v is None:
                out.append(U8Q_ABSENT)
                continue
            v = float(v)
            if v != v:
                out.append(U8Q_ABSENT)
                continue
            q = int(round((min(max(v, lo), hi) - lo) / scale))
            out.append(min(q, _U8Q_STEPS))
    except (TypeError, ValueError) as exc:
        raise SetInputError('array values must be numbers or None: %s' % exc)
    return bytes(out), scale, lo


def decode_u8q(blob, scale, offset):
    scale = float(scale)
    offset = float(offset)
    return [None if b == U8Q_ABSENT else offset + scale * b for b in blob]


def choose_encoding(scope, spec):
    """'u8q' for a pair array whose spec bounds its domain, else 'f32'.

    `spec` may be a MetricSpec, a dict with `lo`/`hi`, or None. Residue arrays stay
    f32: they are one row, not a matrix, so the 4x does not pay for the rounding.
    """
    if scope == 'pair' and spec is not None:
        if isinstance(spec, dict):
            lo, hi = spec.get('lo'), spec.get('hi')
        else:
            lo, hi = getattr(spec, 'lo', None), getattr(spec, 'hi', None)
        if lo is not None and hi is not None:
            return 'u8q'
    return 'f32'


def pack_header(n):
    """Little-endian uint32 count, for callers that want a self-describing blob.

    The store does not use it -- the length comes from `index_json` -- but an exporter
    writing arrays to a file with no index beside them can.
    """
    return struct.pack('<I', n)
