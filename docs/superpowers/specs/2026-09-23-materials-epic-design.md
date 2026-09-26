# Materials: per-representation surface materials on the Metal renderer

- **Date:** 2026-09-23 (rev 4, after two rounds of adversarial review; log in §9)
- **Status:** Design for the epic, ready to file. Supersedes the shipping
  parts of `2026-09-22-metal-materials-exploration.md`.
- **Prototype:** branch `proto/rt-self-reflections` (worktree `RayMol-refl`,
  17 commits on master `827a60a27`), renders in `prototype_renders/`.

## 1. Summary

Every style layer of an object (cartoon, surface, sticks, spheres) gets a
**material** chosen from a short named list: `default`, `matte`, `plastic`,
`metallic`, `glass`, `frosted_glass`, `jelly`, `marble`, `clay`, `rubber`.
Colour says *what* something is; material says *what it is made of*, and
every material keeps the user's colour scheme intact. Materials are set per
representation and per object, from the Inspector's style-layer rows or with
`set` using four settings that sit beside `cartoon_color` and friends.
Choosing a material writes no other setting. The `default` material compiles
to today's shaders and renders identically.

**Non-goals (v1):** per-atom materials; materials on the OpenGL/Qt path; HDR
colour chain (own epic, §8); true refraction through the molecule;
user-defined materials with tunable knobs (v2); colour-coupled or
colour-shifting looks (named metals, porcelain, iridescent film, chrome),
wax translucency, brushed anisotropy, glass or jelly on sphere impostors,
glass on ball-and-stick sticks (v2, §8).

**Selection rule.** A material ships in v1 only if it (a) leaves the base
colour untouched and readable, (b) renders on every Apple GPU with at most a
defined quality upgrade when ray tracing is on, (c) needs no side effect
beyond an implied opacity resolved at rep-build time, (d) exists on all four
representations or degrades to `default` on the missing one with no visual
glitch, and (e) was judged convincing in the prototype gallery.

Terminology: the C table of named materials is the **material table**; the
word *preset* is reserved for `modules/pymol/preset.py`, whose contract
("throw away the current look") is the opposite of this epic's.

## 2. Motivation

The prototype produced convincing metals, glass, gummy, marble, clay and
rubber, and its best figures combined materials across representations of
one object: a glass surface over steel sticks, a marble cartoon with matte
side chains, a jelly shell around a grey backbone. Today that needs separate
objects and twenty environment variables read once at launch. Users need a
dropdown per layer and a scriptable setting that looks right out of the box,
and the change must land in small, individually shippable steps.

## 3. Concept model

### 3.1 Scope and settings

- Four **object-scoped integer settings** carry the material id:
  `cartoon_material`, `surface_material`, `stick_material`,
  `sphere_material`, plus a global fallback `material_default`. Resolution for
  a draw: the rep's object-level value, then the rep's global value, then
  `material_default`. Ribbon, mesh, dots, lines and labels keep default
  shading in v1.
- Ids are integers so they round-trip through `.pse` and older builds, and so
  a later per-atom upgrade needs no type change. **Names live in C:**
  `SettingGetTextPtr` maps id to name for the five material indices exactly as
  it does for colour settings, so `get`, the `Setting: ... set to ...` feedback
  line, `iterate s.stick_material`, the whole-catalog Settings panel and `.pml`
  logs all show names. Python maps name to id at set time (`set
  stick_material, metallic, obj`); an unknown name is an error whose message
  lists the valid names and points to `help material`. Out-of-range integers
  (unclamped for object-level sets) resolve to `default` at draw time; names
  never fall back.
- **Selection-scoped set is rejected in C.** `ExecutiveSetSetting` would
  otherwise write an atom-level int on every matched atom. The
  `cExecSelection` branch gates `have_atomic_value` on the setting's level
  mask and returns an error for the material indices; Python adds the friendly
  message. Object names, `all`, groups and wildcards continue to work. The CI
  test drives `_cmd.set` directly.
- No value completer in v1: the parser hands completers only the token being
  typed, so `set <name>, <TAB>` cannot depend on `<name>` without a parser
  change (a separate small issue if wanted).
- The existing `metal_rt_reflect`, `metal_rt_reflect_tint`,
  `metal_rt_reflect_rough` stay: `default` reads them, so saved sessions and
  animations that ramp reflection keep working. The Inspector collapses them
  into one object-wide "Reflection (legacy)" group (§4.6).

### 3.2 A material is a pure function of its id

A material resolves to `MaterialParams` and **writes no other setting**:

[^jelly-alpha]: 0.45 in revisions 1-4, raised in #496 (PR #525). For a SINGLE
    transparent layer over a NEUTRAL background, `col*a + bg*(1-a)` has channel
    spread `a * spread(col) <= a`, whatever the shader does. Both conditions
    are needed and both hold for the measured renders: the epic's probe
    background is a 0.85 grey, and jelly's row sets `wantsPeel`, whose EQUAL
    depth test keeps only the nearest layer. Note the peel is a property of the
    frame, not of the material -- auto-peel can refuse, only
    `kMaxPeeledObjects` (3) objects peel per frame, and the GL path peels
    nothing -- so an unpeeled jelly object is denser (two layers cover
    `1 - 0.15² = 0.978`). **This is not a general law of the epic's transparency
    model** -- without a peel, `n` layers cover `1 - (1-a)^n` (and
    `backface_cull` is 0 by default, so a closed surface delivers two), and a
    coloured background contributes `(1-a) * spread(bg)` of its own. Under
    those two conditions the gallery's red gummy, at spread 0.539 against
    jelly's own emitted spread of ~0.62, would need alpha ~0.87 to match
    exactly; 0.85 lands at 0.528, 98% of it. Only the LOW end is arithmetic:
    any alpha at or below 0.539 cannot reach the reference's spread whatever
    the shader does, and the specified 0.45 is well inside that -- it renders
    a pale pink that still reads as a gummy, just not this one. The high end
    is a judgement (the alpha is also how much of the scene a jelly object
    hides), not a bound. 0.45 was a number from the prototype's
    architecture, where the fragment wrote coverage 1.0 and did its own
    transmission from the refracted opaque scene; that sampling is not
    available inside the OIT pass (see M6), so here the implied alpha has to
    carry the density the refraction used to.

- **Opacity.** Glass and jelly carry an implied alpha. Because a rep is routed
  to the transparent pass and bakes its per-vertex alpha at *build* time, the
  implied alpha is consulted in layer2 next to the rep's transparency setting
  (`MaterialImpliedAlpha(id)` in RepCartoon, RepSurface, RepCylBond) when the
  rep's own transparency is 0, and the four material settings get a
  `cRepInvColor` invalidation entry so changing material rebuilds the rep. The
  user's transparency slider still overrides. A `.pse` opened in an older
  build renders an opaque surface, visible and wrong, never invisible.
- **Colour.** Metallic is reflection tint plus roughness on whatever colour
  the user set; a rainbow cartoon in `metallic` stays a rainbow.
- **Lighting.** Matte materials look right only with a softer rig. Bundles
  that set colour, material and lighting explicitly ship as a new module
  `pymol.materials` (`materials.marble("obj")`, `materials.clay(...)`,
  `materials.copper(...)`, `materials.gold(...)`), registered in the menus
  (`menu.py` and the Inspector's preset list). The dropdown applies only the
  material; a "Suggested lighting" button beside it runs the bundle.
- **Peel.** Glass-family materials set `wantsPeel`; peeling is per object
  (§4.5) and never a global rule.

### 3.3 Material table (v1)

| Material | Family | Look | Reps | Notes |
|---|---|---|---|---|
| `default` | default | today's two-light model + `metal_rt_reflect*` | all | byte-identical |
| `matte` | procedural | Lambert only, no specular, no grain | all | the "kill the highlights" look users ask for first |
| `plastic` | reflective | glossy lacquer: env-map specular, F0 0.25, rough 0.15 | all | traced reflections replace the env term when RT is on |
| `metallic` | reflective | satin metal: F0 0.6, tint 0.35, rough 0.35 | all | reflection tinted by base colour |
| `glass` | glass | clear glass: refraction of the opaque scene, Fresnel rim, sharp highlight | cartoon, surface, sticks without `stick_ball` (else `default`); spheres `default` | implied alpha 0.15; peel |
| `frosted_glass` | glass | etched glass, 12-tap frosted refraction (capped in the live view) | same | implied alpha 0.2; peel |
| `jelly` | glass | wet-glossy translucent gummy | same | implied alpha 0.85 [^jelly-alpha]; peel |
| `marble` | procedural | matte statuary marble, faint grey veins, waxy wrap | all | veins derived from base; `materials.marble()` adds the light rig |
| `clay` | procedural | dead-matte ceramic with grazing darkening | all | `materials.clay()` adds strong wide AO |
| `rubber` | procedural | matte grainy rubber with velvet sheen | all | grain 0.14 at 14 /Å |

Each row carries an `implemented` flag; `_cmd.get_material_names()` returns
only implemented ids, so the dropdown grows wave by wave instead of listing
looks that cannot draw yet. Dropped from v1 and why: `copper`/`steel`/`gold`/
`chrome` are `metallic` plus a colour (return as `materials.*` bundles);
`porcelain` whitens the base; `iridescent` replaces hue with view angle;
`brushed_metal` has no ribbon tangent; `wax` is a global composite mode with
per-primitive knobs unbuilt.

Fallbacks without ray tracing: the reflective family uses env-map specular
only; nothing else changes.

### 3.4 CPU ray tracer

`ray` maps materials at ray time to `p->wobble` modes (marble → swirl, clay
and rubber → matte) and to specular/reflect knobs, best effort. Known limits:
one `WobbleParam` triple per render, and precedence against a user's own
`ray_texture` is "explicit `ray_texture` wins". No setting is written.

## 4. Architecture

### 4.1 Settings and resolution

- `SettingInfo.h`, one block from index 838 in the first settings PR:
  `cartoon_material`, `surface_material`, `stick_material`, `sphere_material`
  (`object`, int, 0), `material_default` (global int), `material_env` (global
  int: 0 background, 1 studio, 2 none), `transparency_peel` (`object` int:
  -1 auto-from-material, 0 off, 1 on). Declaring all seven at once keeps later
  scene-capture work independent of shader issues. The index-collision test
  guards duplicates.

  **Reserved-block decision (recorded in M1a, 2026-09-24): no.** RayMol's own
  settings continue contiguously from the end of the upstream table — 838–844
  here, after 800–837. A reserved high block (say 2000+) was considered as
  insurance against an upstream PyMOL release claiming the same indices in a
  future merge, and rejected. It cannot rescue the settings already shipped at
  800–837, because a `.pse` stores the *index* and moving one silently
  reinterprets old files. It would leave the table sparse, and
  `SettingAsPyList` walks `cSetting_INIT` entries, so the gap is paid on every
  session save. And the risk it insures against is already covered:
  `material_settings.py` and `metal_rt_reflect.py` assert exact indices and
  whole-table uniqueness, so an upstream collision fails CI at merge time
  instead of corrupting sessions quietly. If that day comes, what moves is the
  *upstream* newcomer, or a RayMol setting that has never shipped — never one
  that has.
- `layer1/Material.cpp` (new): the material table as data (`id, name,
  family, implemented, MaterialParams, impliedAlpha`), `MaterialLookup`,
  `MaterialNames`, `MaterialResolve(id, repType)`, `MaterialImpliedAlpha(id)`.
- `CGOGL.cpp`: the per-draw hook reads the rep-specific setting by
  `I->rep->type()`, resolves, and calls `Renderer::setRepMaterial(const
  MaterialParams&)` **on every lit draw** so no state leaks between draws.
  `stick_ball` spheres are emitted by the stick rep and take `stick_material`.

### 4.2 `MaterialParams` / `MaterialU`

One plain struct on both sides: `int family; int mode; float reflect, tint,
rough; float p[6]; int wantsPeel;` plus the object's inverse modelview so
impostor shaders can evaluate procedural patterns in true model space (the
prototype's rotation-only trick makes grain swim under pan and zoom). Floats
and ints only, `static_assert` on size, bound at a fragment buffer index above
every existing use, neutral default bound when each encoder is created.

### 4.3 Shader organisation

- One shared MSL block `kMaterialSrc` (noise, marble, clay, matte, rubber,
  glass skin and body, the environment sampler, the specular roll-off)
  prepended to the lit VBO, sphere and cylinder libraries. The lit VBO source
  becomes a named literal so the existing shader-source guard test sees it;
  the bezier-tube library is out of scope (no v1 rep uses it).
- Pipelines are specialised by **family with function constants** (default /
  procedural / reflective / glass) crossed with variant (opaque / OIT /
  colour-less / shadow) and sample count. The default family compiles to
  today's code. Five caches are touched: the prebuilt lit VBO singletons, the
  OIT VBO singletons, `cachedVBOPipeline`, the sphere pipeline set and the
  per-layout cylinder set. The four libraries are retained as ivars so
  specialised functions can be created later; specialised pipelines are built
  asynchronously (draw with `default` until ready) or prewarmed when the
  setting changes, so a material pick does not hitch.

### 4.4 Reflective family and environment

- **One environment.** A small eye-space cubemap (six 128 px RGBA16F faces,
  mipmapped) generated when `bg_rgb` or `material_env` changes, bound on the
  scene, OIT and RT-composite encoders. It replaces the three hand-written
  studios in the prototype (glass, cylinder glass, RT miss colour) so glass
  and metal beside each other reflect the same room and toggling ray tracing
  does not change the reflection.
- Base: GGX specular against that cubemap in the forward shaders, on every
  GPU. Upgrade: with `metal_raytrace` on, the traced reflection (per-occurrence
  material table beside the acceleration structure, primary-ray material and
  barycentric-normal lookup, from the prototype) replaces the environment term,
  feathered at depth edges with the test the composite already computes for the
  AO blur so the crossover does not pop.
- **Specular roll-off**, not a clamp: a shared soft knee (Reinhard-style,
  knee 0.8) applied to the specular-plus-reflection term in both the forward
  shaders and the composite mix, since the 8-bit target already hard-clips
  and the artefact is hue-shifting flat white.
- AO on the diffuse term alone is not claimed (needs a G-buffer, v2).

### 4.5 Transparency

- Glass-family materials **stay inside weighted-blended OIT** in v1 and
  refract the resolved opaque colour, which is the pre-post-process image:
  the interior seen through glass lacks AO, fog and shadows relative to the
  exterior, and objects with traced reflections lose part of them. Glass
  coverage defaults below 1 so the resolve mixes the post-processed image
  back in. Both limits are documented; moving glass after the composite is v2
  with the constraints in §8.
- **Peel is per object and needs a scene-level loop.** `SceneRenderMetal`
  iterates transparent objects: for each with peel on (`transparency_peel`,
  or auto and a glass-family material on any layer), it runs a colour-less
  pre-pass for that object into a copy of the opaque depth, then that object's
  OIT draws depth-tested against it; remaining transparent objects render in
  one plain OIT pass. The OIT descriptors clear accumulation and reveal only on
  the frame's first transparent encoder and load thereafter; the pre-pass has
  its own descriptor with zero colour attachments. A cap peels the first K
  flagged objects (K = 8) and the rest fall back, since each peeled object
  costs a depth blit and two encoder boundaries per grid cell.
- **Colour-less, not free.** Impostors derive depth in the fragment shader,
  so the pre-pass reuses the existing shadow fragment functions with the
  camera projection and a `depthOnly` early return right after the
  intersection; cartoon and surface use the existing VBO shadow fragment.
- `stick_ball` sticks with a glass-family material render as `default` (the
  ball spheres have no glass path and would float as near-invisible discs);
  the Inspector says so. Ball-and-stick peel is a per-object toggle, written
  by the Inspector's ball-and-stick control, not a per-frame atom scan.

### 4.6 Inspector

- OBJDETAIL already carries a per-rep string channel (used for colours) and
  `RepProperty` has an options list; the `Material` dropdown is a new `.menu`
  kind delivering names once and ints per rep. Own small piece of the first
  UI issue.
- Style-layer row: `Material` dropdown from `_cmd.get_material_names()`,
  `default` first; a `Suggested lighting` button when a bundle exists; an
  "object-wide" affordance where transparency rows show the per-atom badge.
- Object header row: a single `Peel transparency` toggle (object-scoped
  setting), and the legacy `metal_rt_reflect*` sliders collapsed into one
  "Reflection (legacy, object-wide)" group, disabled with an explanation once
  every active rep has a non-default material.
- Scene panel: `Material default`, `Environment`.
- Every write goes through the existing `set <setting>, <value>, <obj>`
  command path, so it is scriptable and logged.

### 4.7 Scenes, sessions, animation

- `raymol_scenes` captures and applies globals only; object-scoped settings
  (including `metal_rt_reflect*` today) are captured wrongly. Fix first:
  capture per object from `cmd.get_object_settings` (explicitly set entries
  only, so globals are not baked into objects), apply with the object argument
  and **unset** entries an object does not have in the scene (the
  `_apply_ttt` reset pattern), and migrate the flat payload in existing `.pse`
  files on `session_restore`. Then add the seven material settings.
- Material ids step at scene cuts; nothing to interpolate in v1.

## 5. Issue breakdown

Tracking issue: **Materials: per-representation surface materials
(tracking)**, labels `enhancement`, `tier-1`, `materials`. Every issue's
done-when includes "the new test file is listed in
`.github/workflows/raymol-embedded-tests.yml`" where CI-testable, and "leaves
the app shippable". Manual gates reference two checklists written once in the
tracking issue: **A** (iOS device and simulator build plus shader compile) and
**B** (gallery regeneration and review).

| Id | Title | Depends on | Size |
|---|---|---|---|
| M0 | Land the RT self-reflection prototype: settings 833–837, per-occurrence material table, primary-ray material lookup; register `metal_rt_reflect.py` in CI (no peel, no jelly, no knob fields) | – | M |
| M13a | Per-object setting capture in scenes via `get_object_settings`, unset-on-apply, payload migration (fixes `metal_rt_reflect*` today) | – | M |
| M1a | Seven settings in one block from 838; index guard; C-side selection rejection; `SettingGetTextPtr` names; `default` bypass test; reserved-block decision recorded in §4.1 | M0 | S |
| M1b | `MaterialParams`/`MaterialU` + inverse modelview; per-rep resolution on every Metal lit draw; neutral binding | M1a | M |
| M2 | `Material.cpp` table with `implemented` flag and implied alpha; `_cmd.get_material_names()`; Python name→id; error lists names; names↔table CI test; `cRepInvColor` invalidation | M1b | M |
| M4 | `kMaterialSrc`, family function constants across the five caches, retained libraries, async build; `matte`, `marble`, `clay`, `rubber` on all four reps; named VBO literal + guard | M2 | L |
| M10 | Per-object peel: scene loop, first-encoder clear, zero-colour pre-pass descriptor, colour-less impostor paths, cap K; `transparency_peel`; grid test | M1b | M |
| M13b | Seven material settings in scenes; `.pse` round-trip test | M13a, M2 | S |
| M12 | Inspector: `.menu` kind + Material dropdown on style-layer rows, "object-wide" affordance — **first visible win** | M2, M4 | M |
| M3a | `pymol.materials` module: `marble`, `clay` light rigs; menu registration | M2, M4 | S |
| M15a | Checklist A: iOS build + shader compile for the material libraries | M4 | S |
| M11 | Eye-space environment cubemap, `material_env`, regeneration on change, one sampler in `kMaterialSrc`; env-map GGX in forward shaders | M4 | M |
| M5 | `plastic`, `metallic`; traced term as upgrade with edge feathering; specular roll-off in both paths | M11 | M |
| M6 | `glass`, `frosted_glass` inside OIT; implied alpha at rep build; coverage default; `stick_ball` rule | M4, M10 | M |
| M7 | `jelly` on cartoon, surface, sticks | M6 | S |
| M3b | `pymol.materials`: `copper`, `gold`, `steel`, `chrome` (colour + `metallic`) | M3a, M5 | S |
| M12c | Inspector: Suggested-lighting button, object-header peel toggle, legacy reflection group, Scene default + Environment | M12, M5, M6, M11 | M |
| M8 | CPU `ray` mapping to wobble modes + knobs; headless test: each mapped material differs from `default` | M2, M7 | S |
| M14 | Docs (settings reference, limits, deprecated `metal_rt_reflect*`), gallery script + Checklist B, release notes | M7, M12c | S |
| M15b | Performance pass with named targets (frames/s at stated resolution on a named Mac and iPhone, frosted glass on a ~3k-atom surface); live-view caps; Checklist A re-run | M15a, M7 | M |
| M17 | Remove `RAYMOL_*` material env vars: zero `getenv` under `layerGraphics/metal` | M7 | S |

**Waves:** {M0, M13a} → {M1a} → {M1b} → {M2} → {M4, M10, M13b} → {M12, M3a,
M15a, M11} → {M5, M6} → {M7, M3b, M12c} → {M8, M14, M15b, M17}.

**Critical path:** M0 → M1a → M1b → M2 → M4 → M12: six PRs, ending in a
dropdown offering `matte`, `marble`, `clay` and `rubber` with their light
rigs on every GPU, no ray tracing required.

## 6. Verification

- **CI gates (Python, runs today):** names ↔ table including the
  `implemented` flag; set-time validation; selection-scoped set rejected via
  `_cmd.set`; per-rep override beats global; `.pse` round-trip; per-object
  scene capture with unset-on-apply; index guard; shader-source guards for
  `kMaterialSrc` in the three libraries; each new test file present in the
  workflow allowlist; `ray` headless differs-from-default per mapped material.
- **Local, not a merge gate:** `default` byte-exact against master via the
  headless export path; Checklist B gallery review including an orbit-and-zoom
  sweep to confirm procedural patterns stay locked to the object; the peel
  export (translucent ball-and-stick, low colour variance inside a stick);
  the Inspector XCTest.
- Frost and RT looks are noisy by construction (hash-rotated taps, Monte
  Carlo); no pixel tolerance gate for them.

## 7. Risks

- 8-bit chain: bright metallic highlights hue-shift; the roll-off mitigates,
  HDR is its own epic.
- Glass interior lacks AO/fog/shadow relative to the exterior (v1 limit).
- Per-object peel multiplies encoders by grid cells; cap K.
- Pipeline explosion: family × variant × sample count across five caches;
  async creation avoids hitches but needs care around the first frames.
- iOS verified by hand (no Xcode job in CI); frost taps and cubemap sampling
  measured on device in M15b.
- Legacy `metal_rt_reflect*` sliders are object-scoped but shown per rep
  today; M12c collapses them.

## 8. Deferred (v2 candidates)

- **HDR colour chain** (RGBA16F targets, tonemapped or Karis-weighted MSAA
  resolve, BGRA8 convert-and-encode for PNG capture, MetalFX scaler keyed on
  format, tile-memory go/no-go on A-series). Announced re-baseline.
- **Glass after the RT composite**: depth and coverage written for DOF,
  outline and the export alpha matte; ping-pong targets; placement right after
  the OIT resolve; per-cell scissor in grid mode; interleaving with the
  post-chain bookkeeping.
- **User-defined materials** (`material_define name, base, k=v...` saved in
  the session) with per-material knobs and Inspector sliders.
- **Value completer** for material names (parser change).
- **Wax**, **brushed metal** (RepCartoon tangent), **porcelain**,
  **iridescent**, **chrome**; **glass and jelly on sphere impostors and
  ball-and-stick**; **per-atom materials**; **AO on diffuse only** (G-buffer).

## 9. Review log

**Round 1 (rev 1 → rev 2).** String settings cannot be atom-scoped → int ids.
Presets wrote colour/transparency/lighting → pure function, implied opacity,
lighting bundles. Scene capture global-only → M13a. Knobs per object vs per
rep → deferred to named user materials. HDR breaks capture/MSAA/MetalFX and
the byte-identical promise → own epic. Glass after the composite → stays in
OIT. Reflective family gated on RT → env-map base. AO-on-diffuse needs a
G-buffer → dropped. Global auto-peel and double-shaded pre-pass → per-object
peel, colour-less pipelines. Single `MaterialU` leaks and taxes default →
unconditional hook, neutral binding, function-constant families. Pixel
baselines cannot gate → source/settings tests. Added M0, M13a, M15a, M17,
release notes; split M1, M6, M12, M15. Rejected: relocating existing
`metal_*` indices (breaks `.pse`); writing `ray_texture` (violates no-write).

**Round 2 (rev 3 → rev 4).** Rendering: implied opacity must be a rep-build
input in layer2 with invalidation, not a draw-time param; per-object peel
needs a scene loop, first-encoder-only clears and a zero-colour pre-pass
descriptor; impostor pre-pass is colour-less, not free; the radiance clamp was
a no-op on an 8-bit target → soft knee on the specular term in both paths;
marble was VBO-only and impostor model space was rotation-only → inverse
modelview in `MaterialU`, marble in the shared block; glass on ball-and-stick
leaves ghost balls → renders `default`; three studios → one eye-space cubemap
regenerated on change; five pipeline caches and retained libraries named;
tube library dropped from the guard. Settings/UX: selection rejection moved
into C (int settings would otherwise write atom-level values); id↔name in
`SettingGetTextPtr`; value completer infeasible → error lists names;
`preset.py` wrong home → `pymol.materials`; added `matte`, renamed `metal` →
`metallic`; object-header peel toggle; legacy sliders collapsed to one
object-wide group; scene capture via `get_object_settings` with unset and
migration. Delivery: M3x split so light rigs land with the dropdown;
`implemented` flag so the dropdown never lists undrawable looks; all seven
settings declared in M1a; M0 scoped and sized M; CI allowlist in done-whens;
named VBO literal for the guard; M12a+M12b merged; M8 moved last with a
headless test; concrete done-whens for M1a, M4, M15b; XCTest moved to local.
Rejected: trading `frosted_glass` for `chrome` (chrome replaces the colour
scheme and fails rule (a); frosted glass proved distinct in the gallery).

## 10. Tracking-issue outline

Title **Materials: per-representation surface materials (tracking)**;
labels `enhancement`, `tier-1`, `materials`. Sections, in the style of #421:
**Summary** (noun split; `default` identical; "split into 21, in nine waves";
link to this document) · **Motivation** (§2) · **Concept model** (Material,
Family, Resolution, Implied alpha, Peel as bold-lead bullets) · **What ships
in v1** (§3.3 table, selection rule, dropped-and-why) · **The tickets**
(grouped by wave, `- [ ] #NNN — **W5** title — depends #a. Size M.`, completion
appended on the same line) · **Verification** (CI gates vs Checklists A and B
written out once) · **Found while building** (empty at open) ·
**Non-negotiables** (`default` identical; no other setting written; colour
untouched; unknown name errors at set time; every test in the CI allowlist;
each PR shippable; no `getenv` in the shipped Metal path) · **Deferred** (§8).
