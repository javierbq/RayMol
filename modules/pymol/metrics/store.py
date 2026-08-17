"""Runs, their values, the named store, and the .pse round trip.

WHY THIS IS NOT A C++ OBJECT. A metric has no geometry, so every one of `CObject`'s
virtuals would be a stub -- the argument pymol.msas.store already makes.

WHY NOT `p.*` ATOM PROPERTIES, which this fork does implement (`layer1/Property.cpp`,
ungated -- unlike stock open-source PyMOL, where the same write raises
IncentiveOnlyException and Design and assign_stereo fall back to the B-factor column).
Three reasons, none of them about availability:

- a property is per ATOM and carries no run, so two runs of one tool cannot coexist and
  neither can say which options produced it;
- it has no scope: `mean_plddt` is per state and `pae` is per residue PAIR, and neither
  fits on an atom at all;
- it does not survive a .pse, so the numbers die with the session that made them.

The B-factor column is not storage either: one unlabelled scalar per atom, rounded to
two decimals by any PDB round trip, and freely overwritten by the next tool that colours
by it -- including `metrics_color` itself. So `b` is treated here as a rendering channel
that the store can refill, never as the record.

Nothing here imports `cmd`. Whatever has to ask the session -- does that state exist,
are those residues in that object -- lives in binding.py, so the store stays a data
structure that a test, a plugin or a background thread can exercise without a session.

Process-wide, like predicting._JOBS and the MSA store. A second pymol2 instance shares
it; that is a limitation these modules share, not a decision taken here.
"""
import base64
import gzip
import json
import time
import uuid

from . import schema
from .errors import (MetricInputError, MetricNotFound, MetricSchemaError,
                     MetricScopeError)

#: Extra key in the .pse session dictionary. Older PyMOL ignores what it does not know,
#: so a session written with metrics still opens in upstream PyMOL -- without them.
SESSION_KEY = 'raymol_metrics'

#: Bumped only for a change the reader cannot absorb. A reader meeting a version it
#: does not know skips the payload rather than guessing at it.
SESSION_VERSION = 1

#: run id -> MetricRun, insertion-ordered: the order runs were recorded, which is the
#: order metrics_list shows and the order export writes.
_RUNS = {}


def _now():
    """Seconds since the epoch, as a float. One place, so tests can monkeypatch it."""
    return time.time()


class MetricValue:
    """One measurement inside a run.

    Scalar scopes (object, state, chain) carry `value` and no index. Array scopes
    (residue, pair) carry `index` -- a tuple of (chain, resi) pairs -- and `values`,
    which for `pair` is row-major over that index squared.

    The index is EXPLICIT rather than positional. A structure with unobserved residues
    is exactly where a bare offset goes wrong, and it is the same mismatch
    predictors.base._check_alignment_query already exists to catch: an array built from
    a full construct, applied to what a crystal actually resolved, lands silently on
    the wrong residues.

    `resi` is a string, not an int: PyMOL's is, and insertion codes ('52A') are real.
    """

    __slots__ = ('key', 'scope', 'state', 'chain', 'value', 'index', 'values')

    def __init__(self, key, scope, state=None, chain=None,
                 value=None, index=None, values=None):
        self.key = key
        self.scope = scope
        self.state = state
        self.chain = chain
        self.value = value
        self.index = index
        self.values = values

    @property
    def is_array(self):
        return self.scope in schema.ARRAY_SCOPES

    def pairs(self):
        """(chain, resi, value) triples for a residue array, in index order."""
        if self.scope != schema.RESIDUE:
            raise MetricInputError('%r is %s-scope, not residue-scope'
                                   % (self.key, self.scope))
        return [(chain, resi, self.values[i])
                for i, (chain, resi) in enumerate(self.index)]

    def as_map(self):
        """{(chain, resi): value} for a residue array. Absent entries stay absent."""
        return {(chain, resi): value
                for chain, resi, value in self.pairs() if value is not None}

    def __repr__(self):
        if self.is_array:
            return 'MetricValue(%r, %s, n=%d)' % (self.key, self.scope,
                                                  len(self.values or ()))
        return 'MetricValue(%r, %s, %r)' % (self.key, self.scope, self.value)


def _clean_index(key, index):
    """(chain, resi) pairs as a tuple of string 2-tuples, or raise."""
    cleaned = []
    for entry in index or ():
        try:
            chain, resi = entry
        except (TypeError, ValueError):
            raise MetricInputError(
                'index entry %r for %r is not a (chain, resi) pair' % (entry, key))
        cleaned.append((str(chain), str(resi)))
    if not cleaned:
        raise MetricInputError('%r is an array metric with an empty index' % key)
    return tuple(cleaned)


def value(tool, key, value=None, state=None, chain=None, index=None, values=None):
    """Build one MetricValue for `tool`'s declared `key`, or raise.

    The single construction path, so a scope mismatch is caught HERE -- at the point a
    tool writes a number -- rather than surfacing later as a plausible-looking value
    describing something else.
    """
    spec = schema.spec(tool, key)
    scope = spec.scope

    if scope in schema.ARRAY_SCOPES:
        if values is None:
            raise MetricScopeError(
                '%r is %s-scope and needs `values`, not a scalar `value`'
                % (key, scope))
        index = _clean_index(key, index)
        values = [spec.cast(v) for v in values]
        expected = len(index) ** 2 if scope == schema.PAIR else len(index)
        if len(values) != expected:
            raise MetricScopeError(
                '%r is %s-scope over %d residues, so it needs %d values, got %d'
                % (key, scope, len(index), expected, len(values)))
    else:
        if values is not None or index is not None:
            raise MetricScopeError(
                '%r is %s-scope: it takes a single `value`, not an array'
                % (key, scope))
        value = spec.cast(value)

    if scope == schema.OBJECT and state is not None:
        # Not coerced to state 1. An object-scope metric written with a state is a tool
        # saying two different things about what it measured, and the likeliest reading
        # -- "this is really per-model" -- is the one that makes n_models wrong.
        raise MetricScopeError(
            '%r is object-scope, so it must not carry a state; it is a property of the'
            ' object (typically of its sequence) and is the same for every model.'
            ' A per-model number belongs at state scope.' % key)
    if scope in (schema.STATE, schema.RESIDUE, schema.PAIR) and state is None:
        raise MetricScopeError(
            '%r is %s-scope and needs the state it was measured on. With n_models a'
            ' single object holds several independent runs as several states, so a'
            ' value with no state cannot say which coordinates it describes.'
            % (key, scope))
    if scope == schema.CHAIN and not chain:
        raise MetricScopeError('%r is chain-scope and needs a chain' % key)
    if chain is not None and scope in (schema.OBJECT, schema.STATE):
        raise MetricScopeError(
            '%r is %s-scope, so it must not carry a chain' % (key, scope))

    return MetricValue(key, scope,
                       state=None if state is None else int(state),
                       chain=None if chain is None else str(chain),
                       value=value, index=index, values=values)


class MetricRun:
    """Everything one invocation of one tool measured about one object.

    Grouped by RUN because a metric without its inputs is not evidence of anything:
    the options, the seed, the weight pack and the alignment depth all change the
    number, and #293 and #301 made two of those routinely different between runs of
    the same tool. An object carries many runs -- fold, re-fold deeper, then design --
    and no run replaces another.

    `state_count` is the object's state count when the run was written. States are
    positional indices in PyMOL, so deleting or reordering them re-points every
    state-scope value in here; binding.is_stale() compares the two and says so rather
    than letting a number quietly describe different coordinates.
    """

    __slots__ = ('id', 'tool', 'object', 'tool_version', 'created', 'inputs',
                 'values', 'states', 'state_count', 'note')

    def __init__(self, id, tool, object, values=(), tool_version='', inputs=None,
                 states=(), state_count=0, created=None, note=''):
        self.id = id
        self.tool = tool
        self.object = object
        self.tool_version = str(tool_version or '')
        self.created = _now() if created is None else float(created)
        self.inputs = dict(inputs or {})
        self.values = list(values)
        self.states = tuple(int(s) for s in states or ())
        self.state_count = int(state_count or 0)
        self.note = str(note or '')

    def keys(self):
        """Declared keys present in this run, in write order, without duplicates."""
        seen = []
        for entry in self.values:
            if entry.key not in seen:
                seen.append(entry.key)
        return seen

    def find(self, key, state=None, chain=None):
        """Every value for `key`, optionally narrowed to a state and/or chain."""
        out = []
        for entry in self.values:
            if entry.key != key:
                continue
            if state is not None and entry.state is not None \
                    and int(entry.state) != int(state):
                continue
            if chain is not None and entry.chain is not None \
                    and str(entry.chain) != str(chain):
                continue
            out.append(entry)
        return out

    def one(self, key, state=None, chain=None):
        """The single value for `key`, or raise. For scalars and for a chosen state."""
        found = self.find(key, state=state, chain=chain)
        if not found:
            raise MetricNotFound(
                'run %s has no %r%s' % (self.id, key,
                                        '' if state is None else ' for state %s' % state))
        if len(found) > 1:
            raise MetricNotFound(
                'run %s has %d values for %r; narrow by state or chain'
                % (self.id, len(found), key))
        return found[0]

    def scalars(self, state=None):
        """{key: value} for the scalar scopes -- what a listing and a CSV want.

        Object-scope values are always included: they are true of every state. State
        and chain values are included only when they match `state`, or when no state
        was asked for. Never touches an array, so this stays cheap enough for the
        poll (the discipline #271 had to restore for the object panel).
        """
        out = {}
        for entry in self.values:
            if entry.scope not in schema.SCALAR_SCOPES:
                continue
            if state is not None and entry.state is not None \
                    and int(entry.state) != int(state):
                continue
            key = entry.key if not entry.chain else '%s/%s' % (entry.key, entry.chain)
            out[key] = entry.value
        return out

    def summary(self, state=None):
        """The cheap description metrics_list and any future surface show. No arrays."""
        return {
            'id': self.id,
            'tool': self.tool,
            'tool_version': self.tool_version,
            'object': self.object,
            'created': self.created,
            'states': list(self.states),
            'state_count': self.state_count,
            'keys': self.keys(),
            'scalars': self.scalars(state=state),
            'note': self.note,
        }

    def __repr__(self):
        return 'MetricRun(%r, tool=%r, object=%r, values=%d)' % (
            self.id, self.tool, self.object, len(self.values))


def new_id(tool):
    """A run id that is unique in this store and readable in a command line."""
    while True:
        candidate = '%s_%s' % (tool, uuid.uuid4().hex[:8])
        if candidate not in _RUNS:
            return candidate


def add(run):
    """Store `run`. An id already in use is an error, never a silent overwrite."""
    if run.id in _RUNS:
        raise MetricInputError('a run named %r already exists' % run.id)
    _RUNS[run.id] = run
    return run


def record(object, tool, values, tool_version='', inputs=None, states=(),
           state_count=0, note='', run_id=''):
    """Build a run from already-constructed MetricValues and store it.

    The store-level write path. `binding.record()` is the one callers should use from
    a session: it validates the values against the object before this is reached.
    """
    if not schema.declared(tool):
        raise MetricSchemaError(
            'tool %r has declared no metrics; call metrics.schema.register(%r, [...])'
            ' before recording, so listings and export know what the numbers are'
            % (tool, tool))
    run = MetricRun(run_id or new_id(tool), tool, str(object), values,
                    tool_version=tool_version, inputs=inputs, states=states,
                    state_count=state_count, note=note)
    return add(run)


def get(run_id):
    """The run stored under `run_id`."""
    try:
        return _RUNS[run_id]
    except KeyError:
        raise MetricNotFound(
            'no run named %r; recorded: %s'
            % (run_id, ', '.join(ids()) or '(none)'))


def have(run_id):
    return run_id in _RUNS


def ids():
    """Run ids, in record order."""
    return list(_RUNS)


def runs(object='', tool=''):
    """Runs, oldest first, optionally narrowed to an object and/or a tool."""
    out = []
    for run in _RUNS.values():
        if object and run.object != object:
            continue
        if tool and run.tool != tool:
            continue
        out.append(run)
    return out


def objects():
    """Object names that carry at least one run, in first-record order."""
    seen = []
    for run in _RUNS.values():
        if run.object not in seen:
            seen.append(run.object)
    return seen


def delete(target):
    """Forget a run by id, every run on an object, or all of them.

    Returns how many went. A run id is tried first: ids are generated with a tool
    prefix and could in principle collide with an object name, and the more specific
    reading is the safer one to prefer.
    """
    if target in ('*', 'all'):
        count = len(_RUNS)
        _RUNS.clear()
        return count
    if target in _RUNS:
        del _RUNS[target]
        return 1
    doomed = [run.id for run in _RUNS.values() if run.object == target]
    if not doomed:
        raise MetricNotFound(
            'no run or object named %r; runs: %s' % (target, ', '.join(ids()) or '(none)'))
    for run_id in doomed:
        del _RUNS[run_id]
    return len(doomed)


def rename_object(old, new):
    """Follow an object through `set_name`. Returns how many runs moved.

    Metrics are keyed by object NAME, the way the MSA store keys its target: an object
    can be deleted and recreated, and holding a reference would keep a dead one alive.
    The cost of a name is that a rename orphans it, so cmd.set_name calls this.
    """
    moved = 0
    for run in _RUNS.values():
        if run.object == old:
            run.object = new
            moved += 1
    return moved


def forget_object(name):
    """Drop every run for an object that no longer exists. Returns how many went.

    Called when an object is deleted. Not deferred to a lazy check, because a NEW
    object created under the recycled name would otherwise inherit measurements of a
    structure it has nothing to do with -- silence of exactly the kind this package
    exists to remove.
    """
    doomed = [run.id for run in _RUNS.values() if run.object == name]
    for run_id in doomed:
        del _RUNS[run_id]
    return len(doomed)


def clear():
    """Drop everything. Called when a session is replaced, not when one is saved."""
    _RUNS.clear()


def summaries(objects=None):
    """object name -> [run summary]. The shape a surface reads runs in.

    Scalars only: O(runs x scalar values), touching nothing that was not computed at
    record time. Never walks an array and never asks the session anything -- because
    whatever polls this will do so on the main thread, which is the discipline #271 had
    to restore for the object panel.

    No UI consumes it yet; the panel section was stripped back out of #308 until the
    presentation is settled. `metrics_list` is the current reader.
    """
    wanted = None if objects is None else set(objects)
    out = {}
    for run in _RUNS.values():
        if wanted is not None and run.object not in wanted:
            continue
        out.setdefault(run.object, []).append(run.summary())
    return out


# -- Session round trip --------------------------------------------------------
#
# Arrays go in gzipped and base64'd, for the reason the MSA store gzips an a3m: a PAE
# matrix is the index squared, so a 900-residue prediction is 810 000 numbers. As JSON
# text that is several megabytes and would dominate a .pse; it compresses by roughly an
# order of magnitude. Scalars are written plainly -- they are small, and a .pse a human
# can grep is worth more than the bytes.


def _encode_array(payload):
    return base64.b64encode(
        gzip.compress(json.dumps(payload).encode('utf-8'), 6)).decode('ascii')


def _decode_array(blob):
    return json.loads(gzip.decompress(base64.b64decode(blob)).decode('utf-8'))


def _value_to_entry(entry):
    out = {'key': entry.key, 'scope': entry.scope}
    if entry.state is not None:
        out['state'] = entry.state
    if entry.chain is not None:
        out['chain'] = entry.chain
    if entry.is_array:
        # Index and values travel together in ONE blob. Separating them would let a
        # partial read produce an array whose values had lost their residues, which is
        # the failure this package's explicit index exists to prevent.
        out['array_gz_b64'] = _encode_array(
            {'index': [list(pair) for pair in entry.index], 'values': entry.values})
    else:
        out['value'] = entry.value
    return out


def _entry_to_value(entry):
    scope = entry['scope']
    if 'array_gz_b64' in entry:
        payload = _decode_array(entry['array_gz_b64'])
        return MetricValue(entry['key'], scope,
                           state=entry.get('state'), chain=entry.get('chain'),
                           index=tuple(tuple(pair) for pair in payload['index']),
                           values=payload['values'])
    return MetricValue(entry['key'], scope,
                       state=entry.get('state'), chain=entry.get('chain'),
                       value=entry.get('value'))


def session_save(session, **_kwargs):
    """Session-save task: write the runs into the .pse being written.

    The key is omitted entirely when nothing is recorded, so a session from a user who
    never ran a tool is byte-for-byte what it was before this existed.
    """
    if not _RUNS:
        return 1
    entries = []
    for run in _RUNS.values():
        entries.append({
            'id': run.id,
            'tool': run.tool,
            'tool_version': run.tool_version,
            'object': run.object,
            'created': run.created,
            'states': list(run.states),
            'state_count': run.state_count,
            'note': run.note,
            # JSON rather than the dict, so a future field in a tool's inputs cannot
            # make a .pse unpicklable for an older RayMol. The MSA store's `source`
            # travels the same way and for the same reason.
            'inputs': json.dumps(run.inputs, sort_keys=True, default=str),
            'values': [_value_to_entry(entry) for entry in run.values],
        })
    session[SESSION_KEY] = {'version': SESSION_VERSION, 'runs': entries}
    return 1


def session_restore(session, **_kwargs):
    """Session-restore task: replace the store with what the session carries.

    A session WITHOUT the key clears the store, for the reason the MSA store does:
    opening a session with no metrics must not leave the previous session's lying
    around, attached to objects that are gone.

    Tolerant by construction -- a malformed run is skipped with a warning rather than
    raised, because a restore task that throws takes the whole session load with it.
    The schema is NOT required here: a .pse may carry a run from a tool this build does
    not have (an older predictor, a plugin that is not installed), and dropping those
    numbers because nothing can currently colour by them would lose the very data the
    session was saved to keep.
    """
    clear()
    payload = session.get(SESSION_KEY)
    if not isinstance(payload, dict):
        return 1
    if int(payload.get('version', 0)) > SESSION_VERSION:
        print(' metrics: session carries metric format v%s, this build reads v%d;'
              ' metrics not restored'
              % (payload.get('version'), SESSION_VERSION))
        return 1
    for entry in payload.get('runs') or []:
        try:
            inputs = entry.get('inputs') or '{}'
            _RUNS[entry['id']] = MetricRun(
                entry['id'], entry['tool'], entry['object'],
                [_entry_to_value(value) for value in entry.get('values') or []],
                tool_version=entry.get('tool_version', ''),
                inputs=json.loads(inputs) if isinstance(inputs, str) else inputs,
                states=entry.get('states') or (),
                state_count=entry.get('state_count', 0),
                created=entry.get('created'),
                note=entry.get('note', ''))
        except Exception as exc:
            print(' metrics: could not restore run %r from the session (%s)'
                  % (entry.get('id', '?') if isinstance(entry, dict) else '?', exc))
    return 1
