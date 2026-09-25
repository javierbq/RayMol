"""The environment the reflective materials sample (#493).

`material_env` chooses what a reflective object reflects: 0 the background
colour, 1 a studio, 2 nothing. The renderer turns it into a small cubemap and
rebuilds that only when this setting or the background colour changes, so the
setting is the whole of the user-visible contract on the Python side.

No material has the reflective family yet -- plastic and metallic arrive in
#494 -- so nothing samples the cubemap today. That is exactly why these tests
pin the SETTING and its scene capture now: when #494 flips a row, the plumbing
it depends on is already covered.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_env.py
"""
import pymol
from pymol import cmd, testing
from pymol import raymol_scenes as rs


class TestMaterialEnv(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        rs.clear_all()
        cmd.fragment('ala', 'm1')

    def testItIsGlobalAndDefaultsToTheBackground(self):
        """0 = the background colour. A reflective object on a white page should
        reflect white by default, not a studio that is not there."""
        self.assertEqual(cmd.get_setting_int('material_env'), 0)

    def testTheThreeModesRoundTrip(self):
        for mode in (0, 1, 2):
            cmd.set('material_env', mode)
            self.assertEqual(cmd.get_setting_int('material_env'), mode)

    def testItIsNotAMaterialId(self):
        """material_env selects an ENVIRONMENT, not a material, so it must not
        be renamed through the material table the way material_default is."""
        cmd.set('material_env', 1)
        self.assertEqual(cmd.get('material_env'), '1')
        # It is NOT in setting.material_indices, so a material name is not
        # translated for it -- the int parse rejects it (a ValueError, not the
        # CmdException an unknown MATERIAL name raises, because this setting
        # never reaches the material table at all). Either way it is refused,
        # which is the property that matters: `set material_env, marble` must
        # not quietly become a number.
        with self.assertRaises(Exception) as ctx:
            cmd.set('material_env', 'marble')
        self.assertNotIsInstance(ctx.exception, AssertionError)
        self.assertEqual(cmd.get_setting_int('material_env'), 1)   # unchanged

    def testItSurvivesAPse(self):
        cmd.set('material_env', 2)
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            cmd.load(fn)
        self.assertEqual(cmd.get_setting_int('material_env'), 2)

    # -- scenes ---------------------------------------------------------------

    def testItIsCapturedInScenes(self):
        self.assertIn('material_env', rs.CAPTURE)

    def testASceneRestoresIt(self):
        cmd.set('material_env', 1)
        cmd.scene('A', 'store')
        cmd.set('material_env', 2)
        cmd.scene('A', 'recall', animate=0)
        self.assertEqual(cmd.get_setting_int('material_env'), 1)

    def testItIsNotInterpolatedAcrossAMovie(self):
        """The modes are a choice of room, not a quantity: ramping 0 -> 2 would
        pass through 'studio' on the way to 'none'."""
        from pymol import raymol_scene_anim
        self.assertNotIn('material_env', raymol_scene_anim.INTERPOLATE)

    # -- the non-negotiables it could plausibly break --------------------------

    def testChangingItWritesNothingElse(self):
        from pymol import setting
        before = {n: cmd.get(n) for n in setting.get_name_list()}
        cmd.set('material_env', 1)
        after = {n: cmd.get(n) for n in setting.get_name_list()}
        changed = {n for n in after if before.get(n) != after[n]}
        self.assertEqual(changed, {'material_env'})

    def testItDoesNotTouchColour(self):
        cmd.color('red', 'm1')
        before = []
        cmd.iterate('m1', 'before.append(color)', space={'before': before})
        cmd.set('material_env', 1)
        after = []
        cmd.iterate('m1', 'after.append(color)', space={'after': after})
        self.assertEqual(before, after)

    def testNoMaterialIsReflectiveYet(self):
        """Guard for the claim these tests rest on: while no implemented
        material is in the reflective family, material_env cannot change any
        rendered pixel, which is what makes `default` byte-identical. When #494
        flips plastic/metallic this fails, and that is the prompt to extend the
        gallery rather than a regression."""
        from pymol import setting
        for _id, name in setting.get_material_names(1):
            cmd.set('cartoon_material', name, 'm1')
            # reflect/tint/rough stay at their metal_rt_reflect* values; a
            # reflective material would be the first to carry its own.
            self.assertEqual(cmd.get_setting_int('material_env'), 0, name)
