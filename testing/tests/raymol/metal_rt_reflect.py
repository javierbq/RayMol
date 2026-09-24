"""Traced self-reflection material settings (metal_rt_reflect*).

The Metal ray-traced composite reads a per-object material (reflect / tint /
roughness) and two global knobs (environment on miss, export samples). This
checks the settings exist with distinct indices (a duplicate index silently
truncates the table: the first cut of this feature reused 831, which
cartoon_spline already owned, and the last three settings vanished), that the
defaults keep reflections off, and that the object-scoped ones override per
object with a global fallback.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run tests/raymol/metal_rt_reflect.py
"""
from pymol import cmd, setting, testing

OBJECT_SCOPED = ['metal_rt_reflect', 'metal_rt_reflect_tint', 'metal_rt_reflect_rough']
GLOBAL = ['metal_rt_reflect_env', 'metal_rt_reflect_samples']


class TestMetalRTReflectSettings(testing.PyMOLTestCase):
    def testDistinctIndices(self):
        names = OBJECT_SCOPED + GLOBAL
        indices = [setting._get_index(n) for n in names]
        self.assertEqual(len(set(indices)), len(indices), indices)
        # None may collide with a pre-existing setting either: every name must
        # be registered exactly once, and the index must round-trip to it.
        index_to_name = {v: k for k, v in setting.index_dict.items()}
        for n, i in zip(names, indices):
            self.assertEqual(setting.name_list.count(n), 1, n)
            self.assertEqual(index_to_name[i], n)

    def testDefaultsOff(self):
        for n in OBJECT_SCOPED:
            self.assertAlmostEqual(float(cmd.get(n)), 0.0, msg=n)
        self.assertEqual(int(cmd.get('metal_rt_reflect_env')), 1)
        self.assertGreaterEqual(int(cmd.get('metal_rt_reflect_samples')), 1)

    def testPerObjectOverride(self):
        cmd.pseudoatom('m1')
        cmd.pseudoatom('m2')
        cmd.set('metal_rt_reflect', 0.3)          # global default
        cmd.set('metal_rt_reflect', 1.0, 'm2')    # per-object override
        cmd.set('metal_rt_reflect_tint', 0.8, 'm2')
        self.assertAlmostEqual(float(cmd.get('metal_rt_reflect', 'm1')), 0.3, places=5)
        self.assertAlmostEqual(float(cmd.get('metal_rt_reflect', 'm2')), 1.0, places=5)
        self.assertAlmostEqual(float(cmd.get('metal_rt_reflect_tint', 'm1')), 0.0, places=5)
        self.assertAlmostEqual(float(cmd.get('metal_rt_reflect_tint', 'm2')), 0.8, places=5)
        cmd.unset('metal_rt_reflect', 'm2')
        self.assertAlmostEqual(float(cmd.get('metal_rt_reflect', 'm2')), 0.3, places=5)
