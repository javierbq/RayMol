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
import unittest

_MODULES = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules"))


def _load(mod_name, filename):
    """Load a repo module file into sys.modules under the unique name `mod_name`.
    Binding it onto the `pymol` package — which is what makes an intra-module
    `from pymol import raymol_scenes` resolve to the copy under test — is
    load_modules()'s job, done for both modules once they are all loaded."""
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
    with bias=1.0 — what the camera actually does. A negative power clears the
    parabolic flag (View.cpp:897-900), adding the circular pre-warp."""
    parabolic = True
    if power < 0.0:
        parabolic = False
        power = -power
    if power != 1.0 or not parabolic:
        if fxn < 0.5:
            if not parabolic:
                fxn = (1.0 - math.cos(math.pi * fxn)) * 0.5
            fxn = (fxn * 2.0) ** power * 0.5
        elif fxn > 0.5:
            fxn = 1.0 - fxn
            if not parabolic:
                fxn = (1.0 - math.cos(math.pi * fxn)) * 0.5
            fxn = (fxn * 2.0) ** power * 0.5
            fxn = 1.0 - fxn
    return fxn


class TestHelpers(unittest.TestCase):
    def setUp(self):
        self.scenes, self.anim = load_modules()

    def test_ease_matches_cpp_curve(self):
        # -1.0 exercises the parabolic=false (circular) branch the core takes for
        # a negative power, e.g. the keyframes movie._rock stores.
        for power in (1.4, 1.0, 2.0, -1.0, -1.4):
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
        e = self.anim.effective_power
        # `mview store` records a power only when non-zero (Movie.cpp:1183-1185),
        # so a 0/None endpoint carries no power_flag and does not vote; with
        # neither flagged View.cpp falls back to 1.4.
        self.assertEqual(e(0.0), 1.4)
        self.assertEqual(e(None), 1.4)
        self.assertEqual(e(0.0, 0.0), 1.4)
        self.assertEqual(e(1.0), 1.0)              # only the first is flagged
        self.assertEqual(e(0.0, 1.0), 1.0)         # only the last is flagged
        # Both flagged: same sign averages (View.cpp:879-881).
        self.assertEqual(e(1.0, 2.0), 1.5)
        self.assertEqual(e(-1.0, -2.0), -1.5)
        # Mixed signs: bigger magnitude wins, else the negative one
        # (View.cpp:882-888).
        self.assertEqual(e(-2.0, 1.0), -2.0)
        self.assertEqual(e(1.0, -2.0), -2.0)
        # A non-zero mview interpolate/reinterpolate power is resolved before the
        # endpoints are consulted at all (View.cpp:877); 0 means "not given".
        self.assertEqual(e(1.0, 1.0, 2.0), 2.0)
        self.assertEqual(e(1.0, 1.0, 0.0), 1.0)
        self.assertEqual(e(0.0, 0.0, 1.0), 1.0)

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
        # focus = 0 means AUTO, not "no value": the renderer resolves it to a real
        # distance every frame (SceneRender.cpp:2043-2072), so there is nothing
        # unrampable about a 0 endpoint.  Refusing it is what left the user's
        # 0 -> 120 transition dead.  (Focus never reaches build_track anyway —
        # build_dof_transition owns it, see _DOF_OWNED.)
        self.assertTrue(a.interpolatable("metal_dof_focus", 0.0, 12.0))
        self.assertTrue(a.interpolatable("metal_dof_focus", 12.0, 0.0))
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
    def __init__(self, objects=None, extent=None):
        self._objects = list(objects or [])
        # ExecutiveGetExtent's "nothing resolved" placeholder (Cmd.cpp:4529).
        self._extent = extent or [[-0.5, -0.5, -0.5], [0.5, 0.5, 0.5]]
        self.extent_calls = []  # [(selection, state)]
        self.appended = []      # [(frame, command_string)] — each individual call
        self.done = []          # [(frame, command_string)] — mdo calls
        self._slots = {}        # {frame: accumulated slot string, as PyMOL stores}
        self.sets = []          # [(setting, value)]
        self.selected = []      # [(name, expr)]
        self.ttt_calls = []     # [(name, ttt)]

    def mappend(self, frame, command):
        f = int(frame)
        self.appended.append((f, command))
        existing = self._slots.get(f, '')
        self._slots[f] = (existing + ';' + command) if existing else (';' + command)

    def mdo(self, frame, command):
        # MovieSetCommand OVERWRITES the slot (Movie.cpp:1079), unlike mappend.
        f = int(frame)
        self.done.append((f, command))
        self._slots[f] = str(command)

    def set(self, setting, value, *a, **k):
        self.sets.append((setting, value))

    def set_object_ttt(self, name, ttt, *a, **k):
        self.ttt_calls.append((name, ttt))

    def select(self, name, expr, *a, **k):
        self.selected.append((name, expr))

    def get_names(self, kind='objects'):
        return list(self._objects)

    def get_extent(self, selection, state=0, *a, **k):   # 0 == cmd's ALL_STATES
        self.extent_calls.append((selection, state))
        return [list(self._extent[0]), list(self._extent[1])]


class ViewCmd(FakeCmd):
    """FakeCmd plus a camera that DOLLIES: each frame pulls back 0.5 Å, so the
    depth of a fixed point differs per frame.

    build_dof_transition needs frame() and get_view(); with a fake that has
    neither, every per-frame view is None and no focus can resolve — so a test
    asserting an empty (or focus-free) result would be vacuously green."""
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

    def test_build_track_never_emits_focus(self):
        # Ownership moved: metal_dof_focus is resolved per frame by
        # build_dof_transition (0 = auto, and autofocus has to be switched off
        # while we drive it).  build_track emitting a raw ramp of the CAPTURED
        # numbers would fight it, the winner decided by dict.update ordering.
        self._store('A', metal_dof_focus=8.0, metal_dof_aperture=1.0)
        self._store('B', metal_dof_focus=12.0, metal_dof_aperture=5.0)
        track = self.anim.build_track([(1, 'A', 0.0), (11, 'B', 0.0)])
        self.assertTrue(track)
        for vals in track.values():
            self.assertNotIn('metal_dof_focus', vals)
            self.assertIn('metal_dof_aperture', vals)   # its neighbour still ramps

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

    def test_both_endpoint_powers_resolve_the_easing(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        a = self.anim
        # ViewElemInterpolate resolves the power from BOTH endpoints, so the
        # SOURCE keyframe's easing counts exactly as much as the destination's.
        # (Using the destination alone desynced the settings from the camera on a
        # mixed Linear/Smooth timeline.)  Only one endpoint flagged -> that one
        # decides, whichever end it sits on.
        src_only = a.build_track([(1, 'A', 1.0), (5, 'B', 0.0)])
        dst_only = a.build_track([(1, 'A', 0.0), (5, 'B', 1.0)])
        self.assertEqual(src_only, dst_only)
        self.assertAlmostEqual(src_only[2]['ambient'], 0.25)      # linear ramp
        # Neither flagged -> View.cpp's 1.4 default, which lags the linear ramp.
        neither = a.build_track([(1, 'A', 0.0), (5, 'B', 0.0)])
        self.assertLess(neither[2]['ambient'], 0.25)
        # Both flagged and different -> the average power, not either endpoint.
        mixed = a.build_track([(1, 'A', 1.0), (5, 'B', 2.0)])
        avg = a.build_track([(1, 'A', 1.5), (5, 'B', 1.5)])
        self.assertAlmostEqual(mixed[2]['ambient'], avg[2]['ambient'])
        self.assertNotAlmostEqual(mixed[2]['ambient'], src_only[2]['ambient'])

    def test_interpolate_power_override_beats_the_endpoints(self):
        self._store('A', ambient=0.0)
        self._store('B', ambient=1.0)
        a = self.anim
        # The power handed to mview interpolate/reinterpolate wins outright —
        # place_scene passes 1.0 for Linear while the markers store nothing.
        forced = a.build_track([(1, 'A', 0.0), (5, 'B', 0.0)], power=1.0)
        self.assertAlmostEqual(forced[2]['ambient'], 0.25)
        # 0.0 means "no override was given": the endpoints decide again.
        self.assertEqual(a.build_track([(1, 'A', 0.0), (5, 'B', 0.0)], power=0.0),
                         a.build_track([(1, 'A', 0.0), (5, 'B', 0.0)]))

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

    def test_focus_centroid_is_the_transformed_bbox_midpoint(self):
        # The renderer autofocuses on the MIDPOINT of ExecutiveGetExtent(
        # "dof_focus", transformed=true) (SceneRender.cpp:2053-2056).  Anything
        # else (e.g. the arithmetic mean of the coords, or untransformed
        # coordinates) disagrees with the renderer at the bracketing keyframes and
        # snaps.  cmd.get_extent is the identical call (Cmd.cpp:4523).
        self.scenes._scene_focus['A'] = [('m1', 1), ('m1', 2), ('m2', 5)]
        fake = FakeCmd(objects=['m1', 'm2'],
                       extent=[[0.0, -4.0, 2.0], [10.0, 4.0, 6.0]])
        self.assertEqual(self.anim.focus_centroid('A', fake), [5.0, 0.0, 4.0])
        # One selection spanning every surviving object, at ALL_STATES (state=0):
        # cmd.get_extent(state=0) passes int(0)-1=-1 to ExecutiveGetExtent, which
        # takes the OMOP_MNMX all-coord-sets path — matching the renderer exactly
        # for multi-state (NMR/MD) objects.  state=1 would differ.
        (sel, state), = fake.extent_calls
        self.assertEqual(state, 0)      # ALL_STATES, not state 1
        self.assertIn('m1 and index 1+2', sel)
        self.assertIn('m2 and index 5', sel)
        self.assertIn(' or ', sel)

        # Multi-state distinguishing assertion: a FakeCmd that returns a WIDER
        # bbox for state=0 (all states, what the renderer sees) and a NARROWER
        # one for state=1 (first state only, the old wrong path) lets us verify
        # that the fix returns the all-states result.  Under state=1 the midpoint
        # would be 1.5 (mid of [1,2]) — not 0.0 — so assertNotAlmostEqual proves
        # the test is not vacuously true.
        class _MultiStateFakeCmd(FakeCmd):
            def get_extent(self, selection, state=0, *a, **k):
                self.extent_calls.append((selection, state))
                if state == 0:          # all-states union (what renderer computes)
                    return [[-5.0, 0.0, 0.0], [5.0, 0.0, 0.0]]
                else:                   # state-1-only (wrong; old code used this)
                    return [[1.0, 0.0, 0.0], [2.0, 0.0, 0.0]]
        self.scenes._scene_focus['B'] = [('m1', 1)]
        ms = _MultiStateFakeCmd(objects=['m1'])
        result = self.anim.focus_centroid('B', ms)
        self.assertIsNotNone(result)
        self.assertAlmostEqual(result[0], 0.0)     # midpoint of all-states [-5,5]
        self.assertNotAlmostEqual(result[0], 1.5)  # would be 1.5 under state=1

    def test_focus_centroid_none_when_unresolvable(self):
        a, s = self.anim, self.scenes
        self.assertIsNone(a.focus_centroid('A', FakeCmd()))       # nothing captured
        s._scene_focus['A'] = [('gone', 1)]
        self.assertIsNone(a.focus_centroid('A', FakeCmd(objects=['m1'])))  # object gone
        s._scene_focus['B'] = [('m1', 1)]
        # ExecutiveGetExtent returned false -> the +/-0.5 placeholder box, which
        # must NOT be mistaken for a real target at the origin.
        self.assertIsNone(a.focus_centroid('B', FakeCmd(objects=['m1'])))

    def test_a_mixed_autofocus_pair_still_pulls(self):
        a = self.anim
        # A auto-locks onto a target; B uses a manual distance.  The renderer
        # shows a concrete plane for BOTH, so the transition between them is a
        # real focus pull — the old "only when both autofocus" rule refused it and
        # the focus snapped at the cut.
        self.scenes._scene_settings['A'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'off',
                                            'metal_dof_focus': '120'}
        a.focus_centroid = lambda name, _self=None: [0.0, 0.0, 0.0]
        fake = ViewCmd()
        pull = a.build_dof_transition([(1, 'A', 0.0), (11, 'B', 0.0)], _self=fake)
        self.assertEqual(sorted(pull), list(range(2, 11)))
        dists = [pull[f]['metal_dof_focus'] for f in range(2, 11)]
        self.assertEqual(dists, sorted(dists))          # ramps toward 120
        self.assertLess(dists[0], 60.0)                 # starts at A's own depth
        self.assertGreater(dists[-1], 110.0)            # ends approaching 120
        for vals in pull.values():
            self.assertEqual(vals['metal_dof_autofocus'], 0.0)

    def test_pull_emits_monotone_distance_and_disables_autofocus(self):
        a = self.anim
        self.scenes._scene_settings['A'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'on'}

        # ViewCmd's camera DOLLIES: each frame pulls back by 0.5 Å, so the depth
        # of a fixed point differs per frame.  A lerp of endpoint distances would
        # miss this; only per-frame reprojection tracks the moving camera.
        fake = ViewCmd()
        # Stub the centroids: A near (z=0), B far (z=-20).
        a.focus_centroid = lambda name, _self=None: (
            [0.0, 0.0, 0.0] if name == 'A' else [0.0, 0.0, -20.0])

        pull = a.build_dof_transition([(1, 'A', 0.0), (11, 'B', 0.0)], _self=fake)

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
        self.scenes._scene_settings['A'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof': 'on',
                                            'metal_dof_autofocus': 'on'}
        a.focus_centroid = lambda name, _self=None: [1.0, 2.0, 3.0]
        # DOF on both sides and a working (dollying) camera, so the identical
        # targets are the only thing suppressing the pull: delete the
        # equal-distance guard and this emits 7 frames of pointless focus
        # overrides (which would also switch autofocus OFF across a transition
        # that never needed it).
        fake = ViewCmd()
        self.assertEqual(a.build_dof_transition([(1, 'A', 0.0), (9, 'B', 0.0)],
                                                _self=fake), {})
        # The frames WERE visited: the empty result comes from the distances
        # matching, not from an early bail that would mask a broken pull.
        self.assertEqual(fake.frames_seen, list(range(2, 9)))


def _view(tz=-50.0, origin=(0.0, 0.0, 0.0)):
    """An 18-float cmd.get_view() with identity rotation, camera at `tz` and the
    rotation origin at `origin`."""
    return [1, 0, 0,
            0, 1, 0,
            0, 0, 1,
            0.0, 0.0, float(tz),
            float(origin[0]), float(origin[1]), float(origin[2]),
            -60.0, -40.0, 20.0]


class TestResolveFocus(unittest.TestCase):
    """resolve_focus mirrors SceneRender.cpp:2043-2072 — the ONLY place that knows
    what distance the renderer will actually show for a scene."""

    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()

    def test_manual_distance_wins_over_the_fallback(self):
        self.scenes._scene_settings['A'] = {'metal_dof_focus': '14.00000',
                                            'metal_dof_autofocus': 'off'}
        # Centre of interest here is 50 Å, so 14 can only come from the manual value.
        self.assertAlmostEqual(
            self.anim.resolve_focus('A', _view(), FakeCmd()), 14.0)

    def test_autofocus_uses_the_centroid_depth_and_discards_a_stale_manual(self):
        # The renderer zeroes dofFocus before the autofocus block
        # (SceneRender.cpp:2050), and the UI leaves the manual slider's stale
        # value behind while auto-lock is on — so 99 must NOT be what we resolve.
        self.scenes._scene_settings['A'] = {'metal_dof_focus': '99.0',
                                            'metal_dof_autofocus': 'on'}
        self.scenes._scene_focus['A'] = [('m1', 1)]
        fake = FakeCmd(objects=['m1'], extent=[[0.0, 0.0, 10.0],
                                               [0.0, 0.0, 30.0]])
        # bbox midpoint z = 20 -> depth = -(20 - 50) = 30.
        self.assertAlmostEqual(
            self.anim.resolve_focus('A', _view(), fake), 30.0)

    def test_auto_zero_resolves_to_the_centre_of_interest(self):
        # focus = 0 with autofocus off: the renderer falls back to the rotation
        # origin's own depth, which is -tz whatever the origin's coordinates are.
        self.scenes._scene_settings['A'] = {'metal_dof_focus': '0.00000',
                                            'metal_dof_autofocus': 'off'}
        for origin in ((0.0, 0.0, 0.0), (7.0, -8.0, 9.0)):
            self.assertAlmostEqual(
                self.anim.resolve_focus('A', _view(-50.0, origin), FakeCmd()),
                50.0, msg=str(origin))
        self.assertAlmostEqual(
            self.anim.resolve_focus('A', _view(-123.0), FakeCmd()), 123.0)

    def test_autofocus_with_a_dead_target_falls_through_to_the_origin(self):
        self.scenes._scene_settings['A'] = {'metal_dof_focus': '99.0',
                                            'metal_dof_autofocus': 'on'}
        self.scenes._scene_focus['A'] = [('gone', 1)]      # object deleted since
        self.assertAlmostEqual(
            self.anim.resolve_focus('A', _view(), FakeCmd(objects=['m1'])), 50.0)

    def test_none_when_nothing_resolves(self):
        self.scenes._scene_settings['A'] = {'metal_dof_focus': '0',
                                            'metal_dof_autofocus': 'off'}
        a = self.anim
        self.assertIsNone(a.resolve_focus('A', None, FakeCmd()))     # no view
        # Camera BEHIND the origin: the centre of interest is not in front of it,
        # so there is no distance to focus at (the renderer leaves dofFocus 0 and
        # the shader samples the centre pixel instead).
        self.assertIsNone(a.resolve_focus('A', _view(50.0), FakeCmd()))
        self.assertIsNone(a.resolve_focus('unknown-scene', _view(0.0), FakeCmd()))


class TestDofFade(unittest.TestCase):
    """metal_dof is boolean, so a scene switching it POPS. build_dof_transition
    keeps DOF enabled across such a transition and dissolves the blur instead."""

    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()
        self.floor = self.anim._FLOOR['metal_dof_aperture']

    def _store(self, name, **settings):
        self.scenes._scene_settings[name] = {k: str(v)
                                             for k, v in settings.items()}

    def _pair(self):
        self._store('OFF', metal_dof='off', metal_dof_aperture=14,
                    metal_dof_focus=0, metal_dof_autofocus='off')
        self._store('ON', metal_dof='on', metal_dof_aperture=6,
                    metal_dof_focus=30, metal_dof_autofocus='off')

    def test_fade_in_ramps_the_aperture_up_from_the_floor(self):
        self._pair()
        out = self.anim.build_dof_transition([(1, 'OFF', 0.0), (11, 'ON', 0.0)],
                                             _self=ViewCmd())
        self.assertEqual(sorted(out), list(range(2, 11)))
        aps = [out[f]['metal_dof_aperture'] for f in range(2, 11)]
        self.assertEqual(aps, sorted(aps))                     # monotone up
        # NEVER <= 0: that is the renderer's MAXIMUM-blur sentinel
        # (RendererMetal.mm:2528), so a fade that reached it would flash full blur.
        self.assertTrue(all(v > 0.0 for v in aps), aps)
        self.assertTrue(all(v >= self.floor for v in aps), aps)
        # Starts at the FLOOR (no blur), not at either scene's captured aperture.
        self.assertLess(aps[0], 1.0)
        self.assertLess(aps[-1], 6.0)
        self.assertGreater(aps[-1], 5.0)
        for f in range(2, 11):
            self.assertEqual(out[f]['metal_dof'], 1.0)         # renderable at all
            # Focus HOLDS at the enabled side's plane, autofocus off or the
            # renderer would discard it.
            self.assertAlmostEqual(out[f]['metal_dof_focus'], 30.0)
            self.assertEqual(out[f]['metal_dof_autofocus'], 0.0)

    def test_fade_ramp_hits_the_floor_and_the_enabled_aperture_exactly(self):
        # With a LINEAR power the ramp's own endpoints can be recovered by
        # extrapolating one step past each interior frame — pinning them without
        # re-deriving the eased values the code under test computes.
        self._pair()
        out = self.anim.build_dof_transition([(1, 'OFF', 0.0), (11, 'ON', 0.0)],
                                             _self=ViewCmd(), power=1.0)
        aps = [out[f]['metal_dof_aperture'] for f in range(2, 11)]
        step = aps[1] - aps[0]
        self.assertAlmostEqual(aps[0] - step, self.floor)      # t=0 -> floor
        self.assertAlmostEqual(aps[-1] + step, 6.0)            # t=1 -> ON's value

    def test_fade_out_is_the_mirror_image(self):
        self._pair()
        kf_in = [(1, 'OFF', 0.0), (11, 'ON', 0.0)]
        kf_out = [(1, 'ON', 0.0), (11, 'OFF', 0.0)]
        fin = self.anim.build_dof_transition(kf_in, _self=ViewCmd())
        fout = self.anim.build_dof_transition(kf_out, _self=ViewCmd())
        self.assertEqual(sorted(fout), list(range(2, 11)))
        aps = [fout[f]['metal_dof_aperture'] for f in range(2, 11)]
        self.assertEqual(aps, sorted(aps, reverse=True))       # monotone down
        self.assertTrue(all(v > 0.0 for v in aps), aps)
        self.assertGreater(aps[0], 5.0)                        # starts at ON's 6
        self.assertLess(aps[-1], 1.0)                          # ends at the floor
        # The easing is symmetric (ease(t) + ease(1-t) == 1), so frame f of the
        # fade-out must equal frame 12-f of the fade-in exactly.
        for f in range(2, 11):
            self.assertAlmostEqual(fout[f]['metal_dof_aperture'],
                                   fin[12 - f]['metal_dof_aperture'])
            self.assertEqual(fout[f]['metal_dof'], 1.0)
            self.assertAlmostEqual(fout[f]['metal_dof_focus'], 30.0)

    def test_the_destination_keyframe_restores_dof_off_after_a_fade_out(self):
        # The fade leaves metal_dof=1 on the interior frames; nothing turns it back
        # off except the destination scene's own mark, so that has to be authored
        # and it has to carry the captured 'off'.
        self._pair()
        fake = ViewCmd()
        self.anim._track.clear()
        self.anim._scene_marks[:] = []
        self.anim.author([(1, 'ON', 0.0), (11, 'OFF', 0.0)], _self=fake)
        self.assertIn((11, 'OFF'), self.anim._scene_marks)
        marked = FakeCmd()
        self.anim.enter_scene(base64.b64encode(b'OFF').decode('ascii'),
                              _self=marked)
        self.assertEqual(dict(marked.sets).get('metal_dof'), 'off')

    def test_dof_off_on_both_sides_emits_nothing(self):
        # Differing focus AND aperture, so the only reason to stay silent is that
        # DOF is never visible across this transition.
        self._store('A', metal_dof='off', metal_dof_aperture=2,
                    metal_dof_focus=10, metal_dof_autofocus='off')
        self._store('B', metal_dof='off', metal_dof_aperture=20,
                    metal_dof_focus=90, metal_dof_autofocus='off')
        self.assertEqual(
            self.anim.build_dof_transition([(1, 'A', 0.0), (11, 'B', 0.0)],
                                           _self=ViewCmd()), {})

    def test_the_fade_overrides_the_plain_aperture_ramp(self):
        # The disabled side's captured aperture is meaningless — nothing was ever
        # rendered with it — so build_track's 2 -> 20 ramp must not survive
        # underneath the fade (author applies the DOF builder last).
        self._store('OFF', metal_dof='off', metal_dof_aperture=2)
        self._store('ON', metal_dof='on', metal_dof_aperture=20)
        fake = ViewCmd()
        self.anim._track.clear()
        self.anim._scene_marks[:] = []
        self.anim.author([(1, 'OFF', 0.0), (11, 'ON', 0.0)], _self=fake)
        plain = self.anim.build_track([(1, 'OFF', 0.0), (11, 'ON', 0.0)])
        self.assertGreater(plain[2]['metal_dof_aperture'], 2.0)   # the ramp exists
        self.assertLess(self.anim._track[2]['metal_dof_aperture'], 2.0)


class TestUserSessionRegression(unittest.TestCase):
    """The four scenes from the reported session (issue #204), verbatim:

        001  dof=off  focus=0    aperture=14
        002  dof=on   focus=0    aperture=14
        003  dof=on   focus=120  aperture=14
        004  dof=on   focus=40   aperture=40

    Before the fix 001->002 animated NOTHING (DOF popped on) and 002->003
    animated NOTHING (a 0 endpoint was refused), which is exactly what the user
    saw: "aperture interpolates but focus doesn't", plus a hard pop.
    """

    KFS = [(1, '001', 0.0), (11, '002', 0.0), (21, '003', 0.0), (31, '004', 0.0)]

    def setUp(self):
        self.scenes, self.anim = load_modules()
        self.scenes.clear_all()
        self.anim._track.clear()
        self.anim._scene_marks[:] = []
        for name, dof, focus, ap in (('001', 'off', 0, 14), ('002', 'on', 0, 14),
                                     ('003', 'on', 120, 14), ('004', 'on', 40, 40)):
            self.scenes._scene_settings[name] = {
                'metal_dof': dof, 'metal_dof_focus': '%.5f' % focus,
                'metal_dof_aperture': '%.5f' % ap, 'metal_dof_autofocus': 'off'}

    def _authored(self):
        """What author() actually writes into the movie, DOF builder overlaid on
        the plain ramp — the combination is what the user sees."""
        self.anim.author(self.KFS, _self=ViewCmd())
        return dict(self.anim._track)

    def test_001_to_002_fades_dof_in_instead_of_popping(self):
        track = self._authored()
        frames = list(range(2, 11))
        for f in frames:
            self.assertIn(f, track, "001->002 animates nothing on frame %d" % f)
            self.assertEqual(track[f]['metal_dof'], 1.0)
            self.assertGreater(track[f]['metal_dof_focus'], 0.0)   # held, resolved
            self.assertEqual(track[f]['metal_dof_autofocus'], 0.0)
        aps = [track[f]['metal_dof_aperture'] for f in frames]
        self.assertEqual(aps, sorted(aps))
        self.assertTrue(all(v > 0.0 for v in aps), aps)
        self.assertLess(aps[0], 1.0)          # starts at the floor, not at 14
        self.assertGreater(aps[-1], 12.0)     # ends approaching the captured 14

    def test_002_to_003_ramps_focus_from_the_resolved_auto_distance(self):
        track = self._authored()
        frames = list(range(12, 21))
        for f in frames:
            self.assertIn(f, track, "002->003 animates nothing on frame %d" % f)
            self.assertIn('metal_dof_focus', track[f])
            self.assertEqual(track[f]['metal_dof_autofocus'], 0.0)
        d = [track[f]['metal_dof_focus'] for f in frames]
        self.assertEqual(d, sorted(d))        # monotone toward 120
        # 002's focus of 0 is AUTO: under ViewCmd's camera the centre of interest
        # sits ~56-60 Å out, so the ramp starts there rather than at a literal 0.
        self.assertGreater(d[0], 50.0)
        self.assertLess(d[0], 70.0)
        self.assertGreater(d[-1], 110.0)      # ends approaching 120
        self.assertLess(d[-1], 120.0)

    def test_003_to_004_still_ramps_both_aperture_and_focus(self):
        track = self._authored()
        frames = list(range(22, 31))
        aps = [track[f]['metal_dof_aperture'] for f in frames]
        self.assertEqual(aps, sorted(aps))                     # 14 -> 40
        self.assertTrue(all(14.0 < v < 40.0 for v in aps), aps)
        d = [track[f]['metal_dof_focus'] for f in frames]
        self.assertEqual(d, sorted(d, reverse=True))           # 120 -> 40
        self.assertTrue(all(40.0 < v < 120.0 for v in d), d)


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

    def _slots_as_cmds(self, fake, n):
        """The movie's Cmd[] as PyMOL would hold it, from the fake's accumulator."""
        cmds = [''] * n
        for f, slot in fake._slots.items():
            if 1 <= f <= n:
                cmds[f - 1] = slot
        return cmds

    def test_reauthoring_leaves_no_orphan_commands(self):
        # Re-authoring WITHOUT an intervening mset (place_scene does exactly this)
        # used to append the new pass on top of the previous one's commands.
        # session_save can only strip what it can regenerate from the CURRENT
        # _track/_scene_marks, so every orphan survived into the .pse — and a
        # single non-empty frame command there trips MovieSetLock on load
        # (Movie.cpp:459-462), killing the commands, the scene recall AND the
        # camera track.  author() must un-emit its previous output first.
        self._two_scenes()
        fake = FakeCmd()
        self.anim.author([(1, 'A', 0.0), (21, 'B', 0.0)], _self=fake)
        self.anim.author([(1, 'A', 0.0), (11, 'B', 0.0)], _self=fake)
        sess = {'movie': [None] * 6}
        sess['movie'][5] = self._slots_as_cmds(fake, 24)
        self.anim.session_save(sess, _self=fake)
        leftover = ''.join(sess['movie'][5])
        # Nothing but our own text was ever written, so the strip must empty it all.
        self.assertEqual(
            leftover, '',
            "orphaned frame commands survive into the .pse: %r" %
            [(i + 1, s) for i, s in enumerate(sess['movie'][5]) if s])

    def test_clear_authored_blanks_every_frame_it_wrote(self):
        self._two_scenes()
        fake = FakeCmd()
        self.anim.author([(1, 'A', 0.0), (6, 'B', 0.0)], _self=fake)
        expected = sorted(set(list(self.anim._track) +
                              [f for f, _n in self.anim._scene_marks]))
        fake.done[:] = []
        self.anim.clear_authored(_self=fake)
        self.assertEqual(sorted(f for f, _c in fake.done), expected)
        self.assertTrue(all(c == '' for _f, c in fake.done))
        # mdo SETS the slot, so our text is gone from every frame we owned.
        self.assertEqual(''.join(self._slots_as_cmds(fake, 8)), '')

    def test_author_empty_clears_previous_state(self):
        # A movie rebuilt WITHOUT scenes must not keep the old animation: mset
        # wipes Cmd[] but nothing reset the globals, so session_save persisted a
        # track belonging to a movie that no longer exists (and session_restore
        # mappended it back, one Movie-Error per out-of-range frame).
        self._two_scenes()
        fake = FakeCmd()
        self.anim.author([(1, 'A', 0.0), (6, 'B', 0.0)], _self=fake)
        self.assertTrue(self.anim._track)
        self.assertTrue(self.anim._scene_marks)
        self.assertEqual(self.anim.author([], _self=fake), 0)
        self.assertEqual(self.anim._track, {})
        self.assertEqual(self.anim._scene_marks, [])
        sess = {}
        self.anim.session_save(sess, _self=fake)
        self.assertEqual(sess['raymol_movie_anim'], {'track': {}, 'marks': []})

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
        # Build cmds from the fake's slot accumulator — the single source of truth
        # for what PyMOL would store.  Re-implementing the concatenation here would
        # let the fake and the test drift (exactly the failure mode that hid the
        # original '; ' vs ';' bug).
        cmds = [''] * 8
        for f, slot in fake._slots.items():
            if 1 <= f <= 8:
                cmds[f - 1] = slot
        # Frame 4 (index 3) already had a rock command before our mappend.
        cmds[3] = 'turn y, 1' + cmds[3]
        sess = {'movie': [None] * 6}
        sess['movie'][5] = cmds
        self.anim.session_save(sess, _self=fake)
        out = sess['movie'][5]
        self.assertNotIn('enter_scene', ''.join(out))    # ours gone
        self.assertNotIn('set ambient', ''.join(out))    # track cmds gone too
        self.assertEqual(out[3], 'turn y, 1')            # exactly theirs, nothing ours

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

    def test_strip_handles_a_frame_carrying_both_mark_and_track(self):
        # A restored session can put a track entry and a scene mark on the SAME
        # frame; real mappend then leaves ";mark;track" in that slot (each
        # mappend call prefixes ';').  The strip must empty that slot entirely —
        # a leftover locks the whole movie on the next load.
        #
        # The previous version of this test used author() with keyframes designed
        # to collide but the collision never materialised (span-0 pairs and
        # same-scene pairs were both skipped), so _track was always empty and only
        # the mark path was exercised.  session_restore is the reachable path that
        # genuinely co-locates both pieces on one frame.
        fake = FakeCmd()
        self.anim.session_restore(
            {'raymol_movie_anim': {'track': {'1': {'ambient': 0.5}},
                                   'marks': [[1, 'A']]}}, _self=fake)
        # Both pieces must have landed on frame 1.
        self.assertTrue(any(f == 1 and 'enter_scene' in s
                            for f, s in fake.appended),
                        "expected enter_scene on frame 1")
        self.assertTrue(any(f == 1 and 'set ambient' in s
                            for f, s in fake.appended),
                        "expected set ambient on frame 1")
        # Build cmds from the slot accumulator — the single source of truth.
        cmds = [''] * 4
        for f, slot in fake._slots.items():
            if 1 <= f <= 4:
                cmds[f - 1] = slot
        sess = {'movie': [None] * 6}
        sess['movie'][5] = cmds
        self.anim.session_save(sess, _self=fake)
        leftover = ''.join(sess['movie'][5])
        self.assertNotIn('enter_scene', leftover)
        self.assertNotIn('set ambient', leftover)
        self.assertEqual(sess['movie'][5][0], '')    # frame 1 fully emptied
