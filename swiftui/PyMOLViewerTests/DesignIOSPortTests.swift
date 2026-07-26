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

    // MARK: – Task 4: size-guard wiring

    // A run predicted to exceed the budget must never reach the inference queue.
    func testOversizeRedesignIsRefused() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .refuse(maxFittingResidues: 500) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()

        XCTAssertEqual(designCalls, 0, "a refused run must not dispatch inference")
        XCTAssertNotNil(c.errorText, "a refused run must explain itself")
        XCTAssertNil(c.pendingSizeWarning, "refuse is terminal, not a confirmation")
    }

    // In the warn band the run is held pending explicit confirmation, and the
    // autosave fires first so a jetsam kill costs no work.
    func testWarnBandHoldsRunUntilConfirmedAndAutosavesFirst() async {
        let c = makeController()
        var designCalls = 0
        var autosaves = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.autosaveBeforeLargeRun = { autosaves += 1 }
        c.sizeDecisionProvider = { n in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertEqual(designCalls, 0, "warn must hold the run, not start it")
        XCTAssertNotNil(c.pendingSizeWarning)
        XCTAssertEqual(c.pendingSizeWarning?.residueCount, 3)
        XCTAssertEqual(autosaves, 0, "autosave belongs to the confirm path, not the prompt")

        await c.confirmPendingWarning()
        XCTAssertEqual(autosaves, 1, "confirming must autosave before dispatching")
        XCTAssertEqual(designCalls, 1, "confirming must actually run the design")
        XCTAssertNil(c.pendingSizeWarning)
    }

    func testCancellingWarningRunsNothing() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.pendingSizeWarning)
        c.cancelPendingWarning()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 0)
    }

    // An explicit .ok decision (representing any non-blocking case) must never
    // hold or refuse the run.
    func testOkDecisionNeverBlocks() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.sizeDecisionProvider = { _ in .ok }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 1)
    }

    // The default sizeDecisionProvider routes through DesignSizeGuard.evaluate,
    // which returns .ok unconditionally on macOS regardless of residue count.
    // This test exercises the genuine production path and proves shipped macOS
    // behaviour does not change even for objects that would exhaust any iOS device.
    func testMacOSDefaultSizeProviderNeverBlocks() async {
        let c = makeController()
        var designCalls = 0
        let count = 1000   // far above any iOS headroom; irrelevant on macOS
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        // sizeDecisionProvider is NOT injected — exercises the real default path.
        c.setFocusForTest("m1", nativeSequence: Array(repeating: 5, count: count),
                          validFlags: allValid(count))
        c.pickSelection("reg")   // selectedIndices returns [0]

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning,
                     "macOS default provider (evaluate → .ok) must never block")
        XCTAssertNil(c.errorText)   // no error from the guard
        XCTAssertEqual(designCalls, 1, "macOS default provider must let the design run")
    }
}
#endif
