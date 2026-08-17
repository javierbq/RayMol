"""The runtime seam: a request names the backend that must run it.

Before a second method existed, every prediction was Boltz and the request said nothing
about which backend it was for. It does now, because weights and featurizer are
method-specific: a request that reached the wrong backend would not fail, it would
featurize with the wrong tokenizer and return a confident wrong structure. So a predictor
declares its runtime, the host declares what it linked, and the mismatch is refused twice
-- once in check_available before any download, once in the Swift preflight.

Tested here rather than only through one predictor because the mechanism is shared, and
because its back-compatibility properties (absent means boltz, on both sides) are exactly
the kind of thing that rots silently.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_runtime.py
"""
import io
import json
import os
from contextlib import redirect_stdout

from pymol import testing
from pymol.predictors import host, registry
from pymol.predictors.errors import PredictorUnavailable


class RuntimeEnvTestCase(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        self._saved = {name: os.environ.get(name)
                       for name in (host.HOST_ENV, host.RUNTIMES_ENV)}

    def tearDown(self):
        for name, value in self._saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        testing.PyMOLTestCase.tearDown(self)


class TestSupportedRuntimes(RuntimeEnvTestCase):

    def testAHostDeclaringNothingIsAssumedBoltzOnly(self):
        """Every build before this variable existed had exactly the Boltz runtime."""
        os.environ[host.HOST_ENV] = '1'
        os.environ.pop(host.RUNTIMES_ENV, None)
        self.assertEqual(host.supported_runtimes(), ('boltz',))

    def testAnEmptyDeclarationIsTreatedAsUndeclared(self):
        """setenv with an empty value must not read as "no runtimes at all"."""
        os.environ[host.RUNTIMES_ENV] = ''
        self.assertEqual(host.supported_runtimes(), ('boltz',))

    def testDeclarationIsSplitAndStripped(self):
        os.environ[host.RUNTIMES_ENV] = ' boltz , protenix '
        self.assertEqual(host.supported_runtimes(), ('boltz', 'protenix'))

    def testTrailingSeparatorsAreIgnored(self):
        os.environ[host.RUNTIMES_ENV] = 'boltz,,'
        self.assertEqual(host.supported_runtimes(), ('boltz',))


class TestRequireRuntime(RuntimeEnvTestCase):

    def testPassesWhenDeclared(self):
        os.environ[host.HOST_ENV] = '1'
        os.environ[host.RUNTIMES_ENV] = 'boltz,protenix'
        self.assertIsNone(host.require_runtime('some-predictor', 'protenix'))

    def testRaisesWhenAbsent(self):
        os.environ[host.HOST_ENV] = '1'
        os.environ[host.RUNTIMES_ENV] = 'boltz'
        self.assertRaises(PredictorUnavailable,
                          host.require_runtime, 'some-predictor', 'protenix')

    def testTheErrorNamesBothTheWantedAndTheAvailable(self):
        """"Not available" is unactionable; "you have boltz, this needs protenix" is not."""
        os.environ[host.HOST_ENV] = '1'
        os.environ[host.RUNTIMES_ENV] = 'boltz'
        try:
            host.require_runtime('some-predictor', 'protenix')
        except PredictorUnavailable as error:
            self.assertIn('protenix', str(error))
            self.assertIn('boltz', str(error))
            self.assertIn('some-predictor', str(error))
        else:
            self.fail('expected PredictorUnavailable')


class TestRequestNamesItsRuntime(testing.PyMOLTestCase):

    def submit(self, predictor_id, sequence='ACDEFG'):
        predictor = registry.get(predictor_id)
        spec = predictor.parse_spec(sequence, 'pred')
        options = predictor.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = predictor.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        return request

    def testBoltzRequestSaysBoltz(self):
        self.assertEqual(self.submit('boltz2')['runtime'], 'boltz')

    def testTheDenseVariantIsTheSameRuntime(self):
        """boltz2-bf16 is one runtime and two tools: same backend, different weights."""
        self.assertEqual(self.submit('boltz2-bf16')['runtime'], 'boltz')

    def testProtenixRequestSaysProtenix(self):
        self.assertEqual(self.submit('protenix-base')['runtime'], 'protenix')

    def testEveryRegisteredPredictorNamesARuntime(self):
        """A request with no runtime is read as BOLTZ at the far end, deliberately.

        That default is what keeps an older Python side working, and it is also the trap:
        a new predictor that forgets to pass one is silently dispatched to Boltz's
        featurizer and weights. So every registered predictor is checked.
        """
        for pid in registry.available():
            self.assertIn('runtime', self.submit(pid), pid)


class TestOnlyDeclaredKnobsReachTheWire(testing.PyMOLTestCase):
    """A knob on the wire reads as one the method honours."""

    def submit(self, predictor_id):
        predictor = registry.get(predictor_id)
        spec = predictor.parse_spec('ACDEFG', 'pred')
        options = predictor.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = predictor.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        return request

    def testBoltzStillSendsEverythingItHonours(self):
        request = self.submit('boltz2')
        self.assertEqual(request['recycling_steps'], 3)
        self.assertEqual(request['diffusion_steps'], 200)
        self.assertEqual(request['msa_depth'], 16384)

    def testAMethodWithNoAlignmentSendsNoDepth(self):
        """msa_depth on the wire would record a run as having used an alignment."""
        self.assertNotIn('msa_depth', self.submit('protenix-base'))

    def testKnobsDefaultToEveryOptionWhenUnspecified(self):
        """An explicit `knobs=None` keeps the pre-seam behaviour for any caller."""
        predictor = registry.get('boltz2')
        spec = predictor.parse_spec('ACDEFG', 'pred')
        options = predictor.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = host.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        from pymol.predictors.base import PredictionOptions
        for knob in PredictionOptions.__slots__:
            self.assertIn(knob, request)

    def testTheDefaultRuntimeIsBoltz(self):
        """host.submit's own default, for a caller that names no runtime."""
        self.assertEqual(host.DEFAULT_RUNTIME, 'boltz')
