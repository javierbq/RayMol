"""A running tool delivers into a set (#416).

The shared half of "batch delivery lands in a set", used by `designing.binder_design`
and `predicting.predict`. Both commands submit N jobs to a serial runtime queue and are
told, minutes or hours later, that job k finished by OBJECT NAME: `deliver_result(path,
name, seed)`. That name is the key of every pending table those modules keep, and of the
Swift runtime's own bookkeeping, so it stays the key here too. What changes is that the
name no longer has to be an object for the whole run: a batch of 1000 creates a
placeholder object only for the members that will be STAGED when they land -- the first
`budget` of them -- and the rest are pending with no object at all. The panel poll never
looks for one (`appkit_inspector._pending_maps` iterates `pending_objects()`, the table
keys, and asks `pending_info(name)`, which reads dicts and a job handle), so a member
without an object still has a tray record and can still be cancelled or dismissed.

Three moments, three functions:

  open()    at submit: the set, its reference and ONE run row for the whole invocation
            exist before the first job starts, so the inspector's badge (`running()`) has
            a set id to hang off and a crash five minutes in leaves a set that says what
            was attempted
  expect()  per member at submit: registers the object name the runtime will echo back
            and answers whether a placeholder should be created for it
  land()    per member at delivery, AFTER the object is complete and its metrics run is
            filed: the generation check, the entry write, then -- and only then -- the
            staging decision. The entry is on disk before anything is deleted, so a crash
            mid-batch loses at most the design in flight

Nothing here is reached by a poll except `running()`, which reads process state only.

Spec: docs/superpowers/specs/2026-09-13-sets-batch-delivery-design.md
"""
import sys

from pymol import colorprinting
from pymol.metrics import store as mstore

from . import binding, store
from .errors import SetError, SetInputError, SetNameConflict

cmd = sys.modules['pymol.cmd']

#: Column specs every delivering tool writes beside its MetricSpecs. Declared per tool
#: (the `tool` field is filled in at open), so `set_info` groups them with the run that
#: wrote them; neither is a declared METRIC of any tool, so `binding._write_back_metrics`
#: skips them on stage and `set_set` refuses to edit them, which is right for both.
SEED_SPEC = {'key': 'seed', 'scope': 'object', 'dtype': 'int', 'label': 'Seed',
             'description': 'random seed this entry was generated at'}
MODEL_SPEC = {'key': 'model', 'scope': 'object', 'dtype': 'int', 'label': 'Model',
              'description': 'which model of an n_models run this entry is'}

#: batch id -> _Batch, for every batch with a member still outstanding.
_BATCHES = {}

#: object name -> batch id. One name belongs to one batch; `expect` refuses a second.
_MEMBER = {}


class _Batch:
    """One tool invocation delivering into one set."""

    __slots__ = ('id', 'set_id', 'run_id', 'tool', 'total', 'settled', 'landed',
                 'generation', 'group', 'superpose', 'budget', 'members', 'order',
                 'detached')

    def __init__(self, id, set_id, run_id, tool, total, generation, group, superpose,
                 budget):
        self.id = id
        self.set_id = set_id
        self.run_id = run_id
        self.tool = tool
        self.total = int(total)
        #: Names that have left the run one way or another: landed, failed, cancelled.
        self.settled = set()
        self.landed = 0
        #: `store.generation()` when the set was created. Compared before every write.
        self.generation = generation
        #: Whether staged members join a group named after the set. False for a single
        #: design, whose object stays at the top level exactly as it does today.
        self.group = bool(group)
        #: Whether a staged member is superposed on the set's reference. A prediction
        #: is -- a folding backend returns each model in its own frame. A design is not:
        #: its object holds the target where the target already is.
        self.superpose = bool(superpose)
        #: How many members get a placeholder at submit. Read once here rather than at
        #: every `expect`, so the N-th call costs a dict lookup and not a meta read.
        self.budget = int(budget)
        #: object name -> {'entry', 'parents', 'scalars', 'specs'}
        self.members = {}
        self.order = []
        #: Set once the store changed under the batch. Later members skip the write
        #: without a second warning; the batch leaves `running()`.
        self.detached = False


def _container():
    return store.active()


# -- Naming ----------------------------------------------------------------------------


def name_taken(name, tool=''):
    """True when a set of this name exists and a batch of `tool` may not extend it.

    A set written by the SAME tool is not taken: an identical re-run lands back in the
    set its first run made, as a second run row with more entries, which is what the
    group already did ("adding to it is the whole point") and what a user asking for
    ten more designs like these means. A set of another tool -- or one nobody's batch
    made, when `tool` is '' -- is somebody else's record and is left alone.

    Never raises, never opens a container: a caller deciding a group name must not
    create a working file as a side effect.
    """
    if not store.is_open():
        return False
    try:
        row = _container().get_set(name)
    except SetError:
        return False
    except Exception:
        return False
    return not (tool and row.get('tool') == tool)


def free_name(base, tool='', _self=cmd):
    """`base` legalised and moved aside (`_2`, `_3`, ...) until nothing answers to it:
    no set (other than one of `tool`'s own, see `name_taken`), no object or group, no
    pending name and no live batch.

    The batch id is the set's name AND its group's name, so it has to be free on every
    axis at once. `binding._free_object_name` covers objects; sets and live batches are
    this module's to know about. An existing GROUP is not a collision, for the reason
    `designing._group_name_is_available` gives -- it is what a same-tool set's re-run
    lands back into.
    """
    legal = _self.get_legal_name(str(base))
    groups = set(_self.get_names('public_group_objects') or [])
    candidate, n = legal, 1
    while (name_taken(candidate, tool) or candidate in _BATCHES
           or candidate in (set(_self.get_names('all') or []) - groups)):
        n += 1
        candidate = _self.get_legal_name('%s_%d' % (legal, n))
    return candidate


def free_numbered_name(prefix, _self=cmd):
    """`<prefix>_1`, `<prefix>_2`, ... -- the first free on every axis. What a child set
    of a prediction is called (spec §5): `boltz2_1`."""
    n = 0
    while True:
        n += 1
        candidate = _self.get_legal_name('%s_%d' % (prefix, n))
        if not (name_taken(candidate) or candidate in _BATCHES
                or candidate in (_self.get_names('all') or [])):
            return candidate


def _legal_entry_name(name):
    return store.legal_entry_name(name)


# -- Submit ------------------------------------------------------------------------------


def open(name, tool, tool_version='', inputs=None, total=1, reference='',
         parent_set_id=None, group=True, superpose=False, kind='structures', _self=cmd):
    """Create the set (or reopen `tool`'s own set of that name) and add the run for a
    batch about to be submitted. Returns the batch.

    `name` must already be free for `tool` (`free_name` / `free_numbered_name`): a set
    of another tool under it is a caller's bug and is raised as such rather than moved
    aside silently, because the caller has already promised that name to its
    placeholders and its tray row. A set this tool made earlier is EXTENDED -- a second
    run row, entries appended, the reference kept -- which is what an identical re-run
    landing back in its group has always meant.
    """
    c = _container()
    name = str(name)
    if name in _BATCHES:
        raise SetNameConflict('a batch named %r is already running' % name)
    generation = store.generation()
    try:
        set_row = c.get_set(name)
    except SetError:
        set_row = None
    if set_row is None:
        set_row = c.create_set(name, kind=kind, tool=tool, group_name=name)
        if reference:
            c.update_set(set_row['id'], reference=str(reference))
            set_row = c.get_set(set_row['id'])
    elif set_row.get('tool') != tool:
        raise SetNameConflict('set %r belongs to %s, not %s; pick another name'
                              % (name, set_row.get('tool') or 'no tool', tool))
    run_id = c.add_run(set_row['id'], tool, tool_version=tool_version,
                       inputs=dict(inputs or {}), parent_set_id=parent_set_id)
    batch = _Batch(name, set_row['id'], run_id, tool, total, generation, group,
                   superpose, binding.budget(set_row))
    _BATCHES[name] = batch
    return batch


def expect(batch, object_name, entry_name='', parents=(), scalars=None, specs=()):
    """Register a member the runtime will deliver as `object_name`. Returns True when a
    placeholder object should be created for it: the first `budget` members, which are
    the ones that will be staged when they land, get one; the rest are pending without
    an object (spec §1).

    `entry_name` defaults to the object name; `scalars`/`specs` are extra columns to
    write beside the metrics (`SEED_SPEC`, `MODEL_SPEC`); `parents` are entry ids.
    """
    if object_name in _MEMBER:
        raise SetInputError('%r is already expected by batch %r'
                            % (object_name, _MEMBER[object_name]))
    tool_specs = []
    for spec in specs or ():
        record = dict(spec)
        record.setdefault('tool', batch.tool)
        tool_specs.append(record)
    batch.members[object_name] = {
        'entry': _legal_entry_name(entry_name or object_name),
        'parents': [str(p) for p in parents or ()],
        'scalars': dict(scalars or {}),
        'specs': tool_specs,
    }
    batch.order.append(object_name)
    _MEMBER[object_name] = batch.id
    return len(batch.order) <= batch.budget


def is_running(name):
    """True while a batch called `name` has members outstanding."""
    return name in _BATCHES


def batch_of(object_name):
    """The batch expecting `object_name`, or None."""
    batch_id = _MEMBER.get(object_name)
    return None if batch_id is None else _BATCHES.get(batch_id)


# -- Delivery ----------------------------------------------------------------------------


def _check_generation(batch):
    if batch.generation != store.generation():
        batch.detached = True
        raise SetError(
            'the set document changed while batch %s was running (a .raymol or .pse'
            ' was loaded, or the session was reset); its remaining results land as'
            ' plain objects in the group %s and are not written to any set'
            % (batch.id, batch.id))


def land(object_name, state=None, _self=cmd):
    """Write the object that just landed under `object_name` as an entry of its batch's
    set, then stage it or discard it. Returns None when the name is not a batch member
    (or its batch detached), else `{'set_id', 'entry_id', 'staged'}`.

    Called AFTER the object is complete and its metrics run is filed: the entry is
    captured from the object (chains, sequences) and from the metrics store (columns),
    so both have to be there. Raises SetError -- once -- when the store changed under the
    batch; the caller keeps the object as it would have without a set.

    Order inside is the point: the entry is on disk BEFORE the staging decision, and the
    staging decision deletes nothing until the write has committed.
    """
    batch = batch_of(object_name)
    if batch is None or batch.detached:
        return None
    member = batch.members[object_name]
    _check_generation(batch)
    c = _container()
    n_states = max(1, int(_self.count_states(object_name) or 1))
    which = n_states if state is None else int(state)
    entry_name = binding._unique_entry_name(c, batch.set_id, member['entry'])
    ids = binding.capture_object(batch.set_id, object_name, name=entry_name,
                                 run_id=batch.run_id, parents=member['parents'],
                                 states=which, scalars=member['scalars'],
                                 specs=member['specs'], _self=_self)
    entry_id = ids[0]
    batch.landed += 1
    staged = _stage_or_discard(batch, c, entry_id, object_name, _self=_self)
    _settle(batch, object_name)
    return {'set_id': batch.set_id, 'entry_id': entry_id, 'staged': staged}


def _stage_or_discard(batch, c, entry_id, object_name, _self=cmd):
    """Keep the delivered object as the entry's staged object if the set has room,
    else delete it. Decided from the LIVE staged count, not from the member's index, so
    a failed member frees its slot and a user who unstaged mid-batch gets it refilled.

    A staged design is not superposed: it holds the target where the target is. A
    staged prediction is, when the set has a reference, for the reason `binding.stage`
    superposes -- a folding backend returns each model in its own frame.
    """
    set_row = c.get_set(batch.set_id)
    staged_now = len(binding._staged(c, batch.set_id, _self=_self))
    if staged_now >= binding.budget(set_row):
        try:
            mstore.forget_object(object_name)
        except Exception:
            pass
        _self.delete(object_name)
        return False
    if batch.group:
        group = set_row.get('group_name') or set_row['name']
        try:
            binding._ensure_group(group, _self=_self)
            _self.group(group, object_name, 'add', quiet=1)
        except Exception as exc:
            colorprinting.warning(' sets: could not add %s to the group %s (%s); it is'
                                  ' at the top level instead' % (object_name, group, exc))
    if batch.superpose and set_row.get('reference'):
        binding._superpose(object_name, set_row['reference'], _self=_self)
    c.update_entry(entry_id, staged_object=object_name)
    return True


# -- Settling ------------------------------------------------------------------------------


def settle(object_name):
    """A member left the run without landing (failed, cancelled, dismissed). Idempotent:
    `discard_pending` reaches a name more than once on some paths."""
    batch = batch_of(object_name)
    if batch is not None:
        _settle(batch, object_name)


def _settle(batch, object_name):
    if object_name in batch.settled:
        return
    batch.settled.add(object_name)
    if len(batch.settled) >= batch.total and len(batch.settled) >= len(batch.order):
        _reap(batch)


def _reap(batch):
    """Forget a batch whose every member has settled. A batch that landed NOTHING
    deletes its empty set, as today's batch deletes its empty group: a cancelled
    campaign leaves nothing behind. Never touches a store that changed under it."""
    for name in batch.order:
        _MEMBER.pop(name, None)
    _BATCHES.pop(batch.id, None)
    if batch.detached or batch.landed or batch.generation != store.generation():
        return
    try:
        c = _container()
        if c.count(batch.set_id) == 0:
            c.delete_set(batch.set_id)
    except Exception:
        pass


def abandon(batch):
    """A submit that failed part-way: forget the batch and, if nothing landed, its set.
    For the `except` around a submit loop, so a refused member never leaves a set that
    promises designs no job was started for."""
    if batch is None or batch.id not in _BATCHES:
        return
    _reap(batch)


def clear():
    """Forget every batch. For `clear_pending` and tests; the store is reset separately."""
    _BATCHES.clear()
    _MEMBER.clear()


# -- The contract with the UI (#417) ---------------------------------------------------


def running(set_id=None):
    """{set_id: {'done': int, 'total': int, 'tool': str}} for every set whose batch is
    still landing; {} when none. Never raises.

    Polled every 500 ms from `appkit_sets.py`, so it is a dict walk and nothing else:
    no SQL, no session. `done` counts members that have SETTLED -- landed, failed or
    cancelled alike -- so it reaches `total` when the batch is over; how many actually
    landed is the set's entry count, which the UI reads from the file. A batch leaves
    this map when its last member settles or when the store changed under it.
    """
    try:
        out = {}
        for batch in _BATCHES.values():
            if batch.detached:
                continue
            if set_id is not None and batch.set_id != set_id:
                continue
            out[batch.set_id] = {'done': len(batch.settled), 'total': batch.total,
                                 'tool': batch.tool}
        return out
    except Exception:
        return {}
