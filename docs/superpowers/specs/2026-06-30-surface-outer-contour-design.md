# Surface Outer-Contour Outline — Design

Date: 2026-06-30
Worktree: `claude/zen-engelbart-b526f2`

## Goal

Give the **surface** rep a clean outline tracing its **outermost contour** (its
projected outer silhouette), drawn crisply even when the surface is
semi-transparent and/or front-clipped — so a translucent, clipped surface still
reads as a clearly defined shape. This is the outer silhouette of the surface,
NOT the clip cross-section outline.

Per user: clip the front of a semi-transparent surface but keep "a clearly
defined contour with the shape of the surface … the silhouette that follows the
outmost contour."

## Why the existing `metal_outline` isn't enough

`metal_outline` is a global, depth-based Sobel edge pass (`post_outline`,
RendererMetal.mm). Transparent (OIT) surfaces write no depth, so they get no
outline; and depth-edges trace every interior fold (noisy on a bumpy molecular
surface) and aren't per-rep. We need a surface-specific, coverage-based outer
contour that survives transparency.

## Settings (per surface, level: object)

- `surface_contour` (bool, default 0) — on/off.
- `surface_contour_width` (float px, default ~2) — constant on-screen thickness.
- `surface_contour_color` (color, default -1 = inherit the surface color; -1
  resolves to the rep/object color, else black).
- `surface_contour_opaque` (bool, default 1) — crisp opaque line vs. a line that
  picks up the surface's transparency (`1 - transparency`).

## Mechanism (Metal)

1. **Capture (deferred):** during the surface's `drawVBO`/`drawVBOIndexed`, when
   `surface_contour` is on, stash the draw — Metal vertex+index buffers, count,
   stride, posOffset, the current modelview/projection, the per-rep clip planes
   (`_repClipFront/_repClipBack`), and the contour params (color/width/opaque) —
   into a per-frame list grouped by surface object. Nothing else changes in the
   main pass.
2. **Coverage pass (post, before the contour pass):** for each contour-enabled
   surface group, render its stashed draws position-only into a single-sample R8
   coverage texture (cleared to 0), cull none, depth test off, applying the same
   per-rep clip discard so coverage matches the *displayed* (clipped) surface;
   surviving fragments write 1.0. Coverage = the surface's screen footprint
   (front clip removes the front cap but back faces still cover the silhouette,
   so the outer contour stays stable as you clip — desired).
3. **Contour post-pass (`post_surface_contour`):** sample the coverage texture in
   a ring of radius = width; a pixel is on the contour where coverage transitions
   (center vs. neighbor differ) — i.e. the boundary of the covered region (outer
   silhouette + any interior holes/tunnels). Composite the contour color over the
   scene color at those pixels, with alpha = opaque ? 1 : (1 - transparency).
   Ping-pongs `_sceneColor`/`_postColor` like the other post passes; slots in
   right after the `metal_outline` pass.

Multiple contour-enabled surfaces: loop the coverage+contour pass per surface
group so each keeps its own color/width.

## New shaders (inline `vboSrc` + post)

- `coverage_vertex` (position-only, outputs eyeDist) + `coverage_fragment`
  (applies `apply_rep_clip`, returns 1.0) — reuse the `ClipU`/`apply_rep_clip`
  already in `vboSrc`.
- `post_surface_contour` fragment — coverage-edge detect + composite.

## Renderer changes (RendererMetal.h/.mm)

- Members: `_surfaceCoverageTex` (R8, resized with the scene), `_coveragePipeline`,
  `_surfaceContourPipeline`, and a `std::vector` of stashed coverage draws.
- `setRepContour(...)` (or extend the per-rep state set from CGOGL) to pass the
  contour params + enable for the current surface draw; cleared for non-surface
  reps (mirrors `setRepClip`).
- Capture in `drawVBO`/`drawVBOIndexed`; render coverage + contour in the post
  chain; clear the stash each frame.

## CGOGL changes

In `metalApplyRepClip` (or a sibling), when the rep is the surface and
`surface_contour` is on, read the 4 settings, resolve the color, and hand the
draw + params to the renderer to stash.

## Inspector

Add to the Surface `RepSpec` (ObjectPanel.swift) + `appkit_inspector.REP_SETTINGS`:
Contour toggle, Contour width slider, Contour color, Contour opaque toggle.

## Scope / non-goals

- Surface rep only; Metal path (consistent with this branch). GL/ray parity later.
- v1 detects coverage boundary (outer contour + interior holes). Fine for "outmost
  contour."

## Risks

- **Hi-res export:** scale width by `pixelRadiusScale()` (like the other post
  passes) so the line isn't hairline in 2×/4K.
- **Coverage resolution:** single-sample R8 → the contour may show slight
  aliasing; feather the edge in the post-pass.
- **Per-frame stash lifetime:** stash holds cached `id<MTLBuffer>` (already in
  `_vboCache`); clear the list at frame start to avoid stale buffers.
- **Cost:** one extra small pass per contour-enabled surface; negligible for the
  typical 1–2 surfaces.

## Testing

Headless A/B on the iPad sim: transparent + front-clipped surface, contour
on vs off → a clean outline appears around the outer shape, follows it under
clip/rotate; off = unchanged; opaque surface also outlined; cartoon unaffected.
