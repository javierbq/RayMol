// LightsController.swift — the model behind Lights mode (#619, spec §9).
//
// One controller per engine holds what every light tool shares: the read-only
// mirror of the rig, the ONE light selection, the identity colour of each
// light, the rig as it was when the mode was entered (for Revert) and the
// bar's actions. The bar (#619), the inspector (#620), the orbit view (#621)
// and the gizmo (#622) all observe this one object, so they always agree on
// which light is selected and what colour stands for it.
//
// This file never talks to Python, the console or the bridge directly: it
// goes through LightsSeams, which the engine wires (the bridge's JSON read and
// per-field setters for continuous edits; a console command or one Python
// call for a button press) and the unit tests fake. Continuous edits use only
// the setter seams, so a drag runs no Python per tick (#610).

import Foundation
import Combine

// MARK: - Selection

/// The selected light, by name and index. While Lights mode is active there is
/// a selection exactly when the rig has lights.
struct LightSelection: Equatable {
    var name: String?
    var index: Int?

    init(name: String? = nil, index: Int? = nil) {
        self.name = name
        self.index = index
    }

    /// `selection` repaired against the rig's light names (in rig order):
    /// 1. no lights: nothing selected;
    /// 2. the selected name is still there (ignoring case, as the core does):
    ///    keep it, at its current index and with the rig's spelling;
    /// 3. otherwise, when there was an index: clamp it to the new count (a
    ///    rename keeps the slot; removing the selected light selects the one
    ///    that slid into its place, or the new last);
    /// 4. otherwise the first light.
    static func repaired(_ selection: LightSelection, names: [String]) -> LightSelection {
        guard !names.isEmpty else { return LightSelection() }
        if let name = selection.name?.lowercased(),
           let index = names.firstIndex(where: { $0.lowercased() == name }) {
            return LightSelection(name: names[index], index: index)
        }
        if let index = selection.index {
            let clamped = min(max(index, 0), names.count - 1)
            return LightSelection(name: names[clamped], index: clamped)
        }
        return LightSelection(name: names[0], index: 0)
    }
}

// MARK: - Identity colours

/// Identity colour slots: the colour that stands for a light in the bar's
/// chips, the orbit view's lamps and the gizmo's knobs. It is the light's
/// identity, not its own colour (the inspector shows that). Slots are stable
/// by name, so removing one light never recolours the others. The colour of
/// each slot (blue, orange, green, purple, pink, gold) lives with the views.
enum LightPalette {
    static let count = 6

    /// The default slot of the names the core gives new lights: key 0, fill 1,
    /// rim 2, light4 3, light5 4, light6 5 (ignoring case). nil for any other.
    static func defaultSlot(for name: String) -> Int? {
        switch name.lowercased() {
        case "key": return 0
        case "fill": return 1
        case "rim": return 2
        case "light4": return 3
        case "light5": return 4
        case "light6": return 5
        default: return nil
        }
    }

    /// Slots for `names` (rig order), keyed by lowercased name, given the
    /// `previous` assignment (same keys):
    /// 1. a name already in `previous` keeps its slot;
    /// 2. a new name takes its default slot when it has one and that slot is
    ///    free (new names with a default claim them first, so a renamed light
    ///    earlier in the rig cannot take `key`'s blue);
    /// 3. any other new name takes the lowest free slot;
    /// 4. names no longer in the rig are dropped.
    /// So three_point is blue, orange, green; removing `key` leaves fill
    /// orange and rim green; renaming `fill` usually keeps orange (its slot is
    /// the lowest free one); a preset that replaces every name starts again
    /// from slot 0 in rig order.
    static func assign(names: [String], previous: [String: Int]) -> [String: Int] {
        var keys: [String] = []
        for name in names {
            let key = name.lowercased()
            if !keys.contains(key) { keys.append(key) }
        }
        var slots: [String: Int] = [:]
        var used = Set<Int>()
        func take(_ key: String, _ slot: Int) {
            slots[key] = slot
            used.insert(slot)
        }
        for key in keys {
            if let slot = previous[key], (0..<count).contains(slot), !used.contains(slot) {
                take(key, slot)
            }
        }
        for key in keys where slots[key] == nil {
            if let slot = defaultSlot(for: key), !used.contains(slot) {
                take(key, slot)
            }
        }
        for key in keys where slots[key] == nil {
            // More names than slots cannot happen (a rig holds at most
            // `count` lights); wrap rather than trap if it ever does.
            take(key, (0..<count).first { !used.contains($0) } ?? (used.count % count))
        }
        return slots
    }
}

// MARK: - Presets and actions

/// One entry of the preset menu, decoded from what
/// pymol.appkit_lights.write_presets writes: [{"name", "description"}, ...].
struct LightPreset: Decodable, Equatable, Identifiable {
    let name: String
    let description: String

    var id: String { name }

    /// The menu title: "three_point" -> "Three point" (underscores to spaces,
    /// the first letter capitalised). The raw name is what the command takes.
    var displayName: String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return spaced }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Decode the helper's JSON list.
    static func decodeList(_ data: Data) throws -> [LightPreset] {
        try JSONDecoder().decode([LightPreset].self, from: data)
    }
}

/// A button press of the Lights bar. The engine maps each to what it runs (a
/// `lights` console command, or the Revert helper); none is a drag tick.
enum LightsAction: Equatable {
    /// Add a light with the core's next default name.
    case add
    /// Remove the light with this name.
    case remove(String)
    /// Replace the rig's lights with this preset (by its name).
    case preset(String)
    /// Re-capture the rig's centre and 1x size from the molecules.
    case recenter
    /// Turn the rig on or off.
    case setEnabled(Bool)
    /// Put back the rig whose JSON this is ("null" = no rig).
    case restore(String)
}

/// What the controller needs from the engine. The engine wires the real ones;
/// tests use fakes.
struct LightsSeams {
    /// The rig's JSON as the core writes it, or nil when there is no rig
    /// (a bridge read: C++, no Python).
    var rigJSON: () -> String?
    /// Set one number field of light `index` (the bridge setter).
    var setNumber: (Int, String, Double) -> LightSetResult
    /// Set one vector field of light `index` (the bridge setter).
    var setVector: (Int, String, SIMD3<Double>) -> LightSetResult
    /// A button press: one console command or one Python call.
    var perform: (LightsAction) -> Void
    /// The preset menu (one Python call; the controller caches it).
    var loadPresets: () -> [LightPreset]
    /// The engine is up.
    var isReady: () -> Bool
    /// The rig must not be touched now (a movie export reads it off-main).
    var isBusy: () -> Bool
    /// A monotonic clock in seconds.
    var now: () -> TimeInterval
}

// MARK: - Controller

/// The one Lights model (see the file header). `begin()` and `end()` are
/// driven by the engine when the interaction mode enters or leaves Lights.
@MainActor
final class LightsController: ObservableObject {
    /// A rig holds at most this many lights.
    nonisolated static let maxLights = Int(PYMOL_LIGHTS_MAX)

    /// A mirror older than this is re-read before an edit writes to it, so a
    /// gesture never writes to the light that used to be at the selected index.
    nonisolated static let staleAfter: TimeInterval = 1.0 / 60.0

    /// Lights mode is on (between `begin()` and `end()`).
    @Published private(set) var isActive = false
    /// The rig as last read (nil: no rig). Read-only: every change goes
    /// through the seams and comes back here on the next refresh.
    @Published private(set) var rig: LightRigSnapshot?
    /// The one light selection shared by every light tool.
    @Published private(set) var selection = LightSelection()
    /// Identity colour slot by lowercased light name (see LightPalette).
    @Published private(set) var identitySlots: [String: Int] = [:]
    /// The preset menu, loaded once (retried while it comes back empty).
    @Published private(set) var presets: [LightPreset] = []
    /// The rig's JSON when the mode was entered, for Revert: nil while not
    /// taken (inactive, or the engine was not ready yet), "null" for no rig.
    @Published private(set) var entryJSON: String?
    /// The rig the mode was entered with, decoded (nil for no rig): what a
    /// per-light "revert this light" compares against.
    private(set) var entryRig: LightRigSnapshot?

    private let seams: LightsSeams
    /// The JSON `rig` was decoded from, and whether there has been a read.
    private var mirrorJSON: String?
    private var hasMirror = false
    /// When the mirror was last read (`seams.now()`).
    private var lastRefresh: TimeInterval?
    /// `begin()` ran but the entry snapshot is still to be taken.
    private var needsSnapshot = false

    init(seams: LightsSeams) {
        self.seams = seams
    }

    // MARK: derived state

    var selectedIndex: Int? { selection.index }

    var selectedLight: LightRigSnapshot.Light? {
        guard let index = selection.index, let lights = rig?.lights,
              lights.indices.contains(index) else { return nil }
        return lights[index]
    }

    /// The rig has at least one light.
    var hasLights: Bool { !(rig?.lights.isEmpty ?? true) }
    /// The rig is on.
    var isOn: Bool { rig?.enabled ?? false }
    /// Something else holds the rig (a movie export): no action, edit or read.
    var isBusy: Bool { seams.isBusy() }

    private var canAct: Bool { isActive && !seams.isBusy() }

    var canAdd: Bool { canAct && (rig?.lights.count ?? 0) < Self.maxLights }
    var canRemove: Bool { canAct && selection.index != nil }
    var canRecentre: Bool { canAct && hasLights }
    var canToggle: Bool { canAct && hasLights }
    /// Something changed since the mode was entered.
    var canRevert: Bool {
        guard canAct, let entry = entryJSON else { return false }
        return (mirrorJSON ?? "null") != entry
    }

    /// The identity colour slot of the light called `name` (ignoring case).
    func identitySlot(for name: String) -> Int {
        identitySlots[name.lowercased()] ?? LightPalette.defaultSlot(for: name) ?? 0
    }

    // MARK: mode

    /// Lights mode was entered. Takes the entry snapshot (now, or on the first
    /// refresh once the engine is ready), loads the presets once, mirrors the
    /// rig and repairs the selection (the first light by default). Writes
    /// nothing: entering never creates a rig. A second call while active keeps
    /// the first snapshot.
    func begin() {
        guard !isActive else { return }
        isActive = true
        needsSnapshot = true
        refresh()
        repairSelection()
    }

    /// Lights mode was left (Done, Esc, another mode). Edits are kept; the
    /// entry snapshot is dropped. The selection stays, repaired on the next
    /// `begin()`.
    func end() {
        if isActive { isActive = false }
        needsSnapshot = false
        if entryJSON != nil { entryJSON = nil }
        entryRig = nil
    }

    /// Re-read the rig. Publishes only when its JSON changed, so a periodic
    /// poll causes no view updates while nothing happens. The first ready
    /// refresh after `begin()` takes the entry snapshot. Does nothing while
    /// busy or before the engine is ready.
    func refresh() {
        guard !seams.isBusy(), seams.isReady() else { return }
        let json = seams.rigJSON()
        lastRefresh = seams.now()
        if needsSnapshot {
            needsSnapshot = false
            entryJSON = json ?? "null"
            entryRig = json.flatMap(Self.decode)
            if presets.isEmpty {
                let loaded = seams.loadPresets()
                if !loaded.isEmpty { presets = loaded }
            }
        }
        guard !hasMirror || json != mirrorJSON else { return }
        hasMirror = true
        mirrorJSON = json
        let decoded = json.flatMap(Self.decode)
        if decoded != rig { rig = decoded }
        let names = decoded?.lights.map(\.name) ?? []
        let slots = LightPalette.assign(names: names, previous: identitySlots)
        if slots != identitySlots { identitySlots = slots }
        repairSelection()
    }

    // MARK: selection

    /// Select light `index` of the rig; ignored when there is no such light.
    func select(index: Int) {
        guard let lights = rig?.lights, lights.indices.contains(index) else { return }
        setSelection(LightSelection(name: lights[index].name, index: index))
    }

    /// Select the light called `name` (ignoring case); ignored when there is
    /// no such light.
    func select(name: String) {
        let key = name.lowercased()
        guard let index = rig?.lights.firstIndex(where: { $0.name.lowercased() == key })
        else { return }
        select(index: index)
    }

    // MARK: actions (button presses)

    /// Add a light and select it.
    func add() {
        guard canAdd else { return }
        let before = Set((rig?.lights ?? []).map { $0.name.lowercased() })
        seams.perform(.add)
        refresh()
        if let added = rig?.lights.firstIndex(where: { !before.contains($0.name.lowercased()) }) {
            select(index: added)
        }
    }

    /// Remove the selected light; the one that slides into its place (or the
    /// new last) is selected.
    func removeSelected() {
        guard canRemove else { return }
        let target = selectedLight?.name ?? selection.name
        guard let name = target else { return }
        seams.perform(.remove(name))
        refresh()
    }

    /// Apply the preset called `name` and select its first light.
    func applyPreset(_ name: String) {
        guard canAct else { return }
        seams.perform(.preset(name))
        refresh()
        select(index: 0)
    }

    /// Re-capture the rig's centre and 1x size from the molecules.
    func recentre() {
        guard canRecentre else { return }
        seams.perform(.recenter)
        refresh()
    }

    /// Turn the rig on or off.
    func setEnabled(_ on: Bool) {
        guard canToggle else { return }
        seams.perform(.setEnabled(on))
        refresh()
    }

    /// Put back the rig the mode was entered with. The mode stays open and the
    /// snapshot is kept, so Revert can be pressed again.
    func revert() {
        guard canAct, let entry = entryJSON else { return }
        seams.perform(.restore(entry))
        refresh()
    }

    // MARK: continuous edits (bridge setters only)

    /// Set one number field of the selected light through the bridge setter
    /// (no Python): what a drag tick of #620-#622 calls. `.badIndex` when
    /// inactive, busy or nothing is selected.
    @discardableResult
    func edit(_ field: String, _ value: Double) -> LightSetResult {
        write { self.seams.setNumber($0, field, value) }
    }

    /// Set one vector field of the selected light through the bridge setter.
    @discardableResult
    func edit(_ field: String, _ vector: SIMD3<Double>) -> LightSetResult {
        write { self.seams.setVector($0, field, vector) }
    }

    // MARK: private

    private func write(_ set: (Int) -> LightSetResult) -> LightSetResult {
        guard canAct, selection.index != nil else { return .badIndex }
        // A console or MCP change since the last read may have moved the
        // selected light: re-read first so the write lands on the light that
        // is selected now. During a drag each successful write re-reads, so
        // this adds no read per tick.
        if let last = lastRefresh, seams.now() - last <= Self.staleAfter {
            // fresh enough
        } else {
            refresh()
        }
        guard let index = selection.index else { return .badIndex }
        let result = set(index)
        if result == .ok { refresh() }
        return result
    }

    private func repairSelection() {
        setSelection(LightSelection.repaired(selection, names: rig?.lights.map(\.name) ?? []))
    }

    private func setSelection(_ new: LightSelection) {
        if new != selection { selection = new }
    }

    private static func decode(_ json: String) -> LightRigSnapshot? {
        try? LightRigSnapshot.decode(Data(json.utf8))
    }
}
