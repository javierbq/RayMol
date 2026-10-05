"""The app's Lights mode: the Python half (#619).

The Lights bar (swiftui/PyMOLViewer/Shared/LightsBar.swift and
LightsController.swift) runs the `lights` command of #612 for its buttons and
calls Python for two things only, both in pymol.appkit_lights:

* restore(b64(json)) for Revert: the JSON the app read through
  PyMOLBridge_LightsJSON (the same C++ as lighting._lights_json) when the mode
  was entered, or 'null' for "no rig". It must bring the rig back byte for
  byte, and leave it alone on a bad payload.
* write_presets(b64(path)) for the preset menu: [{"name", "description"}]
  in the order of lighting_commands.presets(), the format the Swift
  LightPreset decoder reads.

TestSwiftSource reads the Swift sources (skipped outside a checkout): the
Lights model never runs Python or a console command itself.

TestBarCommands runs the bar's exact command strings through cmd.do (the path
of the app's runCommand -> PyMOLBridge_RunCommand) and checks what the
controller expects of each. The same literals are pinned on the Swift side by
LightsActionInvocationTests (#619 part 3); change both together.

CI builds the GLUT flavour without a GPU, so this exercises _cmd and Python
only. A small peptide (cmd.fab) gives the rig a real frame.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_mode.py
"""
import base64
import contextlib
import copy
import io
import json
import os
import re
import shutil
import tempfile

import pymol
import pymol.invocation
from pymol import appkit_lights, cmd, lighting, lighting_commands, testing

# The peptide that gives the rig its frame.
PEPTIDE = 'ACDEFG'

# Quote, double quote, backslash and non-ASCII text in an aim_selection: the
# bridge JSON escapes them, and Revert must put them back unchanged.
AWKWARD_SELECTION = 'resn "ALA" and name \'CA\' \\ x é'

# Air away from every default.
AIR = {'haze': 0.1, 'dust': 0.3, 'scatter': -0.25, 'seed': 7}


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
    The runner's -y (exit on error) would quit on the errors some of these
    commands print, so it is off for the call."""
    options = pymol.invocation.options
    exit_on_error = options.exit_on_error
    options.exit_on_error = 0
    try:
        return output(cmd.do, line)[1]
    finally:
        options.exit_on_error = exit_on_error


def three_light_rig(enabled=True):
    """Three lights: key (camera), fill aimed at a world point with an
    awkward aim_selection, rim pinned at a world point; the air away from
    its defaults. No centre/size: set_lights captures the frame."""
    return {
        'version': 1,
        'enabled': enabled,
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


class ModeCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.fab(PEPTIDE, 'pep')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def names(self):
        rig = lighting.get_lights()
        return [light['name'] for light in rig['lights']] if rig else None


# --- restore (Revert) ---------------------------------------------------------

class TestRestore(ModeCase):

    def fixtures(self):
        """(label, a function that builds the rig) for every entry state."""
        def full(enabled):
            def build():
                lighting.set_lights(three_light_rig(enabled))
            return build

        def cleared():
            lighting.set_lights(three_light_rig())
            cmd.lights('clear')

        def preset():
            cmd.lights('three_point')

        return [('three lights, on', full(True)),
                ('three lights, off', full(False)),
                ('empty rig after lights clear', cleared),
                ('three_point preset', preset)]

    def testFixturesAreWhatTheyClaim(self):
        lighting.set_lights(three_light_rig())
        rig = lighting.get_lights()
        fill = rig['lights'][1]
        self.assertEqual((fill['aim'], fill['aim_selection']),
                         ('point', AWKWARD_SELECTION))
        self.assertEqual(rig['lights'][2]['anchor'], 'pinned')
        for key, value in AIR.items():
            self.assertEqual(rig['air'][key], value, key)
        self.assertIsNotNone(rig['centre'])
        cmd.lights('clear')
        rig = lighting.get_lights()
        self.assertEqual((rig['lights'], rig['centre'], rig['size'],
                          rig['enabled']), ([], None, None, False))
        # the air is kept by clear, so the empty rig is not a default one
        self.assertEqual(rig['air']['seed'], 7)

    def testRestoreRoundTripsExactly(self):
        for label, build in self.fixtures():
            with self.subTest(label):
                lighting.set_lights(None)
                build()
                j0 = lighting._lights_json()
                self.assertIsInstance(j0, str)
                # change the rig every way the bar can: a preset, a
                # re-centre after the molecule moved, then no rig at all
                cmd.lights('softbox')
                cmd.translate([10.0, 0.0, 0.0], 'pep', camera=0)
                lighting._lights_recenter()
                self.assertNotEqual(lighting._lights_json(), j0)
                lighting.set_lights(None)
                ok, text = output(appkit_lights.restore, b64(j0))
                self.assertIs(ok, True)
                self.assertEqual(text, ' lights: reverted\n')
                self.assertEqual(lighting._lights_json(), j0)
                cmd.translate([-10.0, 0.0, 0.0], 'pep', camera=0)

    def testRestoreOverAnEditedRig(self):
        """Revert from a rig that still exists (the usual case)."""
        lighting.set_lights(three_light_rig())
        j0 = lighting._lights_json()
        cmd.do('lights remove, fill')
        lighting._light_set(0, 'orbit', 12.5)
        self.assertNotEqual(lighting._lights_json(), j0)
        self.assertIs(output(appkit_lights.restore, b64(j0))[0], True)
        self.assertEqual(lighting._lights_json(), j0)

    def testRestoreNullRemovesRig(self):
        for before in (three_light_rig(), None):
            with self.subTest(rig=before is not None):
                lighting.set_lights(before)
                ok, text = output(appkit_lights.restore, b64('null'))
                self.assertIs(ok, True)
                self.assertEqual(text, ' lights: reverted\n')
                self.assertIsNone(lighting.get_lights())
                self.assertIsNone(lighting._lights_json())

    def testRestoreBadPayloadPrintsAndLeavesRig(self):
        lighting.set_lights(three_light_rig())
        seven = json.loads(lighting._lights_json())
        while len(seven['lights']) < 7:
            extra = copy.deepcopy(seven['lights'][0])
            extra['name'] = 'extra%d' % len(seven['lights'])
            extra['shadow'] = False
            seven['lights'].append(extra)
        payloads = [
            ('not base64', 'this is not base64!'),
            ('not JSON', b64('{')),
            ('not a rig', b64('[1, 2]')),
            ('seven lights', b64(json.dumps(seven))),
        ]
        for label, payload in payloads:
            with self.subTest(label):
                before = lighting._lights_json()
                ok, text = output(appkit_lights.restore, payload)
                self.assertIs(ok, False)
                self.assertEqual(lighting._lights_json(), before)
                lines = text.splitlines()
                self.assertEqual(len(lines), 1, text)
                self.assertTrue(
                    lines[0].startswith(' lights: revert failed: '), text)
                self.assertGreater(
                    len(lines[0]) - len(' lights: revert failed: '), 0)

    def testRestoreBadPayloadWithNoRig(self):
        """A failed Revert with no rig leaves no rig (none is created)."""
        self.assertIsNone(lighting.get_lights())
        self.assertIs(output(appkit_lights.restore, b64('{'))[0], False)
        self.assertIsNone(lighting.get_lights())


# --- presets (the bar's menu) -------------------------------------------------

class TestPresets(ModeCase):

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix='lighting_mode_')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)
        super().tearDown()

    def testWritePresetsMatchesCommand(self):
        # a path with a space and non-ASCII, as a user's temp dir can have
        path = os.path.join(self.tmp, 'presets é 1.json')
        ok, text = output(appkit_lights.write_presets, b64(path))
        self.assertIs(ok, True)
        self.assertEqual(text, '')
        with open(path, encoding='utf-8') as handle:
            got = json.load(handle)
        want = [{'name': n, 'description': d}
                for n, d in lighting_commands.presets()]
        self.assertEqual(got, want)
        self.assertGreater(len(got), 0)
        for entry in got:
            self.assertEqual(list(entry), ['name', 'description'])
        # writing presets never touches the rig
        self.assertIsNone(lighting.get_lights())

    def testWritePresetsBadPath(self):
        for label, payload in (
                ('missing directory',
                 b64(os.path.join(self.tmp, 'no', 'such', 'dir', 'p.json'))),
                ('a directory', b64(self.tmp)),
                ('not base64', 'not base64!')):
            with self.subTest(label):
                ok, text = output(appkit_lights.write_presets, payload)
                self.assertIs(ok, False)
                lines = text.splitlines()
                self.assertEqual(len(lines), 1, text)
                self.assertTrue(
                    lines[0].startswith(' lights: presets failed: '), text)


# --- the bar's command strings ------------------------------------------------

class TestBarCommands(ModeCase):
    """The exact strings LightsAction.invocation sends (#619 part 3)."""

    def testBarCommandStrings(self):
        self.assertIsNone(lighting.get_lights())

        # + three times: the default names, the first turns the rig on
        for _ in range(3):
            do('lights add')
        self.assertEqual(self.names(), ['key', 'fill', 'rim'])
        self.assertTrue(lighting.get_lights()['enabled'])

        # − with the selected light's name
        do('lights remove, fill')
        self.assertEqual(self.names(), ['key', 'rim'])

        # a preset from the menu replaces every light
        do('lights three_point')
        rig = lighting.get_lights()
        self.assertEqual(self.names(), ['key', 'fill', 'rim'])
        self.assertTrue(rig['enabled'])

        # the On/Off toggle
        do('lights off')
        self.assertFalse(lighting.get_lights()['enabled'])
        self.assertEqual(self.names(), ['key', 'fill', 'rim'])
        do('lights on')
        self.assertTrue(lighting.get_lights()['enabled'])

        # Re-centre after the molecule moved: the centre follows it
        centre = lighting.get_lights()['centre']
        cmd.translate([10.0, 0.0, 0.0], 'pep', camera=0)
        do('lights recenter')
        moved = lighting.get_lights()['centre']
        self.assertAlmostEqual(moved[0] - centre[0], 10.0, places=3)
        self.assertAlmostEqual(moved[1], centre[1], places=3)
        self.assertAlmostEqual(moved[2], centre[2], places=3)

        # a 7th light is refused: one printed error, the rig unchanged
        while len(self.names()) < 6:
            do('lights add')
        self.assertEqual(len(self.names()), 6)
        before = lighting._lights_json()
        text = do('lights add')
        self.assertIn('lights: add', text)
        self.assertEqual(lighting._lights_json(), before)

    def testRemoveTheLastLightLeavesAnEmptyRig(self):
        """What the bar shows after − on the only light: an empty, off rig
        (the chips area reads "No lights")."""
        do('lights add')
        do('lights remove, key')
        rig = lighting.get_lights()
        self.assertEqual((rig['lights'], rig['enabled']), ([], False))

    def testRecenterAndOnWithoutLightsAreRefused(self):
        """The bar disables Re-centre and On/Off without lights; the
        commands themselves refuse and change nothing."""
        for line in ('lights recenter', 'lights on'):
            with self.subTest(line):
                text = do(line)
                self.assertIn('lights', text)
                self.assertIsNone(lighting.get_lights())


# --- the Swift sources ----------------------------------------------------------

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SHARED = os.path.join('swiftui', 'PyMOLViewer', 'Shared')

# The Lights model (and, once it exists, the bar): every button press goes
# through LightsSeams.perform and every drag tick through the bridge setter
# seams the engine wires, so these files name no Python or console entry
# point, no helper and no bridge function.
NO_PYTHON_SOURCES = [os.path.join(SHARED, 'LightsController.swift')]
NO_PYTHON = re.compile(
    r'\brunPython\w*|\bRunPython\w*|\brunCommand\w*|\bRunCommand\w*'
    r'|appkit_lights|\bPyMOLBridge_\w+\s*\(')


def strip_comments(text):
    """Swift comments removed (as lighting_bridge.strip_comments), so a
    comment can neither satisfy nor trip a check."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


class TestSwiftSource(testing.PyMOLTestCase):

    def read(self, rel):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source check that cannot find its source
            # has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            return handle.read()

    def testControllerAndBarRunNoPython(self):
        for rel in NO_PYTHON_SOURCES:
            with self.subTest(rel):
                found = NO_PYTHON.search(strip_comments(self.read(rel)))
                self.assertIsNone(found, '%s names %r' % (rel, found and found.group(0)))

    def testTheCheckCatchesEachEntryPoint(self):
        """The pattern matches every name it is meant to forbid (and not a
        mere mention of the rig's JSON or the light-count constant)."""
        for text in ('engine.runPython("x")', 'engine.runPythonQuiet(x)',
                     'runCommand("lights add")', 'PyMOLBridge_RunCommand(h, c)',
                     'from pymol import appkit_lights',
                     'PyMOLBridge_LightSet (instance, 0, f, v)'):
            self.assertIsNotNone(NO_PYTHON.search(text), text)
        for text in ('Int(PYMOL_LIGHTS_MAX)', 'seams.rigJSON()',
                     'seams.perform(.add)', '// runPython is never called'):
            self.assertIsNone(NO_PYTHON.search(strip_comments(text)), text)
