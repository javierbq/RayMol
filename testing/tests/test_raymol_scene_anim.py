"""Headless unit tests for pymol.raymol_scene_anim — per-scene render-setting
animation across a scene movie. No C++ build required:

    /Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q \
        testing/tests/test_raymol_scene_anim.py

The fork's modules are not in the venv's stock pymol, so the modules under test
are loaded directly from the repo by path.
"""
import base64
import importlib.util
import math
import os
import sys
import types
import unittest

_MODULES = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules"))


def _load(mod_name, filename):
    """Load a repo module file under a unique name, with `pymol.<mod_name>` also
    registered so intra-module `from pymol import <mod_name>` resolves to it."""
    path = os.path.join(_MODULES, "pymol", filename)
    spec = importlib.util.spec_from_file_location(mod_name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


def load_modules():
    """(raymol_scenes, raymol_scene_anim) freshly loaded and cross-wired."""
    import pymol
    scenes = _load("raymol_scenes_uut", "raymol_scenes.py")
    setattr(pymol, "raymol_scenes", scenes)
    anim = _load("raymol_scene_anim_uut", "raymol_scene_anim.py")
    setattr(pymol, "raymol_scene_anim", anim)
    return scenes, anim


def cpp_ease(fxn, power):
    """Reference port of ViewElemInterpolate's easing (layer1/View.cpp:1165-1177)
    with bias=1.0 and parabolic=True — what the camera actually does."""
    if power != 1.0:
        if fxn < 0.5:
            fxn = (fxn * 2.0) ** power * 0.5
        elif fxn > 0.5:
            fxn = 1.0 - fxn
            fxn = (fxn * 2.0) ** power * 0.5
            fxn = 1.0 - fxn
    return fxn


class TestHelpers(unittest.TestCase):
    def setUp(self):
        self.scenes, self.anim = load_modules()

    def test_ease_matches_cpp_curve(self):
        for power in (1.4, 1.0, 2.0):
            for i in range(0, 21):
                t = i / 20.0
                self.assertAlmostEqual(
                    self.anim.ease(t, power), cpp_ease(t, power), places=9,
                    msg="t=%s power=%s" % (t, power))

    def test_ease_endpoints_and_midpoint(self):
        self.assertEqual(self.anim.ease(0.0), 0.0)
        self.assertEqual(self.anim.ease(1.0), 1.0)
        self.assertEqual(self.anim.ease(0.5), 0.5)
        # Smooth (1.4) lags a linear ramp in the first half — the desync we fix.
        self.assertLess(self.anim.ease(0.25, 1.4), 0.25)
        self.assertEqual(self.anim.ease(0.25, 1.0), 0.25)

    def test_effective_power(self):
        # mview power=0 means "use the default", which View.cpp puts at 1.4.
        self.assertEqual(self.anim.effective_power(0.0), 1.4)
        self.assertEqual(self.anim.effective_power(None), 1.4)
        self.assertEqual(self.anim.effective_power(1.0), 1.0)

    def test_as_float_and_truthy_handle_pymol_strings(self):
        # cmd.get() returns strings: '0.80000' for floats, 'on'/'off' for bools.
        self.assertAlmostEqual(self.anim._as_float("0.80000"), 0.8)
        self.assertIsNone(self.anim._as_float("on"))
        self.assertIsNone(self.anim._as_float(None))
        self.assertTrue(self.anim._truthy("on"))
        self.assertFalse(self.anim._truthy("off"))
        self.assertTrue(self.anim._truthy(1))
        self.assertFalse(self.anim._truthy(None))

    def test_classification_covers_every_captured_setting(self):
        # Every captured setting must be either interpolated or (implicitly) stepped;
        # nothing interpolated may be outside CAPTURE.
        self.assertTrue(self.anim.INTERPOLATE.issubset(set(self.scenes.CAPTURE)))

    def test_expensive_settings_never_interpolate(self):
        for s in ("surface_quality", "metal_dof_quality", "metal_msaa",
                  "metal_upscale", "metal_rt_samples", "metal_dof",
                  "metal_dof_autofocus"):
            self.assertNotIn(s, self.anim.INTERPOLATE, s)

    def test_interpolatable_rules(self):
        a = self.anim
        self.assertTrue(a.interpolatable("metal_dof_aperture", 1.0, 5.0))
        self.assertFalse(a.interpolatable("metal_dof", 0.0, 1.0))   # stepped
        # 0 is the "auto" sentinel for focus — stepping avoids a bogus ramp.
        self.assertFalse(a.interpolatable("metal_dof_focus", 0.0, 12.0))
        self.assertFalse(a.interpolatable("metal_dof_focus", 12.0, 0.0))
        self.assertTrue(a.interpolatable("metal_dof_focus", 8.0, 12.0))

    def test_value_at_clamps_sentinel_floor(self):
        a = self.anim
        # aperture <= 0 is a sentinel meaning MAX blur (14) — a fade to 0 must not
        # reach it; the floor keeps the ramp in real territory.
        self.assertGreaterEqual(a.value_at("metal_dof_aperture", 5.0, 0.0, 1.0),
                                a._FLOOR["metal_dof_aperture"])
        self.assertGreaterEqual(a.value_at("metal_dof_range", 5.0, 0.0, 1.0),
                                a._FLOOR["metal_dof_range"])
        # An unfloored setting interpolates plainly.
        self.assertAlmostEqual(a.value_at("ambient", 0.0, 1.0, 0.25), 0.25)


class FakeCmd:
    """Records mappend/set calls; enough surface for track emission."""
    def __init__(self, objects=None):
        self._objects = list(objects or [])
        self.appended = []      # [(frame, command_string)]
        self.sets = []          # [(setting, value)]
        self.selected = []      # [(name, expr)]
        self.ttt_calls = []     # [(name, ttt)]

    def mappend(self, frame, command):
        self.appended.append((int(frame), command))

    def set(self, setting, value, *a, **k):
        self.sets.append((setting, value))

    def set_object_ttt(self, name, ttt, *a, **k):
        self.ttt_calls.append((name, ttt))

    def select(self, name, expr, *a, **k):
        self.selected.append((name, expr))

    def get_names(self, kind='objects'):
        return list(self._objects)

    def iterate_state(self, *a, **k):
        return 0


class TestTrackBuilder(unittest.TestCase):
    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()

    def _store(self, name, **settings):
        # Mimic a raymol_scenes capture: values arrive as PyMOL strings.
        self.scenes._scene_settings[name] = {k: str(v) for k, v in settings.items()}

    def test_interior_frames_only_and_monotone(self):
        self._store('A', metal_dof_aperture=1.0, metal_dof='on')
        self._store('B', metal_dof_aperture=5.0, metal_dof='on')
        track = self.anim.build_track([(1, 'A', 0.0), (11, 'B', 0.0)])
        # Keyframes themselves are handled by enter_scene, not the track.
        self.assertNotIn(1, track)
        self.assertNotIn(11, track)
        self.assertEqual(sorted(track), list(range(2, 11)))
        vals = [track[f]['metal_dof_aperture'] for f in range(2, 11)]
        self.assertEqual(vals, sorted(vals))              # monotone increasing
        self.assertTrue(all(1.0 < v < 5.0 for v in vals))  # strictly between

    def test_unchanged_settings_are_not_emitted(self):
        self._store('A', metal_dof_aperture=3.0, ambient=0.2)
        self._store('B', metal_dof_aperture=3.0, ambient=0.9)
        track = self.anim.build_track([(1, 'A', 0.0), (6, 'B', 0.0)])
        for vals in track.values():
            self.assertNotIn('metal_dof_aperture', vals)   # identical -> skipped
            self.assertIn('ambient', vals)

    def test_stepped_settings_are_not_in_the_track(self):
        self._store('A', metal_dof='off', surface_quality=1)
        self._store('B', metal_dof='on', surface_quality=3)
        track = self.anim.build_track([(1, 'A', 0.0), (6, 'B', 0.0)])
        self.assertEqual(track, {})     # both step; enter_scene applies them

    def test_adjacent_keyframes_have_no_interior(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        self.assertEqual(self.anim.build_track([(4, 'A', 0.0), (5, 'B', 0.0)]), {})

    def test_easing_is_applied_not_linear(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        smooth = self.anim.build_track([(1, 'A', 0.0), (5, 'B', 0.0)])
        linear = self.anim.build_track([(1, 'A', 1.0), (5, 'B', 1.0)])
        # Quarter-way in, the eased ramp lags the linear one.
        self.assertLess(smooth[2]['ambient'], linear[2]['ambient'])

    def test_destination_keyframe_power_drives_easing(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        # Only the DESTINATION keyframe's power may matter; flipping the source's
        # must not change the result, flipping the destination's must.
        dest_linear = self.anim.build_track([(1, 'A', 0.0), (5, 'B', 1.0)])
        dest_smooth = self.anim.build_track([(1, 'A', 1.0), (5, 'B', 0.0)])
        self.assertNotEqual(dest_linear[2]['ambient'], dest_smooth[2]['ambient'])
        # dest_linear is the linear ramp: quarter-way in == 0.25
        self.assertAlmostEqual(dest_linear[2]['ambient'], 0.25)
        self.assertLess(dest_smooth[2]['ambient'], 0.25)

    def test_unsorted_keyframes_are_sorted(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        out_of_order = self.anim.build_track([(11, 'B', 0.0), (1, 'A', 0.0)])
        in_order = self.anim.build_track([(1, 'A', 0.0), (11, 'B', 0.0)])
        self.assertEqual(out_of_order, in_order)
        self.assertEqual(sorted(out_of_order), list(range(2, 11)))

    def test_frame_command_and_emit(self):
        fake = FakeCmd()
        track = {3: {'ambient': 0.5, 'metal_dof_aperture': 2.0}}
        done = self.anim.emit_track(track, _self=fake)
        self.assertEqual(done, [3])
        self.assertEqual(len(fake.appended), 1)
        frame, s = fake.appended[0]
        self.assertEqual(frame, 3)
        self.assertIn('set ambient, 0.5', s)
        self.assertIn('set metal_dof_aperture, 2', s)
        self.assertIn(';', s)          # multiple sets joined

    def test_emit_scene_marks_is_base64_and_injection_safe(self):
        fake = FakeCmd()
        nasty = "ev'il; quit"
        self.anim.emit_scene_marks([(7, nasty)], _self=fake)
        frame, s = fake.appended[0]
        self.assertEqual(frame, 7)
        self.assertNotIn('quit', s)            # raw name never appears
        self.assertNotIn("'il", s)
        self.assertIn('enter_scene', s)

    def test_enter_scene_applies_all_settings_and_focus_not_ttt(self):
        self._store('A', metal_dof='on', ambient=0.3)
        self.scenes._scene_ttt['A'] = {'m1': None}     # must NOT be applied
        fake = FakeCmd(objects=['m1'])
        b64 = base64.b64encode(b'A').decode('ascii')
        self.anim.enter_scene(b64, _self=fake)
        applied = dict(fake.sets)
        self.assertEqual(applied.get('metal_dof'), 'on')
        self.assertEqual(applied.get('ambient'), '0.3')
        self.assertEqual(fake.appended, [])            # no frame commands
        # TTT is the movie's own channel — enter_scene must not touch it.
        self.assertEqual(fake.ttt_calls, [])

    def test_enter_scene_tolerates_garbage(self):
        fake = FakeCmd()
        self.anim.enter_scene('!!!not-base64!!!', _self=fake)   # must not raise
        self.assertEqual(fake.sets, [])


class TestFocusPull(unittest.TestCase):
    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()

    def test_eye_depth_matches_hand_math(self):
        # 18-float view layout: rows 0-8 rotation, 9-11 camera pos, 12-14 origin.
        view = [1, 0, 0,
                0, 1, 0,
                0, 0, 1,
                0.0, 0.0, -50.0,
                0.0, 0.0, 0.0,
                -60.0, -40.0, 20.0]
        # R_row2 = (v[2], v[5], v[8]) = (0,0,1); tz = v[11] = -50; origin = 0.
        # eye_z = z - 0 + (-50) = z - 50  ->  depth = 50 - z
        self.assertAlmostEqual(self.anim.eye_depth([0.0, 0.0, 0.0], view), 50.0)
        self.assertAlmostEqual(self.anim.eye_depth([0.0, 0.0, 10.0], view), 40.0)

    def test_eye_depth_25float_layout(self):
        # 25-float view uses stride-4 rotation indices (view[2], view[6], view[10])
        # and tz/origin at indices 18-21.  Identity rotation with tz=-50 gives
        # depth = -eye_z = -(r22*(pz - oz) + tz) = -(pz + (-50)) = 50 - pz.
        view25 = [0.0] * 25
        view25[0]  = 1.0   # R[0,0]
        view25[5]  = 1.0   # R[1,1]
        view25[10] = 1.0   # R[2,2]  — this is r22 for eye_depth (view[10])
        # view[2]=0, view[6]=0, view[10]=1 → r20=0, r21=0, r22=1
        view25[18] = -50.0  # tz
        view25[19] = 0.0    # ox
        view25[20] = 0.0    # oy
        view25[21] = 0.0    # oz
        self.assertAlmostEqual(self.anim.eye_depth([0.0, 0.0,  0.0], view25), 50.0)
        self.assertAlmostEqual(self.anim.eye_depth([0.0, 0.0, 10.0], view25), 40.0)

    def test_eye_depth_handles_missing_view(self):
        self.assertIsNone(self.anim.eye_depth([0, 0, 0], None))

    def test_pull_only_when_both_autofocus_and_targets_differ(self):
        a = self.anim
        self.scenes._scene_settings['A'] = {'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof_autofocus': 'off'}
        # B has autofocus off -> step, no pull.
        self.assertEqual(a.build_focus_pull([(1, 'A', 0.0), (9, 'B', 0.0)],
                                            _self=FakeCmd()), {})

    def test_pull_emits_monotone_distance_and_disables_autofocus(self):
        a = self.anim
        self.scenes._scene_settings['A'] = {'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof_autofocus': 'on'}

        # A camera that DOLLIES: each frame pulls back by 0.5 Å, so the depth of
        # a fixed point differs per frame.  A lerp of endpoint distances would
        # miss this; only per-frame reprojection tracks the moving camera.
        class ViewCmd(FakeCmd):
            def __init__(self, *args, **kwargs):
                FakeCmd.__init__(self, *args, **kwargs)
                self.frames_seen = []
                self._tz = -50.0
            def frame(self, f):
                self.frames_seen.append(int(f))
                self._tz = -50.0 - int(f) * 0.5      # camera moves with the frame
            def get_view(self):
                return [1, 0, 0,
                        0, 1, 0,
                        0, 0, 1,
                        0.0, 0.0, self._tz,
                        0.0, 0.0, 0.0,
                        -60.0, -40.0, 20.0]

        fake = ViewCmd()
        # Stub the centroids: A near (z=0), B far (z=-20).
        a.focus_centroid = lambda name, _self=None: (
            [0.0, 0.0, 0.0] if name == 'A' else [0.0, 0.0, -20.0])

        pull = a.build_focus_pull([(1, 'A', 0.0), (11, 'B', 0.0)], _self=fake)

        # 1. _self.frame(f) must be called once per interior frame, in order.
        #    An implementation that skips frame() entirely would produce [] here.
        self.assertEqual(fake.frames_seen, list(range(2, 11)))

        # 2. Interior frames only, monotone distances, autofocus disabled.
        self.assertEqual(sorted(pull), list(range(2, 11)))
        for vals in pull.values():
            self.assertEqual(vals['metal_dof_autofocus'], 0.0)
        dists = [pull[f]['metal_dof_focus'] for f in range(2, 11)]
        self.assertEqual(dists, sorted(dists))
        self.assertTrue(all(d > 50.0 for d in dists))

        # 3. Per-frame reprojection departs from a straight lerp of the endpoint
        #    depths.  Frame 6 (the midpoint) coincides by easing symmetry; frame 4
        #    yields a ~0.28 Å gap.  An implementation that lerps endpoint depths
        #    instead of reprojecting per frame would hit lerp_f4 exactly here.
        ref = ViewCmd()
        ref.frame(1)
        d_start = a.eye_depth([0.0, 0.0, 0.0], ref.get_view())    # centroid A at f=1
        ref.frame(11)
        d_end = a.eye_depth([0.0, 0.0, -20.0], ref.get_view())    # centroid B at f=11
        lerp_f4 = d_start + (d_end - d_start) * a.ease((4 - 1) / 10.0)
        self.assertGreater(abs(pull[4]['metal_dof_focus'] - lerp_f4), 1e-6)

    def test_identical_targets_need_no_pull(self):
        a = self.anim
        self.scenes._scene_settings['A'] = {'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof_autofocus': 'on'}
        a.focus_centroid = lambda name, _self=None: [1.0, 2.0, 3.0]
        self.assertEqual(a.build_focus_pull([(1, 'A', 0.0), (9, 'B', 0.0)],
                                            _self=FakeCmd()), {})


class TestAuthorAndSession(unittest.TestCase):
    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()
        self.anim._track.clear()
        self.anim._scene_marks[:] = []

    def _two_scenes(self):
        self.scenes._scene_settings['A'] = {'ambient': '0.0', 'metal_dof': 'off'}
        self.scenes._scene_settings['B'] = {'ambient': '1.0', 'metal_dof': 'on'}

    def test_author_emits_marks_and_track_and_records_state(self):
        self._two_scenes()
        fake = FakeCmd()
        n = self.anim.author([(1, 'A', 0.0), (6, 'B', 0.0)], _self=fake)
        self.assertGreater(n, 0)
        frames = [f for f, _ in fake.appended]
        self.assertIn(1, frames)                 # scene mark at each keyframe
        self.assertIn(6, frames)
        self.assertTrue(set(range(2, 6)).issubset(frames))   # interior track
        self.assertEqual(sorted(self.anim._track), list(range(2, 6)))
        self.assertEqual(sorted(self.anim._scene_marks), [(1, 'A'), (6, 'B')])

    def test_session_roundtrip_reauthors(self):
        self._two_scenes()
        self.anim.author([(1, 'A', 0.0), (6, 'B', 0.0)], _self=FakeCmd())
        sess = {}
        self.anim.session_save(sess, _self=FakeCmd())
        self.assertIn('raymol_movie_anim', sess)
        saved_track = dict(self.anim._track)
        self.anim._track.clear()
        self.anim._scene_marks[:] = []
        fake = FakeCmd()
        self.anim.session_restore(sess, _self=fake)
        self.assertEqual(self.anim._track, saved_track)
        self.assertEqual(sorted(self.anim._scene_marks), [(1, 'A'), (6, 'B')])
        self.assertTrue(fake.appended)           # commands regenerated, not replayed

    def test_session_save_blanks_only_our_own_commands(self):
        self._two_scenes()
        fake = FakeCmd()
        self.anim.author([(1, 'A', 0.0), (6, 'B', 0.0)], _self=fake)
        # A movie session: slot 5 is the per-frame command list (0-based frames).
        cmds = [''] * 8
        for f, s in fake.appended:
            cmds[f - 1] = s
        cmds[3] = 'turn y, 1'                    # a rock command we must preserve
        for f, s in fake.appended:
            if f - 1 == 3:
                cmds[3] = 'turn y, 1;' + s
        sess = {'movie': [None] * 6}
        sess['movie'][5] = cmds
        self.anim.session_save(sess, _self=fake)
        out = sess['movie'][5]
        self.assertNotIn('enter_scene', ''.join(out))    # ours gone
        self.assertIn('turn y, 1', out[3])               # theirs kept

    def test_session_restore_rejects_unknown_and_nonnumeric(self):
        sess = {'raymol_movie_anim': {
            'track': {'3': {'ambient': 0.5,
                            'os.system': 1.0,          # not a captured setting
                            'metal_dof_aperture': 'rm -rf /'}},   # non-numeric
            'marks': []}}
        self.anim.session_restore(sess, _self=FakeCmd())
        self.assertEqual(self.anim._track, {3: {'ambient': 0.5}})

    def test_session_restore_tolerates_absent_key(self):
        self.anim.session_restore({}, _self=FakeCmd())   # must not raise
        self.assertEqual(self.anim._track, {})
