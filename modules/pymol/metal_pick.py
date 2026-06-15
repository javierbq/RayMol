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
# Atoms whose screen distance² is within this of the closest are treated as
# overlapping under the cursor; among them the front-most (min depth) is picked.
_CLUSTER_NDC2 = 0.0009   # ~0.03 NDC

# Atoms that are actually DRAWN (so a click can't select an invisible atom).
# Per-rep selectors mirror the visRep bitmask. The catch: `show cartoon`/`ribbon`
# OR their bit onto EVERY selected atom (incl. solvent), but the cartoon renderer
# only draws guide/polymer atoms — so cartoon/ribbon are intersected with
# `(polymer or guide)` (flags independent of visRep). Every other rep draws
# exactly the atoms carrying its bit. ('labels' omitted — not pickable geometry.)
# This is strictly better than `not solvent`: a genuinely-shown water (e.g.
# `show nb_spheres, solvent`) stays pickable via its rep clause.
_DRAWN_REPS = ('rep spheres or rep sticks or rep lines or rep nb_spheres or '
               'rep nonbonded or rep surface or rep dots or rep mesh or '
               'rep ellipsoid or ((rep cartoon or rep ribbon) and (polymer or guide))')


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


def _pick_atom(ndc_x, ndc_y, aspect):
    """Project all DRAWN atoms and return the front-most atom under the click as
    (screen_d2, obj, chain, resi, resn, segi, name, sx, sy), or None for empty
    space. Shared by pick_at (residue toggle) and appkit_measure (atom picks)."""
    from pymol import cmd

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
        else:
            # Legacy 18-float layout (what our embedded build returns):
            #   v[0:9]=3x3 ROW-MAJOR rotation, v[9:12]=pos, v[12:15]=origin,
            #   v[15]=front, v[16]=back, v[17]=fov flag.
            r00, r01, r02 = v[0], v[1], v[2]
            r10, r11, r12 = v[3], v[4], v[5]
            r20, r21, r22 = v[6], v[7], v[8]
            tx, ty, tz = v[9], v[10], v[11]
            ox, oy, oz = v[12], v[13], v[14]
            fov_deg = abs(v[17])
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

        best = None  # (screen_d2, obj, chain, resi, resn, segi, name, sx, sy)
        cands = []   # (d2, depth, obj, chain, resi, resn, segi, name, sx, sy)
        ncand = 0    # atoms whose projection fell within the pick radius
        _ext = [1e9, -1e9, 1e9, -1e9]  # projected-NDC extent: sx_min,sx_max,sy_min,sy_max

        for obj in (cmd.get_names('objects', enabled_only=1) or []):
            if obj.startswith('_'):
                continue
            try:
                # Only consider atoms that are actually DRAWN, so a click can't
                # select an invisible atom (e.g. a hidden water under a cartoon).
                # get_model(obj) alone returns EVERY atom; the `visible` selector
                # over-reports because cartoon/ribbon set their visRep bit on all
                # atoms (incl. solvent) though only guide atoms draw — hence the
                # per-rep _DRAWN_REPS filter (see its definition).
                model = cmd.get_model('(%s) and (%s)' % (obj, _DRAWN_REPS))
            except Exception:
                continue
            if not model or not model.atom:
                continue
            for at in model.atom:
                dx = at.coord[0] - ox
                dy = at.coord[1] - oy
                dz = at.coord[2] - oz
                # eye = R*(model-origin) + pos
                ex = r00 * dx + r01 * dy + r02 * dz + tx
                ey = r10 * dx + r11 * dy + r12 * dz + ty
                ez = r20 * dx + r21 * dy + r22 * dz + tz
                depth = -ez                     # camera looks down -Z
                if depth <= 0.01:
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
                if d2 > _MAX_PICK_NDC2:
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
        atom = '%s and resi %s and name %s' % (obj, resi, name)
        if chain:
            atom += ' and chain %s' % chain
        res = ('%s and chain %s and resi %s' % (obj, chain, resi)) if chain \
            else ('%s and resi %s' % (obj, resi))
        if mode == 0:                                   # atom
            expr = '(%s)' % atom
        elif mode == 2:                                 # chain
            expr = ('(%s and chain %s)' % (obj, chain)) if chain else '(%s)' % obj
        elif mode == 3:                                 # segment
            expr = ('(%s and segi %s)' % (obj, segi)) if segi else '(%s)' % obj
        elif mode == 4:                                 # object
            expr = '(%s)' % obj
        elif mode == 5:                                 # molecule
            expr = '(bymol (%s))' % atom
        else:                                           # 1 residue / 6 C-alpha
            expr = '(%s)' % res

        # Toggle into/out of 'sele' (additive — matches Seeker toggle).
        exists = 'sele' in (cmd.get_names('selections') or [])
        already = exists and cmd.count_atoms('(sele) and %s' % expr) > 0
        if already:
            cmd.select('sele', '(sele) and not %s' % expr)
        else:
            cmd.select('sele', '(?sele) or %s' % expr)
        cmd.enable('sele')

    except Exception as e:
        print('metal_pick error: %s' % e)
