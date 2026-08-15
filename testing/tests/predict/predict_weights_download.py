"""Tests for WeightCache.ensure(). Offline: _urlopen is always patched.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
"""
import contextlib
import hashlib
import io
import os
import zipfile
from unittest.mock import patch

from pymol import testing


@contextlib.contextmanager
def no_backoff():
    """Collapse the retry ladder's waits to nothing.

    The delays are zeroed rather than the sleeping stubbed: _backoff waits on a
    real monotonic deadline, so a no-op _sleep would only turn seconds of sleeping
    into seconds of spinning. Every attempt still runs, in the same order.
    """
    with patch('pymol.predictors.weights.RETRY_BACKOFF_BASE', 0.0), \
         patch('pymol.predictors.weights.RETRY_BACKOFF_MAX', 0.0):
        yield


def make_zip(members=(('config.json', '{}'), ('model.bin', 'weights'))):
    """Return (zip_bytes, sha256_hex)."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as archive:
        for name, text in members:
            archive.writestr(name, text)
    data = buf.getvalue()
    return data, hashlib.sha256(data).hexdigest()


class FakeResponse:
    """Minimal urlopen stand-in: a context manager with .read(n) and .headers."""

    def __init__(self, payload, chunk=None):
        self._stream = io.BytesIO(payload)
        self._chunk = chunk
        self.headers = {'Content-Length': str(len(payload))}

    def read(self, size=-1):
        if self._chunk is not None and size not in (0, None):
            size = min(size, self._chunk)
        return self._stream.read(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _Connection(FakeResponse):
    """One RangeServer response; raises a socket timeout after `fail_after` bytes."""

    def __init__(self, server, body, status, fail_after):
        FakeResponse.__init__(self, body)
        self._server = server
        self._served = 0
        self._fail_after = fail_after
        self.status = status

    def read(self, size=-1):
        if self._fail_after is not None and self._served >= self._fail_after:
            raise TimeoutError('The read operation timed out')
        if size and size > 0 and self._fail_after is not None:
            size = min(size, self._fail_after - self._served)
        chunk = FakeResponse.read(self, size)
        self._served += len(chunk)
        self._server.served[-1] = self._served
        return chunk


class RangeServer:
    """urlopen stand-in that honours (or pointedly ignores) Range and can stall.

    `fail_after` is consumed one entry per connection: the Nth connection raises a
    socket timeout once it has handed out that many bytes. With `honour_range`
    false it answers every request with 200 and the whole body, which is what a
    CDN edge that does not do partial content looks like.
    """

    def __init__(self, payload, fail_after=(), honour_range=True):
        self.payload = payload
        self.fail_after = list(fail_after)
        self.honour_range = honour_range
        self.connections = []       # (Range header or None, status) per connection
        self.served = []            # bytes actually handed out per connection

    def __call__(self, request, timeout=None):
        header = request.get_header('Range')
        offset = 0
        if header and self.honour_range:
            offset = int(header.split('=', 1)[1].split('-', 1)[0])
        status = 206 if offset else 200
        limit = self.fail_after.pop(0) if self.fail_after else None
        self.connections.append((header, status))
        self.served.append(0)
        return _Connection(self, self.payload[offset:], status, limit)


def bundle_for(data, digest, **kwargs):
    from pymol.predictors.weights import WeightBundle
    defaults = dict(id='stub', version='v1', url='https://example.invalid/b.zip',
                    sha256=digest, size=len(data),
                    members=('config.json', 'model.bin'))
    defaults.update(kwargs)
    return WeightBundle(**defaults)


class TestEnsure(testing.PyMOLTestCase):

    def testDownloadsOnceThenServesFromCache(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)) as opener:
                first = cache.ensure(bundle)
                self.assertEqual(opener.call_count, 1)
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=AssertionError('must not re-download')) as opener:
                second = cache.ensure(bundle)
                self.assertEqual(opener.call_count, 0)
            self.assertEqual(first, second)
            self.assertEqual(first, cache.path_for(bundle))

    def testExtractionLayoutIsDeterministic(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                path = cache.ensure(bundle)
            self.assertEqual(sorted(os.listdir(path)),
                             sorted([SENTINEL, 'config.json', 'model.bin']))
            with open(os.path.join(path, 'model.bin')) as handle:
                self.assertEqual(handle.read(), 'weights')

    def testChecksumMismatchLeavesNoCache(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightChecksumMismatch
        data, _ = make_zip()
        bundle = bundle_for(data, 'b' * 64)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightChecksumMismatch, cache.ensure, bundle)
            self.assertFalse(os.path.exists(cache.path_for(bundle)))
            self.assertFalse(cache.is_cached(bundle))

    def testInterruptedDownloadProducesNoValidCache(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadFailed
        data, digest = make_zip()
        bundle = bundle_for(data, digest)

        class Dying(FakeResponse):
            def read(self, size=-1):
                raise IOError('connection reset')

        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with no_backoff(), patch('pymol.predictors.weights._urlopen',
                                     return_value=Dying(data)):
                self.assertRaises(WeightDownloadFailed, cache.ensure, bundle)
            self.assertFalse(cache.is_cached(bundle))
            self.assertFalse(os.path.exists(cache.path_for(bundle)))
            # And a later good attempt still succeeds.
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertTrue(os.path.isdir(cache.ensure(bundle)))

    def testWrongMembersRejected(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightBundleLayoutError
        data, digest = make_zip()
        bundle = bundle_for(data, digest,
                            members=('config.json', 'model.bin', 'manifest.json'))
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightBundleLayoutError, cache.ensure, bundle)
            self.assertFalse(cache.is_cached(bundle))

    def testStaleCacheIsReDownloaded(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(bundle)
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write('c' * 64)          # digest from an older bundle
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)) as opener:
                cache.ensure(bundle)
                self.assertEqual(opener.call_count, 1)
            self.assertTrue(cache.is_cached(bundle))

    def testDiskFullDuringDownloadIsClassifiedAsUnwritable(self):
        """ENOSPC is not a network failure and must not be reported as one."""
        import errno
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightCacheUnwritable
        data, digest = make_zip()
        bundle = bundle_for(data, digest)

        class OutOfSpace(FakeResponse):
            def read(self, size=-1):
                raise OSError(errno.ENOSPC, 'No space left on device')

        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=OutOfSpace(data)):
                self.assertRaises(WeightCacheUnwritable, cache.ensure, bundle)
            self.assertFalse(cache.is_cached(bundle))

    def testNetworkErrorRaisesWeightDownloadFailed(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadFailed
        from urllib.error import URLError
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            with patch('pymol.predictors.weights._urlopen',
                       side_effect=URLError('no route to host')):
                self.assertRaises(WeightDownloadFailed,
                                  WeightCache(root).ensure, bundle)

    def testUnwritableRootRaisesWeightCacheUnwritable(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightCacheUnwritable
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        cache = WeightCache('/dev/null/not-a-dir')
        with patch('pymol.predictors.weights._urlopen',
                   return_value=FakeResponse(data)):
            self.assertRaises(WeightCacheUnwritable, cache.ensure, bundle)

    def testResumeContinuesWhereTheStreamDied(self):
        """A mid-stream timeout must cost the stalled read, not the whole transfer."""
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip(members=[('config.json', 'x' * 4000),
                                         ('model.bin', 'y' * 4000)])
        bundle = bundle_for(data, digest)
        server = RangeServer(data, fail_after=[len(data) // 2])
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with no_backoff(), patch('pymol.predictors.weights._urlopen', server):
                path = cache.ensure(bundle)
            self.assertTrue(cache.is_cached(bundle))
            with open(os.path.join(path, 'model.bin')) as handle:
                self.assertEqual(handle.read(), 'y' * 4000)
        # Two connections: the second asked to resume and was told 206.
        self.assertEqual([status for _, status in server.connections],
                         [200, 206])
        self.assertEqual(server.connections[1][0],
                         'bytes=%d-' % (len(data) // 2))
        # The point of the exercise: the bytes before the stall were not re-fetched.
        self.assertEqual(sum(server.served), len(data))

    def testResumeSurvivesRepeatedStalls(self):
        """Several stalls are normal on a slow CDN; each one must only cost itself."""
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip(members=[('config.json', 'x' * 4000),
                                         ('model.bin', 'y' * 4000)])
        bundle = bundle_for(data, digest)
        stalls = [len(data) // 8] * 6           # more than MAX_STALLED_ATTEMPTS
        server = RangeServer(data, fail_after=stalls)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with no_backoff(), patch('pymol.predictors.weights._urlopen', server):
                cache.ensure(bundle)
            self.assertTrue(cache.is_cached(bundle))
        self.assertEqual(len(server.connections), len(stalls) + 1)
        self.assertEqual(sum(server.served), len(data))

    def testRangeIgnoringServerStillEndsWithACorrectDigest(self):
        """A 200 answer to a Range request must restart, never append a duplicate."""
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip(members=[('config.json', 'x' * 4000),
                                         ('model.bin', 'y' * 4000)])
        bundle = bundle_for(data, digest)
        server = RangeServer(data, fail_after=[len(data) // 2],
                             honour_range=False)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with no_backoff(), patch('pymol.predictors.weights._urlopen', server):
                path = cache.ensure(bundle)
            self.assertTrue(cache.is_cached(bundle))
            with open(os.path.join(path, 'config.json')) as handle:
                self.assertEqual(handle.read(), 'x' * 4000)
        # It did ask to resume, was answered with the whole body, and started over --
        # so the second connection served everything, not the tail.
        self.assertEqual([status for _, status in server.connections],
                         [200, 200])
        self.assertIsNotNone(server.connections[1][0])
        self.assertEqual(server.served[1], len(data))

    def testRetriesAreBounded(self):
        """A link that never advances must fail, not retry forever."""
        from pymol.predictors import weights
        from pymol.predictors.errors import WeightDownloadFailed
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        server = RangeServer(data, fail_after=[0] * 100)
        with testing.mkdtemp() as root:
            with no_backoff(), patch('pymol.predictors.weights._urlopen', server):
                self.assertRaises(WeightDownloadFailed,
                                  weights.WeightCache(root).ensure, bundle)
        self.assertEqual(len(server.connections), weights.MAX_STALLED_ATTEMPTS)

    def testBadUrlIsNotRetried(self):
        """404 is the answer, not a hiccup: retrying only delays it."""
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadFailed
        from urllib.error import HTTPError
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        opener = patch('pymol.predictors.weights._urlopen',
                       side_effect=HTTPError(bundle.url, 404, 'Not Found',
                                             {}, None))
        with testing.mkdtemp() as root:
            with no_backoff(), opener as mock:
                self.assertRaises(WeightDownloadFailed,
                                  WeightCache(root).ensure, bundle)
            self.assertEqual(mock.call_count, 1)

    def testCancelDuringBackoffIsPrompt(self):
        """Cancelling while waiting to retry must not wait out the backoff."""
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightDownloadCancelled
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        server = RangeServer(data, fail_after=[0] * 100)
        # Cancel only once a transfer has actually failed, so the wait is what gets
        # interrupted rather than the download never starting.
        state = {'failed': False}

        def should_cancel():
            state['failed'] = bool(server.connections)
            return state['failed']

        slept = []
        with testing.mkdtemp() as root:
            with patch('pymol.predictors.weights._sleep', slept.append), \
                 patch('pymol.predictors.weights._urlopen', server):
                self.assertRaises(WeightDownloadCancelled,
                                  WeightCache(root).ensure, bundle,
                                  should_cancel=should_cancel)
        self.assertEqual(len(server.connections), 1)
        self.assertEqual(slept, [])         # cancelled before the first slice

    def testProgressIsReportedForDownloadAndExtract(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        seen = []
        with testing.mkdtemp() as root:
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data, chunk=4)):
                WeightCache(root).ensure(
                    bundle, progress=lambda phase, frac: seen.append((phase, frac)))
        phases = [phase for phase, _ in seen]
        self.assertIn('download', phases)
        self.assertIn('extract', phases)
        self.assertEqual(seen[-1], ('extract', 1.0))
        for _, frac in seen:
            self.assertTrue(0.0 <= frac <= 1.0, seen)
