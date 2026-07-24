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
}
#endif
