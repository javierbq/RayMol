"""Side chains follow the cartoon's material (MaterialSourceRep).

A stick or sphere layer with no material of its own -- `stick_material` /
`sphere_material` unset on the object and `default` globally -- draws with the
CARTOON's material and Custom knobs while the object shows a cartoon. Giving the
layer a material, `default` included, makes it independent; hiding the cartoon
releases it. Surfaces never follow. The per-rep degradations stay keyed on the
rep that draws: a glass cartoon's spheres still degrade to `default`.

And a Look is a base coat on ATOMS, so "by element" (util.cnc) recolours the
heteroatoms on top of it.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_follow.py
"""
from pymol import _cmd, cmd, testing, util
from pymol.constants import repres

CARTOON = repres['cartoon']
STICKS = repres['sticks']
SPHERES = repres['spheres']
SURFACE = repres['surface']


def params(obj, rep):
    f, m, r, t, ro, p = _cmd.get_material_draw_params(cmd._COb, obj, rep)
    return f, m, round(r, 4), round(t, 4), round(ro, 4), tuple(round(x, 4) for x in p)


def source(obj, rep):
    """Which layer's material settings the rep reads."""
    return _cmd.get_rep_material(cmd._COb, obj, rep, -1, 1)


def material(obj, rep):
    return _cmd.get_rep_material(cmd._COb, obj, rep, -1)


def built_transparency(obj, rep):
    return _cmd.get_built_transparency(cmd._COb, obj, rep)


def colours(sele):
    out = set()
    cmd.iterate(sele, 'out.add(color)', space={'out': out})
    return out


class TestSideChainsFollowTheCartoon(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        # one state: RepVisCache is every bit for a single-state object, so a
        # follow rule reading it would think the cartoon is always shown
        cmd.fab('ACDEFGHIKM', 'p', ss=1)
        cmd.hide('everything')
        cmd.show('cartoon')
        cmd.show('sticks', 'sidechain')
        cmd.set('cartoon_material', 'metallic', 'p')
        cmd.set('cartoon_material_tint', 0.9, 'p')

    def testSticksAndSpheresDrawWithTheCartoonsMaterialAndKnobs(self):
        self.assertEqual(source('p', STICKS), CARTOON)
        self.assertEqual(source('p', SPHERES), CARTOON)
        self.assertEqual(material('p', STICKS), 3)            # metallic
        cartoon = params('p', CARTOON)
        self.assertEqual(cartoon[3], 0.9)                     # the Custom tint
        self.assertEqual(params('p', STICKS), cartoon)
        self.assertEqual(params('p', SPHERES), cartoon)

    def testABuiltRepReportsWhatTheDrawPathUses(self):
        """Once a rep is built, the accessor answers through the DRAW path's
        cached resolve (MaterialDrawParamsCached, as CGOGL calls it), which
        has to follow the cartoon the same way."""
        cartoon = params('p', CARTOON)
        cmd.set('stick_material_tint', 0.1, 'p')     # its own, ignored
        cmd.refresh()
        self.assertEqual(built_transparency('p', STICKS), 0.0)  # built
        self.assertEqual(params('p', STICKS), cartoon)

    def testTheCpuRayStampsTheCartoonsMaterialToo(self):
        wobble, mid, spec, diff, tint = _cmd.get_material_ray_params(
            cmd._COb, 'p', STICKS)
        self.assertEqual(mid, 3)

    def testSurfacesNeverFollow(self):
        self.assertEqual(source('p', SURFACE), SURFACE)
        self.assertEqual(params('p', SURFACE)[0], 0)

    def testAMaterialOfItsOwnKeepsTheLayerIndependent(self):
        cmd.set('stick_material', 'default', 'p')   # explicit default counts
        self.assertEqual(source('p', STICKS), STICKS)
        self.assertEqual(params('p', STICKS)[0], 0)
        self.assertEqual(source('p', SPHERES), CARTOON)  # per layer
        cmd.unset('stick_material', 'p')             # Inherit: follows again
        self.assertEqual(source('p', STICKS), CARTOON)

    def testAGlobalMaterialOfItsOwnKeepsTheLayerIndependent(self):
        cmd.set('stick_material', 'matte')
        self.assertEqual(source('p', STICKS), STICKS)
        self.assertEqual(material('p', STICKS), 1)   # matte

    def testTheLayersOwnKnobsAreNotReadWhileFollowing(self):
        cmd.set('stick_material_tint', 0.1, 'p')
        self.assertEqual(params('p', STICKS)[3], 0.9)

    def testHidingTheCartoonReleasesTheSideChains(self):
        cmd.hide('cartoon', 'p')
        self.assertEqual(source('p', STICKS), STICKS)
        self.assertEqual(params('p', STICKS)[0], 0)
        cmd.show('cartoon', 'p')
        self.assertEqual(source('p', STICKS), CARTOON)

    def testACartoonOnSomeResiduesIsEnough(self):
        cmd.hide('cartoon', 'p and not resi 3')
        self.assertEqual(source('p', STICKS), CARTOON)

    def testAnObjectWithNoPolymerNeverFollows(self):
        """`show cartoon` marks a ligand's atoms too, but draws nothing."""
        cmd.fragment('benzene', 'lig')
        cmd.show('sticks', 'lig')
        cmd.show('cartoon')                      # global, as a user would
        self.assertEqual(cmd.count_atoms('lig and rep cartoon'),
                         cmd.count_atoms('lig'))  # precondition
        self.assertEqual(source('lig', STICKS), STICKS)
        cmd.set('cartoon_material', 'glass')
        cmd.refresh()
        self.assertEqual(built_transparency('lig', STICKS), 0.0)

    def testOnlyMolecules(self):
        self.assertEqual(_cmd.get_rep_material(cmd._COb, '', STICKS, -1, 1), STICKS)

    def testDegradationsStayKeyedOnTheRepThatDraws(self):
        """Glass on sphere impostors floats as near-invisible discs, so spheres
        following a glass cartoon still draw `default`."""
        cmd.set('cartoon_material', 'glass', 'p')
        self.assertEqual(params('p', CARTOON)[0], 3)   # glass family
        self.assertEqual(params('p', STICKS)[0], 3)
        self.assertEqual(params('p', SPHERES)[0], 0)

    def testEverythingDefaultStaysDefault(self):
        cmd.unset('cartoon_material', 'p')
        cmd.unset('cartoon_material_tint', 'p')
        for rep in (CARTOON, STICKS, SPHERES):
            self.assertEqual(params('p', rep), (0, 0, 0.0, 0.0, 0.0, (0.0,) * 6))

    def testAGlassCartoonRebuildsTheSticksTranslucent(self):
        """Implied alpha is a BUILD input: changing the cartoon's material, and
        showing or hiding the cartoon, has to rebuild the following sticks."""
        cmd.refresh()
        self.assertEqual(built_transparency('p', STICKS), 0.0)
        cmd.set('cartoon_material', 'glass', 'p')
        cmd.refresh()
        self.assertAlmostEqual(built_transparency('p', STICKS), 0.85, places=4)
        cmd.hide('cartoon', 'p')
        cmd.refresh()
        self.assertEqual(built_transparency('p', STICKS), 0.0)
        cmd.show('cartoon', 'p')
        cmd.refresh()
        self.assertAlmostEqual(built_transparency('p', STICKS), 0.85, places=4)

    def testAStateLevelCartoonMaterialRebuildsTheSticksOnToggle(self):
        """The draw path reads the state's settings first, so the toggle's
        rebuild has to as well."""
        cmd.unset('cartoon_material', 'p')
        cmd.hide('cartoon', 'p')
        cmd.set('cartoon_material', 'glass', 'p', state=1)
        cmd.refresh()
        self.assertEqual(built_transparency('p', STICKS), 0.0)
        cmd.show('cartoon', 'p')
        cmd.refresh()
        self.assertAlmostEqual(built_transparency('p', STICKS), 0.85, places=4)
        cmd.hide('cartoon', 'p')
        cmd.refresh()
        self.assertEqual(built_transparency('p', STICKS), 0.0)

    def testFollowingGlassSticksDoNotVetoTheCartoonsPeel(self):
        """Auto-peel refuses when a transparent rep did not ask for it. Sticks
        following a glass cartoon DID -- they are glass too."""
        cmd.set('cartoon_material', 'glass', 'p')
        cmd.refresh()
        self.assertAlmostEqual(built_transparency('p', STICKS), 0.85, places=4)
        self.assertEqual(_cmd.get_object_peel(cmd._COb, 'p'), 1)

    def testTheInspectorSaysTheLayerFollows(self):
        from pymol import appkit_inspector as ai
        explicit = {e[0] for e in (cmd.get_object_settings('p') or [])}
        self.assertTrue(ai._custom_state('sticks', 'p', explicit)['follows'])
        self.assertFalse(ai._custom_state('cartoon', 'p', explicit)['follows'])
        self.assertFalse(ai._custom_state('surface', 'p', explicit)['follows'])
        cmd.set('stick_material', 'plastic', 'p')
        self.assertFalse(ai._custom_state('sticks', 'p', explicit)['follows'])


class TestALookIsABaseCoat(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fab('ACDEFGHIKM', 'p', ss=1)
        cmd.hide('everything')
        cmd.show('cartoon')
        cmd.show('sticks', 'sidechain')

    def gold_index(self):
        return cmd.get_color_index('look_gold')

    def testACartoonLookColoursTheSideChainsAndByElementRecoloursHeteroatoms(self):
        cmd.apply_look('gold', 'p', 'cartoon')
        gold = self.gold_index()
        self.assertEqual(colours('p'), {gold})
        util.cnc('p')
        self.assertEqual(colours('p and elem C'), {gold})
        self.assertNotIn(gold, colours('p and elem N'))
        self.assertNotIn(gold, colours('p and elem O'))
        self.assertNotIn(gold, colours('p and elem S'))

    def testItClearsTheLayerColoursThatWouldHideTheAtomColours(self):
        cmd.set('cartoon_color', 'red', 'p')
        cmd.set('stick_color', 'blue', 'p')
        cmd.set('cartoon_color', 'green', 'resi 2')

        def atom_level():
            out = set()
            cmd.iterate('p', 'out.add(s.cartoon_color)', space={'out': out})
            return out
        self.assertIn(cmd.get_color_index('green'), atom_level())  # precondition
        cmd.apply_look('gold', 'p', 'cartoon')
        self.assertEqual(cmd.get('cartoon_color', 'p'), 'default')
        self.assertEqual(cmd.get('stick_color', 'p'), 'default')  # it follows
        self.assertEqual(atom_level(), {None})                    # unset per atom

    def testAnIndependentStickLayerKeepsItsColour(self):
        cmd.set('stick_material', 'plastic', 'p')
        cmd.set('stick_color', 'blue', 'p')
        cmd.apply_look('gold', 'p', 'cartoon')
        self.assertEqual(cmd.get('stick_color', 'p'), 'blue')

    def testACartoonLookSkipsAtomsOutsideItsResidues(self):
        """A ligand in the same object follows the cartoon's material, but
        only the cartoon's residues take its colour."""
        cmd.pseudoatom('p', name='LIG', resn='LIG', resi=900, chain='Z')
        cmd.color('red', 'p and resn LIG')
        cmd.show('sticks', 'p and resn LIG')
        # as the Inspector's toggle does: the cartoon bit lands on the ligand
        cmd.show('cartoon', 'p')
        self.assertEqual(cmd.count_atoms('p and resn LIG and rep cartoon'), 1)
        cmd.apply_look('gold', 'p', 'cartoon')
        self.assertEqual(colours('p and resn LIG'), {cmd.get_color_index('red')})

    def testACartoonLookColoursWholeResidues(self):
        """The side chains take the cartoon's colour whichever atoms carry the
        cartoon bit, shown as sticks yet or not."""
        cmd.hide('everything')
        cmd.show('cartoon', 'p and name CA')
        cmd.apply_look('gold', 'p', 'cartoon')
        self.assertEqual(colours('p'), {self.gold_index()})

    def testAStickLookColoursTheStickAtoms(self):
        cmd.color('red', 'p')
        cmd.apply_look('copper', 'p', 'stick')
        copper = cmd.get_color_index('look_copper')
        self.assertEqual(colours('p and rep sticks'), {copper})
        self.assertEqual(colours('p and not rep sticks'), {cmd.get_color_index('red')})

    def testALayerShownOnNoAtomColoursTheObject(self):
        cmd.apply_look('steel', 'p', 'surface')
        self.assertEqual(colours('p'), {cmd.get_color_index('look_steel')})
