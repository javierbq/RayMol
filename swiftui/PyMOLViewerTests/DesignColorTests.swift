#if RAYMOL_MPNN
import XCTest
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
}
#endif
