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

    # -- named metals (#497) --------------------------------------------------

    def testEachMetalSetsMetallicAndItsColour(self):
        """A named metal is `metallic` plus a colour. It writes colour ON
        PURPOSE -- that is exactly what separates a bundle from a material, and
        why copper cannot be a table row: what makes copper copper is mostly
        its colour, and a material must never touch that."""
        for name in ('copper', 'gold', 'steel', 'chrome'):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            before = [c for c in _colors('m1')]
            getattr(materials, name)('m1')
            for s in REP_MATERIALS:
                self.assertEqual(cmd.get(s, 'm1'), 'metallic', '%s/%s' % (name, s))
            self.assertNotEqual(_colors('m1'), before, name)

    def testTheMetalsAreDistinctFromEachOther(self):
        """If two bundles wrote the same colour the test above would pass on a
        pair that is not actually different."""
        seen = {}
        for name in ('copper', 'gold', 'steel', 'chrome'):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            getattr(materials, name)('m1')
            seen[name] = tuple(_colors('m1'))
        self.assertEqual(len(set(seen.values())), 4, seen)

    def testChromeIsSharperThanPlainMetallic(self):
        """Chrome's whole character is that it is the mirror end of the range.
        The table gives `metallic` tint 0.35 / rough 0.35; chrome overrides both
        per object, which is what the explicit-override path exists for."""
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        materials.chrome('m1')
        self.assertAlmostEqual(cmd.get_setting_float('metal_rt_reflect_rough', 'm1'),
                               0.05, places=4)
        self.assertAlmostEqual(cmd.get_setting_float('metal_rt_reflect_tint', 'm1'),
                               0.10, places=4)

    def testAMetalWritesNothingOutsideItsDocumentedSet(self):
        """Same whole-table guard as the look bundles, widened to the settings a
        metal is allowed: the rep materials (object level) and the three
        reflection overrides."""
        allowed = set(REP_MATERIALS) | {'metal_rt_reflect',
                                        'metal_rt_reflect_tint',
                                        'metal_rt_reflect_rough'}
        from pymol import setting
        want = {setting._get_index(n) for n in allowed}
        for name in ('copper', 'gold', 'steel', 'chrome'):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            g_before = snapshot()
            o_before = _obj_settings('m1')
            getattr(materials, name)('m1')
            self.assertEqual(snapshot(), g_before,
                             '%s changed a GLOBAL setting' % name)
            changed = {k for k in _obj_settings('m1')
                       if o_before.get(k) != _obj_settings('m1')[k]}
            self.assertTrue(changed <= want,
                            '%s wrote %s' % (name, changed - want))

    def testAMetalAppliesColourToTheSELECTIONNotTheWholeObject(self):
        """Colour is per atom, unlike a material -- so `gold('resi 1')` golds
        residue 1 and leaves the rest of the object alone. This is the one place
        a bundle can honour a selection, and it should."""
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.color('white', 'm1')
        materials.gold('m1 and name CA')
        cols = {}
        cmd.iterate('m1', 'cols[name] = color', space={'cols': cols})
        self.assertNotEqual(cols['CA'], cols['CB'])

    # -- registration ---------------------------------------------------------

    def testBothBundlesAreOfferedAndResolve(self):
        for _label, attr, _material in materials.BUNDLES:
            self.assertTrue(hasattr(materials, attr), attr)
            self.assertTrue(callable(getattr(materials, attr)), attr)

    def testEveryBundleNamesTheMaterialItActuallyApplies(self):
        """The third field of BUNDLES is what the Inspector joins on to offer
        "Suggested lighting" beside a material dropdown (#498). A wrong value
        there is invisible -- the button simply appears next to the wrong
        material, or not at all -- so it is checked against what the bundle
        DOES rather than against a second list."""
        from pymol import setting
        for label, attr, material in materials.BUNDLES:
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            getattr(materials, attr)('m1')
            for rep_setting in REP_MATERIALS:
                self.assertEqual(cmd.get(rep_setting, 'm1'), material,
                                 '%s (%s) writes a different material' % (label, attr))
            # ...and it is a real, offerable material, not a typo that happens
            # to match: an unimplemented name would make the button appear for
            # a dropdown entry that does not exist.
            self.assertIn(material,
                          [n for _i, n in setting.get_material_names(1)], label)

    def testAGroupResolvesToItsMembers(self):
        cmd.group('g1', 'm1 m2')
        objs = materials._objects('g1')
        self.assertNotIn('g1', objs)
        self.assertEqual(sorted(objs), ['m1', 'm2'])

    def testABundleWritesNoOBJECTSettingItDoesNotDocument(self):
        """The global snapshot above structurally cannot see an object-level
        stray, and `_apply_material` is the function that takes an object
        argument -- so this is the half that can actually regress."""
        from pymol import setting
        want = {setting._get_index(n) for n in REP_MATERIALS}
        for fn in (materials.marble, materials.clay):
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            cmd.fragment('gly', 'm2')
            cmd.show('cartoon'); cmd.show('sticks'); cmd.show('spheres')
            cmd.refresh()
            before = {o: _obj_settings(o) for o in ('m1', 'm2')}
            fn('m1')
            after = {o: _obj_settings(o) for o in ('m1', 'm2')}
            changed = {k for k in after['m1']
                       if before['m1'].get(k) != after['m1'][k]}
            self.assertEqual(changed, want,
                             '%s changed object settings %s' % (fn.__name__, changed))
            self.assertEqual(before['m2'], after['m2'],
                             '%s touched another object' % fn.__name__)

    def testNothingIsWrittenWhenNoObjectMatches(self):
        """A typo'd name used to rewrite the whole global light rig and apply no
        material, silently -- a changed scene and nothing to explain it."""
        before = snapshot()
        materials.marble('typo_object_name')
        self.assertEqual(snapshot(), before)

    def testAnUnknownMaterialNameIsNotSwallowed(self):
        """A bundle that silently applied nothing would be much harder to
        diagnose than one that names what it could not resolve."""
        with self.assertRaises(pymol.CmdException):
            materials._apply_material('no_such_material', 'm1')

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


def _colors(obj):
    """Atom colour indices, in iteration order."""
    out = []
    cmd.iterate(obj, 'out.append(color)', space={'out': out})
    return out


def _obj_settings(obj):
    """{index: value} an object has explicitly set."""
    return {e[0]: e[2] for e in (cmd.get_object_settings(obj) or [])}
