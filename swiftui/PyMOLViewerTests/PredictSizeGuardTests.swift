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

    /// RayMol's own measured MLX peak memory over a (tokens × MSA depth) grid, M3 Pro /
    /// 36 GiB, recycling 3 / 200 steps, single chain — produced by
    /// `PredictMSAMemorySweepTests`, which is in the repo so this table can be
    /// reproduced rather than believed.
    ///
    /// Two things in here are worth reading before touching the fit:
    ///
    /// - **Depth is free until suddenly it is not.** 250 residues measures 3.88 GB at
    ///   every depth from 1 to 1024 and then 7.13 GB at 4096. While the MSA tensors fit
    ///   inside buffers MLX is recycling for the pairwise trunk anyway, they cost
    ///   nothing; past that they cost everything. No shape derived from the tensor
    ///   dimensions predicts that knee, which is why the term is fitted to these numbers
    ///   and not to an argument about tensor sizes.
    /// - **It is the shallow column that ties this table to the one below.** 250 / depth
    ///   1 measures 3.88 GB here against 3.85 GB in the no-MSA sweep; 384 / depth 1
    ///   measures 6.80 between that table's 5.96 at 350 and 7.38 at 400; 115 / depth 64
    ///   measures 2.19 between its 1.76 at 100 and 2.90 at 150. Two harnesses, months
    ///   apart, agreeing — which is what makes this table evidence rather than output.
    private static let measuredWithMSA: [(tokens: Int, depth: Int, peakGB: Double)] = [
        (115, 64, 2.19), (115, 256, 2.27), (115, 1024, 2.37), (115, 4096, 3.97),
        (115, 16384, 7.90),
        (250, 1, 3.88), (250, 64, 3.88), (250, 256, 3.88), (250, 1024, 3.88),
        (250, 4096, 7.13), (250, 16384, 14.44),
        (384, 1, 6.80), (384, 64, 6.80), (384, 256, 6.80), (384, 1024, 6.81),
        (384, 4096, 8.01), (384, 16384, 22.00),
    ]

    /// RayMol's own measured MLX peak memory, M3 Pro / 36 GiB, Release, recycling 3 /
    /// 200 steps, single chain, no MSA. GB here is 10^9, matching how MLX reports.
    private static let measured: [(tokens: Int, peakGB: Double)] = [
        (60, 0.78), (100, 1.76), (150, 2.90), (200, 3.48), (250, 3.85), (300, 4.64),
        (350, 5.96), (400, 7.38), (450, 7.90), (550, 10.86), (600, 13.11), (650, 15.32),
        (700, 18.43), (750, 21.53), (800, 24.93), (850, 28.65), (900, 32.71),
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

    /// The same rule for the depth dimension, and the reason `bytesPerTokenMSARow`
    /// exists: without it the estimate at 115 residues / depth 16,384 is 2.20 GB against
    /// a measured 7.90 — optimistic by 3.6×, which is what licenses a run that then gets
    /// jetsam-killed and takes the user's unsaved session with it.
    func testEstimateNeverSitsBelowMeasurementWithAnAlignment() {
        for point in Self.measuredWithMSA {
            let estimate = PredictSizeGuard.estimatedBytes(tokens: point.tokens,
                                                           msaDepth: point.depth)
            XCTAssertGreaterThanOrEqual(
                Double(estimate), point.peakGB * 1e9,
                "estimate is optimistic at \(point.tokens) residues / depth "
                + "\(point.depth): \(Double(estimate) / 1e9) GB vs measured "
                + "\(point.peakGB) GB")
        }
    }

    /// The other direction, at a looser bound than the no-MSA table's 2.0× — and the
    /// reason is worth stating, because relaxing a bound to make a fit pass is exactly
    /// the move this file exists to prevent.
    ///
    /// The excess is INHERITED, not introduced. At 384 residues the token-only estimate
    /// is already 9.45 GB against a measured 6.80 — it overshoots before any alignment
    /// is involved — so every MSA cell in that row starts 1.39× conservative and the
    /// depth term compounds it to 2.06× at depth 4096. At 115 residues, where the base
    /// has no cushion at all (2.20 estimated, 2.19 measured), the depth term is what
    /// carries the whole margin and is the tightest anywhere: the coefficient is set by
    /// that cell. Tightening it to satisfy 2.0× here would spend the margin where there
    /// is none to spare in order to look better where there is plenty.
    func testEstimateWithAnAlignmentStaysWithinReasonableConservatism() {
        for point in Self.measuredWithMSA {
            let estimate = Double(PredictSizeGuard.estimatedBytes(tokens: point.tokens,
                                                                  msaDepth: point.depth))
            XCTAssertLessThan(
                estimate, 2.2 * point.peakGB * 1e9,
                "estimate is wildly conservative at \(point.tokens) residues / depth "
                + "\(point.depth)")
        }
    }

    /// The tightest cell in the grid, pinned by name. 115 residues / depth 4096 needs
    /// 3,763 bytes per row·token and gets `bytesPerTokenMSARow`; if a future retune
    /// drops that constant to the measurement, this is the point that goes optimistic
    /// first, and it does so where the token-only term has no cushion to absorb it.
    func testTheCoefficientKeepsMarginOnTheTightestCell() {
        let tokens = 115, depth = 4096, measuredGB = 3.97
        let required = (measuredGB * 1e9
            - Double(PredictSizeGuard.estimatedBytes(tokens: tokens)))
            / Double(tokens * (depth - 1))
        XCTAssertGreaterThan(Double(PredictSizeGuard.bytesPerTokenMSARow),
                             required * 1.15,
                             "less than 15% margin on the cell that binds the fit")
    }

    /// Depth 1 must reduce EXACTLY to the token-only formula, or the 17-point no-MSA
    /// table below stops being evidence for this function. Those runs did have an
    /// alignment — upstream's depth-1 dummy — so depth 1 is their true zero.
    func testDepthOneIsExactlyTheTokenOnlyEstimate() {
        for tokens in [60, 115, 250, 600, 900] {
            XCTAssertEqual(PredictSizeGuard.estimatedBytes(tokens: tokens, msaDepth: 1),
                           PredictSizeGuard.estimatedBytes(tokens: tokens))
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

    /// A 600-residue run needs ~13 GB and must NOT be refused on a 36 GiB machine.
    func testMidSizeIsAllowedOn36GiB() {
        if case .refuse = PredictSizeGuard.decide(tokens: 600, availableBytes: 36 * gib) {
            XCTFail("600 residues must fit on a 36 GiB Mac")
        }
    }

    /// 900 residues measured 32.71 GB — 85% of a 36 GiB machine's RAM, and it completed only
    /// because swap absorbed the overflow. A PREVENTIVE guard should refuse that: with
    /// anything else open it is a jetsam kill, and the guard compares against TOTAL physical
    /// memory. A deliberate capability reduction, not an oversight.
    func testLargestMeasuredSizeIsRefusedOn36GiBBecauseItNeeds85Percent() {
        guard case .refuse = PredictSizeGuard.decide(tokens: 900, availableBytes: 36 * gib)
        else { return XCTFail("900 residues needs 32.7 GB and must be refused on 36 GiB") }
    }

    /// The ceiling tracks what was MEASURED, not what BoltzInputLimits.desktop allows — the
    /// estimate at 1024 is ~41 GB, beyond any machine this ships on.
    func testCeilingIsTheLargestMeasuredSize() {
        XCTAssertEqual(PredictSizeGuard.maximumTokens, 900)
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

    // MARK: - Alignment depth

    /// A target that fits comfortably on its own can stop fitting once an alignment is
    /// attached. That is the whole point of threading depth through here.
    func testADeepAlignmentCanTurnAnOkRunIntoARefusal() {
        XCTAssertEqual(PredictSizeGuard.decide(tokens: 250, availableBytes: 16 * gib),
                       .ok)
        guard case .refuseDepth = PredictSizeGuard.decide(tokens: 250, msaDepth: 16_384,
                                                          availableBytes: 16 * gib)
        else { return XCTFail("a 16,384-row alignment at 250 residues needs ~22 GB") }
    }

    /// Refused because of the ALIGNMENT, so the advice names the lever that makes this
    /// run possible rather than telling the user to fold a shorter protein.
    func testARefusalOnDepthReportsADepthThatWouldFit() {
        guard case let .refuseDepth(maxDepth) =
                PredictSizeGuard.decide(tokens: 250, msaDepth: 16_384,
                                        availableBytes: 16 * gib)
        else { return XCTFail("expected refuseDepth") }
        XCTAssertGreaterThan(maxDepth, 0)
        XCTAssertLessThan(maxDepth, 16_384)
        // ...and it is a depth that actually fits, not merely a smaller number.
        XCTAssertLessThanOrEqual(
            Double(PredictSizeGuard.estimatedBytes(tokens: 250, msaDepth: maxDepth)),
            Double(16 * gib) * PredictSizeGuard.warnFraction)
    }

    /// When even single-sequence does not fit, the alignment is not the problem and
    /// saying "lower msa_depth" would send the user down a road that does not end.
    func testAnInputTooLargeEvenWithoutAnAlignmentIsRefusedOnTokens() {
        guard case .refuse = PredictSizeGuard.decide(tokens: 900, msaDepth: 16_384,
                                                     availableBytes: 4 * gib)
        else { return XCTFail("expected a token refusal, not a depth one") }
    }

    /// The depth ceiling tracks what was MEASURED, exactly as `maximumTokens` does.
    func testDepthCeilingBindsRegardlessOfMemory() {
        guard case let .refuseDepth(maxDepth) = PredictSizeGuard.decide(
            tokens: 100, msaDepth: PredictSizeGuard.maximumMSADepth + 1,
            availableBytes: 512 * gib)
        else { return XCTFail("the depth ceiling must bind regardless of memory") }
        XCTAssertEqual(maxDepth, PredictSizeGuard.maximumMSADepth)
    }

    /// It is also upstream's `const.max_msa_seqs`, which is what the Python side and
    /// `MSAAlignment.a3m` both cap at. Three places, one number.
    func testTheDepthCeilingIsUpstreamsOwnMaximum() {
        XCTAssertEqual(PredictSizeGuard.maximumMSADepth, 16_384)
    }

    /// A shallow alignment on a machine with room must stay silent — the guard is there
    /// to stop jetsam kills, not to make MSAs feel expensive.
    func testAModestAlignmentOnALargeMachineIsStillOK() {
        XCTAssertEqual(PredictSizeGuard.decide(tokens: 250, msaDepth: 1024,
                                               availableBytes: 36 * gib), .ok)
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
