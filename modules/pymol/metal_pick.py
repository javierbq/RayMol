"""Screen-space atom picking for the Metal backend.

GL color-picking (SceneDoXYPick) is unavailable on Metal, so we reproduce its
effect in Python: project every atom of the enabled objects to screen NDC using
the current camera (cmd.get_view), pick the atom whose projection is closest to
the click, and toggle its residue in/out of the active 'sele'. Clicking empty
space empties 'sele' (matching PyMOL's single-click cButModeSeleSet behavior).
Selection indicators are drawn in C++ by SceneRenderMetalSelections.

IMPORTANT: cmd.get_view() returns the full 25-float SceneViewType, NOT the
legacy 18-float vector described in its docstring. Verified layout (0-based):
  v[0..15]  : 4x4 ROTATION matrix, COLUMN-MAJOR (model -> camera). 3x3 rows are
              (v[0],v[4],v[8]), (v[1],v[5],v[9]), (v[2],v[6],v[10]).
  v[16..18] : camera position (eye-space translation, "pos").
  v[19..21] : origin of rotation, in MODEL space.
  v[22]     : front clip,  v[23] : back clip.
  v[24]     : fov flag (+fov if orthoscopic, else -fov); abs() = vertical FOV deg.
The modelview is MV = T(pos) * R * T(-origin), i.e. eye = R*(model-origin) + pos.
"""
import math

# Screen pick radius (squared, in NDC). Clicks farther than this from any
# atom's projection are treated as empty space (which clears 'sele').
_MAX_PICK_NDC2 = 0.0100  # ~0.1 NDC radius
# Object selection (move mode) is forgiving: a tap anywhere on/near a molecule
# should identify the object, not require a precise hit on a guide atom (cartoons
# are gappy when zoomed out). ~0.3 NDC radius; still picks the NEAREST object, so
# a clearly-empty tap (beyond this of every atom) correctly deselects.
_OBJECT_PICK_NDC2 = 0.0900  # ~0.3 NDC radius
# Atoms whose screen distance² is within this of the closest are treated as
# overlapping under the cursor; among them the front-most (min depth) is picked.
_CLUSTER_NDC2 = 0.0009   # ~0.03 NDC

# Atoms that are actually DRAWN (so a pick can't hit an invisible atom).
# Per-rep selectors mirror the visRep bitmask. The catch: `show cartoon`/`ribbon`
# OR their bit onto EVERY atom of the object (incl. side chains + solvent), but
# the cartoon/ribbon geometry is a spline through the GUIDE atoms (Cα for
# protein, C4'/C1' for nucleic) — the side chains are NOT drawn. So for those
# reps we intersect with `guide`, not `(polymer or guide)`: a pick over a cartoon
# resolves to the nearest visible Cα (→ its residue), instead of snapping to
# whatever invisible side-chain atom happens to project closest (which made hover
# jump erratically between residues). A residue that ALSO shows sticks/lines/etc.
# stays atom-pickable via those reps' own clauses. ('labels' omitted — not
# pickable geometry.)
_DRAWN_REPS = ('rep spheres or rep sticks or rep lines or rep nb_spheres or '
               'rep nonbonded or rep surface or rep dots or rep mesh or '
               'rep ellipsoid or ((rep cartoon or rep ribbon) and guide)')

# Named selection that carries the transient hover PREVIEW (issue #165). The
# leading underscore hides it from public object/selection lists AND is already
# skipped by _pick_atom's `startswith('_')` filter, so it can never be picked
# into. The renderer draws it in a distinct color/size (C++
# SceneDrawMetalPreselection) BEFORE the committed 'sele' pass, so the pink
# committed color always wins on overlap.
_PRESELECT = '_preselect'


def _pickdbg(ndc_x, ndc_y, aspect, best, ncand):
    """Append a pick diagnostic line to PYMOL_PICKDEBUG (debug harness only).

    Records the click NDC and, for the chosen atom, its resi and its PROJECTED
    NDC (sx,sy). If the chosen atom's projected NDC ~= the click NDC but the
    selected residue is not the one visibly under the cursor, the pick math and
    the renderer disagree (the bug class we're chasing).
    """
    import os
    path = os.environ.get('PYMOL_PICKDEBUG')
    if not path:
        return
    try:
        if best is None:
            line = 'click ndc=(%.4f,%.4f) aspect=%.4f -> EMPTY (ncand=%d)\n' % (
                ndc_x, ndc_y, aspect, ncand)
        else:
            d2, obj, chain, resi, resn, segi, name, sx, sy = best
            line = ('click ndc=(%.4f,%.4f) aspect=%.4f -> %s/%s/%s`%s/%s '
                    'projNDC=(%.4f,%.4f) d=%.4f ncand=%d\n' % (
                        ndc_x, ndc_y, aspect, obj, chain, resn, resi, name,
                        sx, sy, d2 ** 0.5, ncand))
        with open(path, 'a') as f:
            f.write(line)
    except Exception:
        pass


def _grid_layout(size, aspect):
    """Choose (n_col, n_row) for `size` grid cells at window aspect (W/H).
    Mirrors the C++ GridUpdate (layer1/Scene.cpp) exactly so picking agrees with
    what the Metal renderer drew."""
    if size < 1:
        return (1, 1)
    n_row = n_col = 1
    while (n_row * n_col) < size:
        asp1 = aspect * (n_row + 1.0) / n_col
        asp2 = aspect * n_row / (n_col + 1.0)
        if asp1 < 1.0:
            asp1 = 1.0 / asp1
        if asp2 < 1.0:
            asp2 = 1.0 / asp2
        if abs(asp1) > abs(asp2):
            n_col += 1
        else:
            n_row += 1
    while (n_col - 1) * n_row >= size and size:
        n_col -= 1
    while (n_row - 1) * n_col >= size and size:
        n_row -= 1
    return (n_col, n_row)


def _grid_pick_context(ndc_x, ndc_y, aspect):
    """When grid_mode=1 (by-object) is active with 2+ objects, map a full-window
    click NDC to its grid cell and return
    (target_obj, cell_ndc_x, cell_ndc_y, cell_aspect):
      - target_obj: the object laid out in the clicked cell ('' if none).
      - cell_ndc_x/y: the click re-expressed in that cell's NDC.
      - cell_aspect: that cell's aspect (window_aspect * n_row/n_col).
    Returns None when grid isn't cell-mapped (caller projects the whole window).

    The slot→object mapping mirrors the core: grid-eligible enabled objects take
    slots in scene order, cell layout is GridUpdate, cells run col left→right and
    row 0 at the TOP. (By-object only; grid_mode 2/3 fall through to whole-window
    picking, and disabled-object/group gaps aren't modeled — the common case is
    all-enabled objects.)"""
    from pymol import cmd
    try:
        if int(cmd.get_setting_int('grid_mode')) != 1:
            return None
    except Exception:
        return None
    objs = [o for o in (cmd.get_names('objects', enabled_only=1) or [])
            if not o.startswith('_')]
    size = len(objs)
    try:
        grid_max = int(cmd.get_setting_int('grid_max'))
    except Exception:
        grid_max = -1
    if grid_max >= 0:
        size = min(size, grid_max)
    if size < 2 or aspect <= 0.0:
        return None
    n_col, n_row = _grid_layout(size, aspect)
    if n_col < 1 or n_row < 1:
        return None
    u = (ndc_x + 1.0) * 0.5 * n_col        # [0, n_col), x: +1 = right
    t = (1.0 - ndc_y) * 0.5 * n_row        # [0, n_row), 0 = top row
    col = min(max(int(u), 0), n_col - 1)
    row = min(max(int(t), 0), n_row - 1)
    slot = row * n_col + col               # 0-based, matches abs_grid_slot
    cell_ndc_x = (u - col) * 2.0 - 1.0
    cell_ndc_y = 1.0 - (t - row) * 2.0
    cell_aspect = aspect * (float(n_row) / float(n_col))
    target = objs[slot] if 0 <= slot < len(objs) else ''
    return (target, cell_ndc_x, cell_ndc_y, cell_aspect)


def _is_identity(m, eps=1e-6):
    """True if a 16-float homogeneous matrix is (near) identity — lets picking
    skip the per-atom transform for the common un-moved object."""
    ident = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
    return all(abs(m[i] - ident[i]) < eps for i in range(16))


def _pick_atom(ndc_x, ndc_y, aspect, max_ndc2=None):
    """Project all DRAWN atoms and return the front-most atom under the click as
    (screen_d2, obj, chain, resi, resn, segi, name, sx, sy), or None for empty
    space. Shared by pick_at (residue toggle) and appkit_measure (atom picks).

    max_ndc2 overrides the squared pick radius. Residue/atom picks use the tight
    default (_MAX_PICK_NDC2); object selection (move mode) passes the larger
    _OBJECT_PICK_NDC2 so a tap anywhere on/near the molecule still identifies it."""
    from pymol import cmd
    thresh = _MAX_PICK_NDC2 if max_ndc2 is None else float(max_ndc2)

    try:
        v = cmd.get_view()
        if not v:
            return None

        if len(v) >= 25:
            # 4x4 column-major rotation -> 3x3 rows (model -> camera).
            r00, r01, r02 = v[0], v[4], v[8]
            r10, r11, r12 = v[1], v[5], v[9]
            r20, r21, r22 = v[2], v[6], v[10]
            tx, ty, tz = v[16], v[17], v[18]   # camera pos (eye translation)
            ox, oy, oz = v[19], v[20], v[21]   # rotation origin (model space)
            fov_deg = abs(v[24])
            clip_front = clip_back = None      # 25-float clip layout unverified; skip
        else:
            # Legacy 18-float layout (what our embedded build returns):
            #   v[0:9]=3x3 rotation, v[9:12]=pos, v[12:15]=origin,
            #   v[15]=front, v[16]=back, v[17]=fov flag.
            # The rotation is COLUMN-MAJOR (same as the 25-float / GL convention
            # and the Metal renderer's modelview). Parsing it row-major TRANSPOSES
            # it — harmless for axis-aligned views but, under a real `orient`
            # rotation, it projects atoms to the wrong screen positions, so the
            # click selects an atom that renders far from the cursor.
            r00, r01, r02 = v[0], v[3], v[6]
            r10, r11, r12 = v[1], v[4], v[7]
            r20, r21, r22 = v[2], v[5], v[8]
            tx, ty, tz = v[9], v[10], v[11]
            ox, oy, oz = v[12], v[13], v[14]
            fov_deg = abs(v[17])
            clip_front, clip_back = v[15], v[16]   # slab: pickable only in [front,back]
        if fov_deg <= 1.0:
            fov_deg = cmd.get_setting_float('field_of_view')

        if aspect <= 0.0:
            return

        # Match the renderer EXACTLY: it calls glm::perspective(GetFovWidth,...)
        # with GetFovWidth = 2*tan(radians(fov)/2), and glm takes tan(arg/2),
        # so the effective half-height slope is tan(GetFovWidth/2).
        fov_width = 2.0 * math.tan(math.radians(fov_deg) / 2.0)
        tan_half = math.tan(fov_width / 2.0)
        if tan_half <= 0.0:
            return

        # Grid mode (by-object): the renderer draws each object in its own
        # viewport cell, so a full-window projection wouldn't line up with what
        # the user sees. Map the click to its cell, restrict the search to that
        # cell's object, and project with the cell's NDC + aspect. tan_half is
        # aspect-independent (FOV only), so reassigning `aspect` below is safe.
        pick_objs = None
        gctx = _grid_pick_context(ndc_x, ndc_y, aspect)
        if gctx is not None:
            target_obj, ndc_x, ndc_y, aspect = gctx
            if not target_obj:
                return None  # empty cell → treat as empty-space click
            pick_objs = [target_obj]

        best = None  # (screen_d2, obj, chain, resi, resn, segi, name, sx, sy)
        cands = []   # (d2, depth, obj, chain, resi, resn, segi, name, sx, sy)
        ncand = 0    # atoms whose projection fell within the pick radius
        _ext = [1e9, -1e9, 1e9, -1e9]  # projected-NDC extent: sx_min,sx_max,sy_min,sy_max

        if pick_objs is None:
            pick_objs = (cmd.get_names('objects', enabled_only=1) or [])
        # Displayed movie/model state: pick against the coordinates actually
        # RENDERED. get_model defaults to state 1, so a multi-state (NMR /
        # trajectory) object shown at a later state would otherwise be picked at
        # its state-1 positions — residues can be 20+ A (≈0.4 NDC) off, so a click
        # or hover lands on the wrong residue.
        try:
            cur_state = int(cmd.get_state())
        except Exception:
            cur_state = 1
        for obj in pick_objs:
            if obj.startswith('_'):
                continue
            # Skip non-molecule objects (distance/angle measurements, maps, CGOs,
            # groups). Passing their name to the atom-selection parser (below)
            # raises a C++ "Invalid selection name" Selector-Error that prints to
            # the feedback log on every click even though Python catches it.
            try:
                if cmd.get_type(obj) != 'object:molecule':
                    continue
            except Exception:
                continue
            try:
                # Only consider atoms that are actually DRAWN, so a click can't
                # select an invisible atom (e.g. a hidden water under a cartoon).
                # get_model(obj) alone returns EVERY atom; the `visible` selector
                # over-reports because cartoon/ribbon set their visRep bit on all
                # atoms (incl. solvent) though only guide atoms draw — hence the
                # per-rep _DRAWN_REPS filter (see its definition).
                sel = '(%s) and (%s)' % (obj, _DRAWN_REPS)
                model = None
                # Prefer the displayed state so the pick matches the render.
                # Only when it isn't state 1 (get_model already defaults to 1),
                # and fall back to the default if an explicit-state query returns
                # no atoms — some embedded cores return empty for
                # get_model(state=N); we must never regress those to a dead pick.
                if cur_state > 1:
                    try:
                        m = cmd.get_model(sel, state=cur_state)
                        if m and m.atom:
                            model = m
                    except Exception:
                        model = None
                if model is None:
                    model = cmd.get_model(sel)
            except Exception:
                continue
            if not model or not model.atom:
                continue
            # get_model() already returns coordinates with the object's display
            # transform (TTT) BAKED IN — verified: get_model() == TTT x raw_coords
            # for a moved object. So we must NOT re-apply the object matrix here:
            # doing so DOUBLE-transforms a MOVED object (non-identity TTT) and the
            # pick lands far from where the atom renders. Non-moved objects only
            # appeared correct because their TTT is identity (the re-apply was a
            # no-op) — which is why picking broke only after moving an object.
            for at in model.atom:
                cx, cy, cz = at.coord[0], at.coord[1], at.coord[2]
                dx = cx - ox
                dy = cy - oy
                dz = cz - oz
                # eye = R*(model-origin) + pos
                ex = r00 * dx + r01 * dy + r02 * dz + tx
                ey = r10 * dx + r11 * dy + r12 * dz + ty
                ez = r20 * dx + r21 * dy + r22 * dz + tz
                depth = -ez                     # camera looks down -Z
                if depth <= 0.01:
                    continue
                # Pickability respects the clip slab: an atom clipped away (outside
                # [front,back]) isn't visible, so it must not be selectable. Guarded
                # to a sane slab so a bad view layout can never disable picking. (What
                # IS selected is drawn clip-invariant separately in the renderer.)
                if clip_front is not None and clip_back > clip_front \
                        and (depth < clip_front or depth > clip_back):
                    continue
                half_h = depth * tan_half
                half_w = half_h * aspect
                sx = ex / half_w                # NDC x, +1 = right
                sy = ey / half_h                # NDC y, +1 = up (bottom-left)
                if sx < _ext[0]: _ext[0] = sx
                if sx > _ext[1]: _ext[1] = sx
                if sy < _ext[2]: _ext[2] = sy
                if sy > _ext[3]: _ext[3] = sy
                d2 = (sx - ndc_x) ** 2 + (sy - ndc_y) ** 2
                if d2 > thresh:
                    continue
                ncand += 1
                cands.append((d2, depth, obj, at.chain or '', at.resi,
                              at.resn, at.segi or (at.chain or ''), at.name, sx, sy))

        # Choose the FRONT-MOST atom among those clustered nearest the click, so
        # that where atoms overlap on screen we select the one actually visible
        # (closest to the camera), not whichever projects marginally nearer the
        # cursor. Atoms within _CLUSTER_NDC2 of the closest are treated as
        # overlapping; the smallest depth (front-most) wins.
        if cands:
            cands.sort(key=lambda c: c[0])           # by screen distance²
            d2min = cands[0][0]
            cluster = [c for c in cands if c[0] <= d2min + _CLUSTER_NDC2]
            c = min(cluster, key=lambda c: c[1])     # front-most (min depth)
            best = (c[0], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9])

        _pickdbg(ndc_x, ndc_y, aspect, best, ncand)
        import os as _os
        if _os.environ.get('PYMOL_PICKDEBUG'):
            try:
                _nv = cmd.count_atoms('visible')
                _nt = cmd.count_atoms('all')
                _nhv = cmd.count_atoms('resn HOH and visible')
                with open(_os.environ['PYMOL_PICKDEBUG'], 'a') as _f:
                    _f.write('  VIS total=%d visible=%d hoh_visible=%d\n' % (_nt, _nv, _nhv))
                    _f.write('  params len(v)=%d fov=%.2f tan_half=%.4f aspect=%.4f '
                             'pos=(%.2f,%.2f,%.2f) origin=(%.2f,%.2f,%.2f) '
                             'projext sx=[%.3f,%.3f] sy=[%.3f,%.3f]\n' % (
                                 len(v), fov_deg, tan_half, aspect,
                                 tx, ty, tz, ox, oy, oz,
                                 _ext[0], _ext[1], _ext[2], _ext[3]))
                    _f.write('  rawview=%s\n' % ','.join('%.5f' % x for x in v))
                    if best is not None:
                        _be = best[1]; _bc = best[2]; _br = best[3]; _bn = best[6]
                        _xyz = []
                        cmd.iterate_state(1, '%s and resi %s and name %s%s' % (
                            _be, _br, _bn,
                            (' and chain %s' % _bc) if _bc else ''),
                            '_xyz.extend([x,y,z])', space={'_xyz': _xyz})
                        if len(_xyz) >= 3:
                            _f.write('  pickedxyz=(%.3f,%.3f,%.3f)\n' % (_xyz[0], _xyz[1], _xyz[2]))
            except Exception:
                pass

        return best

    except Exception as e:
        print('metal_pick error: %s' % e)
        return None


def atom_expr(best):
    """Atom-precise selection expression for a _pick_atom result tuple."""
    _, obj, chain, resi, resn, segi, name, _sx, _sy = best
    expr = '%s and resi %s and name %s' % (obj, resi, name)
    if chain:
        expr += ' and chain %s' % chain
    return '(%s)' % expr


def _eye_distance(selection):
    """Mean eye-space (camera) distance of `selection`'s atoms, or None.

    Uses the same camera math as _pick_atom: eye = R*(model-origin) + pos, so the
    eye-space Z is R_row2 . (model-origin) + pos.z, and the positive distance in
    front of the camera is -eye.z. R_row2 = (v[2], v[6], v[10]); pos.z = v[18]."""
    from pymol import cmd
    v = cmd.get_view()
    if not v:
        return None
    if len(v) >= 25:
        r20, r21, r22 = v[2], v[6], v[10]
        tz = v[18]
        ox, oy, oz = v[19], v[20], v[21]
    else:  # legacy 18-float layout
        r20, r21, r22 = v[2], v[5], v[8]
        tz = v[11]
        ox, oy, oz = v[12], v[13], v[14]
    # Gather coords via iterate_state (cmd.get_coords returns None in the
    # embedded build). acc = [sum_of_eye_z, atom_count].
    acc = [0.0, 0]
    # NOTE: `p` and `s` are reserved in iterate/alter expressions (atom property
    # and setting objects), so the camera params go in `cam`, not `p`.
    expr = ('acc[0] += cam[0]*(x-cam[3]) + cam[1]*(y-cam[4]) + cam[2]*(z-cam[5]) + cam[6]; '
            'acc[1] += 1')
    try:
        cmd.iterate_state(1, selection, expr,
                          space={'acc': acc,
                                 'cam': (r20, r21, r22, ox, oy, oz, tz)})
    except Exception:
        return None
    if acc[1] == 0:
        return None
    return -(acc[0] / acc[1])


def dof_focus(selection='pk1', enable=1, _self=None):
    """
DESCRIPTION

    Aim the Metal depth-of-field focal plane at "selection" by setting
    metal_dof_focus to its eye-space distance. With enable=1 also turns
    metal_dof on. An empty selection (or one with no atoms) reverts to AUTO
    focus on the center of interest (metal_dof_focus = 0).

USAGE

    dof_focus [ selection [, enable ]]

EXAMPLES

    dof_focus organic       # focus on the ligand
    dof_focus pk1           # focus on the last picked atom
    dof_focus               # auto (center of interest) if nothing is picked
    """
    from pymol import cmd
    c = _self or cmd
    sel = (selection or '').strip()
    n = 0
    if sel:
        try:
            n = c.count_atoms('(%s)' % sel)
        except Exception:
            n = 0
    if n == 0:
        c.set('metal_dof_focus', 0.0)  # auto: center of interest
    else:
        d = _eye_distance('(%s)' % sel)
        if d and d > 0.0:
            c.set('metal_dof_focus', float(d))
    if int(enable):
        c.set('metal_dof', 1)


try:  # expose `dof_focus` as a PyMOL command when this module is imported
    from pymol import cmd as _cmd_reg
    _cmd_reg.extend('dof_focus', dof_focus)
except Exception:
    pass


def _mode_expr(best, mode):
    """Expand a _pick_atom result tuple to a selection expression honoring
    mouse_selection_mode (0 atom, 1 residue, 2 chain, 3 segment, 4 object,
    5 molecule, 6 C-alpha). Shared by pick_at (commit into 'sele') and
    hover_preview_at (transient '_preselect'), so both expand the pick to the
    same scope for a given mode."""
    _, obj, chain, resi, resn, segi, name, _sx, _sy = best
    atom = '%s and resi %s and name %s' % (obj, resi, name)
    if chain:
        atom += ' and chain %s' % chain
    res = ('%s and chain %s and resi %s' % (obj, chain, resi)) if chain \
        else ('%s and resi %s' % (obj, resi))
    if mode == 0:                                   # atom
        return '(%s)' % atom
    elif mode == 2:                                 # chain
        return ('(%s and chain %s)' % (obj, chain)) if chain else '(%s)' % obj
    elif mode == 3:                                 # segment
        return ('(%s and segi %s)' % (obj, segi)) if segi else '(%s)' % obj
    elif mode == 4:                                 # object
        return '(%s)' % obj
    elif mode == 5:                                 # molecule
        return '(bymol (%s))' % atom
    else:                                           # 1 residue / 6 C-alpha
        return '(%s)' % res


def pick_at(ndc_x, ndc_y, aspect):
    """Default tap: residue-level toggle into the active 'sele'."""
    from pymol import cmd
    try:
        best = _pick_atom(ndc_x, ndc_y, aspect)
        if best is None:
            # Empty-space click: empty the active 'sele' (set-mode clear).
            if 'sele' in (cmd.get_names('selections') or []):
                cmd.select('sele', 'none')
                cmd.enable('sele')
            return

        _, obj, chain, resi, resn, segi, name, _sx, _sy = best
        print(' You clicked /%s/%s/%s`%s/%s' % (segi, chain, resn, resi, name))

        # Honor mouse_selection_mode (0 atom, 1 residue, 2 chain, 3 segment,
        # 4 object, 5 molecule, 6 C-alpha) — what a click expands the pick to.
        try:
            mode = int(cmd.get_setting_int('mouse_selection_mode'))
        except Exception:
            mode = 1
        # atom expression reused below for click-to-focus (dof); the mode-scoped
        # commit expression comes from the shared _mode_expr helper.
        atom = '%s and resi %s and name %s' % (obj, resi, name)
        if chain:
            atom += ' and chain %s' % chain
        expr = _mode_expr(best, mode)

        # Toggle into/out of 'sele' (additive — matches Seeker toggle).
        exists = 'sele' in (cmd.get_names('selections') or [])
        already = exists and cmd.count_atoms('(sele) and %s' % expr) > 0
        if already:
            cmd.select('sele', '(sele) and not %s' % expr)
        else:
            cmd.select('sele', '(?sele) or %s' % expr)
        cmd.enable('sele')

        # Click-to-focus: when depth-of-field is on, also aim its focal plane at
        # the clicked atom (the issue's "focus to a picked atom"). Non-intrusive
        # — only fires while metal_dof is enabled; otherwise a click just selects.
        try:
            if int(cmd.get_setting_int('metal_dof')):
                d = _eye_distance('(%s)' % atom)
                if d and d > 0.0:
                    cmd.set('metal_dof_focus', float(d))
        except Exception:
            pass

    except Exception as e:
        print('metal_pick error: %s' % e)


def pick_info_at(ndc_x, ndc_y, aspect):
    """Identify the atom/residue under a long-press WITHOUT changing the
    selection, and write its identity to <tmpdir>/pymol_longpress.json for the
    iOS long-press context menu to read. Empty space -> {"hit": false}.

    Mirrors pick_at's hit logic (shared _pick_atom) but is read-only: it never
    touches 'sele', so opening the context menu doesn't perturb the scene."""
    import json, os, tempfile
    out = {"hit": False}
    try:
        best = _pick_atom(ndc_x, ndc_y, aspect)
        if best is not None:
            _, obj, chain, resi, resn, segi, name, _sx, _sy = best
            # Residue-scoped selection the menu actions operate on (matches the
            # residue expr pick_at builds for mouse_selection_mode 1).
            sel = ('%s and chain %s and resi %s' % (obj, chain, resi)) if chain \
                else ('%s and resi %s' % (obj, resi))
            out = {"hit": True, "obj": obj, "chain": chain, "resi": resi,
                   "resn": resn, "name": name, "sel": sel}
    except Exception as e:
        print('metal_pick pick_info error: %s' % e)
        out = {"hit": False}
    try:
        path = os.path.join(tempfile.gettempdir(), 'pymol_longpress.json')
        with open(path, 'w') as f:
            json.dump(out, f)
    except Exception:
        pass


def hover_preview_at(ndc_x, ndc_y, aspect):
    """Hover PREVIEW (issue #165): highlight what a click WOULD select, without
    committing anything. Runs the same pick + mouse_selection_mode expansion as
    pick_at, but writes the result to the transient '_preselect' selection
    instead of 'sele'. Empty space clears the preview.

    Deliberately touches ONLY '_preselect' — never 'sele' or 'pk1' — so the
    committed selection is untouched as the pointer moves. The renderer draws
    '_preselect' in a distinct color/size BEFORE the committed pink pass, so an
    already-selected residue keeps its committed color under the cursor."""
    from pymol import cmd
    try:
        best = _pick_atom(ndc_x, ndc_y, aspect)
        if best is None:
            # Empty space: clear the preview (leave 'sele' untouched). enable=0:
            # NEVER enable '_preselect' — cmd.enable is exclusive for selections
            # and would DISABLE the committed 'sele', hiding its pink markers
            # (the atoms stay in 'sele', which is why a click still appended).
            # The renderer draws '_preselect' by atom membership regardless of
            # its enabled flag, so the cyan preview still shows.
            cmd.select(_PRESELECT, 'none', enable=0)
            return

        try:
            mode = int(cmd.get_setting_int('mouse_selection_mode'))
        except Exception:
            mode = 1
        # enable=0 and NO cmd.enable — see the note above: enabling '_preselect'
        # would deselect the committed 'sele'. The C++ preselect pass renders it
        # by name/membership regardless of enabled state.
        cmd.select(_PRESELECT, _mode_expr(best, mode), enable=0)
    except Exception as e:
        print('metal_pick hover error: %s' % e)


def hover_design_at(ndc_x, ndc_y, aspect):
    """Design-mode hover: like hover_preview_at, but also writes the residue
    identity (obj / chain / resi / resn) to
    <tmpdir>/pymol_hover_design.json so the Swift design controller can
    identify the residue under the cursor for the propensity pill row.
    Writes {"hit": false} when the pointer is over empty space.
    Also updates _preselect for the cyan hover-glow visual feedback."""
    import json, os, tempfile
    from pymol import cmd
    out = {"hit": False}
    try:
        best = _pick_atom(ndc_x, ndc_y, aspect)
        if best is None:
            cmd.select(_PRESELECT, 'none', enable=0)
        else:
            _, obj, chain, resi, resn, segi, name, _sx, _sy = best
            out = {"hit": True, "obj": obj, "chain": chain,
                   "resi": resi, "resn": resn}
            try:
                mode = int(cmd.get_setting_int('mouse_selection_mode'))
            except Exception:
                mode = 1
            cmd.select(_PRESELECT, _mode_expr(best, mode), enable=0)
    except Exception as e:
        print('metal_pick hover_design error: %s' % e)
    try:
        path = os.path.join(tempfile.gettempdir(), 'pymol_hover_design.json')
        with open(path, 'w') as f:
            json.dump(out, f)
    except Exception:
        pass
