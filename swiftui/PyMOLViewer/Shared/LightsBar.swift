// LightsBar.swift — the Lights mode bar (#619, spec §9).
//
// The bar shows the rig as a row of chips, one per light, each with the
// light's identity dot (the colour the orbit view #621 and the gizmo #622 use
// for it too), and the rig-wide actions: add, remove, a preset, Re-centre,
// on/off, Revert and Done. It floats at the top of the viewport on macOS and
// docks at the bottom of the top stack on iOS (ContentView places it).
//
// Everything it shows comes from LightsController, and every press goes to
// one of the controller's actions, which reach the rig through the engine's
// seams. So this file names no Python, console command or bridge function
// (testing/tests/raymol/lighting_mode.py checks that), needs neither the
// engine nor the theme manager, and the unit tests can draw it with a
// controller on fake seams. Both platforms share it: no `#if os`.

import SwiftUI

// MARK: - Identity colours

extension LightPalette {
    /// The identity colour of a slot (LightPalette.assign): blue, orange,
    /// green, purple, pink, gold, in the order of the design sketches. Fixed
    /// sRGB values, so a light reads the same on every platform and theme.
    /// Out-of-range slots wrap.
    static func color(_ slot: Int) -> Color {
        let rgb = Self.rgb[((slot % count) + count) % count]
        return Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: 1)
    }

    /// sRGB of each slot, in slot order.
    static let rgb: [(Double, Double, Double)] = [
        (0.23, 0.51, 0.96),   // blue
        (0.96, 0.55, 0.15),   // orange
        (0.24, 0.73, 0.36),   // green
        (0.62, 0.38, 0.92),   // purple
        (0.93, 0.36, 0.62),   // pink
        (0.86, 0.69, 0.13),   // gold
    ]
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
        var isSelected: Bool
        var id: String { name }
        var accessibilityLabel: String { LightsBarState.chipAccessibilityLabel(name) }
        var accessibilityIdentifier: String { "lights.chip.\(name)" }
    }

    /// The only status text the bar ever shows: the rig has no lights.
    static let noLightsText = "No lights · add one or pick a preset"

    /// VoiceOver's name for a chip.
    static func chipAccessibilityLabel(_ name: String) -> String {
        "\(name) light"
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
    var addHelp: String
    var removeHelp: String
    var powerLabel: String
    var powerHelp: String
    var presets: [LightPreset]

    @MainActor
    init(_ controller: LightsController) {
        let lights = controller.rig?.lights ?? []
        let selected = controller.selectedIndex
        chips = lights.enumerated().map { index, light in
            Chip(name: light.name, index: index,
                 slot: controller.identitySlot(for: light.name),
                 isSelected: index == selected)
        }
        status = lights.isEmpty ? Self.noLightsText : nil
        isOn = controller.hasLights && controller.isOn
        canAdd = controller.canAdd
        canRemove = controller.canRemove
        canPickPreset = controller.isActive && !controller.isBusy && !controller.presets.isEmpty
        canRecentre = controller.canRecentre
        canToggle = controller.canToggle
        canRevert = controller.canRevert
        presets = controller.presets
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

    static let recentreHelp = "Re-centre: capture the centre and 1× size from the molecules"
    static let revertHelp = "Revert to the lights you had when you opened Lights mode"
    static let presetsHelp = "Replace the lights with a preset"
    static let doneHelp = "Keep these lights and leave Lights mode (Esc)"

    init(controller: LightsController, style: LightsBarStyle, onDone: @escaping () -> Void) {
        self.controller = controller
        self.style = style
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
            powerButton(state)
            revertButton(state)
            doneButton
        }
    }

    // iPhone portrait: no title; Presets, Re-centre and On/Off in one overflow
    // menu. +, −, Revert and Done stay on the bar.
    private func compact(_ state: LightsBarState) -> some View {
        HStack(spacing: 10) {
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
        if let status = state.status {
            Text(status)
                .font(.system(size: 12))
                .foregroundColor(style.text.opacity(0.55))
                .lineLimit(1)
                .accessibilityIdentifier("lights.status")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(state.chips) { chip in
                        chipButton(chip, rigOn: state.isOn)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func chipButton(_ chip: LightsBarState.Chip, rigOn: Bool) -> some View {
        Button { controller.select(index: chip.index) } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(LightPalette.color(chip.slot))
                    .frame(width: 8, height: 8)
                Text(chip.name)
                    .font(.system(size: 12, weight: chip.isSelected ? .semibold : .regular))
                    .foregroundColor(style.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(chip.isSelected ? style.accent.opacity(0.15) : Color.clear))
            .overlay(Capsule().stroke(chip.isSelected ? style.accent : style.text.opacity(0.2),
                                      lineWidth: chip.isSelected ? 1.5 : 1))
            .opacity(rigOn ? 1 : 0.55)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Select \(chip.name)")
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityAddTraits(chip.isSelected ? .isSelected : [])
        .accessibilityIdentifier(chip.accessibilityIdentifier)
    }

    // MARK: actions

    private func icon(_ name: String, on: Bool = false) -> some View {
        Image(systemName: name)
            .foregroundColor(on ? style.accent : style.text)
    }

    private func addButton(_ state: LightsBarState) -> some View {
        Button { controller.add() } label: { icon("plus") }
            .buttonStyle(.plain)
            .disabled(!state.canAdd)
            .help(state.addHelp)
            .accessibilityLabel("Add light")
            .accessibilityIdentifier("lights.add")
    }

    private func removeButton(_ state: LightsBarState) -> some View {
        Button { controller.removeSelected() } label: { icon("minus") }
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
        Button { controller.recentre() } label: { icon("scope") }
            .buttonStyle(.plain)
            .disabled(!state.canRecentre)
            .help(Self.recentreHelp)
            .accessibilityLabel("Re-centre")
            .accessibilityIdentifier("lights.recentre")
    }

    private func powerButton(_ state: LightsBarState) -> some View {
        Button { controller.setEnabled(!state.isOn) } label: { icon("power", on: state.isOn) }
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
            Button { controller.setEnabled(!state.isOn) } label: {
                Label(state.isOn ? "Turn Lights Off" : "Turn Lights On", systemImage: "power")
            }
            .disabled(!state.canToggle)
            .help(state.powerHelp)
        } label: {
            icon("ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Presets, Re-centre and On/Off")
        .accessibilityLabel("More light actions")
        .accessibilityValue(state.powerLabel)
        .accessibilityIdentifier("lights.more")
    }

    private func revertButton(_ state: LightsBarState) -> some View {
        Button { controller.revert() } label: { icon("arrow.uturn.backward") }
            .buttonStyle(.plain)
            .disabled(!state.canRevert)
            .help(Self.revertHelp)
            .accessibilityLabel("Revert lights")
            .accessibilityIdentifier("lights.revert")
    }

    private var doneButton: some View {
        Button("Done") { onDone() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(Self.doneHelp)
            .accessibilityIdentifier("lights.done")
    }
}
