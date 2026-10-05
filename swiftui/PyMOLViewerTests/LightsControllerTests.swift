import Combine
import XCTest
@testable import RayMol

/// The Lights mode model (#619): the shared selection's repair rules, the
/// identity colour slots, and LightsController on fake seams (no engine).
/// The engine wiring, the mode transitions and Revert on the live rig are in
/// LightsModeTests.

// MARK: - LightSelection

final class LightSelectionTests: XCTestCase {
    private func sel(_ name: String?, _ index: Int?) -> LightSelection {
        LightSelection(name: name, index: index)
    }

    func testEmptyRigHasNoSelection() {
        XCTAssertEqual(LightSelection.repaired(sel("key", 0), names: []), sel(nil, nil))
        XCTAssertEqual(LightSelection.repaired(sel(nil, nil), names: []), sel(nil, nil))
    }

    func testKeepsTheNameAtItsNewIndex() {
        // rim was at 2; key was removed in front of it.
        XCTAssertEqual(LightSelection.repaired(sel("rim", 2), names: ["fill", "rim"]),
                       sel("rim", 1))
        XCTAssertEqual(LightSelection.repaired(sel("fill", 1), names: ["key", "fill", "rim"]),
                       sel("fill", 1))
    }

    func testMatchesNamesIgnoringCase() {
        // The core's names are unique ignoring case; the rig's spelling wins.
        XCTAssertEqual(LightSelection.repaired(sel("FILL", 0), names: ["key", "Fill"]),
                       sel("Fill", 1))
    }

    func testRenameKeepsTheSlot() {
        XCTAssertEqual(LightSelection.repaired(sel("fill", 1), names: ["key", "bounce", "rim"]),
                       sel("bounce", 1))
    }

    func testRemovingTheSelectedPicksTheLightThatSlidIn() {
        XCTAssertEqual(LightSelection.repaired(sel("fill", 1), names: ["key", "rim"]),
                       sel("rim", 1))
    }

    func testRemovingTheLastPicksTheNewLast() {
        XCTAssertEqual(LightSelection.repaired(sel("rim", 2), names: ["key", "fill"]),
                       sel("fill", 1))
        XCTAssertEqual(LightSelection.repaired(sel("light6", 5), names: ["key"]),
                       sel("key", 0))
    }

    func testNoSelectionPicksTheFirst() {
        XCTAssertEqual(LightSelection.repaired(sel(nil, nil), names: ["key", "fill"]),
                       sel("key", 0))
        // A name that is gone with no index to fall back on.
        XCTAssertEqual(LightSelection.repaired(sel("gone", nil), names: ["left", "right"]),
                       sel("left", 0))
    }
}

// MARK: - LightPalette

final class LightPaletteTests: XCTestCase {
    private let threePoint = ["key": 0, "fill": 1, "rim": 2]

    func testDefaultNamesTakeTheirSlots() {
        let names = ["key", "fill", "rim", "light4", "light5", "light6"]
        XCTAssertEqual(names.map { LightPalette.defaultSlot(for: $0) }, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(LightPalette.defaultSlot(for: "KEY"), 0)
        XCTAssertNil(LightPalette.defaultSlot(for: "bounce"))
        XCTAssertNil(LightPalette.defaultSlot(for: "light7"))
        XCTAssertEqual(LightPalette.assign(names: names, previous: [:]),
                       ["key": 0, "fill": 1, "rim": 2, "light4": 3, "light5": 4, "light6": 5])
        // Rig order does not change a default name's slot.
        XCTAssertEqual(LightPalette.assign(names: ["rim", "key"], previous: [:]),
                       ["rim": 2, "key": 0])
    }

    func testRemovingKeepsTheOthersSlots() {
        XCTAssertEqual(LightPalette.assign(names: ["fill", "rim"], previous: threePoint),
                       ["fill": 1, "rim": 2])
    }

    func testNewNamesTakeTheLowestFreeSlot() {
        XCTAssertEqual(LightPalette.assign(names: ["fill", "rim", "bounce"], previous: ["fill": 1, "rim": 2]),
                       ["fill": 1, "rim": 2, "bounce": 0])
        // A default name claims its own slot before an unnamed one takes the
        // lowest free: key stays blue even after another light.
        XCTAssertEqual(LightPalette.assign(names: ["bounce", "key"], previous: [:]),
                       ["bounce": 1, "key": 0])
        // A default name whose slot is held by a known light takes the lowest free.
        XCTAssertEqual(LightPalette.assign(names: ["bounce", "fill"], previous: ["bounce": 1]),
                       ["bounce": 1, "fill": 0])
    }

    func testPresetReplacementReassignsFromZero() {
        XCTAssertEqual(LightPalette.assign(names: ["left", "right", "top"], previous: threePoint),
                       ["left": 0, "right": 1, "top": 2])
        XCTAssertEqual(LightPalette.assign(names: ["spot", "bounce"], previous: ["left": 0, "right": 1, "top": 2]),
                       ["spot": 0, "bounce": 1])
        // A name both rigs share keeps its colour.
        XCTAssertEqual(LightPalette.assign(names: ["under", "rim"], previous: threePoint),
                       ["under": 0, "rim": 2])
    }

    func testSixLightsAreDistinct() {
        let names = ["a", "Fill", "c", "light5", "e", "f"]
        let slots = LightPalette.assign(names: names, previous: [:])
        XCTAssertEqual(slots.count, 6)
        XCTAssertEqual(Set(slots.values), Set(0..<LightPalette.count))
        XCTAssertEqual(slots["fill"], 1)
        XCTAssertEqual(slots["light5"], 4)
        // Keys are lowercased names.
        XCTAssertNil(slots["Fill"])
    }

    func testRenameUsuallyKeepsTheSlot() {
        XCTAssertEqual(LightPalette.assign(names: ["key", "bounce", "rim"], previous: threePoint),
                       ["key": 0, "bounce": 1, "rim": 2])
        // Renaming the key: blue is the lowest free slot.
        XCTAssertEqual(LightPalette.assign(names: ["sun", "fill", "rim"], previous: threePoint),
                       ["sun": 0, "fill": 1, "rim": 2])
    }

    func testBadPreviousSlotsAreIgnored() {
        // Out of range, or two names claiming one slot: the later one is new.
        XCTAssertEqual(LightPalette.assign(names: ["a", "b", "c"], previous: ["a": 9, "b": 1, "c": 1]),
                       ["a": 0, "b": 1, "c": 2])
    }
}

// MARK: - fakes

/// A fake rig store: what the core would hold, written out as the full v1 JSON
/// (every key LightRigToJSON writes), so LightRigSnapshot decodes it. The
/// actions do what #612's `lights` command does to the names and the switch.
final class FakeRigStore {
    struct Light: Equatable {
        var name: String
        var orbit = 0.0
        var color = SIMD3<Double>(1, 1, 1)
    }

    var exists = false
    var enabled = false
    var centreX = 0.0
    var lights: [Light] = []

    var ready = true
    var busy = false
    var clock: TimeInterval = 1000

    private(set) var performed: [LightsAction] = []
    private(set) var numberWrites: [(index: Int, field: String, value: Double)] = []
    private(set) var vectorWrites: [(index: Int, field: String, value: SIMD3<Double>)] = []
    private(set) var reads = 0
    private(set) var presetLoads = 0
    var presetList: [LightPreset] = [
        LightPreset(name: "three_point", description: "Classic portrait"),
        LightPreset(name: "softbox", description: "Product shot"),
    ]

    static let presetLights = [
        "three_point": ["key", "fill", "rim"],
        "softbox": ["left", "right", "top"],
        "spotlight": ["spot", "bounce"],
    ]

    var names: [String] { lights.map(\.name) }

    /// A rig with these lights (on).
    func setRig(_ names: [String], enabled: Bool = true) {
        exists = true
        self.enabled = enabled
        lights = names.map { Light(name: $0) }
    }

    func removeLight(_ name: String) {
        lights.removeAll { $0.name.lowercased() == name.lowercased() }
        if lights.isEmpty { enabled = false }
    }

    private static func num(_ x: Double) -> String { String(describing: x) }
    private static func vec(_ v: SIMD3<Double>) -> String { "[\(num(v.x)),\(num(v.y)),\(num(v.z))]" }

    var json: String? {
        guard exists else { return nil }
        let lightsJSON = lights.map { light in
            "{\"name\":\"\(light.name)\",\"anchor\":\"camera\",\"orbit\":\(Self.num(light.orbit)),"
            + "\"pitch\":30.0,\"radius\":4.0,\"position\":[0.0,0.0,0.0],\"aim\":\"centre\","
            + "\"aim_point\":[0.0,0.0,0.0],\"aim_selection\":\"\",\"beam\":45.0,\"softness\":0.4,"
            + "\"color\":\(Self.vec(light.color)),\"warmth\":6500.0,\"intensity\":1.0,\"highlight\":0.5,"
            + "\"falloff\":2.0,\"shadow\":false,\"outline\":false}"
        }.joined(separator: ",")
        let frame = lights.isEmpty ? "\"centre\":null,\"size\":null"
            : "\"centre\":[\(Self.num(centreX)),0.0,0.0],\"size\":10.0"
        return "{\"version\":1,\"enabled\":\(enabled),\(frame),\"ambient\":0.05,\"classic\":0.0,"
            + "\"air\":{\"haze\":0.0,\"dust\":0.0,\"dust_size\":0.35,\"dust_speed\":1.0,\"scatter\":0.55,\"seed\":0},"
            + "\"lights\":[\(lightsJSON)]}"
    }

    /// The core's next default name (LightRigNextName).
    private func nextName() -> String {
        let taken = Set(names.map { $0.lowercased() })
        for name in ["key", "fill", "rim"] where !taken.contains(name) { return name }
        var i = 4
        while taken.contains("light\(i)") { i += 1 }
        return "light\(i)"
    }

    func perform(_ action: LightsAction) {
        performed.append(action)
        switch action {
        case .add:
            guard lights.count < 6 else { return }
            if !exists { exists = true }
            if lights.isEmpty { enabled = true }   // the first light turns the rig on
            lights.append(Light(name: nextName()))
        case .remove(let name):
            removeLight(name)
        case .preset(let preset):
            guard let names = Self.presetLights[preset] else { return }
            setRig(names)
        case .recenter:
            guard exists, !lights.isEmpty else { return }
            centreX += 10
        case .setEnabled(let on):
            guard exists, !lights.isEmpty else { return }
            enabled = on
        case .restore(let json):
            if json == "null" {
                exists = false
                enabled = false
                lights = []
                return
            }
            guard let rig = try? LightRigSnapshot.decode(Data(json.utf8)) else { return }
            exists = true
            enabled = rig.enabled
            centreX = rig.centre?.x ?? 0
            lights = rig.lights.map { Light(name: $0.name, orbit: $0.orbit, color: $0.color) }
        }
    }

    var seams: LightsSeams {
        LightsSeams(
            rigJSON: {
                self.reads += 1
                return self.json
            },
            setNumber: { index, field, value in
                self.numberWrites.append((index, field, value))
                guard self.ready, self.exists else { return .noRig }
                guard self.lights.indices.contains(index) else { return .badIndex }
                guard field == "orbit" else { return .unknownField }
                self.lights[index].orbit = value
                return .ok
            },
            setVector: { index, field, value in
                self.vectorWrites.append((index, field, value))
                guard self.ready, self.exists else { return .noRig }
                guard self.lights.indices.contains(index) else { return .badIndex }
                guard field == "color" else { return .unknownField }
                self.lights[index].color = value
                return .ok
            },
            perform: { self.perform($0) },
            loadPresets: {
                self.presetLoads += 1
                return self.presetList
            },
            isReady: { self.ready },
            isBusy: { self.busy },
            now: { self.clock })
    }
}

// MARK: - LightsController

@MainActor
final class LightsControllerTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private var names: [String] { controller.rig?.lights.map(\.name) ?? [] }

    private func begin(with lights: [String]?) {
        if let lights { store.setRig(lights) }
        controller.begin()
    }

    func testBeginSnapshotsAndSelectsFirst() {
        begin(with: ["key", "fill", "rim"])
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.entryJSON, store.json)
        XCTAssertEqual(controller.entryRig?.lights.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(controller.rig, controller.entryRig)
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        XCTAssertEqual(controller.selectedLight?.name, "key")
        XCTAssertEqual(controller.identitySlots, ["key": 0, "fill": 1, "rim": 2])
        XCTAssertEqual(controller.presets.map(\.name), ["three_point", "softbox"])
        XCTAssertTrue(controller.hasLights)
        XCTAssertTrue(controller.isOn)
        XCTAssertFalse(controller.canRevert)

        // A second begin while active keeps the first snapshot.
        let entry = controller.entryJSON
        store.lights[0].orbit = 12
        controller.begin()
        XCTAssertEqual(controller.entryJSON, entry)
        XCTAssertEqual(store.presetLoads, 1)
    }

    func testBeginWithNoRigSnapshotsNullAndWritesNothing() {
        begin(with: nil)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.entryJSON, "null")
        XCTAssertNil(controller.entryRig)
        XCTAssertNil(controller.rig)
        XCTAssertEqual(controller.selection, LightSelection())
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)
        XCTAssertFalse(store.exists, "entering must not create a rig")
        XCTAssertTrue(controller.canAdd)
        XCTAssertFalse(controller.canRemove)
        XCTAssertFalse(controller.canRecentre)
        XCTAssertFalse(controller.canToggle)
        XCTAssertFalse(controller.canRevert)
    }

    func testAddSelectsTheNewLight() {
        begin(with: ["key", "rim"])
        controller.add()
        XCTAssertEqual(store.performed, [.add])
        XCTAssertEqual(names, ["key", "rim", "fill"])
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 2))
        XCTAssertEqual(controller.identitySlot(for: "fill"), 1)
        XCTAssertTrue(controller.canRevert)

        // From no rig: the first light is created and selected.
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        controller.begin()
        controller.add()
        XCTAssertEqual(names, ["key"])
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        XCTAssertTrue(controller.isOn)
    }

    func testAddDisabledAtSix() {
        begin(with: ["key", "fill", "rim", "light4", "light5"])
        XCTAssertTrue(controller.canAdd)
        controller.add()
        XCTAssertEqual(names.count, LightsController.maxLights)
        XCTAssertEqual(controller.selection, LightSelection(name: "light6", index: 5))
        XCTAssertFalse(controller.canAdd)
        controller.add()
        XCTAssertEqual(store.performed, [.add], "a 7th add must not be sent")
        XCTAssertEqual(Set(controller.identitySlots.values), Set(0..<LightPalette.count))
    }

    func testRemoveSelectsNeighbour() {
        begin(with: ["key", "fill", "rim"])
        controller.select(index: 1)
        controller.removeSelected()
        XCTAssertEqual(store.performed, [.remove("fill")])
        XCTAssertEqual(names, ["key", "rim"])
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 1))
        // Removing never recolours the others.
        XCTAssertEqual(controller.identitySlots, ["key": 0, "rim": 2])

        // The last one: the new last is selected.
        controller.removeSelected()
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        // The only one: an empty, off rig; nothing selected or removable.
        controller.removeSelected()
        XCTAssertEqual(store.performed, [.remove("fill"), .remove("rim"), .remove("key")])
        XCTAssertEqual(controller.selection, LightSelection())
        XCTAssertFalse(controller.hasLights)
        XCTAssertFalse(controller.isOn)
        XCTAssertFalse(controller.canRemove)
        controller.removeSelected()
        XCTAssertEqual(store.performed.count, 3)
    }

    func testPresetSelectsFirstAndEnablesRevert() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "rim")
        controller.applyPreset("softbox")
        XCTAssertEqual(store.performed, [.preset("softbox")])
        XCTAssertEqual(names, ["left", "right", "top"])
        XCTAssertEqual(controller.selection, LightSelection(name: "left", index: 0))
        XCTAssertEqual(controller.identitySlots, ["left": 0, "right": 1, "top": 2])
        XCTAssertTrue(controller.canRevert)
    }

    func testPowerTogglePerformsSetEnabled() {
        begin(with: ["key", "fill", "rim"])
        XCTAssertTrue(controller.canToggle)
        controller.setEnabled(false)
        XCTAssertEqual(store.performed, [.setEnabled(false)])
        XCTAssertFalse(controller.isOn)
        XCTAssertTrue(controller.canToggle, "an off rig must have a way back on")
        controller.setEnabled(true)
        XCTAssertTrue(controller.isOn)
        XCTAssertEqual(store.performed, [.setEnabled(false), .setEnabled(true)])

        // No lights: disabled, and a press sends nothing.
        controller.end()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        controller.begin()
        XCTAssertFalse(controller.canToggle)
        controller.setEnabled(true)
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testRecentrePerformsRecenter() {
        begin(with: ["key"])
        let before = controller.rig?.centre
        controller.recentre()
        XCTAssertEqual(store.performed, [.recenter])
        XCTAssertNotEqual(controller.rig?.centre, before)
        XCTAssertTrue(controller.canRevert)
    }

    func testRevertPerformsRestoreOfEntry() throws {
        begin(with: ["key", "fill", "rim"])
        let entry = try XCTUnwrap(controller.entryJSON)
        controller.select(name: "rim")
        controller.edit("orbit", 40)
        controller.add()
        controller.setEnabled(false)
        XCTAssertTrue(controller.canRevert)
        controller.revert()
        XCTAssertEqual(store.performed.last, .restore(entry))
        XCTAssertEqual(store.json, entry)
        XCTAssertEqual(names, ["key", "fill", "rim"])
        XCTAssertFalse(controller.canRevert)
        XCTAssertTrue(controller.isActive, "Revert keeps the mode open")
        XCTAssertEqual(controller.entryJSON, entry, "and the snapshot, so it can be pressed again")
        // The added light4 is gone: the selection is repaired onto the rig.
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 2))

        // Entered with no rig: Revert sends "null" and the rig is gone again.
        controller.end()
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        controller.begin()
        controller.add()
        controller.revert()
        XCTAssertEqual(store.performed, [.add, .restore("null")])
        XCTAssertFalse(store.exists)
        XCTAssertNil(controller.rig)
        XCTAssertEqual(controller.selection, LightSelection())
        XCTAssertFalse(controller.canRevert)
    }

    func testRevertDisabledWhenUnchanged() {
        begin(with: ["key", "fill", "rim"])
        XCTAssertFalse(controller.canRevert)
        XCTAssertEqual(controller.edit("orbit", 25), .ok)
        XCTAssertTrue(controller.canRevert)
        XCTAssertEqual(controller.edit("orbit", 0), .ok)
        XCTAssertFalse(controller.canRevert, "back to the entry rig byte for byte")
    }

    func testEndDropsSnapshotAndActionsAreNoOps() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        controller.end()
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.entryJSON)
        XCTAssertNil(controller.entryRig)
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1),
                       "the selection survives Done")
        XCTAssertFalse(controller.canAdd)
        XCTAssertFalse(controller.canRemove)
        XCTAssertFalse(controller.canRecentre)
        XCTAssertFalse(controller.canToggle)
        XCTAssertFalse(controller.canRevert)

        controller.add()
        controller.removeSelected()
        controller.applyPreset("softbox")
        controller.recentre()
        controller.setEnabled(false)
        controller.revert()
        XCTAssertEqual(controller.edit("orbit", 10), .badIndex)
        XCTAssertEqual(controller.edit("color", SIMD3(1, 0, 0)), .badIndex)
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)

        // Re-entering takes a new snapshot and repairs the kept selection.
        store.removeLight("fill")
        controller.begin()
        XCTAssertEqual(controller.entryJSON, store.json)
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 1))
    }

    func testEditsUseOnlyTheBridge() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        let readsBefore = store.reads
        for tick in 0..<100 {
            XCTAssertEqual(controller.edit("orbit", Double(tick)), .ok)
        }
        XCTAssertEqual(store.numberWrites.count, 100)
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.index == 1 && $0.field == "orbit" })
        XCTAssertTrue(store.performed.isEmpty, "a drag tick must not run a command or Python")
        XCTAssertEqual(store.presetLoads, 1)
        // One mirror read per tick (after the write), none before it while fresh.
        XCTAssertEqual(store.reads - readsBefore, 100)
        XCTAssertEqual(controller.selectedLight?.orbit, 99)

        XCTAssertEqual(controller.edit("color", SIMD3(1, 0, 0)), .ok)
        XCTAssertEqual(store.vectorWrites.count, 1)
        XCTAssertEqual(controller.selectedLight?.color, SIMD3(1, 0, 0))
        XCTAssertTrue(store.performed.isEmpty)

        // A refused write is returned as is and changes nothing.
        let json = store.json
        XCTAssertEqual(controller.edit("beam", 10), .unknownField)
        XCTAssertEqual(store.json, json)
    }

    func testEditWithoutSelectionIsRefused() {
        // Inactive.
        store.setRig(["key"])
        controller.refresh()
        XCTAssertEqual(controller.edit("orbit", 10), .badIndex)
        // Active with no rig: nothing to select.
        store = FakeRigStore()
        controller = LightsController(seams: store.seams)
        controller.begin()
        XCTAssertEqual(controller.edit("orbit", 10), .badIndex)
        XCTAssertEqual(controller.edit("color", SIMD3(1, 0, 0)), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)
    }

    func testEditRefreshesAStaleMirrorFirst() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        // The console removes key; the mirror still has fill at index 1.
        store.removeLight("key")
        store.clock += 1
        XCTAssertEqual(controller.edit("orbit", 30), .ok)
        XCTAssertEqual(store.numberWrites.map { $0.index }, [0], "the write must land on fill, now at 0")
        XCTAssertEqual(store.lights.map(\.orbit), [30, 0])
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 0))

        // Within 1/60 s the mirror counts as fresh: no read before the write.
        let reads = store.reads
        store.clock += LightsController.staleAfter / 2
        XCTAssertEqual(controller.edit("orbit", 31), .ok)
        XCTAssertEqual(store.reads - reads, 1)

        // The selected light went away while stale: the re-read repairs the
        // selection and the write goes to the light selected now.
        store.removeLight("fill")
        store.clock += 1
        XCTAssertEqual(controller.edit("orbit", 5), .ok)
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 0))
        XCTAssertEqual(store.lights.map(\.orbit), [5])

        // Every light went away: refused, nothing written.
        store.removeLight("rim")
        store.clock += 1
        let writes = store.numberWrites.count
        XCTAssertEqual(controller.edit("orbit", 6), .badIndex)
        XCTAssertEqual(store.numberWrites.count, writes)
    }

    func testRefreshPublishesOnlyOnChange() {
        begin(with: ["key", "fill", "rim"])
        var changes = 0
        let sink = controller.objectWillChange.sink { changes += 1 }
        defer { sink.cancel() }
        for _ in 0..<10 { controller.refresh() }
        XCTAssertEqual(changes, 0, "an unchanged rig must not publish")
        XCTAssertEqual(store.reads, 11)

        store.lights[1].orbit = 15
        controller.refresh()
        XCTAssertGreaterThan(changes, 0)
        let after = changes
        controller.refresh()
        XCTAssertEqual(changes, after)

        // Selecting the selected light publishes nothing either.
        controller.select(index: 0)
        XCTAssertEqual(changes, after)
        controller.select(index: 2)
        XCTAssertGreaterThan(changes, after)
    }

    func testBusyBlocksActionsEditsAndRefresh() {
        begin(with: ["key", "fill", "rim"])
        store.busy = true
        XCTAssertTrue(controller.isBusy)
        XCTAssertFalse(controller.canAdd)
        XCTAssertFalse(controller.canRemove)
        XCTAssertFalse(controller.canRecentre)
        XCTAssertFalse(controller.canToggle)
        XCTAssertFalse(controller.canRevert)

        let reads = store.reads
        controller.add()
        controller.removeSelected()
        controller.applyPreset("softbox")
        controller.recentre()
        controller.setEnabled(false)
        controller.revert()
        XCTAssertEqual(controller.edit("orbit", 10), .badIndex)
        XCTAssertEqual(controller.edit("color", SIMD3(1, 0, 0)), .badIndex)
        store.removeLight("key")
        controller.refresh()
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)
        XCTAssertEqual(store.reads, reads, "the rig must not be read while busy")
        XCTAssertEqual(names, ["key", "fill", "rim"])

        store.busy = false
        controller.refresh()
        XCTAssertEqual(names, ["fill", "rim"])
    }

    func testExternalRenameAndRemoveRepairSelection() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        store.lights[1].name = "bounce"
        controller.refresh()
        XCTAssertEqual(controller.selection, LightSelection(name: "bounce", index: 1))
        XCTAssertEqual(controller.identitySlot(for: "bounce"), 1, "a rename keeps the colour")
        XCTAssertEqual(controller.identitySlot(for: "BOUNCE"), 1)

        store.removeLight("bounce")
        controller.refresh()
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 1))
        XCTAssertEqual(controller.identitySlots, ["key": 0, "rim": 2])

        // The rig removed from outside: nothing selected, no slots.
        store.exists = false
        store.lights = []
        controller.refresh()
        XCTAssertNil(controller.rig)
        XCTAssertEqual(controller.selection, LightSelection())
        XCTAssertEqual(controller.identitySlots, [:])
        XCTAssertTrue(controller.canRevert)
    }

    func testSelectByIndexAndName() {
        begin(with: ["key", "fill", "rim"])
        controller.select(index: 2)
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 2))
        controller.select(name: "FILL")
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1))
        controller.select(index: 3)
        controller.select(index: -1)
        controller.select(name: "nope")
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1))
        XCTAssertEqual(controller.selectedIndex, 1)
    }

    func testSnapshotTakenOnFirstReadyRefresh() {
        store.ready = false
        store.presetList = []
        controller.begin()
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(controller.entryJSON, "no snapshot before the engine is ready")
        XCTAssertFalse(controller.canRevert)
        XCTAssertEqual(store.reads, 0)

        store.setRig(["key", "fill"])
        store.ready = true
        controller.refresh()
        XCTAssertEqual(controller.entryJSON, store.json)
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        XCTAssertEqual(store.presetLoads, 1)
        XCTAssertTrue(controller.presets.isEmpty)

        // Later refreshes keep it.
        let entry = controller.entryJSON
        store.removeLight("fill")
        controller.refresh()
        XCTAssertEqual(controller.entryJSON, entry)
        XCTAssertTrue(controller.canRevert)

        // An empty preset list is retried on the next entry, then cached.
        store.presetList = [LightPreset(name: "softbox", description: "d")]
        controller.end()
        controller.begin()
        XCTAssertEqual(controller.presets.map(\.name), ["softbox"])
        controller.end()
        controller.begin()
        XCTAssertEqual(store.presetLoads, 2)
    }

    func testPresetsDecodeFromHelperFormat() throws {
        // What pymol.appkit_lights.write_presets writes (lighting_mode.py
        // TestPresets pins the Python side).
        let json = """
            [{"name": "three_point", "description": "Classic portrait: warm key with shadow, cool fill, white rim"},
             {"name": "softbox", "description": "Product shot: two big soft white boxes, gentle top light"}]
            """
        let presets = try LightPreset.decodeList(Data(json.utf8))
        XCTAssertEqual(presets.map(\.name), ["three_point", "softbox"])
        XCTAssertEqual(presets[0].description,
                       "Classic portrait: warm key with shadow, cool fill, white rim")
        XCTAssertEqual(presets[1].id, "softbox")
        XCTAssertEqual(try LightPreset.decodeList(Data("[]".utf8)), [])
        XCTAssertThrowsError(try LightPreset.decodeList(Data("[[\"softbox\", \"d\"]]".utf8)))
    }

    func testPresetDisplayNames() {
        func display(_ name: String) -> String {
            LightPreset(name: name, description: "").displayName
        }
        XCTAssertEqual(display("three_point"), "Three point")
        XCTAssertEqual(display("softbox"), "Softbox")
        XCTAssertEqual(display("underlight"), "Underlight")
        XCTAssertEqual(display(""), "")
    }
}
