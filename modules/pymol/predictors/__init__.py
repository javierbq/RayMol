"""Structure-prediction backend: predictor registry and model-weight cache.

Public API lives in pymol.predicting (cmd.predict and friends). This package holds
the plumbing and the predictor implementations. Adding a predictor means adding one
module here plus one line in _register_builtins().
"""
from . import errors  # noqa: F401
from .registry import register, get, available, unregister  # noqa: F401


def _register_builtins():
    """Register the shipped predictors. The only function that changes per predictor."""
    from .boltz2 import Boltz2Predictor
    register(Boltz2Predictor(), replace=True)


_register_builtins()
