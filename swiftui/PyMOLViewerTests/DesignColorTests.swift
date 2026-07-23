#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

final class DesignColorTests: XCTestCase {
    func testCertaintyPeakedVsFlat() {
        let n = 21
        // Flat distribution -> low certainty (~0); one-hot -> high (~1).
        let flat = [Float](repeating: Float(log(1.0/21.0)), count: n)
        var peak = [Float](repeating: Float(log(1e-6)), count: n); peak[3] = Float(log(1.0 - 20e-6))
        XCTAssertLessThan(DesignColor.certainty(fromLogProbsRow: flat), 0.05)
        XCTAssertGreaterThan(DesignColor.certainty(fromLogProbsRow: peak), 0.95)
    }
    func testScalarSelectsMeaning() {
        let s = DesignScores(nativeFit: [-2.0, nil], certainty: [0.8, nil])
        XCTAssertEqual(DesignColor.scalar(s, .nativeFit), [-2.0, nil])
        XCTAssertEqual(DesignColor.scalar(s, .certainty), [0.8, nil])
    }
    func testScoresFromValidMask() {
        // 3-residue list; only indices 0 and 2 are valid (index 1 is masked out).
        let mask: [Bool] = [true, false, true]
        // 2 valid positions → 2 rows of 21 log-probs (flat distribution).
        let n = 21
        let flatLP = Float(log(1.0 / Float(n)))
        let logProbs: [[Float]] = [
            [Float](repeating: flatLP, count: n),
            [Float](repeating: flatLP, count: n)
        ]
        // One native-fit log-prob per valid position.
        let currentAALogProb: [Float] = [-1.5, -0.5]
        let result = MPNNModel.ScoreResult(logProbs: logProbs, currentAALogProb: currentAALogProb)
        let scores = DesignColor.scores(from: result, validMask: mask)
        // Valid positions should produce non-nil values.
        XCTAssertNotNil(scores.nativeFit[0], "nativeFit[0] should be non-nil")
        XCTAssertNotNil(scores.certainty[0], "certainty[0] should be non-nil")
        XCTAssertNotNil(scores.nativeFit[2], "nativeFit[2] should be non-nil")
        XCTAssertNotNil(scores.certainty[2], "certainty[2] should be non-nil")
        // Masked position (index 1) must be nil.
        XCTAssertNil(scores.nativeFit[1], "nativeFit[1] should be nil (masked)")
        XCTAssertNil(scores.certainty[1], "certainty[1] should be nil (masked)")
        // nativeFit values should match currentAALogProb in j-counter order.
        XCTAssertEqual(scores.nativeFit[0], currentAALogProb[0])
        XCTAssertEqual(scores.nativeFit[2], currentAALogProb[1])
        // Certainty must be in [0,1] at valid positions.
        if let c0 = scores.certainty[0] { XCTAssertTrue(c0 >= 0 && c0 <= 1, "certainty[0] out of range: \(c0)") }
        if let c2 = scores.certainty[2] { XCTAssertTrue(c2 >= 0 && c2 <= 1, "certainty[2] out of range: \(c2)") }
    }

    /// Propensity row: 20 entries, sums to ~1.0, argmax matches the highest logit.
    func testPropensitySoftmax() throws {
        let n = 21
        // Place a high logit at index 2 (D in MPNN alphabet); all others low.
        var logits = [Float](repeating: -5.0, count: n)
        logits[2] = 0.0
        let result = MPNNModel.ScoreResult(logProbs: [logits], currentAALogProb: [-1.0])
        let scores = DesignColor.scores(from: result, validMask: [true])
        guard let props = scores.propensities[0] else {
            XCTFail("propensities[0] should not be nil for a valid residue"); return
        }
        XCTAssertEqual(props.count, 20, "propensity row must have exactly 20 entries")
        let sum = props.reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-4, "propensities must sum to 1.0")
        let argmax = props.indices.max(by: { props[$0] < props[$1] }) ?? -1
        XCTAssertEqual(argmax, 2, "argmax should match the highest-logit AA index (D=2 in MPNN alphabet)")
    }

    /// propensityRow: masked positions remain nil; valid positions produce 20-entry arrays.
    func testPropensitiesNilAtMaskedPositions() {
        let mask: [Bool] = [true, false, true]
        let n = 21
        let logProbs: [[Float]] = [
            [Float](repeating: -5.0, count: n),
            [Float](repeating: -5.0, count: n)
        ]
        let result = MPNNModel.ScoreResult(logProbs: logProbs, currentAALogProb: nil)
        let scores = DesignColor.scores(from: result, validMask: mask)
        XCTAssertNotNil(scores.propensities[0], "valid position must have propensities")
        XCTAssertNil(scores.propensities[1],    "masked position must be nil")
        XCTAssertNotNil(scores.propensities[2], "valid position must have propensities")
        XCTAssertEqual(scores.propensities[0]?.count, 20)
        XCTAssertEqual(scores.propensities[2]?.count, 20)
    }
}
#endif
