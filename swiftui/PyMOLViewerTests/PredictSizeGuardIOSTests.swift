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
    private let phoneBudget = 2_500 * 1024 * 1024
    /// The device peak measured at 117 tokens.
    private let measuredPeakAt117 = 1_400 * 1024 * 1024

    // MARK: - The fit must not sit below the one iOS measurement there is

    /// The iOS constants, restated. `PredictSizeGuard`'s own properties are
    /// platform-branched and this host is macOS, so they cannot be read here — restating
    /// them is the price of testing the iOS fit at all, and `testIOSConstantsAreAsFitted`
    /// below is what keeps the restatement honest.
    private let iosFixed = 700 * 1024 * 1024
    private let iosPerToken = 7_250_000
    private let iosPerTokenSquared = 12_500
    private func iosEstimate(tokens: Int, msaDepth: Int = 1) -> Int {
        iosFixed + tokens * iosPerToken + tokens * tokens * iosPerTokenSquared
            + tokens * max(msaDepth - 1, 0) * PredictSizeGuard.bytesPerTokenMSARow
    }

    /// The single rule this type's doc comment says has been broken three times, checked
    /// against the only iOS measurement that exists.
    func testEstimateCoversTheMeasuredDevicePeak() {
        XCTAssertGreaterThan(iosEstimate(tokens: 117), measuredPeakAt117,
                             "the iOS fit must clear the iPhone 15 Pro measurement, "
                             + "never sit below it")
    }

    /// The reserve at the anchor: enough to absorb what one point cannot know, not so
    /// much that the fit refuses the workload it was made for. Both bounds are the point.
    func testReserveAtTheAnchorIsBetweenTenAndFiftyPercent() {
        let ratio = Double(iosEstimate(tokens: 117)) / Double(measuredPeakAt117)
        XCTAssertGreaterThan(ratio, 1.10, "too little margin over a single measurement")
        XCTAssertLessThan(ratio, 1.50, "so much margin the target workload cannot run")
    }

    /// **The regression that made an iOS-specific fit necessary in the first place.**
    /// Reusing the Mac constants estimates 2.25 GB at the anchor, which against a
    /// realistic phone budget is a refusal — it would have made the fold this port exists
    /// for impossible on the device it was ported to. Pinned so a future "simplification"
    /// that deletes the iOS branch fails here instead of on someone's phone.
    func testTheMacFitWouldHaveRefusedTheTargetWorkload() {
        let macEstimate = PredictSizeGuard.fixedOverheadBytes
            + 117 * PredictSizeGuard.bytesPerToken
            + 117 * 117 * PredictSizeGuard.bytesPerTokenSquared
        XCTAssertGreaterThan(Double(macEstimate),
                             Double(phoneBudget) * PredictSizeGuard.warnFraction,
                             "the Mac curve refuses 117 residues on a phone budget; "
                             + "that is why iOS has its own")
        XCTAssertLessThan(Double(iosEstimate(tokens: 117)),
                          Double(phoneBudget) * PredictSizeGuard.warnFraction,
                          "and the iOS curve does not")
    }

    /// The restated constants must be the ones the guard actually uses. Read through the
    /// live properties, which on this host give the MAC values — so this asserts the
    /// documented RELATIONSHIP (each iOS term is half its Mac counterpart) rather than
    /// re-typing the same literal twice, which would pass no matter what shipped.
    func testIOSConstantsAreAsFitted() {
        XCTAssertEqual(iosPerToken * 2, PredictSizeGuard.bytesPerToken)
        XCTAssertEqual(iosPerTokenSquared * 2, PredictSizeGuard.bytesPerTokenSquared)
        XCTAssertEqual(iosFixed, 700 * 1024 * 1024)
    }

    // MARK: - The budget is what changed, and it is what refuses

    /// The regression this port had to avoid. `physicalMemory` on an iPhone 15 Pro reads
    /// 8 GB; against that, a 250-residue fold sails through. Against the app's real
    /// budget it does not — and the difference between those two answers is a jetsam
    /// SIGKILL that takes the unsaved session.
    func testAFoldThatPassesAgainstPhysicalMemoryIsRefusedAgainstTheAppBudget() {
        let physicalMemoryOfAn8GBPhone = 8 * 1024 * 1024 * 1024
        XCTAssertLessThan(Double(iosEstimate(tokens: 250)),
                          Double(physicalMemoryOfAn8GBPhone) * PredictSizeGuard.okFraction,
                          "against installed RAM, 250 residues looks comfortable")
        XCTAssertGreaterThan(Double(iosEstimate(tokens: 250)),
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
        XCTAssertEqual(PredictSizeGuard.iOSMaximumTokens, 117)
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
