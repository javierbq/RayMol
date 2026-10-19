import AppKit
import SwiftUI
import XCTest
@testable import RayMol

/// The Lights bar (#619): what it shows and enables for each rig state
/// (LightsBarState, no drawing), and pictures of the bar itself, drawn
/// offscreen with a controller on fake seams (FakeRigStore, in
/// LightsControllerTests.swift).

// MARK: - What the bar shows

@MainActor
final class LightsBarModelTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private func begin(with lights: [String]?, enabled: Bool = true) -> LightsBarState {
        if let lights { store.setRig(lights, enabled: enabled) }
        controller.begin()
        return LightsBarState(controller)
    }

    func testChipLabelsIdentifiersAndSelection() {
        _ = begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        let state = LightsBarState(controller)
        XCTAssertEqual(state.chips.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(state.chips.map(\.accessibilityLabel), ["key light", "fill light", "rim light"])
        XCTAssertEqual(state.chips.map(\.accessibilityIdentifier),
                       ["lights.chip.key", "lights.chip.fill", "lights.chip.rim"])
        XCTAssertEqual(state.chips.map(\.isSelected), [false, true, false])
        XCTAssertEqual(state.chips.map(\.slot), [0, 1, 2], "key blue, fill orange, rim green")
        XCTAssertEqual(state.chips.map(\.index), [0, 1, 2])
        XCTAssertEqual(LightsBarState.chipAccessibilityLabel("light4"), "light4 light")
    }

    func testChipSlotsFollowTheNameNotTheIndex() {
        _ = begin(with: ["key", "fill", "rim"])
        store.removeLight("key")
        controller.refresh()
        let state = LightsBarState(controller)
        XCTAssertEqual(state.chips.map(\.name), ["fill", "rim"])
        XCTAssertEqual(state.chips.map(\.slot), [1, 2], "fill stays orange, rim stays green")
    }

    func testChipIsHollowWhenBehind() {
        // #622: the chip's dot is hollow while its light is behind the
        // molecule (LightDepth, the gizmo's rule); VoiceOver says so.
        store.setRig(["key", "fill", "rim"])
        store.lights[2].orbit = 150
        store.lights[1].orbit = 92
        var state = begin(with: nil)
        XCTAssertEqual(state.chips.map(\.isBehind), [false, true, true])
        XCTAssertEqual(state.chips.map(\.accessibilityValue),
                       ["in front of the molecule", "behind the molecule", "behind the molecule"])
        XCTAssertEqual(state.chips.map(\.accessibilityLabel), ["key light", "fill light", "rim light"],
                       "the label stays the name")
        XCTAssertEqual(LightsBarState.chipAccessibilityValue(behind: true), "behind the molecule")
        XCTAssertEqual(LightsBarState.chipAccessibilityValue(behind: false), "in front of the molecule")

        // A pinned light's crossing reaches the chips through `facing` only:
        // the controller (and so the bar) is not re-rendered.
        XCTAssertEqual(controller.setPinned(true), .ok)   // key, selected
        var barChanges = 0
        var chipChanges = 0
        let bar = controller.objectWillChange.sink { barChanges += 1 }
        let chips = controller.facing.objectWillChange.sink { chipChanges += 1 }
        defer { bar.cancel(); chips.cancel() }
        store.eyePlacements["key"] = LightPlacement(orbit: 135, pitch: 0, radius: 4)
        controller.frameRendered()
        XCTAssertEqual(barChanges, 0)
        XCTAssertEqual(chipChanges, 1)
        XCTAssertTrue(controller.facing.isBehind("key"))
        state = LightsBarState(controller)
        XCTAssertEqual(state.chips.map(\.isBehind), [true, true, true])
    }

    func testNoRigShowsOnlyTheStatus() {
        let state = begin(with: nil)
        XCTAssertTrue(state.chips.isEmpty)
        XCTAssertEqual(state.status, "No lights · add one or pick a preset")
        XCTAssertEqual(state.status, LightsBarState.noLightsText)
        XCTAssertEqual(LightsBarState.noLightsShortText, "No lights")
        XCTAssertTrue(state.canAdd)
        XCTAssertTrue(state.canPickPreset)
        XCTAssertFalse(state.canRemove)
        XCTAssertFalse(state.canRecentre)
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(state.canRevert)
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.powerLabel, "Lights off")
        XCTAssertEqual(state.addHelp, "Add a light")
        XCTAssertEqual(state.removeHelp, "Select a light to remove it")
    }

    func testEmptyRigShowsTheSameStatus() {
        let state = begin(with: [])
        XCTAssertTrue(state.chips.isEmpty)
        XCTAssertEqual(state.status, LightsBarState.noLightsText)
        XCTAssertFalse(state.canRemove)
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(state.isOn, "an empty rig shows off, whatever its switch says")
    }

    func testThreeLightsEnableEverythingButRevert() {
        let state = begin(with: ["key", "fill", "rim"])
        XCTAssertNil(state.status, "no status text while there are chips")
        XCTAssertTrue(state.canAdd)
        XCTAssertTrue(state.canRemove)
        XCTAssertTrue(state.canPickPreset)
        XCTAssertTrue(state.canRecentre)
        XCTAssertTrue(state.canToggle)
        XCTAssertFalse(state.canRevert, "nothing changed yet")
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.powerLabel, "Lights on")
        XCTAssertEqual(state.powerHelp, "Lights on: turn the rig off")
        XCTAssertEqual(state.removeHelp, "Remove key")
        XCTAssertEqual(state.presets.map(\.name), ["three_point", "softbox"])

        controller.add()
        XCTAssertTrue(LightsBarState(controller).canRevert)
    }

    func testSixLightsDisableAdd() {
        let state = begin(with: ["key", "fill", "rim", "light4", "light5", "light6"])
        XCTAssertFalse(state.canAdd)
        XCTAssertEqual(state.addHelp, "A rig holds at most 6 lights")
        XCTAssertTrue(state.canRemove)
        XCTAssertEqual(Set(state.chips.map(\.slot)).count, 6, "six distinct identity colours")
    }

    func testOffRigShowsOffAndCanTurnOn() {
        let state = begin(with: ["key", "fill", "rim"], enabled: false)
        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.powerLabel, "Lights off")
        XCTAssertEqual(state.powerHelp, "Lights off: turn the rig on")
        XCTAssertTrue(state.canToggle, "an off rig always has a way back on")
        XCTAssertEqual(state.chips.count, 3)
        XCTAssertNil(state.status)
    }

    func testBusyDisablesEveryAction() {
        _ = begin(with: ["key", "fill", "rim"])
        controller.add()
        store.busy = true
        let state = LightsBarState(controller)
        XCTAssertFalse(state.canAdd)
        XCTAssertFalse(state.canRemove)
        XCTAssertFalse(state.canPickPreset)
        XCTAssertFalse(state.canRecentre)
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(state.canRevert)
        XCTAssertEqual(state.chips.count, 4, "the chips still show the rig")
    }

    func testInactiveDisablesEveryAction() {
        _ = begin(with: ["key", "fill", "rim"])
        controller.end()
        let state = LightsBarState(controller)
        XCTAssertFalse(state.canAdd)
        XCTAssertFalse(state.canRemove)
        XCTAssertFalse(state.canPickPreset)
        XCTAssertFalse(state.canRecentre)
        XCTAssertFalse(state.canToggle)
        XCTAssertFalse(state.canRevert)
    }

    func testNoPresetsDisablesTheMenu() {
        store.presetList = []
        let state = begin(with: ["key"])
        XCTAssertFalse(state.canPickPreset)
    }

    /// #798: every surface draws a light in its own colour, and one edit of
    /// Colour or Warmth moves them all together (the markers are rebuilt from
    /// the controller, so there is nothing to go stale).
    func testEverySurfaceShowsTheLightsOwnColourAndFollowsEdits() {
        _ = begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        func markers() -> [[LightMarkerColour]] {
            let gizmo = LightGizmoInputs(controller: controller, viewSize: CGSize(width: 400, height: 300),
                                         gridMode: false, sceneShadowsOn: nil)
            return [LightsBarState(controller).chips.map(\.marker),
                    LightsOrbitState(controller)!.lamps.map(\.marker),
                    gizmo.lights.map(\.marker),
                    [LightsInspectorState(controller)!.marker]]
        }
        // Untouched lights are white at 6500 K.
        for surface in markers() {
            XCTAssertEqual(surface.first, .neutral)
        }
        _ = controller.setColour(SIMD3(1, 0, 0))
        _ = controller.set(.warmth, 3200)
        let red = LightMarkerColour(color: SIMD3(1, 0, 0), warmth: 3200)
        let white = LightMarkerColour(color: SIMD3(1, 1, 1), warmth: 6500)
        let all = markers()
        XCTAssertEqual(all[0], [white, red, white], "chips")
        XCTAssertEqual(all[1], [white, red, white], "orbit lamps")
        XCTAssertEqual(all[2], [white, red, white], "gizmo knobs")
        XCTAssertEqual(all[3].first, red, "the inspector's dot is the selected light's")
        XCTAssertEqual(red.fill, SIMD3(1, 0, 0), "red at 3200 K: warmth never lifts a zero channel")
        // Selection does not change a marker's colour.
        controller.select(name: "key")
        XCTAssertEqual(LightsBarState(controller).chips.map(\.marker), [white, red, white])
    }

    func testRevertAsksOnlyForMoreThanOneEdit() {
        var state = begin(with: ["key", "fill", "rim"])
        XCTAssertFalse(state.revertNeedsConfirmation)
        XCTAssertEqual(state.editCount, 0)

        controller.add()
        state = LightsBarState(controller)
        XCTAssertTrue(state.canRevert)
        XCTAssertFalse(state.revertNeedsConfirmation)
        XCTAssertEqual(state.editCount, 1)

        controller.setEnabled(false)
        state = LightsBarState(controller)
        XCTAssertTrue(state.canRevert)
        XCTAssertTrue(state.revertNeedsConfirmation)
        XCTAssertEqual(state.editCount, 2)

        XCTAssertEqual(LightsBar.revertConfirmLabel(2), "Revert 2 edits")
    }

    // MARK: the Atmosphere entry (#795)

    func testAtmosphereEntryIsOnTheBarExceptOnTheIPadFloat() {
        // Atmosphere is scene-wide: a phone's bar carries it (the bottom
        // sheet's portrait overflow menu, the side panel's landscape bar) and
        // so does the macOS bar, as a popover (#889); the iPad float has a
        // card of its own.
        XCTAssertTrue(LightsBarState.showsAtmosphereEntry(placement: .bottomSheet))
        XCTAssertTrue(LightsBarState.showsAtmosphereEntry(placement: .sidePanel))
        XCTAssertTrue(LightsBarState.showsAtmosphereEntry(placement: .column))
        XCTAssertFalse(LightsBarState.showsAtmosphereEntry(placement: .floating))
        for placement in LightsToolsPlacement.allCases {
            XCTAssertEqual(LightsBarState.showsAtmosphereEntry(placement: placement), placement != .floating,
                           "\(placement)")
            XCTAssertEqual(LightsBarState.atmosphereOpensPopover(placement: placement), placement == .column,
                           "\(placement)")
        }
    }

    func testLightMenuReplacesTheChipsInPhonePortraitAndOnMacOS() {
        // #885 (phone portrait) and #889 (macOS): a dropdown; iPhone
        // landscape and the iPad float keep the chips.
        for placement in LightsToolsPlacement.allCases {
            let menu = placement == .bottomSheet || placement == .column
            XCTAssertEqual(LightsBarState.showsLightMenu(placement: placement), menu, "\(placement)")
        }
    }

    func testAtmosphereEntryStateDoesNotDependOnTheSelectedLight() {
        // Same entry, same state, whichever light is selected and with none.
        _ = begin(with: ["key", "fill", "rim"])
        store.air = atmosphereOnAir
        controller.refresh()
        var seen = Set<Bool>()
        for name in ["key", "fill", "rim"] {
            controller.select(name: name)
            seen.insert(LightsBarState(controller).atmosphereIsOn)
        }
        XCTAssertEqual(seen, [true], "on for every selected light")
        // No light at all (the air-only sheet's case): the state is the same.
        let emptyStore = FakeRigStore()
        emptyStore.setRig([], enabled: true)
        emptyStore.air = atmosphereOnAir
        let empty = LightsController(seams: emptyStore.seams)
        empty.begin()
        XCTAssertNil(empty.selectedLight)
        XCTAssertTrue(LightsBarState(empty).atmosphereIsOn, "and with no light selected")
    }

    func testAtmosphereMenuItemShowsTheState() {
        XCTAssertEqual(LightsBarState.atmosphereMenuTitle(isOn: true), "Atmosphere: On")
        XCTAssertEqual(LightsBarState.atmosphereMenuTitle(isOn: false), "Atmosphere: Off")
        XCTAssertEqual(LightsBarState.atmosphereMenuImage(isOn: true), "cloud.fog.fill")
        XCTAssertEqual(LightsBarState.atmosphereMenuImage(isOn: false), "cloud.fog")
        let off = begin(with: ["key", "fill", "rim"])
        XCTAssertFalse(off.atmosphereIsOn, "the default air is off")
        store.air = atmosphereOnAir
        controller.refresh()
        XCTAssertTrue(LightsBarState(controller).atmosphereIsOn)
    }

    func testAtmosphereEntryIsNamedAsASceneSetting() {
        XCTAssertEqual(AtmosphereCardIDs.sheetButtonLabel, "Scene atmosphere")
        XCTAssertEqual(AtmosphereCardIDs.menuItem, "lights.atmosphere.menu")
        XCTAssertNotEqual(AtmosphereCardIDs.menuItem, AtmosphereCardIDs.sheetButton)
    }
}

final class LightsBarTests: XCTestCase {
    func testPortraitLightMenuStrings() {
        XCTAssertEqual(LightsBarState.lightMenuTitle(selected: "key"), "key")
        XCTAssertEqual(LightsBarState.lightMenuTitle(selected: nil), "No light")
        XCTAssertEqual(LightsBarState.noLightTitle, "No light")
        XCTAssertEqual(LightsBarState.lightMenuItemIdentifier("fill"), "lights.menu.light.fill")
        XCTAssertEqual(LightsBarState.editLightTitle, "Edit light…")
        XCTAssertEqual(LightsBarState.editLightIdentifier, "lights.menu.edit")
        XCTAssertEqual(LightsBarState.lightMenuIdentifier, "lights.menu")
        XCTAssertEqual(LightsBarState.lightMenuLabel, "Light")
    }

    /// The menu's Shadow toggle is disabled under the cap notice once
    /// `maxShadowed` other lights cast shadows (#886 review), since the
    /// inspector's notice is not on screen with the portrait editor closed.
    func testLightMenuAccessibilityValue() {
        XCTAssertEqual(LightsBarState.lightMenuAccessibilityValue(selected: "key", behind: false),
                       "key, in front of the molecule")
        XCTAssertEqual(LightsBarState.lightMenuAccessibilityValue(selected: "rim", behind: true),
                       "rim, behind the molecule")
        XCTAssertEqual(LightsBarState.lightMenuAccessibilityValue(selected: nil, behind: true), "No light")
    }

    func testShadowCapReached() {
        let cap = LightsController.maxShadowed
        XCTAssertFalse(LightsBarState.shadowCapReached(isShadowed: false, shadowedCount: cap - 1))
        XCTAssertTrue(LightsBarState.shadowCapReached(isShadowed: false, shadowedCount: cap))
        // A shadowed light can always turn its own shadow off.
        XCTAssertFalse(LightsBarState.shadowCapReached(isShadowed: true, shadowedCount: cap))
    }
}

// MARK: - Pictures

/// The bar drawn offscreen, as MovieExportSnapshot draws the Export Movie
/// controls: an NSHostingView in a borderless window far off any screen, then
/// cacheDisplay into a bitmap. It is the app's own view drawn into memory (no
/// screen capture), and unlike ImageRenderer it draws the ScrollView, the
/// menus and the bordered buttons. The PNGs go to
/// $RAYMOL_LIGHTSBAR_SNAPSHOT_DIR (TEST_RUNNER_RAYMOL_LIGHTSBAR_SNAPSHOT_DIR
/// on the xcodebuild line), else NSTemporaryDirectory()/raymol-lightsbar-snapshots;
/// each is logged as `LIGHTSBAR_SNAPSHOT: <path>`.
@MainActor
final class LightsBarSnapshotTests: XCTestCase {
    private struct Shot {
        var name: String
        var lights: [String]?
        var enabled = true
        var select: String?
        var width: CGFloat
        var dark: Bool
        /// The touch profile's minimum target (44: iOS, drawn on macOS).
        var touch: CGFloat = 0
        /// A phone's Atmosphere entry (#795): the bar's `onAtmosphere`.
        var atmosphere = false
        var air: LightRigSnapshot.Air?
        /// The macOS bar (#889): the light menu and the Atmosphere popover button.
        var macOS = false
    }

    private static let three = ["key", "fill", "rim"]
    private static let six = ["key", "fill", "rim", "light4", "light5", "light6"]

    private static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTSBAR_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightsbar-snapshots", isDirectory: true)
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func testRenderSnapshots() throws {
        var shots: [Shot] = []
        for dark in [false, true] {
            let look = dark ? "dark" : "light"
            shots += [
                Shot(name: "wide_0_\(look)", lights: nil, width: 900, dark: dark),
                Shot(name: "wide_3_fill_selected_\(look)", lights: Self.three, select: "fill",
                     width: 900, dark: dark),
                Shot(name: "wide_6_\(look)", lights: Self.six, width: 900, dark: dark),
                Shot(name: "wide_3_off_\(look)", lights: Self.three, enabled: false,
                     width: 900, dark: dark),
            ]
        }
        shots += [
            Shot(name: "compact_3_light", lights: Self.three, select: "fill", width: 600, dark: false),
            Shot(name: "compact_6_light", lights: Self.six, width: 600, dark: false),
            // #623: a 375 pt phone with every control a 44 pt target; the
            // compact bar still shows about two chips.
            Shot(name: "compact_3_ios44_375_light", lights: Self.three, select: "fill", width: 375,
                 dark: false, touch: 44),
            Shot(name: "compact_6_ios44_375_dark", lights: Self.six, width: 375, dark: true, touch: 44),
            Shot(name: "compact_0_ios44_375_light", lights: nil, width: 375, dark: false, touch: 44),
            // #795: the phone's Atmosphere entry. Portrait: an item in the
            // overflow menu (the bar itself looks as before). Landscape:
            // a bar button, at the widths of an iPhone in landscape (932,
            // 852, 667, 568 pt) with the air on and off.
            Shot(name: "atmosphere_compact_ios44_375_light", lights: Self.three, select: "fill", width: 375,
                 dark: false, touch: 44, atmosphere: true),
            Shot(name: "atmosphere_wide_ios44_932_light", lights: Self.three, select: "fill", width: 932,
                 dark: false, touch: 44, atmosphere: true),
            Shot(name: "atmosphere_wide_on_ios44_852_dark", lights: Self.three, select: "fill", width: 852,
                 dark: true, touch: 44, atmosphere: true, air: atmosphereOnAir),
            Shot(name: "atmosphere_wide_ios44_667_light", lights: Self.three, select: "fill", width: 667,
                 dark: false, touch: 44, atmosphere: true),
            Shot(name: "atmosphere_wide_ios44_568_light", lights: Self.three, select: "fill", width: 568,
                 dark: false, touch: 44, atmosphere: true),
            // #889: the macOS bar, with the light menu and the Atmosphere
            // button, wide and in a narrow window, the air off and on.
            Shot(name: "macos_wide_3_fill_light", lights: Self.three, select: "fill", width: 900,
                 dark: false, macOS: true),
            Shot(name: "macos_wide_3_air_on_dark", lights: Self.three, select: "key", width: 900,
                 dark: true, air: atmosphereOnAir, macOS: true),
            Shot(name: "macos_wide_0_light", lights: nil, width: 900, dark: false, macOS: true),
            Shot(name: "macos_compact_3_light", lights: Self.three, select: "rim", width: 420,
                 dark: false, macOS: true),
        ]
        XCTAssertEqual(shots.count, 22)

        let dir = Self.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, shot) in shots.enumerated() {
            let url = dir.appendingPathComponent(String(format: "%02d_%@.png", i + 1, shot.name))
            try render(shot, to: url)
        }
    }

    private func style(dark: Bool) -> LightsBarStyle {
        dark
            ? LightsBarStyle(accent: Color(.sRGB, red: 0.33, green: 0.60, blue: 1.0, opacity: 1),
                             text: Color(white: 0.92),
                             background: Color(white: 0.16))
            : LightsBarStyle(accent: Color(.sRGB, red: 0.0, green: 0.45, blue: 0.95, opacity: 1),
                             text: Color(white: 0.12),
                             background: Color(white: 0.95))
    }

    private func render(_ shot: Shot, to url: URL) throws {
        let store = FakeRigStore()
        if let lights = shot.lights { store.setRig(lights, enabled: shot.enabled) }
        if let air = shot.air { store.air = air }
        let controller = LightsController(seams: store.seams)
        controller.begin()
        if let name = shot.select { controller.select(name: name) }

        let root = LightsBar(controller: controller, style: style(dark: shot.dark),
                             onAtmosphere: shot.atmosphere ? {} : nil,
                             atmospherePopover: shot.macOS, lightMenu: shot.macOS, onDone: {})
            .frame(width: shot.width)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.lightsTouchMinimum, shot.touch)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: shot.width, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)

        var rep = draw(host, in: window, width: shot.width)
        if rep.map(Self.isFlat) ?? true {
            // As MovieExportSnapshot does: some controls draw only once their
            // window is ordered in (still far off any screen).
            window.orderFrontRegardless()
            rep = draw(host, in: window, width: shot.width)
        }
        let bitmap = try XCTUnwrap(rep, "\(shot.name): no bitmap")
        XCTAssertFalse(Self.isFlat(bitmap), "\(shot.name): the picture is one flat colour")
        if shot.touch > 0 {
            // 44 pt targets plus the bar's 8 pt padding above and below.
            XCTAssertGreaterThanOrEqual(host.fittingSize.height, shot.touch + 16 - 0.5,
                                        "\(shot.name): the bar's controls are 44 pt tall")
        } else {
            XCTAssertLessThan(host.fittingSize.height, 44 + 16, "\(shot.name): the macOS bar keeps its height")
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        NSLog("LIGHTSBAR_SNAPSHOT: \(url.path)")
        window.orderOut(nil)
    }

    private func draw(_ host: NSView, in window: NSWindow, width: CGFloat) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        let height = max(host.fittingSize.height, 20)
        window.setContentSize(NSSize(width: width, height: height))
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
        let step = 2
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(String(format: "%.2f %.2f %.2f %.2f", c.redComponent, c.greenComponent,
                                   c.blueComponent, c.alphaComponent))
                if seen.count > 2 { return false }
            }
        }
        return true
    }
}
