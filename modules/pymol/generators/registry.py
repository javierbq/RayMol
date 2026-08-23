"""Generator registry: look a generator up by id, swap implementations freely.

A SEPARATE registry from `predictors.registry`, not a second table inside it. Two
reasons, both about what a shared registry would silently allow:

* `registry.available()` is what Tab-completion for `predict` offers and what a bulk
  `predict_weights download=1` walks. A generator listed there is a method `predict`
  cannot run, offered at the prompt of the command that cannot run it.
* `registry.get()` is how `predict` resolves its first argument. A generator reachable
  from it would be handed a sequence and asked for a `PredictionSpec`, and the only
  correct implementation of that is to raise -- so the shared table's contract would be
  "every entry folds a sequence, except the ones that do not".

Everything genuinely shared -- the weight cache, the fetcher, the file transport, the
metric spec sets -- IS shared, by import. It is only the id namespace that is separate,
because an id namespace is a promise about what its members can do.
"""
from .base import Generator
from ..predictors.errors import PredictionError, PredictorNotFound

_REGISTRY = {}


def register(generator, replace=False):
    """Make `generator` discoverable under its id.

    Registering a duplicate id is an error unless replace=True, so a typo cannot
    silently shadow a shipped generator.
    """
    if not isinstance(generator, Generator):
        raise PredictionError('not a Generator: %r' % (type(generator).__name__,))
    if not generator.id or not isinstance(generator.id, str):
        raise PredictionError('generator has no id: %r' % (generator,))
    if generator.id in _REGISTRY and not replace:
        raise PredictionError(
            'generator %r is already registered; pass replace=True to override'
            % generator.id)
    _REGISTRY[generator.id] = generator
    # Declare what this method measures, at the one moment the method becomes reachable
    # (#308). `replace=True` because re-registering a generator is legal here and its
    # schema must follow it rather than raise on the second pass. Never fatal: a metric
    # schema is bookkeeping, and a method that can generate must not become unusable
    # because its declaration is malformed.
    if generator.metric_specs:
        try:
            from pymol.metrics import schema
            schema.register(generator.id, generator.metric_specs, replace=True)
        except Exception as exc:
            print(' design: %s declared unusable metrics (%s)' % (generator.id, exc))
    return generator


def get(generator_id):
    """Return the generator registered under `generator_id`."""
    try:
        return _REGISTRY[generator_id]
    except KeyError:
        raise PredictorNotFound(
            'unknown generator %r; available: %s'
            % (generator_id, ', '.join(available()) or '(none)'))


def available():
    """Registered generator ids, sorted."""
    return sorted(_REGISTRY)


def unregister(generator_id):
    """Remove a generator. Missing ids are ignored."""
    _REGISTRY.pop(generator_id, None)
