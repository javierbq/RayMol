"""Glycan analysis commands for RayMol."""

from pymol import cmd

from .remediation import analyze_model, classify_residue
from .tree import build_glycan_forest, glyco_tree, write_glycan_tree


def glyco_remediate(selection="all", state=1):
    """Print a non-mutating JSON identity assessment for selected residues."""
    import json

    result = analyze_model(cmd.get_model(selection, state=int(state)))
    serialized = json.dumps(result, sort_keys=True)
    print(serialized)
    return serialized


cmd.extend("glyco_tree", glyco_tree)
cmd.extend("glyco_remediate", glyco_remediate)

__all__ = [
    "analyze_model",
    "build_glycan_forest",
    "classify_residue",
    "glyco_remediate",
    "glyco_tree",
    "write_glycan_tree",
]
