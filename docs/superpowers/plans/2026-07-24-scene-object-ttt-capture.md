# Per-Scene Object TTT Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scenes capture each object's Move-mode TTT (position/orientation), restore it on recall, persist it in `.pse`, and smoothly animate it in movies built from scenes.

**Architecture:** `raymol_scenes.py` becomes the unified per-scene "extras" backend (render settings + object TTT). A single guarded hook in `cmd.scene` (`viewing.py`) fires capture/restore on every scene action from any path (UI, console, MCP, movie-assembly). Movie object motion is authored by emitting `cmd.mview('store', object=…)` keyframes at build time, which the core interpolates during playback and export.

**Tech Stack:** Python (PyMOL `cmd` API, `pymol2` headless for tests), SwiftUI (removal of now-redundant calls), the RayMol `--testing` build + a disposable macOS VM for functional verification.

## Global Constraints

- Python 3.9+ (repo floor). No Python formatter configured — match surrounding style.
- Every new cross-module dependency on `raymol_scenes` must be **import-guarded** (try/except → no-op) so upstream merges and non-RayMol builds stay green. This mirrors the existing guarded registration in `modules/pymol/cmd.py:59-66`.
- Capture uses `cmd.get_object_ttt` / restore uses `cmd.set_object_ttt` (isolates the TTT channel; do **not** use `get_object_matrix` for capture — it bakes in the state matrix and won't round-trip through `set_object_ttt`). `get_object_ttt` returns `None` for an unmoved object; substitute identity on restore.
- Identity TTT (16-float): `[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]`.
- Functional/UI verification MUST run in the mac VM (or iOS sim) via the `raymol-mac-vm` / `mac-vm-test` skill — never drive the host UI (per CLAUDE.md + user directive).
- Do not commit to `master`. Work stays on branch `claude/issue-204-0609e7`; open a PR at the end.
- Bare-pytest tests use the repo venv: `/Users/jcastellanos/repos/RayMol/.venv/bin/python`. The `PyMOLTestCase` runner (`pymol -ckqy testing/testing.py --run …`) only works on a RayMol `--testing=True` build (the venv/Homebrew pymol lack `pymol.testing`).

---

## File Structure

- `modules/pymol/raymol_scenes.py` (modify) — add `_scene_ttt` store, TTT capture/restore, `rename`, `on_scene_action` dispatcher, `suspended()` guard, `scene_ttt_map`, `emit_object_motion`, and extend session save/restore. Single responsibility: per-scene extras storage + apply.
- `modules/pymol/viewing.py` (modify) — call the hook at the end of `cmd.scene`; wrap `session_restore_scenes` temp-scene ops in `suspended()`.
- `modules/pymol/exporting.py` (modify) — wrap the legacy-scene temp block in `get_session` in `suspended()`.
- `modules/pymol/appkit_movie.py` (modify) — emit object-motion keyframes in `rebuild`, `append_template` (scenes), `place_scene`.
- `modules/pymol/movie.py` (modify) — emit object-motion keyframes in `add_scenes`.
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (modify) — remove the now-redundant `_rs.*` pairing calls.
- `testing/tests/test_raymol_scene_ttt.py` (create) — bare-pytest backend tests (runs locally now).
- `testing/tests/raymol/scene_ttt.py` (create) — `PyMOLTestCase` hook + `.pse` + movie tests (RayMol build/CI).

---

## Task 1: `raymol_scenes.py` — TTT capture/restore backend

**Files:**
- Modify: `modules/pymol/raymol_scenes.py`
- Test: `testing/tests/test_raymol_scene_ttt.py` (create)

**Interfaces:**
- Consumes: `cmd.get_object_ttt(obj)`, `cmd.set_object_ttt(obj, ttt)`, `cmd.get_names('objects')`, `cmd.get_scene_list()`, `cmd.mview(...)`, `cmd.get('scene_current_name')`.
- Produces (used by Tasks 2 & 3):
  - `snapshot_current(_self=cmd) -> str` — now also captures TTT for the current scene.
  - `apply(name, _self=cmd)` / `apply_current(_self=cmd)` — now also restores TTT.
  - `rename(old, new, _self=cmd)` — re-keys both dicts.
  - `on_scene_action(key, action, new_key=None, _self=cmd)` — central dispatcher (normalized actions).
  - `suspended()` — context manager pausing the hook.
  - `scene_ttt_map(name) -> dict` — `{obj: list[16] | None}` copy for scene `name` (`{}` if none).
  - `emit_object_motion(name, frame, _self=cmd) -> list[str]` — applies each captured TTT and stores an object-matrix mview keyframe at `frame`; returns objects keyframed.
  - `_IDENTITY_TTT`, `_scene_ttt` module globals.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/test_raymol_scene_ttt.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_ttt.py`
Expected: FAIL — `AttributeError: module 'raymol_scenes_under_test' has no attribute 'emit_object_motion'` (and `rename`, `on_scene_action`, `suspended`, `scene_ttt_map`, `_scene_ttt`).

- [ ] **Step 3: Add the TTT store, guard, and helpers to `raymol_scenes.py`**

After the existing `_scene_settings = {}` line (~line 33), add:

```python
# Identity TTT (16-float) used when an object has no transform yet / to reset one.
_IDENTITY_TTT = [1.0, 0.0, 0.0, 0.0,
                 0.0, 1.0, 0.0, 0.0,
                 0.0, 0.0, 1.0, 0.0,
                 0.0, 0.0, 0.0, 1.0]

# {scene_name: {obj_name: [16 floats] | None}} — per-object Move-mode TTT.
# None means the object had no TTT (unmoved) when the scene was stored; on recall
# that resets the object to identity. Every object present at store time is a key,
# so recall can reset as well as move. Persisted into the .pse alongside settings.
_scene_ttt = {}

# Reentrancy guard: internal temp-scene machinery (.pse legacy convert, multi-scene
# export) increments this so the cmd.scene hook does NOT capture/apply during its
# throwaway store/recall/clear (see viewing.session_restore_scenes / exporting).
_suspend = 0


class _Suspend:
    def __enter__(self):
        global _suspend
        _suspend += 1
        return self

    def __exit__(self, *exc):
        global _suspend
        _suspend = max(0, _suspend - 1)
        return False


def suspended():
    """Context manager: pause the cmd.scene capture/apply hook for internal
    temp-scene operations."""
    return _Suspend()


def _capture_ttt(_self=cmd):
    """Per-object TTT for every current object (None where unmoved)."""
    out = {}
    try:
        objs = _self.get_names('objects') or []
    except Exception:
        objs = []
    for o in objs:
        try:
            out[o] = _self.get_object_ttt(o)   # list[16] or None
        except Exception:
            out[o] = None
    return out


def _apply_ttt(name, _self=cmd):
    """Restore per-object TTT for scene `name`; reset unmoved objects to identity;
    skip objects that no longer exist."""
    d = _scene_ttt.get(name)
    if not d:
        return
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    for o, ttt in d.items():
        if o not in live:
            continue
        try:
            _self.set_object_ttt(o, list(ttt) if ttt else list(_IDENTITY_TTT))
        except Exception:
            pass


def scene_ttt_map(name):
    """Copy of the per-object TTT captured for scene `name` ({} if none)."""
    return dict(_scene_ttt.get(name, {}))


def emit_object_motion(name, frame, _self=cmd):
    """Author per-object Move-mode TTT keyframes for scene `name` at movie `frame`:
    apply each captured object TTT, then store an object-matrix mview keyframe
    (freeze=1 — the caller interpolates per object once at the end). Returns the
    list of objects keyframed. [] if no captured TTT / objects absent."""
    d = _scene_ttt.get(name)
    if not d:
        return []
    try:
        live = set(_self.get_names('objects') or [])
    except Exception:
        live = set()
    done = []
    for o, ttt in d.items():
        if o not in live:
            continue
        try:
            _self.set_object_ttt(o, list(ttt) if ttt else list(_IDENTITY_TTT))
            _self.mview('store', object=o, first=int(frame), freeze=1)
            done.append(o)
        except Exception:
            pass
    return done
```

- [ ] **Step 4: Extend `snapshot_current`, `apply`, `prune`, `clear_all` and add `rename` + `on_scene_action`**

Replace the existing `snapshot_current`, `apply`, `prune`, `clear_all` bodies and add the two new functions:

```python
def snapshot_current(_self=cmd):
    """Capture the current render settings AND per-object TTT for the current
    scene. Call right after `scene ..., store` / `update`."""
    name = _current(_self)
    if name:
        _scene_settings[name] = _capture(_self)
        _scene_ttt[name] = _capture_ttt(_self)
    return name


def apply(name, _self=cmd):
    """Re-apply scene `name`'s captured render settings and per-object TTT."""
    d = _scene_settings.get(name)
    if d:
        for s, v in d.items():
            try:
                _self.set(s, v)
            except Exception:
                pass
    _apply_ttt(name, _self)


def prune(_self=cmd):
    """Drop snapshots for scenes that no longer exist (call after a delete)."""
    try:
        live = set(_self.get_scene_list() or [])
    except Exception:
        return
    for name in list(_scene_settings.keys()):
        if name not in live:
            _scene_settings.pop(name, None)
    for name in list(_scene_ttt.keys()):
        if name not in live:
            _scene_ttt.pop(name, None)


def clear_all(_self=cmd):
    """Forget all snapshots (call after `scene *, clear`)."""
    _scene_settings.clear()
    _scene_ttt.clear()


def rename(old, new, _self=cmd):
    """Re-key snapshots when a scene is renamed (old -> new)."""
    if not old or not new or old == new:
        return
    if old in _scene_settings:
        _scene_settings[new] = _scene_settings.pop(old)
    if old in _scene_ttt:
        _scene_ttt[new] = _scene_ttt.pop(old)


def on_scene_action(key, action, new_key=None, _self=cmd):
    """Central hook called from cmd.scene AFTER the native op completes. `action`
    is already normalized by cmd.scene (update/append -> store, clear -> delete,
    auto-recall -> next). No-op while suspended()."""
    if _suspend:
        return
    if action in ('store', 'insert_after', 'insert_before'):
        snapshot_current(_self)
    elif action in ('recall', 'next', 'previous'):
        apply_current(_self)
    elif action == 'delete':
        if key == '*':
            clear_all(_self)
        else:
            prune(_self)
    elif action == 'rename':
        rename(key, new_key, _self)
```

(`apply_current` is unchanged — it already calls `apply(_current(...))`.)

- [ ] **Step 5: Extend `session_save` / `session_restore` for the TTT dict**

Replace the two session functions:

```python
def session_save(session, *, _self=cmd):
    session["raymol_scene_settings"] = dict(_scene_settings)
    session["raymol_scene_ttt"] = {k: dict(v) for k, v in _scene_ttt.items()}
    return 1


def session_restore(session, *, _self=cmd):
    _scene_settings.clear()
    _scene_ttt.clear()
    d = session.get("raymol_scene_settings")
    if isinstance(d, dict):
        _scene_settings.update(d)
    t = session.get("raymol_scene_ttt")
    if isinstance(t, dict):
        _scene_ttt.update({k: dict(v) for k, v in t.items()})
    return 1
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_ttt.py`
Expected: PASS (all cases in `TestEmitObjectMotion` and `TestSceneTTT`). If `TestSceneTTT` reports SKIPPED, `pymol2` is missing from the venv — install repo dev deps and rerun; do not mark the task done on skips.

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/raymol_scenes.py testing/tests/test_raymol_scene_ttt.py
git commit -m "feat(scenes): #204 per-scene object TTT capture/restore backend

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Central hook in `cmd.scene` + reentrancy guards

**Files:**
- Modify: `modules/pymol/viewing.py` (`scene` ~1194; `session_restore_scenes` ~1268)
- Modify: `modules/pymol/exporting.py` (`get_session` legacy-scene block ~401-416)
- Test: `testing/tests/raymol/scene_ttt.py` (create)

**Interfaces:**
- Consumes: `raymol_scenes.on_scene_action(key, action, new_key=…, _self=…)`, `raymol_scenes.suspended()` (from Task 1).
- Produces: `cmd.scene` now drives per-scene extras on every path.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/raymol/scene_ttt.py`:

```python
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

    def _assertMatDiffers(self, a, b, delta=1e-5):
        self.assertFalse(all(abs(x - y) <= delta for x, y in zip(a, b)))

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run (on a RayMol `--testing` build): `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
Expected: FAIL — `testHookCapturesAndRestores` fails because `cmd.scene('A','recall')` does not restore `m1`'s TTT yet (the hook isn't wired). If no `--testing` build is available in this session, this step is deferred to Task 5's build; note that and proceed to implement.

- [ ] **Step 3: Add the hook to `cmd.scene`**

In `modules/pymol/viewing.py`, in `scene(...)`, after `r = _self._call_with_opengl_context(func)` (~line 1194) and before `pymol._scene_quit_on_action = action`, insert:

```python
        # RayMol: capture/restore per-scene extras (render settings + object TTT)
        # on every scene action, from any path (UI, console, MCP, movie build).
        # `action` is already normalized above (update/append -> store,
        # clear -> delete, auto-recall -> next). Guarded so non-RayMol builds and
        # upstream merges stay unaffected.
        try:
            from pymol import raymol_scenes as _rs
        except Exception:
            _rs = None
        if _rs is not None:
            try:
                _rs.on_scene_action(key, action, new_key=new_key, _self=_self)
            except Exception:
                pass
```

- [ ] **Step 4: Guard the legacy-scene restore machinery**

In `modules/pymol/viewing.py`, wrap the body of `session_restore_scenes` (the `if 'scene_dict' in session:` block that does `_self.scene('*', 'clear')` / temp store / recall / clear, ~lines 1271-1294) in a `suspended()` context so those throwaway scene ops don't fire the hook (which would otherwise wipe the just-restored `_scene_ttt`). Change:

```python
        if 'scene_dict' in session:
            _self.scene('*', 'clear')
            ...
            _self.scene(tempname, 'recall', animate=0)
            _self.scene(tempname, 'clear')
```

to:

```python
        if 'scene_dict' in session:
            try:
                from pymol import raymol_scenes as _rs
                _ctx = _rs.suspended()
            except Exception:
                import contextlib
                _ctx = contextlib.nullcontext()
            with _ctx:
                _self.scene('*', 'clear')
                ...
                _self.scene(tempname, 'recall', animate=0)
                _self.scene(tempname, 'clear')
```

(Keep the existing statements between — only wrap them in the `with _ctx:` block. The trailing `if 'scene_order' in session:` and `return 1` stay OUTSIDE the `with`.)

- [ ] **Step 5: Guard the legacy-scene export block**

In `modules/pymol/exporting.py`, in `get_session`, wrap the `if legacyscenes:` block that does the temp `_self.scene(tempname, 'store')` / per-scene recall / `_self.scene(tempname, 'clear')` (~lines 401-416) in the same suspended context:

```python
        if legacyscenes:
            try:
                from pymol import raymol_scenes as _rs
                _ctx = _rs.suspended()
            except Exception:
                import contextlib
                _ctx = contextlib.nullcontext()
            with _ctx:
                _self.pymol._scene_dict = {}
                scene_current_name = _self.get('scene_current_name')
                tempname = '_scene_db96724c3cef00875c3bebb4f348f711'
                _self.scene(tempname, 'store')
                for name in legacyscenes:
                    _self.scene(name, 'recall', animate=0)
                    wizard = _self.get_wizard()
                    message = wizard.message if getattr(wizard, 'from_scene', 0) else None
                    pymol.viewing._legacy_scene(name, 'store', message, _self=_self)
                _self.scene(tempname, 'recall', animate=0)
                _self.scene(tempname, 'clear')
                _self.set('scene_current_name', scene_current_name)
```

- [ ] **Step 6: Run the test to verify it passes**

Run (RayMol `--testing` build): `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
Expected: PASS for `testHookCapturesAndRestores`, `testPSERoundTrip`, `testRenameKeepsTTT`. If deferred to the build in Task 5, mark this step pending-build and continue.

Also re-run Task 1's bare-pytest to confirm no regression:
Run: `/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_ttt.py`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/viewing.py modules/pymol/exporting.py testing/tests/raymol/scene_ttt.py
git commit -m "feat(scenes): #204 drive per-scene extras from cmd.scene hook + guard temp-scene ops

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Interpolated object motion in movies

**Files:**
- Modify: `modules/pymol/appkit_movie.py` (`rebuild`, `append_template` scenes branch, `place_scene`)
- Modify: `modules/pymol/movie.py` (`add_scenes`)
- Test: `testing/tests/raymol/scene_ttt.py` (extend — `PyMOLTestCase`, build/CI)

**Interfaces:**
- Consumes: `raymol_scenes.emit_object_motion(name, frame, _self=cmd)` (from Task 1); `cmd.mview('interpolate', object=obj)`.
- Produces: scene movies carry per-object matrix keyframes the core interpolates.

- [ ] **Step 1: Write the failing test (extend the PyMOLTestCase file)**

Append to `testing/tests/raymol/scene_ttt.py`:

```python
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
```

- [ ] **Step 2: Run to verify it fails**

Run (RayMol `--testing` build): `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
Expected: FAIL — `testRebuildInterpolatesObjectMotion`: `m_start == m_end` because `rebuild` does not yet author object-motion keyframes. (Deferred to Task 5 build if no `--testing` build here.)

- [ ] **Step 3: Author object motion in `appkit_movie.rebuild`**

In `modules/pymol/appkit_movie.py`, in `rebuild`, initialize a `motion` accumulator before the `cam_scene` loop and emit object keyframes for each scene item. Change the scene branch (currently ending with the `try/except` around `cmd.mview('store', first=f, state=int(cmd.get_state()))`) and the post-loop interpolate:

Find:
```python
        state_clips = [it for it in spec if it.get('states')]
        cam_scene = [it for it in spec if not it.get('states')]
```
Add right after:
```python
        motion = []   # objects that received per-scene TTT keyframes (#204)
```

Find (inside the scene branch):
```python
                cmd.mview('store', first=f, scene=name, power=power, linear=linear)
                # Preserve the scene's stored state for non-swept objects.
                try:
                    cmd.mview('store', first=f, state=int(cmd.get_state()))
                except Exception:
                    pass
```
Replace with:
```python
                cmd.mview('store', first=f, scene=name, power=power, linear=linear)
                # Preserve the scene's stored state for non-swept objects.
                try:
                    cmd.mview('store', first=f, state=int(cmd.get_state()))
                except Exception:
                    pass
                # #204: author per-object Move-mode TTT keyframes for this scene.
                try:
                    from pymol import raymol_scenes as _rs
                    motion += _rs.emit_object_motion(name, f)
                except Exception:
                    pass
```

Find:
```python
        if cam_scene:
            cmd.mview('interpolate')
```
Replace with:
```python
        if cam_scene:
            cmd.mview('interpolate')
        # #204: interpolate each object's matrix track once (keyframes stored with
        # freeze=1 above). dict.fromkeys de-dups while preserving order.
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception as e:
                print('MOVIE_ERR:' + str(e))
```

- [ ] **Step 4: Author object motion in `append_template` (scenes) and `place_scene`**

In `append_template`, find the scenes branch:
```python
                for i, nm in enumerate(names):
                    f = start + 1 + i * per
                    cmd.frame(f)
                    cmd.scene(nm, 'recall')
                    cmd.mview('store', first=f, scene=nm)
                cmd.mview('reinterpolate', power=0.0, linear=0.0)
```
Replace with:
```python
                motion = []
                for i, nm in enumerate(names):
                    f = start + 1 + i * per
                    cmd.frame(f)
                    cmd.scene(nm, 'recall')
                    cmd.mview('store', first=f, scene=nm)
                    try:
                        from pymol import raymol_scenes as _rs
                        motion += _rs.emit_object_motion(nm, f)
                    except Exception:
                        pass
                cmd.mview('reinterpolate', power=0.0, linear=0.0)
                for obj in dict.fromkeys(motion):
                    try:
                        cmd.mview('interpolate', object=obj)
                    except Exception:
                        pass
```

In `place_scene`, find:
```python
        cmd.scene(name, 'recall')    # now the live view+reps ARE the scene
        cmd.mview('store', first=n, scene=name)
        cmd.mview('reinterpolate', power=power, linear=lin)
```
Replace with:
```python
        cmd.scene(name, 'recall')    # now the live view+reps ARE the scene
        cmd.mview('store', first=n, scene=name)
        try:
            from pymol import raymol_scenes as _rs
            motion = _rs.emit_object_motion(name, n)
        except Exception:
            motion = []
        cmd.mview('reinterpolate', power=power, linear=lin)
        for obj in dict.fromkeys(motion):
            try:
                cmd.mview('interpolate', object=obj)
            except Exception:
                pass
```

- [ ] **Step 5: Author object motion in classic `movie.add_scenes`**

In `modules/pymol/movie.py`, in `add_scenes`, find the per-scene store loop:
```python
        for scene in names:
            frame = start+int((cnt*n_frame)/n_scene)
            cmd.mview("store",frame,scene=scene,freeze=1)
```
Insert after the `cmd.mview("store",frame,scene=scene,freeze=1)` line (same indentation, inside the loop):
```python
            try:
                from pymol import raymol_scenes as _rs
                for _obj in _rs.emit_object_motion(scene, frame, _self=cmd):
                    _scene_motion_objs.add(_obj)
            except Exception:
                pass
```
Initialize the accumulator just before the `for scene in names:` loop:
```python
        _scene_motion_objs = set()
```
And after the loop finishes (before the function returns; find where the loop's own rock/interpolate handling ends and the function wraps up), interpolate each object's matrix track once:
```python
        for _obj in _scene_motion_objs:
            try:
                cmd.mview("interpolate", object=_obj)
            except Exception:
                pass
```
Read the surrounding `add_scenes` body first to place this final loop after the existing per-scene camera interpolation completes and before `if loop:` / the function's tail; if the structure makes a clean insertion point unclear, place it immediately before the function's final `return` / end of the `if n_frame > 0:` block.

- [ ] **Step 6: Run the test to verify it passes**

Run (RayMol `--testing` build): `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
Expected: PASS including `testRebuildInterpolatesObjectMotion`. (Deferred to Task 5 build if none here.)

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/appkit_movie.py modules/pymol/movie.py testing/tests/raymol/scene_ttt.py
git commit -m "feat(scenes): #204 author interpolated object-motion keyframes in scene movies

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Remove redundant Swift `_rs.*` pairing calls

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift`

**Interfaces:**
- Consumes: the central `cmd.scene` hook from Task 2 (so these Swift calls are now redundant).
- Produces: no functional change (hook covers it); removes double-firing.

- [ ] **Step 1: Remove the seven redundant `runPython("...raymol_scenes...")` lines**

In `swiftui/PyMOLViewer/Panels/ObjectPanel.swift`, delete each of these lines (the `engine.runCommand("scene ...")` line ABOVE each stays):

- After `engine.runCommand("scene auto, update")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.snapshot_current()")`
- After `engine.runCommand("scene auto, previous")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.apply_current()")`
- After `engine.runCommand("scene auto, next")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.apply_current()")`
- After `engine.runCommand("scene auto, delete")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.prune()")`
- After `engine.runCommand("scene *, clear")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.clear_all()")`
- In `sceneChip`, after `engine.runCommand("scene \(name), recall, animate=1")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.apply('\(name)')")`
- In `addChip`, after `engine.runCommand("scene new, store")`: delete
  `engine.runPython("from pymol import raymol_scenes as _rs; _rs.snapshot_current()")`

- [ ] **Step 2: Verify no other `raymol_scenes` references remain in Swift source**

Run:
```bash
grep -rn "raymol_scenes" swiftui/PyMOLViewer --include="*.swift" | grep -iv "/build"
```
Expected: no output (all removed).

- [ ] **Step 3: Commit**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift
git commit -m "refactor(scenes): #204 drop redundant Swift raymol_scenes pairing (hook is central now)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Build + functional verification in the mac VM

**Files:** none (build + drive the app).

**Interfaces:** exercises Tasks 1-4 end-to-end through the real RayMol build.

- [ ] **Step 1: Build the macOS app (with C++ tests) and run the PyMOLTestCase suite**

Build per the repo's macOS two-stage flow (core then xcodebuild — see the `macos_swiftui_build_verify` memory / `build_macos_swiftui`). Then run the new `PyMOLTestCase` file on the resulting build:

Run: `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
Expected: all `TestSceneTTTHook`, `TestSceneMovieMotion` tests PASS. Fix any failures before proceeding (these are the deferred Task 2/3 verifications).

- [ ] **Step 2: Drive the app in a disposable macOS VM via the RayMol MCP**

Use the `raymol-mac-vm` skill (launch with `RAYMOL_MCP_AUTOTRUST=1`). Then, over MCP:

1. Load two objects (e.g. `fragment ala, m1` then `fragment gly, m2`, or load a small structure twice).
2. Enter Move mode; translate/rotate `m1`; `scene A, store`.
3. Move `m1` elsewhere; `scene B, store`.
4. `scene A, recall` then `scene B, recall` — confirm (via `get_object_matrix m1` over MCP and/or a `screencapture` of the live window) that `m1` jumps between the two positions.

Expected: `get_object_matrix('m1')` after recalling A differs from after B, matching the stored poses.

- [ ] **Step 3: Verify `.pse` round-trip**

Over MCP: `save /tmp/ttt_scenes.pse`, then `reinitialize`, `load /tmp/ttt_scenes.pse`, `scene A, recall`, `scene B, recall`.
Expected: object positions restored per scene after reload (same jump as Step 2).

- [ ] **Step 4: Verify movie object motion (interpolated) — the acceptance criterion**

Over MCP, build a scenes movie from A + B via the appkit_movie path used by the UI, e.g.:
```
from pymol import appkit_movie as _am
import json, base64
def _it(f,n): return {'frame':f,'scene':base64.b64encode(n.encode()).decode(),'power':0.0,'linear':0}
_am.rebuild(json.dumps([_it(1,'A'), _it(60,'B')]))
```
Then step the playhead: `frame 1`, `frame 30`, `frame 60`, capturing `get_object_matrix('m1')` at each (and/or `screencapture` frames). Also `mplay` briefly and screencapture to confirm the object glides.
Expected: `m1`'s matrix changes smoothly across frames (frame-30 strictly between frame-1 and frame-60), and the live window shows the object gliding — not jumping only at the keyframe. Also confirm a file export (MovieExportSheet path / `cmd.frame` loop) shows the motion by capturing two exported frames' object matrices.

- [ ] **Step 5: Regression sanity — render-settings extras still work on every path**

Over MCP, confirm the centralization didn't break the existing feature and now covers the previously un-hooked overlay path: set a distinctive `metal_*` look, `scene A, update`; change the look; recall A via the **viewport scene overlay chip** (not the ObjectPanel button) and confirm the look is restored (this path was un-hooked before Task 2).

- [ ] **Step 6: Open the pull request**

```bash
git push -u origin claude/issue-204-0609e7
gh pr create -R javierbq/RayMol --base master --head claude/issue-204-0609e7 \
  --title "Scenes: capture per-object TTT matrices (Move-mode position/orientation) (#204)" \
  --body "$(cat <<'EOF'
Closes #204.

Scenes now capture each object's Move-mode TTT and restore it on recall, persist it
in .pse, and interpolate it smoothly in movies built from scenes.

- Centralizes per-scene extras (object TTT + existing render settings) behind a
  single guarded hook in cmd.scene, so every path (UI overlay, timeline menus,
  console, MCP, movie build) captures/restores uniformly. This also fixes latent
  bugs the render-settings feature shared: rename orphaning and un-hooked overlay
  recalls.
- Movies author per-object mview matrix keyframes at build time; the core
  interpolates them during mplay and file export.

Tested: headless pytest (testing/tests/test_raymol_scene_ttt.py), PyMOLTestCase
(testing/tests/raymol/scene_ttt.py) on the RayMol --testing build, and functional
verification in a disposable macOS VM (manual recall, .pse round-trip, movie glide).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Criterion 1 (recall moves object between positions, incl. reset-to-unmoved) → Task 1 (`test_roundtrip_offcenter`, `test_recall_resets_unmoved`) + Task 2 (`testHookCapturesAndRestores`) + Task 5 Step 2.
- Criterion 2 (.pse survives) → Task 1 (`test_session_save_restore`) + Task 2 (`testPSERoundTrip`) + Task 5 Step 3.
- Criterion 3 (movie animates positions, interpolated) → Task 3 (`testRebuildInterpolatesObjectMotion`) + Task 5 Step 4.
- Criterion 4 (add/remove objects don't error; skipped) → Task 1 (`test_added_untouched_removed_skipped`).
- Spec §2 central hook → Task 2. §3 capture semantics → Task 1. §4 reentrancy guard → Task 2 Steps 4-5. §5 movie authoring → Task 3. §6 Swift cleanup → Task 4. §7 persistence → Task 1 Step 5. §8 testing → Tasks 1-3 + Task 5. §9 risks → verified in Task 3 test + Task 5 Steps 4 (export) and the mview/state-sweep coexistence is exercised by `rebuild` (which runs the state-sweep section after object motion).

**Placeholder scan:** No TBD/TODO. Task 3 Step 5's final-interpolate insertion point is described with a concrete fallback (before the function's final return / end of `if n_frame > 0:`) because `add_scenes`' tail must be read first — the code to insert is fully specified; only its anchor requires a look.

**Type consistency:** `emit_object_motion(name, frame, _self=cmd) -> list` used identically in Tasks 1 and 3. `on_scene_action(key, action, new_key=None, _self=cmd)` matches the Task 2 call `_rs.on_scene_action(key, action, new_key=new_key, _self=_self)`. `scene_ttt_map(name) -> dict` used in Task 1 tests. `suspended()` context manager used in Task 2 Steps 4-5. `_scene_ttt` / `_IDENTITY_TTT` referenced consistently.
