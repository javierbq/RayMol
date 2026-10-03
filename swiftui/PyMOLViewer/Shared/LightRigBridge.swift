import Foundation

// The light rig (#611, spec §4.4) as the app sees it: a decodable snapshot of
// PyMOLBridge_LightsJSON, the rig resolved to eye space
// (PyMOLBridge_LightsEyeSpace) for the overlays, and per-field writes
// (PyMOLBridge_LightSet / LightSetVector), one per drag tick, with no Python.
//
// The core owns the rig (one per PyMOL instance, in the scene); these are thin
// reads and writes over it. Main thread only, like captureView(): the core's
// rig has no lock, and a movie export renders off-main.

/// The rig as `cmd.get_lights()` returns it, decoded from the bridge's JSON
/// (the same version, keys and types, all from the core's one field table).
struct LightRigSnapshot: Decodable, Equatable {
    enum Anchor: String, Decodable { case camera, pinned }
    enum Aim: String, Decodable { case centre, point }

    struct Air: Decodable, Equatable {
        var haze: Double
        var dust: Double
        var dustSize: Double
        var dustSpeed: Double
        var scatter: Double
        var seed: Int

        enum CodingKeys: String, CodingKey {
            case haze, dust, scatter, seed
            case dustSize = "dust_size"
            case dustSpeed = "dust_speed"
        }
    }

    struct Light: Decodable, Equatable {
        var name: String
        var anchor: Anchor
        /// Degrees; 0 = at the camera, +90 = camera-right (the last placed
        /// values while pinned: `LightEyeSpace` has the current ones).
        var orbit: Double
        var pitch: Double
        /// Scene sizes (multiples of the rig's `size`).
        var radius: Double
        /// World Å; where a pinned light is.
        var position: SIMD3<Double>
        var aim: Aim
        /// World Å; what the light points at when `aim` is `.point`.
        var aimPoint: SIMD3<Double>
        /// The selection the point came from (display only).
        var aimSelection: String
        /// Full cone, degrees.
        var beam: Double
        var softness: Double
        /// sRGB, 0...1.
        var color: SIMD3<Double>
        /// Kelvin.
        var warmth: Double
        var intensity: Double
        var highlight: Double
        var falloff: Double
        var shadow: Bool
        var outline: Bool

        enum CodingKeys: String, CodingKey {
            case name, anchor, orbit, pitch, radius, position, aim
            case beam, softness, color, warmth, intensity, highlight, falloff
            case shadow, outline
            case aimPoint = "aim_point"
            case aimSelection = "aim_selection"
        }
    }

    var version: Int
    var enabled: Bool
    /// The captured frame (world Å); nil only for an empty rig with no light yet.
    var centre: SIMD3<Double>?
    var size: Double?
    var ambient: Double
    var classic: Double
    var air: Air
    var lights: [Light]

    /// Decode the bridge's (or `json.dumps(cmd.get_lights())`'s) JSON.
    static func decode(_ json: Data) throws -> LightRigSnapshot {
        try JSONDecoder().decode(LightRigSnapshot.self, from: json)
    }
}

/// The rig resolved to eye space for the live camera (PyMOLBridge_LightsEyeSpace):
/// what the gizmo and the orbit plan project (#619-#622).
struct LightEyeSpace: Equatable {
    struct Light: Equatable {
        var position: SIMD3<Float>
        /// The eye-space aim point: the centre, or the light's point.
        var target: SIMD3<Float>
        /// Unit, from `position` to `target`.
        var direction: SIMD3<Float>
        var aimDistance: Float
        /// cos(beam / 2).
        var cosOuter: Float
        /// Where the soft edge starts (> cosOuter).
        var cosInner: Float
        /// Current placement (derived from the position for a pinned light).
        var orbit: Float
        var pitch: Float
        var radius: Float
        var anchor: LightRigSnapshot.Anchor
        var aim: LightRigSnapshot.Aim
        var shadow: Bool
        var outline: Bool
    }

    var enabled: Bool
    /// False only for an empty rig that has no frame yet (no lights then).
    var hasFrame: Bool
    var centre: SIMD3<Float>
    /// Å (the rig's 1x).
    var size: Float
    /// lights[i] is light i of the rig.
    var lights: [Light]
}

/// What a light write did. Anything but `.ok` leaves the rig unchanged.
enum LightSetResult: Equatable {
    case ok
    /// No such field (or a rig field at a light index, or vice versa).
    case unknownField
    /// The index is outside -1 ..< light count.
    case badIndex
    /// Refused: a 4th shadowed light; text fields and the frame.
    case refused
    /// NaN, inf, or not a valid choice.
    case badValue
    /// There is no rig (or the engine is not ready).
    case noRig

    /// A PYMOL_LIGHT_SET_* code (PyMOLBridgeLights.h).
    init(status: Int32) {
        switch Int(status) {
        case PYMOL_LIGHT_SET_OK: self = .ok
        case PYMOL_LIGHT_SET_UNKNOWN_FIELD: self = .unknownField
        case PYMOL_LIGHT_SET_BAD_INDEX: self = .badIndex
        case PYMOL_LIGHT_SET_REFUSED: self = .refused
        case PYMOL_LIGHT_SET_BAD_VALUE: self = .badValue
        case PYMOL_LIGHT_SET_NO_RIG: self = .noRig
        default: self = .badValue   // not a code the core returns
        }
    }
}

private func simd3(_ t: (Float, Float, Float)) -> SIMD3<Float> {
    SIMD3(t.0, t.1, t.2)
}

extension PyMOLEngine {
    /// The rig's JSON as the core writes it, or nil when there is no rig.
    func lightRigJSON() -> String? {
        assert(Thread.isMainThread, "light-rig bridge calls are main-thread only")
        guard isReady, let instance else { return nil }
        guard let raw = PyMOLBridge_LightsJSON(instance) else { return nil }
        defer { PyMOLBridge_FreeFeedback(raw) }
        return String(cString: raw)
    }

    /// The rig, or nil when there is none.
    func lightRig() -> LightRigSnapshot? {
        guard let json = lightRigJSON() else { return nil }
        do {
            return try LightRigSnapshot.decode(Data(json.utf8))
        } catch {
            // The core writes this JSON from the same table as the dict, so a
            // failure here is a bug: loud in Debug, "no rig" in Release.
            assertionFailure("light rig JSON did not decode: \(error)")
            return nil
        }
    }

    /// Set one number field of light `index` (>= 0), or of the rig and its air
    /// (index -1). Bools and the anchor / aim choices take 0 or 1. Requests a
    /// redraw when the rig changed.
    @discardableResult
    func setLight(_ index: Int, _ field: String, _ value: Double) -> LightSetResult {
        assert(Thread.isMainThread, "light-rig bridge calls are main-thread only")
        guard isReady, let instance else { return .noRig }
        let result = LightSetResult(status:
            PyMOLBridge_LightSet(instance, Int32(clamping: index), field, value))
        if result == .ok { requestViewportRedraw() }
        return result
    }

    /// Set one vector field of light `index`: `color` (sRGB 0...1), `aim_point`
    /// (world Å; aims the light at it) or `position` (world Å; pins it there).
    @discardableResult
    func setLight(_ index: Int, _ field: String, _ vector: SIMD3<Double>) -> LightSetResult {
        assert(Thread.isMainThread, "light-rig bridge calls are main-thread only")
        guard isReady, let instance else { return .noRig }
        let result = LightSetResult(status: PyMOLBridge_LightSetVector(
            instance, Int32(clamping: index), field, vector.x, vector.y, vector.z))
        if result == .ok { requestViewportRedraw() }
        return result
    }

    /// The rig resolved to eye space for the live camera, or nil when there is
    /// no rig.
    func lightsEyeSpace() -> LightEyeSpace? {
        assert(Thread.isMainThread, "light-rig bridge calls are main-thread only")
        guard isReady, let instance else { return nil }
        var rig = PyMOLLightRigEye()
        var lights = [PyMOLLightEye](repeating: PyMOLLightEye(), count: Int(PYMOL_LIGHTS_MAX))
        let count = lights.withUnsafeMutableBufferPointer { buffer in
            PyMOLBridge_LightsEyeSpace(instance, &rig, buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= 0 else { return nil }
        return LightEyeSpace(
            enabled: rig.enabled != 0,
            hasFrame: rig.hasFrame != 0,
            centre: simd3(rig.centre),
            size: rig.size,
            lights: lights.prefix(min(Int(count), lights.count)).map { light in
                LightEyeSpace.Light(
                    position: simd3(light.position),
                    target: simd3(light.target),
                    direction: simd3(light.direction),
                    aimDistance: light.aimDistance,
                    cosOuter: light.cosOuter,
                    cosInner: light.cosInner,
                    orbit: light.orbit,
                    pitch: light.pitch,
                    radius: light.radius,
                    anchor: light.anchor != 0 ? .pinned : .camera,
                    aim: light.aim != 0 ? .point : .centre,
                    shadow: light.shadow != 0,
                    outline: light.outline != 0)
            })
    }
}
