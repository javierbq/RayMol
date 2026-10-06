import AppKit
import SwiftUI
import XCTest
@testable import RayMol

/// The orbit card (#621, Part 3): its size and visibility, the label
/// placement, the frozen plan layout, the DEBUG gesture tokens as
/// PYMOL_AUTOLIGHTS_EDIT parses and applies them, and offscreen pictures of
/// the card, the side column and the hit regions. All on fake seams (the
/// live-engine tests are in LightsOrbitLiveTests). The gesture plumbing itself
/// (DragGesture, MagnifyGesture) is checked by eye on the #610 manual list;
/// everything it calls is LightsOrbitInteraction, tested in LightsOrbitTests.

/// Sketch 2's rig: key −45° / +35° / 3.0× (selected), fill +50° / +5° / 4.0×,
/// rim +165° / +30° / 3.0×.
private func sketchTwo(_ store: FakeRigStore) {
    store.setRig(["key", "fill", "rim"])
    store.lights[0].orbit = -45
    store.lights[0].pitch = 35
    store.lights[0].radius = 3
    store.lights[1].orbit = 50
    store.lights[1].pitch = 5
    store.lights[1].radius = 4
    store.lights[2].orbit = 165
    store.lights[2].pitch = 30
    store.lights[2].radius = 3
}

@MainActor
private func sketchTwoController() -> (FakeRigStore, LightsController) {
    let store = FakeRigStore()
    sketchTwo(store)
    let controller = LightsController(seams: store.seams)
    controller.begin()
    return (store, controller)
}

private let testStyle = LightsBarStyle(accent: .blue, text: Color(white: 0.12), background: Color(white: 0.95))

// MARK: - The card

@MainActor
final class LightsOrbitViewTests: XCTestCase {
    private func fittingSize(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testTheCardShowsOnlyWithItsState() {
        let store = FakeRigStore()
        sketchTwo(store)
        let controller = LightsController(seams: store.seams)
        // Not in Lights mode: nothing drawn.
        XCTAssertNil(LightsOrbitState(controller))
        XCTAssertLessThan(fittingSize(LightsOrbitView(controller: controller, style: testStyle)).height, 1)
        controller.begin()
        let expanded = fittingSize(LightsOrbitView(controller: controller, style: testStyle))
        XCTAssertEqual(expanded.width, LightsOrbitView.width, accuracy: 0.5)
        XCTAssertEqual(expanded.width, LightsInspector.width, accuracy: 0.5, "the column's width")
        // About 246 pt: it fits the column under the bar at the 360 pt macOS
        // minimum viewport with the inspector's header below it.
        XCTAssertGreaterThan(expanded.height, LightsOrbitMetrics.planSize.height + 20)
        XCTAssertLessThan(expanded.height, 256)
        let collapsed = fittingSize(LightsOrbitView(controller: controller, style: testStyle,
                                                    initiallyCollapsed: true))
        XCTAssertLessThan(collapsed.height, 40)
        XCTAssertGreaterThan(collapsed.height, 20)
        controller.end()
        XCTAssertLessThan(fittingSize(LightsOrbitView(controller: controller, style: testStyle)).height, 1,
                          "Done hides the card")
        XCTAssertTrue(store.numberWrites.isEmpty, "laying out writes nothing")
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testTheCardAndItsCanvasesFitTheColumn() {
        // Inset, plan, gap, arc, inset: the column's width.
        let inner = LightsOrbitMetrics.planSize.width + LightsOrbitView.gap + LightsOrbitMetrics.arcSize.width
        XCTAssertEqual(inner + 2 * LightsOrbitView.inset, LightsSideColumn.width, accuracy: 0.5)
        // The drawing's bleed stays inside the card's padding.
        XCTAssertLessThanOrEqual(OrbitCanvas.bleed, LightsOrbitView.inset)
    }

    func testTheGestureFreezesThePlansExtent() throws {
        let (store, controller) = sketchTwoController()
        store.lights[1].radius = 6
        controller.refresh()
        let state = try XCTUnwrap(LightsOrbitState(controller))
        XCTAssertEqual(state.extent, 8)
        XCTAssertEqual(OrbitCanvases.planLayout(state, frozenExtent: nil).extent, 8)
        XCTAssertEqual(OrbitCanvases.planLayout(state, frozenExtent: 4).extent, 4,
                       "a gesture that began at extent 4 keeps it")
        XCTAssertEqual(OrbitCanvases.planLayout(state, frozenExtent: nil, slop: 14).slop, 14)
        XCTAssertEqual(OrbitCanvases.planLayout(state, frozenExtent: nil).slop, LightsOrbitMetrics.defaultSlop)
    }

    func testLabelPlacement() {
        let p = CGPoint(x: 50, y: 50)
        let right = OrbitLabelPlacement(beside: p, dx: 1, dy: 0, clear: 6)
        XCTAssertEqual(right.anchor, .leading)
        XCTAssertGreaterThan(right.point.x, p.x + 6)
        let left = OrbitLabelPlacement(beside: p, dx: -1, dy: 0, clear: 6)
        XCTAssertEqual(left.anchor, .trailing)
        XCTAssertLessThan(left.point.x, p.x - 6)
        let below = OrbitLabelPlacement(beside: p, dx: 0.2, dy: 0.98, clear: 6)
        XCTAssertEqual(below.anchor, .top)
        XCTAssertGreaterThan(below.point.y, p.y + 6)
        let above = OrbitLabelPlacement(beside: p, dx: -0.2, dy: -0.98, clear: 6)
        XCTAssertEqual(above.anchor, .bottom)
        XCTAssertLessThan(above.point.y, p.y - 6)

        // A lamp in the plan's outer half is labelled inward, one in the
        // inner half outward.
        let layout = OrbitPlanLayout(extent: 4, slop: 6)
        let outerLamp = layout.lampPoint(orbit: 90, radius: 4)
        let inward = OrbitLabelPlacement(lampAt: outerLamp, orbit: 90, distance: layout.drawnDistance(radius: 4),
                                         layout: layout, clear: 6)
        XCTAssertEqual(inward.anchor, .trailing, "a lamp at +90° on the outer ring: label to its left")
        let innerLamp = layout.lampPoint(orbit: 90, radius: 1)
        let outward = OrbitLabelPlacement(lampAt: innerLamp, orbit: 90, distance: layout.drawnDistance(radius: 1),
                                          layout: layout, clear: 6)
        XCTAssertEqual(outward.anchor, .leading)
        let bottom = layout.lampPoint(orbit: 0, radius: 4)
        let up = OrbitLabelPlacement(lampAt: bottom, orbit: 0, distance: layout.drawnDistance(radius: 4),
                                     layout: layout, clear: 6)
        XCTAssertEqual(up.anchor, .bottom, "a lamp at the camera on the outer ring: label above it")
        let nearTheTop = layout.lampPoint(orbit: 150, radius: 4)
        let down = OrbitLabelPlacement(lampAt: nearTheTop, orbit: 150, distance: layout.drawnDistance(radius: 4),
                                       layout: layout, clear: 6)
        XCTAssertEqual(down.anchor, .top, "a lamp near ±180° on the outer ring: label below it, off the top labels")

        // The selected lamp's (wide) radius label goes above or below it:
        // outward, unless that is the plan's edge.
        let key = OrbitLabelPlacement(selectedLampAt: layout.lampPoint(orbit: -45, radius: 3), layout: layout,
                                      clear: 12)
        XCTAssertEqual(key.anchor, .top)
        let atTheCamera = OrbitLabelPlacement(selectedLampAt: layout.lampPoint(orbit: 0, radius: 4),
                                              layout: layout, clear: 12)
        XCTAssertEqual(atTheCamera.anchor, .bottom)
        let atTheBack = OrbitLabelPlacement(selectedLampAt: layout.lampPoint(orbit: 180, radius: 4),
                                            layout: layout, clear: 12)
        XCTAssertEqual(atTheBack.anchor, .top)

        // A label is kept inside the canvas.
        let bounds = CGRect(x: 0, y: 0, width: 194, height: 196)
        let size = CGSize(width: 60, height: 12)
        let pushedOff = OrbitLabelPlacement(beside: CGPoint(x: 10, y: 100), dx: -1, dy: 0, clear: 6)
        XCTAssertEqual(pushedOff.origin(for: size, in: bounds).x, 0)
        let offTheBottom = OrbitLabelPlacement(beside: CGPoint(x: 190, y: 190), dx: 0, dy: 1, clear: 6)
        let origin = offTheBottom.origin(for: size, in: bounds)
        XCTAssertEqual(origin.x, 194 - 60)
        XCTAssertEqual(origin.y, 196 - 12)
        let inside = OrbitLabelPlacement(beside: CGPoint(x: 97, y: 98), dx: 1, dy: 0, clear: 6)
        XCTAssertEqual(inside.origin(for: size, in: bounds), CGPoint(x: 97 + 6 + 3, y: 98 - 6))
    }
}

// MARK: - The DEBUG gesture tokens

#if DEBUG
/// PYMOL_AUTOLIGHTS_EDIT's orbit-view tokens, as LightsAutoEdit parses and
/// applies them (OrbitAutoGestureTests in LightsOrbitTests covers
/// OrbitAutoGesture itself).
@MainActor
final class LightsAutoEditGestureTests: XCTestCase {
    func testGestureTokensParse() {
        let parsed = LightsAutoEdit.parse("tap:fill;plan:key:100;square:2.5;arc:20;pinch:1.5")
        XCTAssertEqual(parsed.tokens, [.gesture(.tap("fill")), .gesture(.plan("key", 100)),
                                       .gesture(.square(2.5)), .gesture(.arc(20)), .gesture(.pinch(1.5))])
        XCTAssertEqual(parsed.rejected, [])
        XCTAssertFalse(parsed.expands)
        let mixed = LightsAutoEdit.parse("expand; orbit:30 ;tap:rim;pin:1;arc:-30")
        XCTAssertEqual(mixed.tokens, [.expand, .set(.orbit, 30), .gesture(.tap("rim")), .pin(true),
                                      .gesture(.arc(-30))])
        XCTAssertTrue(mixed.expands)
    }

    func testMalformedGesturesAreRejected() {
        let parsed = LightsAutoEdit.parse("plan:key;square:x;arc:;pinch:0;tap:;orbit:30;plan:key:x;pinch")
        XCTAssertEqual(parsed.tokens, [.set(.orbit, 30)])
        XCTAssertEqual(parsed.rejected, ["plan:key", "square:x", "arc:", "pinch:0", "tap:", "plan:key:x", "pinch"])
    }

    func testTheInspectorsRejectedFormsAreUnchanged() {
        // LightsAutoEditTests' list: none of them is a gesture's.
        let parsed = LightsAutoEdit.parse(
            "spin:3;orbit:x;pin:2;color:1:2;; beam:40 ;warmth:nan;expand:1;shadow:2;shadow")
        XCTAssertEqual(parsed.tokens, [.set(.beam, 40)])
        XCTAssertEqual(parsed.rejected, ["spin:3", "orbit:x", "pin:2", "color:1:2", "warmth:nan", "expand:1",
                                         "shadow:2", "shadow"])
    }

    func testGesturesApplyThroughTheController() throws {
        let (store, controller) = sketchTwoController()
        let tokens = LightsAutoEdit.parse(
            "orbit:-30;tap:fill;plan:fill:100;arc:20;square:2.5;pinch:1.5;expand").tokens
        let entries = LightsAutoEdit.apply(tokens, to: controller)
        XCTAssertEqual(entries, ["orbit=-30 -> ok", "tap:fill -> ok selected=fill",
                                 "plan:fill:100 -> ok orbit=105", "arc:20 -> ok pitch=20",
                                 "square:2.5 -> ok radius=2.5", "pinch:1.5 -> ok radius=4"])
        XCTAssertEqual(store.lights[0].orbit, -30, "the inspector token wrote key")
        XCTAssertEqual(store.lights[0].pitch, 35)
        XCTAssertEqual(store.lights[0].radius, 3)
        XCTAssertEqual(store.lights[1].orbit, 105)
        XCTAssertEqual(store.lights[1].pitch, 20)
        XCTAssertEqual(store.lights[1].radius, 4)
        XCTAssertEqual(store.lights[1].beam, 45, "the beam is kept")
        XCTAssertEqual(store.lights[2], {
            var rim = FakeRigStore.Light(name: "rim")
            rim.orbit = 165
            rim.pitch = 30
            rim.radius = 3
            return rim
        }(), "rim untouched")
        XCTAssertEqual(Set(store.numberWrites.map(\.field)), ["orbit", "pitch", "radius"])
        XCTAssertTrue(store.vectorWrites.isEmpty)
        XCTAssertTrue(store.performed.isEmpty, "no button press, no Python")
        // The log line's plan= field.
        XCTAssertEqual(try XCTUnwrap(LightsOrbitState(controller)).summary,
                       "fill,orbit:105.0,pitch:20.0,radius:4.00,extent:4,lamps:key|fill|rim")
    }

    func testAGestureThatCannotEditWritesNothing() {
        let (store, controller) = sketchTwoController()
        store.busy = true
        let entries = LightsAutoEdit.apply(LightsAutoEdit.parse("plan:key:30;arc:10;pinch:2").tokens,
                                           to: controller)
        XCTAssertEqual(entries, ["plan:key:30 -> miss", "arc:10 -> miss", "pinch:2 -> miss"])
        XCTAssertTrue(store.numberWrites.isEmpty)
        store.busy = false
        controller.end()
        XCTAssertEqual(LightsAutoEdit.apply([.gesture(.tap("fill"))], to: controller), ["tap:fill -> no_light"])
    }
}
#endif

// MARK: - Pictures

/// The card, the side column and the hit regions drawn offscreen, as
/// LightsInspectorSnapshotTests draws the inspector: an NSHostingView in a
/// borderless window far off any screen, then cacheDisplay into a bitmap (the
/// app's own view drawn into memory, no screen capture). PNGs go to
/// $RAYMOL_LIGHTSORBIT_SNAPSHOT_DIR (TEST_RUNNER_RAYMOL_LIGHTSORBIT_SNAPSHOT_DIR
/// on the xcodebuild line), else NSTemporaryDirectory()/raymol-lightsorbit-
/// snapshots; each is logged as `LIGHTSORBIT_SNAPSHOT: <path>`. Drawing must
/// write nothing: every shot checks the fake store saw no write and no button
/// press beyond what its `after` did.
@MainActor
final class LightsOrbitSnapshotTests: XCTestCase {
    private enum Kind {
        /// The orbit card alone.
        case card(collapsed: Bool)
        /// The side column (orbit card above the inspector).
        case column(orbitCollapsed: Bool)
        /// The bar above the column, as macLightsOverlay places them.
        case withBar
        /// The plan and the arc with OrbitHitTest's regions over them.
        case hitRegions(slop: CGFloat)
    }

    private struct Shot {
        var name: String
        var kind: Kind
        var dark = false
        var width: CGFloat = LightsSideColumn.width + 24
        var height: CGFloat = 290
        var setUp: (FakeRigStore) -> Void = sketchTwo
        var after: (LightsController, FakeRigStore) -> Void = { _, _ in }
    }

    private static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTSORBIT_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightsorbit-snapshots", isDirectory: true)
    }

    /// The column's height under the bar at the macOS minimum viewport
    /// (MetalViewport minHeight 360, less the bar and its spacing).
    static let minimumColumnHeight: CGFloat = 298

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private static func pinnedRim(_ placement: LightPlacement) -> (FakeRigStore) -> Void {
        { store in
            sketchTwo(store)
            store.lights[2].pinned = true
            store.eyePlacements["rim"] = placement
        }
    }

    func testRenderSnapshots() throws {
        let tall = LightsSideColumn.width + 24
        let shots: [Shot] = [
            Shot(name: "sketch2_light", kind: .card(collapsed: false)),
            Shot(name: "sketch2_dark", kind: .card(collapsed: false), dark: true),
            Shot(name: "column_light", kind: .column(orbitCollapsed: false), height: 820),
            // The macOS minimum viewport: the orbit card keeps its height and
            // the inspector scrolls; collapsing the orbit card gives it room.
            Shot(name: "column_min_viewport_light", kind: .column(orbitCollapsed: false),
                 height: Self.minimumColumnHeight),
            Shot(name: "column_min_viewport_orbit_collapsed_light", kind: .column(orbitCollapsed: true),
                 height: Self.minimumColumnHeight),
            // Pinned rim after a 30° camera turn: drawn at its eye placement.
            Shot(name: "pinned_rim_turned_light", kind: .card(collapsed: false),
                 setUp: Self.pinnedRim(LightPlacement(orbit: -165, pitch: 30, radius: 3)),
                 after: { controller, _ in controller.select(name: "rim") }),
            // Pinned rim at eye radius 12: on the outer ring with an outward
            // mark and its true radius in its label; then selected.
            Shot(name: "pinned_rim_radius12_column_light", kind: .column(orbitCollapsed: false), height: 820,
                 setUp: Self.pinnedRim(LightPlacement(orbit: 150, pitch: -15, radius: 12))),
            Shot(name: "pinned_rim_radius12_selected_dark", kind: .card(collapsed: false), dark: true,
                 setUp: Self.pinnedRim(LightPlacement(orbit: 150, pitch: -15, radius: 12)),
                 after: { controller, _ in controller.select(name: "rim") }),
            Shot(name: "extent8_dark", kind: .card(collapsed: false), dark: true, setUp: { store in
                sketchTwo(store)
                store.lights[1].radius = 6
            }),
            Shot(name: "rig_off_light", kind: .card(collapsed: false), setUp: { store in
                sketchTwo(store)
                store.enabled = false
            }),
            Shot(name: "busy_dark", kind: .card(collapsed: false), dark: true,
                 after: { _, store in store.busy = true }),
            Shot(name: "collapsed_light", kind: .card(collapsed: true), height: 70),
            Shot(name: "hit_regions_mac_slop6_light", kind: .hitRegions(slop: 6), width: tall, height: 230),
            Shot(name: "hit_regions_ios_slop14_light", kind: .hitRegions(slop: 14), width: tall, height: 230),
            Shot(name: "hit_regions_small_ring_slop14_light", kind: .hitRegions(slop: 14), width: tall,
                 height: 230, setUp: { store in
                     sketchTwo(store)
                     store.lights[0].radius = 0.5
                 }),
            // Mirroring with the bar: fill picked by a tap on its lamp, then
            // dragged to 105°; the chip, the inspector header and its Orbit
            // row agree.
            Shot(name: "mirror_fill_tapped_light", kind: .withBar, width: 900, height: 900,
                 after: { controller, _ in Self.tapFill(controller) }),
            Shot(name: "mirror_fill_dragged_105_light", kind: .withBar, width: 900, height: 900,
                 after: { controller, store in
                     Self.tapFill(controller)
                     Self.dragFill(controller, to: 100)
                     XCTAssertEqual(store.lights[1].orbit, 105)
                     XCTAssertEqual(LightsInspectorState(controller)?.row(.orbit)?.value, 105)
                     XCTAssertEqual(LightsBarState(controller).chips.first(where: \.isSelected)?.name, "fill")
                 }),
        ]
        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, shot) in shots.enumerated() {
            let url = dir.appendingPathComponent(String(format: "%02d_%@.png", i + 1, shot.name))
            try render(shot, to: url)
        }
    }

    /// A tap on fill's lamp (press and release, no move), as the card's
    /// gesture makes it.
    private static func tapFill(_ controller: LightsController) {
        guard let state = LightsOrbitState(controller), let fill = state.lamp(named: "fill") else {
            return XCTFail("no fill lamp")
        }
        let layout = OrbitPlanLayout(extent: state.extent)
        let session = LightsOrbitInteraction(controller: controller)
            .beginPlan(at: layout.lampPoint(orbit: fill.orbit, radius: fill.radius), state: state, layout: layout)
        XCTAssertNotNil(session)
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(LightsInspectorState(controller)?.name, "fill")
    }

    /// Fill's lamp dragged along its ring towards `orbit`.
    private static func dragFill(_ controller: LightsController, to orbit: Double) {
        guard let state = LightsOrbitState(controller), let fill = state.lamp(named: "fill") else {
            return XCTFail("no fill lamp")
        }
        let layout = OrbitPlanLayout(extent: state.extent)
        let interaction = LightsOrbitInteraction(controller: controller)
        guard var session = interaction.beginPlan(at: layout.lampPoint(orbit: fill.orbit, radius: fill.radius),
                                                  state: state, layout: layout) else {
            return XCTFail("no session on fill")
        }
        let distance = layout.drawnDistance(radius: fill.radius)
        for k in 1...12 {
            let o = fill.orbit + (orbit - fill.orbit) * Double(k) / 12
            interaction.move(&session, to: layout.point(orbit: o, distance: distance))
        }
    }

    private func render(_ shot: Shot, to url: URL) throws {
        let store = FakeRigStore()
        shot.setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        shot.after(controller, store)
        // Drawing must write nothing beyond what `after` did.
        let writesBefore = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)
        let style = LightsInspectorSnapshotTests.style(dark: shot.dark)
        // A neutral viewport behind the card.
        let viewport = shot.dark ? Color(white: 0.08) : Color(white: 0.55)

        let root: AnyView
        switch shot.kind {
        case .card(let collapsed):
            root = AnyView(
                LightsOrbitView(controller: controller, style: style, initiallyCollapsed: collapsed)
                    .padding(12)
                    .frame(width: shot.width, height: shot.height, alignment: .top)
                    .background(viewport))
        case .column(let orbitCollapsed):
            root = AnyView(
                LightsSideColumn(controller: controller, style: style, inspectorStartsCollapsed: false,
                                 orbitStartsCollapsed: orbitCollapsed)
                    .padding(.horizontal, 12)
                    .frame(width: shot.width, height: shot.height, alignment: .top)
                    .background(viewport))
        case .withBar:
            root = AnyView(
                VStack(alignment: .trailing, spacing: 8) {
                    LightsBar(controller: controller, style: style, onDone: {})
                    LightsSideColumn(controller: controller, style: style, inspectorStartsCollapsed: false)
                        .padding(.trailing, 10).padding(.bottom, 10)
                }
                .frame(width: shot.width, height: shot.height, alignment: .top)
                .background(viewport))
        case .hitRegions(let slop):
            let state = try XCTUnwrap(LightsOrbitState(controller))
            root = AnyView(
                OrbitHitRegions(state: state, slop: slop, style: style)
                    .padding(12)
                    .frame(width: shot.width, height: shot.height, alignment: .top)
                    .background(viewport))
        }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let size = NSSize(width: shot.width, height: shot.height)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)

        var rep = draw(host, in: window, size: size)
        if rep.map(Self.isFlat) ?? true {
            window.orderFrontRegardless()
            rep = draw(host, in: window, size: size)
        }
        let bitmap = try XCTUnwrap(rep, "\(shot.name): no bitmap")
        XCTAssertFalse(Self.isFlat(bitmap), "\(shot.name): the picture is one flat colour")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        NSLog("LIGHTSORBIT_SNAPSHOT: \(url.path)")
        window.orderOut(nil)

        XCTAssertEqual(store.numberWrites.count, writesBefore.0,
                       "\(shot.name): drawing wrote \(store.numberWrites.dropFirst(writesBefore.0))")
        XCTAssertEqual(store.vectorWrites.count, writesBefore.1, "\(shot.name): drawing wrote a colour")
        XCTAssertEqual(store.performed.count, writesBefore.2,
                       "\(shot.name): drawing pressed \(store.performed.dropFirst(writesBefore.2))")
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

/// The plan and the arc as the card draws them, with what OrbitHitTest
/// returns at every other point tinted over them (for the UX review): each
/// lamp's region in its identity colour, the square's in black, the pitch
/// handle's in the selected light's colour and the track's in grey.
private struct OrbitHitRegions: View {
    var state: LightsOrbitState
    var slop: CGFloat
    var style: LightsBarStyle

    var body: some View {
        let plan = OrbitPlanLayout(extent: state.extent, slop: slop)
        let arc = PitchArcLayout(slop: slop)
        let state = state
        let style = style
        HStack(alignment: .top, spacing: LightsOrbitView.gap) {
            OrbitCanvas(size: LightsOrbitMetrics.planSize) { context in
                OrbitPlanPainter(state: state, layout: plan, squareAngle: nil, style: style).draw(in: &context)
                Self.tint(&context, size: plan.size) { p in
                    switch OrbitHitTest.plan(at: p, layout: plan, state: state) {
                    case .lamp(_, let index): return LightPalette.color(state.lamps[index].slot)
                    case .radiusSquare: return .black
                    default: return nil
                    }
                }
            }
            OrbitCanvas(size: LightsOrbitMetrics.arcSize) { context in
                PitchArcPainter(state: state, layout: arc, style: style).draw(in: &context)
                Self.tint(&context, size: arc.size) { p in
                    switch OrbitHitTest.pitch(at: p, layout: arc, pitch: state.selected.pitch) {
                    case .pitchHandle: return LightPalette.color(state.selected.slot)
                    case .pitchTrack: return .gray
                    default: return nil
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, LightsOrbitView.inset)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func tint(_ context: inout GraphicsContext, size: CGSize, colour: (CGPoint) -> Color?) {
        for y in stride(from: CGFloat(0), to: size.height, by: 2) {
            for x in stride(from: CGFloat(0), to: size.width, by: 2) {
                guard let c = colour(CGPoint(x: x + 1, y: y + 1)) else { continue }
                context.fill(Path(CGRect(x: x, y: y, width: 2, height: 2)), with: .color(c.opacity(0.35)))
            }
        }
    }
}
