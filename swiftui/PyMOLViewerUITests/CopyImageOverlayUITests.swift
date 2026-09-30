// CopyImageOverlayUITests.swift — repro: Export ▸ Copy Image leaves the
// "Rendering image…" overlay up long after the image reached the pasteboard.

import XCTest
import UIKit

final class CopyImageOverlayUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchEnvironment["PYMOL_AUTOCMD"] = "hide everything; show cartoon; orient"
    }

    func testCopyImageOverlayClears() throws {
        app.launch()
        Thread.sleep(forTimeInterval: 6)   // let the scene settle so rendering goes idle
        UIPasteboard.general.items = []

        let export = app.buttons["Export"]
        XCTAssertTrue(export.waitForExistence(timeout: 15), "Export button not found")
        export.tap()
        let copy = app.buttons["Copy Image"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Copy Image item not found")
        attach("1_menu")
        let t0 = Date()
        copy.tap()

        let overlay = app.staticTexts["Rendering image…"]
        var pasteAt: TimeInterval?
        var overlayGoneAt: TimeInterval?
        var sawOverlay = false
        while Date().timeIntervalSince(t0) < 70 {
            let t = Date().timeIntervalSince(t0)
            if pasteAt == nil, UIPasteboard.general.hasImages { pasteAt = t; attach("2_pasted") }
            if overlay.exists { sawOverlay = true }
            else if sawOverlay || t > 3 { overlayGoneAt = t; break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        attach("3_end")
        print("COPYIMG pasteboard-has-image at \(pasteAt.map { String(format: "%.2fs", $0) } ?? "never"); "
              + "overlay seen=\(sawOverlay), gone at \(overlayGoneAt.map { String(format: "%.2fs", $0) } ?? ">70s")")
        XCTAssertNotNil(pasteAt, "image never reached the pasteboard")
        if let p = pasteAt {
            XCTAssertLessThan((overlayGoneAt ?? 999) - p, 2.0,
                              "overlay outlived the pasteboard write by >2 s")
        }
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }
}
