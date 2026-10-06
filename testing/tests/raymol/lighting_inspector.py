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

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_inspector.py
"""
import base64
import contextlib
import io
import json

import pymol
import pymol.invocation
from pymol import appkit_lights, cmd, lighting, testing

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
