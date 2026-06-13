// PyMOLGestureUITests.swift — real-touch gesture coverage for the iOS app.
//
// These drive the app through the genuine UIKit gesture-recognizer path (the
// one env-var injection can't reach): one-finger drag = rotate, pinch = zoom,
// two-finger rotation = Z-roll, tap = pick. Each gesture is verified by
// pixel-diffing the Metal-rendered viewport region before/after — XCUIScreen
// captures the actual on-screen framebuffer, so a no-op gesture fails the test.
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
        // Autoload a structure, force the panel closed (full-bleed viewport so
        // gestures land on the scene), and skip the first-run gesture coach so
        // it doesn't swallow the first drag.
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOPANEL"] = "closed"
        app.launchArguments += ["-ipadGestureCoachSeen", "YES"]
        app.launch()
        XCTAssertTrue(waitForRender(timeout: 30),
                      "molecule never rendered (embedded Python boot + load)")
    }

    // MARK: - Gesture tests

    func testOneFingerDragRotates() {
        let before = viewportSignature()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.40))
        let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.46))
        start.press(forDuration: 0.05, thenDragTo: end)
        settle()
        attach("after-rotate")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "one-finger drag did not rotate the molecule")
    }

    func testPinchZooms() {
        let before = viewportSignature()
        app.pinch(withScale: 2.4, velocity: 1.5)   // scale > 1 = zoom in
        settle()
        attach("after-zoom")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "pinch did not change the zoom")
    }

    func testTwoFingerRotationRolls() {
        let before = viewportSignature()
        app.rotate(CGFloat.pi / 3.0, withVelocity: 1.0)   // ~60° Z-roll
        settle()
        attach("after-zroll")
        XCTAssertTrue(changed(before, viewportSignature()),
                      "two-finger rotation did not roll the view")
    }

    func testTapKeepsAppResponsive() {
        // Picking is hard to assert without scene introspection; this is a smoke
        // check that a tap on the scene doesn't wedge the app.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        settle(0.6)
        attach("after-tap")
        XCTAssertEqual(app.state, .runningForeground,
                       "app not responsive after a tap on the scene")
    }

    // MARK: - Helpers

    private func settle(_ s: TimeInterval = 1.0) { Thread.sleep(forTimeInterval: s) }

    private func attach(_ name: String) {
        let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Downsample the central viewport band (excludes the status-bar clock at
    /// the top and any panel/sequence chrome at the bottom) to a small grayscale
    /// buffer, so comparisons reflect the rendered molecule rather than chrome.
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

    /// True if more than `threshold` fraction of pixels changed appreciably.
    private func changed(_ a: [UInt8], _ b: [UInt8], threshold: Double = 0.06) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        var diff = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 12 { diff += 1 }
        return Double(diff) / Double(a.count) > threshold
    }

    /// Poll until the viewport band has bright pixels (molecule rendered).
    private func waitForRender(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewportSignature().contains(where: { $0 > 40 }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
