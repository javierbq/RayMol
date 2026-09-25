"""The glass family (#495): `glass` and `frosted_glass`.

Two things make glass different from every material before it.

It is the first family that implies its own TRANSPARENCY. That value is a
rep-BUILD input, consulted beside the rep's own transparency setting and never
written back as a setting -- so a .pse opened in a build that does not know
`glass` renders an opaque surface, visible and wrong, rather than an invisible
one. The user's slider always wins.

It is also the first family that sets `wantsPeel`, which means #488's
`transparency_peel` auto mode finally has a consumer: until now auto resolved
to off for every material in the table.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_glass.py
"""
import pymol
from pymol import _cmd, cmd, setting, testing
from pymol.constants import repres

GLASS_FAMILY = 3


def family(name):
    by_name = {n: i for i, n in setting.get_material_names(0)}
    return _cmd.get_material_family(by_name[name])


def effective_transparency(obj, rep):
    """What the rep would BUILD with -- its own transparency setting, or the
    material's implied opacity converted to a transparency when that setting is
    0. The rendered quantity, as opposed to what the SETTING says."""
    return _cmd.get_effective_transparency(cmd._COb, obj, rep)


def resolved_peel(obj):
    return _cmd.get_object_peel(cmd._COb, obj)


class TestGlass(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    # -- the table ------------------------------------------------------------

    def testBothAreImplementedAndOffered(self):
        names = [n for _i, n in setting.get_material_names(1)]
        self.assertIn('glass', names)
        self.assertIn('frosted_glass', names)

    def testBothAreInTheGlassFamily(self):
        self.assertEqual(family('glass'), GLASS_FAMILY)
        self.assertEqual(family('frosted_glass'), GLASS_FAMILY)

    def testJellyIsNotImplementedYet(self):
        """Jelly is #496. Guard, so flipping it there is a deliberate act and
        this file's claims stay true until then."""
        self.assertNotIn('jelly', [n for _i, n in setting.get_material_names(1)])

    # -- implied alpha --------------------------------------------------------

    def testGlassImpliesTransparencyWithoutWritingASetting(self):
        """The whole contract: the rep BUILDS transparent, but `transparency`
        itself is untouched -- so an older build renders it OPAQUE (visible and
        wrong) rather than invisible.

        Both halves have to be asserted. Checking only that the setting stayed 0
        is true just as much when the feature is dead, which is exactly how the
        alpha/transparency inversion below survived into a render."""
        cmd.show('surface', 'm1')
        cmd.set('surface_material', 'glass', 'm1')
        # the setting is untouched ...
        self.assertEqual(cmd.get_setting_float('transparency', 'm1'), 0.0)
        # ... and the rep still builds see-through. The table stores ALPHA
        # (0.15 = mostly clear); layer2 wants a TRANSPARENCY, so this must be
        # 0.85. Returning 0.15 here shades like glass but is 85% OPAQUE.
        self.assertAlmostEqual(
            effective_transparency('m1', repres['surface']), 0.85, places=4)

    def testFrostedGlassImpliesItsOwnOpacity(self):
        """Each glass row carries its own alpha; frosted is the denser of the
        two, so the two materials must not collapse to one value."""
        cmd.show('surface', 'm1')
        cmd.set('surface_material', 'frosted_glass', 'm1')
        self.assertAlmostEqual(
            effective_transparency('m1', repres['surface']), 0.80, places=4)

    def testANonGlassMaterialImpliesNoOpacity(self):
        """Only the glass family implies anything; a procedural material leaves
        an opaque rep opaque."""
        cmd.show('surface', 'm1')
        cmd.set('surface_material', 'marble', 'm1')
        self.assertAlmostEqual(
            effective_transparency('m1', repres['surface']), 0.0, places=4)

    def testTheUsersSliderWins(self):
        """A non-zero transparency is returned untouched, so turning glass down
        to nearly opaque stays possible -- 0.3, not the material's 0.85."""
        cmd.set('transparency', 0.3, 'm1')
        cmd.set('surface_material', 'glass', 'm1')
        self.assertAlmostEqual(cmd.get_setting_float('transparency', 'm1'), 0.3,
                               places=4)
        self.assertAlmostEqual(
            effective_transparency('m1', repres['surface']), 0.3, places=4)

    def testSettingGlassWritesNothingElseAtAll(self):
        before = {n: cmd.get(n) for n in setting.get_name_list()}
        cmd.set('surface_material', 'glass', 'm1')
        after = {n: cmd.get(n) for n in setting.get_name_list()}
        self.assertEqual({n for n in after if before.get(n) != after[n]}, set())

    def testGlassDoesNotTouchColour(self):
        cmd.color('red', 'm1')
        before = []
        cmd.iterate('m1', 'before.append(color)', space={'before': before})
        cmd.set('surface_material', 'glass', 'm1')
        after = []
        cmd.iterate('m1', 'after.append(color)', space={'after': after})
        self.assertEqual(before, after)

    # -- peel auto, which glass is the first material to trigger --------------

    def testGlassTurnsPeelAutoOn(self):
        """#488 shipped `transparency_peel` -1 (auto) with NO material that
        asked for it. Glass is the first, so this is auto's first real test."""
        self.assertEqual(resolved_peel('m1'), 0)
        cmd.set('surface_material', 'glass', 'm1')
        self.assertEqual(resolved_peel('m1'), 1)

    def testAnExplicitPeelOffStillBeatsGlass(self):
        cmd.set('surface_material', 'glass', 'm1')
        cmd.set('transparency_peel', 0, 'm1')
        self.assertEqual(resolved_peel('m1'), 0)

    def testANonGlassMaterialLeavesAutoOff(self):
        for name in ('matte', 'marble', 'clay', 'rubber', 'plastic', 'metallic'):
            cmd.set('surface_material', name, 'm1')
            self.assertEqual(resolved_peel('m1'), 0, name)

    # -- the representations glass cannot draw on -----------------------------

    def testGlassOnSpheresDrawsAsDefault(self):
        """Sphere impostors have no glass path; they would float as
        near-invisible discs, so MaterialResolve degrades them.

        Asserted on the EFFECTIVE id -- what reaches the shader -- not on the
        setting. My first version of this compared `get_rep_material` values,
        which answer what the SETTING says; both were `glass`, so it could only
        ever have failed. The degradation was not observable from Python at all
        until `get_effective_material` was added for exactly this."""
        by_name = {n: i for i, n in setting.get_material_names(0)}
        glass = by_name['glass']
        self.assertEqual(_cmd.get_effective_material(glass, repres['spheres']), 0)
        # ...and it is NOT degraded where glass does have a path.
        self.assertEqual(_cmd.get_effective_material(glass, repres['surface']),
                         glass)
        self.assertEqual(_cmd.get_effective_material(glass, repres['cartoon']),
                         glass)

    def testStickBallGlassImpliesNoOpacityEither(self):
        """A `stick_ball` stick degrades to `default` because the ball spheres
        have no glass path -- and the implied alpha has to degrade WITH it.

        Shading and alpha resolved separately at first, so ball-and-stick shaded
        as `default` while still building 85% transparent: a see-through
        `default`, which is not "renders default". The render probe caught it;
        this pins it."""
        cmd.set('stick_ball', 1, 'm1')
        cmd.set('stick_material', 'glass', 'm1')
        self.assertAlmostEqual(
            effective_transparency('m1', repres['sticks']), 0.0, places=4)
        # ...and with stick_ball off the same material does imply its opacity,
        # so this is a degradation and not glass being inert on sticks.
        cmd.set('stick_ball', 0, 'm1')
        self.assertAlmostEqual(
            effective_transparency('m1', repres['sticks']), 0.85, places=4)

    def testGlassIsStillSettableOnSpheresAndRoundTrips(self):
        """Degrading at DRAW time is not the same as refusing the value: the
        setting still holds what the user typed, so turning stick_ball off (or
        opening the .pse in a build that grows a glass sphere path) restores the
        intent."""
        cmd.set('sphere_material', 'glass', 'm1')
        self.assertEqual(cmd.get('sphere_material', 'm1'), 'glass')

    def testAnUnknownGlassLikeNameIsStillAnError(self):
        with self.assertRaises(pymol.CmdException):
            cmd.set('surface_material', 'plexiglass', 'm1')
