// LightsAtmosphereCard.swift — the Atmosphere card (#726): the rig's haze and
// dust in Lights mode.
//
// A view over LightsController (the ONE Lights model) and the air model in
// LightsAtmosphere.swift. Its header holds the On/Off switch (a LightsChip, as
// the inspector's Shadow and Pin); its rows are Haze, Dust, Dust size and Dust
// speed (on a square-root track), each a slider with a typed field, and
// Scatter (g) under a disclosure. One hint at a time says why the air may not
// show (AtmosphereHint); a collapsed card shows it as a header glyph, so a
// collapsed card is always one header row tall (44 pt on iOS).
// - Slider ticks and typed values write through the typed air API
//   (`setAirIfChanged` / `setAir` -> the bridge setter at index -1): no Python
//   per drag tick (#610).
// - The switch is a button press: `setAtmosphere(on:)` runs one echoed
//   `atmosphere` command through the controller's actions.
// So this file names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py checks that). It registers no undo:
// light edits have none either, and the bar's Revert is the way back.
//
// Where it sits (LightsAtmospherePresentation):
// - macOS: a third card under the inspector in the side column
//   (LightsSideColumn.swift), keeping its height in a short column;
// - iPad: under the inspector in the float (LightsFloatingTools.swift),
//   collapsed to its header by default;
// - iPhone: a section after the inspector rows in the sheet and the side
//   panel, and the header and rows of the air-only sheet with no light
//   (LightsSheet.swift).
// Unlike the inspector it draws with no light and with no rig.

import SwiftUI

// MARK: - Presentation and metrics

/// What part of the card a view draws:
/// - `card`: the whole card with its chrome and a collapse chevron (the macOS
///   column, the iPad float);
/// - `section`: a hairline, the header without the chevron, the hint and the
///   rows; no chrome and no inner ScrollView (the iPhone sheet scrolls it);
/// - `header`: the glyph, the title and the switch (the air-only sheet's
///   header row);
/// - `rows`: the hint and the rows (the air-only sheet's body).
enum LightsAtmospherePresentation: Equatable {
    case card, section, header, rows
}

enum AtmosphereCardMetrics {
    /// The row labels (`Dust speed`, `Scatter (g)`) are wider than the
    /// inspector's.
    static let labelWidth: CGFloat = 70
    /// The rows' first layout before they are measured (the card is as tall
    /// as its content).
    static let estimatedRowsHeight: CGFloat = 170
}

/// The focused atmosphere field's row id, for the phone sheet: it scrolls
/// that row into view above the keyboard (nil: no atmosphere field has the
/// keyboard). The first non-nil value wins.
struct LightsSheetScrollTargetKey: PreferenceKey {
    static var defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if value == nil { value = nextValue() }
    }
}

/// The card's identifiers and fixed strings. Pure.
enum AtmosphereCardIDs {
    static let card = "lights.atmosphere"
    static let toggle = "lights.atmosphere.switch"
    static let collapse = "lights.atmosphere.collapse"
    static let hint = "lights.atmosphere.hint"
    static let scatterDisclosure = "lights.atmosphere.scatter.disclosure"
    static let section = "lights.atmosphere.section"
    static let header = "lights.atmosphere.header"
    static let rows = "lights.atmosphere.rows"
    static let sheetButton = "lights.sheet.atmosphere"

    static func slider(_ p: AirParameter) -> String { "lights.atmosphere.\(p.field)" }
    static func field(_ p: AirParameter) -> String { "lights.atmosphere.\(p.field).field" }
    /// The row's id in a ScrollView (the sheet's scroll target).
    static func row(_ p: AirParameter) -> String { "lights.atmosphere.row.\(p.field)" }

    static func collapseLabel(collapsed: Bool) -> String {
        collapsed ? "Show the atmosphere settings" : "Hide the atmosphere settings"
    }

    static let switchHelp = "Turn the haze and dust on or off"
    static let scatterLabel = "Scatter"
    static func scatterValue(_ spoken: String, shown: Bool) -> String {
        "\(spoken), \(shown ? "shown" : "hidden")"
    }
    static func fieldLabel(_ p: AirParameter) -> String { "\(p.label) value" }

    static let sheetButtonLabel = "Atmosphere"
    static let sheetButtonHint = "Shows the haze and dust settings"
}

private struct AtmosphereContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The card

/// The Atmosphere card. Draws nothing unless Lights mode is active
/// (AtmosphereCardState is nil otherwise).
struct LightsAtmosphereCard: View {
    @ObservedObject var controller: LightsController
    /// Which lights are behind the molecule: the backlit-haze hint follows a
    /// crossing without per-frame redraws (published only on a crossing).
    @ObservedObject var facing: LightsFacingState
    var style: LightsBarStyle
    var presentation: LightsAtmospherePresentation

    /// Collapsed to its header row (`card` only). Seeded per mode entry from
    /// the start state, never persisted.
    @State private var collapsed: Bool
    /// Scatter's row is shown (the disclosure).
    @State private var showsScatter: Bool
    /// The rows' measured height: the card is as tall as its content and
    /// scrolls only when the space is shorter (one content tree, so a resize
    /// never resets a field).
    @State private var contentHeight: CGFloat = AtmosphereCardMetrics.estimatedRowsHeight
    /// 44 on iOS (every control a 44 pt target), 0 on macOS.
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    init(controller: LightsController, style: LightsBarStyle,
         presentation: LightsAtmospherePresentation = .card,
         start: LightsAtmosphereStart = .expanded, showsScatter: Bool = false) {
        self.controller = controller
        _facing = ObservedObject(wrappedValue: controller.facing)
        self.style = style
        self.presentation = presentation
        _collapsed = State(initialValue: !start.startsExpanded(airIsOn: controller.airIsOn))
        _showsScatter = State(initialValue: showsScatter)
    }

    var body: some View {
        if let state = AtmosphereCardState(controller, behind: facing.behind) {
            switch presentation {
            case .card:
                card(state)
            case .section:
                section(state)
            case .header:
                header(state, showsChevron: false)
                    .tint(style.accent)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(state.containerLabel)
                    .accessibilityIdentifier(AtmosphereCardIDs.header)
            case .rows:
                content(state)
                    .tint(style.accent)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AtmosphereCardIDs.rows)
            }
        }
    }

    private func card(_ state: AtmosphereCardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(state, showsChevron: true)
                // The 44 pt targets carry the header's height on iOS.
                .padding(.horizontal, 12).padding(.vertical, touchMinimum > 0 ? 0 : 8)
            if !collapsed {
                Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
                ScrollView(.vertical) {
                    content(state)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AtmosphereContentHeightKey.self, value: g.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: contentHeight)
                .onPreferenceChange(AtmosphereContentHeightKey.self) { height in
                    if height > 0, abs(height - contentHeight) > 0.5 { contentHeight = height }
                }
            }
        }
        .frame(width: LightsInspector.width)
        .background(style.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.text.opacity(0.18), lineWidth: 0.5))
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier(AtmosphereCardIDs.card)
    }

    private func section(_ state: AtmosphereCardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
            header(state, showsChevron: false)
                .padding(.vertical, touchMinimum > 0 ? 0 : 8)
            content(state)
                .padding(.top, 4)
        }
        .tint(style.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.containerLabel)
        .accessibilityIdentifier(AtmosphereCardIDs.section)
        .id(LightsSheetState.atmosphereAnchor)
    }

    // MARK: header

    private func header(_ state: AtmosphereCardState, showsChevron: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: AtmosphereCardState.systemImage)
                .font(.system(size: 12))
                .foregroundColor(style.text.opacity(0.75))
                .accessibilityHidden(true)
            Text(AtmosphereCardState.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(style.text)
                .lineLimit(1)
                .accessibilityHidden(true)
            // A collapsed card shows its hint as a glyph, so it stays one
            // header row tall whatever the hint.
            if showsChevron, collapsed, let glyph = state.collapsedGlyph {
                Image(systemName: glyph.systemImage)
                    .font(.system(size: 11))
                    .foregroundColor(hintColour(state.hint))
                    .help(glyph.label)
                    .accessibilityLabel(glyph.label)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier(AtmosphereCardIDs.hint)
            }
            Spacer(minLength: 2)
            LightsChip(title: state.switchValue, systemImage: nil, on: state.isOn,
                       enabled: state.canToggle, style: style) {
                _ = controller.setAtmosphere(on: !state.isOn)
            }
            .help(AtmosphereCardIDs.switchHelp)
            .accessibilityLabel(AtmosphereCardState.title)
            .accessibilityValue(state.switchValue)
            .accessibilityIdentifier(AtmosphereCardIDs.toggle)
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
                .help(AtmosphereCardIDs.collapseLabel(collapsed: collapsed))
                .accessibilityLabel(AtmosphereCardIDs.collapseLabel(collapsed: collapsed))
                .accessibilityIdentifier(AtmosphereCardIDs.collapse)
            }
        }
    }

    private func hintColour(_ hint: AtmosphereHint?) -> Color {
        hint == .noLights ? style.text.opacity(0.7) : .orange
    }

    // MARK: content

    private func content(_ state: AtmosphereCardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let hint = state.hint {
                hintRow(hint)
            }
            if state.isUnavailable {
                Text(AtmosphereCardState.unavailableText)
                    .font(.system(size: 11))
                    .foregroundColor(style.text.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("lights.atmosphere.unavailable")
            } else {
                VStack(alignment: .leading, spacing: touchMinimum > 0 ? 0 : 8) {
                    ForEach([AirParameter.haze, .dust, .dustSize, .dustSpeed], id: \.self) { p in
                        sliderRow(p, state)
                    }
                    scatterDisclosure(state)
                    if showsScatter {
                        sliderRow(.scatter, state)
                        Text(AtmosphereCardState.scatterNote)
                            .font(.system(size: 11))
                            .foregroundColor(style.text.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!state.canEdit)
                .opacity(state.canEdit ? 1 : 0.5)
            }
        }
    }

    private func hintRow(_ hint: AtmosphereHint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: hint.glyph)
                .font(.system(size: 10))
                .foregroundColor(hintColour(hint))
                .accessibilityHidden(true)
            Text(hint.text)
                .font(.system(size: 11))
                .foregroundColor(style.text.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AtmosphereCardIDs.hint)
    }

    @ViewBuilder
    private func sliderRow(_ p: AirParameter, _ state: AtmosphereCardState) -> some View {
        if let row = state.row(p), let field = controller.airField(p) {
            AtmosphereSliderRow(controller: controller, row: row, field: field, style: style)
                .id(AtmosphereCardIDs.row(p))
        }
    }

    @ViewBuilder
    private func scatterDisclosure(_ state: AtmosphereCardState) -> some View {
        if let row = state.row(.scatter) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsScatter.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(AirParameter.scatter.label)
                        .font(InspectorMetrics.font)
                        .foregroundColor(style.text.opacity(0.8))
                    Spacer(minLength: 4)
                    // Shown, the row's field carries the value.
                    if !showsScatter {
                        Text(verbatim: row.text)
                            .font(InspectorMetrics.valueFont)
                            .foregroundColor(style.text)
                    }
                    Image(systemName: showsScatter ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(style.text.opacity(0.6))
                }
                .contentShape(Rectangle())
                .lightsTouchTarget(width: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AtmosphereCardIDs.scatterLabel)
            .accessibilityValue(AtmosphereCardIDs.scatterValue(row.spoken, shown: showsScatter))
            .accessibilityIdentifier(AtmosphereCardIDs.scatterDisclosure)
        }
    }
}

// MARK: - A row

/// One air row: label, slider and typed field. A slider tick writes the value
/// at its position on the slider's grid (`setAirIfChanged`, the bridge setter:
/// no Python); the first tick drops the field's typed text and focus
/// (AirFieldEditor.sliderMoved), so a later Return never writes stale text
/// over the drag. Return or focus loss writes the typed value exactly (the
/// core clamps; the field then shows the clamped value). At least a 44 pt row
/// on iOS.
struct AtmosphereSliderRow: View {
    let controller: LightsController
    let row: AtmosphereCardState.Row
    let field: AirField
    let style: LightsBarStyle

    @State private var editor: AirFieldEditor
    @FocusState private var focused: Bool
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    init(controller: LightsController, row: AtmosphereCardState.Row, field: AirField, style: LightsBarStyle) {
        self.controller = controller
        self.row = row
        self.field = field
        self.style = style
        _editor = State(initialValue: AirFieldEditor(parameter: row.parameter))
    }

    var body: some View {
        let p = row.parameter
        HStack(spacing: 6) {
            Text(p.label)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(0.8))
                .lineLimit(1)
                .frame(width: AtmosphereCardMetrics.labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: Binding(get: { p.sliderPosition(row.value, field) },
                                  set: { slid(to: $0) }),
                   in: p.sliderRange(field),
                   onEditingChanged: { began in if began { dropTyping() } })
                .controlSize(.small)
                .accessibilityLabel(p.label)
                .accessibilityValue(row.spoken)
                .accessibilityIdentifier(AtmosphereCardIDs.slider(p))
            TextField(p.label, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(InspectorMetrics.valueFont)
                .multilineTextAlignment(.trailing)
                .frame(width: InspectorMetrics.fieldWidth)
                .focused($focused)
                .onSubmit { commit() }
                .lightsNumberKeyboard()
                .accessibilityLabel(AtmosphereCardIDs.fieldLabel(p))
                .accessibilityIdentifier(AtmosphereCardIDs.field(p))
        }
        .frame(minHeight: touchMinimum)
        .onAppear { editor.show(row.value) }
        .onChange(of: row.value) { editor.show(row.value) }
        .onChange(of: focused) { _, now in
            if now { editor.begin() } else { commit() }
        }
        // The iPhone sheet and the side panel keep the scene's size while a
        // field has the keyboard (#623), and scroll the focused row into
        // view above it.
        .preference(key: LightsFieldFocusKey.self, value: focused)
        .preference(key: LightsSheetScrollTargetKey.self, value: focused ? AtmosphereCardIDs.row(p) : nil)
    }

    private var textBinding: Binding<String> {
        Binding(get: { editor.text }, set: { new in
            guard new != editor.text else { return }
            if !editor.isEditing { editor.begin() }
            editor.type(new)
        })
    }

    private func slid(to position: Double) {
        let p = row.parameter
        if editor.isEditing { dropTyping() }
        controller.setAirIfChanged(p, p.sliderValue(position, field))
    }

    /// The slider began moving: typed text is dropped and the focus goes
    /// (editing has ended first, so the focus change commits nothing).
    private func dropTyping() {
        editor.sliderMoved(value: controller.airValue(row.parameter))
        focused = false
    }

    private func commit() {
        let p = row.parameter
        if let value = editor.commit() {
            controller.setAir(p, value)
        }
        editor.show(controller.airValue(p))
    }
}

// MARK: - The phone sheet's Atmosphere button

/// The phone sheet header's Atmosphere button (a 44 pt glyph target): the
/// fog glyph, filled in the accent while the air is on, with a small badge
/// while a hint applies. `action` expands the sheet and scrolls to the
/// Atmosphere section (LightsSheet). Draws nothing unless Lights mode is
/// active.
struct LightsSheetAtmosphereButton: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var facing: LightsFacingState
    var style: LightsBarStyle
    var action: () -> Void

    init(controller: LightsController, style: LightsBarStyle, action: @escaping () -> Void) {
        self.controller = controller
        _facing = ObservedObject(wrappedValue: controller.facing)
        self.style = style
        self.action = action
    }

    var body: some View {
        if let state = AtmosphereCardState(controller, behind: facing.behind) {
            Button(action: action) {
                Image(systemName: state.isOn ? "cloud.fog.fill" : AtmosphereCardState.systemImage)
                    .font(.system(size: 15))
                    .foregroundColor(state.isOn ? style.accent : style.text.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if state.hint != nil {
                            Circle().fill(state.hint == .noLights ? style.text.opacity(0.6) : Color.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -1)
                        }
                    }
                    .contentShape(Rectangle())
                    .lightsTouchTarget()
            }
            .buttonStyle(.plain)
            .help(AtmosphereCardIDs.sheetButtonHint)
            .accessibilityLabel(AtmosphereCardIDs.sheetButtonLabel)
            .accessibilityValue(state.switchValue)
            .accessibilityHint(AtmosphereCardIDs.sheetButtonHint)
            .accessibilityIdentifier(AtmosphereCardIDs.sheetButton)
        }
    }
}
