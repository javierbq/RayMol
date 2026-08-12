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
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Mirrors exactly what host.py writes: `chains` is a list of OBJECTS, not pairs.
    private func writeRequest(job: String,
                              chains: [(String, String)],
                              diffusionSteps: Int = 200) throws -> URL {
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        let payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": chains.map { ["chain": $0.0, "sequence": $0.1] },
            "recycling_steps": 3,
            "diffusion_steps": diffusionSteps,
            "seed": 0,
            "out_path": dir.appendingPathComponent("out_\(job).pdb").path,
            "status_path": dir.appendingPathComponent("raymol_predict_status_\(job).json").path,
        ]
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
}
#endif
