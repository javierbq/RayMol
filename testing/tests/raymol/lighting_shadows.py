"""Per-light shadow maps (#616): the plan the renderer reads each frame.

SceneLightsFrame (layer1/SceneLights.cpp) plans the studio shadow maps once
per frame: which lights get a map (LightShadowPlan), each map's perspective
frustum (LightShadowFrustum, layer1/LightShadows.cpp), the map size
(LightShadowMapSize, setting metal_light_shadow_size), the grid tiles
(LightShadowTileRect) and the casters (overlays never cast, #433). The plan
is written into the tail of the packed block (layer1/LightRigBlock.h). The
GPU frame-time statistics, windows and log lines behind metal_gpu_timing
live in layer0/GpuFrameTimes.cpp. These tests reach that C++ through _cmd
(pymol.lighting._light_frame, _light_shadow_frustum, _light_shadow_map_size,
_light_shadow_tile, _light_shadow_casters, _gpu_time_summary,
_gpu_time_replay, _gpu_frame_stats). No CI job builds catch2 or has a GPU, so this is how the
C++ is tested (lighting checklist, "What CI must cover").

Expected values never come from the code under test: they come from
explicit matrices, independent cone and sphere maths written here, the #611
resolver (_lights_eye, tested by lighting_eye.py), cmd.get_extent and
cmd.get_setting_*, and float32 rounding through struct.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_shadows.py
"""
import math
import os
import random
import re
import struct

from pymol import cgo, cmd, lighting, testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SENTINEL = os.path.join('layerGraphics', 'metal', 'RendererMetal.mm')

PREFIX_FLOATS = 100        # #613's head and six lights
SHADOW_AT = 100            # map s at 100 + 20 s
SHADOW_FLOATS = 20
GRID_AT = 160
TILE_AT = 164
# #624 appends the tone (exposure, 1 = HDR, 0, 0) after the tile; with the
# settings at their defaults it is [1, 1, 0, 0] while the rig is on.
TONE_AT = 168
BLOCK_FLOATS = 172
DEFAULT_TONE = [1.0, 1.0, 0.0, 0.0]

# LightShadows.h, written out (the plan's D4, D13): the tests derive every
# expected value from these and their own maths.
DESKTOP, MOBILE = 2048, 1024
CASTER_MARGIN, CASTER_PAD = 1.02, 3.0
FOV_MARGIN, PAD_DEG, MAX_HALF_DEG = 1.05, 0.5, 75.0
NORMAL_OFFSET_TEXELS, DEPTH_BIAS = 1.5, 2e-4


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def checkout_source(test, rel):
    """The path of `rel` in the checkout; skips outside one, fails when the
    checkout lacks the file."""
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


# --- small vector and matrix helpers (row-major nested lists; no numpy) ------

def mat_mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)]
            for i in range(4)]


def translation(t):
    return [[1.0, 0.0, 0.0, t[0]], [0.0, 1.0, 0.0, t[1]],
            [0.0, 0.0, 1.0, t[2]], [0.0, 0.0, 0.0, 1.0]]


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


def from_column_major(v):
    return [[v[c * 4 + r] for c in range(4)] for r in range(4)]


def apply(m, p):
    return [sum(m[i][j] * p[j] for j in range(3)) + m[i][3] for i in range(3)]


def clip(vp, p):
    """vp: 16 floats column-major; p: a point. Homogeneous clip coords."""
    return [sum(vp[c * 4 + r] * (p[c] if c < 3 else 1.0) for c in range(4))
            for r in range(4)]


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


def add(a, b):
    return [x + y for x, y in zip(a, b)]


def scale(a, s):
    return [x * s for x in a]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def norm(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = norm(a)
    return [x / n for x in a]


def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def det3(m):
    return dot(m[0][:3], cross(m[1][:3], m[2][:3]))


def half_angle(beam_deg):
    """The beam candidate's half angle (deg), before the cap."""
    return beam_deg / 2.0 * FOV_MARGIN + PAD_DEG


def sphere_half(radius, dist):
    return math.degrees(math.asin(radius / dist)) * FOV_MARGIN + PAD_DEG


# A camera whose view is not the identity: rotated and pulled back.
MATRIX = mat_mul(translation([2.0, -3.0, -90.0]),
                 mat_mul(rot_x(25.0), rot_y(-40.0)))
M = column_major(MATRIX)

LIGHT = {'beam': 60.0, 'softness': 0.3, 'radius': 3.0, 'intensity': 1.0}


def light(name, **kw):
    out = dict(LIGHT, name=name)
    out.update(kw)
    return out


class ShadowCase(testing.PyMOLTestCase):

    def load_m(self):
        cmd.load(self.datafile('1rx1.pdb'), 'm')
        lo, hi = cmd.get_extent('m and not solvent')
        self.lo, self.hi = lo, hi
        self.centre = scale(add(lo, hi), 0.5)
        self.size = 0.5 * norm(sub(hi, lo))

    def rig(self, lights, centre=None, size=None, enabled=True):
        cmd.set_lights({'enabled': enabled,
                        'centre': list(centre if centre is not None else self.centre),
                        'size': float(size if size is not None else self.size),
                        'lights': lights})

    def casters_sphere(self, matrix=MATRIX, lo=None, hi=None):
        """The caster sphere in eye space, from cmd.get_extent and the
        plan's margins (written out here)."""
        lo = self.lo if lo is None else lo
        hi = self.hi if hi is None else hi
        centre = apply(matrix, scale(add(lo, hi), 0.5))
        radius = 0.5 * norm(sub(hi, lo)) * CASTER_MARGIN + CASTER_PAD
        return centre, radius

    def assertVec(self, got, want, tol, msg=None):
        self.assertEqual(len(got), len(want), msg)
        for g, w in zip(got, want):
            self.assertAlmostEqual(g, w, delta=tol * max(1.0, abs(w)),
                                   msg='%r != %r %s' % (got, want, msg or ''))

    def unshadowed_block(self, lights, matrix=M):
        """The same rig with every `shadow` false: #613's block."""
        self.rig([dict(l, shadow=False) for l in lights])
        block = lighting._light_frame(matrix)['rig']['block']
        self.rig(lights)
        return block


class TestGate(ShadowCase):
    """No plan, and the 172-float block equal to the same rig's with no
    shadowed light (pos.w -1, head.w 0, tail zero), unless the rig is on,
    metal_shadows is on, a light has `shadow` and there are casters."""

    LIGHTS = [light('key', orbit=-40.0, pitch=30.0, shadow=True),
              light('fill', orbit=50.0, pitch=10.0)]

    def assertNoPlan(self, frame, studio, msg):
        self.assertIs(frame['studio_shadows'], studio, msg)
        self.assertIsNone(frame['shadows'], msg)
        self.assertEqual(frame['shadow_map_size'], DESKTOP if studio else 0, msg)

    def assertBlockUnshadowed(self, frame, msg):
        block = frame['rig']['block']
        self.assertEqual(len(block), BLOCK_FLOATS, msg)
        self.assertEqual(block[3], 0.0, msg)
        for i in range(int(block[0])):
            self.assertEqual(block[4 + 16 * i + 3], -1.0, msg)
        # #616's tail zero; #624's tone (checked on its own) after it
        self.assertEqual(block[PREFIX_FLOATS:TONE_AT], [0.0] * (TONE_AT - PREFIX_FLOATS),
                         msg)
        self.assertEqual(block[TONE_AT:], DEFAULT_TONE, msg)

    def testNoRig(self):
        self.load_m()
        frame = lighting._light_frame(M)
        self.assertIsNone(frame['rig'])
        self.assertNoPlan(frame, False, 'no rig')

    def testRigOff(self):
        self.load_m()
        self.rig(self.LIGHTS, enabled=False)
        frame = lighting._light_frame(M)
        self.assertIsNone(frame['rig'])
        self.assertNoPlan(frame, False, 'rig off')

    def testNoShadowedLight(self):
        self.load_m()
        lights = [dict(l, shadow=False) for l in self.LIGHTS]
        self.rig(lights)
        frame = lighting._light_frame(M)
        self.assertNoPlan(frame, False, 'no shadowed light')
        self.assertBlockUnshadowed(frame, 'no shadowed light')

    def testMetalShadowsOff(self):
        self.load_m()
        want = self.unshadowed_block(self.LIGHTS)
        cmd.set('metal_shadows', 0)
        frame = lighting._light_frame(M)
        self.assertNoPlan(frame, False, 'metal_shadows 0')
        self.assertEqual(frame['rig']['block'], want)
        self.assertBlockUnshadowed(frame, 'metal_shadows 0')
        # the size setting is not read either: it never reaches the frame
        cmd.set('metal_light_shadow_size', 512)
        self.assertEqual(lighting._light_frame(M)['shadow_map_size'], 0)

    def testEmptyScene(self):
        # studio shadows are on (the whole-pixel shadow is off) but nothing
        # casts: no maps
        self.rig(self.LIGHTS, centre=[0.0, 0.0, 0.0], size=10.0)
        frame = lighting._light_frame(M)
        self.assertNoPlan(frame, True, 'empty scene')
        self.assertBlockUnshadowed(frame, 'empty scene')

    def testOnlyOverlays(self):
        cmd.load_cgo([cgo.SPHERE, 1.0, 2.0, 3.0, 4.0], '_move_gizmo', zoom=0)
        cmd.pseudoatom('anchor', pos=[0.0, 0.0, 0.0])
        cmd.ramp_new('rmp', 'anchor', [0.0, 10.0], ['red', 'blue'])
        cmd.disable('anchor')
        self.rig(self.LIGHTS, centre=[0.0, 0.0, 0.0], size=10.0)
        casters = lighting._light_shadow_casters()
        self.assertEqual(casters['casters'], [])
        self.assertIsNone(casters['extent'])
        frame = lighting._light_frame(M)
        self.assertNoPlan(frame, True, 'only overlays')
        self.assertBlockUnshadowed(frame, 'only overlays')

    def testReinitialize(self):
        self.load_m()
        self.rig(self.LIGHTS)
        self.assertIsNotNone(lighting._light_frame(M)['shadows'])
        cmd.reinitialize()
        frame = lighting._light_frame(M)
        self.assertIsNone(frame['rig'])
        self.assertNoPlan(frame, False, 'after reinitialize')


class TestSlots(ShadowCase):

    def setUp(self):
        super().setUp()
        self.load_m()

    def six(self, shadowed, extra=None):
        extra = extra or {}
        lights = []
        for i in range(6):
            l = light('l%d' % i, orbit=60.0 * i - 150.0, pitch=15.0 * (i % 3),
                      shadow=i in shadowed)
            l.update(extra.get(i, {}))
            lights.append(l)
        return lights

    def testSlotsInRigOrder(self):
        for shadowed in ([2], [0, 5], [1, 3, 4], [0, 1, 2]):
            lights = self.six(shadowed)
            self.rig(lights)
            frame = lighting._light_frame(M)
            packed = frame['rig']
            label = 'shadowed %r' % shadowed
            want = [shadowed.index(i) if i in shadowed else -1 for i in range(6)]
            self.assertEqual([l['shadow_slot'] for l in packed['lights']], want,
                             label)
            self.assertEqual(packed['head'][3], float(len(shadowed)), label)
            plan = frame['shadows']
            self.assertEqual(plan['count'], len(shadowed), label)
            self.assertEqual([s['light'] for s in plan['slots']], shadowed, label)
            self.assertEqual([s['slot'] for s in plan['slots']],
                             list(range(len(shadowed))), label)
            self.assertEqual([s['name'] for s in plan['slots']],
                             ['l%d' % i for i in shadowed], label)
            # unused maps stay zero
            used = SHADOW_AT + SHADOW_FLOATS * len(shadowed)
            self.assertEqual(packed['block'][used:GRID_AT],
                             [0.0] * (GRID_AT - used), label)
            # nothing else of #613's 400 bytes moved
            base = self.unshadowed_block(lights)
            got = list(packed['block'][:PREFIX_FLOATS])
            got[3] = 0.0
            for i in shadowed:
                got[4 + 16 * i + 3] = -1.0
            self.assertEqual(got, base[:PREFIX_FLOATS], label)

    def testDarkLightKeepsItsSlot(self):
        lights = self.six([1, 4], {1: {'intensity': 0.0}})
        self.rig(lights)
        packed = lighting._light_frame(M)['rig']
        self.assertEqual(packed['lights'][1]['radiance'], [0.0, 0.0, 0.0])
        self.assertEqual(packed['lights'][1]['shadow_slot'], 0)
        self.assertEqual(packed['lights'][4]['shadow_slot'], 1)

    def testLiveEdit(self):
        self.rig(self.six([]))
        self.assertIsNone(lighting._light_frame(M)['shadows'])
        lighting._light_set(3, 'shadow', 1)
        frame = lighting._light_frame(M)
        self.assertEqual(frame['rig']['lights'][3]['shadow_slot'], 0)
        self.assertEqual(frame['shadows']['slots'][0]['name'], 'l3')
        lighting._light_set(3, 'shadow', 0)
        self.assertIsNone(lighting._light_frame(M)['shadows'])

    def testInfoAndMatrices(self):
        cmd.set('metal_shadow_bias', 1.7)
        lights = self.six([0, 2])
        self.rig(lights)
        frame = lighting._light_frame(M)
        centre, radius = self.casters_sphere()
        bias = f32(cmd.get_setting_float('metal_shadow_bias'))
        for slot in frame['shadows']['slots']:
            label = slot['name']
            s = frame['rig']['block'][SHADOW_AT + SHADOW_FLOATS * slot['slot']:]
            info = s[16:20]
            self.assertEqual(info[1], float(DESKTOP), label)
            self.assertEqual(info[2], f32(NORMAL_OFFSET_TEXELS * bias), label)
            self.assertEqual(info[3], f32(DEPTH_BIAS), label)
            self.assertEqual(info[0], slot['tan_half_fov'], label)
            # view_proj = proj x view
            vp = mat_mul(from_column_major(slot['proj']),
                         from_column_major(slot['view']))
            self.assertVec(slot['view_proj'], column_major(vp), 1e-5, label)
            # the frustum of this light for the caster sphere written out
            # here (box from cmd.get_extent, margins of the plan)
            l = frame['rig']['lights'][slot['light']]
            want = lighting._light_shadow_frustum(
                l['position'], l['direction'], l['cos_outer'], centre, radius)
            self.assertAlmostEqual(slot['tan_half_fov'], want['tan_half_fov'],
                                   delta=1e-5, msg=label)
            self.assertAlmostEqual(slot['near'], want['near'],
                                   delta=1e-3 * want['near'], msg=label)
            self.assertAlmostEqual(slot['far'], want['far'],
                                   delta=1e-3 * want['far'], msg=label)
            self.assertIs(slot['beam_fit'], want['beam_fit'], label)
            self.assertVec(slot['view_proj'], want['view_proj'], 1e-3, label)


class TestFrustumCovers(ShadowCase):
    """Every caster atom inside a shadowed light's beam projects inside its
    map: |x|, |y| <= 1 and window depth in (0, 1)."""

    def setUp(self):
        super().setUp()
        self.load_m()
        self.atoms = []
        cmd.iterate_state(1, 'enabled and not solvent',
                          'atoms.append((x, y, z))', space={'atoms': self.atoms})
        self.assertGreater(len(self.atoms), 500)

    def check(self, lights, label):
        self.rig(lights)
        frame = lighting._light_frame(M)
        plan = frame['shadows']
        self.assertIsNotNone(plan, label)
        self.assertEqual(plan['count'], sum(1 for l in lights if l.get('shadow')))
        eye = [apply(MATRIX, a) for a in self.atoms]
        for slot in plan['slots']:
            l = frame['rig']['lights'][slot['light']]
            name = '%s/%s' % (label, slot['name'])
            p, d, cos_outer = l['position'], l['direction'], l['cos_outer']
            tested = 0
            for a in eye:
                v = sub(a, p)
                dist = norm(v)
                if dist < 1e-6 or dot(v, d) / dist < cos_outer:
                    continue          # outside the beam: not lit, no shadow
                view = apply(from_column_major(slot['view']), a)
                if -view[2] < slot['near']:
                    continue          # nearer than the near plane (documented)
                c = clip(slot['view_proj'], a)
                self.assertGreater(c[3], 0.0, name)
                x, y, z = c[0] / c[3], c[1] / c[3], c[2] / c[3]
                self.assertLessEqual(abs(x), 1.0 + 1e-5, name)
                self.assertLessEqual(abs(y), 1.0 + 1e-5, name)
                depth = 0.5 + 0.5 * z
                self.assertGreater(depth, 0.0, name)
                self.assertLess(depth, 1.0, name)
                tested += 1
            self.assertGreater(tested, 50, name)

    def testCameraLights(self):
        self.check([light('far', orbit=-50.0, pitch=25.0, shadow=True),
                    light('near', orbit=40.0, pitch=-15.0, radius=0.75,
                          beam=90.0, shadow=True)], 'camera')

    def testPinnedLight(self):
        pos = add(self.centre, [30.0, 22.0, -18.0])
        self.check([light('pin', anchor='pinned', position=pos, shadow=True)],
                   'pinned')

    def testAimedOffCentre(self):
        aim = add(self.centre, [9.0, -7.0, 5.0])
        self.check([light('aimed', orbit=30.0, pitch=20.0, radius=2.0,
                          beam=34.0, aim='point', aim_point=aim, shadow=True)],
                   'aimed')

    def testNarrowAndWideBeams(self):
        self.check([light('narrow', orbit=-20.0, pitch=10.0, beam=12.0,
                          shadow=True),
                    light('wide', orbit=70.0, pitch=40.0, beam=120.0,
                          shadow=True)], 'beams')
        slots = lighting._light_frame(M)['shadows']['slots']
        self.assertIs(slots[0]['beam_fit'], True)    # narrow beam: the beam
        self.assertIs(slots[1]['beam_fit'], False)   # wide beam: the casters


class TestFrustumFit(ShadowCase):
    """LightShadowFrustum against the plan's maths, written out here."""

    def frustum(self, pos, axis, beam, centre, radius):
        return lighting._light_shadow_frustum(
            pos, axis, math.cos(math.radians(beam / 2.0)), centre, radius)

    def assertRigid(self, view):
        m = from_column_major(view)
        rows = [r[:3] for r in m[:3]]
        for i in range(3):
            for j in range(3):
                self.assertAlmostEqual(dot(rows[i], rows[j]),
                                       1.0 if i == j else 0.0, delta=1e-5)
        self.assertAlmostEqual(det3(m), 1.0, delta=1e-5)
        self.assertEqual(m[3], [0.0, 0.0, 0.0, 1.0])

    def testNarrowBeamFarAwayFitsTheBeam(self):
        f = self.frustum([0.0, 0.0, 100.0], [0.0, 0.0, -1.0], 6.0,
                         [0.0, 0.0, 0.0], 10.0)
        self.assertIs(f['beam_fit'], True)
        self.assertAlmostEqual(f['tan_half_fov'],
                               math.tan(math.radians(half_angle(6.0))), delta=1e-6)
        self.assertAlmostEqual(f['far'], (100.0 + 10.0) * 1.02, delta=1e-3)
        self.assertRigid(f['view'])

    def testWideBeamFarAwayFitsTheCasters(self):
        f = self.frustum([0.0, 0.0, 100.0], [0.0, 0.0, -1.0], 60.0,
                         [0.0, 0.0, 0.0], 10.0)
        self.assertIs(f['beam_fit'], False)
        self.assertAlmostEqual(f['tan_half_fov'],
                               math.tan(math.radians(sphere_half(10.0, 100.0))),
                               delta=1e-6)
        self.assertRigid(f['view'])

    def testCappedBeamNeverBeatsTheSphere(self):
        """A beam over the cap is compared uncapped: the sphere wins."""
        f = self.frustum([0.0, 0.0, 12.0], [0.0, 0.0, -1.0], 170.0,
                         [0.0, 0.0, 0.0], 10.0)
        want = sphere_half(10.0, 12.0)
        self.assertLess(want, half_angle(170.0))
        self.assertIs(f['beam_fit'], False)
        self.assertAlmostEqual(f['tan_half_fov'],
                               math.tan(math.radians(min(want, MAX_HALF_DEG))),
                               delta=1e-5)

    def testInsideTheSphere(self):
        f = self.frustum([0.0, 0.0, 5.0], [0.0, 0.0, -1.0], 170.0,
                         [0.0, 0.0, 0.0], 10.0)
        self.assertIs(f['beam_fit'], True)
        self.assertAlmostEqual(f['tan_half_fov'],
                               math.tan(math.radians(MAX_HALF_DEG)), delta=1e-5)
        self.assertGreaterEqual(f['near'], f32(0.05))
        self.assertAlmostEqual(f['near'], 0.01 * 10.0, delta=1e-6)
        self.assertAlmostEqual(f['far'], (5.0 + 10.0) * 1.02, delta=1e-4)
        self.assertRigid(f['view'])

    def testAimedAxisNearPlaneIsConservative(self):
        """dist = 3R, the beam axis 15 deg off the casters' centre, beam 34
        deg: the near plane lies below the least axial depth of (sphere ∩
        beam cone), and every point of it lies inside the clip volume.
        (dist - R would not: the sphere's nearest point along the centre
        direction sits at axial depth 2R cos 15 < 2R.)"""
        R, dist, theta, beam = 10.0, 30.0, 15.0, 34.0
        P = [0.0, 0.0, dist]
        C = [0.0, 0.0, 0.0]
        t = math.radians(theta)
        A = [math.sin(t), 0.0, -math.cos(t)]
        f = self.frustum(P, A, beam, C, R)
        self.assertIsNotNone(f)
        self.assertIs(f['beam_fit'], True)
        cos_beam = math.cos(math.radians(beam / 2.0))
        rng = random.Random(616)
        points = []
        # the sphere's nearest points to the light, along cone directions
        to_c = unit(sub(C, P))
        for k in range(60):
            phi = rng.uniform(0.0, 2.0 * math.pi)
            ang = rng.uniform(0.0, math.radians(beam / 2.0))
            # a direction in the beam cone around A
            ortho1 = unit(cross(A, [0.0, 1.0, 0.0]))
            ortho2 = cross(A, ortho1)
            u = add(scale(A, math.cos(ang)),
                    add(scale(ortho1, math.sin(ang) * math.cos(phi)),
                        scale(ortho2, math.sin(ang) * math.sin(phi))))
            b = dot(u, sub(C, P))
            disc = b * b - (dot(sub(C, P), sub(C, P)) - R * R)
            if disc >= 0.0:
                points.append(add(P, scale(u, b - math.sqrt(disc))))
        nearest = add(P, scale(to_c, dist - R))
        self.assertGreaterEqual(dot(unit(sub(nearest, P)), A), cos_beam)
        points.append(nearest)
        # random points of the ball inside the cone
        while len(points) < 400:
            q = [rng.uniform(-R, R) for _ in range(3)]
            if norm(q) > R:
                continue
            q = add(C, q)
            v = sub(q, P)
            if dot(unit(v), A) >= cos_beam:
                points.append(q)
        view = from_column_major(f['view'])
        depths = []
        for q in points:
            depth = -apply(view, q)[2]
            depths.append(depth)
            c = clip(f['view_proj'], q)
            self.assertGreater(c[3], 0.0)
            for k in range(3):
                self.assertLessEqual(abs(c[k] / c[3]), 1.0 + 1e-5)
        self.assertLess(f['near'], min(depths))
        self.assertLess(min(depths), dist - R)   # the flaw this guards against
        self.assertGreater(f['far'], max(depths))

    def testCastersBehindTheLight(self):
        f = self.frustum([0.0, 0.0, 30.0], [0.0, 0.0, 1.0], 30.0,
                         [0.0, 0.0, 0.0], 10.0)
        self.assertIsNone(f)

    def testUpAxisNearVertical(self):
        f = self.frustum([0.0, 100.0, 0.0], [0.0, -1.0, 0.0], 10.0,
                         [0.0, 0.0, 0.0], 10.0)
        self.assertRigid(f['view'])
        # the light looks along -y: view -z is the world's -y
        m = from_column_major(f['view'])
        self.assertVec([-m[2][0], -m[2][1], -m[2][2]], [0.0, -1.0, 0.0], 1e-6)


class TestMapSize(ShadowCase):

    def testSizes(self):
        cases = [((0, False), DESKTOP), ((0, True), MOBILE),
                 ((-1, False), DESKTOP), ((-5, True), MOBILE),
                 ((3000, False), 2048), ((100, False), 256),
                 ((4096, False), 4096), ((5000, False), 4096),
                 ((4096, True), 2048), ((1500, True), 1024),
                 ((256, True), 256), ((1024, False), 1024)]
        for (setting, mobile), want in cases:
            self.assertEqual(lighting._light_shadow_map_size(setting, mobile),
                             want, (setting, mobile))

    def testSettingReachesThePlan(self):
        self.load_m()
        self.rig([light('key', orbit=-40.0, pitch=30.0, shadow=True)])
        self.assertEqual(cmd.get_setting_int('metal_light_shadow_size'), 0)
        frame = lighting._light_frame(M)
        self.assertEqual(frame['shadow_map_size'], DESKTOP)
        for setting, want in ((1000, 512), (4096, 4096), (0, DESKTOP)):
            cmd.set('metal_light_shadow_size', setting)
            frame = lighting._light_frame(M)
            self.assertEqual(frame['shadow_map_size'], want)
            self.assertEqual(frame['shadows']['size'], want)
            self.assertEqual(frame['shadows']['slots'][0]['map_size'], float(want))
            self.assertEqual(frame['rig']['block'][SHADOW_AT + 17], float(want))


class TestCasters(ShadowCase):
    """Overlays never cast (#433): the Move gizmo's CGO, gadgets and gizmos
    are left out of the casters and of the box the frusta are fitted to."""

    def setUp(self):
        super().setUp()
        self.load_m()
        cmd.load_cgo([cgo.SPHERE] + add(self.centre, [0.0, 0.0, 2.0]) + [3.0],
                      'blocker', zoom=0)
        cmd.load_cgo([cgo.SPHERE] + add(self.centre, [2.0, 0.0, 0.0]) + [3.0],
                      '_move_gizmo', zoom=0)
        cmd.ramp_new('rmp', 'm', [0.0, 10.0], ['red', 'blue'])

    def testCastersAndExcluded(self):
        got = lighting._light_shadow_casters()
        self.assertEqual(sorted(got['casters']), ['blocker', 'm'])
        self.assertEqual(sorted(got['excluded']), ['_move_gizmo', 'rmp'])
        self.assertEqual(got['overlay_name'], '_move_gizmo')
        lo, hi = got['extent']
        self.assertVec(lo, self.lo, 1e-4)
        self.assertVec(hi, self.hi, 1e-4)

    def testDisabledObjectAbsent(self):
        cmd.disable('blocker')
        got = lighting._light_shadow_casters()
        self.assertEqual(sorted(got['casters']), ['m'])
        self.assertNotIn('blocker', got['excluded'])

    def testFarOverlayLeavesTheFrustaAlone(self):
        self.rig([light('key', orbit=-40.0, pitch=30.0, shadow=True),
                  light('rim', orbit=150.0, pitch=20.0, shadow=True)])
        before = [s['view_proj'] for s in lighting._light_frame(M)['shadows']['slots']]
        far = add(self.centre, [0.0, 80.0, 0.0])
        cmd.delete('_move_gizmo')
        cmd.load_cgo([cgo.SPHERE] + far + [2.0], '_move_gizmo', zoom=0)
        after = [s['view_proj'] for s in lighting._light_frame(M)['shadows']['slots']]
        self.assertEqual(after, before)
        # an ordinary CGO at the same place does widen them
        cmd.delete('blocker')
        cmd.load_cgo([cgo.SPHERE] + far + [2.0], 'blocker', zoom=0)
        widened = [s['view_proj'] for s in lighting._light_frame(M)['shadows']['slots']]
        self.assertNotEqual(widened, before)

    def testMoveGizmoNameMatchesMetalMove(self):
        text = read_source(self, os.path.join('modules', 'pymol', 'metal_move.py'))
        name = re.search(r'''^_GIZMO_OBJ\s*=\s*['"](\w+)['"]''', text, re.M)
        self.assertIsNotNone(name)
        self.assertEqual(lighting._light_shadow_casters()['overlay_name'],
                         name.group(1))
        header = strip_comments(read_source(self, os.path.join('layer1',
                                                               'SceneLights.h')))
        self.assertRegex(header, r'kSceneMoveGizmoName\s*=\s*"%s"' % name.group(1))


class TestTiles(ShadowCase):

    def testTilesAreSquareDisjointAndInside(self):
        for size in (2048, 1000):
            for tiles in (1, 2, 3, 4):
                rects = []
                for cell in range(tiles * tiles):
                    t = lighting._light_shadow_tile(cell, tiles, size)
                    side = size // tiles
                    self.assertEqual(t['size'], side)
                    self.assertEqual((t['x'], t['y']),
                                     ((cell % tiles) * side, (cell // tiles) * side))
                    self.assertLessEqual(t['x'] + side, size)
                    self.assertLessEqual(t['y'] + side, size)
                    self.assertEqual(t['uv'], [f32(t['x'] / size), f32(t['y'] / size),
                                               f32(side / size), f32(side / size)])
                    rects.append((t['x'], t['y'], side))
                for i, a in enumerate(rects):
                    for b in rects[i + 1:]:
                        overlap = (a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and
                                   a[1] < b[1] + b[2] and b[1] < a[1] + a[2])
                        self.assertFalse(overlap, (size, tiles, a, b))

    def testOneTileIsTheWholeMap(self):
        t = lighting._light_shadow_tile(0, 1, 2048)
        self.assertEqual((t['x'], t['y'], t['size']), (0, 0, 2048))
        self.assertEqual(t['uv'], [0.0, 0.0, 1.0, 1.0])

    def testCellOutsideTheAtlas(self):
        for cell, tiles in ((-1, 2), (4, 2), (1, 1)):
            t = lighting._light_shadow_tile(cell, tiles, 2048)
            self.assertEqual(t['size'], 0, (cell, tiles))
            self.assertEqual(t['uv'], [0.0] * 4, (cell, tiles))

    def testGridReachesTheBlock(self):
        self.load_m()
        self.rig([light('key', orbit=-40.0, pitch=30.0, shadow=True)])
        frame = lighting._light_frame(M)
        self.assertEqual(frame['rig']['shadow_grid'], [1.0, 0.0, 1.0, 1.0])
        self.assertEqual(frame['shadows']['tiles'], 1)
        frame = lighting._light_frame(M, grid=(3, 2, 1))
        self.assertEqual(frame['shadows']['tiles'], 3)    # max(n_col, n_row)
        self.assertEqual(frame['shadows']['first_slot'], 1)
        self.assertEqual(frame['rig']['shadow_grid'], [3.0, 1.0, 3.0, 2.0])
        self.assertEqual(frame['rig']['block'][GRID_AT:TILE_AT], [3.0, 1.0, 3.0, 2.0])
        self.assertEqual(frame['rig']['shadow_tile'], [0.0] * 4)
        with self.assertRaises(Exception):
            lighting._light_frame(M, grid=(0, 2, 1))

    def testEveryGridCellHasItsOwnTile(self):
        # Every cell a grid of n_col x n_row can hold (cell = slot - first
        # slot, row-major as the grid loops number them) gets a whole tile of
        # the max(n_col, n_row)² atlas, and no two cells share texels: a cell
        # is shadowed only by what the map pass drew into its own tile.
        size = 2048
        for n_col in range(1, 7):
            for n_row in range(1, 7):
                tiles = max(n_col, n_row)
                side = size // tiles
                seen = set()
                for cell in range(n_col * n_row):
                    t = lighting._light_shadow_tile(cell, tiles, size)
                    label = (n_col, n_row, cell)
                    self.assertEqual(t['size'], side, label)
                    self.assertGreaterEqual(min(t['x'], t['y']), 0, label)
                    self.assertLessEqual(max(t['x'], t['y']) + side, size, label)
                    self.assertNotIn((t['x'], t['y']), seen, label)
                    seen.add((t['x'], t['y']))
                    # the texels the pass writes are the uv the lookup reads
                    self.assertEqual(t['uv'], [f32(t['x'] / size), f32(t['y'] / size),
                                               f32(side / size), f32(side / size)],
                                     label)

    def testGridKeepsTheFramesAndTheMapSize(self):
        # One frustum per light framed on the whole scene, grid or not: the
        # tiles split a map, never the light's view. info.y stays the map's
        # side (the lookup takes the tile's texels from shadow_tile.z).
        self.load_m()
        self.rig([light('key', orbit=-40.0, pitch=30.0, shadow=True),
                  light('fill', orbit=50.0, pitch=10.0, shadow=True)])
        plain = lighting._light_frame(M)['shadows']
        for grid in ((2, 1, 1), (2, 2, 1), (3, 2, 1)):
            gridded = lighting._light_frame(M, grid=grid)['shadows']
            self.assertEqual(gridded['count'], plain['count'], grid)
            self.assertEqual(gridded['size'], plain['size'], grid)
            self.assertEqual(gridded['tiles'], max(grid[0], grid[1]), grid)
            for a, b in zip(plain['slots'], gridded['slots']):
                self.assertEqual(a['view_proj'], b['view_proj'], grid)
                self.assertEqual(a['map_size'], b['map_size'], grid)
                self.assertEqual(b['map_size'], float(DESKTOP), grid)


class TestSettings(ShadowCase):

    def testIndicesTypesDefaults(self):
        from pymol import setting
        text = strip_comments(read_source(self, os.path.join('layer1',
                                                             'SettingInfo.h')))
        for index, name in ((882, 'metal_light_shadow_size'),
                            (883, 'metal_gpu_timing')):
            self.assertEqual(setting._get_index(name), index)
            self.assertRegex(text, r'REC_i\(\s*%d,\s*%s\s*,\s*global\s*,\s*0\s*\)'
                             % (index, name))
            self.assertEqual(cmd.get_setting_int(name), 0)

    def testNotPartOfTheLook(self):
        from pymol import raymol_scenes
        for name in ('metal_light_shadow_size', 'metal_gpu_timing'):
            self.assertNotIn(name, raymol_scenes.CAPTURE)


class TestGpuTime(ShadowCase):

    def testSummary(self):
        s = lighting._gpu_time_summary([5.0, 1.0, 3.0, 2.0, 4.0])
        self.assertEqual(s, {'count': 5, 'mean': 3.0, 'median': 3.0,
                             'p95': 5.0, 'max': 5.0})
        s = lighting._gpu_time_summary([float(v) for v in range(20, 0, -1)])
        self.assertEqual(s['count'], 20)
        self.assertEqual(s['median'], 10.5)
        self.assertEqual(s['p95'], 19.0)      # nearest rank: ceil(0.95 x 20)
        self.assertEqual(s['max'], 20.0)
        self.assertAlmostEqual(s['mean'], 10.5)
        s = lighting._gpu_time_summary([float(v) for v in range(1, 101)])
        self.assertEqual(s['p95'], 95.0)
        s = lighting._gpu_time_summary([7.0])
        self.assertEqual((s['median'], s['p95'], s['max']), (7.0, 7.0, 7.0))

    def testBadSamplesDropped(self):
        s = lighting._gpu_time_summary(
            [2.0, float('nan'), float('inf'), -1.0, 4.0, float('-inf')])
        self.assertEqual(s['count'], 2)
        self.assertEqual((s['mean'], s['median'], s['max']), (3.0, 3.0, 4.0))
        empty = lighting._gpu_time_summary([])
        self.assertEqual(empty, {'count': 0, 'mean': 0.0, 'median': 0.0,
                                 'p95': 0.0, 'max': 0.0})
        self.assertEqual(lighting._gpu_time_summary([float('nan')])['count'], 0)

    def testNoRendererNoStats(self):
        # CI and the headless tests have no Metal renderer
        self.assertIsNone(lighting._gpu_frame_stats())
        cmd.set('metal_gpu_timing', 2)
        try:
            self.assertIsNone(lighting._gpu_frame_stats())
        finally:
            cmd.set('metal_gpu_timing', 0)

    # The readout's log lines (the plan's D14), written out here.
    WINDOW = re.compile(r'^RendererMetal: gpu_ms window n=(\d+) median=(\d+\.\d\d) '
                        r'p95=(\d+\.\d\d) max=(\d+\.\d\d) shadow_maps=(\d+) '
                        r'shadow_size=(\d+)$')
    FRAME = re.compile(r'^RendererMetal: gpu_ms frame=(\d+\.\d\d) shadow_maps=(\d+) '
                       r'shadow_size=(\d+) offscreen=([01])$')
    # What gate.sh sim greps the console for (case-insensitive), and the
    # L4 grep for renderer failures.
    BANNED = re.compile(r'validation|MTLDebug|failed assertion|-\[MTL|fail|missing',
                        re.I)

    def replay(self, frames, mode):
        out = lighting._gpu_time_replay(frames, mode)
        for line in out['lines']:
            self.assertIsNone(self.BANNED.search(line), line)
            self.assertTrue(self.WINDOW.match(line) or self.FRAME.match(line), line)
        return out

    def testWindowMode(self):
        """Mode 1: the first frame logs at once (n=1), then one summary per
        window of >= 1 s of live frames, with the latest frame's maps."""
        frames = [(4.0, 1, 1024, False, 10.0),     # first frame: a window of one
                  (2.0, 1, 1024, False, 10.3),
                  (6.0, 1, 1024, False, 10.6),
                  (3.0, 3, 2048, False, 10.99),    # still inside the window
                  (5.0, 3, 2048, False, 11.0),     # 1 s after the last line
                  (9.0, 0, 0, False, 11.5),
                  (1.0, 0, 0, False, 12.25)]
        out = self.replay(frames, 1)
        windows = [self.WINDOW.match(line).groups() for line in out['lines']]
        self.assertEqual(windows, [
            ('1', '4.00', '4.00', '4.00', '1', '1024'),
            # 2, 6, 3, 5: median 4, nearest-rank p95 the 4th, max 6
            ('4', '4.00', '6.00', '6.00', '3', '2048'),
            ('2', '5.00', '9.00', '9.00', '0', '0'),
        ])
        stats = out['stats']
        self.assertEqual(stats['count'], 7)
        self.assertEqual((stats['last_ms'], stats['mode'], stats['shadow_maps'],
                          stats['shadow_size']), (1.0, 1, 0, 0))
        self.assertEqual((stats['median'], stats['max']), (4.0, 9.0))

    def testFrameModeAndOffscreen(self):
        """Mode 2 logs every live frame; offscreen frames log in modes 1 and
        2 and never enter a mode-1 window."""
        out = self.replay([(1.5, 1, 1024, False, 0.0), (2.25, 1, 1024, False, 0.01),
                           (12.346, 3, 2048, True, 0.02)], 2)
        self.assertEqual([self.FRAME.match(line).groups() for line in out['lines']],
                         [('1.50', '1', '1024', '0'), ('2.25', '1', '1024', '0'),
                          ('12.35', '3', '2048', '1')])
        out = self.replay([(2.0, 0, 0, False, 0.0), (7.0, 1, 1024, True, 0.5),
                           (3.0, 0, 0, False, 1.2)], 1)
        self.assertEqual(out['lines'], [
            'RendererMetal: gpu_ms window n=1 median=2.00 p95=2.00 max=2.00 '
            'shadow_maps=0 shadow_size=0',
            'RendererMetal: gpu_ms frame=7.00 shadow_maps=1 shadow_size=1024 offscreen=1',
            # the offscreen frame is not in this window
            'RendererMetal: gpu_ms window n=1 median=3.00 p95=3.00 max=3.00 '
            'shadow_maps=0 shadow_size=0'])
        self.assertEqual(out['stats']['count'], 3)

    def testOffRecordsNothing(self):
        for mode in (0, -1):
            out = self.replay([(2.0, 1, 1024, False, 0.0), (3.0, 1, 1024, True, 1.0)],
                              mode)
            self.assertEqual(out, {'lines': [], 'stats': None})

    def testBadFramesIgnored(self):
        out = self.replay([(float('nan'), 1, 1024, False, 0.0),
                           (-1.0, 1, 1024, False, 0.1),
                           (float('inf'), 1, 1024, True, 0.2)], 2)
        self.assertEqual(out, {'lines': [], 'stats': None})
        # a bad frame does not open the first window either
        out = self.replay([(float('nan'), 1, 1024, False, 0.0),
                           (2.0, 1, 1024, False, 0.1)], 1)
        self.assertEqual(len(out['lines']), 1)
        self.assertTrue(out['lines'][0].startswith('RendererMetal: gpu_ms window n=1 '))

    def testRingHoldsTheLast120(self):
        frames = [(float(i), 0, 0, True, i * 0.01) for i in range(1, 131)]
        stats = self.replay(frames, 2)['stats']
        # frames 11..130 remain
        self.assertEqual(stats['count'], 120)
        self.assertEqual(stats['last_ms'], 130.0)
        self.assertEqual(stats['max'], 130.0)
        self.assertEqual(stats['median'], 70.5)
        self.assertEqual(stats['p95'], 124.0)    # ceil(0.95 x 120) = 114th of 11..130


class TestSource(testing.PyMOLTestCase):
    """What the pure files may use, and where the plan is read."""

    PURE = [os.path.join('layer1', n) for n in
            ('LightRigBlock.h', 'LightShadows.h', 'LightShadows.cpp')] + \
           [os.path.join('layer0', n) for n in
            ('GpuFrameTimes.h', 'GpuFrameTimes.cpp')]
    PYTHON = re.compile(r'os_python\.h|Python\.h|\bPConv\w*|\bPyObject\b'
                        r'|\bPy_\w+|PyMOLGlobals|LightRigPy\.h|SettingGet')

    def read(self, rel):
        return strip_comments(read_source(self, rel))

    def testPureFilesUseNoPython(self):
        for rel in self.PURE:
            found = self.PYTHON.search(self.read(rel))
            self.assertIsNone(found, '%s uses %r' % (rel, found and found.group(0)))

    def testIncludes(self):
        block = self.read(os.path.join('layer1', 'LightRigBlock.h'))
        self.assertEqual(re.findall(r'#include\s+"', block), [])
        shadows = self.read(os.path.join('layer1', 'LightShadows.h'))
        self.assertEqual(sorted(re.findall(r'#include\s+"([^"]+)"', shadows)),
                         ['LightRig.h', 'LightRigBlock.h'])
        self.assertRegex(shadows, r'static_assert\(kLightRigBlockShadowSlots\s*==\s*'
                                  r'kLightRigMaxShadowed')
        times = self.read(os.path.join('layer0', 'GpuFrameTimes.h'))
        self.assertEqual(re.findall(r'#include\s+"', times), [])

    def testPlanReadOnlyWhenStudioShadowsAreOn(self):
        """No new setting, extent or plan is read on a frame without a rig,
        or without a shadowed light at metal_shadows 1."""
        body = function_body(self.read(os.path.join('layer1', 'SceneLights.cpp')),
                             'SceneLightsFrame')
        gate = re.search(r'if\s*\(\s*frame\.rig\s*&&', body)
        self.assertIsNotNone(gate)
        for token in ('cSetting_metal_light_shadow_size', 'cSetting_metal_shadows',
                      'cSetting_metal_shadow_bias', 'SceneGetLightShadowExtent',
                      'LightShadowPlan', 'G->Scene->grid'):
            self.assertEqual(body.count(token), 1, token)
            self.assertGreater(body.index(token), gate.start(), token)
        self.assertNotIn('cSetting_metal_gpu_timing', body)

    def testOverlayFreeExtentIsCachedAndInvalidated(self):
        scene = self.read(os.path.join('layer1', 'Scene.cpp'))
        body = function_body(scene, 'SceneInvalidateExtentCache')
        self.assertIn('LightShadowExtentValid = false', body)
        self.assertIn('ShadowExtentValid = false', body)
        render = self.read(os.path.join('layer1', 'SceneRender.cpp'))
        body = function_body(render, 'SceneGetLightShadowExtent')
        self.assertEqual(len(re.findall(r'SceneComputeShadowExtent\([^;]*,\s*true\s*\)',
                                        body)), 2)
        classic = function_body(render, 'SceneGetShadowExtent')
        self.assertNotIn('LightShadow', classic)
        compute = function_body(render, 'SceneComputeShadowExtent')
        self.assertRegex(compute, r'if\s*\(\s*skip_overlays\s*&&\s*'
                                  r'SceneObjectIsOverlay\(obj\)\s*\)\s*continue;')

    def testFrameCommandUpdatesTheSceneFirst(self):
        cmd_cpp = self.read(os.path.join('layer4', 'Cmd.cpp'))
        for name, call in (('CmdGetLightFrame', 'SceneLightsFrame('),
                           ('CmdGetLightShadowCasters', 'SceneLightShadowCasterNames(')):
            body = function_body(cmd_cpp, name)
            self.assertLess(body.index('ExecutiveUpdateSceneMembers(G)'),
                            body.index(call), name)

    def testRenderKeepsTheFrameForThePrePass(self):
        """SceneRenderMetal declares the frame before the matrices block and
        assigns it there, with #613's call text, once."""
        body = function_body(self.read(os.path.join('layer1', 'SceneRender.cpp')),
                             'SceneRenderMetal')
        decl = re.search(r'\bSceneLightFrame\s+lights\s*;', body)
        self.assertIsNotNone(decl)
        call = re.search(r'\blights\s*=\s*SceneLightsFrame\(G,\s*glm::dmat4\('
                         r'glm::make_mat4\(mv\)\)\);', body)
        self.assertIsNotNone(call)
        self.assertLess(decl.start(), call.start())
        self.assertEqual(body.count('SceneLightsFrame('), 1)
