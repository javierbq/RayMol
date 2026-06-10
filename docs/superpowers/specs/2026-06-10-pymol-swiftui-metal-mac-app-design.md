# Unified SwiftUI + Metal PyMOL — Self-Contained Native Mac App

- **Date:** 2026-06-10
- **Branch:** `swiftui-cross-platform`
- **Status:** Approved design — ready for implementation planning
- **Builds on:** `docs/superpowers/specs/2026-06-09-pymol-ipad-metal-mvp-design.md` (iPad MVP, now working)

## 1. Goal

Make the **SwiftUI + Metal PyMOL app** ("the Swift PyMOL version") a single codebase that runs
natively on **both macOS and iPadOS**, sharing the Metal rendering core. The iPad target is done
(see the MVP spec). This project delivers the **native macOS target** of that same app as a
**self-contained, distributable `.app`** with **embedded Python (no Homebrew dependency)**, at
feature parity with the existing AppKit Metal app **except AI chat**, ad-hoc code-signed and
runnable as a copied bundle on this Mac. It supersedes the older AppKit app (`layer5/main_appkit.mm`).

## 2. Background & current state

- **`master`** already has a working **macOS-native AppKit app** with the Metal backend
  (`layer5/main_appkit.mm`): proof that PyMOL's molecular geometry renders via Metal on macOS.
- **This branch** added the **cross-platform SwiftUI app** (`swiftui/PyMOLViewer/`). The shared
  code — `Bridge/PyMOLBridge.{h,mm}`, `Shared/PyMOLEngine.swift`, `Shared/MetalViewport.swift`,
  and the panels (`CommandPanel`, `ObjectPanel`, `MousePanel`, `SequencePanel`, `ChatPanel`) —
  is `#if`-conditionalized for both platforms. `MetalViewport` already has a macOS
  `NSViewRepresentable` + `NSEvent` mouse/keyboard path and an iOS `UIViewRepresentable` touch path.
- **The iPad MVP work (this session)** fixed the shared bridge so it actually runs: `extern "C"`
  linkage, `SingletonPyMOLGlobals = G` before `PInit`, command routing via `cmd.do`, PyMOL's GIL
  model (`PAutoBlock`) across all Python entry points, frame-free `GetFeedback`, `RendererMetal`
  construction + per-frame drawable handoff (`PyMOLBridge_SetupMetalRenderer` /
  `PyMOLBridge_RenderMetalFrame`), the `GLVertexBuffer` stub interleave, and tap-to-pick
  (`PyMOLBridge_Pick`). **All of this is in the shared bridge/engine, so the macOS target inherits
  it.**
- **The macOS SwiftUI target (`PyMOLViewer_macOS`) has NOT been built this session.** It links the
  **macOS** core (`build_appkit/`, Homebrew Python 3.14) per `PyMOLBridge.xcconfig`
  (`[sdk=macosx*]`). Expect to surface and fix build/run issues specific to it.

**The Metal renderer is shared and proven on macOS — there is no new rendering work in this project.**
The work is: get the macOS SwiftUI target building/running, reach panel parity, and make it
self-contained + signed.

## 3. Definition of done

A `PyMOLViewer.app` that:
1. Is a native macOS SwiftUI app (the cross-platform `PyMOLViewer_macOS` target).
2. Renders a structure via Metal; mouse rotate/zoom + click-to-pick work.
3. Has all non-chat panels working (command, objects, mouse, sequence), plus mouse/keyboard and a
   basic menu — parity with the AppKit app except AI chat.
4. Is **self-contained**: bundles its own Python (via `python-build-standalone`), the Python
   stdlib, PyMOL `modules/` + `data/`, and a macOS `pymol.metallib`. Launches with **no Homebrew /
   no system-Python dependency**.
5. Is **ad-hoc code-signed** and launches correctly when copied to another location / quarantined
   on this Mac.

## 4. Out of scope (deferred)

- **AI chat** — the AppKit app's Claude Agent SDK chat (`ai_chat`); `ChatPanel` stays a stub. Its
  own follow-up project (API keys, networking, agent loop).
- **Notarization** — no Developer ID yet. Structure the signing step so notarization + stapling can
  be enabled later; do not block on it.
- **Retiring the AppKit app** — leave `main_appkit.mm` in place; remove only once SwiftUI-Mac is at
  parity in day-to-day use (separate cleanup).
- **App Store / sandboxing**, Windows/Linux, iPad changes.

## 5. Key technical decisions

- **Embedded Python → `python-build-standalone` (chosen).** Bundle a relocatable macOS CPython into
  `PyMOLViewer.app/Contents/Resources/python` using the **same `lib/python3.x` layout as the iOS
  BeeWare distribution**, so the shared `PyMOLBridge_InitPython` (`config.home = <res>/python`)
  works **unchanged** on both platforms. Pick the standalone build's Python version to match the
  shared bridge's `python3.13` path assumption (or make the version directory lookup dynamic).
  - *Rejected:* embedding Homebrew's `Python.framework` (not relocatable / notarization-hostile;
    the macOS deployment-target and `@rpath` are wrong for distribution); static-linking libpython
    (complex, and the stdlib still must be bundled).
- **Rebuild the macOS core against the standalone Python.** Today `appkit/CMakeLists.txt` +
  `PyMOLBridge.xcconfig` link Homebrew `-lpython3.14`. Phase C points the macOS build at the
  standalone Python's headers + lib. Keep the change `[sdk=macosx*]`-scoped so iOS is unaffected.
- **Metal shader library:** build `pymol.metallib` with
  `scripts/compile_metal_shaders.py --sdk macosx` and bundle it (the AppKit CMake already does this
  at `appkit/CMakeLists.txt:349-353`); `MetalShaderMgr` loads it from the bundle, else compiles
  `data/shaders_metal/` at runtime.
- **Bundle packaging via xcodegen build phases**, mirroring the iOS approach (this branch already
  added iOS-guarded scripts to `swiftui/project.yml`). Add **macOS-guarded** phases
  (`case "$PLATFORM_NAME" in macosx*`) for the macOS payload; keep iOS phases untouched.
- **Ad-hoc signing first.** Sign embedded dylibs + the `.app` with `codesign -s -` (ad-hoc) +
  hardened-runtime where compatible; verify a copied/quarantined bundle launches. Notarization is a
  later, gated step.

## 6. Plan (phases — each ends in a verifiable checkpoint)

Phases are ordered to de-risk fastest first: get the app running on Mac before changing how Python
is bundled.

### Phase A — Mac app runs (dev build, existing core)
- Build + launch `PyMOLViewer_macOS` (xcodegen → xcodebuild `-sdk macosx`), linking the existing
  macOS core. Rebuild the macOS core if needed (the AppKit CMake / `build_appkit`).
- Fix build/run issues this target hasn't hit (it shares the bridge but hasn't been compiled for
  macOS this session).
- ✅ **Checkpoint:** the SwiftUI Mac app launches, loads a structure, renders the cartoon via Metal,
  and mouse rotate/zoom + click-to-pick work. (Verify with a screenshot; reuse the iPad MVP's
  `PYMOL_AUTOLOAD`/`AUTOPICK`/`AUTOTURN` affordances if helpful.)

### Phase B — Feature parity (minus chat)
- Confirm every non-chat panel works on Mac (command, objects, mouse, sequence) and full
  mouse+keyboard input; add a basic app menu if needed.
- Note (do not implement) any AppKit-only feature beyond chat for a future parity pass.
- ✅ **Checkpoint:** a user can drive PyMOL on Mac through the SwiftUI panels — load, represent,
  select, run commands — without the AppKit app.

### Phase C — Self-contained Python (no Homebrew)
- Obtain a relocatable macOS CPython (`python-build-standalone`), staged under `deps_macos/`
  (mirroring `deps_ios/`). Stage it into the bundle's `Resources/python` with the iOS-compatible
  `lib/python3.x` layout.
- Repoint the macOS core build (CMake + xcconfig, `[sdk=macosx*]`) at the standalone Python's
  headers + lib; rebuild the core.
- Add macOS-guarded `project.yml` build phases: copy `modules/`, `data/`, the standalone Python +
  stdlib; build + bundle `pymol.metallib` (`--sdk macosx`).
- ✅ **Checkpoint:** the `.app` launches and renders with **no Homebrew / no system Python**
  (verify by testing with Homebrew Python off `PATH` / temporarily moved, or `otool -L` showing no
  Homebrew/`/usr/local`/`/opt/homebrew` Python linkage).

### Phase D — Sign + run standalone
- Ad-hoc code-sign all embedded dylibs (standalone Python, its extension modules) and the `.app`
  (inside-out signing order); apply hardened runtime where compatible.
- Verify a **copied** bundle (and a quarantined copy) launches and renders on this Mac.
- Document the notarization steps as a gated TODO (needs Developer ID).
- ✅ **Checkpoint:** `codesign --verify --deep --strict` passes; a copied/quarantined
  `PyMOLViewer.app` launches and renders the cartoon.

## 7. Risks & unknowns

1. **Phase A build cascade.** The macOS SwiftUI target hasn't been built this session; like iOS, it
   may surface a chain of compile/link issues (it shares the bridge, so many are pre-fixed, but the
   macOS link line + Homebrew Python + `build_appkit` core are a different combination).
2. **Relocatable-Python relink + dylib signing (C/D)** is the novel, fiddly part: getting
   `config.home`/`sys.path` right for the standalone layout, `@rpath`/install-name correctness, and
   inside-out ad-hoc signing of every embedded `.so`/dylib so a copied bundle launches.
3. **Python version skew.** The shared bridge assumes `python3.13` (iOS BeeWare). The
   `python-build-standalone` choice must match that path, or the version-dir lookup must be made
   dynamic — otherwise macOS won't find its stdlib.

## 8. Verification approach

Functional, automated where possible (consistent with the project's testing preference):
- Build via `xcodebuild -sdk macosx`; launch the `.app`; screenshot the rendered cartoon.
- Reuse the iPad MVP's env-gated affordances (`PYMOL_AUTOLOAD`, `PYMOL_AUTOPICK`, `PYMOL_AUTOTURN`)
  for headless-ish verification.
- Phase C: prove no-Homebrew dependency via `otool -L` on the app binary + embedded Python, and a
  launch with Homebrew Python removed from the environment.
- Phase D: `codesign --verify --deep --strict` + a copied/quarantined-bundle launch.

## 9. Key file references

| Concern | File |
| --- | --- |
| Shared bridge (inherited by Mac) | `swiftui/PyMOLViewer/Bridge/PyMOLBridge.{h,mm}` |
| Shared engine / viewport | `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, `MetalViewport.swift` |
| macOS link config | `swiftui/PyMOLBridge.xcconfig` (`[sdk=macosx*]` lines) |
| xcodegen project + build phases | `swiftui/project.yml` (iOS-guarded phases to mirror for macOS) |
| macOS core + AppKit reference | `appkit/CMakeLists.txt`, `layer5/main_appkit.mm` |
| Metal shader build | `scripts/compile_metal_shaders.py` (`--sdk macosx`) |
| Metal core (shared, proven) | `layerGraphics/metal/RendererMetal.mm`, `layer1/SceneRender.cpp` |
| iPad MVP precedent | `docs/superpowers/specs/2026-06-09-pymol-ipad-metal-mvp-design.md` |
