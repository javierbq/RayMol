"""protenix-base predictor: availability, what it accepts, and what it puts on the wire.
No Swift and no network -- the host is simulated by the env vars it sets.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_protenix.py
"""
import io
import json
import os
from contextlib import redirect_stdout

from pymol import cmd, predicting, testing
from pymol.predictors import host
from pymol.predictors.errors import (PredictionInputError, PredictionOptionError,
                                     PredictorUnavailable)
from pymol.predictors import registry
from pymol.predictors.protenix import MAX_RESIDUES, PREDICTORS


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
                          registry.get('protenix-base-int8').check_available)

    def testNoHostIsReportedAsNoHostEvenWhenTheRuntimeIsAlsoMissing(self):
        """Order matters: the two failures have different remedies."""
        os.environ.pop(host.HOST_ENV, None)
        os.environ.pop(host.RUNTIMES_ENV, None)
        try:
            registry.get('protenix-base-int8').check_available()
        except PredictorUnavailable as error:
            self.assertIn('application host', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testRefusedOnAHostThatCarriesOnlyBoltz(self):
        """This is today's state: no build carries the protenix runtime yet."""
        self.declareHost('boltz')
        try:
            registry.get('protenix-base-int8').check_available()
        except PredictorUnavailable as error:
            self.assertIn('protenix-base-int8', str(error))
            self.assertIn('does not carry', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testRefusalNamesWhatTheBuildDoesCarry(self):
        """So the user can tell "wrong build" from "wrong predictor name"."""
        self.declareHost('boltz,mystery')
        try:
            registry.get('protenix-base-int8').check_available()
        except PredictorUnavailable as error:
            self.assertIn('boltz', str(error))
        else:
            self.fail('expected PredictorUnavailable')

    def testAvailableOnAHostCarryingProtenix(self):
        self.declareHost('boltz,protenix')
        self.assertIsNone(registry.get('protenix-base-int8').check_available())

    def testAHostDeclaringNothingIsAssumedBoltzOnly(self):
        os.environ[host.HOST_ENV] = '1'
        os.environ.pop(host.RUNTIMES_ENV, None)
        self.assertRaises(PredictorUnavailable,
                          registry.get('protenix-base-int8').check_available)


class TestComplexesAreAccepted(testing.PyMOLTestCase):
    """Protenix genuinely models a complex, so a multimer is accepted.

    The port's featurizer groups chains into entities and builds the cross-chain pair
    features, so refusing a multimer here would withhold something the method does. A
    method that CANNOT model one must refuse instead: folding the concatenation would
    emit a PDB nothing downstream could distinguish from a real prediction.
    """

    def predictor(self):
        return registry.get('protenix-base-int8')

    def testOneChainIsAccepted(self):
        spec = self.predictor().parse_spec('ACDEFGHIK', 'p')
        self.assertEqual(spec.chains, (('A', 'ACDEFGHIK'),))

    def testTwoTypedChainsAccepted(self):
        spec = self.predictor().parse_spec('ACDEF/GHIKL')
        self.assertEqual(spec.chains, (('A', 'ACDEF'), ('B', 'GHIKL')))

    def testAHomodimerIsAccepted(self):
        """Identical sequences are the case the featurizer groups into one entity."""
        spec = self.predictor().parse_spec('ACDEF/ACDEF')
        self.assertEqual(spec.chains, (('A', 'ACDEF'), ('B', 'ACDEF')))

    def testAMultiChainSelectionIsAccepted(self):
        cmd.fab('ACDEFG', 'one')
        cmd.fab('GHIKL', 'two')
        resolved = predicting.resolve_sequence('one or two')
        self.assertEqual(resolved, 'ACDEFG/GHIKL')
        spec = self.predictor().parse_spec(resolved)
        self.assertEqual(len(spec.chains), 2)

    def testTheLimitIsOnTheTotalNotPerChain(self):
        """Peak memory is ~N^2 in TOTAL tokens, so the cap has to be on the sum."""
        half = 'A' * (MAX_RESIDUES // 2 + 1)
        self.assertRaises(PredictionInputError,
                          self.predictor().parse_spec, '%s/%s' % (half, half))


class TestResidueValidation(testing.PyMOLTestCase):

    def predictor(self):
        return registry.get('protenix-base-int8')

    def testNonCanonicalRejectedRatherThanSubstituted(self):
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

    def testTheChainIsNamedToo(self):
        """With a complex, "there is a bad residue" is not actionable on its own."""
        try:
            self.predictor().parse_spec('ACDEF/GHIKX')
        except PredictionInputError as error:
            self.assertIn('chain B', str(error))
        else:
            self.fail('expected PredictionInputError')

    def testTheRefusalSaysWhyRatherThanJustNo(self):
        """The reason is the remedy: this runtime carries no CCD, so no ligands."""
        try:
            self.predictor().parse_spec('ACDEFX')
        except PredictionInputError as error:
            self.assertIn('canonical 20', str(error))
        else:
            self.fail('expected PredictionInputError')

    def testTooLongRejected(self):
        self.assertRaises(PredictionInputError,
                          self.predictor().parse_spec, 'A' * (MAX_RESIDUES + 1))

    def testAtTheLimitAccepted(self):
        spec = self.predictor().parse_spec('A' * MAX_RESIDUES)
        self.assertEqual(len(spec.chains[0][1]), MAX_RESIDUES)

    def testTheLimitSaysItIsMeasuredRatherThanIntrinsic(self):
        try:
            self.predictor().parse_spec('A' * (MAX_RESIDUES + 1))
        except PredictionInputError as error:
            self.assertIn('measured', str(error))
        else:
            self.fail('expected PredictionInputError')


class TestOptions(testing.PyMOLTestCase):
    """Protenix recycles a trunk and runs reverse diffusion, so it takes Boltz's knobs."""

    def predictor(self):
        return registry.get('protenix-base-int8')

    def testTheReleasedOperatingPointIsTheDefault(self):
        options = self.predictor().validate_options({})
        self.assertEqual(options.recycling_steps, 10)
        self.assertEqual(options.diffusion_steps, 200)

    def testBothKnobsAreHonoured(self):
        options = self.predictor().validate_options(
            {'recycling_steps': 3, 'diffusion_steps': 50})
        self.assertEqual(options.recycling_steps, 3)
        self.assertEqual(options.diffusion_steps, 50)

    def testMsaDepthRejectedByName(self):
        """There is no alignment to have a depth."""
        try:
            self.predictor().validate_options({'msa_depth': 64})
        except PredictionOptionError as error:
            self.assertIn('msa_depth', str(error))
        else:
            self.fail('expected msa_depth to be rejected by name')

    def testKnobsAreStillBounded(self):
        for bad in ({'recycling_steps': -1}, {'diffusion_steps': 0}, {'seed': -1}):
            self.assertRaises(PredictionOptionError,
                              self.predictor().validate_options, bad)


class TestAlignmentsRefused(testing.PyMOLTestCase):
    """supports_msa is False, so an alignment is refused BY NAME rather than dropped."""

    def testAnAlignmentIsRefused(self):
        predictor = registry.get('protenix-base-int8')
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
        predictor = registry.get('protenix-base-int8')
        spec = predictor.parse_spec('ACDEFG')
        self.assertEqual(predictor.bind_alignments(spec, {}).alignments, {})


class TestWireFormat(testing.PyMOLTestCase):
    """What reaches the Swift host: its runtime, and only its own knobs."""

    def submit(self, sequence='ACDEFG', options=None):
        predictor = registry.get('protenix-base-int8')
        spec = predictor.parse_spec(sequence, 'pred')
        options = predictor.validate_options(options or {})
        with redirect_stdout(io.StringIO()) as buf:
            job = predictor.submit(spec, options, '/tmp/weights')
        with open(job.request_path) as handle:
            request = json.load(handle)
        os.unlink(job.request_path)
        return job, request, buf.getvalue()

    def testRequestNamesTheProtenixRuntime(self):
        _, request, _ = self.submit()
        self.assertEqual(request['runtime'], 'protenix')

    def testRequestCarriesItsOwnKnobs(self):
        _, request, _ = self.submit(
            options={'recycling_steps': 4, 'diffusion_steps': 20, 'seed': 7})
        self.assertEqual(request['recycling_steps'], 4)
        self.assertEqual(request['diffusion_steps'], 20)
        self.assertEqual(request['seed'], 7)

    def testRequestOmitsKnobsProtenixDoesNotHave(self):
        _, request, _ = self.submit()
        for absent in ('msa_depth',):
            self.assertNotIn(absent, request)

    def testAComplexReachesTheWireAsBothChains(self):
        _, request, _ = self.submit('ACDEF/GHIKL')
        self.assertEqual(request['chains'],
                         [{'chain': 'A', 'sequence': 'ACDEF'},
                          {'chain': 'B', 'sequence': 'GHIKL'}])

    def testMarkerIsPrinted(self):
        job, _, out = self.submit()
        self.assertIn('PREDICT:submit:%s' % job.job_id, out)


class TestEveryPackIsAPredictor(testing.PyMOLTestCase):
    """One id per published pack, and every one of them fetchable and distinct."""

    def ids(self):
        from pymol.predictors import registry
        return [i for i in registry.available() if i.startswith('protenix-')]

    def testAllTwelvePacksAreRegistered(self):
        self.assertEqual(len(self.ids()), 12)

    def testEveryVariantAndPrecisionIsOffered(self):
        expected = {'protenix-%s-%s' % (v, p)
                    for v in ('tiny', 'mini', 'base', 'v2')
                    for p in ('int8', 'fp16', 'bf16')}
        self.assertEqual(set(self.ids()), expected)

    def testV2SaysItIsMirrorSourcedWhereAUserWouldSeeIt(self):
        """Its official checkpoint has answered 403 since April 2026.

        These packs come from a Hugging Face mirror whose uploader states no affiliation.
        The file audits clean structurally and is pinned by digest, but no official
        checksum exists for ANY Protenix checkpoint, so nothing authoritative confirms the
        weight values. That belongs in the NAME, not only in a comment.
        """
        from pymol.predictors import registry
        for precision in ('int8', 'fp16', 'bf16'):
            name = registry.get('protenix-v2-%s' % precision).name
            self.assertIn('mirror', name.lower(), precision)

    def testV2IsCappedLowerBecauseItIsMeasuredLess(self):
        from pymol.predictors import registry
        from pymol.predictors.protenix import MAX_RESIDUES, V2_MAX_RESIDUES
        self.assertLess(V2_MAX_RESIDUES, MAX_RESIDUES)
        self.assertEqual(registry.get('protenix-v2-int8').max_residues, V2_MAX_RESIDUES)
        self.assertEqual(registry.get('protenix-base-int8').max_residues, MAX_RESIDUES)

    def testV2RefusesAboveItsOwnCapNotBases(self):
        from pymol.predictors import registry
        from pymol.predictors.protenix import V2_MAX_RESIDUES
        sequence = 'A' * (V2_MAX_RESIDUES + 1)
        # Fine for base, refused for v2 -- the cap is per pack, not per method.
        registry.get('protenix-base-int8').parse_spec(sequence)
        try:
            registry.get('protenix-v2-int8').parse_spec(sequence)
        except PredictionInputError as error:
            self.assertIn('protenix-v2-int8', str(error))
        else:
            self.fail('expected v2 to refuse above its own cap')

    def testNoIdIsAPrefixOfAnother(self):
        """docs/predictors.md step 1: a shared prefix is a tab-completion dead end.

        With nine ids this stops being a nicety. Every one ends in a precision suffix of
        the same shape, so `predict protenix-b<Tab>` can always make progress.
        """
        for one in self.ids():
            for other in self.ids():
                if one != other:
                    self.assertFalse(other.startswith(one), '%s / %s' % (one, other))

    def testEveryPackHasItsOwnDigestAndSize(self):
        """Nine bundles copied by hand is nine chances to paste the wrong digest."""
        from pymol.predictors import registry
        seen = {}
        for pid in self.ids():
            bundle = registry.get(pid).weight_bundle
            self.assertEqual(len(bundle.sha256), 64, pid)
            self.assertNotIn(bundle.sha256, seen,
                             '%s and %s share a digest' % (pid, seen.get(bundle.sha256)))
            seen[bundle.sha256] = pid
            self.assertGreater(bundle.size, 1_000_000, pid)

    def testDigestsAreRealHex(self):
        """A padded or placeholder digest is the failure mode this guards."""
        from pymol.predictors import registry
        for pid in self.ids():
            sha = registry.get(pid).weight_bundle.sha256
            self.assertRegex(sha, r'^[0-9a-f]{64}$', pid)
            self.assertNotEqual(sha, '0' * 64, pid)
            # A real sha256 has no long runs; a hand-padded one usually does.
            self.assertNotIn('a0a0a0a0a0a0', sha, pid)

    def testTinyAndMiniUseTheirOwnShorterSchedule(self):
        """v0.5.0 models were trained at 4 recycles / 5 steps.

        Running them at base's 10 / 200 would spend forty times the compute on a model
        that was not trained to use it -- and quietly, since nothing would fail.
        """
        from pymol.predictors import registry
        for pid in ('protenix-tiny-int8', 'protenix-mini-bf16'):
            defaults = registry.get(pid).option_defaults
            self.assertEqual(defaults['recycling_steps'], 4, pid)
            self.assertEqual(defaults['diffusion_steps'], 5, pid)

    def testBaseUsesTheReleasedOperatingPoint(self):
        from pymol.predictors import registry
        defaults = registry.get('protenix-base-fp16').option_defaults
        self.assertEqual(defaults['recycling_steps'], 10)
        self.assertEqual(defaults['diffusion_steps'], 200)

    def testEveryPackSharesTheOneRuntime(self):
        """Nine tools, one backend -- the boltz2 / boltz2-bf16 pattern."""
        from pymol.predictors.protenix import RUNTIME
        from pymol.predictors import registry
        for pid in self.ids():
            self.assertEqual(registry.get(pid).submit.__self__.__class__.__mro__[1].__name__,
                             'ProtenixPredictor', pid)
        self.assertEqual(RUNTIME, 'protenix')

    def testTheDensePacksAreLargerThanTheQuantisedOne(self):
        """Sanity on the transcription: fp16 is about twice int8, per variant."""
        from pymol.predictors import registry
        for variant in ('tiny', 'mini', 'base', 'v2'):
            small = registry.get('protenix-%s-int8' % variant).weight_bundle.size
            dense = registry.get('protenix-%s-fp16' % variant).weight_bundle.size
            self.assertGreater(dense, small * 1.5, variant)


class TestRegistration(testing.PyMOLTestCase):

    def testRegisteredUnderItsId(self):
        from pymol.predictors import registry
        self.assertIn('protenix-base-int8', registry.available())
        self.assertEqual(registry.get('protenix-base-int8').id, 'protenix-base-int8')

    def testIdIsNotAPrefixExtensionOfAnother(self):
        """docs/predictors.md step 1: a shared prefix breaks tab completion.

        This is why the id is `protenix-base` and not `protenix` -- a later
        `protenix-v2` would otherwise stop `predict protenix<Tab>` at a bare
        `protenix` that names no runnable predictor.
        """
        from pymol.predictors import registry
        for other in (i for i in registry.available() if i != 'protenix-base-int8'):
            self.assertFalse('protenix-base-int8'.startswith(other))
            self.assertFalse(other.startswith('protenix-base-int8'))

    def testWeightBundleIsDeclaredWithARealDigest(self):
        bundle = registry.get('protenix-base-int8').weight_bundle
        self.assertEqual(len(bundle.sha256), 64)
        self.assertNotEqual(set(bundle.sha256), {'0'})
        self.assertGreater(bundle.size, 0)
        self.assertEqual(bundle.members,
                         ('config.json', 'manifest.json', 'model.safetensors'))

    def testConfigJsonIsAMandatoryMember(self):
        """A Protenix checkpoint carries no architecture, so the pack must."""
        self.assertIn('config.json', registry.get('protenix-base-int8').weight_bundle.members)


class TestCommandSurface(HostEnvTestCase):
    """cmd.predict's own layer, at quiet=0 as well as the default.

    parsing.py sets quiet=0 for any command-line invocation, so a suite that only
    exercises quiet=1 never takes a single message-emitting branch.
    """

    def testAnUnknownPredictorNamesThisOneAmongTheAlternatives(self):
        """The registry's own error is how a user discovers the id."""
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        try:
            registry.get('protenix')
        except PredictorNotFound as error:
            self.assertIn('protenix-base-int8', str(error))
        else:
            self.fail('expected a bare "protenix" to be unknown')

    def testRefusalIsReportedAtBothVerbosities(self):
        self.declareHost('boltz')
        for quiet in (0, 1):
            with redirect_stdout(io.StringIO()):
                self.assertRaises(PredictorUnavailable, cmd.predict,
                                  'protenix-base-int8', 'ACDEFG', quiet=quiet)

    def testWeightsSurfaceReportsTheBundleWithoutFetchingIt(self):
        """predict_weights iterates EVERY predictor, so this must not download."""
        for quiet in (0, 1):
            out = cmd.predict_weights('protenix-base-int8', download=0, quiet=quiet)
            self.assertEqual(out['protenix-base-int8']['bundle'],
                             'protenix-base-mlx-int8')


class TestBulkPrefetchSkipsWhatCannotRun(HostEnvTestCase):
    """`predict_weights download=1` with no id must not fetch an unusable pack.

    It iterates every registered predictor, and protenix-base is 214 MB whose runtime
    no shipping build carries yet -- so without a filter, a command aimed at the
    predictors that DO work pulls it down anyway. Naming it explicitly still fetches:
    that is someone deliberately pre-warming, possibly for a build they do not have.
    """

    def setUp(self):
        HostEnvTestCase.setUp(self)
        self.started = []
        from pymol.predictors import fetching
        self._real_start = fetching.start
        fetching.start = lambda bundle, cache, **kw: self.started.append(bundle.id)

    def tearDown(self):
        from pymol.predictors import fetching
        fetching.start = self._real_start
        HostEnvTestCase.tearDown(self)

    def testBulkFetchSkipsAPredictorWhoseRuntimeIsAbsent(self):
        self.declareHost('boltz')
        cmd.predict_weights(download=1, async_=1)
        self.assertNotIn('protenix-base-mlx-int8', self.started)

    def testBulkFetchStillTakesTheOnesThatWork(self):
        """Asserted as "fetched OR already cached", not "fetched".

        Whether a bundle downloads depends on the machine's cache, so asserting a
        download makes the test pass or fail on local state rather than on the filter.
        """
        self.declareHost('boltz')
        out = cmd.predict_weights(download=1, async_=1)
        self.assertTrue(out['boltz2']['cached']
                        or 'boltz2-mlx-int8' in self.started)

    def testNamingItExplicitlyStillFetches(self):
        """Asserted as "fetched OR already cached" -- a machine that has run a fold has
        the pack, so asserting a download tests local state rather than the filter."""
        self.declareHost('boltz')
        out = cmd.predict_weights('protenix-base-int8', download=1, async_=1)
        self.assertTrue(out['protenix-base-int8']['cached']
                        or 'protenix-base-mlx-int8' in self.started)

    def testBulkFetchTakesItOnceTheRuntimeIsThere(self):
        self.declareHost('boltz,protenix')
        out = cmd.predict_weights(download=1, async_=1)
        self.assertTrue(out['protenix-base-int8']['cached']
                        or 'protenix-base-mlx-int8' in self.started)
        # And the OTHER packs, which no fold has cached, are genuinely fetched.
        self.assertIn('protenix-tiny-mlx-int8', self.started)

    def testItIsStillReportedEvenWhenNotFetched(self):
        """Skipping the download must not hide the predictor from the report."""
        self.declareHost('boltz')
        out = cmd.predict_weights(download=1, async_=1)
        self.assertIn('protenix-base-int8', out)
        self.assertEqual(out['protenix-base-int8']['bundle'], 'protenix-base-mlx-int8')

    def testTheSkipIsExplainedAtQuietZero(self):
        self.declareHost('boltz')
        with redirect_stdout(io.StringIO()) as buf:
            cmd.predict_weights(download=1, async_=1, quiet=0)
        self.assertIn('cannot run in this build', buf.getvalue())

    def testNoKnobHadToBeAddedToTheSignature(self):
        """Every knob it declares already existed, so cmd.predict is untouched."""
        import inspect
        parameters = inspect.signature(predicting.predict).parameters
        for knob in registry.get('protenix-base-int8').option_defaults:
            self.assertIn(knob, parameters)
