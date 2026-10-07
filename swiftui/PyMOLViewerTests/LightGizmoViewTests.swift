import AppKit
import Combine
import CoreGraphics
import ImageIO
import SwiftUI
import XCTest
@testable import RayMol

// The light gizmo as drawn (#622 part 4): LightGizmoUIState, the overlay's
// visibility and size, the Shadow chip (the inspector's strings and call, the
// cap notice, the Shadows-off hint), its placement, the VoiceOver elements
// (read back from the hosting view's accessibility tree), offscreen pictures
// of the overlay on fake seams, and composites of the live Metal render under
// the overlay. The drawing writes nothing: every picture checks the fake
// store saw no write beyond what its `after` did.

// MARK: - Fixtures

/// The fake camera: the world translated by (0, 0, -200) (FakeRigStore's
/// faithful eye space), perspective, 20 degrees, no letterbox.
private let viewCameraOffset = SIMD3<Double>(0, 0, -200)
private let viewTestSize = CGSize(width: 800, height: 600)

private func viewPerspective(letterbox: Double = 0) -> LightCameraProjection {
    LightCameraProjection(orthoscopic: false, fovDegrees: 20, cameraDistance: 200, letterboxAspect: letterbox)
}

/// key (-45°, +30°, 3×, in front, selected), fill (60°, +10°, 2×) and rim
/// (160°, -20°, 3×, behind), faithful eye space under the fake camera, in
/// Lights mode with the gizmo's demand.
private func viewRig(_ store: FakeRigStore) {
    store.setRig(["key", "fill", "rim"])
    store.lights[0].orbit = -45
    store.lights[0].pitch = 30
    store.lights[0].radius = 3
    store.lights[1].orbit = 60
    store.lights[1].pitch = 10
    store.lights[1].radius = 2
    store.lights[2].orbit = 160
    store.lights[2].pitch = -20
    store.lights[2].radius = 3
    store.eyeOffset = viewCameraOffset
    store.projection = viewPerspective()
}

@MainActor
private func viewController(_ setUp: (FakeRigStore) -> Void = viewRig) -> (FakeRigStore, LightsController) {
    let store = FakeRigStore()
    setUp(store)
    let controller = LightsController(seams: store.seams)
    controller.eyeDemand = .everyFrame
    controller.begin()
    return (store, controller)
}

@MainActor
private func viewLayout(_ controller: LightsController, size: CGSize = viewTestSize, grid: Bool = false,
                        shadowsOn: Bool? = true) -> LightGizmoLayout? {
    LightGizmoLayout.make(LightGizmoInputs(controller: controller, viewSize: size, gridMode: grid,
                                           sceneShadowsOn: shadowsOn))
}

private let viewStyle = LightsBarStyle(accent: Color(.sRGB, red: 0.33, green: 0.60, blue: 1.0, opacity: 1),
                                       text: Color(white: 0.92), background: Color(white: 0.16))

/// An NSHostingView in a borderless window far off any screen (the app's own
/// view drawn into memory, no screen capture), kept until tearDown.
@MainActor
private final class OffscreenHost {
    let host: NSView
    let window: NSWindow

    init(_ view: some View, size: CGSize) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.host = host
        self.window = window
        settle()
    }

    func settle(_ seconds: TimeInterval = 0.3) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        host.layoutSubtreeIfNeeded()
    }

    func resize(_ size: CGSize) {
        window.setContentSize(size)
        settle()
    }

    func bitmap() -> NSBitmapImageRep? {
        settle()
        var rep = draw()
        if rep.map(Self.isFlat) ?? true {
            window.orderFrontRegardless()
            settle()
            rep = draw()
        }
        return rep
    }

    private func draw() -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    func close() { window.orderOut(nil) }

    /// At most two colours among the sampled pixels: blank, or a bare fill.
    static func isFlat(_ rep: NSBitmapImageRep) -> Bool {
        var seen = Set<String>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(String(format: "%.2f %.2f %.2f %.2f", c.redComponent, c.greenComponent,
                                   c.blueComponent, c.alphaComponent))
                if seen.count > 2 { return false }
            }
        }
        return true
    }

    /// Pixels (every other one in each direction) that are not the backdrop
    /// black.
    static func inkedPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent + c.greenComponent + c.blueComponent > 0.03 { count += 1 }
            }
        }
        return count
    }

    // MARK: accessibility

    /// Every accessibility element under the window, depth first. SwiftUI
    /// builds its nodes only while an assistive client has asked the app for
    /// them (LightGizmoAccessibilityTests sets AXEnhancedUserInterface on the
    /// app itself, no system prompt); they answer the NSAccessibility
    /// getters, read here by key-value coding.
    func elements() -> [AXNode] {
        settle(0.1)
        var out: [AXNode] = []
        func walk(_ e: NSObject, _ depth: Int) {
            out.append(AXNode(object: e))
            guard depth < 40 else { return }
            for child in (e.value(forKey: "accessibilityChildren") as? [Any]) ?? [] {
                if let c = child as? NSObject { walk(c, depth + 1) }
            }
        }
        walk(window, 0)
        return out
    }

    func element(_ identifier: String) -> AXNode? {
        elements().first { $0.identifier == identifier }
    }
}

/// The NSAccessibility press, called by selector on an element that does not
/// declare the protocol (SwiftUI's AccessibilityNode).
@objc private protocol AXPressable {
    func accessibilityPerformPress() -> Bool
}

/// One accessibility element, read by key-value coding.
@MainActor
private struct AXNode {
    let object: NSObject

    private func get(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func text(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let s = value as? NSAttributedString { return s.string }
        return value.map { "\($0)" }
    }

    var identifier: String? { text(get("accessibilityIdentifier")) }
    var label: String? { text(get("accessibilityLabel")) }
    /// The value (a role-less element reports it as its value description).
    var value: String? { text(get("accessibilityValue")) ?? text(get("accessibilityValueDescription")) }
    /// Label and value together (a combined element puts its text in either).
    var spoken: String { [label, value].compactMap { $0 }.joined(separator: " ") }
    var isSelected: Bool {
        object.responds(to: NSSelectorFromString("isAccessibilitySelected"))
            && (object.value(forKey: "accessibilitySelected") as? Bool ?? false)
    }
    var customActions: [NSAccessibilityCustomAction] {
        (get("accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
    }

    /// VoiceOver's press.
    func press() -> Bool {
        guard object.responds(to: #selector(AXPressable.accessibilityPerformPress)) else { return false }
        return unsafeBitCast(object, to: AXPressable.self).accessibilityPerformPress()
    }
}

/// The overlay over a black backdrop, as ContentView places it over the
/// viewport.
@MainActor
private func overlayRoot(_ controller: LightsController, ui: LightGizmoUIState, size: CGSize,
                         gridMode: Bool = false, shadowsOn: Bool? = true,
                         backdrop: AnyView = AnyView(Color.black),
                         onEnable: @escaping () -> Void = {}) -> some View {
    backdrop
        .frame(width: size.width, height: size.height)
        .overlay {
            LightGizmoOverlay(controller: controller, ui: ui, style: viewStyle, gridMode: gridMode,
                              sceneShadowsOn: shadowsOn, onEnableSceneShadows: onEnable)
        }
}

// MARK: - UI state

@MainActor
final class LightGizmoUIStateTests: XCTestCase {

    func testSettersPublishOnlyOnChange() {
        let ui = LightGizmoUIState()
        let changes = LightsChangeCounter()
        let watch = ui.objectWillChange.sink { _ in changes.count += 1 }
        defer { watch.cancel() }
        ui.hovered = .aimDot
        ui.hovered = .aimDot
        XCTAssertEqual(changes.count, 1)
        ui.active = .knob("key")
        ui.active = .knob("key")
        XCTAssertEqual(changes.count, 2)
        ui.hemisphere = .front
        ui.hemisphere = .front
        ui.outside = false
        XCTAssertEqual(changes.count, 3, "outside was already false")
        ui.outside = true
        ui.readout = "Beam 30°"
        ui.readout = "Beam 30°"
        ui.viewSize = CGSize(width: 10, height: 20)
        ui.viewSize = CGSize(width: 10, height: 20)
        XCTAssertEqual(changes.count, 6)
        ui.reset()
        XCTAssertEqual(changes.count, 7)
        XCTAssertEqual(ui.values, LightGizmoUIState.Values())
        ui.reset()
        XCTAssertEqual(changes.count, 7, "a reset of nothing publishes nothing")
        XCTAssertNil(ui.viewSize, "no size until the overlay appears again")
    }

    func testTrackShowsAKnobDrag() throws {
        let (_, controller) = viewController()
        let l = try XCTUnwrap(viewLayout(controller))
        let key = try XCTUnwrap(l.knob(named: "key"))
        let interaction = LightGizmoInteraction(controller: controller)
        var session = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        let ui = LightGizmoUIState()
        ui.track(session, layout: l)
        XCTAssertEqual(ui.active, .knob("key"))
        XCTAssertEqual(ui.hemisphere, .front)
        XCTAssertFalse(ui.outside)
        // Out past the band to the left: the knob turns hollow at once.
        interaction.move(&session, to: CGPoint(x: key.centre.x - 5, y: key.centre.y))
        interaction.move(&session, to: CGPoint(x: l.centre.x - l.bandRadius - 10, y: l.centre.y))
        let after = try XCTUnwrap(viewLayout(controller))
        ui.track(session, layout: after)
        XCTAssertEqual(ui.hemisphere, .behind)
        XCTAssertTrue(ui.outside)
        XCTAssertEqual(ui.readout, after.readout(for: .knob("key")))
        XCTAssertTrue(ui.readout?.hasPrefix("Orbit ") ?? false, ui.readout ?? "nil")
        ui.track(nil, layout: after)
        XCTAssertNil(ui.active)
        XCTAssertNil(ui.hemisphere)
        XCTAssertFalse(ui.outside)
        XCTAssertNil(ui.readout)
        session.end()
        ui.track(session, layout: after)
        XCTAssertNil(ui.active, "an ended session shows nothing")
    }

    func testCoincidentRingsShowTheRingTheFirstMoveChose() throws {
        let (_, controller) = viewController {
            viewRig($0)
            $0.lights[0].softness = 0
        }
        let l = try XCTUnwrap(viewLayout(controller))
        let s = try XCTUnwrap(l.selected)
        let aim = try XCTUnwrap(s.aimDot)
        let ring = try XCTUnwrap(s.outerRing)
        // The ring sample farthest from the handles.
        let handles = [s.outerHandle?.point, s.innerHandle?.point].compactMap { $0 }
        let press = try XCTUnwrap(ring.samples.compactMap { $0 }.max { a, b in
            handles.map { hypot($0.x - a.x, $0.y - a.y) }.min()! < handles.map { hypot($0.x - b.x, $0.y - b.y) }.min()!
        })
        var session = try XCTUnwrap(LightGizmoDragSession(target: .rings, owner: "key", press: press, layout: l))
        XCTAssertEqual(LightGizmoUIState.shownTarget(session), .rings)
        let out = CGPoint(x: press.x + (press.x - aim.x) * 0.2, y: press.y + (press.y - aim.y) * 0.2)
        _ = session.move(to: out, current: LightGizmoCurrent())
        XCTAssertEqual(LightGizmoUIState.shownTarget(session), .outerRing)
        let ui = LightGizmoUIState()
        ui.track(session, layout: l)
        XCTAssertEqual(ui.active, .outerRing)
        XCTAssertNil(ui.hemisphere, "not a knob")
        XCTAssertEqual(ui.readout, l.readout(for: .outerRing))
    }

    func testShowRadius() throws {
        let (_, controller) = viewController()
        let l = try XCTUnwrap(viewLayout(controller))
        let ui = LightGizmoUIState()
        ui.showRadius(of: "fill", layout: l)
        XCTAssertEqual(ui.active, .knob("fill"))
        XCTAssertEqual(ui.readout, l.radiusReadout("fill"))
        XCTAssertTrue(ui.readout?.hasPrefix("Radius 2.0×") ?? false, ui.readout ?? "nil")
        ui.showRadius(of: nil, layout: l)
        XCTAssertNil(ui.active)
        XCTAssertNil(ui.readout)
    }
}

/// The engine's UI state is reset when Lights mode ends (live engine).
@MainActor
final class LightGizmoUIEngineTests: XCTestCase {
    override func tearDown() {
        LightsLive.tearDown()
        super.tearDown()
    }

    func testLeavingLightsResetsTheUIState() throws {
        try LightsLive.requireEngine()
        let engine = PyMOLEngine.shared
        LightsLive.addPeptide()
        _ = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        let ui = engine.lightGizmoUI
        ui.hovered = .aimDot
        ui.active = .knob("key")
        ui.readout = "Beam 30°"
        ui.viewSize = CGSize(width: 300, height: 200)
        engine.setInteractionMode(.viewing)
        XCTAssertEqual(ui.values, LightGizmoUIState.Values(), "leaving Lights mode resets the gizmo's UI state")
        XCTAssertTrue(engine.lightGizmoUI === ui, "one state object for the engine")
    }
}

// MARK: - The overlay

@MainActor
final class LightGizmoOverlayTests: XCTestCase {
    private var hosts: [OffscreenHost] = []

    override func tearDown() {
        hosts.forEach { $0.close() }
        hosts = []
        super.tearDown()
    }

    private func host(_ view: some View, size: CGSize = viewTestSize) -> OffscreenHost {
        let h = OffscreenHost(view, size: size)
        hosts.append(h)
        return h
    }

    /// Drawn only while the gizmo shows: in Lights mode with lights and eye
    /// data, not in grid mode, not while busy; nothing drawn writes.
    func testDrawsOnlyWhenTheGizmoShows() throws {
        let store = FakeRigStore()
        viewRig(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        let ui = LightGizmoUIState()
        func inked(grid: Bool = false) throws -> Int {
            let h = host(overlayRoot(controller, ui: ui, size: viewTestSize, gridMode: grid))
            let rep = try XCTUnwrap(h.bitmap())
            return OffscreenHost.inkedPixels(rep)
        }
        XCTAssertEqual(try inked(), 0, "not in Lights mode: nothing drawn")
        controller.begin()
        XCTAssertGreaterThan(try inked(), 200, "in Lights mode the gizmo is drawn")
        XCTAssertEqual(try inked(grid: true), 0, "grid mode hides it")
        store.busy = true
        XCTAssertEqual(try inked(), 0, "a movie export hides it")
        store.busy = false
        controller.end()
        XCTAssertEqual(try inked(), 0, "Done hides it")
        XCTAssertTrue(store.numberWrites.isEmpty, "drawing writes nothing")
        XCTAssertTrue(store.vectorWrites.isEmpty)
        XCTAssertTrue(store.performed.isEmpty)
    }

    /// The overlay records its size (the viewport's) in the UI state, and
    /// follows a resize.
    func testRecordsItsSize() throws {
        let (_, controller) = viewController()
        let ui = LightGizmoUIState()
        XCTAssertNil(ui.viewSize)
        let root = LightGizmoOverlay(controller: controller, ui: ui, style: viewStyle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        let h = host(root, size: CGSize(width: 640, height: 480))
        XCTAssertEqual(ui.viewSize, CGSize(width: 640, height: 480))
        h.resize(CGSize(width: 500, height: 400))
        XCTAssertEqual(ui.viewSize, CGSize(width: 500, height: 400))
    }

    /// The chip sits on the knob's outward ray, past the knob's hit area and
    /// its label, for every light selected in turn, on macOS and iOS slop.
    func testTheChipClearsTheKnobAndItsLabel() throws {
        let (_, controller) = viewController()
        for slop in [CGFloat(6), 14] {
            for name in ["key", "fill", "rim"] {
                controller.select(name: name)
                let l = try XCTUnwrap(LightGizmoLayout.make(
                    LightGizmoInputs(controller: controller, viewSize: viewTestSize, gridMode: false,
                                     sceneShadowsOn: true), metrics: LightGizmoMetrics(slop: slop)))
                let knob = try XCTUnwrap(l.knob(named: name))
                let place = try XCTUnwrap(LightGizmoOverlay.chipPlacement(l))
                let chipSize = CGSize(width: 62, height: 20)
                let frames = LightGizmoChipLayout.frames(
                    point: place.point, anchor: place.anchor, calloutAbove: place.calloutAbove,
                    chipSize: chipSize, calloutSize: CGSize(width: 220, height: 40),
                    bounds: CGRect(origin: .zero, size: viewTestSize), margin: 8)
                // Not over the knob's hit area.
                let hit = knob.radius + slop
                let nearest = CGPoint(x: min(max(knob.centre.x, frames.chip.minX), frames.chip.maxX),
                                      y: min(max(knob.centre.y, frames.chip.minY), frames.chip.maxY))
                XCTAssertGreaterThan(hypot(nearest.x - knob.centre.x, nearest.y - knob.centre.y), hit,
                                     "\(name), slop \(slop): the chip covers the knob")
                // Not over the label.
                let size = LightGizmoPainter.labelSize(knob.label, selected: true)
                let a = LightGizmoPainter.labelAnchor(knob.labelDirection)
                let label = CGRect(x: knob.labelPoint.x - a.x * size.width,
                                   y: knob.labelPoint.y - a.y * size.height,
                                   width: size.width, height: size.height)
                XCTAssertFalse(frames.chip.insetBy(dx: 0.5, dy: 0.5).intersects(label),
                               "\(name): the chip \(frames.chip) covers its label \(label)")
                XCTAssertEqual(place.anchor, a, "anchored like the label")
                XCTAssertTrue(CGRect(origin: .zero, size: viewTestSize).insetBy(dx: 8, dy: 8)
                    .contains(frames.chip), "kept inside the view")
            }
        }
    }

    /// The chip and its callout stay 8 pt inside the view; the callout goes
    /// above or below the chip, aligned as the anchor says.
    func testChipLayoutKeepsInside() throws {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chip = CGSize(width: 60, height: 20)
        let callout = CGSize(width: 220, height: 50)
        // Past the top-right corner: clamped.
        var f = LightGizmoChipLayout.frames(point: CGPoint(x: 420, y: -30), anchor: .bottomLeading,
                                            calloutAbove: true, chipSize: chip, calloutSize: callout,
                                            bounds: bounds, margin: 8)
        XCTAssertEqual(f.chip, CGRect(x: 332, y: 8, width: 60, height: 20))
        let up = try XCTUnwrap(f.callout)
        XCTAssertEqual(up.maxX, 392, accuracy: 1e-9)
        XCTAssertEqual(up.minY, 8, accuracy: 1e-9, "no room above: clamped inside")
        // In the open, leading anchor, callout below.
        f = LightGizmoChipLayout.frames(point: CGPoint(x: 100, y: 100), anchor: .leading, calloutAbove: false,
                                        chipSize: chip, calloutSize: callout, bounds: bounds, margin: 8)
        XCTAssertEqual(f.chip, CGRect(x: 100, y: 90, width: 60, height: 20))
        XCTAssertEqual(f.callout, CGRect(x: 100, y: 114, width: 220, height: 50))
        // Trailing anchor: the callout's right edge on the chip's.
        f = LightGizmoChipLayout.frames(point: CGPoint(x: 300, y: 200), anchor: .trailing, calloutAbove: true,
                                        chipSize: chip, calloutSize: callout, bounds: bounds, margin: 8)
        XCTAssertEqual(f.chip, CGRect(x: 240, y: 190, width: 60, height: 20))
        XCTAssertEqual(f.callout, CGRect(x: 80, y: 136, width: 220, height: 50))
        // No callout.
        XCTAssertNil(LightGizmoChipLayout.frames(point: .zero, anchor: .center, calloutAbove: false,
                                                 chipSize: chip, calloutSize: nil, bounds: bounds,
                                                 margin: 8).callout)
    }

    /// One VoiceOver element per knob, at its hit area, with LightGizmoState's
    /// strings, in rig order.
    func testKnobElementsSitOnTheKnobs() throws {
        let (_, controller) = viewController()
        let l = try XCTUnwrap(viewLayout(controller))
        let state = try XCTUnwrap(LightGizmoState(controller))
        let elements = LightGizmoOverlay.knobElements(l, state: state)
        XCTAssertEqual(elements.map(\.knob), state.knobs)
        for e in elements {
            let knob = try XCTUnwrap(l.knob(named: e.knob.name))
            XCTAssertEqual(e.frame.midX, knob.centre.x, accuracy: 1e-9)
            XCTAssertEqual(e.frame.midY, knob.centre.y, accuracy: 1e-9)
            XCTAssertEqual(e.frame.width, 2 * (knob.radius + l.metrics.slop), accuracy: 1e-9)
        }
        XCTAssertTrue(LightGizmoOverlay.knobElements(l, state: nil).isEmpty)
    }
}

// MARK: - The chip and VoiceOver, through the hosting view's accessibility

@MainActor
final class LightGizmoAccessibilityTests: XCTestCase {
    private var hosts: [OffscreenHost] = []
    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private static let manual = NSAccessibility.Attribute(rawValue: "AXManualAccessibility")

    override func setUp() {
        super.setUp()
        // As an assistive client does: SwiftUI then builds its accessibility
        // nodes. Set on the test host's own NSApplication (no system
        // prompt), undone in tearDown.
        NSApp.accessibilitySetValue(true, forAttribute: Self.enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: Self.manual)
    }

    override func tearDown() {
        hosts.forEach { $0.close() }
        hosts = []
        NSApp.accessibilitySetValue(false, forAttribute: Self.enhanced)
        NSApp.accessibilitySetValue(false, forAttribute: Self.manual)
        super.tearDown()
    }

    private func host(_ controller: LightsController, ui: LightGizmoUIState? = nil,
                      shadowsOn: Bool? = true, onEnable: @escaping () -> Void = {}) -> OffscreenHost {
        let h = OffscreenHost(overlayRoot(controller, ui: ui ?? LightGizmoUIState(), size: viewTestSize,
                                          shadowsOn: shadowsOn,
                                          onEnable: onEnable), size: viewTestSize)
        hosts.append(h)
        return h
    }

    /// The chip is the inspector's Shadow toggle: its label, help and value;
    /// pressing it calls setShadow (one bridge write, no command).
    func testTheChipIsTheInspectorsShadow() throws {
        let (store, controller) = viewController()
        let h = host(controller)
        let chip = try XCTUnwrap(h.element(LightGizmoState.chipIdentifier), "no Shadow chip")
        XCTAssertEqual(chip.label, LightsInspectorState.shadowLabel)
        let inspector = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(chip.value, inspector.shadowValue)
        XCTAssertEqual(chip.value, "Off")
        XCTAssertTrue(chip.press())
        h.settle()
        XCTAssertTrue(store.lights[0].shadow, "the press turned the selected light's shadow on")
        XCTAssertEqual(store.numberWrites.map(\.field), ["shadow"])
        XCTAssertTrue(store.performed.isEmpty, "a bridge write, no command")
        let after = try XCTUnwrap(h.element(LightGizmoState.chipIdentifier))
        XCTAssertEqual(after.value, "On")
        XCTAssertEqual(after.value, LightsInspectorState(controller)?.shadowValue)
    }

    /// Hidden while a target is dragged.
    func testTheChipHidesDuringADrag() throws {
        let (_, controller) = viewController()
        let ui = LightGizmoUIState()
        let h = host(controller, ui: ui)
        XCTAssertNotNil(h.element(LightGizmoState.chipIdentifier))
        ui.active = .knob("key")
        XCTAssertNil(h.element(LightGizmoState.chipIdentifier), "hidden while a knob is dragged")
        ui.active = .outerHandle
        XCTAssertNil(h.element(LightGizmoState.chipIdentifier))
        ui.active = nil
        XCTAssertNotNil(h.element(LightGizmoState.chipIdentifier))
    }

    /// A fourth shadowed light is refused: the core is unchanged and the cap
    /// notice shows in the chip's callout, as in the inspector.
    func testTheCapNotice() throws {
        let (store, controller) = viewController {
            viewRig($0)
            $0.setRig(["key", "fill", "rim", "light4"])
            for i in 1...3 { $0.lights[i].shadow = true }
        }
        let h = host(controller)
        XCTAssertNil(h.element(LightGizmoOverlay.noticeIdentifier))
        let chip = try XCTUnwrap(h.element(LightGizmoState.chipIdentifier))
        XCTAssertTrue(chip.press())
        h.settle()
        XCTAssertFalse(store.lights[0].shadow, "refused: the core is unchanged")
        XCTAssertTrue(controller.shadowRefused)
        let notice = try XCTUnwrap(h.element(LightGizmoOverlay.noticeIdentifier), "no cap notice")
        XCTAssertTrue(notice.spoken.contains(LightsInspectorState.shadowCapNotice), notice.spoken)
        XCTAssertEqual(LightsInspectorState(controller)?.notice, LightsInspectorState.shadowCapNotice,
                       "shown in the inspector too")
    }

    /// The Shadows-off hint shows while the light casts a shadow and the
    /// scene's switch is off; Turn On calls the inspector's closure.
    func testTheShadowsOffHint() throws {
        let (_, controller) = viewController {
            viewRig($0)
            $0.lights[0].shadow = true
        }
        XCTAssertNil(host(controller, shadowsOn: true).element(LightGizmoOverlay.turnOnIdentifier))
        XCTAssertNil(host(controller, shadowsOn: nil).element(LightGizmoOverlay.turnOnIdentifier),
                     "unknown: no hint")
        var enabled = 0
        let h = host(controller, shadowsOn: false, onEnable: { enabled += 1 })
        let hint = try XCTUnwrap(h.element(LightGizmoOverlay.hintIdentifier), "no Shadows-off hint")
        XCTAssertTrue(hint.spoken.contains(LightsInspectorState.shadowsOffHint), hint.spoken)
        let turnOn = try XCTUnwrap(h.element(LightGizmoOverlay.turnOnIdentifier))
        XCTAssertEqual(turnOn.label, LightsInspectorState.turnOnLabel)
        XCTAssertTrue(turnOn.press())
        h.settle()
        XCTAssertEqual(enabled, 1)
    }

    /// The canvas is a `Light gizmo` container with one element per knob:
    /// `<name> light`, front or behind plus orbit, pitch and radius, the
    /// selected one marked, and a Select action that selects that light.
    func testOneElementPerKnob() throws {
        let (store, controller) = viewController()
        let h = host(controller)
        let container = try XCTUnwrap(h.element(LightGizmoState.identifier), "no gizmo container")
        XCTAssertEqual(container.label, LightGizmoState.containerLabel)
        let state = try XCTUnwrap(LightGizmoState(controller))
        for knob in state.knobs {
            let e = try XCTUnwrap(h.element(knob.identifier), "no element for \(knob.name)")
            XCTAssertEqual(e.label, knob.label)
            XCTAssertEqual(e.value, knob.value)
            XCTAssertEqual(e.isSelected, knob.isSelected, knob.name)
        }
        let rim = try XCTUnwrap(h.element(LightGizmoState.knobIdentifier("rim")))
        XCTAssertTrue(rim.value?.hasPrefix(LightGizmoState.behindValue) ?? false, rim.value ?? "nil")
        let fill = try XCTUnwrap(h.element(LightGizmoState.knobIdentifier("fill")))
        let select = try XCTUnwrap(fill.customActions.first { $0.name == "Select fill" },
                                   "no Select action")
        if let handler = select.handler {
            XCTAssertTrue(handler())
        } else if let target = select.target as? NSObject, let selector = select.selector {
            _ = target.perform(selector, with: select)
        } else {
            XCTFail("the Select action does nothing")
        }
        h.settle()
        XCTAssertEqual(controller.selection.name, "fill")
        // VoiceOver's press on a knob selects its light too.
        XCTAssertTrue(try XCTUnwrap(h.element(LightGizmoState.knobIdentifier("rim"))).press())
        h.settle()
        XCTAssertEqual(controller.selection.name, "rim")
        XCTAssertEqual(h.element(LightGizmoState.knobIdentifier("rim"))?.isSelected, true)
        XCTAssertTrue(store.numberWrites.isEmpty, "selecting writes nothing")
        XCTAssertTrue(store.performed.isEmpty)
    }
}

// MARK: - Pictures

/// The overlay drawn offscreen over a dark backdrop (cacheDisplay of the
/// app's own view, no screen capture). PNGs go to
/// $RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR (TEST_RUNNER_RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR
/// on the xcodebuild line), else NSTemporaryDirectory()/raymol-lightgizmo-
/// snapshots; each is logged as `LIGHTGIZMO_SNAPSHOT: <path>`.
@MainActor
final class LightGizmoSnapshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var size = viewTestSize
        var shadowsOn: Bool? = true
        var setUp: (FakeRigStore) -> Void = viewRig
        var after: (LightsController, FakeRigStore, LightGizmoUIState, CGSize) throws -> Void = { _, _, _, _ in }
    }

    static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightgizmo-snapshots", isDirectory: true)
    }

    private var hosts: [OffscreenHost] = []

    override func tearDown() {
        hosts.forEach { $0.close() }
        hosts = []
        super.tearDown()
    }

    func testRenderSnapshots() throws {
        let shots: [Shot] = [
            // Three-point, key selected (rings, handles, aim dot, chip), rim
            // behind the molecule: hollow and dashed.
            Shot(name: "key_selected_rim_hollow"),
            // Rim selected: its rings around the aim point through the sphere.
            Shot(name: "rim_selected_rings", after: { controller, _, _, _ in controller.select(name: "rim") }),
            // The pointer over the outer ring.
            Shot(name: "hover_outer_ring", after: { _, _, ui, _ in ui.hovered = .outerRing }),
            // Mid-drag: key dragged out past the band (hollow at once), the
            // band and the readout; the chip hidden.
            Shot(name: "mid_drag_band_readout", after: { controller, _, ui, size in
                try Self.dragKeyOut(controller, ui: ui, size: size)
            }),
            // The handles at softness 0 (coincident rings) and 1 (the inner
            // ring on the aim dot): kept apart and off the aim dot.
            Shot(name: "handles_softness0", setUp: { viewRig($0); $0.lights[0].softness = 0 }),
            Shot(name: "handles_softness1", setUp: { viewRig($0); $0.lights[0].softness = 1 }),
            // A fourth shadowed light refused: the cap notice under the chip.
            Shot(name: "chip_cap_notice", setUp: { store in
                viewRig(store)
                let three = store.lights
                store.setRig(["key", "fill", "rim", "light4"])
                for i in 0..<3 { store.lights[i] = three[i] }
                for i in 1...3 { store.lights[i].shadow = true }
                store.lights[3].orbit = -120
                store.lights[3].pitch = 50
            }, after: { controller, _, _, _ in
                XCTAssertEqual(LightGizmoInteraction(controller: controller).toggleShadow(), .refused)
            }),
            // The key casts a shadow the scene does not show: the hint and
            // Turn On; the knob's crescent dimmed.
            Shot(name: "chip_shadows_off_hint", shadowsOn: false,
                 setUp: { viewRig($0); $0.lights[0].shadow = true }),
            // The rig off: every knob dimmed, still editable.
            Shot(name: "rig_off", setUp: { store in
                viewRig(store)
                store.enabled = false
            }),
            // A phone-sized viewport.
            Shot(name: "compact_390x640", size: CGSize(width: 390, height: 640)),
            // Orthoscopic.
            Shot(name: "ortho", setUp: { store in
                viewRig(store)
                store.projection = LightCameraProjection(orthoscopic: true, fovDegrees: 20,
                                                         cameraDistance: 200, letterboxAspect: 0)
            }),
            // A square letterbox in a wide view: bars left and right.
            // (The backdrop shows the scene rect a shade lighter.)
            Shot(name: "letterbox_square", setUp: { store in
                viewRig(store)
                store.projection = viewPerspective(letterbox: 1)
            }),
        ]
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, shot) in shots.enumerated() {
            let url = dir.appendingPathComponent(String(format: "gizmo_%02d_%@.png", i + 1, shot.name))
            try render(shot, to: url)
        }
    }

    /// #623: the gizmo with LightGizmoHitTest's regions over it in the iOS
    /// profile (slop 14, every target hit within at least 22 pt; handles 44
    /// pt apart): knobs in their identity colours, the aim dot white, the
    /// handles yellow, the ring lines cyan (both rings pink). At the test
    /// size and at a phone size.
    func testRenderIOSHitRegions() throws {
        let metrics = LightGizmoMetrics(slop: 14, minimumTarget: 44)
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, size) in [("hit_regions_ios44_gizmo", viewTestSize),
                             ("hit_regions_ios44_gizmo_390x640", CGSize(width: 390, height: 640))] {
            let (store, controller) = viewController()
            let layout = try XCTUnwrap(LightGizmoLayout.make(
                LightGizmoInputs(controller: controller, viewSize: size, gridMode: false, sceneShadowsOn: true),
                metrics: metrics))
            let writes = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)
            let h = OffscreenHost(GizmoHitRegions(layout: layout).frame(width: size.width, height: size.height),
                                  size: size)
            hosts.append(h)
            let rep = try XCTUnwrap(h.bitmap(), "\(name): no bitmap")
            XCTAssertFalse(OffscreenHost.isFlat(rep), "\(name): the picture is one flat colour")
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = dir.appendingPathComponent("gizmo_\(name).png")
            try png.write(to: url)
            NSLog("LIGHTGIZMO_SNAPSHOT: \(url.path)")
            h.close()
            XCTAssertEqual(store.numberWrites.count, writes.0, "\(name): drawing wrote a number")
            XCTAssertEqual(store.vectorWrites.count, writes.1, "\(name): drawing wrote a vector")
            XCTAssertEqual(store.performed.count, writes.2, "\(name): drawing ran an action")
        }
    }

    /// The key's knob pressed and dragged out past the band to the left, the
    /// session kept open (mid-drag), the UI state tracking it.
    private static func dragKeyOut(_ controller: LightsController, ui: LightGizmoUIState, size: CGSize) throws {
        let l = try XCTUnwrap(viewLayout(controller, size: size))
        let key = try XCTUnwrap(l.knob(named: "key"))
        let interaction = LightGizmoInteraction(controller: controller)
        var session = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        let out = CGPoint(x: l.centre.x - l.bandRadius - 12, y: l.centre.y - 30)
        for k in 1...12 {
            let f = CGFloat(k) / 12
            interaction.move(&session, to: CGPoint(x: key.centre.x + (out.x - key.centre.x) * f,
                                                   y: key.centre.y + (out.y - key.centre.y) * f))
        }
        XCTAssertEqual(session.isBehind, true, "the band flipped the knob")
        ui.track(session, layout: viewLayout(controller, size: size))
        XCTAssertNotNil(ui.readout)
    }

    private func render(_ shot: Shot, to url: URL) throws {
        let store = FakeRigStore()
        shot.setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        controller.begin()
        let ui = LightGizmoUIState()
        try shot.after(controller, store, ui, shot.size)
        XCTAssertNotNil(viewLayout(controller, size: shot.size, shadowsOn: shot.shadowsOn),
                        "\(shot.name): the gizmo is hidden")
        let writes = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)

        // A dark viewport; with a letterbox, the scene rect a shade lighter.
        let projection = LightGizmoProjection(camera: try XCTUnwrap(store.projection), viewSize: shot.size)
        let rect = projection?.sceneRect ?? CGRect(origin: .zero, size: shot.size)
        let backdrop = AnyView(ZStack(alignment: .topLeading) {
            Color(white: 0.04)
            Color(white: 0.12).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
        })
        let h = OffscreenHost(overlayRoot(controller, ui: ui, size: shot.size, shadowsOn: shot.shadowsOn,
                                          backdrop: backdrop), size: shot.size)
        hosts.append(h)
        let rep = try XCTUnwrap(h.bitmap(), "\(shot.name): no bitmap")
        XCTAssertFalse(OffscreenHost.isFlat(rep), "\(shot.name): the picture is one flat colour")
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        NSLog("LIGHTGIZMO_SNAPSHOT: \(url.path)")
        h.close()

        XCTAssertEqual(store.numberWrites.count, writes.0,
                       "\(shot.name): drawing wrote \(store.numberWrites.dropFirst(writes.0))")
        XCTAssertEqual(store.vectorWrites.count, writes.1, "\(shot.name): drawing wrote a vector")
        XCTAssertEqual(store.performed.count, writes.2, "\(shot.name): drawing ran an action")
    }
}

/// The gizmo as the overlay draws it, over a dark backdrop, with what
/// LightGizmoHitTest returns at every other point tinted over it.
private struct GizmoHitRegions: View {
    var layout: LightGizmoLayout

    var body: some View {
        let layout = layout
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.08)))
            LightGizmoPainter(layout: layout, ui: LightGizmoUIState.Values()).draw(in: &context)
            for y in stride(from: CGFloat(0), to: size.height, by: 2) {
                for x in stride(from: CGFloat(0), to: size.width, by: 2) {
                    let colour: Color
                    switch LightGizmoHitTest.target(at: CGPoint(x: x + 1, y: y + 1), layout: layout) {
                    case .knob(let name)?:
                        colour = LightPalette.color(layout.knob(named: name)?.slot ?? 0)
                    case .aimDot?: colour = .white
                    case .outerHandle?, .innerHandle?: colour = .yellow
                    case .outerRing?, .innerRing?: colour = .cyan
                    case .rings?: colour = .pink
                    case nil: continue
                    }
                    context.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(colour.opacity(0.35)))
                }
            }
        }
    }
}

// MARK: - Composites over the live Metal render

/// The live Metal render (`renderHiResPNG`, at the overlay's size) under the
/// overlay, drawn offscreen: before and after a knob drag that flips the key
/// across the band, and after a beam-ring drag. The key's `outline` is on, so
/// the rings can be compared with the footprint the renderer paints. PNGs go
/// to $RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR (else a temporary directory).
@MainActor
final class LightGizmoCompositeTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }
    private var interaction: LightGizmoInteraction {
        LightGizmoInteraction(controller: controller, picker: engine.lightGizmoPicker)
    }
    private let size = CGSize(width: 800, height: 600)
    private var sceneBuilt = false
    private var hosts: [OffscreenHost] = []

    /// SurfacePickTests' pinned camera: the eye at z = +100 looking down -z
    /// at the origin, perspective, field_of_view 20.
    private static let pinnedView =
        "(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, "
        + "0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 50.0, 150.0, -20.0)"

    override func setUp() {
        super.setUp()
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        engine.setBinderDesignMode(false)
    }

    override func tearDown() {
        hosts.forEach { $0.close() }
        hosts = []
        if sceneBuilt {
            engine.setInteractionMode(.viewing)
            engine.runPython(
                "from pymol import cmd as _lgc_c\n"
                + "for _k, _v in globals().pop('_lgc_saved', {}).items():\n"
                + "    _lgc_c.set(_k, _v)\n"
                + "for _n in globals().pop('_lgc_enabled', []):\n"
                + "    _lgc_c.enable(_n)\n")
            sceneBuilt = false
        }
        LightsLive.tearDown()
        super.tearDown()
    }

    /// The fab peptide as spheres at the origin, other objects hidden, the
    /// pinned camera, and a rig whose key (selected) paints its outline.
    private func buildScene() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        sceneBuilt = true
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "if '_lgc_saved' not in globals():\n"
            + "    _lgc_saved = {_k: _c.get(_k) for _k in ('orthoscopic', 'field_of_view')}\n"
            + "    _lgc_enabled = [_n for _n in _c.get_names('objects', enabled_only=1) if _n != 'lmt_pep']\n"
            + "for _n in _lgc_enabled:\n"
            + "    _c.disable(_n)\n"
            + "_c.show_as('spheres', 'lmt_pep')\n"
            + "_e = _c.get_extent('lmt_pep')\n"
            + "_c.translate([-(_e[0][i] + _e[1][i]) / 2.0 for i in range(3)],\n"
            + "             selection='lmt_pep', camera=0)\n"
            + "_c.set('orthoscopic', 0)\n"
            + "_c.set_view(\(Self.pinnedView))\n")
        _ = try XCTUnwrap(LightsLive.setRig("""
            {'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 10.0, 'ambient': 0.15, 'classic': 0.2,
             'lights': [
               {'name': 'key', 'orbit': -40.0, 'pitch': 25.0, 'radius': 2.0, 'beam': 30.0,
                'softness': 0.3, 'outline': True},
               {'name': 'fill', 'orbit': 55.0, 'pitch': 10.0, 'radius': 2.5, 'intensity': 0.5},
               {'name': 'rim', 'orbit': 160.0, 'pitch': 20.0, 'radius': 3.0}]}
            """))
        XCTAssertGreaterThan(engine.prepareSurfacePick(updateReps: true), 0, "no pick grid was built")
        engine.setInteractionMode(.lights)
        controller.select(name: "key")
        engine.lightsFrameRendered()
    }

    private func layout() throws -> LightGizmoLayout {
        try XCTUnwrap(engine.lightGizmoLayout(viewSize: size), "the gizmo is hidden")
    }

    /// The Metal frame at the overlay's size with the overlay over it, saved
    /// as `<name>.png`.
    @discardableResult
    private func composite(_ name: String) throws -> NSBitmapImageRep {
        engine.lightsFrameRendered()
        let png = NSTemporaryDirectory() + "lgc_\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Int(size.width), height: Int(size.height), rayTraced: 0)
        let image = try XCTUnwrap(NSImage(contentsOfFile: png), "no frame rendered (is there a Metal renderer?)")
        let ui = LightGizmoUIState()
        let backdrop = AnyView(Image(nsImage: image).resizable().frame(width: size.width, height: size.height))
        let h = OffscreenHost(overlayRoot(controller, ui: ui, size: size, shadowsOn: engine.sceneShadowsOn,
                                          backdrop: backdrop), size: size)
        hosts.append(h)
        let rep = try XCTUnwrap(h.bitmap(), "\(name): no bitmap")
        XCTAssertFalse(OffscreenHost.isFlat(rep), "\(name): one flat colour")
        let dir = LightGizmoSnapshotTests.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("composite_\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        NSLog("LIGHTGIZMO_SNAPSHOT: \(url.path)")
        h.close()
        return rep
    }

    private func drag(_ session: inout LightGizmoDragSession, from: CGPoint, to: CGPoint) -> [LightSetResult] {
        var results: [LightSetResult] = []
        for k in 1...12 {
            let f = CGFloat(k) / 12
            if let r = interaction.move(&session, to: CGPoint(x: from.x + (to.x - from.x) * f,
                                                              y: from.y + (to.y - from.y) * f)) {
                results.append(r)
            }
            engine.lightsFrameRendered()
        }
        return results
    }

    func testCompositesBeforeAndAfterAFlipAndABeamDrag() throws {
        try buildScene()
        try composite("01_key_selected")

        // The key out past the band: it turns into a rim light (behind).
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        XCTAssertFalse(key.isBehind)
        var knob = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        let v = CGVector(dx: key.centre.x - l.centre.x, dy: key.centre.y - l.centre.y)
        let length = hypot(v.dx, v.dy)
        let out = CGPoint(x: l.centre.x + v.dx / length * (l.bandRadius + 10),
                          y: l.centre.y + v.dy / length * (l.bandRadius + 10))
        let flips = drag(&knob, from: key.centre, to: out)
        XCTAssertFalse(flips.isEmpty)
        XCTAssertTrue(flips.allSatisfy { $0 == .ok })
        XCTAssertTrue(controller.isBehind("key"), "the band flipped the key behind the molecule")
        try composite("02_after_band_flip")

        // The beam: the outer ring dragged outwards from a point clear of the
        // other targets.
        let l2 = try layout()
        let s = try XCTUnwrap(l2.selected)
        let ring = try XCTUnwrap(s.outerRing)
        let aim = try XCTUnwrap(s.aimDot)
        let press = try XCTUnwrap(ring.samples.compactMap { $0 }.first {
            LightGizmoHitTest.target(at: $0, layout: l2) == .outerRing
        }, "no clear point on the outer ring")
        let beamBefore = try XCTUnwrap(controller.value(.beam))
        var beam = try XCTUnwrap(interaction.press(at: press, layout: l2))
        let to = CGPoint(x: aim.x + (press.x - aim.x) * 1.4, y: aim.y + (press.y - aim.y) * 1.4)
        let widened = drag(&beam, from: press, to: to)
        XCTAssertFalse(widened.isEmpty)
        XCTAssertTrue(widened.allSatisfy { $0 == .ok })
        XCTAssertGreaterThan(try XCTUnwrap(controller.value(.beam)), beamBefore, "the beam widened")
        try composite("03_after_beam_drag")
    }
}
