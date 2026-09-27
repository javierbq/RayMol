"""get_material_draw_params answers from the BUILT rep when it can (#530).

The Inspector polls `_cmd.get_material_draw_params` about twice a second. For a
glass-family stick rep the family depends on whether any atom draws a
`stick_ball` sphere, and answering that from the settings is a walk over every
atom. The draw path never does that walk per frame: it reads the answer the
rep cached when it was built (Rep::emitsStickBalls). The accessor now does the
same -- but ONLY for a rep that is built, valid and shown, because only then is
the cached answer the one the next frame will draw with:

  * an INVALIDATED rep (stick_ball just changed on some atoms) still holds the
    answer for the old settings until the next frame rebuilds it;
  * a HIDDEN rep holds the answer for atoms it no longer draws. (Hiding also
    invalidates the rep today, so this case is caught by the same check; the
    accessor's separate Active[] test is defensive and not observable here.)

Those, and a rep not built yet, fall back to the scan. So the two paths agree
in every state, which is what these tests pin. (That the cached path is taken
at all is a performance property; it is measured on #501, not asserted here.)

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/material_draw_params_cache.py
"""
from pymol import _cmd, cmd, testing
from pymol.constants import repres

GLASS = 3
DEFAULT = 0


def family(obj='m'):
    return _cmd.get_material_draw_params(cmd._COb, obj, repres['sticks'])[0]


class TestDrawParamsFromTheBuiltRep(testing.PyMOLTestCase):

    def setUp(self):
        super().setUp()
        cmd.reinitialize()
        cmd.fragment('trp', 'm')
        cmd.hide('everything')
        cmd.show('sticks', 'm')
        cmd.set('stick_material', 'glass', 'm')
        cmd.set('stick_ball', 0)

    def build(self):
        cmd.rebuild('m')
        cmd.refresh()

    def testNotBuiltYetScans(self):
        self.assertEqual(family(), GLASS)
        cmd.set('stick_ball', 1, 'm and name CA')
        self.assertEqual(family(), DEFAULT)

    def testBuiltAndValidAgreesWithTheBuild(self):
        self.build()
        self.assertEqual(family(), GLASS)
        cmd.set('stick_ball', 1, 'm')
        self.build()
        self.assertEqual(family(), DEFAULT)

    def testAnInvalidatedRepIsNotTrusted(self):
        # Built with no balls; then one atom gets a ball. The rep still says
        # "no balls" until the next frame rebuilds it -- the accessor must not
        # report glass for a rep the next frame will degrade to default.
        self.build()
        self.assertEqual(family(), GLASS)
        cmd.set('stick_ball', 1, 'm and name CA')
        self.assertEqual(family(), DEFAULT)

    def testAHiddenRepIsNotTrusted(self):
        # Built WITH a ball on CA, then the sticks are hidden: the hidden rep
        # still says "balls", but no atom draws one any more.
        cmd.set('stick_ball', 1, 'm and name CA')
        self.build()
        self.assertEqual(family(), DEFAULT)
        cmd.hide('sticks', 'm')
        self.assertEqual(family(), GLASS)
        # ...and still after a frame and a rebuild.
        cmd.refresh()
        self.assertEqual(family(), GLASS)
        cmd.rebuild('m')
        cmd.refresh()
        self.assertEqual(family(), GLASS)
