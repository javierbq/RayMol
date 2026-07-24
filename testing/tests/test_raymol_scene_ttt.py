"""Headless unit tests for pymol.raymol_scenes per-object TTT capture (#204).

Runs with the repo venv, no C++ build:
    /Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q \
        testing/tests/test_raymol_scene_ttt.py

Stock venv pymol lacks the fork's raymol_scenes module and its cmd.py session-task
registration, so we import the module file directly and drive a real pymol2.PyMOL()
instance, passing _self=p.cmd to every function.
"""
import importlib.util
import os
import unittest

_MODULES = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules"))


def _load_raymol_scenes():
    path = os.path.join(_MODULES, "pymol", "raymol_scenes.py")
    spec = importlib.util.spec_from_file_location("raymol_scenes_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _RecordingCmd:
    """Minimal fake for testing emit_object_motion deterministically."""
    def __init__(self, objects=None):
        self._objects = list(objects or [])
        self.ttt = {}
        self.mviews = []

    def get_names(self, kind='objects'):
        return list(self._objects)

    def set_object_ttt(self, obj, ttt, *a, **k):
        self.ttt[obj] = list(ttt)

    def mview(self, action='store', **kw):
        self.mviews.append((action, kw))


class TestEmitObjectMotion(unittest.TestCase):
    def setUp(self):
        self.rs = _load_raymol_scenes()

    def test_emit_stores_keyframe_per_object(self):
        rs = self.rs
        rs._scene_ttt['A'] = {
            'm1': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1],
            'm2': None,
        }
        rec = _RecordingCmd(objects=['m1', 'm2'])
        done = rs.emit_object_motion('A', 7, _self=rec)
        self.assertEqual(sorted(done), ['m1', 'm2'])
        self.assertEqual(rec.ttt['m2'], rs._IDENTITY_TTT)   # None -> identity
        stores = [c for c in rec.mviews if c[0] == 'store']
        self.assertEqual(len(stores), 2)
        for _, kw in stores:
            self.assertEqual(kw.get('first'), 7)
            self.assertIn(kw.get('object'), ('m1', 'm2'))

    def test_emit_skips_absent_objects(self):
        rs = self.rs
        rs._scene_ttt['A'] = {'ghost': [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]}
        rec = _RecordingCmd(objects=[])   # ghost not present
        done = rs.emit_object_motion('A', 3, _self=rec)
        self.assertEqual(done, [])
        self.assertEqual(rec.mviews, [])


class TestSceneTTT(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import pymol2
        except Exception as e:
            raise unittest.SkipTest("pymol2 unavailable: %s" % e)
        cls.p = pymol2.PyMOL()
        cls.p.start()
        cls.cmd = cls.p.cmd

    @classmethod
    def tearDownClass(cls):
        try:
            cls.p.stop()
        except Exception:
            pass

    def setUp(self):
        self.cmd.reinitialize()
        self.rs = _load_raymol_scenes()

    def _rot(self, obj, axis, deg, origin=None):
        self.cmd.rotate(axis, deg, object=obj, camera=0, object_mode=0,
                        origin=origin if origin else [0.0, 0.0, 0.0])

    def _mat(self, obj):
        return self.cmd.get_object_matrix(obj, incl_ttt=1)

    def _assertMat(self, a, b, delta=1e-6):
        self.assertEqual(len(a), len(b))
        for x, y in zip(a, b):
            self.assertAlmostEqual(x, y, delta=delta)

    def _assertMatDiffers(self, a, b, delta=1e-6):
        self.assertFalse(all(abs(x - y) <= delta for x, y in zip(a, b)))

    def test_roundtrip_offcenter(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1')
        cmd.fragment('gly', 'm2')
        self._rot('m1', 'x', 90, origin=[5, 0, 0])   # off-center (gizmo-divergence case)
        cmd.scene('S1', 'store'); rs.snapshot_current(_self=cmd)
        pose1 = self._mat('m1')
        self._rot('m1', 'y', 45, origin=[5, 0, 0])
        cmd.scene('S2', 'store'); rs.snapshot_current(_self=cmd)
        pose2 = self._mat('m1')
        self._assertMatDiffers(pose1, pose2)
        rs.apply('S1', _self=cmd)
        self._assertMat(self._mat('m1'), pose1)
        rs.apply('S2', _self=cmd)
        self._assertMat(self._mat('m1'), pose2)

    def test_recall_resets_unmoved(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1')
        identity = self._mat('m1')
        cmd.scene('S1', 'store'); rs.snapshot_current(_self=cmd)   # m1 unmoved
        self._rot('m1', 'x', 90)
        self._assertMatDiffers(identity, self._mat('m1'))
        rs.apply('S1', _self=cmd)                                  # must reset
        self._assertMat(self._mat('m1'), identity)

    def test_added_untouched_removed_skipped(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1')
        self._rot('m1', 'x', 90)
        cmd.scene('S1', 'store'); rs.snapshot_current(_self=cmd)
        cmd.fragment('gly', 'm2')          # added AFTER store
        self._rot('m2', 'y', 30)
        m2_moved = self._mat('m2')
        cmd.delete('m1')                   # removed (in the map)
        rs.apply('S1', _self=cmd)          # no exception
        self._assertMat(self._mat('m2'), m2_moved)   # m2 untouched

    def test_rename_rekeys(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1'); self._rot('m1', 'x', 90)
        cmd.scene('S1', 'store'); rs.snapshot_current(_self=cmd)
        pose = self._mat('m1')
        rs.rename('S1', 'S2', _self=cmd)
        self.assertEqual(rs.scene_ttt_map('S1'), {})
        self.assertIn('m1', rs.scene_ttt_map('S2'))
        self._rot('m1', 'y', 45)
        rs.apply('S2', _self=cmd)
        self._assertMat(self._mat('m1'), pose)

    def test_on_scene_action_dispatch(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1'); self._rot('m1', 'x', 90)
        cmd.scene('S1', 'store'); rs.on_scene_action('S1', 'store', _self=cmd)
        self.assertIn('m1', rs.scene_ttt_map('S1'))
        cmd.scene('S1', 'delete'); rs.on_scene_action('S1', 'delete', _self=cmd)
        self.assertEqual(rs.scene_ttt_map('S1'), {})

    def test_suspended_blocks_dispatch(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1'); self._rot('m1', 'x', 90)
        cmd.scene('S1', 'store')
        with rs.suspended():
            rs.on_scene_action('S1', 'store', _self=cmd)   # no-op while suspended
        self.assertEqual(rs.scene_ttt_map('S1'), {})

    def test_session_save_restore(self):
        cmd, rs = self.cmd, self.rs
        cmd.fragment('ala', 'm1'); self._rot('m1', 'x', 90)
        cmd.scene('S1', 'store'); rs.snapshot_current(_self=cmd)
        sess = {}
        rs.session_save(sess, _self=cmd)
        self.assertIn('raymol_scene_ttt', sess)
        rs.clear_all(_self=cmd)
        self.assertEqual(rs.scene_ttt_map('S1'), {})
        rs.session_restore(sess, _self=cmd)
        self.assertIn('m1', rs.scene_ttt_map('S1'))
