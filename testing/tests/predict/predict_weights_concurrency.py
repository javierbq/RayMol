"""Concurrency and locking for WeightCache.ensure().

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_concurrency.py
"""
import os
import sys
import threading
import time
from unittest.mock import patch

from pymol import testing

# The runner imports test files by path (testing.py:48) and never puts their
# directory on sys.path, so a sibling import needs it added explicitly. This
# happens at import time, before setUp's chdir, hence __file__ and not '.'.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from predict_weights_download import FakeResponse, bundle_for, make_zip


class TestConcurrency(testing.PyMOLTestCase):

    def testTwoThreadsProduceExactlyOneDownload(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        calls = []
        barrier = threading.Barrier(2)

        def slow_open(request, timeout=None):
            calls.append(request)
            time.sleep(0.2)
            return FakeResponse(data)

        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            results = []

            def run():
                barrier.wait()
                results.append(cache.ensure(bundle))

            with patch('pymol.predictors.weights._urlopen', slow_open):
                threads = [threading.Thread(target=run) for _ in range(2)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()

            self.assertEqual(len(calls), 1, 'exactly one download expected')
            self.assertEqual(results, [cache.path_for(bundle)] * 2)
            self.assertTrue(cache.is_cached(bundle))

    def testStaleLockIsBroken(self):
        from pymol.predictors.weights import WeightCache
        data, digest = make_zip()
        bundle = bundle_for(data, digest)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            os.makedirs(cache._incoming())
            lock = cache._lock_path(bundle)
            with open(lock, 'w') as handle:
                handle.write('999999')
            old = time.time() - (cache.LOCK_STALE_SECONDS + 60)
            os.utime(lock, (old, old))
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertTrue(os.path.isdir(cache.ensure(bundle)))

    def testLockIsReleasedAfterFailure(self):
        from pymol.predictors.weights import WeightCache
        from pymol.predictors.errors import WeightChecksumMismatch
        data, _ = make_zip()
        bundle = bundle_for(data, 'd' * 64)
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            with patch('pymol.predictors.weights._urlopen',
                       return_value=FakeResponse(data)):
                self.assertRaises(WeightChecksumMismatch, cache.ensure, bundle)
            self.assertFalse(os.path.exists(cache._lock_path(bundle)))
