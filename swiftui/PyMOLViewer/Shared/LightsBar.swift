// LightsBar.swift — the Lights mode bar (#619, spec §9).
//
// The bar shows the rig as a row of chips, one per light, each with the
// light's dot (the colour the light casts, #798, which the orbit view #621 and
// the gizmo #622 use for it too; hollow while the light is behind the molecule, the gizmo's
// front/behind rule), and the rig-wide actions: add, remove, a preset, Re-centre,
// on/off, Revert and Done. In phone portrait (#885, `onEditLight`) a compact
// light menu replaces the chips, with the lights, add/remove, Shadow, Pin,
// Colour, Lights On and "Edit light…" (which opens the full bottom-sheet
// editor). On a phone the bar also carries the scene's Atmosphere entry (#795):
// a button on the wide bar, an item in the overflow menu on the compact one.
// It floats at the top of the viewport on macOS and docks at the bottom of the
// top stack on iOS (ContentView places it).
//
// Everything it shows comes from LightsController, and every press goes to
// one of the controller's actions, which reach the rig through the engine's
// seams. So this file names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py checks that), needs neither the
// engine nor the theme manager, and the unit tests can draw it with a
// controller on fake seams. Both platforms share it: no `#if os`.

import SwiftUI

// MARK: - Marker colours

extension LightMarkerColour {
    /// The marker's fill: the colour the light casts (#798), opaque sRGB.
    var fillColor: Color { Color(.sRGB, red: fill.x, green: fill.y, blue: fill.z, opacity: 1) }

    /// The marker's thin outline: black or white, whichever contrasts with the fill.
    var outlineColor: Color { Color(.sRGB, red: outline.x, green: outline.y, blue: outline.z, opacity: 1) }
}

/// A light's dot (the chip's, the orbit card's and the inspector's header):
/// the light's own colour with a hairline outline, so a white light still
/// reads on a light or dark bar. `hollow` is the chip's "behind the
/// molecule" ring.
struct LightMarkerDot: View {
    var marker: LightMarkerColour
    var size: CGFloat
    var hollow = false

    var body: some View {
        ZStack {
            if hollow {
                Circle().strokeBorder(marker.fillColor, lineWidth: 1.5)
            } else {
                Circle().fill(marker.fillColor)
            }
        }
        .overlay(Circle().strokeBorder(marker.outlineColor.opacity(0.7), lineWidth: 0.75))
        .frame(width: size, height: size)
    }
}

// MARK: - Style

/// The bar's colours. ContentView builds it from the active theme, so the
/// bar matches the other mode bars (moveOverlay, measureOverlay).
struct LightsBarStyle {
    var accent: Color
    var text: Color
    var background: Color
}

// MARK: - What the bar shows

/// Everything the bar shows, worked out from the controller in one place, so
/// the unit tests can check the labels and the enablement without drawing.
struct LightsBarState: Equatable {
    struct Chip: Equatable, Identifiable {
        var name: String
        var index: Int
        var slot: Int
        /// What the dot is drawn in: the light's own colour (#798).
        var marker = LightMarkerColour.neutral
        var isSelected: Bool
        /// The light is behind the molecule (`LightsController.isBehind`)
        /// when the state was made. The chip itself observes
        /// `controller.facing`, so it follows a crossing without the bar.
        var isBehind = false
        var id: String { name }
        var accessibilityLabel: String { LightsBarState.chipAccessibilityLabel(name) }
        var accessibilityValue: String { LightsBarState.chipAccessibilityValue(behind: isBehind) }
        var accessibilityIdentifier: String { "lights.chip.\(name)" }
    }

    /// The only status text the bar ever shows: the rig has no lights.
    static let noLightsText = "No lights · add one or pick a preset"
    /// The same status where the chip area is too narrow for `noLightsText`
    /// (iPhone portrait), where Presets sits in the overflow menu.
    static let noLightsShortText = "No lights"
    /// The portrait light menu (#885), shown in place of the chips.
    static let lightMenuIdentifier = "lights.menu"
    static let lightMenuLabel = "Light"
    static let lightMenuHint = "Pick a light, change its main settings, or open the full editor"
    static let noLightTitle = "No light"
    static let editLightTitle = "Edit light…"
    static let editLightIdentifier = "lights.menu.edit"

    static func lightMenuTitle(selected: String?) -> String {
        selected ?? noLightTitle
    }

    /// VoiceOver's value for the light menu: the selected light and where it
    /// is (the chips' front/behind value, #622), or `No light`.
    static func lightMenuAccessibilityValue(selected: String?, behind: Bool) -> String {
        guard let selected else { return noLightTitle }
        return "\(selected), \(chipAccessibilityValue(behind: behind))"
    }

    static func lightMenuItemIdentifier(_ name: String) -> String {
        "lights.menu.light.\(name)"
    }

    /// The menu's Shadow toggle cannot turn the selected light's shadow on:
    /// it has none and `maxShadowed` other lights already cast one. The menu
    /// then disables it under the inspector's cap notice, since the
    /// inspector (which shows the notice after a refused press) is not on
    /// screen while the portrait editor is closed.
    static func shadowCapReached(isShadowed: Bool, shadowedCount: Int) -> Bool {
        !isShadowed && shadowedCount >= LightsController.maxShadowed
    }

    /// VoiceOver's name for a chip.
    static func chipAccessibilityLabel(_ name: String) -> String {
        "\(name) light"
    }

    /// VoiceOver's value for a chip: where the light is (#622; the hollow
    /// dot shows the same).
    static func chipAccessibilityValue(behind: Bool) -> String {
        behind ? "behind the molecule" : "in front of the molecule"
    }

    var chips: [Chip]
    /// The status text in the chip area (nil when there are chips).
    var status: String?
    var isOn: Bool
    var canAdd: Bool
    var canRemove: Bool
    var canPickPreset: Bool
    var canRecentre: Bool
    var canToggle: Bool
    var canRevert: Bool
    var editCount: Int
    var revertNeedsConfirmation: Bool
    var addHelp: String
    var removeHelp: String
    var powerLabel: String
    var powerHelp: String
    var presets: [LightPreset]
    /// The scene's haze or dust draws (#795): lights the Atmosphere entry's
    /// glyph, and its checkmark in the overflow menu.
    var atmosphereIsOn: Bool

    /// Whether the bar carries the Atmosphere entry point (#795). Atmosphere
    /// is scene-wide, so on a phone it sits here with the other rig-wide
    /// controls and not in the selected light's header. macOS and the iPad
    /// float show it as a card of their own, so the bar carries nothing there.
    static func showsAtmosphereEntry(placement: LightsToolsPlacement) -> Bool {
        switch placement {
        case .bottomSheet, .sidePanel: return true
        case .column, .floating: return false
        }
    }

    /// The overflow menu's item: the title carries the state a checkmark
    /// would (a Button in a menu has no mark of its own).
    static func atmosphereMenuTitle(isOn: Bool) -> String {
        isOn ? "Atmosphere: On" : "Atmosphere: Off"
    }

    /// The menu item's glyph: the filled fog cloud while the air is on.
    static func atmosphereMenuImage(isOn: Bool) -> String {
        isOn ? "cloud.fog.fill" : AtmosphereCardState.systemImage
    }

    @MainActor
    init(_ controller: LightsController) {
        let lights = controller.rig?.lights ?? []
        let selected = controller.selectedIndex
        chips = lights.enumerated().map { index, light in
            Chip(name: light.name, index: index,
                 slot: controller.identitySlot(for: light.name),
                 marker: LightMarkerColour(light),
                 isSelected: index == selected,
                 isBehind: controller.isBehind(light.name))
        }
        status = lights.isEmpty ? Self.noLightsText : nil
        isOn = controller.hasLights && controller.isOn
        canAdd = controller.canAdd
        canRemove = controller.canRemove
        canPickPreset = controller.isActive && !controller.isBusy && !controller.presets.isEmpty
        canRecentre = controller.canRecentre
        canToggle = controller.canToggle
        canRevert = controller.canRevert
        editCount = controller.editCount
        revertNeedsConfirmation = controller.revertNeedsConfirmation
        presets = controller.presets
        atmosphereIsOn = controller.airIsOn
        addHelp = lights.count >= LightsController.maxLights
            ? "A rig holds at most \(LightsController.maxLights) lights"
            : "Add a light"
        if let name = controller.selectedLight?.name {
            removeHelp = "Remove \(name)"
        } else {
            removeHelp = "Select a light to remove it"
        }
        powerLabel = isOn ? "Lights on" : "Lights off"
        if !controller.hasLights {
            powerHelp = "Lights off: add a light or pick a preset first"
        } else {
            powerHelp = isOn ? "Lights on: turn the rig off" : "Lights off: turn the rig on"
        }
    }
}

// MARK: - The bar

struct LightsBar: View {
    @ObservedObject var controller: LightsController
    var style: LightsBarStyle
    var onDone: () -> Void
    /// Reveals the Atmosphere section of the phone sheet or side panel
    /// (#795); nil where the bar carries no such entry (macOS, iPad). The
    /// scene's haze and dust belong to the rig, so the entry is here with the
    /// other rig-wide controls and not in the selected light's header.
    var onAtmosphere: (() -> Void)?
    /// Opens the portrait full light editor (#885); when non-nil the bar
    /// shows the compact light menu in place of the chips.
    var onEditLight: (() -> Void)?
    /// 44 on iOS (every control a 44 pt target, #623), 0 on macOS.
    @Environment(\.lightsTouchMinimum) private var touchMinimum

    @State private var confirmRevert = false

    static let revertConfirmTitle = "Revert your light edits?"
    static func revertConfirmLabel(_ count: Int) -> String { "Revert \(count) edits" }

    static let recentreHelp = "Re-centre: capture the centre and 1× size from the molecules"
    static let revertHelp = "Revert to the lights you had when you opened Lights mode"
    static let presetsHelp = "Replace the lights with a preset"
    static let doneHelp = "Keep these lights and leave Lights mode (Esc)"

    init(controller: LightsController, style: LightsBarStyle, onAtmosphere: (() -> Void)? = nil,
         onEditLight: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        self.controller = controller
        self.style = style
        self.onAtmosphere = onAtmosphere
        self.onEditLight = onEditLight
        self.onDone = onDone
    }

    var body: some View {
        let state = LightsBarState(controller)
        ViewThatFits(in: .horizontal) {
            wide(state)
            compact(state)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(style.background)
        .tint(style.accent)
        .confirmationDialog(Self.revertConfirmTitle, isPresented: $confirmRevert, titleVisibility: .visible) {
            Button(Self.revertConfirmLabel(controller.editCount), role: .destructive) { controller.revert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This puts back the lights you had when you opened Lights mode.")
        }
    }

    // Everything on one row: icon and title, chips, the actions, Done.
    private func wide(_ state: LightsBarState) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(style.accent)
                Text("Lights")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(style.text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            chipArea(state)
            Spacer(minLength: 8)
            addButton(state)
            removeButton(state)
            presetsMenu(state)
            recentreButton(state)
            atmosphereButton
            powerButton(state)
            revertButton(state, showsRevertWord: true)
            doneButton
        }
    }

    // iPhone portrait: no title; the light menu replaces the chips (#885), and
    // Presets, Re-centre, Atmosphere (phones only) and On/Off sit in one
    // overflow menu. +, −, Revert and Done stay on the bar. With 44 pt targets
    // (iOS) the frames carry the gaps, so the spacing drops to 2.
    private func compact(_ state: LightsBarState) -> some View {
        HStack(spacing: touchMinimum > 0 ? 2 : 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(style.accent)
                .accessibilityLabel("Lights")
            chipArea(state)
            Spacer(minLength: 4)
            addButton(state)
            removeButton(state)
            overflowMenu(state)
            revertButton(state)
            doneButton
        }
    }

    // MARK: chips

    @ViewBuilder
    private func chipArea(_ state: LightsBarState) -> some View {
        if let onEditLight {
            lightMenu(state, onEdit: onEditLight)
        } else if let status = state.status {
            ViewThatFits(in: .horizontal) {
                statusText(status)
                statusText(LightsBarState.noLightsShortText)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status)
            .accessibilityIdentifier("lights.status")
        } else {
            // The selected chip scrolls into view (a light added at the end of a
            // long rig, or picked from the gizmo) so + and - never act on a light
            // the user cannot see.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(state.chips) { chip in
                            LightChipButton(chip: chip, facing: controller.facing,
                                            rigOn: state.isOn, style: style) {
                                controller.select(index: chip.index)
                            }
                            .id(chip.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .onAppear { scrollToSelected(state, proxy) }
                .onChange(of: state.chips.first(where: \.isSelected)?.id) {
                    scrollToSelected(state, proxy)
                }
            }
        }
    }

    private func lightMenu(_ state: LightsBarState, onEdit: @escaping () -> Void) -> some View {
        let title = LightsBarState.lightMenuTitle(selected: controller.selectedLight?.name)
        return Menu {
            ForEach(state.chips) { chip in
                Button { controller.select(index: chip.index) } label: {
                    if chip.isSelected {
                        Label(chip.name, systemImage: "checkmark")
                    } else {
                        Text(chip.name)
                    }
                }
                .accessibilityIdentifier(LightsBarState.lightMenuItemIdentifier(chip.name))
            }
            Divider()
            Button { controller.add() } label: {
                Label("Add Light", systemImage: "plus")
            }
            .disabled(!state.canAdd)
            Button(role: .destructive) { controller.removeSelected() } label: {
                Label(state.removeHelp, systemImage: "minus")
            }
            .disabled(!state.canRemove)
            if let inspector = LightsInspectorState(controller) {
                let shadowed = controller.rig?.lights.filter(\.shadow).count ?? 0
                let capReached = LightsBarState.shadowCapReached(isShadowed: inspector.isShadowed,
                                                                 shadowedCount: shadowed)
                Section {
                    Toggle(isOn: Binding(get: { inspector.isShadowed },
                                         set: { on in
                                             // The core keeps the cap: a refusal the
                                             // count missed opens the editor on its
                                             // notice (ContentView speaks it, once).
                                             if controller.setShadow(on) == .refused {
                                                 onEdit()
                                             }
                                         })) {
                        Label(LightsInspectorState.shadowLabel, systemImage: "shadow")
                    }
                    .disabled(!inspector.canEdit || capReached)
                    Toggle(isOn: Binding(get: { inspector.isPinned },
                                         set: { controller.setPinned($0) })) {
                        Label(LightsInspectorState.pinLabel, systemImage: "pin")
                    }
                    .disabled(!inspector.canEdit)
                    Menu {
                        ForEach(inspector.swatches) { swatch in
                            Button { controller.setColour(swatch.rgb) } label: {
                                if swatch.isSelected {
                                    Label(swatch.name, systemImage: "checkmark")
                                } else {
                                    Text(swatch.name)
                                }
                            }
                        }
                    } label: {
                        Label("Colour", systemImage: "paintpalette")
                    }
                    .disabled(!inspector.canEdit)
                } header: {
                    if capReached {
                        Text(LightsInspectorState.shadowCapNotice)
                    }
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { state.isOn },
                                 set: { controller.setEnabled($0) })) {
                Label("Lights On", systemImage: "power")
            }
            .disabled(!state.canToggle)
            Divider()
            Button { onEdit() } label: {
                Label(LightsBarState.editLightTitle, systemImage: "slider.horizontal.3")
            }
            .disabled(controller.selectedLight == nil)
            .accessibilityIdentifier(LightsBarState.editLightIdentifier)
        } label: {
            HStack(spacing: 4) {
                if let chip = state.chips.first(where: \.isSelected) {
                    LightMenuMarker(chip: chip, facing: controller.facing, rigOn: state.isOn)
                }
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .foregroundColor(style.text)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().stroke(style.accent, lineWidth: 1.5))
            .contentShape(Capsule())
            .lightsTouchTarget(width: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(LightsBarState.lightMenuHint)
        .accessibilityLabel(LightsBarState.lightMenuLabel)
        .modifier(LightMenuAccessibilityValue(selected: controller.selectedLight?.name,
                                              facing: controller.facing))
        .accessibilityHint(LightsBarState.lightMenuHint)
        .accessibilityIdentifier(LightsBarState.lightMenuIdentifier)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(style.text.opacity(0.7))
            .lineLimit(1)
    }

    private func scrollToSelected(_ state: LightsBarState, _ proxy: ScrollViewProxy) {
        guard let id = state.chips.first(where: \.isSelected)?.id else { return }
        proxy.scrollTo(id)
    }

    // MARK: actions

    private func icon(_ name: String, on: Bool = false) -> some View {
        Image(systemName: name)
            .foregroundColor(on ? style.accent : style.text)
    }

    private func addButton(_ state: LightsBarState) -> some View {
        Button { controller.add() } label: { icon("plus").lightsTouchTarget() }
            .buttonStyle(.plain)
            .disabled(!state.canAdd)
            .help(state.addHelp)
            .accessibilityLabel("Add light")
            .accessibilityIdentifier("lights.add")
    }

    private func removeButton(_ state: LightsBarState) -> some View {
        Button { controller.removeSelected() } label: { icon("minus").lightsTouchTarget() }
            .buttonStyle(.plain)
            .disabled(!state.canRemove)
            .help(state.removeHelp)
            .accessibilityLabel(state.removeHelp)
            .accessibilityIdentifier("lights.remove")
    }

    @ViewBuilder
    private func presetItems(_ state: LightsBarState) -> some View {
        ForEach(state.presets) { preset in
            Button { controller.applyPreset(preset.name) } label: {
                // Title and second line where the platform shows one.
                Text(preset.displayName)
                Text(preset.description)
            }
            .help(preset.description)
        }
    }

    private func presetsMenu(_ state: LightsBarState) -> some View {
        Menu {
            presetItems(state)
        } label: {
            HStack(spacing: 3) {
                Text("Presets").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(style.text)
            .lightsTouchTarget()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!state.canPickPreset)
        .help(Self.presetsHelp)
        .accessibilityLabel("Presets")
        .accessibilityIdentifier("lights.presets")
    }

    private func recentreButton(_ state: LightsBarState) -> some View {
        Button { controller.recentre() } label: { icon("scope").lightsTouchTarget() }
            .buttonStyle(.plain)
            .disabled(!state.canRecentre)
            .help(Self.recentreHelp)
            .accessibilityLabel("Re-centre")
            .accessibilityIdentifier("lights.recentre")
    }

    /// The phone's Atmosphere entry on the wide bar (iPhone landscape): the
    /// fog glyph, filled while the air is on. Draws nothing without
    /// `onAtmosphere`, or outside Lights mode.
    @ViewBuilder
    private var atmosphereButton: some View {
        if let onAtmosphere {
            LightsSheetAtmosphereButton(controller: controller, style: style, action: onAtmosphere)
        }
    }

    private func powerButton(_ state: LightsBarState) -> some View {
        Button { controller.setEnabled(!state.isOn) } label: { icon("power", on: state.isOn).lightsTouchTarget() }
            .buttonStyle(.plain)
            .disabled(!state.canToggle)
            .help(state.powerHelp)
            .accessibilityLabel(state.powerLabel)
            .accessibilityValue(state.isOn ? "On" : "Off")
            .accessibilityIdentifier("lights.power")
    }

    private func overflowMenu(_ state: LightsBarState) -> some View {
        Menu {
            Menu("Presets") { presetItems(state) }
                .disabled(!state.canPickPreset)
            Button { controller.recentre() } label: {
                Label("Re-centre", systemImage: "scope")
            }
            .disabled(!state.canRecentre)
            .help(Self.recentreHelp)
            if let onAtmosphere {
                Button(action: onAtmosphere) {
                    Label(LightsBarState.atmosphereMenuTitle(isOn: state.atmosphereIsOn),
                          systemImage: LightsBarState.atmosphereMenuImage(isOn: state.atmosphereIsOn))
                }
                .help(AtmosphereCardIDs.sheetButtonHint)
                .accessibilityLabel(AtmosphereCardIDs.sheetButtonLabel)
                .accessibilityValue(state.atmosphereIsOn ? "On" : "Off")
                .accessibilityHint(AtmosphereCardIDs.sheetButtonHint)
                .accessibilityIdentifier(AtmosphereCardIDs.menuItem)
            }
            Button { controller.setEnabled(!state.isOn) } label: {
                Label(state.isOn ? "Turn Lights Off" : "Turn Lights On", systemImage: "power")
            }
            .disabled(!state.canToggle)
            .help(state.powerHelp)
        } label: {
            icon("ellipsis.circle").lightsTouchTarget()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(onAtmosphere == nil ? "Presets, Re-centre and On/Off" : "Presets, Re-centre, Atmosphere and On/Off")
        .accessibilityLabel("More light actions")
        .accessibilityValue(state.powerLabel)
        .accessibilityIdentifier("lights.more")
    }

    private func revertButton(_ state: LightsBarState, showsRevertWord: Bool = false) -> some View {
        Button {
            if state.revertNeedsConfirmation { confirmRevert = true } else { controller.revert() }
        } label: {
            if showsRevertWord {
                // The word, not a bare undo glyph: Revert drops every edit made
                // since the mode opened, not one step (with a confirmation when
                // more than one would be lost, #651).
                HStack(spacing: 3) {
                    icon("arrow.uturn.backward")
                    Text("Revert").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(style.text)
                .lightsTouchTarget()
            } else {
                icon("arrow.uturn.backward").lightsTouchTarget()
            }
        }
            .buttonStyle(.plain)
            .disabled(!state.canRevert)
            .help(Self.revertHelp)
            .accessibilityLabel("Revert lights")
            .accessibilityIdentifier("lights.revert")
    }

    @ViewBuilder
    private var doneButton: some View {
        if touchMinimum > 0 {
            // A bordered button draws its fill around its label, so a 44 pt
            // label would draw a 44 pt pill. Instead the pill is drawn small
            // inside a plain button whose label is the 44 pt target.
            Button { onDone() } label: {
                Text("Done")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(style.accent))
                    .lightsTouchTarget()
            }
            .buttonStyle(.plain)
            .help(Self.doneHelp)
            .accessibilityIdentifier("lights.done")
        } else {
            Button("Done") { onDone() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(Self.doneHelp)
                .accessibilityIdentifier("lights.done")
        }
    }
}

// MARK: - The light menu's dot

/// The portrait light menu's dot (#885): the selected light's colour,
/// hollow while it is behind the molecule. It observes `controller.facing`,
/// as the chips do, so it follows a crossing under a turning camera.
struct LightMenuMarker: View {
    var chip: LightsBarState.Chip
    @ObservedObject var facing: LightsFacingState
    var rigOn: Bool

    var body: some View {
        LightMarkerDot(marker: chip.marker, size: 8, hollow: facing.isBehind(chip.name))
            .opacity(rigOn ? 1 : 0.45)
    }
}

/// The light menu's VoiceOver value (LightsBarState.lightMenuAccessibilityValue).
/// It observes `controller.facing`, so the spoken front/behind state follows a
/// crossing under a turning camera, as the dot does.
struct LightMenuAccessibilityValue: ViewModifier {
    var selected: String?
    @ObservedObject var facing: LightsFacingState

    func body(content: Content) -> some View {
        let behind = selected.map { facing.isBehind($0) } ?? false
        return content.accessibilityValue(LightsBarState.lightMenuAccessibilityValue(selected: selected,
                                                                                     behind: behind))
    }
}

// MARK: - A chip

/// One light's chip: its identity dot and name. It observes
/// `controller.facing`, so when a light crosses behind the molecule (a pinned
/// light under a turning camera, a gizmo drag) only the chips re-render: the
/// dot turns hollow, and VoiceOver reads "behind the molecule".
struct LightChipButton: View {
    var chip: LightsBarState.Chip
    @ObservedObject var facing: LightsFacingState
    var rigOn: Bool
    var style: LightsBarStyle
    var onSelect: () -> Void

    init(chip: LightsBarState.Chip, facing: LightsFacingState, rigOn: Bool,
         style: LightsBarStyle, onSelect: @escaping () -> Void) {
        self.chip = chip
        self.facing = facing
        self.rigOn = rigOn
        self.style = style
        self.onSelect = onSelect
    }

    var body: some View {
        let behind = facing.isBehind(chip.name)
        Button(action: onSelect) {
            HStack(spacing: 4) {
                LightMarkerDot(marker: chip.marker, size: 8, hollow: behind)
                .opacity(rigOn ? 1 : 0.45)
                Text(chip.name)
                    .font(.system(size: 12, weight: chip.isSelected ? .semibold : .regular))
                    .foregroundColor(style.text.opacity(rigOn ? 1 : 0.75))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(chip.isSelected ? style.accent.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(chip.isSelected ? style.accent : style.text.opacity(0.2),
                                      lineWidth: chip.isSelected ? 1.5 : 1))
            .contentShape(Capsule())
            // 44 pt tall on iOS; the chip keeps its width.
            .lightsTouchTarget(width: false)
        }
        .buttonStyle(.plain)
        .help("Select \(chip.name)")
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityValue(LightsBarState.chipAccessibilityValue(behind: behind))
        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
        .accessibilityIdentifier(chip.accessibilityIdentifier)
    }
}
