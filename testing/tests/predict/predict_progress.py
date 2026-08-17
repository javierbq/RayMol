import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from pymol import testing


BANDS = (
    ('featurize', 0.00, 0.03),
    ('load',      0.03, 0.10),
    ('inference', 0.10, 0.10),
    ('diffusion', 0.40, 0.97),
    ('done',      1.00, 1.00),
)


class TestComposeProgress(testing.PyMOLTestCase):

    def compose(self, phase, fraction):
        from pymol.predictors.base import compose_progress
        return compose_progress({'phase': phase, 'fraction': fraction}, BANDS)

    def testAWidebandMapsTheLocalFractionIntoIt(self):
        # 0.40 + 0.42 * (0.97 - 0.40) = 0.6394
        fraction, moving = self.compose('diffusion', 0.42)
        self.assertAlmostEqual(fraction, 0.6394, places=4)
        self.assertTrue(moving)

    def testAZeroSpanBandReturnsTheFloorAndIsNotMoving(self):
        """'started, cannot say how far in' -- the UI must draw a spinner."""
        fraction, moving = self.compose('inference', 0.9)
        self.assertAlmostEqual(fraction, 0.10)
        self.assertFalse(moving)

    def testAnUnknownPhaseSaysNothingRatherThanZero(self):
        """None never means zero: 'queued' must not slam the bar back to 0%."""
        self.assertEqual(self.compose('queued', 0.0), (None, False))
        self.assertEqual(self.compose('download', 0.5), (None, False))

    def testAFractionOutsideTheUnitRangeIsClamped(self):
        self.assertAlmostEqual(self.compose('diffusion', 2.0)[0], 0.97)
        self.assertAlmostEqual(self.compose('diffusion', -1.0)[0], 0.40)

    def testMalformedStatusNeverRaises(self):
        """It runs on a 500 ms main-thread poll; a throw freezes the object panel."""
        from pymol.predictors.base import compose_progress
        for status in ({}, {'phase': 'diffusion'},
                       {'phase': 'diffusion', 'fraction': 'x'},
                       {'phase': 'diffusion', 'fraction': None},
                       {'phase': None, 'fraction': 0.5}):
            self.assertEqual(compose_progress(status, BANDS), (None, False))

    def testAnEmptyBandTableAlwaysSaysNothing(self):
        from pymol.predictors.base import compose_progress
        self.assertEqual(
            compose_progress({'phase': 'diffusion', 'fraction': 0.5}, ()),
            (None, False))
