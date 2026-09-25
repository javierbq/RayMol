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


def built_transparency(obj, rep):
    """What the rep's GEOMETRY was actually built with, read off the rep.

    Deliberately NOT a re-derivation from the settings: implied alpha is a build
    input that is never written back, so re-deriving it only proves the
    derivation agrees with itself. Two dead call sites passed CI that way -- the
    conversion sat downstream of where the per-vertex alpha is written, so glass
    cartoons and multi-coloured glass surfaces still built fully opaque."""
    return _cmd.get_built_transparency(cmd._COb, obj, rep)


def build(obj, rep_name):
    """Show a representation and force its geometry to be BUILT.

    builtTransparency is recorded during the rep build, so a test that only
    calls cmd.show() would be asking an unbuilt rep -- which now raises rather
    than reporting 0.0, so this cannot silently pass."""
    cmd.show(rep_name, obj)
    cmd.rebuild(obj)
    cmd.refresh()


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
        cmd.set('surface_material', 'glass', 'm1')
        build('m1', 'surface')
        # the setting is untouched ...
        self.assertEqual(cmd.get_setting_float('transparency', 'm1'), 0.0)
        # ... and the rep still builds see-through. The table stores ALPHA
        # (0.15 = mostly clear); layer2 wants a TRANSPARENCY, so this must be
        # 0.85. Returning 0.15 here shades like glass but is 85% OPAQUE.
        self.assertAlmostEqual(
            built_transparency('m1', repres['surface']), 0.85, places=4)

    def testFrostedGlassImpliesItsOwnOpacity(self):
        """Each glass row carries its own alpha; frosted is the denser of the
        two, so the two materials must not collapse to one value."""
        cmd.set('surface_material', 'frosted_glass', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(
            built_transparency('m1', repres['surface']), 0.80, places=4)

    def testANonGlassMaterialImpliesNoOpacity(self):
        """Only the glass family implies anything; a procedural material leaves
        an opaque rep opaque."""
        cmd.set('surface_material', 'marble', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(
            built_transparency('m1', repres['surface']), 0.0, places=4)

    def testTheUsersSliderWins(self):
        """A non-zero transparency is returned untouched, so turning glass down
        to nearly opaque stays possible -- 0.3, not the material's 0.85."""
        cmd.set('transparency', 0.3, 'm1')
        cmd.set('surface_material', 'glass', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(cmd.get_setting_float('transparency', 'm1'), 0.3,
                               places=4)
        self.assertAlmostEqual(
            built_transparency('m1', repres['surface']), 0.3, places=4)

    def testFrostedGlassKeepsItsRoughness(self):
        """`rough` is the FROST axis for glass: the cubemap mip is
        sqrt(rough)*7 and it sets the tap spread.

        The legacy object-scoped metal_rt_reflect* triple used to overwrite it
        for every non-reflective family, so frosted_glass's 0.6 became
        metal_rt_reflect_rough's default 0 -- a near-mirror sample. It rendered
        as clear `glass`, and the only surviving difference between the two
        materials was their implied alpha, which is exactly what the render
        probe measured. Nothing could see it."""
        cmd.set('surface_material', 'frosted_glass', 'm1')
        _fam, _mode, _refl, _tint, rough = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        self.assertAlmostEqual(rough, 0.6, places=4)

    def testALegacyReflectSliderCannotReshapeGlass(self):
        """A material is a pure function of its id. The legacy sliders must not
        reach into one -- turning metal_rt_reflect_rough up used to make clear
        glass frosted."""
        cmd.set('surface_material', 'glass', 'm1')
        cmd.set('metal_rt_reflect_rough', 1.0, 'm1')
        _fam, _mode, _refl, _tint, rough = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        self.assertAlmostEqual(rough, 0.0, places=4)

    def testAReflectiveMaterialKeepsItsExplicitOverride(self):
        """#497: a reflective material starts from its TABLE row, but an
        EXPLICIT per-object metal_rt_reflect* value still wins.

        Pinned here because moving the legacy-triple rule out of CGOGL into
        MaterialDrawParams dropped this branch, and the rebase onto #497 is the
        only thing that caught it -- no test covered it."""
        by_name = {n: i for i, n in setting.get_material_names(0)}
        cmd.set('surface_material', 'metallic', 'm1')
        _f, _m, refl, tint, rough = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        # untouched: the table row, NOT the sliders' default of 0
        self.assertAlmostEqual(refl, 0.6, places=4)
        self.assertAlmostEqual(tint, 0.35, places=4)
        self.assertAlmostEqual(rough, 0.35, places=4)
        # explicit values win, and only the ones actually set
        cmd.set('metal_rt_reflect', 0.9, 'm1')
        cmd.set('metal_rt_reflect_rough', 0.05, 'm1')
        _f, _m, refl, tint, rough = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        self.assertAlmostEqual(refl, 0.9, places=4)
        self.assertAlmostEqual(tint, 0.35, places=4)   # untouched, table wins
        self.assertAlmostEqual(rough, 0.05, places=4)

    def testDefaultStillReadsTheLegacySliders(self):
        """The exemption is narrow: `default` keeps reading the legacy triple,
        which is what makes this PR byte-identical for it."""
        cmd.set('metal_rt_reflect_rough', 0.42, 'm1')
        _fam, _mode, _refl, _tint, rough = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        self.assertAlmostEqual(rough, 0.42, places=4)

    def testGlassCartoonBuildsTransparent(self):
        """The cartoon's per-vertex alpha is baked in RepCartoonNew, not in
        RepCartoonCGOGenerate. Converting only in the latter left a glass
        cartoon fully OPAQUE while still being routed through the transparent
        pass -- paying the cost of transparency and showing none of it."""
        # A real peptide, not the `ala` fragment: a single residue has no
        # cartoon geometry, so the rep would not be built and the assertion
        # would be resting on an exception rather than on a value.
        cmd.fab('AAAAAAAAAA', 'm2', ss=1)
        cmd.set('cartoon_material', 'glass', 'm2')
        build('m2', 'cartoon')
        self.assertAlmostEqual(
            built_transparency('m2', repres['cartoon']), 0.85, places=4)
        # and the same cartoon with no material stays opaque
        cmd.set('cartoon_material', 'default', 'm2')
        build('m2', 'cartoon')
        self.assertAlmostEqual(
            built_transparency('m2', repres['cartoon']), 0.0, places=4)

    def testGlassSurfaceIsTransparentWhateverTheColouring(self):
        """A surface's per-vertex VA array is built in recolor() from the raw
        setting, and every triangle branch except the single-colour one prefers
        VA over the scalar alpha. So a MULTI-COLOURED glass surface built opaque
        while a uniformly coloured one was translucent: same material, same
        settings, transparency depending on the colouring."""
        for colouring in ('uniform', 'multi'):
            with self.subTest(colouring=colouring):
                cmd.reinitialize()
                cmd.fragment('ala', 'm1')
                if colouring == 'uniform':
                    cmd.color('grey80', 'm1')
                else:
                    cmd.util.cbaw('m1')
                cmd.set('surface_material', 'glass', 'm1')
                build('m1', 'surface')
                self.assertAlmostEqual(
                    built_transparency('m1', repres['surface']), 0.85, places=4)

    def testAnUnbuiltRepIsAnErrorNotZero(self):
        """Guard on the accessor itself: reporting 0.0 for a rep that was never
        built would let every assertion above pass against geometry that does
        not exist."""
        cmd.set('surface_material', 'glass', 'm1')
        with self.assertRaises(Exception):
            built_transparency('m1', repres['surface'])

    def testSettingGlassWritesNothingElseAtAll(self):
        """The non-negotiable: a material writes no OTHER setting.

        Must read the values on the OBJECT the material was set on. Reading
        cmd.get(n) with no object reads the GLOBAL, so the old version asserted
        only that an object-level `set` leaves globals alone -- true of every
        setting in PyMOL, and still true if glass wrote `transparency` or
        `transparency_peel` on m1, which is precisely what it guards."""
        names = setting.get_name_list()
        before_obj = {n: cmd.get(n, 'm1') for n in names}
        before_global = {n: cmd.get(n) for n in names}
        cmd.set('surface_material', 'glass', 'm1')
        after_obj = {n: cmd.get(n, 'm1') for n in names}
        after_global = {n: cmd.get(n) for n in names}
        changed_obj = {n for n in names if before_obj[n] != after_obj[n]}
        changed_global = {n for n in names if before_global[n] != after_global[n]}
        self.assertEqual(changed_obj, {'surface_material'})
        self.assertEqual(changed_global, set())

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
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 0)
        cmd.set('surface_material', 'glass', 'm1')
        self.assertEqual(resolved_peel('m1'), 1)

    def testAutoPeelRefusesWhenAnotherRepIsAlreadyTransparent(self):
        """Peeling is OBJECT-scoped: the pre-pass records the nearest
        transparent depth across all of the object's transparent reps, and
        anything behind it fails the equality test.

        So auto must NOT turn on when the object also has a transparent rep that
        did not ask for it -- otherwise setting a glass surface makes an
        already-translucent cartoon on the same object vanish, a look the user
        had before and never asked to change."""
        cmd.set('cartoon_transparency', 0.5, 'm1')
        cmd.set('surface_material', 'glass', 'm1')
        # build(), not show(): hasRep consults Obj->RepVisCache, which is only
        # recomputed on a refresh, so a bare show() leaves the rep invisible to
        # the veto.
        build('m1', 'cartoon')
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 0)

    def testAGlobalTransparencyDoesNotDisableAutoPeel(self):
        """The veto must only consider reps the object actually DRAWS.

        SettingGet_f falls back to the GLOBAL value, so reading it blindly made
        a global `set transparency, 0.5` -- one of the most common things a user
        types -- turn auto-peel off for every glass cartoon in the session, on
        account of a surface nothing was showing."""
        cmd.set('transparency', 0.5)          # global, and no surface is shown
        cmd.fab('AAAAAAAAAA', 'm2', ss=1)
        cmd.hide('everything', 'm2')
        cmd.set('cartoon_material', 'glass', 'm2')
        build('m2', 'cartoon')
        self.assertEqual(resolved_peel('m2'), 1)

    def testAnAtomLevelTransparencyStillVetoesAutoPeel(self):
        """The four transparency settings are atom- and bond-level and are
        routinely written through a SELECTION, which leaves the object value at
        0. Reading only the object value missed those entirely -- the same
        vanishing rep, just a narrower trigger. Rep::hasTransparency() is what
        the renderer routes on, so it sees per-atom overrides by construction."""
        cmd.fab('AAAAAAAAAA', 'm2', ss=1)
        cmd.hide('everything', 'm2')
        cmd.set('cartoon_transparency', 0.5, 'm2 and all')   # atom level
        self.assertEqual(
            cmd.get_setting_float('cartoon_transparency', 'm2'), 0.0)
        cmd.set('surface_material', 'glass', 'm2')
        build('m2', 'cartoon')
        build('m2', 'surface')
        self.assertEqual(resolved_peel('m2'), 0)

    def testAnExplicitPeelOnStillPeelsTheWholeObject(self):
        """The refusal above is a property of AUTO only. An explicit request is
        the user asking for object-wide peeling, and still gets it."""
        cmd.set('cartoon_transparency', 0.5, 'm1')
        cmd.set('surface_material', 'glass', 'm1')
        cmd.set('transparency_peel', 1, 'm1')
        build('m1', 'cartoon')
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 1)

    def testAnOpaqueSecondRepDoesNotBlockAutoPeel(self):
        """The refusal is narrow: an untouched rep is opaque and the peel cannot
        affect it either way, so the common case still gets auto-peel."""
        cmd.set('surface_material', 'glass', 'm1')
        build('m1', 'cartoon')
        build('m1', 'surface')
        self.assertEqual(cmd.get_setting_float('cartoon_transparency', 'm1'), 0.0)
        self.assertEqual(resolved_peel('m1'), 1)

    def testBallAndStickGlassDoesNotTurnPeelOn(self):
        """A glass stick on a stick_ball object degrades to `default` and builds
        fully opaque, so it has no transparent fragments to peel.

        Turning peel on for it costs a depth blit and two encoder boundaries per
        grid cell for nothing -- and with only three peel slots it can evict a
        genuinely glass object from the set, which is visible, not just waste.
        The cheap gate that decides whether to look at all reads the material
        row BEFORE the degradations, so the answer has to come from the second
        pass; returning the gate's own verdict got this wrong."""
        cmd.set('stick_ball', 1, 'm1')
        cmd.set('stick_material', 'glass', 'm1')
        build('m1', 'sticks')
        self.assertAlmostEqual(
            built_transparency('m1', repres['sticks']), 0.0, places=4)
        self.assertEqual(resolved_peel('m1'), 0)

    def testAGlassMaterialOnAnUNSHOWNRepDoesNotTurnPeelOn(self):
        """Peel must be asked for by geometry that EXISTS.

        Glass is the first material to set wantsPeel, so this branch was
        unreachable before this ticket: a glass material on a rep the object
        does not draw turned peeling on for nothing -- and with three slots,
        that can evict an object that really is glass."""
        cmd.set('surface_material', 'glass', 'm1')   # but only a cartoon shown
        build('m1', 'cartoon')
        self.assertEqual(resolved_peel('m1'), 0)
        # ...and it turns on as soon as the surface is actually drawn.
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 1)

    def testGlassSticksWithoutBallsDoTurnPeelOn(self):
        """The mirror, so the test above cannot pass by peel simply never
        turning on for sticks."""
        cmd.set('stick_material', 'glass', 'm1')
        build('m1', 'sticks')
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
        build('m1', 'sticks')
        self.assertAlmostEqual(
            built_transparency('m1', repres['sticks']), 0.0, places=4)
        # ...and with stick_ball off the same material does imply its opacity,
        # so this is a degradation and not glass being inert on sticks.
        cmd.set('stick_ball', 0, 'm1')
        build('m1', 'sticks')
        self.assertAlmostEqual(
            built_transparency('m1', repres['sticks']), 0.85, places=4)

    def testAtomLevelStickBallDegradesGlassToo(self):
        """`stick_ball` is an ATOM-level setting and RepCylBond reads it per
        atom, so asking only the object value answers the wrong question.

        An atom-level `stick_ball 1` under an object-level 0 left the rep glass:
        the ball sphere then drew through the glass impostor path at alpha 0.15
        -- the near-invisible disc the rule exists to prevent, and reachable now
        that the glass-family sphere pipelines are built."""
        cmd.set('stick_ball', 1, 'index 1')
        cmd.set('stick_material', 'glass', 'm1')
        build('m1', 'sticks')
        self.assertEqual(cmd.get_setting_boolean('stick_ball', 'm1'), 0)
        self.assertAlmostEqual(
            built_transparency('m1', repres['sticks']), 0.0, places=4)

    def testEveryAtomOptingOutDoesNotDegrade(self):
        """The mirror case: an object-level `stick_ball 1` that every visible
        atom overrides back to 0 emits no balls at all, so glass should still
        apply rather than silently doing nothing."""
        cmd.set('stick_ball', 1, 'm1')          # object level
        # ...overridden per ATOM. `cmd.set(..., 'm1')` is an OBJECT name and
        # would just overwrite the object value, which is what made the first
        # version of this test vacuous: it could not fail if the per-atom scan
        # were reverted. A selection routes to the atom-level branch.
        cmd.set('stick_ball', 0, 'm1 and all')
        self.assertEqual(cmd.get_setting_boolean('stick_ball', 'm1'), 1)
        cmd.set('stick_material', 'glass', 'm1')
        build('m1', 'sticks')
        self.assertAlmostEqual(
            built_transparency('m1', repres['sticks']), 0.85, places=4)

    def testGlassSurvivesAPseRoundTrip(self):
        """The stated reason implied alpha is never written back as a setting is
        session survival, and nothing tested it. A .pse must carry the material
        ID and leave `transparency` at 0 -- an older build then renders an
        opaque surface, visible and wrong, rather than an invisible one."""
        cmd.set('surface_material', 'glass', 'm1')
        with testing.mktemp('.pse') as path:
            cmd.save(path)
            cmd.reinitialize()
            cmd.load(path)
            self.assertEqual(cmd.get('surface_material', 'm1'), 'glass')
            self.assertEqual(cmd.get_setting_float('transparency', 'm1'), 0.0)
            build('m1', 'surface')
            self.assertAlmostEqual(
                built_transparency('m1', repres['surface']), 0.85, places=4)

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
