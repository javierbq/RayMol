#if os(macOS)
import XCTest
@testable import RayMol

/// The transport is deliberately file-based: RayMol has no Python→Swift call path, so
/// Python prints a marker that `pollFeedback()` already scans for, and the payload
/// travels via tempfiles because the feedback line caps at ~1 KB.
///
/// These tests pin the wire format, which is a contract with
/// `modules/pymol/predictors/host.py`. If they and the Python tests disagree, the
/// feature is broken in a way neither side's suite would catch alone.
final class BoltzJobManagerTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        BoltzJobManager.shared.resetForTesting()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BoltzJobManager.shared.resetForTesting()
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Mirrors exactly what host.py writes: `chains` is a list of OBJECTS, not pairs.
    private func writeRequest(job: String,
                              chains: [(String, String)],
                              diffusionSteps: Int = 200,
                              runtime: String? = nil,
                              extra: [String: Any] = [:],
                              omittingBoltzKnobs: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        var payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": chains.map { ["chain": $0.0, "sequence": $0.1] },
            "seed": 0,
            "out_path": dir.appendingPathComponent("out_\(job).pdb").path,
            "status_path": dir.appendingPathComponent("raymol_predict_status_\(job).json").path,
        ]
        // Omitted, not defaulted, when the caller is standing in for a predictor that
        // has neither knob: host.py puts only the knobs a predictor DECLARED on the
        // wire, so "absent" is a shape the decoder really has to handle.
        if !omittingBoltzKnobs {
            payload["recycling_steps"] = 3
            payload["diffusion_steps"] = diffusionSteps
        }
        if let runtime { payload["runtime"] = runtime }
        payload.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    // MARK: - Wire format

    func testDecodesARequestWrittenInHostPysFormat() throws {
        let url = try writeRequest(job: "j1", chains: [("A", "AG"), ("B", "W")])
        let parsed = try BoltzJobManager.parseRequest(at: url)
        XCTAssertEqual(parsed.jobID, "j1")
        XCTAssertEqual(parsed.chains.map(\.chain), ["A", "B"])
        XCTAssertEqual(parsed.chains.map(\.sequence), ["AG", "W"])
        XCTAssertEqual(parsed.recyclingSteps, 3)
        XCTAssertEqual(parsed.diffusionSteps, 200)
        XCTAssertEqual(parsed.seed, 0)
        XCTAssertFalse(parsed.outPath.isEmpty)
        XCTAssertFalse(parsed.statusPath.isEmpty)
    }

    /// #224 auto-load: the object name travels on the wire so the host knows where the
    /// finished structure belongs, without a second round-trip to Python.
    func testDecodesTheObjectNameForAutoLoad() throws {
        let url = dir.appendingPathComponent("raymol_predict_req_named.json")
        let payload: [String: Any] = [
            "job_id": "named", "weights_dir": dir.path,
            "chains": [["chain": "A", "sequence": "AG"]],
            "recycling_steps": 3, "diffusion_steps": 200, "seed": 0,
            "out_path": "/tmp/o.pdb", "status_path": "/tmp/s.json",
            "object_name": "prediction_deadbeef",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        XCTAssertEqual(try BoltzJobManager.parseRequest(at: url).objectName,
                       "prediction_deadbeef")
    }

    /// An absent object_name must NOT fail the decode — it means "do not auto-load", and
    /// a strict field would turn Python/Swift skew into a hard failure.
    func testRequestWithoutAnObjectNameStillDecodes() throws {
        let url = try writeRequest(job: "noname", chains: [("A", "AG")])
        let parsed = try BoltzJobManager.parseRequest(at: url)
        XCTAssertNil(parsed.objectName)
    }

    /// Positional pairs must NOT decode — that would mean the two sides had silently
    /// diverged on the format.
    func testPositionalChainPairsAreRejected() throws {
        let url = dir.appendingPathComponent("raymol_predict_req_bad.json")
        let payload: [String: Any] = [
            "job_id": "bad", "weights_dir": dir.path,
            "chains": [["A", "AG"]],
            "recycling_steps": 3, "diffusion_steps": 200, "seed": 0,
            "out_path": "/tmp/o.pdb", "status_path": "/tmp/s.json",
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        XCTAssertThrowsError(try BoltzJobManager.parseRequest(at: url))
    }

    func testStatusRoundTripsWithSnakeCaseKeys() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j2.json")
        try BoltzJobManager.writeStatus(
            .init(state: "running", phase: "inference", fraction: 0.5,
                  error: nil, resultPath: "/tmp/x.pdb", peakBytes: nil,
                  elapsedSeconds: nil), to: path)
        // Assert the on-disk KEY SPELLING, because Python reads these by name.
        let raw = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: path)) as? [String: Any]
        XCTAssertEqual(raw?["state"] as? String, "running")
        XCTAssertEqual(raw?["result_path"] as? String, "/tmp/x.pdb")
        let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self,
                                               from: try Data(contentsOf: path))
        XCTAssertEqual(decoded.fraction, 0.5)
    }

    func testStatusCarriesPeakMemoryAndElapsedWithSnakeCaseKeys() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j6.json")
        try BoltzJobManager.writeStatus(
            .init(state: "done", phase: "done", fraction: 1.0, error: nil,
                  resultPath: "/tmp/x.pdb", peakBytes: 4_294_967_296,
                  elapsedSeconds: 65.3), to: path)
        let raw = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: path)) as? [String: Any]
        XCTAssertEqual(raw?["peak_bytes"] as? Int, 4_294_967_296)
        XCTAssertEqual(raw?["elapsed_s"] as? Double, 65.3)
        let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self,
                                               from: try Data(contentsOf: path))
        XCTAssertEqual(decoded.peakBytes, 4_294_967_296)
    }

    /// Absent while a job is still running -- Python's queued fallback mirrors that.
    func testPeakMemoryIsNilBeforeCompletion() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j7.json")
        try BoltzJobManager.writeStatus(
            .init(state: "running", phase: "inference", fraction: 0.2, error: nil,
                  resultPath: nil, peakBytes: nil, elapsedSeconds: nil), to: path)
        let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self,
                                               from: try Data(contentsOf: path))
        XCTAssertNil(decoded.peakBytes)
        XCTAssertNil(decoded.elapsedSeconds)
    }

    func testStatusWriteIsAtomicLeavingNoTempBehind() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j5.json")
        try BoltzJobManager.writeStatus(
            .init(state: "done", phase: "done", fraction: 1.0,
                  error: nil, resultPath: nil, peakBytes: nil,
                  elapsedSeconds: nil), to: path)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "temp file left behind: \(leftovers)")
    }

    // MARK: - Marker parsing

    func testParsesSubmitAndCancelVerbs() {
        XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:submit:j1")?.verb, .submit)
        XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:cancel:j1")?.verb, .cancel)
        XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:submit:j1")?.jobID, "j1")
    }

    func testRejectsUnknownVerbsAndForeignPrefixes() {
        XCTAssertNil(BoltzJobManager.parseMarker("PREDICT:frobnicate:j1"))
        XCTAssertNil(BoltzJobManager.parseMarker("OBJPANEL:ready"))
        XCTAssertNil(BoltzJobManager.parseMarker("PREDICT:submit:"))
        XCTAssertNil(BoltzJobManager.parseMarker("PREDICT:submit"))
        XCTAssertNil(BoltzJobManager.parseMarker(""))
    }

    /// A job id containing a colon must survive, since maxSplits caps the split at one.
    func testJobIdMayContainAColon() {
        XCTAssertEqual(BoltzJobManager.parseMarker("PREDICT:cancel:a:b")?.jobID, "a:b")
    }

    func testAMarkerWithNoRequestFileIsIgnored() {
        // Must not crash or throw out of the feedback pump.
        BoltzJobManager.shared.handle(marker: "PREDICT:submit:definitely-missing")
    }

    // MARK: - Preflight

    func testOversizedInputIsRefusedBeforeAnyAllocation() throws {
        let long = String(repeating: "A", count: PredictSizeGuard.maximumTokens + 10)
        let url = try writeRequest(job: "j3", chains: [("A", long)])
        let request = try BoltzJobManager.parseRequest(at: url)
        let status = BoltzJobManager.preflight(request)
        XCTAssertEqual(status?.state, "failed")
        XCTAssertEqual(status?.phase, "preflight")
        XCTAssertNotNil(status?.error)
    }

    func testReasonableInputPassesPreflight() throws {
        let url = try writeRequest(job: "j4", chains: [("A", String(repeating: "A", count: 40))])
        let request = try BoltzJobManager.parseRequest(at: url)
        XCTAssertNil(BoltzJobManager.preflight(request),
                     "a 40-residue chain must not be refused on any supported Mac")
    }

    // MARK: - Runtime dispatch

    /// The safety property of the whole seam. Weights and featurizer are method-
    /// specific, so running another method's request on this backend would not fail —
    /// it would return a confident wrong structure.
    func testARequestNamingAnUnlinkedRuntimeIsRefused() throws {
        let url = try writeRequest(job: "r1", chains: [("A", "AGCT")],
                                   runtime: "simplefold")
        let request = try BoltzJobManager.parseRequest(at: url)
        let status = BoltzJobManager.preflight(request)
        XCTAssertEqual(status?.state, "failed")
        XCTAssertEqual(status?.phase, "preflight")
        XCTAssertEqual(status?.error?.contains("simplefold"), true,
                       "the refusal must name the runtime that is missing")
    }

    func testARequestNamingBoltzExplicitlyIsAccepted() throws {
        let url = try writeRequest(job: "r2", chains: [("A", "AGCT")], runtime: "boltz")
        let request = try BoltzJobManager.parseRequest(at: url)
        XCTAssertEqual(request.runtime, "boltz")
        XCTAssertNil(BoltzJobManager.preflight(request))
    }

    /// Absent means Boltz: every Python side predating a second runtime wrote no such
    /// key, and this manager was the only backend that existed then.
    func testARequestWithNoRuntimeIsTakenAsBoltz() throws {
        let url = try writeRequest(job: "r3", chains: [("A", "AGCT")])
        let request = try BoltzJobManager.parseRequest(at: url)
        XCTAssertNil(request.runtime)
        XCTAssertNil(BoltzJobManager.preflight(request))
    }

    /// A request carrying another method's knobs and none of Boltz's still DECODES, so
    /// the runtime refusal above is what rejects it — with a message naming the
    /// runtime, rather than a bare "malformed prediction request".
    func testARequestWithForeignKnobsDecodesSoItCanBeRefusedByName() throws {
        let url = try writeRequest(job: "r4", chains: [("A", "AGCT")],
                                   runtime: "simplefold",
                                   extra: ["num_steps": 500],
                                   omittingBoltzKnobs: true)
        let request = try BoltzJobManager.parseRequest(at: url)
        XCTAssertEqual(request.numSteps, 500)
        XCTAssertNil(request.recyclingSteps)
        XCTAssertNil(request.diffusionSteps)
        XCTAssertEqual(BoltzJobManager.preflight(request)?.error?.contains("simplefold"),
                       true)
    }
    // MARK: - Cancellation actually interrupts

    /// The whole point of the cancel path. boltz-mlx guards each diffusion step with
    /// `Task.checkCancellation()`, which reads the RUNNING task's flag — so a cancel that
    /// only records a side-channel flag lets compute run to completion and merely discards
    /// the result. This asserts the live task is genuinely cancelled.
    func testCancelMarkerCancelsTheLiveInferenceTask() {
        let started = expectation(description: "task started")
        let observed = expectation(description: "task observed cancellation")
        let task = Task {
            started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            observed.fulfill()
        }
        BoltzJobManager.shared.registerTaskForTesting(task, jobID: "cx1")
        wait(for: [started], timeout: 5)

        BoltzJobManager.shared.handle(marker: "PREDICT:cancel:cx1")

        wait(for: [observed], timeout: 5)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(BoltzJobManager.shared.cancelRequestedForTesting.contains("cx1"))
    }

    /// A cancel can legitimately arrive before the task is registered, so the flag must
    /// still be recorded for the coarse phase checks in run().
    func testCancelBeforeRegistrationIsStillRecorded() {
        BoltzJobManager.shared.handle(marker: "PREDICT:cancel:cx2")
        XCTAssertTrue(BoltzJobManager.shared.cancelRequestedForTesting.contains("cx2"))
    }

    /// ...but a cancel for a job that already finished is moot and must NOT accumulate.
    func testCancelForATerminalJobIsIgnoredSoTheSetStaysBounded() throws {
        let jobID = "cx3"
        try BoltzJobManager.writeStatus(
            .init(state: "done", phase: "done", fraction: 1.0, error: nil,
                  resultPath: "/tmp/x.pdb", peakBytes: 1, elapsedSeconds: 1),
            to: BoltzJobManager.statusURL(jobID: jobID))
        defer { try? FileManager.default.removeItem(at: BoltzJobManager.statusURL(jobID: jobID)) }

        BoltzJobManager.shared.handle(marker: "PREDICT:cancel:\(jobID)")
        XCTAssertFalse(BoltzJobManager.shared.cancelRequestedForTesting.contains(jobID))
    }

    // MARK: - An unparseable request must fail loudly, not vanish

    /// Without this, `handle()` returned silently and Python polled `queued` forever —
    /// asymmetric with preflight, which does write `failed`.
    func testUnparseableRequestWritesAFailedStatus() throws {
        let jobID = "bad-\(UUID().uuidString.prefix(8))"
        let req = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_req_\(jobID).json")
        try Data("{ not json at all".utf8).write(to: req)
        let statusPath = BoltzJobManager.statusURL(jobID: jobID)
        defer {
            try? FileManager.default.removeItem(at: req)
            try? FileManager.default.removeItem(at: statusPath)
        }

        BoltzJobManager.shared.handle(marker: "PREDICT:submit:\(jobID)")

        let decoded = try JSONDecoder().decode(
            BoltzJobManager.Status.self, from: try Data(contentsOf: statusPath))
        XCTAssertEqual(decoded.state, "failed")
        XCTAssertEqual(decoded.phase, "request")
        XCTAssertNotNil(decoded.error)
    }

    /// The same guard covers a well-formed request whose numbers overflow the Swift decode
    /// (Int steps / UInt64 seed) — the concrete case that used to hang a job forever.
    func testRequestWithOverflowingSeedFailsRatherThanHangs() throws {
        let jobID = "ovf-\(UUID().uuidString.prefix(8))"
        let req = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_req_\(jobID).json")
        try Data("""
        {"job_id":"\(jobID)","weights_dir":"/tmp","chains":[{"chain":"A","sequence":"AG"}],
         "recycling_steps":3,"diffusion_steps":1000000000000000000000000000000,"seed":0,
         "out_path":"/tmp/o.pdb","status_path":"\(BoltzJobManager.statusURL(jobID: jobID).path)"}
        """.utf8).write(to: req)
        let statusPath = BoltzJobManager.statusURL(jobID: jobID)
        defer {
            try? FileManager.default.removeItem(at: req)
            try? FileManager.default.removeItem(at: statusPath)
        }

        BoltzJobManager.shared.handle(marker: "PREDICT:submit:\(jobID)")

        let decoded = try JSONDecoder().decode(
            BoltzJobManager.Status.self, from: try Data(contentsOf: statusPath))
        XCTAssertEqual(decoded.state, "failed")
    }
    /// The race live testing exposed. A cancel that arrives BEFORE the inference task is
    /// registered previously found no task, set only the flag, and was then never acted
    /// on: a job cancelled at ~12 s ran the full 49 s and reported "done". The unit test
    /// for the happy path could not catch it, because it registers first and cancels
    /// second. Registration must therefore observe an already-requested cancel.
    func testCancelArrivingBeforeRegistrationStillCancelsTheTask() {
        let jobID = "prereg"
        // Cancel first — no task exists yet, so only the flag is recorded.
        BoltzJobManager.shared.handle(marker: "PREDICT:cancel:\(jobID)")
        XCTAssertTrue(BoltzJobManager.shared.cancelRequestedForTesting.contains(jobID))

        let observed = expectation(description: "task saw the cancellation")
        let task = Task {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            observed.fulfill()
        }
        // Registering must notice the pending request and cancel immediately.
        BoltzJobManager.shared.registerTaskForTesting(task, jobID: jobID)

        wait(for: [observed], timeout: 5)
        XCTAssertTrue(task.isCancelled,
                      "a cancel requested before registration must not be dropped")
    }
}
#endif
