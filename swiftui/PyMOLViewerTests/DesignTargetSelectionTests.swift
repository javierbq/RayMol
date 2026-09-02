#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

/// The Design tool's two typed inputs (#371): a `target` field that accepts an
/// object name OR a selection expression, and a `selection` field that writes the
/// region through PyMOL's 'sele' so the click-to-select path stays the one
/// pipeline. Both mirror Design Backbone / Predict, which take a text box plus an
/// optional dropdown that populates it.
@MainActor
final class DesignTargetSelectionTests: XCTestCase {

    // Two designable residues, enough for `syncFromSele` to reach region mode.
    private func residueSet(_ object: String) -> DesignResidueSet {
        DesignResidueSet(object: object, state: 1, residues: (1...3).map { i in
            DesignResidue(chain: "A", resi: "\(i)", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero,
                                          chain: 0, resSeq: i),
                          valid: true)
        })
    }

    private func makeController(objects: [String]) -> DesignController {
        let c = DesignController(
            enumerate: { [self] obj, _ in residueSet(obj) },
            score: { r, _ in
                MPNNModel.ScoreResult(
                    logProbs: Array(repeating: [Float](repeating: Float(log(1.0 / 21.0)),
                                                       count: 21),
                                    count: r.count),
                    currentAALogProb: [Float](repeating: -1.0, count: r.count))
            },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        c.allObjects = objects
        return c
    }

    // MARK: – Target field

    func testTargetFieldFocusesATypedObjectName() async {
        let c = makeController(objects: ["m1", "m2"])
        c.enter()
        c.targetText = "m2"
        await c.applyTargetAwait()
        XCTAssertEqual(c.focusObject, "m2")
        XCTAssertNil(c.errorText)
    }

    func testTargetFieldResolvesASelectionExpressionToItsObject() async {
        let c = makeController(objects: ["m1", "m2"])
        var asked: [String] = []
        c.injectFields(resolveTarget: { expr in
            asked.append(expr)
            return expr.contains("chain A") ? "m1" : nil
        })
        c.enter()
        c.targetText = "polymer and chain A"
        await c.applyTargetAwait()
        XCTAssertEqual(asked, ["polymer and chain A"])
        XCTAssertEqual(c.focusObject, "m1")
        XCTAssertEqual(c.targetText, "polymer and chain A",
                       "The typed expression must survive the focus it caused")
        XCTAssertNil(c.errorText)
    }

    func testTargetFieldReportsAnExpressionThatMatchesNothing() async {
        let c = makeController(objects: ["m1", "m2"])
        c.injectFields(resolveTarget: { _ in nil })
        c.enter()
        await c.focusAwait("m1")
        c.targetText = "chain Z"
        await c.applyTargetAwait()
        XCTAssertEqual(c.focusObject, "m1", "A bad target must not drop the focus")
        XCTAssertEqual(c.errorText, "No structure matches 'chain Z'")
    }

    func testTargetFieldIgnoresEmptyInput() async {
        let c = makeController(objects: ["m1", "m2"])
        var asked = 0
        c.injectFields(resolveTarget: { _ in asked += 1; return "m1" })
        c.enter()
        c.targetText = "   "
        await c.applyTargetAwait()
        XCTAssertEqual(asked, 0)
        XCTAssertNil(c.focusObject)
        XCTAssertNil(c.errorText)
    }

    func testFocusingFromTheDropdownFillsTheTargetField() async {
        let c = makeController(objects: ["m1", "m2"])
        c.enter()
        await c.focusAwait("m2")        // what the cube menu's Button does
        XCTAssertEqual(c.targetText, "m2")
    }

    // MARK: – Selection field

    func testSelectionFieldRewritesSeleFromAnExpression() async {
        let c = makeController(objects: ["m1", "m2"])
        var selected: [String] = []
        var seleIndices: [Int] = []
        c.injectFields(selectRegion: { expr in
            selected.append(expr)
            seleIndices = [0, 1, 2]
            return 3
        })
        c.injectSele(seleState: { _, _, _ in (seleIndices, "d\(seleIndices.count)", 0) })
        c.enter()
        await c.focusAwait("m1")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)

        c.selectionText = "  chain A and resi 1-3  "
        c.applySelection()
        XCTAssertEqual(selected, ["chain A and resi 1-3"], "Expression is trimmed, then written to 'sele'")
        XCTAssertEqual(c.selectedResidueIndices, [0, 1, 2], "The region must re-derive from 'sele' at once")
        XCTAssertNil(c.errorText)
    }

    func testSelectionFieldLeavesAClickedSelectionAloneForTheLiteralSele() async {
        let c = makeController(objects: ["m1", "m2"])
        var selectCalls = 0
        c.injectFields(selectRegion: { _ in selectCalls += 1; return 0 })
        c.injectSele(seleState: { _, _, _ in ([0, 1], "clicked", 0) })
        c.enter()
        await c.focusAwait("m1")

        c.selectionText = "sele"
        c.applySelection()
        XCTAssertEqual(selectCalls, 0, "Rewriting 'sele' from itself would clobber the user's clicks")
        XCTAssertEqual(c.selectedResidueIndices, [0, 1])
        XCTAssertNil(c.errorText)
    }

    func testSelectionFieldNormalisesEmptyInputBackToSele() async {
        let c = makeController(objects: ["m1", "m2"])
        var selectCalls = 0
        c.injectFields(selectRegion: { _ in selectCalls += 1; return 0 })
        c.enter()
        await c.focusAwait("m1")

        c.selectionText = ""
        c.applySelection()
        XCTAssertEqual(c.selectionText, "sele")
        XCTAssertEqual(selectCalls, 0)
    }

    func testSelectionFieldReportsAnExpressionThatMatchesNothing() async {
        let c = makeController(objects: ["m1", "m2"])
        c.injectFields(selectRegion: { _ in 0 })
        c.injectSele(seleState: { _, _, _ in ([], "empty", 0) })
        c.enter()
        await c.focusAwait("m1")

        c.selectionText = "resi 999"
        c.applySelection()
        XCTAssertEqual(c.errorText, "No residues match 'resi 999'")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
    }

    func testSelectionFieldReportsAnInvalidExpression() async {
        let c = makeController(objects: ["m1", "m2"])
        c.injectFields(selectRegion: { _ in nil })   // nil = PyMOL rejected the selector
        c.enter()
        await c.focusAwait("m1")

        c.selectionText = "chain (("
        c.applySelection()
        XCTAssertEqual(c.errorText, "Invalid selection 'chain (('")
    }

    func testScopeButtonRestoresTheLiteralSele() async {
        let c = makeController(objects: ["m1", "m2"])
        var selectCalls = 0
        c.injectFields(selectRegion: { _ in selectCalls += 1; return 0 })
        c.injectSele(seleState: { _, _, _ in ([0, 1], "clicked", 0) })
        c.enter()
        await c.focusAwait("m1")

        c.selectionText = "chain B"
        c.useCurrentSelection()
        XCTAssertEqual(c.selectionText, "sele")
        XCTAssertEqual(selectCalls, 0, "The scope button reads the live selection; it never rewrites it")
        XCTAssertEqual(c.selectedResidueIndices, [0, 1])
    }
}
#endif
