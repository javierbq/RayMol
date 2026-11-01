"""Conservative, non-mutating glycan identity checks.

This module deliberately reports evidence instead of rewriting residue names.
Coordinates alone are insufficient to assign a definitive monosaccharide in
many real-world structures.
"""

from __future__ import annotations

from pymol.raymol_glycan import SNFG_CATALOG


def _hex_color(rgb):
    return "#" + "".join(f"{round(channel * 255):02X}" for channel in rgb)


def classify_residue(residue_name, atom_names=()):
    """Return a JSON-safe identity assessment without modifying the model."""
    residue_name = (residue_name or "").strip().upper()
    specification = SNFG_CATALOG.get(residue_name)
    if specification:
        return {
            "recognized": True,
            "resn": residue_name,
            "symbol": specification["symbol"],
            "shape": specification["shape"],
            "color": _hex_color(specification["color"]),
            "confidence": "catalog",
            "reason": "Known PDB chemical-component code in RayMol's SNFG catalog.",
        }

    names = {name.strip().upper() for name in atom_names}
    if {"C1", "C2", "C3", "C4", "C5", "O5"}.issubset(names):
        family = "six-membered aldose-like ring"
    elif {"C2", "C3", "C4", "C5", "C6", "O6"}.issubset(names):
        family = "six-membered nonulosonate-like ring"
    else:
        family = None
    return {
        "recognized": False,
        "resn": residue_name,
        "symbol": residue_name or "Unknown",
        "shape": "unknown",
        "color": "#8E8E93",
        "confidence": "advisory" if family else "insufficient",
        "reason": (f"Atom names suggest a {family}; stereochemistry must be verified."
                   if family else "Not enough evidence for an SNFG assignment."),
    }


def analyze_model(model):
    residues = {}
    for atom in model.atom:
        key = (atom.model, atom.segi, atom.chain, atom.resi, atom.resn.strip().upper())
        residues.setdefault(key, set()).add(atom.name)
    return [
        {"object": key[0], "segi": key[1], "chain": key[2], "resi": key[3],
         **classify_residue(key[4], names)}
        for key, names in sorted(residues.items())
    ]
