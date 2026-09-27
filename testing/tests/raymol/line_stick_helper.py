"""`line_stick_helper` keeps the lines under TRANSLUCENT sticks only (#527).

The helper suppresses the lines under a stick, where they are hidden anyway.
Under a see-through stick they are not hidden, and suppressing them leaves
nothing to see, so the lines build turns the helper off for a translucent stick
(#495 extended that to a stick a MATERIAL makes translucent, e.g. glass).

"Translucent" used to mean any transparency above R_SMALL4, so an 85%-opaque
stick -- `stick_transparency 0.15`, or jelly's implied 0.15 -- kept a faint
wireframe down the middle of every bond. It now means MORE than half
transparent.

Asserted on what the lines BUILD decided (`get_built_line_stick_helper`), not
on the setting. When the helper stays on and every line is under a stick,
RepWireBondNew emits no geometry and discards the rep, so the accessor raises
"not built"; when the helper is turned off, the rep is built and records 0.
A per-bond `stick_transparency` decides its own bond, as it decides how that
bond's stick is drawn; the recorded value is the object-level decision.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/line_stick_helper.py
"""
from pymol import _cmd, cmd, testing


def built_line_stick_helper(obj):
    return _cmd.get_built_line_stick_helper(cmd._COb, obj)


class TestLineStickHelperThreshold(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.show('lines', 'm1')
        cmd.show('sticks', 'm1')
        # a precondition, not a test: every difference below is the build's
        # decision, not the user's
        self.assertEqual(cmd.get_setting_boolean('line_stick_helper', 'm1'), 1)

    def build(self):
        cmd.rebuild('m1')
        cmd.refresh()

    def assertLinesSuppressed(self):
        self.build()
        # Matched on the message: a bare assertRaises would also pass on "no
        # such molecular object", i.e. report the rule verified on a typo.
        with self.assertRaisesRegex(Exception, 'not built'):
            built_line_stick_helper('m1')

    def assertLinesKept(self):
        self.build()
        try:
            helper = built_line_stick_helper('m1')
        except Exception as exc:
            self.fail('the lines rep was discarded, i.e. every line under a '
                      'translucent stick was suppressed: %s' % exc)
        self.assertEqual(helper, 0)

    def testOpaqueSticksSuppressTheirLines(self):
        self.assertLinesSuppressed()

    def testAMostlyOpaqueStickSuppressesItsLinesToo(self):
        # the #527 case: 0.15 used to keep them
        cmd.set('stick_transparency', 0.15, 'm1')
        self.assertLinesSuppressed()

    def testHalfTransparentIsNotYetTranslucent(self):
        # the boundary: "more than half", per bond...
        cmd.set('stick_transparency', 0.5, 'm1')
        self.assertLinesSuppressed()
        # ...and for the object, which is what the rep records. One bond at
        # 0.9 keeps its line, so the rep is built and has a value to read.
        cmd.set_bond('stick_transparency', 0.9, 'm1 and name CA',
                     'm1 and name CB')
        self.build()
        self.assertEqual(built_line_stick_helper('m1'), 1)

    def testAMostlyTransparentStickKeepsItsLines(self):
        cmd.set('stick_transparency', 0.6, 'm1')
        self.assertLinesKept()

    def testGlassSticksKeepTheirLines(self):
        # translucent without writing stick_transparency: through the material
        # (#495). Glass implies 0.85.
        cmd.set('stick_material', 'glass', 'm1')
        self.assertEqual(cmd.get_setting_float('stick_transparency', 'm1'), 0.0)
        self.assertLinesKept()

    def testJellySticksSuppressTheirLines(self):
        # jelly implies 0.15: a dense gummy, not a see-through stick
        cmd.set('stick_material', 'jelly', 'm1')
        self.assertLinesSuppressed()

    def testChangingTheSliderRebuildsTheLines(self):
        # the decision must follow the slider without an explicit rebuild of
        # the lines rep, or a session keeps whatever the first build decided
        cmd.refresh()
        cmd.set('stick_transparency', 0.8, 'm1')
        cmd.refresh()
        try:
            helper = built_line_stick_helper('m1')
        except Exception as exc:
            self.fail('the lines rep kept its opaque-stick decision after '
                      'stick_transparency changed: %s' % exc)
        self.assertEqual(helper, 0)
        cmd.set('stick_transparency', 0.2, 'm1')
        cmd.refresh()
        with self.assertRaisesRegex(Exception, 'not built'):
            built_line_stick_helper('m1')

    def testAPerBondValueDecidesItsOwnBond(self):
        # stick_transparency is a bond setting too, and the sticks are drawn
        # at the bond's value: see-through bonds on an object whose own value
        # is below the threshold keep their lines...
        cmd.set('stick_transparency', 0.3, 'm1')
        cmd.set_bond('stick_transparency', 0.9, 'm1')
        self.build()
        try:
            helper = built_line_stick_helper('m1')
        except Exception as exc:
            self.fail('lines suppressed under 90%%-transparent bonds: %s' % exc)
        # the recorded value is the OBJECT's decision: 0.3 is not translucent
        self.assertEqual(helper, 1)
        # ...and mostly opaque bonds on a see-through object lose theirs
        cmd.set('stick_transparency', 0.9, 'm1')
        cmd.set_bond('stick_transparency', 0.1, 'm1')
        self.assertLinesSuppressed()

    def testALineMeetingAStickKeepsItOnATranslucentObject(self):
        """One atom shows only lines, its neighbour only sticks: the helper
        draws the connecting line, and no stick is drawn for that bond, so its
        transparency cannot matter. It used to follow the translucency
        decision, leaving such a bond blank (no line, no stick) at 0.9.

        Isolated so "the lines rep was built" means exactly "that line was
        drawn". The lines build bails out unless some bond shows lines on both
        atoms, so a second molecule in the object shows lines AND sticks on
        every atom, with every bond at stick_transparency 0 -- suppressed per
        bond, contributing no lines. In `ala`, CA shows only lines and every
        other atom only sticks: CA's bonds are the only lines that can exist."""
        cmd.fragment('gly', 'g')
        cmd.create('m1', 'm1 or g')
        cmd.delete('g')
        cmd.alter('m1 and resn GLY', 'segi="G"')
        cmd.set('stick_transparency', 0.9, 'm1')
        cmd.hide('everything', 'm1')
        cmd.show('lines', 'm1 and segi G')
        cmd.show('sticks', 'm1 and segi G')
        cmd.set_bond('stick_transparency', 0.0, 'm1 and segi G')
        cmd.show('lines', 'm1 and resn ALA and name CA')
        cmd.show('sticks', 'm1 and resn ALA and not name CA')
        self.build()
        try:
            helper = built_line_stick_helper('m1')
        except Exception as exc:
            self.fail('the line from CA to its stick-only neighbours was not '
                      'drawn on a 90%%-transparent object: %s' % exc)
        self.assertEqual(helper, 0)   # the object IS translucent
        # ...and the control: hide CA's lines and nothing is left to draw
        cmd.hide('lines', 'm1 and resn ALA')
        self.assertLinesSuppressed()
