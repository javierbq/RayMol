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
from .msas import parse, store
from .msas.errors import MSAInputError  # noqa: F401  (re-export for callers)

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

SEE ALSO

    msa_list, msa_delete, msa_rename, msa_attach
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
