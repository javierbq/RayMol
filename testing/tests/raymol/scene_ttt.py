"""Per-scene object TTT capture via the cmd.scene hook (#204).

Runs on a RayMol --testing build:
    pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py
"""
from pymol import cmd, testing


def _rot(obj, axis, deg, origin=None):
    cmd.rotate(axis, deg, object=obj, camera=0, object_mode=0,
               origin=origin if origin else [0.0, 0.0, 0.0])


class TestSceneTTTHook(testing.PyMOLTestCase):
    def _mat(self, obj):
        return cmd.get_object_matrix(obj, incl_ttt=1)

    def _assertMat(self, a, b, delta=1e-5):
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=delta)

    def testHookCapturesAndRestores(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        _rot('m1', 'x', 90, origin=[5, 0, 0])
        cmd.scene('A', 'store')                 # hook snapshots (no manual call)
        poseA = self._mat('m1')
        _rot('m1', 'y', 60, origin=[5, 0, 0])
        cmd.scene('B', 'store')
        poseB = self._mat('m1')
        cmd.scene('A', 'recall', animate=0)     # hook applies
        self._assertMat(self._mat('m1'), poseA)
        cmd.scene('B', 'recall', animate=0)
        self._assertMat(self._mat('m1'), poseB)

    def testPSERoundTrip(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        _rot('m1', 'x', 90)
        cmd.scene('A', 'store')
        poseA = self._mat('m1')
        _rot('m1', 'y', 45)
        cmd.scene('B', 'store')
        with testing.mktemp('.pse') as fn:
            cmd.save(fn)
            cmd.reinitialize()
            cmd.load(fn)
        cmd.scene('A', 'recall', animate=0)
        self._assertMat(self._mat('m1'), poseA)

    def testRenameKeepsTTT(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        _rot('m1', 'x', 90)
        cmd.scene('A', 'store')
        poseA = self._mat('m1')
        cmd.scene('A', 'rename', new_key='C')
        _rot('m1', 'y', 30)
        cmd.scene('C', 'recall', animate=0)
        self._assertMat(self._mat('m1'), poseA)


class TestSceneMovieMotion(testing.PyMOLTestCase):
    def _mat(self, obj):
        return cmd.get_object_matrix(obj, incl_ttt=1)

    def _assertMatDiffers(self, a, b, delta=1e-4):
        self.assertFalse(all(abs(x - y) <= delta for x, y in zip(a, b)))

    def testRebuildInterpolatesObjectMotion(self):
        import json
        import base64
        from pymol import appkit_movie
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.scene('A', 'store')          # m1 unmoved (hook captures)
        cmd.rotate('x', 90, object='m1', camera=0, object_mode=0)
        cmd.scene('B', 'store')          # m1 rotated

        def item(frame, name):
            return {'frame': frame,
                    'scene': base64.b64encode(name.encode()).decode('ascii'),
                    'power': 0.0, 'linear': 0}

        appkit_movie.rebuild(json.dumps([item(1, 'A'), item(30, 'B')]))
        cmd.frame(1);  m_start = self._mat('m1')
        cmd.frame(30); m_end = self._mat('m1')
        cmd.frame(15); m_mid = self._mat('m1')
        self._assertMatDiffers(m_start, m_end)   # object moved across the movie
        self._assertMatDiffers(m_mid, m_start)   # ...and interpolates in between
        self._assertMatDiffers(m_mid, m_end)
