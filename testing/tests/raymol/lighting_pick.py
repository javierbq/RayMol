'''
Surface pick (#614): pymol.metal_pick.surface_at against a live core.

The camera is pinned so every expected hit is closed-form (same camera as
raymol/metal_pick.py):

    rotation = identity, origin = (0,0,0), camera at world z = +100 looking
    down -Z, slab [50, 150], field of view 20 deg, viewport 400 x 300.

The ray through NDC (x, y) starts at the eye (0, 0, 100) with direction

    (x * T * aspect, y * T, -1),   T = tan(tan(radians(10)))

(the renderer's glm::perspective(GetFovWidth) takes tan of half its argument,
see metal_pick.camera), so a point on it at eye depth D is eye + D * dir.

These run under the GLUT/headless core (no Metal): the pick evaluates the
Metal renderer's clip rules from settings, never from GL, so CI checks exactly
what the app does.

Surfaces and cartoons with no closed form (1rx1) are checked against a
brute-force ray-triangle reference built from the object's OBJ export
(ObjMesh), under the orient view and a rotated one.
'''

import math

from pymol import cmd, testing, metal_pick, CmdException

VIEW = (1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
        0.0, 0.0, -100.0,
        0.0, 0.0, 0.0,
        50.0, 150.0, -20.0)

EYE = (0.0, 0.0, 100.0)
FRONT, BACK = 50.0, 150.0
T = math.tan(math.tan(math.radians(10.0)))


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def norm(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = norm(a)
    return tuple(x / n for x in a)


def angle_deg(a, b):
    c = dot(unit(a), unit(b))
    return math.degrees(math.acos(max(-1.0, min(1.0, c))))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0])


def _numpy():
    try:
        import numpy
        return numpy
    except ImportError:
        return None


class ObjMesh(object):
    '''The triangles of a `geometry_export_mode 1` OBJ export, moved back into
    model space, with their per-corner normals: a brute-force reference for
    the pick. The export walks the same CPU geometry the pick reads (the ray
    tracer's source), so this checks the pick's maths and its per-op walk,
    not Metal-only behaviour.'''

    def __init__(self, path, offset):
        V, N, faces = [], [], []
        with open(path) as handle:
            for line in handle:
                tag = line.split(' ', 1)[0]
                if tag == 'v':
                    V.append(tuple(float(t) - o for t, o in
                                   zip(line.split()[1:4], offset)))
                elif tag == 'vn':
                    N.append(tuple(float(t) for t in line.split()[1:4]))
                elif tag == 'f':
                    corners = [c.split('/') for c in line.split()[1:4]]
                    faces.append(
                        ([int(c[0]) - 1 for c in corners],
                         [int(c[2]) - 1 if len(c) > 2 and c[2] else -1
                          for c in corners]))
        self.tris, self.normals = [], []
        used = set()
        for vi, ni in faces:
            used.update(vi)
            p = [V[i] for i in vi]
            if norm(cross(sub(p[1], p[0]), sub(p[2], p[0]))) < 1e-10:
                continue  # degenerate
            self.tris.append(p)
            self.normals.append([N[i] if i >= 0 else None for i in ni])
        # Vertices no face uses: what the export keeps of spheres (centres).
        self.markers = [V[i] for i in range(len(V)) if i not in used]
        np = _numpy()
        self.np_tris = np.array(self.tris, dtype=float) if np else None

    def first_hit(self, o, d, lo, hi):
        '''(s, u, v, index) of the nearest crossing of o + s d with
        lo <= s <= hi (Moller-Trumbore, double-sided), or None.'''
        np = _numpy()
        if np is not None and self.np_tris is not None and len(self.tris):
            o = np.asarray(o, dtype=float)
            d = np.asarray(d, dtype=float)
            v0 = self.np_tris[:, 0]
            e1 = self.np_tris[:, 1] - v0
            e2 = self.np_tris[:, 2] - v0
            p = np.cross(d, e2)
            det = (e1 * p).sum(1)
            ok = np.abs(det) > 1e-12
            inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
            t = o - v0
            u = (t * p).sum(1) * inv
            q = np.cross(t, e1)
            v = (q * d).sum(1) * inv
            s = (e2 * q).sum(1) * inv
            m = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (s >= lo) & (s <= hi)
            if not m.any():
                return None
            i = int(np.argmin(np.where(m, s, np.inf)))
            return float(s[i]), float(u[i]), float(v[i]), i
        best = None
        for i, (v0, v1, v2) in enumerate(self.tris):
            e1, e2 = sub(v1, v0), sub(v2, v0)
            p = cross(d, e2)
            det = dot(e1, p)
            if abs(det) < 1e-12:
                continue
            t = sub(o, v0)
            u = dot(t, p) / det
            if u < 0 or u > 1:
                continue
            q = cross(t, e1)
            v = dot(d, q) / det
            if v < 0 or u + v > 1:
                continue
            s = dot(e2, q) / det
            if lo <= s <= hi and (best is None or s < best[0]):
                best = (s, u, v, i)
        return best

    def oriented_normal(self, hit, d):
        '''The reference's smooth normal at a first_hit, turned toward the
        camera the way the pick turns it (inside = back face).'''
        s, u, v, i = hit
        v0, v1, v2 = self.tris[i]
        g = cross(sub(v1, v0), sub(v2, v0))
        ns = self.normals[i]
        if any(n is None for n in ns):
            n = g if dot(g, d) < 0 else tuple(-c for c in g)
            return unit(n)
        w = 1.0 - u - v
        n = tuple(w * ns[0][k] + u * ns[1][k] + v * ns[2][k] for k in range(3))
        if dot(g, n) < 0:
            g = tuple(-c for c in g)
        if dot(g, d) > 0:
            n = tuple(-c for c in n)
        return unit(n)


class PickCase(testing.PyMOLTestCase):
    '''Pinned camera and helpers; no tests of its own.'''

    def setUp(self):
        super(PickCase, self).setUp()
        cmd.viewport(400, 300)
        self.width, self.height = cmd.get_viewport()
        cmd.set('async_builds', 0)
        cmd.set_view(VIEW)

    # -- camera ------------------------------------------------------------

    def aspect(self):
        return float(self.width) / float(self.height)

    def ray_dir(self, x, y):
        return (x * T * self.aspect(), y * T, -1.0)

    def ndc_of(self, p):
        '''NDC of a world point under the pinned perspective camera.'''
        depth = EYE[2] - p[2]
        return (p[0] / (depth * T * self.aspect()), p[1] / (depth * T))

    def project(self, p):
        '''(ndc_x, ndc_y, depth) of a world point under the CURRENT camera,
        through metal_pick.camera() (the atom pick's projection).'''
        cam = metal_pick.camera()
        dd = sub(p, cam.origin)
        eye = [sum(cam.rot[3 * k + i] * dd[i] for i in range(3)) + cam.pos[k]
               for k in range(3)]
        half_h = -eye[2] * cam.tan_half
        return (eye[0] / (half_h * self.aspect()), eye[1] / half_h, -eye[2])

    def world_ray(self, x, y):
        '''(o, d) of the camera ray through (x, y) under the CURRENT camera:
        the world point at eye depth D is o + D * d.'''
        cam = metal_pick.camera()
        d_eye = (x * cam.tan_half * self.aspect(), y * cam.tan_half, -1.0)
        o = tuple(sum(cam.rot[3 * k + i] * -cam.pos[k] for k in range(3)) +
                  cam.origin[i] for i in range(3))
        d = tuple(sum(cam.rot[3 * k + i] * d_eye[k] for k in range(3))
                  for i in range(3))
        return o, d

    def eye_depth(self, p):
        cam = metal_pick.camera()
        dd = sub(p, cam.origin)
        return -(sum(cam.rot[6 + i] * dd[i] for i in range(3)) + cam.pos[2])

    def assertOnWorldRay(self, hit, x, y, tol=1e-3):
        o, d = self.world_ray(x, y)
        expect = tuple(o[i] + hit.depth * d[i] for i in range(3))
        self.assertLess(norm(sub(hit.point, expect)), tol,
                        'hit %r is not on the ray (expected %r)' %
                        (hit.point, expect))

    def box_points(self, selection, n=4, inset=0.1):
        '''An n x n grid of NDC points over the central part of the
        selection's projected bounding box.'''
        ndc = [self.project(p)[:2] for p in cmd.get_coords(selection)]
        x0, x1 = min(p[0] for p in ndc), max(p[0] for p in ndc)
        y0, y1 = min(p[1] for p in ndc), max(p[1] for p in ndc)
        x0, x1 = x0 + inset * (x1 - x0), x1 - inset * (x1 - x0)
        y0, y1 = y0 + inset * (y1 - y0), y1 - inset * (y1 - y0)
        return [(x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * j / (n - 1))
                for i in range(n) for j in range(n)]

    def export_mesh(self, name):
        '''ObjMesh of object `name` alone, exported under the current view.'''
        enabled = cmd.get_names('objects', enabled_only=1)
        cmd.disable('all')
        try:
            # geometry_export_mode 1 writes model coordinates shifted by an
            # offset (today (0, 0, -pos.z); proposed follow-up): measure it
            # with a lone probe sphere so the test survives the fix.
            probe = (1.0, 2.0, 3.0)
            cmd.pseudoatom('lt614probe', pos=list(probe), vdw=1.5)
            cmd.show_as('surface', 'lt614probe')
            cmd.set('geometry_export_mode', 1)
            with testing.mktemp('.obj') as path:
                cmd.save(path)
                mesh = ObjMesh(path, (0.0, 0.0, 0.0))
            pts = [p for t in mesh.tris for p in t]
            centre = tuple(sum(p[k] for p in pts) / len(pts) for k in range(3))
            offset = sub(centre, probe)
            cmd.delete('lt614probe')
            cmd.enable(name)
            with testing.mktemp('.obj') as path:
                cmd.save(path)
                return ObjMesh(path, offset)
        finally:
            cmd.delete('lt614probe')
            cmd.set('geometry_export_mode', 0)
            for n in enabled:
                cmd.enable(n)

    def assertMatchesMesh(self, mesh, points, rep, min_hits, depth_tol=0.5,
                          normal_deg=5.0, exclude=None):
        '''Pick every point and compare with the brute-force reference:
        hit/miss agreement away from silhouettes (where a 0.3 A shift of the
        ray changes the reference's answer), depth within depth_tol, the hit
        on its ray and on the mesh, the normal within normal_deg of the
        reference's (camera-facing) smooth normal, facing > 0 unless grazing.
        `exclude(o, d)` skips rays the reference cannot judge.'''
        cam = metal_pick.camera()
        lo, hi = cam.clip_front, cam.clip_back
        hits = 0
        for x, y in points:
            o, d = self.world_ray(x, y)
            if exclude and exclude(o, d):
                continue
            ref = mesh.first_hit(o, d, lo, hi)
            hit = self.pick(x, y)
            depth = ref[0] if ref else -cam.pos[2]
            jx = 0.3 / (depth * cam.tan_half * self.aspect())
            jy = 0.3 / (depth * cam.tan_half)
            stable = all(
                (mesh.first_hit(*(self.world_ray(x + a, y + b) + (lo, hi)))
                 is None) == (ref is None)
                for a, b in ((jx, 0), (-jx, 0), (0, jy), (0, -jy)))
            if stable:
                self.assertEqual(hit is None, ref is None,
                                 'hit/miss differs at %r: pick %r, ref %r' %
                                 ((x, y), hit, ref))
            if hit is None or ref is None:
                continue
            hits += 1
            self.assertEqual(hit.rep, rep)
            self.assertAlmostEqual(hit.depth, ref[0], delta=depth_tol)
            self.assertOnWorldRay(hit, x, y)
            p_ref = tuple(o[i] + ref[0] * d[i] for i in range(3))
            self.assertLess(norm(sub(hit.point, p_ref)), depth_tol)
            n_ref = mesh.oriented_normal(ref, d)
            self.assertNormalNear(hit, n_ref, normal_deg)
            v = unit(tuple(-c for c in d))
            if dot(n_ref, v) > 0.1:
                self.assertGreater(hit.facing, 0.0)
            self.assertAlmostEqual(norm(hit.normal), 1.0, delta=1e-4)
        self.assertGreaterEqual(hits, min_hits,
                                'too few hits to compare (%d)' % hits)
        return hits

    def ray_sphere(self, x, y, c, r):
        '''(point, depth) where the ray through (x, y) enters sphere (c, r).'''
        d = self.ray_dir(x, y)
        oc = sub(EYE, c)
        a = dot(d, d)
        b = 2.0 * dot(oc, d)
        k = dot(oc, oc) - r * r
        disc = b * b - 4 * a * k
        self.assertGreaterEqual(disc, 0.0, 'test geometry: ray misses')
        lam = (-b - math.sqrt(disc)) / (2 * a)
        return tuple(EYE[i] + lam * d[i] for i in range(3)), lam

    # -- scene -------------------------------------------------------------

    def ball(self, name, pos, vdw=2.0, rep='spheres'):
        cmd.pseudoatom(name, pos=list(pos), vdw=vdw)
        cmd.show_as(rep, name)
        return name

    def stick(self, name, p1, p2):
        cmd.pseudoatom(name, name='A1', pos=list(p1))
        cmd.pseudoatom(name, name='A2', pos=list(p2))
        cmd.bond('%s and name A1' % name, '%s and name A2' % name)
        cmd.show_as('sticks', name)
        return name

    def pick(self, x, y, **kw):
        kw.setdefault('aspect', self.aspect())
        return metal_pick.surface_at(x, y, **kw)

    # -- assertions --------------------------------------------------------

    def assertHit(self, hit):
        self.assertIsNotNone(hit, 'expected a hit')
        self.assertIsInstance(hit, metal_pick.SurfaceHit)

    def assertOnRay(self, hit, x, y, tol=1e-3):
        '''The hit lies on the camera ray through (x, y) at its depth.'''
        d = self.ray_dir(x, y)
        expect = tuple(EYE[i] + hit.depth * d[i] for i in range(3))
        self.assertLess(norm(sub(hit.point, expect)), tol,
                        'hit %r is not on the ray (expected %r)' %
                        (hit.point, expect))

    def assertOriented(self, hit, grazing=False):
        '''facing is reported before the silhouette nudge, so this can fail.'''
        self.assertAlmostEqual(norm(hit.normal), 1.0, delta=1e-4)
        if grazing:
            self.assertGreaterEqual(hit.facing, -1e-6)
        else:
            self.assertGreater(hit.facing, 0.0)

    def assertNormalNear(self, hit, expected, deg):
        self.assertLessEqual(angle_deg(hit.normal, expected), deg,
                             'normal %r vs expected %r' % (hit.normal, expected))


class TestSpheres(PickCase):

    C = (0.0, 0.0, 0.0)
    R = 2.0

    def setUp(self):
        super(TestSpheres, self).setUp()
        self.ball('ball', self.C, vdw=self.R)

    def check_sphere_point(self, x, y, c=C, r=R):
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'ball')
        self.assertEqual(hit.rep, 'spheres')
        self.assertEqual(hit.state, 1)
        self.assertFalse(hit.inside)
        self.assertFalse(hit.cap)
        self.assertAlmostEqual(norm(sub(hit.point, c)), r, delta=1e-3)
        self.assertNormalNear(hit, sub(hit.point, c), 0.5)
        self.assertOnRay(hit, x, y)
        self.assertOriented(hit)
        expect, depth = self.ray_sphere(x, y, c, r)
        self.assertLess(norm(sub(hit.point, expect)), 1e-3)
        self.assertAlmostEqual(hit.depth, depth, delta=1e-3)
        # Cross-check the native camera against metal_pick.camera(), the
        # projection the atom pick uses.
        px, py, pdepth = self.project(hit.point)
        self.assertAlmostEqual(px, x, delta=1e-4)
        self.assertAlmostEqual(py, y, delta=1e-4)
        self.assertAlmostEqual(pdepth, hit.depth, delta=1e-3)
        return hit

    def testCentre(self):
        hit = self.check_sphere_point(0.0, 0.0)
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.05)
        self.assertAlmostEqual(hit.facing, 1.0, delta=1e-4)

    def testOffCentrePoints(self):
        for p in [(1.0, 0.0, 0.0), (1.8, 0.0, 0.0), (1.2, 1.2, 0.0),
                  (-1.0, 1.4, 0.0)]:
            self.check_sphere_point(*self.ndc_of(p))

    def testRotatedMovedCamera(self):
        # A general camera: rotated, origin off the sphere, camera moved.
        cmd.origin(position=[1.0, -2.0, 0.5])
        cmd.turn('y', 35)
        cmd.turn('x', -20)
        cmd.move('x', 1.5)
        cmd.move('y', -0.5)
        for p in [(0.0, 0.0, 0.0), (0.5, 0.3, 0.2), (1.2, -0.8, 0.5),
                  (-1.0, 0.6, -0.3)]:
            x, y, _ = self.project(p)
            hit = self.pick(x, y)
            self.assertHit(hit)
            self.assertAlmostEqual(norm(sub(hit.point, self.C)), self.R,
                                   delta=1e-3)
            self.assertNormalNear(hit, sub(hit.point, self.C), 0.5)
            px, py, pdepth = self.project(hit.point)
            self.assertAlmostEqual(px, x, delta=1e-4)
            self.assertAlmostEqual(py, y, delta=1e-4)
            self.assertAlmostEqual(pdepth, hit.depth, delta=1e-3)
            self.assertOriented(hit)
            # The hit is the FRONT of the sphere: nearer than its centre.
            self.assertLess(hit.depth, self.project(self.C)[2])

    def testEmptySpaceIsAMiss(self):
        self.assertIsNone(self.pick(0.9, 0.9))
        self.assertIsNone(self.pick(-0.5, 0.5))

    def testSceneAspectIsTheDefault(self):
        x, y = self.ndc_of((1.2, 1.2, 0.0))
        a = self.pick(x, y)
        b = metal_pick.surface_at(x, y)
        self.assertHit(b)
        self.assertLess(norm(sub(a.point, b.point)), 1e-4)

    def testSphereScale(self):
        cmd.set('sphere_scale', 0.5, 'ball')
        hit = self.check_sphere_point(0.0, 0.0, r=1.0)
        self.assertAlmostEqual(hit.depth, 99.0, delta=1e-3)

    def testFrontMostOfTwoObjectsWins(self):
        cmd.delete('ball')
        self.ball('back', (0.0, 0.0, -20.0))
        self.ball('front', (0.0, 0.0, 20.0))
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'front')
        self.assertAlmostEqual(hit.depth, 78.0, delta=1e-3)
        cmd.hide('spheres', 'front')
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'back')
        self.assertAlmostEqual(hit.depth, 118.0, delta=1e-3)

    def testGrazingHitIsNudgedTowardTheCamera(self):
        # A ray passing the centre at 0.999 r: the true normal is almost
        # perpendicular to the ray (cos = sqrt(1 - 0.999^2) = 0.0447).
        sin_t = 0.999 * self.R / (EYE[2] - self.C[2])
        tx = sin_t / math.sqrt(1.0 - sin_t * sin_t)
        x = tx / (T * self.aspect())
        hit = self.pick(x, 0.0)
        self.assertHit(hit)
        self.assertOriented(hit, grazing=True)
        self.assertLess(hit.facing, 0.05)
        self.assertAlmostEqual(hit.facing, math.sqrt(1 - 0.999 ** 2), delta=2e-3)
        # The nudge lifts facing to 0.05: at most ~3 degrees off radial.
        self.assertNormalNear(hit, sub(hit.point, self.C), 3.1)
        v = unit(tuple(-c for c in self.ray_dir(x, 0.0)))
        self.assertGreaterEqual(dot(hit.normal, v), 0.05 - 1e-4)

    def testPointSpritesAreNotPicked(self):
        cmd.set('sphere_mode', 1)
        self.assertIsNone(self.pick(0.0, 0.0))

    def testTessellatedSpheresArePicked(self):
        cmd.set('sphere_mode', 0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 98.0, delta=0.5)
        self.assertOnRay(hit, 0.0, 0.0)

    def testSphereUseShaderOffTessellates(self):
        # Metal drops mode 9 to triangles only for sphere_use_shader=0; still
        # a hit (Mesh rule).
        cmd.set('sphere_use_shader', 0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 98.0, delta=0.5)

    def testFullyTransparentSpheresAreNotPicked(self):
        cmd.set('sphere_transparency', 1.0, 'ball')
        self.assertIsNone(self.pick(0.0, 0.0))


class TestSticks(PickCase):

    def setUp(self):
        super(TestSticks, self).setUp()
        self.stick('stk', (-3.0, 0.0, 0.0), (3.0, 0.0, 0.0))

    def axis_distance(self, p):
        return math.hypot(p[1], p[2])

    def testBodyHit(self):
        r = cmd.get_setting_float('stick_radius')
        for p in [(0.0, 0.0, 0.0), (1.0, 0.1, 0.0), (-2.0, -0.15, 0.0)]:
            x, y = self.ndc_of(p)
            hit = self.pick(x, y)
            self.assertHit(hit)
            self.assertEqual(hit.rep, 'sticks')
            self.assertEqual(hit.object, 'stk')
            self.assertAlmostEqual(self.axis_distance(hit.point), r, delta=1e-3)
            # Perpendicular to the axis (x), and radial.
            self.assertAlmostEqual(hit.normal[0], 0.0, delta=1e-3)
            self.assertNormalNear(hit, (0.0, hit.point[1], hit.point[2]), 0.5)
            self.assertOnRay(hit, x, y)
            self.assertOriented(hit)
        hit = self.pick(0.0, 0.0)
        self.assertAlmostEqual(hit.depth, 100.0 - r, delta=1e-3)

    def testRoundCapHit(self):
        r = cmd.get_setting_float('stick_radius')
        end = (3.0, 0.0, 0.0)
        x, y = self.ndc_of((3.15, 0.05, 0.0))
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertGreater(hit.point[0], 3.0)
        self.assertAlmostEqual(norm(sub(hit.point, end)), r, delta=1e-3)
        self.assertNormalNear(hit, sub(hit.point, end), 0.5)
        self.assertOnRay(hit, x, y)
        self.assertOriented(hit)

    def testStickRadiusIsHonoured(self):
        cmd.set('stick_radius', 0.5, 'stk')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 99.5, delta=1e-3)

    def testTessellatedSticksStillHit(self):
        # stick_as_cylinders 0: CGOSimplify triangles on Metal (Mesh rule),
        # within half an Angstrom of the analytic stick.
        cmd.set('stick_as_cylinders', 0)
        r = cmd.get_setting_float('stick_radius')
        for p in [(0.0, 0.0, 0.0), (1.0, 0.1, 0.0)]:
            x, y = self.ndc_of(p)
            hit = self.pick(x, y)
            self.assertHit(hit)
            self.assertLess(abs(self.axis_distance(hit.point) - r), 0.5)
            self.assertOnRay(hit, x, y)
            self.assertOriented(hit)

    def testMissBesideTheStick(self):
        self.assertIsNone(self.pick(*self.ndc_of((0.0, 1.0, 0.0))))
        self.assertIsNone(self.pick(*self.ndc_of((4.0, 0.0, 0.0))))


class TestSlab(PickCase):
    '''The slab is [50, 150] in eye depth; eye depth = 100 - z.'''

    def testInFrontOfTheSlabIsNotPicked(self):
        self.ball('near', (0.0, 0.0, 60.0))     # depth 40
        self.ball('mid', (0.0, 0.0, 0.0))       # depth 100
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)

    def testBehindTheSlabIsNotPicked(self):
        self.ball('far', (0.0, 0.0, -60.0))     # depth 160
        self.assertIsNone(self.pick(0.0, 0.0))

    # -- spheres straddling the front plane --------------------------------

    def testStraddlingSphereIsSeeThrough(self):
        self.ball('cut', (0.0, 0.0, 50.0))      # centre on the front plane
        self.assertIsNone(self.pick(0.0, 0.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)

    def assertCap(self, hit, obj):
        self.assertHit(hit)
        self.assertEqual(hit.object, obj)
        self.assertTrue(hit.cap)
        self.assertFalse(hit.inside)
        self.assertAlmostEqual(hit.depth, FRONT, delta=1e-3)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.01)
        self.assertGreater(hit.facing, 0.0)
        self.assertOnRay(hit, 0.0, 0.0)

    def testInteriorCapOnStraddlingSphere(self):
        self.ball('cut', (0.0, 0.0, 50.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        self.assertCap(self.pick(0.0, 0.0), 'cut')

    def testNoCapOnTransparentSphere(self):
        self.ball('cut', (0.0, 0.0, 50.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        cmd.set('sphere_transparency', 0.5, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')
        self.assertFalse(hit.cap)

    # -- a stick straddling the front plane --------------------------------

    def testStraddlingStickIsSeeThrough(self):
        self.stick('cut', (-3.0, 0.0, 50.0), (3.0, 0.0, 50.0))
        self.assertIsNone(self.pick(0.0, 0.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')

    def testInteriorCapOnStraddlingStick(self):
        self.stick('cut', (-3.0, 0.0, 50.0), (3.0, 0.0, 50.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertCap(hit, 'cut')
        self.assertEqual(hit.rep, 'sticks')

    def testNoCapOnTransparentStick(self):
        self.stick('cut', (-3.0, 0.0, 50.0), (3.0, 0.0, 50.0))
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        cmd.set('stick_transparency', 0.5, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')
        self.assertFalse(hit.cap)

    # -- a surface straddling the front plane ------------------------------

    def testStraddlingSurfaceShowsItsInside(self):
        # A mesh: the inside of the far wall shows (Metal culls nothing).
        self.ball('cut', (0.0, 0.0, 50.0), rep='surface')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.rep, 'surface')
        self.assertTrue(hit.inside)
        self.assertFalse(hit.cap)
        self.assertAlmostEqual(hit.depth, 52.0, delta=0.5)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 15.0)
        self.assertOriented(hit)
        self.assertOnRay(hit, 0.0, 0.0)

    def testInteriorCapOnStraddlingSurface(self):
        # Stencil-parity cap at the near plane (no per-rep clip).
        self.ball('cut', (0.0, 0.0, 50.0), rep='surface')
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertCap(hit, 'cut')
        self.assertEqual(hit.rep, 'surface')

    def testNoCapOnTransparentSurface(self):
        self.ball('cut', (0.0, 0.0, 50.0), rep='surface')
        cmd.set('metal_interior_cap', 1, 'cut')
        cmd.set('transparency', 0.5, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertFalse(hit.cap)
        self.assertTrue(hit.inside)
        self.assertAlmostEqual(hit.depth, 52.0, delta=0.5)

    def testTessellatedStraddlingSphereShowsItsInside(self):
        # Mesh rule: Metal culls nothing, so a clipped triangle sphere shows
        # the inside of its far wall -- reported inside, normal flipped
        # toward the camera.
        cmd.set('sphere_mode', 0)
        self.ball('cut', (0.0, 0.0, 50.0))
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'cut')
        self.assertTrue(hit.inside)
        self.assertFalse(hit.cap)
        self.assertAlmostEqual(hit.depth, 52.0, delta=0.5)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 5.0)
        self.assertOriented(hit)


class TestSurface(PickCase):

    R = 2.0

    def testSingleAtom(self):
        # The solvent-excluded surface of one atom is its vdW sphere,
        # tessellated: within half an Angstrom, the normal near radial.
        self.ball('one', (0.0, 0.0, 0.0), vdw=self.R, rep='surface')
        for p in [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (1.4, 0.9, 0.0),
                  (-0.8, -1.2, 0.0), (0.3, 1.6, 0.0)]:
            x, y = self.ndc_of(p)
            hit = self.pick(x, y)
            self.assertHit(hit)
            self.assertEqual(hit.rep, 'surface')
            self.assertEqual(hit.object, 'one')
            self.assertFalse(hit.inside)
            self.assertFalse(hit.cap)
            self.assertLess(abs(norm(hit.point) - self.R), 0.5)
            self.assertNormalNear(hit, hit.point, 15.0)
            self.assertOnRay(hit, x, y)
            self.assertOriented(hit)
        self.assertIsNone(self.pick(*self.ndc_of((2.6, 0.0, 0.0))))

    def pair(self):
        # Two overlapping atoms in ONE object, so the surface around B is
        # built (and then hidden by atom visibility), not left out.
        cmd.pseudoatom('pair', name='A', pos=[-1.25, 0.0, 0.0], vdw=self.R)
        cmd.pseudoatom('pair', name='B', pos=[1.25, 0.0, 0.0], vdw=self.R)
        cmd.show_as('surface', 'pair')

    def testHiddenAtomsHideTheirPatch(self):
        self.pair()
        x, y = self.ndc_of((2.5, 0.0, 0.0))
        before = self.pick(x, y)
        self.assertHit(before)
        self.assertGreater(before.point[0], 2.0)
        cmd.hide('surface', 'pair and name B')
        after = self.pick(x, y)
        if after is not None:
            self.assertGreater(norm(sub(after.point, before.point)), 1.0)
        # A's own patch is still there.
        self.assertHit(self.pick(*self.ndc_of((-2.5, 0.0, 0.0))))

    def testProximityDecidesTheBoundaryTriangles(self):
        # The triangles across the A/B boundary exist and are filtered at
        # pick time: surface_proximity 1 shows a triangle with ANY visible
        # corner, 0 only one with ALL corners visible. Along a line across
        # the junction, proximity 1 must give strictly more front hits.
        self.pair()
        cmd.hide('surface', 'pair and name B')
        counts = []
        for prox in (0, 1):
            cmd.set('surface_proximity', prox, 'pair')
            n = 0
            for i in range(15):
                hit = self.pick(*self.ndc_of((-0.7 + 1.4 * i / 14, 0.0, 0.0)))
                if hit is not None and not hit.inside:
                    n += 1
            counts.append(n)
        self.assertGreater(counts[1], counts[0])

    def load_fragment(self):
        cmd.load(self.datafile('1rx1.pdb'), 'rx')
        cmd.remove('rx and not (polymer and resi 1-40)')
        cmd.show_as('surface', 'rx')
        cmd.orient('rx')

    def testMatchesTheExportedSurface(self):
        self.load_fragment()
        for view in range(2):
            if view:
                cmd.turn('y', 70)
                cmd.turn('x', 35)
            mesh = self.export_mesh('rx')
            self.assertGreater(len(mesh.tris), 1000)
            self.assertMatchesMesh(mesh, self.box_points('rx'), 'surface',
                                   min_hits=8)

    def rep_clip(self, obj, ff, bb):
        '''metalApplyRepClip's eye-depth planes, recomputed from the atoms.'''
        depths = [self.eye_depth(p) for p in cmd.get_coords(obj)]
        pad = cmd.get_setting_float('solvent_radius', obj) + 1.0
        centre = 0.5 * (min(depths) + max(depths))
        half = 0.5 * (max(depths) - min(depths)) + pad
        return centre - half * (1.0 - ff), centre + half * (1.0 - bb)

    def testPerRepClipFront(self):
        self.load_fragment()
        points = self.box_points('rx', n=5)
        front, _ = self.rep_clip('rx', 0.5, 0.0)
        cmd.set('surface_clip_front', 0.5, 'rx')
        inside = 0
        for x, y in points:
            hit = self.pick(x, y)
            if hit is None:
                continue
            self.assertGreaterEqual(hit.depth, front - 2e-3)
            self.assertOnWorldRay(hit, x, y)
            inside += hit.inside
        self.assertGreater(inside, 0, 'the cut should expose the inside')
        # With the interior cap, the cut is filled at the per-rep front.
        cmd.set('metal_interior_cap', 1, 'rx')
        caps = 0
        for x, y in points:
            hit = self.pick(x, y)
            if hit is None:
                continue
            self.assertGreaterEqual(hit.depth, front - 2e-3)
            if hit.cap:
                caps += 1
                self.assertAlmostEqual(hit.depth, front, delta=2e-3)
                self.assertOriented(hit)
        self.assertGreater(caps, 0)

    def testPerRepClipBack(self):
        self.load_fragment()
        points = self.box_points('rx', n=5)
        _, back = self.rep_clip('rx', 0.0, 0.9)
        deep = [p for p in points
                if self.pick(*p) is not None and self.pick(*p).depth > back]
        self.assertTrue(deep, 'test setup: no hit beyond the back plane')
        cmd.set('surface_clip_back', 0.9, 'rx')
        for x, y in points:
            hit = self.pick(x, y)
            if hit is not None:
                self.assertLessEqual(hit.depth, back + 2e-3)
        for p in deep:
            self.assertIsNone(self.pick(*p))

    def testPerRepClipOnOneAtom(self):
        # Closed form: one atom at depth 100, pad = solvent_radius + 1 = 2.4.
        # front = 100 - 2.4 * (1 - ff), back = 100 + 2.4 * (1 - bb).
        self.ball('one', (0.0, 0.0, 0.0), vdw=self.R, rep='surface')
        pad = cmd.get_setting_float('solvent_radius') + 1.0
        cmd.set('surface_clip_front', 0.5, 'one')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.inside)          # the far wall, from inside
        self.assertAlmostEqual(hit.depth, 102.0, delta=0.5)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 15.0)
        cmd.set('surface_clip_back', 0.5, 'one')
        self.assertIsNone(self.pick(0.0, 0.0))  # both walls cut away
        cmd.set('metal_interior_cap', 1, 'one')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.assertAlmostEqual(hit.depth, 100.0 - 0.5 * pad, delta=1e-3)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.01)
        self.assertOnRay(hit, 0.0, 0.0)
        # The cut disc has radius sqrt(R^2 - (0.5 pad)^2) = 1.6; beyond it
        # the band of the sphere between the two planes shows as usual.
        x, y = self.ndc_of((1.9, 0.0, 0.0))
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertFalse(hit.cap)
        self.assertFalse(hit.inside)
        self.assertGreater(hit.depth, 100.0 - 0.5 * pad)
        self.assertLess(hit.depth, 100.0 + 0.5 * pad)
        self.assertOnRay(hit, x, y)
        # The planes follow the view (the cached depth range is per view).
        cmd.move('z', -10.0)
        atom_depth = -cmd.get_view()[11]
        self.assertAlmostEqual(atom_depth, 110.0, delta=1e-3)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.assertAlmostEqual(hit.depth, atom_depth - 0.5 * pad, delta=1e-3)

    def testRecolorKeepsTheGrid(self):
        # Colour and transparency recolor the rep in place: the grid stays,
        # and what recolor decides (here: invisible) is read at pick time.
        self.ball('one', (0.0, 0.0, 0.0), vdw=self.R, rep='surface')
        self.assertEqual(metal_pick.surface_warm()['built'], 1)
        cmd.color('red', 'one')
        cmd.set('transparency', 0.5, 'one')
        self.assertEqual(metal_pick.surface_warm()['built'], 0)
        self.assertHit(self.pick(0.0, 0.0))
        cmd.set('transparency', 1.0, 'one')
        self.assertIsNone(self.pick(0.0, 0.0))

    def testSurfaceTypes(self):
        self.ball('one', (0.0, 0.0, 0.0), vdw=self.R, rep='surface')
        for surface_type, picked in [(0, True), (1, False), (2, False),
                                     (3, True), (6, True)]:
            cmd.set('surface_type', surface_type, 'one')
            hit = self.pick(0.0, 0.0)
            if picked:
                self.assertHit(hit)
                self.assertAlmostEqual(hit.depth, 98.0, delta=0.5)
            else:
                self.assertIsNone(hit, 'surface_type %d' % surface_type)


class TestCartoon(PickCase):

    def testMatchesTheExportedCartoon(self):
        cmd.load(self.datafile('1rx1.pdb'), 'rx')
        cmd.remove('rx and not polymer')
        cmd.show_as('cartoon', 'rx')
        cmd.orient('rx')
        for view in range(2):
            if view:
                cmd.turn('y', 70)
                cmd.turn('x', 35)
            mesh = self.export_mesh('rx')
            self.assertGreater(len(mesh.tris), 1000)

            def near_marker(o, d):
                # The export keeps only the centre of a sphere.
                return any(norm(cross(sub(m, o), d)) / norm(d) < 2.0
                           for m in mesh.markers)

            self.assertMatchesMesh(mesh, self.box_points('rx', n=7),
                                   'cartoon', min_hits=8, exclude=near_marker)

    def test1AON(self):
        # 58,870 atoms; correctness only (timing is pick_bench.py's job).
        cmd.load(self.datafile('1aon.pdb.gz'), 'gro')
        cmd.show_as('cartoon', 'gro')
        cmd.orient('gro')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.rep, 'cartoon')
        self.assertEqual(hit.object, 'gro')
        self.assertOnWorldRay(hit, 0.0, 0.0, tol=5e-3)
        self.assertOriented(hit)

    def testFullyTransparentCartoonIsNotPicked(self):
        cmd.fab('AAAAAAAAAAAA', 'pep', ss=1)
        cmd.dss('pep')
        cmd.show_as('cartoon', 'pep')
        cmd.orient('pep')
        points = self.box_points('pep', n=4)
        self.assertTrue(any(self.pick(*p) for p in points))
        cmd.set('cartoon_transparency', 1.0, 'pep')
        self.assertFalse(any(self.pick(*p) for p in points))

    def testWarmReusesTheCartoonGrid(self):
        cmd.fab('AAAAAAAAAAAA', 'pep', ss=1)
        cmd.dss('pep')
        cmd.show_as('cartoon', 'pep')
        cmd.orient('pep')
        first = metal_pick.surface_warm()
        self.assertEqual((first['accels'], first['built']), (1, 1))
        self.assertGreater(first['bytes'], 0)
        self.assertTrue(any(self.pick(*p) for p in self.box_points('pep')))
        self.assertEqual(metal_pick.surface_warm()['built'], 0)

    def testCylindricalHelix(self):
        # The helix becomes a CGO cylinder (tessellated on Metal: Mesh rule).
        cmd.fab('AAAAAAAAAAAAAAAA', 'pep', ss=1)
        cmd.dss('pep')  # fab sets the backbone angles, dss the helix flag
        cmd.show_as('cartoon', 'pep')
        cmd.set('cartoon_cylindrical_helices', 1)
        cmd.orient('pep')
        radius = cmd.get_setting_float('cartoon_helix_radius')
        ca = cmd.get_coords('pep and name CA')
        hits = 0
        for x, y in self.box_points('pep and name CA', n=3, inset=0.25):
            hit = self.pick(x, y)
            if hit is None:
                continue
            hits += 1
            self.assertEqual(hit.rep, 'cartoon')
            self.assertOnWorldRay(hit, x, y)
            self.assertOriented(hit)
            # On the cylinder: not farther from the CA trace than its radius.
            self.assertLess(min(norm(sub(hit.point, p)) for p in ca),
                            radius + 1.0)
        self.assertGreater(hits, 0)

    def testNucleicAcidRingSpheres(self):
        # cartoon_ring_mode 4 draws each base as a sphere (an impostor on
        # Metal; tessellated with cartoon_use_shader off).
        cmd.fnab('ATGCATGC', name='dna', mode='DNA', form='B', dbl_helix=1)
        cmd.show_as('cartoon', 'dna')
        cmd.orient('dna')
        points = [(i / 5.0, j / 5.0) for i in range(-4, 5)
                  for j in range(-4, 5)]

        def count():
            n = 0
            for x, y in points:
                hit = self.pick(x, y)
                if hit is not None:
                    n += 1
                    self.assertEqual(hit.rep, 'cartoon')
                    self.assertOnWorldRay(hit, x, y)
            return n

        cmd.set('cartoon_ring_mode', 0)
        plain = count()
        cmd.set('cartoon_ring_mode', 4)
        spheres = count()
        self.assertGreater(spheres, plain)
        cmd.set('cartoon_use_shader', 0)
        self.assertGreater(count(), plain)


class TestTransforms(PickCase):

    def testObjectTTT(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        cmd.translate([0.0, 0.0, 10.0], object='ball', camera=0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 88.0, delta=1e-3)
        self.assertLess(norm(sub(hit.point, (0.0, 0.0, 12.0))), 1e-3)
        # And off-centre, where it renders.
        x, y = self.ndc_of((1.0, 1.0, 10.0))
        hit = self.pick(x, y)
        self.assertAlmostEqual(norm(sub(hit.point, (0.0, 0.0, 10.0))), 2.0,
                               delta=1e-3)
        self.assertOnRay(hit, x, y)

    def testRotatedTTTRotatesTheNormal(self):
        # A stick along local x, turned 90 degrees about z: it renders along
        # world y, so the body hit's normal has no y component.
        self.stick('stk', (-3.0, 0.0, 0.0), (3.0, 0.0, 0.0))
        cmd.set_object_ttt('stk', [0.0, -1.0, 0.0, 0.0,
                                   1.0, 0.0, 0.0, 0.0,
                                   0.0, 0.0, 1.0, 0.0,
                                   0.0, 0.0, 0.0, 1.0])
        x, y = self.ndc_of((0.1, 1.0, 0.0))
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.normal[1], 0.0, delta=1e-3)
        self.assertAlmostEqual(math.hypot(hit.point[0], hit.point[2]),
                               cmd.get_setting_float('stick_radius'),
                               delta=1e-3)
        self.assertOnRay(hit, x, y)

    def state_matrix_scene(self):
        # 'mob' is drawn at local (5, 0, 0); its state matrix turns it 90
        # degrees about z and lifts it by 10: world centre (0, 5, 10).
        # transform_object records the matrix (and moves the coordinates);
        # alter_state then puts the coordinates back, leaving only the matrix.
        self.ball('mob', (5.0, 0.0, 0.0))
        cmd.transform_object('mob', [0.0, -1.0, 0.0, 0.0,
                                     1.0, 0.0, 0.0, 0.0,
                                     0.0, 0.0, 1.0, 10.0,
                                     0.0, 0.0, 0.0, 1.0], homogenous=1)
        cmd.alter_state(1, 'mob', '(x, y, z) = (5.0, 0.0, 0.0)')
        m = cmd.get_object_matrix('mob', incl_ttt=0)
        ident = (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
        self.assertTrue(any(abs(a - b) > 1e-3 for a, b in zip(m, ident)),
                        'test setup: no state matrix stored (%r)' % (m,))

    def testStateMatrixUnderMatrixMode(self):
        self.state_matrix_scene()
        cmd.set('matrix_mode', 1, 'mob')
        centre = (0.0, 5.0, 10.0)
        x, y = self.ndc_of((0.5, 5.5, 10.0))
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'mob')
        self.assertAlmostEqual(norm(sub(hit.point, centre)), 2.0, delta=1e-3)
        self.assertNormalNear(hit, sub(hit.point, centre), 0.5)
        self.assertOnRay(hit, x, y)

    def testStateMatrixIgnoredWithoutMatrixMode(self):
        self.state_matrix_scene()
        cmd.set('matrix_mode', 0, 'mob')
        self.assertIsNone(self.pick(*self.ndc_of((0.0, 5.0, 10.0))))
        hit = self.pick(*self.ndc_of((5.0, 0.0, 0.0)))
        self.assertHit(hit)
        self.assertEqual(hit.object, 'mob')

    def testOrthoscopic(self):
        cmd.set('orthoscopic', 1)
        cmd.set_view(VIEW[:17] + (20.0,))
        self.assertTrue(cmd.get_setting_int('orthoscopic'))
        self.ball('ball', (0.0, 0.0, 0.0))
        # glm::ortho half-height: max(R_SMALL4, -pos.z) * GetFovWidth / 2.
        h = 100.0 * math.tan(math.radians(10.0))
        wx, wy = 1.0, 0.5
        x, y = wx / (h * self.aspect()), wy / h
        hit = self.pick(x, y)
        self.assertHit(hit)
        z = math.sqrt(4.0 - wx * wx - wy * wy)
        self.assertLess(norm(sub(hit.point, (wx, wy, z))), 1e-3)
        self.assertNormalNear(hit, (wx, wy, z), 0.5)
        self.assertAlmostEqual(hit.depth, 100.0 - z, delta=1e-3)
        self.assertOriented(hit)

    def testTheDisplayedStateIsPicked(self):
        cmd.pseudoatom('multi', pos=[0.0, 0.0, 0.0], vdw=2.0, state=1)
        cmd.pseudoatom('multi', pos=[0.0, 0.0, 20.0], vdw=2.0, state=2)
        cmd.show_as('spheres', 'multi')
        cmd.frame(1)
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.state, 1)
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)
        cmd.frame(2)
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.state, 2)
        self.assertAlmostEqual(hit.depth, 78.0, delta=1e-3)


class TestScope(PickCase):

    def testLinesAndRibbonAreNotPicked(self):
        self.stick('wire', (-3.0, 0.0, 0.0), (3.0, 0.0, 0.0))
        cmd.show_as('lines', 'wire')
        self.assertIsNone(self.pick(0.0, 0.0))
        cmd.show_as('ribbon', 'wire')
        self.assertIsNone(self.pick(0.0, 0.0))

    def testDisabledObjectIsIgnored(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        cmd.disable('ball')
        self.assertIsNone(self.pick(0.0, 0.0))
        cmd.enable('ball')
        self.assertHit(self.pick(0.0, 0.0))

    def testUnderscoreObjectsOnlyWhenListed(self):
        self.ball('_hidden', (0.0, 0.0, 20.0))
        self.ball('ball', (0.0, 0.0, 0.0))
        self.assertEqual(self.pick(0.0, 0.0).object, 'ball')
        hit = self.pick(0.0, 0.0, objects=['_hidden', 'ball'])
        self.assertEqual(hit.object, '_hidden')
        self.assertEqual(self.pick(0.0, 0.0, objects='ball').object, 'ball')

    def testRepsFilter(self):
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        self.ball('ball', (0.0, 0.0, 0.0))
        self.assertEqual(self.pick(0.0, 0.0).rep, 'sticks')
        hit = self.pick(0.0, 0.0, reps=('spheres',))
        self.assertEqual(hit.rep, 'spheres')
        self.assertEqual(hit.object, 'ball')
        self.assertEqual(self.pick(0.0, 0.0, reps='spheres').object, 'ball')
        self.assertIsNone(self.pick(0.0, 0.0, reps=('surface', 'cartoon')))

    def testRepsFilterSkipsASurfaceInFront(self):
        self.ball('shell', (0.0, 0.0, 20.0), rep='surface')
        self.ball('ball', (0.0, 0.0, 0.0))
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.rep, 'surface')
        self.assertEqual(hit.object, 'shell')
        hit = self.pick(0.0, 0.0, reps=('spheres',))
        self.assertEqual(hit.rep, 'spheres')
        self.assertEqual(hit.object, 'ball')

    def testFullyTransparentSurfaceIsIgnored(self):
        self.ball('shell', (0.0, 0.0, 20.0), rep='surface')
        self.ball('ball', (0.0, 0.0, 0.0))
        cmd.set('transparency', 1.0, 'shell')
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'ball')
        cmd.delete('ball')
        self.assertIsNone(self.pick(0.0, 0.0))

    def testBadArguments(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        self.assertRaises(CmdException, self.pick, 0.0, 0.0, reps=('lines',))
        self.assertRaises(CmdException, metal_pick.surface_warm, reps='dots')

    def testNoUpdateSeesOnlyWhatWasBuilt(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        # Nothing has built the rep yet in this headless session.
        self.assertIsNone(self.pick(0.0, 0.0, update=False))
        self.assertHit(self.pick(0.0, 0.0, update=True))
        self.assertHit(self.pick(0.0, 0.0, update=False))

    def snapshot(self):
        names = cmd.get_names('all')
        return {
            'view': cmd.get_view(),
            'names': names,
            'selections': cmd.get_names('selections'),
            'enabled': cmd.get_names('all', enabled_only=1),
            'settings': [cmd.get(s) for s in (
                'sphere_mode', 'grid_mode', 'state', 'matrix_mode',
                'orthoscopic', 'field_of_view', 'metal_interior_cap',
                'stick_radius', 'sphere_scale')],
            'matrices': [cmd.get_object_matrix(n, incl_ttt=0) for n in names
                         if cmd.get_type(n) == 'object:molecule'],
            'ttt': [cmd.get_object_matrix(n, incl_ttt=1) for n in names
                    if cmd.get_type(n) == 'object:molecule'],
            'frame': cmd.get_frame(),
            'atoms': cmd.count_atoms('all'),
        }

    def testPickHasNoSideEffects(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        cmd.select('mysele', 'ball')
        cmd.translate([1.0, 0.0, 0.0], object='stk', camera=0)
        self.pick(0.0, 0.0)              # builds the reps
        before = self.snapshot()
        for x, y in [(0.0, 0.0), (0.1, 0.0), (0.9, 0.9)]:
            self.pick(x, y)
            self.pick(x, y, update=False)
        metal_pick.surface_warm()
        self.assertEqual(self.snapshot(), before)

    def testWarmBuildsOnceAndReports(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        first = metal_pick.surface_warm()
        self.assertEqual(first['accels'], 2)
        self.assertGreater(first['bytes'], 0)
        self.assertEqual(first['built'], 2)
        again = metal_pick.surface_warm()
        self.assertEqual(again['accels'], 2)
        self.assertEqual(again['built'], 0)
        self.assertEqual(again['bytes'], first['bytes'])
        # A pick reuses the warmed grids.
        self.assertHit(self.pick(0.0, 0.0))
        self.assertEqual(metal_pick.surface_warm()['built'], 0)
        # Rebuilding a rep drops its grid with it.
        cmd.set('sphere_scale', 0.5, 'ball')
        self.assertEqual(metal_pick.surface_warm()['built'], 1)

    def testWarmRespectsRepsAndObjects(self):
        self.ball('ball', (0.0, 0.0, 0.0))
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        self.assertEqual(metal_pick.surface_warm(reps='sticks')['accels'], 1)
        self.assertEqual(metal_pick.surface_warm(objects=['ball'])['accels'], 1)
