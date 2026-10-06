"""The orbit mini viewer: the Python half (#621).

The orbit view (swiftui/PyMOLViewer/Shared/LightsOrbitModel.swift) draws the
rig as a flat plan seen from above, the camera at the bottom, plus a pitch
arc, and writes only orbit, pitch or radius of the selected light, snapped to
LightSnap's grids (orbit every 15 degrees, radius every 0.5 scene sizes),
through the C++ setter the app bridge calls per drag tick (LightRigSet,
reached here as lighting._light_set). It reads where each light is from the
eye-space resolver (LightRigResolve, lighting._lights_eye), as the bridge
does.

What the existing files already pin is not repeated here (the angle
convention, radius in scene sizes, clamps and wraps, the beam kept on a
radius change and the pinned re-pin rules: lighting_eye.py, lighting_rig.py,
lighting_shading.py). This file pins what the plan adds:
- TestPlanGrid: every value on the plan's grids is a value the core holds
  exactly, and an orbit write at a pole leaves the light where it is;
- TestPlanMatchesTheRender: under a turned camera, the position the Metal
  renderer reads (the packed GPU block, lighting._light_frame) is the
  resolver's, and its offset from the eye-space centre decomposes into the
  orbit, pitch and radius the plan draws;
- TestOrbitSource: the Swift sources keep the grids, the owner guard after
  the stale re-read, the one edit path and the inspector's gesture hook; the
  card sits above the inspector, writes only through the interaction, runs a
  pinch beside its drag, starts collapsed on every iPhone and is logged as
  plan= (comments stripped; skipped outside a checkout).

CI builds the GLUT flavour without a GPU, so this exercises _cmd and Python
only. A small peptide (cmd.fab) gives the rig a real frame.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_orbit.py
"""
import math
import os
import re

from pymol import cmd, lighting, testing

PEPTIDE = 'ACDEFG'
SIZE = 10.0

# LightSnap's grids (LightsEditing.swift; TestOrbitSource reads them back).
ORBIT_STEP = 15.0
RADIUS_STEP = 0.5

# The 15-degree orbit grid in (-180, 180].
ORBIT_GRID = [ORBIT_STEP * k for k in range(-11, 13)]
RADIUS_GRID = [RADIUS_STEP * k for k in range(1, 17)]

# eye-space values are float32 (GPU inputs)
REL = 1e-4
ANGLE_TOL = 2e-3


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


def norm(a):
    return math.sqrt(sum(x * x for x in a))


def wrap(degrees):
    """Into (-180, 180], as the core wraps orbit."""
    x = math.fmod(degrees + 180.0, 360.0)
    if x <= 0.0:
        x += 360.0
    return x - 180.0


def decompose(d, size):
    """(orbit, pitch, radius) of an eye-space offset d from the rig centre,
    as the plan draws it (spec §4.3: d = r·size·(sin o cos p, sin p,
    cos o cos p)). Orbit is None at a pole."""
    length = norm(d)
    pitch = math.degrees(math.asin(max(-1.0, min(1.0, d[1] / length))))
    orbit = None
    if math.hypot(d[0], d[2]) > 1e-6 * length:
        orbit = wrap(math.degrees(math.atan2(d[0], d[2])))
    return orbit, pitch, length / size


class OrbitCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.fab(PEPTIDE, 'pep')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def rig(self, lights):
        lighting.set_lights({'enabled': True, 'centre': [1.0, -2.0, 3.0],
                             'size': SIZE, 'lights': lights})

    def turn(self):
        """A view that is not the identity, moved off the origin."""
        cmd.turn('y', 50)
        cmd.turn('x', 30)
        cmd.move('z', -20)
        cmd.move('x', 3)

    def assertClose(self, got, want, rel=REL, msg=None):
        self.assertAlmostEqual(got, want, delta=rel * max(1.0, abs(want)),
                               msg='%r != %r %s' % (got, want, msg or ''))

    def assertAngle(self, got, want, msg=None):
        self.assertLessEqual(abs(wrap(got - want)), ANGLE_TOL,
                             '%r != %r %s' % (got, want, msg or ''))


class TestPlanGrid(OrbitCase):

    def testOrbitGridReadsBackExactly(self):
        """Every orbit on the 15-degree grid is held exactly; -180 reads back
        as 180, as LightSnap wraps it."""
        self.rig([{'name': 'key'}])
        for orbit in ORBIT_GRID + [-180.0]:
            with self.subTest(orbit):
                lighting._light_set(0, 'orbit', orbit)
                self.assertEqual(lighting._light_get(0, 'orbit'),
                                 180.0 if orbit == -180.0 else orbit)
        self.assertEqual(len(ORBIT_GRID), 24)
        self.assertEqual((min(ORBIT_GRID), max(ORBIT_GRID)), (-165.0, 180.0))

    def testRadiusGridReadsBackExactly(self):
        """Every radius on the 0.5x grid is held exactly; both ends of the
        core's range lie on the grid."""
        self.rig([{'name': 'key'}])
        for radius in RADIUS_GRID:
            with self.subTest(radius):
                lighting._light_set(0, 'radius', radius)
                self.assertEqual(lighting._light_get(0, 'radius'), radius)
        table = {name: (low, high)
                 for scope, name, _kind, _default, low, high
                 in lighting._light_fields() if scope == 'light'}
        self.assertEqual((RADIUS_GRID[0], RADIUS_GRID[-1]), table['radius'])

    def testOrbitAtAPoleLeavesTheLightWhereItIs(self):
        """At pitch +-90 a lamp drag moves the lamp on the plan but not the
        light: the direction has no orbit (risk 4, documented). Camera and
        pinned lights alike."""
        for pitch in (90.0, -90.0):
            for pinned in (False, True):
                label = 'pitch %r pinned %r' % (pitch, pinned)
                with self.subTest(label):
                    cmd.reset()
                    self.rig([{'name': 'key', 'orbit': 30.0, 'pitch': pitch,
                               'radius': 3.0}])
                    if pinned:
                        lighting._light_set(0, 'anchor', 1)
                    before = lighting._lights_eye()['lights'][0]['position']
                    lighting._light_set(0, 'orbit', -105.0)
                    after = lighting._lights_eye()['lights'][0]['position']
                    for g, w in zip(after, before):
                        self.assertAlmostEqual(g, w, delta=1e-4 * SIZE, msg=label)


class TestPlanMatchesTheRender(OrbitCase):

    def assertPlan(self, packed, eye, light, label):
        """The packed position is the resolver's, and its offset from the
        eye-space centre is the plan's orbit, pitch and radius."""
        position = packed['position']
        for g, w in zip(position, light['position']):
            self.assertClose(g, w, msg=label)
        orbit, pitch, radius = decompose(sub(position, eye['centre']), eye['size'])
        self.assertClose(radius, light['radius'], msg=label)
        self.assertAngle(pitch, light['pitch'], msg=label)
        if abs(light['pitch']) < 90.0 - 1e-6:
            self.assertAngle(orbit, light['orbit'], msg=label)
            # The plan's lamp direction: normalize(d.x, d.z) = (sin o, cos o).
            d = sub(position, eye['centre'])
            n = math.hypot(d[0], d[2])
            o = math.radians(light['orbit'])
            self.assertAlmostEqual(d[0] / n, math.sin(o), delta=1e-4, msg=label)
            self.assertAlmostEqual(d[2] / n, math.cos(o), delta=1e-4, msg=label)

    def testCameraLightGrid(self):
        """Orbit on the 15-degree grid x pitch {-60, 0, 35} x radius
        {0.5, 2.5, 8}, under a turned camera."""
        self.turn()
        self.rig([{'name': 'key'}])
        for orbit in ORBIT_GRID:
            for pitch in (-60.0, 0.0, 35.0):
                for radius in (0.5, 2.5, 8.0):
                    label = 'orbit %r pitch %r radius %r' % (orbit, pitch, radius)
                    lighting._light_set(0, 'orbit', orbit)
                    lighting._light_set(0, 'pitch', pitch)
                    lighting._light_set(0, 'radius', radius)
                    eye = lighting._lights_eye()
                    frame = lighting._light_frame()
                    self.assertIsNotNone(frame['rig'], label)
                    light = eye['lights'][0]
                    self.assertEqual((light['orbit'], light['pitch'], light['radius']),
                                     (orbit, pitch, radius), label)
                    self.assertPlan(frame['rig']['lights'][0], eye, light, label)

    def testPinnedLightAfterACameraTurn(self):
        """A pinned light: after another camera turn, the eye orbit, pitch
        and radius the resolver reports (what the plan draws) are the
        decomposition of the position the renderer reads."""
        self.turn()
        self.rig([{'name': 'key', 'orbit': -45.0, 'pitch': 35.0, 'radius': 3.0},
                  {'name': 'rim', 'orbit': 30.0, 'pitch': 20.0, 'radius': 3.0}])
        lighting._light_set(1, 'anchor', 1)
        before = lighting._lights_eye()['lights'][1]
        cmd.turn('y', 40)
        eye = lighting._lights_eye()
        frame = lighting._light_frame()
        rim = eye['lights'][1]
        self.assertEqual(rim['anchor'], 'pinned')
        self.assertGreater(abs(wrap(rim['orbit'] - before['orbit'])), 10.0,
                           'the pinned lamp moved round the plan')
        self.assertTrue(0.5 <= rim['radius'] <= 8.0)
        self.assertPlan(frame['rig']['lights'][1], eye, rim, 'pinned')
        # The camera light stays put on the plan.
        key = eye['lights'][0]
        self.assertEqual((key['orbit'], key['pitch'], key['radius']), (-45.0, 35.0, 3.0))
        self.assertPlan(frame['rig']['lights'][0], eye, key, 'camera')


# --- the Swift sources ----------------------------------------------------------

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SHARED = os.path.join('swiftui', 'PyMOLViewer', 'Shared')
EDITING = os.path.join(SHARED, 'LightsEditing.swift')
INSPECTOR = os.path.join(SHARED, 'LightsInspector.swift')
CONTROLLER = os.path.join(SHARED, 'LightsController.swift')
MODEL = os.path.join(SHARED, 'LightsOrbitModel.swift')
VIEW = os.path.join(SHARED, 'LightsOrbitView.swift')
SIDE_COLUMN = os.path.join(SHARED, 'LightsSideColumn.swift')
CONTENT_VIEW = os.path.join(SHARED, 'ContentView.swift')

# What the orbit model must not name: it writes only through the controller's
# owner-guarded set, and never drives the mirror or the eye reads itself.
FORBIDDEN = ('seams', '.edit(', 'writeNumbers(', 'perform(', 'eyeDemand',
             'refresh(', 'frameRendered(')


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


def call_arguments(text, start):
    """The text between the parenthesis that opens at `start` and its
    balanced close."""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return None


class TestOrbitSource(testing.PyMOLTestCase):

    def read(self, rel):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source check that cannot find its source
            # has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            return strip_comments(handle.read())

    def testSnapGridsFitTheCore(self):
        """LightSnap snaps orbit every 15 degrees and radius every 0.5x
        (spec §9); both grids hold the core's range ends, so a snapped value
        is one the core keeps exactly."""
        snap = body(self.read(EDITING), 'enum LightSnap')
        self.assertIsNotNone(snap, 'enum LightSnap not found')
        steps = dict(re.findall(r'static let (orbitStep|radiusStep)\s*=\s*([0-9.]+)', snap))
        self.assertEqual(float(steps.get('orbitStep', 'nan')), ORBIT_STEP)
        self.assertEqual(float(steps.get('radiusStep', 'nan')), RADIUS_STEP)
        self.assertIn('LightsController.eyeDriftTolerance', snap)
        # Only LightParameter.range has range lines (lighting_inspector.py
        # parses them there).
        self.assertIsNone(re.search(r'case\s+\.\w+\s*:\s*return\s+-?[0-9.]+\s*\.\.\.', snap))
        table = {name: (low, high)
                 for scope, name, _kind, _default, low, high
                 in lighting._light_fields() if scope == 'light'}
        for name, step in (('orbit', ORBIT_STEP), ('radius', RADIUS_STEP)):
            low, high = table[name]
            with self.subTest(name):
                self.assertEqual(math.fmod(low, step), 0.0)
                self.assertEqual(math.fmod(high, step), 0.0)

    def testOwnerGuardComesAfterTheStaleReread(self):
        """set(_:_:owner:) goes through the one owner guard, ownsGesture
        (#622 moved it there unchanged), which re-reads a stale mirror
        before it compares the selected name, so a light removed behind the
        mirror is caught."""
        text = self.read(EDITING)
        guarded = body(text, 'func set(_ parameter: LightParameter, _ value: Double, owner:')
        self.assertIsNotNone(guarded, 'set(_:_:owner:) not found')
        self.assertIn('ownsGesture(owner)', guarded)
        guard = body(text, 'func ownsGesture(_ owner: String) -> Bool')
        self.assertIsNotNone(guard, 'ownsGesture(_:) not found')
        reread = guard.find('refreshIfStale()')
        check = guard.find('selection.name')
        self.assertGreaterEqual(reread, 0)
        self.assertGreater(check, reread)
        begin = body(self.read(CONTROLLER), 'func beginGesture()')
        self.assertIsNotNone(begin, 'beginGesture() not found')
        self.assertIn('canEdit', begin)
        self.assertIn('gestureGeneration', begin)

    def testTheModelWritesOnlyThroughTheOwnerGuard(self):
        """LightsOrbitModel.swift names no seam, no unguarded write path and
        nothing that drives the mirror or the eye reads; every controller.set
        call passes its owner."""
        text = self.read(MODEL)
        for name in FORBIDDEN:
            with self.subTest(name):
                self.assertNotIn(name, text)
        calls = [m.end() - 1 for m in re.finditer(r'controller\.set\(', text)]
        self.assertGreater(len(calls), 0, 'the model writes through controller.set')
        for start in calls:
            arguments = call_arguments(text, start)
            self.assertIsNotNone(arguments)
            self.assertIn('owner:', arguments, 'controller.set(%s)' % arguments)
        self.assertNotIn('controller.step(', text)
        self.assertNotIn('controller.setPlacement(', text)

    def testTheInspectorFieldsDropTypingOnAGesture(self):
        """The Orbit and Pitch field rows observe gestureGeneration and call
        LightFieldEditor.gestureBegan, so a drag on the plan is never
        overwritten by text typed before it."""
        text = self.read(INSPECTOR)
        row = body(text, 'struct LightAngleFieldRow')
        self.assertIsNotNone(row, 'LightAngleFieldRow not found')
        self.assertRegex(row, r'onChange\(of:\s*gestureGeneration\)')
        self.assertIn('gestureBegan(', row)
        rows = body(text, 'struct LightPlacementRows')
        self.assertIsNotNone(rows, 'LightPlacementRows not found')
        self.assertEqual(rows.count('gestureGeneration: controller.gestureGeneration'), 2)

    def testTheCardSitsAboveTheInspector(self):
        """LightsSideColumn builds the orbit card before (above) the
        inspector, with its collapse seed."""
        column = body(self.read(SIDE_COLUMN), 'var body: some View')
        self.assertIsNotNone(column, 'LightsSideColumn.body not found')
        orbit = column.find('LightsOrbitView(')
        inspector = column.find('LightsInspector(')
        self.assertGreaterEqual(orbit, 0, 'the column builds no LightsOrbitView')
        self.assertGreater(inspector, orbit, 'the orbit card must come above the inspector')
        self.assertIn('initiallyCollapsed: orbitStartsCollapsed', column)

    def testTheViewWritesOnlyThroughTheInteraction(self):
        """LightsOrbitView.swift names no seam, write path or mirror driver,
        and no controller setter: every edit goes through
        LightsOrbitInteraction (the owner-guarded shared path). It draws only
        with its state, and its canvases (not the card) observe the eye."""
        text = self.read(VIEW)
        for name in FORBIDDEN + ('controller.set(', 'controller.step(', 'controller.setPlacement(',
                                 'controller.select(', 'beginGesture('):
            with self.subTest(name):
                self.assertNotIn(name, text)
        self.assertIn('LightsOrbitInteraction(controller: controller)', text)
        card = body(text, 'struct LightsOrbitView: View')
        self.assertIsNotNone(card, 'LightsOrbitView not found')
        self.assertRegex(body(card, 'var body: some View') or '',
                         r'if\s+let\s+state\s*=\s*LightsOrbitState\(controller\b')
        self.assertNotRegex(card, r'@ObservedObject\s+var\s+eye\b',
                            'the card itself must not observe the eye')
        canvases = body(text, 'struct OrbitCanvases: View')
        self.assertIsNotNone(canvases, 'OrbitCanvases not found')
        self.assertRegex(canvases, r'@ObservedObject\s+var\s+eye:\s*LightsEyeState')
        summary = body(text, 'struct OrbitCollapsedSummary: View')
        self.assertIsNotNone(summary, 'OrbitCollapsedSummary not found')
        self.assertRegex(summary, r'@ObservedObject\s+var\s+eye:\s*LightsEyeState')

    def testThePlanPinchesBesideItsDrag(self):
        """The plan's pinch is a simultaneous MagnifyGesture beside its
        DragGesture (the gesture wiring is otherwise checked by eye)."""
        canvases = body(self.read(VIEW), 'struct OrbitCanvases: View')
        self.assertIsNotNone(canvases, 'OrbitCanvases not found')
        found = re.search(r'\.simultaneousGesture\(\s*MagnifyGesture\(\)', canvases)
        self.assertIsNotNone(found, 'the plan has no simultaneous MagnifyGesture')
        self.assertEqual(len(re.findall(r'DragGesture\(minimumDistance:\s*0', canvases)), 2,
                         'one drag on the plan, one on the arc')
        self.assertIn('accessibilityAdjustableAction', canvases)

    def testACancelledGestureLeavesNothingBehind(self):
        """SwiftUI calls no onEnded for a cancelled gesture, so the drags
        tell a new press by its start (OrbitTouchSequence) and the pinch
        ends on its @GestureState reset, never only in onEnded."""
        canvases = body(self.read(VIEW), 'struct OrbitCanvases: View')
        self.assertIsNotNone(canvases, 'OrbitCanvases not found')
        self.assertEqual(len(re.findall(r'\.isNewPress\(startingAt:\s*drag\.startLocation\)',
                                        canvases)), 2,
                         'the plan and the arc each tell a new press by its start')
        self.assertNotRegex(canvases, r'\b(planPressed|arcPressed)\b')
        self.assertRegex(canvases, r'@GestureState\s+private\s+var\s+pinching\b')
        self.assertRegex(canvases, r'MagnifyGesture\(\)\s*\.updating\(\$pinching\)')
        self.assertRegex(canvases, r'\.onChange\(of:\s*pinching\)[^}]*pinchEnded\(\)')

    def testTheCardStartsCollapsedOnEveryIPhone(self):
        """ContentView seeds the orbit card collapsed on compact width or
        compact height (every iPhone, both orientations), never on macOS,
        and passes the seed to the column."""
        content = self.read(CONTENT_VIEW)
        seed = body(content, 'private var lightsOrbitStartsCollapsed')
        self.assertIsNotNone(seed, 'lightsOrbitStartsCollapsed not found')
        ios, _, mac = seed.partition('#else')
        self.assertIn('hSize == .compact', ios)
        self.assertIn('vSize == .compact', ios)
        self.assertIn('!lightsInspectorExpandOverride', ios)
        self.assertIn('return false', mac)
        site = body(content, 'private var lightsSideColumn')
        self.assertIsNotNone(site, 'lightsSideColumn not found')
        self.assertIn('orbitStartsCollapsed: lightsOrbitStartsCollapsed', site)

    def testTheIPadColumnClearsTheHelpButton(self):
        """On iPad the column (orbit card above the inspector) reaches the
        viewport's bottom, so the iOS overlay stops it above the
        bottom-trailing Gesture help button (a 26 pt glyph with 12 pt
        padding); on iPhone and macOS the inset is 0."""
        content = self.read(CONTENT_VIEW)
        inset = body(content, 'private var lightsSideColumnBottomInset')
        self.assertIsNotNone(inset, 'lightsSideColumnBottomInset not found')
        ios, _, mac = inset.partition('#else')
        self.assertIn('hSize == .compact || vSize == .compact', ios)
        self.assertIn('? 0 : LightsSideColumn.helpButtonClearance', ios)
        self.assertIn('return 0', mac)
        self.assertRegex(content, r'lightsSideColumn\.padding\(8\)\s*'
                                  r'\.padding\(\.bottom,\s*lightsSideColumnBottomInset\)')
        column = self.read(SIDE_COLUMN)
        clearance = re.search(r'static let helpButtonClearance:\s*CGFloat\s*=\s*([0-9.]+)', column)
        self.assertIsNotNone(clearance, 'helpButtonClearance not found')
        help_button = re.search(r'questionmark\.circle\.fill"\)\s*'
                                r'\.font\(\.system\(size:\s*([0-9.]+)\)\)\s*'
                                r'\.foregroundStyle\([^\n]*\)\s*\.padding\(([0-9.]+)\)', content)
        self.assertIsNotNone(help_button, 'the Gesture help button was not found')
        glyph, padding = float(help_button.group(1)), float(help_button.group(2))
        self.assertGreaterEqual(8 + float(clearance.group(1)), glyph + 2 * padding)

    def testBothLogLinesCarryThePlan(self):
        """Both PYMOL_AUTOLIGHTS log lines carry plan=<LightsOrbitState
        summary> beside inspector=, and LightsAutoEdit hands the gesture
        tokens to OrbitAutoGesture."""
        hook = body(self.read(CONTENT_VIEW), 'private func autoEnterLightsModeFromEnv()')
        self.assertIsNotNone(hook, 'autoEnterLightsModeFromEnv not found')
        lines = re.findall(r'NSLog\("PYMOL_AUTOLIGHTS(?:_EDIT)?:[^\n]*', hook)
        self.assertEqual(len(lines), 2)
        for line in lines:
            with self.subTest(line[:30]):
                self.assertIn('inspector=', line)
                self.assertIn(' plan=\\(plan)', line)
        self.assertEqual(len(re.findall(r'LightsOrbitState\(lights\)\?\.summary', hook)), 2)
        edit = body(self.read(INSPECTOR), 'enum LightsAutoEdit')
        self.assertIsNotNone(edit, 'LightsAutoEdit not found')
        self.assertIn('OrbitAutoGesture.claims(', edit)
        self.assertIn('OrbitAutoGesture.apply(', edit)
