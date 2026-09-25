"""Per-object transparent depth peel (#488).

Without peeling, every transparent fragment of an object accumulates -- the
front and back of every stick, and every stick behind it -- so a translucent
ball-and-stick reads as dense mottle rather than one glassy shell. With it, a
colour-less depth pre-pass records the object's nearest surface and the
object's transparent draws are tested for equality against it.

`transparency_peel` is a TRI-STATE: 1 on, 0 off, -1 (the default) auto -- on
when any of the object's four representations resolves to a material whose row
asks for it. No material asks today (it is a glass-family flag and glass lands
in #495), so auto is off for everything, which is exactly why these tests pin
the RESOLUTION rather than the raw setting: the setting alone says nothing
about what the renderer will do.

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/transparency_peel.py
"""
import pymol
from pymol import cmd, testing


def resolved_peel(obj, state=0):
    """Whether the renderer would peel `obj` -- the same call the scene loop
    makes, not the setting value."""
    return pymol._cmd.get_object_peel(cmd._COb, obj, state)


class TestTransparencyPeel(testing.PyMOLTestCase):
    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')

    # -- the setting itself ---------------------------------------------------

    def testTheDefaultIsAutoNotOff(self):
        """-1, not 0. An object that has never been touched must be able to
        follow its material; baking 0 in would make the glass materials inert
        for every object that existed before the user heard of peeling."""
        self.assertEqual(cmd.get_setting_int('transparency_peel'), -1)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), -1)

    def testItIsObjectScopedAndRoundTrips(self):
        cmd.set('transparency_peel', 1, 'm1')
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)
        # ...and the object beside it is untouched, which is the whole point of
        # an object-scoped setting.
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm2'), -1)

    def testASelectionScopedSetIsRefused(self):
        """It is an int the draw path reads per OBJECT; the generic selection
        path would write an atom-level value nothing reads and report success."""
        with self.assertRaises(pymol.CmdException):
            cmd.set('transparency_peel', 1, 'm1 and name CA')

    def testItSurvivesAPse(self):
        cmd.set('transparency_peel', 1, 'm1')
        cmd.set('transparency_peel', 0, 'm2')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            cmd.load(fn)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), 1)
        self.assertEqual(cmd.get_setting_int('transparency_peel', 'm2'), 0)

    # -- what the renderer actually does --------------------------------------

    def testAutoIsOffWhileNoMaterialAsksForIt(self):
        """Every material implemented today has wantsPeel = 0, so nothing peels
        unless the user says so. This is what makes `default` render exactly as
        it did before #488."""
        for obj in ('m1', 'm2'):
            self.assertEqual(resolved_peel(obj), 0, obj)

    def testAutoStaysOffForAPlainTransparentObject(self):
        """Deliberately NOT "any transparent object": peeling a plain
        translucent surface changes a look users already rely on, and it costs a
        depth blit and two encoder boundaries per object per grid cell."""
        cmd.show('surface', 'm1')
        cmd.set('transparency', 0.5, 'm1')
        self.assertEqual(resolved_peel('m1'), 0)

    def testAnExplicitOnWins(self):
        cmd.set('transparency_peel', 1, 'm1')
        self.assertEqual(resolved_peel('m1'), 1)
        self.assertEqual(resolved_peel('m2'), 0)

    def testAnExplicitOffWinsOverEverything(self):
        """0 is not "unset". It has to beat the auto rule, or a user could never
        turn peeling off for one glass object."""
        cmd.set('transparency_peel', 0, 'm1')
        self.assertEqual(resolved_peel('m1'), 0)

    def testTheGlobalAppliesToObjectsWithNoValueOfTheirOwn(self):
        cmd.set('transparency_peel', 1)
        self.assertEqual(resolved_peel('m1'), 1)
        self.assertEqual(resolved_peel('m2'), 1)
        cmd.set('transparency_peel', 0, 'm2')   # one object opts out
        self.assertEqual(resolved_peel('m1'), 1)
        self.assertEqual(resolved_peel('m2'), 0)

    def testAMaterialDoesNotTurnPeelingOn(self):
        """Setting a material writes no other setting, and none of the four
        implemented ones asks to be peeled."""
        for name in ('matte', 'marble', 'clay', 'rubber'):
            cmd.set('cartoon_material', name, 'm1')
            self.assertEqual(cmd.get_setting_int('transparency_peel', 'm1'), -1,
                             name)
            self.assertEqual(resolved_peel('m1'), 0, name)

    def testAnUnknownObjectIsAnError(self):
        self.assertIsNone(resolved_peel('no_such_object'))
