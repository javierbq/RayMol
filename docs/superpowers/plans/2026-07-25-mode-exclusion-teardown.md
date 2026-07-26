# Mode-Exclusion Teardown Symmetry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `setDesignMode` tear down Move and Measure through their canonical setters instead of bare assignments, so entering Design mode no longer strands an undeletable `_move_gizmo` CGO in the scene.

**Architecture:** RayMol's three interaction modes are mutually exclusive. Move and Measure teardown is *imperative* (inside their setters); Design teardown is *observer-driven* (`.onChange(of: engine.designMode)` in `ContentView.swift:506`). Bare assignments therefore work for Design but silently skip teardown for the other two. The fix routes all three setters through each other, adds a DEBUG-only `runPython` tap so the emitted teardown Python is assertable, and repairs an ordering bug in the Move teardown that lets `syncAdjustFrame`'s `readGizmo()` resurrect the fields it just cleared.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, xcodegen + xcodebuild, macOS target `PyMOLViewer_macOS`, test target `PyMOLViewerTests`.

**Spec:** `docs/superpowers/specs/2026-07-25-mode-exclusion-teardown-design.md`

## Global Constraints

- **Never commit or push to `master`.** Work on the current feature branch and open a PR into `master` (project `CLAUDE.md`).
- **Edit files inside this worktree** (`/Users/jcastellanos/repos/RayMol/.claude/worktrees/sleepy-bartik-93c9ce`), not the main repo, or the build will not see the changes.
- **Both platforms must compile.** `ContentView.swift` and `PyMOLEngine.swift` are shared between macOS and iOS with `#if os(iOS)` blocks; a change can compile on one and break the other. Verify both before the final commit.
- **`runPython` must stay safe to call in any state.** It is `guard isReady else { return }` (`PyMOLEngine.swift:1077`); `isReady` defaults to `false` (`:63`). Do not remove or reorder that guard relative to `PyMOLBridge_RunPython`.
- **The new `pythonTap` seam is `#if DEBUG` only** and must be invoked *before* the `isReady` guard.
- **VERIFIED EMPIRICALLY — real Python runs during these tests.** The test bundle uses `TEST_HOST`/`BUNDLE_LOADER` (runs in-process inside `RayMol.app`), the app initializes the engine, and `isReady` is **true**. Proof: a baseline run of the existing `DesignModeStateTests` printed `MEASURE:{"kind": "distance", "count": 0, "need": 2}`, which is emitted by `modules/pymol/appkit_measure.py:45`. Consequences you must design around:
  - `runPython` genuinely executes; these are integration-flavoured tests, not pure unit tests.
  - **No structure is loaded**, so `metal_move`'s `_active` is `None`. Every `_emit(...)` therefore writes `{"active": false}` to `/tmp/pymol_gizmo.json`, and `readGizmo()` consequently nils `gizmo`/`activeMoveObject`. **Do not write assertions that depend on `readGizmo()` finding an active gizmo** — live Python owns that file and will overwrite anything a test seeds into it.
  - Assert on **tap emissions**, not on temp-file side effects.
- **Unit-test command:**
  ```
  cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
  ```
  Both `-skipPackagePluginValidation` and `-skipMacroValidation` are required (mlx-swift CudaBuild plugin).
- **`PyMOLEngine.shared` is a singleton** shared by every test in the target. Every test must leave it in a clean state.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` | Modify | The three mode setters + the `runPython` test seam. All changes are localized to four existing functions; no new files or types. |
| `swiftui/PyMOLViewerTests/DesignModeStateTests.swift` | Modify | Fixture hygiene (`setUp`/`tearDown`) + four new tests. Existing three tests stay as-is. |

No new files. The change is deliberately confined to the two files that already own this behaviour.

## Reference: exact strings emitted by the teardown paths

Assertions match on substrings of these (never on exact array equality — see Task 1 Step 4):

| Teardown | Emitted Python | Assert on |
|---|---|---|
| Move | `"from pymol import metal_move as _mm\n_mm.cleanup()"` | `_mm.cleanup()` |
| Measure | `"from pymol import appkit_measure as _am\n_am.reset()"` | `_am.reset()` |
| Adjust-frame push | `"from pymol import metal_move as _mm\n_mm.set_adjust(0)"` | `set_adjust` |

---

### Task 1: DEBUG `runPython` tap + hermetic test fixture

Delivers the test seam everything downstream asserts through, plus a known-clean singleton fixture. The tap is the *only* way to observe teardown: `metal_move.cleanup()` and `appkit_measure.reset()` leave no Swift-side trace, and (per Global Constraints) the gizmo temp file is owned by live Python and cannot be used as an assertion surface.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:1077-1080` (`runPython`)
- Test: `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PyMOLEngine.pythonTap: ((String) -> Void)?` (DEBUG-only, `@MainActor`, settable from tests); `DesignModeStateTests.gizmoJSONPath: String` (static); `DesignModeStateTests.resetEngine()` (private instance method).

- [ ] **Step 1: Write the failing seam test**

Add to `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`, inside the existing `DesignModeStateTests` class, above the existing tests:

```swift
    /// The gizmo geometry temp file readGizmo() consumes. Deleted between tests
    /// as belt-and-braces hygiene: in practice live Python rewrites it on every
    /// _emit(), but a stale file from a real RayMol run must never be able to
    /// leak an active gizmo into a fixture.
    static let gizmoJSONPath =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_gizmo.json")

    override func setUp() {
        super.setUp()
        resetEngine()
    }

    override func tearDown() {
        resetEngine()
        super.tearDown()
    }

    /// PyMOLEngine.shared is a singleton shared by every test in the target, so
    /// each test must both start and end from a known state. Deleting the gizmo
    /// temp file gives readGizmo() a known-empty baseline — without it, a stale
    /// file left by a real RayMol run on the dev machine leaks into assertions
    /// and makes them machine-dependent.
    private func resetEngine() {
        let e = PyMOLEngine.shared
        e.pythonTap = nil          // first: the resets below emit Python
        e.setDesignMode(false)
        e.setMeasureMode(nil)
        e.setInteractionMode(.viewing)
        try? FileManager.default.removeItem(atPath: Self.gizmoJSONPath)
    }

    func testPythonTapObservesEmissions() {
        let e = PyMOLEngine.shared
        var captured: [String] = []
        e.pythonTap = { captured.append($0) }
        e.runPython("# probe")
        XCTAssertTrue(
            captured.contains("# probe"),
            "pythonTap must fire regardless of engine readiness "
            + "(isReady = \(e.isReady))")
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: **compile error** — `value of type 'PyMOLEngine' has no member 'pythonTap'`. That is the correct failure for this step.

- [ ] **Step 3: Add the seam**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, replace `runPython` (currently at `:1077-1080`):

```swift
    func runPython(_ code: String) {
        guard isReady else { return }
        PyMOLBridge_RunPython(code)
    }
```

with:

```swift
#if DEBUG
    /// Test seam: observes every Python string this engine emits. Placed BEFORE
    /// the isReady guard so it reports what the engine *intended* to run,
    /// independent of whether the core is initialized — that keeps tests of
    /// teardown behaviour (metal_move.cleanup / appkit_measure.reset, which
    /// leave no Swift-side trace) working under any host configuration.
    /// Compiled out of Release; cost in Debug is one optional-closure call.
    var pythonTap: ((String) -> Void)? = nil
#endif

    func runPython(_ code: String) {
#if DEBUG
        pythonTap?(code)
#endif
        guard isReady else { return }
        PyMOLBridge_RunPython(code)
    }
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, all four tests passing (three pre-existing + the new seam test). Baseline before this task was 3 tests passing in ~3.2 s.

**Tap discipline for every later test:** seeding `adjustFrameToggle`/`moveShiftHeld` fires `didSet → syncAdjustFrame()`, which emits `set_adjust(...)`. Always assert with `captured.contains { $0.contains(...) }`. Never compare the captured array for equality, and never assert on emission counts.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/DesignModeStateTests.swift
git commit -m "test(engine): DEBUG runPython tap + hermetic DesignModeState fixture

The tap fires before the isReady guard so unit tests, which run against an
uninitialized engine, can assert on emitted teardown Python.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: `setDesignMode` tears down Move and Measure properly

The core fix. Both new tests fail before the change and pass after.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:1944-1954` (`setDesignMode`)
- Test: `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`

**Interfaces:**
- Consumes: `PyMOLEngine.pythonTap`, `DesignModeStateTests.resetEngine()` (Task 1).
- Produces: no signature changes — `setDesignMode(_ on: Bool)` keeps its shape.

- [ ] **Step 1: Write the two failing teardown tests**

Append to `DesignModeStateTests`:

```swift
    func testEnteringDesignFromMoveTearsDownMoveState() {
        let e = PyMOLEngine.shared
        // SEEDING ORDER MATTERS — two constraints:
        //  1. Move mode first: the hoveredHandle didSet is guarded on
        //     interactionMode == .move, so seeding it earlier is a no-op.
        //  2. adjustFrameToggle/moveShiftHeld fire didSet -> syncAdjustFrame(),
        //     which calls readGizmo() and NILS gizmo + activeMoveObject (live
        //     Python writes active:false — no structure is loaded). So set the
        //     toggles BEFORE the plain fields, or the seed is wiped out.
        e.setInteractionMode(.move)
        e.adjustFrameToggle = true      // triggers readGizmo
        e.moveShiftHeld = true          // syncAdjustFrame early-returns here
        e.hoveredHandle = .rz           // didSet emits set_hover, no readGizmo
        e.armedAxis = .y
        e.activeMoveObject = "mol1"
        e.gizmo = GizmoGeometry(json: ["obj": "mol1", "center": [0.0, 0.0]])
        XCTAssertNotNil(e.gizmo, "precondition: seeded gizmo geometry")
        XCTAssertNotNil(e.activeMoveObject, "precondition: seeded active object")

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }   // install AFTER seeding

        e.setDesignMode(true)

        XCTAssertTrue(e.designMode)
        XCTAssertEqual(e.interactionMode, .viewing)
        XCTAssertNil(e.activeMoveObject)
        XCTAssertNil(e.gizmo)
        XCTAssertNil(e.armedAxis)
        XCTAssertNil(e.hoveredHandle)
        XCTAssertFalse(e.adjustFrameToggle)
        XCTAssertFalse(e.moveShiftHeld)
        XCTAssertTrue(
            captured.contains { $0.contains("_mm.cleanup()") },
            "metal_move.cleanup() must run, or the _move_gizmo CGO is stranded "
            + "in the scene where the user cannot delete it. Captured: \(captured)")
    }

    func testEnteringDesignFromMeasureRunsMeasureReset() {
        let e = PyMOLEngine.shared
        e.setMeasureMode(.distance)
        XCTAssertEqual(e.measureMode, .distance, "precondition: in measure mode")

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }

        e.setDesignMode(true)

        XCTAssertTrue(e.designMode)
        XCTAssertNil(e.measureMode)
        // The measureMode flag alone passes both before and after the fix — the
        // bare assignment already nils it. Only the emission proves teardown ran.
        XCTAssertTrue(
            captured.contains { $0.contains("_am.reset()") },
            "appkit_measure.reset() must run. Captured: \(captured)")
    }
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: **both new tests FAIL**.
- `testEnteringDesignFromMoveTearsDownMoveState` — fails on the first stale field (`XCTAssertNil(e.activeMoveObject)`) and on the missing `_mm.cleanup()`.
- `testEnteringDesignFromMeasureRunsMeasureReset` — passes its flag assertions, fails on the missing `_am.reset()`.

If either *passes* at this step, stop: the fix is already present or the test is not exercising the path.

- [ ] **Step 3: Apply the fix**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, replace the comment and body of `setDesignMode` (currently `:1944-1954`):

```swift
    /// Enter or exit Design mode. Entering clears Move and Measure (mutually
    /// exclusive). The actual MPNN controller startup/teardown is handled by
    /// the UI layer that observes this flag; this setter is deliberately
    /// Python-free so it is safe to call from unit tests and in any state.
    func setDesignMode(_ on: Bool) {
        if on {
            if interactionMode == .move { interactionMode = .viewing }
            if measureMode != nil { measureMode = nil }
        }
        designMode = on
    }
```

with:

```swift
    /// Enter or exit Design mode. Entering clears Move and Measure (mutually
    /// exclusive) through their canonical setters — NOT bare assignments. Move
    /// and Measure teardown is imperative and lives INSIDE those setters
    /// (metal_move.cleanup() / appkit_measure.reset()), so a bare assignment
    /// silently skips it and strands the "_move_gizmo" CGO in the scene, where
    /// its "_" prefix hides it from the object panel and the user cannot delete
    /// it. designMode is the odd one out: its teardown is observer-driven
    /// (.onChange(of: engine.designMode) in ContentView), so it fires on any
    /// assignment — which is why the reverse direction can stay a plain set.
    ///
    /// The MPNN controller startup/teardown is handled by that UI observer.
    /// Still safe to call in any state: the only Python reached goes through
    /// runPython, which no-ops via `guard isReady` before the core is up, and
    /// otherwise runs exactly the paths the "exit Move" / "exit Measure"
    /// buttons already use.
    func setDesignMode(_ on: Bool) {
        if on {
            // Recursion-free: both setters only touch designMode in their
            // ENTERING branch, and the clearing block below is `if on`-guarded.
            if interactionMode == .move { setInteractionMode(.viewing) }
            if measureMode != nil { setMeasureMode(nil) }
        }
        designMode = on
    }
```

- [ ] **Step 4: Run them to verify they pass**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, six tests passing. The three pre-existing tests must still pass — they assert the flag values this change preserves.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/DesignModeStateTests.swift
git commit -m "fix(modes): setDesignMode must tear down Move and Measure, not just clear their flags

Bare assignments skipped metal_move.cleanup() and appkit_measure.reset(),
stranding the undeletable _move_gizmo CGO when entering Design from Move.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Symmetric delegation from the sibling setters

Behaviour-preserving today (`setDesignMode(false)` is exactly `designMode = false`, because the clearing block is `if on`-guarded). Included so that if imperative teardown is ever added to `setDesignMode`, the siblings cannot silently skip it — the precise bug class Task 2 fixed.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:1926` (in `setMeasureMode`) and `:2194` (in `setInteractionMode`)
- Test: `swiftui/PyMOLViewerTests/DesignModeStateTests.swift` (existing tests cover this)

**Interfaces:**
- Consumes: `setDesignMode(_:)` from Task 2.
- Produces: no signature changes.

- [ ] **Step 1: Apply both edits**

In `setMeasureMode`, replace:

```swift
            if interactionMode == .move { setInteractionMode(.viewing) }   // mutually exclusive
            designMode = false                                              // mutually exclusive
```

with:

```swift
            if interactionMode == .move { setInteractionMode(.viewing) }   // mutually exclusive
            setDesignMode(false)                                            // mutually exclusive
```

In `setInteractionMode`, replace:

```swift
            if measureMode != nil { setMeasureMode(nil) }   // mutually exclusive
            designMode = false                               // mutually exclusive
```

with:

```swift
            if measureMode != nil { setMeasureMode(nil) }   // mutually exclusive
            setDesignMode(false)                             // mutually exclusive
```

Both are recursion-free: `setDesignMode(false)` skips its `if on` clearing block entirely.

- [ ] **Step 2: Run the suite to verify nothing regressed**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, still six tests. `testDesignModeIsMutuallyExclusive` and `testEnteringMoveModeClearsDesign` are the ones that exercise these two lines — if either hangs or stack-overflows, the recursion analysis is wrong; revert and report.

- [ ] **Step 3: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "refactor(modes): siblings clear Design via setDesignMode, not a bare assignment

No behaviour change today; prevents future imperative Design teardown from
being silently skipped.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Stop the Move teardown resurrecting the gizmo it just cleared

`adjustFrameToggle` and `moveShiftHeld` both carry `didSet { syncAdjustFrame() }`, and `syncAdjustFrame` calls `readGizmo()`, which re-reads `/tmp/pymol_gizmo.json` — still "active", because `cleanup()` runs at the *end* of the branch. Exiting Move mode with adjust-frame or Shift active therefore repopulates `gizmo` and `activeMoveObject` immediately after they are nil'd.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:2196-2205` (`setInteractionMode` else-branch)
- Test: `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`

**Interfaces:**
- Consumes: `PyMOLEngine.pythonTap`, `DesignModeStateTests.resetEngine()` (Task 1).
- Produces: no signature changes.

- [ ] **Step 1: Write the failing regression test**

The observable is the **emission**, not the temp file. Asserting on `gizmo`
being nil afterwards would be vacuous here: no structure is loaded in the test
host, so live Python writes `{"active": false}` and `readGizmo()` nils the
fields anyway — the test would pass before and after the fix. What actually
distinguishes fixed from broken is whether `syncAdjustFrame` runs at all during
teardown, and that is directly observable through the tap.

Append to `DesignModeStateTests`:

```swift
    func testExitingMoveDoesNotPushAdjustFrameDuringTeardown() {
        let e = PyMOLEngine.shared
        e.setInteractionMode(.move)
        e.adjustFrameToggle = true      // arms lastAdjustSent = true

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }   // install AFTER arming

        e.setInteractionMode(.viewing)

        // Before the fix, clearing adjustFrameToggle fires didSet ->
        // syncAdjustFrame(), which emits set_adjust(0) AND calls readGizmo() —
        // re-reading the gizmo temp file before cleanup() has invalidated it,
        // which resurrects gizmo + activeMoveObject on any host where that file
        // still describes an active gizmo. Clearing lastAdjustSent first makes
        // syncAdjustFrame early-return, so no set_adjust is emitted at all.
        XCTAssertFalse(
            captured.contains { $0.contains("set_adjust") },
            "teardown must not push adjust-frame: syncAdjustFrame's readGizmo() "
            + "can resurrect the state cleanup() is about to drop. "
            + "Captured: \(captured)")
        // cleanup() must still be the thing that runs.
        XCTAssertTrue(
            captured.contains { $0.contains("_mm.cleanup()") },
            "Captured: \(captured)")
        XCTAssertFalse(e.adjustFrameToggle)
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests/testExitingMoveDoesNotPushAdjustFrameDuringTeardown 2>&1 | tail -30
```

Expected: **FAIL** on the `set_adjust` assertion — the captured array will
contain `"from pymol import metal_move as _mm\n_mm.set_adjust(0)"`.

If it passes at this step, the arming did not take (`lastAdjustSent` never
became true). Check that `e.adjustFrameToggle = true` was set *while*
`interactionMode == .move` — `adjustFrameActive` is
`interactionMode == .move && (adjustFrameToggle || moveShiftHeld)`, so arming
outside Move mode is a no-op.

- [ ] **Step 3: Apply the ordering fix**

In `setInteractionMode`'s else-branch, replace:

```swift
        } else {
            armedAxis = nil
            hoveredHandle = nil
            activeMoveObject = nil
            gizmo = nil
            adjustFrameToggle = false
            moveShiftHeld = false
            lastAdjustSent = false
            runPython("from pymol import metal_move as _mm\n_mm.cleanup()")
        }
```

with:

```swift
        } else {
            armedAxis = nil
            hoveredHandle = nil
            activeMoveObject = nil
            gizmo = nil
            // Clear lastAdjustSent FIRST. adjustFrameToggle and moveShiftHeld
            // both carry `didSet { syncAdjustFrame() }`, and syncAdjustFrame
            // calls readGizmo(), which re-reads the gizmo temp file — still
            // "active" here, because cleanup() below hasn't run yet. That
            // resurrects the gizmo and activeMoveObject just cleared above.
            // Zeroing lastAdjustSent first makes syncAdjustFrame's
            // `want != lastAdjustSent` guard early-return. The skipped
            // set_adjust(0) round-trip is redundant: cleanup() tears the whole
            // gizmo down a few lines later.
            lastAdjustSent = false
            adjustFrameToggle = false
            moveShiftHeld = false
            runPython("from pymol import metal_move as _mm\n_mm.cleanup()")
        }
```

- [ ] **Step 4: Run the full class to verify it passes**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, seven tests passing.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/DesignModeStateTests.swift
git commit -m "fix(move): don't resurrect the gizmo while tearing down Move mode

syncAdjustFrame's readGizmo() re-read the still-active temp file mid-teardown
and repopulated gizmo + activeMoveObject. Clear lastAdjustSent first so the
didSet early-returns.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Cross-platform build + full regression

`PyMOLEngine.swift` is shared between macOS and iOS. Nothing in this change is platform-conditional, but the project has a history of shared-file edits compiling on one platform and breaking the other, so both are verified explicitly.

**Files:** none modified (verification only).

**Interfaces:** none.

- [ ] **Step 1: Full macOS test target**

```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`. Every suite in `PyMOLViewerTests`, not just `DesignModeStateTests`. `DesignInferenceSmokeTests` self-skips here (no `MPNN_INFERENCE`).

- [ ] **Step 2: iOS build**

```bash
cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -25
```

Expected: `** BUILD SUCCEEDED **`. If the scheme name differs, list them with `xcodebuild -list -project PyMOLViewer.xcodeproj` and use the iOS app scheme.

- [ ] **Step 3: Functional check — no stray gizmo entering Design from Move**

Use the `mac-vm-test` skill (project `CLAUDE.md` requires the disposable VM for macOS functional testing, not the host UI). In the app: load any structure, enter Move mode, confirm the gizmo is drawn, then enter Design mode from the toolbar. Confirm the gizmo disappears.

Then verify the CGO is actually gone rather than merely hidden, via the console:

```
print([n for n in cmd.get_names('all') if n.startswith('_move_gizmo')])
```

Expected: `[]`.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin HEAD
```

Then open a PR into `master` with `gh pr create -R javierbq/RayMol` (the `gh` CLI defaults to the upstream `schrodinger/pymol-open-source`, so `-R` is required). Describe: the observer-driven vs imperative teardown asymmetry, the three fixes, and — if applicable — the Task 4 Step 2 note about the pre-fix failure not being demonstrable under the test host.

---

## Notes for the implementer

- **Do not "simplify" `setDesignMode` back to bare assignments.** The old comment claimed they were needed for unit-test safety; they were not. `runPython`'s `guard isReady` provides that, and `isReady` defaults to `false`.
- **`lastAdjustSent` is `private`** and deliberately unasserted. Task 4's test covers it behaviourally. Do not widen its access to test it directly.
- **The test target must build Debug** for `pythonTap` to exist. The `UnitTests_macOS` scheme does this; do not run these tests under a Release configuration.
