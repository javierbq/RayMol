#if os(macOS)
import XCTest

@testable import RayMol

/// The second inference runtime: its size guard, its MLX registration, and the routing
/// that gets a `protenix` request to it instead of to Boltz.
///
/// The routing tests matter more than they look. A request whose `runtime` is absent is
/// read as Boltz *deliberately*, so an older Python side keeps working — which means the
/// failure mode for a mis-routed job is not an error but a Protenix sequence folded by
/// Boltz's featurizer and weights, returning a confident wrong structure.
final class ProtenixRuntimeTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func writeRequest(job: String, chains: [(String, String)],
                              runtime: String?) throws -> InferenceJob.Request {
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        var payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": chains.map { ["chain": $0.0, "sequence": $0.1] },
            "recycling_steps": 10,
            "diffusion_steps": 200,
            "seed": 0,
            "out_path": dir.appendingPathComponent("out_\(job).pdb").path,
            "status_path": dir.appendingPathComponent("st_\(job).json").path,
        ]
        if let runtime { payload["runtime"] = runtime }
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return try InferenceJob.parseRequest(at: url)
    }

    // MARK: - settle ordering

    /// The status file must be on disk BEFORE the placeholder is taken down.
    ///
    /// `predicting.discard_pending` re-reads the status FRESH to decide whether to retain a
    /// failure card in `_RECENT` -- and it can, because nothing deletes the status file. So
    /// a discard that lands first records the failure after `_PENDING`, the only map that
    /// could observe it, has already been popped: the card silently vanishes and a refused
    /// or failed run explains nothing.
    ///
    /// The Boltz path has had this test since #291. Protenix did not, and did the two steps
    /// inline in the wrong order at all four of its terminal paths -- #346 moved them onto
    /// `InferenceJob` but preserved the ordering, so extracting the shared shell did not by
    /// itself fix them.
    func testARefusalWritesStatusBeforeDiscardingThePlaceholder() throws {
        var order: [String] = []
        InferenceJob.settleTap = { order.append($0) }
        defer { InferenceJob.settleTap = nil }

        // 100k residues: far past any machine's fitting size, so preflight refuses without
        // touching MLX or reading a weight pack.
        let request = try writeRequest(
            job: "settle-order",
            chains: [("A", String(repeating: "A", count: 100_000))],
            runtime: ProtenixJobManager.runtimeName)
        ProtenixJobManager.shared.submit(request)

        XCTAssertEqual(order, ["write", "discard"],
                       "status must be written before the placeholder is discarded")
        let status = try JSONDecoder().decode(
            InferenceJob.Status.self,
            from: Data(contentsOf: URL(fileURLWithPath: request.statusPath)))
        XCTAssertEqual(status.state, "failed")
        XCTAssertNotNil(status.error)
    }

    /// Every terminal path goes through the ordered helper -- checked STRUCTURALLY, because
    /// three of the four cannot be reached from a unit test.
    ///
    /// `submit`'s refusal is testable (above). The three inside `run` are not: they need a
    /// real 214 MB pack and a real MLX fold to reach. They are also where the ordering
    /// actually bites, and the reason is threading: `discardPlaceholder` hops to the MAIN
    /// queue while the status write is synchronous on the calling thread. From `submit`,
    /// which runs on the main thread, that hop is deferred past the write and the wrong
    /// order is accidentally harmless. From `run`, which is on a background queue, the main
    /// thread can pick the discard up while the write is still in flight.
    ///
    /// So a grep is the honest guard: no direct `discardPlaceholder` call may remain in this
    /// manager. Same discipline as
    /// `predict_api.testEveryMessageHelperUsedByPredictingExists`, which greps its source
    /// rather than trying to take every branch.
    func testNoTerminalPathDiscardsThePlaceholderItself() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // PyMOLViewerTests
            .deletingLastPathComponent()          // swiftui
            .appendingPathComponent("PyMOLViewer/Shared/ProtenixJobManager.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for (number, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            XCTAssertFalse(line.contains("discardPlaceholder"),
                           "ProtenixJobManager.swift:\(number + 1) discards the placeholder "
                           + "directly; route it through InferenceJob.settle so the status "
                           + "is written first: \(trimmed)")
        }
        // And it does still settle -- so the assertion above cannot be satisfied by simply
        // deleting the teardown.
        XCTAssertTrue(text.contains("InferenceJob.settle("),
                      "the manager must settle its jobs through the shared helper")
    }

    // MARK: - Wire format

    func testRequestCarriesItsRuntime() throws {
        let request = try writeRequest(job: "p1", chains: [("A", "ACDEF")],
                                       runtime: "protenix")
        XCTAssertEqual(request.runtime, ProtenixJobManager.runtimeName)
    }

    func testAnAbsentRuntimeStillDecodes() throws {
        // Optional on purpose: a Python side that predates the field must not produce
        // "malformed prediction request", it must fall back to Boltz.
        let request = try writeRequest(job: "p2", chains: [("A", "ACDEF")], runtime: nil)
        XCTAssertNil(request.runtime)
        XCTAssertNil(BoltzJobManager.preflight(request),
                     "an absent runtime means boltz, which must still be accepted")
    }

    func testBoltzRefusesARuntimeNothingImplements() throws {
        let request = try writeRequest(job: "p3", chains: [("A", "ACDEF")],
                                       runtime: "no-such-runtime")
        let status = BoltzJobManager.preflight(request)
        XCTAssertEqual(status?.state, "failed")
        XCTAssertTrue(status?.error?.contains("no-such-runtime") == true,
                      "the refusal must name the runtime, not just decline")
    }

    // MARK: - Size guard

    func testEveryMeasuredPointIsReproducedExactly() {
        // Interpolation must pass through its own data. A guard that smooths its
        // measurements is a fit, and a fit is the thing this type exists to avoid.
        for variant in [ProtenixSizeGuard.Variant.base, .v2] {
            for point in variant.measured where point.tokens <= variant.maximumTokens {
                XCTAssertEqual(
                    ProtenixSizeGuard.estimatedPeakMiB(tokens: point.tokens,
                                                       variant: variant),
                    point.peakMiB, "\(variant) at \(point.tokens) residues")
            }
        }
    }

    func testEstimateRisesWithSize() {
        var last = 0
        for tokens in stride(from: 10, through: 400, by: 10) {
            let estimate = ProtenixSizeGuard.estimatedPeakMiB(tokens: tokens)
            XCTAssertGreaterThanOrEqual(estimate, last, "at \(tokens) residues")
            last = estimate
        }
    }

    func testSmallInputsStillPayForTheWeightPack() {
        // ~500 MiB of the smallest measurement is the pack itself, which a 4-residue
        // peptide pays in full. Scaling linearly to zero would promise a free fold.
        XCTAssertEqual(ProtenixSizeGuard.estimatedPeakMiB(tokens: 4),
                       ProtenixSizeGuard.measured[0].peakMiB)
    }

    func testTheCapIsRefusedEvenOnAHugeMachine() {
        let huge = 512 * 1024 * 1024 * 1024  // 512 GB
        let decision = ProtenixSizeGuard.decide(
            tokens: ProtenixSizeGuard.maximumTokens + 1, variant: .base,
            availableBytes: huge)
        guard case .refuse = decision else {
            return XCTFail("above the cap must refuse regardless of memory, got \(decision)")
        }
    }

    func testTheCapAgreesWithThePythonSide() {
        // Both ends enforce it: Python refuses before the download, this refuses before
        // the tensors. They disagreeing means one of them is decoration.
        XCTAssertEqual(ProtenixSizeGuard.maximumTokens, 700,
                       "keep in step with pymol.predictors.protenix.MAX_RESIDUES")
        XCTAssertEqual(ProtenixSizeGuard.maximumTokensV2, 550,
                       "keep in step with pymol.predictors.protenix.V2_MAX_RESIDUES")
    }

    func testTheCapIsTheLargestMeasuredPointAndNotBeyondIt() {
        // The one invariant that survives raising the cap: it may reach the data and no
        // further. PredictSizeGuard's docstring records three occasions where a fit past
        // its measurements ran optimistic.
        for variant in [ProtenixSizeGuard.Variant.base, .v2] {
            let largest = variant.measured.map(\.tokens).max() ?? 0
            XCTAssertLessThanOrEqual(variant.maximumTokens, largest, "\(variant)")
        }
    }

    func testTheBudgetIsWhatBoundsAFoldOnALargeMachine() {
        // 32 GB by request. A machine with more RAM than that is still held to it.
        let huge = 512 * 1024 * 1024 * 1024
        let decision = ProtenixSizeGuard.decide(tokens: 700, variant: .base,
                                                availableBytes: huge)
        XCTAssertEqual(decision, .ok, "8.6 GB against a 32 GB budget is comfortable")
        XCTAssertEqual(ProtenixSizeGuard.budgetBytes, 32 * 1024 * 1024 * 1024)
    }

    func testASmallMachineIsStillProtectedByItsOwnMemory() {
        // The budget is a ceiling, not a promise: an 8 GB Mac is sized against 8 GB.
        let decision = ProtenixSizeGuard.decide(tokens: 700,
                                                variant: .base,
                                                availableBytes: 8 * 1024 * 1024 * 1024)
        guard case .refuse = decision else {
            return XCTFail("8.6 GB cannot fit in 8 GB, got \(decision)")
        }
    }

    func testTheLengthThatPromptedThisFits() {
        // 532 residues, the input that hit the old 400 cap. Interpolates to ~6 GB, which
        // is measured territory: 550 was swept at 6303 MiB.
        XCTAssertEqual(ProtenixSizeGuard.decide(tokens: 532,
                                                variant: .base,
                                                availableBytes: 32 * 1024 * 1024 * 1024),
                       .ok)
    }

    func testAModestFoldIsAccepted() {
        let decision = ProtenixSizeGuard.decide(tokens: 60,
                                                variant: .base,
                                                availableBytes: 36 * 1024 * 1024 * 1024)
        XCTAssertEqual(decision, .ok)
    }

    func testATinyMachineRefusesAndSaysWhatWouldFit() {
        let decision = ProtenixSizeGuard.decide(tokens: 400,
                                                variant: .base,
                                                availableBytes: 2 * 1024 * 1024 * 1024)
        guard case .refuse(let fitting) = decision else {
            return XCTFail("2 GB cannot hold a 400-residue fold, got \(decision)")
        }
        XCTAssertLessThan(fitting, 400)
    }

    func testV2IsSizedAboveBaseAtEveryMeasuredLength() {
        // The whole reason the two cannot share a table. v2's 256-wide pair track roughly
        // doubles the N^2 term, so base's curve is optimistic for v2 -- and optimistic is
        // the direction that gets a session jetsam-killed rather than a request refused.
        for point in ProtenixSizeGuard.Variant.v2.measured
        where point.tokens <= ProtenixSizeGuard.maximumTokens {
            XCTAssertGreaterThan(
                ProtenixSizeGuard.estimatedPeakMiB(tokens: point.tokens, variant: .v2),
                ProtenixSizeGuard.estimatedPeakMiB(tokens: point.tokens, variant: .base),
                "at \(point.tokens) residues")
        }
    }

    func testAV2WeightsPathSelectsV2sCurve() {
        // How the runtime knows which curve to use: nothing else in the request names
        // the pack.
        let directory = "/Users/x/Library/Application Support/RayMol/weights/"
        XCTAssertEqual(
            ProtenixSizeGuard.Variant(weightsDirectory: directory + "protenix-v2-mlx-int8/v1"),
            .v2)
        XCTAssertEqual(
            ProtenixSizeGuard.Variant(weightsDirectory: directory + "protenix-base-mlx-int8/v1"),
            .base)
    }

    func testAnUnrecognisedWeightsPathTakesTheExpensiveCurve() {
        // "I do not know what this is" must refuse sooner, not later. Defaulting to base
        // would let a typo in a bundle id license a fold against a smaller model's
        // numbers.
        XCTAssertEqual(ProtenixSizeGuard.Variant(weightsDirectory: "/nowhere"), .v2)
    }

    func testEachVariantRefusesAtItsOwnCap() {
        // Per pack, not per method -- and asserted without assuming which cap is lower.
        // v2's was 250 against base's 700 while v2 was unswept, and the two now agree;
        // what must hold either way is that each refuses at its own.
        let huge = 512 * 1024 * 1024 * 1024
        for variant in [ProtenixSizeGuard.Variant.base, .v2] {
            XCTAssertNotEqual(
                ProtenixSizeGuard.decide(tokens: variant.maximumTokens, variant: variant,
                                         availableBytes: huge),
                ProtenixSizeGuard.decide(tokens: variant.maximumTokens + 1,
                                         variant: variant, availableBytes: huge),
                "\(variant) must treat its cap and one past it differently")
            guard case .refuse = ProtenixSizeGuard.decide(
                tokens: variant.maximumTokens + 1, variant: variant,
                availableBytes: huge) else {
                return XCTFail("\(variant) must refuse above its own cap")
            }
        }
    }

    func testAMachineThatFitsBaseNeedNotFitV2() {
        // Why the guard has to know which pack it is sizing, stated as a machine rather
        // than a percentage: at 550 residues base peaks at 6303 MiB and v2 at 9068, so
        // there are real Macs between the two. Sized from base's row, v2 was waved onto
        // every one of them.
        let tokens = 550
        let baseBytes = ProtenixSizeGuard.estimatedBytes(tokens: tokens, variant: .base)
        let v2Bytes = ProtenixSizeGuard.estimatedBytes(tokens: tokens, variant: .v2)
        XCTAssertGreaterThan(v2Bytes, baseBytes)
        // Just too little for v2's real peak, comfortably enough for base's.
        let available = Int(Double(v2Bytes) / PredictSizeGuard.warnFraction) - 1
        guard case .refuse = ProtenixSizeGuard.decide(tokens: tokens, variant: .v2,
                                                      availableBytes: available) else {
            return XCTFail("v2 does not fit and must be refused")
        }
        XCTAssertNotEqual(ProtenixSizeGuard.decide(tokens: tokens, variant: .base,
                                                   availableBytes: available),
                          ProtenixSizeGuard.decide(tokens: tokens, variant: .v2,
                                                   availableBytes: available))
    }

    func testBoltzsGuardIsUntouched() {
        // The two guards are separate types precisely so Protenix's numbers cannot move
        // Boltz's. This pins that.
        XCTAssertEqual(PredictSizeGuard.maximumTokens, 900)
        XCTAssertNotEqual(PredictSizeGuard.maximumTokens, ProtenixSizeGuard.maximumTokens)
    }

    // MARK: - MLX arbitration

    func testEachRuntimeRegistersUnderItsOwnName() {
        // Registering under one name would overwrite rather than arbitrate, and whichever
        // ran last would win — silently, by call order.
        XCTAssertNotEqual(ProtenixRuntime.cacheLimitOwner, BoltzRuntime.cacheLimitOwner)
    }

    func testTheConservativeCeilingStillWins() {
        // Protenix asks for more than Boltz; MLXRuntime must resolve DOWNWARD to the most
        // conservative requirement, or Design mode's 96 MB ceiling could be raised by a
        // prediction and the app jetsam-killed.
        XCTAssertGreaterThan(ProtenixRuntime.cacheLimitBytes, BoltzRuntime.cacheLimitBytes)
        ProtenixRuntime.configureOnce()
        BoltzRuntime.configureOnce()
        let asks = MLXRuntime.cacheLimitRequirements
        XCTAssertEqual(asks[ProtenixRuntime.cacheLimitOwner],
                       ProtenixRuntime.cacheLimitBytes)
        XCTAssertEqual(asks[BoltzRuntime.cacheLimitOwner], BoltzRuntime.cacheLimitBytes)
        // Both asks are on the register, so arbitration can see them; what MLX actually
        // runs with is never above the smallest of them.
        XCTAssertLessThanOrEqual(MLXRuntime.activeCacheLimitBytes,
                                 asks.values.min() ?? Int.max)
    }

    // MARK: - Cancellation bookkeeping

    func testCancellingAJobThisManagerNeverSawIsHarmless() {
        // Cancels are broadcast to every manager, because the marker carries only a job
        // id and there is nothing in it to route on.
        ProtenixJobManager.shared.cancel(jobID: "never-existed")
    }
}
#endif
