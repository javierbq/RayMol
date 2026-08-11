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

    /// The fit must never sit BELOW measurement, or the guard licenses a run that dies.
    func testEstimateTracksTheMeasuredCurve() {
        XCTAssertGreaterThanOrEqual(PredictSizeGuard.estimatedBytes(tokens: 117),
                                    Int(2.24 * Double(gib)))
        XCTAssertGreaterThanOrEqual(PredictSizeGuard.estimatedBytes(tokens: 225),
                                    Int(3.47 * Double(gib)))
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
