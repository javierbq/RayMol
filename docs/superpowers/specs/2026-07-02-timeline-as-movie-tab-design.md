# Timeline as the unified Movie surface

Date: 2026-07-02
Branch: `claude/raymol-timeline-movies-ltr0d6` (PR #85)

## Goal

Make the Timeline the single movie-authoring surface: (A) built templates
decompose onto the editable tracks, and the Timeline becomes the Movie tab's
main view with the preset controls condensed into it (no separate builder sheet).

## Decisions (from brainstorm)

1. **Movie tab IS the timeline** (iOS): selecting the Movie tab shows the
   immersive timeline (viewer + full-width dock, tab bar hidden). The old
   `MoviePane`/preset-builder screen and the separate clapperboard "Timeline
   mode" toggle go away. macOS/iPad-pointer (no tab bar) keep the dock toggle.
2. **Templates append** at the end (never replace); the movie length grows.
3. **Decompose (A):** an appended Camera preset adds camera diamonds; a Scenes
   preset adds scene markers; a State loop/sweep preset just extends length
   (optional labeled band) — no dedicated markers (States track deferred).
4. **Condensed composer:** the preset builder folds INTO the timeline dock (in
   the freed space); the standalone `MovieBuilderSheet` "Templates" path is
   retired. Produce/Export stays in the header.

## Architecture

### Engine — append + emit markers (source of truth)

`appkit_movie.make_movie(kind, …, start=0, reset=1)` gains append semantics and
returns what it created:
- Append: pass `start = current frame count` and `reset=0` so `movie.add_*`
  (which already accept `start=`) extend the movie instead of clearing.
- Emit: after building, compute/collect the frames it keyframed and any scene
  names, and print a structured line (e.g. `TLBUILD:{"camera":[f,…],
  "scenes":[[f,name],…]}`) that `PyMOLEngine` parses — the builder is the source
  of truth, so no fragile `get_session` parsing.
  - Camera (roll/rock/nutate): `movie.add_roll` etc. store mview keyframes at
    known offsets from `start`; return those absolute frames.
  - Scenes: `movie.add_scenes` → return `[(frame, name)]`.
  - State loop/sweep: return no markers (length grows only).

`PyMOLEngine.buildMovie(...)` becomes `appendTemplate(...)`:
- Runs `make_movie(start: frameCount, reset: 0)`, parses `TLBUILD`, and appends
  the returned frames to `cameraKeyframes` / `sceneMarkers` (instead of clearing
  them). Reinterpolates with the current easing. Updates `playback.frameCount`.
- `clearMovie` still wipes everything (Reset affordance).

### Navigation — Movie tab = timeline (iOS)

- Selecting the Movie tab (tag 2) enters the timeline: drive `engine.timelineMode`
  from `selectedTab == 2` (set on appear/selection; cleared on leaving). The
  existing `iosTimelineLayout` renders it (viewer + docked panel, tab bar hidden).
- Remove the separate `iosTimelineToolbar` clapperboard + Panels-popover row (or
  repoint them to select the Movie tab). `MoviePane` no longer shows the builder.
- `Done` sets `selectedTab` back to a sensible tab (e.g. Objects) and exits.
- macOS: unchanged — the clapperboard dock toggle stays.

### UI — condensed composer in the dock

Add an **"Add to timeline"** composer to `TimelinePanel` (below the transport,
using the freed space): a compact type picker (Camera Roll/Rock/Nutate · Scene
loop · State loop), the few relevant params (duration / axis / angle / seconds
per scene) as compact dropdowns, and an **Append** button → `appendTemplate`.
Retire the `MovieBuilderSheet` "Templates" entry (keep the sheet only if still
used elsewhere; Produce/Export unaffected).

## Edge cases

- Empty timeline → first append starts at frame 1 (`start=0`).
- After append: reinterpolate current easing; reflect new keyframes; respect
  one-keyframe-per-frame (append is past the end, so no collisions).
- State preset append: length grows; camera/scene tracks untouched.
- `clearMovie`/Reset wipes tracks + core movie.

## Non-goals (this pass)

- Dedicated States track.
- Full `.pse` track reconstruction (the append-emits-frames plumbing makes it
  a small follow-up — parse the core once on load).
- Desktop tab concept (macOS keeps the toggle).

## Testing

Build both schemes; sim-validate on iPhone (launch into the Movie/timeline via
`PYMOL_AUTOTIMELINE` + `PYMOL_SKIP_FIRSTBOOT_THEME`): append a Camera preset →
diamonds appear in the new range; append a Scenes preset → markers appear;
append a State loop → length grows; verify the composer + tracks + transport in
one view, tab bar hidden. Then deploy to the iPhone.
