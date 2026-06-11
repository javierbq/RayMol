# Metal Impostor Ray-Casting for Spheres & Cylinders — Design

**Date:** 2026-06-11
**Branch:** `swiftui-cross-platform`
**Status:** Approved design; pending implementation plan.

## Goal

Render `show spheres` and `show sticks`/cylinders on the native SwiftUI+Metal
backend as **analytic GPU impostors** — per-pixel ray–sphere / ray–cylinder
intersection in Metal fragment shaders with correct per-fragment depth — instead
of the current tessellated-triangle fallback. This gives perfectly smooth
surfaces at any zoom, pixel-accurate silhouettes and depth, per-pixel specular
lighting, and is typically cheaper than high-tessellation geometry. It also
establishes the per-pixel normal/depth foundation that later Metal work (SSAO,
real-time ray tracing) builds on.

Scope decision: cover **both** spheres and cylinders, implemented **spheres
first** (validate the impostor + depth + lighting pipeline end-to-end), then
cylinders reusing that foundation. One spec, staged build.

## Current behavior (what we're replacing)

- `RepSphere` defaults to `sphere_mode = 9` (GLSL impostor). But
  `RepGetSphereMode` (layer2/RepSphere.cpp:142-145) downgrades mode 9 → 0 when
  `!use_shader || !ShaderMgr->ShaderPrgExists("sphere")`. On Metal (NO_OPENGL)
  the GL "sphere" shader program never exists, so spheres silently render as
  **tessellated triangles** via `RepSphere_Generate_Triangles`. Cylinders/sticks
  fall back analogously.
- `CGO_gl_draw_sphere_buffers` (layer1/CGOGL.cpp:812) and
  `CGO_gl_draw_cylinder_buffers` (CGOGL.cpp:874) early-`return` when
  `G->Renderer` is set (Metal), so the impostor VBOs — if they were emitted —
  would no-op.
- `RendererMetal` builds inline-MSL pipelines (`buildVBOPipelines`), uses a
  `Depth32Float_Stencil8` depth attachment, has a controllable depth-write
  state, and binds `uniforms{modelview, projection}` at vertex buffer index 1.
  No fragment depth output (`[[depth]]`) is used yet.

## Approach (chosen: A)

Reuse the reps' existing impostor VBOs and port the proven GL impostor shaders
to Metal pipelines, isolated to the Metal layer plus a small rep-gate change:

1. **Lift the rep-mode downgrade** so the impostor `*_buffers` ops are emitted on
   Metal. In `RepGetSphereMode` (and the cylinder equivalent), keep mode 9 when a
   Metal renderer with impostor support is active, rather than forcing 0 on the
   GL `ShaderPrgExists` check. Concretely the condition becomes "downgrade only
   when `!use_shader || (!G->Renderer && !ShaderPrgExists(...))`", i.e. Metal is
   treated as having the impostor capability.
2. **New Metal impostor pipelines** in `RendererMetal` (inline MSL, mirroring the
   existing VBO pipeline construction) for spheres and cylinders, each with a
   fragment `[[depth(any)]]` output and a vertex descriptor matching the impostor
   VBO attribute layout.
3. **Wire the no-op Metal branches**: in `CGO_gl_draw_sphere_buffers` /
   `CGO_gl_draw_cylinder_buffers`, when `G->Renderer` is set, extract the
   impostor VBO's retained CPU copy + per-attribute offsets and the needed
   uniforms, and call `RendererMetal::drawSphereImpostors(...)` /
   `drawCylinderImpostors(...)`.

Rejected alternatives: (B) finer tessellation — not impostors, heavier, misses
the point; (C) a fresh Metal-native instanced impostor path with a new per-
sphere instance buffer — cleaner long-term but needs new rep-side buffer
generation and reinvents the working data path; revisit as a later GPU-driven
optimization.

## Sphere impostor

### VBO data (already produced by `RepSphere_Generate_Impostor_Spheres`)
- 4 vertices/sphere (quad; GL_QUADS upstream — on Metal we draw as two triangles
  per quad, see "Quads on Metal" below).
- Attributes: `a_vertex_radius` (Float4: center xyz + radius), `a_Color`
  (UByte4Norm RGBA), `a_rightUpFlags` (corner code: bit0 → right, bit1 → up;
  values 0,1,3,2 over the quad).
- Built by `CGOOptimizeSpheresToVBONonIndexed` (layer1/CGO.cpp:4276-4394).

### Vertex shader (MSL, ported from data/shaders/sphere.vs)
- Extract `radius = a_vertex_radius.w * sphere_size_scale`, normalized for the
  current scale.
- Decode corner offset from `a_rightUpFlags` (`right = -1+2·mod(f,2)`,
  `up = -1+2·floor(mod(f/2,2))`).
- Transform sphere center to eye space; offset the corner by `radius * (right,up)`
  plus the **outer-tangent adjustment** (sphere.vs `outer_tangent_adjustment`)
  that expands the quad so it covers the sphere silhouette under perspective.
- Output: clip-space position; and to the fragment: eye-space sphere center,
  radius, color, and the eye-space impostor point (ray target).

### Fragment shader (MSL, ported from data/shaders/sphere.fs)
- Build the ray (perspective: origin 0, dir = normalize(point); ortho: origin =
  point, dir = (0,0,-1)).
- Solve the ray–sphere quadratic; `discard` if discriminant < 0.
- Front intersection → eye-space surface point `ipoint`; normal =
  `normalize(ipoint - center)`.
- Lighting: `max(N·L, 0)` diffuse + Blinn-Phong specular (fixed shininess /
  intensity for the shiny PyMOL look) + ~0.25 ambient, applied to `a_Color`.
- Depth: see "Depth convention". Output `{ float4 color [[color(0)]]; float depth
  [[depth(any)]]; }`.

## Cylinder impostor (stage 2)

### VBO data (`CGOOptimizeCylindersToVBO` → `cylinder_buffers`)
- 8 vertices/cylinder (eye-space bounding box), indexed triangles.
- Attributes: `attr_vertex1`, `attr_vertex2` (Float3 endpoints), `a_Color`,
  `a_Color2` (Float4), `attr_radius` (Float), `a_cap` (Float bitfield: front/end
  enabled, front/end round-vs-flat, color-interp flag), `attr_flags` (Float:
  packed box-corner selection).

### Shaders (ported from cylinder.vs/.fs)
- Vertex: build the eye-space orthonormal basis (U, V, axis), expand the bounding
  box corner; pass endpoints, basis, radius, colors, caps, inverse-square-height.
- Fragment: ray–cylinder intersection in the cylinder's local U-V plane
  (2D quadratic); radial normal; flat-cap (plane) and round-cap (sphere)
  handling per `a_cap`; per-pixel two-color interpolation by axial ratio;
  diffuse + specular; `[[depth(any)]]` output.

## Depth convention (key risk)

The GL impostor shaders write `depth = 0.5 + 0.5·clipZ/clipW` because GL clip-Z
is `[-1,1]`. Metal clip-Z is `[0,1]`. The Metal fragment will compute
`clip = projection · float4(eyePoint, 1)` and output `clip.z / clip.w`; the
`0.5+0.5` remap is applied **only if** the renderer's projection matrix produces
GL-convention `[-1,1]` Z. This is verified empirically during implementation:
the rasterized geometry (cartoon/surface) already depth-tests correctly on Metal,
so impostor depth must be made to match that same convention — confirmed by
checking that impostor spheres correctly occlude and are occluded by cartoon and
sticks in a mixed scene. Getting this exactly right is the single most important
correctness item.

## Quads on Metal

Metal has no `GL_QUADS` primitive. The sphere VBO is 4 corner vertices per quad.
The Metal path will draw them as triangles — either by emitting an index buffer
(0,1,2, 0,2,3 per quad) at draw time, or by selecting the corner-expansion so a
triangle-strip/list covers the quad. Implementation detail to be settled in the
plan; the renderer already converts quads→triangles elsewhere.

## Uniforms

Extend the impostor uniform block (vertex buffer index 1) with the fields the
shaders need beyond modelview/projection: `sphere_size_scale`, an ortho flag,
and viewport/normal-scale terms used by the outer-tangent adjustment. Fragment
lighting constants (specular intensity, shininess, ambient) are compile-time
constants for v1.

## Picking

Unchanged. CPU `metal_pick` projects atom coordinates independently of how
spheres/cylinders are drawn; impostor depth does not affect it.

## Out of scope (v1)

- Global sorting of **transparent** spheres/cylinders (render opaque first;
  transparent impostors may not sort perfectly — acceptable, revisit later).
- Honoring PyMOL lighting settings (`specular`, `shininess`, `light_count`,
  `reflect`, `ambient`) — fixed constants for now.
- Shadows, SSAO, hardware ray tracing — separate later milestones.

## Testing / acceptance

Use the PID-exact screenshot harness (`open -nF` + `/tmp/winforpid` +
`screencapture -l`; env affordance `PYMOL_AUTOCMD`). On 1ubq:
- `show spheres` → smooth, round silhouettes (vs. the faceted baseline), visible
  specular highlights, no crash.
- Mixed `show cartoon; show spheres, resn LYS` → impostor spheres correctly
  occlude / are occluded by the cartoon (depth correctness).
- Dense all-atom `show spheres` → performant, no artifacts.
- Ball-and-stick (`show sticks; show spheres` with small sphere_scale) once
  cylinders land → spheres and sticks render as smooth impostors and join
  cleanly.
- Compare against desktop GL PyMOL's impostor output as a visual reference.

## Staging

1. **Spheres**: lift gate (sphere), sphere impostor pipeline + shaders, wire
   `CGO_gl_draw_sphere_buffers`, get depth + lighting correct, verify.
2. **Cylinders**: lift gate (cylinder), cylinder impostor pipeline + shaders
   (caps, two-color, depth), wire `CGO_gl_draw_cylinder_buffers`, verify
   ball-and-stick.

## Key files

- `layer2/RepSphere.cpp` (`RepGetSphereMode` gate, ~142-145) and the cylinder
  rep equivalent.
- `layer1/CGOGL.cpp` (`CGO_gl_draw_sphere_buffers` ~812, `CGO_gl_draw_cylinder_buffers`
  ~874; `drawVBOViaMetal` pattern ~28-87).
- `layerGraphics/metal/RendererMetal.{h,mm}` (pipeline build, depth-stencil
  state, new `drawSphereImpostors`/`drawCylinderImpostors`).
- Reference math: `data/shaders/sphere.vs`, `sphere.fs`, `cylinder.vs`,
  `cylinder.fs`.
- `layer1/CGO.cpp` impostor VBO builders (`CGOOptimizeSpheresToVBONonIndexed`
  ~4276-4394; cylinder equivalent).
