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


def predict(predictor, sequence, name='', recycling_steps=3, diffusion_steps=200,
            seed=0, diffusion_samples=None, quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict" folds one or more sequences with a registered structure predictor.
    It returns immediately with a job handle; poll it with "predict_status" and
    load the result with "predict_result".

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
    if predictor_obj.weight_bundle is not None:
        def report(phase, fraction):
            if not int(quiet):
                colorprinting.parrot(' predict: %s %d%%'
                                   % (phase, int(fraction * 100)))
        weights_path = weight_cache().ensure(predictor_obj.weight_bundle,
                                            progress=report)

    job = predictor_obj.submit(spec, options, weights_path)
    _JOBS[job.job_id] = job
    if not int(quiet):
        colorprinting.parrot(' predict: job %s submitted' % job.job_id)
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
