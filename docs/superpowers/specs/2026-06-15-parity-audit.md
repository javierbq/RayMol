# PyMOL SwiftUI+Metal App — Parity Audit vs Vanilla PyMOL

**Date:** 2026-06-15
**Branch:** `swiftui-cross-platform`
**Method:** 8-domain parallel audit of the app code + Metal renderer against the vanilla feature surface, synthesized and adversarially fact-checked. Corrections from the accuracy pass are folded in below.

---

## Bottom line: parity splits into three layers

The app embeds the **real** PyMOL engine (full C++ core `layer0–5`/`layerGraphics` + embedded CPython 3.13) with a **Metal-only** renderer (`RendererMetal.mm` + `CGOGL.cpp`, NO_OPENGL) and a SwiftUI UI. So "parity" is not one number:

| Layer | State | Verdict |
|---|---|---|
| **Core capability** (Console-typed commands) | ~Near-complete | Selections, fitting/alignment, measurements, `alter`/`iterate`, `ramp_new`/`map_new`, `symexp`, `.pse`, `fetch`, undo/redo, scripting all work. Most "missing" is really *Console-only*. |
| **Metal rendering** (what draws) | Production-quality | All common reps + post-chain (MSAA/FXAA, shadow maps, SSAO, hardware RT AO, OIT, fog, outline). Genuine render gaps are narrow. |
| **Native UI exposure** (point-and-click) | Partial & uneven | Inspector + viewport are excellent; no settings editor, measurement/wizard UI, selection builder, save-molecule menu, or touch Edit mode. |

**Net:** high parity as a viewer and Console-driven PyMOL; partial as a full point-and-click desktop replacement. The gap is overwhelmingly **UI coverage**, not engine or rendering.

---

## Scorecard by domain

| Domain | full | partial | core-only (no UI) | missing | Verdict |
|---|--:|--:|--:|--:|---|
| Representations | 11 | 0 | ~3 | 2 | Strong — only `volume` & `slice` truly absent on Metal |
| Rendering effects | 17 | 2 | 1 | 5 | At/above desktop for real-time; gaps stereo/DOF/advanced-ray |
| Selections/color/settings | 7 | 5 | 4 | 1 | Coloring good; selection algebra & ~825 settings Console-only |
| File I/O | 13 | 3 | 3 | 7 | Common formats + session/PNG/movie export; trajectories & maps can't load; no save-molecule UI |
| Editing/building/measuring | 4 | 4 | 4 | 8 | Weakest — measurement/mutagenesis/sculpt/build Console-only or absent |
| Analysis/alignment | 14 | 0 | 6 | 2 | Good — align/contacts/symexp/ESP/area have UI; fit/super/cealign Console-only |
| GUI/UX | 33 | 8 | 9 | 11 | Excellent viewport/inspector/console; no menus for build/settings/wizards/plugins |
| Scripting/plugins/platform | 4 | 4 | 3 | 4 | Full Python API; NumPy/SciPy unbundled, stereo compiled out, no plugin system |

---

## At parity (works well)

- **All everyday representations** on Metal: cartoon (fancy helices, putty, bezier tube), surface (transparent/OIT, electrostatic ramp, interior cap), sticks/spheres (analytic impostors), ribbon, mesh, lines, dots, labels (glyph atlas), measurement dashes.
- **Rendering effects** at/above desktop GL: shadow maps, SSAO, hardware ray-traced AO, OIT transparency, MSAA+FXAA, depth-cue fog, toon outline; CPU `ray` still works.
- **Representation inspector** (per-rep color/transparency/radius/quality + Scene card) and **viewport gestures** — arguably nicer than the desktop A/S/H/L/C menus.
- **Full command language** via the Console + tab-complete.
- **Timeline/movies** (just shipped): transport bar, per-object state controls, scenes strip, movie builder (camera/state/scene loops), in-app MP4/GIF export.
- **Beyond vanilla:** SwiftUI AI ChatPanel (currently a stub).

---

## The real gaps, ranked by impact

### Native-UI gaps (biggest category — engine already supports all of it)
1. **No Settings editor** — only ~9 scene toggles + per-rep sliders surfaced; the other **~800 settings** need `set name, val` in the Console. No search/min-max/help. *(large)*
2. **No interactive measurement tool** — dashes/labels render, but no pick-driven distance/angle/dihedral workflow (Tk wizard can't run). *(medium)*
3. **No selection-algebra builder** + no New/Delete/Rename-selection UI — rich selections (`within`/`around`/`byres`/logical) need the Console. *(medium)*
4. **No save-molecule / 3D-export menu** — `cmd.save` (PDB/SDF/MOL2, glTF/STL/VRML) works from Console; export menu only PNG/MP4/GIF/PSE. *(small)*
5. **No touch path to Edit mode** — bond/torsion/coordinate editing exists in core (macOS Ctrl-drag) but touch can't express modifiers; **Shift/Ctrl modifiers aren't passed to `PyMOL_Button` even on macOS** (`modifiers=0`), so modifier-selection is broken there too. *(large)*

### Platform / build gaps (cross-cutting)
6. **No trajectory or density-map loading — on BOTH platforms.** VMD molfile plugins are `OFF` in **both** `swiftui/build_macos.sh` and `swiftui/build_ios.sh` (`-DPYMOL_VMD_PLUGINS=OFF`); the `ON` default in `appkit/CMakeLists.txt` applies only to the legacy AppKit GL executable, not this app. So **DCD/XTC/TRR/NetCDF + CCP4/MRC/DX/MTZ cannot be opened on Mac or iPad.** *(large)*
7. **NumPy/SciPy not bundled** (`Python3_NumPy_INCLUDE_DIRS=""` for both Metal builds; `_PYMOL_NUMPY` undefined; no numpy package under `deps_*`). Any numpy-importing command/script (e.g. `cealign`, weighted fits, analysis scripts) fails at runtime with `ImportError`. *(large)*

### Metal-rendering gaps (narrow)
8. **`volume` and `slice` don't render** on Metal (GL 3D-texture / texture-plane paths in `layer2/ObjectVolume.cpp` / `ObjectSlice.cpp`) — blocks cryo-EM/density isosurface. *(large)*
   - *Correction from the accuracy pass:* `ellipsoid`, `cell`, `extent` were initially flagged missing but are **likely fine** — they emit standard CGO triangle/line geometry and the Metal CGO path is rep-agnostic; they just have no per-rep UI. Only volume & slice are confirmed missing.
9. **Lighting is hardcoded** (confirmed: fixed ambient/direct/reflect/spec/shininess + two fixed lights in the inline MSL, ~`RendererMetal.mm:2562`/`3562`) — `spec_reflect`/`spec_power`/`light_count` etc. silently **no-op** on the real-time image (CPU `ray` still respects them). *(medium)*
10. No stereo/DOF/gradient-background; `bg_rgb` application on Metal flagged unconfirmed. *(low — niche on mobile)*

---

## Honest caveat on the movie feature
The transport bar plays **any multi-state object**, and on this build multi-state objects come from the **native** multi-model PDB/CIF/SDF reader (NMR ensembles) — which is what was tested. **MD trajectories (DCD/XTC/…) can't be loaded yet** (gap #6), so the playback half is done but the loader half is blocked until the molfile plugins are re-enabled.

---

## Accuracy-pass corrections (so the numbers are trustworthy)
- VMD plugins are OFF on **both** Metal builds (not iOS-only) → trajectory/map loading is a **cross-platform** gap.
- `ellipsoid`/`cell`/`extent` reclassified from "missing" to "renders, no UI" (rep-agnostic Metal CGO path). Confirmed-missing reps = **just volume & slice**.
- Invented file paths in the raw audit (`RepCell.cpp`, `RepExtent.cpp`, `RepVolume.cpp`, `RepSlice.cpp`) do not exist; real geometry lives in `CoordSet.cpp`/`ObjectMap.cpp`/`ObjectVolume.cpp`/`ObjectSlice.cpp`.
- NumPy is simply **not bundled** (no "wheel present" nuance).
- Lighting hardcode is **confirmed** (stated with confidence, not "matches default" guesswork).
- Don't trust specific commit hashes from the raw audit — a couple were fabricated/mis-transcribed; the Timeline feature actually landed as `feat(swiftui): Timeline playback + movie builder/export`.
- Omissions worth tracking later: object **grouping** (`cmd.group`), the **Preset** family (ball_and_stick/publication/pretty/technical/…), object enable/disable as distinct from per-rep show/hide, `cmd.draw`, matrix/transform ops (`transform_selection`, `matrix_copy`), scene **store** (vs recall).

---

## Suggested roadmap (highest payoff first)
1. **UI on top of the working core** *(small→medium, biggest payoff):* interactive measurement tool; save-molecule + glTF/STL export; selection builder + New/Delete/Rename selection. Converts many Console-only rows to full.
2. **Settings panel** backed by `SettingInfo.h` (searchable, typed, min/max) + promote bg color + key lighting settings into the Scene card; confirm/fix `bg_rgb` on Metal.
3. **Make hardcoded rendering real:** drive Metal shaders from spec/light settings; pass Shift/Ctrl modifiers into `PyMOL_Button`.
4. **Platform unblocks:** bundle NumPy; re-enable + validate VMD molfile plugins (trajectories + maps) on both builds — lights up MD/cryo-EM *and* completes the trajectory side of the movie feature.
5. **Remaining reps + editing:** Metal `volume`/`slice`; touch Edit-mode + atom long-press context menu.
6. **Long tail:** stereo/DOF/gradient bg, mutagenesis/sculpt UIs, plugin manager, drag-and-drop load.
