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
    /// Job IDs written by writeRequest() into NSTemporaryDirectory() root. tearDown()
    /// removes both derived paths (request + status) for each one so they do not
    /// accumulate across runs.
    private var writtenJobIDs: [String] = []

    override func setUp() {
        super.setUp()
        BoltzJobManager.shared.resetForTesting()
        writtenJobIDs = []
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BoltzJobManager.shared.resetForTesting()
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        for jobID in writtenJobIDs {
            try? FileManager.default.removeItem(
                at: tmpDir.appendingPathComponent("raymol_predict_req_\(jobID).json"))
            try? FileManager.default.removeItem(
                at: tmpDir.appendingPathComponent("raymol_predict_status_\(jobID).json"))
        }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Mirrors exactly what host.py writes: `chains` is a list of OBJECTS, not pairs.
    ///
    /// The request JSON and status path are written into NSTemporaryDirectory() root (not
    /// the test-scoped `dir` subdirectory) so that `handle()`, which constructs the
    /// request URL from NSTemporaryDirectory() directly, can find the file.
    private func writeRequest(job: String,
                              chains: [(String, String)],
                              diffusionSteps: Int = 200) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = tmpDir.appendingPathComponent("raymol_predict_req_\(job).json")
        let payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": chains.map { ["chain": $0.0, "sequence": $0.1] },
            "recycling_steps": 3,
            "diffusion_steps": diffusionSteps,
            "seed": 0,
            "out_path": dir.appendingPathComponent("out_\(job).pdb").path,
            "status_path": tmpDir.appendingPathComponent("raymol_predict_status_\(job).json").path,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        writtenJobIDs.append(job)
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

    /// boltz-mlx v0.2.1's per-step callback: `phase` becomes trunk/diffusion and
    /// the step counts ride along. Python reads these BY NAME, so the on-disk
    /// spelling is the contract, not the Swift property name.
    func testStatusCarriesStepCountsWithSnakeCaseKeys() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j8.json")
        try BoltzJobManager.writeStatus(
            .init(state: "running", phase: "diffusion", fraction: 0.42, error: nil,
                  resultPath: nil, peakBytes: nil, elapsedSeconds: nil,
                  step: 84, totalSteps: 200), to: path)
        let raw = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: path)) as? [String: Any]
        XCTAssertEqual(raw?["phase"] as? String, "diffusion")
        XCTAssertEqual(raw?["step"] as? Int, 84)
        XCTAssertEqual(raw?["total_steps"] as? Int, 200)
        let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self,
                                               from: try Data(contentsOf: path))
        XCTAssertEqual(decoded.step, 84)
        XCTAssertEqual(decoded.totalSteps, 200)
    }

    /// Optional on purpose: featurize/load/write report no steps at all, and a
    /// status file written before v0.2.1 has neither key. A strict field would
    /// turn either into a decode failure and a job that polls forever.
    func testAStatusWithoutStepCountsStillDecodes() throws {
        let path = dir.appendingPathComponent("raymol_predict_status_j9.json")
        try Data("""
        {"state":"running","phase":"load","fraction":0.1,"error":null,
         "result_path":null,"peak_bytes":null,"elapsed_s":null}
        """.utf8).write(to: path)
        let decoded = try JSONDecoder().decode(BoltzJobManager.Status.self,
                                               from: try Data(contentsOf: path))
        XCTAssertEqual(decoded.phase, "load")
        XCTAssertNil(decoded.step)
        XCTAssertNil(decoded.totalSteps)
    }

    // MARK: - Step throttle

    /// A 200-step run on a small input steps in milliseconds. Unthrottled that is
    /// 200 atomic status writes in a burst, on inference's own critical path.
    func testTheThrottleSkipsStepsThatAreNeitherTimelyNorVisible() {
        let throttle = BoltzJobManager.StepThrottle()
        XCTAssertTrue(throttle.shouldEmit(stage: "diffusion", fraction: 0.0,
                                          isFinal: false, now: 0),
                      "the first step of a stage is always news")
        // +0.005 of movement, +0.01 s: below BOTH thresholds.
        XCTAssertFalse(throttle.shouldEmit(stage: "diffusion", fraction: 0.005,
                                           isFinal: false, now: 0.01))
    }

    /// Either threshold alone is enough — the same OR that fetching.py's `_emit`
    /// applies to the WEIGHTS: marker.
    func testTheThrottleEmitsOnAOnePercentMoveEvenWhenNoTimeHasPassed() {
        let throttle = BoltzJobManager.StepThrottle()
        _ = throttle.shouldEmit(stage: "diffusion", fraction: 0.0, isFinal: false, now: 0)
        XCTAssertTrue(throttle.shouldEmit(stage: "diffusion", fraction: 0.01,
                                          isFinal: false, now: 0.001))
    }

    func testTheThrottleEmitsOnTheIntervalEvenWhenTheBarHasNotMoved() {
        let throttle = BoltzJobManager.StepThrottle()
        _ = throttle.shouldEmit(stage: "diffusion", fraction: 0.5, isFinal: false, now: 0)
        XCTAssertFalse(throttle.shouldEmit(stage: "diffusion", fraction: 0.5,
                                           isFinal: false, now: 0.14))
        XCTAssertTrue(throttle.shouldEmit(stage: "diffusion", fraction: 0.5,
                                          isFinal: false, now: 0.15))
    }

    /// A dropped final step would leave the card parked one step short forever,
    /// because nothing follows it inside the stage.
    func testTheThrottleAlwaysEmitsAStagesFinalStep() {
        let throttle = BoltzJobManager.StepThrottle()
        _ = throttle.shouldEmit(stage: "diffusion", fraction: 0.995, isFinal: false, now: 0)
        XCTAssertTrue(throttle.shouldEmit(stage: "diffusion", fraction: 1.0,
                                          isFinal: true, now: 0.001),
                      "the last step is forced, exactly as fetching._emit forces "
                      + "its terminal marker")
    }

    /// The phase NAME changes on a stage boundary, which no fraction comparison
    /// would catch: trunk ends at 1.0 and diffusion's first step can also be 1.0
    /// of 1 in the degenerate case.
    func testTheThrottleAlwaysEmitsTheFirstStepOfANewStage() {
        let throttle = BoltzJobManager.StepThrottle()
        _ = throttle.shouldEmit(stage: "trunk", fraction: 0.75, isFinal: false, now: 0)
        XCTAssertTrue(throttle.shouldEmit(stage: "diffusion", fraction: 0.75,
                                          isFinal: false, now: 0.001))
    }

    /// 200 steps of a run that finishes in a fraction of a second must not be 200
    /// atomic writes. The 1% rule still lets one through every other step, which
    /// is the deliberate floor: it is the rate at which the bar visibly moves,
    /// and it is exactly the ceiling fetching.py accepts for the WEIGHTS: marker.
    func testAFastTwoHundredStepRunIsThrottledBelowOneWritePerStep() {
        let throttle = BoltzJobManager.StepThrottle()
        var emitted = 0
        for step in 1...200 {
            // 200 steps in 100 ms: every step is well inside the interval, and
            // each is 0.5% of movement.
            if throttle.shouldEmit(stage: "diffusion",
                                   fraction: Double(step) / 200.0,
                                   isFinal: step == 200,
                                   now: Double(step) * 0.0005) {
                emitted += 1
            }
        }
        XCTAssertLessThanOrEqual(emitted, 105, "got \(emitted) of 200 steps")
        XCTAssertGreaterThan(emitted, 0)
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
    // MARK: - settle ordering

    /// The status file must be on disk BEFORE the placeholder is taken down.
    /// discard_pending pops _PENDING, which is the map every progress view reads;
    /// discarding first strands the error where nothing can observe it.
    func testPreflightRefusalWritesStatusBeforeDiscardingPlaceholder() throws {
        var order: [String] = []
        BoltzJobManager.settleTap = { order.append($0) }
        defer { BoltzJobManager.settleTap = nil }

        // 100k residues: far past any machine's fitting size, so preflight refuses
        // without touching MLX.
        let jobID = "test-\(UUID().uuidString.prefix(12))"
        try writeRequest(job: jobID,
                         chains: [("A", String(repeating: "A", count: 100_000))],
                         diffusionSteps: 200)
        BoltzJobManager.shared.handle(marker: "PREDICT:submit:\(jobID)")

        XCTAssertEqual(order, ["write", "discard"],
                       "status must be written before the placeholder is discarded")

        let statusURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_status_\(jobID).json")
        let status = try JSONDecoder().decode(
            BoltzJobManager.Status.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(status.state, "failed")
        XCTAssertNotNil(status.error)
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
