#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignControllerTests: XCTestCase {
    func testFocusScoresOnceThenHitsCache() async throws {
        var scoreCalls = 0
        let residueSet = DesignResidueSet(object: "m1", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)])
        let controller = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in
                scoreCalls += 1
                return MPNNModel.ScoreResult(
                    logProbs: [[Float](repeating: Float(log(1.0 / 21.0)), count: 21)],
                    currentAALogProb: [-1.0])
            },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        controller.enter()
        await controller.focusAwait("m1")     // test-only awaitable variant of focus(_:)
        XCTAssertEqual(scoreCalls, 1)
        await controller.focusAwait("m1")     // same object/seq/state -> cache hit
        XCTAssertEqual(scoreCalls, 1, "Second focus on same object should hit cache, not re-score")
    }

    func testJobTokenCancelsSupersededFocus() async throws {
        // Real supersession: A's scorer blocks in-flight while B starts and bumps jobToken.
        // The serial inference queue means B's scorer queues behind A, but jobToken is incremented
        // on the MainActor synchronously at the START of focusAwait (before the queue.async).
        // So by the time A's scorer completes and A's continuation resumes, jobToken is already 2;
        // A's guard (token==1 vs jobToken==2) fails and A's result is discarded.
        let semaphore = DispatchSemaphore(value: 0)
        var coloredObjects: [String] = []
        let aEnteredScorer = XCTestExpectation(description: "A's scorer in-flight and blocked")

        let residueSet = DesignResidueSet(object: "obj", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)])

        // isFirstScoreCall is only ever touched from the serial inference queue — no lock needed.
        var isFirstScoreCall = true
        let controller = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in
                if isFirstScoreCall {
                    isFirstScoreCall = false
                    aEnteredScorer.fulfill()
                    semaphore.wait()    // block A; B's queue.async is enqueued but waits
                }
                return MPNNModel.ScoreResult(
                    logProbs: [[Float](repeating: Float(log(1.0 / 21.0)), count: 21)],
                    currentAALogProb: [-1.0])
            },
            applyColoring: { obj, _, _, _, _ in coloredObjects.append(obj) },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })

        controller.enter()

        // Start A without awaiting — A's scorer will block on the semaphore.
        controller.focus("A")

        // Wait until A is confirmed in-flight and blocked.
        await fulfillment(of: [aEnteredScorer], timeout: 2)

        // Spawn B as an awaitable Task; then yield so Task_B runs its synchronous prefix
        // on the MainActor (which bumps jobToken to 2) before we release A.
        let taskB = Task { @MainActor in await controller.focusAwait("B") }
        await Task.yield()

        // Release A. When A's continuation resumes it will find jobToken==2 ≠ token_A==1
        // and return without coloring. The queue then drains B's enqueued work.
        semaphore.signal()

        // Wait for B's full lifecycle (enumerate → score → cache → recolor).
        await taskB.value

        // Only B should have been colored; A's result must be discarded by the token guard.
        XCTAssertEqual(coloredObjects, ["B"],
                       "A's result must be discarded; only B should trigger applyColoring")
    }

    func testColorMeaningRecolorOnSetMeaning() async throws {
        var lastPalette: String?
        let residueSet = DesignResidueSet(object: "m2", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)])
        let controller = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in
                MPNNModel.ScoreResult(
                    logProbs: [[Float](repeating: Float(log(1.0 / 21.0)), count: 21)],
                    currentAALogProb: [-1.0])
            },
            applyColoring: { _, _, palette, _, _ in lastPalette = palette },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        controller.enter()
        await controller.focusAwait("m2")
        // Default meaning is nativeFit -> red_white_blue palette.
        XCTAssertEqual(lastPalette, "red_white_blue")
        // Switch to certainty -> blue_white_red palette, recolor called immediately.
        controller.setMeaning(.certainty)
        XCTAssertEqual(lastPalette, "blue_white_red")
    }
}
#endif
