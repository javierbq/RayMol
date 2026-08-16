"""Feeding an MSA to a predictor: the capability, the binding, and the wire (#297).

No Swift, no weights, no network. The alignments are real (testing/data/msa_toy.a3m,
loaded through cmd.load_msa) and the request JSON is really written; only inference is
stubbed, because there is nothing here that inference would decide.

The theme throughout is REFUSAL BEFORE SUBMIT. Every check in this file is one the
featurizer would also make -- but it makes it after a 505 MB weight download and
minutes of featurization, and upstream Boltz does not make it at all: it falls back to
a depth-1 dummy alignment, so every score then describes the wrong complex with
nothing in the output saying so.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_msa.py
"""
import glob
import io
import json
import os
import tempfile
from contextlib import redirect_stdout

from pymol import cmd, predicting, testing
from pymol.predictors import host, registry
from pymol.predictors.base import (MAX_MSA_DEPTH, PredictionOptions, PredictionSpec,
                                   Predictor, parse_chains)
from pymol.predictors.errors import PredictionInputError, PredictionOptionError

#: The query of testing/data/msa_toy.a3m, 24 residues deep 8.
QUERY = 'MKTAYIAKQRQISFVKSHFSRQLE'
TOY_DEPTH = 8

#: A second, unrelated 5-residue sequence, so a dimer has two DIFFERENT chains --
#: parse_chains assigns A and B by position, and two identical chains would let a
#: mis-ordered map pass.
OTHER = 'GSHMA'


class StubJob:
    """Cheap stand-in for a HostJob. Records what it was submitted with."""

    _counter = 0

    def __init__(self, spec, options):
        StubJob._counter += 1
        self.job_id = 'msastub-%d' % StubJob._counter
        self.spec = spec
        self.options = options

    def status(self):
        return {'state': 'running', 'phase': 'inference', 'fraction': 0.5,
                'error': None, 'result_path': None}

    def cancel(self):
        pass


def _stub(predictor_id, supports_msa, options=None):
    """A registered predictor with no weights, so predict() submits immediately.

    The abstract methods are defined in the class BODY rather than patched on
    afterwards: ABCMeta computes __abstractmethods__ at class creation, so a method
    assigned later leaves the class uninstantiable.
    """

    class Stub(Predictor):
        id = predictor_id
        name = 'Stub (%s)' % predictor_id
        weight_bundle = None
        option_defaults = options if options is not None else {
            'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

        def check_available(self):
            return None

        def parse_spec(self, sequence, name=''):
            return PredictionSpec(parse_chains(sequence), name)

        def submit(self, spec, options, weights_path):
            return StubJob(spec, options)

    Stub.supports_msa = supports_msa
    return registry.register(Stub(), replace=True)


class MSAPredictTestCase(testing.PyMOLTestCase):
    """Shared fixture: a clean alignment store and a clean registry. No tests."""

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.msas import store
        self._saved_registry = dict(registry._REGISTRY)
        store.clear()
        self.addCleanup(store.clear)

    def tearDown(self):
        predicting._JOBS.clear()
        predicting._PENDING.clear()
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved_registry)
        testing.PyMOLTestCase.tearDown(self)

    def load_toy(self, name, target='', chain=''):
        """The toy alignment under `name`, optionally attached."""
        cmd.load_msa(self.datafile('msa_toy.a3m'), name, target, chain)
        from pymol.msas import store
        return store.get(name)

    def quiet_predict(self, *args, **kwargs):
        """cmd.predict with its output captured, returned as (job, printed)."""
        buf = io.StringIO()
        with redirect_stdout(buf):
            job = cmd.predict(*args, **kwargs)
        return job, buf.getvalue()


class CapabilityTest(MSAPredictTestCase):
    """`supports_msa` on the base class -- the pluggable part."""

    def testTheDefaultIsThatAMethodCannotUseAnAlignment(self):
        """False by default, so a new predictor refuses until it opts in. The other
        way round, a method that forgot to declare anything would accept an alignment
        and quietly not use it."""
        self.assertFalse(Predictor.supports_msa)

    def testBoltz2DeclaresSupportAndTheDepthLever(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        self.assertTrue(Boltz2Predictor.supports_msa)
        self.assertEqual(Boltz2Predictor.option_defaults['msa_depth'], MAX_MSA_DEPTH)

    def testSupportIsInheritedByASubclassThatOverridesOnlyItsWeights(self):
        """The whole point of putting it on the class: boltz2-bf16 differs from boltz2
        only in weight_bundle, and must not have to restate a capability."""
        from pymol.predictors.boltz2_bf16 import Boltz2BF16Predictor
        self.assertTrue(Boltz2BF16Predictor.supports_msa)
        self.assertEqual(Boltz2BF16Predictor.option_defaults['msa_depth'],
                         MAX_MSA_DEPTH)

    def testTheTemplateCarriesTheAttribute(self):
        """A new predictor copied from the template starts out refusing, explicitly,
        rather than inheriting the default silently."""
        from pymol.predictors import _template
        self.assertIn('supports_msa', vars(_template.TemplatePredictor))
        self.assertFalse(_template.TemplatePredictor.supports_msa)

    def testAMethodWithoutSupportRefusesByNameNotWithATypeError(self):
        _stub('nomsa', supports_msa=False)
        self.load_toy('toy')
        with self.assertRaises(PredictionInputError) as caught:
            cmd.predict('nomsa', QUERY, msa='toy')
        message = str(caught.exception)
        self.assertIn('nomsa', message)
        self.assertIn('toy', message)

    def testRefusalSaysWhyRatherThanJustNo(self):
        """The reason is the point: it would fold single-sequence and say nothing."""
        _stub('nomsa', supports_msa=False)
        self.load_toy('toy')
        with self.assertRaises(PredictionInputError) as caught:
            cmd.predict('nomsa', QUERY, msa='toy')
        self.assertIn('single-sequence', str(caught.exception))

    def testAMethodWithoutSupportIsUnaffectedWhenNoAlignmentIsAsked(self):
        """Refusal is about alignments, not about the method. Nothing changes for the
        predictions that were always single-sequence."""
        _stub('nomsa', supports_msa=False)
        job, _ = self.quiet_predict('nomsa', QUERY)
        self.assertEqual(job.spec.alignments, {})

    def testAMethodWithoutSupportRejectsTheDepthLeverByName(self):
        _stub('nomsa', supports_msa=False)
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.predict('nomsa', QUERY, msa_depth=128)
        self.assertIn('msa_depth', str(caught.exception))


class BindAlignmentsTest(MSAPredictTestCase):
    """The base implementation of bind_alignments: what every method checks."""

    def setUp(self):
        MSAPredictTestCase.setUp(self)
        self.predictor = _stub('msa', supports_msa=True)

    def testAMatchingQueryBinds(self):
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p')
        self.predictor.bind_alignments(spec, {'A': toy})
        self.assertEqual(spec.alignments, {'A': toy})

    def testAnEmptyMapLeavesTheSpecSingleSequence(self):
        spec = PredictionSpec((('A', QUERY),), 'p')
        self.predictor.bind_alignments(spec, {})
        self.assertEqual(spec.alignments, {})

    def testAnEmptyMapIsNotRefusedEvenByAMethodWithoutSupport(self):
        """`supports_msa` gates alignments, not calls. Otherwise every predict on a
        single-sequence method would have to know not to call this."""
        nomsa = _stub('nomsa', supports_msa=False)
        spec = PredictionSpec((('A', QUERY),), 'p')
        nomsa.bind_alignments(spec, {})
        self.assertEqual(spec.alignments, {})

    def testAChainThatIsNotInTheSpecIsRefused(self):
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p')
        with self.assertRaises(PredictionInputError) as caught:
            self.predictor.bind_alignments(spec, {'B': toy})
        self.assertIn('chain B', str(caught.exception))

    def testAQueryOfTheWrongLengthIsRefusedAndSaysSo(self):
        """The common cause is not a wrong file but a structure missing its
        unobserved residues, so the message leads with the two lengths."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY + 'GG'),), 'p')
        with self.assertRaises(PredictionInputError) as caught:
            self.predictor.bind_alignments(spec, {'A': toy})
        message = str(caught.exception)
        self.assertIn('%d-residue query' % len(QUERY), message)
        self.assertIn('%d residues' % (len(QUERY) + 2), message)

    def testAQueryOfTheRightLengthThatDiffersNamesTheResidue(self):
        toy = self.load_toy('toy')
        mutated = 'W' + QUERY[1:]
        spec = PredictionSpec((('A', mutated),), 'p')
        with self.assertRaises(PredictionInputError) as caught:
            self.predictor.bind_alignments(spec, {'A': toy})
        message = str(caught.exception)
        self.assertIn('residue 1', message)
        self.assertIn('W', message)

    def testBindingIsRefusedBeforeAnythingIsSubmitted(self):
        """Nothing is created for a refused alignment -- no job, no placeholder."""
        self.load_toy('toy')
        with self.assertRaises(PredictionInputError):
            cmd.predict('msa', 'W' + QUERY[1:], msa='toy')
        self.assertEqual(predicting._JOBS, {})
        self.assertEqual(predicting.pending_objects(), {})

    def testMixedIsTheDesignCaseNotAnEdgeCase(self):
        """A real alignment for the target and none for the binder: the map has ONE
        entry, not two, and the other chain gets the host's depth-1 dummy."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY), ('B', OTHER)), 'p')
        self.predictor.bind_alignments(spec, {'A': toy})
        self.assertEqual(list(spec.alignments), ['A'])


class MSAArgumentTest(MSAPredictTestCase):
    """`msa=`: positional slots, one per chain, '/'-separated."""

    def setUp(self):
        MSAPredictTestCase.setUp(self)
        _stub('msa', supports_msa=True,
              options={'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0,
                       'msa_depth': MAX_MSA_DEPTH})

    def testOneSlotForOneChain(self):
        toy = self.load_toy('toy')
        job, _ = self.quiet_predict('msa', QUERY, msa='toy')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testSlotsAreAssignedByPosition(self):
        first = self.load_toy('first')
        second = self.load_toy('second')
        # Both chains are the same sequence here on purpose -- the assertion is about
        # WHICH alignment landed on which chain, not about the sequences.
        job, _ = self.quiet_predict('msa', '%s/%s' % (QUERY, QUERY),
                                    msa='first/second')
        self.assertEqual(job.spec.alignments, {'A': first, 'B': second})

    def testAnEmptySlotFoldsThatChainSingleSequence(self):
        toy = self.load_toy('toy')
        job, _ = self.quiet_predict('msa', '%s/%s' % (OTHER, QUERY), msa='/toy')
        self.assertEqual(job.spec.alignments, {'B': toy})

    def testTrailingSlotsMayBeOmitted(self):
        toy = self.load_toy('toy')
        job, _ = self.quiet_predict('msa', '%s/%s' % (QUERY, OTHER), msa='toy')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testMoreSlotsThanChainsIsRefused(self):
        self.load_toy('toy')
        with self.assertRaises(PredictionInputError) as caught:
            cmd.predict('msa', QUERY, msa='toy/toy')
        message = str(caught.exception)
        self.assertIn('2', message)
        self.assertIn('1 chain', message)

    def testAnUnknownAlignmentNamesTheChainItWasAskedFor(self):
        """With several slots, "no alignment named 'x'" alone does not say which one
        of them was wrong."""
        self.load_toy('toy')
        with self.assertRaises(PredictionInputError) as caught:
            cmd.predict('msa', '%s/%s' % (QUERY, OTHER), msa='toy/nope')
        message = str(caught.exception)
        self.assertIn('chain B', message)
        self.assertIn('nope', message)

    def testWhitespaceAroundASlotIsIgnored(self):
        toy = self.load_toy('toy')
        job, _ = self.quiet_predict('msa', '%s/%s' % (QUERY, OTHER), msa=' toy / ')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testAnExplicitArgumentOverridesWhatIsAttached(self):
        """Attachment is a default, not a lock."""
        cmd.fab(QUERY, 'target', chain='A')
        self.load_toy('attached', 'target', 'A')
        explicit = self.load_toy('explicit')
        job, _ = self.quiet_predict('msa', 'target', msa='explicit')
        self.assertEqual(job.spec.alignments, {'A': explicit})

    def testAllEmptySlotsMeanSingleSequenceEvenWithSomethingAttached(self):
        """`msa=/` is not the same as omitting `msa`. Asking for no alignment is an
        explicit request and beats an attachment, rather than being read as an empty
        argument and falling back."""
        cmd.fab(QUERY, 'target', chain='A')
        cmd.fab(OTHER, 'binder', chain='B')
        self.load_toy('attached', 'target', 'A')
        job, _ = self.quiet_predict('msa', 'target or binder', msa='/')
        self.assertEqual(job.spec.alignments, {})


class AttachmentTest(MSAPredictTestCase):
    """Omitting `msa=` uses whatever is attached to the object each chain came from."""

    def setUp(self):
        MSAPredictTestCase.setUp(self)
        _stub('msa', supports_msa=True)

    def testAnAttachedAlignmentIsUsedWithoutBeingNamed(self):
        cmd.fab(QUERY, 'target', chain='A')
        toy = self.load_toy('toy', 'target', 'A')
        job, _ = self.quiet_predict('msa', 'target')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testASelectionOfTheAttachedChainStillFindsIt(self):
        """The match is on the (object, chain) the residues were READ from, so it
        survives being reached through a selection rather than the object name."""
        cmd.fab(QUERY, 'target', chain='A')
        toy = self.load_toy('toy', 'target', 'A')
        job, _ = self.quiet_predict('msa', 'target and polymer')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testALiteralSequenceNeverPicksUpAnAttachment(self):
        """There is no object to have attached one to. Folding the same residues as
        text is a different, deliberately unadorned request."""
        cmd.fab(QUERY, 'target', chain='A')
        self.load_toy('toy', 'target', 'A')
        job, _ = self.quiet_predict('msa', QUERY)
        self.assertEqual(job.spec.alignments, {})

    def testAnAlignmentAttachedToAnotherObjectIsNotUsed(self):
        cmd.fab(QUERY, 'target', chain='A')
        cmd.fab(QUERY, 'other', chain='A')
        self.load_toy('toy', 'other', 'A')
        job, _ = self.quiet_predict('msa', 'target')
        self.assertEqual(job.spec.alignments, {})

    def testAnUnattachedAlignmentIsNotUsed(self):
        cmd.fab(QUERY, 'target', chain='A')
        self.load_toy('toy')
        job, _ = self.quiet_predict('msa', 'target')
        self.assertEqual(job.spec.alignments, {})

    def testADanglingAttachmentIsSimplyNotFound(self):
        """An attachment is by name and does not follow a delete (#296). A row
        pointing at nothing must not break the prediction of something else."""
        cmd.fab(QUERY, 'ghost', chain='A')
        self.load_toy('toy', 'ghost', 'A')
        cmd.delete('ghost')
        cmd.fab(QUERY, 'target', chain='A')
        job, _ = self.quiet_predict('msa', 'target')
        self.assertEqual(job.spec.alignments, {})

    def testTwoAlignmentsOnOneChainAreRefusedRatherThanPicked(self):
        """Two alignments of one chain are two different searches. Folding with
        whichever loaded first would make the result depend on load order."""
        cmd.fab(QUERY, 'target', chain='A')
        self.load_toy('first', 'target', 'A')
        self.load_toy('second', 'target', 'A')
        with self.assertRaises(PredictionInputError) as caught:
            cmd.predict('msa', 'target')
        message = str(caught.exception)
        self.assertIn('first', message)
        self.assertIn('second', message)
        self.assertIn('msa=', message)

    def testOnlyTheAttachedChainOfADimerGetsOne(self):
        cmd.fab(QUERY, 'complex', chain='A')
        cmd.fab(OTHER, 'binder', chain='B')
        toy = self.load_toy('toy', 'complex', 'A')
        job, _ = self.quiet_predict('msa', 'complex or binder')
        self.assertEqual(job.spec.alignments, {'A': toy})

    def testAnAttachmentIsCheckedAgainstTheSequenceBeingFolded(self):
        """Attaching validated against the whole chain; folding a FRAGMENT of it is a
        different sequence, and the alignment no longer applies to it."""
        cmd.fab(QUERY, 'target', chain='A')
        self.load_toy('toy', 'target', 'A')
        with self.assertRaises(PredictionInputError):
            cmd.predict('msa', 'target and resi 1-10')


class DepthOptionTest(MSAPredictTestCase):
    """`msa_depth`: the memory lever, and the one option that is not an accelerator."""

    def setUp(self):
        MSAPredictTestCase.setUp(self)
        _stub('msa', supports_msa=True,
              options={'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0,
                       'msa_depth': MAX_MSA_DEPTH})

    def testTheDefaultIsTheCeilingAndIsNotSilentlyClamped(self):
        job, _ = self.quiet_predict('msa', QUERY)
        self.assertEqual(job.options.msa_depth, MAX_MSA_DEPTH)

    def testAnExplicitDepthIsCarried(self):
        job, _ = self.quiet_predict('msa', QUERY, msa_depth=64)
        self.assertEqual(job.options.msa_depth, 64)

    def testZeroIsRejected(self):
        """Not "no limit". A depth of zero would be an alignment with no rows at all,
        which the parser cannot produce and which is never what was meant."""
        self.assertRaises(PredictionOptionError, cmd.predict, 'msa', QUERY,
                          msa_depth=0)

    def testAboveTheCeilingIsRejectedRatherThanClamped(self):
        """The parser on the other side would ignore it, so accepting it would report
        a run using more of the alignment than it actually did."""
        with self.assertRaises(PredictionOptionError) as caught:
            cmd.predict('msa', QUERY, msa_depth=MAX_MSA_DEPTH + 1)
        self.assertIn(str(MAX_MSA_DEPTH), str(caught.exception))

    def testTheCeilingIsBoltzMLXsOwnMaximum(self):
        """Upstream's const.max_msa_seqs, which is what BoltzInputLimits.desktop
        admits. The two ends must agree or the value means different things."""
        self.assertEqual(MAX_MSA_DEPTH, 16384)

    def testDepthIsIndependentOfWhetherAnAlignmentIsUsed(self):
        """It is an option, not a consequence: setting it on a single-sequence run is
        pointless but not wrong, and rejecting it would make the option's validity
        depend on the input."""
        job, _ = self.quiet_predict('msa', QUERY, msa_depth=32)
        self.assertEqual(job.spec.alignments, {})
        self.assertEqual(job.options.msa_depth, 32)


class ReportingTest(MSAPredictTestCase):
    """What was folded with what, printed whatever `quiet` says."""

    def setUp(self):
        MSAPredictTestCase.setUp(self)
        _stub('msa', supports_msa=True,
              options={'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0,
                       'msa_depth': MAX_MSA_DEPTH})

    def testTheAlignmentAndItsDepthArePrintedEvenWhenQuiet(self):
        """With the attachment path the alignment used need not appear in the command
        at all, so a run whose inputs cannot be recovered from its output is the
        default unless this is unconditional."""
        self.load_toy('toy')
        _, printed = self.quiet_predict('msa', QUERY, msa='toy', quiet=1)
        self.assertIn('toy', printed)
        self.assertIn(str(TOY_DEPTH), printed)

    def testItIsPrintedWhenNotQuietToo(self):
        self.load_toy('toy')
        _, printed = self.quiet_predict('msa', QUERY, msa='toy', quiet=0)
        self.assertIn('toy', printed)

    def testASingleSequenceRunSaysNothingAboutAlignments(self):
        """Every prediction was single-sequence before this existed; a line saying so
        on every run is noise."""
        _, printed = self.quiet_predict('msa', QUERY, quiet=1)
        self.assertNotIn('alignment', printed)

    def testAChainWithoutOneIsNamedAsSingleSequence(self):
        """In a mixed run the chain that did NOT get one is the interesting half."""
        self.load_toy('toy')
        _, printed = self.quiet_predict('msa', '%s/%s' % (QUERY, OTHER), msa='toy')
        self.assertIn('B single-sequence', printed)

    def testTruncationIsReportedRatherThanSilent(self):
        """Depth is the largest determinant of runtime and peak memory, so a run that
        used 4 of 8 rows must not report 8."""
        self.load_toy('toy')
        _, printed = self.quiet_predict('msa', QUERY, msa='toy', msa_depth=4)
        self.assertIn('4 of %d' % TOY_DEPTH, printed)

    def testAnUntruncatedAlignmentReportsItsWholeDepth(self):
        self.load_toy('toy')
        _, printed = self.quiet_predict('msa', QUERY, msa='toy',
                                        msa_depth=TOY_DEPTH)
        self.assertIn('%d sequences' % TOY_DEPTH, printed)
        self.assertNotIn(' of ', printed)


class MarkerWatcher(io.StringIO):
    """Captures stdout, snapshotting the a3m files the moment the marker is printed.

    The ordering claim -- every a3m is COMPLETE on disk before the request that names
    it is announced -- cannot be checked after the fact, because by then both are
    true. Reading the temp dir from inside the write that carries the marker is the
    only point at which the two can be observed apart.
    """

    def __init__(self):
        io.StringIO.__init__(self)
        self.at_marker = None

    def write(self, text):
        if 'PREDICT:submit' in text and self.at_marker is None:
            self.at_marker = {}
            pattern = os.path.join(tempfile.gettempdir(),
                                   'raymol_predict_msa_*.a3m')
            for path in glob.glob(pattern):
                try:
                    with open(path) as handle:
                        self.at_marker[path] = handle.read()
                except OSError:
                    self.at_marker[path] = None
        return io.StringIO.write(self, text)


class WireTest(MSAPredictTestCase):
    """The request JSON and the a3m files beside it."""

    def submit(self, spec, options=None):
        """host.submit with stdout watched. Returns (job, MarkerWatcher)."""
        watcher = MarkerWatcher()
        with redirect_stdout(watcher):
            job = host.submit(spec, options or PredictionOptions(), '/tmp/weights')
        self.addCleanup(job._discard_inputs)
        return job, watcher

    def request(self, job):
        with open(job.request_path) as handle:
            return json.load(handle)

    def testAlignmentsAreCarriedAsPathsNotInlineText(self):
        """An a3m is megabytes; base64 inside a JSON the host reads in one gulp buys
        nothing over a file it streams."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p', {'A': toy})
        job, _ = self.submit(spec)
        entries = self.request(job)['alignments']
        self.assertEqual([e['chain'] for e in entries], ['A'])
        self.assertTrue(entries[0]['a3m_path'].endswith('.a3m'))

    def testTheA3mOnDiskIsByteIdenticalToWhatWasLoaded(self):
        """boltz-mlx's parser reproduces two upstream bugs on purpose and reads
        insertions as lowercase runs, so the bytes that reach it have to be the bytes
        that were loaded."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p', {'A': toy})
        job, _ = self.submit(spec)
        with open(job.a3m_paths['A']) as handle:
            self.assertEqual(handle.read(), toy.a3m)

    def testEveryA3mIsCompleteBeforeTheMarkerIsPrinted(self):
        """The request is what ANNOUNCES the a3m, and the host reads on its next
        100 ms tick -- so a request naming a half-written file is the one ordering bug
        available here."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p', {'A': toy})
        job, watcher = self.submit(spec)
        self.assertIsNotNone(watcher.at_marker)
        self.assertEqual(watcher.at_marker.get(job.a3m_paths['A']), toy.a3m)

    def testMixedCarriesOneEntryNotTwo(self):
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY), ('B', OTHER)), 'p', {'A': toy})
        job, _ = self.submit(spec)
        self.assertEqual(len(self.request(job)['alignments']), 1)

    def testASingleSequenceRunCarriesAnEmptyList(self):
        """Present and empty rather than absent: the host's field is optional for
        backward compatibility, and this is not the case that exercises it."""
        job, _ = self.submit(PredictionSpec((('A', QUERY),), 'p'))
        self.assertEqual(self.request(job)['alignments'], [])

    def testTheDepthLeverCrossesTheWire(self):
        job, _ = self.submit(PredictionSpec((('A', QUERY),), 'p'),
                             PredictionOptions(msa_depth=64))
        self.assertEqual(self.request(job)['msa_depth'], 64)

    def testEachChainGetsItsOwnFile(self):
        first = self.load_toy('first')
        second = self.load_toy('second')
        spec = PredictionSpec((('A', QUERY), ('B', QUERY)), 'p',
                              {'A': first, 'B': second})
        job, _ = self.submit(spec)
        self.assertEqual(len(set(job.a3m_paths.values())), 2)

    def testSettlingRemovesTheAlignmentsAndTheRequest(self):
        """An alignment is megabytes and a session can submit many jobs, so leaving
        them for the OS to reap eventually is not good enough."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p', {'A': toy})
        job, _ = self.submit(spec)
        path = job.a3m_paths['A']
        with open(job.status_path, 'w') as handle:
            json.dump({'state': 'done', 'phase': 'done', 'fraction': 1.0,
                       'error': None, 'result_path': '/tmp/out.pdb'}, handle)
        self.addCleanup(lambda: os.path.exists(job.status_path)
                        and os.unlink(job.status_path))
        job.status()
        self.assertFalse(os.path.exists(path))
        self.assertFalse(os.path.exists(job.request_path))

    def testARunningJobKeepsItsAlignments(self):
        """The host reads the a3m during featurize, which reports `running`. Cleaning
        up on anything but a TERMINAL status would race the reader."""
        toy = self.load_toy('toy')
        spec = PredictionSpec((('A', QUERY),), 'p', {'A': toy})
        job, _ = self.submit(spec)
        with open(job.status_path, 'w') as handle:
            json.dump({'state': 'running', 'phase': 'featurize', 'fraction': 0.0,
                       'error': None, 'result_path': None}, handle)
        self.addCleanup(os.unlink, job.status_path)
        job.status()
        self.assertTrue(os.path.exists(job.a3m_paths['A']))


class EndToEndTest(MSAPredictTestCase):
    """From `load_msa` to a request on disk, the way a user would drive it."""

    def testFoldAnObjectWithItsAttachedAlignment(self):
        _stub('msa', supports_msa=True,
              options={'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0,
                       'msa_depth': MAX_MSA_DEPTH})
        cmd.fab(QUERY, 'target', chain='A')
        cmd.load_msa(self.datafile('msa_toy.a3m'), 'toy', 'target', 'A')

        buf = io.StringIO()
        with redirect_stdout(buf):
            job = cmd.predict('msa', 'target')
        # The alignment was found without being named, and reported for being so.
        self.assertEqual(list(job.spec.alignments), ['A'])
        self.assertIn('toy', buf.getvalue())

    def testTheRealHostWireForAnAttachedAlignment(self):
        """Same path, but submitting through host.submit rather than a stub, so the
        request that lands on disk is the real one."""
        from pymol.msas import store

        cmd.fab(QUERY, 'target', chain='A')
        cmd.load_msa(self.datafile('msa_toy.a3m'), 'toy', 'target', 'A')
        sequence, sources = predicting.resolve_input('target')
        spec = PredictionSpec(parse_chains(sequence), 'out')
        alignments = predicting.alignments_from_attachments(sources, spec.chains)
        spec.alignments = alignments

        with redirect_stdout(io.StringIO()):
            job = host.submit(spec, PredictionOptions(), '/tmp/w')
        self.addCleanup(job._discard_inputs)
        with open(job.request_path) as handle:
            request = json.load(handle)
        self.assertEqual(request['alignments'][0]['chain'], 'A')
        with open(request['alignments'][0]['a3m_path']) as handle:
            self.assertEqual(handle.read(), store.get('toy').a3m)
