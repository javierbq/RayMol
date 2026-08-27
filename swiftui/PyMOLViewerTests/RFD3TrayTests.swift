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
                     remaining: Double? = 300) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: phase, fraction: fraction,
                           moving: moving, detail: "d", modelsDone: 0, modelsTotal: 1,
                           elapsed: elapsed, error: error, bundle: bundle,
                           step: step, totalSteps: totalSteps, remaining: remaining)
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
