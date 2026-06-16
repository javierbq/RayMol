// MousePanel.swift — Mouse mode informational display for PyMOL
// Replaces modules/pymol/appkit_mouse_panel.py with pure SwiftUI.
// Shows current mouse mode, button/modifier action grid, and selection mode.

import SwiftUI

// MARK: - Mouse mode definitions

/// Action code abbreviations matching the Python CODE dict.
private let actionCodes: [String: String] = [
    "rota": "Rota", "move": "Move", "movz": "MovZ", "clip": "Clip",
    "rotz": "RotZ", "clpn": "ClpN", "clpf": "ClpF",
    "lb":   " lb ", "mb":   " mb ", "rb":   " rb ",
    "+lb":  "+lb ", "+mb":  "+mb ", "+rb":  "+rb ",
    "pkat": "PkAt", "pkbd": "PkBd", "rotf": "RotF",
    "torf": "TorF", "movf": "MovF", "orig": "Orig",
    "+lbx": "+lBx", "-lbx": "-lBx", "lbbx": "lbBx",
    "none": " -- ", "cent": "Cent", "pktb": "PkTB",
    "slab": "Slab", "movs": "MovS", "pk1":  "Pk1 ",
    "mova": "MovA", "menu": "Menu", "sele": "Sele",
    "+/-":  "+/- ", "+box": "+Box", "-box": "-Box",
    "mvsz": "MvSZ", "clik": "Clik", "mvoz": "MvOZ",
    "movo": "MovO", "roto": "RotO", "drgm": "DrgM",
    "rotv": "RotV", "movv": "MovV", "mvvz": "MvVZ",
    "drgo": "DrgO", "mvfz": "MvFZ", "mvaz": "MvAZ",
    "rotl": "RotL", "movl": "MovL", "mvzl": "MvzL",
    "imsz": "IMSZ", "imvz": "IMvZ", "box":  " Box",
    "irtz": "IRtZ",
    "rotd": "RotD", "movd": "MovD", "mvdz": "MvDZ",
]

/// A single mouse button/modifier binding: (button, modifier, action).
private typealias Binding = (btn: String, mod: String, act: String)

/// Mouse mode: key, display name, and bindings list.
private struct MouseModeDefinition {
    let key: String
    let displayName: String
    let bindings: [Binding]
}

/// Index map: (button, modifier) -> slot in a 22-element action array.
/// Slots 0-11: drag actions (L/M/R x none/shft/ctrl/ctsh)
/// Slots 12-15: wheel (none/shft/ctrl/ctsh)
/// Slots 16-18: double-click (L/M/R)
/// Slots 19-21: single-click (L/M/R)
private let buttonModToIndex: [String: Int] = [
    "l:none": 0,  "m:none": 1,  "r:none": 2,
    "l:shft": 3,  "m:shft": 4,  "r:shft": 5,
    "l:ctrl": 6,  "m:ctrl": 7,  "r:ctrl": 8,
    "l:ctsh": 9,  "m:ctsh": 10, "r:ctsh": 11,
    "w:none": 12, "w:shft": 13, "w:ctrl": 14, "w:ctsh": 15,
    "double_left:none": 16,  "double_middle:none": 17, "double_right:none": 18,
    "single_left:none": 19,  "single_middle:none": 20, "single_right:none": 21,
]

/// Build a 22-element action array from a list of bindings.
private func buildModeArray(_ bindings: [Binding]) -> [String] {
    var mode = Array(repeating: "none", count: 22)
    for b in bindings {
        let key = "\(b.btn):\(b.mod)"
        if let idx = buttonModToIndex[key] {
            mode[idx] = b.act.lowercased()
        }
    }
    return mode
}

/// Display code for an action string.
private func codeFor(_ action: String) -> String {
    actionCodes[action.lowercased()] ?? String(action.prefix(4))
}

// MARK: - Mode data (mirrors pymol.controlling.mode_dict)

private let allModes: [MouseModeDefinition] = [
    MouseModeDefinition(key: "three_button_viewing", displayName: "3-Button Viewing", bindings: [
        ("l","none","rota"), ("m","none","move"), ("r","none","movz"),
        ("l","shft","+box"), ("m","shft","-box"), ("r","shft","clip"),
        ("l","ctrl","move"), ("m","ctrl","pkat"), ("r","ctrl","pk1"),
        ("l","ctsh","sele"), ("m","ctsh","orig"), ("r","ctsh","clip"),
        ("w","none","slab"), ("w","shft","movs"), ("w","ctrl","mvsz"), ("w","ctsh","movz"),
        ("double_left","none","menu"), ("double_middle","none","none"), ("double_right","none","pkat"),
        ("single_left","none","+/-"), ("single_middle","none","cent"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "three_button_editing", displayName: "3-Button Editing", bindings: [
        ("l","none","rota"), ("m","none","move"), ("r","none","movz"),
        ("l","shft","roto"), ("m","shft","movo"), ("r","shft","mvoz"),
        ("l","ctrl","torf"), ("m","ctrl","+/-"),  ("r","ctrl","pktb"),
        ("l","ctsh","mova"), ("m","ctsh","orig"), ("r","ctsh","clip"),
        ("w","none","slab"), ("w","shft","movs"), ("w","ctrl","mvsz"), ("w","ctsh","movz"),
        ("double_left","none","torf"), ("double_middle","none","drgm"), ("double_right","none","pktb"),
        ("single_left","none","pkat"), ("single_middle","none","cent"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "three_button_motions", displayName: "3-Button Motions", bindings: [
        ("l","none","rota"), ("m","none","move"), ("r","none","movz"),
        ("l","shft","rotv"), ("m","shft","movv"), ("r","shft","mvvz"),
        ("l","ctrl","torf"), ("m","ctrl","pkat"), ("r","ctrl","pktb"),
        ("l","ctsh","mova"), ("m","ctsh","orig"), ("r","ctsh","clip"),
        ("w","none","slab"), ("w","shft","movs"), ("w","ctrl","mvsz"), ("w","ctsh","movz"),
        ("double_left","none","torf"), ("double_middle","none","drgm"), ("double_right","none","pktb"),
        ("single_left","none","pkat"), ("single_middle","none","cent"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "three_button_lights", displayName: "3-Button Lights", bindings: [
        ("l","none","rota"), ("m","none","move"), ("r","none","movz"),
        ("l","shft","rotl"), ("m","shft","movl"), ("r","shft","mvzl"),
        ("l","ctrl","none"), ("m","ctrl","none"), ("r","ctrl","none"),
        ("l","ctsh","none"), ("m","ctsh","none"), ("r","ctsh","none"),
        ("w","none","slab"), ("w","shft","movs"), ("w","ctrl","mvsz"), ("w","ctsh","movz"),
        ("double_left","none","none"), ("double_middle","none","none"), ("double_right","none","none"),
        ("single_left","none","none"), ("single_middle","none","cent"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "three_button_maestro", displayName: "3-Button Maestro", bindings: [
        ("l","none","box"),  ("m","none","rota"), ("r","none","move"),
        ("l","shft","+box"), ("m","shft","-box"), ("r","shft","clip"),
        ("l","ctrl","+/-"),  ("m","ctrl","irtz"), ("r","ctrl","pk1"),
        ("l","ctsh","sele"), ("m","ctsh","orig"), ("r","ctsh","clip"),
        ("w","none","imvz"), ("w","shft","movs"), ("w","ctrl","none"), ("w","ctsh","slab"),
        ("double_left","none","menu"), ("double_middle","none","none"), ("double_right","none","pkat"),
        ("single_left","none","sele"), ("single_middle","none","cent"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "two_button_viewing", displayName: "2-Button Viewing", bindings: [
        ("l","none","rota"), ("m","none","none"), ("r","none","movz"),
        ("l","shft","pk1"),  ("m","shft","none"), ("r","shft","clip"),
        ("l","ctrl","move"), ("m","ctrl","none"), ("r","ctrl","pkat"),
        ("l","ctsh","sele"), ("m","ctsh","none"), ("r","ctsh","cent"),
        ("w","none","none"), ("w","shft","none"), ("w","ctrl","none"), ("w","ctsh","none"),
        ("double_left","none","menu"), ("double_middle","none","none"), ("double_right","none","pkat"),
        ("single_left","none","+/-"), ("single_middle","none","none"), ("single_right","none","menu"),
    ]),
    MouseModeDefinition(key: "one_button_viewing", displayName: "1-Button Viewing", bindings: [
        ("l","none","rota"), ("m","none","none"), ("r","none","none"),
        ("l","shft","none"), ("m","shft","none"), ("r","shft","none"),
        ("l","ctrl","none"), ("m","ctrl","none"), ("r","ctrl","none"),
        ("l","ctsh","none"), ("m","ctsh","none"), ("r","ctsh","none"),
        ("w","none","none"), ("w","shft","none"), ("w","ctrl","none"), ("w","ctsh","none"),
        ("double_left","none","menu"), ("double_middle","none","none"), ("double_right","none","none"),
        ("single_left","none","cent"), ("single_middle","none","none"), ("single_right","none","menu"),
    ]),
]

/// The default ring of (real PyMOL) modes users cycle through.
private let modeRing = ["three_button_viewing", "three_button_editing",
                        "three_button_motions", "three_button_lights",
                        "three_button_maestro"]

/// Synthetic mode key for the macOS "Trackpad" gesture mode. Not a PyMOL
/// mouse_mode — selecting it flips engine.trackpadMode (which re-routes the
/// MetalViewport trackpad gestures to rotate/pan/zoom/roll/clip) instead of
/// issuing a `mouse <mode>` command.
private let kTrackpadKey = "trackpad"

/// Gesture-oriented legend shown while Trackpad mode is active (rotate / move /
/// zoom / roll / clip), in place of the L/M/R button matrix.
private struct TrackpadGestureHint: Identifiable {
    let id = UUID(); let icon: String; let title: String; let detail: String
}
private let trackpadGestureHints: [TrackpadGestureHint] = [
    .init(icon: "hand.draw", title: "Rotate", detail: "Drag"),
    .init(icon: "hand.point.up.left", title: "Move", detail: "Two-finger pan"),
    .init(icon: "arrow.up.left.and.arrow.down.right.circle", title: "Zoom", detail: "Pinch"),
    .init(icon: "arrow.clockwise", title: "Roll", detail: "Two-finger twist"),
    .init(icon: "scissors", title: "Clip", detail: "Shift + two-finger"),
]

private let selectionModeNames = [
    "Atoms", "Residues", "Chains", "Segments",
    "Objects", "Molecules", "C-alphas",
]

// MARK: - MousePanel View

struct MousePanel: View {
    @EnvironmentObject var engine: PyMOLEngine

    // Persisted across launches. macOS defaults to "Trackpad" (the last display-
    // ring index); iOS defaults to the first real mode. selectionMode persists too.
    #if os(macOS)
    @AppStorage("macMouseModeIndex") private var selectedModeIndex: Int = -1
    #else
    @State private var selectedModeIndex: Int = 0
    #endif
    @State private var selectionModeIndex: Int = 1  // Residues default

    private let bgColor = Color(red: 0.149, green: 0.149, blue: 0.161)  // #262629
    private let headerColor = Color(red: 0.9, green: 0.9, blue: 0.9)
    private let actionColor = Color(red: 0.2, green: 1.0, blue: 0.2)
    private let modifierColor = Color(red: 1.0, green: 0.3, blue: 0.3)
    private let labelColor = Color(red: 0.6, green: 0.6, blue: 0.6)

    // The keys shown in the mode picker. macOS appends the synthetic "Trackpad"
    // entry; iOS shows the real PyMOL modes only.
    private var displayRing: [String] {
        #if os(macOS)
        return modeRing + [kTrackpadKey]
        #else
        return modeRing
        #endif
    }

    /// Effective selected index, clamped into the display ring. On macOS the
    /// persisted default (-1) resolves to the Trackpad entry (last index).
    private var effectiveModeIndex: Int {
        if displayRing.indices.contains(selectedModeIndex) { return selectedModeIndex }
        #if os(macOS)
        return displayRing.count - 1   // Trackpad
        #else
        return 0
        #endif
    }

    private func displayName(_ key: String) -> String {
        if key == kTrackpadKey { return "Trackpad" }
        return allModes.first { $0.key == key }?.displayName ?? key
    }

    private var isTrackpad: Bool {
        displayRing.indices.contains(effectiveModeIndex)
            && displayRing[effectiveModeIndex] == kTrackpadKey
    }

    private var currentMode: MouseModeDefinition {
        let ringKey = displayRing.indices.contains(effectiveModeIndex)
            ? displayRing[effectiveModeIndex] : modeRing[0]
        return allModes.first { $0.key == ringKey } ?? allModes[0]
    }

    private var modeArray: [String] {
        buildModeArray(currentMode.bindings)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode name + cycle picker
            modeHeader
                .padding(.horizontal, 6)
                .padding(.top, 4)

            // Trackpad: gesture legend. Otherwise the L/M/R button matrix.
            if isTrackpad {
                trackpadLegend
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            } else {
                actionGrid
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }

            // Selection mode
            selectionRow
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
        .background(bgColor)
        .onAppear { applyMode(effectiveModeIndex) }
        .onChange(of: selectedModeIndex) { applyMode($0) }
        .onChange(of: selectionModeIndex) { newIndex in
            engine.runCommand("set mouse_selection_mode, \(newIndex)")
        }
    }

    /// Apply the mode at `index`: flip engine.trackpadMode and, for real PyMOL
    /// modes, issue the `mouse <key>` command. The synthetic Trackpad entry only
    /// flips the flag (no PyMOL mouse_mode change).
    private func applyMode(_ index: Int) {
        guard displayRing.indices.contains(index) else { return }
        let key = displayRing[index]
        if key == kTrackpadKey {
            engine.trackpadMode = true
        } else {
            engine.trackpadMode = false
            engine.runCommand("mouse \(key)")
        }
    }

    // MARK: - Mode header with picker

    private var modeHeader: some View {
        HStack(spacing: 4) {
            Text("Mouse")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(headerColor)

            #if os(macOS)
            // NB: `Binding` is shadowed by a private typealias in this file
            // (the mouse-button tuple), so fully qualify the SwiftUI Binding.
            Picker("", selection: SwiftUI.Binding(
                get: { effectiveModeIndex },
                set: { selectedModeIndex = $0 })) {
                ForEach(displayRing.indices, id: \.self) { i in
                    Text(displayName(displayRing[i])).tag(i)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.mini)
            .frame(maxWidth: .infinity, alignment: .leading)
            #else
            Menu {
                ForEach(displayRing.indices, id: \.self) { i in
                    Button(displayName(displayRing[i])) { selectedModeIndex = i }
                }
            } label: {
                Text(displayName(displayRing[effectiveModeIndex]))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(actionColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
    }

    // MARK: - Trackpad gesture legend

    /// Compact gesture-oriented legend shown in Trackpad mode (no L/M/R matrix).
    private var trackpadLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(trackpadGestureHints) { h in
                HStack(spacing: 5) {
                    Image(systemName: h.icon)
                        .font(.system(size: 9))
                        .foregroundColor(actionColor)
                        .frame(width: 14)
                    Text(h.title)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(headerColor)
                        .frame(width: 42, alignment: .leading)
                    Text(h.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(labelColor)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action grid

    /// The grid shows drag actions for L/M/R columns across modifier rows,
    /// plus single-click and double-click rows.
    private var actionGrid: some View {
        let mode = modeArray
        let gridFont = Font.system(size: 9, design: .monospaced)

        return VStack(spacing: 0) {
            // Column headers
            gridRow(
                modifier: "Drag",
                modColor: labelColor,
                l: "L", m: "M", r: "R",
                cellColor: headerColor,
                font: gridFont
            )

            // Drag rows: plain, Shift, Ctrl, Ctrl+Shift
            gridRow(modifier: "    ", modColor: modifierColor,
                    l: codeFor(mode[0]), m: codeFor(mode[1]), r: codeFor(mode[2]),
                    cellColor: actionColor, font: gridFont)
            gridRow(modifier: "Shft", modColor: modifierColor,
                    l: codeFor(mode[3]), m: codeFor(mode[4]), r: codeFor(mode[5]),
                    cellColor: actionColor, font: gridFont)
            gridRow(modifier: "Ctrl", modColor: modifierColor,
                    l: codeFor(mode[6]), m: codeFor(mode[7]), r: codeFor(mode[8]),
                    cellColor: actionColor, font: gridFont)
            gridRow(modifier: "CtSh", modColor: modifierColor,
                    l: codeFor(mode[9]), m: codeFor(mode[10]), r: codeFor(mode[11]),
                    cellColor: actionColor, font: gridFont)

            // Click rows
            #if os(macOS)
            gridRow(modifier: "Sngl", modColor: labelColor,
                    l: codeFor(mode[19]), m: codeFor(mode[20]), r: codeFor(mode[21]),
                    cellColor: actionColor, font: gridFont)
            gridRow(modifier: "Dbl ", modColor: labelColor,
                    l: codeFor(mode[16]), m: codeFor(mode[17]), r: codeFor(mode[18]),
                    cellColor: actionColor, font: gridFont)
            #else
            // iPadOS: show touch equivalents
            gridRow(modifier: "Tap ", modColor: labelColor,
                    l: codeFor(mode[19]), m: codeFor(mode[20]), r: codeFor(mode[21]),
                    cellColor: actionColor, font: gridFont)
            gridRow(modifier: "2Tap", modColor: labelColor,
                    l: codeFor(mode[16]), m: codeFor(mode[17]), r: codeFor(mode[18]),
                    cellColor: actionColor, font: gridFont)
            #endif
        }
    }

    /// A single row in the action grid.
    private func gridRow(
        modifier: String,
        modColor: Color,
        l: String, m: String, r: String,
        cellColor: Color,
        font: Font
    ) -> some View {
        HStack(spacing: 0) {
            Text(modifier)
                .font(font)
                .foregroundColor(modColor)
                .frame(width: 32, alignment: .leading)

            Text(l)
                .font(font)
                .foregroundColor(cellColor)
                .frame(maxWidth: .infinity)

            Text(m)
                .font(font)
                .foregroundColor(cellColor)
                .frame(maxWidth: .infinity)

            Text(r)
                .font(font)
                .foregroundColor(cellColor)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 11)
    }

    // MARK: - Selection mode row

    private var selectionRow: some View {
        HStack(spacing: 4) {
            Text("Selecting")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(actionColor)

            Text(selectionModeNames.indices.contains(selectionModeIndex)
                 ? selectionModeNames[selectionModeIndex] : "Atoms")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.3, green: 1.0, blue: 1.0))
                .onTapGesture {
                    selectionModeIndex = (selectionModeIndex + 1) % selectionModeNames.count
                }

            Spacer()
        }
    }
}

// MARK: - Preview

struct MousePanel_Previews: PreviewProvider {
    static var previews: some View {
        MousePanel()
            .environmentObject(PyMOLEngine.shared)
            .frame(width: 300, height: 120)
            .preferredColorScheme(.dark)
    }
}
