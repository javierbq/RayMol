"""Layer Looks (pymol.looks): one-click starting points for ONE layer.

A Look sets a layer's material, that material's Custom knobs (#568) and the
atom colour of the layer's atoms -- and nothing else. The Looks removed in #566
rewrote all four layers and the scene's lighting, so a look stuck after the
material changed; these pin that the new ones touch one layer's material of one
object, write no global setting, and are undone the ordinary way. How the
colour lands on atoms is pinned in material_follow.py.

    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_looks.py
"""
import json

import pymol
from pymol import _cmd, cmd, setting, testing
from pymol import looks
from pymol.constants import repres

REP_INDEX = {'cartoon': repres['cartoon'], 'surface': repres['surface'],
             'stick': repres['sticks'], 'sphere': repres['spheres']}


def params(obj, layer):
    f, m, r, t, ro, p = _cmd.get_material_draw_params(cmd._COb, obj, REP_INDEX[layer])
    return f, m, r, t, ro, tuple(p)


def atom_colours(sele):
    out = set()
    cmd.iterate(sele, 'out.add(color)', space={'out': out})
    return out


def global_settings():
    out = {}
    for name in setting.get_name_list():
        try:
            out[name] = cmd.get(name)
        except Exception:
            pass
    return out


class TestLooks(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        cmd.show('sticks')

    def testEveryLookUsesAnImplementedMaterialAndOnlyItsKnobs(self):
        """A knob the material does not have would be silently ignored by the
        core -- a Look promising a change it cannot make."""
        by_name = {n: i for i, n in setting.get_material_names(1)}
        for name, label, material, colour, knobs in looks.LOOKS:
            self.assertIn(material, by_name, name)
            has = {row[0] for row in _cmd.get_material_knobs(by_name[material])}
            self.assertTrue(set(knobs) <= has, '%s: %s' % (name, set(knobs) - has))
            self.assertTrue(label)
            self.assertTrue(0 <= colour <= 0xffffff)

    def testALookSetsOneLayersMaterialKnobsAndColour(self):
        cmd.apply_look('gold', 'm1', 'stick')
        self.assertEqual(cmd.get('stick_material', 'm1'), 'metallic')
        _f, _m, r, t, ro, _p = params('m1', 'stick')
        self.assertAlmostEqual(r, 0.60, places=4)
        self.assertAlmostEqual(t, 0.88, places=4)
        self.assertAlmostEqual(ro, 0.05, places=4)
        # the atoms, not the layer: a layer colour would hide "by element"
        self.assertEqual(atom_colours('m1'), {cmd.get_color_index('look_gold')})
        self.assertEqual(cmd.get('stick_color', 'm1'), 'default')
        self.assertEqual([round(c * 255) for c in cmd.get_color_tuple('look_gold')],
                         [0xd4, 0xaf, 0x37])

    def testNothingElseChanges(self):
        """No other layer, no other object, no global setting -- the old Looks
        changed the scene's lighting for everything on screen."""
        before = global_settings()
        colours_before = {n for n, _i in cmd.get_color_indices()}
        other_layers = [params('m1', l) for l in ('cartoon', 'surface', 'sphere')]
        other_object = params('m2', 'stick')
        other_colours = atom_colours('m2')
        cmd.apply_look('chrome', 'm1', 'stick')
        self.assertEqual(global_settings(), before)
        # the one thing outside the layer: the Look's named colour
        self.assertEqual({n for n, _i in cmd.get_color_indices()} - colours_before,
                         {'look_chrome'})
        self.assertEqual([params('m1', l) for l in ('cartoon', 'surface', 'sphere')],
                         other_layers)
        self.assertEqual(params('m2', 'stick'), other_object)
        self.assertEqual(atom_colours('m2'), other_colours)
        for l in ('cartoon', 'surface', 'sphere'):
            self.assertEqual(cmd.get('%s_material' % l, 'm1'), 'default', l)

    def testEveryLookLeavesTheLayerCustom(self):
        """Each Look sets at least one knob, so the layer reads "Custom (...)"
        and Reset undoes it -- the same for every Look."""
        for name, _l, _m, _c, knobs in looks.LOOKS:
            self.assertTrue(knobs, name)

    def testALookReplacesTheLastOnesKnobs(self):
        """Chrome sets reflect; copper does not -- chrome's must not survive."""
        cmd.apply_look('chrome', 'm1', 'surface')
        cmd.apply_look('copper', 'm1', 'surface')
        _f, _m, r, t, ro, _p = params('m1', 'surface')
        self.assertAlmostEqual(r, 0.6, places=4)     # metallic's own, not chrome's 0.75
        self.assertAlmostEqual(t, 0.55, places=4)
        self.assertAlmostEqual(ro, 0.30, places=4)

    def testItIsUndoneByPickingAMaterial(self):
        """What the Inspector sends for a pick: the material, and unset the
        layer's overrides. The colour is the atoms' now; any colouring
        replaces it."""
        cmd.apply_look('copper', 'm1', 'surface')
        cmd.do('set surface_material, 3, m1\n' + '\n'.join(
            'unset surface_material_%s, m1' % k for k in looks.KNOBS))
        self.assertAlmostEqual(params('m1', 'surface')[3], 0.35, places=4)  # metallic's tint
        cmd.color('red', 'm1')
        self.assertEqual(atom_colours('m1'), {cmd.get_color_index('red')})

    def testTheCommandTheInspectorSendsWorks(self):
        """CustomMaterial.applyLook's form: apply_look <name>, <object>, <stem>."""
        cmd.do('apply_look statuary, m1, sphere')
        self.assertEqual(cmd.get('sphere_material', 'm1'), 'marble')
        self.assertEqual(atom_colours('m1'), {cmd.get_color_index('look_statuary')})

    def testLayerNamesAreForgiving(self):
        cmd.apply_look('bronze', 'm1', 'sticks')
        self.assertEqual(cmd.get('stick_material', 'm1'), 'metallic')
        cmd.apply_look('terracotta', 'm1', 'surface_material')
        self.assertEqual(cmd.get('surface_material', 'm1'), 'clay')

    def testUnknownLookLayerOrObjectIsAnError(self):
        with self.assertRaisesRegex(pymol.CmdException, 'unknown look'):
            cmd.apply_look('platinum', 'm1', 'stick')
        with self.assertRaisesRegex(pymol.CmdException, 'unknown layer'):
            cmd.apply_look('gold', 'm1', 'ribbon')
        with self.assertRaisesRegex(pymol.CmdException, 'no object'):
            cmd.apply_look('gold', 'nope', 'stick')

    def testTheInspectorLineFitsAndCarriesEveryLook(self):
        import io, contextlib
        from pymol import appkit_inspector as ai
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ai.poll_materials()
        lines = [l for l in buf.getvalue().splitlines() if l.startswith('LOOKS:')]
        self.assertEqual(len(lines), 1)
        self.assertLess(len(lines[0]), 1000)
        rows = json.loads(lines[0][len('LOOKS:'):])
        self.assertEqual([r[0] for r in rows], [row[0] for row in looks.LOOKS])
