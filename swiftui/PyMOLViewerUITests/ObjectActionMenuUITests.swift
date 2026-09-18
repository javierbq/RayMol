// ObjectActionMenuUITests.swift — the selection row's "Copy to Object" and
// "Extract" entries (#461, #468) driven through the real menu on iOS.
//
// These exist because the unit tests can only prove the menu is *composed*
// correctly and the command strings are right; only this can show the entries
// actually appear under a finger and do something to the object list. The
// screenshots each test attaches are the artefact worth looking at.
//
// Run: xcodebuild test -scheme UITests_iOS -sdk iphonesimulator \
//        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//        -only-testing:PyMOLViewerUITests/ObjectActionMenuUITests
//
// NOT -scheme PyMOLViewer_iOS: that generated scheme also carries the macOS-only
// PyMOLViewerTests and xcodebuild will not build it for iphonesimulator.

import XCTest

final class ObjectActionMenuUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        // PYMOL_AUTOLOAD names the object "mol"; add a selection to hang the
        // new menu off, since both entries are selection-only.
        app.launchEnvironment["PYMOL_AUTOCMD"] =
            "hide everything; show cartoon; orient; select mysele, resi 1-10"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "open"
        app.launchEnvironment["PYMOL_AUTOTAB"] = "objects"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_SKIP_FIRSTBOOT_THEME"] = "1"
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchArguments += ["-ipadGestureCoachSeen", "YES"]
    }

    /// Both entries are on the selection's menu, and on nothing else's — the
    /// gating that mirrors desktop PyMOL's `if object:` split.
    func testSelectionMenuOffersCopyAndExtract() {
        launchAndSettle()

        openActionMenu(for: "mysele")
        XCTAssertTrue(menuItem("Copy to Object").exists,
                      "Copy to Object missing from the selection's A menu")
        XCTAssertTrue(item("Extract").exists, "Extract missing from the selection's A menu")
        attach("1-selection-menu")
    }

    /// …and on nothing else's. Separate launch rather than a second menu in the
    /// test above: scrolling a long menu leaves the panel offset behind it, and
    /// the next row is then not hittable.
    func testObjectMenuOffersNeither() {
        launchAndSettle()

        openActionMenu(for: "mol")
        XCTAssertTrue(item("Zoom").waitForExistence(timeout: 5), "the object's A menu did not open")
        // Scroll to the depth the selection menu needed, so "absent" means absent
        // rather than merely below the fold.
        menuItem("Move to Group")
        XCTAssertFalse(item("Copy to Object").exists, "Copy to Object should not be on an OBJECT row")
        XCTAssertFalse(item("Extract").exists, "Extract should not be on an OBJECT row")
        attach("2-object-menu-has-neither")
    }

    /// Extract ▸ object moves the atoms into a new auto-named object and drops
    /// the emptied selection.
    func testExtractCreatesObjectAndDropsSelection() {
        launchAndSettle()
        XCTAssertTrue(row("mysele").exists, "the selection row is missing before extracting")

        openActionMenu(for: "mysele")
        menuItem("Extract").tap()
        XCTAssertTrue(item("object").waitForExistence(timeout: 5), "the Extract submenu did not open")
        XCTAssertTrue(item("extend 1").exists, "'extend 1' missing")
        XCTAssertTrue(item("byres extend 1").exists, "'byres extend 1' missing")
        attach("3-extract-submenu")

        item("object").tap()
        settle(2.5)
        attach("4-after-extract")

        XCTAssertTrue(row("obj01").waitForExistence(timeout: 10),
                      "extract did not produce the auto-named obj01")
        XCTAssertFalse(row("mysele").exists,
                       "the emptied selection should have been dropped")
        XCTAssertEqual(app.state, .runningForeground, "app crashed during extract")
    }

    /// Copy to Object lists the loaded molecule objects plus "New Object…",
    /// and the new-object path prompts with PyMOL's own objNN default.
    func testCopyToObjectListsTargetsAndPrompts() {
        launchAndSettle()

        openActionMenu(for: "mysele")
        menuItem("Copy to Object").tap()
        XCTAssertTrue(item("New Object…").waitForExistence(timeout: 5),
                      "the Copy to Object submenu did not open")
        XCTAssertTrue(item("mol").exists, "the loaded object 'mol' is not offered as a copy target")
        attach("5-copy-to-submenu")

        item("New Object…").tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the name prompt never appeared")
        let field = alert.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "obj01",
                       "the prompt should prefill PyMOL's objNN default")
        attach("6-new-object-prompt")

        alert.buttons["Copy"].tap()
        settle(2.5)
        attach("7-after-copy")

        XCTAssertTrue(row("obj01").waitForExistence(timeout: 10), "the copy did not appear")
        XCTAssertTrue(row("mysele").exists, "a COPY must leave the selection in place")
        XCTAssertTrue(row("mol").exists, "a COPY must leave the source object in place")
        XCTAssertEqual(app.state, .runningForeground, "app crashed during copy")
    }

    // MARK: - helpers

    private func launchAndSettle() {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 60),
                      "molecule never rendered (embedded Python boot + load)")
        settle(2.0)
    }

    private func openActionMenu(for name: String) {
        let button = app.descendants(matching: .any)["actionMenu.\(name)"]
        guard button.waitForExistence(timeout: 20) else {
            print("=== AX DUMP ===\n\(app.debugDescription)\n=== END DUMP ===")
            return XCTFail("the \(name) row's A menu button never appeared")
        }
        button.tap()
        settle(1.0)
    }

    /// A menu row by its visible title; UIKit exposes UIMenu rows with varying
    /// element types across OS versions, so match on label rather than type.
    private func item(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    /// Scroll the open action menu until `title` is on screen and return it.
    ///
    /// The selection menu is long enough to scroll — Copy/Extract sit in the
    /// object-management tail, well below Zoom/Preset/Find — and UIKit only puts
    /// the *rendered* rows in the accessibility tree, so an off-screen row simply
    /// does not exist to query.
    @discardableResult
    private func menuItem(_ title: String, swipes: Int = 8,
                          file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        for _ in 0..<swipes {
            if item(title).exists { return item(title) }
            app.swipeUp(velocity: .slow)
            settle(0.4)
        }
        // Fail here rather than returning a non-existent element: the caller
        // usually taps it, and "Failed to tap Any (First Match)" names neither
        // the row it wanted nor the fact that scrolling ran out.
        XCTFail("'\(title)' never came into view after \(swipes) swipes of the menu",
                file: file, line: line)
        return item(title)
    }

    /// A row in the panel, addressed by the AX hook its A button carries — the
    /// row's own text is shared with menu titles once a menu is open.
    private func row(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["actionMenu.\(name)"]
    }

    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        settle(1.0)
    }

    private func settle(_ s: TimeInterval = 1.0) { Thread.sleep(forTimeInterval: s) }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// 48×48 grey thumbnail of the viewport band (rows 12 %…67 % of the screen).
    private func viewportSignature() -> [UInt8] {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return [] }
        let w = cg.width, h = cg.height
        let crop = CGRect(x: 0, y: Int(Double(h) * 0.12),
                          width: w, height: Int(Double(h) * 0.55))
        guard let region = cg.cropping(to: crop) else { return [] }
        let sw = 48, sh = 48
        var buf = [UInt8](repeating: 0, count: sw * sh)
        guard let ctx = CGContext(data: &buf, width: sw, height: sh,
                                  bitsPerComponent: 8, bytesPerRow: sw,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return buf
    }

    private func waitForRender(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewportSignature().contains(where: { $0 > 40 }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
