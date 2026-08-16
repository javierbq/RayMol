"""simplefold predictor: availability, the single-chain rule, and what it puts on
the wire. No Swift and no network -- the host is simulated by the env vars it sets.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_simplefold.py
"""
import io
import json
import os
from contextlib import redirect_stdout

from pymol import cmd, predicting, testing
from pymol.predictors import host
from pymol.predictors.errors import (PredictionInputError, PredictionOptionError,
                                     PredictorUnavailable)
from pymol.predictors.simplefold import SimpleFoldPredictor


class HostEnvTestCase(testing.PyMOLTestCase):
    """Restores both host variables, so one test cannot leak into the next."""

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

    def declareHost(self, runtimes):
        os.environ[host.HOST_ENV] = '1'
        os.environ[host.RUNTIMES_ENV] = runtimes


class TestAvailability(HostEnvTestCase):

    def testUnavailableWithoutAHost(self):
        os.environ.pop(host.HOST_ENV, None)
        os.environ.pop(host.RUNTIMES_ENV, None)
        self.assertRaises(PredictorUnavailable,
                          SimpleFoldPredictor().check_available)

    def testNoHostIsReportedAsNoHostEvenWhenTheRuntimeIsAlsoMissing(self):
        """Order matters: the two failures have different remedies."""
        os.environ.pop(host.HOST_ENV, None)
        os.environ.pop(host.RUNTIMES_ENV, None)
        try:
            SimpleFoldPredictor().check_available()
        except PredictorUnavailable as error:
            self.assertIn('application host', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testRefusedOnAHostThatCarriesOnlyBoltz(self):
        self.declareHost('boltz')
        try:
            SimpleFoldPredictor().check_available()
        except PredictorUnavailable as error:
            self.assertIn('simplefold', str(error))
            self.assertIn('does not carry', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testAHostDeclaringNothingIsAssumedBoltzOnly(self):
        """Every build before RUNTIMES_ENV existed had exactly the Boltz runtime."""
        os.environ[host.HOST_ENV] = '1'
        os.environ.pop(host.RUNTIMES_ENV, None)
        self.assertEqual(host.supported_runtimes(), ('boltz',))
        self.assertRaises(PredictorUnavailable,
                          SimpleFoldPredictor().check_available)

    def testStillRefusedWithTheRuntimeWhileWeightsAreUnpublished(self):
        self.declareHost('boltz,simplefold')
        try:
            SimpleFoldPredictor().check_available()
        except PredictorUnavailable as error:
            self.assertIn('weight pack', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testBoltzIsUnaffectedByTheRuntimeDeclaration(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        os.environ[host.HOST_ENV] = '1'
        os.environ.pop(host.RUNTIMES_ENV, None)
        self.assertIsNone(Boltz2Predictor().check_available())


class TestSingleChainRule(testing.PyMOLTestCase):
    """A complex is a plain error -- never a warning, never a partial fold."""

    def predictor(self):
        return SimpleFoldPredictor()

    def testOneChainIsAccepted(self):
        spec = self.predictor().parse_spec('ACDEFGHIK', 'p')
        self.assertEqual(spec.chains, (('A', 'ACDEFGHIK'),))

    def testTwoTypedChainsRejected(self):
        try:
            self.predictor().parse_spec('ACDEF/GHIKL')
        except PredictionInputError as error:
            self.assertIn('cannot fold a complex', str(error))
            self.assertIn('A, B', str(error))
            self.assertIn('2 were given', str(error))
        else:
            self.fail('expected PredictionInputError')

    def testThreeTypedChainsRejected(self):
        self.assertRaises(PredictionInputError,
                          self.predictor().parse_spec, 'ACDEF/GHIKL/MNPQR')

    def testErrorNamesAWorkingAlternative(self):
        """The remedy is in the message: fold separately, or use boltz2."""
        try:
            self.predictor().parse_spec('ACDEF/GHIKL')
        except PredictionInputError as error:
            self.assertIn('separately', str(error))
            self.assertIn('boltz2', str(error))

    def testAMultiChainSelectionIsRejectedToo(self):
        """The likelier path: no separator is typed at all.

        resolve_sequence reads one chain per (object, chain id) and joins them with
        '/', so a selection spanning two objects reaches parse_spec in exactly the
        shape a typed multimer does -- which is why one check covers both.
        """
        cmd.fab('ACDEFG', 'one')
        cmd.fab('GHIKL', 'two')
        resolved = predicting.resolve_sequence('one or two')
        self.assertEqual(resolved, 'ACDEFG/GHIKL')
        self.assertRaises(PredictionInputError,
                          self.predictor().parse_spec, resolved)

    def testASingleChainSelectionIsAccepted(self):
        cmd.fab('ACDEFG', 'one')
        spec = self.predictor().parse_spec(predicting.resolve_sequence('one'))
        self.assertEqual(spec.chains, (('A', 'ACDEFG'),))


class TestResidueValidation(testing.PyMOLTestCase):

    def predictor(self):
        return SimpleFoldPredictor()

    def testNonCanonicalRejectedRatherThanFoldedAsX(self):
        """The port's tokenizer resolves an unknown letter to X instead of failing."""
        for sequence in ('ACDEFX', 'ACDEFU', 'ACDEFB', 'ACDEFZ'):
            self.assertRaises(PredictionInputError,
                              self.predictor().parse_spec, sequence)

    def testTheOffendingLetterIsNamed(self):
        try:
            self.predictor().parse_spec('ACDEFJ')
        except PredictionInputError as error:
            self.assertIn('J', str(error))
        else:
            self.fail('expected PredictionInputError')

    def testTooLongRejected(self):
        from pymol.predictors.simplefold import MAX_RESIDUES
        self.assertRaises(PredictionInputError,
                          self.predictor().parse_spec, 'A' * (MAX_RESIDUES + 1))

    def testAtTheLimitAccepted(self):
        from pymol.predictors.simplefold import MAX_RESIDUES
        spec = self.predictor().parse_spec('A' * MAX_RESIDUES)
        self.assertEqual(len(spec.chains[0][1]), MAX_RESIDUES)


class TestOptions(testing.PyMOLTestCase):

    def predictor(self):
        return SimpleFoldPredictor()

    def testNumStepsIsHonoured(self):
        options = self.predictor().validate_options({'num_steps': 250})
        self.assertEqual(options.num_steps, 250)

    def testDefaultIsFiveHundred(self):
        self.assertEqual(self.predictor().validate_options({}).num_steps, 500)

    def testBoltzKnobsRejectedByName(self):
        for knob in ('recycling_steps', 'diffusion_steps', 'msa_depth',
                     'diffusion_samples'):
            try:
                self.predictor().validate_options({knob: 1})
            except PredictionOptionError as error:
                self.assertIn(knob, str(error))
            else:
                self.fail('expected %s to be rejected by name' % knob)

    def testNumStepsRejectedByBoltz(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        try:
            Boltz2Predictor().validate_options({'num_steps': 10})
        except PredictionOptionError as error:
            self.assertIn('num_steps', str(error))
        else:
            self.fail('expected num_steps to be rejected by name')

    def testNumStepsIsBounded(self):
        from pymol.predictors.base import MAX_NUM_STEPS
        for bad in (0, -1, MAX_NUM_STEPS + 1):
            self.assertRaises(PredictionOptionError,
                              self.predictor().validate_options,
                              {'num_steps': bad})

    def testNumStepsMustBeAnInteger(self):
        for bad in (1.5, '250', True):
            self.assertRaises(PredictionOptionError,
                              self.predictor().validate_options,
                              {'num_steps': bad})


class TestAlignmentsRefused(testing.PyMOLTestCase):
    """supports_msa is False, so an alignment is refused BY NAME."""

    def testAnAlignmentIsRefused(self):
        predictor = SimpleFoldPredictor()
        spec = predictor.parse_spec('ACDEFG')

        class FakeMSA:
            name = 'aln'
            query = 'ACDEFG'
            depth = 32

        try:
            predictor.bind_alignments(spec, {'A': FakeMSA()})
        except PredictionInputError as error:
            self.assertIn('cannot use a multiple-sequence alignment', str(error))
        else:
            self.fail('expected PredictionInputError')

    def testNoAlignmentIsFine(self):
        predictor = SimpleFoldPredictor()
        spec = predictor.parse_spec('ACDEFG')
        self.assertEqual(predictor.bind_alignments(spec, {}).alignments, {})


class TestWireFormat(testing.PyMOLTestCase):
    """What reaches the Swift host: its runtime, and only its own knobs."""

    def submit(self, options=None):
        predictor = SimpleFoldPredictor()
        spec = predictor.parse_spec('ACDEFG', 'pred')
        options = predictor.validate_options(options or {})
        with redirect_stdout(io.StringIO()) as buf:
            job = predictor.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        return job, request, buf.getvalue()

    def testRequestNamesTheSimpleFoldRuntime(self):
        _, request, _ = self.submit()
        self.assertEqual(request['runtime'], 'simplefold')

    def testRequestCarriesNumStepsAndSeed(self):
        _, request, _ = self.submit({'num_steps': 250, 'seed': 7})
        self.assertEqual(request['num_steps'], 250)
        self.assertEqual(request['seed'], 7)

    def testRequestOmitsKnobsSimpleFoldDoesNotHave(self):
        """A SimpleFold request has no recycling_steps: there is no trunk."""
        _, request, _ = self.submit()
        for absent in ('recycling_steps', 'diffusion_steps', 'msa_depth'):
            self.assertNotIn(absent, request)

    def testMarkerIsPrinted(self):
        job, _, out = self.submit()
        self.assertIn('PREDICT:submit:%s' % job.job_id, out)

    def testBoltzRequestIsUnchanged(self):
        """The knob split must not have altered what boltz2 sends."""
        from pymol.predictors.boltz2 import Boltz2Predictor
        predictor = Boltz2Predictor()
        spec = predictor.parse_spec('ACDEFG', 'pred')
        options = predictor.validate_options({})
        with redirect_stdout(io.StringIO()):
            job = predictor.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        self.assertEqual(request['runtime'], 'boltz')
        self.assertEqual(request['recycling_steps'], 3)
        self.assertEqual(request['diffusion_steps'], 200)
        self.assertEqual(request['msa_depth'], 16384)
        self.assertNotIn('num_steps', request)


class TestRegistration(testing.PyMOLTestCase):

    def testRegisteredUnderItsId(self):
        from pymol.predictors import registry
        self.assertIn('simplefold', registry.available())
        self.assertEqual(registry.get('simplefold').id, 'simplefold')

    def testIdIsNotAPrefixExtensionOfAnother(self):
        """docs/predictors.md step 1: a shared prefix breaks tab completion."""
        from pymol.predictors import registry
        others = [i for i in registry.available() if i != 'simplefold']
        for other in others:
            self.assertFalse('simplefold'.startswith(other))
            self.assertFalse(other.startswith('simplefold'))

    def testWeightsCommandSkipsAnUnpublishedPack(self):
        """predict_weights iterates EVERY predictor; nothing may be fetched here."""
        out = cmd.predict_weights('simplefold', download=1, async_=0)
        self.assertIsNone(out['simplefold']['bundle'])


class TestCommandSurface(HostEnvTestCase):
    """cmd.predict's own layer: the knob must be nameable to be rejectable."""

    def testNumStepsIsAcceptedByTheSignature(self):
        """A knob absent from the signature raises TypeError before validation."""
        import inspect
        self.assertIn('num_steps', inspect.signature(cmd.predict).parameters)

    def testPredictRefusesCleanlyWithoutTheRuntime(self):
        self.declareHost('boltz')
        self.assertRaises(PredictorUnavailable,
                          cmd.predict, 'simplefold', 'ACDEFG')

    def testPredictRefusesCleanlyAtQuietZeroToo(self):
        """parsing.py forces quiet=0 for command-line invocations."""
        self.declareHost('boltz')
        self.assertRaises(PredictorUnavailable,
                          cmd.predict, 'simplefold', 'ACDEFG', quiet=0)

    def testBoltzStillRunsWithNoKnobsNamed(self):
        """The conditional-knob change must not have broken the default call."""
        from pymol.predictors.boltz2 import Boltz2Predictor
        options = Boltz2Predictor().validate_options({'seed': 0})
        self.assertEqual(options.recycling_steps, 3)
        self.assertEqual(options.diffusion_steps, 200)
