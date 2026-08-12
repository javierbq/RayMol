"""SNFG glycan colors and Metal-rendered CGO cartoons for RayMol."""

from __future__ import annotations

import hashlib
import math

from pymol import cgo, cmd


def _rgb(red: int, green: int, blue: int) -> tuple[float, float, float]:
    """Convert the official 8-bit SNFG palette to PyMOL RGB floats."""
    return red / 255.0, green / 255.0, blue / 255.0


BLUE = _rgb(0, 114, 188)
GREEN = _rgb(0, 166, 81)
YELLOW = _rgb(255, 212, 0)
PURPLE = _rgb(165, 67, 153)
LIGHT_BLUE = _rgb(143, 204, 233)
RED = _rgb(237, 28, 36)


# Curated common mammalian monosaccharides for the first release. ``ring`` is
# deliberately ordered: it drives both the centroid and a stable ring normal.
SNFG_CATALOG = {
    "NAG": {"shape": "cube", "color": BLUE, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "NDG": {"shape": "cube", "color": BLUE, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "A2G": {"shape": "cube", "color": YELLOW, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "NGA": {"shape": "cube", "color": YELLOW, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "BM3": {"shape": "cube", "color": GREEN, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "MAN": {"shape": "sphere", "color": GREEN, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "BMA": {"shape": "sphere", "color": GREEN, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "GAL": {"shape": "sphere", "color": YELLOW, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "GLA": {"shape": "sphere", "color": YELLOW, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "GLC": {"shape": "sphere", "color": BLUE, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "BGC": {"shape": "sphere", "color": BLUE, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "FUC": {"shape": "cone", "color": RED, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "FUL": {"shape": "cone", "color": RED, "ring": ("C1", "C2", "C3", "C4", "C5", "O5")},
    "SIA": {"shape": "diamond", "color": PURPLE, "ring": ("C2", "C3", "C4", "C5", "C6", "O6")},
    "SLB": {"shape": "diamond", "color": PURPLE, "ring": ("C2", "C3", "C4", "C5", "C6", "O6")},
    "NGC": {"shape": "diamond", "color": LIGHT_BLUE, "ring": ("C2", "C3", "C4", "C5", "C6", "O6")},
}


def _norm(vector):
    magnitude = math.sqrt(sum(component * component for component in vector))
    if magnitude <= 1e-6:
        return [0.0, 0.0, 1.0]
    return [component / magnitude for component in vector]


def _cross(left, right):
    return [
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
    ]


def _get_deterministic_cgo_name(selection: str) -> str:
    digest = hashlib.sha256(selection.encode("utf-8")).hexdigest()[:12]
    return f"cgo_glyco_{digest}"


def _triangle(obj, normal, vertices):
    obj.extend([cgo.NORMAL, *normal])
    for vertex in vertices:
        obj.extend([cgo.VERTEX, *vertex])


def build_cube_cgo(center, size, color):
    cx, cy, cz = center
    radius = size / 2.0
    vertices = [
        [cx - radius, cy - radius, cz - radius],
        [cx + radius, cy - radius, cz - radius],
        [cx + radius, cy + radius, cz - radius],
        [cx - radius, cy + radius, cz - radius],
        [cx - radius, cy - radius, cz + radius],
        [cx + radius, cy - radius, cz + radius],
        [cx + radius, cy + radius, cz + radius],
        [cx - radius, cy + radius, cz + radius],
    ]
    faces = [
        ([0.0, 0.0, -1.0], (0, 2, 1), (0, 3, 2)),
        ([0.0, 0.0, 1.0], (4, 5, 6), (4, 6, 7)),
        ([0.0, -1.0, 0.0], (0, 1, 5), (0, 5, 4)),
        ([0.0, 1.0, 0.0], (2, 3, 7), (2, 7, 6)),
        ([-1.0, 0.0, 0.0], (0, 4, 7), (0, 7, 3)),
        ([1.0, 0.0, 0.0], (1, 2, 6), (1, 6, 5)),
    ]
    obj = [cgo.BEGIN, cgo.TRIANGLES, cgo.COLOR, *color]
    for normal, first, second in faces:
        _triangle(obj, normal, [vertices[index] for index in first])
        _triangle(obj, normal, [vertices[index] for index in second])
    obj.append(cgo.END)
    return obj


def build_diamond_cgo(center, size, color):
    cx, cy, cz = center
    radius = size * 0.7
    top = [cx, cy, cz + radius]
    bottom = [cx, cy, cz - radius]
    middle = [
        [cx + radius, cy, cz],
        [cx, cy + radius, cz],
        [cx - radius, cy, cz],
        [cx, cy - radius, cz],
    ]
    obj = [cgo.BEGIN, cgo.TRIANGLES, cgo.COLOR, *color]
    for index in range(4):
        following = (index + 1) % 4
        upper = [top, middle[index], middle[following]]
        upper_u = [upper[1][axis] - upper[0][axis] for axis in range(3)]
        upper_v = [upper[2][axis] - upper[0][axis] for axis in range(3)]
        _triangle(obj, _norm(_cross(upper_u, upper_v)), upper)

        lower = [bottom, middle[following], middle[index]]
        lower_u = [lower[1][axis] - lower[0][axis] for axis in range(3)]
        lower_v = [lower[2][axis] - lower[0][axis] for axis in range(3)]
        _triangle(obj, _norm(_cross(lower_u, lower_v)), lower)
    obj.append(cgo.END)
    return obj


def build_cone_cgo(center, normal, size, color):
    cx, cy, cz = center
    nx, ny, nz = _norm(normal)
    height = size * 1.2
    radius = size * 0.55
    base = [cx - nx * height / 2.0, cy - ny * height / 2.0, cz - nz * height / 2.0]
    tip = [cx + nx * height / 2.0, cy + ny * height / 2.0, cz + nz * height / 2.0]
    return [
        cgo.CONE,
        *base,
        *tip,
        radius,
        0.0,
        *color,
        *color,
        1.0,
        1.0,
    ]


def glycocolor(selection="all"):
    """Apply official SNFG colors without changing representation visibility."""
    applied = 0
    for residue_name, specification in SNFG_CATALOG.items():
        target = f"({selection}) and resn {residue_name}"
        if cmd.count_atoms(target):
            color_name = f"snfg_{residue_name.lower()}"
            cmd.set_color(color_name, specification["color"])
            cmd.color(color_name, target)
            applied += 1
    print(f" GlycoColor: colored {applied} residue types")
    return applied


def _prefer_atom(candidate, current):
    """Choose one conformer deterministically, preferring blank altlocs."""
    candidate_alt = candidate.alt or ""
    current_alt = current.alt or ""
    candidate_rank = (candidate_alt == "", candidate.q, candidate_alt)
    current_rank = (current_alt == "", current.q, current_alt)
    return candidate if candidate_rank > current_rank else current


def _build_glycocartoon_cgo(model, size=2.5, draw_linkers=1):
    """Build CGO data and residue centroids from a ChemPy indexed model."""
    size = float(size)
    if size <= 0.0:
        raise ValueError("size must be greater than zero")
    draw_linkers = int(draw_linkers)

    atom_to_residue = {}
    residue_atoms = {}
    for atom_index, atom in enumerate(model.atom):
        residue_name = atom.resn.strip().upper()
        if residue_name not in SNFG_CATALOG:
            continue
        residue_key = (atom.model, atom.segi, atom.chain, atom.resi, residue_name)
        atom_to_residue[atom_index] = residue_key
        atoms_by_name = residue_atoms.setdefault(residue_key, {})
        current = atoms_by_name.get(atom.name)
        atoms_by_name[atom.name] = atom if current is None else _prefer_atom(atom, current)

    cgo_data = []
    centroids = {}
    for residue_key in sorted(residue_atoms):
        atoms_by_name = residue_atoms[residue_key]
        specification = SNFG_CATALOG[residue_key[4]]
        ring_names = specification["ring"]
        if any(name not in atoms_by_name for name in ring_names):
            continue

        ring_coordinates = [atoms_by_name[name].coord for name in ring_names]
        centroid = [
            sum(coordinate[axis] for coordinate in ring_coordinates) / len(ring_coordinates)
            for axis in range(3)
        ]
        first = [ring_coordinates[2][axis] - ring_coordinates[0][axis] for axis in range(3)]
        second = [ring_coordinates[4][axis] - ring_coordinates[0][axis] for axis in range(3)]
        normal = _norm(_cross(first, second))
        centroids[residue_key] = centroid

        shape = specification["shape"]
        color = specification["color"]
        if shape == "sphere":
            cgo_data.extend([cgo.COLOR, *color, cgo.SPHERE, *centroid, size * 0.5])
        elif shape == "cube":
            cgo_data.extend(build_cube_cgo(centroid, size, color))
        elif shape == "diamond":
            cgo_data.extend(build_diamond_cgo(centroid, size, color))
        elif shape == "cone":
            cgo_data.extend(build_cone_cgo(centroid, normal, size, color))

    if draw_linkers and len(centroids) > 1:
        linked_residues = set()
        for bond in model.bond:
            first_residue = atom_to_residue.get(bond.index[0])
            second_residue = atom_to_residue.get(bond.index[1])
            if not first_residue or not second_residue or first_residue == second_residue:
                continue
            pair = tuple(sorted((first_residue, second_residue)))
            if pair in linked_residues or any(key not in centroids for key in pair):
                continue
            first_center, second_center = (centroids[key] for key in pair)
            cgo_data.extend([
                cgo.CYLINDER,
                *first_center,
                *second_center,
                0.35,
                0.7,
                0.7,
                0.7,
                0.7,
                0.7,
                0.7,
            ])
            linked_residues.add(pair)

    return cgo_data, centroids


def glycocartoon(selection="all", size=2.5, draw_linkers=1, state=1):
    """Render SNFG CGO shapes for recognized glycans in ``selection``."""
    size = float(size)
    draw_linkers = int(draw_linkers)
    state = int(state)
    object_name = _get_deterministic_cgo_name(selection)
    if object_name in cmd.get_names("objects"):
        cmd.delete(object_name)

    model = cmd.get_model(selection, state=state)
    cgo_data, centroids = _build_glycocartoon_cgo(model, size, draw_linkers)
    if cgo_data:
        cmd.load_cgo(cgo_data, object_name, state=state)
    else:
        print(f" GlycoCartoon: no supported complete sugar rings in '{selection}'")
    return len(centroids)


def glycocartoon_hide(selection="all"):
    """Delete only the glycan cartoon generated for ``selection``."""
    object_name = _get_deterministic_cgo_name(selection)
    if object_name in cmd.get_names("objects"):
        cmd.delete(object_name)


def glycocartoon_hide_all():
    """Delete every CGO object generated by :func:`glycocartoon`."""
    for object_name in cmd.get_names("objects"):
        if object_name.startswith("cgo_glyco_"):
            cmd.delete(object_name)


cmd.extend("glycocolor", glycocolor)
cmd.extend("glycocartoon", glycocartoon)
cmd.extend("glycocartoon_hide", glycocartoon_hide)
cmd.extend("glycocartoon_hide_all", glycocartoon_hide_all)
