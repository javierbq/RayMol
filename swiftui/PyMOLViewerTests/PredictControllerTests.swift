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
}
#endif
