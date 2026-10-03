"""The light rig in .pse sessions: the 'light_rig' key (#611, spec §6).

ExecutiveGetSession writes the rig as a versioned positional list
(LightRigAsPyList, layer1/LightRigPy.cpp) in full sessions that have a rig;
ExecutiveSetSession reads it back (LightRigFromPyList) right after the view,
with the view's rules: skipped on a partial restore, and a full session
without the key (an older .pse) clears the rig. A key that does not read
clears the rig, prints a warning naming the field and marks the restore
incomplete; the rest of the session still loads. A newer version loads the
fields this build knows, with one warning. Out-of-range numbers are clamped.

The list holds the same version and fields as cmd.get_lights()'s dict, in
the C++ field table's order (_light_fields()): bools and the anchor/aim
choices as the ints 0|1, plain ints, floats, strs, lists and None only, so
pse_binary_dump never turns it into blobs and older builds see plain data.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_session.py
"""
import contextlib
import copy
import os
import sys
import tempfile

from pymol import cmd, lighting, testing

# Done-when 1: three lights plus air, every rig-level value away from its
# default. 'key' is a shadowed camera light, 'fill' a camera light aimed at a
# point (the NAP ligand of 1rx1, by its selection text), 'rim' a pinned
# light with an outline. No frame: set_lights captures it from 1rx1.
THREE_LIGHTS_PLUS_AIR = {
    'version': 1,
    'enabled': True,
    'ambient': 0.2,
    'classic': 0.3,
    'air': {'haze': 0.25, 'dust': 0.4, 'dust_size': 0.6, 'dust_speed': 2.5,
            'scatter': -0.3, 'seed': 1234},
    'lights': [
        {'name': 'key', 'anchor': 'camera', 'orbit': -35.5, 'pitch': 30.2,
         'radius': 3.3, 'beam': 50.0, 'softness': 0.45,
         'color': [1.0, 0.95, 0.9], 'warmth': 5200.0, 'intensity': 1.2,
         'highlight': 0.6, 'falloff': 1.5, 'shadow': True},
        {'name': 'fill', 'anchor': 'camera', 'orbit': 60.0, 'pitch': 10.5,
         'radius': 4.5, 'aim': 'point', 'aim_point': [21.3, 33.1, 11.7],
         'aim_selection': 'organic', 'intensity': 0.45, 'warmth': 7500.0},
        {'name': 'rim', 'anchor': 'pinned', 'position': [-12.5, 60.25, -4.1],
         'beam': 30.0, 'softness': 0.2, 'intensity': 2.0, 'outline': True},
    ],
}

# A different rig, to show what a restore replaces or keeps.
OTHER_RIG = {
    'centre': [0.0, 0.0, 0.0], 'size': 5.0, 'enabled': True,
    'lights': [{'name': 'b_one', 'orbit': 10.0}, {'name': 'b_two'}],
}

AIR_DEFAULTS = {'haze': 0.0, 'dust': 0.0, 'dust_size': 0.35,
                'dust_speed': 1.0, 'scatter': 0.55, 'seed': 0}

CHOICES = {'camera|pinned': ['camera', 'pinned'],
           'centre|point': ['centre', 'point']}


def session_list(rig):
    """Oracle: the session list for a get_lights() dict, built from the
    field table (_light_fields), so it pins the order and the encoding."""
    fields = lighting._light_fields()

    def encode(kind, value):
        if kind == 'bool':
            return int(value)
        if kind in CHOICES:
            return CHOICES[kind].index(value)
        return value

    def scope(name, source):
        return [encode(f[2], source[f[1]]) for f in fields if f[0] == name]

    return ([rig['version']] + scope('rig', rig)
            + [scope('air', rig['air']),
               [scope('light', light) for light in rig['lights']]])


def plain_types(value, path='light_rig'):
    """Every value in the list is int, float, str, list or None (no bool, no
    tuple, no bytes): what any build and any pickler read as plain data."""
    if isinstance(value, list):
        for i, item in enumerate(value):
            plain_types(item, '%s[%d]' % (path, i))
        return
    if value is not None and type(value) not in (int, float, str):
        raise AssertionError('%s is %s' % (path, type(value).__name__))


@contextlib.contextmanager
def capture_console():
    """Collect what is written to fd 1 while open (yields a getter).

    The session warnings are C++ feedback, written straight to fd 1:
    contextlib.redirect_stdout never sees them (as in
    test_raymol_theme_apply.py).
    """
    sys.stdout.flush()
    saved = os.dup(1)
    tmp = tempfile.TemporaryFile(mode='w+b')
    result = {}
    try:
        os.dup2(tmp.fileno(), 1)
        yield lambda: result['text']
        sys.stdout.flush()
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        tmp.seek(0)
        result['text'] = tmp.read().decode(errors='replace')
        tmp.close()


class TestLightSession(testing.PyMOLTestCase):

    def load_1rx1(self):
        cmd.load(self.datafile('1rx1.pdb'), 'm')
        return cmd.count_atoms('m')

    def set_rig(self):
        """Load 1rx1, set the done-when rig, return what get_lights() says."""
        self.load_1rx1()
        cmd.turn('y', 35)
        cmd.turn('x', -20)
        cmd.set_lights(THREE_LIGHTS_PLUS_AIR)
        rig = cmd.get_lights()
        self.assertIsNotNone(rig['centre'])
        return rig

    def restore(self, session, partial=0):
        """set_session on a copy of `session`, returning the console text it
        printed."""
        session = copy.deepcopy(session)
        with capture_console() as text:
            cmd.set_session(session, partial=partial)
        return text()

    # --- round-trips ----------------------------------------------------------

    def testPseRoundTripThreeLightsPlusAir(self):
        """Done-when 1: save, reinitialize, load: every value matches."""
        for binary in (0, 1):
            cmd.reinitialize()
            rig = self.set_rig()
            eye = lighting._lights_eye()
            text = lighting._lights_json()
            atoms = cmd.count_atoms('m')
            cmd.set('pse_binary_dump', binary)
            with testing.mktemp('.pse') as filename:
                cmd.save(filename)
                cmd.reinitialize()
                self.assertIsNone(cmd.get_lights())
                cmd.load(filename)
            self.assertEqual(cmd.count_atoms('m'), atoms)
            self.assertEqual(cmd.get_lights(), rig, 'pse_binary_dump %d' % binary)
            self.assertEqual(lighting._lights_json(), text)
            # the view comes back too, so the rig resolves to the same place
            self.assertEqual(lighting._lights_eye(), eye)

    def testCompressedPseRoundTrip(self):
        rig = self.set_rig()
        with testing.mktemp('.pse.gz') as filename:
            cmd.save(filename)
            cmd.reinitialize()
            cmd.load(filename)
        self.assertEqual(cmd.get_lights(), rig)

    def testLegacyPicklerRoundTrip(self):
        """pse_export_version < 1.9 pickles text the Python 2 way, and
        non-ASCII text then loads back as bytes: the rig still reads."""
        self.load_1rx1()
        rig = copy.deepcopy(THREE_LIGHTS_PLUS_AIR)
        rig['lights'][1]['aim_selection'] = 'resn NAP and name C1é'
        cmd.set_lights(rig)
        expected = cmd.get_lights()
        for version in (1.8, 1.7):
            with testing.mktemp('.pse') as filename:
                cmd.set('pse_export_version', version)
                cmd.save(filename)
                cmd.set('pse_export_version', 0)
                cmd.set_lights(None)
                with capture_console() as text:
                    cmd.load(filename)
            self.assertNotIn('light_rig', text(), version)
            self.assertEqual(cmd.get_lights(), expected, version)

    def testInMemoryRoundTrip(self):
        rig = self.set_rig()
        session = cmd.get_session()
        cmd.reinitialize()
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), rig)

    def testGetSetSessionRestoresRig(self):
        """The snapshot pattern (appkit_theme_preview: get_session, change
        things, set_session) puts the rig back, or its absence."""
        rig = self.set_rig()
        snapshot = cmd.get_session(partial=0, quiet=1)
        cmd.set_lights(OTHER_RIG)
        lighting._light_set(0, 'orbit', 25.0)
        cmd.set_session(snapshot, partial=0, quiet=1)
        self.assertEqual(cmd.get_lights(), rig)

        cmd.set_lights(None)
        snapshot = cmd.get_session(partial=0, quiet=1)
        cmd.set_lights(OTHER_RIG)
        cmd.set_session(snapshot, partial=0, quiet=1)
        self.assertIsNone(cmd.get_lights())

    def testEmptyAndDisabledRigsRoundTrip(self):
        """A rig that is present but off (or empty, with no frame) stays
        present: it is not the same as no rig."""
        self.load_1rx1()
        cmd.set_lights({})
        empty = cmd.get_lights()
        self.assertIsNone(empty['centre'])
        session = cmd.get_session()
        cmd.set_lights(None)
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), empty)

        cmd.set_lights(dict(THREE_LIGHTS_PLUS_AIR, enabled=False))
        off = cmd.get_lights()
        session = cmd.get_session()
        cmd.set_lights(None)
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), off)
        self.assertIs(cmd.get_lights()['enabled'], False)

    def testRestoreKeepsTheStoredFrame(self):
        """Loading never re-captures the frame (decision 3): the stored
        centre and size come back although the molecule moved 30 A."""
        rig = self.set_rig()
        cmd.translate([30.0, 0.0, 0.0], 'm', camera=0)
        session = cmd.get_session()
        cmd.set_lights(None)
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), rig)
        lighting._lights_recenter()      # what a re-capture would give
        self.assertNotEqual(cmd.get_lights()['centre'], rig['centre'])

    # --- the key's format -----------------------------------------------------

    def testSessionKeyFormat(self):
        rig = self.set_rig()
        for binary in (0, 1):
            key = cmd.get_session(binary=binary)['light_rig']
            plain_types(key)
            self.assertEqual(key, session_list(rig))
            # the spec §6 layout, by position
            self.assertEqual(key[0], 1)
            self.assertEqual(len(key), 8)
            self.assertEqual(key[1], 1)                      # enabled
            self.assertEqual(key[2], rig['centre'])
            self.assertEqual(key[3], rig['size'])
            self.assertEqual(key[4:6], [0.2, 0.3])           # ambient, classic
            self.assertEqual(key[6], [0.25, 0.4, 0.6, 2.5, -0.3, 1234])
            self.assertEqual(len(key[7]), 3)
            for light in key[7]:
                self.assertEqual(len(light), 18)
            key_light, fill, rim = key[7]
            self.assertEqual(key_light[0], 'key')
            self.assertEqual(key_light[16:], [1, 0])          # shadow, outline
            self.assertEqual(fill[6:9], [1, [21.3, 33.1, 11.7], 'organic'])
            self.assertEqual(rim[1], 1)                       # pinned
            self.assertEqual(rim[5], [-12.5, 60.25, -4.1])    # position
            self.assertEqual(rim[16:], [0, 1])

    def testNoKeyWithoutRig(self):
        """No rig: no key, so the session has exactly the keys it had before
        the rig existed."""
        self.load_1rx1()
        without = cmd.get_session()
        self.assertNotIn('light_rig', without)
        cmd.set_lights(THREE_LIGHTS_PLUS_AIR)
        with_rig = cmd.get_session()
        self.assertEqual(set(with_rig) - set(without), {'light_rig'})
        self.assertEqual(set(without) - set(with_rig), set())

        cmd.set_lights(None)
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            cmd.reinitialize()
            cmd.load(filename)
        self.assertIsNone(cmd.get_lights())

    def testPartialSaveOmitsKey(self):
        self.set_rig()
        self.assertNotIn('light_rig', cmd.get_session(partial=1))
        self.assertIn('light_rig', cmd.get_session(partial=0))

    # --- older sessions and partial restores ----------------------------------

    def testOlderPseClearsRig(self):
        """Done-when 3: a real PyMOL 1.7.6 session (no key) clears the rig."""
        self.set_rig()
        cmd.load(self.datafile('1rx1_176.pse.gz'))
        self.assertGreater(cmd.count_atoms(), 0)
        self.assertIsNone(cmd.get_lights())
        # and with no rig it stays that way
        cmd.load(self.datafile('1rx1_176.pse.gz'))
        self.assertIsNone(cmd.get_lights())

    def testSessionWithoutKeyClearsRig(self):
        rig = self.set_rig()
        session = cmd.get_session()
        self.assertEqual(session_list(rig), session['light_rig'])
        del session['light_rig']
        text = self.restore(session)
        self.assertIsNone(cmd.get_lights())
        self.assertNotIn('light_rig', text)
        self.assertNotIn('incomplete', text)

    def testPartialRestoreKeepsRig(self):
        """Done-when 3: a partial restore (load ..., partial=1) never
        touches the rig, whatever the session holds."""
        self.set_rig()
        session = cmd.get_session()
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            cmd.set_lights(OTHER_RIG)
            other = cmd.get_lights()
            cmd.load(filename, partial=1)
            self.assertEqual(cmd.get_lights(), other)
        self.restore(session, partial=1)
        self.assertEqual(cmd.get_lights(), other)

        # nor does a partial restore of a session without the key
        del session['light_rig']
        self.restore(session, partial=1)
        self.assertEqual(cmd.get_lights(), other)

    def testPartialSessionFileLeavesRigAlone(self):
        """A file saved with partial=1 has no key; loading it in full keeps
        the current rig (it says nothing about lights)."""
        self.set_rig()
        with testing.mktemp('.pse') as filename:
            cmd.save(filename, partial=1)
            cmd.set_lights(OTHER_RIG)
            other = cmd.get_lights()
            cmd.load(filename)
        self.assertGreater(cmd.count_atoms('m'), 0)
        self.assertEqual(cmd.get_lights(), other)

        session = cmd.get_session(partial=1)
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), other)

    # --- robustness -----------------------------------------------------------

    def corrupt_cases(self, key):
        """(label, value for 'light_rig', words the warning must contain),
        each built from the valid list `key`."""

        def edit(fn):
            value = copy.deepcopy(key)
            fn(value)
            return value

        def light(i, slot, value):
            return edit(lambda k: k[7][i].__setitem__(slot, value))

        seven = edit(lambda k: k[7].extend(copy.deepcopy(k[7][:1]) * 4))
        for i, entry in enumerate(seven[7]):
            entry[0] = 'l%d' % i
        four_shadows = edit(lambda k: k[7].append(copy.deepcopy(k[7][0])))
        four_shadows[7][3][0] = 'extra'
        for entry in four_shadows[7]:
            entry[16] = 1
        return [
            ('not a list', 'garbage', ['expected a list, got str']),
            ('empty', [], ['empty list']),
            ('float version', edit(lambda k: k.__setitem__(0, 1.0)),
             ["'version' must be an int"]),
            ('version 0', edit(lambda k: k.__setitem__(0, 0)),
             ['not a light rig version']),
            ('enabled text', edit(lambda k: k.__setitem__(1, 'yes')),
             ["'enabled' must be 0 or 1"]),
            ('centre of 2', edit(lambda k: k.__setitem__(2, [1.0, 2.0])),
             ["'centre' must be a list of 3 numbers"]),
            ('size NaN', edit(lambda k: k.__setitem__(3, float('nan'))),
             ["'size' must be finite"]),
            ('size 0', edit(lambda k: k.__setitem__(3, 0.0)),
             ["'size' must be > 0"]),
            ('centre without size', edit(lambda k: k.__setitem__(3, None)),
             ["'centre' and 'size' go together"]),
            ('lights without a frame',
             edit(lambda k: k.__setitem__(slice(2, 4), [None, None])),
             ['needs a frame']),
            ('air dict', edit(lambda k: k.__setitem__(6, {'haze': 0.1})),
             ["'air' must be a list"]),
            ('float seed', edit(lambda k: k[6].__setitem__(5, 1.5)),
             ["air: 'seed' must be an int"]),
            ('lights text', edit(lambda k: k.__setitem__(7, 'key')),
             ["'lights' must be a list"]),
            ('light dict', edit(lambda k: k[7].__setitem__(0, {'name': 'k'})),
             ['light 0 must be a list']),
            ('orbit text', light(1, 2, 'left'),
             ["light 1 ('fill'): 'orbit' must be a number"]),
            ('anchor 2', light(0, 1, 2),
             ["light 0 ('key'): 'anchor' must be 0 (camera) or 1 (pinned)"]),
            ('aim text', light(1, 6, 'point'),
             ["'aim' must be 0 (centre) or 1 (point)"]),
            ('shadow 2', light(0, 16, 2), ["'shadow' must be 0 or 1"]),
            ('name number', light(0, 0, 7), ["'name' must be a string"]),
            ('bad name', light(0, 0, '1st'), ["name '1st' is not valid"]),
            ('duplicate name', light(1, 0, 'KEY'), ["'KEY' is already used"]),
            ('inf warmth', light(2, 12, float('inf')),
             ["light 2 ('rim'): 'warmth' must be finite"]),
            ('pinned without position',
             edit(lambda k: k[7].__setitem__(2, k[7][2][:5])),
             ["light 2 ('rim'): a pinned light needs 'position'"]),
            ('7 lights', seven, ['at most 6 lights (got 7)']),
            ('4 shadows', four_shadows,
             ['at most 3 lights can cast shadows']),
        ]

    def testCorruptKeyClearsRigAndLoadsTheRest(self):
        rig = self.set_rig()
        atoms = cmd.count_atoms('m')
        view = cmd.get_view()
        session = cmd.get_session()
        cases = self.corrupt_cases(session['light_rig'])
        for label, value, words in cases:
            corrupt = copy.deepcopy(session)
            corrupt['light_rig'] = value
            cmd.set_lights(OTHER_RIG)
            text = self.restore(corrupt)
            self.assertIsNone(cmd.get_lights(), label)
            self.assertEqual(cmd.count_atoms('m'), atoms, label)
            self.assertEqual(cmd.get_view(), view, label)
            warnings = [line for line in text.splitlines()
                        if 'light_rig' in line]
            self.assertEqual(len(warnings), 1, '%s: %r' % (label, text))
            self.assertIn('rig cleared', warnings[0], label)
            for word in words:
                self.assertIn(word, warnings[0], label)
            self.assertIn('restore may be incomplete', text, label)
        # the valid key still loads after all that
        cmd.set_session(session)
        self.assertEqual(cmd.get_lights(), rig)

    def testNewerVersionLoadsKnownPrefix(self):
        """Q6: a newer version (append-only) loads the fields this build
        knows, with one warning, and the restore is complete."""
        rig = self.set_rig()
        session = cmd.get_session()
        for version in (2, 10 ** 30):
            newer = copy.deepcopy(session['light_rig'])
            newer[0] = version
            newer[6] += [0.5, 'future air']
            for entry in newer[7]:
                entry += [[1.0, 2.0, 3.0], 'future light field']
            newer += [{'future': 1}, None]
            corrupt = dict(session, light_rig=newer)
            cmd.set_lights(OTHER_RIG)
            text = self.restore(corrupt)
            self.assertEqual(cmd.get_lights(), rig)
            warnings = [line for line in text.splitlines()
                        if 'light_rig' in line]
            self.assertEqual(len(warnings), 1, text)
            self.assertIn('version %d is newer than this build reads (1)'
                          % version, warnings[0])
            self.assertNotIn('incomplete', text)

    def testVersionOneLoadsSilently(self):
        self.set_rig()
        text = self.restore(cmd.get_session())
        self.assertNotIn('light_rig', text)
        self.assertNotIn('incomplete', text)

    def testShorterListTakesDefaults(self):
        """Missing trailing fields take the defaults (what a reader of a
        later version does with this version's lists)."""
        self.load_1rx1()
        session = cmd.get_session()
        cases = [
            ([1], {'version': 1, 'enabled': False, 'centre': None,
                   'size': None, 'ambient': 0.05, 'classic': 0.0,
                   'air': AIR_DEFAULTS, 'lights': []}),
            ([1, 1, [1.0, 2.0, 3.0], 4.0, 0.2],
             {'version': 1, 'enabled': True, 'centre': [1.0, 2.0, 3.0],
              'size': 4.0, 'ambient': 0.2, 'classic': 0.0,
              'air': AIR_DEFAULTS, 'lights': []}),
        ]
        for value, expected in cases:
            text = self.restore(dict(session, light_rig=value))
            self.assertEqual(cmd.get_lights(), expected, value)
            self.assertNotIn('light_rig', text)

        value = [1, 0, [1.0, 2.0, 3.0], 4.0, 0.05, 0.0, [0.3],
                 [['top', 0, 45.0], [], ['pin', 1, 0.0, 30.0, 4.0,
                                         [5.0, 6.0, 7.0]]]]
        self.restore(dict(session, light_rig=value))
        got = cmd.get_lights()
        self.assertEqual(got['air'], dict(AIR_DEFAULTS, haze=0.3))
        defaults = {f[1]: f[3] for f in lighting._light_fields()
                    if f[0] == 'light'}
        top, unnamed, pin = got['lights']
        self.assertEqual(top, dict(defaults, name='top', orbit=45.0))
        self.assertEqual(unnamed, dict(defaults, name='key'))
        self.assertEqual(pin, dict(defaults, name='pin', anchor='pinned',
                                   position=[5.0, 6.0, 7.0]))

    def testRestoreClampsOutOfRange(self):
        """Q3: out-of-range numbers are clamped, silently."""
        rig = self.set_rig()
        session = cmd.get_session()
        key = copy.deepcopy(session['light_rig'])
        key[4] = 1.5                       # ambient
        key[6][4] = -2.0                   # scatter
        key[6][5] = 2000000                # seed
        key[7][0][2] = 270.0               # orbit
        key[7][0][3] = 120.0               # pitch
        key[7][0][4] = 20.0                # radius
        key[7][0][11] = [2.0, -1.0, 0.5]   # color
        text = self.restore(dict(session, light_rig=key))
        self.assertNotIn('light_rig', text)
        got = cmd.get_lights()
        self.assertEqual(got['ambient'], 1.0)
        self.assertEqual(got['air']['scatter'], -0.9)
        self.assertEqual(got['air']['seed'], 1000000)
        light = got['lights'][0]
        self.assertEqual((light['orbit'], light['pitch'], light['radius']),
                         (-90.0, 90.0, 8.0))
        self.assertEqual(light['color'], [1.0, 0.0, 0.5])
        self.assertEqual(got['lights'][1:], rig['lights'][1:])

    def testTuplesRead(self):
        """A key edited by hand with tuples instead of lists still reads."""
        rig = self.set_rig()
        session = cmd.get_session()
        key = session['light_rig']
        as_tuples = tuple(key[:6]) + (tuple(key[6]),
                                      tuple(tuple(l) for l in key[7]))
        cmd.set_lights(None)
        cmd.set_session(dict(session, light_rig=as_tuples))
        self.assertEqual(cmd.get_lights(), rig)
