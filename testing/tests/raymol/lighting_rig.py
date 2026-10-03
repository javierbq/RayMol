"""The native light rig: model, field table, frame capture (#611).

The rig is C++ owned by the scene (layer1/LightRig.h, SceneLights.h); these
tests reach it through cmd.get_lights / cmd.set_lights and the private _cmd
entries in pymol.lighting, which call the same C++ the app bridge does. No CI
job builds catch2, so the C++ model is tested this way (lighting checklist,
"What CI must cover").

Covers: no rig by default; the field table against the spec; exact set/get
round-trips; default names; strict, atomic validation; clamping; frame capture
(current state, enabled objects, solvent excluded, fallbacks) and re-centre;
what reinitialize clears; and the epic's non-negotiables (the rig never writes
a setting, colour or material, never touches an extent, is per instance).

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_rig.py
"""
import copy
import math

import pymol
from pymol import _cmd, cmd, lighting, testing

# Two protein atoms in a 4 x 6 x 12 A box (half-diagonal 7 A), plus waters
# 50 A away that would inflate the box if solvent were not excluded.
_PDB = """\
ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N
ATOM      2  CA  ALA A   1       4.000   6.000  12.000  1.00  0.00           C
HETATM    3  O   HOH A   2      50.000  50.000  50.000  1.00  0.00           O
HETATM    4  O   HOH A   3     -50.000 -50.000 -50.000  1.00  0.00           O
END
"""

# A literal copy of the field table in the #611 plan (spec §4.1/§4.2 plus the
# proposed air ranges): (scope, name, kind, default, min, max).
SPEC_FIELDS = [
    ('rig', 'enabled', 'bool', False, None, None),
    ('rig', 'centre', 'vec3', None, None, None),
    ('rig', 'size', 'float', None, None, None),
    ('rig', 'ambient', 'float', 0.05, 0.0, 1.0),
    ('rig', 'classic', 'float', 0.0, 0.0, 1.0),
    ('air', 'haze', 'float', 0.0, 0.0, 1.0),
    ('air', 'dust', 'float', 0.0, 0.0, 1.0),
    ('air', 'dust_size', 'float', 0.35, 0.05, 2.0),
    ('air', 'dust_speed', 'float', 1.0, 0.0, 10.0),
    ('air', 'scatter', 'float', 0.55, -0.9, 0.9),
    ('air', 'seed', 'int', 0, 0, 1000000),
    ('light', 'name', 'name', None, None, None),
    ('light', 'anchor', 'camera|pinned', 'camera', None, None),
    ('light', 'orbit', 'angle', 0.0, -180.0, 180.0),
    ('light', 'pitch', 'float', 30.0, -90.0, 90.0),
    ('light', 'radius', 'float', 4.0, 0.5, 8.0),
    ('light', 'position', 'vec3', [0.0, 0.0, 0.0], None, None),
    ('light', 'aim', 'centre|point', 'centre', None, None),
    ('light', 'aim_point', 'vec3', [0.0, 0.0, 0.0], None, None),
    ('light', 'aim_selection', 'str', '', None, None),
    ('light', 'beam', 'float', 45.0, 1.0, 170.0),
    ('light', 'softness', 'float', 0.4, 0.0, 1.0),
    ('light', 'color', 'vec3', [1.0, 1.0, 1.0], 0.0, 1.0),
    ('light', 'warmth', 'float', 6500.0, 1500.0, 15000.0),
    ('light', 'intensity', 'float', 1.0, 0.0, 4.0),
    ('light', 'highlight', 'float', 0.5, 0.0, 1.0),
    ('light', 'falloff', 'float', 2.0, 0.0, 2.0),
    ('light', 'shadow', 'bool', False, None, None),
    ('light', 'outline', 'bool', False, None, None),
]

RIG_KEYS = ['version', 'enabled', 'centre', 'size', 'ambient', 'classic',
            'air', 'lights']
AIR_DEFAULTS = {'haze': 0.0, 'dust': 0.0, 'dust_size': 0.35,
                'dust_speed': 1.0, 'scatter': 0.55, 'seed': 0}
LIGHT_KEYS = [f[1] for f in SPEC_FIELDS if f[0] == 'light']


def default_light(name):
    light = {f[1]: copy.deepcopy(f[3]) for f in SPEC_FIELDS if f[0] == 'light'}
    light['name'] = name
    return light


# Every field away from its default, with decimals that are not exact in
# binary (0.4, 0.1, ...): set_lights then get_lights must give them back
# exactly. A camera light, an aimed light and a pinned light.
FULL_RIG = {
    'version': 1,
    'enabled': True,
    'centre': [1.25, -3.1, 7.7],
    'size': 13.3,
    'ambient': 0.2,
    'classic': 0.3,
    'air': {'haze': 0.3, 'dust': 0.45, 'dust_size': 0.4, 'dust_speed': 2.5,
            'scatter': -0.35, 'seed': 42},
    'lights': [
        {'name': 'key', 'anchor': 'camera', 'orbit': -45.1, 'pitch': 35.2,
         'radius': 3.3, 'position': [0.1, 0.2, 0.3], 'aim': 'centre',
         'aim_point': [0.0, 0.0, 0.0], 'aim_selection': '', 'beam': 55.5,
         'softness': 0.55, 'color': [1.0, 0.9, 0.8], 'warmth': 4500.0,
         'intensity': 1.15, 'highlight': 0.7, 'falloff': 1.5,
         'shadow': True, 'outline': False},
        {'name': 'Fill_2', 'anchor': 'camera', 'orbit': 179.9, 'pitch': -89.9,
         'radius': 0.5, 'position': [0.0, 0.0, 0.0], 'aim': 'point',
         'aim_point': [5.5, -6.6, 7.7], 'aim_selection': 'organic and chain A',
         'beam': 1.0, 'softness': 0.0, 'color': [0.1, 0.2, 0.3],
         'warmth': 15000.0, 'intensity': 0.0, 'highlight': 0.0,
         'falloff': 0.0, 'shadow': False, 'outline': True},
        {'name': '_rim', 'anchor': 'pinned', 'orbit': -179.9, 'pitch': 90.0,
         'radius': 8.0, 'position': [-11.1, 22.2, -33.3], 'aim': 'point',
         'aim_point': [0.4, 0.5, 0.6], 'aim_selection': 'resn NAP',
         'beam': 170.0, 'softness': 1.0, 'color': [0.0, 1.0, 1.0],
         'warmth': 1500.0, 'intensity': 4.0, 'highlight': 1.0,
         'falloff': 2.0, 'shadow': True, 'outline': True},
    ],
}


def material_settings():
    return [name for name in pymol.setting.get_name_list()
            if name.endswith('_material')]


class TestLightRig(testing.PyMOLTestCase):

    def load(self, name='m'):
        cmd.read_pdbstr(_PDB, name)

    def frame_of(self, selection, state=-1):
        """Oracle: midpoint and half-diagonal of cmd.get_extent."""
        mn, mx = cmd.get_extent(selection, state=state)
        centre = [(a + b) / 2.0 for a, b in zip(mn, mx)]
        size = 0.5 * math.sqrt(sum((b - a) ** 2 for a, b in zip(mn, mx)))
        return centre, max(size, 1.0)

    def assertFrame(self, rig, centre, size):
        self.assertIsNotNone(rig['centre'])
        for got, want in zip(rig['centre'], centre):
            self.assertAlmostEqual(got, want, places=5)
        self.assertAlmostEqual(rig['size'], size, places=5)

    def assertRaisesNaming(self, rig, *words):
        """set_lights(rig) raises CmdException whose message has every word."""
        with self.assertRaises(pymol.CmdException) as ctx:
            cmd.set_lights(rig)
        message = str(ctx.exception)
        for word in words:
            self.assertIn(word, message, 'for %r' % (rig,))
        return message

    # --- defaults and the field table ----------------------------------------

    def testNoRigByDefault(self):
        self.assertIsNone(cmd.get_lights())
        self.load()
        self.assertIsNone(cmd.get_lights())

    def testFieldTableMatchesSpec(self):
        fields = lighting._light_fields()
        self.assertEqual([tuple(f) for f in fields], SPEC_FIELDS)
        for got, want in zip(fields, SPEC_FIELDS):
            self.assertIs(type(got[3]), type(want[3]), got)

    def testDefaults(self):
        self.load()
        cmd.set_lights({'lights': [{}]})
        rig = cmd.get_lights()
        self.assertEqual(list(rig), RIG_KEYS)
        self.assertEqual(list(rig['air']), list(AIR_DEFAULTS))
        self.assertEqual(list(rig['lights'][0]), LIGHT_KEYS)
        centre, size = self.frame_of('(enabled and not solvent)')
        expected = {
            'version': 1, 'enabled': False, 'centre': centre, 'size': size,
            'ambient': 0.05, 'classic': 0.0, 'air': AIR_DEFAULTS,
            'lights': [default_light('key')],
        }
        self.assertFrame(rig, centre, size)
        rig['centre'], rig['size'] = centre, size
        self.assertEqual(rig, expected)
        self.assertIs(rig['enabled'], False)
        self.assertIs(rig['air']['seed'], 0)
        self.assertIs(rig['lights'][0]['shadow'], False)

    def testGetReturnsACopy(self):
        cmd.set_lights(FULL_RIG)
        rig = cmd.get_lights()
        rig['lights'][0]['orbit'] = 99.0
        rig['air']['haze'] = 0.9
        self.assertEqual(cmd.get_lights(), FULL_RIG)

    # --- round-trips ----------------------------------------------------------

    def testSetGetIdentity(self):
        cmd.set_lights(FULL_RIG)
        self.assertEqual(cmd.get_lights(), FULL_RIG)
        # and again from what get_lights returned
        cmd.set_lights(cmd.get_lights())
        self.assertEqual(cmd.get_lights(), FULL_RIG)

    def testEveryFieldRoundTrips(self):
        """Each field alone, away from its default, reads back exactly."""
        self.load()
        for scope, name, kind, default, lo, hi in SPEC_FIELDS:
            if kind == 'bool':
                value = not default
            elif kind == 'int':
                value = 12345
            elif kind == 'name':
                value = 'Light_1'
            elif kind == 'str':
                value = 'chain A and "x" \\ é'
            elif kind == 'camera|pinned':
                value = 'pinned'
            elif kind == 'centre|point':
                value = 'point'
            elif kind == 'vec3':
                value = [0.1, 0.7, 0.3] if lo is not None else [-1.1, 2.2, 3.3]
            elif name == 'size':
                value = 12.1
            else:
                value = round(lo + (hi - lo) * 0.37, 6)
            rig = {'lights': [{}]}
            if scope == 'rig':
                rig[name] = value
                if name in ('centre', 'size'):
                    rig.update({'centre': [1.1, 2.2, 3.3], 'size': 4.4})
                    rig[name] = value
            elif scope == 'air':
                rig['air'] = {name: value}
            else:
                rig['lights'][0][name] = value
                if name == 'anchor':
                    rig['lights'][0]['position'] = [1.0, 2.0, 3.0]
            cmd.set_lights(rig)
            got = cmd.get_lights()
            if scope == 'rig':
                self.assertEqual(got[name], value, name)
            elif scope == 'air':
                self.assertEqual(got['air'][name], value, name)
            else:
                self.assertEqual(got['lights'][0][name], value, name)
            self.assertIs(type(got[name] if scope == 'rig' else
                               got['air'][name] if scope == 'air' else
                               got['lights'][0][name]), type(value), name)

    def testTuplesAndIntsAccepted(self):
        cmd.set_lights({'centre': (1, 2, 3), 'size': 5, 'lights': (
            {'orbit': -45, 'color': (1, 0, 0), 'shadow': 1},)})
        rig = cmd.get_lights()
        self.assertEqual(rig['centre'], [1.0, 2.0, 3.0])
        self.assertIs(type(rig['size']), float)
        self.assertEqual(rig['lights'][0]['orbit'], -45.0)
        self.assertEqual(rig['lights'][0]['color'], [1.0, 0.0, 0.0])
        self.assertIs(rig['lights'][0]['shadow'], True)

    def testDefaultNames(self):
        self.load()
        cmd.set_lights({'lights': [{}, {}, {}, {}, {}, {}]})
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key', 'fill', 'rim', 'light4', 'light5', 'light6'])
        # names given later in the list are never reused, ignoring case
        cmd.set_lights({'lights': [{}, {'name': 'KEY'}, {}]})
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['fill', 'KEY', 'rim'])

    # --- validation -----------------------------------------------------------

    def testValidationIsAtomic(self):
        self.load()
        cmd.set_lights(FULL_RIG)
        light = {'name': 'a'}
        cases = [
            ({'lights': [{}] * 7}, ['at most 6 lights']),
            ({'lights': [{'shadow': True}] * 4}, ['light 3', 'at most 3 lights can cast shadows']),
            ({'lights': [{'name': 'key'}, {'name': 'Key'}]}, ["light 1 ('Key')", 'already used']),
            ({'lights': [{'name': ''}]}, ['light 0', 'not valid']),
            ({'lights': [{'name': '1abc'}]}, ["'1abc'", 'not valid']),
            ({'lights': [{'name': 'a b'}]}, ['not valid']),
            ({'lights': [{'name': 'x' * 33}]}, ['not valid']),
            ({'lights': [{'name': 'naïve'}]}, ['not valid']),
            ({'lights': [{'name': 5}]}, ["'name' must be a string"]),
            ({'colour': [1, 0, 0]}, ["unknown key 'colour'"]),
            ({'air': {'fog': 0.1}}, ['air', "unknown key 'fog'"]),
            ({'lights': [{'name': 'k', 'colour': [1, 0, 0]}]}, ["light 0 ('k')", "unknown key 'colour'"]),
            ({'lights': [light, {'anchor': 'pin'}]}, ['light 1', "'anchor' must be 'camera' or 'pinned'"]),
            ({'lights': [{'aim': 'center'}]}, ["'aim' must be 'centre' or 'point'"]),
            ({'ambient': float('nan')}, ["'ambient' must be finite"]),
            ({'lights': [{'orbit': float('inf')}]}, ["'orbit' must be finite"]),
            ({'lights': [{'color': [1.0, float('-inf'), 0.0]}]}, ["'color' must be finite"]),
            ({'air': {'haze': float('nan')}}, ['air', "'haze' must be finite"]),
            ({'enabled': 'yes'}, ["'enabled' must be True or False"]),
            ({'enabled': 2}, ["'enabled' must be True or False"]),
            ({'ambient': '0.1'}, ["'ambient' must be a number"]),
            ({'lights': [{'orbit': True}]}, ["'orbit' must be a number"]),
            ({'lights': [{'color': [1, 1]}]}, ["'color' must be a list of 3 numbers"]),
            ({'lights': [{'color': 'red'}]}, ["'color' must be a list of 3 numbers"]),
            ({'lights': [{'position': None}]}, ["'position' must be a list of 3 numbers"]),
            ({'lights': [{'aim_selection': 5}]}, ["'aim_selection' must be a string"]),
            ({'air': {'seed': 1.5}}, ["'seed' must be an int"]),
            ({'air': []}, ["'air' must be a dict"]),
            ({'lights': {}}, ["'lights' must be a list"]),
            ({'lights': [1]}, ['light 0 must be a dict']),
            ({1: 2}, ['keys must be strings']),
            ({'lights': [{'name': 'rim', 'anchor': 'pinned'}]}, ["light 0 ('rim')", "a pinned light needs 'position'"]),
            ({'centre': [0, 0, 0]}, ["'centre' and 'size' go together"]),
            ({'size': 5.0, 'lights': [{}]}, ["'centre' and 'size' go together"]),
            ({'centre': [0, 0, 0], 'size': 0.0}, ["'size' must be > 0"]),
            ({'centre': [0, 0, 0], 'size': -1.0}, ["'size' must be > 0"]),
            ({'version': 2}, ["'version' 2 is newer"]),
            ({'version': 0}, ["'version' 0 is not a light rig version"]),
            ({'version': '1'}, ["'version' must be an int"]),
            ('three_point', ['expected a dict']),
            ([{}], ['expected a dict']),
        ]
        for rig, words in cases:
            message = self.assertRaisesNaming(rig, 'set_lights', *words)
            self.assertEqual(cmd.get_lights(), FULL_RIG, message)

    def testClamps(self):
        self.load()
        cases = [
            ('radius', 20.0, 8.0), ('radius', 0.1, 0.5),
            ('orbit', 270.0, -90.0), ('orbit', -180.0, 180.0),
            ('orbit', 540.0, 180.0), ('orbit', -190.0, 170.0),
            ('orbit', 180.0, 180.0), ('orbit', 0.4, 0.4),
            ('pitch', 120.0, 90.0), ('pitch', -91.0, -90.0),
            ('beam', 0.0, 1.0), ('beam', 200.0, 170.0),
            ('softness', 2.0, 1.0), ('warmth', 100.0, 1500.0),
            ('intensity', 9.0, 4.0), ('highlight', -1.0, 0.0),
            ('falloff', 3.0, 2.0), ('color', [2.0, -1.0, 0.5], [1.0, 0.0, 0.5]),
        ]
        for name, value, want in cases:
            cmd.set_lights({'lights': [{name: value}]})
            self.assertEqual(cmd.get_lights()['lights'][0][name], want, name)
        air = [('dust_size', 9.0, 2.0), ('dust_size', 0.0, 0.05),
               ('scatter', 1.0, 0.9), ('scatter', -1.0, -0.9),
               ('dust_speed', 11.0, 10.0), ('haze', -0.5, 0.0),
               ('seed', -5, 0), ('seed', 2000000, 1000000)]
        for name, value, want in air:
            cmd.set_lights({'air': {name: value}})
            self.assertEqual(cmd.get_lights()['air'][name], want, name)
        cmd.set_lights({'ambient': 1.5, 'classic': -0.5})
        rig = cmd.get_lights()
        self.assertEqual((rig['ambient'], rig['classic']), (1.0, 0.0))

    # --- frame capture --------------------------------------------------------

    def testCentreCapture(self):
        self.load()
        self.assertEqual(cmd.count_atoms('solvent'), 2)
        cmd.set_lights({'lights': [{}]})
        centre, size = self.frame_of('(enabled and not solvent)')
        self.assertEqual(centre, [2.0, 3.0, 6.0])
        self.assertAlmostEqual(size, 7.0, places=5)
        self.assertFrame(cmd.get_lights(), centre, size)

    def testCaptureCurrentStateOnly(self):
        self.load('src')
        cmd.remove('src and solvent')
        cmd.create('mm', 'src', 1, 1)
        cmd.create('mm', 'src', 1, 2)
        cmd.delete('src')
        cmd.translate([20.0, 0.0, 0.0], 'mm', state=2, camera=0)
        cmd.set('state', 2)
        cmd.set_lights({'lights': [{}]})
        centre, size = self.frame_of('mm', state=-1)   # current state
        self.assertEqual(centre, [22.0, 3.0, 6.0])
        self.assertFrame(cmd.get_lights(), centre, size)

    def testCaptureExcludesDisabled(self):
        self.load('near')
        cmd.pseudoatom('far', pos=[300.0, 300.0, 300.0])
        cmd.disable('far')
        cmd.set_lights({'lights': [{}]})
        centre, size = self.frame_of('near and not solvent')
        self.assertFrame(cmd.get_lights(), centre, size)

    def testCaptureFallbacks(self):
        # only solvent enabled: every enabled atom
        self.load()
        cmd.remove('not solvent')
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [0.0, 0.0, 0.0],
                         0.5 * math.sqrt(3 * 100.0 ** 2))
        # nothing enabled: the rotation origin and 10 A
        cmd.delete('all')
        cmd.origin(position=[1.5, -2.5, 3.5])
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [1.5, -2.5, 3.5], 10.0)
        cmd.pseudoatom('off', pos=[40.0, 0.0, 0.0])
        cmd.disable('off')
        cmd.origin(position=[-7.0, 8.0, 9.0])
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [-7.0, 8.0, 9.0], 10.0)
        # a single atom: size 1 A
        cmd.delete('all')
        cmd.pseudoatom('one', pos=[3.0, 4.0, 5.0])
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [3.0, 4.0, 5.0], 1.0)

    def testFrameNotMovedByViewChanges(self):
        self.load()
        cmd.set_lights({'lights': [{}]})
        before = cmd.get_lights()
        steps = [
            lambda: cmd.hide('everything'),
            lambda: cmd.show('spheres'),
            lambda: cmd.zoom('resi 2'),
            lambda: cmd.turn('y', 40),
            lambda: cmd.move('z', -10),
            lambda: cmd.pseudoatom('other', pos=[90.0, 0.0, 0.0]),
            lambda: cmd.disable('m'),
            lambda: cmd.enable('m'),
            lambda: cmd.translate([5.0, 0.0, 0.0], 'm', camera=0),
            lambda: cmd.origin(position=[9.0, 9.0, 9.0]),
        ]
        for step in steps:
            step()
            self.assertEqual(cmd.get_lights(), before)

    def testRecenter(self):
        self.load()
        cmd.set_lights({'lights': [{}], 'enabled': True})
        before = cmd.get_lights()
        cmd.translate([10.0, 0.0, 0.0], 'm', camera=0)
        lighting._lights_recenter()
        after = cmd.get_lights()
        centre, size = self.frame_of('(enabled and not solvent)')
        self.assertEqual(centre, [12.0, 3.0, 6.0])
        self.assertFrame(after, centre, size)
        # only the frame changed
        after['centre'], after['size'] = before['centre'], before['size']
        self.assertEqual(after, before)

    def testRecenterWithoutRigRaises(self):
        with self.assertRaises(pymol.CmdException):
            lighting._lights_recenter()
        self.assertIsNone(cmd.get_lights())

    def testRecenterEmptyRig(self):
        self.load()
        cmd.set_lights({})
        lighting._lights_recenter()
        centre, size = self.frame_of('(enabled and not solvent)')
        self.assertFrame(cmd.get_lights(), centre, size)

    def testExplicitFrameKept(self):
        self.load()
        cmd.set_lights({'centre': [10.0, 20.0, 30.0], 'size': 2.5,
                        'lights': [{}]})
        rig = cmd.get_lights()
        self.assertEqual((rig['centre'], rig['size']), ([10.0, 20.0, 30.0], 2.5))

    def testEmptyRigHasNoFrame(self):
        self.load()
        cmd.set_lights({})
        rig = cmd.get_lights()
        self.assertEqual(rig, {'version': 1, 'enabled': False, 'centre': None,
                               'size': None, 'ambient': 0.05, 'classic': 0.0,
                               'air': AIR_DEFAULTS, 'lights': []})
        cmd.set_lights({'enabled': True, 'lights': []})
        self.assertIsNone(cmd.get_lights()['centre'])
        self.assertIs(cmd.get_lights()['enabled'], True)

    def testSetNoneRemovesRig(self):
        cmd.set_lights(None)     # no rig: nothing to do
        self.assertIsNone(cmd.get_lights())
        cmd.set_lights(FULL_RIG)
        cmd.set_lights(None)
        self.assertIsNone(cmd.get_lights())

    # --- reinitialize ---------------------------------------------------------

    def testReinitializeClears(self):
        cmd.set_lights(FULL_RIG)
        cmd.reinitialize()
        self.assertIsNone(cmd.get_lights())

    def testReinitializeSettingsKeeps(self):
        cmd.set_lights(FULL_RIG)
        cmd.reinitialize('settings')
        self.assertEqual(cmd.get_lights(), FULL_RIG)
        cmd.reinitialize('original_settings')
        self.assertEqual(cmd.get_lights(), FULL_RIG)

    def testReinitializeObjectKeeps(self):
        self.load()
        cmd.set_lights(FULL_RIG)
        cmd.reinitialize('everything', 'm')
        self.assertEqual(cmd.get_lights(), FULL_RIG)

    # --- non-negotiables ------------------------------------------------------

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

    def testRigNeverWritesSettings(self):
        self.load()
        cmd.show('cartoon')
        cmd.color('red', 'resi 1')
        cmd.set('cartoon_color', 'blue', 'resi 2')
        # The first get_session() writes pse_binary_dump back (CmdGetSession),
        # which adds it to the session's settings list: take that one first.
        self.snapshot()
        before = self.snapshot()
        self.assertTrue(before['materials'])
        rig = copy.deepcopy(FULL_RIG)
        rig['enabled'] = False
        steps = [
            lambda: cmd.set_lights({'lights': [{}]}),
            lambda: cmd.set_lights(rig),
            lambda: cmd.set_lights(FULL_RIG),
            lambda: lighting._lights_recenter(),
            lambda: cmd.set_lights(dict(FULL_RIG, ambient=1.0, classic=1.0)),
            lambda: cmd.set_lights(None),
        ]
        for step in steps:
            step()
            self.assertEqual(self.snapshot(), before)

    def testRigDoesNotTouchExtents(self):
        self.load()

        def extents():
            with cmd.lockcm:
                shadow = _cmd.get_shadow_extent(cmd._COb)
            return (shadow, cmd.get_extent(), cmd.get_extent('all', state=-1),
                    cmd.get_names('all'), cmd.get_view())

        before = extents()
        cmd.set_lights(FULL_RIG)
        self.assertEqual(extents(), before)
        cmd.set_lights({'lights': [{}] * 6, 'enabled': True})
        self.assertEqual(extents(), before)
        lighting._lights_recenter()
        self.assertEqual(extents(), before)
        self.assertNotIn('key', cmd.get_names('all'))

    def testNoStudioSettings(self):
        names = pymol.setting.get_name_list()
        self.assertNotIn('studio_lights', names)
        self.assertNotIn('studio_atmosphere', names)

    def testPerInstance(self):
        import pymol2
        p1 = pymol2.PyMOL()
        p2 = pymol2.PyMOL()
        p1.start()
        p2.start()
        try:
            p1.cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 1.0,
                               'lights': [{'name': 'a'}]})
            p2.cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 1.0,
                               'lights': [{'name': 'b'}, {'name': 'c'}]})
            self.assertIsNone(cmd.get_lights())     # the singleton
            self.assertEqual([l['name'] for l in p1.cmd.get_lights()['lights']], ['a'])
            self.assertEqual([l['name'] for l in p2.cmd.get_lights()['lights']], ['b', 'c'])
            p1.cmd.reinitialize()
            self.assertIsNone(p1.cmd.get_lights())
            self.assertEqual(len(p2.cmd.get_lights()['lights']), 2)
            cmd.set_lights(FULL_RIG)
            self.assertEqual(len(p2.cmd.get_lights()['lights']), 2)
            self.assertIsNone(p1.cmd.get_lights())
        finally:
            p1.stop()
            p2.stop()
