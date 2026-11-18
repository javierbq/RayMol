#if os(macOS)
import XCTest
import RFD4Core
import RFD4MLX
@testable import RayMol

/// The `rfd4` runtime seam: a request names the backend that must run it, the router hands
/// it to exactly one manager, and everything a generator's request adds to the wire is
/// OPTIONAL so a Python/Swift skew degrades to a refusal rather than "malformed request".
///
/// Payloads are built as JSON and decoded through `InferenceJob.parseRequest`, never
/// constructed with the memberwise initialiser: the thing under test is the wire contract
/// with `pymol.generators.rfd4`, and a hand-built struct would only prove the decoder
/// agrees with itself.
///
/// What this file pins beyond RFD3's equivalent is the pair of places the two runtimes must
/// NOT be confused: the router must give each its own requests, and the metric keys must
/// differ, because RFD4 rebuilds its target where RFD3 holds it fixed.
final class RFD4RuntimeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rfd4-runtime-tests-\(UUID().uuidString)")
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

    /// Exactly the keys `pymol.generators.rfd4.submit` writes, so a change on either side
    /// breaks here rather than in front of a user. Note what is NOT here: no `live_view`,
    /// because this engine's step hook carries no coordinates and there is nothing to
    /// stream.
    private func writeRequest(job: String, runtime: String? = "rfd4",
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
            // The two decoder-compatibility fields. `rfd4.py` sends the flow-step count it
            // actually runs, and a 1 for recycling precisely so nobody reads it as a
            // setting — this model's recycling is a per-band schedule with no scalar form.
            "recycling_steps": 1,
            "diffusion_steps": 60,
            "seed": 7,
            "out_path": dir.appendingPathComponent("\(job).pdb").path,
            "status_path": dir.appendingPathComponent("\(job).json").path,
            "object_name": "rfd4_design_abcd1234",
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
        let request = try writeRequest(job: "j1")
        XCTAssertEqual(request.runtime, "rfd4")
        XCTAssertEqual(request.target?.count, 2)
        XCTAssertEqual(request.target?.first?.chain, "A")
        // The insertion code survives because `resi` is a STRING on both sides. Routed
        // through a PDB reader instead, 45 and 45A would have merged into one residue.
        XCTAssertEqual(request.target?.first?.resi, "45")
        XCTAssertEqual(request.target?.first?.resn, "TRP")
        XCTAssertEqual(request.hotspots, [0])
        XCTAssertEqual(request.designLength, 30)
        XCTAssertEqual(request.designChain, "B")
        XCTAssertEqual(request.designKey, "deadbeefdeadbeef")
        XCTAssertEqual(request.seed, 7)
    }

    func testAnInsertionCodeSurvivesTheWire() throws {
        let request = try writeRequest(
            job: "j1a", target: [residue("A", "45A", "TRP"), residue("A", "45B", "SER")])
        XCTAssertEqual(request.target?.map(\.resi), ["45A", "45B"])
    }

    func testAnAbsentLiveViewFlagMeansOff() throws {
        // `rfd4.py` writes no `live_view` key at all, and absent must read as off rather
        // than as malformed: there is nothing to stream from this engine.
        let request = try writeRequest(job: "j2")
        XCTAssertNotEqual(request.liveView, true)
    }

    // MARK: Routing

    func testTheRouterClaimsRFD4AndOnlyRFD4() throws {
        let names = InferenceRouter.runtimes.map { type(of: $0).runtimeName }
        XCTAssertTrue(names.contains("rfd4"), "rfd4 must be routable")
        // Exactly one claimant. Two would make dispatch depend on table order, and
        // running one method's request on another's featurizer does not fail — it
        // tokenizes with the wrong featurizer and returns a confident wrong answer.
        XCTAssertEqual(names.filter { $0 == "rfd4" }.count, 1)
        // And it is a DIFFERENT object from the rfd3 manager, which is the mistake a
        // copy-pasted registration makes.
        XCTAssertFalse(RFD4JobManager.shared === RFD3JobManager.shared as AnyObject)
        XCTAssertNotEqual(RFD4JobManager.runtimeName, RFD3JobManager.runtimeName)
    }

    func testTheRuntimeNameMatchesWhatTheBridgeAdvertises() throws {
        // `PyMOLBridge.mm` sets RAYMOL_PREDICT_RUNTIMES, and `check_available` refuses on
        // it BEFORE an 807 MB download. A name that disagreed with this one would offer a
        // method whose Swift half is not in the binary.
        XCTAssertEqual(RFD4JobManager.runtimeName, "rfd4")
    }

    func testCancelIsSafeForAJobThisManagerNeverHad() throws {
        // A cancel marker carries only a job id, so it is broadcast to every runtime.
        // Each must keep only its own, and must not crash on someone else's.
        RFD4JobManager.shared.cancel(jobID: "a-job-that-does-not-exist-\(UUID())")
    }

    // MARK: Shape preflight

    func testAValidGeneratorRequestPassesShapePreflight() throws {
        XCTAssertNil(RFD4JobManager.preflight(try writeRequest(job: "j3")))
    }

    func testAForeignRuntimeIsRefusedByThisManagerToo() throws {
        // Unreachable through the router, which dispatches on this very field. Refused
        // anyway so a future caller cannot quietly run a Boltz request through a
        // generator's featurizer.
        let status = RFD4JobManager.preflight(try writeRequest(job: "j4", runtime: "boltz"))
        XCTAssertEqual(status?.state, "failed")
        XCTAssertTrue(status?.error?.contains("rfd4") == true)
    }

    func testATargetlessRequestIsRefused() throws {
        let status = RFD4JobManager.preflight(try writeRequest(job: "j5", target: []))
        XCTAssertEqual(status?.state, "failed")
        XCTAssertTrue(status?.error?.contains("target") == true)
    }

    func testAHotspotOutsideTheTargetIsRefusedByIndex() throws {
        let status = RFD4JobManager.preflight(try writeRequest(job: "j6", hotspots: [0, 9]))
        XCTAssertEqual(status?.state, "failed")
        XCTAssertTrue(status?.error?.contains("9") == true)
    }

    func testNoHotspotsAtAllIsAcceptedAsUnguidedPlacement() throws {
        // An empty set is a mode the featurizer supports directly, not an omission. The
        // floor that would refuse it would be OURS rather than the engine's.
        XCTAssertNil(RFD4JobManager.preflight(try writeRequest(job: "j7", hotspots: [])))
        XCTAssertNil(RFD4JobManager.preflight(try writeRequest(job: "j8", hotspots: nil)))
    }

    func testAZeroLengthDesignIsRefused() throws {
        let status = RFD4JobManager.preflight(try writeRequest(job: "j9", designLength: 0))
        XCTAssertEqual(status?.state, "failed")
    }

    func testAnAtomlessTargetResidueIsRefusedByName() throws {
        let empty: [String: Any] = ["chain": "A", "resi": "47", "resn": "GLY", "atoms": []]
        let status = RFD4JobManager.preflight(
            try writeRequest(job: "j10", target: [residue("A", "45", "TRP"), empty]))
        XCTAssertEqual(status?.state, "failed")
        XCTAssertTrue(status?.error?.contains("47") == true)
    }

    // MARK: The schedule is not a request field

    func testTheScheduleComesFromThePortRatherThanTheRequest() throws {
        // 60 flow steps, taken from `ReleasedRecycleStrategy.nsteps`. Reading
        // `request.diffusionSteps` instead would let a stale or hand-written request
        // misreport the progress denominator — and worse, suggest the count is a knob
        // when every released strategy's recycle bands are indexed against those 60.
        XCTAssertEqual(RFD4JobManager.flowSteps, ReleasedRecycleStrategy.nsteps)
        XCTAssertEqual(RFD4JobManager.flowSteps, 60)
        XCTAssertEqual(RFD4JobManager.strategy, .thinkingMedium)
    }

    // MARK: Metrics

    func testTheMetricsDocumentCarriesExactlyTheGeometryKeys() throws {
        let request = try writeRequest(job: "j11")
        RFD4JobManager.writeMetrics(
            request: request,
            geometry: RFD4JobManager.Geometry(
                designCACAMean: 3.81, backboneValidPercent: 97.4,
                designRadiusOfGyration: 11.8, interfaceMinDistance: 4.2,
                contactsUnder8A: 132, hotspotMinDistance: 5.1,
                targetRebuildRMSD: 0.84))
        let data = try Data(contentsOf: URL(fileURLWithPath: request.metricsPath!))
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let values = payload?["values"] as? [[String: Any]] ?? []
        let keys = Set(values.compactMap { $0["key"] as? String })

        // The exact set `modules/pymol/generators/metrics.py` declares as
        // RFD4_GEOMETRY_SPECS. Asserted as a SET EQUALITY, not a containment: a key
        // written here but not declared there is dropped silently by the metric store,
        // and a key declared there but never written is a number the schema promises and
        // nothing produces.
        XCTAssertEqual(keys, ["design_ca_ca_mean", "backbone_valid_pct",
                              "design_radius_of_gyration", "interface_min_distance",
                              "contacts_under_8a", "hotspot_min_distance",
                              "target_rebuild_rmsd"])
        // THE KEY THAT MUST NOT BE HERE. RFD3's `target_drift_max` declares `lo=0` and is
        // documented as "0.000 A on a correct run, and a bug on any other", because there
        // the target is held fixed. This model GENERATES its target, so a correct run
        // reads non-zero — and writing it under that key would brand every correct design
        // a defect.
        XCTAssertFalse(keys.contains("target_drift_max"))
        // Elapsed time and peak memory reach the store through the STATUS file. Sending
        // them here too would be two sources that can disagree.
        XCTAssertFalse(keys.contains("elapsed_s"))
        XCTAssertFalse(keys.contains("peak_bytes"))
        XCTAssertEqual(payload?["tool"] as? String, "rfd4")
    }

    func testAnUnmeasuredDistanceIsAbsentRatherThanZero() throws {
        // Both distances are optional, and for the same reason: 0.0 on a
        // `higher_is_better=false` distance is the BEST possible score, recorded for
        // something that was never measured. An unguided run has no hotspot to measure
        // to, and a design with no CA has no interface to measure across.
        let unguided = RFD4JobManager.Geometry(
            designCACAMean: 3.81, backboneValidPercent: 97.4,
            designRadiusOfGyration: 11.8, interfaceMinDistance: 4.2,
            contactsUnder8A: 132, hotspotMinDistance: nil, targetRebuildRMSD: 0.84)
        let keys = Set(unguided.metricValues.compactMap { $0["key"] as? String })
        XCTAssertFalse(keys.contains("hotspot_min_distance"))
        XCTAssertTrue(keys.contains("interface_min_distance"))

        let unmeasured = RFD4JobManager.Geometry(
            designCACAMean: 3.81, backboneValidPercent: 97.4,
            designRadiusOfGyration: 11.8, interfaceMinDistance: nil,
            contactsUnder8A: 0, hotspotMinDistance: nil, targetRebuildRMSD: 0.84)
        let fewer = Set(unmeasured.metricValues.compactMap { $0["key"] as? String })
        XCTAssertFalse(fewer.contains("interface_min_distance"))
        // The rebuild RMSD is NOT optional: it is measured on every run that got far
        // enough to be emitted at all, and an absent one would hide a bad placement.
        XCTAssertTrue(fewer.contains("target_rebuild_rmsd"))
    }

    func testNoMetricsPathMeansNoFileRatherThanACrash() throws {
        // Optional at this end for the reason every other field is: a Python side that
        // predates it writes no key, and the run must still be recorded from the status.
        var payload: [String: Any] = [
            "job_id": "j12", "weights_dir": dir.path, "chains": [],
            "recycling_steps": 1, "diffusion_steps": 60, "seed": 0,
            "out_path": dir.appendingPathComponent("j12.pdb").path,
            "status_path": dir.appendingPathComponent("j12.json").path,
            "runtime": "rfd4",
        ]
        payload["target"] = [residue("A", "45", "TRP")]
        let url = dir.appendingPathComponent("raymol_predict_req_j12.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let request = try InferenceJob.parseRequest(at: url)
        XCTAssertNil(request.metricsPath)
        RFD4JobManager.writeMetrics(
            request: request,
            geometry: RFD4JobManager.Geometry(
                designCACAMean: 3.81, backboneValidPercent: 97.4,
                designRadiusOfGyration: 11.8, interfaceMinDistance: 4.2,
                contactsUnder8A: 132, hotspotMinDistance: 5.1,
                targetRebuildRMSD: 0.84))
    }

    // MARK: Naming

    func testNoUserFacingStringCallsTheOutputABinder() throws {
        // The naming split from `generators/base`: the TOOL may be called Binder Design,
        // the OUTPUT may not be called a binder until a refold and an interface gate say
        // so. The port's own API says `binder` in places; this is where that stops.
        let request = try writeRequest(job: "j13")
        let keys = RFD4JobManager.Geometry(
            designCACAMean: 3.81, backboneValidPercent: 97.4,
            designRadiusOfGyration: 11.8, interfaceMinDistance: 4.2,
            contactsUnder8A: 132, hotspotMinDistance: 5.1, targetRebuildRMSD: 0.84)
            .metricValues.compactMap { $0["key"] as? String }
        for key in keys {
            XCTAssertFalse(key.lowercased().contains("binder"), "metric key \(key)")
        }
        XCTAssertFalse(RFD4SizeGuard.refusalMessage(
            tokens: 900, predictedBytes: Int(14e9), budgetBytes: Int(9e9),
            maxTokens: 700).lowercased().contains("binder"))
        // The REMARKs travel with an exported file, so they are user-facing too. They
        // cannot be built without a `Result`, whose memberwise init is internal to the
        // port, so what is checkable here is the half that does not need one.
        XCTAssertFalse(request.objectName!.lowercased().contains("binder"))
    }
}
#endif
