"""A running tool delivers into a set (#416).

The shared half of "batch delivery lands in a set", used by `designing.binder_design`,
`predicting.predict` and `designing_sequences.design_sequences`. Each submits N jobs to a
serial runtime queue and is
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

`land_sequence()` is `land`'s sibling for a member that HAS no object: `design_sequences`
delivers N sequences per backbone and a designed sequence is a `kind='sequences'` entry
with no structure blob until something folds it (#453). Same batch, same identity check,
same settle -- only the source of the entry differs, and there is nothing to stage.

Nothing here is reached by a poll except `running()`, which reads process state only.

Spec: docs/superpowers/specs/2026-09-13-sets-batch-delivery-design.md,
docs/superpowers/specs/2026-09-16-sets-sequence-design-design.md
"""
import atexit
import os
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
             'role': 'provenance',
             'description': 'random seed this entry was generated at'}
MODEL_SPEC = {'key': 'model', 'scope': 'object', 'dtype': 'int', 'label': 'Model',
              'role': 'provenance',
              'description': 'which model of an n_models run this entry is'}
SEQUENCE_SPEC = {'key': 'sequence_n', 'scope': 'object', 'dtype': 'int',
                 'label': 'Sequence', 'role': 'provenance',
                 'description': 'which sequence of an n_sequences design run this entry'
                                ' is (#453)'}

#: batch id -> _Batch, for every batch with a member still outstanding.
_BATCHES = {}

#: object name -> batch id. One name belongs to one batch; `expect` refuses a second.
_MEMBER = {}


class _Batch:
    """One tool invocation delivering into one set."""

    __slots__ = ('id', 'set_id', 'run_id', 'tool', 'total', 'settled', 'landed',
                 'group', 'superpose', 'slots', 'members', 'order', 'detached',
                 'quiet_end', 'home', 'away', 'hold')

    def __init__(self, id, set_id, run_id, tool, total, group, superpose, slots,
                 home=''):
        self.id = id
        self.set_id = set_id
        self.run_id = run_id
        self.tool = tool
        self.total = int(total)
        #: Names that have left the run one way or another: landed, failed, cancelled.
        self.settled = set()
        self.landed = 0
        #: Whether staged members join a group named after the set. False for a single
        #: design, whose object stays at the top level exactly as it does today.
        self.group = bool(group)
        #: Whether a staged member is superposed on the set's reference. A prediction
        #: is -- a folding backend returns each model in its own frame. A design is not:
        #: its object holds the target where the target already is.
        self.superpose = bool(superpose)
        #: How many members get a placeholder at submit: the set's FREE stage slots
        #: when the batch opened (budget less what a set being extended already has
        #: staged), so a re-run into a full set creates no placeholder it would then
        #: have to delete. Read once here rather than at every `expect`.
        self.slots = int(slots)
        #: object name -> {'entry', 'parents', 'scalars', 'specs'}
        self.members = {}
        self.order = []
        #: Set once the store changed under the batch. Later members skip the write
        #: without a second warning; the batch leaves `running()`.
        self.detached = False
        #: Set by `quiesce` when the batch is being torn down rather than finishing
        #: (`clear_pending`): its end is not a run's end, so nothing is restaged.
        self.quiet_end = False
        #: Where this batch's set and run LIVE: the path of the container it opened
        #: in, followed through Save As (`installed`) and through the working file
        #: being kept under a recovered_ name (`moved`). When the session is replaced
        #: under the batch, later results are written back here (#448).
        self.home = os.path.abspath(home) if home else ''
        #: True while `home` is not the active container: the batch is writing into a
        #: document nobody has open, so it is not this session's badge.
        self.away = False
        #: The home Container, held OPEN for as long as the batch is away (#448 review).
        #: Not for speed: an open connection keeps SQLite's -wal/-shm beside the file,
        #: which is what ANOTHER RayMol's sweep, recovery offer and Discard read as "in
        #: use" (`store._has_sidecar`) -- a per-process registry cannot tell them.
        self.hold = None


def _container():
    return store.active()


# -- Naming ----------------------------------------------------------------------------


def name_taken(name, tool='', reference='', need_slot=False, _self=cmd):
    """True when a set of this name exists and a batch of `tool` may not extend it.

    A set written by the SAME tool against the SAME reference is not taken: an
    identical re-run lands back in the set its first run made, as a second run row with
    more entries, which is what the group already did ("adding to it is the whole
    point") and what a user asking for ten more designs like these means. Taken, and
    left alone, when: another tool wrote it (or nobody's batch did, when `tool` is '');
    it was built against a different reference (`predict set:` would superpose the new
    designs on the OLD target -- measured); or `need_slot` and it has no free stage slot
    (a single design extending a full set would land, be measured, and then have its
    object deleted, which for `n_designs=1` breaks "indistinguishable from today").

    Never raises, never opens a container: a caller deciding a group name must not
    create a working file as a side effect.
    """
    if not store.is_open():
        return False
    try:
        c = _container()
        row = c.get_set(name)
    except SetError:
        return False
    except Exception:
        return False
    if not tool or row.get('tool') != tool:
        return True
    if reference and row.get('reference') and row.get('reference') != reference:
        return True
    if need_slot:
        try:
            staged = len(binding._staged(c, row['id'], _self=_self))
            return staged >= binding.budget(row)
        except Exception:
            return True
    return False


def free_name(base, tool='', reference='', need_slot=False, _self=cmd):
    """`base` legalised and moved aside (`_2`, `_3`, ...) until nothing answers to it:
    no set (other than one of `tool`'s own this batch may extend, see `name_taken`), no
    object or group, no pending name and no live batch.

    The batch id is the set's name AND its group's name, so it has to be free on every
    axis at once. `binding._free_object_name` covers objects; sets and live batches are
    this module's to know about. An existing GROUP is not a collision, for the reason
    `designing._group_name_is_available` gives -- it is what a same-tool set's re-run
    lands back into.
    """
    legal = _self.get_legal_name(str(base))
    groups = set(_self.get_names('public_group_objects') or [])
    candidate, n = legal, 1
    while (name_taken(candidate, tool, reference, need_slot, _self=_self)
           or candidate in _BATCHES
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
    elif reference and set_row.get('reference') and set_row['reference'] != reference:
        raise SetNameConflict('set %r was built against %s, not %s; pick another name'
                              % (name, set_row['reference'], reference))
    run_id = c.add_run(set_row['id'], tool, tool_version=tool_version,
                       inputs=dict(inputs or {}), parent_set_id=parent_set_id)
    # Free stage slots NOW, not the budget: a set being extended may already hold
    # staged objects, and a placeholder for a member that could never be staged is a
    # finished design deleted in front of the user.
    #
    # ZERO for a set that is not `structures` (#453): staging means "keep the delivered
    # object", and a designed SEQUENCE has no object at any point -- so a placeholder
    # would be an empty object that nothing ever loads into. Read off the set row rather
    # than off the caller, so a batch extending an existing sequences set gets the same
    # answer as the one that created it.
    if (set_row.get('kind') or 'structures') != 'structures':
        slots = 0
    else:
        staged_now = len(binding._staged(c, set_row['id'], _self=_self))
        slots = max(binding.budget(set_row) - staged_now, 0)
    batch = _Batch(name, set_row['id'], run_id, tool, total, group, superpose, slots,
                   home=c.path)
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
    return len(batch.order) <= batch.slots


def is_running(name):
    """True while a batch called `name` has members outstanding."""
    return name in _BATCHES


def batch_of(object_name):
    """The batch expecting `object_name`, or None."""
    batch_id = _MEMBER.get(object_name)
    return None if batch_id is None else _BATCHES.get(batch_id)


# -- Delivery ----------------------------------------------------------------------------


def _still_ours(batch):
    """True while the active container holds this batch's run in this batch's set.

    IDENTITY, not a counter. `store.generation()` bumps on every `replace`, and Save As
    from an untitled session (`save x.raymol`) is a replace -- the same document, moved
    -- so a counter check detached a batch on the very flow the docs recommend
    (measured: deliver 1, save, deliver 3 -> three plain objects and an empty
    `running()`). Ids are token_hex(4), so a run id resolving to the right set in
    whatever container is open now IS the document the batch was writing into.
    """
    if not store.is_open():
        return False
    try:
        c = _container()
        run = c.run(batch.run_id)
    except Exception:
        return False
    if run.get('set_id') != batch.set_id:
        return False
    # The same ids in ANOTHER file -- a Finder duplicate of the document the batch left
    # -- are not its document (#448 review): an away batch only comes back to its own.
    if batch.away and not _is_home(c.path, batch.home):
        return False
    return True


def _detach(batch):
    batch.detached = True
    _release_hold(batch)
    raise SetError(
        'the set document changed while batch %s was running (a .raymol or .pse'
        ' was loaded, or the session was reset), and the document it was writing into'
        ' (%s) cannot be written any more; its remaining results land as plain objects'
        ' in the group %s and are not written to any set'
        % (batch.id, batch.home or 'none', batch.id))


def _open_home(batch):
    """The batch's own container, opened on the side, when the session was replaced
    under it (#448) -- or None when that cannot be done safely.

    Safely means: the file is still there (a Container on a missing path would CREATE
    one, and results would go into a file nobody knows about), it is not the active
    container (then `_still_ours` would have said so), and the batch's run resolves to
    the batch's set in it. That last check is the same identity `_still_ours` uses, so
    a pid-scoped working name reused by a new session can never be mistaken for it.
    """
    path = batch.home
    if not path or not os.path.isfile(path):
        return None
    if store.is_open():
        try:
            if os.path.samefile(path, _container().path):
                return None
        except OSError:
            pass
    try:
        c = store.Container(path)
    except Exception:
        return None
    try:
        ok = c.run(batch.run_id).get('set_id') == batch.set_id
    except Exception:
        ok = False
    if not ok:
        c.close()
        return None
    return c


def _home_container(batch):
    """The held home Container of an away batch, opening (and holding) it on first
    use; None when `_open_home` refuses."""
    c = batch.hold
    if c is not None and not c.closed and _same(c.path, batch.home) \
            and _identity(batch.home) == getattr(c, '_raymol_identity', None):
        return c
    # Gone, replaced or never opened. A connection to a file that was unlinked (or
    # replaced) under it would write into an inode nobody can reach, silently -- the
    # failure #447's review found -- so a held connection is only reused while the
    # path still names the very file it was opened on.
    _release_hold(batch)
    c = _open_home(batch)
    if c is not None:
        c._raymol_identity = _identity(batch.home)
    batch.hold = c
    return c


def _identity(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def _release_hold(batch):
    """Checkpoint and close the held home connection. When the file was MOVED under
    it (Finder), SQLite leaves the -wal/-shm behind at the old name on close; once the
    checkpoint has folded them into the moved main file they are empty debris beside a
    file that no longer exists, and are removed (#448 review round 2)."""
    c, batch.hold = batch.hold, None
    if c is None:
        return
    path = c.path
    folded = c.checkpoint()
    try:
        c.close()
    except Exception:
        pass
    if folded and not os.path.exists(path):
        for extra in ('-wal', '-shm'):
            try:
                os.unlink(path + extra)
            except OSError:
                pass


def is_away(object_name):
    """True when `object_name` is a member of a live batch whose session was replaced
    under it (#448) -- and STAYS true once the batch has detached, because what makes
    the name unsafe is the replaced scene, not whether the batch can still write (#448
    review round 2). Not true after `set_delete` of the batch's set in its own session:
    the scene is still the batch's, and its placeholders are still its own.
    Its result belongs to a document that is not the open one, so the
    delivering tool must not load it into, read it from, or delete anything by that
    name in THIS scene -- the name may well be the user's own object here. The caller
    loads the result into a scratch object and hands that to `land(..., source=)`."""
    batch = batch_of(object_name)
    return batch is not None and bool(batch.away)


def _left_behind(batch, object_name, entry_name, _self=cmd):
    """Say where a result that landed in a document nobody has open went. Said every
    time, for the reason `_stage_or_discard` says its line: a finished design that does
    not appear in the scene with nothing on the console looks lost."""
    colorprinting.parrot(
        ' sets: %s landed as entry %s of %s in %s, which is not the open session;'
        ' "load" that file to see it.' % (object_name, entry_name, batch.id, batch.home))


def land(object_name, state=None, source=None, _self=cmd):
    """Write the object that just landed under `object_name` as an entry of its batch's
    set, then stage it or discard it. Returns None when the name is not a batch member
    (or its batch detached), else `{'set_id', 'entry_id', 'staged'}`.

    Called AFTER the object is complete and its metrics run is filed: the entry is
    captured from the object (chains, sequences) and from the metrics store (columns),
    so both have to be there. Raises SetError -- once -- when the store changed under the
    batch; the caller keeps the object as it would have without a set.

    Order inside is the point: the entry is on disk BEFORE the staging decision, and the
    staging decision deletes nothing until the write has committed.

    `source` is the scratch object an AWAY delivery was loaded into (`is_away`): when
    the batch's session was replaced, the entry is captured from it and it -- never
    `object_name` -- is what leaves the scene. An away landing without one is refused
    before anything is read or deleted.
    """
    batch = batch_of(object_name)
    if batch is None or batch.detached:
        return None
    member = batch.members[object_name]
    if not _still_ours(batch):
        if _home_container(batch) is None:
            _detach(batch)
        if not source:
            raise SetInputError(
                '%s belongs to batch %s, whose session was replaced; its result must be'
                ' delivered into a scratch object, not into %r in this scene'
                % (object_name, batch.id, object_name))
        return _land_away(batch, object_name, member, source, _self=_self)
    n_states = max(1, int(_self.count_states(object_name) or 1))
    which = n_states if state is None else int(state)
    c = _container()
    batch.away = False
    entry_name = binding._unique_entry_name(c, batch.set_id, member['entry'])
    ids = binding.capture_object(batch.set_id, object_name, name=entry_name,
                                 run_id=batch.run_id, parents=member['parents'],
                                 states=which, scalars=member['scalars'],
                                 specs=member['specs'], _self=_self)
    entry_id = ids[0]
    batch.landed += 1
    # The entry is on disk. From here a failure is "written, not staged", which the
    # caller must hear as such: reporting it as "not written" sent a design into the
    # batch group with no staged link behind it.
    try:
        staged = _stage_or_discard(batch, c, entry_id, entry_name, object_name,
                                   _self=_self)
    except Exception as exc:
        colorprinting.warning(
            ' sets: %s is written to %s as entry %s but could not be staged (%s); the'
            ' object is left where it is, unlinked' % (object_name, batch.id, entry_name, exc))
        staged = False
    _settle(batch, object_name)
    if staged and batch.id not in _BATCHES:
        # This was the last member, and the end-of-run restage (#546) may just have
        # replaced it: say what is true now.
        try:
            staged = bool(c.entry_by_id(entry_id).get('staged_object'))
        except Exception:
            pass
    return {'set_id': batch.set_id, 'entry_id': entry_id, 'staged': staged,
            'entry': entry_name}


def _land_away(batch, object_name, member, source, _self=cmd):
    """`land` for a batch whose session was replaced under it (#448): the entry is
    written into the batch's OWN container -- the untitled session's file, now kept
    under a recovered_ name, or the user's document, now closed -- from the scratch
    object `source` the caller loaded the result into, and only `source` leaves the
    scene.

    Why not leave the result in the new scene, as #445 did: that scene is not the
    campaign's. An object dropped into it is written to no set, is saved into the wrong
    document if that one is saved, and is simply gone at quit if it is not -- and the
    campaign's own file, the one the recovery flow offers back, would be missing every
    design that landed after the load.

    Why a scratch object and never `object_name` (#448 review): member names repeat
    across runs (`name_01..NN`, a design-key digest), so the new session may hold the
    USER'S object under exactly that name; loading into it merges atoms, and deleting it
    destroys their work. Nothing here reads the active container either: `into=` skips
    the staged-complex lookup, which would consult an unrelated document.

    Falls back to #445's behaviour, once, when that file cannot be written any more
    (deleted, moved, unreadable): SetError, and the caller keeps the scratch as a
    plain object under a free name.
    """
    c = _home_container(batch)
    if c is None:
        _detach(batch)
    batch.away = True
    n_states = max(1, int(_self.count_states(source) or 1))
    entry_name = binding._unique_entry_name(c, batch.set_id, member['entry'])
    ids = binding.capture_object(batch.set_id, source, name=entry_name,
                                 run_id=batch.run_id, parents=member['parents'],
                                 states=n_states, scalars=member['scalars'],
                                 specs=member['specs'], into=c, _self=_self)
    entry_id = ids[0]
    batch.landed += 1
    # The main file alone must hold it: the hold keeps a WAL connection open for hours.
    c.checkpoint()
    # On disk in the batch's file: only now may the scratch leave the scene.
    try:
        mstore.forget_object(source)
    except Exception:
        pass
    try:
        _self.delete(source)
    except Exception:
        pass
    _left_behind(batch, object_name, entry_name, _self=_self)
    _settle(batch, object_name)
    return {'set_id': batch.set_id, 'entry_id': entry_id, 'staged': False,
            'entry': entry_name, 'path': batch.home}


def land_sequence(member_name, sequences, scalars=None, arrays=(), specs=(), _self=cmd):
    """Write a member that has no object -- a DESIGNED SEQUENCE (#453) -- as an entry of
    its batch's set. Returns None when the name is not a member (or its batch detached),
    else `{'set_id', 'entry_id', 'staged': False, 'entry'}`.

    The sibling of `land`, not a second delivery path: same batch, same `_still_ours`
    identity check, same settle and the same reap. What differs is where the entry comes
    FROM. `land` captures one out of the session (`binding.capture_object` reads chains
    and sequences off an object and its metrics runs); a designed sequence has no object
    and never will -- it is a `kind='sequences'` entry with no structure blob until
    something folds it -- so the entry is written straight from what the runtime returned.

    Nothing is staged, for the same reason: staging keeps the delivered object, and there
    is none. `open` already gave a non-structures set zero stage slots, so no member of
    such a batch was promised a placeholder either.

    `sequences` is {chain: one-letter}; `scalars` and `arrays` are merged over what
    `expect` recorded for this member, so a caller may register what it knows at submit
    (the seed, which sequence of the run this is) and add what it learns at delivery.
    """
    batch = batch_of(member_name)
    if batch is None or batch.detached:
        return None
    member = batch.members[member_name]
    away = not _still_ours(batch)
    if away:
        # The session was replaced under the batch (#448): the sequence goes into the
        # batch's own container, as `_land_away` does for a structure. There is no
        # object to take out of the scene.
        c = _home_container(batch)
        if c is None:
            _detach(batch)
        batch.away = True
    else:
        c = _container()
        batch.away = False
    return _write_sequence(batch, c, member_name, member, sequences, scalars,
                           arrays, specs, away)


def _write_sequence(batch, c, member_name, member, sequences, scalars, arrays, specs,
                    away):
    entry_name = binding._unique_entry_name(c, batch.set_id, member['entry'])
    all_scalars = dict(member['scalars'])
    all_scalars.update(dict(scalars or {}))
    all_specs = list(member['specs'])
    for spec in specs or ():
        record = dict(spec)
        record.setdefault('tool', batch.tool)
        all_specs.append(record)
    entry_id = c.add_entry(batch.set_id, entry_name, run_id=batch.run_id,
                           sequences=dict(sequences or {}),
                           parents=member['parents'], chains=(),
                           scalars=all_scalars, arrays=list(arrays or ()),
                           specs=all_specs)
    batch.landed += 1
    if away:
        c.checkpoint()
        _left_behind(batch, member_name, entry_name)
    _settle(batch, member_name)
    out = {'set_id': batch.set_id, 'entry_id': entry_id, 'staged': False,
           'entry': entry_name}
    if away:
        out['path'] = batch.home
    return out


def _stage_or_discard(batch, c, entry_id, entry_name, object_name, _self=cmd):
    """Keep the delivered object as the entry's staged object if the set has room,
    else delete it. Decided from the LIVE staged count, not from the member's index, so
    a failed member frees its slot and a user who unstaged mid-batch gets it refilled.

    A staged design is not superposed: it holds the target where the target is. A
    staged prediction is, when the set has a reference, for the reason `binding.stage`
    superposes -- a folding backend returns each model in its own frame.
    """
    set_row = c.get_set(batch.set_id)
    staged_now = len(binding._staged(c, batch.set_id, _self=_self))
    limit = binding.budget(set_row)
    if staged_now >= limit:
        try:
            mstore.forget_object(object_name)
        except Exception:
            pass
        _self.delete(object_name)
        # Said, always: a finished design leaving the scene with an empty console
        # looks like a lost design. Not gated on `quiet` -- delivery has none to read.
        colorprinting.parrot(
            ' sets: %s landed as entry %s of %s (%d of %d staged; budget full).'
            ' "set_stage %s, %s" shows it.'
            % (object_name, entry_name, set_row['name'], staged_now, limit,
               set_row['name'], entry_name))
        return False
    if batch.group:
        group = set_row.get('group_name') or set_row['name']
        try:
            binding._ensure_group(group, _self=_self)
            _self.group(group, object_name, 'add', quiet=1)
        except Exception as exc:
            colorprinting.warning(' sets: could not add %s to the group %s (%s); it is'
                                  ' at the top level instead' % (object_name, group, exc))
    # Placed and linked by the same rule `binding.stage` uses (#545): a grouped member
    # whose target is the run's one shared target keeps only its design chain(s), FIT
    # onto that target; otherwise superposed on the reference when this batch
    # superposes. A single design (no group) stays whole, as it looks without sets.
    binding.place(c, set_row, c.entry_by_id(entry_id), object_name,
                  superpose=batch.superpose, allow_split=batch.group, _self=_self)
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
    campaign leaves nothing behind. Never touches a store that changed under it.

    A batch that landed something has FINISHED, and its set's staging follows the
    ranking from here (#546, `_restage`)."""
    for name in batch.order:
        _MEMBER.pop(name, None)
    _BATCHES.pop(batch.id, None)
    _release_hold(batch)
    if batch.detached or not _still_ours(batch):
        return
    if batch.landed:
        _restage(batch)
        return
    try:
        c = _container()
        if c.count(batch.set_id) == 0:
            c.delete_set(batch.set_id)
    except Exception:
        pass


def _restage(batch):
    """The end of a run (#546): while it ran, members were staged as they landed into
    whatever slots were free -- the first to ARRIVE, not the best. Now that every
    member has settled, `binding.restage_by_ranking` replaces those provisional stages
    with the top of the set by its ranking key, leaving pinned and hand-staged entries
    alone, and says so in one line (console, and the drawer's notice strip).

    A run that was CANCELLED part-way is still restaged, over what landed: its designs
    are as real as a finished run's and were staged in the same arbitrary order, so
    leaving the first arrivals in view would be the same problem with fewer entries.

    Skipped when the batch made no group (a single design stays exactly where it lands,
    as it does without sets) and when a teardown ended it (`quiesce`). Never raises:
    the run is over and every design is on disk whatever happens here.
    """
    if not batch.group or batch.quiet_end:
        return
    try:
        c = _container()
        set_row = c.get_set(batch.set_id)
        result = binding.restage_by_ranking(set_row, _self=cmd)
    except Exception as exc:
        colorprinting.warning(' sets: %s finished, but its staging could not follow the'
                              ' ranking (%s); what is staged stays as it landed'
                              % (batch.id, exc))
        return
    if result and result.get('text'):
        colorprinting.parrot(' sets: %s -- %s.' % (set_row['name'], result['text']))
        try:
            c.set_notice(batch.set_id, {'kind': 'restage', 'text': result['text']})
        except Exception:
            pass


def quiesce():
    """Mark every live batch as ending by teardown, not by finishing: for the
    `clear_pending` loops, which settle each member on the way out and would otherwise
    restage a set in the middle of a reset."""
    for batch in _BATCHES.values():
        batch.quiet_end = True


def abandon(batch):
    """A submit that failed part-way: forget the batch and, if nothing landed, its set.
    For the `except` around a submit loop, so a refused member never leaves a set that
    promises designs no job was started for."""
    if batch is None or batch.id not in _BATCHES:
        return
    _reap(batch)


def clear():
    """Forget every batch. For `clear_pending` and tests; the store is reset separately."""
    for batch in list(_BATCHES.values()):
        _release_hold(batch)
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
            if batch.detached or batch.away:
                continue
            if set_id is not None and batch.set_id != set_id:
                continue
            out[batch.set_id] = {'done': len(batch.settled), 'total': batch.total,
                                 'tool': batch.tool, 'landed': batch.landed}
        return out
    except Exception:
        return {}


# -- Following the document (#448) -------------------------------------------------------


def _same(a, b):
    # realpath: macOS's $TMPDIR is /var/... and also /private/var/... (#447's note).
    return bool(a) and bool(b) and os.path.realpath(a) == os.path.realpath(b)


def _is_home(path, home):
    """`path` is the batch's home file itself, or the home is gone (moved in Finder)
    and `path` is the only candidate left."""
    if not home or not os.path.exists(home):
        return True
    try:
        return os.path.samefile(path, home)
    except OSError:
        return _same(path, home)


def _observe(event, container=None, path=None, old=None, new=None, **_):
    """The store's observer (store.observe): keep each batch's `home` pointing at the
    file its set and run are in, and answer "who is still writing to this file".

    Cheap on purpose -- `installed` is one indexed lookup per live batch, and a store
    change is not on any poll. `running()` itself still reads nothing but these dicts.
    """
    if event == 'installed':
        for batch in list(_BATCHES.values()):
            ours = False
            if container is not None and not container.closed:
                try:
                    ours = container.run(batch.run_id).get('set_id') == batch.set_id
                except Exception:
                    ours = False
            if ours and batch.away and not _is_home(container.path, batch.home):
                # The run resolves, but in ANOTHER file: a Finder duplicate of the home
                # document carries the same set and run ids (#448 review). A batch that
                # is away only goes back to the file it left -- or, when that is gone,
                # to what is plainly the same document moved. Save As, which is the
                # legitimate "same document, new path", happens while the batch is
                # ATTACHED, and is handled below.
                ours = False
            if ours:
                # Save As, or the batch's own file opened again -- or, for a batch
                # that detached because its file was MOVED, the moved file (#448
                # review round 2; the main file is complete, see `checkpoint`): it is
                # home, and the batch is this session's again.
                _release_hold(batch)
                batch.home = os.path.abspath(container.path)
                batch.away = False
                batch.detached = False
            else:
                batch.away = True
        return None
    if event == 'moved':
        for batch in _BATCHES.values():
            if _same(batch.home, old):
                _release_hold(batch)
                batch.home = os.path.abspath(new)
        return None
    if event == 'opening':
        ident = _identity(path) if path else None
        for batch in list(_BATCHES.values()):
            c = batch.hold
            if c is None or c.closed:
                continue
            # The same file under ANOTHER name only: a second connection by the same
            # path shares the -wal and is ordinary SQLite concurrency.
            if ident is not None and not _same(c.path, path) \
                    and ident == getattr(c, '_raymol_identity', None):
                _release_hold(batch)
        return None
    if event in ('kept', 'left'):
        # Hold the file from now on, not from the first late result: a batch that has
        # landed nothing yet still owns a file another RayMol must not sweep (#448
        # review). After the rename, so the connection is on the final name.
        for batch in _BATCHES.values():
            if not batch.detached and batch.away and _same(batch.home, path):
                _home_container(batch)
        return None
    if event == 'writers':
        return [batch.id for batch in _BATCHES.values()
                if not batch.detached and _same(batch.home, path)
                and len(batch.settled) < max(batch.total, len(batch.order))]
    return None


store.observe(_observe)


def release_all():
    """Checkpoint and close every away batch's held home container. For the way out
    (atexit here, and the app's applicationWillTerminate, which may never reach Python's
    atexit): the -wal must be folded in and the sidecars gone, or the file a batch was
    writing into is left looking busy to the next launch (#448 review round 2)."""
    for batch in list(_BATCHES.values()):
        _release_hold(batch)


atexit.register(release_all)
