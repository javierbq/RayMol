# RayMol Design mode on iOS/iPad (#217 Phase 2d) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Design mode — on-device ProteinMPNN inference via MPNNKit — available on iPhone and iPad, with the memory safety a 2 GB-class workload needs on a platform that kills processes without warning.

**Architecture:** The five Design Swift files already live in `Shared/`, are already members of the iOS target, and are already platform-neutral — they compile today as empty translation units because `RAYMOL_MPNN` is undefined for the iOS SDK. So this is a port, not a rewrite: open the build gate, add an iOS entry point and a compact iPhone layout, replace one mouse-only affordance with a touch one, and add three new pure files (`DesignAvailability`, `DesignSizeGuard`, `MPNNRuntime`) that carry all the new risk in unit-testable form. Design domain logic, the Python helper layer (`raymol_design.py`), and the 21 closure contracts between them are untouched.

**Tech Stack:** Swift 5.9 / SwiftUI, MPNNKit (`javierbq/proteinmpnn-mlx`, `from: 0.1.2`) wrapping mlx-swift 0.31.6, xcodegen-generated Xcode project, XCTest, embedded CPython + PyMOL C++ core.

**Spec:** `docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md`

## Global Constraints

- **Git flow:** never commit or push to `master`. Work on `claude/raymol-217-design-ios-phase2d`, open a PR into `master`. Use `gh -R javierbq/RayMol` for every `gh` command — `gh` otherwise defaults to the upstream `schrodinger/pymol-open-source`.
- **Worktree:** all edits go in `/Users/jcastellanos/repos/RayMol/.claude/worktrees/nostalgic-cartwright-b21efe`. Editing main-repo paths means the build will not see the change.
- **Never mutate the user's original object in place.** Every Design result is a new object. This is a standing Design-mode invariant from Phase 2b.
- **Index spaces:** `editedSequence` is FULL-LENGTH (indexed like `set.residues`); `design()` / `score()` / `repack()` operate in VALID-PROJECTED space (`L = validResidues.count`). Convert only via `validFullIndices` / `fullToValid`. Never mix them.
- **iOS deployment target:** `17.0` (forced — MPNNKit and mlx-swift both declare `.iOS(.v17)`). Design mode is offered only on **iOS 18+** at runtime.
- **Do NOT bump** `appkit/ios.toolchain.cmake:26` (`CMAKE_OSX_DEPLOYMENT_TARGET "16.0"`). A static library built for an older minimum links cleanly into a 17.0 app; bumping forces a full iOS deps rebuild for no benefit.
- **macOS behaviour must not regress.** The size guard is bypassed on macOS (swap makes the question meaningless). All 57 existing unit tests must still pass.
- **`project.pbxproj` is generated.** Never hand-edit it. Run `cd swiftui && xcodegen generate` after any `project.yml` change.
- **Keep the MPNNKit dependency OUTSIDE the `RAYMOL_SPARKLE_BEGIN`/`RAYMOL_SPARKLE_END` markers** in `project.yml`, or `archive_appstore.sh`'s sed-strip will delete it from the Mac App Store build.
- **Test commands** (run from repo root unless noted):
  - Swift unit: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/<Class> 2>&1 | tail -40`
  - Swift build (macOS): `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
  - Swift build (iOS simulator): `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
  - On-host inference: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS_Inference -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignEditInferenceTests 2>&1 | tail -40`
  - Python: `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`
- **Every new Swift file must be wrapped in `#if RAYMOL_MPNN` … `#endif`**, matching the five existing Design files. Files under `swiftui/PyMOLViewer/Shared/` are auto-discovered by xcodegen — no `project.yml` edit is needed to add one.
- **Commit after every task.** Message style: `feat(design):`, `fix(design):`, `test(design):`, `build(ios):`, `docs:`.

## File Structure

**New files**

| Path | Responsibility |
|---|---|
| `swiftui/PyMOLViewer/Shared/DesignAvailability.swift` | Is Design mode offered on this build + OS? Pure. |
| `swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift` | Predict inference peak memory; decide ok / warn / refuse. Pure. |
| `swiftui/PyMOLViewer/Shared/MPNNRuntime.swift` | The ONLY file importing MLX. Buffer-cache clamp + simulator CPU fallback. |
| `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift` | iPhone four-row docked panel + settings sheet. |
| `swiftui/PyMOLViewerTests/DesignAvailabilityTests.swift` | Tests for the OS gate. |
| `swiftui/PyMOLViewerTests/DesignSizeGuardTests.swift` | Tests for the memory policy. |
| `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` | Tests for region-edit routing, model release, cache bound. |

**Modified files**

| Path | Change |
|---|---|
| `swiftui/project.yml` | Gate for iOS SDK, drop macOS platform filters, floor 17.0, weight-pack copy, add `mlx-swift` package. |
| `swiftui/archive_appstore.sh` | `-skipPackagePluginValidation` on the iOS branch. |
| `swiftui/resources_macos/` → `swiftui/resources_mpnn/` | Directory rename (2 references, both in `project.yml`). |
| `swiftui/PyMOLViewer/Shared/DesignController.swift` | `regionEditMode`, `tapResidue`, size-guard consult, `releaseModel`, `clearError`. |
| `swiftui/PyMOLViewer/Shared/DesignScoreCache.swift` | Bounded with FIFO eviction. |
| `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` | `releaseModel` closure, `MPNNRuntime.configureOnce()` before inference. |
| `swiftui/PyMOLViewer/Shared/ContentView.swift` | Rail pill, docked slots ×4, `anyTop` ×3, lifecycle hoist, error banner, `#if os(macOS)` on shift-click, popover adaptation, `PYMOL_AUTODESIGN`. |
| `swiftui/PyMOLViewer/Shared/MetalViewport.swift` | Design branch in `handleTap`. |
| `.github/workflows/raymol-embedded-tests.yml` | Add the 5 Python design test files. |

**Task order rationale:** Task 1 (error surfacing) lands first because it makes every later failure diagnosable. Tasks 2–7 are pure logic, fully testable on macOS with no iOS work at all. Tasks 8–9 open the build. Tasks 10–12 are UI. Tasks 13–15 verify.

---

### Task 1: Surface `errorText` so Design failures stop being silent

`errorText` is written in six places in `DesignController` (`:16`, `:266`, `:391`, `:413`, `:423`, `:679`) and read **nowhere in the app** — only by `DesignRegionTests.swift:246`. Every failure mode this phase introduces (missing weight pack, refused run, MLX throw) would be invisible without this.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift` (add `clearError()` near `exit()`, ~line 272)
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (new `DesignErrorBanner` view; attach inside `DesignOverlayView.body`)
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (new file)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `DesignController.clearError()`; `DesignErrorBanner` (private to ContentView.swift). Later tasks set `errorText` and rely on this banner to display it.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift`:

```swift
#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignIOSPortTests: XCTestCase {

    func makeController() -> DesignController {
        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        return DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }

    private func allValid(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    // A failed region redesign must leave a message the UI can render, and
    // clearError() must be the way it goes away (the banner's dismiss path).
    func testClearErrorResetsErrorText() async {
        let c = makeController()
        c.injectRegion(designRegion: { _, _, _, _, _ in [] },   // wrong length → failure
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertEqual(c.errorText, "Region redesign failed",
                       "a failed redesign must leave a user-visible message")

        c.clearError()
        XCTAssertNil(c.errorText, "clearError must clear the message the banner shows")
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: FAIL — compile error `value of type 'DesignController' has no member 'clearError'`.

- [ ] **Step 3: Add `clearError()` to DesignController**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`, immediately after the closing brace of `exit()` (currently line 272), insert:

```swift

    /// Dismiss the current error message. The Design overlay's error banner calls
    /// this on tap and on its auto-dismiss timer; `errorText` is otherwise only
    /// cleared implicitly by the next successful operation.
    func clearError() { errorText = nil }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: PASS, 1 test.

- [ ] **Step 5: Add the banner view**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, immediately before `private struct DesignOverlayView: View {` (currently line 3646), insert:

```swift
// Error banner for Design mode. `errorText` was previously written in six places
// in DesignController and read nowhere, so every Design failure was silent —
// including a missing weight pack, which is the first thing that goes wrong on a
// new platform. Tap or wait to dismiss.
#if RAYMOL_MPNN
private struct DesignErrorBanner: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager

    var body: some View {
        if let text = controller.errorText {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.red.opacity(0.85))
            .contentShape(Rectangle())
            .onTapGesture { controller.clearError() }
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                controller.clearError()
            }
            .accessibilityLabel("Design error: \(text). Tap to dismiss.")
        }
    }
}
#endif
```

- [ ] **Step 6: Attach the banner to the overlay**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, inside `DesignOverlayView.body`, replace the opening of the `VStack` (currently line 3653, `VStack(spacing: 0) {`) and the main control strip's start so the banner sits at the top. Change:

```swift
        VStack(spacing: 0) {
            // ── Main control strip ──────────────────────────────────────
            HStack(spacing: 10) {
```

to:

```swift
        VStack(spacing: 0) {
            // ── Error banner (only when something failed) ───────────────
            DesignErrorBanner(controller: controller, theme: theme)
            // ── Main control strip ──────────────────────────────────────
            HStack(spacing: 10) {
```

- [ ] **Step 7: Verify the macOS app still builds and all tests pass**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 58 tests executed (57 existing + 1 new), 0 failures.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "$(cat <<'EOF'
fix(design): surface errorText in a banner instead of dropping it

errorText was written in six places in DesignController and read nowhere
outside a unit test, so every Design failure was silent. That is tolerable on
macOS where the console is one keystroke away and untenable on iOS, where the
first failure mode of a new platform (missing weight pack) would look like a
dead button.

Adds clearError() as the explicit dismiss path and a DesignErrorBanner at the
top of the Design overlay, tap- or timeout-dismissible.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `DesignAvailability` — gate the feature to iOS 18+

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignAvailability.swift`
- Test: `swiftui/PyMOLViewerTests/DesignAvailabilityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DesignAvailability.isSupported: Bool`, `DesignAvailability.isSupported(platform:osMajorVersion:) -> Bool`, `DesignAvailability.Platform` (`.macOS` / `.iOS`), `DesignAvailability.minimumIOSMajorVersion: Int`. Task 10 guards the rail pill with `isSupported`.

The pure function takes the platform as a **parameter** rather than reading `#if os(iOS)`, specifically so the macOS test host can verify the iOS rule. A version of this that branched on the compiled platform would be untestable — the tests run on macOS and would only ever exercise the macOS arm.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/DesignAvailabilityTests.swift`:

```swift
#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignAvailabilityTests: XCTestCase {

    // iOS 18 is the only configuration ever validated on real hardware; 17 merely
    // resolves in SPM. Design must be absent below 18 rather than present-and-unproven.
    func testIOSRequires18() {
        XCTAssertFalse(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 17))
        XCTAssertFalse(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 16))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 18))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .iOS, osMajorVersion: 26))
    }

    // macOS shipped Design in Phase 2a; its availability must not change.
    func testMacOSAlwaysSupported() {
        XCTAssertTrue(DesignAvailability.isSupported(platform: .macOS, osMajorVersion: 14))
        XCTAssertTrue(DesignAvailability.isSupported(platform: .macOS, osMajorVersion: 26))
    }

    func testMinimumIsEighteen() {
        XCTAssertEqual(DesignAvailability.minimumIOSMajorVersion, 18)
    }

    // The live property must agree with the pure function for the running host.
    func testLivePropertyMatchesPureFunction() {
        XCTAssertEqual(DesignAvailability.isSupported,
                       DesignAvailability.isSupported(platform: DesignAvailability.current,
                                                      osMajorVersion: DesignAvailability.currentOSMajorVersion))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignAvailabilityTests 2>&1 | tail -40`

Expected: FAIL — compile error `cannot find 'DesignAvailability' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/DesignAvailability.swift`:

```swift
#if RAYMOL_MPNN
import Foundation

/// Whether Design mode may be offered on this build and OS.
///
/// Design mode is compiled in for both macOS and iOS (RAYMOL_MPNN), but on iOS
/// the only configuration ever validated on physical hardware is iOS 18 —
/// mlx-swift's Metal path is unverified on iOS 17, which SPM nonetheless
/// resolves. Rather than ship an unverified path or raise the whole app's floor
/// to 18 (which would cost every iOS 17 user the app, not just Design), the
/// feature itself is gated and simply absent below 18.
///
/// See docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §4.
enum DesignAvailability {

    enum Platform { case macOS, iOS }

    /// Minimum iOS major version on which Design mode is offered.
    static let minimumIOSMajorVersion = 18

    /// Pure decision. `platform` is a parameter rather than a `#if` branch so the
    /// macOS test host can verify the iOS rule; a compile-time branch would leave
    /// the iOS arm permanently untested.
    static func isSupported(platform: Platform, osMajorVersion: Int) -> Bool {
        switch platform {
        case .macOS: return true
        case .iOS:   return osMajorVersion >= minimumIOSMajorVersion
        }
    }

    /// The platform this binary was compiled for.
    static var current: Platform {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }

    static var currentOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// True when Design mode should be offered. Callers must not build any Design
    /// entry point — rail pill, menu item, docked panel — when this is false.
    static var isSupported: Bool {
        isSupported(platform: current, osMajorVersion: currentOSMajorVersion)
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignAvailabilityTests 2>&1 | tail -40`

Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignAvailability.swift swiftui/PyMOLViewerTests/DesignAvailabilityTests.swift
git commit -m "$(cat <<'EOF'
feat(design): add DesignAvailability, gating Design mode to iOS 18+

MPNNKit forces the app's iOS floor to 17.0, but the only configuration ever run
on physical hardware is 18.0. Gating the feature rather than the app means no
iOS 17 user loses RayMol and nothing unverified ships.

The pure decision takes the platform as a parameter instead of branching on
#if os(iOS), so the macOS test host can actually exercise the iOS rule.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `DesignSizeGuard` — predict peak memory, decide warn vs refuse

The two-tier policy as a pure function. This is where all the memory risk lives, and it is deliberately arithmetic so it can be tested exhaustively without a device.

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift`
- Test: `swiftui/PyMOLViewerTests/DesignSizeGuardTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `DesignSizeGuard.Decision` (`.ok` / `.warn(estimatedBytes:availableBytes:)` / `.refuse(maxFittingResidues:)`), `DesignSizeGuard.evaluate(residueCount:availableBytes:)`, `DesignSizeGuard.estimatedBytes(residueCount:)`, `DesignSizeGuard.maxFittingResidues(availableBytes:)`, `DesignSizeGuard.availableBytesNow: Int`. Task 4 calls `evaluate` from `DesignController`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/DesignSizeGuardTests.swift`:

```swift
#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignSizeGuardTests: XCTestCase {

    // 4 GiB of remaining budget. With fixedOverhead 160 MiB (167_772_160 B) and
    // 1.4 MB/residue, the ok ceiling is 2_147_483_648 and the refuse floor is
    // 3_221_225_472. Every expectation below is arithmetic on those two numbers.
    private let fourGiB = 4_294_967_296

    func testComfortableSizeIsOK() {
        // 1000 residues -> 1_567_772_160 B, well under 50% of 4 GiB.
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1000, availableBytes: fourGiB), .ok)
    }

    func testJustUnderOkCeilingIsStillOK() {
        // 1400 residues -> 2_127_772_160 B <= 2_147_483_648 B.
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1400, availableBytes: fourGiB), .ok)
    }

    func testMidBandWarns() {
        // 1500 residues -> 2_267_772_160 B: over 50%, under 75%.
        XCTAssertEqual(
            DesignSizeGuard.evaluate(residueCount: 1500, availableBytes: fourGiB),
            .warn(estimatedBytes: 2_267_772_160, availableBytes: fourGiB))
    }

    func testOversizeRefusesAndReportsWhatWouldFit() {
        // 2300 residues -> 3_387_772_160 B, past the 3_221_225_472 B refuse floor.
        XCTAssertEqual(
            DesignSizeGuard.evaluate(residueCount: 2300, availableBytes: fourGiB),
            .refuse(maxFittingResidues: 2180))
    }

    func testMaxFittingIsTheBoundaryItClaims() {
        let maxFit = DesignSizeGuard.maxFittingResidues(availableBytes: fourGiB)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: maxFit, availableBytes: fourGiB),
                       .warn(estimatedBytes: DesignSizeGuard.estimatedBytes(residueCount: maxFit),
                             availableBytes: fourGiB),
                       "the largest 'fitting' size must not itself be refused")
        if case .refuse = DesignSizeGuard.evaluate(residueCount: maxFit + 1, availableBytes: fourGiB) {
            // expected
        } else {
            XCTFail("one residue past maxFittingResidues must refuse")
        }
    }

    // A budget smaller than the model's own footprint cannot fit anything.
    func testTinyBudgetRefusesWithZero() {
        XCTAssertEqual(DesignSizeGuard.maxFittingResidues(availableBytes: 100_000_000), 0)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1, availableBytes: 100_000_000),
                       .refuse(maxFittingResidues: 0))
    }

    // availableBytes <= 0 means "unknown budget" (macOS, where swap makes the
    // question meaningless). Shipped macOS behaviour must not change.
    func testUnknownBudgetAlwaysOK() {
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 100_000, availableBytes: 0), .ok)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 100_000, availableBytes: -1), .ok)
    }

    func testZeroResiduesIsOK() {
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 0, availableBytes: fourGiB), .ok)
    }

    // Guards the derivation: the constants must still match the measured slope.
    func testEstimateMatchesMeasuredModel() {
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 0), 167_772_160)
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 1000), 1_567_772_160)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignSizeGuardTests 2>&1 | tail -40`

Expected: FAIL — compile error `cannot find 'DesignSizeGuard' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift`:

```swift
#if RAYMOL_MPNN
import Foundation
#if os(iOS)
import os
#endif

/// Predicts the peak memory an MPNN inference run will need and decides whether
/// to proceed silently, warn, or refuse.
///
/// This exists because overshoot on iOS is unrecoverable in two independent ways:
/// jetsam is an uncatchable SIGKILL, and mlx-swift's default error handler prints
/// then exits (mlx-swift/Source/MLX/ErrorHandler.swift:4), so DesignController's
/// do/catch can never observe an allocation failure. The only workable strategy is
/// prediction before dispatch.
///
/// Constants derive from a physical-device measurement (iPhone 15 Pro, 8 GB) in
/// docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §2:
/// MLX peak active memory is linear in residue count, slope 1.32 MB/residue,
/// intercept ~55 MB. Retune all four numbers together from device data (Task 15).
enum DesignSizeGuard {

    // MARK: – Tunable constants

    /// Marginal cost of one residue. Measured slope 1.32 MB, rounded up for margin.
    static let bytesPerResidue = 1_400_000
    /// Model-resident floor: measured ~55 MB intercept + the 96 MB MLX cache clamp.
    static let fixedOverheadBytes = 160 * 1024 * 1024   // 167_772_160
    /// At or below this fraction of the remaining budget, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction of the remaining budget, refuse.
    ///
    /// The 25% reserve is not arbitrary padding: MLX's reported peak EXCLUDES its
    /// buffer cache (mlx-swift/Source/MLX/Memory.swift:171-178), so true
    /// phys_footprint runs above this estimate by an amount nobody has measured.
    static let warnFraction = 0.75

    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingResidues: Int)
    }

    /// Predicted peak bytes for `residueCount` residues.
    static func estimatedBytes(residueCount: Int) -> Int {
        fixedOverheadBytes + max(0, residueCount) * bytesPerResidue
    }

    /// Largest residue count that stays inside `warnFraction` of `availableBytes`.
    /// Zero when even the fixed overhead does not fit.
    static func maxFittingResidues(availableBytes: Int) -> Int {
        let ceiling = Double(availableBytes) * warnFraction - Double(fixedOverheadBytes)
        guard ceiling > 0 else { return 0 }
        return Int(ceiling / Double(bytesPerResidue))
    }

    /// Two-tier policy. `availableBytes <= 0` means "budget unknown" and always
    /// yields `.ok` — that is the macOS path, where swap makes the question
    /// meaningless and shipped behaviour must not change.
    static func evaluate(residueCount: Int, availableBytes: Int) -> Decision {
        guard availableBytes > 0, residueCount > 0 else { return .ok }
        let estimate = estimatedBytes(residueCount: residueCount)
        let available = Double(availableBytes)
        if Double(estimate) <= available * okFraction { return .ok }
        if Double(estimate) <= available * warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
        }
        return .refuse(maxFittingResidues: maxFittingResidues(availableBytes: availableBytes))
    }

    /// Remaining memory budget for this process, or 0 when unknown.
    ///
    /// os_proc_available_memory() reports what is left before this app is jetsammed,
    /// which already accounts for whatever structures are loaded — that is why the
    /// policy uses it instead of a static residue cap.
    static var availableBytesNow: Int {
        #if os(iOS)
        return os_proc_available_memory()
        #else
        return 0
        #endif
    }

    /// Human-readable size for the warn/refuse copy, e.g. "2.3 GB".
    static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignSizeGuardTests 2>&1 | tail -40`

Expected: PASS, 9 tests. If `testOversizeRefusesAndReportsWhatWouldFit` fails on the exact value 2180, do **not** change the test to match the code — recompute by hand and fix whichever is wrong.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift swiftui/PyMOLViewerTests/DesignSizeGuardTests.swift
git commit -m "$(cat <<'EOF'
feat(design): add DesignSizeGuard, predicting MPNN peak memory before dispatch

Overshoot on iOS is unrecoverable twice over: jetsam is an uncatchable SIGKILL,
and mlx-swift's default error handler prints then exits, so no do/catch can ever
see an allocation failure. Prediction before dispatch is the only strategy left.

Constants derive from the measured iPhone 15 Pro curve (1.32 MB/residue, ~55 MB
intercept), rounded up and paired with a 25% reserve because MLX's reported peak
excludes its buffer cache. Pure arithmetic, so the boundaries are tested exactly
rather than approximated on a device.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Enforce the size guard in `DesignController`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (extend)

**Interfaces:**
- Consumes: `DesignSizeGuard.Decision`, `DesignSizeGuard.evaluate(residueCount:availableBytes:)`, `DesignSizeGuard.availableBytesNow`, `DesignSizeGuard.formatted(bytes:)` (Task 3); `DesignController.clearError()` (Task 1).
- Produces: `DesignController.availableMemoryProvider: () -> Int` (injectable), `DesignController.pendingSizeWarning: SizeWarning?`, `DesignController.confirmPendingWarning()`, `DesignController.cancelPendingWarning()`, `DesignController.SizeWarning` (`residueCount`, `estimatedBytes`, `availableBytes`), `DesignController.autosaveBeforeLargeRun: () -> Void` (injectable). Task 11 renders the warning; Task 12 wires the autosave.

Design note: the guard is consulted in `redesignSelectionAwait()` only. `repackNowAwait()` and focus scoring run over the same residue set, so a redesign that passes the guard implies its follow-ups do too — adding three separate confirmation prompts to one user action would be hostile. Focus scoring is not gated at all: it is what populates the sequence strip, and refusing it would make the object unopenable rather than merely un-redesignable.

- [ ] **Step 1: Write the failing tests**

Append inside `final class DesignIOSPortTests: XCTestCase { … }` in `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift`, before the closing brace:

```swift

    // A run predicted to exceed the budget must never reach the inference queue.
    func testOversizeRedesignIsRefusedWithoutRunningInference() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        // 100 MB of headroom cannot even hold the model.
        c.availableMemoryProvider = { 100_000_000 }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()

        XCTAssertEqual(designCalls, 0, "a refused run must not dispatch inference")
        XCTAssertNotNil(c.errorText, "a refused run must explain itself")
        XCTAssertNil(c.pendingSizeWarning, "refuse is terminal, not a confirmation")
    }

    // In the warn band the run is held pending explicit confirmation, and the
    // autosave fires first so a jetsam kill costs no work.
    func testWarnBandHoldsRunUntilConfirmedAndAutosavesFirst() async {
        let c = makeController()
        var designCalls = 0
        var autosaves = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.autosaveBeforeLargeRun = { autosaves += 1 }
        // Budget chosen so 3 residues land in the warn band: estimate is
        // 167_772_160 + 3*1_400_000 = 171_972_160; ok ceiling 0.50*B, refuse 0.75*B.
        // B = 250_000_000 -> ok 125_000_000, refuse 187_500_000. 171.97M is between.
        c.availableMemoryProvider = { 250_000_000 }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertEqual(designCalls, 0, "warn must hold the run, not start it")
        XCTAssertNotNil(c.pendingSizeWarning)
        XCTAssertEqual(c.pendingSizeWarning?.residueCount, 3)
        XCTAssertEqual(autosaves, 0, "autosave belongs to the confirm path, not the prompt")

        await c.confirmPendingWarning()
        XCTAssertEqual(autosaves, 1, "confirming must autosave before dispatching")
        XCTAssertEqual(designCalls, 1, "confirming must actually run the design")
        XCTAssertNil(c.pendingSizeWarning)
    }

    func testCancellingWarningRunsNothing() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.availableMemoryProvider = { 250_000_000 }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.pendingSizeWarning)
        c.cancelPendingWarning()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 0)
    }

    // macOS reports an unknown budget (0) and must behave exactly as before.
    func testUnknownBudgetNeverBlocks() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.availableMemoryProvider = { 0 }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: FAIL — compile error `value of type 'DesignController' has no member 'availableMemoryProvider'`.

- [ ] **Step 3: Add the state and injection points**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`, immediately after the `designTemperature` declaration (currently line 153), insert:

```swift
    /// Pending oversize confirmation, or nil. Set when a redesign lands in the
    /// guard's warn band; the UI presents it and calls confirm/cancel.
    @Published private(set) var pendingSizeWarning: SizeWarning?

    /// A run large enough to be worth confirming. `residueCount` is the total
    /// object length, not the selection size — MPNN's cost tracks the whole
    /// object regardless of how few positions are free.
    struct SizeWarning: Equatable {
        let residueCount: Int
        let estimatedBytes: Int
        let availableBytes: Int
    }

    /// Remaining process memory in bytes, or 0 when unknown. Injectable so the
    /// policy can be tested without a device; defaults to the real iOS query.
    var availableMemoryProvider: () -> Int = { DesignSizeGuard.availableBytesNow }

    /// Write a session autosave before a confirmed large run, so a jetsam kill
    /// costs no user work. Wired to the engine in PyMOLEngine; no-op in tests.
    var autosaveBeforeLargeRun: () -> Void = { }
```

- [ ] **Step 4: Consult the guard in `redesignSelectionAwait`**

In the same file, in `redesignSelectionAwait()`, immediately after the existing guard block (currently lines 635-638) and **before** `redesignSnapshot` is assigned, insert:

```swift
        // Memory gate. Consulted here only: repack and rescore run over the same
        // residue set, so clearing this gate clears them too, and three prompts for
        // one user action would be hostile. Focus scoring is deliberately ungated —
        // it is what populates the sequence strip, and refusing it would make an
        // object unopenable rather than merely un-redesignable.
        let residueCount = set.residues.count
        switch DesignSizeGuard.evaluate(residueCount: residueCount,
                                        availableBytes: availableMemoryProvider()) {
        case .ok:
            break
        case .warn(let estimate, let available):
            pendingSizeWarning = SizeWarning(residueCount: residueCount,
                                             estimatedBytes: estimate,
                                             availableBytes: available)
            return
        case .refuse(let maxFitting):
            pendingSizeWarning = nil
            errorText = maxFitting > 0
                ? "This structure is too large to design on this device (\(residueCount) residues; about \(maxFitting) would fit). Free memory or use a smaller structure."
                : "Not enough free memory to run Design. Close other apps and try again."
            return
        }
```

Note the ordering: this sits **after** `beginEditIfNeeded()` and the `set` lookup so `residueCount` is available, but **before** `redesignSnapshot` is written — a refused run must leave no revert state behind.

- [ ] **Step 5: Add confirm and cancel**

In the same file, immediately after `redesignSelectionAwait()`'s closing brace (currently line 709), insert:

```swift

    /// Proceed with a redesign the user confirmed after a size warning. Writes an
    /// autosave first so a jetsam kill during the run costs no work, then re-enters
    /// the normal path with the guard suppressed for this one call.
    func confirmPendingWarning() async {
        guard pendingSizeWarning != nil else { return }
        pendingSizeWarning = nil
        autosaveBeforeLargeRun()
        suppressSizeGuardOnce = true
        await redesignSelectionAwait()
    }

    /// Dismiss a size warning without running anything.
    func cancelPendingWarning() { pendingSizeWarning = nil }
```

- [ ] **Step 6: Add the one-shot suppression flag**

Without this, a confirmed run re-enters `redesignSelectionAwait()`, hits the guard again, and warns forever.

In the same file, immediately after the `availableMemoryProvider` declaration added in Step 3, insert:

```swift
    /// Set for exactly one call by `confirmPendingWarning()` so the confirmed run
    /// is not re-gated into an infinite warn loop. Cleared on read.
    private var suppressSizeGuardOnce = false
```

Then replace the two lines at the top of the Step 4 block:

```swift
        let residueCount = set.residues.count
        switch DesignSizeGuard.evaluate(residueCount: residueCount,
                                        availableBytes: availableMemoryProvider()) {
```

with:

```swift
        let residueCount = set.residues.count
        let skipGuard = suppressSizeGuardOnce
        suppressSizeGuardOnce = false
        let sizeDecision: DesignSizeGuard.Decision = skipGuard
            ? .ok
            : DesignSizeGuard.evaluate(residueCount: residueCount,
                                       availableBytes: availableMemoryProvider())
        switch sizeDecision {
```

Binding the decision to a `let` first keeps the `switch` subject a plain value — a ternary inline in the `switch` subject compiles but is needlessly hard to read and to edit later.

- [ ] **Step 7: Clear the pending warning on teardown**

In `clearRegionState()` (currently lines 616-624), add one line before `designToken += 1`:

```swift
        pendingSizeWarning = nil
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: PASS, 5 tests.

- [ ] **Step 9: Verify no regression in the existing suite**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`

Expected: `** TEST SUCCEEDED **`, 0 failures. The existing `DesignRegionTests` must all still pass — they use the default `availableMemoryProvider`, which returns 0 on macOS and therefore never gates.

- [ ] **Step 10: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "$(cat <<'EOF'
feat(design): gate region redesign on predicted memory, warn then refuse

Consults DesignSizeGuard before dispatching a redesign: proceed silently under
50% of the remaining budget, hold for explicit confirmation up to 75%, refuse
above it with the size that would fit. Confirming writes an autosave first, so
a jetsam kill during a large run costs no work.

Gated at the redesign only. Repack and rescore run over the same residue set, so
clearing this gate clears them; focus scoring stays ungated because refusing it
would make an object unopenable rather than merely un-redesignable.

availableMemoryProvider is injectable and returns 0 on macOS, where swap makes
the question meaningless — macOS behaviour is unchanged.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Release the MPNN model on exit, on the inference queue

`_mpnnModel` (`PyMOLEngine.swift:1958`) is loaded once and never released. On macOS that is a harmless cache; on iOS it is resident weights held for the life of the process.

**The concurrency trap:** `_mpnnModel` is an unsynchronized stored property read only from the serial `io.raymol.design.inference` queue (`DesignController.swift:176`). Nilling it from the main thread would race an in-flight inference. The release must be **enqueued onto that same queue**, which also means it naturally happens *after* any running job.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `DesignController.ReleaseModelFn = () -> Void`, `DesignController.injectReleaseModel(_:)` (DEBUG), and a `releaseModel:` parameter on the initializer (defaulted, so no existing call site breaks).

- [ ] **Step 1: Write the failing test**

Append inside `DesignIOSPortTests`:

```swift

    // Exiting Design mode must free the ~model-resident weights, and must do it on
    // the inference queue so it can never race a running job.
    func testExitReleasesModelOffTheMainThread() {
        let c = makeController()
        let released = expectation(description: "model released")
        var releasedOnMain = true
        c.injectReleaseModel {
            releasedOnMain = Thread.isMainThread
            released.fulfill()
        }
        c.exit()
        wait(for: [released], timeout: 2.0)
        XCTAssertFalse(releasedOnMain,
                       "release must run on the inference queue, not the main thread")
    }

    // Release is ordered behind any queued inference, which is what makes it safe.
    func testReleaseIsOrderedAfterInFlightInference() async {
        let c = makeController()
        var order: [String] = []
        let done = expectation(description: "released")
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           order.append("design")
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectReleaseModel { order.append("release"); done.fulfill() }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        c.exit()
        await fulfillment(of: [done], timeout: 2.0)
        XCTAssertEqual(order, ["design", "release"],
                       "release must not jump ahead of inference already dispatched")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: FAIL — `value of type 'DesignController' has no member 'injectReleaseModel'`.

- [ ] **Step 3: Add the closure type, storage, and initializer parameter**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`, after the `SelectedIndicesFn` typealias (line 85), add:

```swift
    /// Release the cached MPNN model. Invoked on the inference queue from `exit()`,
    /// never on the main thread — the model is owned by that queue.
    typealias ReleaseModelFn = () -> Void
```

After the `selectedIndicesFn` stored property (line 113), add:

```swift
    private var releaseModelFn: ReleaseModelFn = { }
```

In the initializer, change the final parameter line (line 218) from:

```swift
                     selectedIndices: @escaping SelectedIndicesFn = { _, _, _, _ in [] }) {
```

to:

```swift
                     selectedIndices: @escaping SelectedIndicesFn = { _, _, _, _ in [] },
                     releaseModel: @escaping ReleaseModelFn = { }) {
```

and after `self.selectedIndicesFn = selectedIndices` (line 239) add:

```swift
        self.releaseModelFn = releaseModel
```

- [ ] **Step 4: Enqueue the release in `exit()`**

In `exit()`, replace the final line (currently line 271):

```swift
        rescoreToken += 1; repackToken += 1   // cancel any in-flight scoring or repack
```

with:

```swift
        rescoreToken += 1; repackToken += 1   // cancel any in-flight scoring or repack
        // Free the model's resident weights. Dispatched to the inference queue
        // rather than run inline: `_mpnnModel` is unsynchronized and owned by that
        // serial queue, so a main-thread nil-out would race a running job. Queueing
        // it also orders the release behind any inference already dispatched.
        let release = releaseModelFn
        inferenceQueue.async { release() }
```

- [ ] **Step 5: Add the DEBUG injection hook**

In the `#if DEBUG` block, after `injectRegion` (ends line 998), add:

```swift

    /// Override the model-release closure for testing (Phase 2d).
    func injectReleaseModel(_ fn: @escaping ReleaseModelFn) {
        self.releaseModelFn = fn
    }
```

- [ ] **Step 6: Wire the real release in PyMOLEngine**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, in the `designController` construction, add a final argument after the `selectedIndices:` closure (the construction ends at line 2178 with `)`). Insert before that closing paren:

```swift
        ,
        releaseModel: { [weak self] in
            // Called on DesignController's inference queue, which is the only
            // context that touches _mpnnModel — see loadedMPNNModel().
            self?._mpnnModel = nil
        }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: PASS, 7 tests.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "$(cat <<'EOF'
feat(design): release the MPNN model when leaving Design mode

_mpnnModel was loaded once and never freed — a harmless cache on macOS, resident
weights held for the process lifetime on iOS.

The release is dispatched to the inference queue rather than run inline:
_mpnnModel is unsynchronized and effectively owned by that serial queue, so
nilling it from the main thread would race an in-flight job. Queueing also orders
the release behind any inference already dispatched, which the test asserts.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Bound `DesignScoreCache`

The cache key includes the sequence hash, so every single edit inserts a new entry that is never evicted. `invalidate(object:)` exists but is called from nowhere.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignScoreCache.swift`
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `DesignScoreCache.init(capacity:)`, `DesignScoreCache.defaultCapacity: Int`, `DesignScoreCache.count: Int`. `get`/`set`/`invalidate` signatures are unchanged, so `DesignController` needs no edit.

- [ ] **Step 1: Write the failing test**

Append inside `DesignIOSPortTests`:

```swift

    // The cache key includes the sequence hash, so every edit inserts a new entry.
    // Without a bound it grows for the whole session.
    func testCacheEvictsOldestPastCapacity() {
        let cache = DesignScoreCache(capacity: 3)
        func key(_ i: Int) -> DesignCacheKey {
            DesignCacheKey(object: "m1", state: 1, sequenceHash: i)
        }
        let scores = DesignScores(nativeFit: [-1], certainty: [0.5])
        for i in 0..<5 { cache.set(key(i), scores) }

        XCTAssertEqual(cache.count, 3, "cache must not grow past its capacity")
        XCTAssertNil(cache.get(key(0)), "oldest entry must be evicted")
        XCTAssertNil(cache.get(key(1)))
        XCTAssertNotNil(cache.get(key(4)), "newest entry must survive")
    }

    // Re-setting an existing key must refresh it in place, not consume a second slot.
    func testOverwritingAKeyDoesNotConsumeCapacity() {
        let cache = DesignScoreCache(capacity: 2)
        let k = DesignCacheKey(object: "m1", state: 1, sequenceHash: 7)
        cache.set(k, DesignScores(nativeFit: [-1], certainty: [0.1]))
        cache.set(k, DesignScores(nativeFit: [-2], certainty: [0.2]))
        cache.set(DesignCacheKey(object: "m1", state: 1, sequenceHash: 8),
                  DesignScores(nativeFit: [-3], certainty: [0.3]))

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.get(k)?.nativeFit, [-2], "overwrite must win, and survive")
    }

    func testInvalidateDropsOnlyTheNamedObject() {
        let cache = DesignScoreCache(capacity: 8)
        let scores = DesignScores(nativeFit: [-1], certainty: [0.5])
        cache.set(DesignCacheKey(object: "keep", state: 1, sequenceHash: 1), scores)
        cache.set(DesignCacheKey(object: "drop", state: 1, sequenceHash: 2), scores)
        cache.invalidate(object: "drop")

        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.get(DesignCacheKey(object: "keep", state: 1, sequenceHash: 1)))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: FAIL — `argument passed to call that takes no arguments` on `DesignScoreCache(capacity: 3)`.

- [ ] **Step 3: Replace the cache implementation**

In `swiftui/PyMOLViewer/Shared/DesignScoreCache.swift`, replace the `final class DesignScoreCache { … }` block (lines 23-28) with:

```swift
/// Bounded score cache with insertion-order (FIFO) eviction.
///
/// The key includes the sequence hash, so every edit inserts a fresh entry and an
/// unbounded dict grows for the whole session. Each entry holds three per-residue
/// arrays — including a 20-wide propensity row per residue — so a 2000-residue
/// object costs on the order of a megabyte.
///
/// FIFO rather than LRU is deliberate: the access pattern is "latest sequence
/// wins", so recency of *insertion* already tracks usefulness, and FIFO avoids
/// touching bookkeeping on every read.
final class DesignScoreCache {
    /// Retained entries. Roughly a session's worth of edits on one object.
    static let defaultCapacity = 24

    private let capacity: Int
    private var store: [DesignCacheKey: DesignScores] = [:]
    private var order: [DesignCacheKey] = []   // oldest first

    init(capacity: Int = DesignScoreCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { store.count }

    func get(_ key: DesignCacheKey) -> DesignScores? { store[key] }

    func set(_ key: DesignCacheKey, _ scores: DesignScores) {
        if store[key] == nil { order.append(key) }   // overwrite keeps its slot
        store[key] = scores
        while order.count > capacity {
            let oldest = order.removeFirst()
            store[oldest] = nil
        }
    }

    func invalidate(object: String) {
        store = store.filter { $0.key.object != object }
        order = order.filter { store[$0] != nil }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: PASS, 10 tests.

- [ ] **Step 5: Verify no regression**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`

Expected: `** TEST SUCCEEDED **`, 0 failures. Note `DesignController` constructs `DesignScoreCache()` with no arguments (line 173) and keeps working via the default.

- [ ] **Step 6: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignScoreCache.swift swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "$(cat <<'EOF'
feat(design): bound DesignScoreCache with FIFO eviction

The cache key includes the sequence hash, so every edit inserted an entry that
was never evicted — unbounded growth over a session, with each entry holding a
20-wide propensity row per residue.

FIFO rather than LRU: the access pattern is "latest sequence wins", so insertion
order already tracks usefulness and reads stay bookkeeping-free.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Region-edit mode — the touch replacement for shift-click

`TapGesture().modifiers(.shift)` at `ContentView.swift:3314-3318` is the **only** iOS compile error in the whole feature, and it is also the only way to build an ad-hoc region. Per spec §9 the replacement ships on both platforms; shift-click survives on macOS as a shortcut.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift`
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (extend)

**Interfaces:**
- Consumes: `toggleRegionResidue(residueIndex:)` and `setPinned(chain:resi:)` (both existing).
- Produces: `DesignController.regionEditMode: Bool` (`@Published`), `DesignController.tapResidue(residueIndex:)`. Task 10 calls `tapResidue` from the viewport; Task 11 renders the toggle.

- [ ] **Step 1: Write the failing tests**

Append inside `DesignIOSPortTests`:

```swift

    // Region-edit OFF: a plain tap pins for inspection, exactly as before.
    func testTapPinsWhenRegionEditModeIsOff() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        XCTAssertFalse(c.regionEditMode)

        c.tapResidue(residueIndex: 1)

        XCTAssertEqual(c.pinnedResidueIndex, 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "pinning must not build a region")
    }

    // Region-edit ON: the same tap toggles region membership and does not pin.
    func testTapTogglesRegionWhenRegionEditModeIsOn() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.regionEditMode = true

        c.tapResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [1])
        XCTAssertNil(c.pinnedResidueIndex, "region editing must not also pin")

        c.tapResidue(residueIndex: 0)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1], "region stays sorted")

        c.tapResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [0], "a second tap removes")
    }

    // Non-designable positions cannot enter a region, however they are tapped.
    func testTapIgnoresInvalidResiduesInRegionEditMode() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, false, true])
        c.regionEditMode = true

        c.tapResidue(residueIndex: 1)

        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "an invalid residue must never join the region")
    }

    // Leaving Design mode must not strand the toggle on for the next session.
    func testExitClearsRegionEditMode() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.regionEditMode = true

        c.exit()

        XCTAssertFalse(c.regionEditMode)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: FAIL — `value of type 'DesignController' has no member 'regionEditMode'`.

- [ ] **Step 3: Add the flag and the routing method**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`, after the `regionModeActive` computed property (line 155), add:

```swift

    /// True while the user is building an ad-hoc region by tapping positions.
    /// Replaces shift-click, which does not exist on touch (and whose SwiftUI
    /// modifier is unavailable on iOS). Ships on macOS too — the explicit toggle
    /// is the discoverable path; shift-click remains as a power-user shortcut.
    @Published var regionEditMode = false
```

After `toggleRegionResidue(residueIndex:)` (ends line 599), add:

```swift

    /// Route a plain tap on residue `i` (full-length index). In region-edit mode a
    /// tap toggles region membership; otherwise it pins the residue for inspection,
    /// which is the pre-existing behaviour.
    func tapResidue(residueIndex i: Int) {
        if regionEditMode {
            toggleRegionResidue(residueIndex: i)
            return
        }
        guard let obj = focusObject, let set = lastSet[obj],
              i >= 0, i < set.residues.count else { return }
        let r = set.residues[i]
        setPinned(chain: r.chain, resi: r.resi)
    }
```

In `clearRegionState()`, add one line alongside the other resets:

```swift
        regionEditMode = false
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -40`

Expected: PASS, 14 tests.

- [ ] **Step 5: Fix the iOS compile error and route the strip through `tapResidue`**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, replace lines 3311-3321 (the shift gesture and the plain tap):

```swift
        // Shift-click builds an ad-hoc region (add/remove this position); a plain
        // click still pins for single-residue inspection. The shift gesture takes
        // priority so it only fires when the modifier is held.
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                controller.toggleRegionResidue(residueIndex: i)
            }
        )
        .onTapGesture {
            controller.setPinned(chain: residue.chain, resi: residue.resi)
        }
```

with:

```swift
        // macOS keeps shift-click as a shortcut for building an ad-hoc region.
        // `TapGesture().modifiers(_:)` is unavailable on iOS — this was the single
        // iOS compile error in the whole Design feature. The cross-platform path is
        // controller.regionEditMode, which a plain tap honours (see tapResidue).
        #if os(macOS)
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                controller.toggleRegionResidue(residueIndex: i)
            }
        )
        #endif
        .onTapGesture {
            controller.tapResidue(residueIndex: i)
        }
```

- [ ] **Step 6: Add the toggle to the region strip**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, in `DesignRegionStripView.controls` (line 3357), insert after `selectionButton`:

```swift
            stripDivider
            regionEditToggle
```

and add this computed property to `DesignRegionStripView`, after `selectionButton` (ends line 3403):

```swift

    // Explicit region-building mode: while on, a plain tap on a sequence column or
    // in the viewport adds/removes that position. This is the touch replacement for
    // shift-click, and the discoverable path on macOS too.
    private var regionEditToggle: some View {
        Button {
            controller.regionEditMode.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.regionEditMode
                        ? "hand.tap.fill" : "hand.tap")
                    .font(.system(size: 10))
                Text("Tap to edit")
                    .font(.system(size: 11,
                                  weight: controller.regionEditMode ? .semibold : .regular))
            }
            .foregroundColor(controller.regionEditMode
                             ? .white : theme.active.panelText.color.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(controller.regionEditMode
                        ? theme.active.accent.color
                        : theme.active.panelText.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Build a region by tapping positions in the sequence or the structure")
        .accessibilityLabel("Tap to edit region, \(controller.regionEditMode ? "on" : "off")")
    }
```

- [ ] **Step 7: Verify both platforms compile**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

The iOS build cannot be verified yet — `RAYMOL_MPNN` is still undefined for iOS until Task 9, so this code is not compiled there. Task 9 Step 8 is where it is proven.

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "$(cat <<'EOF'
feat(design): add region-edit mode, replacing shift-click on touch

TapGesture().modifiers(.shift) is unavailable on iOS and was the single iOS
compile error in the entire Design feature — and it was also the only way to
build an ad-hoc region, so it could not simply be dropped.

regionEditMode makes a plain tap toggle region membership instead of pinning.
It ships on macOS too: the explicit toggle is the discoverable path, and
shift-click stays behind #if os(macOS) as the power-user shortcut.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `MPNNRuntime` — clamp the MLX cache and survive the simulator

Two non-negotiables, both established by the `proteinmpnn-ios` bench harness. RayMol has **no `import MLX` anywhere today** (verified repo-wide), so this file also introduces the direct MLX link.

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/MPNNRuntime.swift`
- Modify: `swiftui/project.yml` (add the `mlx-swift` package and the `MLX` product dependency)
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (call `configureOnce()` in `loadedMPNNModel()`)

**Interfaces:**
- Consumes: nothing.
- Produces: `MPNNRuntime.configureOnce()`, `MPNNRuntime.cacheLimitBytes: Int`.

**Why the package entry is needed:** `mlx-swift` reaches RayMol only *transitively*, as a dependency of MPNNKit (`proteinmpnn-ios/Package.swift:19`, pinned `exact: "0.31.6"`). Swift will not let you `import MLX` without a direct product dependency. Declaring it `from: 0.31.6` rather than `exact:` is deliberate — MPNNKit's `exact:` pin wins during resolution either way, so RayMol never has to be bumped in lockstep when MPNNKit moves.

- [ ] **Step 1: Add the mlx-swift package**

In `swiftui/project.yml`, in the `packages:` block, after the `proteinmpnn-mlx` entry (ends line 16, before the Sparkle comment), insert:

```yaml
  # mlx-swift, linked DIRECTLY rather than only transitively through MPNNKit, so
  # MPNNRuntime can set the process-wide buffer-cache limit and the simulator CPU
  # fallback — neither is reachable through MPNNKit's API. `from:` not `exact:`:
  # MPNNKit pins mlx-swift exactly and that pin wins during resolution, so this
  # entry never needs bumping in lockstep.
  mlx-swift:
    url: https://github.com/ml-explore/mlx-swift
    from: 0.31.6
```

- [ ] **Step 2: Link the MLX product to the app target**

In `swiftui/project.yml`, in the app target's `dependencies:` block, immediately after the `proteinmpnn-mlx` / `MPNNKit` entry (lines 448-452), insert:

```yaml
      - package: mlx-swift
        product: MLX
        platforms: [macOS]
```

The `platforms: [macOS]` filter here is temporary and is removed in Task 9 alongside MPNNKit's. Keeping it for this task means the iOS build stays exactly as it is today, so a failure in Task 8 cannot be confused with one from opening the gate.

- [ ] **Step 3: Regenerate the project**

Run: `cd swiftui && xcodegen generate 2>&1 | tail -5`
Expected: `Created project at .../PyMOLViewer.xcodeproj`

- [ ] **Step 4: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/MPNNRuntime.swift`:

```swift
#if RAYMOL_MPNN
import Foundation
import MLX

/// Process-wide MLX configuration. This is the ONLY file in RayMol that imports
/// MLX; everything else reaches MLX through MPNNKit.
///
/// Both settings below were established by the proteinmpnn-ios bench harness
/// (app/MPNNBench/MPNNBenchApp.swift) and are prerequisites for running inference
/// on iOS at all — see docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §6.1.
enum MPNNRuntime {

    /// Ceiling on MLX's buffer cache. Without it the pool was measured above 5 GB
    /// at L~1000, which is a guaranteed jetsam kill on any iPhone.
    static let cacheLimitBytes = 96 * 1024 * 1024

    /// Applied exactly once, thread-safely: a `static let` initializer is run at
    /// most once by the runtime, which is precisely the semantics wanted here.
    private static let applied: Void = {
        MLX.GPU.set(cacheLimit: cacheLimitBytes)

        #if targetEnvironment(simulator)
        // The iOS Simulator's Metal cannot allocate MLX's private-storage heaps
        // (MTLStorageModePrivate assertion), and its architecture()->name() is null
        // (std::string(nullptr) abort under iOS 26 libc++ hardening). Force the CPU
        // backend and supply an arch string so the pipeline can run in the Simulator.
        // Real devices use the GPU — this block is simulator-only, and without it the
        // first inference in any simulator ABORTS the process rather than throwing.
        setenv("MLX_METAL_GPU_ARCH", "applegpu_g15g", 1)
        MLX.Device.setDefault(device: Device(.cpu))
        #endif
    }()

    /// Idempotent; safe to call from any thread. Call before the first MPNNKit call.
    static func configureOnce() { _ = applied }
}
#endif
```

- [ ] **Step 5: Call it before the model loads**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, in `loadedMPNNModel()` (line 1959), insert as the new first statement of the function body:

```swift
        // Must precede any MLX allocation: sets the buffer-cache ceiling and, in a
        // simulator, switches MLX to the CPU backend (GPU there aborts).
        MPNNRuntime.configureOnce()
```

so the method reads:

```swift
    private func loadedMPNNModel() throws -> MPNNModel {
        // Must precede any MLX allocation: sets the buffer-cache ceiling and, in a
        // simulator, switches MLX to the CPU backend (GPU there aborts).
        MPNNRuntime.configureOnce()
        if let m = _mpnnModel { return m }
```

- [ ] **Step 6: Verify the macOS build and the real inference path**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. If `import MLX` fails, the package/product wiring in Steps 1-3 is wrong — do not work around it by importing MPNNKit instead.

Run the gated on-host inference suite, which actually exercises MLX with the clamp applied:
`cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS_Inference -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignEditInferenceTests 2>&1 | tail -40`
Expected: `** TEST SUCCEEDED **`. This loads the 24 MB weights and takes roughly 30–120 s. A failure here means the 96 MB clamp is too tight for the host path — report the number rather than silently raising it.

- [ ] **Step 7: Time-boxed spike — can MLX's fatal error handler be replaced? (spec §10)**

mlx-swift's default error handler *prints then exits* (`mlx-swift/Source/MLX/ErrorHandler.swift:4`). That is why `DesignController`'s `do/catch` (`:399-424`) and `try?` sites can never observe an allocation failure, and why `DesignSizeGuard` has to be preventive rather than reactive. If the handler is replaceable, a whole class of hard crashes becomes catchable.

Box this at 30 minutes. Read `ErrorHandler.swift` in the resolved package (find it under the SPM checkout, e.g. `~/Library/Developer/Xcode/DerivedData/*/SourcePackages/checkouts/mlx-swift/Source/MLX/ErrorHandler.swift`, or in `swiftui/build_ios_sim/SourcePackages/checkouts/`) and determine whether it exposes a public setter.

**Binary outcome, and it must be written down either way:**

- **If a public setter exists** — install a handler in `MPNNRuntime.applied` that records the message somewhere `DesignController` can read rather than terminating, and note in the commit body what it now catches. Be careful: MLX may expect the handler not to return, in which case throwing or longjmp-ing out of it is undefined. If the handler cannot safely return, treat that as "no" rather than shipping something unsound.
- **If no setter exists, or it cannot safely return** — add one line to `MPNNRuntime`'s doc comment recording the finding and the version checked, e.g. `// mlx-swift 0.31.6: no public error-handler override; allocation failures are fatal, which is why DesignSizeGuard is preventive.` Then move on.

What is not acceptable is leaving the question open — the next person will re-ask it.

- [ ] **Step 8: Commit**

```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj/project.pbxproj swiftui/PyMOLViewer/Shared/MPNNRuntime.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "$(cat <<'EOF'
feat(design): add MPNNRuntime — MLX cache clamp + simulator CPU fallback

Two prerequisites for running inference on iOS, both established by the
proteinmpnn-ios bench harness:

- The MLX buffer cache is unbounded by default and was measured above 5 GB at
  L~1000 — a guaranteed jetsam kill. Clamped to 96 MB.
- MLX ABORTS on first inference in any iOS Simulator (cannot allocate private
  storage heaps; null GPU arch string). The CPU-backend fallback is what makes a
  simulator test path possible at all.

Links mlx-swift directly, since neither setting is reachable through MPNNKit's
API and Swift needs a direct product dependency to import MLX. Declared `from:`
rather than `exact:` so MPNNKit's exact pin keeps winning and this entry never
needs bumping in lockstep.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Open the build gate for iOS

The seven build-config edits from spec §5. After this task the Design code compiles for iOS for the first time — expect the compiler to find things the `-typecheck` survey did not.

**Files:**
- Modify: `swiftui/project.yml`
- Modify: `swiftui/archive_appstore.sh`
- Rename: `swiftui/resources_macos/` → `swiftui/resources_mpnn/`

**Interfaces:**
- Consumes: everything from Tasks 1-8 (all of it must compile for iOS now).
- Produces: an iOS build with `RAYMOL_MPNN` defined, MPNNKit + MLX linked, and `MPNN.mpnnpack` in the bundle.

- [ ] **Step 1: Rename the resource directory**

```bash
git mv swiftui/resources_macos swiftui/resources_mpnn
```

The directory must stay **outside** `swiftui/PyMOLViewer/` — that is the whole reason it exists, so xcodegen never auto-adds it to a Copy Bundle Resources phase and the pack is copied exactly once, by the explicit script.

- [ ] **Step 2: Define `RAYMOL_MPNN` for the iOS SDK**

In `swiftui/project.yml`, replace lines 85-88:

```yaml
        # Design mode: RAYMOL_MPNN enables MPNNKit (ProteinMPNN inference) on macOS.
        # The [sdk=macosx*] conditional ensures this flag is never set for the iOS
        # slice of this shared target, keeping mlx-swift and MPNNKit out of iOS.
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]": "$(inherited) RAYMOL_MPNN"
```

with:

```yaml
        # Design mode: RAYMOL_MPNN enables MPNNKit (ProteinMPNN inference) on both
        # platforms as of Phase 2d. Kept as two per-SDK keys rather than one
        # unconditional setting so either slice can be turned off independently
        # without disturbing the other. Availability on iOS is additionally gated at
        # RUNTIME to iOS 18+ by DesignAvailability — see the Phase 2d spec §4.
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]": "$(inherited) RAYMOL_MPNN"
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphoneos*]": "$(inherited) RAYMOL_MPNN"
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=iphonesimulator*]": "$(inherited) RAYMOL_MPNN"
```

Both `iphoneos*` and `iphonesimulator*` are required — a single `iphone*` key is not a pattern Xcode expands.

- [ ] **Step 3: Raise the iOS deployment target**

In `swiftui/project.yml`, line 6, change:

```yaml
    iOS: "16.0"
```

to:

```yaml
    # 17.0 is forced: MPNNKit and mlx-swift both declare .iOS(.v17), and SPM
    # refuses to resolve below a dependency's floor. Design mode itself requires
    # iOS 18 at runtime (DesignAvailability) — the app does not.
    iOS: "17.0"
```

- [ ] **Step 4: Drop the macOS platform filters**

In `swiftui/project.yml`, in the app target's `dependencies:`, replace the MPNNKit entry (lines 448-452) and the MLX entry added in Task 8 with:

```yaml
      # MPNNKit: on-device ProteinMPNN inference. Linked on BOTH platforms as of
      # Phase 2d. All usage is guarded by #if RAYMOL_MPNN, and iOS availability is
      # gated at runtime to iOS 18+ by DesignAvailability.
      # NOTE: this entry must stay OUTSIDE the RAYMOL_SPARKLE_BEGIN/END markers
      # below, or archive_appstore.sh's sed-strip removes it from the MAS build.
      - package: proteinmpnn-mlx
        product: MPNNKit
      - package: mlx-swift
        product: MLX
```

In the `PyMOLViewerTests` target's `dependencies:` (lines 487-493), remove the `platforms: [macOS]` line from its MPNNKit entry. The test target is macOS-only by its own `platform: macOS`, so the filter is redundant and only invites drift.

- [ ] **Step 5: Bundle the weight pack on both platforms**

In `swiftui/project.yml`, replace the build-phase block at lines 432-446 with:

```yaml
      # Copy the MPNN weight pack into the built app as a real directory (folder
      # reference) so Bundle.main.url(forResource:withExtension:) resolves the whole
      # directory as a single URL (MPNNGate.packURL). Lives in swiftui/resources_mpnn/
      # (outside the auto-scanned PyMOLViewer/ tree) so xcodegen never adds it to a
      # Copy Bundle Resources phase — it must be copied exactly once, here.
      # UNLOCALIZED_RESOURCES_FOLDER_PATH resolves to Contents/Resources on macOS and
      # to the flat app root on iOS, which is where MPNNGate.packURL looks on each.
      - name: "Bundle MPNN.mpnnpack"
        basedOnDependencyAnalysis: false
        script: |
          set -e
          DEST="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
          mkdir -p "$DEST"
          rm -rf "$DEST/MPNN.mpnnpack"
          cp -R "${SRCROOT}/resources_mpnn/MPNN.mpnnpack" "$DEST/MPNN.mpnnpack"
```

- [ ] **Step 6: Add the archive flag for iOS**

In `swiftui/archive_appstore.sh`, in the iOS branch around lines 33-46, add `-skipPackagePluginValidation -skipMacroValidation` to the `xcodebuild archive` invocation. mlx-swift's `Cmlx` target carries a `CudaBuild` `.buildTool()` plugin that stalls a headless archive without it. Read the surrounding branch first and match its line-continuation style.

- [ ] **Step 7: Regenerate and verify the Sparkle markers survived**

Run: `cd swiftui && xcodegen generate 2>&1 | tail -5`
Expected: `Created project at .../PyMOLViewer.xcodeproj`

Run: `grep -n "RAYMOL_SPARKLE_BEGIN\|RAYMOL_SPARKLE_END\|proteinmpnn-mlx\|mlx-swift" swiftui/project.yml`
Expected: both `proteinmpnn-mlx` and `mlx-swift` dependency entries appear at line numbers **below** the `packages:` block and **above** `RAYMOL_SPARKLE_BEGIN`. If either sits between BEGIN and END, move it — the MAS build would lose MPNNKit entirely.

- [ ] **Step 8: Build for iOS simulator — the first real compile of Design code for iOS**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -40`

Expected: `** BUILD SUCCEEDED **`.

If it fails, the errors are the point of this task — fix them here rather than deferring. The `-typecheck` survey predicted exactly one iOS error (fixed in Task 7), but it could not see: SwiftUI overload resolution differences, `@available` requirements on APIs used inside the newly-compiled regions, or anything in `PyMOLEngine`'s design closures. Fix each with the narrowest possible change and note it in the commit body. Do **not** re-close the gate to make the build pass.

- [ ] **Step 9: Confirm the pack is actually in the iOS bundle**

```bash
find swiftui/build -name "MPNN.mpnnpack" -maxdepth 8 2>/dev/null | head
```
Expected: a path inside `...-iphonesimulator/RayMol.app/MPNN.mpnnpack` — at the app **root**, not under `Contents/Resources`. If it is missing, `MPNNGate.packURL` returns nil at runtime and every score, design, and repack throws "MPNN model pack not found in bundle."

- [ ] **Step 10: Confirm macOS is unchanged**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 0 failures.

```bash
ls swiftui/build/Debug/RayMol.app/Contents/Resources/MPNN.mpnnpack 2>/dev/null || find swiftui -name "MPNN.mpnnpack" -path "*Contents/Resources*" | head
```
Expected: the macOS pack is still at `Contents/Resources/MPNN.mpnnpack`.

- [ ] **Step 11: Commit**

```bash
git add swiftui/project.yml swiftui/archive_appstore.sh swiftui/PyMOLViewer.xcodeproj/project.pbxproj swiftui/resources_mpnn
git commit -m "$(cat <<'EOF'
build(ios): compile and link Design mode for iOS

Opens the gate that has kept the entire feature out of the iOS slice: defines
RAYMOL_MPNN for both iOS SDKs, drops the platforms:[macOS] filters from MPNNKit
and MLX, raises the deployment target to 17.0 (forced — both manifests declare
.iOS(.v17) and SPM will not resolve below it), and bundles the weight pack for
iOS via UNLOCALIZED_RESOURCES_FOLDER_PATH, which resolves to Contents/Resources
on macOS and the flat app root on iOS.

resources_macos/ is renamed resources_mpnn/ now that both platforms read it.
The MPNNKit dependency stays outside the RAYMOL_SPARKLE markers so the Mac App
Store sed-strip cannot remove it.

The app floor moves to 17.0; Design mode itself stays gated to iOS 18+ at
runtime, so no iOS 17 user loses RayMol and nothing unverified ships.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: iOS entry point and lifecycle

Six wiring changes. Without the lifecycle observer in particular, entering Design mode on iOS dims and recolours a structure with **no restore path**.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift`
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift`

**Interfaces:**
- Consumes: `DesignAvailability.isSupported` (Task 2), `DesignController.tapResidue(residueIndex:)` (Task 7), `engine.designMode` / `engine.setDesignMode(_:)` (existing, and deliberately outside `#if RAYMOL_MPNN` — `PyMOLEngine.swift:1942-1954` — so layout code can read the flag unconditionally).
- Produces: `ContentView.designModeBar` (`@ViewBuilder`), a Design rail pill, and `handleTap` design routing. Task 11 fills in the compact panel that `designModeBar` selects on iPhone.

- [ ] **Step 1: Fix the mislabelled accessibility string on `railToggle`**

`railToggle` hardcodes `"Move mode"` for every caller, so Measure already announces itself as Move. In `swiftui/PyMOLViewer/Shared/ContentView.swift` line 1962, change:

```swift
        .accessibilityLabel("Move mode, \(isOn ? "on" : "off")")
```

to:

```swift
        .accessibilityLabel("\(label) mode, \(isOn ? "on" : "off")")
```

- [ ] **Step 2: Add the Design rail pill**

In `topPaneRail` (line 1877), after the Measure `railToggle`, insert:

```swift
            #if RAYMOL_MPNN
            if DesignAvailability.isSupported {
                railToggle(icon: "wand.and.stars", label: "Design",
                           isOn: engine.designMode,
                           action: { engine.setDesignMode(!engine.designMode) })
            }
            #endif
```

- [ ] **Step 3: Add the docked-bar view**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, immediately before `private func topPaneRail(` (line 1876), insert:

```swift
    // Design-mode docked bar for the iOS layouts. Resolves to EmptyView when the
    // feature is compiled out, so the mode chain in all four layouts can reference
    // it unconditionally. iPhone (compact width, either orientation) gets the
    // four-row compact panel; iPad gets the same five-row overlay macOS uses.
    @ViewBuilder
    private var designModeBar: some View {
        #if RAYMOL_MPNN
        if hSize == .compact {
            DesignCompactPanel(controller: engine.designController,
                               engine: engine,
                               theme: themeManager)
        } else {
            DesignOverlayView(controller: engine.designController,
                              engine: engine,
                              theme: themeManager)
        }
        #else
        EmptyView()
        #endif
    }
```

- [ ] **Step 4: Join the mode chain in all four docked slots**

In each of the four layouts, extend the mutually-exclusive chain. Change every occurrence of:

```swift
                if engine.interactionMode == .move { moveOverlay }
                else if engine.measureMode != nil { measureOverlay }
```

to:

```swift
                if engine.interactionMode == .move { moveOverlay }
                else if engine.measureMode != nil { measureOverlay }
                else if engine.designMode { designModeBar }
```

The four sites, with their surrounding indentation (which differs per layout — match what is already there):
- `:1461-1462` iPhone portrait (`iPhoneLayout`)
- `:1542-1543` iPhone landscape (`iPhoneLandscapeLayout`)
- `:1680-1681` iPad landscape (`iPadMacStyleLayout`, `if landscape` branch)
- `:1744-1745` iPad portrait (`iPadMacStyleLayout`, `else` branch)

- [ ] **Step 5: Add `designMode` to the three `anyTop` predicates**

Without this, the rail floats over a full-bleed viewport and the Design bar has no chrome band to sit on.

At `:1433-1434` and `:1519-1521`, change:

```swift
        let anyTop = !iosFullScreen && (cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil)
```

to:

```swift
        let anyTop = !iosFullScreen && (cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
            || engine.designMode)
```

At `:1654-1655`, change:

```swift
        let anyTop = cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
```

to:

```swift
        let anyTop = cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
            || engine.designMode
```

- [ ] **Step 6: Hoist the lifecycle observer so iOS restores visual state**

The `.onChange(of: engine.designMode)` block currently lives at `:502-515`, attached inside the macOS-only layout. On iOS, entering Design mode would dim and recolour the structure with nothing ever calling `exit()` to restore it.

Delete the block at `:502-515` from the macOS layout, and attach it instead to the shared root `body` — the same modifier chain that carries `busyOverlay` — so both platforms observe it:

```swift
            #if RAYMOL_MPNN
            // Single lifecycle observer for Design mode, shared by macOS and iOS:
            // fires on EVERY designMode transition (rail pill, toolbar button, menu,
            // Move/Measure exclusion) so the scene is always restored on exit
            // regardless of which path caused the change. Hoisted out of the macOS
            // layout in Phase 2d — without it, iOS dims and recolours with no restore.
            .onChange(of: engine.designMode) { on in
                if on {
                    engine.designController.allObjects = engine.objects
                        .filter { !$0.isSelection }.map { $0.name }
                    engine.designController.enter()
                } else {
                    engine.designController.exit()
                }
            }
            #endif
```

- [ ] **Step 7: Route viewport taps in Design mode**

In `swiftui/PyMOLViewer/Shared/MetalViewport.swift`, in `handleTap` (lines 1027-1055), insert after the `interactionMode == .move` block and before the `measureMode` check:

```swift
            #if RAYMOL_MPNN
            if engine.designMode {
                // In Design mode a viewport tap targets a residue, mirroring the
                // macOS long-press path. Region-edit mode makes it toggle region
                // membership instead of pinning — see DesignController.tapResidue.
                engine.designPickResidue(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
                return
            }
            #endif
```

- [ ] **Step 8: Add the engine-side pick helper**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, inside the `#if RAYMOL_MPNN` block (which opens at line 1956), add a method that mirrors the macOS `readDesignHoverHit` path but commits the hit. Read `hoverDesignPreview` / `readDesignHoverHit` (around `:2474-2536`) first and reuse their pick + `(chain, resi)` decode verbatim rather than reimplementing it; then resolve the index and route it:

```swift
    /// Commit a Design-mode residue pick from a viewport tap (iOS). Resolves the
    /// hit to a full-length residue index on the focus object and hands it to
    /// DesignController.tapResidue, which pins or edits the region per mode.
    func designPickResidue(ndcX: Float, ndcY: Float, aspect: Float) {
        guard designMode,
              let hit = readDesignHoverHit(ndcX: ndcX, ndcY: ndcY, aspect: aspect),
              let idx = designController.residueIndex(chain: hit.chain, resi: hit.resi)
        else { return }
        designController.tapResidue(residueIndex: idx)
    }
```

If `readDesignHoverHit`'s actual signature or return type differs from this, adapt the call — do not change `readDesignHoverHit` itself, which the macOS hover path depends on.

- [ ] **Step 9: Stop the iOS long-press sheet from eating Design hits**

The iOS `confirmationDialog` at `:1180-1188` lacks the `&& !engine.designMode` guard that macOS has at `:664`. Add the same condition to its presentation binding so the residue action sheet does not fire in Design mode.

- [ ] **Step 10: Adapt the two popovers for compact width**

`.popover` becomes a full-height sheet on iPhone. Add `.presentationCompactAdaptation(.popover)` to the selection picker at `:3402` and the help popover at `:3840`:

```swift
        .popover(isPresented: $showPicker) {
            pickerContent
                .presentationCompactAdaptation(.popover)
        }
```

- [ ] **Step 11: Build both platforms**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30`

Expected: FAIL with `cannot find 'DesignCompactPanel' in scope` — that view arrives in Task 11. Everything else must compile. If any other error appears, fix it here.

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. The macOS build must stay green even though `DesignCompactPanel` is missing — `hSize` is never `.compact` in the macOS layout, but Swift compiles both branches, so if macOS also fails on the missing type, temporarily stub `DesignCompactPanel` as an empty `View` and complete it in Task 11.

- [ ] **Step 12: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Shared/MetalViewport.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "$(cat <<'EOF'
feat(design): add the iOS entry point and share the mode lifecycle

Adds a Design rail pill (gated by DesignAvailability), joins the mutually
exclusive docked-mode chain in all four iOS layouts, and adds designMode to the
three anyTop predicates so the bar gets a chrome band instead of floating.

The important one is hoisting .onChange(of: engine.designMode) out of the
macOS-only layout into the shared body. It owns enter()/exit(), so without it
iOS would dim and recolour a structure with no restore path at all.

Viewport taps now route through DesignController.tapResidue, and the iOS
long-press sheet gets the !designMode guard macOS already had, or it swallows
every Design hit.

Also fixes railToggle's hardcoded "Move mode" accessibility label, which made
Measure announce itself as Move.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: `DesignCompactPanel` — the iPhone dock and settings sheet

Spec §8: four docked rows (~110 pt) plus a sheet for set-once controls. `Compare` stays docked because it is toggled repeatedly while judging a design, unlike the preferences around it.

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift`

**Interfaces:**
- Consumes: `DesignController` published state (`focusObject`, `allObjects`, `sequenceScore`, `isScoring`, `focusResidues`, `activePropensity`, `regionModeActive`, `regionEditMode`, `selectedResidueIndices`, `paletteAllowed`, `designTemperature`, `autoRepack`, `showSidechains`, `compareEnabled`, `sideBySide`, `editing`, `editCount`, `workingObject`, `repackDirty`, `pendingSizeWarning`), `DesignSizeGuard.formatted(bytes:)` (Task 3), `controller.confirmPendingWarning()` / `cancelPendingWarning()` (Task 4), `controller.tapResidue(residueIndex:)` (Task 7).
- Produces: `DesignCompactPanel(controller:engine:theme:)`, referenced by `ContentView.designModeBar` (Task 10).

Reuse, do not duplicate: `DesignSequenceStripView` and the propensity/palette pill rows already scroll horizontally and are used as-is. Only the three non-scrolling `HStack`s need new layout.

- [ ] **Step 1: Create the file**

Create `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift`:

```swift
#if RAYMOL_MPNN
import SwiftUI

/// Compact Design panel for iPhone (compact width, either orientation).
///
/// The macOS overlay is five non-scrolling rows wanting roughly 600-700 pt; an
/// iPhone has ~390. Rather than shrink everything, this keeps the four rows that
/// carry a primary action docked and moves set-once controls into a sheet.
/// `Compare` stays docked deliberately — it is toggled repeatedly while judging a
/// design, unlike the preferences beside it.
///
/// iPad and macOS keep DesignOverlayView; see ContentView.designModeBar.
struct DesignCompactPanel: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showSettings = false
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            DesignErrorBannerCompact(controller: controller)
            sizeWarningRow
            headerRow
            if !controller.focusResidues.isEmpty {
                Divider().opacity(0.3)
                DesignSequenceStripView(controller: controller, theme: theme)
                Divider().opacity(0.3)
                actionRow
            }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
        .sheet(isPresented: $showSettings) {
            DesignSettingsSheet(controller: controller, theme: theme)
        }
    }

    // Row 1: focus object · score · settings · exit.
    private var headerRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(controller.allObjects, id: \.self) { name in
                    Button { controller.focus(name) } label: {
                        if name == controller.focusObject {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(controller.focusObject ?? "Choose object")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundColor(theme.active.panelText.color)
            }
            .menuIndicator(.hidden)

            if let s = controller.sequenceScore {
                Text(String(format: "%.2f", s))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.55))
            }
            if controller.isScoring { ProgressView().scaleEffect(0.6) }

            Spacer(minLength: 0)

            Button { showSettings = true } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Design settings")

            Button { engine.setDesignMode(false) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit design mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // Row 4: the one primary action. Region controls while designing; Keep /
    // Discard once there are edits to resolve.
    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                controller.refreshSelections()
                showPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "lasso").font(.system(size: 11))
                    Text(controller.selectedSelectionName ?? "Region")
                        .font(.system(size: 12)).lineLimit(1)
                }
                .foregroundColor(theme.active.panelText.color.opacity(0.85))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(theme.active.panelText.color.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker) {
                selectionPicker.presentationCompactAdaptation(.popover)
            }

            Button { controller.regionEditMode.toggle() } label: {
                Image(systemName: controller.regionEditMode ? "hand.tap.fill" : "hand.tap")
                    .font(.system(size: 13))
                    .foregroundColor(controller.regionEditMode
                                     ? .white : theme.active.panelText.color.opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(controller.regionEditMode
                                ? theme.active.accent.color
                                : theme.active.panelText.color.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tap to edit region, \(controller.regionEditMode ? "on" : "off")")

            if controller.regionModeActive {
                Button { controller.redesignSelection() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars").font(.system(size: 11, weight: .semibold))
                        Text("\(controller.selectedResidueIndices.count)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(theme.active.accent.color, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(controller.paletteAllowed.filter { $0 < 20 }.isEmpty)
                .accessibilityLabel("Redesign \(controller.selectedResidueIndices.count) residues")
            }

            Spacer(minLength: 0)

            if controller.editing {
                Toggle("", isOn: Binding(get: { controller.compareEnabled },
                                         set: { controller.setCompare($0) }))
                    .labelsHidden()
                    .accessibilityLabel("Compare with original")
                Button { Task { await controller.keepEditsAwait() } } label: {
                    Text("Keep").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain)
                Button { controller.discardEdits() } label: {
                    Text("Discard").font(.system(size: 12))
                        .foregroundColor(.red)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var selectionPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            if controller.availableSelections.isEmpty {
                Text("No selections — create one first")
                    .font(.system(size: 12)).foregroundColor(.secondary).padding(10)
            } else {
                ForEach(controller.availableSelections) { opt in
                    Button {
                        controller.pickSelection(opt.name)
                        showPicker = false
                    } label: {
                        HStack {
                            Text(opt.name).font(.system(size: 14))
                            Spacer(minLength: 12)
                            Text("\(opt.count) res")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9).frame(minWidth: 220)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if controller.regionModeActive {
                Divider()
                Button {
                    controller.clearSelection()
                    showPicker = false
                } label: {
                    Text("Clear region").font(.system(size: 14)).foregroundColor(.red)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(6)
    }

    // Oversize confirmation. Inline rather than an alert so it cannot be dismissed
    // by accident and stays visible while the user decides.
    @ViewBuilder
    private var sizeWarningRow: some View {
        if let w = controller.pendingSizeWarning {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(w.residueCount) residues needs about \(DesignSizeGuard.formatted(bytes: w.estimatedBytes)) — close to this device's limit of \(DesignSizeGuard.formatted(bytes: w.availableBytes)).")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Run anyway") { Task { await controller.confirmPendingWarning() } }
                        .font(.system(size: 12, weight: .semibold))
                    Button("Cancel") { controller.cancelPendingWarning() }
                        .font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.9))
        }
    }
}

// Same contract as the macOS DesignErrorBanner, sized for compact width.
private struct DesignErrorBannerCompact: View {
    @ObservedObject var controller: DesignController

    var body: some View {
        if let text = controller.errorText {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                Text(text).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.red.opacity(0.85))
            .contentShape(Rectangle())
            .onTapGesture { controller.clearError() }
            .accessibilityLabel("Design error: \(text). Tap to dismiss.")
        }
    }
}

/// Set-once Design controls, moved off the dock to keep the viewport large.
struct DesignSettingsSheet: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Sampling") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(String(format: "%.2f", controller.designTemperature))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $controller.designTemperature, in: 0...1)
                    }
                    Text("0 picks the most likely residue every time; higher values vary each run.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Structure") {
                    Toggle("Auto-repack after each edit", isOn: $controller.autoRepack)
                    Toggle("Show all sidechains", isOn: Binding(
                        get: { controller.showSidechains },
                        set: { controller.setShowSidechains($0) }))
                    if controller.compareEnabled {
                        Toggle("Side-by-side", isOn: Binding(
                            get: { controller.sideBySide },
                            set: { controller.setSideBySide($0) }))
                    }
                }
                Section("Colouring") {
                    Picker("Meaning", selection: $controller.colorMeaning) {
                        ForEach(DesignColorMeaning.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                }
            }
            .navigationTitle("Design settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
```

- [ ] **Step 2: Reconcile every symbol against the real API**

The panel references controller members by name. Before building, verify each against `DesignController.swift` and fix any mismatch **in this file**, never by renaming controller members other code depends on. Check specifically: `focus(_:)`, `keepEditsAwait()`, `discardEdits()`, `setCompare(_:)`, `setShowSidechains(_:)`, `setSideBySide(_:)`, `colorMeaning`, and whether `DesignColorMeaning` is `CaseIterable` with a `label`. If `DesignColorMeaning` lacks `allCases` or `label`, mirror however `meaningPicker` in `ContentView.swift` (~`:3808`) builds its options.

- [ ] **Step 3: Build for iOS**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`

If the Swift type-checker reports "unable to type-check this expression in reasonable time", split the offending row into a separate `@ViewBuilder` computed property — the existing code hits this repeatedly and `DesignSequenceStripView.seqCols` (`:3248`) is the in-repo precedent for the fix.

- [ ] **Step 4: Build for macOS**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

This file is in `Shared/`, so it compiles on macOS too. `NavigationStack`, `.presentationDetents`, and `.navigationBarTitleDisplayMode` are iOS-only or behave differently — if macOS fails, wrap the sheet body in `#if os(iOS)` rather than dropping the feature on iPhone.

- [ ] **Step 5: Enlarge the sequence-column hit region (spec §8)**

Sequence columns are 14 pt wide (`ContentView.swift:3275`/`:3282`) with 1 pt spacing (`:3238`) — far below the 44 pt touch guidance, and now that a tap builds a region rather than just pinning, a mis-tap has consequences.

The columns must stay 14 pt *visually* (a legible sequence requires it), so widen only the hit region. In `DesignSequenceStripView.seqColumn`, replace the existing `.contentShape(Rectangle())` (`:3303`) with:

```swift
        // Keep the column 14 pt wide visually — a legible sequence needs it — but
        // give touch a taller, slightly wider target. contentShape does not affect
        // layout, so neighbouring columns are unmoved.
        .contentShape(Rectangle().inset(by: -6))
```

- [ ] **Step 6: Keep hover working for iPad pointers (spec §9)**

Touch has no hover state, so on iPhone the pinned residue is the primary interaction. iPad with a trackpad or Apple Pencil *does* deliver hover, and `MetalViewport` already has a `UIHoverGestureRecognizer` (`:258-259`).

In `swiftui/PyMOLViewer/Shared/MetalViewport.swift`, in `handleHover` (`:1075-1105`), mirror the macOS branch at `:612-620` so an indirect pointer drives the Design hover preview rather than the generic one:

```swift
            #if RAYMOL_MPNN
            if engine.designMode {
                engine.hoverDesignPreview(ndcX: ndcX, ndcY: ndcY, aspect: aspect)
                return
            }
            #endif
```

Match the macOS branch's exact call and argument labels rather than the ones written here — read `:612-620` first. If `handleHover` computes its NDC coordinates under different names, use those.

This is a bonus path, not a requirement: everything Design does must remain reachable by tapping alone.

- [ ] **Step 7: Run the full unit suite**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`, 0 failures.

Re-run both builds after Steps 5-6, since they touch shared files:

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10`
Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Shared/MetalViewport.swift
git commit -m "$(cat <<'EOF'
feat(design): add DesignCompactPanel for iPhone

The macOS overlay is five non-scrolling rows wanting ~600-700 pt; an iPhone has
~390. This keeps the four rows carrying a primary action docked (~110 pt) and
moves set-once controls — temperature, auto-repack, sidechains, side-by-side,
colour meaning — into a sheet.

Compare stays docked on purpose: it is toggled repeatedly while judging a
design, unlike the preferences beside it.

The oversize confirmation renders inline rather than as an alert, so it cannot
be dismissed by accident while the user is deciding.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: `PYMOL_AUTODESIGN` hook and the simulator smoke test

The repo has 35 `PYMOL_AUTO*`/`PYMOL_SKIP*` hooks and **not one for Design**. This is the established way an iOS feature gets verified headlessly here, and combined with Task 8's simulator CPU fallback it turns "does the Design pipeline work on iOS" into an automated check.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift`

**Interfaces:**
- Consumes: `engine.setDesignMode(_:)`, `controller.focus(_:)`, `controller.pickSelection(_:)`, `controller.redesignSelectionAwait()`, `controller.sequenceScore`.
- Produces: the `PYMOL_AUTODESIGN` environment contract, documented below, and an `NSLog` marker `AUTODESIGN_DONE:` / `AUTODESIGN_FAIL:`.

**Contract:** `PYMOL_AUTODESIGN="<object>[,<selection>]"` — enter Design mode, focus `<object>`, and if `<selection>` is given, designate it as the region and run one redesign. On completion log `AUTODESIGN_DONE: <object> score=<value> edits=<n>`; on failure log `AUTODESIGN_FAIL: <reason>`. Pairs with `PYMOL_AUTOLOAD` to get a structure in first.

- [ ] **Step 1: Add the hook**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`, in the same `onAppear` that hosts `PYMOL_AUTOMOVE` and `PYMOL_AUTOEXPORTMOVIE` (lines 1318-1335), append after the `PYMOL_AUTOEXPORTMOVIE` block:

```swift
            #if RAYMOL_MPNN
            // Test affordance (PYMOL_AUTODESIGN="<object>[,<selection>]"): enter
            // Design mode, focus the object, and optionally designate a selection as
            // the region and run one redesign. Logs a grep-able marker on completion.
            // This is the only headless way to drive Design mode; pair with
            // PYMOL_AUTOLOAD to get a structure in first.
            if let d = ProcessInfo.processInfo.environment["PYMOL_AUTODESIGN"] {
                let parts = d.split(separator: ",").map(String.init)
                let objectName = parts.first ?? ""
                let selectionName = parts.count > 1 ? parts[1] : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    guard !objectName.isEmpty else {
                        NSLog("AUTODESIGN_FAIL: no object given")
                        return
                    }
                    engine.setDesignMode(true)
                    let c = engine.designController
                    Task { @MainActor in
                        await c.focusAwait(objectName)
                        guard c.focusObject != nil, !c.focusResidues.isEmpty else {
                            NSLog("AUTODESIGN_FAIL: focus produced no residues for \(objectName)")
                            return
                        }
                        if let sel = selectionName {
                            c.refreshSelections()
                            c.pickSelection(sel)
                            guard c.regionModeActive else {
                                NSLog("AUTODESIGN_FAIL: selection '\(sel)' matched no designable residues")
                                return
                            }
                            await c.redesignSelectionAwait()
                            if let err = c.errorText {
                                NSLog("AUTODESIGN_FAIL: \(err)")
                                return
                            }
                        }
                        let score = c.sequenceScore.map { String(format: "%.4f", $0) } ?? "nil"
                        NSLog("AUTODESIGN_DONE: \(objectName) score=\(score) edits=\(c.editCount)")
                    }
                }
            }
            #endif
```

- [ ] **Step 2: Build for iOS simulator**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Install and run the smoke test in a simulator**

Build for a concrete simulator, install, and launch with the hooks set. Adjust the device name to one `xcrun simctl list devices available` reports.

```bash
cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath build_ios_sim -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -5
```

```bash
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null; xcrun simctl bootstatus "iPhone 16 Pro" -b
```

```bash
xcrun simctl install booted swiftui/build_ios_sim/Build/Products/Debug-iphonesimulator/RayMol.app
```

- [ ] **Step 4: Confirm the weight pack shipped in the simulator bundle**

```bash
ls "$(xcrun simctl get_app_container booted io.raymol.RayMol)/MPNN.mpnnpack"
```
Expected: the pack's contents (`manifest.json`, `weights/`, …). If this is missing, Task 9 Step 5 did not take effect for the simulator SDK and every inference call will throw.

- [ ] **Step 5: Run the pipeline headlessly**

```bash
xcrun simctl launch --console-pty --terminate-running-process booted io.raymol.RayMol \
  --setenv PYMOL_AUTOLOAD=1ubq.pdb --setenv PYMOL_AUTODESIGN=mol 2>&1 | grep -E "AUTODESIGN_|error|Fatal" | head -20
```

Expected: `AUTODESIGN_DONE: mol score=-<n.nnnn> edits=0` within roughly a minute. MLX runs on the **CPU** here (Task 8's fallback), so it is slow and the timing means nothing — the point is that featurize → encode → decode → score completes without aborting.

If the process aborts with an `MTLStorageModePrivate` assertion or a null-architecture crash, `MPNNRuntime.configureOnce()` is not running before the first MLX allocation — check the call site in `loadedMPNNModel()`.

Substitute a bundled structure name that actually exists if `1ubq.pdb` is not in the bundle; `PYMOL_AUTOLOAD` resolves via `Bundle.main.path(forResource:ofType:)`.

- [ ] **Step 6: Verify the object was not mutated in place**

The standing Design invariant. In the same launch, confirm the log shows Design mode entered against `mol` and that no `mol` mutation occurred (`edits=0` with no selection given). Then re-run with a selection to exercise the redesign path:

```bash
xcrun simctl launch --console-pty --terminate-running-process booted io.raymol.RayMol \
  --setenv PYMOL_AUTOLOAD=1ubq.pdb --setenv PYMOL_AUTOCMD="select reg, resi 10-20" \
  --setenv PYMOL_AUTODESIGN=mol,reg 2>&1 | grep -E "AUTODESIGN_" | head -5
```
Expected: `AUTODESIGN_DONE: mol score=… edits=<n>` with `n > 0`.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "$(cat <<'EOF'
test(design): add PYMOL_AUTODESIGN headless hook

The repo has 35 PYMOL_AUTO*/SKIP* hooks and none for Design, so there was no way
to drive the feature without a human. PYMOL_AUTODESIGN="<object>[,<selection>]"
enters Design mode, focuses, optionally designates a region and runs one
redesign, then logs a grep-able AUTODESIGN_DONE / AUTODESIGN_FAIL marker.

With MPNNRuntime's simulator CPU fallback this makes the whole pipeline —
featurize, encode, decode, score, repack — verifiable headlessly in a simulator.
Timings there are meaningless (CPU backend); correctness is not.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Put the Python design tests in CI, and record the Swift-CI gap

`testing/tests/raymol/design_*.py` covers `raymol_design.py`, which iOS now ships — and none of it runs in CI.

**Files:**
- Modify: `.github/workflows/raymol-embedded-tests.yml`

- [ ] **Step 1: List the design test files**

```bash
ls testing/tests/raymol/design_*.py
```
Note the exact filenames; the next step must match them.

- [ ] **Step 2: Add them to the workflow**

In `.github/workflows/raymol-embedded-tests.yml`, extend the list at lines 47-60. Keep the existing 14-space continuation indent and the trailing `\` on every line but the last:

```yaml
              testing/tests/test_stale_check.py \
              testing/tests/raymol/design_region.py
```

Add one line per file found in Step 1, in alphabetical order, with `testing/tests/test_stale_check.py` keeping its `\`.

- [ ] **Step 3: Verify the tests pass locally before trusting CI**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`
Expected: all tests pass.

If the installed `pymol` lacks `raymol_design`, it is shadowing the fork — the runner warns about a stale Python layer (`0683def4f`). Resolve that before concluding the tests are broken.

- [ ] **Step 4: File the Swift-CI gap as its own issue**

No workflow in this repo compiles Swift, so nothing will ever catch an iOS Design regression. Per spec §12 this is deliberately out of scope — it is a repo-wide infrastructure decision — but it must be recorded rather than forgotten.

```bash
gh issue create -R javierbq/RayMol \
  --title "CI: no workflow compiles Swift, so iOS/macOS app regressions are never caught" \
  --body "$(cat <<'EOF'
### Problem

`.github/workflows/` contains `build.yml` (Linux/Windows/macOS pip + `--run all`), `raymol-embedded-tests.yml` (embedded pymol Python tests), and `download-stats.yml`. **None of them run `xcodebuild`.** No Swift code in `swiftui/` is compiled by CI on any platform.

This surfaced during #217 Phase 2d, which opened the `RAYMOL_MPNN` gate for iOS. Before 2d, both earlier Design plans carried a manual "iOS still builds, mlx not linked" gate. After 2d that check inverts — iOS must now build *with* MPNNKit linked and the weight pack present — and there is no automation for either form.

### Why it matters now

Design mode is the largest shared-code surface in the app and it now compiles on both platforms. A change that builds on macOS can break iOS silently (a shared view referencing a macOS-only symbol is a repeatedly-hit failure mode in `ContentView.swift`), and nothing would notice until someone builds by hand.

### Options

1. **macOS-runner job building both schemes** — catches gate, link, and platform-fork regressions. Smallest useful step.
2. **(1) plus the unit-test suite** (`-scheme UnitTests_macOS`) — 60+ tests that currently only run locally.
3. **(2) plus a simulator smoke test** driven by the `PYMOL_AUTODESIGN` hook added in Phase 2d — the only option that would catch a broken Design *pipeline* rather than just a broken build.

Cost is real: macOS runners are billed at a premium and the build pulls mlx-swift from source.

### Not blocking

Phase 2d ships without this; opening the iOS gate cannot break CI precisely because CI does not build Swift.
EOF
)"
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/raymol-embedded-tests.yml
git commit -m "$(cat <<'EOF'
ci: run the RayMol design Python tests under embedded pymol

These cover raymol_design.py, which iOS now ships as of Phase 2d, and none of
them ran in CI. Cheap coverage for code that just gained a second platform.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Measure on a physical device and retune the guard

Everything above is arithmetic against a measurement taken on a *different app*. This task replaces inference with observation. It is the only task that cannot be done headlessly, and the only one that can invalidate Task 3's constants.

**Files:**
- Possibly modify: `swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift` (constants only)
- Modify: `docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md` (record measurements)

- [ ] **Step 1: Build and install on the device**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
  -configuration Release -destination "generic/platform=iOS" \
  -derivedDataPath build_ios_restricted \
  DEVELOPMENT_TEAM=VT99UQUQ89 CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
  clean build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`, artifact at `build_ios_restricted/Build/Products/Release-iphoneos/RayMol.app`.

- [ ] **Step 2: Measure RayMol's own baseline — the biggest unknown**

The spec's §2 table is MLX peak for a *bench* app. RayMol additionally carries the PyMOL C++ core, embedded CPython, numpy, and Metal render buffers, and that baseline has never been measured. Load a structure, enter Design mode, and before running any inference record `os_proc_available_memory()`.

Add a temporary log line at the top of `redesignSelectionAwait`'s guard block:

```swift
        NSLog("DESIGNMEM: residues=\(residueCount) available=\(availableMemoryProvider()) estimate=\(DesignSizeGuard.estimatedBytes(residueCount: residueCount))")
```

Record the value for: no structure loaded, a ~400-residue structure loaded, and a ~1500-residue structure loaded.

- [ ] **Step 3: Run redesigns at three sizes and record reality**

For each of roughly 100, 400, and 1000+ residues: run a full-object redesign and record wall-clock time, whether it completed, and the available-memory reading before and after. Note whether the app was ever killed.

- [ ] **Step 4: Measure `.leaveOneOut` — the documented blind spot**

`PyMOLEngine.swift:1987` scores with `mode: .leaveOneOut`, which runs L full-length decoder passes rather than one sliced row per step, and **has never been measured on any device**. It runs on every focus and every edit rescore, so it is plausibly the slowest thing in the feature.

Time a focus (which triggers exactly one score) at each of the three sizes. Record the numbers.

- [ ] **Step 5: Decide, with data**

- If measured peak exceeds `estimatedBytes` at any size, raise `bytesPerResidue` or `fixedOverheadBytes` until the estimate is conservative, and update `DesignSizeGuardTests` expectations by **recomputing them**, not by pasting whatever the code now returns.
- If `.leaveOneOut` focus time is tolerable (say under ~5 s at 1000 residues), record the numbers and close the question.
- If it is not, **do not** swap it to `.conditional` here — that changes confidence semantics on both platforms. File a separate issue with the measurements attached and note it in the PR.

- [ ] **Step 6: Remove the temporary logging and record the results**

Delete the `DESIGNMEM` NSLog. Add a "§2a Phase 2d device measurements" subsection to the spec with a table matching §2's format, stating the device, iOS version, and RAM, and explicitly separating measured from inferred.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift swiftui/PyMOLViewerTests/DesignSizeGuardTests.swift docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md
git commit -m "$(cat <<'EOF'
perf(design): record on-device measurements and retune the size guard

Replaces the Phase 2d guard constants — derived from a different app's bench
numbers — with measurements from RayMol itself on hardware, including the
process baseline (PyMOL core + CPython + numpy + render buffers) that the
original table could not account for.

Also records the first measurement of .leaveOneOut scoring on any device. It
runs on every focus and every edit rescore and had never been timed.

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 15: Open the pull request

- [ ] **Step 1: Full verification sweep**

Run each and confirm before proceeding:

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`, 0 failures, roughly 75 tests.

```bash
cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -5
```

```bash
cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -5
```

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
```

- [ ] **Step 2: Confirm the Mac App Store strip still leaves MPNNKit in place**

```bash
sed '/RAYMOL_SPARKLE_BEGIN/,/RAYMOL_SPARKLE_END/d' swiftui/project.yml | grep -c "proteinmpnn-mlx"
```
Expected: `2` (the package entry and the app-target dependency). A `0` or `1` means the MAS build would lose Design mode entirely.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin claude/raymol-217-design-ios-phase2d
```

```bash
gh pr create -R javierbq/RayMol --base master \
  --title "RayMol Design mode on iOS/iPad (#217 Phase 2d)" \
  --body "$(cat <<'EOF'
Brings on-device ProteinMPNN Design mode to iPhone and iPad. Implements `docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md`.

## What this is

Mostly a port. All five Design Swift files already lived in `Shared/`, were already members of the iOS target, and were already platform-neutral — they compiled as empty translation units because `RAYMOL_MPNN` was undefined for the iOS SDK. A `-sdk iphoneos swiftc -typecheck` pass over every gated region found exactly one iOS compile error.

## Decisions

- **iPhone and iPad both**, one adaptive UI.
- **App iOS floor 16.0 → 17.0** (forced: MPNNKit and mlx-swift declare `.iOS(.v17)`, SPM won't resolve lower). **Design mode itself requires iOS 18** at runtime — the only configuration ever validated on hardware. Gating the feature rather than the app means no iOS 17 user loses RayMol and nothing unverified ships.
- **Two-tier size policy**: proceed under 50% of the remaining budget, confirm (after an autosave) up to 75%, refuse above it. Driven by `os_proc_available_memory()` rather than a static residue cap, so the limit adapts to what is already loaded.
- **iPhone layout**: four docked rows (~110 pt) plus a settings sheet. `Compare` stays docked — it is toggled repeatedly while judging a design.

## Three things worth a reviewer's attention

- **`errorText` was read nowhere in the app.** Written in six places in `DesignController`, consumed only by a unit test. Every Design failure was silent. Fixed first, because it makes every other failure here diagnosable.
- **MLX aborts in the iOS Simulator** without a CPU-device fallback (cannot allocate private-storage Metal heaps; null GPU arch string). `MPNNRuntime` adds it, which is what makes a headless simulator test path exist at all. It also clamps the MLX buffer cache to 96 MB — unbounded, it was measured above 5 GB at L~1000.
- **Model release is dispatched to the inference queue**, not run inline. `_mpnnModel` is unsynchronized and effectively owned by that serial queue, so a main-thread nil-out would race an in-flight job.

## Memory

Measured on physical hardware (see the spec's device-measurement section). The guard's constants derive from the measured slope with a 25% reserve, because MLX's reported peak excludes its buffer cache and true `phys_footprint` runs above the estimate by an unmeasured amount.

## Verification

- Swift unit tests, all passing on macOS — including exhaustive boundary tests for the size guard, which is pure arithmetic and therefore testable exactly rather than approximated on a device.
- Headless simulator smoke test via the new `PYMOL_AUTODESIGN` hook: full pipeline, CPU backend.
- On-device build, run, and measurement.
- macOS behaviour unchanged: the size guard reports an unknown budget there and never gates.

## Deliberately out of scope

- **`.leaveOneOut` → `.conditional`.** Scoring uses `.leaveOneOut`, which does ~L× the decode work and had never been measured on any device. This PR measures it; swapping it changes confidence semantics on both platforms and is a separate call.
- On-demand resources for the 23.7 MB weight pack (the IPA grows ~28.6 MB), chunking in MPNNKit, Phase 2e (MAS), and Escape-to-exit (#235).
- An iOS CI job — filed separately, since no workflow in this repo compiles Swift at all.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Report the PR URL and stop**

Do not merge. The user reviews and merges.

---

## Appendix: facts an implementer will otherwise rediscover the hard way

- **`xcodebuild` alone links a stale core.** The two-stage build is `bash swiftui/build_macos.sh` (C++ → `libpymol_core.a`) *then* `xcodebuild`. If runtime behaviour contradicts the source, suspect a stale `libpymol_core.a` before suspecting your change. `strings build_macos_swiftui/libpymol_core.a | grep -c <symbol>` — with a control symbol to validate the method — tells you whether a feature is actually in the binary.
- **In a worktree**, `deps_macos` and `build_macos_swiftui` may need symlinking from the main repo. A symlinked *prebuilt* core can be months old; that exact trap cost a full debugging session in Phase 2c.
- **SourceKit lies about `ContentView.swift` and `PyMOLEngine.swift`**, emitting spurious "cannot find type 'PyMOLEngine'" and type-check-timeout diagnostics. Trust `xcodebuild`, not the editor.
- **`cmd.enable()` is exclusive for selections** — enabling one blanks other selections' markers. Never use it for transient overlays.
- **`DesignController` is a nested `ObservableObject` on `PyMOLEngine`.** A view that observes only `engine` will **not** re-render when controller state changes. Every Design view must hold `@ObservedObject var controller: DesignController`. A stale busy overlay caused by exactly this bug shipped once already.
- **Busy flags must clear via `defer`, token-guarded.** `isRedesigning` and `isRepacking` drive an input-blocking overlay; a flag stranded on any early-return path locks the UI. Both existing sites do this correctly — copy the pattern rather than inventing one.
- **`fixedPositions` is not a speedup.** Cost tracks total object length, not selection size, so redesigning 10 residues of a 2000-residue protein costs nearly the same as redesigning all of it. Do not size-gate on the selection count.
