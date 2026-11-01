"""Covalent glycan linkage extraction and torsion measurement."""

from __future__ import annotations

from ._geometry import dihedral


def _atom_by_name(atoms, name):
    candidates = [atom for atom in atoms if atom.name.strip().upper() == name]
    return max(candidates, key=lambda atom: ((atom.alt or "") == "", atom.q), default=None)


def _angle(*atoms):
    if any(atom is None for atom in atoms):
        return None
    value = dihedral(*(atom.coord for atom in atoms))
    return None if value is None else round(value, 1)


def describe_linkage(first_key, second_key, first_atom, second_atom, residue_atoms):
    """Describe one inter-residue bond, orienting anomeric carbon to oxygen."""
    first_name = first_atom.name.strip().upper()
    second_name = second_atom.name.strip().upper()
    if first_name in {"C1", "C2"} and second_name.startswith("O"):
        donor_key, acceptor_key = first_key, second_key
        anomeric, oxygen = first_atom, second_atom
    elif second_name in {"C1", "C2"} and first_name.startswith("O"):
        donor_key, acceptor_key = second_key, first_key
        anomeric, oxygen = second_atom, first_atom
    else:
        donor_key, acceptor_key = first_key, second_key
        anomeric, oxygen = first_atom, second_atom

    donor_atoms = residue_atoms[donor_key]
    acceptor_atoms = residue_atoms[acceptor_key]
    donor_ring_oxygen = _atom_by_name(donor_atoms, "O5")
    if donor_ring_oxygen is None:
        donor_ring_oxygen = _atom_by_name(donor_atoms, "O6")
    position = oxygen.name.strip().upper()[1:] if oxygen.name.strip().upper().startswith("O") else "?"
    acceptor_carbon = _atom_by_name(acceptor_atoms, f"C{position}")
    previous_carbon = None
    if position.isdigit() and int(position) > 1:
        previous_carbon = _atom_by_name(acceptor_atoms, f"C{int(position) - 1}")

    phi = _angle(donor_ring_oxygen, anomeric, oxygen, acceptor_carbon)
    psi = _angle(anomeric, oxygen, acceptor_carbon, previous_carbon)
    omega = None
    if position == "6":
        omega = _angle(oxygen, acceptor_carbon,
                       _atom_by_name(acceptor_atoms, "C5"),
                       _atom_by_name(acceptor_atoms, "C4"))
    return {
        "donor": _key_id(donor_key),
        "acceptor": _key_id(acceptor_key),
        "bond": f"{anomeric.name.strip()}-{oxygen.name.strip()}",
        "phi": phi,
        "psi": psi,
        "omega": omega,
        "status": "measured" if phi is not None or psi is not None else "insufficient atoms",
        "advisory": True,
    }


def _key_id(key):
    return "|".join(str(value) for value in key)
