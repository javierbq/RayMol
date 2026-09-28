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

    // MARK: - #417: the .raymol document is a session

    func testRaymolLoadsBareAndReplacesTheSession() {
        // A .raymol carries a .pse as one blob plus the sets, so `load` replaces
        // the session exactly as a .pse does: no object name, no theming, and the
        // #349 guard applies.
        for path in ["/tmp/campaign.raymol", "/tmp/CAMPAIGN.RAYMOL"] {
            let (command, theme) = PyMOLEngine.loadInvocation(path: path, name: "campaign")
            XCTAssertEqual(command, "load \(path)", path)
            XCTAssertNil(theme, path)
            XCTAssertTrue(openWouldReplaceSession(URL(fileURLWithPath: path), hasObjects: true))
            XCTAssertFalse(openWouldReplaceSession(URL(fileURLWithPath: path), hasObjects: false))
        }
        XCTAssertTrue(PyMOLEngine.isRayMolDocument("/tmp/x.raymol"))
        XCTAssertFalse(PyMOLEngine.isRayMolDocument("/tmp/x.pse"))
    }

    func testRaymolIsTrackedAsTheOpenDocumentPswIsNot() {
        XCTAssertTrue(PyMOLEngine.isTrackedDocument(URL(fileURLWithPath: "/tmp/a.raymol")))
        XCTAssertTrue(PyMOLEngine.isTrackedDocument(URL(fileURLWithPath: "/tmp/a.pse")))
        XCTAssertFalse(PyMOLEngine.isTrackedDocument(URL(fileURLWithPath: "/tmp/a.psw")),
                       "a show file was never the ⌘S target and still is not")
        XCTAssertFalse(PyMOLEngine.isTrackedDocument(URL(fileURLWithPath: "/tmp/a.pdb")))
    }

    func testSavePanelOffersTheDocumentsOwnFormatFirst() {
        XCTAssertEqual(PyMOLEngine.sessionSaveExtensions(currentDocument: nil), ["pse", "raymol"],
                       "an untitled session still defaults to plain PyMOL")
        XCTAssertEqual(PyMOLEngine.sessionSaveExtensions(
                           currentDocument: URL(fileURLWithPath: "/tmp/a.pse")), ["pse", "raymol"])
        XCTAssertEqual(PyMOLEngine.sessionSaveExtensions(
                           currentDocument: URL(fileURLWithPath: "/tmp/a.raymol")), ["raymol", "pse"],
                       "a .raymol document keeps saving as .raymol")
        XCTAssertEqual(PyMOLEngine.sessionSaveExtensions(currentDocument: nil, forcing: "raymol"),
                       ["raymol", "pse"], "the sets sheet's 'Save as .raymol' wins")
    }

    // MARK: - #417 review: the save paths that could lose a set

    /// The blocker this file exists to keep fixed. A Save As BEFORE any set existed
    /// used to record "the user has decided", so the ⌘S that came after a six-hour
    /// batch filled a set wrote a plain .pse and dropped it with only a console
    /// warning. Only the sheet's own answers may satisfy the question.
    func testASaveBeforeTheSetExistsDoesNotAnswerTheQuestion() {
        let campaign = URL(fileURLWithPath: "/tmp/campaign.pse")
        // 1. Untitled session, no sets: ⇧⌘S goes straight to the panel...
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: false, currentDocument: nil,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: true),
            .panel(["pse", "raymol"]))
        // 2. ...which must NOT have recorded a decision. A batch then fills a set,
        //    and ⌘S over the tracked .pse has to ask.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: campaign,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: false),
            .askAboutSets)
    }

    /// The #349 "Save and Replace…" button runs the LAST save the outgoing session
    /// will ever get — the `load` behind it resets the store and deletes the working
    /// container — so it asks the same question ⌘S does, rather than silently
    /// overwriting the tracked .pse.
    func testReplaceGuardSaveAsksBeforeWritingAPseOverASet() {
        let campaign = URL(fileURLWithPath: "/tmp/campaign.pse")
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: campaign,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: false),
            .askAboutSets)
        // "Save as .raymol" must open a panel even though a .pse is tracked: the
        // point of the answer is not to write that .pse.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: campaign,
                                        setsChoiceMade: true, forcingRaymol: true,
                                        alwaysPanel: false),
            .panel(["raymol", "pse"]))
        // "Save .pse without sets" records the choice and overwrites, as asked.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: campaign,
                                        setsChoiceMade: true, forcingRaymol: false,
                                        alwaysPanel: false),
            .overwrite(campaign))
    }

    func testOrdinarySavesAreUnaffected() {
        let pse = URL(fileURLWithPath: "/tmp/a.pse")
        let raymol = URL(fileURLWithPath: "/tmp/a.raymol")
        // No set: ⌘S overwrites silently, as it always has.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: false, currentDocument: pse,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: false),
            .overwrite(pse))
        // A .raymol document with sets never asks — it simply saves.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: raymol,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: false),
            .overwrite(raymol))
        // Untitled with a set: the sheet, then a panel — never a silent .pse.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveStep(hasNonEmptySet: true, currentDocument: nil,
                                        setsChoiceMade: false, forcingRaymol: false,
                                        alwaysPanel: false),
            .askAboutSets)
    }

    func testSavePanelNameKeepsTheStemAndTakesTheChosenFormat() {
        XCTAssertEqual(PyMOLEngine.sessionSaveName(currentDocument: nil, preferred: "pse"),
                       "session.pse")
        XCTAssertEqual(
            PyMOLEngine.sessionSaveName(
                currentDocument: URL(fileURLWithPath: "/tmp/campaign.pse"), preferred: "raymol"),
            "campaign.raymol",
            "spec §2.1: the .raymol lands beside the .pse with the same stem")
    }

    func testAnUnofferedExtensionGetsOursAppended() {
        // allowsOtherFileTypes lets the user type anything; what is written must
        // still be recognisable as a session afterwards.
        XCTAssertEqual(
            PyMOLEngine.sessionSaveURL(URL(fileURLWithPath: "/tmp/campaign.backup"),
                                       extensions: ["raymol", "pse"]).lastPathComponent,
            "campaign.backup.raymol")
        // An offered extension is left exactly as typed, in either case.
        for name in ["campaign.pse", "campaign.RAYMOL"] {
            XCTAssertEqual(
                PyMOLEngine.sessionSaveURL(URL(fileURLWithPath: "/tmp/\(name)"),
                                           extensions: ["raymol", "pse"]).lastPathComponent,
                name)
        }
    }

    // MARK: - #417 review: names go to Python escaped, never stripped

    /// A backslash is a legal entry name character (the store forbids quotes and
    /// whitespace, not `\\`), and `set_import` of `a\\b.cif` produces one. Stripping
    /// it made every drawer verb act on `ab` — a wrong-entry mutation when the set
    /// also holds an entry by that name, which `unstage` turns into a deleted object.
    func testPythonLiteralEscapesRatherThanStrips() {
        XCTAssertEqual(PyMOLEngine.pythonLiteral("a\\b"), "'a\\\\b'")
        XCTAssertEqual(PyMOLEngine.pythonLiteral("d_0417"), "'d_0417'")
        XCTAssertEqual(PyMOLEngine.pythonLiteral("a'b"), "'a\\'b'")
        // Nothing may be dropped: what Python parses back must be the name the
        // store has, character for character.
        for name in ["a\\b", "a\\\\b", "a'b", "a\\'b", "plain"] {
            let literal = PyMOLEngine.pythonLiteral(name)
            XCTAssertEqual(unescapePythonLiteral(literal), name,
                           "\(literal) does not read back as \(name)")
        }
    }

    /// Minimal reader for the single-quoted literals `pythonLiteral` emits, so the
    /// round trip is asserted rather than eyeballed.
    private func unescapePythonLiteral(_ literal: String) -> String {
        var body = Array(literal.dropFirst().dropLast())
        var out = ""
        var i = 0
        while i < body.count {
            if body[i] == "\\", i + 1 < body.count {
                out.append(body[i + 1])
                i += 2
            } else {
                out.append(body[i])
                i += 1
            }
        }
        return out
    }

    func testSetsSheetShowsOnceAndOnlyWhenItMatters() {
        let pse = URL(fileURLWithPath: "/tmp/a.pse")
        let raymol = URL(fileURLWithPath: "/tmp/a.raymol")
        // The case the sheet exists for: a set, saving to a .pse (or untitled).
        XCTAssertTrue(PyMOLEngine.sessionNeedsRaymolPrompt(hasNonEmptySet: true, currentDocument: pse,
                                                           alreadyDecided: false))
        XCTAssertTrue(PyMOLEngine.sessionNeedsRaymolPrompt(hasNonEmptySet: true, currentDocument: nil,
                                                           alreadyDecided: false))
        // Never for a session without sets — a user who never touches a set never
        // sees .raymol (spec §2.1).
        XCTAssertFalse(PyMOLEngine.sessionNeedsRaymolPrompt(hasNonEmptySet: false, currentDocument: nil,
                                                            alreadyDecided: false))
        // Never when a .raymol is already the document: it simply saves.
        XCTAssertFalse(PyMOLEngine.sessionNeedsRaymolPrompt(hasNonEmptySet: true, currentDocument: raymol,
                                                            alreadyDecided: false))
        // Once per session.
        XCTAssertFalse(PyMOLEngine.sessionNeedsRaymolPrompt(hasNonEmptySet: true, currentDocument: pse,
                                                            alreadyDecided: true))
    }

    // MARK: - #448: replacing the session while a batch is still landing

    private func set(_ name: String, id: String, count: Int) -> SetEntry {
        SetEntry(id: id, name: name, kind: "structures", tool: "rfd3", count: count,
                 stagedCount: min(count, 6), budget: 6, groupName: name, reference: "tgt",
                 rankingKey: "", sortKey: "", sortDescending: true, filter: "",
                 columns: [], histogram: [])
    }

    private let working = "/Users/x/Library/RayMolState/raymol_sets_4242.raymol"
    private func busy(landed: Int? = 12) -> [String: BatchProgress] {
        ["ab12cd34": BatchProgress(done: 12, total: 200, tool: "rfd3", landed: landed)]
    }

    func testNoRunningBatchAsksNothingNew() {
        // The #349 / §2.1 behaviour is untouched when nothing is landing — even with
        // a big set in the session.
        XCTAssertNil(PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 500)], running: [:],
            storePath: working, currentDocument: nil))
    }

    func testAnUntitledRunningBatchAsksAndSaysDontSaveKeepsARecoveredFile() {
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 40), set("old", id: "ffff0000", count: 40)],
            running: busy(), storePath: working, currentDocument: nil)
        XCTAssertEqual(guardInfo?.sets, ["rfd3_a"])
        XCTAssertEqual(guardInfo?.landed, 12, "the batch's own count, not the set's 40")
        XCTAssertEqual(guardInfo?.landedIsExact, true)
        XCTAssertEqual(guardInfo?.isUntitled, true)
        XCTAssertEqual(guardInfo?.title, "A batch is still running in “rfd3_a”.")
        let text = guardInfo?.message(replacing: "Opening “b.pse”") ?? ""
        XCTAssertTrue(text.contains("12 designs from it have landed."), text)
        XCTAssertTrue(text.contains("this untitled session"), text)
        XCTAssertTrue(text.contains("Don’t Save keeps it as a recovered file"), text)
        XCTAssertTrue(text.contains("keeps writing into it"), text)
    }

    func testWithoutTheBatchsOwnCountTheSheetSaysWhatTheSetsHold() {
        // An older marker, or a truncated one: the set count is all there is, and for
        // an extended set it includes earlier runs -- so it is not called "landed".
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 40)], running: busy(landed: nil),
            storePath: working, currentDocument: nil)
        XCTAssertEqual(guardInfo?.landed, 40)
        XCTAssertEqual(guardInfo?.landedIsExact, false)
        let text = guardInfo?.message(replacing: "Clearing the session") ?? ""
        XCTAssertTrue(text.contains("Its sets hold 40 entries."), text)
        XCTAssertFalse(text.contains("landed"), text)
    }

    func testASessionTrackingAPseSaysThePseDoesNotHoldItsSets() {
        // Opened from (or saved as) a .pse, then a batch: the sets are in the working
        // file, so Don't Save is the recovered-file answer -- but it is not "untitled".
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 1)], running: busy(landed: 1),
            storePath: working, currentDocument: URL(fileURLWithPath: "/tmp/a.pse"))
        XCTAssertEqual(guardInfo?.isUntitled, true)
        XCTAssertEqual(guardInfo?.pseDocument, URL(fileURLWithPath: "/tmp/a.pse"))
        let text = guardInfo?.message(replacing: "Clearing the session") ?? ""
        XCTAssertTrue(text.contains("1 design from it has landed."), text)
        XCTAssertTrue(text.contains("not in “a.pse”"), text)
        XCTAssertFalse(text.contains("untitled"), text)
        XCTAssertTrue(text.contains("recovered file"), text)
    }

    func testARaymolDocumentIsNamedAndSaidToHoldTheSetsAlready() {
        let doc = URL(fileURLWithPath: "/tmp/campaign.raymol")
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 7)], running: busy(landed: 7),
            storePath: "/tmp/campaign.raymol", currentDocument: doc)
        XCTAssertEqual(guardInfo?.document, doc)
        XCTAssertEqual(guardInfo?.isUntitled, false)
        let text = guardInfo?.message(replacing: "Opening “b.pse”") ?? ""
        XCTAssertTrue(text.contains("“campaign.raymol”"), text)
        XCTAssertTrue(text.contains("already saved"), text)
        XCTAssertFalse(text.contains("recovered"), text)
    }

    func testARaymolDocumentThatIsNotTheStoresFileIsNotClaimed() {
        // The marker has moved to another file (the store is authoritative): do not
        // tell the user their sets are in a document they are not in.
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 7)], running: busy(),
            storePath: working, currentDocument: URL(fileURLWithPath: "/tmp/campaign.raymol"))
        XCTAssertEqual(guardInfo?.isUntitled, true)
    }

    func testABatchWithNothingLandedYetStillAsks() {
        // Its set and run are in the file already, and so is everything it delivers.
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [set("rfd3_a", id: "ab12cd34", count: 0)], running: busy(landed: 0),
            storePath: working, currentDocument: nil)
        XCTAssertEqual(guardInfo?.landed, 0)
        XCTAssertTrue(guardInfo?.message(replacing: "Opening “b.pse”")
                        .contains("No design from it has landed yet.") ?? false)
    }

    func testARunningIdTheDrawerHasNotReadYetStillAsks() {
        let guardInfo = PyMOLEngine.runningBatchReplace(
            sets: [], running: busy(), storePath: working, currentDocument: nil)
        XCTAssertNotNil(guardInfo)
        XCTAssertEqual(guardInfo?.title, "A batch is still running in a set.")
        XCTAssertEqual(PyMOLEngine.RunningBatchReplace.list(["a", "b", "c"]),
                       "“a” and 2 other sets")
    }

    func testTheMarkerDecodesTheBatchsOwnLandedCountAndToleratesItsAbsence() throws {
        let with = #"{"v":3,"path":"/p","active":"","peek":"","running":{"ab12cd34":{"done":5,"total":9,"tool":"rfd3","landed":4}}}"#
        let without = #"{"v":3,"path":"/p","active":"","peek":"","running":{"ab12cd34":{"done":5,"total":9,"tool":"rfd3"}}}"#
        let a = try JSONDecoder().decode(SetsMarker.self, from: Data(with.utf8))
        let b = try JSONDecoder().decode(SetsMarker.self, from: Data(without.utf8))
        XCTAssertEqual(a.running["ab12cd34"]?.landed, 4)
        XCTAssertNil(b.running["ab12cd34"]?.landed)
        XCTAssertEqual(b.running["ab12cd34"]?.done, 5)
    }
}
