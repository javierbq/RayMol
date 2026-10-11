import XCTest
@testable import RayMol

// Regression tests for issue #222: `open a.pdb b.pdb c.pdb` from a Terminal (and
// Finder "Open With" multi-select / Dock-icon drop) only loaded the first file.
// macOS delivers all of them via NSApplicationDelegate.application(_:open:) as one
// [URL] array; RayMolAppDelegate forwards that array through handleOpenedURLs.
// These lock in that EVERY url is forwarded — a spy stands in for the real
// loadOpenedFile so the engine/PyMOL core never has to boot.
@MainActor
final class OpenFilesTests: XCTestCase {

    func testAllOpenedURLsAreForwardedInOrder() {
        let urls = ["a.pdb", "b.pdb", "c.pdb"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        var seen: [String] = []
        handleOpenedURLs(urls, into: PyMOLEngine.shared) { url, _ in
            seen.append(url.lastPathComponent)
        }
        // The bug loaded only "a.pdb"; the fix must forward all three, in order.
        XCTAssertEqual(seen, ["a.pdb", "b.pdb", "c.pdb"])
    }

    func testSingleOpenedURLStillForwarded() {
        // A plain Finder double-click delivers a one-element array; it must still
        // load (the delegate now handles single- and multi-file opens uniformly).
        let urls = [URL(fileURLWithPath: "/tmp/only.pse")]
        var seen: [String] = []
        handleOpenedURLs(urls, into: PyMOLEngine.shared) { url, _ in
            seen.append(url.lastPathComponent)
        }
        XCTAssertEqual(seen, ["only.pse"])
    }

    func testEmptyURLListIsNoOp() {
        var called = false
        handleOpenedURLs([], into: PyMOLEngine.shared) { _, _ in called = true }
        XCTAssertFalse(called)
    }

    // MARK: - Issue #272: sessions load bare — no object name, no theming

    func testSessionLoadHasNoObjectNameAndNoTheme() {
        // `load foo.pse, name` creates nothing named `name` (the session restores
        // its own objects), so the old theming call spammed `Invalid selection
        // name` on every session open — and would have clobbered the session's
        // saved colors/reps had the name resolved.
        let (command, theme) = PyMOLEngine.loadInvocation(
            path: "/tmp/open_E277B7EE.pse", name: "top6_candidates")
        XCTAssertEqual(command, "load /tmp/open_E277B7EE.pse")
        XCTAssertNil(theme)
    }

    func testSessionExtensionMatchIsCaseInsensitiveAndCoversPsw() {
        for path in ["/tmp/a.PSE", "/tmp/b.psw", "/tmp/c.Psw"] {
            let (command, theme) = PyMOLEngine.loadInvocation(path: path, name: "x")
            XCTAssertEqual(command, "load \(path)", path)
            XCTAssertNil(theme, path)
        }
    }

    func testCoordinateLoadKeepsObjectNameAndTheme() {
        let (command, theme) = PyMOLEngine.loadInvocation(
            path: "/tmp/5hbh.pdb", name: "5hbh")
        XCTAssertEqual(command, "load /tmp/5hbh.pdb, 5hbh")
        XCTAssertEqual(theme,
            "from pymol import raymol_theme as _rt; _rt.apply_to('5hbh')")
    }

    // MARK: - Issue #349: a .pse open must not silently wipe a non-empty session

    func testSessionOpenOverNonEmptySessionNeedsConfirmation() {
        let pse = URL(fileURLWithPath: "/tmp/other.pse")
        XCTAssertTrue(openWouldReplaceSession(pse, hasObjects: true))
    }

    func testSessionOpenIntoEmptySessionNeedsNoConfirmation() {
        // Cold launch from a Finder double-click: nothing to lose, no prompt.
        let pse = URL(fileURLWithPath: "/tmp/other.pse")
        XCTAssertFalse(openWouldReplaceSession(pse, hasObjects: false))
    }

    func testCoordinateOpenNeverPrompts() {
        // A .pdb/.cif ADDS an object — it doesn't replace the session.
        let pdb = URL(fileURLWithPath: "/tmp/5hbh.pdb")
        XCTAssertFalse(openWouldReplaceSession(pdb, hasObjects: true))
    }
}

// Issue #220: Save Structure used to write every object. The picker's pure logic:
// which formats it applies to, ticks -> selection expression, the save call, and the
// candidate list it is built from.
final class SaveStructureSelectionTests: XCTestCase {
    private let all = ["2kpo", "lig", "1abc"]

    func testAllObjectsIsTheOldUnqualifiedSave() {
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: Set(all), allObjects: all,
                                                     includeSelection: false), .everything)
        // sele is a subset of the objects, so ticking it too changes nothing.
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: Set(all), allObjects: all,
                                                     includeSelection: true), .everything)
        let code = SaveStructureSelection.saveCommand(path: "/tmp/s.pdb", choice: .everything)
        XCTAssertEqual(code, "from pymol import cmd as _c\n_c.save(r'''/tmp/s.pdb''')")
    }

    func testSubsetBuildsExpressionInObjectOrder() {
        // Ticked in a different order than listed: the expression follows the list.
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: ["lig", "2kpo"], allObjects: all,
                                                     includeSelection: false),
                       .subset("%2kpo or %lig"))
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: ["lig"], allObjects: all,
                                                     includeSelection: false),
                       .subset("%lig"))
    }

    func testSelectionRowAloneAndCombined() {
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: [], allObjects: all,
                                                     includeSelection: true), .subset("%sele"))
        XCTAssertEqual(SaveStructureSelection.choice(selectedObjects: ["lig"], allObjects: all,
                                                     includeSelection: true),
                       .subset("%lig or %sele"))
    }

    func testNamesWithSpecialCharactersUseTheExplicitReference() {
        // Digit-leading, '+', '-', '.' would otherwise parse as atom keywords/operators.
        let odd = ["1abc", "p+q", "a-b", "x.y", "and_"]
        let choice = SaveStructureSelection.choice(selectedObjects: ["p+q", "a-b", "x.y"],
                                                   allObjects: odd, includeSelection: false)
        XCTAssertEqual(choice, .subset("%p+q or %a-b or %x.y"))
        XCTAssertTrue(odd.allSatisfy(SaveStructureSelection.isSelectorSafe))
    }

    func testNamesThatCouldBreakTheExpressionOrLiteralAreNotSelectorSafe() {
        for bad in ["", "a b", "a)b", "a'''b", "a\\b", "a;b", "a\nb", "é"] {
            XCTAssertFalse(SaveStructureSelection.isSelectorSafe(bad), "\(bad.debugDescription)")
        }
    }

    func testNothingTickedIsDisallowed() {
        let choice = SaveStructureSelection.choice(selectedObjects: [], allObjects: all,
                                                   includeSelection: false)
        XCTAssertEqual(choice, .nothing)
        XCTAssertNil(SaveStructureSelection.saveCommand(path: "/tmp/s.pdb", choice: choice))
    }

    func testSubsetSaveCommandPassesTheSelection() {
        let code = SaveStructureSelection.saveCommand(path: "/tmp/s.cif",
                                                      choice: .subset("%2kpo or %lig"))
        XCTAssertEqual(code, "from pymol import cmd as _c\n_c.save(r'''/tmp/s.cif''', r'''%2kpo or %lig''')")
    }

    func testSceneFormatsSkipThePicker() {
        XCTAssertFalse(SaveStructureSelection.supportsSelection(ext: "wrl"))
        XCTAssertFalse(SaveStructureSelection.supportsSelection(ext: "pov"))
        for ext in ["pdb", "cif", "sdf", "mol", "mol2", "xyz", "pqr"] {
            XCTAssertTrue(SaveStructureSelection.supportsSelection(ext: ext), ext)
        }
    }

    func testOnlyMolAndXyzMergeObjects() {
        XCTAssertTrue(SaveStructureSelection.mergesObjects(ext: "mol"))
        XCTAssertTrue(SaveStructureSelection.mergesObjects(ext: "xyz"))
        for ext in ["pdb", "cif", "sdf", "mol2", "pqr"] {
            XCTAssertFalse(SaveStructureSelection.mergesObjects(ext: ext), ext)
        }
    }

    func testCandidatesParseAndSkipModalWhenNothingToChoose() {
        let json = #"{"objects": ["2kpo", "lig", "bad name"], "sele": false}"#.data(using: .utf8)!
        let parsed = SaveStructureCandidates.parse(json)
        XCTAssertEqual(parsed, SaveStructureCandidates(objects: ["2kpo", "lig"], hasSelection: false))
        XCTAssertEqual(parsed?.needsPicker, true)

        XCTAssertFalse(SaveStructureCandidates(objects: ["2kpo"], hasSelection: false).needsPicker)
        XCTAssertFalse(SaveStructureCandidates(objects: [], hasSelection: false).needsPicker)
        XCTAssertTrue(SaveStructureCandidates(objects: ["2kpo"], hasSelection: true).needsPicker)
        XCTAssertNil(SaveStructureCandidates.parse(Data("not json".utf8)))
    }
}
