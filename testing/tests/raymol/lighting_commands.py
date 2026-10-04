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
            ('clear', lambda: cmd.lights('clear')),
            ('clear again', lambda: cmd.lights('clear')),
        ]

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
