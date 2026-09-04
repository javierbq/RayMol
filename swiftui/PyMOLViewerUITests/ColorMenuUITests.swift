// ColorMenuUITests.swift — the tiered per-object color menu (#379) on iOS.
//
// Desktop PyMOL's "C" menu lists colors as rows that both apply (click "red")
// and expand into that hue's named variants (firebrick, salmon, …). This
// drives the real SwiftUI Menu through UIKit and confirms the viewport
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

    /// The chevron end of a row: on iOS a row that both acts and expands is a
    /// UIKit menu with a submenu, and which half of the row does what has
    /// changed between OS versions, so the tests target it explicitly.
    private func chevron(of row: XCUIElement) -> XCUICoordinate {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
    }

    /// Tapping the "red" row applies red — either directly (primaryAction) or
    /// by drilling into the variants, where red is the first entry. Both paths
    /// must end with the menu closed and the molecule recoloured.
    func testRedRowAppliesRed() {
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
        if item("firebrick").waitForExistence(timeout: 3) {
            // Drilled into the variants: the base color leads the list. "red"
            // now appears twice (submenu header + shade); the shade is last.
            attach("color-menu-red-variants")
            let reds = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'red'"))
            reds.element(boundBy: reds.count - 1).tap()
        }
        waitForMenuToClose()
        attach("after-red")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "the 'red' row did not recolour the viewport")
        XCTAssertEqual(app.state, .runningForeground, "app crashed after applying a color")
    }

    /// The row's chevron opens that hue's named variants, and picking one
    /// recolours the object.
    func testVariantAppliesToTheObject() {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30),
                      "molecule never rendered (embedded Python boot + load)")
        let before = viewportSignature()
        openMenu()
        settle(0.5)
        chevron(of: item("red")).tap()
        if !item("firebrick").waitForExistence(timeout: 3) {
            item("red").tap()   // older layouts expand from anywhere on the row
        }
        XCTAssertTrue(item("firebrick").waitForExistence(timeout: 5), "'firebrick' variant never appeared")
        XCTAssertTrue(item("salmon").exists, "'salmon' variant missing")
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
