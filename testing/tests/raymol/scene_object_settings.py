"""Per-object capture of object-scoped settings in scenes (#483).

`raymol_scenes` used to capture only globals, and `metal_rt_reflect*` are
object-scoped: a scene could record the global fallback and nothing else, so
"this object is reflective, that one is not" was not expressible and an
override added after the scene was stored survived every recall. These tests
drive the real `cmd.scene` hook.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/scene_object_settings.py
"""
from pymol import cmd, testing
from pymol import raymol_scenes as rs

REFLECT = 'metal_rt_reflect'
TINT = 'metal_rt_reflect_tint'


class TestSceneObjectSettings(testing.PyMOLTestCase):
    def setUp(self):
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        # A distinctive global fallback: every "unset" assertion below reads it
        # back through the object, which is how an absent override shows up.
        cmd.set(REFLECT, 0.25)

    def _objval(self, obj, name=REFLECT):
        return float(cmd.get(name, obj))

    def testCapturesPerObjectAndRecallsEachScene(self):
        cmd.set(REFLECT, 1.0, 'm1')
        cmd.scene('A', 'store')
        cmd.unset(REFLECT, 'm1')
        cmd.set(REFLECT, 0.5, 'm2')
        cmd.scene('B', 'store')

        cmd.scene('A', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 1.0, places=5)
        self.assertAlmostEqual(self._objval('m2'), 0.25, places=5)  # unset -> global

        cmd.scene('B', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 0.25, places=5)  # unset on apply
        self.assertAlmostEqual(self._objval('m2'), 0.5, places=5)

    def testRecallUnsetsAnOverrideAddedAfterTheStore(self):
        cmd.scene('A', 'store')                     # neither object has one
        cmd.set(REFLECT, 0.9, 'm1')
        self.assertAlmostEqual(self._objval('m1'), 0.9, places=5)
        cmd.scene('A', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 0.25, places=5)

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
        cmd.set(TINT, 0.8, 'm2')
        cmd.scene('A', 'store')
        self.assertAlmostEqual(
            rs.scene_object_settings_map('A')['m2'][TINT], 0.8, places=5)

    def testObjectsGoneAtRecallAreSkipped(self):
        cmd.set(REFLECT, 1.0, 'm1')
        cmd.scene('A', 'store')
        cmd.delete('m1')
        cmd.scene('A', 'recall', animate=0)         # must not raise
        self.assertEqual(cmd.get_names('objects'), ['m2'])

    def testRenameKeepsPerObjectCapture(self):
        cmd.set(REFLECT, 1.0, 'm1')
        cmd.scene('A', 'store')
        cmd.scene('A', 'rename', new_key='C')
        self.assertEqual(rs.scene_object_settings_map('A'), {})
        cmd.unset(REFLECT, 'm1')
        cmd.scene('C', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 1.0, places=5)

    def testDeleteScenePrunesTheCapture(self):
        cmd.set(REFLECT, 1.0, 'm1')
        cmd.scene('A', 'store')
        cmd.scene('B', 'store')
        cmd.scene('A', 'delete')
        self.assertEqual(rs.scene_object_settings_map('A'), {})
        self.assertNotEqual(rs.scene_object_settings_map('B'), {})

    def testPSERoundTrip(self):
        cmd.set(REFLECT, 1.0, 'm1')
        cmd.set(TINT, 0.7, 'm1')
        cmd.scene('A', 'store')
        cmd.set(REFLECT, 0.5, 'm2')
        cmd.unset(REFLECT, 'm1')
        cmd.scene('B', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            rs.clear_all()
            cmd.load(fn)
        self.assertAlmostEqual(
            rs.scene_object_settings_map('A')['m1'][REFLECT], 1.0, places=5)
        cmd.scene('A', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 1.0, places=5)
        self.assertAlmostEqual(self._objval('m1', TINT), 0.7, places=5)
        self.assertAlmostEqual(self._objval('m2'), 0.25, places=5)
        cmd.scene('B', 'recall', animate=0)
        self.assertAlmostEqual(self._objval('m1'), 0.25, places=5)
        self.assertAlmostEqual(self._objval('m2'), 0.5, places=5)


class TestLegacyPayload(testing.PyMOLTestCase):
    """A .pse written before per-object capture existed carries only the flat
    `raymol_scene_settings` payload."""

    def setUp(self):
        rs.clear_all()

    def tearDown(self):
        rs.clear_all()

    def testFlatPayloadRestoresWithoutError(self):
        session = {'raymol_scene_settings': {'A': {REFLECT: 0.4, 'metal_dof': 1}}}
        self.assertEqual(rs.session_restore(session), 1)
        self.assertEqual(rs.scene_settings_map('A'), {REFLECT: 0.4, 'metal_dof': 1})
        self.assertEqual(rs.scene_object_settings_map('A'), {})

    def testLegacySceneRecallLeavesObjectOverridesAlone(self):
        """No per-object map means "unknown", not "nothing was set": recalling a
        legacy scene must not unset overrides the user has on the object."""
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.set(REFLECT, 0.25)
        cmd.scene('A', 'store')
        rs._scene_object_settings.pop('A', None)        # as a legacy .pse restores
        cmd.set(REFLECT, 0.9, 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertAlmostEqual(float(cmd.get(REFLECT, 'm1')), 0.9, places=5)

    def testMalformedPayloadIsDroppedNotRaised(self):
        for payload in ([], 'nonsense', {'A': 7}, {'A': {'m1': 3}}):
            session = {'raymol_scene_object_settings': payload}
            self.assertEqual(rs.session_restore(session), 1)
            self.assertEqual(rs.scene_object_settings_map('A'), {})

    def testSaveRestoreRoundTripsTheMap(self):
        rs._scene_object_settings['A'] = {'m1': {REFLECT: 1.0}, 'm2': {}}
        session = {}
        rs.session_save(session)
        rs.clear_all()
        rs.session_restore(session)
        self.assertEqual(rs.scene_object_settings_map('A'),
                         {'m1': {REFLECT: 1.0}, 'm2': {}})
