# Per-scene render-setting animation in scene movies — design

**Follows:** [#204](https://github.com/javierbq/RayMol/issues/204) / PR #229 (per-scene object TTT + render settings + DOF autofocus target)
**Date:** 2026-07-25
**Branch:** `claude/issue-204-0609e7`

## Problem

Scenes now capture render settings (including depth-of-field) and restore them on
manual recall. But **in a movie built from scenes, none of it applies** — the movie
keeps whatever settings were last set interactively. Reported by the user as "the
DOF setting is just stuck on the last active setting" when making a video.

**Root cause.** Movie playback recalls scenes entirely in C++:
`MovieDoFrameCommand` (`layer1/Movie.cpp:1046`) → `MovieSceneRecall`
(`Movie.cpp:1058-1066`) → `SceneFromViewElem` (`Movie.cpp:1067`). No Python hook
fires, so `raymol_scenes.apply()` never runs. `ViewElem` (`layer1/View.h`) has
channels for the camera matrix and per-object state/matrix, but **no channel for
arbitrary global settings**, so settings cannot ride the existing keyframe
mechanism.

## Goals

1. A scene movie applies each scene's captured render settings as it plays — in
   live playback **and** in exported video.
2. Continuous settings **interpolate smoothly** across transitions, in step with
   the camera's easing; discrete settings step at the cut.
3. Differing Auto-lock focus targets produce a true **focus pull**, not a snap.
4. The animation survives `.pse` save/reload, without tripping PyMOL's movie
   security lock.

## Decisions (user-approved)

- **Scope:** all captured render settings, not DOF alone (same code path; the
  complaint would otherwise recur for lighting/exposure).
- **Focus:** true focus pull for differing Auto-lock targets.
- **Persistence:** survive `.pse` reload, by re-authoring from structured data.

## Key findings that shape the design

Verified by reading the core and by live probes against the compiled macOS build
over MCP.

- **`mdo`/`mappend` is the only viable vehicle.** `cmd.mdo(frame, str)` stores one
  command string per frame (`Movie.cpp:1075` `MovieSetCommand`; storage is
  `std::vector<std::string> Cmd`, `Movie.h:58`). It executes via `PParse` →
  `PFlush`.
- **It fires on both playback and export.** Live: `SceneIdle` → `SceneSetFrame`
  (modes 5/7) → `MovieDoFrameCommand` (`Scene.cpp:2216-2219`). Export:
  `MovieExportSheet.swift:148` calls `cmd.frame(N)`, whose default `trigger=-1`
  → `SceneSetFrame` mode 4 → `movieCommand = true` (`Cmd.cpp:4458`). **Measured
  live:** command fires at each `cmd.frame(N)`; ~0.03 ms/frame; 300 commands
  authored in <1 ms. *Fragility:* `cmd.frame(n, 0)` or `cmd.set_frame` would skip
  it — the export call must keep the default trigger.
- **Ordering is favourable.** The frame command is *queued* first, then the scene
  recall and `SceneFromViewElem` run, then `PFlush` executes it — so our `set`
  lands **last** and overrides the C++ scene recall.
- **`mset` wipes all frame commands** (`Movie.cpp:918` `I->Cmd.clear()`), so
  emission must come after the `mset` in the authoring path.
- **Use `mappend`, not `mdo`.** Defensive: `mdo` *sets* the slot, so it would
  silently overwrite a third-party frame command sharing a frame with ours.
  PyMOL's `movie` module does write such commands — the LEGACY top-level helpers
  `rock`/`roll`/`tdroll`/`zoom`/`nutate`/`screw` (`movie.py:90,114,158,182,210,244`)
  — though *not* on the `add_scenes` path (see below).
- **⚠ The `.pse` security lock.** Frame commands are serialized into the session
  (`MovieCmdAsPyList`, `Movie.cpp:483`). On load, if any command is non-empty and
  `G->Security` is on (default), `MovieSetLock(G, true)` fires
  (`Movie.cpp:459-462`) — and `MovieDoFrameCommand` is gated on `if(!I->Locked)`
  (`Movie.cpp:1051`), so the lock disables **the entire per-frame path: commands,
  scene recall, and the camera track**. `importing.py:178-180` would launch
  `wizard("security")`, which RayMol's SwiftUI app has no UI for → a silently dead
  movie. **Verified live:** after `.pse` reload the command is present in the
  session but does not execute.
- **Sentinel traps** (`RendererMetal.mm:2528,2532`): `metal_dof_aperture <= 0` is
  treated as **14 (maximum blur)**, and `metal_dof_range <= 0.01` as **14** — so a
  naive fade-to-zero slams to max blur. `metal_dof_focus == 0` means "auto"
  (`SceneRender.cpp:2061`).
- **Autofocus discards manual focus.** With `metal_dof_autofocus` on,
  `SceneRender.cpp:2051` overwrites `dofFocus` with 0 and recomputes it from the
  `dof_focus` selection's bbox centre every frame. So focus cannot be cross-faded
  by lerping `metal_dof_focus` while autofocus is on.
- **The camera eases nonlinearly.** `ViewElemInterpolate` (`View.cpp:1149-1177`)
  applies a symmetric `power` curve, default **1.4**. Linear setting interpolation
  desyncs ~24 % at t=0.25 — worst exactly where the camera hangs near a keyframe.
- **`metal_dof_hq` (SettingInfo.h:938) is dead code** — superseded by
  `metal_dof_quality`. Do not animate it.

## Architecture

### New module: `modules/pymol/raymol_scene_anim.py`

`raymol_scenes.py` already owns capture, restore, session persistence, and the
`cmd.scene` dispatcher for three kinds of extras; movie authoring is a distinct
responsibility. The new module has one job: **read per-scene captures and author
per-frame movie commands.**

Two accessors are added to `raymol_scenes`, mirroring the existing
`scene_ttt_map`:

```python
def scene_settings_map(name):   # -> {setting: value}   ({} if none)
def scene_focus_map(name):      # -> [(model, index), ...]   ([] if none)
```

### Setting classification

```python
# Continuous -> interpolate across the transition.
INTERPOLATE = {
    "metal_dof_focus", "metal_dof_range", "metal_dof_aperture",
    "metal_exposure", "metal_sss_wrap", "metal_outline_width",
    "metal_rt_ao_radius", "metal_rt_ao_intensity", "metal_rt_shadow_intensity",
    "ambient", "direct", "reflect", "specular", "shininess", "fog",
}
# Everything else in raymol_scenes.CAPTURE steps at the scene cut: booleans and
# ints (metal_dof, metal_dof_autofocus, metal_shadows, metal_ssao, metal_raytrace,
# metal_tonemap, metal_outline, metal_temporal_ao, depth_cue,
# ray_opaque_background), plus these which are continuous-ish but MUST step
# because changing them mid-transition forces a rebuild/hitch:
#   surface_quality, metal_dof_quality, metal_msaa, metal_upscale,
#   metal_rt_samples
```

Only settings whose value actually **differs** between the two scenes are emitted
("smooth transitions when needed").

### Easing — mirror the core

Ported verbatim from `View.cpp:1165-1177` (with `bias` fixed at 1.0, `parabolic`
true, matching how RayMol authors keyframes):

```python
def ease(t, power=1.4):
    """Normalized transition position -> eased position. Mirrors
    ViewElemInterpolate so settings track the camera instead of desyncing."""
    if power == 1.0:
        return t
    if t < 0.5:
        return (t * 2.0) ** power * 0.5
    if t > 0.5:
        return 1.0 - (((1.0 - t) * 2.0) ** power * 0.5)
    return 0.5
```

`power` is 1.4 for Smooth and 1.0 for Linear — matching how Swift encodes the
transition (`PyMOLEngine.swift:1702-1704`).

`t` for interior frame `f` of transition `[F0, F1]` is `(f - F0) / (F1 - F0)`,
which is exactly the core's `fxn` (`View.cpp:1150`).

### Sentinel-safe interpolation

```python
_FLOOR = {"metal_dof_aperture": 0.02, "metal_dof_range": 0.02}
```

Interpolated values are clamped to their floor so a fade never reaches the
"≤0 ⇒ 14" sentinel. `metal_dof_focus` is never interpolated *through* 0: if either
endpoint is 0 (auto) the pair is treated as non-interpolatable and steps instead.

### Focus pull

For a transition into scene B from scene A where the effective focus target
differs (either scene has autofocus on and their `dof_focus` captures differ):

1. At author time, resolve each scene's target **centroid in model coordinates**
   from its `scene_focus_map` atoms (mean of coordinates; falls back to the
   scene's `metal_dof_focus` distance, or the origin, when the capture is empty).
2. For each interior frame `f`: `cmd.frame(f)` yields the interpolated camera, and
   `cmd.get_view()` gives that frame's view. Compute the eye-space depth of
   `lerp3(centroid_A, centroid_B, ease(t))` under that view — reusing the existing
   math from `metal_pick.py:384-417` `_eye_distance`:
   `eye_z = R_row2 · (p − origin) + tz`, distance `= −eye_z`.
   Sampling per frame (rather than lerping two endpoint distances) keeps the pull
   correct while the camera itself dollies.
3. Emit for that frame: `set metal_dof_autofocus, 0` + `set metal_dof_focus, <d>`.
4. At B's keyframe, emit a compact helper call that re-points the `dof_focus`
   selection to B's atoms and restores B's autofocus flag, so the lock is live
   again during the dwell.

Restoring the live pose after authoring: the authoring loop moves the playhead, so
it must restore the frame it started on (the existing paths already end with
`cmd.rewind()` / `cmd.frame(start)`).

### Emission

Per frame, the animated values are joined into one `mappend` string:

```
set metal_dof_focus, 12.345; set metal_dof_aperture, 3.20
```

At each scene keyframe, a compact helper call is emitted rather than a long
literal `select`:

```
from pymol import raymol_scene_anim as _a; _a.enter_scene('<b64 name>')
```

`enter_scene(name_b64)` applies **all** of that scene's captured settings exactly
(not just the stepped ones — at the keyframe the scene's own values are by
definition the correct endpoint, so this needs no special-casing), then re-selects
`dof_focus` to that scene's atoms and restores its autofocus flag. Interior
transition frames carry only the interpolated subset.

The scene name is **base64-encoded** in the emitted string. That is a security
requirement, not cosmetics: the string is executed by the PyMOL parser, so an
unescaped name containing a quote or semicolon would be a command-injection
vector. The base64 alphabet cannot terminate the literal. (Multi-statement command
strings and semicolon-joined `set`s are **verified working** in an `mdo` string.)

### Hook points

Same four authoring paths as the #204 object motion, emitting **after**
`mview interpolate` and after the `mset`:

| Path | Frame layout |
|---|---|
| `appkit_movie.rebuild` | scene items are zero-width keyframes; transition into item *i* = `[F(i-1), F(i)]` sorted **by frame index** (an `atFrame` item can interleave) |
| `appkit_movie.append_template` (scenes) | `F(i) = start + 1 + i*per`; transition = `per` frames |
| `appkit_movie.place_scene` | single marker; re-emit rebuild-style rather than patching locally |
| `movie.add_scenes` | has a **dwell**: hold `[S_c, D_c]` (~`pause*fps`), transition `[D_c, S_(c+1)]` (~`animate*fps`) — animate across the transition only, hold values through the dwell |

### Persistence & security

- `session_save`: blank the movie command slots this module authored (tracked by
  frame), so the saved `.pse` carries no frame commands from us and does not trip
  `MovieSetLock`. Persist the animation as **structured data**:
  `session["raymol_movie_anim"] = {frame: {setting: number}}` plus the per-frame
  focus values.
- `session_restore`: **validate** — accept only setting names present in
  `raymol_scenes.CAPTURE` and values that are real numbers — then regenerate the
  `set` command strings and re-apply them with `mappend`.
- **Security-critical:** we persist structured values and regenerate the commands
  ourselves. We never persist or replay raw command strings, so a hostile `.pse`
  cannot smuggle executable code through our session key. This is why the
  save/restore is not simply "stash and replay `Cmd[]`".
- **`add_scenes` with rock/nutate carries no third-party frame commands, so our
  strip is sufficient.** An earlier draft of this spec claimed otherwise and
  listed it as a known limitation; that was wrong. The `mdo` call sites in
  `movie.py` (90, 114, 158, 182, 210, 244) belong to the LEGACY top-level
  `rock`/`roll`/`tdroll`/`zoom`/`nutate`/`screw` helpers (defined at
  `movie.py:64, 93, 118, 167, 185, 214`), which `add_scenes` never calls. The
  camera animation it *does* use — `_rock` (`movie.py:490`), `_nutate`
  (`movie.py:543`) and `_nutate_sub` (`movie.py:517`) — authors `mview store`
  keyframes (`power=-1` / `freeze=1`) and writes **no** frame commands at all.
  Blanking our own text therefore leaves such a movie with an entirely empty
  `Cmd[]`, and it reloads unlocked. `mappend` over `mdo` stays the right
  defensive choice for the general case (a user's own `mdo`), but no limitation
  remains on the shipping scene-movie paths.

## Testing

**Headless pytest** (`.venv/bin/python -m pytest`, extends the existing
`testing/tests/test_raymol_scene_ttt.py` pattern or a sibling file) — pure logic,
no Metal:
- `ease()` reproduces the C++ curve at sampled t (including the 1.4/1.0 cases and
  the t=0.5 midpoint).
- Sentinel clamping: an aperture fade toward 0 never emits ≤ 0.02; a focus pair
  with a 0 endpoint steps instead of interpolating.
- Classification: every name in `raymol_scenes.CAPTURE` is either interpolated or
  stepped, and the must-step overrides are stepped.
- Only differing settings are emitted.
- Table generation for a two-scene transition: correct frames, monotone values.
- Restore validation rejects unknown setting names and non-numeric values.
- A scene name containing a quote/semicolon round-trips through `enter_scene`
  without breaking or injecting into the emitted command string.

**Live VM (macOS build over MCP)** — the real contract:
- Author a two-scene movie with different DOF; step frames and assert
  `metal_dof_aperture`/`_focus` change smoothly and monotonically across the
  transition and hold through a dwell.
- Focus pull: differing Auto-lock targets produce a monotone focus distance across
  the transition, with autofocus re-enabled and `dof_focus` re-pointed at the
  destination.
- Stepped settings change exactly at the cut.
- `.pse` save/reload: the movie still plays (camera track alive — i.e. the lock did
  *not* fire) and the animation is restored.
- Scrub correctness: jumping backward to an interior frame yields that frame's
  values (per-frame commands make this deterministic; with keyframe-only commands
  it would not be).

**Note:** DOF is a Metal post-process — `cmd.ray` / `capture_viewport` do **not**
render it, so visual confirmation requires a live-window capture. Value-based
assertions are the contract-level test.

## Out of scope

- A settings channel in `ViewElem` (the "proper" C++ fix; core change + upstream
  divergence).
- Animating settings outside `raymol_scenes.CAPTURE`.
- The pre-existing rock/nutate `.pse` security-lock interaction.
- Per-transition user control over which settings animate (automatic for now:
  interpolate when values differ).

## Key files

- `modules/pymol/raymol_scene_anim.py` — new: classification, easing, table build, emission, session tasks
- `modules/pymol/raymol_scenes.py` — add `scene_settings_map` / `scene_focus_map`
- `modules/pymol/appkit_movie.py` — hook `rebuild`, `append_template`, `place_scene`
- `modules/pymol/movie.py` — hook `add_scenes` (dwell-aware)
- `modules/pymol/cmd.py` — register the new session save/restore tasks
- `modules/pymol/metal_pick.py` — reference for `_eye_distance`
- `layer1/View.cpp`, `layer1/Movie.cpp`, `layer1/SceneRender.cpp`,
  `layerGraphics/metal/RendererMetal.mm` — reference (not modified)
