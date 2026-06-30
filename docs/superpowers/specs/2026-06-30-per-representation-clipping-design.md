# Per-Representation Clipping (Approach A) — Design

Date: 2026-06-30
Branch/worktree: `claude/zen-engelbart-b526f2` (zen-engelbart)

## Goal

Let each representation of an object carry its own clip depth so a user can, e.g.,
clip the **Surface** to peek inside while the **Cartoon/Sticks** stay whole. The
control sits in the per-rep inspector grid alongside Transparency.

## Chosen approach — "A: per-rep *tighter* clip via fragment discard"

Clipping today is global: a single near/far slab (`SceneView::ClippingPlane`)
is baked into one projection matrix shared by every rep (`SceneRender.cpp`).
Approach A keeps the global slab generous (whole structure visible) and lets a
rep clip *further in* than global by discarding fragments past a per-rep depth.
One shared projection ⇒ fog/SSAO/depth-reconstruction stay correct.

Rejected: per-rep *exempt* via matrix swap (B) — cheaper but cannot generalize
and breaks depth-based post effects at the boundary.

### Why per-rep-*type* settings (not per-object)

Settings in PyMOL are hierarchical (global / object / object-state / atom). A
plain object-state setting cannot differ between the surface and cartoon of the
**same** object — which is the entire point. So clip offsets are **per-rep-type**
settings (`surface_clip_*`, `cartoon_clip_*`, …), each read in the draw path for
that rep, exactly like `cartoon_transparency` / `surface_color`. This mirrors the
existing `metal_interior_cap` (object-level) plumbing.

### Setting semantics

For each rep type, two settings (eye-space distance units, measured from the
camera, same units as the global front/back):

- `<rep>_clip_front` — extra inset of the **near** plane for this rep. `0` = no
  extra clip (use global slab). Positive = clip further from camera (peek in).
- `<rep>_clip_back` — extra inset of the **far** plane. `0` = none.

The effective per-rep planes are `front_eff = global_front + <rep>_clip_front`
and `back_eff = global_back - <rep>_clip_back`. Fragment kept iff
`front_eff <= eyeDist <= back_eff`. Because discard only *removes*, a rep can
only clip tighter than the global slab (never extend past it) — consistent with
Approach A.

## Data flow (Metal / iPad — primary target; GL path mirrors it)

1. **Settings** — new `REC_f` entries in `layer1/SettingInfo.h` (object-state
   level) + indices appended after the current max.
2. **Read per-rep** — in `layer1/CGOGL.cpp`, the draw helpers
   (`drawVBOViaMetal`, `drawVBOIndexedViaMetal`, `drawSphereImpostorsViaMetal`,
   `drawCylinderImpostorsViaMetal`) read the offset pair for the current rep
   type from `s1=rep->cs->Setting`, `s2=rep->obj->Setting` and pass them on the
   draw-call structs (new `clipFront`/`clipBack` fields next to `interiorCap`).
3. **Renderer** — `layerGraphics/metal/RendererMetal.mm` forwards the offsets
   into the per-draw uniform structs (the inline MSL impostor uniforms already
   carry `interiorCap`; surface/VBO path gets new uniform fields) and the global
   `front`/`clipRange` it already knows (`SceneGetCurrentFrontSafe/BackSafe`).
4. **Shader discard** — each fragment reconstructs eye-space distance (the
   impostor shaders already compute `ez`/depth; the lit VBO + surface shaders
   reconstruct from interpolated eye position / `gl_FragCoord`) and
   `discard_fragment()` outside `[front_eff, back_eff]`.

## Increments (each independently testable on the iPad simulator)

The transparent surface in the user's screenshot means the **OIT pass** is on
the critical path for the headline demo, so it is folded into Increment 1.

1. **Surface clip (Metal, opaque + OIT)** — the demo. `surface_clip_front/back`
   → CGOGL surface path → `surface.metal` (and the OIT variant) discard. Verify
   on sim: load 2kpo, surface transparent, set `surface_clip_front` and confirm
   the surface opens while cartoon/sticks stay whole.
2. **Impostor reps** — `sphere_clip_*`, `stick_clip_*` into the inline MSL
   impostor uniforms (front-clip logic already present).
3. **Cartoon + lines/triangles** — `cartoon_clip_*`, `line_clip_*` in the lit
   VBO + line shaders.
4. **Inspector UI** — `appkit_inspector.REP_SETTINGS` + `RepCatalog.specs`
   (ObjectPanel.swift): a Clip-front / Clip-back slider per rep.
5. **GL path + Ray path parity** — GL `.fs`/`.vs` discard; `CRay` per-rep clip.

Increments 1–4 give a shippable, demoable iPad feature; 5 is desktop/raytrace
parity.

## Testing strategy

- **Headless A/B render** (no UI taps): `bash swiftui/build_ios.sh simulator`
  → rebuild app → `xcrun simctl launch` with
  `SIMCTL_CHILD_PYMOL_AUTOLOAD`, `SIMCTL_CHILD_PYMOL_AUTOCMD`
  (`show surface; set transparency,0.5; set surface_clip_front, 8`),
  `SIMCTL_CHILD_PYMOL_AUTOEXPORT=/tmp/out.png,W,H,0`. Pull PNG, eyeball /
  pixel-diff front-clip on vs off.
- Renderer/CGO/settings changes are in `libpymol_core.a` ⇒ require a core
  rebuild (`build_ios.sh simulator`) before the app xcodebuild. Inspector-only
  (Swift/py) changes do not.
- Bump the build-tag banner so a stale install is detectable.

## Risks / open questions

- **OIT correctness** — discarded fragments must not corrupt the weighted-blend
  accumulation; verify transparent surface clip has no haloing at the cut.
- **Interior cap interaction** — `metal_interior_cap` caps the *global* slab
  cross-section; per-rep clip cuts inside it. For increment 1 the cap is left
  keyed to the global slab (documented), revisited if it looks wrong at the cut.
- **Depth/fog** — single shared projection means fog stays correct; confirm the
  cut face fogs consistently with neighbouring geometry.
