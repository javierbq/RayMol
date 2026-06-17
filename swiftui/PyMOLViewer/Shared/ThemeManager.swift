// ThemeManager.swift — owns the active theme + custom list; persists to UserDefaults;
// pushes molecular/viewport defaults into PyMOL via raymol_theme. App chrome updates
// automatically through SwiftUI views observing the @Published `active`.

import SwiftUI

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var active: Theme
    @Published private(set) var custom: [Theme]

    /// True until the user picks a theme for the first time (drives first-boot popup).
    @Published var firstBoot: Bool

    private let activeKey = "raymol.theme.activeID"
    private let customKey = "raymol.theme.custom"
    private let firstBootKey = "raymol.theme.didFirstBoot"

    var presets: [Theme] { Theme.builtInPresets }
    var all: [Theme] { presets + custom }

    private init() {
        let d = UserDefaults.standard
        // Load custom list into a local (can't read self.* until all stored
        // properties are initialized).
        let loadedCustom: [Theme]
        if let data = d.data(forKey: customKey),
           let decoded = try? JSONDecoder().decode([Theme].self, from: data) {
            loadedCustom = decoded
        } else {
            loadedCustom = []
        }
        custom = loadedCustom
        // Resolve active by stored id (preset or custom), default Midnight.
        let storedID = d.string(forKey: activeKey).flatMap { UUID(uuidString: $0) }
        let pool = Theme.builtInPresets + loadedCustom
        active = pool.first(where: { $0.id == storedID }) ?? Theme.classic
        firstBoot = d.object(forKey: firstBootKey) == nil
    }

    // MARK: - Selection / editing

    func select(_ theme: Theme, engine: PyMOLEngine? = nil) {
        active = theme
        persistActive()
        if let engine { apply(engine: engine) }
    }

    /// Save (or overwrite by id) a custom theme and make it active.
    func saveCustom(_ theme: Theme, engine: PyMOLEngine? = nil) {
        var t = theme
        t.builtIn = false
        if t.id == Theme.classicID || t.id == Theme.paperID
            || t.id == Theme.sunsetID || t.id == Theme.dawnID {
            t.id = UUID()   // never overwrite a preset id
        }
        if let i = custom.firstIndex(where: { $0.id == t.id }) {
            custom[i] = t
        } else {
            custom.append(t)
        }
        persistCustom()
        select(t, engine: engine)
    }

    func deleteCustom(_ theme: Theme) {
        custom.removeAll { $0.id == theme.id }
        persistCustom()
        if active.id == theme.id { active = Theme.classic; persistActive() }
    }

    func markFirstBootDone() {
        firstBoot = false
        UserDefaults.standard.set(true, forKey: firstBootKey)
    }

    // MARK: - Apply to PyMOL

    /// Push viewport bg + render toggles + molecular default palette into PyMOL.
    /// Chrome (SwiftUI) updates automatically via @Published `active`.
    func apply(engine: PyMOLEngine) {
        engine.applyTheme(active)
    }

    // MARK: - Persistence

    private func persistActive() {
        UserDefaults.standard.set(active.id.uuidString, forKey: activeKey)
    }
    private func persistCustom() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
    }
}
