// LightsEditing.swift — the one edit path for the selected light (#620).
//
// The inspector (#620), the orbit view (#621) and the gizmo (#622) all edit
// the light rig through the typed API below, on top of LightsController's
// bridge-setter `edit` path. Every successful write re-reads the rig mirror in
// the same main-thread turn, so whichever tool made the edit, every observer
// shows it in the next frame.
//
// Contract for #621 and #622:
// - select a light with `LightsController.select(index:)` (or `select(name:)`);
// - write with `set`, `step`, `setPlacement`, `setColour`, `setPinned` and
//   `setShadow`; nothing else writes the rig per tick. A refused shadow (a 4th
//   shadowed light) sets `shadowRefused`, which the inspector shows as a
//   notice; the next edit or selection change clears it;
// - read `rig`, `selection` and `identitySlot(for:)` from the controller, the
//   current orbit, pitch and radius of every light from `eye.placements`, and
//   the full eye-space rig from `eye.eyeSpace` after setting
//   `eyeDemand = .everyFrame` (set it back to `.pinnedOnly` when done);
// - do the angle maths (dial and lamp drags, pitch arcs) with `LightAngles`;
// - a direct-manipulation gesture starts with `beginGesture()` (its owner),
//   writes every tick with `set(_:_:owner:)` (refused once the owner is no
//   longer selected), reads a step's base with `freshValue`, and snaps with
//   `LightSnap` (orbit 15°, radius 0.5×, pitch 1°);
// - #622's gizmo reuses that gesture start and that one owner guard
//   (`ownsGesture`): a knob tick writes orbit and pitch together with
//   `setPlacement(orbit:pitch:radius:owner:)` (pitch first, one re-read, so
//   pitch never lands without orbit), an aim-dot tick writes the picked
//   point with `setAim(_:owner:)`, and the eye demand follows Lights mode
//   (the engine sets `.everyFrame` while the mode is on), so `eye.eyeSpace`
//   and `eye.projection` are there whenever the gizmo shows.
//
// Like LightsController.swift, this file names no Python, console or bridge
// entry point: every write goes through the controller's seams, so a drag runs
// no Python per tick (#610). testing/tests/raymol/lighting_mode.py checks it,
// and lighting_inspector.py checks `LightParameter.range` against the core's
// field table.

import CoreGraphics
import Foundation

// MARK: - Parameters

/// One arrow-key nudge of the selected light (#700): which placement field and by how many degrees.
struct LightNudge: Equatable {
    let parameter: LightParameter
    let delta: Double
}

/// One numeric control of the selected light: a core light field of kind
/// float or angle.
enum LightParameter: String, CaseIterable {
    case orbit, pitch, radius, intensity, warmth, beam, softness

    /// The core field name.
    var field: String { rawValue }

    /// The core's range (layer1/LightRig.cpp field table). The core clamps
    /// into it (orbit wraps instead). Keep each line in the form
    /// `case .x: return a...b`: lighting_inspector.py parses it.
    var range: ClosedRange<Double> {
        switch self {
        case .orbit: return -180...180
        case .pitch: return -90...90
        case .radius: return 0.5...8
        case .intensity: return 0...4
        case .warmth: return 1500...15000
        case .beam: return 1...170
        case .softness: return 0...1
        }
    }

    /// The value wraps around the range (an angle field) instead of clamping.
    var wraps: Bool {
        switch self {
        case .orbit: return true
        default: return false
        }
    }

    /// Orbit, pitch and radius: where the light is. A pinned light's current
    /// values come from eye space (`LightsController.eye`).
    var isPlacement: Bool {
        switch self {
        case .orbit, .pitch, .radius: return true
        default: return false
        }
    }

    /// The control's label (spec decision 11).
    var label: String {
        switch self {
        case .orbit: return "Orbit"
        case .pitch: return "Pitch"
        case .radius: return "Radius"
        case .intensity: return "Intensity"
        case .warmth: return "Warmth"
        case .beam: return "Beam"
        case .softness: return "Softness"
        }
    }

    /// What a continuous control (slider, dial) rounds to. Typed values are
    /// written exactly.
    var quantum: Double {
        switch self {
        case .orbit, .pitch: return 1
        case .radius, .intensity, .softness: return 0.01
        case .warmth: return 10
        case .beam: return 0.5
        }
    }

    /// `value` rounded to `quantum` (for a slider or dial tick).
    func rounded(_ value: Double) -> Double {
        (value / quantum).rounded() * quantum
    }
}

// MARK: - Placement

/// Where a light is around the rig centre: orbit and pitch in degrees, radius
/// in scene sizes.
struct LightPlacement: Equatable {
    var orbit: Double
    var pitch: Double
    var radius: Double

    init(orbit: Double, pitch: Double, radius: Double) {
        self.orbit = orbit
        self.pitch = pitch
        self.radius = radius
    }

    /// A light's current placement in eye space.
    init(_ light: LightEyeSpace.Light) {
        self.init(orbit: Double(light.orbit), pitch: Double(light.pitch),
                  radius: Double(light.radius))
    }

    /// Some value differs from `other` by more than `tolerance` (orbit
    /// compared around the circle, so 180 and -180 are the same).
    func differs(from other: LightPlacement, by tolerance: Double) -> Bool {
        abs(LightAngles.wrap(orbit - other.orbit)) > tolerance
            || abs(pitch - other.pitch) > tolerance
            || abs(radius - other.radius) > tolerance
    }
}

extension LightRigSnapshot.Light {
    /// The stored placement: a camera light's current one, a pinned light's
    /// last placed one.
    var placement: LightPlacement {
        LightPlacement(orbit: orbit, pitch: pitch, radius: radius)
    }

    /// The stored value of `parameter`.
    func value(of parameter: LightParameter) -> Double {
        switch parameter {
        case .orbit: return orbit
        case .pitch: return pitch
        case .radius: return radius
        case .intensity: return intensity
        case .warmth: return warmth
        case .beam: return beam
        case .softness: return softness
        }
    }
}

// MARK: - Angle maths

/// Dial and drag angles, in the plan's orientation (spec decision 12): the
/// camera at the bottom of an orbit dial, +90 to its right, ±180 at the top;
/// a pitch half dial has 0 to the right and +90 up. Offsets are in view
/// coordinates (y grows downwards) and unit length.
enum LightAngles {
    /// The orbit of a point at offset (dx, dy) from the dial's centre:
    /// bottom 0, right +90, top 180, left -90.
    static func orbit(dx: Double, dy: Double) -> Double {
        wrap(atan2(dx, dy) * 180 / .pi)
    }

    /// The unit offset of `orbit` on the dial (inverse of `orbit(dx:dy:)`).
    static func offset(orbit: Double) -> (dx: Double, dy: Double) {
        let r = orbit * .pi / 180
        return (sin(r), cos(r))
    }

    /// The pitch of a point at offset (dx, dy) from the half dial's centre:
    /// right 0, up +90, down -90; the left half clamps to ±90.
    static func pitch(dx: Double, dy: Double) -> Double {
        min(max(atan2(-dy, dx) * 180 / .pi, -90), 90)
    }

    /// The unit offset of `pitch` on the half dial (inverse of
    /// `pitch(dx:dy:)` on -90...90).
    static func offset(pitch: Double) -> (dx: Double, dy: Double) {
        let r = pitch * .pi / 180
        return (cos(r), -sin(r))
    }

    /// `degrees` wrapped into (-180, 180], as the core wraps orbit.
    static func wrap(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return degrees }
        var x = fmod(degrees + 180, 360)
        if x <= 0 { x += 360 }
        return x - 180
    }
}

// MARK: - Snapping

/// The grids the orbit view snaps to (spec §9): orbit every 15° (decision 7),
/// radius every 0.5×, pitch to the dial's 1°. Values are compared at
/// `tolerance`, the eye-space drift a pinned light's Float placement carries,
/// so 104.99999 counts as on 105. Non-finite input gives nil.
enum LightSnap {
    static let tolerance = LightsController.eyeDriftTolerance
    static let orbitStep = 15.0
    static let radiusStep = 0.5

    /// The nearest multiple of 15°, wrapped into (-180, 180].
    static func orbit(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        return LightAngles.wrap((degrees / orbitStep).rounded() * orbitStep)
    }

    /// The nearest multiple of 0.5×, clamped into the core's 0.5...8.
    static func radius(_ sizes: Double) -> Double? {
        guard sizes.isFinite else { return nil }
        return clampRadius((sizes / radiusStep).rounded() * radiusStep)
    }

    /// Rounded to the pitch quantum (1°), clamped into -90...90.
    static func pitch(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        let r = LightParameter.pitch.range
        // `+ 0` turns -0 (a small negative rounded) into 0.
        return min(max(LightParameter.pitch.rounded(degrees), r.lowerBound), r.upperBound) + 0
    }

    /// The radius a pinch makes of `start`: `radius(start × magnification)`.
    /// nil unless the magnification is finite and positive.
    static func pinch(start: Double, magnification: Double) -> Double? {
        guard magnification.isFinite, magnification > 0 else { return nil }
        return radius(start * magnification)
    }

    /// The next 15° grid value above (`up`) or below `degrees`, wrapped. A
    /// value within `tolerance` of a grid value counts as on it.
    static func nextOrbit(from degrees: Double, up: Bool) -> Double? {
        guard let n = next(degrees, step: orbitStep, up: up) else { return nil }
        return LightAngles.wrap(n)
    }

    /// The next 0.5× grid value above (`up`) or below `sizes`, clamped into
    /// 0.5...8 (8 up stays 8).
    static func nextRadius(from sizes: Double, up: Bool) -> Double? {
        next(sizes, step: radiusStep, up: up).map(clampRadius)
    }

    /// `a` and `b` are the same value at `tolerance` (around the circle when
    /// `wraps`, so 179.9995 and -180 are the same).
    static func same(_ a: Double, _ b: Double, wraps: Bool) -> Bool {
        let d = wraps ? LightAngles.wrap(a - b) : a - b
        return abs(d) <= tolerance
    }

    private static func next(_ value: Double, step: Double, up: Bool) -> Double? {
        guard value.isFinite else { return nil }
        let k = value / step
        let nearest = k.rounded()
        let index: Double
        if abs(k - nearest) * step <= tolerance {
            index = nearest + (up ? 1 : -1)
        } else {
            index = up ? k.rounded(.up) : k.rounded(.down)
        }
        return index * step
    }

    private static func clampRadius(_ sizes: Double) -> Double {
        let r = LightParameter.radius.range
        return min(max(sizes, r.lowerBound), r.upperBound)
    }
}

// MARK: - Colour

/// Light colours: the swatches, sRGB conversion and the match tolerance.
enum LightColour {
    /// Two colours match when every channel is within this (one 8-bit step):
    /// a colour picker echoing a value through another colour space must not
    /// count as an edit, and still selects its swatch.
    static let tolerance = 1.0 / 255.0

    /// The inspector's swatches: the colours #612's presets use
    /// (modules/pymol/lighting_commands.py).
    static let swatches: [(name: String, rgb: SIMD3<Double>)] = [
        ("White", SIMD3(1, 1, 1)),
        ("Cyan", SIMD3(0, 1, 1)),
        ("Magenta", SIMD3(1, 0, 1)),
        ("Violet", SIMD3(0.5, 0.5, 1)),
        ("Green", SIMD3(0.6, 1, 0.55)),
        ("Red", SIMD3(1, 0, 0)),
    ]

    /// `color` in sRGB, each channel clamped into 0...1 (an extended-range
    /// colour comes back outside it); nil when it cannot be converted.
    static func srgb(from color: CGColor) -> SIMD3<Double>? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        func clamp(_ x: CGFloat) -> Double {
            let d = Double(x)
            return d.isFinite ? min(max(d, 0), 1) : 0
        }
        return SIMD3(clamp(c[0]), clamp(c[1]), clamp(c[2]))
    }

    /// An opaque sRGB colour.
    static func cgColor(_ rgb: SIMD3<Double>) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    /// Every channel within `tolerance`.
    static func matches(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        abs(a.x - b.x) <= tolerance + 1e-12
            && abs(a.y - b.y) <= tolerance + 1e-12
            && abs(a.z - b.z) <= tolerance + 1e-12
    }

    /// The swatch `rgb` matches, if any.
    static func swatchIndex(of rgb: SIMD3<Double>) -> Int? {
        swatches.firstIndex { matches($0.rgb, rgb) }
    }
}

// MARK: - Warmth track

/// The warmth slider's track: log kelvin, so the warm end (where the colour
/// changes most) gets about 40% of the track. 1500 K is 0, 15000 K is 1,
/// 6500 K about 0.64.
enum WarmthScale {
    static let range = LightParameter.warmth.range

    /// The slider position (0...1) of `kelvin` (clamped into the range).
    static func position(kelvin: Double) -> Double {
        let k = min(max(kelvin, range.lowerBound), range.upperBound)
        return log(k / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    /// The kelvin at slider position `position` (clamped into 0...1).
    static func kelvin(position: Double) -> Double {
        let t = min(max(position, 0), 1)
        return range.lowerBound * pow(range.upperBound / range.lowerBound, t)
    }
}

// MARK: - The typed edit API

extension LightsController {
    /// The current placement of light `index`: eye space for a pinned light
    /// (refreshed per rendered frame in Lights mode), the stored values for a
    /// camera light. nil when there is no such light or the mode is off.
    func placement(at index: Int) -> LightPlacement? {
        eye.placements.indices.contains(index) ? eye.placements[index] : nil
    }

    /// The selected light's current value of `parameter` (a pinned light's
    /// orbit, pitch and radius from eye space); nil with no selected light.
    func value(_ parameter: LightParameter) -> Double? {
        guard let light = selectedLight else { return nil }
        if parameter.isPlacement, let index = selection.index,
           let placement = placement(at: index) {
            switch parameter {
            case .orbit: return placement.orbit
            case .pitch: return placement.pitch
            default: return placement.radius
            }
        }
        return light.value(of: parameter)
    }

    /// Set `parameter` of the selected light (the core clamps, and wraps
    /// orbit). What a slider or dial tick, a stepper press and a typed value
    /// call: the bridge setter, no Python.
    @discardableResult
    func set(_ parameter: LightParameter, _ value: Double) -> LightSetResult {
        writeNumbers([(parameter.field, value)])
    }

    /// Set `parameter` of the light a gesture began on: what a gesture tick
    /// (#621's plan and arc, #622's gizmo) calls, with the owner
    /// `beginGesture()` returned. Re-reads a stale mirror first, then writes
    /// only while `owner` (ignoring case) is still the selected light: a
    /// console or MCP remove since the last read slides another light into
    /// the selected index, the re-read repairs the selection onto it, and the
    /// name check refuses the write (`.badIndex`).
    @discardableResult
    func set(_ parameter: LightParameter, _ value: Double, owner: String) -> LightSetResult {
        guard ownsGesture(owner) else { return .badIndex }
        return writeNumbers([(parameter.field, value)], editKey: gestureEditKey)
    }

    /// Move the light a gesture began on (#622's knob tick): `ownsGesture`,
    /// then `setPlacement(orbit:pitch:radius:)` (pitch, orbit, radius, the
    /// selected index fixed, one re-read), so a tick writes its values
    /// together or not at all. `.badIndex` once `owner` is not selected.
    @discardableResult
    func setPlacement(orbit: Double?, pitch: Double?, radius: Double? = nil,
                      owner: String) -> LightSetResult {
        guard ownsGesture(owner) else { return .badIndex }
        return setPlacement(orbit: orbit, pitch: pitch, radius: radius, editKey: gestureEditKey)
    }

    /// Aim the light a gesture began on at a world point (#622's aim dot,
    /// the point #614's surface pick found): the core sets the aim to that
    /// point and clears the aim selection. `.badIndex` once `owner` is not
    /// selected.
    @discardableResult
    func setAim(_ point: SIMD3<Double>, owner: String) -> LightSetResult {
        guard ownsGesture(owner) else { return .badIndex }
        return edit("aim_point", point, editKey: gestureEditKey)
    }

    /// The one owner guard of every gesture write (`set`, `setPlacement` and
    /// `setAim` with `owner:`): the selected light can be edited, a stale
    /// mirror is re-read, and only then is the selected name compared with
    /// `owner` (ignoring case). A console or MCP remove since the last read
    /// slides another light into the selected index; the re-read repairs the
    /// selection onto it and the name check refuses the write.
    private func ownsGesture(_ owner: String) -> Bool {
        guard canEdit else { return false }
        refreshIfStale()
        return selection.name?.lowercased() == owner.lowercased()
    }

    /// The selected light's current value of `parameter`, read fresh: a
    /// stale mirror is re-read first, and for a pinned light's placement the
    /// eye space too. nil unless `canEdit`. What a step adds to.
    func freshValue(_ parameter: LightParameter) -> Double? {
        guard canEdit else { return nil }
        refreshIfStale()
        if parameter.isPlacement, selectedLight?.anchor == .pinned {
            frameRendered()
        }
        return value(parameter)
    }

    /// Add `delta` to the selected light's current value of `parameter` (a
    /// stepper press). Re-reads a stale mirror first, and for a pinned light's
    /// placement the eye space too, so the step adds to the exact current
    /// value. Orbit wraps in the core (178 + 5 is -177).
    @discardableResult
    func step(_ parameter: LightParameter, by delta: Double) -> LightSetResult {
        guard let current = freshValue(parameter) else { return .badIndex }
        return set(parameter, current + delta)
    }

    /// An arrow-key nudge in the main view (#700): one stepper-style write, so it
    /// re-reads a stale mirror, wraps orbit / clamps pitch in the core, and counts
    /// as an edit by the same rules as a stepper press.
    @discardableResult
    func nudge(_ nudge: LightNudge) -> LightSetResult { step(nudge.parameter, by: nudge.delta) }

    /// Move the selected light: each given value is written with the selected
    /// index fixed for the whole call, in the order pitch, orbit, radius
    /// (on a pinned light each write re-pins and derives the other two from
    /// where the light is now, and at pitch ±90 the derived orbit is
    /// undefined, so pitch goes first). Stops at the first write that is not
    /// `.ok` and returns its result; re-reads the mirror once if any write
    /// succeeded.
    @discardableResult
    func setPlacement(orbit: Double? = nil, pitch: Double? = nil,
                      radius: Double? = nil, editKey: String? = nil) -> LightSetResult {
        var fields: [(String, Double)] = []
        if let pitch { fields.append((LightParameter.pitch.field, pitch)) }
        if let orbit { fields.append((LightParameter.orbit.field, orbit)) }
        if let radius { fields.append((LightParameter.radius.field, radius)) }
        return writeNumbers(fields, editKey: editKey)
    }

    /// Set the selected light's colour (sRGB 0...1). A colour within
    /// `LightColour.tolerance` of the current one writes nothing (a colour
    /// picker echoing its value on open must not count as an edit).
    @discardableResult
    func setColour(_ rgb: SIMD3<Double>) -> LightSetResult {
        guard canEdit else { return .badIndex }
        refreshIfStale()
        guard let light = selectedLight else { return .badIndex }
        if LightColour.matches(light.color, rgb) { return .ok }
        return edit("color", rgb)
    }

    /// Pin the selected light where it is now (fixed in world space), or
    /// unpin it (it follows the camera from where it is now).
    @discardableResult
    func setPinned(_ on: Bool) -> LightSetResult {
        writeNumbers([("anchor", on ? 1 : 0)])
    }

    /// Turn the selected light's shadow on or off. `.refused` (and
    /// `shadowRefused` set) when `maxShadowed` other lights already cast one:
    /// the core keeps the cap, nothing changes. A shadow shows only while the
    /// scene's Shadows switch is on (#616); the inspector says so.
    @discardableResult
    func setShadow(_ on: Bool) -> LightSetResult {
        writeNumbers([("shadow", on ? 1 : 0)])
    }
}
