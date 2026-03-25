"""Screen-to-world unprojection for Metal picking.

Used by the Metal backend where GL picking (SceneDoXYPick) is unavailable.
Unprojects screen coordinates to world space, finds the nearest atom, creates
a selection. Selection indicators are rendered in C++ by
SceneRenderMetalSelections() in SceneRender.cpp.
"""
import math

# Maximum picking distance in Angstroms — clicks farther than this from any
# atom are treated as empty-space clicks and leave the selection unchanged.
_MAX_PICK_DISTANCE = 20.0


def pick_at(ndc_x, ndc_y, aspect):
    """Select the nearest atom/residue to the screen position.

    When the click lands on empty space (no atom within _MAX_PICK_DISTANCE),
    the function returns immediately without modifying any selection.  This
    avoids the scene-invalidation side effects that the old pseudoatom-based
    approach caused (which would clear the current ``sele``).
    """
    from pymol import cmd

    try:
        v = cmd.get_view()
        if not v:
            return

        R = [
            [v[0], v[1], v[2]],
            [v[3], v[4], v[5]],
            [v[6], v[7], v[8]],
        ]
        tx, ty, tz = v[9], v[10], v[11]
        ox, oy, oz = v[12], v[13], v[14]

        fov = cmd.get_setting_float('field_of_view')
        dist = abs(tz)
        half_h = dist * math.tan(math.radians(fov / 2.0))
        half_w = half_h * aspect

        px = ndc_x * half_w - tx
        py = ndc_y * half_h - ty
        pz = 0.0

        wx = R[0][0] * px + R[1][0] * py + R[2][0] * pz + ox
        wy = R[0][1] * px + R[1][1] * py + R[2][1] * pz + oy
        wz = R[0][2] * px + R[1][2] * py + R[2][2] * pz + oz

        # Find the nearest atom by iterating in pure Python — no pseudoatom
        # creation needed, so clicking empty space causes zero scene changes.
        all_atoms = cmd.get_model('all')
        if not all_atoms or not all_atoms.atom:
            return

        nearest = None
        best_dist = _MAX_PICK_DISTANCE
        for at in all_atoms.atom:
            d = math.sqrt(
                (at.coord[0] - wx)**2 +
                (at.coord[1] - wy)**2 +
                (at.coord[2] - wz)**2)
            if d < best_dist:
                best_dist = d
                nearest = at

        if not nearest:
            return

        chain = nearest.chain or ''
        resi = nearest.resi

        ident = '/%s/%s/%s`%s/%s' % (
            nearest.segi or chain, chain,
            nearest.resn, resi, nearest.name)
        print(' You clicked %s' % ident)

        # Build selection expression
        obj_list = cmd.get_names('objects')
        sele_expr = None
        for obj in obj_list:
            if obj.startswith('_'):
                continue
            try:
                n = cmd.count_atoms(
                    '(%s and chain %s and resi %s)' % (
                        obj, repr(chain), resi))
                if n > 0:
                    sele_expr = '(%s and chain %s and resi %s)' % (
                        obj, repr(chain), resi)
                    break
            except Exception:
                continue

        if sele_expr:
            try:
                existing = cmd.count_atoms('sele')
            except Exception:
                existing = 0

            if existing > 0:
                cmd.select('sele', 'sele or %s' % sele_expr)
            else:
                cmd.select('sele', sele_expr)
            cmd.enable('sele')

    except Exception as e:
        print('metal_pick error: %s' % e)
