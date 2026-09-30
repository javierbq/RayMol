"""The Inspector's object-wide material row (#498), Python side.

The peel tri-state shows what AUTO currently resolves to, which is a question
only the core can answer (#488). It is computed in `appkit_inspector` and
shipped in the object payload; these pin it there, where it can be tested
without a GPU or a window. (The legacy `metal_rt_reflect*` group that shared
the header was removed in #565, and the Look bundles in #566.)

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/inspector_materials.py
"""
import os
import re

from pymol import appkit_inspector as ai
from pymol import cmd, setting, testing


def meta(obj, objs=None):
    """The objmeta entry `poll()` would ship for `obj`."""
    built = ai._build(objs if objs is not None else [obj])
    return built['objmeta'][obj]


def reps_payload(obj, objs=None):
    return ai._build(objs or [obj])['detail'][obj]


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


class TestWhichObjectsGetTheRows(testing.PyMOLTestCase):
    """The object-wide peel row is for peelable objects, and not for groups.

    Two separate reasons, and each of them bit before the gate existed:

      * probing one for its peel resolves through ExecutiveFindObjectByName,
        which writes "named object not found." straight to the feedback log --
        the issue #219 flood, twice a second for as long as the card is open,
        and unsuppressable from Python because the line is out before the call
        returns;
      * on a GROUP, `cmd.set` expands to the members but `cmd.get` reports the
        group's own value, so every control wrote correctly and then reverted
        half a second later when the poll landed.
    """
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    def testAMoleculeGetsIt(self):
        self.assertEqual(meta('m1')['peel_row'], 1)

    def testAMeasurementGetsIt(self):
        """Peel is not a material question: SceneCollectPeelObjects walks every
        non-gadget object."""
        cmd.distance('d1', 'm1 and index 1', 'm1 and index 2')
        m = meta('d1', objs=['m1', 'd1'])
        self.assertEqual(m['peel_row'], 1)

    def testNoPayloadCarriesTheRetiredReflectionGroup(self):
        """#565 retired the object-wide metal_rt_reflect* group. Its payload keys
        -- and the molecules-only gate that existed only for it -- go too."""
        for key in ('refl', 'legacy_dead', 'material_rows'):
            self.assertNotIn(key, meta('m1'), key)

    def testObjectKindsMatchExecutiveGetType(self):
        """OBJECT_KINDS is a hand-kept copy of ExecutiveGetType's labels, so
        read the switch and compare, in order. Skipped outside a repo checkout:
        a source-reading test that cannot find its source has checked
        nothing."""
        root = os.path.join(os.path.dirname(__file__), os.pardir, os.pardir,
                            os.pardir)
        path = os.path.normpath(os.path.join(root, 'layer3', 'Executive.cpp'))
        if not os.path.isfile(path):
            self.skipTest('layer3/Executive.cpp not present; not a repo checkout')
        with open(path, encoding='utf-8') as handle:
            src = handle.read()
        start = src.index('ExecutiveGetType(PyMOLGlobals* G, const char* name)\n{')
        body = src[start:src.index('\n}\n', start)]
        labels = tuple(re.findall(r'return "(object:[^"]*)";', body))
        self.assertEqual(labels, ai.OBJECT_KINDS)

    def testTheGateIsAnsweredForEVERYObjectKind(self):
        """Enumerated over the WHOLE of cmd.get_type's object vocabulary, not a
        hand-picked subset.

        The previous version listed six of the twelve labels and omitted
        `object:ramp` -- which is a GADGET, the one kind the peel walk
        structurally cannot reach, and therefore the one the predicate had
        wrong. The suite was green with the defect in it. The loop is driven
        from ai.OBJECT_KINDS, and testObjectKindsMatchExecutiveGetType ties
        that tuple to the C switch; together, a label added to
        ExecutiveGetType fails one of the two tests until it has a decision
        here. (Without that second test nothing would: a label missing from
        OBJECT_KINDS would simply fall to peel=True, which is the safe side,
        but silent.)

        Peel is not a material question: SceneCollectPeelObjects walks
        `NonGadgetObjs`, and MaterialObjectWantsPeel returns an explicit
        object-level value outright before it ever looks for an ObjectMolecule.
        So an isosurface at `transparency_peel 1` really is peeled -- and a
        translucent one's front/back double blend is exactly what peel is for.

        Asserted on the predicates rather than on live objects of each kind:
        several need geometry this headless build does not produce."""
        expected_peel = {
            'object:molecule': True,
            'object:map': True,
            'object:mesh': True,
            'object:slice': True,
            'object:surface': True,
            'object:measurement': True,
            'object:cgo': True,
            'object:volume': True,
            'object:alignment': True,
            'object:': True,
            'object:group': False,   # set reaches members, get does not
            'object:ramp': False,    # a gadget; the peel walk skips GadgetObjs
        }
        self.assertEqual(sorted(expected_peel), sorted(ai.OBJECT_KINDS))
        for kind in ai.OBJECT_KINDS:
            self.assertEqual(ai._takes_peel_row(kind), expected_peel[kind], kind)
        # A name the core cannot type at all gets no row.
        self.assertFalse(ai._takes_peel_row(''))

    def testARampGetsNoRowsAtAll(self):
        """The live version of the gadget case, since a ramp IS buildable
        headlessly. It reaches the panel -- get_names('public_objects')
        includes every named object regardless of type -- so without the gate
        its card renders a live Peel tri-state writing a setting no frame will
        ever consult."""
        cmd.pseudoatom('pa')
        cmd.map_new('mp', 'gaussian', 1.0, 'pa', 4)
        cmd.ramp_new('rmp', 'mp', [0, 1], ['blue', 'red'])
        self.assertEqual(cmd.get_type('rmp'), 'object:ramp')
        self.assertIn('rmp', cmd.get_names('public_objects'))
        m = meta('rmp', objs=['rmp'])
        self.assertEqual(m['peel_row'], 0)

    def testAGroupDoesNotGetIt(self):
        cmd.fragment('ala', 'm2')
        cmd.group('g1', 'm1 m2')
        m = meta('g1', objs=['g1'])
        self.assertEqual(m['peel_row'], 0)

    def testTheGroupAsymmetryIsRealAndNotJustCaution(self):
        """`set` reaches the members, `get` does not -- which is what would
        make every control on a group card write and then snap back."""
        cmd.fragment('ala', 'm2')
        cmd.group('g1', 'm1 m2')
        cmd.set('transparency_peel', 1, 'g1')
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'g1'), -1)


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


class TestCustomMaterial(testing.PyMOLTestCase):
    """The Custom material's Inspector half (#569), Python side: the knobs the
    MATKNOBS lines carry, the per-rep state the poll ships, and what commands
    of the form the Swift strings send (MaterialInspectorTests pins those
    strings; the line format is the join) do to the session."""
    KNOBS = ('reflect', 'tint', 'rough', 'knob1', 'knob2', 'knob3',
             'knob4', 'knob5', 'knob6')

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.hide('everything', 'm1')
        cmd.show('sticks', 'm1')

    def rep(self, name='sticks'):
        return [r for r in reps_payload('m1') if r['rep'] == name][0]

    def testEachMaterialsKnobsComeFromTheCore(self):
        from pymol import _cmd
        for mid, name in ai.material_names():
            self.assertEqual([k[0] for k in ai.material_knobs(mid)],
                             [k[0] for k in _cmd.get_material_knobs(mid)], name)
        by_name = {n: i for i, n in ai.material_names()}
        self.assertEqual(ai.material_knobs(by_name['default']), [])
        self.assertEqual([k[0] for k in ai.material_knobs(by_name['marble'])],
                         ['knob2', 'knob5', 'knob6'])

    def testEveryPolledLineFitsInOneFeedbackLine(self):
        """PyMOL splits feedback at ~1024 chars (OrthoLineLength), and a split
        line fails to parse on the Swift side -- which left every material
        menu disabled when the knobs rode on the MATERIALS line."""
        import io, contextlib, json
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ai.poll_materials()
        lines = buf.getvalue().splitlines()
        self.assertTrue(lines[0].startswith('MATERIALS:'))
        # names only: the knobs must not ride here, at any compactness -- the
        # table is ~70 chars from the cap even with compact separators
        for row in json.loads(lines[0][len('MATERIALS:'):]):
            self.assertEqual(len(row), 2, row)
        knob_lines = [l for l in lines if l.startswith('MATKNOBS:')]
        self.assertGreaterEqual(len(knob_lines), 9)
        for l in lines:
            self.assertLess(len(l), 1000, l[:60])
        mid, payload = knob_lines[0][len('MATKNOBS:'):].split(':', 1)
        self.assertEqual(json.loads(payload), ai.material_knobs(int(mid)))

    def testTheRepShipsWhatTheDrawUsesAndWhatIsOverridden(self):
        cmd.set('stick_material', 'metallic', 'm1')
        m = self.rep()['material']
        self.assertAlmostEqual(m['knobs']['reflect'], 0.6, places=4)
        self.assertEqual(m['custom'], [])
        cmd.set('stick_material_rough', 0.05, 'm1')
        m = self.rep()['material']
        self.assertAlmostEqual(m['knobs']['rough'], 0.05, places=4)
        self.assertEqual(m['custom'], ['rough'])

    def testAGlobalValueIsNotShownAsAnOverride(self):
        cmd.set('stick_material', 'metallic', 'm1')
        cmd.set('stick_material_rough', 0.9)          # global, not the object's
        self.assertEqual(self.rep()['material']['custom'], [])

    def testPickingANamedMaterialClearsTheOverrides(self):
        """What CustomMaterial.pick sends: set the material, and unset the
        overrides the payload reports in `set`. Re-picking a material that HAS
        the overridden knob is what shows the unset ran -- a material without
        it would hide a leftover anyway."""
        cmd.set('stick_material', 'metallic', 'm1')
        cmd.set('stick_material_rough', 0.05, 'm1')
        self.assertEqual(self.rep()['material']['set'], ['rough'])
        cmd.do('set stick_material, 2, m1\nunset stick_material_rough, m1')
        self.assertEqual(cmd.get('stick_material', 'm1'), 'plastic')
        m = self.rep()['material']
        self.assertEqual(m['custom'], [])
        self.assertEqual(m['set'], [])
        self.assertAlmostEqual(m['knobs']['rough'], 0.15, places=4)   # plastic's own

    def testAKnobCommandWritesTheLayersOverride(self):
        """What CustomMaterial.setKnob sends."""
        cmd.set('stick_material', 'marble', 'm1')
        cmd.do('set stick_material_knob5, 0.2500, m1')
        m = self.rep()['material']
        self.assertEqual(m['custom'], ['knob5'])
        self.assertAlmostEqual(m['knobs']['knob5'], 0.25, places=4)

    def testADegradedLayerDrawsDefaultAndOffersNoKnobs(self):
        """Glass on a ball-and-stick degrades to `default`: the layer draws
        material 0, so the Inspector must not offer Custom there."""
        cmd.set('stick_material', 'glass', 'm1')
        cmd.set('stick_ball', 1, 'm1')
        cmd.set('stick_material_rough', 0.5, 'm1')
        m = self.rep()['material']
        self.assertEqual(m['drawn'], 0)
        self.assertEqual(m['custom'], [])
        cmd.set('stick_ball', 0, 'm1')
        by_name = {n: i for i, n in setting.get_material_names(1)}
        self.assertEqual(self.rep()['material']['drawn'], by_name['glass'])

    def testALeftoverOverrideIsNotCustomButIsStillCleared(self):
        """An override the drawn material has no knob for is ignored by the
        core, so it must not make the row read Custom -- but it is still in
        `set`, what a pick or Reset unsets, or it would come back the next
        time a material with that knob is picked."""
        cmd.set('stick_material', 'metallic', 'm1')
        cmd.set('stick_material_rough', 0.05, 'm1')
        cmd.set('stick_material', 'marble', 'm1')     # marble has no rough
        m = self.rep()['material']
        self.assertEqual(m['custom'], [])
        self.assertEqual(m['set'], ['rough'])

    def testEachLayerReportsItsOwnOverrides(self):
        cmd.show('spheres', 'm1')
        cmd.set('sphere_material', 'metallic', 'm1')
        cmd.set('stick_material', 'metallic', 'm1')
        cmd.set('sphere_material_rough', 0.07, 'm1')
        spheres = self.rep('spheres')['material']
        self.assertEqual(spheres['custom'], ['rough'])
        self.assertAlmostEqual(spheres['knobs']['rough'], 0.07, places=4)
        self.assertEqual(self.rep('sticks')['material']['custom'], [])
