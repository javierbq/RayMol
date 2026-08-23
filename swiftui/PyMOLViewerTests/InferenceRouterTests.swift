#if os(macOS)
import XCTest
@testable import RayMol

/// The dispatcher, now that it is neutral ground rather than a static on one of its own
/// targets.
///
/// Two properties here were previously carried by nothing but the shape of a hand-written
/// branch per runtime:
///
/// * **Routable implies cancellable.** `submit` and `cancel` read the SAME table, so a
///   runtime cannot be added to one path and forgotten in the other. A runtime that is
///   routable but not cancellable is a job the user cannot stop — seventeen minutes of it
///   for a design.
/// * **An unrouted runtime is refused BY NAME**, not silently accepted and not left
///   reporting `queued` forever. That is how a Python side offering a method this build did
///   not link gets a real error.
final class InferenceRouterTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inference-router-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func name(of runtime: any InferenceRuntime) -> String {
        type(of: runtime).runtimeName
    }

    // MARK: The table

    /// `Request.runtime` is optional and absent means Boltz — every Python side that
    /// predates a second runtime wrote no such key.
    func testARequestNamingNoRuntimeMeansBoltz() {
        XCTAssertEqual(name(of: InferenceRouter.defaultRuntime),
                       BoltzJobManager.runtimeName)
    }

    /// The default must ALSO be a table entry, or a cancel for the commonest kind of job —
    /// one that named no runtime at all — would never be broadcast to the manager running
    /// it.
    func testTheDefaultRuntimeIsItselfInTheTable() {
        XCTAssertTrue(
            InferenceRouter.runtimes.contains { $0 === InferenceRouter.defaultRuntime },
            "the default runtime is reachable by submit but not by cancel")
    }

    /// Two entries sharing a name would make routing depend on table order, which nothing
    /// declares.
    func testEveryLinkedRuntimeHasADistinctName() {
        let names = InferenceRouter.runtimes.map(name(of:))
        XCTAssertEqual(names.count, Set(names).count, "duplicate runtime name in \(names)")
    }

    /// What this macOS build actually links. Fails when a runtime is added to the app and
    /// not to the table — the state in which it is neither routable nor cancellable.
    func testTheTableCarriesEveryRuntimeThisBuildLinks() {
        XCTAssertEqual(Set(InferenceRouter.runtimes.map(name(of:))),
                       ["boltz", "protenix", "rfd3"])
    }

    // MARK: Cancel reaches the whole table

    /// A cancel marker carries only a job id, so there is nothing in it to route on: it
    /// must reach EVERY runtime, not just the first or the default.
    ///
    /// Asserted through `protenix` AND `rfd3`, neither of which is the first entry or the
    /// default — so a broadcast that stopped early would fail here. `rfd3` is the one that
    /// matters most: a design the user cannot cancel is seventeen minutes of it.
    func testACancelMarkerReachesEveryRuntimeNotJustTheDefault() {
        let jobID = "router-cancel-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(ProtenixJobManager.shared.cancelRequestedForTesting.contains(jobID))
        XCTAssertFalse(RFD3JobManager.shared.cancelRequestedForTesting.contains(jobID))

        InferenceRouter.handle(marker: "PREDICT:cancel:\(jobID)")

        XCTAssertTrue(ProtenixJobManager.shared.cancelRequestedForTesting.contains(jobID),
                      "the cancel broadcast stopped before reaching every runtime")
        XCTAssertTrue(RFD3JobManager.shared.cancelRequestedForTesting.contains(jobID),
                      "the cancel broadcast stopped before reaching every runtime")
        // ...and the default saw it too, from the same one loop.
        XCTAssertTrue(BoltzJobManager.shared.cancelRequestedForTesting.contains(jobID))
    }

    // MARK: Refusals

    /// A runtime nothing implements must reach a refusal that NAMES it. Refused inside
    /// Boltz's preflight, which runs before any sizing and before MLX is touched, so this
    /// test costs nothing.
    func testARuntimeThisBuildDoesNotCarryIsRefusedByName() throws {
        let jobID = "router-unknown-\(UUID().uuidString.prefix(8))"
        let statusPath = dir.appendingPathComponent("\(jobID).json")
        // No `object_name`: a refusal for a job with a placeholder would hop into
        // PyMOLEngine, which a unit test must not do.
        let payload: [String: Any] = [
            "job_id": jobID, "weights_dir": dir.path, "chains": [],
            "runtime": "nosuchruntime",
            "recycling_steps": 1, "diffusion_steps": 1, "seed": 0,
            "out_path": dir.appendingPathComponent("\(jobID).pdb").path,
            "status_path": statusPath.path,
        ]
        let requestURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_req_\(jobID).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: requestURL)
        defer { try? FileManager.default.removeItem(at: requestURL) }

        InferenceRouter.handle(marker: "PREDICT:submit:\(jobID)")

        let status = try JSONDecoder().decode(
            InferenceJob.Status.self, from: Data(contentsOf: statusPath))
        XCTAssertEqual(status.state, "failed")
        XCTAssertTrue(status.error?.contains("nosuchruntime") ?? false,
                      "the refusal must name the runtime: \(status.error ?? "nil")")
    }
}
#endif
