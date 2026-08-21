import XCTest
@testable import RayMol

/// The screen-awake policy. Pure by construction (see `PredictScreenAwake`), so the iOS
/// rule is testable from the macOS test host — the side effect it drives is one
/// assignment and is not what can be got wrong.
final class PredictScreenAwakeTests: XCTestCase {

    private func job(_ id: String, state: String) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: "diffusion", fraction: 0.5,
                           moving: true, detail: "", modelsDone: 0, modelsTotal: 1,
                           elapsed: 1, error: nil)
    }

    func testIdleReleasesTheScreen() {
        XCTAssertFalse(PredictScreenAwake.shouldStayAwake(predictions: [],
                                                           weightsFetching: false))
    }

    func testARunningFoldHoldsTheScreen() {
        XCTAssertTrue(
            PredictScreenAwake.shouldStayAwake(predictions: [job("m1", state: "running")],
                                                weightsFetching: false))
    }

    /// The 529 MB first-run download is minutes of foreground-only work with no input —
    /// the same shape as a fold, and the same failure if iOS sleeps the display. It must
    /// hold the screen on its own, with no prediction job yet in flight.
    func testAWeightDownloadAloneHoldsTheScreen() {
        XCTAssertTrue(PredictScreenAwake.shouldStayAwake(predictions: [],
                                                          weightsFetching: true))
    }

    /// A cancelled job is terminal, so the screen must be released at once rather than
    /// held until the user dismisses the card. `isError` covers cancelled, which is what
    /// makes this fall out — pinned here because that is a subtle thing to rely on.
    func testTerminalJobsReleaseTheScreen() {
        for state in ["error", "failed", "cancelled"] {
            XCTAssertFalse(
                PredictScreenAwake.shouldStayAwake(predictions: [job("m1", state: state)],
                                                    weightsFetching: false),
                "a \(state) job is terminal and must not hold the display on")
        }
    }

    /// One live job among finished ones still holds the screen — the guard is "any
    /// running", not "the newest".
    func testOneLiveJobAmongTerminalOnesStillHolds() {
        let jobs = [job("a", state: "cancelled"),
                    job("b", state: "running"),
                    job("c", state: "error")]
        XCTAssertTrue(PredictScreenAwake.shouldStayAwake(predictions: jobs,
                                                          weightsFetching: false))
    }

    // MARK: - The job-owned hold

    override func setUp() {
        super.setUp()
        PredictScreenAwake.resetJobHoldsForTesting()
    }

    override func tearDown() {
        PredictScreenAwake.resetJobHoldsForTesting()
        super.tearDown()
    }

    /// The authoritative path: BoltzJobManager takes the hold the instant a fold starts,
    /// not when the object-panel poll notices one. The view path was too slow — a
    /// 110-residue run was observed freezing at diffusion step 42 of 200 because the
    /// phone locked inside the ~500 ms gap.
    func testAJobTakesAndReleasesTheHold() {
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 0)
        PredictScreenAwake.setJobActive(true)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 1)
        PredictScreenAwake.setJobActive(false)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 0)
    }

    /// Counted, not a flag: n_models > 1 and queued jobs overlap, and the display must
    /// stay pinned until the LAST one finishes.
    func testOverlappingJobsHoldUntilTheLastOneFinishes() {
        PredictScreenAwake.setJobActive(true)
        PredictScreenAwake.setJobActive(true)
        PredictScreenAwake.setJobActive(false)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 1,
                       "one fold finishing must not release the other's hold")
        PredictScreenAwake.setJobActive(false)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 0)
    }

    /// An unbalanced release must not drive the count negative — that would make the next
    /// genuine hold a no-op and silently reintroduce the freeze this fixes.
    func testUnbalancedReleaseCannotGoNegative() {
        PredictScreenAwake.setJobActive(false)
        PredictScreenAwake.setJobActive(false)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 0)
        PredictScreenAwake.setJobActive(true)
        XCTAssertEqual(PredictScreenAwake.activeJobHolds, 1,
                       "a real hold after stray releases must still hold")
    }
}
