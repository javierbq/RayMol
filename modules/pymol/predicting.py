"""Structure prediction: cmd.predict and friends.

Thin by design. Argument marshalling and session interaction only; the registry,
the weight cache, and the predictors themselves live in pymol.predictors.

Every function ends its signature with _self=cmd. That is load-bearing:
pymol2/cmd2.py binds _self only when it appears in the argspec, and otherwise
copies the function verbatim so it silently drives the GLOBAL instance.
"""
import sys

from . import colorprinting
from .predictors import registry
from .predictors.base import PredictionOptions  # noqa: F401  (re-export for callers)
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

#: Hex digits of the sequence digest used in a derived object name. Eight, not six:
#: six is 24 bits, and two DIFFERENT sequences colliding would silently merge into one
#: object, which is worse than a visible name clash. Widen, never narrow.
OBJECT_NAME_DIGEST_CHARS = 8

#: name -> job_id for placeholders whose job has not finished. Read by the object panel
#: (to disable the enable-toggle and show hover detail), by the session-save wrapper
#: (to keep placeholders out of a .pse), and by cleanup on failure/cancel/quit.
_PENDING = {}


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


def pending_objects():
    """Copy of the pending name -> job_id map."""
    return dict(_PENDING)


def pending_detail(name, _self=cmd):
    """One-line description of the job a placeholder is waiting on, or None.

    This is the string the object panel shows on hover, so it must stay short and must
    never raise: it is rendered from a 500 ms poll on the main thread.
    """
    job_id = _PENDING.get(name)
    if job_id is None:
        return None
    job = _JOBS.get(job_id)
    if job is None:
        return 'pending'
    try:
        status = job.status()
    except Exception:
        return 'pending'
    phase = status.get('phase') or status.get('state') or 'pending'
    fraction = status.get('fraction') or 0.0
    return 'pending: %s %d%%' % (phase, int(float(fraction) * 100))


def register_pending(name, job_id, _self=cmd):
    """Create the empty placeholder and remember what it is waiting for."""
    _self.create(name, 'none')
    _PENDING[name] = job_id


def discard_pending(name, _self=cmd):
    """Forget a placeholder, deleting the object only if it never received atoms.

    The atom check is the important part: cleanup can race a job that just finished, and
    deleting a completed structure would destroy the very thing the user asked for.
    """
    _PENDING.pop(name, None)
    try:
        if name in _self.get_names('objects') and _self.count_atoms(name) == 0:
            _self.delete(name)
    except Exception:
        pass


def clear_pending(_self=cmd):
    """Drop every placeholder. Used on quit and by tests."""
    for name in list(_PENDING):
        discard_pending(name, _self=_self)


def deliver_result(path, name, _self=cmd):
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
    finally:
        _PENDING.pop(name, None)


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
            seed=0, diffusion_samples=None, quiet=1, _self=cmd):
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

    seed = int: random seed {default: 0}

    diffusion_samples = int: accepted only so that a predictor which does not
    plumb it can REJECT it by name instead of ignoring it. No shipped predictor
    supports it. {default: None, meaning "not requested"}

EXAMPLES

    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    predict boltz2, MKTAY/GSHMA, name=dimer, diffusion_steps=300

NOTES

    Defaults follow upstream Boltz. Options a predictor does not implement are
    rejected rather than ignored, so a typo cannot silently degrade a result.

    THE FIRST CALL BLOCKS. Inference itself is asynchronous, but a predictor whose
    weights are not yet cached downloads them synchronously first -- for boltz2 that
    is a ~505 MiB download plus extraction, minutes on a slow link, and it runs on
    the calling thread. From the command line that is the main thread, so the window
    will not redraw until it finishes. Pre-warm the cache instead:

        predict_weights boltz2, download=1

    Subsequent calls hit the cache and return promptly.

SEE ALSO

    predict_status, predict_result, predict_cancel, predict_weights
    """
    predictor_obj = registry.get(predictor)
    predictor_obj.check_available()

    spec = predictor_obj.parse_spec(sequence, name=name or (predictor + '_pred'))
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

    weights_path = None
    bundle = predictor_obj.weight_bundle
    if bundle is not None:
        cache = weight_cache()
        # Warn regardless of `quiet`: this is the one blocking step in an otherwise
        # asynchronous API, and staying silent while the main thread stalls on a
        # half-gigabyte download looks like a hang rather than progress.
        if not cache.is_cached(bundle):
            colorprinting.warning(
                ' predict: fetching %s weights (%.0f MB) before the first run; this'
                ' blocks until complete. Pre-warm with "predict_weights %s, download=1".'
                % (predictor_obj.id, (bundle.size or 0) / 1e6, predictor_obj.id))

        def report(phase, fraction):
            if not int(quiet):
                colorprinting.parrot(' predict: %s %d%%'
                                   % (phase, int(fraction * 100)))
        weights_path = cache.ensure(bundle, progress=report)

    # Resolve the object name BEFORE submitting: the host needs it to load the result,
    # and the placeholder has to exist by the time this call returns so the panel shows
    # the job immediately rather than after the first poll.
    object_name = (str(name) if name else
                   default_object_name(sequence, predictor_obj.id))
    # PredictionSpec is a __slots__ class, not a namedtuple: assign, don't _replace.
    spec.name = object_name

    job = predictor_obj.submit(spec, options, weights_path)
    _JOBS[job.job_id] = job
    register_pending(object_name, job.job_id, _self=_self)
    if not int(quiet):
        colorprinting.parrot(' predict: job %s submitted, will load as %s'
                           % (job.job_id, object_name))
    return job


def predict_status(job_id='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_status" reports the state of one prediction job, or of all of them.

USAGE

    predict_status [ job_id ]

SEE ALSO

    predict
    """
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

SEE ALSO

    predict
    """
    _job(job_id).cancel()
    if not int(quiet):
        colorprinting.parrot(' predict: cancel requested for %s' % job_id)


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


def predict_weights(predictor='', download=0, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_weights" reports -- and optionally pre-fetches -- each predictor's
    cached model weights.

USAGE

    predict_weights [ predictor [, download ]]

SEE ALSO

    predict
    """
    cache = weight_cache()
    ids = [predictor] if predictor else registry.available()
    out = {}
    for pid in ids:
        bundle = registry.get(pid).weight_bundle
        if bundle is None:
            out[pid] = {'cached': True, 'path': None, 'bundle': None}
            continue
        if int(download) and not cache.is_cached(bundle):
            cache.ensure(bundle)
        out[pid] = {'cached': bool(cache.is_cached(bundle)),
                    'path': cache.path_for(bundle),
                    'bundle': bundle.id}
        if not int(quiet):
            colorprinting.parrot(' predict: %s weights cached=%s at %s' % (
                pid, out[pid]['cached'], out[pid]['path']))
    return out


def _job(job_id):
    from .predictors.errors import PredictionError
    try:
        return _JOBS[job_id]
    except KeyError:
        raise PredictionError('unknown prediction job %r' % job_id)
