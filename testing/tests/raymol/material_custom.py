"""The Custom material, core half (#568).

A layer's material is its base material plus optional per-layer overrides of
that material's own knobs: `<rep>_material_reflect`, `_tint`, `_rough` and
`_knob1`..`_knob6` for cartoon, surface, stick and sphere. Unset means the
base's value. They are OBJECT-scoped settings, and each MATERIAL has only the
knobs its shader reads (`_cmd.get_material_knobs`) -- the meaning of a p[]
slot differs per material, not per family: marble reads p[1] as vein scale and
never reads p[0], rubber reads p[2] as its highlight where clay reads it as
grazing darkening. An override of an unlisted knob is ignored, and an override
never switches the shading model.

Asserted on the FINAL draw params (`get_material_draw_params`) -- what the
shader is handed -- not on the settings.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_custom.py
"""
from pymol import _cmd, cmd, setting, testing
from pymol.constants import repres

REPS = ('cartoon', 'surface', 'stick', 'sphere')
KNOBS = ('reflect', 'tint', 'rough', 'knob1', 'knob2', 'knob3',
         'knob4', 'knob5', 'knob6')
REP_INDEX = {'cartoon': repres['cartoon'], 'surface': repres['surface'],
             'stick': repres['sticks'], 'sphere': repres['spheres']}


def params(obj, rep='surface'):
    """(family, mode, reflect, tint, rough, (p0..p5))"""
    f, m, r, t, ro, p = _cmd.get_material_draw_params(cmd._COb, obj, REP_INDEX[rep])
    return f, m, r, t, ro, tuple(p)


class TestTheSettings(testing.PyMOLTestCase):

    def testThirtySixObjectScopedSettingsInOneBlock(self):
        names = ['%s_material_%s' % (r, k) for r in REPS for k in KNOBS]
        indices = [setting._get_index(n) for n in names]
        # .pse files store indices: these are theirs for good
        self.assertEqual(indices, list(range(846, 882)))
        for n in names:
            self.assertEqual(
                _cmd.get_setting_level(setting._get_index(n)), 'object', n)

    def testTheSceneCapturesThemPerObject(self):
        from pymol import raymol_scenes as rs
        for r in REPS:
            for k in KNOBS:
                self.assertIn('%s_material_%s' % (r, k), rs.OBJECT_CAPTURE)


class TestTheOverrides(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    def testUnsetMeansTheMaterialsOwnValues(self):
        cmd.set('surface_material', 'metallic', 'm1')
        self.assertEqual(params('m1')[2:5], (0.6000000238418579,
                                             0.3499999940395355,
                                             0.25))

    def testAReflectiveMaterialTakesReflectTintAndRough(self):
        cmd.set('surface_material', 'metallic', 'm1')
        base = params('m1')
        cmd.set('surface_material_reflect', 0.9, 'm1')
        cmd.set('surface_material_rough', 0.05, 'm1')
        f, m, r, t, ro, _p = params('m1')
        self.assertAlmostEqual(r, 0.9, places=5)
        self.assertAlmostEqual(t, 0.35, places=5)   # not overridden: its own
        self.assertAlmostEqual(ro, 0.05, places=5)
        cmd.set('surface_material_tint', 1.0, 'm1')
        self.assertAlmostEqual(params('m1')[3], 1.0, places=5)
        # the shading model is still the base's
        self.assertEqual((f, m), base[:2])

    def testJellyTakesItsFiveKnobsOnly(self):
        # rough, knob1..3 (its body) and knob4 (Distortion, #590)
        cmd.set('surface_material', 'jelly', 'm1')
        base = params('m1')
        cmd.set('surface_material_rough', 0.5, 'm1')
        for k in (1, 2, 3, 4):
            cmd.set('surface_material_knob%d' % k, 0.1 * k, 'm1')
        for k in (5, 6):                                   # not jelly's
            cmd.set('surface_material_knob%d' % k, 9.0, 'm1')
        cmd.set('surface_material_reflect', 0.7, 'm1')    # not jelly's
        _f, _m, r, _t, ro, p = params('m1')
        self.assertAlmostEqual(ro, 0.5, places=5)
        for k in (1, 2, 3, 4):
            self.assertAlmostEqual(p[k - 1], 0.1 * k, places=5)
        self.assertEqual(p[4:], base[5][4:])
        self.assertEqual(r, base[2])

    def testMarbleTakesVeinScaleContrastAndSharpnessOnly(self):
        cmd.set('surface_material', 'marble', 'm1')
        base = params('m1')
        for k in range(1, 7):
            cmd.set('surface_material_knob%d' % k, 0.5 + k, 'm1')
        cmd.set('surface_material_reflect', 0.8, 'm1')    # not marble's
        _f, _m, r, t, ro, p = params('m1')
        self.assertAlmostEqual(p[1], 2.5, places=5)       # knob2: vein scale
        self.assertAlmostEqual(p[4], 5.5, places=5)       # knob5: vein contrast
        self.assertAlmostEqual(p[5], 6.5, places=5)       # knob6: vein sharpness
        for i in (0, 2, 3):                               # marble reads none of these
            self.assertEqual(p[i], base[5][i], i)
        self.assertEqual((r, t, ro), (0.0, 0.0, 0.0))

    def testEveryMaterialTakesExactlyTheKnobsItLists(self):
        """Data-driven over the whole table: set all nine overrides, and only
        the slots the material lists move -- everything else stays the base's."""
        slot = {'reflect': ('r', None), 'tint': ('t', None), 'rough': ('ro', None)}
        for k in range(1, 7):
            slot['knob%d' % k] = ('p', k - 1)
        for mid, name in setting.get_material_names(1):
            if name == 'default':
                continue
            cmd.set('surface_material', name, 'm1')
            for k in KNOBS:
                cmd.unset('surface_material_%s' % k, 'm1')
            base = params('m1')
            listed = {row[0] for row in _cmd.get_material_knobs(mid)}
            for k in KNOBS:
                cmd.set('surface_material_%s' % k, 0.4321, 'm1')
            got = params('m1')
            for k in KNOBS:
                kind, i = slot[k]
                before = {'r': base[2], 't': base[3], 'ro': base[4]}.get(kind) \
                    if kind != 'p' else base[5][i]
                after = {'r': got[2], 't': got[3], 'ro': got[4]}.get(kind) \
                    if kind != 'p' else got[5][i]
                if k in listed:
                    self.assertAlmostEqual(after, 0.4321, places=4, msg='%s %s' % (name, k))
                else:
                    self.assertEqual(after, before, '%s %s' % (name, k))
            self.assertEqual(got[:2], base[:2], name)     # same shading model

    def testTheKnobListsMatchWhatTheShadersRead(self):
        """Pinned by hand against RendererMetal.mm, because the table is the
        one place that knows it (mat_body_shade, mat_shade_procedural,
        mat_marble_albedo, mat_jelly_shade, mat_glass_shade)."""
        by_name = {n: i for i, n in setting.get_material_names(1)}
        def knobs(name):
            return [row[0] for row in _cmd.get_material_knobs(by_name[name])]
        self.assertEqual(knobs('default'), [])
        self.assertEqual(knobs('metallic'), ['reflect', 'tint', 'rough'])
        self.assertEqual(knobs('plastic'), ['reflect', 'tint', 'rough'])
        self.assertEqual(knobs('glass'), ['knob1', 'knob2', 'rough'])
        self.assertEqual(knobs('frosted_glass'), ['knob1', 'knob2', 'rough'])
        self.assertEqual(knobs('jelly'), ['rough', 'knob1', 'knob2', 'knob3', 'knob4'])
        self.assertEqual(knobs('matte'), ['knob1', 'knob2'])
        self.assertEqual(knobs('clay'), ['knob1', 'knob2', 'knob3'])
        self.assertEqual(knobs('rubber'), ['knob1', 'knob2', 'knob3', 'knob4'])
        self.assertEqual(knobs('marble'), ['knob2', 'knob5', 'knob6'])
        for mid, _n in setting.get_material_names(1):
            for _suffix, label, lo, hi, control in _cmd.get_material_knobs(mid):
                self.assertTrue(label)
                self.assertLess(lo, hi)
                self.assertIn(control, ('slider', 'toggle'))

    def testDefaultHasNoKnobs(self):
        base = params('m1')
        for k in KNOBS:
            cmd.set('surface_material_%s' % k, 0.77, 'm1')
        self.assertEqual(params('m1'), base)

    def testAnOverrideIsOneLayerOfOneObject(self):
        for rep in ('surface', 'cartoon'):
            cmd.set('%s_material' % rep, 'metallic', 'm1')
        cmd.set('surface_material', 'metallic', 'm2')
        cmd.set('surface_material_reflect', 0.95, 'm1')
        self.assertAlmostEqual(params('m1', 'surface')[2], 0.95, places=5)
        self.assertAlmostEqual(params('m1', 'cartoon')[2], 0.6, places=5)
        self.assertAlmostEqual(params('m2', 'surface')[2], 0.6, places=5)

    def testAGlobalValueIsNotAnOverride(self):
        """Custom tunes one layer of one object. A global value (every object
        has one, as a fallback) must not become everyone's override."""
        cmd.set('surface_material', 'metallic', 'm1')
        cmd.set('surface_material_reflect', 0.95)
        self.assertAlmostEqual(params('m1')[2], 0.6, places=5)

    def testEveryLayerReadsItsOwnSettings(self):
        for rep in REPS:
            cmd.set('%s_material' % rep, 'metallic', 'm1')
            cmd.set('%s_material_reflect' % rep, 0.1 + REPS.index(rep) * 0.2, 'm1')
        for i, rep in enumerate(REPS):
            self.assertAlmostEqual(params('m1', rep)[2], 0.1 + i * 0.2, places=5,
                                   msg=rep)

    def testASceneRestoresTheOverrides(self):
        cmd.set('surface_material', 'metallic', 'm1')
        cmd.set('surface_material_reflect', 0.2, 'm1')
        cmd.scene('s1', 'store')
        cmd.set('surface_material_reflect', 0.9, 'm1')
        cmd.scene('s1', 'recall', animate=0)
        self.assertAlmostEqual(params('m1')[2], 0.2, places=5)
        # ...and an override added after the store is taken away again
        cmd.set('surface_material_tint', 0.9, 'm1')
        cmd.scene('s1', 'recall', animate=0)
        self.assertAlmostEqual(params('m1')[3], 0.35, places=5)
