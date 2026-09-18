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
        // it never touches the source object's atoms.
        XCTAssertTrue(copyToObjectCommand(sele: "sele", target: "1ubq")
            .contains("cmd.copy_to(\"1ubq\", \"(sele)\", zoom=0, quiet=0)"),
                      copyToObjectCommand(sele: "sele", target: "1ubq"))
    }

    /// quiet=0 so the console reports the atom count — the panel itself gives no
    /// feedback that a merge happened.
    func testCopyToExistingObjectIsNotQuiet() {
        XCTAssertTrue(copyToObjectCommand(sele: "sele", target: "obj").contains("quiet=0"))
    }

    /// cmd.copy_to disables every object the selection lives in. The source row
    /// stays in the panel, so its checkbox clearing on its own looks like the
    /// copy consumed the original — capture the enabled ones and switch them back.
    func testCopyToExistingObjectRestoresSourceVisibility() {
        let cmd = copyToObjectCommand(sele: "sele", target: "obj")
        XCTAssertTrue(cmd.contains("cmd.get_object_list(\"(sele)\")"), cmd)
        XCTAssertTrue(cmd.contains("enabled_only=1"),
                      "only the sources that were VISIBLE may be switched back on")
        XCTAssertTrue(cmd.contains("[cmd.enable(o) for o in _on]"), cmd)
        // Order matters: capture, copy, restore.
        guard let capture = cmd.range(of: "_on = ["),
              let copy = cmd.range(of: "cmd.copy_to("),
              let restore = cmd.range(of: "[cmd.enable(o)") else {
            return XCTFail("copy command lost one of its three steps: \(cmd)")
        }
        XCTAssertTrue(capture.lowerBound < copy.lowerBound, "must capture BEFORE copying")
        XCTAssertTrue(copy.lowerBound < restore.lowerBound, "must restore AFTER copying")
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

    // MARK: - New-object name validation

    /// PyMOL's legal set is A–Z, a–z, 0–9 and + - . ^ _ (ObjectMakeValidName).
    func testLegalNamesAreAccepted() {
        for name in ["obj01", "ligand", "A", "9", "a_b", "a-b", "a+b", "a.b", "a^b", "Obj_01-x.y"] {
            XCTAssertTrue(isLegalObjectName(name), "'\(name)' should be legal")
        }
    }

    /// A space or a bang is not an error in the engine — it silently rewrites the
    /// name (`my obj!` becomes `my_obj`), so the panel would show a name the user
    /// never typed. Catch it while they can still see the field.
    func testNamesTheEngineWouldRewriteAreRejected() {
        for name in ["my obj", "obj!", "obj#1", "α", "obj/1", "obj\\1", ""] {
            XCTAssertFalse(isLegalObjectName(name), "'\(name)' should be rejected")
        }
    }

    /// A comma is the argument separator: `create foo, bar, (sele), zoom=0`
    /// throws a Python traceback into the console feed.
    func testACommaInTheNameIsRejected() {
        XCTAssertFalse(isLegalObjectName("foo, bar"))
        XCTAssertFalse(isLegalObjectName("foo,bar"))
    }

    /// `create` against an existing name does nothing at all — no object, no
    /// error — so an unchecked collision makes the Copy button silently fail.
    func testAnAlreadyTakenNameCannotNameANewObject() {
        let existing = ["mol", "mysele", "obj01"]
        XCTAssertFalse(canNameNewObject("mol", existing: existing))
        XCTAssertFalse(canNameNewObject("mysele", existing: existing),
                       "selections share the object namespace")
        XCTAssertFalse(canNameNewObject("obj01", existing: existing))
        XCTAssertTrue(canNameNewObject("obj02", existing: existing))
    }

    /// The prefilled default must itself always pass the check it is offered for.
    func testTheDefaultNameIsAlwaysUsable() {
        for existing in [[], ["obj01"], ["obj01", "obj02", "mol"], ["a b", "obj01"]] as [[String]] {
            let name = defaultNewObjectName(existing: existing)
            XCTAssertTrue(canNameNewObject(name, existing: existing),
                          "default '\(name)' rejected against \(existing)")
        }
    }

    // MARK: - Menu layout

    /// Two separators in a row render as a doubled divider. The section is spliced
    /// in just before Move to Group, riding the separator already there and adding
    /// one after, so no pair of them may end up adjacent.
    func testNoDoubledSeparators() {
        for items in [actionMenuItems(isSelection: true),
                      actionMenuItems(isSelection: false),
                      actionMenuItems(isSelection: false, isGroup: true)] {
            var lastWasSeparator = false
            for (i, item) in items.enumerated() {
                if case .separator = item {
                    XCTAssertFalse(lastWasSeparator, "doubled separator at index \(i)")
                    lastWasSeparator = true
                } else {
                    lastWasSeparator = false
                }
            }
        }
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
