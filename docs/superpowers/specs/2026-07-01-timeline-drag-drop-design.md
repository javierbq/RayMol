# Timeline drag-and-drop — design

Date: 2026-07-01
Branch: `claude/raymol-timeline-movies-ltr0d6` (extends PR #85 Timeline mode)

## Goal

Let the user drag camera keyframes and scenes across the Timeline to compose a
movie by direct manipulation: re-time camera poses, and place/re-time scenes at
specific moments.

## Scene vs. camera (the two things being dragged)

- **Camera keyframe** — stores *only* the camera (orientation, zoom, clip,
  origin) at a frame. Interpolated between keyframes (Smooth/Linear). PyMOL:
  `mview store`. Rendered today as diamonds on the Camera lane.
- **Scene** — a complete named snapshot (camera **plus** reps, colors,
  visibility, settings). Not time-positioned today; the Scenes lane is a recall
  palette. PyMOL: a named `scene`.

## Decisions

1. **Scope:** both draggable — camera diamonds re-time; scenes get placed on a
   time-positioned lane and re-timed.
2. **Scene on the timeline = instant marker** (a point at frame N). The look
   *cuts* to the scene when playback reaches it (reps can't interpolate).
3. **Camera coupling:** a scene marker *also* acts as a camera keyframe — the
   view flies smoothly between scenes; only reps/colors cut. (PyMOL's native
   scene-movie behavior.)
4. **Placement UX (adaptive):** a saved-scenes palette is the source. macOS —
   drag a palette chip into the lane at a time. Touch — scrub, tap a palette
   chip to drop at the playhead. Placed markers then drag to re-time.

## Core mechanism — unified `mview` keyframes

Both lanes are the same underlying object, a PyMOL `mview` keyframe, tagged only
by whether a scene is attached (verified: `mview(action='store', …, scene='',
cut=…)` in `modules/pymol/moving.py`):

- **Camera diamond** = `mview store` at frame N, no scene.
- **Scene marker** = recall the scene (so the live camera == the scene's
  camera), then `mview store, scene=NAME` at frame N. The scene's camera becomes
  the interpolation keyframe; the scene is recalled (reps cut) at the `cut`
  moment during playback.

**Re-time (drag)** for both: read the keyframe's stored view at the old frame →
`mview clear` there → re-`store` at the new frame (re-attaching `scene=` for
markers) → `mview reinterpolate` with the current easing.

## Data model

Session-scoped Swift mirrors (same pattern/limitation as today's
`cameraKeyframes` — not rebuilt from a reloaded `.pse`):

- `cameraKeyframes: [Int]` — frames of plain camera keyframes (exists).
- `sceneMarkers: [SceneMarker]` — new; `SceneMarker = { frame: Int, name: String }`.
- **Invariant: at most one keyframe per frame** — `cameraKeyframes` and
  `sceneMarkers` frames are disjoint.

## API surface

**Python (`modules/pymol/appkit_movie.py`):**
- `place_scene(frame, name, linear)` — `scene(name,'recall')` → `mview store,
  first=frame, scene=name` → reinterpolate.
- `move_keyframe(old, new, linear)` — read view at `old`, `mview clear` old,
  set the view, `mview store` at `new`, reinterpolate.
- `move_scene_marker(old, name, new, linear)` — `mview clear` old →
  `place_scene(new, name, linear)`.
- Reuse `clear_keyframe(frame, linear)` for delete (both kinds).

**Swift (`PyMOLEngine`):**
- `placeScene(_ name, at frame, linear)` — runs `place_scene`; upserts
  `sceneMarkers`; keeps frames disjoint from `cameraKeyframes`.
- `moveKeyframe(from old, to new)` — plain diamond re-time; updates
  `cameraKeyframes`.
- `moveSceneMarker(_ name, from old, to new)` — updates `sceneMarkers`.
- `deleteSceneMarker(at frame)` — `clear_keyframe`; removes from `sceneMarkers`.
- `clearMovie` / `newTimeline` / `buildMovie` also clear `sceneMarkers`.

**UI (`TimelinePanel.swift`):**
- Camera lane: diamonds gain a horizontal `DragGesture` (re-time on release);
  tap (below threshold) still seeks; long-press context menu still deletes.
- Scenes lane: time-positioned marker chips (label = scene name) at their frame;
  draggable to re-time; tap to seek; long-press to delete. A saved-scenes
  palette strip sits under the lane as the drag source (drag on macOS,
  tap-to-drop at playhead on touch).

## Edge cases

- **Collision:** dropping/dragging onto an occupied frame snaps to the nearest
  free frame.
- **Clamp** target frame to `[1, frameCount]`; drag requires `frameCount > 1`.
- **Tap vs. drag** disambiguated by a small drag-distance threshold.
- Empty-state hints remain when a lane is empty.
- After any move/place/delete, `reinterpolate` with the current Smooth/Linear.

## Non-goals (v1)

- Segments / dwell-time blocks (scenes are instant markers).
- Per-marker "include camera" toggle (scenes always contribute their camera).
- `.pse` reconstruction of the tracks (stays session-scoped).
- Multi-select / bulk moves.

## Testing

Build both schemes; then **mac-vm-test** in a fresh isolated VM: place scenes,
drag diamonds and scene markers to re-time, verify via the accessibility tree +
screenshots that markers land at the intended frames, and export an MP4 to
confirm the composed camera path + scene cuts.
