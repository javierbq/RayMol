"""Jelly (#496): the gummy, and the last row of the v1 material table.

Jelly lives in the glass FAMILY -- it shares its pipeline, its peel and its
implied-alpha machinery -- but it is the opposite material. Glass is a clear
body under a Fresnel rim; jelly is a dense scattering body under a smooth wet
skin. Everything asserted here is a place those two could quietly collapse into
each other:

  * its implied alpha is 0.45, three times clear glass's, so a jelly surface is
    a body you look INTO rather than through. Sharing a value with glass would
    still shade like a gummy and still look wrong.
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
JELLY_TRANSPARENCY = 1.0 - 0.45


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
        not built, and would draw as `default`."""
        self.assertEqual(family('jelly'), GLASS_FAMILY)

    def testJellyHasItsOwnModeWithinTheFamily(self):
        """The three glass-family materials share one pipeline and are told
        apart by `mode` alone. Pinning the numbers here is what keeps the Metal
        block's kMatMode_jelly and the C enum from drifting: they are in
        different languages and nothing else compares them."""
        by_name = {n: i for i, n in setting.get_material_names(0)}
        self.assertEqual(by_name['jelly'], JELLY_MODE)
        for name in ('glass', 'frosted_glass', 'jelly'):
            cmd.set('surface_material', name, 'm1')
            _f, mode, _r, _t, _ro, _p = draw_params('m1', repres['surface'])
            self.assertEqual(mode, by_name[name], name)

    # -- implied alpha --------------------------------------------------------

    def testJellySurfaceBuildsAtItsOwnAlpha(self):
        """0.45 alpha -> 0.55 transparency. The table stores ALPHA and layer2
        wants a TRANSPARENCY; returning 0.45 here would shade like a gummy and
        be 45% see-through instead of 55% -- close enough to look deliberate."""
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
        a 0.85-transparent gummy is a tinted glass."""
        seen = {}
        for name in ('glass', 'frosted_glass', 'jelly'):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            cmd.set('surface_material', name, 'm1')
            build('m1', 'surface')
            seen[name] = round(built_transparency('m1', repres['surface']), 4)
        self.assertEqual(seen, {'glass': 0.85, 'frosted_glass': 0.8,
                                'jelly': 0.55})

    def testTheUsersSliderWins(self):
        cmd.set('transparency', 0.2, 'm1')
        cmd.set('surface_material', 'jelly', 'm1')
        build('m1', 'surface')
        self.assertAlmostEqual(cmd.get_setting_float('transparency', 'm1'), 0.2,
                               places=4)
        self.assertAlmostEqual(built_transparency('m1', repres['surface']), 0.2,
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
        """Jelly's row sets wantsPeel. At 0.55 transparency a ball-and-stick or
        a closed surface accumulates its own far side, which is the mottle peel
        exists to remove -- and jelly, being the densest of the three, is where
        it matters most."""
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
        sphere impostor has no glass-family path. The whole rep degrades --
        shading AND implied alpha together, or a `default`-shaded stick would
        still build 55% transparent."""
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
