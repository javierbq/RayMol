"""Structure-prediction backend: predictor registry and model-weight cache.

Public API lives in pymol.predicting (cmd.predict and friends). This package holds
the plumbing and the predictor implementations. Adding a predictor means adding one
module here plus one line in _register_builtins().
"""
from . import errors  # noqa: F401
from .registry import register, get, available, unregister, register_alias  # noqa: F401


def _register_builtins():
    """Register the shipped predictors. The only function that changes per predictor."""
    from .boltz2 import Boltz2Predictor
    from .boltz2_bf16 import Boltz2BF16Predictor
    from .protenix import PREDICTORS as PROTENIX_PREDICTORS, ALIASES as PROTENIX_ALIASES
    register(Boltz2Predictor(), replace=True)
    register(Boltz2BF16Predictor(), replace=True)
    # One id per published pack -- six of them, variant x precision. A loop rather than
    # six lines because they differ only in which pack they name, and the list is
    # generated from the digests protenix-mlx publishes; see protenix.py.
    for predictor in PROTENIX_PREDICTORS:
        register(predictor(), replace=True)
    for alias, target_id in PROTENIX_ALIASES.items():
        register_alias(alias, target_id)


_register_builtins()
