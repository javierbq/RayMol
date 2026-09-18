import XCTest
@testable import RayMol

/// #463's two value types, which is the whole of what the tool bars decide: what a run
/// will create, and what of this tool's work is running. The views over them are a
/// `Text`, a `ProgressView` and two buttons, so everything worth pinning is here.
///
/// The last group is the compatibility contract and the reason it is a test rather than
/// a claim: with no batch running and no sets in the session, both bars must be what
/// they were before #463 — `forTools` returns `[]`, so neither the progress row nor its
/// divider is built at all.
final class ToolSetStatusTests: XCTestCase {

    // MARK: fixtures

    private func set(_ name: String, id: String, tool: String = "rfd3", count: Int = 1000,
                     staged: Int = 6, running: BatchProgress? = nil) -> SetEntry {
        SetEntry(id: id, name: name, kind: "structures", tool: tool, count: count,
                 stagedCount: staged, budget: 6, groupName: name, reference: "4HHB",
                 rankingKey: "", sortKey: "", sortDescending: true, filter: "",
                 columns: [], histogram: [], views: [], running: running)
    }

    private func job(_ id: String, batch: String?, state: String = "running",
                     runRemaining: Double? = nil) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: "diffusion", fraction: 0.4,
                           moving: true, detail: "d", modelsDone: 0, modelsTotal: 1,
                           elapsed: 60, error: nil, bundle: nil, step: 80,
                           totalSteps: 200, remaining: 30, batch: batch,
                           batchIndex: 1, batchTotal: 1000, runRemaining: runRemaining)
    }

    // MARK: what the run will create

    func testTheBarDeclaresEntriesAndHowManyAreStaged() {
        let plan = PlannedSet(entries: 1000, stageBudget: 6)
        XCTAssertEqual(plan.staged, 6)
        XCTAssertEqual(plan.summary, "→ a new set · 1000 entries · 6 staged as they land")
    }

    /// #416 makes a set for a single design too (spec §8 decision 1). A line that went
    /// away at n = 1 would teach that a lone design is not in one.
    func testASingleDesignStillDeclaresItsSet() {
        XCTAssertEqual(PlannedSet(entries: 1, stageBudget: 6).summary,
                       "→ a new set · 1 entry · 1 staged as it lands")
    }

    func testNothingMoreThanTheBatchCanBeStaged() {
        let plan = PlannedSet(entries: 3, stageBudget: 6)
        XCTAssertEqual(plan.staged, 3)
        XCTAssertEqual(plan.summary, "→ a new set · 3 entries · 3 staged as they land")
    }

    func testABudgetOfZeroStagesNothingAndSaysSo() {
        XCTAssertEqual(PlannedSet(entries: 4, stageBudget: 0).summary,
                       "→ a new set · 4 entries · none staged")
    }

    /// The finding, pinned: the set's name is a digest over a seed that is drawn at
    /// submit, so the bar promises no name. A future refactor that "helpfully" filled
    /// one in would be displaying a name that can differ from the one created.
    func testNoNameIsPromisedBeforeTheRunStarts() {
        let plan = PlannedSet(entries: 10, stageBudget: 6)
        XCTAssertTrue(plan.summary.hasPrefix("→ a new set"))
        XCTAssertFalse(plan.summary.contains("“"), "no quoted name may appear")
        XCTAssertTrue(plan.nameNote.contains("seed"),
                      "the tooltip has to say WHY there is no name")
    }

    // MARK: which batch belongs to which bar

    func testABatchIsMatchedToTheBarThatDrivesItsTool() {
        let mine = set("rfd3_a1", id: "s1",
                       running: BatchProgress(done: 312, total: 1000, tool: "rfd3"))
        let theirs = set("boltz2_1", id: "s2", tool: "boltz2",
                         running: BatchProgress(done: 2, total: 5, tool: "boltz2"))
        let rows = RunningToolBatch.forTools(["rfd3"], sets: [mine, theirs])
        XCTAssertEqual(rows.map(\.setID), ["s1"])
        XCTAssertEqual(rows.first?.detail, "312 / 1000 · 6 staged")
        XCTAssertEqual(rows.first?.fraction, 0.312)
    }

    /// A set with no batch is not a running batch, however many entries it has.
    func testASettledSetIsNotAProgressRow() {
        XCTAssertTrue(RunningToolBatch.forTools(["rfd3"], sets: [set("rfd3_a1", id: "s1")])
                        .isEmpty)
    }

    /// The marker drops the counts — and with them the tool — before it drops the sets.
    /// The set's own `tool` column says the same thing, from the file, so the row
    /// survives truncation as a spinner.
    func testATruncatedMarkerStillFindsTheBarByTheSetsOwnTool() {
        let entry = set("rfd3_a1", id: "s1", running: BatchProgress.unknown)
        let rows = RunningToolBatch.forTools(["rfd3"], sets: [entry], countsKnown: false)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.fraction, "no confident bar without counts")
        XCTAssertEqual(rows.first?.detail, "landing… · 6 staged")
    }

    /// Two batches of one tool: the newest takes the row, the rest are the +N menu.
    /// "Newest" is the container's creation order, which is the order `sets()` reads.
    func testTheNewestBatchOfAToolTakesTheRow() {
        let older = set("rfd3_a1", id: "s1",
                        running: BatchProgress(done: 900, total: 1000, tool: "rfd3"))
        let newer = set("rfd3_a2", id: "s2",
                        running: BatchProgress(done: 1, total: 4, tool: "rfd3"))
        XCTAssertEqual(RunningToolBatch.forTools(["rfd3"], sets: [older, newer]).map(\.setID),
                       ["s2", "s1"])
    }

    // MARK: the estimate and the Cancel target

    /// The estimate is `designing._run_remaining` — measured wall times of the designs
    /// that already finished — carried on the job record, never computed here.
    func testTheEstimateComesFromTheJobThatCarriesIt() {
        let entry = set("rfd3_a1", id: "s1",
                        running: BatchProgress(done: 312, total: 1000, tool: "rfd3"))
        let rows = RunningToolBatch.forTools(
            ["rfd3"], sets: [entry],
            jobs: [job("rfd3_design_1", batch: "rfd3_a1", runRemaining: 7200)])
        XCTAssertEqual(rows.first?.remaining, 7200)
        XCTAssertEqual(rows.first?.detail, "312 / 1000 · 6 staged · over an hour left")
    }

    /// No job on the wire (a single design, whose set names no group) and no estimate —
    /// `done / total` alone rather than a number derived from a guess.
    func testWithNothingToPriceItThereIsNoEstimate() {
        let entry = set("rfd3_b1", id: "s1", count: 1, staged: 1,
                        running: BatchProgress(done: 0, total: 1, tool: "rfd3"))
        let rows = RunningToolBatch.forTools(["rfd3"], sets: [entry],
                                             jobs: [job("rfd3_design_1", batch: nil,
                                                        runRemaining: 600)])
        XCTAssertNil(rows.first?.remaining)
        XCTAssertNil(rows.first?.cancelJob, "nothing on the wire answers to the set name")
        XCTAssertEqual(rows.first?.detail, "0 / 1 · 1 staged")
    }

    /// `design_cancel` takes the GROUP name of a batch, and that group name is the set
    /// name. A live job naming this set as its batch is the proof the name is a job id.
    func testCancelTargetsTheSetNameOnlyWhenAJobAnswersToIt() {
        let entry = set("rfd3_a1", id: "s1",
                        running: BatchProgress(done: 3, total: 10, tool: "rfd3"))
        let live = RunningToolBatch.forTools(["rfd3"], sets: [entry],
                                             jobs: [job("d1", batch: "rfd3_a1")])
        XCTAssertEqual(live.first?.cancelJob, "rfd3_a1")
        // A settled member is still on the wire until it is dismissed; it cannot be
        // cancelled and its numbers are frozen, so it does not count as live.
        let settled = RunningToolBatch.forTools(
            ["rfd3"], sets: [entry],
            jobs: [job("d1", batch: "rfd3_a1", state: "cancelled", runRemaining: 99)])
        XCTAssertNil(settled.first?.cancelJob)
        XCTAssertNil(settled.first?.remaining)
    }

    // MARK: the compatibility contract

    func testWithNoSetsInTheSessionTheBarsAreUntouched() {
        XCTAssertTrue(RunningToolBatch.forTools(["rfd3", "boltz2"], sets: []).isEmpty)
    }

    func testABarThatDrivesNoToolYetShowsNothing() {
        let entry = set("rfd3_a1", id: "s1",
                        running: BatchProgress(done: 1, total: 2, tool: "rfd3"))
        XCTAssertTrue(RunningToolBatch.forTools([], sets: [entry]).isEmpty)
        XCTAssertTrue(RunningToolBatch.forTools([""], sets: [entry]).isEmpty)
    }
}
