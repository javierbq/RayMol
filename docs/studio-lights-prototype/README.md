# Studio lights prototype: reference for the lighting epic

**This branch is a reference, not for merge.** It is the prototype behind the lighting epic. Read it for behaviour, numbers and working shader code, then reimplement each piece properly in its own PR. Base: `master` at 567e34310.

- Design spec with the decisions, the light model, commands, storage and the updated UI sketches: [`docs/superpowers/specs/2026-10-02-lighting-epic-design.md`](https://github.com/javierbq/RayMol/blob/7248c0a982d08c24f91f9099c3555735ad501e48/docs/superpowers/specs/2026-10-02-lighting-epic-design.md) (PR #629). Where this README and the spec disagree, the spec wins: the command is `lights`/`atmosphere`, not `studio`, and a lamp drag in the orbit plan changes orbit only. `sketches/` here are the originals from the sketch round.
- Movie-export speed-up found while profiling: issue #601, PR #602. The copy on this branch is a separate commit so the branch builds as tested.

## What it does (Metal renderer only)

- **Studio lights:** up to 6 spot lights with position, beam angle and soft edge, colour (RGB, name or kelvin), intensity, coloured highlight and distance falloff. They are added on top of PyMOL's lighting, and presets zero `direct`/`reflect`/`specular`.
- **Placement:**
  - camera-relative: `az`, `el`, `dist`, `aim`;
  - fixed to the molecule: `target=<sele>` (beam fitted to it), `highlight=<sele>` / `click=x/y` (mirror rule), `rim=<deg>`.
- **Aids:**
  - beam outlines on the geometry (`cue=1`);
  - a rig view, `studio gizmo`: CGO lines for the lamps, cones, camera, view ray and normal.
- **Per-light shadows:** up to 3 lights with `shadow=1`, each a 2048² perspective map applied to its own light only. The old whole-pixel shadow is turned off while these are active.
- **Atmosphere:** haze (forward-scattering beams, shafts from shadowed lights) and procedural dust motes that glint only inside beams and drift, wobble and twinkle. `dust_speed`; movie time during export.
- **Materials:** each material responds to the studio lights in its own way (`studio_response`).

## Build and run

```bash
bash swiftui/build_macos.sh          # C++ core (CLEAN=1 after setting-table changes)
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Debug -derivedDataPath swiftui/build_mac_dd \
  -skipPackagePluginValidation -skipMacroValidation build
# then copy RayMol.app to RayMol-<tag>.app with its own CFBundleIdentifier (see CLAUDE.md)
```

Headless renders (`PYMOL_AUTOCMD` + `PYMOL_AUTOEXPORT`, one `open -n` per image): `scripts/studio_lights/{render,placement,atmosphere,material_gallery,shadows}.py --app <app> --out <dir>`. Contact sheets: `sheet.py`, `placement_sheet.py`, `--sheet <dir>`. `RAYMOL_STUDIO_TIME=<s>` pins the dust clock.

## Command reference

| Command | Effect |
| --- | --- |
| `studio list` / `studio <preset>` | `three_point`, `softbox`, `spotlight`, `rembrandt`, `neon`, `sunset`, `underlight` |
| `studio name: field=value … \| name: …` | Custom rig. Fields: `az el dist aim beam soft int kelvin color rgb spec falloff shadow cue target highlight click rim focus` |
| `studio <light> field=value` | Adjust one light by name |
| `studio haze= dust= dust_size= scatter= seed= dust_speed=` | Air; `studio air off` |
| `studio cue on\|off`, `studio gizmo [off]` | Beam outlines; rig view |
| `studio` / `studio off` | Show the rig / restore the previous lighting |

`studio` takes the rest of the command line, so it must be the last command in a `;` chain.

## Code map

| Where | What to read it for |
| --- | --- |
| `modules/pymol/studio_lights.py` | The command, presets, `kelvin_rgb`, placement (`_resolve`, `_pick`, `_outward_normal`: mirror rule, rim rule, smoothed normal), rig view (`_gizmo`), packing (`_pack`) |
| `layer1/SceneRender.cpp` `SceneStudioLightsUpdate` | Per frame: rig to eye space (camera rig or model space), shadow slots and perspective light view-projections, air range and dust scale; `SceneStudioClock` (movie time vs wall clock) |
| `layer1/SceneRender.cpp` shadow pre-pass | One depth pass per shadowed light into an array slice; the regular key-light pass is skipped |
| `layerGraphics/metal/RendererMetal.mm` `studio_shade` / `studio_shadow` / `studio_cues` / `studio_response` / `studio_apply` | Spot-light shading, per-light shadow lookup, beam outlines, material response (in the shared `kMaterialSrc` block) |
| `layerGraphics/metal/RendererMetal.mm` `atmo_*` / `post_atmosphere` | Haze ray march and layered dust; its own pass after either post path (RT on or off), before OIT |
| `layerGraphics/metal/RendererMetal.mm` `bindStudioShadows`, `beginShadowPass` | Shadow-map array, studio shadow target, binding on every lit draw (never while a shadow pass renders) |
| `layerGraphics/metal/RendererMetal.h` `StudioU` | The uniform layout shared with MSL |
| `layerGraphics/Renderer.h` | The `setStudio*` virtuals |
| `layer1/SettingInfo.h` 882–883 | `studio_lights` (17 floats per light), `studio_atmosphere` (6 floats) |

## Shortcuts not to carry over

- **Packed float strings** in two settings, plus Python-side state. `reinitialize` desyncs them, and scenes and movies don't store the rig. Replace with a native rig model with `.pse` and scene support.
- **File-static state** in `SceneRender.cpp`, which allows only one rig per process.
- **A hand-tuned material response table**; materials should own their light response.
- **Python picking** over all atoms with an estimated normal. Use the native pick plus a hit point, or a depth and normal readback.
- **Constant redraw** while dust moves, with no idle or low-power policy.
- **Not in the CPU `ray` renderer or OpenGL; no HDR** (an 8-bit soft knee); grid mode has no shadows.

## Numbers measured on this branch

- **Shadows:** 3 shadowed lights vs none: 0.091 vs 0.090 s/frame (1080p export, Metal RT, 1,300-atom protein); 10–13% of pixels differ.
- **Beam angle:** at 3 scene radii, any beam wider than ~25° covers the whole molecule. Size beams by the lit patch, not degrees.
- **Haze when backlit:** forward scattering peaks at (1+g)/(1−g)² (13× at g = 0.65), so it is capped at 5× for haze and 8× for dust.

## Pictures

Sketches (`sketches/`): `architecture.png`, `gizmo-mockup.png`, `sketch1-mac-layout.png`, `sketch2-orbit-plan-and-pitch.png`, `sketch3-inspector.png`, `sketch4-iphone-ipad.png`, `alt-corner-lighting-ball.png` (superseded), `roadmap.png`.

Galleries (`gallery/`): presets, parameter sweeps, placement, atmosphere, `dust-drift.gif`, materials × lighting, per-light shadows.
