#if os(macOS)
import XCTest
@testable import RayMol

/// The `rfd3` runtime seam: a request names the backend that must run it, the router hands
/// it to exactly one manager, and everything a generator's request adds to the wire is
/// OPTIONAL so a Python/Swift skew degrades to a refusal rather than "malformed request".
///
/// Payloads are built as JSON and decoded through `InferenceJob.parseRequest`, never
/// constructed with the memberwise initialiser: the thing under test is the wire contract
/// with `pymol.generators`, and a hand-built struct would only prove the decoder agrees
/// with itself.
final class RFD3RuntimeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rfd3-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// One residue, three atoms — enough to be a legal target.
    private func residue(_ chain: String, _ resi: String, _ resn: String) -> [String: Any] {
        ["chain": chain, "resi": resi, "resn": resn,
         "atoms": [["name": "N", "xyz": [0.0, 0.0, 0.0]],
                   ["name": "CA", "xyz": [1.5, 0.0, 0.0]],
                   ["name": "C", "xyz": [2.4, 1.0, 0.0]]]]
    }

    /// Exactly the keys `pymol.predictors.host.submit` writes for a generator, so a change
    /// on either side breaks here rather than in front of a user.
    private func writeRequest(job: String, runtime: String? = "rfd3",
                              target: [[String: Any]]? = nil,
                              hotspots: [Int]? = [0],
                              designLength: Int? = 30,
                              designChain: String? = "B",
                              designKey: String? = "deadbeefdeadbeef") throws
        -> InferenceJob.Request
    {
        var payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": [],
            "recycling_steps": 2,
            "diffusion_steps": 200,
            "seed": 7,
            "out_path": dir.appendingPathComponent("\(job).pdb").path,
            "status_path": dir.appendingPathComponent("\(job).json").path,
            "object_name": "rfd3_design_abcd1234",
            "metrics_path": dir.appendingPathComponent("\(job)-metrics.json").path,
        ]
        if let runtime { payload["runtime"] = runtime }
        payload["target"] = target ?? [residue("A", "45", "TRP"), residue("A", "46", "SER")]
        if let hotspots { payload["hotspots"] = hotspots }
        if let designLength { payload["design_length"] = designLength }
        if let designChain { payload["design_chain"] = designChain }
        if let designKey { payload["design_key"] = designKey }
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return try InferenceJob.parseRequest(at: url)
    }

    // MARK: The wire

    func testAGeneratorRequestDecodesEveryFieldItAdds() throws {
        let request = try writeRequest(job: "g1")
        XCTAssertEqual(request.runtime, RFD3JobManager.runtimeName)
        XCTAssertEqual(request.target?.count, 2)
        XCTAssertEqual(request.target?.first?.chain, "A")
        XCTAssertEqual(request.target?.first?.resi, "45")
        XCTAssertEqual(request.target?.first?.resn, "TRP")
        XCTAssertEqual(request.target?.first?.atoms.count, 3)
        XCTAssertEqual(request.target?.first?.atoms.first?.name, "N")
        XCTAssertEqual(request.hotspots, [0])
        XCTAssertEqual(request.designLength, 30)
        XCTAssertEqual(request.designChain, "B")
        XCTAssertEqual(request.designKey, "deadbeefdeadbeef")
        // And a generator has no sequences at all, which is the whole reason it needed
        // fields of its own.
        XCTAssertTrue(request.chains.isEmpty)
    }

    func testAPredictionRequestStillDecodesWithNoneOfThem() throws {
        // Every added field is Optional so a Python side that predates them -- or simply a
        // prediction -- decodes unchanged. A non-optional field here would turn any skew
        // into "malformed prediction request" for EVERY predictor, not just this method.
        let url = dir.appendingPathComponent("raymol_predict_req_p1.json")
        let payload: [String: Any] = [
            "job_id": "p1", "weights_dir": dir.path,
            "chains": [["chain": "A", "sequence": "MKTAY"]],
            "recycling_steps": 3, "diffusion_steps": 200, "seed": 0,
            "out_path": dir.appendingPathComponent("p1.pdb").path,
            "status_path": dir.appendingPathComponent("p1.json").path,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let request = try InferenceJob.parseRequest(at: url)
        XCTAssertNil(request.target)
        XCTAssertNil(request.hotspots)
        XCTAssertNil(request.designLength)
        XCTAssertNil(request.designChain)
        XCTAssertNil(request.designKey)
        XCTAssertNil(request.runtime, "absent runtime means boltz")
        XCTAssertNil(BoltzJobManager.preflight(request),
                     "a plain Boltz request must still pass Boltz's preflight")
    }

    // MARK: Routing

    func testTheRouterClaimsRFD3AndOnlyRFD3() throws {
        // Not via `InferenceRouter.handle` -- that would actually start a design. The
        // property under test is that the runtime names are distinct and that the DEFAULT
        // runtime's preflight refuses this one, which is the fallback path if the table
        // entry were ever removed.
        XCTAssertEqual(RFD3JobManager.runtimeName, "rfd3")
        XCTAssertNotEqual(RFD3JobManager.runtimeName, ProtenixJobManager.runtimeName)
        XCTAssertNotEqual(RFD3JobManager.runtimeName, BoltzJobManager.runtimeName)
        let request = try writeRequest(job: "g2")
        let refusal = BoltzJobManager.preflight(request)
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("rfd3") ?? false,
                      "the refusal must NAME the runtime: \(refusal?.error ?? "nil")")
    }

    func testBoltzRefusesARuntimeNothingImplements() throws {
        let request = try writeRequest(job: "g3", runtime: "nosuchruntime")
        let refusal = BoltzJobManager.preflight(request)
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("nosuchruntime") ?? false,
                      refusal?.error ?? "nil")
    }

    // MARK: Shape refusals

    func testAForeignRuntimeIsRefusedByThisManagerToo() throws {
        // Unreachable through `route`, which dispatches on this field -- checked anyway,
        // because running a Boltz request through a generator's featurizer would not fail,
        // it would return a confident wrong answer.
        let request = try writeRequest(job: "s0", runtime: "boltz")
        let refusal = RFD3JobManager.preflight(request)
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("rfd3") ?? false, refusal?.error ?? "nil")
    }

    func testAValidGeneratorRequestPassesShapePreflight() throws {
        XCTAssertNil(RFD3JobManager.preflight(try writeRequest(job: "s1")))
    }

    func testATargetlessRequestIsRefused() throws {
        let request = try writeRequest(job: "s2", target: [])
        let refusal = RFD3JobManager.preflight(request)
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("target") ?? false, refusal?.error ?? "nil")
    }

    func testAHotspotOutsideTheTargetIsRefusedByIndex() throws {
        // The featurizer tests hotspot membership against a residue's POSITION in the array
        // and never reads a residue number, so an out-of-range index would silently
        // condition on nothing. Refused, and the message names the index.
        let refusal = RFD3JobManager.preflight(try writeRequest(job: "s3", hotspots: [2]))
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("2") ?? false, refusal?.error ?? "nil")
    }

    func testNoHotspotsAtAllIsRefused() throws {
        let refusal = RFD3JobManager.preflight(try writeRequest(job: "s4", hotspots: []))
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("hotspot") ?? false, refusal?.error ?? "nil")
    }

    func testAZeroLengthDesignIsRefused() throws {
        let refusal = RFD3JobManager.preflight(
            try writeRequest(job: "s5", designLength: 0))
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("length") ?? false, refusal?.error ?? "nil")
    }

    func testAnAtomlessTargetResidueIsRefusedByName() throws {
        let empty: [String: Any] = ["chain": "A", "resi": "47", "resn": "GLY",
                                   "atoms": [] as [[String: Any]]]
        let refusal = RFD3JobManager.preflight(
            try writeRequest(job: "s6", target: [residue("A", "45", "TRP"), empty]))
        XCTAssertEqual(refusal?.state, "failed")
        XCTAssertTrue(refusal?.error?.contains("A/47") ?? false, refusal?.error ?? "nil")
    }

    // MARK: The metric document

    func testTheMetricsDocumentCarriesExactlyTheGeometryKeys() throws {
        let request = try writeRequest(job: "m1")
        let geometry = RFD3JobManager.Geometry(
            designCACAMean: 3.85, backboneValidPercent: 98.3,
            designRadiusOfGyration: 12.1, interfaceMinDistance: 3.0,
            contactsUnder8A: 154, hotspotMinDistance: 5.2, targetDriftMax: 0.0)
        RFD3JobManager.writeMetrics(request: request, geometry: geometry)
        let path = try XCTUnwrap(request.metricsPath)
        let payload = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        let values = try XCTUnwrap(payload?["values"] as? [[String: Any]])
        let keys = Set(values.compactMap { $0["key"] as? String })
        // The exact set `modules/pymol/generators/metrics.py` declares as GEOMETRY_SPECS.
        // Asserted as a SET EQUALITY, not a containment: a key written here but not
        // declared there is dropped silently by the metric store, and a key declared there
        // but never written is a number the schema promises and nothing produces.
        XCTAssertEqual(keys, ["design_ca_ca_mean", "backbone_valid_pct",
                              "design_radius_of_gyration", "interface_min_distance",
                              "contacts_under_8a", "hotspot_min_distance",
                              "target_drift_max"])
        // Elapsed time and peak memory reach the store through the STATUS file. Sending
        // them here too would be two sources that can disagree.
        XCTAssertFalse(keys.contains("elapsed_s"))
        XCTAssertFalse(keys.contains("peak_bytes"))
        XCTAssertEqual(payload?["tool"] as? String, "rfd3")
    }

    func testNoMetricsPathMeansNoFileRatherThanACrash() throws {
        // Optional at this end for the same reason every other field is: a Python side that
        // predates it writes no key, and the run must still be recorded from the status.
        let url = dir.appendingPathComponent("raymol_predict_req_m2.json")
        var payload: [String: Any] = [
            "job_id": "m2", "weights_dir": dir.path, "chains": [], "runtime": "rfd3",
            "recycling_steps": 2, "diffusion_steps": 200, "seed": 0,
            "out_path": dir.appendingPathComponent("m2.pdb").path,
            "status_path": dir.appendingPathComponent("m2.json").path,
        ]
        payload["target"] = [residue("A", "45", "TRP")]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let request = try InferenceJob.parseRequest(at: url)
        XCTAssertNil(request.metricsPath)
        RFD3JobManager.writeMetrics(
            request: request,
            geometry: RFD3JobManager.Geometry(
                designCACAMean: 0, backboneValidPercent: 0, designRadiusOfGyration: 0,
                interfaceMinDistance: 0, contactsUnder8A: 0, hotspotMinDistance: 0,
                targetDriftMax: 0))
    }

    // MARK: The naming rule

    func testNoUserFacingStringCallsTheOutputABinder() throws {
        // A generated chain is a DESIGNED BACKBONE until a refold and an interface gate say
        // otherwise -- a product rule, not a wording preference, because generation alone
        // does not license the word. Enforced by grep rather than by review, over the files
        // that produce user-visible text.
        //
        // RFD3Kit's OWN API spells it `designBinder` / `binderSequence` / `binderLength`,
        // and those call sites are unavoidable, so they are the only allowance.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // PyMOLViewerTests
            .deletingLastPathComponent()          // swiftui
            .appendingPathComponent("PyMOLViewer/Shared")
        let upstreamSymbols = ["designBinder", "binderSequence", "binderLength",
                               "binderCACAmeanA", "binderToHotspotMinA"]
        for name in ["RFD3JobManager.swift", "RFD3ResultWriter.swift",
                     "RFD3SizeGuard.swift", "RFD3Runtime.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name),
                                  encoding: .utf8)
            for (number, line) in text.split(separator: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments are exempt, and only comments: the rule is about what the
                // product SAYS -- a UI string, an object name, a metric label -- not about
                // whether the code may explain the rule or name the upstream API it wraps.
                if trimmed.hasPrefix("//") { continue }
                guard line.lowercased().contains("binder") else { continue }
                let allowed = upstreamSymbols.contains { line.contains($0) }
                XCTAssertTrue(allowed,
                              "\(name):\(number + 1) says \"binder\" outside an upstream "
                              + "symbol: \(line)")
            }
        }
    }
}
#endif
