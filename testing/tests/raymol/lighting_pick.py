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
