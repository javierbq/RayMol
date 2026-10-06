"""The selected-light inspector: the Python half (#620).

The inspector (swiftui/PyMOLViewer/Shared/LightsInspector.swift) edits the
selected light through the bridge setters, without Python. One button runs
Python: *Revert this light*, which calls
pymol.appkit_lights.restore_light(b64(json), name) with the JSON the app read
through PyMOLBridge_LightsJSON (the same C++ as lighting._lights_json) when
the mode was entered. It must put back only that light, as it was, at the
index it has now, and leave the rig alone (one printed line) whenever it
cannot.

Matching is by name, ignoring case: a light named since entry ('spot') has
nothing to go back to, and a default name that was removed and added again
('fill', which `lights add` reuses) counts as the entry light.

CI builds the GLUT flavour without a GPU, so this exercises _cmd and Python
only. A small peptide (cmd.fab) gives the rig a real frame.

The inspector's Swift sources are checked too (comments stripped; skipped
outside a checkout): LightParameter's ranges are the core's field table, the
per-frame hook (MetalViewport.draw(in:) -> lightsFrameRendered) runs only in
Lights mode and only reads through the bridge, the inspector's shadow cap is
lighting_commands.MAX_SHADOWS, and its Shadows hint reads the setting the
scene poll reports (#616: studio shadows show only while metal_shadows is on).

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_inspector.py
"""
import base64
import contextlib
import io
import json
import os
import re

import pymol
import pymol.invocation
from pymol import appkit_inspector, appkit_lights, cmd, lighting, lighting_commands, testing

# The peptide that gives the rig its frame.
PEPTIDE = 'ACDEFG'

# Quote, double quote, backslash and non-ASCII text in an aim_selection: the
# bridge JSON escapes them, and Revert this light must put them back.
AWKWARD_SELECTION = 'resn "ALA" and name \'CA\' \\ x é'

# Air away from every default.
AIR = {'haze': 0.1, 'dust': 0.3, 'scatter': -0.25, 'seed': 7}

FAILED = ' lights: revert failed: '


def b64(text):
    """What the app sends: base64 of the UTF-8 text
    (Data(text.utf8).base64EncodedString() in Swift)."""
    return base64.b64encode(text.encode('utf-8')).decode('ascii')


def output(func, *args, **kwargs):
    """Run func, return (result, what it printed from Python)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args, **kwargs)
    return result, buf.getvalue()


def do(line):
    """cmd.do(line), the app's command path; returns the printed text.
    The runner's -y (exit on error) would quit on the errors some commands
    print, so it is off for the call."""
    options = pymol.invocation.options
    exit_on_error = options.exit_on_error
    options.exit_on_error = 0
    try:
        return output(cmd.do, line)[1]
    finally:
        options.exit_on_error = exit_on_error


def three_light_rig():
    """Three lights: key (camera, shadowed), fill aimed at a world point with
    an awkward aim_selection, rim pinned at a world point; the air away from
    its defaults. No centre/size: set_lights captures the frame."""
    return {
        'version': 1,
        'enabled': True,
        'ambient': 0.12,
        'classic': 0.25,
        'air': dict(AIR),
        'lights': [
            {'name': 'key', 'orbit': -45.0, 'pitch': 35.0, 'shadow': True,
             'warmth': 4500.0},
            {'name': 'fill', 'orbit': 55.0, 'pitch': 5.0, 'aim': 'point',
             'aim_point': [1.5, -2.25, 3.125],
             'aim_selection': AWKWARD_SELECTION, 'intensity': 0.35},
            {'name': 'rim', 'anchor': 'pinned',
             'position': [-11.1, 22.2, -33.3], 'beam': 40.0,
             'color': [0.0, 1.0, 1.0], 'intensity': 1.6},
        ],
    }


def light_named(rig, name):
    for light in rig['lights']:
        if light['name'] == name:
            return light
    raise AssertionError('no light %r in %r' % (
        name, [light['name'] for light in rig['lights']]))


class TestRestoreLight(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.fab(PEPTIDE, 'pep')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def names(self):
        return [light['name'] for light in lighting.get_lights()['lights']]

    def entry(self, rig=None):
        """Set the rig and return its bridge JSON, as the app reads it when
        the mode is entered."""
        lighting.set_lights(rig if rig is not None else three_light_rig())
        j0 = lighting._lights_json()
        self.assertIsInstance(j0, str)
        return j0

    def assertRestored(self, j0, name, printed_name=None):
        ok, text = output(appkit_lights.restore_light, b64(j0), name)
        self.assertIs(ok, True, text)
        self.assertEqual(text, ' lights: %s reverted\n'
                         % (printed_name or name.lower()))

    def assertRefused(self, payload, name):
        """restore_light refuses: False, one printed line with a reason, the
        rig (or no rig) byte for byte as it was."""
        before = lighting._lights_json()
        try:
            ok, text = output(appkit_lights.restore_light, payload, name)
        except Exception as exc:  # pragma: no cover - the test's failure
            self.fail('restore_light raised %r' % exc)
        self.assertIs(ok, False, text)
        self.assertEqual(lighting._lights_json(), before)
        lines = text.splitlines()
        self.assertEqual(len(lines), 1, text)
        self.assertTrue(lines[0].startswith(FAILED), text)
        self.assertGreater(len(lines[0]) - len(FAILED), 0, text)
        return lines[0][len(FAILED):]

    def testFixtureIsWhatItClaims(self):
        lighting.set_lights(three_light_rig())
        rig = lighting.get_lights()
        self.assertEqual(self.names(), ['key', 'fill', 'rim'])
        key, fill, rim = rig['lights']
        self.assertEqual((key['anchor'], key['shadow']), ('camera', True))
        self.assertEqual((fill['aim'], fill['aim_selection']),
                         ('point', AWKWARD_SELECTION))
        self.assertEqual(rim['anchor'], 'pinned')
        for field, value in AIR.items():
            self.assertEqual(rig['air'][field], value, field)
        self.assertIsNotNone(rig['centre'])

    def testRestoreLightPutsBackOnlyThatLight(self):
        j0 = self.entry()
        entry = json.loads(j0)

        # edit key every way the inspector can (and pin it), fill and the
        # rig itself, then turn the rig off from the bar
        lighting._light_set(0, 'orbit', 120.0)
        lighting._light_set(0, 'color', [1.0, 0.0, 1.0])
        lighting._light_set(0, 'warmth', 3800.0)
        lighting._light_set(0, 'beam', 22.5)
        lighting._light_set(0, 'anchor', 1)
        lighting._light_set(1, 'intensity', 1.25)
        lighting._light_set(-1, 'ambient', 0.3)
        do('lights off')
        edited = lighting.get_lights()
        self.assertNotEqual(light_named(edited, 'key'), entry['lights'][0])

        self.assertRestored(j0, 'key')

        now = json.loads(lighting._lights_json())
        # key is the entry key exactly, at the same index
        self.assertEqual(self.names(), ['key', 'fill', 'rim'])
        self.assertEqual(now['lights'][0], entry['lights'][0])
        # everything else is as it was just before the revert
        want = json.loads(j0)
        want['lights'][1]['intensity'] = light_named(edited, 'fill')['intensity']
        want['ambient'] = edited['ambient']
        want['enabled'] = False
        self.assertEqual(now, want)
        self.assertEqual(now['lights'][1]['intensity'], 1.25)
        self.assertEqual(now['ambient'], 0.3)
        self.assertEqual((now['centre'], now['size']),
                         (entry['centre'], entry['size']))
        # the rest of the rig went through get_lights/set_lights unchanged
        self.assertEqual(now['lights'][1:], json.loads(
            json.dumps(edited['lights'][1:])))

    def testRestoreLightKeepsTheCurrentIndex(self):
        """A light that moved in the list (others removed and added) comes
        back where it is now, not where it was."""
        j0 = self.entry()
        do('lights remove, key')
        do('lights add, spot')
        self.assertEqual(self.names(), ['fill', 'rim', 'spot'])
        lighting._light_set(1, 'intensity', 3.0)
        self.assertRestored(j0, 'rim')
        self.assertEqual(self.names(), ['fill', 'rim', 'spot'])
        self.assertEqual(json.loads(lighting._lights_json())['lights'][1],
                         json.loads(j0)['lights'][2])

    def testRestoreLightRestoresPinAndAim(self):
        rig = three_light_rig()
        rig['lights'][0].update({
            'anchor': 'pinned', 'position': [8.5, -4.25, 12.0],
            'aim': 'point', 'aim_point': [0.5, 1.0, -1.5],
            'aim_selection': AWKWARD_SELECTION, 'shadow': False})
        j0 = self.entry(rig)
        entry_key = json.loads(j0)['lights'][0]
        self.assertEqual((entry_key['anchor'], entry_key['aim']),
                         ('pinned', 'point'))

        # unpin it and aim it back at the centre (which clears the text)
        lighting._light_set(0, 'anchor', 0)
        lighting._light_set(0, 'aim', 0)
        key = lighting.get_lights()['lights'][0]
        self.assertEqual((key['anchor'], key['aim'], key['aim_selection']),
                         ('camera', 'centre', ''))

        self.assertRestored(j0, 'key')
        key = json.loads(lighting._lights_json())['lights'][0]
        for field in ('anchor', 'position', 'aim', 'aim_point',
                      'aim_selection', 'orbit', 'pitch', 'radius'):
            self.assertEqual(key[field], entry_key[field], field)
        self.assertEqual(key, entry_key)

    def testRestoreLightMatchesNamesIgnoringCase(self):
        j0 = self.entry()
        lighting._light_set(0, 'intensity', 3.5)
        lighting._light_set(1, 'orbit', -10.0)
        self.assertRestored(j0, 'KEY')
        self.assertRestored(j0, 'Fill')
        self.assertEqual(lighting._lights_json(), j0)

    def testRestoreLightRefusals(self):
        j0 = self.entry()
        lighting._light_set(0, 'orbit', 12.5)

        # a light named since entry has nothing to go back to
        do('lights add, spot')
        self.assertEqual(self.names(), ['key', 'fill', 'rim', 'spot'])
        reason = self.assertRefused(b64(j0), 'spot')
        self.assertIn('spot', reason)

        # a light removed since entry
        do('lights remove, fill')
        reason = self.assertRefused(b64(j0), 'fill')
        self.assertIn('fill', reason)

        # bad payloads and names
        for label, payload, name in (
                ('entry with no rig', b64('null'), 'key'),
                ('not base64', 'this is not base64!', 'key'),
                ('not UTF-8', base64.b64encode(b'\xff\xfe').decode(), 'key'),
                ('not JSON', b64('{'), 'key'),
                ('a JSON list', b64('[1, 2]'), 'key'),
                ('an object without lights', b64('{"version": 1}'), 'key'),
                ('no name', b64(j0), ''),
                ('a name that is not text', b64(j0), None),
                ('a payload that is not text', None, 'key')):
            with self.subTest(label):
                self.assertRefused(payload, name)

        # no rig now: still no rig afterwards
        lighting.set_lights(None)
        reason = self.assertRefused(b64(j0), 'key')
        self.assertIn('no rig', reason)
        self.assertIsNone(lighting.get_lights())

    def testRestoreLightReusedDefaultName(self):
        """`lights add` reuses the first free default name, so a removed and
        re-added fill counts as the entry fill (the documented rule)."""
        j0 = self.entry()
        entry_fill = json.loads(j0)['lights'][1]
        do('lights remove, fill')
        do('lights add')
        self.assertEqual(self.names(), ['key', 'rim', 'fill'])
        self.assertNotEqual(lighting.get_lights()['lights'][2]['aim'], 'point')
        self.assertRestored(j0, 'fill')
        now = json.loads(lighting._lights_json())
        self.assertEqual(self.names(), ['key', 'rim', 'fill'])
        self.assertEqual(now['lights'][2], entry_fill)

    def testRestoreLightShadowCap(self):
        """Putting back a shadowed light when three others now cast shadows
        would make a 4th: set_lights refuses it and nothing changes."""
        j0 = self.entry()
        self.assertTrue(json.loads(j0)['lights'][0]['shadow'])
        lighting._light_set(0, 'shadow', 0)
        do('lights add')
        self.assertEqual(self.names(), ['key', 'fill', 'rim', 'light4'])
        for index in (1, 2, 3):
            lighting._light_set(index, 'shadow', 1)
        self.assertEqual([light['shadow'] for light in
                          lighting.get_lights()['lights']],
                         [False, True, True, True])
        reason = self.assertRefused(b64(j0), 'key')
        self.assertIn('shadow', reason)
        self.assertFalse(lighting.get_lights()['lights'][0]['shadow'])


# --- the Swift sources ----------------------------------------------------------

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SHARED = os.path.join('swiftui', 'PyMOLViewer', 'Shared')
EDITING = os.path.join(SHARED, 'LightsEditing.swift')
VIEWPORT = os.path.join(SHARED, 'MetalViewport.swift')
ENGINE = os.path.join(SHARED, 'PyMOLEngine.swift')
APP = os.path.join('swiftui', 'PyMOLViewer')
CONTENT_VIEW = os.path.join(SHARED, 'ContentView.swift')
SIDE_COLUMN = os.path.join(SHARED, 'LightsSideColumn.swift')
INSPECTOR = os.path.join(SHARED, 'LightsInspector.swift')
CONTROLLER = os.path.join(SHARED, 'LightsController.swift')

# `case .x: return a...b` (a range line of LightParameter.range).
RANGE_CASE = re.compile(
    r'case\s+\.(\w+)\s*:\s*return\s+(-?[0-9.]+)\s*\.\.\.\s*(-?[0-9.]+)')


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


class TestInspectorSource(testing.PyMOLTestCase):

    def read(self, rel):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source check that cannot find its source
            # has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            return strip_comments(handle.read())

    def parameters(self):
        """(cases in declaration order, {case: (min, max)}, {wrapping cases})
        parsed from LightParameter."""
        text = self.read(EDITING)
        enum = body(text, 'enum LightParameter')
        self.assertIsNotNone(enum, 'enum LightParameter not found')
        declared = re.search(r'\bcase\s+(\w+(?:\s*,\s*\w+)*)\s*\n', enum)
        self.assertIsNotNone(declared, 'LightParameter has no case list')
        cases = [name.strip() for name in declared.group(1).split(',')]
        ranges_body = body(enum, 'var range:')
        self.assertIsNotNone(ranges_body, 'LightParameter.range not found')
        ranges = {}
        for name, low, high in RANGE_CASE.findall(ranges_body):
            self.assertNotIn(name, ranges, 'case .%s listed twice' % name)
            ranges[name] = (float(low), float(high))
        wraps_body = body(enum, 'var wraps:')
        self.assertIsNotNone(wraps_body, 'LightParameter.wraps not found')
        wraps = set(re.findall(r'case\s+\.(\w+)\s*:\s*return\s+true', wraps_body))
        return cases, ranges, wraps

    def testParametersMatchTheCoreTable(self):
        """Every LightParameter is a light field of kind float or angle in the
        core's table, with the core's min and max; it wraps exactly when the
        core's kind is angle; every case has a range line."""
        cases, ranges, wraps = self.parameters()
        self.assertEqual(
            cases,
            ['orbit', 'pitch', 'radius', 'intensity', 'warmth', 'beam', 'softness'])
        self.assertEqual(sorted(ranges), sorted(cases),
                         'every case needs exactly one `case .x: return a...b` line')
        table = {name: (kind, low, high)
                 for scope, name, kind, _default, low, high
                 in lighting._light_fields() if scope == 'light'}
        for name in cases:
            with self.subTest(name):
                self.assertIn(name, table, '%s is not a light field' % name)
                kind, low, high = table[name]
                self.assertIn(kind, ('float', 'angle'))
                self.assertEqual(ranges[name], (low, high))
                self.assertEqual(name in wraps, kind == 'angle')

    def testTheRangePatternReadsEachForm(self):
        """The pattern reads the forms a range line can take."""
        for line, expected in (('case .orbit: return -180...180', ('orbit', '-180', '180')),
                               ('case .radius:  return 0.5 ... 8', ('radius', '0.5', '8')),
                               ('case .warmth: return 1500...15000',
                                ('warmth', '1500', '15000'))):
            self.assertEqual(RANGE_CASE.search(line).groups(), expected, line)

    def testFrameHookIsLightsOnly(self):
        """draw(in:) calls lightsFrameRendered() exactly once, inside an
        `if engine.interactionMode == .lights` block on the render path
        (after the frame's heavyRenderTick); the engine's lightsFrameRendered
        returns first thing outside Lights mode and runs no Python or command;
        nothing else in the app calls it."""
        viewport = self.read(VIEWPORT)
        draw = body(viewport, 'func draw(in view: MTKView)')
        self.assertIsNotNone(draw, 'MetalViewport.draw(in:) not found')
        self.assertEqual(draw.count('lightsFrameRendered('), 1,
                         'draw(in:) must call the hook exactly once')
        gate = body(draw, 'if engine.interactionMode == .lights')
        self.assertIsNotNone(gate, 'draw(in:) has no Lights-mode block')
        self.assertIn('engine.lightsFrameRendered()', gate,
                      'the hook must be inside the Lights-mode block')
        rendered = draw.find('engine.heavyRenderTick(presented: presented)')
        self.assertGreaterEqual(rendered, 0, 'the render path\'s heavyRenderTick moved')
        self.assertGreater(draw.find('lightsFrameRendered('), rendered,
                           'the hook belongs on the render path, after the frame')

        engine = self.read(ENGINE)
        hook = body(engine, 'func lightsFrameRendered()')
        self.assertIsNotNone(hook, 'PyMOLEngine.lightsFrameRendered not found')
        self.assertRegex(hook, r'^\{\s*guard\s+interactionMode\s*==\s*\.lights\s+else\s*'
                               r'\{\s*return\s*\}',
                         'lightsFrameRendered must return first thing outside Lights mode')
        self.assertIn('lightsController.frameRendered()', hook)
        for name in ('runPython', 'runCommand', 'PyMOLBridge_RunPython'):
            self.assertNotIn(name, hook, 'the frame hook must run no Python or command')

        callers = []
        for folder, _dirs, files in os.walk(os.path.join(ROOT, APP)):
            for filename in files:
                if not filename.endswith('.swift'):
                    continue
                rel = os.path.relpath(os.path.join(folder, filename), ROOT)
                text = self.read(rel)
                calls = len(re.findall(r'\blightsFrameRendered\(\)', text))
                calls -= len(re.findall(r'func\s+lightsFrameRendered\(\)', text))
                if calls:
                    callers.append((os.path.basename(rel), calls))
        self.assertEqual(callers, [('MetalViewport.swift', 1)],
                         'only draw(in:) may call the frame hook')

    def testEyeSpaceSeamIsTheBridgeRead(self):
        """The engine wires the controller's eyeSpace seam to the C++ read
        lightsEyeSpace() (no Python)."""
        engine = self.read(ENGINE)
        self.assertRegex(
            engine,
            r'eyeSpace:\s*\{\s*\[weak self\]\s*in\s*self\?\.lightsEyeSpace\(\)\s*\}',
            'LightsSeams.eyeSpace must be wired to lightsEyeSpace()')

    def testInspectorPlacedOnBothPlatforms(self):
        """The Lights side column (and so the inspector) is placed on both
        platforms: on macOS macLightsOverlay shows the bar and the column and
        is the Lights branch of the viewport's top overlay chain; on iOS
        viewportView shows the column in Lights mode only (one site for the
        four layouts); the column holds the inspector."""
        content = self.read(CONTENT_VIEW)
        mac = body(content, 'private var macLightsOverlay')
        self.assertIsNotNone(mac, 'macLightsOverlay not found')
        self.assertIn('lightsBar', mac)
        self.assertIn('lightsSideColumn', mac)
        chain = body(content, 'private var macViewport: some View')
        self.assertIsNotNone(chain, 'macViewport not found')
        self.assertRegex(chain, r'interactionMode\s*==\s*\.lights\s*\{\s*macLightsOverlay\s*\}')
        ios = body(content, 'private var viewportView')
        self.assertIsNotNone(ios, 'viewportView not found')
        self.assertRegex(
            ios,
            r'if\s+engine\.interactionMode\s*==\s*\.lights[^{]*\{\s*lightsSideColumn\b',
            'viewportView must show lightsSideColumn in Lights mode only')
        column_site = body(content, 'private var lightsSideColumn')
        self.assertIsNotNone(column_site, 'lightsSideColumn not found')
        self.assertIn('LightsSideColumn(', column_site)
        column = self.read(SIDE_COLUMN)
        self.assertIn('LightsInspector(', column)

    def testInspectorDrawsOnlyWithItsState(self):
        """The card draws only when LightsInspectorState(controller) exists
        (Lights mode active with a selected light): ContentView does not
        observe the nested controller, so the check lives in the view."""
        inspector = self.read(INSPECTOR)
        card = body(inspector, 'struct LightsInspector: View')
        self.assertIsNotNone(card, 'LightsInspector not found')
        view_body = body(card, 'var body: some View')
        self.assertIsNotNone(view_body, 'LightsInspector.body not found')
        self.assertRegex(view_body, r'if\s+let\s+state\s*=\s*LightsInspectorState\(controller\b')

    def testShadowCapMatches(self):
        """LightsController.maxShadowed (the inspector's refusal notice) is
        the `lights` command's MAX_SHADOWS, and the per-field setter the
        bridge calls (what setShadow writes through) refuses exactly the light
        after it, leaving the rig unchanged (setShadow gets .refused)."""
        found = re.search(r'static\s+let\s+maxShadowed\s*=\s*(\d+)\b', self.read(CONTROLLER))
        self.assertIsNotNone(found, 'LightsController.maxShadowed not found')
        self.assertEqual(int(found.group(1)), lighting_commands.MAX_SHADOWS)

        cmd.reinitialize()
        cmd.fab(PEPTIDE, 'pep')
        names = ['key', 'fill', 'rim', 'light4']
        self.assertGreater(len(names), lighting_commands.MAX_SHADOWS)
        lighting.set_lights({'enabled': True,
                             'lights': [{'name': n} for n in names]})
        for i in range(lighting_commands.MAX_SHADOWS):
            lighting._light_set(i, 'shadow', 1)
        before = lighting._lights_json()
        with self.assertRaisesRegex(pymol.CmdException, r'refused'):
            lighting._light_set(lighting_commands.MAX_SHADOWS, 'shadow', 1)
        self.assertEqual(lighting._lights_json(), before, 'a refusal changes nothing')
        cmd.reinitialize()

    def testShadowsHintReadsThePolledSetting(self):
        """The Shadows hint reads metal_shadows from the scene poll
        (appkit_inspector.SCENE_SETTINGS, polled in every mode), and Turn On
        sets that setting with one command."""
        self.assertIn('metal_shadows', appkit_inspector.SCENE_SETTINGS)
        engine = self.read(ENGINE)
        shadows_on = body(engine, 'var sceneShadowsOn: Bool?')
        self.assertIsNotNone(shadows_on, 'PyMOLEngine.sceneShadowsOn not found')
        self.assertIn('sceneState.values["metal_shadows"]', shadows_on)
        turn_on = body(engine, 'func enableSceneShadows()')
        self.assertIsNotNone(turn_on, 'PyMOLEngine.enableSceneShadows not found')
        self.assertIn('runCommand("set metal_shadows, 1")', turn_on)
        self.assertNotIn('runPython', turn_on)
        column_site = body(self.read(CONTENT_VIEW), 'private var lightsSideColumn')
        self.assertIsNotNone(column_site, 'lightsSideColumn not found')
        self.assertIn('sceneShadowsOn: engine.sceneShadowsOn', column_site)
        self.assertIn('engine.enableSceneShadows()', column_site)
        # The command the button runs is a valid one.
        cmd.reinitialize()
        cmd.do('set metal_shadows, 1')
        self.assertEqual(int(cmd.get_setting_int('metal_shadows')), 1)
        cmd.set('metal_shadows', 0)
