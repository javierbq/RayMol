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
                              runtime: String?) throws -> BoltzJobManager.Request {
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
        return try BoltzJobManager.parseRequest(at: url)
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
        for point in ProtenixSizeGuard.measured where point.tokens <= 700 {
            XCTAssertEqual(ProtenixSizeGuard.estimatedPeakMiB(tokens: point.tokens),
                           point.peakMiB, "at \(point.tokens) residues")
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
            tokens: ProtenixSizeGuard.maximumTokens + 1, availableBytes: huge)
        guard case .refuse = decision else {
            return XCTFail("above the cap must refuse regardless of memory, got \(decision)")
        }
    }

    func testTheCapAgreesWithThePythonSide() {
        // Both ends enforce it: Python refuses before the download, this refuses before
        // the tensors. They disagreeing means one of them is decoration.
        XCTAssertEqual(ProtenixSizeGuard.maximumTokens, 700,
                       "keep in step with pymol.predictors.protenix.MAX_RESIDUES")
    }

    func testTheCapIsTheLargestMeasuredPointAndNotBeyondIt() {
        // The one invariant that survives raising the cap: it may reach the data and no
        // further. PredictSizeGuard's docstring records three occasions where a fit past
        // its measurements ran optimistic.
        let largest = ProtenixSizeGuard.measured.map(\.tokens).max() ?? 0
        XCTAssertLessThanOrEqual(ProtenixSizeGuard.maximumTokens, largest)
    }

    func testTheBudgetIsWhatBoundsAFoldOnALargeMachine() {
        // 32 GB by request. A machine with more RAM than that is still held to it.
        let huge = 512 * 1024 * 1024 * 1024
        let decision = ProtenixSizeGuard.decide(tokens: 700, availableBytes: huge)
        XCTAssertEqual(decision, .ok, "8.6 GB against a 32 GB budget is comfortable")
        XCTAssertEqual(ProtenixSizeGuard.budgetBytes, 32 * 1024 * 1024 * 1024)
    }

    func testASmallMachineIsStillProtectedByItsOwnMemory() {
        // The budget is a ceiling, not a promise: an 8 GB Mac is sized against 8 GB.
        let decision = ProtenixSizeGuard.decide(tokens: 700,
                                                availableBytes: 8 * 1024 * 1024 * 1024)
        guard case .refuse = decision else {
            return XCTFail("8.6 GB cannot fit in 8 GB, got \(decision)")
        }
    }

    func testTheLengthThatPromptedThisFits() {
        // 532 residues, the input that hit the old 400 cap. Interpolates to ~6 GB, which
        // is measured territory: 550 was swept at 6303 MiB.
        XCTAssertEqual(ProtenixSizeGuard.decide(tokens: 532,
                                                availableBytes: 32 * 1024 * 1024 * 1024),
                       .ok)
    }

    func testAModestFoldIsAccepted() {
        let decision = ProtenixSizeGuard.decide(tokens: 60,
                                                availableBytes: 36 * 1024 * 1024 * 1024)
        XCTAssertEqual(decision, .ok)
    }

    func testATinyMachineRefusesAndSaysWhatWouldFit() {
        let decision = ProtenixSizeGuard.decide(tokens: 400,
                                                availableBytes: 2 * 1024 * 1024 * 1024)
        guard case .refuse(let fitting) = decision else {
            return XCTFail("2 GB cannot hold a 400-residue fold, got \(decision)")
        }
        XCTAssertLessThan(fitting, 400)
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
