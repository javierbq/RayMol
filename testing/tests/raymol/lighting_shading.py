"""What the renderer reads from the light rig each frame (#613).

The Metal renderer reads the lighting once per frame through SceneLightsFrame
(layer1/SceneLights.cpp): PyMOL's classic light terms after decision 15
(LightRigClassic) and the rig packed into the block the GPU reads (#613's
400 bytes, then #616's shadow maps, then #624's tone: 688 bytes in all)
(LightRigFrameBlock / LightRigPack, layer1/LightShading.cpp), each light's
colour tinted by its warmth (LightWarmthRGB). These tests reach that C++
through _cmd.get_light_frame and _cmd.light_warmth_rgb
(pymol.lighting._light_frame / _light_warmth). No CI job builds catch2 or has
a GPU, so this is how the C++ is tested (lighting checklist, "What CI must
cover").

Expected values never come from the code under test. They come from an
in-test port of the published kelvin fit (itself checked against the
Planckian locus), explicit matrices, the #611 resolver (_lights_eye, tested by
lighting_eye.py), cmd.get_setting_float, and float32 rounding through struct.

Covers: kelvin -> RGB (neutral, range, continuity, monotonic warmth,
clamping); the gate (nothing computed with no rig or a rig that is off, and
the settings returned bit for bit); the packed values under an explicit
matrix and the live camera; the block layout at its documented offsets;
decision 15; that nothing is ever written; and that the core files use no
Python.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_shading.py
"""
import math
import os
import re
import struct

from pymol import cmd, lighting, metal_pick, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))

# A repo checkout is decided by ONE file every checkout has. In a checkout,
# the sources these tests read are required: a renamed or removed file fails
# the test instead of skipping it (CI always runs from a checkout, and a skip
# there would hide exactly that).
SENTINEL = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')


def checkout_source(test, rel):
    """The path of `rel` in the checkout; skips outside one, fails when the
    checkout lacks the file."""
    if not os.path.isfile(os.path.join(ROOT, SENTINEL)):
        test.skipTest('not a repo checkout (no %s)' % SENTINEL)
    path = os.path.join(ROOT, rel)
    test.assertTrue(os.path.isfile(path), '%s is missing from the checkout' % rel)
    return path


IDENTITY = [1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0]

# eye-space values are floats (GPU inputs): independent maths compares with a
# float tolerance; values from the same resolver compare exactly
TOL = 2e-4

LIGHT_FLOATS = 16          # one light: 4 float4
HEAD_FLOATS = 4
# #613's block: the head and six lights, 400 bytes. #616 appends three shadow
# maps of 20 floats, the shadow grid and the per-draw tile (one float4 each).
# #624 appends the tone (exposure, 1 = HDR, 0, 0): [1, 1, 0, 0] while the rig
# is on with the settings at their defaults; lighting_hdr.py tests it.
PREFIX_FLOATS = HEAD_FLOATS + 6 * LIGHT_FLOATS
SHADOW_FLOATS = 20
TONE_AT = PREFIX_FLOATS + 3 * SHADOW_FLOATS + 4 + 4
BLOCK_FLOATS = TONE_AT + 4
DEFAULT_TONE = [1.0, 1.0, 0.0, 0.0]
assert PREFIX_FLOATS == 100 and TONE_AT == 168 and BLOCK_FLOATS == 172


def f32(x):
    """x rounded to float32, as the GPU block holds it."""
    return struct.unpack('f', struct.pack('f', x))[0]


# --- the kelvin fit, ported from its publication ------------------------------
# Krystek (1985): the Planckian locus in CIE 1960 (u, v), 1000-15000 K; then
# CIE 1931 xy, XYZ (Y = 1) and linear sRGB (D65). White-balanced so 6500 K is
# neutral, divided by the largest channel.

SRGB = ((3.2404542, -1.5371385, -0.4985314),
        (-0.9692660, 1.8760108, 0.0415560),
        (0.0556434, -0.2040259, 1.0572252))


def planck_xy(t):
    u = ((0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t)
         / (1.0 + 8.42420235e-4 * t + 7.08145163e-7 * t * t))
    v = ((0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t)
         / (1.0 - 2.89741816e-5 * t + 1.61456053e-7 * t * t))
    d = 2.0 * u - 8.0 * v + 4.0
    return 3.0 * u / d, 2.0 * v / d


def planck_rgb(t):
    x, y = planck_xy(t)
    xyz = (x / y, 1.0, (1.0 - x - y) / y)
    return [sum(m * c for m, c in zip(row, xyz)) for row in SRGB]


def warmth_port(kelvin):
    k = min(max(kelvin, 1500.0), 15000.0)
    c = [max(a / b, 0.0) for a, b in zip(planck_rgb(k), planck_rgb(6500.0))]
    top = max(c)
    return [v / top for v in c]


# The Planckian locus (CIE 1931 xy), from the CIE tables: the port must sit
# on it (Krystek's fit is good to about 3e-4 here).
LOCUS = {2000: (0.5267, 0.4133), 2856: (0.44757, 0.40745),
         4000: (0.3805, 0.3768), 5000: (0.3451, 0.3516),
         6500: (0.3135, 0.3236), 10000: (0.2807, 0.2884)}


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


def oracle(world):
    """A world point in the live camera's eye space (metal_pick.camera)."""
    cam = metal_pick.camera()
    d = sub(world, cam.origin)
    return [sum(cam.rot[3 * i + j] * d[j] for j in range(3)) + cam.pos[i]
            for i in range(3)]


MATRIX = mat_mul(translation([3.0, -4.0, -60.0]),
                 mat_mul(rot_x(30.0), rot_y(50.0)))
CENTRE = [1.0, 2.0, 3.0]
SIZE = 5.0
PINNED_AT = [10.0, -5.0, 8.0]
AIM_POINT = [4.0, 0.0, -2.0]

# Every field the block carries, away from its default.
LIGHTS = [
    {'name': 'key', 'orbit': -45.0, 'pitch': 35.0, 'radius': 3.0,
     'beam': 40.0, 'softness': 0.5, 'color': [1.0, 0.55, 0.2],
     'warmth': 3200.0, 'intensity': 1.6, 'highlight': 0.8, 'falloff': 2.0,
     'shadow': True, 'outline': True},
    {'name': 'pin', 'anchor': 'pinned', 'position': PINNED_AT, 'beam': 60.0,
     'softness': 0.0, 'color': [0.2, 0.8, 1.0], 'warmth': 12000.0,
     'intensity': 2.0, 'highlight': 1.0, 'falloff': 1.0},
    {'name': 'aimed', 'orbit': 120.0, 'pitch': -10.0, 'radius': 1.5,
     'aim': 'point', 'aim_point': AIM_POINT, 'warmth': 6500.0,
     'intensity': 0.7, 'highlight': 0.25, 'falloff': 0.0},
]


def light_slice(block, i):
    """Light i's 16 floats, at the offset LightRigBlock.h documents."""
    start = HEAD_FLOATS + LIGHT_FLOATS * i
    return block[start:start + LIGHT_FLOATS]


class LightingCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        # something to look at, away from the origin
        cmd.pseudoatom('pa', pos=[4.0, -2.0, 6.0])
        cmd.pseudoatom('pb', pos=[-6.0, 5.0, 1.0])

    def rig(self, lights=LIGHTS, enabled=True, **extra):
        rig = {'enabled': enabled, 'centre': list(CENTRE), 'size': SIZE,
               'lights': lights}
        rig.update(extra)
        cmd.set_lights(rig)

    def assertVec(self, got, want, tol=TOL, msg=None):
        self.assertEqual(len(got), len(want), msg)
        for g, w in zip(got, want):
            self.assertAlmostEqual(g, w, delta=tol * max(1.0, abs(w)),
                                   msg='%r != %r %s' % (got, want, msg or ''))

    def settings_terms(self):
        """The classic terms as the settings give them: ambient, direct and
        reflect read directly; specular and shininess through PyMOL's
        light-count adjustment (SceneGetAdjustedLightValues), written out
        here for light counts up to 2 (no pow). Settings are floats: the
        renderer gets them unrounded, get_setting_float rounds them for
        display, so f32 recovers the stored value."""
        def get(name):
            return f32(cmd.get_setting_float(name))
        spec = get('specular')
        if spec == 1.0:
            spec = get('specular_intensity')
        if spec < 1e-4:
            spec = 0.0
        power = get('spec_power')
        if power < 0.0:
            power = get('shininess')
        reflect_spec = get('spec_reflect')
        if reflect_spec < 0.0:
            reflect_spec = spec
        n = cmd.get_setting_int('spec_count')
        if n < 0:
            n = cmd.get_setting_int('light_count')
        self.assertLessEqual(n, 2, 'the oracle has no pow')
        return {'ambient': get('ambient'), 'direct': get('direct'),
                'reflect': get('reflect'),
                'specular': min(max(reflect_spec, 0.0), 1.0),
                'shininess': power}

    def assertTermsAreSettings(self, frame, msg=None):
        want = self.settings_terms()
        for key, value in want.items():
            self.assertEqual(frame[key], value, '%s %s' % (key, msg or ''))


class TestWarmth(LightingCase):

    def testNeutralIsExactlyWhite(self):
        self.assertEqual(lighting._light_warmth(6500), (1.0, 1.0, 1.0))
        self.assertEqual(lighting._light_warmth(6500.0), (1.0, 1.0, 1.0))

    def testPortSitsOnThePlanckianLocus(self):
        """The in-test port is the published fit: it reproduces the CIE
        locus (Illuminant A is 2856 K)."""
        for kelvin, (x, y) in sorted(LOCUS.items()):
            px, py = planck_xy(float(kelvin))
            self.assertAlmostEqual(px, x, delta=1e-3, msg=kelvin)
            self.assertAlmostEqual(py, y, delta=1e-3, msg=kelvin)

    def testMatchesThePort(self):
        for kelvin in range(1500, 15001, 50):
            self.assertVec(lighting._light_warmth(kelvin),
                           warmth_port(float(kelvin)), tol=1e-9,
                           msg='%d K' % kelvin)

    def testTintsAndNeverBrightens(self):
        """The largest channel is exactly 1; red leads below 6500 K and blue
        above."""
        for kelvin in range(1500, 15001, 50):
            r, g, b = lighting._light_warmth(kelvin)
            label = '%d K: %r' % (kelvin, (r, g, b))
            self.assertEqual(max(r, g, b), 1.0, label)
            self.assertGreaterEqual(min(r, g, b), 0.0, label)
            if kelvin < 6500:
                self.assertEqual(r, 1.0, label)
                self.assertLess(b, 1.0, label)
            elif kelvin > 6500:
                self.assertEqual(b, 1.0, label)
                self.assertLess(r, 1.0, label)

    def testContinuous(self):
        """No seam anywhere: a warmth slider moves the colour smoothly. The
        prototype's piecewise fit jumped ~0.028 in green at 6600 K, right
        next to neutral."""
        def largest_step(kelvins):
            prev, worst = None, (0.0, None)
            for kelvin in kelvins:
                c = lighting._light_warmth(kelvin)
                if prev is not None:
                    step = max(abs(a - b) for a, b in zip(c, prev))
                    worst = max(worst, (step, kelvin))
                prev = c
            return worst

        step, where = largest_step(range(1500, 15001, 10))
        self.assertLess(step, 0.004, 'jump of %g at %s K' % (step, where))
        # 1 K apart: a jump stands out against the slope (<= 2.7e-4 per K)
        step, where = largest_step(range(1500, 15001))
        self.assertLess(step, 5e-4, 'jump of %g at %s K' % (step, where))
        # around neutral, where the largest channel changes from red to blue
        step, where = largest_step([6500.0 + 0.01 * i for i in range(-1000, 1001)])
        self.assertLess(step, 1e-5, 'jump of %g at %s K' % (step, where))

    def testWarmerIsRedderCoolerIsBluer(self):
        """b/r never falls as kelvin rises, and rises wherever there is any
        blue (below ~1900 K a black body has none in sRGB)."""
        prev = None
        for kelvin in range(1500, 15001, 10):
            r, g, b = lighting._light_warmth(kelvin)
            ratio = b / r
            if prev is not None:
                if b > 0.0:
                    self.assertGreater(ratio, prev, '%d K' % kelvin)
                else:
                    self.assertEqual(ratio, prev, '%d K' % kelvin)
            prev = ratio
        warm, cool = lighting._light_warmth(2500), lighting._light_warmth(12000)
        self.assertGreater(warm[0], warm[2])
        self.assertGreater(cool[2], cool[0])

    def testClamped(self):
        low, high = lighting._light_warmth(1500), lighting._light_warmth(15000)
        self.assertEqual(lighting._light_warmth(500), low)
        self.assertEqual(lighting._light_warmth(-1e9), low)
        self.assertEqual(lighting._light_warmth(float('-inf')), low)
        self.assertEqual(lighting._light_warmth(50000), high)
        self.assertEqual(lighting._light_warmth(float('inf')), high)
        self.assertEqual(lighting._light_warmth(float('nan')), (1.0, 1.0, 1.0))

    def testRangeIsTheField(self):
        """The fit's range is the warmth field's (spec §4.2), and its neutral
        the field's default."""
        fields = {(scope, name): (default, lo, hi)
                  for scope, name, _, default, lo, hi in lighting._light_fields()}
        self.assertEqual(fields[('light', 'warmth')], (6500.0, 1500.0, 15000.0))


class TestFrameGate(LightingCase):
    """With no rig, or a rig that is off, nothing is resolved or packed and
    the classic terms are the settings bit for bit."""

    def assertOff(self, msg):
        for matrix in (None, IDENTITY, column_major(MATRIX)):
            frame = lighting._light_frame(matrix)
            label = '%s (matrix %s)' % (msg, 'live' if matrix is None else 'given')
            self.assertIs(frame['rig_on'], False, label)
            self.assertIsNone(frame['rig'], label)
            self.assertTermsAreSettings(frame, label)
            # #615 adds 'classic_scale' (1 here; lighting_materials.py)
            self.assertEqual(sorted(frame), sorted(
                ['ambient', 'direct', 'reflect', 'specular', 'shininess',
                 'rig_on', 'rig', 'studio_shadows', 'shadow_map_size',
                 'shadows', 'classic_scale']), label)
            # #616: no rig, no studio shadows and nothing planned
            self.assertIs(frame['studio_shadows'], False, label)
            self.assertEqual(frame['shadow_map_size'], 0, label)
            self.assertIsNone(frame['shadows'], label)

    def testNoRig(self):
        self.assertIsNone(cmd.get_lights())
        self.assertOff('no rig')

    def testDisabledWithLights(self):
        self.rig(enabled=False)
        self.assertOff('enabled False with lights')

    def testEnabledWithNoLights(self):
        cmd.set_lights({'enabled': True})
        self.assertOff('enabled with no lights, no frame')
        self.rig(lights=[])
        self.assertOff('enabled with no lights, a frame')

    def testTurnedOff(self):
        self.rig()
        self.assertIs(lighting._light_frame()['rig_on'], True)
        lighting._light_set(-1, 'enabled', 0)
        self.assertOff('after enabled 0')

    def testRemoved(self):
        self.rig()
        cmd.set_lights(None)
        self.assertOff('after set_lights(None)')

    def testReinitialize(self):
        self.rig()
        cmd.reinitialize()
        self.assertOff('after reinitialize')

    def testNonDefaultSettings(self):
        """Every input of the classic terms is read, not assumed."""
        cmd.set('ambient', 0.3)
        cmd.set('direct', 0.6)
        cmd.set('reflect', 0.2)
        cmd.set('specular', 0.7)
        cmd.set('spec_power', 40.0)
        cmd.set('spec_count', 1)
        self.rig(enabled=False)
        self.assertOff('non-default settings')
        cmd.set('spec_power', -1.0)
        cmd.set('shininess', 21.0)
        cmd.set('spec_reflect', 0.35)
        self.assertOff('spec_reflect and shininess')


class TestFrameValues(LightingCase):

    def testExplicitMatrix(self):
        # metal_shadows off: the key's shadow: True plans no map (#616), so the
        # block is #613's (the shadowed case is checked at the end)
        cmd.set('metal_shadows', 0)
        self.rig()
        m = column_major(MATRIX)
        frame = lighting._light_frame(m)
        eye = lighting._lights_eye(m)
        rig = cmd.get_lights()
        self.assertIs(frame['rig_on'], True)
        packed = frame['rig']
        self.assertEqual(packed['count'], 3)
        self.assertEqual([l['name'] for l in packed['lights']],
                         ['key', 'pin', 'aimed'])
        self.assertEqual(packed['head'],
                         [3.0, frame['shininess'], 0.0, 0.0])

        c = apply(MATRIX, CENTRE)
        for i, (got, want, light) in enumerate(zip(packed['lights'],
                                                   eye['lights'], rig['lights'])):
            label = light['name']
            # the #611 resolver's values, unchanged (same matrix: exact)
            for key in ('position', 'direction', 'cos_outer', 'cos_inner'):
                self.assertEqual(got[key], want[key], '%s %s' % (label, key))
            self.assertEqual(got['falloff_ref'], want['aim_distance'], label)
            # independent: the cone from the beam
            half = math.radians(light['beam'] / 2.0)
            self.assertAlmostEqual(got['cos_outer'], math.cos(half), delta=1e-6)
            # radiance = color * warmth * intensity, in double, then float
            warm = lighting._light_warmth(light['warmth'])
            self.assertEqual(
                got['radiance'],
                [f32(col * w * light['intensity'])
                 for col, w in zip(light['color'], warm)], label)
            self.assertVec(got['radiance'],
                           [col * w * light['intensity'] for col, w in
                            zip(light['color'], warmth_port(light['warmth']))],
                           tol=1e-6, msg=label)
            self.assertEqual(got['highlight'], f32(light['highlight']), label)
            self.assertEqual(got['falloff'], f32(light['falloff']), label)
            self.assertIs(got['outline'], light['outline'], label)
            # no shadow slot at metal_shadows 0, even for the key's
            # shadow: True
            self.assertEqual(got['shadow_slot'], -1, label)

        key, pin, aimed = packed['lights']
        # independent placement maths (spec §4.3)
        self.assertVec(key['position'],
                       add(c, scale(orbit_dir(-45.0, 35.0), 3.0 * SIZE)))
        p = apply(MATRIX, PINNED_AT)
        self.assertVec(pin['position'], p)
        self.assertVec(pin['direction'], unit(sub(c, p)))
        self.assertAlmostEqual(pin['falloff_ref'], norm(sub(c, p)), delta=TOL)
        a = add(c, scale(orbit_dir(120.0, -10.0), 1.5 * SIZE))
        t = apply(MATRIX, AIM_POINT)
        self.assertVec(aimed['position'], a)
        self.assertVec(aimed['direction'], unit(sub(t, a)))
        # the key is warm (3200 K on orange), the pinned light cool
        self.assertGreater(key['radiance'][0], key['radiance'][2])
        self.assertGreater(pin['radiance'][2], pin['radiance'][0])
        # a white light at 6500 K: its intensity, exactly
        self.assertEqual(aimed['radiance'], [f32(0.7)] * 3)
        self.assertIs(frame['studio_shadows'], False)
        self.assertIsNone(frame['shadows'])
        self.assertEqual(packed['block'][PREFIX_FLOATS:TONE_AT],
                         [0.0] * (TONE_AT - PREFIX_FLOATS))
        self.assertEqual(packed['block'][TONE_AT:], DEFAULT_TONE)

        # metal_shadows on (#616): the key, the only shadowed light, gets
        # map slot 0 and head[3] counts one map; nothing else of #613's 400
        # bytes changes
        cmd.set('metal_shadows', 1)
        shadowed = lighting._light_frame(m)
        self.assertIs(shadowed['studio_shadows'], True)
        lit = shadowed['rig']
        self.assertEqual(lit['head'], [3.0, frame['shininess'], 0.0, 1.0])
        self.assertEqual([l['shadow_slot'] for l in lit['lights']], [0, -1, -1])
        want = list(packed['block'][:PREFIX_FLOATS])
        want[3] = 1.0                    # head.w: one map
        want[HEAD_FLOATS + 3] = 0.0      # the key's pos.w: slot 0
        self.assertEqual(lit['block'][:PREFIX_FLOATS], want)
        self.assertEqual(shadowed['shadows']['count'], 1)
        self.assertEqual(shadowed['shadows']['slots'][0]['name'], 'key')

    def testLiveCamera(self):
        cmd.turn('y', 50)
        cmd.turn('x', 30)
        cmd.move('z', -20)
        cmd.move('x', 3)
        self.rig()
        frame = lighting._light_frame()
        eye = lighting._lights_eye()
        for got, want in zip(frame['rig']['lights'], eye['lights']):
            for key in ('position', 'direction', 'cos_outer', 'cos_inner'):
                self.assertEqual(got[key], want[key], key)
        pin = frame['rig']['lights'][1]
        self.assertVec(pin['position'], oracle(PINNED_AT))
        self.assertVec(pin['direction'],
                       unit(sub(oracle(CENTRE), oracle(PINNED_AT))))

    def testSixLightsFillSixSlots(self):
        lights = [{'orbit': 60.0 * i - 150.0, 'intensity': 0.5 + 0.5 * i}
                  for i in range(6)]
        self.rig(lights=lights)
        packed = lighting._light_frame(column_major(MATRIX))['rig']
        self.assertEqual(packed['count'], 6)
        self.assertEqual(packed['head'][0], 6.0)
        self.assertEqual([l['name'] for l in packed['lights']],
                         ['key', 'fill', 'rim', 'light4', 'light5', 'light6'])
        for i, light in enumerate(packed['lights']):
            self.assertEqual(light['radiance'], [f32(0.5 + 0.5 * i)] * 3)
            self.assertNotEqual(light_slice(packed['block'], i), [0.0] * 16)

    def testUnusedSlotsAreZero(self):
        # metal_shadows off: no map is planned, so the shadow tail (#616) is
        # zero as well
        cmd.set('metal_shadows', 0)
        self.rig(lights=LIGHTS[:2])
        block = lighting._light_frame(column_major(MATRIX))['rig']['block']
        self.assertEqual(len(block), BLOCK_FLOATS)
        self.assertEqual(block[HEAD_FLOATS + 2 * LIGHT_FLOATS:TONE_AT],
                         [0.0] * (TONE_AT - HEAD_FLOATS - 2 * LIGHT_FLOATS))
        self.assertEqual(block[TONE_AT:], DEFAULT_TONE)
        # with a map planned, the unused light slots stay zero
        cmd.set('metal_shadows', 1)
        block = lighting._light_frame(column_major(MATRIX))['rig']['block']
        self.assertEqual(block[HEAD_FLOATS + 2 * LIGHT_FLOATS:PREFIX_FLOATS],
                         [0.0] * (4 * LIGHT_FLOATS))

    def testLightAimedAtItself(self):
        """A light aimed at its own position has no aim distance: falloff is
        measured from the rig centre instead (never 1e-3, which would make
        the light black), and from the rig size when it also sits on the
        centre."""
        self.rig(lights=[
            {'name': 'self', 'anchor': 'pinned', 'position': PINNED_AT,
             'aim': 'point', 'aim_point': PINNED_AT},
            {'name': 'centre', 'anchor': 'pinned', 'position': CENTRE},
        ])
        m = column_major(MATRIX)
        eye = lighting._lights_eye(m)
        own, on_centre = lighting._light_frame(m)['rig']['lights']
        self.assertEqual(eye['lights'][0]['aim_distance'], 0.0)
        self.assertAlmostEqual(
            own['falloff_ref'],
            norm(sub(eye['centre'], eye['lights'][0]['position'])), delta=1e-4)
        self.assertAlmostEqual(own['falloff_ref'],
                               norm(sub(CENTRE, PINNED_AT)), delta=TOL)
        self.assertEqual(eye['lights'][1]['aim_distance'], 0.0)
        self.assertEqual(on_centre['falloff_ref'], f32(SIZE))

    def testLiveEdits(self):
        """The frame follows the rig: no cached block."""
        self.rig()
        m = column_major(MATRIX)
        before = lighting._light_frame(m)['rig']['lights'][0]['radiance']
        lighting._light_set(0, 'intensity', 3.2)   # 2 x 1.6
        after = lighting._light_frame(m)['rig']['lights'][0]['radiance']
        self.assertEqual(after, [2.0 * v for v in before])
        lighting._light_set(0, 'color', [0.0, 0.0, 1.0])
        lighting._light_set(0, 'warmth', 6500.0)
        self.assertEqual(lighting._light_frame(m)['rig']['lights'][0]['radiance'],
                         [0.0, 0.0, f32(3.2)])
        lighting._light_set(0, 'outline', 0)
        self.assertIs(lighting._light_frame(m)['rig']['lights'][0]['outline'], False)
        lighting._light_set(0, 'beam', 90.0)
        self.assertAlmostEqual(
            lighting._light_frame(m)['rig']['lights'][0]['cos_outer'],
            math.cos(math.radians(45.0)), delta=1e-6)


class TestBlockLayout(LightingCase):
    """The block the GPU reads: 172 floats at the offsets LightRigBlock.h
    documents (and MSL LightRigU mirrors). Checked against independent
    values, not only against the decoded dict."""

    def testOffsets(self):
        cmd.set('metal_shadows', 0)    # no map planned (#616)
        self.rig()
        m = column_major(MATRIX)
        frame = lighting._light_frame(m)
        packed = frame['rig']
        block = packed['block']
        eye = lighting._lights_eye(m)
        rig = cmd.get_lights()
        self.assertEqual(len(block), BLOCK_FLOATS)
        self.assertEqual(block[:4], [3.0, frame['shininess'], 0.0, 0.0])
        self.assertEqual(packed['head'], block[:4])
        for i, (want, light) in enumerate(zip(eye['lights'], rig['lights'])):
            s = light_slice(block, i)
            label = light['name']
            self.assertEqual(s[0:3], want['position'], label)
            self.assertEqual(s[3], -1.0, label)                  # shadow slot
            self.assertEqual(s[4:7], want['direction'], label)
            self.assertEqual(s[7], want['cos_outer'], label)
            warm = lighting._light_warmth(light['warmth'])
            self.assertEqual(s[8:11], [f32(c * w * light['intensity'])
                                       for c, w in zip(light['color'], warm)])
            self.assertEqual(s[11], want['cos_inner'], label)
            self.assertEqual(s[12], f32(light['highlight']), label)
            self.assertEqual(s[13], f32(light['falloff']), label)
            self.assertEqual(s[14], want['aim_distance'], label)
            self.assertEqual(s[15], 1.0 if light['outline'] else 0.0, label)
        self.assertEqual(block[PREFIX_FLOATS:TONE_AT], [0.0] * (TONE_AT - PREFIX_FLOATS))
        self.assertEqual(block[TONE_AT:], DEFAULT_TONE)
        self.assertEqual(packed['tone'], block[TONE_AT:])

    def testShadowOffsets(self):
        """#616's tail at the documented offsets: map s at 100 + 20 s (16
        floats of matrix, then tan(half fov), map size, normal offset, depth
        bias), the grid at 160 and the per-draw tile (0 here) at 164; the
        slot in pos.w and the count in head.w."""
        cmd.set('metal_shadows', 1)
        self.rig()
        m = column_major(MATRIX)
        frame = lighting._light_frame(m)
        block = frame['rig']['block']
        self.assertEqual(len(block), BLOCK_FLOATS)
        self.assertEqual(block[3], 1.0)
        self.assertEqual(light_slice(block, 0)[3], 0.0)
        slot = frame['shadows']['slots'][0]
        s = block[PREFIX_FLOATS:PREFIX_FLOATS + SHADOW_FLOATS]
        self.assertEqual(s[0:16], slot['view_proj'])
        self.assertEqual(s[16:20], [slot['tan_half_fov'], slot['map_size'],
                                    slot['normal_offset'], slot['depth_bias']])
        self.assertEqual(s[17], float(frame['shadow_map_size']))
        # unused maps are zero; no grid: one tile, first slot 0, 1 x 1
        self.assertEqual(block[PREFIX_FLOATS + SHADOW_FLOATS:160],
                         [0.0] * (2 * SHADOW_FLOATS))
        self.assertEqual(block[160:164], [1.0, 0.0, 1.0, 1.0])
        self.assertEqual(frame['rig']['shadow_grid'], block[160:164])
        self.assertEqual(block[164:168], [0.0] * 4)
        self.assertEqual(frame['rig']['shadow_tile'], block[164:168])
        self.assertEqual(block[TONE_AT:], DEFAULT_TONE)   # #624, last

    def testDecodedFromTheBlock(self):
        self.rig()
        packed = lighting._light_frame(column_major(MATRIX))['rig']
        for i, light in enumerate(packed['lights']):
            s = light_slice(packed['block'], i)
            self.assertEqual(
                [light['position'], light['shadow_slot'], light['direction'],
                 light['cos_outer'], light['radiance'], light['cos_inner'],
                 light['highlight'], light['falloff'], light['falloff_ref'],
                 light['outline']],
                [s[0:3], int(s[3]), s[4:7], s[7], s[8:11], s[11], s[12],
                 s[13], s[14], s[15] >= 0.5])

    def testBlockSourceMatchesTheDocumentedLayout(self):
        """LightRigBlock.h: a float4 head and six lights of four float4,
        400 bytes (#613), then three shadow maps of a 4x4 and a float4, the
        shadow grid and the per-draw tile (#616), then the tone (#624): 688
        bytes, asserted at compile time."""
        path = checkout_source(self, os.path.join('layer1', 'LightRigBlock.h'))
        with open(path, encoding='utf-8') as handle:
            text = strip_comments(handle.read())
        light = re.search(r'struct LightRigBlockLight\s*\{(.*?)\};', text, re.S)
        block = re.search(r'struct LightRigBlock\s*\{(.*?)\};', text, re.S)
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', light.group(1)),
                         ['pos', 'axis', 'radiance', 'misc'])
        self.assertEqual(re.findall(r'float\s+(\w+)\[4\];', block.group(1)),
                         ['head', 'shadowGrid', 'shadowTile', 'tone'])
        self.assertRegex(block.group(1),
                         r'LightRigBlockLight\s+light\[kLightRigBlockSlots\];')
        # #613's fields first, in order; #616's appended after them
        members = re.findall(r'(\w+)\s+(\w+)\[(\w+)\];', block.group(1))
        self.assertEqual(members, [
            ('float', 'head', '4'),
            ('LightRigBlockLight', 'light', 'kLightRigBlockSlots'),
            ('LightRigBlockShadow', 'shadow', 'kLightRigBlockShadowSlots'),
            ('float', 'shadowGrid', '4'), ('float', 'shadowTile', '4'),
            ('float', 'tone', '4')])
        shadow = re.search(r'struct LightRigBlockShadow\s*\{(.*?)\};', text,
                           re.S)
        self.assertEqual(re.findall(r'float\s+(\w+)\[(\d+)\];', shadow.group(1)),
                         [('viewProj', '16'), ('info', '4')])
        self.assertRegex(text, r'kLightRigBlockSlots\s*=\s*6;')
        self.assertRegex(text, r'kLightRigBlockShadowSlots\s*=\s*3;')
        self.assertRegex(text, r'sizeof\(LightRigBlock\)\s*==\s*688')
        self.assertRegex(text, r'sizeof\(LightRigBlockLight\)\s*==\s*64')
        self.assertRegex(text, r'sizeof\(LightRigBlockShadow\)\s*==\s*80')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*shadow\)\s*==\s*400')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*shadowGrid\)\s*==\s*640')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*shadowTile\)\s*==\s*656')
        self.assertRegex(text, r'offsetof\(LightRigBlock,\s*tone\)\s*==\s*672')


class TestDecision15(LightingCase):
    """While the rig is on, the rig's ambient replaces the ambient setting
    and direct, reflect and specular are scaled by its classic (spec §2,
    decision 15). Shininess is never scaled."""

    def check(self, msg):
        cmd.set_lights(None)
        base = lighting._light_frame()
        self.assertTermsAreSettings(base, msg)
        for classic in (0.0, 0.5, 1.0):
            for ambient in (0.05, 0.33):
                self.rig(classic=classic, ambient=ambient)
                frame = lighting._light_frame()
                label = '%s classic %r ambient %r' % (msg, classic, ambient)
                self.assertIs(frame['rig_on'], True, label)
                self.assertEqual(frame['ambient'], f32(ambient), label)
                for key in ('direct', 'reflect', 'specular'):
                    self.assertEqual(frame[key],
                                     f32(f32(base[key]) * f32(classic)),
                                     '%s %s' % (label, key))
                self.assertEqual(frame['shininess'], base['shininess'], label)
                self.assertEqual(frame['rig']['head'][1], base['shininess'])
        # classic 0 turns PyMOL's lights off; 1 leaves them as they were
        self.rig(classic=0.0)
        frame = lighting._light_frame()
        self.assertEqual([frame[k] for k in ('direct', 'reflect', 'specular')],
                         [0.0, 0.0, 0.0])
        self.rig(classic=1.0)
        frame = lighting._light_frame()
        for key in ('direct', 'reflect', 'specular'):
            self.assertEqual(frame[key], base[key], key)

    def testDefaultSettings(self):
        self.check('defaults')

    def testNonDefaultSettings(self):
        cmd.set('ambient', 0.3)
        cmd.set('direct', 0.6)
        cmd.set('reflect', 0.2)
        cmd.set('specular', 0.7)
        cmd.set('spec_power', 40.0)
        cmd.set('spec_count', 1)
        self.check('non-default')

    def testDarkRigIsStillOn(self):
        """A rig whose lights are all at intensity 0 is on: the scene is lit
        by the rig's ambient alone (Q5)."""
        self.rig(lights=[dict(l, intensity=0.0) for l in LIGHTS])
        frame = lighting._light_frame()
        self.assertIs(frame['rig_on'], True)
        self.assertEqual(frame['ambient'], f32(0.05))
        self.assertEqual([frame[k] for k in ('direct', 'reflect', 'specular')],
                         [0.0, 0.0, 0.0])
        for light in frame['rig']['lights']:
            self.assertEqual(light['radiance'], [0.0, 0.0, 0.0])

    def testLiveRigEdits(self):
        self.rig()
        lighting._light_set(-1, 'classic', 0.5)
        lighting._light_set(-1, 'ambient', 0.2)
        frame = lighting._light_frame()
        cmd.set_lights(None)
        base = lighting._light_frame()
        self.assertEqual(frame['ambient'], f32(0.2))
        self.assertEqual(frame['direct'], f32(f32(base['direct']) * f32(0.5)))


def material_settings():
    import pymol.setting
    return [name for name in pymol.setting.get_name_list()
            if name.endswith('_material')]


class TestNothingWritten(LightingCase):

    def snapshot(self):
        session = cmd.get_session()
        colors = []
        cmd.iterate('all', 'colors.append(color)', space={'colors': colors})
        return {
            'settings': session['settings'],
            'unique_settings': session.get('unique_settings'),
            'colors': colors,
            'materials': [cmd.get(name) for name in material_settings()],
        }

    def testShadingWritesNothing(self):
        cmd.show('spheres')
        cmd.color('red', 'pa')
        cmd.set('sphere_color', 'blue', 'pb')
        # The first get_session() writes pse_binary_dump back (CmdGetSession):
        # take that one first.
        self.snapshot()
        before = self.snapshot()
        m = column_major(MATRIX)
        steps = [
            lambda: self.rig(),
            lambda: lighting._light_frame(),
            lambda: lighting._light_frame(m),
            lambda: lighting._light_warmth(2500),
            lambda: lighting._light_set(0, 'intensity', 3.0),
            lambda: lighting._light_set(-1, 'classic', 0.5),
            lambda: lighting._light_set(-1, 'ambient', 0.4),
            lambda: lighting._light_frame(),
            lambda: lighting._light_set(-1, 'enabled', 0),
            lambda: lighting._light_frame(),
            lambda: cmd.set_lights(None),
            lambda: lighting._light_frame(),
        ]
        for step in steps:
            step()
            self.assertEqual(self.snapshot(), before)

    def testOffGivesBackTheExactTerms(self):
        no_rig = lighting._light_frame()
        self.rig(classic=0.25, ambient=0.5)
        self.assertNotEqual(lighting._light_frame(), no_rig)
        lighting._light_set(-1, 'enabled', 0)
        self.assertEqual(lighting._light_frame(), no_rig)
        lighting._light_set(-1, 'enabled', 1)
        cmd.set_lights(None)
        self.assertEqual(lighting._light_frame(), no_rig)


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def function_body(text, name):
    """The body of the function `name` defined in `text` (comments
    stripped), braces balanced."""
    match = re.search(r'\b%s\s*\([^;{]*\)\s*\{' % name, text)
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


class TestNoPython(testing.PyMOLTestCase):
    """The shading maths takes no PyMOLGlobals and no Python, so the
    renderer (and a future catch2 job) can call it directly, off the main
    thread during movie export."""

    PURE = [os.path.join('layer1', name) for name in
            ('LightRigBlock.h', 'LightShading.h', 'LightShading.cpp')]
    PYTHON = re.compile(r'os_python\.h|Python\.h|\bPConv\w*|\bPyObject\b'
                        r'|\bPy_\w+|PyMOLGlobals|LightRigPy\.h')

    def read(self, rel):
        path = checkout_source(self, rel)
        with open(path, encoding='utf-8') as handle:
            return strip_comments(handle.read())

    def testPureFilesUseNoPython(self):
        for rel in self.PURE:
            found = self.PYTHON.search(self.read(rel))
            self.assertIsNone(found, '%s uses %r' % (rel, found and found.group(0)))

    def testBlockHeaderIncludesOnlyTheStandardLibrary(self):
        text = self.read(os.path.join('layer1', 'LightRigBlock.h'))
        self.assertEqual(re.findall(r'#include\s+"', text), [])

    def testOffIsDecidedBeforeAnything(self):
        text = self.read(os.path.join('layer1', 'LightShading.cpp'))
        body = function_body(text, 'LightRigFrameBlock')
        self.assertLess(body.index('LightRigIsOn'), body.index('LightRigResolve'))
        self.assertRegex(body, r'^\s*if\s*\(\s*!LightRigIsOn\(rig\)\s*\)\s*'
                               r'return\s+std::nullopt;')
        body = function_body(text, 'LightRigClassic')
        self.assertRegex(body, r'^\s*if\s*\(\s*!LightRigIsOn\(rig\)\s*\)\s*'
                               r'return\s+settings;')

    def testSceneReadsTheRigOnce(self):
        text = self.read(os.path.join('layer1', 'SceneLights.cpp'))
        body = function_body(text, 'SceneLightsFrame')
        self.assertEqual(len(re.findall(r'\bSceneGetLightRig\s*\(', body)), 1)
        self.assertEqual(len(re.findall(r'\bLightRigFrameBlock\s*\(', body)), 1)
        self.assertEqual(len(re.findall(r'\bLightRigClassic\s*\(', body)), 1)
        self.assertNotRegex(body, r'\bLightRigResolve\s*\(|\bSceneLightsResolve\s*\(')
