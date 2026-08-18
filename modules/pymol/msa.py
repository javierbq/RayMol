"""Multiple-sequence alignments: cmd.load_msa and friends.

Thin by design. Argument marshalling and session interaction only; the store, the
reader and the errors live in pymol.msas.

Every function ends its signature with _self=cmd. That is load-bearing:
pymol2/cmd2.py binds _self only when it appears in the argspec, and otherwise
copies the function verbatim so it silently drives the GLOBAL instance.
"""
import os
import sys

from . import colorprinting
from .msas import colabfold, parse, searching, store
from .msas.errors import (MSAError, MSAInputError,  # noqa: F401 (re-exported)
                          MSANotFound)

cmd = sys.modules["pymol.cmd"]

#: Stripped from a filename to make the default object name. Longest first, so
#: `.a3m.gz` does not come back as `alignment.a3m`.
_SUFFIXES = ('.a3m.gz', '.fasta.gz', '.fa.gz', '.aln.gz', '.a2m.gz', '.gz',
             '.a3m', '.fasta', '.fa', '.aln', '.a2m')


def default_name(filename):
    """The name an alignment gets when the caller does not pick one.

    The file's stem, with the alignment suffix removed and anything the command
    parser could not address replaced by '_'. Not made unique here -- see
    store.unique_name.
    """
    stem = os.path.basename(str(filename or ''))
    lowered = stem.lower()
    for suffix in _SUFFIXES:
        if lowered.endswith(suffix):
            stem = stem[:-len(suffix)]
            break
    cleaned = ''.join(c if (c.isalnum() or c in '_-.') else '_' for c in stem)
    return cleaned.strip('_') or 'alignment'


def _spell(chain):
    """How a chain id reads in a message. cmd.fab leaves it blank."""
    return chain if chain else '(blank)'


def _chain_sequence(target, chain, _self=cmd):
    """One-letter sequence of `chain` in `target`, and the chain id actually used.

    Reads it through predicting.sequence_from_selection deliberately, rather than
    with a private copy: the whole point of checking here is that the sequence an
    alignment is validated against is the same one a prediction would fold, down to
    how modified residues are substituted.
    """
    import pymol
    from .predicting import sequence_from_selection

    selection = '(%s) and polymer.protein' % target
    try:
        chains = [c for c in (_self.get_chains(selection) or [])]
    except Exception:
        chains = []
    if not chains:
        raise MSAInputError(
            'target "%s" has no protein chains to check the alignment against' % target)
    if chain:
        if chain not in chains:
            raise MSAInputError(
                'target "%s" has no chain %s; it has %s'
                % (target, chain, ', '.join(_spell(c) for c in chains)))
    elif len(chains) == 1:
        # May be '' -- cmd.fab leaves the chain id blank, and building a peptide with
        # fab is exactly how someone gets a target to attach an alignment to.
        chain = chains[0]
    else:
        # Not guessed. An alignment attached to the wrong chain of a complex is
        # exactly the mistake that produces a confident, wrong answer later.
        raise MSAInputError(
            'target "%s" has %d protein chains (%s); say which one this alignment is'
            ' for with chain=' % (target, len(chains),
                                  ', '.join(_spell(c) for c in chains)))

    # A blank chain id cannot be written as a selection, so it is addressed by being
    # the only one there is -- which is the only way this can be reached with ''.
    subselection = '(%s) and chain %s' % (selection, chain) if chain else selection
    try:
        sequence = sequence_from_selection(subselection, _self=_self)
    except pymol.CmdException as exc:
        raise MSAInputError('cannot read the sequence of "%s" chain %s: %s'
                            % (target, _spell(chain), exc))
    if '/' in sequence:
        # Several (object, chain) pairs matched -- `target` was a selection spanning
        # more than one object. Refused rather than joined: which one the alignment
        # belongs to is unknowable from here.
        raise MSAInputError(
            '"%s" chain %s spans more than one object; attach the alignment to a'
            ' single object' % (target, _spell(chain)))
    return sequence, chain


def _check_against_target(summary, target, chain, _self=cmd):
    """Refuse an alignment whose query is not the sequence it is attached to."""
    sequence, chain = _chain_sequence(target, chain, _self=_self)
    query = summary['query']
    if sequence == query:
        return chain
    # Length first, because the overwhelmingly common cause is not a wrong file but a
    # structure with unobserved residues: the object carries only what was resolved,
    # so a full-construct alignment is legitimately longer. Say so, rather than
    # leaving the user to diff two sequences by eye.
    if len(sequence) != len(query):
        raise MSAInputError(
            'the alignment\'s query is %d residues but "%s" chain %s has %d.'
            ' Unobserved residues are absent from a structure, so a full-construct'
            ' alignment will not match a crystal structure -- attach it to the'
            ' sequence you will actually fold, or load it without target=.'
            % (len(query), target, _spell(chain), len(sequence)))
    first = next(i for i, (a, b) in enumerate(zip(sequence, query)) if a != b)
    raise MSAInputError(
        'the alignment\'s query does not match "%s" chain %s: they differ at residue'
        ' %d (%s in the structure, %s in the alignment). This is the mismatch the'
        ' featurizer would refuse after the job had already started.'
        % (target, _spell(chain), first + 1, sequence[first], query[first]))


def load_msa(filename, name='', target='', chain='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "load_msa" reads a multiple-sequence alignment into a named alignment
    object, which is stored in the session and can be reused across targets
    and prediction methods.

    The alignment is kept EXACTLY as it was written. Nothing rewrites or
    normalises it, because the featurizer that eventually reads it reproduces
    upstream Boltz's parser bug for bug.

USAGE

    load_msa filename [, name [, target [, chain ]]]

ARGUMENTS

    filename = str: an a3m or aligned FASTA, optionally gzipped.

    name = str: name for the alignment {default: the file's stem}

    target = str: object this alignment is for. When given, the alignment's
    query is checked against that object's sequence immediately, and refused if
    it does not match.

    chain = str: chain of "target". Required when the target has more than one
    protein chain.

EXAMPLES

    load_msa barnase.a3m
    load_msa barnase.a3m, barnase_aln
    load_msa barnase.a3m, barnase_aln, 1brs, A

NOTES

    A structure carries only its OBSERVED residues, so an alignment built from
    the full construct will not match a crystal structure with unresolved
    loops. Load it without "target" in that case.

    The attachment is by name: renaming or deleting the object does not update
    or remove the alignment.

    Depth is reported AFTER duplicate rows are dropped, because that is what
    the featurizer will see.

    An alignment attached to an object is used automatically by "predict" when
    that object's chain is folded, and "predict" reports which alignment each
    chain used. Pass "msa=" there to override it.

SEE ALSO

    msa_list, msa_delete, msa_rename, msa_attach, predict
    """
    text = parse.read(filename)
    summary = parse.summarize(text)

    name = store.check_name(name) if name else store.unique_name(
        default_name(filename))
    if store.have(name):
        # Only reachable for an EXPLICIT name; the default was uniquified above.
        # Refused rather than overwritten: an alignment is expensive, and silently
        # replacing one because two files share a stem loses work.
        from .msas.errors import MSANameConflict
        raise MSANameConflict(
            'an alignment named %r already exists; delete it, or pass another name'
            % name)

    target = str(target or '').strip()
    chain = str(chain or '').strip()
    if target:
        chain = _check_against_target(summary, target, chain, _self=_self)

    msa = store.add(store.MSA(
        name, text, summary['query'], summary['depth'], summary['columns'],
        target=target, chain=chain,
        source={'kind': 'file', 'path': os.path.abspath(str(filename))}))

    if summary['dots']:
        # Warned regardless of `quiet`: '.' is insert-column padding to HHsuite, but
        # the featurizer counts it as a COLUMN and tokenizes it as UNK, so an
        # alignment carrying them does not mean there what it means here.
        colorprinting.warning(
            ' load_msa: %s contains %d "." characters; they are counted as alignment'
            ' columns and folded as unknown residues, not as insertions.'
            % (name, summary['dots']))
    if not int(quiet):
        detail = ' -> %s, %d sequences x %d columns' % (
            name, msa.depth, msa.columns)
        if summary['duplicates']:
            detail += ' (%d duplicate rows dropped)' % summary['duplicates']
        if target:
            detail += ', for %s chain %s' % (target, _spell(chain))
        colorprinting.parrot(' load_msa: %s%s' % (os.path.basename(str(filename)),
                                                  detail))
    return name


def msa_list(quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_list" returns the names of the alignments loaded in this session.

USAGE

    msa_list

SEE ALSO

    load_msa, msa_delete
    """
    summaries = store.panel_summary()
    if not int(quiet):
        if not summaries:
            colorprinting.parrot(' msa_list: no alignments loaded')
        for entry in summaries.values():
            attached = (' -> %s chain %s' % (entry['target'],
                                             _spell(entry['chain']))
                        if entry['target'] else '')
            colorprinting.parrot(
                ' %-24s %6d sequences x %5d columns%s'
                % (entry['name'], entry['depth'], entry['columns'], attached))
    return list(summaries)


def msa_delete(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_delete" removes an alignment from the session.

USAGE

    msa_delete name

ARGUMENTS

    name = str: alignment to remove, or "all" for every one.

SEE ALSO

    load_msa, msa_list
    """
    removed = store.delete(str(name))
    if not int(quiet):
        colorprinting.parrot(' msa_delete: removed %d alignment(s)' % removed)
    return removed


def msa_rename(name, new_name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_rename" renames an alignment.

USAGE

    msa_rename name, new_name

SEE ALSO

    load_msa, msa_list
    """
    msa = store.rename(str(name), str(new_name))
    if not int(quiet):
        colorprinting.parrot(' msa_rename: %s -> %s' % (name, msa.name))
    return msa.name


def msa_attach(name, target, chain='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_attach" records which object and chain an alignment belongs to, and
    checks that its query matches that chain's sequence.

USAGE

    msa_attach name, target [, chain ]

ARGUMENTS

    name = str: a loaded alignment.

    target = str: object the alignment is for.

    chain = str: chain of "target". Required when the target has more than one
    protein chain.

NOTES

    The attachment is by name. Renaming or deleting the object does not update
    or remove the alignment.

SEE ALSO

    load_msa, msa_detach
    """
    msa = store.get(str(name))
    summary = {'query': msa.query}
    chain = _check_against_target(summary, str(target), str(chain), _self=_self)
    store.attach(msa.name, str(target), chain)
    if not int(quiet):
        colorprinting.parrot(' msa_attach: %s -> %s chain %s'
                             % (msa.name, target, _spell(chain)))
    return msa.name


def msa_detach(name, quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_detach" forgets which object an alignment belongs to. The alignment
    itself is kept.

USAGE

    msa_detach name

SEE ALSO

    msa_attach
    """
    msa = store.detach(str(name))
    if not int(quiet):
        colorprinting.parrot(' msa_detach: %s is no longer attached' % msa.name)
    return msa.name


# -- Searching: msa_search and the main-thread pump ----------------------------
#
# The search itself runs on a thread (msas/searching.py) and MAY NOT touch the session,
# so the finished alignment is parked on the search record and put in the store HERE, on
# the main thread. pump() is driven by the object panel's existing 500 ms poll in the app
# (appkit_inspector.poll_panel), and by msa_status / msa_cancel everywhere else -- the
# same arrangement predicting.pump() uses for a prediction whose weights were cold.

#: Hosts already warned about in this session. A search against a public server publishes
#: the query to a third party, and RayMol's users fold unpublished designed binders; the
#: warning is per host rather than a single flag so pointing at a second public server
#: warns again.
_PUBLIC_WARNED = set()

#: Residue letters a query may contain: the 20, plus the ambiguity and rare codes an
#: honest sequence can carry. Anything else is a typo or a nucleotide sequence, and the
#: server would spend a minute rejecting it.
_RESIDUE_LETTERS = frozenset('ACDEFGHIKLMNPQRSTVWYBZXUO')

#: Below this a search is meaningless -- MMseqs2 needs something to seed on -- and above
#: it the public server refuses the job anyway. Both are advisory bounds that turn a slow
#: remote failure into an immediate local one.
MIN_QUERY_RESIDUES = 10
MAX_QUERY_RESIDUES = 4000

#: Hex digits of the query digest in a derived alignment name. Eight, as in
#: predicting.default_object_name, and for the same reason: a collision would put two
#: different alignments in one place.
NAME_DIGEST_CHARS = 8


def default_search_name(sequence, source='', _self=cmd):
    """The name a searched alignment gets when the caller does not pick one.

    `<object>_msa` when the search was asked for by object name, because that is what the
    user will look for in the panel; otherwise `msa_<digest>` of the query, so searching
    the same sequence twice reads as the same thing rather than as two unrelated names.
    Not made unique here -- see store.unique_name.
    """
    stem = str(source or '').strip()
    if stem and all(c.isalnum() or c in '_-.' for c in stem):
        try:
            if stem in (_self.get_names('objects') or []):
                return '%s_msa' % stem
        except Exception:
            pass
    import hashlib
    normalised = ''.join(str(sequence).split()).upper()
    digest = hashlib.sha256(normalised.encode('utf-8')).hexdigest()
    return 'msa_%s' % digest[:NAME_DIGEST_CHARS]


def warn_if_public(server):
    """Say, once per session and per host, that a public server sees the sequence.

    Regardless of `quiet`: this is not progress reporting. `quiet=1` is the Python API's
    default, so gating it would hide the disclosure from exactly the scripted path most
    likely to search a hundred designs in a loop.
    """
    if not colabfold.is_public(server):
        return False
    host = colabfold.host_of(server)
    if host in _PUBLIC_WARNED:
        return False
    _PUBLIC_WARNED.add(host)
    colorprinting.warning(
        ' msa_search: %s is a PUBLIC, third-party MSA server. The query sequence LEAVES'
        ' THIS MACHINE and is searched on infrastructure RayMol does not control. To use'
        ' your own deployment instead: msa_server https://your.server (or set %s).'
        % (host, colabfold.SERVER_ENV))
    return True


def _check_query(sequence):
    """The query to search for, or raise. One chain, residues only."""
    text = ''.join(str(sequence or '').split()).upper()
    if '/' in text:
        # Refused rather than searched as a concatenation, and rather than searched as a
        # complex: this command produces UNPAIRED, per-chain alignments only (#298), and
        # a chimeric query built by joining two chains describes a protein that does not
        # exist. Real pairing needs a taxonomy database and is a separate ticket.
        raise MSAInputError(
            'msa_search builds an alignment for ONE chain at a time; this query has %d.'
            ' Search each chain separately and attach each alignment to its own chain.'
            % (text.count('/') + 1))
    if not text:
        raise MSAInputError('nothing to search for: the query sequence is empty')
    bad = sorted(set(text) - _RESIDUE_LETTERS)
    if bad:
        raise MSAInputError(
            'the query contains %s, which are not residue letters; msa_search searches'
            ' protein sequences' % ', '.join(repr(c) for c in bad))
    if not MIN_QUERY_RESIDUES <= len(text) <= MAX_QUERY_RESIDUES:
        raise MSAInputError(
            'the query is %d residues; msa_search searches between %d and %d'
            % (len(text), MIN_QUERY_RESIDUES, MAX_QUERY_RESIDUES))
    return text


def msa_server(server='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_server" sets -- or reports -- the ColabFold MSA server that
    "msa_search" sends queries to.

USAGE

    msa_server [ server ]

ARGUMENTS

    server = str: base URL of a ColabFold MSA server, e.g.
    https://msa.internal.example. Omit it to print the one in use.

NOTES

    Resolution order: the "server" argument of msa_search, then this setting,
    then the RAYMOL_MSA_SERVER environment variable, then the public default
    https://api.colabfold.com.

    THE DEFAULT IS A THIRD-PARTY SERVICE. Searching there publishes the query
    sequence to infrastructure RayMol does not control. A private deployment
    running ColabFold's own msa-server speaks exactly the same protocol, so
    only this URL changes.

    This setting is per session. Put the command in ~/.raymolrc.py to make it
    permanent -- the native apps boot Python directly and never read ~/.pymolrc.

EXAMPLES

    msa_server https://msa.internal.example
    msa_server

SEE ALSO

    msa_search, msa_status
    """
    if server:
        url = colabfold.set_server(str(server))
        if not int(quiet):
            colorprinting.parrot(' msa_server: searches will use %s' % url)
        return url
    url, origin = colabfold.resolve()
    if not int(quiet):
        where = {'msa_server': 'set with msa_server',
                 'default': 'the public default',
                 colabfold.SERVER_ENV: 'from ' + colabfold.SERVER_ENV,
                 }.get(origin, origin)
        colorprinting.parrot(' msa_server: %s (%s)%s'
                             % (url, where,
                                '; a PUBLIC, third-party service'
                                if colabfold.is_public(url) else ''))
    return url


def msa_search(sequence, name='', target='', chain='', server='', mode='env',
               refresh=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_search" builds an alignment for one protein chain by running an
    MMseqs2 search on a ColabFold MSA server, and stores the result as a named
    alignment object.

    IT RETURNS IMMEDIATELY. The search takes minutes and runs in the
    background; the alignment appears when it lands. Watch it with
    "msa_status", stop it with "msa_cancel".

USAGE

    msa_search sequence [, name [, target [, chain [, server [, mode
        [, refresh ]]]]]]

ARGUMENTS

    sequence = str: one-letter sequence, or the name of a loaded object, or an
    atom selection -- resolved exactly as "predict" resolves it. ONE CHAIN: a
    complex is refused, because this produces unpaired, per-chain alignments.

    name = str: name for the alignment {default: <object>_msa when the query
    came from an object, else msa_<digest of the sequence>}

    target = str: object the alignment is for. Checked against that object's
    sequence before the search starts, and recorded when it lands.

    chain = str: chain of "target". Required when the target has more than one
    protein chain.

    server = str: base URL of the MSA server for this search only
    {default: the "msa_server" setting, then RAYMOL_MSA_SERVER, then the
    public https://api.colabfold.com}

    mode = env | all | env-nofilter | nofilter: which databases are searched
    and whether the result is filtered. "env" adds the environmental databases
    and is ColabFold's own default. {default: env}

    refresh = 0/1: search again instead of reusing a cached result {default: 0}

EXAMPLES

    msa_search MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    fetch 1ubq
    msa_search 1ubq, target=1ubq
    msa_search 1ubq and chain A, name=ubq_aln, server=https://msa.internal

NOTES

    THE DEFAULT SERVER IS A THIRD-PARTY SERVICE and the query sequence leaves
    this machine when it is used. The first such search in a session says so.
    A private deployment running ColabFold's msa-server speaks the identical
    protocol: "msa_server https://your.server".

    Results are cached on disk, keyed on the sequence, the server and the mode,
    so re-searching a target is instant. "refresh=1" forces a new search.

    ALIGNMENTS ARE UNPAIRED, one chain at a time. Paired MSAs for complexes are
    deliberately not produced: nothing downstream reads their pairing, and
    passing homolog rows off as paired inflates interface scores rather than
    failing outright.

    Which server produced an alignment is recorded in it, and survives into a
    saved .pse -- see "msa_list".

SEE ALSO

    msa_server, msa_status, msa_cancel, load_msa, msa_list
    """
    from .predicting import resolve_sequence

    # Resolved through predict's own resolver, deliberately: the sequence an alignment is
    # built for has to be the same one a prediction would fold, down to how modified
    # residues are substituted -- otherwise the alignment is refused at attach time by a
    # mismatch the user cannot see the cause of.
    # quiet=1 regardless of ours: its own message is prefixed ' predict:', which reads as
    # a prediction starting. What this command did is said below, in its own words.
    resolved = resolve_sequence(sequence, quiet=1, _self=_self)
    query = _check_query(resolved)

    url, _origin = colabfold.resolve(server)
    mode = colabfold.check_mode(mode)

    target = str(target or '').strip()
    chain = str(chain or '').strip()
    if target:
        # Checked NOW, before minutes of searching, for the same reason load_msa checks
        # at load time: a mismatch found afterwards has already spent the time.
        chain = _check_against_target({'query': query}, target, chain, _self=_self)

    name = store.check_name(name) if name else default_search_name(
        query, source=sequence if isinstance(sequence, str) else '', _self=_self)
    name = store.unique_name(name)

    warn_if_public(url)

    search = searching.start(name, query, url, mode, target=target, chain=chain,
                             quiet=quiet, refresh=refresh)
    if not int(quiet):
        if search.from_cache:
            colorprinting.parrot(
                ' msa_search: %d residues, already searched on %s [%s]; reusing the'
                ' cached alignment' % (len(query), url, mode))
        else:
            colorprinting.parrot(
                ' msa_search: %d residues sent to %s [mode %s]; search %s runs in the'
                ' background and lands as %s. Stop it with "msa_cancel %s".'
                % (len(query), url, mode, search.id, name, search.id))
    # A cached search is already settled, so this lands it before the call returns and a
    # script can use the alignment on the next line. A live one is untouched by it.
    pump(_self=_self)
    return search.id


def pump(_self=cmd):
    """Land every finished search. MAIN THREAD ONLY -- it writes to the store.

    Cheap and idempotent by design: it is called from the object panel's 500 ms poll, so
    it must stay a few dict lookups when there is nothing to do. Never raises; a failure
    here would break the poll that drives the whole panel.

    Returns the number of searches settled by this call.
    """
    settled = 0
    for search in searching.unreaped():
        snapshot = search.snapshot()
        if snapshot['state'] == 'running':
            continue
        if not searching.reap(search):
            continue                      # another pump got there first
        settled += 1
        try:
            if snapshot['state'] == 'done':
                _land(search, _self=_self)
            elif snapshot['state'] == 'error':
                # Always reported, whatever `quiet` said: this is the only account the
                # user gets of a search that has been running for minutes, and the app's
                # console is where they will look for it.
                colorprinting.error(' msa_search: %s failed: %s'
                                    % (search.name, snapshot['error']))
            elif not search.quiet:
                colorprinting.parrot(' msa_search: %s cancelled' % search.name)
        except Exception as exc:
            colorprinting.error(' msa_search: %s could not be stored (%s)'
                                % (search.name, exc))
    return settled


def _land(search, _self=cmd):
    """Put a finished search in the store. Main thread only; called from pump()."""
    summary = search.summary or {}
    # Uniquified AGAIN: the name was free when the search was submitted, and minutes have
    # passed since. Landing must not fail on a name the user took in the meantime.
    name = store.unique_name(search.name)
    target, chain = search.target, search.chain
    if target:
        try:
            chain = _check_against_target(summary, target, chain, _self=_self)
        except MSAError as exc:
            # The object was deleted or edited while the search ran. The alignment cost
            # minutes and is still perfectly good, so it lands unattached rather than
            # being thrown away -- attach it later with msa_attach.
            colorprinting.warning(
                ' msa_search: %s no longer matches %s (%s); storing it unattached'
                % (name, target, exc))
            target, chain = '', ''
    meta = search.meta or {}
    msa = store.add(store.MSA(
        name, search.text, summary['query'], summary['depth'], summary['columns'],
        target=target, chain=chain,
        # Provenance names the server, always. Inside a saved .pse this is the only
        # record of where an alignment came from -- and, for a sequence that was sent to
        # a public service, the only record that it was.
        source={'kind': 'search',
                'server': meta.get('server') or search.server,
                'mode': meta.get('mode') or search.mode,
                'ticket': meta.get('ticket') or search.ticket,
                'databases': list(meta.get('sources') or []),
                'when': meta.get('when') or '',
                'cached': bool(search.from_cache)}))
    if summary.get('dots'):
        # Same warning load_msa gives, and for the same reason: '.' is insert-column
        # padding to HHsuite, but the featurizer counts it as a COLUMN and tokenizes it
        # as UNK.
        colorprinting.warning(
            ' msa_search: %s contains %d "." characters; they are counted as alignment'
            ' columns and folded as unknown residues, not as insertions.'
            % (name, summary['dots']))
    if not search.quiet:
        detail = ' -> %s, %d sequences x %d columns from %s' % (
            name, msa.depth, msa.columns, search.server)
        if search.from_cache:
            detail += ' (cached)'
        if target:
            detail += ', for %s chain %s' % (target, _spell(chain))
        colorprinting.parrot(' msa_search:%s' % detail)
    return name


def msa_status(search_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_status" reports the state of one background MSA search, or of all of
    them.

USAGE

    msa_status [ search_id ]

NOTES

    Polling this is also what lands a finished search in a script: the
    alignment is created on the calling thread, because the search thread must
    not touch the session. The application does the same from its own poll.

SEE ALSO

    msa_search, msa_cancel
    """
    pump(_self=_self)
    if search_id:
        search = searching.get(str(search_id))
        if search is None:
            raise MSANotFound('no MSA search %r' % search_id)
        searches = [search]
    else:
        searches = searching.all_searches()
    out = {}
    for search in searches:
        snapshot = search.snapshot()
        out[snapshot['id']] = snapshot
        if not int(quiet):
            detail = ''
            if snapshot['state'] == 'done':
                detail = ' (%d sequences x %d columns)' % (snapshot['depth'],
                                                           snapshot['columns'])
            elif snapshot['error']:
                detail = ' (%s)' % snapshot['error']
            colorprinting.parrot(
                ' msa_search: %s %s %s on %s, %ds%s'
                % (snapshot['id'], snapshot['state'], snapshot['phase'],
                   snapshot['server'], int(snapshot['elapsed']), detail))
    return out


def msa_cancel(search_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "msa_cancel" stops a background MSA search.

USAGE

    msa_cancel [ search_id ]

ARGUMENTS

    search_id = str: search to stop {default: '', meaning every running one}

NOTES

    Nothing half-built is left behind: an alignment is only ever created when a
    search completes, so a cancelled search creates no alignment at all.

    The server is not told. A ticket already queued there runs to completion on
    its side; RayMol simply stops waiting for it, and searching the same
    sequence again will usually pick the finished result up at once.

SEE ALSO

    msa_search, msa_status
    """
    if search_id and searching.get(str(search_id)) is None:
        raise MSANotFound('no MSA search %r' % search_id)
    stopped = searching.cancel(str(search_id))
    # Reap now rather than at the next poll: a cancelled search still holds a record the
    # user is about to ask about, and msa_status should not report it as running.
    pump(_self=_self)
    if not int(quiet):
        colorprinting.parrot(' msa_cancel: stopped %d search(es)' % stopped)
    return stopped
