"""a3m / aligned-FASTA reading. Validation and the panel summary ONLY.

What this module returns is NEVER what gets folded. The stored alignment is the
file's own bytes, and boltz-mlx parses those itself; this exists so that a
malformed alignment, or one that does not match the structure it is attached to,
is caught at load time instead of after a half-gigabyte weight download and
minutes of featurization.

Which is exactly why the counting rules below are boltz-mlx's own -- see
`MSAAlignment.a3m()` in `Sources/BoltzMLX/Featurize/MSAAlignment.swift` -- rather
than a reasonable reading of the a3m spec. A summary that disagrees with the
featurizer is worse than no summary, because it makes the early check pass on
something the late check will refuse:

- blank lines, and lines starting with '#', are skipped; a line starting with '>'
  is a header and is skipped too.
- a residue is an INSERTION, occupying no column, when it is lowercase. Everything
  else is a column -- **including '.'**, which HHsuite writes as insert-column
  padding and which boltz-mlx tokenizes as UNK instead of skipping. A '.' therefore
  shifts that row's column count, so it is counted here and reported rather than
  quietly tolerated.
- rows are DEDUPLICATED, on the gap-stripped and upper-cased sequence, before any
  column count is compared. So "depth" means depth after dedup, which is what the
  featurizer will see -- and note the key strips gaps, so two rows with the same
  residues in different columns collide.
- every row must have as many columns as row 0, which is the query.

The one thing it does NOT reproduce is the `maximumSequences` cut-off: truncation
is a per-prediction knob (#297), not a property of the file, so the whole file is
summarized here.
"""
from .errors import MSAInputError

#: Deletes ASCII a-z, which is what makes the column count a C-speed operation
#: instead of a per-character Python loop -- a 16384-row alignment is tens of
#: millions of characters and this runs on the main thread.
#:
#: ASCII only, deliberately: `str.islower()` is Unicode-aware and Swift's
#: `Character.isLowercase` agrees with it, so a non-ASCII lower-case letter would
#: be counted differently by the two. No a3m contains one; if one ever does, this
#: over-counts columns and the row-length check reports it instead of silently
#: disagreeing with the featurizer.
_DELETE_LOWERCASE = {c: None for c in range(ord('a'), ord('z') + 1)}


def summarize(text):
    """Depth, columns and query of an alignment, or raise MSAInputError.

    Returns a dict with:
        depth       rows after dedup, the query included
        columns     aligned length of the query row
        query       the query, ungapped -- what a target's sequence must equal
        duplicates  rows dropped as duplicates
        dots        '.' characters seen, which are columns here (see the module docstring)
    """
    depth = 0
    columns = 0
    duplicates = 0
    dots = 0
    query = ''
    seen = set()

    for line in text.split('\n'):
        line = line.strip()
        if not line or line[0] == '#' or line[0] == '>':
            continue

        key = line.replace('-', '').upper()
        if key in seen:
            duplicates += 1
            continue
        seen.add(key)

        row = line.translate(_DELETE_LOWERCASE)
        dots += row.count('.')
        if depth == 0:
            columns = len(row)
            query = row.replace('-', '')
        elif len(row) != columns:
            # Same shape as boltz-mlx's rowLengthMismatch, and 1-based because the
            # user is going to go looking for the line in a text editor. Reported
            # against the query, which is what the featurizer compares against too.
            raise MSAInputError(
                'row %d has %d aligned columns, but the query has %d; every row of an'
                ' alignment must line up with the query'
                % (depth + 1, len(row), columns))
        depth += 1

    if depth == 0:
        raise MSAInputError('no sequences found; expected an a3m or aligned FASTA')
    if not query:
        raise MSAInputError('the query (the first sequence) is empty')

    return {'depth': depth, 'columns': columns, 'query': query,
            'duplicates': duplicates, 'dots': dots}


def read(path):
    """Alignment text from `path`, transparently un-gzipping it.

    Returns the text EXACTLY as stored -- no normalisation, no re-wrapping, no
    line-ending translation. Whatever comes back here is what gets kept and what
    the featurizer eventually parses, so touching it would make boltz-mlx's parity
    claim a statement about a file that no longer exists.

    Gzip is handled because alignments arrive compressed far more often than not:
    a deep a3m is tens of megabytes of extremely compressible text, and ColabFold
    hands back a tarball of them (#298).
    """
    import gzip
    try:
        with open(path, 'rb') as handle:
            raw = handle.read()
    except (IOError, OSError) as exc:
        raise MSAInputError('cannot read %s: %s' % (path, exc))
    if raw[:2] == b'\x1f\x8b':
        try:
            raw = gzip.decompress(raw)
        except (IOError, OSError, EOFError, ValueError) as exc:
            raise MSAInputError('%s looks gzipped but does not decompress: %s'
                                % (path, exc))
    if not raw.strip():
        raise MSAInputError('%s is empty' % path)
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise MSAInputError(
            '%s is not text: %s. An alignment must be an a3m or aligned FASTA;'
            ' this looks like a binary file.' % (path, exc))
