"""Build bond-derived glycan forests suitable for JSON and SwiftUI."""

from __future__ import annotations

import json

from pymol import cmd
from pymol.raymol_glycan import SNFG_CATALOG, _prefer_atom

from .linkages import _key_id, describe_linkage
from .puckering import cremer_pople_six
from .remediation import classify_residue


def _model_data(model):
    atom_keys = {}
    residue_atoms = {}
    atoms_by_name = {}
    for atom_index, atom in enumerate(model.atom):
        resn = atom.resn.strip().upper()
        key = (atom.model, atom.segi, atom.chain, atom.resi, resn)
        atom_keys[atom_index] = key
        residue_atoms.setdefault(key, []).append(atom)
        named = atoms_by_name.setdefault(key, {})
        current = named.get(atom.name)
        named[atom.name] = atom if current is None else _prefer_atom(atom, current)
    return atom_keys, residue_atoms, atoms_by_name


def _node_payload(key, atoms, named_atoms):
    assessment = classify_residue(key[4], (atom.name for atom in atoms))
    specification = SNFG_CATALOG[key[4]]
    ring = [named_atoms.get(name) for name in specification["ring"]]
    puckering = None if any(atom is None for atom in ring) else cremer_pople_six(
        [atom.coord for atom in ring]
    )
    return {
        "id": _key_id(key),
        "object": key[0],
        "segi": key[1],
        "chain": key[2],
        "resi": key[3],
        "resn": key[4],
        "snfg": assessment,
        "puckering": puckering,
        "children": [],
    }


def build_glycan_forest(model):
    """Return recognized glycan components oriented from their attachment root."""
    atom_keys, residue_atoms, atoms_by_name = _model_data(model)
    glycan_keys = {key for key in residue_atoms if key[4] in SNFG_CATALOG}
    adjacency = {key: set() for key in glycan_keys}
    attachments = set()
    linkage_by_pair = {}

    for bond in model.bond:
        first_index, second_index = bond.index
        first_key, second_key = atom_keys.get(first_index), atom_keys.get(second_index)
        if first_key is None or second_key is None or first_key == second_key:
            continue
        first_glycan, second_glycan = first_key in glycan_keys, second_key in glycan_keys
        if first_glycan and second_glycan:
            adjacency[first_key].add(second_key)
            adjacency[second_key].add(first_key)
            pair = frozenset((first_key, second_key))
            if pair not in linkage_by_pair:
                linkage_by_pair[pair] = describe_linkage(
                    first_key, second_key, model.atom[first_index], model.atom[second_index],
                    residue_atoms,
                )
        elif first_glycan:
            attachments.add(first_key)
        elif second_glycan:
            attachments.add(second_key)

    seen = set()
    roots = []
    for component_start in sorted(glycan_keys):
        if component_start in seen:
            continue
        component = set()
        pending = [component_start]
        while pending:
            key = pending.pop()
            if key in component:
                continue
            component.add(key)
            pending.extend(adjacency[key] - component)
        seen.update(component)
        root_key = min(component & attachments) if component & attachments else min(component)

        emitted = set()

        def build_node(key, parent=None):
            emitted.add(key)
            node = _node_payload(key, residue_atoms[key], atoms_by_name[key])
            for child_key in sorted(adjacency[key]):
                if child_key == parent or child_key in emitted:
                    continue
                child = build_node(child_key, key)
                child["linkage"] = linkage_by_pair.get(frozenset((key, child_key)))
                node["children"].append(child)
            return node

        roots.append(build_node(root_key))

    return {
        "schema": 1,
        "roots": roots,
        "residueCount": len(glycan_keys),
        "componentCount": len(roots),
        "notice": "Identity, puckering, and torsion assessments are advisory.",
    }


def glyco_tree(selection="all", state=1):
    """Return and print a JSON glycan forest for a PyMOL selection."""
    payload = build_glycan_forest(cmd.get_model(selection, state=int(state)))
    serialized = json.dumps(payload, sort_keys=True)
    print(serialized)
    return serialized


def write_glycan_tree(path, selection="all", state=1):
    """Write the glycan forest to *path* for native UI bridges."""
    payload = build_glycan_forest(cmd.get_model(selection, state=int(state)))
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    return payload
