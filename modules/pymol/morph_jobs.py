'''
morph_jobs — the morph job layer behind the Object panel's Morph action.

Building blocks (naming, estimation, validation, look copy, titles,
fingerprint) plus the job pipeline: start_job() snapshots a multi-state source
on the main thread, MorphJob.step() computes one leg of frames without touching
cmd (on a daemon worker thread for async morphs), and pump() lands computed
frames on the main thread within a time budget.  The pending surface
(pending_objects / recent_objects / pending_info) feeds the progress tray with
the same record shape designing.pending_info publishes; a morph_object that
start_job refuses is filed there as a failed job too (_record_refusal).

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
import itertools
import os
import queue
import re
import struct
import sys
import threading
import time
import traceback

import pymol
from pymol import morphing

cmd = __import__("sys").modules["pymol.cmd"]

# --------------------------------------------------------------------------
# Platform memory thresholds
# --------------------------------------------------------------------------
#
# morph_estimate's bytes are the memory the finished morph holds; above
# warn the sheet turns orange, above refuse the morph is refused.  The
# constants are floors only: on macOS (and command-line PyMOL anywhere) the
# thresholds scale with the machine's physical memory, on iPhone and iPad
# with the memory the app may still allocate before the system ends it
# (os_proc_available_memory), read each time because it changes.  Any
# failure to read a figure falls back to the floors.

_WARN_FLOOR, _REFUSE_FLOOR = 200e6, 1e9
_IOS_WARN_FLOOR, _IOS_REFUSE_FLOOR = 100e6, 400e6


def _is_ios():
    return sys.platform == 'ios'


def _physical_memory():
    return os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')


def _ios_available_memory():
    import ctypes
    available = ctypes.CDLL(None).os_proc_available_memory
    available.restype = ctypes.c_size_t
    available.argtypes = []
    return available()


def _platform_warn():
    '''Warn threshold: 1/4 of what an iOS app may still allocate (at least
    100 MB), elsewhere 1/16 of physical memory (at least 200 MB).'''
    if _is_ios():
        try:
            return max(_IOS_WARN_FLOOR, _ios_available_memory() / 4.0)
        except Exception:
            return _IOS_WARN_FLOOR
    try:
        return max(_WARN_FLOOR, _physical_memory() / 16.0)
    except Exception:
        return _WARN_FLOOR


def _platform_refuse():
    '''Refuse threshold: 1/2 of what an iOS app may still allocate (at least
    400 MB), elsewhere 1/4 of physical memory (at least 1 GB).'''
    if _is_ios():
        try:
            return max(_IOS_REFUSE_FLOOR, _ios_available_memory() / 2.0)
        except Exception:
            return _IOS_REFUSE_FLOOR
    try:
        return max(_REFUSE_FLOOR, _physical_memory() / 4.0)
    except Exception:
        return _REFUSE_FLOOR


# None: thresholds() asks _platform_warn / _platform_refuse at each call.  A
# number set here (a test, a script) is used as is.
WARN_BYTES = None
REFUSE_BYTES = None


def thresholds():
    '''``(warn, refuse)`` in bytes, compared with morph_estimate's bytes.'''
    warn = WARN_BYTES if WARN_BYTES is not None else _platform_warn()
    refuse = REFUSE_BYTES if REFUSE_BYTES is not None else _platform_refuse()
    return warn, refuse

# --------------------------------------------------------------------------
# Job registry: morph-object name -> the MorphJob that last built it, terminal
# jobs included (morph_spec and morph_sources read them).  Session state only;
# morph_name reads it to recognise a morph of a given source.  Keyed by name,
# so a record speaks for the object under that name only while it is still the
# job's own output (_is_output).  A session load or reinitialize replaces the
# objects under it: reset() stops the jobs building into them and forgets the
# finished morphs they replaced (session_restore, commanding.reinitialize).
# --------------------------------------------------------------------------

_JOBS = {}

# Numbers each job, so each finished build has its own number in
# morph_sources().  The app's panel poll reports a morph as finished when a
# number it has not seen appears: a small morph lands inside one poll's pump,
# so no poll lists it as being built, and a rebuild with the same settings
# publishes the same source and spec.  Never reset: unique for the process.
_BUILDS = itertools.count(1)

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
# any time (about 160 B per atom-frame, transient, outside the memory
# estimate), whatever the morph's size and however slowly pump() runs.
# pump() waits for the next leg within its budget, so small legs do not cost
# one pump call each.
_LEGS_AHEAD = 1

# cmd.morph's method aliases and segmentation defaults
_RIGID_METHODS = ('rigimol', 'rigid', 'segments', 'corkscrew')
_CORE_FRACTION, _MIN_HINGE, _HINGE_BLEND = 0.5, 6, 3

# --------------------------------------------------------------------------
# Memory one morph frame holds (bytes_per_frame)
# --------------------------------------------------------------------------
#
# Resident bytes per built state, measured headless on this core.  With the
# app's defer_builds_mode 0 the core builds and keeps the representations of
# every state of the morph, so each frame costs this for good.  Method: one
# fresh process per figure; load the model, show one representation, add
# 300 states to a copy of it (with cmd.create, and with load_coordset as a
# morph does), force the core's update phase over all of them (the call
# _prebuild makes) and read RSS (ps) before and after.  Models: 2kpo (20
# models; 1860 atoms, 917 without hydrogens; 110 residues: 59 helix, 23
# strand, 28 loop) and a 120-residue Ala peptide with every residue set to
# one secondary structure.  The larger per-unit figure is kept:
#
#   coordinates only  23-25 B/atom (create), 27-46 (load_coordset)        45
#   cartoon           13.8 KB/residue loop, 8.7 strand, 30.8 helix  14000/res
#                     (2kpo: 18.4-18.5 KB/residue, the model 23)    +17000/helix
#                     at the default sampling (auto: 20 rings per residue
#                     with cartoon_spline); 2kpo costs 7.5 KB/residue at
#                     cartoon_sampling 7 and 16.3 at 18, the app's highest
#                     zoom level, so the default bounds what zooming builds
#   sticks            95-98 B/atom                                       100
#   lines             77-78 B/atom                                        80
#   spheres           64-65 B/atom                                        65
#   ribbon            101-103 B/residue                                  105
#   dots              1.2 KB/atom with hydrogens, 1.6 KB without        1600
#   labels            124-127 B/atom (atom-name labels)                  130
#
# Helix residues are the source's own, or every residue when the source has
# no secondary structure assigned (_helix_residues).  Surfaces and meshes are
# never carried onto a morph (start_job hides them).  bytes_per_frame adds
# 10 %.  Not counted: while it builds, the job's snapshot of the models and
# one leg of frames held as Python lists; on the Metal path, GPU buffers of
# the frames drawn.

_COORD_COST = 45
_ATOM_REP_COST = {'sticks': 100, 'lines': 80, 'spheres': 65, 'dots': 1600,
                  'labels': 130}
_RESIDUE_REP_COST = {'cartoon': 14000, 'ribbon': 105}
_HELIX_CARTOON_COST = 17000     # on top of the cartoon's per-residue cost
# One atom per polymer residue (CA; C4' in nucleic acids): the guide atoms
# cartoon and ribbon trace.  A flag test, cheaper in the selector than
# matching names, and it leaves out calcium ions named CA.
_RESIDUE = 'guide'
_FRAME_OVERHEAD = 1.1

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
    '''True when *name* is a morph of *source* started since launch and the
    object there is still that morph: one being built (the job has not been
    cleaned up, so the object holds what it has landed; a job that failed
    keeps its partial morph until the next pump) or one built (_is_output).
    The registry outlives deletes and cancels, and a re-morph deletes the
    object it claims, so a record alone claims nothing: not a group, map or
    CGO made later under the name, nor a molecule, even one with the same
    atoms.'''
    job = _JOBS.get(name)
    if getattr(job, 'source', None) != source:
        return False
    if not job._finalised:
        return _holds(job, 1 + job._landed, _self)
    return _is_output(job, _self)


# --------------------------------------------------------------------------
# validate_source
# --------------------------------------------------------------------------

_MISMATCH = ('morph: models have different atoms; '
             'morph needs the same atoms in every model')


def _molecular_models(source, _self):
    '''``count_states(source)`` once *source* is known to be a molecular
    object.  Raises CmdException when there is no such object or it is not a
    molecule (a CGO, map, group...).  Existence is checked by name first:
    get_type would log a Selector-Error and raise without a message, which a
    tray card would show as " Error: ".'''
    if str(source) not in _self.get_names('objects'):
        raise pymol.CmdException('morph: there is no object named %s' % source)
    if _self.get_type(source) != 'object:molecule':
        raise pymol.CmdException('morph: %s is not a molecular object' % source)
    return _self.count_states(source)


def validate_source(source, _self=cmd):
    '''Validate *source* for morphing.

    Returns ``(atoms, models)`` where *atoms* is the alt-filtered count in
    model 1 and *models* is ``count_states(source)``.

    Raises ``pymol.CmdException`` if:
    - the object does not exist ("morph: there is no object named <source>"),
    - it is not a molecular object ("morph: <source> is not a molecular
      object"),
    - it has no atoms with no alternate location or altloc A ("morph:
      <source> has no atoms in alt '' or A"), or
    - it is discrete, or its states do not all hold the same atoms ("morph:
      models have different atoms; morph needs the same atoms in every
      model").  Counts are compared first; equal counts must also be the same
      atoms: every atom of model 1 is present in model k (the ``state``
      selection operator, so the check runs in the selector, not one Python
      call per atom).
    '''
    models = _molecular_models(source, _self)

    # Discrete objects store different atoms per state — not morphable
    if _self.count_discrete(source) > 0:
        raise pymol.CmdException(_MISMATCH)

    sel = '(%s) and %s' % (source, _ALT)
    atoms = _self.count_atoms(sel, state=1)
    if atoms == 0:
        raise pymol.CmdException("morph: %s has no atoms in alt '' or A" % source)

    for k in range(2, models + 1):
        if _self.count_atoms(sel, state=k) != atoms:
            raise pymol.CmdException(_MISMATCH)
    for k in range(2, models + 1):
        if _self.count_atoms('%s and state 1 and state %d' % (sel, k)) != atoms:
            raise pymol.CmdException(_MISMATCH)

    return atoms, models


# --------------------------------------------------------------------------
# morph_estimate
# --------------------------------------------------------------------------

def bytes_per_frame(source, _self=cmd):
    '''Bytes one interpolated state of a morph of *source* holds once built.

    Coordinates of the ``(source) and alt ''+A`` atoms plus the
    representations the source shows now (a morph copies them; surface and
    mesh excluded, a morph never carries them), at the costs measured above
    (_COORD_COST, _ATOM_REP_COST, _RESIDUE_REP_COST, _HELIX_CARTOON_COST),
    plus 10 %.  morph_estimate, the Morph sheet and the Play-models sheet
    (the panel payload's ``morph_bytes_per_frame``) use this one figure.'''
    return frame_cost(source, _self)[1]


def frame_cost(source, _self=cmd):
    '''``(atoms, bytes)`` of one interpolated state of a morph of *source*:
    the ``(source) and alt ''+A`` atoms of state 1 (morph_estimate's
    ``atoms``, what one morph frame holds: one model's atoms, also for a
    discrete object) and bytes_per_frame().  One pass for both, so the panel
    poll publishes both figures (``morph_atoms_per_frame``,
    ``morph_bytes_per_frame``) for the price of the bytes.'''
    sel = '(%s) and %s' % (source, _ALT)
    atoms = _self.count_atoms(sel, state=1)
    total = _COORD_COST * atoms
    shown = _shown_reps(sel, _self)
    for rep, cost in _ATOM_REP_COST.items():
        if rep in shown:
            total += cost * _self.count_atoms('%s and rep %s' % (sel, rep), state=1)
    for rep, cost in _RESIDUE_REP_COST.items():
        if rep not in shown:
            continue
        traced = '%s and rep %s and %s' % (sel, rep, _RESIDUE)
        residues = _self.count_atoms(traced, state=1)
        total += cost * residues
        if rep == 'cartoon' and residues:
            total += _HELIX_CARTOON_COST * _helix_residues(traced, residues, _self)
    return atoms, int(_FRAME_OVERHEAD * total)


def _shown_reps(sel, _self):
    '''Names of the representations at least one atom of *sel* shows: one
    selector pass (the fork's _cmd.get_atom_reps, the OR of the atoms' rep
    flags), so frame_cost counts only those (the panel poll calls
    frame_cost, whose bytes bytes_per_frame returns, for every multi-state
    molecule).  Every costed rep when the call is missing or fails, which
    only costs the counts.'''
    reps = set(_ATOM_REP_COST) | set(_RESIDUE_REP_COST)
    try:
        from pymol import _cmd
        from pymol.constants import repres
        with _self.lockcm:
            shown = set(_cmd.get_atom_reps(_self._COb, sel))
        return {r for r in reps if repres[r] in shown}
    except Exception:
        return reps


def _helix_residues(traced, residues, _self):
    '''Residues of *traced* (the cartoon's) that the morph will draw as
    helix.  The morph object is created with one state, so with auto_dss on
    (the default) the core assigns its secondary structure itself (dss on
    model 1).  A source whose secondary structure was never assigned (no
    helix and no strand, as after fab or a multi-model file without helix
    records) says nothing about what that will find, so every residue is
    counted as helix, the dearer case; otherwise the source's own
    assignment stands in for it.'''
    helix = _self.count_atoms(traced + ' and ss H', state=1)
    if (not helix and _self.get_setting_int('auto_dss')
            and not _self.count_atoms(traced + ' and ss S', state=1)):
        return residues
    return helix


#: Build-time costs in seconds, measured headless at the app's cadence
#: (pump(100) every 500 ms): per atom per leg, and per atom per frame with no
#: clean-up plus per clean-up cycle.  2kpo (1860 atoms) 300 frames took 8 s at
#: 0 cycles and 32 s at 3, 1200 frames 117 s at 3; 50k atoms x 45 frames 88 s
#: at 3; these read them within +-30 %.  MorphSettings.buildSeconds (Swift)
#: uses the same three numbers for the Morph sheet's hint.
_SECONDS_PER_ATOM_LEG = 0.05e-3
_SECONDS_PER_ATOM_FRAME = 1.4e-5
_SECONDS_PER_ATOM_FRAME_CYCLE = 1.1e-5


def build_seconds(atoms, legs, frames, refinement):
    '''Rough seconds the app takes to build a morph of *atoms* atoms with
    *legs* legs, *frames* frames in all and *refinement* clean-up cycles: a
    hint only (spec section 5.2); nothing is refused on time.'''
    per_frame = (_SECONDS_PER_ATOM_FRAME
                 + _SECONDS_PER_ATOM_FRAME_CYCLE * max(int(refinement), 0))
    return atoms * (legs * _SECONDS_PER_ATOM_LEG + frames * per_frame)


def morph_estimate(source, frames_per_model=15, loop=1, refinement=3,
                   _self=cmd):
    '''Estimate resource usage for morphing *source*.

    Returns a dict with keys:
      models, legs, frames, atoms, bytes, seconds, warn, refuse

    ``bytes`` is bytes_per_frame(source) times the frames: the memory the
    finished morph holds.  ``seconds`` is build_seconds(): the build-time hint
    the Morph sheet shows.  ``warn`` / ``refuse`` are true when it is above
    the thresholds() (WARN_BYTES / REFUSE_BYTES when set, else the platform
    figures, read at call time).
    '''
    models = _self.count_states(source)
    legs = models if loop else max(1, models - 1)
    frames = legs * frames_per_model
    atoms, per_frame = frame_cost(source, _self)
    nbytes = per_frame * frames
    seconds = build_seconds(atoms, legs, frames, refinement)
    warn, refuse = thresholds()

    return {
        'models': models,
        'legs': legs,
        'frames': frames,
        'atoms': atoms,
        'bytes': nbytes,
        'seconds': seconds,
        'warn': nbytes > warn,
        'refuse': nbytes > refuse,
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
    if method in _RIGID_METHODS:
        # one name for cmd.morph's aliases of the same method: reuse=1
        # compares specs, and the sheet's Method control knows two values
        method = 'rigimol'
    elif method != 'linear':
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

    Shared with a worker thread: ``state``, ``error``, ``_traceback``,
    ``done_legs``, ``_held`` and the snapshot (``_coords``, ``_info``,
    ``_pos``) change only under ``_lock``; ``_queue`` carries finished legs
    to the main thread; ``_room`` (a Condition on ``_lock``) is notified
    when a leg is queued or has landed and when the job ends (the worker
    waits on it for room, pump() for the next leg); ``_cancel`` stops the
    worker.
    ``landed_legs``, ``_landing`` and the remaining flags belong to the main
    thread.'''

    def __init__(self, name, source, spec, fingerprint, pos, coords, info, run):
        self.name = name
        self.source = source
        self.spec = spec
        self.fingerprint = fingerprint
        self.build = next(_BUILDS)  # this build's number (morph_sources)
        self.frames_per_model = spec['frames_per_model']
        self.natoms = len(pos)      # atoms in the morph object
        self.models = len(coords)
        # 0 for a refusal's record (_record_refusal), which has no models
        self.legs = max(self.models if spec['loop'] else self.models - 1, 0)
        self.done_legs = 0          # computed by step()
        self.landed_legs = 0        # written into the object by pump()
        # frames loaded: the object has 1 + this states (the last one may
        # still be being cleaned up, _landing[3])
        self._landed = 0
        self._output_crc = None     # _frame_crc of the finished morph (_complete)
        self.state = 'queued'
        self.error = None
        self._traceback = None      # of an unexpected failure, printed by the main thread
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
        # [leg, frames, next frame to load, clean-up cycles still to run on
        # the frame loaded last] for the leg being landed
        self._landing = None
        self._finalised = False     # terminal and cleaned up on the main thread
        self._dismissed = False
        self._sculpting = False     # sculpting activated on the morph (_sculpt_activate)
        self._unbuilt = 0           # landed frames whose reps are not built yet
        self._build_cost = None     # seconds to build one frame; None: not measured
        # seconds per unit of pump work (_note_land_cost)
        self._land_cost = 0.0
        # seconds per clean-up cycle (_sculpt_slice); None: not measured
        self._cycle_cost = None

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
            # A CmdException explains itself; anything else is a bug, whose
            # traceback the main thread prints when it cleans up: in the app
            # a write to stderr goes into the core, which is main-thread only.
            tb = (None if isinstance(e, pymol.CmdException)
                  else traceback.format_exc())
            self._terminate('error', _message(e), tb)
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

    def _terminate(self, state, error=None, tb=None):
        '''End the job in *state* unless it has already ended: a terminal
        state is never overwritten.  *tb*: the traceback of the failure, for
        _print_traceback.  True when this call ended it.'''
        with self._room:
            if self.state not in _ACTIVE:
                return False
            self.error, self.state, self._traceback = error, state, tb
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
    way pump() only lands what is queued; it never calls ``step()``.

    Refusals come cheapest first: the source's type, its number of models,
    the memory limit, and only then validate_source's per-state checks, so a
    trajectory too large to morph is refused without visiting its states.'''
    spec = _make_spec(frames_per_model, loop, method, refinement, rate, copy_look)
    models = _molecular_models(source, _self)
    if models < 2:
        raise pymol.CmdException(
            'morph: %s has one model; morph needs at least two' % source)
    est = morph_estimate(source, spec['frames_per_model'], spec['loop'],
                         spec['refinement'], _self=_self)
    if est['refuse']:
        raise pymol.CmdException(
            'morph: this morph needs about %d MB. Reduce frames per model or '
            'morph fewer models' % (est['bytes'] // 1000000))
    validate_source(source, _self)
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
        try:
            job._thread.start()
        except Exception as e:              # e.g. no more threads
            _fail(job, e, _self)
            raise pymol.CmdException('morph: could not start the worker: %s' % e)
    return job


def pump(budget_ms=100, only=None, _self=cmd):
    '''Land computed frames on the main thread, build their representations
    while the morph is hidden (_prebuild), then finish jobs whose last leg
    landed.

    The work comes in units: loading one frame, activating sculpting (once
    per job), or running an intermediate's sculpting clean-up: all its
    cycles in one call when they fit what is left of *budget_ms* at the
    measured cost per cycle, else a slice of _SCULPT_CYCLES cycles (a frame
    counts as landed after its last cycle).  A unit is taken only while
    running it and building every frame this pump landed still fit in what
    is left of *budget_ms*, at the costs measured so far (a job's first
    frame is built at once to measure them).
    A worker computing a job's next leg is waited for only within that same
    allowance, so a pump that only waits returns that reserve early.  Every
    job still gets one unit, so pump(budget_ms=0) makes progress; when that
    unit alone used the budget, the frames it completed are built by the
    next pump.  A pump therefore overruns *budget_ms* only by that one unit
    (activating sculpting on a large morph is the dearest: 1.5 s at 50k
    atoms) or by the error of the estimates; the budget is shared by all
    jobs.

    *only*: advance that job alone (morph_object's own job when it runs to
    completion), not every job.  Never raises: a failing job goes to the
    error path.'''
    deadline = time.monotonic() + max(float(budget_ms), 0.0) / 1000.0
    jobs = list(_JOBS.values()) if only is None else [only]
    for job in [j for j in jobs if not j._finalised]:
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
    if not _holds(job, 1 + job._landed, _self):
        # Another object took the name (created over it, or brought in by a
        # load), or the morph was edited in place: it is not this job's to
        # grow, retitle or delete.
        _release(job, 'error',
                 'morph: %s was replaced while it was being built' % job.name,
                 _self)
        return
    while _unit(job, deadline, _self):
        if job._build_cost is None and time.monotonic() < deadline:
            _prebuild(job, _self)           # first frame: measure the build
        if time.monotonic() + _reserve(job, 1) >= deadline:
            break                           # one more would not fit once built
    # Build what this pump landed, unless its one guaranteed unit (a clean-up
    # slice of a large morph, say) has already used the budget: those frames
    # then wait for the next pump, whose first unit is the next frame's cheap
    # load, and at the latest for the leg's key frame (_frame_in).
    if time.monotonic() < deadline:
        _prebuild(job, _self)


def _reserve(job, extra):
    '''Seconds to run *extra* more units and to build their frames together
    with the frames landed since the last _prebuild, at the measured costs
    (a clean-up slice adds no frame: the estimate errs towards a smaller
    pump).'''
    return (extra * job._land_cost
            + (job._unbuilt + extra) * (job._build_cost or 0.0))


def _worker_alive(job):
    return job._thread is None or job._thread.is_alive()


def _wait_for_leg(job, deadline):
    '''A worker job with nothing queued is computing its next leg: wait for
    it until *deadline* (no wait once it has passed).  The wait releases the
    job lock and the GIL; a queued leg, a terminal state and _end wake it.
    run=False jobs are never waited for: their legs come from the caller.

    A worker that has exited with legs still to compute died (or never
    started): the job fails, instead of every pump idling its budget for a
    leg that never comes.'''
    if not job.run:
        return
    with job._room:
        while (job._queue.empty() and job.state in _ACTIVE
               and not job._cancel.is_set() and job.done_legs < job.legs
               and _worker_alive(job)):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            job._room.wait(remaining)
        died = (job._queue.empty() and job.state in _ACTIVE
                and job.done_legs < job.legs and not _worker_alive(job))
    if died:                                # _terminate takes the lock
        job._terminate('error', 'morph: worker died')


def _unit(job, deadline, _self):
    '''One unit of work: clean-up cycles of the frame loaded last (or the
    activation they need first), or else the next frame loaded.  False when
    the job must wait or has ended.'''
    if job.state in _FAILED:                # step() failed during this pump
        _finalise_failed(job, _self)
        return False
    if job._landing is not None and job._landing[3]:
        _sculpt_slice(job, deadline, _self)
        return True
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
            job._landing = [leg, frames, 0, 0]
    if job._landing is not None:
        _land_frame(job, _self)
        return True
    if job.landed_legs >= job.legs:
        _complete(job, _self)
    return False


def _land_frame(job, _self):
    '''Load the next frame of the leg being landed.  An intermediate that is
    cleaned up gets its sculpting cycles as later units (_sculpt_slice);
    any other frame is in at once (_frame_in).'''
    t = time.monotonic()
    leg, frames, k, _ = job._landing
    _self.load_coordset(frames[k], job.name, 0)
    job._landed += 1
    job._landing[2] = k + 1
    if k + 1 < len(frames) and job.spec['refinement'] > 0:
        job._landing[3] = morphing._SCULPT_CYCLES * job.spec['refinement']
        _note_land_cost(job, time.monotonic() - t)
        return
    _frame_in(job, t, _self)


def _sculpt_slice(job, deadline, _self):
    '''Run clean-up cycles on the intermediate loaded last (state
    ``2 + leg·f + j`` for frame j of the leg, and _landing[2] is j + 1); it
    is in once its last cycle has run.

    Every sculpt_iterate call pays its own setup and non-bonded passes
    (layer2/Sculpt.cpp resets them per call), so cycles split over several
    calls cost more than one call and do not give the same coordinates.
    The cycles left therefore run in one call when they fit before
    *deadline* (_slice_cycles), as they always do with no budget to speak
    of (morph_object async_=0), and in slices of _SCULPT_CYCLES only when
    they do not: a large morph's pump then checks its budget between
    slices.  Activating sculpting, which the first call needs, is a unit of
    its own: it costs more than a slice for a large morph.'''
    t = time.monotonic()
    if not job._sculpting:
        _sculpt_activate(job, _self)
        _note_land_cost(job, time.monotonic() - t)
        return
    leg, frames, k, left = job._landing
    cycles = _slice_cycles(job, left, deadline)
    _self.sculpt_iterate(job.name, 1 + leg * job.frames_per_model + k, cycles)
    per = (time.monotonic() - t) / cycles
    job._cycle_cost = per if job._cycle_cost is None else 0.5 * (job._cycle_cost + per)
    job._landing[3] = left - cycles
    if job._landing[3]:
        _note_land_cost(job, time.monotonic() - t)
    else:
        _frame_in(job, t, _self)


def _slice_cycles(job, left, deadline):
    '''How many of the *left* clean-up cycles the next call runs: all of
    them when, at the measured cost per cycle, they fit before *deadline*
    together with building this frame and the frames waiting for _prebuild;
    otherwise a slice of _SCULPT_CYCLES (fewer when fewer are left).  The
    job's first call is a slice, which measures the cost.  Every call has
    fixed costs, so the cost per cycle measured on slices overestimates a
    whole frame's call (the error is on the side of a slice); measured on
    whole frames' calls, it matches the next one.'''
    cycles = min(morphing._SCULPT_CYCLES, left)
    if job._cycle_cost is None or cycles == left:
        return cycles
    room = (deadline - time.monotonic()
            - (job._unbuilt + 1) * (job._build_cost or 0.0))
    return left if left * job._cycle_cost <= room else cycles


def _frame_in(job, t, _self):
    '''The frame loaded last is complete (cleaned up, if it is): it joins the
    frames _prebuild builds.  Once the leg's key frame is in, title the leg,
    build the leg's frames, and only then let the worker compute the next
    leg.  *t*: when this unit began (_note_land_cost).'''
    job._unbuilt += 1
    leg, frames, k, _ = job._landing
    if k < len(frames):
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
    _prebuild(job, _self)
    with job._room:
        job._held -= 1
        job._room.notify_all()              # the worker may compute the next leg


def _note_land_cost(job, seconds):
    '''Running estimate of the time one unit takes: a frame loaded,
    sculpting activated or a clean-up call.'''
    job._land_cost = seconds if not job._land_cost else 0.5 * (job._land_cost + seconds)


def _sculpt_activate(job, _self):
    '''Set up the clean-up as morphing.sculpt_states does: backbone fixed,
    sculpting imprinted from model 1.

    Sculpting is activated before the job's first clean-up call and stays
    active until the job ends (_sculpt_off): activating costs far more than
    a slice for a large morph (1.5 s at 50k atoms), so it is paid once per
    job, not once per pump.  The morph's own ``sculpting`` setting is off
    meanwhile.  With the global setting on (the Sculpting menu, or
    auto_sculpt while dragging atoms, at any moment), the draw loop's
    ExecutiveSculptIterateAll sculpts the current state of every activated
    molecule whose ``sculpting`` is on: for the hidden morph that state is
    usually a key frame, which must stay an exact copy of its model.  An
    explicit sculpt_iterate does not read the setting.'''
    job._sculpting = True
    _self.set('sculpting', 0, job.name, quiet=1)
    _self.flag('fix', '%s and %s' % (job.name, morphing._SCULPT_FIX), 'set', quiet=1)
    _self.sculpt_activate(job.name, 1)


def _sculpt_off(job, _self, mine=False):
    '''Undo _sculpt_activate when the job ends: deactivate sculpting, clear
    the fix flags and drop the object-level ``sculpting`` off.  Only on the
    job's own object: *mine* when the caller knows it is (_complete), else
    when the object under the name still carries that setting
    (_sculpt_marked), which is the morph, edited in place perhaps, but never
    an object that replaced it or a name that is gone.'''
    if not job._sculpting:
        return
    job._sculpting = False
    try:
        if mine or _sculpt_marked(job, _self):
            _self.sculpt_deactivate(job.name)
            _self.flag('fix', job.name, 'clear', quiet=1)
            _self.unset('sculpting', job.name, quiet=1)
    except Exception:
        pass                                # e.g. the object went meanwhile


def _sculpt_marked(job, _self):
    '''True when the object under *job*'s name carries the object-level
    ``sculpting`` off that _sculpt_activate set and only _sculpt_off removes:
    the job's own object.  An object that took the name starts without it:
    one from a load (a .pse never holds a building morph: session_save) or
    a delete and create.  Editing the morph in place (removing atoms,
    loading or creating states into it) keeps the object, and the setting.'''
    import pymol.setting as _ps
    if job.name not in _self.get_names('objects'):
        return False
    index = _ps._get_index('sculpting')
    return any(i == index and not v
               for i, _t, v in _self.get_object_settings(job.name) or ())


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
    built = False
    _self.enable(name)
    try:
        with _self.lockcm:
            # update phase only: reps mask 0, update 1, build 0 (layer4/Cmd.cpp)
            prepare(_self._COb, [name], 0, 1, 0)
        built = True
    except Exception:
        pass                                # e.g. a modal draw owns the core
    finally:
        _self.disable(name)
    if built:
        # per frame, with the call's fixed cost spread over the frames: rises
        # at once, falls by halves, so an estimate errs towards a smaller pump.
        # A failed call measured nothing: its near-zero time would let the
        # next pump land and build far more than its budget allows.
        per = (time.monotonic() - t) / job._unbuilt
        old = job._build_cost
        job._build_cost = per if old is None or per > old else 0.5 * (old + per)
    job._unbuilt = 0


def _complete(job, _self):
    '''Verify the finished morph, then show it in place of the source.  The
    morph gets no object-level ``state``: like any multi-state object it
    follows the global frame (mset, mplay, a Lockstep clip, movie export).'''
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
    try:
        job._output_crc = _frame_crc(name, _self)
    except Exception:
        job._output_crc = None      # a session restore then forgets the record
    _sculpt_off(job, _self, mine=True)
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


def _print_traceback(job):
    '''Print, once, the traceback a worker kept for an unexpected failure
    (main thread only: in the app stderr writes into the core).'''
    with job._lock:
        tb, job._traceback = job._traceback, None
    if tb:
        sys.stderr.write(tb)


def _finalise_failed(job, _self):
    '''Cancel/error cleanup: drop the partial morph and show the source
    again.  The record stays in recent_objects() until morph_dismiss.  An
    object that took the name meanwhile is not the partial morph: it stays,
    and so do its sculpting and fix flags (_sculpt_off).'''
    _print_traceback(job)
    _end(job)
    _sculpt_off(job, _self)
    try:
        names = _self.get_names('objects')
        if job.name in names and _holds(job, 1 + job._landed, _self):
            _self.delete(job.name)
        if job.source in names:
            _self.enable(job.source)
    except Exception:
        pass


def _release(job, state, error, _self):
    '''End *job* without touching the session: stop its worker and drop what
    it holds, but delete, enable or disable nothing, because the objects it
    used were replaced and the names now belong to whatever replaced them.  A
    job that had already ended keeps its state.

    The one exception is the sculpting it activated: a partial morph edited
    in place (other atoms or states, the same object) is the user's now,
    and keeps neither the backbone fix flags nor the morph's own
    ``sculpting`` off; an object that replaced the morph is left alone
    (_sculpt_off).'''
    job._terminate(state, error)
    _print_traceback(job)
    _sculpt_off(job, _self)
    _end(job)


def _holds(job, states, _self):
    '''True when the object under *job*'s name is a molecule with the job's
    atoms and *states* states: still the morph the job is building (states
    ``1 + job._landed``) or built (``legs * frames_per_model``).  Cheapest
    test first: count_atoms is a selector pass over the session.'''
    try:
        return (_self.get_type(job.name) == 'object:molecule'
                and _self.count_states(job.name) == states
                and _self.count_atoms(job.name) == job.natoms)
    except pymol.CmdException:
        return False                # no such object any more


def _frame_crc(name, _self):
    '''CRC32 of the coordinates of state 2, the first interpolated frame: it
    depends on the models and on every setting that shapes the morph (method,
    rate, refinement, frames per model), so another build with the same atoms
    and states does not match.  The frame survives a .pse round trip exactly.'''
    xyz = []
    _self.iterate_state(2, name, 'xyz.extend((x, y, z))', space={'xyz': xyz})
    return binascii.crc32(struct.pack('<%dd' % len(xyz), *xyz)) & 0xFFFFFFFF


def _is_output(job, _self, exact=False):
    '''True when *job* finished and the object under its name is still its
    output: a molecule with the job's atoms and states, cheap enough for every
    panel poll.  *exact* also compares the first interpolated frame with the
    one the job built (_frame_crc), for a session restore: an object a .pse
    brought back under the name may be another build of the same size.'''
    if job.state != 'done':
        return False
    if not _holds(job, job.legs * job.frames_per_model, _self):
        return False
    if not exact:
        return True
    try:
        return (job._output_crc is not None
                and _frame_crc(job.name, _self) == job._output_crc)
    except Exception:
        return False


def _message(exc):
    '''The error text a tray card shows: a CmdException's own message,
    without the " Error: " label its str() adds.'''
    if isinstance(exc, pymol.CmdException) and exc.message:
        return str(exc.message)
    return str(exc) or exc.__class__.__name__


def _fail(job, exc, _self):
    '''End *job* in error for *exc*, raised on the main thread, and clean up.
    A CmdException explains itself; anything else is a bug, whose traceback
    is printed (the card keeps the one-line message).'''
    if not isinstance(exc, pymol.CmdException):
        traceback.print_exception(type(exc), exc, exc.__traceback__)
    job._terminate('error', _message(exc))
    _finalise_failed(job, _self)


# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

def morph_object(source, name=None, frames_per_model=15, loop=1,
                 method='rigimol', refinement=3, rate='linear', copy_look=1,
                 async_=1, reuse=0, quiet=1, _self=cmd, **kwargs):
    '''
DESCRIPTION

    Build a smoothly playing morph of a multi-state object: every pair of
    consecutive models is interpolated (rigid segments on screw paths, then
    sculpting clean-up), the key frames stay exact copies of the models, and
    the result replaces the source on screen when it is complete.

    A refused morph (one model, models with different atoms, not a
    molecule, larger than the memory limit, ...) raises and creates
    nothing; its reason stays listed as a failed morph (the app's progress
    tray shows it) until morph_dismiss.

USAGE

    morph_object source [, name [, frames_per_model [, loop [, method
        [, refinement [, rate [, copy_look [, async [, reuse ]]]]]]]]]

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

    async = 0/1: build in the background (1) or finish before returning;
    written async_ from Python, as for fetch {default: 1}

    reuse = 0/1: keep an existing morph built with the same settings from
    the unchanged source {default: 0}

SEE ALSO

    morph, morph_cancel, morph_dismiss
    '''
    # **kwargs takes `async` (a Python keyword) as fetch does.  It also turns
    # off the parser's check of argument names (parsing.prepare_call), so
    # anything else left over is refused here.
    async_ = int(kwargs.pop('async', async_))
    if kwargs:
        raise pymol.CmdException('morph_object: unknown argument(s): %s'
                                 % ', '.join(sorted(kwargs)))
    spec = None
    try:
        spec = _make_spec(frames_per_model, loop, method, refinement, rate,
                          copy_look)
        if int(reuse):
            target = _target_name(source, name, _self)
            job = _JOBS.get(target)
            if (job is not None and job.source == source and job.spec == spec
                    and _is_output(job, _self)
                    and job.fingerprint == fingerprint(source, _self)):
                return target
        job = start_job(source, name, run=bool(int(async_)), _self=_self, **spec)
    except pymol.CmdException as exc:
        _record_refusal(source, name, spec, exc, _self)
        raise
    if job.run:
        if not int(quiet):
            print(' morph_object: building %s (%d legs)' % (job.name, job.legs))
        return job.name
    # its own job only: another morph a worker builds meanwhile is left to
    # the app's polls, not waited for here
    while job.step():
        pump(budget_ms=10 ** 9, only=job, _self=_self)
    pump(budget_ms=10 ** 9, only=job, _self=_self)
    if job.state != 'done':
        raise pymol.CmdException(job.error or 'morph: %s did not complete' % job.name)
    if not int(quiet):
        print(' morph_object: %s, %d states from %d models'
              % (job.name, job.legs * job.frames_per_model, job.models))
    return job.name


#: The spec a refusal's record carries when the arguments themselves were
#: refused (morph_spec reports it).
_DEFAULT_SPEC = _make_spec(15, 1, 'rigimol', 3, 'linear', 1)


def _record_refusal(source, name, spec, exc, _self):
    '''Register a refused morph_object as a failed job, so the tray shows a
    "Morph failed" card and the MCP state lists it, as for a morph that fails
    while it builds: start_job refuses before any job exists, and the app
    starts a morph without waiting for an answer.

    Filed under the morph's name (the conventional ``<source>_morph`` when
    the name itself was refused), replacing a cancelled or failed record
    there.  Nothing is filed while a job builds under that name (its running
    card is showing), and a finished morph's record is never displaced
    (morph_sources, the badge and the clip stride read it): the card goes
    under ``<name> (refused)`` instead.  The record holds no object, so
    morph_dismiss is all it needs.  A failed record the pump has not cleaned
    up yet is cleaned up first (_finalise_failed): once replaced, the pump
    never sees it, and its hidden partial morph would stay.'''
    try:
        target = _target_name(source, name, _self)
    except Exception:
        target = None
    if not target:
        try:
            target = _self.get_legal_name(str(source) + '_morph')
        except Exception:
            target = str(source) + '_morph'
    old = _JOBS.get(target)
    if old is not None and old.state in _ACTIVE:
        return
    if old is not None and old.state in _FAILED and not old._finalised:
        _finalise_failed(old, _self)
    key = target if old is None or old.state in _FAILED else target + ' (refused)'
    job = MorphJob(key, source, spec or _DEFAULT_SPEC, {}, {}, [], [], False)
    job._terminate('error', _message(exc))
    _end(job)
    _JOBS[key] = job


def morph_cancel(name, quiet=1, _self=cmd):
    '''
DESCRIPTION

    Cancel a morph that is being built: the partial object is deleted and the
    source is shown again.  The morph is then listed as cancelled (the app's
    progress tray shows a "Morph cancelled" card) until morph_dismiss.
    Cancelling a rebuild also loses the previous morph, which was deleted
    when the rebuild started.

USAGE

    morph_cancel name

ARGUMENTS

    name = str: the morph object being built (e.g. 2kpo_morph), not the
    source it is built from

SEE ALSO

    morph_object, morph_dismiss
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

    Forget the record of a cancelled or failed morph: its card in the app's
    progress tray and its entry in the MCP session state.  A completed morph
    leaves nothing to dismiss.

USAGE

    morph_dismiss name

ARGUMENTS

    name = str: the morph object the record is listed under (e.g.
    2kpo_morph), not the source; a morph refused while a finished morph held
    that name is listed as "2kpo_morph (refused)"

SEE ALSO

    morph_object, morph_cancel
    '''
    job = _JOBS.get(name)
    if job is not None and job.state in _FAILED:
        job._dismissed = True
    elif not int(quiet):
        print(' morph_dismiss: no cancelled or failed morph named %s' % name)


def morph_spec(name, _self=cmd):
    '''``{'source', 'spec', 'fingerprint', 'state', 'started'}`` of the job
    that last built *name* this session (terminal included), or None.  A
    finished job's record only while *name* is still its output.'''
    job = _JOBS.get(name)
    if job is None or (job.state == 'done' and not _is_output(job, _self)):
        return None
    return {'source': job.source, 'spec': dict(job.spec),
            'fingerprint': dict(job.fingerprint),
            'state': job.state, 'started': job.started}


def morph_sources(_self=cmd):
    '''``{morph_name: {'source', 'spec', 'build'}}`` for completed morphs that
    still exist as the job built them (_is_output): the stride the Timeline
    maps a morph clip with comes from here.  ``build`` is the job's number
    (_BUILDS): a new one means the morph was built again.'''
    names = set(_self.get_names('objects'))
    return {n: {'source': j.source, 'spec': dict(j.spec), 'build': j.build}
            for n, j in list(_JOBS.items()) if n in names and _is_output(j, _self)}


# --------------------------------------------------------------------------
# Session replacement and session files
# --------------------------------------------------------------------------

def reset(names=None, *, dismiss=False, _self=cmd):
    '''Objects were replaced under the registry: by a session load or
    ``reinitialize`` (*names* None: every object), or by a partial load
    (*names*: the objects it brought in).

    A job building one of them stops without touching it, since the name now
    belongs to the session that replaced it; its tray card reads cancelled.
    A finished morph's record goes unless the object there is still exactly
    that morph, as after the Theme studio restores its snapshot: the Timeline
    then maps a restored morph clip with the stride the clip saved.

    *dismiss* (a new session: ``reinitialize``, the app's Clear Session):
    nothing is left to explain, so a job it stops leaves no card and the
    records of earlier cancelled or failed morphs go as well.'''
    for name, job in list(_JOBS.items()):
        if names is not None and name not in names:
            continue
        if not job._finalised:
            _release(job, 'cancelled',
                     'morph: stopped because the session was replaced', _self)
            if dismiss:
                job._dismissed = True
        elif job.state == 'done' and not _is_output(job, _self, exact=True):
            del _JOBS[name]
        elif dismiss and job.state in _FAILED:
            del _JOBS[name]


def session_restore(session, *, _self=cmd, **_kwargs):
    '''Session-restore task: a .pse load replaced the objects under the
    registry (reset).  A partial load (``load x.pse, partial=1``) replaced
    only the objects it carries.  Never fails the load.'''
    try:
        from pymol import raymol_scenes
        names = None
        if raymol_scenes.restoring_partial(_self):
            names = {e[0] for e in session.get('names') or ()
                     if e and isinstance(e[0], str)}
        reset(names, _self=_self)
    except Exception as e:
        print(' morph_jobs: session restore: %s' % e)
    return 1


def session_save(session, *, _self=cmd, **_kwargs):
    '''Session-save task: leave morphs still being built out of the .pse.

    A partial morph would come back as an ordinary object, hidden and holding
    the frames landed so far, and nothing would finish it: the job does not
    travel with the session.  The source stays (it is shown while its morph
    builds), and so does a Timeline clip naming the morph: morphing the source
    again builds it under that name and the clip plays it.  Edits the copy
    being written, after get_session filled ``session['names']``, so the live
    session and the job are untouched (as predicting.session_save does for
    its placeholders).'''
    names = session.get('names')
    if not names:
        return 1
    building = {n for n, j in list(_JOBS.items())
                if not j._finalised and _holds(j, 1 + j._landed, _self)}
    if building:
        session['names'] = [e for e in names if not (e and e[0] in building)]
    return 1


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
        if job.legs == 0:                   # a refusal (_record_refusal)
            detail = str(error or '')
        else:
            detail = 'leg %d of %d · %d%%' % (job.landed_legs, job.legs,
                                              int(fraction * 100))
        return {
            'state': state, 'phase': phase, 'fraction': fraction,
            'moving': state == 'running',
            'models_done': job.landed_legs, 'models_total': job.legs,
            'elapsed': max(end - job.started, 0.0),
            'error': None if error is None else str(error),
            'detail': detail,
            'bundle': None, 'step': None, 'total_steps': None,
            'remaining': None, 'batch': None, 'batch_index': None,
            'batch_total': None, 'run_remaining': None,
        }
    except Exception:
        return None
