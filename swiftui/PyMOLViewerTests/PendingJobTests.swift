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
        // Quoted: object names may contain spaces.
        XCTAssertEqual(item.cancelCommand, "predict_cancel \"my pred\"")
        XCTAssertTrue(item.moving)
        XCTAssertFalse(item.isError)
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
