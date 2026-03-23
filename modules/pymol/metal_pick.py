"""Screen-to-world unprojection for Metal picking."""
import math

def pick_at(ndc_x, ndc_y, aspect):
    """Select the nearest atom to the screen position.

    Args:
        ndc_x: normalized device coordinate X [-1, 1]
        ndc_y: normalized device coordinate Y [-1, 1]
        aspect: viewport width / height
    """
    from pymol import cmd

    try:
        v = cmd.get_view()
        if not v:
            return

        # Rotation matrix (3x3, row-major in PyMOL's get_view)
        R = [
            [v[0], v[1], v[2]],
            [v[3], v[4], v[5]],
            [v[6], v[7], v[8]],
        ]

        # Camera position in eye space (translation after rotation)
        tx, ty, tz = v[9], v[10], v[11]

        # Origin (center of rotation) in world space
        ox, oy, oz = v[12], v[13], v[14]

        # Compute eye-space offset from screen coordinates
        fov = cmd.get_setting_float('field_of_view')
        dist = abs(tz)
        half_h = dist * math.tan(math.radians(fov / 2.0))
        half_w = half_h * aspect

        # Eye-space point (offset from camera along near plane)
        ex = ndc_x * half_w
        ey = ndc_y * half_h

        # Eye-to-world transform:
        # Point in eye space relative to camera
        px = ex - tx
        py = ey - ty
        pz = 0.0  # on the focal plane (z = -tz + tz = 0 relative to origin depth)

        # Rotate by inverse (transpose) of R to get world offset
        wx = R[0][0] * px + R[1][0] * py + R[2][0] * pz + ox
        wy = R[0][1] * px + R[1][1] * py + R[2][1] * pz + oy
        wz = R[0][2] * px + R[1][2] * py + R[2][2] * pz + oz

        # Create a temporary pseudoatom at the unprojected point,
        # then select the nearest real atom within range
        cmd.pseudoatom('_pick_tmp', pos=[wx, wy, wz])
        n = cmd.select('sele', 'first (all and not _pick_tmp) within 5 of _pick_tmp')
        if n == 0:
            n = cmd.select('sele', 'first (all and not _pick_tmp) within 10 of _pick_tmp')
        cmd.delete('_pick_tmp')

    except Exception as e:
        try:
            with open('/tmp/pymol_pick.log', 'a') as f:
                f.write('pick_at error: %s\n' % e)
        except:
            pass
