"""The material table and the name <-> id mapping (#486).

The table lives in C (`layer1/Material.cpp`). The settings store IDS so they
round-trip through `.pse` and through builds that predate a given material; the
user types NAMES. Two rules the rest of the epic leans on:

  * an unknown NAME is an error at set time, never a fallback at draw time;
  * `get_material_names()` offers only the materials that can actually draw, so
    the Inspector dropdown grows wave by wave instead of listing looks that
    would silently render as `default`. A material whose shader has not landed
    is still a real id that can be set and saved.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_table.py
"""
from pymol import cmd, testing
from pymol import _cmd

import pymol

# The v1 table, in id order. Ids are append-only: they are written into .pse
# files, so a row may never be renumbered.
TABLE = [
    (0, 'default'),
    (1, 'matte'),
    (2, 'plastic'),
    (3, 'metallic'),
    (4, 'glass'),
    (5, 'frosted_glass'),
    (6, 'jelly'),
    (7, 'marble'),
    (8, 'clay'),
    (9, 'rubber'),
]

MATERIAL_SETTINGS = ['cartoon_material', 'surface_material', 'stick_material',
                     'sphere_material', 'material_default']

# The materials this build can actually draw, in id order. Each wave of the epic
# flips one or more `implemented` flags in layer1/Material.cpp and must update
# this list in the same change -- that is the point of asserting it exactly.
IMPLEMENTED_TODAY = ['default']


class TestMaterialTable(testing.PyMOLTestCase):
    def testTheWholeTableIsExactlyTheV1List(self):
        self.assertEqual([tuple(x) for x in _cmd.get_material_names(0)], TABLE)

    def testIdsAreDenseAndInOrder(self):
        full = _cmd.get_material_names(0)
        self.assertEqual([i for i, _ in full], list(range(len(full))))

    def testNamesApiOffersExactlyTheImplementedRows(self):
        self.assertEqual([n for _, n in _cmd.get_material_names(1)],
                         IMPLEMENTED_TODAY)
        # `default` can always draw, and is first so a dropdown leads with it.
        self.assertEqual(tuple(_cmd.get_material_names(1)[0]), (0, 'default'))

    def testTheFlagActuallyFilters(self):
        """Without this, a no-op `only_implemented` would leave every other
        assertion in this file green while the dropdown offered looks that
        cannot draw -- which is the whole reason the flag exists."""
        full = _cmd.get_material_names(0)
        implemented = _cmd.get_material_names(1)
        self.assertTrue(set(map(tuple, implemented)) <= set(map(tuple, full)))
        if len(implemented) == len(full):
            self.skipTest('every material is implemented')
        self.assertLess(len(implemented), len(full))
        self.assertTrue(set(map(tuple, full)) - set(map(tuple, implemented)))

    def testAnExcludedRowIsStillASettableId(self):
        """Hidden from the dropdown, but a real material: a .pse written by a
        build where it IS implemented still has to open here."""
        implemented = set(i for i, _ in _cmd.get_material_names(1))
        excluded = sorted((i, n) for i, n in _cmd.get_material_names(0)
                          if i not in implemented)
        if not excluded:
            self.skipTest('every material is implemented')
        want_id, name = excluded[0]
        cmd.set('surface_material', name)
        self.assertEqual(cmd.get_setting_int('surface_material'), want_id)
        self.assertEqual(cmd.get('surface_material'), name)

    def testTheDefaultOfTheApiIsImplementedOnly(self):
        self.assertEqual(_cmd.get_material_names(), _cmd.get_material_names(1))

    def testCmdWrapperMatches(self):
        self.assertEqual(cmd.get_material_names(), _cmd.get_material_names(1))
        self.assertEqual(cmd.get_material_names(0), _cmd.get_material_names(0))

    def testEveryNameRoundTripsThroughTheSetting(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        for want_id, name in TABLE:
            cmd.set('cartoon_material', name, 'm1')
            self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'),
                             want_id, name)
            self.assertEqual(cmd.get('cartoon_material', 'm1'), name)

    def testANameWorksOnEverySettingThatHoldsAMaterialId(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        for setting in MATERIAL_SETTINGS:
            cmd.set(setting, 'marble')
            self.assertEqual(cmd.get_setting_int(setting), 7, setting)

    def testAnUnimplementedMaterialIsStillSettable(self):
        """It is a real id that renders as `default` until its shader lands --
        not an error, or a .pse from a newer build could not be opened."""
        implemented = set(i for i, _ in _cmd.get_material_names(1))
        unimplemented = [(i, n) for i, n in TABLE if i not in implemented]
        if not unimplemented:
            self.skipTest('every material is implemented')
        want_id, name = unimplemented[0]
        cmd.set('surface_material', name)
        self.assertEqual(cmd.get_setting_int('surface_material'), want_id)

    def testNumbersStillWork(self):
        cmd.set('cartoon_material', 7)
        self.assertEqual(cmd.get_setting_int('cartoon_material'), 7)
        cmd.set('cartoon_material', '8')
        self.assertEqual(cmd.get_setting_int('cartoon_material'), 8)

    def testAnIdWithNoRowIsAccepted(self):
        """Ids are not clamped: a .pse written by a newer build must open, and
        the renderer resolves the unknown id to `default`."""
        cmd.set('cartoon_material', 99)
        self.assertEqual(cmd.get_setting_int('cartoon_material'), 99)


class TestMaterialDefaultReach(testing.PyMOLTestCase):
    """Which representations `material_default` reaches is duplicated by hand:
    once in `MaterialSettingForRep` and once in the invalidation list in
    `SettingGenerateSideEffects`. Nothing else pins them together, so a later
    wave that gives a new rep a material and forgets the invalidation would ship
    reps whose geometry stays baked for the material they had before."""

    # cRep_t indices that own a material setting: sticks, spheres, surface,
    # cartoon (layer1/Rep.h). Everything else keeps default shading in v1.
    REPS_WITH_A_MATERIAL = {0, 1, 2, 5}

    def testExactlyTheseRepsResolveMaterialDefault(self):
        from pymol.constants import repres
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.set('material_default', 7)          # marble
        reached = set()
        for rep in range(max(repres.values()) + 1):
            # state -1 forces the object level, so only the resolution rule is
            # under test here and not the state chain.
            if _cmd.get_rep_material(cmd._COb, 'm1', rep, -1) != 0:
                reached.add(rep)
        self.assertEqual(reached, self.REPS_WITH_A_MATERIAL)


class TestNamesReadBack(testing.PyMOLTestCase):
    """`get` renders a material id as its NAME, and `set` accepts that same
    name back -- the two halves of the mapping land together, so the Settings
    panel and `.pml` logs round-trip."""

    def testGetReturnsTheName(self):
        for want_id, name in TABLE:
            cmd.set('surface_material', want_id)
            self.assertEqual(cmd.get('surface_material'), name)

    def testWhatGetReturnsIsWhatSetAccepts(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.set('cartoon_material', 'marble', 'm1')
        value = cmd.get('cartoon_material', 'm1')
        cmd.set('cartoon_material', value, 'm1')      # the Settings panel path
        self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'), 7)

    def testTheSettingHelpTextExampleActuallyWorks(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'myobj')
        cmd.set('cartoon_material', 'marble', 'myobj')
        self.assertEqual(cmd.get('cartoon_material', 'myobj'), 'marble')

    def testAnIdWithNoRowKeepsItsNumber(self):
        """A name never falls back to `default` -- that would make `get` report
        a value `set` would then apply differently."""
        cmd.set('cartoon_material', 99)
        self.assertEqual(cmd.get('cartoon_material'), '99')
        cmd.set('cartoon_material', -3)
        self.assertEqual(cmd.get('cartoon_material'), '-3')

    def testNonMaterialIntSettingsStillReadAsNumbers(self):
        cmd.set('material_env', 2)
        self.assertEqual(cmd.get('material_env'), '2')
        cmd.set('transparency_peel', 1)
        self.assertEqual(cmd.get('transparency_peel'), '1')


class TestUnknownNameIsAnError(testing.PyMOLTestCase):
    def testUnknownNameRaises(self):
        for setting in MATERIAL_SETTINGS:
            with self.assertRaises(pymol.CmdException, msg=setting):
                cmd.set(setting, 'unobtanium')

    def testTheMessageListsTheValidNamesAndPointsAtHelp(self):
        try:
            cmd.set('cartoon_material', 'unobtanium')
        except pymol.CmdException as e:
            msg = str(e)
        else:
            self.fail('no error raised')
        self.assertIn('unobtanium', msg)
        self.assertIn('help material', msg)
        for _, name in TABLE:
            self.assertIn(name, msg)

    def testARejectedNameWritesNothing(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.set('cartoon_material', 'marble', 'm1')
        try:
            cmd.set('cartoon_material', 'unobtanium', 'm1')
        except pymol.CmdException:
            pass
        self.assertEqual(cmd.get_setting_int('cartoon_material', 'm1'), 7)

    def testNonMaterialSettingsAreUnaffectedByTheNameMapping(self):
        """The mapping is per-setting: a normal int setting still rejects a
        name the way it always did, through _validate_value."""
        cmd.set('sphere_quality', 2)
        self.assertEqual(cmd.get_setting_int('sphere_quality'), 2)
        with self.assertRaises(Exception):
            cmd.set('sphere_quality', 'marble')

    def testHelpMaterialExists(self):
        cmd.help('material')
