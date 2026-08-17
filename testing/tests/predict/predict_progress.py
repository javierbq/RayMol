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


class TestPredictorProgress(testing.PyMOLTestCase):

    def testTheBaseClassDeclaresNoPhases(self):
        """Phase names belong to a backend, not the infrastructure. A predictor
        that says nothing must get a spinner, never another backend's bar."""
        from pymol.predictors.base import Predictor
        self.assertEqual(Predictor.progress_phases, ())

    def testProgressIsConcreteSoExistingPredictorsStillInstantiate(self):
        from pymol.predictors.base import Predictor
        self.assertNotIn('progress', Predictor.__abstractmethods__)
        self.assertEqual(sorted(Predictor.__abstractmethods__),
                         ['check_available', 'parse_spec', 'submit'])

    def testBoltz2DeclaresItsOwnPipeline(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        names = [p[0] for p in Boltz2Predictor.progress_phases]
        self.assertEqual(names, ['featurize', 'load', 'inference',
                                 'trunk', 'diffusion', 'write', 'done'])

    def testBoltz2InferenceIsZeroSpanUntilTheUpstreamPatchLands(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        fraction, moving = Boltz2Predictor().progress(
            {'phase': 'inference', 'fraction': 0.5})
        self.assertFalse(moving)
        self.assertAlmostEqual(fraction, 0.10)

    def testBoltz2DiffusionIsDeterminate(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        fraction, moving = Boltz2Predictor().progress(
            {'phase': 'diffusion', 'fraction': 0.5})
        self.assertTrue(moving)
        self.assertGreater(fraction, 0.40)
        self.assertLess(fraction, 0.97)

    def testBandsAreOrderedAndWithinTheUnitRange(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        for name, start, end in Boltz2Predictor.progress_phases:
            self.assertLessEqual(start, end, name)
            self.assertGreaterEqual(start, 0.0, name)
            self.assertLessEqual(end, 1.0, name)

    def testTheTemplateDeclaresPhasesSoACopyInheritsABar(self):
        from pymol.predictors import _template
        self.assertTrue(_template.TemplatePredictor.progress_phases)
