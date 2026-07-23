"""RayMol Design-mode core helpers: residue enumeration, coloring, and
exact visual-state save/restore. Mirrors the appkit_sequence bundled-module
pattern (writes JSON to TMPDIR, returns a short marker)."""
import json
import os
import tempfile

from pymol import cmd

# 3-letter -> MPNN alphabet index ("ACDEFGHIKLMNPQRSTVWYX", X=20).
_ONE = {'ALA': 'A', 'ARG': 'R', 'ASN': 'N', 'ASP': 'D', 'CYS': 'C', 'GLN': 'Q', 'GLU': 'E',
        'GLY': 'G', 'HIS': 'H', 'ILE': 'I', 'LEU': 'L', 'LYS': 'K', 'MET': 'M', 'PHE': 'F',
        'PRO': 'P', 'SER': 'S', 'THR': 'T', 'TRP': 'W', 'TYR': 'Y', 'VAL': 'V'}
_ALPHABET = "ACDEFGHIKLMNPQRSTVWYX"
_AA_INDEX = {c: i for i, c in enumerate(_ALPHABET)}


def _tmp(name):
    return os.path.join(tempfile.gettempdir(), name)


def enumerate_design_residues(obj, state):
    state = int(state)
    # Guide atoms give one row per residue in canonical (chain, resv, inscode) order.
    order = []
    cmd.iterate('(%s) and polymer and guide' % obj,
                'order.append((chain, resi, resn))', space={'order': order})
    # Backbone atom coords for the same residues.
    atoms = {}

    def _collect(chain, resi, name, x, y, z):
        atoms.setdefault((chain, resi), {})[name] = (x, y, z)

    cmd.iterate_state(state, '(%s) and polymer and name N+CA+C+O' % obj,
                      '_collect(chain, resi, name, x, y, z)',
                      space={'_collect': _collect})
    residues = []
    for (chain, resi, resn) in order:
        bb = atoms.get((chain, resi), {})
        valid = all(k in bb for k in ('N', 'CA', 'C', 'O'))
        aa = _AA_INDEX.get(_ONE.get(resn, 'X'), 20)
        residues.append({
            'chain': chain, 'resi': resi, 'resn': resn, 'aa': aa, 'valid': valid,
            'n':  list(bb['N'])  if 'N'  in bb else None,
            'ca': list(bb['CA']) if 'CA' in bb else None,
            'c':  list(bb['C'])  if 'C'  in bb else None,
            'o':  list(bb['O'])  if 'O'  in bb else None,
        })
    with open(_tmp('raymol_design_residues.json'), 'w') as f:
        json.dump({'object': obj, 'state': state, 'residues': residues}, f)
    return 'DESIGN_RESIDUES:ready'


def apply_design_coloring(obj, values_json_path, palette, lo, hi):
    """Write per-residue scalar and apply spectrum coloring.

    values_json_path: path to JSON list of {'chain', 'resi', 'value'} dicts.
    palette: PyMOL palette name (e.g. 'blue_white_red').
    lo, hi: domain min/max used by the Swift legend; passed to spectrum when
            minimum/maximum kwargs are supported, otherwise auto-scaling is used.
    Returns 'DESIGN_COLOR:ok'.

    Storage: Incentive PyMOL stores values in the custom atom property
    p.mpnn_conf; Open-Source PyMOL falls back to the B-factor column (b).
    Spectrum is run only over scored polymer residues — masked residues and
    non-polymer atoms (ligands, ions, waters) keep their baseline color.
    """
    # -- Fix 1: Un-dim -- reset this object's transparency settings back to the
    # snapshot baseline so a previously-dimmed object is fully visible when it
    # becomes the focus.  If the snapshot is absent (e.g. loaded mid-mode) or
    # the object is not recorded in it, skip gracefully.
    snap_path = _tmp('raymol_design_snapshot.json')
    if os.path.exists(snap_path):
        try:
            with open(snap_path) as _snap_f:
                snap = json.load(_snap_f)
            baseline = snap.get('settings', {}).get(obj)
            if baseline:
                for s, v in baseline.items():
                    try:
                        cmd.set(s, float(v), obj)
                    except Exception:
                        pass
        except Exception:
            pass

    with open(values_json_path) as f:
        rows = json.load(f)
    # Build vmap only for rows that carry an actual score value.  Rows with
    # value=null represent masked (missing-backbone) residues and are excluded.
    vmap = {(r['chain'], r['resi']): float(r['value'])
            for r in rows if r.get('value') is not None}

    if not vmap:
        # No scored residues; nothing to alter or spectrum.
        return 'DESIGN_COLOR:ok'

    # -- Fix 2: Build a selection of exactly the scored polymer residues so
    # that masked residues and all non-polymer atoms keep their baseline color
    # instead of being clamped to the first palette color (the -9999 sentinel).
    from collections import defaultdict
    chain_resis = defaultdict(list)
    for (chain, resi) in vmap:
        chain_resis[chain].append(resi)

    chain_parts = []
    for ch, resis in chain_resis.items():
        resi_str = '+'.join(str(r) for r in resis)
        if ch:
            chain_parts.append('(chain %s and resi %s)' % (ch, resi_str))
        else:
            # Empty chain: select by resi only.
            chain_parts.append('(resi %s)' % resi_str)
    scored_sel = '(%s) and polymer and (%s)' % (obj, ' or '.join(chain_parts))

    def _lookup(chain, resi):
        return vmap.get((chain, resi), -9999.0)

    # Attempt incentive-only per-atom property first; fall back to B-factor.
    prop_field = 'p.mpnn_conf'
    try:
        cmd.alter(scored_sel, 'p.mpnn_conf = _lookup(chain, resi)',
                  space={'_lookup': _lookup})
    except Exception as e:
        if 'IncentiveOnly' not in type(e).__name__:
            raise
        # Open-Source PyMOL raises IncentiveOnlyException for p.* properties;
        # fall back to storing values in the B-factor column instead.
        prop_field = 'b'
        cmd.alter(scored_sel, 'b = _lookup(chain, resi)',
                  space={'_lookup': _lookup})

    try:
        cmd.spectrum(prop_field, palette, scored_sel,
                     minimum=float(lo), maximum=float(hi))
    except TypeError:
        # This PyMOL build does not support minimum/maximum kwargs;
        # spectrum auto-scales over the values present. The Swift legend
        # still uses the lo/hi domain it passed.
        cmd.spectrum(prop_field, palette, scored_sel)

    return 'DESIGN_COLOR:ok'


# ---------------------------------------------------------------------------
# Visual-state save / dim / restore  (Task 7)
# ---------------------------------------------------------------------------
# Transparency setting names that are saved and restored per-object.
_TRANSP = [
    'cartoon_transparency',
    'transparency',
    'stick_transparency',
    'sphere_transparency',
    'ribbon_transparency',
    'surface_transparency',
]


def _get_transp_settings(obj):
    """Return a dict of {setting_name: float} for all known transparency settings.

    Silently skips any setting name unknown to this PyMOL build (e.g.
    'surface_transparency' is absent in some open-source builds).
    """
    result = {}
    for s in _TRANSP:
        try:
            result[s] = cmd.get_setting_float(s, obj)
        except Exception:
            pass
    return result


def snapshot_visual_state(objects_csv):
    """Snapshot per-atom colors and transparency settings for a set of objects.

    objects_csv: comma-separated PyMOL object names.

    Saves:
      - per-atom color (integer color index) keyed by atom *index* (str in JSON)
      - each transparency setting from _TRANSP per object (unknown settings skipped)

    Writes to $TMPDIR/raymol_design_snapshot.json.
    Returns 'DESIGN_SNAP:ok'.
    """
    objs = [o.strip() for o in objects_csv.split(',') if o.strip()]
    colors = {}
    settings = {}
    for o in objs:
        d = {}
        cmd.iterate(o, 'd[index] = color', space={'d': d})
        # JSON keys must be strings; int color values are fine.
        colors[o] = {str(k): v for k, v in d.items()}
        settings[o] = _get_transp_settings(o)
    snap = {'objects': objs, 'colors': colors, 'settings': settings}
    with open(_tmp('raymol_design_snapshot.json'), 'w') as f:
        json.dump(snap, f)
    return 'DESIGN_SNAP:ok'


def dim_object(obj, gray_color, transparency):
    """Color obj with gray_color and set all transparency settings to transparency.

    Unknown settings (absent in some PyMOL builds) are silently skipped.
    Returns 'DESIGN_DIM:ok'.
    """
    cmd.color(gray_color, obj)
    for s in _TRANSP:
        try:
            cmd.set(s, float(transparency), obj)
        except Exception:
            pass
    return 'DESIGN_DIM:ok'


def restore_visual_state():
    """Restore exact per-atom colors and transparency settings from snapshot.

    Loads $TMPDIR/raymol_design_snapshot.json written by snapshot_visual_state.
    For each object: restores transparency settings, then restores per-atom
    colors via alter (JSON string keys are converted back to int for matching),
    then calls recolor() to flush the display.
    Returns 'DESIGN_RESTORE:ok'.
    """
    with open(_tmp('raymol_design_snapshot.json')) as f:
        snap = json.load(f)
    for o in snap['objects']:
        # Restore transparency settings first.
        for s, v in snap['settings'][o].items():
            cmd.set(s, float(v), o)
        # JSON keys are strings; convert back to int to match `index` (int) in alter.
        int_colors = {int(k): v for k, v in snap['colors'][o].items()}
        cmd.alter(o, 'color = _d.get(index, color)', space={'_d': int_colors})
    cmd.recolor()
    return 'DESIGN_RESTORE:ok'
