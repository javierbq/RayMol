"""Jelly (#496): the gummy, and the last row of the v1 material table.

Jelly lives in the glass FAMILY -- it shares its pipeline, its peel and its
implied-alpha machinery -- but it is the opposite material. Glass is a clear
body under a Fresnel rim; jelly is a dense scattering body under a smooth wet
skin. Everything asserted here is a place those two could quietly collapse into
each other:

  * its implied alpha is 0.85, where clear glass's is 0.15, so a jelly surface
    is a body you look INTO rather than through. Sharing a value with glass
    would still shade like a gummy and still look wrong. That 0.85 is a
    deliberate departure from the 0.45 #496 and #503 specify, and the reason is
    arithmetic: for a SINGLE layer over a NEUTRAL background, col*a + bg*(1-a)
    has channel spread a*spread(col) <= a, and the prototype gallery's red
    gummy measures 0.539. Both conditions are load-bearing and both hold for
    jelly -- the probe background is grey, and jelly peels, so there is one
    layer. It is not a general law; see the table comment in
    layer1/Material.cpp, which spells out what happens without either.
  * its `rough` is near zero where frosted_glass's is 0.6. `rough` is the
    cubemap MIP axis, so a jelly that picked up a frosted roughness reflects a
    blurred room and stops reading as wet -- the same class of defect as #495's
    frosted_glass losing its roughness to the legacy slider, which rendered as
    a plausible clear glass and was invisible to every test.
  * its three knobs (absorption, scatter, wet highlight) are what separate a
    gummy from a tinted glass, and each of them fails by rendering a DIFFERENT
    plausible material rather than by failing to draw.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_jelly.py
"""
import pymol
from pymol import _cmd, cmd, setting, testing
from pymol.constants import repres

GLASS_FAMILY = 3

# Must equal cMaterial_jelly in layer1/Material.h AND kMatMode_jelly in the
# shared Metal block: `mode` is what the shader switches on inside the glass
# family, so if these three ever disagree a jelly object silently draws as
# clear glass.
JELLY_MODE = 6

# The alpha the table implies, as the TRANSPARENCY layer2 builds with.
JELLY_TRANSPARENCY = 1.0 - 0.85


def family(name):
    by_name = {n: i for i, n in setting.get_material_names(0)}
    return _cmd.get_material_family(by_name[name])


def built_transparency(obj, rep):
    """What the rep's GEOMETRY was built with, read off the rep itself.

    Not re-derived from the settings: implied alpha is a build input that is
    never written back, so a re-derivation only proves it agrees with itself."""
    return _cmd.get_built_transparency(cmd._COb, obj, rep)


def draw_params(obj, rep):
    return _cmd.get_material_draw_params(cmd._COb, obj, rep)


def built_line_stick_helper(obj):
    """What the LINES build decided about line_stick_helper, not what the
    setting says. The two differ exactly when a material is what made the
    sticks translucent, which is the case worth testing."""
    return _cmd.get_built_line_stick_helper(cmd._COb, obj)


def build(obj, rep_name):
    """Show a representation and force its geometry to be BUILT."""
    cmd.show(rep_name, obj)
    cmd.rebuild(obj)
    cmd.refresh()


def resolved_peel(obj):
    return _cmd.get_object_peel(cmd._COb, obj)


class TestJelly(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    # -- the table row --------------------------------------------------------

    def testJellyIsImplementedAndOffered(self):
        self.assertIn('jelly', [n for _i, n in setting.get_material_names(1)])

    def testJellyIsInTheGlassFamily(self):
        """Family is the function-constant axis the Metal pipelines are
        specialised on. Jelly in any other family would need a pipeline that is
        not built, and would draw as `default`.

        Asserted twice on purpose: the table row carries a family AND the
        MaterialParams inside it carry one, and only the second reaches the
        GPU. They are separate fields and nothing but this compares them."""
        self.assertEqual(family('jelly'), GLASS_FAMILY)
        cmd.set('surface_material', 'jelly', 'm1')
        fam, _m, _r, _t, _ro, _p = draw_params('m1', repres['surface'])
        self.assertEqual(fam, GLASS_FAMILY)

    def testJellyHasItsOwnModeWithinTheFamily(self):
        """The three glass-family materials share one pipeline and are told
        apart by `mode` alone, so `mode` has to be the material's own id.

        This pins the C side only. The Metal side -- that kMatMode_jelly in
        RendererMetal.mm carries the same number -- is checked by
        metal_shader_sources.py, which parses the MSL. An earlier draft of this
        docstring claimed the check happened here, and it did not: that file's
        loop was a hardcoded four-name list that had not grown since #487, so
        both frosted_glass and jelly were unverified. It now covers every
        kMatMode_* the shader declares."""
        by_name = {n: i for i, n in setting.get_material_names(0)}
        self.assertEqual(by_name['jelly'], JELLY_MODE)
        for name in ('glass', 'frosted_glass', 'jelly'):
            cmd.set('surface_material', name, 'm1')
            _f, mode, _r, _t, _ro, _p = draw_params('m1', repres['surface'])
            self.assertEqual(mode, by_name[name], name)

    # -- implied alpha --------------------------------------------------------

    def testJellySurfaceBuildsAtItsOwnAlpha(self):
        """0.85 alpha -> 0.15 transparency. The table stores ALPHA and layer2
        wants a TRANSPARENCY; returning the alpha itself would shade like a
        gummy and be 85% see-through instead of 15% -- the inversion that shipped
        clear glass 85% OPAQUE in #495, and which looks deliberate either way."""
        cmd.set('surface_material', 'jelly', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(built_transparency('m1', repres['surface']),
                               JELLY_TRANSPARENCY, places=4)
        # ...and it wrote no transparency setting to get there.
        self.assertEqual(cmd.get_setting_float('transparency', 'm1'), 0.0)

    def testJellyCartoonBuildsTransparent(self):
        """The cartoon's per-vertex alpha is baked in RepCartoonNew, a different
        site from the surface's. A material that only reached one of them looks
        right on whichever representation the reviewer happened to open."""
        cmd.fab('AAAAAAAAAA', 'm2', ss=1)
        cmd.set('cartoon_material', 'jelly', 'm2')
        build('m2', 'cartoon')
        self.assertAlmostEqual(built_transparency('m2', repres['cartoon']),
                               JELLY_TRANSPARENCY, places=4)

    def testJellySticksBuildTransparent(self):
        """Sticks are the third build site, and the one the done-when names
        ("gummy sticks")."""
        cmd.set('stick_material', 'jelly', 'm1')
        build('m1', 'sticks')
        self.assertAlmostEqual(built_transparency('m1', repres['sticks']),
                               JELLY_TRANSPARENCY, places=4)

    def testJellySurfaceIsTransparentWhateverTheColouring(self):
        """A surface's per-vertex VA array is built in recolor(); every triangle
        branch except the single-colour one prefers VA over the scalar alpha, so
        this is where a multi-coloured surface can build opaque while a
        uniformly coloured one does not."""
        for colouring in ('uniform', 'multi'):
            with self.subTest(colouring=colouring):
                cmd.reinitialize()
                cmd.fragment('ala', 'm1')
                if colouring == 'uniform':
                    cmd.color('grey80', 'm1')
                else:
                    cmd.util.cbaw('m1')
                cmd.set('surface_material', 'jelly', 'm1')
                build('m1', 'surface')
                self.assertAlmostEqual(
                    built_transparency('m1', repres['surface']),
                    JELLY_TRANSPARENCY, places=4)

    def testTheThreeGlassFamilyMaterialsKeepDistinctAlphas(self):
        """The failure this rules out is a shared constant: one alpha for the
        whole family renders three materials that differ only in their shading
        and are all equally see-through. Jelly is the one that would suffer --
        a 0.85-transparent gummy is a pale pink tinted glass, which is exactly
        what the ticket's own 0.45 produced."""
        seen = {}
        for name in ('glass', 'frosted_glass', 'jelly'):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            cmd.set('surface_material', name, 'm1')
            build('m1', 'surface')
            seen[name] = round(built_transparency('m1', repres['surface']), 4)
        self.assertEqual(seen, {'glass': 0.85, 'frosted_glass': 0.8,
                                'jelly': 0.15})

    def testTheUsersSliderWins(self):
        cmd.set('transparency', 0.6, 'm1')
        cmd.set('surface_material', 'jelly', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(cmd.get_setting_float('transparency', 'm1'), 0.6,
                               places=4)
        self.assertAlmostEqual(built_transparency('m1', repres['surface']), 0.6,
                               places=4)

    # -- the knobs that make it a gummy --------------------------------------

    def testJellyKeepsItsWetRoughness(self):
        """`rough` is the cubemap MIP axis (lod = sqrt(rough) * 7). Jelly's skin
        is WET: the frost belongs to its body, not to its surface, so it must
        stay near zero where frosted_glass sits at 0.6."""
        cmd.set('surface_material', 'jelly', 'm1')
        _f, _m, _r, _t, rough, _p = draw_params('m1', repres['surface'])
        self.assertAlmostEqual(rough, 0.03, places=4)
        self.assertLess(rough, 0.1)

    def testALegacyReflectSliderCannotReshapeJelly(self):
        """The whole glass family is exempt from the legacy metal_rt_reflect*
        triple (#495). Without the exemption jelly's 0.03 becomes the slider's
        value and the wet skin turns into a blurred one -- a frosted gummy,
        which is a material nobody asked for and which still looks fine."""
        cmd.set('surface_material', 'jelly', 'm1')
        cmd.set('metal_rt_reflect_rough', 0.9, 'm1')
        cmd.set('metal_rt_reflect', 0.8, 'm1')
        _f, _m, refl, _t, rough, _p = draw_params('m1', repres['surface'])
        self.assertAlmostEqual(rough, 0.03, places=4)
        self.assertAlmostEqual(refl, 0.0, places=4)

    def testJellysThreeKnobsReachTheDraw(self):
        """absorption, scatter and wet highlight. Each fails by rendering a
        DIFFERENT plausible material: 0 absorption is a white body, 0 scatter is
        a tinted glass, 0 wet highlight is a matte gum. None of them fails to
        draw, which is why they are asserted rather than eyeballed."""
        cmd.set('surface_material', 'jelly', 'm1')
        _f, _m, _r, _t, _ro, p = draw_params('m1', repres['surface'])
        self.assertAlmostEqual(p[0], 2.2, places=4)    # Beer-Lambert strength
        self.assertAlmostEqual(p[1], 0.35, places=4)   # scattered inner glow
        self.assertAlmostEqual(p[2], 1.1, places=4)    # sharp wet highlight

    def testTheOtherGlassMaterialsCarryNoKnobs(self):
        """The mirror, so the test above cannot pass on a table that hands the
        same knobs to every glass row -- which would put an absorption term on
        clear glass and stop it being clear."""
        for name in ('glass', 'frosted_glass'):
            cmd.set('surface_material', name, 'm1')
            _f, _m, _r, _t, _ro, p = draw_params('m1', repres['surface'])
            self.assertEqual(tuple(p[:3]), (0.0, 0.0, 0.0), name)

    # -- peel -----------------------------------------------------------------

    def testJellyTurnsPeelAutoOn(self):
        """Jelly's row sets wantsPeel, and for jelly the peel does more than
        tidy the look: it is what makes the material ONE layer, which is the
        condition the implied alpha of 0.85 was measured under. Unpeeled, a
        closed surface delivers two layers and covers 1 - 0.15^2 = 0.978."""
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 0)
        cmd.set('surface_material', 'jelly', 'm1')
        self.assertEqual(resolved_peel('m1'), 1)

    def testJellySticksWithoutBallsTurnPeelOn(self):
        cmd.set('stick_material', 'jelly', 'm1')
        build('m1', 'sticks')
        self.assertEqual(resolved_peel('m1'), 1)

    def testBallAndStickJellyDegradesLikeGlass(self):
        """stick_ball spheres arrive as cRepCyl and take stick_material, and the
        sphere impostor is outside the glass family's scope. The whole rep
        degrades -- shading AND implied alpha together, or a `default`-shaded
        stick would still build 15% transparent."""
        cmd.set('stick_ball', 1, 'm1')
        cmd.set('stick_material', 'jelly', 'm1')
        build('m1', 'sticks')
        self.assertAlmostEqual(built_transparency('m1', repres['sticks']), 0.0,
                               places=4)
        self.assertEqual(resolved_peel('m1'), 0)

    def testAutoPeelStillRefusesWhenAnotherRepIsTransparent(self):
        """Peeling is object-scoped, so jelly inherits the refusal: a jelly
        surface must not make an already-translucent cartoon vanish."""
        cmd.set('cartoon_transparency', 0.5, 'm1')
        cmd.set('surface_material', 'jelly', 'm1')
        build('m1', 'cartoon')
        build('m1', 'surface')
        self.assertEqual(resolved_peel('m1'), 0)

    def testJellySticksKeepTheirLines(self):
        """`line_stick_helper` suppresses the lines under a stick, and #495
        turned it off for any stick a MATERIAL makes translucent -- a
        see-through stick with its lines suppressed shows nothing.

        Jelly enters the same branch, and the rule is binary: 0.15 transparency
        trips it exactly as glass's 0.85 does. So `show lines` beside jelly
        sticks draws a wireframe down the middle of every 85%-opaque bond
        (measured at 5.3% of the frame; with `default` the same comparison is
        byte-identical, i.e. fully suppressed). That is the pre-existing rule
        applied to a new value rather than anything this ticket introduced, so
        it is pinned rather than changed -- see #527.

        Asserted on what the BUILD decided, not on the setting. The first
        version of this test checked `built_transparency` and an untouched
        `stick_transparency`, which are the rule's INPUT: revert #495's branch
        in RepWireBond and both assertions still hold, so it pinned nothing.
        Nothing else in the tree covered that branch either.
        """
        cmd.show('lines', 'm1')
        cmd.show('sticks', 'm1')
        cmd.set('stick_material', 'jelly', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        # the helper the user asked for is ON ...
        self.assertEqual(cmd.get_setting_boolean('line_stick_helper', 'm1'), 1)
        # ... and no transparency was written anywhere, so nothing but the
        # MATERIAL can be what makes the sticks translucent.
        self.assertEqual(
            cmd.get_setting_float('stick_transparency', 'm1'), 0.0)
        # Reported as a failure, not an error: with the rule reverted the
        # helper stays on, every line is suppressed and RepWireBondNew
        # discards the rep, so the accessor raises. That is the right
        # observation but an unreadable way to report it.
        try:
            helper = built_line_stick_helper('m1')
        except Exception as exc:
            self.fail('the lines rep was discarded, i.e. line_stick_helper '
                      'suppressed every line under a jelly stick: %s' % exc)
        # ...and THIS is the rule: the build turned the helper off anyway.
        self.assertEqual(helper, 0)

    def testDefaultSticksSuppressTheirLinesEntirely(self):
        """The mirror, and it is stronger than the flag: with the helper left
        ON, every line under a stick is dropped, RepWireBondNew emits no
        geometry and discards the rep outright -- so the accessor raises where
        jelly's returns 0.

        The second half is what makes "raises" mean something. Hide the sticks
        on the same object, with `lines` shown throughout, and the rep comes
        back recording the helper as 1. So the difference between the two is
        the sticks, not whether lines were ever asked for."""
        cmd.show('lines', 'm1')
        cmd.show('sticks', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        # Matched on the message: a bare assertRaises would also pass on "no
        # such molecular object", i.e. on a typo in the object name, and
        # report the suppression rule as verified when no rep was ever built.
        with self.assertRaisesRegex(Exception, 'not built'):
            built_line_stick_helper('m1')
        cmd.hide('sticks', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        self.assertEqual(built_line_stick_helper('m1'), 1)

    def testAnUnbuiltLinesRepIsAnErrorNotZero(self):
        """0 means "the helper was turned off", so it must not also mean
        "no lines rep exists" -- that would make both tests above vacuous.

        Note this exercises the missing-rep branch, not the -1 sentinel. The
        sentinel is unreachable for cRepLine: RepWireBondNew is the only
        factory for it and always records, so a lines rep that exists always
        carries a value. The sentinel is kept as defence and because
        CmdGetBuiltTransparency's equivalent IS reachable -- several rep types
        record no transparency -- but nothing can cover this one."""
        cmd.set('stick_material', 'jelly', 'm1')
        with self.assertRaisesRegex(Exception, 'not built'):
            built_line_stick_helper('m1')

    # -- the representations jelly cannot draw on -----------------------------

    def testJellyOnSpheresDrawsAsDefault(self):
        """Asserted on the EFFECTIVE id -- what reaches the shader -- not on the
        setting, which still holds what the user typed."""
        by_name = {n: i for i, n in setting.get_material_names(0)}
        jelly = by_name['jelly']
        self.assertEqual(_cmd.get_effective_material(jelly, repres['spheres']), 0)
        for rep in ('surface', 'cartoon', 'sticks'):
            self.assertEqual(
                _cmd.get_effective_material(jelly, repres[rep]), jelly, rep)

    # -- the non-negotiables --------------------------------------------------

    def testSettingJellyWritesNothingElseAtAll(self):
        """Read on the OBJECT the material was set on: reading the globals would
        be true of every setting in PyMOL and would still pass if jelly wrote
        `transparency` or `transparency_peel` on m1."""
        names = setting.get_name_list()
        before_obj = {n: cmd.get(n, 'm1') for n in names}
        before_global = {n: cmd.get(n) for n in names}
        cmd.set('surface_material', 'jelly', 'm1')
        after_obj = {n: cmd.get(n, 'm1') for n in names}
        after_global = {n: cmd.get(n) for n in names}
        changed_obj = {n for n in names if before_obj[n] != after_obj[n]}
        changed_global = {n for n in names if before_global[n] != after_global[n]}
        self.assertEqual(changed_obj, {'surface_material'})
        self.assertEqual(changed_global, set())

    def testJellyDoesNotTouchColour(self):
        cmd.color('red', 'm1')
        before = []
        cmd.iterate('m1', 'before.append(color)', space={'before': before})
        cmd.set('surface_material', 'jelly', 'm1')
        after = []
        cmd.iterate('m1', 'after.append(color)', space={'after': after})
        self.assertEqual(before, after)

    def testJellySurvivesAPseRoundTrip(self):
        """The id is what a .pse stores, and `transparency` stays 0 -- so a
        build that predates jelly renders an opaque surface, visible and wrong,
        rather than an invisible one."""
        cmd.set('surface_material', 'jelly', 'm1')
        with testing.mktemp('.pse') as path:
            cmd.save(path)
            cmd.reinitialize()
            cmd.load(path)
            self.assertEqual(cmd.get('surface_material', 'm1'), 'jelly')
            self.assertEqual(cmd.get_setting_float('transparency', 'm1'), 0.0)
            build('m1', 'surface')
            self.assertAlmostEqual(built_transparency('m1', repres['surface']),
                                   JELLY_TRANSPARENCY, places=4)

    def testAnUnknownJellyLikeNameIsStillAnError(self):
        with self.assertRaises(pymol.CmdException):
            cmd.set('surface_material', 'gelatin', 'm1')

    def testDefaultIsStillUntouched(self):
        """The one that matters most: adding a material must leave a rep with no
        material exactly as it was -- opaque, and reading the legacy sliders."""
        cmd.set('metal_rt_reflect_rough', 0.42, 'm1')
        fam, mode, _r, _t, rough, p = draw_params('m1', repres['surface'])
        self.assertEqual((fam, mode), (0, 0))
        self.assertAlmostEqual(rough, 0.42, places=4)
        self.assertEqual(tuple(p[:3]), (0.0, 0.0, 0.0))
        build('m1', 'surface')
        self.assertAlmostEqual(built_transparency('m1', repres['surface']), 0.0,
                               places=4)
