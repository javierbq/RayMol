"""Materials in scenes (#489).

A scene stores what each object is MADE OF, not just how it is lit: the four
per-representation material settings and `transparency_peel` per object, and
`material_default` / `material_env` globally. Ids step at a scene cut -- there
is nothing meaningful to interpolate between two materials -- so they are
captured, never ramped.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/scene_materials.py
"""
from pymol import cmd, testing
from pymol import raymol_scenes as rs

REP_MATERIALS = ['cartoon_material', 'surface_material',
                 'stick_material', 'sphere_material']


class TestSceneMaterials(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    def testEveryMaterialSettingIsCaptured(self):
        for name in REP_MATERIALS:
            self.assertIn(name, rs.OBJECT_CAPTURE, name)
        self.assertIn('transparency_peel', rs.OBJECT_CAPTURE)
        for name in ('material_default', 'material_env'):
            self.assertIn(name, rs.CAPTURE, name)

    def testMaterialsAreNotInterpolated(self):
        """A material id is a table row, not a quantity: ramping 7 -> 8 would
        walk through unrelated materials."""
        from pymol import raymol_scene_anim
        for name in REP_MATERIALS + ['transparency_peel', 'material_default',
                                     'material_env']:
            self.assertNotIn(name, raymol_scene_anim.INTERPOLATE, name)

    def testPerObjectMaterialsRecallPerScene(self):
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('surface_material', 'clay', 'm2')
        cmd.scene('A', 'store')
        cmd.set('cartoon_material', 'rubber', 'm1')
        cmd.unset('surface_material', 'm2')
        cmd.scene('B', 'store')

        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('surface_material', 'm2'), 'clay')
        cmd.scene('B', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'rubber')
        # ...and the object that lost its material gets it UNSET, not left behind.
        self.assertEqual(cmd.get_setting_int('surface_material', 'm2'), 0)

    def testTheGlobalDefaultIsCapturedAsAnId(self):
        """`cmd.get` renders material_default as a NAME; the scene stores the
        id, which is what the rest of the .pse format uses."""
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        self.assertEqual(rs.scene_settings_map('A')['material_default'], 8)

    def testTheGlobalDefaultRecalls(self):
        cmd.set('material_default', 'clay')
        cmd.scene('A', 'store')
        cmd.set('material_default', 'default')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('material_default'), 'clay')

    def testPeelIsCapturedPerObject(self):
        cmd.set('transparency_peel', 1, 'm1')
        cmd.scene('A', 'store')
        cmd.set('transparency_peel', 0, 'm1')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)

    def testTwoObjectsWithDifferentMaterialsRoundTripThroughAPse(self):
        cmd.set('cartoon_material', 'marble', 'm1')
        cmd.set('cartoon_material', 'rubber', 'm2')
        cmd.set('material_default', 'matte')
        cmd.scene('A', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            rs.clear_all()
            cmd.load(fn)
        # the live values survive the session...
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('cartoon_material', 'm2'), 'rubber')
        # ...and so does the scene that captured them.
        cmd.set('cartoon_material', 'default', 'm1')
        cmd.set('cartoon_material', 'default', 'm2')
        cmd.set('material_default', 'default')
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('cartoon_material', 'm2'), 'rubber')
        self.assertEqual(cmd.get('material_default'), 'matte')

    def testAMaterialIsNeverBakedOntoAnObjectThatHasNone(self):
        cmd.set('material_default', 'clay')      # global only
        cmd.scene('A', 'store')
        captured = rs.scene_object_settings_map('A')
        for obj in ('m1', 'm2'):
            self.assertNotIn('cartoon_material', captured[obj], obj)
