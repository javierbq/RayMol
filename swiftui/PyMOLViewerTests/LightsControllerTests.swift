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
/// actions do what #612's `lights` command does to the names and the switch,
/// and the setters what LightRigSet does (layer1/LightRig.h): the core's
/// clamps, the orbit wrap, anchor 0/1, re-pinning a pinned light's placement
/// and the 3-shadow cap. Eye space is served from the stored values for
/// camera lights and from `eyePlacements` for pinned ones (a test moves a
/// pinned light's eye placement to stand for a camera turn). Setting
/// `eyeOffset` opts into a faithful eye space (#622): positions, targets,
/// directions, aim distances and the cone as LightRigResolve computes them,
/// under a camera that only translates the world by that offset.
final class FakeRigStore {
    struct Light: Equatable {
        var name: String
        var orbit = 0.0
        var color = SIMD3<Double>(1, 1, 1)
        var pinned = false
        var pitch = 30.0
        var radius = 4.0
        var beam = 45.0
        var softness = 0.4
        var warmth = 6500.0
        var intensity = 1.0
        var shadow = false
        /// The world point the light aims at (`aim_point`); nil: the centre.
        var aimPoint: SIMD3<Double>?

        var placement: LightPlacement {
            get { LightPlacement(orbit: orbit, pitch: pitch, radius: radius) }
            set {
                orbit = newValue.orbit
                pitch = newValue.pitch
                radius = newValue.radius
            }
        }
    }

    /// The core's ranges (layer1/LightRig.cpp) and its shadow cap.
    static let ranges: [String: ClosedRange<Double>] = [
        "pitch": -90...90, "radius": 0.5...8, "beam": 1...170, "softness": 0...1,
        "warmth": 1500...15000, "intensity": 0...4,
    ]
    static let maxShadowed = 3

    /// The air rows of the core's field table (layer1/LightRig.cpp), as
    /// appkit_lights.write_air_fields gives them (#726).
    static let airTable: [AirField] = {
        let json = #"[{"name": "haze", "kind": "float", "default": 0.0, "min": 0.0, "max": 1.0}, "#
            + #"{"name": "dust", "kind": "float", "default": 0.0, "min": 0.0, "max": 1.0}, "#
            + #"{"name": "dust_size", "kind": "float", "default": 0.35, "min": 0.05, "max": 2.0}, "#
            + #"{"name": "dust_speed", "kind": "float", "default": 1.0, "min": 0.0, "max": 10.0}, "#
            + #"{"name": "scatter", "kind": "float", "default": 0.55, "min": -0.9, "max": 0.9}, "#
            + #"{"name": "seed", "kind": "int", "default": 0, "min": 0, "max": 1000000}]"#
        return try! AirField.decodeList(Data(json.utf8))
    }()
    /// The core's default air (LightAir in layer1/LightRig.h).
    static let defaultAir = LightRigSnapshot.Air(haze: 0, dust: 0, dustSize: 0.35, dustSpeed: 1,
                                                 scatter: 0.55, seed: 0)

    var exists = false
    var enabled = false
    var centreX = 0.0
    var lights: [Light] = []
    /// The rig's air: presets and `lights off` keep it; `atmosphere off`, a
    /// restore and the setters at index -1 change it.
    var air = FakeRigStore.defaultAir

    var ready = true
    var busy = false
    var clock: TimeInterval = 1000

    /// A pinned light's current placement in eye space, by lowercased name
    /// (absent: its stored placement).
    var eyePlacements: [String: LightPlacement] = [:]
    /// When set, `eyeSpace` serves this instead (`.some(nil)`: no rig), for a
    /// stale or mismatched read.
    var eyeOverride: LightEyeSpace?? = .none
    /// Opt-in faithful eye space: world to eye is `+ eyeOffset` (nil: the
    /// placeholder positions every test before #622 uses).
    var eyeOffset: SIMD3<Double>?
    /// What the projection seam serves (the gizmo's camera).
    var projection: LightCameraProjection?
    private(set) var projectionReads = 0
    /// Per-light shadow slots in `eyeSpace` (defaults to -1 for each light) (#673).
    var shadowSlots: [Int]?
    /// Run after every number write (before it returns): a test can change
    /// things in the middle of a multi-field write.
    var afterNumberWrite: (() -> Void)?

    private(set) var performed: [LightsAction] = []
    private(set) var numberWrites: [(index: Int, field: String, value: Double)] = []
    private(set) var vectorWrites: [(index: Int, field: String, value: SIMD3<Double>)] = []
    private(set) var reads = 0
    private(set) var eyeReads = 0
    private(set) var presetLoads = 0
    /// What the air-field seam serves, and how often it was asked.
    var airFieldList: [AirField] = FakeRigStore.airTable
    private(set) var airFieldLoads = 0
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
        eyePlacements = [:]
        shadowSlots = nil
    }

    func removeLight(_ name: String) {
        lights.removeAll { $0.name.lowercased() == name.lowercased() }
        eyePlacements[name.lowercased()] = nil
        if lights.isEmpty { enabled = false }
    }

    /// Light `index`'s current placement (eye space for a pinned light).
    func currentPlacement(_ index: Int) -> LightPlacement {
        let light = lights[index]
        guard light.pinned else { return light.placement }
        return eyePlacements[light.name.lowercased()] ?? light.placement
    }

    private static func num(_ x: Double) -> String { String(describing: x) }
    private static func vec(_ v: SIMD3<Double>) -> String { "[\(num(v.x)),\(num(v.y)),\(num(v.z))]" }

    var json: String? {
        guard exists else { return nil }
        let lightsJSON = lights.map { light in
            "{\"name\":\"\(light.name)\",\"anchor\":\"\(light.pinned ? "pinned" : "camera")\","
            + "\"orbit\":\(Self.num(light.orbit)),\"pitch\":\(Self.num(light.pitch)),"
            + "\"radius\":\(Self.num(light.radius)),\"position\":[0.0,0.0,0.0],"
            + "\"aim\":\"\(light.aimPoint == nil ? "centre" : "point")\","
            + "\"aim_point\":\(Self.vec(light.aimPoint ?? .zero)),\"aim_selection\":\"\","
            + "\"beam\":\(Self.num(light.beam)),"
            + "\"softness\":\(Self.num(light.softness)),\"color\":\(Self.vec(light.color)),"
            + "\"warmth\":\(Self.num(light.warmth)),\"intensity\":\(Self.num(light.intensity)),"
            + "\"highlight\":0.5,\"falloff\":2.0,\"shadow\":\(light.shadow),\"outline\":false}"
        }.joined(separator: ",")
        let frame = lights.isEmpty ? "\"centre\":null,\"size\":null"
            : "\"centre\":[\(Self.num(centreX)),0.0,0.0],\"size\":10.0"
        return "{\"version\":1,\"enabled\":\(enabled),\(frame),\"ambient\":0.05,\"classic\":0.0,"
            + "\"air\":{\"haze\":\(Self.num(air.haze)),\"dust\":\(Self.num(air.dust)),"
            + "\"dust_size\":\(Self.num(air.dustSize)),\"dust_speed\":\(Self.num(air.dustSpeed)),"
            + "\"scatter\":\(Self.num(air.scatter)),\"seed\":\(air.seed)},"
            + "\"lights\":[\(lightsJSON)]}"
    }

    /// The rig in eye space, as PyMOLBridge_LightsEyeSpace resolves it (only
    /// the fields the controller reads are meaningful).
    var eyeSpace: LightEyeSpace? {
        guard ready, exists else { return nil }
        if let eyeOffset { return faithfulEyeSpace(eyeOffset) }
        return LightEyeSpace(
            enabled: enabled, hasFrame: !lights.isEmpty,
            centre: SIMD3(Float(centreX), 0, 0), size: 10,
            lights: lights.indices.map { index in
                let light = lights[index]
                let place = currentPlacement(index)
                let cosOuter = Float(cos(light.beam / 2 * .pi / 180))
                let slot = shadowSlots?.indices.contains(index) == true ? shadowSlots![index] : -1
                return LightEyeSpace.Light(
                    position: .zero, target: .zero, direction: SIMD3(0, 0, -1),
                    aimDistance: Float(place.radius * 10),
                    cosOuter: cosOuter, cosInner: min(1, cosOuter + 0.01),
                    orbit: Float(place.orbit), pitch: Float(place.pitch),
                    radius: Float(place.radius),
                    anchor: light.pinned ? .pinned : .camera, aim: .centre,
                    shadow: light.shadow, outline: false,
                    shadowSlot: slot)
            })
    }

    /// The rig size the JSON gives (Å).
    static let size = 10.0

    /// The unit offset of (orbit, pitch) from the centre in eye space
    /// (spec §4.3): (sin o cos p, sin p, cos o cos p).
    static func unitOffset(_ place: LightPlacement) -> SIMD3<Double> {
        let o = place.orbit * .pi / 180, p = place.pitch * .pi / 180
        return SIMD3(sin(o) * cos(p), sin(p), cos(o) * cos(p))
    }

    /// LightRigResolve under a camera that translates the world by `offset`.
    private func faithfulEyeSpace(_ offset: SIMD3<Double>) -> LightEyeSpace {
        let centre = SIMD3(centreX, 0, 0) + offset
        func float3(_ v: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
        return LightEyeSpace(
            enabled: enabled, hasFrame: !lights.isEmpty,
            centre: float3(centre), size: Float(Self.size),
            lights: lights.indices.map { index in
                let light = lights[index]
                let place = currentPlacement(index)
                let position = centre + place.radius * Self.size * Self.unitOffset(place)
                let target = light.aimPoint.map { $0 + offset } ?? centre
                let axis = target - position
                let distance = (axis * axis).sum().squareRoot()
                let direction = distance > 0 ? axis / distance : SIMD3(0, 0, -1)
                let half = light.beam * 0.5 * .pi / 180
                let cosOuter = cos(half)
                let band = min(1e-4, 0.5 * (1 - cosOuter))
                let cosInner = min(1, max(cos(half * (1 - light.softness)), cosOuter + band))
                let slot = shadowSlots?.indices.contains(index) == true ? shadowSlots![index] : -1
                return LightEyeSpace.Light(
                    position: float3(position), target: float3(target),
                    direction: float3(direction), aimDistance: Float(distance),
                    cosOuter: Float(cosOuter), cosInner: Float(cosInner),
                    orbit: Float(place.orbit), pitch: Float(place.pitch),
                    radius: Float(place.radius),
                    anchor: light.pinned ? .pinned : .camera,
                    aim: light.aimPoint == nil ? .centre : .point,
                    shadow: light.shadow, outline: false,
                    shadowSlot: slot)
            })
    }

    /// The core's next default name (LightRigNextName).
    private func nextName() -> String {
        let taken = Set(names.map { $0.lowercased() })
        for name in ["key", "fill", "rim"] where !taken.contains(name) { return name }
        var i = 4
        while taken.contains("light\(i)") { i += 1 }
        return "light\(i)"
    }

    private static func light(from snapshot: LightRigSnapshot.Light) -> Light {
        Light(name: snapshot.name, orbit: snapshot.orbit, color: snapshot.color,
              pinned: snapshot.anchor == .pinned, pitch: snapshot.pitch,
              radius: snapshot.radius, beam: snapshot.beam, softness: snapshot.softness,
              warmth: snapshot.warmth, intensity: snapshot.intensity, shadow: snapshot.shadow,
              aimPoint: snapshot.aim == .point ? snapshot.aimPoint : nil)
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
            eyePlacements = [:]
            if json == "null" {
                exists = false
                enabled = false
                lights = []
                air = Self.defaultAir
                return
            }
            guard let rig = try? LightRigSnapshot.decode(Data(json.utf8)) else { return }
            exists = true
            enabled = rig.enabled
            centreX = rig.centre?.x ?? 0
            lights = rig.lights.map(Self.light(from:))
            air = rig.air
        case .restoreLight(let name, let json):
            // appkit_lights.restore_light: that light only, at its index now.
            let key = name.lowercased()
            guard exists,
                  let rig = try? LightRigSnapshot.decode(Data(json.utf8)),
                  let entry = rig.lights.first(where: { $0.name.lowercased() == key }),
                  let index = lights.firstIndex(where: { $0.name.lowercased() == key })
            else { return }
            let restored = Self.light(from: entry)
            let shadowed = lights.enumerated().filter { $0.offset != index && $0.element.shadow }.count
            guard !restored.shadow || shadowed < Self.maxShadowed else { return }
            eyePlacements[key] = nil
            lights[index] = restored
        case .highlight(let name, _, _, _, let pin):
            // The click= helper: aimed at the picked point, and a camera
            // light unless pin=1. (The point itself comes from a real pick.)
            let key = name.lowercased()
            guard let index = lights.firstIndex(where: { $0.name.lowercased() == key }) else { return }
            lights[index].aimPoint = SIMD3(0, 0, 1)
            if !pin, lights[index].pinned {
                var place = currentPlacement(index)
                place.radius = place.radius.clamped(to: Self.ranges["radius"]!)
                lights[index].placement = place
                lights[index].pinned = false
                eyePlacements[key] = nil
            }
        case .aimAtCentre(let name):
            // `aim=centre`: aimed at the centre, the placement kept.
            let key = name.lowercased()
            guard let index = lights.firstIndex(where: { $0.name.lowercased() == key }) else { return }
            lights[index].aimPoint = nil
        case .atmosphereOff:
            // `atmosphere off`: with no rig it prints a line and changes
            // nothing.
            guard exists else { return }
            air = Self.defaultAir
        case .setAir(let values):
            // `atmosphere f=v, ...`: a value outside its range is an error
            // and changes nothing; with no rig it creates one, off and empty.
            for value in values {
                guard let field = Self.airTable.first(where: { $0.name == value.field }),
                      value.value.isFinite, field.range.contains(value.value) else { return }
            }
            if !exists {
                exists = true
                enabled = false
                lights = []
            }
            for value in values { setAirField(value.field, value.value) }
        }
    }

    /// One air field set, clamped to the table (seed rounded): LightRigSet.
    private func setAirField(_ name: String, _ value: Double) {
        guard let field = Self.airTable.first(where: { $0.name == name }) else { return }
        let v = value.clamped(to: field.range)
        switch name {
        case "haze": air.haze = v
        case "dust": air.dust = v
        case "dust_size": air.dustSize = v
        case "dust_speed": air.dustSpeed = v
        case "scatter": air.scatter = v
        case "seed": air.seed = Int(v.rounded())
        default: break
        }
    }

    /// LightRigSet for a number field of a light.
    private func setNumber(_ index: Int, _ field: String, _ value: Double) -> LightSetResult {
        guard ready, exists else { return .noRig }
        if index == -1 {
            // The rig and its air: only the air fields here.
            guard Self.airTable.contains(where: { $0.name == field }) else { return .unknownField }
            guard value.isFinite else { return .badValue }
            setAirField(field, value)
            return .ok
        }
        guard lights.indices.contains(index) else { return .badIndex }
        guard value.isFinite else { return .badValue }
        var light = lights[index]
        let key = light.name.lowercased()
        switch field {
        case "orbit", "pitch", "radius":
            var place = currentPlacement(index)
            // A pinned light is re-pinned from where it is now, its derived
            // radius clamped into range first (layer1/LightRig.cpp, as on
            // unpin): a light past 8 sizes comes in to 8.
            if light.pinned { place.radius = place.radius.clamped(to: Self.ranges["radius"]!) }
            switch field {
            case "orbit": place.orbit = LightAngles.wrap(value)
            case "pitch": place.pitch = value.clamped(to: Self.ranges["pitch"]!)
            default: place.radius = value.clamped(to: Self.ranges["radius"]!)
            }
            light.placement = place
            // A pinned light is re-pinned at the new place.
            if light.pinned { eyePlacements[key] = place }
        case "beam": light.beam = value.clamped(to: Self.ranges[field]!)
        case "softness": light.softness = value.clamped(to: Self.ranges[field]!)
        case "warmth": light.warmth = value.clamped(to: Self.ranges[field]!)
        case "intensity": light.intensity = value.clamped(to: Self.ranges[field]!)
        case "anchor":
            guard value == 0 || value == 1 else { return .badValue }
            if value == 1, !light.pinned {
                // Pinned where it is now.
                light.pinned = true
                eyePlacements[key] = light.placement
            } else if value == 0, light.pinned {
                // Unpinned, its placement derived from where it is now.
                var place = currentPlacement(index)
                place.radius = place.radius.clamped(to: Self.ranges["radius"]!)
                light.placement = place
                light.pinned = false
                eyePlacements[key] = nil
            }
        case "shadow":
            let on = value >= 0.5
            if on, !light.shadow,
               lights.filter(\.shadow).count >= Self.maxShadowed { return .refused }
            light.shadow = on
        default:
            return .unknownField
        }
        lights[index] = light
        return .ok
    }

    var seams: LightsSeams {
        LightsSeams(
            rigJSON: {
                self.reads += 1
                return self.json
            },
            setNumber: { index, field, value in
                self.numberWrites.append((index, field, value))
                let result = self.setNumber(index, field, value)
                self.afterNumberWrite?()
                return result
            },
            setVector: { index, field, value in
                self.vectorWrites.append((index, field, value))
                guard self.ready, self.exists else { return .noRig }
                guard self.lights.indices.contains(index) else { return .badIndex }
                guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { return .badValue }
                switch field {
                case "color":
                    self.lights[index].color = SIMD3(value.x.clamped(to: 0...1), value.y.clamped(to: 0...1),
                                                     value.z.clamped(to: 0...1))
                case "aim_point":
                    // LightRigSet: aim at the point, the selection text cleared.
                    self.lights[index].aimPoint = value
                default:
                    return .unknownField
                }
                return .ok
            },
            perform: { self.perform($0) },
            loadPresets: {
                self.presetLoads += 1
                return self.presetList
            },
            loadAirFields: {
                self.airFieldLoads += 1
                return self.airFieldList
            },
            isReady: { self.ready },
            isBusy: { self.busy },
            now: { self.clock },
            eyeSpace: {
                self.eyeReads += 1
                if case .some(let served) = self.eyeOverride { return served }
                return self.eyeSpace
            },
            projection: {
                self.projectionReads += 1
                return self.projection
            })
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
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
        XCTAssertEqual(controller.edit("colour", 10), .unknownField)
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

    // MARK: the gizmo's projection (#622)

    private let camera = LightCameraProjection(orthoscopic: false, fovDegrees: 20,
                                               cameraDistance: 50, letterboxAspect: 0)

    func testProjectionPublishesWithTheEyeSpaceOnlyEveryFrame() {
        store.projection = camera
        begin(with: ["key", "fill", "rim"])
        XCTAssertNil(controller.eye.projection, "not under .pinnedOnly")
        controller.frameRendered()
        XCTAssertNil(controller.eye.projection)
        XCTAssertEqual(store.projectionReads, 0, "no camera read under .pinnedOnly")

        controller.eyeDemand = .everyFrame
        controller.frameRendered()
        XCTAssertEqual(controller.eye.projection, camera)
        XCTAssertNotNil(controller.eye.eyeSpace, "published together")
        XCTAssertEqual(store.projectionReads, 1)

        // The camera changes: the next frame publishes it; an edit re-reads
        // it in the same turn too.
        var zoomed = camera
        zoomed.cameraDistance = 80
        store.projection = zoomed
        controller.frameRendered()
        XCTAssertEqual(controller.eye.projection, zoomed)
        var ortho = zoomed
        ortho.orthoscopic = true
        store.projection = ortho
        XCTAssertEqual(controller.set(.beam, 30), .ok)
        XCTAssertEqual(controller.eye.projection, ortho)

        // A still camera publishes nothing.
        var changes = 0
        let sink = controller.eye.objectWillChange.sink { changes += 1 }
        defer { sink.cancel() }
        controller.frameRendered()
        XCTAssertEqual(changes, 0)

        // Back to .pinnedOnly: cleared with the eye space.
        controller.eyeDemand = .pinnedOnly
        XCTAssertNil(controller.eye.projection)
        XCTAssertNil(controller.eye.eyeSpace)
        let reads = store.projectionReads
        controller.frameRendered()
        XCTAssertEqual(store.projectionReads, reads)
    }

    func testDemandSetBeforeBeginPublishesAtOnce() {
        // What the engine does on entering Lights mode: the first refresh,
        // with no frame rendered, already has the eye space and projection.
        store.setRig(["key", "fill"])
        store.projection = camera
        controller.eyeDemand = .everyFrame
        controller.begin()
        XCTAssertEqual(controller.eye.projection, camera)
        XCTAssertEqual(controller.eye.eyeSpace?.lights.count, 2)
        XCTAssertEqual(store.eyeReads, 1)

        // end() clears both and keeps the demand (the engine resets it).
        controller.end()
        XCTAssertNil(controller.eye.projection)
        XCTAssertNil(controller.eye.eyeSpace)
        XCTAssertEqual(controller.eyeDemand, .everyFrame)
    }

    func testNoProjectionWithoutAnEyeRead() {
        // No rig: nothing to project, so no camera either.
        store.projection = camera
        controller.eyeDemand = .everyFrame
        begin(with: nil)
        controller.frameRendered()
        XCTAssertNil(controller.eye.eyeSpace)
        XCTAssertNil(controller.eye.projection)
        // A read that disagrees with the mirror is not published, and neither
        // is the camera.
        store.setRig(["key"])
        controller.refresh()
        XCTAssertNotNil(controller.eye.projection)
        controller.eyeDemand = .pinnedOnly
        controller.eyeDemand = .everyFrame
        store.eyeOverride = .some(nil)
        store.clock += 1
        controller.frameRendered()
        XCTAssertNil(controller.eye.projection)
        XCTAssertNil(controller.eye.eyeSpace)
    }

    // MARK: front and behind (#622)

    func testBehindFollowsPlacements() {
        store.setRig(["key", "fill", "rim"])
        store.lights[2].orbit = 150        // a camera light behind the molecule
        controller.begin()
        XCTAssertEqual(controller.facing.behind, ["rim"])
        XCTAssertTrue(controller.isBehind("RIM"), "names ignore case")
        XCTAssertFalse(controller.isBehind("key"))

        // A gizmo-style write crosses fill to the back in the same turn.
        controller.select(name: "fill")
        XCTAssertEqual(controller.setPlacement(orbit: 120, pitch: 10), .ok)
        XCTAssertEqual(controller.facing.behind, ["fill", "rim"])

        // A pinned light flips as the camera turns (its eye placement moves
        // across orbit 90 frame by frame).
        controller.select(name: "key")
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["key"] = LightPlacement(orbit: 80, pitch: 0, radius: 4)
        controller.frameRendered()
        XCTAssertFalse(controller.isBehind("key"))
        store.eyePlacements["key"] = LightPlacement(orbit: 100, pitch: 0, radius: 4)
        controller.frameRendered()
        XCTAssertTrue(controller.isBehind("key"))
        XCTAssertEqual(controller.facing.behind, ["key", "fill", "rim"])

        // Camera lights never flip with the camera; leaving clears it.
        controller.end()
        XCTAssertEqual(controller.facing.behind, [])
        XCTAssertFalse(controller.isBehind("rim"))
    }

    func testFacingPublishesOnlyOnACrossing() {
        store.setRig(["key", "fill"])
        store.lights[0].pinned = true
        store.eyePlacements["key"] = LightPlacement(orbit: 90, pitch: 0, radius: 4)
        controller.begin()
        XCTAssertEqual(controller.facing.behind, [])
        var changes = 0
        let sink = controller.facing.objectWillChange.sink { changes += 1 }
        defer { sink.cancel() }
        // 100 frames of Float noise on the outline: no publish.
        for frame in 0..<100 {
            let noise = Double(Float(Double(frame % 7 - 3) * 1e-5))
            store.eyePlacements["key"] = LightPlacement(orbit: 90 + noise, pitch: noise, radius: 4)
            controller.frameRendered()
        }
        XCTAssertEqual(changes, 0)
        // A crossing publishes once; staying behind publishes nothing more.
        store.eyePlacements["key"] = LightPlacement(orbit: 95, pitch: 0, radius: 4)
        controller.frameRendered()
        XCTAssertEqual(changes, 1)
        store.eyePlacements["key"] = LightPlacement(orbit: 120, pitch: 5, radius: 4)
        controller.frameRendered()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(controller.facing.behind, ["key"])
    }

    // MARK: highlight placement (#622)

    func testPlaceHighlightPerformsOneAction() {
        begin(with: ["key", "fill", "rim"])
        controller.select(name: "fill")
        XCTAssertTrue(controller.placeHighlight(sceneNDC: SIMD2(0.125, -0.0625), rim: nil))
        XCTAssertEqual(store.performed, [.highlight(name: "fill", x: 0.125, y: -0.0625, rim: nil, pin: false)])
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(controller.selectedLight?.aim, .point, "re-read in the same turn")

        // The rim rule, and a pinned light keeps its pin.
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        XCTAssertTrue(controller.placeHighlight(sceneNDC: SIMD2(-0.5, 0.25), rim: 145))
        XCTAssertEqual(store.performed.last,
                       .highlight(name: "rim", x: -0.5, y: 0.25, rim: 145, pin: true))
        XCTAssertEqual(controller.selectedLight?.anchor, .pinned)
        XCTAssertEqual(store.performed.count, 2)
    }

    func testPlaceHighlightRunsNothingWhenItCannot() {
        begin(with: ["key"])
        // Out of the helper's range, or not finite: nothing run.
        for point: SIMD2<Double> in [SIMD2(1.5, 0), SIMD2(0, -1.0001), SIMD2(.nan, 0), SIMD2(0, .infinity)] {
            XCTAssertFalse(controller.placeHighlight(sceneNDC: point, rim: nil), "\(point)")
        }
        XCTAssertFalse(controller.placeHighlight(sceneNDC: SIMD2(0, 0), rim: 180))
        // Busy, outside the mode, or no light selected.
        store.busy = true
        XCTAssertFalse(controller.placeHighlight(sceneNDC: SIMD2(0, 0), rim: nil))
        store.busy = false
        controller.end()
        XCTAssertFalse(controller.placeHighlight(sceneNDC: SIMD2(0, 0), rim: nil))
        controller.begin()
        store.setRig([])
        controller.refresh()
        XCTAssertNil(controller.selection.name)
        XCTAssertFalse(controller.placeHighlight(sceneNDC: SIMD2(0, 0), rim: nil))
        XCTAssertTrue(store.performed.isEmpty)
    }
}
