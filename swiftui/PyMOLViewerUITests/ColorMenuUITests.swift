// ColorMenuUITests.swift — the tiered per-object color menu (#379) on iOS.
//
// Desktop PyMOL's "C" menu lists colors as rows that both apply (click "red")
// and expand into that hue's named variants (firebrick, salmon, …). On iOS
// the menu is a hand-drawn popover (a UIMenu row cannot do both), so each row
// is split: the name applies the color in ONE tap, the chevron beside it
// expands the hue. These drive the real popover and confirm the viewport
// actually recoloured (pixel-diff, as in PyMOLGestureUITests).
//
// Run: xcodebuild test -scheme PyMOLViewer_iOS -sdk iphonesimulator \
//        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//        -only-testing:PyMOLViewerUITests/ColorMenuUITests

import XCTest

final class ColorMenuUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOCMD"] = "hide everything; show cartoon; orient"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "open"       // expand bottom panel
        app.launchEnvironment["PYMOL_AUTOTAB"] = "objects"      // …on the Objects tab
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_SKIP_FIRSTBOOT_THEME"] = "1"
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchArguments += ["-ipadGestureCoachSeen", "YES"]
    }

    /// PYMOL_AUTOLOAD names the object "mol".
    private var cButton: XCUIElement { app.descendants(matching: .any)["colorMenu.mol"] }

    private func openMenu() {
        guard cButton.waitForExistence(timeout: 20) else {
            print("=== AX DUMP ===\n\(app.debugDescription)\n=== END DUMP ===")
            return XCTFail("the mol row's C menu button never appeared")
        }
        cButton.tap()
        XCTAssertTrue(item("by element").waitForExistence(timeout: 5), "menu did not open")
    }

    /// Wait for the menu (and any submenu) to be fully gone so a viewport
    /// pixel-diff measures the molecule, not the menu overlay.
    private func waitForMenuToClose() {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, item("by element").exists || item("firebrick").exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(item("by element").exists || item("firebrick").exists,
                       "the color menu did not close after picking a color")
        settle(1.5)
    }

    /// The expand half of a split row. It is its own button, so address it by
    /// identifier rather than by poking at coordinates inside the name half.
    private func expander(_ color: String) -> XCUIElement {
        app.descendants(matching: .any)["colorRow.\(color).expand"]
    }

    /// Tapping the name half of the "red" row applies red in one tap: no
    /// submenu opens, the menu closes, and the molecule recolours. (It used to
    /// drill into the reds and cost a second tap on the shade.)
    func testRedRowAppliesRedInOneTap() {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30),
                      "molecule never rendered (embedded Python boot + load)")
        let before = viewportSignature()   // green cartoon, menu closed
        openMenu()
        for row in ["red", "green", "blue", "yellow", "magenta", "cyan", "orange"] {
            XCTAssertTrue(item(row).exists, "'\(row)' row missing")
        }
        attach("color-menu-top")
        settle(0.5)

        item("red").tap()
        XCTAssertFalse(item("firebrick").waitForExistence(timeout: 2),
                       "tapping 'red' expanded the reds instead of applying red")
        waitForMenuToClose()
        attach("after-red")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "the 'red' row did not recolour the viewport")
        XCTAssertEqual(app.state, .runningForeground, "app crashed after applying a color")
    }

    /// The row's chevron expands that hue's named variants in place — without
    /// closing the menu or recolouring anything — and picking one applies it.
    func testChevronExpandsTheHueAndAVariantApplies() {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30),
                      "molecule never rendered (embedded Python boot + load)")
        let before = viewportSignature()
        openMenu()
        settle(0.5)
        XCTAssertTrue(expander("red").waitForExistence(timeout: 5), "the reds chevron is missing")
        expander("red").tap()
        XCTAssertTrue(item("firebrick").waitForExistence(timeout: 5), "'firebrick' variant never appeared")
        XCTAssertTrue(item("salmon").exists, "'salmon' variant missing")
        XCTAssertTrue(item("by element").exists, "expanding closed the menu")
        attach("color-menu-red-variants")

        item("firebrick").tap()
        waitForMenuToClose()
        attach("after-firebrick")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "choosing 'firebrick' did not recolour the viewport")
        XCTAssertEqual(app.state, .runningForeground, "app crashed after applying a shade")
    }

    // MARK: - helpers

    /// A menu row by its visible title; UIKit exposes UIMenu rows with varying
    /// element types across OS versions, so match on label rather than type.
    private func item(_ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
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

    private func changed(_ a: [UInt8], _ b: [UInt8], threshold: Double = 0.06) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var diff = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { diff += 1 }
        return Double(diff) / Double(a.count) > threshold
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
