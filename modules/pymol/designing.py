"""Backbone design: cmd.design_backbone and friends.

The sibling of `predicting.py`, and thin in the same way: argument marshalling and
session interaction only. The registry lives in `pymol.generators`, and the weight cache,
the non-blocking fetcher and the request/status transport are `pymol.predictors`' --
shared by import, because none of them is sequence-shaped.

WHY NOT `predict`. Every predictor maps chain sequences to a structure. A generator is
handed a target STRUCTURE and returns a chain that did not exist, so there is no sequence
to type and nothing to put in `PredictionSpec.chains`. Routing it through `predict` would
mean a method whose only honest `parse_spec` raises, offered by Tab-completion at the
prompt of the command that cannot run it. See docs/generators.md.

WHAT IS DELIBERATELY SHARED ANYWAY. The ETA arithmetic, the tooltip wording and the
progress composition are imported from `predicting` rather than reimplemented. Those
carry real traps -- a NaN fraction poisons a monotone floor permanently, a phase change
has to restart the clock, the tooltip has to word an estimate at the scope it was measured
-- and two copies of that policy would drift. What is NOT shared is the job bookkeeping:
a design's jobs are its own, because a design and a prediction are not interchangeable
rows in one list, and because `predicting`'s progress lookup resolves a job's method
through the predictor registry, which by construction does not know a generator.

Every function ends its signature with _self=cmd. That is load-bearing: pymol2/cmd2.py
binds _self only when it appears in the argspec, and otherwise copies the function
verbatim so it silently drives the GLOBAL instance.
"""
import sys

from . import colorprinting
from . import predicting
from .generators import registry
from .generators.base import (KEPT_ALTLOCS, STANDARD_AA3, TargetResidue,
                              TargetStructure, looks_like_bare_residue_list)
from .generators.metrics import STATS_FIELDS
from .predictors import fetching
from .predictors.errors import PredictionInputError, PredictionOptionError

cmd = sys.modules["pymol.cmd"]

#: Reused verbatim from `predicting`, on purpose -- see the module docstring. These are
#: pure functions of a status dict with no predictor knowledge in them.
_as_float = predicting._as_float
_as_int = predicting._as_int
_format_detail = predicting._format_detail
_phase_remaining = predicting._phase_remaining
format_remaining = predicting.format_remaining

_JOBS = {}

#: Upper bound for a randomly chosen seed. Below 2**53 so the value survives a JSON
#: round-trip through a Double on the Swift side.
RANDOM_SEED_BOUND = 2 ** 32

#: Hex digits of the design key used in a derived object name.
OBJECT_NAME_DIGEST_CHARS = 8

#: name -> LIST of outstanding job ids. A list for shape-compatibility with the panel
#: payload `predicting` already publishes, never for several designs: EACH DESIGN IS ITS
#: OWN OBJECT, which is the data-model decision this module makes and the reason is worth
#: stating. `n_models` of a prediction are samples of one distribution over one input, so
#: they belong in one object as states. Two designs at two seeds are not that -- they are
#: different molecules with different sequences, different geometry and separate
#: identities, and stacking them as states of one object would give them one metric row
#: per state with nothing saying which sequence each described.
_PENDING = {}

#: name -> progress bookkeeping the job handles cannot supply. Same shape as
#: `predicting._TRACK`, because `_format_detail` and the panel payload read it.
_TRACK = {}

#: name -> the last record of a job that ended badly, held so the card can say WHY a
#: seventeen-minute run produced nothing. Success is not retained: the loaded object is
#: its own confirmation.
_RECENT = {}

#: How many terminal records to hold.
MAX_RECENT = 16

#: name -> the most recent pending_info() result. A FALLBACK only, for a name that left
#: _PENDING before the discard reached it.
_LAST_INFO = {}

#: name -> the layout of a live design's object, while its run is still going.
#:
#: `{'offset': atoms before the generated chain, 'atoms': atoms in it,
#:   'target': the target's coordinates, as a list of [x, y, z]}`
#:
#: Written by `trajectory_seed`, read by `trajectory_frame`, and REMOVED by whichever of
#: `deliver_result` / `discard_pending` gets there first. Its presence is what says "every
#: atom of this object came from the live view, not from a delivered design" -- which is
#: what `discard_pending` and `session_save` need in order to keep treating a run that
#: never finished as though the object were still the empty placeholder it replaced.
_TRAJECTORY = {}


def weight_cache():
    """The process-wide WeightCache -- `predicting`'s, not a second one.

    One cache, because a bundle is identified by id and version and the cache root is a
    property of the machine, not of the method that wants it. Two caches would put the
    same bytes in the same place through two lock namespaces, which is exactly the
    concurrent-download hazard `WeightCache._acquire_lock` exists to prevent.
    """
    return predicting.weight_cache()


def job_ids():
    """Ids of every design job submitted this session, newest last."""
    return list(_JOBS)


def pending_objects():
    """Copy of the pending map: object name -> list of outstanding job ids."""
    return {name: list(ids) for name, ids in _PENDING.items()}


def recent_objects():
    """Names whose job ended badly and whose card is still waiting to be seen."""
    return list(_RECENT)


def default_object_name(design_key, generator_id=''):
    """The object name a design lands in when the caller does not pick one.

    Shaped `<generator>_design_<key>`, e.g. `rfd3_design_1f4c9e02`. Derived from the
    DESIGN KEY rather than from the target alone, so two seeds against one target are
    two objects automatically and re-running an identical design lands back in the same
    one -- and so the name a user sees is a prefix of the identity a later refold is
    matched against.
    """
    method = ''.join(ch for ch in str(generator_id) if ch.isalnum() or ch == '_')
    stem = 'design_%s' % str(design_key)[:OBJECT_NAME_DIGEST_CHARS]
    return '%s_%s' % (method, stem) if method else stem


def _legal_object_name(name, _self=cmd):
    """The object name PyMOL will actually use for `name`.

    Creating an object LEGALISES its name -- an apostrophe, a space and a forward slash
    all become underscores -- and nothing tells the caller. So a name chosen here and the
    object that actually exists are two different strings, and every table keyed on the
    chosen one then addresses an object that is not there. Passed through this on the way
    in, the placeholder map, the metric record and the live trajectory all key on the one
    string that names a real object.

    `cmd.get_legal_name` rather than a local rewrite: it is the same C++ rule
    (`ObjectMakeValidName`) that creation itself applies, so the two cannot drift. That
    rule is subtler than replacing three characters -- it strips a trailing `)`, yields one
    underscore per BYTE of a multi-byte character, and leaves `+`, `-` and `.` alone -- and
    any reimplementation of it here or in Swift would be a copy waiting to fall out of step.
    It is idempotent, so applying it twice on one path is harmless.

    Applied on EVERY public entry point that takes an object name, `pending_info`
    included -- and identically in `predicting`, whose surface this one mirrors on
    purpose. In production its callers pass keys that came out of these tables, so the
    call is a no-op there, but a rule of "some of these legalise and some do not" is one
    a caller has to know. Measured before deciding: 0.82 us per call, 0.016 ms for twenty
    placeholders on a 500 ms poll tick, 0.003% of it.
    """
    return _self.get_legal_name(str(name))



# -- Reading the target out of the session ------------------------------------


def resolve_target(target, hotspots, quiet=1, _self=cmd):
    """Selection + hotspot selection -> TargetStructure. The only session read here.

    Resolved ONCE, up front: the design key, the size checks and the coordinates the
    engine sees must all describe the same residues, and re-reading later could see a
    target the user has since edited.

    `hotspots` is a selection expression, not a residue list. That is the PyMOL-native
    spelling, it composes with everything else that selects atoms -- including `sele`,
    which is what Design mode's picking writes -- and it makes "the residues I clicked"
    expressible without a second syntax.
    """
    if not str(target).strip():
        raise PredictionInputError('no target selection given')
    if _self.count_atoms(target) == 0:
        raise PredictionInputError(
            'the target selection %r selects no atoms' % (target,))

    # One object, refused explicitly rather than left to the duplicate-residue check in
    # `parse_target`. Two objects can both have a chain A, and residues are grouped by
    # adjacency, so the failure would otherwise surface as "residue A/12 appears twice" --
    # true, but not the thing to fix.
    objects = _self.get_object_list('(%s)' % target)
    if len(objects) > 1:
        raise PredictionInputError(
            'the target selection spans %d objects (%s). A design is generated against'
            ' one structure; select within one object, or "create" a single object from'
            ' what you want first.' % (len(objects), ', '.join(sorted(objects))))

    # The state is resolved and RECORDED rather than left as -1: state 3 of an NMR
    # ensemble is a different target from state 1, and the design key has to say which.
    state = int(_self.get_state())

    # Read straight out of the session. No PDB round trip -- see TargetResidue for why
    # (RFD3Kit's PDB entry point substitutes its own auto-picked target, and its reader
    # merges insertion codes).
    #
    # Hydrogens are excluded here rather than filtered later: the engine's dense atom
    # templates are heavy-atom only, so a hydrogen is wire weight that reaches nothing.
    rows = []
    _self.iterate_state(state, '(%s) and not hydro' % target,
                        'rows.append((chain, resi, resn, name, alt, x, y, z))',
                        space={'rows': rows})

    # THE OBJECT MATRIX HAS TO BE APPLIED BY HAND, and forgetting it is a silent
    # wrong-answer rather than an error. `iterate_state` reports an atom's STORED
    # coordinates; `get_coords` and `get_pdbstr` both apply the object's TTT matrix and
    # `iterate_state` does not. Measured: after `translate [10,0,0], object=t`,
    # get_coords reads 9.999 for an atom iterate_state still reads as -0.001.
    #
    # RayMol ships Move mode, which is exactly a TTT matrix (#204), so a user CAN move a
    # target and then design against it. Without this the design would be generated against
    # where the target used to be and land ten Angstrom off the structure on screen -- a
    # design that looks fine in isolation and is nowhere near its target.
    rows = _apply_object_matrix(objects[0], rows, state, _self=_self)

    residues = []
    key = None
    for chain, resi, resn, name, alt, x, y, z in rows:
        # A second modelled conformer of the same atom, which has one slot. Keeping 'A'
        # and the blank is what every structure pipeline does with an altloc.
        if alt not in KEPT_ALTLOCS:
            continue
        if resn not in STANDARD_AA3:
            continue
        if (chain, resi, resn) != key:
            residues.append(TargetResidue(chain, resi, resn))
            key = (chain, resi, resn)
        residues[-1].atoms.append((name, (x, y, z)))
    residues = tuple(residues)

    _report_excluded(target, residues, state, _self=_self)

    hotspot_indices = _resolve_hotspots(target, hotspots, residues, _self=_self)
    if not int(quiet):
        colorprinting.parrot(
            ' design: target %s -- %d residues, chain %s, state %d, %d hotspot(s): %s'
            % (target, len(residues), residues[0].chain if residues else '?', state,
               len(hotspot_indices),
               ', '.join('%s/%s' % (residues[i].chain, residues[i].resi)
                         for i in hotspot_indices[:8])))
    return TargetStructure(residues, hotspot_indices, source=str(target), state=state)


#: A 4x4 that changes nothing, row-major, as `get_object_matrix` returns it.
_IDENTITY_MATRIX = (1.0, 0.0, 0.0, 0.0,
                    0.0, 1.0, 0.0, 0.0,
                    0.0, 0.0, 1.0, 0.0,
                    0.0, 0.0, 0.0, 1.0)


def _apply_object_matrix(obj, rows, state, _self=cmd):
    """Put `rows`' coordinates where the object actually IS. See the caller for why.

    Compared against the identity rather than applied unconditionally, so the overwhelmingly
    common case -- an object nobody has moved -- costs one comparison and cannot introduce
    float noise into coordinates the design key hashes.
    """
    try:
        matrix = _self.get_object_matrix(obj, state)
    except Exception:
        # An object with no matrix at all. Nothing to apply, and a diagnostic failure here
        # must not take a design down.
        return rows
    if not matrix or len(matrix) != 16:
        return rows
    matrix = tuple(float(value) for value in matrix)
    if all(abs(a - b) < 1e-9 for a, b in zip(matrix, _IDENTITY_MATRIX)):
        return rows
    moved = []
    for chain, resi, resn, name, alt, x, y, z in rows:
        moved.append((
            chain, resi, resn, name, alt,
            matrix[0] * x + matrix[1] * y + matrix[2] * z + matrix[3],
            matrix[4] * x + matrix[5] * y + matrix[6] * z + matrix[7],
            matrix[8] * x + matrix[9] * y + matrix[10] * z + matrix[11]))
    return moved


def _report_excluded(target, residues, state, _self=cmd):
    """Say which PROTEIN residues of the selection the engine will not see.

    Unconditional, not gated on `quiet`, and the distinction is the point. Waters,
    ions, ligands and nucleic acids are not part of a protein target by anyone's
    definition and are dropped in silence. A residue inside the protein chain that the
    reader cannot represent -- a selenomethionine, a phosphoserine, anything not in the
    standard twenty -- is different: it leaves a HOLE in the target, the residues on
    either side are then numbered as neighbours, and nothing in the result would say so.
    A user who is not told cannot know to fix it.
    """
    kept = set((residue.chain, residue.resi) for residue in residues)
    protein = set()
    try:
        # `iterate`, not `iterate_state`, and NO state argument: `cmd.iterate` does not take
        # one. Passing it raises TypeError straight into the except below, which is exactly
        # how this diagnostic was silently doing nothing when it was first written. Residue
        # identity does not vary by state anyway -- only coordinates do.
        _self.iterate('(%s) and polymer.protein' % target,
                      'protein.add((chain, resi))',
                      space={'protein': protein})
    except Exception:
        # A selection language failure here must not take the command down: the checks
        # that matter are in parse_target, and this is a diagnostic.
        return
    missing = sorted(protein - kept)
    if not missing:
        return
    shown = ', '.join('%s/%s' % pair for pair in missing[:6])
    colorprinting.warning(
        ' design: %d protein residue(s) of the target cannot be read by this method and'
        ' are EXCLUDED from it: %s%s. The residues on either side of each gap are then'
        ' presented to the network as neighbours. Only the standard twenty amino acids'
        ' are readable, from ATOM records.'
        % (len(missing), shown, ', ...' if len(missing) > 6 else ''))


def _resolve_hotspots(target, hotspots, residues, _self=cmd):
    """The hotspot selection, as indices into `residues`.

    Every named hotspot must land inside the target. A hotspot outside it is not
    ignorable: hotspots set the sampler's origin, so dropping one silently aims the
    design somewhere else -- which looks exactly like a bad design.
    """
    text = str(hotspots or '').strip()
    if not text:
        raise PredictionInputError(
            'no hotspots given. They are required rather than optional: the interface'
            ' residues set the sampler origin, so without them the design is aimed at'
            ' the centre of mass of the whole target. Give a selection, e.g.'
            ' hotspots="chain A and resi 45+48+52", or hotspots=sele after picking'
            ' them in the viewer.')
    if looks_like_bare_residue_list(text):
        raise PredictionInputError(
            'hotspots is a SELECTION, not a residue list: %r selects nothing. Write it'
            ' as hotspots="resi %s".' % (text, text.replace(' ', '')))

    index_of = {}
    for index, residue in enumerate(residues):
        index_of.setdefault((residue.chain, residue.resi), index)

    picked = set()
    _self.iterate('(%s)' % text, 'picked.add((chain, resi))',
                  space={'picked': picked})
    if not picked:
        raise PredictionInputError(
            'the hotspot selection %r selects no atoms' % (text,))

    outside = sorted(pair for pair in picked if pair not in index_of)
    if outside:
        shown = ', '.join('%s/%s' % pair for pair in outside[:6])
        raise PredictionInputError(
            '%d hotspot residue(s) are not inside the target: %s%s. A hotspot outside'
            ' the target cannot be conditioned on, and dropping it silently would aim'
            ' the design somewhere other than where it was pointed. Either extend the'
            ' target to include them or drop them from the hotspot selection.'
            % (len(outside), shown, ', ...' if len(outside) > 6 else ''))
    return sorted(index_of[pair] for pair in picked)


# -- Deferred submit: designs waiting on a weight download ---------------------


class _DeferredDesignJob:
    """A design that is waiting for its weights.

    Presents the same surface as a real job -- job_id, status(), cancel(), spec, options
    -- so `design_status`, `design_cancel` and the panel need to know nothing about
    deferral. The mirror of `predicting._DeferredJob`, and a separate class rather than a
    reuse because that one stores a `predictor_id` and is advanced by a pump that walks
    the prediction job table.
    """

    __slots__ = ('job_id', 'spec', 'options', 'object_name', 'generator_id',
                 '_generator', '_bundle', '_real', '_error', '_cancelled', '_reaped')

    def __init__(self, spec, options, generator, bundle, object_name):
        import uuid
        # This handle's own id, NOT the host's: the host allocates its id inside
        # submit(), which has not run yet at the point the caller needs something to
        # hold. The two never need to agree -- every host-side path is keyed by the
        # host's id and every session-side path by the object name.
        self.job_id = 'pending-%s' % uuid.uuid4().hex[:12]
        self.spec = spec
        self.options = options
        self.object_name = object_name
        self.generator_id = generator.id
        self._generator = generator
        self._bundle = bundle
        self._real = None
        self._error = None
        self._cancelled = False
        self._reaped = False

    @property
    def submitted(self):
        return self._real is not None

    def status(self):
        if self._real is not None:
            return self._real.status()
        base = {'state': 'running', 'phase': 'weights', 'fraction': 0.0,
                'error': None, 'result_path': None,
                'peak_bytes': None, 'elapsed_s': None}
        if self._error is not None:
            base.update(state='error', error=self._error)
            return base
        if self._cancelled:
            base.update(state='cancelled')
            return base
        fetch = fetching.get(self._bundle.id)
        if fetch is not None:
            snap = fetch.snapshot()
            # The fetch's own phase (download/extract) rather than a flat "weights", so
            # the tray and `design_status` say which half is slow.
            base.update(phase=snap['phase'], fraction=snap['fraction'])
        return base

    def cancel(self):
        """Cancel the design, or -- if it has not started -- the download itself.

        Cancelling the fetch cancels it for every job waiting on the same bundle, which
        is correct: there is one transfer. Each waiting job is then settled by pump().
        """
        if self._real is not None:
            self._real.cancel()
        else:
            self._cancelled = True
            fetching.cancel(self._bundle.id)

    def advance(self, _self=cmd):
        """Main-thread half: submit once the weights are there, or clean up.

        Returns True when this job is fully reaped. Every line here touches the session,
        which is precisely why the fetch worker cannot do any of it.
        """
        if self._reaped:
            return True
        if self._cancelled or self._error is not None:
            self._reaped = True
            discard_pending(self.object_name, _self=_self)
            return True
        fetch = fetching.get(self._bundle.id)
        if fetch is None:
            self._error = 'weight fetch for %s disappeared' % self._bundle.id
            self._reaped = True
            discard_pending(self.object_name, _self=_self)
            return True
        snap = fetch.snapshot()
        if snap['state'] == 'running':
            return False
        self._reaped = True
        if snap['state'] in ('cancelled', 'error'):
            if snap['state'] == 'cancelled':
                self._cancelled = True
            else:
                self._error = snap['error'] or 'weight fetch failed'
            discard_pending(self.object_name, _self=_self)
            return True
        self._real = self._generator.submit(self.spec, self.options, fetch.path)
        return True


def pump(_self=cmd):
    """Advance every deferred design. MAIN THREAD ONLY -- it creates session objects.

    Cheap and idempotent: it is called from the object panel's 500 ms poll, so it must
    stay a few dict lookups when there is nothing to do. Never raises; a failure here
    would break the poll that drives the whole panel.
    """
    settled = 0
    for job in list(_JOBS.values()):
        if not isinstance(job, _DeferredDesignJob) or job._reaped:
            continue
        try:
            if job.advance(_self=_self):
                settled += 1
        except Exception as exc:
            colorprinting.warning(' design: could not start job %s (%s)'
                                  % (job.job_id, exc))
    return settled


# -- Placeholders and progress -------------------------------------------------


def register_pending(name, job_id, _self=cmd):
    """Create the empty placeholder (if new) and remember what it is waiting for.

    The placeholder is a real, zero-atom object, so the design appears in the object
    panel the moment the command returns rather than seventeen minutes later, and
    loading into it lands at state 1.
    """
    name = _legal_object_name(name, _self=_self)
    if name not in _self.get_names('objects'):
        _self.create(name, 'none')
    _PENDING.setdefault(name, []).append(job_id)
    import time
    track = _TRACK.setdefault(
        name, {'total': 0, 'done': 0, 'started': time.monotonic(), 'floor': 0.0})
    track['total'] += 1


def discard_pending(name, _self=cmd):
    """Forget a placeholder, deleting the object only if it never received a design.

    The atom check is the important part: cleanup can race a job that just finished, and
    deleting a completed design would destroy the very thing that took seventeen minutes.

    A live run makes "no atoms" the wrong question, so it is not the only one asked. Live
    view builds the design's own object as it goes, so a run that is cancelled or fails
    leaves an object full of atoms that are NOT a design -- a half-diffused poly-ALA
    backbone under a name that says `rfd3_design_<key>`, indistinguishable from a finished
    one in the object panel and in any .pse saved afterwards. `_TRAJECTORY` says every
    atom in there came from the recording, and while it does, the object counts as empty
    for this purpose and goes with the placeholder. The name means the finished design or
    nothing.
    """
    name = _legal_object_name(name, _self=_self)
    recording = _TRAJECTORY.pop(name, None)
    fresh = None
    try:
        fresh = pending_info(name, _self=_self)
    except Exception:
        pass
    last = fresh or _LAST_INFO.get(name)
    _LAST_INFO.pop(name, None)
    if last is not None and last.get('state') in ('error', 'failed', 'cancelled'):
        while len(_RECENT) >= MAX_RECENT:
            _RECENT.pop(next(iter(_RECENT)))
        _RECENT[name] = last
    _PENDING.pop(name, None)
    _TRACK.pop(name, None)
    try:
        if name in _self.get_names('objects') and (
                recording is not None or _self.count_atoms(name) == 0):
            _self.delete(name)
    except Exception:
        pass


def clear_pending(_self=cmd):
    """Drop every placeholder, and anything that would create another."""
    for job_id, job in list(_JOBS.items()):
        if isinstance(job, _DeferredDesignJob):
            _JOBS.pop(job_id, None)
    for name in list(_PENDING):
        discard_pending(name, _self=_self)
    # After the loop: discard_pending removes its own entry, and this catches a recording
    # whose name has already left _PENDING.
    for name in list(_TRAJECTORY):
        discard_pending(name, _self=_self)
    _TRACK.clear()
    _RECENT.clear()
    _LAST_INFO.clear()


def pending_info(name, _self=cmd):
    """Structured progress for a placeholder, or None if it is not pending.

    Same keys as `predicting.pending_info`, and that is a contract rather than a
    coincidence: the object panel's payload and the progress tray decode one shape, so a
    design row and a prediction row have to be the same record.

    Never raises. The whole body is inside one try, because the caller writes no panel
    file at all if this throws, which freezes the object panel on a stale list.
    """
    import time
    try:
        name = _legal_object_name(name, _self=_self)
    except Exception:
        # Guarded because of the "never raises" contract above, and only here: a lookup
        # under the name as given misses and returns None, which the panel renders as
        # "pending" -- where letting this out would write no panel file at all.
        pass
    job_ids_for_name = _PENDING.get(name)
    if not job_ids_for_name:
        return _RECENT.get(name)
    track = _TRACK.setdefault(name, {'total': len(job_ids_for_name), 'done': 0,
                                     'started': time.monotonic(), 'floor': 0.0})
    info = {'state': 'running', 'phase': 'pending', 'fraction': None,
            'moving': False, 'models_done': 0, 'models_total': 1,
            'elapsed': 0.0, 'error': None, 'detail': 'pending', 'bundle': None,
            'step': None, 'total_steps': None, 'remaining': None}
    try:
        info['models_done'] = track['done']
        info['models_total'] = max(track['total'], 1)
        info['elapsed'] = max(time.monotonic() - track['started'], 0.0)
        job = _JOBS.get(job_ids_for_name[0])
        if job is not None:
            bundle = getattr(job, '_bundle', None)
            if bundle is not None and getattr(job, '_real', None) is None:
                info['bundle'] = getattr(bundle, 'id', None)
            status = job.status()
            # Coerced, not trusted: every value here crosses json.dumps into a
            # strongly-typed Swift decoder that does no coercion of its own, and one
            # wrong type fails the WHOLE panel payload and takes the object list down.
            info['state'] = str(status.get('state') or 'running')
            info['phase'] = str(status.get('phase') or 'pending')
            error = status.get('error')
            info['error'] = None if error is None else str(error)
            info['step'] = _as_int(status.get('step'))
            info['total_steps'] = _as_int(status.get('total_steps'))
            local = _as_float(status.get('fraction'))
            if (track.get('phase') != info['phase']
                    or local is None
                    or local < track.get('phase_fraction', 0.0)):
                track['phase'] = info['phase']
                track['phase_started'] = time.monotonic()
            track['phase_fraction'] = 0.0 if local is None else local
            phase_elapsed = max(
                time.monotonic() - track.get('phase_started', time.monotonic()), 0.0)
            if info['state'] == 'running':
                info['remaining'] = _phase_remaining(local, phase_elapsed)
            fraction, moving = _job_progress(job, status)
            if fraction is not None:
                whole = (track['done'] + fraction) / info['models_total']
                whole = max(whole, track.get('floor', 0.0))
                track['floor'] = whole
                info['fraction'] = whole
                info['moving'] = bool(moving)
            elif track.get('floor'):
                info['fraction'] = track['floor']
        info['detail'] = _format_detail(info)
    except Exception:
        pass
    _LAST_INFO[name] = info
    return info


def _job_progress(job, status):
    """(fraction, moving) from the job's own generator, or (None, False).

    Resolved through the GENERATOR registry, which is the whole reason this is not
    `predicting._job_progress`: that one asks the predictor registry, where a generator
    id is correctly absent, and would silently drop every fraction.
    """
    try:
        import math
        generator_id = getattr(job, 'generator_id', '') or ''
        if generator_id:
            generator = registry.get(generator_id)
        else:
            generator = getattr(job, '_generator', None)
        if generator is None:
            return None, False
        fraction, moving = generator.progress(status)
        if fraction is not None:
            if (not isinstance(fraction, (int, float))
                    or isinstance(fraction, bool)
                    or not math.isfinite(float(fraction))):
                return None, False
        return fraction, bool(moving)
    except Exception:
        return None, False


def pending_detail(name, _self=cmd):
    """One-line description of the job a placeholder is waiting on, or None."""
    info = pending_info(name, _self=_self)
    return None if info is None else info['detail']


def session_save(session, _self=cmd):
    """Session-save task: keep unfinished designs out of the .pse.

    A placeholder is a real zero-atom object and DOES survive a session round-trip, so a
    session saved mid-design would carry an object that can never fill. Only objects that
    are BOTH pending and unfinished are dropped.

    Unfinished means one of two things, not one. An empty placeholder is the ordinary
    case. A LIVE design is the other: its object has atoms from the first captured frame
    onwards, but they are a half-diffused poly-ALA backbone rather than a design, and it
    is sitting under the design's own name -- reopened tomorrow, nothing would say that
    the thing called `rfd3_design_<key>` is a rollout frozen at step 84. `_TRAJECTORY`
    holds the name for exactly as long as that is true.
    """
    names = session.get('names')
    if not names or not (_PENDING or _TRAJECTORY):
        return 1
    keep = []
    for entry in names:
        if entry and (entry[0] in _PENDING or entry[0] in _TRAJECTORY):
            try:
                if entry[0] in _TRAJECTORY or _self.count_atoms(entry[0]) == 0:
                    continue
            except Exception:
                continue
        keep.append(entry)
    session['names'] = keep
    return 1


# -- Delivery: the finished design, and what it measured ----------------------


def record_run(name, job_id, state, _self=cmd):
    """Record what this design measured, against the object it landed in (#308).

    Returns the MetricRun, or None when there is nothing to attach. Never raises into the
    delivery path: a design that took seventeen minutes must not fail to appear because
    its metrics could not be filed.

    Two halves, from two places, and neither could supply the other's:

    * The GEOMETRY is measured inside the runtime, because that is the only process the
      coordinates exist in while it runs. It arrives as a metric document at
      `job.metrics_path` -- the same channel `BoltzJobManager.writeMetrics` uses.
    * The IDENTITY and the input facts are known only here: which selection was the
      target, how many hotspots, the design key. The runtime is told the key so it can
      stamp it, but the length, the target size and the source selection are this side's.
    """
    from pymol.metrics import binding
    job = _JOBS.get(job_id)
    if job is None:
        return None
    generator_id = getattr(job, 'generator_id', '') or ''
    if not generator_id:
        return None
    try:
        status = job.status()
    except Exception:
        status = {}

    values = _run_values(job, status, state, generator_id)
    try:
        values.extend(_document_values(job, generator_id, state, name))
    except Exception as exc:
        # The runtime's numbers are the valuable half, so a malformed document is worth a
        # warning -- but the run is still recorded with what this side knows.
        colorprinting.warning(
            ' design: could not read the metrics %s wrote for job %s (%s)'
            % (generator_id, job_id, exc))
    if not values:
        return None
    return binding.record(name, generator_id, values,
                          tool_version=_weight_version(generator_id),
                          inputs=_run_inputs(job), _self=_self)


def _run_values(job, status, state, generator_id):
    """The metrics THIS side knows, without asking the runtime for anything.

    Deliberately independent of the metrics document: a runtime that never writes one
    still leaves a run carrying what the design was and what it cost.
    """
    from pymol.metrics import store as metric_store
    from pymol.metrics.errors import MetricSchemaError
    spec = getattr(job, 'spec', None)
    options = getattr(job, 'options', None)
    values = []

    def _add(key, **kwargs):
        # A generator declares the subset it can produce, so a key it never declared is
        # simply not written -- the capability contract working, not a failure. ONLY that:
        # a scope or type error is a bug here and must not be swallowed into a silently
        # incomplete run.
        try:
            values.append(metric_store.value(generator_id, key, **kwargs))
        except MetricSchemaError:
            pass

    if spec is not None:
        _add('n_residues', value=spec.total_residues)
        # Two: the target and the designed chain. The pair IS the object, which is the
        # whole point of emitting them together.
        _add('n_chains', value=2)
        _add('design_length', value=spec.length)
        _add('design_target_residues', value=spec.target.n_residues)
        _add('design_hotspots', value=len(spec.target.hotspots))
        _add('design_chain', value=spec.design_chain)
        if options is not None:
            _add('design_key',
                 value=spec.design_key(options,
                                       weights_version=_weight_version(generator_id)))
    for key in ('elapsed_s', 'peak_bytes'):
        # Absent stays absent: a runtime that reported no timing gets no `elapsed_s`,
        # rather than a zero that reads as an instantaneous design.
        if status.get(key) is not None:
            _add(key, value=status[key], state=state)
    return values


def _run_inputs(job):
    """The provenance half of a run: what this design was ASKED to do.

    Inputs, not metrics -- they are not measurements. But a metric without them is not
    evidence of anything: the same target at a different seed, or against a different
    weight pack, is a different design with the same schema.
    """
    spec = getattr(job, 'spec', None)
    options = getattr(job, 'options', None)
    inputs = {'generator': getattr(job, 'generator_id', '') or ''}
    if options is not None:
        inputs['options'] = options.as_dict()
        inputs['seed'] = options.seed
    if spec is not None:
        inputs['target'] = spec.target.source
        inputs['target_state'] = spec.target.state
        inputs['target_residues'] = spec.target.n_residues
        inputs['design_length'] = spec.length
        inputs['design_chain'] = spec.design_chain
        inputs['hotspots'] = ['%s/%s' % (entry['chain'], entry['resi'])
                              for entry in spec.hotspot_ids()]
    return inputs


def _document_values(job, generator_id, state, object_name):
    """What the RUNTIME measured: the geometry, which exists only inside it."""
    import json
    import os
    from pymol.metrics import document

    handle = getattr(job, '_real', None) or job
    path = getattr(handle, 'metrics_path', '')
    if not path or not os.path.exists(path):
        return []
    with open(path) as stream:
        payload = json.load(stream)
    # The document's own `tool` is overridden with the generator that ran. The runtime
    # knows its RUNTIME name, not which generator selected it -- the same reason
    # `predicting` overrides it for a prediction.
    payload['tool'] = generator_id
    # A document may name its own state, but the state a design actually landed in is
    # known only here, so it is stamped on the way in over anything the file claims.
    for entry in payload.get('values') or []:
        if 'state' in entry or entry.get('index') is not None:
            entry['state'] = state
    # The object is named here too rather than trusted from the file: the runtime wrote it
    # at submit time, and a rename in between would leave the document naming an object
    # that no longer exists.
    parsed = document.parse(payload, object=object_name)
    return parsed['values']


def _weight_version(generator_id):
    """Which weights produced this run, as `bundle-id vN`, or '' for a method with none."""
    try:
        bundle = registry.get(generator_id).weight_bundle
    except Exception:
        return ''
    if bundle is None:
        return ''
    version = getattr(bundle, 'version', '')
    return ('%s %s' % (bundle.id, version)).strip()


# -- Building the design's object live ----------------------------------------
#
# A design takes minutes and shows nothing until it ends. With `live_view=1` the runtime
# streams the rollout here, one state per captured frame, into THE DESIGN'S OWN OBJECT --
# the same name, the same contents and the same writer as a run without it. There is no
# second object: the finished design arrives as one more state of the one the user has
# been watching, and the object is left showing it.
#
# The object holds the target as well as the generated chain, which is what makes that
# possible: it is what `RFD3ResultWriter.compose` emits for the result, atom for atom, so
# the result's coordinates can simply be appended. Only two things differ while the run is
# going -- the generated chain's coordinates are a rollout frame rather than the answer,
# and its residues are named ALA because the sequence is not settled yet. Delivery fixes
# both.
#
# Each frame carries the generated chain ONLY. Resending the target's coordinates fifty
# times would be pointless traffic, so the target's half of every state is copied from
# the seed and the frame is spliced onto it here. That needs to know where the generated
# chain starts and how long it is, which is why `trajectory_seed` takes both and records
# them rather than anything assuming the generated chain is simply "the last atoms".


def rollout_step_count(diffusion_steps):
    """Steps the rollout actually takes for a `diffusion_steps` schedule.

    The schedule has `diffusion_steps` sigma levels and one fewer TRANSITION between
    them, and it is the transitions that are captured. Floored at 1 so the arithmetic
    below it never divides by zero; `DesignOptions` already refuses anything under 2.

    ** THIS IS A CROSS-LANGUAGE COUPLING, and it is the only one this feature has. **
    `RFD3JobManager.run` computes the same quantity as
    `max(request.diffusionSteps - 1, 1)` for `shouldCapture`'s final-step arm. If the two
    ever disagreed, the count echoed at submit time would be a lie about the object the
    user then gets -- so `testTheRolloutLengthMatchesTheRuntimes` greps the Swift source
    for that expression and fails if it changes. Both ends carry a pointer to the other.
    """
    return max(int(diffusion_steps) - 1, 1)


def capture_frame_count(interval, total):
    """How many frames a live run captures at `interval` over `total` rollout steps.

    The multiples of `interval` in `1..total`, plus the final step when it is not already
    one of them -- which is the `step == total` arm of `RFD3Trajectory.shouldCapture`,
    counted rather than re-derived. Swift owns the capture RULE; this side owns the
    arithmetic about it, and these two must agree or every derived interval is off.
    """
    interval, total = int(interval), int(total)
    if interval <= 0 or total <= 0:
        return 0
    multiples = total // interval
    return multiples if total % interval == 0 else multiples + 1


def capture_interval(frames, total):
    """THE derivation: the capture interval that lands closest to `frames` captures.

    `live_steps` is a number of STATES, not an interval -- a user reasons about how many
    states end up in their object (scrub granularity, memory, how long the movie is), not
    about every-Nth-step. This is the single place that turns one into the other, on the
    side that also knows `diffusion_steps`, so the number can be REPORTED at submit time
    without a second copy of this arithmetic existing anywhere. Swift does no arithmetic:
    it is handed the interval and captures every Kth step.

    Switching the parameter to interval semantics later means returning `frames` unchanged
    from here and deleting the rest.

    The achievable counts are QUANTISED, because the interval is a whole number of steps:
    over 199 rollout steps they run 199, 100, 67, 50, 40, 34, ... So an exact answer is
    often impossible and this returns the NEAREST achievable count rather than the nearest
    under it. "At most `frames`" was the other candidate and it is much worse in the gaps
    -- asked for 99 of 199 it would give 67, where nearest gives 100.

    Ties keep the SMALLER interval, i.e. the finer recording: someone who asked for more
    states is better served by one extra than by one fewer.

    Scanning rather than dividing, because `round(total / frames)` is not always right:
    7 frames over 199 steps rounds to interval 28, which yields 8, while 29 yields exactly
    7. Bounded by `total`, once per command.
    """
    total = int(total)
    if total <= 0:
        return 1
    wanted = max(int(frames), 1)
    best, best_distance = 1, None
    for interval in range(1, total + 1):
        distance = abs(capture_frame_count(interval, total) - wanted)
        # `<`, not `<=`, so a tie keeps the smaller interval already found.
        if best_distance is None or distance < best_distance:
            best, best_distance = interval, distance
        if distance == 0:
            break
    return best


#: The gap a record starts with, before any two captured frames have been timed.
#:
#: A placeholder rather than a pace: nothing animates until a second frame lands, and
#: that landing measures the real gap and overwrites this. It only survives if the
#: measured gap comes back non-positive, which a monotonic clock does not do.
#:
#: There is deliberately no display-rate constant here. The rate is
#: `RFD3Trajectory.playbackTicksPerSecond`, on the side that owns the timer, and this
#: module never needs it: `display_fraction` is a function of elapsed TIME, so it gives
#: the right answer at any tick rate and at irregular ticks.
NOMINAL_FRAME_INTERVAL = 1.0


def display_fraction(elapsed, gap):
    """How far between the previous captured frame and the newest one to show, 0...1.

    Time-based rather than tick-counted, so a tick that arrives late lands where it
    should rather than where it would have been if every tick had been on time.

    Saturates at 1 rather than overshooting: if the next frame is slow the display sits
    on the newest captured frame and waits. It never extrapolates past a coordinate the
    model actually produced.
    """
    try:
        elapsed, gap = float(elapsed), float(gap)
    except (TypeError, ValueError):
        return 1.0
    if not gap > 0:
        return 1.0
    if elapsed <= 0:
        return 0.0
    return min(1.0, elapsed / gap)


def interpolate_frame(start, end, fraction):
    """One coordinate set `fraction` of the way from `start` to `end`.

    Straight-line, per atom, per axis. THE ENDPOINTS ARE EXACT and are returned by copy
    rather than computed: `a + (b - a) * t` is not bit-for-bit `a` at t=0 or `b` at t=1 in
    floating point, and the whole design of this feature is that the model's own
    coordinates are never approximated.

    Returns `[]` when the two frames do not describe the same atoms, so a mismatch
    degrades to "no smoothing" rather than to a mis-shaped state.
    """
    if not start or len(start) != len(end):
        return []
    if fraction <= 0:
        return [list(point) for point in start]
    if fraction >= 1:
        return [list(point) for point in end]
    return [[a[axis] + (b[axis] - a[axis]) * fraction for axis in range(3)]
            for a, b in zip(start, end)]


def _pdb_atom_records(text):
    """`(resn, chain, resi, [x, y, z])` per ATOM record of `text`, in FILE order.

    The PDB is fixed-column, so this is a slice rather than a parse. It exists because
    both places that need coordinates need them in the FILE's order -- which is what
    `load_coordset` is documented to load in ("the original atom order (order from PDB
    file)"), as opposed to the property-sorted order `iterate` and `load_coords` use.

    Reading them back out of the session instead is not an option, and that is a
    measurement rather than a preference: `cmd.get_coordset` is numpy-backed and returns
    **None** in the shipped macOS app. It returns a real array under the headless PyMOL
    the test suite runs on, so the difference is invisible to every test.

    Malformed lines are skipped rather than raising; the callers check the count they
    ended up with, which is the only thing that makes the result usable.
    """
    records = []
    for line in text.splitlines():
        if not (line.startswith('ATOM') or line.startswith('HETATM')):
            continue
        if len(line) < 54:
            continue
        try:
            xyz = [float(line[30:38]), float(line[38:46]), float(line[46:54])]
        except ValueError:
            continue
        records.append((line[17:20].strip(), line[21:22].strip(),
                        line[22:27].strip(), xyz))
    return records


def _hide_target_copy(name, _self=cmd):
    """Hide the copy of the target the design object carries, showing only the design.

    The object is the target plus the generated chain, and the user already has their own
    target loaded -- so the target half draws duplicate geometry directly on top of their
    structure. The atoms STAY: they are what makes the pair a refold's input, they are in
    the result file and in the metrics, and hiding is a display flag, not a deletion.

    Applied to EVERY design object, live or not. The reason for hiding -- "this chain
    duplicates a target you already have" -- is just as true without the live view, and
    doing it live-only would make a live object look different from a plain one, which is
    the difference `keep_frames=0` exists to avoid.

    ONCE, where the object is created, and never again: if the user shows the target chain
    themselves mid-run, nothing here puts it back.

    The generated chain is identified as the chain of the LAST atom, because
    `RFD3ResultWriter.emit` writes the target first and the generated chain second. That
    also means this needs no parameters and works the same on the seeded object and on a
    plainly loaded result.
    """
    try:
        atoms = []
        _self.iterate(name, 'L.append((rank, chain))', space={'L': atoms})
        if not atoms:
            return False
        design_chain = max(atoms)[1]
        if not design_chain:
            return False
        _self.hide('everything', '%s and not chain %s' % (name, design_chain))
        return True
    except Exception:
        # Cosmetic; a design must never fail because a chain could not be hidden.
        return False


def _holds_our_writes(name, record, _self=cmd):
    """Whether `name` still holds the coordinates this recording last put in it.

    The identity check. Its job is to catch "same NAME, different object" -- yesterday's
    .pse of this design reopened under the name mid-run matches on atom count exactly, so
    counting cannot tell them apart, and every writer here would then be editing somebody
    else's structure.

    It compares the ANCHOR state -- the one this recording writes to, which is the display
    slot once there is one and state 1 before that -- against `record['written']`, the
    coordinates last put there. It used to compare state 1 against the SEED, which worked
    only while state 1 was never rewritten. With `keep_frames=0` the object has a single
    state that IS the animated display, so the anchor has to follow the writes instead.

    Rank-scoped, so it reads the generated chain and nothing else; `rank` is the file
    order the layout was reported in, where `index` is PyMOL's sorted order. Measured on
    the real 450-atom design: 0.132 ms.
    """
    try:
        offset = len(record['target'])
        expected = record.get('written') or record['design']
        anchor = record.get('display_state') or 1
        held = []
        _self.iterate_state(anchor, '%s and rank %d-%d'
                            % (name, offset, offset + record['atoms'] - 1),
                            'L.append((rank, x, y, z))', space={'L': held})
        if len(held) != len(expected):
            return False
        for entry, written in zip(sorted(held), expected):
            # 0.01 A: the seed round-trips through the PDB's three decimals and float32
            # storage, so this is "the same coordinates", not "close enough".
            if max(abs(a - b) for a, b in zip(entry[1:], written)) > 0.01:
                return False
        return True
    except Exception:
        return False


def _refuse_seed(name, reason, _self=cmd):
    """Abandon a seed: say why, leave no object, record nothing. Always False.

    Audible on purpose. Each of these branches used to `return False` in silence, and the
    user's experience of one was a design whose row VANISHED from the object panel -- the
    placeholder is deleted here along with the half-seeded object -- for the seventeen
    minutes until the result loaded. Nothing anywhere said the live view had been refused.
    """
    try:
        _TRAJECTORY.pop(name, None)
        if name in _self.get_names('objects'):
            _self.delete(name)
        # Put the placeholder back. `register_pending` made a zero-atom object so the
        # design has a row in the object panel from the moment the command returns, and
        # the seed replaced it; abandoning the seed must not cost the user that row for
        # the rest of a seventeen-minute run.
        if name in _PENDING and name not in _self.get_names('objects'):
            _self.create(name, 'none')
    except Exception:
        pass
    colorprinting.warning(' design: no live view for %s -- %s. The design itself is'
                          ' unaffected and will load when it finishes.' % (name, reason))
    return False


def trajectory_seed(name, pdb, design_offset, design_atoms, keep=1, _self=cmd):
    """Create the design's object from the FIRST captured frame. Called once.

    `pdb` is the whole object -- target chain plus a poly-ALA generated chain -- as
    `RFD3Trajectory.seed` composed it. `design_offset` is how many atoms precede the
    generated chain in it and `design_atoms` how many are in it; both are reported by the
    writer that emitted the string, not counted here, and they are recorded so
    `trajectory_frame` can splice into the right slice.

    The seed is state 1, not a placeholder before it: PyMOL infers connectivity ONCE, at
    read time, from the coordinates in this string, and `load_coordset` moves atoms without
    ever re-bonding them. A seed whose atoms all sat at the origin therefore refused every
    bond for the life of the object -- and into any .pse saved from it.

    Never raises: live view is a nicety, and a design that would have succeeded must not
    fail because a frame could not be drawn. A failure here simply leaves no recording, and
    the frames that follow find no record to splice into and are dropped for the same
    reason -- and delivery then loads the result plainly, exactly as a non-live run does.
    """
    try:
        name = _legal_object_name(name, _self=_self)
        offset = int(design_offset)
        atoms = int(design_atoms)
        if atoms <= 0 or offset < 0:
            colorprinting.warning(' design: no live view for %s -- the layout the writer'
                                  ' reported is not usable (%d + %d atoms)'
                                  % (name, offset, atoms))
            return False
        _TRAJECTORY.pop(name, None)
        if name in _self.get_names('objects') and _self.count_atoms(name):
            # Delete only a PREVIOUS RECORDING. `read_pdbstr` into an object that already
            # has atoms appends states, so re-running a named design with Live on would
            # splice the last run's recording onto the front of this one.
            #
            # The zero-atom PLACEHOLDER is read into IN PLACE, which is what the plain
            # path does with `cmd.load` -- and it has to be, or a live object is
            # distinguishable from a plain one on three axes that had nothing to do with
            # the live view. Measured with a placeholder at submit and another object
            # opened before the seed, which is the realistic order:
            #
            #   plain          objlist [design, opened]  carbons [26]  auto_color_next 1
            #   delete+read    objlist [opened, design]  carbons [5]   auto_color_next 2
            #   read-in-place  objlist [design, opened]  carbons [26]  auto_color_next 1
            #
            # Deleting and recreating moved the design to the END of the object panel,
            # gave it a different colour, and burned an extra auto-colour slot so every
            # object opened afterwards was shifted one along. Reading in place matches the
            # plain path on all three with nothing to capture and restore.
            _self.delete(name)
        # `zoom=0` is LOAD-BEARING, not tidiness -- and it is why the comment that used to
        # sit here claiming "not zoomed" was false. Without it `read_pdbstr` inherits
        # zoom=-1 -> `auto_zoom`, which is on by default and which the app never overrides,
        # and the object is brand new every time because of the delete above, so auto-zoom
        # fires on EVERY live run. It reframes the camera on a chain that is still noise,
        # dragging the origin off the target and shrinking the clipping slab until the
        # target the user was looking at is outside it: measured, origin (122.58, 109.47,
        # 81.77) clip 108.14/166.19 -> origin (0, 0, 0) clip 11.18/17.18, target centre
        # depth 136.82 against a 11.18-17.18 slab. Nothing zooms back, so the user watches
        # a BLANK viewport for the rest of a multi-minute run. The run is minutes long and
        # the user is looking at the target; the object appearing in the panel is enough.
        # Same reason `deliver_result` loads with zoom=0.
        _self.read_pdbstr(str(pdb), name, zoom=0)
        if _self.count_atoms(name) != offset + atoms:
            # The string did not contain the object the writer said it did. No live view,
            # and no half-seeded object left under the design's name either.
            return _refuse_seed(name, 'the seed produced %d atoms, not the %d the writer'
                                ' reported' % (_self.count_atoms(name), offset + atoms),
                                _self=_self)
        # No covalent bonds between the target and the generated chain, ever.
        #
        # This is the one hazard the target and the design sharing an object introduces,
        # and it is permanent when it fires: PyMOL infers connectivity ONCE, from the
        # FIRST captured frame, and that frame is step 4 of 199. A generated chain is
        # MEANT to sit against the target, so an early, unsettled frame routinely puts
        # some of its atoms within bonding distance of target atoms -- measured on a real
        # 24-residue design against a 40-residue target, an early frame produced 34
        # inter-chain bonds where the finished structure has 0. They would then be drawn
        # as sticks joining the design to the target in every state including the
        # delivered one, and saved into any .pse.
        #
        # By RANK, from the layout the writer reported. `rank` is the atom's position in
        # the FILE; `index` is its position in PyMOL's SORTED order, and those are not the
        # same thing here. `AtomInfoCompare` orders by chain before residue number and
        # `retain_order` is 0, so for a target on any chain that sorts after the design's
        # -- which `_free_chain_id` makes every target letter except A and B -- the design
        # sorts FIRST and `index 1-<offset>` spans both chains. Measured on a target/design
        # pair of H/B: `rank 0-19` is {H}, `index 1-20` is {H, B}.
        #
        # Not by chain id either, but for a different reason than the comment that used to
        # sit here claimed: it said the target might share the design's letter, and it
        # cannot -- `_free_chain_id` picks a letter the target does not use, over a target
        # `require_single_chain` has already reduced to one chain. Rank is used because it
        # is the layout the writer reported and needs no lookup, not because chain is
        # ambiguous.
        #
        # Nothing legitimate is removed -- a generated backbone is a separate chain and
        # the result path produces no inter-chain bonds either (measured 0).
        if offset:
            _self.unbond('%s and rank 0-%d' % (name, offset - 1),
                         '%s and rank %d-%d' % (name, offset, offset + atoms - 1))
        # Once, here, where the object is created -- never per frame, so a user who shows
        # the target chain themselves is not fought.
        _hide_target_copy(name, _self=_self)
        # The target's half of every state, read out of the STRING rather than back out
        # of the session. It never changes -- the target is held fixed by contract for
        # the whole run -- and every frame is spliced onto it.
        #
        # Out of the string for two reasons. It is the order `load_coordset` wants, which
        # is documented as "the original atom order (order from PDB file)" and not
        # PyMOL's sorted order; and `cmd.get_coordset` returns **None** in the shipped
        # app, which has no numpy-backed path in its `_cmd`. That returned None silently:
        # the seed threw, left no record, and every frame of every live run was dropped,
        # with a headless test suite that has numpy passing throughout.
        written = _pdb_atom_records(str(pdb))
        if len(written) != offset + atoms:
            return _refuse_seed(name, 'the seed PDB carries %d atoms, not the %d the'
                                ' writer reported' % (len(written), offset + atoms),
                                _self=_self)
        # And PROVE the order rather than trusting it, once, here: every atom PyMOL holds
        # must be the atom the string wrote at that position. A reader that reordered the
        # atoms would put the target's coordinates on the generated chain for the whole
        # run, silently, and nothing downstream would notice.
        #
        # In RANK order, which is the file's. An earlier version of this compared against
        # `get_model`, whose order is the SORTED one, and so refused every design whose
        # target chain sorts after the generated chain's -- 24 of the 26 letters
        # `_free_chain_id` can hand out. It was a pure false negative: `load_coordset` is
        # rank-keyed (measured -- pushing the design's file-order slice 500 A moves chain
        # B and only chain B), so the splice this guards was correct all along.
        held = []
        _self.iterate_state(1, name, 'L.append((rank, x, y, z))', space={'L': held})
        if len(held) != len(written):
            return _refuse_seed(name, 'the object holds %d atoms, not the %d the seed'
                                ' PDB wrote' % (len(held), len(written)), _self=_self)
        for position, entry in enumerate(sorted(held)):
            if max(abs(a - b) for a, b in zip(entry[1:], written[position][3])) > 0.01:
                return _refuse_seed(
                    name, 'the object does not hold the seed PDB in the order it was'
                    ' written (atom %d differs)' % position, _self=_self)
        # The state the head last put on screen, and the baseline the "has the user taken
        # over?" check compares against. The seed IS state 1, and it is SET rather than
        # assumed: a fresh object reports the global default until something sets it, and
        # the check needs an unambiguous starting point.
        import time
        _self.set('state', 1, name)
        _TRAJECTORY[name] = {
            'offset': offset,
            'atoms': atoms,
            'head_state': 1,
            #: How many CAPTURED frames have landed, which is also the index of the last
            #: of them: states 1..captured are model output and nothing else ever is.
            'captured': 1,
            #: Whether captured frames are KEPT as states of the object.
            #:
            #: On, the object grows one state per model frame and you can scrub them
            #: afterwards. Off -- the default -- the frames are still captured and still
            #: animated, but nothing is appended: the object holds the single display
            #: state throughout and at delivery that slot becomes the design, so the
            #: finished object is indistinguishable from a `live_view=0` run.
            'keep': bool(int(keep)),
            #: The state the animation rewrites, and the one `_holds_our_writes` reads.
            #: With frames kept it is `captured + 1` and appears once there are two
            #: frames to interpolate between; without, it is state 1 from the start,
            #: because the object's only state IS the display.
            'display_state': None if int(keep) else 1,
            #: The two ends of the current animation, and the gap it plays over.
            'prev_design': None,
            'last_design': [record[3] for record in written[offset:]],
            'last_arrival': time.monotonic(),
            'gap': NOMINAL_FRAME_INTERVAL,
            'target': [record[3] for record in written[:offset]],
            # WHAT THE SEED PUT IN STATE 1, which is this recording's identity.
            #
            # Neither a frame NOR delivery may land on an object that merely shares the
            # name: open yesterday's .pse of this same design mid-run and the atom count
            # matches exactly, so counting cannot tell them apart -- and the frames would
            # be appended to the user's saved design, whose residues delivery would then
            # rename as well. Checked in both places, `trajectory_frame` and
            # `_finish_trajectory`; the frame check alone left delivery free to do it.
            #
            # State 1's generated chain discriminates it exactly, because that is the
            # one thing the two do NOT share: this recording's state 1 is the step-4
            # poly-ALA seed, and the saved design's is the finished structure.
            #
            # Stored rather than written anywhere. A previous version stamped a token
            # into state 1's TITLE, which was wrong twice over: `ObjectMoleculeLoadCoords`
            # builds each appended state by copying the first coordinate set, and
            # `CoordSet`'s copy carries `Name` -- so the token spread to every state as
            # the recording grew -- and `appkit_inspector` emits `titles` for any object
            # where a state has one, which the panel renders as a "Name" row. The user
            # read `raymol-live:<uuid>` in the inspector for the whole run, and it
            # survived into their .pse on states 2..N.
            'design': [record[3] for record in written[offset:]],
            #: The coordinates last written to the anchor state. Starts as the seed's,
            #: because that is what state 1 holds.
            'written': [record[3] for record in written[offset:]],
        }
        return True
    except Exception as exc:
        _TRAJECTORY.pop(name, None)
        colorprinting.warning(' design: could not start the live view (%s)' % exc)
        return False


def trajectory_frame(name, coords, advance=1, smooth=0, _self=cmd):
    """Append one captured frame as a new state of `name`, and show it.

    `coords` is a FLAT list of floats, three per atom, covering the GENERATED CHAIN ONLY,
    in the order the seed wrote it. The target's coordinates are spliced in front of it
    from the record `trajectory_seed` made, so the object grows a state whose target half
    is exactly the target half of state 1.

    `load_coordset` rather than `load_coords`: it is documented to load in the order the
    file had, and that order is the one `RFD3ResultWriter.emit` wrote.

    `advance` decides whether the new state is also SHOWN, and `smooth` whether an extra
    DISPLAY state is kept beside the captured frames for `trajectory_display` to animate.
    Both default to the behaviour every scripted and headless caller has always had:
    append a state and jump to it, nothing else in the object. The app passes
    `advance=0, smooth=1`.

    Note what `smooth` does NOT do: it does not add states between the captured frames.
    The object gains exactly one state per model frame either way. The single extra state
    is the live display, it is overwritten by the next captured frame, and at delivery it
    becomes the finished design -- so a smoothed run and a plain one end with the same
    states.

    When it does show the state, it does so through the OBJECT's `state` setting and never
    `cmd.frame`: `cmd.frame` writes the global MOVIE frame, and `CObject::getCurrentState`
    prefers the object's own setting and only falls back to the global -- so in a session
    that already has an `mset` the object would never move. Measured with `mset '1 x10'`:
    states grew 2, 3, 4, 5 while the displayed state stayed 1, 1, 1, 1.

    Never raises, for the reason `trajectory_seed` does not. A name with no record -- an
    object the user deleted mid-run, or a run whose seed failed -- is a no-op rather than
    an error.
    """
    try:
        name = _legal_object_name(name, _self=_self)
        record = _TRAJECTORY.get(name)
        if record is None or name not in _self.get_names('objects'):
            return False
        values = list(coords)
        if not values or len(values) % 3:
            return False
        atoms = len(values) // 3
        if atoms != record['atoms']:
            # A frame whose atom count is not the GENERATED CHAIN's cannot be a state of
            # it. The comparison is against the recorded length rather than against the
            # whole object, which now holds the target too: measured against
            # `count_atoms`, every frame of every live run would be short by the target
            # and none would ever land. Dropped rather than coerced: a partial frame
            # would silently misplace atoms.
            return False
        if len(record['target']) + record['atoms'] != _self.count_atoms(name):
            # The object is no longer the one the record describes -- atoms removed or
            # added under it. Refused rather than spliced into a shape that has changed.
            return False
        if not _holds_our_writes(name, record, _self=_self):
            # Same NAME, different object -- see `_TRAJECTORY['design']`.
            return False
        import time
        design = [values[i * 3:i * 3 + 3] for i in range(atoms)]
        now = time.monotonic()
        keep = record.get('keep', True)
        state = record['captured'] + 1
        if keep:
            # The captured frame goes at ITS OWN index, `captured + 1`. When a display
            # state exists it is sitting at exactly that index, so this overwrites it --
            # which is the point: nothing interpolated survives, the slot becomes model
            # output, and the object gains exactly one state per captured frame.
            _self.load_coordset(record['target'] + design, name, state)
        # Counted either way: the frame WAS captured, and `live_steps` means model frames
        # whether or not they are kept. Nothing is appended when they are not -- the
        # object holds the single display state and the animation runs exactly as it does
        # with them, from the two ends held in this record rather than from states.
        record['captured'] = state
        gap = now - record.get('last_arrival', now)
        if gap > 0:
            record['gap'] = gap
        record['prev_design'] = record.get('last_design')
        record['last_design'] = design
        record['last_arrival'] = now
        # SECONDARY STRUCTURE, per captured frame -- so the cartoon evolves with the
        # rollout instead of appearing only at the end.
        #
        # Scoped to the GENERATED CHAIN: the target's coordinates never move, so
        # re-deriving its `ss` every second is work for an answer that cannot change.
        # Measured on the real 450-atom design: 0.048 ms for `dss` plus 0.014 ms for the
        # cartoon rebuild it dirties -- 0.062 ms, 0.01% of one main thread at ~1 Hz.
        #
        # Per CAPTURED FRAME rather than per display tick: secondary structure is a
        # slowly varying property and ~1 Hz is what the eye needs. (Per tick would cost
        # 0.19% of one main thread, so the choice is about sense rather than budget.)
        #
        # ss is per-ATOM, so it belongs to the OBJECT and not to a state -- see the note
        # in `docs/generators.md`. Against the state holding the newest coordinates: the
        # captured frame itself when frames are kept, and the display otherwise, which is
        # the only state there is.
        try:
            ss_state = state if keep else record.get('display_state')
            if ss_state:
                _self.dss('%s and rank %d-%d'
                          % (name, len(record['target']),
                             len(record['target']) + record['atoms'] - 1),
                          state=ss_state)
        except Exception:
            # Cosmetic. A design must never fail because a cartoon could not be updated.
            pass
        if keep and int(smooth) and record['prev_design'] is not None:
            # A new display slot, appended after the captured frame and started at the
            # PREVIOUS frame -- the animation runs from there to the one that just
            # landed, over the interval that just elapsed. That is why the display lags
            # one frame: a gap can only be animated once both of its ends are known.
            # BEFORE `head_state` moves. A scrub that landed since the last tick is
            # only visible against the OLD value, and overwriting it first is what let a
            # frame arriving in the ~33 ms after a scrub undo it silently.
            took_over = _user_took_over(name, record, _self=_self)
            display = state + 1
            _self.load_coordset(record['target'] + record['prev_design'], name, display)
            record['display_state'] = display
            record['written'] = record['prev_design']
            if not took_over:
                # The slot still moves so the recording keeps its shape and delivery
                # overwrites the right state -- but a user who has taken the object is
                # left where they are, which is what they were told would happen.
                _self.set('state', display, name)
                record['head_state'] = display
        elif keep and int(advance):
            _self.set('state', state, name)
            record['head_state'] = state
        return True
    except Exception:
        return False


def _user_took_over(name, record, _self=cmd):
    """Whether something other than the live view has moved `name`. Latches if so.

    The live view is the only thing that sets this object's state, so the object showing
    anything other than what the view last set means the user moved it -- the object
    panel's state control, a typed `set state`, a scrubbed slider.

    ONE helper because there are two writers that must agree, and a version where only
    one of them checked shipped: `trajectory_display` latched and told the user the live
    view had stopped touching the object, and then every subsequent captured frame moved
    them anyway, about once a second for the rest of the rollout. Worse, a frame landing
    in the ~33 ms between the scrub and the next tick reset `head_state` first, so the
    comparison was against a value that had just been invented and the latch never fired
    at all.

    So this is called by BOTH, and in `trajectory_frame` it is called BEFORE `head_state`
    is overwritten. Once latched it stays latched: "stopped" has to mean stopped, not
    "stopped until the next frame".
    """
    if record.get('user_scrubbed'):
        return True
    try:
        shown = int(_self.get('state', name))
    except Exception:
        # Cannot tell; assume not, and leave the object alone rather than latching on a
        # transient failure.
        return False
    if shown == int(record.get('head_state', shown)):
        return False
    record['user_scrubbed'] = True
    colorprinting.parrot(
        ' design: you moved %s yourself, so the live view has stopped animating it.'
        ' The finished design will still be shown when it lands.' % name)
    return True


def trajectory_display(name, _self=cmd):
    """Move the atoms of the DISPLAY state to where they are right now. Called ~30/s.

    This is the smooth motion, and the shape of it is the point: the object gains exactly
    one state per captured model frame, and the animation happens by REWRITING the
    coordinates of one extra state rather than by manufacturing states between them. So
    nothing in the finished object was invented, there is nothing to label, and a session
    saved from it contains model output and the design.

    The display runs one frame behind, necessarily: a gap can only be animated once both
    of its ends have landed. `display_fraction` turns elapsed time into how far along the
    gap to be, so a late tick lands where it belongs rather than where it would have been
    had every tick been punctual, and it saturates at 1 rather than extrapolating past a
    coordinate the model produced.

    HOW THE USER TAKING OVER IS DETECTED: the object is showing the display state and
    nothing else moves it, so if it is showing something else, the user did -- the object
    panel's state control, a typed `set state`, a scrubbed slider. The head then gives way
    for the rest of the run. Checked here rather than in the runtime because the bridge is
    one-directional: the runtime cannot read the object's state, and here it is a
    `cmd.get` away.

    Never raises. Everything on this path degrades to "no smoothing".
    """
    try:
        import time
        name = _legal_object_name(name, _self=_self)
        record = _TRAJECTORY.get(name)
        if record is None or record.get('user_scrubbed'):
            return False
        display = record.get('display_state')
        if display is None:
            # No display slot yet: with frames kept there is none until two of them have
            # landed. (The "no predecessor yet" case needs no test of its own here --
            # `interpolate_frame` returns nothing without one, and the `if not middle`
            # below already turns that into "no animation".)
            return False
        if name not in _self.get_names('objects'):
            # Deleted mid-run, which is legitimate. Asking a gone object anything raises
            # AND prints a Selector-Error -- thirty times a second, for the rest of the
            # run -- so it is not asked.
            return False
        if _user_took_over(name, record, _self=_self):
            return False
        fraction = display_fraction(time.monotonic() - record['last_arrival'],
                                    record.get('gap'))
        if record.get('fraction') == fraction:
            # Already there -- the gap has run out and the next frame has not landed.
            # AHEAD of the identity check on purpose: this tick writes nothing, and the
            # check exists to guard a write. Skipping it here is what keeps an idle tick
            # cheap; putting it first made the "early out" cost more than the work.
            return False
        if not _holds_our_writes(name, record, _self=_self):
            # SAME NAME, DIFFERENT OBJECT -- see `_TRAJECTORY['design']`. This writer has
            # to make the check for the same reason the other two do, and more so: it is
            # the one that writes COORDINATES, thirty times a second, so an unverified
            # object here is the user's reopened design being silently overwritten rather
            # than merely being shown a different state.
            #
            # The scrub check above catches most impostors incidentally -- a swapped-in
            # object is rarely showing exactly the state the head last set -- but
            # "incidentally" is not the contract. Measured on the version without this:
            # an impostor pinned to the display state had its coordinates changed, with
            # no latch and no warning.
            #
            # Measured on the real 450-atom design: 0.132 ms per call, most of a
            # 0.182 ms working tick -- 0.55% of one main thread at 30 Hz, 5.5 ms/s.
            # Immaterial, and it is the only thing between this loop and someone else's
            # coordinates, so it runs on every tick that WRITES. It sits after the
            # fraction early-out precisely so an idle tick pays none of it (0.004 ms).
            record['user_scrubbed'] = True
            colorprinting.warning(
                ' design: %s is no longer the object this run seeded, so the live view'
                ' has stopped animating it.' % name)
            return False
        middle = interpolate_frame(record['prev_design'], record['last_design'], fraction)
        if not middle:
            return False
        _self.load_coordset(record['target'] + middle, name, display)
        record['fraction'] = fraction
        # The anchor now holds this, and the identity check compares against it.
        record['written'] = middle
        return True
    except Exception:
        return False


def _finish_trajectory(path, name, record, _self=cmd):
    """Turn a live recording into the finished design. True if it did.

    Two steps, and the ORDER of them is the whole function.

    1. Rename the generated chain's residues to the sequence the design actually produced.
       Residue names in PyMOL are per-OBJECT, not per-state, so this is not a property of
       the last state -- every state of the recording ends up showing the designed
       sequence. That is fine, and better than leaving poly-ALA behind: the alternative is
       an object whose residues are named after a placeholder identity the design does not
       have.
    2. THEN append the result's coordinates as one more state.

    Not `cmd.load(path, name)`, which does not merge: mismatched residue names make PyMOL
    treat the incoming atoms as new ones, and the object goes from 450 atoms to 530.
    Renaming first and appending with `load_coordset` keeps it at 450 atoms, its bonds
    unchanged, and the last state 0.000000 A from the result.

    The result is read as TEXT rather than loaded into a scratch object. `load_coordset`
    wants the file's own atom order and the file is the only place that has it -- reading
    it back out of a loaded object would mean `cmd.get_coordset`, which returns None in
    the shipped app. The rename is scoped to the generated chain by INDEX, from the layout
    the seed recorded, and keyed within it by residue number, so nothing has to agree
    about which chain id the generated chain got or whether the target reuses it.

    Returns False rather than raising if the two do not line up, and the caller then loads
    the result plainly.
    """
    try:
        with open(path) as handle:
            written = _pdb_atom_records(handle.read())
        offset = len(record['target'])
        expected = offset + record['atoms']
        if len(written) != expected:
            colorprinting.warning(
                ' design: the live view for %s could not be completed -- the result has'
                ' %d atoms and the recording has %d, so it is being loaded as a fresh'
                ' object instead.' % (name, len(written), expected))
            return False
        if _self.count_atoms(name) != expected:
            colorprinting.warning(
                ' design: the live view for %s could not be completed -- the object now'
                ' holds %d atoms and the recording has %d, so the result is being loaded'
                ' as a fresh object instead.'
                % (name, _self.count_atoms(name), expected))
            return False
        if not _holds_our_writes(name, record, _self=_self):
            # The same check every frame makes, applied once more here. Counting alone
            # cannot see this: an impostor -- yesterday's .pse of this design, reopened
            # under the name mid-run -- matches on atoms exactly, and delivery would then
            # append a state to the user's saved object and RENAME its residues, which is
            # a silent rewrite of something this run does not own. Refusing sends the
            # caller down the plain path, which replaces the object with the design the
            # name promises.
            colorprinting.warning(
                ' design: the live view for %s could not be completed -- the object under'
                ' that name is no longer the one this run seeded, so the result is being'
                ' loaded as a fresh object instead.' % name)
            return False
        sequence = {}
        for resn, _chain, resi, _xyz in written[offset:]:
            sequence[resi] = resn
        # By RANK, which is the file order the layout was reported in; `index` is PyMOL's
        # sorted order and spans both chains whenever the target's chain sorts after the
        # generated chain's. Keyed by residue number WITHIN that range, so the rename
        # cannot depend on atom order at all.
        _self.alter('%s and rank %d-%d' % (name, offset, expected - 1),
                    'resn = _seq.get(resi, resn)', space={'_seq': sequence})
        # The design goes into the DISPLAY slot when smoothing made one -- overwriting
        # the last interpolated position rather than appending after it -- so the finished
        # object is the captured frames plus the design, exactly the state count a run
        # without smoothing produces.
        display = record.get('display_state')
        _self.load_coordset([entry[3] for entry in written], name,
                            display if display else _self.count_states(name) + 1)
        # RE-DERIVE the bonds from the settled final state, so a delivered design's
        # CHEMISTRY does not depend on whether Live was ticked.
        #
        # The seed states connectivity with CONECT records, and a plain CONECT is order
        # ONE. The result file carries no CONECT at all, so a plain run INFERS the
        # generated chain's carbonyls as double bonds. Nothing here used to re-derive
        # them, so the same design came out with C=O order 2 without live view and order
        # 1 with it -- measured on an 8-residue design, 8 double bonds on the generated
        # chain against 0. That is visible, not bookkeeping: `valence` is on by default
        # and the wire and cylinder renderers branch on bond order, and it persisted into
        # any saved session.
        #
        # `rebond` on the FINAL state rather than a scoped valence fix: the final state is
        # the delivered design, which is exactly what a plain run bonds from, so this
        # makes the two identical by construction instead of by patching up the one
        # difference anyone has noticed so far. It also re-derives inter-chain bonds from
        # the settled geometry -- which is what a plain load would do too.
        #
        # Read from the final state, but WRITTEN to the object: PyMOL's bond table is per
        # OBJECT, not per state, so this replaces the connectivity of every state at once
        # -- measured 88 -> 92 on state 2 of a live object across delivery. So the unbond
        # at seed time protects the RECORDING only UNTIL delivery; afterwards the rollout
        # states carry the finished structure's bonds, inter-chain ones included. That is
        # the same thing a plain run draws, and the object is pinned to the final state,
        # so it surfaces only if someone unpins and scrubs back. Stated because the
        # alternative reading -- that the early states keep their own connectivity -- is
        # the natural one and the data model does not offer it.
        _self.rebond(name, state=_self.count_states(name))
        states = _self.count_states(name)
        colorprinting.parrot(
            ' design: %s was built live -- %s' % (
                name,
                'the finished design, with the rollout\'s frames discarded'
                ' (keep_frames=1 keeps them).' if states <= 1
                else '%d states, the last one the finished design.' % states))
        return True
    except Exception as exc:
        colorprinting.warning(' design: could not complete the live view for %s (%s)'
                              % (name, exc))
        return False


def deliver_result(path, name, seed=None, _self=cmd):
    """Load a finished design into its placeholder and retire the pending mark.

    Called BY THE RUNTIME, which is why it is one entry point rather than a load plus a
    bookkeeping call: a name left pending after a successful load would be stripped from
    every subsequent session save.

    `zoom=0` on purpose. A design can land seventeen minutes after submit, and pulling the
    camera onto it while the user is working elsewhere is hostile. The placeholder has
    been visible in the object panel since the command returned.

    A LIVE run lands differently and in one object, not two. Its object already exists and
    already holds this design's target and generated chain, so the result is appended to
    it as one more state instead of being loaded over it -- `cmd.load` into an existing
    object does not merge, it adds atoms. If that cannot be done for any reason the
    recording is thrown away and the result is loaded exactly as a non-live run loads it,
    so the worst case is losing the recording rather than losing the design.

    A live object WITH ITS FRAMES KEPT is left PINNED to its final state through the
    object's own `state` setting, which is the only way to be sure it shows the design in
    a session that has a movie. To replay the rollout afterwards, move that setting -- the
    object panel's per-object state control, or `unset state, <name>` to hand the object
    back to the global frame.

    On the DEFAULT path there is nothing to pin and nothing to replay: the object has one
    state, so the pin is skipped and the seed's own is removed, leaving exactly what a
    `live_view=0` run leaves.
    """
    name = _legal_object_name(name, _self=_self)
    landing = (_PENDING.get(name) or [None])[0]
    # Popped before anything else can fail: from here on this object is a delivered design
    # rather than a recording, and `discard_pending` must never delete it.
    live = _TRAJECTORY.pop(name, None)
    try:
        if live is not None and not _finish_trajectory(path, name, live, _self=_self):
            # Half-finished is not an option: the recording is not the design, and
            # `cmd.load` on top of it would silently double atoms. Start clean.
            _self.delete(name)
            live = None
        if live is None:
            _self.load(path, name, zoom=0)
            # The same treatment a live object gets at seed time, for the same reason:
            # the target half duplicates a structure the user already has loaded. Applied
            # to both so a live run and a plain one leave the same object.
            _hide_target_copy(name, _self=_self)
        if seed is not None:
            # In the state title, so a design says which seed produced it -- and it
            # survives into a saved .pse, which is what makes a run reproducible after
            # the fact.
            try:
                _self.set_title(name, _self.count_states(name), 'seed=%d' % int(seed))
            except Exception:
                pass
        # Secondary structure explicitly: `auto_dss` does NOT fire when loading into a
        # PRE-EXISTING object, which is exactly what the placeholder makes this, and
        # without it cartoon renders every design as featureless loops. A generated
        # backbone carries no HELIX/SHEET records to fall back on either -- and unlike a
        # prediction, judging a design by eye IS looking at its secondary structure.
        #
        # A live object needs the state said. `dss`'s default is state 0, meaning ALL
        # states, and a live object's earlier states are unsettled rollout frames whose
        # geometry is not the design's -- assigning from them would let step 4 decide
        # what the finished backbone is called. Secondary structure is per-ATOM in PyMOL,
        # so there is one assignment to get right and the last state is the design.
        try:
            if live is not None:
                _self.dss(name, state=_self.count_states(name))
            else:
                _self.dss(name)
        except Exception as exc:
            colorprinting.warning(' design: could not assign secondary structure to %s'
                                  ' (%s)' % (name, exc))
        # `keep_frames=0` leaves a single state, which has nothing to pin -- and a plain
        # run leaves no per-object `state` setting behind, so neither may this, or the two
        # objects would be distinguishable by a leftover setting. The seed SET one (state
        # 1, so the "has the user taken over?" check had an unambiguous baseline), so it
        # is not enough to skip the pin here: the seed's has to be removed.
        if live is not None and _self.count_states(name) <= 1:
            try:
                _self.unset('state', name)
            except Exception:
                pass
        if live is not None and _self.count_states(name) > 1:
            try:
                # PINNED to the final state, via the OBJECT's own `state` setting rather
                # than `cmd.frame`. `cmd.frame` writes the global movie frame, which
                # `CObject::getCurrentState` only consults as a fallback -- in a session
                # that already has an `mset` it leaves the object showing state 1, i.e.
                # the step-4 poly-ALA seed wearing the DESIGNED residue names, which a
                # `cmd.save` at its default `state=-1` would then export as the design.
                #
                # The cost, and it is documented rather than hidden: the object stays on
                # that state. Replaying the rollout means moving that setting -- the
                # object panel's per-object state control does exactly this, or
                # `unset state, <name>` hands the object back to the global frame.
                _self.set('state', _self.count_states(name), name)
                # Said out loud, because it survives a .pse round trip: a user who later
                # drags the frame slider would otherwise find this one object frozen with
                # nothing anywhere explaining it.
                colorprinting.parrot(
                    ' design: %s is pinned to state %d (its finished design). Replay the'
                    ' rollout from the object panel\'s state control, or "unset state,'
                    ' %s" to follow the frame slider again.'
                    % (name, _self.count_states(name), name))
            except Exception:
                pass
        try:
            # `count_states` IS the state the design landed in, and it is the last one for
            # a live run as well as the only one for a plain one -- the metrics describe
            # the finished coordinates, which are the final state either way. Filed once,
            # from here, whether or not the object existed before this call: nothing in
            # the live path records anything.
            record_run(name, landing, _self.count_states(name), _self=_self)
        except Exception as exc:
            colorprinting.warning(' design: could not record metrics for %s (%s)'
                                  % (name, exc))
    finally:
        remaining = _PENDING.get(name)
        if remaining:
            remaining.pop(0)
            track = _TRACK.get(name)
            if track is not None:
                track['done'] += 1
            if not remaining:
                _PENDING.pop(name, None)
                _TRACK.pop(name, None)
                _LAST_INFO.pop(name, None)
                _RECENT.pop(name, None)


# -- The command surface -------------------------------------------------------


def design_backbone(generator, target, hotspots, length=60, name='', n_designs=1,
                    diffusion_steps=200, recycling_steps=2, seed=None, live_view=None,
                    live_steps=None, keep_frames=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_backbone" generates a new protein backbone against a target structure,
    with a registered backbone generator. It returns a job handle; poll it with
    "design_status".

    Each design lands in its own object holding the TARGET AND THE DESIGNED CHAIN
    together, with the target exactly where it already was. That pair is what a
    later refold takes as input, so nothing has to re-derive it.

    WHAT COMES BACK IS A BACKBONE, NOT A BINDER. Generation does not establish that
    the chain binds anything: the geometry metrics say whether it is sane and where
    it sits, and confirming it needs a refold of the pair and an interface gate,
    neither of which this command does.

USAGE

    design_backbone generator, target, hotspots [, length [, name [, n_designs
        [, diffusion_steps [, recycling_steps [, seed ]]]]]]

ARGUMENTS

    generator = str: id of a registered generator, e.g. rfd3

    target = str: atom selection for the structure to design against. One object,
    one chain. Only the standard twenty amino acids are read; anything else in the
    selection is excluded and, if it is inside the protein chain, reported.

    hotspots = str: atom selection for the interface residues to engage. A
    SELECTION, not a residue list -- so "resi 45+48+52", or "sele" after picking
    them in the viewer. Required: hotspots set the sampler origin, so without them
    the design is aimed at the whole target's centre of mass. Every residue named
    must be inside the target.

    length = int: residues in the generated chain {default: 60}

    name = str: object name for the result {default: <generator>_design_<key>}. With
    n_designs > 1 an index is appended.

    n_designs = int: how many independent designs to generate. Each is a FULL run --
    see NOTES. {default: 1}

    diffusion_steps = int: reverse-diffusion steps {default: 200}

    recycling_steps = int: recycling iterations {default: 2}

    seed = int: random seed. Drawn FRESH PER DESIGN when omitted, so two designs are
    genuinely different rather than identical duplicates. The value used is printed,
    written into the state title, and part of the design key.
    {default: None, meaning "choose one"}

    live_view = 0/1: build the design's object up as it diffuses, one state per
        captured frame, advancing the displayed state as each lands. The SAME single
        object either way -- the finished design is appended as its last state and
        left showing, so a live run and a plain one leave the same thing in the
        session. Scrub the states afterwards to replay the rollout. A run that is
        cancelled or fails leaves no object at all, as it does without this.
        {default: off, unless live_steps is given}

    live_steps = int: roughly how many states the live recording should end up with,
        across the whole rollout. Giving it turns the live view ON by itself; giving
        live_view=0 alongside it is a contradiction and is refused. Between 1 and
        diffusion_steps - 1, and refused outside that rather than clamped.

        APPROXIMATE on purpose: the capture interval is a whole number of steps, so
        the achievable counts are quantised -- over the default 199 rollout steps they
        run 199, 100, 67, 50, 40, 34 and so on -- and the nearest achievable count to
        what was asked is what you get. With quiet=0 the real number is printed before
        the run starts.

        {default: none, meaning the runtime's own cadence of one frame every 4
        rollout steps -- which is 50 states at diffusion_steps=200, but 5 at 20 and
        2 at 6, because it is a fixed interval rather than a fixed count}

    keep_frames = 0/1: keep the captured frames as states of the finished object,
        so they can be scrubbed afterwards. Off by default: watching is the point,
        and the states are opt-in. With it off the run animates exactly the same
        way -- every frame is still captured and still shown -- but nothing is
        appended, and the object you are left with is indistinguishable from a
        live_view=0 run: one state, the design. Only meaningful with the live view
        on; live_view=0 alongside it is a contradiction and is refused. {default: 0}

EXAMPLES

    fetch 1ao6
    design_backbone rfd3, 1ao6 and chain A and resi 100-200, \\
        hotspots=1ao6 and chain A and resi 142+145+149

    # pick the hotspots in the viewer, then:
    design_backbone rfd3, my_target, sele, length=75, n_designs=5

NOTES

    THIS TAKES MINUTES PER DESIGN. On an M3 Pro at 200 steps, a 578-residue target
    with a 60-residue design measured 821-1321 s each -- about 17 minutes. Cost grows
    quadratically with the number of atoms, so a small epitope is far cheaper than a
    whole protein. n_designs COSTS N FULL RUNS: there is no shared trunk to amortise,
    so five designs against a large target is well over an hour. The runs are
    sequential, so peak memory is that of ONE design.

    Cancel a running design with "design_cancel". It stops within one diffusion step.

    THE FIRST CALL DOWNLOADS WEIGHTS, in the background -- ~625 MB for rfd3. That runs
    on its own thread and this command returns immediately; each job sits in phase
    "download"/"extract" and is submitted automatically once the bundle lands. Watch it
    with design_status, stop it with design_weights_cancel, or pre-warm the cache with:

        design_weights rfd3, download=1

    THE TARGET IS HELD FIXED, and that is checked rather than assumed: the
    "target_drift_max" metric on each result is the largest distance any target atom
    moved, and it is 0.000 on a correct run.

    Every design carries a "design_key" metric -- the generator, weight pack, target
    residues and coordinates, hotspots, length, seed and schedule. A later refold of
    the same design can be keyed to it, which is what makes refold-versus-design
    comparison possible without guessing which design a prediction came from.

SEE ALSO

    design_status, design_cancel, design_result, design_weights
    """
    generator_obj = registry.get(generator)
    generator_obj.check_available()

    count = int(n_designs)
    if not 1 <= count <= _max_designs(generator_obj):
        raise PredictionOptionError(
            'n_designs must be between 1 and %d' % _max_designs(generator_obj))

    # Universal, so it holds for every generator rather than for whichever ones remembered
    # to check: a zero-length generated chain is nonsense for any method, and letting it
    # through would start a several-hundred-megabyte download for a design that cannot
    # exist. A method's own upper bound is its business and lives in `parse_target`.
    if int(length) < 1:
        raise PredictionOptionError(
            'length must be at least 1 residue, got %d' % int(length))

    structure = resolve_target(target, hotspots, quiet=quiet, _self=_self)

    if seed is None:
        import random
        seed = random.randrange(RANDOM_SEED_BOUND)

    requested = dict(recycling_steps=int(recycling_steps),
                     diffusion_steps=int(diffusion_steps),
                     seed=int(seed))
    options = generator_obj.validate_options(requested)

    # Presentation parameters, resolved together because they interact.
    #
    # AFTER `validate_options`, deliberately. `diffusion_steps` is validated there, and
    # everything below is derived from it -- so running first meant promising a state
    # count for a run that then refused to start: `diffusion_steps=1, live_steps=1,
    # quiet=0` printed "will capture 1 state" and only then raised, and
    # `diffusion_steps=0, live_steps=5` raised "live_steps must be between 1 and 1",
    # blaming the wrong parameter for a bad schedule.
    #
    # REFUSED rather than clamped. Still nothing has been allocated -- no weight fetch,
    # no job -- so a number that cannot be honoured is a command error the user can
    # correct, not a degrade. The "live view must never fail a design" rule governs
    # everything AFTER the job starts, and nothing here starts one.
    rollout_steps = rollout_step_count(options.diffusion_steps)
    if live_steps is not None:
        try:
            live_steps = int(live_steps)
        except (TypeError, ValueError):
            raise PredictionOptionError(
                'live_steps must be a whole number of states between 1 and %d'
                ' (diffusion_steps is %d), got %r'
                % (rollout_steps, options.diffusion_steps, live_steps))
        if not 1 <= live_steps <= rollout_steps:
            raise PredictionOptionError(
                'live_steps must be between 1 and %d -- the rollout has that many steps'
                ' to capture at diffusion_steps=%d -- got %d'
                % (rollout_steps, options.diffusion_steps, live_steps))
    # Giving `live_steps` is an explicit opt-in and turns the live view on by itself.
    #
    # `live_view=0` ALONGSIDE it is a CONTRADICTION and is refused, not absorbed. It asks
    # for a recording length and for no recording in the same breath, and one of the two
    # has to be silently thrown away -- which is precisely the "a parameter you passed did
    # nothing" failure this feature keeps closing. Refusing also makes the case observable
    # in something other than a log line: `live_view=0` already forces both fields off, so
    # a warning was the ONLY thing distinguishing the two paths.
    keep = bool(int(keep_frames))
    if live_view is None:
        watch = live_steps is not None or keep
    else:
        watch = bool(int(live_view))
        if live_steps is not None and not watch:
            raise PredictionOptionError(
                'live_steps=%d asks for a %d-state live recording and live_view=0 asks'
                ' for none -- drop whichever one you did not mean.'
                % (live_steps, live_steps))
        if keep and not watch:
            raise PredictionOptionError(
                'keep_frames=1 asks to keep the live view\'s frames and live_view=0 asks'
                ' for no live view -- drop whichever one you did not mean.')

    # THE derivation, on this side, so the number can be reported before the run starts.
    # The wire carries the INTERVAL. `None` means "the runtime's default cadence", which
    # is the path EVERY live run without `live_steps` takes -- including the app's Live
    # checkbox, which sends no count.
    live_interval = None
    if watch and live_steps is not None:
        live_interval = capture_interval(live_steps, rollout_steps)
        achievable = capture_frame_count(live_interval, rollout_steps)
        if not int(quiet):
            # The counts are quantised, so asking for 30 and getting 29 is a small
            # surprise that costs nothing to remove. Said before the run, not after it.
            colorprinting.parrot(
                ' design: live view will capture %d model frame%s%s, every %d of the %d'
                ' rollout steps; %s'
                % (achievable, '' if achievable == 1 else 's',
                   '' if achievable == live_steps
                   else ' (the nearest to the %d requested -- the interval is a whole'
                        ' number of steps, so the reachable counts are spaced out)'
                        % live_steps,
                   live_interval, rollout_steps,
                   'they are kept as states and the finished design is appended after'
                   ' them.' if keep else
                   'they are animated and discarded, so the object ends as the design'
                   ' alone -- pass keep_frames=1 to scrub them afterwards.'))


    # Validated BEFORE the weight fetch starts and before anything is submitted: a refused
    # target must cost nothing, and every check in parse_target is one the runtime would
    # otherwise make after a 625 MB download.
    spec = generator_obj.parse_target(structure, length, name=name)

    bundle = generator_obj.weight_bundle
    weights_path = None
    fetch = None
    if bundle is not None:
        # One entry point for all three cases -- cached, bundled in the app, or needs
        # downloading -- so this cannot drift from what fetching.start() knows.
        started = fetching.start(bundle, weight_cache())
        if started.state == 'done':
            weights_path = started.path
        else:
            fetch = started
            # Regardless of `quiet`: nothing else tells a command-line user why their
            # design has not started, and the app's tray is driven by the marker rather
            # than by this line.
            colorprinting.warning(
                ' design: fetching %s weights (%.0f MB) in the background; the design'
                ' starts on its own when they land. Cancel with'
                ' "design_weights_cancel %s".'
                % (generator_obj.id, (bundle.size or 0) / 1e6, generator_obj.id))

    jobs = []
    for index in range(count):
        # A distinct seed per design, or every one would be the same molecule. The first
        # uses the seed resolved above, so `seed=N` still reproduces exactly and
        # `n_designs` extends that run rather than replacing it.
        if index == 0:
            design_options = options
        else:
            import random
            design_options = generator_obj.validate_options(
                dict(requested, seed=random.randrange(RANDOM_SEED_BOUND)))
        # Named per design, from that design's own key: two seeds are two objects, and an
        # identical re-run lands back in the same one.
        key = spec.design_key(design_options,
                              weights_version=_weight_version(generator_obj.id))
        if name:
            object_name = str(name) if count == 1 else '%s_%02d' % (name, index + 1)
        else:
            object_name = default_object_name(key, generator_obj.id)
        # Legalised HERE, once, rather than left for `create` to do silently: this string
        # becomes the placeholder's key, the name the runtime is handed and echoes back on
        # delivery, the object the metric run is filed against, and what the message below
        # tells the user to look for. Any of those differing from the object that actually
        # exists is a silent no-op somewhere downstream.
        object_name = _legal_object_name(object_name, _self=_self)
        # DesignSpec is a __slots__ class, not a namedtuple: assign, don't _replace. A
        # copy per design, because each names its own object.
        # CONSTRUCTED with every field, not built bare and then patched. `DesignSpec` is
        # a __slots__ class rebuilt per design, so a field left off silently reverts to
        # the constructor default -- and passing them here is also what makes the
        # constructor's own coercion the real path rather than dead code that reads like
        # a guard.
        design_spec = type(spec)(spec.target, spec.length, name=object_name,
                                 generator_id=spec.generator_id,
                                 design_chain=spec.design_chain,
                                 live_view=watch, live_interval=live_interval,
                                 keep_frames=keep)
        if fetch is not None:
            job = _DeferredDesignJob(design_spec, design_options, generator_obj, bundle,
                                     object_name)
        else:
            job = generator_obj.submit(design_spec, design_options, weights_path)
        # Stamped here rather than passed into submit(): the handle a generator returns is
        # its own type, and the registry id is the one fact the command layer knows and
        # the transport does not. Progress and metric recording read it back off the
        # handle.
        try:
            job.generator_id = generator_obj.id
        except AttributeError:
            pass          # __slots__ handle with no room: it simply gets the spinner
        _JOBS[job.job_id] = job
        register_pending(object_name, job.job_id, _self=_self)
        jobs.append(job)
        if not int(quiet):
            colorprinting.parrot(
                ' design: job %s %s, will load as %s (%d residues, seed %d)'
                % (job.job_id,
                   'waiting on weights' if fetch is not None else 'submitted',
                   object_name, design_spec.length, design_options.seed))

    return jobs[0] if count == 1 else jobs


def _max_designs(generator_obj):
    """The generator's own ceiling on designs per command, or a conservative default.

    Read off the module rather than hardcoded here, because "how many is too many" is a
    property of how long one design takes -- which is a property of the method.
    """
    import sys as _sys
    module = _sys.modules.get(type(generator_obj).__module__)
    return int(getattr(module, 'MAX_DESIGNS', 5))


def design_status(job_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_status" reports the state of one design job, or of all of them.

USAGE

    design_status [ job_id ]

SEE ALSO

    design_backbone
    """
    # Polling design_status is what a script does while it waits, so it doubles as the
    # main-thread pump that submits jobs whose weights have arrived. The app also pumps
    # from the object panel's poll, so neither environment depends on the other.
    pump(_self=_self)
    if job_id:
        jobs = {job_id: _job(job_id)}
    else:
        jobs = dict(_JOBS)
    out = {}
    for key, job in jobs.items():
        out[key] = job.status()
    if not int(quiet):
        if not out:
            colorprinting.parrot(' design: no jobs this session')
        for key, status in out.items():
            colorprinting.parrot(
                ' design: %s %s (%s%s)%s'
                % (key, status.get('state', '?'), status.get('phase', '?'),
                   '' if status.get('fraction') is None
                   else ' %d%%' % int(float(status['fraction']) * 100),
                   '' if not status.get('error') else ': ' + str(status['error'])))
    return out


def design_cancel(job_id, quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_cancel" stops a running design.

    It stops within one diffusion step: the rollout polls for cancellation once per
    step, which is the finest granularity available for a synchronous sampler. During
    the one-time setup -- the phase that holds the memory peak -- it is observed at
    the phase boundary instead.

    Cancelling a design whose WEIGHTS are still downloading cancels the transfer, and
    that transfer is shared: any other job waiting on the same bundle is cancelled
    with it. There is one download, and no way to abandon it for one caller while
    another still needs it.

USAGE

    design_cancel job_id

ARGUMENTS

    job_id = string: the job to cancel, or the name of a pending object -- which
        cancels the design outstanding for it.

SEE ALSO

    design_backbone, design_status
    """
    # A pending OBJECT name cancels the design registered against it, exactly as
    # `predict_cancel` accepts one. That is not a convenience: the progress tray's
    # Cancel button is per OBJECT and passes the object name, because that is the id
    # a card is keyed by. Accepting only a job id made that button raise KeyError --
    # found by pressing it, not by a test, because the Swift side asserted the
    # command STRING and the Python side asserted the job-id path, and nothing
    # checked that one accepts what the other sends.
    #
    # Job ids are 'pending-<12 hex>' or the host's own hex and never collide with an
    # object name, so this cannot shadow a real id.
    ids = _PENDING.get(job_id)
    if ids:
        for one in list(ids):
            try:
                _job(one).cancel()
            except Exception as exc:
                colorprinting.warning(' design_cancel: %s (%s)' % (one, exc))
        if not int(quiet):
            colorprinting.parrot(' design: cancel requested for %s (%d job(s))'
                                 % (job_id, len(ids)))
        pump(_self=_self)
        return job_id
    job = _job(job_id)
    job.cancel()
    if not int(quiet):
        colorprinting.parrot(' design: cancel requested for %s' % job_id)
    # The placeholder comes down on the next pump for a deferred job, and when the
    # runtime writes its terminal status for a running one.
    pump(_self=_self)
    return job_id


def design_result(job_id, name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_result" loads a finished design by hand.

    Rarely needed: a design is loaded into its placeholder automatically as soon as
    it finishes. This exists for a script that wants the object under a different
    name, or after a placeholder was dismissed.

USAGE

    design_result job_id [, name ]

SEE ALSO

    design_backbone, design_status
    """
    job = _job(job_id)
    status = job.status()
    path = status.get('result_path')
    if status.get('state') != 'done' or not path:
        raise PredictionInputError(
            'job %s is %s, not done' % (job_id, status.get('state', 'unknown')))
    object_name = str(name) or getattr(job, 'object_name', '') or \
        getattr(getattr(job, 'spec', None), 'name', '') or job_id
    # `load` would legalise this for itself, but the name is also dss'd, printed and
    # RETURNED -- a script that loads under a name of its own and then uses the return
    # value must get the object that now exists, not the string it asked for.
    object_name = _legal_object_name(object_name, _self=_self)
    _self.load(path, object_name, zoom=0)
    try:
        _self.dss(object_name)
    except Exception:
        pass
    if not int(quiet):
        colorprinting.parrot(' design: loaded %s as %s' % (job_id, object_name))
    return object_name


def design_dismiss(name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_dismiss" clears the card of a design that failed or was cancelled, and
    removes its empty placeholder. With no name, clears all of them.

USAGE

    design_dismiss [ name ]

SEE ALSO

    design_backbone
    """
    # The explicit name only: the list branches are already table keys.
    names = ([_legal_object_name(name, _self=_self)] if name
             else list(_RECENT) + list(_PENDING))
    for entry in names:
        _RECENT.pop(entry, None)
        discard_pending(entry, _self=_self)
    if not int(quiet):
        colorprinting.parrot(' design: dismissed %s'
                             % (', '.join(names) if names else 'nothing'))
    return names


def design_weights(generator='', download=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_weights" reports which generator weight packs are cached, and can fetch
    them ahead of time.

    Worth doing before the first design: the rfd3 pack is ~625 MB, and fetching it
    up front means the design itself starts immediately.

USAGE

    design_weights [ generator [, download ]]

ARGUMENTS

    generator = str: which generator, or '' for all of them {default: ''}

    download = 0/1: fetch what is missing, in the background {default: 0}

SEE ALSO

    design_backbone, design_weights_cancel
    """
    cache = weight_cache()
    ids = [str(generator)] if generator else registry.available()
    out = {}
    for generator_id in ids:
        generator_obj = registry.get(generator_id)
        bundle = generator_obj.weight_bundle
        if bundle is None:
            out[generator_id] = {'bundle': None, 'cached': True, 'path': None}
            continue
        # Asked BEFORE any fetch: a generator that cannot run in this build is reported
        # but never downloaded, so a bulk `download=1` does not pull half a gigabyte for
        # a method whose runtime is not linked.
        runnable, why = _can_run(generator_obj)
        cached = cache.is_cached(bundle)
        record = {'bundle': bundle.id, 'version': bundle.version,
                  'cached': bool(cached), 'size': bundle.size,
                  'runnable': runnable,
                  'path': cache.path_for(bundle) if cached else None}
        out[generator_id] = record
        if not int(quiet):
            colorprinting.parrot(
                ' design: %s -- %s %s, %.0f MB, %s%s'
                % (generator_id, bundle.id, bundle.version, (bundle.size or 0) / 1e6,
                   'cached' if cached else 'not cached',
                   '' if runnable else ' (cannot run in this build: %s)' % why))
        if int(download) and not cached:
            if not runnable:
                continue
            started = fetching.start(bundle, cache)
            record['fetching'] = started.state != 'done'
            if not int(quiet):
                colorprinting.parrot(
                    ' design: fetching %s in the background' % bundle.id)
    return out


def _can_run(generator_obj):
    """(runnable, why-not) for a generator, without touching the weight cache."""
    try:
        generator_obj.check_available()
    except Exception as exc:
        return False, str(exc)
    return True, ''


def design_weights_cancel(generator='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "design_weights_cancel" stops a generator weight download in progress.

    Every design waiting on that bundle is cancelled with it: there is one transfer,
    and no way to abandon it for one caller while another still needs it.

USAGE

    design_weights_cancel [ generator ]

SEE ALSO

    design_weights
    """
    ids = [str(generator)] if generator else registry.available()
    stopped = []
    for generator_id in ids:
        bundle = registry.get(generator_id).weight_bundle
        if bundle is None:
            continue
        # By ID, never bare. `fetching.cancel()` with no argument stops every transfer in
        # the process, predictions included -- one process-wide table keyed by bundle id.
        fetching.cancel(bundle.id)
        stopped.append(bundle.id)
    pump(_self=_self)
    if not int(quiet):
        colorprinting.parrot(' design: cancelled %s'
                             % (', '.join(stopped) if stopped else 'nothing'))
    return stopped


def _job(job_id):
    try:
        return _JOBS[str(job_id)]
    except KeyError:
        raise PredictionInputError(
            'unknown design job %r; this session has: %s'
            % (job_id, ', '.join(_JOBS) or '(none)'))
