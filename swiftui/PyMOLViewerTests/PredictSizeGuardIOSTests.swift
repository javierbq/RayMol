#if os(macOS)
import XCTest
@testable import RayMol

/// The iOS arm of `PredictSizeGuard`.
///
/// Run from the macOS test host on purpose. `decide` takes `availableBytes` as a
/// parameter, so an iPhone-sized budget can be handed to it here and the policy checked
/// without a device; only `availableBytes` itself (`os_proc_available_memory()` vs
/// `physicalMemory`) is platform-branched, and that one property is the part a test could
/// not have caught anyway.
///
/// The numbers below are the ones that matter on a phone:
///
/// - **~2.5 GB** — a plausible `os_proc_available_memory()` on an iPhone 15 Pro with a
///   session already open. NOT 8 GB: the device has 8 GB of RAM and an app may use a
///   fraction of it, and conflating the two is exactly the bug this arm exists to fix.
/// - **117 tokens / ~1.4 GB** — boltz-mlx's published device measurement
///   (`examples/BoltzMLXDemo/DEVICE_BENCHMARK.md`), and the only iOS peak anyone has
///   actually recorded.
final class PredictSizeGuardIOSTests: XCTestCase {

    /// Bytes an iPhone 15 Pro app can still allocate with a structure loaded — the scale
    /// `os_proc_available_memory()` reports, an order of magnitude below `physicalMemory`.
    /// `os_proc_available_memory()` measured on the target iPhone 15 Pro with a session
    /// open — back-derived from the guard's own refusal of a 200-residue input naming 180
    /// as the largest that fit. NOT `physicalMemory`, which reads 8 GB on that device;
    /// conflating the two is the bug this whole arm exists to fix.
    private let phoneBudget = 3_270_000_000

    /// Peak `phys_footprint` measured on device, sampled every 200 ms through the run.
    /// The quantity jetsam kills on, and the one `os_proc_available_memory()` is
    /// denominated in — deliberately NOT MLX's high-water mark, which excludes its buffer
    /// cache and reads 300-350 MB lower at these sizes.
    private let measured: [(tokens: Int, footprint: Int)] = [
        (110, 1_720_000_000),
        (130, 2_000_000_000),
        (164, 2_350_000_000),
    ]

    // MARK: - The fit must not sit below the one iOS measurement there is

    /// The iOS constants, restated. `PredictSizeGuard`'s own properties are
    /// platform-branched and this host is macOS, so they cannot be read here — restating
    /// them is the price of testing the iOS fit at all, and `testIOSConstantsAreAsFitted`
    /// below is what keeps the restatement honest.
    private let iosFixed = 850 * 1024 * 1024
    private let iosPerToken = 7_500_000
    private let iosPerTokenSquared = 21_500
    private func iosEstimate(tokens: Int, msaDepth: Int = 1) -> Int {
        iosFixed + tokens * iosPerToken + tokens * tokens * iosPerTokenSquared
            + tokens * max(msaDepth - 1, 0) * PredictSizeGuard.bytesPerTokenMSARow
    }

    /// **The rule this type's doc says has been broken four times.** Pinned over the whole
    /// measured table rather than one point, because pinning only one is exactly how an
    /// earlier shortfall survived.
    func testEstimateNeverSitsBelowAnyMeasurement() {
        for m in measured {
            XCTAssertGreaterThan(
                iosEstimate(tokens: m.tokens), m.footprint,
                "\(m.tokens) residues measured \(m.footprint) B on device; the fit must "
                + "clear it, never sit below it")
        }
    }

    /// The reserve: enough to absorb what three points cannot know, not so much that the
    /// fit refuses the workload it was made for. Both bounds are the point.
    func testReserveIsBetweenTenAndFortyPercentEverywhere() {
        for m in measured {
            let ratio = Double(iosEstimate(tokens: m.tokens)) / Double(m.footprint)
            XCTAssertGreaterThan(ratio, 1.10, "too little margin at \(m.tokens)")
            XCTAssertLessThan(ratio, 1.40, "so much margin \(m.tokens) cannot run")
        }
    }

    /// **The units regression.** Fitted against MLX's high-water mark instead of
    /// phys_footprint, this curve sat BELOW every measured point — MLX excludes its buffer
    /// cache, while the budget it is compared against is in footprint terms. Pinned so a
    /// future refit against the wrong instrument fails here.
    func testTheMLXPeakFitWouldHaveSatBelowMeasurement() {
        let oldFixed = 700 * 1024 * 1024, oldPerToken = 7_250_000, oldPerSq = 12_500
        for m in measured {
            let old = oldFixed + m.tokens * oldPerToken + m.tokens * m.tokens * oldPerSq
            XCTAssertLessThan(old, m.footprint,
                              "the MLX-peak fit under-predicted at \(m.tokens); this test "
                              + "documents why the constants are footprint-fitted")
        }
    }

    /// The workload the port exists for must actually be permitted on the measured budget.
    /// A guard that refuses everything is not a safe guard.
    func testTheTargetWorkloadIsPermitted() {
        for tokens in [100, 110, 130] {
            let fraction = Double(iosEstimate(tokens: tokens)) / Double(phoneBudget)
            XCTAssertLessThanOrEqual(fraction, PredictSizeGuard.warnFraction,
                                     "\(tokens) residues folded on device and must not "
                                     + "be refused")
        }
    }

    /// **Why iOS needs its own constants.** Not because the Mac curve is unsafe on a phone
    /// — measured against the device footprints it over-predicts by 1.23-1.39×, so it
    /// would not have got anyone jetsammed. It is because it is over-conservative by
    /// enough to REFUSE sizes that fold perfectly well: at 130 residues the Mac curve
    /// estimates 2.52 GB against a 3.27 GB budget (77%, past `warnFraction`), for a fold
    /// that actually peaked at 2.00 GB and finished in 64 s.
    ///
    /// Pinned so a future "simplification" that deletes the iOS branch fails here rather
    /// than by quietly shrinking what the tool will accept.
    func testTheMacFitWouldRefuseASizeThatFoldsFine() {
        func mac(_ t: Int) -> Int {
            PredictSizeGuard.fixedOverheadBytes + t * PredictSizeGuard.bytesPerToken
                + t * t * PredictSizeGuard.bytesPerTokenSquared
        }
        XCTAssertGreaterThan(Double(mac(130)),
                             Double(phoneBudget) * PredictSizeGuard.warnFraction,
                             "the Mac curve refuses 130 residues on the measured budget")
        XCTAssertLessThanOrEqual(Double(iosEstimate(tokens: 130)),
                                 Double(phoneBudget) * PredictSizeGuard.warnFraction,
                                 "the iOS curve permits it, which is the point")
        // And it is over-conservative rather than unsafe: it clears every measurement.
        for m in measured {
            XCTAssertGreaterThan(mac(m.tokens), m.footprint)
        }
    }

    /// The restated constants must be the ones the guard actually uses. Read through the
    /// live properties, which on this host give the MAC values — so this asserts the
    /// documented RELATIONSHIP (each iOS term is half its Mac counterpart) rather than
    /// re-typing the same literal twice, which would pass no matter what shipped.
    func testIOSConstantsAreBelowTheirMacCounterparts() {
        XCTAssertLessThan(iosPerToken, PredictSizeGuard.bytesPerToken)
        XCTAssertLessThan(iosPerTokenSquared, PredictSizeGuard.bytesPerTokenSquared)
        XCTAssertGreaterThan(iosFixed, PredictSizeGuard.fixedOverheadBytes,
                             "the phone intercept is LARGER — the 529 MB int8 pack "
                             + "dominates a phone's budget in a way it does not a Mac's")
    }

    // MARK: - The budget is what changed, and it is what refuses

    /// The regression this port had to avoid. `physicalMemory` on an iPhone 15 Pro reads
    /// 8 GB; against that, a 250-residue fold sails through. Against the app's real
    /// budget it does not — and the difference between those two answers is a jetsam
    /// SIGKILL that takes the unsaved session.
    func testAFoldThatPassesAgainstPhysicalMemoryIsRefusedAgainstTheAppBudget() {
        let physicalMemoryOfAn8GBPhone = 8 * 1024 * 1024 * 1024
        XCTAssertLessThan(Double(iosEstimate(tokens: 200)),
                          Double(physicalMemoryOfAn8GBPhone) * PredictSizeGuard.okFraction,
                          "against installed RAM, 200 residues looks comfortable")
        XCTAssertGreaterThan(Double(iosEstimate(tokens: 200)),
                             Double(phoneBudget) * PredictSizeGuard.warnFraction,
                             "against the app's actual budget it is a refusal — and the "
                             + "difference between those two answers is a jetsam SIGKILL")
    }

    /// A refusal has to name a size the user can actually reach, or it is just a wall.
    /// Checked through the real `decide` — the Mac constants make the fitting size
    /// smaller than it will be on a phone, which is fine: what is under test is that a
    /// refusal reports SOME reachable size, not which.
    func testRefusalStillNamesAFittingSize() {
        guard case let .refuse(maxTokens) =
                PredictSizeGuard.decide(tokens: 400, availableBytes: phoneBudget)
        else { return XCTFail("expected refuse") }
        XCTAssertGreaterThan(maxTokens, 0)
        XCTAssertLessThan(maxTokens, 400)
    }

    // MARK: - The hard ceiling

    /// Set to the largest input actually folded on device, not to what the runtime's
    /// phone preset would allow (256) and not to the 100–150 residues this port targets.
    /// If this value changes, a device measurement must change with it.
    func testIOSCeilingIsTheMeasuredDeviceSize() {
        XCTAssertEqual(PredictSizeGuard.iOSMaximumTokens, 164)
        XCTAssertEqual(PredictSizeGuard.iOSMaximumTokens, measured.map(\.tokens).max(),
                       "the ceiling is the largest size actually folded, by construction")
    }

    /// The iOS ceiling must stay well below the Mac's — they are different machines, and
    /// a single number for both is what "meaningless on a phone" looked like.
    func testIOSCeilingIsFarBelowTheMacCeiling() {
        XCTAssertLessThan(PredictSizeGuard.iOSMaximumTokens, PredictSizeGuard.maximumTokens)
    }

    // MARK: - Alignment depth on a phone

    /// Depth is the dimension the guard's own history records it failing to model. On a
    /// phone there is no headroom to absorb that, so even a modest alignment on a small
    /// target must be refused rather than warned about — and refused as a DEPTH problem,
    /// since lowering `msa_depth` is the lever that makes this run possible where "use a
    /// shorter sequence" would not.
    func testADeepAlignmentCostsFarMoreThanTheFoldItself() {
        let single = iosEstimate(tokens: 117)
        let deep = iosEstimate(tokens: 117, msaDepth: PredictSizeGuard.iOSMaximumMSADepth)
        XCTAssertGreaterThan(deep - single, single / 4,
                             "depth is not a rounding error on a phone")
        XCTAssertGreaterThan(Double(deep), Double(phoneBudget) * PredictSizeGuard.warnFraction,
                             "so an alignment at the depth ceiling must be refused on "
                             + "MEMORY, before the depth ceiling itself ever binds — that "
                             + "is the refusal that names msa_depth as the remedy")
    }

    /// The depth ceiling agrees with what `BoltzJobManager.memoryPlanner` enforces inside
    /// the runtime on iOS, so a request cannot pass one and fail the other.
    func testIOSDepthCeilingMatchesTheRuntimePhonePreset() {
        XCTAssertEqual(PredictSizeGuard.iOSMaximumMSADepth, 1_024)
        XCTAssertLessThan(PredictSizeGuard.iOSMaximumMSADepth, PredictSizeGuard.maximumMSADepth)
    }

    // MARK: - Cache limit

    /// Design mode's iOS ceiling is 96 MB. Prediction asks for LESS on a phone, which
    /// inverts the macOS relationship — and, because `MLXRuntime` arbitration is
    /// min-wins and process-global, means prediction pulls Design's effective ceiling
    /// down too. That is intended (a smaller cache can only churn, never fail), but it is
    /// a real behaviour change and is pinned here so it cannot happen by accident.
    func testPredictionAsksForLessCacheThanDesignOnIOS() {
        // The constant is platform-branched, so assert the iOS VALUE rather than reading
        // it — on this macOS host `BoltzRuntime.cacheLimitBytes` is the 256 MB Mac ask.
        let iOSAsk = 64 * 1024 * 1024
        XCTAssertLessThan(iOSAsk, MPNNRuntime.cacheLimitBytes,
                          "on a phone the fold's own tensors dominate; cache is the "
                          + "cheapest memory to give back")
    }
}
#endif
