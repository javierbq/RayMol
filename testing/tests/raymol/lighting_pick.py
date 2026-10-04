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
Metal renderer's clip rules from settings, never from GL. The geometry it
reads is the rep's own CGO, and that is the app's only where the build does
not depend on use_shaders. Sticks do: the app forces use_shaders on
(layer5/PyMOL.cpp), and only then does RepCylBond leave a bond's end open at
an atom another bond has already capped. So every stick test turns
use_shaders on before building (PickCase.app_sticks), to build what the app
draws. Spheres, surfaces and cartoons build the same either way at the
settings used here (cartoon_nucleic_acid_as_cylinders & 2, off by default, is
the cartoon's one use_shaders-dependent build).

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


def sphere_roots(o, d, c, r):
    '''(s0, s1), s0 <= s1, where o + s d crosses the sphere (c, r), or None.'''
    oc = sub(o, c)
    a, b, k = dot(d, d), 2.0 * dot(oc, d), dot(oc, oc) - r * r
    disc = b * b - 4.0 * a * k
    if disc < 0.0:
        return None
    q = math.sqrt(disc)
    return (-b - q) / (2.0 * a), (-b + q) / (2.0 * a)


def tube_roots(o, d, p0, u, r):
    '''(s0, s1), s0 <= s1, where o + s d crosses the INFINITE cylinder of
    radius r about the line p0 + t u (u unit), or None (also when the ray is
    parallel to it).'''
    m = sub(o, p0)
    mp = sub(m, tuple(c * dot(m, u) for c in u))
    dp = sub(d, tuple(c * dot(d, u) for c in u))
    a, b, k = dot(dp, dp), dot(mp, dp), dot(mp, mp) - r * r
    if a < 1e-14:
        return None
    disc = b * b - a * k
    if disc < 0.0:
        return None
    q = math.sqrt(disc)
    return (-b - q) / a, (-b + q) / a


def metal_box_kept(p0, p1, r):
    '''Does Metal keep the cylinder impostor's box (p0 to p1, radius r)
    where it lies in front of the near plane, under the pinned camera?
    cyl_impostor_vertex (RendererMetal.mm) moves a box corner in front of the
    plane onto it only when the corner, pushed back by the ends' depth
    difference + 3.5 r, is behind the plane; otherwise that corner is
    clipped. Kept = every corner in front is moved.'''
    axis = sub(p1, p0)
    h = unit(axis)
    uu = cross(h, (1.0, 0.0, 0.0))
    if dot(uu, uu) < 0.001:
        uu = cross(h, (0.0, 1.0, 0.0))
    uu = unit(uu)
    vv = unit(cross(uu, h))
    reach = abs(p1[2] - p0[2]) + 3.5 * r
    nearest = min(
        EYE[2] - (p0[2] + up * axis[2] + right * r * uu[2] + out * r * vv[2]
                  + (2 * up - 1) * r * h[2])
        for up in (0, 1) for right in (-1, 1) for out in (-1, 1))
    return nearest >= FRONT or nearest + reach > FRONT


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

    def app_sticks(self):
        '''Build sticks as the app does. Metal forces use_shaders on, and only
        then does RepCylBond draw each atom's round cap once: the first bond
        at an atom caps it, every later bond leaves its end there open (cap
        bits 0, PickCap::None). Headless, use_shaders is off after
        reinitialize and every end is capped. Set before the sticks build
        (they build at the first pick).'''
        cmd.set('use_shaders', 1)

    def stick(self, name, p1, p2):
        self.app_sticks()
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
        # The nudge turns the normal, in the plane of the radial and the view
        # direction, until it faces the camera by exactly 0.05: here by
        # asin(0.05) - asin(facing), about 0.3 degrees.
        radial = unit(sub(hit.point, self.C))
        turn = math.degrees(math.asin(0.05) - math.asin(hit.facing))
        self.assertAlmostEqual(angle_deg(hit.normal, radial), turn, delta=0.02)
        v = unit(tuple(-c for c in self.ray_dir(x, 0.0)))
        self.assertAlmostEqual(dot(hit.normal, v), 0.05, delta=2e-5)
        self.assertLess(abs(dot(hit.normal, cross(radial, v))), 1e-5)

    def testFacingCameraIsNotNudged(self):
        # The nudge only touches grazing hits: a hit facing the camera by
        # just over 0.05 keeps its radial normal.
        sin_t = math.sqrt(1.0 - 0.06 ** 2) * self.R / (EYE[2] - self.C[2])
        x = sin_t / math.sqrt(1.0 - sin_t * sin_t) / (T * self.aspect())
        hit = self.pick(x, 0.0)
        self.assertHit(hit)
        self.assertGreater(hit.facing, 0.05)
        self.assertNormalNear(hit, sub(hit.point, self.C), 0.05)

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
        # picked against the analytic stick they approximate.
        cmd.set('stick_as_cylinders', 0)
        r = cmd.get_setting_float('stick_radius')
        for p in [(0.0, 0.0, 0.0), (1.0, 0.1, 0.0)]:
            x, y = self.ndc_of(p)
            hit = self.pick(x, y)
            self.assertHit(hit)
            self.assertAlmostEqual(self.axis_distance(hit.point), r, delta=1e-3)
            self.assertGreater(hit.point[2], 0.0, 'the far side was picked')
            self.assertOnRay(hit, x, y)
            self.assertOriented(hit)
        self.assertAlmostEqual(self.pick(0.0, 0.0).depth, 100.0 - r,
                               delta=1e-3)

    def testMissBesideTheStick(self):
        self.assertIsNone(self.pick(*self.ndc_of((0.0, 1.0, 0.0))))
        self.assertIsNone(self.pick(*self.ndc_of((4.0, 0.0, 0.0))))


class TestPointedNub(PickCase):
    '''Tessellated sticks (stick_as_cylinders 0: CGOSimplify triangles on
    Metal) with stick_round_nub off, its default. CGOSimpleCylinder then
    draws a round end as a pointed nub, not a hemisphere: the body runs on
    stick_overlap * r past the atom, then a triangle fan closes it in a cone
    stick_nub * r long, whose vertex normals are radial on the rim and the
    axis at the tip. The reference marches the ray through that solid, so it
    shares no algebra with the pick.'''

    R = 1.0  # a fat stick keeps the nub and the hemisphere far apart

    def setUp(self):
        super(TestPointedNub, self).setUp()
        cmd.set('stick_radius', self.R)
        cmd.set('stick_as_cylinders', 0)
        cmd.set('stick_round_nub', 0)

    def solid(self, p0, p1):
        self.p0, self.p1 = p0, p1
        self.h = norm(sub(p1, p0))
        self.u = tuple(c / self.h for c in sub(p1, p0))
        self.ov = cmd.get_setting_float('stick_overlap') * self.R
        self.tip = cmd.get_setting_float('stick_nub') * self.R

    def part(self, p):
        '''(inside, outward normal) of the drawn solid at p: the body,
        extended by the overlap at both ends, and a cone beyond each end,
        with the fan's normals interpolated by height.'''
        q = sub(p, self.p0)
        z = dot(q, self.u)
        radial = sub(q, tuple(c * z for c in self.u))
        rho = norm(radial)
        lo, hi = -self.ov, self.h + self.ov
        if lo <= z <= hi:
            return rho <= self.R, unit(radial) if rho > 0 else None
        hh, out = (z - hi, 1.0) if z > hi else (lo - z, -1.0)
        if hh > self.tip:
            return False, None
        w = hh / self.tip
        n = tuple(w * out * a + ((1.0 - w) * b / rho if rho > 0 else 0.0)
                  for a, b in zip(self.u, radial))
        return rho <= self.R * (1.0 - w), unit(n)

    def march(self, x, y):
        '''(depth, outward normal) of the first point of the solid on the
        ray through (x, y), or None.'''
        d = self.ray_dir(x, y)

        def inside(t):
            return self.part(tuple(EYE[k] + t * d[k] for k in range(3)))[0]
        t, step, end = 90.0, 0.005, 106.0
        while t < end and not inside(t):
            t += step
        if t >= end:
            return None
        a, b = t - step, t
        for _ in range(40):
            m = 0.5 * (a + b)
            a, b = (a, m) if inside(m) else (m, b)
        return b, self.part(tuple(EYE[k] + b * d[k] for k in range(3)))[1]

    def assertMatchesTheNub(self, points, min_hits):
        hits = 0
        for p in points:
            x, y = self.ndc_of(p)
            ref = self.march(x, y)
            hit = self.pick(x, y)
            where = 'at %r: pick %r, nub %r' % (p, hit, ref)
            self.assertEqual(hit is None, ref is None, where)
            if ref is None:
                continue
            hits += 1
            self.assertEqual(hit.rep, 'sticks')
            self.assertFalse(hit.inside)
            self.assertAlmostEqual(hit.depth, ref[0], delta=1e-3, msg=where)
            self.assertOnRay(hit, x, y)
            self.assertOriented(hit)
            v = unit(tuple(-c for c in self.ray_dir(x, y)))
            self.assertNormalNear(hit, ref[1],
                                  0.1 if dot(ref[1], v) > 0.06 else 3.1)
        self.assertGreaterEqual(hits, min_hits)

    def testAlongTheBond(self):
        # Down the bond at its near end: the centre ray runs along the axis
        # (pickCylinder's parallel case) to the tip, (0.2 + 0.7) r out.
        self.solid((0.0, 0.0, -3.0), (0.0, 0.0, 3.0))
        self.stick('nub', self.p0, self.p1)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 97.0 - self.ov - self.tip,
                               delta=1e-3)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.01)
        points = [(rho * math.cos(a), rho * math.sin(a), 3.0)
                  for rho in (0.1, 0.3, 0.5, 0.7, 0.9)
                  for a in (0.3, 2.2, 4.1)]
        self.assertMatchesTheNub(points, min_hits=15)
        # The hemisphere it replaces is nearer the camera (up to 0.32 r).
        x, y = self.ndc_of((0.5, 0.0, 3.0))
        ball = sphere_roots(EYE, self.ray_dir(x, y), self.p1, self.R)
        self.assertGreater(self.pick(x, y).depth - ball[0], 0.2)

    def testAcrossTheBond(self):
        # From the side: the extended body, the cone narrowing to its tip at
        # x = 3.9, and nothing past it, where a hemisphere would still be.
        self.solid((-3.0, 0.0, 0.0), (3.0, 0.0, 0.0))
        self.stick('nub', self.p0, self.p1)
        points = [(x, y, 0.0) for x in (3.1, 3.3, 3.5, 3.7, 3.85, 3.95)
                  for y in (0.0, 0.25, -0.4)]
        self.assertMatchesTheNub(points, min_hits=12)
        x, y = self.ndc_of((3.95, 0.0, 0.0))
        self.assertIsNotNone(
            sphere_roots(EYE, self.ray_dir(x, y), self.p1, self.R))
        self.assertIsNone(self.pick(x, y))
        # The other end is pointed too.
        self.assertMatchesTheNub([(-3.5, 0.0, 0.0), (-3.3, 0.3, 0.0)], 2)

    def testNubSettingsShapeIt(self):
        self.solid((0.0, 0.0, -3.0), (0.0, 0.0, 3.0))
        self.stick('nub', self.p0, self.p1)
        self.assertHit(self.pick(0.0, 0.0))  # builds the first grid
        cmd.set('stick_nub', 1.5)
        cmd.set('stick_overlap', 0.4)
        self.solid(self.p0, self.p1)
        self.assertAlmostEqual(self.pick(0.0, 0.0).depth,
                               97.0 - 1.9 * self.R, delta=1e-3)
        self.assertMatchesTheNub([(0.4, 0.2, 3.0), (-0.6, 0.3, 3.0)], 2)

    def testRoundNubAndImpostorsDrawAHemisphere(self):
        self.solid((0.0, 0.0, -3.0), (0.0, 0.0, 3.0))
        self.stick('nub', self.p0, self.p1)
        x, y = self.ndc_of((0.5, 0.2, 3.0))
        ball = sphere_roots(EYE, self.ray_dir(x, y), self.p1, self.R)
        pointed = self.pick(x, y).depth
        self.assertGreater(pointed - ball[0], 0.2)
        # stick_round_nub on: CGOSimplify draws a hemisphere (CGORoundNub).
        cmd.set('stick_round_nub', 1)
        self.assertAlmostEqual(self.pick(x, y).depth, ball[0], delta=1e-3)
        cmd.set('stick_round_nub', 0)
        self.assertAlmostEqual(self.pick(x, y).depth, pointed, delta=1e-3)
        # Impostors always draw a hemisphere.
        cmd.set('stick_as_cylinders', 1)
        self.assertAlmostEqual(self.pick(x, y).depth, ball[0], delta=1e-3)


class TestBranchedSticks(PickCase):
    '''Sticks at a branched atom, built as the app builds them (app_sticks):
    CB has three bonds, made in the order CA-CB, CB-CC, CB-CD, so CA-CB caps
    CB and the other two are OPEN there. CB-CC runs along the view axis toward
    the camera; CB-CD leans toward it. In the app nearly every stick of a real
    molecule has such an open end; every other stick test uses lone bonds,
    whose ends are all capped.'''

    REL = (('CA', (-1.45, 0.25, -0.30)), ('CB', (0.0, 0.0, 0.0)),
           ('CC', (0.0, 0.0, 1.5)), ('CD', (0.85, -0.70, 0.95)))
    BONDS = (('CA', 'CB'), ('CB', 'CC'), ('CB', 'CD'))

    def junction(self, z0=0.0, use_shaders=1):
        '''The junction with CB at (0, 0, z0), as object `br`.'''
        cmd.delete('br')
        cmd.set('use_shaders', use_shaders)
        self.pos = {}
        for name, p in self.REL:
            self.pos[name] = (p[0], p[1], p[2] + z0)
            cmd.pseudoatom('br', name=name, pos=list(self.pos[name]))
        for a, b in self.BONDS:
            cmd.bond('br and name %s' % a, 'br and name %s' % b)
        cmd.show_as('sticks', 'br')
        self.r = cmd.get_setting_float('stick_radius')

    def caps(self):
        '''{(bond, atom): capped} as RepCylBond builds it in shader mode: the
        first bond at an atom draws its round cap, later ones leave it open.'''
        seen, caps = set(), {}
        for bond in self.BONDS:
            for atom in bond:
                caps[bond, atom] = atom not in seen
                seen.add(atom)
        return caps

    def grid(self, n, pad=0.3):
        '''n x n ray NDC points over the junction's projected box, padded.'''
        ndc = [self.ndc_of(p) for p in self.pos.values()]
        jx = pad / ((EYE[2] - self.pos['CB'][2]) * T * self.aspect())
        jy = pad / ((EYE[2] - self.pos['CB'][2]) * T)
        x0, x1 = min(p[0] for p in ndc) - jx, max(p[0] for p in ndc) + jx
        y0, y1 = min(p[1] for p in ndc) - jy, max(p[1] for p in ndc) + jy
        return [(x0 + (x1 - x0) * (i + 0.5) / n, y0 + (y1 - y0) * (j + 0.5) / n)
                for i in range(n) for j in range(n)]

    def axis(self, bond):
        p0, p1 = self.pos[bond[0]], self.pos[bond[1]]
        h = norm(sub(p1, p0))
        return p0, tuple(c / h for c in sub(p1, p0)), h

    # -- references ----------------------------------------------------------

    def union_hit(self, d):
        '''The front-most entry into the union of the bonds' capsules (radius
        r): (depth, normal, what), what = an atom name (its ball) or a bond
        (its body); None on a miss. Unclipped, this is what the app shows,
        whichever bond draws each atom's ball.'''
        best = None
        for name, c in self.pos.items():
            roots = sphere_roots(EYE, d, c, self.r)
            if roots and (best is None or roots[0] < best[0]):
                p = tuple(EYE[k] + roots[0] * d[k] for k in range(3))
                best = (roots[0], unit(sub(p, c)), name)
        for bond in self.BONDS:
            p0, u, h = self.axis(bond)
            roots = tube_roots(EYE, d, p0, u, self.r)
            if not roots or (best is not None and roots[0] >= best[0]):
                continue
            q = sub(tuple(EYE[k] + roots[0] * d[k] for k in range(3)), p0)
            z = dot(q, u)
            if 0.0 <= z <= h:
                best = (roots[0], unit(sub(q, tuple(c * z for c in u))), bond)
        return best

    def leaves_through_open_end(self, d, hit):
        '''Does the ray, entering a bond that is open at CB (through its body
        or its other ball), cross that bond's infinite tube for the last time
        beyond CB? Then the pick resolves that crossing as an open end.'''
        caps = self.caps()
        for bond in self.BONDS:
            if 'CB' not in bond or caps[bond, 'CB']:
                continue
            other = bond[0] if bond[1] == 'CB' else bond[1]
            if hit[2] not in (bond, other):
                continue
            p0, u, h = self.axis(bond)
            roots = tube_roots(EYE, d, p0, u, self.r)
            if roots is None:
                return True  # parallel: leaves through an end
            q = sub(tuple(EYE[k] + roots[1] * d[k] for k in range(3)), p0)
            cb_end = 0.0 if bond[0] == 'CB' else h
            z = dot(q, u)
            if (z < 0.0) if cb_end == 0.0 else (z > h):
                return True
        return False

    def metal_hit(self, d, cap_on, round_far='tube'):
        '''What Metal's cylinder impostor draws along the ray (cyl_shade and
        cyl_impostor_vertex, RendererMetal.mm): (depth, cap) or None.
        Per bond: the front crossing of the infinite tube; past an end, that
        end's round cap, or nothing if the end is open (caps()). A point in
        front of the near plane is discarded, unless cap_on and the tube's
        FAR crossing (of the infinite tube, as the shader computes it) is
        behind the plane: then a flat cap at the plane. The nearest wins.

        round_far='ball': where that far crossing lies past a ROUND end, use
        the ball's far crossing instead (the capped solid's exit). That is
        NOT what Metal does; the test uses it to find the rays where the two
        differ, which the pick must still answer as Metal does.'''
        caps = self.caps()
        best = None
        for bond in self.BONDS:
            p0, u, h = self.axis(bond)
            roots = tube_roots(EYE, d, p0, u, self.r)
            if roots is None:
                continue
            front, far = roots
            q = sub(tuple(EYE[k] + front * d[k] for k in range(3)), p0)
            z = dot(q, u)
            if z < 0.0 or z > h:
                atom = bond[0] if z < 0.0 else bond[1]
                if not caps[bond, atom]:
                    continue
                ball = sphere_roots(EYE, d, self.pos[atom], self.r)
                if ball is None:
                    continue
                front = ball[0]
            if round_far == 'ball':
                q = sub(tuple(EYE[k] + far * d[k] for k in range(3)), p0)
                z = dot(q, u)
                if z < 0.0 or z > h:
                    atom = bond[0] if z < 0.0 else bond[1]
                    if caps[bond, atom]:
                        ball = sphere_roots(EYE, d, self.pos[atom], self.r)
                        far = ball[1] if ball else front
            if front <= FRONT:
                if not cap_on or far <= FRONT:
                    continue
                hit = (FRONT, True)
            elif front >= BACK:
                continue
            else:
                hit = (front, False)
            if best is None or hit[0] < best[0]:
                best = hit
        return best

    def assertProxiesStraddle(self):
        '''metal_hit assumes every impostor box survives the near plane
        (metal_box_kept); the pick models the clamp, metal_hit does not.'''
        for bond in self.BONDS:
            self.assertTrue(
                metal_box_kept(self.pos[bond[0]], self.pos[bond[1]], self.r),
                'test geometry: %r' % (bond,))

    # -- tests -----------------------------------------------------------------

    def testOpenEndsAreBuilt(self):
        # Guards the premise that app_sticks builds the app's open ends (the
        # headless default caps every end). The interior cap follows the
        # infinite tube whatever the ends, so only one ray tells them apart
        # here: exactly down CB-CC (NDC 0, 0), parallel to the bond, the tube
        # has no far crossing and the pick falls back to the bond's exit.
        # Through the open end at CB it runs on behind the plane: a cap.
        # Through CB's ball it ends in front of the plane: nothing.
        self.junction(z0=50.4)
        cmd.set('metal_interior_cap', 1, 'br')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.junction(z0=50.4, use_shaders=0)
        cmd.set('metal_interior_cap', 1, 'br')
        self.assertIsNone(self.pick(0.0, 0.0))

    def testMatchesTheCapsuleUnion(self):
        self.junction()
        # Straight down CB-CC: in through CC's ball, out through the open end
        # at CB, so the front is CC's ball, not CB's behind it.
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.rep, 'sticks')
        self.assertAlmostEqual(hit.depth, 100.0 - 1.5 - self.r, delta=1e-3)
        self.assertLess(norm(sub(hit.point, (0.0, 0.0, 1.5 + self.r))), 1e-3)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.05)
        hits = open_exits = 0
        for x, y in self.grid(25):
            d = self.ray_dir(x, y)
            ref = self.union_hit(d)
            hit = self.pick(x, y)
            if (ref is None) != (hit is None):
                # Only a ray grazing a silhouette may disagree.
                jitter = [self.union_hit(self.ray_dir(x + a, y + b)) is None
                          for a, b in ((1e-4, 0), (-1e-4, 0), (0, 1e-4),
                                       (0, -1e-4))]
                self.assertTrue(any(j != (ref is None) for j in jitter),
                                'hit/miss differs at %r: pick %r, union %r' %
                                ((x, y), hit, ref))
                continue
            if ref is None:
                continue
            hits += 1
            open_exits += self.leaves_through_open_end(d, ref)
            self.assertEqual(hit.rep, 'sticks')
            self.assertFalse(hit.cap)
            self.assertFalse(hit.inside)
            self.assertAlmostEqual(hit.depth, ref[0], delta=1e-3,
                                   msg='at %r: %r vs %r' % ((x, y), hit, ref))
            self.assertOnRay(hit, x, y)
            # Grazing normals are nudged toward the camera (at most ~3 deg).
            v = unit(tuple(-c for c in d))
            self.assertNormalNear(hit, ref[1],
                                  0.5 if dot(ref[1], v) > 0.06 else 3.1)
        self.assertGreater(hits, 150)
        # The open-end branch of pickCylinder ran, many times.
        self.assertGreater(open_exits, 15)

    def testNearPlaneThroughTheJunction(self):
        tube_not_ball = 0
        for z0 in (49.6, 50.0, 50.4):
            for cap_on in (0, 1):
                self.junction(z0=z0)
                self.assertProxiesStraddle()
                cmd.set('metal_interior_cap', cap_on, 'br')
                hits = caps = 0
                for x, y in self.grid(19):
                    d = self.ray_dir(x, y)
                    ref = self.metal_hit(d, cap_on)
                    # A ray leaving a ROUND end's ball in front of the plane
                    # while the infinite tube runs on behind it: Metal caps
                    # it (cyl_shade tests the tube), so the pick must too.
                    tube_not_ball += \
                        ref != self.metal_hit(d, cap_on, round_far='ball')
                    hit = self.pick(x, y)
                    where = 'z0 %g cap %d at %r: pick %r, Metal %r' % (
                        z0, cap_on, (x, y), hit, ref)
                    self.assertEqual(hit is None, ref is None, where)
                    if ref is None:
                        continue
                    hits += 1
                    caps += ref[1]
                    self.assertEqual(hit.cap, ref[1], where)
                    self.assertAlmostEqual(hit.depth, ref[0], delta=1e-3,
                                           msg=where)
                    self.assertOnRay(hit, x, y)
                    self.assertOriented(hit)
                if cap_on:
                    # At 50.4 every atom is in front of the plane: the caps
                    # come from CB-CC and CB-CD, whose far crossings run on
                    # past their open ends at CB.
                    self.assertGreater(caps, 10, 'z0 %g' % z0)
                else:
                    self.assertEqual(caps, 0)
                    if z0 < 50.2:
                        self.assertGreater(hits, 0, 'z0 %g' % z0)
        # The grid reaches rays where the tube and the ball disagree.
        self.assertGreater(tube_not_ball, 0)


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

    def testSphereImpostorsFollowTheirCentre(self):
        # sphere_impostor_vertex puts the quad at the centre's depth, so a
        # sphere whose centre is outside the slab draws nothing at all: no
        # cap with the centre just in front of the near plane, and no front
        # surface with it just behind the far plane.
        self.ball('cut', (0.0, 0.0, 50.5))      # centre at depth 49.5
        self.ball('mid', (0.0, 0.0, 0.0))
        cmd.set('metal_interior_cap', 1, 'cut')
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'mid')
        self.assertFalse(hit.cap)
        cmd.translate([0.0, 0.0, -1.0], 'cut', camera=0)  # depth 50.5
        self.assertCap(self.pick(0.0, 0.0), 'cut')
        cmd.delete('cut')
        cmd.delete('mid')
        self.ball('deep', (0.0, 0.0, -51.0))     # depth 151, front at 149
        self.assertIsNone(self.pick(0.0, 0.0))
        cmd.translate([0.0, 0.0, 2.0], 'deep', camera=0)  # depth 149
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 147.0, delta=1e-3)

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

    def testInteriorCapFollowsTheTubeNotTheBall(self):
        # cyl_shade decides the cap from the INFINITE tube's far crossing,
        # whatever the ends. A stick wholly in front of the plane, leaning
        # away from the camera: this ray enters its body and leaves through
        # the far ball, both in front of the plane, but the tube runs on
        # behind the plane, so Metal caps.
        p0, p1 = (0.0, 0.0, 52.0), (0.0, 1.0, 50.3)
        self.stick('cut', p0, p1)
        cmd.set('metal_interior_cap', 1, 'cut')
        r = cmd.get_setting_float('stick_radius')
        x, y = self.ndc_of((0.0, 1.15, 50.3))
        d = self.ray_dir(x, y)
        h = norm(sub(p1, p0))
        u = unit(sub(p1, p0))

        def axial(t):
            return dot(sub(tuple(EYE[k] + t * d[k] for k in range(3)), p0), u)
        tube = tube_roots(EYE, d, p0, u, r)
        ball = sphere_roots(EYE, d, p1, r)
        self.assertTrue(metal_box_kept(p0, p1, r), 'test setup')
        self.assertTrue(0.0 <= axial(tube[0]) <= h, 'test setup: body entry')
        self.assertGreater(axial(tube[1]), h, 'test setup: ball exit')
        self.assertLess(tube[0], FRONT, 'test setup')
        self.assertLess(ball[1], FRONT, 'test setup')
        self.assertGreater(tube[1], FRONT, 'test setup')
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.assertAlmostEqual(hit.depth, FRONT, delta=1e-3)
        self.assertOnRay(hit, x, y)
        cmd.set('metal_interior_cap', 0, 'cut')
        self.assertIsNone(self.pick(x, y))

    def testNoCapWhereMetalClipsTheBox(self):
        # The same tube rule, but the stick is too far in front of the plane
        # for Metal to keep its impostor box (metal_box_kept): no fragment,
        # so no cap, though the tube runs on behind the plane.
        p0, p1 = (0.0, 0.0, 55.0), (0.0, 0.1, 53.0)
        self.stick('cut', p0, p1)
        cmd.set('metal_interior_cap', 1, 'cut')
        r = cmd.get_setting_float('stick_radius')
        x, y = self.ndc_of((0.0, 0.1, 53.0))
        d = self.ray_dir(x, y)
        tube = tube_roots(EYE, d, p0, unit(sub(p1, p0)), r)
        self.assertLess(sphere_roots(EYE, d, p0, r)[0], FRONT, 'test setup')
        self.assertGreater(tube[1], FRONT, 'test setup')
        self.assertFalse(metal_box_kept(p0, p1, r), 'test setup')
        self.assertIsNone(self.pick(x, y))
        # 2.5 A further back Metal keeps the box, and caps.
        cmd.translate([0.0, 0.0, -2.5], 'cut', camera=0)
        p0, p1 = (0.0, 0.0, 52.5), (0.0, 0.1, 50.5)
        self.assertTrue(metal_box_kept(p0, p1, r), 'test setup')
        x, y = self.ndc_of((0.0, 0.1, 50.5))
        d = self.ray_dir(x, y)
        self.assertLess(sphere_roots(EYE, d, p0, r)[0], FRONT, 'test setup')
        self.assertGreater(
            tube_roots(EYE, d, p0, unit(sub(p1, p0)), r)[1], FRONT)
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.assertAlmostEqual(hit.depth, FRONT, delta=1e-3)

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

    def assertFarWallFromInside(self, hit, depth, what):
        self.assertHit(hit)
        self.assertEqual(hit.object, 'cut', what)
        self.assertTrue(hit.inside, what)
        self.assertFalse(hit.cap, what)
        self.assertAlmostEqual(hit.depth, depth, delta=1e-3, msg=what)
        self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.05)
        self.assertOriented(hit)
        self.assertOnRay(hit, 0.0, 0.0)

    def testSphereUseShaderOffStraddlingSphereShowsItsInside(self):
        # sphere_use_shader 0 drops the impostors to CGOSimplify triangles
        # (picked as the analytic sphere): Mesh rule, the far wall from
        # inside, where the impostor is see-through.
        cmd.set('sphere_use_shader', 0)
        self.ball('cut', (0.0, 0.0, 50.0))
        self.assertFarWallFromInside(self.pick(0.0, 0.0), 52.0,
                                     'sphere_use_shader 0')
        cmd.set('metal_interior_cap', 1, 'cut')
        self.assertFarWallFromInside(self.pick(0.0, 0.0), 52.0,
                                     'no impostor cap on triangles')

    def testTessellatedStraddlingStickShowsItsInside(self):
        # Without the stick impostor (any of these off) RepCylBond's CGO is
        # tessellated: Mesh rule, the far wall from inside at 50 + r.
        r = cmd.get_setting_float('stick_radius')
        for setting in ('stick_as_cylinders', 'stick_use_shader',
                        'render_as_cylinders'):
            cmd.delete('cut')
            cmd.set(setting, 0)
            self.stick('cut', (-3.0, 0.0, 50.0), (3.0, 0.0, 50.0))
            self.assertFarWallFromInside(self.pick(0.0, 0.0), 50.0 + r,
                                         setting)
            cmd.set(setting, 1)
        # And with all three on, the impostor: see-through.
        cmd.delete('cut')
        self.stick('cut', (-3.0, 0.0, 50.0), (3.0, 0.0, 50.0))
        self.assertIsNone(self.pick(0.0, 0.0))


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

    def testNoPerRepClipWhenItsFrontIsBehindTheCamera(self):
        # RendererMetal applies the per-rep window only when its front plane
        # is at eye depth >= 0. Atom A, at depth 1, puts it at
        # 50.5 - (49.5 + 2.4) = -1.4: Metal draws the surface with the global
        # slab alone (even though surface_clip_back alone would put the back
        # plane at 76.45, in front of B).
        cmd.pseudoatom('m', name='B', pos=[0.0, 0.0, 0.0], vdw=self.R)
        cmd.pseudoatom('m', name='A', pos=[30.0, 0.0, 99.0], vdw=self.R)
        cmd.show_as('surface', 'm')
        cmd.set('surface_clip_back', 0.5, 'm')
        front, back = self.rep_clip('m', 0.0, 0.5)
        self.assertLess(front, 0.0, 'test setup')
        self.assertLess(back, 98.0, 'test setup')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'm')
        self.assertFalse(hit.inside)
        self.assertFalse(hit.cap)
        self.assertAlmostEqual(hit.depth, 98.0, delta=0.5)
        # B cut by the near plane instead: the far wall from inside, or with
        # the interior cap, a cap at the NEAR plane (repCapDepth's sentinel),
        # not at the disabled per-rep front.
        cmd.delete('m')
        cmd.pseudoatom('m', name='B', pos=[0.0, 0.0, 50.0], vdw=self.R)
        cmd.pseudoatom('m', name='A', pos=[30.0, 0.0, 99.0], vdw=self.R)
        cmd.show_as('surface', 'm')
        cmd.set('surface_clip_back', 0.5, 'm')
        self.assertLess(self.rep_clip('m', 0.0, 0.5)[0], 0.0, 'test setup')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.inside)
        self.assertAlmostEqual(hit.depth, 52.0, delta=0.5)
        cmd.set('metal_interior_cap', 1, 'm')
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertTrue(hit.cap)
        self.assertAlmostEqual(hit.depth, FRONT, delta=1e-3)
        self.assertOnRay(hit, 0.0, 0.0)

    def testPerRepBackPlaneHoldsWithTheCap(self):
        # With the cap on, the parity search runs on to the far plane, past
        # the per-rep back plane, so a first crossing beyond that plane must
        # still be dropped. A at depth 100, B at 110: the ray through B
        # enters it at about 108, behind the back plane at 106.48.
        cmd.pseudoatom('m', name='A', pos=[0.0, 0.0, 0.0], vdw=self.R)
        cmd.pseudoatom('m', name='B', pos=[6.0, 0.0, -10.0], vdw=self.R)
        cmd.show_as('surface', 'm')
        x, y = self.ndc_of((6.0, 0.0, -10.0))
        entry = self.pick(x, y)
        self.assertHit(entry)
        self.assertFalse(entry.inside)
        self.assertAlmostEqual(entry.depth, 108.0, delta=0.5)
        cmd.set('surface_clip_back', 0.8, 'm')
        front, back = self.rep_clip('m', 0.0, 0.8)
        self.assertAlmostEqual(back, 106.48, delta=1e-3)
        self.assertGreater(front, FRONT, 'test setup: the cap plane is live')
        self.assertLess(back, entry.depth, 'test setup')
        self.assertIsNone(self.pick(x, y))
        cmd.set('metal_interior_cap', 1, 'm')
        self.assertIsNone(self.pick(x, y))
        # Without the back plane, the cap-on search finds the entry.
        cmd.set('surface_clip_back', 0.0, 'm')
        hit = self.pick(x, y)
        self.assertHit(hit)
        self.assertFalse(hit.cap)
        self.assertFalse(hit.inside)
        self.assertAlmostEqual(hit.depth, entry.depth, delta=1e-3)

    def testNoCapInFrontOfTheNearPlane(self):
        # A per-rep front at eye depth 48.84, in front of the near plane but
        # >= 0: the window is on, but Metal's cap fill at 48.84 is clipped
        # away, so the cut atom shows the inside of its far wall at 52.
        cmd.pseudoatom('n', name='A', pos=[0.0, 0.0, 50.0], vdw=self.R)
        cmd.pseudoatom('n', name='B', pos=[0.0, 0.0, 30.0], vdw=self.R)
        cmd.show_as('surface', 'n')
        cmd.set('surface_clip_front', 0.1, 'n')
        front, _ = self.rep_clip('n', 0.1, 0.0)
        self.assertAlmostEqual(front, 48.84, delta=1e-3)
        for cap_on in (0, 1):
            cmd.set('metal_interior_cap', cap_on, 'n')
            hit = self.pick(0.0, 0.0)
            self.assertHit(hit)
            self.assertFalse(hit.cap, 'cap %d' % cap_on)
            self.assertTrue(hit.inside, 'cap %d' % cap_on)
            self.assertAlmostEqual(hit.depth, 52.0, delta=0.5)
            self.assertOnRay(hit, 0.0, 0.0)
            self.assertOriented(hit)

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
        for view in range(3):
            if view == 1:
                cmd.turn('y', 70)
                cmd.turn('x', 35)
            elif view == 2:
                # The near plane through the middle of the molecule: the
                # window starts inside it, and where the cut opens the
                # cartoon, the far wall shows from inside (Mesh rule).
                v = list(cmd.get_view())
                v[15] = -v[11]  # front clip at the origin's depth
                cmd.set_view(v)
                self.assertAlmostEqual(metal_pick.camera().clip_front,
                                       -v[11], delta=1e-3)
            mesh = self.export_mesh('rx')
            self.assertGreater(len(mesh.tris), 1000)

            def near_marker(o, d):
                # The export keeps only the centre of a sphere.
                return any(norm(cross(sub(m, o), d)) / norm(d) < 2.0
                           for m in mesh.markers)

            points = self.box_points('rx', n=7 if view < 2 else 11)
            self.assertMatchesMesh(mesh, points, 'cartoon', min_hits=8,
                                   exclude=near_marker)
            if view == 2:
                # A finer grid (picks only) to find rays through the cut.
                front = metal_pick.camera().clip_front
                hits = [h for h in (self.pick(*p) for p in
                                    self.box_points('rx', n=31, inset=0.0))
                        if h]
                self.assertTrue(all(h.depth >= front - 1e-3 for h in hits))
                self.assertTrue(any(h.inside for h in hits),
                                'the cut should expose a back face')

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

    def ring_sphere(self, z):
        '''TTT single-strand B-DNA, cartoon_ring_mode 4: the middle base's
        ring sphere (radius cartoon_ring_radius 1.5, at the ring's centroid)
        centred at (0, 0, z).'''
        cmd.delete('dna')
        cmd.fnab('TTT', name='dna', mode='DNA', form='B', dbl_helix=0)
        cmd.set_view(VIEW)  # the first object zooms the view
        cmd.show_as('cartoon', 'dna')
        cmd.set('cartoon_ring_mode', 4)
        cmd.set('cartoon_ring_radius', 1.5)
        ring = cmd.get_coords('dna and resi 2 and name N1+C2+N3+C4+C5+C6')
        c = [sum(p[k] for p in ring) / len(ring) for k in range(3)]
        cmd.translate([-c[0], -c[1], z - c[2]], 'dna', camera=0)

    def testRingSphereCutByTheNearPlane(self):
        # Unclipped: the sphere's front pole, wherever it was built.
        self.ring_sphere(0.0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertAlmostEqual(hit.depth, 98.5, delta=1e-3)
        self.assertFalse(hit.inside)
        # Centred on the near plane. The impostor (the default) is
        # see-through; the triangles RepCartoonCGOGenerate tessellates
        # instead (cartoon_use_shader off, or a transparent cartoon with
        # transparency_mode != 3) show the far wall from inside.
        self.ring_sphere(50.0)
        cases = [({}, None),
                 ({'cartoon_use_shader': 0}, 51.5),
                 ({'cartoon_transparency': 0.5}, 51.5),
                 ({'cartoon_transparency': 0.5, 'transparency_mode': 3}, None)]
        for settings, depth in cases:
            saved = {name: cmd.get(name) for name in settings}
            for name, value in settings.items():
                cmd.set(name, value)
            hit = self.pick(0.0, 0.0)
            if depth is None:
                self.assertIsNone(hit, settings)
            else:
                self.assertHit(hit)
                self.assertEqual(hit.rep, 'cartoon')
                self.assertTrue(hit.inside, settings)
                self.assertFalse(hit.cap)
                self.assertAlmostEqual(hit.depth, depth, delta=1e-3,
                                       msg=settings)
                self.assertNormalNear(hit, (0.0, 0.0, 1.0), 0.05)
            for name, value in saved.items():
                cmd.set(name, value)

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


class TestPerAtomTransparency(PickCase):
    '''Transparency set per atom (or per bond) leaves the rep's built
    transparency at 0, so the rep is picked primitive by primitive: the
    CGO_ALPHA before a sphere or a cylinder, the per-vertex colour alpha of
    a cartoon's triangle blocks, the surface's per-vertex alpha (VA). A
    primitive fully transparent there draws nothing, so the pick passes
    through it to what is behind.'''

    def testInvisibleSphere(self):
        cmd.pseudoatom('two', name='F', pos=[0.0, 0.0, 20.0], vdw=2.0)
        cmd.pseudoatom('two', name='B', pos=[0.0, 0.0, 0.0], vdw=2.0)
        cmd.show_as('spheres', 'two')
        self.assertAlmostEqual(self.pick(0.0, 0.0).depth, 78.0, delta=1e-3)
        cmd.set('sphere_transparency', 1.0, 'two and name F')
        self.assertEqual(cmd.get_setting_float('sphere_transparency', 'two'),
                         0.0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'two')
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)

    def testInvisibleBond(self):
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        self.ball('ball', (0.0, 0.0, 0.0))
        self.assertEqual(self.pick(0.0, 0.0).object, 'stk')
        cmd.set_bond('stick_transparency', 1.0, 'stk')
        self.assertEqual(cmd.get_setting_float('stick_transparency', 'stk'),
                         0.0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'ball')
        self.assertAlmostEqual(hit.depth, 98.0, delta=1e-3)
        # Half transparent is still drawn.
        cmd.set_bond('stick_transparency', 0.5, 'stk')
        self.assertEqual(self.pick(0.0, 0.0).object, 'stk')

    def testInvisibleSurfacePatch(self):
        cmd.pseudoatom('pair', name='A', pos=[-1.25, 0.0, 0.0], vdw=2.0)
        cmd.pseudoatom('pair', name='B', pos=[1.25, 0.0, 0.0], vdw=2.0)
        cmd.show_as('surface', 'pair')
        self.ball('ball', (0.0, 0.0, -20.0))
        self.assertEqual(self.pick(0.0, 0.0).object, 'pair')
        cmd.set('transparency', 1.0, 'pair and name A+B')
        self.assertEqual(cmd.get_setting_float('transparency', 'pair'), 0.0)
        hit = self.pick(0.0, 0.0)
        self.assertHit(hit)
        self.assertEqual(hit.object, 'ball')
        self.assertAlmostEqual(hit.depth, 118.0, delta=1e-3)

    def testInvisibleCartoonResidues(self):
        cmd.fab('AAAAAAAAAAAA', 'pep', ss=1)
        cmd.dss('pep')
        cmd.show_as('cartoon', 'pep')
        e = cmd.get_extent('pep')
        cmd.translate([-(e[0][i] + e[1][i]) / 2.0 for i in range(3)],
                      selection='pep', camera=0)
        cmd.translate([0.0, 0.0, 20.0], selection='pep', camera=0)
        cmd.pseudoatom('wall', pos=[0.0, 0.0, -20.0], vdw=30.0)
        cmd.show_as('spheres', 'wall')
        cmd.set_view(VIEW)  # the first object zoomed the view
        points = [(i / 20.0, j / 20.0) for i in range(-6, 7)
                  for j in range(-6, 7)]

        def cartoon_hits():
            hits = [self.pick(*p) for p in points]
            return sum(1 for h in hits if h is not None and h.object == 'pep')

        every = cartoon_hits()
        self.assertGreater(every, 10)
        cmd.set('cartoon_transparency', 1.0, 'pep and resi 7-12')
        self.assertEqual(cmd.get_setting_float('cartoon_transparency', 'pep'),
                         0.0)
        some = cartoon_hits()
        self.assertGreater(some, 0)
        self.assertLess(some, every)
        cmd.set('cartoon_transparency', 1.0, 'pep and resi 1-6')
        self.assertEqual(cartoon_hits(), 0)


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
        # GL and ray semantics. The Metal app does not draw state matrices
        # yet (see coordSetToWorld in layer3/SurfacePick.cpp); this pins the
        # pick to what the renderer should draw.
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


class TestGrid(PickCase):
    '''grid_mode 1-3, mapped in the core.

    surface_at takes a whole-viewport point. The core finds the cell under it
    the way SceneRenderMetal lays cells out (columns left to right, row 0 at
    the top; every cell shares the frame's camera, with the cell's own
    aspect) and picks only what that cell draws. At 400 x 300 (aspect 4/3)
    GridUpdate lays 2 slots out as 1 row x 2 columns (cell aspect 2/3), and
    3 or 4 slots as 2 x 2 (cell aspect 4/3).

    Every object sits on the view axis, nearer ones in front, so without the
    cell mapping the nearest object would win every pick.'''

    TWO = (2, 1)   # (n_col, n_row)
    FOUR = (2, 2)
    O = (0.0, 0.0, 0.0)

    def at(self, layout, slot, cx=0.0, cy=0.0):
        '''Viewport NDC of the point (cx, cy), in cell NDC, of 1-based `slot`
        in an (n_col, n_row) layout.'''
        n_col, n_row = layout
        col, row = (slot - 1) % n_col, (slot - 1) // n_col
        return (-1.0 + (2.0 * col + cx + 1.0) / n_col,
                1.0 - (2.0 * row + 1.0 - cy) / n_row)

    def cell_sphere(self, layout, cx, cy, c, r):
        '''(point, depth) where the cell's ray through (cx, cy) enters the
        sphere (c, r): the pinned camera with the cell's aspect.'''
        n_col, n_row = layout
        d = (cx * T * self.aspect() * n_row / n_col, cy * T, -1.0)
        oc = sub(EYE, c)
        qa, qb, qc = dot(d, d), 2.0 * dot(oc, d), dot(oc, oc) - r * r
        disc = qb * qb - 4.0 * qa * qc
        self.assertGreaterEqual(disc, 0.0, 'test geometry: ray misses')
        lam = (-qb - math.sqrt(disc)) / (2.0 * qa)
        return tuple(EYE[i] + lam * d[i] for i in range(3)), lam

    def assertCellHit(self, layout, slot, obj, state, c, r=2.0, cx=0.0,
                      cy=0.0):
        p, depth = self.cell_sphere(layout, cx, cy, c, r)
        hit = self.pick(*self.at(layout, slot, cx, cy))
        self.assertHit(hit)
        self.assertEqual((hit.object, hit.state), (obj, state),
                         'slot %d' % slot)
        self.assertAlmostEqual(hit.depth, depth, delta=1e-3)
        self.assertLess(norm(sub(hit.point, p)), 1e-3)
        self.assertNormalNear(hit, sub(p, c), 0.5)
        self.assertOriented(hit)
        return hit

    def multi(self, name, zs):
        '''One sphere per state, on the view axis at the given z.'''
        for i, z in enumerate(zs):
            cmd.pseudoatom(name, pos=[0.0, 0.0, z], vdw=2.0, state=i + 1)
        cmd.show_as('spheres', name)

    def testOneSlotIsTheWholeViewport(self):
        # One object: one slot, which GridUpdate does not make a grid.
        self.ball('ga', self.O)
        cmd.set('grid_mode', 1)
        hit = self.pick(0.05, -0.04)
        self.assertHit(hit)
        p, depth = self.ray_sphere(0.05, -0.04, self.O, 2.0)
        self.assertAlmostEqual(hit.depth, depth, delta=1e-3)
        self.assertLess(norm(sub(hit.point, p)), 1e-3)

    def testByObject(self):
        self.ball('ga', self.O)
        self.ball('gb', (0.0, 0.0, 10.0))
        self.assertEqual(self.pick(0.0, 0.0).object, 'gb')
        cmd.set('grid_mode', 1)
        self.assertCellHit(self.TWO, 1, 'ga', 1, self.O)
        self.assertCellHit(self.TWO, 2, 'gb', 1, (0.0, 0.0, 10.0))
        # Off-centre points take the cell's aspect (2/3; at the viewport's
        # 4/3 these rays would pass beside the spheres).
        self.assertCellHit(self.TWO, 1, 'ga', 1, self.O, cx=0.12, cy=-0.06)
        self.assertCellHit(self.TWO, 2, 'gb', 1, (0.0, 0.0, 10.0),
                           cx=-0.12, cy=0.06)
        # The viewport centre is cell 2's left edge: nothing is drawn there.
        self.assertIsNone(self.pick(0.0, 0.0))
        # Outside the viewport there is no cell.
        self.assertIsNone(self.pick(1.2, 0.0))
        self.assertIsNone(self.pick(-0.5, -1.01))

    def testEmptySlotAndGridMax(self):
        self.ball('ga', self.O)
        self.ball('gb', (0.0, 0.0, 10.0))
        self.ball('gc', (0.0, 0.0, 20.0))
        cmd.set('grid_mode', 1)
        self.assertCellHit(self.FOUR, 1, 'ga', 1, self.O)
        self.assertCellHit(self.FOUR, 2, 'gb', 1, (0.0, 0.0, 10.0))
        self.assertCellHit(self.FOUR, 3, 'gc', 1, (0.0, 0.0, 20.0))
        # Three slots in a 2 x 2 grid: the fourth cell is empty.
        self.assertIsNone(self.pick(*self.at(self.FOUR, 4)))
        # grid_max 2 draws two slots (1 x 2): gc, in slot 3, is drawn nowhere.
        cmd.set('grid_max', 2)
        self.assertCellHit(self.TWO, 1, 'ga', 1, self.O)
        self.assertCellHit(self.TWO, 2, 'gb', 1, (0.0, 0.0, 10.0))

    def testByObjectFollowsGridSlot(self):
        self.ball('ga', self.O)
        self.ball('gb', (0.0, 0.0, 10.0))
        self.ball('gc', (0.0, 0.0, 20.0))
        cmd.set('grid_mode', 1)
        # gc shares ga's slot: two slots, and gc is in front in cell 1.
        cmd.set('grid_slot', 1, 'gc')
        self.assertCellHit(self.TWO, 1, 'gc', 1, (0.0, 0.0, 20.0))
        self.assertCellHit(self.TWO, 2, 'gb', 1, (0.0, 0.0, 10.0))
        # A negative grid_slot draws the object in every cell.
        cmd.set('grid_slot', -2, 'gc')
        self.assertCellHit(self.TWO, 1, 'gc', 1, (0.0, 0.0, 20.0))
        self.assertCellHit(self.TWO, 2, 'gc', 1, (0.0, 0.0, 20.0))

    def testByObjectStates(self):
        self.multi('gm', (0.0, 10.0))
        self.ball('gs', (0.0, 0.0, -20.0))
        cmd.set('grid_mode', 2)
        cmd.frame(1)
        self.assertCellHit(self.TWO, 1, 'gm', 1, self.O)
        self.assertCellHit(self.TWO, 2, 'gm', 2, (0.0, 0.0, 10.0))
        self.assertCellHit(self.TWO, 2, 'gm', 2, (0.0, 0.0, 10.0),
                           cx=0.12, cy=0.06)
        # Cells count from the scene's state: cell 1 now draws state 2 and
        # cell 2 state 3, which gm lacks. The single-state object is drawn in
        # every cell (static_singletons).
        cmd.frame(2)
        self.assertCellHit(self.TWO, 1, 'gm', 2, (0.0, 0.0, 10.0))
        self.assertCellHit(self.TWO, 2, 'gs', 1, (0.0, 0.0, -20.0))
        cmd.set('static_singletons', 0)
        self.assertCellHit(self.TWO, 1, 'gm', 2, (0.0, 0.0, 10.0))
        self.assertIsNone(self.pick(*self.at(self.TWO, 2)))

    def testByObjectByState(self):
        self.multi('gp', (0.0, 5.0))
        self.multi('gq', (10.0, 15.0))
        cmd.set('grid_mode', 3)
        expected = [('gp', 1, 0.0), ('gp', 2, 5.0), ('gq', 1, 10.0),
                    ('gq', 2, 15.0)]
        for frame in (1, 2):
            # The scene's state does not move ByObjectByState cells.
            cmd.frame(frame)
            for slot, (obj, state, z) in enumerate(expected, 1):
                self.assertCellHit(self.FOUR, slot, obj, state,
                                   (0.0, 0.0, z))
        self.assertCellHit(self.FOUR, 4, 'gq', 2, (0.0, 0.0, 15.0),
                           cx=-0.08, cy=0.06)
        # gq with one state: three slots, and the fourth cell is empty.
        cmd.delete('gq')
        self.multi('gq', (10.0,))
        self.assertCellHit(self.FOUR, 3, 'gq', 1, (0.0, 0.0, 10.0))
        self.assertIsNone(self.pick(*self.at(self.FOUR, 4)))

    def testPicksAreRepeatable(self):
        '''Picking again, in another order and without the update, gives the
        same answers, and leaves the view, frame, grid settings and enabled
        objects unchanged. Whether pickGridLayout writes CScene::m_slots or
        obj->grid_slot cannot be seen from Python (see its comment).'''
        self.multi('gp', (0.0, 5.0))
        self.multi('gq', (10.0, 15.0))
        cmd.set('grid_mode', 3)
        points = [self.at(self.FOUR, slot, cx, cy) for slot in (1, 2, 3, 4)
                  for cx, cy in ((0.0, 0.0), (0.06, -0.05))]
        first = [self.pick(x, y) for x, y in points]
        self.assertTrue(all(first))

        def snapshot():
            return (cmd.get('grid_mode'), cmd.get('grid_max'),
                    cmd.get_view(), cmd.get_frame(),
                    cmd.get_names('all', enabled_only=1))
        before = snapshot()
        again = [self.pick(x, y, update=False) for x, y in reversed(points)]
        self.assertEqual(again[::-1], first)
        self.assertEqual([self.pick(x, y) for x, y in points], first)
        self.assertEqual(snapshot(), before)
        # Back to ByObject: one cell per object again, at the shown state.
        cmd.set('grid_mode', 1)
        self.assertCellHit(self.TWO, 1, 'gp', 1, self.O)
        self.assertCellHit(self.TWO, 2, 'gq', 1, (0.0, 0.0, 10.0))

    def testWarmCoversEveryCell(self):
        self.multi('gm', (0.0, 10.0))
        self.ball('gs', (0.0, 0.0, -20.0))
        # No grid: the shown state of each object.
        self.assertEqual(metal_pick.surface_warm()['accels'], 2)
        # ByObjectStates: gm's two states, and the singleton once.
        cmd.set('grid_mode', 2)
        warm = metal_pick.surface_warm()
        self.assertEqual(warm['accels'], 3)
        self.assertEqual(warm['built'], 1)
        # ByObjectByState: every state of every object, already warm.
        cmd.set('grid_mode', 3)
        warm = metal_pick.surface_warm()
        self.assertEqual(warm['accels'], 3)
        self.assertEqual(warm['built'], 0)
        # One slot is no grid.
        cmd.set('grid_max', 1)
        self.assertEqual(metal_pick.surface_warm()['accels'], 2)

    def testReleaseCoversEveryState(self):
        # Grids warmed for grid cells stay with their states after the grid
        # is gone; release drops them all, drawn or not.
        self.multi('gm', (0.0, 10.0))
        self.ball('gs', (0.0, 0.0, -20.0))
        cmd.set('grid_mode', 3)
        self.assertEqual(metal_pick.surface_warm()['accels'], 3)
        cmd.set('grid_mode', 0)
        released = metal_pick.surface_release()
        self.assertEqual(released['accels'], 3)
        self.assertGreater(released['bytes'], 0)
        self.assertEqual(metal_pick.surface_release(),
                         {'accels': 0, 'bytes': 0})


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
        metal_pick.surface_release()
        self.assertEqual(self.snapshot(), before)

    def render(self):
        '''The bytes of a small ray-traced frame (headless: no GL).'''
        with testing.mktemp('.png') as path:
            cmd.png(path, width=80, height=60, ray=1, quiet=1)
            with open(path, 'rb') as handle:
                return handle.read()

    def assertPicksLeaveTheRenderAlone(self, points, what):
        self.render()                    # whatever the first frame builds
        before = self.render()
        self.assertGreater(len(before), 0)
        for x, y in points:
            self.pick(x, y)
            self.pick(x, y, update=False)
        metal_pick.surface_warm()
        self.assertEqual(self.render(), before, what + ': warm and picks')
        metal_pick.surface_release()
        self.assertEqual(self.render(), before, what + ': release')
        for x, y in points:
            self.pick(x, y)              # rebuilds the released grids
        self.assertEqual(self.render(), before, what + ': picks again')

    def testPicksLeaveTheRenderAlone(self):
        # The pick and its update must not change what a frame draws: the
        # same ray-traced frame before and after (L1 renders no pick).
        points = [(0.0, 0.0), (0.1, 0.0), (-0.2, 0.15), (0.9, 0.9)]
        self.ball('ball', (0.0, 0.0, 0.0))
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        self.ball('shell', (2.0, -1.0, 10.0), rep='surface')
        self.assertPicksLeaveTheRenderAlone(points, 'plain')
        # The per-rep clip (its cached depth range) and the interior cap.
        cmd.set('surface_clip_front', 0.4, 'shell')
        cmd.set('metal_interior_cap', 1, 'shell')
        self.assertPicksLeaveTheRenderAlone(points, 'surface clip')
        # A grid (the pick rebuilds its layout locally) over two states.
        cmd.pseudoatom('multi', pos=[0.0, 3.0, 0.0], vdw=2.0, state=1)
        cmd.pseudoatom('multi', pos=[0.0, -3.0, 5.0], vdw=2.0, state=2)
        cmd.show_as('spheres', 'multi')
        cmd.set('grid_mode', 3)
        self.addCleanup(self.reset_ray_grid)
        self.assertPicksLeaveTheRenderAlone(
            points + [(-0.5, 0.5), (0.5, -0.5)], 'grid_mode 3')

    def reset_ray_grid(self):
        '''A ray render in grid mode leaves the scene's grid layout behind,
        and a later ray with grid_mode 0 (an OBJ export in another test)
        still draws through it: SceneRay only updates the layout in grid
        mode, and headless no SceneRender resets it (pre-existing; proposed
        follow-up). A one-slot grid ray clears it.'''
        cmd.delete('all')
        cmd.set('grid_mode', 1)
        self.render()
        cmd.set('grid_mode', 0)

    def testReleaseDropsTheGrids(self):
        from pymol.cmd import _cmd
        mask = metal_pick._surface_rep_mask(metal_pick.SURFACE_REPS)

        def cached():
            with cmd.lockcm:
                return _cmd.surface_pick_prepare(cmd._COb, None, mask, 0, 0)[0]

        self.ball('ball', (0.0, 0.0, 0.0))
        self.stick('stk', (-3.0, 0.0, 20.0), (3.0, 0.0, 20.0))
        self.assertEqual(metal_pick.surface_warm()['accels'], 2)
        sticks = metal_pick.surface_warm(reps='sticks')
        # Only what is asked for, with the heap it held.
        self.assertEqual(metal_pick.surface_release(reps='sticks'),
                         {'accels': 1, 'bytes': sticks['bytes']})
        self.assertEqual(cached(), 1)
        self.assertEqual(metal_pick.surface_release(objects=['nothing']),
                         {'accels': 0, 'bytes': 0})
        # The next pick rebuilds what it needs.
        hit = self.pick(0.0, 0.0)
        self.assertEqual(hit.object, 'stk')
        self.assertEqual(cached(), 2)
        self.assertEqual(metal_pick.surface_warm()['built'], 0)
        # Disabled objects keep their grids until released.
        cmd.disable('ball')
        released = metal_pick.surface_release()
        self.assertEqual(released['accels'], 2)
        self.assertGreater(released['bytes'], sticks['bytes'])
        cmd.enable('ball')
        self.assertEqual(cached(), 0)
        self.assertEqual(metal_pick.surface_release(),
                         {'accels': 0, 'bytes': 0})
        self.assertRaises(CmdException, metal_pick.surface_release,
                          reps='lines')

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


class TestPickBench(testing.PyMOLTestCase):
    '''scripts/lighting/pick_bench.py, the orchestrator's timing entry point,
    in its --check mode: the same steps as the timed run, on 1rx1, with
    correctness asserted and no timings printed. Keeps the timing command
    working as the pick evolves.'''

    def bench(self):
        import importlib.util
        import os
        # <root>/testing/data/1rx1.pdb -> <root>
        root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(self.datafile('1rx1.pdb')))))
        path = os.path.join(root, 'scripts', 'lighting', 'pick_bench.py')
        if not os.path.exists(path):
            self.skipTest('no scripts/lighting/pick_bench.py next to the tests')
        spec = importlib.util.spec_from_file_location('lt614_pick_bench', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)  # runs nothing on import
        return module

    def testCheckModePasses(self):
        bench = self.bench()
        lines = []
        status = bench.run(['--check', '--pdb', self.datafile('1rx1.pdb')],
                           out=lines.append)
        self.assertEqual(status, 0, '\n'.join(lines))
        self.assertEqual(lines[-1], 'PICKBENCH CHECK ok')
        for label in ('cartoon', 'surface', 'spheres', 'sticks', 'all'):
            self.assertTrue(any(l.startswith('PICKBENCH CHECK reps=%s ' % label)
                                and l.endswith(' ok') for l in lines), label)
        self.assertFalse(any('_ms' in l for l in lines),
                         '--check must print no timings')

    def testCheckModeReportsAFailure(self):
        # Invisible spheres (the bench reinitializes, so set it per set):
        # nothing is pickable, and the check must say so and fail.
        bench = self.bench()
        real = bench.bench_set

        def invisible(label, ctx, check):
            cmd.set('sphere_transparency', 1.0, ctx['name'])
            return real(label, ctx, check)

        lines = []
        bench.bench_set = invisible
        status = bench.run(['--check', '--pdb', self.datafile('1rx1.pdb'),
                            '--reps', 'spheres'], out=lines.append)
        self.assertEqual(status, 1, '\n'.join(lines))
        self.assertTrue(
            lines[-1].startswith('PICKBENCH CHECK FAIL reps=spheres'), lines[-1])
