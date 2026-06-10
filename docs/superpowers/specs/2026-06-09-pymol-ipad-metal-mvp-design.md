# PyMOL on iPad (Metal) — MVP Design

- **Date:** 2026-06-09
- **Branch:** `swiftui-cross-platform`
- **Status:** Approved design — ready for implementation planning
- **Scope of this round:** MVP on the **iOS Simulator** only

## 1. Background & context

`master` (this fork; tip `50b5e751`) is already a **working macOS-native PyMOL with a real Metal
rendering backend**. The git history (`eaef9e72 feat: Metal VBO rendering — molecules visible`,
`98f04686 feat: Metal renders molecules!`, `9d124c7c feat: selection indicators and atom picking
for Metal backend`), 22 shaders in `data/shaders_metal/`, and a built `build_appkit/PyMOL.app`
confirm that PyMOL's actual molecular geometry (cartoons, sticks, surfaces) renders through Metal —
**not** a CPU-image/raytrace-to-texture scheme. Rendering flows CGO → VBO → `MTLBuffer` with MSL
shaders, driven by `SceneRenderMetal`.

The `swiftui-cross-platform` branch **extends that proven macOS Metal app to iPadOS**. The
expensive, risky graphics work is therefore already done. What remains for iPad is largely
mechanical platform glue.

### Reference implementation (the template)
The macOS AppKit host `layer5/main_appkit.mm` is the working reference for everything the iOS
host must do:
- **Per-frame drawable handoff + frame lifecycle:** `main_appkit.mm:805–869`
  (`setDrawable` at `:818`; `viewport`/`beginFrame`/`endFrame` around `:840–868`).
- **Python boot:** `main_appkit.mm:1216–1277` (inittab `_cmd` at `:1224`, modern `PyConfig`,
  `PyConfig.home`/PYTHONHOME at `:1239–1243`, `init_cmd()` at `:1254`, `sys.path` at `:1257–1271`,
  `PYMOL_PATH`/`PYMOL_DATA` env at `:1274–1276`).
- **Resource bundling (macOS CMake):** `appkit/CMakeLists.txt:340–347` copy `data/`+`modules/`,
  `:349–353` compile `pymol.metallib`, `:334–338` copy `_champ.so` — all inside `if(NOT PYMOL_IOS)`.

## 2. Current state of the iPad port (assessment)

**Working / done on this branch:**
- **Core compiles & links for the iOS Simulator.** `build_ios/libpymol_core.a` is confirmed
  iOS-sim arm64 (Mach-O platform 7, min iOS 16) with the Metal renderer compiled in and OpenGL
  fully stubbed out: `_PYMOL_NO_OPENGL` (~459 lines of no-op `gl*` shims in `layer0/os_gl.h`),
  `layerGraphics/gl/GLVertexBuffer_stubs.cpp` retains CPU vertex data for Metal, and there are
  **zero unresolved `gl*` symbols**. `_PYMOL_NO_OPENGL` auto-defines `PURE_OPENGL_ES_2` +
  `_PYMOL_NO_MAIN` (`layer0/os_predef.h`).
- **Dependencies cross-compiled for iOS sim:** `deps_ios/install/lib/libfreetype.a`,
  `libpng.a` (both iOS-sim arm64); BeeWare `deps_ios/Python.xcframework` (Python **3.13**,
  device + simulator slices, full stdlib). `deps_ios/VERSIONS` documents the BeeWare build.
- **iOS build system:** `appkit/ios.toolchain.cmake`, `appkit/CMakeLists_iOS.cmake`
  (forces `PYMOL_IOS=ON`, libxml/vmd/msgpack OFF), `swiftui/build_ios.sh` (builds the static lib
  only; defaults to simulator).
- **Cross-platform SwiftUI UI** (`swiftui/PyMOLViewer/`): `ContentView` has a full iPad `TabView`
  layout; `MetalViewport` has a UIKit touch-gesture path; `CommandPanel`, `MousePanel`,
  `ObjectPanel` are wired to PyMOL via `PyMOLBridge_*` and a 100 ms polling engine
  (`PyMOLEngine.swift`).

**Blockers / gaps (this is the MVP work):**
1. **Render wiring (nothing reaches the screen).** `MetalViewport.draw(in:)`
   (`MetalViewport.swift:129`) fetches `currentDrawable` + `currentRenderPassDescriptor`
   (`:132–133`) but never hands them to the renderer (`:138–139` is the gap). There is **no**
   `SetDrawable` bridge function (`PyMOLBridge.h` exposes only `RenderMetal`), and
   `beginFrame`/`viewport`/`endFrame` are never called from Swift. Consequently
   `RendererMetal::ensureEncoder()` bails with no drawable (`RendererMetal.mm:260–261`) and
   `isRenderReady()` is false (`:1074–1077`).
2. **Packaging (the app can't launch).** The Xcode project (`swiftui/.../project.pbxproj`,
   generated from `swiftui/project.yml`) has **only a Sources build phase** — no Embed-Frameworks,
   no resource copy. So `Python.framework` is linked but not embedded (dyld fails), `modules/` and
   `data/` (incl. `shaders_metal/`) are not bundled, and no metallib is provided.
   `PyMOLBridge_InitPython` (`PyMOLBridge.mm:52–81`) uses the old `Py_Initialize()` and **never
   sets `PyConfig.home`/PYTHONHOME**; iOS has no system Python.
3. **iOS compile errors (small).** `CommandPanel.swift` and `MetalViewport.swift` use UIKit types
   (`UITextField`, `UIColor`, `UIKeyCommand`, `UI*GestureRecognizer`) without `import UIKit`.

**Secondary (out of scope this round, see §4):** Metal atom-pick hit-testing — CGO draw ops
early-return on `isPicking` (`layer1/CGOGL.cpp:578,671,760`); iPad input has no modifier mapping
(`MetalViewport.swift:159–165`) and an empty two-finger rotate (`:280–283`); `SequencePanel` shows
hardcoded data; `ChatPanel` is a canned stub (no AI); no numpy; simulator slice only.

## 3. Goal — definition of done (MVP)

On the **iOS Simulator**, the PyMOLViewer app:
1. Builds and links cleanly for `iphonesimulator`.
2. Launches with a working embedded Python; the Command panel runs a command and returns real
   feedback.
3. Renders a real structure via Metal: `load 1ubq.cif; hide everything; show cartoon` shows a
   cartoon in the viewport.
4. Responds to basic touch: one-finger drag rotates, pinch zooms, two-finger pan translates; the
   app stays stable.

(`1ubq.cif` and `2kpo.cif` already exist at the repo root as test structures.)

## 4. Out of scope (deferred)

iphoneos **device** build + code signing/provisioning; AI chat backend (would use `URLSession`,
never a subprocess); live `SequencePanel` data; iPad ray-image display; numpy; prebuilt metallib;
App Store packaging; Metal atom-pick hit-testing (tap-select may be partial — not MVP-blocking).

## 5. Key technical decisions

- **Metal shaders on iOS → runtime-compile from bundled sources (chosen).** Bundle
  `data/shaders_metal/` (we copy `data/` anyway) and rely on the existing
  `MetalShaderMgr::compileFromSourceFiles()` fallback (`layer0/MetalShaderMgr.mm:60–153`);
  `newLibraryWithSource` compiles for the Simulator at runtime, so **no new build tooling**.
  - *Alternative (deferred):* precompile `pymol.metallib` via
    `scripts/compile_metal_shaders.py --sdk iphonesimulator` and bundle it (faster startup,
    build-time validation, but more plumbing and per-SDK rebuilds). Revisit for the device phase.
- **Python embedding → mirror `main_appkit.mm` with the modern `PyConfig` API.** Rewrite
  `PyMOLBridge_InitPython` to: append `_cmd` to the inittab before init, use `PyConfig`, set
  `config.home` to the bundled BeeWare **3.13** stdlib (resolve exact layout by inspecting
  `deps_ios/Python.xcframework` + `deps_ios/VERSIONS`), insert `Resources/modules` on `sys.path`,
  call `init_cmd()`, and set `PYMOL_PATH`/`PYMOL_DATA`. Do **not** reuse the hardcoded 3.14 path.
- **Build-phase changes live in `swiftui/project.yml`** (regenerated via `xcodegen`), not
  hand-edited in `project.pbxproj`.
- **Trust the build, not the static guess.** Phase 0 runs a real `xcodebuild` to surface the
  actual compile/link errors; fix what the compiler reports.

## 6. Plan (phased — each phase ends in a verifiable checkpoint)

Phases are ordered by hard dependency. Code for Phases 1 and 2 can be written together, but the
checkpoints must pass in order (the app must launch before a loaded structure can render).

### Phase 0 — Make the iOS target build
- Add `import UIKit` under the `#if os(iOS)` branches of `CommandPanel.swift` and
  `MetalViewport.swift`.
- `xcodegen generate`; `xcodebuild -scheme PyMOLViewer_iOS -sdk iphonesimulator`; fix the real
  errors that surface (expect a few more Swift/ObjC++ bridging issues).
- ✅ **Checkpoint:** iOS Simulator target compiles and links `libpymol_core.a` +
  `Python.xcframework` cleanly.

### Phase 1 — Launch with working embedded Python (packaging blocker)
- In `project.yml`, add build phases: copy `modules/` → Resources; copy `data/`
  (incl. `shaders_metal/`) → Resources; **Embed Frameworks** for `Python.xcframework`; bundle the
  BeeWare `python-stdlib` (exact layout TBD by inspection — top risk, see §7).
- Rewrite `PyMOLBridge_InitPython` per §5 (modern `PyConfig`, `config.home` → bundled 3.13 stdlib,
  inittab `_cmd`, `sys.path` += `Resources/modules`, `init_cmd()`, `PYMOL_PATH`/`PYMOL_DATA`).
- ✅ **Checkpoint:** app launches in the Simulator; Command panel runs
  `print(cmd.get_version_message())` and returns real feedback (viewport may still be black).

### Phase 2 — Pixels on screen (render-wiring blocker)
- Add bridge entry points mirroring `main_appkit.mm:805–869`: either discrete
  `PyMOLBridge_SetDrawable(handle, drawable, passDesc)` + `BeginFrame`/`Viewport(w,h)`/`EndFrame`,
  or a single `PyMOLBridge_RenderMetal(handle, drawable, passDesc, w, h)`. Pass the Metal objects
  across the ObjC++ boundary as `id`/`void*`.
- In `MetalViewport.draw(in:)`, pass `view.currentDrawable` + `currentRenderPassDescriptor` to the
  renderer, then begin → `SceneRenderMetal(G)` → end. Confirm the metallib loads via the
  runtime-compile path (`MetalShaderMgr.mm:19–26`).
- ✅ **Checkpoint:** viewport clears to PyMOL's background; `load 1ubq.cif; hide everything;
  show cartoon` renders a cartoon. Capture with `xcrun simctl io booted screenshot`.

### Phase 3 — Basic touch interaction
- Verify the existing UIKit gestures drive `PyMOLBridge_Button`/`Drag` (drag = rotate, pinch =
  zoom, two-finger pan = translate); implement the empty `handleRotation` (`MetalViewport.swift:280–283`)
  if quick.
- ✅ **Checkpoint:** rotate/zoom a loaded structure smoothly; app remains stable across
  load + interaction.

## 7. Risks & unknowns

1. **BeeWare Python stdlib layout + `PyConfig.home` correctness** — likeliest time sink. Resolve by
   inspecting `deps_ios/Python.xcframework` and `deps_ios/VERSIONS`; the stdlib may live inside the
   xcframework slice or as a separate `python-stdlib` to copy in. Getting `home`/`sys.path` wrong
   means Python init fails at launch.
2. **Runtime Metal shader compilation of the full set** may surface iOS-incompatible shader code or
   `#include` resolution issues (`pymol_metal_common.h` is inlined by `compileFromSourceFiles`).
3. **Build surprises** — more Swift/ObjC++ bridging errors than the two known `import UIKit` fixes.

## 8. Verification approach

Functional, automated where possible (Simulator + known structures), consistent with the project's
testing preference:
- Boot a Simulator, install/launch the app, drive the Command panel, and capture screenshots via
  `xcrun simctl` (`io booted screenshot`, `launch`, `install`).
- Phase checkpoints in §6 are the acceptance gates.

## 9. Key file references

| Concern | File / lines |
| --- | --- |
| Frame lifecycle template (macOS) | `layer5/main_appkit.mm:805–869` |
| Python boot template (macOS) | `layer5/main_appkit.mm:1216–1277` |
| Renderer frame begin/end | `layerGraphics/metal/RendererMetal.mm:311–349` |
| Renderer needs drawable | `layerGraphics/metal/RendererMetal.mm:260–261, 1074–1077` |
| iOS render gap | `swiftui/PyMOLViewer/Shared/MetalViewport.swift:129, 132–133, 138–139` |
| iOS Python init (to rewrite) | `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm:52–81` |
| Bridge API surface | `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h` |
| Metal scene driver | `layer1/SceneRender.cpp:1847` (`SceneRenderMetal`) |
| Shader load/runtime-compile | `layer0/MetalShaderMgr.mm:19–26, 28–58, 60–153` |
| macOS resource bundling (template) | `appkit/CMakeLists.txt:340–353` |
| iOS build flags | `swiftui/PyMOLBridge.xcconfig` (`_PYMOL_NO_OPENGL`, `_PYMOL_IOS`) |
| iOS entry stubs | `layer5/main_ios.cpp` |
| Xcode project source | `swiftui/project.yml` (regen via `xcodegen`) |
