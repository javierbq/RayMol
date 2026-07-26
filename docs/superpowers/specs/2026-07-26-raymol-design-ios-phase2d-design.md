# RayMol Design mode on iOS/iPad — #217 Phase 2d

**Date:** 2026-07-26
**Issue:** [#217](https://github.com/javierbq/RayMol/issues/217) Phase 2d
**Predecessors:** Phase 1 (MPNNKit API), 2a (confidence viz, PR #221), 2b (point mutation, PR #227), 2c (region redesign, PR #228 — merged as `0e6ba4a79`)
**Successor:** Phase 2e (Mac App Store build)

---

## 1. Goal

Make Design mode — on-device ProteinMPNN inference via MPNNKit — available on iPhone and iPad. Today the entire feature is compiled out for iOS by a single build flag.

Phase 2d is deliberately a *port*, not a redesign. The Design domain logic, the Python helper layer, and the closure contracts between them are already platform-neutral and stay untouched. What this phase adds is: build configuration, an iOS entry point and adaptive layout, a touch replacement for one mouse-only affordance, and the memory safety that a 2 GB-class workload needs on a device that kills processes without warning.

---

## 2. Starting state (verified, not assumed)

The port is smaller than the roadmap implied. All five Design Swift files — `DesignController.swift`, `DesignResidues.swift`, `DesignColor.swift`, `DesignScoreCache.swift`, `MPNNGate.swift` — already live in `Shared/`, are already members of the iOS target's Sources phase, and are already free of AppKit and `NS*` types. They compile today as **empty translation units** because `RAYMOL_MPNN` is undefined for the iOS SDK.

A `xcrun -sdk iphoneos swiftc -typecheck` pass over every `#if RAYMOL_MPNN` region found exactly **one** iOS compile error:

- `TapGesture().modifiers(.shift)` at `swiftui/PyMOLViewer/Shared/ContentView.swift:3314-3318` — `modifiers` is unavailable on iOS.

Everything else typechecks clean for iOS, including `.menuStyle(.borderlessButton)`, `.menuIndicator(.hidden)`, `.controlSize(.mini)`, `.toggleStyle(.switch)`, `.onHover`, `.help()`, `.popover`, and `MainActor.assumeIsolated`.

The Python half (`modules/pymol/raymol_design.py`, 694 lines) has no platform gating, and `modules/` is already copied wholesale into the iOS bundle by `swiftui/project.yml:335-344`.

### Measured device performance

From a prior on-device harness (`~/repos/proteinmpnn-ios`, results committed in `device_results/on_device_results_optimized.json`) — iPhone 15 Pro, 8 GB, physical device, `design()` + `repack()`:

| L (residues) | wall clock | MLX peak active |
|---:|---:|---:|
| 68 | 0.30 s | 145 MB |
| 425 | 1.04 s | 751 MB |
| 955 | 2.91 s | 1666 MB |
| 1590 | 5.41 s | 2427 MB |
| 2120 | 7.33 s | 2851 MB |

Linear at ≈1.4 MB/residue. This **meets #217's own acceptance criteria** (<3 s under 500 aa, <10 s under 1500 aa on iPhone 15). The harness carried no entitlements file and survived 2.85 GB — with a 96 MB MLX cache clamp in place.

Two caveats that shape §8:

- `peakMB` is MLX peak *active* memory and excludes the buffer cache (`mlx-swift/Source/MLX/Memory.swift:171-178`); true `phys_footprint` is higher.
- RayMol's **own** iOS baseline (PyMOL core + embedded CPython + numpy + Metal render buffers + loaded structure) has never been measured, so the table above cannot simply be added to a known floor.

---

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **iPhone and iPad both, one adaptive UI** | The measured numbers come from an iPhone, so capability is not the limiter. An iPad-only gate would be enforced at runtime anyway — the code ships either way — so deferring iPhone buys only the compact-layout work, which is most of the phase. |
| D2 | **App floor 17.0; Design mode requires iOS 18 at runtime** | 17.0 is forced (SPM won't resolve MPNNKit below it). 18.0 is the only configuration ever run on real hardware. Gating the *feature* rather than the *app* means no iOS 17 user loses RayMol, and we ship nothing unverified. |
| D3 | **Two-tier size policy: warn (after autosave), then refuse** | Jetsam is an uncatchable SIGKILL and mlx-swift's error handler exits the process, so overshoot is unrecoverable. But a hard refusal on a structure that would have worked is hostile to a power user. Warn-with-autosave keeps the user in control while making a kill cost no work. |
| D4 | **iPhone layout: compact dock + settings sheet** | Design mode exists to look at a structure, so chrome should be cheap. ~110 pt of dock leaves the most viewport, and no primary action hides off a scroll edge. |
| D5 | **Region-edit mode ships on macOS too** | The shift-click replacement is a genuine discoverability improvement, not an iOS compromise. Shift-click survives on macOS as the power-user shortcut. |
| D6 | **Do not bump the C++ core's iOS deployment target** | A static library built for an older minimum links cleanly into a 17.0 app. Bumping `appkit/ios.toolchain.cmake:26` would force a full iOS deps rebuild for no benefit. |

---

## 4. Platform policy

New file `swiftui/PyMOLViewer/Shared/DesignAvailability.swift`:

```
enum DesignAvailability {
    /// True when Design mode can be offered: compiled in AND the OS is validated.
    static var isSupported: Bool
}
```

- macOS: `true` whenever `RAYMOL_MPNN` is defined (unchanged behaviour).
- iOS: `true` only when `RAYMOL_MPNN` is defined **and** `#available(iOS 18, *)`.
- Otherwise `false`.

Every iOS entry point (rail pill, docked panel slot, `anyTop` predicate) is built only when `isSupported`. Below iOS 18 the feature is absent rather than present-and-broken. `isSupported` is a pure expression and is unit-tested through an injectable OS-version seam rather than by branching on the host OS.

`appkit/ios.toolchain.cmake` and `scripts/build_ios_deps.sh` / `scripts/build_numpy_ios.sh` are **not** modified (D6).

---

## 5. Build configuration

All edits in `swiftui/project.yml` unless noted. The generated `PyMOLViewer.xcodeproj/project.pbxproj` follows from `xcodegen generate` — it is never hand-edited.

| # | Change | Location |
|---|---|---|
| B1 | Define `RAYMOL_MPNN` for the iOS SDK: add a `"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphone*]"` key alongside the existing `[sdk=macosx*]` one. Update the now-wrong comment above it. | `project.yml:85-88` |
| B2 | Remove `platforms: [macOS]` from the MPNNKit package dependency. Update the comment, which claims "MPNNKit (mlx-swift) has no iOS slice" — both manifests declare `.iOS(.v17)`. | `project.yml:448-452` |
| B3 | Same removal on the test target's MPNNKit dependency. | `project.yml:487-493` |
| B4 | `deploymentTarget.iOS`: `"16.0"` → `"17.0"`. | `project.yml:6` |
| B5 | Bundle the weight pack for iOS: replace the macOS-only `case "$PLATFORM_NAME" in macosx*) ;; *) exit 0 ;; esac` early-exit, and change `DEST` from `${CONTENTS_FOLDER_PATH}/Resources` to **`${UNLOCALIZED_RESOURCES_FOLDER_PATH}`**, which resolves to `Contents/Resources` on macOS and the flat app root on iOS. Rename the build phase from "macOS: Bundle MPNN.mpnnpack". | `project.yml:432-446` |
| B6 | Rename `swiftui/resources_macos/` → `swiftui/resources_mpnn/`. Only two references exist, both in `project.yml` (`:435` comment, `:446` `cp`). The directory must stay outside the auto-scanned `PyMOLViewer/` tree so xcodegen never adds it to a Copy Bundle Resources phase — that is the whole reason it exists. | `project.yml:435,446` |
| B7 | Add `-skipPackagePluginValidation` (and `-skipMacroValidation`) to the iOS branch of `swiftui/archive_appstore.sh:33-46`. mlx-swift's `Cmlx` target carries a `CudaBuild` `.buildTool()` plugin that stalls a headless archive. | `archive_appstore.sh` |
| B8 | Verify — do not assume — that the MPNNKit dependency remains **outside** the `RAYMOL_SPARKLE_BEGIN`/`END` markers so the Mac App Store sed-strip does not remove it. It currently does (`project.yml:448-452` precedes the `:453` marker); B2's edit must not disturb that. | `project.yml:448-453` |

`MPNNGate.packURL` resolves via `Bundle.main.url(forResource: "MPNN", withExtension: "mpnnpack")`, which works for both the macOS `Contents/Resources` location and the iOS bundle root, so no Swift change is needed for pack discovery.

**Accepted cost:** the IPA grows ≈28.6 MB (23.7 MB weight pack + ≈3.8 MB `default.metallib` + MLX object code). This is a size decision, not a compliance one; on-demand resources are explicitly out of scope (§11).

---

## 6. New components

Three new files, each pure enough to unit-test without a device, MLX, or PyMOL.

### 6.1 `MPNNRuntime.swift`

The **only** file in RayMol that imports MLX. Owns process-wide MLX configuration, applied exactly once before the first inference.

```
enum MPNNRuntime {
    /// Idempotent. Must be called on the inference queue before any MPNNKit call.
    static func configureOnce()
}
```

Two responsibilities:

1. **Cache clamp** — `MLX.GPU.set(cacheLimit:)` to 96 MB. Non-negotiable: the bench app applies this with the comment *"measured >5 GB unbounded at L~1000"*, and MLX's default is ≈1.5× `maxRecommendedWorkingSetSize`. RayMol has no `import MLX` today and therefore no clamp.
2. **Simulator fallback** — under `#if targetEnvironment(simulator)`, `setenv("MLX_METAL_GPU_ARCH", "applegpu_g15g", …)` and `MLX.Device.setDefault(device: Device(.cpu))`. Without this, MLX **aborts** on first inference in any simulator: it cannot allocate `MTLStorageModePrivate` heaps there, and `architecture()->name()` returns null. This block is what makes any simulator test path possible at all.

### 6.2 `DesignSizeGuard.swift`

The D3 policy as a pure function — no MLX, no UIKit, no I/O.

```
enum DesignSizeGuard {
    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingResidues: Int)
    }
    static func evaluate(residueCount: Int, availableBytes: Int) -> Decision
}
```

Constants, derived from the §2 measurement rather than guessed, and kept in one reviewable block:

| Constant | Value | Derivation |
|---|---|---|
| `bytesPerResidue` | 1.4 MB | Least-squares slope of the §2 table is 1.32 MB/residue ((2851−145) / (2120−68)); rounded up for margin. |
| `fixedOverhead` | 160 MB | Measured intercept is ≈55 MB (145 − 68 × 1.32), plus the 96 MB cache clamp from §6.1. |
| `okFraction` | 0.50 | |
| `warnFraction` | 0.75 | |

`estimate = fixedOverhead + residueCount × bytesPerResidue`, compared against `availableBytes`:

- `estimate ≤ 0.50 × available` → `.ok`
- `0.50 <` … `≤ 0.75 ×` → `.warn`
- `> 0.75 × available` → `.refuse`, reporting `maxFittingResidues = (0.75 × available − fixedOverhead) / bytesPerResidue`

The 25% reserve is not padding for its own sake: MLX's reported peak excludes the buffer cache (§2), so true `phys_footprint` runs above our estimate by an amount nobody has measured. These four numbers are the single place to retune once §12's device measurements land, and the tests assert the boundaries rather than the interior.

Callers obtain `availableBytes` from `os_proc_available_memory()` on iOS. On macOS the guard is bypassed entirely and always yields `.ok` — macOS has swap, and shipped macOS behaviour must not change.

Choosing `os_proc_available_memory()` over a static residue cap is deliberate: it accounts for whatever structures are already loaded, so the limit adapts to actual session state instead of guessing a worst case.

### 6.3 `DesignAvailability.swift`

Per §4.

---

## 7. Changes to existing components

### 7.1 `DesignController.swift`

- Call `MPNNRuntime.configureOnce()` on the inference queue before the first MPNNKit call.
- Consult `DesignSizeGuard` before dispatching work in `redesignSelectionAwait()`, `repackNowAwait()`, and focus scoring. `.refuse` sets `errorText` and returns without dispatching; `.warn` raises a confirmation the UI presents, and on confirm triggers an autosave before proceeding.
- New `releaseModel: (() -> Void)?` closure, invoked from `exit()`. It must be **enqueued onto `inferenceQueue`** (`DesignController.swift:176`), not run on the main thread: `_mpnnModel` (`PyMOLEngine.swift:1958`) is an unsynchronized stored property on the process-wide engine singleton read only on that serial queue, so a main-thread nil-out would race in-flight inference.
- New `@Published var regionEditMode: Bool` (§9).
- Bound `DesignScoreCache` with eviction; `invalidate(object:)` at `DesignScoreCache.swift:23-28` is currently dead code and should either be wired up or removed.

The existing closure contracts (`DesignRegionFn`, `ListSelectionsFn`, `SelectedIndicesFn`, score, repack) are **unchanged**, as is the full-length-versus-valid-projected index discipline. Nothing in the Python layer changes.

### 7.2 `PyMOLEngine.swift`

- Provide `releaseModel` when constructing `designController`, nilling `_mpnnModel`.
- No change to `loadedMPNNModel()` (`:1959`) or the `.leaveOneOut` scoring call (`:1987`) — see §11.

### 7.3 `ContentView.swift` — the one compile fix

Wrap the `.highPriorityGesture(TapGesture().modifiers(.shift)…)` at `:3314-3318` in `#if os(macOS)`. Its cross-platform replacement is §9.

### 7.4 `ContentView.swift` — iOS wiring

| Change | Location |
|---|---|
| 5th `railToggle` pill ("Design", `wand.and.stars`), built only when `DesignAvailability.isSupported` | `topPaneRail`, `:1876-1907`; helper `:1943-1963` |
| Design joins the mutually-exclusive docked mode chain (`if .move … else if measure … else if designMode`) in all four slots | `:1461-1462` (iPhone portrait), `:1542-1543` (iPhone landscape), `:1680-1681` / `:1744-1745` (iPad) |
| `engine.designMode` joins the `anyTop` predicates, or the rail floats over a full-bleed viewport with no chrome band | `:1433-1434`, `:1520-1521`, `:1654-1655` |
| Hoist the `.onChange(of: engine.designMode)` lifecycle observer out of the macOS-only block into shared `body`. Without it iOS dims and recolours a structure with **no restore path**. | currently `:502-515` |
| Design branch in `MetalViewport.handleTap` (`:1027-1055`) routing to focus-object / `setPinned`, mirroring the macOS `longPressPick` → `:671-691` path | `MetalViewport.swift`, `ContentView.swift` |
| Add the `&& !engine.designMode` guard to the iOS long-press `confirmationDialog` (`:1180-1188`) that macOS already has (`:664`), or the residue action sheet eats every Design hit | `:1180-1188` |
| `.presentationCompactAdaptation(.popover)` on the selection picker (`:3402`) and help (`:3840`) popovers, which otherwise become full sheets on iPhone | `:3402`, `:3840` |

`busyOverlay` already carries the gated `DesignBusyOverlayView` and is attached in both layouts, so blocking-overlay behaviour works on iOS the moment the flag is defined — no change needed.

---

## 8. iPhone layout (D4)

Which panel each platform gets, explicitly:

| Platform | Docked-slot content |
|---|---|
| macOS | today's five-row `DesignOverlayView`, unchanged except the error banner (§10) and region-edit toggle (§9) |
| iPad (both orientations) | the same `DesignOverlayView` — ≥1024 pt accommodates the five rows |
| iPhone (both orientations) | new `DesignCompactPanel` + `DesignSettingsSheet` |

The iPhone fork is a single conditional at the docked-slot call sites, not a parallel view hierarchy: both panels drive the same `DesignController`, so no state or logic is duplicated.

**Docked (≈110 pt, four rows):**

1. Focus-object menu · sequence score · scoring spinner · `⋯` (opens the sheet) · ✕ (exit)
2. Sequence strip — already a horizontal `ScrollView`, unchanged
3. Propensity pills, or the palette row in region mode — already scrolls, unchanged
4. Primary action row: region selection button + Redesign; Keep / Discard when an edit session is active

**In the sheet:** auto-repack, sidechains, side-by-side, temperature, colour meaning + legend.

`Compare` stays **docked**, not in the sheet: it is toggled repeatedly while judging a design, unlike the set-once preferences around it.

Two supporting concerns:

- **Touch targets.** Sequence columns are 14 pt (`:3275`/`:3282`) and palette pills 30×36 (`:3918-3962`), both below the 44 pt guidance. Sequence columns stay visually 14 pt — a legible sequence requires it — but gain an expanded hit region; pills move to a standard control size on iOS. Platform-forked sizing precedent: `TimelinePanel.swift:86-89`, `TransportBar.swift:66-72`.
- **Tooltips.** The ≈14 `.help()` calls are invisible on touch. Essentials move into the existing help sheet; the rest remain accessibility hints.

---

## 9. Input model: region-edit mode (D5)

Replaces shift-click as the way to build an ad-hoc region, on **both** platforms.

- New `regionEditMode` toggle in the region strip.
- While on: a plain tap on a sequence column toggles that residue's region membership instead of pinning it, and a tap in the viewport does the same. While off: taps pin, exactly as today.
- macOS additionally keeps shift-click as a shortcut (`#if os(macOS)`), so no existing muscle memory breaks.
- Routing is a pure decision inside `DesignController` (`regionEditMode` → `toggleRegionResidue` vs `setPinned`) and is unit-tested without any UI.

Named-selection regions (the 2c dropdown) are unaffected and remain the primary path.

Hover-driven UI — the residue badge, propensity row, and transient sidechain sticks — has no touch analogue, since touch has no hover state. The **pinned** residue (already implemented via `setPinned`) becomes the primary interaction on iOS; hover remains an iPad indirect-pointer bonus by branching `MetalViewport.handleHover` (`:1075-1105`).

---

## 10. Error handling

`errorText` is written in six places in `DesignController` (`:16`, `:266`, `:391`, `:413`, `:423`, `:679`) and **read nowhere in the app** — only by a unit test. Every Design failure on iOS would be silent, including all four "dead on arrival" failure modes this phase introduces.

- A `DesignErrorBanner` in the Design overlay renders `controller.errorText` on both platforms, tap- and timeout-dismissible. This is small and lands **early** in implementation, because it makes everything else in this phase diagnosable.
- The size guard is *preventive* by necessity: mlx-swift's default error handler prints then exits (`mlx-swift/Source/MLX/ErrorHandler.swift:4`), so `DesignController`'s `do/catch` and `try?` sites can never observe an allocation failure.
- **Time-boxed spike with a binary outcome:** can that handler be replaced with one that records instead of exiting? If yes, install it — a class of hard crashes becomes catchable. If no, say so in the PR body and rely on the guard alone. Either way the outcome is written down; what is *not* acceptable is leaving the question open.
- On a `.warn` confirmation, write an autosave before dispatching, so a jetsam kill costs no user work.

---

## 11. Out of scope

| Item | Why |
|---|---|
| `.leaveOneOut` → `.conditional` scoring swap | `PyMOLEngine.swift:1987` uses `.leaveOneOut`, whose decode work is ≈L× `.conditional`'s and which **has never been measured on any device**. This phase measures it (§12). Swapping it changes confidence semantics — a science call, and a cross-platform one, not iOS work. |
| On-demand resources / first-run weight download | New subsystem; needs hosting, an offline story, and integrity checking. Bundling is the D-level decision. |
| Chunking in MPNNKit | No chunking mechanism exists upstream; this is a new MPNNKit feature. |
| Phase 2e (Mac App Store) | Separate phase. |
| Escape-to-exit-mode | [#235](https://github.com/javierbq/RayMol/issues/235). |
| C++ core iOS deployment-target bump | D6. |

---

## 12. Verification

**Pure unit tests (no device, no MLX, no PyMOL)** — added to the existing `PyMOLViewerTests` target, whose 50 gated Design tests already drive `DesignController` through its seven `#if DEBUG` injection seams (`DesignController.swift:952-1018`) with stub defaults:

- `DesignSizeGuard.evaluate` — `.ok`/`.warn`/`.refuse` boundaries, `refuse` residue arithmetic, degenerate inputs (zero residues, zero available memory).
- `DesignAvailability.isSupported` through its injectable version seam.
- Region-edit-mode routing: `regionEditMode` on → membership toggles; off → pinning.
- `exit()` enqueues the model release on the inference queue rather than running it inline.

**Simulator (headless).** New `PYMOL_AUTODESIGN` environment hook — the established verification pattern in this codebase, which has 35 such `PYMOL_AUTO*`/`SKIP*` hooks and not one for Design. It enters Design mode, focuses an object, optionally runs a redesign, and writes a completion marker. Combined with the §6.1 simulator fallback this makes "does the Design pipeline work end-to-end on iOS" an automated check. Note `PyMOLViewerUITests` cannot `@testable import` internals (`project.yml:520-526` blanks the bridging header), so it verifies UI and entry points, not logic.

**Physical device (no substitute).** Latency, memory, jetsam behaviour, and cache-clamp tuning. The `mac-vm-test` path is unavailable: the VM's paravirtual GPU will not run MLX reliably. This is also where `.leaveOneOut` gets its first measurement at representative L, and where the §6.2 constants are validated against reality.

**CI.** No workflow compiles Swift today, so opening the iOS gate cannot break CI — and nothing will catch an iOS Design regression either. **In scope:** add the 21 existing `testing/tests/raymol/design_*.py` tests to `raymol-embedded-tests.yml` (a few lines; they cover code iOS now ships). **Out of scope:** an iOS-simulator build job. It would be the first Swift CI in this repo, which makes it a repo-wide infrastructure decision rather than a Design-mode one; it gets its own issue, filed during this phase, so the gap is recorded rather than forgotten.

**Manual gate.** Both earlier Design plans required a "iOS still builds, mlx not linked" check. After 2d that check inverts: iOS must build **with** MPNNKit linked and the pack present.

---

## 13. Risks

| Risk | Mitigation |
|---|---|
| iOS 17 turns out to be genuinely broken for mlx-swift | D2 already gates Design to 18+; the app floor at 17 is unaffected by MLX behaviour. |
| RayMol's unmeasured iOS baseline makes the §2 table optimistic | The guard reads `os_proc_available_memory()` at call time, which already accounts for the real baseline — this is precisely why a static cap was rejected. |
| `.leaveOneOut` is unacceptably slow on device | Measured in this phase (§12) before any release; if bad, it becomes a separate ticket with data attached. |
| Sequence-strip taps unreliable at 14 pt | Expanded hit region, and the named-selection path does not depend on per-column tapping. |
| First simulator run aborts, blocking all iOS testing | §6.1 fallback lands before any other iOS work. |
