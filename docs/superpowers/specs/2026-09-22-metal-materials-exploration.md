# Advanced materials on the Metal backend — exploration

- **Date:** 2026-09-22
- **Status:** Exploration / feasibility. No code changes.
- **Question:** Can cartoon, surface and sphere representations be rendered as
  polished metal with reflections, as glass, or as marble on the native
  Metal renderer? What would each take?

## 1. Short answer

Yes to all three, and most of it is cheaper than it sounds because the
renderer already has the two hard prerequisites: per-pixel analytic normals
for spheres/cylinders (impostors) and a hardware ray-tracing acceleration
structure (AS) that already holds every atom sphere, stick cylinder and
cartoon/surface triangle in model space. What is missing is a *material*
concept: every fragment today runs one fixed two-light Blinn-Phong model with
global sliders, writes to an 8-bit LDR colour target, and there is no
environment to reflect.

Ordered by value per unit of work:

| Look | Technique | New infrastructure | Runs on | Effort |
|---|---|---|---|---|
| Brushed / polished metal | GGX metallic BRDF + image-based lighting (IBL) from a studio environment cubemap | material uniform, env cubemap, HDR scene target | all Apple GPUs incl. iOS | small–medium |
| Marble, clay, wax, fiber | Procedural 3D noise in model space modulating albedo + normal; reuse `metal_sss_wrap` | material uniform, model-space position in fragment | all | small |
| Glass | Fresnel reflection (IBL) + screen-space refraction of the opaque scene behind, through the existing OIT path | material uniform, env cubemap | all | medium |
| Mirror reflections of *other parts of the molecule* | One reflection ray per pixel against the existing AS, shaded at the hit | per-primitive colour buffers for the AS, normal/material G-buffer | RT-capable GPUs (M-series, A17 Pro+) | medium–large |
| Refraction *through* the molecule (true glass) | Refracted rays against the AS | same as above plus non-opaque instances | RT GPUs | large |

The recommendation is a small material system (Section 5) delivered in four
phases (Section 6); phase 1 alone gives convincing metal and marble.

## 2. What the Metal backend has today

All rendering lives in `layerGraphics/metal/RendererMetal.mm` (7.3k lines,
MSL embedded as string literals; the `data/shaders/*.fs` GLSL files are the
legacy OpenGL path and are not used on Metal).

**Shading.** Every lit pipeline (triangle VBOs for cartoon/surface/mesh,
sphere impostors, cylinder impostors, bezier tube) runs the same PyMOL
two-light model: ambient + `direct` key light on +Z + `reflect` fill light at
(0.4,0.4,1), one Blinn-Phong specular lobe, two-sided normal flip. Parameters
come from the Scene sliders through `setLightingParams` (`RendererMetal.mm:1819`)
into a `LightU` struct bound per draw (`vbo_shade`, `RendererMetal.mm:4210`;
`sphere_shade`, `:5670`; cylinder, `:6119`). There is no per-object or per-rep
shading parameter today apart from colour; the per-object `metal_interior_cap`
shows the plumbing pattern (setting read in `layer1/CGOGL.cpp:255`, passed
on the draw call).

**Normals.** Spheres and cylinders are ray-cast impostors with exact
per-pixel normals and `[[depth]]` output. Cartoon/surface use interpolated
vertex normals (Phong). Post passes do *not* receive normals: SSAO, shadows
and the RT composite reconstruct a smoothed eye-space normal from the depth
buffer (`post_eye_normal_smooth`), which is good enough for AO but too noisy
for a mirror reflection direction on twisted ribbons.

**Targets.** Scene colour is `BGRA8Unorm`, 4x MSAA (`RendererMetal.mm:1567`).
The tone-map pass comment already flags promoting the chain to `RGBA16Float`
as a follow-up (`:989`). AO and DOF intermediates are already 16F.

**Transparency.** Weighted-blended order-independent transparency
(`vbo_fragment_oit`, `oit_resolve`): accumulates premultiplied colour and a
reveal term, composites over the *post-processed* opaque image. Transparent
fragments cannot see what is behind them, which matters for refraction.

**Ray tracing.** When `metal_raytrace` is on and the device supports it, an
instance AS is built in model space: one icosphere instance per atom
(320 tris, shared proto) plus a single "world triangle" instance holding
sticks (12-sided tubes), cartoon and surface triangles
(`ensureRayTracingAS`, `:2403`). It is rebuilt only when geometry changes,
not on rotation. The `rt_ao` fragment pass traces up to 256 AO rays and one
hard shadow ray per pixel using `intersector<instancing>`; `rt_composite`
blurs and multiplies. The AS carries **positions only**: no colour, no
normal, no material. The vertex buffer for world triangles is retained so
hits can read their facet (`rt_facet_normal`). Sphere hits know the
`instance_id`, so centre and radius are recoverable from `_rtSpheres`.

**Post chain.** RT-AO/shadow (or SSAO/shadow-map) → OIT resolve → DOF →
outline → surface contour → exposure/ACES tone-map → FXAA → blit. Offscreen
PNG export runs the same chain at higher quality (`_offscreen`, AO samples
≥ 48, RT scale 1). Anything added as a material or post pass applies to
exports for free.

**Existing "texture" feature.** PyMOL's CPU ray tracer has `ray_texture`
1–5 (Matte 1/2, Swirl 1/2, Fiber), implemented in
`RayReflectAndTexture` (`layer1/Ray.cpp:452`) as a perturbation of the
surface normal by hashed/trig functions of the model-space hit point. The
Metal path ignores it. These are the direct ancestors of "marble".

## 3. What is missing

1. **A material parameter path.** A per-object (later per-rep) setting
   reaching the fragment shaders as a small `MaterialU` uniform alongside
   `LightU`.
2. **An environment to reflect.** Metal and glass read as such only when
   there is something in the reflection. A studio-style environment cubemap
   (a few soft area lights on a dark or light gradient) is the standard
   answer and works with no ray tracing at all.
3. **HDR scene colour.** Metallic highlights and Fresnel rims exceed 1.0;
   on an 8-bit target they clip flat and the ACES pass has nothing to roll
   off. Promote `_sceneColor`/`_postColor` to `RGBA16Float`.
4. **A physically based BRDF.** Replace the single Phong lobe with
   Cook-Torrance/GGX (metallic, roughness, F0) when a material is active;
   leave the current model byte-identical when it is not.
5. **Model-space position in the fragment.** Procedural noise must be
   evaluated in model space so the pattern is glued to the molecule and does
   not swim while orbiting. Triangle pipelines need one extra varying;
   impostors already have the eye-space hit point and `invModelview` is
   already computed for RT.
6. **For traced reflections only:** per-primitive colour (and ideally
   smooth normal) buffers indexed by `instance_id`/`primitive_id`, and a
   normal + material G-buffer target from the scene pass so the reflection
   post pass gets a trustworthy reflection direction and roughness.
7. **For true refraction only:** non-opaque instances in the AS and a
   recursive trace budget. Not recommended for the live view.

## 4. Material by material

### 4.1 Metal (polished / brushed / anodised)

**Look.** Dark base with bright, colour-tinted reflections of the
environment; highlight shape controlled by roughness; grazing-angle
brightening from Fresnel. Per-atom/residue colouring becomes the metal tint
(F0), so a rainbow cartoon becomes rainbow anodised aluminium.

**Technique.** GGX specular with `metallic = 1`, `F0 = albedo`, diffuse term
zero. Ambient/indirect specular from a prefiltered environment cubemap:
sample a mip level chosen by roughness (`roughness² × mipCount`), multiply by
the split-sum environment BRDF (an analytic fit is fine; no LUT needed).
Key and fill lights stay where PyMOL puts them so the Scene lighting sliders
still mean something: `direct`/`reflect` scale the two analytic GGX lobes,
`specular`/`shininess` map to lobe intensity and roughness when the user has
not set `metal_roughness` explicitly.

**Reflections of the molecule itself.** Optional phase-3 addition: for pixels
with roughness below a threshold, trace one reflection ray in the existing
AS and blend the hit colour into the specular term by the Fresnel weight.
See 4.4.

**Cost.** One cubemap sample and ~30 ALU per fragment. Negligible on M-series,
fine on iPhone.

**Interactions.** RT-AO currently multiplies the *whole* colour. For metals
that darkens reflections in pockets, which is physically wrong but looks
acceptable; the correct fix is to write AO into the diffuse/ambient term only,
which needs the material ID in the post pass (phase 3).

### 4.2 Marble (and clay, wax, fiber, "swirl")

**Look.** Veined, slightly translucent stone. Colour veins follow a turbulent
noise field; the surface stays mostly smooth with faint normal detail; light
wraps softly past the terminator.

**Technique.** In the fragment shader, evaluate 3D value/simplex noise with
4–5 fBm octaves at `modelPos × scale`. Marble veins:
`v = sin(dot(p, dir) × k + turbulence(p) × amp)`, remapped to blend between
the atom colour and a vein colour (default: darker/greyer version of the same
colour, so `color` commands still work). Add a small normal perturbation from
the noise gradient for a stony micro-relief. Set `metal_sss_wrap` to ~0.3 by
default for the material to get the waxy look. Roughness ~0.3 with a weak
dielectric F0 (0.04) from the same GGX code as 4.1 gives the polished-stone
sheen.

The five legacy `ray_texture` modes can be ported almost line for line as
normal-only perturbations (they are trig/hash functions of the model-space
point), which gives CPU `ray` / Metal parity as a side effect.

**Cost.** fBm noise is the most expensive part (~5 hash lookups per octave).
Roughly 100–150 ALU per fragment at 5 octaves; still comfortably real-time on
M-series at 4K. On iPhone drop to 3 octaves.

**Interactions.** None with AO/shadows/OIT. Picking unaffected. Deterministic
in model space, so movies do not flicker.

### 4.3 Glass

**Look.** Mostly transparent, Fresnel-bright rim and highlights, environment
reflection, faint colour tint, and visible refraction of whatever is behind.

**Technique (no RT).**
- Draw the glass object through the existing OIT pipeline with a material
  flag. Per fragment: Fresnel `F = Schlick(F0 = 0.04, N·V)`.
- Reflection: sample the environment cubemap along `reflect(-V, N)` (and
  optionally an RT reflection ray in phase 3).
- Refraction: bend the view vector with `refract(-V, N, 1/ior)` and sample
  the **opaque scene colour** at the current pixel offset by the bent vector
  projected to screen space (scaled by an assumed thickness). This is the
  standard real-time trick; it needs the opaque colour texture bound to the
  OIT pass, which is a small change (OIT currently only *resolves* against
  it).
- Output `alpha = F + tint absorption`, colour = `reflection × F + refracted × (1−F) × tint`.
  Weighted-blended OIT handles overlapping glass surfaces order-independently
  with the usual approximation.

**Where it falls short.** Screen-space refraction only bends the *opaque*
background; glass in front of glass sees the resolved opaque image, not the
other glass. A cartoon inside a glass surface (a very common wish: opaque
ligand inside a transparent glassy protein surface) works well because the
cartoon is opaque and lands in the refraction source.

**True refraction (RT).** Trace a refracted ray into the AS, shade the hit
with the per-primitive colour buffer, exit through a second intersection for
a thickness estimate. Two rays per pixel plus hit shading, RT GPUs only, and
the AS would need the glass object's own primitives flagged non-opaque so
rays can pass through them. Worth prototyping for export only, not for the
live view.

**Cost (no RT).** Comparable to today's OIT pass plus one cubemap sample and
one colour-texture sample.

### 4.4 Traced reflections (shared by metal and glass)

**What exists.** The AS, `intersector<instancing>` in a fragment pass,
`invModelview`, a retained world-tri vertex buffer, and `_rtSpheres`
(centre + radius per instance). Hit shading needs colour and a smooth normal
at the hit, which the AS does not carry.

**Changes.**
1. When appending geometry (`rtAppendVBOTris`, `rtAppendCylinder`, the
   sphere accumulation at `:5841`), also append per-vertex colour (and normal
   for triangles) into parallel buffers. Sphere colour per instance; cylinder
   colour per triangle from the endpoint colours; cartoon/surface colour and
   normal read at the VBO's colour/normal attribute offsets, which the
   draw-call structs already carry for the rasteriser.
2. Add an `rt_reflect` fragment pass after `rt_ao`: read normal + roughness
   + material from a new G-buffer (see 5.3), compute `R`, trace one ray with
   `accept_any_intersection(false)`, shade the hit with the same two-light
   model plus env fallback on miss, and write the reflected radiance to an
   RGBA16F target. Composite in `rt_composite` weighted by Fresnel and gated
   by the material flag.
3. Roughness: jitter `R` inside the GGX lobe per pixel and reuse the temporal
   accumulation already built for AO (`post_ao_accum`) to converge glossy
   reflections while the view is still. Exports trace several samples.

**Cost.** One ray per pixel at `metal_rt_scale`, about the same as the shadow
ray today, plus hit shading. Rebuild cost of the AS is unchanged (the parallel
buffers are plain uploads).

### 4.5 Cheap extras that fall out of the same work

- **Plastic / clear-coat:** dielectric GGX (F0 0.04–0.08), low roughness,
  diffuse albedo kept. This is what most "ray-traced" molecular figures
  actually want and would be the best default upgrade.
- **Matte clay:** roughness 1, Oren-Nayar or Lambert, no specular, strong
  AO. Good for print figures.
- **Carbon / velvet sheen:** a retro-reflective rim term. Trivial once the
  BRDF is split out.

## 5. Proposed material system

### 5.1 Settings

Object-scoped (`object` storage class, like `metal_interior_cap`), so
`set metal_material, 1, myprotein` works and the Inspector can expose it per
object. Per-rep (cartoon vs surface on the same object) can follow the
`cartoon_transparency`/`transparency` precedent later with `cartoon_material`
and `surface_material` overrides.

| Setting | Type | Default | Meaning |
|---|---|---|---|
| `metal_material` | int | 0 | 0 legacy PyMOL, 1 plastic, 2 metal, 3 glass, 4 marble, 5 clay, 6–10 legacy `ray_texture` parity |
| `metal_roughness` | float | -1 | -1 = derived from `shininess`; 0 mirror … 1 fully rough |
| `metal_ior` | float | 1.5 | glass refraction index |
| `metal_material_scale` | float | 1.0 | procedural pattern frequency (Å⁻¹ × scale) |
| `metal_material_color` | color | -1 | second colour for veins; -1 = derived from atom colour |
| `metal_env_map` | int | 1 | 0 none, 1 built-in studio, 2 user file |
| `metal_env_intensity` | float | 1.0 | IBL strength |
| `metal_rt_reflections` | bool | false | trace reflection rays (needs `metal_raytrace`) |

Settings 0 and defaults must leave the current image byte-identical, the
same invariant every previous Metal feature has kept.

### 5.2 Plumbing

- `Renderer.h`: `setMaterialParams(int material, float roughness, float ior,
  float scale, float3 color2)`, called from `CGOGL.cpp` next to the
  `metal_interior_cap` read for each object draw (spheres, cylinders,
  triangle VBOs, tube).
- `RendererMetal`: a `MaterialU` struct bound at a new fragment buffer index
  on every lit pipeline (plain, OIT and shadow variants; shadow variant
  ignores it).
- One shared MSL helper block (`kMaterialSrc`) prepended to the VBO, sphere,
  cylinder and tube libraries: GGX BRDF, Schlick Fresnel, env sampling,
  noise/fBm, marble, legacy `ray_texture` modes, and a single
  `material_shade(albedo, N_eye, V_eye, P_model, LightU, MaterialU)` entry
  point that returns the legacy result when `material == 0`.
- Triangle pipelines: add `float3 posModel` to `VBOVertexOut` (the vertex
  shader has the model-space position before the modelview multiply).
  Impostors: `P_model = invModelview × P_eye`, matrix already available.

### 5.3 Targets

- Promote `_sceneColor`, `_postColor`, OIT accumulation and every
  intermediate that carries colour to `RGBA16Float`. Pipelines list their
  colour formats explicitly, so this is a mechanical sweep plus the MSAA
  resolve texture. Memory roughly doubles for those targets (a few tens of
  MB at 4K).
- Phase 3 only: add a second colour attachment `RGBA16Float` normal(xyz) +
  roughness/material-id(w) to the opaque scene pass (MRT), written by every
  lit fragment function, resolved alongside colour. This also lets the
  existing SSAO/shadow/outline passes drop the depth-derived normal, which
  would fix a class of "triangles under shadows" artefacts the comments in
  `rt_ao`/`rt_composite` are working around.

### 5.4 Environment map

Ship one small built-in studio HDR cubemap (six 256² RGBA16F faces,
mipmapped, ~1.5 MB) generated procedurally at startup: a vertical gradient
plus three soft rectangular area lights, one of them aligned with the key
light direction so reflections and the analytic highlights agree. No asset
licensing, no bundle-size change, identical on macOS and iOS. `metal_env_map
2` can load a user equirectangular image through the existing PNG loader
later. Prefiltering by roughness uses cubemap mips (blit `generateMipmaps`),
which is visually fine for this use; a proper GGX prefilter compute kernel is
an optional upgrade.

## 6. Phased plan

**Phase 1 — Materials without new targets (IBL metal, marble, plastic, clay).**
Settings, plumbing, `MaterialU`, shared MSL helper, model-space position,
built-in studio cubemap, GGX + IBL, procedural noise. Keep LDR for now and
accept clipped highlights. Inspector: a "Material" group in the Scene/Object
panel. Deliverable: `set metal_material, 2` turns a cartoon into anodised
metal in the live view and in exports, on Mac and iPad.

**Phase 2 — HDR chain + glass.** `RGBA16Float` sweep; bind the opaque colour
to the OIT pipelines; glass BSDF with screen-space refraction; exposure/ACES
now has real headroom. Deliverable: transparent glassy surface with a
refracted cartoon inside.

**Phase 3 — G-buffer + traced reflections.** MRT normal/material target;
per-primitive colour/normal buffers alongside the AS; `rt_reflect` pass;
Fresnel composite; temporal accumulation for glossy lobes; AO applied to
diffuse only. Gated on `metal_raytrace` like AO/shadows. Deliverable:
mirror-finish spheres reflecting the neighbouring helix.

**Phase 4 (optional, export-oriented) — Traced refraction.** Non-opaque AS
instances, two-bounce refraction, offscreen-only by default.

Rough sizing, judged against the RT-AO/shadow work already in the tree:
phase 1 is comparable to the impostor-lighting work; phase 2 is mostly a
format sweep plus one shader; phase 3 is about the size of the original RT
AO milestone set. Each phase is independently shippable behind settings that
default off.

## 7. Risks and open questions

- **Per-rep granularity.** Object-level materials mean a metal cartoon and a
  metal surface on the same object; users will want glass surface over
  plastic cartoon. Plan `cartoon_material`/`surface_material`/`sphere_material`
  overrides in phase 1 if the setting plumbing makes it cheap, otherwise
  phase 2.
- **Colour semantics.** Metals have no diffuse albedo; atom colour becomes
  the reflection tint. Very dark atom colours make near-black metals; a
  minimum F0 floor (e.g. 0.3) keeps them readable.
- **AO on metals** darkens reflections until phase 3 moves AO to the diffuse
  term. Acceptable for phase 1, note it in the setting help.
- **Screen-space refraction edge cases.** Offsets near the viewport edge
  clamp; glass over background shows the background shifted, which reads as
  a lens and is fine.
- **iOS performance.** IBL and noise are cheap; traced reflections are gated
  by `supportsRaytracing` through the existing `PyMOLBridge_SupportsRayTracing`
  path and can further respect `metal_rt_scale`.
- **PID-exact regression testing.** All existing screenshot tests must be
  byte-identical with `metal_material 0`; the HDR sweep in phase 2 will
  perturb the 8-bit output slightly (rounding) and needs a tolerance or a
  re-baseline, as the tone-map milestone did.
- **Legacy `ray_texture` parity.** Porting modes 1–5 is cheap and makes
  `ray` and the live view agree, but the CPU tracer's random table must be
  reproduced exactly or the two will differ in detail. Treat as a
  nice-to-have.

## 8. Prototype results (2026-09-22)

Traced self-reflections (Section 4.4) are implemented on branch
`proto/rt-self-reflections` (worktree `RayMol-refl`, two commits on top of
master, renders in `prototype_renders/`). The first commit was a throwaway with
env-var knobs; the second turned it into a feature:

- **Settings** (indices 833–837, after `cartoon_spline` 831 and `metal_rt_scale`
  832): `metal_rt_reflect` (F0, 0 = off), `metal_rt_reflect_tint`,
  `metal_rt_reflect_rough` (object-scoped, so `set metal_rt_reflect, 1, hemes`
  works with a global fallback), `metal_rt_reflect_env` and
  `metal_rt_reflect_samples` (global). Exposed in the Inspector both as Scene
  sliders (global default) and as per-rep rows on cartoon/surface/sticks/
  spheres; registered in the scene capture/animation lists.
- **Per-primitive materials without a G-buffer.** Each RT geometry occurrence
  records its material next to its pose and clip; the acceleration structure
  build writes the occurrence index per triangle (and per sphere instance) and
  the composite looks the material up for the primitive under the pixel (found
  with a primary ray) and for every reflection hit. The material table is
  refreshed every frame without rebuilding the acceleration structure, so
  dragging a slider never hitches.
- **Per-vertex normals** travel beside the triangles and are barycentrically
  interpolated at hits and at the reflecting pixel; this is what removed the
  per-facet sparkle and the mosaic look of the first pass.
- **Cost:** one primary ray + one reflection ray per reflective pixel (rough
  materials trace `metal_rt_reflect_samples` rays in exports only). Default
  images are unchanged. Live-view frame time still unmeasured (machine locked).

Lessons:

- Reusing a setting index silently truncates the table: index 831 was taken by
  `cartoon_spline`, so three of the new settings vanished and the fourth aliased
  another setting. `testing/tests/raymol/metal_rt_reflect.py` now asserts
  distinct, round-tripping indices.
- The depth-reconstructed normal is fine for AO but not for reflection
  directions; the primary-ray lookup is the cheap substitute for a normal
  G-buffer and is needed anyway for the material.
- Look: F0 0.25–0.3 untinted = polished plastic/lacquer (colouring stays
  legible); F0 1 + tint = anodised metal; F0 1 untinted = chrome. Surfaces
  benefit most (smooth, concave pockets reflect neighbouring lobes).

Still open for a merge: HDR colour chain (highlights clip), AO applied to the
whole pixel (the reflection term itself is not darkened, which is right, but
the base is), grid_mode masks honoured but untested, iOS untested, and the
live-view timing.

## 9. Progress log (2026-09-22)

Branch `proto/rt-self-reflections`, worktree `/Users/javier/repos/RayMol-refl`,
built app `/tmp/RayMol-refl.app`, renders in `RayMol-refl/prototype_renders/`.
Not pushed.

| Commit | What |
|---|---|
| `a9cdc34` | Throwaway: colour + normal buffers beside the AS, reflection ray in `rt_composite`, env-var knobs. |
| `914b740` | Glass coverage knob `RAYMOL_GLASS_COVER` (10.7). |
| `6a7baee` | Glass on transparent stick impostors (10.5). |
| `4467a61` | Glass fast hack on transparent lit meshes (10.4). |
| `6bdc9b8` | Rough marble on the lit triangle pipelines (env knobs), see 9.1. Probe scripts copied to `prototype_renders/scripts/` (scene.py, run.sh, montage.py). |
| `6b8e898` | Feature: `metal_rt_reflect` / `_tint` / `_rough` (object-scoped, 833–835), `metal_rt_reflect_env` / `_samples` (836–837); per-occurrence material table indexed per primitive; barycentric per-vertex normals; Inspector rows (Scene sliders + per-rep); scene capture/anim lists; `testing/tests/raymol/metal_rt_reflect.py`. |

Verified: settings resolve to distinct indices, per-object override with global
fallback (live over MCP in the built app); default renders unchanged; offscreen
exports for every scene below. Not verified: live-view frame cost (screen
locked all day), grid_mode, iOS.

Renders and the recipes that produced them (all `metal_raytrace 1`,
`metal_rt_shadows 1`, bg 0.12/0.13/0.16, exports at 1400×1000 or 1800×1300):

| File | Scene | Material settings |
|---|---|---|
| `final_cartoon.png` | 1ubq cartoon (off / glossy / tinted metal / brushed) | reflect 0 · 0.25 · 1+tint 1 · 1+tint 1+rough 0.5 (16 spp) |
| `final_surface.png` | 4hhb surface + 1ubq mixed reps | reflect 0 · 0.3 · 1+tint 1 · mixed 0.3 |
| `final_perobject.png` | 4hhb matte cartoon + mirror hemes; 1ubq glossy cartoon in matte transparent surface | hemes reflect 1 tint 0.6, protein 0; cartoon 0.6 tint 0.5, surface 0 |
| `final_normals_fix.png` | facet vs interpolated normals | same material, before/after |
| `copper_surface_4hhb.png` | 4hhb surface, colour (0.80,0.47,0.25) | reflect 1, tint 1, rough 0.15, 16 spp |
| `copper_surface_brushed_4hhb.png` | same | rough 0.45, 24 spp |
| `copper_surface_reflect045_4hhb.png` | same | reflect 0.45 (recommended for figures) |
| `copper_surface_reflect025_4hhb.png` | same | reflect 0.25 (satin/lacquer) |
| `twometal_barnase_copper_barstar_steel_1brs.png` | 1brs chains A/D as two objects | A copper: 0.45/1.0/0.15 · D steel (0.62,0.66,0.72): 0.6/0.35/0.4 |

Later renders (all in `prototype_renders/`, scenes in `scripts/scene.py`):
statuary marble (9.1), steel cartoon+sticks (9.2), glass surface / sticks /
ligand / tinted (10.4–10.5), copper+glass complex (10.6), gold or steel
interior inside a glass shell (10.7).

Observations that should shape the next material:

- Reflection strength 0.25–0.45 is the useful range for figures; 1.0 is only
  for deliberate chrome/gold looks and clips highlights on the 8-bit chain.
- Cross-object reflections (copper on steel at the interface) work with no
  extra code because every object shares one acceleration structure.
- The material lives on the RT geometry record, not in the forward shaders.
  Anything that must change the *base* shading (marble veins, clay, wax)
  needs the forward-shader material path from Section 5.2, which does not
  exist yet.

### 9.1 Marble rough cut (2026-09-22, commit `6bdc9b8`)

Section 4.2 built in its cheapest form on the lit triangle pipelines only
(cartoon + surface; impostors and the bezier tube untouched). The fragment
gets the model-space position as one extra varying; the lit-VBO uniform grows
eight material floats read once from the environment (`RAYMOL_MATERIAL=1`,
`RAYMOL_MARBLE_SCALE/_VEIN/_SHARP/_VEIN_RGB/_WRAP`); `vbo_shade` replaces the
albedo with `sin(direction·p + turbulence)` veins (two crossing sets, thinned
by a power, with a soft halo) over slow fBm mottling and raises the diffuse
wrap to 0.35. Vein colour defaults to a darker, desaturated version of the
base, so `color` still sets the stone's hue. Mode 0 is pixel-identical.

Renders (`prototype_renders/marble_*`), all with reflect 0.2 rough 0.1 for a
polished sheen:

| File | Knobs | Verdict |
|---|---|---|
| `marble_white_surface_4hhb.png` | scale 0.22, sharp 6, vein 0.85 | Convincing stone, but the veins form a fine crackle web rather than flowing marble veins. |
| `marble_white_surface_warmveins_4hhb.png` | scale 0.14, sharp 5, vein 0.8, vein RGB (0.45,0.36,0.30) | Best of the set: warm grey-brown veins, flowing, legible topology. |
| `marble_white_surface_coarse_4hhb.png` | scale 0.09, sharp 3.5, vein 0.75 | Too sparse: reads as mottled porcelain, veins mostly lost. |
| `marble_cartoon_1ubq.png` | defaults, helices pale blue | Carved-stone look; veins scale well with the thinner geometry. |
| `marble_green_surface_4hhb.png` | base 0x5f8f6a, vein RGB (0.12,0.16,0.12) | Verde marble; works with no extra code. |

What it confirms about the design: the forward-shader material path (a per-
draw material uniform + model-space position) is small and gives the look on
every GPU with no ray tracing. What is still missing for a real feature:
object-scoped settings (the per-draw hook from the reflection work can feed
them), the sphere/cylinder/tube pipelines, vein direction control (veins
currently follow fixed model-space axes), normal relief (needs the modelview in
the fragment or a model-space normal varying), and marble on the reflection
hit shading (the AS buffers carry flat colours).

**Statuary marble (matte, Carrara-like), after feedback that the polished
version was too shiny.** `marble_statuary_surface_4hhb.png` and
`marble_statuary_cartoon_1ubq.png`. Recipe: base (0.94, 0.925, 0.90), no
reflection, `specular 0.12`, `shininess 8`, `ambient 0.22 / direct 0.55 /
reflect 0.45`, `metal_rt_ao_intensity 0.95`, `metal_rt_ao_radius 12`,
`metal_rt_shadows 0` (soft PCF shadows; the traced hard edges read as grey
blotches on white stone) with `metal_rt_shadow_intensity 0.18`, light grey
background (0.80, 0.80, 0.81); marble knobs scale 0.12, sharp 3, vein 0.42,
vein RGB (0.64, 0.64, 0.66), wrap 0.6. Lesson: for stone the light rig matters
as much as the material: low specular, high wrap, wide soft AO, soft shadows.
A material preset should set those lighting defaults, not just the albedo.

## 10. Glass: what the code allows (investigation, 2026-09-22)

Facts checked in `RendererMetal.mm` on the prototype branch:

- The opaque scene encoder ends before the transparency encoder starts
  (`beginTransparentOIT`), and the opaque pass resolves its 4x MSAA colour
  into `_sceneColor` and depth into `_sceneDepth`. Both are therefore readable
  as textures **while transparent fragments are being shaded**. Nothing binds
  them there today.
- The OIT pass depth-tests against the opaque depth (LEQUAL) without writing,
  into two targets: premultiplied weighted colour (`_oitAccum`) and
  transmittance (`_oitReveal`). `oit_resolve` runs later in the post chain and
  blends `avg * (1 - reveal) + opaque * reveal` over the *post-processed*
  opaque image (after RT-AO/shadows, before DOF/outline/tonemap).
- Transparent geometry is excluded from the ray-tracing record
  (`!_oitActive`), so glass casts no shadow/AO and cannot be hit by
  reflection rays. Reflections of the *opaque* scene in glass would need the
  acceleration structure bound in the OIT fragment shader, which is possible
  (the RT library is compiled separately for exactly this reason) but is not
  the first step.
- Per-fragment eye-space normal, model-space position (added for marble) and
  the per-draw material hook are all available in the lit VBO OIT shader
  (`vbo_fragment_oit`); sphere/cylinder impostors have their own OIT variants
  with analytic normals.

### 10.1 Cheapest convincing glass (no ray tracing)

A "glass" branch inside `vbo_fragment_oit` (and later the impostor OIT
shaders), gated by a material mode, with `_sceneColor` bound as a texture:

1. **Refraction.** Bend the view vector by the eye-space normal with
   `refract(V, N, 1/ior)`, project the bent vector to a screen-space offset
   scaled by an assumed thickness (a few pixels at ior 1.5), and sample
   `_sceneColor` at `uv + offset`. Clamp the offset near the viewport edge.
   This shows the opaque geometry behind the glass, distorted. It cannot show
   other glass layers (they are not in `_sceneColor`), which is the standard
   real-time compromise and looks right for "opaque cartoon inside a glassy
   surface".
2. **Reflection.** Schlick Fresnel with F0 0.04 (ior 1.5); on the environment
   term reuse the studio-gradient function from the reflection pass (move it
   into the shared eye-reconstruction header so both libraries see it).
3. **Absorption / tint.** Beer-Lambert style `exp(-k * thickness)` toward the
   object's colour; thickness from `1 - N·V` as a proxy, or from the depth
   difference to the opaque surface behind (`_sceneDepth` is bound too).
4. **Output through OIT.** Emit colour `refracted * (1 - F) * tint + env * F`
   with a *high* alpha (0.85–0.95): the refracted sample already *is* the
   background, so the fragment must dominate the resolve rather than blend
   thinly. Where two glass sheets overlap the weighted average of both
   refracted samples is a soft double image, acceptable.
5. **Specular.** Keep the sharp Blinn lobe (glass is polished): shininess
   high, specular ≈ 0.6.

Mismatch to accept: the refracted sample comes from the *pre*-post-process
opaque colour (no RT-AO/shadows inside the glass), while the surroundings are
post-processed. Small, and fixable later by moving the glass pass after the RT
composite (then it must be its own raster pass reading `_postColor`).

### 10.2 Better glass (ray tracing)

- Bind the instance AS and the colour/normal buffers in the glass fragment
  and trace one reflection ray (same code as `rt_composite`) so the glass
  mirrors the opaque molecule, not only the studio gradient.
- Refraction through the molecule (two bounces, exit through the far side)
  needs the glass geometry itself in the AS as non-opaque instances; export
  only.

### 10.3 Plan

Rough cut (an afternoon): mode 2 = glass in the lit-VBO OIT shader, bind
`_sceneColor`/`_sceneDepth` in `beginTransparentOIT`, env knobs
`RAYMOL_MATERIAL=2`, `RAYMOL_GLASS_IOR`, `RAYMOL_GLASS_TINT`, `RAYMOL_GLASS_THICK`.
Scene: transparent surface (`transparency 0.5`) over an opaque cartoon or
sticks, 1ubq and a ligand complex. Judge: does the cartoon appear refracted
and does the rim brighten? Then decide on the RT reflection add-on.

Feature form: `metal_material 2` per object (needs the settings block from
Section 9 for marble anyway), ior/tint/thickness settings, impostor OIT
shaders, and the post-composite ordering fix.

### 10.4 Glass fast hack (2026-09-22, commit `4467a61`)

Section 10.1 built as an env-var prototype on the transparent lit-VBO shader
only. `beginTransparentOIT` binds the resolved opaque colour at texture(0);
`vbo_fragment_oit` in mode 2 samples it through a normal-bent screen offset
(refraction), attenuates toward the base colour (absorption), adds Schlick
Fresnel (F0 0.04) of the studio gradient, a sharp key-light highlight, a small
"frosting" blend of the diffusely lit base scaled by the user's opacity, and
writes coverage 0.92 so the refracted sample dominates the weighted-blended
resolve. Knobs `RAYMOL_MATERIAL=2`, `RAYMOL_GLASS_IOR` (1.5), `_THICK` (px per
1000 px height, 14), `_TINT` (1.0), `_REFLECT` (1.0); scenes `glass`,
`glass_dark`, `glass_ligand` in `prototype_renders/scripts/scene.py`.

| File | Knobs | Verdict |
|---|---|---|
| `glass_control_plain_transparency_1ubq.png` | mode 0, transparency 0.85 | Baseline: flat, milky transparency. |
| `glass_surface_over_cartoon_1ubq.png` | defaults, light bg | Clearly glass (rim, highlights, refracted cartoon edges) but frosted: the light studio gradient veils the whole surface. |
| `glass_clear_1ubq.png` | transparency 0.95, reflect 0.7, thick 26 | Clearer; stronger refraction doubles loop edges visibly. |
| `glass_darkbg_1ubq.png` | dark bg, transparency 0.9, reflect 0.8, thick 20 | Most convincing of the set: the Fresnel rim and sparse highlights read as glass, cartoon fully legible. |
| `glass_blue_tinted_1ubq.png` | colour 0x7fb3e6, tint 2.5 | Coloured glass: absorption shifts the cartoon toward blue, physically plausible. |
| `glass_surface_ligand_1hsg.png` | defaults | HIV protease + inhibitor: glass surface, grey cartoon, ligand sticks; typical figure use. |

Lessons: (1) the environment used for reflection must be darker than the
background or clear glass reads as frosted on light backgrounds; a real feature
should expose env brightness or derive it from `bg_rgb`. (2) The highlight
exponent 90 / strength 0.9 sprinkles many small hot spots on a bumpy surface;
lower strength or a wider lobe for surfaces, keep it sharp for smooth
cartoons. (3) Refraction thickness 14–20 px per 1000 px height is the sweet
spot; 26 shows double edges. (4) No shadows/AO inside the glass (samples the
pre-post-process colour) is not noticeable in these scenes.
Not done: impostor OIT shaders (sticks/spheres stay plain transparent), RT
reflections in glass, per-object settings, thickness from depth.

### 10.5 Glass sticks (2026-09-22, commit on top of `4467a61`)

The glass model was ported to the cylinder impostor OIT shader (sticks with
`stick_transparency`): `cyl_shade` now returns the hit normal and bond colour,
`CylU` carries the glass knobs, and `cyl_impostor_fragment_oit` applies the
same refraction/absorption/Fresnel/highlight model. Scenes `glass_sticks`
(1ubq: grey cartoon + side-chain sticks) and `glass_sticks_ligand` (1hsg:
grey cartoon + inhibitor sticks), `GLASS_BG=light|dark`.

| File | Knobs | Verdict |
|---|---|---|
| `glass_sticks_cartoon_1ubq.png` | light bg, transparency 0.8, reflect 1.0, thick 16 | Convincing: frosted-clear glass rods with bright rims; the ribbon refracts through them. |
| `glass_sticks_ligand_1hsg.png` | same, 1hsg | Glass inhibitor in a grey cartoon; N/O ends keep their colour through absorption. |
| `glass_sticks_cartoon_darkbg_1ubq.png` | dark bg, transparency 0.7, reflect 2.2 | Smoked glass: thin rods mostly refract the dark background, only rims read. |

Lesson: thin glass geometry needs a bright environment or background to read
as glass; on dark backdrops a real feature should raise the environment term
(or add RT reflections of the molecule) for cylinders specifically. Sphere
impostors still lack the glass branch (same pattern, ~40 lines).

### 10.6 Mixed materials in one complex (2026-09-22)

`metal_glass_barnase_copper_barstar_glass_1brs.png`: barnase (chain A) as a
copper surface (per-object `metal_rt_reflect 0.45 / tint 1 / rough 0.15`) and
barstar (chain D) as a glass surface (`transparency 0.85`, material mode 2)
over its own grey cartoon, light backdrop. No new code: the reflection
material is object-scoped and the glass hack only fires on transparent draws,
so the two coexist in one scene. The copper refracts through the glass at the
interface and the glass rim picks up the studio light. Scene `metal_glass`
(`REFL_CHAIN_A/_B` select chains) in `prototype_renders/scripts/scene.py`.

### 10.7 Metal inside glass (2026-09-22)

`metal_glass_goldsticks_1brs.png`: barnase copper surface; barstar glass
surface (transparency 0.9) over a grey cartoon with **gold metal side-chain
sticks** as a third object (`metal_rt_reflect 0.8 / tint 1 / rough 0.1`), so
only the sticks reflect. This exposed the ordering limitation from 10.1: glass
refracts the *pre*-post-process opaque image, so with coverage 0.92 the gold
sticks under the glass lost their traced reflections and looked flat
(`metal_glass_goldsticks_cover092_1brs.png`). A new knob `RAYMOL_GLASS_COVER`
(OIT coverage of glass fragments) at 0.55 blends in the post-processed opaque
image and the sticks read as polished gold through the glass, at the cost of
weaker refraction. The proper fix remains moving glass shading after the RT
composite (its own raster pass reading `_postColor`), which would give both.

### 9.2 Stainless steel cartoon + side chains (2026-09-22)

`steel_cartoon_sticks_1ubq.png` (dark bg) and `steel_cartoon_sticks_lightbg_1ubq.png`:
one object, cartoon + side-chain sticks, colour (0.62, 0.66, 0.72),
`metal_rt_reflect 0.6 / tint 0.35 / rough 0.35`, `specular 1.0`,
`shininess 60`, 16 reflection samples. Reads as brushed stainless: the
roughness turns the sheet reflections into soft streaks and the sticks into
polished rods. No new code (scene `steel`, `STEEL_REFLECT` / `STEEL_ROUGH`
env overrides). Both backdrops work; the light one shows the streaking
better, the dark one the rims.

`metal_glass_steelinner_1brs.png` (scene `metal_glass_steel`): same complex
with the barstar interior as stainless steel, cartoon + side-chain sticks in
one inner object (`metal_rt_reflect 0.6 / tint 0.35 / rough 0.35`), the glass
shell as a second object, glass coverage 0.55. Three materials in one frame
(copper, glass, steel) with no code beyond the coverage knob.

### 9.3 Rubber rough cut (2026-09-22, commit `64c268a`)

Material mode 3 on the lit triangle shader and the opaque stick shader:
slightly compressed Lambert (`pow(N·L, 0.85)`), a broad dim highlight
(exponent 8), a faint velvet sheen at grazing angles, and two-octave
model-space grain, with highlight and sheen tinted 70% toward the base colour
so nothing reads as a clear coat. Knobs `RAYMOL_RUBBER_GRAIN/_FREQ/_SPEC/_SHEEN`
(defaults 0.06 / 6 / 0.12 / 0.10). Scenes `rubber` (1ubq cartoon coloured by
secondary structure + grey side-chain sticks) and `rubber_surface` (4hhb teal).

| File | Knobs | Verdict |
|---|---|---|
| `rubber_control_plain_1ubq.png` | mode 0 | Baseline plastic. |
| `rubber_cartoon_sticks_1ubq.png` | defaults | Softer, broader highlights; grain barely visible at 1800 px. |
| `rubber_cartoon_sticks_grain_1ubq.png` | grain 0.14, freq 14, sheen 0.22, spec 0.16 | Reads as rubber: fine matte grain on sheets and rods, soft rim. Recommended defaults. |
| `rubber_surface_4hhb.png` | defaults | Matte silicone. |
| `rubber_surface_grain_4hhb.png` | grain 0.12, freq 10, sheen 0.2, spec 0.16 | Rubber toy look; wide soft AO in the pockets sells it. |

Lessons: grain must be visible to read as rubber (0.12–0.14 at 10–14 /Å, i.e.
sub-Å texture), and like marble the light rig matters: AO strength ~0.9 with
radius 8–10 Å, no reflections. The stick shader recovers a model-space
position from the eye-space hit through the rotation only (translation
ignored), fine for grain. Not done: spheres, per-object mode, settings.

### 9.4 Spheres (2026-09-23)

Sphere impostors already take the per-object reflection material (they are in
the acceleration structure and have analytic normals), so metal spheres work
with no code: `spheres_plain_1ubq.png` (control), `spheres_metal_1ubq.png`
(CPK colours, reflect 0.5 / tint 0.6 / rough 0.2) and `spheres_chrome_1ubq.png`
(reflect 1.0 / tint 0.1 / rough 0.05). The chrome set is the clearest
demonstration of true self-reflection in the whole series: each ball mirrors
its red/blue neighbours and the studio light. Marble, glass and rubber are NOT
yet on the sphere impostor shaders (mode ignored there). Scene
`spheres_material`, knobs `STEEL_REFLECT/_TINT/_ROUGH`.

**Rubber spheres (2026-09-23, commit on top of `64c268a`).** The sphere
impostor shader now has the rubber branch (mode 3). `spheres_rubber_1ubq.png`
(grain 0.14 / freq 14 / sheen 0.22 / spec 0.16, CPK toy colours, light bg, AO
0.9 radius 6) vs `spheres_rubber_control_1ubq.png`: the glossy hot spots are
gone, every ball has a matte grainy skin and a soft rim, and contact AO makes
them read as rubber balls pressed together. Glass and marble remain the only
modes missing on spheres.

## 11. Six more materials via subagents (2026-09-23)

Two subagents in isolated worktrees, on top of a knob-plumbing commit
(`fb6424a`: `RAYMOL_MAT_P0..P3`, `RAYMOL_GLASS_FROST`, `RAYMOL_WAX_P0..P3`
reach every uniform). Cherry-picked as `809c082` (wax + frost) and `4a39866`
(modes 4–7). Gallery: `prototype_renders/gallery.html` (thumbnails link to
full PNGs; `scripts/manifest.json` holds every recipe).

| Mode | Material | Where | Verdict from the renders |
|---|---|---|---|
| 4 | Clay / unglazed ceramic | VBO, sphere, cyl | Works as intended: the matte "clay render" look, grazing darkening reads as porous stone. Best on light bg. |
| 5 | Porcelain / glazed | VBO, sphere, cyl | Convincing bone china on surface and cartoon+sticks: creamy whitening, sharp coat highlight, glaze rim. |
| 6 | Iridescent thin film | VBO, sphere, cyl | Striking: oil-slick rings toward silhouettes, base colour kept face-on. Needs a mid-tone base (near-black bases lose the film). |
| 7 | Anisotropic brushed metal | VBO (screen-space tangent), sphere (model axis), cyl (axis) | Streaked highlights along sheets/rods; brushed-gold spheres are the best example. VBO version reads dark (P2 darkening stacks with AO); the ribbon tangent heuristic is untested at scale. |
| 8 | Wax / jelly (RT thickness) | rt_composite | Thin sticks/loops glow, core stays solid, backlight term works. Artefact: on coarse flat ribbons the inward ray self-hits and reads as thin -> hard bright patches on sheets. Fix: facet-aware min distance or a normal-offset origin. |
| 2+frost | Frosted glass | glass_shade, cyl_glass | 12-tap Vogel blur; frost 4 = etched, 8 = heavy. Reads well on dark bg; interior stays legible as soft shapes. |

Runner gotcha fixed along the way: `run.sh` defaulted `GLASS_BG=dark`,
overriding scene-level light defaults; clay/porcelain were re-rendered on the
light backdrop.

### 11.1 Jelly v2 (2026-09-23)

The opaque wax-mode gummy (mode 8 on a surface) looked like painted plastic.
Real jelly is semi-transparent, so v2 is mode 9 inside `glass_shade`: heavily
frosted refraction (7 px/1000), ior 1.33, strong absorption toward the base
colour, a milky scattered glow of the wide-wrapped lit base that thickens
toward the rim, and a broad soft highlight; used on a surface with
`transparency 0.55-0.6`. Renders `g_jelly_red.png`, `g_jelly_green_inner.png`
(grey cartoon visible blurred inside), `g_jelly_red_dark.png` (dull: the
transmitted term is the refracted background, jelly wants a bright backdrop).
Verdict: reads as a gummy body. Mode 8 remains useful for thin opaque parts
(sticks, loops) rather than whole bodies.

**Gummy v3.** Javier's gummy-bear reference showed the missing piece: the skin
is wet-glossy while the body scatters. v2 had frosted the highlight together
with the transmission. v3 keeps the Fresnel reflection of the sharp studio
gradient (reflect 1.0) and a sharp near-white highlight (exponent 70 + a low
broad lobe) and frosts only the refracted light. Renders `g_jelly_red_v3`,
`g_jelly_orange_v3`, `g_jelly_green_inner_v3`. Verdict: matches the reference.
General lesson for translucent materials: separate the skin BRDF from the
volume term; never blur the specular with the transmission.

**Gummy sticks.** Mode 9 ported to `cyl_glass` (sticks with
`stick_transparency`). `g_jelly_sticks_red.png` (all bonds, radius 0.45,
transparency 0.55) and `g_jelly_sticks_cpk.png` (N green, O orange): glossy
translucent rods with the half-bond colour split intact. Every transparent
path now has the jelly branch except sphere impostors (no glass path there).

## 12. Transparent depth pre-pass (2026-09-23)

Javier: "when sticks are transparent you can see the balls and cylinders
independently". Cause: weighted-blended OIT accumulates every fragment, so
the internal joins of a ball-and-stick blend through its own skin. Fix
(prototype, `RAYMOL_OIT_PEEL=1`): `wantsTransparentDepthPrepass()` makes
`SceneRenderMetal` run the transparent pass twice. `beginTransparentDepthPrepass`
blit-copies `_sceneDepth` into `_oitNearDepth` and renders the transparent
draws with their OIT pipelines but LESS + depth-write (colour discarded);
`beginTransparentOIT` then binds `_oitNearDepth` as the depth attachment with
the usual LEQUAL/no-write state, so only the nearest transparent layer per
pixel accumulates. `peel_before_after.jpg` shows the result: one translucent
shell, joins gone. Trade-offs: back layers of the same object (and other
transparent objects behind it) no longer show through; transparent geometry
is shaded twice (cheap; glass/jelly frost taps double). This is the natural
default for glass/jelly shells and for any translucent ball-and-stick; a
setting (`metal_oit_peel`) should default it on for `stick_ball` sticks.
