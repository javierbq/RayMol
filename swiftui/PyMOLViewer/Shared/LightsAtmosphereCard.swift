// LightsAtmosphereCard.swift — the Atmosphere card (#726): the rig's haze and
// dust in Lights mode.
//
// A view over LightsController (the ONE Lights model) and the air model in
// LightsAtmosphere.swift. Its header holds the On/Off switch (a LightsChip, as
// the inspector's Shadow and Pin); its rows are Haze, Dust, Dust size and Dust
// speed (on a square-root track), each a slider with a typed field, and
// Scatter (g) and the dust Seed (a whole-number field, #740) under a
// disclosure. One hint at a time says why the air may not show
// (AtmosphereHint).
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
// - macOS and iPad: the header and rows in a popover off the Lights bar's
//   Atmosphere button (LightsAtmospherePopover, below; #889);
// - iPhone: a section after the inspector rows in the sheet and the side
//   panel, and the header and rows of the air-only sheet with no light
//   (LightsSheet.swift).
// Unlike the inspector it draws with no light and with no rig.

import SwiftUI

// MARK: - Presentation and metrics

/// What part of the card a view draws:
/// - `section`: a hairline, the header, the hint and the rows; no chrome and
///   no inner ScrollView (the iPhone sheet scrolls it);
/// - `header`: the glyph, the title and the switch (the air-only sheet's
///   header row, the popover's header);
/// - `rows`: the hint and the rows (the air-only sheet's body, the
///   popover's body).
enum LightsAtmospherePresentation: Equatable {
    case section, header, rows
}

enum AtmosphereCardMetrics {
    /// The row labels (`Dust speed`, `Scatter (g)`) are wider than the
    /// inspector's.
    static let labelWidth: CGFloat = 70
    /// The rows' first layout before they are measured (the popover is as
    /// tall as its content).
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

/// The inspector's and the Atmosphere card's own rows keep the focused field
/// in view (#725, #870): on the iPad float the column shrinks above the
/// keyboard after a field takes the focus, so each card's ScrollView scrolls
/// its focused row (`Key`) back into view when the focus moves and when its
/// height changes.
struct LightsCardFocusScroll<Key: PreferenceKey>: ViewModifier where Key.Value == String? {
    var proxy: ScrollViewProxy
    @State private var focusedRow: String?
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { height = g.size.height }
                    .onChange(of: g.size.height) { _, new in height = new }
            })
            .onPreferenceChange(Key.self) { focusedRow = $0 }
            .onChange(of: focusedRow) { reveal() }
            .onChange(of: height) { reveal() }
    }

    private func reveal() {
        guard let focusedRow else { return }
        proxy.scrollTo(focusedRow)
    }
}

/// The card's identifiers and fixed strings. Pure.
enum AtmosphereCardIDs {
    static let toggle = "lights.atmosphere.switch"
    static let hint = "lights.atmosphere.hint"
    static let scatterDisclosure = "lights.atmosphere.scatter.disclosure"
    static let seedField = "lights.atmosphere.seed.field"
    static let seedRow = "lights.atmosphere.row.seed"
    static let section = "lights.atmosphere.section"
    static let header = "lights.atmosphere.header"
    static let rows = "lights.atmosphere.rows"
    static let sheetButton = "lights.sheet.atmosphere"
    /// The macOS bar's Atmosphere button and its popover (#889).
    static let barButton = "lights.bar.atmosphere"
    static let popover = "lights.atmosphere.popover"
    /// The same entry as an item of the Lights bar's overflow menu (#795).
    static let menuItem = "lights.atmosphere.menu"

    static func slider(_ p: AirParameter) -> String { "lights.atmosphere.\(p.field)" }
    static func field(_ p: AirParameter) -> String { "lights.atmosphere.\(p.field).field" }
    /// The row's id in a ScrollView (the sheet's scroll target).
    static func row(_ p: AirParameter) -> String { "lights.atmosphere.row.\(p.field)" }

    static let switchHelp = "Turn the haze and dust on or off"
    static let scatterLabel = "Scatter"
    static func scatterValue(_ spoken: String, shown: Bool) -> String {
        "\(spoken), \(shown ? "shown" : "hidden")"
    }
    static func fieldLabel(_ p: AirParameter) -> String { "\(p.label) value" }
    static let seedFieldLabel = "Dust seed value"

    /// VoiceOver's name for the phone's Atmosphere entry (#795): a scene
    /// setting, not one of the selected light's.
    static let sheetButtonLabel = "Scene atmosphere"
    static let sheetButtonHint = "Shows the scene's haze and dust settings"
}

private struct AtmosphereContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - The card

/// The Atmosphere card's parts (`presentation`). Draws nothing unless Lights
/// mode is active (AtmosphereCardState is nil otherwise).
struct LightsAtmosphereCard: View {
    @ObservedObject var controller: LightsController
    /// Which lights are behind the molecule: the backlit-haze hint follows a
    /// crossing without per-frame redraws (published only on a crossing).
    @ObservedObject var facing: LightsFacingState
    var style: LightsBarStyle
    var presentation: LightsAtmospherePresentation

    /// Scatter's row is shown (the disclosure).
    @State private var showsScatter: Bool
    /// 44 on iOS (every control a 44 pt target), 0 on macOS.
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    init(controller: LightsController, style: LightsBarStyle,
         presentation: LightsAtmospherePresentation, showsScatter: Bool = false) {
        self.controller = controller
        _facing = ObservedObject(wrappedValue: controller.facing)
        self.style = style
        self.presentation = presentation
        _showsScatter = State(initialValue: showsScatter)
    }

    var body: some View {
        if let state = AtmosphereCardState(controller, behind: facing.behind) {
            switch presentation {
            case .section:
                section(state)
            case .header:
                header(state)
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

    private func section(_ state: AtmosphereCardState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
            header(state)
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

    private func header(_ state: AtmosphereCardState) -> some View {
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
            Spacer(minLength: 2)
            LightsChip(title: state.switchValue, systemImage: nil, on: state.isOn,
                       enabled: state.canToggle, style: style) {
                _ = controller.setAtmosphere(on: !state.isOn)
            }
            .help(AtmosphereCardIDs.switchHelp)
            .accessibilityLabel(AtmosphereCardState.title)
            .accessibilityValue(state.switchValue)
            .accessibilityIdentifier(AtmosphereCardIDs.toggle)
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
                        sliderRow(.dustGlow, state)
                        Text(AtmosphereCardState.glowNote)
                            .font(.system(size: 11))
                            .foregroundColor(style.text.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                        sliderRow(.dustOpacity, state)
                        Text(AtmosphereCardState.opacityNote)
                            .font(.system(size: 11))
                            .foregroundColor(style.text.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                        seedRow(state)
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
    private func seedRow(_ state: AtmosphereCardState) -> some View {
        if let seed = state.seed {
            AtmosphereSeedRow(controller: controller, row: seed, style: style)
                .id(AtmosphereCardIDs.seedRow)
            Text(AtmosphereCardState.seedNote)
                .font(.system(size: 11))
                .foregroundColor(style.text.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
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
        // The iPhone sheet, the side panel and the iPad float keep the scene's
        // size while a field has the keyboard (#623, #725); the sheet and the
        // card's own rows (LightsCardFocusScroll) scroll the focused row
        // into view above it.
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

/// One air row for the dust pattern's whole-number seed: label and typed field
/// (no slider).
struct AtmosphereSeedRow: View {
    let controller: LightsController
    let row: AtmosphereCardState.SeedRow
    let style: LightsBarStyle

    @State private var editor = AirSeedEditor()
    @FocusState private var focused: Bool
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    var body: some View {
        HStack(spacing: 6) {
            Text(AtmosphereCardState.seedLabel)
                .font(InspectorMetrics.font)
                .foregroundColor(style.text.opacity(0.8))
                .lineLimit(1)
                .frame(width: AtmosphereCardMetrics.labelWidth, alignment: .leading)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            TextField(AtmosphereCardState.seedLabel, text: textBinding)
                .textFieldStyle(.roundedBorder)
                .font(InspectorMetrics.valueFont)
                .multilineTextAlignment(.trailing)
                .frame(width: InspectorMetrics.fieldWidth)
                .focused($focused)
                .onSubmit { commit() }
                .lightsNumberKeyboard()
                .accessibilityLabel(AtmosphereCardIDs.seedFieldLabel)
                .accessibilityIdentifier(AtmosphereCardIDs.seedField)
        }
        .frame(minHeight: touchMinimum)
        .onAppear { editor.show(row.value) }
        .onChange(of: row.value) { editor.show(row.value) }
        .onChange(of: focused) { _, now in
            if now { editor.begin() } else { commit() }
        }
        .preference(key: LightsFieldFocusKey.self, value: focused)
        .preference(key: LightsSheetScrollTargetKey.self, value: focused ? AtmosphereCardIDs.seedRow : nil)
    }

    private var textBinding: Binding<String> {
        Binding(get: { editor.text }, set: { new in
            guard new != editor.text else { return }
            if !editor.isEditing { editor.begin() }
            editor.type(new)
        })
    }

    private func commit() {
        if let value = editor.commit() {
            controller.setAirSeed(value)
        }
        editor.show(controller.airSeed)
    }
}

// MARK: - The macOS Atmosphere popover

/// The Atmosphere popover off the Lights bar's button on macOS and the iPad
/// float (#889): the card's header (title and On/Off switch) over its hint
/// and rows, at the inspector's width. The rows scroll in a short window. A
/// popover, not a menu: a menu cannot hold the sliders and typed fields.
/// `onFieldFocus` reports a field's keyboard to the owner, which keeps the
/// iPad's viewport size meanwhile (#725): the popover is outside the float,
/// so the float's focus report never sees its fields.
struct LightsAtmospherePopover: View {
    let controller: LightsController
    var style: LightsBarStyle
    var onFieldFocus: (Bool) -> Void = { _ in }
    /// Scatter's row starts shown (the snapshot tests).
    var showsScatter = false
    @State private var fieldFocused = false
    /// The rows' measured height (the popover is as tall as its content, up
    /// to `maxRowsHeight`, and follows the Scatter disclosure; less when it
    /// has less room, the rows then scroll).
    @State private var rowsHeight = AtmosphereCardMetrics.estimatedRowsHeight

    static let maxRowsHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LightsAtmosphereCard(controller: controller, style: style, presentation: .header)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(style.text.opacity(0.12)).frame(height: 0.5)
            // The focused row scrolls back into view when the keyboard
            // shrinks the popover (iPad, #725).
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LightsAtmosphereCard(controller: controller, style: style, presentation: .rows,
                                         showsScatter: showsScatter)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: AtmosphereContentHeightKey.self, value: g.size.height)
                        })
                }
                .scrollBounceBehavior(.basedOnSize)
                .modifier(LightsCardFocusScroll<LightsSheetScrollTargetKey>(proxy: proxy))
            }
            // Ideally the rows' own height (capped), but free to shrink and
            // scroll when the popover has less room (the iPad keyboard, a
            // short Mac window), so no row is clipped out of reach.
            .frame(minHeight: 0, idealHeight: min(rowsHeight, Self.maxRowsHeight),
                   maxHeight: min(rowsHeight, Self.maxRowsHeight))
            .onPreferenceChange(AtmosphereContentHeightKey.self) { height in
                if height > 0, abs(height - rowsHeight) > 0.5 { rowsHeight = height }
            }
        }
        .frame(width: LightsInspector.width)
        .background(style.background)
        .onPreferenceChange(LightsFieldFocusKey.self) { focused in
            guard focused != fieldFocused else { return }
            fieldFocused = focused
            onFieldFocus(focused)
        }
        // Closed with a field still focused: never leave the keyboard rule on.
        .onDisappear {
            if fieldFocused {
                fieldFocused = false
                onFieldFocus(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AtmosphereCardIDs.popover)
    }
}

// MARK: - The bar's Atmosphere entry

/// The Atmosphere entry on the Lights bar (a 44 pt glyph target on a phone;
/// the overflow menu carries the same entry in phone portrait, #795): the fog
/// glyph, filled in the accent while the air is on, with a small badge while
/// a hint applies. On a phone `action` expands the sheet and scrolls to the
/// Atmosphere section (LightsSheet, via ContentView's reveal request); on
/// macOS and the iPad float it opens the Atmosphere popover (#889). Draws nothing unless Lights
/// mode is active.
struct LightsSheetAtmosphereButton: View {
    @ObservedObject var controller: LightsController
    @ObservedObject var facing: LightsFacingState
    var style: LightsBarStyle
    var identifier: String
    var action: () -> Void

    init(controller: LightsController, style: LightsBarStyle,
         identifier: String = AtmosphereCardIDs.sheetButton, action: @escaping () -> Void) {
        self.controller = controller
        _facing = ObservedObject(wrappedValue: controller.facing)
        self.style = style
        self.identifier = identifier
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
            .accessibilityIdentifier(identifier)
        }
    }
}
