'''
morph_jobs — building blocks for the morph job layer.

Provides naming, estimation, validation, look-copying and title helpers that
the MorphJob class (Task 3) and the Swift side (Task 4) depend on.  Keep this
module free of threading, queues, and UI concerns.

Convention: only alt ''+A atoms are counted (consistent with morphing.py).
'''

import binascii
import sys

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
# Job registry — Task 3 fills this; morph_name reads it.
# Maps morph-object-name -> job object (with a .source attribute).
# --------------------------------------------------------------------------

_JOBS = {}

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

    Returns ``<source>_morph`` when that name is free in the session or when
    the slot is already held by a morph job for this source.  Falls back to
    ``<source>_morph2``, ``<source>_morph3``, … with the same rule.
    Names are legalised with ``cmd.get_legal_name``.
    '''
    suffix = 2
    base = source + '_morph'
    name = _self.get_legal_name(base)
    while True:
        existing = _self.get_object_list()
        if name not in existing:
            return name                          # slot is free
        job_source = getattr(_JOBS.get(name), 'source', None)
        if job_source == source:
            return name                          # already a morph of this source
        # Slot taken by something else — try next suffix
        candidate = '%s%d' % (base, suffix)
        name = _self.get_legal_name(candidate)
        suffix += 1


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


# --------------------------------------------------------------------------
# set_state_titles
# --------------------------------------------------------------------------

def set_state_titles(name, models, frames_per_model, loop, _self=cmd):
    '''Assign human-readable titles to every state of a morph object.

    Key-frame states get ``"model N"``; intermediate states get ``"N → M"``.
    When *loop* is true the last state wraps back to model 1.
    '''
    legs = models if loop else max(1, models - 1)
    total = legs * frames_per_model
    kf = morphing.key_frames(total, frames_per_model, legs)

    # Model number at each key-frame index
    def _model_at(kf_idx):
        return (kf_idx % models) + 1   # 0-based index mod models, then 1-based

    for i, kstate in enumerate(kf):
        model_num = _model_at(i)
        _self.set_title(name, kstate, 'model %d' % model_num)

        # Label intermediate states between kf[i] and kf[i+1]
        if i + 1 < len(kf):
            next_state = kf[i + 1]
            next_model = _model_at(i + 1)
            title = '%d → %d' % (model_num, next_model)
            for s in range(kstate + 1, next_state):
                _self.set_title(name, s, title)


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
