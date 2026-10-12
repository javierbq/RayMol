---
title: RayMol Settings
description: Reference guide to RayMol-specific settings for Metal rendering, materials, lighting, and surfaces.
---

RayMol introduces modern rendering and visualization settings on top of standard PyMOL. These settings configure the native Metal renderer, physically-based materials, studio lighting, depth of field, real-time ray tracing, and surface slicing.

Standard PyMOL settings operate as described in the [PyMOL documentation](https://pymolwiki.org/index.php/Settings). RayMol settings use the same `set` and `get` command interfaces, but include features tailored to Apple Silicon GPUs on macOS, iPadOS, and iOS.

## Managing settings

Settings in RayMol can be set globally, or scoped to a specific object or molecular state where supported.

### Setting values

```text
# Global setting
set metal_raytrace, 1
set metal_exposure, 1.2

# Object-scoped setting
set surface_material, glass, my_protein
set transparency_peel, 1, my_protein
set surface_clip_front, 0.4, my_protein
```

In Python scripts or the embedded console:

```python
from pymol import cmd

# Global setting
cmd.set("metal_raytrace", 1)
cmd.set("metal_exposure", 1.2)

# Object-scoped setting
cmd.set("surface_material", "glass", "my_protein")
cmd.set("transparency_peel", 1, "my_protein")
```

### Inspecting values

Use `get` in the console or Python:

```text
get metal_raytrace
get surface_material, my_protein
```

```python
# Query settings via Python
is_rt = cmd.get("metal_raytrace")
exposure = cmd.get("metal_exposure")
material_name = cmd.get("surface_material", "my_protein")
```

:::note
Settings marked with **object** scope can be assigned to individual objects without affecting other loaded structures. Set without an object name, the value applies to every object that has no value of its own — including objects already loaded. Settings marked with **global** scope apply to the entire scene and viewer window.
:::

---

## Materials & Shading

RayMol supports physically-modelled materials across all major structural representations. For details on visual tuning, see [Materials and Looks](/RayMol/reference/commands/#materials).

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `cartoon_material` | string / int | `default` | Object | Material for cartoon representations (`matte`, `plastic`, `metallic`, `glass`, `frosted_glass`, `jelly`, `marble`, `clay`, `rubber`). |
| `surface_material` | string / int | `default` | Object | Material for molecular surface representations. |
| `stick_material` | string / int | `default` | Object | Material for stick representations, including bond joints and `stick_ball` spheres. |
| `sphere_material` | string / int | `default` | Object | Material for space-filling CPK sphere representations. |
| `material_default` | string / int | `default` | Global | Fallback material applied to any representation without an explicit material. |
| `material_env` | integer | `0` | Global | Environment reflection source: `0` = background color, `1` = neutral studio, `2` = none. |
| `transparency_peel` | integer | `-1` | Object | Depth-peeling for translucent geometry: `-1` (auto for glass), `0` (disabled), `1` (show nearest transparent layer only). |
| `metal_rt_transparent` | boolean | `off` | Global | Traces transparent geometry through ray tracing so glass and jelly cast soft shadows, AO, and appear in reflections. |

### Custom material knobs

Each representation (`cartoon`, `surface`, `stick`, `sphere`) supports fine-tuning of material parameters per object via `<rep>_material_<knob>`. Each material reads only the knobs its shader implements; an override of any other knob is ignored. Unsetting a knob (`unset`) or clicking Reset restores the material's values; picking any material from the Inspector clears the tuning.

| Setting Pattern | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `<rep>_material_reflect` | float | unset (the material's own value) | Object | Specular reflection multiplier (read only by `plastic` and `metallic`). |
| `<rep>_material_tint` | float | unset (the material's own value) | Object | Specular reflection tint toward the underlying atom color (read only by `plastic` and `metallic`). |
| `<rep>_material_rough` | float | unset (the material's own value) | Object | Roughness on `plastic`, `metallic`, and `glass`; Frost on `frosted_glass`; skin-reflection blur on `jelly`. |
| `<rep>_material_knob1` | float | unset (the material's own value) | Object | Material-specific knob 1 (see table below). |
| `<rep>_material_knob2` | float | unset (the material's own value) | Object | Material-specific knob 2 (see table below). |
| `<rep>_material_knob3` | float | unset (the material's own value) | Object | Material-specific knob 3 (see table below). |
| `<rep>_material_knob4` | float | unset (the material's own value) | Object | Material-specific knob 4 (see table below). |
| `<rep>_material_knob5` | float | unset (the material's own value) | Object | Material-specific knob 5 (see table below). |
| `<rep>_material_knob6` | float | unset (the material's own value) | Object | Material-specific knob 6 (see table below). |

#### Knobs by Material

| Material | Knobs |
| :--- | :--- |
| `plastic` | `reflect` Reflection, `tint` Reflection tint, `rough` Roughness |
| `metallic` | `reflect` Reflection, `tint` Reflection tint, `rough` Roughness |
| `glass` | `knob1` Reflection, `knob2` Distortion, `rough` Roughness |
| `frosted_glass` | `knob1` Reflection, `knob2` Distortion, `rough` Frost |
| `jelly` | `rough` Skin reflection blur, `knob1` Absorption, `knob2` Inner glow, `knob3` Wet highlight, `knob4` Distortion |
| `matte` | `knob1` Grain, `knob2` Grain frequency |
| `clay` | `knob1` Grain, `knob2` Grain frequency, `knob3` Edge darkening |
| `rubber` | `knob1` Grain, `knob2` Grain frequency, `knob3` Highlight, `knob4` Sheen |
| `marble` | `knob2` Vein scale, `knob5` Vein contrast, `knob6` Vein sharpness |

---

## Real-Time Ray Tracing

RayMol features an interactive Metal hardware ray tracing pipeline that calculates real-time ambient occlusion and directional contact shadows.

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `metal_raytrace` | boolean | `on` | Global | Toggles hardware ray-traced ambient occlusion and shadows in the live viewport. |
| `metal_rt_samples` | integer | `32` | Global | Number of ambient occlusion rays traced per pixel in live view (`1`–`256`). Exports use at least 48. |
| `metal_rt_scale` | float | `0.5` | Global | Live viewport resolution scale for ray tracing (`0.25`–`1.0`); depth-guided filters reconstruct full resolution. |
| `metal_rt_ao_radius` | float | `5.0` | Global | Hemisphere search radius for ambient occlusion in Angstroms (cavity/pocket reach). |
| `metal_rt_ao_intensity` | float | `0.72` | Global | Darkness intensity scaling factor for ray-traced ambient occlusion (`0.0`–`1.0`). |
| `metal_rt_shadows` | boolean | `on` | Global | Traces hard shadow rays against scene geometry instead of shadow-map PCF lookups. |
| `metal_rt_shadow_intensity` | float | `0.45` | Global | Darkness intensity multiplier for cast directional shadows (`0.0`–`1.0`). |
| `metal_temporal_ao` | boolean | `on` | Global | Accumulates ray-traced ambient occlusion across consecutive still frames to eliminate noise. |
| `metal_rt_reflect_env` | boolean | `on` | Global | Traced reflection rays missing the structure reflect the studio environment rather than the solid background. |
| `metal_rt_reflect_samples` | integer | `8` | Global | Reflection sample count per pixel for rough materials in offscreen renders (`1`–`64`). |

---

## Lighting & Post-Processing

These settings control directional lighting, ambient occlusion, outlines, exposure, and tone reproduction in the Metal viewport.

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `metal_shadows` | boolean | `on` | Global | Screen-space directional shadows. |
| `metal_shadow_bias` | float | `1.0` | Global | Multiplier on shadow depth bias (raise to `2.0`–`4.0` if flat cartoon ribbons show self-shadow acne). |
| `metal_ssao` | boolean | `on` | Global | Screen-space ambient occlusion (SSAO) for crease and contact darkening. |
| `metal_ssao_cartoon` | boolean | `off` | Global | Include cartoon geometry in SSAO pass (disabled by default to prevent false seams along ribbons). |
| `metal_outline` | boolean | `off` | Global | Full-scene silhouette and toon outline post-process filter. |
| `metal_outline_color` | color | `0x000000` | Global | Color of the silhouette contour line. |
| `metal_outline_width` | float | `1.4` | Global | Silhouette line thickness in screen pixels. |
| `metal_tonemap` | boolean | `off` | Global | Filmic ACES tone mapping and contrast curve. |
| `metal_exposure` | float | `1.0` | Global | Exposure multiplier for tone mapping and studio lighting rigs (`1.0` = neutral). |
| `metal_sss_wrap` | float | `0.0` | Global | Diffuse lighting wrap-around parameter for soft, waxy subsurface appearance (`0.0` = pure Lambert). |
| `metal_msaa` | boolean | `on` | Global | 4x multisample anti-aliasing in the opaque scene pass (the transparency and post-process passes stay single-sample). |
| `metal_upscale` | boolean | `off` | Global | Renders scene at lower resolution and upscales to native display resolution for battery or GPU savings. |

---

## Depth of Field (DOF)

RayMol provides a camera depth-of-field post-processing filter that produces photographic bokeh blur based on distance from the focal plane.

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `metal_dof` | boolean | `off` | Global | Toggles camera depth-of-field post-processing. |
| `metal_dof_focus` | float | `0.0` | Global | Focal-plane distance from the camera in eye-space units (`0.0` auto-focuses on the center of interest). |
| `metal_dof_range` | float | `14.0` | Global | Depth range around the focal plane before blur saturates at maximum. |
| `metal_dof_aperture` | float | `14.0` | Global | Aperture size governing maximum circle-of-confusion blur radius in pixels (`0.0` disables blur). |
| `metal_dof_quality` | integer | `4` | Global | Bokeh quality level from `1` (fast 16-sample single-pass) to `4` (96-sample two-pass gather with denoising). |
| `metal_dof_hq` | boolean | `off` | Global | Enables two-pass high-quality bokeh with an additional smoothing and denoising step. |
| `metal_dof_autofocus` | boolean | `off` | Global | Continuously recalculates focal distance to track the centroid of the `dof_focus` selection. |

---

## Studio Light Rig & Atmosphere

These settings govern the multi-light studio rig and atmospheric volumetric rendering configured via the `lights` and `atmosphere` commands.

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `metal_light_hdr` | integer | `0` | Global | Studio rig dynamic range handling: `0` (platform default — HDR on), `1` (HDR on: exposure plus a white-point tone curve), `2` (HDR off: the legacy 8-bit soft knee). |
| `metal_light_shadow_size` | integer | `0` | Global | Shadow map resolution per light: `0` (platform default: 2048 macOS / 1024 iOS), or `256`–`4096` (`256`–`2048` on iOS). |
| `metal_light_air_resolution` | integer | `0` | Global | Haze and dust volumetric pass resolution: `0` (platform default / half), `1` (full), `2` (half). |
| `metal_light_air_time` | float | `-1.0` | Global | Atmosphere dust clock: `< 0.0` follows live/movie clock; `>= 0.0` pins time in seconds for reproducible renders. |
| `metal_light_air_phase` | float | `0.0` | Global | Time offset added to dust animation during movie playback to prevent jumps across scene transitions. |
| `metal_light_air_shadow_filter` | integer | `0` | Global | Haze shadow evaluation quality: `0` (default 1-tap), `1` (hardware comparison), `2` (3×3 PCF filter). |
| `metal_light_air_alpha` | integer | `0` | Global | Retains haze/dust luminance in alpha channel during transparent exports (`0` = cutout background, `1` = retain air). |

---

## Geometry, Surfaces & Slicing

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `cartoon_spline` | boolean | `on` | Object / State | Natural cubic spline interpolation through Cα atoms with smooth twist frames (`off` uses classic Hermite blend). |
| `metal_interior_cap` | boolean | `off` | Object | Fills the open cross-section of clipped sticks and spheres with a solid flat interior cap. |
| `surface_clip_front` | float | `0.0` | Object | Fraction (`0.0`–`1.0`) of depth shaved off the front side of a molecular surface relative to its center of mass. |
| `surface_clip_back` | float | `0.0` | Object | Fraction (`0.0`–`1.0`) of depth shaved off the back side of a molecular surface relative to its center of mass. |
| `surface_contour` | boolean | `off` | Object | Draws a crisp silhouette contour line along the outer boundary of molecular surfaces. |
| `surface_contour_width` | float | `2.0` | Object | Width of the outer surface contour line in pixels. |
| `surface_contour_color` | color | `-1` | Object | Color of the surface contour line (`-1` inherits surface color). |
| `surface_contour_opaque` | boolean | `on` | Object | Keeps surface contour line fully opaque even when the underlying surface is translucent. |

:::tip Slicing surfaces to inspect interiors
Combining `surface_clip_front` on a molecular surface while leaving cartoon and stick representations whole allows you to peek inside binding pockets while keeping the cartoon backbone intact:

```text
show surface, my_protein
show cartoon, my_protein
set surface_clip_front, 0.45, my_protein
```
:::

---

## Multi-Object Display & Diagnostics

| Setting | Type | Default | Scope | Description |
| :--- | :--- | :--- | :--- | :--- |
| `grid_mode` | integer | `0` | Global | Standard PyMOL setting, listed because the Metal viewport honours it per cell. Toggles tiled grid view: `0` (off), `1` (by object), `2` (by state), `3` (both). |
| `metal_gpu_timing` | integer | `0` | Global | GPU timing diagnostics logged to console: `0` (off), `1` (one-second summary window), `2` (per-frame statistics). |
