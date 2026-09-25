"""Material "look" bundles (#491): `pymol.materials.marble` / `.clay`.

A material on its own is only half a look -- marble under the default rig still
carries a tight specular highlight that reads as polished plastic. Each bundle
sets the material on the object's material-bearing representations AND the
handful of scene settings the look depends on.

The contract these pin is narrow and load-bearing: a bundle writes exactly what
its docstring lists and NOTHING else. They are not presets -- a preset rebuilds
the representation set from scratch, which throws away whatever the user had on
screen -- so a bundle that quietly changed a rep, a colour, or an unrelated
setting would be a much worse surprise than a preset doing the same.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_bundles.py
"""
import pymol
from pymol import cmd, testing
from pymol import materials

# Every setting a bundle is allowed to touch, as {setting: (marble, clay)}.
# Taken from the docstrings; the tests below assert the bundles write these and
# only these.
EXPECTED = {
    'specular':                  (0.12, 0.0),
    'shininess':                 (8, 4),
    'metal_sss_wrap':            (0.6, 0.25),
    'metal_shadows':             (1, 1),
    'metal_rt_shadows':          (1, 1),
    'metal_rt_shadow_intensity': (0.55, 0.7),
    'metal_ssao':                (1, 1),
    'metal_rt_ao_radius':        (12, 8),
    'metal_rt_ao_intensity':     (0.65, 0.9),
}

REP_MATERIALS = ['cartoon_material', 'surface_material',
                 'stick_material', 'sphere_material']


def snapshot():
    """Every global setting's value, as text. The comparison below is
    whole-table on purpose: naming the settings a bundle must not touch would
    only ever catch the ones someone thought of."""
    from pymol import setting
    out = {}
    for name in setting.get_name_list():
        try:
            out[name] = cmd.get(name)
        except Exception:
            pass
    return out


class TestMaterialBundles(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    # -- the material reaches the object --------------------------------------

    def testMarbleSetsEveryRepMaterialOnTheObject(self):
        materials.marble('m1')
        for s in REP_MATERIALS:
            self.assertEqual(cmd.get(s, 'm1'), 'marble', s)

    def testClaySetsEveryRepMaterialOnTheObject(self):
        materials.clay('m1')
        for s in REP_MATERIALS:
            self.assertEqual(cmd.get(s, 'm1'), 'clay', s)

    def testItAppliesToTheSelectedObjectOnly(self):
        materials.marble('m1')
        for s in REP_MATERIALS:
            self.assertEqual(cmd.get_setting_int(s, 'm2'), 0, s)

    def testItWritesTheOBJECTLevelNotTheGlobal(self):
        """An object-level value is what lets one object differ from another,
        and what survives a later change to the global."""
        materials.marble('m1')
        for s in REP_MATERIALS:
            self.assertEqual(cmd.get_setting_int(s), 0, s)   # global untouched

    def testItCoversRepsThatAreNotShownYet(self):
        """Turning the surface on afterwards must give the look that was asked
        for, not `default`."""
        cmd.hide('everything', 'm1')
        materials.clay('m1')
        cmd.show('surface', 'm1')
        self.assertEqual(cmd.get('surface_material', 'm1'), 'clay')

    def testAllDefaultsToEveryObject(self):
        materials.marble()
        for obj in ('m1', 'm2'):
            self.assertEqual(cmd.get('cartoon_material', obj), 'marble', obj)

    # -- the light rig --------------------------------------------------------

    def testEachBundleSetsItsDocumentedLighting(self):
        for idx, fn in ((0, materials.marble), (1, materials.clay)):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            fn('m1')
            for name, values in EXPECTED.items():
                # get_setting_float, not cmd.get: the rig mixes floats with
                # booleans, and cmd.get renders a boolean as 'on'/'off'.
                self.assertAlmostEqual(cmd.get_setting_float(name),
                                       float(values[idx]), places=4,
                                       msg='%s (%s)' % (name, fn.__name__))

    def testTheTwoBundlesDisagreeSoTheRigIsReallyBeingSet(self):
        """If both wrote the same rig the test above would pass on a no-op."""
        differing = [n for n, v in EXPECTED.items() if v[0] != v[1]]
        self.assertGreaterEqual(len(differing), 5, differing)

    # -- and nothing else -----------------------------------------------------

    def testABundleWritesNothingItDoesNotDocument(self):
        for fn, idx in ((materials.marble, 0), (materials.clay, 1)):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            before = snapshot()
            fn('m1')
            after = snapshot()
            changed = {k for k in after if before.get(k) != after.get(k)}
            # The per-rep materials are written at the OBJECT level, so they do
            # not appear in a global snapshot -- anything else that moved is a
            # setting the bundle does not document.
            unexpected = changed - set(EXPECTED)
            self.assertEqual(unexpected, set(),
                             '%s wrote undocumented settings' % fn.__name__)

    def testABundleNeverTouchesColour(self):
        """#503's non-negotiable. Asserted on the atoms, not just the settings:
        a bundle that recoloured would be the single most annoying way to
        violate it."""
        cmd.color('red', 'm1')
        before = []
        cmd.iterate('m1', 'before.append(color)', space={'before': before})
        materials.marble('m1')
        after = []
        cmd.iterate('m1', 'after.append(color)', space={'after': after})
        self.assertEqual(before, after)

    def testABundleNeverChangesWhichRepsAreShown(self):
        """The whole reason these are not presets."""
        cmd.hide('everything', 'm1')
        cmd.show('sticks', 'm1')
        before = cmd.get_object_list('m1'), _shown('m1')
        materials.clay('m1')
        self.assertEqual((cmd.get_object_list('m1'), _shown('m1')), before)

    # -- registration ---------------------------------------------------------

    def testBothBundlesAreOfferedAndResolve(self):
        for _label, attr in materials.BUNDLES:
            self.assertTrue(hasattr(materials, attr), attr)
            self.assertTrue(callable(getattr(materials, attr)), attr)

    def testAGroupIsNotWrittenTwice(self):
        """`cmd.set` expands a group to its members, so writing the group as
        well would double every member."""
        cmd.group('g1', 'm1 m2')
        objs = materials._objects('g1')
        self.assertNotIn('g1', objs)

    def testAnEmptySelectionIsHarmless(self):
        materials.marble('none')   # must not raise


def _shown(obj):
    """Which reps are currently enabled on `obj`."""
    out = []
    cmd.iterate_state(-1, obj, 'pass')   # force the rep flags to be current
    for rep in ('cartoon', 'surface', 'sticks', 'spheres', 'lines', 'ribbon'):
        try:
            if cmd.count_atoms('%s and rep %s' % (obj, rep)) > 0:
                out.append(rep)
        except Exception:
            pass
    return out
