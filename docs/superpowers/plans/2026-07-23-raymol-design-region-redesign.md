# RayMol #217 Phase 2c — Region Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-residue region redesign to RayMol Design mode — run MPNNKit `design()` over a dropdown-picked selection with the rest of the sequence held fixed, fold the single deterministic result into the existing Phase-2b working copy, with a one-level revert and a repurposed pill row for palette restriction.

**Architecture:** Extend the existing `DesignController` edit session (no parallel subsystem). A new region-designation surface (a selection dropdown) snapshots the region into `selectedResidueIndices`; the 20-AA propensity pill row switches to active/inactive palette toggles in region mode; a `redesignSelection()` action calls `design()` off the main serial queue (fixed rest, greedy, fixed seed, palette→`omit`), scatters the result into `editedSequence`, then reuses 2b's rescore + whole-structure repack. Revert restores a pre-batch snapshot.

**Tech Stack:** Swift 5.9 / SwiftUI + Combine (`@MainActor` controller), MPNNKit (mlx-swift) via `#if RAYMOL_MPNN`, Python `raymol_design` helpers marshalling JSON through `$TMPDIR`, XCTest (macOS), PyMOL `testing.PyMOLTestCase`.

## Global Constraints

- **Platform:** macOS only. All new Swift code lives inside `#if RAYMOL_MPNN` (the iOS build must be unaffected). Do not reference iOS-only symbols from shared code.
- **Never mutate the original object in place** — region redesign folds into the working copy `<obj>_design`; the source object is only ever `disable`d / re-`enable`d (Phase-2b lifecycle).
- **Determinism:** `design()` must run with `temperature = 0` (greedy) **and** `seed = 0` (its decode order is drawn from `MLXRandom.normal`, so a fixed seed is required for reproducibility).
- **Index spaces (the crux, spec §6):** `editedSequence` is **full-length** (indexed like `set.residues`). `design()`/`score()`/`repack()` operate in **valid-projected** space (length `L = validResidues.count`). `fixedPositions`, `nativeSequence`, `omit`, and `design()`'s returned indices are all valid-projected. The Swift `set.residues[i].valid` mask is the single source of truth for converting between the two.
- **Git flow:** work on branch `claude/raymol-217-region-redesign-phase2c` (already created); never push to `master`; open a PR with `gh ... -R javierbq/RayMol`.
- **Worktree build prereqs:** this worktree needs the `deps_macos` and `build_macos_swiftui` symlinks from the main repo, and a `libpymol_core.a` from at least one prior full build. **2c changes no C++**, so the existing core lib is reused — `xcodebuild` only recompiles Swift. Do not clean-build the core.
- **MPNNKit version:** pinned at ≥ 0.1.2 in `project.yml` (`from: 0.1.2`) and `Package.resolved`. Do not change it. `xcodegen generate` regenerates a `minimumVersion = 0.1.2` consistent with `project.yml`, so regen is safe.
- **Test commands** (run from repo root unless noted):
  - Swift unit: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -40`
  - Swift build: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
  - On-host inference: `cd swiftui && MPNN_INFERENCE=1 xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS_Inference -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignEditInferenceTests 2>&1 | tail -40`
  - Python: `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`

---

## Task 1: Python selection helpers (`raymol_design.py`)

**Files:**
- Modify: `modules/pymol/raymol_design.py` (add `_selection_names`, `_obj_residue_order`, `list_design_selections`, `selected_design_indices` after the existing `enumerate_design_residues`, near line 57)
- Test: `testing/tests/raymol/design_region.py` (create)

**Interfaces:**
- Produces:
  - `list_design_selections(obj: str, state) -> str` — writes `$TMPDIR/raymol_design_selections.json` = `{"selections": [{"name": str, "n": int}, ...]}` (selections intersecting `obj`'s polymer residues, count > 0). Returns `"DESIGN_SELECTIONS:<count>"`.
  - `selected_design_indices(obj: str, selection: str, state) -> str` — writes `$TMPDIR/raymol_design_selected.json` = `{"indices": [int, ...]}` (0-based positions in `obj`'s polymer guide order — the same order `enumerate_design_residues` uses). Returns `"DESIGN_SELECTED:<count>"`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/raymol/design_region.py`:

```python
"""Tests for pymol.raymol_design region-redesign selection helpers.

Runs via the repo test runner:
    pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
"""
import json
import os
import tempfile

from pymol import cmd, testing


class TestDesignRegion(testing.PyMOLTestCase):
    def _peptide(self):
        cmd.reinitialize()
        cmd.fab('AAAAA', 'm1')          # 5-residue poly-Ala with full backbone
        return 'm1'

    def testSelectedIndicesMapInGuideOrder(self):
        obj = self._peptide()
        cmd.select('reg', '%s and resi 2+4' % obj)
        from pymol import raymol_design as rd
        marker = rd.selected_design_indices(obj, 'reg', 1)
        self.assertTrue(marker.startswith('DESIGN_SELECTED:'))
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selected.json')) as f:
            data = json.load(f)
        # resi 2 and 4 → 0-based guide-order indices 1 and 3.
        self.assertEqual(data['indices'], [1, 3])

    def testListSelectionsCountsAndFilters(self):
        obj = self._peptide()
        cmd.select('reg', '%s and resi 2+3+4' % obj)
        cmd.select('empty', 'resn HOH')          # matches nothing on m1
        from pymol import raymol_design as rd
        rd.list_design_selections(obj, 1)
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_selections.json')) as f:
            data = json.load(f)
        names = {d['name']: d['n'] for d in data['selections']}
        self.assertEqual(names.get('reg'), 3)
        self.assertNotIn('empty', names)         # zero-intersection selection filtered out
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`
Expected: FAIL — `AttributeError: module 'pymol.raymol_design' has no attribute 'selected_design_indices'`.

- [ ] **Step 3: Write minimal implementation**

In `modules/pymol/raymol_design.py`, add immediately after `enumerate_design_residues` (after its `return 'DESIGN_RESIDUES:ready'`, ~line 57):

```python
def _selection_names():
    """Named selections in the session (includes the active 'sele' if present)."""
    try:
        return list(cmd.get_names('selections'))
    except Exception:
        return []


def _obj_residue_order(obj):
    """(chain, resi) for obj's polymer residues in canonical guide order —
    the same order enumerate_design_residues emits, so indices align with the
    Swift DesignResidueSet.residues array."""
    order = []
    cmd.iterate('(%s) and polymer and guide' % obj,
                'order.append((chain, resi))', space={'order': order})
    return order


def list_design_selections(obj, state):
    """Write named selections that intersect obj's polymer residues, with counts.

    Output: $TMPDIR/raymol_design_selections.json = {'selections': [{'name','n'}]}.
    Selections with zero intersecting residues are omitted. The count is polymer
    residues in the intersection; the exact designable subset (full backbone) is
    resolved at pick time by the Swift valid mask. Returns a short marker.
    """
    int(state)  # tolerate str/float; state is not needed to count residues
    out = []
    for name in _selection_names():
        try:
            n = cmd.count_atoms('(%s) and (%s) and polymer and guide' % (obj, name))
        except Exception:
            n = 0
        if n > 0:
            out.append({'name': name, 'n': int(n)})
    try:
        with open(_tmp('raymol_design_selections.json'), 'w') as f:
            json.dump({'selections': out}, f)
    except Exception:
        pass
    return 'DESIGN_SELECTIONS:%d' % len(out)


def selected_design_indices(obj, selection, state):
    """Map a selection on obj → full-length residue indices in guide order.

    Non-polymer atoms in the selection are ignored. Output:
    $TMPDIR/raymol_design_selected.json = {'indices': [int]}. Returns a marker.
    """
    int(state)  # tolerate str/float
    order = _obj_residue_order(obj)
    sel_res = set()
    try:
        cmd.iterate('(%s) and (%s) and polymer and guide' % (obj, selection),
                    'sel_res.add((chain, resi))', space={'sel_res': sel_res})
    except Exception:
        pass
    indices = [i for i, cr in enumerate(order) if cr in sel_res]
    try:
        with open(_tmp('raymol_design_selected.json'), 'w') as f:
            json.dump({'indices': indices}, f)
    except Exception:
        pass
    return 'DESIGN_SELECTED:%d' % len(indices)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`
Expected: PASS (2 tests, `OK`).

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_region.py
git commit -m "feat(design): #217 2c — raymol_design selection→indices helpers"
```

---

## Task 2: Controller region designation + palette state (`DesignController`)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignResidues.swift` (add `DesignSelectionOption`)
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift` (closure typealiases, injected properties, init params, `@Published` region state, `RedesignSnapshot`, designation/palette actions, `clearRegionState()` wired into `exit`/`focusAwait`/`teardownEditSession`, `#if DEBUG` inject hook)
- Test: `swiftui/PyMOLViewerTests/DesignRegionTests.swift` (create)

**Interfaces:**
- Consumes: `DesignResidueSet` (`.residues`, `.validResidues`, `.state`), `DesignResidue.valid`, existing `focusObject`, `lastSet`, `editedSequence` (Phase-2b).
- Produces (used by Tasks 3, 4, 6, 7):
  - `struct DesignSelectionOption: Identifiable, Equatable { let name: String; let count: Int; var id: String { name } }`
  - `typealias DesignRegionFn = (_ residues: [MPNNModel.Residue], _ fixedPositions: Set<Int>, _ nativeSequence: [Int], _ omit: [Set<Int>]) throws -> [Int]`
  - `typealias ListSelectionsFn = (_ obj: String, _ state: Int) -> [DesignSelectionOption]`
  - `typealias SelectedIndicesFn = (_ obj: String, _ selection: String, _ state: Int) -> [Int]`
  - `@Published private(set) var selectedResidueIndices: [Int]` (full-length, valid only)
  - `@Published var paletteAllowed: Set<Int>` (default `Set(0..<20)`)
  - `@Published private(set) var selectedSelectionName: String?`
  - `@Published private(set) var availableSelections: [DesignSelectionOption]`
  - `@Published private(set) var redesignSnapshot: RedesignSnapshot?` (`struct RedesignSnapshot { let seq: [Int]; let editCount: Int }`)
  - `@Published private(set) var isRedesigning: Bool`
  - `var regionModeActive: Bool { !selectedResidueIndices.isEmpty }`
  - `func refreshSelections()`, `func pickSelection(_ name: String)`, `func clearSelection()`, `func togglePalette(_ aa: Int)`
  - `#if DEBUG func injectRegion(designRegion:listSelections:selectedIndices:)`
  - Init gains params `designRegion:`, `listSelections:`, `selectedIndices:` (all defaulted).

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/DesignRegionTests.swift`:

```swift
#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignRegionTests: XCTestCase {

    func makeController() -> DesignController {
        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        return DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }
    private func allValid(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    func testRegionModeTogglesWithSelection() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _ in [0, 1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        XCTAssertFalse(c.regionModeActive)
        c.pickSelection("reg")
        XCTAssertTrue(c.regionModeActive)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1])
        XCTAssertEqual(c.selectedSelectionName, "reg")
        c.clearSelection()
        XCTAssertFalse(c.regionModeActive)
        XCTAssertNil(c.selectedSelectionName)
    }

    func testSelectionFiltersInvalidResidues() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _ in [0, 1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, false, true])
        c.pickSelection("reg")
        XCTAssertEqual(c.selectedResidueIndices, [0, 2])   // idx 1 (invalid) dropped
    }

    func testTogglePalette() {
        let c = makeController()
        XCTAssertEqual(c.paletteAllowed.count, 20)
        c.togglePalette(4)
        XCTAssertFalse(c.paletteAllowed.contains(4))
        c.togglePalette(4)
        XCTAssertTrue(c.paletteAllowed.contains(4))
        c.togglePalette(20)                                // X: ignored (out of 0..<20)
        XCTAssertEqual(c.paletteAllowed.count, 20)
    }

    func testRefreshSelectionsPopulatesList() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 0, count: r.count) },
                       listSelections: { _, _ in
                           [DesignSelectionOption(name: "loopA", count: 12),
                            DesignSelectionOption(name: "sele", count: 5)]
                       })
        c.setFocusForTest("m1", nativeSequence: [5, 5], validFlags: allValid(2))
        c.refreshSelections()
        XCTAssertEqual(c.availableSelections.map { $0.name }, ["loopA", "sele"])
        XCTAssertEqual(c.availableSelections.first?.count, 12)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -40`
Expected: FAIL to compile — `value of type 'DesignController' has no member 'injectRegion'` / `regionModeActive` / `pickSelection` etc. (Also requires the new file be in the target — Step 3 runs `xcodegen generate`.)

- [ ] **Step 3: Write minimal implementation**

In `swiftui/PyMOLViewer/Shared/DesignResidues.swift`, inside the `#if RAYMOL_MPNN` block (after `DesignResidueSet`):

```swift
/// One entry in the region-redesign selection dropdown.
struct DesignSelectionOption: Identifiable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}
```

In `swiftui/PyMOLViewer/Shared/DesignController.swift`:

(a) Add typealiases after the `SticksFn` typealias (~line 73):

```swift
    /// Run MPNN region design off-main. Returns designed alphabet indices, length = residues.count.
    typealias DesignRegionFn = (_ residues: [MPNNModel.Residue],
                                _ fixedPositions: Set<Int>,
                                _ nativeSequence: [Int],
                                _ omit: [Set<Int>]) throws -> [Int]
    /// List named selections intersecting `obj`'s designable residues.
    typealias ListSelectionsFn = (_ obj: String, _ state: Int) -> [DesignSelectionOption]
    /// Map a named selection on `obj` → full-length residue indices (guide order).
    typealias SelectedIndicesFn = (_ obj: String, _ selection: String, _ state: Int) -> [Int]
```

(b) Add injected properties after `pinnedIndicatorFn` (~line 98):

```swift
    private var designRegionFn: DesignRegionFn = { r, _, _, _ in Array(repeating: 0, count: r.count) }
    private var listSelectionsFn: ListSelectionsFn = { _, _ in [] }
    private var selectedIndicesFn: SelectedIndicesFn = { _, _, _ in [] }
```

(c) Add region state after `editSourceObject` (~line 122):

```swift
    /// Full-length residue indices (into set.residues) of the picked region, valid only.
    @Published private(set) var selectedResidueIndices: [Int] = []
    /// Allowed amino-acid alphabet indices (0..<20) for region sampling; toggled off → omit.
    @Published var paletteAllowed: Set<Int> = Set(0..<20)
    /// Name of the selection currently designated as the region (nil = single-residue mode).
    @Published private(set) var selectedSelectionName: String?
    /// Selections available in the dropdown, refreshed on open.
    @Published private(set) var availableSelections: [DesignSelectionOption] = []
    /// Pre-batch sequence + editCount captured before the last region redesign (nil = nothing to revert).
    @Published private(set) var redesignSnapshot: RedesignSnapshot?
    /// True while a region design() call is running off-main.
    @Published private(set) var isRedesigning = false
    /// Region mode = a selection is designated. Drives the pill-row hat-switch + Redesign button.
    var regionModeActive: Bool { !selectedResidueIndices.isEmpty }

    struct RedesignSnapshot { let seq: [Int]; let editCount: Int }
```

(d) Add `designToken` next to the other tokens (~line 133):

```swift
    /// Incremented on each region redesign; a superseded design() checks this before applying.
    private var designToken: Int = 0
```

(e) Add the three init params to the `init(...)` signature (after `pinnedIndicator:`), and assign them:

```swift
                     pinnedIndicator: @escaping PinnedIndicatorFn = { _, _, _ in },
                     designRegion: @escaping DesignRegionFn = { r, _, _, _ in Array(repeating: 0, count: r.count) },
                     listSelections: @escaping ListSelectionsFn = { _, _ in [] },
                     selectedIndices: @escaping SelectedIndicesFn = { _, _, _ in [] }) {
```

and in the body after `self.pinnedIndicatorFn = pinnedIndicator`:

```swift
        self.designRegionFn = designRegion
        self.listSelectionsFn = listSelections
        self.selectedIndicesFn = selectedIndices
```

(f) Add designation + palette actions (place in the `// MARK: – Edit session` region, e.g. before `beginEditIfNeeded`):

```swift
    // MARK: – Region redesign: designation + palette (Task 2)

    /// Refresh the dropdown from the current session selections (call on menu open).
    func refreshSelections() {
        guard let obj = focusObject, let set = lastSet[obj] else { availableSelections = []; return }
        availableSelections = listSelectionsFn(obj, set.state)
    }

    /// Designate `name` as the region: snapshot its designable residues (valid only)
    /// as `selectedResidueIndices`, in full-length space. Enters region mode.
    func pickSelection(_ name: String) {
        guard let obj = focusObject, let set = lastSet[obj] else { return }
        let full = selectedIndicesFn(obj, name, set.state)
        let valid = full.filter { $0 >= 0 && $0 < set.residues.count && set.residues[$0].valid }
        selectedResidueIndices = valid
        selectedSelectionName = valid.isEmpty ? nil : name
    }

    /// Clear the region → return to single-residue (Phase-2b) mode.
    func clearSelection() {
        selectedResidueIndices = []
        selectedSelectionName = nil
    }

    /// Toggle an amino acid (0..<20) in/out of the region sampling palette.
    func togglePalette(_ aa: Int) {
        guard aa >= 0, aa < 20 else { return }
        if paletteAllowed.contains(aa) { paletteAllowed.remove(aa) } else { paletteAllowed.insert(aa) }
    }

    /// Reset all region state. Region state can exist without an edit session
    /// (a selection picked before the first redesign), so this is called on
    /// mode exit and focus change too, not only in teardownEditSession.
    private func clearRegionState() {
        selectedResidueIndices = []
        selectedSelectionName = nil
        paletteAllowed = Set(0..<20)
        redesignSnapshot = nil
        isRedesigning = false
        availableSelections = []
        designToken += 1   // cancel any in-flight region design
    }
```

(g) Wire `clearRegionState()` into the three lifecycle spots:
- In `exit()`, after `pinnedIndicatorFn("", "", "")` (before `rescoreToken += 1`), add: `clearRegionState()`
- In `focusAwait(_:)`, inside `if previous != object { ... }`, after `pinnedIndicatorFn("", "", "")`, add: `clearRegionState()`
- In `teardownEditSession(discardCopy:)`, before the final `compareEnabled = false` line, add: `clearRegionState()`

(h) Add the `#if DEBUG` inject hook in the `// MARK: – Test hooks` block:

```swift
    /// Override the region closures for testing (Task 2/3).
    func injectRegion(designRegion: @escaping DesignRegionFn,
                      listSelections: @escaping ListSelectionsFn = { _, _ in [] },
                      selectedIndices: @escaping SelectedIndicesFn = { _, _, _ in [] }) {
        self.designRegionFn = designRegion
        self.listSelectionsFn = listSelections
        self.selectedIndicesFn = selectedIndices
    }
```

Then regenerate the Xcode project so the new test file joins the target:

```bash
cd swiftui && xcodegen generate
```

(Safe: `project.yml` already pins `from: 0.1.2`, so the regenerated `minimumVersion` matches.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -40`
Expected: PASS (4 tests). Also confirm the full suite still builds: rerun without `-only-testing`.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignResidues.swift swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignRegionTests.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "feat(design): #217 2c — region designation + palette state on DesignController"
```

---

## Task 3: Controller redesign action + revert (`DesignController`)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift` (`redesignSelection`, `redesignSelectionAwait`, `revertRedesign`; clear revert in `applyMutationState`)
- Test: `swiftui/PyMOLViewerTests/DesignRegionTests.swift` (add tests)

**Interfaces:**
- Consumes: Task 2's region state + `designRegionFn`; Phase-2b `beginEditIfNeeded`, `rescoreWorkingObject`, `repackNowAwait`, `mutateDisplay`, `editedSequence`, `editCount`, `repackDirty`.
- Produces (used by Task 7 UI): `func redesignSelection()`, `func redesignSelectionAwait() async`, `func revertRedesign()`.

- [ ] **Step 1: Write the failing test**

Append to `swiftui/PyMOLViewerTests/DesignRegionTests.swift` (inside the class):

```swift
    // Stub score/edit closures used by every redesign test.
    private func wireEdit(_ c: DesignController) {
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
    }

    func testRedesignScattersOnlyIntoRegion() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _ in [1, 3] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5, 5], validFlags: allValid(5))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [5, 9, 5, 9, 5])   // only free positions changed
    }

    func testFixedPartitionIsComplementOfRegion() async {
        var capturedFixed: Set<Int>?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, fixed, native, _ in capturedFixed = fixed; return native },
                       selectedIndices: { _, _, _ in [0, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: allValid(4))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedFixed, [1, 3])               // complement of free {0,2} over L=4
    }

    func testValidProjectedPartitionAndNativeWithGaps() async {
        var capturedFixed: Set<Int>?; var capturedNative: [Int]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, fixed, native, _ in
            capturedFixed = fixed; capturedNative = native; return native
        }, selectedIndices: { _, _, _ in [0, 2] })          // full idx 0,2 selected; idx 1 invalid
        c.setFocusForTest("m1", nativeSequence: [5, 6, 7], validFlags: [true, false, true])
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        // valid residues full {0,2} → valid-projected {0,1}; both selected → free {0,1}, fixed {}.
        XCTAssertEqual(capturedFixed, [])
        XCTAssertEqual(capturedNative, [5, 7])              // valid-projected native (gap dropped)
    }

    func testScatterWithInvalidGap() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, _, _ in [9, 8] },   // valid-projected result (L=2)
                       selectedIndices: { _, _, _ in [2] })      // full idx 2 → valid-projected 1
        c.setFocusForTest("m1", nativeSequence: [5, 6, 7], validFlags: [true, false, true])
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [5, 6, 8])         // only full idx 2 changed → result[1]==8
    }

    func testNativeSequenceReflectsPriorEdits() async {
        var capturedNative: [Int]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _ in capturedNative = native; return native },
                       selectedIndices: { _, _, _ in [2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: allValid(4))
        await c.applyMutationAwait(residueIndex: 0, aa: 7)  // earlier manual edit
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedNative, [7, 5, 5, 5])        // manual edit carried into native
    }

    func testOmitDerivedFromPalette() async {
        var capturedOmit: [Set<Int>]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, omit in capturedOmit = omit; return native },
                       selectedIndices: { _, _, _ in [1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        c.togglePalette(4); c.togglePalette(12)
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedOmit?.count, 3)              // one per valid residue (L=3)
        XCTAssertEqual(capturedOmit?.first, [4, 12])        // inactive set, uniform
    }

    func testEmptyPaletteBlocksRedesign() async {
        var called = false
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _ in called = true; return native },
                       selectedIndices: { _, _, _ in [0] })
        c.setFocusForTest("m1", nativeSequence: [5, 5], validFlags: allValid(2))
        c.pickSelection("reg")
        for i in 0..<20 where c.paletteAllowed.contains(i) { c.togglePalette(i) }
        await c.redesignSelectionAwait()
        XCTAssertFalse(called)
    }

    func testRevertRestoresPreRedesignAndKeepsEarlierEdits() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _ in [2, 3] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: allValid(4))
        await c.applyMutationAwait(residueIndex: 0, aa: 7)  // earlier manual edit
        let ec = c.editCount
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [7, 5, 9, 9])
        XCTAssertNotNil(c.redesignSnapshot)
        c.revertRedesign()
        XCTAssertEqual(c.editedSequence, [7, 5, 5, 5])      // redesign undone; manual edit survives
        XCTAssertEqual(c.editCount, ec)
        XCTAssertNil(c.redesignSnapshot)
    }

    func testManualEditAfterRedesignClearsRevert() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _ in [1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.redesignSnapshot)
        await c.applyMutationAwait(residueIndex: 2, aa: 3)
        XCTAssertNil(c.redesignSnapshot)                    // revert invalidated by a manual edit
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run the Swift unit command from Global Constraints.
Expected: FAIL to compile — `has no member 'redesignSelectionAwait'` / `revertRedesign`.

- [ ] **Step 3: Write minimal implementation**

In `DesignController.swift`, add the actions after the Task-2 designation block:

```swift
    // MARK: – Region redesign: the design() action + revert (Task 3)

    /// Fire-and-forget region redesign (UI button). Wraps redesignSelectionAwait.
    func redesignSelection() { Task { await redesignSelectionAwait() } }

    /// Run design() over the picked region with the rest of the sequence fixed,
    /// scatter the result into editedSequence, then rescore + (auto)repack.
    /// Snapshots editedSequence first for a one-level revert.
    func redesignSelectionAwait() async {
        guard !selectedResidueIndices.isEmpty else { return }
        guard paletteAllowed.contains(where: { $0 >= 0 && $0 < 20 }) else { return }  // ≥1 allowed AA
        beginEditIfNeeded()
        guard editing, let focus = focusObject, let set = lastSet[focus] else { return }

        // One-level revert snapshot (captures earlier manual edits + editCount).
        redesignSnapshot = RedesignSnapshot(seq: editedSequence, editCount: editCount)

        // Full-length ↔ valid-projected maps (the single-source-of-truth conversion).
        let validFullIndices = set.residues.enumerated().filter { $0.element.valid }.map { $0.offset }
        var fullToValid: [Int: Int] = [:]
        for (v, f) in validFullIndices.enumerated() { fullToValid[f] = v }
        let residues = set.validResidues
        let L = residues.count
        let nativeValid = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let freeValid = Set(selectedResidueIndices.compactMap { fullToValid[$0] })
        guard !freeValid.isEmpty else { redesignSnapshot = nil; return }
        let fixed = Set(0..<L).subtracting(freeValid)
        let inactive = Set((0..<20).filter { !paletteAllowed.contains($0) })
        let omit = Array(repeating: inactive, count: L)
        let designFn = designRegionFn

        isRedesigning = true
        designToken += 1
        let token = designToken

        let result: [Int]? = try? await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                do { cont.resume(returning: try designFn(residues, fixed, nativeValid, omit)) }
                catch { cont.resume(throwing: error) }
            }
        }

        guard token == designToken else { isRedesigning = false; return }
        isRedesigning = false

        guard let result, result.count == L else {
            if let snap = redesignSnapshot { editedSequence = snap.seq; editCount = snap.editCount }
            redesignSnapshot = nil
            errorText = "Region redesign failed"
            return
        }

        // Scatter designed identities into free (full-length) positions only.
        var changed = 0
        let w = workingObject
        for v in freeValid {
            let f = validFullIndices[v]
            let aa = result[v]
            if editedSequence[f] != aa {
                editedSequence[f] = aa
                changed += 1
                if let w, f < set.residues.count {
                    let r = set.residues[f]
                    mutateDisplay(w, r.chain, r.resi, aa)   // backbone-only until repack
                }
            }
        }
        editCount += changed
        repackDirty = true

        await rescoreWorkingObject()
        if autoRepack { await repackNowAwait() }
    }

    /// Undo the last region redesign: restore the pre-batch sequence + editCount.
    /// One level; earlier manual edits (captured in the snapshot) are preserved.
    func revertRedesign() {
        guard let snap = redesignSnapshot else { return }
        editedSequence = snap.seq
        editCount = snap.editCount
        redesignSnapshot = nil
        repackDirty = true
        Task {
            await rescoreWorkingObject()
            if autoRepack { await repackNowAwait() }
        }
    }
```

In `applyMutationState(residueIndex:aa:)`, invalidate a pending revert on any manual edit — add right after `repackDirty = true` (~line 556):

```swift
        redesignSnapshot = nil   // a manual edit invalidates the one-level region-redesign revert
```

- [ ] **Step 4: Run test to verify it passes**

Run the Swift unit command.
Expected: PASS (all `DesignRegionTests`, ~13 tests).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignRegionTests.swift
git commit -m "feat(design): #217 2c — region redesign action + one-level revert"
```

---

## Task 4: Engine wiring (`PyMOLEngine`)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (`designController` construction, ~line 2136–2146: add `designRegion`, `listSelections`, `selectedIndices` closures)

**Interfaces:**
- Consumes: Task 2's init params; `loadedMPNNModel()`, `runPython`, `MPNNModel.DesignOptions`/`design`, Task 1's Python helpers.
- Produces: a fully-wired `designController` (no new public API). Verified by a successful build (no cheap unit test — these closures call Python/MLX; behaviour is covered by Task 5 inference + Task 8 functional).

- [ ] **Step 1: Add the closures**

In `PyMOLEngine.swift`, inside the `DesignController(` call, change the final `pinnedIndicator:` closure's trailing `}` to `},` and append:

```swift
        designRegion: { [weak self] residues, fixed, native, omit in
            guard let self else {
                throw NSError(domain: "raymol.design", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Engine deallocated"])
            }
            let model = try self.loadedMPNNModel()
            var opts = MPNNModel.DesignOptions()
            opts.temperature = 0            // greedy
            opts.seed = 0                   // fixed decode order → reproducible
            opts.fixedPositions = fixed
            opts.nativeSequence = native
            opts.omit = omit
            return try model.design(residues, options: opts).indices
        },
        listSelections: { [weak self] obj, state in
            guard let self else { return [] }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.list_design_selections('\(obj)', \(state))
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_selections.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["selections"] as? [[String: Any]] else { return [] }
            return arr.compactMap { d in
                guard let name = d["name"] as? String, let n = d["n"] as? Int else { return nil }
                return DesignSelectionOption(name: name, count: n)
            }
        },
        selectedIndices: { [weak self] obj, sel, state in
            guard let self else { return [] }
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.selected_design_indices('\(obj)', '\(sel)', \(state))
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_selected.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idx = root["indices"] as? [Int] else { return [] }
            return idx
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd swiftui && xcodebuild build -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the unit suite (no regression)**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(design): #217 2c — wire designRegion/listSelections/selectedIndices to the engine"
```

---

## Task 5: On-host `design()` region inference test

**Files:**
- Modify: `swiftui/PyMOLViewerTests/DesignEditInferenceTests.swift` (add `testDesignRegionFixesRestAndHonorsOmit`, reusing the file's `Self.makeResidues()` / `Self.nativeSequence`)

**Interfaces:**
- Consumes: real `MPNNModel.design`, `MPNNGate.packURL`, existing static fixtures in the test file.

- [ ] **Step 1: Write the test**

Add inside `final class DesignEditInferenceTests` (before the closing brace at line 110):

```swift
    func testDesignRegionFixesRestAndHonorsOmit() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MPNN_INFERENCE"] == "1",
            "Real-inference; set MPNN_INFERENCE=1 to enable.")
        let packURL = try XCTUnwrap(MPNNGate.packURL)
        let model = try MPNNModel(packDirectory: packURL)

        let residues = Self.makeResidues()
        let native = Self.nativeSequence
        let L = residues.count

        // Redesign only positions 1 and 2; hold the rest fixed to native.
        let free: Set<Int> = [1, 2]
        let fixed = Set(0..<L).subtracting(free)
        // Omit CYS (index 4) everywhere.
        let omit = Array(repeating: Set([4]), count: L)

        var opts = MPNNModel.DesignOptions()
        opts.temperature = 0; opts.seed = 0
        opts.fixedPositions = fixed
        opts.nativeSequence = native
        opts.omit = omit
        let r1 = try model.design(residues, options: opts)
        XCTAssertEqual(r1.indices.count, L)

        // Fixed positions keep their native identity.
        for i in fixed {
            XCTAssertEqual(r1.indices[i], native[i],
                           "fixed position \(i) must remain native")
        }
        // Omitted AA never appears at a designed position.
        for i in free {
            XCTAssertNotEqual(r1.indices[i], 4, "CYS omitted but appeared at \(i)")
        }
        // Determinism: same inputs → identical result.
        let r2 = try model.design(residues, options: opts)
        XCTAssertEqual(r1.indices, r2.indices, "greedy + fixed seed must be reproducible")

        print("[DesignRegion] free \(Array(free).sorted()) → \(free.map { r1.indices[$0] })")
    }
```

- [ ] **Step 2: Run the gated inference test**

Run: `cd swiftui && MPNN_INFERENCE=1 xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS_Inference -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/DesignEditInferenceTests/testDesignRegionFixesRestAndHonorsOmit 2>&1 | tail -40`
Expected: PASS (loads ~24 MB weights, runs MLX). If MLX cannot init on this host, it will fail loudly — do not silence; report.

- [ ] **Step 3: Commit**

```bash
git add swiftui/PyMOLViewerTests/DesignEditInferenceTests.swift
git commit -m "test(design): #217 2c — on-host design() region: fixed rest, omit, determinism"
```

---

## Task 6: UI — pill palette mode + strip region highlight (`ContentView`)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (`DesignOverlayView.propensityRow` branch + new `paletteRow`/`palettePill`; `DesignSequenceStripView.seqColumn` region highlight)

**Interfaces:**
- Consumes: `controller.regionModeActive`, `controller.paletteAllowed`, `controller.togglePalette`, `controller.selectedResidueIndices`.

- [ ] **Step 1: Branch the pill row into palette mode**

In `DesignOverlayView`, replace the `propensityRow(_:)` opening so it forks on region mode. Change the function to return `AnyView` and add the palette builders. Replace the current `return ScrollView(...)` at the end of `propensityRow` with `return AnyView(ScrollView(...))`, and add at the top of the function body (right after the signature `{`):

```swift
        if controller.regionModeActive {
            return AnyView(paletteRow())
        }
```

Then add, inside `DesignOverlayView` (after `aaPill(...)`):

```swift
    // MARK: – Region palette row (numbers hidden; pills are active/inactive toggles)

    private func paletteRow() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    Button { controller.togglePalette(i) } label: {
                        palettePill(index: i, active: controller.paletteAllowed.contains(i))
                    }
                    .buttonStyle(.plain)
                    .help(controller.paletteAllowed.contains(i)
                          ? "Allowed during redesign — click to exclude"
                          : "Excluded from redesign — click to allow")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 5)
    }

    private func palettePill(index i: Int, active: Bool) -> some View {
        let letter = i < DesignColor.mpnnAlphabet.count ? DesignColor.mpnnAlphabet[i] : "?"
        return Text(letter)
            .font(.system(size: 12, weight: active ? .bold : .regular, design: .monospaced))
            .foregroundColor(active ? .white : theme.active.panelText.color.opacity(0.32))
            .frame(width: 30, height: 36)
            .background(active
                        ? theme.active.accent.color.opacity(0.85)
                        : theme.active.panelText.color.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(active ? theme.active.accent.color : Color.clear, lineWidth: 1))
    }
```

- [ ] **Step 2: Add the region highlight to the sequence strip**

In `DesignSequenceStripView.seqColumn(index:residue:)`, add a bottom accent bar for region residues. After the existing `.overlay(isPinned ? ... : nil)` modifier, append:

```swift
        .overlay(alignment: .bottom) {
            if controller.selectedResidueIndices.contains(i) {
                Rectangle()
                    .fill(theme.active.accent.color)
                    .frame(height: 2)
            }
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run the Swift build command.
Expected: `** BUILD SUCCEEDED **`. (SwiftUI views aren't unit-tested; the visual is verified in Task 8. Watch for the type-checker "reasonable time" error — if it appears, the `AnyView` wrap of both `propensityRow` branches is what keeps it in bounds.)

- [ ] **Step 4: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "feat(design): #217 2c — pill palette mode + sequence-strip region highlight"
```

---

## Task 7: UI — region strip (dropdown + Redesign/Revert) (`ContentView`)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (new `DesignRegionStripView`; insert into `DesignOverlayView.body`)

**Interfaces:**
- Consumes: `controller.refreshSelections`, `availableSelections`, `pickSelection`, `clearSelection`, `selectedSelectionName`, `regionModeActive`, `selectedResidueIndices`, `paletteAllowed`, `redesignSelection`, `redesignSnapshot`, `revertRedesign`, `isRedesigning`.

- [ ] **Step 1: Add the region strip view**

In `ContentView.swift`, add a new view before `DesignEditStripView` (near line 3252):

```swift
// MARK: – Region-redesign strip (Phase 2c)

// Selection dropdown + Redesign/Revert + "Redesigning region…" spinner. Its own
// View struct so @ObservedObject re-renders on region-state @Published changes.
private struct DesignRegionStripView: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager
    @State private var showPicker = false

    var body: some View {
        Group {
            if controller.isRedesigning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Redesigning region…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            selectionButton
            if controller.regionModeActive {
                stripDivider
                Text("palette \(controller.paletteAllowed.filter { $0 < 20 }.count)/20")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
                stripDivider
                Button { controller.redesignSelection() } label: {
                    Text("Redesign selection · \(controller.selectedResidueIndices.count) res")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(theme.active.accent.color.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundColor(theme.active.accent.color)
                }
                .buttonStyle(.plain)
                .disabled(controller.paletteAllowed.filter { $0 < 20 }.isEmpty)
                .help("Redesign the selected residues; the rest of the sequence is held fixed")
            }
            if controller.redesignSnapshot != nil {
                stripDivider
                Button { controller.revertRedesign() } label: {
                    Text("Revert redesign")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Undo the last region redesign (keeps earlier manual edits)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var selectionButton: some View {
        Button {
            controller.refreshSelections()
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "lasso").font(.system(size: 10))
                Text(controller.selectedSelectionName ?? "Select region…")
                    .font(.system(size: 11)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundColor(theme.active.panelText.color.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(theme.active.panelText.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) { pickerContent }
    }

    private var pickerContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if controller.availableSelections.isEmpty {
                Text("No selections — create one first")
                    .font(.system(size: 11)).foregroundColor(.secondary).padding(8)
            } else {
                ForEach(controller.availableSelections) { opt in
                    Button {
                        controller.pickSelection(opt.name)
                        showPicker = false
                    } label: {
                        HStack {
                            Text(opt.name).font(.system(size: 12))
                            Spacer(minLength: 12)
                            Text("\(opt.count) res")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5).frame(minWidth: 190)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if controller.regionModeActive {
                Divider()
                Button {
                    controller.clearSelection()
                    showPicker = false
                } label: {
                    Text("Clear selection")
                        .font(.system(size: 12)).foregroundColor(.red)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6).frame(maxWidth: 260)
    }

    private var stripDivider: some View {
        Rectangle().fill(theme.active.panelText.color.opacity(0.2)).frame(width: 0.5, height: 14)
    }
}
```

- [ ] **Step 2: Insert it into the overlay**

In `DesignOverlayView.body`, after the propensity-row `propensityRow(controller.activePropensity)` line and before the edit-strip block, add:

```swift
            // ── Region-redesign strip (Phase 2c) ─────────────────────────────
            if !controller.focusResidues.isEmpty {
                Divider().opacity(0.3)
                DesignRegionStripView(controller: controller, theme: theme)
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run the Swift build command.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "feat(design): #217 2c — region strip: selection dropdown + Redesign/Revert"
```

---

## Task 8: Functional verification in a disposable macOS VM

**Files:** none (verification only).

**Interfaces:** exercises the full stack end-to-end.

- [ ] **Step 1: Build + launch in the VM via the mac-vm-test skill**

Use the `mac-vm-test` (or `raymol-mac-vm`) skill to build the macOS app and run it in an isolated VM. Launch with `RAYMOL_MCP_AUTOTRUST=1` so MCP needs no Allow click.

- [ ] **Step 2: Drive the region-redesign flow and assert**

Over MCP / AX, perform and verify:
1. Load a small structure (e.g. `fetch 1ubq, async=0` or a bundled PDB); enter Design mode (⌃D); focus the object → confidence coloring appears.
2. Create a selection: `select loop, <obj> and resi 7-11`.
3. Open the region strip's **Select region…** dropdown → `loop · 5 res` is listed; pick it → the 5 residues gain the accent underline in the sequence strip, the pill row switches to palette toggles (letters only, no numbers), and **Redesign selection · 5 res** appears.
4. Toggle **C** off in the palette → "palette 19/20".
5. Click **Redesign selection** → "Redesigning region…" shows; on completion the heatmap recolors, sidechains repack (Auto-repack default on), and no redesigned position is Cys. Capture a screenshot of the recolored region.
6. Click **Revert redesign** → the region returns to native identities; capture a screenshot.
7. **Keep** → the `<obj>_design` object remains; **Discard** on a fresh run removes it and re-shows the original.

Record before/after screenshots as verification evidence (per `raymol_mcp_live_capture`: capture the live Metal frame with `screencapture -l<winid>`, not PNG-over-MCP).

- [ ] **Step 3: No commit** (verification only). If a defect is found, return to the relevant task, fix with a test, and re-verify.

---

## Task 9: Ship — docs, memory, PR

**Files:**
- Modify: `docs/superpowers/specs/2026-07-23-raymol-design-region-redesign-design.md` (only if the build surfaced a deviation from the spec — otherwise leave as-is)
- Update memory: `raymol_217_mpnnkit_design_phase1.md` (mark 2c merged; note the region flow) + `MEMORY.md` index line.

- [ ] **Step 1: Full green gate**

Run the full unit suite + a clean build:
```bash
cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20
```
Expected: all PASS. Then run the Python test (`pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`) → OK.

- [ ] **Step 2: Push + open PR**

```bash
git push -u origin claude/raymol-217-region-redesign-phase2c
gh pr create -R javierbq/RayMol --base master \
  --title "RayMol Design mode — region redesign (#217 Phase 2c)" \
  --body "$(cat <<'EOF'
Phase 2c of #217: multi-residue region redesign in Design mode.

- Pick an existing selection from a dropdown (filtered to the focus object's designable residues) → region snapshotted at pick-time.
- Pill row switches to active/inactive palette toggles in region mode (→ design() omit).
- `Redesign selection` runs MPNNKit `design()` deterministically (greedy + fixed seed) over the region with the rest held fixed; result folds into the 2b working copy → rescore + repack.
- `Revert redesign` restores the pre-batch snapshot (earlier manual edits preserved). Keep/Discard as in 2b.
- macOS only; iOS unaffected. Spec + plan under docs/superpowers/.

Tests: DesignRegionTests (pure-logic), DesignEditInferenceTests.testDesignRegion… (gated on-host), tests/raymol/design_region.py (Python), plus VM functional verification.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Update memory**

Edit `raymol_217_mpnnkit_design_phase1.md` — change the Phase-2c line from PENDING to the shipped summary (dropdown-picked region, palette-toggle pills, deterministic single result, one-level revert; valid-projected indexing; files: `DesignController` region actions, `DesignRegionStripView`, `raymol_design.list_design_selections`/`selected_design_indices`). Keep 2d/2e/Predict as the remaining slices. Update the matching `MEMORY.md` index line.

- [ ] **Step 4: Commit any doc/memory changes** (memory files are outside the repo; the spec/plan are already committed).

---

## Self-Review

**1. Spec coverage** (against `2026-07-23-raymol-design-region-redesign-design.md`):
- §1 success criteria 1–3 (region-only change, determinism, palette) → Task 3 (`testRedesignScattersOnlyIntoRegion`, `testOmitDerivedFromPalette`) + Task 5 (`testDesignRegionFixesRestAndHonorsOmit`). ✓
- §1 criterion 4 (recolor + repack) → Task 3 reuses `rescoreWorkingObject`/`repackNowAwait`; Task 8 visual. ✓
- §1 criterion 5 (revert preserves earlier edits) → Task 3 `testRevertRestoresPreRedesignAndKeepsEarlierEdits`. ✓
- §1 criterion 6 (off-main, token) → Task 3 `designToken` + `inferenceQueue`. ✓
- §1 criterion 7 (macOS-only, no 2a/2b regression) → all code `#if RAYMOL_MPNN`; Task 4 Step 3 re-runs the full suite. ✓
- §4 dropdown source/filter/snapshot → Task 1 (`list_design_selections`/`selected_design_indices`) + Task 2 (`pickSelection` snapshot). ✓
- §5 pill hat-switch → Task 6. ✓
- §6 valid-projected indexing → Task 3 (`testValidProjectedPartitionAndNativeWithGaps`, `testScatterWithInvalidGap`). ✓
- §7 apply/revert/Keep/Discard → Task 3 + reuse of 2b teardown (Task 2 `clearRegionState`). ✓
- §8 whole-structure repack → Task 3 reuses `repackNowAwait` (no new repack code). ✓
- §9 edge cases (multi-object, 0 designable, failure rollback, mode-exit teardown, palette-empty) → Task 1 filter, Task 2 `clearRegionState`, Task 3 failure rollback + `testEmptyPaletteBlocksRedesign`. ✓
- §10 UI (dropdown, pill switch, highlight, spinner) → Tasks 6, 7. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows the assertions and the exact run command with expected output. ✓

**3. Type consistency:** `DesignRegionFn`/`ListSelectionsFn`/`SelectedIndicesFn` signatures identical across Task 2 (typealias), Task 2 (init params + inject hook), Task 4 (engine closures), and the tests. `DesignSelectionOption(name:count:)` used identically in Task 2, Task 4, tests. `RedesignSnapshot(seq:editCount:)` consistent in Task 2 (decl) / Task 3 (use). `selectedResidueIndices` full-length everywhere; valid-projected conversion only inside `redesignSelectionAwait`. Method names (`pickSelection`, `clearSelection`, `togglePalette`, `refreshSelections`, `redesignSelection`, `redesignSelectionAwait`, `revertRedesign`, `regionModeActive`, `injectRegion`) match across controller, tests, and UI. ✓
