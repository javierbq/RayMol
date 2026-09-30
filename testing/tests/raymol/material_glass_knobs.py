"""Glass's Reflection and Distortion, and jelly's Distortion (#590).

Clear and frosted glass get two Custom knobs, Reflection (p[0]: the Fresnel
rim and the glints) and Distortion (p[1]: the refraction of #588); jelly gets
Distortion (p[3]). All three are 1 in the material table, and the Inspector
shows them as on/off toggles -- the fifth field of `_cmd.get_material_knobs`
-- while the value stays an amount the shader scales by.

Asserted on the FINAL draw params (`get_material_draw_params`), what the
shader is handed. What the renderer does with them is render-verified: the
Metal renderer is not reachable from these tests.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_glass_knobs.py
"""
from pymol import _cmd, cmd, setting, testing
from pymol.constants import repres


def material_id(name):
    return {n: i for i, n in setting.get_material_names(1)}[name]


def knob_rows(name):
    return {row[0]: row for row in _cmd.get_material_knobs(material_id(name))}


def p(obj, rep='surface'):
    return tuple(_cmd.get_material_draw_params(cmd._COb, obj, repres[rep])[5])


class TestTheKnobs(testing.PyMOLTestCase):

    def testGlassHasReflectionAndDistortionToggles(self):
        for name, rough in (('glass', 'Roughness'), ('frosted_glass', 'Frost')):
            rows = _cmd.get_material_knobs(material_id(name))
            self.assertEqual([(r[0], r[1], r[4]) for r in rows],
                             [('knob1', 'Reflection', 'toggle'),
                              ('knob2', 'Distortion', 'toggle'),
                              ('rough', rough, 'slider')], name)

    def testJellyHasADistortionToggle(self):
        rows = knob_rows('jelly')
        self.assertEqual(rows['knob4'][1:], ('Distortion', 0.0, 1.0, 'toggle'))
        for k in ('rough', 'knob1', 'knob2', 'knob3'):
            self.assertEqual(rows[k][4], 'slider', k)

    def testTogglesRunFromOffToOn(self):
        """min is off and max is on: the Inspector writes one or the other."""
        for mid, name in setting.get_material_names(1):
            for row in _cmd.get_material_knobs(mid):
                if row[4] == 'toggle':
                    self.assertEqual(row[2:4], (0.0, 1.0), (name, row[0]))

    def testOnlyTheNewKnobsAreToggles(self):
        toggles = sorted((name, row[0])
                         for mid, name in setting.get_material_names(1)
                         for row in _cmd.get_material_knobs(mid)
                         if row[4] == 'toggle')
        self.assertEqual(toggles, [('frosted_glass', 'knob1'),
                                   ('frosted_glass', 'knob2'),
                                   ('glass', 'knob1'), ('glass', 'knob2'),
                                   ('jelly', 'knob4')])


class TestTheDraw(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')

    def testEverythingStartsOn(self):
        for name in ('glass', 'frosted_glass'):
            cmd.set('surface_material', name, 'm1')
            self.assertEqual(p('m1')[:2], (1.0, 1.0), name)
        cmd.set('surface_material', 'jelly', 'm1')
        self.assertEqual(p('m1')[3], 1.0)

    def testTurningOneOffReachesTheDrawAndNothingElse(self):
        cmd.set('surface_material', 'glass', 'm1')
        base = p('m1')
        cmd.set('surface_material_knob2', 0.0, 'm1')        # Distortion off
        self.assertEqual(p('m1'), (base[0], 0.0) + base[2:])
        cmd.set('surface_material_knob1', 0.0, 'm1')        # Reflection off
        self.assertEqual(p('m1'), (0.0, 0.0) + base[2:])

    def testJellysDistortionIsItsOwnSlot(self):
        cmd.set('surface_material', 'jelly', 'm1')
        base = p('m1')
        cmd.set('surface_material_knob4', 0.0, 'm1')
        self.assertEqual(p('m1'), base[:3] + (0.0,) + base[4:])

    def testAnAmountBetweenIsKept(self):
        """The value is an amount: the command line can halve the distortion."""
        cmd.set('surface_material', 'glass', 'm1')
        cmd.set('surface_material_knob2', 0.5, 'm1')
        self.assertAlmostEqual(p('m1')[1], 0.5, places=6)

    def testOneLayerOnly(self):
        cmd.set('surface_material', 'glass', 'm1')
        cmd.set('cartoon_material', 'glass', 'm1')
        cmd.set('surface_material_knob2', 0.0, 'm1')
        self.assertEqual(p('m1', 'cartoon')[1], 1.0)


class TestTheInspector(testing.PyMOLTestCase):

    def testTheInspectorShipsTheControl(self):
        from pymol import appkit_inspector as ai
        rows = ai.material_knobs(material_id('glass'))
        self.assertEqual([r[4] for r in rows], ['toggle', 'toggle', 'slider'])
        for mid, _name in ai.material_names():
            self.assertEqual(ai.material_knobs(mid),
                             [list(r) for r in _cmd.get_material_knobs(mid)])
