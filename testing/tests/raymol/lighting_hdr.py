"""HDR colour for the light rig (#624): the tone curve, exposure, the
metal_light_hdr switch and what a frame carries of them.

The curve T (layer1/LightTone.{h,cpp}: LightToneScalar, LightToneScalarInverse,
LightTone, LightToneInverse), the exposure a rig frame applies
(LightToneExposure) and the switch (LightHdrOn) are pure C++. SceneLightsFrame
(layer1/SceneLights.cpp) fills the rig block's last float4, `tone`
(exposure, 1 = HDR, 0, 0), through SceneLightsToneFill, and only while the
rig is on: with no rig, or a rig that is off, neither metal_exposure nor
metal_light_hdr is read. These tests reach that C++ through _cmd
(light_tone, light_tone_scalar, light_tone_exposure, light_hdr,
get_light_hdr, get_light_frame). No CI job builds catch2 or has a GPU, so
this is how the C++ is tested (lighting checklist, "What CI must cover").

Expected values never come from the code under test: they come from the
curve's definition written out here (plans/624.md D2) in double precision,
scripts/lighting/check_hdr.py's python twin (TestTwin ties the harness to the
core), cmd.get_setting_*, and float32 rounding through struct.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_hdr.py
"""
import importlib.util
import math
import os
import re
import struct
import unittest

from pymol import cmd, lighting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SENTINEL = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')
CHECK_HDR = os.path.join(ROOT, 'scripts', 'lighting', 'check_hdr.py')

try:
    import numpy
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False

# LightTone.h, written out (plans/624.md D2, D4, D10): every expected value is
# derived from these. Part 6 of #624 tuned (KNEE, WHITE) once; TestSource pins
# them equal to the header.
KNEE, WHITE, MAX_EXPOSURE = 0.55, 10.0, 16.0
SETTING = (887, 'metal_light_hdr', 0)
BLOCK_FLOATS = 172
TONE_AT = 168            # the tone: the block's last float4 (after #616's 168)
NAN, INF = float('nan'), float('inf')
ULP1 = 2.0 ** -23        # float32 epsilon


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


# --- the C++ through _cmd -------------------------------------------------------

def tone(values, inverse=False):
    """LightTone (or LightToneInverse) of each [r, g, b]."""
    with cmd.lockcm:
        return cmd._cmd.light_tone(cmd._COb, [list(map(float, v)) for v in values],
                                   bool(inverse))


def tone1(rgb, inverse=False):
    return tone([rgb], inverse)[0]


def scalar(values, inverse=False):
    """LightToneScalar (or LightToneScalarInverse) of each value."""
    with cmd.lockcm:
        return cmd._cmd.light_tone_scalar(cmd._COb, [float(v) for v in values],
                                          bool(inverse))


def exposure(x):
    with cmd.lockcm:
        return cmd._cmd.light_tone_exposure(cmd._COb, float(x))


def hdr_mode(setting, mobile):
    with cmd.lockcm:
        return cmd._cmd.light_hdr(cmd._COb, int(setting), bool(mobile))


def light_hdr():
    with cmd.lockcm:
        return cmd._cmd.get_light_hdr(cmd._COb)


# --- the model (D2), in double precision --------------------------------------------

def model_scalar(m):
    if not math.isfinite(m) or m <= 0.0:
        return 0.0
    if m <= KNEE:
        return m
    if m >= WHITE:
        return 1.0
    s = 1.0 - KNEE
    w = (WHITE - KNEE) / s
    t = (m - KNEE) / s
    return KNEE + s * t * (1.0 + t / (w * w)) / (1.0 + t)


def model_inverse(y):
    if not math.isfinite(y) or y <= 0.0:
        return 0.0
    if y <= KNEE:
        return y
    if y >= 1.0:
        return WHITE
    s = 1.0 - KNEE
    w = (WHITE - KNEE) / s
    u = (y - KNEE) / s
    t = 2.0 * u / ((1.0 - u) + math.sqrt((1.0 - u) ** 2 + 4.0 * u / (w * w)))
    return KNEE + s * t


def frange(lo, hi, n):
    return [lo + (hi - lo) * i / (n - 1) for i in range(n)]


class TestSetting(testing.PyMOLTestCase):

    def testIndexTypeDefault(self):
        from pymol import setting
        index, name, default = SETTING
        self.assertEqual(setting._get_index(name), index)
        self.assertEqual(cmd.get_setting_int(name), default)
        text = strip_comments(read_source(self, os.path.join('layer1',
                                                             'SettingInfo.h')))
        self.assertRegex(text, r'REC_i\(\s*%d,\s*%s\s*,\s*global\s*,\s*0\s*\)'
                         % (index, name))
        self.assertEqual(len(re.findall(r'\b%s\b' % name, text)), 1)

    def testNotPartOfTheLook(self):
        from pymol import raymol_scenes
        self.assertNotIn(SETTING[1], raymol_scenes.CAPTURE)
        # the exposure stays part of a scene's look (#13)
        self.assertIn('metal_exposure', raymol_scenes.CAPTURE)


class TestMode(testing.PyMOLTestCase):

    def testDefaultIsOnForBoth(self):
        # 0: the platform default, on for the Mac and on for iOS (provisional
        # until #623 measures it on devices)
        self.assertIs(hdr_mode(0, False), True)
        self.assertIs(hdr_mode(0, True), True)

    def testExplicit(self):
        for mobile in (False, True):
            self.assertIs(hdr_mode(1, mobile), True)
            self.assertIs(hdr_mode(2, mobile), False)

    def testOtherValuesReadAsDefault(self):
        for value in (-1, 3, 7, 99, -1000):
            for mobile in (False, True):
                self.assertIs(hdr_mode(value, mobile), hdr_mode(0, mobile), value)


class TestExposure(testing.PyMOLTestCase):

    def testKept(self):
        for x in (1.0, 0.5, 0.2, 2.0, 4.0 / 7.0, 0.0, MAX_EXPOSURE):
            self.assertEqual(exposure(x), f32(x), x)

    def testNonFiniteReadsAsOne(self):
        for x in (NAN, INF, -INF):
            self.assertEqual(exposure(x), 1.0, x)

    def testClamped(self):
        self.assertEqual(exposure(-2.0), 0.0)
        self.assertEqual(exposure(100.0), MAX_EXPOSURE)
        self.assertEqual(exposure(16.5), MAX_EXPOSURE)


class TestCurve(testing.PyMOLTestCase):

    def testIdentityAtOrBelowTheKnee(self):
        xs = [f32(x) for x in frange(0.0, KNEE, 601)] + [f32(KNEE)]
        self.assertEqual(scalar(xs), xs)
        self.assertEqual(scalar(xs, inverse=True), xs)
        # a colour whose largest channel is at or below the knee: exactly
        for rgb in ([KNEE, 0.3, 0.1], [0.1, 0.2, 0.3], [0.0, 0.0, 0.0],
                    [f32(KNEE)] * 3, [KNEE - 1e-4, 0.0, KNEE - 1e-4]):
            want = [f32(c) for c in rgb]
            self.assertEqual(tone1(rgb), want, rgb)
            self.assertEqual(tone1(rgb, inverse=True), want, rgb)

    def testWhitePoint(self):
        self.assertEqual(scalar([WHITE, WHITE + 1.0, 1e6, 3.0e38]), [1.0] * 4)
        self.assertEqual(scalar([1.0, 1.5], inverse=True), [WHITE, WHITE])
        # a colour at or beyond W: its largest channel exactly 1, the hue kept
        for rgb in ([WHITE, WHITE / 2.0, WHITE / 4.0], [1.0, 20.0, 5.0],
                    [100.0, 100.0, 100.0]):
            got = tone1(rgb)
            self.assertEqual(max(got), 1.0, rgb)
            m = max(rgb)
            for g, c in zip(got, rgb):
                self.assertAlmostEqual(g, c / m, delta=2 * ULP1)

    def testMatchesTheModel(self):
        xs = frange(0.0, 12.0, 2401)
        for x, got in zip(xs, scalar(xs)):
            self.assertAlmostEqual(got, model_scalar(f32(x)), delta=4 * ULP1, msg=x)
        ys = frange(0.0, 1.0, 1001)
        for y, got in zip(ys, scalar(ys, inverse=True)):
            want = model_inverse(f32(y))
            self.assertAlmostEqual(got, want, delta=8 * ULP1 * max(1.0, want), msg=y)

    def testCalibration(self):
        # D2's curve as #624 part 6 tuned it once and froze it (k 0.55, W 10):
        # T(1.0) = 0.776, within D2's constraint T(1) >= 0.75
        self.assertEqual((KNEE, WHITE), (0.55, 10.0))
        self.assertAlmostEqual(scalar([1.0])[0], 0.7755, delta=0.0005)
        self.assertGreaterEqual(scalar([1.0])[0], 0.75)

    def testNonDecreasing(self):
        xs = frange(0.0, 10.0, 10001)
        ys = scalar(xs)
        for a, b, x in zip(ys, ys[1:], xs[1:]):
            self.assertLessEqual(a, b, x)
        self.assertTrue(all(0.0 <= y <= 1.0 for y in ys))
        inv = scalar(frange(0.0, 1.0, 10001), inverse=True)
        for a, b in zip(inv, inv[1:]):
            self.assertLessEqual(a, b)

    def testC1AtTheKnee(self):
        h = 1e-3
        k = f32(KNEE)
        t0, t1, t2 = scalar([k, k + h, k + 2 * h])
        tm = scalar([k - h])[0]
        left = (t0 - tm) / h
        # second order one-sided, so the shoulder's curvature cancels
        right = (4.0 * t1 - t2 - 3.0 * t0) / (2.0 * h)
        self.assertAlmostEqual(left, 1.0, delta=1e-3)
        self.assertAlmostEqual(right, 1.0, delta=1e-3)

    def testConcaveAboveTheKnee(self):
        xs = frange(KNEE, WHITE, 1401)
        ys = scalar(xs)
        h = xs[1] - xs[0]
        slopes = [(b - a) / h for a, b in zip(ys, ys[1:])]
        for a, b in zip(slopes, slopes[1:]):
            # the slope never rises (float32 noise on a difference of h)
            self.assertLessEqual(b, a + 4 * ULP1 / h)
        self.assertLess(slopes[-1], slopes[0])

    def testHueKept(self):
        for scale in (0.8, 1.0, 2.0, 3.5, 7.9):
            rgb = [1.0 * scale, 0.55 * scale, 0.2 * scale]
            got = tone1(rgb)
            self.assertAlmostEqual(got[1] / got[0], 0.55, delta=1e-6, msg=scale)
            self.assertAlmostEqual(got[2] / got[0], 0.2, delta=1e-6, msg=scale)
            self.assertAlmostEqual(got[0], model_scalar(f32(rgb[0])), delta=4 * ULP1)

    def testInverseRoundTrip(self):
        ys = [f32(y) for y in frange(0.0, 1.0, 4001)]
        back = scalar(scalar(ys, inverse=True))
        for y, b in zip(ys, back):
            self.assertAlmostEqual(b, y, delta=1e-6, msg=y)
        rgb = [[y, 0.5 * y, 0.25 * y] for y in ys[::40]]
        back = tone(tone(rgb, inverse=True))
        for c, b in zip(rgb, back):
            for want, got in zip(c, b):
                self.assertAlmostEqual(got, f32(want), delta=1e-6, msg=c)
        self.assertEqual(scalar([1.0], inverse=True), [WHITE])

    def testNaNInfAndNegatives(self):
        self.assertEqual(scalar([NAN, INF, -INF, -1.0, -1e-9]), [0.0] * 5)
        self.assertEqual(scalar([NAN, INF, -INF, -1.0], inverse=True), [0.0] * 4)
        for inverse in (False, True):
            self.assertEqual(tone1([NAN, 1.0, 1.0], inverse), [0.0] * 3)
            self.assertEqual(tone1([2.0, INF, 1.0], inverse), [0.0] * 3)
            self.assertEqual(tone1([0.5, 0.2, -INF], inverse), [0.0] * 3)
            self.assertEqual(tone1([-1.0, 0.5, 0.2], inverse),
                             [0.0, 0.5, f32(0.2)])
        # negatives read as 0 before the largest channel is taken
        self.assertEqual(tone1([-5.0, 2.0, 0.0]), tone1([0.0, 2.0, 0.0]))

    def testInverseClipsToOne(self):
        self.assertEqual(tone1([2.0, 0.5, 0.0], inverse=True),
                         tone1([1.0, 0.5, 0.0], inverse=True))


@unittest.skipUnless(HAVE_NUMPY, 'needs numpy (check_hdr.py)')
class TestTwin(testing.PyMOLTestCase):
    """The harness's python twin (scripts/lighting/check_hdr.py) is this
    curve: the L2 checks model what the build renders."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.twin = None
        if os.path.isfile(CHECK_HDR):
            spec = importlib.util.spec_from_file_location('_lighting_hdr_twin',
                                                          CHECK_HDR)
            cls.twin = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.twin)

    def setUp(self):
        checkout_source(self, os.path.join('scripts', 'lighting', 'check_hdr.py'))
        super().setUp()

    def testConstants(self):
        self.assertEqual(self.twin.TONE_KNEE, KNEE)
        self.assertEqual(self.twin.TONE_WHITE, WHITE)

    def testScalar(self):
        xs = frange(0.0, 12.0, 1201)
        want = self.twin.tone_scalar(numpy.asarray(xs, dtype='float32'))
        for x, got, w in zip(xs, scalar(xs), want):
            self.assertAlmostEqual(got, float(w), delta=2e-6, msg=x)
        ys = frange(0.0, 1.0, 1001)
        want = self.twin.tone_scalar_inverse(numpy.asarray(ys, dtype='float32'))
        for y, got, w in zip(ys, scalar(ys, inverse=True), want):
            self.assertAlmostEqual(got, float(w), delta=2e-6 * max(1.0, float(w)),
                                   msg=y)

    def testColour(self):
        rgb = [[a, a * 0.55, a * 0.2] for a in frange(0.0, 10.0, 201)] + \
              [[0.1 * a, a, 0.4 * a] for a in frange(0.0, 3.0, 61)] + \
              [[NAN, 1.0, 1.0], [-1.0, 2.0, 0.5], [INF, 0.0, 0.0]]
        f = numpy.asarray(rgb, dtype='float32')
        for got, want in zip(tone(rgb), self.twin.tone(f)):
            for g, w in zip(got, want):
                self.assertAlmostEqual(g, float(w), delta=2e-6, msg=rgb)
        disp = [[min(c, 1.0) for c in v] for v in rgb]
        f = numpy.asarray(disp, dtype='float32')
        for got, want in zip(tone(disp, inverse=True), self.twin.tone_inverse(f)):
            for g, w in zip(got, want):
                self.assertAlmostEqual(g, float(w), delta=2e-6 * max(1.0, float(w)))


class TestQuantised(testing.PyMOLTestCase):
    """The air composite (Part 5) inverts T on an 8-bit colour, adds light in
    scene units and maps back: the 8-bit storage costs at most one level."""

    def testOneLevel(self):
        cs = frange(0.0, 1.0, 1021)
        c8 = [round(c * 255.0) / 255.0 for c in cs]
        inv = scalar(cs, inverse=True)
        inv8 = scalar(c8, inverse=True)
        for a in frange(0.01, 2.0, 25):
            exact = scalar([x + a for x in inv])
            stored = scalar([x + a for x in inv8])
            worst = max(abs(p - q) for p, q in zip(exact, stored))
            self.assertLessEqual(worst, 1.0 / 255.0, a)

    def testExactBelowTheKnee(self):
        c8 = [f32(i / 255.0) for i in range(256) if i / 255.0 <= KNEE]
        self.assertEqual(scalar(scalar(c8, inverse=True)), c8)


class TestCommute(testing.PyMOLTestCase):
    """`recover`'s premise: intensity I at exposure e, with e * I = I', maps
    like I' at exposure 1, within float32 rounding."""

    def testPairs(self):
        xs = frange(0.05, 2.5, 50)
        for intensity, e, other in ((3.5, 4.0 / 7.0, 2.0), (3.0, 2.0 / 3.0, 2.0),
                                    (3.0, 1.0 / 3.0, 1.0), (2.0, 0.5, 1.0)):
            a = [f32(f32(f32(intensity) * f32(x)) * f32(e)) for x in xs]
            b = [f32(f32(other) * f32(x)) for x in xs]
            for p, q in zip(a, b):
                self.assertLessEqual(abs(p - q), 2 * ULP1 * max(p, q))
            for p, q in zip(scalar(a), scalar(b)):
                self.assertLessEqual(abs(p - q), 2 * ULP1)


# --- what a frame carries ----------------------------------------------------------

LIGHT = {'name': 'key', 'beam': 40.0, 'softness': 0.3, 'radius': 3.0,
         'orbit': -40.0, 'pitch': 30.0, 'intensity': 1.5}
I16 = [1.0 if r == c else 0.0 for c in range(4) for r in range(4)]


class FrameCase(testing.PyMOLTestCase):

    def rig(self, enabled=True, shadow=False):
        cmd.set_lights({'enabled': enabled, 'centre': [0.0, 0.0, -100.0],
                        'size': 20.0,
                        'lights': [dict(LIGHT, shadow=shadow),
                                   dict(LIGHT, name='fill', orbit=60.0)]})

    def frame(self):
        return lighting._light_frame(I16)


class TestFrame(FrameCase):

    def testToneIsTheLastFloat4(self):
        self.rig()
        packed = self.frame()['rig']
        block = packed['block']
        self.assertEqual(len(block), BLOCK_FLOATS)
        self.assertEqual(block[TONE_AT:], [1.0, 1.0, 0.0, 0.0])
        self.assertEqual(packed['tone'], block[TONE_AT:])
        self.assertEqual(cmd.get_setting_float('metal_exposure'), 1.0)

    def testExposureAndSwitch(self):
        self.rig()
        cmd.set('metal_exposure', 0.7)
        self.assertEqual(self.frame()['rig']['tone'], [f32(0.7), 1.0, 0.0, 0.0])
        for value, on in ((0, 1.0), (1, 1.0), (2, 0.0), (7, 1.0), (-1, 1.0)):
            cmd.set('metal_light_hdr', value)
            self.assertEqual(self.frame()['rig']['tone'], [f32(0.7), on, 0.0, 0.0],
                             value)
        cmd.set('metal_light_hdr', 0)
        cmd.set('metal_exposure', 100.0)
        self.assertEqual(self.frame()['rig']['tone'][0], MAX_EXPOSURE)
        cmd.set('metal_exposure', -2.0)
        self.assertEqual(self.frame()['rig']['tone'][0], 0.0)

    def testNonFiniteExposure(self):
        self.rig()
        cmd.set('metal_exposure', NAN)
        if math.isfinite(cmd.get_setting_float('metal_exposure')):
            self.skipTest('the setting does not hold nan')
        self.assertEqual(self.frame()['rig']['tone'][0], 1.0)

    def testOnlyAppended(self):
        """The first 168 floats are #616's block: the tone settings never
        change them, with or without studio shadows."""
        for shadows in (0, 1):
            cmd.set('metal_shadows', shadows)
            cmd.set('metal_exposure', 1.0)
            cmd.set('metal_light_hdr', 0)
            self.rig(shadow=True)
            want = self.frame()
            for exp, mode in ((0.5, 0), (2.0, 2), (1.0, 7)):
                cmd.set('metal_exposure', exp)
                cmd.set('metal_light_hdr', mode)
                got = self.frame()
                self.assertEqual(got['rig']['block'][:TONE_AT],
                                 want['rig']['block'][:TONE_AT])
                for key in set(want) - {'rig'}:
                    self.assertEqual(got[key], want[key], key)
                for key in set(want['rig']) - {'block', 'tone'}:
                    self.assertEqual(got['rig'][key], want['rig'][key], key)

    def testNothingWithoutARigThatIsOn(self):
        for enabled in (None, False):
            if enabled is None:
                cmd.set_lights(None)
            else:
                self.rig(enabled=False)
            cmd.set('metal_exposure', 1.0)
            cmd.set('metal_light_hdr', 0)
            want = self.frame()
            self.assertIsNone(want['rig'])
            for exp, mode in ((0.37, 7), (2.0, 1), (0.5, 2), (1.0, -3)):
                cmd.set('metal_exposure', exp)
                cmd.set('metal_light_hdr', mode)
                self.assertEqual(self.frame(), want, (enabled, exp, mode))
                self.assertEqual(light_hdr(),
                                 {'rig': False, 'hdr': False, 'exposure': 1.0})

    def testGetLightHdr(self):
        cmd.set_lights(None)
        self.assertEqual(light_hdr(), {'rig': False, 'hdr': False, 'exposure': 1.0})
        self.rig(enabled=False)
        cmd.set('metal_exposure', 0.5)
        self.assertEqual(light_hdr(), {'rig': False, 'hdr': False, 'exposure': 1.0})
        self.rig()
        for mode, on in ((0, True), (1, True), (2, False), (7, True)):
            cmd.set('metal_light_hdr', mode)
            self.assertEqual(light_hdr(), {'rig': True, 'hdr': on,
                                           'exposure': f32(0.5)}, mode)
        # the same frame get_light_frame reads (live camera)
        tone4 = lighting._light_frame()['rig']['tone']
        got = light_hdr()
        self.assertEqual([got['exposure'], 1.0 if got['hdr'] else 0.0], tone4[:2])


class TestSource(testing.PyMOLTestCase):

    PYTHON = re.compile(r'os_python\.h|Python\.h|\bPConv\w*|\bPyObject\b'
                        r'|\bPy_\w+|PyMOLGlobals|LightRigPy\.h|SettingGet')

    def read(self, rel):
        return strip_comments(read_source(self, rel))

    def testPureFiles(self):
        for name in ('LightTone.h', 'LightTone.cpp'):
            text = self.read(os.path.join('layer1', name))
            found = self.PYTHON.search(text)
            self.assertIsNone(found, '%s uses %r' % (name, found and found.group(0)))
            self.assertNotRegex(text, r'\bstatic\s+(?!inline)\w[^(;]*=')

    def testConstants(self):
        header = self.read(os.path.join('layer1', 'LightTone.h'))
        for name, value in (('kLightToneKnee', KNEE), ('kLightToneWhite', WHITE),
                            ('kLightToneMaxExposure', MAX_EXPOSURE),
                            ('kLightHdrOn', 1), ('kLightHdrOff', 2)):
            match = re.search(r'\b%s\s*=\s*([0-9.eE+-]+)f?\s*;' % name, header)
            self.assertIsNotNone(match, name)
            self.assertEqual(float(match.group(1)), value, name)

    def testBlock(self):
        text = self.read(os.path.join('layer1', 'LightRigBlock.h'))
        block = re.search(r'struct LightRigBlock\s*\{(.*?)\};', text, re.S).group(1)
        members = re.findall(r'(\w+)\s+(\w+)\[(\w+)\];', block)
        self.assertEqual(members[-2:], [('float', 'shadowTile', '4'),
                                        ('float', 'tone', '4')])
        self.assertRegex(text, r'sizeof\(LightRigBlock\)\s*==\s*688')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*tone\)\s*==\s*672')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*shadowTile\)\s*==\s*656')

    def testFrameFillsTheToneOnlyWithTheRig(self):
        scene = self.read(os.path.join('layer1', 'SceneLights.cpp'))
        body = function_body(scene, 'SceneLightsFrame')
        statements = re.findall(r'if\s*\(\s*frame\.rig\s*\)\s*'
                                r'SceneLightsToneFill\(G,\s*\*frame\.rig\);', body)
        self.assertEqual(len(statements), 1)
        self.assertEqual(body.count('SceneLightsToneFill'), 1)
        self.assertEqual(body.count('SceneGetLightRig('), 1)
        # right after the block is made, before #616's shadows and #618's air
        made = body.index('frame.rig = pymol::LightRigFrameBlock(')
        fill = body.index('SceneLightsToneFill')
        self.assertLess(made, fill)
        self.assertLess(fill, body.index('LightShadowPlan'))
        self.assertNotIn('metal_light_hdr', body)
        self.assertNotIn('metal_exposure', body)
        # the fill reads the two settings, each once, and nothing else
        fill = function_body(scene, 'SceneLightsToneFill')
        self.assertEqual(re.findall(r'cSetting_\w+', fill),
                         ['cSetting_metal_exposure', 'cSetting_metal_light_hdr'])
        self.assertIn('pymol::LightToneExposure(', fill)
        self.assertIn('kSceneLightsMobile', fill)
        self.assertEqual(scene.count('cSetting_metal_light_hdr'), 1)
        self.assertEqual(scene.count('SceneLightsToneFill('), 2)  # def, call

    def testCmdEntries(self):
        text = self.read(os.path.join('layer4', 'Cmd.cpp'))
        for name, fn in (('light_tone', 'CmdLightTone'),
                         ('light_tone_scalar', 'CmdLightToneScalar'),
                         ('light_tone_exposure', 'CmdLightToneExposure'),
                         ('light_hdr', 'CmdLightHdr'),
                         ('get_light_hdr', 'CmdGetLightHdr')):
            self.assertRegex(text, r'\{"%s",\s*%s,\s*METH_VARARGS\}' % (name, fn))
