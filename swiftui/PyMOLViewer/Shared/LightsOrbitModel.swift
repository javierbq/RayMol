// LightsOrbitModel.swift — the orbit mini viewer's model (#621, spec §9,
// sketch 2).
//
// The orbit view is a flat plan of the rig seen from above, the camera at the
// bottom, plus a pitch arc for the selected light. This file holds everything
// about it that is not drawing, so the unit tests, the live tests, the view
// and the DEBUG simulator hook all run the same code:
// - LightsOrbitMetrics: the card's fixed sizes (no GeometryReader needed);
// - OrbitPlanLayout and PitchArcLayout: where every lamp, ring, the radius
//   square and the pitch handle are drawn, and the inverse maps;
// - OrbitHitTest: which target a press lands on;
// - OrbitDragSession and OrbitPinchSession: one gesture each, from the press
//   (owner, grab offset, frozen extent and square angle) to the snapped,
//   de-duplicated edit of each tick;
// - LightsOrbitState: what the card shows, with its VoiceOver strings and a
//   one-token summary for logs;
// - LightsOrbitInteraction: turns a press, a drag tick, a pinch or a
//   VoiceOver action into LightsController calls.
//
// Every write goes through the shared edit path in LightsEditing.swift:
// `beginGesture()` at the press, then the owner-guarded `set(_:_:owner:)` per
// tick (a bridge setter, no Python, #610). So the plan, the inspector and the
// bar show each other's edits within a frame, and this file names no Python,
// console or bridge entry point (testing/tests/raymol/lighting_mode.py and
// lighting_orbit.py check that).
//
// Angles follow LightAngles (spec decision 12): on the plan, orbit 0 is at the
// camera (bottom), +90 to the right, ±180 at the top, so positive orbit runs
// counter-clockwise on screen (§4.3); on the arc, 0 is level (right), +90 up.
// Lamps sit at their radius on their orbit (polar, sketch 2): pitch lives on
// the arc, so the three controls stay independent.

import CoreGraphics
import Foundation

// MARK: - Metrics

/// The card's fixed sizes, shared by the drawing, the gestures, the tests and
/// the DEBUG gestures.
enum LightsOrbitMetrics {
    /// The plan canvas and the pitch-arc canvas, side by side in the card.
    static let planSize = CGSize(width: 194, height: 196)
    static let arcSize = CGSize(width: 58, height: 196)
    /// Between the plan's outer ring and its canvas edge.
    static let planMargin: CGFloat = 5
    /// The drawn radius of a lamp, and of the selected one.
    static let lampRadius: CGFloat = 6
    static let selectedLampRadius: CGFloat = 8
    /// Half the side of the radius square.
    static let squareHalfSide: CGFloat = 5
    /// The drawn radius of the pitch handle.
    static let handleRadius: CGFloat = 7
    /// The arc's centre is this far from the arc canvas's left edge; the arc
    /// keeps `arcMargin` from its other edges.
    static let arcInset: CGFloat = 8
    static let arcMargin: CGFloat = 8
    /// A drag writes nothing until the pointer is this far from the press, so
    /// a tap never writes.
    static let dragSlop: CGFloat = 3
    /// A pointer this close to the plan's centre has no orbit angle.
    static let centreDeadZone: CGFloat = 2
    /// The radius square sits this far before its lamp's orbit (sketch 2)
    /// wherever its ring is big enough.
    static let squareAngle = 45.0
    /// Ticks per DEBUG gesture.
    static let autoTicks = 12

    /// How far outside a drawn target a press still hits it: 6 pt on macOS;
    /// 14 pt on iOS, so the selected lamp is a 44 pt target (#623 owns the
    /// touch-target pass).
    static var defaultSlop: CGFloat {
        #if os(iOS)
        return 14
        #else
        return 6
        #endif
    }
}

// MARK: - The plan

/// Where the plan draws everything, for a canvas size, an extent (the radius
/// of the outer ring, in scene sizes) and a hit slop. Linear: one scene size
/// is `pointsPerSize` points.
struct OrbitPlanLayout: Equatable {
    var size: CGSize
    /// The outer ring's radius in scene sizes: 4 or 8 (`extent(for:)`).
    var extent: Double
    var slop: CGFloat
    /// The smallest target side (`LightsTouch.minimumTarget`: 44 on iOS, 0
    /// on macOS): every target is hit within at least half of it.
    var minimumTarget: CGFloat

    static let smallExtent = 4.0
    static let largeExtent = 8.0

    init(size: CGSize = LightsOrbitMetrics.planSize, extent: Double,
         slop: CGFloat = LightsOrbitMetrics.defaultSlop,
         minimumTarget: CGFloat = LightsTouch.minimumTarget) {
        self.size = size
        self.extent = extent
        self.slop = slop
        self.minimumTarget = minimumTarget
    }

    /// How far from its centre a lamp drawn at `radius` points is hit.
    func lampReach(_ radius: CGFloat) -> CGFloat {
        LightsTouch.reach(drawn: radius, slop: slop, minimumTarget: minimumTarget)
    }

    /// How far from its centre, per axis, the radius square is hit.
    var squareReach: CGFloat {
        LightsTouch.reach(drawn: LightsOrbitMetrics.squareHalfSide, slop: slop, minimumTarget: minimumTarget)
    }

    /// The extent that shows lights at `radii`: 4 (rings 1× to 4×, sketch 2;
    /// every preset fits) while every radius is at most 4 (within
    /// `LightSnap.tolerance`), 8 (rings 2× to 8×) otherwise. A gesture keeps
    /// the extent it began with, so the plan never rescales under the pointer.
    static func extent(for radii: [Double]) -> Double {
        radii.contains { !($0 <= smallExtent + LightSnap.tolerance) } ? largeExtent : smallExtent
    }

    /// A light at `radius` is drawn on the outer ring rather than where it is
    /// (beyond the extent).
    static func isClamped(radius: Double, extent: Double) -> Bool {
        !(radius <= extent + LightSnap.tolerance)
    }

    /// A light at `radius` is outside what the plan's rings show: beyond the
    /// extent, or nearer than the core's 0.5× (a pinned light near the
    /// centre). Its label then carries its true radius.
    static func isOutOfRange(radius: Double, extent: Double) -> Bool {
        isClamped(radius: radius, extent: extent)
            || radius < LightParameter.radius.range.lowerBound - LightSnap.tolerance
    }

    var centre: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    /// The outer ring, in points.
    var outerRadius: CGFloat { max(min(size.width, size.height) / 2 - LightsOrbitMetrics.planMargin, 1) }
    var pointsPerSize: CGFloat { outerRadius / CGFloat(extent) }
    /// The grey rings, in scene sizes: 1, 2, 3, 4 or 2, 4, 6, 8.
    var rings: [Double] { (1...4).map { Double($0) * extent / 4 } }

    /// `sizes` scene sizes, in points.
    func ringRadius(_ sizes: Double) -> CGFloat { CGFloat(sizes) * pointsPerSize }

    func isClamped(radius: Double) -> Bool { Self.isClamped(radius: radius, extent: extent) }
    func isOutOfRange(radius: Double) -> Bool { Self.isOutOfRange(radius: radius, extent: extent) }

    /// How far from the centre a light at `radius` is drawn: where it is, or
    /// on the outer ring when it is beyond the extent.
    func drawnDistance(radius: Double) -> CGFloat {
        isClamped(radius: radius) ? outerRadius : ringRadius(max(radius, 0))
    }

    /// The point at `distance` points from the centre in the direction of
    /// `orbit` (LightAngles: 0 down, +90 right).
    func point(orbit: Double, distance: CGFloat) -> CGPoint {
        let o = LightAngles.offset(orbit: orbit)
        return CGPoint(x: centre.x + distance * CGFloat(o.dx), y: centre.y + distance * CGFloat(o.dy))
    }

    /// Where the lamp of a light at `orbit` and `radius` is drawn (and hit).
    func lampPoint(orbit: Double, radius: Double) -> CGPoint {
        point(orbit: orbit, distance: drawnDistance(radius: radius))
    }

    /// The orbit of `point` around the centre; nil within
    /// `LightsOrbitMetrics.centreDeadZone` of it.
    func orbit(at point: CGPoint) -> Double? {
        let dx = Double(point.x - centre.x), dy = Double(point.y - centre.y)
        guard (dx * dx + dy * dy).squareRoot() > Double(LightsOrbitMetrics.centreDeadZone) else { return nil }
        return LightAngles.orbit(dx: dx, dy: dy)
    }

    /// The distance of `point` from the centre, in scene sizes (not clamped).
    func radius(at point: CGPoint) -> Double {
        Double(hypot(point.x - centre.x, point.y - centre.y) / pointsPerSize)
    }

    /// How many degrees before its lamp's orbit the radius square of a light
    /// at `radius` sits: 45° (sketch 2) unless the chord from the square to
    /// the lamp would be shorter than two selected-lamp hit radii
    /// (2·R·sin(θ/2) ≥ 2·max(lamp radius + slop, minimum target / 2): 28 pt
    /// on macOS, 44 pt on iOS, as before the touch floor); then the smallest
    /// angle that clears it, at most 180°.
    func squareAngle(radius: Double) -> Double {
        let r = Double(drawnDistance(radius: radius))
        let needed = 2 * Double(max(LightsOrbitMetrics.selectedLampRadius + slop, minimumTarget / 2))
        let preferred = LightsOrbitMetrics.squareAngle
        if 2 * r * sin(preferred / 2 * .pi / 180) >= needed { return preferred }
        guard needed < 2 * r else { return 180 }
        return 2 * asin(needed / (2 * r)) * 180 / .pi
    }

    /// Where the radius square of the selected light is drawn: on its ring
    /// (the outer ring when beyond the extent), `angle` degrees before its
    /// orbit.
    func squarePoint(orbit: Double, radius: Double, angle: Double) -> CGPoint {
        point(orbit: orbit - angle, distance: drawnDistance(radius: radius))
    }
}

// MARK: - The pitch arc

/// Where the pitch arc draws its half circle and handle: centred near the
/// canvas's left edge, -90 at the bottom, 0 to the right (level with the
/// camera), +90 at the top (LightAngles' half dial).
struct PitchArcLayout: Equatable {
    var size: CGSize
    var slop: CGFloat
    /// The smallest target side (`LightsTouch.minimumTarget`).
    var minimumTarget: CGFloat

    /// The arc's ticks (sketch 2).
    static let ticks: [Double] = [-90, -45, 0, 45, 90]

    init(size: CGSize = LightsOrbitMetrics.arcSize, slop: CGFloat = LightsOrbitMetrics.defaultSlop,
         minimumTarget: CGFloat = LightsTouch.minimumTarget) {
        self.size = size
        self.slop = slop
        self.minimumTarget = minimumTarget
    }

    /// How far from its centre the handle is hit.
    var handleReach: CGFloat {
        LightsTouch.reach(drawn: LightsOrbitMetrics.handleRadius, slop: slop, minimumTarget: minimumTarget)
    }

    /// How far from the arc line the track is hit.
    var trackReach: CGFloat {
        LightsTouch.reach(drawn: 0, slop: slop, minimumTarget: minimumTarget)
    }

    var centre: CGPoint { CGPoint(x: LightsOrbitMetrics.arcInset, y: size.height / 2) }
    /// The half ellipse's horizontal radius: out to the canvas's right margin.
    var radiusX: CGFloat {
        max(size.width - LightsOrbitMetrics.arcInset - LightsOrbitMetrics.arcMargin, 1)
    }
    /// Its vertical radius: the full canvas height less the margins, so a
    /// narrow canvas gets a flatter ellipse instead of a small circle (#681).
    var radiusY: CGFloat {
        max(size.height / 2 - LightsOrbitMetrics.arcMargin, 1)
    }

    /// The point of the arc at `pitch`.
    func point(pitch: Double) -> CGPoint {
        let o = LightAngles.offset(pitch: pitch)
        return CGPoint(x: centre.x + radiusX * CGFloat(o.dx), y: centre.y + radiusY * CGFloat(o.dy))
    }

    /// How far `point` is from the arc's ellipse (positive outside, negative
    /// inside): the distance to the nearest point of the full ellipse, found
    /// by a coarse scan and a refinement. Infinite at the centre.
    func distanceToArc(_ point: CGPoint) -> CGFloat {
        let dx = point.x - centre.x, dy = point.y - centre.y
        let f = hypot(dx / radiusX, dy / radiusY)
        guard f > 1e-9 else { return .infinity }
        func gap(_ degrees: Double) -> Double {
            let o = LightAngles.offset(pitch: degrees)
            return hypot(Double(dx - radiusX * CGFloat(o.dx)), Double(dy - radiusY * CGFloat(o.dy)))
        }
        var best = -180.0, bestGap = Double.infinity
        for degrees in stride(from: -180.0, through: 180, by: 2) where gap(degrees) < bestGap {
            best = degrees
            bestGap = gap(degrees)
        }
        var low = best - 2, high = best + 2
        for _ in 0..<30 {
            let m1 = low + (high - low) / 3, m2 = high - (high - low) / 3
            if gap(m1) < gap(m2) { high = m2 } else { low = m1 }
        }
        let nearest = CGFloat(gap((low + high) / 2))
        return f >= 1 ? nearest : -nearest
    }

    /// The pitch of `point` around the centre (the left half clamps to ±90):
    /// the offset is unsquashed by the radii first, so the inverse of
    /// `point(pitch:)` for any ellipse.
    func pitch(at point: CGPoint) -> Double {
        LightAngles.pitch(dx: Double(point.x - centre.x) / Double(radiusX),
                          dy: Double(point.y - centre.y) / Double(radiusY))
    }
}

// MARK: - Hit tests

/// What a press on the orbit view lands on.
enum OrbitTarget: Equatable {
    /// A lamp on the plan (dragging it changes orbit).
    case lamp(name: String, index: Int)
    /// The selected light's radius square (dragging it changes radius).
    case radiusSquare
    /// The pitch arc's handle (dragged with a grab offset).
    case pitchHandle
    /// The pitch arc away from the handle (the handle comes to the pointer).
    case pitchTrack

    /// The one field a drag of this target writes.
    var parameter: LightParameter {
        switch self {
        case .lamp: return .orbit
        case .radiusSquare: return .radius
        case .pitchHandle, .pitchTrack: return .pitch
        }
    }
}

/// Which target a press hits. Targets are hit where they are drawn
/// (out-of-range lamps on the outer ring), within their drawn size plus the
/// layout's slop, and never less than half the layout's minimum target (the
/// 44 pt floor on iOS, LightsTouch). Empty space, the rings, the labels and
/// the 1× disc hit nothing.
enum OrbitHitTest {
    /// The plan target at `point`. Among the targets containing it, the
    /// nearest centre wins; exact ties go to the selected lamp, then the
    /// square, then the lamp drawn last (the later in rig order). So lamps on
    /// one ring and a square next to its lamp stay reachable. `squareAngle`
    /// is the square's angle when it is not `layout.squareAngle(radius:)`
    /// (frozen during a square drag).
    static func plan(at point: CGPoint, layout: OrbitPlanLayout, state: LightsOrbitState,
                     squareAngle: Double? = nil) -> OrbitTarget? {
        var best: (target: OrbitTarget, distance: CGFloat, rank: Int)?
        func consider(_ target: OrbitTarget, _ distance: CGFloat, _ rank: Int) {
            if let b = best, (b.distance, b.rank) <= (distance, rank) { return }
            best = (target, distance, rank)
        }
        for lamp in state.lamps {
            let c = layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            let reach = layout.lampReach(lamp.isSelected ? LightsOrbitMetrics.selectedLampRadius
                                                         : LightsOrbitMetrics.lampRadius)
            let d = hypot(point.x - c.x, point.y - c.y)
            guard d <= reach else { continue }
            consider(.lamp(name: lamp.name, index: lamp.index), d,
                     lamp.isSelected ? 0 : 2 + (state.lamps.count - lamp.index))
        }
        let s = state.selected
        let angle = squareAngle ?? layout.squareAngle(radius: s.radius)
        let c = layout.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle)
        let half = layout.squareReach
        if abs(point.x - c.x) <= half, abs(point.y - c.y) <= half {
            consider(.radiusSquare, hypot(point.x - c.x, point.y - c.y), 1)
        }
        return best?.target
    }

    /// The arc target at `point` for a handle at `pitch`: the handle (drawn
    /// radius plus slop, at least half the minimum target), else the arc
    /// itself (within the slop of it, at least half the minimum target, not
    /// left of the centre), else nil.
    static func pitch(at point: CGPoint, layout: PitchArcLayout, pitch: Double) -> OrbitTarget? {
        let h = layout.point(pitch: pitch)
        if hypot(point.x - h.x, point.y - h.y) <= layout.handleReach {
            return .pitchHandle
        }
        let c = layout.centre
        guard point.x >= c.x,
              abs(layout.distanceToArc(point)) <= layout.trackReach else { return nil }
        return .pitchTrack
    }
}

// MARK: - Gesture sessions

/// One edit a gesture tick asks for: a snapped value of one field.
struct OrbitEdit: Equatable {
    var parameter: LightParameter
    var value: Double
}

/// One drag on the plan or the arc, from the press to the release. Holds what
/// the press fixed: the target, the owner (`beginGesture()`), the layouts
/// (so the extent and the square's angle stay frozen) and the grab offset
/// (the value and the pointer at the press), so a press anywhere inside a
/// target's slop never jumps the light.
struct OrbitDragSession {
    let target: OrbitTarget
    /// The lowercased name of the light the gesture began on.
    let owner: String
    let press: CGPoint
    /// The plan as it was at the press (lamp and square drags).
    let plan: OrbitPlanLayout?
    /// The arc (pitch drags).
    let arc: PitchArcLayout?
    /// The square's angle at the press (plan drags), kept while it is dragged.
    let squareAngle: Double?
    /// The owner's orbit, radius or pitch at the press.
    let valueAtPress: Double
    /// The press's orbit around the plan centre, its distance in scene sizes,
    /// or its pitch around the arc centre (unused on the pitch track).
    let pointerAtPress: Double

    private(set) var lastSent: Double?
    private(set) var hasMoved = false
    private(set) var isEnded = false

    /// The field this session writes.
    var parameter: LightParameter { target.parameter }

    /// A session for `target` pressed at `press`, on the light whose
    /// placement is `placement`. nil when the target's layout is missing
    /// (`plan` for the lamp and the square, `arc` for pitch).
    init?(target: OrbitTarget, owner: String, press: CGPoint, placement: LightPlacement,
          plan: OrbitPlanLayout?, arc: PitchArcLayout?) {
        self.target = target
        self.owner = owner.lowercased()
        self.press = press
        self.plan = plan
        self.arc = arc
        switch target {
        case .lamp:
            guard let plan else { return nil }
            valueAtPress = placement.orbit
            // At the centre a press has no angle: the lamp's own orbit.
            pointerAtPress = plan.orbit(at: press) ?? placement.orbit
        case .radiusSquare:
            guard let plan else { return nil }
            valueAtPress = placement.radius
            pointerAtPress = plan.radius(at: press)
        case .pitchHandle:
            guard let arc else { return nil }
            valueAtPress = placement.pitch
            pointerAtPress = arc.pitch(at: press)
        case .pitchTrack:
            guard arc != nil else { return nil }
            valueAtPress = placement.pitch
            pointerAtPress = 0
        }
        squareAngle = plan?.squareAngle(radius: placement.radius)
    }

    /// The edit for a pointer at `point` (the owner's value now is
    /// `current`), or nil:
    /// - until the pointer has first moved `dragSlop` from the press;
    /// - a lamp pointer within the centre's dead zone;
    /// - when the snapped value is the last one sent or the current one (at
    ///   `LightSnap.tolerance`, orbit around the circle), so a still pointer,
    ///   Float noise on a pinned light and redraws write nothing.
    /// Lamp, square and handle are relative to the press (the grab offset);
    /// the pitch track is absolute. A returned edit counts as sent.
    mutating func move(to point: CGPoint, current: Double?) -> OrbitEdit? {
        guard !isEnded else { return nil }
        if !hasMoved {
            guard hypot(point.x - press.x, point.y - press.y) >= LightsOrbitMetrics.dragSlop else { return nil }
            hasMoved = true
        }
        let snapped: Double?
        switch target {
        case .lamp:
            guard let plan, let angle = plan.orbit(at: point) else { return nil }
            snapped = LightSnap.orbit(valueAtPress + LightAngles.wrap(angle - pointerAtPress))
        case .radiusSquare:
            guard let plan else { return nil }
            snapped = LightSnap.radius(valueAtPress + (plan.radius(at: point) - pointerAtPress))
        case .pitchHandle:
            guard let arc else { return nil }
            snapped = LightSnap.pitch(valueAtPress + (arc.pitch(at: point) - pointerAtPress))
        case .pitchTrack:
            guard let arc else { return nil }
            snapped = LightSnap.pitch(arc.pitch(at: point))
        }
        guard let value = snapped else { return nil }
        let wraps = parameter.wraps
        if let lastSent, LightSnap.same(value, lastSent, wraps: wraps) { return nil }
        if let current, LightSnap.same(value, current, wraps: wraps) { return nil }
        lastSent = value
        return OrbitEdit(parameter: parameter, value: value)
    }

    /// The gesture is over (a refused write, the mode left): nothing more.
    mutating func end() { isEnded = true }
}

/// One touch sequence of a drag on the plan or the arc, told apart from the
/// next by its start location. SwiftUI does not call a gesture's `onEnded`
/// when the gesture is cancelled (a system gesture, an alert, the app going
/// to the background), so a "pressed" flag cleared only there could stay set:
/// the next press would then skip its hit test and drive the cancelled
/// gesture's session (a tap anywhere moving the light dragged before), or do
/// nothing at all. A change whose start differs from the recorded one is a
/// new press, whether or not the previous sequence ended.
struct OrbitTouchSequence: Equatable {
    /// Where the current sequence began; nil between sequences.
    private(set) var start: CGPoint?

    /// A sequence is under way (its press has been handled, hit or miss).
    var isActive: Bool { start != nil }

    /// Records a change of the sequence that began at `start`; true when it
    /// is a new press (no sequence, or another start).
    mutating func isNewPress(startingAt start: CGPoint) -> Bool {
        if self.start == start { return false }
        self.start = start
        return true
    }

    /// The sequence ended normally.
    mutating func end() { start = nil }
}

/// One pinch on the plan: radius only, from the radius at the pinch's start.
struct OrbitPinchSession {
    /// The lowercased name of the light the pinch began on.
    let owner: String
    let radiusAtStart: Double
    private(set) var lastSent: Double?
    private(set) var isEnded = false

    init(owner: String, radiusAtStart: Double) {
        self.owner = owner.lowercased()
        self.radiusAtStart = radiusAtStart
    }

    /// The radius for `magnification` (`LightSnap.pinch`), or nil when it is
    /// the last one sent or `current` (at `LightSnap.tolerance`). A returned
    /// value counts as sent.
    mutating func change(magnification: Double, current: Double?) -> Double? {
        guard !isEnded,
              let value = LightSnap.pinch(start: radiusAtStart, magnification: magnification) else { return nil }
        if let lastSent, LightSnap.same(value, lastSent, wraps: false) { return nil }
        if let current, LightSnap.same(value, current, wraps: false) { return nil }
        lastSent = value
        return value
    }

    mutating func end() { isEnded = true }
}

// MARK: - What the card shows

/// Everything the orbit card shows, worked out from the controller in one
/// place so the tests check it without drawing. nil unless Lights mode is
/// active with a selected light (the inspector's rule).
struct LightsOrbitState: Equatable {
    /// One light on the plan.
    struct Lamp: Equatable, Identifiable {
        var name: String
        var index: Int
        /// The identity colour slot (the bar chip's colour).
        var slot: Int
        /// The current placement: eye space for a pinned light.
        var orbit: Double
        var pitch: Double
        var radius: Double
        var isSelected: Bool
        var isPinned: Bool
        /// Beyond the plan's extent or nearer than 0.5×.
        var isOutOfRange: Bool
        /// Its pitch (`+30°`), plus its true radius when out of range
        /// (`+30° · 12.0×`).
        var labelText: String

        var id: String { name.lowercased() }
    }

    // Titles (spec decision 11), VoiceOver names and identifiers.
    static let orbitTitle = "Orbit"
    static let pitchTitle = "Pitch"
    static let increaseRadiusAction = "Increase radius"
    static let decreaseRadiusAction = "Decrease radius"
    static let identifier = "lights.orbit"
    static let planIdentifier = "lights.orbit.plan"
    static let pitchIdentifier = "lights.orbit.pitch"
    static let collapseIdentifier = "lights.orbit.collapse"
    /// A VoiceOver pitch step, in degrees (the inspector stepper's).
    static let pitchStep = LightsInspectorState.stepperStep

    static func selectAction(_ name: String) -> String { "Select \(name)" }

    static func collapseLabel(collapsed: Bool) -> String {
        collapsed ? "Expand orbit view" : "Collapse orbit view"
    }

    /// A lamp's label: its pitch, and its true radius when out of range.
    static func label(pitch: Double, radius: Double, outOfRange: Bool) -> String {
        let text = LightInspectorFormat.angle(pitch, plus: true)
        return outOfRange ? text + " · " + LightInspectorFormat.radius(radius, frameSize: nil) : text
    }

    /// Every light in rig order.
    var lamps: [Lamp]
    var selected: Lamp
    /// The plan's extent for these lamps (`OrbitPlanLayout.extent(for:)`).
    var extent: Double
    /// The rig's 1× in Å (nil without a frame).
    var frameSize: Double?
    var isOn: Bool
    var canEdit: Bool
    /// The selected light's values as the plan and the arc label them:
    /// `−45°`, `+35°`, `3.0× · 30 Å`.
    var orbitText: String
    var pitchText: String
    var radiusText: String

    @MainActor
    init?(_ controller: LightsController) {
        guard controller.isActive, let index = controller.selectedIndex,
              let lights = controller.rig?.lights, lights.indices.contains(index) else { return nil }
        let placements = lights.indices.map { controller.placement(at: $0) ?? lights[$0].placement }
        let extent = OrbitPlanLayout.extent(for: placements.map(\.radius))
        lamps = lights.enumerated().map { i, light in
            let p = placements[i]
            let out = OrbitPlanLayout.isOutOfRange(radius: p.radius, extent: extent)
            return Lamp(name: light.name, index: i, slot: controller.identitySlot(for: light.name),
                        orbit: p.orbit, pitch: p.pitch, radius: p.radius,
                        isSelected: i == index, isPinned: light.anchor == .pinned,
                        isOutOfRange: out,
                        labelText: Self.label(pitch: p.pitch, radius: p.radius, outOfRange: out))
        }
        selected = lamps[index]
        self.extent = extent
        frameSize = controller.rig?.size
        isOn = controller.isOn
        canEdit = controller.canEdit
        orbitText = LightInspectorFormat.angle(selected.orbit)
        pitchText = LightInspectorFormat.angle(selected.pitch, plus: true)
        radiusText = LightInspectorFormat.radius(selected.radius, frameSize: frameSize)
    }

    /// The lamp of the light called `name` (ignoring case).
    func lamp(named name: String) -> Lamp? {
        lamps.first { $0.name.lowercased() == name.lowercased() }
    }

    /// The lights other than the selected one, in rig order.
    var others: [Lamp] { lamps.filter { !$0.isSelected } }

    /// The collapsed header's one line: `−45° · +35° · 3.0×`.
    var collapsedSummary: String {
        orbitText + " · " + pitchText + " · " + LightInspectorFormat.radius(selected.radius, frameSize: nil)
    }

    // VoiceOver: the card is a container; the plan and the arc are each one
    // adjustable element (the plan steps orbit to the next 15°, the arc pitch
    // by 5°).
    var containerLabel: String { "Orbit view, \(selected.name)" }
    var planLabel: String { "Orbit, \(selected.name)" }
    /// `-45 degrees, 3.0 scene sizes, 30 angstroms`.
    var planValue: String {
        LightInspectorFormat.spokenAngle(selected.orbit) + ", "
            + LightInspectorFormat.spokenRadius(selected.radius, frameSize: frameSize)
    }
    var pitchLabel: String { "Pitch, \(selected.name)" }
    /// `35 degrees`.
    var pitchValue: String { LightInspectorFormat.spokenAngle(selected.pitch) }
    /// The plan's named actions: the radius steps, then `Select <name>` for
    /// each other light.
    var planActions: [String] {
        [Self.increaseRadiusAction, Self.decreaseRadiusAction] + others.map { Self.selectAction($0.name) }
    }

    /// One space-free token for logs and the simulator evidence (logged as
    /// `plan=<summary>`):
    /// `key,orbit:-45.0,pitch:35.0,radius:3.00,extent:4,lamps:key|fill|rim`.
    var summary: String {
        func token(_ name: String) -> String {
            name.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        }
        func num(_ x: Double, _ places: Int) -> String {
            let scale = pow(10.0, Double(places))
            // `+ 0` turns -0 into 0.
            return String(format: "%.\(places)f", (x * scale).rounded() / scale + 0)
        }
        return token(selected.name) + ",orbit:" + num(selected.orbit, 1)
            + ",pitch:" + num(selected.pitch, 1) + ",radius:" + num(selected.radius, 2)
            + ",extent:" + num(extent, 0) + ",lamps:" + lamps.map { token($0.name) }.joined(separator: "|")
    }
}

// MARK: - Interaction

/// Turns what the user does on the card into controller calls. The view, the
/// unit and live tests and the DEBUG gestures all drive this one type:
/// - a press selects the lamp it hits (by name) and starts a session with
///   `beginGesture()` (a tap only selects);
/// - each drag tick or pinch change writes one snapped field through the
///   owner-guarded `set(_:_:owner:)`; any result but `.ok` (the owner is no
///   longer selected, the mode ended, busy, no rig) ends the session;
/// - a lamp drag writes orbit only, the square and a pinch radius only (the
///   core keeps the beam, decision 8), the arc pitch only.
@MainActor
struct LightsOrbitInteraction {
    let controller: LightsController

    /// A press on the plan at `point`, the card showing `state` with
    /// `layout`. nil unless the light can be edited and the press hits a
    /// target. A press on a lamp that is not selected selects it first (nil
    /// when that light is gone); the same drag then orbits it.
    func beginPlan(at point: CGPoint, state: LightsOrbitState,
                   layout: OrbitPlanLayout) -> OrbitDragSession? {
        guard controller.canEdit,
              let target = OrbitHitTest.plan(at: point, layout: layout, state: state) else { return nil }
        if case .lamp(let name, _) = target {
            if !isSelected(name) { controller.select(name: name) }
            guard isSelected(name) else { return nil }
        } else {
            // The square belongs to the light the card showed as selected.
            guard isSelected(state.selected.name) else { return nil }
        }
        return start(target, at: point, plan: layout, arc: nil)
    }

    /// A press on the pitch arc at `point`, the card showing `state`.
    func beginArc(at point: CGPoint, state: LightsOrbitState,
                  layout: PitchArcLayout) -> OrbitDragSession? {
        guard controller.canEdit, isSelected(state.selected.name),
              let target = OrbitHitTest.pitch(at: point, layout: layout, pitch: state.selected.pitch)
        else { return nil }
        return start(target, at: point, plan: nil, arc: layout)
    }

    /// A drag tick at `point`: the write's result, or nil when nothing was
    /// written (inside the slop, no new grid value, or the session is over).
    /// A result other than `.ok`, or the light no longer editable, ends the
    /// session.
    @discardableResult
    func move(_ session: inout OrbitDragSession, to point: CGPoint) -> LightSetResult? {
        guard !session.isEnded else { return nil }
        guard controller.canEdit else {
            session.end()
            return nil
        }
        let current = isSelected(session.owner) ? controller.value(session.parameter) : nil
        guard let edit = session.move(to: point, current: current) else { return nil }
        let result = controller.set(edit.parameter, edit.value, owner: session.owner)
        if result != .ok { session.end() }
        return result
    }

    /// A pinch begins on the selected light (radius only).
    func beginPinch() -> OrbitPinchSession? {
        guard controller.canEdit, let radius = controller.value(.radius),
              let owner = controller.beginGesture() else { return nil }
        return OrbitPinchSession(owner: owner, radiusAtStart: radius)
    }

    /// A pinch change: as `move`, for the radius.
    @discardableResult
    func pinch(_ session: inout OrbitPinchSession, magnification: Double) -> LightSetResult? {
        guard !session.isEnded else { return nil }
        guard controller.canEdit else {
            session.end()
            return nil
        }
        let current = isSelected(session.owner) ? controller.value(.radius) : nil
        guard let value = session.change(magnification: magnification, current: current) else { return nil }
        let result = controller.set(.radius, value, owner: session.owner)
        if result != .ok { session.end() }
        return result
    }

    // VoiceOver: each step names the light its element announces (`owner`)
    // and writes only while that light is still selected.

    /// Orbit to the next 15° grid value.
    @discardableResult
    func stepOrbit(up: Bool, owner: String) -> LightSetResult {
        step(.orbit, owner: owner) { LightSnap.nextOrbit(from: $0, up: up) }
    }

    /// Radius to the next 0.5× grid value.
    @discardableResult
    func stepRadius(up: Bool, owner: String) -> LightSetResult {
        step(.radius, owner: owner) { LightSnap.nextRadius(from: $0, up: up) }
    }

    /// Pitch by ±5° (the inspector stepper's step), clamped into ±90.
    @discardableResult
    func stepPitch(up: Bool, owner: String) -> LightSetResult {
        step(.pitch, owner: owner) {
            LightSnap.pitch($0 + (up ? LightsOrbitState.pitchStep : -LightsOrbitState.pitchStep))
        }
    }

    /// `Select <name>`.
    func select(name: String) {
        controller.select(name: name)
    }

    // MARK: private

    private func isSelected(_ name: String) -> Bool {
        controller.selection.name?.lowercased() == name.lowercased()
    }

    private func start(_ target: OrbitTarget, at point: CGPoint, plan: OrbitPlanLayout?,
                       arc: PitchArcLayout?) -> OrbitDragSession? {
        guard let index = controller.selectedIndex,
              let placement = controller.placement(at: index),
              let owner = controller.beginGesture() else { return nil }
        return OrbitDragSession(target: target, owner: owner, press: point, placement: placement,
                                plan: plan, arc: arc)
    }

    /// A step from the fresh value (a stale mirror and a pinned light's eye
    /// space re-read first). Drops typed inspector text like a gesture.
    private func step(_ parameter: LightParameter, owner: String,
                      next: (Double) -> Double?) -> LightSetResult {
        guard let current = controller.freshValue(parameter),
              isSelected(owner), controller.beginGesture() != nil else { return .badIndex }
        guard let value = next(current) else { return .badValue }
        return controller.set(parameter, value, owner: owner)
    }
}

// MARK: - DEBUG gestures

#if DEBUG
/// Orbit-view gestures a simulator run applies (PYMOL_AUTOLIGHTS_EDIT, debug
/// builds only), driven through LightsOrbitInteraction with the card's own
/// layout, so a run exercises the hit test, the grab offset, the snapping,
/// the owner guard and the write:
/// - `tap:<light>`: press and release on the lamp;
/// - `plan:<light>:<orbit>`: press the lamp's centre, move along its ring
///   towards that orbit in `autoTicks` ticks, release;
/// - `square:<radius>`: press the selected light's square, move radially to
///   that radius at the plan's scale;
/// - `arc:<pitch>`: press the handle, move along the arc to that pitch;
/// - `pinch:<factor>`: a pinch from 1 to that magnification.
enum OrbitAutoGesture: Equatable {
    case tap(String)
    case plan(String, Double)
    case square(Double)
    case arc(Double)
    case pinch(Double)

    static let keys: Set<String> = ["tap", "plan", "square", "arc", "pinch"]

    /// `token`'s key is a gesture's (whether or not the rest parses).
    static func claims(_ token: String) -> Bool {
        let key = token.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return keys.contains(key.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The gesture `token` describes, or nil.
    static func parse(_ token: String) -> OrbitAutoGesture? {
        let parts = token.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.first?.lowercased() else { return nil }
        func number(_ i: Int) -> Double? {
            guard parts.indices.contains(i), let x = Double(parts[i]), x.isFinite else { return nil }
            return x
        }
        switch key {
        case "tap":
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return .tap(parts[1])
        case "plan":
            guard parts.count == 3, !parts[1].isEmpty, let orbit = number(2) else { return nil }
            return .plan(parts[1], orbit)
        case "square":
            guard parts.count == 2, let radius = number(1) else { return nil }
            return .square(radius)
        case "arc":
            guard parts.count == 2, let pitch = number(1) else { return nil }
            return .arc(pitch)
        case "pinch":
            guard parts.count == 2, let factor = number(1), factor > 0 else { return nil }
            return .pinch(factor)
        default:
            return nil
        }
    }

    /// The token as logged.
    var token: String {
        switch self {
        case .tap(let name): return "tap:\(name)"
        case .plan(let name, let orbit): return "plan:\(name):\(Self.fmt(orbit))"
        case .square(let radius): return "square:\(Self.fmt(radius))"
        case .arc(let pitch): return "arc:\(Self.fmt(pitch))"
        case .pinch(let factor): return "pinch:\(Self.fmt(factor))"
        }
    }

    /// Run the gesture on `controller`; one `<token> -> <result> <value>`
    /// line: the last write's result (`none` when nothing was written, `miss`
    /// when the press hit no target) and the selected light's value after.
    /// `planSize` and `arcSize` are the canvases' sizes in the placement that
    /// shows them (the card's by default; #623's sheet and side panel pass
    /// theirs), so a run drives the plan the user sees.
    @MainActor
    static func apply(_ gesture: OrbitAutoGesture, to controller: LightsController,
                      slop: CGFloat = LightsOrbitMetrics.defaultSlop,
                      planSize: CGSize = LightsOrbitMetrics.planSize,
                      arcSize: CGSize = LightsOrbitMetrics.arcSize) -> String {
        let interaction = LightsOrbitInteraction(controller: controller)
        guard let state = LightsOrbitState(controller) else { return "\(gesture.token) -> no_light" }
        let plan = OrbitPlanLayout(size: planSize, extent: state.extent, slop: slop)
        let arc = PitchArcLayout(size: arcSize, slop: slop)
        let ticks = LightsOrbitMetrics.autoTicks
        var last: LightSetResult?
        func drag(_ session: inout OrbitDragSession, _ path: (Double) -> CGPoint) {
            for k in 1...ticks {
                if let result = interaction.move(&session, to: path(Double(k) / Double(ticks))) {
                    last = result
                }
                if session.isEnded { break }
            }
        }
        func outcome(_ parameter: LightParameter) -> String {
            let value = controller.value(parameter).map { fmt(($0 * 100).rounded() / 100 + 0) } ?? "-"
            return "\(gesture.token) -> \(last.map { "\($0)" } ?? "none") \(parameter.field)=\(value)"
        }
        switch gesture {
        case .tap(let name):
            guard let lamp = state.lamp(named: name),
                  interaction.beginPlan(at: plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius),
                                        state: state, layout: plan) != nil
            else { return "\(gesture.token) -> miss" }
            return "\(gesture.token) -> ok selected=\(controller.selection.name ?? "-")"
        case .plan(let name, let orbit):
            guard let lamp = state.lamp(named: name),
                  var session = interaction.beginPlan(
                      at: plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius), state: state, layout: plan),
                  session.target.parameter == .orbit
            else { return "\(gesture.token) -> miss" }
            let distance = plan.drawnDistance(radius: lamp.radius)
            let sweep = LightAngles.wrap(orbit - lamp.orbit)
            drag(&session) { t in plan.point(orbit: lamp.orbit + sweep * t, distance: distance) }
            return outcome(.orbit)
        case .square(let radius):
            let s = state.selected
            let angle = plan.squareAngle(radius: s.radius)
            guard var session = interaction.beginPlan(
                      at: plan.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle),
                      state: state, layout: plan),
                  session.target == .radiusSquare
            else { return "\(gesture.token) -> miss" }
            let from = plan.drawnDistance(radius: s.radius)
            let to = plan.ringRadius(radius)
            drag(&session) { t in plan.point(orbit: s.orbit - angle, distance: from + (to - from) * CGFloat(t)) }
            return outcome(.radius)
        case .arc(let pitch):
            let s = state.selected
            guard var session = interaction.beginArc(at: arc.point(pitch: s.pitch), state: state, layout: arc),
                  session.target == .pitchHandle
            else { return "\(gesture.token) -> miss" }
            drag(&session) { t in arc.point(pitch: s.pitch + (pitch - s.pitch) * t) }
            return outcome(.pitch)
        case .pinch(let factor):
            guard var session = interaction.beginPinch() else { return "\(gesture.token) -> miss" }
            for k in 1...ticks {
                let m = 1 + (factor - 1) * Double(k) / Double(ticks)
                if let result = interaction.pinch(&session, magnification: m) { last = result }
                if session.isEnded { break }
            }
            return outcome(.radius)
        }
    }

    private static func fmt(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(format: "%.0f", x) : String(x)
    }
}
#endif
