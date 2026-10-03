"""The light rig in eye space: the resolver and the pin conversions (#611).

The app bridge (PyMOLBridge_LightsEyeSpace / PyMOLBridge_LightSet) and, from
#613, the renderer resolve the rig with C++ in layer1/LightRig.cpp:
LightRigResolve and LightRigSet. These tests reach the same functions through
_cmd.get_lights_eye and _cmd.light_set (pymol.lighting._lights_eye /
_light_set). No CI job builds catch2, so the C++ maths is tested this way
(lighting checklist, "What CI must cover").

Expected values never come from the code under test: they come from explicit
matrices built here, or from the camera as metal_pick.camera() reads it from
cmd.get_view() (eye = R·(world - origin) + pos).

Covers the angle convention (orbit 0 = at the camera, +90 = camera-right,
+-180 = behind; pitch +90 = camera-up), camera, aimed and pinned lights under
an explicit rotated matrix and under the live camera, the cone cosines, pin /
unpin / re-pin keeping the eye position, radius in scene sizes and the
degenerate aims.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_eye.py
"""
import math

import pymol
from pymol import cmd, lighting, metal_pick, testing

IDENTITY = [1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0]

# eye-space values are floats (GPU inputs): compare with a float tolerance
TOL = 2e-4


# --- small 4x4 helpers (row-major nested lists; no numpy in CI) -------------

def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)]
            for i in range(4)]


def translation(t):
    return [[1.0, 0.0, 0.0, t[0]],
            [0.0, 1.0, 0.0, t[1]],
            [0.0, 0.0, 1.0, t[2]],
            [0.0, 0.0, 0.0, 1.0]]


def rot_x(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[1.0, 0.0, 0.0, 0.0],
            [0.0, c, -s, 0.0],
            [0.0, s, c, 0.0],
            [0.0, 0.0, 0.0, 1.0]]


def rot_y(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[c, 0.0, s, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [-s, 0.0, c, 0.0],
            [0.0, 0.0, 0.0, 1.0]]


def column_major(m):
    """16 numbers, column after column (what _lights_eye takes)."""
    return [m[r][c] for c in range(4) for r in range(4)]


def apply(m, p):
    return [sum(m[i][j] * p[j] for j in range(3)) + m[i][3] for i in range(3)]


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


def add(a, b):
    return [x + y for x, y in zip(a, b)]


def scale(a, s):
    return [x * s for x in a]


def norm(a):
    return math.sqrt(sum(x * x for x in a))


def unit(a):
    n = norm(a)
    return [x / n for x in a]


def orbit_dir(orbit, pitch):
    """Spec §4.3, written out independently of the C++."""
    o, p = math.radians(orbit), math.radians(pitch)
    return [math.sin(o) * math.cos(p), math.sin(p), math.cos(o) * math.cos(p)]


def oracle_matrix():
    """The live camera's world->eye matrix, from cmd.get_view() as
    metal_pick.camera() parses it: eye = R·(w - origin) + pos."""
    cam = metal_pick.camera()
    r = cam.rot
    m = [[r[3 * i + j] for j in range(3)] + [0.0] for i in range(3)]
    for i in range(3):
        m[i][3] = cam.pos[i] - sum(r[3 * i + j] * cam.origin[j]
                                   for j in range(3))
    m.append([0.0, 0.0, 0.0, 1.0])
    return m


def oracle(world):
    """A world point in the live camera's eye space (metal_pick.camera)."""
    cam = metal_pick.camera()
    d = sub(world, cam.origin)
    return [sum(cam.rot[3 * i + j] * d[j] for j in range(3)) + cam.pos[i]
            for i in range(3)]


class TestLightingEye(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        # something to look at, away from the origin
        cmd.pseudoatom('pa', pos=[4.0, -2.0, 6.0])
        cmd.pseudoatom('pb', pos=[-6.0, 5.0, 1.0])

    def rig(self, lights, centre=(0.0, 0.0, 0.0), size=10.0, enabled=True):
        cmd.set_lights({'enabled': enabled, 'centre': list(centre),
                        'size': float(size), 'lights': lights})

    def assertVec(self, got, want, tol=TOL, msg=None):
        self.assertEqual(len(got), len(want), msg)
        for g, w in zip(got, want):
            self.assertAlmostEqual(g, w, delta=tol * max(1.0, abs(w)),
                                   msg='%r != %r %s' % (got, want, msg or ''))

    def turn(self):
        """A view that is not axis-aligned, moved off the origin."""
        cmd.turn('y', 50)
        cmd.turn('x', 30)
        cmd.move('z', -20)
        cmd.move('x', 3)

    # --- no rig, empty rig ------------------------------------------------------

    def testNoRig(self):
        self.assertIsNone(lighting._lights_eye())
        self.assertIsNone(lighting._lights_eye(IDENTITY))

    def testEmptyRigHasNoFrame(self):
        cmd.set_lights({'enabled': True})
        self.assertEqual(lighting._lights_eye(IDENTITY), {
            'enabled': True, 'centre': None, 'size': None, 'lights': []})

    def testBadMatrix(self):
        self.rig([{}])
        for bad in ([1.0] * 15, [1.0] * 17, IDENTITY[:-1] + [float('nan')]):
            with self.assertRaises(pymol.CmdException):
                lighting._lights_eye(bad)

    # --- the angle convention (spec §4.3, decision 12) ----------------------------

    def testAngleConventionIdentity(self):
        """orbit 0 = towards the viewer (+z), +90 = camera-right (+x), -90 =
        left, +-180 = behind; pitch +90 = camera-up (+y)."""
        cases = [
            (0.0, 0.0, [0.0, 0.0, 20.0], 0.0),
            (90.0, 0.0, [20.0, 0.0, 0.0], 90.0),
            (-90.0, 0.0, [-20.0, 0.0, 0.0], -90.0),
            (180.0, 0.0, [0.0, 0.0, -20.0], 180.0),
            (-180.0, 0.0, [0.0, 0.0, -20.0], 180.0),   # wraps to 180
            (0.0, 90.0, [0.0, 20.0, 0.0], 0.0),
            (0.0, -90.0, [0.0, -20.0, 0.0], 0.0),
            (45.0, 0.0, [20.0 * math.sqrt(0.5), 0.0, 20.0 * math.sqrt(0.5)], 45.0),
            (90.0, 30.0, [20.0 * math.cos(math.radians(30)), 10.0, 0.0], 90.0),
        ]
        for orbit, pitch, want, stored in cases:
            self.rig([{'orbit': orbit, 'pitch': pitch, 'radius': 2.0}])
            eye = lighting._lights_eye(IDENTITY)
            light = eye['lights'][0]
            label = 'orbit %r pitch %r' % (orbit, pitch)
            self.assertVec(eye['centre'], [0.0, 0.0, 0.0], msg=label)
            self.assertVec(light['position'], want, msg=label)
            self.assertAlmostEqual(norm(light['position']), 20.0, delta=TOL)
            # aimed at the centre: the beam points back at it
            self.assertVec(light['target'], [0.0, 0.0, 0.0], msg=label)
            self.assertVec(light['direction'], unit(scale(want, -1.0)), msg=label)
            self.assertAlmostEqual(light['aim_distance'], 20.0, delta=TOL)
            self.assertAlmostEqual(light['orbit'], stored, delta=TOL)
            self.assertAlmostEqual(light['pitch'], pitch, delta=TOL)
            self.assertAlmostEqual(light['radius'], 2.0, delta=TOL)

    def testOrbitPlus90IsCameraRightUnderLiveView(self):
        """+90 is camera-right whatever the molecule's orientation."""
        self.turn()
        self.rig([{'orbit': 90.0, 'pitch': 0.0, 'radius': 2.0}],
                 centre=(1.0, 2.0, 3.0))
        eye = lighting._lights_eye()
        offset = sub(eye['lights'][0]['position'], eye['centre'])
        self.assertVec(offset, [20.0, 0.0, 0.0])

    # --- an explicit rotated matrix ----------------------------------------------

    def testExplicitRotatedMatrix(self):
        m = mat_mul(translation([3.0, -4.0, -60.0]),
                    mat_mul(rot_x(30.0), rot_y(50.0)))
        centre, size = [1.0, 2.0, 3.0], 5.0
        pinned_at = [10.0, -5.0, 8.0]
        aim_point = [4.0, 0.0, -2.0]
        self.rig([
            {'name': 'cam', 'orbit': 40.0, 'pitch': 20.0, 'radius': 3.0,
             'beam': 60.0, 'softness': 0.5},
            {'name': 'pin', 'anchor': 'pinned', 'position': pinned_at,
             'beam': 50.0, 'softness': 0.0, 'shadow': True},
            {'name': 'aimed', 'orbit': -120.0, 'pitch': -10.0, 'radius': 1.5,
             'aim': 'point', 'aim_point': aim_point, 'outline': True},
        ], centre=centre, size=size)

        eye = lighting._lights_eye(column_major(m))
        identity = lighting._lights_eye(IDENTITY)
        c = apply(m, centre)
        self.assertVec(eye['centre'], c)
        self.assertAlmostEqual(eye['size'], size)
        self.assertIs(eye['enabled'], True)
        cam, pin, aimed = eye['lights']
        self.assertEqual([l['name'] for l in eye['lights']], ['cam', 'pin', 'aimed'])

        # camera light: the offset from the centre is eye-space, so the same
        # as under the identity, and radius is in scene sizes
        want = scale(orbit_dir(40.0, 20.0), 3.0 * size)
        self.assertVec(sub(cam['position'], c), want)
        self.assertVec(sub(identity['lights'][0]['position'],
                           identity['centre']), want)
        self.assertVec(cam['target'], c)
        self.assertVec(cam['direction'], unit(scale(want, -1.0)))
        self.assertEqual((cam['anchor'], cam['aim']), ('camera', 'centre'))

        # pinned light: where the matrix puts its world position
        p = apply(m, pinned_at)
        self.assertVec(pin['position'], p)
        self.assertVec(pin['direction'], unit(sub(c, p)))
        self.assertAlmostEqual(pin['aim_distance'], norm(sub(c, p)), delta=TOL)
        self.assertEqual(pin['anchor'], 'pinned')
        self.assertIs(pin['shadow'], True)

        # aimed light: placed like a camera light, the beam turned to the point
        p = add(c, scale(orbit_dir(-120.0, -10.0), 1.5 * size))
        t = apply(m, aim_point)
        self.assertVec(aimed['position'], p)
        self.assertVec(aimed['target'], t)
        self.assertVec(aimed['direction'], unit(sub(t, p)))
        self.assertAlmostEqual(aimed['aim_distance'], norm(sub(t, p)), delta=TOL)
        self.assertEqual(aimed['aim'], 'point')
        self.assertIs(aimed['outline'], True)

        # cone cosines: the prototype's, with the +1e-4 guard at softness 0
        self.assertAlmostEqual(cam['cos_outer'], math.cos(math.radians(30.0)), places=6)
        self.assertAlmostEqual(cam['cos_inner'], math.cos(math.radians(15.0)), places=6)
        self.assertAlmostEqual(pin['cos_outer'], math.cos(math.radians(25.0)), places=6)
        self.assertAlmostEqual(pin['cos_inner'],
                               math.cos(math.radians(25.0)) + 1e-4, places=6)
        self.assertGreater(pin['cos_inner'], pin['cos_outer'])
        # defaults: beam 45, softness 0.4
        self.assertAlmostEqual(aimed['cos_outer'], math.cos(math.radians(22.5)), places=6)
        self.assertAlmostEqual(aimed['cos_inner'],
                               math.cos(math.radians(22.5 * 0.6)), places=6)

    # --- the live camera -----------------------------------------------------------

    def testLiveCameraMatchesExplicit(self):
        """None (the bridge's path, SceneGetWorldToEye) equals the oracle's
        matrix built from cmd.get_view()."""
        self.rig([
            {'orbit': 30.0, 'pitch': 15.0, 'radius': 2.5},
            {'anchor': 'pinned', 'position': [12.0, 3.0, -7.0]},
            {'aim': 'point', 'aim_point': [-3.0, 4.0, 5.0], 'orbit': 100.0},
        ], centre=(2.0, -1.0, 4.0), size=6.0)
        self.turn()
        live = lighting._lights_eye()
        explicit = lighting._lights_eye(column_major(oracle_matrix()))
        self.assertVec(live['centre'], explicit['centre'])
        self.assertVec(live['centre'], oracle([2.0, -1.0, 4.0]))
        for got, want in zip(live['lights'], explicit['lights']):
            for key in ('position', 'target', 'direction'):
                self.assertVec(got[key], want[key], msg=key)
            for key in ('aim_distance', 'cos_outer', 'cos_inner', 'orbit',
                        'pitch', 'radius'):
                self.assertAlmostEqual(got[key], want[key], delta=TOL, msg=key)
        self.assertVec(live['lights'][1]['position'], oracle([12.0, 3.0, -7.0]))
        self.assertVec(live['lights'][2]['target'], oracle([-3.0, 4.0, 5.0]))

    def testCameraLightFollowsCamera(self):
        self.rig([{'orbit': -35.0, 'pitch': 25.0, 'radius': 3.0}],
                 centre=(4.0, -2.0, 6.0), size=7.0)
        want = scale(orbit_dir(-35.0, 25.0), 21.0)
        for step in (lambda: None, lambda: cmd.turn('y', 70),
                     lambda: cmd.turn('x', -40), lambda: cmd.move('z', -15),
                     lambda: cmd.turn('z', 120)):
            step()
            eye = lighting._lights_eye()
            self.assertVec(eye['centre'], oracle([4.0, -2.0, 6.0]))
            self.assertVec(sub(eye['lights'][0]['position'], eye['centre']), want)

    def testAimAnchoredLight(self):
        """Aimed at a point: the light still follows the camera; only the
        beam turns towards the point, which follows the molecule."""
        point = [-6.0, 5.0, 1.0]
        self.rig([{'orbit': 60.0, 'pitch': 10.0, 'radius': 2.0,
                   'aim': 'point', 'aim_point': point}],
                 centre=(0.0, 1.0, 2.0), size=5.0)
        want = scale(orbit_dir(60.0, 10.0), 10.0)
        targets = []
        for step in (lambda: None, lambda: cmd.turn('y', 80),
                     lambda: cmd.turn('x', 25)):
            step()
            eye = lighting._lights_eye()
            light = eye['lights'][0]
            self.assertVec(sub(light['position'], eye['centre']), want)
            t = oracle(point)
            self.assertVec(light['target'], t)
            self.assertVec(light['direction'], unit(sub(t, light['position'])))
            targets.append(sub(light['target'], eye['centre']))
        # the point moved relative to the camera, the light did not
        self.assertGreater(norm(sub(targets[0], targets[1])), 1.0)

    def testPinnedLight(self):
        at = [15.0, -3.0, 2.0]
        self.rig([{'anchor': 'pinned', 'position': at}],
                 centre=(0.0, 0.0, 0.0), size=5.0)
        first = lighting._lights_eye()['lights'][0]['position']
        self.assertVec(first, oracle(at))
        cmd.turn('y', 90)
        second = lighting._lights_eye()['lights'][0]['position']
        self.assertVec(second, oracle(at))
        self.assertGreater(norm(sub(first, second)), 1.0)

    def testPinnedDerivedOrbitPitchRadius(self):
        """A pinned light reports its current orbit, pitch and radius (it
        circles the plan as the molecule turns, decision 6)."""
        at, centre, size = [9.0, 6.0, -4.0], [1.0, 1.0, 1.0], 4.0
        self.rig([{'anchor': 'pinned', 'position': at, 'orbit': 11.0,
                   'pitch': 12.0, 'radius': 1.0}], centre=centre, size=size)
        for step in (lambda: None, lambda: cmd.turn('y', 65),
                     lambda: cmd.turn('x', -50)):
            step()
            d = sub(oracle(at), oracle(centre))
            light = lighting._lights_eye()['lights'][0]
            self.assertAlmostEqual(light['orbit'],
                                   math.degrees(math.atan2(d[0], d[2])), delta=1e-3)
            self.assertAlmostEqual(light['pitch'],
                                   math.degrees(math.asin(d[1] / norm(d))), delta=1e-3)
            self.assertAlmostEqual(light['radius'], norm(d) / size, delta=TOL)
        # the stored (last placed) values are untouched
        stored = cmd.get_lights()['lights'][0]
        self.assertEqual((stored['orbit'], stored['pitch'], stored['radius']),
                         (11.0, 12.0, 1.0))

    # --- pin, unpin, re-pin ---------------------------------------------------------

    def testPinUnpinKeepsEyePosition(self):
        centre, size = [2.0, 0.0, -1.0], 6.0
        self.rig([{'orbit': 30.0, 'pitch': 10.0, 'radius': 3.0}],
                 centre=centre, size=size)
        cmd.turn('y', 50)
        before = lighting._lights_eye()['lights'][0]['position']

        lighting._light_set(0, 'anchor', 1)
        light = cmd.get_lights()['lights'][0]
        self.assertEqual(light['anchor'], 'pinned')
        self.assertVec(oracle(light['position']), before)
        self.assertVec(lighting._lights_eye()['lights'][0]['position'], before)

        cmd.turn('x', 40)
        cmd.turn('y', -70)
        moved = lighting._lights_eye()['lights'][0]['position']
        self.assertVec(moved, oracle(light['position']))   # moved with the molecule
        self.assertGreater(norm(sub(moved, before)), 1.0)

        lighting._light_set(0, 'anchor', 0)
        eye = lighting._lights_eye()
        self.assertEqual(cmd.get_lights()['lights'][0]['anchor'], 'camera')
        self.assertVec(eye['lights'][0]['position'], moved)   # no jump
        # it is a camera light again: its offset now follows the camera
        offset = sub(eye['lights'][0]['position'], eye['centre'])
        cmd.turn('y', 33)
        eye = lighting._lights_eye()
        self.assertVec(sub(eye['lights'][0]['position'], eye['centre']), offset)
        # and its stored placement is where it was unpinned
        light = cmd.get_lights()['lights'][0]
        self.assertVec(scale(orbit_dir(light['orbit'], light['pitch']),
                             light['radius'] * size), offset)

    def testPinTwiceAndUnpinTwiceAreNoOps(self):
        self.rig([{'anchor': 'pinned', 'position': [5.0, 5.0, 5.0]},
                  {'orbit': 10.0}], centre=(0.0, 0.0, 0.0), size=3.0)
        cmd.turn('y', 40)
        before = cmd.get_lights()
        lighting._light_set(0, 'anchor', 1)
        lighting._light_set(1, 'anchor', 0)
        self.assertEqual(cmd.get_lights(), before)

    def testUnpinClampsRadius(self):
        """A pinned light farther than 8 sizes comes back to radius 8 along
        the same line when unpinned (documented: it moves)."""
        self.rig([{'anchor': 'pinned', 'position': [0.0, 0.0, 100.0]}],
                 centre=(0.0, 0.0, 0.0), size=1.0)
        lighting._light_set(0, 'anchor', 0)
        light = cmd.get_lights()['lights'][0]
        self.assertEqual(light['radius'], 8.0)
        eye = lighting._lights_eye()
        offset = sub(eye['lights'][0]['position'], eye['centre'])
        self.assertAlmostEqual(norm(offset), 8.0, delta=TOL)
        self.assertVec(unit(offset), unit(sub(oracle([0.0, 0.0, 100.0]),
                                              oracle([0.0, 0.0, 0.0]))))

    def testOrbitEditRepinsPinned(self):
        """Editing orbit, pitch or radius of a pinned light re-pins it at the
        camera-formula place, the other two taken from where it is now."""
        centre, size = [1.0, -2.0, 3.0], 4.0
        self.rig([{'anchor': 'pinned', 'position': [8.0, 4.0, -6.0]}],
                 centre=centre, size=size)
        self.turn()
        for field, value in (('orbit', 75.0), ('pitch', -20.0), ('radius', 2.5)):
            now = lighting._lights_eye()['lights'][0]
            placement = {k: now[k] for k in ('orbit', 'pitch', 'radius')}
            placement[field] = value
            lighting._light_set(0, field, value)
            light = cmd.get_lights()['lights'][0]
            self.assertEqual(light['anchor'], 'pinned', field)
            want = add(oracle(centre),
                       scale(orbit_dir(placement['orbit'], placement['pitch']),
                             placement['radius'] * size))
            self.assertVec(oracle(light['position']), want, msg=field)
            eye = lighting._lights_eye()['lights'][0]
            self.assertVec(eye['position'], want, msg=field)
            self.assertAlmostEqual(eye[field], value, delta=1e-3, msg=field)
            self.assertAlmostEqual(light[field], value, msg=field)
        # still pinned: it turns with the molecule
        cmd.turn('y', 45)
        self.assertVec(lighting._lights_eye()['lights'][0]['position'],
                       oracle(cmd.get_lights()['lights'][0]['position']))

    def testRepinFromTheCentreMovesTheLight(self):
        """A pinned light on the rig centre has no orbit, pitch or radius to
        keep: an orbit or pitch edit moves it out to radius 0.5 (the low end
        of the range, as on unpin), not nowhere. A light past 8 sizes comes
        in to 8, as on unpin."""
        centre, size = [1.0, -2.0, 3.0], 4.0
        for field, value in (('pitch', 45.0), ('orbit', -60.0)):
            self.rig([{'anchor': 'pinned', 'position': centre, 'orbit': 20.0}],
                     centre=centre, size=size)
            self.turn()
            lighting._light_set(0, field, value)
            light = cmd.get_lights()['lights'][0]
            self.assertEqual(light['anchor'], 'pinned', field)
            # the stored orbit (20) is kept, pitch 0, radius 0 -> 0.5
            placement = {'orbit': 20.0, 'pitch': 0.0, 'radius': 0.5}
            placement[field] = value
            want = add(oracle(centre),
                       scale(orbit_dir(placement['orbit'], placement['pitch']),
                             placement['radius'] * size))
            self.assertVec(oracle(light['position']), want, msg=field)
            eye = lighting._lights_eye()['lights'][0]
            self.assertVec(eye['position'], want, msg=field)
            for key in ('orbit', 'pitch', 'radius'):
                self.assertAlmostEqual(eye[key], placement[key], delta=1e-3,
                                       msg='%s: %s' % (field, key))
                self.assertAlmostEqual(light[key], placement[key],
                                       msg='%s: %s' % (field, key))

        self.rig([{'anchor': 'pinned', 'position': [0.0, 0.0, 100.0]}],
                 centre=(0.0, 0.0, 0.0), size=1.0)
        lighting._light_set(0, 'orbit', 30.0)
        eye = lighting._lights_eye()
        offset = sub(eye['lights'][0]['position'], eye['centre'])
        self.assertAlmostEqual(norm(offset), 8.0, delta=TOL)
        self.assertAlmostEqual(eye['lights'][0]['orbit'], 30.0, delta=1e-3)
        self.assertEqual(cmd.get_lights()['lights'][0]['radius'], 8.0)

    def testPositionPins(self):
        self.rig([{'orbit': 20.0}], centre=(0.0, 0.0, 0.0), size=2.0)
        lighting._light_set(0, 'position', [3.0, -4.0, 5.5])
        light = cmd.get_lights()['lights'][0]
        self.assertEqual(light['anchor'], 'pinned')
        self.assertEqual(light['position'], [3.0, -4.0, 5.5])
        self.turn()
        self.assertVec(lighting._lights_eye()['lights'][0]['position'],
                       oracle([3.0, -4.0, 5.5]))

    # --- units and edge cases ---------------------------------------------------------

    def testRadiusInSceneSizes(self):
        light = {'orbit': 25.0, 'pitch': 35.0, 'radius': 3.0}
        offsets = []
        for size in (5.0, 10.0):
            self.rig([light], centre=(1.0, 1.0, 1.0), size=size)
            eye = lighting._lights_eye(IDENTITY)
            offsets.append(sub(eye['lights'][0]['position'], eye['centre']))
        self.assertAlmostEqual(norm(offsets[0]), 15.0, delta=TOL)
        self.assertVec(offsets[1], scale(offsets[0], 2.0))

    def testCentreNotAtOrigin(self):
        """The lights circle the rig centre, not the rotation origin."""
        centre = [10.0, -4.0, 3.0]
        cmd.origin(position=[-20.0, 7.0, 1.0])
        self.turn()
        self.rig([{'orbit': 90.0, 'pitch': 0.0, 'radius': 1.0}],
                 centre=centre, size=2.0)
        eye = lighting._lights_eye()
        self.assertVec(eye['centre'], oracle(centre))
        self.assertVec(sub(eye['lights'][0]['position'], eye['centre']),
                       [2.0, 0.0, 0.0])

    def testDegenerateAim(self):
        # aim point on the light: the beam falls back towards the centre.
        # Off the z axis, so that this differs from the -z fallback below.
        self.rig([{'orbit': 90.0, 'pitch': 0.0, 'radius': 2.0,
                   'aim': 'point', 'aim_point': [20.0, 0.0, 0.0]}],
                 centre=(0.0, 0.0, 0.0), size=10.0)
        light = lighting._lights_eye(IDENTITY)['lights'][0]
        self.assertVec(light['position'], [20.0, 0.0, 0.0])
        self.assertVec(light['direction'], [-1.0, 0.0, 0.0])
        self.assertAlmostEqual(light['aim_distance'], 0.0, delta=TOL)
        # and under a rotated view, towards wherever the centre is now
        centre = [3.0, -1.0, 2.0]
        self.rig([{'orbit': -40.0, 'pitch': 25.0, 'radius': 1.5}],
                 centre=centre, size=4.0)
        self.turn()
        where = lighting._lights_eye()['lights'][0]['position']
        lighting._light_set(0, 'anchor', 1)              # pinned where it is
        pinned_at = cmd.get_lights()['lights'][0]['position']
        lighting._light_set(0, 'aim_point', pinned_at)   # aimed at itself
        light = lighting._lights_eye()['lights'][0]
        self.assertVec(light['position'], where)
        self.assertVec(light['direction'], unit(sub(oracle(centre), where)))
        self.assertAlmostEqual(light['aim_distance'], 0.0, delta=TOL)
        # a pinned light on the centre, aimed at it: -z
        self.rig([{'anchor': 'pinned', 'position': [1.0, 2.0, 3.0]}],
                 centre=(1.0, 2.0, 3.0), size=4.0)
        cmd.turn('y', 30)
        light = lighting._lights_eye()['lights'][0]
        self.assertVec(light['direction'], [0.0, 0.0, -1.0])
        self.assertAlmostEqual(light['radius'], 0.0, delta=TOL)
        for value in light['direction'] + light['position']:
            self.assertFalse(math.isnan(value))

    def testNarrowBeamConeStaysBelowOne(self):
        """cos_outer < cos_inner <= 1 for every beam in range: the soft band
        narrows for beams under ~2.3 degrees instead of pushing cos_inner
        past 1 (under ~1.6 degrees), where no direction could reach full
        intensity."""
        for beam in (1.0, 1.2, 1.5, 1.7, 2.0, 45.0, 170.0):
            for softness in (0.0, 0.4, 1.0):
                self.rig([{'beam': beam, 'softness': softness}])
                light = lighting._lights_eye(IDENTITY)['lights'][0]
                outer, inner = light['cos_outer'], light['cos_inner']
                label = 'beam %g softness %g' % (beam, softness)
                self.assertAlmostEqual(outer, math.cos(math.radians(beam / 2)),
                                       places=6, msg=label)
                self.assertLess(outer, inner, label)
                self.assertLessEqual(inner, 1.0, label)
                # the centre of the beam reaches full intensity
                t = (1.0 - outer) / (inner - outer)
                self.assertGreaterEqual(t, 1.0, label)
        # the prototype's 1e-4 band where it fits (beam 50, softness 0)
        self.rig([{'beam': 50.0, 'softness': 0.0}])
        light = lighting._lights_eye(IDENTITY)['lights'][0]
        self.assertAlmostEqual(light['cos_inner'],
                               math.cos(math.radians(25.0)) + 1e-4, places=6)

    def testEnabledFlagPassesThrough(self):
        self.rig([{}], enabled=False)
        self.assertIs(lighting._lights_eye()['enabled'], False)
        lighting._light_set(-1, 'enabled', 1)
        self.assertIs(lighting._lights_eye()['enabled'], True)
