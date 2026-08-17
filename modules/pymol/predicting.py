"""Structure prediction: cmd.predict and friends.

Thin by design. Argument marshalling and session interaction only; the registry,
the weight cache, and the predictors themselves live in pymol.predictors.

Every function ends its signature with _self=cmd. That is load-bearing:
pymol2/cmd2.py binds _self only when it appears in the argspec, and otherwise
copies the function verbatim so it silently drives the GLOBAL instance.
"""
import sys

from . import colorprinting
from .predictors import fetching, registry
from .predictors.base import PredictionOptions  # noqa: F401  (re-export for callers)
from .predictors.errors import PredictionOptionError
from .predictors.weights import WeightCache

cmd = sys.modules["pymol.cmd"]

_JOBS = {}
_CACHE = None


def weight_cache():
    """Process-wide WeightCache. Rebuilt if RAYMOL_WEIGHTS_DIR changes."""
    global _CACHE
    import os
    root = os.environ.get('RAYMOL_WEIGHTS_DIR')
    if _CACHE is None or (root and _CACHE.root != root):
        _CACHE = WeightCache(root)
    return _CACHE


# -- Auto-load: content-derived names and pending placeholders -----------------
#
# A prediction takes seconds to tens of minutes, so `cmd.predict` returns a handle
# rather than blocking. That left the result invisible until the user called
# `predict_result` by hand. Instead an EMPTY object is created at submit time under a
# name derived from the input, and the host loads the finished structure into it.
#
# The placeholder is deliberately a real, zero-atom object (`cmd.create(name, 'none')`):
# it shows up in the object panel immediately, and -- verified -- loading into it lands
# at state 1 rather than appending after a phantom empty state, so re-running the same
# sequence yields models 1..N in one object with no gaps.

#: Upper bound for a randomly chosen seed. Below 2**53 so the value survives a JSON
#: round-trip through a Double on the Swift side; still 4 billion distinct samples.
RANDOM_SEED_BOUND = 2 ** 32

#: Ceiling on `n_models`. Each model is a FULL run -- see predict()'s docstring -- and a
#: single 600-residue run already takes ~11 minutes, so an unbounded count is a foot-gun
#: rather than a feature.
MAX_MODELS = 20

#: Hex digits of the sequence digest used in a derived object name. Eight, not six:
#: six is 24 bits, and two DIFFERENT sequences colliding would silently merge into one
#: object, which is worse than a visible name clash. Widen, never narrow.
OBJECT_NAME_DIGEST_CHARS = 8

#: name -> job_id for placeholders whose job has not finished. Read by the object panel
#: (to disable the enable-toggle and show hover detail), by the session-save wrapper
#: (to keep placeholders out of a .pse), and by cleanup on failure/cancel/quit.
_PENDING = {}

#: name -> per-object progress bookkeeping the job handles cannot supply:
#: {'total': N, 'done': k, 'started': monotonic_seconds, 'floor': fraction}.
#: `floor` is a monotone clamp -- bands make monotonicity meaningful, this makes
#: it guaranteed against a phase table that drifts, HostJob's 'queued' fallback,
#: and the fraction reset every terminal path in Swift writes.
_TRACK = {}


def default_object_name(sequence, predictor_id=''):
    """The object name a prediction lands in when the caller does not pick one.

    Shaped `<method>_prediction_<digest>`, e.g. `boltz2_prediction_f2b2e116`. The method
    leads so that objects sort and read by predictor -- with several methods registered,
    the same sequence folded two ways must be two objects, not two models of one, because
    they are not samples of the same distribution.

    The digest is of the sequence, so re-predicting the same target with the same method
    appends another model to the same object instead of littering the session. Normalised
    for case and whitespace -- otherwise 'mktay' and 'MKTAY ' would give two objects for
    one protein -- but the '/' chain separator is significant, because A/B is a different
    complex from the concatenation AB.
    """
    import hashlib
    normalised = ''.join(str(sequence).split()).upper()
    digest = hashlib.sha256(normalised.encode('utf-8')).hexdigest()
    stem = 'prediction_%s' % digest[:OBJECT_NAME_DIGEST_CHARS]
    method = ''.join(ch for ch in str(predictor_id) if ch.isalnum() or ch == '_')
    return '%s_%s' % (method, stem) if method else stem


def job_ids():
    """Ids of every job submitted this session, newest last.

    Public because the command-line completer offers them for predict_status /
    predict_cancel / predict_result, and a completer must not reach into _JOBS.
    """
    return list(_JOBS)


def pending_objects():
    """Copy of the pending map: object name -> LIST of outstanding job ids.

    A list because `n_models` submits several runs that all deliver into one object.
    """
    return {name: list(ids) for name, ids in _PENDING.items()}


def pending_info(name, _self=cmd):
    """Structured progress for a placeholder, or None if it is not pending.

    Keys: state, phase, fraction (0..1 or None), moving, detail, models_done,
    models_total, elapsed, error.

    ONE status read per pending OBJECT, never per model: this runs on the main
    thread every 500 ms and n_models can be 20. The first outstanding job is the
    one in flight; the rest are queued behind it.

    Never raises. The whole body -- status(), the composition AND the arithmetic
    -- is inside one try, because appkit_inspector's caller writes no file at all
    if this throws, which freezes the object panel on a stale list.
    """
    import time
    job_ids = _PENDING.get(name)
    if not job_ids:
        return None
    track = _TRACK.setdefault(name, {'total': len(job_ids), 'done': 0,
                                     'started': time.monotonic(), 'floor': 0.0})
    info = {'state': 'running', 'phase': 'pending', 'fraction': None,
            'moving': False, 'models_done': 0, 'models_total': 1,
            'elapsed': 0.0, 'error': None, 'detail': 'pending', 'bundle': None}
    try:
        info['models_done'] = track['done']
        info['models_total'] = max(track['total'], 1)
        info['elapsed'] = max(time.monotonic() - track['started'], 0.0)
        job = _JOBS.get(job_ids[0])
        if job is not None:
            # The weight bundle this job is still waiting on, or None once it has
            # been submitted. The tray hides a prediction card while its bundle's
            # own download card is up, so a cold-cache run shows ONE card and not
            # two describing the same transfer at two different percentages.
            bundle = getattr(job, '_bundle', None)
            if bundle is not None and getattr(job, '_real', None) is None:
                info['bundle'] = getattr(bundle, 'id', None)
            status = job.status()
            info['state'] = status.get('state') or 'running'
            info['phase'] = status.get('phase') or 'pending'
            info['error'] = status.get('error')
            fraction, moving = _job_progress(job, status)
            if fraction is not None:
                whole = (track['done'] + fraction) / info['models_total']
                whole = max(whole, track.get('floor', 0.0))
                track['floor'] = whole
                info['fraction'] = whole
                info['moving'] = moving
            elif track.get('floor'):
                info['fraction'] = track['floor']
        info['detail'] = _format_detail(info)
    except Exception:
        pass
    return info


def _job_progress(job, status):
    """(fraction, moving) from the job's own predictor, or (None, False).

    Tries predictor_id via the registry first (set on regular jobs in predict()),
    then falls back to _predictor (the raw object stored on _DeferredJob before
    its real job is submitted). _DeferredJob.__slots__ blocks the predictor_id
    assignment, so without the fallback all deferred-phase fractions are dropped.
    """
    try:
        from .predictors import registry
        predictor_id = getattr(job, 'predictor_id', '') or ''
        if predictor_id:
            predictor = registry.get(predictor_id)
        else:
            predictor = getattr(job, '_predictor', None)
        if predictor is None:
            return None, False
        return predictor.progress(status)
    except Exception:
        return None, False


def _format_detail(info):
    """'pending: diffusion 64% (model 1 of 3)'. Short -- it is a tooltip."""
    parts = ['pending: %s' % (info['phase'],)]
    if info['fraction'] is not None and info['moving']:
        parts.append('%d%%' % int(info['fraction'] * 100))
    detail = ' '.join(parts)
    if info['models_total'] > 1:
        detail += ' (model %d of %d)' % (
            min(info['models_done'] + 1, info['models_total']), info['models_total'])
    return detail


def pending_detail(name, _self=cmd):
    """One-line description of the job a placeholder is waiting on, or None.

    This is the string the object panel shows on hover, so it must stay short and
    must never raise: it is rendered from a 500 ms poll on the main thread. It is
    now a thin formatter over pending_info, so the tooltip and the progress card
    can never disagree.
    """
    info = pending_info(name, _self=_self)
    return None if info is None else info['detail']


def register_pending(name, job_id, _self=cmd):
    """Create the empty placeholder (if new) and remember what it is waiting for.

    A LIST of job ids, not one: `n_models` submits several runs that all deliver into the
    same object, and the placeholder has to stay pending until the last of them lands.
    Recording only the newest would clear the pending mark on the first delivery while
    later models were still running.
    """
    if name not in _self.get_names('objects'):
        _self.create(name, 'none')
    _PENDING.setdefault(name, []).append(job_id)
    import time
    track = _TRACK.setdefault(
        name, {'total': 0, 'done': 0, 'started': time.monotonic(), 'floor': 0.0})
    track['total'] += 1


def discard_pending(name, _self=cmd):
    """Forget a placeholder, deleting the object only if it never received atoms.

    The atom check is the important part: cleanup can race a job that just finished, and
    deleting a completed structure would destroy the very thing the user asked for.
    """
    _PENDING.pop(name, None)
    _TRACK.pop(name, None)
    try:
        if name in _self.get_names('objects') and _self.count_atoms(name) == 0:
            _self.delete(name)
    except Exception:
        pass


def clear_pending(_self=cmd):
    """Drop every placeholder, and anything that would create another.

    Stopping the weight fetches is not optional here: a deferred job outlives its
    placeholder, so clearing the placeholders alone would let the next pump() put them
    straight back. Dropping the deferred jobs matters for the same reason.
    """
    fetching.shutdown()
    for job_id, job in list(_JOBS.items()):
        if isinstance(job, _DeferredJob):
            _JOBS.pop(job_id, None)
    for name in list(_PENDING):
        discard_pending(name, _self=_self)
    _TRACK.clear()


# -- Deferred submit: jobs waiting on a weight download ------------------------
#
# The fetch runs on a thread (see predictors/fetching.py) and MAY NOT touch the session.
# So a prediction whose weights are cold cannot be submitted where it was asked for --
# it becomes a _DeferredJob, and pump() finishes the job of submitting it once the bytes
# have landed. pump() is main-thread-only and is driven by the object panel's existing
# 500 ms poll in the app, and by predict_status / predict_result elsewhere.


class _DeferredJob:
    """A prediction that is waiting for its weights.

    Presents the same surface as a real job -- job_id, status(), cancel(), spec, options
    -- so predict_status, predict_cancel, predict_result and the object panel need to
    know nothing about deferral. Once submitted it forwards everything to the real job.

    `job_id` is this handle's own id, NOT the host's: the host allocates its id inside
    submit(), which has not run yet at the point the caller needs something to hold. The
    two never need to agree, because every host-side path is keyed by the host's id
    (status file, cancel marker) and every session-side path by the object name.
    """

    __slots__ = ('job_id', 'spec', 'options', 'object_name', '_predictor',
                 '_bundle', '_real', '_error', '_cancelled', '_reaped')

    def __init__(self, spec, options, predictor, bundle, object_name):
        import uuid
        self.job_id = 'pending-%s' % uuid.uuid4().hex[:12]
        self.spec = spec
        self.options = options
        self.object_name = object_name
        self._predictor = predictor
        self._bundle = bundle
        self._real = None
        self._error = None
        self._cancelled = False
        self._reaped = False

    @property
    def submitted(self):
        return self._real is not None

    @property
    def settled(self):
        """True once the outcome is known -- submitted, failed or cancelled.

        NOT the same as reaped: cancel() settles a job from whatever thread the command
        came in on, but taking its placeholder back down is session work and has to wait
        for pump(). A job can therefore be settled and still need one more pump.
        """
        return (self._real is not None or self._error is not None
                or self._cancelled)

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
            # Report the fetch's phase (download/extract) rather than a flat "weights",
            # so the panel's hover line and predict_status say which half is slow.
            base.update(phase=snap['phase'], fraction=snap['fraction'])
        return base

    def cancel(self):
        """Cancel the prediction, or -- if it has not started -- the download itself.

        Cancelling the fetch cancels it for EVERY job waiting on the same bundle, which
        is correct: there is one transfer, and no way to abandon it for one caller while
        another still needs it. Each waiting job is then settled by pump().
        """
        if self._real is not None:
            self._real.cancel()
        else:
            self._cancelled = True
            fetching.cancel(self._bundle.id)

    def advance(self, _self=cmd):
        """Main-thread half of the job: submit once the weights are there, or clean up.

        Returns True when this job is fully reaped and needs no further pumping. Every
        line here touches the session, which is precisely why the fetch worker cannot
        do any of it.
        """
        if self._reaped:
            return True
        # Cancelled through predict_cancel / predict_weights_cancel rather than by the
        # worker noticing: the outcome is already decided, but the placeholder is still
        # standing and only this thread may remove it.
        if self._cancelled or self._error is not None:
            self._reaped = True
            discard_pending(self.object_name, _self=_self)
            return True
        fetch = fetching.get(self._bundle.id)
        if fetch is None:
            # The record was forgotten out from under us (only forget() does this, and
            # only in tests). Nothing can complete this job, so fail it visibly rather
            # than leave it running forever.
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
            # Take the placeholder back down. It only goes if it is still empty, so a
            # sibling model that landed first is never destroyed. One call clears the
            # whole name -- with n_models every job waits on the SAME fetch, so they
            # all fail together and the later calls are no-ops.
            discard_pending(self.object_name, _self=_self)
            return True
        # register_pending already ran in predict(); the placeholder is up and this job
        # is already recorded against it, so submitting is all that is left.
        self._real = self._predictor.submit(self.spec, self.options, fetch.path)
        return True


def pump(_self=cmd):
    """Advance every deferred job. MAIN THREAD ONLY -- it creates session objects.

    Cheap and idempotent by design: it is called from the object panel's 500 ms poll, so
    it must stay a few dict lookups when there is nothing to do. Never raises; a failure
    here would break the poll that drives the whole panel.

    Returns the number of jobs that were reaped by this call.
    """
    settled = 0
    for job in list(_JOBS.values()):
        if not isinstance(job, _DeferredJob) or job._reaped:
            continue
        try:
            if job.advance(_self=_self):
                settled += 1
        except Exception as exc:
            colorprinting.warning(' predict: could not start job %s (%s)'
                                  % (job.job_id, exc))
    return settled


def deliver_result(path, name, seed=None, _self=cmd):
    """Load a finished prediction into its placeholder and retire the pending mark.

    One entry point rather than two calls from the host, so the load and the bookkeeping
    cannot get out of step -- a name left in `_PENDING` after a successful load would be
    filtered out of every subsequent session save.

    `zoom=0` on purpose: a prediction can land many minutes after submit, and pulling the
    camera onto it while the user is working elsewhere is hostile. The object is already
    visible, because the placeholder appeared at submit time.
    """
    try:
        _self.load(path, name, zoom=0)
        # Record which seed produced THIS model, in its state title, so a multi-model
        # object says what each model is. It survives into a saved .pse, which is what
        # makes a randomly seeded run reproducible after the fact.
        if seed is not None:
            try:
                _self.set_title(name, _self.count_states(name), 'seed=%d' % int(seed))
            except Exception:
                pass
        # Assign secondary structure explicitly. `auto_dss` does NOT fire when loading
        # into a PRE-EXISTING object, which is exactly what the placeholder makes this --
        # measured: this path leaves ss='' on every residue, while the same file loaded
        # under a fresh name comes back H/S/L. Without this, cartoon renders every
        # prediction as featureless loops, and boltz output carries no HELIX/SHEET
        # records to fall back on.
        #
        # ss is a per-ATOM property in PyMOL, not per-state, so one call covers every
        # appended model -- but it also means two models with genuinely different
        # conformations share whichever assignment dss computed, which is a PyMOL
        # limitation rather than a choice made here.
        try:
            _self.dss(name)
        except Exception as exc:
            # Not fatal: a structure without ss is still the thing the user asked for.
            # Reported rather than swallowed, because a silently skipped step here looks
            # exactly like a prediction that folded to nothing but loops.
            colorprinting.warning(' predict: could not assign secondary structure to %s'
                                  ' (%s)' % (name, exc))
    finally:
        # Retire only THIS job. With n_models > 1 the object stays pending until the last
        # model has landed, so the panel keeps showing progress for the rest.
        remaining = _PENDING.get(name)
        if remaining:
            remaining.pop(0)
            track = _TRACK.get(name)
            if track is not None:
                track['done'] += 1
            if not remaining:
                _PENDING.pop(name, None)
                _TRACK.pop(name, None)


def session_save(session, _self=cmd):
    """Session-save task: keep pending placeholders out of the .pse.

    A placeholder is a real zero-atom object and DOES survive a session round-trip, so a
    session saved mid-prediction would carry an object that can never fill -- the job is
    gone on reload. This runs after `_cmd.get_session` has populated `session['names']`
    (exporting.py:443), so the entry can simply be dropped from the copy being written.
    The live session is untouched, which is why there is no delete/recreate and no race.

    Only objects that are BOTH pending and still empty are dropped: a job that completed
    between submit and save has real atoms and must be saved like anything else.
    """
    names = session.get('names')
    if not names or not _PENDING:
        return 1
    keep = []
    for entry in names:
        # None entries are structural in PyMOL's names list -- preserve them.
        if entry and entry[0] in _PENDING:
            try:
                if _self.count_atoms(entry[0]) == 0:
                    continue
            except Exception:
                continue
        keep.append(entry)
    session['names'] = keep
    return 1


def predict(predictor, sequence, name='', recycling_steps=3, diffusion_steps=200,
            seed=None, n_models=1, diffusion_samples=None, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict" folds one or more sequences with a registered structure predictor.
    It returns a job handle; poll it with "predict_status" and load the result with
    "predict_result".

USAGE

    predict predictor, sequence [, name [, recycling_steps [, diffusion_steps
        [, seed ]]]]

ARGUMENTS

    predictor = str: id of a registered predictor, e.g. boltz2

    sequence = str: one-letter sequence. Use "/" to separate chains of a
    multimer -- NOT a comma, which the command parser treats as an argument
    separator. Chains are assigned ids A, B, C...

    name = str: object name for the loaded result {default: <predictor>_pred}

    recycling_steps = int: trunk recycling passes {default: 3}

    diffusion_steps = int: reverse-diffusion steps; higher is slower and more
    accurate {default: 200}

    seed = int: random seed. Drawn FRESH PER RUN when omitted, so repeat
    predictions of one sequence are different models rather than identical
    duplicates. The value used is printed and recorded in each model's state
    title, so any result can be reproduced exactly with seed=N.
    {default: None, meaning "choose one"}

    n_models = int: how many models to produce, appended as states 1..N of the
    same object. Each gets its own seed. {default: 1, maximum: 20}

    diffusion_samples = int: accepted only so that a predictor which does not
    plumb it can REJECT it by name instead of ignoring it. No shipped predictor
    supports it. {default: None, meaning "not requested"}

EXAMPLES

    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    predict boltz2, MKTAY/GSHMA, name=dimer, diffusion_steps=300
    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ, n_models=5

NOTES

    Defaults follow upstream Boltz. Options a predictor does not implement are
    rejected rather than ignored, so a typo cannot silently degrade a result.

    n_models COSTS N FULL RUNS. Each model repeats the whole prediction with a
    different seed, including the trunk; it is not several samples drawn from one
    diffusion run. boltz-mlx does not plumb diffusion_samples -- only sample 0
    escapes its predictor -- so sharing the trunk across models is not available.
    Budget accordingly: five models of a 600-residue target is roughly an hour.
    The runs are sequential, so peak memory is that of ONE model, not N.

    THE FIRST CALL DOWNLOADS WEIGHTS, in the background. A predictor whose weights
    are not yet cached needs them fetched first -- for boltz2 a ~505 MiB download
    plus extraction, minutes on a slow link. That runs on its own thread and this
    command returns immediately; each job sits in phase "download"/"extract" and is
    submitted automatically once the bundle lands. In the app a progress sheet
    tracks it. Watch it from a script with predict_status, stop it with
    predict_weights_cancel, or pre-warm the cache up front with:

        predict_weights boltz2, download=1

    Nothing is left behind if the fetch fails or is cancelled: the object is only
    created at the moment the prediction is actually submitted.

SEE ALSO

    predict_status, predict_result, predict_cancel, predict_weights
    """
    predictor_obj = registry.get(predictor)
    predictor_obj.check_available()

    spec = predictor_obj.parse_spec(sequence, name=name or (predictor + '_pred'))

    # A fresh seed per run unless one is given, so repeat predictions of the same sequence
    # are genuinely different models rather than bit-identical duplicates -- measured, two
    # runs at the fixed seed 0 gave RMSD 0.0000 and appending the second was pointless.
    #
    # The seed used is RECORDED -- printed, carried on the job's options, and written into
    # the per-state title -- because a random seed you cannot recover makes every result
    # unreproducible. `seed=N` reproduces one exactly.
    #
    # Bounded to 2**32 rather than the full UInt64 range: the value crosses a JSON wire
    # into Swift, and an integer above 2**53 cannot survive a round-trip through a Double,
    # which is what Foundation's JSON layer may use for large numbers.
    count = int(n_models)
    if not 1 <= count <= MAX_MODELS:
        raise PredictionOptionError('n_models must be between 1 and %d' % MAX_MODELS)

    if seed is None:
        import random
        seed = random.randrange(RANDOM_SEED_BOUND)

    requested = dict(
        recycling_steps=int(recycling_steps),
        diffusion_steps=int(diffusion_steps),
        seed=int(seed))
    if diffusion_samples is not None:
        # Forwarded unvalidated on purpose: validate_options rejects it by name.
        # A command function cannot take **kwargs (parsing.py forces NO_CHECK when
        # CO_VARKEYWORDS is set), so the option a user is most likely to reach for
        # has to be named here to be rejected with the taxonomy's error instead of
        # a bare TypeError.
        requested['diffusion_samples'] = diffusion_samples
    options = predictor_obj.validate_options(requested)

    # Resolve the object name BEFORE submitting: the host needs it to load the result,
    # and the placeholder has to exist by the time this call returns so the panel shows
    # the job immediately rather than after the first poll.
    object_name = (str(name) if name else
                   default_object_name(sequence, predictor_obj.id))
    # PredictionSpec is a __slots__ class, not a namedtuple: assign, don't _replace.
    spec.name = object_name

    # Weights, without blocking (#284). A cold cache used to be fetched inline, which
    # froze the app for the whole half-gigabyte transfer AND made the progress messages
    # describing it unrenderable -- the app drains feedback from a main-run-loop timer
    # that a blocked main thread never lets fire. So a cold cache starts a background
    # fetch and the jobs are deferred until it lands; a warm cache is unchanged and
    # still submits immediately, which is every call after the first.
    weights_path = None
    fetch = None
    bundle = predictor_obj.weight_bundle
    if bundle is not None:
        # One entry point for all three cases -- already cached, bundled inside the app,
        # or needs downloading -- so this cannot drift from what fetching.start() knows.
        # In particular BundledSource has no `version`, so reaching for is_cached() here
        # instead would raise AttributeError on it.
        started = fetching.start(bundle, weight_cache())
        if started.state == 'done':
            weights_path = started.path
        else:
            fetch = started
            # Warn regardless of `quiet`: nothing else tells a command-line user why
            # their prediction has not started, and the app's progress sheet is driven
            # by the marker rather than by this line.
            colorprinting.warning(
                ' predict: fetching %s weights (%.0f MB) in the background; the'
                ' prediction starts on its own when they land. Cancel with'
                ' "predict_weights_cancel %s".'
                % (predictor_obj.id, (bundle.size or 0) / 1e6, predictor_obj.id))

    jobs = []
    for index in range(count):
        # A distinct seed per model, or every model would be the same structure. The
        # first uses the seed resolved above, so `predict ..., seed=N` still reproduces
        # exactly and `n_models` extends that run rather than replacing it.
        if index == 0:
            model_options = options
        else:
            import random
            model_options = predictor_obj.validate_options(
                dict(requested, seed=random.randrange(RANDOM_SEED_BOUND)))
        if fetch is not None:
            job = _DeferredJob(spec, model_options, predictor_obj, bundle, object_name)
        else:
            job = predictor_obj.submit(spec, model_options, weights_path)
        _JOBS[job.job_id] = job
        # Which predictor to ask for progress bands. Set here rather than required
        # of every job class, so a third-party handle needs no new attribute.
        try:
            job.predictor_id = predictor_obj.id
        except AttributeError:
            pass          # __slots__ handle: it simply gets the spinner
        # The placeholder goes up for a deferred job too, so the object panel shows the
        # download the same way it shows inference -- pending_detail reads the phase off
        # the job, which reports "download"/"extract" until the real one takes over. If
        # the fetch fails or is cancelled, pump() takes the placeholder back down.
        register_pending(object_name, job.job_id, _self=_self)
        jobs.append(job)
        if not int(quiet):
            colorprinting.parrot(
                ' predict: job %s %s, will load as %s model %d (seed %d)'
                % (job.job_id,
                   'waiting on weights' if fetch is not None else 'submitted',
                   object_name, index + 1, model_options.seed))

    # A single job for the default, a list when several were asked for. Keeping the
    # scalar for n_models=1 means existing callers and `job.job_id` keep working.
    return jobs[0] if count == 1 else jobs


def predict_status(job_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_status" reports the state of one prediction job, or of all of them.

USAGE

    predict_status [ job_id ]

SEE ALSO

    predict
    """
    # Polling predict_status is what a script does while it waits, so it doubles as the
    # main-thread pump that submits jobs whose weights have arrived. The app also pumps
    # from the object panel's 500 ms poll, so neither environment depends on the other.
    pump(_self=_self)
    if job_id:
        jobs = {job_id: _job(job_id)}
    else:
        jobs = dict(_JOBS)
    out = {}
    for key, job in jobs.items():
        out[key] = job.status()
        if not int(quiet):
            colorprinting.parrot(' predict: %s %s %s' % (
                key, out[key].get('state'), out[key].get('phase')))
    return out


def predict_cancel(job_id, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_cancel" asks a running prediction to stop.

USAGE

    predict_cancel job_id

ARGUMENTS

    job_id = string: the job to cancel, or the name of a pending object -- which
        cancels every model still outstanding for it.

SEE ALSO

    predict
    """
    # A pending OBJECT name cancels every model registered against it. The
    # progress card's Cancel is per object, and with n_models > 1 cancelling only
    # _PENDING[name][0] would leave the other N-1 running. Job ids are
    # 'pending-<12 hex>' / backend-specific and never collide with object names,
    # so this cannot shadow a real id.
    ids = _PENDING.get(job_id)
    if ids:
        for one in list(ids):
            try:
                _job(one).cancel()
            except Exception as exc:
                colorprinting.warning(' predict_cancel: %s (%s)' % (one, exc))
        if not int(quiet):
            colorprinting.parrot(' predict_cancel: cancelled %d job(s) for %s'
                                 % (len(ids), job_id))
        return
    _job(job_id).cancel()
    # Reap now: a job cancelled before its weights arrived still has a placeholder
    # standing, and only the main thread may take it down.
    pump(_self=_self)
    if not int(quiet):
        colorprinting.parrot(' predict: cancel requested for %s' % (job_id,))


def predict_result(job_id, name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_result" loads a finished prediction into the session.

USAGE

    predict_result job_id [, name ]

SEE ALSO

    predict, predict_status
    """
    from .predictors.errors import PredictionError
    pump(_self=_self)
    job = _job(job_id)
    status = job.status()
    if status.get('state') != 'done':
        raise PredictionError(
            'job %s is %s, not done' % (job_id, status.get('state')))
    path = status.get('result_path')
    if not path:
        raise PredictionError('job %s produced no structure' % job_id)
    object_name = name or getattr(job.spec, 'name', None) or job_id
    _self.load(path, object_name)
    if not int(quiet):
        colorprinting.parrot(' predict: loaded %s' % object_name)
    return object_name


def predict_weights(predictor='', download=0, async_=-1, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_weights" reports -- and optionally pre-fetches -- each predictor's
    cached model weights.

USAGE

    predict_weights [ predictor [, download [, async_ ]]]

ARGUMENTS

    predictor = str: id of a registered predictor {default: '', meaning all}

    download = 0/1: fetch any bundle that is not cached {default: 0}

    async_ = 0/1/-1: whether to return before the download finishes. -1 chooses:
    asynchronous inside the RayMol application, where blocking the calling thread
    would freeze the window, and synchronous otherwise, which is what a script
    pre-warming the cache wants. {default: -1}

NOTES

    Progress is reported either way -- as a percentage on the command line, and as
    the application's progress sheet. Stop a running fetch with
    "predict_weights_cancel".

SEE ALSO

    predict, predict_weights_cancel
    """
    from .predictors import host
    cache = weight_cache()
    ids = [predictor] if predictor else registry.available()
    # -1 means "decide": a UI thread must never block on a half-gigabyte transfer,
    # while a headless script calling this to pre-warm the cache is asking to wait.
    # PyMOL's own `fetch` resolves its async_ default the same way.
    wait = not host.available() if int(async_) < 0 else not int(async_)
    out = {}
    for pid in ids:
        bundle = registry.get(pid).weight_bundle
        if bundle is None:
            out[pid] = {'cached': True, 'path': None, 'bundle': None}
            continue
        if int(download) and not cache.is_cached(bundle):
            fetching.start(bundle, cache)
            if wait:
                _wait_for_fetch(bundle, quiet)
        out[pid] = {'cached': bool(cache.is_cached(bundle)),
                    'path': cache.path_for(bundle),
                    'bundle': bundle.id}
        if not int(quiet):
            colorprinting.parrot(' predict: %s weights cached=%s at %s' % (
                pid, out[pid]['cached'], out[pid]['path']))
    return out


def _wait_for_fetch(bundle, quiet, _poll=0.1):
    """Block until a fetch settles, printing progress as it goes.

    Only ever called on a thread that is allowed to block -- see predict_weights's
    async_ resolution. The progress lines are printed HERE, by the waiting thread,
    rather than by the worker: on the command line they are the only progress the user
    gets, and printing them from the waiting thread keeps them ordered with whatever
    else that thread is writing.
    """
    fetch = fetching.get(bundle.id)
    if fetch is None:
        return
    shown = -1
    while True:
        snap = fetch.snapshot()
        if not int(quiet):
            step = int(snap['fraction'] * 100) // 10 * 10
            if step != shown and snap['state'] == 'running':
                shown = step
                colorprinting.parrot(' predict: %s %d%%' % (snap['phase'], step))
        if snap['state'] != 'running':
            break
        if fetch.thread is None:
            break
        fetch.thread.join(_poll)
    snap = fetch.snapshot()
    if snap['state'] == 'error':
        from .predictors.errors import WeightDownloadFailed
        # Re-raised on the CALLING thread: the worker has no caller to propagate to, so
        # without this a `predict_weights ..., download=1` that failed would return a
        # cheerful cached=False and look like a no-op.
        raise WeightDownloadFailed(snap['error'] or 'weight fetch failed')
    if snap['state'] == 'cancelled' and not int(quiet):
        colorprinting.warning(' predict: fetch of %s weights cancelled' % bundle.id)


def predict_weights_cancel(predictor='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_weights_cancel" stops an in-progress model-weight download.

USAGE

    predict_weights_cancel [ predictor ]

NOTES

    Cancellation is cooperative and observed between 1 MiB chunks, so it takes
    effect almost immediately. Nothing partial is kept: the next attempt starts
    over rather than resuming.

    A bundle is fetched ONCE however many predictions are waiting on it, so
    cancelling stops all of them. Each then settles as "cancelled" and no object
    is created for it.

SEE ALSO

    predict, predict_weights
    """
    bundle_id = ''
    if predictor:
        bundle = registry.get(predictor).weight_bundle
        if bundle is None:
            if not int(quiet):
                colorprinting.parrot(' predict: %s has no downloadable weights'
                                     % predictor)
            return 0
        bundle_id = bundle.id
    stopped = fetching.cancel(bundle_id)
    # Settle the waiting jobs HERE rather than leaving it to the next pump. The worker
    # only notices the flag at its next chunk boundary, so a job that waited for the
    # fetch's own state to flip would keep reporting "running" for up to one 1 MiB read
    # after the user pressed Cancel -- long enough to look like the button did nothing.
    for job in list(_JOBS.values()):
        if (isinstance(job, _DeferredJob) and not job.settled
                and (not bundle_id or job._bundle.id == bundle_id)):
            job.cancel()
    pump(_self=_self)
    if not int(quiet):
        colorprinting.parrot(' predict: cancelled %d weight download(s)' % stopped)
    return stopped


def _job(job_id):
    from .predictors.errors import PredictionError
    try:
        return _JOBS[job_id]
    except KeyError:
        raise PredictionError('unknown prediction job %r' % job_id)
