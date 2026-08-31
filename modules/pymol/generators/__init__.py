"""Backbone generation: methods that produce a chain rather than folding one.

The sibling of `pymol.predictors`, and separate from it for the reason
`generators.base` gives at length: a predictor's input is chain sequences, a
generator's is a target structure. See docs/generators.md.
"""
from . import registry


def _register_builtins():
    """Register the generators that ship with RayMol. Idempotent."""
    from .rfd3 import RFD3Generator
    registry.register(RFD3Generator(), replace=True)


_register_builtins()
