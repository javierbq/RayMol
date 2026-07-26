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
