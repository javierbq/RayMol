"""Tests for pymol.predictors.base and .errors.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_base.py
"""
from pymol import testing


class TestErrors(testing.PyMOLTestCase):

    def testAllErrorsAreCmdExceptions(self):
        import pymol
        from pymol.predictors import errors
        names = ('PredictorNotFound', 'PredictorUnavailable', 'PredictionInputError',
                 'PredictionOptionError', 'WeightDownloadFailed', 'WeightChecksumMismatch',
                 'WeightBundleLayoutError', 'WeightCacheUnwritable')
        for name in names:
            cls = getattr(errors, name)
            self.assertTrue(issubclass(cls, errors.PredictionError), name)
            self.assertTrue(issubclass(cls, pymol.CmdException), name)


class TestParseChains(testing.PyMOLTestCase):

    def testSingleChainGetsIdA(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains('MKTAY'), (('A', 'MKTAY'),))

    def testSlashSeparatesChains(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains('MKTAY/GSHMA'),
                         (('A', 'MKTAY'), ('B', 'GSHMA')))

    def testWhitespaceAndCaseAreNormalised(self):
        from pymol.predictors.base import parse_chains
        self.assertEqual(parse_chains(' mkt ay / gsh '),
                         (('A', 'MKTAY'), ('B', 'GSH')))

    def testEmptySequenceRejected(self):
        from pymol.predictors.base import parse_chains
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, parse_chains, '')
        self.assertRaises(PredictionInputError, parse_chains, 'MKT//GSH')

    def testTooManyChainsRejected(self):
        from pymol.predictors.base import parse_chains
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, parse_chains, '/'.join(['MK'] * 27))


class TestPredictionOptions(testing.PyMOLTestCase):

    def testDefaultsMatchUpstreamBoltz(self):
        from pymol.predictors.base import PredictionOptions
        opts = PredictionOptions()
        self.assertEqual(opts.recycling_steps, 3)
        self.assertEqual(opts.diffusion_steps, 200)
        self.assertEqual(opts.seed, 0)

    def testNonPositiveStepsRejected(self):
        from pymol.predictors.base import PredictionOptions
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError, PredictionOptions, diffusion_steps=0)
        self.assertRaises(PredictionOptionError, PredictionOptions, recycling_steps=-1)
