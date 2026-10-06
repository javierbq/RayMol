"""Scenes store their own light rig (#617, spec §6).

raymol_scenes keeps a fifth per-scene extra, _scene_lights: the rig as
lighting.get_lights() returns it when the rig is on (it exists, is enabled
and has at least one light), else 'off'. Store captures it, recall (and
next/previous) applies it, delete prunes it, rename re-keys it and
`scene *, clear` clears it. A scene with no entry (from an older .pse)
leaves the rig alone. The .pse holds them under 'raymol_scene_lights' as
{scene: 'off' | <light_rig list>}, each list in the format of the top-level
'light_rig' key, through two pure _cmd converters (light_rig_to_session,
light_rig_from_session), so #611's lenient reader is reused. A partial
restore leaves every per-scene extra and the movie track alone.

The C++ converters are tested through _cmd (#611's decision: no catch2 job).

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_scenes.py
"""
import contextlib
import copy

import pymol
from pymol import cmd, colorprinting, lighting, setting, testing
from pymol import raymol_scene_anim, raymol_scenes

# Two protein atoms in a 4 x 6 x 12 A box.
_PDB = """\
ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N
ATOM      2  CA  ALA A   1       4.000   6.000  12.000  1.00  0.00           C
END
"""

# Every rig-level value away from its default: a shadowed camera key, a
# pinned rim with an outline, and a top light aimed at a point.
RIG_A = {
    'version': 1,
    'enabled': True,
    'ambient': 0.1,
    'classic': 0.2,
    'air': {'haze': 0.2, 'dust': 0.3, 'dust_size': 0.5, 'dust_speed': 1.5,
            'scatter': 0.1, 'seed': 7},
    'lights': [
        {'name': 'key', 'orbit': -60.0, 'pitch': 30.0, 'radius': 4.0,
         'beam': 40.0, 'softness': 0.3, 'color': [1.0, 0.55, 0.2],
         'intensity': 1.6, 'shadow': True},
        {'name': 'rim', 'anchor': 'pinned', 'position': [10.0, 5.0, -3.0],
         'color': [0.2, 0.8, 1.0], 'outline': True},
        {'name': 'top', 'pitch': 80.0, 'aim': 'point',
         'aim_point': [1.0, 2.0, 3.0], 'aim_selection': 'all'},
    ],
}

# A different rig with its own frame.
RIG_B = {
    'enabled': True, 'centre': [1.0, 2.0, 3.0], 'size': 6.0,
    'ambient': 0.15, 'classic': 0.0,
    'lights': [{'name': 'key', 'orbit': 60.0, 'pitch': 45.0},
               {'name': 'fill', 'orbit': -100.0, 'warmth': 3200.0}],
}


def reset_module_state():
    """What setUp and tearDown reset directly: reinitialize does not clear
    these (and author([]) after reinitialize would mdo frames of a movie
    that no longer exists)."""
    raymol_scenes.clear_all()
    raymol_scene_anim._track.clear()
    raymol_scene_anim._scene_marks[:] = []
    lights_track = getattr(raymol_scene_anim, '_lights_track', None)
    if lights_track is not None:
        lights_track.clear()


@contextlib.contextmanager
def warnings_collected():
    """The raymol_scenes warnings (colorprinting.warning) as a list."""
    lines = []
    saved = colorprinting.warning
    colorprinting.warning = lambda *args, **kw: lines.append(
        ' '.join(str(a) for a in args))
    try:
        yield lines
    finally:
        colorprinting.warning = saved


@contextlib.contextmanager
def counting(module, name):
    """Count calls to module.name (still calling it)."""
    calls = []
    original = getattr(module, name)

    def spy(*args, **kw):
        calls.append(args)
        return original(*args, **kw)

    setattr(module, name, spy)
    try:
        yield calls
    finally:
        setattr(module, name, original)


class _SceneRigCase(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        reset_module_state()
        cmd.read_pdbstr(_PDB, 'm')

    def tearDown(self):
        reset_module_state()
        super().tearDown()

    def set_rig(self, rig):
        """Set `rig` (None removes it) and return what get_lights() says."""
        lighting.set_lights(copy.deepcopy(rig) if rig else None)
        return cmd.get_lights()

    def store(self, name, rig):
        """Make `rig` live and store scene `name`; return the live rig."""
        live = self.set_rig(rig)
        cmd.scene(name, 'store')
        return live


class TestRigSessionConverters(_SceneRigCase):
    """_cmd.light_rig_to_session / light_rig_from_session."""

    def testRigToSessionMatchesTheSessionKey(self):
        rig = self.set_rig(RIG_A)
        self.assertEqual(lighting._rig_to_session(rig),
                         cmd.get_session()['light_rig'])
        # never touches the live rig
        lighting._rig_to_session(RIG_B)
        self.assertEqual(cmd.get_lights(), rig)

    def testRigFromSessionRoundTrip(self):
        disabled = dict(copy.deepcopy(RIG_B), enabled=False)
        empty = {'enabled': True, 'lights': []}
        for source in (RIG_A, RIG_B, disabled, empty):
            rig = self.set_rig(source)
            got, warnings = lighting._rig_from_session(
                lighting._rig_to_session(rig))
            self.assertEqual(got, rig)
            self.assertEqual(warnings, [])
            # neither converter touches the live rig
            self.assertEqual(cmd.get_lights(), rig)

    def testRigFromSessionLenient(self):
        rig = self.set_rig(RIG_A)
        lst = lighting._rig_to_session(rig)

        # a newer version with one more field per light: the known prefix
        newer = copy.deepcopy(lst)
        newer[0] = 2
        for entry in newer[3]:
            entry.append('a field from the future')
        got, warnings = lighting._rig_from_session(newer)
        self.assertEqual(got, rig)
        self.assertEqual(len(warnings), 1, warnings)
        self.assertIn('newer', warnings[0])

        # seven lights: six load, with a warning (the cap is policy)
        seven = copy.deepcopy(lst)
        rim = seven[3][1]
        for i in range(4):
            extra = copy.deepcopy(rim)
            extra[0] = 'extra%d' % i
            seven[3].append(extra)
        self.assertEqual(len(seven[3]), 7)
        got, warnings = lighting._rig_from_session(seven)
        self.assertEqual(len(got['lights']), 6)
        self.assertEqual([l['name'] for l in got['lights']],
                         ['key', 'rim', 'top', 'extra0', 'extra1', 'extra2'])
        self.assertTrue(warnings)

        # tuples read too
        got, _ = lighting._rig_from_session(tuple(lst))
        self.assertEqual(got, rig)

    def testRigSessionErrors(self):
        rig = self.set_rig(RIG_A)
        lst = lighting._rig_to_session(rig)
        bad_dicts = [
            ('x', None),
            ({'bogus': 1}, 'bogus'),
            ({'version': 2}, 'version'),
            ({'lights': [{'name': 'key'}]}, 'frame'),        # validated
            ({'centre': [0, 0, 0]}, 'centre'),
        ]
        for value, word in bad_dicts:
            with self.assertRaises(pymol.CmdException) as cm:
                lighting._rig_to_session(value)
            self.assertIn('light_rig_to_session', str(cm.exception), value)
            if word:
                self.assertIn(word, str(cm.exception), value)
        zero = copy.deepcopy(lst)
        zero[0] = 0
        for value in ('x', None, 7, zero, [1, 'rig', [], []]):
            with self.assertRaises(pymol.CmdException) as cm:
                lighting._rig_from_session(value)
            self.assertIn('light_rig_from_session', str(cm.exception), value)
        self.assertEqual(cmd.get_lights(), rig)


class TestSceneRigStoreRecall(_SceneRigCase):
    """Done-when: recalling a scene restores its rig."""

    def testStoreRecallRestoresTheRig(self):
        a = self.store('A', RIG_A)
        self.assertEqual(raymol_scenes.scene_lights('A'), a)
        # edit the live rig everywhere a scene has to bring back
        lighting.set_lights(dict(a, centre=[5.0, 5.0, 5.0], size=9.0,
                                 air=dict(a['air'], haze=0.9)))
        lighting._light_set(1, 'position', [0.0, 0.0, 9.0])
        lighting._light_set(2, 'aim_point', [3.0, 3.0, 3.0])
        lighting._light_set(0, 'orbit', 25.0)
        self.assertNotEqual(cmd.get_lights(), a)
        cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), a)

        b = self.store('B', RIG_B)
        cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), a)
        cmd.scene('B', 'recall')
        self.assertEqual(cmd.get_lights(), b)

    def testSceneLightsIsACopy(self):
        a = self.store('A', RIG_A)
        got = raymol_scenes.scene_lights('A')
        got['lights'][0]['orbit'] = 10.0
        self.assertEqual(raymol_scenes.scene_lights('A'), a)
        self.assertIsNone(raymol_scenes.scene_lights('nope'))

    def testNoRigRecordsOffAndRecallTurnsTheRigOff(self):
        self.store('Off', None)
        self.assertEqual(raymol_scenes._scene_lights['Off'], 'off')
        a = self.set_rig(RIG_A)
        cmd.scene('Off', 'recall')
        # the lights are kept; only 'enabled' changes
        self.assertEqual(cmd.get_lights(), dict(a, enabled=False))

    def testNoRigStaysNoRig(self):
        self.store('Off', None)
        cmd.scene('Off', 'recall')
        self.assertIsNone(cmd.get_lights())
        # recalling 'off' with no rig writes nothing at all
        with counting(lighting, '_light_set') as light_set, \
                counting(lighting, 'set_lights') as set_lights:
            cmd.scene('Off', 'recall')
        self.assertEqual((light_set, set_lights), ([], []))
        self.assertIsNone(cmd.get_lights())

    def testRigNotOnRecordsOff(self):
        """Q1: a rig that exists but is not on (disabled, or no lights)
        records 'off', per spec §6."""
        self.store('Disabled', dict(copy.deepcopy(RIG_A), enabled=False))
        self.assertEqual(raymol_scenes._scene_lights['Disabled'], 'off')
        self.store('Empty', {'enabled': True, 'lights': []})
        self.assertEqual(raymol_scenes._scene_lights['Empty'], 'off')
        self.store('On', RIG_A)
        self.assertTrue(raymol_scenes.rig_on(raymol_scenes._scene_lights['On']))

    def testRigOn(self):
        on = raymol_scenes.rig_on
        self.assertTrue(on(RIG_A))
        self.assertFalse(on(None))
        self.assertFalse(on('off'))
        self.assertFalse(on(dict(RIG_A, enabled=False)))
        self.assertFalse(on(dict(RIG_A, lights=[])))

    def testOlderSceneLeavesTheRigAlone(self):
        self.store('A', RIG_A)
        del raymol_scenes._scene_lights['A']
        b = self.set_rig(RIG_B)
        cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), b)
        lighting.set_lights(None)
        cmd.scene('A', 'recall')
        self.assertIsNone(cmd.get_lights())

    def testNextAndPreviousApply(self):
        a = self.store('A', RIG_A)
        b = self.store('B', RIG_B)
        cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), a)
        cmd.scene('auto', 'next')
        self.assertEqual(cmd.get_lights(), b)
        cmd.scene('auto', 'previous')
        self.assertEqual(cmd.get_lights(), a)

    def testUpdateRecaptures(self):
        self.store('A', RIG_A)
        b = self.set_rig(RIG_B)
        cmd.scene('A', 'update')
        self.assertEqual(raymol_scenes.scene_lights('A'), b)
        lighting.set_lights(None)
        cmd.scene('A', 'update')
        self.assertEqual(raymol_scenes.scene_lights('A'), 'off')

    def testRecallWritesOnlyWhatChanges(self):
        """A recall whose rig already matches writes nothing (the
        conditional write apply_settings uses)."""
        a = self.store('A', RIG_A)
        with counting(lighting, 'set_lights') as calls:
            cmd.scene('A', 'recall')
        self.assertEqual(calls, [])
        self.store('Off', None)
        lighting.set_lights(dict(a, enabled=False))
        with counting(lighting, '_light_set') as calls:
            cmd.scene('Off', 'recall')
        self.assertEqual(calls, [])

    def testRenameDeleteClear(self):
        a = self.store('A', RIG_A)
        self.store('B', None)
        cmd.scene('A', 'rename', new_key='C')
        self.assertNotIn('A', raymol_scenes._scene_lights)
        self.assertEqual(raymol_scenes.scene_lights('C'), a)
        cmd.scene('B', 'delete')
        self.assertEqual(set(raymol_scenes._scene_lights), {'C'})
        self.store('D', RIG_B)
        cmd.scene('*', 'clear')
        self.assertEqual(raymol_scenes._scene_lights, {})

    def testBadStoredRigWarnsOnce(self):
        """A rig the core refuses (a hand-edited or newer one) leaves the
        live rig unchanged and warns once, not once per recall."""
        a = self.store('A', RIG_A)
        raymol_scenes._scene_lights['A'] = dict(a, version=99)
        b = self.set_rig(RIG_B)
        with warnings_collected() as lines:
            for _ in range(3):
                cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), b)
        self.assertEqual(len(lines), 1, lines)
        self.assertIn('light rig of scene "A"', lines[0])
        # deleting the scene forgets the report with the scene's entry
        cmd.scene('A', 'delete')
        self.assertNotIn(('A', 'light rig'), raymol_scenes._reported)

    def testPreservedPutsTheRigBack(self):
        a = self.set_rig(RIG_A)
        with raymol_scenes.preserved(cmd):
            lighting.set_lights(copy.deepcopy(RIG_B))
        self.assertEqual(cmd.get_lights(), a)

        lighting.set_lights(None)
        with raymol_scenes.preserved(cmd):
            lighting.set_lights(copy.deepcopy(RIG_A))
        self.assertIsNone(cmd.get_lights())

        # nothing written when the block leaves the rig as it was
        self.set_rig(RIG_A)
        with counting(lighting, 'set_lights') as calls:
            with raymol_scenes.preserved(cmd):
                pass
        self.assertEqual(calls, [])

    def testNeverCallsCmdSetLights(self):
        """Harness scene files wrap cmd.set_lights, so the scenes go
        through the lighting module only."""
        self.store('A', RIG_A)
        self.store('B', RIG_B)
        saved = cmd.set_lights
        cmd.set_lights = lambda *a, **k: self.fail('cmd.set_lights called')
        try:
            cmd.scene('A', 'recall')
            cmd.scene('B', 'recall')
            with raymol_scenes.preserved(cmd):
                cmd.scene('A', 'recall')
        finally:
            cmd.set_lights = saved

    def testNoSettingOrColourWritten(self):
        """Lights never change a setting or a colour: recalling scenes that
        differ only in their rigs leaves both as they were."""
        self.store('A', RIG_A)
        self.store('B', None)
        names = setting.get_name_list()

        def values():
            # values, not the session list: a scene recall may mark a setting
            # as defined at the value it already had
            return {n: cmd.get(n) for n in names}

        settings = values()
        colors = []
        cmd.iterate('all', 'colors.append(color)', space={'colors': colors})
        # (ends on B, the scene current when the settings were read:
        # scene_current_name is a setting)
        for name in ('A', 'B', 'A', 'B'):
            cmd.scene(name, 'recall')
        self.assertEqual(values(), settings)
        after = []
        cmd.iterate('all', 'after.append(color)', space={'after': after})
        self.assertEqual(after, colors)


class TestSceneRigSession(_SceneRigCase):
    """Done-when: .pse round trip, older .pse, partial restore."""

    def store_three(self):
        a = self.store('A', RIG_A)
        b = self.store('B', RIG_B)
        self.store('Off', None)
        return a, b

    def check_three(self, a, b):
        self.assertEqual(raymol_scenes._scene_lights,
                         {'A': a, 'B': b, 'Off': 'off'})
        lighting.set_lights(None)
        cmd.scene('A', 'recall')
        self.assertEqual(cmd.get_lights(), a)
        cmd.scene('B', 'recall')
        self.assertEqual(cmd.get_lights(), b)
        cmd.scene('Off', 'recall')
        self.assertEqual(cmd.get_lights(), dict(b, enabled=False))

    def testPseRoundTrip(self):
        for binary in (0, 1):
            cmd.reinitialize()
            reset_module_state()
            cmd.read_pdbstr(_PDB, 'm')
            a, b = self.store_three()
            cmd.set('pse_binary_dump', binary)
            with testing.mktemp('.pse') as filename:
                cmd.save(filename)
                cmd.reinitialize()
                reset_module_state()
                cmd.load(filename)
            self.check_three(a, b)

    def testInMemoryRoundTrip(self):
        a, b = self.store_three()
        session = cmd.get_session()
        cmd.reinitialize()
        reset_module_state()
        cmd.set_session(session)
        self.check_three(a, b)

    def testSessionKeyFormat(self):
        self.store('A', RIG_A)
        key_a = cmd.get_session()['light_rig']
        self.store('B', RIG_B)
        key_b = cmd.get_session()['light_rig']
        self.store('Off', None)
        self.assertEqual(cmd.get_session()['raymol_scene_lights'],
                         {'A': key_a, 'B': key_b, 'Off': 'off'})
        # the key is written even with no entries, like its siblings
        raymol_scenes.clear_all()
        self.assertEqual(cmd.get_session()['raymol_scene_lights'], {})

    def testUnsavableEntrySkippedWithAWarning(self):
        a = self.store('A', RIG_A)
        raymol_scenes._scene_lights['Bad'] = dict(a, version=99)
        with warnings_collected() as lines:
            key = cmd.get_session()['raymol_scene_lights']
        self.assertEqual(set(key), {'A'})
        self.assertEqual(len(lines), 1, lines)
        self.assertIn('Bad', lines[0])

    def testOlderPseWithoutTheKey(self):
        self.store_three()
        session = cmd.get_session()
        del session['raymol_scene_lights']
        cmd.set_session(session)
        self.assertEqual(raymol_scenes._scene_lights, {})
        # every scene then leaves the rig alone
        b = self.set_rig(RIG_B)
        for name in ('A', 'Off'):
            cmd.scene(name, 'recall')
            self.assertEqual(cmd.get_lights(), b)

    def testPartialRestoreLeavesScenesAlone(self):
        """Q5: a partial restore leaves every per-scene extra and the movie
        track alone (the core keeps the live scenes and movie then)."""
        cmd.mset('1 x10')
        self.store_three()
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            session = cmd.get_session()
            # a session whose extras and track differ from the live ones
            session['raymol_scene_lights'] = {'A': 'off', 'Z': 'off'}
            session['raymol_scene_settings'] = {'Z': {'ambient': '0.5'}}
            session['raymol_movie_anim'] = {
                'track': {'3': {'ambient': 0.5}}, 'marks': []}

            # the live state the restore must keep
            self.store('A', RIG_B)
            raymol_scene_anim._track[7] = {'ambient': 0.25}
            live = cmd.get_lights()
            lights = copy.deepcopy(raymol_scenes._scene_lights)
            settings = copy.deepcopy(raymol_scenes._scene_settings)
            ttt = copy.deepcopy(raymol_scenes._scene_ttt)
            track = copy.deepcopy(raymol_scene_anim._track)

            def unchanged(how):
                self.assertEqual(raymol_scenes._scene_lights, lights, how)
                self.assertEqual(raymol_scenes._scene_settings, settings, how)
                self.assertEqual(raymol_scenes._scene_ttt, ttt, how)
                self.assertEqual(raymol_scene_anim._track, track, how)
                self.assertEqual(cmd.get_lights(), live, how)
                self.assertFalse(cmd._pymol._session_partial_restore, how)

            cmd.load(filename, partial=1)
            unchanged('load partial=1')
            cmd.set_session(copy.deepcopy(session), partial=1)
            unchanged('set_session partial=1')

        # a full restore still replaces them
        cmd.set_session(session)
        self.assertEqual(raymol_scenes._scene_lights, {'A': 'off', 'Z': 'off'})
        self.assertEqual(raymol_scene_anim._track, {3: {'ambient': 0.5}})
        self.assertFalse(cmd._pymol._session_partial_restore)
        reset_module_state()

    def testPartialFlagResetAfterAFailedRestore(self):
        def failing(session, *, _self=cmd):
            raise RuntimeError('boom')

        cmd._pymol._session_restore_tasks.append(failing)
        try:
            with self.assertRaises(RuntimeError):
                cmd.set_session(cmd.get_session(), partial=1)
        finally:
            cmd._pymol._session_restore_tasks.remove(failing)
        self.assertFalse(cmd._pymol._session_partial_restore)

    def testMalformedEntries(self):
        a = self.store('A', RIG_A)
        session = cmd.get_session()
        good = session['raymol_scene_lights']['A']
        zero = copy.deepcopy(good)
        zero[0] = 0
        newer = copy.deepcopy(good)
        newer[0] = 2
        session['raymol_scene_lights'] = {
            'A': good, 'B': 'on', 'C': {'enabled': True}, 'D': zero,
            'E': 'off', 'F': 42, 'G': newer, 'H': None, 7: 'off',
            'I': [1, 'rig', [], []]}
        with warnings_collected() as lines:
            cmd.set_session(session)
        self.assertEqual(raymol_scenes._scene_lights,
                         {'A': a, 'E': 'off', 'G': a})
        dropped = [l for l in lines if 'dropped' in l]
        for name in 'BCDFHI':
            self.assertEqual(
                len([l for l in dropped if "'%s'" % name in l]), 1,
                (name, lines))
        self.assertTrue(any("'G'" in l and 'newer' in l for l in lines), lines)
        self.assertTrue(any('bad scene name' in l for l in lines), lines)

        # a payload that is not a dict: no entries, one warning, no raise
        session['raymol_scene_lights'] = 'junk'
        with warnings_collected() as lines:
            cmd.set_session(session)
        self.assertEqual(raymol_scenes._scene_lights, {})
        self.assertEqual(len(lines), 1, lines)

    def testLegacyPicklerRoundTrip(self):
        """pse_export_version < 1.9 gives non-ASCII text back as bytes: the
        per-scene rigs still read. (A non-ASCII scene NAME does not survive
        the legacy pickler in the core's own scene settings, so the name is
        ASCII here; testBytesKeysAndValues reads a bytes key.)"""
        rig = copy.deepcopy(RIG_A)
        rig['lights'][2]['aim_selection'] = 'name Cé'
        a = self.store('Scene1', rig)
        with testing.mktemp('.pse') as filename:
            cmd.set('pse_export_version', 1.8)
            cmd.save(filename)
            cmd.set('pse_export_version', 0)
            reset_module_state()
            with warnings_collected() as lines:
                cmd.load(filename)
        self.assertEqual(lines, [])
        self.assertEqual(raymol_scenes._scene_lights, {'Scene1': a})

    def testBytesKeysAndValues(self):
        """The legacy pickler's UTF-8 bytes keys and values read as text;
        a key that is not UTF-8 is dropped with a warning."""
        a = self.store('A', RIG_A)
        session = cmd.get_session()
        good = session['raymol_scene_lights']['A']
        session['raymol_scene_lights'] = {
            'Scène'.encode('utf-8'): good, b'Off': b'off',
            b'\xff': 'off'}
        with warnings_collected() as lines:
            cmd.set_session(session)
        self.assertEqual(raymol_scenes._scene_lights,
                         {'Scène': a, 'Off': 'off'})
        self.assertEqual(len(lines), 1, lines)
        self.assertIn('bad scene name', lines[0])
