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

    def testCancellingByObjectNameStopsEveryModel(self):
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.1}]] * 3)
        self.predicting.predict_cancel('multi', quiet=1, _self=self.cmd)
        for job in jobs:
            self.assertTrue(getattr(job, 'cancelled', False), job.job_id)

    def testCancellingByJobIdStillCancelsExactlyThatJob(self):
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.1}]] * 2)
        self.predicting.predict_cancel(jobs[0].job_id, quiet=1, _self=self.cmd)
        self.assertTrue(getattr(jobs[0], 'cancelled', False))
        self.assertFalse(getattr(jobs[1], 'cancelled', False))

    def testThePayloadCarriesTheRecordAndKeepsPendingAStringMap(self):
        """Swift decodes `pending` as [String: String]; widening it would break
        the whole PanelPayload decode and take the object list with it."""
        import json
        import os
        import tempfile
        from pymol import appkit_inspector

        self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.5}]] * 2)
        appkit_inspector.poll_panel()
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % os.getpid())
        with open(path) as handle:
            payload = json.load(handle)

        self.assertIsInstance(payload['pending']['multi'], str)
        record = payload['pending_jobs']['multi']
        self.assertEqual(record['models_total'], 2)
        for key, value in record.items():
            self.assertIsInstance(value, (str, int, float, bool, type(None)),
                                  'pending_jobs.%s is not a scalar' % key)

    def testPollPanelStillWritesAFileWhenAJobExplodes(self):
        import os
        import tempfile
        from pymol import appkit_inspector

        class Exploding(ProgressStubJob):
            def status(self):
                raise RuntimeError('boom')

        job = Exploding([])
        job.predictor_id = 'progress_stub'
        self.predicting._JOBS[job.job_id] = job
        self.predicting.register_pending('boom', job.job_id, _self=self.cmd)
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % os.getpid())
        if os.path.exists(path):
            os.remove(path)
        appkit_inspector.poll_panel()
        self.assertTrue(os.path.exists(path))

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

    def testAFailedJobIsRetainedWithItsErrorAfterThePlaceholderGoes(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'out of memory'}]])
        self.predicting.pending_info('boom', _self=self.cmd)   # observe it once
        self.predicting.discard_pending('boom', _self=self.cmd)
        info = self.predicting.pending_info('boom', _self=self.cmd)
        self.assertIsNotNone(info, 'a failed job must survive its placeholder')
        self.assertEqual(info['state'], 'failed')
        self.assertEqual(info['error'], 'out of memory')

    def testASuccessfulJobIsNotRetained(self):
        self.register('ok', [[{'state': 'done', 'phase': 'done', 'fraction': 1.0}]])
        self.predicting.pending_info('ok', _self=self.cmd)
        self.predicting.discard_pending('ok', _self=self.cmd)
        self.assertIsNone(self.predicting.pending_info('ok', _self=self.cmd))

    def testRetentionIsCapped(self):
        for index in range(20):
            name = 'boom%d' % index
            self.register(name, [[{'state': 'failed', 'phase': 'inference',
                                   'fraction': 0.0, 'error': 'x'}]])
            self.predicting.pending_info(name, _self=self.cmd)
            self.predicting.discard_pending(name, _self=self.cmd)
        self.assertLessEqual(len(self.predicting._RECENT), 16)

    def testClearPendingDropsRetainedRecords(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'x'}]])
        self.predicting.pending_info('boom', _self=self.cmd)
        self.predicting.discard_pending('boom', _self=self.cmd)
        self.predicting.clear_pending()
        self.assertEqual(self.predicting._RECENT, {})

    def testDismissRemovesARetainedCard(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'x'}]])
        self.predicting.pending_info('boom', _self=self.cmd)
        self.predicting.discard_pending('boom', _self=self.cmd)
        self.cmd.predict_dismiss('boom')
        self.assertIsNone(self.predicting.pending_info('boom', _self=self.cmd))

    def testDismissWithNoArgumentClearsThemAll(self):
        for name in ('a', 'b'):
            self.register(name, [[{'state': 'failed', 'phase': 'inference',
                                   'fraction': 0.0, 'error': 'x'}]])
            self.predicting.pending_info(name, _self=self.cmd)
            self.predicting.discard_pending(name, _self=self.cmd)
        self.cmd.predict_dismiss()
        self.assertEqual(self.predicting._RECENT, {})

    def testDismissAtQuietZeroDoesNotExplode(self):
        """parsing.py forces quiet=0 for command-line calls; a suite that only
        tests quiet=1 never enters a single message-emitting branch."""
        self.cmd.predict_dismiss('nothing-here', quiet=0)

    def testDismissIsReachableAsACommand(self):
        from pymol import keywords
        self.assertIn('predict_dismiss', keywords.get_command_keywords())

    def testDeliverResultClearsRetainedFailureRecord(self):
        """A retry that succeeds must not leave a stale failure card.

        deliver_result pops _PENDING directly (not via discard_pending), so the
        clear must live there too. Sequence: fail, verify retained, retry via
        deliver_result, verify card is gone.
        """
        import os, tempfile
        pdb = ('ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00'
               '           N\nATOM      2  CA  ALA A   1       1.458   0.000   0.000'
               '  1.00  0.00           C\nEND\n')
        fd, path = tempfile.mkstemp(suffix='.pdb')
        try:
            os.write(fd, pdb.encode())
            os.close(fd)
            # Step 1: register a failed job and retain it.
            self.register('retry', [[{'state': 'failed', 'phase': 'inference',
                                      'fraction': 0.0, 'error': 'oom'}]])
            self.predicting.pending_info('retry', _self=self.cmd)
            self.predicting.discard_pending('retry', _self=self.cmd)
            self.assertIsNotNone(self.predicting._RECENT.get('retry'),
                                 'pre-condition: failure must be retained')
            # Step 2: retry -- register a new job into the SAME name and deliver it.
            self.register('retry', [[{'state': 'done', 'phase': 'done',
                                      'fraction': 1.0}]])
            self.predicting.deliver_result(path, 'retry', _self=self.cmd)
            # All three must be clean after a successful delivery.
            self.assertIsNone(self.predicting._RECENT.get('retry'),
                              '_RECENT must be cleared on successful delivery')
            self.assertIsNone(self.predicting._LAST_INFO.get('retry'),
                              '_LAST_INFO must be cleared on successful delivery')
            self.assertIsNone(self.predicting.pending_info('retry', _self=self.cmd),
                              'pending_info must return None for a delivered object')
        finally:
            try:
                os.unlink(path)
            except Exception:
                pass

    def testDismissSpaceNameViaDirectApi(self):
        """cmd.predict_dismiss('my pred') works; cmd.do passes quotes as literals.

        FINDING: parsing.STRICT does NOT strip surrounding double-quotes from
        arguments -- cmd.do('predict_dismiss "my pred"') passes the argument as
        '"my pred"' (quotes included), not 'my pred'. Verified by sentinel-key
        probe: only the literal-quoted key was removed, not 'my pred' itself.

        The Swift error card must therefore avoid spaces in derived object names,
        OR call the Python API directly rather than through cmd.do, OR strip its
        own quotes before dispatching. The direct-API path is what every test in
        this suite (and testDismissRemovesARetainedCard above) uses, and it works
        for space-containing names.
        """
        self.register('my pred', [[{'state': 'failed', 'phase': 'inference',
                                    'fraction': 0.0, 'error': 'x'}]])
        self.predicting.pending_info('my pred', _self=self.cmd)
        self.predicting.discard_pending('my pred', _self=self.cmd)
        self.assertIsNotNone(self.predicting._RECENT.get('my pred'),
                             'pre-condition: failure must be retained')
        # Direct API: works fine for space names.
        self.cmd.predict_dismiss('my pred')
        self.assertIsNone(self.predicting._RECENT.get('my pred'),
                          'direct API must dismiss space-containing name')
        # cmd.do with quotes: STRICT passes the argument with the quotes as
        # literal characters, not stripped -- 'my pred' is NOT matched.
        self.predicting._RECENT['my pred'] = {'state': 'failed'}
        self.cmd.do('predict_dismiss "my pred"')
        # The key '"my pred"' (with quotes) would be popped, not 'my pred'.
        # Assert the actual behaviour so a future Swift fix is caught immediately.
        self.assertIsNotNone(self.predicting._RECENT.get('my pred'),
                             'cmd.do with quoted arg does NOT strip quotes in STRICT mode')
