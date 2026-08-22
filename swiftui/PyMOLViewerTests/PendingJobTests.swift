import XCTest
@testable import RayMol

final class PendingJobTests: XCTestCase {

    /// Captured from $TMPDIR/pymol_objpanel_<pid>.json during a real 2-model run.
    private let payload = """
    {"objects":["multi"],"selections":[],"enabled":[],"sel_counts":{},
     "nstate":{"multi":1},"has_transp":{"multi":false},"groups":[],"parent":{},
     "pending":{"multi":"pending: diffusion 64% (model 1 of 2)"},
     "pending_jobs":{"multi":{"state":"running","phase":"diffusion",
       "fraction":0.3196,"moving":true,
       "detail":"pending: diffusion 64% (model 1 of 2)",
       "models_done":0,"models_total":2,"elapsed":412.5,"error":null}}}
    """

    func testTheRecordDecodesFromARealPayload() throws {
        let decoded = try JSONDecoder().decode(
            PanelPayload.self, from: Data(payload.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["multi"])
        XCTAssertEqual(job.phase, "diffusion")
        XCTAssertEqual(job.fraction ?? 0, 0.3196, accuracy: 0.0001)
        XCTAssertTrue(job.moving)
        XCTAssertEqual(job.modelsTotal, 2)
        XCTAssertEqual(job.elapsed, 412.5, accuracy: 0.01)
        XCTAssertNil(job.error)
        XCTAssertFalse(job.isError)
    }

    /// An older bundled Python has no pending_jobs key. The object list must
    /// still decode -- otherwise the whole panel freezes on a stale list.
    func testAPayloadWithoutPendingJobsStillDecodes() throws {
        let old = """
        {"objects":["a"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"a":1},"has_transp":{"a":false},"groups":[],"parent":{},
         "pending":{}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.objects, ["a"])
        XCTAssertNil(decoded.pending_jobs)
    }

    /// A partially-populated record must not fail the WHOLE payload decode.
    func testARecordMissingOptionalFieldsStillDecodes() throws {
        let partial = """
        {"objects":["p"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"p":1},"has_transp":{"p":false},"groups":[],"parent":{},
         "pending":{"p":"pending"},
         "pending_jobs":{"p":{"state":"running","phase":"pending"}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(partial.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["p"])
        XCTAssertNil(job.fraction)
        XCTAssertFalse(job.moving)
        XCTAssertEqual(job.modelsTotal, 1)
    }

    /// boltz-mlx v0.2.1's per-step callback reaches the card through three new
    /// keys. All Optional: a phase with no steps, a Python older than this
    /// change, or a suppressed ETA must not fail the record.
    func testStepCountsAndTheEtaDecodeFromTheirSnakeCaseKeys() throws {
        let measured = """
        {"objects":["m"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"m":1},"has_transp":{"m":false},"groups":[],"parent":{},
         "pending":{"m":"pending: diffusion 64% step 84 of 200, 2 min left"},
         "pending_jobs":{"m":{"state":"running","phase":"diffusion",
           "fraction":0.6394,"moving":true,"detail":"pending: diffusion 64%",
           "models_done":0,"models_total":1,"elapsed":412.5,"error":null,
           "step":84,"total_steps":200,"remaining":138.1}}}
        """
        let decoded = try JSONDecoder().decode(
            PanelPayload.self, from: Data(measured.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["m"])
        XCTAssertEqual(job.step, 84)
        XCTAssertEqual(job.totalSteps, 200)
        XCTAssertEqual(job.remaining ?? 0, 138.1, accuracy: 0.01)
    }

    /// The increment-1 payload, replayed verbatim: none of the three keys exist.
    func testARecordWithoutStepCountsOrAnEtaStillDecodes() throws {
        let decoded = try JSONDecoder().decode(
            PanelPayload.self, from: Data(payload.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["multi"])
        XCTAssertNil(job.step)
        XCTAssertNil(job.totalSteps)
        XCTAssertNil(job.remaining)
    }

    /// The line the user actually reads. The percentage is the COMPOSED value --
    /// the same number the bar draws, so text and bar cannot disagree -- while
    /// "step 84 of 200" says where in the phase we are, and the countdown is the
    /// phase's own measured estimate rather than the elapsed clock, and SAYS which
    /// of the two it is (see formatPhaseRemaining).
    func testAMeasuredPredictionReadsAsPhasePercentStepModelAndEta() {
        let job = PredictionJobState(
            id: "p", state: "running", phase: "diffusion", fraction: 0.6394,
            moving: true, detail: "d", modelsDone: 0, modelsTotal: 3,
            elapsed: 412.5, error: nil, bundle: nil,
            step: 84, totalSteps: 200, remaining: 240)
        XCTAssertEqual(ProgressItem.prediction(job).detail,
                       "Diffusion 64% · step 84 of 200 · model 1 of 3 · "
                       + "this phase: 4 min left")
    }

    /// The defect the 1.10.0 hero capture shipped with: 20 models, 3 delivered,
    /// diffusion at step 141 of 200 and seconds from ending. "almost done" sat
    /// beside an overall 19% and "model 4 of 20", reading as if the whole run
    /// were finishing with sixteen models still to go.
    func testTheEtaDoesNotClaimTheWholeJobIsAlmostDone() {
        let job = PredictionJobState(
            id: "p", state: "running", phase: "diffusion", fraction: 0.1901,
            moving: true, detail: "d", modelsDone: 3, modelsTotal: 20,
            elapsed: 900, error: nil, bundle: nil,
            step: 141, totalSteps: 200, remaining: 4)
        XCTAssertEqual(ProgressItem.prediction(job).detail,
                       "Diffusion 19% · step 141 of 200 · model 4 of 20 · "
                       + "this phase: almost done")
    }

    /// The scoped spelling wraps the buckets rather than replacing them, so the
    /// weight-download card -- which measures a WHOLE task and reads correctly
    /// unqualified -- keeps the wording it has.
    func testOnlyThePredictionCardScopesItsEtaToThePhase() {
        XCTAssertEqual(ProgressCard.formatPhaseRemaining(4), "this phase: almost done")
        XCTAssertEqual(ProgressCard.formatPhaseRemaining(240), "this phase: 4 min left")
        XCTAssertEqual(ProgressCard.formatRemaining(4), "almost done")
        // 950 of 1000 bytes in 95 s -> 10 B/s -> 5 s left.
        let fetch = WeightsFetchState(
            id: "boltz2-mlx-int8", state: "running", phase: "download",
            fraction: 0.95, received: 950, total: 1000, elapsed: 95, error: nil)
        let detail = WeightDownloadDetail.text(fetch)
        XCTAssertTrue(detail.hasSuffix("almost done"), detail)
        XCTAssertFalse(detail.contains("this phase"), detail)
    }

    /// With no measured rate yet, the card falls back to the elapsed clock it
    /// showed before this increment — never a fabricated countdown.
    func testAPredictionWithNoEtaStillShowsItsElapsedClock() {
        let job = PredictionJobState(
            id: "p", state: "running", phase: "trunk", fraction: nil,
            moving: false, detail: "d", modelsDone: 0, modelsTotal: 1,
            elapsed: 95, error: nil)
        let item = ProgressItem.prediction(job)
        XCTAssertEqual(item.detail, "Trunk · 2 min elapsed")
        XCTAssertFalse(item.detail.contains("left"))
    }

    func testBothErrorAndFailedCountAsAnErrorState() {
        // Swift's host writes "failed"; _DeferredJob writes "error". Neither wire
        // is migrated, so the single consumer must accept both.
        for state in ["error", "failed"] {
            let job = PredictionJobState(
                id: "x", state: state, phase: "inference", fraction: nil,
                moving: false, detail: "d", modelsDone: 0, modelsTotal: 1,
                elapsed: 1, error: "boom")
            XCTAssertTrue(job.isError, state)
        }
    }
}

extension PendingJobTests {

    func testAPredictionItemCarriesAPerObjectCancelCommand() {
        let job = PredictionJobState(
            id: "my pred", state: "running", phase: "diffusion", fraction: 0.5,
            moving: true, detail: "pending: diffusion 64%", modelsDone: 0,
            modelsTotal: 2, elapsed: 12, error: nil)
        let item = ProgressItem.prediction(job)
        XCTAssertEqual(item.id, "predict:my pred")
        XCTAssertEqual(item.buttonTitle, "Cancel")
        // Python path: object names may contain spaces, and the PyMOL text parser
        // does not strip the surrounding quotes from its "[^"]*" token.
        //
        // The import is not decoration. runPython → PyRun_SimpleString executes in
        // __main__, which starts EMPTY in this embedding — raymolrc binds `cmd`
        // there only when ~/.raymolrc.py exists — so a bare `cmd.predict_cancel(…)`
        // was a silent NameError and Cancel did nothing at all for most users.
        XCTAssertEqual(item.action,
                       .python("from pymol import cmd as _c\n_c.predict_cancel('my pred')"))
        XCTAssertTrue(item.moving)
        XCTAssertFalse(item.isError)
    }

    /// Every emitted Python statement must stand on its own in an empty __main__.
    func testEveryEmittedPythonStatementImportsWhatItUses() {
        for state in ["running", "failed", "cancelled"] {
            let item = ProgressItem.prediction(job("p", state: state))
            guard case .python(let src) = item.action else {
                return XCTFail("\(state) did not emit a python action")
            }
            XCTAssertTrue(src.hasPrefix("from pymol import cmd as _c\n"),
                          "\(state) emitted a bare reference: \(src)")
            XCTAssertFalse(src.contains("\ncmd."), "\(state): \(src)")
        }
    }

    func testPythonLiteralEscapesApostrophesAndDoesNotTerminateStringEarly() {
        // A name with both a space and an apostrophe must not break the Python
        // literal: the apostrophe must be backslash-escaped, not close the string.
        let job = PredictionJobState(
            id: "my pred's", state: "running", phase: "diffusion", fraction: nil,
            moving: true, detail: "d", modelsDone: 0, modelsTotal: 1,
            elapsed: 1, error: nil)
        let item = ProgressItem.prediction(job)
        XCTAssertEqual(
            item.action,
            .python("from pymol import cmd as _c\n_c.predict_cancel('my pred\\'s')"))
    }

    // -- Weight-fetch action contract -----------------------------------------

    /// The per-bundle command spelling was never executable. `WeightsFetchState.id`
    /// is the BUNDLE id ("boltz2-mlx-int8"), but `predict_weights_cancel` takes a
    /// PREDICTOR id and does `registry.get(predictor)` — so the emitted command
    /// raised `PredictorNotFound: unknown predictor 'boltz2-mlx-int8'`, the 529 MB
    /// download carried on, and the card stayed. Assert the ACTION, which is what
    /// actually runs, rather than a string that never worked end to end.
    func testARunningWeightsFetchItemCancelsThroughTheLocalAction() {
        let fetch = WeightsFetchState(
            id: "boltz2-mlx-int8", state: "running", phase: "download",
            fraction: 0.4, received: 200, total: 500, elapsed: 10, error: nil)
        let item = ProgressItem.weights(fetch)
        XCTAssertEqual(item.action, .cancelWeightsFetch)
        XCTAssertEqual(item.buttonTitle, "Cancel")
    }

    func testAnErroredWeightsFetchItemYieldsCancelWeightsFetchNotNoop() {
        // Before the Action enum, the error branch set cancelCommand = nil, so the
        // guard in ContentView fired and the card was stuck on screen forever.
        let fetch = WeightsFetchState(
            id: "boltz2-mlx-int8", state: "error", phase: "download",
            fraction: 0.0, received: 0, total: 529338573, elapsed: nil,
            error: "failed to fetch https://example/b.zip")
        let item = ProgressItem.weights(fetch)
        XCTAssertEqual(item.action, .cancelWeightsFetch)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        XCTAssertTrue(item.isError)
    }

    /// No weights branch may emit a bundle id as a predictor id ever again.
    func testNoWeightsBranchEmitsARawCommand() {
        for state in ["running", "error"] {
            let fetch = WeightsFetchState(
                id: "boltz2-mlx-int8", state: state, phase: "download",
                fraction: 0.4, received: 200, total: 500, elapsed: 10,
                error: state == "error" ? "boom" : nil)
            XCTAssertEqual(ProgressItem.weights(fetch).action, .cancelWeightsFetch, state)
        }
    }

    func testAFailedPredictionShowsItsErrorAndOffersDismiss() {
        let job = PredictionJobState(
            id: "p", state: "failed", phase: "inference", fraction: nil,
            moving: false, detail: "pending", modelsDone: 0, modelsTotal: 1,
            elapsed: 600, error: "input of 9000 residues is too large")
        let item = ProgressItem.prediction(job)
        XCTAssertTrue(item.isError)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        XCTAssertEqual(item.detail, "input of 9000 residues is too large")
        XCTAssertFalse(item.moving)
    }

    /// A user's own Cancel must not be reported back to them as a failure.
    ///
    /// `settle("cancelled", …)` writes `error: nil` and Python retains the record,
    /// so with only an error branch the card read "Prediction failed: p — Unknown
    /// error": an unexplained failure for someone who had just pressed Cancel.
    func testACancelledPredictionReadsAsCancelledNotFailed() {
        let job = PredictionJobState(
            id: "p", state: "cancelled", phase: "inference", fraction: 0.3,
            moving: true, detail: "pending: inference", modelsDone: 0,
            modelsTotal: 1, elapsed: 95, error: nil)
        let item = ProgressItem.prediction(job)
        XCTAssertEqual(item.title, "Prediction cancelled: p")
        XCTAssertEqual(item.detail, "2 min elapsed")
        XCTAssertFalse(item.detail.contains("Unknown error"))
        XCTAssertEqual(item.icon, "xmark.circle")
        XCTAssertTrue(item.isCancelled)
        // Terminal like a failure: Dismiss, no live bar, sorted below live jobs.
        XCTAssertTrue(item.isError)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        XCTAssertFalse(item.moving)
    }

    /// A real failure must keep its own presentation.
    func testAFailedPredictionIsNotDressedUpAsCancelled() {
        let item = ProgressItem.prediction(PredictionJobState(
            id: "p", state: "failed", phase: "inference", fraction: nil,
            moving: false, detail: "pending", modelsDone: 0, modelsTotal: 1,
            elapsed: 95, error: "out of memory"))
        XCTAssertFalse(item.isCancelled)
        XCTAssertEqual(item.icon, "exclamationmark.triangle.fill")
        XCTAssertEqual(item.title, "Prediction failed: p")
        XCTAssertEqual(item.detail, "out of memory")
    }

    func testElapsedIsFormattedCoarsely() {
        XCTAssertEqual(ProgressCard.formatElapsed(4), "4 sec")
        XCTAssertEqual(ProgressCard.formatElapsed(95), "2 min")
        XCTAssertEqual(ProgressCard.formatElapsed(4000), "1 hr 7 min")
    }

    /// Rounding carry: each boundary that .rounded() would push across a unit
    /// boundary must be caught and propagated, not printed as "60 sec" / "60 min".
    func testElapsedCarriesAtUnitBoundaries() {
        // 59.5 s rounds to 60 s — must not print "60 sec"
        XCTAssertEqual(ProgressCard.formatElapsed(59.5), "1 min")
        // 7199 s = 1 hr 59.983 min — must not print "1 hr 60 min"
        XCTAssertEqual(ProgressCard.formatElapsed(7199), "2 hr 0 min")
        // Regression for the original fix (4000 s = 1 hr 6.67 min → rounds to 7)
        XCTAssertEqual(ProgressCard.formatElapsed(4000), "1 hr 7 min")
    }

    func testRemainingDoesNotPrint60MinLeft() {
        // 3594 s / 60 = 59.9 min, rounds to 60 — must route to "over an hour left"
        XCTAssertEqual(ProgressCard.formatRemaining(3594), "over an hour left")
    }

    func testElapsedDoesNotPrint60Min() {
        // 3570–3599 s round to 60 min in the ..<3600 branch — must carry to "1 hr 0 min"
        // and must match what the default branch produces at exactly 3600.
        let atBoundary = ProgressCard.formatElapsed(3599)
        XCTAssertFalse(atBoundary.contains("60 min"), "got: \(atBoundary)")
        XCTAssertEqual(atBoundary, ProgressCard.formatElapsed(3600))
    }

    private func job(_ id: String, state: String = "running",
                     bundle: String? = nil) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: "inference", fraction: nil,
                           moving: false, detail: "d", modelsDone: 0, modelsTotal: 1,
                           elapsed: 1, error: state == "running" ? nil : "boom",
                           bundle: bundle)
    }

    /// A cold-cache run must show ONE card, not two describing the same transfer
    /// at two different percentages.
    func testAPredictionWaitingOnALiveDownloadIsHidden() {
        let fetch = WeightsFetchState(
            id: "boltz2-mlx-int8", state: "running", phase: "download",
            fraction: 0.4, received: 200, total: 500, elapsed: 10, error: nil)
        let items = ProgressItem.tray(weights: fetch,
                                      predictions: [job("p", bundle: "boltz2-mlx-int8")])
        XCTAssertEqual(items.map(\.id), ["weights:boltz2-mlx-int8"])
    }

    func testAPredictionWaitingOnADIFFERENTBundleIsStillShown() {
        let fetch = WeightsFetchState(
            id: "other", state: "running", phase: "download",
            fraction: 0.4, received: 200, total: 500, elapsed: 10, error: nil)
        let items = ProgressItem.tray(weights: fetch,
                                      predictions: [job("p", bundle: "boltz2-mlx-int8")])
        XCTAssertEqual(items.count, 2)
    }

    func testRunningCardsSortAboveErrorCards() {
        let items = ProgressItem.tray(
            weights: nil,
            predictions: [job("zzz-failed", state: "failed"), job("aaa-running")])
        XCTAssertEqual(items.map(\.id), ["predict:aaa-running", "predict:zzz-failed"])
    }
}
