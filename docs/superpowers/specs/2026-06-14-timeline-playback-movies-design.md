# Timeline Playback & Movies — Design Spec

**Date:** 2026-06-14
**Branch:** `swiftui-cross-platform` (NEVER merge to master)
**App:** SwiftUI + Metal PyMOL viewer (macOS / iPad / iPhone), NO_OPENGL Metal core, embedded CPython 3.13

## Goal

Bring **NMR ensembles, MD trajectories, and movies** to the cross-platform app with a single unified "Timeline" abstraction: an always-relevant transport bar for play/scrub, inspector affordances for per-object state, a Scenes strip, a Make-Movie authoring sheet, and an in-app movie export — all feeling familiar to desktop PyMOL but native to Apple platforms.

## Core insight

In PyMOL, **states, NMR models, and trajectory frames are the same machinery**, and a "movie" is a sequencing layer on top:

- An `ObjectMolecule` holds one `CoordSet` per **state** (`CSet[]`, `NCSet`). Multi-MODEL PDB/mmCIF → one state per MODEL. `load_traj` appends each MD frame as a state — identical storage.
- A **frame** is a movie playlist index; `mset` maps frame→state (default `1 x N`, i.e. 1:1, which is why NMR/trajectories "just play").
- The global `state` setting selects what renders; `all_states` overlays all states. `count_frames`/`get_frame` (playlist) vs `count_states`/`get_state` (coordinates). UI is 1-indexed; internals 0-indexed.
- Camera animation = `mview` keyframes interpolated by `ViewElemInterpolate` (power/bias/hand splines). Scenes (`scene store/recall`, `add_scenes`) snapshot+sequence whole views. `movie.add_roll/add_rock/add_nutate/add_state_loop/add_state_sweep` are the high-level builders.

**Therefore:** one `currentFrame` driving `cmd.frame(N)` over `count_frames()` covers every case. No "NMR mode" vs "trajectory mode" vs "movie mode".

## Architecture decision: the CORE drives playback (no Swift timer)

`draw(in:)` already calls `engine.idle()` every Metal frame (`MetalViewport.swift:253` → `PyMOLEngine.idle()` `PyMOLEngine.swift:475` → `PyMOL_Idle` → `SceneIdle`). `SceneIdle` (`layer1/Scene.cpp:~2453-2497`) advances frames at `movie_fps` whenever `MoviePlaying(G)` is set, looping per `movie_loop`.

- **Play/pause** = `cmd.mplay()` / `cmd.mstop()`. The core advances frames through the draw loop we already tick. This auto-fires `mview`/`mdo`/scene keyframe commands (SceneIdle uses movie-command mode), honors `movie_fps`/`movie_loop` in-core, and is race-free.
- **A Swift `Timer` for frame advance is explicitly rejected** — it would double-advance against `SceneIdle` (≈2× / stutter) and `get_movie_playing` would fight Swift state.
- Swift's only frame writes are **scrubbing** (`cmd.frame(N)`) and **mirroring** core state into the UI via the existing poll.

### Source of truth & the poll
- New `appkit_movie.py` (sibling of `appkit_object_panel.py`) emits one `PLAYBACK:<json>` feedback line from the existing poll tick: `{frame: cmd.get_frame(), count: cmd.count_frames(), playing: cmd.get_movie_playing(), loop: get_setting_int('movie_loop'), fps: get_setting_float('movie_fps')}`.
- `count_frames` is the unified length — `SceneCountFrames` already returns `max(state count)` when no `mset` exists, so **no Python fallback is needed**.
- `PyMOLEngine` gains `@Published`: `currentFrame:Int`, `frameCount:Int`, `isPlaying:Bool`, `fps:Double`, `movieLoop:Bool`. `isPlaying` is sourced from `get_movie_playing` (true because we use `mplay`).
- **`isScrubbing` guard:** while the user drags, the poll must not overwrite `currentFrame` (classic two-way-binding bug). Poll refreshes `frameCount`/`isPlaying` always, but `currentFrame` only when `!isScrubbing`.
- **Serialize API access:** all `cmd.*` from the poll/scrub and `idle()`+render from the MTKView thread enter the PyMOL API (trylock). Route command dispatch and render through one queue/serialization so a trylock failure never silently drops a `frame` command.

## Components

### 1. `TransportBar.swift` (new) — all platforms
Fixed ~40pt strip: `[|< ] [ < ] [ ▶/⏸ ] [ > ] [ >| ]  |  Slider(1...frameCount)  |  "NNN / NNN" mono  |  [↻loop]  |  [⋯ overflow]`.
- Transport buttons → `rewind` / `backward` / `forward` / `ending`. Play/pause toggles `mplay`/`mstop`.
- Slider `onChange` sets `isScrubbing=true` + throttled `cmd.frame(N)` (≤1/draw, ~16ms); shows in-flight value live (mirrors desktop frame-under-cursor); release commits and clears `isScrubbing`.
- Loop → `set movie_loop, 0/1`. Overflow `⋯`: FPS picker (30/15/5/1/0.3 → `set movie_fps`; clamp, never derive interval from fps≤0), Show frame rate (`set show_frame_rate,1`), Make Movie…, Export Movie….
- **Auto-visible only when `frameCount > 1`** (mirrors `movie_panel`).
- **Placement:** macOS — fixed dock under the viewport in the VSplitView. iPad — pinned strip spanning the viewport, just above the safe area. iPhone — **collapsing peek**: 1-line peek over the viewport (`|< ▶/⏸ >|  N/M  ↻  ^`) that expands in place to a 3-row control (transport / scrubber / loop+fps+overflow). All touch targets ≥44pt (HIG); the peek uses 4 targets max with the expand chevron.

### 2. `PyMOLEngine` playback extension
Add the 5 `@Published` props; `play()`→`runCommand("mplay")`, `pause()`→`runCommand("mstop")`, `scrub(to:)`→clamp + throttled `runCommand("frame N")`. Add `parsePlaybackFeedback()` (modeled on `parseObjectDetailFeedback`) dispatched on `"PLAYBACK:"` in `pollFeedback()` (`~545`); call `appkit_movie.poll()` from `pollObjects()` (`~583`). No new C bridge.

### 3. `appkit_movie.py` (new)
`poll()` (emits `PLAYBACK:`), `make_movie(...)` (wraps `movie.add_roll/add_rock/add_nutate/add_scenes/add_state_loop/add_state_sweep`, `mset`, `mview store/interpolate`), `export(...)` (wraps the export path — see §7).

### 4. ObjectCard STATE affordance — `ObjectPanel.swift`
A `STATE` row appears in an expanded ObjectCard **only when `nstate > 1`**: stepper/mini-slider `state N / total` → `set state, N, <obj>` (pin one object independent of the global frame); plus existing actions promoted to buttons — `freeze` (`state_freeze`), `split` (`state_split`), `fit states` (`align_states` = `intra_fit`). Add `nstate` to the object enumeration JSON (`appkit_object_panel.py`) so the row can show before expansion.
- **Disambiguate the two "all states" concepts:** the existing `state_all` action = `set state, 0, obj` (render-all via state machinery) — label it **"Step all"**. A separate global overlay toggle = `set all_states, 0/1` — label it **"Overlay all"**. They render differently; never merge them.

### 5. SceneCard extension — `ObjectPanel.swift`
Global **Overlay all states** toggle (`set all_states, 0/1`). **Scenes strip**: horizontal chips from `get_scene_list`; tap → `scene NAME, recall, animate=1` (smooth transition via `scene_animation_duration`); `+`/`⟳`/`✕` → `scene new,store` / `scene auto,update` / `scene auto,clear`; `‹ ›` → `scene ,previous/next`; "Scene loop →" opens the Make-Movie sheet on its Scenes tab.

### 6. `MovieBuilderSheet.swift` (new) — neutral-labeled
Segmented: **Camera** (Roll/Rock/Nutate; duration 4/8/16/32 s; angle 30/60/90/120 → `add_roll/add_rock/add_nutate`), **Scenes** (multi-select chips + seconds/scene + loop → `add_scenes`), **States** (Loop/Sweep; speed 1×…1/8×; pause 0/1/2/4 s → `add_state_loop/add_state_sweep`). Plus "Capture keyframe @ frame N" (`mview store` + `mview interpolate`) and "Reset movie" (`mset; rewind`). Apply → `appkit_movie.make_movie(...)`; the TransportBar plays the result. No `mset`/`mview` jargon in user-facing text.

### 7. `MovieExportSheet.swift` (new) — in-app encode on all platforms
Fields: size (W×H + 720p/480p/360p presets, even-dimension clamp), frame range (1…frameCount), mode (**Draw = real-time Metal frames, default** / Ray = slow, behind a time warning, gated by existing `exportRayTraced` `@AppStorage`), format (MP4 / GIF / PNG-sequence).
- **Render:** per-frame Swift loop — `cmd.frame(N)` → capture via the **existing `renderHiResPNG` / Metal offscreen path** → collect frame. (Do **not** assume `cmd.mpng` works on the Metal backend — it uses `SceneMakeMovieImage`, not our capture interception. See Risks: `mpng` is a spike; the per-frame loop is the safe baseline.)
- **Encode in-app (no ffmpeg):** MP4 via `AVAssetWriter` (`AVAssetWriterInputPixelBufferAdaptor`), GIF via `ImageIO` (`CGImageDestination`, `kCGImagePropertyGIFDictionary`). PNG-sequence as zip fallback. Determinate progress bar driven by the render loop.
- **Deliver:** iOS → `presentShareSheet`; macOS → `NSSavePanel`. Manage memory: stream frames to the writer/encoder rather than holding all in RAM; respect `cache_frames`.

## Naming / branding
Neutral, jargon-free user-facing labels — **"Timeline", "Make Movie", "States", "Scenes"** (no `mset`/`mview`/`frame-vs-state` jargon in primary UI; state-vs-frame surfaced inline as "frame 7/20 · state 7" only when they differ). A **distinct accent color** for transport controls, consistent with the "plainly distinguished from PyMOL" license requirement.

## Phasing (smallest shippable first; user opted for all five)

1. **Play + scrub (states & trajectories).** `TransportBar` + 5 `@Published` props + `play/pause/scrub` (mplay/mstop/frame) + `appkit_movie.poll()` + `PLAYBACK:` parse + `isScrubbing` guard + API serialization. Auto-show when `frameCount>1`. Plays NMR/trajectories with full RT/SSAO per frame. *Zero core changes.*
2. **Inspector state controls.** Per-object STATE row (gated on `nstate>1`; `set state,N,obj`; freeze/split/fit), global Overlay-all, the two-"all-states" disambiguation, FPS picker + Show-frame-rate in overflow. Add `nstate` to object JSON.
3. **Scenes strip.** SceneCard chips: `get_scene_list`, recall `animate=1`, new/update/delete, prev/next; F-keys on macOS. Persists with sessions.
4. **Make Movie sheet.** Camera/Scenes/States tabs → `movie.add_*`; manual keyframe capture (`mview store`+`interpolate`); reset (`mset;rewind`). Plays via TransportBar.
5. **Export.** Per-frame Draw capture → in-app MP4 (`AVAssetWriter`) / GIF (`ImageIO`) / PNG-zip, progress bar, share (iOS) / save (Mac). Ray mode behind `exportRayTraced` + warning.

## Risks & mitigations

- **iOS memory (no streaming):** all frames are RAM-resident (`3·Natoms·Nstates` floats). A desktop-fine trajectory can OOM the app. *Mitigate:* on load, if `count_states` exceeds a threshold, offer interval-skip; rely on / don't fight `auto_defer_builds` (auto-enables `defer_builds_mode`/`async_builds` at ~100–500 states); hard frame-count ceiling check before load on iPhone.
- **`mpng` on Metal unverified:** it calls `SceneMakeMovieImage`, not our single-image capture. *Mitigate:* Phase-5 spike; default to the Swift per-frame `frame→renderHiResPNG→encode` loop (known-good capture path) rather than `mpng`.
- **Per-frame rep rebuild cost:** changing state rebuilds reps; large trajectories at 30fps can stall the draw thread. *Mitigate:* `defer_builds_mode`/`auto_defer_builds`.
- **Scrub vs poll fight:** `isScrubbing` ownership flag (above).
- **Trylock dropped frames / concurrent API entry:** serialize all PyMOL API access onto one queue (above).
- **`movie_fps ≤ 0`** means "use `movie_delay`" in-core; never derive a Swift interval from it (we don't, since the core drives advance — but guard the FPS picker to the preset set and clamp).
- **Auto-visibility latency:** `frameCount` is polled (~500ms), so the bar pops in/out ~half a second after load/`split_states`/delete. Acceptable; optionally refresh `frameCount` immediately after load commands.

## Scope explicitly NOT in v1 (parity gaps, called out per review)
- `movie.tdroll/screw/zoom/sweep/timed_roll` builders, Append-blank-frames (`add_blank`), `meter_reset`, per-frame `mdo` command authoring, `mmatrix`, motion easing knobs (`motion_power/bias/hand/linear`), scene cache management (`cache_frames` UI), ffmpeg encoder/quality dropdown + MPEG1/MOV/WebM containers. (MP4/GIF/PNG cover the common cases.) These can be added later behind the Make-Movie/Export overflow.

## Testing
- **Playback:** load `2kpo.cif` (multi-model) / a trajectory; PID-exact screenshots (`open -nF` + `/tmp/winforpid` + `screencapture`) at frames 1/N/last; verify scrub + play/pause + loop. An env-gated `PYMOL_AUTOPLAY` affordance (like the existing `PYMOL_AUTOTURN`) to verify frame advance headlessly.
- **State affordance:** two multi-state objects, pin different states per object; verify independent render and the two-"all-states" semantics.
- **Scenes/Make Movie:** store 2–3 scenes, build a scene loop + a camera roll; verify smooth interpolated playback drives the Metal camera each frame.
- **Export:** export a short MP4 + GIF on macOS and iOS sim; verify file opens and frame count/size match; memory stays bounded (stream to writer).
- Build: `bash swiftui/build_macos.sh` + `xcodebuild PyMOLViewer_macOS` (Mac), `swiftui/build_ios.sh` (sim/device).

## Resolved decisions
- Scope: all five phases incl. export. iPhone transport: collapsing peek overlay. iOS export: in-app MP4/GIF (AVAssetWriter/ImageIO). Naming: neutral labels + distinct accent.
- Frame-advance owner: **core (`mplay`+`SceneIdle`)**, not a Swift timer.
- Unified length source: `count_frames` (no Python fallback).
- Module attributions corrected: per-object state actions in `appkit_object_panel.py` / `ObjectPanel.swift`; `state_all` = `set state,0` ≠ `all_states`.

## Remaining open questions (non-blocking; default in parens)
- Per-object STATE row before expansion: add `nstate` to the per-object enumeration poll (slightly heavier every ~500ms) vs only when a card is expanded. (Default: add `nstate` to the enumeration — cheap.)
- iPhone large-trajectory ceiling value (default: warn above ~2000 states, offer interval-skip).
