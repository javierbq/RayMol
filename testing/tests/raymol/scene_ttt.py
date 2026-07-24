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
    def _frame_hash(self, fr):
        """md5 of a ray-rendered frame. We must RENDER to observe movie object
        motion: the interpolated per-object TTT is applied in the render path,
        NOT committed to the object's persistent matrix, so get_object_matrix()
        after cmd.frame() does NOT reflect it (verified). The ray render does."""
        import hashlib
        import os
        import time
        cmd.frame(fr)
        cmd.ray(120, 120)
        with testing.mktemp('.png') as png:
            cmd.png(png, dpi=0)
            for _ in range(100):     # png write is sync in -cq, but be defensive
                if os.path.exists(png) and os.path.getsize(png) > 0:
                    break
                time.sleep(0.02)
            with open(png, 'rb') as fh:
                return hashlib.md5(fh.read()).hexdigest()

    def testRebuildInterpolatesObjectMotion(self):
        import json
        import base64
        from pymol import appkit_movie
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')
        cmd.hide('everything'); cmd.show('spheres', 'm1')
        cmd.bg_color('white'); cmd.orient('m1'); cmd.zoom('m1', 6)
        cmd.scene('A', 'store')                  # m1 unmoved (hook captures)
        cmd.translate([10, 0, 0], object='m1', camera=0)
        cmd.scene('B', 'store')                  # m1 translated far

        def item(frame, name):
            return {'frame': frame,
                    'scene': base64.b64encode(name.encode()).decode('ascii'),
                    'power': 0.0, 'linear': 0}

        # Keyframes at 1 and 30; sample the true midpoint (15). A STEPPED movie
        # would leave frame 15 identical to an endpoint — three distinct frames
        # prove the object glides (interpolates) rather than jumping at the cut.
        appkit_movie.rebuild(json.dumps([item(1, 'A'), item(30, 'B')]))
        h_start = self._frame_hash(1)
        h_mid = self._frame_hash(15)
        h_end = self._frame_hash(30)
        self.assertNotEqual(h_start, h_end)   # object moved across the movie
        self.assertNotEqual(h_mid, h_start)   # ...and is mid-way at the midpoint
        self.assertNotEqual(h_mid, h_end)
