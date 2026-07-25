# Per-Scene Render-Setting Movie Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a movie built from scenes apply each scene's captured render settings as it plays — interpolating continuous ones (depth-of-field, lighting) in step with the camera's easing, stepping discrete ones at the cut, and producing a true focus pull when Auto-lock targets differ.

**Architecture:** A new module `raymol_scene_anim` reads `raymol_scenes`' per-scene captures and authors one `cmd.mappend` command per frame — the only vehicle available, since `ViewElem` has no channel for global settings and movie playback recalls scenes purely in C++. The authored track is persisted as structured data (never raw command strings) so a `.pse` round-trips without tripping PyMOL's movie security lock.

**Tech Stack:** Python (PyMOL `cmd` API, `pymol2` headless for tests), the RayMol macOS build driven over MCP in a disposable VM for functional verification.

**Spec:** `docs/superpowers/specs/2026-07-25-scene-render-setting-movie-animation-design.md`

## Global Constraints

- Python 3.9+. No Python formatter — match surrounding style.
- Every cross-module import of `raymol_scenes` / `raymol_scene_anim` from an existing core module MUST be import-guarded (`try/except` → no-op) so upstream/non-RayMol builds stay green. Mirrors `modules/pymol/cmd.py:59-66`.
- Use **`cmd.mappend`**, never `cmd.mdo`, to author frame commands: `movie._rock`/`_nutate` already own frame commands in `add_scenes` and `mdo` would overwrite them.
- Emission must happen **after** the authoring path's `cmd.mset(...)` (mset clears all frame commands, `Movie.cpp:918`) and **after** `cmd.mview('interpolate')` (the focus pull samples interpolated views).
- **Security-critical:** persist only structured `{frame: {setting: number}}` data and regenerate command strings locally. Never persist or replay raw command strings — a hostile `.pse` must not be able to smuggle executable code through our session key.
- Scene names embedded in an emitted command string MUST be base64-encoded (the string is executed by the PyMOL parser; an unescaped quote/semicolon is a command-injection vector).
- `cmd.get(setting)` returns **strings** (`'on'`/`'off'` for booleans, `'0.80000'` for floats). Always convert before arithmetic.
- Never emit `metal_dof_aperture` or `metal_dof_range` ≤ their floor (0.02): `≤0` / `≤0.01` are sentinels meaning **14 = maximum blur** (`RendererMetal.mm:2528,2532`).
- Do NOT re-apply object TTT from a movie frame command — the movie owns object motion through its own `mview` keyframes and re-applying would fight the interpolation.
- Do not commit to `master`. Work continues on `claude/issue-204-0609e7`; the work extends PR #229.
- Local tests: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q <file>`.

---

## File Structure

- `modules/pymol/raymol_scene_anim.py` (**create**) — the whole feature: classification, easing, track building, focus pull, emission, session tasks. One responsibility: turn per-scene captures into per-frame movie commands.
- `modules/pymol/raymol_scenes.py` (**modify**) — add three public accessors (`scene_settings_map`, `scene_focus_map`, `apply_focus_target`). No behavior change.
- `modules/pymol/appkit_movie.py` (**modify**) — one-line hook in `rebuild`, `append_template`, `place_scene`.
- `modules/pymol/movie.py` (**modify**) — one-line hook in `add_scenes`.
- `modules/pymol/cmd.py` (**modify**) — register the new session save/restore tasks.
- `testing/tests/test_raymol_scene_anim.py` (**create**) — bare-pytest tests (no C++ build needed).

---

## Task 1: Accessors + pure helpers (classification, easing, clamping)

**Files:**
- Modify: `modules/pymol/raymol_scenes.py`
- Create: `modules/pymol/raymol_scene_anim.py`
- Create: `testing/tests/test_raymol_scene_anim.py`

**Interfaces:**
- Consumes: `raymol_scenes.CAPTURE`, `raymol_scenes._scene_settings`, `raymol_scenes._scene_focus`, `raymol_scenes._apply_focus`.
- Produces (used by Tasks 2-5):
  - `raymol_scenes.scene_settings_map(name) -> dict`
  - `raymol_scenes.scene_focus_map(name) -> list`
  - `raymol_scenes.apply_focus_target(name, _self=cmd) -> None`
  - `raymol_scene_anim.INTERPOLATE` (frozenset), `_FLOOR` (dict)
  - `raymol_scene_anim.ease(t, power=1.4) -> float`
  - `raymol_scene_anim.effective_power(power) -> float`
  - `raymol_scene_anim._as_float(v) -> float|None`, `_truthy(v) -> bool`
  - `raymol_scene_anim.interpolatable(setting, a, b) -> bool`
  - `raymol_scene_anim.value_at(setting, a, b, e) -> float`

- [ ] **Step 1: Write the failing test**

Create `testing/tests/test_raymol_scene_anim.py`:

```python
"""Headless unit tests for pymol.raymol_scene_anim — per-scene render-setting
animation across a scene movie. No C++ build required:

    /Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q \
        testing/tests/test_raymol_scene_anim.py

The fork's modules are not in the venv's stock pymol, so the modules under test
are loaded directly from the repo by path.
"""
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py`
Expected: FAIL — `FileNotFoundError` / `No such file or directory: '.../modules/pymol/raymol_scene_anim.py'` (the module does not exist yet).

- [ ] **Step 3: Add the three accessors to `raymol_scenes.py`**

Insert immediately after the existing `scene_ttt_map` function:

```python
def scene_settings_map(name):
    """Copy of the render settings captured for scene `name` ({} if none)."""
    return dict(_scene_settings.get(name, {}))


def scene_focus_map(name):
    """Copy of the autofocus target atoms captured for scene `name` ([] if none)."""
    return list(_scene_focus.get(name, []))


def apply_focus_target(name, _self=cmd):
    """Re-point the 'dof_focus' autofocus selection at scene `name`'s captured
    target. Public wrapper over _apply_focus for the movie animator, which must
    restore the focus target WITHOUT touching object TTT (a movie owns object
    motion through its own keyframes)."""
    _apply_focus(name, _self)
```

- [ ] **Step 4: Create `modules/pymol/raymol_scene_anim.py` with the helpers**

```python
"""Animate per-scene render settings across a scene movie.

Movie playback recalls scenes entirely in C++ (Movie.cpp MovieDoFrameCommand ->
MovieSceneRecall) and never fires the Python cmd.scene hook, so the per-scene
render settings raymol_scenes captures are NOT applied while a movie plays — the
movie keeps whatever was last set interactively (reported as "the DOF setting is
stuck on the last active value"). ViewElem has no channel for global settings, so
the only vehicle is a per-frame movie command.

This module reads raymol_scenes' captures and authors those commands with
cmd.mappend: continuous settings are interpolated across each transition using
the SAME easing curve the camera uses (View.cpp ViewElemInterpolate), discrete
ones step at the scene cut via enter_scene(), and differing depth-of-field
autofocus targets produce a true focus pull.

The authored track is persisted as STRUCTURED DATA and the command strings are
regenerated locally on restore — never persisted or replayed as text. Frame
commands in a .pse trip MovieSetLock, which disables the entire per-frame path
(commands, scene recall AND the camera track), so this module also blanks its own
commands out of the saved session.
"""
import base64

from pymol import cmd

# Continuous settings worth interpolating across a transition. Everything else in
# raymol_scenes.CAPTURE steps at the scene cut: booleans/ints, plus quality knobs
# (surface_quality, metal_dof_quality, metal_msaa, metal_upscale,
# metal_rt_samples) which would force a rebuild hitch every frame.
INTERPOLATE = frozenset([
    "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_exposure", "metal_sss_wrap", "metal_outline_width",
    "metal_rt_ao_radius", "metal_rt_ao_intensity", "metal_rt_shadow_intensity",
    "ambient", "direct", "reflect", "specular", "shininess", "fog",
])

# Values at/below the renderer's sentinel are reinterpreted as 14 (MAXIMUM blur)
# — RendererMetal.mm:2528,2532 — so an interpolated fade must never reach them.
_FLOOR = {"metal_dof_aperture": 0.02, "metal_dof_range": 0.02}

# View.cpp resolves an unspecified mview power to this.
_DEFAULT_POWER = 1.4


def _as_float(v):
    """cmd.get() hands back strings ('0.80000'); booleans come back 'on'/'off'
    and correctly fail here (they are stepped, never interpolated)."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _truthy(v):
    if v is None:
        return False
    if isinstance(v, str):
        return v.strip().lower() in ("on", "1", "true", "yes")
    return bool(v)


def ease(t, power=_DEFAULT_POWER):
    """Normalized transition position -> eased position, mirroring
    ViewElemInterpolate (View.cpp:1165-1177, bias=1, parabolic) so animated
    settings track the camera instead of desyncing (~24% off at t=0.25)."""
    if t <= 0.0:
        return 0.0
    if t >= 1.0:
        return 1.0
    if power == 1.0:
        return t
    if t < 0.5:
        return (t * 2.0) ** power * 0.5
    if t > 0.5:
        return 1.0 - (((1.0 - t) * 2.0) ** power * 0.5)
    return 0.5


def effective_power(power):
    """mview power=0 means 'use the default'; View.cpp's default is 1.4. Swift
    encodes Linear as power=1.0 and Smooth as power=0.0."""
    p = _as_float(power)
    if p is None or p == 0.0:
        return _DEFAULT_POWER
    return p


def interpolatable(setting, a, b):
    """True if `setting` should ramp between numeric endpoints a and b."""
    if setting not in INTERPOLATE:
        return False
    if a is None or b is None:
        return False
    # 0 means "auto (center of interest)" for focus (SceneRender.cpp:2061);
    # ramping through it would sweep to a meaningless plane, so step instead.
    if setting == "metal_dof_focus" and (a == 0.0 or b == 0.0):
        return False
    return True


def value_at(setting, a, b, e):
    """Interpolated value at eased position `e`, clamped off the sentinel floor."""
    v = a + (b - a) * e
    floor = _FLOOR.get(setting)
    if floor is not None and v < floor:
        v = floor
    return v
```

- [ ] **Step 5: Run test to verify it passes**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py`
Expected: PASS — 7 tests.

Also confirm no regression in the existing scene tests:
Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_ttt.py`
Expected: PASS — 12 tests.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/raymol_scenes.py modules/pymol/raymol_scene_anim.py testing/tests/test_raymol_scene_anim.py
git commit -m "feat(movie): scene-anim helpers — easing, classification, sentinel clamping

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Track builder + emission + `enter_scene`

**Files:**
- Modify: `modules/pymol/raymol_scene_anim.py`
- Modify: `testing/tests/test_raymol_scene_anim.py`

**Interfaces:**
- Consumes (Task 1): `INTERPOLATE`, `_FLOOR`, `ease`, `effective_power`, `_as_float`, `_truthy`, `interpolatable`, `value_at`; `raymol_scenes.scene_settings_map`, `raymol_scenes.apply_focus_target`.
- Produces (Tasks 3-5):
  - `build_track(keyframes) -> {int frame: {str setting: float}}` — keyframes is an ordered iterable of `(frame:int, scene_name:str, power:float)`; returns **interior** transition frames only.
  - `frame_command(values) -> str` — `"set a, 1.5; set b, 2"`.
  - `emit_track(track, _self=cmd) -> [int]` — mappend per frame; returns frames touched.
  - `emit_scene_marks(marks, _self=cmd) -> [int]` — marks is `[(frame:int, scene_name:str)]`.
  - `enter_scene(name_b64, _self=cmd) -> None` — the movie-frame callback.

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/test_raymol_scene_anim.py`:

```python
class FakeCmd:
    """Records mappend/set calls; enough surface for track emission."""
    def __init__(self, objects=None):
        self._objects = list(objects or [])
        self.appended = []      # [(frame, command_string)]
        self.sets = []          # [(setting, value)]
        self.selected = []      # [(name, expr)]

    def mappend(self, frame, command):
        self.appended.append((int(frame), command))

    def set(self, setting, value, *a, **k):
        self.sets.append((setting, value))

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
        self.assertFalse(hasattr(fake, 'set_object_ttt_called'))

    def test_enter_scene_tolerates_garbage(self):
        fake = FakeCmd()
        self.anim.enter_scene('!!!not-base64!!!', _self=fake)   # must not raise
        self.assertEqual(fake.sets, [])
```

Add `import base64` to the test file's imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py -k TestTrackBuilder`
Expected: FAIL — `AttributeError: module has no attribute 'build_track'`.

- [ ] **Step 3: Implement the builder and emission**

Append to `modules/pymol/raymol_scene_anim.py`:

```python
def build_track(keyframes):
    """Per-frame interpolated values for the INTERIOR frames of each transition.

    `keyframes` is an ordered iterable of (frame, scene_name, power) where power
    is the easing of the transition INTO that keyframe (as passed to mview).
    Returns {frame: {setting: float}}. Scene keyframes themselves are applied by
    enter_scene (exact captured values), so they are deliberately absent here."""
    from pymol import raymol_scenes as _rs
    track = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, _p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
        f0, f1 = int(f0), int(f1)
        span = f1 - f0
        if span < 2:
            continue                      # no interior frames
        a = _rs.scene_settings_map(n0)
        b = _rs.scene_settings_map(n1)
        pairs = {}
        for s, bv in b.items():
            fa, fb = _as_float(a.get(s)), _as_float(bv)
            if fa is None or fb is None or fa == fb:
                continue                  # missing, non-numeric, or unchanged
            if not interpolatable(s, fa, fb):
                continue
            pairs[s] = (fa, fb)
        if not pairs:
            continue
        power = effective_power(p1)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), power)
            slot = track.setdefault(f, {})
            for s, (fa, fb) in pairs.items():
                slot[s] = value_at(s, fa, fb, e)
    return track


def _fmt(v):
    """Compact, parser-safe number formatting for a command string."""
    return '%.6g' % float(v)


def frame_command(values):
    """'set a, 1.5; set b, 2' for a frame's {setting: value} map ('' if empty)."""
    return '; '.join('set %s, %s' % (s, _fmt(v))
                     for s, v in sorted(values.items()))


def emit_track(track, _self=cmd):
    """Author one mappend per interior frame. mappend (not mdo) so rock/nutate
    frame commands in movie.add_scenes survive. Returns the frames touched."""
    done = []
    for f in sorted(track):
        s = frame_command(track[f])
        if not s:
            continue
        try:
            _self.mappend(int(f), s)
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def scene_mark_command(name):
    """Frame command that makes a scene's own settings + focus target current.
    The name is base64-encoded because this string is executed by the PyMOL
    parser — a raw name containing a quote or semicolon would be an injection."""
    b64 = base64.b64encode(name.encode('utf-8')).decode('ascii')
    return ("from pymol import raymol_scene_anim as _a; "
            "_a.enter_scene('%s')" % b64)


def emit_scene_marks(marks, _self=cmd):
    """Author the enter_scene call at each scene keyframe. `marks` is
    [(frame, scene_name)]. Returns the frames touched."""
    done = []
    for f, name in marks:
        try:
            _self.mappend(int(f), scene_mark_command(name))
            done.append(int(f))
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
    return done


def enter_scene(name_b64, _self=cmd):
    """Movie-frame callback: make scene `name`'s captured render settings and
    autofocus target current. Applies ALL captured settings (at a keyframe the
    scene's own values are by definition the correct endpoint) but deliberately
    NOT object TTT — the movie owns object motion through its own keyframes and
    re-applying would fight the interpolation."""
    try:
        name = base64.b64decode(name_b64).decode('utf-8')
    except Exception:
        return
    from pymol import raymol_scenes as _rs
    for s, v in _rs.scene_settings_map(name).items():
        try:
            _self.set(s, v)
        except Exception:
            pass
    try:
        _rs.apply_focus_target(name, _self)
    except Exception:
        pass
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py`
Expected: PASS — 16 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_scene_anim.py testing/tests/test_raymol_scene_anim.py
git commit -m "feat(movie): build + emit per-frame render-setting track

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Focus pull

**Files:**
- Modify: `modules/pymol/raymol_scene_anim.py`
- Modify: `testing/tests/test_raymol_scene_anim.py`

**Interfaces:**
- Consumes (Tasks 1-2): `ease`, `effective_power`, `_truthy`, `_as_float`; `raymol_scenes.scene_settings_map`, `raymol_scenes.scene_focus_map`.
- Produces (Task 4-5):
  - `eye_depth(point, view) -> float|None` — positive eye-space distance of a model-space point.
  - `focus_centroid(name, _self=cmd) -> [x,y,z]|None`
  - `build_focus_pull(keyframes, _self=cmd) -> {int frame: {'metal_dof_autofocus': 0.0, 'metal_dof_focus': float}}`

**Rule (spec clarification):** a pull is authored only when **both** adjacent scenes have autofocus on **and** their resolved centroids differ. Any other combination steps at the cut (the autofocus flag itself is a stepped setting applied by `enter_scene`).

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/test_raymol_scene_anim.py`:

```python
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

        view = [1, 0, 0, 0, 1, 0, 0, 0, 1,
                0.0, 0.0, -50.0, 0.0, 0.0, 0.0, -60.0, -40.0, 20.0]

        class ViewCmd(FakeCmd):
            def frame(self, f):
                self.last_frame = int(f)
            def get_view(self):
                return view

        fake = ViewCmd()
        # Stub the centroids: A near (z=0 -> depth 50), B far (z=-20 -> depth 70).
        a.focus_centroid = lambda name, _self=None: (
            [0.0, 0.0, 0.0] if name == 'A' else [0.0, 0.0, -20.0])

        pull = a.build_focus_pull([(1, 'A', 0.0), (11, 'B', 0.0)], _self=fake)
        self.assertEqual(sorted(pull), list(range(2, 11)))
        for vals in pull.values():
            self.assertEqual(vals['metal_dof_autofocus'], 0.0)  # off during pull
        dists = [pull[f]['metal_dof_focus'] for f in range(2, 11)]
        self.assertEqual(dists, sorted(dists))                  # monotone
        self.assertTrue(all(50.0 < d < 70.0 for d in dists))    # between endpoints

    def test_identical_targets_need_no_pull(self):
        a = self.anim
        self.scenes._scene_settings['A'] = {'metal_dof_autofocus': 'on'}
        self.scenes._scene_settings['B'] = {'metal_dof_autofocus': 'on'}
        a.focus_centroid = lambda name, _self=None: [1.0, 2.0, 3.0]
        self.assertEqual(a.build_focus_pull([(1, 'A', 0.0), (9, 'B', 0.0)],
                                            _self=FakeCmd()), {})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py -k TestFocusPull`
Expected: FAIL — `AttributeError: module has no attribute 'eye_depth'`.

- [ ] **Step 3: Implement the focus pull**

Append to `modules/pymol/raymol_scene_anim.py`:

```python
def eye_depth(point, view):
    """Positive eye-space distance (Angstroms, in front of the camera) of a
    MODEL-space point under `view` (a cmd.get_view() result). Same camera math as
    metal_pick._eye_distance: eye_z = R_row2 . (p - origin) + tz, depth = -eye_z."""
    if not view:
        return None
    if len(view) >= 25:
        r20, r21, r22 = view[2], view[6], view[10]
        tz = view[18]
        ox, oy, oz = view[19], view[20], view[21]
    else:                                   # 18-float layout (this build)
        r20, r21, r22 = view[2], view[5], view[8]
        tz = view[11]
        ox, oy, oz = view[12], view[13], view[14]
    ez = (r20 * (point[0] - ox) + r21 * (point[1] - oy)
          + r22 * (point[2] - oz) + tz)
    return -ez


def focus_centroid(name, _self=cmd):
    """Mean MODEL-space coordinate of scene `name`'s captured autofocus target
    atoms, skipping objects that no longer exist. None if unresolvable."""
    from pymol import raymol_scenes as _rs
    atoms = _rs.scene_focus_map(name)
    if not atoms:
        return None
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    groups = {}
    for m, i in atoms:
        if m in live:
            groups.setdefault(m, []).append(int(i))
    if not groups:
        return None
    acc = [0.0, 0.0, 0.0, 0]
    for m, idxs in groups.items():
        sel = '(%s and index %s)' % (m, '+'.join(str(i) for i in idxs))
        try:
            _self.iterate_state(1, sel,
                                'acc[0] += x; acc[1] += y; acc[2] += z; acc[3] += 1',
                                space={'acc': acc})
        except Exception:
            pass
    if acc[3] == 0:
        return None
    return [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3]]


def build_focus_pull(keyframes, _self=cmd):
    """Per-frame focus distance for transitions whose autofocus target moves.

    With metal_dof_autofocus on, the renderer recomputes focus from the
    'dof_focus' selection every frame and DISCARDS metal_dof_focus
    (SceneRender.cpp:2051), so a changing target can only snap. To pull instead,
    autofocus is switched off across the transition and the distance is driven
    per frame: the target centroid is interpolated in model space and its depth
    resolved under THAT frame's interpolated camera (a straight lerp of the two
    endpoint distances would drift whenever the camera dollies).

    Only authored when both scenes have autofocus on and their centroids differ;
    every other combination steps at the cut. Must run AFTER cmd.mview
    ('interpolate') so cmd.frame(f) yields the interpolated view."""
    from pymol import raymol_scenes as _rs
    out = {}
    kfs = sorted(keyframes, key=lambda k: int(k[0]))
    for (f0, n0, _p0), (f1, n1, p1) in zip(kfs, kfs[1:]):
        f0, f1 = int(f0), int(f1)
        span = f1 - f0
        if span < 2:
            continue
        sa = _rs.scene_settings_map(n0)
        sb = _rs.scene_settings_map(n1)
        if not (_truthy(sa.get('metal_dof_autofocus'))
                and _truthy(sb.get('metal_dof_autofocus'))):
            continue                          # not both locked -> step at the cut
        ca = focus_centroid(n0, _self)
        cb = focus_centroid(n1, _self)
        if ca is None or cb is None or ca == cb:
            continue
        power = effective_power(p1)
        for f in range(f0 + 1, f1):
            e = ease((f - f0) / float(span), power)
            p = [ca[i] + (cb[i] - ca[i]) * e for i in range(3)]
            try:
                _self.frame(f)
                d = eye_depth(p, _self.get_view())
            except Exception:
                d = None
            if d is None or d <= 0.0:
                continue
            out[f] = {'metal_dof_autofocus': 0.0, 'metal_dof_focus': d}
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py`
Expected: PASS — 21 tests.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_scene_anim.py testing/tests/test_raymol_scene_anim.py
git commit -m "feat(movie): true focus pull across differing autofocus targets

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `author()` entry point + session persistence

**Files:**
- Modify: `modules/pymol/raymol_scene_anim.py`
- Modify: `modules/pymol/cmd.py`
- Modify: `testing/tests/test_raymol_scene_anim.py`

**Interfaces:**
- Consumes (Tasks 1-3): `build_track`, `build_focus_pull`, `emit_track`, `emit_scene_marks`, `frame_command`, `scene_mark_command`.
- Produces (Task 5):
  - `author(keyframes, _self=cmd) -> int` — the single hook the authoring paths call; keyframes is `[(frame, scene_name, power)]`. Returns the number of frames touched.
  - `session_save(session, *, _self=cmd) -> 1`, `session_restore(session, *, _self=cmd) -> 1`
  - Module globals `_track`, `_scene_marks`.

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/test_raymol_scene_anim.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py -k TestAuthorAndSession`
Expected: FAIL — `AttributeError: module has no attribute '_track'`.

- [ ] **Step 3: Implement `author()` and the session tasks**

Append to `modules/pymol/raymol_scene_anim.py`:

```python
# The animation authored into the CURRENT movie, regenerated on every rebuild.
# {frame: {setting: float}} for interior transition frames...
_track = {}
# ...and [(frame, scene_name)] for the scene keyframes carrying enter_scene.
_scene_marks = []


def author(keyframes, _self=cmd):
    """Author the whole per-scene setting animation for a movie.

    `keyframes` is [(frame, scene_name, power)] for every scene keyframe in the
    movie, in any order (sorted internally by frame). Call AFTER the path's
    cmd.mset and cmd.mview('interpolate'). Returns the number of frames touched."""
    marks = [(int(f), n) for f, n, _p in keyframes]
    track = build_track(keyframes)
    # The pull owns focus wherever it applies, so it overrides the plain ramp.
    for f, vals in build_focus_pull(keyframes, _self).items():
        track.setdefault(f, {}).update(vals)
    _track.clear()
    _track.update(track)
    _scene_marks[:] = sorted(set(marks))
    touched = set(emit_scene_marks(_scene_marks, _self))
    touched.update(emit_track(_track, _self))
    return len(touched)


def _our_commands():
    """{frame: command_string} for every frame command this module authored."""
    out = {}
    for f, name in _scene_marks:
        out[int(f)] = scene_mark_command(name)
    for f, vals in _track.items():
        s = frame_command(vals)
        if s:
            out[int(f)] = (out[int(f)] + '; ' + s) if int(f) in out else s
    return out


# --- .pse persistence (registered in cmd._deferred_init_pymol_internals) ---
def session_save(session, *, _self=cmd):
    """Persist the animation as STRUCTURED data and strip our own frame commands
    out of the saved movie.

    Stripping matters: any non-empty frame command makes session load call
    MovieSetLock (Movie.cpp:459-462), and MovieDoFrameCommand is gated on
    !Locked (Movie.cpp:1051) — so a locked movie loses its commands, its scene
    recall AND its camera track, and RayMol has no security-wizard UI to unlock
    it. We remove only OUR text so a co-located rock/nutate command survives."""
    session['raymol_movie_anim'] = {
        'track': {str(f): dict(v) for f, v in _track.items()},
        'marks': [[int(f), n] for f, n in _scene_marks],
    }
    try:
        mv = session.get('movie')
        cmds = mv[5] if (isinstance(mv, list) and len(mv) > 5) else None
        if isinstance(cmds, list):
            for f, ours in _our_commands().items():
                i = int(f) - 1                  # movie Cmd[] is 0-based
                if 0 <= i < len(cmds) and isinstance(cmds[i], str) and ours in cmds[i]:
                    cmds[i] = cmds[i].replace(';' + ours, '').replace(ours, '')
    except Exception:
        pass
    return 1


def session_restore(session, *, _self=cmd):
    """Rebuild the animation from structured data and RE-AUTHOR the commands.

    Values are validated (known captured setting + real number) and the command
    strings are regenerated here — stored text is never replayed, so a hostile
    .pse cannot smuggle executable code through our session key."""
    _track.clear()
    _scene_marks[:] = []
    d = session.get('raymol_movie_anim')
    if not isinstance(d, dict):
        return 1
    from pymol import raymol_scenes as _rs
    known = set(_rs.CAPTURE)
    raw = d.get('track')
    if isinstance(raw, dict):
        for fs, vals in raw.items():
            try:
                f = int(fs)
            except (TypeError, ValueError):
                continue
            if not isinstance(vals, dict):
                continue
            clean = {}
            for s, v in vals.items():
                if s not in known:
                    continue
                fv = _as_float(v)
                if fv is None:
                    continue
                clean[s] = fv
            if clean:
                _track[f] = clean
    marks = d.get('marks')
    if isinstance(marks, list):
        for m in marks:
            try:
                _scene_marks.append((int(m[0]), str(m[1])))
            except Exception:
                continue
    _scene_marks[:] = sorted(set(_scene_marks))
    emit_scene_marks(_scene_marks, _self)
    emit_track(_track, _self)
    return 1
```

- [ ] **Step 4: Register the session tasks in `cmd.py`**

In `modules/pymol/cmd.py`, immediately after the existing `raymol_scenes` registration block (the one ending `print("raymol_scenes registration failed: %s" % _rs_e)`), add:

```python
    # RayMol: per-scene render-setting animation across a scene movie. Registered
    # AFTER raymol_scenes so its restore runs first — the animation is rebuilt
    # from those captures.
    try:
        from pymol import raymol_scene_anim
        if raymol_scene_anim.session_restore not in _pymol._session_restore_tasks:
            _pymol._session_restore_tasks.append(raymol_scene_anim.session_restore)
        if raymol_scene_anim.session_save not in _pymol._session_save_tasks:
            _pymol._session_save_tasks.append(raymol_scene_anim.session_save)
    except Exception as _ra_e:
        print("raymol_scene_anim registration failed: %s" % _ra_e)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py`
Expected: PASS — 26 tests.

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m py_compile modules/pymol/cmd.py modules/pymol/raymol_scene_anim.py modules/pymol/raymol_scenes.py`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/raymol_scene_anim.py modules/pymol/cmd.py testing/tests/test_raymol_scene_anim.py
git commit -m "feat(movie): author() entry point + security-safe session persistence

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Hook the four authoring paths

**Files:**
- Modify: `modules/pymol/appkit_movie.py` (`rebuild`, `append_template`, `place_scene`)
- Modify: `modules/pymol/movie.py` (`add_scenes`)

**Interfaces:**
- Consumes (Task 4): `raymol_scene_anim.author(keyframes, _self=cmd)` where keyframes is `[(frame, scene_name, power)]`.
- Produces: scene movies carry the setting animation.

- [ ] **Step 1: Hook `appkit_movie.rebuild`**

In `modules/pymol/appkit_movie.py`, in `rebuild`, find:

```python
        motion = []   # objects that received per-scene TTT keyframes (#204)
```
Add immediately after:
```python
        scene_kfs = []   # (frame, scene_name, power) for the setting animation
```

Find (inside the `if sc:` branch, right after the `emit_object_motion` try/except):
```python
                try:
                    from pymol import raymol_scenes as _rs
                    motion += _rs.emit_object_motion(name, f)
                except Exception:
                    pass
```
Add immediately after:
```python
                scene_kfs.append((f, name, power))
```

Find:
```python
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception as e:
                print('MOVIE_ERR:' + str(e))
```
Add immediately after:
```python
        # Per-scene render settings (DOF etc.) across the transitions. AFTER the
        # interpolate above: the focus pull samples each frame's interpolated view.
        if scene_kfs:
            try:
                from pymol import raymol_scene_anim as _an
                _an.author(scene_kfs)
            except Exception as e:
                print('MOVIE_ERR:' + str(e))
```

- [ ] **Step 2: Hook `appkit_movie.append_template` (scenes branch)**

Find:
```python
                motion = []
```
(inside the `elif k == 'scenes':` branch) and add after it:
```python
                scene_kfs = []
```

Find:
```python
                    try:
                        from pymol import raymol_scenes as _rs
                        motion += _rs.emit_object_motion(nm, f)
                    except Exception:
                        pass
```
Add immediately after (same indentation, inside the loop):
```python
                    scene_kfs.append((f, nm, 0.0))
```

Find the per-object interpolate loop that follows `cmd.mview('reinterpolate', power=0.0, linear=0.0)`:
```python
                for obj in dict.fromkeys(motion):
                    try:
                        cmd.mview('interpolate', object=obj)
                    except Exception:
                        pass
```
Add immediately after:
```python
                if scene_kfs:
                    try:
                        from pymol import raymol_scene_anim as _an
                        _an.author(scene_kfs)
                    except Exception as e:
                        print('MOVIE_ERR:' + str(e))
```

- [ ] **Step 3: Hook `appkit_movie.place_scene`**

`place_scene` drops a single marker, so it has no local transition range. Re-author the whole movie's animation from every scene keyframe currently on the timeline. Find, at the end of `place_scene`:

```python
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception:
                pass
```
Add immediately after:
```python
        # Re-author the setting animation across the WHOLE movie: a single dropped
        # marker changes the transitions on both sides of it.
        try:
            from pymol import raymol_scene_anim as _an
            _an.author(_scene_keyframes())
        except Exception as e:
            print('MOVIE_ERR:' + str(e))
```

And add this module-level helper to `modules/pymol/appkit_movie.py`, just above `def place_scene(`:

```python
def _scene_keyframes():
    """[(frame, scene_name, power)] for every scene marker currently on the
    timeline, recovered by scrubbing: a scene-tagged keyframe sets
    scene_current_name when its frame is displayed."""
    out = []
    try:
        n = int(cmd.count_frames())
    except Exception:
        return out
    seen = None
    for f in range(1, n + 1):
        try:
            cmd.frame(f)
            cur = cmd.get('scene_current_name') or ''
        except Exception:
            continue
        if cur and cur != seen:
            out.append((f, cur, 0.0))
        seen = cur
    return out
```

- [ ] **Step 4: Hook `movie.add_scenes`**

In `modules/pymol/movie.py`, in `add_scenes`, find:
```python
        _scene_motion_objs = set()
```
Add immediately after:
```python
        _scene_kfs = []      # (frame, scene, power) — hold start AND dwell end
```

Find the hold-start emit (the first `emit_object_motion` block, right after `cmd.mview("store",frame,scene=scene,freeze=1)`) and add immediately after it, at the same indentation:
```python
            _scene_kfs.append((frame, scene, 0.0))
```

Find the dwell-end emit block (inside `if frame <= act_n_frame:` / `if sweep_mode!=3:`, after its `emit_object_motion` try/except) and add immediately after it, at that same indentation:
```python
                    _scene_kfs.append((frame, scene, 0.0))
```

Find the final per-object interpolate loop:
```python
        for _obj in _scene_motion_objs:
            try:
                cmd.mview("interpolate", object=_obj)
            except Exception:
                pass
```
Add immediately after:
```python
        # Per-scene render settings. Passing BOTH the hold-start and dwell-end
        # keyframes makes the values hold through the dwell (identical endpoints
        # produce no emission) and animate only across the transition.
        if _scene_kfs:
            try:
                from pymol import raymol_scene_anim as _an
                _an.author(_scene_kfs, _self=cmd)
            except Exception:
                pass
```

- [ ] **Step 5: Verify compilation and no regression**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m py_compile modules/pymol/appkit_movie.py modules/pymol/movie.py`
Expected: no output.

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_anim.py testing/tests/test_raymol_scene_ttt.py`
Expected: PASS — 38 tests.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/appkit_movie.py modules/pymol/movie.py
git commit -m "feat(movie): apply per-scene render settings in all four scene-movie paths

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Build + live VM verification

**Files:** none (build and drive the real app).

**Interfaces:** exercises Tasks 1-5 end-to-end against the compiled macOS build.

- [ ] **Step 1: Build the macOS app**

Python-only changes, so no C++ core rebuild is needed — but the SPM plugin gate must be skipped or the build fails before compiling anything:

```bash
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -configuration Debug -derivedDataPath swiftui/build_mac_dd -skipPackagePluginValidation -skipMacroValidation build
```
Expected: `** BUILD SUCCEEDED **`. Then confirm the new module is bundled:
```bash
grep -c "def author" swiftui/build_mac_dd/Build/Products/Debug/RayMol.app/Contents/Resources/modules/pymol/raymol_scene_anim.py
```
Expected: `1`.

- [ ] **Step 2: Deploy to a disposable VM and drive it over MCP**

Use the `raymol-mac-vm` skill: acquire a headless VM, `scp` the `.app` to `~/Apps/`, launch with `RAYMOL_MCP_BIND=0.0.0.0 RAYMOL_MCP_AUTOTRUST=1 RAYMOL_MCP_ENABLE=1` via `launchctl asuser`, wait ~40 s for the listener, then `python3 .claude/skills/raymol-mac-vm/raymol-vm-mcp.py --vm-ip "$IP" ping`.

- [ ] **Step 3: Verify the setting animation (the reported bug)**

Over MCP, run:

```python
from pymol import cmd, appkit_movie
import json, base64
cmd.reinitialize(); cmd.fragment('trp', 'm1')
cmd.set('metal_dof', 1); cmd.set('metal_dof_autofocus', 0)
cmd.set('metal_dof_aperture', 1.0); cmd.scene('A', 'store')
cmd.set('metal_dof_aperture', 9.0); cmd.scene('B', 'store')
def it(f, n):
    return {'frame': f, 'scene': base64.b64encode(n.encode()).decode('ascii'),
            'power': 0.0, 'linear': 0}
appkit_movie.rebuild(json.dumps([it(1, 'A'), it(21, 'B')]))
vals = []
for f in (1, 6, 11, 16, 21):
    cmd.frame(f)
    vals.append((f, round(cmd.get_setting_float('metal_dof_aperture'), 3)))
print(vals)
print('animates:', vals[0][1] != vals[-1][1])
print('monotone:', [v for _, v in vals] == sorted(v for _, v in vals))
print('endpoints exact:', abs(vals[0][1] - 1.0) < 1e-3 and abs(vals[-1][1] - 9.0) < 1e-3)
```
Expected: aperture ramps 1.0 → 9.0 monotonically with distinct interior values; all three checks `True`. (Before this change every frame reported the same value — the reported bug.)

- [ ] **Step 4: Verify scrub correctness and stepped settings**

```python
cmd.frame(21); a_end = cmd.get_setting_float('metal_dof_aperture')
cmd.frame(6);  a_back = cmd.get_setting_float('metal_dof_aperture')
print('scrub back is frame-accurate:', abs(a_back - a_end) > 1e-3)
```
Expected: `True` — jumping backward yields frame 6's value, not the last-executed one (this is why every frame carries a command).

- [ ] **Step 5: Verify the focus pull**

```python
from pymol import cmd, appkit_movie
import json, base64
cmd.reinitialize(); cmd.fab('ACDEFGHIKLMNPQRST', 'pep'); cmd.orient('pep')
cmd.set('metal_dof', 1)
cmd.select('dof_focus', 'pep and resi 1'); cmd.set('metal_dof_autofocus', 1)
cmd.scene('A', 'store')
cmd.select('dof_focus', 'pep and resi 17')
cmd.scene('B', 'store')
def it(f, n):
    return {'frame': f, 'scene': base64.b64encode(n.encode()).decode('ascii'),
            'power': 0.0, 'linear': 0}
appkit_movie.rebuild(json.dumps([it(1, 'A'), it(21, 'B')]))
rows = []
for f in (1, 6, 11, 16, 21):
    cmd.frame(f)
    rows.append((f, round(cmd.get_setting_float('metal_dof_focus'), 2),
                 round(cmd.get_setting_float('metal_dof_autofocus'), 0)))
print(rows)
mid = [d for f, d, _ in rows if f in (6, 11, 16)]
print('pull is monotone:', mid == sorted(mid) or mid == sorted(mid, reverse=True))
print('autofocus off mid-pull:', all(af == 0 for f, _, af in rows if f in (6, 11, 16)))
print('autofocus relocked at B:', [af for f, _, af in rows if f == 21] == [1])
```
Expected: focus distance moves monotonically across the transition, autofocus is 0 during it, and 1 again at B's keyframe.

- [ ] **Step 6: Verify the `.pse` round-trip does NOT lock the movie**

```python
cmd.save('/tmp/anim.pse')
cmd.reinitialize(); cmd.load('/tmp/anim.pse')
cmd.frame(1);  v1 = cmd.get_view()[0:3]
cmd.frame(21); v2 = cmd.get_view()[0:3]
print('camera track alive after reload:', v1 != v2)     # the lock would kill this
a = []
for f in (1, 11, 21):
    cmd.frame(f); a.append(round(cmd.get_setting_float('metal_dof_aperture'), 3))
print('animation restored:', a[0] != a[-1], a)
```
Expected: both `True`. A failure here means the security lock fired — check that `session_save`'s blanking matched the authored strings.

- [ ] **Step 7: Release the VM and report**

Release the lease via `mcp__mac-vm-pool__release_vm`. Record the observed values for each step above in the report; a step that could not be run must be reported as not-run, never as passing.

---

## Self-Review

**Spec coverage:** Goal 1 (settings apply in playback and export) → Tasks 2, 5, 6 (export shares the `cmd.frame` path verified in Step 3-4). Goal 2 (smooth interpolation in step with the camera) → Task 1 `ease`, Task 2 `build_track`. Goal 3 (focus pull) → Task 3, verified Task 6 Step 5. Goal 4 (`.pse` survives without the lock) → Task 4, verified Task 6 Step 6. Spec's classification, sentinel floors, base64 injection-safety, structured-only persistence, `mappend`-not-`mdo`, emit-after-interpolate, and the four hook points all map to tasks. The spec's "either scene has autofocus on" is narrowed in Task 3 to "both, with differing centroids" and stated explicitly there.

**Placeholder scan:** No TBD/TODO. Every code step carries complete code; every test step has real assertions and an exact command with expected output.

**Type consistency:** `keyframes` is `[(frame, scene_name, power)]` in `build_track`, `build_focus_pull`, and `author`, and every hook in Task 5 builds exactly that shape. `marks` is `[(frame, scene_name)]` in `emit_scene_marks` and `_scene_marks`. `_track` is `{int: {str: float}}` everywhere. `scene_settings_map`/`scene_focus_map`/`apply_focus_target` are defined in Task 1 and used with those names in Tasks 2-3.
