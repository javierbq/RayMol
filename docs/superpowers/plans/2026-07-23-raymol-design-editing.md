# RayMol Design-mode Point-Mutation Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make RayMol's macOS Design mode editable — click a propensity pill to mutate a residue on a non-destructive working copy, auto re-score, and repack sidechains on a toggle/on-demand.

**Architecture:** Extends the Phase-2a `DesignController` (an `@MainActor ObservableObject` doing off-main serial scoring with a job token) with an edit session: a working-copy object, an `editedSequence`, and mutate/rescore/repack actions driven by injected closures (unit-testable without MLX/Metal). The real closures wire to `raymol_design.py` helpers via `PyMOLEngine.runPython`. UI lives in the existing `DesignOverlayView` (`#if RAYMOL_MPNN`).

**Tech Stack:** Swift 5.9 / SwiftUI (macOS), XcodeGen project, MPNNKit (`proteinmpnn-mlx` SPM package, `repack`/`score`), embedded PyMOL Python (`modules/pymol/raymol_design.py`), XCTest (`PyMOLViewerTests`).

## Global Constraints

- macOS-only this slice; all editing code is `#if RAYMOL_MPNN`-gated; the iOS target must still compile (no `DesignController`/MPNNKit leakage into iOS).
- App target stays **Swift 5.9** language mode; do **not** hand-edit `swiftui/PyMOLViewer.xcodeproj/project.pbxproj` — run `cd swiftui && xcodegen generate`; discard xcodegen UUID churn (`git checkout -- …/project.pbxproj`) before committing if the only change is `TEMP_` reshuffling.
- Swift module for `@testable import` is **`RayMol`**; test files need BOTH `import MPNNKit` and `@testable import RayMol`.
- Unit tests run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:PyMOLViewerTests/<Class>`; gated real-inference tests use `-scheme UnitTests_macOS_Inference` (injects `MPNN_INFERENCE=1`).
- Python tests run via the symlink recipe: `ln -sf "$(pwd)/modules/pymol/raymol_design.py" /opt/homebrew/lib/python3.14/site-packages/pymol/raymol_design.py; cd testing && pymol -ckqy testing.py --run tests/raymol/<file>.py; cd ..; rm -f /opt/homebrew/lib/python3.14/site-packages/pymol/raymol_design.py`.
- **MPNN scores from backbone + sequence (sidechain-independent)** → rescore needs no repack. Repack is a separate geometry step.
- Never modify the original object in place; the original is only `disable`/`enable`d. Discard = delete the working copy.
- `MPNNModel.ScoreResult(logProbs:currentAALogProb:)` and `MPNNModel.repack(_:sequence:) -> RepackResult{pdb:String, atomConfidence:[[Float]]}` are available (Phase 1/2a).

---

## File Structure

- `modules/pymol/raymol_design.py` — **modify**: add working-copy + display helpers (create/enable/disable, load repacked coords, backbone-only display for stale residues).
- `swiftui/PyMOLViewer/Shared/DesignController.swift` — **modify**: edit-session state, `editedSequence`, mutate/rescore/repack actions, keep/discard, new injected closures.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — **modify**: provide the real edit closures (call the Python helpers via `runPython`; construct the working copy; load repacked coords).
- `swiftui/PyMOLViewer/Shared/ContentView.swift` (`DesignOverlayView`) — **modify**: interactive pills + edit-session strip controls + "Repacking sidechains…".
- `swiftui/PyMOLViewerTests/DesignEditingTests.swift` — **create**: unit tests for the edit-session logic.
- `swiftui/PyMOLViewerTests/DesignEditInferenceTests.swift` — **create**: gated real mutate→repack→rescore test.
- `testing/tests/raymol/design_editing.py` — **create**: Python helper tests.

---

### Task 1: Python working-copy & display helpers

**Files:**
- Modify: `modules/pymol/raymol_design.py` (append new functions)
- Test: `testing/tests/raymol/design_editing.py`

**Interfaces:**
- Produces (called from Swift via `runPython`):
  - `make_working_copy(src, dst) -> "DESIGN_WORK:<dst>"` — `cmd.create(dst, src)` then `cmd.disable(src)`; if `dst` exists, delete it first.
  - `set_compare(src, on) -> "DESIGN_CMP:ok"` — `cmd.enable(src)` if `on` else `cmd.disable(src)`.
  - `discard_working_copy(src, dst) -> "DESIGN_DISCARD:ok"` — `cmd.delete(dst)`; `cmd.enable(src)`.
  - `set_residue_backbone_only(obj, chain, resi, on) -> "DESIGN_BBONLY:ok"` — when `on`, `cmd.hide('sticks'/'lines'/'spheres', <residue sidechain>)` (sidechain = `not name N+CA+C+O`) so stale atoms aren't shown; when `off`, no-op (repack + rep refresh restores).
  - `load_repacked(obj, pdb_str) -> "DESIGN_REPACKED:ok"` — replace `obj`'s coordinates from an all-atom PDB string produced by `repack()`, preserving the object name and the current confidence coloring where possible (use `cmd.read_pdbstr` into a temp name, `cmd.update(obj, tmp)` to copy coords by matching atoms, then `cmd.delete(tmp)`; fall back to replacing the object if topology changed).

- [ ] **Step 1: Write the failing test**

Create `testing/tests/raymol/design_editing.py`:

```python
import os, tempfile
from pymol import cmd, testing

class TestDesignEditing(testing.PyMOLTestCase):
    def testMakeAndDiscardWorkingCopy(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src')
        self.assertEqual(rd.make_working_copy('src', 'src_design'), 'DESIGN_WORK:src_design')
        self.assertIn('src_design', cmd.get_object_list())
        self.assertEqual(cmd.count_atoms('src'), cmd.count_atoms('src_design'))
        # original disabled, copy enabled
        self.assertEqual(cmd.get_object_list('enabled src'), [])
        rd.discard_working_copy('src', 'src_design')
        self.assertNotIn('src_design', cmd.get_object_list())
        self.assertEqual(cmd.get_object_list('enabled src'), ['src'])

    def testCompareToggle(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('ala', 'src'); rd.make_working_copy('src', 'src_design')
        rd.set_compare('src', True);  self.assertEqual(cmd.get_object_list('enabled src'), ['src'])
        rd.set_compare('src', False); self.assertEqual(cmd.get_object_list('enabled src'), [])

    def testBackboneOnlyHidesSidechain(self):
        from pymol import raymol_design as rd
        cmd.reinitialize(); cmd.fragment('arg', 'm')     # ARG has a long sidechain
        cmd.show('sticks', 'm')
        before = cmd.count_atoms('m and rep sticks and sidechain')
        self.assertGreater(before, 0)
        rd.set_residue_backbone_only('m', '', '1', True)
        self.assertEqual(cmd.count_atoms('m and rep sticks and sidechain'), 0)
```

- [ ] **Step 2: Run to verify it fails**

Run (symlink recipe): expected FAIL — `AttributeError: module 'pymol.raymol_design' has no attribute 'make_working_copy'`.

- [ ] **Step 3: Implement the helpers**

Append to `modules/pymol/raymol_design.py` (reuse existing `_residue_sel`):

```python
# ---- Phase 2b: point-mutation editing helpers (additive) ----

def make_working_copy(src, dst):
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.create(dst, src)          # inherits source matrices → superposed
    cmd.disable(src)
    return 'DESIGN_WORK:%s' % dst

def set_compare(src, on):
    (cmd.enable if (bool(on) if isinstance(on, bool) else bool(int(on))) else cmd.disable)(src)
    return 'DESIGN_CMP:ok'

def discard_working_copy(src, dst):
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.enable(src)
    return 'DESIGN_DISCARD:ok'

def set_residue_backbone_only(obj, chain, resi, on):
    on = bool(on) if isinstance(on, bool) else bool(int(on))
    side = '(%s) and (not name N+CA+C+O)' % _residue_sel(obj, chain, resi)
    if on:
        for rep in ('sticks', 'lines', 'spheres', 'nb_spheres'):
            cmd.hide(rep, side)
    return 'DESIGN_BBONLY:ok'

def load_repacked(obj, pdb_str):
    tmp = cmd.get_unused_name('_rp')
    cmd.read_pdbstr(pdb_str, tmp)
    try:
        cmd.update(obj, tmp, matchmaker=1)   # copy coords onto matching atoms
    finally:
        cmd.delete(tmp)
    return 'DESIGN_REPACKED:ok'
```

- [ ] **Step 4: Run to verify it passes**

Run (symlink recipe): expected `OK` (3 tests). Confirm no leftover symlink.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_editing.py
git commit -m "feat(design): python working-copy + backbone-only + repacked-coord helpers (2b)"
```

---

### Task 2: DesignController edit-session state + mutate logic

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignEditingTests.swift` (create)

**Interfaces:**
- Consumes: the Phase-2a `DesignController` (has `focusObject`, `lastSet[obj]: DesignResidueSet`, the off-main `queue`, `jobToken`, injected `score`/`applyColoring` closures, `cache`).
- Produces (public API used by UI + later tasks):
  - `@Published private(set) var editing: Bool`
  - `@Published private(set) var editCount: Int`
  - `@Published private(set) var repackDirty: Bool`
  - `@Published var autoRepack: Bool` (default `false`)
  - `@Published private(set) var isRepacking: Bool`
  - `private(set) var workingObject: String?`
  - `private(set) var editedSequence: [Int]`
  - New injected closures (typealiases): `MakeWorkingCopyFn = (String) -> String`, `MutateDisplayFn = (String, Int, Int) -> Void` (obj, residueIndex, aa → set backbone-only for that residue), `DiscardFn = (String) -> Void`, `CompareFn = (Bool) -> Void`.
  - `func beginEditIfNeeded()` — creates the working copy on first edit (idempotent).
  - `func applyMutation(residueIndex: Int, aa: Int)` — pure state update (begins edit, sets `editedSequence`, `editCount`, `repackDirty=true`, calls `mutateDisplay`); does NOT itself rescore/repack (Tasks 3–4 add those).
  - `func discardEdits()` / `func keepEdits()`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/DesignEditingTests.swift`:

```swift
#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignEditingTests: XCTestCase {
    // Build a controller with stub closures + a 3-residue focus set (see helper below).
    func makeController(mutateLog: @escaping (Int, Int) -> Void = { _,_ in }) -> DesignController { … }

    func testFirstMutationBeginsEditAndMarksDirty() {
        var created: [String] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { src in created.append(src); return src + "_design" },
                     mutateDisplay: { _,_,_ in }, discard: { _ in }, compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])   // GLY,GLY,GLY
        c.applyMutation(residueIndex: 1, aa: 9)              // -> LEU
        XCTAssertTrue(c.editing)
        XCTAssertEqual(created, ["m1"])                      // working copy made once
        XCTAssertEqual(c.editedSequence[1], 9)
        XCTAssertEqual(c.editCount, 1)
        XCTAssertTrue(c.repackDirty)
        c.applyMutation(residueIndex: 2, aa: 9)              // second edit: no new copy
        XCTAssertEqual(created, ["m1"])
        XCTAssertEqual(c.editCount, 2)
    }

    func testDiscardResetsState() {
        var discarded: [String] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _,_,_ in },
                     discard: { discarded.append($0) }, compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5,5,5])
        c.applyMutation(residueIndex: 0, aa: 1)
        c.discardEdits()
        XCTAssertFalse(c.editing)
        XCTAssertEqual(c.editCount, 0)
        XCTAssertEqual(discarded, ["m1_design"])
    }
}
#endif
```

(Add small test-only hooks `injectEdit(...)`, `setFocusForTest(_:nativeSequence:)` to `DesignController` under `#if DEBUG`, mirroring the Phase-2a test hooks.)

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test … -only-testing:PyMOLViewerTests/DesignEditingTests` → FAIL (members `editing`, `applyMutation`, `injectEdit` not found).

- [ ] **Step 3: Implement the state + mutate logic**

In `DesignController` (`#if RAYMOL_MPNN`) add the published state, closures, and:

```swift
func beginEditIfNeeded() {
    guard !editing, let focus = focusObject else { return }
    let native = lastSet[focus]?.residues.map { $0.aa } ?? []
    editedSequence = native
    workingObject = makeWorkingCopy(focus)   // "<focus>_design"
    editing = true; editCount = 0; repackDirty = false
}

func applyMutation(residueIndex i: Int, aa: Int) {
    beginEditIfNeeded()
    guard editing, i >= 0, i < editedSequence.count, editedSequence[i] != aa else { return }
    editedSequence[i] = aa
    editCount += 1
    repackDirty = true
    if let w = workingObject { mutateDisplay(w, i, aa) }   // backbone-only for the stale residue
}

func discardEdits() {
    if let w = workingObject { discard(w) }
    editing = false; editCount = 0; repackDirty = false; isRepacking = false
    workingObject = nil; editedSequence = []
}

func keepEdits() {   // repack-if-dirty is wired in Task 4; here just end the session, keep the object
    editing = false; editCount = 0; repackDirty = false; workingObject = nil; editedSequence = []
}
```

- [ ] **Step 4: Run to verify it passes**

Run the same command → PASS (2 tests, assertions > 0).

- [ ] **Step 5: Commit**

```bash
cd swiftui && xcodegen generate && cd ..
git checkout -- swiftui/PyMOLViewer.xcodeproj/project.pbxproj 2>/dev/null || true
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignEditingTests.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "feat(design): edit-session state + applyMutation/discard/keep (2b)"
```

---

### Task 3: Auto re-score on edit

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignEditingTests.swift`

**Interfaces:**
- Consumes: Task 2 state; the Phase-2a `score` closure `ScoreFn = ([MPNNModel.Residue],[Int]) throws -> MPNNModel.ScoreResult` and `applyColoring`.
- Produces: `applyMutation` now also triggers an off-main rescore fed `editedSequence`, recolors the working object, refreshes propensities — job-token guarded. Test hook: `func rescoreAwait()` (awaitable, like Phase-2a `focusAwait`).

- [ ] **Step 1: Write the failing test**

Add:

```swift
func testMutationRescoresWithEditedSequence() async {
    var scoredSeqs: [[Int]] = []
    let c = makeController()
    c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _,_,_ in }, discard: { _ in }, compare: { _ in })
    c.injectScore { _, seq in scoredSeqs.append(seq)
        return MPNNModel.ScoreResult(logProbs: Array(repeating: Array(repeating: -3.0, count: 21), count: seq.count),
                                     currentAALogProb: Array(repeating: -3.0, count: seq.count)) }
    c.setFocusForTest("m1", nativeSequence: [5,5,5])
    await c.applyMutationAwait(residueIndex: 1, aa: 9)   // await the rescore
    XCTAssertEqual(scoredSeqs.last, [5,9,5])             // rescored with the EDITED sequence
}
```

- [ ] **Step 2: Run to verify it fails**

Run → FAIL (`applyMutationAwait` / `injectScore` not found, or `scoredSeqs.last != [5,9,5]`).

- [ ] **Step 3: Implement the rescore**

Have `applyMutation` (after the state update) kick an off-main rescore reusing the Phase-2a scoring block, but building residues from `workingObject`/`lastSet` and passing `editedSequence` as the sequence; on completion (job-token OK) call `applyColoring` on the working object and refresh the propensity cache entry. Provide `applyMutationAwait` for tests (the sync `applyMutation` wraps it in a `Task`).

```swift
func applyMutationAwait(residueIndex i: Int, aa: Int) async {
    beginEditIfNeeded()
    guard editing, i >= 0, i < editedSequence.count, editedSequence[i] != aa else { return }
    editedSequence[i] = aa; editCount += 1; repackDirty = true
    if let w = workingObject { mutateDisplay(w, i, aa) }
    guard let w = workingObject, let set = lastSet[focusObject ?? ""] else { return }
    jobToken += 1; let token = jobToken
    let residues = set.validResidues
    let seq = editedSequence               // captured value type
    let scoreFn = score
    let result: MPNNModel.ScoreResult? = try? await withCheckedThrowingContinuation { cont in
        queue.async { do { cont.resume(returning: try scoreFn(residues, seq)) } catch { cont.resume(throwing: error) } }
    }
    guard token == jobToken, let r = result else { return }
    let scores = DesignColor.scores(from: r, validMask: set.residues.map { $0.valid })
    cache.set(DesignCacheKey(object: w, state: 1, sequenceHash: seq.hashValue), scores)
    applyColoring(w, scores, colorMeaning, legendDomainFor(colorMeaning))
}
```

(Match the exact `applyColoring`/`legendDomain` names/shapes used in Phase-2a; `validResidues` for the model, full mask for alignment.)

- [ ] **Step 4: Run to verify it passes**

Run → PASS.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignEditingTests.swift
git commit -m "feat(design): auto re-score on mutation with edited sequence (2b)"
```

---

### Task 4: Repack action (toggle + dirty indicator)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignEditingTests.swift`

**Interfaces:**
- Consumes: Task 2/3 state; new injected closures `RepackFn = ([Int]) throws -> String` (edited sequence → all-atom PDB) and `LoadRepackedFn = (String, String) -> Void` (obj, pdb).
- Produces: `func repackNow()` (async `repackNowAwait()` for tests) — sets `isRepacking`, runs `repack(editedSequence)` off-main, loads coords into the working object, clears `repackDirty`; job-token guarded. `applyMutation*` calls `repackNow()` automatically iff `autoRepack`. `keepEdits()` repacks first if `repackDirty`.

- [ ] **Step 1: Write the failing test**

```swift
func testRepackClearsDirtyAndLoadsCoords() async {
    var repackedSeqs: [[Int]] = []; var loaded: [(String,String)] = []
    let c = makeController()
    c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _,_,_ in }, discard: { _ in }, compare: { _ in })
    c.injectScore { _, s in MPNNModel.ScoreResult(logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count), currentAALogProb: Array(repeating: -3, count: s.count)) }
    c.injectRepack(repack: { seq in repackedSeqs.append(seq); return "PDBDATA" },
                   loadRepacked: { obj, pdb in loaded.append((obj, pdb)) })
    c.setFocusForTest("m1", nativeSequence: [5,5,5])
    await c.applyMutationAwait(residueIndex: 0, aa: 1)
    XCTAssertTrue(c.repackDirty)
    await c.repackNowAwait()
    XCTAssertEqual(repackedSeqs.last, [1,5,5])
    XCTAssertEqual(loaded.last?.0, "m1_design")
    XCTAssertFalse(c.repackDirty)
    XCTAssertFalse(c.isRepacking)
}

func testAutoRepackRepacksOnEachEdit() async {
    var repacks = 0
    let c = makeController()
    c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _,_,_ in }, discard: { _ in }, compare: { _ in })
    c.injectScore { _, s in MPNNModel.ScoreResult(logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count), currentAALogProb: Array(repeating: -3, count: s.count)) }
    c.injectRepack(repack: { _ in repacks += 1; return "P" }, loadRepacked: { _,_ in })
    c.setFocusForTest("m1", nativeSequence: [5,5,5]); c.autoRepack = true
    await c.applyMutationAwait(residueIndex: 0, aa: 1)
    XCTAssertEqual(repacks, 1)
    XCTAssertFalse(c.repackDirty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run → FAIL (`repackNowAwait`/`injectRepack` not found).

- [ ] **Step 3: Implement repack**

```swift
func repackNowAwait() async {
    guard editing, let w = workingObject, repackDirty else { return }
    isRepacking = true
    jobToken += 1; let token = jobToken
    let seq = editedSequence; let repackFn = repack
    let pdb: String? = try? await withCheckedThrowingContinuation { cont in
        queue.async { do { cont.resume(returning: try repackFn(seq)) } catch { cont.resume(throwing: error) } }
    }
    guard token == jobToken else { isRepacking = false; return }
    if let pdb { loadRepacked(w, pdb); repackDirty = false }
    isRepacking = false
}
```

At the end of `applyMutationAwait`, after recolor: `if autoRepack { await repackNowAwait() }`. In `keepEdits()`: `if repackDirty { await repackNowAwait() }` (make `keepEdits` async or wrap).

- [ ] **Step 4: Run to verify it passes**

Run → PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignEditingTests.swift
git commit -m "feat(design): repack action + auto-repack toggle + dirty flag (2b)"
```

---

### Task 5: Wire the real edit closures on PyMOLEngine

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`

**Interfaces:**
- Consumes: Task 1 Python helpers; Task 2–4 closure typealiases on `DesignController`.
- Produces: the real closures injected into `designController` — `makeWorkingCopy` → `runPython make_working_copy`; `mutateDisplay` → set the resn on the working object's residue AND `set_residue_backbone_only(...on)`; `discard` → `discard_working_copy`; `compare` → `set_compare`; `repack` → build `[Residue]` from the working object + `editedSequence`, call the stored `MPNNModel.repack`, return `result.pdb`; `loadRepacked` → `runPython load_repacked`.

- [ ] **Step 1** — Verify (build only). Add the closures where `designController` is constructed (Phase-2a). For `mutateDisplay`, emit the mutation to the working object's residue: `cmd.alter("<obj> and chain X and resi Y", "resn='LEU'")` (map aa index → 3-letter via `MPNNModel.alphabet`), then `set_residue_backbone_only`. `repack` reuses the lazily-loaded `MPNNModel` (`loadedMPNNModel()`).
- [ ] **Step 2** — `cd swiftui && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation build 2>&1 | tail -6` → BUILD SUCCEEDED.
- [ ] **Step 3** — iOS Swift-compile regression: `xcodebuild -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS' build 2>&1 | tail -6` → only the expected `libpymol_core` link failure; no leakage.
- [ ] **Step 4: Commit**

```bash
git checkout -- swiftui/PyMOLViewer.xcodeproj/project.pbxproj 2>/dev/null || true
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "feat(design): wire real mutate/working-copy/repack closures on PyMOLEngine (2b)"
```

---

### Task 6: DesignOverlayView — interactive pills + edit strip

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (`DesignOverlayView`, `#if RAYMOL_MPNN`)

**Interfaces:**
- Consumes: `@ObservedObject var controller: DesignController` (already held); `applyMutation`, `repackNow`, `autoRepack`, `repackDirty`, `editCount`, `isRepacking`, `discardEdits`, `keepEdits`, compare toggle.

- [ ] **Step 1** — Make each propensity pill a `Button` calling `controller.applyMutation(residueIndex: activeIndex, aa: <pillIndex>)` (active = pinned ?? hovered residue index); disable when no active residue. Split into small subviews (type-checker).
- [ ] **Step 2** — Add the edit-session strip row (shown when `controller.editing`): `Toggle("Auto-repack", isOn: $controller.autoRepack)`; a `needs repack` button (highlighted when `repackDirty`, count = edits since repack) calling `controller.repackNow()`; a `compare` toggle; `Keep`/`Discard` buttons; an `editCount` readout. Show a `ProgressView` + "Repacking sidechains…" when `controller.isRepacking`.
- [ ] **Step 3** — Build macOS (as Task 5 Step 2) → BUILD SUCCEEDED; iOS Swift-compile regression clean.
- [ ] **Step 4: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "feat(design): interactive pills + edit-session strip (Auto-repack, needs-repack, compare, Keep/Discard) (2b)"
```

---

### Task 7: Real on-host cycle test + verification

**Files:**
- Create: `swiftui/PyMOLViewerTests/DesignEditInferenceTests.swift`

- [ ] **Step 1** — Gated (`MPNN_INFERENCE=1`) test: load the real `MPNNModel`, build a small `[Residue]` + native `[Int]`, produce an edited sequence (one position changed), call `model.repack(residues, sequence: edited)` → assert `pdb` is non-empty and side-chain coords at the mutated position differ from native; call `model.score(residues, sequence: edited, mode: .leaveOneOut)` → finite log-probs.

```swift
#if RAYMOL_MPNN
import XCTest; import MPNNKit; @testable import RayMol
final class DesignEditInferenceTests: XCTestCase {
  func testMutateRepackRescore() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["MPNN_INFERENCE"] == "1", "gated")
    let model = try MPNNModel(packDirectory: try XCTUnwrap(MPNNGate.packURL))
    let residues = /* small hardcoded backbone, len 8 */ …
    var seq = Array(repeating: 0, count: residues.count); seq[3] = 9   // mutate pos 3 -> LEU
    let rp = try model.repack(residues, sequence: seq)
    XCTAssertFalse(rp.pdb.isEmpty)
    let sr = try model.score(residues, sequence: seq, mode: .leaveOneOut, seed: 0)
    XCTAssertEqual(sr.logProbs.count, residues.count)
    XCTAssertTrue(sr.logProbs.allSatisfy { $0.allSatisfy { $0.isFinite } })
  }
}
#endif
```

- [ ] **Step 2** — Run gated: `xcodebuild test … -scheme UnitTests_macOS_Inference -only-testing:PyMOLViewerTests/DesignEditInferenceTests` → PASS.
- [ ] **Step 3** — Full regression: `-scheme UnitTests_macOS -only-testing:PyMOLViewerTests` (all Design suites incl. `DesignEditingTests`) → all pass; Python `design_editing.py` + existing raymol tests → green.
- [ ] **Step 4** — Functional (host): build + relaunch; enter Design mode, focus, click a pill → recolor (no repack), `needs repack` lights; click it → "Repacking sidechains…" → correct sidechains; toggle Auto-repack; compare; Keep; Discard restores original.
- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewerTests/DesignEditInferenceTests.swift swiftui/PyMOLViewer.xcodeproj
git commit -m "test(design): real mutate->repack->rescore host smoke + 2b verification"
```

---

## Self-Review

- **Spec coverage:** §2 workflow → Tasks 5/6 (wiring+UI); §3 decoupling → Tasks 3 (rescore) + 4 (repack); §4 working copy → Tasks 1/2/5; §5 cycle → Tasks 3/4/5; §6 UI → Task 6; §7 edges → Tasks 2 (same-AA no-op, discard) + 4 (failure rollback via job-token/`try?`) + 6; §9 testing → Tasks 1–4,7. Covered.
- **Placeholder scan:** UI tasks (5/6) give structure + exact calls rather than every SwiftUI line (adapts to the existing `DesignOverlayView`); all *logic/test* steps carry complete code. `Task 7` residue fixture marked `…` — the implementer hardcodes a small backbone (same pattern as the Phase-2a inference smoke).
- **Type consistency:** `applyMutation`/`applyMutationAwait`, `repackNow`/`repackNowAwait`, `editedSequence`, `repackDirty`, `autoRepack`, `isRepacking`, `workingObject`, closure names (`makeWorkingCopy`/`mutateDisplay`/`discard`/`compare`/`repack`/`loadRepacked`) are consistent across Tasks 2–6. `MPNNModel.ScoreResult(logProbs:currentAALogProb:)` + `repack(_:sequence:)`/`score(_:sequence:mode:seed:)` match Phase 1/2a.
