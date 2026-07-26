# Scenes: capture per-object TTT matrices — design

**Issue:** [#204](https://github.com/javierbq/RayMol/issues/204) — Scenes: capture per-object TTT matrices (Move-mode position/orientation)
**Date:** 2026-07-24
**Branch:** `claude/issue-204-0609e7`

## Problem

Move mode (1.7.0) rigid-body translates/rotates individual objects by applying a
per-object **TTT matrix** in the core (`cmd.translate`/`cmd.rotate ... object=`,
see `modules/pymol/metal_move.py`). This transform is non-destructive and survives
a saved `.pse`, but classic PyMOL `scene store`/`recall` captures only the camera
view + representations + colors — **not** per-object TTT. So recalling a scene
leaves each object wherever it currently sits, making it impossible to build a set
of scenes (or a movie) that show objects in different arrangements.

`modules/pymol/raymol_scenes.py` already extends scenes to snapshot render "look"
settings (the same class of gap), but it does not touch object matrices.

## Goals (acceptance criteria)

1. Move an object, `scene A, store`; move it elsewhere, `scene B, store`. Recalling
   A vs B moves the object between the two positions (including resetting an object
   back to *unmoved* if it was unmoved when that scene was stored).
2. Per-scene positions survive a `.pse` save/reload.
3. A movie built from scenes animates object positions — **interpolated** (smooth
   glide between scene keyframes).
4. Objects added/removed between store and recall don't error; missing objects are
   skipped.

## Key findings that shaped this design

Two facts (from a codebase investigation) override the issue's "just mirror
`raymol_scenes.py`" framing:

- **Movie playback recalls scenes entirely in C++**
  (`MovieDoFrameCommand → MovieSceneRecall`, `layer1/Movie.cpp:1046`) and never
  fires any Python hook. The existing render-settings snapshot therefore does *not*
  apply during a movie today. **But** the movie core natively interpolates
  per-object TTT if object-motion keyframes are authored via
  `cmd.mview('store', object=NAME, first=f)` (`modules/pymol/moving.py`;
  `set_object_ttt` docstring confirms keyframes drive the TTT during playback).
  → Movies need keyframes injected at *build* time, not a per-recall callback.

- **The current hook-pairing pattern is fragile.** `cmd.scene()`
  (`modules/pymol/viewing.py:1103`) does not call `raymol_scenes`; only the
  ObjectPanel Scenes-tab buttons pair the hook manually. The viewport scene
  overlay, Timeline menus, the four `PyMOLEngine` scene helpers, **rename** (no
  hook exists — orphans snapshots), the console, and the MCP/agent path all bypass
  it. These are latent bugs in the shipped render-settings feature too.

## Decisions

- **Centralize both** the new TTT capture and the existing render-settings capture
  behind a single hook inside `cmd.scene`, so every path (UI, console, MCP,
  movie-assembly) is covered uniformly and rename re-keys correctly.
- **Interpolate** object motion in movies (smooth glide), matching how the camera
  already interpolates.

## Architecture

### `raymol_scenes.py` becomes the unified "scene extras" backend

It already owns `_scene_settings = {scene: {setting: value}}` plus
snapshot/apply/prune/clear_all/session_save/session_restore. Add:

- `_scene_ttt = {scene: {obj: [16 floats]}}` — parallel store for per-object TTT.
- A single dispatcher `on_scene_action(key, action, new_key=None, _self=cmd)` that
  routes a scene action to the right capture/restore for **both** dicts.
- A `suspended()` context manager (a simple counter) so internal temp-scene
  machinery can disable the hook.
- Rename support (re-key both dicts `old → new_key`).

`snapshot_current` and `apply`/`apply_current` are extended to also handle TTT;
`prune` and `clear_all` already cover both dicts once `_scene_ttt` is added.

### Central hook in `cmd.scene`

`cmd.scene()` calls `raymol_scenes.on_scene_action(key, action, new_key=...)` at
the **end**, after the native op completes (so `scene_current_name` reflects the
result). The call is import-guarded (no-op if `raymol_scenes` is absent) to stay
upstream-merge-safe.

| `action`                                  | hook behavior                              |
|-------------------------------------------|--------------------------------------------|
| `store` / `update` / `insert` / `append`  | `snapshot_current` (settings + all TTT)    |
| `recall` / `next` / `previous` / `first` / `last` | `apply_current`                    |
| `delete`                                  | `prune`                                    |
| `clear` (`key == '*'`)                    | `clear_all`                                |
| `rename`                                  | re-key `key → new_key` in both dicts       |

No recursion risk: the hook only calls `get/set`, `get_object_ttt`/
`set_object_ttt`, `get_names`, `get_scene_list` — none re-enter `cmd.scene`.

### TTT capture / restore semantics

- **Capture** (`snapshot_current`): for every object in `cmd.get_names('objects')`,
  store `cmd.get_object_ttt(obj)`, substituting the identity TTT
  (`[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]`) when it returns `None` (unmoved).
  Recording *all* present objects — not only moved ones — is what lets recall reset
  an object back to unmoved.
- **Restore** (`apply`): `cmd.set_object_ttt(obj, ttt)` for each recorded object
  still present; skip objects that no longer exist. Objects created *after* the
  scene was stored are not in the map and are left untouched.
- **Why `get/set_object_ttt`, not `get_object_matrix`:** it isolates the TTT (Move
  mode's channel) and avoids double-counting an object's state matrix (structural
  alignment). `get_object_matrix(incl_ttt=1)` bakes both together and would not
  round-trip through `set_object_ttt`. A test performs an *off-center* rotation
  (the exact case that diverges the gizmo per `metal_move.py:429-438`) then
  store → move → recall and asserts `get_object_matrix` is byte-identical.

### Reentrancy guard

Internal callers that perform temp scene store/recall/clear must not trigger
capture/apply:

- `.pse` restore — `viewing.py:1268` `session_restore_scenes`.
- Multi-scene PNG/mpng export — `exporting.py` (~112-120, ~406-415).

Wrap those temp ops in `with raymol_scenes.suspended():`; the hook early-returns
while the suspend counter is nonzero. Movie-build recalls in `appkit_movie` are
deliberately **not** suspended — the applied TTT is exactly what the keyframe
capture below must observe.

### Movie authoring — interpolated object motion

In `appkit_movie.rebuild()` per-scene loop (`modules/pymol/appkit_movie.py:358-447`;
also the single-marker `place_scene` at ~131-146 and `append_template` at ~257-267),
the existing sequence is:

```
cmd.frame(f)
cmd.scene(name, 'recall')            # now also applies the scene's TTT via the hook
cmd.mview('store', first=f, scene=name, power=power, linear=linear)  # camera keyframe
cmd.mview('store', first=f, state=<state>)                           # state pin
cmd.mview('interpolate')
```

Add, right after the recall: for each object that has a captured TTT for `name`
(from `raymol_scenes._scene_ttt[name]`),

```
cmd.mview('store', object=obj, first=f)   # object-matrix keyframe
```

The core interpolates object motion between scene frames during both `mplay` and
file export. This coexists with the per-object *state-sweep* channel
(`_emit_state_sweep`) because a `ViewElem` carries `matrix_flag` and `state_flag`
independently.

### Swift cleanup

With the hook central, the scattered `_rs.snapshot_current()/apply()/apply_current()/
prune()/clear_all()` calls in `ObjectPanel.swift` (~2856-2935) are redundant
(double-firing, harmless but confusing) and are removed. The previously un-hooked
paths — the ContentView viewport overlay recall, the Timeline menus, the four
`PyMOLEngine` helpers (`recallScene`/`updateScene`/`deleteScene`/`renameScene`), and
rename — now work automatically with no per-site Swift edits.

### Persistence

`session_save` writes `session["raymol_scene_ttt"] = dict(_scene_ttt)` alongside the
existing `raymol_scene_settings`. `session_restore` reads it back and tolerates its
absence (old `.pse` files load unchanged). Both flow through the already-registered
`_session_save_tasks`/`_session_restore_tasks` (`cmd.py:59-66`).

## Testing

### Fast headless pytest (runs in this environment, no C++ build)

New file `testing/tests/test_raymol_scene_ttt.py` (matches the existing standalone
`test_appkit_*.py` pattern that `pytest.ini`/`conftest.py` collect), run with:

`/Users/jcastellanos/repos/RayMol/.venv/bin/python -m pytest -q testing/tests/test_raymol_scene_ttt.py`

Stock venv pymol lacks `raymol_scenes` and the session-task registration, so import
the module file directly via `importlib.util.spec_from_file_location` and drive a
real `pymol2.PyMOL()`, passing `_self=p.cmd`. Cases:

- Off-center rotate `m1`, `store S1`; rotate more, `store S2`; recall S1 → assert
  `get_object_matrix('m1', incl_ttt=1)` equals the S1 pose; recall S2 → S2 pose.
- Scene stored while `m1` unmoved, then move, then recall → `m1` resets to identity.
- Object added after store is left untouched on recall; object removed is skipped
  (no error).
- `rename` re-keys the snapshot; `prune`/`clear_all`; `session_save`/`restore` dict
  round-trip (both `_scene_settings` and `_scene_ttt`).
- **Gotcha:** TTT is only populated by TTT-mode transforms (`rotate`/`translate`
  with `object=`, `camera=0`, `object_mode=0`) or `set_object_ttt`. `get_object_ttt`
  returns `None` for identity/unset. Reset `_scene_ttt`/`_scene_settings` in
  setUp/teardown (module-level globals).

### `PyMOLTestCase` (faithful, runs in the RayMol `--testing` build / CI)

New file `testing/tests/raymol/scene_ttt.py`, mirroring
`testing/tests/raymol/design_saverestore.py`. Exercises the real `cmd.scene` hook
end-to-end and a real `.pse` `save`/`load` round-trip through the registered session
tasks. (Runs via `pymol -ckqy testing/testing.py --run tests/raymol/scene_ttt.py`
on a `--testing=True` build; CI is `raymol-embedded-tests.yml`.)

Two files by design: `test_raymol_scene_ttt.py` (bare-pytest, `pymol2` +
`importlib`) runs locally now; `raymol/scene_ttt.py` (`PyMOLTestCase`) runs in the
RayMol build/CI. One file can't do both — the venv pymol has no `pymol.testing`.

### Functional verification (mac VM / simulator)

Build the macOS app; drive it via the RayMol MCP (`raymol-mac-vm` skill):

1. Load two objects; enter Move mode; move object A; `scene A, store`.
2. Move it elsewhere; `scene B, store`.
3. Recall A vs B → the object jumps between the two positions.
4. Save `.pse`, reload → positions preserved.
5. Build a movie from A + B, play → object glides smoothly between positions;
   confirm an exported movie file shows the motion too (not only live `mplay`).

## Risks to resolve during implementation

- Exact `cmd.mview('store', object=obj)` semantics vs. the state-sweep channel —
  confirm matrix and state keyframes coexist and that `interpolate` handles the
  object-matrix channel.
- Confirm object motion renders in **file export** (`cmd.frame` path), not just
  live `mplay`.
- Read the exact `cmd.scene` signature so `rename` passes `new_key` correctly to the
  hook, and confirm the `key == '*'` clear form.
- Confirm the temp-scene names/paths used by `session_restore_scenes` and the export
  helpers so the `suspended()` wrap covers exactly those ops.

## Out of scope

- Multi-state objects' per-state matrices.
- A vanilla-parity gating flag (the fork already captures render extras
  unconditionally; TTT matches that).
- iOS-specific UI — the hook is backend, so iOS inherits the behavior for free.

## Key files

- `modules/pymol/raymol_scenes.py` — extras backend (edit)
- `modules/pymol/viewing.py` — `cmd.scene` central hook (edit)
- `modules/pymol/appkit_movie.py` — object-motion keyframe authoring (edit)
- `modules/pymol/exporting.py`, `modules/pymol/viewing.py` — `suspended()` wraps (edit)
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — remove redundant `_rs.*` calls (edit)
- `testing/tests/test_raymol_scene_ttt.py` — new bare-pytest tests (local)
- `testing/tests/raymol/scene_ttt.py` — new `PyMOLTestCase` tests (RayMol build/CI)
- `modules/pymol/cmd.py` — existing session-task registration (reference)
- `modules/pymol/metal_move.py`, `modules/pymol/moving.py`, `modules/pymol/editing.py` — reference
