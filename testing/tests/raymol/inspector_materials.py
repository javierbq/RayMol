"""The Inspector's object-wide material rows (#498), Python side.

Four controls moved or arrived in #498, and three of them need a fact the Swift
side cannot compute:

  * the peel tri-state shows what AUTO currently resolves to, which is a
    question only the core can answer (#488);
  * the legacy `metal_rt_reflect*` group is disabled when it cannot change
    anything the object draws, which depends on the material FAMILY of every
    shown representation;
  * "Suggested lighting" appears beside a material dropdown when a
    `pymol.materials` bundle applies that material, and the join key lives in
    `materials.BUNDLES`.

All three are computed in `appkit_inspector` and shipped in the object payload.
These pin them there, where they can be tested without a GPU or a window.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/inspector_materials.py
"""
import json

from pymol import appkit_inspector as ai
from pymol import cmd, materials, setting, testing


def meta(obj, objs=None):
    """The objmeta entry `poll()` would ship for `obj`."""
    built = ai._build(objs or [obj])
    return built['objmeta'][obj]


def reps_payload(obj, objs=None):
    return ai._build(objs or [obj])['detail'][obj]


class TestInspectorBundles(testing.PyMOLTestCase):
    def testTheBundleListCarriesTheMaterialEachApplies(self):
        """The Inspector joins on the third field to decide whether to offer
        the button beside a material dropdown. A list of (attr, label) alone --
        which is what BUNDLES was before #498 -- cannot answer that."""
        rows = ai.material_bundles()
        self.assertEqual(len(rows), len(materials.BUNDLES))
        for attr, label, mat in rows:
            self.assertTrue(hasattr(materials, attr), attr)
            self.assertTrue(label)
            self.assertIn(mat, [n for _i, n in setting.get_material_names(1)], attr)

    def testTheFourMetalsAllNameMetallic(self):
        """Which is why the control is a MENU when more than one bundle matches
        and a button when one does. A material -> bundle map would silently keep
        whichever metal came last."""
        by_material = {}
        for attr, _label, mat in ai.material_bundles():
            by_material.setdefault(mat, []).append(attr)
        self.assertEqual(sorted(by_material.get('metallic', [])),
                         ['chrome', 'copper', 'gold', 'steel'])
        self.assertEqual(by_material.get('marble'), ['marble'])

    def testPollBundlesEmitsParseableJson(self):
        """The Swift side parses this line; a payload it cannot read leaves the
        control absent with nothing said."""
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ai.poll_bundles()
        line = buf.getvalue().strip()
        self.assertTrue(line.startswith('BUNDLES:'), line[:40])
        rows = json.loads(line[len('BUNDLES:'):])
        self.assertTrue(rows)
        for row in rows:
            self.assertEqual(len(row), 3)
            self.assertTrue(all(isinstance(x, str) for x in row))


class TestInspectorPeelRow(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    def testThePayloadCarriesBothTheSettingAndWhatAutoResolvesTo(self):
        """The tri-state shows the stored value; the hint beside it shows what
        AUTO means right now. Shipping only the setting would leave the most
        common state -- the default -- unreadable."""
        cmd.show('surface', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        m = meta('m1')
        self.assertEqual(m['peel'], -1)          # auto, the default
        self.assertEqual(m['peel_resolved'], 0)  # ...and nothing asks for it
        cmd.set('surface_material', 'glass', 'm1')
        m = meta('m1')
        self.assertEqual(m['peel'], -1)          # the SETTING is untouched ...
        self.assertEqual(m['peel_resolved'], 1)  # ... and auto now means on

    def testAnExplicitValueIsReportedAsItself(self):
        cmd.set('transparency_peel', 0, 'm1')
        self.assertEqual(meta('m1')['peel'], 0)
        cmd.set('transparency_peel', 1, 'm1')
        self.assertEqual(meta('m1')['peel'], 1)


class TestLegacyReflectionGroup(testing.PyMOLTestCase):
    """When the object-wide `metal_rt_reflect*` group is disabled.

    #498 says "once every active rep has a non-default material". That was
    written before #497 gave REFLECTIVE materials an explicit-override path, so
    the test here is narrower: the material must also belong to a family that
    IGNORES the triple. Disabling the group for `metallic` would take away a
    control that still works.
    """
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    def dead(self):
        return meta('m1')['legacy_dead']

    def show(self, *reps):
        """Hide first: RayMol's `auto_show_*` defaults put sticks, cartoon AND
        nb_spheres on a fresh fragment, so a test that only calls show() is
        asserting about four reps it did not choose -- and three of them have no
        material, which keeps the group live for reasons the test never states.
        """
        cmd.hide('everything', 'm1')
        for r in reps:
            cmd.show(r, 'm1')
        cmd.rebuild('m1')
        cmd.refresh()

    def testAnObjectWithNoMaterialsKeepsTheGroupLive(self):
        self.show('surface', 'sticks')
        self.assertEqual(self.dead(), 0)

    def testARepWhoseFLAGIsSetCountsAsDrawn(self):
        """The rep list the poll ships is "some atom has this rep's flag",
        which over-approximates what is on screen: `nb_spheres` draws only
        NONBONDED atoms, but `auto_show_nonbonded` sets its flag on every atom
        of a fresh fragment.

        Kept deliberately. The error is one-directional -- an over-approximation
        keeps the group LIVE when it might have been disabled, and the cost of
        that is an enabled slider that happens to do nothing, against the cost
        of a disabled slider that would have worked."""
        cmd.hide('everything', 'm1')
        cmd.show('surface', 'm1')
        cmd.show('nb_spheres', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        cmd.set('surface_material', 'marble', 'm1')
        self.assertEqual(self.dead(), 0)

    def testAProceduralMaterialOnEveryShownRepKillsIt(self):
        self.show('surface')
        cmd.set('surface_material', 'marble', 'm1')
        self.assertEqual(self.dead(), 1)

    def testAGlassMaterialKillsItToo(self):
        self.show('surface')
        cmd.set('surface_material', 'glass', 'm1')
        self.assertEqual(self.dead(), 1)

    def testAReflectiveMaterialKeepsItLive(self):
        """The #497 refinement, and the one the ticket's own wording gets
        wrong: `metallic` starts from its table row, but an explicit
        per-object metal_rt_reflect still wins. Disabling the sliders there
        would remove a working control and say the opposite of the truth."""
        self.show('surface')
        cmd.set('surface_material', 'metallic', 'm1')
        self.assertEqual(self.dead(), 0)
        # ...and the override really does work, so the group is not merely
        # being left live out of caution.
        from pymol import _cmd
        from pymol.constants import repres
        cmd.set('metal_rt_reflect', 0.9, 'm1')
        _f, _m, refl, _t, _r, _p = _cmd.get_material_draw_params(
            cmd._COb, 'm1', repres['surface'])
        self.assertAlmostEqual(refl, 0.9, places=4)

    def testOneShownRepWithoutAMaterialKeepsItLive(self):
        """Ribbon, mesh, lines, dots and labels have no material setting at
        all, so they draw with `default` shading and DO read the triple. An
        earlier version of this looked only at the four material-bearing reps
        and disabled the group while a ribbon on screen still obeyed it."""
        self.show('surface', 'ribbon')
        cmd.set('surface_material', 'marble', 'm1')
        self.assertEqual(self.dead(), 0)

    def testAMaterialOnAnUNSHOWNRepDoesNotKillIt(self):
        """The claim the disabled group makes is about what the object DRAWS."""
        self.show('surface')
        cmd.set('cartoon_material', 'marble', 'm1')   # cartoon is not shown
        self.assertEqual(self.dead(), 0)

    def testEveryShownRepMustHaveOne(self):
        self.show('surface', 'sticks')
        cmd.set('surface_material', 'marble', 'm1')
        self.assertEqual(self.dead(), 0)
        cmd.set('stick_material', 'marble', 'm1')
        self.assertEqual(self.dead(), 1)

    def testAnObjectShowingNothingKeepsItLive(self):
        """Nothing drawn is not the same as "the sliders are dead": the next
        rep the user shows may well read them."""
        cmd.hide('everything', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()
        self.assertEqual(self.dead(), 0)


class TestObjectWideReflectionValues(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.show('surface', 'm1')
        cmd.rebuild('m1')
        cmd.refresh()

    def testThePayloadCarriesTheObjectLevelTriple(self):
        """One copy, on the object. Until #498 these were three rows in each of
        the four material-bearing rep panels -- twelve controls over three
        object-scoped settings, and moving any one moved the other eleven."""
        cmd.set('metal_rt_reflect', 0.5, 'm1')
        cmd.set('metal_rt_reflect_tint', 0.25, 'm1')
        cmd.set('metal_rt_reflect_rough', 0.75, 'm1')
        refl = meta('m1')['refl']
        self.assertEqual(len(refl), 3)
        self.assertAlmostEqual(refl[0], 0.5, places=4)
        self.assertAlmostEqual(refl[1], 0.25, places=4)
        self.assertAlmostEqual(refl[2], 0.75, places=4)

    def testTheRepPayloadNoLongerCarriesThem(self):
        """The Swift catalog drops the rows; this is the other half -- the poll
        should stop shipping the value four times over."""
        for rep in reps_payload('m1'):
            for s in ('metal_rt_reflect', 'metal_rt_reflect_tint',
                      'metal_rt_reflect_rough'):
                self.assertNotIn(s, rep.get('vals', {}),
                                 '%s still ships %s' % (rep['rep'], s))


class TestWhatTheControlsSend(testing.PyMOLTestCase):
    """The other half of the Inspector's verification.

    The panel cannot be driven headlessly -- these controls live on a screen --
    so an XCTest pins the command string each one emits
    (MaterialInspectorTests.testThePeelControlWritesTheTriStateOnTheObject and
    friends) and this runs those same strings and pins what they do to the
    session. The literal is the join between the two.

    Written out rather than built from a helper on purpose: a helper shared
    with the Swift side does not exist, and one built HERE would let both
    halves drift together.
    """
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    def testThePeelCommandsSetTheTriState(self):
        for value in (0, 1, -1):
            cmd.do('set transparency_peel, %d, m1' % value)
            self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), value)

    def testTheReflectionCommandSetsTheObjectLevelValue(self):
        cmd.do('set metal_rt_reflect, 0.5000, m1')
        self.assertAlmostEqual(
            cmd.get_setting_float('metal_rt_reflect', 'm1'), 0.5, places=4)
        # ...on the OBJECT, so the global is untouched and every rep of m1 sees
        # the same value -- which is the whole reason the row moved to the
        # object header.
        self.assertAlmostEqual(cmd.get_setting_float('metal_rt_reflect'), 0.0,
                               places=4)

    def testTheBundleCommandRunsTheBundle(self):
        cmd.do("python\nfrom pymol import materials; "
               "materials.marble('m1', _self=cmd)\npython end")
        self.assertEqual(cmd.get('surface_material', 'm1'), 'marble')
        self.assertEqual(cmd.get('cartoon_material', 'm1'), 'marble')
        # ...and the lighting half, which is what separates a bundle from the
        # dropdown beside it.
        self.assertAlmostEqual(cmd.get_setting_float('specular'), 0.12, places=4)
        self.assertAlmostEqual(cmd.get_setting_float('metal_sss_wrap'), 0.6,
                               places=4)


class TestSceneMaterialRows(testing.PyMOLTestCase):
    def testTheSceneParamsArePolled(self):
        """A row the panel offers but the poll does not read renders at 0 and
        silently disagrees with the session."""
        self.assertIn('material_default', ai.SCENE_SETTINGS)
        self.assertIn('material_env', ai.SCENE_SETTINGS)
        scene = ai._build([])['scene']
        self.assertIn('material_default', scene)
        self.assertIn('material_env', scene)

    def testTheyReportWhatWasSet(self):
        cmd.reinitialize()
        cmd.set('material_default', 'marble')
        cmd.set('material_env', 1)
        scene = ai._build([])['scene']
        by_name = {n: i for i, n in setting.get_material_names(0)}
        self.assertEqual(int(scene['material_default']), by_name['marble'])
        self.assertEqual(int(scene['material_env']), 1)
