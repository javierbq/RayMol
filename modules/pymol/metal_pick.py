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


def pick_at(ndc_x, ndc_y, aspect):
    from pymol import cmd

    try:
        v = cmd.get_view()
        if not v:
            return

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
        ncand = 0    # atoms whose projection fell within the pick radius
        _ext = [1e9, -1e9, 1e9, -1e9]  # projected-NDC extent: sx_min,sx_max,sy_min,sy_max

        for obj in (cmd.get_names('objects', enabled_only=1) or []):
            if obj.startswith('_'):
                continue
            try:
                # Exclude solvent from picking: get_model(obj) returns EVERY atom
                # (incl. hidden waters), so the screen-nearest one is often an
                # invisible water => "wrong/none residue" selected when clicking a
                # cartoon. (The `visible` selector would be the right filter but
                # is unreliable on this build — it reports all atoms visible — so
                # we exclude solvent explicitly, the dominant offender.)
                model = cmd.get_model('(%s) and not solvent' % obj)
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
                if best is None or d2 < best[0]:
                    best = (d2, obj, at.chain or '', at.resi,
                            at.resn, at.segi or (at.chain or ''), at.name, sx, sy)

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

        if best is None:
            # Empty-space click: empty the active 'sele' (set-mode clear),
            # matching SelectorCreate(name,'none') in the original.
            if 'sele' in (cmd.get_names('selections') or []):
                cmd.select('sele', 'none')
                cmd.enable('sele')
            return

        _, obj, chain, resi, resn, segi, name, _sx, _sy = best
        print(' You clicked /%s/%s/%s`%s/%s' % (segi, chain, resn, resi, name))

        # Residue-level selection scoped to the picked object.
        if chain:
            expr = '(%s and chain %s and resi %s)' % (obj, chain, resi)
        else:
            expr = '(%s and resi %s)' % (obj, resi)

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
