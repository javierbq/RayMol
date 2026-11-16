// PyMOLGestureUITests.swift — real-touch gesture + selection coverage (iOS).
//
// Drives the app through the genuine UIKit gesture-recognizer path (which the
// layer env-var affordances bypass): one-finger drag = rotate, pinch = zoom,
// two-finger rotation = Z-roll, tap = pick. Rotate/zoom/roll are verified by
// pixel-diffing the Metal-rendered viewport (a no-op gesture fails); tap-pick
// is verified via the PYMOL_UITEST-gated "selectionCount" accessibility hook
// that mirrors the live 'sele' size.
//
// Run: xcodebuild test -scheme PyMOLViewer_iOS -sdk iphonesimulator \
//        -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
//        -derivedDataPath ./build_xcode ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

import XCTest
import UIKit

final class PyMOLGestureUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"   // full-bleed viewport
        app.launchEnvironment["PYMOL_UITEST"] = "1"           // expose selectionCount
        app.launchArguments += ["-ipadGestureCoachSeen", "YES"]
        // Each test calls launch(...) so it can tune the scene.
    }

    /// Launch (or relaunch) the app, optionally overriding the scene / opening
    /// the panel (for the sequence viewer), and wait for the molecule to render.
    private func launch(scene: String? = nil, panelOpen: Bool = false) {
        if let scene { app.launchEnvironment["PYMOL_AUTOCMD"] = scene }
        if panelOpen { app.launchEnvironment["PYMOL_AUTOPANEL"] = "open" }
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30),
                      "molecule never rendered (embedded Python boot + load)")
    }

    // MARK: - Gesture tests (cartoon scene)

    func testOneFingerDragRotates() {
        launch()
        let before = viewportSignature()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.40))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.46))
        start.press(forDuration: 0.05, thenDragTo: end)
        settle()
        attach("after-rotate")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "one-finger drag did not rotate the molecule")
    }

    /// #929: a one-finger VERTICAL drag turns the model the way the finger
    /// moves. The scene is a white sphere at the rotation origin with a small
    /// red marker in front of it (toward the viewer), so the marker sits at
    /// the viewport centre and a rotation shows as the marker sliding over
    /// the sphere: finger up -> marker up, finger down -> marker down.
    func testOneFingerVerticalDragFollowsTheFinger() {
        app.launchEnvironment["PYMOL_AUTOLOAD"] = nil
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        launch(scene: "pseudoatom o, pos=[0,0,0]; pseudoatom m, pos=[0,0,12]; show spheres; "
                    + "set sphere_scale, 3, o; set sphere_scale, 1.2, m; color white, o; color red, m; "
                    + "bg_color black; origin o; zoom o, 25")
        settle()
        guard let rest = redMarkerCentre() else { return XCTFail("the red marker never rendered") }
        attach("vertical-rest")

        let scale = UIScreen.main.scale
        func drag(dy: CGFloat) {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: rest.x / scale, dy: rest.y / scale))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)))
            settle()
        }

        drag(dy: -60)   // finger UP
        guard let up = redMarkerCentre() else { return XCTFail("the marker left the view on the up drag") }
        attach("vertical-after-up")
        XCTAssertLessThan(up.y, rest.y - 4, "finger up must carry the front of the model UP the screen")

        drag(dy: 120)   // finger DOWN, past the rest position
        guard let down = redMarkerCentre() else { return XCTFail("the marker left the view on the down drag") }
        attach("vertical-after-down")
        XCTAssertGreaterThan(down.y, rest.y + 4, "finger down must carry the front of the model DOWN the screen")
    }

    func testPinchZooms() {
        launch()
        let before = viewportSignature()
        app.pinch(withScale: 2.4, velocity: 1.5)   // scale > 1 = zoom in
        settle()
        attach("after-zoom")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "pinch did not change the zoom")
    }

    func testTwoFingerRotationRolls() {
        launch()
        let before = viewportSignature()
        app.rotate(CGFloat.pi / 3.0, withVelocity: 1.0)   // ~60° Z-roll
        settle()
        attach("after-zroll")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "two-finger rotation did not roll the view")
    }

    // MARK: - Click → residue selection (via the sequence viewer)
    //
    // NOTE on the 3D-scene tap: a tap directly on the Metal viewport to pick an
    // atom can NOT be exercised here — XCUITest only delivers a *moving* touch to
    // the MTKView's gesture recognizers, never a stationary tap/small-drag, so
    // handleTap never fires under automation. That pick path is verified out of
    // band (PYMOL_AUTOPICK → pink selection markers + sequence highlight). This
    // test covers residue selection through the sequence viewer, which is a real
    // SwiftUI element tap and exercises the same 'sele' → highlight machinery.

    func testTapResidueInSequenceSelects() {
        launch(panelOpen: true)   // show the sequence strip
        let sel = app.staticTexts["selectionCount"]
        XCTAssertTrue(sel.waitForExistence(timeout: 10),
                      "selectionCount test hook not found (PYMOL_UITEST not honored?)")
        XCTAssertEqual(sel.label, "0", "expected an empty selection at launch")

        // Met1 ("M") is the only M in 1ubq's sequence — tap it in the viewer.
        let m = app.staticTexts["M"].firstMatch
        XCTAssertTrue(m.waitForExistence(timeout: 10), "sequence residue 'M' not found")
        m.tap()
        XCTAssertTrue(waitForCount(sel, satisfies: { $0 == 1 }, timeout: 6),
                      "tapping a sequence residue did not select it")
        attach("after-select")

        // Tap it again → toggles the residue back off.
        m.tap()
        XCTAssertTrue(waitForCount(sel, satisfies: { $0 == 0 }, timeout: 6),
                      "tapping the selected residue again did not deselect it")
        attach("after-deselect")
    }

    // NOTE: a command-field Return test was tried but XCUITest cannot focus the
    // command TextField on the simulator (synthetic taps don't engage keyboard
    // focus here — same class of limitation as the Metal-view taps). The fix
    // (native SwiftUI TextField + .onSubmit(.send)) is verified on-device.

    // MARK: - Helpers

    private func settle(_ s: TimeInterval = 1.0) { Thread.sleep(forTimeInterval: s) }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Poll the selectionCount hook (the app refreshes 'sele' on a ~500ms timer).
    private func waitForCount(_ el: XCUIElement, satisfies pred: (Int) -> Bool,
                              timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pred(Int(el.label) ?? -1) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// Downsample the central viewport band (excludes the status-bar clock at
    /// the top and any panel chrome at the bottom) to a small grayscale buffer.
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

    /// The centre (screenshot pixels, top-left origin) of the saturated-red
    /// pixels on screen, or nil when there are too few to be the marker.
    private func redMarkerCentre() -> CGPoint? {
        guard let cg = XCUIScreen.main.screenshot().image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sx = 0, sy = 0, n = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if buf[i] > 120, buf[i + 1] < 50, buf[i + 2] < 50 { sx += x; sy += y; n += 1 }
            }
        }
        guard n > 50 else { return nil }
        // Row 0 of the buffer is the top of the screenshot.
        return CGPoint(x: CGFloat(sx) / CGFloat(n), y: CGFloat(sy) / CGFloat(n))
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
