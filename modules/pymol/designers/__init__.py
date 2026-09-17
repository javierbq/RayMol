"""Sequence design: a backbone in, sequences out (#453).

The third method family, beside `pymol.predictors` (sequences -> a structure) and
`pymol.generators` (a target -> a backbone). It closes flow 1 of the protein-CAD spec:
a campaign generates backbones, triages them, and hands the survivors here for the
sequences that are then folded back.

Separate from both for the reason `generators.base` gives at length about its own split:
the INPUT differs all the way down. A designer is handed backbone coordinates whose
identities are the thing being replaced, so it has neither a `PredictionSpec`'s chain
sequences nor a `DesignSpec`'s hotspots and length. See the "Sequence design" section
of docs/generators.md.
"""
from . import registry


def _register_builtins():
    """Register the sequence designers that ship with RayMol. Idempotent."""
    from .mpnn import MPNNDesigner
    registry.register(MPNNDesigner(), replace=True)


_register_builtins()
