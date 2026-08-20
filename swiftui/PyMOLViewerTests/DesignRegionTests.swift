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
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }
    private func allValid(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    func testRegionModeTogglesWithSelection() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _, _ in [0, 1] })
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
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _, _ in [0, 1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, false, true])
        c.pickSelection("reg")
        XCTAssertEqual(c.selectedResidueIndices, [0, 2])   // idx 1 (invalid) dropped
    }

    // Click-built region under the count-driven rule: successive toggles accumulate
    // designable residues into a region, non-designable positions never count,
    // dropping back to ONE designable residue returns to single-residue pin mode
    // (empty region), and removing the last one leaves nothing active. The label of
    // a click-built region is "sele" — it IS the ordinary selection now, not a
    // separate "custom" copy the controller keeps on the side.
    func testTapResidueBuildsAdHocRegion() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: [true, true, false, true])
        XCTAssertFalse(c.regionModeActive)

        c.tapResidue(residueIndex: 3)
        XCTAssertEqual(c.pinnedResidueIndex, 3,
                       "one designable residue is single-residue mode, not a region")
        XCTAssertFalse(c.regionModeActive)

        c.tapResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])   // kept sorted
        XCTAssertTrue(c.regionModeActive)
        XCTAssertNil(c.pinnedResidueIndex, "region mode drops the pin")
        XCTAssertEqual(c.selectedSelectionName, "sele",
                       "a click-built region is labelled 'sele'")

        c.tapResidue(residueIndex: 2)             // invalid → never counts
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])

        c.tapResidue(residueIndex: 1)             // remove → one left
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "one designable residue leaves region mode")
        XCTAssertEqual(c.pinnedResidueIndex, 3, "the survivor is pinned")
        XCTAssertNil(c.selectedSelectionName)

        c.tapResidue(residueIndex: 3)             // remove last → nothing
        XCTAssertFalse(c.regionModeActive)
        XCTAssertNil(c.selectedSelectionName)
        XCTAssertNil(c.pinnedResidueIndex)
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
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       listSelections: { _, _, _ in
                           [DesignSelectionOption(name: "loopA", count: 12),
                            DesignSelectionOption(name: "sele", count: 5)]
                       })
        c.setFocusForTest("m1", nativeSequence: [5, 5], validFlags: allValid(2))
        c.refreshSelections()
        XCTAssertEqual(c.availableSelections.map { $0.name }, ["loopA", "sele"])
        XCTAssertEqual(c.availableSelections.first?.count, 12)
    }

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

    // refreshSelections/pickSelection scope to the focus object AND its edit source,
    // so selections made on the original still resolve once a working copy is focused.
    func testSelectionScopingPassesSourceObjectWhenEditing() async {
        var srcSeen: [String?] = []
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       listSelections: { _, src, _ in srcSeen.append(src); return [] },
                       selectedIndices: { _, _, _, _ in [0] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.refreshSelections()                                  // pre-edit: no source
        await c.applyMutationAwait(residueIndex: 0, aa: 7)     // begins edit → editSourceObject "m1"
        c.refreshSelections()                                  // post-edit: source is the original
        XCTAssertEqual(srcSeen.count, 2)
        XCTAssertNil(srcSeen[0])
        XCTAssertEqual(srcSeen[1], "m1")
    }

    func testRedesignScattersOnlyIntoRegion() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _, _ in [1, 3] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5, 5], validFlags: allValid(5))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [5, 9, 5, 9, 5])   // only free positions changed
    }

    func testFixedPartitionIsComplementOfRegion() async {
        var capturedFixed: Set<Int>?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, fixed, native, _, _ in capturedFixed = fixed; return native },
                       selectedIndices: { _, _, _, _ in [0, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: allValid(4))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedFixed, [1, 3])               // complement of free {0,2} over L=4
    }

    func testValidProjectedPartitionAndNativeWithGaps() async {
        var capturedFixed: Set<Int>?; var capturedNative: [Int]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, fixed, native, _, _ in
            capturedFixed = fixed; capturedNative = native; return native
        }, selectedIndices: { _, _, _, _ in [0, 2] })       // full idx 0,2 selected; idx 1 invalid
        c.setFocusForTest("m1", nativeSequence: [5, 6, 7], validFlags: [true, false, true])
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        // valid residues full {0,2} → valid-projected {0,1}; both selected → free {0,1}, fixed {}.
        XCTAssertEqual(capturedFixed, [])
        XCTAssertEqual(capturedNative, [5, 7])              // valid-projected native (gap dropped)
    }

    func testScatterWithInvalidGap() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, _, _, _ in [9, 8] },   // valid-projected result (L=2)
                       selectedIndices: { _, _, _, _ in [0, 2] })   // full idx 0,2 → valid-projected 0,1
        c.setFocusForTest("m1", nativeSequence: [5, 6, 7], validFlags: [true, false, true])
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        // Both designed values must land on the correct side of the invalid gap:
        // full 0 ← result[0]==9, full 2 ← result[1]==8, and full 1 (no backbone)
        // is skipped entirely and keeps its native identity.
        XCTAssertEqual(c.editedSequence, [9, 6, 8])
    }

    func testNativeSequenceReflectsPriorEdits() async {
        var capturedNative: [Int]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _, _ in capturedNative = native; return native },
                       selectedIndices: { _, _, _, _ in [2, 3] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: allValid(4))
        await c.applyMutationAwait(residueIndex: 0, aa: 7)  // earlier manual edit
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedNative, [7, 5, 5, 5])        // manual edit carried into native
    }

    func testOmitDerivedFromPalette() async {
        var capturedOmit: [Set<Int>]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, omit, _ in capturedOmit = omit; return native },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        c.togglePalette(4); c.togglePalette(12)
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedOmit?.count, 3)              // one per valid residue (L=3)
        XCTAssertEqual(capturedOmit?.first, [4, 12])        // inactive set, uniform
    }

    // The slider value flows through to design()'s temperature argument.
    func testTemperaturePassedToDesign() async {
        var capturedTemp: Float?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _, temp in capturedTemp = temp; return native },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.designTemperature = 0.7
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(capturedTemp, 0.7)
    }

    // The busy flags drive an INPUT-BLOCKING overlay: if one is left set the whole UI
    // is wedged. They must be clear after every outcome — success, failure, and a
    // redesign whose follow-up repack runs.
    func testBusyFlagsClearAfterSuccessfulRedesign() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.injectRepack(repack: { _, _ in "REPACKED" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [5, 9, 9],
                       "the redesign must actually have run — without this the flag "
                     + "assertions below pass vacuously on any early return")
        XCTAssertFalse(c.isRedesigning, "isRedesigning must clear after a successful redesign")
        XCTAssertFalse(c.isRepacking, "isRepacking must clear after the follow-up repack")
    }

    // Regression for the stranded blocking overlay: the redesign flag must NOT span
    // the follow-up repack. When it did, any stall in that tail left "Redesigning
    // region…" up forever with input blocked (observed on host: sequence applied,
    // inference idle, overlay stuck). Probe the flag from loadRepacked, which runs
    // on the main actor while the repack phase is in progress.
    func testRedesignFlagDoesNotSpanRepackPhase() async {
        var flagDuringRepack: Bool?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.injectRepack(repack: { _, _ in "PDB" },
                       loadRepacked: { [weak c] _, _ in flagDuringRepack = c?.isRedesigning })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(flagDuringRepack, false,
                       "isRedesigning must already be clear once the repack phase runs — "
                     + "otherwise a stalled repack strands the input-blocking overlay")
        XCTAssertFalse(c.isRedesigning)
        XCTAssertFalse(c.isRepacking)
    }

    func testBusyFlagClearsWhenDesignThrows() async {
        struct Boom: Error {}
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, _, _, _ in throw Boom() },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertFalse(c.isRedesigning, "a failed redesign must not strand the blocking overlay")
        XCTAssertNotNil(c.errorText)
    }

    func testBusyFlagClearsWhenDesignReturnsWrongLength() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, _, _, _ in [1, 2, 3, 4, 5, 6, 7] },  // wrong length
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.errorText, "Region redesign failed",
                       "design() must actually have been called and rejected for its "
                     + "length — otherwise the rollback assertion below is vacuous")
        XCTAssertFalse(c.isRedesigning)
        XCTAssertEqual(c.editedSequence, [5, 5, 5])   // rolled back
    }

    func testEmptyPaletteBlocksRedesign() async {
        var called = false
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _, _ in called = true; return native },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5], validFlags: allValid(2))
        c.pickSelection("reg")
        // Pre-condition: without this, `called == false` also holds when the region
        // never designated at all — the assertion would pass for the wrong reason.
        XCTAssertTrue(c.regionModeActive, "pre-condition: a region must be designated")
        for i in 0..<20 where c.paletteAllowed.contains(i) { c.togglePalette(i) }
        await c.redesignSelectionAwait()
        XCTAssertFalse(called, "an empty palette must block the run")
    }

    func testRevertRestoresPreRedesignAndKeepsEarlierEdits() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _, _ in [2, 3] })
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
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) },
                       selectedIndices: { _, _, _, _ in [1, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.redesignSnapshot)
        await c.applyMutationAwait(residueIndex: 2, aa: 3)
        XCTAssertNil(c.redesignSnapshot)                    // revert invalidated by a manual edit
    }

    // MARK: – 'sele' as the single source of truth

    // No selection -> nothing active. This is the idle state the greyed propensity
    // row renders.
    func testSyncFromSeleWithNothingSelected() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
        XCTAssertEqual(c.syncFromSele(), 0)
        XCTAssertNil(c.pinnedResidueIndex)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertFalse(c.regionModeActive)
    }

    // Exactly one selected residue must reproduce today's single-residue
    // behaviour: pinned, and NOT region mode, so the propensity pills still show.
    func testOneSelectedResiduePinsAndStaysOutOfRegionMode() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
        c.injectSele(seleState: { _, _, _ in (indices: [1, 99, -1], digest: "d4", total: 3) })
        XCTAssertEqual(c.syncFromSele(), 1)
        XCTAssertEqual(c.pinnedResidueIndex, 1)
    }

    // Residues selected on OTHER structures are reported so the UI can say so
    // instead of silently ignoring them.
    func testOffFocusResiduesAreCounted() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
        c.injectSele(seleState: { _, _, _ in (indices: [0], digest: "d5", total: 3) })
        c.syncFromSele()
        XCTAssertEqual(c.seleResiduesOffFocus, 2)
    }

    // With no focus object there is nothing to resolve against; sync must reset
    // rather than keep stale indices.
    func testSyncWithoutFocusResets() {
        let c = makeController()
        c.injectSele(seleState: { _, _, _ in (indices: [0, 1], digest: "d6", total: 2) })
        XCTAssertEqual(c.syncFromSele(), 0)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertNil(c.pinnedResidueIndex)
    }

    // MARK: – Gestures route through 'sele'

    // Successive taps accumulate, exactly like normal-mode clicks: 1 -> pin,
    // 2 -> region. This is the behaviour the whole change exists to deliver.
    func testSuccessiveTapsAccumulateIntoARegion() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))

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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)
        c.handleViewportHit(object: "m1", chain: "A", resi: "99", hasResidue: true)
        XCTAssertEqual(c.pinnedResidueIndex, 0,
                       "an unresolvable residue must not disturb the selection")
    }

    // The lasso dropdown writes 'sele' and keeps its own label.
    func testPickSelectionWritesSeleAndKeepsItsLabel() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
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
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
            designCalls += 1
            return Array(repeating: 0, count: r.count)
        })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

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
    //
    // Driven through the DEBUG `refocusAndSelectAwait` seam, which calls the SAME
    // private method the synchronous `focusThenSelect` wraps in a Task. Awaiting the
    // seam is deterministic; polling `focusObject` with a fixed number of
    // `Task.yield()`s would not be, because `focusAwait` crosses a real
    // DispatchQueue hop. That `handleViewportHit` routes a non-focus object into
    // this path is covered by DesignIOSPortTests.testHandleViewportHitRefocusesOnDifferentObject.
    func testHitOnOtherObjectRefocusesAndSelects() async {
        // m2's residues deliberately use DIFFERENT keys from m1's (which
        // setFocusForTest builds as chain "A", resi "1"..."3"), so the two objects
        // are not interchangeable and no future test can pass by accident.
        let m2Residues = (1...3).map { i in
            DesignResidue(chain: "B", resi: "\(100 + i)", resn: "ALA", aa: 5,
                          backbone: MPNNModel.Residue(n: .zero, ca: .zero, c: .zero,
                                                      o: .zero, chain: 1, resSeq: 100 + i),
                          valid: true)
        }
        let c = DesignController(
            enumerate: { obj, _ in
                DesignResidueSet(object: obj, state: 1, residues: m2Residues)
            },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
        c.allObjects = ["m1", "m2"]

        // 'sele', modelled object-awarely: PyMOL resolves a selection against
        // whichever object is in scope, so reading it while the OLD object is still
        // focused yields the OLD object's indices. That is the hazard under test.
        var sele: Set<String> = []
        var focusWhenWritten: String?
        c.injectSele(
            seleState: { obj, _, _ in
                let keys = (obj == "m2")
                    ? ["B/101", "B/102", "B/103"]
                    : ["A/1", "A/2", "A/3"]
                let idx = keys.enumerated().compactMap { sele.contains($0.element) ? $0.offset : nil }
                return (indices: idx, digest: "\(sele.sorted())", total: sele.count)
            },
            toggleSele: { _, chain, resi, _ in
                let k = "\(chain)/\(resi)"
                if sele.contains(k) { sele.remove(k) } else { sele.insert(k) }
            },
            setSeleResidue: { [weak c] _, chain, resi, _ in
                // Record WHEN the write lands relative to the refocus. This is the
                // load-bearing assertion: every state assertion below also passes
                // if the two steps are swapped, because `focusAwait` ends with its
                // own `syncFromSele()` and would re-derive the right indices anyway.
                focusWhenWritten = c?.focusObject
                sele = ["\(chain)/\(resi)"]
            })

        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)       // a residue selected on the OLD focus
        XCTAssertEqual(c.pinnedResidueIndex, 0, "pre-condition: A/1 selected on m1")

        await c.refocusAndSelectAwait(object: "m2", chain: "B", resi: "102", hasResidue: true)

        XCTAssertEqual(focusWhenWritten, "m2",
                       "the selection must be written AFTER the refocus completes — "
                     + "writing it first resolves the new residue against the OLD "
                     + "object's residue set and silently produces wrong indices")
        XCTAssertEqual(c.focusObject, "m2", "the click must retarget design")
        XCTAssertEqual(c.pinnedResidueIndex, 1,
                       "the clicked residue must be selected by the same click (D4)")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "old-focus residues must not linger in the region")
        XCTAssertEqual(sele, ["B/102"], "'sele' holds exactly the clicked residue")
    }

    // Ending an edit session must leave the derived state agreeing with 'sele'.
    // teardownEditSession calls clearRegionState(), which wipes the region, but the
    // teardown never touches 'sele' — so without a re-derive the UI loses the
    // Redesign button and palette row while the pink markers still show a
    // multi-residue selection. The panel poll cannot rescue it: it is digest-gated,
    // and an unchanged 'sele' produces an identical digest, so the re-derive is
    // skipped and the wrong state persists until the user happens to click a
    // residue. Both teardown paths (Keep and Discard) share the code, so both are
    // exercised here.
    func testEndingAnEditSessionKeepsTheRegionDerivedFromSele() async {
        for keep in [true, false] {
            let c = makeController(); wireEdit(c)
            c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 9, count: r.count) })
            c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
            c.tapResidue(residueIndex: 0)
            c.tapResidue(residueIndex: 2)
            XCTAssertEqual(c.selectedResidueIndices, [0, 2], "pre-condition: region designated")

            await c.applyMutationAwait(residueIndex: 1, aa: 7)   // begins the edit session
            XCTAssertTrue(c.editing, "pre-condition: an edit session must be open")

            if keep { c.keepEdits() } else { c.discardEdits() }

            let path = keep ? "Keep" : "Discard"
            XCTAssertFalse(c.editing, "\(path): the session must be closed")
            XCTAssertEqual(c.selectedResidueIndices, [0, 2],
                           "\(path): 'sele' still holds both residues, so the region must survive")
            XCTAssertTrue(c.regionModeActive, "\(path): region mode must survive the teardown")
            XCTAssertEqual(c.selectedSelectionName, "sele", "\(path): label re-derived")
        }
    }

    // The lasso name must not outlive the region it labels. Designate a named
    // region, leave Design mode, then re-enter with 'sele' untouched: the region
    // re-derives from 'sele' and is now click-built, so it must carry the "sele"
    // label, not the stale lasso name. The focus-change path shares the same reset
    // (both go through clearRegionState), so this covers it too.
    func testStaleLassoNameDoesNotSurviveLeavingDesignMode() async {
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
        c.allObjects = ["m1"]
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _, _ in [0, 2] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.pickSelection("loop")
        XCTAssertEqual(c.selectedSelectionName, "loop", "pre-condition: named region")

        c.exit()                      // must scrub the stale name
        await c.focusAwait("m1")      // re-enter; 'sele' still holds both residues

        XCTAssertEqual(c.selectedResidueIndices, [0, 2],
                       "pre-condition: the region still derives from 'sele'")
        XCTAssertEqual(c.selectedSelectionName, "sele",
                       "the lasso name must not outlive the region it labelled")
    }

    // A refocus whose enumerate throws must leave 'sele' untouched. Writing anyway
    // would swap the user's selection for a residue that cannot be resolved against
    // any residue set, leaving them with neither the old selection nor a usable new
    // one.
    func testFailedRefocusLeavesSeleUntouched() async {
        struct Boom: Error {}
        var wrote = false
        let c = DesignController(
            enumerate: { _, _ in throw Boom() },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
        c.allObjects = ["m1", "m2"]
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.injectSele(setSeleResidue: { _, _, _, _ in wrote = true },
                     clearSele: { wrote = true })

        await c.refocusAndSelectAwait(object: "m2", chain: "A", resi: "2", hasResidue: true)

        XCTAssertNotNil(c.errorText, "pre-condition: the focus must actually have failed")
        XCTAssertFalse(wrote, "a failed refocus must not touch 'sele'")
    }

    // D2: leaving Design mode must NOT wipe the user's ordinary selection.
    func testExitDoesNotClearSele() {
        let c = makeController()
        var cleared = false
        c.injectSele(clearSele: { cleared = true })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)
        c.exit()
        XCTAssertFalse(cleared,
                       "exiting Design mode must leave 'sele' alone (D2)")
    }

    // The poll must re-derive only when the digest actually changed, so a quiet
    // 500 ms tick costs nothing.
    func testSyncFromSeleRecordsTheDigestItResolved() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, true, true])
        c.injectSele(seleState: { _, _, _ in (indices: [0], digest: "abc123", total: 1) })
        c.syncFromSele()
        XCTAssertEqual(c.lastSeleDigest, "abc123",
                       "the resolved digest must be recorded for poll gating")
    }

    // MARK: – I1: 'sele' writes are scoped like 'sele' reads

    // Inside an edit session the focus is the WORKING COPY while the selection still
    // sits on the original's atoms, and every read resolves `sele ∩ scope(obj, src)`
    // by (chain, resi) identity. A writer that never learns the source object
    // therefore addresses a different atom set than the reader: the toggle finds no
    // focus-object atoms in 'sele', so it ADDS instead of removing (the region
    // member becomes un-removable and gets counted twice), and residues clicked
    // mid-session lose their only membership when a repack replaces the working
    // copy's topology. Python owns the scoping (see design_region.py); what Swift
    // must guarantee is that `editSourceObject` actually reaches both writers.
    func testSeleWritesCarryTheEditSourceScope() async {
        var toggleSrc: [String?] = []
        var setSrc: [String?] = []
        let c = makeController(); wireEdit(c)
        c.injectSele(toggleSele: { _, _, _, src in toggleSrc.append(src) },
                     setSeleResidue: { _, _, _, src in setSrc.append(src) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.tapResidue(residueIndex: 0)
        XCTAssertEqual(toggleSrc, [nil],
                       "with no edit session open there is no source object to scope to")

        await c.applyMutationAwait(residueIndex: 1, aa: 7)   // opens the edit session
        XCTAssertTrue(c.editing, "pre-condition: an edit session must be open")
        XCTAssertEqual(c.focusObject, "m1_design",
                       "pre-condition: the focus must have moved to the working copy")

        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(toggleSrc.last, "m1",
                       "a toggle inside an edit session must carry the source object, "
                     + "or it cannot remove a member selected on the original")

        await c.refocusAndSelectAwait(object: "m1_design", chain: "A", resi: "3",
                                     hasResidue: true)
        XCTAssertEqual(setSrc.last, "m1",
                       "the replace-with-one-residue write must be scoped too")
    }

    // MARK: – The panel-poll gate

    // The gate itself, not just the digest bookkeeping: an unchanged digest must
    // SKIP the re-derive (a quiet 500 ms tick costs nothing) and a changed one must
    // trigger it.
    func testPollGateReDerivesOnlyWhenTheDigestChanged() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        var reads = 0
        c.injectSele(seleState: { _, _, _ in
            reads += 1
            return (indices: [0], digest: "d1", total: 1)
        })

        XCTAssertTrue(c.syncFromSeleIfChanged(digest: "d1"),
                      "a digest never seen before must re-derive")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(c.pinnedResidueIndex, 0)

        XCTAssertFalse(c.syncFromSeleIfChanged(digest: "d1"),
                       "an unchanged digest must skip the re-derive")
        XCTAssertEqual(reads, 1, "a quiet tick must not read 'sele' at all")

        c.injectSele(seleState: { _, _, _ in
            reads += 1
            return (indices: [0, 2], digest: "d2", total: 2)
        })
        XCTAssertTrue(c.syncFromSeleIfChanged(digest: "d2"),
                      "a changed digest must re-derive")
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(c.selectedResidueIndices, [0, 2])
    }

    // M2: Design mode on with NO focus object (2+ objects loaded, so enter() does
    // not auto-focus) and a non-empty 'sele'. syncFromSele cannot read a digest
    // without an object to scope the read to, so the gate must adopt the digest the
    // poll observed — otherwise every 500 ms tick re-derives forever, republishing
    // four @Published properties and invalidating the design bar, compact panel and
    // sequence strip twice a second for as long as the mode is open.
    func testPollGateDoesNotSpinWithoutAFocusObject() {
        let c = makeController()
        c.allObjects = ["m1", "m2"]           // enter() must not auto-focus
        c.enter()
        XCTAssertNil(c.focusObject, "pre-condition: nothing is focused")

        XCTAssertTrue(c.syncFromSeleIfChanged(digest: "py-digest"),
                      "the first tick after entering may re-derive once")
        for tick in 1...4 {
            XCTAssertFalse(c.syncFromSeleIfChanged(digest: "py-digest"),
                           "tick \(tick): an unchanged 'sele' must not re-derive "
                         + "just because there is no focus object")
        }
    }

    // M3: a named selection that resolves to exactly ONE designable residue pins
    // (no region), so the branch that consumes the lasso label never runs — and the
    // label must not survive to mislabel the NEXT region.
    func testOneResidueNamedRegionDoesNotLabelTheNextRegion() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5, 5], validFlags: allValid(5))
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                       selectedIndices: { _, _, _, _ in [2] })   // ONE residue

        c.pickSelection("hotspot")
        XCTAssertEqual(c.pinnedResidueIndex, 2,
                       "pre-condition: one designable residue pins rather than designating")
        XCTAssertNil(c.selectedSelectionName, "pre-condition: no region, so no label")

        // A 5-residue selection now arrives from outside Design mode (`select sele,
        // resi 1-5` at the prompt) and reaches the controller through the poll.
        c.injectSele(seleState: { _, _, _ in
            (indices: [0, 1, 2, 3, 4], digest: "external", total: 5)
        })
        c.syncFromSeleIfChanged(digest: "external")

        XCTAssertEqual(c.selectedResidueIndices, [0, 1, 2, 3, 4])
        XCTAssertEqual(c.selectedSelectionName, "sele",
                       "a click-built region must not inherit the stale lasso name")
    }

    // M4: `refocusAndSelect` must check that the focus is still CURRENT, not merely
    // that the object exists. Two rapid clicks on two different non-focus objects
    // spawn two Tasks; if the loser resumes last its write lands while the winner
    // owns the focus, leaving 'sele' on a NON-focused object — pink markers plus
    // "nothing selected", because every read is scoped to the focus object.
    //
    // The interleaving is made deterministic by having the loser's own `enumerate`
    // move the focus, which is exactly where the competing task's `focusAwait` would
    // land: after `focusObject = object` and before the 'sele' write.
    func testRefocusDoesNotWriteSeleWhenAnotherObjectWonTheFocus() async {
        var writes: [String] = []
        var ctrl: DesignController?
        let residues = (1...3).map { i in
            DesignResidue(chain: "B", resi: "\(100 + i)", resn: "ALA", aa: 5,
                          backbone: MPNNModel.Residue(n: .zero, ca: .zero, c: .zero,
                                                      o: .zero, chain: 1, resSeq: 100 + i),
                          valid: true)
        }
        let c = DesignController(
            enumerate: { obj, _ in
                if obj == "m2" { ctrl?.focusObject = "m3" }   // the winner takes over
                return DesignResidueSet(object: obj, state: 1, residues: residues)
            },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
        ctrl = c
        c.allObjects = ["m1", "m2", "m3"]
        c.injectSele(setSeleResidue: { obj, _, resi, _ in writes.append("\(obj)/\(resi)") },
                     clearSele: { writes.append("clear") })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        await c.refocusAndSelectAwait(object: "m2", chain: "B", resi: "102",
                                     hasResidue: true)

        XCTAssertEqual(c.focusObject, "m3",
                       "pre-condition: another object must have won the focus — "
                     + "m2's residue set DOES exist, so existence alone is not enough")
        XCTAssertTrue(writes.isEmpty,
                      "a superseded refocus must not write 'sele' onto an object that "
                    + "is no longer focused: \(writes)")
    }

    // MARK: – Design mode adopts a selection made before it opened

    // Goal 4's most visible consequence: an ordinary normal-mode selection is already
    // a designated region the moment Design mode focuses a structure — no lasso, no
    // re-clicking.
    func testEnteringDesignModeAdoptsAPreExistingSele() async {
        let residues = (1...5).map { i in
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
        c.allObjects = ["m1"]
        // 'sele' already holds three residues, selected in normal mode.
        c.injectSele(seleState: { _, _, _ in
            (indices: [1, 2, 3], digest: "pre-existing", total: 3)
        })

        c.enter()                     // single object → auto-focus
        await c.focusAwait("m1")      // the deterministic half of what enter() starts

        XCTAssertEqual(c.selectedResidueIndices, [1, 2, 3],
                       "the pre-existing selection must arm the region immediately")
        XCTAssertTrue(c.regionModeActive,
                      "\"Redesign selection · 3 res\" must be armed on entry")
        XCTAssertNil(c.pinnedResidueIndex, "3 residues is region mode, not a pin")
        XCTAssertEqual(c.selectedSelectionName, "sele")
    }

    // MARK: – M5: an unreadable pick payload must not destroy the selection

    // `handleViewportHit(object: "")` CLEARS 'sele', so "I could not read the pick"
    // and "the pick ran and missed" cannot share an encoding: the first must be a
    // no-op, the second must clear (normal-mode parity).
    func testDesignPickOutcomeSeparatesAMissFromAnUnreadablePayload() {
        XCTAssertNil(PyMOLEngine.designPickOutcome(payload: nil),
                     "no file / unparseable JSON: the tap must be a no-op")
        XCTAssertNil(PyMOLEngine.designPickOutcome(payload: [:]),
                     "a payload with no 'hit' key is not a pick result")

        let miss = PyMOLEngine.designPickOutcome(
            payload: ["hit": false, "obj": "m1", "chain": "A", "resi": "2"])
        XCTAssertEqual(miss?.hit, false)
        XCTAssertEqual(miss?.object, "",
                       "a genuine miss must reach the controller as an empty object "
                     + "so the empty-space tap clears 'sele'")

        let hit = PyMOLEngine.designPickOutcome(
            payload: ["hit": true, "obj": "m1", "chain": "A", "resi": "2"])
        XCTAssertEqual(hit?.hit, true)
        XCTAssertEqual(hit?.object, "m1")
        XCTAssertEqual(hit?.chain, "A")
        XCTAssertEqual(hit?.resi, "2")
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
}
#endif
