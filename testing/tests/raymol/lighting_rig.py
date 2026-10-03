"""The native light rig: model, field table, frame capture (#611).

The rig is C++ owned by the scene (layer1/LightRig.h, SceneLights.h); these
tests reach it through cmd.get_lights / cmd.set_lights and the private _cmd
entries in pymol.lighting, which call the same C++ the app bridge does. No CI
job builds catch2, so the C++ model is tested this way (lighting checklist,
"What CI must cover").

Covers: no rig by default; the field table against the spec; exact set/get
round-trips; default names; strict, atomic validation; clamping; frame capture
(current state, enabled objects, solvent excluded, fallbacks) and re-centre;
the per-field setter and getter the app bridge uses (_light_set / _light_get:
status codes, clamping and wrap, aim switching, the beam kept on a radius
edit); the JSON the bridge reads (_lights_json: same keys, order and types as
the dict, exact numbers, escaped text, '.' whatever the C locale); what
reinitialize clears; and the epic's non-negotiables (the rig never writes a
setting, colour or material, never touches an extent, is per instance).
The eye-space resolver and the pin conversions are in lighting_eye.py.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_rig.py
"""
import copy
import math

import pymol
from pymol import _cmd, cgo, cmd, lighting, testing

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


# Every field _light_set takes, each away from FULL_RIG's value: (index,
# field, value). Index -1 is the rig and its air.
LIGHT_SET_VALUES = [
    (-1, 'enabled', 0), (-1, 'ambient', 0.33), (-1, 'classic', 0.66),
    (-1, 'haze', 0.1), (-1, 'dust', 0.2), (-1, 'dust_size', 0.9),
    (-1, 'dust_speed', 4.0), (-1, 'scatter', 0.25), (-1, 'seed', 99),
    (1, 'orbit', 12.5), (1, 'pitch', 33.0), (1, 'radius', 6.5),
    (1, 'beam', 80.0), (1, 'softness', 0.9), (1, 'warmth', 9000.0),
    (1, 'intensity', 2.5), (1, 'highlight', 0.25), (1, 'falloff', 1.25),
    (1, 'shadow', 1), (1, 'outline', 0), (1, 'color', [0.9, 0.5, 0.1]),
    (1, 'aim_point', [1.5, 2.5, 3.5]), (1, 'aim', 0), (1, 'aim', 1),
    (1, 'anchor', 1), (1, 'pitch', -15.0), (1, 'anchor', 0),
    (2, 'orbit', 45.0), (2, 'position', [7.0, 8.0, 9.0]),
]


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
        self.assertIsNone(lighting._lights_json())
        self.assertIsNone(lighting._lights_eye())

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
                if name == 'aim':
                    rig['lights'][0]['aim_point'] = [4.0, 5.0, 6.0]
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
            ({'lights': [light, {'name': 'spot', 'aim': 'point'}]}, ["light 1 ('spot')", "a light aimed at a point needs 'aim_point'"]),
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

    def testNameLengthBoundary(self):
        """Q4: 32 characters is the longest name: accepted by set_lights,
        through _light_get and the JSON, and through a session save and
        restore; 33 is refused (testValidationIsAtomic)."""
        self.load()
        longest = '_' + 'a' * 30 + '9'
        self.assertEqual(len(longest), 32)
        cmd.set_lights({'lights': [{'name': longest}, {'name': 'B' * 32}]})
        rig = cmd.get_lights()
        self.assertEqual([l['name'] for l in rig['lights']],
                         [longest, 'B' * 32])
        self.assertEqual(lighting._light_get(0, 'name'), longest)
        self.assertIn('"%s"' % longest, lighting._lights_json())
        session = cmd.get_session()
        cmd.set_lights(None)
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), rig)

    def testSequenceSubclassWithWrongLen(self):
        """A list subclass whose __len__ disagrees with its items is read
        by its real items: an error naming the field, never a crash."""

        class Liar(list):
            def __init__(self, items, n):
                super().__init__(items)
                self.n = n

            def __len__(self):
                return self.n

        cmd.set_lights(FULL_RIG)
        cases = [
            ({'lights': [{'color': Liar([1.0], 3)}]}, "'color' must be a list of 3"),
            ({'lights': [{'color': Liar([], 3)}]}, "'color' must be a list of 3"),
            ({'centre': Liar([0.0, 0.0], 3), 'size': 5.0}, "'centre' must be a list of 3"),
        ]
        for rig, words in cases:
            message = self.assertRaisesNaming(rig, words)
            self.assertEqual(cmd.get_lights(), FULL_RIG, message)
        # longer than it says: its real items are checked
        self.assertRaisesNaming(
            {'lights': [{'color': Liar([1.0, 0.0, 0.0, 0.5], 3)}]},
            "'color' must be a list of 3")
        # a lights list that claims more lights than it holds: the real ones
        cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 5.0,
                        'lights': Liar([{'name': 'one'}], 6)})
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['one'])
        # and fewer than it holds: all of them count
        self.assertRaisesNaming({'centre': [0.0, 0.0, 0.0], 'size': 5.0,
                                 'lights': Liar([{}] * 7, 1)},
                                'at most 6 lights (got 7)')
        with self.assertRaises(pymol.CmdException):
            with cmd.lockcm:
                _cmd.get_lights_eye(cmd._COb, Liar([1.0], 16))
        with self.assertRaises(pymol.CmdException):
            lighting._light_set(0, 'color', Liar([0.5], 3))
        with self.assertRaises(pymol.CmdException):
            lighting._light_set(0, 'color', Liar([0.5, 0.5, 0.5, 0.5], 3))

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

    def testCaptureIncludesNonMoleculeObjects(self):
        """§4.3 / Q5: the extent of the enabled objects. Maps, meshes and
        CGOs count with the atoms (solvent is still left out when anything
        else is enabled); disabled ones and gadgets (screen space) do not."""
        shape = [cgo.BEGIN, cgo.LINES, cgo.VERTEX, -10.0, -20.0, -30.0,
                 cgo.VERTEX, 1.0, 2.0, 3.0, cgo.END]
        # a CGO alone
        cmd.load_cgo(shape, 'shape')
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [-4.5, -9.0, -13.5],
                         0.5 * math.sqrt(11.0 ** 2 + 22.0 ** 2 + 33.0 ** 2))
        # with the molecule: the union of the CGO and the non-solvent atoms
        # (0,0,0)-(4,6,12); the waters at +-50 A still left out
        self.load()
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [-3.0, -7.0, -9.0],
                         0.5 * math.sqrt(14.0 ** 2 + 26.0 ** 2 + 42.0 ** 2))
        # a disabled CGO does not count
        cmd.disable('shape')
        cmd.set_lights({'lights': [{}]})
        centre, size = self.frame_of('(enabled and not solvent)')
        self.assertFrame(cmd.get_lights(), centre, size)
        # waters and a CGO: the CGO alone (solvent counts only when nothing
        # else is enabled)
        cmd.enable('shape')
        cmd.remove('m and not solvent')
        cmd.set_lights({'lights': [{}]})
        self.assertFrame(cmd.get_lights(), [-4.5, -9.0, -13.5],
                         0.5 * math.sqrt(11.0 ** 2 + 22.0 ** 2 + 33.0 ** 2))

        # an EM-style scene: a mesh of a map, the molecule and the map off
        cmd.delete('all')
        self.load()
        cmd.alter('m', 'b = 20.0')          # a gaussian map needs B > 0
        cmd.map_new('dens', 'gaussian', 1.0, 'm and not solvent', 4.0)
        cmd.isomesh('emesh', 'dens', 0.2)
        self.assertIn('emesh', cmd.get_names('objects'))
        cmd.disable('m')
        cmd.disable('dens')
        cmd.set_lights({'lights': [{}]})
        centre, size = self.frame_of('emesh')
        self.assertGreater(size, 7.0)       # wider than the two atoms
        self.assertFrame(cmd.get_lights(), centre, size)
        # the map's own extent counts while it is enabled
        cmd.enable('dens')
        cmd.set_lights({'lights': [{}]})
        mn = [min(a, b) for a, b in zip(cmd.get_extent('emesh')[0],
                                        cmd.get_extent('dens')[0])]
        mx = [max(a, b) for a, b in zip(cmd.get_extent('emesh')[1],
                                        cmd.get_extent('dens')[1])]
        self.assertFrame(cmd.get_lights(),
                         [(a + b) / 2.0 for a, b in zip(mn, mx)],
                         0.5 * math.sqrt(sum((b - a) ** 2
                                             for a, b in zip(mn, mx))))
        # a colour ramp (a gadget, drawn in screen space) changes nothing
        before = cmd.get_lights()
        cmd.ramp_new('ramp', 'dens', [0.0, 1.0])
        cmd.set_lights({'lights': [{}]})
        self.assertEqual(cmd.get_lights(), before)

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

    # --- per-field set / get (the app bridge's setter) ------------------------

    def assertLightSetFails(self, status, args, *words):
        """_light_set(*args) raises CmdException('<status>: ...') naming
        every word, and leaves the rig unchanged."""
        before = cmd.get_lights()
        with self.assertRaises(pymol.CmdException) as ctx:
            lighting._light_set(*args)
        message = ctx.exception.message
        self.assertTrue(message.startswith(status + ': '),
                        '%r for %r' % (message, args))
        for word in words:
            self.assertIn(word, message, 'for %r' % (args,))
        self.assertEqual(cmd.get_lights(), before, message)

    def testLightSetScalarsVectorsRigLevel(self):
        cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 10.0,
                        'lights': [{}, {}]})
        untouched = cmd.get_lights()['lights'][0]
        scalars = [('orbit', 33.3), ('pitch', -12.5), ('radius', 2.5),
                   ('beam', 70.1), ('softness', 0.25), ('warmth', 3200.0),
                   ('intensity', 2.2), ('highlight', 0.8), ('falloff', 1.1)]
        for field, value in scalars:
            lighting._light_set(1, field, value)
            got = cmd.get_lights()['lights'][1][field]
            self.assertEqual(got, value, field)
            self.assertIs(type(got), float, field)
        # ints are numbers too
        lighting._light_set(1, 'warmth', 4000)
        self.assertEqual(cmd.get_lights()['lights'][1]['warmth'], 4000.0)
        # bools: true from 0.5 up; Python bools accepted
        for value, want in ((1, True), (0, False), (0.7, True), (0.2, False),
                            (True, True), (False, False)):
            lighting._light_set(1, 'shadow', value)
            lighting._light_set(1, 'outline', value)
            light = cmd.get_lights()['lights'][1]
            self.assertIs(light['shadow'], want, value)
            self.assertIs(light['outline'], want, value)
        # vectors: a list or a tuple of 3
        lighting._light_set(1, 'color', [0.2, 0.4, 0.6])
        self.assertEqual(cmd.get_lights()['lights'][1]['color'], [0.2, 0.4, 0.6])
        lighting._light_set(1, 'color', (1, 0, 0.5))
        self.assertEqual(cmd.get_lights()['lights'][1]['color'], [1.0, 0.0, 0.5])
        self.assertEqual(cmd.get_lights()['lights'][0], untouched)
        # the rig and its air: index -1
        for field, value in (('ambient', 0.3), ('classic', 0.4)):
            lighting._light_set(-1, field, value)
            self.assertEqual(cmd.get_lights()[field], value, field)
        lighting._light_set(-1, 'enabled', 1)
        self.assertIs(cmd.get_lights()['enabled'], True)
        lighting._light_set(-1, 'enabled', False)
        self.assertIs(cmd.get_lights()['enabled'], False)
        air = [('haze', 0.2), ('dust', 0.3), ('dust_size', 0.5),
               ('dust_speed', 3.0), ('scatter', -0.2), ('seed', 17)]
        for field, value in air:
            lighting._light_set(-1, field, value)
            self.assertEqual(cmd.get_lights()['air'][field], value, field)
        lighting._light_set(-1, 'seed', 17.6)
        self.assertIs(cmd.get_lights()['air']['seed'], 18)

    def testLightSetWorksOnAnEmptyRig(self):
        cmd.set_lights({})
        lighting._light_set(-1, 'enabled', 1)
        lighting._light_set(-1, 'haze', 0.5)
        rig = cmd.get_lights()
        self.assertEqual((rig['enabled'], rig['air']['haze'], rig['centre']),
                         (True, 0.5, None))
        self.assertLightSetFails('bad index', (0, 'orbit', 1.0),
                                 'light index 0 is out of range')

    def testLightSetStatuses(self):
        cmd.set_lights(FULL_RIG)     # 3 lights, 2 of them shadowed
        cases = [
            ('unknown field', (0, 'colour', [1, 0, 0]), "'colour' is not a light field"),
            ('unknown field', (-1, 'fog', 0.1), "'fog' is not a rig field"),
            ('unknown field', (-1, 'orbit', 1.0), "'orbit' is a light field"),
            ('unknown field', (0, 'ambient', 0.1), "'ambient' is a rig field"),
            ('unknown field', (0, 'version', 1), "'version'"),
            ('bad index', (3, 'orbit', 1.0), 'light index 3', '0 to 2'),
            ('bad index', (-2, 'ambient', 0.1), 'light index -2'),
            ('refused', (0, 'name', 1.0), "'name' is text"),
            ('refused', (0, 'aim_selection', 1.0), "'aim_selection' is text"),
            ('refused', (-1, 'centre', [0, 0, 0]), "'centre' is the captured frame"),
            ('refused', (-1, 'size', 5.0), "'size' is the captured frame"),
            ('bad value', (0, 'orbit', float('nan')), "'orbit' must be finite"),
            ('bad value', (0, 'radius', float('inf')), "'radius' must be finite"),
            ('bad value', (0, 'color', [1.0, float('nan'), 0.0]), "'color' must be finite"),
            ('bad value', (-1, 'haze', float('-inf')), "'haze' must be finite"),
            ('bad value', (0, 'color', 1.0), "'color' takes 3 numbers, got 1"),
            ('bad value', (0, 'position', 1.0), "'position' takes 3 numbers"),
            ('bad value', (0, 'orbit', [1.0, 2.0, 3.0]), "'orbit' takes 1 number, got 3"),
            ('bad value', (0, 'anchor', 0.5), "'anchor' takes 0 (camera) or 1 (pinned)"),
            ('bad value', (0, 'aim', 2), "'aim' takes 0 (centre) or 1 (point)"),
            ('bad value', (0, 'orbit', 'left'), 'must be a number or a list of 3 numbers'),
            ('bad value', (0, 'color', [1.0, 'x', 0.0]), 'value item 1'),
            ('bad value', (0, 'color', [1.0, 0.0]), 'must be a number or a list of 3'),
            ('bad value', (0, 'orbit', None), 'must be a number'),
        ]
        for status, args, *words in cases:
            self.assertLightSetFails(status, args, *words)
        # a 4th shadowed light is refused; a shadowed light can be set again,
        # and once one is switched off another can cast
        cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 5.0,
                        'lights': [{'shadow': True}] * 3 + [{}]})
        self.assertLightSetFails('refused', (3, 'shadow', 1),
                                 'at most 3 lights can cast shadows')
        self.assertLightSetFails('refused', (3, 'shadow', 0.5),
                                 'at most 3 lights can cast shadows')
        lighting._light_set(3, 'shadow', 0)
        lighting._light_set(0, 'shadow', 1)
        lighting._light_set(0, 'shadow', 0)
        lighting._light_set(3, 'shadow', 1)
        self.assertEqual([l['shadow'] for l in cmd.get_lights()['lights']],
                         [False, True, True, True])
        # no rig
        cmd.set_lights(None)
        with self.assertRaises(pymol.CmdException) as ctx:
            lighting._light_set(0, 'orbit', 1.0)
        self.assertEqual(ctx.exception.message, 'no rig: there is no light rig')
        with self.assertRaises(pymol.CmdException) as ctx:
            lighting._light_get(0, 'orbit')
        self.assertEqual(ctx.exception.message, 'no rig: there is no light rig')
        self.assertIsNone(cmd.get_lights())

    def testLightGetStatuses(self):
        cmd.set_lights(FULL_RIG)
        for args, status in (((0, 'colour'), 'unknown field'),
                             ((-1, 'orbit'), 'unknown field'),
                             ((3, 'orbit'), 'bad index'),
                             ((-2, 'ambient'), 'bad index')):
            with self.assertRaises(pymol.CmdException) as ctx:
                lighting._light_get(*args)
            self.assertTrue(ctx.exception.message.startswith(status + ': '),
                            ctx.exception.message)

    def testLightSetClampsAndWraps(self):
        cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 10.0,
                        'lights': [{}]})
        cases = [
            ('orbit', 270.0, -90.0), ('orbit', -180.0, 180.0),
            ('orbit', 540.0, 180.0), ('orbit', -190.0, 170.0),
            ('orbit', 180.0, 180.0), ('orbit', 0.4, 0.4),
            ('radius', 20.0, 8.0), ('radius', 0.0, 0.5),
            ('pitch', 120.0, 90.0), ('pitch', -91.0, -90.0),
            ('beam', 0.0, 1.0), ('beam', 200.0, 170.0),
            ('softness', 2.0, 1.0), ('warmth', 100.0, 1500.0),
            ('intensity', 9.0, 4.0), ('highlight', -1.0, 0.0),
            ('falloff', 3.0, 2.0), ('color', [2.0, -1.0, 0.5], [1.0, 0.0, 0.5]),
        ]
        for field, value, want in cases:
            lighting._light_set(0, field, value)
            self.assertEqual(cmd.get_lights()['lights'][0][field], want,
                             (field, value))
        rig_cases = [
            ('ambient', 1.5, 1.0), ('classic', -0.5, 0.0),
            ('dust_size', 9.0, 2.0), ('dust_size', 0.0, 0.05),
            ('scatter', 1.0, 0.9), ('dust_speed', 11.0, 10.0),
            ('haze', -0.5, 0.0), ('seed', -5, 0), ('seed', 2000000, 1000000),
        ]
        for field, value, want in rig_cases:
            lighting._light_set(-1, field, value)
            rig = cmd.get_lights()
            got = rig[field] if field in rig else rig['air'][field]
            self.assertEqual(got, want, (field, value))

    def testBeamKeptWhenRadiusChanges(self):
        """Decision 8: the beam is a cone angle; radius never changes it."""
        cmd.set_lights({'centre': [0.0, 0.0, 0.0], 'size': 10.0, 'lights': [
            {'beam': 37.0, 'softness': 0.3},
            {'beam': 64.0, 'anchor': 'pinned', 'position': [0.0, 0.0, 30.0]}]})
        before = lighting._lights_eye()
        for radius in (1.0, 6.0, 0.5, 8.0):
            lighting._light_set(0, 'radius', radius)
            lighting._light_set(1, 'radius', radius)
            rig = cmd.get_lights()
            eye = lighting._lights_eye()
            for i in (0, 1):
                self.assertEqual(rig['lights'][i]['beam'], [37.0, 64.0][i])
                self.assertEqual(eye['lights'][i]['cos_outer'],
                                 before['lights'][i]['cos_outer'])
                self.assertEqual(eye['lights'][i]['cos_inner'],
                                 before['lights'][i]['cos_inner'])
                self.assertAlmostEqual(eye['lights'][i]['radius'], radius,
                                       places=4)

    def testAimPointSwitchesAim(self):
        cmd.set_lights({'centre': [1.0, 2.0, 3.0], 'size': 4.0, 'lights': [
            {'aim': 'centre', 'aim_selection': 'resn NAP'}]})
        # aim_point: aims at the point and drops the selection text
        lighting._light_set(0, 'aim_point', [5.0, 6.0, 7.0])
        light = cmd.get_lights()['lights'][0]
        self.assertEqual((light['aim'], light['aim_point'], light['aim_selection']),
                         ('point', [5.0, 6.0, 7.0], ''))
        # aim 1 while already aimed at a point keeps the point
        lighting._light_set(0, 'aim', 1)
        self.assertEqual(cmd.get_lights()['lights'][0]['aim_point'], [5.0, 6.0, 7.0])
        # aim 0: back to the centre, selection text cleared
        cmd.set_lights({'centre': [1.0, 2.0, 3.0], 'size': 4.0, 'lights': [
            {'aim': 'point', 'aim_point': [5.0, 6.0, 7.0],
             'aim_selection': 'organic'}]})
        lighting._light_set(0, 'aim', 0)
        light = cmd.get_lights()['lights'][0]
        self.assertEqual((light['aim'], light['aim_selection']), ('centre', ''))
        before = lighting._lights_eye()['lights'][0]
        # aim 1 from the centre: a point at the centre, so nothing moves
        lighting._light_set(0, 'aim', 1)
        light = cmd.get_lights()['lights'][0]
        self.assertEqual((light['aim'], light['aim_point']), ('point', [1.0, 2.0, 3.0]))
        after = lighting._lights_eye()['lights'][0]
        for key in ('position', 'target', 'direction'):
            for a, b in zip(after[key], before[key]):
                self.assertAlmostEqual(a, b, places=5, msg=key)

    def testLightGetMatchesDict(self):
        cmd.set_lights(FULL_RIG)
        rig = cmd.get_lights()
        for scope, name, kind, default, lo, hi in SPEC_FIELDS:
            if scope == 'light':
                for index, light in enumerate(rig['lights']):
                    got = lighting._light_get(index, name)
                    self.assertEqual(got, light[name], (index, name))
                    self.assertIs(type(got), type(light[name]), (index, name))
            else:
                want = rig[name] if scope == 'rig' else rig['air'][name]
                got = lighting._light_get(-1, name)
                self.assertEqual(got, want, name)
                self.assertIs(type(got), type(want), name)
        cmd.set_lights({})
        self.assertIsNone(lighting._light_get(-1, 'centre'))
        self.assertIsNone(lighting._light_get(-1, 'size'))

    def testLightSetThenGetEveryField(self):
        cmd.set_lights(FULL_RIG)
        for index, field, value in LIGHT_SET_VALUES:
            lighting._light_set(index, field, value)
            got = lighting._light_get(index, field)
            if field in ('anchor', 'aim'):
                want = [['camera', 'pinned'], ['centre', 'point']][
                    field == 'aim'][int(value)]
            elif field in ('enabled', 'shadow', 'outline'):
                want = bool(value)
            else:
                want = value
            self.assertEqual(got, want, (index, field, value))

    # --- JSON (what the app bridge reads) -------------------------------------

    def testJsonNoneWithoutRig(self):
        self.assertIsNone(lighting._lights_json())
        cmd.set_lights(FULL_RIG)
        cmd.set_lights(None)
        self.assertIsNone(lighting._lights_json())

    def testJsonMatchesDict(self):
        import json
        rig = copy.deepcopy(FULL_RIG)
        rig['lights'][1]['aim_selection'] = \
            'resn "NAP" \\ x\nand\tchain A \x01 é ü 分子'
        for case in (rig, {}, {'lights': [{}]}):
            cmd.set_lights(case)
            text = lighting._lights_json()
            self.assertIsInstance(text, str)
            decoded = json.loads(text)
            want = cmd.get_lights()
            self.assertEqual(decoded, want)
            self.assertEqual(list(decoded), RIG_KEYS)
            self.assertEqual(list(decoded['air']), list(AIR_DEFAULTS))
            for light in decoded['lights']:
                self.assertEqual(list(light), LIGHT_KEYS)

            # the same types as the dict: floats stay floats
            def types(value):
                if isinstance(value, dict):
                    return {k: types(v) for k, v in value.items()}
                if isinstance(value, list):
                    return [types(v) for v in value]
                return type(value)
            self.assertEqual(types(decoded), types(want))
            # one line: control characters are escaped
            self.assertNotIn('\n', text)
            self.assertNotIn('\t', text)

    def testJsonNumbersRoundTrip(self):
        """Numbers that need 17 significant digits read back exactly."""
        import json
        rig = {'centre': [0.1 + 0.2, 1.0 / 3.0, -2.0 / 3.0],
               'size': 123.45678901234567, 'ambient': 0.1 + 0.2,
               'classic': 1e-300, 'lights': [
                   {'orbit': 1.0 / 7.0, 'position': [1e20, -1e-20, 0.0],
                    'warmth': 6500.0, 'anchor': 'pinned'}]}
        cmd.set_lights(rig)
        text = lighting._lights_json()
        self.assertEqual(json.loads(text), cmd.get_lights())
        self.assertIn('"warmth":6500.0', text)
        self.assertIn('"seed":0', text)
        self.assertIn('"enabled":false', text)

    def testJsonIgnoresCLocale(self):
        """A C locale with a decimal comma never leaks into the JSON."""
        import json
        import locale
        cmd.set_lights(FULL_RIG)
        expected = cmd.get_lights()
        old = locale.setlocale(locale.LC_NUMERIC)
        for name in ('de_DE.UTF-8', 'de_DE', 'fr_FR.UTF-8', 'fr_FR', 'nl_NL.UTF-8'):
            try:
                locale.setlocale(locale.LC_NUMERIC, name)
            except locale.Error:
                continue
            if locale.localeconv()['decimal_point'] == ',':
                break
            locale.setlocale(locale.LC_NUMERIC, old)
        else:
            self.skipTest('no decimal-comma locale installed')
        try:
            text = lighting._lights_json()
        finally:
            locale.setlocale(locale.LC_NUMERIC, old)
        self.assertEqual(json.loads(text), expected)
        self.assertIn('"ambient":0.2', text)

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
        ]
        # every field the per-field setter takes (the app bridge's path)
        for index, field, value in LIGHT_SET_VALUES:
            steps.append(lambda i=index, f=field, v=value:
                         lighting._light_set(i, f, v))
        steps += [
            lambda: lighting._lights_json(),
            lambda: lighting._lights_eye(),
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
