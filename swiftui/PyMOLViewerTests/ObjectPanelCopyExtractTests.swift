import XCTest
@testable import RayMol

/// Covers the "Copy to Object" (#461) and "Extract" (#468) entries added to the
/// Objects-panel action menu.
///
/// The commands are built by free functions rather than inline in the SwiftUI
/// closures precisely so they can be asserted here: a wrong `zoom`, a missing
/// `extract=`, or a dropped cleanup step is invisible in a screenshot but
/// changes what happens to the user's structure.
final class ObjectPanelCopyExtractTests: XCTestCase {

    // MARK: - Menu composition

    /// The section is selection-only, matching desktop PyMOL, where both verbs
    /// live in the `else:` branch of `if object:` (modules/pymol/menu.py:1183).
    func testCopyExtractShownOnSelectionsOnly() {
        XCTAssertTrue(hasCopyToObject(actionMenuItems(isSelection: true)))
        XCTAssertTrue(hasExtractSubmenu(actionMenuItems(isSelection: true)))

        XCTAssertFalse(hasCopyToObject(actionMenuItems(isSelection: false)))
        XCTAssertFalse(hasExtractSubmenu(actionMenuItems(isSelection: false)))

        let group = actionMenuItems(isSelection: false, isGroup: true)
        XCTAssertFalse(hasCopyToObject(group))
        XCTAssertFalse(hasExtractSubmenu(group))
    }

    /// A group row is a group row even when the caller also says "selection" —
    /// the isGroup branch returns before the selection extras are added.
    func testGroupWinsOverSelection() {
        let items = actionMenuItems(isSelection: true, isGroup: true)
        XCTAssertFalse(hasCopyToObject(items))
        XCTAssertFalse(hasExtractSubmenu(items))
    }

    /// Extract offers PyMOL's three reaches (menu.py:47), in upstream's order.
    func testExtractSubmenuOffersAllThreeScopes() {
        let keys = extractSubmenuKeys(actionMenuItems(isSelection: true))
        XCTAssertEqual(keys, ["extract_object", "extract_extend_1", "extract_byres_extend_1"])
    }

    /// Copy/Extract sits in the object-management tail, above "Move to Group",
    /// where upstream keeps it ("duplicate, copy to object, extract object").
    func testCopyExtractPrecedesMoveToGroup() {
        let items = actionMenuItems(isSelection: true)
        guard let copyIdx = items.firstIndex(where: { if case .copyToObject = $0 { return true }; return false }),
              let groupIdx = items.firstIndex(where: { if case .moveToGroup = $0 { return true }; return false })
        else { return XCTFail("expected both a Copy to Object and a Move to Group row") }
        XCTAssertLessThan(copyIdx, groupIdx)
    }

    /// Adding the section must not cost the selection anything it already had.
    func testSelectionKeepsRemoveAtoms() {
        XCTAssertTrue(actionKeys(actionMenuItems(isSelection: true)).contains("remove_atoms"))
    }

    // MARK: - Copy commands

    func testCopyToExistingObjectLeavesSourceIntact() {
        // copy_to (not create) is what renames chain/segi/ID on the way in, and
        // it never touches the source object.
        XCTAssertEqual(copyToObjectCommand(sele: "sele", target: "1ubq"),
                       "copy_to 1ubq, (sele), zoom=0, quiet=0")
    }

    /// quiet=0 so the console reports the atom count — the panel itself gives no
    /// feedback that a merge happened.
    func testCopyToExistingObjectIsNotQuiet() {
        XCTAssertTrue(copyToObjectCommand(sele: "sele", target: "obj").contains("quiet=0"))
    }

    func testCopyToNewObjectUsesCreate() {
        XCTAssertEqual(copyToNewObjectCommand(sele: "my_sele", name: "ligand"),
                       "create ligand, (my_sele), zoom=0")
    }

    /// The new object lands on top of the atoms it was copied from, so framing
    /// it would move the camera for no visible reason.
    func testCopyCommandsDoNotMoveTheCamera() {
        XCTAssertTrue(copyToObjectCommand(sele: "s", target: "o").contains("zoom=0"))
        XCTAssertTrue(copyToNewObjectCommand(sele: "s", name: "o").contains("zoom=0"))
    }

    /// A selection expression is parenthesised before it is handed to PyMOL, so
    /// an operator in the name/expression cannot re-associate the argument.
    func testSelectionIsParenthesised() {
        XCTAssertTrue(copyToObjectCommand(sele: "chain A or chain B", target: "o")
            .contains("(chain A or chain B)"))
        XCTAssertTrue(copyToNewObjectCommand(sele: "chain A or chain B", name: "o")
            .contains("(chain A or chain B)"))
    }

    // MARK: - Extract commands

    /// Plain extract: selection and extraction target are the same atoms, so the
    /// boolean form applies and PyMOL's deprecation warning is avoided.
    func testExtractObjectUsesCmdExtract() {
        let cmd = extractCommand(sele: "sele", scope: .object)
        XCTAssertTrue(cmd.contains("cmd.extract(None, \"(sele)\", zoom=0)"), cmd)
        XCTAssertFalse(cmd.contains("extract=\""), "plain extract should not need the deprecated form")
    }

    /// The widened variants copy the bonded neighbourhood but still remove only
    /// the selected atoms — hence create-selection ≠ extract-selection.
    func testExtendedExtractsCopyWiderThanTheyRemove() {
        let extend = extractCommand(sele: "sele", scope: .extend1)
        XCTAssertTrue(extend.contains("cmd.create(None, \"((sele) extend 1)\""), extend)
        XCTAssertTrue(extend.contains("extract=\"sele\""), extend)

        let byres = extractCommand(sele: "sele", scope: .byresExtend1)
        XCTAssertTrue(byres.contains("cmd.create(None, \"(byres ((sele) extend 1))\""), byres)
        XCTAssertTrue(byres.contains("extract=\"sele\""), byres)
    }

    /// `None` lets PyMOL mint obj01/obj02 itself, as the desktop menu item does.
    func testExtractAutoNamesTheNewObject() {
        for scope in ExtractScope.allCases {
            XCTAssertTrue(extractCommand(sele: "s", scope: scope).contains("None"),
                          "\(scope) should let PyMOL name the new object")
        }
    }

    /// cmd.extract only cleans up its own temporary; without this the user's
    /// selection survives with every atom gone — a live-looking 0-atom row.
    func testExtractDropsTheEmptiedSelection() {
        for scope in ExtractScope.allCases {
            XCTAssertTrue(extractCommand(sele: "my_sele", scope: scope).contains("cmd.delete(\"my_sele\")"),
                          "\(scope) should delete the now-empty selection")
        }
    }

    func testExtractNeverMovesTheCamera() {
        for scope in ExtractScope.allCases {
            XCTAssertTrue(extractCommand(sele: "s", scope: scope).contains("zoom=0"), "\(scope)")
        }
    }

    /// Routed through a python block because the `extract` console keyword
    /// requires a name and this passes None deliberately.
    func testExtractIsAWellFormedPythonBlock() {
        for scope in ExtractScope.allCases {
            let cmd = extractCommand(sele: "s", scope: scope)
            XCTAssertTrue(cmd.hasPrefix("python\n"), "\(scope): \(cmd)")
            XCTAssertTrue(cmd.hasSuffix("\npython end"), "\(scope): \(cmd)")
            // One statement line: the body must not smuggle in extra newlines,
            // which the block parser would treat as separate statements.
            XCTAssertEqual(cmd.components(separatedBy: "\n").count, 3, cmd)
        }
    }

    // MARK: - Default object name

    /// Mirrors ExecutiveMakeUnusedName: pattern %02d, starting at 1.
    func testDefaultNameStartsAtObj01() {
        XCTAssertEqual(defaultNewObjectName(existing: []), "obj01")
        XCTAssertEqual(defaultNewObjectName(existing: ["1ubq", "sele"]), "obj01")
    }

    func testDefaultNameSkipsTakenNames() {
        XCTAssertEqual(defaultNewObjectName(existing: ["obj01"]), "obj02")
        XCTAssertEqual(defaultNewObjectName(existing: ["obj01", "obj02"]), "obj03")
    }

    /// Objects, selections and groups share one namespace in PyMOL, so a name
    /// taken by any of them is taken — and the first *free* slot wins, gaps
    /// included, exactly as the C++ loop does.
    func testDefaultNameFillsGaps() {
        XCTAssertEqual(defaultNewObjectName(existing: ["obj02", "obj03"]), "obj01")
        XCTAssertEqual(defaultNewObjectName(existing: ["obj01", "obj03"]), "obj02")
    }

    /// Two-digit padding only holds to 99; past that PyMOL widens the number and
    /// so must this, or the modal would offer a name that is already taken.
    func testDefaultNameGoesPastNinetyNine() {
        let taken = (1...99).map { String(format: "obj%02d", $0) }
        XCTAssertEqual(defaultNewObjectName(existing: taken), "obj100")
    }

    // MARK: - Helpers

    private func hasCopyToObject(_ items: [ActionMenuItem]) -> Bool {
        items.contains { if case .copyToObject = $0 { return true }; return false }
    }

    private func hasExtractSubmenu(_ items: [ActionMenuItem]) -> Bool {
        items.contains {
            if case .submenu(let label, _) = $0 { return label == "Extract" }
            return false
        }
    }

    private func extractSubmenuKeys(_ items: [ActionMenuItem]) -> [String] {
        for case .submenu(let label, let children) in items where label == "Extract" {
            return actionKeys(children)
        }
        return []
    }

    private func actionKeys(_ items: [ActionMenuItem]) -> [String] {
        items.compactMap {
            if case .action(_, let key) = $0 { return key }
            return nil
        }
    }
}
