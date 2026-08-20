#if os(macOS)
import XCTest
@testable import RayMol

final class PredictControllerTests: XCTestCase {

    // MARK: composition

    func testPredictPythonMinimal() {
        let s = PredictController.predictPython(
            predictor: "boltz2", input: "MKTAY", nModels: 1,
            recyclingSteps: 3, diffusionSteps: 200,
            seed: nil, msaDepth: nil, name: nil, msa: nil)
        XCTAssertTrue(s.contains("_c.predict('boltz2', 'MKTAY'"))
        XCTAssertTrue(s.contains("n_models=1"))
        XCTAssertTrue(s.contains("recycling_steps=3"))
        XCTAssertTrue(s.contains("diffusion_steps=200"))
        XCTAssertFalse(s.contains("seed="))       // omitted → fresh per run
        XCTAssertFalse(s.contains("msa_depth="))
        XCTAssertFalse(s.contains("name="))
        XCTAssertFalse(s.contains("msa="))
    }

    func testPredictPythonEscapesSelectionAndAddsOptions() {
        let s = PredictController.predictPython(
            predictor: "boltz2", input: "1ubq and chain A", nModels: 5,
            recyclingSteps: 3, diffusionSteps: 300,
            seed: 42, msaDepth: 256, name: "my pred", msa: "alnA//alnC")
        XCTAssertTrue(s.contains("_c.predict('boltz2', '1ubq and chain A'"))
        XCTAssertTrue(s.contains("n_models=5"))
        XCTAssertTrue(s.contains("diffusion_steps=300"))
        XCTAssertTrue(s.contains("seed=42"))
        XCTAssertTrue(s.contains("msa_depth=256"))
        XCTAssertTrue(s.contains("name='my pred'"))
        XCTAssertTrue(s.contains("msa='alnA//alnC'"))
    }

    func testMsaSearchPythonObjectPath() {
        let s = PredictController.msaSearchPython(
            sequence: "1ubq and chain A", name: "predui_x", target: "1ubq",
            chain: "A", mode: "env", server: "")
        XCTAssertTrue(s.contains("_c.msa_search('1ubq and chain A'"))
        XCTAssertTrue(s.contains("name='predui_x'"))
        XCTAssertTrue(s.contains("target='1ubq'"))
        XCTAssertTrue(s.contains("chain='A'"))
        XCTAssertTrue(s.contains("mode='env'"))
        XCTAssertFalse(s.contains("server="))     // blank → use the setting/default
    }

    func testMsaSearchPythonLiteralPathHasNoTarget() {
        let s = PredictController.msaSearchPython(
            sequence: "MKTAY", name: "predui_y", target: "", chain: "",
            mode: "all", server: "https://msa.internal")
        XCTAssertTrue(s.contains("_c.msa_search('MKTAY'"))
        XCTAssertTrue(s.contains("name='predui_y'"))
        XCTAssertFalse(s.contains("target="))
        XCTAssertFalse(s.contains("chain="))
        XCTAssertTrue(s.contains("mode='all'"))
        XCTAssertTrue(s.contains("server='https://msa.internal'"))
    }

    func testLiteralChainSequencesSplitStripUpper() {
        XCTAssertEqual(PredictController.literalChainSequences(" mkt ay / gshma "),
                       ["MKTAY", "GSHMA"])
    }

    func testMsaSlotsOrderedWithEmptyForUnselected() {
        let chains = [
            PredictChain(id: "A", length: 5, object: "", chain: ""),
            PredictChain(id: "B", length: 5, object: "", chain: ""),
            PredictChain(id: "C", length: 5, object: "", chain: ""),
        ]
        let slots = PredictController.msaSlots(
            orderedChains: chains,
            requested: ["A", "C"],
            nameFor: { "aln\($0.id)" })
        XCTAssertEqual(slots, "alnA//alnC")
    }

    func testFormPayloadDecodes() throws {
        let json = """
        {"predictors":[{"id":"boltz2","msa":true},{"id":"protenix","msa":false}],
         "chains":[{"id":"A","length":129,"object":"1ubq","chain":"A"}],
         "error":null}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PredictFormPayload.self, from: json)
        XCTAssertEqual(payload.predictors.map(\.id), ["boltz2", "protenix"])
        XCTAssertFalse(payload.predictors[1].msa)
        XCTAssertEqual(payload.chains.first?.length, 129)
        XCTAssertTrue(payload.chains.first!.isFromObject)
        XCTAssertNil(payload.error)
    }

    // MARK: Task 2 deferred — direct coverage of pure statics

    func testFNVDigestIsPinned() {
        // FNV-1a 32-bit hash of "MKTAY" — pinned so any future change to the hash is caught.
        XCTAssertEqual(PredictController.fnvHex("MKTAY"), "6c788fb1")
    }

    func testAlignmentBaseNameObjectPath() {
        let ch = PredictChain(id: "A", length: 129, object: "1ubq", chain: "A")
        XCTAssertEqual(PredictController.alignmentBaseName(for: ch, literalSequence: nil),
                       "predui_1ubq_A")
    }

    func testAlignmentBaseNameLiteralPath() {
        let ch = PredictChain(id: "A", length: 5, object: "", chain: "")
        let name = PredictController.alignmentBaseName(for: ch, literalSequence: "MKTAY")
        XCTAssertEqual(name, "predui_\(PredictController.fnvHex("MKTAY"))_A")
    }
}

@MainActor
final class PredictControllerRunTests: XCTestCase {

    private let gib = 1024 * 1024 * 1024

    private func makeController(captured: NSMutableArray) -> PredictController {
        let c = PredictController()
        c.runPythonSeam = { captured.add($0) }
        c.availableBytesProvider = { 64 * (1024 * 1024 * 1024) }  // never warns
        return c
    }

    private func chain(_ id: String, _ len: Int, obj: String = "", ch: String = "")
        -> PredictChain { PredictChain(id: id, length: len, object: obj, chain: ch) }

    func testRunWithoutMSASubmitsPredictImmediately() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 30)], error: nil))
        c.inputText = "MKTAY"
        c.predictor = "boltz2"
        c.nModels = 3
        c.run()
        // Submitting hands the job to the tray and returns the bar to ready (.idle),
        // rather than dwelling on a sticky "submitted" status.
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(cmds.count, 1)
        let sent = cmds[0] as! String
        XCTAssertTrue(sent.contains("_c.predict('boltz2', 'MKTAY'"))
        XCTAssertTrue(sent.contains("n_models=3"))
    }

    func testRunWithMSAObjectPathStartsSearchesThenPredicts() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"
        c.predictor = "boltz2"
        c.useMSA = true
        c.msaChains = ["A"]
        c.run()

        // A search started; not predicting yet. The search is chain-SCOPED —
        // msa_search refuses a complex, so per-chain scoping is required even for a
        // single-chain object.
        XCTAssertEqual(c.phase, .searching(remaining: 1))
        XCTAssertEqual(cmds.count, 1)
        XCTAssertTrue((cmds[0] as! String).contains("_c.msa_search('(1ubq) and chain A'"))
        XCTAssertTrue((cmds[0] as! String).contains("target='1ubq'"))
        XCTAssertTrue((cmds[0] as! String).contains("chain='A'"))

        // The alignment lands (name matches predui_1ubq_A, attached to 1ubq/A).
        let landed = AlignmentEntry(id: "aln", name: "predui_1ubq_A", depth: 8,
                                    columns: 60, residues: 60, target: "1ubq", chain: "A")
        c.onEngineState(alignments: [landed], searches: [])

        XCTAssertEqual(c.phase, .idle)   // submitted → bar back to ready; tray owns progress
        XCTAssertEqual(cmds.count, 2)
        // Object path: predict does NOT carry an msa= arg (auto-attach).
        XCTAssertFalse((cmds[1] as! String).contains("msa="))
        XCTAssertTrue((cmds[1] as! String).contains("_c.predict('boltz2', '1ubq'"))
    }

    func testMSALiteralPathPassesSlots() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 5), chain("B", 5)], error: nil))
        c.inputText = "MKTAY/GSHMA"
        c.predictor = "boltz2"
        c.useMSA = true
        c.msaChains = ["A"]              // only chain A gets an MSA
        c.run()
        XCTAssertEqual(c.phase, .searching(remaining: 1))
        let name = PredictController.alignmentBaseName(
            for: c.chains[0], literalSequence: "MKTAY")
        let landed = AlignmentEntry(id: "aln", name: name, depth: 4, columns: 5,
                                    residues: 5, target: "", chain: "")
        c.onEngineState(alignments: [landed], searches: [])
        XCTAssertEqual(c.phase, .idle)   // submitted → bar back to ready
        XCTAssertTrue((cmds.lastObject as! String).contains("msa='\(name)/'"))  // B empty
    }

    func testSearchThatVanishesWithoutLandingIsAnError() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"; c.predictor = "boltz2"; c.useMSA = true; c.msaChains = ["A"]
        c.run()
        // Fix B: the FIRST tick with no alignment and no running search burns the grace tick
        // — the search hasn't had time to appear in engine.msaSearches yet.
        c.onEngineState(alignments: [], searches: [])
        XCTAssertEqual(c.phase, .searching(remaining: 1), "first tick must NOT error (grace)")
        XCTAssertEqual(cmds.count, 1)   // predict still not submitted
        // SECOND tick with neither alignment nor running search → genuinely failed.
        c.onEngineState(alignments: [], searches: [])
        guard case .error = c.phase else { return XCTFail("expected error phase on second tick") }
        XCTAssertEqual(cmds.count, 1)   // predict was never submitted
    }

    func testAlreadySatisfiedChainSkipsSearchAndPredictsDirect() {
        // Fix A: if the alignment is already present when run() is called, no msa_search
        // is fired and predict is submitted immediately (no .searching phase).
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"; c.predictor = "boltz2"; c.useMSA = true; c.msaChains = ["A"]
        // Feed the matching alignment while idle — latestAlignments is populated.
        let existing = AlignmentEntry(id: "aln", name: "predui_1ubq_A", depth: 8,
                                      columns: 60, residues: 60, target: "1ubq", chain: "A")
        c.onEngineState(alignments: [existing], searches: [])
        XCTAssertEqual(c.phase, .idle, "onEngineState while idle must not change phase")
        c.run()
        // Already satisfied → no msa_search, goes straight to predict, then back to idle.
        XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(cmds.count, 1)
        XCTAssertFalse((cmds[0] as! String).contains("msa_search"), "no search needed")
        XCTAssertTrue((cmds[0] as! String).contains("_c.predict("))
        XCTAssertFalse((cmds[0] as! String).contains("msa="), "object path: no msa= arg")
    }

    func testOversizeRaisesWarningNotSubmit() {
        let cmds = NSMutableArray()
        let c = PredictController()
        c.runPythonSeam = { cmds.add($0) }
        c.availableBytesProvider = { 4 * (1024 * 1024 * 1024) }  // small machine
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 120)], error: nil))
        c.inputText = "…120 residues…"; c.predictor = "boltz2"
        c.run()
        XCTAssertNotNil(c.pendingSizeWarning)
        XCTAssertEqual(cmds.count, 0)          // nothing submitted yet
        c.confirmPendingWarning()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(c.phase, .idle)   // confirm → submit → bar back to ready
        XCTAssertEqual(cmds.count, 1)
    }

    func testCancelDuringSearchPreventsAutoSubmit() {
        // Fix 1: cancel() during .searching must stop the state machine so that a
        // subsequently-landed alignment does NOT trigger submitPredict.
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"; c.predictor = "boltz2"; c.useMSA = true; c.msaChains = ["A"]

        // Start the MSA flow — should be .searching with one msa_search command sent.
        c.run()
        XCTAssertEqual(c.phase, .searching(remaining: 1))
        XCTAssertEqual(cmds.count, 1)

        // Cancel — must send msa_cancel, clear plannedNames, and reset to idle.
        c.cancel()
        XCTAssertEqual(c.phase, .idle, "cancel must reset phase to .idle")
        XCTAssertTrue((cmds.lastObject as! String).contains("msa_cancel"),
                      "cancel must send msa_cancel command")
        let countAfterCancel = cmds.count

        // Simulate the alignment landing AFTER cancel — must not auto-submit predict.
        let landed = AlignmentEntry(id: "aln", name: "predui_1ubq_A", depth: 8,
                                    columns: 60, residues: 60, target: "1ubq", chain: "A")
        c.onEngineState(alignments: [landed], searches: [])
        XCTAssertEqual(c.phase, .idle, "landed alignment after cancel must not change phase")
        XCTAssertEqual(cmds.count, countAfterCancel, "no predict submitted after cancel")
    }

    func testPredictorSelectionDefaultsToFirst() {
        let c = PredictController()
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true),
                         PredictorInfo(id: "protenix", msa: false)],
            chains: [], error: nil))
        XCTAssertEqual(c.predictor, "boltz2")
    }
}
#endif
