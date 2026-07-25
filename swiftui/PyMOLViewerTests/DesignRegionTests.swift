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

    // Shift-click region building: toggleRegionResidue adds/removes valid residues,
    // ignores invalid ones, and detaches into a "custom" ad-hoc region.
    func testToggleRegionResidueBuildsAdHocRegion() {
        let c = makeController()
        c.injectRegion(designRegion: { r, _, _, _, _ in Array(repeating: 0, count: r.count) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5, 5], validFlags: [true, true, false, true])
        XCTAssertFalse(c.regionModeActive)
        c.toggleRegionResidue(residueIndex: 3)
        c.toggleRegionResidue(residueIndex: 1)
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])   // kept sorted
        XCTAssertTrue(c.regionModeActive)
        XCTAssertEqual(c.selectedSelectionName, "custom")
        c.toggleRegionResidue(residueIndex: 2)             // invalid → ignored
        XCTAssertEqual(c.selectedResidueIndices, [1, 3])
        c.toggleRegionResidue(residueIndex: 1)             // remove
        XCTAssertEqual(c.selectedResidueIndices, [3])
        c.toggleRegionResidue(residueIndex: 3)             // remove last → empty
        XCTAssertFalse(c.regionModeActive)
        XCTAssertNil(c.selectedSelectionName)
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
}
#endif
