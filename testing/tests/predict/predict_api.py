"""End-to-end flow through cmd.predict with a stub predictor. No Swift, no network.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_api.py
"""
import os
import sys
from unittest.mock import patch

from pymol import cmd, testing

# The runner imports test files by path (testing.py:48) and never puts their
# directory on sys.path, so a sibling import needs it added explicitly. This
# happens at import time, before setUp's chdir, hence __file__ and not '.'.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from predict_weights_download import FakeResponse, make_zip


class StubJob:
    def __init__(self, spec, options, weights_path):
        self.job_id = 'stub-1'
        self.spec = spec
        self.options = options
        self.weights_path = weights_path
        self._pdb = (
            'ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N\n'
            'ATOM      2  CA  ALA A   1       1.458   0.000   0.000  1.00  0.00           C\n'
            'END\n')

    def status(self):
        return {'state': 'done', 'phase': 'done', 'fraction': 1.0,
                'error': None, 'result_path': self.result_path}

    @property
    def result_path(self):
        path = os.path.join(self.weights_path, 'stub.pdb')
        with open(path, 'w') as handle:
            handle.write(self._pdb)
        return path

    def cancel(self):
        self.cancelled = True


def install_stub(cache_root, digest, size):
    from pymol.predictors import registry
    from pymol.predictors.base import Predictor, PredictionSpec, parse_chains
    from pymol.predictors.weights import WeightBundle

    class Stub(Predictor):
        id = 'stub'
        name = 'Stub predictor'
        weight_bundle = WeightBundle(
            id='stub', version='v1', url='https://example.invalid/b.zip',
            sha256=digest, size=size, members=('config.json', 'model.bin'))
        option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return StubJob(spec, options, weights_path)

    registry.register(Stub(), replace=True)
    return Stub


class PredictAPITest(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        self.data, self.digest = make_zip()
        install_stub(self.root, self.digest, len(self.data))

    def tearDown(self):
        from pymol.predictors import registry
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    def testFullFlowDeclareFetchRunLoad(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)) as opener:
            job = cmd.predict('stub', 'AA', name='pred')
            self.assertEqual(opener.call_count, 1, 'weights fetched lazily, once')
        self.assertEqual(job.status()['state'], 'done')
        name = cmd.predict_result(job.job_id, 'pred')
        self.assertIn('pred', cmd.get_names('objects'))
        self.assertEqual(name, 'pred')
        self.assertEqual(cmd.count_atoms('pred'), 2)

    def testSecondRunDoesNotReDownload(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.predict('stub', 'AA')
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            cmd.predict('stub', 'AA')

    def testUnknownPredictorRaises(self):
        from pymol.predictors.errors import PredictorNotFound
        self.assertRaises(PredictorNotFound, cmd.predict, 'nope', 'AA')

    def testOptionsReachThePredictor(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA', diffusion_steps=300, seed=7)
        self.assertEqual(job.options.diffusion_steps, 300)
        self.assertEqual(job.options.seed, 7)
        self.assertEqual(job.options.recycling_steps, 3)

    def testUnknownOptionRejected(self):
        from pymol.predictors.errors import PredictionOptionError
        self.assertRaises(PredictionOptionError,
                          cmd.predict, 'stub', 'AA', diffusion_samples=4)

    def testMalformedInputRejected(self):
        from pymol.predictors.errors import PredictionInputError
        self.assertRaises(PredictionInputError, cmd.predict, 'stub', '')

    def testUnavailablePredictorRaisesBeforeAnyDownload(self):
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorUnavailable
        predictor = registry.get('stub')
        with patch.object(type(predictor), 'check_available',
                          side_effect=PredictorUnavailable('no host')):
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=AssertionError('must not download')):
                self.assertRaises(PredictorUnavailable,
                                  cmd.predict, 'stub', 'AA')

    def testPredictWeightsReportsCacheState(self):
        info = cmd.predict_weights('stub')
        self.assertFalse(info['stub']['cached'])
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            cmd.predict('stub', 'AA')
        self.assertTrue(cmd.predict_weights('stub')['stub']['cached'])

    def testPredictWeightsPrefetchesOnDemand(self):
        """The documented way to avoid the blocking first predict."""
        self.assertFalse(cmd.predict_weights('stub')['stub']['cached'])
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)) as opener:
            info = cmd.predict_weights('stub', download=1)
            self.assertEqual(opener.call_count, 1)
        self.assertTrue(info['stub']['cached'])
        # And a subsequent predict must not re-download.
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not re-download')):
            cmd.predict('stub', 'AA')

    def testMultimerUsesSlashSeparator(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA/GG')
        self.assertEqual(job.spec.chains, (('A', 'AA'), ('B', 'GG')))

    def testPredictIsRegisteredAsACommandKeyword(self):
        self.assertIn('predict', cmd.keyword)
        self.assertIn('predict_status', cmd.keyword)
        self.assertIn('predict_cancel', cmd.keyword)

    # -- quiet=0 is the DEFAULT command-line path -------------------------------
    #
    # parsing.py:417-420 sets quiet=0 for any command-line invocation whose
    # argspec contains `quiet`. So every message-emitting branch below is what a
    # user typing `predict ...` at the prompt actually takes, while the Python
    # API defaults to quiet=1 and skips all of it. A first cut of this suite
    # tested only quiet=1 and was fully green while every one of these branches
    # raised AttributeError on a colorprinting function that does not exist.

    def testPredictIsVerboseWithoutRaising(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA', quiet=0)
        self.assertEqual(job.status()['state'], 'done')

    def testProgressReportingPathIsExercised(self):
        """quiet=0 routes WeightCache progress through the reporting callback."""
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data, chunk=4)):
            cmd.predict('stub', 'AA', quiet=0)

    def testStatusCancelResultAndWeightsAreVerboseWithoutRaising(self):
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA', name='verbose', quiet=0)
        cmd.predict_status(job.job_id, quiet=0)
        cmd.predict_status(quiet=0)
        cmd.predict_cancel(job.job_id, quiet=0)
        cmd.predict_weights('stub', quiet=0)
        cmd.predict_result(job.job_id, 'verbose', quiet=0)
        self.assertIn('verbose', cmd.get_names('objects'))

    def testEveryMessageHelperUsedByPredictingExists(self):
        """Guards the whole class of bug: a message helper that is not there.

        colorprinting exposes error/warning/suggest/parrot -- there is no info().
        Every name predicting.py reaches for must resolve, or a branch no test
        happens to take will crash in front of a user.
        """
        import re
        from pymol import colorprinting, predicting
        with open(predicting.__file__) as handle:
            used = set(re.findall(r'colorprinting\.(\w+)', handle.read()))
        self.assertTrue(used, 'expected predicting.py to emit messages')
        for helper in sorted(used):
            self.assertTrue(hasattr(colorprinting, helper),
                            'colorprinting has no %r' % helper)
