// LightsInspector.swift — the selected-light inspector (#620, spec §9, sketch 3).
//
// A card that holds the exact values of the selected light: Orbit and Pitch
// (dial, field and stepper), sliders for Radius, Intensity, Warmth, Beam and
// Softness, colour swatches plus a picker, Pin, Revert this light and Delete.
// It sits in the Lights side column (LightsSideColumn.swift): under the bar on
// macOS, at the viewport's top-trailing corner on iOS (ContentView places it).
//
// It observes LightsController, the one Lights model the bar (#619), the orbit
// view (#621) and the gizmo (#622) share, so a chip tap selects here and an
// edit here shows in the bar in the same main-thread turn. Every control
// writes through the typed edit API in LightsEditing.swift, which reaches the
// rig through the bridge setter seams: no Python per drag tick (#610). Only
// Revert this light and Delete are button presses that run a helper or a
// command, through the controller's actions. So this file names no Python,
// console command or bridge function (testing/tests/raymol/lighting_mode.py
// checks that).
//
// Per-frame placement updates (a pinned light while the camera turns) are
// published on `LightsController.eye`; only LightPlacementRows observes it, so
// the rest of the card and the bar do not re-render at display rate.
//
// Both platforms share this file. The only `#if os` is the small iOS keyboard
// extension at the end; the DEBUG `LightsAutoEdit` (the simulator edit hook)
// compiles only in debug builds.

import CoreGraphics
import SwiftUI

// MARK: - Formatting

/// How the inspector writes and reads its numbers, for the eye and for
/// VoiceOver. Pure, so the unit tests check every string.
enum LightInspectorFormat {
    /// The typographic minus the fields and value labels show.
    static let minus = "\u{2212}"

    /// An angle to one decimal, the decimal dropped when it is zero: `−45°`,
    /// `47.3°`, `0°`; `plus` adds `+` to a positive value (`+35°`, pitch).
    static func angle(_ degrees: Double, plus: Bool = false) -> String {
        let (sign, magnitude) = parts(degrees)
        let shown = sign < 0 ? minus : (plus && sign > 0 ? "+" : "")
        return shown + magnitude + "°"
    }

    /// An angle as VoiceOver says it: `-45 degrees`, `35 degrees`.
    static func spokenAngle(_ degrees: Double) -> String {
        let (sign, magnitude) = parts(degrees)
        let unit = magnitude == "1" ? "degree" : "degrees"
        return (sign < 0 ? "-" : "") + magnitude + " " + unit
    }

    /// Radius in scene sizes, with Å alongside when the rig has a frame
    /// (spec decision 2): `3.0× · 42 Å`, or `3.0×`.
    static func radius(_ sizes: Double, frameSize: Double?) -> String {
        let base = String(format: "%.1f×", sizes)
        guard let frameSize, frameSize.isFinite else { return base }
        return base + String(format: " · %.0f Å", (sizes * frameSize).rounded())
    }

    /// `3.0 scene sizes, 42 angstroms`, or `3.0 scene sizes`.
    static func spokenRadius(_ sizes: Double, frameSize: Double?) -> String {
        let base = String(format: "%.1f scene sizes", sizes)
        guard let frameSize, frameSize.isFinite else { return base }
        return base + String(format: ", %.0f angstroms", (sizes * frameSize).rounded())
    }

    /// `3800 K`.
    static func kelvin(_ k: Double) -> String { String(format: "%.0f K", k) }
    /// `3800 kelvin`.
    static func spokenKelvin(_ k: Double) -> String { String(format: "%.0f kelvin", k) }
    /// Two decimals: `1.80`.
    static func fraction(_ x: Double) -> String { String(format: "%.2f", x) }

    /// The value label of `parameter`.
    static func text(_ parameter: LightParameter, _ value: Double, frameSize: Double?) -> String {
        switch parameter {
        case .orbit, .beam: return angle(value)
        case .pitch: return angle(value, plus: true)
        case .radius: return radius(value, frameSize: frameSize)
        case .warmth: return kelvin(value)
        case .intensity, .softness: return fraction(value)
        }
    }

    /// The VoiceOver value of `parameter`.
    static func spoken(_ parameter: LightParameter, _ value: Double, frameSize: Double?) -> String {
        switch parameter {
        case .orbit, .pitch, .beam: return spokenAngle(value)
        case .radius: return spokenRadius(value, frameSize: frameSize)
        case .warmth: return spokenKelvin(value)
        case .intensity, .softness: return fraction(value)
        }
    }

    /// A typed angle: blanks, a `+`, a `-` or `−`, and a trailing `°` are
    /// accepted; nil when it is not a finite number. Out-of-range values are
    /// returned as typed (the core wraps orbit and clamps pitch).
    static func parseAngle(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: minus, with: "-")
        if s.hasSuffix("°") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.allSatisfy({ "+-.0123456789eE".contains($0) }),
              let value = Double(s), value.isFinite else { return nil }
        return value
    }

    /// (sign, magnitude) of `degrees` rounded to 0.1, the decimal dropped
    /// when zero; a value that rounds to 0 has sign 0 (never `−0°`).
    private static func parts(_ degrees: Double) -> (Int, String) {
        let r = (degrees * 10).rounded() / 10
        guard r != 0, r.isFinite else { return (0, "0") }
        let m = abs(r)
        let text = m == m.rounded() ? String(format: "%.0f", m) : String(format: "%.1f", m)
        return (r < 0 ? -1 : 1, text)
    }
}

// MARK: - What the inspector shows

/// Everything the card shows, worked out from the controller in one place so
/// the unit tests can check values, labels and enablement without drawing.
/// nil unless Lights mode is active with a selected light.
struct LightsInspectorState: Equatable {
    /// One numeric control.
    struct Row: Equatable {
        var parameter: LightParameter
        var value: Double
        /// The value label (`−45°`, `3.0× · 42 Å`, `3800 K`).
        var text: String
        /// What VoiceOver says for the value.
        var spoken: String
    }

    /// One item of the header's light menu.
    struct MenuItem: Equatable, Identifiable {
        var name: String
        var index: Int
        var slot: Int
        var isSelected: Bool
        var id: String { name }
    }

    /// One colour swatch.
    struct Swatch: Equatable, Identifiable {
        var name: String
        var rgb: SIMD3<Double>
        var isSelected: Bool
        var id: String { name }
    }

    // VoiceOver names and fixed texts.
    static let menuLabel = "Light"
    static let menuHint = "Choose the light to edit"
    static let pinLabel = "Pin"
    static let pinHelp = "Pin: fix this light in the scene, so it stays put while the camera turns"
    static let customColourLabel = "Custom colour"
    static let rigOffText = "Lights off"
    static let revertTitle = "Revert this light"
    static let deleteTitle = "Delete"

    /// An Orbit or Pitch stepper press, in degrees (Up/Down arrows: 1°).
    static let stepperStep = 5.0
    static let arrowStep = 1.0

    /// The VoiceOver label of the Orbit or Pitch field.
    static func fieldLabel(_ parameter: LightParameter) -> String {
        "\(parameter.label) in degrees"
    }

    /// The VoiceOver label of the collapse chevron.
    static func collapseLabel(collapsed: Bool) -> String {
        collapsed ? "Expand inspector" : "Collapse inspector"
    }

    /// The slider's range for `parameter`: the core's, except warmth, whose
    /// slider runs over a log-kelvin track (WarmthScale, 0...1).
    static func sliderRange(_ parameter: LightParameter) -> ClosedRange<Double> {
        parameter == .warmth ? 0...1 : parameter.range
    }

    /// The slider position of `value`.
    static func sliderPosition(_ parameter: LightParameter, _ value: Double) -> Double {
        if parameter == .warmth { return WarmthScale.position(kelvin: value) }
        return min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
    }

    /// The value at slider position `position`, rounded to the parameter's
    /// quantum (what a slider tick writes).
    static func sliderValue(_ parameter: LightParameter, _ position: Double) -> Double {
        let raw = parameter == .warmth ? WarmthScale.kelvin(position: position) : position
        return parameter.rounded(raw)
    }

    var name: String
    var index: Int
    var slot: Int
    var menu: [MenuItem]
    var isPinned: Bool
    var isOn: Bool
    /// The muted header status (`Lights off`), nil while the rig is on.
    var status: String?
    var canEdit: Bool
    var canRevertLight: Bool
    var canDelete: Bool
    var color: SIMD3<Double>
    var swatches: [Swatch]
    var swatchIndex: Int?
    /// Every LightParameter, in declaration order.
    var rows: [Row]

    @MainActor
    init?(_ controller: LightsController) {
        guard controller.isActive, let light = controller.selectedLight,
              let index = controller.selectedIndex,
              let lights = controller.rig?.lights else { return nil }
        name = light.name
        self.index = index
        slot = controller.identitySlot(for: light.name)
        menu = lights.enumerated().map { i, l in
            MenuItem(name: l.name, index: i, slot: controller.identitySlot(for: l.name),
                     isSelected: i == index)
        }
        isPinned = light.anchor == .pinned
        isOn = controller.isOn
        status = controller.isOn ? nil : Self.rigOffText
        canEdit = controller.canEdit
        canRevertLight = controller.canRevertLight
        canDelete = controller.canRemove
        color = light.color
        let selectedSwatch = LightColour.swatchIndex(of: light.color)
        swatchIndex = selectedSwatch
        swatches = LightColour.swatches.enumerated().map { i, s in
            Swatch(name: s.name, rgb: s.rgb, isSelected: i == selectedSwatch)
        }
        rows = LightParameter.allCases.compactMap { Self.row($0, of: controller) }
    }

    /// The row of `parameter` for the selected light (a pinned light's orbit,
    /// pitch and radius from eye space); nil with no selected light.
    @MainActor
    static func row(_ parameter: LightParameter, of controller: LightsController) -> Row? {
        guard let value = controller.value(parameter) else { return nil }
        let size = controller.rig?.size
        return Row(parameter: parameter, value: value,
                   text: LightInspectorFormat.text(parameter, value, frameSize: size),
                   spoken: LightInspectorFormat.spoken(parameter, value, frameSize: size))
    }

    func row(_ parameter: LightParameter) -> Row? {
        rows.first { $0.parameter == parameter }
    }

    /// VoiceOver's name for the card: `Light inspector, key`.
    var containerLabel: String { "Light inspector, \(name)" }
    var pinValue: String { isPinned ? "On" : "Off" }
    var revertLabel: String { "Revert \(name)" }
    var deleteLabel: String { "Delete \(name)" }

    /// One line for logs and the simulator evidence; stable field order and
    /// number formats.
    var summary: String {
        func v(_ p: LightParameter, _ format: String) -> String {
            row(p).map { String(format: format, $0.value) } ?? "-"
        }
        let rgb = String(format: "%.3f,%.3f,%.3f", color.x, color.y, color.z)
        let swatch = swatchIndex.map { LightColour.swatches[$0].name } ?? "custom"
        return "\(name) slot=\(slot) pin=\(isPinned ? 1 : 0) on=\(isOn ? 1 : 0)"
            + " orbit=\(v(.orbit, "%.1f")) pitch=\(v(.pitch, "%.1f")) radius=\(v(.radius, "%.2f"))"
            + " intensity=\(v(.intensity, "%.2f")) warmth=\(v(.warmth, "%.0f"))"
            + " beam=\(v(.beam, "%.1f")) softness=\(v(.softness, "%.2f"))"
            + " color=\(rgb) swatch=\(swatch) edit=\(canEdit ? 1 : 0) revert=\(canRevertLight ? 1 : 0)"
    }
}

// MARK: - Orbit and Pitch fields: the editing model

/// The text of one Orbit or Pitch field while the model keeps changing under
/// it (a pinned light's placement per frame, a poll, a console edit).
/// - The model's value replaces the text unless the user has typed into the
///   field for that light (`show`).
/// - The typing belongs to the light that was selected when it began
///   (`owner`); a commit writes only while that light is still selected, so
///   text typed for one light is never written to another.
/// - A selection change drops the typed text (`selectionChanged`).
struct LightFieldEditor: Equatable {
    let parameter: LightParameter
    /// What the field shows.
    private(set) var text = ""
    /// The lowercased name of the light the editing belongs to.
    private(set) var owner: String?
    /// The model's text, put back when typing is dropped or does not parse.
    private var modelText = ""
    /// The user typed since editing began.
    private(set) var typed = false

    init(parameter: LightParameter) {
        self.parameter = parameter
    }

    var isEditing: Bool { owner != nil }

    /// The model's value for `light` changed: it replaces the text unless the
    /// user is typing for that light. Editing for another light ends.
    mutating func show(_ value: Double?, light: String?) {
        modelText = value.map { LightInspectorFormat.text(parameter, $0, frameSize: nil) } ?? ""
        if isEditing, owner != light?.lowercased() { endEditing() }
        if typed { return }
        text = modelText
    }

    /// The field gained focus with `light` selected.
    mutating func begin(light: String?) {
        let key = light?.lowercased()
        if isEditing, owner == key { return }
        owner = key
        typed = false
    }

    /// The user typed (the TextField binding's setter).
    mutating func type(_ new: String) {
        text = new
        if isEditing { typed = true }
    }

    /// Return or focus loss with `selected` the selected light: the value to
    /// write, or nil (nothing typed, the typing belongs to another light, or
    /// the text does not parse; the model's text comes back then). Always
    /// ends editing.
    mutating func commit(selected: String?) -> Double? {
        defer { endEditing() }
        guard typed, let owner, owner == selected?.lowercased(),
              let value = LightInspectorFormat.parseAngle(text) else {
            text = modelText
            return nil
        }
        text = LightInspectorFormat.text(parameter, value, frameSize: nil)
        return value
    }

    /// The selection changed: typed text is dropped and editing ends.
    mutating func selectionChanged(to light: String?, value: Double?) {
        endEditing()
        show(value, light: light)
    }

    private mutating func endEditing() {
        owner = nil
        typed = false
    }
}

// MARK: - Dials

/// The Orbit dial (a full circle: the camera at the bottom, +90 to the right,
/// ±180 at the top) or the Pitch half dial (0 to the right, +90 up), in the
/// orientation of LightAngles (spec decision 12). Dragging calls `onDrag`
/// with each new angle rounded to the parameter's quantum. Hidden from
/// VoiceOver: the field and the stepper carry the value.
struct LightAngleDial: View {
    var parameter: LightParameter
    var value: Double?
    var accent: Color
    var track: Color
    var onDrag: (Double) -> Void

    @State private var lastSent: Double?

    static let side: CGFloat = 28

    var body: some View {
        Canvas { context, size in
            let centre = Self.centre(parameter, size)
            let r = Self.radius(size)
            var trackPath = Path()
            if parameter == .orbit {
                trackPath.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                                width: 2 * r, height: 2 * r))
                // The camera's side.
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 1.5, y: centre.y + r - 1.5,
                                                    width: 3, height: 3)),
                             with: .color(track))
            } else {
                for (i, p) in stride(from: -90.0, through: 90.0, by: 10).enumerated() {
                    let o = LightAngles.offset(pitch: p)
                    let pt = CGPoint(x: centre.x + r * o.dx, y: centre.y + r * o.dy)
                    if i == 0 { trackPath.move(to: pt) } else { trackPath.addLine(to: pt) }
                }
            }
            context.stroke(trackPath, with: .color(track), lineWidth: 1.2)
            if let value {
                let o = parameter == .orbit ? LightAngles.offset(orbit: value)
                                            : LightAngles.offset(pitch: value)
                var needle = Path()
                needle.move(to: centre)
                needle.addLine(to: CGPoint(x: centre.x + r * o.dx, y: centre.y + r * o.dy))
                context.stroke(needle, with: .color(accent),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let c = Self.centre(parameter, CGSize(width: Self.side, height: Self.side))
                    let dx = Double(drag.location.x - c.x)
                    let dy = Double(drag.location.y - c.y)
                    guard dx * dx + dy * dy > 4 else { return }
                    let angle = parameter == .orbit ? LightAngles.orbit(dx: dx, dy: dy)
                                                    : LightAngles.pitch(dx: dx, dy: dy)
                    let rounded = parameter.rounded(angle)
                    guard rounded != lastSent else { return }
                    lastSent = rounded
                    onDrag(rounded)
                }
                .onEnded { _ in lastSent = nil }
        )
        .accessibilityHidden(true)
    }

    /// The dial's centre: the middle for Orbit, near the left edge for the
    /// Pitch half dial.
    static func centre(_ parameter: LightParameter, _ size: CGSize) -> CGPoint {
        parameter == .orbit ? CGPoint(x: size.width / 2, y: size.height / 2)
                            : CGPoint(x: 6, y: size.height / 2)
    }

    static func radius(_ size: CGSize) -> CGFloat {
        min(size.width, size.height) / 2 - 2
    }
}

// MARK: - Rows

private enum InspectorMetrics {
    static let labelWidth: CGFloat = 58
    static let valueWidth: CGFloat = 78
    static let fieldWidth: CGFloat = 60
    static let font = Font.system(size: 12)
    static let valueFont = Font.system(size: 11).monospacedDigit()
}

/// A slider row: label, continuous slider (no ticks), value label. The
/// setter receives the value at the slider's position, rounded.
struct LightSliderRow: View {
    var row: LightsInspectorState.Row
    var style: LightsBarStyle
    var onSet: (Double) -> Void

    var body: some View {
        let p = row.parameter
        HStack(spacing: 6) {
            Text(p.label)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(0.8))
                .frame(width: InspectorMetrics.labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { LightsInspectorState.sliderPosition(p, row.value) },
                                  set: { onSet(LightsInspectorState.sliderValue(p, $0)) }),
                   in: LightsInspectorState.sliderRange(p))
                .controlSize(.small)
                .accessibilityLabel(p.label)
                .accessibilityValue(row.spoken)
                .accessibilityIdentifier("lights.inspector.\(p.field)")
            Text(verbatim: row.text)
                .font(InspectorMetrics.valueFont)
                .foregroundColor(style.text)
                .lineLimit(1)
                .frame(width: InspectorMetrics.valueWidth, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

/// An Orbit or Pitch row: label, dial, field and stepper. The field follows
/// LightFieldEditor; Return or focus loss writes the typed value exactly; the
/// stepper adds ±5°; Up and Down in the focused field add ±1° (best effort).
struct LightAngleFieldRow: View {
    let controller: LightsController
    let parameter: LightParameter
    let row: LightsInspectorState.Row?
    let lightName: String?
    let style: LightsBarStyle

    @State private var editor: LightFieldEditor
    @FocusState private var focused: Bool

    init(controller: LightsController, parameter: LightParameter,
         row: LightsInspectorState.Row?, lightName: String?, style: LightsBarStyle) {
        self.controller = controller
        self.parameter = parameter
        self.row = row
        self.lightName = lightName
        self.style = style
        _editor = State(initialValue: LightFieldEditor(parameter: parameter))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(parameter.label)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(0.8))
                .frame(width: InspectorMetrics.labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            LightAngleDial(parameter: parameter, value: row?.value, accent: style.accent,
                           track: style.text.opacity(0.35)) { angle in
                controller.set(parameter, angle)
            }
            TextField(parameter.label, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(InspectorMetrics.valueFont)
                .multilineTextAlignment(.trailing)
                .frame(width: InspectorMetrics.fieldWidth)
                .focused($focused)
                .onSubmit { commit() }
                .lightsNumberKeyboard()
                .onKeyPress(.upArrow) { arrow(LightsInspectorState.arrowStep) }
                .onKeyPress(.downArrow) { arrow(-LightsInspectorState.arrowStep) }
                .accessibilityLabel(LightsInspectorState.fieldLabel(parameter))
                .accessibilityIdentifier("lights.inspector.\(parameter.field).field")
            Spacer(minLength: 0)
            Stepper(parameter.label,
                    onIncrement: { controller.step(parameter, by: LightsInspectorState.stepperStep) },
                    onDecrement: { controller.step(parameter, by: -LightsInspectorState.stepperStep) })
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(parameter.label)
                .accessibilityValue(row?.spoken ?? "")
                .accessibilityIdentifier("lights.inspector.\(parameter.field).stepper")
        }
        .onAppear { editor.show(row?.value, light: lightName) }
        .onChange(of: row?.value) { editor.show(row?.value, light: lightName) }
        .onChange(of: lightName) {
            editor.selectionChanged(to: lightName, value: row?.value)
            focused = false
        }
        .onChange(of: focused) { _, now in
            if now { editor.begin(light: lightName) } else { commit() }
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { editor.text }, set: { new in
            guard new != editor.text else { return }
            if !editor.isEditing { editor.begin(light: lightName) }
            editor.type(new)
        })
    }

    private func commit() {
        if let value = editor.commit(selected: controller.selection.name) {
            controller.set(parameter, value)
        }
        editor.show(controller.value(parameter), light: controller.selection.name)
    }

    private func arrow(_ delta: Double) -> KeyPress.Result {
        guard controller.canEdit else { return .ignored }
        if let typed = editor.commit(selected: controller.selection.name) {
            controller.set(parameter, typed + delta)
        } else {
            controller.step(parameter, by: delta)
        }
        editor.show(controller.value(parameter), light: controller.selection.name)
        editor.begin(light: controller.selection.name)
        return .handled
    }
}

/// Orbit, Pitch and Radius: the rows that show where the light is. The only
/// part of the card observing `LightsController.eye`, so a pinned light's
/// per-frame placement re-renders these three rows and nothing else.
struct LightPlacementRows: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var eye: LightsEyeState
    var style: LightsBarStyle

    var body: some View {
        let name = controller.selection.name
        VStack(alignment: .leading, spacing: 10) {
            LightAngleFieldRow(controller: controller, parameter: .orbit,
                               row: LightsInspectorState.row(.orbit, of: controller),
                               lightName: name, style: style)
                .id("orbit.\(name ?? "")")
            LightAngleFieldRow(controller: controller, parameter: .pitch,
                               row: LightsInspectorState.row(.pitch, of: controller),
                               lightName: name, style: style)
                .id("pitch.\(name ?? "")")
            if let radius = LightsInspectorState.row(.radius, of: controller) {
                LightSliderRow(row: radius, style: style) { value in
                    controller.setIfChanged(.radius, value)
                }
            }
        }
    }
}

extension LightsController {
    /// `set`, skipped when `value` is the selected light's current value (a
    /// slider redrawing at the same position writes nothing).
    @discardableResult
    func setIfChanged(_ parameter: LightParameter, _ value: Double) -> LightSetResult {
        if let current = self.value(parameter), abs(current - value) < 1e-9 { return .ok }
        return set(parameter, value)
    }
}

// MARK: - The card

private struct LightsInspectorHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The inspector card. Draws nothing unless Lights mode is active with a
/// selected light (LightsInspectorState is nil otherwise).
struct LightsInspector: View {
    @ObservedObject var controller: LightsController
    var style: LightsBarStyle

    /// Collapsed to its header row. Plain view state, seeded per mode entry and
    /// never persisted (the test host shares the installed app's defaults).
    @State private var collapsed: Bool
    /// The content's measured height: the card is as tall as its content and
    /// scrolls only when the space is shorter. One content tree (no
    /// ViewThatFits), so a resize never resets a field's text or focus.
    @State private var contentHeight: CGFloat = LightsInspector.estimatedHeight

    static let width: CGFloat = 284
    static let estimatedHeight: CGFloat = 480

    init(controller: LightsController, style: LightsBarStyle, initiallyCollapsed: Bool) {
        self.controller = controller
        self.style = style
        _collapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        if let state = LightsInspectorState(controller) {
            card(state)
        }
    }

    private func card(_ state: LightsInspectorState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(state)
                .padding(.horizontal, 12).padding(.vertical, 8)
            if !collapsed {
                Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
                ScrollView(.vertical) {
                    content(state)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: LightsInspectorHeightKey.self,
                                                   value: g.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: contentHeight)
                .onPreferenceChange(LightsInspectorHeightKey.self) { height in
                    if height > 0, abs(height - contentHeight) > 0.5 { contentHeight = height }
                }
            }
        }
        .frame(width: Self.width)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.text.opacity(0.18), lineWidth: 0.5))
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier("lights.inspector")
    }

    // MARK: header

    private func header(_ state: LightsInspectorState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LightPalette.color(state.slot))
                .frame(width: 10, height: 10)
                .opacity(state.isOn ? 1 : 0.45)
                .accessibilityHidden(true)
            lightMenu(state)
            if let status = state.status {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(style.text.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            pinToggle(state)
            Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(style.text.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(LightsInspectorState.collapseLabel(collapsed: collapsed))
            .accessibilityLabel(LightsInspectorState.collapseLabel(collapsed: collapsed))
            .accessibilityIdentifier("lights.inspector.collapse")
        }
    }

    // A toggle drawn as the bar's chips are, so On reads at a glance (the
    // system button-style toggle barely changes on macOS).
    private func pinToggle(_ state: LightsInspectorState) -> some View {
        let on = state.isPinned
        return Button { controller.setPinned(!on) } label: {
            HStack(spacing: 3) {
                Image(systemName: on ? "pin.fill" : "pin").font(.system(size: 10))
                Text(LightsInspectorState.pinLabel).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(on ? style.accent : style.text.opacity(0.85))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Capsule().fill(on ? style.accent.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(on ? style.accent : style.text.opacity(0.25),
                                      lineWidth: on ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!state.canEdit)
        .opacity(state.canEdit ? 1 : 0.5)
        .help(LightsInspectorState.pinHelp)
        .accessibilityLabel(LightsInspectorState.pinLabel)
        .accessibilityValue(state.pinValue)
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("lights.inspector.pin")
    }

    // Text items with a checkmark on the selected one: macOS menus draw only
    // text and template images, so the identity dot lives in the header.
    private func lightMenu(_ state: LightsInspectorState) -> some View {
        Menu {
            ForEach(state.menu) { item in
                Button { controller.select(index: item.index) } label: {
                    if item.isSelected {
                        Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: state.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundColor(style.text)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(LightsInspectorState.menuHint)
        .accessibilityLabel(LightsInspectorState.menuLabel)
        .accessibilityValue(state.name)
        .accessibilityHint(LightsInspectorState.menuHint)
        .accessibilityIdentifier("lights.inspector.menu")
    }

    // MARK: content

    private func content(_ state: LightsInspectorState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LightPlacementRows(controller: controller, eye: controller.eye, style: style)
            slider(.intensity, state)
            colourRow(state)
            slider(.warmth, state)
            Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
            slider(.beam, state)
            slider(.softness, state)
            footer(state)
        }
        .disabled(!state.canEdit)
    }

    @ViewBuilder
    private func slider(_ parameter: LightParameter, _ state: LightsInspectorState) -> some View {
        if let row = state.row(parameter) {
            LightSliderRow(row: row, style: style) { value in
                controller.setIfChanged(parameter, value)
            }
        }
    }

    private func colourRow(_ state: LightsInspectorState) -> some View {
        HStack(spacing: 5) {
            Text("Colour")
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(0.8))
                .frame(width: InspectorMetrics.labelWidth - 1, alignment: .leading)
                .accessibilityHidden(true)
            ForEach(state.swatches) { swatch in
                Button { controller.setColour(swatch.rgb) } label: {
                    Circle()
                        .fill(Color(.sRGB, red: swatch.rgb.x, green: swatch.rgb.y,
                                    blue: swatch.rgb.z, opacity: 1))
                        .overlay(Circle().stroke(style.text.opacity(0.3), lineWidth: 0.5))
                        .frame(width: 15, height: 15)
                        .padding(2)
                        .overlay(Circle().stroke(swatch.isSelected ? style.accent : Color.clear,
                                                 lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(swatch.isSelected ? .isSelected : [])
                .accessibilityIdentifier("lights.inspector.swatch.\(swatch.name.lowercased())")
            }
            Spacer(minLength: 2)
            ColorPicker(LightsInspectorState.customColourLabel,
                        selection: Binding(get: { LightColour.cgColor(state.color) },
                                           set: { picked in
                                               if let rgb = LightColour.srgb(from: picked) {
                                                   controller.setColour(rgb)
                                               }
                                           }),
                        supportsOpacity: false)
                .labelsHidden()
                .help(LightsInspectorState.customColourLabel)
                .accessibilityLabel(LightsInspectorState.customColourLabel)
                .accessibilityIdentifier("lights.inspector.custom")
        }
    }

    private func footer(_ state: LightsInspectorState) -> some View {
        HStack {
            Button(LightsInspectorState.revertTitle) { controller.revertSelectedLight() }
                .buttonStyle(.plain)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(state.canRevertLight ? 0.85 : 0.35))
                .disabled(!state.canRevertLight)
                .help("Put \(state.name) back as it was when you opened Lights mode")
                .accessibilityLabel(state.revertLabel)
                .accessibilityIdentifier("lights.inspector.revert")
            Spacer()
            Button(LightsInspectorState.deleteTitle) { controller.removeSelected() }
                .buttonStyle(.plain)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(state.canDelete ? 0.85 : 0.35))
                .disabled(!state.canDelete)
                .help("Remove \(state.name) (the bar's Revert brings it back)")
                .accessibilityLabel(state.deleteLabel)
                .accessibilityIdentifier("lights.inspector.delete")
        }
        .padding(.top, 2)
    }
}

// MARK: - Keyboard

extension View {
    /// Orbit and Pitch fields on iOS: a keyboard with a minus key and Return
    /// (`.decimalPad` has neither, so onSubmit would never fire).
    @ViewBuilder
    func lightsNumberKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
}

// MARK: - DEBUG edit hook

#if DEBUG
/// PYMOL_AUTOLIGHTS_EDIT='<token>;<token>…' (debug builds only): inspector
/// edits a simulator run applies through the same controller calls the card
/// makes. Tokens: `<parameter>:<value>` for every LightParameter, `pin:0|1`,
/// `color:r:g:b` (0...1) and `expand` (the card starts expanded on compact
/// width).
enum LightsAutoEdit {
    enum Token: Equatable {
        case set(LightParameter, Double)
        case pin(Bool)
        case color(SIMD3<Double>)
        case expand
    }

    struct Parsed: Equatable {
        var tokens: [Token] = []
        /// Tokens that were not understood (unknown names, bad numbers).
        var rejected: [String] = []

        var expands: Bool { tokens.contains(.expand) }
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for raw in text.split(separator: ";") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let key = parts[0].lowercased()
            let numbers = parts.dropFirst().map { Double($0.trimmingCharacters(in: .whitespaces)) }
            let finite = numbers.compactMap { $0 }.filter(\.isFinite)
            let allNumbers = finite.count == numbers.count
            if key == "expand", parts.count == 1 {
                parsed.tokens.append(.expand)
            } else if key == "pin", parts.count == 2, allNumbers, finite[0] == 0 || finite[0] == 1 {
                parsed.tokens.append(.pin(finite[0] == 1))
            } else if key == "color" || key == "colour", parts.count == 4, allNumbers {
                parsed.tokens.append(.color(SIMD3(finite[0], finite[1], finite[2])))
            } else if let parameter = LightParameter(rawValue: key), parts.count == 2, allNumbers {
                parsed.tokens.append(.set(parameter, finite[0]))
            } else {
                parsed.rejected.append(token)
            }
        }
        return parsed
    }

    /// Apply `tokens` to the selected light; one `<edit> -> <result>` entry
    /// per edit (`expand` is a layout choice, applied before the mode opens).
    @MainActor
    static func apply(_ tokens: [Token], to controller: LightsController) -> [String] {
        tokens.compactMap { token in
            switch token {
            case .set(let parameter, let value):
                return "\(parameter.field)=\(fmt(value)) -> \(controller.set(parameter, value))"
            case .pin(let on):
                return "pin=\(on ? 1 : 0) -> \(controller.setPinned(on))"
            case .color(let rgb):
                return "color=\(fmt(rgb.x)):\(fmt(rgb.y)):\(fmt(rgb.z)) -> \(controller.setColour(rgb))"
            case .expand:
                return nil
            }
        }
    }

    private static func fmt(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(format: "%.0f", x) : String(x)
    }
}
#endif
