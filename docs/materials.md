# Materials

Colour says what something **is**; a material says what it is **made of**.
Every style layer that has a material (cartoon, surface, sticks, spheres) can
be `default`, `matte`, `plastic`, `metallic`, `glass`, `frosted_glass`,
`jelly`, `marble`, `clay` or `rubber`, independently, per object — a glass
surface over a marble cartoon with metallic sticks is one object.

- **Choosing a material never writes another setting.** It does not touch
  colour, lighting or transparency. The one side effect is the *implied
  alpha* of the glass family, which is used when the representation is
  built and is never written back as a setting (see
  [Transparency](#transparency-and-peel)).
- **`default` is today's rendering, byte for byte.** Nothing changes unless
  you pick something else.

## Quick start

In the **Inspector**, each style-layer row (Cartoon, Surface, Sticks, Spheres)
has a **Material** dropdown. When the chosen material has a look — `marble`,
`clay`, or `metallic` (copper, gold, steel, chrome) — a **Look** chip appears
beside it and applies the whole look: for marble and clay, the material plus
the lighting that flatters it; for the metals, `metallic` plus the metal's
colour and reflection settings. See [Looks](#looks-materials-plus-lighting).

From the command line:

```
set surface_material, glass, myprotein
set cartoon_material, marble, myprotein
set stick_material, metallic, ligand
set material_default, matte          # everything without its own material
get surface_material, myprotein      # -> glass
```

Or from Python:

```python
cmd.set('surface_material', 'frosted_glass', 'myprotein')
cmd.get_setting_int('surface_material', 'myprotein')   # the id; cmd.get gives the name
```

Material names are checked when you set them. An unknown name is an error,
and nothing is written:

```
set surface_material, glas, myprotein
# Error: unknown material 'glas'. Valid materials: clay, default, frosted_glass, glass, jelly, ...
```

## Settings

| Setting | Scope | Default | Meaning |
|---|---|---|---|
| `cartoon_material` | object | `default` | Material of the cartoon. |
| `surface_material` | object | `default` | Material of the molecular surface. |
| `stick_material` | object | `default` | Material of the sticks, **including** the `stick_ball` spheres the stick representation draws. |
| `sphere_material` | object | `default` | Material of the sphere representation. |
| `material_default` | global | `default` | Fallback for every representation above that has no material of its own. |
| `material_env` | global | `0` | What the reflective and glass-family materials reflect: `0` the background colour, `1` a studio, `2` nothing. |
| `metal_rt_transparent` | global | `0` | Let transparent geometry cast traced shadows and ambient occlusion and appear in traced reflections (see [Environment and ray tracing](#environment-and-ray-tracing)). |
| `transparency_peel` | object | `-1` | Keep only the nearest transparent layer of the object: `-1` auto (on for glass-family materials), `0` off, `1` on. |

**Resolution order.** Each representation takes:

1. the value set on the object (or on one of its states), **including an
   explicit `default`**, which is how one object opts out of
   `material_default`;
2. otherwise the global `*_material`, if it is not `default`;
3. otherwise `material_default`.

A global `set cartoon_material, default` therefore does *not* block
`material_default`; only the object-level one does.

**Object-scoped, never per atom.** A selection-scoped `set` of one of the four
`*_material` settings (`set cartoon_material, marble, chain A`) is rejected
with an error, and so is one of `transparency_peel`. Use separate objects to
give parts of a structure different materials. `material_default` and
`material_env` are global only: setting them on an object prints PyMOL's
usual "global-level setting" warning. The object-level value is stored (and
`get` reports it) but the renderer reads only the global one.

**`get` and logs show names.** `get`, the `Setting: … set to …` line, `.pml`
logs and the Settings panel print `marble` rather than an id. Sessions (`.pse`)
store the id. A session saved by a newer build and opened by an older one
renders an unknown id as `default`.

**Representations without a material.** Ribbon, lines, mesh, dots, labels and
the other representations keep `default` shading. `material_default` does not
reach them.

## The materials

| Material | Family | Representations | Looks like |
|---|---|---|---|
| `default` | default | all | Today's shading, unchanged. |
| `matte` | procedural | all | Lambert only: no highlight at all. |
| `plastic` | reflective | all | Glossy clear coat: a white environment reflection over the base colour. Traced reflections when ray tracing is on. |
| `metallic` | reflective | all | A stronger, rougher environment reflection, tinted by the base colour. The body and the light highlight are `default`'s, so the difference is all in what it reflects (under `ray`, see below, the body is darker and the highlight tinted). |
| `glass` | glass | cartoon, surface, sticks | Clear body (implied alpha 0.15) under a Fresnel rim, with key-light and headlight glints. |
| `frosted_glass` | glass | cartoon, surface, sticks | Glass with a blurred environment and soft, broad glints (implied alpha 0.2). |
| `jelly` | glass | all | A dense gummy body (implied alpha 0.85) with an inner glow and a wet highlight. |
| `marble` | procedural | all | Veined stone with a waxy light wrap. |
| `clay` | procedural | all | Unglazed ceramic: fine grain, darkened at grazing angles. |
| `rubber` | procedural | all | A mottled, low-sheen skin. |

**Glass on spheres and ball-and-stick.** Clear and frosted glass degrade to
`default` on the sphere representation, and on a stick representation that
draws `stick_ball` spheres: at their implied alpha a sphere reads as a
near-invisible disc. The degradation applies to the whole rep, so a
ball-and-stick is never half glass, and both the shading and the implied alpha
degrade, so the rep draws exactly as `default`. **Jelly is the exception:** it
is dense enough to read as gummy balls, so it draws on spheres and on
ball-and-stick, with its implied alpha.

**Procedural patterns are locked to the object** in the viewport. They don't
slide when you rotate, pan or zoom.

## Transparency and peel

The glass family carries an **implied alpha**: glass 0.15, frosted glass 0.2,
jelly 0.85. It is used when a representation's own transparency slider
(`transparency`, `cartoon_transparency`, `stick_transparency`,
`sphere_transparency`) is at 0. **Your
slider always wins.** Set `transparency, 0.5` on a glass surface and it is
50% transparent glass. The implied alpha is a build input and is never
written as a setting, so a session opened in a build that doesn't know `glass`
shows an opaque surface (visible and wrong) rather than an invisible one.

**Peel** keeps only the nearest transparent layer of an object. Without it, a
translucent ball-and-stick shows the front and back of every stick and the
joins inside them; with it, the object reads as one skin.

- `transparency_peel -1` (auto, the default) turns peel on for an object when
  one of its representations draws a glass-family material. Auto refuses when
  the object also has a transparent representation that did not ask for peel,
  because peel is per object and would erase that rep's back layers.
- `1` and `0` force peel on or off.
- Groups: `set transparency_peel, 1, mygroup` reaches the members.
- Up to **three** peeled objects are drawn per frame; any further ones draw
  unpeeled, so a fourth jelly object looks denser. The classic OpenGL path
  peels nothing.

## Environment and ray tracing

The reflective materials (`plastic`, `metallic`) reflect an environment
chosen by `material_env`: the background colour (0), a neutral studio (1), or
nothing (2). The glass family's Fresnel rim reflects the same environment,
blurred for `frosted_glass`, so `material_env 2` also takes the rim away.
All of this works on every GPU.

**On a dark background, pick the studio.** Under `material_env 0` the room
*is* the background, and a near-black room reflects almost nothing. Reflection
is the only thing that separates `plastic` from `metallic`, so without ray
tracing the two look alike on black. `set material_env, 1` gives them a studio
to reflect.

With **Metal ray tracing** (`metal_raytrace 1`, where supported), reflective
materials also trace real reflections of the structure itself. This is an
upgrade on top of the environment reflection, not a replacement, so turning
ray tracing off leaves the environment reflection alone.

**Transparent geometry is left out of the ray-traced scene unless you ask
for it.** By default, glass, frosted glass and jelly (like any transparent
representation) cast no traced shadow or ambient occlusion and don't appear
in other objects' reflections. `set metal_rt_transparent, 1` puts them in
(#532):

- **Shadows.** A transparent object lets through `1 - alpha` of the light, so
  jelly (alpha 0.85) casts a dark shadow and clear glass (0.15) a faint one.
  Each transparent representation counts once along a ray, so a closed glass
  shell shadows once rather than at both of its walls (an object with two
  transparent representations, such as jelly spheres and sticks, attenuates
  once for each it crosses, up to eight per ray). This needs traced shadows
  (`metal_rt_shadows`, on by default).
- **Ambient occlusion.** A transparent object occludes in proportion to its
  alpha.
- **Reflections.** A reflective material's traced reflection shows the
  nearest transparent surface, blended over what lies behind it by its alpha.
- **What it does not do.** Transparent geometry still receives no traced
  shadow or ambient occlusion itself, and it is not traced in `grid_mode`.
- **Cost.** On a scene with one 55%-transparent molecular surface it makes the
  ray-traced pass about 2.5 times slower (23 to about 57 ms per 1400×1000 export
  frame on an M1 Max), which is why it is off by default.

**Where the near clipping plane cuts into a structure, the cut face may miss
its traced reflection** (#503). The ray-traced scene deliberately ignores the
near and far clipping planes (the camera slab), so geometry clipped away by
them still casts shadows onto what remains. (Per-representation clipping such
as `surface_clip_front` is different: geometry it removes leaves the traced
scene too.) The material a pixel reflects with is found by a ray from the
camera that must land at the pixel's own depth. Inside a cut, that ray can
hit the clipped-away front geometry first, and the pixel then gets no traced
reflection; its environment reflection is unaffected. Traced ambient occlusion
falls back to a coarser surface normal there, and the clipped-away geometry
still occludes the cut. With `metal_interior_cap` on, a clipped sphere, stick
or closed surface shows a flat cap instead, and the cap is never reflective;
cartoon gets no cap. Making it reflect would mean mirroring
geometry you just clipped away.

**Glass does not refract.** It is a Fresnel rim and glints over a see-through
body. What is behind it is seen straight through, not bent.

### The CPU `ray` command

`ray` (the classic CPU ray tracer, and `png …, ray=1`) maps materials to the
knobs it has:

| Material | Under `ray` |
|---|---|
| `marble` | `ray_texture` 2 (Swirl 1) |
| `clay` | `ray_texture` 1 (Matte 1) |
| `rubber` | `ray_texture` 4 (Matte 2) |
| `frosted_glass` | `ray_texture` 1 on top of its transparency |
| `matte` | no highlight |
| `plastic` | brighter highlight |
| `metallic` | darker body, highlight tinted by the base colour |
| `glass`, `jelly` | their implied transparency |

- **An explicit `ray_texture` wins.** A value set on the object (0 included)
  or a non-zero global value beats the material's texture. The texture's
  knobs are always `ray_texture_settings`: `ray` has one set per render.
- **Known limits.**
  - `ray`'s Swirl 1 and Matte 2 are evaluated in camera space, so under `ray`
    a marble or rubber pattern slides as the camera moves (a `ray` movie
    shows it).
  - Scene exports (`save` to `.pov`, `.wrl`, `.obj`, `.dae`, `.gltf`, `.idtf`)
    carry no material knobs. Of the implied transparency:
    - `.dae` and `.gltf` carry it on every primitive;
    - `.pov` carries it on triangles only;
    - `.idtf` exports only triangles;
    - `.wrl` and `.obj` carry none.

## Looks: materials plus lighting

Some looks need more than a material. `pymol.materials` has bundles that set
the material on **all four** material-bearing representations of each object
in the selection, plus what else the look depends on: the lighting rig for
`marble` and `clay`, the colour and reflection settings for the metals. Each
function's docstring lists exactly what it writes.

```python
from pymol import materials
materials.marble('myprotein')   # marble + a soft museum rig (specular down, light wrap)
materials.clay('myprotein')     # clay + contact shadow and occlusion
materials.copper('ligand')      # metallic + copper colour + reflection overrides
materials.gold('ligand')
materials.steel('ligand')
materials.chrome('ligand')
```

- Lighting is **global** (there is one light rig), so calling two bundles in a
  row leaves the second one's lighting.
- The named metals **do** write colour, on the selection. That is what
  separates a metal look from the `metallic` material.
- `clay` and `marble` switch on screen-space shadows and occlusion
  (`metal_shadows`, `metal_ssao`), which work without ray tracing (except that
  cartoons get no occlusion: `metal_ssao_cartoon` is off by default), and set the
  ray-traced ones (`metal_rt_shadow*`, `metal_rt_ao_*`), which need
  `metal_raytrace`. The bundles deliberately don't switch that on.

In the Inspector these are the **Look** chips on a representation row, shown
when the row's material is `marble`, `clay` or `metallic` (which offers the
four metals). They rewrite all four representation materials of the object,
not just that row's.

## Legacy: `metal_rt_reflect*`

`metal_rt_reflect`, `metal_rt_reflect_tint` and `metal_rt_reflect_rough`
(object-scoped) predate materials. They set traced self-reflection directly
and still work, but **prefer a material** (`plastic` or `metallic`) or a
metal look.

How materials treat them:

- `default` and the procedural materials take the three values as they are.
- `plastic` and `metallic` use their own reflection unless the object has an
  explicit value, which then wins.
- The glass family ignores them.

The Inspector shows them in a collapsed **Reflection (legacy)** group, marked
"not in use" when every shown representation is glass. **Clear** unsets all
three.

## Scenes and sessions

Materials, `material_default`, `material_env` and `transparency_peel` are
stored in scenes and round-trip through `.pse`.

**Movies** currently replay only the global half of a scene's materials. An
object's own per-object material is not re-applied at each scene cut
(#508).

## Regenerating the gallery

`scripts/materials_gallery/` renders every material on every material-bearing
representation, on light and dark backgrounds, with Metal ray tracing off and
on, from a clean checkout (the structure is `testing/data/1rx1.pdb`):

```bash
# a built app, copied with its OWN bundle id (render.py refuses io.raymol.RayMol)
python3 scripts/materials_gallery/render.py --app /tmp/RayMol-dev.app \
    --out /tmp/materials-gallery --lock-check
python3 scripts/materials_gallery/gallery.py /tmp/materials-gallery   # needs Pillow + numpy
open /tmp/materials-gallery/index.html
```

`gallery.py` reports, for every image against the `default` image of the same
cell:

- the share of the subject that changed;
- its high-frequency detail;
- its PNG size.

It exits non-zero, and lists the cause at the top of the page, when:

- a material came out indistinguishable from `default`;
- two materials in one cell render alike;
- a material is identical with and without ray tracing;
- an image is missing or blank;
- a procedural pattern does not stay locked. The `--lock-check` pairs pan an
  orthoscopic camera and check that each pattern moves with the object.

Expected cases are declared in `manifest.json` with their reasons, and the
page labels them instead of failing:

- clear and frosted glass on spheres, which must still match `default`;
- plastic and metallic on a dark background without ray tracing;
- the glass family's ray-tracing invariance (#532; the gallery renders with
  `metal_rt_transparent` off).
