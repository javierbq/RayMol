"""Predictor registry: look a predictor up by id, swap implementations freely."""
from .base import Predictor
from .errors import PredictionError, PredictorNotFound

_REGISTRY = {}

#: Shorthand id -> real id, e.g. 'protenix' -> 'protenix-v2-int8'. Deliberately a
#: separate table rather than a second _REGISTRY entry: real ids must never share a
#: prefix (see protenix.py's _SUFFIX comment), and an alias resolved only by `get()` -
#: absent from `available()` - can't trip that invariant or show up in Tab-completion.
_ALIASES = {}


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


def register_alias(alias, target_id):
    """Make `alias` resolve to whatever is registered under `target_id`.

    Not validated against `target_id` existing yet: builtins register their packs
    before their aliases, but nothing requires that order.
    """
    _ALIASES[alias] = target_id


def get(predictor_id):
    """Return the predictor registered under `predictor_id`, resolving aliases first."""
    predictor_id = _ALIASES.get(predictor_id, predictor_id)
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
