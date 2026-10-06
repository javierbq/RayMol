"""The in-scene light gizmo: the Python half (#622).

The gizmo (swiftui/PyMOLViewer/Shared/LightGizmo*.swift) is a SwiftUI
overlay, never scene geometry. It draws the rig from the eye-space resolver
(LightRigResolve, reached here as lighting._lights_eye, as the app bridge
reads it) through a Swift projection of the live camera, and edits the
selected light through the C++ setter the bridge calls per drag tick
(LightRigSet, here lighting._light_set): a knob tick writes pitch then orbit,
an aim-dot tick writes aim_point with the surface pick's point (#614). An
option-click is a click, not a tick: it runs #612's click= helper once, as a
console command.

This file pins what the gizmo relies on in the core:
- TestBehindRule: 'behind the molecule' (the hollow knob and bar chip) is
  cos(orbit) cos(pitch) < -1e-4, which is the sign of the light's eye-space
  z offset from the rig centre, for camera lights and for a pinned light
  under a turning camera;
- TestKnobWrites: the trackball's inverse (orbit = atan2(dx, dz), pitch =
  asin(dy)), written pitch then orbit, puts the light along (dx, dy, dz) in
  eye space, re-pinning a pinned light; a write at pitch 88 keeps the orbit;
- TestAimPoint: aim_point at a surface_at hit aims the light at that point,
  clears the aim selection and keeps the placement;
- TestHighlightCommand: the exact strings LightsAction.highlight sends
  (LightsActionInvocationTests pins them on the Swift side: change both
  together) aim at the surface_at hit, put the light in front of it (the
  mirror rule) or behind it (rim=145), keep a pinned light pinned with pin=1,
  and change nothing on a miss;
- TestGizmoSource: the Swift sources keep one owner guard for every gesture
  write, the eye demand in the engine's mode switch, the renderer's projection
  slope, and the gizmo out of LightRigBridge.swift (comments stripped;
  skipped outside a checkout).

CI builds the GLUT flavour without a GPU, so this exercises _cmd and Python
only.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_gizmo.py
"""
import contextlib
import io
import math
import os
import re

import pymol
import pymol.invocation
from pymol import cmd, lighting, metal_pick, testing

PEPTIDE = 'ACDEFG'
SIZE = 10.0

# LightDepth.tolerance (LightGizmoGeometry.swift; TestGizmoSource reads it).
BEHIND_TOLERANCE = 1e-4

# eye-space values are float32 (GPU inputs)
REL = 1e-4
ANGLE_TOL = 2e-3


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def norm(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = norm(a)
    return [x / n for x in a]


def wrap(degrees):
    """Into (-180, 180], as the core wraps orbit."""
    x = math.fmod(degrees + 180.0, 360.0)
    if x <= 0.0:
        x += 360.0
    return x - 180.0


def is_behind(orbit, pitch):
    """LightDepth.isBehind: cos(orbit) cos(pitch) < -1e-4 (degrees)."""
    return (math.cos(math.radians(orbit)) * math.cos(math.radians(pitch))
            < -BEHIND_TOLERANCE)


def knob_angles(d):
    """The knob drag's inverse (LightTrackball): (orbit, pitch) in degrees
    of a unit eye-space direction (dx, dy, dz)."""
    return (math.degrees(math.atan2(d[0], d[2])),
            math.degrees(math.asin(max(-1.0, min(1.0, d[1])))))


def world_to_eye(p, _self=cmd):
    """A world point in eye space under the live camera:
    eye = R (p - origin) + pos (metal_pick.camera's convention)."""
    cam = metal_pick.camera(_self)
    d = sub(p, cam.origin)
    return [sum(cam.rot[3 * i + k] * d[k] for k in range(3)) + cam.pos[i]
            for i in range(3)]


def eye_light(index=0):
    return lighting._lights_eye()['lights'][index]


def eye_offset(index=0):
    """Light `index`'s eye-space offset from the rig centre."""
    eye = lighting._lights_eye()
    return sub(eye['lights'][index]['position'], eye['centre'])


def output(func, *args, **kwargs):
    """Run func, return (result, what it printed from Python)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args, **kwargs)
    return result, buf.getvalue()


def do(line):
    """cmd.do(line), the app's command path (runCommand); returns the printed
    text. The runner's -y (exit on error) would quit on the error a miss
    prints, so it is off for the call."""
    options = pymol.invocation.options
    exit_on_error = options.exit_on_error
    options.exit_on_error = 0
    try:
        return output(cmd.do, line)[1]
    finally:
        options.exit_on_error = exit_on_error


class GizmoCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.fab(PEPTIDE, 'pep')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def rig(self, lights, centre=(1.0, -2.0, 3.0)):
        lighting.set_lights({'enabled': True, 'centre': list(centre),
                             'size': SIZE, 'lights': lights})

    def turn(self):
        """The camera of the plan: turned, so eye space is not world space."""
        cmd.turn('y', 40)
        cmd.turn('x', -25)

    def assertClose(self, got, want, rel=REL, msg=None):
        self.assertAlmostEqual(got, want, delta=rel * max(1.0, abs(want)),
                               msg='%r != %r %s' % (got, want, msg or ''))

    def assertVec(self, got, want, rel=REL, msg=None):
        for g, w in zip(got, want):
            self.assertClose(g, w, rel, msg)

    def assertAngle(self, got, want, msg=None):
        self.assertLessEqual(abs(wrap(got - want)), ANGLE_TOL,
                             '%r != %r %s' % (got, want, msg or ''))

    def assertBehindRule(self, index, msg):
        """The rule on the resolver's orbit and pitch says what the light's
        eye-space z offset from the centre says."""
        entry = eye_light(index)
        d = unit(eye_offset(index))
        self.assertEqual(is_behind(entry['orbit'], entry['pitch']),
                         d[2] < -BEHIND_TOLERANCE,
                         '%s: orbit %r pitch %r offset %r' % (
                             msg, entry['orbit'], entry['pitch'], d))
        return d[2] < -BEHIND_TOLERANCE


class TestBehindRule(GizmoCase):

    ORBITS = [-180.0, -135.0, -92.0, -90.0, -88.0, -45.0, 0.0, 45.0, 88.0,
              90.0, 92.0, 135.0, 180.0]
    PITCHES = [-90.0, -60.0, -20.0, 0.0, 20.0, 60.0, 88.0, 90.0]

    def testCameraLights(self):
        """Over an orbit and pitch grid under a turned camera: orbit 88 is in
        front, 92 behind, 90 and the poles on the outline count as front."""
        self.turn()
        seen = set()
        for orbit in self.ORBITS:
            for pitch in self.PITCHES:
                self.rig([{'name': 'key', 'orbit': orbit, 'pitch': pitch,
                           'radius': 2.5}])
                behind = self.assertBehindRule(0, 'orbit %r pitch %r' % (
                    orbit, pitch))
                seen.add(behind)
                if pitch in (-90.0, 90.0) or orbit in (-90.0, 90.0):
                    self.assertFalse(behind, 'the outline counts as front')
                if pitch == 0.0 and orbit in (88.0, -88.0):
                    self.assertFalse(behind)
                if pitch == 0.0 and orbit in (92.0, -92.0, 180.0):
                    self.assertTrue(behind)
        self.assertEqual(seen, {False, True})

    def testPinnedLightUnderATurningCamera(self):
        """A pinned light's derived orbit and pitch follow the camera, and the
        rule keeps matching its eye-space depth through a full turn (it
        crosses to the back and returns)."""
        self.turn()
        self.rig([{'name': 'key', 'orbit': 30.0, 'pitch': 15.0,
                   'radius': 3.0}])
        lighting._light_set(0, 'anchor', 1)
        seen = []
        for step in range(12):
            if step:
                cmd.turn('y', 30)
            self.assertEqual(eye_light()['anchor'], 'pinned')
            seen.append(self.assertBehindRule(0, 'step %d' % step))
        self.assertIn(True, seen)
        self.assertIn(False, seen)


class TestKnobWrites(GizmoCase):

    DIRECTIONS = [
        (0.3, 0.4, math.sqrt(1.0 - 0.25)),
        (-0.6, 0.2, -math.sqrt(1.0 - 0.40)),
        (0.1, -0.9, math.sqrt(1.0 - 0.82)),
        (-0.7, -0.1, math.sqrt(1.0 - 0.50)),
        (0.0, 0.0, -1.0),
        (math.sin(math.radians(88.0)), 0.0, math.cos(math.radians(88.0))),
        (math.sin(math.radians(92.0)), 0.0, math.cos(math.radians(92.0))),
    ]

    def write(self, index, d):
        """One knob tick: pitch, then orbit (setPlacement's order)."""
        orbit, pitch = knob_angles(d)
        lighting._light_set(index, 'pitch', pitch)
        lighting._light_set(index, 'orbit', orbit)
        return orbit, pitch

    def testCameraLight(self):
        self.turn()
        self.rig([{'name': 'key', 'radius': 2.0}])
        for d in self.DIRECTIONS:
            orbit, pitch = self.write(0, d)
            self.assertVec(unit(eye_offset()), d, msg=repr(d))
            self.assertClose(norm(eye_offset()), 2.0 * SIZE)
            self.assertEqual(is_behind(orbit, pitch), d[2] < 0.0, repr(d))

    def testPinnedLightIsRepinned(self):
        self.rig([{'name': 'key', 'orbit': 20.0, 'pitch': 10.0,
                   'radius': 3.0}])
        lighting._light_set(0, 'anchor', 1)
        self.turn()
        cmd.move('z', -15)
        for d in self.DIRECTIONS:
            self.write(0, d)
            entry = eye_light()
            self.assertEqual(entry['anchor'], 'pinned', 'the light stays pinned')
            self.assertVec(unit(eye_offset()), d, msg=repr(d))
            self.assertClose(entry['radius'], 3.0)

    def testPitch88KeepsTheOrbit(self):
        """The knob holds 2 degrees off the poles: a write there keeps the
        orbit, camera light or pinned."""
        self.turn()
        self.rig([{'name': 'key', 'orbit': 40.0, 'pitch': 10.0,
                   'radius': 2.0},
                  {'name': 'fill', 'orbit': 40.0, 'pitch': 10.0,
                   'radius': 2.0}])
        lighting._light_set(1, 'anchor', 1)
        for index in (0, 1):
            lighting._light_set(index, 'pitch', 88.0)
            entry = eye_light(index)
            self.assertAngle(entry['orbit'], 40.0, 'light %d' % index)
            self.assertAlmostEqual(entry['pitch'], 88.0, delta=ANGLE_TOL)
            lighting._light_set(index, 'pitch', -88.0)
            self.assertAngle(eye_light(index)['orbit'], 40.0)


class TestAimPoint(GizmoCase):

    def setUp(self):
        super().setUp()
        cmd.viewport(400, 300)
        cmd.set('async_builds', 0)
        cmd.show_as('spheres', 'pep')
        cmd.orient('pep')

    def ndc_of_atom(self, selection):
        """The scene NDC of an atom's centre under the live camera (the
        surface pick's projection, metal_pick.camera)."""
        cam = metal_pick.camera()
        e = world_to_eye(cmd.get_coords(selection)[0].tolist())
        width, height = cmd.get_viewport()
        depth = -e[2]
        return (e[0] / (depth * cam.tan_half * float(width) / float(height)),
                e[1] / (depth * cam.tan_half))

    def testAimPointAtAPick(self):
        self.turn()
        self.rig([{'name': 'key', 'orbit': -30.0, 'pitch': 20.0,
                   'radius': 2.5, 'aim': 'point', 'aim_point': [0.0, 0.0, 0.0],
                   'aim_selection': 'resi 2'}])
        x, y = self.ndc_of_atom('pep and resi 3 and name CA')
        hit = metal_pick.surface_at(x, y)
        self.assertIsNotNone(hit, 'the pick missed the peptide at %r/%r' % (x, y))
        before = lighting.get_lights()['lights'][0]
        self.assertEqual(before['aim_selection'], 'resi 2')
        lighting._light_set(0, 'aim_point', list(hit.point))
        after = lighting.get_lights()['lights'][0]
        self.assertEqual(after['aim'], 'point')
        self.assertEqual(after['aim_selection'], '', 'the selection text is cleared')
        self.assertVec(after['aim_point'], hit.point)
        for field in ('orbit', 'pitch', 'radius', 'beam', 'softness', 'anchor'):
            self.assertEqual(after[field], before[field], field)
        entry = eye_light()
        target = world_to_eye(hit.point)
        self.assertVec(entry['target'], target, rel=1e-4)
        self.assertVec(entry['direction'],
                       unit(sub(entry['target'], entry['position'])), rel=1e-4)
        self.assertClose(entry['aim_distance'],
                         norm(sub(entry['target'], entry['position'])))


# The pinned camera of raymol/lighting_commands.py PlacementCase: rotation
# identity, origin (0,0,0), camera at world z = +100 looking down -Z, slab
# [50, 150], field of view 20 degrees (perspective), viewport 400 x 300.
PINNED_VIEW = (1.0, 0.0, 0.0,
               0.0, 1.0, 0.0,
               0.0, 0.0, 1.0,
               0.0, 0.0, -100.0,
               0.0, 0.0, 0.0,
               50.0, 150.0, -20.0)

# What LightsAction.highlight(name:x:y:rim:pin:).invocation sends
# (LightsActionInvocationTests.testHighlightStrings).
CLICK = 'lights key, click=0.1250/-0.0625'
CLICK_RIM = 'lights key, click=0.1250/-0.0625, rim=145'
CLICK_PIN = 'lights key, click=0.1250/-0.0625, pin=1'
CLICK_RIM_PIN = 'lights key, click=0.1250/-0.0625, rim=145, pin=1'
CLICK_ZERO = 'lights key, click=0.0000/0.2500'
CLICK_MISS = 'lights key, click=0.9000/0.9000'


class TestHighlightCommand(testing.PyMOLTestCase):
    """A ball of radius 8 at the origin under the pinned camera: every click
    above is on it but the miss."""

    R = 8.0

    def setUp(self):
        super().setUp()
        cmd.viewport(400, 300)
        cmd.set('async_builds', 0)
        cmd.pseudoatom('ball', pos=[0.0, 0.0, 0.0], vdw=self.R)
        cmd.show_as('spheres', 'ball')
        cmd.set_view(PINNED_VIEW)
        lighting.set_lights({'enabled': True, 'centre': [0.0, 0.0, 0.0],
                             'size': SIZE,
                             'lights': [{'name': 'key', 'orbit': 30.0,
                                         'pitch': 10.0, 'radius': 3.0}]})

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def placed(self, line, x, y):
        """Run `line`; the light aims at surface_at(x, y) and is returned
        with its eye-space depth relative to that point (> 0: in front)."""
        hit = metal_pick.surface_at(x, y)
        self.assertIsNotNone(hit, 'the ball is not under %r/%r' % (x, y))
        text = do(line)
        self.assertNotIn('Error', text, line)
        light = lighting.get_lights()['lights'][0]
        self.assertEqual(light['aim'], 'point', line)
        for got, want in zip(light['aim_point'], hit.point):
            self.assertAlmostEqual(got, want, delta=1e-3, msg=line)
        entry = eye_light()
        depth = entry['position'][2] - world_to_eye(hit.point)[2]
        return light, depth

    def testMirrorRulePutsTheLightInFront(self):
        light, depth = self.placed(CLICK, 0.125, -0.0625)
        self.assertGreater(depth, 0.0, 'the mirror rule lights the point from the front')
        self.assertEqual(light['anchor'], 'camera')
        light, depth = self.placed(CLICK_ZERO, 0.0, 0.25)
        self.assertGreater(depth, 0.0)

    def testRimRulePutsTheLightBehind(self):
        _, depth = self.placed(CLICK_RIM, 0.125, -0.0625)
        self.assertLess(depth, 0.0, 'rim=145 puts the light behind the point')

    def testPinKeepsAPinnedLightPinned(self):
        lighting._light_set(0, 'anchor', 1)
        light, _ = self.placed(CLICK_PIN, 0.125, -0.0625)
        self.assertEqual(light['anchor'], 'pinned', 'pin=1 keeps the pin')
        light, depth = self.placed(CLICK_RIM_PIN, 0.125, -0.0625)
        self.assertEqual(light['anchor'], 'pinned')
        self.assertLess(depth, 0.0)
        # Without pin=1 the helper leaves a camera light (#610's anchoring
        # decision): why the gizmo sends it for a pinned light.
        light, _ = self.placed(CLICK, 0.125, -0.0625)
        self.assertEqual(light['anchor'], 'camera')

    def testAMissChangesNothing(self):
        self.assertIsNone(metal_pick.surface_at(0.9, 0.9))
        before = lighting._lights_json()
        text = do(CLICK_MISS)
        self.assertIn('lights', text)
        self.assertEqual(lighting._lights_json(), before)


# --- the Swift sources ----------------------------------------------------------

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SHARED = os.path.join('swiftui', 'PyMOLViewer', 'Shared')
EDITING = os.path.join(SHARED, 'LightsEditing.swift')
ENGINE = os.path.join(SHARED, 'PyMOLEngine.swift')
BRIDGE = os.path.join(SHARED, 'LightRigBridge.swift')
GEOMETRY = os.path.join(SHARED, 'LightGizmoGeometry.swift')
METAL_PICK = os.path.join('modules', 'pymol', 'metal_pick.py')
SCENE_RENDER = os.path.join('layer1', 'SceneRender.cpp')


def strip_comments(text):
    """Swift comments removed (as lighting_mode.strip_comments), so a
    comment can neither satisfy nor trip a check."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def body(text, signature):
    """The braces-matched body that follows `signature` (None when absent)."""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find('{', start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


class TestGizmoSource(testing.PyMOLTestCase):

    def read(self, rel, swift=True):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source check that cannot find its source
            # has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            text = handle.read()
        return strip_comments(text) if swift else text

    def testOneOwnerGuard(self):
        """The owner-name comparison appears once in LightsEditing.swift,
        inside ownsGesture, after the stale re-read; every owner: write
        (set, setPlacement, setAim) calls it first."""
        text = self.read(EDITING)
        self.assertEqual(len(re.findall(r'owner\.lowercased\(\)', text)), 1)
        guard = body(text, 'func ownsGesture(_ owner: String) -> Bool')
        self.assertIsNotNone(guard, 'ownsGesture not found')
        self.assertIn('owner.lowercased()', guard)
        self.assertIn('canEdit', guard)
        reread = guard.find('refreshIfStale()')
        self.assertGreater(reread, guard.find('canEdit'))
        self.assertGreater(guard.find('selection.name'), reread)

        entries = {}
        for match in re.finditer(r'func (\w+)\(([^{]*?)\)\s*->\s*LightSetResult\s*\{',
                                 text):
            if 'owner: String' in match.group(2):
                entries[match.group(1)] = body(text, match.group(0))
        self.assertEqual(sorted(entries), ['set', 'setAim', 'setPlacement'])
        for name, block in entries.items():
            with self.subTest(name):
                first = block[1:].lstrip()
                self.assertTrue(first.startswith('guard ownsGesture(owner) else'),
                                first[:60])
        self.assertIn('edit("aim_point", point)', entries['setAim'])
        self.assertIn('setPlacement(orbit: orbit, pitch: pitch, radius: radius)',
                      entries['setPlacement'])

    def testTheEngineDrivesTheEyeDemand(self):
        """setInteractionMode sets .everyFrame before begin() on entering
        Lights, and .pinnedOnly plus releaseSurfacePick() after end() on
        leaving. No other app file sets the demand."""
        engine = self.read(ENGINE)
        mode = body(engine, 'func setInteractionMode(_ mode: InteractionMode)')
        self.assertIsNotNone(mode, 'setInteractionMode not found')
        every = mode.find('lightsController.eyeDemand = .everyFrame')
        begin = mode.find('lightsController.begin()')
        self.assertGreaterEqual(every, 0)
        self.assertGreater(begin, every)
        end = mode.find('lightsController.end()')
        self.assertGreater(end, begin)
        self.assertGreater(mode.find('lightsController.eyeDemand = .pinnedOnly'), end)
        self.assertGreater(mode.find('releaseSurfacePick()'), end)
        self.assertEqual(len(re.findall(r'eyeDemand\s*=[^=]', engine)), 2)
        shared = os.path.join(ROOT, SHARED)
        for name in sorted(os.listdir(shared)):
            if name.endswith('.swift') and name not in ('PyMOLEngine.swift',
                                                        'LightsController.swift'):
                with self.subTest(name):
                    text = self.read(os.path.join(SHARED, name))
                    self.assertIsNone(re.search(r'eyeDemand\s*=[^=]', text))

    def testTheProjectionSlopeIsTheRenderers(self):
        """LightCameraProjection computes the slope as metal_pick.camera and
        SceneProjectionMatrix do: tan(GetFovWidth / 2) with GetFovWidth =
        2 tan(fov / 2), the orthoscopic half height max(1e-4, d) GetFovWidth
        / 2, and the field_of_view fallback when |view[24]| <= 1."""
        swift = self.read(GEOMETRY)
        self.assertIn('2 * tan(fovDegrees * .pi / 360)', swift)
        self.assertIn('tan(fovWidth / 2)', swift)
        self.assertIn('max(1e-4, cameraDistance) * fovWidth / 2', swift)
        self.assertIn('abs(view[24])', swift)
        self.assertIn('if fov <= 1', swift)
        self.assertIn('fieldOfView', swift)
        self.assertRegex(swift, r'static let tolerance\s*=\s*1e-4')
        python = self.read(METAL_PICK, swift=False)
        self.assertIn('fov_width = 2.0 * math.tan(math.radians(fov_deg) / 2.0)', python)
        self.assertIn('tan_half = math.tan(fov_width / 2.0)', python)
        self.assertIn('if fov_deg <= 1.0:', python)
        cpp = self.read(SCENE_RENDER, swift=False)
        self.assertIn('glm::perspective(GetFovWidth(G)', cpp)
        self.assertIn('std::max(R_SMALL4, -I->m_view.pos().z) * GetFovWidth(G) / 2.f', cpp)

    def testNoGizmoCodeInTheBridgeWrapper(self):
        """The projection reader is the engine's; LightRigBridge.swift keeps
        only the light functions (lighting_bridge.py checks those)."""
        bridge = self.read(BRIDGE)
        for name in ('LightCameraProjection', 'LightGizmo', 'LightDepth',
                     'captureView', 'GetView', 'GetLetterboxAspect'):
            with self.subTest(name):
                self.assertNotIn(name, bridge)
        engine = self.read(ENGINE)
        reader = body(engine, 'func lightCameraProjection() -> LightCameraProjection?')
        self.assertIsNotNone(reader, 'lightCameraProjection() not in PyMOLEngine.swift')
        self.assertIn('captureView()', reader)
        self.assertIn('letterboxAspect(handle:', reader)
        self.assertIn('"field_of_view"', reader)
        self.assertNotRegex(reader, r'runPython|runCommand')
