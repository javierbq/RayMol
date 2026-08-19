# Design-Mode Multi-Residue Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a click in Design mode build a multi-residue selection exactly as a click in normal mode does, with the *count* of selected residues deciding the mode — one residue keeps today's single-residue behaviour, two or more auto-designate the redesign region.

**Architecture:** Invert the current data flow. Today `DesignController.setPinned` owns `pinnedResidueIndex` and pushes a one-residue `sele` outward purely as a pink marker. After this change PyMOL's `sele` is the single source of truth: clicks *toggle* `sele`, and a new `syncFromSele()` is the only writer of `pinnedResidueIndex` and `selectedResidueIndices`, deriving both from `sele ∩ scope(focusObject, editSourceObject)`. The modal "Tap to edit region" toggle and the macOS shift-click shortcut are deleted, since the count now carries that information.

**Tech Stack:** Swift 5 / SwiftUI (`@MainActor` `ObservableObject`), Python 3 (bundled `pymol` modules), PyMOL selection algebra, XCTest, `pymol.testing` (unittest), xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-19-design-mode-multi-residue-selection-design.md`

## Global Constraints

- **Platforms:** macOS *and* iOS. Design mode is gated on the `RAYMOL_MPNN` compilation condition, which `swiftui/project.yml` sets for `macosx*`, `iphoneos*`, and `iphonesimulator*`. Every Swift change must compile for both.
- **CI does not cover this code.** No workflow runs `PyMOLViewerTests`, and CI never compiles the iOS target. Swift tests and both-platform compiles are **manual** (Task 8). Do not treat a green CI as verification.
- **New Python test files are invisible to CI unless registered.** `.github/workflows/raymol-embedded-tests.yml` hand-lists test files. This plan therefore adds tests to `testing/tests/raymol/design_region.py`, which is already listed (line ~73). Do not create a new Python test file.
- **Python tests run through PyMOL, not pytest:** `pymol -ckqy testing/testing.py --run tests/raymol/design_region.py`. The repo's `.venv` PyMOL is broken (namespace-package conflict); use a Homebrew `pymol` with a shadow `PYTHONPATH` pointing at this worktree's `modules/`.
- **`poll_panel` runs on the main thread every 500 ms and is a measured hot spot** (PR #270 fixed a 713 ms tick). Anything added to it must be O(1) when Design mode is off.
- **`cmd.enable` is exclusive for selections.** Enabling `sele` disables other selections; `_preselect` must stay `enable=0`. Unchanged behaviour, but do not "fix" it.
- **Decisions carried from the spec, all binding:**
  - D1 — Design clicks always expand to **residue** scope, ignoring `mouse_selection_mode` (atom mode maps to zero guide residues → a click that selects nothing).
  - D2 — Exiting Design mode **no longer clears `sele`**.
  - D3 — 2+ residues auto-*designate*; MPNN runs only on the Redesign button.
  - D4 — A click on a non-focus object refocuses **and** selects that residue.
  - D5 — The lasso dropdown stays, but writes `sele` instead of snapshotting.
  - D6 — `regionEditMode` is **deleted** (property, UI on both platforms, tests).
  - D7 — Sidechain sticks stay tied to `{pinned} ∪ {hovered}`; not extended to the region.
  - D8 — The macOS shift-click region shortcut is **deleted**.

---

### Task 1: Python — read the active `sele`

Adds the read half of the new contract: map `sele` to guide-order residue indices for a focus object, plus a cheap digest for change detection that is gated on Design mode being active.

**Files:**
- Modify: `modules/pymol/raymol_design.py` (add after `selected_design_indices`, which ends ~line 148)
- Test: `testing/tests/raymol/design_region.py` (append to `TestDesignRegion`)

**Interfaces:**
- Consumes: existing `_tmp(name)`, `_scope(obj, src)`, `_obj_residue_order(obj)` in the same module.
- Produces:
  - `set_design_active(on) -> str` — arms/disarms the digest.
  - `sele_digest() -> str` — `''` when disarmed, else `"<count>:<md5-16>"`.
  - `sele_design_indices(obj, state, src='') -> str` — writes `$TMPDIR/raymol_design_sele.json` = `{'indices': [int], 'digest': str, 'n_total': int}`; returns `'DESIGN_SELE:<n>'`.

- [ ] **Step 1: Write the failing tests**

Append to `testing/tests/raymol/design_region.py` inside `class TestDesignRegion`:

```python
    def _sele_payload(self):
        with open(os.path.join(tempfile.gettempdir(),
                               'raymol_design_sele.json')) as f:
            return json.load(f)

    def testSeleIndicesMapInGuideOrder(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2+4' % obj)
        from pymol import raymol_design as rd
        marker = rd.sele_design_indices(obj, 1)
        self.assertTrue(marker.startswith('DESIGN_SELE:'))
        data = self._sele_payload()
        # resi 2 and 4 -> 0-based guide-order indices 1 and 3.
        self.assertEqual(data['indices'], [1, 3])
        self.assertEqual(data['n_total'], 2)

    def testSeleIndicesEmptyWithoutSele(self):
        obj = self._peptide()          # reinitialize() in _peptide drops any 'sele'
        from pymol import raymol_design as rd
        rd.sele_design_indices(obj, 1)
        data = self._sele_payload()
        self.assertEqual(data['indices'], [])
        self.assertEqual(data['n_total'], 0)

    def testSeleIndicesScopeToFocusObject(self):
        obj = self._peptide()
        cmd.fab('AAAAA', 'm2')
        cmd.select('sele', '(m1 and resi 2) or (m2 and resi 3)')
        from pymol import raymol_design as rd
        rd.sele_design_indices('m1', 1)
        data = self._sele_payload()
        # Only m1's residue is designable here; m2's still counts toward n_total.
        self.assertEqual(data['indices'], [1])
        self.assertEqual(data['n_total'], 2)

    def testSeleIndicesResolveOriginalOntoWorkingCopy(self):
        obj = self._peptide()
        cmd.create('%s_design' % obj, obj, zoom=0)
        cmd.select('sele', '%s and resi 2+4' % obj)   # selection on the ORIGINAL
        from pymol import raymol_design as rd
        # Focus = working copy, no src: the original's selection does not intersect.
        rd.sele_design_indices('%s_design' % obj, 1)
        self.assertEqual(self._sele_payload()['indices'], [])
        # With src = original it maps by (chain, resi) onto the copy's guide order.
        rd.sele_design_indices('%s_design' % obj, 1, src=obj)
        self.assertEqual(self._sele_payload()['indices'], [1, 3])

    def testSeleDigestIsGatedOnDesignActive(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2' % obj)
        from pymol import raymol_design as rd
        rd.set_design_active(0)
        self.assertEqual(rd.sele_digest(), '',
                         'digest must cost nothing while Design mode is off')
        rd.set_design_active(1)
        try:
            d1 = rd.sele_digest()
            self.assertTrue(d1)
            # Re-selecting the SAME residues must not change the digest.
            cmd.select('sele', '%s and resi 2' % obj)
            self.assertEqual(rd.sele_digest(), d1)
            # A different residue set must change it.
            cmd.select('sele', '%s and resi 2+3' % obj)
            self.assertNotEqual(rd.sele_digest(), d1)
        finally:
            rd.set_design_active(0)   # never leak the flag into another test
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
```

Expected: FAIL — `AttributeError: module 'pymol.raymol_design' has no attribute 'sele_design_indices'` (and the same for `sele_digest` / `set_design_active`).

- [ ] **Step 3: Add `hashlib` to the imports**

In `modules/pymol/raymol_design.py`, change the import block at the top from:

```python
import json
import os
import tempfile
```

to:

```python
import hashlib
import json
import os
import tempfile
```

- [ ] **Step 4: Implement the read half**

Insert into `modules/pymol/raymol_design.py` immediately after `selected_design_indices` (i.e. before `def apply_design_coloring`):

```python
# Design mode active? The selection digest below is O(selected residues) and is
# called from appkit_inspector.poll_panel, which runs on the MAIN thread every
# 500 ms and is a measured hot spot (PR #270). Gating on this flag keeps the cost
# at a single boolean check whenever Design mode is not on. A list rather than a
# bare module global so the setter never needs `global`.
_DESIGN_ACTIVE = [False]


def set_design_active(on):
    """Arm or disarm the Design-mode 'sele' digest computed by poll_panel."""
    _DESIGN_ACTIVE[0] = bool(on) if isinstance(on, bool) else bool(int(on))
    return 'DESIGN_ACTIVE:%d' % (1 if _DESIGN_ACTIVE[0] else 0)


def _sele_residue_keys():
    """Sorted (model, chain, resi) of every guide residue in the active 'sele'.

    '?sele' rather than 'sele' so a session that has never had a selection yields
    [] instead of raising. Guide atoms only, so the key set is one entry per
    residue regardless of how many of its atoms the user picked.
    """
    keys = []
    try:
        cmd.iterate('(?sele) and polymer and guide',
                    'keys.append((model, chain, resi))', space={'keys': keys})
    except Exception:
        return []
    return sorted(keys)


def _digest_of(keys):
    """Stable short fingerprint of a residue-key list."""
    return '%d:%s' % (len(keys),
                      hashlib.md5(repr(keys).encode('utf-8')).hexdigest()[:16])


def sele_digest():
    """Fingerprint of the active 'sele' residue set, or '' when Design is off.

    Used purely for change detection: the Swift side re-derives its selection
    state only when this value differs from the last one it saw.
    """
    if not _DESIGN_ACTIVE[0]:
        return ''
    return _digest_of(_sele_residue_keys())


def sele_design_indices(obj, state, src=''):
    """Map the active 'sele' -> full-length residue indices in obj's guide order.

    The Design-mode counterpart of selected_design_indices, hard-wired to 'sele'
    so the viewer's ordinary selection is the single source of truth for what
    Design mode is working on. Scoped through _scope(obj, src) so a selection made
    on the ORIGINAL object still maps onto a focused working copy by (chain, resi)
    identity once an edit session has begun.

    Output: $TMPDIR/raymol_design_sele.json =
        {'indices': [int], 'digest': str, 'n_total': int}
      indices  - 'sele' within the scope, as 0-based indices into obj's guide order
      digest   - fingerprint of the WHOLE 'sele' residue set (all objects)
      n_total  - residue count of 'sele' across ALL objects, so a caller can tell
                 "nothing selected" from "selected, but on another structure"

    `state` is accepted for signature symmetry with selected_design_indices and is
    likewise unused: guide order is read from the current state.
    Returns 'DESIGN_SELE:<n>'.
    """
    order = _obj_residue_order(obj)
    scope = _scope(obj, src)
    sel_res = set()
    try:
        cmd.iterate('%s and (?sele) and polymer and guide' % scope,
                    'sel_res.add((chain, resi))', space={'sel_res': sel_res})
    except Exception:
        pass
    indices = [i for i, cr in enumerate(order) if cr in sel_res]
    keys = _sele_residue_keys()
    payload = {'indices': indices,
               'digest': _digest_of(keys),
               'n_total': len(keys)}
    try:
        with open(_tmp('raymol_design_sele.json'), 'w') as f:
            json.dump(payload, f)
    except Exception:
        pass
    return 'DESIGN_SELE:%d' % len(indices)
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
```

Expected: PASS, all tests in `TestDesignRegion` (the five new ones plus the four pre-existing).

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_region.py
git commit -m "feat(design): read the active 'sele' as guide-order residue indices

Adds sele_design_indices (sele -> full-length indices, scoped to the focus
object and its edit source) plus a design-mode-gated digest for cheap change
detection, so 'sele' can become the single source of truth for what Design
mode is working on.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Python — mutate the active `sele`

The write half: the four `sele` mutations a Design-mode gesture can perform, using the same selection algebra as `metal_pick.pick_at` so the two modes cannot drift.

**Files:**
- Modify: `modules/pymol/raymol_design.py` (add after `sele_design_indices` from Task 1)
- Test: `testing/tests/raymol/design_region.py`

**Interfaces:**
- Consumes: `_residue_sel(obj, chain, resi)` from the same module.
- Produces:
  - `toggle_sele_residue(obj, chain, resi) -> str` (`'DESIGN_SELE_TOGGLE:on'|':off'`)
  - `set_sele_residue(obj, chain, resi) -> str` (`'DESIGN_SELE_SET:ok'`)
  - `set_sele_from_selection(name) -> str` (`'DESIGN_SELE_NAMED:ok'`)
  - `clear_sele() -> str` (`'DESIGN_SELE_CLEAR:ok'`)

- [ ] **Step 1: Write the failing tests**

Append to `testing/tests/raymol/design_region.py` inside `class TestDesignRegion`:

```python
    def _sele_resis(self):
        """Sorted resi strings of the guide residues currently in 'sele'."""
        out = set()
        cmd.iterate('(?sele) and polymer and guide',
                    'out.add(resi)', space={'out': out})
        return sorted(out, key=int)

    def testToggleSeleResidueAddsThenRemoves(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        self.assertEqual(rd.toggle_sele_residue(obj, '', '2'),
                         'DESIGN_SELE_TOGGLE:on')
        self.assertEqual(self._sele_resis(), ['2'])
        rd.toggle_sele_residue(obj, '', '4')
        self.assertEqual(self._sele_resis(), ['2', '4'])
        # Same residue again -> removed, matching a normal-mode click.
        self.assertEqual(rd.toggle_sele_residue(obj, '', '2'),
                         'DESIGN_SELE_TOGGLE:off')
        self.assertEqual(self._sele_resis(), ['4'])

    def testSetSeleResidueReplaces(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        rd.toggle_sele_residue(obj, '', '3')
        rd.set_sele_residue(obj, '', '5')
        self.assertEqual(self._sele_resis(), ['5'],
                         'set must replace the selection, not extend it')

    def testSetSeleFromSelectionCopiesNamedRegion(self):
        obj = self._peptide()
        cmd.select('loop', '%s and resi 2+3' % obj)
        from pymol import raymol_design as rd
        rd.set_sele_from_selection('loop')
        self.assertEqual(self._sele_resis(), ['2', '3'])

    def testSetSeleFromMissingSelectionEmpties(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        # A name that does not exist must empty 'sele', never raise.
        rd.set_sele_from_selection('nope')
        self.assertEqual(self._sele_resis(), [])

    def testToggleIsResidueScopedRegardlessOfMouseSelectionMode(self):
        # D1: Design clicks always expand to RESIDUE scope. With
        # mouse_selection_mode = 0 (atom) a normal-mode click would commit a single
        # ATOM, which maps to zero guide residues -- a click that silently selects
        # nothing. Design must ignore the setting entirely.
        obj = self._peptide()
        from pymol import raymol_design as rd
        for mode in (0, 1, 2, 4):
            cmd.set('mouse_selection_mode', mode)
            rd.clear_sele()
            rd.toggle_sele_residue(obj, '', '2')
            self.assertEqual(self._sele_resis(), ['2'],
                             'mouse_selection_mode %d must not change the scope '
                             'of a Design-mode click' % mode)
        cmd.set('mouse_selection_mode', 1)   # restore the default

    def testClearSeleEmpties(self):
        obj = self._peptide()
        from pymol import raymol_design as rd
        rd.toggle_sele_residue(obj, '', '2')
        self.assertEqual(rd.clear_sele(), 'DESIGN_SELE_CLEAR:ok')
        self.assertEqual(self._sele_resis(), [])
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
```

Expected: FAIL — `AttributeError: module 'pymol.raymol_design' has no attribute 'toggle_sele_residue'`.

- [ ] **Step 3: Implement the write half**

Insert into `modules/pymol/raymol_design.py` immediately after `sele_design_indices`:

```python
def toggle_sele_residue(obj, chain, resi):
    """Add or remove one residue in the active 'sele' (a Design-mode click).

    Deliberately mirrors metal_pick.pick_at's toggle idiom so that a click means
    the same thing in Design mode as in normal mode: already selected -> remove,
    otherwise add. Always leaves 'sele' enabled so the renderer's pink committed
    pass draws it. Returns 'DESIGN_SELE_TOGGLE:on' or ':off'.
    """
    expr = '(%s)' % _residue_sel(obj, chain, resi)
    try:
        already = cmd.count_atoms('(?sele) and %s' % expr) > 0
    except Exception:
        already = False
    if already:
        cmd.select('sele', '(?sele) and not %s' % expr, enable=1)
    else:
        cmd.select('sele', '(?sele) or %s' % expr, enable=1)
    return 'DESIGN_SELE_TOGGLE:%s' % ('off' if already else 'on')


def set_sele_residue(obj, chain, resi):
    """Replace the active 'sele' with exactly one residue.

    Used when a Design-mode click lands on a DIFFERENT object than the current
    focus: design retargets to that object and the selection starts fresh there,
    so residues of the previous focus never linger in the region.
    Returns 'DESIGN_SELE_SET:ok'.
    """
    cmd.select('sele', _residue_sel(obj, chain, resi), enable=1)
    return 'DESIGN_SELE_SET:ok'


def set_sele_from_selection(name):
    """Replace the active 'sele' with the contents of the named selection.

    Backs the lasso dropdown: designating a named region writes it into 'sele' so
    'sele' stays the single source of truth instead of the controller holding a
    second, divergent copy. '?name' so a stale name empties the selection rather
    than raising. Returns 'DESIGN_SELE_NAMED:ok'.
    """
    cmd.select('sele', '(?%s)' % name, enable=1)
    return 'DESIGN_SELE_NAMED:ok'


def clear_sele():
    """Empty the active 'sele' (a Design-mode click on empty space).

    Matches metal_pick.pick_at's empty-space behaviour. enable=0 because there is
    nothing to draw, and an enabled empty selection would still suppress other
    selections (cmd.enable is exclusive for selections).
    Returns 'DESIGN_SELE_CLEAR:ok'.
    """
    cmd.select('sele', 'none', enable=0)
    return 'DESIGN_SELE_CLEAR:ok'
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_region.py
git commit -m "feat(design): add the 'sele' mutations a Design-mode gesture performs

toggle/set/named/clear, using the same selection algebra as metal_pick.pick_at
so a click cannot come to mean different things in the two modes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Swift — derive the mode from `sele` (`syncFromSele`)

The heart of the change. Adds the read closure, an engine-free in-memory fallback so the state machine is unit-testable, and the single function that derives `pinnedResidueIndex` and `selectedResidueIndices`.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignRegionTests.swift`

**Interfaces:**
- Consumes: existing private `stickKey(_:_:)`, `lastSet`, `focusObject`, `editSourceObject`, `reconcileSticks()`, `DesignResidue.valid`.
- Produces, for Tasks 4/6/7:
  - `typealias SeleStateFn = (_ obj: String, _ src: String?, _ state: Int) -> (indices: [Int], digest: String, total: Int)`
  - `@discardableResult func syncFromSele() -> Int` — returns the designable-residue count it derived.
  - `@Published private(set) var seleResiduesOffFocus: Int`
  - `private var pickedSelectionName: String?`, `private var stubSele: Set<String>`
  - private helpers `seleToggleLocal(_:_:)`, `seleSetLocal(_:_:)`, `seleClearLocal()`, `seleStateLocal()`
  - `#if DEBUG func injectSele(seleState:toggleSele:setSeleResidue:setSeleNamed:clearSele:)`

- [ ] **Step 1: Write the failing tests**

Append to `swiftui/PyMOLViewerTests/DesignRegionTests.swift`, inside the existing test class (it already has a controller-construction pattern; mirror the one used by the neighbouring tests in the file):

```swift
    // MARK: – 'sele' as the single source of truth

    private func seleController() -> DesignController {
        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        return DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }

    // No selection -> nothing active. This is the idle state the greyed propensity
    // row renders.
    func testSyncFromSeleWithNothingSelected() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        XCTAssertEqual(c.syncFromSele(), 0)
        XCTAssertNil(c.pinnedResidueIndex)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertFalse(c.regionModeActive)
    }

    // Exactly one selected residue must reproduce today's single-residue
    // behaviour: pinned, and NOT region mode, so the propensity pills still show.
    func testOneSelectedResiduePinsAndStaysOutOfRegionMode() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [1], digest: "d1", total: 1) })
        XCTAssertEqual(c.syncFromSele(), 1)
        XCTAssertEqual(c.pinnedResidueIndex, 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "a single residue must not enter region mode")
        XCTAssertFalse(c.regionModeActive)
        XCTAssertNil(c.selectedSelectionName,
                     "the region label belongs to region mode only")
    }

    // Two or more selected residues auto-designate the region and drop the pin,
    // so the palette row replaces the propensity pills.
    func testTwoSelectedResiduesEnterRegionMode() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [0, 2], digest: "d2", total: 2) })
        XCTAssertEqual(c.syncFromSele(), 2)
        XCTAssertNil(c.pinnedResidueIndex,
                     "region mode must clear the single-residue pin")
        XCTAssertEqual(c.selectedResidueIndices, [0, 2])
        XCTAssertTrue(c.regionModeActive)
        XCTAssertEqual(c.selectedSelectionName, "sele",
                       "a click-built region is labelled 'sele'")
    }

    // Non-designable positions (missing backbone) never count, so selecting one
    // designable and one invalid residue is still single-residue mode.
    func testInvalidResiduesAreDroppedFromTheCount() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, false, true])
        c.injectSele(seleState: { _, _, _ in (indices: [0, 1], digest: "d3", total: 2) })
        XCTAssertEqual(c.syncFromSele(), 1,
                       "index 1 is not designable and must not count")
        XCTAssertEqual(c.pinnedResidueIndex, 0)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
    }

    // Out-of-range indices from a stale payload must not crash or leak in.
    func testOutOfRangeIndicesAreIgnored() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [1, 99, -1], digest: "d4", total: 3) })
        XCTAssertEqual(c.syncFromSele(), 1)
        XCTAssertEqual(c.pinnedResidueIndex, 1)
    }

    // Residues selected on OTHER structures are reported so the UI can say so
    // instead of silently ignoring them.
    func testOffFocusResiduesAreCounted() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [0], digest: "d5", total: 3) })
        c.syncFromSele()
        XCTAssertEqual(c.seleResiduesOffFocus, 2)
    }

    // With no focus object there is nothing to resolve against; sync must reset
    // rather than keep stale indices.
    func testSyncWithoutFocusResets() {
        let c = seleController()
        c.injectSele(seleState: { _, _, _ in (indices: [0, 1], digest: "d6", total: 2) })
        XCTAssertEqual(c.syncFromSele(), 0)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertNil(c.pinnedResidueIndex)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -30
```

Expected: FAIL to compile — `value of type 'DesignController' has no member 'injectSele'` / `'syncFromSele'` / `'seleResiduesOffFocus'`.

- [ ] **Step 3: Add the typealiases**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`, immediately after the `SelectedIndicesFn` typealias (~line 113):

```swift
    /// Read the active 'sele' for `obj`, scoped to `obj` + its edit `src` exactly as
    /// `SelectedIndicesFn` is. Returns the full-length guide indices inside that
    /// scope, a digest of the WHOLE selection (used only for change detection), and
    /// the total selected residue count across all objects.
    typealias SeleStateFn = (_ obj: String, _ src: String?, _ state: Int)
        -> (indices: [Int], digest: String, total: Int)
    /// Add or remove one residue in the active 'sele'.
    typealias ToggleSeleFn = (_ obj: String, _ chain: String, _ resi: String) -> Void
    /// Replace the active 'sele' with exactly one residue.
    typealias SetSeleResidueFn = (_ obj: String, _ chain: String, _ resi: String) -> Void
    /// Replace the active 'sele' with the contents of a named selection.
    typealias SetSeleNamedFn = (_ name: String) -> Void
    /// Empty the active 'sele'.
    typealias ClearSeleFn = () -> Void
```

- [ ] **Step 4: Add the stored properties**

In the same file, immediately after `private var selectedIndicesFn` (~line 144):

```swift
    // MARK: – 'sele' access (single source of truth)
    //
    // OPTIONAL rather than defaulted closures: a stored property's default value
    // cannot reference `self`, and the engine-free fallbacks below must read
    // `lastSet` / `focusObject`. nil therefore means "use the local fallback",
    // which is what unit tests get — and that matters, because
    // `pinnedResidueIndex` is now DERIVED: against no-op stubs every existing pin
    // assertion would read nil.
    private var seleStateFn: SeleStateFn?
    private var toggleSeleFn: ToggleSeleFn?
    private var setSeleResidueFn: SetSeleResidueFn?
    private var setSeleNamedFn: SetSeleNamedFn?
    private var clearSeleFn: ClearSeleFn?

    /// In-memory stand-in for PyMOL's 'sele' used by the fallbacks. Keys are
    /// "chain\u{1}resi" — the same encoding `stickKey` produces.
    private var stubSele: Set<String> = []

    /// Digest of the selection the last `syncFromSele()` resolved. The panel-poll
    /// hook compares against this so it only re-derives when 'sele' really changed.
    private(set) var lastSeleDigest: String = ""

    /// Name of the last selection explicitly designated through the lasso dropdown.
    /// Any click clears it, so a click-built region falls back to the "sele" label.
    private var pickedSelectionName: String?
```

And with the other `@Published` region properties (next to `selectedSelectionName`):

```swift
    /// Residues in 'sele' that are NOT on the focus object. Design ignores them,
    /// so the UI surfaces the count rather than silently dropping them.
    @Published private(set) var seleResiduesOffFocus: Int = 0
```

- [ ] **Step 5: Add the local fallbacks and `syncFromSele`**

Insert into `DesignController.swift` immediately before `func pickSelection(_ name: String)` (~line 728):

```swift
    // MARK: – Engine-free 'sele' fallbacks
    //
    // Used when no closure is injected, so unit tests drive the REAL derivation
    // instead of no-op stubs. Behaviourally identical to the Python helpers:
    // toggle adds/removes, set replaces, clear empties.

    private func seleToggleLocal(_ chain: String, _ resi: String) {
        let k = stickKey(chain, resi)
        if stubSele.contains(k) { stubSele.remove(k) } else { stubSele.insert(k) }
    }

    private func seleSetLocal(_ chain: String, _ resi: String) {
        stubSele = [stickKey(chain, resi)]
    }

    private func seleClearLocal() { stubSele.removeAll() }

    /// Local counterpart of `SeleStateFn`: resolve `stubSele` against the focus
    /// object's residue set, in guide order.
    private func seleStateLocal() -> (indices: [Int], digest: String, total: Int) {
        guard let obj = focusObject, let set = lastSet[obj] else {
            return (indices: [], digest: "\(stubSele.count)", total: stubSele.count)
        }
        let idx = set.residues.enumerated().compactMap { i, r in
            stubSele.contains(stickKey(r.chain, r.resi)) ? i : nil
        }
        return (indices: idx, digest: "\(stubSele.count):\(idx)", total: stubSele.count)
    }

    /// Read the current 'sele' state through the injected closure, or the local
    /// fallback when none is injected. Only reached with a focus object present
    /// (`syncFromSele` guards first), so the no-focus branch just defers to the
    /// fallback rather than inventing an empty result.
    private func readSeleState() -> (indices: [Int], digest: String, total: Int) {
        guard let obj = focusObject, let set = lastSet[obj] else { return seleStateLocal() }
        if let fn = seleStateFn { return fn(obj, editSourceObject, set.state) }
        return seleStateLocal()
    }

    // MARK: – Deriving the mode from 'sele'

    /// Re-derive the Design-mode selection state from the active 'sele'.
    ///
    /// This is the ONLY writer of `pinnedResidueIndex` and
    /// `selectedResidueIndices`. The count of DESIGNABLE residues in
    /// `sele ∩ scope(focusObject, editSourceObject)` picks the mode:
    ///   0  → nothing active (propensity row renders in its greyed idle form)
    ///   1  → that residue is pinned; the region stays empty so `regionModeActive`
    ///        is false and the propensity pills behave exactly as before
    ///   ≥2 → the region is designated on 'sele'; the pin is cleared so the
    ///        palette row and the Redesign button take over
    ///
    /// Returns the designable count, so callers and tests can assert the mode
    /// without re-reading three properties.
    @discardableResult
    func syncFromSele() -> Int {
        guard let obj = focusObject, let set = lastSet[obj] else {
            pinnedResidueIndex = nil
            selectedResidueIndices = []
            selectedSelectionName = nil
            seleResiduesOffFocus = 0
            return 0
        }
        let state = readSeleState()
        lastSeleDigest = state.digest
        let inScope = state.indices.filter { $0 >= 0 && $0 < set.residues.count }
        let valid = inScope.filter { set.residues[$0].valid }.sorted()
        seleResiduesOffFocus = max(0, state.total - inScope.count)
        if valid.count >= 2 {
            selectedResidueIndices = valid
            selectedSelectionName = pickedSelectionName ?? "sele"
            pinnedResidueIndex = nil
        } else {
            selectedResidueIndices = []
            selectedSelectionName = nil
            pinnedResidueIndex = valid.first
        }
        reconcileSticks()
        return valid.count
    }
```

- [ ] **Step 6: Add the DEBUG injection hook**

In the `#if DEBUG` block of `DesignController.swift`, next to `injectRegion` (~line 1272):

```swift
    /// Override the 'sele' closures for testing. Any argument left nil keeps the
    /// engine-free local fallback for that operation.
    func injectSele(seleState: SeleStateFn? = nil,
                    toggleSele: ToggleSeleFn? = nil,
                    setSeleResidue: SetSeleResidueFn? = nil,
                    setSeleNamed: SetSeleNamedFn? = nil,
                    clearSele: ClearSeleFn? = nil) {
        if let seleState { self.seleStateFn = seleState }
        if let toggleSele { self.toggleSeleFn = toggleSele }
        if let setSeleResidue { self.setSeleResidueFn = setSeleResidue }
        if let setSeleNamed { self.setSeleNamedFn = setSeleNamed }
        if let clearSele { self.clearSeleFn = clearSele }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -30
```

Expected: PASS — all seven new tests plus the pre-existing `DesignRegionTests`.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift \
        swiftui/PyMOLViewerTests/DesignRegionTests.swift
git commit -m "feat(design): derive pin and region from 'sele' via syncFromSele

syncFromSele becomes the only writer of pinnedResidueIndex and
selectedResidueIndices: 0 selected = idle, 1 = pinned (unchanged
single-residue behaviour), 2+ = region auto-designated.

The 'sele' closures are optional with engine-free in-memory fallbacks, so unit
tests exercise the real derivation -- necessary now that pinnedResidueIndex is
derived rather than assigned.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Swift — route every selection gesture through `sele`

Rewires taps, the viewport three-way rule, the lasso dropdown, and clear so they all mutate `sele` and then re-derive. Also removes the outward `sele` write (`pinnedIndicatorFn`) and stops Design-mode exit from wiping the user's selection (D2).

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignRegionTests.swift`

**Interfaces:**
- Consumes: `syncFromSele()`, `readSeleState()`, `seleToggleLocal/seleSetLocal/seleClearLocal`, `pickedSelectionName`, `stubSele` (Task 3); existing `focusAwait(_:)`, `residueIndex(chain:resi:)`, `selectedIndicesFn`.
- Produces: `tapResidue(residueIndex:)`, `toggleRegionResidue(residueIndex:)`, `setPinned(chain:resi:)`, `handleViewportHit(object:chain:resi:hasResidue:)`, `pickSelection(_:)`, `clearSelection()` — all now `sele`-backed. Removes `PinnedIndicatorFn`, `pinnedIndicatorFn`, and the `pinnedIndicator:` init parameter.

- [ ] **Step 1: Write the failing tests**

Append to `swiftui/PyMOLViewerTests/DesignRegionTests.swift` (reuses `seleController()` from Task 3):

```swift
    // MARK: – Gestures route through 'sele'

    // Successive taps accumulate, exactly like normal-mode clicks: 1 -> pin,
    // 2 -> region. This is the behaviour the whole change exists to deliver.
    func testSuccessiveTapsAccumulateIntoARegion() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])

        c.tapResidue(residueIndex: 1)
        XCTAssertEqual(c.pinnedResidueIndex, 1)
        XCTAssertFalse(c.regionModeActive)

        c.tapResidue(residueIndex: 0)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1], "region stays sorted")
        XCTAssertNil(c.pinnedResidueIndex)
        XCTAssertTrue(c.regionModeActive)

        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1, 2])
    }

    // Tapping a selected residue removes it, matching pick_at's toggle.
    func testTapOnSelectedResidueDeselects() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.tapResidue(residueIndex: 1)
        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(c.selectedResidueIndices, [1, 2])

        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(c.pinnedResidueIndex, 1, "back to single-residue mode")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)

        c.tapResidue(residueIndex: 1)
        XCTAssertNil(c.pinnedResidueIndex, "last residue removed -> nothing active")
    }

    // A click on empty space clears, as it does in normal mode. Focus is kept.
    func testEmptySpaceHitClearsSelectionButKeepsFocus() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.tapResidue(residueIndex: 0)
        c.tapResidue(residueIndex: 1)
        XCTAssertTrue(c.regionModeActive)

        c.handleViewportHit(object: "", chain: "", resi: "", hasResidue: false)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertNil(c.pinnedResidueIndex)
        XCTAssertEqual(c.focusObject, "m1", "clearing must not change focus")
    }

    // A hit on the focus object with no resolvable residue is a no-op, not a clear.
    func testHitOnFocusObjectWithoutResidueIsNoOp() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.tapResidue(residueIndex: 0)
        c.handleViewportHit(object: "m1", chain: "A", resi: "99", hasResidue: true)
        XCTAssertEqual(c.pinnedResidueIndex, 0,
                       "an unresolvable residue must not disturb the selection")
    }

    // The lasso dropdown writes 'sele' and keeps its own label.
    func testPickSelectionWritesSeleAndKeepsItsLabel() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _, _ in [0, 2] })
        c.pickSelection("loop")
        XCTAssertEqual(c.selectedResidueIndices, [0, 2])
        XCTAssertEqual(c.selectedSelectionName, "loop")

        // A subsequent click detaches from the named region.
        c.tapResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1, 2])
        XCTAssertEqual(c.selectedSelectionName, "sele")
    }

    // clearSelection empties 'sele' rather than only the mirrored array, so a
    // following sync cannot resurrect the region.
    func testClearSelectionEmptiesSele() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.tapResidue(residueIndex: 0)
        c.tapResidue(residueIndex: 1)
        c.clearSelection()
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertEqual(c.syncFromSele(), 0, "'sele' itself must be empty, not just the mirror")
    }

    // D3: reaching 2+ residues ARMS the Redesign button; it must never run MPNN
    // on its own. Auto-running would burn an inference per click and throw away
    // every intermediate result.
    func testBuildingARegionNeverRunsInference() {
        let c = seleController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
            designCalls += 1
            return Array(repeating: 0, count: r.count)
        })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, true, true])

        c.tapResidue(residueIndex: 0)
        c.tapResidue(residueIndex: 1)
        c.tapResidue(residueIndex: 2)

        XCTAssertTrue(c.regionModeActive, "3 residues must designate a region")
        XCTAssertEqual(designCalls, 0,
                       "designating a region must not run inference (D3)")
    }

    // D4: a hit on a NON-focus object retargets design AND selects that residue in
    // one gesture, so the first click on another structure is never dead. The
    // selection must be applied after the async focus completes, or it would be
    // resolved against the previous object's residue set.
    func testHitOnOtherObjectRefocusesAndSelects() async {
        let residues = (1...3).map { i in
            DesignResidue(chain: "A", resi: "\(i)", resn: "ALA", aa: 5,
                          backbone: MPNNModel.Residue(n: .zero, ca: .zero, c: .zero,
                                                      o: .zero, chain: 0, resSeq: i),
                          valid: true)
        }
        let c = DesignController(
            enumerate: { obj, _ in
                DesignResidueSet(object: obj, state: 1, residues: residues)
            },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
        c.allObjects = ["m1", "m2"]
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, true, true])
        c.tapResidue(residueIndex: 0)       // a residue selected on the OLD focus

        // Drive the async refocus path directly so the test can await it.
        c.handleViewportHit(object: "m2", chain: "A", resi: "2", hasResidue: true)
        // handleViewportHit spawns a Task for the refocus; yield until it settles.
        for _ in 0..<10 where c.focusObject != "m2" { await Task.yield() }

        XCTAssertEqual(c.focusObject, "m2", "the click must retarget design")
        XCTAssertEqual(c.pinnedResidueIndex, 1,
                       "the clicked residue must be selected by the same click (D4)")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "old-focus residues must not linger in the region")
    }

    // D2: leaving Design mode must NOT wipe the user's ordinary selection.
    func testExitDoesNotClearSele() {
        let c = seleController()
        var cleared = false
        c.injectSele(clearSele: { cleared = true })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.tapResidue(residueIndex: 0)
        c.exit()
        XCTAssertFalse(cleared,
                       "exiting Design mode must leave 'sele' alone (D2)")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -30
```

Expected: FAIL — `testSuccessiveTapsAccumulateIntoARegion` fails because `tapResidue` still calls `setPinned`, which replaces rather than accumulates; `testExitDoesNotClearSele` fails because `exit()` still calls `pinnedIndicatorFn("", "", "")`.

- [ ] **Step 3: Rewrite `tapResidue`, `toggleRegionResidue`, and `setPinned`**

In `DesignController.swift`, replace the whole existing `toggleRegionResidue`, `tapResidue`, and `setPinned` implementations with:

```swift
    /// Toggle one residue (full-length index) in the active 'sele'.
    ///
    /// The single gesture entry point: the viewport, the sequence strip, and the
    /// compact panel all land here, so a click means the same thing everywhere and
    /// the same thing it means in normal mode. The resulting mode (pin vs region)
    /// is DERIVED by `syncFromSele`, never decided here.
    func tapResidue(residueIndex i: Int) {
        guard let obj = focusObject, let set = lastSet[obj],
              i >= 0, i < set.residues.count else { return }
        let r = set.residues[i]
        pickedSelectionName = nil        // a click detaches from any named region
        if let fn = toggleSeleFn { fn(obj, r.chain, r.resi) }
        else { seleToggleLocal(r.chain, r.resi) }
        syncFromSele()
    }

    /// Historical name for `tapResidue`, kept because call sites and tests read
    /// naturally with it. Both go through 'sele', so they are now the same action.
    func toggleRegionResidue(residueIndex i: Int) {
        tapResidue(residueIndex: i)
    }

    /// Toggle one residue addressed by (chain, resi). Retained because the sequence
    /// strip and several tests address residues that way. The pin itself is derived
    /// by `syncFromSele` — this method never writes `pinnedResidueIndex`.
    func setPinned(chain: String, resi: String) {
        guard let idx = residueIndex(chain: chain, resi: resi) else { return }
        tapResidue(residueIndex: idx)
    }
```

- [ ] **Step 4: Rewrite `handleViewportHit` and add `focusThenSelect`**

Replace the existing `handleViewportHit` body with:

```swift
    /// Unified viewport-hit routing shared between iOS (`designPickResidue`) and
    /// macOS (`onChange(of: engine.longPressHit)`).
    ///
    /// Four-way rule, matching normal-mode click semantics:
    ///   - `object` empty (a miss) → clear 'sele'; focus is untouched
    ///   - `object != focusObject` → refocus there AND select that residue (D4),
    ///     so the first click on another structure is never dead
    ///   - `object == focusObject && hasResidue` → toggle that residue in 'sele'
    ///   - `object == focusObject && !hasResidue` → no-op (a non-residue patch)
    func handleViewportHit(object: String, chain: String, resi: String, hasResidue: Bool) {
        guard !object.isEmpty else {
            // Empty-space click clears, exactly as metal_pick.pick_at does.
            pickedSelectionName = nil
            if let fn = clearSeleFn { fn() } else { seleClearLocal() }
            syncFromSele()
            return
        }
        if object != focusObject {
            focusThenSelect(object: object, chain: chain, resi: resi, hasResidue: hasResidue)
        } else if hasResidue, let idx = residueIndex(chain: chain, resi: resi) {
            tapResidue(residueIndex: idx)
        }
        // object == focusObject && !hasResidue → no-op
    }

    /// Retarget design to `object`, then seed 'sele' with the clicked residue.
    ///
    /// The two steps cannot be reordered or collapsed: `focusAwait` is async (it
    /// enumerates residues and may score), and until it completes `lastSet[object]`
    /// does not exist — so a `syncFromSele()` run before it would resolve the new
    /// selection against the OLD object's residue set and silently produce garbage
    /// indices.
    private func focusThenSelect(object: String, chain: String, resi: String,
                                 hasResidue: Bool) {
        Task {
            await focusAwait(object)
            pickedSelectionName = nil
            if hasResidue {
                if let fn = setSeleResidueFn { fn(object, chain, resi) }
                else { seleSetLocal(chain, resi) }
            } else {
                if let fn = clearSeleFn { fn() } else { seleClearLocal() }
            }
            syncFromSele()
        }
    }
```

- [ ] **Step 5: Rewrite `pickSelection` and `clearSelection`**

Replace both existing implementations with:

```swift
    /// Designate `name` as the region by writing it into 'sele' (D5), so 'sele'
    /// stays the single source of truth rather than the controller holding a
    /// second, divergent copy. The resulting indices come back through
    /// `syncFromSele` like every other selection change.
    func pickSelection(_ name: String) {
        guard let obj = focusObject, let set = lastSet[obj] else { return }
        pickedSelectionName = name
        if let fn = setSeleNamedFn {
            fn(name)
        } else {
            // Engine-free fallback: resolve the name through the injected index
            // mapper so unit tests can designate a named region with no live PyMOL.
            let full = selectedIndicesFn(obj, name, editSourceObject, set.state)
            stubSele = Set(full.compactMap { i in
                (i >= 0 && i < set.residues.count)
                    ? stickKey(set.residues[i].chain, set.residues[i].resi) : nil
            })
        }
        syncFromSele()
    }

    /// Clear the region by emptying 'sele' → back to nothing selected.
    func clearSelection() {
        pickedSelectionName = nil
        if let fn = clearSeleFn { fn() } else { seleClearLocal() }
        syncFromSele()
    }
```

Note: `pickSelection` sets `pickedSelectionName` *before* `syncFromSele()` so the label survives; at `valid.count >= 2` the sync uses it, and a later `tapResidue` clears it.

- [ ] **Step 6: Sync after a focus change**

In `focusAwait(_:)`, immediately after the existing `syncFocusResidues()` call that follows `lastSet[object] = set`, add:

```swift
            syncFromSele()        // derive pin/region for the NEW focus's scope
```

- [ ] **Step 7: Remove the outward `sele` write (`pinnedIndicatorFn`)**

The pink marker *is* `sele` now, so nothing should push a selection outward. Delete all of:

- the `PinnedIndicatorFn` typealias (~line 83) and its doc comment,
- `private var pinnedIndicatorFn: PinnedIndicatorFn = { _, _, _ in }` (~line 141),
- the `pinnedIndicator: @escaping PinnedIndicatorFn = { _, _, _ in },` init parameter (~line 306) and its `self.pinnedIndicatorFn = pinnedIndicator` assignment,
- every call site: `pinnedIndicatorFn("", "", "")` in `exit()` (this is D2 — exiting no longer clears `sele`), in `focusAwait`'s focus-change block, and in `teardownEditSession`.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -30
```

Expected: PASS. The build will still fail elsewhere if `PyMOLEngine.swift` passes `pinnedIndicator:` — remove that argument now (its full replacement wiring lands in Task 6):

```swift
// In PyMOLEngine.swift, delete the whole `pinnedIndicator: { ... },` closure
// argument from the DesignController(...) construction.
```

- [ ] **Step 9: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift \
        swiftui/PyMOLViewer/Shared/PyMOLEngine.swift \
        swiftui/PyMOLViewerTests/DesignRegionTests.swift
git commit -m "feat(design): route every selection gesture through 'sele'

Taps, the viewport three-way rule, the lasso dropdown and clear all mutate
'sele' and then re-derive, so successive clicks accumulate a region the way
normal-mode clicks do. A click on another structure now refocuses AND selects
that residue (D4), and an empty-space click clears.

Drops the outward one-residue 'sele' write: the pink marker IS 'sele'. Leaving
Design mode therefore no longer wipes the user's selection (D2).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Delete `regionEditMode` and the macOS shift-click

The count now carries what the modal toggle used to (D6), and a plain tap has made shift-click an exact duplicate with a documented double-fire hazard (D8).

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignController.swift` (~lines 230, 388–392, 750–762, 788)
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (~lines 843, 3730–3746, 3789, 3844–3867)
- Modify: `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift` (~lines 174–183, 220–237)
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` (~lines 445–500, 549–590)

**Interfaces:**
- Consumes: `tapResidue(residueIndex:)`, `syncFromSele()` (Tasks 3–4).
- Produces: no new API. Removes `DesignController.regionEditMode`, `ContentView.regionEditToggle`, and `DesignCompactPanel.regionEditButton`.

- [ ] **Step 1: Rewrite the tests that encode the old rule**

In `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift`, replace `testTapPinsWhenRegionEditModeIsOff`, `testTapTogglesRegionWhenRegionEditModeIsOn`, and `testTapIgnoresInvalidResiduesInRegionEditMode` with the count-driven equivalents (keep every other test in the file untouched):

```swift
    // One tap pins for inspection; the region stays empty so the propensity pills
    // still show. This is the single-residue behaviour the change preserves.
    func testSingleTapPinsAndDoesNotBuildARegion() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.tapResidue(residueIndex: 1)

        XCTAssertEqual(c.pinnedResidueIndex, 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "one residue must not enter region mode")
    }

    // A second tap on a different residue turns the selection into a region and
    // drops the pin — no mode toggle involved.
    func testSecondTapBuildsRegionAndDropsThePin() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.tapResidue(residueIndex: 1)
        c.tapResidue(residueIndex: 0)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1], "region stays sorted")
        XCTAssertNil(c.pinnedResidueIndex)

        // Tapping a member removes it, dropping back to single-residue mode.
        c.tapResidue(residueIndex: 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertEqual(c.pinnedResidueIndex, 0)
    }

    // Non-designable positions can never be pinned or enter a region, however
    // many times they are tapped.
    func testTapIgnoresNonDesignableResidues() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, false, true])

        c.tapResidue(residueIndex: 1)
        XCTAssertNil(c.pinnedResidueIndex,
                     "a residue with no backbone is not designable")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)

        // A designable residue alongside it still works normally.
        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(c.pinnedResidueIndex, 2)
    }
```

Then find the `handleViewportHit` region-edit test near line 564 (`testHandleViewportHit…RegionEditMode…`) and replace it with:

```swift
    // Two viewport hits on the focus object accumulate into a region, so the
    // viewport and the sequence strip agree without any mode switch.
    func testHandleViewportHitAccumulatesRegionOnFocusObject() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.handleViewportHit(object: "m1", chain: "A", resi: "2", hasResidue: true)
        XCTAssertEqual(c.pinnedResidueIndex, 1)

        c.handleViewportHit(object: "m1", chain: "A", resi: "3", hasResidue: true)
        XCTAssertEqual(c.selectedResidueIndices, [1, 2])
        XCTAssertNil(c.pinnedResidueIndex)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignIOSPortTests 2>&1 | tail -30
```

Expected: PASS. Unusually for a TDD step these tests pass immediately — Task 4 already made the count-driven rule true — so the point of running them now is to prove the rewrite captures real behaviour rather than accommodating the deletion that follows. The file still references `c.regionEditMode` at the other lines listed above; those references are what stops compiling in Step 3, and they get deleted there.

- [ ] **Step 3: Delete `regionEditMode` from the controller**

In `swiftui/PyMOLViewer/Shared/DesignController.swift`:

- Delete the property and its doc comment (~line 226–230):

```swift
    /// True while the user is building an ad-hoc region by tapping positions.
    /// Replaces shift-click, which does not exist on touch (and whose SwiftUI
    /// modifier is unavailable on iOS). Ships on macOS too — the explicit toggle
    /// is the discoverable path; shift-click remains as a power-user shortcut.
    @Published var regionEditMode = false
```

- Delete the `regionEditMode = false` line from `clearRegionState()` (~line 788).
- Update the `handleViewportHit` doc comment written in Task 4 if it still mentions region-edit mode (it should not).

- [ ] **Step 4: Delete the macOS toggle and the shift-click gesture**

In `swiftui/PyMOLViewer/Shared/ContentView.swift`:

- In `controls` (~line 3786), delete the `stripDivider` + `regionEditToggle` pair so it reads:

```swift
    private var controls: some View {
        HStack(spacing: 8) {
            selectionButton
            if controller.regionModeActive {
                stripDivider
```

- Delete the entire `private var regionEditToggle: some View { … }` property (~lines 3842–3867) including its leading comment block.
- In the sequence-strip column (~lines 3730–3746), delete the comment block and the whole `#if os(macOS) .highPriorityGesture(…) #endif` shift gesture, leaving:

```swift
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                controller.setHovered(chain: residue.chain, resi: residue.resi)
            } else {
                controller.clearHover()
            }
        }
        // A plain tap toggles this position in 'sele' — the same gesture, and the
        // same meaning, as a click in the viewport or in normal mode.
        .onTapGesture {
            controller.tapResidue(residueIndex: i)
        }
```

- In the Design-mode click-routing comment (~line 843), drop the sentence about region-edit mode being honoured on macOS; it no longer exists.

- [ ] **Step 5: Delete the iOS toggle**

In `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift`:

- In `actionRow` (~line 180), delete the `regionEditButton` line so it reads:

```swift
        HStack(spacing: 8) {
            regionButton
            if controller.regionModeActive { redesignButton }
```

- Update the row's leading comment (~line 174) from `region picker · edit-mode toggle · redesign …` to `region picker · redesign …`.
- Delete the entire `private var regionEditButton: some View { … }` property (~lines 220–237).

- [ ] **Step 6: Verify no reference survives**

```bash
grep -rn "regionEditMode\|regionEditButton\|regionEditToggle\|Tap to edit" \
  swiftui/PyMOLViewer swiftui/PyMOLViewerTests
```

Expected: no output. (Matches under `swiftui/build_ios_restricted/` or in `docs/superpowers/plans/` are historical and must be left alone — this grep deliberately does not search them.)

- [ ] **Step 7: Run the full design test suite**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests 2>&1 | tail -40
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift \
        swiftui/PyMOLViewer/Shared/ContentView.swift \
        swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift \
        swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "refactor(design): delete the region-edit toggle and shift-click

The count of 'sele' now decides single-vs-region, so the modal toggle has no
job left on either platform. Shift-click goes with it: once a plain tap toggles
region membership the gesture is an exact duplicate carrying the double-fire
no-op hazard its own comment documented, and removing it deletes the sequence
strip's last #if os(macOS) branch.

Rewrites the four tests that asserted the toggle's behaviour to assert the
count-driven rule instead.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Wire the engine to real PyMOL closures

Connects the controller's `sele` closures to the Python helpers, makes an iOS empty-space tap reach the controller, and arms the poll digest while Design mode is on.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` (`DesignController(...)` construction ~line 2100+, `designPickResidue` ~line 2854, `setDesignMode` ~line 2173)
- Test: `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift`

**Interfaces:**
- Consumes: `sele_design_indices`, `toggle_sele_residue`, `set_sele_residue`, `set_sele_from_selection`, `clear_sele`, `set_design_active` (Tasks 1–2); `injectSele` and `handleViewportHit` (Tasks 3–4).
- Produces: a fully wired `DesignController`; `designPickResidue` now forwards misses.

- [ ] **Step 1: Write the failing test**

Append to `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift`:

```swift
    // An iOS tap that MISSES must reach the controller as an empty hit so it
    // clears the selection. The old designPickResidue returned early on a miss,
    // making empty-space taps silently inert.
    func testEmptyHitClearsThroughTheSameRouting() {
        let c = makeController()
        var clearCalls = 0
        c.injectSele(clearSele: { clearCalls += 1 })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)

        c.handleViewportHit(object: "", chain: "", resi: "", hasResidue: false)

        XCTAssertEqual(clearCalls, 1,
                       "a miss must clear 'sele' through the injected closure")
        XCTAssertEqual(c.focusObject, "m1", "a miss must not change focus")
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignIOSPortTests/testEmptyHitClearsThroughTheSameRouting 2>&1 | tail -20
```

Expected: PASS if Task 4 landed correctly (`clearSeleFn` is called). If it FAILS with `clearCalls == 0`, Task 4's empty-space branch is wrong — fix that before continuing.

- [ ] **Step 3: Wire the five closures**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, add these arguments to the `DesignController(...)` construction, next to the existing `selectedIndices:` closure:

```swift
        seleState: { [weak self] obj, src, state in
            guard let self else { return (indices: [], digest: "", total: 0) }
            let srcArg = (src?.isEmpty == false) ? src! : ""
            self.runPython("""
                from pymol import raymol_design as _rd
                _rd.sele_design_indices('\(obj)', \(state), src='\(srcArg)')
                """)
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("raymol_design_sele.json")
            guard let data = FileManager.default.contents(atPath: path.path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return (indices: [], digest: "", total: 0) }
            return (indices: (root["indices"] as? [Int]) ?? [],
                    digest: (root["digest"] as? String) ?? "",
                    total: (root["n_total"] as? Int) ?? 0)
        },
        toggleSele: { [weak self] obj, chain, resi in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.toggle_sele_residue('\(obj)', '\(chain)', '\(resi)')
                """)
        },
        setSeleResidue: { [weak self] obj, chain, resi in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.set_sele_residue('\(obj)', '\(chain)', '\(resi)')
                """)
        },
        setSeleNamed: { [weak self] name in
            self?.runPython("""
                from pymol import raymol_design as _rd
                _rd.set_sele_from_selection('\(name)')
                """)
        },
        clearSele: { [weak self] in
            self?.runPython("from pymol import raymol_design as _rd; _rd.clear_sele()")
        },
```

Then add the matching non-optional init parameters to `DesignController.init` (in `DesignController.swift`), each defaulting to `nil` so existing constructions — including every test helper — keep compiling:

```swift
                     seleState: SeleStateFn? = nil,
                     toggleSele: ToggleSeleFn? = nil,
                     setSeleResidue: SetSeleResidueFn? = nil,
                     setSeleNamed: SetSeleNamedFn? = nil,
                     clearSele: ClearSeleFn? = nil,
```

and in the init body:

```swift
        self.seleStateFn = seleState
        self.toggleSeleFn = toggleSele
        self.setSeleResidueFn = setSeleResidue
        self.setSeleNamedFn = setSeleNamed
        self.clearSeleFn = clearSele
```

- [ ] **Step 4: Forward iOS misses**

Replace the body of `designPickResidue` in `PyMOLEngine.swift` with:

```swift
    func designPickResidue(ndcX: Float, ndcY: Float, aspect: Float) {
        guard designMode, isReady else { return }
        runPython("from pymol import metal_pick as _mp; _mp.hover_design_at(\(ndcX), \(ndcY), \(aspect))")
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_hover_design.json")
        var obj = "", chain = "", resi = ""
        var hit = false
        if let data = FileManager.default.contents(atPath: path),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hit   = (root["hit"] as? Bool) ?? false
            obj   = root["obj"]   as? String ?? ""
            chain = root["chain"] as? String ?? ""
            resi  = root["resi"]  as? String ?? ""
        }
        // A MISS must still reach the controller: an empty-space tap clears the
        // selection (normal-mode parity). The previous early return on `hit ==
        // false` made empty taps silently inert. An empty `object` is exactly what
        // the macOS path already delivers on a miss (longPressPick builds
        // LongPressHit with obj: "" and isEmpty: true), so both platforms converge.
        MainActor.assumeIsolated {
            designController.handleViewportHit(object: hit ? obj : "",
                                               chain: chain, resi: resi,
                                               hasResidue: hit)
        }
    }
```

- [ ] **Step 5: Arm the digest while Design mode is on**

In `setDesignMode(_:)` in `PyMOLEngine.swift`, replace the final `designMode = on` with:

```swift
        designMode = on
        // Arm/disarm the Design-mode 'sele' digest that poll_panel computes. Off ⇒
        // that 500 ms main-thread poll pays one boolean check (see raymol_design
        // .sele_digest), which is why this must be toggled rather than always on.
        runPython("from pymol import raymol_design as _rd; _rd.set_design_active(\(on ? 1 : 0))")
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests 2>&1 | tail -40
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift \
        swiftui/PyMOLViewer/Shared/DesignController.swift \
        swiftui/PyMOLViewerTests/DesignIOSPortTests.swift
git commit -m "feat(design): wire the 'sele' closures to the engine

Connects read/toggle/set/named/clear to raymol_design, arms the poll digest
only while Design mode is on, and forwards iOS viewport MISSES to
handleViewportHit so an empty-space tap clears the selection the way it does in
normal mode (it was silently inert).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Notice `sele` changes made outside Design mode

A `select` typed at the prompt, a Seeker drag, or an object-panel action must also drive Design mode. Piggybacks the existing 500 ms panel poll rather than adding a timer.

**Files:**
- Modify: `modules/pymol/appkit_inspector.py` (`poll_panel`, after the `payload = {…}` literal ~line 631)
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (`PanelPayload` ~line 4072, `parseObjectPanelFeedback` ~line 4140)
- Test: `testing/tests/raymol/design_region.py`, `swiftui/PyMOLViewerTests/DesignRegionTests.swift`

**Interfaces:**
- Consumes: `raymol_design.sele_digest()` (Task 1), `DesignController.syncFromSele()` / `lastSeleDigest` (Task 3).
- Produces: `PanelPayload.design_sele: String?`; a digest-gated `syncFromSele()` call on each poll tick.

- [ ] **Step 1: Write the failing tests**

Append to `testing/tests/raymol/design_region.py`:

```python
    def testPollPanelCarriesDesignSeleDigest(self):
        obj = self._peptide()
        cmd.select('sele', '%s and resi 2' % obj)
        from pymol import appkit_inspector as ai
        from pymol import raymol_design as rd
        rd.set_design_active(1)
        try:
            ai.poll_panel()
            path = os.path.join(tempfile.gettempdir(),
                                'pymol_objpanel_%d.json' % os.getpid())
            with open(path) as f:
                payload = json.load(f)
            self.assertTrue(payload.get('design_sele'),
                            "poll_panel must carry the digest while Design is active")
            # And it must cost nothing once Design mode is off.
            rd.set_design_active(0)
            ai.poll_panel()
            with open(path) as f:
                payload = json.load(f)
            self.assertEqual(payload.get('design_sele'), '')
        finally:
            rd.set_design_active(0)
```

Append to `swiftui/PyMOLViewerTests/DesignRegionTests.swift`:

```swift
    // The poll must re-derive only when the digest actually changed, so a quiet
    // 500 ms tick costs nothing.
    func testSyncFromSeleRecordsTheDigestItResolved() {
        let c = seleController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [0], digest: "abc123", total: 1) })
        c.syncFromSele()
        XCTAssertEqual(c.lastSeleDigest, "abc123",
                       "the resolved digest must be recorded for poll gating")
    }

    // The panel payload's new field must be optional so an older bundled
    // appkit_inspector.py still decodes (the whole panel would freeze otherwise).
    func testPanelPayloadDecodesWithoutDesignSele() throws {
        let json = """
        {"objects":[],"selections":[],"enabled":[],"sel_counts":{}}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PanelPayload.self, from: json)
        XCTAssertNil(payload.design_sele)
    }
```

- [ ] **Step 2: Run both suites to verify they fail**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests/DesignRegionTests 2>&1 | tail -25
```

Expected: Python FAILs (`design_sele` missing → `assertTrue(None)`); Swift FAILs to compile (`PanelPayload` has no member `design_sele`).

- [ ] **Step 3: Add the digest to the poll payload**

In `modules/pymol/appkit_inspector.py`, immediately after the `payload = { … }` literal closes and **before** `blob = json.dumps(payload)`:

```python
        # Design-mode selection fingerprint. Computed inside raymol_design and
        # GATED there on Design mode being active, so this main-thread 500 ms poll
        # pays a single boolean check whenever Design mode is off (PR #270 made
        # this tick's cost a standing constraint). Its own try: a failure here must
        # not cost the panel its update.
        try:
            from pymol import raymol_design as _rd
            payload['design_sele'] = _rd.sele_digest()
        except Exception:
            payload['design_sele'] = ''
```

- [ ] **Step 4: Add the optional payload field**

In `swiftui/PyMOLViewer/Panels/ObjectPanel.swift`, inside `struct PanelPayload: Decodable`, after `msa_searches`:

```swift
    /// Design-mode 'sele' fingerprint, '' while Design mode is off. Optional for
    /// the same reason as every field above: a non-optional would fail the whole
    /// decode against an older bundled appkit_inspector.py and freeze the panel on
    /// its last list.
    let design_sele: String?
```

- [ ] **Step 5: Re-derive when the digest changes**

In `parseObjectPanelFeedback` in the same file, immediately after the `guard let payload = try? JSONDecoder().decode(...)` block:

```swift
        #if RAYMOL_MPNN
        // 'sele' is the single source of truth for Design mode, so a selection made
        // OUTSIDE it — `select` at the prompt, a Seeker drag, the object panel —
        // must drive it too. Gated on the digest so a quiet tick does no work, and
        // on designMode so nothing runs when the feature is not in use.
        if let digest = payload.design_sele, !digest.isEmpty, designMode {
            MainActor.assumeIsolated {
                if digest != designController.lastSeleDigest {
                    designController.syncFromSele()
                }
            }
        }
        #endif
```

- [ ] **Step 6: Run both suites to verify they pass**

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests 2>&1 | tail -40
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/appkit_inspector.py \
        swiftui/PyMOLViewer/Panels/ObjectPanel.swift \
        testing/tests/raymol/design_region.py \
        swiftui/PyMOLViewerTests/DesignRegionTests.swift
git commit -m "feat(design): pick up 'sele' changes made outside Design mode

Piggybacks the existing 500 ms panel poll with a design-mode-gated digest, so a
'select' typed at the prompt or a Seeker drag becomes the design region without
adding a second timer. The re-derive is skipped whenever the digest is
unchanged, and the payload field is optional so an older bundled Python still
decodes.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Surface off-focus residues, then verify on both platforms

A small honesty fix — residues selected on other structures are silently ignored by design, so say so — followed by the manual verification this repo's CI cannot do.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (`controls`, ~line 3786)
- Modify: `swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift` (`actionRow`, ~line 178)

**Interfaces:**
- Consumes: `DesignController.seleResiduesOffFocus` (Task 3).
- Produces: no new API.

- [ ] **Step 1: Add the hint to the macOS region strip**

In `ContentView.swift`, inside `DesignRegionStripView.controls`, immediately after `selectionButton`:

```swift
            if controller.seleResiduesOffFocus > 0 {
                Text("+\(controller.seleResiduesOffFocus) off-structure")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
                    .help("Selected residues on other structures. Design only ever "
                          + "works on the focused structure, so these are ignored.")
            }
```

- [ ] **Step 2: Add the same hint to the iOS panel**

In `DesignCompactPanel.swift`, inside `actionRow`, immediately after `regionButton`:

```swift
            if controller.seleResiduesOffFocus > 0 {
                Text("+\(controller.seleResiduesOffFocus)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
                    .accessibilityLabel(
                        "\(controller.seleResiduesOffFocus) selected residues on other structures, ignored")
            }
```

- [ ] **Step 3: Compile the macOS target the two-stage way**

The core must be built BEFORE `xcodebuild`, or `xcodebuild` silently links a stale `libpymol_core.a` and you test old code:

```bash
pip install --verbose --no-build-isolation --config-settings testing=True .
cd swiftui && xcodegen generate && \
  xcodebuild -scheme RayMol -destination 'platform=macOS' \
  -skipPackagePluginValidation build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Compile the iOS target by hand**

CI never compiles iOS, and `ContentView.swift` has leaked platform-only symbols in both directions before (#174, #226, #238). This step is the only thing that catches it:

```bash
cd swiftui && xcodebuild -scheme PyMOLViewer_iOS \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If it fails on a symbol the macOS build accepted, that symbol is macOS-only and needs a `#if os(macOS)` guard or a cross-platform replacement.

- [ ] **Step 5: Run the whole Swift and Python design suites**

```bash
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' \
  -only-testing:PyMOLViewerTests 2>&1 | tail -40
```

```bash
pymol -ckqy testing/testing.py --run tests/raymol/design_region.py
pymol -ckqy testing/testing.py --run tests/raymol/design_editing.py
pymol -ckqy testing/testing.py --run tests/raymol/design_enumerate.py
pymol -ckqy testing/testing.py --run tests/raymol/design_color.py
pymol -ckqy testing/testing.py --run tests/raymol/design_saverestore.py
```

Expected: all PASS. Report actual output; do not claim success without it.

- [ ] **Step 6: Functional check in a disposable macOS VM**

Use the `mac-vm-test` (or `raymol-mac-vm`) skill — never the host UI. Load a structure, enter Design mode, and confirm each row of the behaviour table:

1. Click one residue → propensity pills become live, residue badge shows the label, the pink marker appears.
2. Click a second residue → palette row replaces the pills, "Redesign selection · 2 res" appears, both residues pink.
3. Click one of the two again → back to single-residue mode with pills.
4. Click empty space → selection clears, pills grey out, focus unchanged.
5. With two structures loaded, click a residue on the non-focus one → design retargets to it AND that residue is selected in one click.
6. Type `select sele, resi 10-14` at the prompt → within ~500 ms the region shows 5 residues without any click.
7. Press Redesign → it runs once; it must NOT have fired on any of the clicks above.
8. Exit Design mode → `sele` survives (D2); the pink markers remain.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift \
        swiftui/PyMOLViewer/Shared/DesignCompactPanel.swift
git commit -m "feat(design): show how many selected residues design is ignoring

Residues selected on non-focus structures are scoped out of the region, which
was silent. Both panels now report the count.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **`focusAwait` is async.** Any code that sets a selection right after changing focus must await the focus first, or `syncFromSele()` resolves indices against the previous object's residue set. `focusThenSelect` in Task 4 exists solely for this.
- **`stickKey` is the shared residue-key encoding** (`"chain\u{1}resi"`). The in-memory `sele` fallback reuses it deliberately; do not introduce a second encoding.
- **Do not add `cmd.enable('sele')` anywhere new.** The Python helpers already pass `enable=1`, and `cmd.enable` is exclusive for selections — an extra call risks disabling `_preselect`-adjacent state.
- **`pinnedResidueIndex` is derived.** If a new feature needs to pin something, it must go through `sele`, not assign the property.
