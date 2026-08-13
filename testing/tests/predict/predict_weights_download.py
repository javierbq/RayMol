"""Tests for WeightCache.ensure(). Offline: _urlopen is always patched.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_download.py
"""
import hashlib
import io
import os
import zipfile
from unittest.mock import patch

from pymol import testing


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
            with patch('pymol.predictors.weights._urlopen',
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
