"""The air (#618): haze and dust, the block a frame packs for the air pass.

SceneLightsFrame (layer1/SceneLights.cpp) copies the rig's air and frame in
eye space (airSource) from its one rig read, only while the rig is on with
haze or dust. SceneLightsAir then applies the gates (no air in grid mode, no
air without geometry), reads the dust clock (LightAirClock: a pin, movie time
in exports, 0 for an offscreen still, the live clock) and the settings
metal_light_air_resolution, metal_light_air_time and
metal_light_air_shadow_filter, and packs the 80-byte block
(LightAirPack, layer1/LightAir.cpp; layout in layer1/LightAirBlock.h).
SceneLightsAirAnimating answers the app's redraw policy. These tests reach
that C++ through _cmd (pymol.lighting._light_air_frame, _light_air_clock,
_light_air_time, _light_air_resolution, _light_air_shadow_filter,
_light_air_animating). No CI job builds catch2 or has a GPU, so this is how
the C++ is tested (lighting checklist, "What CI must cover").

Expected values never come from the code under test: they come from the
model's constants written out here (the plan's D6), explicit matrices,
cmd.get_setting_*, and float32 rounding through struct.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_air.py
"""
import math
import os
import re
import struct

from pymol import cgo, cmd, lighting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SENTINEL = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')

# LightAir.h, written out (the plan's D6, D9): every expected value is
# derived from these.
RANGE_SIZES, MIN_NEAR = 1.8, 0.5
CELL_SIZES, MIN_CELL = 0.15, 0.5
HAZE_DENSITY, MOTE_CELLS, DEFOCUS, OCCUPANCY = 0.73, 0.18, 0.3, 0.35
TIME_WRAP, DEFAULT_FPS = 20000.0, 30.0
GOLDEN = 0.6180339887498949
BLOCK_FLOATS = 20

SETTINGS = ((884, 'metal_light_air_resolution', 'i', 0),
            (885, 'metal_light_air_time', 'f', -1.0),
            (886, 'metal_light_air_shadow_filter', 'i', 0))

# Decoded fields at their block offsets (LightAirBlock.h).
OFFSETS = {'haze_density': 0, 'dust_occupancy': 1, 'scatter': 2,
           'seed_offset': 3, 'near': 4, 'far': 5, 'focus': 6, 'cell': 7,
           'time': 8, 'mote_radius': 9, 'defocus': 10, 'shadow_filter': 11,
           'scale': 12}


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def checkout_source(test, rel):
    if not os.path.isfile(os.path.join(ROOT, SENTINEL)):
        test.skipTest('not a repo checkout (no %s)' % SENTINEL)
    path = os.path.join(ROOT, rel)
    test.assertTrue(os.path.isfile(path), '%s is missing from the checkout' % rel)
    return path


def read_source(test, rel):
    with open(checkout_source(test, rel), encoding='utf-8') as handle:
        return handle.read()


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def function_body(text, name):
    match = re.search(r'\b%s\s*\([^;{]*\)\s*(?:const\s*)?\{' % name, text)
    if not match:
        raise AssertionError('%s is not defined' % name)
    depth = 0
    for i in range(match.end() - 1, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[match.end():i]
    raise AssertionError('unbalanced braces after %s' % name)


# --- matrices (row-major nested lists; no numpy) ------------------------------

def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)]
            for i in range(4)]


def translation(t):
    return [[1.0, 0.0, 0.0, t[0]], [0.0, 1.0, 0.0, t[1]],
            [0.0, 0.0, 1.0, t[2]], [0.0, 0.0, 0.0, 1.0]]


def uniform(s):
    return [[s, 0.0, 0.0, 0.0], [0.0, s, 0.0, 0.0], [0.0, 0.0, s, 0.0],
            [0.0, 0.0, 0.0, 1.0]]


def rot_x(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[1.0, 0.0, 0.0, 0.0], [0.0, c, -s, 0.0], [0.0, s, c, 0.0],
            [0.0, 0.0, 0.0, 1.0]]


def rot_y(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return [[c, 0.0, s, 0.0], [0.0, 1.0, 0.0, 0.0], [-s, 0.0, c, 0.0],
            [0.0, 0.0, 0.0, 1.0]]


def column_major(m):
    return [m[r][c] for c in range(4) for r in range(4)]


def apply(m, p):
    return [sum(m[i][j] * p[j] for j in range(3)) + m[i][3] for i in range(3)]


IDENTITY = [[1.0 if r == c else 0.0 for c in range(4)] for r in range(4)]
I16 = column_major(IDENTITY)
# A camera whose view is not the identity: rotated and pulled back.
MATRIX = mat_mul(translation([2.0, -3.0, -90.0]),
                 mat_mul(rot_x(25.0), rot_y(-40.0)))
M = column_major(MATRIX)

LIGHT = {'name': 'key', 'beam': 40.0, 'softness': 0.3, 'radius': 3.0,
         'orbit': -40.0, 'pitch': 30.0, 'intensity': 1.5}

AIR = {'haze': 0.6, 'dust': 0.5, 'dust_size': 0.4, 'dust_speed': 1.0,
       'scatter': 0.55, 'seed': 7}


def seed_offset(seed):
    v = seed * GOLDEN
    return f32((v - math.floor(v)) * 1000.0)


def expected(centre_eye, size_eye, air, time=0.0, scale=0.5, shadow_filter=1):
    """The block's named fields for an air source, from the model's
    constants (LightAirPack, written out). `centre_eye` and `size_eye` are
    rounded to float32 first, as the source holds them. `scale` defaults to
    0.5: metal_light_air_resolution 0 is half on the Mac too (L6)."""
    s = f32(size_eye)
    zc = -f32(centre_eye[2])
    cell = max(CELL_SIZES * s, MIN_CELL)
    return {
        'haze_density': f32(min(max(air['haze'], 0.0), 1.0) * HAZE_DENSITY / s),
        'dust_occupancy': f32(OCCUPANCY * min(max(air['dust'], 0.0), 1.0)),
        'scatter': f32(min(max(air['scatter'], -0.9), 0.9)),
        'seed_offset': seed_offset(air['seed']),
        'near': f32(max(zc - RANGE_SIZES * s, MIN_NEAR)),
        'far': f32(zc + RANGE_SIZES * s),
        'focus': f32(zc),
        'cell': f32(cell),
        'time': f32(time),
        'mote_radius': f32(air['dust_size'] * MOTE_CELLS * cell),
        'defocus': f32(DEFOCUS / s),
        'shadow_filter': shadow_filter,
        'scale': scale,
    }


class AirCase(testing.PyMOLTestCase):

    def load_m(self):
        cmd.load(self.datafile('1rx1.pdb'), 'm')

    def rig(self, centre=(0.0, 0.0, -100.0), size=20.0, air=None,
            enabled=True, lights=None):
        cmd.set_lights({'enabled': enabled, 'centre': list(centre),
                        'size': float(size),
                        'lights': [dict(LIGHT)] if lights is None else lights,
                        'air': dict(AIR if air is None else air)})

    def frame(self, matrix=I16, offscreen=True, wall=None, grid=None):
        return lighting._light_air_frame(matrix, offscreen=offscreen,
                                         wall=wall, grid=grid)

    def assertFields(self, got, want, rel=0.0, msg=None):
        self.assertIsNotNone(got, msg)
        for key, value in want.items():
            if rel and isinstance(value, float):
                self.assertAlmostEqual(got[key], value,
                                       delta=rel * max(1.0, abs(value)),
                                       msg='%s %s' % (key, msg or ''))
            else:
                self.assertEqual(got[key], value, '%s %s' % (key, msg or ''))


class TestSettings(AirCase):

    def testIndicesTypesDefaults(self):
        from pymol import setting
        text = strip_comments(read_source(self, os.path.join('layer1',
                                                             'SettingInfo.h')))
        for index, name, kind, default in SETTINGS:
            self.assertEqual(setting._get_index(name), index, name)
            pattern = (r'REC_i\(\s*%d,\s*%s\s*,\s*global\s*,\s*0\s*\)' if kind == 'i'
                       else r'REC_f\(\s*%d,\s*%s\s*,\s*global\s*,\s*-1\.0F\s*\)')
            self.assertRegex(text, pattern % (index, name))
            self.assertEqual(len(re.findall(r'\b%s\b' % name, text)), 1, name)
            if kind == 'i':
                self.assertEqual(cmd.get_setting_int(name), default, name)
            else:
                self.assertEqual(cmd.get_setting_float(name), default, name)

    def testNotPartOfTheLook(self):
        from pymol import raymol_scenes
        for _, name, _, _ in SETTINGS:
            self.assertNotIn(name, raymol_scenes.CAPTURE)


class TestResolution(testing.PyMOLTestCase):

    FN = staticmethod(lighting._light_air_resolution)
    # L6 (#618): 0 means half on the Mac as well as on iOS
    DESKTOP, MOBILE = 2, 2

    def testDefaults(self):
        self.assertEqual(self.FN(0, False), self.DESKTOP)
        self.assertEqual(self.FN(0, True), self.MOBILE)

    def testExplicit(self):
        for mobile in (False, True):
            self.assertEqual(self.FN(1, mobile), 1)
            self.assertEqual(self.FN(2, mobile), 2)

    def testOtherValuesReadAsDefault(self):
        for value in (-3, -1, 3, 7, 1000):
            self.assertEqual(self.FN(value, False), self.DESKTOP, value)
            self.assertEqual(self.FN(value, True), self.MOBILE, value)

    def testMacDefaultIsHalf(self):
        # L6 (#618): the desktop default is half, as on iOS; full stays at 1
        self.assertEqual(lighting._light_air_resolution(0, False), 2)
        self.assertEqual(lighting._light_air_resolution(1, False), 1)


class TestShadowFilter(TestResolution):

    FN = staticmethod(lighting._light_air_shadow_filter)
    DESKTOP, MOBILE = 1, 1

    def testMacDefaultIsHalf(self):
        pass  # the resolution's own test, not the filter's


class TestClock(testing.PyMOLTestCase):

    clock = staticmethod(lighting._light_air_clock)

    def testPinBeatsEverything(self):
        for offscreen in (False, True):
            for playing in (False, True):
                self.assertEqual(self.clock(2.5, offscreen, playing, 48, 15,
                                            30.0, 99.0), 2.5)
        self.assertEqual(self.clock(0.0, True, False, 48, 15, 30.0, 99.0), 0.0)

    def testMovieTime(self):
        # offscreen (an export) or a playing movie, with frames > 1
        self.assertAlmostEqual(self.clock(-1.0, True, False, 48, 15, 30.0, 9.0), 0.5)
        self.assertAlmostEqual(self.clock(-1.0, False, True, 48, 15, 30.0, 9.0), 0.5)
        self.assertAlmostEqual(self.clock(-1.0, True, False, 48, 0, 30.0, 9.0), 0.0)
        self.assertAlmostEqual(self.clock(-1.0, True, False, 48, 47, 24.0, 9.0),
                               47 / 24.0)
        # a negative frame reads as 0
        self.assertEqual(self.clock(-1.0, True, False, 48, -3, 30.0, 9.0), 0.0)

    def testOneFrameIsNeverAMovie(self):
        self.assertEqual(self.clock(-1.0, True, False, 1, 0, 30.0, 9.0), 0.0)
        self.assertEqual(self.clock(-1.0, False, True, 1, 0, 30.0, 9.0), 9.0)

    def testFpsZeroReadsAsThirty(self):
        for fps in (0.0, -5.0):
            self.assertAlmostEqual(self.clock(-1.0, True, False, 48, 15, fps, 9.0),
                                   15 / DEFAULT_FPS)

    def testStillAndLive(self):
        self.assertEqual(self.clock(-1.0, True, False, 1, 0, 30.0, 123.0), 0.0)
        self.assertEqual(self.clock(-1.0, False, False, 1, 0, 30.0, 123.0), 123.0)
        # a movie that is not playing: the live view keeps the wall clock
        self.assertEqual(self.clock(-1.0, False, False, 48, 15, 30.0, 123.0), 123.0)

    def testTime(self):
        time = lighting._light_air_time
        self.assertEqual(time(3.0, 2.0), 6.0)
        self.assertEqual(time(3.0, 0.0), 0.0)
        self.assertEqual(time(-3.0, 2.0), 0.0)
        self.assertEqual(time(3.0, -2.0), 0.0)
        self.assertAlmostEqual(time(TIME_WRAP + 1.5, 1.0), 1.5)
        self.assertAlmostEqual(time(15000.0, 2.0), 10000.0)
        self.assertGreaterEqual(time(1e300, 1e300), 0.0)
        self.assertEqual(time(float('nan'), 1.0), 0.0)
        for clock in (0.0, 0.5, 19999.0, 1e9):
            for speed in (0.0, 0.5, 10.0):
                t = time(clock, speed)
                self.assertGreaterEqual(t, 0.0)
                self.assertLess(t, TIME_WRAP)


class TestGate(AirCase):
    """No block unless the rig is on with haze or dust, something is shown,
    the grid is off and the air's range is in front of the camera."""

    def setUp(self):
        super().setUp()
        self.load_m()

    def testNoRig(self):
        self.assertIsNone(self.frame())

    def testRigOffWithAir(self):
        self.rig(enabled=False)
        self.assertIsNone(self.frame())

    def testNoLights(self):
        self.rig(lights=[])
        self.assertIsNone(self.frame())

    def testAirAtZero(self):
        # every other air field non-default: still no air
        self.rig(air=dict(AIR, haze=0.0, dust=0.0, dust_size=1.2,
                          dust_speed=3.0, scatter=-0.4, seed=99))
        self.assertIsNone(self.frame())

    def testAtmosphereWithoutRig(self):
        cmd.atmosphere(haze=0.3, dust=0.5)
        self.assertIsNotNone(lighting.get_lights())
        self.assertIsNone(self.frame(matrix=None))
        cmd.lights('three_point')
        self.assertIsNotNone(self.frame(matrix=None))

    def testHazeOnlyAndDustOnly(self):
        self.rig(air=dict(AIR, dust=0.0))
        self.assertIsNotNone(self.frame())
        self.rig(air=dict(AIR, haze=0.0))
        self.assertIsNotNone(self.frame())

    def testNothingEnabled(self):
        self.rig()
        self.assertIsNotNone(self.frame())
        cmd.disable('all')
        self.assertIsNone(self.frame())
        cmd.enable('m')
        self.assertIsNotNone(self.frame())

    def testOnlyTheMoveGizmo(self):
        cmd.load_cgo([cgo.SPHERE, 1.0, 2.0, 3.0, 4.0], '_move_gizmo', zoom=0)
        cmd.disable('m')
        self.rig()
        self.assertIsNone(self.frame())

    def testGrid(self):
        self.rig()
        self.assertIsNotNone(self.frame())
        self.assertIsNone(self.frame(grid=(2, 1, 1)))
        self.assertIsNone(self.frame(grid=(1, 1, 1)))

    def testReinitialize(self):
        self.rig()
        self.assertIsNotNone(self.frame())
        cmd.reinitialize()
        self.assertIsNone(self.frame())

    def testRigBehindTheCamera(self):
        # identity camera: eye z = world z; the camera looks down -z
        self.rig(centre=(0.0, 0.0, 100.0), size=20.0)
        self.assertIsNone(self.frame())
        # the far end at the camera, short of the near floor: still empty
        self.rig(centre=(0.0, 0.0, RANGE_SIZES * 20.0), size=20.0)
        self.assertIsNone(self.frame())
        # the far end just in front of the camera: some air
        self.rig(centre=(0.0, 0.0, -1.0), size=20.0)
        self.assertIsNotNone(self.frame())


class TestPack(AirCase):

    def setUp(self):
        super().setUp()
        self.load_m()

    def testIdentity(self):
        self.rig(centre=(3.0, -4.0, -100.0), size=20.0)
        self.assertFields(self.frame(), expected((3.0, -4.0, -100.0), 20.0, AIR))

    def testRangeValues(self):
        self.rig(centre=(0.0, 0.0, -100.0), size=20.0)
        got = self.frame()
        self.assertAlmostEqual(got['near'], 100.0 - 36.0, places=4)
        self.assertAlmostEqual(got['far'], 100.0 + 36.0, places=4)
        self.assertAlmostEqual(got['focus'], 100.0, places=4)
        self.assertAlmostEqual(got['cell'], 3.0, places=5)
        self.assertAlmostEqual(got['haze_density'], 0.6 * 0.73 / 20.0, places=7)
        self.assertAlmostEqual(got['dust_occupancy'], 0.35 * 0.5, places=6)
        self.assertAlmostEqual(got['mote_radius'], 0.4 * 0.18 * 3.0, places=6)
        self.assertAlmostEqual(got['defocus'], 0.3 / 20.0, places=7)

    def testNearFloorInsideTheAir(self):
        self.rig(centre=(0.0, 0.0, -10.0), size=20.0)
        got = self.frame()
        self.assertEqual(got['near'], MIN_NEAR)
        self.assertAlmostEqual(got['far'], 10.0 + 36.0, places=4)
        self.assertFields(got, expected((0.0, 0.0, -10.0), 20.0, AIR))

    def testCellFloor(self):
        self.rig(centre=(0.0, 0.0, -30.0), size=2.0)
        got = self.frame()
        self.assertEqual(got['cell'], MIN_CELL)
        self.assertFields(got, expected((0.0, 0.0, -30.0), 2.0, AIR))

    def testRotatedView(self):
        centre = (12.0, -7.0, 31.0)
        self.rig(centre=centre, size=17.5)
        eye = apply(MATRIX, centre)
        self.assertFields(self.frame(M), expected(eye, 17.5, AIR), rel=2e-6)

    def testLiveCamera(self):
        """No matrix: the live camera, as the #611 resolver sees it."""
        cmd.turn('y', 35)
        cmd.turn('x', -20)
        self.rig(centre=(4.0, -2.0, 9.0), size=20.0)
        eye = lighting._lights_eye()['centre']
        got = self.frame(matrix=None)
        self.assertAlmostEqual(got['focus'], -eye[2], delta=1e-3)

    def testOffscreenStillWithoutMovie(self):
        self.rig()
        self.assertEqual(self.frame()['time'], 0.0)
        self.assertEqual(self.frame(offscreen=False, wall=7.0)['time'], 7.0)

    def testScaledMatrix(self):
        """sizeEye is the size times the matrix's largest column scale."""
        self.rig(centre=(0.0, 0.0, -50.0), size=10.0)
        got = self.frame(column_major(uniform(2.0)))
        self.assertFields(got, expected((0.0, 0.0, -100.0), 20.0, AIR))

    def testScatterClampedAndSeedOffsets(self):
        offsets = set()
        for seed in range(21):
            self.rig(air=dict(AIR, seed=seed, scatter=0.9))
            got = self.frame()
            self.assertEqual(got['seed_offset'], seed_offset(seed))
            self.assertGreaterEqual(got['seed_offset'], 0.0)
            self.assertLess(got['seed_offset'], 1000.0)
            self.assertEqual(got['scatter'], f32(0.9))
            offsets.add(got['seed_offset'])
        self.assertEqual(len(offsets), 21)
        self.assertEqual(seed_offset(0), 0.0)
        self.rig(air=dict(AIR, scatter=-0.9, seed=1000000))
        got = self.frame()
        self.assertEqual(got['scatter'], f32(-0.9))
        self.assertEqual(got['seed_offset'], seed_offset(1000000))

    def testScaleInvariance(self):
        """Doubling the size doubles every length and halves the densities
        per Å."""
        self.rig(centre=(0.0, 0.0, -300.0), size=20.0)
        a = self.frame()
        self.rig(centre=(0.0, 0.0, -300.0), size=40.0)
        b = self.frame()
        for key in ('cell', 'mote_radius'):
            self.assertAlmostEqual(b[key], 2.0 * a[key], places=4, msg=key)
        self.assertAlmostEqual(b['far'] - b['focus'], 2.0 * (a['far'] - a['focus']),
                               places=3)
        self.assertAlmostEqual(b['focus'] - b['near'], 2.0 * (a['focus'] - a['near']),
                               places=3)
        for key in ('haze_density', 'defocus'):
            self.assertAlmostEqual(b[key], 0.5 * a[key], places=8, msg=key)
        self.assertEqual(a['dust_occupancy'], b['dust_occupancy'])

    def testRecenterMovesTheRangeHidingDoesNot(self):
        cmd.pseudoatom('far_away', pos=[200.0, 0.0, 0.0])
        lo, hi = cmd.get_extent('m')
        centre = [(x + y) / 2 for x, y in zip(lo, hi)]
        self.rig(centre=[centre[0], centre[1], centre[2] - 25.0], size=20.0)
        before = self.frame(M)
        cmd.disable('far_away')
        cmd.hide('everything', 'm and resi 1-20')
        self.assertEqual(self.frame(M), before)
        lighting._lights_recenter()
        after = self.frame(M)
        self.assertNotEqual(after['focus'], before['focus'])
        rig = lighting.get_lights()
        eye = apply(MATRIX, rig['centre'])
        self.assertAlmostEqual(after['focus'], -eye[2], delta=1e-3)

    def testResolutionAndFilterSettings(self):
        self.rig()
        # 0 and any other value give the platform default: half on the Mac
        # (L6), as on iOS; this build's frame shows it at 0.5
        for value, scale in ((0, 0.5), (1, 1.0), (2, 0.5), (5, 0.5)):
            cmd.set('metal_light_air_resolution', value)
            self.assertEqual(self.frame()['scale'], scale, value)
        cmd.set('metal_light_air_resolution', 0)
        for value, filt in ((0, 1), (1, 1), (2, 2), (-1, 1)):
            cmd.set('metal_light_air_shadow_filter', value)
            got = self.frame()
            self.assertEqual(got['shadow_filter'], filt, value)
            self.assertIsInstance(got['shadow_filter'], int)

    def testRendererFieldsAreZero(self):
        self.rig()
        block = self.frame()['block']
        self.assertEqual(block[13:16], [0.0, 0.0, 0.0])
        self.assertEqual(block[16:20], [0.0, 0.0, 0.0, 0.0])

    def testBlockLayout(self):
        self.rig(air=dict(AIR, seed=3))
        cmd.set('metal_light_air_resolution', 2)
        cmd.set('metal_light_air_shadow_filter', 2)
        cmd.set('metal_light_air_time', 1.25)
        got = self.frame(M)
        block = got['block']
        self.assertEqual(len(block), BLOCK_FLOATS)
        for key, offset in OFFSETS.items():
            self.assertEqual(block[offset], got[key], key)
        for v in block:
            self.assertEqual(v, f32(v))
        self.assertEqual(set(got), set(OFFSETS) | {'block'})


class TestMovieTime(AirCase):

    def setUp(self):
        super().setUp()
        self.load_m()
        cmd.mset('1 x48')
        cmd.set('movie_fps', 30)

    def time(self, **kw):
        kw.setdefault('offscreen', True)
        return self.frame(**kw)['time']

    def testFrames(self):
        for speed in (1.0, 2.0):
            self.rig(air=dict(AIR, dust_speed=speed))
            cmd.frame(1)
            self.assertEqual(self.time(), 0.0)
            cmd.frame(16)
            self.assertEqual(self.time(), f32(0.5 * speed), speed)
            cmd.frame(17)
            self.assertEqual(self.time(), f32(16 / 30.0 * speed), speed)

    def testMovieFps(self):
        self.rig()
        cmd.set('movie_fps', 24)
        cmd.frame(13)
        self.assertEqual(self.time(), f32(12 / 24.0))
        cmd.set('movie_fps', 0)
        self.assertEqual(self.time(), f32(12 / 30.0))

    def testSpeedZero(self):
        self.rig(air=dict(AIR, dust_speed=0.0))
        cmd.frame(16)
        self.assertEqual(self.time(), 0.0)

    def testPin(self):
        self.rig(air=dict(AIR, dust_speed=2.0))
        cmd.frame(16)
        cmd.set('metal_light_air_time', 2.0)
        self.assertEqual(self.time(), 4.0)
        self.assertEqual(self.time(offscreen=False, wall=50.0), 4.0)

    def testLiveNotPlaying(self):
        self.rig(air=dict(AIR, dust_speed=2.0))
        cmd.frame(16)
        self.assertEqual(self.time(offscreen=False, wall=50.0), 100.0)


class TestAnimating(AirCase):

    def setUp(self):
        super().setUp()
        self.load_m()

    def testFalse(self):
        animating = lighting._light_air_animating
        self.assertIs(animating(), False)                     # no rig
        self.rig(enabled=False)
        self.assertIs(animating(), False)                     # rig off
        self.rig(air=dict(AIR, dust=0.0))
        self.assertIs(animating(), False)                     # haze only
        self.rig(air=dict(AIR, dust_speed=0.0))
        self.assertIs(animating(), False)                     # speed 0
        self.rig()
        cmd.set('metal_light_air_time', 1.0)
        self.assertIs(animating(), False)                     # pinned
        cmd.set('metal_light_air_time', -1.0)
        cmd.disable('all')
        self.assertIs(animating(), False)                     # no geometry
        cmd.load_cgo([cgo.SPHERE, 1.0, 2.0, 3.0, 4.0], '_move_gizmo', zoom=0)
        self.assertIs(animating(), False)                     # overlay only

    def testTrue(self):
        self.rig()
        self.assertIs(lighting._light_air_animating(), True)
        cmd.set('metal_light_air_time', 0.0)
        self.assertIs(lighting._light_air_animating(), False)
        cmd.set('metal_light_air_time', -0.5)
        self.assertIs(lighting._light_air_animating(), True)


class TestRigUntouched(AirCase):
    """The rig block (#613, #616) and the rest of get_light_frame do not
    depend on the air or on the air settings."""

    def testFrameIndependentOfTheAir(self):
        self.load_m()
        lo, hi = cmd.get_extent('m')
        centre = [(a + b) / 2 for a, b in zip(lo, hi)]
        lights = [dict(LIGHT, shadow=True), dict(LIGHT, name='fill', orbit=60.0)]
        self.rig(centre=centre, size=20.0, lights=lights,
                 air=dict(AIR, haze=0.0, dust=0.0))
        want = lighting._light_frame(M)
        self.assertIsNotNone(want['rig'])
        self.rig(centre=centre, size=20.0, lights=lights)
        self.assertEqual(lighting._light_frame(M), want)
        cmd.set('metal_light_air_resolution', 2)
        cmd.set('metal_light_air_time', 3.0)
        cmd.set('metal_light_air_shadow_filter', 2)
        self.assertEqual(lighting._light_frame(M), want)


class TestSource(testing.PyMOLTestCase):

    PYTHON = re.compile(r'os_python\.h|Python\.h|\bPConv\w*|\bPyObject\b'
                        r'|\bPy_\w+|PyMOLGlobals|LightRigPy\.h|SettingGet')
    REDRAW = re.compile(r'NeedRedisplay|SceneInvalidate|OrthoDirty|SceneChanged')

    def read(self, rel):
        return strip_comments(read_source(self, rel))

    def scene_lights(self):
        return self.read(os.path.join('layer1', 'SceneLights.cpp'))

    def testPureFiles(self):
        for name in ('LightAir.h', 'LightAir.cpp', 'LightAirBlock.h'):
            text = self.read(os.path.join('layer1', name))
            found = self.PYTHON.search(text)
            self.assertIsNone(found, '%s uses %r' % (name, found and found.group(0)))
        block = self.read(os.path.join('layer1', 'LightAirBlock.h'))
        self.assertEqual(re.findall(r'#include\s+"', block), [])
        self.assertRegex(block, r'static_assert\(sizeof\(LightAirBlock\)\s*==\s*80')
        for field, offset in (('medium', 0), ('range', 16), ('motion', 32),
                              ('view', 48), ('proj', 64)):
            self.assertRegex(block, r'offsetof\(LightAirBlock,\s*%s\)\s*==\s*%d'
                             % (field, offset))

    def testConstants(self):
        header = self.read(os.path.join('layer1', 'LightAir.h'))
        for name, value in (('kLightAirRangeSizes', RANGE_SIZES),
                            ('kLightAirMinNear', MIN_NEAR),
                            ('kLightAirCellSizes', CELL_SIZES),
                            ('kLightAirMinCell', MIN_CELL),
                            ('kLightAirHazeDensity', HAZE_DENSITY),
                            ('kLightAirMoteCells', MOTE_CELLS),
                            ('kLightAirDefocus', DEFOCUS),
                            ('kLightAirOccupancy', OCCUPANCY),
                            ('kLightAirTimeWrap', TIME_WRAP),
                            ('kLightAirDefaultFps', DEFAULT_FPS),
                            ('kLightAirHazePhaseCap', 5.0),
                            ('kLightAirDustPhaseCap', 8.0),
                            ('kLightAirFalloffCap', 4.0),
                            ('kLightAirHazeSteps', 48),
                            ('kLightAirDustLayers', 32)):
            match = re.search(r'\b%s\s*=\s*([0-9.eE+-]+)\s*;' % name, header)
            self.assertIsNotNone(match, name)
            self.assertEqual(float(match.group(1)), value, name)

    def testFrameOnlyCopiesTheSource(self):
        body = function_body(self.scene_lights(), 'SceneLightsFrame')
        self.assertEqual(body.count('SceneGetLightRig('), 1)
        statements = re.findall(r'if\s*\(([^;]*?)\)\s*frame\.airSource\s*=\s*([^;]*);',
                                body)
        self.assertEqual(len(statements), 1, 'one airSource statement')
        self.assertEqual(body.count('airSource'), 1)
        cond, value = statements[0]
        self.assertRegex(cond, r'^\s*frame\.rig\s*&&\s*pymol::LightAirActive\(rig->air\)\s*$')
        self.assertRegex(value, r'^pymol::LightAirSourceOf\(\*rig,\s*worldToEye\)$')
        # after #616's shadow block, the last statement before the return
        self.assertGreater(body.index('airSource'), body.index('LightShadowPlan'))
        for token in ('Setting', 'Extent', 'grid', 'Clock', 'UtilGetSeconds',
                      'Movie', 'Renderer'):
            self.assertNotIn(token, cond + value, token)

    def testAirReadsInOrder(self):
        body = function_body(self.scene_lights(), 'SceneLightsAir')
        first = re.search(r'\S', body)
        self.assertTrue(body[first.start():].startswith('if (!frame.airSource)'),
                        body[:80])
        grid = body.index('grid')
        extent = body.index('SceneGetLightShadowExtent(')
        self.assertLess(grid, extent)
        for token in ('cSetting_metal_light_air_time',
                      'cSetting_metal_light_air_resolution',
                      'cSetting_metal_light_air_shadow_filter',
                      'cSetting_movie_fps', 'SceneGetFrame(', 'SceneCountFrames(',
                      'MoviePlaying(', 'UtilGetSeconds(', 'offscreenFrame('):
            self.assertEqual(body.count(token), 1, token)
            self.assertGreater(body.index(token), extent, token)
        # MoviePlaying (which may write Playing) only on live, unpinned frames
        self.assertRegex(body, r'if\s*\(\s*!in\.offscreen\s*&&\s*!\(in\.pinned\s*>=\s*0\.0\)\s*\)'
                               r'\s*in\.playing\s*=\s*MoviePlaying\(G\)')
        self.assertIn('LightAirPack(', body)

    def testAnimatingOrder(self):
        body = function_body(self.scene_lights(), 'SceneLightsAirAnimating')
        self.assertEqual(body.count('SceneGetLightShadowExtent('), 1)
        extent = body.index('SceneGetLightShadowExtent(')
        for token in ('LightRigIsOn(', 'cSetting_metal_light_air_time',
                      'MoviePlaying(', 'grid'):
            self.assertLess(body.index(token), extent, token)

    def testNoRedrawRequests(self):
        scene_lights = self.scene_lights()
        for name in ('SceneLightsAir', 'SceneLightsAirAnimating'):
            body = function_body(scene_lights, name)
            self.assertIsNone(self.REDRAW.search(body), name)
        for name in ('LightAir.cpp', 'LightAir.h'):
            text = self.read(os.path.join('layer1', name))
            self.assertIsNone(self.REDRAW.search(text), name)

    def testSceneRenderCallsTheAirOnceAfterTheRig(self):
        body = function_body(self.read(os.path.join('layer1', 'SceneRender.cpp')),
                             'SceneRenderMetal')
        self.assertEqual(body.count('SceneLightsAir('), 1)
        self.assertEqual(body.count('setLightAir('), 1)
        self.assertRegex(body, r'const auto air = SceneLightsAir\(G, lights\);\s*'
                               r'G->Renderer->setLightAir\(air \? &\*air : nullptr\);')
        self.assertLess(body.index('setGpuTiming('), body.index('SceneLightsAir('))
        self.assertLess(body.index('setLightAir('), body.index('SceneRenderAll('))

    def testRenderer(self):
        renderer = self.read(os.path.join('layerGraphics', 'Renderer.h'))
        self.assertRegex(renderer, r'virtual void setLightAir\(const LightAirBlock\*[^)]*\)\s*\{\s*\}')
        self.assertRegex(renderer, r'virtual bool offscreenFrame\(\)\s*const\s*\{\s*return false;\s*\}')
        mm = self.read(os.path.join('layerGraphics', 'metal', 'RendererMetal.mm'))
        body = function_body(mm, 'RendererMetal::setLightAir')
        self.assertEqual(re.sub(r'\s+', ' ', body).strip(),
                         '_lightAirOn = air != nullptr; if (air) _lightAirBlock = *air;')
        body = function_body(mm, 'RendererMetal::offscreenFrame')
        self.assertEqual(body.strip(), 'return _offscreen;')
        body = function_body(mm, 'RendererMetal::beginFrame')
        self.assertEqual(body.count('_lightAirOn = false;'), 1)
