"""Predictor registry: look a predictor up by id, swap implementations freely."""
from .base import Predictor
from .errors import PredictionError, PredictorNotFound

_REGISTRY = {}


def register(predictor, replace=False):
    """Make `predictor` discoverable under its id.

    Registering a duplicate id is an error unless replace=True, so that a typo
    cannot silently shadow a shipped predictor.
    """
    if not isinstance(predictor, Predictor):
        raise PredictionError(
            'not a Predictor: %r' % (type(predictor).__name__,))
    if not predictor.id or not isinstance(predictor.id, str):
        raise PredictionError('predictor has no id: %r' % (predictor,))
    if predictor.id in _REGISTRY and not replace:
        raise PredictionError(
            'predictor %r is already registered; pass replace=True to override'
            % predictor.id)
    _REGISTRY[predictor.id] = predictor
    # Declare what this method measures, at the one moment the method becomes
    # reachable (#308). `replace=True` because re-registering a predictor is legal
    # here and its schema must follow it rather than raise on the second pass.
    # Never fatal: a metric schema is bookkeeping, and a predictor that can fold must
    # not become unusable because its declaration is malformed.
    if predictor.metric_specs:
        try:
            from pymol.metrics import schema
            schema.register(predictor.id, predictor.metric_specs, replace=True)
        except Exception as exc:
            print(' predict: %s declared unusable metrics (%s)' % (predictor.id, exc))
    return predictor


def get(predictor_id):
    """Return the predictor registered under `predictor_id`."""
    try:
        return _REGISTRY[predictor_id]
    except KeyError:
        raise PredictorNotFound(
            'unknown predictor %r; available: %s'
            % (predictor_id, ', '.join(available()) or '(none)'))


def available():
    """Registered predictor ids, sorted."""
    return sorted(_REGISTRY)


def unregister(predictor_id):
    """Remove a predictor. Missing ids are ignored."""
    _REGISTRY.pop(predictor_id, None)
