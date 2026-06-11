"""Screen-space atom picking for the Metal backend.

GL color-picking (SceneDoXYPick) is unavailable on Metal, so we reproduce its
effect in Python: project every atom of the enabled objects to screen NDC using
the current camera (cmd.get_view), pick the atom whose projection is closest to
the click, and toggle its residue in/out of the active 'sele' (PyMOL's additive
behavior). Selection indicators are drawn in C++ by SceneRenderMetalSelections.
"""
import math

# Screen pick radius (squared, in NDC). Clicks farther than this from any
# atom's projection are treated as empty space and leave 'sele' unchanged.
_MAX_PICK_NDC2 = 0.0100  # ~0.1 NDC radius


def pick_at(ndc_x, ndc_y, aspect):
    from pymol import cmd

    try:
        v = cmd.get_view()
        if not v:
            return

        # 3x3 rotation (rows), camera translation, rotation origin.
        r00, r01, r02, r10, r11, r12, r20, r21, r22 = v[0:9]
        tx, ty, tz = v[9], v[10], v[11]
        ox, oy, oz = v[12], v[13], v[14]

        fov = cmd.get_setting_float('field_of_view')
        tan_half = math.tan(math.radians(fov / 2.0))
        if tan_half <= 0.0 or aspect <= 0.0:
            return

        best = None  # (screen_d2, obj, chain, resi, resn, segi, name)

        # Project the atoms of each enabled object; track the nearest-to-click.
        for obj in (cmd.get_names('objects', enabled_only=1) or []):
            if obj.startswith('_'):
                continue
            try:
                model = cmd.get_model(obj)
            except Exception:
                continue
            if not model or not model.atom:
                continue
            for at in model.atom:
                dx = at.coord[0] - ox
                dy = at.coord[1] - oy
                dz = at.coord[2] - oz
                ex = r00 * dx + r01 * dy + r02 * dz + tx
                ey = r10 * dx + r11 * dy + r12 * dz + ty
                ez = r20 * dx + r21 * dy + r22 * dz + tz
                depth = -ez
                if depth <= 0.01:        # behind the camera
                    continue
                half_h = depth * tan_half
                half_w = half_h * aspect
                sx = ex / half_w
                sy = ey / half_h
                d2 = (sx - ndc_x) ** 2 + (sy - ndc_y) ** 2
                if d2 > _MAX_PICK_NDC2:
                    continue
                if best is None or d2 < best[0]:
                    best = (d2, obj, at.chain or '', at.resi,
                            at.resn, at.segi or (at.chain or ''), at.name)

        if best is None:
            return  # empty-space click — leave selection unchanged

        _, obj, chain, resi, resn, segi, name = best
        print(' You clicked /%s/%s/%s`%s/%s' % (segi, chain, resn, resi, name))

        # Residue-level selection scoped to the picked object.
        if chain:
            expr = '(%s and chain %s and resi %s)' % (obj, chain, resi)
        else:
            expr = '(%s and resi %s)' % (obj, resi)

        # Toggle into/out of 'sele' (additive — matches PyMOL Seeker behavior).
        exists = 'sele' in (cmd.get_names('selections') or [])
        already = exists and cmd.count_atoms('(sele) and %s' % expr) > 0
        if already:
            cmd.select('sele', '(sele) and not %s' % expr)
        else:
            cmd.select('sele', '(?sele) or %s' % expr)
        cmd.enable('sele')

    except Exception as e:
        print('metal_pick error: %s' % e)
