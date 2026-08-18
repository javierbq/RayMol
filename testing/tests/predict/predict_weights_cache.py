"""Tests for WeightCache path resolution and validity. No network.

    pymol -ckqy testing/testing.py --run testing/tests/predict/predict_weights_cache.py
"""
import os

from pymol import testing

SHA = 'a' * 64


def make_bundle(**kwargs):
    from pymol.predictors.weights import WeightBundle
    defaults = dict(id='stub', version='v1', url='https://example.invalid/b.zip',
                    sha256=SHA, size=123, members=('config.json', 'model.bin'))
    defaults.update(kwargs)
    return WeightBundle(**defaults)


class TestCachePaths(testing.PyMOLTestCase):

    def testPathForIsIdThenVersion(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            self.assertEqual(cache.path_for(make_bundle()),
                             os.path.join(root, 'stub', 'v1'))

    def testEnvOverrideWinsOverDefault(self):
        from pymol.predictors import weights
        old = os.environ.get('RAYMOL_WEIGHTS_DIR')
        try:
            os.environ['RAYMOL_WEIGHTS_DIR'] = '/tmp/raymol-weights-test'
            self.assertEqual(weights.WeightCache().root,
                             '/tmp/raymol-weights-test')
        finally:
            if old is None:
                os.environ.pop('RAYMOL_WEIGHTS_DIR', None)
            else:
                os.environ['RAYMOL_WEIGHTS_DIR'] = old

    def testDefaultRootIsUnderApplicationSupportOnDarwin(self):
        from pymol.predictors import weights
        root = weights.WeightCache.default_root(platform='darwin', home='/Users/x')
        self.assertEqual(
            root, '/Users/x/Library/Application Support/RayMol/weights')

    def testDefaultRootHasADotDirElsewhere(self):
        from pymol.predictors import weights
        self.assertEqual(weights.WeightCache.default_root(platform='linux',
                                                          home='/home/x'),
                         '/home/x/.raymol/weights')


class TestCacheValidity(testing.PyMOLTestCase):

    def testEmptyCacheIsNotCached(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            self.assertFalse(WeightCache(root).is_cached(make_bundle()))

    def testDirectoryWithoutSentinelIsNotCached(self):
        """The interrupted-download case: files present, no sentinel."""
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, 'model.bin'), 'w') as handle:
                handle.write('partial')
            self.assertFalse(cache.is_cached(make_bundle()))

    def testSentinelWithWrongDigestIsNotCached(self):
        """Re-validation: a cache whose digest no longer matches is rejected."""
        from pymol.predictors.weights import WeightCache, SENTINEL
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write('b' * 64)
            self.assertFalse(cache.is_cached(make_bundle()))

    def testSentinelWithMatchingDigestIsCached(self):
        from pymol.predictors.weights import WeightCache, SENTINEL
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            target = cache.path_for(make_bundle())
            os.makedirs(target)
            with open(os.path.join(target, SENTINEL), 'w') as handle:
                handle.write(SHA)
            self.assertTrue(cache.is_cached(make_bundle()))


class TestIncomingSweep(testing.PyMOLTestCase):
    """Scratch stranded by a process that died mid-download must be reclaimed.

    ensure()'s `finally` never ran for these: the fetch is a daemon thread, so
    quitting the app takes the interpreter down without unwinding it and leaves a
    half-gigabyte .part behind for good.
    """

    def _incoming(self, cache):
        path = cache._incoming()
        os.makedirs(path, exist_ok=True)
        return path

    def _debris(self, incoming, pid):
        token = '%s-%d' % ('c' * 64, pid)
        part = os.path.join(incoming, token + '.part')
        staging = os.path.join(incoming, token + '.d')
        with open(part, 'wb') as handle:
            handle.write(b'partial')
        os.makedirs(staging)
        return part, staging

    def testDeadOwnersScratchIsReclaimed(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            incoming = self._incoming(cache)
            # A pid that cannot be running: os.getpid() is this process, and
            # _pid_alive treats an unreachable pid as gone.
            part, staging = self._debris(incoming, 999999)
            cache.sweep_incoming()
            self.assertFalse(os.path.exists(part))
            self.assertFalse(os.path.exists(staging))

    def testLiveOwnersScratchIsLeftAlone(self):
        """A concurrent downloader's scratch is not ours to delete."""
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            incoming = self._incoming(cache)
            part, staging = self._debris(incoming, os.getpid())
            cache.sweep_incoming()
            self.assertTrue(os.path.exists(part))
            self.assertTrue(os.path.exists(staging))

    def testUnrecognizedEntriesAreLeftAlone(self):
        """.incoming is not this method's to empty -- only its own token shape."""
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            cache = WeightCache(root)
            incoming = self._incoming(cache)
            keep = [os.path.join(incoming, name) for name in
                    ('notes.txt', 'stub-v1.lock', 'short-999999.part')]
            for path in keep:
                with open(path, 'w') as handle:
                    handle.write('x')
            cache.sweep_incoming()
            for path in keep:
                self.assertTrue(os.path.exists(path), path)

    def testSweepSurvivesAMissingIncoming(self):
        from pymol.predictors.weights import WeightCache
        with testing.mkdtemp() as root:
            WeightCache(root).sweep_incoming()      # must not raise


class TestBundledSource(testing.PyMOLTestCase):

    def testResolveReturnsAnExistingPath(self):
        """ensure() must be able to return a path it never downloaded (see #249)."""
        from pymol.predictors.weights import BundledSource
        with testing.mkdtemp() as root:
            source = BundledSource('mpnn', root)
            self.assertEqual(source.resolve(), root)

    def testResolveRaisesWhenAbsent(self):
        from pymol.predictors.weights import BundledSource
        from pymol.predictors.errors import WeightDownloadFailed
        source = BundledSource('mpnn', '/nonexistent/raymol/pack')
        self.assertRaises(WeightDownloadFailed, source.resolve)
