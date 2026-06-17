// Theme.swift — RayMol theme model: app chrome + molecular defaults.
// A Theme is fully Codable so custom themes persist as JSON in UserDefaults.

import SwiftUI

/// sRGB color, Codable (SwiftUI.Color is not Codable).
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    /// "r, g, b" in 0..1 for PyMOL set_color.
    var pymolTriplet: String { String(format: "%.4f, %.4f, %.4f", r, g, b) }
    /// Linear blend toward `other` by `t` (0…1). Keeps alpha solid for both
    /// endpoints at alpha 1, so derived chrome colors stay opaque.
    func blended(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t,
             b + (other.b - b) * t, a + (other.a - a) * t)
    }
}

struct FontSpec: Codable, Equatable {
    enum Family: String, Codable, CaseIterable { case monospaced, system, serif, rounded }
    var family: Family
    var size: Double
    var design: Font.Design {
        switch family {
        case .monospaced: return .monospaced
        case .serif:      return .serif
        case .rounded:    return .rounded
        case .system:     return .default
        }
    }
    var font: Font { .system(size: size, design: design) }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// nil = follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

enum RepStyle: String, Codable, CaseIterable, Identifiable {
    case cartoon, sticks, ballStick = "ball_stick", spheres, surface, pretty
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ballStick: return "Ball & Stick"
        default: return rawValue.capitalized
        }
    }
}

struct Theme: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var builtIn: Bool
    var appearance: Appearance

    // App chrome
    var accent: RGBA
    var bubble: RGBA
    var selectionName: RGBA
    var tabTint: RGBA
    var viewportBackground: RGBA
    var terminalFont: FontSpec
    var terminalText: RGBA
    var panelBackground: RGBA   // chrome surface (panels, console bg)
    var panelText: RGBA

    // Molecular defaults (NEW objects only)
    var chainCycle: [RGBA]
    var elementColors: [String: RGBA]   // N,O,S,P,H,halogens… (carbon untouched)
    var defaultStyle: RepStyle

    // Render toggles
    var outline: Bool
    var flatSheets: Bool
    var fancyHelices: Bool
    var rayTrace: Bool       // metal_raytrace (real-time AO + shadows)
    var shadows: Bool        // metal_shadows (shadow-map shadows)

    init(id: UUID, name: String, builtIn: Bool, appearance: Appearance,
         accent: RGBA, bubble: RGBA, selectionName: RGBA, tabTint: RGBA,
         viewportBackground: RGBA, terminalFont: FontSpec, terminalText: RGBA,
         panelBackground: RGBA, panelText: RGBA, chainCycle: [RGBA],
         elementColors: [String: RGBA], defaultStyle: RepStyle,
         outline: Bool, flatSheets: Bool, fancyHelices: Bool,
         rayTrace: Bool = false, shadows: Bool = false) {
        self.id = id; self.name = name; self.builtIn = builtIn; self.appearance = appearance
        self.accent = accent; self.bubble = bubble; self.selectionName = selectionName
        self.tabTint = tabTint; self.viewportBackground = viewportBackground
        self.terminalFont = terminalFont; self.terminalText = terminalText
        self.panelBackground = panelBackground; self.panelText = panelText
        self.chainCycle = chainCycle; self.elementColors = elementColors
        self.defaultStyle = defaultStyle; self.outline = outline
        self.flatSheets = flatSheets; self.fancyHelices = fancyHelices
        self.rayTrace = rayTrace; self.shadows = shadows
    }

    // Lenient decode: rayTrace/shadows were added later, so default them when a
    // previously-saved custom theme lacks the keys (avoids dropping the theme).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        builtIn = try c.decode(Bool.self, forKey: .builtIn)
        appearance = try c.decode(Appearance.self, forKey: .appearance)
        accent = try c.decode(RGBA.self, forKey: .accent)
        bubble = try c.decode(RGBA.self, forKey: .bubble)
        selectionName = try c.decode(RGBA.self, forKey: .selectionName)
        tabTint = try c.decode(RGBA.self, forKey: .tabTint)
        viewportBackground = try c.decode(RGBA.self, forKey: .viewportBackground)
        terminalFont = try c.decode(FontSpec.self, forKey: .terminalFont)
        terminalText = try c.decode(RGBA.self, forKey: .terminalText)
        panelBackground = try c.decode(RGBA.self, forKey: .panelBackground)
        panelText = try c.decode(RGBA.self, forKey: .panelText)
        chainCycle = try c.decode([RGBA].self, forKey: .chainCycle)
        elementColors = try c.decode([String: RGBA].self, forKey: .elementColors)
        defaultStyle = try c.decode(RepStyle.self, forKey: .defaultStyle)
        outline = try c.decode(Bool.self, forKey: .outline)
        flatSheets = try c.decode(Bool.self, forKey: .flatSheets)
        fancyHelices = try c.decode(Bool.self, forKey: .fancyHelices)
        rayTrace = try c.decodeIfPresent(Bool.self, forKey: .rayTrace) ?? false
        shadows = try c.decodeIfPresent(Bool.self, forKey: .shadows) ?? false
    }
}

// MARK: - Color <-> RGBA

extension Color {
    /// Resolve a SwiftUI Color to sRGB components for persistence / PyMOL.
    var rgba: RGBA {
        #if os(macOS)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RGBA(Double(ns.redComponent), Double(ns.greenComponent),
                    Double(ns.blueComponent), Double(ns.alphaComponent))
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(Double(r), Double(g), Double(b), Double(a))
        #endif
    }
}

// MARK: - Curated presets

extension Theme {
    // Stable IDs so persistence (active-id) survives relaunch. classicID reuses
    // the old Midnight slot so anyone previously on Midnight lands on Classic.
    static let classicID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let paperID   = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let sunsetID  = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    static let dawnID    = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    /// Chain color cycle (distinct, color-blind-leaning hues).
    static let defaultChainCycle: [RGBA] = [
        RGBA(0.25, 0.55, 1.00), RGBA(0.20, 0.80, 0.40), RGBA(1.00, 0.50, 0.20),
        RGBA(0.85, 0.30, 0.85), RGBA(0.95, 0.85, 0.25), RGBA(0.30, 0.85, 0.85),
        RGBA(1.00, 0.40, 0.40), RGBA(0.60, 0.45, 0.95)
    ]
    /// PyMOL-ish element colors (non-carbon). Carbon is intentionally absent.
    static let defaultElementColors: [String: RGBA] = [
        "N": RGBA(0.20, 0.20, 1.00), "O": RGBA(1.00, 0.20, 0.20),
        "S": RGBA(0.90, 0.78, 0.20), "P": RGBA(1.00, 0.50, 0.00),
        "H": RGBA(0.90, 0.90, 0.90), "F": RGBA(0.50, 0.85, 0.25),
        "CL": RGBA(0.30, 0.85, 0.25), "BR": RGBA(0.60, 0.32, 0.12),
        "I": RGBA(0.58, 0.00, 0.58)
    ]

    /// Classic PyMOL: black viewport, neutral dark chrome, standard PyMOL
    /// element/chain colors, no real-time shadows — the canonical look.
    static let classic = Theme(
        id: classicID, name: "Classic", builtIn: true, appearance: .dark,
        accent: RGBA(0.30, 0.60, 0.95), bubble: RGBA(0.30, 0.60, 0.95),
        selectionName: RGBA(0.95, 0.35, 0.85), tabTint: RGBA(0.30, 0.60, 0.95),
        viewportBackground: RGBA(0.0, 0.0, 0.0),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(0.85, 0.85, 0.85),
        panelBackground: RGBA(0.13, 0.13, 0.15), panelText: RGBA(0.88, 0.88, 0.90),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: false, flatSheets: false, fancyHelices: false,
        rayTrace: false, shadows: false)

    static let paper = Theme(
        id: paperID, name: "Paper", builtIn: true, appearance: .light,
        accent: RGBA(0.10, 0.45, 0.85), bubble: RGBA(0.10, 0.45, 0.85),
        selectionName: RGBA(0.85, 0.35, 0.0), tabTint: RGBA(0.10, 0.45, 0.85),
        viewportBackground: RGBA(1.0, 1.0, 1.0),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(0.10, 0.10, 0.10),
        panelBackground: RGBA(0.95, 0.95, 0.96), panelText: RGBA(0.12, 0.12, 0.14),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: true, flatSheets: true, fancyHelices: false,
        rayTrace: false, shadows: true)

    /// Sunset: warm dusk — deep plum viewport, orange/magenta accents, fancy
    /// helices + shadows for a rich dark look.
    static let sunset = Theme(
        id: sunsetID, name: "Sunset", builtIn: true, appearance: .dark,
        accent: RGBA(1.00, 0.55, 0.25), bubble: RGBA(0.85, 0.35, 0.45),
        selectionName: RGBA(1.00, 0.40, 0.70), tabTint: RGBA(1.00, 0.55, 0.25),
        viewportBackground: RGBA(0.09, 0.06, 0.13),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(1.00, 0.78, 0.55),
        panelBackground: RGBA(0.16, 0.11, 0.16), panelText: RGBA(0.95, 0.90, 0.86),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: false, flatSheets: false, fancyHelices: true,
        rayTrace: false, shadows: true)

    /// Dawn: soft sunrise — warm off-white viewport, coral accents, outline +
    /// flat sheets for a clean light look.
    static let dawn = Theme(
        id: dawnID, name: "Dawn", builtIn: true, appearance: .light,
        accent: RGBA(0.95, 0.45, 0.35), bubble: RGBA(0.95, 0.50, 0.40),
        selectionName: RGBA(0.90, 0.40, 0.25), tabTint: RGBA(0.95, 0.45, 0.35),
        viewportBackground: RGBA(1.0, 0.97, 0.93),
        terminalFont: FontSpec(family: .monospaced, size: 11), terminalText: RGBA(0.35, 0.20, 0.15),
        panelBackground: RGBA(0.98, 0.94, 0.90), panelText: RGBA(0.22, 0.15, 0.13),
        chainCycle: defaultChainCycle, elementColors: defaultElementColors,
        defaultStyle: .cartoon, outline: true, flatSheets: true, fancyHelices: false,
        rayTrace: false, shadows: true)

    static let builtInPresets: [Theme] = [classic, paper, sunset, dawn]

    /// SwiftUI color scheme derived from the chrome (panel) luminance, so native
    /// controls always match the palette — no separate appearance toggle to fight
    /// it. (The `appearance` field is retained for Codable back-compat only.)
    var resolvedColorScheme: ColorScheme {
        let l = 0.2126 * panelBackground.r + 0.7152 * panelBackground.g + 0.0722 * panelBackground.b
        return l < 0.5 ? .dark : .light
    }
}
