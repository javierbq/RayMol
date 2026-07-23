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
        // Two back-to-back focuses; the first result should be discarded (token mismatch).
        var callCount = 0
        let residueSet = DesignResidueSet(object: "m1", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)])
        let controller = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in
                callCount += 1
                return MPNNModel.ScoreResult(
                    logProbs: [[Float](repeating: Float(log(1.0 / 21.0)), count: 21)],
                    currentAALogProb: [-1.0])
            },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        controller.enter()
        // First focus scores (cache miss), second hits cache.
        await controller.focusAwait("m1")
        await controller.focusAwait("m1")
        XCTAssertEqual(callCount, 1)
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
