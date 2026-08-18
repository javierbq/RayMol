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

    def testANonFiniteFractionIsRejectedNotClamped(self):
        """The clamp does NOT catch these: min(max(nan, 0.0), 1.0) is nan, because
        every comparison with NaN is False. NaN also serialises as invalid JSON."""
        for bad in (float('nan'), float('inf'), float('-inf')):
            self.assertEqual(self.compose('diffusion', bad), (None, False), bad)

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
                               ('trunk', 0.10, 0.40),
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

    def panel_payload(self):
        """poll_panel() once, then the JSON it wrote. Fails loudly if it wrote none."""
        import json
        import os
        import tempfile
        from pymol import appkit_inspector

        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % (os.getpid(),))
        if os.path.exists(path):
            os.remove(path)
        appkit_inspector.poll_panel()
        self.assertTrue(os.path.exists(path), 'poll_panel wrote no file at all')
        self.assertGreater(os.path.getsize(path), 0,
                           'poll_panel truncated the file to zero bytes')
        with open(path) as handle:
            return json.load(handle)

    def testARetainedRecordIsNotListedAsPending(self):
        """`pending` disables the enable-toggle and greys the row. A retained
        terminal record belongs to a real object that may already carry a landed
        model, so listing it there kills a live structure's checkbox."""
        self.register('kept', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'model 2 failed'}]])
        self.predicting.discard_pending('kept', _self=self.cmd)
        self.assertIn('kept', self.predicting._RECENT, 'pre-condition: retained')
        # Give the name real atoms, exactly as model 1 landing would.
        self.cmd.fragment('ala', 'kept')

        payload = self.panel_payload()
        self.assertNotIn('kept', payload['pending'],
                         'a retained record must not grey out a real object')
        self.assertIn('kept', payload['pending_jobs'],
                      'the tray still needs the record to say why it failed')
        self.assertEqual(payload['pending_jobs']['kept']['error'], 'model 2 failed')

    def testARunningJobIsStillListedAsPending(self):
        """The other half of the same invariant: a live job MUST be in both."""
        self.register('live', [[{'phase': 'diffusion', 'fraction': 0.5}]])
        payload = self.panel_payload()
        self.assertIn('live', payload['pending'])
        self.assertIn('live', payload['pending_jobs'])

    # -- Unsanitised third-party status values (spec 6.6) ----------------------

    def testANonSerialisableErrorStillWritesTheWholePayload(self):
        """A predictor may put an EXCEPTION in status()['error']. Uncoerced, that
        is not JSON-serialisable: json.dumps raises after open('w') has already
        truncated the file, so the panel gets zero bytes and freezes."""
        self.register('weird', [[{'state': 'failed', 'phase': 'inference',
                                  'fraction': 0.0, 'error': ValueError('boom')}]])
        payload = self.panel_payload()
        self.assertIsInstance(payload['pending_jobs']['weird']['error'], str)
        self.assertIn('boom', payload['pending_jobs']['weird']['error'])

    def testANonStringPhaseIsCoercedRatherThanFailingTheDecode(self):
        """Swift does `try c.decode(String.self, forKey: .phase)` with no coercion,
        so a bare int fails the WHOLE PanelPayload and takes the object list down."""
        self.register('numeric', [[{'state': 'running', 'phase': 5,
                                    'fraction': 0.5}]])
        payload = self.panel_payload()
        record = payload['pending_jobs']['numeric']
        self.assertIsInstance(record['phase'], str)
        self.assertIsInstance(record['state'], str)
        self.assertEqual(record['phase'], '5')

    def testANonFiniteFractionIsRejectedAndDoesNotPoisonTheFloor(self):
        """min(max(nan, 0.0), 1.0) is STILL nan -- every comparison with NaN is
        False -- so the clamp does not catch it. NaN is invalid JSON, and once it
        reaches track['floor'] every later tick repeats it forever."""
        self.register('nanjob', [[{'phase': 'diffusion', 'fraction': float('nan')},
                                  {'phase': 'diffusion', 'fraction': 0.5}]])
        info = self.predicting.pending_info('nanjob', _self=self.cmd)
        self.assertIsNone(info['fraction'], 'NaN says nothing; it is not a number')
        self.assertEqual(self.predicting._TRACK['nanjob']['floor'], 0.0)
        # The next tick, with a real fraction, must recover.
        info = self.predicting.pending_info('nanjob', _self=self.cmd)
        self.assertIsNotNone(info['fraction'])
        self.assertGreater(info['fraction'], 0.0)

    def testAnInfiniteFractionIsRejectedToo(self):
        self.register('infjob', [[{'phase': 'diffusion', 'fraction': float('inf')}]])
        self.assertIsNone(
            self.predicting.pending_info('infjob', _self=self.cmd)['fraction'])

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

    def testAFailureIsRetainedWITHOUTAPollHavingObservedItFirst(self):
        """The real ordering in the app, and the one no other test covered.

        The app never polls between the failure and the discard: settle() writes the
        terminal status on a background queue and hops discardPlaceholder to the main
        queue, which runs within milliseconds -- long before the next 500 ms tick. So
        every other retention test here calls pending_info() first ('observe it once')
        and would keep passing against a discard_pending that only read the cache.
        This one does NOT, which is exactly the failing case in the shipped build.
        """
        self.register('unseen', [[{'state': 'failed', 'phase': 'inference',
                                   'fraction': 0.0, 'error': 'out of memory'}]])
        self.assertIsNone(self.predicting._LAST_INFO.get('unseen'),
                          'pre-condition: no poll has observed this job')
        self.predicting.discard_pending('unseen', _self=self.cmd)
        info = self.predicting.pending_info('unseen', _self=self.cmd)
        self.assertIsNotNone(
            info, 'the terminal status is on disk; discard must read it fresh')
        self.assertEqual(info['state'], 'failed')
        self.assertEqual(info['error'], 'out of memory')

    def testAnUnobservedCancellationIsRetainedToo(self):
        """settle('cancelled') writes error=None; the card still has to appear."""
        self.register('stopped', [[{'state': 'cancelled', 'phase': 'inference',
                                    'fraction': 0.0, 'error': None}]])
        self.predicting.discard_pending('stopped', _self=self.cmd)
        info = self.predicting.pending_info('stopped', _self=self.cmd)
        self.assertIsNotNone(info)
        self.assertEqual(info['state'], 'cancelled')
        self.assertIsNone(info['error'])

    def testAnUnobservedSuccessIsStillNotRetained(self):
        """The fresh read must not turn every teardown into a card."""
        self.register('fine', [[{'state': 'done', 'phase': 'done',
                                 'fraction': 1.0}]])
        self.predicting.discard_pending('fine', _self=self.cmd)
        self.assertIsNone(self.predicting.pending_info('fine', _self=self.cmd))

    def testDiscardStillFallsBackToTheCachedRecord(self):
        """A name popped from _PENDING before the discard has no status to re-read;
        the last observed record is what keeps its card."""
        self.register('gone', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'vanished'}]])
        self.predicting.pending_info('gone', _self=self.cmd)
        self.predicting._PENDING.pop('gone', None)     # nothing left to read
        self.predicting.discard_pending('gone', _self=self.cmd)
        info = self.predicting.pending_info('gone', _self=self.cmd)
        self.assertIsNotNone(info, 'the cached record is the fallback')
        self.assertEqual(info['error'], 'vanished')

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

    # -- Measured diffusion progress and the phase-local ETA (increment 3) -----

    def age_phase(self, name, seconds):
        """Backdate the current phase's clock, so an ETA can be asserted without
        sleeping. _TRACK[name]['phase_started'] IS the state under test."""
        self.predicting._TRACK[name]['phase_started'] -= seconds

    def testDiffusionWithARealFractionIsDeterminateInsideItsBand(self):
        """The point of the increment: boltz-mlx v0.2.1 reports a real
        stage-local fraction, so the bar stops being a spinner."""
        self.register('det', [[{'phase': 'diffusion', 'fraction': 0.42,
                                'step': 84, 'total_steps': 200}]])
        info = self.predicting.pending_info('det', _self=self.cmd)
        self.assertTrue(info['moving'], 'a wide band must draw a determinate bar')
        # 0.40 + 0.42 * (0.97 - 0.40)
        self.assertAlmostEqual(info['fraction'], 0.6394, places=4)
        self.assertGreater(info['fraction'], 0.40)
        self.assertLess(info['fraction'], 0.97)
        self.assertEqual(info['step'], 84)
        self.assertEqual(info['total_steps'], 200)
        self.assertIn('step 84 of 200', info['detail'])

    def testStepCountsAreAbsentRatherThanZeroWhenThePhaseHasNone(self):
        """featurize and load report no steps; the card must not read 'step 0 of 0'."""
        self.register('nosteps', [[{'phase': 'load', 'fraction': 0.5}]])
        info = self.predicting.pending_info('nosteps', _self=self.cmd)
        self.assertIsNone(info['step'])
        self.assertIsNone(info['total_steps'])
        self.assertNotIn('step', info['detail'])

    def testTheEtaIsSuppressedForTheFirstSecondsOfAPhase(self):
        """remaining = elapsed * (1 - f) / f is wild while elapsed is tiny."""
        self.register('eta', [[{'phase': 'diffusion', 'fraction': 0.5,
                                'step': 100, 'total_steps': 200}]])
        info = self.predicting.pending_info('eta', _self=self.cmd)
        self.assertIsNone(info['remaining'],
                          'a phase milliseconds old has no measured rate')
        self.assertNotIn('left', info['detail'])

        # Half done after 100 s of diffusion -> about 100 s to go.
        self.age_phase('eta', 100.0)
        info = self.predicting.pending_info('eta', _self=self.cmd)
        self.assertAlmostEqual(info['remaining'], 100.0, delta=2.0)
        self.assertIn('2 min left', info['detail'])
        self.assertTrue(info['detail'].startswith('pending'),
                        'predict_weights_async and predict_autoload assert on this')

    def testTheEtaIsAbsentWhileTheFractionIsStillTiny(self):
        """f in the divisor: at 0.1% done, a ten-minute phase projects a week."""
        self.register('tiny', [[{'phase': 'diffusion', 'fraction': 0.001,
                                 'step': 1, 'total_steps': 1000}]])
        self.predicting.pending_info('tiny', _self=self.cmd)
        self.age_phase('tiny', 600.0)
        info = self.predicting.pending_info('tiny', _self=self.cmd)
        self.assertIsNone(info['remaining'])
        self.assertNotIn('left', info['detail'])

    def testAPhaseChangeRestartsTheEtaClock(self):
        """The trunk's four passes and diffusion's two hundred steps are nothing
        alike, so a new phase must not inherit the previous phase's clock."""
        import time
        self.register('phases', [[{'phase': 'trunk', 'fraction': 0.5},
                                  {'phase': 'trunk', 'fraction': 0.5},
                                  {'phase': 'diffusion', 'fraction': 0.5}]])
        self.predicting.pending_info('phases', _self=self.cmd)
        self.age_phase('phases', 600.0)             # ten minutes of trunk
        info = self.predicting.pending_info('phases', _self=self.cmd)
        self.assertEqual(info['phase'], 'trunk')
        self.assertIsNotNone(info['remaining'], 'pre-condition: trunk has an ETA')

        info = self.predicting.pending_info('phases', _self=self.cmd)
        self.assertEqual(info['phase'], 'diffusion')
        self.assertIsNone(
            info['remaining'],
            'diffusion must not project from the trunk 10-minute clock')
        self.assertAlmostEqual(
            self.predicting._TRACK['phases']['phase_started'],
            time.monotonic(), delta=2.0)

    def testTheNextModelDoesNotInheritThePreviousModelsClock(self):
        """n_models re-enters the SAME phase name at step 1, so the phase test
        alone would keep model 1's start and inflate model 2's whole estimate."""
        import time
        self.register('models', [[{'phase': 'diffusion', 'fraction': 0.9},
                                  {'phase': 'diffusion', 'fraction': 0.9},
                                  {'phase': 'diffusion', 'fraction': 0.02}]])
        self.predicting.pending_info('models', _self=self.cmd)
        self.age_phase('models', 600.0)             # ten minutes of model 1
        info = self.predicting.pending_info('models', _self=self.cmd)
        self.assertLess(info['remaining'], 120.0, 'pre-condition: model 1 is nearly done')
        # Model 2 restarts diffusion: the fraction goes backwards.
        info = self.predicting.pending_info('models', _self=self.cmd)
        self.assertIsNone(info['remaining'],
                          'a fraction that went backwards must restart the clock')
        self.assertAlmostEqual(self.predicting._TRACK['models']['phase_started'],
                               time.monotonic(), delta=2.0)

    def testTheEtaIsMeasuredPerPhaseNotFromTheComposedFraction(self):
        """The bands are LAYOUT, NOT TIME. Composed, this job reads 64% done; the
        honest statement is that DIFFUSION is 42% done after 100 s."""
        self.register('local', [[{'phase': 'diffusion', 'fraction': 0.42,
                                  'step': 84, 'total_steps': 200}]])
        self.predicting.pending_info('local', _self=self.cmd)
        self.age_phase('local', 100.0)
        info = self.predicting.pending_info('local', _self=self.cmd)
        # Stage-local: 100 * (1 - 0.42) / 0.42 = 138.1 s.
        self.assertAlmostEqual(info['remaining'], 138.1, delta=2.0)
        # Composed would be 100 * (1 - 0.6394) / 0.6394 = 56.4 s -- a countdown
        # that runs out while diffusion is still going.
        self.assertGreater(info['remaining'], 100.0)

    def testATerminalJobCarriesNoEta(self):
        """A cancelled job keeps reporting its last status until Swift notices;
        a countdown on a card that has already stopped is a lie."""
        self.register('stop', [[{'state': 'cancelled', 'phase': 'diffusion',
                                 'fraction': 0.5}]])
        self.predicting.pending_info('stop', _self=self.cmd)
        self.age_phase('stop', 100.0)
        info = self.predicting.pending_info('stop', _self=self.cmd)
        self.assertIsNone(info['remaining'])

    def testMalformedStepCountsAreCoercedAwayRatherThanRaising(self):
        """status() is a third-party surface and every value crosses json.dumps
        into a Swift decoder that does no coercion of its own."""
        self.register('junk', [[{'phase': 'diffusion', 'fraction': 0.5,
                                 'step': 'eighty-four', 'total_steps': None}]])
        info = self.predicting.pending_info('junk', _self=self.cmd)
        self.assertIsNone(info['step'])
        self.assertIsNone(info['total_steps'])

    def testTheRemainingFormatterMatchesTheSwiftCardsBuckets(self):
        """ProgressCard.formatRemaining (ProgressTray.swift) verbatim -- the
        tooltip and the card must not word one estimate two different ways."""
        remaining = self.predicting.format_remaining
        self.assertEqual(remaining(4), 'almost done')
        self.assertEqual(remaining(45), '45 sec left')
        self.assertEqual(remaining(240), '4 min left')
        self.assertEqual(remaining(3594), 'over an hour left')
        self.assertEqual(remaining(7200), 'over an hour left')

    def testStepCountsAndEtaSurviveThePayloadAsScalars(self):
        """A non-scalar would fail the whole PanelPayload decode in Swift."""
        self.register('wire', [[{'phase': 'diffusion', 'fraction': 0.5,
                                 'step': 100, 'total_steps': 200}]])
        self.predicting.pending_info('wire', _self=self.cmd)
        self.age_phase('wire', 100.0)
        payload = self.panel_payload()
        record = payload['pending_jobs']['wire']
        self.assertEqual(record['step'], 100)
        self.assertEqual(record['total_steps'], 200)
        self.assertIsInstance(record['remaining'], float)
        for key, value in record.items():
            self.assertIsInstance(value, (str, int, float, bool, type(None)),
                                  'pending_jobs.%s is not a scalar' % (key,))
