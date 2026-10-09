// LightsSheet.swift — the light tools docked on phones (#623, spec §9, sketch 4).
//
// Where the light tools go is decided by size class, never by device
// (LightsToolsPlacement): the macOS side column; on compact width with
// regular height (iPhone portrait, iPad Slide Over) a two-height bottom sheet
// docked under the viewport; on compact height (every iPhone in landscape)
// the same tools in the trailing panel slot; on regular width and height
// (iPad) the floating orbit card (LightsFloatingTools, Part 5).
//
// The sheet (LightsSheet, `.bottom`):
// - a grabber strip and a measured header row (the inspector's header: the
//   light menu, the status line, Shadow and Pin, the cap notice and the
//   Shadows hint) with More/Less;
// - compact: the plan (164 pt) beside Pitch, Intensity and one 44 pt Colour
//   button (LightsCompactRows);
// - expanded: the plan and the pitch arc pinned under the header, and every
//   inspector row scrolling below them (only the rows scroll, so the
//   canvases' drags and pinch never fight a ScrollView).
// Its heights follow the room it has (LightsSheetModel: the scene keeps at
// least 180 pt in both heights). A grabber drag moves the drawn sheet over
// the viewport without resizing it; on release the sheet docks once, the
// owner freezing the drawable for that one snap (`onMoving`).
//
// The side panel (`.side`): the header row and the expanded body filling the
// panel's height, no grabber.
//
// The Atmosphere section (#726): the rig's haze and dust
// (LightsAtmosphereCard, `.section`) follow the inspector rows in the
// expanded body. An Atmosphere button in the header expands a compact sheet
// and scrolls to it (`revealAtmosphere()`).
//
// With no light (no rig, or a rig with no light) the sheet shows the air
// alone (`showsAirOnly`): at `.bottom` the compact height whatever the
// detent, with the Atmosphere header (title and switch) and its rows
// scrolling below it, no grabber drag and no More; at `.side` the same header
// and rows filling the panel. So the no-lights hint and the switch are
// reachable on a phone too.
//
// While a field in the rows has the keyboard (LightsFieldFocusKey) the
// owner keeps the viewport's size; the sheet reads the keyboard's overlap
// itself (iOS only), hides the pinned canvases, pads the rows, scrolls the
// focused row into view (an Atmosphere row reports itself through
// LightsSheetScrollTargetKey; otherwise the rows' top), and rises over the
// scene when fewer than 96 pt of rows would show.
//
// Every edit goes through the controller's typed API (setIfChanged,
// setColour), LightsOrbitInteraction (inside OrbitCanvases) and the
// Atmosphere card's typed air API: the bridge setters, no Python per tick
// (#610). This file names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py and lighting_touch.py check that).
// The pure parts (placement, metrics, the height model, the strings) are
// unit-tested in LightsSheetTests.swift.

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Placement

/// Where the light tools go.
enum LightsToolsPlacement: String, Equatable, CaseIterable {
    /// The macOS side column under the Lights bar (#620, #621).
    case column
    /// The two-height bottom sheet (compact width, regular height).
    case bottomSheet
    /// The trailing panel slot (compact height: iPhone landscape).
    case sidePanel
    /// The floating orbit card and the top-trailing inspector (iPad).
    case floating

    /// The placement for a size class. Bools, not UserInterfaceSizeClass, so
    /// the macOS tests cover every case. Compact height wins (a large phone's
    /// landscape width is regular), then compact width; else the float.
    static func resolve(compactWidth: Bool, compactHeight: Bool) -> LightsToolsPlacement {
        if compactHeight { return .sidePanel }
        if compactWidth { return .bottomSheet }
        return .floating
    }
}

/// The sheet's two heights. Plain view state, seeded per mode entry and
/// never persisted.
enum LightsSheetDetent: String, Equatable, CaseIterable {
    case compact, expanded

    var toggled: LightsSheetDetent { self == .compact ? .expanded : .compact }
}

// MARK: - Metrics

/// The sheet's fixed sizes, shared by the drawing, the height model and the
/// tests.
enum LightsSheetMetrics {
    /// The full-width strip holding the grabber, and the grabber itself.
    static let grabberStrip: CGFloat = 24
    static let grabberSize = CGSize(width: 36, height: 5)
    /// The header row's least height (its 44 pt targets); it is measured.
    static let minimumHeader: CGFloat = 44
    /// Between the header and the body.
    static let headerGap: CGFloat = 8
    /// Above the Atmosphere section, under the inspector rows.
    static let sectionGap: CGFloat = 8
    /// The compact body: the plan (164 x 164) beside two 48 pt two-line
    /// sliders and a 44 pt Colour button with 8 pt gaps (156).
    static let compactBody: CGFloat = 164
    static let compactPlanSide: CGFloat = 164
    static let sliderRowHeight: CGFloat = 48
    static let colourButtonHeight: CGFloat = 44
    /// Under the body.
    static let bottomGap: CGFloat = 12
    /// The scene's least height above the sheet, in both heights.
    static let minimumScene: CGFloat = 180
    /// The rows' least height under the pinned plan (while the room allows).
    static let minimumRows: CGFloat = 150
    /// The pinned plan's side, and the arc canvas's width beside it.
    static let pinnedPlanSide: ClosedRange<CGFloat> = 120...194
    static let arcWidth: ClosedRange<CGFloat> = 58...98
    /// The sheet's side insets, and the gap between the canvases and rows.
    static let inset: CGFloat = 12
    static let gap: CGFloat = 8
    /// A release past this drag, or past this predicted end, changes height.
    static let snapDistance: CGFloat = 40
    static let flingDistance: CGFloat = 120
    /// The rows a keyboard always leaves showing above it.
    static let keyboardRows: CGFloat = 96
    /// The rows' height before they are first measured: the three_point
    /// key's inspector rows plus the Atmosphere section in the 44 pt profile
    /// (measured 603; LightsSheetSnapshotTests keeps it within 40 pt).
    static let estimatedRows: CGFloat = 600
    /// The top corners' radius.
    static let cornerRadius: CGFloat = 12
    /// Above the side panel's header.
    static let sideTopInset: CGFloat = 4
    /// The snap after a release, a tap or a VoiceOver adjustment.
    static let snapDuration = 0.22
}

// MARK: - The height model

/// The sheet's two heights for a room.
struct LightsSheetHeights: Equatable {
    var compact: CGFloat
    var expanded: CGFloat
    /// What the compact body needs; below it the compact body scrolls.
    var compactContent: CGFloat

    var compactScrolls: Bool { compact < compactContent - 0.5 }

    func height(_ detent: LightsSheetDetent) -> CGFloat {
        detent == .compact ? compact : expanded
    }
}

/// The slot the sheet keeps in the layout (the committed height, so the
/// viewport above never resizes during a drag) and the sheet as drawn.
struct LightsSheetFrame: Equatable {
    var slot: CGFloat
    var sheet: CGFloat
}

/// The pinned canvases of the expanded sheet or the side panel.
struct LightsSheetCanvases: Equatable {
    var planSide: CGFloat
    var arcWidth: CGFloat

    var planSize: CGSize { CGSize(width: planSide, height: planSide) }
    var arcSize: CGSize { CGSize(width: arcWidth, height: planSide) }
}

/// What a keyboard over the sheet changes.
struct LightsSheetKeyboardLayout: Equatable {
    /// The pinned plan and arc show (hidden while a keyboard overlaps).
    var showsPinnedPlan: Bool
    /// How far the sheet rises over the scene, so `keyboardRows` of rows show.
    var rise: CGFloat
}

/// The sheet's heights and motion, keyed by the room it has (the measured
/// height of the viewport plus the sheet's slot, the keyboard ignored),
/// never by the phone's size. Pure.
enum LightsSheetModel {
    typealias M = LightsSheetMetrics

    /// The header's height: as measured, at least the 44 pt minimum.
    static func header(_ measured: CGFloat) -> CGFloat {
        max(measured, M.minimumHeader)
    }

    /// The compact sheet's natural height: grabber, header, gap, the 164 pt
    /// body, the bottom gap and the home indicator's inset.
    static func compactContent(header: CGFloat, bottomInset: CGFloat) -> CGFloat {
        M.grabberStrip + Self.header(header) + M.headerGap + M.compactBody + M.bottomGap + bottomInset
    }

    /// The expanded sheet's natural height for rows `rows` points tall (0:
    /// not measured yet, the estimate then) at `width`: the canvases at their
    /// largest pinned side, then the rows.
    static func expandedContent(header: CGFloat, rows: CGFloat, bottomInset: CGFloat,
                                width: CGFloat) -> CGFloat {
        let rows = rows > 0 ? rows : M.estimatedRows
        let side = min(M.pinnedPlanSide.upperBound, widthCap(width))
        return M.grabberStrip + Self.header(header) + M.headerGap + side + M.gap + rows + M.bottomGap
            + bottomInset
    }

    /// The two heights for `room`:
    /// - compact = the compact content, clamped between the grabber and the
    ///   header (the least sheet) and `room - minimumScene` (the body then
    ///   scrolls: only with re-shown panes on the smallest phones);
    /// - expanded = max(compact, min(room - minimumScene, expandedContent)):
    ///   never taller than its content, never shorter than compact.
    static func layout(room: CGFloat, header: CGFloat, bottomInset: CGFloat,
                       expandedContent: CGFloat) -> LightsSheetHeights {
        let h = Self.header(header)
        let content = compactContent(header: h, bottomInset: bottomInset)
        let least = M.grabberStrip + h + bottomInset
        let most = room - M.minimumScene
        let compact = max(least, min(content, most))
        let expanded = max(compact, min(most, expandedContent))
        return LightsSheetHeights(compact: compact, expanded: expanded, compactContent: content)
    }

    /// The widest pinned plan `width` leaves room for beside the narrowest
    /// arc.
    static func widthCap(_ width: CGFloat) -> CGFloat {
        max(width - 2 * M.inset - M.gap - M.arcWidth.lowerBound, 1)
    }

    /// The pinned plan's side in a body `height` points tall, around
    /// `chrome` points of everything else: what leaves `minimumRows` of rows,
    /// clamped into 120...194, and never wider than `width` allows.
    static func pinnedPlanSide(height: CGFloat, chrome: CGFloat, width: CGFloat) -> CGFloat {
        let byHeight = height - chrome - M.minimumRows
        let clamped = min(max(byHeight, M.pinnedPlanSide.lowerBound), M.pinnedPlanSide.upperBound)
        return min(clamped, widthCap(width))
    }

    /// The arc canvas beside a plan of `side` at `width`: what is left, 58
    /// to 98 pt wide (an arc radius up to 82 pt).
    static func arcWidth(width: CGFloat, planSide side: CGFloat) -> CGFloat {
        let left = width - 2 * M.inset - M.gap - side
        return min(max(left, M.arcWidth.lowerBound), M.arcWidth.upperBound)
    }

    /// The expanded sheet's canvases at drawn height `sheet`.
    static func expandedCanvases(sheet: CGFloat, header: CGFloat, bottomInset: CGFloat,
                                 width: CGFloat) -> LightsSheetCanvases {
        let chrome = M.grabberStrip + Self.header(header) + M.headerGap + M.gap + M.bottomGap + bottomInset
        let side = pinnedPlanSide(height: sheet, chrome: chrome, width: width)
        return LightsSheetCanvases(planSide: side, arcWidth: arcWidth(width: width, planSide: side))
    }

    /// The side panel's canvases in a panel of `size`.
    static func sideCanvases(size: CGSize, header: CGFloat) -> LightsSheetCanvases {
        let chrome = Self.header(header) + M.headerGap + M.gap + M.bottomGap
        let side = pinnedPlanSide(height: size.height, chrome: chrome, width: size.width)
        return LightsSheetCanvases(planSide: side, arcWidth: arcWidth(width: size.width, planSide: side))
    }

    /// The height a release leaves: up past 40 pt, or a predicted end past
    /// 120 pt up, expands; down likewise compacts; otherwise unchanged. A
    /// fling's direction wins over the distance dragged. `translation` and
    /// `predicted` are vertical, down positive.
    static func detent(from current: LightsSheetDetent, translation: CGFloat,
                       predicted: CGFloat) -> LightsSheetDetent {
        if predicted <= -M.flingDistance { return .expanded }
        if predicted >= M.flingDistance { return .compact }
        if translation <= -M.snapDistance { return .expanded }
        if translation >= M.snapDistance { return .compact }
        return current
    }

    /// While a drag runs: the slot keeps the committed height; the drawn
    /// sheet follows the finger, clamped to [compact, expanded].
    static func dragFrame(detent: LightsSheetDetent, translation: CGFloat,
                          heights: LightsSheetHeights) -> LightsSheetFrame {
        let slot = heights.height(detent)
        let sheet = min(max(slot - translation, heights.compact), heights.expanded)
        return LightsSheetFrame(slot: slot, sheet: sheet)
    }

    /// The air-only sheet (no light): the compact height whatever the
    /// detent, never dragged (the detent is left for when a light returns).
    /// Compact, so it never breaks the expanded sheet's "no taller than its
    /// content" rule; its rows scroll in the compact body.
    static func airOnlyFrame(heights: LightsSheetHeights) -> LightsSheetFrame {
        dragFrame(detent: .compact, translation: 0, heights: heights)
    }

    /// The expanded body shows once the drawn sheet is past halfway to the
    /// expanded height (during a drag), else for the expanded detent.
    static func showsExpandedBody(detent: LightsSheetDetent, sheet: CGFloat, heights: LightsSheetHeights,
                                  dragging: Bool) -> Bool {
        guard heights.expanded > heights.compact + 0.5 else { return detent == .expanded }
        guard dragging else { return detent == .expanded }
        return sheet > (heights.compact + heights.expanded) / 2
    }

    /// A keyboard overlapping a sheet `sheet` points tall by `overlap`: the
    /// pinned plan hides, and the sheet rises so that at least 96 pt of rows
    /// stay above the keyboard.
    static func keyboardLayout(sheet: CGFloat, header: CGFloat, overlap: CGFloat) -> LightsSheetKeyboardLayout {
        guard overlap > 0 else { return LightsSheetKeyboardLayout(showsPinnedPlan: true, rise: 0) }
        let shown = sheet - M.grabberStrip - Self.header(header) - overlap
        return LightsSheetKeyboardLayout(showsPinnedPlan: false, rise: max(0, M.keyboardRows - shown))
    }

    /// How much of a view whose bottom is at `bottom` a keyboard whose top is
    /// at `keyboardTop` covers (both in the window's coordinates); nil: no
    /// keyboard.
    static func keyboardOverlap(bottom: CGFloat, keyboardTop: CGFloat?) -> CGFloat {
        guard let keyboardTop else { return 0 }
        return max(0, bottom - keyboardTop)
    }

    /// The orbit canvases' sizes in the active placement, so the DEBUG orbit
    /// tokens (`plan:`, `square:`, `arc:`, `pinch:`) lay out at what is on
    /// screen: the compact sheet's 164 pt plan (no arc), the expanded sheet's
    /// pinned canvases at its height in `room`, the side panel's canvases in
    /// a panel of `sideSize`, else the card's (the column and the float).
    static func activeCanvases(placement: LightsToolsPlacement, detent: LightsSheetDetent,
                               heights: LightsSheetHeights, room: CGSize, header: CGFloat,
                               bottomInset: CGFloat, sideSize: CGSize) -> (plan: CGSize, arc: CGSize) {
        switch placement {
        case .bottomSheet:
            guard detent == .expanded else {
                return (CGSize(width: M.compactPlanSide, height: M.compactPlanSide), LightsOrbitMetrics.arcSize)
            }
            let canvases = expandedCanvases(sheet: heights.expanded, header: header, bottomInset: bottomInset,
                                            width: room.width)
            return (canvases.planSize, canvases.arcSize)
        case .sidePanel:
            let canvases = sideCanvases(size: CGSize(width: sideSize.width,
                                                     height: sideSize.height - M.sideTopInset),
                                        header: header)
            return (canvases.planSize, canvases.arcSize)
        case .column, .floating:
            return (LightsOrbitMetrics.planSize, LightsOrbitMetrics.arcSize)
        }
    }
}

// MARK: - The phone panes

/// Phone portrait Lights mode (#623 Q7): the console and the sequence strip
/// give way to the docked sheet. Their stored flags are never written by the
/// mode; a pane shows when its flag is on and, while the tools are docked,
/// once the user brings it back from the rail (the override, reset each time
/// the mode opens). The rail pill's setter writes both, so once touched the
/// pill behaves as usual. Pure.
enum LightsPaneRule {
    static func shows(stored: Bool, override: Bool, docked: Bool) -> Bool {
        stored && (!docked || override)
    }

    /// The panes shown beside the docked sheet, for the DEBUG layout line.
    static func summary(console: Bool, sequence: Bool) -> String {
        switch (console, sequence) {
        case (false, false): return "hidden"
        case (true, false): return "console"
        case (false, true): return "sequence"
        case (true, true): return "both"
        }
    }
}

// MARK: - Strings

/// The sheet's VoiceOver names, titles and identifiers. Pure.
enum LightsSheetState {
    static let grabberLabel = "Light sheet"
    static let identifier = "lights.sheet"
    static let sideIdentifier = "lights.side"
    static let grabberIdentifier = "lights.sheet.grabber"
    static let moreIdentifier = "lights.sheet.more"
    static let colourIdentifier = "lights.sheet.colour"
    static let paletteIdentifier = "lights.sheet.palette"
    static let colourLabel = "Colour"
    static let colourHint = "Shows the colour swatches"
    static let customColourName = "Custom"
    /// The air-only sheet and side panel (no light, #726).
    static let airIdentifier = "lights.sheet.air"
    static let sideAirIdentifier = "lights.side.air"
    /// The rows' top, scrolled into view when a field with no row of its own
    /// (the inspector's) takes the keyboard.
    static let rowsAnchor = "lights.sheet.rows.top"
    /// The Atmosphere section (#726): what the header's Atmosphere button
    /// scrolls to.
    static let atmosphereAnchor = "lights.sheet.atmosphere.section"

    /// What the rows scroll to while a keyboard covers the sheet with a
    /// field focused (`covered`): the focused row an Atmosphere field reports
    /// (LightsSheetScrollTargetKey), else the rows' top; nil (no scroll)
    /// while uncovered. A focused row near the bottom of the rows would
    /// otherwise stay under the keyboard.
    static func scrollTarget(focusedRow: String?, covered: Bool) -> String? {
        guard covered else { return nil }
        return focusedRow ?? rowsAnchor
    }

    static func grabberValue(_ detent: LightsSheetDetent) -> String {
        detent == .compact ? "Compact" : "Expanded"
    }

    static func moreTitle(expanded: Bool) -> String {
        expanded ? "Less" : "More"
    }

    static func moreLabel(expanded: Bool) -> String {
        expanded ? "Show fewer light settings" : "Show all light settings"
    }

    /// A VoiceOver adjustment: increment expands, decrement compacts.
    static func adjusted(_ detent: LightsSheetDetent, increment: Bool) -> LightsSheetDetent {
        increment ? .expanded : .compact
    }

    /// The Colour button's value: the swatch's name, or `Custom`.
    static func colourValue(swatchIndex: Int?) -> String {
        guard let swatchIndex, LightColour.swatches.indices.contains(swatchIndex) else { return customColourName }
        return LightColour.swatches[swatchIndex].name
    }

    static func swatchIdentifier(_ name: String) -> String {
        "lights.sheet.swatch.\(name.lowercased())"
    }

    /// Where the tools are, for the `tools=` field of the PYMOL_AUTOLIGHTS
    /// and LightsLayout log lines: `sheet:compact`, `sheet:expanded`,
    /// `side`, `float:<corner>` (`float:bl`) or `column`; with no light on a
    /// phone (`airOnly`, LightsSheet.showsAirOnly) `sheet:air` or `side:air`.
    static func toolsSummary(placement: LightsToolsPlacement, detent: LightsSheetDetent,
                             corner: LightsFloatCorner = .default, airOnly: Bool = false) -> String {
        switch placement {
        case .bottomSheet: return airOnly ? "sheet:air" : "sheet:\(detent.rawValue)"
        case .sidePanel: return airOnly ? "side:air" : "side"
        case .floating: return "float:\(corner.rawValue)"
        case .column: return "column"
        }
    }
}

// MARK: - Measurements reported to the owner

/// The header row's measured height (the owner's height model reads it).
struct LightsSheetHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The expanded rows' measured content height (for `expandedContent`).
struct LightsSheetRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct LightsSheetBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The sheet

/// The docked light tools. With a selected light, the full sheet (or side
/// panel); with no light while Lights mode is active, the air alone
/// (`showsAirOnly`). Draws nothing outside Lights mode.
struct LightsSheet: View {
    enum Placement: Equatable {
        /// The two-height bottom sheet.
        case bottom
        /// The trailing panel (compact height).
        case side
    }

    @ObservedObject var controller: LightsController
    var style: LightsBarStyle
    var placement: Placement
    @Binding var detent: LightsSheetDetent
    /// From LightsSheetModel.layout for the owner's room (`.bottom`).
    var heights: LightsSheetHeights
    /// The home indicator's inset under the sheet.
    var bottomInset: CGFloat
    var sceneShadowsOn: Bool?
    var onEnableSceneShadows: () -> Void
    /// True for the snap after a release, a tap or a VoiceOver adjustment,
    /// false when it completes (the owner freezes the drawable meanwhile).
    var onMoving: (Bool) -> Void
    /// A field in the rows (Orbit, Pitch, an Atmosphere value) took or lost
    /// the keyboard.
    var onFieldFocus: (Bool) -> Void
    /// Asks the full sheet to reveal the Atmosphere section, as the header's
    /// Atmosphere button does (`revealAtmosphere()`): each change asks once,
    /// and a non-zero value when the full sheet appears asks once too (an
    /// owner resets it to 0 for each mode entry). 0: nothing asked.
    var atmosphereRevealRequest: Int

    /// The grabber drag's live translation. SwiftUI resets it when the drag
    /// ends or is cancelled (no `onEnded` then), so a cancelled drag leaves
    /// nothing behind: the sheet animates back to its slot.
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: LightsSheetMetrics.snapDuration)))
    private var dragTranslation: CGFloat = 0
    @State private var header: CGFloat = LightsSheetMetrics.minimumHeader
    @State private var fieldFocused = false
    @State private var keyboardTop: CGFloat?
    @State private var bottom: CGFloat = 0
    /// Bumped by `revealAtmosphere()`; the expanded body scrolls to the
    /// Atmosphere section while it differs from `atmosphereShown` (also when
    /// the body only appears with the expansion the request started).
    @State private var atmosphereRequest = 0
    @State private var atmosphereShown = 0
    /// The owner's last `atmosphereRevealRequest` acted on.
    @State private var revealSeen = 0

    init(controller: LightsController, style: LightsBarStyle, placement: Placement,
         detent: Binding<LightsSheetDetent>, heights: LightsSheetHeights, bottomInset: CGFloat = 0,
         sceneShadowsOn: Bool? = nil, onEnableSceneShadows: @escaping () -> Void = {},
         onMoving: @escaping (Bool) -> Void = { _ in }, onFieldFocus: @escaping (Bool) -> Void = { _ in },
         atmosphereRevealRequest: Int = 0) {
        self.controller = controller
        self.style = style
        self.placement = placement
        _detent = detent
        self.heights = heights
        self.bottomInset = bottomInset
        self.sceneShadowsOn = sceneShadowsOn
        self.onEnableSceneShadows = onEnableSceneShadows
        self.onMoving = onMoving
        self.onFieldFocus = onFieldFocus
        self.atmosphereRevealRequest = atmosphereRevealRequest
    }

    private typealias M = LightsSheetMetrics

    /// The air-only sheet shows: Lights mode is active with no selected
    /// light (no rig, or a rig with no light), where the full sheet (which
    /// needs LightsOrbitState) has nothing to show.
    static func showsAirOnly(_ controller: LightsController) -> Bool {
        controller.isActive && LightsOrbitState(controller) == nil
    }

    var body: some View {
        if LightsOrbitState(controller) != nil {
            observingMeasurements(Group {
                switch placement {
                case .bottom: bottomSheet
                case .side: sidePanel
                }
            })
            .onAppear { noteRevealRequest(atmosphereRevealRequest) }
            .onChange(of: atmosphereRevealRequest) { _, request in noteRevealRequest(request) }
        } else if Self.showsAirOnly(controller) {
            observingMeasurements(Group {
                switch placement {
                case .bottom: airOnlySheet
                case .side: airOnlyPanel
                }
            })
        }
    }

    /// The header's height, the keyboard rule and the safety net, for the
    /// full sheet and the air-only one alike.
    private func observingMeasurements<Content: View>(_ content: Content) -> some View {
        content
            .onPreferenceChange(LightsSheetHeaderHeightKey.self) { measured in
                if measured > 0, abs(measured - header) > 0.5 { header = measured }
            }
            .onPreferenceChange(LightsFieldFocusKey.self) { focused in
                guard focused != fieldFocused else { return }
                fieldFocused = focused
                onFieldFocus(focused)
            }
            .onPreferenceChange(LightsSheetBottomKey.self) { bottom = $0 }
            .modifier(LightsKeyboardTopReader(top: $keyboardTop))
            .onDisappear {
                // Safety net: never leave the drawable frozen or the
                // keyboard rule on (also when the air-only sheet gives way
                // to the full one, or back).
                onMoving(false)
                if fieldFocused {
                    fieldFocused = false
                    onFieldFocus(false)
                }
            }
    }

    private func noteRevealRequest(_ request: Int) {
        guard request != 0, request != revealSeen else { return }
        revealSeen = request
        revealAtmosphere()
    }

    /// The header's Atmosphere button: a compact sheet expands, then the
    /// rows scroll to the Atmosphere section (the side panel, always
    /// expanded, only scrolls).
    private func revealAtmosphere() {
        if placement == .bottom, detent == .compact { setDetent(.expanded) }
        atmosphereRequest += 1
    }

    private var overlap: CGFloat {
        LightsSheetModel.keyboardOverlap(bottom: bottom, keyboardTop: keyboardTop)
    }

    // MARK: .bottom

    private var bottomSheet: some View {
        let frame = LightsSheetModel.dragFrame(detent: detent, translation: dragTranslation, heights: heights)
        let keyboard = LightsSheetModel.keyboardLayout(sheet: frame.sheet, header: header, overlap: overlap)
        let drawn = frame.sheet + keyboard.rise
        let expanded = LightsSheetModel.showsExpandedBody(detent: detent, sheet: frame.sheet, heights: heights,
                                                          dragging: dragTranslation != 0)
        return GeometryReader { g in
            VStack(spacing: 0) {
                dragRegion
                Group {
                    if expanded {
                        expandedBody(LightsSheetModel.expandedCanvases(sheet: drawn, header: header,
                                                                       bottomInset: bottomInset,
                                                                       width: g.size.width),
                                     showsPlan: keyboard.showsPinnedPlan)
                    } else {
                        compactBody
                    }
                }
                .padding(.horizontal, M.inset)
                .padding(.top, M.headerGap)
                .padding(.bottom, M.bottomGap)
            }
            .padding(.bottom, bottomInset)
        }
        .frame(height: drawn)
        .background(sheetChrome)
        .background(GeometryReader { g in
            Color.clear.preference(key: LightsSheetBottomKey.self, value: g.frame(in: .global).maxY)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightsSheetState.identifier)
        // A pull-down leaves the slot's top band in the tools' colour; a
        // pull-up draws over the viewport above (the slot never changes
        // during a drag).
        .frame(height: frame.slot, alignment: .bottom)
        .background(alignment: .top) {
            style.background.frame(height: max(0, frame.slot - drawn))
        }
        .tint(style.accent)
    }

    private var sheetChrome: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: M.cornerRadius, topTrailingRadius: M.cornerRadius)
        return shape.fill(style.background)
            .overlay(shape.stroke(style.text.opacity(0.18), lineWidth: 0.5))
    }

    /// The grabber strip and the header row: a drag here moves the sheet, a
    /// tap toggles it (the header's buttons keep their own taps).
    private var dragRegion: some View {
        VStack(spacing: 0) {
            grabber
            headerRow
                .padding(.horizontal, M.inset)
        }
        .contentShape(Rectangle())
        .onTapGesture { setDetent(detent.toggled) }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .updating($dragTranslation) { value, translation, _ in
                    translation = value.translation.height
                }
                .onEnded { value in
                    setDetent(LightsSheetModel.detent(from: detent, translation: value.translation.height,
                                                      predicted: value.predictedEndTranslation.height))
                }
        )
    }

    private var grabber: some View {
        Capsule()
            .fill(style.text.opacity(0.35))
            .frame(width: M.grabberSize.width, height: M.grabberSize.height)
            .frame(maxWidth: .infinity)
            .frame(height: M.grabberStrip)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(LightsSheetState.grabberLabel)
            .accessibilityValue(LightsSheetState.grabberValue(detent))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { setDetent(detent.toggled) }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setDetent(LightsSheetState.adjusted(detent, increment: true))
                case .decrement: setDetent(LightsSheetState.adjusted(detent, increment: false))
                @unknown default: break
                }
            }
            .accessibilityIdentifier(LightsSheetState.grabberIdentifier)
    }

    /// One snap to `next`, animated, with the owner told before and after.
    private func setDetent(_ next: LightsSheetDetent) {
        guard next != detent else { return }
        onMoving(true)
        withAnimation(.easeOut(duration: M.snapDuration)) {
            detent = next
        } completion: {
            onMoving(false)
        }
    }

    // MARK: header

    /// The inspector's header, the Atmosphere button (expands a compact
    /// sheet and scrolls to the section) and, on the bottom sheet, More/Less.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 4) {
            LightsInspector(controller: controller, style: style, sceneShadowsOn: sceneShadowsOn,
                            onEnableSceneShadows: onEnableSceneShadows, presentation: .header)
            LightsSheetAtmosphereButton(controller: controller, style: style) { revealAtmosphere() }
            if placement == .bottom {
                moreButton
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: LightsSheetHeaderHeightKey.self, value: g.size.height)
        })
    }

    private var moreButton: some View {
        let expanded = detent == .expanded
        return Button { setDetent(detent.toggled) } label: {
            HStack(spacing: 3) {
                Text(LightsSheetState.moreTitle(expanded: expanded))
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(style.accent)
            .frame(minHeight: M.minimumHeader)
            .contentShape(Rectangle())
            .lightsTouchTarget()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(LightsSheetState.moreLabel(expanded: expanded))
        .accessibilityLabel(LightsSheetState.moreLabel(expanded: expanded))
        .accessibilityIdentifier(LightsSheetState.moreIdentifier)
    }

    // MARK: bodies

    /// The plan beside Pitch, Intensity and Colour. It scrolls only when the
    /// room clamps the compact height.
    private var compactBody: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: M.gap) {
                OrbitCanvases(controller: controller, eye: controller.eye, style: style,
                              planSize: CGSize(width: M.compactPlanSide, height: M.compactPlanSide),
                              showsArc: false)
                LightsCompactRows(controller: controller, eye: controller.eye, style: style)
            }
        }
        .scrollDisabled(!heights.compactScrolls)
        .scrollBounceBehavior(.basedOnSize)
    }

    /// The plan and the arc pinned at the top (hidden under a keyboard), and
    /// the inspector's rows then the Atmosphere section scrolling below: only
    /// the rows scroll.
    private func expandedBody(_ canvases: LightsSheetCanvases, showsPlan: Bool) -> some View {
        VStack(alignment: .leading, spacing: M.gap) {
            if showsPlan {
                OrbitCanvases(controller: controller, eye: controller.eye, style: style,
                              planSize: canvases.planSize, arcSize: canvases.arcSize)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id(LightsSheetState.rowsAnchor)
                        LightsInspector(controller: controller, style: style, sceneShadowsOn: sceneShadowsOn,
                                        onEnableSceneShadows: onEnableSceneShadows, presentation: .rows)
                        // The rig's haze and dust (#726), after the light's
                        // rows; it carries LightsSheetState.atmosphereAnchor.
                        LightsAtmosphereCard(controller: controller, style: style, presentation: .section)
                            .padding(.top, M.sectionGap)
                    }
                    .background(GeometryReader { g in
                        Color.clear.preference(key: LightsSheetRowsHeightKey.self, value: g.size.height)
                    })
                }
                .scrollBounceBehavior(.basedOnSize)
                .contentMargins(.bottom, overlap, for: .scrollContent)
                .modifier(LightsSheetKeyboardScroll(proxy: proxy, covered: fieldFocused && overlap > 0))
                // Appearing with the expansion a reveal started: jump (the
                // sheet's own expansion animates); already shown: glide.
                .onAppear { scrollToAtmosphereIfAsked(proxy, animated: false) }
                .onChange(of: atmosphereRequest) { scrollToAtmosphereIfAsked(proxy, animated: true) }
            }
        }
    }

    /// One scroll to the Atmosphere section per `revealAtmosphere()`, after
    /// the layout pass (a body that has just appeared has its rows then).
    private func scrollToAtmosphereIfAsked(_ proxy: ScrollViewProxy, animated: Bool) {
        guard atmosphereRequest != atmosphereShown else { return }
        atmosphereShown = atmosphereRequest
        DispatchQueue.main.async {
            withAnimation(animated ? .easeOut(duration: M.snapDuration) : nil) {
                proxy.scrollTo(LightsSheetState.atmosphereAnchor, anchor: .top)
            }
        }
    }

    // MARK: .side

    private var sidePanel: some View {
        GeometryReader { g in
            let canvases = LightsSheetModel.sideCanvases(
                size: CGSize(width: g.size.width, height: g.size.height - M.sideTopInset), header: header)
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                    .padding(.horizontal, M.inset)
                    .padding(.top, M.sideTopInset)
                expandedBody(canvases, showsPlan: overlap <= 0)
                    .padding(.horizontal, M.inset)
                    .padding(.top, M.headerGap)
                    .padding(.bottom, M.bottomGap)
            }
        }
        .background(style.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(style.text.opacity(0.18)).frame(width: 0.5)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: LightsSheetBottomKey.self, value: g.frame(in: .global).maxY)
        })
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightsSheetState.sideIdentifier)
    }

    // MARK: air only (no light)

    /// The air alone at the compact height whatever the detent: the
    /// Atmosphere header (title and switch) under an empty grabber strip
    /// (there is no other height to drag to), and the air rows scrolling in
    /// the compact body. No More and no Atmosphere button. The keyboard rule
    /// holds as in the full sheet.
    private var airOnlySheet: some View {
        let frame = LightsSheetModel.airOnlyFrame(heights: heights)
        let keyboard = LightsSheetModel.keyboardLayout(sheet: frame.sheet, header: header, overlap: overlap)
        let drawn = frame.sheet + keyboard.rise
        return VStack(spacing: 0) {
            Color.clear.frame(height: M.grabberStrip)
            airHeaderRow
                .padding(.horizontal, M.inset)
            airRows
                .padding(.horizontal, M.inset)
                .padding(.top, M.headerGap)
                .padding(.bottom, M.bottomGap)
        }
        .padding(.bottom, bottomInset)
        .frame(height: drawn, alignment: .top)
        .background(sheetChrome)
        .background(GeometryReader { g in
            Color.clear.preference(key: LightsSheetBottomKey.self, value: g.frame(in: .global).maxY)
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightsSheetState.airIdentifier)
        .frame(height: frame.slot, alignment: .bottom)
        .tint(style.accent)
    }

    /// The air alone in the side panel: the Atmosphere header, then its rows
    /// filling the panel.
    private var airOnlyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            airHeaderRow
                .padding(.horizontal, M.inset)
                .padding(.top, M.sideTopInset)
            airRows
                .padding(.horizontal, M.inset)
                .padding(.top, M.headerGap)
                .padding(.bottom, M.bottomGap)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(style.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(style.text.opacity(0.18)).frame(width: 0.5)
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: LightsSheetBottomKey.self, value: g.frame(in: .global).maxY)
        })
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LightsSheetState.sideAirIdentifier)
    }

    /// The Atmosphere header as the sheet's header row (measured, as the
    /// light's header is, so the heights follow it).
    private var airHeaderRow: some View {
        LightsAtmosphereCard(controller: controller, style: style, presentation: .header)
            .frame(minHeight: M.minimumHeader)
            .background(GeometryReader { g in
                Color.clear.preference(key: LightsSheetHeaderHeightKey.self, value: g.size.height)
            })
    }

    /// The hint and the air rows. Not reported as the sheet's rows height:
    /// that measures the light's expanded rows.
    private var airRows: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id(LightsSheetState.rowsAnchor)
                    LightsAtmosphereCard(controller: controller, style: style, presentation: .rows)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.bottom, overlap, for: .scrollContent)
            .modifier(LightsSheetKeyboardScroll(proxy: proxy, covered: fieldFocused && overlap > 0))
        }
    }
}

/// While a keyboard covers the sheet with a field focused (`covered`), the
/// rows scroll to LightsSheetState.scrollTarget: the focused Atmosphere row
/// (LightsSheetScrollTargetKey), else the rows' top.
private struct LightsSheetKeyboardScroll: ViewModifier {
    var proxy: ScrollViewProxy
    var covered: Bool
    @State private var focusedRow: String?

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(LightsSheetScrollTargetKey.self) { focusedRow = $0 }
            .onChange(of: LightsSheetState.scrollTarget(focusedRow: focusedRow, covered: covered)) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: LightsSheetMetrics.snapDuration)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
    }
}

// MARK: - The compact rows

/// The compact sheet's controls beside the plan (sketch 4): Pitch and
/// Intensity as two-line sliders (label and value over a full-width slider),
/// then one 44 pt Colour button whose popover holds the swatches and the
/// picker. Observes `eye`, so a pinned light's pitch follows the camera.
/// Writes through `setIfChanged` and `setColour` (the bridge setters).
struct LightsCompactRows: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var eye: LightsEyeState
    var style: LightsBarStyle

    @State private var showsColours = false

    private typealias M = LightsSheetMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: M.gap) {
            slider(.pitch)
            slider(.intensity)
            colourButton
        }
        .disabled(!controller.canEdit)
        .opacity(controller.canEdit ? 1 : 0.5)
        .tint(style.accent)
    }

    @ViewBuilder
    private func slider(_ parameter: LightParameter) -> some View {
        if let row = LightsInspectorState.row(parameter, of: controller) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(parameter.label)
                        .font(.system(size: 12))
                        .foregroundColor(style.text.opacity(0.8))
                    Spacer(minLength: 4)
                    Text(verbatim: row.text)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(style.text)
                        .lineLimit(1)
                }
                .accessibilityHidden(true)
                Slider(value: Binding(get: { LightsInspectorState.sliderPosition(parameter, row.value) },
                                      set: { position in
                                          controller.setIfChanged(
                                              parameter, LightsInspectorState.sliderValue(parameter, position))
                                      }),
                       in: LightsInspectorState.sliderRange(parameter))
                    .accessibilityLabel(parameter.label)
                    .accessibilityValue(row.spoken)
                    .accessibilityIdentifier("lights.sheet.\(parameter.field)")
            }
            .frame(minHeight: M.sliderRowHeight, alignment: .top)
        }
    }

    private var colourButton: some View {
        let rgb = controller.selectedLight?.color ?? SIMD3(1, 1, 1)
        let value = LightsSheetState.colourValue(swatchIndex: LightColour.swatchIndex(of: rgb))
        return Button { showsColours = true } label: {
            HStack(spacing: 8) {
                LightsSwatchDot(rgb: rgb, style: style, size: 22)
                Text(LightsSheetState.colourLabel)
                    .font(.system(size: 12))
                    .foregroundColor(style.text.opacity(0.8))
                Spacer(minLength: 4)
                Text(verbatim: value)
                    .font(.system(size: 11))
                    .foregroundColor(style.text.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: M.colourButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsColours) {
            LightsColourPalette(controller: controller, style: style)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(LightsSheetState.colourLabel)
        .accessibilityValue(value)
        .accessibilityHint(LightsSheetState.colourHint)
        .accessibilityIdentifier(LightsSheetState.colourIdentifier)
    }
}

/// A colour dot with a hairline ring.
struct LightsSwatchDot: View {
    var rgb: SIMD3<Double>
    var style: LightsBarStyle
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: 1))
            .overlay(Circle().stroke(style.text.opacity(0.3), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}

/// The Colour button's popover: the six swatches as 44 pt targets in three
/// columns, then the custom colour picker in a 44 pt frame.
struct LightsColourPalette: View {
    @ObservedObject var controller: LightsController
    var style: LightsBarStyle

    static let columns = 3
    static let spacing: CGFloat = 4
    /// Wide enough for the three columns and for `Custom colour` on one
    /// line beside the 44 pt picker.
    static let width: CGFloat = 196

    var body: some View {
        if let state = LightsInspectorState(controller) {
            let rows = stride(from: 0, to: state.swatches.count, by: Self.columns).map {
                Array(state.swatches[$0..<min($0 + Self.columns, state.swatches.count)])
            }
            VStack(alignment: .leading, spacing: 8) {
                Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r]) { swatch in
                                swatchButton(swatch)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Text(LightsInspectorState.customColourLabel)
                        .font(.system(size: 12))
                        .foregroundColor(style.text.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    ColorPicker(LightsInspectorState.customColourLabel,
                                selection: Binding(get: { LightColour.cgColor(state.color) },
                                                   set: { picked in
                                                       if let rgb = LightColour.srgb(from: picked) {
                                                           controller.setColour(rgb)
                                                       }
                                                   }),
                                supportsOpacity: false)
                        .labelsHidden()
                        .frame(minWidth: LightsTouch.swatchTarget, minHeight: LightsTouch.swatchTarget)
                        .contentShape(Rectangle())
                        .accessibilityLabel(LightsInspectorState.customColourLabel)
                        .accessibilityIdentifier("lights.sheet.custom")
                }
            }
            .padding(12)
            .frame(width: Self.width)
            .disabled(!state.canEdit)
            .tint(style.accent)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(LightsSheetState.paletteIdentifier)
        }
    }

    private func swatchButton(_ swatch: LightsInspectorState.Swatch) -> some View {
        Button { controller.setColour(swatch.rgb) } label: {
            LightsSwatchDot(rgb: swatch.rgb, style: style, size: 26)
                .padding(3)
                .overlay(Circle().stroke(swatch.isSelected ? style.accent : Color.clear, lineWidth: 1.5))
                .frame(width: LightsTouch.swatchTarget, height: LightsTouch.swatchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(swatch.isSelected ? .isSelected : [])
        .accessibilityIdentifier(LightsSheetState.swatchIdentifier(swatch.name))
    }
}

// MARK: - The keyboard (iOS)

/// The keyboard's top edge in the window's coordinates, nil while it is
/// hidden (iOS only; nothing on macOS). Read from the keyboard's frame
/// notifications, converted from screen coordinates (an iPad Slide Over
/// window is offset).
struct LightsKeyboardTopReader: ViewModifier {
    @Binding var top: CGFloat?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
                note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                top = Self.windowY(screenY: frame.minY)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                top = nil
            }
        #else
        content
        #endif
    }

    #if os(iOS)
    @MainActor
    private static func windowY(screenY: CGFloat) -> CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        guard let window else { return screenY }
        return window.convert(CGPoint(x: 0, y: screenY), from: window.screen.coordinateSpace).y
    }
    #endif
}
