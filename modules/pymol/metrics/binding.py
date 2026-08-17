"""Everything that has to ask the session: scope checks, recording, staleness.

Kept apart from store.py so the store stays a data structure -- exercisable from a
test, a plugin or a background thread with no session at all -- and so there is exactly
one place where a metric meets the object it claims to describe.

The checks here are deliberately loud and up front, the same trade predictors.base
makes by validating an alignment before a half-gigabyte weight download: a number that
lands on the wrong residues is not detectable later by looking at it.
"""
from pymol import cmd as _cmd_module

from . import schema, store
from .errors import MetricScopeError

#: How many offending residues a mismatch message lists before it says "and N more".
#: Enough to recognise the pattern -- a whole chain missing, an off-by-one register --
#: without printing an 800-residue array into a feedback line.
_MAX_REPORTED = 6


def _exists(object, _self=_cmd_module):
    try:
        return object in _self.get_names('objects')
    except Exception:
        return False


def state_count(object, _self=_cmd_module):
    """Number of states in `object`, or 0 if it is not there."""
    try:
        return int(_self.count_states(object))
    except Exception:
        return 0


def residue_index(object, _self=_cmd_module):
    """The set of (chain, resi) in `object`. ONE pass over its atoms.

    O(atoms), so it is called once per record and never from the panel poll.

    Deliberately `iterate`, not `iterate_state`: chain and resi are per-ATOM in PyMOL,
    shared by every state, so the index is a property of the object rather than of one
    model. That is what a write-time check wants -- states of one object differ in
    coordinates, not in which residues exist.

    Chain is taken verbatim, including the empty string -- a PDB without chain ids is
    ordinary, and an entry keyed by '' has to be able to match it.
    """
    seen = set()
    try:
        _self.iterate(object, 'seen.add((chain, resi))', space={'seen': seen})
    except Exception as exc:
        raise MetricScopeError('could not read residues of %r (%s)' % (object, exc))
    return seen


def check(object, values, _self=_cmd_module, index=None):
    """Raise unless every value in `values` fits `object` as it is right now.

    `index` is an already-computed residue index, so recording several arrays does not
    walk the atoms once per array.
    """
    if not _exists(object, _self=_self):
        raise MetricScopeError(
            'no object named %r; a metric is recorded against an object that exists,'
            ' so that its states and residues can be checked' % object)
    count = state_count(object, _self=_self)
    needs_index = any(entry.is_array for entry in values)
    if needs_index and index is None:
        index = residue_index(object, _self=_self)

    for entry in values:
        if entry.state is not None:
            # Bound by INDEX, which is what a PyMOL state is. The alternative -- an
            # identity stamped into the state title -- survives reordering but requires
            # every producer to stamp one, and today only the prediction seed does.
            # So: check the index now, and let binding.stale_reason() say so loudly if
            # the state count changes underneath.
            if not 1 <= int(entry.state) <= count:
                raise MetricScopeError(
                    '%r was measured on state %d, but %r has %s'
                    % (entry.key, entry.state, object,
                       '%d state(s)' % count if count else 'no states'))
        if entry.chain is not None and index is None:
            index = residue_index(object, _self=_self)
        if entry.chain is not None:
            chains = {chain for chain, _ in index}
            if entry.chain not in chains:
                raise MetricScopeError(
                    '%r is chain-scope on chain %r, which %r does not have (it has:'
                    ' %s)' % (entry.key, entry.chain, object,
                              ', '.join(sorted(repr(c) for c in chains)) or 'none'))
        if entry.is_array:
            missing = [pair for pair in entry.index if pair not in index]
            if missing:
                shown = ', '.join('%s/%s' % pair for pair in missing[:_MAX_REPORTED])
                more = ('' if len(missing) <= _MAX_REPORTED
                        else ' and %d more' % (len(missing) - _MAX_REPORTED))
                raise MetricScopeError(
                    '%r is indexed by %d residue(s) that %r does not have: %s%s.'
                    ' An array must be indexed by the residues it measured --'
                    ' unobserved residues are absent from a structure, so an array'
                    ' built from the full construct will not fit one read out of a'
                    ' crystal structure.'
                    % (entry.key, len(missing), object, shown, more))
    return True


def record(object, tool, values, tool_version='', inputs=None, states=(),
           note='', run_id='', _self=_cmd_module):
    """Validate `values` against `object`, then store them as one run.

    The write path every tool should use. Returns the MetricRun.

    `states` defaults to the states the values themselves name, so a caller that wrote
    per-state numbers does not also have to declare which states it touched.
    """
    values = list(values)
    check(object, values, _self=_self)
    if not states:
        states = sorted({int(entry.state) for entry in values
                         if entry.state is not None})
    return store.record(object, tool, values, tool_version=tool_version,
                        inputs=inputs, states=states,
                        state_count=state_count(object, _self=_self),
                        note=note, run_id=run_id)


def stale_reason(run, _self=_cmd_module):
    """Why `run` may no longer describe what it says it does, or '' if it is fine.

    States are positional. Delete state 1 of a five-model object and every state-scope
    value in every run on it now points one model along -- the numbers are still there
    and still look right. Nothing here repairs that, because nothing here can know
    which state went; it is reported instead, in metrics_list, in metrics_get and on
    the panel row, so the number is never read as current without the caveat.
    """
    if not _exists(run.object, _self=_self):
        return 'object %r is gone' % run.object
    if not run.state_count:
        return ''
    now = state_count(run.object, _self=_self)
    if now != run.state_count:
        return ('%r had %d state(s) when this was measured and has %d now, so'
                ' per-state values may no longer line up'
                % (run.object, run.state_count, now))
    return ''


def is_stale(run, _self=_cmd_module):
    return bool(stale_reason(run, _self=_self))


def color(run, key, palette='blue_white_red', state=None, chain=None,
          minimum=None, maximum=None, selection='', _self=_cmd_module):
    """Colour by a stored residue array, writing it into B-factors as a VIEW.

    `b` is a rendering channel here, not storage: the run keeps the array, and this
    can be re-run after another tool has coloured over the column. That is the whole
    point of the store -- before it, a design pass overwrote a prediction's pLDDT and
    there was no way back.

    Only the residues the array actually measured are spectrumed. Everything else keeps
    its colour instead of being clamped to the first palette entry, which is the fix
    raymol_design.apply_design_coloring already carries for masked residues.
    """
    entry = run.one(key, state=state, chain=chain)
    if entry.scope != schema.RESIDUE:
        raise MetricScopeError(
            'metrics_color needs a residue-scope metric; %r is %s-scope'
            % (key, entry.scope))
    values = entry.as_map()
    if not values:
        raise MetricScopeError(
            '%r in run %s has no measured residues to colour by' % (key, run.id))

    scope = selection or run.object
    by_chain = {}
    for chain_id, resi in values:
        by_chain.setdefault(chain_id, []).append(resi)
    parts = []
    for chain_id, resis in by_chain.items():
        resi_sel = 'resi ' + '+'.join(resis)
        parts.append('(chain %s and %s)' % (chain_id, resi_sel) if chain_id
                     else '(%s)' % resi_sel)
    scored = '(%s) and (%s)' % (scope, ' or '.join(parts))

    def _lookup(chain_id, resi):
        return values.get((chain_id, resi))

    # Residues the array did not measure keep whatever `b` already held: `alter` runs
    # only over the scored selection. A sentinel would colour them, which is the bug
    # the -9999 clamp used to cause.
    _self.alter(scored, 'b = _lookup(chain, resi) if _lookup(chain, resi)'
                        ' is not None else b',
                space={'_lookup': _lookup})

    spec = schema.spec(run.tool, key)
    lo = spec.lo if minimum is None else float(minimum)
    hi = spec.hi if maximum is None else float(maximum)
    if lo is None or hi is None:
        # No declared domain and none given: let spectrum auto-scale over what is
        # there. Comparable within this object, not between runs -- which is exactly
        # why a spec should declare lo/hi.
        _self.spectrum('b', palette, scored)
    else:
        _self.spectrum('b', palette, scored, minimum=lo, maximum=hi)
    return len(values)
