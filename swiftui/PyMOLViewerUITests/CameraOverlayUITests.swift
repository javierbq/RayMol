// CameraOverlayUITests.swift — functional verification of the camera chip and the
// bottom-docked camera control strip (CameraDock) on iPhone (compact size class).
//
// AX contract (see CameraDock):
//   - Camera chip:  id='camera', label='Camera settings'
//   - Strip icons:  id='camDock.lens' / '.zoom' / '.ortho' / '.depth' / '.reset'
//   - DOF toggles:  id='dof.enabled' / 'dof.autolock'
//   - Open control: the only slider in the app when a slider surface is open.

import XCTest

final class CameraOverlayUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        // Without this the What's New sheet auto-shows after a version bump and
        // covers the whole app, so every test here fails on "icon not found".
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchEnvironment["PYMOL_AUTOCMD"] = "hide everything; show cartoon; orient"
    }

    // MARK: - Chip opens a strip of icons, no surface yet

    func testChipOpensStrip() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")

        let chip = cameraChipButton()
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "Camera chip not found")
        attach("strip_1_chip")

        chip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach("strip_2_open")

        for id in ["camDock.lens", "camDock.zoom", "camDock.depth", "camDock.close"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5), "Strip icon '\(id)' not found")
        }
        // Ortho is no longer a strip icon — it lives in the Lens row.
        XCTAssertFalse(app.buttons["camDock.ortho"].exists, "Ortho should not be in the strip")
        // No surface open yet → no slider present (Objects panel is closed).
        XCTAssertFalse(app.sliders.firstMatch.exists, "A slider is open before any icon was tapped")
    }

    // MARK: - The dock clears the parked inspector tongue (#474)

    // With the inspector closed, the horizontal tongue parks on the viewport's
    // bottom edge — the same edge the dock docks to — and paints ON TOP of it
    // (its overlay is applied by the layout, outside viewportView). It used to
    // land across the Zoom/Depth icons and, since only the pill is hit-testable,
    // swallow taps meant for them. The dock now pads itself above the pill.
    func testDockClearsParkedTongue() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach("tongue_1_dock_open")

        // PYMOL_AUTOPANEL=closed leaves the tongue parked and pointing up.
        let tongue = app.buttons["Show panel"]
        XCTAssertTrue(tongue.waitForExistence(timeout: 5), "parked inspector tongue not found")

        for id in ["camDock.lens", "camDock.zoom", "camDock.depth", "camDock.close"] {
            let icon = app.buttons[id]
            XCTAssertTrue(icon.waitForExistence(timeout: 5), "Strip icon '\(id)' not found")
            XCTAssertFalse(icon.frame.intersects(tongue.frame),
                           "tongue \(tongue.frame) overlaps \(id) \(icon.frame)")
        }
        // The pill sits BELOW the dock, not through it.
        XCTAssertGreaterThan(tongue.frame.minY, app.buttons["camDock.close"].frame.maxY,
                             "tongue should be parked under the dock, not across it")
    }

    // MARK: - Lens/Zoom open a single slider, one at a time

    func testLensAndZoomOpenSingleSlider() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.lens"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3), "Lens slider did not open")
        attach("strip_3_lens")

        // Tapping the active icon again collapses the surface.
        app.buttons["camDock.lens"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertFalse(app.sliders.firstMatch.exists, "Lens slider did not collapse on second tap")

        app.buttons["camDock.zoom"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3), "Zoom slider did not open")
        attach("strip_4_zoom")
    }

    // MARK: - Ortho (in the Lens row) greys the Lens slider

    func testOrthoGreysLensSlider() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        // Open the Lens row; the Ortho toggle lives there (not in the strip).
        app.buttons["camDock.lens"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Lens slider not found")
        XCTAssertTrue(slider.isEnabled, "Lens slider should be enabled in perspective mode")

        let ortho = app.buttons["camDock.ortho"]
        XCTAssertTrue(ortho.waitForExistence(timeout: 3), "Ortho toggle not found in the Lens row")
        ortho.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach("strip_5_ortho")
        XCTAssertFalse(slider.isEnabled, "Lens slider should be greyed out in orthographic mode")

        ortho.tap()  // restore perspective for a clean state
    }

    // MARK: - Depth opens the sub-panel; enabling reveals Focus; no quality control

    func testDepthSubPanel() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.depth"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(app.staticTexts["Depth of field"].waitForExistence(timeout: 3),
                      "DOF sub-panel header not shown")

        let enabled = app.switches["dof.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3), "DOF 'Enabled' toggle not found")

        // Focus/aperture are hidden until DOF is enabled.
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.exists,
                       "Focus row should be hidden before DOF is enabled")
        enabled.tap()
        Thread.sleep(forTimeInterval: 1.0)
        attach("strip_6_dof")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'DOF focus'")).firstMatch.waitForExistence(timeout: 3),
                      "Focus row not revealed after enabling DOF")

        // Quality was moved to the inspector — it must NOT appear in the dock.
        XCTAssertFalse(app.staticTexts["DOF quality"].exists,
                       "'DOF quality' must not appear in the camera dock")
    }

    // MARK: - Close button dismisses the dock

    func testCloseButtonDismissesDock() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        let close = app.buttons["camDock.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Close icon not found")
        close.tap()
        Thread.sleep(forTimeInterval: 1.0)
        // Dock is dismissed: its strip icons are gone.
        XCTAssertFalse(app.buttons["camDock.lens"].exists, "Dock did not dismiss after Close")
        XCTAssertEqual(app.state, .runningForeground, "App crashed after Close")
        attach("strip_7_close")
    }

    // MARK: - Zoom slider changes the on-screen molecule size

    func testZoomChangesView() throws {
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30), "molecule never rendered")
        cameraChipButton().tap()
        Thread.sleep(forTimeInterval: 1.5)

        app.buttons["camDock.zoom"].tap()
        Thread.sleep(forTimeInterval: 0.8)
        let zoom = app.sliders.firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 3), "Zoom slider not open")

        let baseline = viewportMoleculeSize()
        zoom.adjust(toNormalizedSliderPosition: 0.75)
        Thread.sleep(forTimeInterval: 1.5)
        let zoomedIn = viewportMoleculeSize()
        attach("strip_8_zoomin")
        zoom.adjust(toNormalizedSliderPosition: 0.10)
        Thread.sleep(forTimeInterval: 1.5)
        let zoomedOut = viewportMoleculeSize()

        XCTAssertGreaterThan(zoomedIn, baseline, "Molecule did not grow when zooming in")
        XCTAssertLessThan(zoomedOut, baseline, "Molecule did not shrink when zooming out")
    }

    // MARK: - Helpers

    private func cameraChipButton() -> XCUIElement {
        let byID = app.buttons["camera"]
        if byID.exists { return byID }
        return app.buttons["Camera settings"]
    }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    private func waitForRender(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewportMoleculeSize() > 200 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // Count COLORFUL (saturated) pixels in the center viewport — a background-
    // independent proxy for "how much molecule is on screen". The 1ubq cartoon is
    // vividly colored (spectrum/green), whereas the viewport background (white or
    // black, depending on theme) and the grey UI chrome are near-neutral (low
    // saturation). Counting max-min channel spread instead of raw brightness makes
    // the zoom-size assertions work regardless of the theme's background color.
    private func viewportMoleculeSize() -> Int {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        let crop = CGRect(x: Int(Double(w) * 0.20), y: Int(Double(h) * 0.05),
                          width: Int(Double(w) * 0.60), height: Int(Double(h) * 0.60))
        guard let region = cg.cropping(to: crop) else { return 0 }
        let pw = region.width, ph = region.height
        var buf = [UInt8](repeating: 0, count: pw * ph * 4)
        guard let ctx = CGContext(data: &buf, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: pw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return 0 }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        var count = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = Int(buf[i]), g = Int(buf[i+1]), b = Int(buf[i+2])
            let hi = max(r, g, b), lo = min(r, g, b)
            if hi - lo > 40 { count += 1 }   // saturated → part of the molecule
        }
        return count
    }
}
