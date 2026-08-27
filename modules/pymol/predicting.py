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
#: {'total': N, 'done': k, 'started': monotonic_seconds, 'floor': fraction,
#:  'phase': str, 'phase_started': monotonic_seconds}.
#: `floor` is a monotone clamp -- bands make monotonicity meaningful, this makes
#: it guaranteed against a phase table that drifts, HostJob's 'queued' fallback,
#: and the fraction reset every terminal path in Swift writes.
#: `phase` / `phase_started` are the ETA's clock: it is measured per PHASE, so
#: entering a new one must restart it rather than inherit the previous phase's.
_TRACK = {}

#: Below this stage-local fraction the ETA is suppressed. `remaining` divides by
#: f, so at f = 0.005 a phase two seconds old projects a six-minute wait that the
#: next step revises away -- a confidently wrong countdown, which is worse than no
#: countdown. WeightsFetchState.secondsRemaining (PyMOLEngine.swift) refuses on
#: the same grounds, there with `received > 0`.
ETA_MIN_FRACTION = 0.02

#: ...and for the same reason, nothing is projected from a phase this young.
#: WeightsFetchState uses one second over a download that reports ~500 times;
#: a phase here can report as few as four times (recycling 3 = 4 trunk passes),
#: so its first sample is far coarser and deserves a wider window.
ETA_MIN_PHASE_SECONDS = 2.0

#: name -> the last record of a job that ended badly, held so the card can say
#: WHY an eleven-minute run produced nothing. Success is not retained: the loaded
#: object is its own confirmation. Capped, oldest-first, so a scripted loop of
#: failures cannot grow it without bound.
_RECENT = {}

#: How many terminal records to hold.
MAX_RECENT = 16

#: name -> the most recent pending_info() result. A FALLBACK only: discard_pending
#: re-reads the status fresh, because the cached copy is one poll old and the
#: failure it needs to retain is written milliseconds before the discard runs.
#: This still covers a name that left _PENDING before the discard reached it.
_LAST_INFO = {}


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


def _legal_object_name(name, _self=cmd):
    """The object name PyMOL will actually use for `name`.

    Creating an object LEGALISES its name -- an apostrophe, a space and a forward slash
    all become underscores -- and nothing tells the caller. So a name chosen here and the
    object that actually exists are two different strings, and every table keyed on the
    chosen one then addresses an object that is not there: the placeholder is not deleted
    by `discard_pending`, `session_save` does not recognise it and writes it into the
    .pse, and `record_run` files metrics against a name nothing answers to.

    `cmd.get_legal_name` rather than a local rewrite: it is the same C++ rule
    (`ObjectMakeValidName`) that creation itself applies, so the two cannot drift. That
    rule is subtler than replacing three characters -- it strips a trailing `)`, yields one
    underscore per BYTE of a multi-byte character, and leaves `+`, `-` and `.` alone.
    It is idempotent, so applying it twice on one path is harmless.

    Applied on EVERY public entry point that takes an object name, `pending_info`
    included. In production its callers pass keys that came out of these tables, so the
    call is a no-op there -- but a rule of "some of these legalise and some do not" is one
    a caller has to know, and the cost of not needing to know it was measured at 0.82 us
    per call: 0.016 ms for twenty placeholders on a 500 ms poll tick, 0.003% of it.
    """
    return _self.get_legal_name(str(name))



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


def recent_objects():
    """Names whose job ended badly and whose card is still waiting to be seen."""
    return list(_RECENT)


def pending_info(name, _self=cmd):
    """Structured progress for a placeholder, or None if it is not pending.

    Keys: state, phase, fraction (0..1 or None), moving, detail, models_done,
    models_total, elapsed, error, step, total_steps, remaining.

    ONE status read per pending OBJECT, never per model: this runs on the main
    thread every 500 ms and n_models can be 20. The first outstanding job is the
    one in flight; the rest are queued behind it.

    Never raises. The whole body -- status(), the composition AND the arithmetic
    -- is inside one try, because appkit_inspector's caller writes no file at all
    if this throws, which freezes the object panel on a stale list.
    """
    import time
    try:
        name = _legal_object_name(name, _self=_self)
    except Exception:
        # Guarded because of the "never raises" contract above, and only here: a lookup
        # under the name as given misses and returns None, which the panel renders as
        # "pending" -- where letting this out would write no panel file at all.
        pass
    job_ids = _PENDING.get(name)
    if not job_ids:
        return _RECENT.get(name)
    track = _TRACK.setdefault(name, {'total': len(job_ids), 'done': 0,
                                     'started': time.monotonic(), 'floor': 0.0})
    info = {'state': 'running', 'phase': 'pending', 'fraction': None,
            'moving': False, 'models_done': 0, 'models_total': 1,
            'elapsed': 0.0, 'error': None, 'detail': 'pending', 'bundle': None,
            'step': None, 'total_steps': None, 'remaining': None}
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
            # Coerced, not trusted. status() is a THIRD-PARTY surface (any registered
            # predictor supplies it) and every value here crosses json.dumps into a
            # strongly-typed Swift decoder that does no coercion of its own. A
            # ValueError in 'error' is not JSON-serialisable and truncates the panel
            # file to zero bytes; an int in 'phase' decodes as a non-String and fails
            # the WHOLE PanelPayload, taking the object list down with it.
            info['state'] = str(status.get('state') or 'running')
            info['phase'] = str(status.get('phase') or 'pending')
            error = status.get('error')
            info['error'] = None if error is None else str(error)
            info['step'] = _as_int(status.get('step'))
            info['total_steps'] = _as_int(status.get('total_steps'))
            # The ETA's clock. A new phase restarts it: rates are per phase (the
            # trunk's four passes and diffusion's two hundred steps are nothing
            # alike), so inheriting the previous phase's start would project
            # diffusion's first step from the trunk's whole duration.
            #
            # A fraction that went BACKWARDS restarts it too. With n_models the
            # next job enters the SAME phase name at step 1, so the phase test
            # alone would keep model 1's start time and quietly inflate every
            # estimate for model 2 by the whole of model 1.
            local = _as_float(status.get('fraction'))
            if (track.get('phase') != info['phase']
                    or local is None
                    or local < track.get('phase_fraction', 0.0)):
                track['phase'] = info['phase']
                track['phase_started'] = time.monotonic()
            track['phase_fraction'] = 0.0 if local is None else local
            phase_elapsed = max(
                time.monotonic() - track.get('phase_started', time.monotonic()), 0.0)
            # STAGE-LOCAL, from the raw status -- never the composed value below.
            # compose_progress's own docstring says the bands are LAYOUT, NOT TIME
            # ('load' is ~10 s cold and ~0 s warm; inference is 6.5 s at 60
            # residues and 675 s at 600), so a countdown extrapolated from the
            # composed fraction would be confidently wrong.
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
        fraction, moving = predictor.progress(status)
        # progress() is overridable, so the finiteness guard cannot live only in
        # compose_progress. A NaN reaching pending_info poisons track['floor']
        # permanently -- every later max() against it is NaN too -- and writes an
        # invalid JSON literal that no decoder accepts.
        if fraction is not None:
            import math
            if (not isinstance(fraction, (int, float))
                    or isinstance(fraction, bool)
                    or not math.isfinite(float(fraction))):
                return None, False
        return fraction, bool(moving)
    except Exception:
        return None, False


def _as_int(value):
    """A non-negative int, or None. Coerced, because status() is third-party.

    Every value in this record crosses json.dumps into a strongly-typed Swift
    decoder that does no coercion of its own, so a float or a numeric string here
    would fail the WHOLE payload decode and take the object list with it.
    """
    try:
        if value is None or isinstance(value, bool):
            return None
        number = int(value)
    except Exception:
        return None
    return number if number >= 0 else None


def _as_float(value):
    """A finite float, or None. status() is third-party; nothing here is trusted."""
    try:
        if value is None or isinstance(value, bool):
            return None
        import math
        number = float(value)
    except Exception:
        return None
    return number if math.isfinite(number) else None


def _phase_remaining(local_fraction, phase_elapsed):
    """Seconds left IN THE CURRENT PHASE, from its own measured rate, or None.

        remaining = phase_elapsed * (1 - f) / f

    `local_fraction` is status()['fraction'] RAW -- completion within the phase.
    Never the composed whole-job value: the band table compose_progress folds
    that through is layout, not time, so a countdown derived from it would be a
    guess wearing a number's clothes.

    Suppressed for a young phase and for a tiny f, where the divisor makes the
    estimate wild. Follows WeightsFetchState.secondsRemaining's policy
    (PyMOLEngine.swift), which likewise refuses rather than reporting an absurd
    figure, and which extrapolates from an AVERAGE rate rather than an
    instantaneous one -- phase_elapsed / f is exactly that average.

    Never raises: it is on the 500 ms main-thread poll.
    """
    try:
        import math
        if phase_elapsed < ETA_MIN_PHASE_SECONDS:
            return None
        if local_fraction is None or isinstance(local_fraction, bool):
            return None
        f = float(local_fraction)
        if not math.isfinite(f) or f < ETA_MIN_FRACTION or f >= 1.0:
            return None
        return phase_elapsed * (1.0 - f) / f
    except Exception:
        return None


def format_remaining(seconds):
    """'4 min left'. Deliberately coarse, and deliberately identical to
    ProgressCard.formatRemaining (ProgressTray.swift), so the hover tooltip and
    the progress card never word the same estimate two different ways.

    Coarse because a to-the-second countdown derived from an average rate invites
    a trust it has not earned.
    """
    if seconds < 10:
        return 'almost done'
    if seconds < 90:
        # int(x + 0.5), not round(): Swift's .rounded() is half-away-from-zero
        # while Python's round() is half-to-even, and the two would disagree on
        # exactly the .5 cases this formatter is built to round.
        return '%d sec left' % (int(seconds + 0.5),)
    if seconds < 3600:
        minutes = int(seconds / 60.0 + 0.5)
        # Rounding can carry 59.5 min -> 60; route those to the next bucket.
        if minutes >= 60:
            return 'over an hour left'
        return '%d min left' % (minutes,)
    return 'over an hour left'


def format_phase_remaining(seconds):
    """'this phase: 4 min left'. The SCOPED spelling, for a prediction card.

    Deliberately identical to ProgressCard.formatPhaseRemaining
    (ProgressTray.swift), for the same reason format_remaining is.

    The scope is stated because the number is scoped: `remaining` comes from
    _phase_remaining, which measures the CURRENT PHASE only, while everything
    beside it on the card -- the percentage, the bar, 'model 4 of 20' -- is the
    whole job. Unqualified, the two read as one claim: a 1.10.0 capture shows
    'Diffusion 19% . step 141 of 200 . model 4 of 20 . almost done', where
    'almost done' means diffusion is seconds from step 200 but reads as if the
    run were finishing with sixteen models still to go.

    'phase' rather than 'model', which would be the friendlier word: diffusion is
    band 0.40-0.97 of a model and 'write' follows it, so a phase estimate is not
    a model estimate and must not be sold as one. A whole-JOB countdown is not
    offered at all -- compose_progress's bands are layout, not time, so there is
    nothing honest to extrapolate one from.

    format_remaining stays unscoped, because its other caller is right: a weight
    download IS the whole task, and 'almost done' there means what it says.
    """
    return 'this phase: %s' % (format_remaining(seconds),)


def _format_detail(info):
    """'pending: diffusion 64% step 84 of 200 (model 1 of 3), this phase: 4 min left'.

    Short -- it is a tooltip. The percentage is the COMPOSED whole-job value, the
    same number the progress bar draws, so the two can never disagree; the
    stage-local position is said precisely by 'step 84 of 200' instead. The
    estimate is the current phase's, which is what was actually measured, and it
    SAYS so: unqualified, it read as a claim about the whole job it sits beside
    (see format_phase_remaining).
    """
    parts = ['pending: %s' % (info['phase'],)]
    if info['fraction'] is not None and info['moving']:
        parts.append('%d%%' % (int(info['fraction'] * 100),))
    step, total_steps = info.get('step'), info.get('total_steps')
    if step is not None and total_steps:
        parts.append('step %d of %d' % (step, total_steps))
    detail = ' '.join(parts)
    if info['models_total'] > 1:
        detail += ' (model %d of %d)' % (
            min(info['models_done'] + 1, info['models_total']), info['models_total'])
    remaining = info.get('remaining')
    if remaining is not None:
        detail += ', %s' % (format_phase_remaining(remaining),)
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
    name = _legal_object_name(name, _self=_self)
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
    # Capture BEFORE the pop: this is the only moment the record still exists and
    # we already know the outcome.
    #
    # Read it FRESH. _LAST_INFO holds whatever the last 500 ms poll saw, and the
    # real ordering in the app is: poll observes 'running' -> inference fails on a
    # background queue -> settle() writes the terminal status file -> the discard is
    # hopped to the main queue and runs within milliseconds, LONG before the next
    # poll. Trusting the cache therefore retains nothing on the only path that
    # matters. Nothing deletes the status file (InferenceJob has no removeItem
    # on statusPath), so re-reading it here is what actually sees the failure;
    # _LAST_INFO stays as the fallback for a job that vanished from _PENDING first.
    #
    # NOT on the poll path: discard_pending runs once per placeholder teardown, so
    # this does not add a per-tick status read.
    name = _legal_object_name(name, _self=_self)
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
    _RECENT.clear()
    _LAST_INFO.clear()


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

    __slots__ = ('job_id', 'spec', 'options', 'object_name', 'predictor_id',
                 '_predictor', '_bundle', '_real', '_error', '_cancelled', '_reaped')

    def __init__(self, spec, options, predictor, bundle, object_name):
        import uuid
        self.job_id = 'pending-%s' % uuid.uuid4().hex[:12]
        self.spec = spec
        self.options = options
        self.object_name = object_name
        # Which method this is a job of. A HostJob is told the same thing in predict();
        # both carry it so metric recording can ask any job handle, deferred or not,
        # without knowing which kind it holds.
        self.predictor_id = predictor.id
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


def _host_handle(job):
    """The handle that owns the host-side paths, unwrapping a deferred job.

    A _DeferredJob's own id is not the host's -- the host allocates its id inside
    submit() -- so anything keyed by a temp-file path has to come from the real job.
    """
    return getattr(job, '_real', None) or job


def _run_inputs(job, seed):
    """The provenance half of a metric run: what this prediction was ASKED to do.

    Inputs, not metrics, because they are not measurements -- but a metric without
    them is not evidence of anything, which is why they travel in the same record.
    #293 (a second weight pack) and #301 (an alignment, at a depth) both change the
    numbers without changing the sequence, so both have to be here.
    """
    spec = getattr(job, 'spec', None)
    options = getattr(job, 'options', None)
    inputs = {'predictor': getattr(job, 'predictor_id', '') or '',
              'seed': None if seed is None else int(seed)}
    if options is not None:
        inputs['options'] = options.as_dict()
        # The seed the job actually ran with wins over the one the host echoed back:
        # with n_models only the first model uses the seed the user gave.
        inputs['seed'] = options.seed
    if spec is not None:
        inputs['chains'] = [{'chain': chain, 'length': len(sequence)}
                            for chain, sequence in spec.chains]
        alignments = getattr(spec, 'alignments', None) or {}
        if alignments:
            inputs['alignments'] = {chain: msa.name
                                    for chain, msa in alignments.items()}
    return inputs


def _run_values(job, status, state):
    """The metrics the PYTHON side knows, without asking the host for anything.

    Deliberately independent of the metrics document: a host that never writes one --
    an older app, or a runtime with no confidence module -- still gets a run carrying
    what the prediction cost and what it was over. Everything here is a measurement or
    a fact about the input, never a knob (knobs are inputs).
    """
    from pymol.metrics import store as metric_store
    predictor_id = getattr(job, 'predictor_id', '') or ''
    spec = getattr(job, 'spec', None)
    options = getattr(job, 'options', None)
    values = []

    def _add(key, **kwargs):
        # A predictor declares the subset it can produce, so a key it never declared is
        # simply not written -- that is the capability contract working, not a failure.
        # ONLY that: a scope or type error is a bug in this function and must not be
        # swallowed into a silently incomplete run.
        from pymol.metrics.errors import MetricSchemaError
        try:
            values.append(metric_store.value(predictor_id, key, **kwargs))
        except MetricSchemaError:
            pass

    if spec is not None:
        _add('n_residues', value=spec.total_residues)
        _add('n_chains', value=len(spec.chains))
        # Chain scope, because it genuinely differs per chain: an alignment for the
        # target and none for the binder is the designed-binder case, not an omission.
        # The depth RECORDED is the depth READ -- the parser truncates at msa_depth --
        # so a run that used 1000 rows of a 6000-row alignment says 1000.
        depth_cap = getattr(options, 'msa_depth', None)
        for chain, msa in (getattr(spec, 'alignments', None) or {}).items():
            depth = msa.depth if depth_cap is None else min(msa.depth, depth_cap)
            _add('msa_depth', value=depth, chain=chain)

    for key in ('elapsed_s', 'peak_bytes'):
        # Absent stays absent: a host that reported no timing gets no `elapsed_s`,
        # rather than a zero that reads as an instantaneous fold.
        if status.get(key) is not None:
            _add(key, value=status[key], state=state)
    return values


def _document_values(job, predictor_id, state, object_name):
    """What the HOST measured: pLDDT, PAE, the interface scores.

    These exist only inside the runtime. Before #308 exactly one of them survived --
    pLDDT, as rounded B-factors -- and `ScoredStructure.pae` and `interfaceScores()`
    were computed and dropped.

    The document's own `tool` is overridden with the predictor that ran. The host knows
    its RUNTIME ('boltz'), not which predictor selected it, and boltz2 and boltz2-bf16
    share one runtime while declaring their metrics separately. This is our own host
    writing to a path we named, not a foreign file, so the Python side is the
    authority on which tool produced it.
    """
    import json
    import os
    from pymol.metrics import document

    handle = _host_handle(job)
    path = getattr(handle, 'metrics_path', '')
    if not path or not os.path.exists(path):
        return []
    with open(path) as stream:
        payload = json.load(stream)
    payload['tool'] = predictor_id
    # A document may name its own state, but the state a model actually landed in is
    # known only here -- the host cannot know how many models preceded it in the
    # object. So the state is stamped on the way in, over anything the file claims.
    for entry in payload.get('values') or []:
        if 'state' in entry or entry.get('index') is not None:
            entry['state'] = state
    # The object is named here too, rather than trusted from the file: the host wrote it
    # at submit time, and a rename between submit and delivery would leave the document
    # naming an object that no longer exists.
    parsed = document.parse(payload, object=object_name)
    return parsed['values']


def _weight_version(predictor_id):
    """Which weights produced this run, as `bundle-id vN`, or '' for a method with none.

    Part of the record because it is the thing most likely to differ between two runs
    that otherwise look identical: boltz2 and boltz2-bf16 are the same model at two
    precisions (#293), and comparing their numbers without knowing which pack ran is
    comparing nothing.
    """
    try:
        bundle = registry.get(predictor_id).weight_bundle
    except Exception:
        return ''
    if bundle is None:
        return ''
    version = getattr(bundle, 'version', '')
    return ('%s %s' % (bundle.id, version)).strip()


def record_run(name, job_id, state, _self=cmd):
    """Record what this prediction measured, against the object it landed in (#308).

    Returns the MetricRun, or None when there is nothing to attach it to. Never raises
    into the delivery path: a structure that folded must not fail to appear because its
    metrics could not be filed.
    """
    from pymol.metrics import binding
    job = _JOBS.get(job_id)
    if job is None:
        return None
    predictor_id = getattr(job, 'predictor_id', '') or ''
    if not predictor_id:
        return None
    try:
        status = job.status()
    except Exception:
        status = {}

    values = _run_values(job, status, state)
    try:
        values.extend(_document_values(job, predictor_id, state, name))
    except Exception as exc:
        # The host's numbers are the valuable half, so a malformed document is worth
        # a warning -- but the run is still recorded with what the Python side knows.
        colorprinting.warning(
            ' predict: could not read the metrics %s wrote for job %s (%s)'
            % (predictor_id, job_id, exc))
    if not values:
        return None
    return binding.record(name, predictor_id, values,
                          tool_version=_weight_version(predictor_id),
                          inputs=_run_inputs(job, status.get('seed')),
                          _self=_self)


def superpose_on_first_model(name, _self=cmd):
    """Superimpose every model of `name` onto model 1. Returns the RMSD of the model that
    landed last, or None when no fit was made.

    A folding backend has no shared frame of reference: each seed comes back in whatever
    orientation and at whatever origin the network happened to produce. So appending
    model 2 to model 1 puts two copies of the SAME molecule in two different places --
    measured, two deliveries of one bit-identical structure sat 25.08 A apart, and read
    0.000 A after this fit. Without it, stepping through the states of an `n_models`
    object makes the structure jump across the viewport, and every `intra_rms_cur`
    reading is dominated by an arbitrary rigid-body offset rather than by the
    conformational difference the number is meant to report.

    `intra_fit` rather than `fit`/`align`, which CANNOT do this: at the default
    matrix_mode, ExecutiveRMS ends in OMOP_TTTF -> ObjectMoleculeTransformTTTf(I, ttt,
    -1), and that -1 is "all states", so asking `fit` to move one state moves the whole
    object. intra_fit (-> ExecutiveRMSStates -> OMOP_SFIT) is the only primitive that
    fits each state separately, and it leaves the target state exactly where it was --
    which is what makes model 1 hold still. That matters beyond tidiness: the camera was
    framed on model 1, and anything positioned relative to it (a co-loaded target, a
    measurement, a scene) stays valid only if it does not move.

    Every model is re-fitted on every delivery rather than only the new one, because
    there is no per-state fit primitive to reach for. It is cheap and it converges:
    measured over 20 redeliveries the worst per-coordinate drift on an already-settled
    model was 7e-7 A, three orders of magnitude below the 1e-3 A precision the
    coordinates themselves carry.

    All atoms, not `name CA`: a prediction can be a ligand or a nucleic acid, which have
    no CA at all, and a fit that silently selects nothing is worse than one that is
    slightly pulled on by side-chain rotamers. `intra_fit "obj and name CA", 1` remains
    available by hand for the canonical backbone superposition.
    """
    states = _self.count_states(name)
    if states < 2:
        # Nothing to superimpose onto: the first model IS the frame every later one
        # adopts. Also the guard that keeps intra_fit off a zero-atom placeholder, which
        # raises rather than declining.
        return None
    # Models of different molecules share no frame to be fitted in. Predicting another
    # sequence into an existing name merges the atom sets, leaving each state holding
    # only its own subset -- measured, 10 atoms in state 1 against 24 in state 2.
    # intra_fit does decline that (returning -1.0 per state) but it declines LOUDLY, one
    # C++ Executive-Warning per state, so checking first keeps a deliberate reuse of a
    # name from looking like a malfunction in the log.
    if _self.count_atoms(name, state=states) != _self.count_atoms(name, state=1):
        return None
    values = _self.intra_fit(name, 1)
    if not isinstance(values, list) or len(values) < states:
        return None
    rms = values[states - 1]
    # intra_fit reports -1.0 for a state it could not match -- the target state always,
    # and any state whose atoms did not pair up. Not a distance, so it must not be
    # returned as one.
    return None if rms < 0.0 else rms


def deliver_result(path, name, seed=None, _self=cmd):
    """Load a finished prediction into its placeholder and retire the pending mark.

    One entry point rather than two calls from the host, so the load and the bookkeeping
    cannot get out of step -- a name left in `_PENDING` after a successful load would be
    filtered out of every subsequent session save.

    `zoom=0` on purpose: a prediction can land many minutes after submit, and pulling the
    camera onto it while the user is working elsewhere is hostile. The object is already
    visible, because the placeholder appeared at submit time.
    """
    # Read BEFORE the finally block pops it: this is the job whose model is landing,
    # and it is what says which predictor, which options and which alignment produced
    # the coordinates about to be loaded.
    name = _legal_object_name(name, _self=_self)
    landing = (_PENDING.get(name) or [None])[0]
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
        # Put this model in the frame of model 1 (#329). A backend returns each seed in
        # its own arbitrary orientation, so an appended model lands somewhere else
        # entirely unless it is superposed -- and model 1, which the camera is framed on,
        # is the one that must not move.
        #
        # Never fatal, and warned rather than swallowed, for the reason dss above is: a
        # model that arrives unsuperposed is still the structure the user asked for, but
        # it looks exactly like a prediction that folded to something else.
        try:
            rms = superpose_on_first_model(name, _self=_self)
            if rms is not None:
                # Not gated on quiet: this is the ensemble spread, the one number that
                # says how much the models actually disagree, and the delivery it belongs
                # to has no `quiet` to consult -- it is driven by the host, minutes after
                # the command that asked for it returned.
                colorprinting.parrot(
                    ' predict: %s model %d superposed on model 1 (RMSD %.3f)'
                    % (name, _self.count_states(name), rms))
        except Exception as exc:
            colorprinting.warning(' predict: could not superpose %s on its first model'
                                  ' (%s)' % (name, exc))
        # Attach what this run measured to the object it just landed in (#308). AFTER
        # the load, because the metrics are checked against the object -- the state
        # they were measured on has to exist before they can name it.
        #
        # Never fatal, and warned rather than swallowed, for the reason dss above is:
        # a prediction that arrives with no numbers looks exactly like a prediction
        # from a host that measured none.
        try:
            record_run(name, landing, _self.count_states(name), _self=_self)
        except Exception as exc:
            colorprinting.warning(' predict: could not record metrics for %s (%s)'
                                  % (name, exc))
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
                # A successful delivery clears any retained failure record for
                # this name, so a retry that succeeds does not leave a stale
                # error card in the tray.
                _LAST_INFO.pop(name, None)
                _RECENT.pop(name, None)


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


# -- Input resolution: a sequence, an object, or a selection -------------------
#
# `predict boltz2, MKTAY` and `predict boltz2, 1ubq` both have to work, and the two are
# told apart by ASKING THE SESSION -- whatever selects atoms is a selection, anything
# else that could be residues is a sequence. That order is the safe one: sniffing the
# text first would fold `polymer` (seven perfectly good residue letters) as a peptide
# while the structure the user meant sat loaded in the session.

#: Alternative SPELLINGS of a canonical residue, missing from exporting._resn_to_aa:
#: force-field names for a protonation or disulfide state (CHARMM HSD/HSE/HSP, AMBER
#: HID/HIE/HIP/CYX/CYM/ASH/GLH/LYN). Same residue, different name, so these are
#: substituted silently.
_RESN_ALIASES = {
    'HSD': 'H', 'HSE': 'H', 'HSP': 'H',
    'HID': 'H', 'HIE': 'H', 'HIP': 'H',
    'CYX': 'C', 'CYM': 'C',
    'ASH': 'D', 'GLH': 'E', 'LYN': 'K',
}

#: Modified residues, mapped to the parent they are made from. Folding the parent is
#: the only thing any predictor here can do -- none of them model the modification --
#: and it is what every folding pipeline does with a PDB entry, so the alternative is
#: not a better prediction but no prediction at all: MSE alone (selenomethionine, a
#: phasing trick rather than biology) appears in a large share of crystal structures,
#: and oxidised cysteines and phospho-residues are common enough that refusing them
#: would make the object path fail on ordinary entries -- 1VJE, picked at random from
#: an MSE search, carries two CSD.
#:
#: Unlike the aliases above this DOES drop chemistry -- a phosphate, an acetyl -- so
#: every substitution is reported. Only unambiguous parents are listed: D-amino acids
#: and selenocysteine are deliberately absent, because there the parent is a guess.
_MODIFIED_TO_PARENT = {
    'MSE': 'M', 'FME': 'M',                                       # methionine
    'CSO': 'C', 'CSD': 'C', 'CSS': 'C', 'CSW': 'C', 'CSX': 'C',   # oxidised /
    'CME': 'C', 'OCS': 'C', 'SMC': 'C', 'YCM': 'C',               # alkylated cys
    'SEP': 'S', 'TPO': 'T', 'PTR': 'Y', 'TYS': 'Y',               # phospho / sulfo
    'MLY': 'K', 'MLZ': 'K', 'M3L': 'K', 'ALY': 'K',               # modified lysine
    'KCX': 'K', 'LLP': 'K',
    'HYP': 'P', 'PCA': 'E', 'CGU': 'E',
}


def _is_sequence_shaped(text):
    """True if `text` could be a bare one-letter sequence.

    Residue letters, the '/' chain separator, and the line breaks of a pasted FASTA
    block -- nothing else. A SPACE disqualifies it, deliberately: every multi-word
    selection ('chain A', 'polymer and 1ubq') carries one, so a mistyped selection that
    fails to resolve is reported as a bad selection instead of being quietly folded
    letter by letter -- 'chian A' is not the pentapeptide CHIANA.
    """
    return bool(text) and all(ch.isalpha() or ch in '/\r\n' for ch in text)


def chains_from_selection(selection, _self=cmd):
    """[(object, chain_id, sequence), ...] for the protein chains in `selection`.

    The provenance-carrying form of ``sequence_from_selection``, which is a join of
    the sequences. WHERE each chain came from is what lets `predict` find the
    alignments attached to it, and it cannot be recovered from the joined string.

    One entry per (object, chain id) in the order PyMOL iterates them, so predicting
    from a dimer folds A/B as a complex rather than as two independent monomers, and
    predicting from `objA or objB` builds the complex of the two.

    Only `polymer.protein` is read. Waters and ligands have no place in a protein-only
    prediction, and nucleic acids are excluded for a sharper reason: A, G, C and T are
    all valid residue letters, so a DNA chain would come back looking like a perfectly
    good protein sequence and be folded as one.

    Gaps are NOT filled: a chain with residues 1-10 and 21-30 yields the 20 OBSERVED
    residues as one continuous run, because that is the sequence PyMOL actually has.
    Pass the full sequence as a string to fold the missing loop.

    Modified residues are folded as the residue they are made from (MSE as M, SEP as
    S...) and reported; a residue with no unambiguous parent is refused.
    """
    import collections

    from .exporting import _resn_to_aa
    from .predictors.errors import PredictionInputError

    chains = collections.OrderedDict()
    # `guide & alt +A` is get_fastastr's reduction: one atom per residue (CA for
    # protein), first altloc only, so a disordered side chain cannot duplicate a residue.
    _self.iterate('(%s) & polymer.protein & guide & alt +A' % selection,
                  'chains.setdefault((model, chain), []).append(resn)',
                  space={'chains': chains})
    if not chains:
        raise PredictionInputError(
            '"%s" contains no protein residues to fold' % selection)

    sequences, unknown, substituted = [], [], {}
    for (model, chain_id), resn_list in chains.items():
        letters = []
        for resn in resn_list:
            aa = _resn_to_aa.get(resn) or _RESN_ALIASES.get(resn)
            if aa is None:
                aa = _MODIFIED_TO_PARENT.get(resn)
                if aa is not None:
                    substituted[resn] = substituted.get(resn, 0) + 1
            if aa is None:
                unknown.append(resn)
            else:
                letters.append(aa)
        sequences.append((model, chain_id, ''.join(letters)))
    if unknown:
        # Refused rather than skipped: dropping a residue would hand the predictor a
        # sequence one residue shorter than the structure it came from, spliced across
        # the hole, and nothing downstream could tell that had happened. For the same
        # reason the advice is NOT "exclude it from the selection" -- that produces
        # exactly the spliced sequence this is refusing to produce.
        raise PredictionInputError(
            '"%s" contains residues with no one-letter code: %s. Pass the sequence as'
            ' a string, or rename them to the residue they are made from'
            ' (alter <sel>, resn="CYS").'
            % (selection, ', '.join(sorted(set(unknown)))))
    if substituted:
        # Warned regardless of `quiet`: the sequence being folded no longer matches the
        # structure it came from, and a user comparing the two needs to know why.
        colorprinting.warning(
            ' predict: %s: %d modified residue(s) folded as the residue they are made'
            ' from (%s); the modification itself is not modelled.'
            % (selection, sum(substituted.values()),
               ', '.join('%d %s->%s' % (count, resn, _MODIFIED_TO_PARENT[resn])
                         for resn, count in sorted(substituted.items()))))
    return sequences


def sequence_from_selection(selection, _self=cmd):
    """One-letter sequence of the protein chains in `selection`, '/'-joined.

    See ``chains_from_selection`` for what is read and what is deliberately not.
    """
    return '/'.join(seq for _, _, seq in
                    chains_from_selection(selection, _self=_self))


def resolve_sequence(sequence, quiet=1, _self=cmd):
    """The one-letter sequence to fold, given a sequence, object or selection.

    ``resolve_input`` without the provenance. This is the whole of what most callers
    need, and it is what the tests pin.
    """
    return resolve_input(sequence, quiet=quiet, _self=_self)[0]


def resolve_input(sequence, quiet=1, _self=cmd):
    """(sequence, sources) for a sequence, object or selection.

    `sources` is one (object, chain id) per '/'-separated chain of the returned
    sequence, in the same order -- or an EMPTY list when the input was a literal
    sequence, which has no provenance to speak of. It is what lets `predict` find the
    alignments attached to the chains it is about to fold.

    Resolution order, and why:

    1. Anything that selects atoms is read from the session. An object name wins over
       a same-spelled sequence -- with an object called `AAA` loaded, `predict m, AAA`
       folds the object. Rename it if you meant the tripeptide.
    2. Otherwise, text that could be residues is taken literally, so a sequence still
       works with an empty session or alongside unrelated objects.
    3. Otherwise it was a selection that matched nothing, and that is an error -- NOT
       a sequence. Silently folding the letters of a typo'd selection is the one
       failure mode worth going out of the way to prevent.
    """
    from .predictors.errors import PredictionInputError

    if not isinstance(sequence, str):
        raise PredictionInputError('sequence must be a string')
    text = sequence.strip()
    if not text:
        raise PredictionInputError('no sequence, object or selection given')

    literal = _is_sequence_shaped(text)
    try:
        n_atoms = _self.count_atoms(text)
    except Exception:
        # Not parseable as a selection at all: a bare word that names no object comes
        # back as 'Invalid selection name "MKTAY"', which is exactly what a sequence
        # looks like to the selection parser. Fine if it could be residues; otherwise
        # the caller wrote a broken selection and deserves to hear about it.
        if literal:
            return text, []
        raise
    if n_atoms > 0:
        found = chains_from_selection(text, _self=_self)
        resolved = '/'.join(seq for _, _, seq in found)
        if not int(quiet):
            colorprinting.parrot(
                ' predict: %s -> %d residues in %d chain(s)'
                % (text, sum(len(seq) for _, _, seq in found), len(found)))
        return resolved, [(model, chain) for model, chain, _ in found]
    if literal:
        return text, []
    raise PredictionInputError(
        '"%s" selects no atoms and is not a one-letter sequence' % text)


# -- Alignments: from the command line, or from what is attached ---------------
#
# Two ways in, and they are not equivalent. `msa=` is positional per chain and says
# exactly which alignment goes where. Omitting it uses whatever is ATTACHED to the
# object each chain was read from -- which is not implicit magic, because attaching is
# a deliberate act (`load_msa ..., target=` or `msa_attach`), but it does mean the
# inputs of a run are not all visible in the command that started it. That is why
# `predict` reports what it used regardless of `quiet`.


def alignments_from_argument(msa, chains):
    """{chain id: MSA} from a `msa=` argument. One '/'-separated slot per chain.

    '/' rather than ',' for the same reason the sequence uses it: parsing.parse_arg
    splits the command line on commas, so a comma-separated list never arrives whole.

    An EMPTY slot means "no alignment for this chain", which is what makes the mixed
    case writable -- `msa=/barstar_aln` folds chain A single-sequence and chain B with
    an alignment. Trailing slots may simply be omitted.
    """
    from .msas import store
    from .msas.errors import MSAError
    from .predictors.errors import PredictionInputError

    slots = [part.strip() for part in str(msa).split('/')]
    if len(slots) > len(chains):
        raise PredictionInputError(
            'msa= has %d "/"-separated slots but there %s %d chain(s) to fold. Slots'
            ' are positional, one per chain; leave one empty to fold that chain'
            ' single-sequence.'
            % (len(slots), 'is' if len(chains) == 1 else 'are', len(chains)))
    out = {}
    for (chain_id, _sequence), stored_name in zip(chains, slots):
        if not stored_name:
            continue
        try:
            out[chain_id] = store.get(stored_name)
        except MSAError as exc:
            # Re-raised in predict's own taxonomy, naming the chain: with several slots
            # "no alignment named 'x'" does not say which one of them was wrong.
            raise PredictionInputError('msa= for chain %s: %s' % (chain_id, exc))
    return out


def alignments_from_attachments(sources, chains):
    """{chain id: MSA} for the chains whose source object/chain has one attached.

    `sources` is what resolve_input returns: empty for a literal sequence, which
    therefore never picks up an attachment -- there is no object to have attached one
    to. Matching is on the object NAME and chain id exactly as `msa_attach` recorded
    them, so an alignment attached through a multi-word selection does not match; pass
    it with `msa=` instead.
    """
    from .msas import store
    from .predictors.errors import PredictionInputError

    if not sources:
        return {}
    attached = {}
    for stored_name in store.names():
        msa = store.get(stored_name)
        if msa.target:
            attached.setdefault((msa.target, msa.chain), []).append(msa)
    out = {}
    for (chain_id, _sequence), source in zip(chains, sources):
        found = attached.get(source)
        if not found:
            continue
        if len(found) > 1:
            # Not resolved by picking one. Two alignments of the same chain are two
            # different searches, and silently folding with whichever loaded first
            # would make the result depend on load order rather than on the input.
            raise PredictionInputError(
                '%d alignments are attached to "%s" chain %s (%s); say which one to'
                ' use with msa='
                % (len(found), source[0], source[1] or '(blank)',
                   ', '.join(m.name for m in found)))
        out[chain_id] = found[0]
    return out


def report_alignments(spec, options):
    """Say what alignment each chain was folded with. NOT gated on `quiet`.

    Depth is the single largest determinant of both runtime and peak memory, and with
    the attachment path the alignment used need not appear in the command at all -- so
    a run whose inputs cannot be recovered from its own output is the default unless
    this is unconditional. The modified-residue substitution warning is unconditional
    for the same reason.

    Silent when nothing was folded with an alignment: every prediction was
    single-sequence before this existed, and a line saying so on every run is noise.
    """
    if not spec.alignments:
        return
    limit = getattr(options, 'msa_depth', None) or 0
    parts = []
    for chain_id, _sequence in spec.chains:
        msa = spec.alignments.get(chain_id)
        if msa is None:
            parts.append('%s single-sequence' % chain_id)
        elif limit and msa.depth > limit:
            parts.append('%s %s (%d of %d sequences, msa_depth)'
                         % (chain_id, msa.name, limit, msa.depth))
        else:
            parts.append('%s %s (%d sequences)' % (chain_id, msa.name, msa.depth))
    colorprinting.parrot(' predict: alignments: %s' % ', '.join(parts))


def predict(predictor, sequence, name='', recycling_steps=3, diffusion_steps=200,
            seed=None, n_models=1, diffusion_samples=None, msa='', msa_depth=None,
            quiet=1, _self=cmd):
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

    sequence = str: one-letter sequence, or the name of a loaded object, or an
    atom selection. Anything that selects atoms is read from the session -- one
    chain per (object, chain id), in the order they appear -- and everything else
    is taken as a literal sequence.

    In a literal sequence, use "/" to separate chains of a multimer -- NOT a
    comma, which the command parser treats as an argument separator. Chains are
    assigned ids A, B, C...

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
    same object. Each gets its own seed. Every model after the first is
    superposed on model 1 as it lands, because a backend returns each seed in its
    own arbitrary frame -- so the RMSD between two states is their conformational
    difference and nothing else. Model 1 never moves. For the canonical
    backbone-only superposition instead, redo it by hand with
    "intra_fit <name> and name CA, 1". {default: 1, maximum: 20}

    diffusion_samples = int: accepted only so that a predictor which does not
    plumb it can REJECT it by name instead of ignoring it. No shipped predictor
    supports it. {default: None, meaning "not requested"}

    msa = str: alignments to fold with, one "/"-separated slot per chain in the
    same order as the sequence. Each names an alignment loaded with "load_msa".
    An empty slot folds that chain single-sequence, which is how a designed
    binder is folded against an aligned target. {default: '', meaning "use
    whatever is attached"}

    msa_depth = int: use at most this many alignment rows, taken from the top --
    an a3m is in search-rank order, so this is "the best N", not a sample. It is
    the memory lever: MSA tensors are depth x residues. {default: 16384}

EXAMPLES

    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    predict boltz2, MKTAY/GSHMA, name=dimer, diffusion_steps=300
    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ, n_models=5

    fetch 1ubq
    predict boltz2, 1ubq                  # re-fold the whole object
    predict boltz2, 1ubq and chain A      # one chain of it
    predict boltz2, 1ubq and resi 1-40    # a fragment

    load_msa barnase.a3m, barnase_aln, 1brs, A
    predict boltz2, 1brs and chain A      # uses barnase_aln, because it is attached
    predict boltz2, MKTAY/GSHMA, msa=binder_aln/target_aln
    predict boltz2, MKTAY/GSHMA, msa=/target_aln     # chain A single-sequence

NOTES

    Defaults follow upstream Boltz. Options a predictor does not implement are
    rejected rather than ignored, so a typo cannot silently degrade a result.

    Reading from the session takes only protein residues -- waters, ligands and
    nucleic acids are skipped -- and does not fill gaps: unobserved residues are
    absent from the object, so they are absent from the sequence too. Pass the
    full sequence as a string to fold a missing loop.

    A modified residue is folded as the residue it is made from (MSE as M, SEP as
    S, ...), which is reported, because no predictor here models the modification.

    An object name wins over a same-spelled sequence: with an object called AAA
    loaded, "predict boltz2, AAA" folds the object, not the tripeptide.

    ALIGNMENTS ARE USED WITHOUT BEING NAMED HERE. With no "msa" argument, each
    chain read from the session is folded with whatever alignment is attached to
    that object and chain. Which alignment each chain used is therefore printed
    on every run, whatever "quiet" says. A method that cannot use an alignment
    refuses one by name rather than folding single-sequence and not saying so.

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

    # Resolved once, up front: everything downstream -- validation, the digest the
    # object name is built from, the spec the predictor gets -- must see the same
    # residues, and re-reading the session later could see a different one if the
    # user deleted or edited the source object in between.
    sequence, sources = resolve_input(sequence, quiet=quiet, _self=_self)
    spec = predictor_obj.parse_spec(sequence, name=name or (predictor + '_pred'))

    # Bound BEFORE the seed is drawn and before anything is submitted: a refused
    # alignment must cost nothing, and every one of these checks is one the backend
    # would otherwise make after a 505 MB weight download and minutes of featurization.
    alignments = (alignments_from_argument(msa, spec.chains) if msa
                  else alignments_from_attachments(sources, spec.chains))
    predictor_obj.bind_alignments(spec, alignments)

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
    if msa_depth is not None:
        # Only when asked for, so a predictor that cannot use an alignment rejects it
        # BY NAME rather than being handed a depth it has no use for. Passing it
        # unconditionally would make every predictor look as though it honoured one.
        requested['msa_depth'] = int(msa_depth)
    options = predictor_obj.validate_options(requested)
    report_alignments(spec, options)

    # Resolve the object name BEFORE submitting: the host needs it to load the result,
    # and the placeholder has to exist by the time this call returns so the panel shows
    # the job immediately rather than after the first poll.
    object_name = (str(name) if name else
                   default_object_name(sequence, predictor_obj.id))
    # Legalised HERE, once, rather than left for `create` to do silently: this string is
    # the placeholder's key, the name the host is handed and echoes back to
    # `deliver_result`, and what the metric run is filed against. Any of those differing
    # from the object that actually exists is a silent no-op somewhere downstream.
    object_name = _legal_object_name(object_name, _self=_self)
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
        # Stamped here rather than passed into submit(): the handle a predictor returns
        # is its own type, and the registry id is the one fact about the run that the
        # command layer knows and the transport does not (boltz2 and boltz2-bf16 share
        # one runtime). Metric recording reads it back off the handle.
        job.predictor_id = predictor_obj.id
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
    object_name = _legal_object_name(object_name, _self=_self)
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

    A bundle is fetched ONCE however many callers ask for it, so download=1 while a
    transfer is already in flight joins that transfer instead of starting a second
    one. It says so on the console and reports it as joined=True rather than looking
    like a call that did nothing.

RETURNS

    dict: predictor id -> {'cached', 'path', 'bundle', 'joined', 'fetch'}, where
    'fetch' is the live transfer's state (or None) and 'joined' says whether this
    call attached to a transfer that was already running.

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
        predictor_obj = registry.get(pid)
        bundle = predictor_obj.weight_bundle
        if bundle is None:
            out[pid] = {'cached': True, 'path': None, 'bundle': None,
                        'joined': False, 'fetch': None}
            continue
        # A BULK fetch downloads only what this build could actually run. Asking for one
        # predictor BY NAME still downloads it -- that is someone pre-warming a cache
        # deliberately, possibly for a build they do not have yet.
        #
        # Without this, "fetch everything" means every registered pack whether or not the
        # host carries its runtime: `protenix-base` alone is 214 MB that no shipping build
        # can use yet, pulled down by a command aimed at the predictors that do work.
        if int(download) and not predictor and not _can_run(predictor_obj):
            out[pid] = {'cached': bool(cache.is_cached(bundle)),
                        'path': cache.path_for(bundle),
                        'bundle': bundle.id,
                        'joined': False, 'fetch': None}
            if not int(quiet):
                colorprinting.parrot(
                    ' predict: %s cannot run in this build; not fetching its weights'
                    % pid)
            continue
        joined = False
        if int(download) and not cache.is_cached(bundle):
            # Identity, not a flag from start(): start() joins an in-flight transfer
            # on purpose (one bundle, one download, however many callers), and the
            # only way to tell "joined" from "began" is that it handed back the
            # record that was already there.
            before = fetching.get(bundle.id)
            started = fetching.start(bundle, cache)
            joined = started is before and before is not None
            if joined and started.state == 'running':
                snap = started.snapshot()
                # Warned regardless of `quiet`, for the same reason predict() warns
                # when it defers: this call deliberately started nothing, and saying
                # nothing about it is indistinguishable from "download=1 is broken".
                # That silence is what sent the reported bug looking for a .part file
                # that was never going to appear.
                colorprinting.warning(
                    ' predict: a fetch of %s weights is already in flight (%s %d%%);'
                    ' this call joined it rather than starting a second download.'
                    ' Stop it with "predict_weights_cancel %s".'
                    % (bundle.id, snap['phase'],
                       int(round(snap['fraction'] * 100)), pid))
            if wait:
                _wait_for_fetch(bundle, quiet)
        live = fetching.get(bundle.id)
        out[pid] = {'cached': bool(cache.is_cached(bundle)),
                    'path': cache.path_for(bundle),
                    'bundle': bundle.id,
                    # Whether this call joined a transfer already running rather than
                    # starting one, and what that transfer is doing. Reported in the
                    # return value as well as on the console so a script can tell a
                    # deliberate join from a failure instead of reading cached=False
                    # as "nothing happened".
                    'joined': joined,
                    'fetch': live.snapshot() if live is not None else None}
        if not int(quiet):
            colorprinting.parrot(' predict: %s weights cached=%s at %s' % (
                pid, out[pid]['cached'], out[pid]['path']))
    return out


def _can_run(predictor_obj):
    """True if this predictor could run here, for deciding whether to pre-fetch.

    Never raises: `check_available` is a predictor's own code, and a bulk pre-warm must
    not be derailed by one method's availability check. An error means "cannot say", and a
    bulk fetch treats that as "do not download" -- the cheap direction to be wrong in,
    since naming the predictor explicitly still fetches it.
    """
    try:
        predictor_obj.check_available()
    except Exception:
        return False
    return True


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


def predict_dismiss(name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_dismiss" clears the retained card for a prediction that failed or was
    cancelled. Success needs no dismissal -- the loaded object is its own
    confirmation and its card retires on its own.

USAGE

    predict_dismiss [ name ]

ARGUMENTS

    name = string: the object whose card to clear. Omit to clear every one.

SEE ALSO

    predict, predict_status, predict_cancel
    """
    pump(_self=_self)
    if name:
        removed = _RECENT.pop(_legal_object_name(name, _self=_self), None) is not None
    else:
        removed = bool(_RECENT)
        _RECENT.clear()
    if not int(quiet):
        if removed:
            colorprinting.parrot(' predict_dismiss: cleared %s'
                                 % (name or 'all cards',))
        else:
            colorprinting.warning(' predict_dismiss: nothing to clear')


def _job(job_id):
    from .predictors.errors import PredictionError
    try:
        return _JOBS[job_id]
    except KeyError:
        raise PredictionError('unknown prediction job %r' % job_id)
