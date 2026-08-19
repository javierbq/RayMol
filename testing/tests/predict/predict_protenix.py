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

    def testTheLengthThatPromptedTheRaiseIsAccepted(self):
        """532 residues hit the old 400 cap. 550 is measured, at 6.3 GB."""
        spec = self.predictor().parse_spec('A' * 532)
        self.assertEqual(len(spec.chains[0][1]), 532)

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


class TestTheRefusalQuotesTheVariantThatActuallyFailed(testing.PyMOLTestCase):
    """#316: the over-length refusal used to quote base's sweep whatever refused it.

    A v2 user who asked for 429 residues was told the limit "is measured" and that peak
    memory "reaches 8.6 GB at 700 residues" -- three numbers from a pack they were not
    running, and, worse, the claim that v2's 250 came from a memory measurement. It did
    not: v2 is swept at one point, 15 residues. Which of the two it is decides the
    reader's next move (accept a wall, or go measure), so the message has to get it
    right, and has to get it right FROM the table rather than from prose that can drift
    out of step with it.
    """

    def refusal(self, predictor_id):
        from pymol.predictors import registry
        predictor = registry.get(predictor_id)
        try:
            predictor.parse_spec('A' * (predictor.max_residues + 1))
        except PredictionInputError as error:
            return str(error)
        self.fail('expected %s to refuse above its cap' % predictor_id)

    def testBaseCallsItsCapMeasuredBecauseItIs(self):
        """700 is a point in base's own sweep, so "measured" is the honest word."""
        self.assertIn('That limit is measured', self.refusal('protenix-base-int8'))

    def testBaseQuotesThePeakItsOwnTableRecordsAtTheCap(self):
        """Derived from MEASURED_PEAK_MIB, so a future sweep cannot leave prose stale."""
        from pymol.predictors.protenix import MAX_RESIDUES, MEASURED_PEAK_MIB
        peak = dict(MEASURED_PEAK_MIB['base'])[MAX_RESIDUES]
        self.assertIn('%.1f GiB' % (peak / 1024.0), self.refusal('protenix-base-int8'))
        self.assertIn('at %d residues' % MAX_RESIDUES,
                      self.refusal('protenix-base-int8'))

    def testV2AlsoCallsItsCapMeasuredNowThatItIs(self):
        """v2 was swept for #316, so "measured" became the honest word for it too.

        This test read the other way round when the cap was 250: the point is not which
        word appears but that the word tracks the table, and the table changed.
        """
        message = self.refusal('protenix-v2-int8')
        self.assertIn('That limit is measured', message)
        self.assertNotIn('placeholder', message)

    def testV2QuotesItsOwnPeakAndNotBases(self):
        """The regression itself, and it survives the caps being equal.

        base and v2 now stop at the same length, so a refusal that still reached for
        base's table would produce a message that LOOKS right -- same cap, same shape,
        wrong gigabytes. Only the peak distinguishes them.
        """
        from pymol.predictors.protenix import MEASURED_PEAK_MIB, V2_MAX_RESIDUES
        peak = dict(MEASURED_PEAK_MIB['v2'])[V2_MAX_RESIDUES]
        message = self.refusal('protenix-v2-int8')
        self.assertIn('%.1f GiB' % (peak / 1024.0), message)
        for _, other in MEASURED_PEAK_MIB['base']:
            self.assertNotIn(str(other), message, other)
        self.assertNotIn('8.6 GB', message)

    def testTheTwoVariantsQuoteDifferentPeaks(self):
        """The sharpest form of #316: same sentence, same cap, different numbers.

        If these two ever agree, something is reading one table for both packs again --
        which is the whole bug, and it would be invisible in any test that only checked
        one of them.
        """
        self.assertNotEqual(self.refusal('protenix-base-int8'),
                            self.refusal('protenix-v2-int8'))

    def testV2IsMeasuredHigherThanBaseAtItsCap(self):
        """Not a message test: the reason the two tables cannot be shared.

        A 256-wide pair track against base's 128 roughly doubles the N^2 term, and the
        sweep bears it out at every length. If this ever inverts, the v2 row was
        mis-transcribed, and mis-transcribed downward is the direction that kills
        sessions.
        """
        from pymol.predictors.protenix import MEASURED_PEAK_MIB
        base = dict(MEASURED_PEAK_MIB['base'])
        for residues, peak in MEASURED_PEAK_MIB['v2']:
            if residues in base:
                self.assertGreater(peak, base[residues], residues)

    def testEveryPackNamesItselfAndItsOwnCap(self):
        """Six ids, two caps -- the header has to come from the pack that refused."""
        from pymol.predictors import registry
        for pid in (i for i in registry.available() if i.startswith('protenix-')):
            message = self.refusal(pid)
            self.assertIn(pid, message, pid)
            self.assertIn('%d-residue limit' % registry.get(pid).max_residues,
                          message, pid)

    def testBothPrecisionsOfAVariantGiveTheSameRationale(self):
        """The curve is a property of the variant's shape, not of its quantisation."""
        for variant in ('base', 'v2'):
            rationales = set()
            for suffix in ('int8', 'fp16', 'bf16'):
                message = self.refusal('protenix-%s-%s' % (variant, suffix))
                rationales.add(message.split('limit. ', 1)[1])
            self.assertEqual(len(rationales), 1, variant)


class TestTheRationaleFollowsTheTableNotTheProse(testing.PyMOLTestCase):
    """`_limit_rationale` is unit-tested directly, because its whole point is that the
    day someone sweeps v2 the message corrects itself with no prose edit.

    Testing it only through v2's current one-point table would pass just as well if the
    branch were hardcoded to the variant name.
    """

    def rationale(self, table, variant, limit):
        from pymol.predictors import protenix
        saved = protenix.MEASURED_PEAK_MIB
        protenix.MEASURED_PEAK_MIB = table
        try:
            return protenix._limit_rationale(variant, limit)
        finally:
            protenix.MEASURED_PEAK_MIB = saved

    def testACapInsideTheSweepReadsAsMeasured(self):
        table = {'v2': ((60, 900), (250, 4400), (400, 7600))}
        message = self.rationale(table, 'v2', 400)
        self.assertIn('That limit is measured', message)
        self.assertIn('%.1f GiB' % (7600 / 1024.0), message)
        self.assertNotIn('placeholder', message)

    def testACapAboveTheSweepReadsAsAPlaceholder(self):
        table = {'v2': ((60, 900), (250, 4400))}
        message = self.rationale(table, 'v2', 400)
        self.assertIn('placeholder', message)
        self.assertIn('250 residues (4400 MiB peak)', message)

    def testACapExactlyAtTheLastSweptPointIsMeasured(self):
        """The boundary is <=, not <: 250 measured means 250 may be quoted as measured."""
        table = {'v2': ((60, 900), (250, 4400))}
        self.assertIn('That limit is measured', self.rationale(table, 'v2', 250))

    def testAnIntermediateCapQuotesTheHighestPointAtOrBelowIt(self):
        """Never a point ABOVE the cap: that would overstate what the cap permits."""
        table = {'base': ((60, 547), (250, 2279), (400, 3868))}
        message = self.rationale(table, 'base', 300)
        self.assertIn('at 250 residues', message)
        self.assertNotIn('3868', message)

    def testAVariantWithNoSweepAtAllSaysSo(self):
        """Not "measured", and not a confident-sounding number either."""
        message = self.rationale({'base': ((60, 547),)}, 'mystery', 250)
        self.assertIn('no memory sweep exists', message)
        self.assertNotIn('That limit is measured', message)

    def testAVariantWithNoRecordedReasonStillRefusesCleanly(self):
        """_UNMEASURED_CAP_REASON is an optional annotation, not a required one."""
        table = {'mini': ((15, 400),)}
        message = self.rationale(table, 'mini', 250)
        self.assertIn('placeholder', message)
        self.assertIn('15 residues (400 MiB peak)', message)


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

    def testAllSixPacksAreRegistered(self):
        self.assertEqual(len(self.ids()), 6)

    def testEveryOfferedVariantAndPrecision(self):
        expected = {'protenix-%s-%s' % (v, p)
                    for v in ('base', 'v2')
                    for p in ('int8', 'fp16', 'bf16')}
        self.assertEqual(set(self.ids()), expected)

    def testTinyAndMiniAreNotOffered(self):
        """Published upstream, deliberately not registered here.

        Five diffusion steps does not converge the geometry: at a fixed seed tiny gives
        CA-CA 3.26 A against base's 3.67 and an ideal 3.80, loose enough that DSSP stops
        calling helices. Fast is not a virtue on its own -- a fold nobody should trust is
        not worth 11 seconds either, and offering it invites exactly that.
        """
        for variant in ('tiny', 'mini'):
            for precision in ('int8', 'fp16', 'bf16'):
                self.assertNotIn('protenix-%s-%s' % (variant, precision), self.ids())

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

    def testNeitherCapOutrunsItsOwnSweep(self):
        """The one invariant that survives a cap moving: it may reach the data, not pass it.

        This replaces an assertion that v2's cap was strictly LOWER than base's, which was
        true only while v2 was unswept and stopped being true the moment it was measured
        to the same length. What must hold forever is that a cap is a measurement.
        """
        from pymol.predictors import registry
        from pymol.predictors.protenix import (MAX_RESIDUES, MEASURED_PEAK_MIB,
                                               V2_MAX_RESIDUES)
        for variant, cap in (('base', MAX_RESIDUES), ('v2', V2_MAX_RESIDUES)):
            swept = max(residues for residues, _ in MEASURED_PEAK_MIB[variant])
            self.assertLessEqual(cap, swept, variant)
        self.assertEqual(registry.get('protenix-v2-int8').max_residues, V2_MAX_RESIDUES)
        self.assertEqual(registry.get('protenix-base-int8').max_residues, MAX_RESIDUES)

    def testEachPackRefusesAtItsOwnCapAndNotAnothersProtenix(self):
        """The cap is per pack, not per method, whether or not the two happen to agree."""
        from pymol.predictors import registry
        for pid in ('protenix-base-int8', 'protenix-v2-int8'):
            predictor = registry.get(pid)
            predictor.parse_spec('A' * predictor.max_residues)
            try:
                predictor.parse_spec('A' * (predictor.max_residues + 1))
            except PredictionInputError as error:
                self.assertIn(pid, str(error))
            else:
                self.fail('expected %s to refuse above its own cap' % pid)

    def testBareProtenixAliasesToV2Int8(self):
        from pymol.predictors import registry
        self.assertIs(registry.get('protenix'), registry.get('protenix-v2-int8'))

    def testBareProtenixIsNotOffered(self):
        """The alias resolves in registry.get() but must not appear in available().

        Otherwise it would both show up in Tab-completion and violate the very
        no-id-is-a-prefix-of-another invariant it exists to route around.
        """
        from pymol.predictors import registry
        self.assertNotIn('protenix', registry.available())

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

    def testEveryOfferedPackUsesTheFullSchedule(self):
        """base and v2 are both 10 recycles / 200 steps, from their own config.json.

        The shorter 4 / 5 schedule belonged to the v0.5.0 models that are no longer
        offered; nothing here should silently inherit it.
        """
        from pymol.predictors import registry
        for pid in self.ids():
            defaults = registry.get(pid).option_defaults
            self.assertEqual(defaults['recycling_steps'], 10, pid)
            self.assertEqual(defaults['diffusion_steps'], 200, pid)

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
        for variant in ('base', 'v2'):
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
        """The registry's own error is how a user discovers the id.

        Not "protenix" itself -- that bare name is now a registered alias for
        protenix-v2-int8 (see TestEveryPackIsAPredictor.testBareProtenixAliasesToV2Int8)
        -- so this uses a name that is unknown under any spelling.
        """
        from pymol.predictors import registry
        from pymol.predictors.errors import PredictorNotFound
        try:
            registry.get('protenix-nonexistent')
        except PredictorNotFound as error:
            self.assertIn('protenix-base-int8', str(error))
        else:
            self.fail('expected an unknown predictor id to raise')

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
        """Both asserted as "fetched OR already cached" -- a machine that has run a fold,
        or a prior bulk prefetch, has the pack, so asserting a download tests local state
        rather than the filter."""
        self.declareHost('boltz,protenix')
        out = cmd.predict_weights(download=1, async_=1)
        self.assertTrue(out['protenix-base-int8']['cached']
                        or 'protenix-base-mlx-int8' in self.started)
        # And the other packs, no longer filtered out, are reached as well.
        self.assertTrue(out['protenix-v2-int8']['cached']
                        or 'protenix-v2-mlx-int8' in self.started)

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
