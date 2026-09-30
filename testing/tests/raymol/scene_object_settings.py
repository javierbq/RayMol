"""Per-object capture of object-scoped settings in scenes (#483).

`raymol_scenes` used to capture only globals, and the per-rep materials are
object-scoped: a scene could record the global fallback and nothing else, so
"this object is metallic, that one is not" was not expressible and an
override added after the scene was stored survived every recall. These tests
drive the real `cmd.scene` hook.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/scene_object_settings.py
"""
from pymol import cmd, testing
from pymol import raymol_scenes as rs

SETTING = 'cartoon_material'   # any object-scoped setting OBJECT_CAPTURE lists
OTHER = 'surface_material'


class TestSceneObjectSettings(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        # A distinctive global fallback: every "unset" assertion below reads it
        # back through the object, which is how an absent override shows up.
        cmd.set(SETTING, 2)

    def _objval(self, obj, name=SETTING):
        return cmd.get_setting_int(name, obj)

    def testCapturesPerObjectAndRecallsEachScene(self):
        cmd.set(SETTING, 3, 'm1')
        cmd.scene('A', 'store')
        cmd.unset(SETTING, 'm1')
        cmd.set(SETTING, 7, 'm2')
        cmd.scene('B', 'store')

        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 3)
        self.assertEqual(self._objval('m2'), 2)  # unset -> global

        cmd.scene('B', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 2)  # unset on apply
        self.assertEqual(self._objval('m2'), 7)

    def testRecallUnsetsAnOverrideAddedAfterTheStore(self):
        cmd.scene('A', 'store')                     # neither object has one
        cmd.set(SETTING, 9, 'm1')
        self.assertEqual(self._objval('m1'), 9)
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 2)

    def testGlobalIsNeverBakedOntoAnObject(self):
        """The capture reads each object's own table, so a global value that no
        object overrides must not be written into the per-object map (it would
        turn a global into N object-level settings on the first recall)."""
        cmd.scene('A', 'store')
        captured = rs.scene_object_settings_map('A')
        self.assertEqual(sorted(captured), ['m1', 'm2'])
        self.assertEqual(captured['m1'], {})
        self.assertEqual(captured['m2'], {})

    def testCapturesEverySettingInTheList(self):
        cmd.set(OTHER, 4, 'm2')
        cmd.scene('A', 'store')
        self.assertAlmostEqual(
            rs.scene_object_settings_map('A')['m2'][OTHER], 4)

    def testAnObjectGoneAtRecallDoesNotStopTheRest(self):
        """The deleted object must be skipped, not abort the loop: m2's value
        still has to be applied after m1 has gone."""
        cmd.set(SETTING, 3, 'm1')
        cmd.set(SETTING, 8, 'm2')
        cmd.scene('A', 'store')
        cmd.delete('m1')
        cmd.unset(SETTING, 'm2')
        cmd.scene('A', 'recall', animate=0)         # must not raise
        self.assertEqual(cmd.get_names('objects'), ['m2'])
        self.assertEqual(self._objval('m2'), 8)

    def testRenameKeepsPerObjectCapture(self):
        cmd.set(SETTING, 3, 'm1')
        cmd.scene('A', 'store')
        cmd.scene('A', 'rename', new_key='C')
        self.assertEqual(rs.scene_object_settings_map('A'), {})
        cmd.unset(SETTING, 'm1')
        cmd.scene('C', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 3)

    def testDeleteScenePrunesTheCapture(self):
        cmd.set(SETTING, 3, 'm1')
        cmd.scene('A', 'store')
        cmd.scene('B', 'store')
        cmd.scene('A', 'delete')
        self.assertEqual(rs.scene_object_settings_map('A'), {})
        self.assertNotEqual(rs.scene_object_settings_map('B'), {})

    def testAGroupIsNeverCapturedOrApplied(self):
        """`get_names('objects')` includes groups, and `cmd.set`/`cmd.unset`
        expand a group name to its MEMBERS. Capturing a group would record its
        own (empty) table and then unset the setting on every member on recall,
        wiping the very overrides this module restores."""
        cmd.set(SETTING, 3, 'm1')
        cmd.group('grp', 'm1 m2')
        cmd.scene('A', 'store')
        self.assertNotIn('grp', rs.scene_object_settings_map('A'))
        self.assertEqual(sorted(rs.scene_object_settings_map('A')), ['m1', 'm2'])
        cmd.unset(SETTING, 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 3)

    def testALegacyMapNamingAGroupIsIgnored(self):
        """A .pse written before the guard existed can still carry a group."""
        cmd.set(SETTING, 3, 'm1')
        cmd.group('grp', 'm1 m2')
        cmd.scene('A', 'store')
        rs._scene_object_settings['A']['grp'] = {}       # as the old build stored it
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 3)

    def testAGroupDoesNotWipeAMemberObjectTTT(self):
        """`set_object_ttt` expands a group to its members exactly as `set`
        does, so capturing the group and resetting it to identity on recall
        wiped every member's Move-mode transform."""
        moved = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 7, 0, 0, 1]
        cmd.set_object_ttt('m1', moved)
        cmd.group('grp', 'm1 m2')
        cmd.scene('A', 'store')
        cmd.set_object_ttt('m1', list(rs._IDENTITY_TTT))
        cmd.scene('A', 'recall', animate=0)
        self.assertAlmostEqual(cmd.get_object_ttt('m1')[12], 7.0, places=5)

    def testPSERoundTrip(self):
        cmd.set(SETTING, 3, 'm1')
        cmd.set(OTHER, 5, 'm1')
        cmd.scene('A', 'store')
        cmd.set(SETTING, 7, 'm2')
        cmd.unset(SETTING, 'm1')
        cmd.scene('B', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            rs.clear_all()
            cmd.load(fn)
        self.assertAlmostEqual(
            rs.scene_object_settings_map('A')['m1'][SETTING], 3)
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 3)
        self.assertEqual(self._objval('m1', OTHER), 5)
        self.assertEqual(self._objval('m2'), 2)
        cmd.scene('B', 'recall', animate=0)
        self.assertEqual(self._objval('m1'), 2)
        self.assertEqual(self._objval('m2'), 7)


class TestLegacyPayload(testing.PyMOLTestCase):
    """A .pse written before per-object capture existed carries only the flat
    `raymol_scene_settings` payload."""

    def setUp(self):
        super().setUp()
        rs.clear_all()

    def tearDown(self):
        rs.clear_all()
        super().tearDown()

    def testFlatPayloadRestoresWithoutError(self):
        session = {'raymol_scene_settings': {'A': {SETTING: 6, 'metal_dof': 1}}}
        self.assertEqual(rs.session_restore(session), 1)
        self.assertEqual(rs.scene_settings_map('A'), {SETTING: 6, 'metal_dof': 1})
        self.assertEqual(rs.scene_object_settings_map('A'), {})

    def testLegacySceneRecallLeavesObjectOverridesAlone(self):
        """No per-object map means "unknown", not "nothing was set": recalling a
        legacy scene must not unset overrides the user has on the object."""
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.set(SETTING, 2)
        cmd.scene('A', 'store')
        rs._scene_object_settings.pop('A', None)        # as a legacy .pse restores
        cmd.set(SETTING, 9, 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int(SETTING, 'm1'), 9)

    def testMalformedPayloadIsDroppedNotRaised(self):
        for payload in ([], 'nonsense', {'A': 7}, {'A': {'m1': 3}}):
            session = {'raymol_scene_object_settings': payload}
            self.assertEqual(rs.session_restore(session), 1)
            self.assertEqual(rs.scene_object_settings_map('A'), {})

    def testSaveRestoreRoundTripsTheMap(self):
        rs._scene_object_settings['A'] = {'m1': {SETTING: 3}, 'm2': {}}
        session = {}
        rs.session_save(session)
        rs.clear_all()
        rs.session_restore(session)
        self.assertEqual(rs.scene_object_settings_map('A'),
                         {'m1': {SETTING: 3}, 'm2': {}})
