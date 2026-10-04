"""The `lights` and `atmosphere` commands (#612).

The commands script the native rig of #611 (pymol.lighting) from the command
line, `cmd.do`, scripts, MCP and the app's command line (PyMOLBridge_RunCommand
-> cmd.do): presets, keywords, the air, and the query forms. Every call is one
transaction: nothing changes when any argument is invalid, every error is a
CmdException starting with "lights: " or "atmosphere: ", and in a `;` chain
PyMOL skips the rest of the line after an error.

Expected values come from closed forms (the frame from cmd.get_extent) or from
literal copies of the tables in the #612 plan, never from the code under test.

Covers (part 1): registration (keyword table, cmd.do, help, completion, the
`at` abbreviation), the 7 presets (exact values, frame captured again, air
kept, the spotlight's off-centre aim), the keywords (add by name, remove,
presets, recenter, on, off, clear), the query forms (always print, return
data), the air (fields, ranges, `off`, the no-rig rule, the comma hint), the
docs against the C++ field table, the frozen harness's `lights three_point;
lights off` path, the rollback, the non-negotiables (no setting, colour,
material, extent or view changes) and `;` chaining.

Covers (part 2): per-light edits and `add` with fields (every field and
alias, rename and the name rules, the 6-light and 3-shadow caps), the colour
resolver (names ignoring case, unique prefixes, hex, r/g/b, the colour words
warm/neutral/cool, and the special colours and indices it refuses without
touching auto_color_next), aim (centre, a world point, a selection's centroid
with the object matrix applied), pin/anchor/position and the order of their
steps, every conflict, the Phase 2 rollback, chaining and the
non-negotiables for each field kind.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_commands.py
"""
import contextlib
import copy
import io
import math
import re

import pymol
import pymol.invocation
from pymol import CmdException, _cmd, cmd, lighting, lighting_commands, testing
from pymol import parsing

# Two protein atoms in a 4 x 6 x 12 A box (half-diagonal 7 A), plus waters
# 50 A away that would inflate the box if solvent were not excluded.
_PDB = """\
ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N
ATOM      2  CA  ALA A   1       4.000   6.000  12.000  1.00  0.00           C
HETATM    3  O   HOH A   2      50.000  50.000  50.000  1.00  0.00           O
HETATM    4  O   HOH A   3     -50.000 -50.000 -50.000  1.00  0.00           O
END
"""

DEFAULT_LIGHT = {
    'anchor': 'camera', 'orbit': 0.0, 'pitch': 30.0, 'radius': 4.0,
    'position': [0.0, 0.0, 0.0], 'aim': 'centre', 'aim_point': [0.0, 0.0, 0.0],
    'aim_selection': '', 'beam': 45.0, 'softness': 0.4,
    'color': [1.0, 1.0, 1.0], 'warmth': 6500.0, 'intensity': 1.0,
    'highlight': 0.5, 'falloff': 2.0, 'shadow': False, 'outline': False,
}
AIR_DEFAULTS = {'haze': 0.0, 'dust': 0.0, 'dust_size': 0.35,
                'dust_speed': 1.0, 'scatter': 0.55, 'seed': 0}


def L(name, orbit, pitch, beam, softness, intensity, highlight, **extra):
    light = dict(copy.deepcopy(DEFAULT_LIGHT), name=name, orbit=orbit,
                 pitch=pitch, beam=beam, softness=softness,
                 intensity=intensity, highlight=highlight)
    light.update(extra)
    return light


# A literal copy of the #612 plan's preset table (section 3.10): name,
# description, ambient, lights. classic is 0 for every preset.
PRESETS = [
    ('three_point',
     'Classic portrait: warm key with shadow, cool fill, white rim', 0.10, [
         L('key', -45.0, 35.0, 55.0, 0.5, 1.15, 0.6, warmth=4500.0,
           shadow=True),
         L('fill', 55.0, 5.0, 80.0, 0.8, 0.35, 0.1, warmth=8000.0),
         L('rim', 165.0, 40.0, 40.0, 0.4, 1.6, 1.0)]),
    ('softbox',
     'Product shot: two big soft white boxes, gentle top light', 0.16, [
         L('left', -60.0, 20.0, 120.0, 1.0, 0.75, 0.25, shadow=True),
         L('right', 60.0, 20.0, 120.0, 1.0, 0.55, 0.25),
         L('top', 0.0, 80.0, 110.0, 1.0, 0.35, 0.15)]),
    ('spotlight',
     'Theatre: one narrow beam from above, the rest falls off', 0.05, [
         L('spot', -15.0, 50.0, 18.0, 0.3, 1.8, 0.9, radius=3.0,
           warmth=5200.0, shadow=True),
         L('bounce', 20.0, -30.0, 90.0, 1.0, 0.12, 0.0, warmth=7500.0)]),
    ('rembrandt',
     'Dramatic: one hard warm key high to the side, almost no fill', 0.04, [
         L('key', -70.0, 45.0, 60.0, 0.3, 1.5, 0.7, radius=3.0,
           warmth=3400.0, falloff=2.0, shadow=True),
         L('kicker', 150.0, 10.0, 30.0, 0.4, 0.6, 0.6, warmth=6500.0)]),
    ('neon',
     'Coloured rims: magenta and cyan from behind, dim violet front', 0.06, [
         L('magenta', -125.0, 20.0, 55.0, 0.5, 1.6, 1.0,
           color=[1.0, 0.0, 1.0], shadow=True),
         L('cyan', 125.0, 20.0, 55.0, 0.5, 1.6, 1.0, color=[0.0, 1.0, 1.0]),
         L('front', 0.0, 0.0, 90.0, 1.0, 0.25, 0.1, color=[0.5, 0.5, 1.0])]),
    ('sunset',
     'Low orange sun from one side, blue sky fill from the other', 0.08, [
         L('sun', -75.0, 12.0, 70.0, 0.5, 1.4, 0.8, warmth=2400.0,
           shadow=True),
         L('sky', 60.0, 50.0, 110.0, 1.0, 0.45, 0.1, warmth=14000.0)]),
    ('underlight',
     'Horror-film: green-tinted key from below, red rim', 0.04, [
         L('under', 0.0, -55.0, 60.0, 0.5, 1.3, 0.6,
           color=[0.6, 1.0, 0.55], shadow=True),
         L('rim', 170.0, 25.0, 40.0, 0.4, 1.4, 0.8, color=[1.0, 0.0, 0.0])]),
]
PRESET_NAMES = [p[0] for p in PRESETS]
KEYWORDS = ['add', 'remove', 'presets', 'recenter', 'on', 'off', 'clear']
ALIASES = ['az', 'el', 'dist', 'soft', 'int', 'spec', 'cue', 'kelvin',
           'colour']
HELPERS = ['target', 'highlight', 'click', 'rim']
# The spotlight's spot aims off the centre: rig sizes along camera x, y, z.
SPOT_OFFSET = (-0.25, 0.15, 0.0)


def output(func, *args, **kwargs):
    """Run func, return (result, what it printed from Python)."""
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        result = func(*args, **kwargs)
    return result, buf.getvalue()


def do(line):
    """cmd.do(line) (the parser's and the app's path); returns the text.
    The runner's -y (exit on error) would quit on the errors these tests
    provoke, so it is off for the call."""
    options = pymol.invocation.options
    exit_on_error = options.exit_on_error
    options.exit_on_error = 0
    try:
        return output(cmd.do, line)[1]
    finally:
        options.exit_on_error = exit_on_error


def closed_frame(sele='(enabled and not solvent)'):
    mn, mx = cmd.get_extent(sele)
    centre = [(a + b) / 2.0 for a, b in zip(mn, mx)]
    size = max(0.5 * math.sqrt(sum((b - a) ** 2 for a, b in zip(mn, mx))),
               1.0)
    return centre, size


def num(x):
    """The docs' number format, by the test's own rule: an integral value in
    full, other values as %g."""
    x = float(x)
    return str(int(x)) if x.is_integer() else '%g' % x


def light(name):
    """Light `name` of the rig, as get_lights() holds it."""
    for entry in cmd.get_lights()['lights']:
        if entry['name'] == name:
            return entry
    raise KeyError(name)


def eye(name):
    """Light `name` resolved to eye space (the live camera)."""
    for entry in lighting._lights_eye()['lights']:
        if entry['name'] == name:
            return entry
    raise KeyError(name)


# The protein atoms of _PDB (resi 1) and their centroid.
PROTEIN = [(0.0, 0.0, 0.0), (4.0, 6.0, 12.0)]
PROTEIN_CENTROID = [2.0, 3.0, 6.0]


class CommandsCase(testing.PyMOLTestCase):

    def load(self):
        cmd.read_pdbstr(_PDB, 'm')

    def tearDown(self):
        lighting.set_lights(None)
        super().tearDown()

    def assertUnchanged(self, before, func, *args, **kwargs):
        """func raises a CmdException and the rig is deep-equal to `before`
        (or still None); returns the message."""
        with self.assertRaises(CmdException) as ctx:
            func(*args, **kwargs)
        self.assertEqual(cmd.get_lights(), before)
        return str(ctx.exception)

    def assertError(self, pattern, func, *args, **kwargs):
        """func raises a CmdException matching `pattern`, starting with the
        command's prefix, and nothing changes."""
        before = cmd.get_lights()
        message = self.assertUnchanged(before, func, *args, **kwargs)
        self.assertRegex(message, pattern)
        self.assertRegex(message, r'^ Error: (lights|atmosphere): ')
        return message

    def assertVec(self, got, want, places=4, msg=None):
        self.assertEqual(len(got), len(want), msg)
        for g, w in zip(got, want):
            self.assertAlmostEqual(g, w, places=places, msg=msg)


# --- registration -----------------------------------------------------------

class TestRegistration(CommandsCase):

    def testKeywordTable(self):
        for name, func in (('lights', cmd.lights),
                           ('atmosphere', cmd.atmosphere)):
            self.assertIn(name, cmd.keyword)
            entry = cmd.keyword[name]
            self.assertIs(entry[0], func)
            self.assertEqual(entry[4], parsing.STRICT)
        self.assertIs(cmd.lights, lighting_commands.lights)
        self.assertIs(cmd.atmosphere, lighting_commands.atmosphere)

    def testCompletionTables(self):
        self.assertIn('lights', cmd.auto_arg[0])
        self.assertIn('atmosphere', cmd.auto_arg[0])
        self.assertIn('lights', cmd.auto_arg[1])

    def testDoAppliesAPreset(self):
        do('lights three_point')
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']],
                         ['key', 'fill', 'rim'])
        self.assertIs(rig['enabled'], True)

    def testHelp(self):
        for name in ('lights', 'atmosphere'):
            _, text = output(cmd.help, name)
            self.assertIn('DESCRIPTION', text)
            self.assertIn('"%s"' % name, text)

    def testAtIsNowAmbiguous(self):
        # 'at' expanded to 'attach' (the only command starting with 'at')
        # before #612; now it is ambiguous, and 'attach' must be typed out.
        matches = cmd.kwhash.interpret('at')
        self.assertIsInstance(matches, list)
        self.assertIn('attach', matches)
        self.assertIn('atmosphere', matches)
        self.assertEqual(cmd.kwhash.interpret('atm'), 'atmosphere')
        self.assertEqual(cmd.kwhash.interpret('lights'), 'lights')

    def testParserCompletion(self):
        result, _ = output(cmd._parser.complete, 'lights thr')
        self.assertEqual(result, 'lights three_point, ')
        cmd.set_lights({'lights': [{'name': 'zed'}]})
        result, _ = output(cmd._parser.complete, 'lights ze')
        self.assertEqual(result, 'lights zed, ')
        result, _ = output(cmd._parser.complete, 'lights remove, ze')
        self.assertEqual(result, 'lights remove, zed, ')
        result, _ = output(cmd._parser.complete, 'atmosphere o')
        self.assertEqual(result, 'atmosphere off, ')

    def testCompletionHelperNeverRaises(self):
        from pymol import completing
        words = KEYWORDS + PRESET_NAMES
        # no rig
        sc = lighting_commands._lights_shortcut(cmd)
        self.assertEqual(sorted(sc.keywords), sorted(words))
        # a rig, with a light named after a keyword (shadowed, not offered)
        cmd.set_lights({'lights': [{'name': 'zed'}, {'name': 'off'}]})
        sc = lighting_commands._lights_shortcut(cmd)
        self.assertEqual(sorted(sc.keywords), sorted(words + ['zed']))
        names = lighting_commands._light_names_shortcut(cmd)
        self.assertEqual(sorted(names.keywords), ['off', 'zed'])
        # a broken instance
        sc = lighting_commands._lights_shortcut(object())
        self.assertEqual(sorted(sc.keywords), sorted(words))
        self.assertEqual(
            list(lighting_commands._light_names_shortcut(object()).keywords),
            [])
        # the completing.py wrappers the parser calls
        sc = completing._lights_shortcut(None)
        self.assertEqual(sorted(sc.keywords), sorted(words))
        self.assertEqual(list(completing._light_names_shortcut(None).keywords),
                         [])


# --- presets ----------------------------------------------------------------

class TestPresets(CommandsCase):

    def testListPrintsAndReturns(self):
        pairs = [(name, description) for name, description, _, _ in PRESETS]
        self.assertEqual(lighting_commands.presets(), pairs)
        for quiet in (1, 0):
            result, text = output(cmd.lights, 'presets', quiet=quiet)
            self.assertEqual(result, pairs)
            lines = text.splitlines()
            for name, description in pairs:
                self.assertTrue(any(name in line and description in line
                                    for line in lines), name)
            names = [n for n, _ in pairs]
            order = [min(i for i, line in enumerate(lines) if n in line)
                     for n in names]
            self.assertEqual(order, sorted(order))
        self.assertIsNone(cmd.get_lights())     # a query changes nothing

    def testEveryPresetExactly(self):
        self.load()
        centre, size = closed_frame()
        table = lighting._light_fields()
        bounds = {f[1]: (f[4], f[5]) for f in table
                  if f[0] == 'light' and f[4] is not None}
        for name, _, ambient, lights in PRESETS:
            for word in (name, name.upper()):
                cmd.lights(word)
                rig = cmd.get_lights()
                self.assertIs(rig['enabled'], True, name)
                self.assertEqual(rig['ambient'], ambient, name)
                self.assertEqual(rig['classic'], 0.0, name)
                self.assertEqual(rig['air'], AIR_DEFAULTS, name)
                for got_c, want_c in zip(rig['centre'], centre):
                    self.assertAlmostEqual(got_c, want_c, places=5)
                self.assertAlmostEqual(rig['size'], size, places=5)
                self.assertEqual(len(rig['lights']), len(lights), name)
                for got, want in zip(rig['lights'], lights):
                    if name == 'spotlight' and want['name'] == 'spot':
                        # the off-centre aim (TestPresets.testSpotlightAim)
                        self.assertEqual(got['aim'], 'point')
                        self.assertEqual(got['aim_selection'], '')
                        got = dict(got, aim='centre',
                                   aim_point=[0.0, 0.0, 0.0])
                    self.assertEqual(got, want, (name, want['name']))
                    for field, (lo, hi) in bounds.items():
                        value = want[field]
                        for v in (value if isinstance(value, list)
                                  else [value]):
                            self.assertTrue(lo <= v <= hi,
                                            (name, field, v))

    def testPresetCapturesTheFrameAgain(self):
        self.load()
        cmd.lights('three_point')
        first = cmd.get_lights()
        # move the object (its TTT) and apply the preset again
        cmd.translate([10.0, 0.0, 0.0], 'm', camera=0, object='m')
        cmd.lights('three_point')
        second = cmd.get_lights()
        centre, size = closed_frame()
        self.assertAlmostEqual(second['centre'][0], first['centre'][0] + 10.0,
                               places=5)
        for got, want in zip(second['centre'], centre):
            self.assertAlmostEqual(got, want, places=5)
        self.assertAlmostEqual(second['size'], size, places=5)
        self.assertEqual(second['lights'], first['lights'])

    def testPresetReplacesTheRigAndKeepsTheAir(self):
        self.load()
        cmd.atmosphere(haze=0.3, dust=0.45, seed=7)
        air = cmd.get_lights()['air']
        cmd.lights('neon')
        cmd.lights('add', 'extra')
        cmd.lights(ambient=0.5, classic=0.25)
        cmd.lights('sunset')
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']], ['sun', 'sky'])
        self.assertEqual(rig['ambient'], 0.08)
        self.assertEqual(rig['classic'], 0.0)
        self.assertEqual(rig['air'], air)
        self.assertEqual(air['haze'], 0.3)

    def testPresetTurnsTheRigOn(self):
        self.load()
        cmd.lights('three_point')
        cmd.lights('off')
        cmd.lights('neon')
        self.assertIs(cmd.get_lights()['enabled'], True)

    def testRigOverrides(self):
        self.load()
        cmd.lights('neon', ambient=0.2)
        self.assertEqual(cmd.get_lights()['ambient'], 0.2)
        do('lights neon, ambient=0.3, classic=0.4')
        rig = cmd.get_lights()
        self.assertEqual((rig['ambient'], rig['classic']), (0.3, 0.4))
        self.assertEqual(rig['lights'][0]['name'], 'magenta')

    def testLightFieldWithAPresetIsAnError(self):
        self.load()
        cmd.lights('three_point')
        message = self.assertError(r'neon: intensity is a light field',
                                   cmd.lights, 'neon', intensity=2)
        self.assertIn('lights <name>, intensity=2', message)
        self.assertError(r"unknown field 'fog' \(a preset takes only "
                         r"ambient=, classic=\)", cmd.lights, 'neon', fog=1)
        self.assertError(r'ambient=2 is out of range 0 to 1', cmd.lights,
                         'neon', ambient=2)
        self.assertError(r'haze is an atmosphere field', cmd.lights, 'neon',
                         haze=0.2)
        self.assertError(r'too many arguments', cmd.lights, 'neon', 'key')

    def testSpotlightAim(self):
        # The spot aims 0.25 sizes left and 0.15 up of the centre as the
        # camera sees it when the preset is applied, stored as a world point.
        self.load()
        cmd.turn('y', 40)
        cmd.turn('x', 25)
        cmd.lights('spotlight')
        rig = cmd.get_lights()
        eye = lighting._lights_eye()
        spot = eye['lights'][0]
        for k in range(3):
            want = eye['centre'][k] + rig['size'] * SPOT_OFFSET[k]
            self.assertAlmostEqual(spot['target'][k], want, places=4)
        # resolved once: turning the camera keeps the world aim point
        point = rig['lights'][0]['aim_point']
        cmd.turn('y', 30)
        self.assertEqual(cmd.get_lights()['lights'][0]['aim_point'], point)
        # the bounce light aims at the centre
        self.assertEqual(rig['lights'][1]['aim'], 'centre')

    def testPresetWithNothingLoaded(self):
        # with nothing to measure the frame is the scene origin, size 10
        cmd.lights('softbox')
        rig = cmd.get_lights()
        self.assertEqual(rig['size'], 10.0)
        self.assertEqual(len(rig['lights']), 3)


# --- keywords ---------------------------------------------------------------

class TestKeywords(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()

    def testOffAndOnKeepTheRig(self):
        cmd.lights('three_point')
        cmd.atmosphere(haze=0.3)
        on = cmd.get_lights()
        cmd.lights('off')
        off = cmd.get_lights()
        self.assertIs(off['enabled'], False)
        self.assertEqual(dict(off, enabled=True), on)
        cmd.lights('ON')
        self.assertEqual(cmd.get_lights(), on)

    def testOffIsANoOpWithNoRigOrWhenOff(self):
        result, text = output(cmd.lights, 'off', quiet=0)
        self.assertIsNone(result)
        self.assertIn('no light rig', text)
        self.assertIsNone(cmd.get_lights())
        cmd.lights('three_point')
        cmd.lights('off')
        before = cmd.get_lights()
        _, text = output(cmd.lights, 'off', quiet=0)
        self.assertIn('already off', text)
        self.assertEqual(cmd.get_lights(), before)

    def testOnNeedsLights(self):
        self.assertError(r'on: no light rig', cmd.lights, 'on')
        cmd.atmosphere(haze=0.2)          # an empty rig
        self.assertError(r'on: the rig has no lights', cmd.lights, 'on')
        cmd.lights('three_point')
        before = cmd.get_lights()
        _, text = output(cmd.lights, 'on', quiet=0)
        self.assertIn('already on', text)
        self.assertEqual(cmd.get_lights(), before)

    def testClearRemovesTheLightsAndKeepsTheRest(self):
        # Q1: 'lights clear' removes all lights (spec section 5) and keeps
        # the rig's air, ambient and classic; 'atmosphere off' clears the air.
        cmd.lights('three_point', ambient=0.3, classic=0.2)
        cmd.atmosphere(haze=0.4, seed=9)
        before = cmd.get_lights()
        _, text = output(cmd.lights, 'clear', quiet=0)
        self.assertIn('cleared', text)
        rig = cmd.get_lights()
        self.assertEqual(rig['lights'], [])
        self.assertIs(rig['enabled'], False)
        self.assertIsNone(rig['centre'])
        self.assertIsNone(rig['size'])
        for key in ('ambient', 'classic', 'air'):
            self.assertEqual(rig[key], before[key], key)
        self.assertIsNone(lighting._lights_ray_notice())
        # no rig: a no-op
        lighting.set_lights(None)
        cmd.lights('clear')
        self.assertIsNone(cmd.get_lights())

    def testRecenterMovesOnlyTheFrame(self):
        cmd.lights('three_point')
        before = cmd.get_lights()
        cmd.translate([0.0, 0.0, 20.0], 'm', camera=0)
        _, text = output(cmd.lights, 'recenter', quiet=0)
        self.assertIn('re-centred', text)
        after = cmd.get_lights()
        centre, size = closed_frame()
        for got, want in zip(after['centre'], centre):
            self.assertAlmostEqual(got, want, places=5)
        self.assertAlmostEqual(after['size'], size, places=5)
        self.assertNotEqual(after['centre'], before['centre'])
        self.assertEqual(dict(after, centre=None, size=None),
                         dict(before, centre=None, size=None))

    def testRecenterWithNoRig(self):
        self.assertError(r'no light rig to re-centre', cmd.lights, 'recenter')

    def testRemove(self):
        cmd.lights('three_point')
        _, text = output(cmd.lights, 'remove', 'RIM', quiet=0)
        self.assertIn("removed 'rim'", text)
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key', 'fill'])
        self.assertError(r"remove: no light named 'nosuch' \(lights: key, "
                         r"fill\)", cmd.lights, 'remove', 'nosuch')
        self.assertError(r'remove: which light', cmd.lights, 'remove')
        self.assertError(r'remove: takes only a light name', cmd.lights,
                         'remove', 'key', orbit=3)
        self.assertError(r'remove: the name is given twice', cmd.lights,
                         'remove', 'key', name='fill')
        cmd.lights('remove', name='Fill')
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key'])

    def testRemoveTheLastLight(self):
        cmd.set_lights({'enabled': True, 'ambient': 0.2,
                        'air': {'haze': 0.3}, 'lights': [{'name': 'solo'}]})
        _, text = output(cmd.lights, 'remove', 'solo', quiet=0)
        self.assertIn('no lights left', text)
        rig = cmd.get_lights()
        self.assertEqual(rig['lights'], [])
        self.assertIs(rig['enabled'], False)
        self.assertIsNone(rig['centre'])
        self.assertEqual(rig['ambient'], 0.2)
        self.assertEqual(rig['air']['haze'], 0.3)

    def testRemoveWithNoRig(self):
        self.assertError(r"remove: no light named 'key' \(lights: none\)",
                         cmd.lights, 'remove', 'key')

    def testAddByName(self):
        result, text = output(cmd.lights, 'add', 'rim', quiet=0)
        self.assertEqual(result, 'rim')
        self.assertIn("added 'rim'", text)
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual(rig['lights'], [dict(DEFAULT_LIGHT, name='rim')])
        centre, size = closed_frame()
        for got, want in zip(rig['centre'], centre):
            self.assertAlmostEqual(got, want, places=5)
        self.assertAlmostEqual(rig['size'], size, places=5)

    def testAddWithoutAName(self):
        self.assertEqual(cmd.lights('add'), 'key')
        self.assertEqual(cmd.lights('add'), 'fill')
        self.assertEqual(cmd.lights('add', name='spot'), 'spot')
        self.assertEqual(cmd.lights('add'), 'rim')
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key', 'fill', 'spot', 'rim'])

    def testAddThroughTheParser(self):
        do('lights add, rim')
        do('lights add, name=spot')
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['rim', 'spot'])

    def testAddKeepsAnOffRigOff(self):
        cmd.lights('three_point')
        cmd.lights('off')
        _, text = output(cmd.lights, 'add', 'extra', quiet=0)
        self.assertIn("the rig is off", text)
        self.assertIs(cmd.get_lights()['enabled'], False)

    def testAddToAnEmptyRigCapturesTheFrameAndTurnsItOn(self):
        cmd.atmosphere(haze=0.3)
        self.assertIsNone(cmd.get_lights()['centre'])
        cmd.lights('add', 'key')
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        centre, size = closed_frame()
        self.assertAlmostEqual(rig['size'], size, places=5)
        self.assertEqual(rig['air']['haze'], 0.3)
        # after 'clear' the stale frame is dropped and captured again
        cmd.lights('clear')
        cmd.translate([0.0, 30.0, 0.0], 'm', camera=0)
        cmd.lights('add')
        centre, size = closed_frame()
        for got, want in zip(cmd.get_lights()['centre'], centre):
            self.assertAlmostEqual(got, want, places=5)

    def testAddErrors(self):
        for i in range(6):
            cmd.lights('add')
        self.assertError(r'add: the rig already has 6 lights', cmd.lights,
                         'add')
        lighting.set_lights(None)
        cmd.lights('add', 'key')
        self.assertError(r"add: a light named 'key' already exists",
                         cmd.lights, 'add', 'KEY')
        self.assertError(r"add: 'off' is a keyword", cmd.lights, 'add', 'off')
        self.assertError(r"add: 'Neon' is a preset", cmd.lights, 'add',
                         'Neon')
        self.assertError(r"add: name '1key' is not valid", cmd.lights, 'add',
                         '1key')
        self.assertError(r"add: name '%s' is not valid" % ('a' * 33),
                         cmd.lights, 'add', 'a' * 33)
        self.assertError(r'add: the name is given twice', cmd.lights, 'add',
                         'rim', name='spot')
        self.assertError(r'too many arguments', cmd.lights, 'add', 'a', 'b')

    def testKeywordsMatchIgnoringCase(self):
        cmd.lights('THREE_POINT')
        cmd.lights('Off')
        self.assertIs(cmd.get_lights()['enabled'], False)

    def testKeywordsTakeNoExtraArguments(self):
        cmd.lights('three_point')
        for word in ('off', 'on', 'clear', 'recenter', 'presets'):
            self.assertError(r'%s takes no arguments' % word, cmd.lights,
                             word, 'x')
            self.assertError(r'%s takes no arguments' % word, cmd.lights,
                             word, ambient=0.2)
        self.assertError(r'too many arguments', cmd.lights, 'off', 'x', 'y')

    def testUnknownWord(self):
        cmd.lights('three_point')
        message = self.assertError(
            r"no light, preset or keyword named 'nosuch' \(lights: key, "
            r"fill, rim; presets: three_point, ", cmd.lights, 'nosuch')
        self.assertIn('keywords: add, remove, presets', message)
        self.assertNotIn('to add one', message)
        message = self.assertError(r"named 'spot'", cmd.lights, 'spot',
                                   orbit=3)
        self.assertIn('to add one: lights add, spot', message)

    def testCommaLessWords(self):
        message = self.assertError(r"'key orbit=-45': separate arguments "
                                   r"with commas", cmd.lights, 'key orbit=-45')
        self.assertIn('lights key, orbit=-45', message)
        self.assertError(r'separate arguments with commas', cmd.lights,
                         'add', 'rim orbit=3')


# --- queries ----------------------------------------------------------------

class TestQueries(CommandsCase):

    def testNoRig(self):
        for quiet in (1, 0):
            result, text = output(cmd.lights, quiet=quiet)
            self.assertIsNone(result)
            self.assertIn('no light rig', text)
            result, text = output(cmd.atmosphere, quiet=quiet)
            self.assertIsNone(result)
            self.assertIn('no light rig', text)
        self.assertIsNone(cmd.get_lights())

    def testRig(self):
        self.load()
        cmd.lights('three_point')
        for quiet in (1, 0):
            result, text = output(cmd.lights, quiet=quiet)
            self.assertEqual(result, cmd.get_lights())
            self.assertIn('lights: on, 3 lights, ambient 0.1, classic 0', text)
            self.assertIn('key: camera, orbit -45, pitch 35, radius 4', text)
            self.assertIn('beam 55, softness 0.5, color 1/1/1, warmth 4500, '
                          'intensity 1.15', text)
            self.assertIn('air: haze 0, dust 0, dust_size 0.35', text)
        text = do('lights')
        self.assertIn('lights: on, 3 lights', text)

    def testOneLight(self):
        self.load()
        cmd.lights('three_point')
        result, text = output(cmd.lights, 'FILL')
        self.assertEqual(result, cmd.get_lights()['lights'][1])
        self.assertIn('fill: camera, orbit 55, pitch 5', text)
        self.assertNotIn('rim', text)

    def testAtmosphere(self):
        self.load()
        cmd.lights('three_point')
        cmd.atmosphere(haze=0.3, seed=7)
        result, text = output(cmd.atmosphere)
        self.assertEqual(result, cmd.get_lights()['air'])
        self.assertIn('atmosphere: haze 0.3, dust 0, dust_size 0.35, '
                      'dust_speed 1, scatter 0.55, seed 7', text)
        self.assertNotIn('shows only while', text)

    def testPinnedLightPrintsItsDerivedPlace(self):
        self.load()
        cmd.set_lights({'enabled': True, 'lights': [
            {'name': 'key', 'anchor': 'pinned', 'position': [30.0, 3.0, 6.0]},
            {'name': 'fill', 'aim': 'point', 'aim_point': [1.0, 2.0, 3.0],
             'aim_selection': 'resi 1'}]})
        eye = lighting._lights_eye()['lights'][0]
        _, text = output(cmd.lights)
        self.assertIn('key: pinned at (30.00, 3.00, 6.00), now orbit %g, '
                      'pitch %g, radius %g' % (eye['orbit'], eye['pitch'],
                                               eye['radius']), text)
        self.assertIn("aim (1.00, 2.00, 3.00) from 'resi 1'", text)
        self.assertNotEqual(eye['orbit'], 0.0)

    def testEmptyRig(self):
        cmd.lights(ambient=0.2)
        _, text = output(cmd.lights)
        self.assertIn('lights: off, no lights, ambient 0.2', text)

    def testShadowedNameIsMarked(self):
        # Q6: reserved names are enforced by the command only, so a rig
        # from set_lights can hold one; the keyword wins at dispatch.
        cmd.set_lights({'lights': [{'name': 'off'}, {'name': 'neon'}]})
        _, text = output(cmd.lights)
        self.assertIn('off (shadowed by the keyword)', text)
        self.assertIn('neon (shadowed by the preset)', text)


# --- rig fields -------------------------------------------------------------

class TestRigFields(CommandsCase):

    def testEditRig(self):
        self.load()
        cmd.lights('three_point')
        before = cmd.get_lights()
        _, text = output(cmd.lights, ambient='0.25', classic=1, quiet=0)
        self.assertIn('lights: ambient 0.25, classic 1', text)
        self.assertNotIn('created', text)
        rig = cmd.get_lights()
        self.assertEqual(dict(rig, ambient=0.05, classic=0.0),
                         dict(before, ambient=0.05, classic=0.0))
        self.assertEqual((rig['ambient'], rig['classic']), (0.25, 1.0))
        do('lights classic=0')
        self.assertEqual(cmd.get_lights()['classic'], 0.0)

    def testErrors(self):
        for start in (None, 'three_point'):
            if start:
                self.load()
                cmd.lights(start)
            message = self.assertError(
                r"unknown field 'fog' \(rig: ambient, classic; light: name, "
                r"anchor, orbit \(az\), pitch \(el\)", cmd.lights, fog=1)
            self.assertIn('placement: target, highlight, click, rim', message)
            self.assertIn('air (atmosphere): haze, dust', message)
            self.assertError(r"which light\? orbit is a light field: lights "
                             r"<name>, orbit=3 or lights add, <name>, orbit=3",
                             cmd.lights, orbit=3)
            self.assertError(r'which light\? az is a light field', cmd.lights,
                             ambient=0.2, az=3)
            self.assertError(r"enabled is set by 'lights on' and 'lights "
                             r"off'", cmd.lights, enabled=1)
            self.assertError(r"centre is captured from the molecules; "
                             r"'lights recenter'", cmd.lights,
                             centre=[0, 0, 0])
            self.assertError(r'aim_point is set by aim=', cmd.lights,
                             aim_point=[1, 2, 3])
            self.assertError(r'haze is an atmosphere field: atmosphere '
                             r'haze=0.3', cmd.lights, haze=0.3)
            self.assertError(r'classic=1.5 is out of range 0 to 1',
                             cmd.lights, ambient=0.2, classic=1.5)
            self.assertError(r'ambient=-0.1 is out of range 0 to 1',
                             cmd.lights, ambient='-0.1')
            self.assertError(r'ambient=x is not a number', cmd.lights,
                             ambient='x')
            self.assertError(r'ambient=inf is not a finite number',
                             cmd.lights, ambient=float('inf'))
            self.assertError(r'ambient is given twice', cmd.lights,
                             ambient=0.1, Ambient=0.2)


# --- atmosphere -------------------------------------------------------------

class TestAtmosphere(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()

    def testEveryField(self):
        cmd.lights('three_point')
        want = {'haze': 0.3, 'dust': 0.45, 'dust_size': 0.4,
                'dust_speed': 2.5, 'scatter': -0.35, 'seed': 42}
        do('atmosphere haze=0.3, dust=0.45, dust_size=0.4, dust_speed=2.5, '
           'scatter=-0.35, seed=42')
        self.assertEqual(cmd.get_lights()['air'], want)
        cmd.atmosphere('off')
        cmd.atmosphere(**want)                  # Python numbers
        self.assertEqual(cmd.get_lights()['air'], want)

    def testRangesAreInclusive(self):
        cmd.atmosphere(haze=1, dust=0, dust_size=0.05, dust_speed=10,
                       scatter=-0.9, seed=1000000)
        self.assertEqual(cmd.get_lights()['air'], {
            'haze': 1.0, 'dust': 0.0, 'dust_size': 0.05, 'dust_speed': 10.0,
            'scatter': -0.9, 'seed': 1000000})
        cmd.atmosphere(dust_size=2, scatter=0.9, seed=0)
        air = cmd.get_lights()['air']
        self.assertEqual((air['dust_size'], air['scatter'], air['seed']),
                         (2.0, 0.9, 0))

    def testOffResetsToTheTableDefaults(self):
        cmd.lights('three_point')
        cmd.atmosphere(haze=0.3, dust=0.5, seed=7)
        lights = cmd.get_lights()['lights']
        cmd.atmosphere('OFF')
        defaults = {f[1]: f[3] for f in lighting._light_fields()
                    if f[0] == 'air'}
        rig = cmd.get_lights()
        self.assertEqual(rig['air'], defaults)
        self.assertEqual(rig['air'], AIR_DEFAULTS)
        self.assertEqual(rig['lights'], lights)
        self.assertIs(rig['enabled'], True)

    def testOffWithNoRigIsANoOp(self):
        _, text = output(cmd.atmosphere, 'off', quiet=0)
        self.assertIn('no light rig', text)
        self.assertIsNone(cmd.get_lights())

    def testNoRigCreatesAnEmptyRigThatIsOff(self):
        # Q8: a rig-level or air edit with no rig creates an empty rig that
        # is off and holds the value.
        _, text = output(cmd.atmosphere, haze=0.3, quiet=0)
        self.assertIn('created a light rig that is off', text)
        self.assertIn('shows only while the lights are on', text)
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], False)
        self.assertEqual(rig['lights'], [])
        self.assertIsNone(rig['centre'])
        self.assertEqual(rig['air'], dict(AIR_DEFAULTS, haze=0.3))
        self.assertIsNone(lighting._lights_ray_notice())
        lighting.set_lights(None)
        _, text = output(cmd.lights, ambient=0.2, quiet=0)
        self.assertIn('created a light rig that is off', text)
        rig = cmd.get_lights()
        self.assertEqual((rig['enabled'], rig['lights'], rig['ambient']),
                         (False, [], 0.2))

    def testErrorsChangeNothing(self):
        for rig in (None, 'three_point'):
            if rig:
                cmd.lights(rig)
                cmd.atmosphere(haze=0.1)
            self.assertError(r'atmosphere: haze=1.5 is out of range 0 to 1',
                             cmd.atmosphere, haze=1.5)
            self.assertError(r'scatter=-1 is out of range -0.9 to 0.9',
                             cmd.atmosphere, scatter='-1')
            self.assertError(r'seed=1000001 is out of range 0 to 1000000',
                             cmd.atmosphere, seed=1000001)
            self.assertError(r"unknown field 'fog' \(fields: haze, dust, "
                             r"dust_size, dust_speed, scatter, seed\)",
                             cmd.atmosphere, fog=1)
            self.assertError(r'seed=7.5 is not a whole number',
                             cmd.atmosphere, seed='7.5')
            self.assertError(r'seed=7.5 is not a whole number',
                             cmd.atmosphere, seed=7.5)
            self.assertError(r'haze=abc is not a number', cmd.atmosphere,
                             haze='abc')
            self.assertError(r'haze=nan is not a finite number',
                             cmd.atmosphere, haze='nan')
            self.assertError(r'haze=True: a number is needed',
                             cmd.atmosphere, haze=True)
            self.assertError(r'haze= needs a value', cmd.atmosphere, haze='')
            # all fields are checked before anything changes
            self.assertError(r'dust=2 is out of range', cmd.atmosphere,
                             haze=0.5, dust=2)
            self.assertError(r'orbit is a light field', cmd.atmosphere,
                             orbit=3)
            self.assertError(r'ambient is a rig field: lights ambient=0.2',
                             cmd.atmosphere, ambient=0.2)
            self.assertError(r"unknown keyword 'on'", cmd.atmosphere, 'on')
            self.assertError(r'off takes no fields', cmd.atmosphere, 'off',
                             haze=0.1)
            self.assertError(r'too many arguments', cmd.atmosphere, 'off',
                             'x')
            self.assertError(r'haze is given twice', cmd.atmosphere,
                             haze=0.1, HAZE=0.2)

    def testSeedIsAnInt(self):
        for value in (7, '7', 7.0, '+7'):
            cmd.atmosphere(seed=value)
            seed = cmd.get_lights()['air']['seed']
            self.assertEqual(seed, 7)
            self.assertIs(type(seed), int)

    def testCommaHint(self):
        message = self.assertError(
            r"haze=0.3 dust=0.5 is not a number; separate arguments with "
            r"commas: atmosphere haze=0.3, dust=0.5", cmd.atmosphere,
            haze='0.3 dust=0.5')
        self.assertTrue(message)
        # the same through the parser, which hands that text to haze=
        text = do('atmosphere haze=0.3 dust=0.5')
        self.assertIn('separate arguments with commas', text)
        self.assertIsNone(cmd.get_lights())
        self.assertError(r'separate arguments with commas', cmd.lights,
                         ambient='0.2 classic=0.5')
        self.assertError(r"'off haze=0': separate arguments with commas",
                         cmd.atmosphere, 'off haze=0')

    def testNoteWhileTheRigIsOff(self):
        cmd.lights('three_point')
        _, text = output(cmd.atmosphere, haze=0.2, quiet=0)
        self.assertNotIn('shows only while', text)
        cmd.lights('off')
        _, text = output(cmd.atmosphere, haze=0.3, quiet=0)
        self.assertIn('the air shows only while the lights are on', text)
        _, text = output(cmd.atmosphere, haze=0.3, quiet=1)
        self.assertEqual(text, '')


# --- per-light edits (part 2) -----------------------------------------------

@contextlib.contextmanager
def recorded_steps(fail_at=None):
    """Record the post-steps (lighting._light_set calls) a command runs;
    with `fail_at`, that call raises as C++ would."""
    original = lighting._light_set
    calls = []

    def wrapper(index, field, value, *, _self=cmd):
        calls.append((index, field, value))
        if fail_at is not None and len(calls) == fail_at:
            raise CmdException('bad value: boom')
        return original(index, field, value, _self=_self)

    lighting._light_set = wrapper
    try:
        yield calls
    finally:
        lighting._light_set = original


class TestAddEditRemove(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()

    def testAddWithFields(self):
        # spec section 5's example, through the parser
        do('lights add, rim, orbit=160, pitch=30, color=cyan, intensity=2')
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual(rig['lights'], [dict(
            DEFAULT_LIGHT, name='rim', orbit=160.0, pitch=30.0,
            color=list(cmd.get_color_tuple('cyan')), intensity=2.0)])
        centre, size = closed_frame()
        self.assertVec(rig['centre'], centre)

    def testAddReturnsTheName(self):
        result, text = output(cmd.lights, 'add', beam=20, quiet=0)
        self.assertEqual(result, 'key')
        self.assertIn("added 'key'", text)
        self.assertIn('beam 20', text)
        self.assertEqual(cmd.lights('add', name='spot', shadow=1), 'spot')
        self.assertEqual(cmd.lights('add', 'Top', softness='0.1'), 'Top')
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']],
                         ['key', 'spot', 'Top'])
        self.assertEqual(rig['lights'][0]['beam'], 20.0)
        self.assertIs(rig['lights'][1]['shadow'], True)
        self.assertEqual(rig['lights'][2]['softness'], 0.1)

    def testEdit(self):
        cmd.lights('three_point')
        before = cmd.get_lights()
        result, text = output(cmd.lights, 'KEY', beam=30, softness='0.2',
                              intensity='2', falloff=1, outline='on',
                              quiet=0)
        self.assertIsNone(result)
        self.assertIn("edited 'key' (beam, softness, intensity, falloff, "
                      "outline)", text)
        self.assertIn('beam 30, softness 0.2', text)
        rig = cmd.get_lights()
        want = copy.deepcopy(before)
        want['lights'][0].update(beam=30.0, softness=0.2, intensity=2.0,
                                 falloff=1.0, outline=True)
        self.assertEqual(rig, want)
        # quiet: no output
        _, text = output(cmd.lights, 'key', beam=31)
        self.assertEqual(text, '')

    def testEditThroughTheParser(self):
        cmd.lights('three_point')
        do('lights fill, orbit=-45, pitch=35, shadow=1, cue=1')
        fill = light('fill')
        self.assertEqual((fill['orbit'], fill['pitch'], fill['shadow'],
                          fill['outline']), (-45.0, 35.0, True, True))

    def testRename(self):
        cmd.lights('three_point')
        before = light('key')
        _, text = output(cmd.lights, 'key', name='main', quiet=0)
        self.assertIn("edited 'main' (name)", text)
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['main', 'fill', 'rim'])
        self.assertEqual(dict(light('main'), name='key'), before)
        # a light may change the case of its own name
        cmd.lights('MAIN', name='Main')
        self.assertEqual(cmd.get_lights()['lights'][0]['name'], 'Main')
        # rename together with other fields
        do('lights main, name=key2, beam=33')
        self.assertEqual(light('key2')['beam'], 33.0)
        self.assertError(r"lights: key2: a light named 'fill' already exists",
                         cmd.lights, 'key2', name='FILL')
        self.assertError(r"lights: key2: 'neon' is a preset", cmd.lights,
                         'key2', name='neon')
        self.assertError(r"lights: key2: name= needs a value", cmd.lights,
                         'key2', name='')

    def testSixLightCap(self):
        for i in range(6):
            cmd.lights('add', beam=10 + i)
        self.assertError(r'add: the rig already has 6 lights', cmd.lights,
                         'add', beam=20)

    def testFirstLightCapturesTheFrame(self):
        # an atmosphere rig has no frame; the first light (pinned and
        # placed) captures it, then the pin step uses it
        cmd.atmosphere(haze=0.3)
        self.assertIsNone(cmd.get_lights()['centre'])
        cmd.lights('add', 'key', orbit=40, pin=1)
        rig = cmd.get_lights()
        centre, size = closed_frame()
        self.assertVec(rig['centre'], centre)
        self.assertAlmostEqual(rig['size'], size, places=5)
        self.assertIs(rig['enabled'], True)
        self.assertEqual(rig['lights'][0]['anchor'], 'pinned')
        self.assertAlmostEqual(eye('key')['orbit'], 40.0, places=4)
        self.assertAlmostEqual(eye('key')['pitch'], 30.0, places=4)
        self.assertEqual(rig['air']['haze'], 0.3)

    def testAddEnabledRule(self):
        # Q7: an off rig stays off; a rig with no lights turns on
        cmd.lights('three_point')
        cmd.lights('off')
        cmd.lights('add', 'extra', beam=20, shadow=1)
        self.assertIs(cmd.get_lights()['enabled'], False)
        cmd.lights('clear')
        cmd.lights('add', 'solo', intensity=2)
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], True)
        self.assertEqual(rig['lights'][0]['intensity'], 2.0)

    def testEditKeepsTheFrameAndTheRest(self):
        cmd.lights('three_point')
        cmd.atmosphere(haze=0.2)
        before = cmd.get_lights()
        cmd.translate([0.0, 30.0, 0.0], 'm', camera=0)
        cmd.lights('rim', intensity=3)
        rig = cmd.get_lights()
        self.assertEqual(rig['centre'], before['centre'])
        self.assertEqual(rig['size'], before['size'])
        self.assertEqual(rig['air'], before['air'])
        self.assertEqual(rig['lights'][:2], before['lights'][:2])


class TestFieldsAndAliases(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()
        cmd.lights('three_point')

    def testEveryStoredField(self):
        cases = [
            ('orbit', '-30', -30.0), ('pitch', '-20', -20.0),
            ('radius', '2.5', 2.5), ('beam', '100', 100.0),
            ('softness', '0.9', 0.9), ('warmth', '3000', 3000.0),
            ('intensity', '3.5', 3.5), ('highlight', '0.7', 0.7),
            ('falloff', '0.5', 0.5), ('shadow', 'off', False),
            ('outline', 'yes', True), ('color', 'red', [1.0, 0.0, 0.0]),
        ]
        for field, text, stored in cases:
            cmd.lights('key', **{field: text})
            self.assertEqual(light('key')[field], stored, field)
            do('lights fill, %s=%s' % (field, text))
            self.assertEqual(light('fill')[field], stored, field)

    def testAliases(self):
        cases = [
            ('az', '-30', 'orbit', -30.0), ('el', '-20', 'pitch', -20.0),
            ('dist', '2.5', 'radius', 2.5), ('soft', '0.9', 'softness', 0.9),
            ('int', '3.5', 'intensity', 3.5),
            ('spec', '0.7', 'highlight', 0.7), ('cue', '1', 'outline', True),
            ('kelvin', '3000', 'warmth', 3000.0),
            ('colour', 'blue', 'color', [0.0, 0.0, 1.0]),
        ]
        for alias, text, field, stored in cases:
            before = light('rim')
            do('lights rim, %s=%s' % (alias, text))
            self.assertEqual(light('rim'), dict(before, **{field: stored}),
                             alias)
        cmd.lights('rim', AZ=10)              # names ignore case
        self.assertEqual(light('rim')['orbit'], 10.0)

    def testBoolSpellings(self):
        for value in ('1', 'on', 'true', 'yes', 'On', 'TRUE', 'Yes', True,
                      1):
            cmd.lights('rim', outline=0)
            cmd.lights('rim', outline=value)
            self.assertIs(light('rim')['outline'], True, value)
        for value in ('0', 'off', 'false', 'no', 'OFF', 'No', False, 0):
            cmd.lights('rim', outline=1)
            cmd.lights('rim', outline=value)
            self.assertIs(light('rim')['outline'], False, value)
        for value in ('maybe', '2', 2, ''):
            self.assertError(r"rim: outline=%s: use 1/0, on/off" % value,
                             cmd.lights, 'rim', outline=value)

    def testOrbitWraps(self):
        for value, stored in ((200, -160.0), ('-190', 170.0), (540, 180.0),
                              (-180, 180.0), ('720', 0.0), (180, 180.0)):
            cmd.lights('key', orbit=value)
            self.assertEqual(light('key')['orbit'], stored, value)

    def testHighlightNumberIsTheStrength(self):
        # Q4: a number is the strength, spec= always is
        for value, stored in (('0.7', 0.7), (0.25, 0.25), ('1', 1.0),
                              (0, 0.0)):
            cmd.lights('key', highlight=value)
            self.assertEqual(light('key')['highlight'], stored)
        cmd.lights('key', spec=0.4)
        self.assertEqual(light('key')['highlight'], 0.4)
        self.assertError(r'key: highlight=1.5 is out of range 0 to 1',
                         cmd.lights, 'key', highlight='1.5')
        self.assertError(r'key: spec=organic is not a number', cmd.lights,
                         'key', spec='organic')

    def testOutOfRange(self):
        # Q2: an error naming the field, the value and the range
        cases = [
            ('pitch', '91', r'-90 to 90 \(degrees\)'),
            ('el', '-90.5', r'-90 to 90 \(degrees\)'),
            ('radius', '0.4', r'0\.5 to 8 \(scene sizes\)'),
            ('dist', '8.1', r'0\.5 to 8 \(scene sizes\)'),
            ('beam', '0.5', r'1 to 170 \(degrees\)'),
            ('beam', '171', r'1 to 170 \(degrees\)'),
            ('softness', '1.01', r'0 to 1'),
            ('soft', '-0.1', r'0 to 1'),
            ('warmth', '1499', r'1500 to 15000 \(kelvin\)'),
            ('kelvin', '15001', r'1500 to 15000 \(kelvin\)'),
            ('intensity', '4.5', r'0 to 4'),
            ('int', '-1', r'0 to 4'),
            ('highlight', '-0.5', r'0 to 1'),
            ('spec', '2', r'0 to 1'),
            ('falloff', '2.5', r'0 to 2'),
        ]
        for field, value, bounds in cases:
            self.assertError(r'lights: key: %s=%s is out of range %s' % (
                field, re.escape(value), bounds), cmd.lights, 'key',
                **{field: value})

    def testBoundsAreInclusive(self):
        cases = [('beam', 1.0), ('beam', 170.0), ('pitch', -90.0),
                 ('pitch', 90.0), ('radius', 0.5), ('radius', 8.0),
                 ('softness', 0.0), ('softness', 1.0), ('warmth', 1500.0),
                 ('warmth', 15000.0), ('intensity', 0.0),
                 ('intensity', 4.0), ('highlight', 0.0),
                 ('highlight', 1.0), ('falloff', 0.0), ('falloff', 2.0)]
        for field, value in cases:
            do('lights key, %s=%s' % (field, num(value)))
            self.assertEqual(light('key')[field], value, field)

    def testNanAndInfAreRefused(self):
        for field, value in (('orbit', 'nan'), ('beam', 'inf'),
                             ('intensity', float('nan')),
                             ('orbit', float('inf')), ('pitch', '-inf')):
            self.assertError(r'key: %s=\S+ is not a finite number' % field,
                             cmd.lights, 'key', **{field: value})
        self.assertError(r"key: rgb=1/nan/0: each value must be a finite",
                         cmd.lights, 'key', rgb='1/nan/0')
        self.assertError(r"key: position=\[1,inf,3\]: each value must be",
                         cmd.lights, 'key', position=[1, float('inf'), 3])

    def testPythonValues(self):
        cmd.lights('key', beam=20, shadow=False, outline=True,
                   rgb=(1, 0.5, 0), aim=[1, 2, 3])
        key = light('key')
        self.assertEqual((key['beam'], key['shadow'], key['outline']),
                         (20.0, False, True))
        self.assertEqual(key['color'], [1.0, 0.5, 0.0])
        self.assertEqual((key['aim'], key['aim_point']), ('point',
                                                           [1.0, 2.0, 3.0]))
        self.assertError(r'key: beam=True: a number is needed', cmd.lights,
                         'key', beam=True)


class TestColour(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()
        cmd.lights('three_point')

    def colour(self, value, field='color'):
        cmd.lights('rim', **{field: value})
        return light('rim')['color']

    def testNamesIgnoreCase(self):
        for value in ('red', 'Red', 'RED', ' red '):
            cmd.lights('rim', color='white')
            self.assertEqual(self.colour(value), [1.0, 0.0, 0.0], value)

    def testUniquePrefix(self):
        for prefix, name in (('oran', 'orange'), ('FORES', 'forest'),
                             ('cya', 'cyan')):
            self.assertEqual(self.colour(prefix),
                             list(cmd.get_color_tuple(name)), prefix)

    def testAmbiguousPrefix(self):
        for value in ('GRE', 'gre'):
            self.assertError(r'rim: color=%s is ambiguous: green, grey, '
                             r'grey00, .* and \d+ more' % value,
                             cmd.lights, 'rim', color=value)

    def testDigitNames(self):
        # grey80 is only in get_color_indices(all=1), not in mode 1
        self.assertEqual(self.colour('grey80'),
                         list(cmd.get_color_tuple('grey80')))
        self.assertError(r'rim: color=grey8 is ambiguous: grey80, grey81',
                         cmd.lights, 'rim', color='grey8')

    def testUnknownAndRamp(self):
        self.assertError(r"rim: color=blurple is not a PyMOL colour",
                         cmd.lights, 'rim', color='blurple')
        cmd.ramp_new('heat', 'm', [0, 1], ['red', 'blue'])
        self.assertError(r'rim: color=heat is a colour ramp', cmd.lights,
                         'rim', color='heat')
        self.assertError(r'rim: color=red intensity=2 is not a PyMOL '
                         r'colour; separate arguments with commas',
                         cmd.lights, 'rim', color='red intensity=2')

    def testSpecialColoursAndIndicesWriteNothing(self):
        # Color.cpp: an exact "auto" and the index -2 call ColorGetNext,
        # which writes the setting auto_color_next: the resolver refuses
        # them as text, before any C++ call
        snap = Snapshot()
        before = snap.take()
        auto_next = cmd.get('auto_color_next')
        cases = [
            ('auto', r'special colours have no RGB value'),
            ('AUTO', r'special colours have no RGB value'),
            ('au', r'is not a PyMOL colour'),
            ('current', r'special colours'), ('default', r'special colours'),
            ('atomic', r'special colours'), ('object', r'special colours'),
            ('front', r'special colours'), ('back', r'special colours'),
            ('-2', r'colour indices are not accepted'),
            ('5', r'colour indices are not accepted'),
            ('-1', r'colour indices are not accepted'),
            ('0x12', r'is not a hex colour'),
            ('0xff88zz', r'is not a hex colour'),
        ]
        for value, pattern in cases:
            for field in ('color', 'colour'):
                self.assertError(r'rim: %s=%s(:| ).*%s' % (
                    field, re.escape(value), pattern), cmd.lights, 'rim',
                    **{field: value})
                do('lights rim, %s=%s' % (field, value))
        self.assertError(r'rim: color=5: colour indices', cmd.lights, 'rim',
                         color=5)
        self.assertEqual(cmd.get('auto_color_next'), auto_next)
        self.assertEqual(snap.take(), before)

    def testHex(self):
        for value in ('0xff8800', '0XFF8800'):
            got = self.colour(value)
            self.assertEqual(got, [1.0, 0x88 / 255.0, 0.0], value)

    def testRgb(self):
        cases = [('1/0.5/0', [1.0, 0.5, 0.0]),
                 ('255/128/0', [1.0, 128 / 255.0, 0.0]),
                 ('[1,0.5,0]', [1.0, 0.5, 0.0]),
                 ('[ 0.25, 0.5, 1 ]', [0.25, 0.5, 1.0]),
                 ('(0,0,1)', [0.0, 0.0, 1.0]),
                 ((0, 128, 255), [0.0, 128 / 255.0, 1.0]),
                 ([0.1, 0.2, 0.3], [0.1, 0.2, 0.3])]
        for value, stored in cases:
            self.assertVec(self.colour(value, 'rgb'), stored, places=12,
                           msg=value)
        for value, pattern in (('1.5/0/0', r'each value is 0 to 1, or all '
                                           r'are whole numbers 0 to 255'),
                               ('256/0/0', r'each value is 0 to 1'),
                               ('-1/0/0', r'each value is 0 to 1'),
                               ('1/2', r'give r/g/b or \[r,g,b\]'),
                               ('1/0/0/0', r'give r/g/b'),
                               ('a/b/c', r"'a' is not a number"),
                               ('red', r'give r/g/b')):
            self.assertError(r'rim: rgb=%s: %s' % (re.escape(value), pattern),
                             cmd.lights, 'rim', rgb=value)

    def testColourTriple(self):
        self.assertEqual(self.colour('1/0.5/0'), [1.0, 0.5, 0.0])
        self.assertEqual(self.colour('[0,1,0]', 'colour'), [0.0, 1.0, 0.0])
        self.assertEqual(self.colour((0.0, 0.0, 1.0)), [0.0, 0.0, 1.0])

    def testWarmthIsStoredAndLeavesTheColour(self):
        cmd.lights('rim', color='red')
        cmd.lights('rim', warmth=3200)
        self.assertEqual((light('rim')['color'], light('rim')['warmth']),
                         ([1.0, 0.0, 0.0], 3200.0))
        do('lights rim, kelvin=9000')
        self.assertEqual((light('rim')['color'], light('rim')['warmth']),
                         ([1.0, 0.0, 0.0], 9000.0))

    def testColourWords(self):
        # color=warm/neutral/cool: white with 3200/6500/9000 K, never
        # PyMOL's warmpink (which 'warm' is a unique prefix of)
        warmpink = list(cmd.get_color_tuple('warmpink'))
        for word, kelvin in (('warm', 3200.0), ('neutral', 6500.0),
                             ('cool', 9000.0), ('WARM', 3200.0)):
            cmd.lights('rim', color='red', warmth=12000)
            do('lights rim, color=%s' % word)
            rim = light('rim')
            self.assertEqual((rim['color'], rim['warmth']),
                             ([1.0, 1.0, 1.0], kelvin), word)
            self.assertNotEqual(rim['color'], warmpink)
        # spec section 5's example
        do('lights key, orbit=-45, pitch=35, color=warm')
        key = light('key')
        self.assertEqual((key['orbit'], key['pitch'], key['color'],
                          key['warmth']), (-45.0, 35.0, [1.0, 1.0, 1.0],
                                           3200.0))
        self.assertError(r'rim: color=warm sets white with warmth 3200 K: '
                         r'give warmth= or color=, not both', cmd.lights,
                         'rim', color='warm', warmth=4000)
        self.assertError(r'rim: colour=cool sets white with warmth 9000 K',
                         cmd.lights, 'rim', colour='cool', kelvin=4000)

    def testColorAndRgbConflict(self):
        self.assertError(r'rim: color= and rgb= both set the colour',
                         cmd.lights, 'rim', color='red', rgb='1/0/0')
        self.assertError(r'rim: colour= and rgb= both set the colour',
                         cmd.lights, 'rim', colour='red', rgb='1/0/0')
        self.assertError(r'rim: color is given twice \(color= and colour=\)',
                         cmd.lights, 'rim', color='red', colour='blue')

    def testUserColourAndSetColorLater(self):
        # a colour of the user's own resolves by name; the light keeps the
        # RGB it resolved to when set_color changes the colour later
        cmd.set_color('l612_teal', [0.25, 0.5, 0.75])
        cmd.lights('rim', color='L612_Teal')
        self.assertVec(light('rim')['color'], [0.25, 0.5, 0.75], places=6)
        stored = light('rim')['color']
        cmd.set_color('l612_teal', [0.9, 0.9, 0.9])
        self.assertEqual(light('rim')['color'], stored)


class TestAimAndPin(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()
        cmd.lights('three_point')
        cmd.turn('y', 35)
        cmd.turn('x', -20)

    def testAimSelection(self):
        cmd.lights('key', aim='m and not solvent')
        key = light('key')
        self.assertEqual((key['aim'], key['aim_selection']),
                         ('point', 'm and not solvent'))
        self.assertVec(key['aim_point'], PROTEIN_CENTROID, places=5)
        # resolved once: later atom moves do not change it
        cmd.translate([0.0, 5.0, 0.0], 'm', camera=0)
        self.assertEqual(light('key'), key)

    def testAimFollowsTheObjectMatrix(self):
        # the centroid is in world space, as the frame capture and the pick
        cmd.translate([10.0, 0.0, 0.0], 'm', camera=0, object='m')
        self.assertTrue(cmd.get_object_matrix('m') != [
            1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0])
        cmd.lights('key', aim='resi 1')
        want = [PROTEIN_CENTROID[0] + 10.0] + PROTEIN_CENTROID[1:]
        self.assertVec(light('key')['aim_point'], want, places=5)
        mn, mx = cmd.get_extent('resi 1')
        self.assertVec(light('key')['aim_point'],
                       [(a + b) / 2.0 for a, b in zip(mn, mx)], places=5)

    def testAimCentre(self):
        cmd.lights('key', aim='resi 1')
        for word in ('centre', 'CENTER'):
            cmd.lights('key', aim=word)
            key = light('key')
            self.assertEqual((key['aim'], key['aim_selection']),
                             ('centre', ''))
            cmd.lights('key', aim='resi 1')

    def testAimPoint(self):
        for value in ('1/2/3', '[1,2,3]', '[ 1, 2, 3 ]', [1, 2, 3],
                      (1.0, 2.0, 3.0), ' 1 / 2 / 3 '):
            cmd.lights('key', aim='resi 1')
            cmd.lights('key', aim=value)
            key = light('key')
            self.assertEqual((key['aim'], key['aim_point'],
                              key['aim_selection']),
                             ('point', [1.0, 2.0, 3.0], ''), value)

    def testAimSelectionErrors(self):
        # parentheses force a selection: (1/2/3) selects no atoms here
        self.assertError(r'key: aim=\(1/2/3\): the selection has no atoms',
                         cmd.lights, 'key', aim='(1/2/3)')
        self.assertError(r'key: aim=none: the selection has no atoms',
                         cmd.lights, 'key', aim='none')
        self.assertError(r'key: aim=\(\(\( is not a valid selection',
                         cmd.lights, 'key', aim='(((')
        self.assertError(r'key: aim=nosuch is not a valid selection',
                         cmd.lights, 'key', aim='nosuch')
        self.assertError(r'key: aim=\[1,2\]: give x/y/z or \[x,y,z\]',
                         cmd.lights, 'key', aim='[1,2]')
        self.assertError(r'key: aim= needs a value', cmd.lights, 'key',
                         aim='')
        self.assertError(r'key: aim=resi 1 pin=1 is not a valid selection; '
                         r'separate arguments with commas', cmd.lights,
                         'key', aim='resi 1 pin=1')

    def testPinKeepsTheEyePosition(self):
        before = eye('key')
        with recorded_steps() as calls:
            cmd.lights('key', pin=1)
        self.assertEqual(calls, [(0, 'anchor', 1)])
        key = light('key')
        self.assertEqual(key['anchor'], 'pinned')
        self.assertVec(eye('key')['position'], before['position'])
        # a pinned light turns with the molecules
        cmd.turn('y', 40)
        self.assertNotAlmostEqual(eye('key')['orbit'], -45.0, places=1)
        self.assertEqual(light('key')['position'], key['position'])

    def testUnpinInPlace(self):
        cmd.lights('key', pin=1)
        cmd.turn('y', 40)
        before = eye('key')
        with recorded_steps() as calls:
            cmd.lights('key', pin=0)
        self.assertEqual(calls, [(0, 'anchor', 0)])
        key = light('key')
        self.assertEqual(key['anchor'], 'camera')
        self.assertVec(eye('key')['position'], before['position'])
        self.assertVec([key['orbit'], key['pitch'], key['radius']],
                       [before['orbit'], before['pitch'], before['radius']])

    def testAnchorWords(self):
        cmd.lights('key', anchor='PINNED')
        self.assertEqual(light('key')['anchor'], 'pinned')
        do('lights key, anchor=camera')
        self.assertEqual(light('key')['anchor'], 'camera')
        self.assertError(r'key: anchor=world: use camera or pinned',
                         cmd.lights, 'key', anchor='world')

    def testOrbitOnAPinnedLightRepins(self):
        cmd.lights('key', pin=1)
        with recorded_steps() as calls:
            cmd.lights('key', orbit=30)
        self.assertEqual(calls, [(0, 'orbit', 30.0)])
        self.assertEqual(light('key')['anchor'], 'pinned')
        self.assertAlmostEqual(eye('key')['orbit'], 30.0, places=4)

    def testOrbitAndPitchOnAPinnedLight(self):
        cmd.lights('key', pin=1)
        radius = eye('key')['radius']
        # the steps run orbit, pitch, radius whatever the typed order
        with recorded_steps() as calls:
            cmd.lights('key', pitch=20, orbit='390')
        self.assertEqual([c[1] for c in calls], ['orbit', 'pitch'])
        e = eye('key')
        self.assertVec([e['orbit'], e['pitch'], e['radius']],
                       [30.0, 20.0, radius])
        self.assertEqual(light('key')['anchor'], 'pinned')
        cmd.lights('key', radius=2, pitch=-10, orbit=-100)
        e = eye('key')
        self.assertVec([e['orbit'], e['pitch'], e['radius']],
                       [-100.0, -10.0, 2.0])

    def testPinWithOrbitPlacesThenPins(self):
        with recorded_steps() as calls:
            cmd.lights('key', pin=1, orbit=60, radius=3)
        self.assertEqual(calls, [(0, 'anchor', 1)])     # orbit is in the dict
        e = eye('key')
        self.assertEqual(light('key')['anchor'], 'pinned')
        self.assertVec([e['orbit'], e['pitch'], e['radius']],
                       [60.0, 35.0, 3.0])

    def testUnpinFirstThenPlace(self):
        cmd.lights('key', pin=1)
        cmd.turn('y', 40)
        with recorded_steps() as calls:
            cmd.lights('key', radius=2, pin=0)
        self.assertEqual([c[1] for c in calls], ['anchor', 'radius'])
        key = light('key')
        self.assertEqual((key['anchor'], key['radius']), ('camera', 2.0))

    def testPositionPins(self):
        with recorded_steps() as calls:
            cmd.lights('key', position='[1,2,3]')
        self.assertEqual(calls, [])
        key = light('key')
        self.assertEqual((key['anchor'], key['position']),
                         ('pinned', [1.0, 2.0, 3.0]))
        for value in ('4/5/6', (4, 5, 6), '(4,5,6)'):
            cmd.lights('key', position=value, pin=1)
            self.assertEqual(light('key')['position'], [4.0, 5.0, 6.0])
        do('lights fill, position=[1,2,3], anchor=pinned')
        self.assertEqual(light('fill')['anchor'], 'pinned')

    def testPositionConflicts(self):
        self.assertError(r'key: position= and pin= disagree: position= pins',
                         cmd.lights, 'key', position='1/2/3', pin=0)
        self.assertError(r'key: position= and anchor= disagree', cmd.lights,
                         'key', position='1/2/3', anchor='camera')
        for field in ('orbit', 'pitch', 'radius', 'az', 'dist'):
            self.assertError(r'key: position= and %s= both place the light'
                             % field, cmd.lights, 'key', position='1/2/3',
                             **{field: 1})
        self.assertError(r'key: position=1/2: give x/y/z or \[x,y,z\]',
                         cmd.lights, 'key', position='1/2')


class TestErrors(CommandsCase):
    """Every message names the field or value, and nothing changes."""

    def setUp(self):
        super().setUp()
        self.load()
        cmd.lights('three_point')
        cmd.atmosphere(haze=0.2)

    def testFieldErrors(self):
        message = self.assertError(r"lights: key: unknown field 'fog' "
                                   r"\(rig: ambient, classic; light: ",
                                   cmd.lights, 'key', fog=1)
        self.assertIn('placement: target, highlight, click, rim', message)
        self.assertError(r'key: beam=abc is not a number', cmd.lights, 'key',
                         beam='abc')
        self.assertError(r'key: shadow=maybe: use 1/0', cmd.lights, 'key',
                         shadow='maybe')
        self.assertError(r'key: color=blurple is not a PyMOL colour',
                         cmd.lights, 'key', color='blurple')
        self.assertError(r'key: rgb=2/0: give r/g/b', cmd.lights, 'key',
                         rgb='2/0')
        self.assertError(r'key: ambient is a rig field: lights ambient=0.3',
                         cmd.lights, 'key', ambient=0.3)
        self.assertError(r'key: haze is an atmosphere field: atmosphere '
                         r'haze=0.3', cmd.lights, 'key', haze=0.3)
        self.assertError(r'key: aim_point is set by aim=', cmd.lights, 'key',
                         aim_point=[1, 2, 3])
        self.assertError(r'key: aim_selection is set by aim=', cmd.lights,
                         'key', aim_selection='x')
        self.assertError(r"key: enabled is set by 'lights on'", cmd.lights,
                         'key', enabled=1)
        self.assertError(r'key: centre is captured', cmd.lights, 'key',
                         centre=[0, 0, 0])
        self.assertError(r'key: size is captured', cmd.lights, 'key', size=3)
        self.assertError(r'key: orbit= needs a value', cmd.lights, 'key',
                         orbit='')

    def testNames(self):
        for name, pattern in (('add', r"'add' is a keyword"),
                              ('OFF', r"'OFF' is a keyword"),
                              ('three_point', r"'three_point' is a preset"),
                              ('Neon', r"'Neon' is a preset"),
                              ('1key', r"name '1key' is not valid"),
                              ('a' * 33, r"name 'a{33}' is not valid"),
                              ('ké', r"name 'ké' is not valid"),
                              ('KEY', r"a light named 'key' already exists"),
                              ('Fill', r"a light named 'fill' already "
                                       r"exists")):
            self.assertError(r'lights: rim: ' + pattern, cmd.lights, 'rim',
                             name=name)
            if name not in ('KEY', 'Fill'):
                self.assertError(r'lights: add: ' + pattern, cmd.lights,
                                 'add', name)
        self.assertError(r"lights: add: a light named 'key' already exists",
                         cmd.lights, 'add', 'KEY', beam=20)

    def testUnknownLight(self):
        self.assertError(r"no light, preset or keyword named 'nosuch'.*to "
                         r"add one: lights add, nosuch", cmd.lights,
                         'nosuch', orbit=3)

    def testCaps(self):
        for i in range(3):
            cmd.lights('add', beam=10 + i)
        self.assertError(r'add: the rig already has 6 lights', cmd.lights,
                         'add', shadow=1)
        cmd.lights('fill', shadow=1)
        cmd.lights('rim', shadow='on')
        self.assertError(r'lights: light4: shadow=1: at most 3 lights cast '
                         r'shadows \(key, fill, rim already do\)',
                         cmd.lights, 'light4', shadow=1)
        cmd.lights('remove', 'light6')
        self.assertError(r'lights: add: shadow=yes: at most 3 lights cast '
                         r'shadows', cmd.lights, 'add', shadow='yes')
        # a light that already casts one can be edited
        cmd.lights('key', shadow=1, beam=50)
        self.assertEqual(light('key')['beam'], 50.0)

    def testConflicts(self):
        cases = [
            (dict(color='red', rgb='1/0/0'), r'color= and rgb= both set'),
            (dict(pin=1, anchor='pinned'), r'pin= and anchor= both set the '
                                           r'anchor'),
            (dict(highlight=0.7, spec=0.5), r'highlight is given twice'),
            (dict(orbit=3, az=4), r'orbit is given twice \(orbit= and az=\)'),
            (dict(position='1/2/3', pin=0), r'position= and pin= disagree'),
            (dict(position='1/2/3', radius=2), r'position= and radius= both'),
            (dict(aim='centre', target='resi 1'), r'aim= and target= both '
                                                  r'set the aim'),
            (dict(target='resi 1', click='0/0'), r'target=, click=: give '
                                                 r'one placement helper'),
            (dict(click='0/0', highlight='resi 1'), r'click=, highlight=: '
                                                    r'give one'),
            (dict(click='0/0', orbit=3), r'orbit= and click= both place the '
                                         r'light'),
            (dict(highlight='resi 1', el=3), r'el= and highlight= both place'),
            (dict(click='0/0', position='1/2/3'), r'position= and click= '
                                                  r'both place'),
            (dict(rim=30), r'rim= needs click= or highlight='),
            (dict(rim=30, target='resi 1'), r'rim= needs click='),
            (dict(color='warm', warmth=4000), r'color=warm sets white'),
        ]
        for fields, pattern in cases:
            self.assertError(r'lights: key: ' + pattern, cmd.lights, 'key',
                             **fields)

    def testArguments(self):
        self.assertError(r"too many arguments: 'rim' after the light 'key'",
                         cmd.lights, 'key', 'rim', orbit=3)
        self.assertError(r"'key orbit=-45': separate arguments with commas",
                         cmd.lights, 'key orbit=-45')
        text = do('lights key orbit=-45')
        self.assertIn('separate arguments with commas', text)
        text = do('lights key, orbit=-45 pitch=35')
        self.assertIn('orbit=-45 pitch=35 is not a number; separate '
                      'arguments with commas', text)
        self.assertEqual(light('key')['orbit'], -45.0)    # unchanged preset
        self.assertError(r'off takes no arguments', cmd.lights, 'off',
                         orbit=3)
        self.assertError(r'remove: takes only a light name', cmd.lights,
                         'remove', 'key', beam=3)

    def testMixedValidAndInvalid(self):
        before = light('key')
        self.assertError(r'key: beam=abc is not a number', cmd.lights, 'key',
                         intensity=2, beam='abc')
        self.assertEqual(light('key'), before)
        do('lights key, intensity=2, color=nosuchcolour')
        self.assertEqual(light('key'), before)

    def testPhase2FailureRollsBack(self):
        # a pinned light: orbit and pitch are two re-pin steps after
        # set_lights; make the second fail and the rig must be as it was
        cmd.lights('key', pin=1)
        before = cmd.get_lights()
        with recorded_steps(fail_at=2) as calls:
            message = self.assertUnchanged(before, cmd.lights, 'key',
                                           orbit=30, pitch=20, beam=20)
        self.assertEqual([c[1] for c in calls], ['orbit', 'pitch'])
        self.assertIn('lights: key: pitch: boom', message)
        # unpin first: the failing radius step comes after the unpin
        with recorded_steps(fail_at=2) as calls:
            message = self.assertUnchanged(before, cmd.lights, 'key',
                                           pin=0, radius=2, name='main')
        self.assertEqual([c[1] for c in calls], ['anchor', 'radius'])
        self.assertIn('lights: main: radius: boom', message)
        # an add rolls back to no new light
        with recorded_steps(fail_at=1):
            message = self.assertUnchanged(before, cmd.lights, 'add',
                                           'extra', pin=1)
        self.assertIn('lights: extra: pin: boom', message)

    def testPhase2FailureWithNoRig(self):
        lighting.set_lights(None)
        with recorded_steps(fail_at=1):
            self.assertUnchanged(None, cmd.lights, 'add', 'key', pin=1)
        self.assertIsNone(cmd.get_lights())


# --- docs -------------------------------------------------------------------

class TestDocs(testing.PyMOLTestCase):
    """The command docs list every field of the C++ field table: a new field
    fails here until it is documented."""

    def field_line(self, doc, name):
        for line in doc.splitlines():
            if re.match(r'^\s+%s(\s|\(|$)' % re.escape(name), line):
                return line
        return None

    def testEveryFieldIsDocumented(self):
        lights_doc = cmd.lights.__doc__
        atmo_doc = cmd.atmosphere.__doc__
        for scope, name, kind, default, lo, hi in lighting._light_fields():
            doc = atmo_doc if scope == 'air' else lights_doc
            line = self.field_line(doc, name)
            self.assertIsNotNone(line, (scope, name))
            if lo is not None:
                self.assertIn(num(lo), line, (name, line))
                self.assertIn(num(hi), line, (name, line))
                self.assertRegex(line, r'(^|\D)%s to %s(\D|$)' % (
                    re.escape(num(lo)), re.escape(num(hi))), name)

    def testAliasesPresetsKeywordsHelpers(self):
        doc = cmd.lights.__doc__
        for alias in ALIASES:
            self.assertRegex(doc, r'\(%s\)' % alias, alias)
        for name, description, _, _ in PRESETS:
            self.assertRegex(doc, r'\n\s+%s\s+%s\n' % (
                re.escape(name), re.escape(description)), name)
        for keyword in KEYWORDS:
            self.assertRegex(doc, r'\n    %s\s' % keyword, keyword)
        for helper in HELPERS:
            self.assertRegex(doc, r'\n    %s=' % helper, helper)
        for extra in ('rgb', 'pin'):
            self.assertIsNotNone(self.field_line(doc, extra), extra)

    def testColourWords(self):
        # color=warm/neutral/cool set white with warmth 3200/6500/9000 K, so
        # spec section 5's example never resolves to PyMOL's warmpink
        doc = cmd.lights.__doc__
        self.assertIn('color=warm, neutral', doc)
        self.assertIn('3200, 6500 or 9000 K', doc)
        self.assertIn('lights key, orbit=-45, pitch=35, color=warm', doc)

    def testNotes(self):
        doc = cmd.lights.__doc__
        for text in ('Metal renderer', 'never write a setting',
                     'changes nothing', 'skips the rest of the line',
                     'empty rig that is off', '"at"', 'recenter'):
            self.assertIn(text, doc)
        self.assertIn('SEE ALSO', doc)
        self.assertIn('creates a rig that is off', cmd.atmosphere.__doc__)

    def testAscii(self):
        for func in (cmd.lights, cmd.atmosphere):
            func.__doc__.encode('ascii')
            self.assertNotIn('\t', func.__doc__)
            for line in func.__doc__.splitlines():
                self.assertLessEqual(len(line), 79, line)


# --- the harness path -------------------------------------------------------

class TestHarnessPath(CommandsCase):
    """scripts/lighting/render.py (frozen) reaches the 'rig off' state with
    cmd.keyword['lights'][0]('three_point') and then ('off') once 'lights'
    is a keyword."""

    def testKeywordPath(self):
        self.load()
        snap = Snapshot()
        before = snap.take()
        func = cmd.keyword['lights'][0]
        func('three_point')
        func('off')
        rig = cmd.get_lights()
        self.assertIs(rig['enabled'], False)
        self.assertEqual([l['name'] for l in rig['lights']],
                         ['key', 'fill', 'rim'])
        self.assertIsNone(lighting._lights_ray_notice())
        self.assertEqual(snap.take(), before)
        # run twice: the same rig (the harness checks run 1 == run 2)
        func('three_point')
        func('off')
        self.assertEqual(cmd.get_lights(), rig)

    def testSetLightsShimDoesNotRecurse(self):
        # A scene file (#613 style) wraps cmd.set_lights to call `lights`:
        # `lights` must never call cmd.set_lights itself.
        self.load()
        calls = []
        original = cmd.set_lights

        def shim(rig, **kwargs):
            calls.append(rig)
            return cmd.lights('three_point')

        cmd.set_lights = shim
        try:
            cmd.set_lights({'enabled': True})
            cmd.lights('neon')
            cmd.atmosphere(haze=0.2)
            cmd.lights('off')
        finally:
            cmd.set_lights = original
        self.assertEqual(len(calls), 1)
        rig = cmd.get_lights()
        self.assertEqual(rig['lights'][0]['name'], 'magenta')
        self.assertIs(rig['enabled'], False)

    def testPerInstance(self):
        import pymol2
        p1 = pymol2.PyMOL()
        p1.start()
        try:
            p1.cmd.read_pdbstr(_PDB, 'm')
            p1.cmd.lights('neon')
            self.assertIsNone(cmd.get_lights())         # the singleton
            names = [l['name'] for l in p1.cmd.get_lights()['lights']]
            self.assertEqual(names, ['magenta', 'cyan', 'front'])
            p1.cmd.do('lights off')
            p1.cmd.do('atmosphere haze=0.25')
            rig = p1.cmd.get_lights()
            self.assertIs(rig['enabled'], False)
            self.assertEqual(rig['air']['haze'], 0.25)
            self.assertIsNone(cmd.get_lights())
            cmd.lights('three_point')
            self.assertEqual(p1.cmd.get_lights(), rig)
            # the spotlight's aim reads p1's own camera
            p1.cmd.turn('y', 60)
            p1.cmd.lights('spotlight')
            eye = lighting._lights_eye(_self=p1.cmd)
            size = p1.cmd.get_lights()['size']
            for k in range(3):
                self.assertAlmostEqual(
                    eye['lights'][0]['target'][k],
                    eye['centre'][k] + size * SPOT_OFFSET[k], places=4)
            self.assertEqual(p1.cmd.lights('presets'),
                             lighting_commands.presets())
        finally:
            p1.stop()


# --- the transaction --------------------------------------------------------

class TestTransaction(CommandsCase):

    def testFailureAfterSetLightsRollsBack(self):
        # The spotlight's aim is a step after set_lights: make it fail and
        # the rig must be exactly what it was.
        self.load()
        original = lighting._light_set

        def failing(index, field, value, *, _self=cmd):
            raise CmdException('bad value: boom')

        for start in (None, 'three_point'):
            lighting.set_lights(None)
            if start:
                cmd.lights(start)
                cmd.atmosphere(haze=0.3)
            before = cmd.get_lights()
            lighting._light_set = failing
            try:
                message = self.assertUnchanged(before, cmd.lights,
                                               'spotlight')
            finally:
                lighting._light_set = original
            self.assertIn('lights: spot: aim: boom', message)

    def testOtherExceptionsRollBackAndPropagate(self):
        self.load()
        cmd.lights('three_point')
        before = cmd.get_lights()
        original = lighting._light_set

        def broken(index, field, value, *, _self=cmd):
            raise ZeroDivisionError('bug')

        lighting._light_set = broken
        try:
            with self.assertRaises(ZeroDivisionError):
                cmd.lights('spotlight')
        finally:
            lighting._light_set = original
        self.assertEqual(cmd.get_lights(), before)

    def testRewrite(self):
        rewrite = lighting_commands._rewrite
        self.assertEqual(
            rewrite('lights', '', '', CmdException(
                "set_lights: lights[3]: 'shadow': refused")),
            "lights: lights[3]: 'shadow': refused")
        self.assertEqual(
            rewrite('lights', 'key', 'shadow', CmdException(
                'refused: at most 3 lights cast shadows')),
            'lights: key: shadow: at most 3 lights cast shadows')
        self.assertEqual(
            rewrite('lights', 'key', 'beam', CmdException('bad value')),
            'lights: key: beam: bad value')
        self.assertEqual(
            rewrite('atmosphere', '', '', CmdException('no rig: x')),
            'atmosphere: x')
        self.assertEqual(
            rewrite('lights', '', '', CmdException('lights: already')),
            'lights: already')

    def testQuietArgument(self):
        self.load()
        _, text = output(cmd.lights, 'three_point', quiet='0')
        self.assertIn('three_point: key, fill, rim', text)
        _, text = output(cmd.lights, 'off', quiet='yes')
        self.assertEqual(text, '')
        self.assertError(r'quiet=maybe', cmd.lights, 'on', quiet='maybe')


# --- non-negotiables --------------------------------------------------------

class Snapshot(object):
    """Everything a lights command must never touch: settings (session and
    unique), atom colours, materials, extents, object names, the view."""

    def __init__(self):
        # The first get_session() writes pse_binary_dump back (CmdGetSession),
        # which adds it to the session's settings list: take that one first.
        cmd.get_session()

    def take(self):
        session = cmd.get_session()
        colors = []
        cmd.iterate('all', 'colors.append(color)', space={'colors': colors})
        with cmd.lockcm:
            shadow = _cmd.get_shadow_extent(cmd._COb)
        materials = [name for name in pymol.setting.get_name_list()
                     if name.endswith('_material')]
        return {
            'settings': session['settings'],
            'unique_settings': session.get('unique_settings'),
            'colors': colors,
            'materials': [cmd.get(name) for name in materials],
            'extent': cmd.get_extent(),
            'extent_all': cmd.get_extent('all', state=-1),
            'names': cmd.get_names('all'),
            'view': cmd.get_view(),
            'shadow': shadow,
        }


class TestNonNegotiables(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()
        cmd.show('sticks')
        cmd.color('red', 'resi 1')
        cmd.set('stick_color', 'blue', 'resi 1')
        cmd.turn('y', 30)

    def steps(self):
        """Part 1 forms; each is (label, callable). Errors are expected
        CmdExceptions."""
        return [
            ('query none', lambda: output(cmd.lights)),
            ('atmosphere none', lambda: output(cmd.atmosphere)),
            ('ambient no rig', lambda: cmd.lights(ambient=0.2)),
            ('air no rig', lambda: cmd.atmosphere(haze=0.3, dust=0.5,
                                                  seed=7)),
            ('preset', lambda: cmd.lights('three_point')),
            ('spotlight', lambda: cmd.lights('spotlight')),
            ('every preset', lambda: [cmd.lights(p) for p in PRESET_NAMES]),
            ('off', lambda: cmd.lights('off')),
            ('on', lambda: cmd.lights('on')),
            ('recenter', lambda: cmd.lights('recenter')),
            ('add', lambda: cmd.lights('add', 'extra')),
            ('remove', lambda: cmd.lights('remove', 'extra')),
            ('ambient', lambda: cmd.lights(ambient=0.7, classic=0.4)),
            ('atmosphere', lambda: cmd.atmosphere(haze=0.6, scatter=-0.2)),
            ('atmosphere off', lambda: cmd.atmosphere('off')),
            ('queries', lambda: [output(cmd.lights), output(cmd.lights, 'rim'),
                                 output(cmd.atmosphere),
                                 output(cmd.lights, 'presets')]),
            ('do', lambda: do('lights neon; lights off; atmosphere dust=0.2')),
            ('error', lambda: self.assertRaises(
                CmdException, cmd.lights, 'neon', intensity=9)),
            ('error do', lambda: do('lights nosuch')),
        ] + self.part2_steps() + [
            ('clear', lambda: cmd.lights('clear')),
            ('clear again', lambda: cmd.lights('clear')),
        ]

    def part2_steps(self):
        """Per-light edits: each field kind, colours (and a refused special
        colour), aim, pin, position, rename, add with fields."""
        L = cmd.lights
        error = lambda **fields: self.assertRaises(  # noqa: E731
            CmdException, cmd.lights, 'key', **fields)
        return [
            ('preset again', lambda: L('three_point')),
            ('numbers', lambda: L('key', orbit=10, pitch=20, radius=3,
                                  beam=30, softness=0.2, warmth=4000,
                                  intensity=2, highlight=0.3, falloff=1)),
            ('aliases', lambda: do('lights fill, az=20, el=10, dist=2, '
                                   'soft=0.5, int=1.5, spec=0.2, cue=1, '
                                   'kelvin=7000')),
            ('bools', lambda: L('rim', shadow=1, outline='on')),
            ('color red', lambda: L('key', color='red')),
            ('color prefix', lambda: L('key', color='oran')),
            ('color hex', lambda: L('key', color='0x336699')),
            ('color word', lambda: do('lights key, color=warm')),
            ('rgb', lambda: L('key', rgb='255/128/0')),
            ('color auto', lambda: error(color='auto')),
            ('color -2', lambda: do('lights key, color=-2')),
            ('aim sele', lambda: L('key', aim='resi 1')),
            ('aim point', lambda: L('fill', aim='1/2/3')),
            ('aim centre', lambda: L('key', aim='centre')),
            ('pin', lambda: L('key', pin=1)),
            ('re-pin', lambda: L('key', orbit=30, pitch=10)),
            ('unpin', lambda: L('key', pin=0, radius=2)),
            ('position', lambda: L('fill', position=[1, 2, 3])),
            ('rename', lambda: L('key', name='main')),
            ('rename back', lambda: do('lights main, name=key')),
            ('add with fields', lambda: L('add', 'extra', color='cyan',
                                          aim='resi 1', pin=1)),
            ('remove extra', lambda: L('remove', 'extra')),
            ('conflict', lambda: error(color='red', rgb='1/0/0')),
            ('phase 2 failure', self.failing_step),
        ]

    def failing_step(self):
        with recorded_steps(fail_at=1):
            self.assertRaises(CmdException, cmd.lights, 'key', pin=1)

    def testNothingElseChanges(self):
        snap = Snapshot()
        before = snap.take()
        self.assertTrue(before['materials'])
        for label, step in self.steps():
            step()
            after = snap.take()
            for key in before:
                self.assertEqual(after[key], before[key], (label, key))


# --- chaining ---------------------------------------------------------------

class TestChaining(CommandsCase):

    def setUp(self):
        super().setUp()
        self.load()

    def testChainApplies(self):
        do('lights three_point; lights ambient=0.2; lights off')
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']],
                         ['key', 'fill', 'rim'])
        self.assertEqual(rig['ambient'], 0.2)
        self.assertIs(rig['enabled'], False)
        do('atmosphere haze=0.3; lights neon; atmosphere dust=0.5')
        rig = cmd.get_lights()
        self.assertEqual((rig['air']['haze'], rig['air']['dust']), (0.3, 0.5))
        self.assertIs(rig['enabled'], True)

    def testErrorSkipsTheRestOfTheLine(self):
        text = do('lights three_point; lights nosuch; lights off')
        self.assertIn("no light, preset or keyword named 'nosuch'", text)
        self.assertIs(cmd.get_lights()['enabled'], True)
        text = do('lights ambient=0.4; lights neon, ambient=7; lights off')
        self.assertIn('ambient=7 is out of range 0 to 1', text)
        rig = cmd.get_lights()
        self.assertEqual(rig['ambient'], 0.4)
        self.assertIs(rig['enabled'], True)
        self.assertEqual(rig['lights'][0]['name'], 'key')

    def testLightEditsChain(self):
        do('lights three_point; lights key, intensity=2; lights off')
        rig = cmd.get_lights()
        self.assertEqual(rig['lights'][0]['intensity'], 2.0)
        self.assertIs(rig['enabled'], False)

    def testBadFieldSkipsTheRest(self):
        do('lights three_point')
        key = light('key')
        text = do('lights key, beam=abc; lights off')
        self.assertIn('lights: key: beam=abc is not a number', text)
        self.assertEqual(light('key'), key)
        self.assertIs(cmd.get_lights()['enabled'], True)

    def testCommasInsideBrackets(self):
        do('lights three_point')
        do('lights key, rgb=[1,0.5,0]; lights key, position=[1,2,3]')
        key = light('key')
        self.assertEqual(key['color'], [1.0, 0.5, 0.0])
        self.assertEqual((key['anchor'], key['position']),
                         ('pinned', [1.0, 2.0, 3.0]))

    def testSelectionWithParentheses(self):
        do('lights three_point')
        do('lights key, aim=(m and (resi 1 or resi 2)), beam=30')
        key = light('key')
        self.assertEqual(key['aim_selection'], '(m and (resi 1 or resi 2))')
        # resi 1 (two atoms) and the water of resi 2 at (50, 50, 50)
        self.assertVec(key['aim_point'], [54.0 / 3, 56.0 / 3, 62.0 / 3],
                       places=5)
        self.assertEqual(key['beam'], 30.0)
