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

Scene movies blend the rigs (raymol_scene_anim): one `_lights_blend A, B, t`
frame command per interior frame of each transition, reading the stored rigs
at play time, with the camera's easing; the scene keyframe applies the
scene's rig exactly. The track is saved as data, stripped from the saved
movie (no movie lock) and re-authored on load.

The C++ converters are tested through _cmd (#611's decision: no catch2 job).

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_scenes.py
"""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import math
import os
import shutil
import sys
import tempfile
import unittest

import pymol
from pymol import cmd, colorprinting, lighting, setting, testing
from pymol import appkit_movie, raymol_scene_anim, raymol_scenes

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


# --- the movie blend ---------------------------------------------------------

anim = raymol_scene_anim

# Two rigs for the movie tests, like the L2 movie: key and rim in both (the
# rim crosses 180 the short way), top only in A, fill only in B; B's key is
# shadowed, A's top is.
MOVIE_A = {
    'enabled': True, 'ambient': 0.05, 'classic': 0.0,
    'air': {'haze': 0.1, 'dust': 0.2, 'seed': 4},
    'lights': [
        {'name': 'key', 'orbit': -60.0, 'pitch': 30.0, 'radius': 4.0,
         'beam': 40.0, 'softness': 0.3, 'color': [1.0, 0.55, 0.2],
         'intensity': 1.6},
        {'name': 'rim', 'orbit': 160.0, 'pitch': 20.0,
         'color': [0.2, 0.8, 1.0]},
        {'name': 'top', 'pitch': 80.0, 'intensity': 1.0, 'shadow': True},
    ],
}
MOVIE_B = {
    'enabled': True, 'ambient': 0.15, 'classic': 0.2,
    'air': {'haze': 0.3, 'dust': 0.0, 'seed': 9},
    'lights': [
        {'name': 'key', 'orbit': 60.0, 'pitch': 45.0, 'radius': 3.0,
         'beam': 60.0, 'softness': 0.6, 'color': [0.3, 0.45, 1.0],
         'intensity': 1.2, 'shadow': True},
        {'name': 'rim', 'orbit': -160.0, 'color': [1.0, 0.25, 0.8]},
        {'name': 'fill', 'orbit': -100.0, 'pitch': 0.0, 'warmth': 3200.0,
         'intensity': 0.8},
    ],
}

SMOOTH = 1.4


def eased_t(f, f0=1, f1=25, power=SMOOTH):
    """The t the author stores for frame f: the camera's easing, pre-rounded
    like the command text."""
    return float('%.6g' % anim.ease((f - f0) / float(f1 - f0), power))


def b64(name):
    return base64.b64encode(name.encode('utf-8')).decode('ascii')


def scene_item(frame, name, power=0.0, linear=0, **extra):
    return dict({'frame': frame, 'scene': b64(name), 'power': power,
                 'linear': linear}, **extra)


def rebuild(*items):
    appkit_movie.rebuild(json.dumps(list(items)))


def played(f):
    cmd.frame(f)
    return cmd.get_lights()


def raw_movie_commands():
    """The movie's frame commands as the core holds them: get_session()
    without raymol_scene_anim's save task (which strips ours)."""
    tasks = cmd._pymol._session_save_tasks
    saved = list(tasks)
    tasks[:] = [t for t in tasks if t is not anim.session_save]
    try:
        return list(cmd.get_session()['movie'][5])
    finally:
        tasks[:] = saved


def rig(source):
    """A complete rig dict (the get_lights() format) for `source`, from the
    core, leaving the live rig as it was."""
    live = cmd.get_lights()
    lighting.set_lights(copy.deepcopy(source))
    try:
        return cmd.get_lights()
    finally:
        lighting.set_lights(live)


@contextlib.contextmanager
def spying(module, name):
    """Record (args, kwargs) of each call to module.name, still calling it."""
    calls = []
    original = getattr(module, name)

    def spy(*args, **kw):
        calls.append((args, kw))
        return original(*args, **kw)

    setattr(module, name, spy)
    try:
        yield calls
    finally:
        setattr(module, name, original)


class _BlendCase(_SceneRigCase):

    def assertRigAlmostEqual(self, got, want, path='rig'):
        """Numbers almost equal (relative 1e-5: the core stores floats),
        everything else exactly."""
        if isinstance(want, dict):
            self.assertIsInstance(got, dict, path)
            self.assertEqual(set(got), set(want), path)
            for k in want:
                self.assertRigAlmostEqual(got[k], want[k], '%s.%s' % (path, k))
        elif isinstance(want, (list, tuple)):
            self.assertIsInstance(got, (list, tuple), path)
            self.assertEqual(len(got), len(want), path)
            for i, (g, w) in enumerate(zip(got, want)):
                self.assertRigAlmostEqual(g, w, '%s[%d]' % (path, i))
        elif isinstance(want, float) and not isinstance(got, bool):
            self.assertIsInstance(got, (int, float), path)
            tol = 1e-5 * max(1.0, abs(want))
            self.assertTrue(abs(got - want) <= tol,
                            '%s: %r != %r' % (path, got, want))
        else:
            self.assertEqual(got, want, path)

    def light(self, r, name):
        for l in r['lights']:
            if l['name'] == name:
                return l
        self.fail('no light %r in %r' % (name, [l['name'] for l in r['lights']]))


class TestBlendValues(_BlendCase):
    """Blend values at t = 0, 0.5 and 1 (args): shortest-path angles,
    linear-RGB colour, one-sided fades and the step-at-cut fields."""

    A = {'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 2.0,
         'ambient': 0.1, 'classic': 0.0,
         'air': {'haze': 0.0, 'dust': 0.2, 'dust_size': 0.2,
                 'dust_speed': 1.0, 'scatter': -0.5, 'seed': 3},
         'lights': [
             {'name': 'key', 'orbit': 170.0, 'pitch': 10.0, 'radius': 2.0,
              'beam': 20.0, 'softness': 0.2, 'intensity': 1.0,
              'highlight': 0.2, 'falloff': 1.0, 'warmth': 3000.0,
              'color': [1.0, 0.0, 0.0]},
             {'name': 'k2', 'orbit': -60.0}]}
    B = {'enabled': True, 'centre': [2.0, 4.0, 6.0], 'size': 6.0,
         'ambient': 0.3, 'classic': 0.5,
         'air': {'haze': 0.4, 'dust': 0.6, 'dust_size': 1.0,
                 'dust_speed': 3.0, 'scatter': 0.5, 'seed': 9},
         'lights': [
             {'name': 'key', 'orbit': -170.0, 'pitch': 50.0, 'radius': 6.0,
              'beam': 60.0, 'softness': 0.6, 'intensity': 3.0,
              'highlight': 0.8, 'falloff': 2.0, 'warmth': 9000.0,
              'color': [0.0, 0.0, 1.0]},
             {'name': 'k2', 'orbit': 60.0}]}

    def testBlendEndpoints(self):
        a, b = rig(self.A), rig(self.B)
        self.assertEqual(anim.blend_target(a, b, 0.0), a)
        self.assertEqual(anim.blend_target(a, b, -0.5), a)
        self.assertEqual(anim.blend_target(a, b, 1.0), b)
        self.assertEqual(anim.blend_target(a, b, 1.5), b)
        # blend_rigs itself is exact at its ends for every interpolated field
        r = anim.blend_rigs(a, b, 0.0)
        self.assertEqual(r, a)
        # copies: the stored rigs are never aliased
        got = anim.blend_target(a, b, 0.0)
        got['lights'][0]['orbit'] = 1.0
        self.assertNotEqual(got, a)

    def testBlendMidpoint(self):
        a, b = rig(self.A), rig(self.B)
        m = anim.blend_rigs(a, b, 0.5)
        key, k2 = self.light(m, 'key'), self.light(m, 'k2')
        self.assertAlmostEqual(key['orbit'], 180.0)      # 170 -> -170
        self.assertAlmostEqual(k2['orbit'], 0.0)         # -60 -> 60
        for field, want in (('pitch', 30.0), ('radius', 4.0), ('beam', 40.0),
                            ('softness', 0.4), ('intensity', 2.0),
                            ('highlight', 0.5), ('falloff', 1.5),
                            ('warmth', 6000.0)):
            self.assertAlmostEqual(key[field], want, places=5, msg=field)
        # linear RGB, not the sRGB average (0.5, 0, 0.5)
        for got, want in zip(key['color'], (0.7354, 0.0, 0.7354)):
            self.assertAlmostEqual(got, want, places=4)
        self.assertAlmostEqual(m['ambient'], 0.2)
        self.assertAlmostEqual(m['classic'], 0.25)
        for got, want in zip(m['centre'], (1.0, 2.0, 3.0)):
            self.assertAlmostEqual(got, want)
        self.assertAlmostEqual(m['size'], 4.0)
        air = m['air']
        for field, want in (('haze', 0.2), ('dust', 0.4), ('dust_size', 0.6),
                            ('dust_speed', 2.0), ('scatter', 0.0)):
            self.assertAlmostEqual(air[field], want, places=5, msg=field)
        self.assertEqual(air['seed'], 3)                 # steps with A (Q3)
        self.assertTrue(m['enabled'])
        # the core takes it as it is
        lighting.set_lights(m)
        self.assertRigAlmostEqual(cmd.get_lights(), m)

    def testShortestPathAngles(self):
        lerp = anim._lerp_angle
        self.assertAlmostEqual(lerp(160.0, -160.0, 0.5), 180.0)
        self.assertAlmostEqual(lerp(160.0, -160.0, 0.75), -170.0)
        self.assertAlmostEqual(lerp(-170.0, 170.0, 0.5), 180.0)
        self.assertAlmostEqual(lerp(-170.0, 170.0, 0.25), -175.0)
        self.assertAlmostEqual(lerp(10.0, 350.0, 0.5), 0.0)
        self.assertEqual(lerp(-37.25, 60.0, 0.0), -37.25)  # exact at t = 0
        for a, b in ((179.0, -179.0), (-90.0, 90.0), (0.0, 180.0)):
            for e in (0.0, 0.3, 0.5, 0.9, 1.0):
                v = lerp(a, b, e)
                self.assertTrue(-180.0 < v <= 180.0, (a, b, e, v))

    def testColourInLinearRgb(self):
        c = anim._lerp_color([1.0, 0.0, 0.0], [0.0, 0.0, 1.0], 0.5)
        self.assertAlmostEqual(c[0], 0.735357, places=5)
        self.assertEqual(c[1], 0.0)
        self.assertAlmostEqual(c[2], 0.735357, places=5)
        for v in (0.0, 0.02, 0.04045, 0.2, 0.5, 1.0):
            self.assertAlmostEqual(
                anim._linear_to_srgb(anim._srgb_to_linear(v)), v, places=6)
        self.assertEqual(anim._lerp_color([0.2, 0.4, 0.6], [1, 1, 1], 0.0),
                         [0.2, 0.4, 0.6])

    def testOneSidedFades(self):
        a = rig({'enabled': True, 'lights': [
            {'name': 'key'}, {'name': 'solo', 'intensity': 2.0,
                              'shadow': True}]})
        b = rig({'enabled': True, 'lights': [
            {'name': 'key'}, {'name': 'newb', 'intensity': 1.5,
                              'shadow': True, 'outline': True}]})
        m = anim.blend_target(a, b, 0.5)
        self.assertEqual([l['name'] for l in m['lights']],
                         ['key', 'solo', 'newb'])       # A's, then B's own
        solo, newb = self.light(m, 'solo'), self.light(m, 'newb')
        self.assertAlmostEqual(solo['intensity'], 1.0)
        self.assertTrue(solo['shadow'])
        self.assertAlmostEqual(newb['intensity'], 0.75)
        self.assertFalse(newb['shadow'])
        self.assertFalse(newb['outline'])
        q = anim.blend_target(a, b, 0.25)
        self.assertAlmostEqual(self.light(q, 'solo')['intensity'], 1.5)
        self.assertAlmostEqual(self.light(q, 'newb')['intensity'], 0.375)
        end = anim.blend_target(a, b, 1.0)
        self.assertTrue(self.light(end, 'newb')['shadow'])
        self.assertNotIn('solo', [l['name'] for l in end['lights']])

    def testStepFields(self):
        a = rig({'enabled': True, 'lights': [
            {'name': 'key', 'orbit': -40.0, 'pitch': 20.0, 'outline': True},
            {'name': 'pt', 'aim': 'point', 'aim_point': [0.0, 0.0, 0.0],
             'aim_selection': 'name CA'}]})
        b = rig({'enabled': True, 'lights': [
            {'name': 'key', 'anchor': 'pinned', 'position': [9.0, 9.0, 9.0],
             'aim': 'point', 'aim_point': [1.0, 1.0, 1.0], 'shadow': True},
            {'name': 'pt', 'aim': 'point', 'aim_point': [2.0, 4.0, 6.0],
             'aim_selection': 'name N'}]})
        ka, kb = self.light(a, 'key'), self.light(b, 'key')
        for t in (0.5, 0.999):
            m = anim.blend_target(a, b, t)
            key = self.light(m, 'key')
            for field in ('shadow', 'outline', 'anchor', 'aim', 'aim_point',
                          'position', 'orbit', 'pitch', 'radius'):
                # an anchor mismatch holds A's placement, an aim mismatch
                # A's aim
                self.assertEqual(key[field], ka[field], (t, field))
            pt = self.light(m, 'pt')
            self.assertEqual(pt['aim_selection'], 'name CA')
            for got, want in zip(pt['aim_point'], (2 * t, 4 * t, 6 * t)):
                self.assertAlmostEqual(got, want)
        end = anim.blend_target(a, b, 1.0)
        self.assertEqual(self.light(end, 'key'), kb)

    def testPinnedPositionsArcAroundTheCentre(self):
        def pinned_rig(centre, position):
            return {'enabled': True, 'centre': centre, 'size': 5.0,
                    'lights': [{'name': 'p', 'anchor': 'pinned',
                                'position': position}]}

        # opposite sides of the centre
        a = rig(pinned_rig([0.0, 0.0, 0.0], [10.0, 0.0, 0.0]))
        b = rig(pinned_rig([2.0, 0.0, 0.0], [-6.0, 0.0, 0.0]))
        self.assertEqual(self.light(anim.blend_rigs(a, b, 0.0), 'p')['position'],
                         [10.0, 0.0, 0.0])               # exactly pa
        for t in (0.25, 0.5, 0.75):
            m = anim.blend_rigs(a, b, t)
            c = m['centre']
            p = self.light(m, 'p')['position']
            d = math.dist(p, c)
            self.assertAlmostEqual(d, 10.0 + (8.0 - 10.0) * t, places=6)
            self.assertGreaterEqual(d, 8.0 - 1e-9)
            # deterministic: the same path every time
            self.assertEqual(anim.blend_rigs(a, b, t), m)
        # antipodal: turns about normalize(oa x y) = z, so it passes over +y
        mid = self.light(anim.blend_rigs(a, b, 0.5), 'p')['position']
        for got, want in zip(mid, (1.0, 9.0, 0.0)):
            self.assertAlmostEqual(got, want, places=6)

        # a 90-degree pair follows the shortest arc
        a = rig(pinned_rig([0.0, 0.0, 0.0], [10.0, 0.0, 0.0]))
        b = rig(pinned_rig([0.0, 0.0, 0.0], [0.0, 0.0, 10.0]))
        mid = self.light(anim.blend_rigs(a, b, 0.5), 'p')['position']
        h = 10.0 * math.sqrt(0.5)
        for got, want in zip(mid, (h, 0.0, h)):
            self.assertAlmostEqual(got, want, places=5)
        q = self.light(anim.blend_rigs(a, b, 1.0 / 3.0), 'p')['position']
        for got, want in zip(q, (10 * math.cos(math.pi / 6), 0.0,
                                 10 * math.sin(math.pi / 6))):
            self.assertAlmostEqual(got, want, places=5)

        # a vertical offset turns about the x axis
        off = anim._slerp_offset([0.0, 4.0, 0.0], [0.0, -4.0, 0.0], 0.5)
        for got, want in zip(off, (0.0, 0.0, 4.0)):
            self.assertAlmostEqual(got, want, places=6)
        # a zero-length offset lerps
        self.assertEqual(anim._slerp_offset([0, 0, 0], [4, 0, 0], 0.5),
                         [2.0, 0.0, 0.0])

    def testCaseInsensitiveMatch(self):
        a = rig({'enabled': True, 'lights': [{'name': 'Key', 'orbit': -20.0}]})
        b = rig({'enabled': True, 'lights': [{'name': 'key', 'orbit': 40.0}]})
        m = anim.blend_rigs(a, b, 0.5)
        self.assertEqual([l['name'] for l in m['lights']], ['Key'])
        self.assertAlmostEqual(m['lights'][0]['orbit'], 10.0)
        lighting.set_lights(m)

    def testUnionCap(self):
        a = rig({'enabled': True, 'lights': [
            {'name': 'a%d' % i, 'orbit': 30.0 * i, 'shadow': i < 3}
            for i in range(6)]})
        b = rig({'enabled': True, 'lights': [
            {'name': 'b%d' % i, 'orbit': -30.0 * i, 'shadow': i >= 3}
            for i in range(6)]})
        for step in range(21):
            t = step * 0.05
            m = anim.blend_target(a, b, t)
            self.assertLessEqual(len(m['lights']), 6, t)
            self.assertLessEqual(sum(l['shadow'] for l in m['lights']), 3, t)
            lighting.set_lights(m)                       # accepted
        names = lambda t: [l['name'] for l in anim.blend_target(a, b, t)['lights']]
        self.assertEqual(names(0.25), ['a%d' % i for i in range(6)])
        self.assertEqual(names(0.75), ['b%d' % i for i in range(6)])
        # a tie drops the later light first
        self.assertEqual(names(0.5), ['a%d' % i for i in range(6)])

    def testOffOrAbsentSteps(self):
        a = rig(MOVIE_A)
        self.assertEqual(anim.blend_target(a, 'off', 0.5), a)
        self.assertEqual(anim.blend_target(a, 'off', 1.0), 'off')
        self.assertEqual(anim.blend_target('off', a, 0.5), 'off')
        self.assertEqual(anim.blend_target('off', a, 1.0), a)
        self.assertIsNone(anim.blend_target(None, a, 0.5))
        self.assertIsNone(anim.blend_target(None, a, 1.0))
        self.assertIsNone(anim.blend_target(a, None, 1.0))
        disabled = dict(a, enabled=False)
        self.assertEqual(anim.blend_target(disabled, a, 0.5), disabled)

    def testLightsCommand(self):
        self.assertEqual(anim.lights_command('A', 'B', 0.5),
                         '_lights_blend 41, 42, 0.5')
        self.assertEqual(anim.lights_command("x'; y=1", 'é', 0.1894651234),
                         '_lights_blend 78273b20793d31, c3a9, 0.189465')
        self.assertEqual(anim._name_from_hex('c3a9'), 'é')
        for bad in ('', 'c3a', 'zz', ' 41', '41 ', 'ff', None, 41):
            self.assertIsNone(anim._name_from_hex(bad), bad)


class TestSceneMovieBlend(_BlendCase):
    """Done-when: a 2-scene movie changes a light smoothly."""

    def setUp(self):
        super().setUp()
        self.a = self.store('A', MOVIE_A)
        self.b = self.store('B', MOVIE_B)

    def build(self, power=0.0, linear=0):
        rebuild(scene_item(1, 'A', power, linear),
                scene_item(25, 'B', power, linear))

    def expected(self, f, a=None, b=None, power=SMOOTH):
        return anim.blend_rigs(a or self.a, b or self.b,
                               eased_t(f, power=power))

    def testRebuildBlendsFrameByFrame(self):
        self.build()
        orbits = []
        for f in range(1, 26):
            got = played(f)
            if f == 1:
                self.assertEqual(got, self.a)
            elif f == 25:
                self.assertEqual(got, self.b)
            else:
                self.assertRigAlmostEqual(got, self.expected(f), 'f%d' % f)
            orbits.append(self.light(got, 'key')['orbit'])
        self.assertEqual(orbits, sorted(orbits))         # monotone
        self.assertEqual(eased_t(13), 0.5)
        self.assertEqual(eased_t(7), 0.189465)
        mid = played(13)
        self.assertAlmostEqual(self.light(mid, 'key')['orbit'], 0.0, places=5)
        self.assertAlmostEqual(self.light(mid, 'rim')['orbit'], 180.0, places=4)
        self.assertEqual(len(mid['lights']), 4)
        # the renderer reads the blend: the packed light's radiance is the
        # blended colour x warmth x intensity
        frame = lighting._light_frame()
        self.assertTrue(frame['rig_on'])
        packed = {l['name']: l for l in frame['rig']['lights']}
        for l in mid['lights']:
            w = lighting._light_warmth(l['warmth'])
            want = [c * k * l['intensity'] for c, k in zip(l['color'], w)]
            for got, value in zip(packed[l['name']]['radiance'], want):
                self.assertAlmostEqual(got, value, places=4)

    def testRandomAccessAndBackwardScrub(self):
        self.build()
        played(1)
        self.assertRigAlmostEqual(played(13), self.expected(13))
        for f in (25, 19, 13, 7, 1):
            got = played(f)
            if f == 25:
                self.assertEqual(got, self.b)
            elif f == 1:
                self.assertEqual(got, self.a)
            else:
                self.assertRigAlmostEqual(got, self.expected(f), 'f%d' % f)

    def testLinearEasing(self):
        self.build(power=1.0, linear=1)
        for f in (2, 7, 13, 19, 24):
            self.assertEqual(anim._lights_track[f][2],
                             float('%.6g' % ((f - 1) / 24.0)))
            self.assertRigAlmostEqual(played(f),
                                      self.expected(f, power=1.0), 'f%d' % f)
        self.assertEqual(anim._lights_track[7][2], 0.25)

    def check_received(self, calls):
        """Every interior frame of every distinct pair author() received
        plays the blend at that pair's eased t."""
        (keyframes,), kw = calls[-1][0][:1], calls[-1][1]
        power = kw.get('power')
        kfs = sorted(keyframes, key=lambda k: int(k[0]))
        checked = 0
        for (f0, n0, p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
            if f1 - f0 < 2 or n0 == n1:
                continue
            pw = anim.effective_power(p0, p1, power)
            ra = raymol_scenes.scene_lights(n0)
            rb = raymol_scenes.scene_lights(n1)
            for f in range(f0 + 1, f1):
                t = eased_t(f, f0, f1, pw)
                self.assertEqual(anim._lights_track[f], (n0, n1, t))
                self.assertRigAlmostEqual(played(f), anim.blend_target(ra, rb, t),
                                          'f%d' % f)
                checked += 1
        self.assertTrue(checked)
        return kfs

    def testOtherAuthoringPaths(self):
        # the Movie Builder sheet: movie.add_scenes between its markers
        with spying(anim, 'author') as calls:
            appkit_movie.make_movie('scenes', loop=0, pause=0.5,
                                    scenes=['A', 'B'])
        kfs = self.check_received(calls)
        self.assertEqual([n for _f, n, _p in kfs], ['A', 'A', 'B', 'B'])

        # script-only paths: place_scene and append_template('scenes') blend
        # between the frames _scene_keyframes reports -- today the native
        # scene CUT frames, not the markers (a proposed follow-up updates
        # this on purpose)
        appkit_movie.reset_movie()
        cmd.mset('1 x25')
        with spying(anim, 'author') as calls:
            appkit_movie.place_scene(1, 'A')
            appkit_movie.place_scene(25, 'B')
        kfs = self.check_received(calls)
        self.assertEqual(kfs, [(1, 'A', 0.0), (13, 'B', 0.0)])

        appkit_movie.reset_movie()
        with spying(anim, 'author') as calls:
            appkit_movie.append_template('scenes', seconds_per_scene=0.5,
                                         scenes=['A', 'B'])
        self.check_received(calls)

    def testOneCompactCommandPerFrame(self):
        self.build()
        cmds = raw_movie_commands()
        self.assertEqual(len(cmds), 25)
        for f in range(1, 26):
            n = cmds[f - 1].count('_lights_blend')
            if f in (1, 25):
                self.assertEqual(n, 0, cmds[f - 1])
            else:
                self.assertEqual(n, 1, cmds[f - 1])
                self.assertIn(';_lights_blend 41, 42, %s' % ('%.6g' % eased_t(f)),
                              cmds[f - 1])

    def testEditingASceneNeedsNoReauthoring(self):
        self.build()
        other = copy.deepcopy(MOVIE_B)
        other['lights'][0]['orbit'] = 120.0
        b2 = self.set_rig(other)
        with spying(anim, 'author') as calls:
            cmd.scene('B', 'update')
        self.assertEqual(calls, [])
        self.assertRigAlmostEqual(played(13), self.expected(13, b=b2))

        # scenes stored with NO rig before authoring blend once they get rigs
        self.store('A', None)
        self.store('B', None)
        self.build()
        self.assertTrue(anim._lights_track)
        self.assertIsNone(played(13))
        self.store('A', MOVIE_A)
        self.store('B', MOVIE_B)
        lighting.set_lights(None)
        self.assertRigAlmostEqual(played(13), self.expected(13))

    def testMoviePseRoundTrip(self):
        self.build()
        before = played(13)
        track = dict(anim._lights_track)
        session = cmd.get_session()
        self.assertFalse(any('_lights_blend' in c for c in session['movie'][5]))
        self.assertEqual(session['raymol_movie_anim']['lights'],
                         [[f, 'A', 'B', track[f][2]] for f in range(2, 25)])
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            cmd.reinitialize()
            reset_module_state()
            cmd.load(filename)
        self.assertEqual(cmd.get_movie_locked(), 0)
        self.assertEqual(anim._lights_track, track)
        cmds = raw_movie_commands()
        self.assertEqual(sum(c.count('_lights_blend') for c in cmds), 23)
        lighting.set_lights(None)
        self.assertEqual(played(13), before)
        self.assertEqual(played(25), self.b)

    def testOlderBuildsIgnoreTheTrack(self):
        """Q4: an older build sees no frame command of ours (stripped) and
        reads only 'track' and 'marks', which the rig leaves as they were."""
        self.build()
        payload = cmd.get_session()['raymol_movie_anim']
        self.assertEqual(payload['track'], {})
        self.assertEqual(payload['marks'], [[1, 'A'], [25, 'B']])
        old = {'raymol_movie_anim': {'track': payload['track'],
                                     'marks': payload['marks']}}
        with spying(cmd, 'mappend') as calls:
            anim.session_restore(old)
        self.assertEqual(anim._lights_track, {})
        self.assertFalse(any('_lights_blend' in a[1] for a, _kw in calls))

    def testMalformedLightsTrack(self):
        self.build()                                     # 25 frames
        session = {'raymol_movie_anim': {'track': {}, 'marks': [], 'lights': [
            [5, 'A', 'B', 0.25],
            [6, "A'; quit", 'B', 0.5],
            [0, 'A', 'B', 0.5], ['7', 'A', 'B', 0.5], [True, 'A', 'B', 0.5],
            [8.0, 'A', 'B', 0.5], [9, 5, 'B', 0.5], [10, b'A', 'B', 0.5],
            [11, 'A', None, 0.5], [12, 'A', 'B', float('nan')],
            [13, 'A', 'B', float('inf')], [14, 'A', 'B', -0.1],
            [15, 'A', 'B', 1.1], [16, 'A', 'B'], [17, 'A', 'B', 0.5, 1],
            [18, 'A', 'B', '0.5'], [19, 'A', 'B', True], 'junk', None,
            [26, 'A', 'B', 0.5], [99999, 'A', 'B', 0.5],
            [24, 'A', 'B', 1]]}}
        out = io.StringIO()
        with spying(cmd, 'mappend') as calls, contextlib.redirect_stdout(out):
            anim.session_restore(session)
        self.assertEqual(anim._lights_track, {5: ('A', 'B', 0.25),
                                              6: ("A'; quit", 'B', 0.5),
                                              24: ('A', 'B', 1.0)})
        self.assertEqual(sorted((a[0], a[1]) for a, _kw in calls),
                         [(5, '_lights_blend 41, 42, 0.25'),
                          (6, '_lights_blend 41273b2071756974, 42, 0.5'),
                          (24, '_lights_blend 41, 42, 1')])
        self.assertEqual(out.getvalue(), '')
        # not a list at all: nothing
        anim.session_restore({'raymol_movie_anim': {'lights': 'junk'}})
        self.assertEqual(anim._lights_track, {})

    def testLightsBlendIgnoresBadInput(self):
        live = self.set_rig(RIG_B)
        bad = [('4', '42', '0.5'), ('zz', '42', '0.5'), ('ff', '42', '0.5'),
               ('41', '4', '0.5'), ('5a', '42', '0.5'), ('41', '42', 'abc'),
               ('41', '42', 'nan'), ('41', '42', 'inf'), ('', '', ''),
               (None, '42', '0.5')]
        for args in bad:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                lighting._lights_blend(*args)
                cmd._lights_blend(*args)
            self.assertEqual(out.getvalue(), '', args)
            self.assertEqual(cmd.get_lights(), live, args)
        for line in ('_lights_blend 4, 42, 0.5', '_lights_blend zz, 42, 0.5',
                     '_lights_blend ff, 42, 0.5', '_lights_blend 5a, 42, 0.5',
                     '_lights_blend 41, 42, abc', '_lights_blend 41, 42, nan',
                     '_lights_blend'):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                cmd.do(line, echo=0)
            self.assertEqual(out.getvalue(), '', line)
            self.assertEqual(cmd.get_lights(), live, line)
        # and the good command through the parser does blend
        cmd.do('_lights_blend 41, 42, 0.5', echo=0)
        self.assertRigAlmostEqual(cmd.get_lights(),
                                  anim.blend_rigs(self.a, self.b, 0.5))
        # t is clamped
        lighting._lights_blend('41', '42', '7')
        self.assertEqual(cmd.get_lights(), self.b)

    def testAuthoringLeavesTheLiveRigAlone(self):
        live = self.set_rig(RIG_B)
        self.build()
        # untouched, or what the frame on screen (rewind: frame 1) shows
        self.assertIn(cmd.get_lights(), (live, self.a))
        self.assertEqual(cmd.get_frame(), 1)

    def testShadowStepsAtTheCut(self):
        self.build()
        self.assertFalse(self.light(self.a, 'key')['shadow'])
        self.assertTrue(self.light(self.b, 'key')['shadow'])
        for f in range(1, 26):
            rig_now = played(f)
            self.assertEqual(self.light(rig_now, 'key')['shadow'], f == 25, f)
            # A's top keeps its shadow until the cut, B's fill has none
            names = [l['name'] for l in rig_now['lights']]
            if 'top' in names:
                self.assertTrue(self.light(rig_now, 'top')['shadow'], f)
            if 'fill' in names and f < 25:
                self.assertFalse(self.light(rig_now, 'fill')['shadow'], f)

    def testNoSettingOrColourWritten(self):
        """Lights never change a setting or a colour: playing a movie whose
        scenes differ only in their rigs leaves both as they were."""
        self.build()
        # (the frame and the current scene are what playing a movie changes)
        names = [n for n in setting.get_name_list()
                 if n not in ('frame', 'scene_current_name')]

        def values():
            return {n: cmd.get(n) for n in names}

        def colours():
            out = []
            cmd.iterate('all', 'out.append(color)', space={'out': out})
            return out

        settings, colors = values(), colours()
        for f in list(range(1, 26)) + [13, 1]:
            cmd.frame(f)
            self.assertEqual(values(), settings, f)
            self.assertEqual(colours(), colors, f)

    def testRiglessMovieRendersUnchanged(self):
        """With no rig anywhere the blend commands are no-ops: no rig is
        created and the renderer's lighting is the settings'."""
        self.store('A', None)
        self.store('B', None)
        lighting.set_lights(None)
        self.build()
        self.assertTrue(anim._lights_track)              # Q4: authored
        with counting(lighting, 'set_lights') as set_calls, \
                counting(lighting, '_light_set') as light_set:
            for f in range(1, 26):
                self.assertIsNone(played(f), f)
                self.assertIsNone(lighting._light_frame()['rig'], f)
        self.assertEqual((set_calls, light_set), ([], []))
        self.assertEqual(cmd.get_movie_locked(), 0)
        with testing.mktemp('.pse') as filename:
            cmd.save(filename)
            cmd.load(filename)
        self.assertEqual(cmd.get_movie_locked(), 0)
        self.assertIsNone(played(13))

        # scenes with no entry (an older .pse): no track, no 'lights' key
        raymol_scenes._scene_lights.clear()
        self.build()
        self.assertEqual(anim._lights_track, {})
        self.assertNotIn('lights', cmd.get_session()['raymol_movie_anim'])
        self.assertFalse(any('_lights_blend' in c for c in raw_movie_commands()))

    def testLoopWrapIsNotBlended(self):
        """Known limit (Q8): the loop-wrap span after the last marker has no
        keyframe pair, so the rig holds B there and pops to A at frame 1."""
        rebuild(scene_item(1, 'A'), scene_item(40, 'B', end=60))
        cmds = raw_movie_commands()
        self.assertEqual(len(cmds), 60)
        self.assertTrue(all('_lights_blend' in cmds[f - 1] for f in range(2, 40)))
        self.assertFalse(any('_lights_blend' in cmds[f - 1]
                             for f in range(40, 61)))
        # played in order: the cut at 40 applies B, which then holds
        for f in range(1, 61):
            got = played(f)
            if f >= 40:
                self.assertEqual(got, self.b, f)
        self.assertEqual(played(1), self.a)


# --- the L2 scene file (scripts/lighting/scenes/lighting_617_movie.json) ----

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                     os.pardir, os.pardir, os.pardir))
RENDER = os.path.join(ROOT, 'scripts', 'lighting', 'render.py')
MOVIE_FILE = os.path.join(ROOT, 'scripts', 'lighting', 'scenes',
                          'lighting_617_movie.json')
PDB_1RX1 = os.path.join(ROOT, 'testing', 'data', '1rx1.pdb')
MOVIE_FILE_TAGS = ['movie_f01_rt0', 'movie_f07_rt0', 'movie_f13_rt0',
                   'movie_f19_rt0', 'movie_f25_rt0', 'movie_f01_rt1',
                   'movie_f13_rt1', 'movie_f25_rt1', 'recall_b_rt0']
# The light count the harness marker records per frame: A's 3, the union of
# A and B (key, rim, top, fill) while blending, B's 3.
MARKER_LIGHTS = {1: 3, 7: 4, 13: 4, 19: 4, 25: 3}


@contextlib.contextmanager
def capture_console():
    """Collect what is written to fd 1 while open (yields a getter). The
    core's feedback (a Movie-Error) is printed by C straight to fd 1, where
    contextlib.redirect_stdout never sees it (as in lighting_session.py);
    Python's own prints are caught as well."""
    sys.stdout.flush()
    saved = os.dup(1)
    tmp = tempfile.TemporaryFile(mode='w+b')
    buf = io.StringIO()
    result = {}
    try:
        os.dup2(tmp.fileno(), 1)
        with contextlib.redirect_stdout(buf):
            yield lambda: result['text']
        sys.stdout.flush()
    finally:
        os.dup2(saved, 1)
        os.close(saved)
        tmp.seek(0)
        result['text'] = tmp.read().decode(errors='replace') + buf.getvalue()
        tmp.close()


def job_frame(tag):
    """The movie frame of a movie tag ('movie_f07_rt0' -> 7), else None."""
    if not tag.startswith('movie_f'):
        return None
    return int(tag[len('movie_f'):].split('_', 1)[0])


@unittest.skipUnless(os.path.isfile(RENDER) and os.path.isfile(PDB_1RX1),
                     'needs a RayMol checkout (scripts/lighting)')
class TestMovieSceneFile(_BlendCase):
    """The L2 scene file: the frozen harness's scene scripts build the
    2-scene movie through appkit_movie.rebuild and go to one frame each,
    or recall scene B. Each script runs twice in this process, as the app
    runs PYMOL_AUTOCMD (at launch and again before the export).

    The CI workflow runs every test file in one process: the file wraps
    cmd.set_lights, so tearDown puts it back and deletes every cmd._l617_*
    attribute (lighting_harness.py's scripts call cmd.set_lights)."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        spec = importlib.util.spec_from_file_location('lighting_render_617',
                                                      RENDER)
        cls.render = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.render)

    def setUp(self):
        super().setUp()
        self.tmp = tempfile.mkdtemp(prefix='l617')
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.original_set_lights = cmd.set_lights

    def tearDown(self):
        cmd.set_lights = self.original_set_lights
        for name in [n for n in dir(cmd) if n.startswith('_l617_')]:
            delattr(cmd, name)
        super().tearDown()

    def run_twice(self, job, out):
        """Write the job's scene script and run it twice. Returns the rig
        after each run and what the second run printed."""
        render = self.render
        render.write_scripts(ROOT, out, [job])
        path = render.script_path(out, job.tag)
        cmd.run(path)
        first = cmd.get_lights()
        with capture_console() as printed:
            cmd.run(path)
        return first, cmd.get_lights(), printed()

    def testTheFileAndItsPaths(self):
        # render.py refuses a --scenes path, tag, scene script or image name
        # the app would split or act on (FORBIDDEN_WORDS are substrings).
        render = self.render
        self.assertTrue(os.path.isfile(MOVIE_FILE), MOVIE_FILE)
        render.check_path('--scenes', os.path.relpath(MOVIE_FILE, ROOT))
        jobs = render.scene_file_jobs(MOVIE_FILE)
        self.assertEqual([j.tag for j in jobs], MOVIE_FILE_TAGS)
        out = os.path.join('out', 'l2')
        with open(MOVIE_FILE) as handle:
            extra = json.load(handle)['extra']
        for job in jobs:
            render.check_path('tag', job.tag)
            render.check_path('scene script', render.script_path(out, job.tag))
            render.check_path('image', render.png_path(out, job.tag))
            # the L1 shadows scene with the harness's rig on, recoloured
            l1 = render.l1_job('shadows_rt%d' % job.rt, 'on')
            self.assertEqual(
                (job.rig, job.rep_lines, job.shadows, job.size),
                ('on', l1.rep_lines, l1.shadows, l1.size), job.tag)
            self.assertEqual(job.rt, int(job.tag[-1]), job.tag)
            self.assertEqual(job.extra[:len(extra)], extra, job.tag)
            self.assertEqual(job.extra[-1], "cmd.color('grey80', 'm')",
                             job.tag)

    def testLighting617MovieFile(self):
        render = self.render
        out = os.path.join(self.tmp, 'l2')
        got = {}
        for job in render.scene_file_jobs(MOVIE_FILE):
            first, second, printed = self.run_twice(job, out)
            tag, frame = job.tag, job_frame(job.tag)
            # the harness's own check: both runs left their line, rig on
            marker = render.marker_path(out, tag)
            self.assertIsNone(render.check_marker(marker, tag, job.rig), tag)
            with open(marker) as handle:
                rows = [json.loads(line) for line in handle]
            want = MARKER_LIGHTS[frame] if frame else 3
            self.assertEqual([r['rig']['lights'] for r in rows], [want, want],
                             tag)
            # both runs agree, and the second (after reinitialize, with the
            # first run's movie gone) authors cleanly
            self.assertEqual(first, second, tag)
            self.assertNotIn('Movie-Error', printed, tag)
            self.assertNotIn('MOVIE_ERR', printed, tag)
            self.assertNotIn('Traceback', printed, tag)
            if frame:
                self.assertEqual(cmd.get_frame(), frame, tag)
                self.assertEqual(cmd.get_movie_length(), 25, tag)
            # wrapped once: the original stays reachable
            self.assertIs(cmd._l617_set, self.original_set_lights)
            got[tag] = (second, raymol_scenes.scene_lights('A'),
                        raymol_scenes.scene_lights('B'))

        a = got['movie_f01_rt0'][1]
        b = got['movie_f01_rt0'][2]
        self.assertEqual([l['name'] for l in a['lights']], ['key', 'rim', 'top'])
        self.assertEqual([l['name'] for l in b['lights']], ['key', 'rim', 'fill'])
        self.assertTrue(self.light(b, 'key')['shadow'])
        for tag, (rig_now, sa, sb) in got.items():
            # every script stores the same two rigs
            self.assertEqual((sa, sb), (a, b), tag)
            frame = job_frame(tag)
            if frame == 1:
                self.assertEqual(rig_now, a, tag)
            elif frame == 25 or tag == 'recall_b_rt0':
                self.assertEqual(rig_now, b, tag)
            else:
                self.assertRigAlmostEqual(
                    rig_now, anim.blend_rigs(a, b, eased_t(frame)), tag)
        self.assertEqual(eased_t(13), 0.5)
        mid = got['movie_f13_rt0'][0]
        self.assertAlmostEqual(self.light(mid, 'key')['orbit'], 0.0, places=4)
        self.assertAlmostEqual(abs(self.light(mid, 'rim')['orbit']), 180.0,
                               places=4)
        self.assertEqual(got['movie_f13_rt1'][0], mid)

        # the capture sees the core's feedback (so the checks above bite)
        with capture_console() as printed:
            cmd.mdo(cmd.get_movie_length() + 5, '')
        self.assertIn('Movie-Error', printed())

    def testBuilderChecksBite(self):
        # a wrong frame or rig raises from the builder, which stops the
        # scene script before the harness marker
        render = self.render
        out = os.path.join(self.tmp, 'bite')
        jobs = {j.tag: j for j in render.scene_file_jobs(MOVIE_FILE)}
        self.run_twice(jobs['movie_f13_rt0'], out)
        cmd._l617_check(cmd, 13)                       # passes as built
        with self.assertRaisesRegex(RuntimeError, 'l617 frame 7'):
            cmd._l617_check(cmd, 7)                    # the rig is f13's
        cmd._l617_expect[13] = (4, 0.0, 1.4, True, 180.0)
        with self.assertRaisesRegex(RuntimeError, 'l617 frame 13'):
            cmd._l617_check(cmd, 13)                   # key shadow differs
        self.run_twice(jobs['recall_b_rt0'], out)
        cmd._l617_rig_b = rig(MOVIE_A)
        with self.assertRaisesRegex(RuntimeError, 'l617 recall of scene B'):
            cmd._l617_recall_b(cmd)
        # with neither attribute set the wrapper is the plain setter
        cmd._l617_frame, cmd._l617_recall = 0, False
        cmd.set_lights(copy.deepcopy(MOVIE_B))
        self.assertEqual([l['name'] for l in cmd.get_lights()['lights']],
                         ['key', 'rim', 'fill'])
