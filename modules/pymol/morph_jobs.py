'''
morph_jobs — the morph job layer behind the Object panel's Morph action.

Building blocks (naming, estimation, validation, look copy, titles,
fingerprint) plus the job pipeline: start_job() snapshots a multi-state source
on the main thread, MorphJob.step() computes one leg of frames without touching
cmd (on a daemon worker thread for async morphs), and pump() lands computed
frames on the main thread within a time budget.  The pending surface
(pending_objects / recent_objects / pending_info) feeds the progress tray with
the same record shape designing.pending_info publishes.

The embedded core is main-thread only: everything that touches cmd happens in
start_job, pump, morph_cancel, morph_dismiss or morph_object.  A worker shares
only its MorphJob with the main thread: the job's state, error, done_legs and
snapshot change under ``job._lock``, finished legs travel through a
``queue.Queue``, and ``job._cancel`` (a threading.Event) stops the worker.  The
worker holds at most _LEGS_AHEAD computed legs that have not landed
(``job._held``, ``job._room``), and pump() waits for the leg it is computing
within what its budget has left once the frames it landed are built.

Convention: only alt ''+A atoms are counted (consistent with morphing.py).
'''

import binascii
import queue
import re
import sys
import threading
import time

import pymol
from pymol import morphing

cmd = __import__("sys").modules["pymol.cmd"]

# --------------------------------------------------------------------------
# Platform memory thresholds
# --------------------------------------------------------------------------

def _platform_warn():
    return 100e6 if sys.platform == 'ios' else 200e6


def _platform_refuse():
    return 400e6 if sys.platform == 'ios' else 1e9


WARN_BYTES = _platform_warn()
REFUSE_BYTES = _platform_refuse()

# --------------------------------------------------------------------------
# Job registry: morph-object name -> the MorphJob that last built it, terminal
# jobs included (morph_spec and morph_sources read them).  Session state only;
# morph_name reads it to recognise a morph of a given source.
# --------------------------------------------------------------------------

_JOBS = {}

_ACTIVE = ('queued', 'running')
_FAILED = ('error', 'cancelled')

# Test seam: when set, step() calls _leg_hook(job, leg) as each leg begins
# (snapshot references taken, no frame computed yet), on whichever thread runs
# step().  Tests block or fail a leg here instead of racing the worker with
# sleeps.  Always None in production.
_leg_hook = None

# Computed legs a worker may hold before they have landed: it waits while this
# many are queued or being landed, and computes the next leg only once one has
# landed completely.  With 1, a single leg of frames exists as Python lists at
# any time (about 160 B per atom-frame, three times what the memory estimate
# budgets for cartoon), whatever the morph's size and however slowly pump()
# runs.  pump() waits for the next leg within its budget, so small legs do not
# cost one pump call each.
_LEGS_AHEAD = 1

# cmd.morph's method aliases and segmentation defaults
_RIGID_METHODS = ('rigimol', 'rigid', 'segments', 'corkscrew')
_CORE_FRACTION, _MIN_HINGE, _HINGE_BLEND = 0.5, 6, 3

# --------------------------------------------------------------------------
# Rep cost table: bytes per atom per interpolated frame
# --------------------------------------------------------------------------

_REP_COST = {
    'cartoon': 36,
    'sticks': 24,
    'lines': 8,
    'spheres': 12,
    'ribbon': 16,
    'dots': 8,
    'labels': 4,
}

# Alt filter used throughout this module
_ALT = "alt ''+A"


# --------------------------------------------------------------------------
# morph_name
# --------------------------------------------------------------------------

def morph_name(source, _self=cmd):
    '''Return a suitable name for the morph output of *source*.

    Returns ``<source>_morph`` when no object of any type (molecule, group,
    map, CGO, …) has that name, or when the object there is a known morph of
    this source (``_is_known_morph``).  Falls back to ``<source>_morph2``,
    ``<source>_morph3``, … with the same rule.  Names are legalised with
    ``cmd.get_legal_name``.
    '''
    suffix = 2
    base = source + '_morph'
    name = _self.get_legal_name(base)
    existing = _self.get_names('objects')
    while name in existing and not _is_known_morph(name, source, _self):
        name = _self.get_legal_name('%s%d' % (base, suffix))
        suffix += 1
    return name


def _is_known_morph(name, source, _self=cmd):
    '''True when *name* is a morph of *source* built this session and the
    object there is still that morph: a molecular object with the atom count
    the job created.  The registry outlives deletes and ``reinitialize``, so a
    record alone must not claim a group, map, CGO or unrelated molecule made
    later under the same name (a re-morph deletes the object it claims).'''
    job = _JOBS.get(name)
    if getattr(job, 'source', None) != source:
        return False
    try:
        return (_self.get_type(name) == 'object:molecule'
                and _self.count_atoms(name) == job.natoms)
    except pymol.CmdException:
        return False                             # no such object any more


# --------------------------------------------------------------------------
# validate_source
# --------------------------------------------------------------------------

def validate_source(source, _self=cmd):
    '''Validate *source* for morphing.

    Returns ``(atoms, models)`` where *atoms* is the alt-filtered count in
    model 1 and *models* is ``count_states(source)``.

    Raises ``pymol.CmdException`` if:
    - the object does not exist (propagated from get_type),
    - the object is discrete, or
    - atom counts differ across states.

    Error text for the last two: "morph: models have different atoms;
    morph needs the same atoms in every model".
    '''
    _MISMATCH = ('morph: models have different atoms; '
                 'morph needs the same atoms in every model')

    _self.get_type(source)          # raises CmdException if not found

    # Discrete objects store different atoms per state — not morphable
    if _self.count_discrete(source) > 0:
        raise pymol.CmdException(_MISMATCH)

    models = _self.count_states(source)
    sel = '(%s) and %s' % (source, _ALT)
    atoms = _self.count_atoms(sel, state=1)

    for k in range(2, models + 1):
        if _self.count_atoms(sel, state=k) != atoms:
            raise pymol.CmdException(_MISMATCH)

    return atoms, models


# --------------------------------------------------------------------------
# morph_estimate
# --------------------------------------------------------------------------

def morph_estimate(source, frames_per_model=15, loop=1, refinement=3,
                   _self=cmd):
    '''Estimate resource usage for morphing *source*.

    Returns a dict with keys:
      models, legs, frames, atoms, bytes, seconds, warn, refuse

    ``bytes`` uses 12 bytes per xyz coord plus rep-based overhead, times 1.1
    for the output object.  ``warn`` / ``refuse`` compare against the
    module-level WARN_BYTES / REFUSE_BYTES thresholds (read at call time so
    tests can monkeypatch them).
    '''
    models = _self.count_states(source)
    legs = models if loop else max(1, models - 1)
    frames = legs * frames_per_model
    atoms = _self.count_atoms('(%s) and %s' % (source, _ALT), state=1)

    # Sum rep costs for representations currently shown on source
    rep_cost = sum(
        cost
        for rep, cost in _REP_COST.items()
        if _self.count_atoms('(%s) and rep %s' % (source, rep)) > 0
    )

    nbytes = int(atoms * frames * (12 + rep_cost) * 1.1)
    seconds = (atoms * legs * 0.05e-3
               + atoms * frames * 0.25e-3 * (1 if refinement > 0 else 0))

    return {
        'models': models,
        'legs': legs,
        'frames': frames,
        'atoms': atoms,
        'bytes': nbytes,
        'seconds': seconds,
        'warn': nbytes >= WARN_BYTES,
        'refuse': nbytes >= REFUSE_BYTES,
    }


# --------------------------------------------------------------------------
# copy_look
# --------------------------------------------------------------------------

def copy_look(src, dst, _self=cmd):
    '''Copy per-object visual settings from *src* to *dst*.

    Copies every explicit per-object setting from ``get_object_settings(src)``
    except those whose name is ``state``, ``all_states``, or starts with
    ``movie``.  Always hides ``surface`` and ``mesh`` on *dst*.

    Returns the list of setting names that were copied.
    '''
    import pymol.setting as _ps

    raw = _self.get_object_settings(src) or []
    copied = []
    for idx, _typ, val in raw:
        name = _ps._get_name(idx)
        if not name:
            continue    # unknown index — skip defensively
        if name in ('state', 'all_states') or name.startswith('movie'):
            continue
        _self.set(name, val, dst)
        copied.append(name)

    _self.hide('surface', dst)
    _self.hide('mesh', dst)

    return copied


# start_job's copy_look=0/1 parameter shadows the function
_copy_look = copy_look


# --------------------------------------------------------------------------
# set_state_titles
# --------------------------------------------------------------------------

def set_state_titles(name, models, frames_per_model, loop, _self=cmd):
    '''Assign human-readable titles to every state of a morph object.

    Key-frame states get ``"model N"``; intermediate states get ``"N → M"``.
    When *loop* is true the last state wraps back to model 1.
    '''
    legs = models if loop else max(1, models - 1)
    _self.set_title(name, 1, 'model 1')
    for leg in range(legs):
        _title_leg(name, leg, models, frames_per_model, legs, _self)


def _title_leg(name, leg, models, frames_per_model, legs, _self=cmd):
    '''Title the states that leg *leg* (0-based) lands: ``"i → j"`` on its
    intermediates and ``"model j"`` on the key frame it ends on (state
    ``1 + (leg+1)·f``, or ``legs·f`` for the last leg).'''
    a, b = leg % models + 1, (leg + 1) % models + 1
    last = (1 + (leg + 1) * frames_per_model if leg < legs - 1
            else legs * frames_per_model)
    for s in range(2 + leg * frames_per_model, last):
        _self.set_title(name, s, '%d → %d' % (a, b))
    _self.set_title(name, last, 'model %d' % b)


# --------------------------------------------------------------------------
# fingerprint
# --------------------------------------------------------------------------

def fingerprint(source, _self=cmd):
    '''Return a dict identifying the current state of *source*.

    Keys: ``state_count`` (int), ``atom_count`` (int), ``crc32`` (int).

    ``crc32`` is computed from the model-1 coordinates formatted as
    ``"%.3f %.3f %.3f"`` per atom, one per line.  It changes when atom
    positions or identities change; ``state_count`` changes when states are
    added or removed.
    '''
    state_count = _self.count_states(source)
    sel = '(%s) and %s' % (source, _ALT)
    atom_count = _self.count_atoms(sel, state=1)

    lines = []
    _self.iterate_state(1, sel,
                        'lines.append("%.3f %.3f %.3f" % (x, y, z))',
                        space={'lines': lines})
    crc = binascii.crc32('\n'.join(lines).encode()) & 0xFFFFFFFF

    return {
        'state_count': state_count,
        'atom_count': atom_count,
        'crc32': crc,
    }


# --------------------------------------------------------------------------
# The job pipeline
# --------------------------------------------------------------------------

def _make_spec(frames_per_model, loop, method, refinement, rate, copy_look):
    '''The validated job spec.  Ints, never bools: the Swift side decodes
    ``loop`` and ``copy_look`` as Int, and a JSON ``true`` would fail the whole
    Object-panel payload.'''
    frames_per_model, refinement = int(frames_per_model), int(refinement)
    if frames_per_model < 2:
        raise pymol.CmdException('morph: frames per model must be at least 2')
    if refinement < 0:
        raise pymol.CmdException('morph: refinement must be 0 or more')
    method = str(method).lower()
    if method != 'linear' and method not in _RIGID_METHODS:
        raise pymol.CmdException('morph: unknown method "%s"' % method)
    rate = str(rate).lower().replace('_', ' ')
    if rate not in morphing._RATES:
        raise pymol.CmdException('morph: unknown rate "%s"' % rate)
    return {'frames_per_model': frames_per_model, 'loop': 1 if int(loop) else 0,
            'method': method, 'refinement': refinement, 'rate': rate,
            'copy_look': 1 if int(copy_look) else 0}


class MorphJob(object):
    '''One morph being built into the object *name* from *source*.

    ``step()`` computes the next leg from the snapshot start_job took and
    queues its frames; it never touches cmd, so it can run off the main thread.
    ``pump()`` lands queued frames.  ``state`` is 'queued', 'running', 'done',
    'error' or 'cancelled'; a terminal state is never overwritten.

    Shared with a worker thread: ``state``, ``error``, ``done_legs``,
    ``_held`` and the snapshot (``_coords``, ``_info``, ``_pos``) change
    only under ``_lock``; ``_queue`` carries finished legs to the main
    thread; ``_room`` (a Condition on ``_lock``) is notified when a leg is
    queued or has landed and when the job ends (the worker waits on it for
    room, pump() for the next leg); ``_cancel`` stops the worker.
    ``landed_legs``, ``_landing`` and the remaining flags belong to the main
    thread.'''

    def __init__(self, name, source, spec, fingerprint, pos, coords, info, run):
        self.name = name
        self.source = source
        self.spec = spec
        self.fingerprint = fingerprint
        self.frames_per_model = spec['frames_per_model']
        self.natoms = len(pos)      # atoms in the morph object
        self.models = len(coords)
        self.legs = self.models if spec['loop'] else self.models - 1
        self.done_legs = 0          # computed by step()
        self.landed_legs = 0        # written into the object by pump()
        self.state = 'queued'
        self.error = None
        self.started = time.monotonic()
        self.ended = None
        self.run = run              # True: a worker thread calls step()
        self._pos = pos             # output atom index -> coordinate-set row
        self._coords = coords       # per model, rows in coordinate-set order
        self._info = info
        self._lock = threading.Lock()
        self._room = threading.Condition(self._lock)    # a leg queued or landed
        self._held = 0              # legs computed and not yet landed
        self._cancel = threading.Event()    # set: the worker stops
        self._thread = None
        self._queue = queue.Queue()         # (leg, frames) not yet landed
        self._landing = None        # [leg, frames, next frame] being landed
        self._finalised = False     # terminal and cleaned up on the main thread
        self._dismissed = False
        self._sculpting = False
        self._unbuilt = 0           # landed frames whose reps are not built yet
        self._build_cost = None     # seconds to build one frame; None: not measured
        self._land_cost = 0.0       # seconds to land (and sculpt) one frame

    def step(self):
        '''Compute the next leg into the queue; False when none remain or the
        job has ended.  Never touches cmd: the worker thread (run=True) or the
        caller (run=False) runs it while the main thread may cancel or pump.'''
        with self._lock:
            if (self._cancel.is_set() or self.state not in _ACTIVE
                    or self.done_legs >= self.legs):
                return False
            self.state = 'running'
            # own references: _end frees the job's snapshot when the job ends,
            # possibly while this leg is still being computed
            leg, coords, info = self.done_legs, self._coords, self._info
        try:
            if _leg_hook is not None:
                _leg_hook(self, leg)
            frames = self._compute_leg(leg, coords, info)
        except Exception as e:
            self._terminate('error', _message(e))
            return False
        with self._lock:
            if self._cancel.is_set() or self.state not in _ACTIVE:
                return False                # ended meanwhile: drop the leg
            self._queue.put((leg, frames))
            self.done_legs += 1
            self._held += 1
            self._room.notify_all()         # pump() may be waiting for this leg
        return True

    def cancel(self):
        '''Stop computing (a worker drops the leg it is on and exits); the
        next pump (or morph_cancel) cleans up.'''
        self._terminate('cancelled')
        self._cancel.set()

    def join(self, timeout=None):
        '''Wait for the worker thread; True once it has exited (at once for a
        job without one).'''
        if self._thread is None:
            return True
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def _run(self):
        '''The worker thread: compute legs until none remain or the job
        ends, holding at most _LEGS_AHEAD legs that have not landed.'''
        while self._wait_for_room() and self.step():
            pass

    def _wait_for_room(self):
        '''Block while _LEGS_AHEAD computed legs have not finished landing;
        False once the job has ended.  The wait releases _lock, so pump()
        and cancel() never block on a waiting worker, and both notify
        _room.'''
        with self._room:
            while (self.state in _ACTIVE and not self._cancel.is_set()
                   and self._held >= _LEGS_AHEAD):
                self._room.wait()
            return self.state in _ACTIVE and not self._cancel.is_set()

    def _terminate(self, state, error=None):
        '''End the job in *state* unless it has already ended: a terminal
        state is never overwritten.  True when this call ended it.'''
        with self._room:
            if self.state not in _ACTIVE:
                return False
            self.error, self.state = error, state
            self._room.notify_all()         # a waiting worker exits
            return True

    def _compute_leg(self, leg, coords, info):
        '''The frames *leg* lands: its intermediates, then its end model.

        A non-last leg lands fractions j/f (j = 1..f) and the last leg
        j/(f-1) (j = 1..f-1), so the morph has legs·f states with model 1 as
        state 1 and key frames at 1 + k·f: the cmd.morph schedule, regrouped so
        every leg ends on its key frame.  The end model is the snapshot itself,
        never a computed frame, so key frames are bit-exact.  Reads only the
        snapshot passed in (*coords*, *info*) and immutable job fields.'''
        S = coords[leg]
        E = coords[(leg + 1) % self.models]
        n = self.frames_per_model if leg < self.legs - 1 else self.frames_per_model - 1
        rate = morphing._RATES[self.spec['rate']]
        fracs = [rate(j / float(n)) for j in range(1, n)]
        if self.spec['method'] == 'linear':
            frames = morphing._frames_linear(S, E, fracs)
        else:
            segments, blend_of_pos, _ = morphing._segment_chains(
                S, E, info, _CORE_FRACTION, _MIN_HINGE, _HINGE_BLEND)
            frames = morphing._frames_rigid(S, E, segments, blend_of_pos, fracs)
        return list(frames) + [E]


def _target_name(source, name, _self):
    '''The object a morph of *source* is built in.

    No name: ``morph_name(source)``.  An explicit name is legalised and may
    replace an existing object only when it is a known morph of *source* or
    a molecular object following the ``<source>_morph<N>`` convention (a
    morph restored from a session has no job registered).'''
    if not name:
        return morph_name(source, _self)
    name = _self.get_legal_name(str(name))
    if name in _self.get_names('objects'):
        base = _self.get_legal_name(source + '_morph')
        convention = (re.match(r'%s\d*$' % re.escape(base), name)
                      and _self.get_type(name) == 'object:molecule')
        if not convention and not _is_known_morph(name, source, _self):
            raise pymol.CmdException(
                'morph: %s exists and is not a morph of %s' % (name, source))
    return name


def start_job(source, name=None, frames_per_model=15, loop=1, method='rigimol',
              refinement=3, rate='linear', copy_look=1, run=False, _self=cmd):
    '''Validate *source*, create the morph object holding model 1 (disabled
    until the morph is complete), snapshot every model, register the job.

    run=False: the caller drives ``job.step()``.  run=True: a daemon worker
    thread drives ``step()`` until the legs run out or the job ends.  Either
    way pump() only lands what is queued; it never calls ``step()``.'''
    spec = _make_spec(frames_per_model, loop, method, refinement, rate, copy_look)
    _, models = validate_source(source, _self)
    if models < 2:
        raise pymol.CmdException(
            'morph: %s has one model; morph needs at least two' % source)
    est = morph_estimate(source, spec['frames_per_model'], spec['loop'],
                         spec['refinement'], _self=_self)
    if est['refuse']:
        raise pymol.CmdException(
            'morph: this morph needs about %d MB. Reduce frames per model or '
            'morph fewer models' % (est['bytes'] // 1000000))
    target = _target_name(source, name, _self)
    old = _JOBS.get(target)
    if old is not None and old.state in _ACTIVE:
        raise pymol.CmdException('morph: %s is already being built' % target)
    fp = fingerprint(source, _self)

    if target in _self.get_names('objects'):
        _self.delete(target)                # morph always rebuilds
    sele = '((%s) and %s)' % (source, _ALT)
    _self.create(target, sele, 1, 1, zoom=0, quiet=1)
    try:
        # hidden while it grows: at state 1 it would z-fight the source
        _self.disable(target)
        _, pos, src_of, info = morphing._snapshot(target, sele, source, _self)
        coords = [morphing._coords_by_pos(source, k, src_of, pos, _self)
                  for k in range(1, models + 1)]
        if spec['copy_look']:
            _copy_look(source, target, _self)
        # never carried, copy_look or not: reps live per state, so a surface
        # would be built once per frame
        _self.hide('surface', target)
        _self.hide('mesh', target)
        _self.set_title(target, 1, 'model 1')
    except Exception:
        _self.delete(target)
        raise
    # a re-morph deleted the old morph; keep the source on screen meanwhile
    _self.enable(source)
    job = MorphJob(target, source, spec, fp, pos, coords, info, bool(run))
    _JOBS[target] = job
    if job.run:
        job._thread = threading.Thread(target=job._run, daemon=True,
                                       name='morph ' + target)
        job._thread.start()
    return job


def pump(budget_ms=100, _self=cmd):
    '''Land computed frames on the main thread, build their representations
    while the morph is hidden (_prebuild), then finish jobs whose last leg
    landed.  A frame is landed only while landing it and building every frame
    this pump landed still fit in what is left of *budget_ms*, at the costs
    measured so far (a job's first frame is built at once to measure them).
    A worker computing a job's next leg is waited for only within that same
    allowance.  Every job still gets one unit of work, one frame landed and
    built, so pump(budget_ms=0) makes progress.  A pump therefore overruns
    *budget_ms* only by that one unit or by the error of the estimates; the
    budget is shared by all jobs.  Never raises: a failing job goes to the
    error path.'''
    deadline = time.monotonic() + max(float(budget_ms), 0.0) / 1000.0
    for job in [j for j in _JOBS.values() if not j._finalised]:
        try:
            _advance(job, deadline, _self)
        except Exception as e:
            _fail(job, e, _self)


def _advance(job, deadline, _self):
    if job.state in _FAILED:                # step() failed or cancel() was called
        _finalise_failed(job, _self)
        return
    names = _self.get_names('objects')
    if job.source not in names:
        raise pymol.CmdException('morph: source %s was deleted' % job.source)
    if job.name not in names:
        raise pymol.CmdException(
            'morph: %s was deleted while it was being built' % job.name)
    try:
        while _unit(job, deadline, _self):
            if job._build_cost is None:     # first frame: measure the build
                _sculpt_off(job, _self)
                _prebuild(job, _self)
            if time.monotonic() + _reserve(job, 1) >= deadline:
                break                       # one more would not fit once built
    finally:
        _sculpt_off(job, _self)
    _prebuild(job, _self)


def _reserve(job, extra):
    '''Seconds to land *extra* more frames and to build them together with
    the frames landed since the last _prebuild, at the measured costs.'''
    return (extra * job._land_cost
            + (job._unbuilt + extra) * (job._build_cost or 0.0))


def _wait_for_leg(job, deadline):
    '''A worker job with nothing queued is computing its next leg: wait for
    it until *deadline* (no wait once it has passed).  The wait releases the
    job lock and the GIL; a queued leg, a terminal state and _end wake it.
    run=False jobs are never waited for: their legs come from the caller.'''
    if not job.run:
        return
    with job._room:
        while (job._queue.empty() and job.state in _ACTIVE
               and not job._cancel.is_set() and job.done_legs < job.legs):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            job._room.wait(remaining)


def _unit(job, deadline, _self):
    '''One unit of work; False when the job must wait or has ended.'''
    if job.state in _FAILED:                # step() failed during this pump
        _finalise_failed(job, _self)
        return False
    if job._landing is None:
        _wait_for_leg(job, deadline - _reserve(job, 1))
        if job.state in _FAILED:            # the worker failed meanwhile
            _finalise_failed(job, _self)
            return False
        try:
            leg, frames = job._queue.get_nowait()
        except queue.Empty:
            pass
        else:
            job._landing = [leg, frames, 0]
    if job._landing is not None:
        _land_frame(job, _self)
        return True
    if job.landed_legs >= job.legs:
        _complete(job, _self)
    return False


def _land_frame(job, _self):
    '''Append the next frame of the leg being landed; sculpt it when it is an
    intermediate; title the leg once its key frame is in, build the leg's
    frames, and only then let the worker compute the next leg.'''
    t = time.monotonic()
    leg, frames, k = job._landing
    _self.load_coordset(frames[k], job.name, 0)
    job._unbuilt += 1
    if k + 1 < len(frames):
        job._landing[2] = k + 1
        if job.spec['refinement'] > 0:
            _sculpt(job, 2 + leg * job.frames_per_model + k, _self)
        _note_land_cost(job, time.monotonic() - t)
        return
    job._landing = None
    _title_leg(job.name, leg, job.models, job.frames_per_model, job.legs, _self)
    job.landed_legs += 1
    _note_land_cost(job, time.monotonic() - t)
    # Build before releasing the worker.  The core takes the GIL once per state
    # of the morph during the update (OrthoBusyFast at the end of every
    # CoordSet::update), so a build that overlaps the worker's pure-Python leg
    # waits for it hundreds of times: 5-10x slower at leg boundaries.  Frames
    # of the next leg land only once the worker has queued it and waits for
    # room again, so no build overlaps a computing worker.
    _sculpt_off(job, _self)
    _prebuild(job, _self)
    with job._room:
        job._held -= 1
        job._room.notify_all()              # the worker may compute the next leg


def _note_land_cost(job, seconds):
    '''Running estimate of the time one frame takes to land.'''
    job._land_cost = seconds if not job._land_cost else 0.5 * (job._land_cost + seconds)


def _sculpt(job, state, _self):
    '''Clean up one landed intermediate as morphing.sculpt_states does.

    Sculpting is switched on here and off at the end of every pump, never
    left active between pumps: with the global ``sculpting`` setting on, the
    render loop sculpts an active object's current state, which may be a key
    frame that must stay an exact copy of its model.'''
    if not job._sculpting:
        job._sculpting = True
        _self.flag('fix', '%s and %s' % (job.name, morphing._SCULPT_FIX), 'set', quiet=1)
        _self.sculpt_activate(job.name, 1)
    _self.sculpt_iterate(job.name, state,
                         morphing._SCULPT_CYCLES * job.spec['refinement'])


def _sculpt_off(job, _self):
    if not job._sculpting:
        return
    job._sculpting = False
    try:
        _self.sculpt_deactivate(job.name)
        _self.flag('fix', job.name, 'clear', quiet=1)
    except Exception:
        pass                                # the object is already gone


def _prebuild(job, _self):
    '''Build the representations of the frames landed since the last call
    while the morph is still hidden.

    The core builds an object's representations only while it is in the
    scene, and for an object with its own ``state`` setting (per-object
    playback) it builds every state in one update (PyMOL's
    ObjectAdjustStateRebuildRange).  A morph that grew hidden therefore made
    the first frame after completion build all of it: a 1.5-2 s frame for
    1200 frames of 2kpo.  Here the morph joins the scene for one update
    phase (no frame is drawn while pump runs), which builds only its frames
    without representations, and leaves it again.

    Skipped when it cannot help: a morph the user switched on is built by the
    frames that draw it; with defer_builds_mode >= 1 the update builds only
    the current state, and at >= 3 disabling would also purge what it built.'''
    if not job._unbuilt or job.state not in _ACTIVE:
        return
    from pymol import _cmd
    prepare = getattr(_cmd, 'surface_pick_prepare', None)
    name = job.name
    if (prepare is None or _self.get_setting_int('defer_builds_mode') != 0
            or name in _self.get_names('objects', enabled_only=1)):
        job._unbuilt = 0
        if job._build_cost is None:
            job._build_cost = 0.0           # nothing will be built here
        return
    t = time.monotonic()
    _self.enable(name)
    try:
        with _self.lockcm:
            # update phase only: reps mask 0, update 1, build 0 (layer4/Cmd.cpp)
            prepare(_self._COb, [name], 0, 1, 0)
    except Exception:
        pass                                # e.g. a modal draw owns the core
    finally:
        _self.disable(name)
    # per frame, with the call's fixed cost spread over the frames: rises at
    # once, falls by halves, so an estimate errs towards a smaller pump
    per = (time.monotonic() - t) / job._unbuilt
    old = job._build_cost
    job._build_cost = per if old is None or per > old else 0.5 * (old + per)
    job._unbuilt = 0


def _complete(job, _self):
    '''Verify the finished morph, then show it in place of the source.'''
    name = job.name
    expected = job.legs * job.frames_per_model
    got = _self.count_states(name)
    if got != expected:
        raise pymol.CmdException('morph: expected %d states, got %d' % (expected, got))
    # round-trip the last frame: load_coordset is order-sensitive
    target = job._coords[0 if job.spec['loop'] else job.models - 1]
    chk = {}
    _self.iterate_state(got, name, 'chk[index] = (x, y, z)', space={'chk': chk})
    err = max(abs(chk[i][a] - target[p][a]) for i, p in job._pos.items() for a in range(3))
    if err > 1e-3:
        raise pymol.CmdException('morph: coordinate write order mismatch (%.3g)' % err)
    _sculpt_off(job, _self)
    _self.set('state', 1, name)
    _self.enable(name)
    if job.source in _self.get_names('objects'):
        _self.disable(job.source)
    job._terminate('done')
    _end(job)


def _end(job):
    '''Retire a job that has reached a terminal state: stop its worker, drop
    unlanded legs, free the snapshot.  A worker still inside a leg computes
    on its own references and drops the leg (step()); nothing is queued once
    the state is terminal.'''
    job._cancel.set()
    job._finalised = True
    job.ended = time.monotonic()
    job._landing = None
    with job._room:
        while not job._queue.empty():
            job._queue.get_nowait()
        job._coords = job._info = job._pos = None
        job._held = 0
        job._room.notify_all()


def _finalise_failed(job, _self):
    '''Cancel/error cleanup: drop the partial morph and show the source
    again.  The record stays in recent_objects() until morph_dismiss.'''
    _end(job)
    _sculpt_off(job, _self)
    try:
        names = _self.get_names('objects')
        if job.name in names:
            _self.delete(job.name)
        if job.source in names:
            _self.enable(job.source)
    except Exception:
        pass


def _message(exc):
    '''The error text a tray card shows: a CmdException's own message,
    without the " Error: " label its str() adds.'''
    if isinstance(exc, pymol.CmdException) and exc.message:
        return str(exc.message)
    return str(exc) or exc.__class__.__name__


def _fail(job, exc, _self):
    job._terminate('error', _message(exc))
    _finalise_failed(job, _self)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def morph_object(source, name=None, frames_per_model=15, loop=1,
                 method='rigimol', refinement=3, rate='linear', copy_look=1,
                 async_=1, reuse=0, quiet=1, _self=cmd):
    '''
DESCRIPTION

    Build a smoothly playing morph of a multi-state object: every pair of
    consecutive models is interpolated (rigid segments on screw paths, then
    sculpting clean-up), the key frames stay exact copies of the models, and
    the result replaces the source on screen when it is complete.

USAGE

    morph_object source [, name [, frames_per_model [, loop [, method
        [, refinement [, rate [, copy_look [, async_ [, reuse ]]]]]]]]]

ARGUMENTS

    source = str: multi-state object; every model must have the same atoms

    name = str: output object {default: <source>_morph}

    frames_per_model = int: states per model {default: 15}

    loop = 0/1: interpolate back from the last model to the first {default: 1}

    method = rigimol or linear {default: rigimol}

    refinement = int: sculpting clean-up of intermediates, 0 for none
    {default: 3}

    rate = linear, sinusoidal, "ramp up" or "ramp down" {default: linear}

    copy_look = 0/1: copy the source's object-level settings {default: 1}

    async_ = 0/1: build in the background (1) or finish before returning
    {default: 1}

    reuse = 0/1: keep an existing morph built with the same settings from
    the unchanged source {default: 0}

SEE ALSO

    morph, morph_cancel, morph_dismiss
    '''
    spec = _make_spec(frames_per_model, loop, method, refinement, rate, copy_look)
    if int(reuse):
        target = _target_name(source, name, _self)
        job = _JOBS.get(target)
        if (job is not None and job.state == 'done' and job.source == source
                and target in _self.get_names('objects') and job.spec == spec
                and job.fingerprint == fingerprint(source, _self)):
            return target
    job = start_job(source, name, run=bool(int(async_)), _self=_self, **spec)
    if job.run:
        if not int(quiet):
            print(' morph_object: building %s (%d legs)' % (job.name, job.legs))
        return job.name
    while job.step():
        pump(budget_ms=10 ** 9, _self=_self)
    pump(budget_ms=10 ** 9, _self=_self)
    if job.state != 'done':
        raise pymol.CmdException(job.error or 'morph: %s did not complete' % job.name)
    if not int(quiet):
        print(' morph_object: %s, %d states from %d models'
              % (job.name, job.legs * job.frames_per_model, job.models))
    return job.name


def morph_cancel(name, quiet=1, _self=cmd):
    '''
DESCRIPTION

    Cancel a morph that is being built: the partial object is deleted and the
    source is shown again.
    '''
    job = _JOBS.get(name)
    if job is None or job._finalised:
        if not int(quiet):
            print(' morph_cancel: %s is not being built' % name)
        return
    job.cancel()
    _finalise_failed(job, _self)


def morph_dismiss(name, quiet=1, _self=cmd):
    '''
DESCRIPTION

    Forget the record of a cancelled or failed morph (its progress card).
    '''
    job = _JOBS.get(name)
    if job is not None and job.state in _FAILED:
        job._dismissed = True
    elif not int(quiet):
        print(' morph_dismiss: no cancelled or failed morph named %s' % name)


def morph_spec(name):
    '''``{'spec', 'fingerprint', 'state', 'started'}`` of the job that last
    built *name* this session (terminal included), or None.'''
    job = _JOBS.get(name)
    if job is None:
        return None
    return {'spec': dict(job.spec), 'fingerprint': dict(job.fingerprint),
            'state': job.state, 'started': job.started}


def morph_sources(_self=cmd):
    '''``{morph_name: {'source', 'spec'}}`` for completed morphs that still
    exist.'''
    names = set(_self.get_names('objects'))
    return {n: {'source': j.source, 'spec': dict(j.spec)}
            for n, j in _JOBS.items() if j.state == 'done' and n in names}


# --------------------------------------------------------------------------
# Pending surface (progress tray), same contract as designing.py
# --------------------------------------------------------------------------

def pending_objects():
    '''Morphs still being built: ``{name: [name]}``.'''
    return {n: [n] for n, j in _JOBS.items() if j.state in _ACTIVE}


def recent_objects():
    '''Cancelled or failed morphs whose card has not been dismissed.  A
    morph that completes leaves no record.'''
    return [n for n, j in _JOBS.items() if j.state in _FAILED and not j._dismissed]


def pending_info(name, _self=cmd):
    '''Progress record for the tray, or None: the keys designing.pending_info
    publishes, one leg counted as one "model".  Never raises: the caller
    writes no panel file at all if this throws.'''
    try:
        job = _JOBS.get(name)
        if job is None:
            return None
        with job._lock:                     # a worker may be ending the job
            state, error = job.state, job.error
        if state == 'done' or job._dismissed:
            return None
        if state not in _ACTIVE:
            phase = 'done'
        elif job._landing is not None or not job._queue.empty():
            phase = 'landing'
        else:
            phase = 'computing'
        fraction = job.landed_legs / float(max(job.legs, 1))
        end = job.ended if job.ended is not None else time.monotonic()
        return {
            'state': state, 'phase': phase, 'fraction': fraction,
            'moving': state == 'running',
            'models_done': job.landed_legs, 'models_total': job.legs,
            'elapsed': max(end - job.started, 0.0),
            'error': None if error is None else str(error),
            'detail': 'leg %d of %d · %d%%' % (job.landed_legs, job.legs,
                                               int(fraction * 100)),
            'bundle': None, 'step': None, 'total_steps': None,
            'remaining': None, 'batch': None, 'batch_index': None,
            'batch_total': None, 'run_remaining': None,
        }
    except Exception:
        return None
