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


class ProgressStubJob:
    """A job whose status is scripted, and which counts how often it is read.

    predict_api.StubJob returns a fixed terminal status that ~15 existing tests
    assert on, so it must not be modified -- this is its progress-aware sibling.
    """

    _counter = 0

    def __init__(self, statuses):
        ProgressStubJob._counter += 1
        self.job_id = 'progress-%d' % ProgressStubJob._counter
        self.statuses = list(statuses)
        self.status_calls = 0

    def status(self):
        self.status_calls += 1
        return self.statuses[min(self.status_calls - 1, len(self.statuses) - 1)]

    def cancel(self):
        self.cancelled = True


class TestPendingInfo(testing.PyMOLTestCase):

    def setUp(self):
        super(TestPendingInfo, self).setUp()
        from pymol import cmd, predicting
        from pymol.predictors import registry
        from pymol.predictors.base import Predictor, PredictionSpec, parse_chains
        self.cmd = cmd

        class ProgressStub(Predictor):
            id = 'progress_stub'
            name = 'Progress stub'
            progress_phases = (('featurize', 0.00, 0.03),
                               ('load', 0.03, 0.10),
                               ('inference', 0.10, 0.10),
                               ('diffusion', 0.40, 0.97),
                               ('done', 1.00, 1.00))

            def check_available(self):
                return None

            def parse_spec(self, sequence, name=''):
                return PredictionSpec(parse_chains(sequence), name)

            def submit(self, spec, options, weights_path):
                raise AssertionError('tests register jobs directly')

        registry.register(ProgressStub(), replace=True)
        self.predicting = predicting

    def tearDown(self):
        from pymol.predictors import registry
        self.predicting.clear_pending()
        self.predicting._JOBS.clear()
        registry.unregister('progress_stub')
        self.cmd.delete('all')
        super(TestPendingInfo, self).tearDown()

    def register(self, name, statuses_per_job):
        jobs = []
        for statuses in statuses_per_job:
            job = ProgressStubJob(statuses)
            job.predictor_id = 'progress_stub'
            self.predicting._JOBS[job.job_id] = job
            self.predicting.register_pending(name, job.job_id, _self=self.cmd)
            jobs.append(job)
        return jobs

    def testOnlyOneStatusIsReadPerPendingObjectPerPoll(self):
        """n_models can be 20; the poll runs on the main thread every 500 ms."""
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.5}]] * 5)
        self.predicting.pending_info('multi', _self=self.cmd)
        self.assertEqual(sum(j.status_calls for j in jobs), 1)

    def testProgressIsFoldedAcrossModels(self):
        self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.0}]] * 3)
        info = self.predicting.pending_info('multi', _self=self.cmd)
        self.assertEqual(info['models_total'], 3)
        self.assertEqual(info['models_done'], 0)
        # first model at band floor 0.40, folded over 3 -> ~0.133
        self.assertAlmostEqual(info['fraction'], 0.40 / 3, places=3)
        self.assertIn('model 1 of 3', info['detail'])

    def testTheComposedFractionNeverDecreases(self):
        """The real cold sequence dips at 'queued' and again on cancel."""
        self.register('mono', [[{'phase': 'featurize', 'fraction': 1.0},
                                {'phase': 'load', 'fraction': 1.0},
                                {'phase': 'diffusion', 'fraction': 0.5},
                                {'phase': 'queued', 'fraction': 0.0},
                                {'phase': 'diffusion', 'fraction': 0.0}]])
        seen = []
        for _ in range(5):
            seen.append(self.predicting.pending_info('mono', _self=self.cmd)['fraction'])
        for earlier, later in zip(seen, seen[1:]):
            self.assertGreaterEqual(later, earlier, seen)

    def testAJobWhoseStatusRaisesStillProducesARecord(self):
        class Exploding(ProgressStubJob):
            def status(self):
                raise RuntimeError('boom')

        job = Exploding([])
        job.predictor_id = 'progress_stub'
        self.predicting._JOBS[job.job_id] = job
        self.predicting.register_pending('boom', job.job_id, _self=self.cmd)
        info = self.predicting.pending_info('boom', _self=self.cmd)
        self.assertEqual(info['state'], 'running')
        self.assertIsNone(info['fraction'])
        self.assertFalse(info['moving'])

    def testPendingDetailKeepsItsDocumentedPrefix(self):
        """predict_weights_async and predict_autoload assert on this string."""
        self.register('mono', [[{'phase': 'diffusion', 'fraction': 0.5}]])
        self.assertTrue(
            self.predicting.pending_detail('mono', _self=self.cmd).startswith('pending'))

    def testPendingDetailIsNoneForAnUnknownName(self):
        self.assertIsNone(self.predicting.pending_detail('nope', _self=self.cmd))

    def testFloorIsRetiredOnDiscardSoReRunCountsFromOne(self):
        """discard_pending (the failure / cancel path) must retire the floor."""
        self.register('again', [[{'phase': 'done', 'fraction': 1.0}]])
        self.predicting.discard_pending('again', _self=self.cmd)
        self.register('again', [[{'phase': 'featurize', 'fraction': 0.0}]] * 2)
        info = self.predicting.pending_info('again', _self=self.cmd)
        self.assertEqual(info['models_total'], 2)
        self.assertIn('model 1 of 2', info['detail'])

    def testDeliverResultBumpsModelsDoneAndFloorIsRetiredOnCompletion(self):
        """deliver_result's track['done'] += 1 path and its _TRACK.pop on last model."""
        import os, tempfile
        pdb = ('ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00'
               '           N\nATOM      2  CA  ALA A   1       1.458   0.000   0.000'
               '  1.00  0.00           C\nEND\n')
        fd, path = tempfile.mkstemp(suffix='.pdb')
        try:
            os.write(fd, pdb.encode())
            os.close(fd)
            self.register('twomodel', [[{'phase': 'done', 'fraction': 1.0}]] * 2)
            # Deliver first model.
            self.predicting.deliver_result(path, 'twomodel', _self=self.cmd)
            info = self.predicting.pending_info('twomodel', _self=self.cmd)
            # (a) models_done advances and the object is still pending.
            self.assertEqual(info['models_done'], 1)
            self.assertEqual(info['models_total'], 2)
            self.assertIn('model 2 of 2', info['detail'])
            # Deliver second model -- clears _PENDING and _TRACK.
            self.predicting.deliver_result(path, 'twomodel', _self=self.cmd)
            self.assertIsNone(self.predicting.pending_info('twomodel', _self=self.cmd))
            # (b) Re-run: should report model 1 of 2, not model 1 of 4.
            self.register('twomodel', [[{'phase': 'featurize', 'fraction': 0.0}]] * 2)
            info2 = self.predicting.pending_info('twomodel', _self=self.cmd)
            self.assertEqual(info2['models_total'], 2)
            self.assertIn('model 1 of 2', info2['detail'])
        finally:
            try:
                os.unlink(path)
            except Exception:
                pass

    def testDeferredJobCarriesPercentageViaPredicatorFallback(self):
        """_DeferredJob.__slots__ blocks predictor_id; _job_progress must fall back
        to _predictor so fractions for in-flight phases are not silently dropped."""
        from pymol.predictors import registry

        class FakeDeferred:
            """Simulates _DeferredJob: has _predictor but predictor_id is absent."""
            def __init__(self, predictor):
                self.job_id = 'fake-deferred-fallback'
                self._predictor = predictor
            def status(self):
                # 'diffusion' is in ProgressStub.progress_phases with a wide band.
                return {'state': 'running', 'phase': 'diffusion', 'fraction': 0.5}

        stub_predictor = registry.get('progress_stub')
        job = FakeDeferred(stub_predictor)
        # Deliberately do NOT set job.predictor_id -- simulates __slots__ blocking it.
        self.predicting._JOBS[job.job_id] = job
        self.predicting.register_pending('deferred', job.job_id, _self=self.cmd)
        info = self.predicting.pending_info('deferred', _self=self.cmd)
        self.assertIsNotNone(info['fraction'])
        self.assertTrue(info['moving'])
        self.assertIn('%', info['detail'])
