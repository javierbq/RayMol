#if RAYMOL_MPNN
import XCTest
@testable import RayMol

final class DesignSizeGuardTests: XCTestCase {

    // 4 GiB of remaining budget. With fixedOverhead 384 MiB (402_653_184 B) and
    // 1.4 MB/residue, the ok ceiling is 2_147_483_648 and the warn ceiling (the
    // largest non-refusing estimate) is 3_221_225_472. Every expectation below is
    // arithmetic on those two numbers.
    //
    // All arithmetic tests call `decide` rather than `evaluate` so the arithmetic
    // is exercised on the macOS test host; `evaluate` is unconditionally `.ok` on
    // non-iOS by structural design (see testEvaluateIsInertOnCurrentPlatform).
    private let fourGiB = 4_294_967_296

    func testComfortableSizeIsOK() {
        // 1000 residues -> 1_802_653_184 B, well under 50% of 4 GiB.
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 1000, availableBytes: fourGiB), .ok)
    }

    func testWellBelowOkCeilingIsOK() {
        // 1200 residues -> 2_082_653_184 B <= 2_147_483_648 B (ok ceiling).
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 1200, availableBytes: fourGiB), .ok)
    }

    func testOkWarnBoundary() {
        // ok/warn boundary: floor((2_147_483_648 - 402_653_184) / 1_400_000)
        //                 = floor(1_744_830_464 / 1_400_000) = floor(1246.307) = 1246
        // estimatedBytes(1246) = 402_653_184 + 1_744_400_000 = 2_147_053_184 <= 2_147_483_648 -> .ok
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 1246, availableBytes: fourGiB), .ok)
        // estimatedBytes(1247) = 402_653_184 + 1_745_800_000 = 2_148_453_184 > 2_147_483_648 -> .warn
        XCTAssertEqual(
            DesignSizeGuard.decide(residueCount: 1247, availableBytes: fourGiB),
            .warn(estimatedBytes: 2_148_453_184, availableBytes: fourGiB))
    }

    func testMidBandWarns() {
        // 1500 residues -> 2_502_653_184 B: over 50%, under 75%.
        XCTAssertEqual(
            DesignSizeGuard.decide(residueCount: 1500, availableBytes: fourGiB),
            .warn(estimatedBytes: 2_502_653_184, availableBytes: fourGiB))
    }

    func testOversizeRefusesAndReportsWhatWouldFit() {
        // 2300 residues -> 3_622_653_184 B, past the 3_221_225_472 B warn ceiling.
        // ceiling = 4_294_967_296 * 0.75 - 402_653_184 = 2_818_572_288
        // maxFit  = floor(2_818_572_288 / 1_400_000) = floor(2013.266) = 2013
        XCTAssertEqual(
            DesignSizeGuard.decide(residueCount: 2300, availableBytes: fourGiB),
            .refuse(maxFittingResidues: 2013))
    }

    func testMaxFittingIsTheBoundaryItClaims() {
        // warn/refuse boundary: maxFit = 2013
        // estimatedBytes(2013) = 3_220_853_184 <= 3_221_225_472 -> .warn
        // estimatedBytes(2014) = 3_222_253_184 >  3_221_225_472 -> .refuse
        let maxFit = DesignSizeGuard.maxFittingResidues(availableBytes: fourGiB)
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: maxFit, availableBytes: fourGiB),
                       .warn(estimatedBytes: DesignSizeGuard.estimatedBytes(residueCount: maxFit),
                             availableBytes: fourGiB),
                       "the largest 'fitting' size must not itself be refused")
        if case .refuse = DesignSizeGuard.decide(residueCount: maxFit + 1, availableBytes: fourGiB) {
            // expected
        } else {
            XCTFail("one residue past maxFittingResidues must refuse")
        }
    }

    // A budget smaller than the model's own footprint cannot fit anything.
    func testTinyBudgetRefusesWithZero() {
        XCTAssertEqual(DesignSizeGuard.maxFittingResidues(availableBytes: 100_000_000), 0)
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 1, availableBytes: 100_000_000),
                       .refuse(maxFittingResidues: 0))
    }

    // availableBytes <= 0 means "unknown budget" in the pure arithmetic path.
    // `evaluate` is unconditionally .ok on non-iOS by structural design.
    func testUnknownBudgetAlwaysOK() {
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 100_000, availableBytes: 0), .ok)
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 100_000, availableBytes: -1), .ok)
    }

    func testZeroResiduesIsOK() {
        XCTAssertEqual(DesignSizeGuard.decide(residueCount: 0, availableBytes: fourGiB), .ok)
    }

    // Guards the derivation: the constants must still match the measured upper envelope.
    func testEstimateMatchesMeasuredModel() {
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 0), 402_653_184)
        XCTAssertEqual(DesignSizeGuard.estimatedBytes(residueCount: 1000), 1_802_653_184)
    }

    // An absurd input (e.g. garbage from a parse failure) must refuse, not trap.
    func testAbsurdCountRefusesWithoutCrash() {
        let result = DesignSizeGuard.decide(residueCount: Int.max, availableBytes: fourGiB)
        if case .refuse = result {
            // expected — overflow sentinel Int.max exceeds every threshold
        } else {
            XCTFail("absurd residue count must refuse, got \(result)")
        }
    }

    // On non-iOS platforms `evaluate` must return .ok unconditionally regardless of
    // the arguments — the macOS inertness is structural, not a caller convention.
    func testEvaluateIsInertOnCurrentPlatform() {
        #if !os(iOS)
        XCTAssertEqual(DesignSizeGuard.evaluate(residueCount: 100_000, availableBytes: fourGiB), .ok,
                       "evaluate must be unconditionally .ok on non-iOS")
        #endif
    }
}
#endif
