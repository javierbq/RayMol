// LightsInspector.swift — the selected-light inspector (#620, spec §9, sketch 3).
//
// A card that holds the exact values of the selected light: Orbit and Pitch
// (dial, field and stepper), sliders for Radius, Intensity, Warmth, Beam and
// Softness, colour swatches plus a picker, Shadow and Pin, Revert this light
// and Delete. Under the header it says why a Shadow press did nothing (a 4th
// shadowed light) and when the selected light's shadow cannot show because
// the scene's Shadows switch is off (#616: studio shadows render only while
// it is on), with a Turn On button the owner (ContentView) wires; and, in a
// muted line, when the switch is on but this frame's shadow plan gave the
// light no map because no caster is in its beam (#673, LightsFacingState).
// It sits in the Lights side column (LightsSideColumn.swift): under the bar on
// macOS, at the viewport's top-trailing corner on iOS (ContentView places it).
// The iPhone sheet and the side panel (#623, LightsSheet.swift) draw its
// header and its rows apart (LightsInspectorPresentation), from the same code.
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
    static let shadowLabel = "Shadow"
    static let shadowHelp = "Shadow: this light casts its own shadow (at most "
        + "\(LightsController.maxShadowed) lights do)"
    /// The notice after a refused Shadow press (a 4th shadowed light).
    static let shadowCapNotice = "At most \(LightsController.maxShadowed) lights cast shadows. "
        + "Turn one off first."
    /// The hint while the selected light casts a shadow the scene does not show.
    static let shadowsOffHint = "Shadows are off for this scene"
    /// The muted line under the header while the selected light's shadow has no map (#673).
    static let noCastersHint = "No casters in this light's beam"
    static let turnOnTitle = "Turn On"
    static let turnOnLabel = "Turn on scene shadows"
    static let turnOnHelp = "Turn on the scene's Shadows switch, so lights with Shadow cast them"
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

    /// #673: show `noCastersHint` only when every fact is known: the light has Shadow on,
    /// the rig is on, the scene's Shadows switch is on and this frame's plan gave the light
    /// no map (slot -1). nil (unknown) shows nothing.
    static func showsNoCastersHint(isShadowed: Bool, rigOn: Bool, sceneShadowsOn: Bool?,
                                   shadowSlot: Int?) -> Bool {
        isShadowed && rigOn && sceneShadowsOn == true && shadowSlot == -1
    }

    var name: String
    var index: Int
    var slot: Int
    var menu: [MenuItem]
    var isPinned: Bool
    var isShadowed: Bool
    /// The notice under the header (a refused Shadow press), nil when none.
    var notice: String?
    /// The selected light casts a shadow and the scene's Shadows switch is off
    /// (known to be off: nil, not yet read, shows no hint).
    var showsShadowsHint: Bool
    /// The selected light casts a shadow but has no shadow map because no
    /// casters sit in front of it (#673).
    var showsNoCastersHint: Bool
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

    /// `sceneShadowsOn`: the scene's Shadows switch (metal_shadows) as last
    /// read, nil when unknown.
    @MainActor
    init?(_ controller: LightsController, sceneShadowsOn: Bool? = nil) {
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
        isShadowed = light.shadow
        notice = controller.shadowRefused ? Self.shadowCapNotice : nil
        showsShadowsHint = light.shadow && sceneShadowsOn == false
        showsNoCastersHint = Self.showsNoCastersHint(
            isShadowed: light.shadow,
            rigOn: controller.isOn,
            sceneShadowsOn: sceneShadowsOn,
            shadowSlot: controller.facing.shadowSlot(of: light.name))
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
    var shadowValue: String { isShadowed ? "On" : "Off" }
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
        return "\(name) slot=\(slot) pin=\(isPinned ? 1 : 0) shadow=\(isShadowed ? 1 : 0) on=\(isOn ? 1 : 0)"
            + " orbit=\(v(.orbit, "%.1f")) pitch=\(v(.pitch, "%.1f")) radius=\(v(.radius, "%.2f"))"
            + " intensity=\(v(.intensity, "%.2f")) warmth=\(v(.warmth, "%.0f"))"
            + " beam=\(v(.beam, "%.1f")) softness=\(v(.softness, "%.2f"))"
            + " color=\(rgb) swatch=\(swatch) edit=\(canEdit ? 1 : 0) revert=\(canRevertLight ? 1 : 0)"
            + (notice == nil ? "" : " notice=shadow_cap") + (showsShadowsHint ? " hint=shadows_off" : "")
            + (showsNoCastersHint ? " hint=no_casters" : "")
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
/// - A selection change drops the typed text (`selectionChanged`), and so
///   does a gesture beginning on the light (`gestureBegan`: a drag on the
///   orbit plan or the gizmo), so a later Return never writes the typed value
///   over the gesture's edit.
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

    /// A direct-manipulation gesture began on `light`
    /// (`LightsController.gestureGeneration` changed): typed text is dropped
    /// and editing ends, as on a selection change.
    mutating func gestureBegan(value: Double?, light: String?) {
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

/// The inspector's row metrics, shared with the Atmosphere card (#726).
enum InspectorMetrics {
    static let labelWidth: CGFloat = 58
    static let valueWidth: CGFloat = 78
    static let fieldWidth: CGFloat = 60
    static let font = Font.system(size: 12)
    static let valueFont = Font.system(size: 11).monospacedDigit()

    /// The HStack spacing of an inspector row.
    static let rowSpacing: CGFloat = 6

    /// The width of the Orbit and Pitch steppers' touch buttons (minus and
    /// plus, each a `minimum` pt square) on iOS (#720); 0 when `minimum` is 0
    /// (macOS draws the system stepper).
    static func touchStepperWidth(minimum: CGFloat) -> CGFloat { 2 * minimum }

    /// The narrowest an Orbit or Pitch row can be with touch buttons: label,
    /// dial, field, the two buttons, and the gaps between the five children
    /// (the spacer included).
    static func angleRowMinimumWidth(minimum: CGFloat) -> CGFloat {
        labelWidth + LightAngleDial.side + fieldWidth + touchStepperWidth(minimum: minimum)
            + 4 * rowSpacing
    }
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
/// A gesture beginning on the light (`gestureGeneration` changes) drops the
/// typed text and the focus.
struct LightAngleFieldRow: View {
    let controller: LightsController
    let parameter: LightParameter
    let row: LightsInspectorState.Row?
    let lightName: String?
    let style: LightsBarStyle
    let gestureGeneration: Int

    @State private var editor: LightFieldEditor
    @FocusState private var focused: Bool

    init(controller: LightsController, parameter: LightParameter,
         row: LightsInspectorState.Row?, lightName: String?, style: LightsBarStyle,
         gestureGeneration: Int) {
        self.controller = controller
        self.parameter = parameter
        self.row = row
        self.lightName = lightName
        self.style = style
        self.gestureGeneration = gestureGeneration
        _editor = State(initialValue: LightFieldEditor(parameter: parameter))
    }

    var body: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
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
            LightAngleStepper(parameter: parameter, spoken: row?.spoken ?? "", style: style) { step in
                controller.step(parameter, by: step)
            }
        }
        .onAppear { editor.show(row?.value, light: lightName) }
        .onChange(of: row?.value) { editor.show(row?.value, light: lightName) }
        .onChange(of: lightName) {
            editor.selectionChanged(to: lightName, value: row?.value)
            focused = false
        }
        // Editing has ended before the focus goes, so the focus change below
        // commits nothing.
        .onChange(of: gestureGeneration) {
            editor.gestureBegan(value: row?.value, light: lightName)
            focused = false
        }
        .onChange(of: focused) { _, now in
            if now { editor.begin(light: lightName) } else { commit() }
        }
        // The iPhone sheet and the side panel keep the scene's size while a
        // field has the keyboard (#623): they read this.
        .preference(key: LightsFieldFocusKey.self, value: focused)
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

/// An Orbit or Pitch stepper: two 44 pt touch buttons on iOS (#720), or the
/// system stepper on macOS.
struct LightAngleStepper: View {
    let parameter: LightParameter
    let spoken: String
    let style: LightsBarStyle
    let onStep: (Double) -> Void

    @Environment(\.lightsTouchMinimum) private var touchMinimum

    var body: some View {
        if touchMinimum > 0 {
            HStack(spacing: 0) {
                button("minus", by: -LightsInspectorState.stepperStep)
                Rectangle().fill(style.text.opacity(0.25)).frame(width: 1, height: 18)
                button("plus", by: LightsInspectorState.stepperStep)
            }
            .background(Capsule().fill(style.text.opacity(0.12)).frame(height: 32))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parameter.label)
            .accessibilityValue(spoken)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onStep(LightsInspectorState.stepperStep)
                case .decrement: onStep(-LightsInspectorState.stepperStep)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("lights.inspector.\(parameter.field).stepper")
        } else {
            Stepper(parameter.label,
                    onIncrement: { onStep(LightsInspectorState.stepperStep) },
                    onDecrement: { onStep(-LightsInspectorState.stepperStep) })
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel(parameter.label)
                .accessibilityValue(spoken)
                .accessibilityIdentifier("lights.inspector.\(parameter.field).stepper")
        }
    }

    private func button(_ name: String, by step: Double) -> some View {
        Button {
            onStep(step)
        } label: {
            Image(systemName: name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(style.text)
                .frame(width: touchMinimum, height: touchMinimum)
                .contentShape(Rectangle())
                .lightsTouchTarget()
        }
        .buttonStyle(.plain)
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
                               lightName: name, style: style,
                               gestureGeneration: controller.gestureGeneration)
                .id("orbit.\(name ?? "")")
            LightAngleFieldRow(controller: controller, parameter: .pitch,
                               row: LightsInspectorState.row(.pitch, of: controller),
                               lightName: name, style: style,
                               gestureGeneration: controller.gestureGeneration)
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

// MARK: - Chip

/// A toggle drawn as the bar's chips are, so On reads at a glance (the system
/// button-style toggle barely changes on macOS): the inspector's Shadow and
/// Pin, and the Atmosphere card's switch (#726). A 44 pt target on iOS.
struct LightsChip: View {
    var title: String
    var systemImage: String?
    var on: Bool
    var enabled: Bool
    var style: LightsBarStyle
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(on ? style.accent : style.text.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? style.accent.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(on ? style.accent : style.text.opacity(0.25),
                                      lineWidth: on ? 1.5 : 1))
            .contentShape(Capsule())
            .lightsTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(.isToggle)
    }
}

// MARK: - The card

/// True while an Orbit or Pitch field has the keyboard focus. The iPhone
/// sheet and the side panel (#623) forward it, so the viewport does not
/// resize for the keyboard while a Lights field is edited.
struct LightsFieldFocusKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// What part of the inspector a view draws:
/// - `card`: the whole card (#620: the side column, the iPad float);
/// - `header`: the identity dot, the light menu, the status line, Shadow and
///   Pin, then the cap notice and the Shadows hint (with Turn On); no
///   chevron, fixed width or card chrome (the iPhone sheet's header row);
/// - `rows`: the content rows and the footer only; no header, inner
///   ScrollView or chrome (the sheet and the side panel scroll them).
enum LightsInspectorPresentation: Equatable {
    case card, header, rows
}

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
    /// The controller's `facing`, observed for the shadow slots (#673's
    /// "No casters" line); it publishes only when a value changes.
    @ObservedObject var facing: LightsFacingState
    var style: LightsBarStyle
    /// The scene's Shadows switch (metal_shadows) as last read; nil when
    /// unknown (no Shadows hint then).
    var sceneShadowsOn: Bool?
    /// Turn the scene's Shadows switch on (the hint's Turn On button).
    var onEnableSceneShadows: () -> Void
    /// The whole card, or only its header or rows (#623's sheet).
    var presentation: LightsInspectorPresentation

    /// Collapsed to its header row. Plain view state, seeded per mode entry and
    /// never persisted (the test host shares the installed app's defaults).
    @State private var collapsed: Bool
    /// The content's measured height: the card is as tall as its content and
    /// scrolls only when the space is shorter. One content tree (no
    /// ViewThatFits), so a resize never resets a field's text or focus.
    @State private var contentHeight: CGFloat = LightsInspector.estimatedHeight
    /// The colour row's measured width: how many columns of 44 pt swatches
    /// it lays out on iOS (`LightsTouch.swatchColumns`).
    @State private var colourWidth: CGFloat = LightsInspector.width - 24
    /// 44 on iOS (every control a 44 pt target, #623), 0 on macOS.
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    static let width: CGFloat = 284
    static let estimatedHeight: CGFloat = 480

    init(controller: LightsController, style: LightsBarStyle, initiallyCollapsed: Bool = false,
         sceneShadowsOn: Bool? = nil, onEnableSceneShadows: @escaping () -> Void = {},
         presentation: LightsInspectorPresentation = .card) {
        self.controller = controller
        _facing = ObservedObject(wrappedValue: controller.facing)
        self.style = style
        self.sceneShadowsOn = sceneShadowsOn
        self.onEnableSceneShadows = onEnableSceneShadows
        self.presentation = presentation
        _collapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        if let state = LightsInspectorState(controller, sceneShadowsOn: sceneShadowsOn) {
            switch presentation {
            case .card:
                card(state)
            case .header:
                headerBlock(state)
            case .rows:
                content(state)
                    .tint(style.accent)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("lights.inspector.rows")
            }
        }
    }

    /// The `header` presentation: the header row without its chevron, then
    /// the notice and the Shadows hint, which answer the header's Shadow chip.
    private func headerBlock(_ state: LightsInspectorState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(state, showsChevron: false)
                .padding(.vertical, touchMinimum > 0 ? 0 : 8)
            if let notice = state.notice {
                noticeRow(notice).padding(.bottom, 8)
            }
            if state.showsShadowsHint {
                shadowsHintRow(state).padding(.bottom, 8)
            }
            if state.showsNoCastersHint {
                noCastersHintRow().padding(.bottom, 8)
            }
        }
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier("lights.inspector.header")
    }

    private func card(_ state: LightsInspectorState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(state, showsChevron: true)
                // The 44 pt targets carry the header's height on iOS.
                .padding(.horizontal, 12).padding(.vertical, touchMinimum > 0 ? 0 : 8)
            // Shown even while collapsed: both answer the header's Shadow chip.
            if let notice = state.notice {
                noticeRow(notice)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if state.showsShadowsHint {
                shadowsHintRow(state)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if state.showsNoCastersHint {
                noCastersHintRow()
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
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

    private func header(_ state: LightsInspectorState, showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            // The status goes under the name, so the Shadow and Pin chips
            // leave room for any light name and `Lights off`.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(LightPalette.color(state.slot))
                        .frame(width: 10, height: 10)
                        .opacity(state.isOn ? 1 : 0.45)
                        .accessibilityHidden(true)
                    lightMenu(state)
                }
                if let status = state.status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundColor(style.text.opacity(0.55))
                        .lineLimit(1)
                        .padding(.leading, 16)
                }
            }
            Spacer(minLength: 2)
            shadowToggle(state)
            pinToggle(state)
            if showsChevron {
                Button { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(style.text.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .lightsTouchTarget()
                }
                .buttonStyle(.plain)
                .help(LightsInspectorState.collapseLabel(collapsed: collapsed))
                .accessibilityLabel(LightsInspectorState.collapseLabel(collapsed: collapsed))
                .accessibilityIdentifier("lights.inspector.collapse")
            }
        }
    }

    private func shadowToggle(_ state: LightsInspectorState) -> some View {
        let on = state.isShadowed
        return chip(LightsInspectorState.shadowLabel, systemImage: nil, on: on,
                    enabled: state.canEdit) { controller.setShadow(!on) }
            .help(LightsInspectorState.shadowHelp)
            .accessibilityLabel(LightsInspectorState.shadowLabel)
            .accessibilityValue(state.shadowValue)
            .accessibilityIdentifier("lights.inspector.shadow")
    }

    private func pinToggle(_ state: LightsInspectorState) -> some View {
        let on = state.isPinned
        return chip(LightsInspectorState.pinLabel, systemImage: on ? "pin.fill" : "pin", on: on,
                    enabled: state.canEdit) { controller.setPinned(!on) }
            .help(LightsInspectorState.pinHelp)
            .accessibilityLabel(LightsInspectorState.pinLabel)
            .accessibilityValue(state.pinValue)
            .accessibilityIdentifier("lights.inspector.pin")
    }

    // A toggle drawn as the bar's chips are (LightsChip, shared with the
    // Atmosphere card's switch).
    private func chip(_ title: String, systemImage: String?, on: Bool, enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        LightsChip(title: title, systemImage: systemImage, on: on, enabled: enabled, style: style,
                   action: action)
    }

    // MARK: notice and hint

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .accessibilityHidden(true)
            Text(verbatim: notice)
                .font(.system(size: 11))
                .foregroundColor(style.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lights.inspector.notice")
    }

    private func shadowsHintRow(_ state: LightsInspectorState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(style.text.opacity(0.7))
                .accessibilityHidden(true)
            Text(LightsInspectorState.shadowsOffHint)
                .font(.system(size: 11))
                .foregroundColor(style.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("lights.inspector.shadows_hint")
            Spacer(minLength: 4)
            Button(LightsInspectorState.turnOnTitle) { onEnableSceneShadows() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11, weight: .medium))
                .disabled(!state.canEdit)
                .help(LightsInspectorState.turnOnHelp)
                .accessibilityLabel(LightsInspectorState.turnOnLabel)
                .accessibilityIdentifier("lights.inspector.shadows_turn_on")
        }
    }

    private func noCastersHintRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundColor(style.text.opacity(0.55))
                .accessibilityHidden(true)
            Text(LightsInspectorState.noCastersHint)
                .font(.system(size: 11))
                .foregroundColor(style.text.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lights.inspector.no_casters_hint")
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
            .lightsTouchTarget()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Its own height, but a long name truncates rather than pushing the
        // chips (and the phone sheet's Atmosphere and More buttons) off the
        // row (#726).
        .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private func colourRow(_ state: LightsInspectorState) -> some View {
        if touchMinimum > 0 {
            touchColourRow(state)
        } else {
            HStack(spacing: 5) {
                colourLabel
                ForEach(state.swatches) { swatch in
                    swatchButton(swatch, dot: 15, padding: 2)
                }
                Spacer(minLength: 2)
                colourPicker(state)
            }
        }
    }

    /// iOS: the label and the custom picker (a 44 pt target) on one line, the
    /// six swatches below as 44 pt targets, all six in a row when the width
    /// fits them (a phone sheet) or three per row (the 284 pt card).
    private func touchColourRow(_ state: LightsInspectorState) -> some View {
        let columns = LightsTouch.swatchColumns(width: colourWidth)
        let swatches = state.swatches
        let rows = stride(from: 0, to: swatches.count, by: columns).map {
            Array(swatches[$0..<min($0 + columns, swatches.count)])
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                colourLabel
                Spacer(minLength: 2)
                colourPicker(state)
                    .frame(minWidth: touchMinimum, minHeight: touchMinimum)
                    .contentShape(Rectangle())
            }
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(rows[r]) { swatch in
                        swatchButton(swatch, dot: 24, padding: 3, target: LightsTouch.swatchTarget)
                    }
                    // A short last row keeps the columns of the rows above.
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, minHeight: LightsTouch.swatchTarget)
                    }
                }
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { colourWidth = g.size.width }
                .onChange(of: g.size.width) { _, width in colourWidth = width }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lights.inspector.colour")
    }

    private var colourLabel: some View {
        Text("Colour")
            .font(InspectorMetrics.font)
            .foregroundColor(style.text.opacity(0.8))
            .frame(width: InspectorMetrics.labelWidth - 1, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// One swatch: a dot of `dot` points ringed in the accent when selected;
    /// with a `target`, the label is that tall and shares the row's width
    /// with the other swatches (iOS), so the whole cell is hit.
    @ViewBuilder
    private func swatchButton(_ swatch: LightsInspectorState.Swatch, dot: CGFloat, padding: CGFloat,
                              target: CGFloat? = nil) -> some View {
        Button { controller.setColour(swatch.rgb) } label: {
            let ring = Circle()
                .fill(Color(.sRGB, red: swatch.rgb.x, green: swatch.rgb.y,
                            blue: swatch.rgb.z, opacity: 1))
                .overlay(Circle().stroke(style.text.opacity(0.3), lineWidth: 0.5))
                .frame(width: dot, height: dot)
                .padding(padding)
                .overlay(Circle().stroke(swatch.isSelected ? style.accent : Color.clear,
                                         lineWidth: 1.5))
            if let target {
                ring
                    .frame(maxWidth: .infinity, minHeight: target)
                    .contentShape(Rectangle())
            } else {
                ring.contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help(swatch.name)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(swatch.isSelected ? .isSelected : [])
        .accessibilityIdentifier("lights.inspector.swatch.\(swatch.name.lowercased())")
    }

    private func colourPicker(_ state: LightsInspectorState) -> some View {
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
/// `shadow:0|1`, `color:r:g:b` (0...1), `expand` (the phone light sheet
/// starts expanded; the iPad inspector expanded), `corner:tl|tr|bl|br` (the
/// iPad's floating orbit view starts there, for this run only: nothing is
/// stored), the orbit view's gestures (`tap:`,
/// `plan:`, `square:`, `arc:`, `pinch:`; OrbitAutoGesture parses and runs
/// them through LightsOrbitInteraction) and the gizmo's (`knob:`, `flip:`,
/// `outer:`, `inner:`, `aimat:`, `wheel:`, `kpinch:`, `hl:`, `gshadow:`;
/// GizmoAutoGesture parses and runs them through LightGizmoInteraction).
/// The Atmosphere card's (#726): `<air field>:<value>` for haze, dust,
/// dust_size, dust_speed and scatter (the card's `setAir`, the bridge
/// setter at index -1), `airon:0|1` (the card's switch, `setAtmosphere(on:)`,
/// one echoed `atmosphere` command) and `air` (the macOS and iPad card
/// starts expanded; the phone sheet starts expanded and reveals the
/// Atmosphere section as its header button does; with no light the
/// air-only sheet already shows it).
enum LightsAutoEdit {
    enum Token: Equatable {
        case set(LightParameter, Double)
        case pin(Bool)
        case shadow(Bool)
        case color(SIMD3<Double>)
        case expand
        case corner(LightsFloatCorner)
        case gesture(OrbitAutoGesture)
        case gizmo(GizmoAutoGesture)
        case air(AirParameter, Double)
        case airOn(Bool)
        case revealAir
    }

    struct Parsed: Equatable {
        var tokens: [Token] = []
        /// Tokens that were not understood (unknown names, bad numbers).
        var rejected: [String] = []

        var expands: Bool { tokens.contains(.expand) }
        /// The `air` token: the Atmosphere card starts expanded and the
        /// phone sheet reveals its Atmosphere section.
        var revealsAir: Bool { tokens.contains(.revealAir) }
        /// The last `corner:` token's corner (nil: the stored one).
        var corner: LightsFloatCorner? {
            tokens.reduce(nil) { found, token in
                if case .corner(let corner) = token { return corner }
                return found
            }
        }
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        for raw in text.split(separator: ";") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            // A gizmo or orbit-view gesture's key: it parses, or it is
            // rejected (never passed on to the inspector's forms).
            if GizmoAutoGesture.claims(token) {
                if let gesture = GizmoAutoGesture.parse(token) {
                    parsed.tokens.append(.gizmo(gesture))
                } else {
                    parsed.rejected.append(token)
                }
                continue
            }
            if OrbitAutoGesture.claims(token) {
                if let gesture = OrbitAutoGesture.parse(token) {
                    parsed.tokens.append(.gesture(gesture))
                } else {
                    parsed.rejected.append(token)
                }
                continue
            }
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let key = parts[0].lowercased()
            let numbers = parts.dropFirst().map { Double($0.trimmingCharacters(in: .whitespaces)) }
            let finite = numbers.compactMap { $0 }.filter(\.isFinite)
            let allNumbers = finite.count == numbers.count
            if key == "expand", parts.count == 1 {
                parsed.tokens.append(.expand)
            } else if key == "air", parts.count == 1 {
                parsed.tokens.append(.revealAir)
            } else if key == "airon", parts.count == 2, allNumbers, finite[0] == 0 || finite[0] == 1 {
                parsed.tokens.append(.airOn(finite[0] == 1))
            } else if let parameter = AirParameter(rawValue: key), parts.count == 2, allNumbers {
                parsed.tokens.append(.air(parameter, finite[0]))
            } else if key == "corner", parts.count == 2,
                      let corner = LightsFloatCorner(rawValue: parts[1].trimmingCharacters(in: .whitespaces)
                        .lowercased()) {
                parsed.tokens.append(.corner(corner))
            } else if key == "pin" || key == "shadow", parts.count == 2, allNumbers,
                      finite[0] == 0 || finite[0] == 1 {
                parsed.tokens.append(key == "pin" ? .pin(finite[0] == 1) : .shadow(finite[0] == 1))
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
    /// per edit (`expand`, `corner:` and `air` are layout choices, applied
    /// before the mode opens). An air field's entry is
    /// `haze=0.3 -> ok` (the rig's air, whatever is selected); the switch's
    /// `airon=1 -> ran` (a command ran) or `-> skipped` (already in that
    /// state, or the switch cannot be pressed).
    /// A gesture's entry is `<token> -> <result> <field>=<value>`. Gizmo
    /// gestures run with `gizmo` (the overlay's size and the engine's
    /// picker); without it each logs `<token> -> noview`.
    /// `orbitPlanSize` and `orbitArcSize`: the orbit canvases' sizes in the
    /// active placement (OrbitAutoGesture.apply), the card's by default.
    @MainActor
    static func apply(_ tokens: [Token], to controller: LightsController,
                      gizmo: GizmoAutoContext? = nil,
                      orbitPlanSize: CGSize = LightsOrbitMetrics.planSize,
                      orbitArcSize: CGSize = LightsOrbitMetrics.arcSize) -> [String] {
        tokens.compactMap { token in
            switch token {
            case .set(let parameter, let value):
                return "\(parameter.field)=\(fmt(value)) -> \(controller.set(parameter, value))"
            case .pin(let on):
                return "pin=\(on ? 1 : 0) -> \(controller.setPinned(on))"
            case .shadow(let on):
                return "shadow=\(on ? 1 : 0) -> \(controller.setShadow(on))"
            case .color(let rgb):
                return "color=\(fmt(rgb.x)):\(fmt(rgb.y)):\(fmt(rgb.z)) -> \(controller.setColour(rgb))"
            case .air(let parameter, let value):
                return "\(parameter.field)=\(fmt(value)) -> \(controller.setAir(parameter, value))"
            case .airOn(let on):
                return "airon=\(on ? 1 : 0) -> \(controller.setAtmosphere(on: on) ? "ran" : "skipped")"
            case .expand, .corner, .revealAir:
                return nil
            case .gesture(let gesture):
                return OrbitAutoGesture.apply(gesture, to: controller, planSize: orbitPlanSize,
                                              arcSize: orbitArcSize)
            case .gizmo(let gesture):
                return GizmoAutoGesture.apply(gesture, to: controller, context: gizmo)
            }
        }
    }

    private static func fmt(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(format: "%.0f", x) : String(x)
    }
}
#endif
