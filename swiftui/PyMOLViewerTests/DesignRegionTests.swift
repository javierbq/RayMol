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
    func testToggleRegionResidueBuildsAdHocRegion() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: [true, true, false, true])
        XCTAssertFalse(c.regionModeActive)

        c.toggleRegionResidue(residueIndex: 3)
        XCTAssertEqual(c.pinnedResidueIndex, 3,
                       "one designable residue is single-residue mode, not a region")
        XCTAssertFalse(c.regionModeActive)

        c.toggleRegionResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])   // kept sorted
        XCTAssertTrue(c.regionModeActive)
        XCTAssertNil(c.pinnedResidueIndex, "region mode drops the pin")
        XCTAssertEqual(c.selectedSelectionName, "sele",
                       "a click-built region is labelled 'sele'")

        c.toggleRegionResidue(residueIndex: 2)             // invalid → never counts
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])

        c.toggleRegionResidue(residueIndex: 1)             // remove → one left
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "one designable residue leaves region mode")
        XCTAssertEqual(c.pinnedResidueIndex, 3, "the survivor is pinned")
        XCTAssertNil(c.selectedSelectionName)

        c.toggleRegionResidue(residueIndex: 3)             // remove last → nothing
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
                       selectedIndices: { _, _, _, _ in [2] })      // full idx 2 → valid-projected 1
        c.setFocusForTest("m1", nativeSequence: [5, 6, 7], validFlags: [true, false, true])
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertEqual(c.editedSequence, [5, 6, 8])         // only full idx 2 changed → result[1]==8
    }

    func testNativeSequenceReflectsPriorEdits() async {
        var capturedNative: [Int]?
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _, _ in capturedNative = native; return native },
                       selectedIndices: { _, _, _, _ in [2] })
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
                       selectedIndices: { _, _, _, _ in [1] })
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
                       selectedIndices: { _, _, _, _ in [1] })
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
                       selectedIndices: { _, _, _, _ in [1] })
        c.injectRepack(repack: { _, _ in "REPACKED" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
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
                       selectedIndices: { _, _, _, _ in [1] })
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
                       selectedIndices: { _, _, _, _ in [1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertFalse(c.isRedesigning, "a failed redesign must not strand the blocking overlay")
        XCTAssertNotNil(c.errorText)
    }

    func testBusyFlagClearsWhenDesignReturnsWrongLength() async {
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, _, _, _ in [1, 2, 3, 4, 5, 6, 7] },  // wrong length
                       selectedIndices: { _, _, _, _ in [1] })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")
        await c.redesignSelectionAwait()
        XCTAssertFalse(c.isRedesigning)
        XCTAssertEqual(c.editedSequence, [5, 5, 5])   // rolled back
    }

    func testEmptyPaletteBlocksRedesign() async {
        var called = false
        let c = makeController(); wireEdit(c)
        c.injectRegion(designRegion: { _, _, native, _, _ in called = true; return native },
                       selectedIndices: { _, _, _, _ in [0] })
        c.setFocusForTest("m1", nativeSequence: [5, 5], validFlags: allValid(2))
        c.pickSelection("reg")
        for i in 0..<20 where c.paletteAllowed.contains(i) { c.togglePalette(i) }
        await c.redesignSelectionAwait()
        XCTAssertFalse(called)
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
                       selectedIndices: { _, _, _, _ in [1] })
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
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)       // a residue selected on the OLD focus

        await c.refocusAndSelectAwait(object: "m2", chain: "A", resi: "2", hasResidue: true)

        XCTAssertEqual(c.focusObject, "m2", "the click must retarget design")
        XCTAssertEqual(c.pinnedResidueIndex, 1,
                       "the clicked residue must be selected by the same click (D4)")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "old-focus residues must not linger in the region")
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
}
#endif
