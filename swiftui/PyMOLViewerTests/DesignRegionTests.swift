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
