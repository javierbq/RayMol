// LightsGestureUITests.swift — Lights mode under real UIKit recognizers (#623).
//
// The routing deciders are unit-tested on macOS (LightsTouchRoutingTests) and
// the simulator runs drive the same model through DEBUG tokens; these tests
// send real touches through XCUITest, so the MTKView's recognizers, their
// delegate and the SwiftUI drags are the ones a finger reaches:
//   - off every light target, one finger rotates, a pinch zooms and a twist
//     rolls (the camera moves, no light changes): no camera gesture is lost;
//   - a pinch on a knob changes only that light's radius (0.5x grid, beam
//     kept, camera still), and press-hold-drag on a knob drags it (the
//     long-press never begins on a knob);
//   - iPhone: the sheet's grabber drag expands it with the scene kept at
//     180 pt at least; iPad: the float's grip drag moves it to a corner.
//
// State is read from the PYMOL_UITEST=1 probe (`lightsProbe`, ContentView's
// LightsUITestProbe): `sel=<name> radius= orbit= pitch= beam= cam=<hash>
// rig=<name>:<orbit>/<pitch>/<radius>/<beam>,...`, where cam hashes the live
// camera (the published LightCameraProjection plus the view matrix).
//
// Run (the iOS core must be built, swiftui/build_ios.sh):
//   xcodebuild test -project swiftui/PyMOLViewer.xcodeproj -scheme UITests_iOS \
//     -destination 'platform=iOS Simulator,id=<udid>' \
//     -only-testing:PyMOLViewerUITests/LightsGestureUITests

import XCTest
import UIKit

final class LightsGestureUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The scene: 1ubq, the three_point rig with the key's beam narrowed to
    /// 20 degrees so its rings stay small and clear of the viewport's corners,
    /// Lights mode entered on the key (PYMOL_AUTOLIGHTS).
    private static let scene = "hide everything; show cartoon; orient; lights three_point; lights key, beam=20"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["PYMOL_AUTOLOAD"] = "1ubq.cif"
        app.launchEnvironment["PYMOL_AUTOCMD"] = Self.scene
        app.launchEnvironment["PYMOL_AUTOLIGHTS"] = "key"
        // A one-run corner override (DEBUG token): the float starts at the
        // default corner and a grip drag never writes the stored corner.
        app.launchEnvironment["PYMOL_AUTOLIGHTS_EDIT"] = "corner:bl"
        app.launchEnvironment["PYMOL_UITEST"] = "1"
        app.launchEnvironment["PYMOL_SKIP_WHATS_NEW"] = "1"
        app.launchEnvironment["PYMOL_SKIP_GESTURE_HELP"] = "1"
        app.launchEnvironment["PYMOL_SKIP_FIRSTBOOT_THEME"] = "1"
        app.launchArguments += ["-ipadGestureCoachSeen", "YES"]
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    // MARK: - Off every target: the camera's

    func testOffTargetDragRotates() throws {
        let before = try launchInLights()
        let start = try offTargetPoint()
        let end = start.withOffset(CGVector(dx: 140, dy: 40))
        mark("drag")
        start.press(forDuration: 0.05, thenDragTo: end)
        let after = try waitForProbe("the camera to rotate") { $0.cam != before.cam }
        settle(1.5)  // the result stays on screen for the recording
        report(before, after)
        attach("off-target-drag")
        XCTAssertEqual(after.rig, before.rig, "a camera drag changed a light")
        XCTAssertEqual(after.sel, before.sel)
    }

    func testOffTargetPinchZooms() throws {
        let before = try launchInLights()
        mark("pinch")
        viewport().pinch(withScale: 1.8, velocity: 1.5)
        let after = try waitForProbe("the camera to zoom") { $0.cam != before.cam }
        settle(1.5)  // the result stays on screen for the recording
        report(before, after)
        attach("off-target-pinch")
        XCTAssertEqual(after.rig, before.rig, "a camera pinch changed a light")
    }

    func testOffTargetTwistRolls() throws {
        let before = try launchInLights()
        mark("twist")
        viewport().rotate(CGFloat.pi / 3, withVelocity: 1.0)
        let after = try waitForProbe("the camera to roll") { $0.cam != before.cam }
        settle(1.5)  // the result stays on screen for the recording
        report(before, after)
        attach("off-target-twist")
        XCTAssertEqual(after.rig, before.rig, "a camera twist changed a light")
    }

    // MARK: - On a knob: the light's

    func testKnobPinchChangesOnlyTheRadius() throws {
        let before = try launchInLights()
        // The knob farthest from the screen's edges: XCUITest spreads the
        // fingers around the element, and a finger clamped at an edge (the
        // iPhone's fill knob sits 47 pt from it) distorts the scale.
        let name = try knobFarthestFromTheEdges()
        let knob = try knobElement(name)
        guard knob.isHittable else {
            throw XCTSkip("the \(name) knob's element (\(knob.frame)) is not hittable: XCUITest cannot pinch "
                          + "on it, so the knob pinch stays on the #610 manual list")
        }
        let light = try XCTUnwrap(before.rig[name], "no \(name) light in \(before.line)")
        // Pinch out under 5x, in above it, so the radius never sits at a clamp.
        let grows = light.radius < 5
        let (scale, velocity): (CGFloat, CGFloat) = grows ? (1.6, 1.0) : (0.6, -1.0)
        print("LIGHTS_UITEST_KNOB \(name) frame=\(knob.frame) scale=\(scale)")
        mark("knob-pinch")
        knob.pinch(withScale: scale, velocity: velocity)
        let after = try waitForProbe("the \(name) radius to change") {
            ($0.rig[name]?.radius ?? light.radius) != light.radius
        }
        settle(1.5)  // the result stays on screen for the recording
        report(before, after)
        attach("knob-pinch")
        let edited = try XCTUnwrap(after.rig[name])
        XCTAssertEqual(after.sel, name, "the pinch selects the knob's light")
        if grows {
            XCTAssertGreaterThan(edited.radius, light.radius, "a pinch out shrank the radius")
        } else {
            XCTAssertLessThan(edited.radius, light.radius, "a pinch in grew the radius")
        }
        XCTAssertEqual(edited.radius * 2, (edited.radius * 2).rounded(), accuracy: 0.011,
                       "the radius is off the 0.5x grid: \(edited.radius)")
        XCTAssertEqual(edited.beam, light.beam, "the pinch changed the beam")
        XCTAssertEqual(edited.orbit, light.orbit, "the pinch moved the light")
        XCTAssertEqual(edited.pitch, light.pitch, "the pinch moved the light")
        XCTAssertEqual(after.cam, before.cam, "the knob pinch moved the camera")
        for other in ["key", "fill", "rim"] where other != name {
            XCTAssertEqual(after.rig[other], before.rig[other], "the pinch changed \(other)")
        }
    }

    func testPressHoldDragOnAKnobDrags() throws {
        let before = try launchInLights()
        let knob = try knobElement("fill")
        let fill = try XCTUnwrap(before.rig["fill"], "no fill light in \(before.line)")
        let centre = knob.frame
        let view = viewport().frame
        // Toward the viewport's centre, 60 pt: the light moves on its sphere.
        let dx = view.midX - centre.midX, dy = view.midY - centre.midY
        let length = max(1, hypot(dx, dy))
        let start = screenPoint(CGPoint(x: centre.midX, y: centre.midY))
        let end = start.withOffset(CGVector(dx: dx / length * 60, dy: dy / length * 60))
        mark("press-hold-drag")
        start.press(forDuration: 0.8, thenDragTo: end)
        let after = try waitForProbe("the fill light to move") {
            guard let moved = $0.rig["fill"] else { return false }
            return moved.orbit != fill.orbit || moved.pitch != fill.pitch
        }
        settle(1.5)  // the result stays on screen for the recording
        report(before, after)
        attach("knob-press-hold-drag")
        XCTAssertEqual(after.cam, before.cam, "the knob drag moved the camera")
        XCTAssertEqual(after.rig["fill"]?.beam, fill.beam, "the knob drag changed the beam")
        for name in ["key", "rim"] {
            XCTAssertEqual(after.rig[name], before.rig[name], "the knob drag changed \(name)")
        }
    }

    // MARK: - The docked sheet (iPhone) and the float (iPad)

    func testGrabberDragExpandsTheSheet() throws {
        guard !isPad else { throw XCTSkip("iPhone only: the iPad floats the orbit view (testGripDragMovesTheFloat)") }
        _ = try launchInLights()
        let grabber = element("lights.sheet.grabber")
        XCTAssertTrue(grabber.waitForExistence(timeout: 10), "the sheet's grabber is missing")
        XCTAssertEqual(grabber.value as? String, "Compact")
        attach("sheet-compact")
        let start = screenPoint(CGPoint(x: grabber.frame.midX, y: grabber.frame.midY))
        mark("grabber-drag")
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)))
        XCTAssertTrue(waitFor(timeout: 5) { (grabber.value as? String) == "Expanded" },
                      "the grabber drag did not expand the sheet (value \(String(describing: grabber.value)))")
        settle(1.0)
        attach("sheet-expanded")
        let sheet = element("lights.sheet")
        XCTAssertTrue(sheet.exists, "the sheet is missing")
        let scene = sheet.frame.minY - viewport().frame.minY
        print("LIGHTS_UITEST_SHEET value=\(String(describing: grabber.value)) sheet=\(sheet.frame) "
              + "viewport=\(viewport().frame) scene=\(scene)")
        XCTAssertGreaterThanOrEqual(scene, 179.5, "the expanded sheet leaves \(scene) pt of scene")
    }

    func testGripDragMovesTheFloat() throws {
        guard isPad else { throw XCTSkip("iPad only: phones dock the tools (testGrabberDragExpandsTheSheet)") }
        _ = try launchInLights()
        let grip = element("lights.float.grip")
        XCTAssertTrue(grip.waitForExistence(timeout: 10), "the float's grip is missing")
        XCTAssertEqual(grip.value as? String, "bottom left")
        let card = element("lights.orbit")
        XCTAssertTrue(card.exists, "the orbit card is missing")
        attach("float-bottom-left")
        // The grip's drag is the card's 44 pt header row (the capsule above
        // it passes touches through); its leading part, clear of the chevron.
        let before = card.frame
        let start = screenPoint(CGPoint(x: card.frame.minX + 40, y: card.frame.minY + 26))
        let view = viewport().frame
        let end = screenPoint(CGPoint(x: view.minX + 60, y: view.minY + 60))
        mark("grip-drag")
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(waitFor(timeout: 5) { (grip.value as? String) == "top left" },
                      "the grip drag did not move the float (value \(String(describing: grip.value)))")
        settle(1.0)
        attach("float-top-left")
        print("LIGHTS_UITEST_FLOAT value=\(String(describing: grip.value)) card before=\(before) after=\(card.frame)")
        XCTAssertLessThan(card.frame.midY, view.midY, "the card is not in the top half: \(card.frame)")
    }

    // MARK: - The probe

    private struct ProbeTimeout: Error, CustomStringConvertible {
        var description: String
    }

    private struct LightValues: Equatable {
        var orbit: Double, pitch: Double, radius: Double, beam: Double
    }

    private struct Probe {
        var line: String
        var fields: [String: String] = [:]
        var rig: [String: LightValues] = [:]

        var sel: String { fields["sel"] ?? "none" }
        var cam: String { fields["cam"] ?? "none" }

        init(_ line: String) {
            self.line = line
            for word in line.split(separator: " ") {
                let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            for entry in (fields["rig"] ?? "").split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let numbers = parts[1].split(separator: "/").compactMap { Double($0) }
                guard numbers.count == 4 else { continue }
                rig[parts[0]] = LightValues(orbit: numbers[0], pitch: numbers[1],
                                            radius: numbers[2], beam: numbers[3])
            }
        }
    }

    private func probe() -> Probe? {
        let text = app.staticTexts["lightsProbe"]
        guard text.exists else { return nil }
        return Probe(text.label)
    }

    /// Launch, wait for the rig, the camera and Lights mode on the key, and
    /// let the layout settle.
    private func launchInLights() throws -> Probe {
        app.launch()
        XCTAssertTrue(app.staticTexts["lightsProbe"].waitForExistence(timeout: 90),
                      "the lightsProbe hook never appeared (Lights mode not entered, or PYMOL_UITEST not honoured)")
        _ = try waitForProbe("the three_point rig with the key selected", timeout: 60) {
            $0.sel == "key" && $0.cam != "none" && $0.rig.count == 3 && $0.rig["key"]?.beam == 20
        }
        XCTAssertTrue(element(Self.knobIdentifier("fill")).waitForExistence(timeout: 20),
                      "the gizmo's knobs never appeared")
        settle(2.0)
        return try XCTUnwrap(probe())
    }

    private func waitForProbe(_ what: String, timeout: TimeInterval = 8,
                              _ predicate: (Probe) -> Bool) throws -> Probe {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Probe?
        while Date() < deadline {
            if let p = probe() {
                last = p
                if predicate(p) { return p }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ProbeTimeout(description: "timed out waiting for \(what); probe: \(last?.line ?? "missing")")
    }

    // MARK: - Elements and points

    private static func knobIdentifier(_ name: String) -> String { "lights.gizmo.knob." + name }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func viewport() -> XCUIElement {
        let view = element("raymol.viewport")
        XCTAssertTrue(view.waitForExistence(timeout: 10), "the raymol.viewport element is missing")
        return view
    }

    private func knobElement(_ name: String) throws -> XCUIElement {
        let knob = element(Self.knobIdentifier(name))
        guard knob.waitForExistence(timeout: 10), !knob.frame.isEmpty else {
            throw XCTSkip("the \(name) knob's element is unreachable to XCUITest, so the knob gestures "
                          + "stay on the #610 manual list")
        }
        return knob
    }

    /// The light whose knob centre lies farthest from the screen's edges.
    private func knobFarthestFromTheEdges() throws -> String {
        let screen = app.frame
        var best: (name: String, margin: CGFloat)?
        for name in ["key", "fill", "rim"] {
            let knob = element(Self.knobIdentifier(name))
            guard knob.exists, !knob.frame.isEmpty else { continue }
            let c = CGPoint(x: knob.frame.midX, y: knob.frame.midY)
            let margin = min(c.x - screen.minX, screen.maxX - c.x, c.y - screen.minY, screen.maxY - c.y)
            if margin > (best?.margin ?? -.infinity) { best = (name, margin) }
        }
        guard let best else {
            throw XCTSkip("no knob element is reachable to XCUITest, so the knob pinch stays on the #610 manual list")
        }
        return best.name
    }

    /// A point in screen coordinates (points), independent of hittability.
    private func screenPoint(_ p: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: p.x, dy: p.y))
    }

    /// The viewport's top-leading region, outside the gizmo's sphere and
    /// every knob's touch frame.
    private func offTargetPoint() throws -> XCUICoordinate {
        let view = viewport().frame
        let p = CGPoint(x: view.minX + view.width * 0.07, y: view.minY + view.height * 0.09)
        for name in ["key", "fill", "rim"] {
            let knob = element(Self.knobIdentifier(name))
            if knob.exists {
                XCTAssertFalse(knob.frame.insetBy(dx: -8, dy: -8).contains(p),
                               "the off-target point \(p) is on the \(name) knob \(knob.frame)")
            }
        }
        return screenPoint(p)
    }

    // MARK: - Helpers

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// A wall-clock marker in the test log, for cutting the simulator
    /// recording to each gesture.
    private func mark(_ gesture: String) {
        print(String(format: "LIGHTS_UITEST_MARK %@ %.2f", gesture, Date().timeIntervalSince1970))
    }

    /// The probe before and after a gesture, in the test log.
    private func report(_ before: Probe, _ after: Probe) {
        print("LIGHTS_UITEST_PROBE before: \(before.line)")
        print("LIGHTS_UITEST_PROBE after:  \(after.line)")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
