#if os(macOS)
import XCTest
@testable import RayMol

/// boltz-mlx's own preflight cannot be trusted: its activation estimate under-predicts
/// measured peaks by 10–25× (115 tokens estimates ~60 MB against a measured 1.43 GB;
/// 384 tokens estimates ~622 MB against 6.84 GB). This guard is fitted to the measured
/// curve instead, and stays PREVENTIVE because jetsam is an uncatchable SIGKILL that on
/// macOS costs the user their unsaved session.
final class PredictSizeGuardTests: XCTestCase {

    private let gib = 1024 * 1024 * 1024

    func testSmallProteinOnALargeMachineIsOK() {
        XCTAssertEqual(PredictSizeGuard.decide(tokens: 117, availableBytes: 32 * gib), .ok)
    }

    func testLargeProteinOnASmallMachineIsRefused() {
        guard case .refuse = PredictSizeGuard.decide(tokens: 900, availableBytes: 4 * gib)
        else { return XCTFail("expected refuse") }
    }

    /// RayMol's own measured MLX peak memory, M3 Pro / 36 GiB, Release, recycling 3 /
    /// 200 steps, single chain, no MSA. GB here is 10^9, matching how MLX reports.
    private static let measured: [(tokens: Int, peakGB: Double)] = [
        (60, 0.78), (100, 1.76), (150, 2.90), (200, 3.48), (250, 3.85), (300, 4.64),
        (350, 5.96), (400, 7.38), (450, 7.90), (550, 10.86), (600, 13.11),
    ]

    /// The fit must never sit BELOW measurement, or the guard licenses a run that dies.
    ///
    /// This pins the WHOLE sweep, not a couple of points. An earlier version asserted only
    /// 117 and 225 tokens and was therefore green while the estimate ran 27% optimistic at
    /// 600 residues.
    func testEstimateNeverSitsBelowMeasurement() {
        for point in Self.measured {
            let estimate = PredictSizeGuard.estimatedBytes(tokens: point.tokens)
            XCTAssertGreaterThanOrEqual(
                Double(estimate), point.peakGB * 1e9,
                "estimate is optimistic at \(point.tokens) residues: "
                + "\(Double(estimate) / 1e9) GB vs measured \(point.peakGB) GB")
        }
    }

    /// ...but not so conservative that it refuses work that would comfortably fit. Keeps
    /// the fit honest in both directions rather than passing by inflating the intercept.
    func testEstimateStaysWithinTwiceMeasurement() {
        for point in Self.measured where point.tokens >= 100 {
            let estimate = Double(PredictSizeGuard.estimatedBytes(tokens: point.tokens))
            XCTAssertLessThan(
                estimate, 2.0 * point.peakGB * 1e9,
                "estimate is wildly conservative at \(point.tokens) residues")
        }
    }

    /// A 600-residue run really does need ~13 GB, so it must NOT be refused on a 36 GiB
    /// machine — that is the largest size actually measured end to end.
    func testLargestMeasuredSizeIsAllowedOn36GiB() {
        let decision = PredictSizeGuard.decide(tokens: 600, availableBytes: 36 * gib)
        XCTAssertNotEqual(decision, .refuse(maxFittingTokens: 0))
        if case .refuse = decision { XCTFail("600 residues must fit on a 36 GiB Mac") }
    }

    func testEstimateIsSuperLinearInTokens() {
        let a = PredictSizeGuard.estimatedBytes(tokens: 100)
        let b = PredictSizeGuard.estimatedBytes(tokens: 200)
        XCTAssertGreaterThan(b, 2 * a - PredictSizeGuard.fixedOverheadBytes)
    }

    func testRefusalReportsAFittingTokenCount() {
        guard case let .refuse(maxTokens) =
                PredictSizeGuard.decide(tokens: 5000, availableBytes: 8 * gib)
        else { return XCTFail("expected refuse") }
        XCTAssertGreaterThan(maxTokens, 0)
        XCTAssertLessThan(maxTokens, 5000)
    }

    func testHardTokenCeilingBindsEvenWithVastMemory() {
        guard case .refuse = PredictSizeGuard.decide(tokens: PredictSizeGuard.maximumTokens + 1,
                                                    availableBytes: 512 * gib)
        else { return XCTFail("the hard ceiling must bind regardless of memory") }
    }

    func testWarnBandSitsBetweenOkAndRefuse() {
        // Pick a budget that lands 117 tokens in the warn band: estimate/available
        // must fall between okFraction and warnFraction.
        let estimate = PredictSizeGuard.estimatedBytes(tokens: 117)
        let budget = Int(Double(estimate) / 0.6)   // 0.50 < 0.6 <= 0.75
        guard case .warn = PredictSizeGuard.decide(tokens: 117, availableBytes: budget)
        else { return XCTFail("expected warn at 60% of budget") }
    }
}

/// `BoltzRuntime` must register through ``MLXRuntime`` rather than assigning MLX
/// directly, so boltz's `MemoryPlanner.apply()` cannot raise Design mode's 96 MB
/// ceiling by call order.
final class BoltzRuntimeTests: XCTestCase {

    override func tearDown() {
        MLXRuntime.resetCacheLimitRequirementsForTesting()
        MPNNRuntime.configureOnce()
        super.tearDown()
    }

    func testConfigureOnceRegistersThroughMLXRuntime() {
        MLXRuntime.resetCacheLimitRequirementsForTesting()
        BoltzRuntime.configureOnce()
        XCTAssertEqual(MLXRuntime.cacheLimitRequirements[BoltzRuntime.cacheLimitOwner],
                       BoltzRuntime.cacheLimitBytes)
    }

    func testDesignModesLowerCeilingStillWins() {
        MLXRuntime.resetCacheLimitRequirementsForTesting()
        BoltzRuntime.configureOnce()      // larger
        MPNNRuntime.configureOnce()       // 96 MB
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes)
    }

    func testOrderDoesNotMatter() {
        MLXRuntime.resetCacheLimitRequirementsForTesting()
        MPNNRuntime.configureOnce()
        BoltzRuntime.configureOnce()
        XCTAssertEqual(MLXRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes)
    }

    func testBoltzAsksForMoreThanDesignMode() {
        XCTAssertGreaterThan(BoltzRuntime.cacheLimitBytes, MPNNRuntime.cacheLimitBytes,
                             "otherwise the min-wins arbitration is untested by these cases")
    }
}
#endif
