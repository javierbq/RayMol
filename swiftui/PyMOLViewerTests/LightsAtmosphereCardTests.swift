import AppKit
import SwiftUI
import XCTest
@testable import RayMol

/// The Atmosphere card's view (#726, LightsAtmosphereCard.swift) with a
/// controller on fake seams (FakeRigStore, in LightsControllerTests.swift):
/// its sizes in the iOS touch profile, the macOS side column's layout
/// contract (the card keeps its height in a short column; the inspector
/// scrolls first), and pictures of every state. The model under it is tested
/// in LightsAtmosphereTests.swift; the iPad float's frames in
/// LightsFloatTests.swift.

/// The air the pictures show on: haze 0.25, dust 0.5 (the other fields at
/// their defaults).
let atmosphereOnAir = LightRigSnapshot.Air(haze: 0.25, dust: 0.5, dustSize: 0.35, dustSpeed: 1,
                                           scatter: 0.55, seed: 0)

/// Draws SwiftUI offscreen as the other Lights snapshot tests do: an
/// NSHostingView in a borderless window far off any screen, then cacheDisplay
/// into a bitmap (the app's own views drawn into memory, no screen capture).
@MainActor
final class LightsOffscreen {
    private var windows: [NSWindow] = []

    func close() {
        for window in windows { window.orderOut(nil) }
        windows = []
    }

    /// The host of `root` at `size`, laid out and settled (state the views
    /// measure, such as the cards' content heights, has landed).
    func host(_ root: AnyView, size: CGSize, dark: Bool = false) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        settle(host, in: window, size: size)
        return host
    }

    func settle(_ host: NSView, in window: NSWindow?, size: CGSize) {
        for _ in 0..<2 {
            window?.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// The bitmap of `host`; drawn again in front (still off screen) when it
    /// comes back flat.
    func bitmap(_ host: NSHostingView<AnyView>, size: CGSize) -> NSBitmapImageRep? {
        var rep = draw(host)
        if rep.map(Self.isFlat) ?? true, let window = host.window {
            window.orderFrontRegardless()
            settle(host, in: window, size: size)
            rep = draw(host)
        }
        return rep
    }

    /// `root`'s fitting size once its measured state has landed.
    func settledFittingSize(_ root: AnyView) -> CGSize {
        let host = self.host(root, size: CGSize(width: 600, height: 900))
        // Measured heights land on the next update; ask again after it.
        settle(host, in: host.window, size: CGSize(width: 600, height: 900))
        return host.fittingSize
    }

    private func draw(_ host: NSView) -> NSBitmapImageRep? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

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

    /// PNGs go to $RAYMOL_ATMOSPHERE_SNAPSHOT_DIR
    /// (TEST_RUNNER_RAYMOL_ATMOSPHERE_SNAPSHOT_DIR on the xcodebuild line),
    /// else NSTemporaryDirectory()/raymol-atmosphere-snapshots.
    static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_ATMOSPHERE_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-atmosphere-snapshots", isDirectory: true)
    }

    static func write(_ rep: NSBitmapImageRep, name: String) throws {
        let dir = outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        NSLog("ATMOSPHERE_SNAPSHOT: \(url.path)")
    }
}

// MARK: - Sizes and strings

@MainActor
final class AtmosphereCardViewTests: XCTestCase {
    private let offscreen = LightsOffscreen()

    override func tearDown() {
        offscreen.close()
        super.tearDown()
    }

    private func controller(_ setUp: (FakeRigStore) -> Void) -> (LightsController, FakeRigStore) {
        let store = FakeRigStore()
        setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        return (controller, store)
    }

    func testIdentifiersAndStrings() {
        XCTAssertEqual(AtmosphereCardIDs.card, "lights.atmosphere")
        XCTAssertEqual(AtmosphereCardIDs.toggle, "lights.atmosphere.switch")
        XCTAssertEqual(AtmosphereCardIDs.collapse, "lights.atmosphere.collapse")
        XCTAssertEqual(AtmosphereCardIDs.hint, "lights.atmosphere.hint")
        XCTAssertEqual(AtmosphereCardIDs.scatterDisclosure, "lights.atmosphere.scatter.disclosure")
        XCTAssertEqual(AtmosphereCardIDs.sheetButton, "lights.sheet.atmosphere")
        XCTAssertEqual(AirParameter.allCases.map(AtmosphereCardIDs.slider),
                       ["lights.atmosphere.haze", "lights.atmosphere.dust", "lights.atmosphere.dust_size",
                        "lights.atmosphere.dust_speed", "lights.atmosphere.scatter"])
        XCTAssertEqual(AtmosphereCardIDs.field(.dustSpeed), "lights.atmosphere.dust_speed.field")
        XCTAssertEqual(AtmosphereCardIDs.row(.haze), "lights.atmosphere.row.haze")
        XCTAssertEqual(AtmosphereCardIDs.fieldLabel(.dustSize), "Dust size value")
        XCTAssertEqual(AtmosphereCardIDs.scatterValue("-0.25", shown: false), "-0.25, hidden")
        XCTAssertEqual(AtmosphereCardIDs.scatterValue("0.55", shown: true), "0.55, shown")
        XCTAssertEqual(AtmosphereCardIDs.collapseLabel(collapsed: true), "Show the atmosphere settings")
        XCTAssertEqual(AtmosphereCardIDs.collapseLabel(collapsed: false), "Hide the atmosphere settings")
        XCTAssertEqual(AtmosphereCardIDs.sheetButtonHint, "Shows the haze and dust settings")
        XCTAssertEqual(LightsSheetState.atmosphereAnchor, "lights.sheet.atmosphere.section")
        XCTAssertNotEqual(LightsSheetState.atmosphereAnchor, LightsSheetState.rowsAnchor)
    }

    /// Every row is at least a 44 pt target in the touch profile, and the
    /// header presentations are 44 pt tall.
    func testTouchProfileRowsAndHeaders() throws {
        let (controller, _) = controller { store in
            lightsFloatThreePoint(store)
            store.air = atmosphereOnAir
        }
        let style = LightsInspectorSnapshotTests.style(dark: false)
        for p in AirParameter.allCases {
            let state = try XCTUnwrap(AtmosphereCardState(controller))
            let row = try XCTUnwrap(state.row(p))
            let field = try XCTUnwrap(controller.airField(p))
            let size = offscreen.settledFittingSize(AnyView(
                AtmosphereSliderRow(controller: controller, row: row, field: field, style: style)
                    .frame(width: 260)
                    .environment(\.lightsTouchMinimum, 44)))
            XCTAssertGreaterThanOrEqual(size.height, 44 - 0.5, "\(p) row")
        }
        let header = offscreen.settledFittingSize(AnyView(
            LightsAtmosphereCard(controller: controller, style: style, presentation: .header)
                .frame(width: 351)
                .environment(\.lightsTouchMinimum, 44)))
        XCTAssertEqual(header.height, 44, accuracy: 0.5, "the air-only sheet's header row")
        // macOS keeps its pointer sizes: the collapsed card is shorter.
        let mac = offscreen.settledFittingSize(AnyView(
            LightsAtmosphereCard(controller: controller, style: style, start: .collapsed)
                .environment(\.lightsTouchMinimum, 0)))
        XCTAssertEqual(mac.width, LightsInspector.width, accuracy: 0.5)
        XCTAssertLessThan(mac.height, 44)
    }

    /// The start states: `.expandedIfOn` is a header with the air off and the
    /// whole card with it on; drawing a card writes nothing.
    func testStartStatesAndDrawingWritesNothing() throws {
        let style = LightsInspectorSnapshotTests.style(dark: false)
        for (air, expanded) in [(FakeRigStore.defaultAir, false), (atmosphereOnAir, true)] {
            let (controller, store) = controller { store in
                lightsFloatThreePoint(store)
                store.air = air
            }
            let collapsed = offscreen.settledFittingSize(AnyView(
                LightsAtmosphereCard(controller: controller, style: style, start: .collapsed)))
            let start = offscreen.settledFittingSize(AnyView(
                LightsAtmosphereCard(controller: controller, style: style, start: .expandedIfOn)))
            if expanded {
                XCTAssertGreaterThan(start.height, collapsed.height + 100, "the air is on: expanded")
            } else {
                XCTAssertEqual(start.height, collapsed.height, accuracy: 0.5, "the air is off: collapsed")
            }
            XCTAssertTrue(store.numberWrites.isEmpty, "drawing wrote \(store.numberWrites)")
            XCTAssertTrue(store.performed.isEmpty, "drawing pressed \(store.performed)")
        }
    }

    /// The phone header's button draws only in Lights mode.
    func testSheetButtonDrawsOnlyInLightsMode() {
        let store = FakeRigStore()
        lightsFloatThreePoint(store)
        let controller = LightsController(seams: store.seams)
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let button = { AnyView(LightsSheetAtmosphereButton(controller: controller, style: style) {}
            .environment(\.lightsTouchMinimum, 44)) }
        XCTAssertEqual(offscreen.settledFittingSize(button()).height, 0, accuracy: 0.5, "inactive: nothing")
        controller.begin()
        let size = offscreen.settledFittingSize(button())
        XCTAssertEqual(size.width, 44, accuracy: 0.5)
        XCTAssertEqual(size.height, 44, accuracy: 0.5)
    }
}

// MARK: - The macOS column's layout contract

/// The side column with the Atmosphere card under the inspector (#726): the
/// card keeps its height in a short column and the inspector scrolls first;
/// with no light the card stands alone at the top. Frames are read through
/// LightsColumnFramesKey.
@MainActor
final class LightsSideColumnLayoutTests: XCTestCase {
    private let offscreen = LightsOffscreen()

    final class Reported {
        var frames: [String: CGRect] = [:]
    }

    override func tearDown() {
        offscreen.close()
        super.tearDown()
    }

    private struct Column: View {
        let controller: LightsController
        let style: LightsBarStyle
        let start: LightsAtmosphereStart
        let height: CGFloat
        let reported: Reported

        var body: some View {
            LightsSideColumn(controller: controller, style: style, inspectorStartsCollapsed: false,
                             sceneShadowsOn: true, atmosphereStart: start)
                .padding(.trailing, 10)
                .frame(width: LightsSideColumn.width + 20, height: height, alignment: .top)
                .background(Color(white: 0.55))
                .onPreferenceChange(LightsColumnFramesKey.self) { reported.frames = $0 }
        }
    }

    private func column(_ setUp: (FakeRigStore) -> Void, start: LightsAtmosphereStart, height: CGFloat,
                        name: String?) throws -> (frames: [String: CGRect], controller: LightsController,
                                                  store: FakeRigStore) {
        let store = FakeRigStore()
        setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let reported = Reported()
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let size = CGSize(width: LightsSideColumn.width + 20, height: height)
        let host = offscreen.host(AnyView(Column(controller: controller, style: style, start: start,
                                                 height: height, reported: reported)), size: size)
        if let name {
            let rep = try XCTUnwrap(offscreen.bitmap(host, size: size), name)
            XCTAssertFalse(LightsOffscreen.isFlat(rep), "\(name): flat")
            try LightsOffscreen.write(rep, name: name)
        }
        XCTAssertTrue(store.numberWrites.isEmpty, "drawing wrote \(store.numberWrites)")
        XCTAssertTrue(store.performed.isEmpty, "drawing pressed \(store.performed)")
        return (reported.frames, controller, store)
    }

    private static func threeLightsAirOn(_ store: FakeRigStore) {
        lightsFloatThreePoint(store)
        store.air = atmosphereOnAir
    }

    func testAtmosphereKeepsItsHeightInAShortColumn() throws {
        let (frames, controller, _) = try column(Self.threeLightsAirOn, start: .expanded, height: 560,
                                                 name: "column_short_560")
        let orbit = try XCTUnwrap(frames["orbit"], "no orbit frame")
        let inspector = try XCTUnwrap(frames["inspector"], "no inspector frame")
        let atmosphere = try XCTUnwrap(frames["atmosphere"], "no atmosphere frame")
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let cardFit = offscreen.settledFittingSize(AnyView(
            LightsAtmosphereCard(controller: controller, style: style, start: .expanded)))
        let headerFit = offscreen.settledFittingSize(AnyView(
            LightsInspector(controller: controller, style: style, initiallyCollapsed: true, sceneShadowsOn: true)))
        let inspectorFit = offscreen.settledFittingSize(AnyView(
            LightsInspector(controller: controller, style: style, sceneShadowsOn: true)))
        // The card keeps its whole height; the inspector gave way.
        XCTAssertEqual(atmosphere.height, cardFit.height, accuracy: 0.5, "the card kept its height")
        XCTAssertGreaterThan(cardFit.height, 150, "expanded: the rows show")
        XCTAssertGreaterThanOrEqual(inspector.height, headerFit.height - 0.5, "at least the inspector's header")
        XCTAssertLessThan(inspector.height, inspectorFit.height - 50, "the inspector scrolls (the column is short)")
        // Stacked in order, 8 pt apart, inside the column.
        XCTAssertEqual(inspector.minY, orbit.maxY + 8, accuracy: 0.5)
        XCTAssertEqual(atmosphere.minY, inspector.maxY + 8, accuracy: 0.5)
        for (name, frame) in frames {
            XCTAssertLessThanOrEqual(frame.maxY, 560 + 0.5, "\(name) ends below the column")
            XCTAssertEqual(frame.width, LightsInspector.width, accuracy: 0.5, name)
        }
    }

    /// In a tall column every card has its whole height.
    func testATallColumnFitsEveryCard() throws {
        let (frames, controller, _) = try column(Self.threeLightsAirOn, start: .expanded, height: 1300,
                                                 name: nil)
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let inspectorFit = offscreen.settledFittingSize(AnyView(
            LightsInspector(controller: controller, style: style, sceneShadowsOn: true)))
        let inspector = try XCTUnwrap(frames["inspector"])
        XCTAssertEqual(inspector.height, inspectorFit.height, accuracy: 0.5)
        XCTAssertNotNil(frames["atmosphere"])
    }

    /// `.expandedIfOn` (ContentView's macOS start): the card is its header
    /// while the air is off, so the inspector keeps its room.
    func testExpandedIfOnLeavesTheRoomWithTheAirOff() throws {
        let (frames, controller, _) = try column(lightsFloatThreePoint, start: .expandedIfOn, height: 560,
                                                 name: "column_air_off_560")
        let style = LightsInspectorSnapshotTests.style(dark: false)
        let collapsed = offscreen.settledFittingSize(AnyView(
            LightsAtmosphereCard(controller: controller, style: style, start: .collapsed)))
        let atmosphere = try XCTUnwrap(frames["atmosphere"])
        XCTAssertEqual(atmosphere.height, collapsed.height, accuracy: 0.5)
    }

    /// No light: the orbit card and the inspector draw nothing, and the card
    /// stands alone at the top of the column, with its no-lights hint.
    func testTheCardStandsAloneWithNoLights() throws {
        let (frames, controller, _) = try column({ _ in }, start: .expanded, height: 560,
                                                 name: "column_no_lights")
        XCTAssertNil(frames["orbit"].flatMap { $0.isEmpty ? nil : $0 })
        XCTAssertNil(frames["inspector"].flatMap { $0.isEmpty ? nil : $0 })
        let atmosphere = try XCTUnwrap(frames["atmosphere"])
        XCTAssertEqual(atmosphere.minY, 0, accuracy: 0.5)
        XCTAssertEqual(AtmosphereCardState(controller)?.hint, .noLights)
    }
}

// MARK: - Pictures

/// The card in every state, drawn offscreen (LightsOffscreen) in the macOS
/// and the iOS (44 pt) profiles; PNGs to $RAYMOL_ATMOSPHERE_SNAPSHOT_DIR,
/// each logged as `ATMOSPHERE_SNAPSHOT: <path>`. Drawing must write nothing.
@MainActor
final class AtmosphereCardSnapshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var dark = false
        var width: CGFloat = LightsInspector.width + 24
        var height: CGFloat = 340
        var touch: CGFloat = 0
        var presentation: LightsAtmospherePresentation = .card
        var start: LightsAtmosphereStart = .expanded
        var showsScatter = false
        /// The hint the state must show.
        var hint: AtmosphereHint?
        var setUp: (FakeRigStore) -> Void
        var after: (FakeRigStore) -> Void = { _ in }
    }

    private let offscreen = LightsOffscreen()

    override func tearDown() {
        offscreen.close()
        super.tearDown()
    }

    private static func threePoint(_ store: FakeRigStore) {
        lightsFloatThreePoint(store)
    }

    private static func airOn(_ store: FakeRigStore) {
        lightsFloatThreePoint(store)
        store.air = atmosphereOnAir
    }

    /// The rig on, haze 0.35, the rim (orbit 165) behind the molecule.
    private static func backlit(_ store: FakeRigStore) {
        lightsFloatThreePoint(store)
        store.air = atmosphereOnAir
        store.air.haze = 0.35
    }

    private static func lightsOff(_ store: FakeRigStore) {
        lightsFloatThreePoint(store)
        store.enabled = false
        store.air = atmosphereOnAir
    }

    func testRenderSnapshots() throws {
        let shots: [Shot] = [
            Shot(name: "off_light", setUp: Self.threePoint),
            Shot(name: "on_light", setUp: Self.airOn),
            Shot(name: "on_dark", dark: true, setUp: Self.airOn),
            Shot(name: "on_scatter_shown_light", height: 400, showsScatter: true, setUp: { store in
                Self.airOn(store)
                store.air.scatter = -0.25
            }),
            Shot(name: "collapsed_off_light", height: 80, start: .collapsed, setUp: Self.threePoint),
            Shot(name: "collapsed_on_dark", dark: true, height: 80, start: .collapsed, setUp: Self.airOn),
            Shot(name: "hint_no_rig_light", hint: .noLights, setUp: { _ in }),
            Shot(name: "hint_lights_off_light", hint: .lightsOff, setUp: Self.lightsOff),
            Shot(name: "hint_backlit_light", hint: .backlitHaze, setUp: Self.backlit),
            Shot(name: "hint_backlit_dark", dark: true, hint: .backlitHaze, setUp: Self.backlit),
            Shot(name: "no_table_light", height: 160, setUp: { store in
                Self.threePoint(store)
                store.airFieldList = []
            }),
            Shot(name: "busy_dark", dark: true, setUp: Self.airOn, after: { $0.busy = true }),
            Shot(name: "ios44_on_light", height: 420, touch: 44, setUp: Self.airOn),
            Shot(name: "ios44_on_scatter_shown_dark", dark: true, height: 480, touch: 44, showsScatter: true,
                 setUp: Self.airOn),
            Shot(name: "ios44_collapsed_none_light", height: 70, touch: 44, start: .collapsed,
                 setUp: Self.threePoint),
            Shot(name: "ios44_collapsed_no_lights_light", height: 70, touch: 44, start: .collapsed,
                 hint: .noLights, setUp: { _ in }),
            Shot(name: "ios44_collapsed_lights_off_light", height: 70, touch: 44, start: .collapsed,
                 hint: .lightsOff, setUp: Self.lightsOff),
            Shot(name: "ios44_collapsed_backlit_dark", dark: true, height: 70, touch: 44, start: .collapsed,
                 hint: .backlitHaze, setUp: Self.backlit),
            Shot(name: "ios44_section_375_light", width: 375, height: 420, touch: 44, presentation: .section,
                 setUp: Self.airOn),
            Shot(name: "ios44_section_375_dark", dark: true, width: 375, height: 420, touch: 44,
                 presentation: .section, hint: .backlitHaze, setUp: Self.backlit),
            Shot(name: "ios44_header_no_lights_375_light", width: 375, height: 60, touch: 44,
                 presentation: .header, hint: .noLights, setUp: { _ in }),
            Shot(name: "ios44_rows_no_lights_375_light", width: 375, height: 300, touch: 44,
                 presentation: .rows, hint: .noLights, setUp: { _ in }),
        ]
        for (i, shot) in shots.enumerated() {
            try render(shot, name: String(format: "%02d_%@", i + 1, shot.name))
        }
    }

    private func render(_ shot: Shot, name: String) throws {
        let store = FakeRigStore()
        shot.setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        shot.after(store)
        let state = try XCTUnwrap(AtmosphereCardState(controller), name)
        XCTAssertEqual(state.hint, shot.hint, "\(name): the hint")
        let writesBefore = (store.numberWrites.count, store.performed.count)
        let style = LightsInspectorSnapshotTests.style(dark: shot.dark)
        let viewport = shot.dark ? Color(white: 0.08) : Color(white: 0.55)
        let card = LightsAtmosphereCard(controller: controller, style: style, presentation: shot.presentation,
                                        start: shot.start, showsScatter: shot.showsScatter)
        let root: AnyView
        if shot.presentation == .card {
            root = AnyView(card
                .padding(12)
                .frame(width: shot.width, height: shot.height, alignment: .top)
                .background(viewport)
                .environment(\.lightsTouchMinimum, shot.touch))
        } else {
            // A presentation alone, on the tools' background, padded as the
            // sheet pads it.
            root = AnyView(card
                .padding(.horizontal, 12)
                .frame(width: shot.width, height: shot.height, alignment: .top)
                .background(style.background)
                .environment(\.lightsTouchMinimum, shot.touch))
        }
        let size = CGSize(width: shot.width, height: shot.height)
        let host = offscreen.host(root, size: size, dark: shot.dark)
        let rep = try XCTUnwrap(offscreen.bitmap(host, size: size), "\(name): no bitmap")
        XCTAssertFalse(LightsOffscreen.isFlat(rep), "\(name): the picture is one flat colour")
        try LightsOffscreen.write(rep, name: name)
        XCTAssertEqual(store.numberWrites.count, writesBefore.0,
                       "\(name): drawing wrote \(store.numberWrites.dropFirst(writesBefore.0))")
        XCTAssertEqual(store.performed.count, writesBefore.1,
                       "\(name): drawing pressed \(store.performed.dropFirst(writesBefore.1))")
    }
}
