"""Sequence-designer registry: look a designer up by id, swap implementations freely.

A THIRD registry, not a third table inside one of the other two, for the reason
`generators.registry` gives about its own split: an id namespace is a promise about what
its members can do. `predict <Tab>` must not offer a method that cannot fold a sequence,
and `design_sequences <Tab>` must not offer one that cannot read a backbone -- and
`registry.get()` is what each command resolves its first argument through, so a shared
table would have to answer "yes" to both questions for every entry.

Everything genuinely shared -- the file transport, the weight cache, the metric spec sets,
the set-delivery layer -- IS shared, by import.
"""
from .base import SequenceDesigner
from ..predictors.errors import PredictionError, PredictorNotFound

_REGISTRY = {}


def register(designer, replace=False):
    """Make `designer` discoverable under its id.

    Registering a duplicate id is an error unless replace=True, so a typo cannot
    silently shadow a shipped designer.
    """
    if not isinstance(designer, SequenceDesigner):
        raise PredictionError('not a SequenceDesigner: %r' % (type(designer).__name__,))
    if not designer.id or not isinstance(designer.id, str):
        raise PredictionError('sequence designer has no id: %r' % (designer,))
    if designer.id in _REGISTRY and not replace:
        raise PredictionError(
            'sequence designer %r is already registered; pass replace=True to override'
            % designer.id)
    _REGISTRY[designer.id] = designer
    # Declare what this method measures at the one moment it becomes reachable (#308),
    # as the other two registries do. Never fatal: a metric schema is bookkeeping, and a
    # method that can design must not become unusable because its declaration is
    # malformed.
    if designer.metric_specs:
        try:
            from pymol.metrics import schema
            schema.register(designer.id, designer.metric_specs, replace=True)
        except Exception as exc:
            print(' design: %s declared unusable metrics (%s)' % (designer.id, exc))
    return designer


def get(designer_id):
    """Return the sequence designer registered under `designer_id`."""
    try:
        return _REGISTRY[designer_id]
    except KeyError:
        raise PredictorNotFound(
            'unknown sequence designer %r; available: %s'
            % (designer_id, ', '.join(available()) or '(none)'))


def available():
    """Registered designer ids, sorted."""
    return sorted(_REGISTRY)


def unregister(designer_id):
    """Remove a designer. Missing ids are ignored."""
    _REGISTRY.pop(designer_id, None)
