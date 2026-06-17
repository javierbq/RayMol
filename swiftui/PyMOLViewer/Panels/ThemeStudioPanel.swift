// ThemeStudioPanel.swift — RayMol Theme studio, embedded inline (NOT a modal).
// Replaces the right column (macOS / iPad-landscape) or the bottom panel
// (iPhone / iPad-portrait) while open. The 3D viewport stays live, showing a
// bundled example molecule (cartoon + sidechain sticks) themed by the current
// edit, so the user sees the impact directly. Editing any control applies the
// working theme live (chrome + viewport + example). Closing restores the prior
// scene (handled by ContentView via beginThemePreview/endThemePreview).

import SwiftUI

struct ThemeStudioPanel: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var engine: PyMOLEngine

    /// Close the studio (ContentView sets showThemeStudio = false).
    var onClose: () -> Void = {}

    @State private var working: Theme = ThemeManager.shared.active
    // macOS has a full-height side column, so open Customize by default (fills
    // the space). iOS/iPad use a shorter bottom panel — keep it collapsed.
    #if os(macOS)
    @State private var showCustomize = true
    #else
    @State private var showCustomize = false
    #endif
    @State private var saveName = ""
    @State private var showSavePrompt = false

    // Panel chrome colors from the active theme (so the panel itself is an
    // example of the look — PanelTheme is file-private to ObjectPanel).
    private var panelBg: Color { themeManager.active.panelBackground.color }
    private var panelText: Color { themeManager.active.panelText.color }
    private var panelDim: Color { themeManager.active.panelText.color.opacity(0.7) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Presets rendered OUTSIDE the Form (a LazyVGrid inside a macOS Form
            // section mis-sized its cells, esp. when the Customize disclosure
            // collapsed) so we control the layout deterministically.
            presetsBlock
            Divider()
            // Customize editor + Save in a Form (auto control/label alignment).
            Form {
                Section {
                    DisclosureGroup("Customize", isExpanded: $showCustomize) { editor }
                }
                Section {
                    Button { saveName = ""; showSavePrompt = true } label: {
                        Label("Save as Preset…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            #endif
        }
        .background(panelBg)
        .onAppear { working = themeManager.active }
        .alert("Name your theme", isPresented: $showSavePrompt) {
            TextField("Theme name", text: $saveName)
            Button("Save") {
                var t = working
                t.name = saveName.isEmpty ? "Custom" : saveName
                t.builtIn = false
                t.id = UUID()
                themeManager.saveCustom(t, engine: engine)
                engine.refreshThemePreview()
                working = themeManager.active
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Header (themed)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.lefthalf.filled")
                .foregroundColor(themeManager.active.accent.color)
            Text("Theme Studio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(panelText)
            Spacer()
            Button { saveName = ""; showSavePrompt = true } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .foregroundColor(themeManager.active.accent.color)
            .help("Save as preset")
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(panelDim)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(panelBg)
    }

    /// Apply the working theme everywhere (chrome + viewport + example) live.
    private func live() {
        themeManager.select(working, engine: engine)
        engine.refreshThemePreview()
    }

    // MARK: - Galleries

    // Presets + custom themes, rendered in the panel's own VStack (not a Form).
    private var presetsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(panelDim)
            presetGallery
            if !themeManager.custom.isEmpty {
                Text("My Themes")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(panelDim)
                    .padding(.top, 6)
                customGallery
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // FIXED-width cells (min == max) so the 64pt swatches don't float inside
    // grow-to-fill adaptive cells; leftover width trails (left-aligned), and the
    // row wraps consistently at any panel width.
    private var swatchColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 72, maximum: 72), spacing: 12, alignment: .top)]
    }

    private var presetGallery: some View {
        LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 12) {
            ForEach(themeManager.presets) { t in swatch(t) }
        }
    }

    private var customGallery: some View {
        LazyVGrid(columns: swatchColumns, alignment: .leading, spacing: 12) {
            ForEach(themeManager.custom) { t in
                swatch(t).contextMenu {
                    Button("Delete", role: .destructive) { themeManager.deleteCustom(t) }
                }
            }
        }
    }

    private func swatch(_ t: Theme) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(t.viewportBackground.color)
                HStack(spacing: 3) {
                    Circle().fill(t.accent.color).frame(width: 12, height: 12)
                    Circle().fill(t.selectionName.color).frame(width: 12, height: 12)
                    Circle().fill(t.terminalText.color).frame(width: 12, height: 12)
                }
            }
            .frame(width: 64, height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(themeManager.active.id == t.id ? Color.accentColor : .clear, lineWidth: 2)
            )
            Text(t.name).font(.caption2)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            working = t
            themeManager.select(t, engine: engine)
            engine.refreshThemePreview()
        }
    }

    // MARK: - Custom editor

    // Non-carbon elements exposed for editing (carbon follows chain color).
    private let elementOrder = ["N", "O", "S", "P", "H", "F", "CL", "BR", "I"]

    @ViewBuilder private var editor: some View {
        // Appearance lives here now (folded out of the top to stop fighting the
        // preset selection — the preset sets it, and you override it here).
        Picker("Appearance", selection: Binding(
            get: { working.appearance },
            set: { working.appearance = $0; live() })) {
            ForEach(Appearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)

        groupLabel("Chrome")
        ColorPicker("Accent", selection: bind(\.accent))
        ColorPicker("Chat bubble", selection: bind(\.bubble))
        ColorPicker("Selection name", selection: bind(\.selectionName))
        ColorPicker("Tab tint", selection: bind(\.tabTint))
        ColorPicker("Viewport background", selection: bind(\.viewportBackground))
        ColorPicker("Terminal text", selection: bind(\.terminalText))
        Picker("Terminal font", selection: Binding(
            get: { working.terminalFont.family },
            set: { working.terminalFont.family = $0; live() })) {
            ForEach(FontSpec.Family.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Stepper("Font size \(Int(working.terminalFont.size))", value: Binding(
            get: { working.terminalFont.size },
            set: { working.terminalFont.size = $0; live() }), in: 8...20)

        groupLabel("Molecular")
        Picker("Default style", selection: Binding(
            get: { working.defaultStyle },
            set: { working.defaultStyle = $0; live() })) {
            ForEach(RepStyle.allCases) { Text($0.label).tag($0) }
        }
        chainColorsEditor
        elementColorsEditor

        groupLabel("Render")
        Toggle("Outline", isOn: boolBind(\.outline))
        Toggle("Cartoon flat sheets", isOn: boolBind(\.flatSheets))
        Toggle("Fancy helices", isOn: boolBind(\.fancyHelices))
        Toggle("Shadows", isOn: boolBind(\.shadows))
        Toggle("Ray tracing (AO + shadows)", isOn: boolBind(\.rayTrace))
    }

    private func groupLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.caption2).fontWeight(.semibold)
            .foregroundColor(panelDim)
            .padding(.top, 4)
    }

    // Chain color cycle: a row of editable wells with add/remove.
    private var chainColorsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Chain colors").font(.caption).foregroundColor(panelDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(working.chainCycle.indices, id: \.self) { i in
                        VStack(spacing: 2) {
                            ColorPicker("", selection: chainBind(i)).labelsHidden()
                            if working.chainCycle.count > 1 {
                                Button { removeChain(i) } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Button { addChain() } label: {
                        Image(systemName: "plus.circle").font(.system(size: 18))
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
    }

    // Non-carbon element colors: labeled wells.
    private var elementColorsEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Element colors (non-carbon)").font(.caption).foregroundColor(panelDim)
            ForEach(elementOrder, id: \.self) { el in
                ColorPicker(elementLabel(el), selection: elementBind(el))
            }
        }
    }

    private func elementLabel(_ el: String) -> String {
        switch el {
        case "CL": return "Chlorine (Cl)"
        case "BR": return "Bromine (Br)"
        default:
            let names = ["N": "Nitrogen", "O": "Oxygen", "S": "Sulfur", "P": "Phosphorus",
                         "H": "Hydrogen", "F": "Fluorine", "I": "Iodine"]
            return "\(names[el] ?? el) (\(el.capitalized))"
        }
    }

    // MARK: - Bindings

    private func bind(_ kp: WritableKeyPath<Theme, RGBA>) -> Binding<Color> {
        Binding(get: { working[keyPath: kp].color },
                set: { working[keyPath: kp] = $0.rgba; live() })
    }
    private func boolBind(_ kp: WritableKeyPath<Theme, Bool>) -> Binding<Bool> {
        Binding(get: { working[keyPath: kp] },
                set: { working[keyPath: kp] = $0; live() })
    }
    private func chainBind(_ i: Int) -> Binding<Color> {
        Binding(get: { working.chainCycle.indices.contains(i) ? working.chainCycle[i].color : .gray },
                set: { if working.chainCycle.indices.contains(i) { working.chainCycle[i] = $0.rgba; live() } })
    }
    private func addChain() { working.chainCycle.append(RGBA(0.5, 0.5, 0.5)); live() }
    private func removeChain(_ i: Int) {
        guard working.chainCycle.count > 1, working.chainCycle.indices.contains(i) else { return }
        working.chainCycle.remove(at: i); live()
    }
    private func elementBind(_ el: String) -> Binding<Color> {
        Binding(get: { (working.elementColors[el] ?? RGBA(0.5, 0.5, 0.5)).color },
                set: { working.elementColors[el] = $0.rgba; live() })
    }
}
