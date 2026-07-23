## Fix: keepEdits isRepacking + guard tests

### Status: DONE

### Commit
See below (after git commit)

### Changes
- `DesignController.swift` `keepEdits()`: added `isRepacking = false` to match `discardEdits()` — prevents a stuck spinner if Keep is called mid-repack (Task 4).
- `DesignEditingTests.swift`: added `testKeepEndsSessionWithoutDiscard` (asserts editing/editCount reset and discard closure not called) and `testSameAAAndOutOfRangeAreNoOps` (same-aa and out-of-range index calls are no-ops).
- `PyMOLViewer.xcodeproj/project.pbxproj`: regenerated via `xcodegen generate` to pick up the previously-added `DesignEditingTests.swift` file (it existed on disk but was missing from the build target, causing 0 tests to run).

### Test result
```
Executed 4 tests, with 0 failures (0 unexpected) in 0.002 seconds
** TEST SUCCEEDED **
```

---

# Task 2 Report: edit-session state + applyMutation/discard/keep (Phase 2b)

## Status: DONE

## Commit
`ebe81a657` — `feat(design): edit-session state + applyMutation/discard/keep (2b)`

## Published state added (inside `#if RAYMOL_MPNN`)

- `@Published private(set) var editing = false`
- `@Published private(set) var editCount = 0`
- `@Published private(set) var repackDirty = false`
- `@Published var autoRepack = false`
- `@Published private(set) var isRepacking = false`
- `private(set) var workingObject: String?`
- `private(set) var editedSequence: [Int] = []`

## Closure typealiases added

- `MakeWorkingCopyFn = (String) -> String`
- `MutateDisplayFn = (String, Int, Int) -> Void` — obj, residueIndex, aa
- `DiscardFn = (String) -> Void`
- `CompareFn = (Bool) -> Void` — isImproved (wired in Task 3+)

Stored as `private var` with default no-ops; existing Phase-2a `init` signature unchanged.

## New public methods

`beginEditIfNeeded()`, `applyMutation(residueIndex:aa:)`, `discardEdits()`, `keepEdits()` — exact logic from the brief.

## Test-hook style (matching Phase-2a)

Phase-2a passes all scoring closures directly to the initializer. Edit closures are a separate lifecycle, so two `#if DEBUG` hooks were added:
- `injectEdit(makeWorkingCopy:mutateDisplay:discard:compare:)` — replaces `var` closures post-init.
- `setFocusForTest(_:nativeSequence:)` — sets `focusObject` and synthesises a `lastSet` entry from the given `[Int]` without the async score lifecycle.

## Brief-signature adaptations

None material. `setFocusForTest` was not fully specified; implemented to produce a `DesignResidueSet` with `valid: false` residues (backbone `nil`) so `beginEditIfNeeded()` can read `.aa` from each residue without backbone coordinates.

## Test result (DesignEditingTests only)

```
Executed 2 tests, with 0 failures (0 unexpected) in 0.002 seconds
** TEST SUCCEEDED **
```

## Existing-suite regression check (full PyMOLViewerTests)

```
Executed 20 tests, with 1 test skipped and 0 failures (0 unexpected)
** TEST SUCCEEDED **
```
(1 skip = DesignInferenceSmokeTests; requires `MPNN_INFERENCE=1`; unchanged.)

## Files changed

- `swiftui/PyMOLViewer/Shared/DesignController.swift`
- `swiftui/PyMOLViewerTests/DesignEditingTests.swift` (created)

## Report path

`/Users/jcastellanos/repos/RayMol/.claude/worktrees/goofy-swartz-ef2bbb/.superpowers/sdd/task-2-report.md`

---

# Previous Task 2 Report: macOS-only MPNNKit dependency + weights + RAYMOL_MPNN gate

## Status: DONE_WITH_CONCERNS

## Commit
`863eaf574` — `build(design): macOS-only MPNNKit dependency + weights + RAYMOL_MPNN gate`

---

## What changed in project.yml

### 1. Options bump
```yaml
deploymentTarget:
  macOS: "14.0"   # was 13.0
xcodeVersion: "16.0"  # was 15.0
```

### 2. Global settings
```yaml
SWIFT_VERSION: "6.0"   # was 5.9
```

### 3. Packages block restructured (outside SPARKLE markers)
```yaml
packages:
  proteinmpnn-mlx:
    url: https://github.com/javierbq/proteinmpnn-mlx.git
    from: 0.1.0
# RAYMOL_SPARKLE_BEGIN ...
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
# RAYMOL_SPARKLE_END
```
The `packages:` key is now OUTSIDE the SPARKLE markers. After the MAS strip, only `proteinmpnn-mlx` remains. `archive_appstore.sh` `grep -q "package: Sparkle"` check still passes.

### 4. RAYMOL_MPNN macOS-only compilation condition (target settings.base)
```yaml
"SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]": "$(inherited) RAYMOL_MPNN"
```

### 5. Folder reference resource (macOS only)
```yaml
resources:
  - path: PyMOLViewer/Resources/MPNN.mpnnpack
    type: folder
    platforms: [macOS]
```

### 6. Dependencies restructured (MPNNKit outside SPARKLE markers)
```yaml
    dependencies:
      - package: proteinmpnn-mlx
        product: MPNNKit
        platforms: [macOS]
# RAYMOL_SPARKLE_BEGIN ...
      - package: Sparkle
        platforms: [macOS]
# RAYMOL_SPARKLE_END
```

---

## How macOS filtering works
Both the dependency (`platforms: [macOS]`) and the compilation condition (`[sdk=macosx*]`) ensure mlx-swift/MPNNKit are never pulled into the iOS slice. The `#if RAYMOL_MPNN` guard in MPNNGate.swift is the final code-level gate.

---

## Weights bundling
Copied `/Users/jcastellanos/repos/proteinmpnn-ios/dist/MPNN.mpnnpack/` (atom14_names.json, geometry.safetensors, manifest.json, weights/) to `swiftui/PyMOLViewer/Resources/MPNN.mpnnpack/`. Committed directly (24 MB accepted per brief; no .gitignore exclusion for .mpnnpack). Added as folder-reference resource for macOS only.

---

## Build results

### macOS build
```
** BUILD SUCCEEDED **
```
SPM resolved: MPNNKit @ 0.1.0, mlx-swift @ 0.31.6, Sparkle @ 2.9.3. Required `-skipPackagePluginValidation` to skip mlx-swift's CudaBuild plugin (expected on Apple Silicon — no CUDA hardware).

### iOS build
iOS Swift compilation: SUCCEEDED (no errors, RAYMOL_MPNN absent from iOS slice confirmed — no MPNNGate/mlx references in iOS compile log).  
iOS linker: FAILED with `ld: library 'pymol_core' not found` — the iOS C++ core (`build_ios_device`) was never built in this worktree (pre-existing / out of scope). This is unrelated to MPNNKit. mlx-swift is NOT in the iOS link command.

---

## Worktree symlink setup
`deps_macos` and `build_macos_swiftui` symlinks were already present from a prior session. `CLEAN=1` was needed for `build_macos.sh` due to CMake source mismatch (build dir had cached paths from the main repo).

---

## Concerns

### Swift 6 strict-concurrency (significant)
Bumping `SWIFT_VERSION` from 5.9 → 6.0 triggered 11 Swift 6 strict-concurrency errors in existing code. All were fixed with minimal changes:
- `nonisolated(unsafe) static var/let` on 5 singleton/global-state declarations (MCPBridge, MCPServerManager, PyMOLEngine, ThemeManager, SequencePanel, TimelinePanel PreferenceKey defaults)
- `@unchecked Sendable` on 4 `ObservableObject` classes whose `@Published` mutations already happen on the main thread (PyMOLEngine, MCPServerManager, MetalViewport.Coordinator, MovieExporter)
- `@Sendable` added to 2 `@escaping` closure parameters that cross isolation boundaries
- `Binding<Bool>` explicit type annotation in ContentView (helped type-checker)
- `macOSLayout` split into `macOSLayoutContent` + `macOSLayout` to fix type-checker timeout (expression too complex for Swift 6)

These are correctness annotations, not semantic changes — the runtime behavior is unchanged.

### scheme name discrepancy
The brief specified `-scheme RayMol` but the project generates `-scheme PyMOLViewer_macOS` / `-scheme PyMOLViewer_iOS`. Used the actual scheme names.

### iOS regression verdict
iOS BUILD FAILED only due to missing `libpymol_core` (iOS C++ core not built — expected in a macOS-only worktree). Swift compilation succeeded. mlx-swift confirmed absent from iOS. Platform filter is holding.

---

## Report path
`/Users/jcastellanos/repos/RayMol/.claude/worktrees/goofy-swartz-ef2bbb/.superpowers/sdd/task-2-report.md`

---

## Fix: Swift 5 language mode

### Status: DONE

### Commit
`cc5aa499f` — `fix(design): keep Swift 5 language mode for the app target — drop unneeded Swift 6 concurrency migration (mlx needs only the Xcode 16+ toolchain)`

### Files reverted to pre-Task-2 state (commit 2da487581)
All 9 files:
- `swiftui/PyMOLViewer/Panels/MovieExportSheet.swift`
- `swiftui/PyMOLViewer/Panels/SequencePanel.swift`
- `swiftui/PyMOLViewer/Panels/TimelinePanel.swift`
- `swiftui/PyMOLViewer/Shared/ContentView.swift`
- `swiftui/PyMOLViewer/Shared/MCPBridge.swift`
- `swiftui/PyMOLViewer/Shared/MCPServerManager.swift`
- `swiftui/PyMOLViewer/Shared/MetalViewport.swift`
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`
- `swiftui/PyMOLViewer/Shared/ThemeManager.swift`

### SWIFT_VERSION change
`SWIFT_VERSION: "6.0"` → `SWIFT_VERSION: "5.9"` in `swiftui/project.yml`.
All other project.yml changes from Task 2 retained (xcodeVersion, deploymentTarget, MPNNKit package/dependency, RAYMOL_MPNN compile condition, MPNN.mpnnpack folder resource).
MPNNGate.swift not touched.

### macOS build result
```
** BUILD SUCCEEDED **
```

### Swift-5 concurrency fix required?
**Yes — one fix was necessary**, but it was NOT a concurrency issue. It was a Swift type-checker timeout:

`ContentView.swift:477:16: error: the compiler is unable to type-check this expression in reasonable time`

The `macOSLayout` computed var had too long a view modifier chain. Fixed by extracting the first two-thirds of the chain into `macOSLayoutBase` and having `macOSLayout` call `macOSLayoutBase` + the 6 trailing lifecycle modifiers (`.preferredColorScheme`, `.tint`, `.onChange` ×2, `.onAppear`, `.onDisappear`). This is the same pattern already used for `macViewport` in the same file. No `@unchecked Sendable`, no `nonisolated(unsafe)` — the Swift 6 concurrency migration from Task 2 was entirely unnecessary under Swift 5.9.

---

## Fix: macOS-only pack bundling

**Review findings addressed:** (A) MPNN.mpnnpack was added to the iOS target too (spec violation); (B) xcodegen emitted it as a flat file group so Bundle.main.url(forResource:) returned nil.

### What moved
`swiftui/PyMOLViewer/Resources/MPNN.mpnnpack` → `swiftui/resources_macos/MPNN.mpnnpack`
Moved outside the auto-scanned `PyMOLViewer/` tree so xcodegen no longer adds it to any target's Copy Bundle Resources phase.

### project.yml changes
- Removed the `resources:` block entry (`path: PyMOLViewer/Resources/MPNN.mpnnpack`, `type: folder`, `platforms: [macOS]`) — the per-platform filter was not being honoured.
- Added a new `postBuildScripts` step `"macOS: Bundle MPNN.mpnnpack"` guarded by `case "$PLATFORM_NAME" in macosx*)` that `cp -R`s the directory from `${SRCROOT}/resources_macos/MPNN.mpnnpack` into `${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Resources/`, preserving the nested directory structure that Bundle lookup requires.

### macOS build result
`** BUILD SUCCEEDED **` — commit `43fb4a7e8`.

### Gate A: pack bundled as a directory (finding B)
Confirmed. Built app path:
`swiftui/build_mac_dd/Build/Products/Debug/RayMol.app/Contents/Resources/MPNN.mpnnpack/`
- `manifest.json` present
- `weights/design.safetensors` present
- `weights/packer.safetensors` present
All as nested real directories (not flat files).

### Gate B: iOS pbxproj weights-free (finding A)
Confirmed. `grep design.safetensors|packer.safetensors|MPNN.mpnnpack` against `PyMOLViewer.xcodeproj/project.pbxproj` finds ZERO entries in any PBXResourcesBuildPhase. The only MPNN references are: `MPNNGate.swift` (Swift source, gated by `#if RAYMOL_MPNN`), the post-build script shell strings, and the MPNNKit package product (macOS-only `platforms: [macOS]`).
