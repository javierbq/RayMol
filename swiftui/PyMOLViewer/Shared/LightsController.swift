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
//
// The typed edit API every light tool shares (set, step, setPlacement,
// setColour, setPinned, setShadow) is in LightsEditing.swift; the per-frame
// eye data (each light's current orbit, pitch and radius, and on demand the
// whole rig in eye space) is in LightsEyeState below, a separate object so a
// per-frame update redraws only the views that show it, never the bar.
//
// The rig's air (haze and dust, #726) goes the same two ways: the Atmosphere
// card's slider ticks and typed values write it through the setter seam at
// index -1 (`writeRigNumbers`), and its On/Off switch is a button press
// (`setAtmosphere(on:)`: one `atmosphere` command). The air's typed API, its
// field table and the card's model are in LightsAtmosphere.swift.

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
    /// Put back the light called `name` (ignoring case) as it is in the rig
    /// whose JSON this is, at the index it has now; every other light and the
    /// rig's own fields stay as they are (Revert this light, #620).
    case restoreLight(name: String, json: String)
    /// Place light `name` so its highlight lands on the surface under scene
    /// NDC (`x`, `y`) (#612's `click=` helper, #622's ⌥-click): the mirror
    /// rule, or `rim` degrees towards the outline when given; `pin` keeps a
    /// pinned light pinned (the helper otherwise leaves a camera light).
    case highlight(name: String, x: Double, y: Double, rim: Double?, pin: Bool)
    /// The Atmosphere card's Off (#726): every air field back to its table
    /// default (`atmosphere off`).
    case atmosphereOff
    /// The Atmosphere card's On (#726): set these air fields in one
    /// `atmosphere` command (with no rig it creates one, off, with no lights).
    case setAir([AirValue])
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
    /// The air rows of the core's field table, the Atmosphere card's ranges
    /// and defaults (#726; the engine reads them in the presets' Python call
    /// and caches both; the controller caches them too).
    var loadAirFields: () -> [AirField] = { [] }
    /// The engine is up.
    var isReady: () -> Bool
    /// The rig must not be touched now (a movie export reads it off-main).
    var isBusy: () -> Bool
    /// A monotonic clock in seconds.
    var now: () -> TimeInterval
    /// The rig resolved to eye space for the live camera, or nil when there is
    /// no rig (a bridge read: C++, no Python). Read only while a light is
    /// pinned or a tool asks for every frame (`LightsEyeDemand`).
    var eyeSpace: () -> LightEyeSpace? = { nil }
    /// The live camera the gizmo projects eye space with (#622: the view,
    /// the letterbox and the field of view; C++ reads, no Python), or nil
    /// before the engine is up. Read only with the eye space under
    /// `.everyFrame`.
    var projection: () -> LightCameraProjection? = { nil }
}

// MARK: - Eye state

/// How much eye-space data the light tools need per rendered frame.
enum LightsEyeDemand: Equatable {
    /// Only the placements of pinned lights (they move with the camera):
    /// no bridge read at all while no light is pinned.
    case pinnedOnly
    /// The whole rig in eye space and the camera's projection every
    /// rendered frame (#622's gizmo: the engine sets it while Lights mode is
    /// on), published in `LightsEyeState.eyeSpace` and `.projection`.
    case everyFrame
}

/// The per-frame eye data, owned by the controller and kept apart from it so
/// that a per-frame update re-renders only the views observing this object
/// (the inspector's placement rows, #621's orbit view, #622's gizmo), never
/// the bar or the rest of the inspector.
@MainActor
final class LightsEyeState: ObservableObject {
    /// One per rig light, in rig order: a camera light's stored orbit, pitch
    /// and radius, a pinned light's current ones in eye space. Empty while
    /// Lights mode is off.
    @Published fileprivate(set) var placements: [LightPlacement] = []
    /// The latest eye-space read, published only while the demand is
    /// `.everyFrame` (nil otherwise), so float noise from lights nobody shows
    /// never re-renders the inspector.
    @Published fileprivate(set) var eyeSpace: LightEyeSpace?
    /// The camera `eyeSpace` was read under, published with it (the same
    /// call, only under `.everyFrame` and only with a usable eye read), so
    /// the two always describe one camera; nil otherwise.
    @Published fileprivate(set) var projection: LightCameraProjection?

    /// Publish `new` when its count differs or some value moved by more than
    /// `tolerance` (0: any change).
    fileprivate func publish(_ new: [LightPlacement], tolerance: Double) {
        if new.count != placements.count
            || zip(new, placements).contains(where: { $0.differs(from: $1, by: tolerance) }) {
            placements = new
        }
    }

    fileprivate func publish(eyeSpace new: LightEyeSpace?) {
        if new != eyeSpace { eyeSpace = new }
    }

    fileprivate func publish(projection new: LightCameraProjection?) {
        if new != projection { projection = new }
    }

    fileprivate func clear() {
        if !placements.isEmpty { placements = [] }
        if eyeSpace != nil { eyeSpace = nil }
        if projection != nil { projection = nil }
    }
}

/// Which lights are behind the molecule (`LightDepth`: behind the rig centre
/// in eye depth), the one answer the bar's chips and the gizmo's knobs show,
/// and each light's shadow-map slot this frame (#673), which the inspector's
/// "No casters" line reads. Its own object, published only when a value
/// changes, so the per-frame eye read re-renders its observers (the chips,
/// the inspector) only on a crossing or a slot change, never the bar.
@MainActor
final class LightsFacingState: ObservableObject {
    /// Lowercased names of the lights behind the molecule. Empty while
    /// Lights mode is off.
    @Published fileprivate(set) var behind: Set<String> = []
    /// Lowercased light name -> slot (0..2, or -1 when it gets no map), from the latest
    /// consistent eye read; empty when unknown (#673).
    @Published fileprivate(set) var shadowSlots: [String: Int] = [:]

    /// The light called `name` (ignoring case) is behind the molecule.
    func isBehind(_ name: String) -> Bool { behind.contains(name.lowercased()) }

    /// The shadow-map slot of the light called `name` (ignoring case), or nil when unknown (#673).
    func shadowSlot(of name: String) -> Int? { shadowSlots[name.lowercased()] }

    fileprivate func publish(_ new: Set<String>) {
        if new != behind { behind = new }
    }

    fileprivate func publish(shadowSlots new: [String: Int]) {
        if new != shadowSlots { shadowSlots = new }
    }
}

// MARK: - Controller

/// The one Lights model (see the file header). `begin()` and `end()` are
/// driven by the engine when the interaction mode enters or leaves Lights.
@MainActor
final class LightsController: ObservableObject {
    /// A rig holds at most this many lights.
    nonisolated static let maxLights = Int(PYMOL_LIGHTS_MAX)
    /// At most this many lights cast shadows: the core refuses a 4th
    /// (kLightRigMaxShadowed in layer1/LightRig.h). lighting_inspector.py
    /// checks it against lighting_commands.MAX_SHADOWS.
    nonisolated static let maxShadowed = 3

    /// A mirror older than this is re-read before an edit writes to it, so a
    /// gesture never writes to the light that used to be at the selected index.
    nonisolated static let staleAfter: TimeInterval = 1.0 / 60.0
    /// Continuous writes with the same key further apart than this are
    /// separate edits (#651): a slider released and dragged again.
    nonisolated static let editRunGap: TimeInterval = 0.5

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
    /// The air rows of the core's field table (#726): the Atmosphere card's
    /// ranges and defaults. Loaded with the presets at the first entry,
    /// retried at each entry while empty.
    @Published private(set) var airFields: [AirField] = []
    /// The air the Atmosphere card's Off put away, for its On (#726). Lives
    /// for one Lights-mode visit: `end()` drops it (Done, Esc, another mode,
    /// and a command that replaces the document, which ends the mode). Not
    /// published: it changes only with the rig, which is.
    private(set) var airMemory: LightRigSnapshot.Air?
    /// The rig's JSON when the mode was entered, for Revert: nil while not
    /// taken (inactive, or the engine was not ready yet), "null" for no rig.
    @Published private(set) var entryJSON: String?
    /// The rig the mode was entered with, decoded (nil for no rig): what a
    /// per-light "revert this light" compares against.
    private(set) var entryRig: LightRigSnapshot?
    /// The last write turned a light's shadow on and was refused: `maxShadowed`
    /// lights already cast one. The inspector shows a notice while it is set;
    /// the next edit, a selection change or leaving the mode clears it.
    @Published private(set) var shadowRefused = false
    /// Bumped once each time a direct-manipulation gesture begins on the
    /// selected light (`beginGesture()`), never per tick. The inspector's
    /// Orbit and Pitch fields observe it and drop typed text.
    @Published private(set) var gestureGeneration = 0
    /// Committed edits since the entry snapshot (#651): one per button action,
    /// one per gesture, and one per run of continuous writes to the same
    /// target and fields with no gap over `editRunGap` (a slider drag,
    /// quick repeated stepper presses on one field). Reset by begin(), end() and revert(). Revert asks for
    /// confirmation when it would drop more than one.
    @Published private(set) var editCount = 0

    /// The per-frame eye data (see LightsEyeState). Not @Published: a change
    /// in it must not re-render the controller's observers.
    let eye = LightsEyeState()
    /// Which lights are behind the molecule (see LightsFacingState). Not
    /// @Published, for the same reason as `eye`.
    let facing = LightsFacingState()
    /// What the tools need from eye space per rendered frame. The engine
    /// sets `.everyFrame` while Lights mode is on (#622's gizmo shows then);
    /// back to `.pinnedOnly` clears `eye.eyeSpace` and `eye.projection`.
    var eyeDemand: LightsEyeDemand = .pinnedOnly {
        didSet {
            if eyeDemand == .pinnedOnly {
                eye.publish(eyeSpace: nil)
                eye.publish(projection: nil)
            }
        }
    }

    private let seams: LightsSeams
    /// The JSON `rig` was decoded from, and whether there has been a read.
    private var mirrorJSON: String?
    private var hasMirror = false
    /// When the mirror was last read (`seams.now()`).
    private var lastRefresh: TimeInterval?
    /// `begin()` ran but the entry snapshot is still to be taken.
    private var needsSnapshot = false
    /// The coalescing key of the last counted edit (see `noteEdit`).
    private var lastEditKey: String?
    /// When the last counted or continued edit was written (`seams.now()`).
    private var lastEditTime: TimeInterval?
    /// `eye.placements` must be rebuilt on the next refresh even when the rig
    /// is unchanged (after `end()`, or an eye read that disagreed with it).
    private var eyeNeedsRebuild = true

    /// A camera light's eye-space placement may differ from its stored one
    /// by this much (float rounding) before the eye read counts as stale.
    nonisolated static let eyeDriftTolerance = 1e-3
    /// A placement must move by more than this to be republished per frame.
    nonisolated static let placementTolerance = 1e-4

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

    /// The selected light can be edited now (active, not busy, a selection).
    var canEdit: Bool { canAct && selection.index != nil }

    /// The selected light as it was when the mode was entered: the entry rig's
    /// light with the same name, ignoring case (nil when there is none).
    /// A light removed and added again under the same default name counts as
    /// the entry light.
    var entryLight: LightRigSnapshot.Light? {
        guard let name = (selectedLight?.name ?? selection.name)?.lowercased() else { return nil }
        return entryRig?.lights.first { $0.name.lowercased() == name }
    }

    /// Revert this light can do something: the selected light has an entry
    /// light and differs from it (stored fields; camera motion changes none).
    var canRevertLight: Bool {
        guard canAct, let light = selectedLight, let entry = entryLight else { return false }
        return light != entry
    }

    var canAdd: Bool { canAct && (rig?.lights.count ?? 0) < Self.maxLights }
    var canRemove: Bool { canAct && selection.index != nil }
    var canRecentre: Bool { canAct && hasLights }
    var canToggle: Bool { canAct && hasLights }
    /// The Atmosphere card's switch can be pressed: active, not busy, and
    /// the field table read (with no rig too: On creates one).
    var canToggleAir: Bool { canAct && !airFields.isEmpty }
    /// The Atmosphere card's rows can be edited: the switch can be pressed
    /// and there is a rig (the setter has nothing to write to otherwise).
    var canEditAir: Bool { canToggleAir && rig != nil }
    /// Something changed since the mode was entered.
    var canRevert: Bool {
        guard canAct, let entry = entryJSON else { return false }
        return (mirrorJSON ?? "null") != entry
    }

    /// Revert asks before dropping the edits: more than one would be lost.
    nonisolated static func revertNeedsConfirmation(editCount: Int) -> Bool { editCount > 1 }
    var revertNeedsConfirmation: Bool { Self.revertNeedsConfirmation(editCount: editCount) }
    /// The coalescing key of a direct-manipulation gesture's writes.
    var gestureEditKey: String { "gesture#\(gestureGeneration)" }

    /// The identity colour slot of the light called `name` (ignoring case).
    func identitySlot(for name: String) -> Int {
        identitySlots[name.lowercased()] ?? LightPalette.defaultSlot(for: name) ?? 0
    }

    /// The light called `name` (ignoring case) is behind the molecule now
    /// (`facing`; false while the mode is off).
    func isBehind(_ name: String) -> Bool { facing.isBehind(name) }

    // MARK: mode

    /// Lights mode was entered. Takes the entry snapshot (now, or on the first
    /// refresh once the engine is ready), loads the presets once, mirrors the
    /// rig and repairs the selection (the first light by default). Writes
    /// nothing: entering never creates a rig. A second call while active keeps
    /// the first snapshot.
    func begin() {
        guard !isActive else { return }
        isActive = true
        resetEdits()
        needsSnapshot = true
        refresh()
        repairSelection()
    }

    /// Lights mode was left (Done, Esc, another mode). Edits are kept; the
    /// entry snapshot and the Atmosphere switch's memory are dropped. The
    /// selection stays, repaired on the next `begin()`.
    func end() {
        if isActive { isActive = false }
        needsSnapshot = false
        resetEdits()
        if entryJSON != nil { entryJSON = nil }
        entryRig = nil
        airMemory = nil
        noteShadowRefused(false)
        eye.clear()
        facing.publish([])
        facing.publish(shadowSlots: [:])
        eyeNeedsRebuild = true
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
            resetEdits()
            entryJSON = json ?? "null"
            entryRig = json.flatMap(Self.decode)
            if presets.isEmpty {
                let loaded = seams.loadPresets()
                if !loaded.isEmpty { presets = loaded }
            }
            // The engine reads both tables in the presets' one Python call,
            // so on a first entry this is a cache hit.
            if airFields.isEmpty {
                let loaded = seams.loadAirFields()
                if !loaded.isEmpty { airFields = loaded }
            }
        }
        guard !hasMirror || json != mirrorJSON else {
            if eyeNeedsRebuild { rebuildEye() }
            return
        }
        hasMirror = true
        mirrorJSON = json
        let decoded = json.flatMap(Self.decode)
        if decoded != rig { rig = decoded }
        let names = decoded?.lights.map(\.name) ?? []
        let slots = LightPalette.assign(names: names, previous: identitySlots)
        if slots != identitySlots { identitySlots = slots }
        repairSelection()
        rebuildEye()
    }

    /// Re-read the rig unless the last read is younger than `staleAfter`:
    /// what every edit does before it writes, so a console or MCP change since
    /// the last read cannot send the write to the light that used to be at the
    /// selected index. During a drag each successful write re-reads, so this
    /// adds no read per tick.
    func refreshIfStale() {
        if let last = lastRefresh, seams.now() - last <= Self.staleAfter { return }
        refresh()
    }

    // MARK: eye data (per rendered frame)

    /// Called once per rendered frame in Lights mode. Refreshes
    /// `eye.placements` and `facing` (and, in `.everyFrame` demand,
    /// `eye.eyeSpace` and `eye.projection`) from one eye-space read, made
    /// only while a light is pinned or the demand is `.everyFrame`; otherwise
    /// it does nothing (no bridge call).
    ///
    /// The eye read carries no names, only rig order, so it is checked against
    /// the mirror first: a different light count, a different anchor, or a
    /// camera light whose placement differs from its stored one means the rig
    /// changed behind the mirror's back (the console, MCP), and the rig is
    /// re-read instead of publishing another light's numbers. (A reorder of
    /// two pinned lights that keeps the count and the anchors passes until the
    /// next poll.)
    func frameRendered() {
        guard isActive, !seams.isBusy(), seams.isReady() else { return }
        let lights = rig?.lights ?? []
        guard eyeDemand == .everyFrame || lights.contains(where: { $0.anchor == .pinned }) else {
            eye.publish(eyeSpace: nil)
            eye.publish(projection: nil)
            facing.publish(shadowSlots: [:])
            return
        }
        let read = seams.eyeSpace()
        guard Self.eye(read, isConsistentWith: rig) else {
            eyeNeedsRebuild = true
            facing.publish(shadowSlots: [:])
            refresh()
            return
        }
        let placements = Self.placements(of: lights, eye: read)
        eye.publish(placements, tolerance: Self.placementTolerance)
        publishFacing(lights, placements)
        publishShadowSlots(lights: lights, eye: read)
        // The projection goes with an eye-space read (none for no rig).
        let everyFrame = eyeDemand == .everyFrame && read != nil
        eye.publish(eyeSpace: everyFrame ? read : nil)
        eye.publish(projection: everyFrame ? seams.projection() : nil)
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

    // MARK: gestures

    /// A direct-manipulation gesture (#621's plan and pitch arc, #622's
    /// gizmo) begins on the selected light. Returns the gesture's owner, the
    /// selected light's lowercased name, which every tick then passes to
    /// `set(_:_:owner:)`, and bumps `gestureGeneration` so the inspector
    /// drops typed field text (a later Return cannot write it over the
    /// gesture's edit). nil, and nothing bumped, unless `canEdit`.
    func beginGesture() -> String? {
        guard canEdit, let name = selection.name else { return nil }
        gestureGeneration &+= 1
        return name.lowercased()
    }

    // MARK: actions (button presses)

    /// Place the selected light's highlight on the surface under scene NDC
    /// `sceneNDC` (#622's ⌥-click; #623's long-press): one `lights <name>,
    /// click=x/y` command (`rim=` when given, `pin=1` for a pinned light so
    /// it stays pinned). A click, never a drag tick. False, and nothing run,
    /// unless the selected light can be edited and the action is one the
    /// engine would run (a valid name, x and y in -1...1, a rim it accepts).
    @discardableResult
    func placeHighlight(sceneNDC: SIMD2<Double>, rim: Double?) -> Bool {
        guard canEdit else { return false }
        refreshIfStale()
        guard let light = selectedLight else { return false }
        let action = LightsAction.highlight(name: light.name, x: sceneNDC.x, y: sceneNDC.y,
                                            rim: rim, pin: light.anchor == .pinned)
        guard action.invocation != nil else { return false }
        seams.perform(action)
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
        return true
    }

    /// Add a light and select it.
    func add() {
        guard canAdd else { return }
        let before = Set((rig?.lights ?? []).map { $0.name.lowercased() })
        seams.perform(.add)
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
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
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
    }

    /// Apply the preset called `name` and select its first light.
    func applyPreset(_ name: String) {
        guard canAct else { return }
        seams.perform(.preset(name))
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
        select(index: 0)
    }

    /// Re-capture the rig's centre and 1x size from the molecules.
    func recentre() {
        guard canRecentre else { return }
        seams.perform(.recenter)
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
    }

    /// Turn the rig on or off.
    func setEnabled(_ on: Bool) {
        guard canToggle else { return }
        seams.perform(.setEnabled(on))
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
    }

    /// Put back the rig the mode was entered with. The mode stays open and the
    /// snapshot is kept, so Revert can be pressed again.
    func revert() {
        guard canAct, let entry = entryJSON else { return }
        seams.perform(.restore(entry))
        refresh()
        resetEdits()
    }

    /// Put back only the selected light as it was when the mode was entered
    /// (matched by name), leaving every other light and the rig's own fields
    /// as they are. The light stays selected. A refusal (a 4th shadowed
    /// light) changes nothing.
    func revertSelectedLight() {
        guard canRevertLight, let entry = entryJSON,
              let name = selectedLight?.name else { return }
        seams.perform(.restoreLight(name: name, json: entry))
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
    }

    /// The Atmosphere card's On/Off switch (#726), a button press: one
    /// echoed `atmosphere` command, never a drag tick.
    /// - Off remembers the air for this visit, then runs `atmosphere off`
    ///   (every air field back to its table default).
    /// - On runs `atmosphere f=v, ...` with `AtmosphereSwitch.onValues`: the
    ///   remembered air (fields changed since Off keep their value), or the
    ///   start look. With no rig it creates one, off and with no lights.
    /// Returns true when a command ran; false, and nothing run, unless
    /// `canToggleAir`, when the air already is `on`, or when there is
    /// nothing to send.
    @discardableResult
    func setAtmosphere(on: Bool) -> Bool {
        guard canToggleAir else { return false }
        refreshIfStale()
        guard on != airIsOn else { return false }
        if !on {
            airMemory = rig?.air
            seams.perform(.atmosphereOff)
            let mirrorBefore = mirrorJSON
            refresh()
            noteEdit(nil, ifChangedFrom: mirrorBefore)
            return true
        }
        let values = AtmosphereSwitch.onValues(current: rig?.air, memory: airMemory,
                                               fields: airFields)
        let action = LightsAction.setAir(values)
        guard !values.isEmpty, action.invocation != nil else { return false }
        seams.perform(action)
        let mirrorBefore = mirrorJSON
        refresh()
        noteEdit(nil, ifChangedFrom: mirrorBefore)
        return true
    }

    // MARK: continuous edits (bridge setters only)

    /// Set one number field of the selected light through the bridge setter
    /// (no Python): what a drag tick of #620-#622 calls. `.badIndex` when
    /// inactive, busy or nothing is selected.
    @discardableResult
    func edit(_ field: String, _ value: Double, editKey: String? = nil) -> LightSetResult {
        write(key: { editKey ?? "light:\($0):\(field)" }) { self.seams.setNumber($0, field, value) }
    }

    /// Set one vector field of the selected light through the bridge setter.
    @discardableResult
    func edit(_ field: String, _ vector: SIMD3<Double>, editKey: String? = nil) -> LightSetResult {
        write(key: { editKey ?? "light:\($0):\(field)" }) { self.seams.setVector($0, field, vector) }
    }

    /// Set several number fields of the selected light, in order, with the
    /// selected index fixed for the whole call: the multi-field form of
    /// `edit(_:_:)`. Stops at the first result that is not `.ok` and returns
    /// it; re-reads the mirror once if any write succeeded. `.badIndex` when
    /// inactive, busy or nothing is selected. A refused `shadow` write sets
    /// `shadowRefused`; any other write clears it.
    @discardableResult
    func writeNumbers(_ fields: [(String, Double)], editKey: String? = nil) -> LightSetResult {
        guard canAct, selection.index != nil else { return .badIndex }
        refreshIfStale()
        guard let index = selection.index else { return .badIndex }
        var result = LightSetResult.ok
        var wrote = false
        var refusedShadow = false
        for (field, value) in fields {
            result = seams.setNumber(index, field, value)
            guard result == .ok else {
                refusedShadow = result == .refused && field == "shadow"
                break
            }
            wrote = true
        }
        if wrote {
            let key = editKey ?? "light:\(index):" + fields.map(\.0).joined(separator: ",")
            let mirrorBefore = mirrorJSON
            refresh()
            noteEdit(key, ifChangedFrom: mirrorBefore)
        }
        noteShadowRefused(refusedShadow)
        return result
    }

    /// Set several number fields of the rig and its air (index -1), in
    /// order, through the bridge setter (no Python): what the Atmosphere
    /// card's slider ticks and typed values call (#726). Stops at the first
    /// result that is not `.ok` and returns it; re-reads the mirror once if
    /// any write succeeded. `.badIndex` when inactive or busy, `.noRig` with
    /// no rig. Leaves `shadowRefused` alone (that notice is about the
    /// selected light).
    @discardableResult
    func writeRigNumbers(_ fields: [(String, Double)], editKey: String? = nil) -> LightSetResult {
        guard canAct else { return .badIndex }
        refreshIfStale()
        guard rig != nil else { return .noRig }
        var result = LightSetResult.ok
        var wrote = false
        for (field, value) in fields {
            result = seams.setNumber(-1, field, value)
            guard result == .ok else { break }
            wrote = true
        }
        if wrote {
            let key = editKey ?? "rig:" + fields.map(\.0).joined(separator: ",")
            let mirrorBefore = mirrorJSON
            refresh()
            noteEdit(key, ifChangedFrom: mirrorBefore)
        }
        return result
    }

    /// Count one committed edit (#651). A non-nil `key` names the target and
    /// fields of a continuous write: the same key as the last edit continues
    /// that edit (a drag, a gesture). A nil key always counts and ends any run.
    /// A run of writes with the same key ends after `editRunGap` without a
    /// counted write, so two separate drags of one slider are two edits. A
    /// gesture's key is unique to that gesture and never times out.
    func noteEdit(_ key: String?) {
        let now = seams.now()
        defer { lastEditTime = now }
        if let key, key == lastEditKey,
           key.hasPrefix("gesture#") || now - (lastEditTime ?? now) <= Self.editRunGap {
            return
        }
        editCount += 1
        lastEditKey = key
    }

    /// `noteEdit(key)` only when the re-read mirror differs from `before`
    /// (the mirror JSON just before the re-read): a refused write (a 4th
    /// shadowed light) or one that changes nothing is not an edit.
    private func noteEdit(_ key: String?, ifChangedFrom before: String?) {
        guard mirrorJSON != before else { return }
        noteEdit(key)
    }

    // MARK: private

    private func resetEdits() {
        if editCount != 0 { editCount = 0 }
        lastEditKey = nil
        lastEditTime = nil
    }

    private func write(key: (Int) -> String, _ set: (Int) -> LightSetResult) -> LightSetResult {
        guard canAct, selection.index != nil else { return .badIndex }
        // A console or MCP change since the last read may have moved the
        // selected light: re-read first so the write lands on the light that
        // is selected now.
        refreshIfStale()
        guard let index = selection.index else { return .badIndex }
        let result = set(index)
        if result == .ok {
            let mirrorBefore = mirrorJSON
            refresh()
            noteEdit(key(index), ifChangedFrom: mirrorBefore)
        }
        noteShadowRefused(false)
        return result
    }

    private func noteShadowRefused(_ refused: Bool) {
        if shadowRefused != refused { shadowRefused = refused }
    }

    /// Rebuild `eye.placements` for the mirror just read (only while active).
    /// Reads eye space only while a light is pinned or the demand is
    /// `.everyFrame`, so an edit of a pinned light shows its new placement in
    /// the same turn; a read that disagrees with the mirror is not used.
    private func rebuildEye() {
        guard isActive else { return }
        eyeNeedsRebuild = false
        let lights = rig?.lights ?? []
        let needsRead = eyeDemand == .everyFrame || lights.contains { $0.anchor == .pinned }
        let read = needsRead ? seams.eyeSpace() : nil
        let usable = needsRead && Self.eye(read, isConsistentWith: rig)
        let placements = Self.placements(of: lights, eye: usable ? read : nil)
        eye.publish(placements, tolerance: 0)
        publishFacing(lights, placements)
        publishShadowSlots(lights: lights, eye: usable ? read : nil)
        let everyFrame = eyeDemand == .everyFrame && usable && read != nil
        eye.publish(eyeSpace: everyFrame ? read : nil)
        eye.publish(projection: everyFrame ? seams.projection() : nil)
    }

    /// Publish each light's shadow-map slot from `eye` (only when `eye` is
    /// non-nil and consistent with `lights`): only when the mapping changes (#673).
    private func publishShadowSlots(lights: [LightRigSnapshot.Light], eye: LightEyeSpace?) {
        guard let eye else {
            facing.publish(shadowSlots: [:])
            return
        }
        var slots: [String: Int] = [:]
        for (light, eyeLight) in zip(lights, eye.lights) {
            slots[light.name.lowercased()] = eyeLight.shadowSlot
        }
        facing.publish(shadowSlots: slots)
    }

    /// Publish which of `lights` are behind the molecule at `placements`
    /// (same order): only when the set changes.
    private func publishFacing(_ lights: [LightRigSnapshot.Light], _ placements: [LightPlacement]) {
        var behind = Set<String>()
        for (light, placement) in zip(lights, placements) where LightDepth.isBehind(placement) {
            behind.insert(light.name.lowercased())
        }
        facing.publish(behind)
    }

    /// Each light's current placement: a pinned light's from `eye` when
    /// given (it matches `lights`), otherwise the stored one.
    private static func placements(of lights: [LightRigSnapshot.Light],
                                   eye: LightEyeSpace?) -> [LightPlacement] {
        lights.enumerated().map { index, light in
            if light.anchor == .pinned, let eye, eye.lights.indices.contains(index) {
                return LightPlacement(eye.lights[index])
            }
            return light.placement
        }
    }

    /// `read` describes the same rig as `rig`: no read only for a rig with no
    /// lights; the same light count and anchors; and every camera light where
    /// its stored values put it (within `eyeDriftTolerance`).
    nonisolated static func eye(_ read: LightEyeSpace?,
                                isConsistentWith rig: LightRigSnapshot?) -> Bool {
        let lights = rig?.lights ?? []
        guard let read else { return lights.isEmpty }
        guard read.lights.count == lights.count else { return false }
        for (seen, light) in zip(read.lights, lights) {
            guard seen.anchor == light.anchor else { return false }
            if light.anchor == .camera,
               LightPlacement(seen).differs(from: light.placement, by: eyeDriftTolerance) {
                return false
            }
        }
        return true
    }

    private func repairSelection() {
        setSelection(LightSelection.repaired(selection, names: rig?.lights.map(\.name) ?? []))
    }

    private func setSelection(_ new: LightSelection) {
        guard new != selection else { return }
        selection = new
        // The refusal notice was about the light that was selected.
        noteShadowRefused(false)
    }

    private static func decode(_ json: String) -> LightRigSnapshot? {
        try? LightRigSnapshot.decode(Data(json.utf8))
    }
}
