"""Structure-prediction backend: predictor registry and model-weight cache.

Public API lives in pymol.predicting (cmd.predict and friends). This package holds
the plumbing and the predictor implementations. Adding a predictor means adding one
module here plus one line in _register_builtins().
"""
from . import errors  # noqa: F401
# TODO(Task 2): restore this re-export once predictors/registry.py exists.
# _register_builtins() below calls the bare name `register`, so this line must
# come back with registry.py.
# from .registry import register, get, available, unregister  # noqa: F401


def _register_builtins():
    """Register the shipped predictors. The only function that changes per predictor."""
    return
