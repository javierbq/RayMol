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


def _selection_names():
    """Named selections in the session (includes the active 'sele' if present)."""
    try:
        return list(cmd.get_names('selections'))
    except Exception:
        return []


def _obj_residue_order(obj):
    """(chain, resi) for obj's polymer residues in canonical guide order —
    the same order enumerate_design_residues emits, so indices align with the
    Swift DesignResidueSet.residues array."""
    order = []
    try:
        cmd.iterate('(%s) and polymer and guide' % obj,
                    'order.append((chain, resi))', space={'order': order})
    except Exception:
        return []
    return order


def list_design_selections(obj, state):
    """Write named selections that intersect obj's polymer residues, with counts.

    Output: $TMPDIR/raymol_design_selections.json = {'selections': [{'name','n'}]}.
    Selections with zero intersecting residues are omitted. The count is polymer
    residues in the intersection; the exact designable subset (full backbone) is
    resolved at pick time by the Swift valid mask. Returns a short marker.
    """
    out = []
    for name in _selection_names():
        try:
            n = cmd.count_atoms('(%s) and (%s) and polymer and guide' % (obj, name))
        except Exception:
            n = 0
        if n > 0:
            out.append({'name': name, 'n': int(n)})
    try:
        with open(_tmp('raymol_design_selections.json'), 'w') as f:
            json.dump({'selections': out}, f)
    except Exception:
        pass
    return 'DESIGN_SELECTIONS:%d' % len(out)


def selected_design_indices(obj, selection, state):
    """Map a selection on obj → full-length residue indices in guide order.

    Non-polymer atoms in the selection are ignored. Output:
    $TMPDIR/raymol_design_selected.json = {'indices': [int]}. Returns a marker.
    """
    # state is accepted for signature symmetry with enumerate_design_residues but
    # not used here: guide order is read from the current state. Multi-state objects
    # at a non-default state may misalign; Design-mode editing is single-state (spec).
    order = _obj_residue_order(obj)
    sel_res = set()
    try:
        cmd.iterate('(%s) and (%s) and polymer and guide' % (obj, selection),
                    'sel_res.add((chain, resi))', space={'sel_res': sel_res})
    except Exception:
        pass
    indices = [i for i, cr in enumerate(order) if cr in sel_res]
    try:
        with open(_tmp('raymol_design_selected.json'), 'w') as f:
            json.dump({'indices': indices}, f)
    except Exception:
        pass
    return 'DESIGN_SELECTED:%d' % len(indices)


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

# Module-level store for the full visual state (per-atom colors + transparency
# settings) saved when compare first turns on. Keyed by src object name; popped
# on compare-off or reset_compare.
# Shape: {src: {'colors': {str(index): color_int}, 'settings': {name: float}}}
_COMPARE_STATE = {}


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
        # Exclude hydrogens (`not hydro`) — H sticks just clutter the preview.
        side_sel = '(%s) and (sidechain or name CA) and not hydro' % res_sel
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

def make_working_copy(src):
    """Create a non-destructive working copy of src, choosing a unique name.

    Uses cmd.get_unused_name so a previously-kept working copy (e.g. src_design)
    is not overwritten — the new session gets src_design01 etc.  The chosen
    name is written to $TMPDIR/raymol_design_working.json for the Swift caller
    to read back (runPython is fire-and-forget; no return channel).
    The copy inherits source transformation matrices so the two objects are
    superposed.  Returns 'DESIGN_WORK:<dst>'.
    """
    dst = cmd.get_unused_name(src + '_design')
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.create(dst, src, zoom=0)  # zoom=0: no camera reset; inherits source matrices → superposed
    cmd.disable(src)
    try:
        with open(_tmp('raymol_design_working.json'), 'w') as f:
            json.dump({'src': src, 'dst': dst}, f)
    except Exception:
        pass
    return 'DESIGN_WORK:%s' % dst


def _restore_compare_state(src):
    """Restore per-atom colors and transparency settings from _COMPARE_STATE[src].

    Pops the entry. Returns True if state was present, False otherwise.
    """
    state = _COMPARE_STATE.pop(src, None)
    if state is None:
        return False
    int_colors = {int(k): v for k, v in state['colors'].items()}
    cmd.alter(src, 'color = _d.get(index, color)', space={'_d': int_colors})
    for s, v in state['settings'].items():
        try:
            cmd.set(s, float(v), src)
        except Exception:
            pass
    cmd.recolor(src)
    return True


def _apply_compare_overlap(src):
    """Overlap mode: grey + transparent, no grid.

    Grid mode 0; enable src; color grey70; set all transparency settings to 0.5.
    """
    cmd.set('grid_mode', 0)
    cmd.enable(src)
    cmd.color('grey70', src)
    for s in _TRANSP:
        try:
            cmd.set(s, 0.5, src)
        except Exception:
            pass


def _apply_compare_grid(src):
    """Grid mode: restore saved colors + fully opaque, grid enabled.

    Restores per-atom colors from _COMPARE_STATE (saved at compare-first-on);
    sets all transparency settings to 0 (fully opaque); enables grid_mode 1.
    """
    state = _COMPARE_STATE.get(src)
    if state:
        int_colors = {int(k): v for k, v in state['colors'].items()}
        cmd.alter(src, 'color = _d.get(index, color)', space={'_d': int_colors})
        cmd.recolor(src)
    for s in _TRANSP:
        try:
            cmd.set(s, 0.0, src)
        except Exception:
            pass
    cmd.set('grid_mode', 1)
    cmd.enable(src)


def set_compare(src, on, side_by_side=False):
    """Enable/disable compare view for src (original parent).

    on truthy: save src per-atom colors + transparency into _COMPARE_STATE (once
      on first call); then apply overlap or grid per side_by_side:
      - side_by_side=False (overlap, default): grid_mode 0; enable src; color
        grey70; set transparency ~0.5 so it ghosts behind the design.
      - side_by_side=True (grid): grid_mode 1; enable src; restore saved colors +
        set transparency 0 (own confidence coloring, fully opaque).
      Toggling side_by_side while on switches between the two modes.
    on falsy: restore saved colors + transparency; disable src; grid_mode 0.

    Returns 'DESIGN_CMP:ok'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    _sbs = bool(side_by_side) if isinstance(side_by_side, bool) else bool(int(side_by_side))
    if _on:
        # Save full visual state on first compare-on; idempotent on subsequent calls.
        if src not in _COMPARE_STATE:
            colors = {}
            cmd.iterate(src, 'colors[index] = color', space={'colors': colors})
            _COMPARE_STATE[src] = {
                'colors': {str(k): v for k, v in colors.items()},
                'settings': _get_transp_settings(src),
            }
        if _sbs:
            _apply_compare_grid(src)
        else:
            _apply_compare_overlap(src)
    else:
        _restore_compare_state(src)
        cmd.disable(src)
        cmd.set('grid_mode', 0)
    return 'DESIGN_CMP:ok'


def reset_compare(src):
    """Restore src's saved compare colors + transparency (if any) and clear grid_mode.

    Does NOT enable or disable src.  Called by teardown so grid_mode is turned
    off and the parent is un-greyed, while the teardown's own enable/discard
    logic independently handles object visibility.
    Returns 'DESIGN_CMPRESET:ok'.
    """
    _restore_compare_state(src)
    cmd.set('grid_mode', 0)
    return 'DESIGN_CMPRESET:ok'


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
    """Replace obj's structure from an all-atom PDB string (repack output).

    Full topology replace: reads pdb_str into a temp object, copies the
    current transform matrix from obj onto the temp (preserving superposition
    with the parent), then deletes obj and renames temp → obj.  This correctly
    adopts point mutations where the residue's atom set changed (e.g. ALA→TRP):
    cmd.update(matchmaker=1) can only copy coordinates onto atoms that already
    match by name, so it silently leaves the old sidechain intact when the atom
    set differs.  Replacing the entire object always adopts the new topology.

    After renaming, cartoon rep is enabled so the replaced object is visible.
    On any failure after read but before rename, the temp object is cleaned up.
    Returns 'DESIGN_REPACKED:ok'.
    """
    # Capture the camera view BEFORE any structural replacement so the viewport
    # does not jump when load+delete+rename triggers PyMOL's auto-zoom.
    v = cmd.get_view()
    tmp = cmd.get_unused_name('_rp')
    renamed = False
    try:
        cmd.read_pdbstr(pdb_str, tmp)
        # Copy the source object's transformation matrix to tmp BEFORE deleting
        # the source, so the replaced object stays in the same frame (superposed
        # on the original parent).  Silently skip if not supported or if obj is gone.
        try:
            cmd.matrix_copy(obj, tmp)
        except Exception:
            pass
        cmd.delete(obj)
        cmd.set_name(tmp, obj)
        renamed = True
        # Replacing the object resets representations; restore cartoon so the
        # working copy is visible immediately (conf coloring is re-applied by
        # the Swift caller after this returns).
        cmd.show_as('cartoon', obj)
    finally:
        if not renamed and tmp in cmd.get_object_list():
            cmd.delete(tmp)
    # Restore the camera view exactly as it was before the replace (zoom=0 on
    # create already prevented the initial zoom; this covers the repack path).
    cmd.set_view(v)
    return 'DESIGN_REPACKED:ok'


def set_pinned_indicator(obj, chain, resi):
    """Set or clear the persistent committed 'sele' marker for the pinned residue.

    If chain and resi are non-empty, commits the residue's atoms to the PyMOL
    'sele' selection with enable=1 so the renderer draws the pink committed-
    selection pass persistently (the same indicator family as a normal click, but
    driven by the Design-mode pin rather than a user tap).  If either is empty,
    clears 'sele' to 'none' with enable=0 so no stale marker persists after
    unpinning, focus-change, teardown, or exit from Design mode.
    Returns 'DESIGN_PIN:ok'.
    """
    if resi:  # resi non-empty → set indicator (chain may legitimately be empty)
        cmd.select('sele', _residue_sel(obj, chain, resi), enable=1)
    else:      # resi empty → clear (controller sends ("", "", "") on unpin/teardown)
        cmd.select('sele', 'none', enable=0)
    return 'DESIGN_PIN:ok'


def show_all_sidechains(obj, on):
    """Show or hide all sidechain sticks on obj.

    on truthy: show sticks for '(obj) and (sidechain or name CA) and not hydro'
      (CA included so the CA–CB bond draws from the backbone; hydrogens excluded),
      then apply cnc coloring so
      heteroatoms are colored by element while carbons inherit the residue's
      current confidence color.
    on falsy: hide sticks for the same selection.

    Returns 'DESIGN_SIDECHAINS:on' or 'DESIGN_SIDECHAINS:off'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    # Exclude hydrogens (`not hydro`) — H sticks just clutter the display.
    sel = '(%s) and (sidechain or name CA) and not hydro' % obj
    if _on:
        cmd.show('sticks', sel)
        try:
            cmd.util.cnc(sel, _self=cmd)
        except Exception:
            pass
    else:
        cmd.hide('sticks', sel)
    return 'DESIGN_SIDECHAINS:%s' % ('on' if _on else 'off')
