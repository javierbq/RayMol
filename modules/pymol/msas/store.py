"""The named alignment store, and its .pse round trip.

An alignment is expensive -- minutes of search, or a file someone curated by hand --
and it belongs to a *sequence*, not to a run. So it is kept here under a name, the
way a structure is kept under an object name, and it survives a session save.

WHY THIS IS NOT A C++ OBJECT. An alignment has no geometry, so every one of
`CObject`'s virtuals (extent, matrix, render, state count) would be a stub, and a row
in the object list that accepts `show cartoon` and does nothing is a worse lie than a
section that plainly is not a molecule. The precedent is the one raymol_notes,
raymol_scenes and raymol_scene_anim already set: non-geometric state, carried through
a .pse by a session task, surfaced by the panel poll.

Process-wide, like `predicting._JOBS` and `raymol_notes._payload`. A second pymol2
instance shares this store; that is a limitation these modules share, not a decision
taken here.
"""
import base64
import gzip
import json

from .errors import MSAInputError, MSANameConflict, MSANotFound

#: Extra key in the .pse session dictionary. Older PyMOL ignores what it does not know,
#: so a session written with alignments still opens in upstream PyMOL -- without them.
SESSION_KEY = 'raymol_msa'

#: Bumped only for a change the reader cannot absorb. A reader that meets a version it
#: does not know skips the payload rather than guessing at it.
SESSION_VERSION = 1

#: Characters that cannot appear in a name. ',' and whitespace because the command
#: parser splits on them; '/' because `predict ..., msa=aln_a/aln_b` will separate
#: per-chain alignments with it (#297), and a name containing one could not be
#: addressed there at all.
_FORBIDDEN = set('/,\'"()[]{}') | set(' \t\r\n')

#: name -> MSA. Insertion-ordered, which is the order the panel and msa_list show.
_MSAS = {}


class MSA:
    """One named alignment.

    `a3m` is the file's text VERBATIM. Never re-serialize it from a parse: boltz-mlx's
    parser deliberately reproduces two upstream bugs and reads insertions as lowercase
    runs, so the bytes that reach it have to be the bytes that were loaded, or its
    bitwise-parity claim is a statement about a file that no longer exists.

    `query`, `depth` and `columns` are the summary of those bytes, computed once at
    load time -- the panel polls every 500 ms on the main thread and must never re-read
    or re-parse an alignment to draw a row.

    `target`/`chain` are a name and a chain id, resolved when they are USED, not held as
    a reference: the object may not exist yet, may be renamed, or may be deleted, and an
    alignment surviving its structure is normal rather than an error.
    """

    __slots__ = ('name', 'a3m', 'query', 'depth', 'columns', 'target', 'chain', 'source')

    def __init__(self, name, a3m, query, depth, columns,
                 target='', chain='', source=None):
        self.name = name
        self.a3m = a3m
        self.query = query
        self.depth = int(depth)
        self.columns = int(columns)
        self.target = target or ''
        self.chain = chain or ''
        self.source = dict(source or {})

    def summary(self):
        """The cheap description: what the panel and msa_list show. No a3m bytes."""
        return {'name': self.name, 'depth': self.depth, 'columns': self.columns,
                'residues': len(self.query), 'target': self.target,
                'chain': self.chain}

    def __repr__(self):
        return 'MSA(%r, depth=%d, columns=%d, target=%r)' % (
            self.name, self.depth, self.columns, self.target)


def check_name(name):
    """Return `name` if it can be addressed from the command line, else raise."""
    name = str(name or '').strip()
    if not name:
        raise MSAInputError('an alignment needs a name')
    bad = sorted(set(name) & _FORBIDDEN)
    if bad:
        raise MSAInputError(
            'invalid name %r: %s cannot appear in an alignment name'
            % (name, ', '.join(repr(c) for c in bad)))
    return name


def unique_name(stem):
    """`stem`, or the first free `stem_2`, `stem_3`, ... Never raises on collision."""
    stem = check_name(stem)
    if stem not in _MSAS:
        return stem
    index = 2
    while '%s_%d' % (stem, index) in _MSAS:
        index += 1
    return '%s_%d' % (stem, index)


def add(msa):
    """Store `msa`. A name already in use is an error, never a silent overwrite."""
    check_name(msa.name)
    if msa.name in _MSAS:
        raise MSANameConflict(
            'an alignment named %r already exists; delete it or load under another'
            ' name' % msa.name)
    _MSAS[msa.name] = msa
    return msa


def get(name):
    """The MSA stored under `name`."""
    try:
        return _MSAS[name]
    except KeyError:
        raise MSANotFound(
            'no alignment named %r; loaded: %s'
            % (name, ', '.join(names()) or '(none)'))


def have(name):
    return name in _MSAS


def names():
    """Stored names, in load order."""
    return list(_MSAS)


def delete(name):
    """Forget one alignment, or every one if `name` is '*' or 'all'."""
    if name in ('*', 'all'):
        count = len(_MSAS)
        _MSAS.clear()
        return count
    get(name)
    del _MSAS[name]
    return 1


def rename(old, new):
    new = check_name(new)
    msa = get(old)
    if new == old:
        return msa
    if new in _MSAS:
        raise MSANameConflict('an alignment named %r already exists' % new)
    # Rebuilt rather than reassigned in place, so the store keeps load order instead
    # of moving the renamed alignment to the end of the panel's list.
    msa.name = new
    for key in list(_MSAS):
        value = _MSAS.pop(key)
        _MSAS[new if key == old else key] = value
    return msa


def attach(name, target, chain=''):
    msa = get(name)
    msa.target = str(target or '')
    msa.chain = str(chain or '')
    return msa


def detach(name):
    msa = get(name)
    msa.target = ''
    msa.chain = ''
    return msa


def clear():
    """Drop everything. Called when a session is replaced, not when one is saved."""
    _MSAS.clear()


def panel_summary():
    """name -> summary dict, for the object panel's 500 ms poll.

    O(number of alignments), touching only scalars that were computed at load time.
    Never reads a file and never re-parses an a3m: `poll_panel` runs on the main
    thread and is a measured hot spot (PR #270).
    """
    return {name: msa.summary() for name, msa in _MSAS.items()}


# -- Session round trip --------------------------------------------------------
#
# The a3m goes in gzipped and base64'd. raymol_notes base64s its image assets for the
# same reason: the barnase alignment boltz-mlx tests against is depth 6628 x 199
# columns, ~1.3 MB of text, and boltz-mlx admits 16384 rows -- a couple of those stored
# raw would dominate a .pse. Alignments compress by roughly an order of magnitude.


def _encode(text):
    return base64.b64encode(gzip.compress(text.encode('utf-8'), 6)).decode('ascii')


def _decode(blob):
    return gzip.decompress(base64.b64decode(blob)).decode('utf-8')


def session_save(session, **_kwargs):
    """Session-save task: write the alignments into the .pse being written.

    The key is omitted entirely when nothing is loaded, so a session from a user who
    never touched an alignment is byte-for-byte what it was before this existed.
    """
    if not _MSAS:
        return 1
    entries = []
    for msa in _MSAS.values():
        entries.append({
            'name': msa.name,
            'a3m_gz_b64': _encode(msa.a3m),
            'query': msa.query,
            'depth': msa.depth,
            'columns': msa.columns,
            'target': msa.target,
            'chain': msa.chain,
            # JSON rather than the object, so a future field cannot make a .pse
            # unpicklable for an older RayMol.
            'source': json.dumps(msa.source, sort_keys=True),
        })
    session[SESSION_KEY] = {'version': SESSION_VERSION, 'alignments': entries}
    return 1


def session_restore(session, **_kwargs):
    """Session-restore task: replace the store with what the session carries.

    A session WITHOUT the key clears the store. That is the point: opening a session
    with no alignments must not leave the previous session's lying around, attached to
    objects that are gone.

    Tolerant by construction -- a malformed entry is skipped with a warning rather than
    raised, because a restore task that throws takes the whole session load with it.
    """
    clear()
    payload = session.get(SESSION_KEY)
    if not isinstance(payload, dict):
        return 1
    if int(payload.get('version', 0)) > SESSION_VERSION:
        print(' msa: session carries alignment format v%s, this build reads v%d;'
              ' alignments not restored'
              % (payload.get('version'), SESSION_VERSION))
        return 1
    for entry in payload.get('alignments') or []:
        try:
            source = entry.get('source') or '{}'
            _MSAS[entry['name']] = MSA(
                entry['name'], _decode(entry['a3m_gz_b64']), entry['query'],
                entry['depth'], entry['columns'],
                entry.get('target', ''), entry.get('chain', ''),
                json.loads(source) if isinstance(source, str) else source)
        except Exception as exc:
            print(' msa: could not restore alignment %r from the session (%s)'
                  % (entry.get('name', '?') if isinstance(entry, dict) else '?', exc))
    return 1
