"""Traced-reflection settings after #565.

The object-wide `metal_rt_reflect` / `_tint` / `_rough` triple predated
materials and never shipped. It is retired: reflection now comes from each
layer's material (reflective materials carry their own; per-layer tuning is the
Custom material). Its indices 833-835 are kept as blank slots, so no other
setting's index moves and a .pse written by a dev build loads.

The two GLOBAL knobs that are not part of the triple stay: the environment a
reflection ray sees on a miss, and the ray count for exports.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run tests/raymol/metal_rt_reflect.py
"""
from pymol import cmd, setting, testing

RETIRED = ['metal_rt_reflect', 'metal_rt_reflect_tint', 'metal_rt_reflect_rough']
GLOBAL = ['metal_rt_reflect_env', 'metal_rt_reflect_samples']


class TestMetalRTReflectSettings(testing.PyMOLTestCase):
    def testTheTripleIsGone(self):
        for n in RETIRED:
            self.assertNotIn(n, setting.name_list, n)
            with self.assertRaises(Exception, msg=n):
                cmd.set(n, 0.5)

    def testItsIndicesStayReservedSoNothingElseMoved(self):
        # the neighbours on both sides keep their indices
        self.assertEqual(setting._get_index('metal_rt_scale'), 832)
        self.assertEqual(setting._get_index('metal_rt_reflect_env'), 836)
        # ...and the three slots are blank, not handed to a new setting
        index_to_name = {v: k for k, v in setting.index_dict.items()}
        for i in (833, 834, 835):
            self.assertFalse(index_to_name.get(i), i)

    def testTheGlobalKnobsRemain(self):
        for n in GLOBAL:
            self.assertEqual(setting.name_list.count(n), 1, n)
        # cmd.get() renders a boolean as 'on'/'off', so read the typed getter.
        self.assertEqual(cmd.get_setting_boolean('metal_rt_reflect_env'), 1)
        self.assertGreaterEqual(cmd.get_setting_int('metal_rt_reflect_samples'), 1)
