"""The material settings block: indices, names, scope (#484).

Materials (#503) are stored as integer ids in five settings and read back as
NAMES from C, the way colour settings are. Two things can go silently wrong and
are guarded here:

  * A duplicate setting index truncates the generated table, and the settings
    past the duplicate simply vanish (this happened once already: the first cut
    of `metal_rt_reflect` reused 831, which `cartoon_spline` owned).
  * A selection-scoped `set` of an int setting writes an atom-level value that
    no draw path reads: the user gets a success message and no change. C
    refuses it for the four per-representation material settings.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_settings.py
"""
from pymol import cmd, setting, testing

import pymol

# (name, expected index) — the block is contiguous from 838 by design; the
# existing metal_* indices must never move, because .pse files hold indices.
BLOCK = [
    ('cartoon_material', 838),
    ('surface_material', 839),
    ('stick_material', 840),
    ('sphere_material', 841),
    ('material_default', 842),
    ('material_env', 843),
    ('transparency_peel', 844),
]

REP_MATERIALS = ['cartoon_material', 'surface_material',
                 'stick_material', 'sphere_material']

# Every material the table knows, id -> name. Ids are append-only: they are
# written into .pse files.
MATERIAL_NAMES = [
    'default', 'matte', 'plastic', 'metallic', 'glass',
    'frosted_glass', 'jelly', 'marble', 'clay', 'rubber',
]


class TestMaterialSettingBlock(testing.PyMOLTestCase):
    def testIndicesAreExactlyTheDeclaredBlock(self):
        for name, index in BLOCK:
            self.assertEqual(setting._get_index(name), index, name)

    def testNoIndexCollisionAnywhereInTheTable(self):
        """A duplicate index silently truncates the generated settings table."""
        indices = [setting._get_index(n) for n in setting.name_list]
        self.assertEqual(len(set(indices)), len(indices))
        for name, index in BLOCK:
            self.assertEqual(setting.name_list.count(name), 1, name)
            self.assertEqual(setting.name_dict[index], name)

    def testExistingMetalIndicesDidNotMove(self):
        """.pse files store indices; moving one silently reinterprets old files."""
        for name, index in [('cartoon_spline', 831), ('metal_rt_scale', 832),
                            ('metal_rt_reflect', 833),
                            ('metal_rt_reflect_samples', 837)]:
            self.assertEqual(setting._get_index(name), index, name)

    def testLevels(self):
        from pymol import _cmd
        def level(name):
            return _cmd.get_setting_level(setting._get_index(name))
        for name in REP_MATERIALS + ['transparency_peel']:
            self.assertEqual(level(name), 'object', name)
        for name in ['material_default', 'material_env']:
            self.assertEqual(level(name), 'global', name)

    def testDefaultsAreTheDefaultMaterial(self):
        for name in REP_MATERIALS + ['material_default']:
            self.assertEqual(cmd.get_setting_int(name), 0, name)
            self.assertEqual(cmd.get(name), 'default', name)
        self.assertEqual(cmd.get_setting_int('material_env'), 0)
        self.assertEqual(cmd.get_setting_int('transparency_peel'), -1)


class TestMaterialNames(testing.PyMOLTestCase):
    def testEveryIdReadsBackAsItsName(self):
        for want_id, want_name in enumerate(MATERIAL_NAMES):
            cmd.set('cartoon_material', want_id)
            self.assertEqual(cmd.get('cartoon_material'), want_name)
            self.assertEqual(cmd.get_setting_int('cartoon_material'), want_id)

    def testNamesApplyToEverySettingThatHoldsAMaterialId(self):
        for name in REP_MATERIALS + ['material_default']:
            cmd.set(name, 7)
            self.assertEqual(cmd.get(name), 'marble', name)

    def testAnIdWithNoRowKeepsItsNumber(self):
        """A name never falls back to `default` — that would make `get` lie and
        break the round trip. Out-of-range ids resolve to `default` at DRAW
        time, but they read back as the number they are."""
        cmd.set('cartoon_material', 99)
        self.assertEqual(cmd.get('cartoon_material'), '99')
        cmd.set('cartoon_material', -3)
        self.assertEqual(cmd.get('cartoon_material'), '-3')

    def testNonMaterialIntSettingsStillReadAsNumbers(self):
        cmd.set('material_env', 2)
        self.assertEqual(cmd.get('material_env'), '2')
        cmd.set('transparency_peel', 1)
        self.assertEqual(cmd.get('transparency_peel'), '1')

    def testPerObjectValueReadsBackPerObject(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        cmd.set('cartoon_material', 8)            # global: clay
        cmd.set('cartoon_material', 3, 'm1')      # m1: metallic
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'metallic')
        self.assertEqual(cmd.get('cartoon_material', 'm2'), 'clay')

    def testPSERoundTripKeepsTheId(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.set('surface_material', 5, 'm1')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            cmd.load(fn)
        self.assertEqual(cmd.get_setting_int('surface_material', 'm1'), 5)
        self.assertEqual(cmd.get('surface_material', 'm1'), 'frosted_glass')


class TestSelectionScopedSetIsRejected(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.select('half', 'm1 and name N+CA')

    def testSelectionExpressionIsRefused(self):
        for name in REP_MATERIALS:
            with self.assertRaises(pymol.CmdException, msg=name):
                cmd.set(name, 1, 'name CA')

    def testNamedSelectionIsRefused(self):
        for name in REP_MATERIALS:
            with self.assertRaises(pymol.CmdException, msg=name):
                cmd.set(name, 1, 'half')

    def testRefusalWritesNothing(self):
        try:
            cmd.set('cartoon_material', 4, 'half')
        except pymol.CmdException:
            pass
        self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'), 0)
        self.assertEqual(cmd.get_setting_int('cartoon_material'), 0)

    def testObjectNameStillWorks(self):
        cmd.set('cartoon_material', 2, 'm1')
        self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'), 2)

    def testAllStillWorks(self):
        cmd.fragment('gly', 'm2')
        cmd.set('stick_material', 9, 'all')
        for o in ('m1', 'm2'):
            self.assertEqual(cmd.get_setting_int('stick_material', o), 9, o)

    def testWildcardStillWorks(self):
        cmd.fragment('gly', 'm2')
        cmd.set('sphere_material', 3, 'm*')
        for o in ('m1', 'm2'):
            self.assertEqual(cmd.get_setting_int('sphere_material', o), 3, o)

    def testGroupStillWorks(self):
        cmd.fragment('gly', 'm2')
        cmd.group('grp', 'm1 m2')
        cmd.set('surface_material', 7, 'grp')
        for o in ('m1', 'm2'):
            self.assertEqual(cmd.get_setting_int('surface_material', o), 7, o)

    def testNonMaterialSettingsKeepTheirAtomScope(self):
        """The refusal is per-setting, not a blanket change to selection sets."""
        cmd.set('sphere_scale', 0.5, 'half')
        cmd.iterate_state(1, 'm1 and name CA', 'assert s.sphere_scale == 0.5')

    def testGlobalMaterialSettingsAreNotAffected(self):
        cmd.set('material_default', 6)
        self.assertEqual(cmd.get_setting_int('material_default'), 6)
