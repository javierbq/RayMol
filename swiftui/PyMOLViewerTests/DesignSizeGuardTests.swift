#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignSizeGuardTests: XCTestCase {

    // 4 GiB of remaining budget. With fixedOverhead 160 MiB (167_772_160 B) and
    // 1.4 MB/residue, the ok ceiling is 2_147_483_648 and the refuse floor is
    // 3_221_225_472. Every expectation below is arithmetic on those two numbers.
    private let fourGiB = 4_294_967_296

    func testComfortableSizeIsOK() {
        // 1000 residues -> 1_567_772_160 B, well under 50% of 4 GiB.
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1000, availableBytes: fourGiB), .ok)
    }

    func testJustUnderOkCeilingIsStillOK() {
        // 1400 residues -> 2_127_772_160 B <= 2_147_483_648 B.
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1400, availableBytes: fourGiB), .ok)
    }

    func testMidBandWarns() {
        // 1500 residues -> 2_267_772_160 B: over 50%, under 75%.
        XCTAssertEqual(
            DesignSizeGuard.evaluate(residueCount: 1500, availableBytes: fourGiB),
            .warn(estimatedBytes: 2_267_772_160, availableBytes: fourGiB))
    }

    func testOversizeRefusesAndReportsWhatWouldFit() {
        // 2300 residues -> 3_387_772_160 B, past the 3_221_225_472 B refuse floor.
        // ceiling = 4_294_967_296 * 0.75 - 167_772_160 = 3_053_453_312
        // maxFit  = floor(3_053_453_312 / 1_400_000) = floor(2181.038) = 2181
        XCTAssertEqual(
            DesignSizeGuard.evaluate(residueCount: 2300, availableBytes: fourGiB),
            .refuse(maxFittingResidues: 2181))
    }

    func testMaxFittingIsTheBoundaryItClaims() {
        let maxFit = DesignSizeGuard.maxFittingResidues(availableBytes: fourGiB)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: maxFit, availableBytes: fourGiB),
                       .warn(estimatedBytes: DesignSizeGuard.estimatedBytes(residueCount: maxFit),
                             availableBytes: fourGiB),
                       "the largest 'fitting' size must not itself be refused")
        if case .refuse = DesignSizeGuard.evaluate(residueCount: maxFit + 1, availableBytes: fourGiB) {
            // expected
        } else {
            XCTFail("one residue past maxFittingResidues must refuse")
        }
    }

    // A budget smaller than the model's own footprint cannot fit anything.
    func testTinyBudgetRefusesWithZero() {
        XCTAssertEqual(DesignSizeGuard.maxFittingResidues(availableBytes: 100_000_000), 0)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 1, availableBytes: 100_000_000),
                       .refuse(maxFittingResidues: 0))
    }

    // availableBytes <= 0 means "unknown budget" (macOS, where swap makes the
    // question meaningless). Shipped macOS behaviour must not change.
    func testUnknownBudgetAlwaysOK() {
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 100_000, availableBytes: 0), .ok)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 100_000, availableBytes: -1), .ok)
    }

    func testZeroResiduesIsOK() {
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 0, availableBytes: fourGiB), .ok)
    }

    // Guards the derivation: the constants must still match the measured slope.
    func testEstimateMatchesMeasuredModel() {
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 0), 167_772_160)
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 1000), 1_567_772_160)
    }
}
#endif
