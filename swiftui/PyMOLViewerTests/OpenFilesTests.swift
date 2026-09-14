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
}
