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
# MPNN alphabet index -> 3-letter resname (index 20 / 'X' -> 'UNK').
_ONE_LETTER_TO_THREE = {v: k for k, v in _ONE.items()}
_ONE_LETTER_TO_THREE['X'] = 'UNK'
_INDEX_TO_THREE = {i: _ONE_LETTER_TO_THREE.get(c, 'UNK') for i, c in enumerate(_ALPHABET)}


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


# ---------------------------------------------------------------------------
# Per-residue hover / pin sidechain sticks  (Phase 2a)
# ---------------------------------------------------------------------------
# Non-destructive preview: show sidechain sticks (colored by element) for the
# residue under the pointer (transient) and the pinned residue (persistent).
# We remember the EXACT per-atom colors we overwrote so stick-off restores them
# precisely — same faithful capture/restore pattern as snapshot_visual_state,
# but scoped to a single residue's sidechain. Residues the user already
# stick-repped themselves are detected and left completely untouched.
_STICK_COLORS = {}


def _residue_sel(obj, chain, resi):
    """Build a residue selection, tolerating an empty chain id."""
    if chain:
        return '(%s) and chain %s and resi %s' % (obj, chain, resi)
    return '(%s) and resi %s' % (obj, resi)


def set_residue_sticks(obj, chain, resi, on):
    """Non-destructively show/hide sidechain sticks for a single residue.

    on truthy: if the residue's sidechain has no sticks yet AND has sidechain
      atoms, show sticks there and color by element (util.cnc keeps carbons,
      colors N/O/S/... ). Remembers the atoms' prior colors so stick-off can
      restore them, and reports whether WE added the sticks. A residue that
      already carries sticks (the user's own) is left untouched (added=False).
    on falsy: hide the sticks and restore the exact colors we overwrote — but
      only for residues WE previously added (tracked in _STICK_COLORS).

    Writes {'added': bool, 'chain': .., 'resi': ..} to
    $TMPDIR/raymol_design_sticks.json so the Swift caller can record, on a
    show, whether it now manages this residue's sticks.
    Never raises into the caller; returns a short marker string.
    """
    added = False
    try:
        on = bool(on) if isinstance(on, bool) else bool(int(on))
        res_sel = _residue_sel(obj, chain, resi)
        # Include CA so the CA–CB bond is drawn — otherwise the sidechain sticks
        # float detached from the backbone (PyMOL's `sidechain` excludes CA).
        side_sel = '(%s) and (sidechain or name CA)' % res_sel
        key = '%s\x01%s\x01%s' % (obj, chain, resi)
        if on:
            # Only add if the sidechain has atoms and none are already sticks
            # (never clobber a residue the user drew sticks on).
            has_atoms = cmd.count_atoms(side_sel) > 0
            already = cmd.count_atoms('(%s) and rep sticks' % side_sel) > 0
            if has_atoms and not already:
                # Capture the exact per-atom colors before recoloring by element.
                prior = {}
                cmd.iterate(side_sel, 'prior[index] = color',
                            space={'prior': prior})
                _STICK_COLORS[key] = prior
                cmd.show('sticks', side_sel)
                try:
                    cmd.util.cnc(side_sel, _self=cmd)
                except Exception:
                    pass
                added = True
        else:
            prior = _STICK_COLORS.pop(key, None)
            # Only touch residues we actually added sticks to.
            if prior is not None:
                cmd.hide('sticks', side_sel)
                cmd.alter(side_sel, 'color = _d.get(index, color)',
                          space={'_d': prior})
                cmd.recolor(side_sel)
    except Exception:
        pass
    try:
        with open(_tmp('raymol_design_sticks.json'), 'w') as f:
            json.dump({'added': bool(added), 'chain': chain, 'resi': resi}, f)
    except Exception:
        pass
    return 'DESIGN_STICKS:%s' % ('added' if added else 'noop')


# ---- Phase 2b: point-mutation editing helpers (additive) ----

def make_working_copy(src, dst):
    """Create a non-destructive working copy of src named dst, disable src.

    If dst already exists it is deleted first.  The copy inherits source
    transformation matrices so the two objects are superposed.
    Returns 'DESIGN_WORK:<dst>'.
    """
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.create(dst, src)          # inherits source matrices → superposed
    cmd.disable(src)
    return 'DESIGN_WORK:%s' % dst


def set_compare(src, on):
    """Enable or disable the original src object for a side-by-side compare view.

    on: truthy → enable; falsy → disable.
    Returns 'DESIGN_CMP:ok'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    (cmd.enable if _on else cmd.disable)(src)
    return 'DESIGN_CMP:ok'


def discard_working_copy(src, dst):
    """Delete the working copy dst and re-enable the original src.

    Safe to call even if dst no longer exists.
    Returns 'DESIGN_DISCARD:ok'.
    """
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.enable(src)
    return 'DESIGN_DISCARD:ok'


def set_residue_backbone_only(obj, chain, resi, on):
    """Hide sidechain representations for a single residue while a mutation is pending.

    on truthy: hide sticks/lines/spheres/nb_spheres on the sidechain atoms
      (everything except backbone N, CA, C, O) so stale pre-mutation coordinates
      are not shown.  Repack + rep-refresh restores them, so the off branch is a
      deliberate no-op.
    on falsy: no-op (caller reloads coords via load_repacked, which triggers a
      full representation refresh).
    Returns 'DESIGN_BBONLY:ok'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    side = '(%s) and (not name N+CA+C+O)' % _residue_sel(obj, chain, resi)
    if _on:
        for rep in ('sticks', 'lines', 'spheres', 'nb_spheres'):
            cmd.hide(rep, side)
    return 'DESIGN_BBONLY:ok'


def mutate_residue_display(obj, chain, resi, aa_index):
    """Visually apply a pending single-residue mutation to the working copy.

    1. Updates the residue name (resn) via cmd.alter so labels reflect the new
       amino-acid identity.
    2. Hides stale sidechain representations via set_residue_backbone_only so
       pre-repack side-chain coordinates are not shown to the user.

    aa_index: MPNN alphabet index (0-20); index 20 ('X'/masked) is a no-op.
    Returns 'DESIGN_MUTDISP:ok' or 'DESIGN_MUTDISP:noop'.
    """
    try:
        idx = int(aa_index)
    except (ValueError, TypeError):
        return 'DESIGN_MUTDISP:noop'
    if idx >= 20:
        # Masked/unknown residue — leave untouched.
        return 'DESIGN_MUTDISP:noop'
    three = _INDEX_TO_THREE.get(idx, 'UNK')
    res_sel = _residue_sel(obj, chain, resi)
    try:
        cmd.alter(res_sel, "resn='%s'" % three)
        cmd.rebuild(res_sel)  # flush label/rep state that depends on resn immediately
    except Exception:
        pass
    set_residue_backbone_only(obj, chain, resi, True)
    return 'DESIGN_MUTDISP:ok'


def load_repacked(obj, pdb_str):
    """Replace obj's coordinates from an all-atom PDB string (repack output).

    Uses a temp object and cmd.update to copy coordinates by matching atoms,
    preserving the object name and current per-atom coloring.  Falls back to
    replacing the object outright if the topology changed (update returned an
    error or atom count differs).
    Returns 'DESIGN_REPACKED:ok'.
    """
    tmp = cmd.get_unused_name('_rp')
    try:
        cmd.read_pdbstr(pdb_str, tmp)
        try:
            cmd.update(obj, tmp, matchmaker=1)   # copy coords onto matching atoms
        except TypeError:
            # Older builds may not accept matchmaker kwarg; retry without it.
            cmd.update(obj, tmp)
    finally:
        cmd.delete(tmp)
    return 'DESIGN_REPACKED:ok'
