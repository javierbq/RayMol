# Real-time ray tracing — implementation plan

**Goal:** Interactive, hardware ray-traced ambient occlusion + shadows over the rasterized scene, using a Metal acceleration structure of the molecule's atom spheres. Gated by `metal_raytrace`; falls back to shadow-map/SSAO when off or unsupported.

**Approach (hybrid RT over rasterized G-buffer):** keep rasterization for primary visibility (all reps); replace the SSAO/shadow-map post pass with a **fragment RT pass** that, per pixel, reconstructs the eye-space position+normal from `_sceneDepth`, transforms to MODEL space (via inverse modelview), and traces:
- N **AO rays** over the hemisphere (occlusion within a radius) → ambient occlusion.
- 1–few **shadow rays** toward the key light (model-space light dir) → contact shadow.
Composite `sceneColor × (ao · shadow)`.

**Acceleration structure:** instanced triangle **icospheres** (one shared unit-icosphere primitive AS; an instance AS with one instance per atom: transform = translate(center)·scale(radius), MODEL space). Triangle geometry ⇒ built-in intersection, **no intersection-function table** (lowest risk). Rebuilt only when the sphere set changes (model-space centers are rotation-invariant; detect via count + checksum) — not per rotation.

**Geometry source (v1):** the `spheres` rep's impostor draw data (`drawSphereImpostors`, model-space center+radius). RT therefore applies when atoms are shown as spheres. (Cylinders/cartoon/surface occluders = follow-up.)

## Milestones

### RT-1 — Setting + plumbing + matrices (no visual change)
- `SettingInfo.h`: `REC_b(802, metal_raytrace, global, false)`.
- `Renderer.h`: extend `setPostParams(... , int rtEnabled = 0)`.
- `SceneRender.cpp`: read `cSetting_metal_raytrace`, pass to `setPostParams`.
- `RendererMetal`: store `_rtEnabled`; compute + store `_modelviewInv` (glm::inverse) in `loadMatrixf` for MODELVIEW; in ctor record `_rtSupported = [_device supportsRaytracing]`.
- Build, verify no regression.

### RT-2 — Geometry capture + acceleration structure
- Generate a unit icosphere (icosahedron + 1 subdivision, ~80 tris) in C++; build its primitive AS once.
- Hook `drawSphereImpostors` to append (center.xyz, radius) to `_rtSpheres` (cleared each frame at `beginFrame`).
- At `runPostChain` start: if `_rtEnabled && _rtSupported` and the sphere set changed (count+checksum), (re)build the instance AS (one instance/atom, transform translate·scale).
- Verify build (log instance count, no crash).

### RT-3 — RT fragment pass + composite
- MSL `rt_resolve` fragment (in `kPostSrc` or a new lib): bind `_sceneColor`, `_sceneDepth`, the instance AS, and an `RTU` uniform (modelviewInv 4x4, light dir model, projA/B/X/Y, params). Reconstruct p_eye+n_eye → model space; `intersector<instancing>` with `accept_any_intersection(true)`; trace AO (cosine hemisphere, radius ~ few Å) + 1 shadow ray; output `sceneColor × occlusion`.
- In `runPostChain`: when `_rtEnabled && _rtReady`, run `rt_resolve` in place of the SSAO/shadow pass; `useResource` the primitive AS. Rest of chain unchanged.
- Verify PID-exact: RT AO/shadow vs SSAO/shadow-map; correctness across rotation; toggle via `set metal_raytrace`.

### RT-4 — Tune + (stretch) cylinders + shadows quality
- Tune AO radius/intensity/sample count, shadow softness; compare to PyMOL `ray`.
- Stretch: add bond cylinders to the AS; multi-sample shadow for soft penumbra.

**Verification harness:** `bash swiftui/build_macos.sh` (core, RendererMetal.mm changed) + `xcodebuild …PyMOLViewer_macOS`; launch with a spheres scene; `set metal_raytrace, 1`; PID-exact screenshot. `PYMOL_NO_RT` env force-off if needed.

**Risk/fallback:** if `!supportsRaytracing`, `_rtEnabled` is forced off and the SSAO/shadow path runs — zero regression. Fragment-shader RT requires Apple6+ (M3 = Apple9 ✓).
