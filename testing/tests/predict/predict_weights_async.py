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
from predict_weights_download import make_zip          # noqa: E402


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
        from predict_weights_download import FakeResponse
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
        from predict_weights_download import FakeResponse
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

    # -- registration ---------------------------------------------------------

    def testCancelIsRegisteredAsACommandKeyword(self):
        self.assertIn('predict_weights_cancel', cmd.keyword)
