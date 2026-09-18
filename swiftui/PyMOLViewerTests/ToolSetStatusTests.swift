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

    // MARK: the run that does NOT create a set (#463 review, fix 1)

    /// An identical re-run extends the set the first one made — `batch.name_taken` says
    /// False for the same tool against the same reference — so "a new set" was false,
    /// and so was the staged count: the free slots are `budget - staged`, not `budget`.
    /// Measured with seed 7 and count 4: one set, 8 entries, 2 of the 4 new designs
    /// staged. `testing/tests/sets/sets_batch.py::PlanPreviewTest` pins the Python that
    /// this wording is about.
    func testAnIdenticalRerunSaysItExtendsAndCountsOnlyTheFreeSlots() {
        let plan = PlannedSet(entries: 4, stageBudget: 6,
                              extending: .init(name: "rfd3_batch_1f4c9e02", stagedNow: 4))
        XCTAssertEqual(plan.staged, 2, "budget 6 less the 4 already staged")
        XCTAssertEqual(plan.summary,
                       "→ extends “rfd3_batch_1f4c9e02” · 4 entries · 2 staged as they land")
    }

    /// The set being extended is already at its budget: the entries are still written,
    /// and `binder_design` says "budget full" per landing, so the line must not promise
    /// an object. (A budget of 0 on a NEW set is unreachable — `set_budget` refuses
    /// below 1 — so this is the only way this branch is reached in practice.)
    func testExtendingAFullSetStagesNothingAndSaysSo() {
        let plan = PlannedSet(entries: 4, stageBudget: 2,
                              extending: .init(name: "camp", stagedNow: 2))
        XCTAssertEqual(plan.staged, 0)
        XCTAssertEqual(plan.summary,
                       "→ extends “camp” · 4 entries · none staged, the budget is full")
    }

    /// The tooltip has to explain the extension too — "extends" is the surprising word
    /// and the reason it happens (same tool, same target, same options) is not on screen.
    func testTheTooltipExplainsAnExtension() {
        let note = PlannedSet(entries: 4, stageBudget: 6,
                              extending: .init(name: "camp", stagedNow: 4)).nameNote
        XCTAssertTrue(note.contains("camp"))
        XCTAssertTrue(note.contains("appends"))
    }

    /// What Python answered, decoded: `extends` plus a name is an extension, an empty
    /// name never is (it is the "cannot be known, and therefore new" case), and the
    /// budget comes from the plan rather than from the file default when there is one.
    func testThePlanFromPythonDecidesTheWording() {
        let extend = PlannedSet(entries: 3,
                                plan: DesignSetPlan(name: "camp", extends: true,
                                                    budget: 4, staged: 1),
                                defaultBudget: 6)
        XCTAssertEqual(extend.stageBudget, 4, "the set's own budget column wins")
        XCTAssertEqual(extend.staged, 3)
        XCTAssertTrue(extend.summary.hasPrefix("→ extends “camp”"))

        let fresh = PlannedSet(entries: 3,
                               plan: DesignSetPlan(name: "", extends: false,
                                                   budget: 6, staged: 0),
                               defaultBudget: 6)
        XCTAssertNil(fresh.extending)
        XCTAssertEqual(fresh.summary, "→ a new set · 3 entries · 3 staged as they land")
    }

    /// No round trip has answered yet (or this build has no set store): the line is
    /// exactly what it was before the plan existed, rather than blank.
    func testWithNoPlanTheLineFallsBackToTheFileDefault() {
        let plan = PlannedSet(entries: 10, plan: nil, defaultBudget: 6)
        XCTAssertEqual(plan.summary, "→ a new set · 10 entries · 6 staged as they land")
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

    /// Two batches of one tool: the order is by SET ID and does not depend on which
    /// started first, so the row cannot change identity under the pointer when one of
    /// them starts or finishes — the hazard `ProgressTray.designBatch` was designed
    /// against (#463 review, fix 6). Asserted from both container orders, because
    /// "stable" is exactly the claim that the input order does not reach the output.
    func testTheRowKeepsItsIdentityWhateverOrderTheBatchesArrivedIn() {
        let a = set("rfd3_a1", id: "s1",
                    running: BatchProgress(done: 900, total: 1000, tool: "rfd3"))
        let b = set("rfd3_a2", id: "s2",
                    running: BatchProgress(done: 1, total: 4, tool: "rfd3"))
        XCTAssertEqual(RunningToolBatch.forTools(["rfd3"], sets: [a, b]).map(\.setID),
                       ["s1", "s2"])
        XCTAssertEqual(RunningToolBatch.forTools(["rfd3"], sets: [b, a]).map(\.setID),
                       ["s1", "s2"])
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

    // MARK: what each bar cancels with, and what it has to explain (fixes 4 and 5)

    /// Predict has NO batch-level cancel: `predicting.pending_info` publishes no
    /// `batch`, so nothing on the wire names a predict set, and `predict_cancel` takes
    /// one object name. Passing `"predict_cancel"` was inert only because `cancelJob` is
    /// always nil today; nil makes `predict_cancel('<set name>')` unreachable by
    /// construction once `predicting` does publish a batch.
    func testThePredictRowCarriesNoCancelCommandAtAll() {
        XCTAssertNil(ToolBatchStyle.predict.cancelFunction)
        XCTAssertEqual(ToolBatchStyle.design.cancelFunction, "design_cancel")
    }

    /// …and because it has none, it has to say where the work came from and where the
    /// per-fold Cancels are: a row in a tool's bar with no Cancel otherwise reads as
    /// "this cannot be cancelled", which is false.
    func testThePredictRowSaysWhereTheWorkCameFromAndWhereItsCancelsAre() {
        let note = ToolBatchStyle.predict.note
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.contains("progress tray"))
        XCTAssertTrue(note!.contains("console") || note!.contains("Data drawer"))
        XCTAssertNil(ToolBatchStyle.design.note, "the design row explains itself")
    }

    /// Both conditions, and the escaping, in one pure place.
    func testACancelRunsOnlyWhenThereIsACommandAndAJobToNameIt() {
        XCTAssertEqual(ToolBatchRow.cancelSource("design_cancel", "rfd3_a1"),
                       "from pymol import cmd as _c\n_c.design_cancel('rfd3_a1')")
        XCTAssertNil(ToolBatchRow.cancelSource(nil, "boltz2_1"),
                     "a tool with no batch cancel must compose nothing")
        XCTAssertNil(ToolBatchRow.cancelSource("design_cancel", nil))
        // A set name is a user string: it reaches Python as a literal, escaped.
        XCTAssertEqual(ToolBatchRow.cancelSource("design_cancel", "it's_1"),
                       "from pymol import cmd as _c\n_c.design_cancel('it\\'s_1')")
    }

    // MARK: the compatibility contract

    /// With nothing running, no progress row is built at all — so neither bar gains the
    /// row or its divider. (The Binder bar does gain its one `plannedSetRow` whenever
    /// Generate can fire; that line is #463's whole point and is pinned above.)
    func testWithNoSetsInTheSessionThereIsNoProgressRow() {
        XCTAssertTrue(RunningToolBatch.forTools(["rfd3", "boltz2"], sets: []).isEmpty)
    }

    func testABarThatDrivesNoToolYetShowsNothing() {
        let entry = set("rfd3_a1", id: "s1",
                        running: BatchProgress(done: 1, total: 2, tool: "rfd3"))
        XCTAssertTrue(RunningToolBatch.forTools([], sets: [entry]).isEmpty)
        XCTAssertTrue(RunningToolBatch.forTools([""], sets: [entry]).isEmpty)
    }
}
