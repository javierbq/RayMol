#if os(macOS)
import XCTest
@testable import RayMol

/// The progress tray's design lane (#342, #291), and the sheet that starts a design.
///
/// A design is minutes long, so the tray is the only thing that says it is alive at all.
/// Everything here is about what the user reads and what the buttons actually do.
final class RFD3TrayTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear persisted live-view preference so each test starts from the published
        // default (false). Without this, testLiveViewAppearsInTheCommandWhenOn sets the
        // key to true and subsequent tests that create a fresh controller read true from
        // UserDefaults instead of the intended default.
        UserDefaults.standard.removeObject(forKey: DesignBackboneController.liveViewKey)
        UserDefaults.standard.removeObject(forKey: DesignBackboneController.keepFramesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DesignBackboneController.liveViewKey)
        UserDefaults.standard.removeObject(forKey: DesignBackboneController.keepFramesKey)
        super.tearDown()
    }

    private func job(id: String = "rfd3_design_ab12cd34", state: String = "running",
                     phase: String = "diffusion", fraction: Double? = 0.42,
                     moving: Bool = true, elapsed: Double = 512,
                     error: String? = nil, bundle: String? = nil,
                     step: Int? = 84, totalSteps: Int? = 199,
                     remaining: Double? = 300,
                     batch: String? = nil, batchIndex: Int? = nil,
                     batchTotal: Int? = nil) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: phase, fraction: fraction,
                           moving: moving, detail: "d", modelsDone: 0, modelsTotal: 1,
                           elapsed: elapsed, error: error, bundle: bundle,
                           step: step, totalSteps: totalSteps, remaining: remaining,
                           batch: batch, batchIndex: batchIndex, batchTotal: batchTotal)
    }

    /// One member of a ten-design batch, at `index`, in whatever state.
    private func member(_ index: Int, state: String = "queued", phase: String = "queued",
                        fraction: Double? = nil, moving: Bool = false,
                        error: String? = nil, bundle: String? = nil,
                        step: Int? = nil, totalSteps: Int? = nil,
                        remaining: Double? = nil, total: Int = 10,
                        elapsed: Double = 512) -> PredictionJobState {
        job(id: String(format: "rfd3_design_%02d", index),
            state: state, phase: phase, fraction: fraction, moving: moving,
            elapsed: elapsed, error: error, bundle: bundle, step: step,
            totalSteps: totalSteps, remaining: remaining,
            batch: "rfd3_batch_ab12cd34", batchIndex: index, batchTotal: total)
    }

    // MARK: What the card says

    func testARunningDesignReadsAsPhasePercentStepEtaAndElapsed() {
        // BOTH the estimate and the elapsed clock, unlike a prediction's card. The estimate
        // covers only the current phase, and on a seventeen-minute run the elapsed clock is
        // the number a user actually tracks.
        let item = ProgressItem.design(job())
        XCTAssertEqual(item.title, "Designing rfd3_design_ab12cd34")
        XCTAssertEqual(item.detail,
                       "Diffusion 42% · step 84 of 199 · this phase: 5 min left · "
                       + "9 min elapsed")
        XCTAssertEqual(item.icon, "wand.and.stars")
        XCTAssertFalse(item.isError)
    }

    func testTheStepCountIsTheRUNTIMESTotalNotTheRequestedStepCount() {
        // 199, not 200: the EDM schedule has numTimesteps sigma levels and one fewer
        // transition, so the runtime reports numTimesteps - 1. A card that recomputed this
        // from the requested step count would stop one short of the end forever.
        XCTAssertTrue(ProgressItem.design(job(step: 199, totalSteps: 199)).detail
                        .contains("step 199 of 199"))
    }

    func testAnIndeterminatePhaseShowsNoPercentage() {
        // No number rather than a made-up one: the bar is indeterminate here, so a
        // percentage beside it would be a figure the bar does not agree with.
        let item = ProgressItem.design(job(fraction: nil, moving: false, remaining: nil))
        XCTAssertEqual(item.detail, "Diffusion · step 84 of 199 · 9 min elapsed")
        XCTAssertFalse(item.moving)
    }

    func testAFailedDesignSaysWhy() {
        let item = ProgressItem.design(
            job(state: "failed", error: "the target moved 3.500 A during generation"))
        XCTAssertEqual(item.title, "Design failed: rfd3_design_ab12cd34")
        XCTAssertEqual(item.detail, "the target moved 3.500 A during generation")
        XCTAssertTrue(item.isError)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
    }

    func testACancelledDesignIsNotReportedAsAFailure() {
        // `settle("cancelled", ...)` writes error: nil, so the failure branch would render
        // "Design failed — Unknown error" for someone who had just pressed Cancel.
        let item = ProgressItem.design(job(state: "cancelled", error: nil))
        XCTAssertEqual(item.title, "Design cancelled: rfd3_design_ab12cd34")
        XCTAssertEqual(item.detail, "9 min elapsed")
        XCTAssertTrue(item.isCancelled)
    }

    func testNoCardEverSaysBinder() {
        // The naming rule, at the surface where it matters most. A generated chain is a
        // designed backbone until a refold and an interface gate say otherwise, and this
        // card is read long before either.
        for state in ["running", "failed", "cancelled"] {
            let item = ProgressItem.design(job(state: state, error: "a binder-ish error"))
            XCTAssertFalse(item.title.lowercased().contains("binder"), item.title)
            // The DETAIL may echo a message from elsewhere; the title and the button are
            // ours, and they are what the rule governs.
            XCTAssertFalse(item.buttonTitle.lowercased().contains("binder"))
        }
    }

    // MARK: What the buttons do

    func testCancelRoutesToDesignCancelNotPredictCancel() {
        // The two surfaces keep SEPARATE job tables, so a design's object name means
        // nothing to predict_cancel -- it would raise for an unknown job and the button
        // would appear to do nothing.
        guard case .python(let source) = ProgressItem.design(job()).action else {
            return XCTFail("a design card must act through the Python channel")
        }
        XCTAssertTrue(source.contains("design_cancel"), source)
        XCTAssertFalse(source.contains("predict_cancel"), source)
        // The import is load-bearing: runPython lands in a __main__ that is EMPTY in this
        // embedding, so a bare `cmd.design_cancel(...)` is a silent NameError.
        XCTAssertTrue(source.contains("from pymol import cmd as _c"), source)
        XCTAssertTrue(source.contains("'rfd3_design_ab12cd34'"), source)
    }

    func testDismissRoutesToDesignDismiss() {
        guard case .python(let source) =
            ProgressItem.design(job(state: "failed", error: "x")).action else {
            return XCTFail("expected .python")
        }
        XCTAssertTrue(source.contains("design_dismiss"), source)
    }

    func testAnObjectNameWithAnApostropheIsEscaped() {
        guard case .python(let source) =
            ProgressItem.design(job(id: "it's_a_design")).action else {
            return XCTFail("expected .python")
        }
        XCTAssertTrue(source.contains("'it\\'s_a_design'"), source)
    }

    // MARK: The merge

    func testDesignsAndPredictionsShareTheTrayWithLiveJobsFirst() {
        let items = ProgressItem.tray(
            weights: nil,
            predictions: [job(id: "pred_ok"), job(id: "pred_bad", state: "failed",
                                                  error: "x")],
            designs: [job(id: "design_ok"), job(id: "design_bad", state: "failed",
                                                error: "y")])
        XCTAssertEqual(items.count, 4)
        // Errors last, so a live job is never pushed below the fold by a stale card.
        XCTAssertEqual(items.map(\.isError), [false, false, true, true])
        XCTAssertTrue(items.contains { $0.id == "design:design_ok" })
        XCTAssertTrue(items.contains { $0.id == "predict:pred_ok" })
    }

    func testTheOrderIsStableAcrossPolls() {
        // The tray is rebuilt from a 2 Hz poll. Rows that reorder under the pointer make
        // Cancel unclickable, so the sort has to be total, not merely "errors last".
        let predictions = [job(id: "p2"), job(id: "p1")]
        let designs = [job(id: "d2"), job(id: "d1")]
        let once = ProgressItem.tray(weights: nil, predictions: predictions,
                                     designs: designs).map(\.id)
        let twice = ProgressItem.tray(weights: nil, predictions: predictions.reversed(),
                                      designs: designs.reversed()).map(\.id)
        XCTAssertEqual(once, twice)
    }

    func testADesignWaitingOnAFetchingBundleShowsNoSecondCard() {
        // One transfer, one card. The bundle's own card is the measured one; a design
        // merely waiting on it would show the same download again at a different number.
        let fetch = WeightsFetchState(id: "rfd3-mlx-fp32", state: "running",
                                     phase: "download", fraction: 0.4, received: 250,
                                     total: 625, elapsed: 30, error: nil)
        let items = ProgressItem.tray(weights: fetch, predictions: [],
                                      designs: [job(bundle: "rfd3-mlx-fp32")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.bundle, "rfd3-mlx-fp32")
    }

    func testAnEmptyDesignListLeavesTheTrayExactlyAsItWas() {
        // `designs:` is defaulted, so nothing about the prediction tray changes when
        // nothing is designing -- the acceptance rule for this whole feature.
        let predictions = [job(id: "p1"), job(id: "p2", state: "failed", error: "x")]
        XCTAssertEqual(ProgressItem.tray(weights: nil, predictions: predictions).map(\.id),
                       ProgressItem.tray(weights: nil, predictions: predictions,
                                         designs: []).map(\.id))
    }

    // MARK: The batch — one invocation, one row

    func testTenDesignsFromOneCommandAreOneRow() {
        // The defect this exists to close: ten designs produced ten tray rows, nine of
        // them reading "Queued", because the tray listed work the serial queue had not
        // started as if it were nine separate jobs.
        let running = member(1, state: "running", phase: "diffusion", fraction: 0.42,
                             moving: true, step: 84, totalSteps: 199, remaining: 300)
        let queued = (2...10).map { member($0) }
        let items = ProgressItem.tray(weights: nil, predictions: [],
                                      designs: [running] + queued)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "design:rfd3_batch_ab12cd34")
        XCTAssertEqual(items[0].title, "Designing rfd3_batch_ab12cd34")
    }

    func testTheRowSaysHowFarThroughTheBatchTheRunIs() {
        // Submission order IS the serial queue's order, so the lowest index that has not
        // settled is the design being worked on -- and everything below it is done.
        let item = ProgressItem.designBatch(
            [member(3, state: "running", phase: "diffusion", fraction: 0.5, moving: true,
                    step: 100, totalSteps: 199, remaining: 300)]
            + (4...10).map { member($0) })
        XCTAssertEqual(item.detail,
                       "Diffusion 25% · design 3 of 10 · step 100 of 199 · "
                       + "this phase: 5 min left · 9 min elapsed")
        XCTAssertFalse(item.isError)
        XCTAssertEqual(item.buttonTitle, "Cancel")
    }

    func testTheBatchDoesNotSHRINKAsItsDesignsSUCCEED() {
        // A delivered design leaves NO record -- `deliver_result` pops it from every
        // table -- so a row that counted the records present would report a ten-design
        // batch as a seven-design one by the time it was three in. The size comes from
        // the wire.
        let item = ProgressItem.designBatch(
            [member(4, state: "running", phase: "diffusion", fraction: 0.0, moving: true)]
            + (5...10).map { member($0) })
        XCTAssertTrue(item.detail.contains("design 4 of 10"), item.detail)
    }

    func testTheBarComposesTheFINISHEDDesignsWithTheRunningOnesOwnFraction() {
        // The whole-batch number, and the SAME number the percentage in the text quotes
        // -- the two can never disagree because there is one of them.
        let item = ProgressItem.designBatch(
            [member(3, state: "running", phase: "diffusion", fraction: 0.5,
                    moving: true)])
        XCTAssertEqual(try XCTUnwrap(item.fraction), 0.25, accuracy: 1e-9)
        XCTAssertTrue(item.detail.hasPrefix("Diffusion 25%"), item.detail)
    }

    func testOneCancelStopsTheWholeBatch() {
        // The batch id, which is the group name -- `design_cancel` resolves it to every
        // job of that invocation still outstanding: the one running and the ones queued.
        let item = ProgressItem.designBatch(
            [member(1, state: "running", phase: "diffusion", fraction: 0.1, moving: true)]
            + (2...10).map { member($0) })
        guard case .python(let source) = item.action else {
            return XCTFail("a batch card must act through the Python channel")
        }
        XCTAssertTrue(source.contains("design_cancel"), source)
        XCTAssertTrue(source.contains("'rfd3_batch_ab12cd34'"), source)
        // NOT the member names: ten calls would be ten chances to half-cancel a batch.
        XCTAssertFalse(source.contains("rfd3_design_"), source)
    }

    func testADesignFAILINGMidBatchDoesNotStopTheRowFromRunning() {
        // A partial failure is not a batch failure. The other nine are still going, so
        // the row stays a running row -- and it says how many have failed, so a batch
        // that ends nine-and-one can never have read as ten successes.
        let item = ProgressItem.designBatch(
            [member(1, state: "failed", error: "the target moved 3.500 A"),
             member(2, state: "running", phase: "diffusion", fraction: 0.5, moving: true)]
            + (3...10).map { member($0) })
        XCTAssertFalse(item.isError)
        XCTAssertEqual(item.title, "Designing rfd3_batch_ab12cd34")
        XCTAssertTrue(item.detail.contains("design 2 of 10"), item.detail)
        XCTAssertTrue(item.detail.contains("1 failed"), item.detail)
        XCTAssertEqual(item.buttonTitle, "Cancel")
    }

    func testABatchThatENDEDWithOneFailureDoesNotClaimTheyAllFailed() {
        // Nine landed and are gone from the wire; one failed and is retained. The card
        // has to name the ONE, not the batch.
        let item = ProgressItem.designBatch(
            [member(4, state: "failed", error: "the target moved 3.500 A")])
        XCTAssertEqual(item.title, "1 of 10 designs failed: rfd3_batch_ab12cd34")
        XCTAssertEqual(item.detail, "the target moved 3.500 A")
        XCTAssertTrue(item.isError)
        XCTAssertFalse(item.isCancelled)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        guard case .python(let source) = item.action else { return XCTFail("expected .python") }
        XCTAssertTrue(source.contains("design_dismiss"), source)
        XCTAssertTrue(source.contains("'rfd3_batch_ab12cd34'"), source)
    }

    func testSeveralFailuresAreCountedRatherThanListed() {
        let item = ProgressItem.designBatch(
            [member(2, state: "failed", error: "first reason"),
             member(5, state: "failed", error: "second reason"),
             member(9, state: "cancelled")])
        XCTAssertEqual(item.title, "2 of 10 designs failed: rfd3_batch_ab12cd34")
        XCTAssertEqual(item.detail, "first reason · and 1 more · 1 cancelled")
    }

    func testACancelledBatchIsNotReportedAsAFailure() {
        // `settle("cancelled", ...)` writes error: nil, so without the split the card
        // read "designs failed — Unknown error" at someone who had just pressed Cancel.
        let item = ProgressItem.designBatch((1...10).map { member($0, state: "cancelled") })
        XCTAssertEqual(item.title, "10 of 10 designs cancelled: rfd3_batch_ab12cd34")
        XCTAssertEqual(item.detail, "9 min elapsed")
        XCTAssertTrue(item.isCancelled)
        XCTAssertEqual(item.icon, "xmark.circle")
    }

    func testTheBatchRowNeverSaysBinder() {
        for state in ["running", "failed", "cancelled"] {
            let item = ProgressItem.designBatch(
                [member(1, state: state, error: "a binder-ish error")])
            XCTAssertFalse(item.title.lowercased().contains("binder"), item.title)
            XCTAssertFalse(item.buttonTitle.lowercased().contains("binder"))
        }
    }

    func testALONEDesignIsUNTOUCHEDByBatching() {
        // n_designs=1 publishes no batch fields at all, so its row is byte-for-byte the
        // one it has always been. Compared against `design(_:)` directly rather than
        // against a remembered string.
        let lone = job()
        let items = ProgressItem.tray(weights: nil, predictions: [], designs: [lone])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0], ProgressItem.design(lone))
    }

    func testAPredictionIsNEVERCollapsedEvenBesideABatch() {
        // `predicting.pending_info` publishes no batch key, so a prediction cannot be
        // grouped -- and the prediction lane is shipped behaviour this feature does not
        // own. Asserted against the untouched tray, not against a remembered layout.
        let predictions = [job(id: "p1"), job(id: "p2")]
        let designs = (1...4).map { member($0) }
        let withBatch = ProgressItem.tray(weights: nil, predictions: predictions,
                                          designs: designs)
        let alone = ProgressItem.tray(weights: nil, predictions: predictions)
        XCTAssertEqual(withBatch.filter { $0.id.hasPrefix("predict:") }, alone)
        XCTAssertEqual(withBatch.filter { $0.id.hasPrefix("design:") }.count, 1)
    }

    func testTwoBatchesAreTwoRowsInAStableOrder() {
        let first = (1...3).map { member($0) }
        let second = (1...3).map {
            job(id: "other_\($0)", state: "queued", phase: "queued", fraction: nil,
                moving: false, batch: "rfd3_batch_ffffffff", batchIndex: $0,
                batchTotal: 3)
        }
        let once = ProgressItem.tray(weights: nil, predictions: [],
                                     designs: first + second).map(\.id)
        let twice = ProgressItem.tray(weights: nil, predictions: [],
                                      designs: (second + first).reversed()).map(\.id)
        XCTAssertEqual(once, ["design:rfd3_batch_ab12cd34", "design:rfd3_batch_ffffffff"])
        XCTAssertEqual(once, twice)
    }

    func testABatchWaitingOnAFetchingBundleShowsNoSecondCard() {
        // Same rule as a single design: one transfer, one card.
        let fetch = WeightsFetchState(id: "rfd3-mlx-fp32", state: "running",
                                      phase: "download", fraction: 0.4, received: 250,
                                      total: 625, elapsed: 30, error: nil)
        let items = ProgressItem.tray(
            weights: fetch, predictions: [],
            designs: (1...4).map { member($0, bundle: "rfd3-mlx-fp32") })
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.bundle, "rfd3-mlx-fp32")
    }

    // MARK: The payload

    func testADesignRecordDecodesFromTheRealPayloadShape() throws {
        // Verbatim from the shape appkit_inspector.poll_panel writes: `design_jobs` beside
        // `pending_jobs`, both keyed by object name, both the same record type.
        let payload = """
        {"objects":["rfd3_design_ab12cd34"],"selections":[],"enabled":[],
         "sel_counts":{},"nstate":{"rfd3_design_ab12cd34":0},
         "has_transp":{"rfd3_design_ab12cd34":false},"groups":[],"parent":{},
         "pending":{"rfd3_design_ab12cd34":"pending: diffusion 42% step 84 of 199"},
         "pending_jobs":{},
         "design_jobs":{"rfd3_design_ab12cd34":{"state":"running","phase":"diffusion",
           "fraction":0.42,"moving":true,"detail":"pending: diffusion 42%",
           "models_done":0,"models_total":1,"elapsed":512.0,"error":null,
           "step":84,"total_steps":199,"remaining":300.0}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self,
                                               from: Data(payload.utf8))
        let record = try XCTUnwrap(decoded.design_jobs?["rfd3_design_ab12cd34"])
        XCTAssertEqual(record.phase, "diffusion")
        XCTAssertEqual(record.step, 84)
        XCTAssertEqual(record.totalSteps, 199)
        // A design placeholder is in `pending` too, so its enable-toggle is greyed exactly
        // as a prediction placeholder's is.
        XCTAssertEqual(decoded.pending?.count, 1)
    }

    func testABatchedRecordCarriesItsBatchIdentityThroughTheRealPayloadShape() throws {
        // The three keys `designing.pending_info` adds. Decoded from the payload rather
        // than constructed here, because a CodingKey typo is exactly the kind of break
        // that leaves every test green and the tray uncollapsed.
        let payload = """
        {"objects":[],"selections":[],"enabled":[],"sel_counts":{},"nstate":{},
         "has_transp":{},"groups":[],"parent":{},"pending":{},"pending_jobs":{},
         "design_jobs":{"rfd3_design_ab12cd34":{"state":"queued","phase":"queued",
           "fraction":null,"moving":false,"detail":"pending","models_done":0,
           "models_total":1,"elapsed":12.0,"error":null,"step":null,"total_steps":null,
           "remaining":null,"batch":"rfd3_batch_ab12cd34","batch_index":3,
           "batch_total":10}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(payload.utf8))
        let record = try XCTUnwrap(decoded.design_jobs?["rfd3_design_ab12cd34"])
        XCTAssertEqual(record.batch, "rfd3_batch_ab12cd34")
        XCTAssertEqual(record.batchIndex, 3)
        XCTAssertEqual(record.batchTotal, 10)
        // And the identity survives the key-to-id step the panel does on every record.
        XCTAssertEqual(record.withID("rfd3_design_ab12cd34").batch, "rfd3_batch_ab12cd34")
    }

    func testARecordWithNoBatchKeysDecodesToNoBatch() throws {
        // A single design, and every prediction ever: the keys are simply absent. A
        // non-optional field here would fail the whole payload decode against a Python
        // side that predates them and freeze the object panel on its last list.
        let payload = """
        {"objects":[],"selections":[],"enabled":[],"sel_counts":{},"nstate":{},
         "has_transp":{},"groups":[],"parent":{},"pending":{},
         "pending_jobs":{"pred_1":{"state":"running","phase":"diffusion","fraction":0.4,
           "moving":true,"detail":"d","models_done":0,"models_total":1,"elapsed":1.0,
           "error":null}},
         "design_jobs":{"rfd3_design_ab12cd34":{"state":"running","phase":"diffusion",
           "fraction":0.42,"moving":true,"detail":"d","models_done":0,"models_total":1,
           "elapsed":512.0,"error":null,"step":84,"total_steps":199,"remaining":300.0}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(payload.utf8))
        XCTAssertNil(try XCTUnwrap(decoded.design_jobs?["rfd3_design_ab12cd34"]).batch)
        XCTAssertNil(try XCTUnwrap(decoded.pending_jobs?["pred_1"]).batch)
    }

    func testTheREALPayloadOfAPartlyFailedTenDesignBatchCollapsesToOneRow() throws {
        // VERBATIM from `appkit_inspector._pending_maps('designing')` on a real ten-design
        // batch driven through the headless harness: design 1 DELIVERED (so it has no
        // record at all -- that is what makes counting rows wrong), design 2 FAILED and
        // retained, design 3 running at step 84, designs 4-10 queued.
        //
        // Decoded here rather than hand-built, because every defect this row exists to
        // close lives between the two languages: a CodingKey that does not match the key
        // Python writes leaves the tray uncollapsed with every unit test green.
        let payload = """
        {"objects":[],"selections":[],"enabled":[],"sel_counts":{},"nstate":{},
                 "has_transp":{},"groups":[],"parent":{},"pending":{},"pending_jobs":{},
                 "design_jobs":{
                 "stubgen_design_15938a91":{"batch":"stubgen_batch_ee8afa5b","batch_index":7,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.0020585829624906182,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_332196a5":{"batch":"stubgen_batch_ee8afa5b","batch_index":4,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.0024077920243144035,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_3d92314b":{"batch":"stubgen_batch_ee8afa5b","batch_index":5,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.002310291980393231,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_6fbbee03":{"batch":"stubgen_batch_ee8afa5b","batch_index":9,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.0016517910407856107,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_85c5eb2c":{"batch":"stubgen_batch_ee8afa5b","batch_index":3,"batch_total":10,"bundle":null,"detail":"pending: diffusion 47% step 84 of 199","elapsed":0.0026035000337287784,"error":null,"fraction":0.478,"models_done":0,"models_total":1,"moving":true,"phase":"diffusion","remaining":null,"state":"running","step":84,"total_steps":199},
                 "stubgen_design_a3def5ea":{"batch":"stubgen_batch_ee8afa5b","batch_index":6,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.0021878340048715472,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_ac22da17":{"batch":"stubgen_batch_ee8afa5b","batch_index":10,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.001532584079541266,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_ce27af0c":{"batch":"stubgen_batch_ee8afa5b","batch_index":8,"batch_total":10,"bundle":null,"detail":"pending: queued","elapsed":0.001891832915134728,"error":null,"fraction":null,"models_done":0,"models_total":1,"moving":false,"phase":"queued","remaining":null,"state":"queued","step":null,"total_steps":null},
                 "stubgen_design_ef1a8cb5":{"batch":"stubgen_batch_ee8afa5b","batch_index":2,"batch_total":10,"bundle":null,"detail":"pending: diffusion 10%","elapsed":0.0026616250397637486,"error":"the target moved 3.500 A","fraction":0.1,"models_done":0,"models_total":1,"moving":true,"phase":"diffusion","remaining":null,"state":"failed","step":null,"total_steps":null}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(payload.utf8))
        let designs = try XCTUnwrap(decoded.design_jobs).map { $0.value.withID($0.key) }
        XCTAssertEqual(designs.count, 9, "the delivered design leaves no record")
        let items = ProgressItem.tray(weights: nil, predictions: [], designs: designs)
        XCTAssertEqual(items.count, 1, "nine records, one invocation, one row")
        let row = items[0]
        XCTAssertEqual(row.id, "design:stubgen_batch_ee8afa5b")
        XCTAssertEqual(row.title, "Designing stubgen_batch_ee8afa5b")
        // Design 3 is the frontier: 1 landed, 2 failed, 3 is running. Not "design 1 of 9".
        XCTAssertTrue(row.detail.contains("design 3 of 10"), row.detail)
        XCTAssertTrue(row.detail.contains("step 84 of 199"), row.detail)
        XCTAssertTrue(row.detail.contains("1 failed"), row.detail)
        // Still running, still cancellable, and the bar is the WHOLE batch: two designs
        // behind the frontier plus 47.8% of the third, over ten.
        XCTAssertFalse(row.isError)
        XCTAssertEqual(row.buttonTitle, "Cancel")
        XCTAssertEqual(try XCTUnwrap(row.fraction), (2.0 + 0.478) / 10.0, accuracy: 1e-9)
    }

    func testAPayloadWithNoDesignJobsStillDecodes() throws {
        // Optional at this end, like every field ever added to PanelPayload: one
        // non-optional fails the single `guard let` and freezes the panel on its last list.
        let payload = """
        {"objects":[],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{},"has_transp":{},"groups":[],"parent":{},"pending":{},
         "pending_jobs":{}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self,
                                               from: Data(payload.utf8))
        XCTAssertNil(decoded.design_jobs)
    }

    // MARK: The bar's command

    @MainActor
    private func controller() -> DesignBackboneController {
        let c = DesignBackboneController()
        c.generator = "rfd3"
        c.targetText = "target"
        c.target = DesignTargetInfo(residues: 40, chain: "A", state: 1, hotspots: 3)
        return c
    }

    @MainActor
    func testTheBarBuildsARunnableCommand() {
        XCTAssertEqual(controller().command,
                       "design_backbone rfd3, target, sele, length=60")
    }

    @MainActor
    func testOnlyNonDefaultOptionsAppear() {
        // The command is read back by a human and re-run from the console, so it carries
        // what was CHANGED rather than every knob at its default.
        let c = controller()
        c.nDesigns = 5
        c.diffusionSteps = 30
        c.recyclingSteps = 3
        c.seedText = "42"
        c.resultName = "mine"
        XCTAssertEqual(c.command,
                       "design_backbone rfd3, target, sele, length=60, n_designs=5, "
                       + "diffusion_steps=30, recycling_steps=3, seed=42, name=mine")
    }

    @MainActor
    func testANonNumericSeedIsDroppedRatherThanPassedThrough() {
        // Dropped keeps the command runnable and the default -- a fresh random seed --
        // applies. Passing it through would make Generate fail on a typo.
        let c = controller()
        c.seedText = "abc"
        XCTAssertFalse(c.command.contains("seed"))
    }

    @MainActor
    func testASelectionWithSpacesNeedsNoQuotingButACommaIsRemoved() {
        // PyMOL splits arguments on COMMAS, so a selection with spaces is one argument and
        // needs no quotes -- while a comma inside one cannot be passed at all and would
        // silently truncate it. Half a selection is a design against the wrong structure.
        let c = controller()
        c.targetText = "1ao6 and chain A and resi 100-200"
        XCTAssertTrue(c.command.contains("1ao6 and chain A and resi 100-200"))
        XCTAssertEqual(DesignBackboneController.sanitise("resi 45,48"), "resi 45 48")
        XCTAssertEqual(DesignBackboneController.sanitise("  sele\n"), "sele")
    }

    @MainActor
    func testTheTargetDefaultsToALoadedObjectNotToSele() {
        // Both fields defaulting to `sele` made the target BE the hotspots: the bar opened
        // reading "3 res · 3 hotspots" against a 40-residue structure. Target is the thing
        // the interface is part of, so it is seeded from a loaded object; hotspots stay
        // `sele`, which is what the viewport writes.
        let c = DesignBackboneController()
        XCTAssertEqual(c.targetText, "")
        XCTAssertEqual(c.hotspotsText, "sele")
        c.prepare(defaultTarget: "1ao6")
        XCTAssertEqual(c.targetText, "1ao6")
        XCTAssertEqual(c.hotspotsText, "sele")
    }

    @MainActor
    func testSeedingNeverClobbersATargetTheUserTyped() {
        let c = DesignBackboneController()
        c.targetText = "chain A and resi 100-200"
        c.prepare(defaultTarget: "1ao6")
        XCTAssertEqual(c.targetText, "chain A and resi 100-200")
    }

    @MainActor
    func testGenerateIsRefusedUntilATargetHasResolved() {
        // `canRun` gates on the RESOLVED target, not on the text being non-empty: the
        // fields are prefilled with "sele", so gating on text alone would offer Generate
        // before anything had been picked.
        let c = DesignBackboneController()
        c.generator = "rfd3"
        c.targetText = "target"
        XCTAssertNil(c.target)
        XCTAssertFalse(c.canRun)
        c.target = DesignTargetInfo(residues: 40, chain: "A", state: 1, hotspots: 3)
        XCTAssertTrue(c.canRun)
        // A resolve error re-closes it even with a target in hand: the bar must not offer
        // a run the command layer has already said it will refuse.
        c.resolveError = "hotspots are not inside the target"
        XCTAssertFalse(c.canRun)
    }

    @MainActor
    func testRunWithNothingResolvedReportsInTheBarRatherThanSilently() {
        let c = DesignBackboneController()
        c.generator = "rfd3"
        var ran: [String] = []
        c.runCommandSeam = { ran.append($0) }
        c.run()
        XCTAssertTrue(ran.isEmpty, "nothing may be submitted")
        XCTAssertNotNil(c.runError)
    }

    @MainActor
    func testRunSubmitsThroughTheCommandChannel() {
        let c = controller()
        var ran: [String] = []
        c.runCommandSeam = { ran.append($0) }
        c.run()
        XCTAssertEqual(ran, [c.command])
    }

    @MainActor
    func testTheFormPayloadDecodesFromWhatPythonWrites() throws {
        // Verbatim from the shape appkit_design.emit writes.
        let json = """
        {"generators":[{"id":"rfd3"}],
         "target":{"residues":40,"chain":"A","state":1,"hotspots":3},
         "error":null}
        """
        let payload = try JSONDecoder().decode(DesignFormPayload.self,
                                               from: Data(json.utf8))
        let c = DesignBackboneController()
        c.targetText = "target"
        c.loadFormPayload(payload)
        XCTAssertEqual(c.generator, "rfd3", "the only generator is selected for you")
        XCTAssertEqual(c.target?.residues, 40)
        XCTAssertEqual(c.target?.hotspots, 3)
        XCTAssertNil(c.resolveError)
        XCTAssertTrue(c.canRun)
    }

    @MainActor
    func testLiveViewIsOffByDefaultAndAbsentFromTheCommand() {
        // A 50-state object is a reasonable thing to opt into and an unreasonable thing to
        // be given, so the command carries the flag only when it is on.
        let c = controller()
        XCTAssertFalse(c.liveView)
        XCTAssertFalse(c.command.contains("live_view"))
    }

    @MainActor
    func testLiveViewAppearsInTheCommandWhenOn() {
        let c = controller()
        c.liveView = true
        XCTAssertEqual(c.command,
                       "design_backbone rfd3, target, sele, length=60, live_view=1")
    }

    @MainActor
    func testKeepFramesIsOffByDefaultAndAbsentFromTheCommand() {
        let c = controller()
        XCTAssertFalse(c.keepFrames, "watching is the point; the states are opt-in")
        c.liveView = true
        XCTAssertFalse(c.command.contains("keep_frames"))
    }

    @MainActor
    func testKeepFramesAppearsInTheCommandOnlyWithLiveOn() {
        let c = controller()
        c.liveView = true
        c.keepFrames = true
        XCTAssertEqual(c.command,
                       "design_backbone rfd3, target, sele, length=60, live_view=1,"
                       + " keep_frames=1")
    }

    @MainActor
    func testARememberedKeepFramesTickCannotComposeTheContradiction() {
        // The checkbox keeps its value while greyed, so `keepFrames` can be true with
        // Live off. `keep_frames=1, live_view=0` is a contradiction Python REFUSES, so
        // the command must not contain it -- a remembered preference must not be able to
        // make Generate fail.
        let c = controller()
        c.keepFrames = true
        c.liveView = false
        XCTAssertFalse(c.command.contains("keep_frames"), c.command)
        XCTAssertFalse(c.command.contains("live_view"), c.command)
        // And it comes back when Live is switched on again, rather than being forgotten.
        c.liveView = true
        XCTAssertTrue(c.command.contains("keep_frames=1"), c.command)
    }

    // MARK: Unguided placement, and the typed numbers

    @MainActor
    func testAnEmptyHotspotFieldOmitsTheArgumentEntirely() {
        // NOT `design_backbone rfd3, target, , length=60`. PyMOL's parser splits on
        // commas and has no spelling for "skip this positional", so an empty slot would
        // be passed as the empty string in the LENGTH position on any future reordering
        // -- and reading it back from the console history, a human sees a typo. Leaving
        // the argument out takes the Python default, which is "unguided".
        let c = controller()
        c.hotspotsText = ""
        XCTAssertEqual(c.command, "design_backbone rfd3, target, length=60")
    }

    @MainActor
    func testAWhitespaceOnlyHotspotFieldIsTheSameAsEmpty() {
        let c = controller()
        c.hotspotsText = "   "
        XCTAssertEqual(c.command, "design_backbone rfd3, target, length=60")
    }

    @MainActor
    func testGenerateStaysOpenWithNoHotspots() {
        // The bar must not refuse in the UI what the command accepts. Zero hotspots is a
        // resolved target like any other -- it is unguided, not invalid.
        let c = controller()
        c.hotspotsText = ""
        c.target = DesignTargetInfo(residues: 40, chain: "A", state: 1, hotspots: 0)
        XCTAssertTrue(c.canRun)
    }

    func testATypedNumberInRangeIsTakenAsItIs() {
        XCTAssertEqual(
            DesignBackboneController.committed("120", into: 1...150, fallback: 60), 120)
        // Surrounding whitespace is not a typo worth punishing.
        XCTAssertEqual(
            DesignBackboneController.committed("  75 ", into: 1...150, fallback: 60), 75)
    }

    func testATypedNumberOutOfRangeIsClampedNotRefused() {
        // The stepper beside the box cannot leave the range, so the box must not be able
        // to compose a command the bar could not otherwise compose. The caller writes the
        // clamped value back into the field, so the snap is visible.
        XCTAssertEqual(
            DesignBackboneController.committed("999", into: 1...150, fallback: 60), 150)
        XCTAssertEqual(
            DesignBackboneController.committed("0", into: 1...150, fallback: 60), 1)
        XCTAssertEqual(
            DesignBackboneController.committed("-4", into: 1...10, fallback: 1), 1)
    }

    func testUnparseableTextRevertsRatherThanSubstitutingABound() {
        // There is no number to honour, and clamping "" to 1 would silently change a
        // setting the user never touched. Reverting is the only non-destructive answer.
        for text in ["", "   ", "abc", "4.5", "42x", "1e3", "٤٢"] {
            XCTAssertEqual(
                DesignBackboneController.committed(text, into: 1...150, fallback: 60), 60,
                "\(text.debugDescription) must leave the value alone")
        }
    }

    @MainActor
    func testAResolveErrorPayloadClosesGenerate() throws {
        let json = """
        {"generators":[{"id":"rfd3"}],"target":null,
         "error":"the hotspot selection 'sele' selects no atoms"}
        """
        let payload = try JSONDecoder().decode(DesignFormPayload.self,
                                               from: Data(json.utf8))
        let c = DesignBackboneController()
        c.loadFormPayload(payload)
        XCTAssertEqual(c.resolveError, "the hotspot selection 'sele' selects no atoms")
        XCTAssertFalse(c.canRun)
    }

    @MainActor
    func testAHostWithNoRunnableGeneratorOffersNothing() throws {
        // Under headless PyMOL, or a build without the runtime, `_generators()` is empty
        // and the bar must offer nothing rather than something that refuses at submit.
        let payload = try JSONDecoder().decode(
            DesignFormPayload.self,
            from: Data("{\"generators\":[],\"target\":null,\"error\":null}".utf8))
        let c = DesignBackboneController()
        c.loadFormPayload(payload)
        XCTAssertEqual(c.generator, "")
        XCTAssertFalse(c.canRun)
    }
}
#endif
