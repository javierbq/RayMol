"""The weight fetch must not block the caller, and must be observable and cancellable
while it runs (#284).

This is the regression suite for a bug whose symptom was that the RayMol window froze
with NOTHING on screen for a 529 MB download -- not because no message was written, but
because the app drains PyMOL's feedback buffer from a main-run-loop timer that a blocked
main thread never lets fire. So the properties worth pinning are, in order:

  1. cmd.predict RETURNS while the transfer is still in flight;
  2. progress is readable DURING the transfer, both as job status and as the WEIGHTS:
     marker the app's progress sheet is driven by;
  3. the transfer can be cancelled, and leaves nothing behind.

Every test drives a transfer that is held open on an Event, so "still in flight" is a
fact the test controls rather than a race it hopes to win.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_async.py
"""
import json
import os
import sys
import threading

from unittest.mock import patch

from pymol import cmd, testing

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from predict_api import StubJob, install_stub          # noqa: E402
from predict_weights_download import FakeResponse, make_zip   # noqa: E402


class GatedResponse:
    """A urlopen stand-in that stops mid-body until the test lets it continue.

    `serving` is set once the first chunk has been read, so a test can wait for the
    transfer to be genuinely underway instead of sleeping and hoping. `gate` releases
    the rest of the body.
    """

    def __init__(self, payload, first=8):
        self._payload = payload
        self._first = first
        self._offset = 0
        self.serving = threading.Event()
        self.gate = threading.Event()
        self.headers = {'Content-Length': str(len(payload))}

    def read(self, size=-1):
        if self._offset == 0:
            self._offset = self._first
            self.serving.set()
            return self._payload[:self._first]
        # Hold the body open. Timeout rather than wait forever: a test that fails an
        # assertion before releasing the gate must not wedge the whole run.
        self.gate.wait(10)
        rest = self._payload[self._offset:]
        self._offset = len(self._payload)
        return rest

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class captured_markers:
    """Collect the WEIGHTS: marker lines emitted while this context is open.

    Captures sys.stdout rather than cmd._get_feedback(). Under `pymol -c` a Python
    print goes to the real stdout and never enters the Ortho queue that _get_feedback
    drains, so asserting on the queue headlessly would pass vacuously -- it is empty
    whether the marker was emitted or not. stdout is where the line is actually
    written, and in the app that same write is what the feedback buffer captures and
    pollFeedback() hands to the progress sheet.

    `markers()` may be called while the context is still open, which is the point: the
    interesting assertion is what is visible mid-transfer.
    """

    def __init__(self):
        self._buffer = None
        self._saved = None

    def __enter__(self):
        import io
        self._buffer = io.StringIO()
        self._saved = sys.stdout
        sys.stdout = self._buffer
        return self

    def __exit__(self, *exc):
        sys.stdout = self._saved
        return False

    def markers(self):
        from pymol.predictors.fetching import MARKER
        out = []
        for line in self._buffer.getvalue().split('\n'):
            if line.startswith(MARKER):
                out.append(json.loads(line[len(MARKER):]))
        return out


def registry_bundle(predictor='stub'):
    """The stub predictor's bundle, as the command path resolves it."""
    from pymol.predictors import registry
    return registry.get(predictor).weight_bundle


def predicting_cache():
    """The same WeightCache the commands use, so cache.root matches theirs.

    start() only shares a fetch that lands in the SAME root, so a test that built
    its own cache would exercise the not-shared branch by accident.
    """
    from pymol import predicting
    return predicting.weight_cache()


class AsyncFetchTest(testing.PyMOLTestCase):

    def setUp(self):
        testing.PyMOLTestCase.setUp(self)
        from pymol.predictors import registry
        self._saved = dict(registry._REGISTRY)
        self._tmp = testing.mkdtemp()
        self.root = self._tmp.__enter__()
        os.environ['RAYMOL_WEIGHTS_DIR'] = self.root
        self.data, self.digest = make_zip()
        install_stub(self.root, self.digest, len(self.data))
        StubJob._counter = 0

    def tearDown(self):
        from pymol import predicting
        from pymol.predictors import registry
        # clear_pending() stops the worker AND drops the deferred jobs; without it the
        # rmtree below races a thread still writing into <root>/.incoming.
        predicting.clear_pending()
        predicting._JOBS.clear()
        registry._REGISTRY.clear()
        registry._REGISTRY.update(self._saved)
        os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
        self._tmp.__exit__(None, None, None)
        testing.PyMOLTestCase.tearDown(self)

    # -- the core property ----------------------------------------------------

    def testPredictReturnsWhileTheDownloadIsStillRunning(self):
        """THE bug: this call used to block for the whole transfer."""
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            job = cmd.predict('stub', 'AA', name='async_test')
            # Returned. Now prove the transfer had not finished when it did.
            self.assertTrue(response.serving.wait(5), 'download never started')
            fetch = fetching.get('stub')
            self.assertIsNotNone(fetch)
            self.assertEqual(fetch.snapshot()['state'], 'running')
            self.assertEqual(job.status()['state'], 'running')
            self.assertIn(job.status()['phase'], ('download', 'extract'))
            response.gate.set()
            fetching.join('stub', timeout=10)
        self.assertEqual(fetch.snapshot()['state'], 'done')

    def testProgressIsReadableWhileTheTransferIsInFlight(self):
        """The whole point of moving off the main thread: the marker arrives DURING.

        Before the fix this was impossible by construction -- the download ran on the
        main thread, and nothing could drain the buffer it was writing into until it
        had finished.
        """
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            with captured_markers() as cap:
                cmd.predict('stub', 'AA', name='async_test')
                self.assertTrue(response.serving.wait(5), 'download never started')
                # Read the markers WHILE the body is still held open.
                running = [m for m in cap.markers() if m['state'] == 'running']
                self.assertTrue(
                    running,
                    'no WEIGHTS: marker was observable mid-transfer; the app '
                    'progress sheet is driven by exactly these')
                self.assertEqual(running[0]['id'], 'stub')
                self.assertEqual(running[0]['total'], len(self.data))
                response.gate.set()
                fetching.join('stub', timeout=10)

    def testASettledFetchAlwaysEmitsATerminalMarker(self):
        """A dropped terminal marker would leave the app's sheet up forever."""
        from pymol.predictors import fetching
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            with captured_markers() as cap:
                cmd.predict('stub', 'AA', name='async_test')
                fetching.join('stub', timeout=10)
                states = [m['state'] for m in cap.markers()]
        self.assertIn('done', states)

    # -- the job follows the fetch -------------------------------------------

    def testPlaceholderExistsImmediatelyAndShowsTheDownload(self):
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            cmd.predict('stub', 'AA', name='async_test')
            self.assertTrue(response.serving.wait(5))
            self.assertIn('async_test', cmd.get_names('objects'))
            from pymol import predicting
            detail = predicting.pending_detail('async_test')
            self.assertIsNotNone(detail)
            self.assertTrue(detail.startswith('pending: download')
                            or detail.startswith('pending: extract'), detail)
            response.gate.set()
            from pymol.predictors import fetching
            fetching.join('stub', timeout=10)

    def testPumpSubmitsTheJobOnceTheWeightsLand(self):
        from pymol import predicting
        from pymol.predictors import fetching
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            job = cmd.predict('stub', 'AA', name='async_test')
            self.assertFalse(job.submitted, 'must not submit before weights exist')
            fetching.join('stub', timeout=10)
            predicting.pump()
            self.assertTrue(job.submitted)
        self.assertEqual(job.status()['state'], 'done')

    def testOneDownloadServesEveryPredictionWaitingOnIt(self):
        """Two cold-cache predicts must share a transfer, not start two."""
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen',
                   return_value=response) as opener:
            cmd.predict('stub', 'AA', name='first')
            self.assertTrue(response.serving.wait(5))
            cmd.predict('stub', 'GG', name='second')
            self.assertEqual(opener.call_count, 1, 'started a second download')
            response.gate.set()
            fetching.join('stub', timeout=10)

    # -- cancellation ---------------------------------------------------------

    def testCancelStopsTheDownloadAndLeavesNothingBehind(self):
        from pymol import predicting
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            job = cmd.predict('stub', 'AA', name='async_test')
            self.assertTrue(response.serving.wait(5))
            cmd.predict_weights_cancel('stub')
            # Reported as cancelled at once, without waiting for the worker to reach
            # its next chunk boundary -- otherwise the button looks dead.
            self.assertEqual(job.status()['state'], 'cancelled')
            response.gate.set()
            fetching.join('stub', timeout=10)
        self.assertEqual(fetching.get('stub').snapshot()['state'], 'cancelled')
        # No half-written cache, and no placeholder left orphaned in the session.
        from pymol.predictors import registry
        bundle = registry.get('stub').weight_bundle
        self.assertFalse(predicting.weight_cache().is_cached(bundle))
        predicting.pump()
        self.assertNotIn('async_test', cmd.get_names('objects'))
        self.assertNotIn('async_test', predicting.pending_objects())

    def testCancellingViaTheJobCancelsTheFetch(self):
        """predict_cancel on a job that has not started yet stops its download."""
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            job = cmd.predict('stub', 'AA', name='async_test')
            self.assertTrue(response.serving.wait(5))
            cmd.predict_cancel(job.job_id)
            self.assertEqual(job.status()['state'], 'cancelled')
            response.gate.set()
            fetching.join('stub', timeout=10)
        self.assertEqual(fetching.get('stub').snapshot()['state'], 'cancelled')

    def testCancelIsHarmlessWhenNothingIsRunning(self):
        self.assertEqual(cmd.predict_weights_cancel('stub'), 0)

    # -- failure --------------------------------------------------------------

    def testAFailedFetchSettlesTheJobAndRemovesThePlaceholder(self):
        from pymol import predicting
        from pymol.predictors import fetching
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=IOError('no route to host')):
            job = cmd.predict('stub', 'AA', name='async_test')
            fetching.join('stub', timeout=10)
            predicting.pump()
        status = job.status()
        self.assertEqual(status['state'], 'error')
        self.assertTrue(status['error'])
        self.assertNotIn('async_test', cmd.get_names('objects'))
        self.assertNotIn('async_test', predicting.pending_objects())

    def testASynchronousPrefetchRaisesTheFailureOnTheCallingThread(self):
        """predict_weights(download=1) must not report a silent no-op.

        The worker has no caller to propagate to, so without the re-raise a failed
        prefetch returns a cheerful cached=False and looks like it did nothing.
        """
        from pymol.predictors.errors import WeightDownloadFailed
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=IOError('no route to host')):
            self.assertRaises(WeightDownloadFailed,
                              cmd.predict_weights, 'stub', download=1)

    # -- bundles that ship inside the app -------------------------------------

    def testABundledSourceResolvesWithNoThreadAndNoAttributeError(self):
        """`weight_bundle` may be a BundledSource, which has no `version` or `size`.

        Routing a cold-cache check through cache.is_cached() -> path_for() would raise
        AttributeError on one. Nothing ships a BundledSource today, but Predictor
        documents it as valid and #275 plans to move MPNN.mpnnpack onto it, so the
        deferral path must already tolerate it rather than wait there as a landmine.
        """
        import os as _os
        from pymol.predictors import fetching
        from pymol.predictors.weights import BundledSource, WeightCache
        inside = _os.path.join(self.root, 'bundled')
        _os.makedirs(inside, exist_ok=True)
        bundle = BundledSource(id='bundled-stub', path=inside)
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=AssertionError('must not download a bundled source')):
            fetch = fetching.start(bundle, WeightCache(self.root))
        self.assertEqual(fetch.state, 'done')
        self.assertIsNone(fetch.thread, 'no worker should be started')
        self.assertEqual(fetch.path, inside)
        self.assertEqual(fetch.snapshot()['total'], 0)

    # -- registration ---------------------------------------------------------

    def testCancelIsRegisteredAsACommandKeyword(self):
        self.assertIn('predict_weights_cancel', cmd.keyword)

    # -- a fetch record must never wedge ------------------------------------
    #
    # Reported symptom: cancelling while the tray said "Unpacking... 67%" left the
    # card on screen forever, `fetching.forget(<id>)` refused to drop the record,
    # and every later `predict_weights <p>, download=1` silently did nothing --
    # no new .incoming/.part -- because start() kept handing back the same entry.
    # Only popping _FETCHES by hand recovered it.
    #
    # All three follow from ONE state: a record still reading `running`. forget()
    # skips running records by design and start() shares them by design, so a
    # record that stops making progress disables both retry and cleanup with no
    # way out. These pin the escape hatches.

    def _gate_inside_extract(self, member='model.bin'):
        """(patcher, reached, gate) that holds the worker inside ONE member.

        Gates on the member's own read() rather than on a chunk count, so it can
        only ever trip during extraction -- a count would have to guess how many
        checks the download phase made first.
        """
        import zipfile
        real_open = zipfile.ZipFile.open
        reached = threading.Event()
        gate = threading.Event()

        class _Held:
            def __init__(self, inner):
                self._inner = inner
                self._reads = 0

            def read(self, size=-1):
                self._reads += 1
                if self._reads == 2:
                    reached.set()
                    gate.wait(10)
                return self._inner.read(size)

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                self._inner.close()
                return False

        def opener(zself, name, mode='r', *args, **kwargs):
            handle = real_open(zself, name, mode, *args, **kwargs)
            if getattr(name, 'filename', name) == member:
                return _Held(handle)
            return handle
        return patch.object(zipfile.ZipFile, 'open', opener), reached, gate

    def _big_stub(self, size=256 * 1024):
        """Re-install the stub with a model.bin big enough to span many chunks."""
        self.data, self.digest = make_zip(
            (('config.json', '{}'), ('model.bin', 'x' * size)))
        install_stub(self.root, self.digest, len(self.data))

    def testCancellingDuringExtractEmitsATerminalMarker(self):
        """THE reported bug: the tray card must resolve, not freeze on a stale %.

        The card is kept while the state is running or error and dropped on any
        terminal state, so "the card never went away" means "no terminal marker
        ever arrived". It has to arrive from the extract phase too.
        """
        from pymol.predictors import fetching
        self._big_stub()
        patcher, reached, gate = self._gate_inside_extract()
        with patch('pymol.predictors.weights.EXTRACT_CHUNK_BYTES', 4096), \
                patch('pymol.predictors.weights._urlopen',
                      return_value=FakeResponse(self.data)), patcher:
            with captured_markers() as cap:
                cmd.predict_weights('stub', download=1, async_=1)
                self.assertTrue(reached.wait(10), 'never reached extract')
                mid = fetching.get('stub').snapshot()
                self.assertEqual(mid['phase'], 'extract')
                cmd.predict_weights_cancel('stub')
                gate.set()
                fetching.join('stub', timeout=10)
                markers = cap.markers()
        self.assertEqual(fetching.get('stub').snapshot()['state'], 'cancelled')
        self.assertTrue(markers, 'no markers at all')
        self.assertEqual(markers[-1]['state'], 'cancelled',
                         'the last marker was not terminal, so the tray card would '
                         'sit on a stale running fraction forever')
        self.assertEqual(markers[-1]['phase'], 'extract')

    def testExtractProgressIsVisibleWhileOneBigMemberIsWritten(self):
        """A marker has to move DURING the unpack, or the bar looks hung."""
        from pymol.predictors import fetching
        self._big_stub()
        with patch('pymol.predictors.weights.EXTRACT_CHUNK_BYTES', 4096), \
                patch('pymol.predictors.weights._urlopen',
                      return_value=FakeResponse(self.data)):
            with captured_markers() as cap:
                cmd.predict_weights('stub', download=1, async_=1)
                fetching.join('stub', timeout=10)
                extracting = [m['fraction'] for m in cap.markers()
                              if m['phase'] == 'extract' and m['state'] == 'running']
        self.assertGreater(len(set(extracting)), 1,
                           'only one extract fraction was ever published (%r), so a '
                           'pack whose last member is the payload shows a frozen bar'
                           % (extracting,))

    def testForgetDropsALiveRecordSoARetryCanStart(self):
        """(a) forget(<id>) must actually drop it -- that is the whole point.

        It also has to cancel what it abandons: the worker owns a half-written
        staging dir and would otherwise still publish it, racing the fresh fetch
        that forget() exists to permit.
        """
        from pymol.predictors import fetching
        held = GatedResponse(self.data)
        # A fresh body for the retry, so this asserts the replacement transfer
        # actually COMPLETES -- the whole point of being able to forget the old one.
        responses = [held, FakeResponse(self.data)]
        with patch('pymol.predictors.weights._urlopen',
                   side_effect=lambda *a, **k: responses.pop(0)):
            first = fetching.start(registry_bundle(), predicting_cache())
            self.assertTrue(held.serving.wait(5))
            self.assertEqual(first.snapshot()['state'], 'running')
            self.assertEqual(fetching.forget('stub'), ['stub'])
            self.assertNotIn('stub', list(fetching._FETCHES),
                             'forget() left the record in place, so every retry is '
                             'still a silent no-op')
            self.assertTrue(first.cancelled,
                            'the abandoned worker was not asked to stop; it can '
                            'still publish over the fetch that replaces it')
            held.gate.set()
            # Let the abandoned worker unwind before retrying: it still holds the
            # cache lock for this bundle, and releases it as it goes.
            if first.thread is not None:
                first.thread.join(10)
            self.assertEqual(first.snapshot()['state'], 'cancelled')
            second = fetching.start(registry_bundle(), predicting_cache())
            self.assertIsNot(second, first, 'retry rejoined the forgotten fetch')
            fetching.join('stub', timeout=10)
        self.assertEqual(second.snapshot()['state'], 'done')
        self.assertTrue(predicting_cache().is_cached(registry_bundle()))

    def testForgetWithNoIdStillOnlyDropsSettledRecords(self):
        """The bulk broom must stay a broom: it may not abort live transfers."""
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            fetch = fetching.start(registry_bundle(), predicting_cache())
            self.assertTrue(response.serving.wait(5))
            fetching.forget()
            self.assertIn('stub', list(fetching._FETCHES))
            self.assertFalse(fetch.cancelled)
            response.gate.set()
            fetching.join('stub', timeout=10)
        fetching.forget()
        self.assertNotIn('stub', list(fetching._FETCHES))

    def testARecordWhoseWorkerDiedDoesNotBlockEveryRetryForever(self):
        """A 'running' record with a dead thread is wedged, not live.

        This is the state the report was stuck in. Sharing it forever is what made
        `predict_weights ..., download=1` a no-op with no .part to show for it.
        """
        from pymol.predictors import fetching
        bundle, cache = registry_bundle(), predicting_cache()
        wedged = fetching.Fetch(bundle, cache)
        dead = threading.Thread(target=lambda: None)
        dead.start()
        dead.join()
        wedged.thread = dead              # ran, exited, never settled its state
        with fetching._LOCK:
            fetching._FETCHES[bundle.id] = wedged
        self.assertEqual(wedged.state, 'running')
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            fresh = fetching.start(bundle, cache)
            self.assertIsNot(fresh, wedged, 'retry rejoined a dead fetch')
            fetching.join(bundle.id, timeout=10)
        self.assertEqual(fetching.get(bundle.id).snapshot()['state'], 'done')

    def testAWorkerThatCannotStartSettlesInsteadOfStrandingARunningRecord(self):
        """If the thread never starts, nothing will ever settle the record."""
        from pymol.predictors import fetching
        bundle, cache = registry_bundle(), predicting_cache()
        with patch.object(threading.Thread, 'start',
                          side_effect=RuntimeError("can't start new thread")):
            with captured_markers() as cap:
                fetch = fetching.start(bundle, cache)
                markers = cap.markers()
        self.assertEqual(fetch.snapshot()['state'], 'error')
        self.assertTrue(fetch.snapshot()['error'])
        self.assertTrue(markers and markers[-1]['state'] == 'error',
                        'no terminal marker, so the tray card would never clear')
        # And the record must not block the next attempt.
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(self.data)):
            again = fetching.start(bundle, cache)
            self.assertIsNot(again, fetch)
            fetching.join(bundle.id, timeout=10)
        self.assertEqual(fetching.get(bundle.id).snapshot()['state'], 'done')

    def testTheWorkerSettlesEvenIfEnsureRaisesSomethingOutsideException(self):
        """`except Exception` is not enough: a BaseException strands the record.

        Nothing in ensure() raises one today. This asserts the invariant rather
        than the current call graph, because the cost of being wrong is a record
        that can never be forgotten and a tray card that never clears.
        """
        from pymol.predictors import fetching
        from pymol.predictors.weights import WeightCache
        bundle, cache = registry_bundle(), predicting_cache()
        with patch.object(WeightCache, 'ensure',
                          side_effect=KeyboardInterrupt('boom')):
            with captured_markers() as cap:
                fetching.start(bundle, cache)
                fetching.join(bundle.id, timeout=10)
                markers = cap.markers()
        snap = fetching.get(bundle.id).snapshot()
        self.assertEqual(snap['state'], 'error')
        self.assertTrue(snap['error'])
        self.assertTrue(markers and markers[-1]['state'] == 'error')

    def testPredictWeightsSaysSoWhenItJoinsAFetchAlreadyInFlight(self):
        """(c) A download=1 that starts nothing must say why, not look like a no-op."""
        from pymol.predictors import fetching
        response = GatedResponse(self.data)
        with patch('pymol.predictors.weights._urlopen', return_value=response):
            cmd.predict_weights('stub', download=1, async_=1)
            self.assertTrue(response.serving.wait(5))
            out = cmd.predict_weights('stub', download=1, async_=1)
            self.assertIn('fetch', out['stub'],
                          'the second call reported nothing about the transfer it '
                          'silently joined')
            self.assertEqual(out['stub']['fetch']['state'], 'running')
            self.assertTrue(out['stub']['joined'])
            response.gate.set()
            fetching.join('stub', timeout=10)
