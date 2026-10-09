import AppKit
import SwiftUI
import XCTest
@testable import RayMol

/// The docked light tools of #623 (LightsSheet.swift): where the tools go by
/// size class, the sheet's heights keyed by the room it has, its drag and
/// keyboard rules and its strings (no drawing), and pictures of the sheet and
/// the side panel drawn offscreen with a controller on fake seams
/// (FakeRigStore, in LightsControllerTests.swift), in the iOS touch profile.

// MARK: - Placement

final class LightsToolsPlacementTests: XCTestCase {
    func testResolveBySizeClass() {
        // iPhone portrait and iPad Slide Over: compact width, regular height.
        XCTAssertEqual(LightsToolsPlacement.resolve(compactWidth: true, compactHeight: false), .bottomSheet)
        // Every iPhone in landscape, the large phones' regular width too.
        XCTAssertEqual(LightsToolsPlacement.resolve(compactWidth: true, compactHeight: true), .sidePanel)
        XCTAssertEqual(LightsToolsPlacement.resolve(compactWidth: false, compactHeight: true), .sidePanel)
        // iPad: regular both ways.
        XCTAssertEqual(LightsToolsPlacement.resolve(compactWidth: false, compactHeight: false), .floating)
    }

    func testNamesAndDetents() {
        XCTAssertEqual(LightsToolsPlacement.allCases.map(\.rawValue),
                       ["column", "bottomSheet", "sidePanel", "floating"])
        XCTAssertEqual(LightsSheetDetent.compact.toggled, .expanded)
        XCTAssertEqual(LightsSheetDetent.expanded.toggled, .compact)
    }
}

// MARK: - The height model

final class LightsSheetModelTests: XCTestCase {
    typealias M = LightsSheetMetrics

    /// A room (viewport plus the sheet's slot, the keyboard ignored) and the
    /// phone it comes from, with the panes hidden (section 4.2 of the plan)
    /// or the console re-shown on the 667 pt phone.
    struct Room {
        var name: String
        var room: CGFloat
        var width: CGFloat
        var bottomInset: CGFloat
    }

    static let rooms = [
        Room(name: "667 console", room: 387, width: 375, bottomInset: 0),
        Room(name: "667", room: 517, width: 375, bottomInset: 0),
        Room(name: "852", room: 663, width: 393, bottomInset: 34),
        Room(name: "956", room: 764, width: 440, bottomInset: 34),
    ]
    /// The header without and with the Shadows hint row (measured: the hint
    /// row is about 22 pt plus 8 pt under it).
    static let headers: [CGFloat] = [44, 76]
    /// The measured rows (all inspector rows with the 44 pt swatches).
    static let rows: CGFloat = 430

    private func heights(_ r: Room, header: CGFloat, rows: CGFloat = LightsSheetModelTests.rows)
        -> LightsSheetHeights {
        let content = LightsSheetModel.expandedContent(header: header, rows: rows, bottomInset: r.bottomInset,
                                                       width: r.width)
        return LightsSheetModel.layout(room: r.room, header: header, bottomInset: r.bottomInset,
                                       expandedContent: content)
    }

    func testCompactContent() {
        XCTAssertEqual(LightsSheetModel.compactContent(header: 44, bottomInset: 0), 24 + 44 + 8 + 164 + 12)
        XCTAssertEqual(LightsSheetModel.compactContent(header: 44, bottomInset: 34), 286)
        // A measured header shorter than 44 counts as 44.
        XCTAssertEqual(LightsSheetModel.compactContent(header: 30, bottomInset: 0), 252)
        XCTAssertEqual(LightsSheetModel.compactContent(header: 76, bottomInset: 0), 284)
    }

    func testHeightsKeyedByRoom() {
        // 667 pt phone, panes hidden: compact fits whole, expanded leaves 180.
        var h = heights(Self.rooms[1], header: 44)
        XCTAssertEqual(h.compact, 252)
        XCTAssertEqual(h.expanded, 337)
        XCTAssertFalse(h.compactScrolls)
        // 852 pt phone.
        h = heights(Self.rooms[2], header: 44)
        XCTAssertEqual(h.compact, 286)
        XCTAssertEqual(h.expanded, 483)
        // 956 pt phone.
        h = heights(Self.rooms[3], header: 44)
        XCTAssertEqual(h.compact, 286)
        XCTAssertEqual(h.expanded, 584)
        // The Shadows hint grows the header, and both heights follow it.
        h = heights(Self.rooms[1], header: 76)
        XCTAssertEqual(h.compact, 284)
        XCTAssertEqual(h.expanded, 337)
    }

    func testCompactClampsAndScrollsWithTheConsoleShown() {
        // The console re-shown on a 667 pt phone: room 387. Compact clamps to
        // 207 (the scene keeps 180) and scrolls; expanded equals compact.
        let h = heights(Self.rooms[0], header: 44)
        XCTAssertEqual(h.compact, 207)
        XCTAssertEqual(h.expanded, 207)
        XCTAssertEqual(h.compactContent, 252)
        XCTAssertTrue(h.compactScrolls)
        // With the hint the header takes more of the same height.
        let hint = heights(Self.rooms[0], header: 76)
        XCTAssertEqual(hint.compact, 207)
        XCTAssertTrue(hint.compactScrolls)
    }

    func testExpandedKeepsTheScene() {
        for r in Self.rooms {
            for header in Self.headers {
                let h = heights(r, header: header)
                for detent in LightsSheetDetent.allCases {
                    XCTAssertGreaterThanOrEqual(r.room - h.height(detent), M.minimumScene,
                                                "\(r.name) header \(header) \(detent)")
                }
                XCTAssertGreaterThanOrEqual(h.expanded, h.compact, "\(r.name) header \(header)")
                // The pinned plan's side lies in 120...194 in every room.
                let canvases = LightsSheetModel.expandedCanvases(sheet: h.expanded, header: header,
                                                                 bottomInset: r.bottomInset, width: r.width)
                XCTAssertTrue(M.pinnedPlanSide.contains(canvases.planSide),
                              "\(r.name) header \(header): side \(canvases.planSide)")
                XCTAssertTrue(M.arcWidth.contains(canvases.arcWidth), "\(r.name): arc \(canvases.arcWidth)")
                // Plan, gap and arc fit across the sheet.
                XCTAssertLessThanOrEqual(canvases.planSide + M.gap + canvases.arcWidth, r.width - 2 * M.inset)
                // Whenever the plan is not at its least side, the rows keep
                // at least 150 pt under it.
                let chrome = M.grabberStrip + header + M.headerGap + M.gap + M.bottomGap + r.bottomInset
                let rows = h.expanded - chrome - canvases.planSide
                if canvases.planSide > M.pinnedPlanSide.lowerBound {
                    XCTAssertGreaterThanOrEqual(rows, M.minimumRows - 0.001, "\(r.name) header \(header)")
                }
            }
        }
        // Any room with space for the least sheet (grabber, header and the
        // home indicator: 102 pt) plus 180 pt keeps 180 pt of scene; a
        // smaller room keeps the least sheet.
        let least: CGFloat = 24 + 44 + 34
        for room in stride(from: least + M.minimumScene, through: 1100, by: 7) {
            let h = LightsSheetModel.layout(room: room, header: 44, bottomInset: 34, expandedContent: 900)
            XCTAssertGreaterThanOrEqual(room - h.expanded, M.minimumScene, "room \(room)")
            XCTAssertGreaterThanOrEqual(room - h.compact, M.minimumScene, "room \(room)")
        }
        let cramped = LightsSheetModel.layout(room: 200, header: 44, bottomInset: 34, expandedContent: 900)
        XCTAssertEqual(cramped.compact, least)
        XCTAssertEqual(cramped.expanded, least)
    }

    func testPinnedSidesInTheWorkedRooms() {
        // 667: the plan at its least side (120); 852 and 956: the largest.
        let small = LightsSheetModel.expandedCanvases(sheet: 337, header: 44, bottomInset: 0, width: 375)
        XCTAssertEqual(small, LightsSheetCanvases(planSide: 120, arcWidth: 98))
        let mid = LightsSheetModel.expandedCanvases(sheet: 483, header: 44, bottomInset: 34, width: 393)
        XCTAssertEqual(mid.planSide, 194)
        XCTAssertEqual(mid.arcWidth, 98)
        let big = LightsSheetModel.expandedCanvases(sheet: 584, header: 44, bottomInset: 34, width: 440)
        XCTAssertEqual(big.planSide, 194)
        // A side between the bounds: height decides.
        XCTAssertEqual(LightsSheetModel.pinnedPlanSide(height: 400, chrome: 100, width: 393), 150)
        // A narrow body caps the side so the narrowest arc still fits.
        XCTAssertEqual(LightsSheetModel.widthCap(250), 250 - 24 - 8 - 58)
        XCTAssertEqual(LightsSheetModel.pinnedPlanSide(height: 900, chrome: 100, width: 250), 160)
        XCTAssertEqual(LightsSheetModel.arcWidth(width: 250, planSide: 160), 58)
        XCTAssertEqual(LightsSheetModel.arcWidth(width: 375, planSide: 120), 98)
        XCTAssertEqual(LightsSheetModel.arcWidth(width: 300, planSide: 194), 74)
    }

    func testExpandedIsNeverTallerThanItsContent() {
        // A tall Slide Over window: the rows are short of the room, so the
        // expanded sheet is as tall as its content, no empty space.
        let content = LightsSheetModel.expandedContent(header: 44, rows: 300, bottomInset: 20, width: 320)
        XCTAssertEqual(content, 24 + 44 + 8 + 194 + 8 + 300 + 12 + 20)
        let h = LightsSheetModel.layout(room: 1000, header: 44, bottomInset: 20, expandedContent: content)
        XCTAssertEqual(h.expanded, content)
        // Content shorter than compact: expanded is compact.
        let tiny = LightsSheetModel.layout(room: 1000, header: 44, bottomInset: 0, expandedContent: 100)
        XCTAssertEqual(tiny.expanded, tiny.compact)
        // Rows not yet measured: the estimate stands in.
        XCTAssertEqual(LightsSheetModel.expandedContent(header: 44, rows: 0, bottomInset: 0, width: 393),
                       LightsSheetModel.expandedContent(header: 44, rows: M.estimatedRows, bottomInset: 0,
                                                        width: 393))
        // The width caps the plan the content counts.
        XCTAssertEqual(LightsSheetModel.expandedContent(header: 44, rows: 300, bottomInset: 0, width: 250),
                       24 + 44 + 8 + 160 + 8 + 300 + 12)
    }

    func testTheAirOnlySheetIsCompact() {
        // No light (#726): the air alone at the compact height in every room,
        // with either header; the slot and the drawn sheet agree (never
        // dragged), and it is never taller than the expanded sheet.
        for r in Self.rooms {
            for header in Self.headers {
                let h = heights(r, header: header)
                let frame = LightsSheetModel.airOnlyFrame(heights: h)
                XCTAssertEqual(frame, LightsSheetFrame(slot: h.compact, sheet: h.compact), "\(r.name) \(header)")
                XCTAssertLessThanOrEqual(frame.slot, h.expanded)
                XCTAssertGreaterThanOrEqual(r.room - frame.slot, M.minimumScene, "\(r.name) \(header)")
            }
        }
    }

    func testDetentSnapping() {
        func d(_ from: LightsSheetDetent, _ t: CGFloat, _ p: CGFloat) -> LightsSheetDetent {
            LightsSheetModel.detent(from: from, translation: t, predicted: p)
        }
        // Up past 40, or a predicted end past 120 up: expanded.
        XCTAssertEqual(d(.compact, -41, -41), .expanded)
        XCTAssertEqual(d(.compact, -10, -121), .expanded)
        // Within both: unchanged.
        XCTAssertEqual(d(.compact, -39, -100), .compact)
        XCTAssertEqual(d(.expanded, 39, 100), .expanded)
        XCTAssertEqual(d(.expanded, 0, 0), .expanded)
        // Down likewise: compact.
        XCTAssertEqual(d(.expanded, 41, 41), .compact)
        XCTAssertEqual(d(.expanded, 10, 121), .compact)
        // A fling's direction wins over the distance dragged.
        XCTAssertEqual(d(.compact, -60, 130), .compact)
        XCTAssertEqual(d(.expanded, 60, -130), .expanded)
        // Already there: stays.
        XCTAssertEqual(d(.expanded, -80, -200), .expanded)
        XCTAssertEqual(d(.compact, 80, 200), .compact)
    }

    func testDragFrameMovesOnlyTheDrawnSheet() {
        let h = LightsSheetHeights(compact: 286, expanded: 483, compactContent: 286)
        // The slot keeps the committed height for the whole drag.
        XCTAssertEqual(LightsSheetModel.dragFrame(detent: .compact, translation: -100, heights: h),
                       LightsSheetFrame(slot: 286, sheet: 386))
        XCTAssertEqual(LightsSheetModel.dragFrame(detent: .compact, translation: -500, heights: h),
                       LightsSheetFrame(slot: 286, sheet: 483))
        XCTAssertEqual(LightsSheetModel.dragFrame(detent: .compact, translation: 50, heights: h),
                       LightsSheetFrame(slot: 286, sheet: 286))
        XCTAssertEqual(LightsSheetModel.dragFrame(detent: .expanded, translation: 120, heights: h),
                       LightsSheetFrame(slot: 483, sheet: 363))
        XCTAssertEqual(LightsSheetModel.dragFrame(detent: .expanded, translation: 0, heights: h),
                       LightsSheetFrame(slot: 483, sheet: 483))
    }

    func testTheExpandedBodyShowsPastHalfway() {
        let h = LightsSheetHeights(compact: 286, expanded: 483, compactContent: 286)
        XCTAssertFalse(LightsSheetModel.showsExpandedBody(detent: .compact, sheet: 286, heights: h, dragging: false))
        XCTAssertTrue(LightsSheetModel.showsExpandedBody(detent: .expanded, sheet: 483, heights: h, dragging: false))
        XCTAssertFalse(LightsSheetModel.showsExpandedBody(detent: .compact, sheet: 380, heights: h, dragging: true))
        XCTAssertTrue(LightsSheetModel.showsExpandedBody(detent: .compact, sheet: 390, heights: h, dragging: true))
        XCTAssertFalse(LightsSheetModel.showsExpandedBody(detent: .expanded, sheet: 300, heights: h, dragging: true))
        // One height (the clamped room): the detent decides.
        let one = LightsSheetHeights(compact: 207, expanded: 207, compactContent: 252)
        XCTAssertTrue(LightsSheetModel.showsExpandedBody(detent: .expanded, sheet: 207, heights: one, dragging: true))
        XCTAssertFalse(LightsSheetModel.showsExpandedBody(detent: .compact, sheet: 207, heights: one, dragging: true))
    }

    func testKeyboardLayout() {
        // No keyboard: the plan shows and nothing rises.
        XCTAssertEqual(LightsSheetModel.keyboardLayout(sheet: 483, header: 44, overlap: 0),
                       LightsSheetKeyboardLayout(showsPinnedPlan: true, rise: 0))
        // A keyboard leaving 79 pt of rows: the plan hides and the sheet
        // rises 17 pt, so 96 pt show.
        XCTAssertEqual(LightsSheetModel.keyboardLayout(sheet: 483, header: 44, overlap: 336),
                       LightsSheetKeyboardLayout(showsPinnedPlan: false, rise: 17))
        // Enough rows left: hidden plan, no rise.
        XCTAssertEqual(LightsSheetModel.keyboardLayout(sheet: 483, header: 44, overlap: 100),
                       LightsSheetKeyboardLayout(showsPinnedPlan: false, rise: 0))
        // A taller header leaves fewer rows.
        XCTAssertEqual(LightsSheetModel.keyboardLayout(sheet: 483, header: 76, overlap: 336).rise, 49)
        // The overlap from the frames (window coordinates).
        XCTAssertEqual(LightsSheetModel.keyboardOverlap(bottom: 852, keyboardTop: nil), 0)
        XCTAssertEqual(LightsSheetModel.keyboardOverlap(bottom: 852, keyboardTop: 516), 336)
        XCTAssertEqual(LightsSheetModel.keyboardOverlap(bottom: 852, keyboardTop: 852), 0)
        XCTAssertEqual(LightsSheetModel.keyboardOverlap(bottom: 500, keyboardTop: 516), 0)
    }

    func testSideCanvases() {
        // iPhone landscape's trailing slot.
        let side = LightsSheetModel.sideCanvases(size: CGSize(width: 360, height: 393), header: 44)
        XCTAssertEqual(side.planSide, 393 - (44 + 8 + 8 + 12) - 150)
        XCTAssertEqual(side.arcWidth, 98)
        // A short panel keeps the least side; a tall one the largest.
        XCTAssertEqual(LightsSheetModel.sideCanvases(size: CGSize(width: 360, height: 300), header: 44).planSide,
                       120)
        XCTAssertEqual(LightsSheetModel.sideCanvases(size: CGSize(width: 360, height: 600), header: 44).planSide,
                       194)
    }

    @MainActor
    func testCanvasLayoutsFollowTheSizes() throws {
        let store = FakeRigStore()
        store.setRig(["key", "fill", "rim"])
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let state = try XCTUnwrap(LightsOrbitState(controller))
        let compact = CGSize(width: 164, height: 164)
        let plan = OrbitCanvases.planLayout(state, frozenExtent: nil, size: compact)
        XCTAssertEqual(plan.size, compact)
        XCTAssertEqual(plan.outerRadius, 164 / 2 - LightsOrbitMetrics.planMargin)
        XCTAssertEqual(OrbitCanvases.planLayout(state, frozenExtent: nil).size, LightsOrbitMetrics.planSize)
        // The widest pinned arc: radius 82 (the card's is 42).
        XCTAssertEqual(PitchArcLayout(size: CGSize(width: 98, height: 194)).radius, 82)
        XCTAssertEqual(PitchArcLayout().radius, 42)
    }
}

// MARK: - Strings

final class LightsSheetStateTests: XCTestCase {
    func testStrings() {
        XCTAssertEqual(LightsSheetState.grabberLabel, "Light sheet")
        XCTAssertEqual(LightsSheetState.grabberValue(.compact), "Compact")
        XCTAssertEqual(LightsSheetState.grabberValue(.expanded), "Expanded")
        XCTAssertEqual(LightsSheetState.moreTitle(expanded: false), "More")
        XCTAssertEqual(LightsSheetState.moreTitle(expanded: true), "Less")
        XCTAssertEqual(LightsSheetState.moreLabel(expanded: false), "Show all light settings")
        XCTAssertEqual(LightsSheetState.moreLabel(expanded: true), "Show fewer light settings")
        XCTAssertEqual(LightsSheetState.identifier, "lights.sheet")
        XCTAssertEqual(LightsSheetState.grabberIdentifier, "lights.sheet.grabber")
        XCTAssertEqual(LightsSheetState.moreIdentifier, "lights.sheet.more")
        XCTAssertEqual(LightsSheetState.sideIdentifier, "lights.side")
        XCTAssertEqual(LightsSheetState.colourIdentifier, "lights.sheet.colour")
        XCTAssertEqual(LightsSheetState.swatchIdentifier("Warm"), "lights.sheet.swatch.warm")
        XCTAssertEqual(LightsSheetState.airIdentifier, "lights.sheet.air")
        XCTAssertEqual(LightsSheetState.sideAirIdentifier, "lights.side.air")
        XCTAssertEqual(LightsSheetState.atmosphereAnchor, "lights.sheet.atmosphere.section")
    }

    func testTheKeyboardScrollsToTheFocusedRow() {
        // Uncovered: no scroll, whatever is focused.
        XCTAssertNil(LightsSheetState.scrollTarget(focusedRow: nil, covered: false))
        XCTAssertNil(LightsSheetState.scrollTarget(focusedRow: AtmosphereCardIDs.row(.dustSpeed), covered: false))
        // Covered with an Atmosphere field focused: that row, not the rows'
        // top (a field at the bottom of the rows would stay under the
        // keyboard).
        for p in AirParameter.allCases {
            XCTAssertEqual(LightsSheetState.scrollTarget(focusedRow: AtmosphereCardIDs.row(p), covered: true),
                           AtmosphereCardIDs.row(p))
        }
        // Covered with an inspector field focused (it reports no row): the
        // rows' top, as before.
        XCTAssertEqual(LightsSheetState.scrollTarget(focusedRow: nil, covered: true), LightsSheetState.rowsAnchor)
    }

    @MainActor
    func testTheAirOnlySheetShowsWithNoLight() {
        let store = FakeRigStore()
        let controller = LightsController(seams: store.seams)
        // Outside Lights mode: nothing.
        XCTAssertFalse(LightsSheet.showsAirOnly(controller))
        // No rig: the air alone.
        controller.begin()
        XCTAssertTrue(LightsSheet.showsAirOnly(controller))
        XCTAssertNil(LightsOrbitState(controller))
        controller.end()
        // A rig with no light (as the switch makes with no rig): the air
        // alone.
        store.setRig([], enabled: false)
        store.air = atmosphereOnAir
        controller.begin()
        XCTAssertTrue(LightsSheet.showsAirOnly(controller))
        controller.end()
        // A light: the full sheet.
        store.setRig(["key", "fill", "rim"])
        controller.begin()
        XCTAssertFalse(LightsSheet.showsAirOnly(controller))
        XCTAssertNotNil(LightsOrbitState(controller))
        controller.end()
        XCTAssertFalse(LightsSheet.showsAirOnly(controller))
    }

    func testVoiceOverAdjustments() {
        // Increment expands, decrement compacts, from either height.
        for detent in LightsSheetDetent.allCases {
            XCTAssertEqual(LightsSheetState.adjusted(detent, increment: true), .expanded)
            XCTAssertEqual(LightsSheetState.adjusted(detent, increment: false), .compact)
        }
    }

    func testColourValue() {
        XCTAssertEqual(LightsSheetState.colourValue(swatchIndex: nil), "Custom")
        XCTAssertEqual(LightsSheetState.colourValue(swatchIndex: 99), "Custom")
        for (i, swatch) in LightColour.swatches.enumerated() {
            XCTAssertEqual(LightsSheetState.colourValue(swatchIndex: i), swatch.name)
        }
    }
}

// MARK: - The phone wiring (Part 4)

/// What ContentView's phone wiring decides with pure rules: the panes that
/// give way to the portrait sheet, the `tools=` log field and the orbit
/// canvases the DEBUG orbit tokens lay out at in each placement.
final class LightsPhoneWiringTests: XCTestCase {
    typealias M = LightsSheetMetrics

    func testPanesGiveWayWhileDocked() {
        // Outside the docked sheet the stored flag decides, as before.
        for stored in [false, true] {
            for override in [false, true] {
                XCTAssertEqual(LightsPaneRule.shows(stored: stored, override: override, docked: false), stored)
            }
        }
        // Docked: hidden until the rail brings the pane back (the override),
        // and never shown with the stored flag off.
        XCTAssertFalse(LightsPaneRule.shows(stored: true, override: false, docked: true))
        XCTAssertTrue(LightsPaneRule.shows(stored: true, override: true, docked: true))
        XCTAssertFalse(LightsPaneRule.shows(stored: false, override: true, docked: true))
        XCTAssertFalse(LightsPaneRule.shows(stored: false, override: false, docked: true))
    }

    func testThePillSetterKeepsTheRuleConsistent() {
        // The rail pill's setter writes the override and the stored flag
        // together (ContentView's consoleBinding / sequenceBinding), so what
        // the pill shows always follows the tap while docked.
        var stored = true
        var override = false
        func set(_ value: Bool) { override = value; stored = value }
        XCTAssertFalse(LightsPaneRule.shows(stored: stored, override: override, docked: true))
        set(true)
        XCTAssertTrue(LightsPaneRule.shows(stored: stored, override: override, docked: true))
        set(false)
        XCTAssertFalse(LightsPaneRule.shows(stored: stored, override: override, docked: true))
        XCTAssertFalse(stored, "a pane the user closed stays closed after the mode")
    }

    func testPanesSummary() {
        XCTAssertEqual(LightsPaneRule.summary(console: false, sequence: false), "hidden")
        XCTAssertEqual(LightsPaneRule.summary(console: true, sequence: false), "console")
        XCTAssertEqual(LightsPaneRule.summary(console: false, sequence: true), "sequence")
        XCTAssertEqual(LightsPaneRule.summary(console: true, sequence: true), "both")
    }

    func testToolsSummary() {
        XCTAssertEqual(LightsSheetState.toolsSummary(placement: .bottomSheet, detent: .compact), "sheet:compact")
        XCTAssertEqual(LightsSheetState.toolsSummary(placement: .bottomSheet, detent: .expanded), "sheet:expanded")
        for detent in LightsSheetDetent.allCases {
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .sidePanel, detent: detent), "side")
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .floating, detent: detent), "float:bl")
            for corner in LightsFloatCorner.allCases {
                XCTAssertEqual(LightsSheetState.toolsSummary(placement: .floating, detent: detent, corner: corner),
                               "float:\(corner.rawValue)")
            }
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .column, detent: detent), "column")
            // The phone's air-only sheet (no light, #726), whatever the
            // detent; the float and the column have no air-only form.
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .bottomSheet, detent: detent, airOnly: true),
                           "sheet:air")
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .sidePanel, detent: detent, airOnly: true),
                           "side:air")
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .floating, detent: detent, airOnly: true),
                           "float:bl")
            XCTAssertEqual(LightsSheetState.toolsSummary(placement: .column, detent: detent, airOnly: true),
                           "column")
        }
    }

    func testOrbitTokensUseTheActiveCanvases() {
        // The 852 pt phone's room under the bar.
        let room = CGSize(width: 393, height: 663)
        let content = LightsSheetModel.expandedContent(header: 44, rows: 430, bottomInset: 34, width: room.width)
        let heights = LightsSheetModel.layout(room: room.height, header: 44, bottomInset: 34,
                                              expandedContent: content)
        func sizes(_ placement: LightsToolsPlacement, _ detent: LightsSheetDetent,
                   side: CGSize = .zero) -> (plan: CGSize, arc: CGSize) {
            LightsSheetModel.activeCanvases(placement: placement, detent: detent, heights: heights, room: room,
                                            header: 44, bottomInset: 34, sideSize: side)
        }
        // Compact sheet: the 164 pt plan.
        XCTAssertEqual(sizes(.bottomSheet, .compact).plan, CGSize(width: 164, height: 164))
        // Expanded sheet: the pinned canvases at the expanded height.
        let expanded = sizes(.bottomSheet, .expanded)
        let pinned = LightsSheetModel.expandedCanvases(sheet: heights.expanded, header: 44, bottomInset: 34,
                                                       width: room.width)
        XCTAssertEqual(expanded.plan, pinned.planSize)
        XCTAssertEqual(expanded.arc, pinned.arcSize)
        XCTAssertEqual(expanded.plan, CGSize(width: 194, height: 194))
        XCTAssertEqual(expanded.arc, CGSize(width: 98, height: 194))
        // Side panel: its canvases in the panel below the top inset.
        let panel = CGSize(width: 393, height: 380)
        let side = sizes(.sidePanel, .compact, side: panel)
        let expect = LightsSheetModel.sideCanvases(size: CGSize(width: 393, height: 380 - M.sideTopInset),
                                                   header: 44)
        XCTAssertEqual(side.plan, expect.planSize)
        XCTAssertEqual(side.arc, expect.arcSize)
        // The column and the float: the card's sizes.
        for placement in [LightsToolsPlacement.column, .floating] {
            XCTAssertEqual(sizes(placement, .expanded).plan, LightsOrbitMetrics.planSize)
            XCTAssertEqual(sizes(placement, .expanded).arc, LightsOrbitMetrics.arcSize)
        }
    }
}

// MARK: - Pictures

/// The sheet drawn offscreen, as LightsInspectorSnapshotTests draws the card:
/// an NSHostingView in a borderless window far off any screen, then
/// cacheDisplay into a bitmap (the app's own view drawn into memory, no
/// screen capture), in the iOS touch profile (44 pt targets) unless a shot
/// says otherwise. A room-high frame holds a neutral viewport above the
/// sheet's slot, and the host measures the header and the rows and lays the
/// sheet out with LightsSheetModel, as ContentView does. PNGs go to
/// $RAYMOL_LIGHTSSHEET_SNAPSHOT_DIR (TEST_RUNNER_RAYMOL_LIGHTSSHEET_SNAPSHOT_DIR
/// on the xcodebuild line), else NSTemporaryDirectory()/
/// raymol-lightssheet-snapshots; each is logged as
/// `LIGHTSSHEET_SNAPSHOT: <path>`. Drawing must write nothing.
@MainActor
final class LightsSheetSnapshotTests: XCTestCase {
    private enum Kind {
        case bottom(LightsSheetDetent)
        case side
        case palette
    }

    private struct Shot {
        var name: String
        var kind: Kind = .bottom(.compact)
        var dark = false
        var width: CGFloat = 375
        /// The room (viewport plus slot); the side panel's height.
        var room: CGFloat = 517
        var bottomInset: CGFloat = 0
        var sceneShadowsOn: Bool? = true
        var touch: CGFloat = 44
        /// The owner's Atmosphere reveal request (the header button's path).
        var reveal = 0
        var setUp: (FakeRigStore) -> Void = LightsSheetSnapshotTests.sketchKey
        var check: (Measured) -> Void = { _ in }
    }

    /// What the host measured.
    final class Measured {
        var header: CGFloat = 0
        var rows: CGFloat = 0
        /// The sheet's slot as laid out, and its detent after the shot.
        var sheet: CGFloat = 0
        var detent: LightsSheetDetent?
        /// How far the rows are scrolled (the largest vertical offset of the
        /// NSScrollViews behind SwiftUI's ScrollViews; only the rows scroll
        /// in the expanded sheet).
        var scrolled: CGFloat = 0
    }

    /// The sheet's compact height in `room` with the measured header.
    private static func compact(_ m: Measured, room: CGFloat, bottomInset: CGFloat) -> CGFloat {
        LightsSheetModel.layout(room: room, header: m.header, bottomInset: bottomInset, expandedContent: 0).compact
    }

    private static var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTSSHEET_SNAPSHOT_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("raymol-lightssheet-snapshots", isDirectory: true)
    }

    /// Sketch 3's key light in a three_point rig.
    private static func sketchKey(_ store: FakeRigStore) {
        store.setRig(["key", "fill", "rim"])
        store.lights[0].orbit = -45
        store.lights[0].pitch = 35
        store.lights[0].radius = 3
        store.lights[0].intensity = 1.8
        store.lights[0].warmth = 3800
        store.lights[0].beam = 40
        store.lights[0].softness = 0.5
        store.lights[1].orbit = 55
        store.lights[1].pitch = 5
        store.lights[1].radius = 3
        store.lights[2].orbit = 165
        store.lights[2].pitch = 40
        store.lights[2].radius = 3
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    func testRenderSnapshots() throws {
        let shots: [Shot] = [
            // Compact on a 667 pt phone (room 517) and an 852 pt phone (room
            // 663, home indicator 34), light and dark.
            Shot(name: "compact_375_light", check: { m in
                XCTAssertGreaterThanOrEqual(m.header, 44, "the header row is at least 44 pt")
                XCTAssertLessThan(m.header, 60, "no hint row: one 44 pt row")
            }),
            Shot(name: "compact_375_dark", dark: true),
            Shot(name: "compact_393_light", width: 393, room: 663, bottomInset: 34),
            Shot(name: "compact_393_dark", dark: true, width: 393, room: 663, bottomInset: 34),
            // The key casts a shadow while the scene's Shadows switch is off:
            // the header grows by the hint row (measured), with Turn On.
            Shot(name: "compact_shadows_hint_light", width: 393, room: 663, bottomInset: 34,
                 sceneShadowsOn: false, setUp: { store in
                     Self.sketchKey(store)
                     store.lights[0].shadow = true
                 }, check: { m in
                     XCTAssertGreaterThan(m.header, 60, "the hint row adds to the measured header")
                 }),
            // The rig switched off: 'Lights off' under the name, dimmed.
            Shot(name: "compact_lights_off_light", setUp: { store in
                Self.sketchKey(store)
                store.enabled = false
            }),
            // The console re-shown on a 667 pt phone (room 387): compact
            // clamps to 207 and its body scrolls.
            Shot(name: "compact_console_387_light", room: 387),
            // Pulled up: pinned plan and arc, the rows scrolling below.
            Shot(name: "expanded_852_light", kind: .bottom(.expanded), width: 393, room: 663, bottomInset: 34,
                 check: { m in
                     XCTAssertGreaterThan(m.rows, 300, "the rows are measured once shown")
                     // The first expanded layout uses the estimate: it stays
                     // near the measured three_point rows plus the
                     // Atmosphere section in the 44 pt profile.
                     XCTAssertEqual(m.rows, LightsSheetMetrics.estimatedRows, accuracy: 40, "estimatedRows vs measured \(m.rows)")
                     // Not revealed: the rows are not scrolled (the control
                     // for the revealed shot's check).
                     XCTAssertLessThan(m.scrolled, 1, "no scroll without a reveal")
                 }),
            Shot(name: "expanded_852_dark", kind: .bottom(.expanded), dark: true, width: 393, room: 663,
                 bottomInset: 34),
            Shot(name: "expanded_667_light", kind: .bottom(.expanded)),
            // iPhone landscape's trailing panel.
            Shot(name: "side_panel_light", kind: .side, width: 360, room: 393),
            // The Colour button's popover content.
            Shot(name: "colour_palette_light", kind: .palette, width: 220, room: 230),
            // The macOS profile (no 44 pt frames) for comparison.
            Shot(name: "compact_375_mac_profile_light", touch: 0),
            // The Atmosphere section (#726). The header's Atmosphere button
            // path from compact: the sheet expands and the rows scroll to
            // the section (the air on, so the button is lit).
            Shot(name: "atmosphere_revealed_852_light", width: 393, room: 663, bottomInset: 34, reveal: 1,
                 setUp: { store in
                     Self.sketchKey(store)
                     store.air = atmosphereOnAir
                 }, check: { m in
                     XCTAssertEqual(m.detent, .expanded, "the reveal expands a compact sheet")
                     // Scrolled past the inspector rows (about 430 pt) to
                     // the section.
                     XCTAssertGreaterThan(m.scrolled, 300, "the rows scroll to the Atmosphere section")
                 }),
            Shot(name: "atmosphere_revealed_667_dark", dark: true, reveal: 1, setUp: { store in
                Self.sketchKey(store)
                store.air = atmosphereOnAir
            }, check: { m in
                XCTAssertEqual(m.detent, .expanded)
                XCTAssertGreaterThan(m.scrolled, 300, "the rows scroll to the Atmosphere section")
            }),
            // The header at 375 pt with a long light name: the menu label
            // truncates; the Atmosphere button, Shadow, Pin and More keep
            // their 44 pt targets on one 44 pt row.
            Shot(name: "header_375_long_name_light", setUp: { store in
                Self.sketchKey(store)
                store.lights[0].name = "key_light_over_the_left_shoulder"
                store.air = atmosphereOnAir
            }, check: { m in
                XCTAssertGreaterThanOrEqual(m.header, 44)
                XCTAssertLessThan(m.header, 60, "one header row with a long name")
            }),
            // No light: the air alone at the compact height, even with the
            // expanded detent; no rows height reported (that is the light's).
            Shot(name: "air_only_no_rig_852_light", kind: .bottom(.expanded), width: 393, room: 663,
                 bottomInset: 34, setUp: { _ in }, check: { m in
                     XCTAssertEqual(m.sheet, Self.compact(m, room: 663, bottomInset: 34), accuracy: 0.5)
                     XCTAssertEqual(m.rows, 0, "the air rows are not the light's rows")
                     XCTAssertGreaterThanOrEqual(m.header, 44)
                     XCTAssertLessThan(m.header, 60, "the Atmosphere header is one row")
                     XCTAssertEqual(m.detent, .expanded, "the detent is left for when a light returns")
                 }),
            // The empty rig the switch makes with no rig, the air on.
            Shot(name: "air_only_empty_rig_375_dark", dark: true, setUp: { store in
                store.setRig([], enabled: false)
                store.air = atmosphereOnAir
            }, check: { m in
                XCTAssertEqual(m.sheet, Self.compact(m, room: 517, bottomInset: 0), accuracy: 0.5)
            }),
            // iPhone landscape's trailing panel with no light.
            Shot(name: "air_only_side_panel_light", kind: .side, width: 360, room: 393, setUp: { _ in }),
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
        shot.setUp(store)
        let controller = LightsController(seams: store.seams)
        controller.begin()
        let writesBefore = (store.numberWrites.count, store.vectorWrites.count, store.performed.count)
        let style = LightsInspectorSnapshotTests.style(dark: shot.dark)
        let viewport = shot.dark ? Color(white: 0.08) : Color(white: 0.55)
        let measured = Measured()

        let content: AnyView
        switch shot.kind {
        case .bottom(let detent):
            content = AnyView(SheetHost(controller: controller, style: style, detent: detent,
                                        room: shot.room, width: shot.width, bottomInset: shot.bottomInset,
                                        sceneShadowsOn: shot.sceneShadowsOn, viewport: viewport,
                                        reveal: shot.reveal, measured: measured))
        case .side:
            content = AnyView(
                HStack(spacing: 0) {
                    viewport
                    LightsSheet(controller: controller, style: style, placement: .side,
                                detent: .constant(.expanded),
                                heights: LightsSheetHeights(compact: 0, expanded: 0, compactContent: 0),
                                sceneShadowsOn: shot.sceneShadowsOn, atmosphereRevealRequest: shot.reveal)
                        .frame(width: shot.width)
                }
                .frame(width: shot.width + 200, height: shot.room))
        case .palette:
            content = AnyView(
                LightsColourPalette(controller: controller, style: style)
                    .background(style.background)
                    .padding(10)
                    .frame(width: shot.width, height: shot.room)
                    .background(viewport))
        }
        let root = content.environment(\.lightsTouchMinimum, shot.touch)
        let size: NSSize
        if case .side = shot.kind {
            size = NSSize(width: shot.width + 200, height: shot.room)
        } else {
            size = NSSize(width: shot.width, height: shot.room)
        }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)

        // Two passes: the first measures the header and the rows, the second
        // draws the sheet at the heights they give.
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
        NSLog("LIGHTSSHEET_SNAPSHOT: \(url.path)")
        measured.scrolled = Self.scrollOffset(in: host)
        window.orderOut(nil)
        shot.check(measured)

        XCTAssertEqual(store.numberWrites.count, writesBefore.0,
                       "\(shot.name): drawing wrote \(store.numberWrites.dropFirst(writesBefore.0))")
        XCTAssertEqual(store.vectorWrites.count, writesBefore.1, "\(shot.name): drawing wrote a colour")
        XCTAssertEqual(store.performed.count, writesBefore.2,
                       "\(shot.name): drawing pressed \(store.performed.dropFirst(writesBefore.2))")
    }

    /// The viewport above the docked sheet, laid out as ContentView does:
    /// the measured header and rows give the heights; the slot takes the
    /// committed height and the viewport the rest.
    private struct SheetHost: View {
        let controller: LightsController
        let style: LightsBarStyle
        @State var detent: LightsSheetDetent
        let room: CGFloat
        let width: CGFloat
        let bottomInset: CGFloat
        let sceneShadowsOn: Bool?
        let viewport: Color
        let reveal: Int
        let measured: Measured
        @State private var header: CGFloat = 0
        @State private var rows: CGFloat = 0

        var body: some View {
            let content = LightsSheetModel.expandedContent(header: header, rows: rows, bottomInset: bottomInset,
                                                           width: width)
            let heights = LightsSheetModel.layout(room: room, header: header, bottomInset: bottomInset,
                                                  expandedContent: content)
            VStack(spacing: 0) {
                viewport
                LightsSheet(controller: controller, style: style, placement: .bottom, detent: $detent,
                            heights: heights, bottomInset: bottomInset, sceneShadowsOn: sceneShadowsOn,
                            atmosphereRevealRequest: reveal)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { measured.sheet = g.size.height }
                            .onChange(of: g.size.height) { _, height in measured.sheet = height }
                    })
            }
            .frame(width: width, height: room)
            .onAppear { measured.detent = detent }
            .onChange(of: detent) { _, now in measured.detent = now }

            .onPreferenceChange(LightsSheetHeaderHeightKey.self) { value in
                header = value
                measured.header = value
            }
            .onPreferenceChange(LightsSheetRowsHeightKey.self) { value in
                rows = value
                measured.rows = value
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

    /// The largest vertical scroll offset among the NSScrollViews under
    /// `view` (SwiftUI's ScrollView on macOS).
    private static func scrollOffset(in view: NSView) -> CGFloat {
        var offset: CGFloat = 0
        if let scroll = view as? NSScrollView {
            offset = abs(scroll.contentView.bounds.origin.y)
        }
        for sub in view.subviews { offset = max(offset, scrollOffset(in: sub)) }
        return offset
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
