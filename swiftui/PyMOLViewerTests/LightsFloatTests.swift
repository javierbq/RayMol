import AppKit
import SwiftUI
import XCTest
@testable import RayMol

/// The iPad's floating orbit view of #623 (LightsFloatingTools.swift): the
/// corner and its raw values, the drop rule, the clearances from the
/// viewport's bottom chrome, the cards' frames and their stacking, the knobs
/// the cards cover (the default three_point knobs stay free at the default
/// panel sizes), the VoiceOver strings, the metrics against the rendered
/// cards, and pictures of the four corners drawn offscreen over the gizmo
/// with a controller on fake seams (FakeRigStore, in
/// LightsControllerTests.swift), in the iOS touch profile.

/// The default iPad viewports the knob check runs at, as the `LightsLayout:`
/// line and the plan measured them (Lights mode, default panels): the 13-inch
/// iPad Pro simulator in portrait (the ticket's), the 11-inch in portrait and
/// landscape, and the mini in portrait.
let lightsFloatDefaultViewports: [(name: String, size: CGSize)] = [
    ("ipad13_portrait", CGSize(width: 1032, height: 602)),
    ("ipad11_portrait", CGSize(width: 834, height: 560)),
    ("ipad11_landscape", CGSize(width: 754, height: 574)),
    ("ipadmini_portrait", CGSize(width: 744, height: 520)),
]

/// The bottom-leading chrome with objects loaded: the 46 pt camera button
/// with its 12 pt bottom padding (ContentView.bottomLeadingViewportChrome).
let lightsFloatCameraChrome = ViewportChromeHeights(bottomLeading: 46 + 12, dock: 0)

/// three_point's placements (lighting_commands.three_point): key -45/+35,
/// fill 55/+5, rim 165/+40.
func lightsFloatThreePoint(_ store: FakeRigStore) {
    store.setRig(["key", "fill", "rim"])
    for (i, (o, p)) in [(-45.0, 35.0), (55.0, 5.0), (165.0, 40.0)].enumerated() {
        store.lights[i].orbit = o
        store.lights[i].pitch = p
        store.lights[i].radius = 3
    }
    store.lights[0].shadow = true
    store.lights[0].beam = 40
}

/// A camera close enough that the display sphere is at its maximum (0.42 of
/// the view's shorter side), where the knobs reach farthest from the centre.
func lightsFloatCloseCamera(_ store: FakeRigStore) {
    store.eyeOffset = SIMD3(0, 0, -40)
    store.projection = LightCameraProjection(orthoscopic: false, fovDegrees: 20, cameraDistance: 40,
                                             letterboxAspect: 0)
}

// MARK: - Corner and layout

@MainActor
final class LightsFloatLayoutTests: XCTestCase {
    typealias L = LightsFloatLayout
    typealias M = LightsFloatMetrics

    func testCornerRawValuesAndFlags() {
        XCTAssertEqual(LightsFloatCorner.allCases.map(\.rawValue), ["tl", "tr", "bl", "br"])
        XCTAssertEqual(LightsFloatCorner.default, .bottomLeading)
        XCTAssertEqual(LightsFloatCorner.allCases.map(\.isTrailing), [false, true, false, true])
        XCTAssertEqual(LightsFloatCorner.allCases.map(\.isBottom), [false, false, true, true])
        XCTAssertEqual(LightsFloatCorner.allCases.map(\.alignment),
                       [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing])
        for corner in LightsFloatCorner.allCases {
            XCTAssertEqual(LightsFloatCorner(trailing: corner.isTrailing, bottom: corner.isBottom), corner)
            XCTAssertEqual(LightsFloatCorner.stored(corner.rawValue), corner)
        }
        XCTAssertEqual(LightsFloatCorner.stored(""), .bottomLeading, "absent: the default")
        XCTAssertEqual(LightsFloatCorner.stored("BL"), .bottomLeading, "unknown: the default")
    }

    func testNearestCornerByQuadrant() {
        let size = CGSize(width: 800, height: 600)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 10, y: 10), in: size), .topLeading)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 799, y: 10), in: size), .topTrailing)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 10, y: 599), in: size), .bottomLeading)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 799, y: 599), in: size), .bottomTrailing)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 399, y: 299), in: size), .topLeading)
        XCTAssertEqual(L.nearest(to: CGPoint(x: 400, y: 300), in: size), .bottomTrailing, "the centre lines")
        XCTAssertEqual(L.nearest(to: CGPoint(x: -50, y: 900), in: size), .bottomLeading, "past the edges")
    }

    func testDropCornerFollowsThePredictedEnd() {
        let size = CGSize(width: 834, height: 560)
        let card = L.frames(corner: .bottomLeading, container: size, inspectorCollapsed: true,
                            chrome: lightsFloatCameraChrome).card
        // A short drag stays in its corner.
        XCTAssertEqual(L.dropCorner(cardFrame: card, translation: CGSize(width: 60, height: -40),
                                    predicted: CGSize(width: 70, height: -50), container: size), .bottomLeading)
        // Dragged past the middle: the corner it is over.
        XCTAssertEqual(L.dropCorner(cardFrame: card, translation: CGSize(width: 400, height: -300),
                                    predicted: nil, container: size), .topTrailing)
        // A fling: a short drag whose predicted end is far throws the card.
        XCTAssertEqual(L.dropCorner(cardFrame: card, translation: CGSize(width: 40, height: 0),
                                    predicted: CGSize(width: 600, height: 0), container: size), .bottomTrailing)
        XCTAssertEqual(L.dropCorner(cardFrame: card, translation: CGSize(width: 0, height: -30),
                                    predicted: CGSize(width: 0, height: -500), container: size), .topLeading)
        // A non-finite prediction falls back to the drag.
        XCTAssertEqual(L.dropCorner(cardFrame: card, translation: CGSize(width: 500, height: 0),
                                    predicted: CGSize(width: CGFloat.nan, height: 0), container: size),
                       .bottomTrailing)
    }

    func testClearancesFromTheBottomChrome() {
        let none = ViewportChromeHeights()
        XCTAssertEqual(L.bottomClearance(trailing: true, chrome: none), M.helpButtonClearance)
        XCTAssertEqual(L.bottomClearance(trailing: false, chrome: none), 0, "no camera button without objects")
        XCTAssertEqual(L.bottomClearance(trailing: false, chrome: lightsFloatCameraChrome), 58 + M.chromeGap)
        XCTAssertEqual(L.bottomClearance(trailing: true, chrome: lightsFloatCameraChrome), M.helpButtonClearance)
        // An open CameraDock (full width) pushes both sides above it.
        let dock = ViewportChromeHeights(bottomLeading: 58, dock: 132)
        XCTAssertEqual(L.bottomClearance(trailing: true, chrome: dock), 132)
        XCTAssertEqual(L.bottomClearance(trailing: false, chrome: dock), 132)
        let lowDock = ViewportChromeHeights(bottomLeading: 58, dock: 30)
        XCTAssertEqual(L.bottomClearance(trailing: true, chrome: lowDock), M.helpButtonClearance)
        XCTAssertEqual(L.bottomClearance(trailing: false, chrome: lowDock), 66)
        for corner in LightsFloatCorner.allCases {
            XCTAssertEqual(L.bottomClearance(corner: corner, chrome: dock),
                           L.bottomClearance(trailing: corner.isTrailing, chrome: dock))
        }
        // The help button (26 pt glyph, 12 pt padding) fits under the inset
        // plus the clearance.
        XCTAssertGreaterThanOrEqual(M.inset + M.helpButtonClearance, 26 + 2 * 12)
    }

    func testFramesForEachCorner() {
        let size = CGSize(width: 834, height: 560)
        let card = M.orbitCardSize
        let w = LightsInspector.width
        let chrome = lightsFloatCameraChrome
        // bl: the card above the camera button; the inspector's header
        // top-trailing.
        var f = L.frames(corner: .bottomLeading, container: size, inspectorCollapsed: true, chrome: chrome)
        XCTAssertEqual(f.card, CGRect(x: 8, y: 560 - 8 - 66 - card.height, width: card.width, height: card.height))
        XCTAssertEqual(f.inspector, CGRect(x: 834 - 8 - w, y: 8, width: w, height: M.inspectorHeaderHeight))
        XCTAssertEqual(f.all, [f.card, f.inspector])
        // #673: the "No casters" line grows the collapsed inspector.
        let h = L.frames(corner: .bottomLeading, container: size, inspectorCollapsed: true, chrome: chrome,
                         inspectorHintLines: 1)
        XCTAssertEqual(h.inspector.height, M.inspectorHeaderHeight + M.inspectorHintHeight)
        // tl: top-leading, beside the inspector.
        f = L.frames(corner: .topLeading, container: size, inspectorCollapsed: true, chrome: chrome)
        XCTAssertEqual(f.card.origin, CGPoint(x: 8, y: 8))
        XCTAssertFalse(f.card.intersects(f.inspector))
        // tr: the card on top, the inspector stacked under it, scrolling in
        // the rest of the column down to the help button (#889: no
        // Atmosphere card under it).
        f = L.frames(corner: .topTrailing, container: size, inspectorCollapsed: false, chrome: chrome)
        XCTAssertEqual(f.card.origin, CGPoint(x: 834 - 8 - card.width, y: 8))
        XCTAssertEqual(f.inspector.minY, f.card.maxY + M.gap)
        XCTAssertEqual(f.inspector.maxY, 560 - 8 - M.helpButtonClearance, accuracy: 1e-9,
                       "expanded: it scrolls in the rest, above the help button")
        // br: the inspector on top, the card above the help button.
        f = L.frames(corner: .bottomTrailing, container: size, inspectorCollapsed: false, chrome: chrome)
        XCTAssertEqual(f.card.maxY, 560 - 8 - M.helpButtonClearance)
        XCTAssertEqual(f.inspector.minY, 8)
        XCTAssertEqual(f.inspector.maxY, f.card.minY - M.gap, accuracy: 1e-9)
        // A short inspector keeps its content height.
        f = L.frames(corner: .bottomLeading, container: size, inspectorCollapsed: false, chrome: chrome,
                     inspectorHeight: 200)
        XCTAssertEqual(f.inspector.height, 200)
        // Every corner keeps both cards inside the viewport and apart.
        for corner in LightsFloatCorner.allCases {
            for collapsed in [true, false] {
                let f = L.frames(corner: corner, container: size, inspectorCollapsed: collapsed, chrome: chrome)
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
                XCTAssertTrue(bounds.contains(f.card), "\(corner)")
                XCTAssertTrue(bounds.contains(f.inspector), "\(corner)")
                XCTAssertFalse(f.card.intersects(f.inspector), "\(corner) collapsed=\(collapsed)")
            }
        }
    }

    /// No light: no orbit card and no inspector (both `.zero`, no room or
    /// gap left for them).
    func testFramesWithoutTheOrbitCard() {
        let size = CGSize(width: 834, height: 560)
        for corner in LightsFloatCorner.allCases {
            let f = L.frames(corner: corner, container: size, inspectorCollapsed: true,
                             chrome: lightsFloatCameraChrome, showsCard: false, showsInspector: false)
            XCTAssertEqual(f.card, .zero, "\(corner)")
            XCTAssertEqual(f.inspector, .zero, "\(corner)")
        }
        // A card without an inspector (no selected light).
        let f = L.frames(corner: .topTrailing, container: size, inspectorCollapsed: true,
                         chrome: lightsFloatCameraChrome, showsInspector: false)
        XCTAssertEqual(f.inspector, .zero)
        XCTAssertNotEqual(f.card, .zero)
        // An inspector without a card takes the top inset in every corner.
        for corner in LightsFloatCorner.allCases {
            let f = L.frames(corner: corner, container: size, inspectorCollapsed: true,
                             chrome: lightsFloatCameraChrome, showsCard: false)
            XCTAssertEqual(f.inspector.minY, 8, "\(corner)")
        }
    }

    func testAnOpenDockLiftsTheCard() {
        let size = CGSize(width: 834, height: 560)
        let dock = ViewportChromeHeights(bottomLeading: 58, dock: 132)
        for corner in [LightsFloatCorner.bottomLeading, .bottomTrailing] {
            let f = L.frames(corner: corner, container: size, inspectorCollapsed: true, chrome: dock)
            XCTAssertEqual(f.card.maxY, 560 - 8 - 132, "\(corner)")
        }
    }

    /// #718: an open CameraDock collapses the orbit card on short viewports,
    /// keeping the key knob free while still resting on the dock.
    func testAnOpenDockCollapsesTheCardOnShortViewports() throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        lightsFloatCloseCamera(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        controller.begin()
        let dock = ViewportChromeHeights(bottomLeading: 58, dock: 132)
        for size in [CGSize(width: 834, height: 560), CGSize(width: 744, height: 520)] {
            let layout = try XCTUnwrap(LightGizmoLayout.make(
                LightGizmoInputs(controller: controller, viewSize: size, gridMode: false, sceneShadowsOn: true),
                metrics: LightGizmoMetrics(slop: 14, minimumTarget: 44)))
            let f = L.frames(corner: .default, container: size, inspectorCollapsed: true, chrome: dock)
            let key = try XCTUnwrap(layout.knobs.first { $0.name == "key" })
            let r = layout.metrics.reach(key.radius)
            let keyRect = CGRect(x: key.centre.x - r, y: key.centre.y - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse(f.card.intersects(keyRect), "\(size): card covers key knob")
            XCTAssertEqual(L.coveredKnobs(layout: layout, frames: f.all), [], "\(size)")
            XCTAssertEqual(f.card.maxY, size.height - 8 - 132, accuracy: 1e-9, "\(size)")
        }
    }

    /// #718: the pure dock collapse rule and its effect on frames.
    func testTheDockCollapseRule() {
        let dock = ViewportChromeHeights(bottomLeading: 58, dock: 132)
        for size in [CGSize(width: 834, height: 560), CGSize(width: 744, height: 520)] {
            for corner in [LightsFloatCorner.bottomLeading, .bottomTrailing] {
                XCTAssertTrue(L.dockCollapsesCard(corner: corner, container: size, chrome: dock),
                              "\(size) \(corner)")
                let f = L.frames(corner: corner, container: size, inspectorCollapsed: true, chrome: dock)
                XCTAssertEqual(f.card.height, M.orbitCardCollapsedHeight, "\(size) \(corner)")
            }
            for corner in [LightsFloatCorner.topLeading, .topTrailing] {
                XCTAssertFalse(L.dockCollapsesCard(corner: corner, container: size, chrome: dock),
                               "\(size) \(corner)")
                let f = L.frames(corner: corner, container: size, inspectorCollapsed: true, chrome: dock)
                XCTAssertEqual(f.card.height, M.orbitCardSize.height, "\(size) \(corner)")
            }

            for corner in LightsFloatCorner.allCases {
                XCTAssertFalse(L.dockCollapsesCard(corner: corner, container: size,
                                                   chrome: lightsFloatCameraChrome),
                               "\(size) \(corner)")
                let f = L.frames(corner: corner, container: size, inspectorCollapsed: true,
                                 chrome: lightsFloatCameraChrome)
                XCTAssertEqual(f.card.height, M.orbitCardSize.height, "\(size) \(corner)")
            }
            let blClosed = L.frames(corner: .bottomLeading, container: size, inspectorCollapsed: true,
                                    chrome: lightsFloatCameraChrome)
            XCTAssertEqual(blClosed.card.origin,
                           CGPoint(x: 8, y: size.height - 8 - 66 - 252),
                           "\(size) today's layout")
        }

        let tallSize = CGSize(width: 1180, height: 760)
        XCTAssertFalse(L.dockCollapsesCard(corner: .bottomLeading, container: tallSize, chrome: dock))
        let tallFrames = L.frames(corner: .bottomLeading, container: tallSize, inspectorCollapsed: true,
                                  chrome: dock)
        XCTAssertEqual(tallFrames.card.height, 252)
        XCTAssertEqual(tallFrames.card.maxY, 760 - 8 - 132, accuracy: 1e-9)

        let lowDock = ViewportChromeHeights(bottomLeading: 58, dock: 30)
        XCTAssertFalse(L.dockCollapsesCard(corner: .bottomLeading, container: CGSize(width: 744, height: 520),
                                           chrome: lowDock))

        XCTAssertFalse(L.dockCollapsesCard(corner: .bottomLeading, container: .zero, chrome: dock))
    }

    func testCoveredKnobsUseTheTouchReach() throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        lightsFloatCloseCamera(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        controller.begin()
        let size = CGSize(width: 834, height: 560)
        let layout = try XCTUnwrap(LightGizmoLayout.make(
            LightGizmoInputs(controller: controller, viewSize: size, gridMode: false, sceneShadowsOn: true),
            metrics: LightGizmoMetrics(slop: 14, minimumTarget: 44)))
        let fill = try XCTUnwrap(layout.knobs.first { $0.name == "fill" })
        XCTAssertEqual(layout.metrics.reach(fill.radius), 22, "iOS: 7 + 14 = 21, floored to 22")
        // A rect 21.5 pt left of the fill's centre covers its target; 22.5 pt does not.
        let near = CGRect(x: fill.centre.x - 21.5 - 100, y: fill.centre.y - 5, width: 100, height: 10)
        let far = near.offsetBy(dx: -1, dy: 0)
        XCTAssertEqual(L.coveredKnobs(layout: layout, frames: [near]), ["fill"])
        XCTAssertEqual(L.coveredKnobs(layout: layout, frames: [far]), [])
        XCTAssertEqual(L.coveredKnobs(layout: nil, frames: [near]), [], "no gizmo, nothing covered")
        XCTAssertEqual(L.coveredSummary([]), "none")
        XCTAssertEqual(L.coveredSummary(["key", "fill"]), "key,fill")
        XCTAssertFalse(L.overlaps(.zero, centre: .zero, radius: 10), "an empty frame covers nothing")
    }

    /// #692's iPad case: with the float's defaults (the card bottom-leading,
    /// the inspector collapsed top-trailing), every default three_point knob
    /// and its whole 44 pt target stay outside both cards at each default
    /// viewport, with the display sphere at its maximum. sketch 4's
    /// bottom-trailing card with the inspector expanded covers the fill knob.
    func testDefaultPlacementLeavesThreePointKnobsFree() throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        lightsFloatCloseCamera(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        controller.begin()
        for (name, size) in lightsFloatDefaultViewports {
            let layout = try XCTUnwrap(LightGizmoLayout.make(
                LightGizmoInputs(controller: controller, viewSize: size, gridMode: false, sceneShadowsOn: true),
                metrics: LightGizmoMetrics(slop: 14, minimumTarget: 44)), name)
            XCTAssertEqual(layout.sphereRadius, 0.42 * min(size.width, size.height), accuracy: 1e-6,
                           "\(name): the sphere at its maximum")
            XCTAssertEqual(layout.knobs.map(\.name), ["key", "fill", "rim"])
            let defaults = L.frames(corner: .default, container: size, inspectorCollapsed: true,
                                    chrome: lightsFloatCameraChrome)
            XCTAssertEqual(defaults.all.count, 2)
            XCTAssertEqual(L.coveredKnobs(layout: layout, frames: defaults.all), [], name)
            // #718: an open CameraDock auto-collapses the orbit card where it
            // would reach the key knob on short viewports, so every default
            // knob stays free.
            let docked = L.frames(corner: .default, container: size, inspectorCollapsed: true,
                                  chrome: ViewportChromeHeights(bottomLeading: 58, dock: 132))
            XCTAssertEqual(L.coveredKnobs(layout: layout, frames: docked.all), [],
                           "\(name): open dock covers a knob")
            // Every knob stays inside the view (none hides off-screen either).
            for knob in layout.knobs {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(knob.centre), "\(name) \(knob.name)")
            }
        }
        // Why not sketch 4's corner: at the 11-inch portrait viewport the
        // bottom-trailing card and the expanded inspector cover the fill knob.
        let size = CGSize(width: 834, height: 560)
        let layout = try XCTUnwrap(LightGizmoLayout.make(
            LightGizmoInputs(controller: controller, viewSize: size, gridMode: false, sceneShadowsOn: true),
            metrics: LightGizmoMetrics(slop: 14, minimumTarget: 44)))
        let sketch = L.frames(corner: .bottomTrailing, container: size, inspectorCollapsed: false,
                              chrome: lightsFloatCameraChrome)
        XCTAssertTrue(L.coveredKnobs(layout: layout, frames: sketch.all).contains("fill"))
    }

    /// The metrics are the cards as the float draws them on iOS (44 pt
    /// targets): the expanded orbit card and the inspector collapsed to its
    /// header.
    func testMetricsMatchTheRenderedCards() throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let card = NSHostingView(rootView: LightsOrbitView(controller: controller, style: style)
            .environment(\.lightsTouchMinimum, 44))
        XCTAssertEqual(card.fittingSize.width, M.orbitCardSize.width, accuracy: 0.5)
        XCTAssertEqual(card.fittingSize.height, M.orbitCardSize.height, accuracy: 0.5)
        let header = NSHostingView(rootView: LightsInspector(controller: controller, style: style,
                                                             initiallyCollapsed: true, sceneShadowsOn: true)
            .environment(\.lightsTouchMinimum, 44))
        XCTAssertEqual(header.fittingSize.width, LightsInspector.width, accuracy: 0.5)
        XCTAssertEqual(header.fittingSize.height, M.inspectorHeaderHeight, accuracy: 0.5)
        // The grip changes neither size.
        let gripped = NSHostingView(rootView: LightsOrbitView(
            controller: controller, style: style,
            grip: LightsOrbitGrip(gesture: AnyGesture(DragGesture().map { _ in () }), label: "", value: "",
                                  hint: "", identifier: "", actions: []))
            .environment(\.lightsTouchMinimum, 44))
        XCTAssertEqual(gripped.fittingSize.height, M.orbitCardSize.height, accuracy: 0.5)

        // #718: initially collapsed and dock-collapsed cards match the collapsed height.
        let collapsed = NSHostingView(rootView: LightsOrbitView(
            controller: controller, style: style, initiallyCollapsed: true)
            .environment(\.lightsTouchMinimum, 44))
        XCTAssertEqual(collapsed.fittingSize.width, M.orbitCardSize.width, accuracy: 0.5)
        XCTAssertEqual(collapsed.fittingSize.height, M.orbitCardCollapsedHeight, accuracy: 0.5)

        let dockCollapsed = NSHostingView(rootView: LightsOrbitView(
            controller: controller, style: style, dockCollapsed: true)
            .environment(\.lightsTouchMinimum, 44))
        XCTAssertEqual(dockCollapsed.fittingSize.width, M.orbitCardSize.width, accuracy: 0.5)
        XCTAssertEqual(dockCollapsed.fittingSize.height, M.orbitCardCollapsedHeight, accuracy: 0.5)
    }

}

// MARK: - The card's frame during a drag

/// The card's reported frame is its laid-out frame while the grip's drag
/// offsets it (`lightsFloatCard(offset:space:)`), so the drop adds the drag
/// once: a GeometryReader inside `.offset` reports the moved frame, and the
/// drop then counted the drag twice (a card dragged a quarter of the way up
/// snapped to the top) while the frames changed on every drag tick.
@MainActor
final class LightsFloatCardFrameTests: XCTestCase {
    final class Reported {
        var frames: [String: CGRect] = [:]
    }

    private struct Host: View {
        let offset: CGSize
        let reported: Reported

        var body: some View {
            ZStack {
                Color.gray.frame(width: 284, height: 252)
                    .lightsFloatCard(offset: offset, space: "float")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
            }
            .frame(width: 834, height: 560)
            .coordinateSpace(name: "float")
            .onPreferenceChange(LightsFloatFramesKey.self) { reported.frames = $0 }
        }
    }

    private func reportedCard(offset: CGSize) throws -> CGRect {
        let reported = Reported()
        let host = NSHostingView(rootView: Host(offset: offset, reported: reported))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 834, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(reported.frames["card"], "no card frame reported")
    }

    func testTheReportedFrameIgnoresTheDragOffset() throws {
        let rest = try reportedCard(offset: .zero)
        XCTAssertEqual(rest.minX, 8, accuracy: 0.5)
        XCTAssertEqual(rest.maxY, 552, accuracy: 0.5)
        let dragged = try reportedCard(offset: CGSize(width: 120, height: -150))
        XCTAssertEqual(dragged.minX, rest.minX, accuracy: 0.5, "the frame followed the drag")
        XCTAssertEqual(dragged.minY, rest.minY, accuracy: 0.5, "the frame followed the drag")
    }

    func testAQuarterDragUpStaysInItsCorner() throws {
        // The card's centre is at y 426 of 560; 100 pt up leaves it below
        // the middle (280), so the drop keeps bottom-leading.
        let drag = CGSize(width: 0, height: -100)
        let card = try reportedCard(offset: drag)
        XCTAssertEqual(LightsFloatLayout.dropCorner(cardFrame: card, translation: drag, predicted: drag,
                                                    container: CGSize(width: 834, height: 560)),
                       .bottomLeading)
    }
}

// MARK: - Strings

final class LightsFloatStateTests: XCTestCase {
    func testGripStrings() {
        XCTAssertEqual(LightsFloatState.identifier, "lights.float")
        XCTAssertEqual(LightsFloatState.gripIdentifier, "lights.float.grip")
        XCTAssertEqual(LightsFloatState.gripLabel, "Orbit view position")
        XCTAssertEqual(LightsFloatCorner.allCases.map(\.spokenName),
                       ["top left", "top right", "bottom left", "bottom right"])
        XCTAssertEqual(LightsFloatState.gripValue(.bottomLeading), "bottom left")
        XCTAssertEqual(LightsFloatState.moveActionName(.topTrailing), "Move to top right")
    }

    func testMoveActionsNameTheOtherCorners() {
        for corner in LightsFloatCorner.allCases {
            let targets = LightsFloatState.moveTargets(from: corner)
            XCTAssertEqual(targets.count, 3)
            XCTAssertFalse(targets.contains(corner))
            XCTAssertEqual(Set(targets + [corner]), Set(LightsFloatCorner.allCases))
        }
        XCTAssertEqual(LightsFloatState.moveTargets(from: .bottomLeading).map(LightsFloatState.moveActionName),
                       ["Move to top left", "Move to top right", "Move to bottom right"])
    }

    func testTheCornerTokenParses() {
        XCTAssertEqual(LightsAutoEdit.parse("corner:tl").corner, .topLeading)
        XCTAssertEqual(LightsAutoEdit.parse("corner:BR;orbit:10").corner, .bottomTrailing)
        XCTAssertEqual(LightsAutoEdit.parse("corner:tl;corner:tr").corner, .topTrailing, "the last one wins")
        XCTAssertNil(LightsAutoEdit.parse("expand").corner)
        XCTAssertEqual(LightsAutoEdit.parse("corner:xx").rejected, ["corner:xx"])
        XCTAssertEqual(LightsAutoEdit.parse("corner").rejected, ["corner"])
    }

    @MainActor
    func testTheCornerTokenWritesNothing() {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let entries = LightsAutoEdit.apply(LightsAutoEdit.parse("corner:tr;expand").tokens, to: controller)
        XCTAssertEqual(entries, [], "layout choices log no edit")
        XCTAssertEqual(store.numberWrites.count, 0)
        XCTAssertEqual(store.performed.count, 0)
    }
}

// MARK: - Pictures

/// The float drawn offscreen over the gizmo, as LightsSheetSnapshotTests
/// draws the sheet: an NSHostingView in a borderless window far off any
/// screen, then cacheDisplay into a bitmap (the app's own views drawn into
/// memory, no screen capture), in the iOS touch profile. A dark viewport
/// carries the gizmo (three_point, the sphere at its maximum), a stand-in
/// camera button bottom-leading and the Gesture help glyph bottom-trailing,
/// as ContentView places them. PNGs go to $RAYMOL_LIGHTSFLOAT_SNAPSHOT_DIR
/// (TEST_RUNNER_RAYMOL_LIGHTSFLOAT_SNAPSHOT_DIR on the xcodebuild line), else
/// NSTemporaryDirectory()/raymol-lightsfloat-snapshots; each is logged as
/// `LIGHTSFLOAT_SNAPSHOT: <path>`. The frames the view reports must be the
/// pure layout's, and drawing must write nothing.
@MainActor
final class LightsFloatSnapshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var corner: LightsFloatCorner = .default
        var size: CGSize = CGSize(width: 834, height: 560)
        var inspectorCollapsed = true
        var dark = false
        var chrome = lightsFloatCameraChrome
        var air = FakeRigStore.defaultAir
    }

    /// What the view reported.
    final class Reported {
        var frames: LightsFloatLayout.Frames?
    }

    private static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTSFLOAT_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightsfloat-snapshots", isDirectory: true)
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func testRenderSnapshots() throws {
        var shots: [Shot] = LightsFloatCorner.allCases.map { Shot(name: "corner_\($0.rawValue)_834x560", corner: $0) }
        shots += [
            Shot(name: "default_bl_744x520_mini", size: CGSize(width: 744, height: 520)),
            Shot(name: "default_bl_754x574_landscape", size: CGSize(width: 754, height: 574)),
            Shot(name: "default_bl_1032x602_ipad13", size: CGSize(width: 1032, height: 602)),
            Shot(name: "default_bl_1180x760_dark", size: CGSize(width: 1180, height: 760), dark: true),
            Shot(name: "corner_br_inspector_expanded_834x560", corner: .bottomTrailing, inspectorCollapsed: false),
            Shot(name: "corner_tr_inspector_expanded_834x560", corner: .topTrailing, inspectorCollapsed: false),
            Shot(name: "default_bl_dock_open_834x560",
                 chrome: ViewportChromeHeights(bottomLeading: 58, dock: 132)),
            Shot(name: "default_bl_dock_open_744x520_mini", size: CGSize(width: 744, height: 520),
                 chrome: ViewportChromeHeights(bottomLeading: 58, dock: 132)),
            Shot(name: "default_bl_dock_open_1180x760_tall", size: CGSize(width: 1180, height: 760),
                 chrome: ViewportChromeHeights(bottomLeading: 58, dock: 132)),
            // The air on: nothing in the float changes (#889: the
            // Atmosphere controls are the bar's popover).
            Shot(name: "air_on_834x560", air: atmosphereOnAir),
        ]
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, shot) in shots.enumerated() {
            let url = dir.appendingPathComponent(String(format: "%02d_%@.png", i + 1, shot.name))
            try render(shot, to: url)
        }
    }

    private func render(_ shot: Shot, to url: URL) throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        store.air = shot.air
        lightsFloatCloseCamera(store)
        let controller = LightsController(seams: store.seams)
        controller.eyeDemand = .everyFrame
        controller.begin()
        let writesBefore = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)
        let style = LightsInspectorSnapshotTests.style(dark: shot.dark)
        let reported = Reported()
        let root = FloatHost(controller: controller, style: style, corner: shot.corner,
                             inspectorCollapsed: shot.inspectorCollapsed, chrome: shot.chrome,
                             reported: reported)
            .frame(width: shot.size.width, height: shot.size.height)
            .environment(\.lightsTouchMinimum, 44)
        let size = NSSize(width: shot.size.width, height: shot.size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)

        _ = draw(host, in: window, size: size)
        var rep = draw(host, in: window, size: size)
        if rep.map(Self.isFlat) ?? true {
            window.orderFrontRegardless()
            rep = draw(host, in: window, size: size)
        }
        let bitmap = try XCTUnwrap(rep, "\(shot.name): no bitmap")
        XCTAssertFalse(Self.isFlat(bitmap), "\(shot.name): the picture is one flat colour")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        NSLog("LIGHTSFLOAT_SNAPSHOT: \(url.path)")
        window.orderOut(nil)

        // The view lays the card out where the pure layout says.
        let frames = try XCTUnwrap(reported.frames, "\(shot.name): no frames reported")
        // #673: the key light is shadowed, the scene's Shadows are on (the
        // host) and the fake plan gives it no map, so the inspector shows its
        // "No casters" line under the header, collapsed or not.
        let hintLines = LightsInspectorState(controller, sceneShadowsOn: true)?.showsNoCastersHint == true ? 1 : 0
        XCTAssertEqual(hintLines, 1, "\(shot.name): the casters hint")
        let want = LightsFloatLayout.frames(corner: shot.corner, container: shot.size,
                                            inspectorCollapsed: shot.inspectorCollapsed, chrome: shot.chrome,
                                            inspectorHintLines: hintLines)
        if LightsFloatLayout.dockCollapsesCard(corner: shot.corner, container: shot.size,
                                                               chrome: shot.chrome) {
            XCTAssertEqual(frames.card.height, LightsFloatMetrics.orbitCardCollapsedHeight, accuracy: 0.5,
                           "\(shot.name): the dock collapses the card")
        }
        for (got, expected, what) in [(frames.card, want.card, "card")] {
            XCTAssertEqual(got.minX, expected.minX, accuracy: 0.5, "\(shot.name) \(what)")
            XCTAssertEqual(got.minY, expected.minY, accuracy: 0.5, "\(shot.name) \(what)")
            XCTAssertEqual(got.width, expected.width, accuracy: 0.5, "\(shot.name) \(what)")
            XCTAssertEqual(got.height, expected.height, accuracy: 0.5, "\(shot.name) \(what)")
        }
        XCTAssertEqual(frames.inspector.minX, want.inspector.minX, accuracy: 0.5, "\(shot.name) inspector")
        XCTAssertEqual(frames.inspector.minY, want.inspector.minY, accuracy: 0.5, "\(shot.name) inspector")
        XCTAssertLessThanOrEqual(frames.inspector.maxY, want.inspector.maxY + 0.5, "\(shot.name) inspector")
        if shot.inspectorCollapsed {
            XCTAssertEqual(frames.inspector.height, want.inspector.height, accuracy: 0.5, "\(shot.name)")
        }
        XCTAssertFalse(frames.card.intersects(frames.inspector), "\(shot.name): the cards overlap")

        XCTAssertEqual(store.numberWrites.count, writesBefore.0,
                       "\(shot.name): drawing wrote \(store.numberWrites.dropFirst(writesBefore.0))")
        XCTAssertEqual(store.vectorWrites.count, writesBefore.1, "\(shot.name): drawing wrote a colour")
        XCTAssertEqual(store.performed.count, writesBefore.2,
                       "\(shot.name): drawing pressed \(store.performed.dropFirst(writesBefore.2))")
    }

    /// The viewport as ContentView builds it: the gizmo first, the bottom
    /// chrome, then the float above them.
    private struct FloatHost: View {
        let controller: LightsController
        let style: LightsBarStyle
        @State var corner: LightsFloatCorner
        let inspectorCollapsed: Bool
        let chrome: ViewportChromeHeights
        let reported: Reported
        @StateObject private var ui = LightGizmoUIState()

        var body: some View {
            Color(white: 0.1)
                .overlay {
                    LightGizmoOverlay(controller: controller, ui: ui, style: style, sceneShadowsOn: true)
                }
                .overlay(alignment: .bottomLeading) {
                    Circle().fill(Color(white: 0.85).opacity(0.6))
                        .frame(width: 46, height: 46)
                        .padding(.leading, 12).padding(.bottom, chrome.bottomLeading - 46)
                }
                .overlay(alignment: .bottom) {
                    if chrome.dock > 0 {
                        RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.3))
                            .frame(height: chrome.dock - 12)
                            .padding(.horizontal, 10).padding(.bottom, 12)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(12)
                }
                .overlay {
                    LightsFloatingTools(controller: controller, style: style, corner: $corner, chrome: chrome,
                                        inspectorStartsCollapsed: inspectorCollapsed,
                                        sceneShadowsOn: true,
                                        onFrames: { reported.frames = $0 })
                }
        }
    }

    private func draw(_ host: NSView, in window: NSWindow, size: NSSize) -> NSBitmapImageRep? {
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// At most two colours among the sampled pixels: blank, or a bare fill.
    private static func isFlat(_ rep: NSBitmapImageRep) -> Bool {
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
}

// MARK: - Field focus reporting (#725)

@MainActor
final class LightsFieldFocusReportTests: XCTestCase {
    private class FocusableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class FocusRecorder {
        var values: [Bool] = []
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            return textField
        }
        for subview in view.subviews {
            if let found = findEditableTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    private func checkFieldFocus(named name: String, makeView: (FocusRecorder) -> AnyView) throws {
        let recorder = FocusRecorder()
        let rootView = makeView(recorder)
            .frame(width: 834, height: 1000)
            .environment(\.lightsTouchMinimum, 44)
        let host = NSHostingView(rootView: rootView)
        let window = FocusableWindow(contentRect: NSRect(x: -20000, y: -20000, width: 834, height: 1000),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.orderOut(nil)
        }
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(findEditableTextField(in: host), "\(name): no editable text field found")
        let focused = window.makeFirstResponder(field)
        XCTAssertTrue(focused, "\(name): could not make text field first responder")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.values.last, true, "\(name): onFieldFocus did not report true on focus")

        window.makeFirstResponder(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.values.last, false, "\(name): onFieldFocus did not report false on blur")
    }

    func testEveryPresentationReportsFieldFocus() throws {
        // 1. LightsFloatingTools
        try checkFieldFocus(named: "LightsFloatingTools") { recorder in
            let store = FakeRigStore()
            lightsFloatThreePoint(store)
            let controller = LightsController(seams: store.seams)
            controller.begin()
            let style = LightsInspectorSnapshotTests.style(dark: false)
            return AnyView(LightsFloatingTools(controller: controller,
                                               style: style,
                                               corner: .constant(.bottomLeading),
                                               chrome: lightsFloatCameraChrome,
                                               inspectorStartsCollapsed: false,
                                               onFieldFocus: { recorder.values.append($0) }))
        }

        // 2. LightsSheet .bottom
        try checkFieldFocus(named: "LightsSheet .bottom") { recorder in
            let store = FakeRigStore()
            lightsFloatThreePoint(store)
            let controller = LightsController(seams: store.seams)
            controller.begin()
            let style = LightsInspectorSnapshotTests.style(dark: false)
            let heights = LightsSheetHeights(compact: 100, expanded: 800, compactContent: 600)
            return AnyView(LightsSheet(controller: controller,
                                       style: style,
                                       placement: .bottom,
                                       detent: .constant(.expanded),
                                       heights: heights,
                                       onFieldFocus: { recorder.values.append($0) }))
        }

        // 3. LightsSheet .side
        try checkFieldFocus(named: "LightsSheet .side") { recorder in
            let store = FakeRigStore()
            lightsFloatThreePoint(store)
            let controller = LightsController(seams: store.seams)
            controller.begin()
            let style = LightsInspectorSnapshotTests.style(dark: false)
            let heights = LightsSheetHeights(compact: 0, expanded: 800, compactContent: 0)
            return AnyView(LightsSheet(controller: controller,
                                       style: style,
                                       placement: .side,
                                       detent: .constant(.expanded),
                                       heights: heights,
                                       onFieldFocus: { recorder.values.append($0) }))
        }
    }

    func testTrailingBottomPaddingLiftsAboveTheKeyboard() {
        let clearance: CGFloat = 58
        let gap = LightsFloatMetrics.gap
        // unfocused -> clearance even with an overlap
        XCTAssertEqual(LightsFloatLayout.trailingBottomPadding(clearance: clearance, focused: false, keyboardOverlap: 300), clearance)
        // focused with overlap 0 -> clearance
        XCTAssertEqual(LightsFloatLayout.trailingBottomPadding(clearance: clearance, focused: true, keyboardOverlap: 0), clearance)
        // focused with overlap 300 and clearance 58 -> 300 + gap
        XCTAssertEqual(LightsFloatLayout.trailingBottomPadding(clearance: clearance, focused: true, keyboardOverlap: 300), 300 + gap)
        // focused with overlap 20 and clearance 58 -> 58
        XCTAssertEqual(LightsFloatLayout.trailingBottomPadding(clearance: clearance, focused: true, keyboardOverlap: 20), clearance)
    }

    func testOnlyADockedKeyboardLiftsTheColumn() {
        let screen = CGRect(x: 0, y: 0, width: 1194, height: 834)
        // Docked: reaches the screen's bottom edge.
        XCTAssertTrue(LightsKeyboardDock.isDocked(keyboard: CGRect(x: 0, y: 434, width: 1194, height: 400),
                                                  screen: screen))
        // The floating mini keyboard and an undocked (split) one end above it.
        XCTAssertFalse(LightsKeyboardDock.isDocked(keyboard: CGRect(x: 400, y: 300, width: 320, height: 250),
                                                   screen: screen))
        XCTAssertFalse(LightsKeyboardDock.isDocked(keyboard: CGRect(x: 0, y: 200, width: 1194, height: 400),
                                                   screen: screen))
        // An empty frame (some floating keyboards report one) is no keyboard.
        XCTAssertFalse(LightsKeyboardDock.isDocked(keyboard: .zero, screen: screen))
    }

    func testABottomTrailingCardOnlyTakesTheRoomTheLiftLeaves() {
        let gap = LightsFloatMetrics.gap
        // Unlifted: the card's height and the gap, as before #725.
        XCTAssertEqual(LightsFloatLayout.trailingCardRoom(cardHeight: 252, cardClearance: 58, trailingPadding: 58),
                       252 + gap)
        // Lifted part of the way: only the card's part above the lift.
        XCTAssertEqual(LightsFloatLayout.trailingCardRoom(cardHeight: 252, cardClearance: 58, trailingPadding: 200),
                       58 + 252 + gap - 200)
        // Lifted past the card (it is under the keyboard): no room.
        XCTAssertEqual(LightsFloatLayout.trailingCardRoom(cardHeight: 252, cardClearance: 58, trailingPadding: 400), 0)
    }
}

// MARK: - Inspector focus priority (#870)

@MainActor
final class LightsFloatFocusPriorityTests: XCTestCase {
    private class FocusableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private final class FrameRecorder {
        var frames: LightsFloatLayout.Frames?
    }

    private func findEditableTextFields(in view: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let textField = view as? NSTextField, textField.isEditable {
            result.append(textField)
        }
        for subview in view.subviews {
            result.append(contentsOf: findEditableTextFields(in: subview))
        }
        return result
    }

    func testAShortFocusedColumnRisesToItsMinimum() {
        let minimum = LightsFloatMetrics.focusedColumnMinimum
        // Unfocused, or tall enough: no rise.
        XCTAssertEqual(LightsFloatLayout.focusedColumnRise(available: 100, focused: false, maxRise: 260), 0)
        XCTAssertEqual(LightsFloatLayout.focusedColumnRise(available: minimum + 50, focused: true, maxRise: 260), 0)
        // iPad landscape with the keyboard (~100 pt left): up to the minimum.
        XCTAssertEqual(LightsFloatLayout.focusedColumnRise(available: 100, focused: true, maxRise: 260),
                       minimum - 100)
        // Never past the window's safe area, never negative.
        XCTAssertEqual(LightsFloatLayout.focusedColumnRise(available: 100, focused: true, maxRise: 40), 40)
        XCTAssertEqual(LightsFloatLayout.focusedColumnRise(available: 100, focused: true, maxRise: -10), 0)
        // The focused inspector's least height (the UI test's 200 pt); no
        // Atmosphere card shares the column since #889.
        XCTAssertGreaterThanOrEqual(minimum, 200)
    }

    func testAShortFocusedColumnCollapsesOnlyATopTrailingCard() {
        let minimum = LightsFloatMetrics.focusedColumnMinimum
        let card = LightsFloatMetrics.orbitCardSize.height + LightsFloatMetrics.gap
        // iPad landscape with the keyboard: ~100 pt column, ~250 pt rise.
        XCTAssertTrue(LightsFloatLayout.focusCollapsesCard(corner: .topTrailing, focused: true,
                                                           available: 100, maxRise: 250))
        XCTAssertFalse(LightsFloatLayout.focusCollapsesCard(corner: .topTrailing, focused: false,
                                                            available: 100, maxRise: 250))
        for corner in [LightsFloatCorner.topLeading, .bottomLeading, .bottomTrailing] {
            XCTAssertFalse(LightsFloatLayout.focusCollapsesCard(corner: corner, focused: true,
                                                                available: 100, maxRise: 250))
        }
        // Room for the expanded card and the minimum: it stays expanded.
        XCTAssertFalse(LightsFloatLayout.focusCollapsesCard(corner: .topTrailing, focused: true,
                                                            available: card + minimum, maxRise: 0))
        XCTAssertTrue(LightsFloatLayout.focusCollapsesCard(corner: .topTrailing, focused: true,
                                                           available: card + minimum - 1, maxRise: 0))
    }

    func testPlacementRowIDsMatchTheRowsIDs() {
        XCTAssertEqual(LightsInspectorState.placementRowID(.orbit, light: "key"), "orbit.key")
        XCTAssertEqual(LightsInspectorState.placementRowID(.pitch, light: "key"), "pitch.key")
        XCTAssertEqual(LightsInspectorState.placementRowID(.orbit, light: nil), "orbit.")
    }

    /// #870 with no Atmosphere card under it (#889): the expanded inspector
    /// has the short column before a field takes the keyboard and keeps it
    /// after.
    func testAFocusedInspectorFieldKeepsTheInspectorsHeightInAShortColumn() throws {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let recorder = FrameRecorder()
        let size = CGSize(width: 1194, height: 420)
        let rootView = LightsFloatingTools(controller: controller,
                                           style: style,
                                           corner: .constant(.bottomLeading),
                                           chrome: lightsFloatCameraChrome,
                                           inspectorStartsCollapsed: false,
                                           onFrames: { recorder.frames = $0 })
            .frame(width: size.width, height: size.height)
            .environment(\.lightsTouchMinimum, 44)
        let host = NSHostingView(rootView: rootView)
        let window = FocusableWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil) }
        window.makeKey()
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
        }

        let before = try XCTUnwrap(recorder.frames, "no frames reported before focus")
        XCTAssertGreaterThanOrEqual(before.inspector.height, 200, "the inspector has the column")

        let fields = findEditableTextFields(in: host)
        let orbitField = try XCTUnwrap(
            fields.first { $0.placeholderString == LightParameter.orbit.label }
                ?? fields.first,
            "no editable Orbit field found"
        )

        XCTAssertTrue(window.makeFirstResponder(orbitField), "could not focus the Orbit field")
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
        }

        let after = try XCTUnwrap(recorder.frames, "no frames reported after focus")
        XCTAssertGreaterThanOrEqual(after.inspector.height, before.inspector.height - 0.5,
                                    "focused inspector should keep its height (before=\(before.inspector), after=\(after.inspector))")
    }
}
