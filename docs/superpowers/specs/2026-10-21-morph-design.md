# Morph: smooth playback of multi-state objects

**Date:** 2026-10-21
**Branch:** `worktree-morph-poc` (POC engine committed as `a1756983e`; this document specifies the full feature)
**Status:** builder-checked, awaiting approval

## 1. Intent

A user has an object with several states — an NMR ensemble, prediction seeds, a
design trajectory, several entries loaded as states — and wants it to **glide**
rather than flip when played, for visual inspection and for movies, with the
loop running while they change representations, materials and the camera.

Morph turns such an object into a smooth trajectory object beside it. Every
consecutive pair of models becomes one leg of `frames_per_model` frames, and by
default the last model morphs back into the first so the loop is seamless. The
result is an ordinary multi-state object: the Object panel's State row, per-object
Play, the Movie tab's Play-models clip and movie export all pick it up with no
new plumbing (verified with the POC, see §4).

Morphing **across two objects** (closed vs open from two PDB entries) stays a
command-line feature (`morph mout, obj1, obj2`), already working in the POC. No
UI is built for it.

## 2. Goals, non-goals, anti-goals

**Goals**

- One click from an ensemble's row to a looping, gliding version of it.
- The same from the Movie tab, while building a Play-models clip.
- Non-destructive: the source keeps its states and numbering.
- Works on macOS and iPad/iPhone with the same controls.
- Large inputs do not freeze the app; progress and cancel are visible.

**Non-goals (this release)**

- Morphing in place (replacing the source's states). Possible later as an
  explicit "replace models" option.
- Any UI for the two-object case; `cmd.morph` covers it.
- Internal-coordinate (dihedral) interpolation inside segments. The engine
  keeps the POC's rigid-segment screw interpolation plus sculpt clean-up; a
  NeRF tier is a later quality increment.
- Keeping a morph in sync when its source changes (a new prediction seed
  lands). The user re-morphs.
- Morphing a selection or part of an object.

**Anti-goals (would make the feature a failure even if it "works")**

- Touching the source's coordinates, states, titles or metrics.
- Blocking the UI for tens of seconds on an MD trajectory.
- A morph object that plays, scrubs, exports or saves differently from any
  other multi-state object.
- Model frames that do not land exactly on the original models.

## 3. Decisions made in the brainstorm (the user's)

1. Separate object named `<source>_morph`; source hidden, untouched.
2. Presented as a **plain sibling row** with a morph badge (loop glyph + frame
   count), not as a child row.
3. Object panel trigger: a **"Morph…" capsule beside Fit / Split / Sync** on the
   State row of any object with more than one state; opens a small sheet.
4. Movie tab trigger: a **"Smooth transitions (morph)" toggle inside the
   existing Play-models sheet**, with the morph settings behind a disclosure.
   No new composer preset.
5. Cross-object morph is command line only.
6. **Worker first**: the background worker with live progress and cancel
   lands before the Object panel and Movie tab UI ship; no synchronous
   "Calculating…" build is released.

## 4. Verified mechanics that constrain the design

All file references are to this worktree.

- **The engine exists and runs in the shipped app.** `modules/pymol/morphing.py`
  (POC): pairing, multi-state legs with exactly `N·steps` states, per-chain
  sieve core, run-length hinge rule, per-segment least-squares fit, screw
  interpolation with bit-exact endpoints, hinge blending, Cartesian lerp inside
  the segment frame, `refinement=N` sculpt cycles with the backbone fixed,
  rate presets, `color_segments`. Pure Python; no numpy, which matters because
  the shipped core returns `None` from `get_coords` (`appkit/CMakeLists.txt:239-245`).
  Measured: 1AKE→4AKE, 1656 atoms, 30 states: 0.07 s rigid headless, 0.31 s in
  the app, 0.43 s with refinement 3.
- **A created object's coordset order equals its `index` order**, so
  `load_coordset` in sorted-index order is correct; `load_coordset` silently
  moves zero atoms on a length mismatch, so the engine asserts row counts and
  round-trips the last frame (`morphing.py`, write-order check).
- **The core is main-thread only.** `engine.runHeavy(label){}` runs work on
  main under the blocking "Calculating…" overlay (`PyMOLEngine.swift:1361-1400`);
  long tasks use a worker thread that never touches `cmd` plus a main-thread
  `pump()` driven by `appkit_inspector.poll_panel()` every ~500 ms
  (`PyMOLEngine.swift:4938-4959`, `appkit_inspector.py:925-949`,
  `predicting.py:538-663`).
- **The ProgressTray is fed only by the OBJPANEL poll's `pending_jobs` /
  `design_jobs` maps**; a module gets a card by exposing
  `pending_objects()`, `recent_objects()`, `pending_info(name)`
  (`appkit_inspector.py:684-739`, `ProgressTray.swift:11-57`). Cancel is a
  `.python(...)` action. Placeholders are real zero-atom objects created with
  `cmd.create(name, 'none')` so the row appears immediately
  (`predicting.py:60-100`).
- **Object panel discovery is automatic.** `poll_panel` publishes `nstate`
  per object; the Swift `ObjectEntry.stateCount` drives the count badge and the
  State row (`ObjectPanel.swift:689-721, 3857-3993`). The POC's morph object
  appeared and played without any Swift change.
- **State row today**: `State` slider with ∓ steppers and `cur/total`, optional
  `Name` (per-state title), `Play` + fps menu (Swift `Timer` issuing
  `set state, k, obj`; `PyMOLEngine.swift:2154-2206`), `Overlay all` toggle,
  capsules `Fit` (`intra_fit`), `Split` (`split_states`), `Sync` (`unset state`)
  sent through `engine.runCommand(_:naming:)` (`ObjectPanel.swift:3972-3974`).
  Per-object Play is disabled while `engine.timelineMode` (authoring vs
  inspection, `ObjectPanel.swift:3870-3963`).
- **Play-models sheet today**: `statesConfigSheet` in `TimelinePanel.swift:903-980`:
  title "Play models" + "<target> · n models", segmented Sweep/Loop/Lockstep,
  steppers Start/End/Duration, Cancel + Add; writes
  `StatesSpec{objects, mode, firstModel, lastModel, durationSeconds}`
  (`PyMOLEngine.swift:497-526`). Append is enabled only when
  `engine.maxStateCount > 1`; the object chip lists `engine.multiStateObjects()`
  (`TimelinePanel.swift:796-811`). `appkit_movie.rebuild` sweeps a states clip
  with per-object `mview store object=… state=…` + `mview interpolate`
  (`appkit_movie.py:84-106, 667-706`); a wrapped morph swept 1→K ends on
  model 1, so the movie loops seamlessly in Sweep mode.
- **Look is not fully carried by `create`**: per-atom colors and reps are, but
  per-object settings (materials `<rep>_material` + knobs, transparencies,
  cartoon knobs) are not; there is no object-to-object look copier
  (`looks.py` applies named presets only; `appkit_inspector.py:21-33, 60-88`
  holds the per-rep setting tables).
- **Errors from Python reach the user only as console lines**; features surface
  errors inline or as tray cards (`PyMOLEngine.swift:4809-4907`).
- **Sheet style**: small config sheets are `VStack(spacing 16)`, padding 20,
  macOS `.frame(width: 340-400)`, iOS `.presentationDetents`, trailing
  Cancel (`.cancelAction`) + primary (`.defaultAction`, `.borderedProminent`).
- **Preferences**: per-user defaults live in `UserDefaults` under `raymol.*`,
  never in the `.pse`.
- Names must pass `isLegalObjectName` / `cmd.get_legal_name`; Python snippets
  from Swift use `InferenceJob.pythonLiteral` and must import what they use.

## 5. Design

### 5.1 Vocabulary

- **source**: the multi-state object being morphed.
- **morph object**: `<source>_morph` (legalised; `_morph2`, `_morph3`… if the
  name is taken by something that is not a morph of this source).
- **model**: one state of the source. **leg**: the frames between two
  consecutive models. **key frame**: the frame that is an exact copy of a model.
- **spec**: `{source, frames_per_model, loop, method, refinement, rate,
  copy_look}`.

### 5.2 Python engine (`modules/pymol/morphing.py`)

Keep `cmd.morph(...)` exactly as in the POC (public API, two-object capable).
Add a job layer for the UI:

```
morph_object(source, name=None, frames_per_model=15, loop=1,
             method='rigimol', refinement=3, rate='linear',
             copy_look=1, play=1, async_=1, quiet=1)
morph_cancel(name)
morph_spec(name) -> dict | None          # spec of a morph object this session
morph_estimate(source, frames_per_model, loop) -> {frames, atoms, bytes, seconds}
pending_objects() / recent_objects() / pending_info(name) / pump()
```

Behaviour of `morph_object`:

1. **Validate** on main: source exists; `count_states >= 2`; the source is not
   discrete and every state has the same atom count (otherwise raise
   `CmdException("morph: models have different atoms; morph needs the same
   atoms in every model")`, surfaced as a tray error card); estimate memory
   (§5.6); legalise the name. **No de-duplication**: morphing a source always
   rebuilds its morph object (delete the old one if present, keep the name),
   so a stale morph is refreshed by pressing Morph again. (Builder check:
   dedupe would have made "re-morph" a no-op.)
2. **Main thread, synchronous, cheap**: read every model's coordinates and the
   atom table once (`iterate_state`, plain lists) for the atoms
   `source and alt ''+A` — the POC's rule, so identifiers are unique; alt-B
   atoms are not carried. `cmd.create(name, "<source> and alt ''+A", 1, 1)`
   so the row exists immediately, copy the look (§5.5), register the job as
   pending (row shows the pending state, tray shows a card). The source stays
   visible until the morph is complete.
3. **Leg pipeline**: a `_MorphJob` object owns the snapshot and exposes
   `step()` (compute the next leg's frames with the POC's `_segment_chains` /
   `_frames_rigid`, or the linear path; pure Python; never touches `cmd`;
   returns False when no legs remain) and a queue of finished legs. In the
   worker increment a daemon thread calls `step()` in a loop and honours a
   `threading.Event` cancel; before that, `pump()` itself calls `step()`.
4. **`pump(budget_ms=100)` on main** (called from `poll_panel` every ~500 ms
   and from `morph_status`): land queued legs with `load_coordset`, run
   `sculpt_iterate` for landed **intermediate** states only (key frames are
   never sculpted, so they stay bit-exact copies of the models; backbone
   `flag fix`, `refinement` cycles), set per-state titles (§5.4), update
   progress `{phase, fraction, leg, legs}`, stop when the budget is spent.
   When the last leg lands: verify state count `= legs × frames_per_model`,
   verify the last frame round-trips, deactivate sculpting, hide the source,
   publish `select: name` in the terminal record so the panel expands the
   row, set the morph's per-object fps to the movie fps and start per-object
   playback when `play=1` (unless `engine.timelineMode`), retain the terminal
   record for the tray's Dismiss.
5. Cancel: set the event, drain the queue, **delete the partial object**,
   re-enable the source, terminal record `cancelled`.
6. Failure: terminal record with `error`; partial object deleted; tray card
   shows the message with Dismiss.

`async_=0` runs `while job.step(): pump()` inline to completion (scripts, CLI).
Tests drive the same pipeline one leg at a time: `job = morphing.start_job(…)`,
`job.step()`, `morphing.pump()`, assert partial state count, `morph_cancel`,
assert the partial object is gone and the source re-enabled. No thread timing
in tests.

Legs: `loop=1` → N legs (`1→2 … N→1`); `loop=0` → N−1 legs. State count is
`legs × frames_per_model`; key frames at `1 + k·frames_per_model`. Endpoints of
each leg are bit-exact copies of the models (the POC's frame schedule).
`cmd.morph` gets the same two fixes (alt-A filter it already has; sculpt skips
key frames) so the CLI ensemble shortcut honours the anti-goal too.

**Fingerprint.** The job records `{state_count, atom_count, crc32 of model 1's
coordinates}` of the source alongside the spec. `morph_spec(name)` returns
both, and the Movie path (§5.7) reuses an existing morph only when spec and
fingerprint both match; otherwise it rebuilds.

**Size policy.** `morph_estimate` also returns `seconds`, from the measured
costs (≈ 0.05 ms per atom per leg for frames, ≈ 0.25 ms per atom-state for
sculpting); the sheet shows it as a hint only. The user decided (§3.6) that
the worker thread ships before any UI, so nothing is refused on time; only
the memory limit (§5.6) refuses. Sculpting still runs on the main thread
inside `pump()`'s budget, so very large morphs complete slowly but never
block.

### 5.3 Object panel (`swiftui/PyMOLViewer/Panels/ObjectPanel.swift`)

- **Capsule "Morph…"** appended to `stateActionButtons` after Sync, same style
  as Fit/Split/Sync, visible when `entry.stateCount > 1 && !entry.isPending`.
  Help text: "Build a smooth, looping version of this object's models".
  Accessibility identifier `stateRow.morph.<name>`.
- **Morph sheet** (macOS `.sheet`, width 380; iOS detent ≈ 360 pt):
  - Title row: "Morph <source>" · right-aligned "<n> models" (secondary).
  - **Frames per model** — Stepper, 2…120, default 15 (my call: half a second
    per transition at 30 fps; 20 models → 300 frames → 10 s loop).
  - **Loop back to model 1** — Toggle, default on.
  - **Method** — segmented "Rigid segments" (default) / "Linear".
  - **Clean-up cycles** — Stepper 0…10, default 3; caption "sculpting, backbone
    fixed".
  - **Rate** — Menu: Linear (default), Sinusoidal, Ramp up, Ramp down.
  - **Summary line** (secondary, updates live): "20 models → 300 frames ·
    10 s at 30 fps · ≈ 24 MB · creates 2kpo_morph, hides 2kpo". The fps is
    the **movie fps** (`movie_fps`, default 30), which is also what auto-play
    uses (the morph's per-object fps is set to it), so what you inspect runs
    at the speed the movie will. Turns orange with a warning above the memory
    threshold (§5.6); the primary button is disabled above the hard limit.
    If the source shows a surface or mesh, a second caption says "Surface and
    mesh are not carried to the morph (too costly per frame)".
  - Buttons: Cancel (`.cancelAction`) · **Morph** (`.defaultAction`,
    `.borderedProminent`). Morph closes the sheet and calls
    `morph_object(...)` through `runPython` with `pythonLiteral` escaping.
  - Values persist in `UserDefaults` `raymol.morph.{framesPerModel, loop,
    method, refinement, rate}`.
- **On a morph object** (name resolved by `morph_spec(name)` or, after a `.pse`
  reload, by the `<x>_morph` convention with `x` present), the same capsule
  reads "Morph…" and the sheet is pre-filled with its spec (user defaults
  after a reload); Morph regenerates under the same name (delete + rebuild
  through the job path), so timeline clips and scenes that name it keep
  working; clips created through the Smooth path remap to the new stride
  (§5.7). A secondary "Delete morph" button appears in the sheet (destructive
  style) which deletes the morph and re-enables the source.
- **Row badge**: for morph objects the state-count capsule shows a `repeat`
  glyph before the count (`⟳ 300`); tooltip "Morph of 2kpo · 300 frames".
  The panel learns a morph from a new optional payload key `morph`
  (`{name: source}`) in `poll_panel` (all new PanelPayload fields Optional).
- **While pending**: the row is created immediately (zero-atom placeholder is
  not needed since `create` of state 1 is instant); the pending map greys the
  checkbox as for predictions; the tray card reads "Morphing 2kpo · leg 7/20 ·
  35%" with Cancel → `morph_cancel`.
- **After completion**: row selected/expanded, per-object Play running
  (unless `engine.timelineMode`, where Play is disabled by design; then the
  object simply sits at frame 1).
- **Per-state Name** shows the title (§5.4), so scrubbing reads "model 7" on
  key frames.

### 5.4 Per-state titles

`set_title(name, k, 'model i')` on key frames and `'i → j'` on intermediates
(`'20 → 1'` on the wrap leg). Cheap, serialises into `.pse`, and gives the
State row and the timeline something readable.

### 5.5 Look copy

`create` carries per-atom reps and colors. In addition copy, from source to
morph, **only the settings the source overrides at object level**
(`cmd.get_object_settings`, the same source of truth the inspector uses for
Custom/Inherit), so the morph keeps inheriting globals and theme changes
exactly like its source and no rep row reads as "Custom" that was not. Never
copy `state`, `all_states`, or anything movie related. Expose as
`morphing.copy_look(src, dst)` so it is testable and reusable.

**Surfaces and meshes are not carried.** PyMOL stores representations per
coordinate set (`layer2/CoordSet.h:107`), so a 300-frame morph with a surface
shown would hold 300 surface meshes (hundreds of MB) and stutter through its
first loop while building them; `defer_builds_mode` would instead rebuild the
surface every frame. The morph hides `surface` and `mesh` (per-atom rep flags
cleared on the morph) and the sheet says so (§5.3). Cartoon, sticks, lines,
spheres, ribbon, dots and labels are carried.

### 5.6 Memory guard

`bytes ≈ atoms × frames × (12 + rep_cost)` where `rep_cost` is a rough
per-atom-per-frame cost of the reps the morph will show (builder to measure;
cartoon and sticks are the common case, surfaces are excluded by §5.5).
Thresholds (my call): warn above 200 MB on macOS / 100 MB on iOS; refuse
above 1 GB / 400 MB with the message "Reduce frames per model or morph fewer
models". The sheet shows the estimate live; `morph_object` enforces the hard
limit too (CLI users get a `CmdException`). The test in §6 pins the
coordinate term (`atoms × frames × 12`) and checks that rep costs are added,
not the exact rep numbers.

### 5.7 Movie tab (`TimelinePanel.swift` Play-models sheet)

- Add a **Toggle "Smooth transitions (morph)"** under the Start/End/Duration
  row, default off, persisted (`raymol.morph.movieSmooth`). Disabled with a
  hint when the target is "all models" (`spec.objects == nil`) or the target is
  already a morph object.
- A `DisclosureGroup "Morph settings…"` beneath it holds the same four
  controls as §5.3 (frames per model, method, clean-up, rate); loop is implied
  on for the Movie path (my call: a movie clip of a non-looping morph is
  obtained by setting End to the last key frame).
- When the toggle turns on, **Duration** is set to the natural length
  (`frames / fps`, 1 decimal) unless the user has edited it since; the
  summary under the toggle reads "Builds 2kpo_morph (20 models × 15 frames)
  and plays that instead · 10 s at 30 fps".
- **Add** with the toggle on: if `<obj>_morph` exists with the same spec
  **and** source fingerprint (§5.2), use it; else call
  `morph_object(..., play=0, async_=1)` and append the clip with
  `objects: [morphName]` immediately. The clip is drawn as today with the
  `repeat` glyph and label "<obj>_morph" plus the range suffix rules. The
  states clip sweeps whatever states exist at render time, so a clip added
  while the morph is still computing simply fills in as legs land; the
  rebuild on completion is triggered by the job's terminal record
  (`engine.rebuildMovie()` when a morph named by any clip completes).
- Start/End steppers count **models** while the toggle is on. `StatesSpec`
  gains `morphStride: Int?` and keeps `firstModel`/`lastModel` as model
  indices when it is set; `rebuildMovie` converts at rebuild time with the
  morph's current stride (`first = 1 + (start−1)·f`), so a regenerated morph
  with a different `frames_per_model` remaps old clips instead of silently
  sweeping a different range. The **full range** (Start 1, End N) is sent as
  `last = 0`, i.e. all `N·f` states including the wrap leg, so a Sweep ends
  on model 1 and the movie loops seamlessly; a partial range `3…8` ends on
  model 8's key frame.
- Lockstep remains available and unchanged.
- After the morph object exists, the ordinary path (Models chip → pick
  `2kpo_morph` → Play models) also works, since `multiStateObjects()` lists
  it.

### 5.8 Command line, API, MCP, docs

- `morph` keeps the PyMOL signature. Ensemble shortcut: `morph 2kpo_morph,
  2kpo, state1=0` (wrap) / `state2=0` (no wrap); `steps` is frames per
  model. New keywords `morph_object`, `morph_cancel` registered in
  `keywords.py` / `api.py` like `apply_look`.
- MCP: when the native tool set (branch `feat/mcp-raymol-native`) lands, add
  `morph_object` to `raymol_help` and the guide; until then `run_pymol_command`
  covers it.
- Docs: `docs/src/content/docs/reference/commands.md` entry under a new
  "Movies & Playback" section; a guide page `guides/morph.md`; a What's New
  page with a short looping video when the release is cut.

### 5.9 Errors and edge cases

- Source with 1 state: capsule not shown; CLI raises.
- Source is a pending prediction/design placeholder: capsule hidden
  (`isPending`).
- Source changes while a morph is computing (states added/deleted): the job
  read all coordinates up front, so it completes against the snapshot; no
  invalidation.
- Name collision: `<source>_morph` taken by a non-morph object → `_morph2`.
- Session restore: a morph object is an ordinary object in the `.pse`; its
  spec is not persisted (session registry only); the `_morph` convention
  restores the re-morph affordance when the source is present.
- Discrete objects (`load … discrete=1`, multi-compound SDF libraries) and
  ensembles whose states have different atoms are **refused** with the §5.2
  message; the capsule still shows for them (a per-tick `morphable` check in
  `poll_panel` is not worth its cost), the error arrives as a tray card.
- Alt locs: only `alt ''+A` atoms are carried (§5.2).
- Timeline open: creation still works; auto-play is skipped (inspection
  playback is disabled while authoring).

## 6. Verification (must pass)

**Python, real engine** (`testing/tests/raymol/morph.py`, added to
`.github/workflows/raymol-embedded-tests.yml`):

- `morph_object` on a 5-model `fab` ensemble: state count `5·f` with loop,
  `4·f` without; key frames bit-exact copies of models **at the default
  refinement**; titles as §5.4; a source with an alt-B atom yields a morph
  with alt-A atoms only.
- Look copy: a cartoon material, a custom knob and a stick transparency set
  at object level on the source appear on the morph; a global-only value
  does not become an object-level override; `state`/`all_states` are not
  copied; surface/mesh flags are cleared.
- Memory estimate: coordinate term equals `atoms × frames × 12` within 10 %
  and the total is larger when cartoon/sticks are shown; hard limit raises.
- Validation: discrete source and per-state atom-count mismatch raise the
  §5.2 message; nothing is created.
- Leg pipeline with `start_job`: after one `step()` + `pump()` the state
  count is `1 + f` (first leg landed, the key frame exact), `pending_info`
  reports leg 1 of N; `morph_cancel` deletes the partial object and
  re-enables the source; a completed job's record is terminal and retained.
- `pump()` is idempotent, bounded by its budget, and never raises.
- Re-morph of a source rebuilds under the same name (no dedupe); fingerprint
  changes when a state is added to the source.
- The POC harness checks (screw math, hinge rule, endpoints, geometry stats,
  rates, pairing, multi-state legs, errors) move into the suite.

**Swift** (`PyMOLViewerTests`, run locally with `xcodebuild test`; there is no
CI job for XCTest or VM runs in this repo, and this feature does not add one
— the PR records the local run): summary-line maths (frames, seconds, bytes
at movie fps), model ↔ absolute state mapping including the full-range
`last = 0` rule and remapping on stride change, natural-duration update rule,
UserDefaults round trip.

**Functional, macOS VM** (`mac-vm-test`): load `2kpo.cif` (20 models) →
Objects → expand → Morph… → Morph: row `2kpo_morph ⟳ 300` appears, 2kpo hidden,
object plays; Movie tab → Models chip → 2kpo → Append → toggle Smooth → Add:
a clip "2kpo_morph · 10 s" on the lane; export 30 frames and confirm the
first and last exported frames differ. iOS simulator: the same sheet via
`PYMOL_AUTO*` hooks and screenshots.

## 7. Scope / files

- `modules/pymol/morphing.py` — job layer, look copy, estimate, titles.
- `modules/pymol/appkit_inspector.py` — `morph` payload key; call
  `morphing.pump()` beside the other pumps; pending maps for morph jobs.
- `modules/pymol/keywords.py`, `api.py` — register `morph_object`, `morph_cancel`.
- `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` — capsule, sheet, badge,
  pending/selection handling.
- `swiftui/PyMOLViewer/Panels/TimelinePanel.swift` — toggle, disclosure,
  key-frame mapping, natural duration.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `MorphSettings`
  (`@AppStorage`), `morph(source:settings:)` entry, rebuild-on-complete hook,
  PanelPayload `morph` field.
- `swiftui/PyMOLViewer/Shared/ProgressTray.swift` — `.morph(...)` factory if
  the generic job record is not reusable as is.
- Tests and CI yml as in §6; docs as in §5.8.

## 8. Left to the builder

- Exact per-object setting list for look copy (start from the inspector's
  tables; add what the Display tab exposes).
- Worker/pump chunk sizes; whether sculpting is chunked per state or per leg.
- Whether the morph badge glyph is `repeat` or a dedicated symbol.
- iOS sheet detent heights; iPhone placement of the capsule row if it wraps.
- Whether `MorphSettings` lives in `PyMOLEngine` or a small
  `MorphController` like `PredictController`.

## 9. Increments

1. **Engine job layer + tests**: `start_job`/`step`/`pump`, `morph_object`,
   estimate, titles, look copy, validation, cancel; `async_=0` path; CLI
   fixes to `cmd.morph`.
2. **Worker thread**: daemon thread driving `step()`, chunked `pump`, live
   tray progress and cancel. Lands before 3 and 4 (user decision §3.6).
3. **Object panel**: capsule, sheet, badge, selection + auto-play, errors via
   tray card, `morph` payload key.
4. **Movie tab**: toggle, disclosure, natural duration, model ↔ state mapping
   with `morphStride`, rebuild-on-complete.
5. Docs, What's New, MCP guide entry.

## 10. Open questions

None. Release gating was the one question the builder check raised for the
user; answered as §3.6 (worker first).

Calls made by the author in response to the builder check (not the user's):
no de-duplication of morphs (always rebuild); fingerprint-gated reuse in the
Movie path; sculpt never touches key frames; alt-A atoms only; discrete or
non-uniform sources refused rather than half-handled; look copy limited to
explicit object-level settings; surface and mesh not carried; movie fps as the
canonical fps for summary and auto-play; full-range Movie clips include the
wrap leg (`last = 0`); `morphStride` on `StatesSpec` so clips survive a
re-morph; Swift and VM gates run locally, not in CI.
