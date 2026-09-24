"""Per-representation material resolution (#485).

A draw resolves its material from the rep's OWN setting -- the object value
first, then that setting's global value, then `material_default`. The
representations that have no material in v1 (ribbon, mesh, dots, lines, labels)
stay `default` and `material_default` does not reach them.

`_cmd.get_rep_material(object_or_empty, rep_index)` is the same C function the
renderer calls on every lit draw, so these assertions test the shipped path and
not a Python re-implementation of it.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_resolution.py
"""
from pymol import cmd, testing
from pymol import _cmd
from pymol.constants import repres

# pymol.constants.repres is index-for-index the C `cRep_t` enum in layer1/Rep.h,
# whose comment reads "don't change these -- you'll break sessions".
CARTOON = repres['cartoon']      # cRepCartoon
SURFACE = repres['surface']      # cRepSurface
STICKS = repres['sticks']        # cRepCyl -- also the stick_ball spheres
SPHERES = repres['spheres']      # cRepSphere
RIBBON = repres['ribbon']
MESH = repres['mesh']
LINES = repres['lines']
DOTS = repres['dots']
LABELS = repres['labels']

MATERIAL_REPS = {
    CARTOON: 'cartoon_material',
    SURFACE: 'surface_material',
    STICKS: 'stick_material',
    SPHERES: 'sphere_material',
}
PLAIN_REPS = [RIBBON, MESH, LINES, DOTS, LABELS]

MARBLE, CLAY, METALLIC, GLASS = 7, 8, 3, 4


def resolve(rep, obj=''):
    return _cmd.get_rep_material(cmd._COb, obj, rep)


class TestMaterialResolution(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    def testDefaultsResolveToDefault(self):
        for rep in list(MATERIAL_REPS) + PLAIN_REPS:
            self.assertEqual(resolve(rep), 0, rep)
            self.assertEqual(resolve(rep, 'm1'), 0, rep)

    def testEachRepReadsItsOwnSetting(self):
        for rep, name in MATERIAL_REPS.items():
            cmd.reinitialize()
            cmd.fragment('ala', 'm1')
            cmd.set(name, MARBLE)
            for other, othername in MATERIAL_REPS.items():
                want = MARBLE if other == rep else 0
                self.assertEqual(resolve(other, 'm1'), want,
                                 '%s set, %s read' % (name, othername))

    def testPerObjectOverrideBeatsTheRepGlobal(self):
        cmd.set('cartoon_material', MARBLE)              # global
        cmd.set('cartoon_material', METALLIC, 'm1')      # object
        self.assertEqual(resolve(CARTOON, 'm1'), METALLIC)
        self.assertEqual(resolve(CARTOON, 'm2'), MARBLE)
        self.assertEqual(resolve(CARTOON), MARBLE)

    def testAnExplicitObjectDefaultBeatsTheRepGlobal(self):
        """Setting a material back to `default` on one object is how a user opts
        that object out of a global material; it must not fall through to the
        global again."""
        cmd.set('cartoon_material', MARBLE)
        cmd.set('cartoon_material', 0, 'm1')
        self.assertEqual(resolve(CARTOON, 'm1'), 0)
        self.assertEqual(resolve(CARTOON, 'm2'), MARBLE)

    def testRepGlobalBeatsMaterialDefault(self):
        cmd.set('material_default', CLAY)
        cmd.set('cartoon_material', MARBLE)
        self.assertEqual(resolve(CARTOON, 'm1'), MARBLE)
        # ...and a rep with no setting of its own still gets material_default.
        self.assertEqual(resolve(SURFACE, 'm1'), CLAY)

    def testMaterialDefaultIsTheLastFallback(self):
        cmd.set('material_default', CLAY)
        for rep in MATERIAL_REPS:
            self.assertEqual(resolve(rep, 'm1'), CLAY, rep)
            self.assertEqual(resolve(rep), CLAY, rep)

    def testObjectOverrideBeatsMaterialDefault(self):
        cmd.set('material_default', CLAY)
        cmd.set('sphere_material', GLASS, 'm1')
        self.assertEqual(resolve(SPHERES, 'm1'), GLASS)
        self.assertEqual(resolve(SPHERES, 'm2'), CLAY)

    def testRepsWithoutAMaterialStayDefault(self):
        """Ribbon, mesh, dots, lines and labels keep default shading in v1, and
        material_default must not reach them."""
        cmd.set('material_default', CLAY)
        for name in MATERIAL_REPS.values():
            cmd.set(name, MARBLE)
        for rep in PLAIN_REPS:
            self.assertEqual(resolve(rep, 'm1'), 0, rep)
            self.assertEqual(resolve(rep), 0, rep)

    def testUnsetFallsBackAgain(self):
        cmd.set('cartoon_material', MARBLE)
        cmd.set('cartoon_material', METALLIC, 'm1')
        self.assertEqual(resolve(CARTOON, 'm1'), METALLIC)
        cmd.unset('cartoon_material', 'm1')
        self.assertEqual(resolve(CARTOON, 'm1'), MARBLE)

    def testAnIdWithNoRowIsCarriedThroughUnchanged(self):
        """Out-of-range ints are not clamped at set time; they resolve to
        `default` in the renderer, not by being rewritten here."""
        cmd.set('cartoon_material', 99, 'm1')
        self.assertEqual(resolve(CARTOON, 'm1'), 99)

    def testUnknownObjectIsAnError(self):
        self.assertIsNone(_cmd.get_rep_material(cmd._COb, 'no_such_object', CARTOON))

    def testUnknownRepResolvesToDefault(self):
        cmd.set('material_default', CLAY)
        self.assertEqual(resolve(-1, 'm1'), 0)
        self.assertEqual(resolve(999, 'm1'), 0)
