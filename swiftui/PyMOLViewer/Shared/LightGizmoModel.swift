// LightGizmoModel.swift — the in-scene light gizmo's model (#622, spec §9,
// the gizmo mock-up).
//
// The gizmo is a SwiftUI Canvas over the viewport, never scene geometry: it
// cannot cast a shadow, enter ray tracing or widen the scene's extent (#610).
// This file holds everything about it that is not drawing or input routing,
// so the unit tests, the live tests, the overlay, the viewport's hit tests and
// the DEBUG simulator hook all run the same code:
// - LightGizmoMetrics: every size (`slop` is the one #623 turns for touch);
// - LightGizmoInputs and LightGizmoLayout: where every knob, label, the aim
//   dot, the rings and their handles are, from the eye-space rig and the
//   projection LightsController publishes (`eye.eyeSpace`, `eye.projection`);
//   nil (nothing drawn, every press to the camera) unless Lights mode shows it;
// - LightGizmoHitTest: which target a press lands on;
// - LightTrackball, LightRingMeasure and LightGizmoDragSession: one drag each,
//   from the press (owner, grab offset, frozen layout) to the rounded,
//   de-duplicated edit of each tick;
// - LightGizmoInteraction: a press, a drag tick, a scroll, a pinch, an
//   option-click or the Shadow chip as LightsController calls;
// - LightGizmoPointer: which input owns a press, from its start to its end;
// - LightGizmoState: the VoiceOver strings, the Shadow chip and a one-token
//   summary for logs.
//
// Every write goes through the shared edit path in LightsEditing.swift:
// `beginGesture()` at the press, then the owner-guarded `setPlacement(…,
// owner:)`, `set(_:_:owner:)` or `setAim(_:owner:)` per tick (bridge setters,
// no Python, #610). The surface pick of an aim drag goes through the
// LightGizmoPicker seam (C++ only, `updateReps: false` in the engine's
// wiring). An option-click is a click, not a tick: it runs #612's `click=`
// helper once through `placeHighlight`. So this file names no Python, console
// or bridge entry point (testing/tests/raymol/lighting_mode.py and
// lighting_gizmo.py check that).
//
// Screen geometry is in view points, top-left origin, y down, as SwiftUI
// draws; eye space is +x right, +y up, +z towards the viewer (spec §4.3). A
// light at orbit o and pitch p sits along (sin o cos p, sin p, cos o cos p)
// from the rig centre; its knob is drawn at C + R (d.x, -d.y) on a display
// sphere of radius R around the projected centre C.

import CoreGraphics
import Foundation

// MARK: - Metrics

/// Every size the gizmo draws and hit-tests with. `slop` (6 pt on macOS,
/// 14 pt on iOS, `LightsOrbitMetrics.defaultSlop`) and `minimumTarget` (0 on
/// macOS, 44 on iOS, `LightsTouch.minimumTarget`) set the hit areas: each
/// target is hit within its drawn size plus the slop, never less than half
/// the minimum target (#623). The rest are the mock-up's.
struct LightGizmoMetrics: Equatable {
    /// How far outside a drawn target a press still hits it.
    var slop: CGFloat
    /// The smallest target side: every knob, the aim dot, each handle and
    /// each ring line is hit within at least half of it.
    var minimumTarget: CGFloat
    /// The drawn radius of a knob, and of the selected one.
    var knobRadius: CGFloat = 7
    var selectedKnobRadius: CGFloat = 9
    /// The drawn radius of the aim dot.
    var aimDotRadius: CGFloat = 4
    /// Half the side of a ring handle (a square).
    var handleHalfSide: CGFloat = 4.5
    /// The handles keep this far from each other and from the aim dot: 12
    /// pt, or the minimum target when larger (44 on iOS: a finger's width
    /// between the two handles).
    var handleSeparation: CGFloat
    /// A drag writes nothing until the pointer is this far from the press.
    var dragSlop: CGFloat = 3
    /// A knob dragged this far outside the sphere's outline swaps sides.
    var band: CGFloat = 14
    /// A dragged knob holds this many degrees off the outline and the poles.
    var silhouetteHold: Double = 2
    /// The display sphere: `sphereScale` times the rig's 1× at the centre's
    /// depth, at least `sphereMinimum` (or the maximum when smaller), at most
    /// `sphereMaximumFraction` of the scene rect's shorter side.
    var sphereScale: Double = 1.2
    var sphereMinimum: CGFloat = 64
    var sphereMaximumFraction: CGFloat = 0.42
    /// Points per ring.
    var ringSamples: Int = 72
    /// Below this |cos| between the press ray and the beam axis, ring drags
    /// are measured on the view plane instead of the aim plane.
    var grazingCos: Double = 0.26
    /// Point targets this close in distance count as tied (then the rank).
    var tieTolerance: CGFloat = 0.5
    /// A trackpad scroll steps the radius once per this many points.
    var trackpadStep: CGFloat = 24
    /// Stroke widths of the outer (solid) and inner (dashed) rings.
    var outerRingWidth: CGFloat = 2
    var innerRingWidth: CGFloat = 1.5
    /// Rings this close to each other where pressed are one target (`.rings`).
    var coincidentRings: CGFloat = 2
    /// Between a knob's edge and its label.
    var labelGap: CGFloat = 4

    init(slop: CGFloat = LightsOrbitMetrics.defaultSlop,
         minimumTarget: CGFloat = LightsTouch.minimumTarget) {
        self.slop = slop
        self.minimumTarget = minimumTarget
        self.handleSeparation = max(12, minimumTarget)
    }

    /// How far from its centre a round target drawn at `radius` is hit.
    func reach(_ radius: CGFloat) -> CGFloat {
        LightsTouch.reach(drawn: radius, slop: slop, minimumTarget: minimumTarget)
    }

    /// How far from its centre, per axis, a ring handle is hit.
    var handleReach: CGFloat { reach(handleHalfSide) }

    /// How far from a ring's line (its centre line) a press hits it.
    func ringReach(width: CGFloat) -> CGFloat { reach(width / 2) }

    /// Knob opacity while the rig is off (still editable).
    static let dimmedOpacity = 0.45
    /// An option-click whose pick faces the camera less than this uses the
    /// rim rule (`rimDegrees`) instead of the mirror rule.
    static let rimFacing: Float = 0.3
    static let rimDegrees = 145.0
    /// An aim pick within this many Å of the last one sent writes nothing.
    static let aimRepeat = 1e-4
    /// Ticks per DEBUG gesture.
    static let autoTicks = 12
}

// MARK: - Inputs

/// The view's edges covered by chrome drawn over the viewport (the macOS
/// Lights bar), in points. The ring handles keep out of them (#693).
struct LightGizmoInsets: Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0
    static let zero = LightGizmoInsets()
}

/// Where the transient readout's box goes during a gizmo drag (#703): at the
/// pointer (the cursor, the finger) with a fixed offset, right of and above
/// it; flipped to the left near the right edge and below near the top; then
/// kept inside the view less its chrome insets and a margin. Top-left points.
enum LightGizmoReadoutPlacement {
    /// The box's offset from the pointer.
    static let offset = CGSize(width: 14, height: 14)
    /// The box keeps this far inside the view (and its insets).
    static let margin: CGFloat = 8

    /// The box's top-left corner for a box of `box` points beside `pointer`
    /// in a view of `viewSize` whose edges `insets` are covered.
    static func origin(pointer: CGPoint, box: CGSize, viewSize: CGSize,
                       insets: LightGizmoInsets = .zero,
                       offset: CGSize = offset, margin: CGFloat = margin) -> CGPoint {
        let minX = insets.left + margin
        let maxX = viewSize.width - insets.right - margin - box.width
        let minY = insets.top + margin
        let maxY = viewSize.height - insets.bottom - margin - box.height
        var x = pointer.x + offset.width
        if x > maxX { x = pointer.x - offset.width - box.width }
        var y = pointer.y - offset.height - box.height
        if y < minY { y = pointer.y + offset.height }
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { hi < lo ? lo : min(max(v, lo), hi) }
        return CGPoint(x: clamp(x, minX, maxX), y: clamp(y, minY, maxY))
    }
}

/// Everything the layout is made from, as a plain value: tests build it
/// without a controller; the overlay and the viewport build it from the same
/// controller, so what is drawn is what is hit-tested.
struct LightGizmoInputs: Equatable {
    /// One rig light, in rig order.
    struct Light: Equatable {
        var name: String
        /// The identity colour slot (the bar chip's colour).
        var slot: Int
        var beam: Double
        var softness: Double
        var shadow: Bool
    }

    var isActive: Bool
    /// A movie export holds the rig.
    var isBusy: Bool
    /// The rig is on (off: knobs dimmed, still editable).
    var isOn: Bool
    var lights: [Light]
    var selection: LightSelection
    /// The rig's 1× in Å (nil without a frame).
    var rigSize: Double?
    var eyeSpace: LightEyeSpace?
    var projection: LightCameraProjection?
    /// The overlay's size (the viewport's bounds), in points.
    var viewSize: CGSize
    /// `grid_mode` is on: each cell has its own view, which the whole-view
    /// projection cannot match, so the gizmo hides.
    var gridMode: Bool
    /// The scene's Shadows switch as last read (nil: unknown).
    var sceneShadowsOn: Bool?
    /// Edges covered by chrome drawn over the viewport (#693).
    var chromeInsets: LightGizmoInsets

    init(isActive: Bool, isBusy: Bool, isOn: Bool, lights: [Light], selection: LightSelection,
         rigSize: Double?, eyeSpace: LightEyeSpace?, projection: LightCameraProjection?,
         viewSize: CGSize, gridMode: Bool, sceneShadowsOn: Bool?,
         chromeInsets: LightGizmoInsets = .zero) {
        self.isActive = isActive
        self.isBusy = isBusy
        self.isOn = isOn
        self.lights = lights
        self.selection = selection
        self.rigSize = rigSize
        self.eyeSpace = eyeSpace
        self.projection = projection
        self.viewSize = viewSize
        self.gridMode = gridMode
        self.sceneShadowsOn = sceneShadowsOn
        self.chromeInsets = chromeInsets
    }

    /// The controller's state now, for a view of `viewSize` points.
    @MainActor
    init(controller: LightsController, viewSize: CGSize, gridMode: Bool, sceneShadowsOn: Bool?,
         chromeInsets: LightGizmoInsets = .zero) {
        self.init(
            isActive: controller.isActive, isBusy: controller.isBusy, isOn: controller.isOn,
            lights: (controller.rig?.lights ?? []).map {
                Light(name: $0.name, slot: controller.identitySlot(for: $0.name), beam: $0.beam,
                      softness: $0.softness, shadow: $0.shadow)
            },
            selection: controller.selection, rigSize: controller.rig?.size,
            eyeSpace: controller.eye.eyeSpace, projection: controller.eye.projection,
            viewSize: viewSize, gridMode: gridMode, sceneShadowsOn: sceneShadowsOn,
            chromeInsets: chromeInsets)
    }
}

// MARK: - Layout

/// Where the gizmo draws everything (and so where it is hit), for one frame.
struct LightGizmoLayout: Equatable {
    /// One light's knob on the display sphere.
    struct Knob: Equatable, Identifiable {
        var name: String
        var index: Int
        var slot: Int
        var centre: CGPoint
        /// The drawn radius (larger when selected).
        var radius: CGFloat
        /// The unit offset from the rig centre in eye space.
        var direction: SIMD3<Double>
        /// Its current orbit, pitch and radius (a pinned light's from eye
        /// space).
        var placement: LightPlacement
        var isSelected: Bool
        /// Behind the molecule (`LightDepth`): drawn hollow and dashed.
        var isBehind: Bool
        /// The light casts a shadow: the knob carries a small dark crescent,
        /// dimmed while the scene's Shadows switch is off.
        var isShadowed: Bool
        var isShadowDimmed: Bool
        /// 1, or `LightGizmoMetrics.dimmedOpacity` while the rig is off.
        var opacity: Double
        /// The name, plus the radius for the selected light (`key 3.0×`).
        var label: String
        /// Just outside the knob, away from the sphere's centre.
        var labelPoint: CGPoint
        /// Unit, from the sphere's centre through the knob (up at the centre).
        var labelDirection: CGVector

        var id: String { name.lowercased() }
    }

    /// One ring: the beam cone's section in the plane through the aim point
    /// normal to the beam axis, as drawn.
    struct Ring: Equatable {
        /// Its radius in that plane, Å.
        var radius: Double
        /// `samples` projected points around it (closed); nil where a point
        /// does not project (behind the eye).
        var samples: [CGPoint?]

        /// The drawable segments: consecutive samples (closing the loop),
        /// skipping any with an end that does not project.
        var segments: [(CGPoint, CGPoint)] {
            guard samples.count > 1 else { return [] }
            return samples.indices.compactMap { i in
                guard let a = samples[i], let b = samples[(i + 1) % samples.count] else { return nil }
                return (a, b)
            }
        }

        /// The rightmost projected sample (where its handle sits).
        var rightmost: CGPoint? {
            samples.compactMap { $0 }.max { $0.x < $1.x }
        }
    }

    /// A ring's handle.
    struct Handle: Equatable {
        /// Where it is drawn (and hit).
        var point: CGPoint
        /// Where on its ring it belongs: the rightmost sample, or, when
        /// handles there would leave the view or fall under chrome, the best
        /// candidate sample keeping handles in view (#693).
        var ringPoint: CGPoint
        /// Drawn away from its ring (the separation rule), joined by a tick.
        var isOffRing: Bool
    }

    /// What only the selected light shows.
    struct Selected: Equatable {
        var name: String
        var index: Int
        var placement: LightPlacement
        var beam: Double
        var softness: Double
        /// Eye space: the aim point, the unit beam axis and their distance.
        var target: SIMD3<Double>
        var direction: SIMD3<Double>
        var aimDistance: Double
        var cosOuter: Double
        var cosInner: Double
        /// nil when the aim point does not project; then no rings either.
        var aimDot: CGPoint?
        /// nil when the aim point is on the light or does not project.
        var outerRing: Ring?
        var innerRing: Ring?
        var outerHandle: Handle?
        var innerHandle: Handle?
    }

    let projection: LightGizmoProjection
    let metrics: LightGizmoMetrics
    /// The rig centre, projected.
    let centre: CGPoint
    /// The display sphere's radius, in points.
    let sphereRadius: CGFloat
    /// Every light, in rig order.
    let knobs: [Knob]
    /// Indices into `knobs` in drawing order: behind knobs in rig order,
    /// front knobs in rig order, then the selected knob.
    let drawingOrder: [Int]
    let selected: Selected?
    let isOn: Bool
    /// The rig's 1× in Å.
    let rigSize: Double?

    /// The unit offset of (orbit, pitch) degrees from the rig centre in eye
    /// space: (sin o cos p, sin p, cos o cos p).
    static func direction(orbit: Double, pitch: Double) -> SIMD3<Double> {
        let o = orbit * .pi / 180, p = pitch * .pi / 180
        return SIMD3(sin(o) * cos(p), sin(p), cos(o) * cos(p))
    }

    /// The layout for `inputs`, or nil (nothing drawn, every press goes to
    /// the camera) unless Lights mode is active, the rig is not busy (a movie
    /// export), has lights, the eye space and projection are published and
    /// describe this rig, grid mode is off, and the rig centre projects.
    static func make(_ inputs: LightGizmoInputs,
                     metrics: LightGizmoMetrics = LightGizmoMetrics()) -> LightGizmoLayout? {
        guard inputs.isActive, !inputs.isBusy, !inputs.gridMode, !inputs.lights.isEmpty,
              let eye = inputs.eyeSpace, eye.hasFrame, eye.lights.count == inputs.lights.count,
              let camera = inputs.projection,
              let projection = LightGizmoProjection(camera: camera, viewSize: inputs.viewSize)
        else { return nil }
        let centreEye = SIMD3<Double>(eye.centre)
        guard let centre = projection.point(eye: centreEye),
              centre.x.isFinite, centre.y.isFinite,
              let perAngstrom = projection.pointsPerAngstrom(atDepth: centreEye.z) else { return nil }

        // The display sphere.
        let maxR = metrics.sphereMaximumFraction
            * min(projection.sceneRect.width, projection.sceneRect.height)
        let wanted = CGFloat(metrics.sphereScale * Double(eye.size) * perAngstrom)
        let sphereRadius = min(max(wanted.isFinite ? wanted : 0, min(metrics.sphereMinimum, maxR)), maxR)
        guard sphereRadius > 0 else { return nil }

        let selectedIndex = inputs.selection.index.flatMap { inputs.lights.indices.contains($0) ? $0 : nil }
        let shadowDimmed = inputs.sceneShadowsOn == false
        var knobs: [Knob] = []
        for (i, light) in inputs.lights.enumerated() {
            let seen = eye.lights[i]
            let placement = LightPlacement(seen)
            let d = direction(orbit: placement.orbit, pitch: placement.pitch)
            let point = CGPoint(x: centre.x + sphereRadius * CGFloat(d.x),
                                y: centre.y - sphereRadius * CGFloat(d.y))
            let isSelected = i == selectedIndex
            let radius = isSelected ? metrics.selectedKnobRadius : metrics.knobRadius
            let out = CGVector(dx: point.x - centre.x, dy: point.y - centre.y)
            let length = hypot(out.dx, out.dy)
            let unit = length > 1e-6 ? CGVector(dx: out.dx / length, dy: out.dy / length) : CGVector(dx: 0, dy: -1)
            let reach = radius + metrics.labelGap
            let label = isSelected
                ? light.name + " " + LightInspectorFormat.radius(placement.radius, frameSize: nil)
                : light.name
            knobs.append(Knob(
                name: light.name, index: i, slot: light.slot, centre: point, radius: radius,
                direction: d, placement: placement, isSelected: isSelected,
                isBehind: LightDepth.isBehind(placement), isShadowed: light.shadow,
                isShadowDimmed: light.shadow && shadowDimmed,
                opacity: inputs.isOn ? 1 : LightGizmoMetrics.dimmedOpacity,
                label: label,
                labelPoint: CGPoint(x: point.x + reach * unit.dx, y: point.y + reach * unit.dy),
                labelDirection: unit))
        }
        let others = knobs.indices.filter { $0 != selectedIndex }
        let drawingOrder = others.filter { knobs[$0].isBehind } + others.filter { !knobs[$0].isBehind }
            + (selectedIndex.map { [$0] } ?? [])

        var selected: Selected?
        if let index = selectedIndex {
            selected = Self.selected(index: index, light: inputs.lights[index], eye: eye.lights[index],
                                     projection: projection, metrics: metrics, insets: inputs.chromeInsets)
        }
        return LightGizmoLayout(projection: projection, metrics: metrics, centre: centre,
                                sphereRadius: sphereRadius, knobs: knobs, drawingOrder: drawingOrder,
                                selected: selected, isOn: inputs.isOn, rigSize: inputs.rigSize)
    }

    /// The selected light's aim dot, rings and handles.
    private static func selected(index: Int, light: LightGizmoInputs.Light, eye: LightEyeSpace.Light,
                                 projection: LightGizmoProjection,
                                 metrics: LightGizmoMetrics,
                                 insets: LightGizmoInsets) -> Selected {
        let target = SIMD3<Double>(eye.target)
        let direction = SIMD3<Double>(eye.direction)
        var s = Selected(name: light.name, index: index, placement: LightPlacement(eye),
                         beam: light.beam, softness: light.softness, target: target,
                         direction: direction, aimDistance: Double(eye.aimDistance),
                         cosOuter: Double(eye.cosOuter), cosInner: Double(eye.cosInner),
                         aimDot: projection.point(eye: target))
        guard let aim = s.aimDot, s.aimDistance >= 1e-3,
              let outer = ring(cos: s.cosOuter, s, projection, metrics),
              let inner = ring(cos: s.cosInner, s, projection, metrics),
              let o = outer.rightmost else { return s }
        s.outerRing = outer
        s.innerRing = inner
        var handles = Self.handles(aim: aim, outer: o, inner: inner.rightmost ?? aim, metrics: metrics)
        // #693: handles at the rightmost samples can leave the view (a wide
        // beam, a light near the right edge) or fall under chrome (the macOS
        // Lights bar). In priority order:
        // 1. Keep the rightmost-sample handles if both lie inside allowed bounds.
        // 2. Otherwise, pick the rightmost sample index whose candidate handles
        //    both lie inside allowed bounds.
        // 3. Fallback: among indices whose candidate outer handle lies inside
        //    allowed bounds, choose the one whose outer sample is nearest the
        //    aim dot (ties within 0.5 pt go to the larger sample x, then lower k).
        // 4. Otherwise, keep the rightmost-sample handles.
        var allowed = CGRect(origin: .zero, size: projection.viewSize)
        allowed.origin.x += insets.left
        allowed.origin.y += insets.top
        allowed.size.width -= insets.left + insets.right
        allowed.size.height -= insets.top + insets.bottom
        allowed = allowed.insetBy(dx: metrics.handleReach, dy: metrics.handleReach)

        func insideBoth(_ h: (outer: Handle, inner: Handle)) -> Bool {
            allowed.contains(h.outer.point) && allowed.contains(h.inner.point)
        }

        if !insideBoth(handles) {
            // Both rings share the basis and the sample count, so index k is
            // the same direction on each.
            typealias Candidate = (k: Int, ring: CGPoint, handles: (outer: Handle, inner: Handle))
            let candidates = outer.samples.indices.compactMap { k -> Candidate? in
                guard let ok = outer.samples[k] else { return nil }
                let ik = (inner.samples.indices.contains(k) ? inner.samples[k] : nil) ?? aim
                return (k, ok, Self.handles(aim: aim, outer: ok, inner: ik, metrics: metrics))
            }
            // Rightmost first, ties to the lower index.
            func righter(_ a: Candidate, _ b: Candidate) -> Bool {
                a.ring.x != b.ring.x ? a.ring.x > b.ring.x : a.k < b.k
            }
            if let best = candidates.filter({ insideBoth($0.handles) }).sorted(by: righter).first {
                handles = best.handles
            } else {
                let visible = candidates.filter { allowed.contains($0.handles.outer.point) }
                if let nearest = visible.map({ gizmoDistance($0.ring, aim) }).min(),
                   let best = visible.filter({ gizmoDistance($0.ring, aim) - nearest <= 0.5 })
                       .sorted(by: righter).first {
                    handles = best.handles
                }
            }
        }
        s.outerHandle = handles.outer
        s.innerHandle = handles.inner
        return s
    }

    /// The handles for ring points `o` (outer) and `i` (inner), after the
    /// separation rule (mock-up items 2 and 3): the outer handle at least 2s
    /// from the aim dot, the inner one at least s from the aim dot and from
    /// the outer handle, so both stay reachable when the rings coincide
    /// (softness 0) and when the inner ring collapses onto the aim dot
    /// (softness 1).
    private static func handles(aim: CGPoint, outer o: CGPoint, inner i: CGPoint,
                                metrics: LightGizmoMetrics) -> (outer: Handle, inner: Handle) {
        let sep = Double(metrics.handleSeparation)
        let outerVector = gizmoVector(aim, o)
        let outerLength = gizmoLength(outerVector)
        let outerUnit = outerLength > 1e-9 ? outerVector / outerLength : SIMD2(1, 0)
        let outerAt = max(outerLength, 2 * sep)
        let outerPoint = gizmoPoint(aim, outerUnit * outerAt)
        let innerVector = gizmoVector(aim, i)
        let innerLength = gizmoLength(innerVector)
        let innerUnit = innerLength > 1e-9 ? innerVector / innerLength : outerUnit
        let innerAt = min(max(innerLength, sep), outerAt - sep)
        let innerPoint = gizmoPoint(aim, innerUnit * innerAt)
        return (Handle(point: outerPoint, ringPoint: o, isOffRing: gizmoDistance(outerPoint, o) > 0.5),
                Handle(point: innerPoint, ringPoint: i, isOffRing: gizmoDistance(innerPoint, i) > 0.5))
    }

    /// The cone's section at cosine `cos` around the selected light's aim
    /// point: radius aimDistance tan(acos(cos)), sampled with the
    /// prototype's basis (u = unit(axis × (|axis.y| < 0.9 ? Y : X)),
    /// v = axis × u). nil for a cone the plane cannot cut (90° or wider).
    private static func ring(cos c: Double, _ s: Selected, _ projection: LightGizmoProjection,
                             _ metrics: LightGizmoMetrics) -> Ring? {
        let clamped = min(max(c, -1), 1)
        guard clamped > 1e-6 else { return nil }
        let radius = s.aimDistance * tan(acos(clamped))
        guard radius.isFinite, radius >= 0 else { return nil }
        let axis = s.direction
        let helper: SIMD3<Double> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = gizmoUnit3(gizmoCross(axis, helper))
        let v = gizmoCross(axis, u)
        let n = max(metrics.ringSamples, 3)
        let samples: [CGPoint?] = (0..<n).map { k in
            let theta = 2 * Double.pi * Double(k) / Double(n)
            return projection.point(eye: s.target + radius * (cos(theta) * u + sin(theta) * v))
        }
        return Ring(radius: radius, samples: samples)
    }

    // MARK: lookups

    /// The knob of the light called `name` (ignoring case).
    func knob(named name: String) -> Knob? {
        knobs.first { $0.name.lowercased() == name.lowercased() }
    }

    /// The line from the selected knob to the aim dot.
    var aimLine: (from: CGPoint, to: CGPoint)? {
        guard let s = selected, let aim = s.aimDot, knobs.indices.contains(s.index) else { return nil }
        return (knobs[s.index].centre, aim)
    }

    /// The band's outline (drawn faintly while a knob is dragged), points.
    var bandRadius: CGFloat { sphereRadius + metrics.band }

    // MARK: the transient readout

    /// What a drag of `target` shows next to the pointer: `Orbit −60° ·
    /// Pitch +25°`, `Beam 30°`, `Softness 0.60` (both for coincident rings);
    /// nil for the aim dot.
    func readout(for target: LightGizmoTarget) -> String? {
        let size = rigSize
        func text(_ p: LightParameter, _ v: Double) -> String {
            p.label + " " + LightInspectorFormat.text(p, v, frameSize: size)
        }
        switch target {
        case .knob(let name):
            guard let knob = knob(named: name) else { return nil }
            return text(.orbit, knob.placement.orbit) + " · " + text(.pitch, knob.placement.pitch)
        case .outerHandle, .outerRing:
            return selected.map { text(.beam, $0.beam) }
        case .innerHandle, .innerRing:
            return selected.map { text(.softness, $0.softness) }
        case .rings:
            return selected.map { text(.beam, $0.beam) + " · " + text(.softness, $0.softness) }
        case .aimDot:
            return nil
        }
    }

    /// The readout of a scroll or pinch on the knob of `name`: `Radius 2.5× ·
    /// 25 Å`.
    func radiusReadout(_ name: String) -> String? {
        knob(named: name).map {
            LightParameter.radius.label + " "
                + LightInspectorFormat.text(.radius, $0.placement.radius, frameSize: rigSize)
        }
    }
}

// MARK: - Hit test

/// What a press on the gizmo lands on.
enum LightGizmoTarget: Hashable {
    /// The selected light's aim dot (dragging it re-aims through a pick).
    case aimDot
    /// The ring handles: beam (outer) and softness (inner).
    case outerHandle
    case innerHandle
    /// A light's knob (dragging it moves the light around the sphere).
    case knob(String)
    /// The ring lines away from their handles.
    case outerRing
    case innerRing
    /// Both rings where they coincide (softness near 0): the first move
    /// decides (inwards softness, outwards beam).
    case rings
}

/// The cursor the viewport shows over the light gizmo (#701).
enum LightGizmoCursorKind: Equatable {
    /// Unchanged: whatever the viewport shows today.
    case normal
    /// Over a target a press would take.
    case openHand
    /// Dragging a target.
    case closedHand

    /// The cursor for `mode`, the target under the pointer and whether the
    /// gizmo owns a press. Only Lights mode changes the cursor.
    static func cursor(mode: InteractionMode, hovered: LightGizmoTarget?, isDragging: Bool) -> LightGizmoCursorKind {
        guard mode == .lights else { return .normal }
        if isDragging { return .closedHand }
        return hovered == nil ? .normal : .openHand
    }
}

/// Which target a point lands on: section 4.7 of the plan.
/// 1. Point targets (the aim dot, the handles, the knobs) within their reach
///    (drawn size plus the slop, at least half the minimum target: 22 pt on
///    iOS, #623), ranked by the distance outside their drawn shape (0
///    inside): the smallest wins (within `tieTolerance`), then the lowest rank
///    (aim dot 0, inner handle 1, outer handle 2, selected knob 3, front knobs
///    4, behind knobs 5), then the later in drawing order. A press inside a
///    knob always takes it, and an aim dot under a knob stays reachable at its
///    centre.
/// 2. Only when no point target is in reach: the ring lines, within half the
///    stroke plus the slop (at least half the minimum target), by distance
///    minus half the stroke; the nearer wins, and both within
///    `coincidentRings` of each other there is `.rings`.
/// 3. Otherwise nil: ring interiors, the outline, labels and empty space keep
///    the camera gesture.
enum LightGizmoHitTest {
    private struct Candidate {
        var target: LightGizmoTarget
        var margin: CGFloat
        var rank: Int
        var order: Int
    }

    static func target(at p: CGPoint, layout: LightGizmoLayout) -> LightGizmoTarget? {
        if let hit = best(pointCandidates(at: p, layout: layout, knobsOnly: false), layout) {
            return hit
        }
        return ring(at: p, layout: layout)
    }

    /// The light whose knob is at `p` (knobs only, the same rules): what a
    /// scroll or a pinch acts on.
    static func knob(at p: CGPoint, layout: LightGizmoLayout) -> String? {
        if case .knob(let name)? = best(pointCandidates(at: p, layout: layout, knobsOnly: true), layout) {
            return name
        }
        return nil
    }

    private static func best(_ candidates: [Candidate], _ layout: LightGizmoLayout) -> LightGizmoTarget? {
        guard let least = candidates.map(\.margin).min() else { return nil }
        let pool = candidates.filter { $0.margin <= least + layout.metrics.tieTolerance }
        return pool.min { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.order > b.order
        }?.target
    }

    private static func pointCandidates(at p: CGPoint, layout: LightGizmoLayout,
                                        knobsOnly: Bool) -> [Candidate] {
        let metrics = layout.metrics
        var out: [Candidate] = []
        let n = layout.knobs.count
        for (order, index) in layout.drawingOrder.enumerated() {
            let knob = layout.knobs[index]
            let d = gizmoDistance(p, knob.centre)
            guard d <= metrics.reach(knob.radius) else { continue }
            let m = max(0, d - knob.radius)
            let rank = knob.isSelected ? 3 : (knob.isBehind ? 5 : 4)
            out.append(Candidate(target: .knob(knob.name), margin: m, rank: rank, order: order))
        }
        guard !knobsOnly, let s = layout.selected else { return out }
        if let aim = s.aimDot {
            let d = gizmoDistance(p, aim)
            if d <= metrics.reach(metrics.aimDotRadius) {
                let m = max(0, d - metrics.aimDotRadius)
                out.append(Candidate(target: .aimDot, margin: m, rank: 0, order: n + 2))
            }
        }
        let half = metrics.handleHalfSide
        for (handle, target, rank) in [(s.innerHandle, LightGizmoTarget.innerHandle, 1),
                                       (s.outerHandle, LightGizmoTarget.outerHandle, 2)] {
            guard let h = handle?.point else { continue }
            let axis = max(abs(p.x - h.x), abs(p.y - h.y))
            guard axis <= metrics.handleReach else { continue }
            let m = max(axis - half, 0)
            out.append(Candidate(target: target, margin: m, rank: rank, order: n + 2 - rank))
        }
        return out
    }

    private static func ring(at p: CGPoint, layout: LightGizmoLayout) -> LightGizmoTarget? {
        guard let s = layout.selected, let outer = s.outerRing, let inner = s.innerRing else { return nil }
        let metrics = layout.metrics
        let o = nearest(p, on: outer)
        let i = nearest(p, on: inner)
        let mo = o.map { max(0, $0.distance - metrics.outerRingWidth / 2) }
        let mi = i.map { max(0, $0.distance - metrics.innerRingWidth / 2) }
        let outerHit = o.map { $0.distance <= metrics.ringReach(width: metrics.outerRingWidth) } ?? false
        let innerHit = i.map { $0.distance <= metrics.ringReach(width: metrics.innerRingWidth) } ?? false
        switch (outerHit, innerHit) {
        case (true, true):
            if let o, let near = nearest(o.point, on: inner), near.distance <= layout.metrics.coincidentRings {
                return .rings
            }
            return mi! < mo! ? .innerRing : .outerRing
        case (true, false): return .outerRing
        case (false, true): return .innerRing
        case (false, false): return nil
        }
    }

    /// The nearest point of `ring`'s drawn segments to `p`, and its distance.
    static func nearest(_ p: CGPoint, on ring: LightGizmoLayout.Ring) -> (point: CGPoint, distance: CGFloat)? {
        var best: (point: CGPoint, distance: CGFloat)?
        for (a, b) in ring.segments {
            let q = closest(p, a, b)
            let d = gizmoDistance(p, q)
            if best == nil || d < best!.distance { best = (q, d) }
        }
        return best
    }

    private static func closest(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return a }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1)
        return CGPoint(x: a.x + t * abx, y: a.y + t * aby)
    }
}

// MARK: - The knob trackball

/// A knob drag on the display sphere (plan 4.8). The press freezes the
/// sphere, the side (front or behind) and the grab offset (knob minus press),
/// so a press anywhere on a knob never jumps it. Each tick maps the pointer
/// (plus the grab) onto the sphere on the session's side, holding the knob
/// `silhouetteHold` degrees off the outline and the poles, so |dz| ≥ sin 2°:
/// rounding to 1° then never crosses the outline (|orbit| ≤ 88° in front,
/// ≥ 92° behind, |pitch| ≤ 88°). Outside the outline the knob stays on it at
/// the pointer's angle. The first time the pointer is more than `band` points
/// outside in one excursion, the side flips (key to rim in one drag); the
/// excursion ends when the pointer is back inside the outline.
struct LightTrackball: Equatable {
    let centre: CGPoint
    let radius: CGFloat
    let band: CGFloat
    /// Degrees.
    let hold: Double
    /// The knob minus the press.
    let grab: CGVector
    /// +1 in front, -1 behind.
    private(set) var hemisphere: Double
    /// The pointer is outside the outline (an excursion).
    private(set) var isOutside = false
    /// This excursion has flipped the side already.
    private(set) var hasFlipped = false

    init(centre: CGPoint, radius: CGFloat, knob: CGPoint, press: CGPoint, behind: Bool,
         metrics: LightGizmoMetrics) {
        self.centre = centre
        self.radius = radius
        self.band = metrics.band
        self.hold = metrics.silhouetteHold
        self.grab = CGVector(dx: knob.x - press.x, dy: knob.y - press.y)
        self.hemisphere = behind ? -1 : 1
    }

    var isBehind: Bool { hemisphere < 0 }

    /// The unit eye-space direction for a pointer at `pointer` (and the
    /// band's side flip).
    mutating func direction(at pointer: CGPoint) -> SIMD3<Double> {
        let ux = Double(pointer.x + grab.dx - centre.x) / Double(radius)
        let uy = -Double(pointer.y + grab.dy - centre.y) / Double(radius)
        let rho = (ux * ux + uy * uy).squareRoot()
        if rho > 1 {
            if !isOutside {
                isOutside = true
                hasFlipped = false
            }
            if !hasFlipped, rho > 1 + Double(band / radius) {
                hemisphere = -hemisphere
                hasFlipped = true
            }
        } else if rho < 1 {
            isOutside = false
            hasFlipped = false
        }
        let s = sin(hold * .pi / 180)
        if rho <= 1 {
            let dz = hemisphere * max((max(0, 1 - rho * rho)).squareRoot(), s)
            guard rho > 0 else { return SIMD3(0, 0, dz) }
            let scale = (max(0, 1 - dz * dz)).squareRoot() / rho
            return SIMD3(ux * scale, uy * scale, dz)
        }
        let c = cos(hold * .pi / 180)
        return SIMD3(ux / rho * c, uy / rho * c, hemisphere * s)
    }

    /// Where the pointer goes for the knob to sit along `direction` on the
    /// session's side (the inverse of `direction(at:)` inside the outline).
    func pointer(for direction: SIMD3<Double>) -> CGPoint {
        CGPoint(x: centre.x + radius * CGFloat(direction.x) - grab.dx,
                y: centre.y - radius * CGFloat(direction.y) - grab.dy)
    }

    /// Orbit and pitch in degrees of a unit direction, rounded to 1°: pitch
    /// asin(dy), orbit atan2(dx, dz) (`orbit` kept at a pole).
    static func angles(of d: SIMD3<Double>, keeping orbit: Double) -> (orbit: Double, pitch: Double) {
        let pitch = asin(min(max(d.y, -1), 1)) * 180 / .pi
        let raw = hypot(d.x, d.z) < 1e-6 ? orbit : atan2(d.x, d.z) * 180 / .pi
        return (LightAngles.wrap(LightParameter.orbit.rounded(raw)) + 0,
                LightParameter.pitch.rounded(pitch) + 0)
    }
}

// MARK: - Ring measure

/// How far from the aim point a pointer is, in Å, for a ring drag (plan
/// 4.9): the pointer's camera ray meets the aim plane (through the aim point,
/// normal to the beam axis), or, when the press ray grazes it (|cos| under
/// `grazingCos`), the view plane through the aim point. Chosen once at the
/// press, so the redrawn ring passes under the pointer on the aim plane
/// (oblique rings included) and edge-on rings stay usable.
struct LightRingMeasure: Equatable {
    let projection: LightGizmoProjection
    let target: SIMD3<Double>
    let normal: SIMD3<Double>
    let usesAimPlane: Bool

    init?(projection: LightGizmoProjection, target: SIMD3<Double>, axis: SIMD3<Double>,
          press: CGPoint, grazingCos: Double) {
        guard let ray = projection.ray(at: press) else { return nil }
        let n = gizmoUnit3(axis)
        guard n.x.isFinite, n.y.isFinite, n.z.isFinite else { return nil }
        self.projection = projection
        self.target = target
        usesAimPlane = abs(gizmoDot(ray.direction, n)) >= grazingCos
        normal = usesAimPlane ? n : SIMD3(0, 0, 1)
    }

    /// The distance from the aim point to where the ray through `p` meets the
    /// plane; nil when the ray is parallel to it or meets it behind its origin.
    func radius(at p: CGPoint) -> Double? {
        guard let ray = projection.ray(at: p) else { return nil }
        let denom = gizmoDot(ray.direction, normal)
        guard abs(denom) > 1e-9 else { return nil }
        let t = gizmoDot(target - ray.origin, normal) / denom
        guard t > 0, t.isFinite else { return nil }
        let hit = ray.origin + t * ray.direction
        let r = gizmoLength3(hit - target)
        return r.isFinite ? r : nil
    }
}

// MARK: - Drag sessions

/// What a drag tick asks for.
enum LightGizmoStep: Equatable {
    /// Move the light (`setPlacement(orbit:pitch:owner:)`).
    case placement(orbit: Double, pitch: Double)
    /// Set the beam (degrees) or the softness.
    case beam(Double)
    case softness(Double)
    /// Pick the surface at this view point and aim there.
    case aim(at: CGPoint)
}

/// The owner's values now, for de-duplication (nil: not the owner).
struct LightGizmoCurrent: Equatable {
    var placement: LightPlacement?
    var beam: Double?
    var softness: Double?
}

/// One drag of a gizmo target, from the press to the release (plan 4.8 to
/// 4.10). Holds what the press fixed: the target, the owner
/// (`beginGesture()`), the layout, the trackball or ring measure and the grab
/// offsets. Writes nothing until the pointer has moved `dragSlop`, and never
/// a value equal to the last one sent or the owner's current one.
struct LightGizmoDragSession {
    enum Mode: Equatable {
        case knob, outer, inner, aim
        /// Coincident rings, until the first move decides.
        case rings
    }

    let target: LightGizmoTarget
    /// The lowercased name of the light the gesture began on.
    let owner: String
    let press: CGPoint
    /// The layout at the press (frozen for the whole drag).
    let layout: LightGizmoLayout
    private(set) var mode: Mode
    private(set) var trackball: LightTrackball?
    let measure: LightRingMeasure?
    /// The drawn ring's radius minus the measured one at the press, per ring
    /// (also absorbs a handle drawn off its ring), Å.
    let outerGrab: Double
    let innerGrab: Double
    /// The measured radius at the press.
    let radiusAtPress: Double?
    /// The aim dot minus the press.
    let aimGrab: CGVector
    /// The knob's orbit at the press (kept at a pole).
    let orbitAtPress: Double

    private(set) var lastPlacement: LightPlacement?
    private(set) var lastValue: Double?
    private(set) var lastAim: SIMD3<Double>?
    private(set) var hasMoved = false
    private(set) var isEnded = false

    /// A session for `target` pressed at `press` on `layout`, owned by
    /// `owner`. nil when the target is not in the layout (a knob of another
    /// name, no rings, no aim dot) or the press cannot be measured.
    init?(target: LightGizmoTarget, owner: String, press: CGPoint, layout: LightGizmoLayout) {
        self.target = target
        self.owner = owner.lowercased()
        self.press = press
        self.layout = layout
        var trackball: LightTrackball?
        var measure: LightRingMeasure?
        var outerGrab = 0.0, innerGrab = 0.0
        var radiusAtPress: Double?
        var aimGrab = CGVector.zero
        var orbit = 0.0
        switch target {
        case .knob(let name):
            guard let knob = layout.knob(named: name) else { return nil }
            mode = .knob
            trackball = LightTrackball(centre: layout.centre, radius: layout.sphereRadius, knob: knob.centre,
                                       press: press, behind: knob.isBehind, metrics: layout.metrics)
            orbit = knob.placement.orbit
        case .aimDot:
            guard let s = layout.selected, let aim = s.aimDot else { return nil }
            mode = .aim
            aimGrab = CGVector(dx: aim.x - press.x, dy: aim.y - press.y)
            orbit = s.placement.orbit
        case .outerHandle, .outerRing, .innerHandle, .innerRing, .rings:
            guard let s = layout.selected, let outer = s.outerRing, let inner = s.innerRing,
                  let m = LightRingMeasure(projection: layout.projection, target: s.target, axis: s.direction,
                                           press: press, grazingCos: layout.metrics.grazingCos),
                  let r = m.radius(at: press) else { return nil }
            switch target {
            case .outerHandle, .outerRing: mode = .outer
            case .innerHandle, .innerRing: mode = .inner
            default: mode = .rings
            }
            measure = m
            radiusAtPress = r
            outerGrab = outer.radius - r
            innerGrab = inner.radius - r
            orbit = s.placement.orbit
        }
        self.trackball = trackball
        self.measure = measure
        self.outerGrab = outerGrab
        self.innerGrab = innerGrab
        self.radiusAtPress = radiusAtPress
        self.aimGrab = aimGrab
        self.orbitAtPress = orbit
    }

    /// The knob is behind the molecule now (its side, flipped by the band);
    /// nil for other targets.
    var isBehind: Bool? { trackball?.isBehind }
    /// The pointer is outside the sphere's outline (a knob drag).
    var isOutside: Bool { trackball?.isOutside ?? false }

    /// The ring radius (Å) the pointer at `p` stands for in the session's
    /// resolved ring mode (the measured radius plus that ring's grab); nil
    /// before `.rings` is resolved or for other targets.
    func ringRadius(at p: CGPoint) -> Double? {
        guard let measure, let r = measure.radius(at: p) else { return nil }
        switch mode {
        case .outer: return max(0, r + outerGrab)
        case .inner: return max(0, r + innerGrab)
        default: return nil
        }
    }

    /// The step for a pointer at `point`, or nil (inside the drag slop, a
    /// repeat, nothing to measure, or the session is over). A returned
    /// placement or value counts as sent; an aim step counts once `noteAim`
    /// accepts its picked point.
    mutating func move(to point: CGPoint, current: LightGizmoCurrent) -> LightGizmoStep? {
        guard !isEnded else { return nil }
        if !hasMoved {
            guard gizmoDistance(point, press) >= layout.metrics.dragSlop else { return nil }
            hasMoved = true
        }
        switch mode {
        case .knob:
            guard var ball = trackball else { return nil }
            let d = ball.direction(at: point)
            trackball = ball
            let a = LightTrackball.angles(of: d, keeping: lastPlacement?.orbit ?? orbitAtPress)
            func same(_ p: LightPlacement) -> Bool {
                LightSnap.same(a.orbit, p.orbit, wraps: true) && LightSnap.same(a.pitch, p.pitch, wraps: false)
            }
            if let last = lastPlacement, same(last) { return nil }
            if let now = current.placement, same(now) { return nil }
            lastPlacement = LightPlacement(orbit: a.orbit, pitch: a.pitch, radius: 0)
            return .placement(orbit: a.orbit, pitch: a.pitch)
        case .aim:
            return .aim(at: CGPoint(x: point.x + aimGrab.dx, y: point.y + aimGrab.dy))
        case .rings:
            guard let measure, let r = measure.radius(at: point), let r0 = radiusAtPress else { return nil }
            mode = r < r0 ? .inner : .outer
            return ringStep(at: point, current: current)
        case .outer, .inner:
            return ringStep(at: point, current: current)
        }
    }

    private mutating func ringStep(at point: CGPoint, current: LightGizmoCurrent) -> LightGizmoStep? {
        guard let s = layout.selected, let r = ringRadius(at: point) else { return nil }
        let alpha = atan2(r, s.aimDistance)
        let value: Double
        let now: Double?
        if mode == .outer {
            let range = LightParameter.beam.range
            value = min(max(LightParameter.beam.rounded(2 * alpha * 180 / .pi), range.lowerBound), range.upperBound)
            now = current.beam
        } else {
            let half = acos(min(max(s.cosOuter, -1), 1))
            guard half > 0 else { return nil }
            value = min(max(LightParameter.softness.rounded(1 - alpha / half), 0), 1) + 0
            now = current.softness
        }
        if let lastValue, LightSnap.same(value, lastValue, wraps: false) { return nil }
        if let now, LightSnap.same(value, now, wraps: false) { return nil }
        lastValue = value
        return mode == .outer ? .beam(value) : .softness(value)
    }

    /// An aim pick found `point` (world Å): true when it should be written
    /// (not within `aimRepeat` of the last one sent).
    mutating func noteAim(_ point: SIMD3<Double>) -> Bool {
        if let lastAim, gizmoLength3(point - lastAim) <= LightGizmoMetrics.aimRepeat { return false }
        lastAim = point
        return true
    }

    /// The gesture is over (a refused write, the mode left): nothing more.
    mutating func end() { isEnded = true }
}

/// A trackpad scroll that began over a knob: latched to that light for its
/// whole phase, one radius step per `trackpadStep` points.
struct LightGizmoScrollSession: Equatable {
    /// The lowercased name of the light the scroll began on.
    let owner: String
    private(set) var accumulated: CGFloat = 0
    private(set) var isEnded = false

    init(owner: String) {
        self.owner = owner.lowercased()
    }

    /// Adds `deltaY` and returns the whole steps it completes (positive:
    /// farther), keeping the rest.
    mutating func add(_ deltaY: CGFloat, step: CGFloat) -> Int {
        guard !isEnded, deltaY.isFinite, step > 0 else { return 0 }
        accumulated += deltaY
        let steps = Int((accumulated / step).rounded(.towardZero))
        accumulated -= CGFloat(steps) * step
        return steps
    }

    mutating func end() { isEnded = true }
}

// MARK: - The picker seam

/// The surface pick an aim drag and an option-click use (#614). The engine
/// wires `prepareSurfacePick(updateReps: false)` and `pickSurface(...,
/// updateReps: false)` (C++ only: what the last frame drew); tests fake it.
struct LightGizmoPicker {
    /// Called once per press, before the first pick.
    var prepare: () -> Void
    /// The hit at a whole-view NDC (+y up) for a view of `viewAspect`
    /// (width / height), or nil on a miss.
    var pick: (_ viewNDC: SIMD2<Float>, _ viewAspect: Float) -> SurfacePick?
}

/// What an option-click (#623: a long-press) did.
enum LightGizmoHighlightResult: Equatable {
    /// No light is selected (or it cannot be edited): nothing ran.
    case noSelection
    /// The pick found no surface there: nothing ran.
    case miss
    /// The command ran; `rim` is 145 near the outline, nil for the mirror rule.
    case placed(rim: Double?)
    /// The controller would not run it (the light went away).
    case refused
}

// MARK: - Interaction

/// Turns what the user does on the gizmo into controller calls. The overlay,
/// the viewport, the tests and the DEBUG gestures all drive this one type:
/// - a press on a target starts a session with `beginGesture()`; a press on
///   another light's knob selects it by name first and the same drag moves it
///   (#621 Q7); a click on a knob only selects;
/// - each drag tick writes through the owner-guarded setters (knob:
///   `setPlacement`, two bridge setters; rings: `set(.beam|.softness)`; aim
///   dot: a pick, then `setAim`); any result but `.ok` ends the session, and
///   edits already made stay (Esc = Done);
/// - a scroll or pinch on a knob selects that light and sets its radius only
///   (the core keeps the beam, decision 8);
/// - an option-click places a highlight with one `lights` command.
@MainActor
struct LightGizmoInteraction {
    let controller: LightsController
    var picker: LightGizmoPicker?

    init(controller: LightsController, picker: LightGizmoPicker? = nil) {
        self.controller = controller
        self.picker = picker
    }

    /// A press at `point`: the hit target's session, or nil (the camera keeps
    /// the gesture).
    func press(at point: CGPoint, layout: LightGizmoLayout) -> LightGizmoDragSession? {
        guard let target = LightGizmoHitTest.target(at: point, layout: layout) else { return nil }
        return begin(target, at: point, layout: layout)
    }

    /// A session for `target` pressed at `point`. nil unless the light can
    /// be edited. A knob of another light is selected first (nil when that
    /// light is gone); the aim dot, rings and handles belong to the light the
    /// layout showed as selected. An aim press prepares the picker once.
    func begin(_ target: LightGizmoTarget, at point: CGPoint,
               layout: LightGizmoLayout) -> LightGizmoDragSession? {
        guard controller.canEdit else { return nil }
        if case .knob(let name) = target {
            if !isSelected(name) { controller.select(name: name) }
            guard isSelected(name) else { return nil }
        } else {
            guard let shown = layout.selected?.name, isSelected(shown) else { return nil }
            if target == .aimDot {
                guard let picker else { return nil }
                picker.prepare()
            }
        }
        guard let owner = controller.beginGesture() else { return nil }
        return LightGizmoDragSession(target: target, owner: owner, press: point, layout: layout)
    }

    /// A drag tick at `point`: the write's result, or nil when nothing was
    /// written. A result other than `.ok`, or the light no longer editable,
    /// ends the session.
    @discardableResult
    func move(_ session: inout LightGizmoDragSession, to point: CGPoint) -> LightSetResult? {
        guard !session.isEnded else { return nil }
        guard controller.canEdit else {
            session.end()
            return nil
        }
        var current = LightGizmoCurrent()
        if isSelected(session.owner), let index = controller.selectedIndex {
            current.placement = controller.placement(at: index)
            current.beam = controller.value(.beam)
            current.softness = controller.value(.softness)
        }
        guard let step = session.move(to: point, current: current) else { return nil }
        let result: LightSetResult
        switch step {
        case .placement(let orbit, let pitch):
            result = controller.setPlacement(orbit: orbit, pitch: pitch, owner: session.owner)
        case .beam(let value):
            result = controller.set(.beam, value, owner: session.owner)
        case .softness(let value):
            result = controller.set(.softness, value, owner: session.owner)
        case .aim(let at):
            guard let hit = pick(at: at, layout: session.layout) else { return nil }
            let world = SIMD3<Double>(Double(hit.point.x), Double(hit.point.y), Double(hit.point.z))
            guard session.noteAim(world) else { return nil }
            result = controller.setAim(world, owner: session.owner)
        }
        if result != .ok { session.end() }
        return result
    }

    // MARK: radius

    /// A mouse-wheel notch over a knob: that light selected, its radius one
    /// 0.5× step farther (`up`) or nearer. nil when nothing was written (not
    /// on a knob, at the end of the range, or the light cannot be edited).
    @discardableResult
    func scrollWheel(at point: CGPoint, up: Bool, layout: LightGizmoLayout) -> LightSetResult? {
        guard let owner = beginRadius(at: point, layout: layout) else { return nil }
        return stepRadius(owner: owner, steps: up ? 1 : -1)
    }

    /// A trackpad scroll begins at `point`: latched to the knob's light for
    /// its whole phase (nil off a knob: the camera keeps it).
    func beginScroll(at point: CGPoint, layout: LightGizmoLayout) -> LightGizmoScrollSession? {
        beginRadius(at: point, layout: layout).map(LightGizmoScrollSession.init(owner:))
    }

    /// A trackpad scroll change: one 0.5× step per `trackpadStep` points of
    /// accumulated `deltaY` (positive: farther). Momentum is the caller's to
    /// drop. A result other than `.ok` ends the session.
    @discardableResult
    func scroll(_ session: inout LightGizmoScrollSession, deltaY: CGFloat,
                metrics: LightGizmoMetrics = LightGizmoMetrics()) -> LightSetResult? {
        guard !session.isEnded else { return nil }
        guard controller.canEdit else {
            session.end()
            return nil
        }
        let steps = session.add(deltaY, step: metrics.trackpadStep)
        guard steps != 0 else { return nil }
        let result = stepRadius(owner: session.owner, steps: steps)
        if let result, result != .ok { session.end() }
        return result
    }

    /// A pinch begins at `point`: on a knob, that light selected and #621's
    /// pinch session (the 0.5× grid); nil elsewhere (the camera zooms).
    func beginPinch(at point: CGPoint, layout: LightGizmoLayout) -> OrbitPinchSession? {
        guard let name = LightGizmoHitTest.knob(at: point, layout: layout) else { return nil }
        return beginPinch(named: name)
    }

    /// A pinch on the knob of light `name` (#623: a two-finger sequence
    /// decided on that knob, opened wherever the centroid is by the time the
    /// pinch begins): that light selected and #621's pinch session; nil when
    /// the light cannot be edited or is gone.
    func beginPinch(named name: String) -> OrbitPinchSession? {
        guard controller.canEdit else { return nil }
        if !isSelected(name) { controller.select(name: name) }
        guard isSelected(name) else { return nil }
        return LightsOrbitInteraction(controller: controller).beginPinch()
    }

    /// A pinch change (radius only, owner-guarded).
    @discardableResult
    func pinch(_ session: inout OrbitPinchSession, magnification: Double) -> LightSetResult? {
        LightsOrbitInteraction(controller: controller).pinch(&session, magnification: magnification)
    }

    // MARK: clicks

    /// An option-click at `point` (#623's long-press calls this too): one
    /// `lights <name>, click=x/y` command for the selected light, with
    /// `rim=145` when the pick's facing is under 0.3 (near the molecule's
    /// outline the mirror rule would put the light straight behind it). No
    /// selection, a miss or a point outside the scene runs nothing.
    @discardableResult
    func placeHighlight(at point: CGPoint, layout: LightGizmoLayout) -> LightGizmoHighlightResult {
        guard controller.canEdit, controller.selectedLight != nil else { return .noSelection }
        guard let picker, let ndc = layout.projection.sceneNDC(point: point) else { return .miss }
        picker.prepare()
        guard let hit = pick(at: point, layout: layout) else { return .miss }
        let rim: Double? = hit.facing < LightGizmoMetrics.rimFacing ? LightGizmoMetrics.rimDegrees : nil
        return controller.placeHighlight(sceneNDC: ndc, rim: rim) ? .placed(rim: rim) : .refused
    }

    /// Re-aim the selected light called `name` at the rig centre (#699's
    /// double-click or double-tap on its aim dot). False when nothing ran.
    @discardableResult
    func aimAtCentre(name: String) -> Bool {
        guard controller.canEdit, isSelected(name) else { return false }
        return controller.aimAtCentre(name: name)
    }

    /// The Shadow chip: the selected light's shadow toggled with the
    /// inspector's own call, so the cap, its notice and their clearing are
    /// shared.
    @discardableResult
    func toggleShadow() -> LightSetResult {
        guard let light = controller.selectedLight else { return .badIndex }
        return controller.setShadow(!light.shadow)
    }

    // MARK: private

    private func isSelected(_ name: String) -> Bool {
        controller.selection.name?.lowercased() == name.lowercased()
    }

    /// The knob at `point`: its light selected and a gesture begun on it.
    private func beginRadius(at point: CGPoint, layout: LightGizmoLayout) -> String? {
        guard controller.canEdit, let name = LightGizmoHitTest.knob(at: point, layout: layout) else { return nil }
        if !isSelected(name) { controller.select(name: name) }
        guard isSelected(name) else { return nil }
        return controller.beginGesture()
    }

    /// `steps` 0.5× steps from the owner's fresh radius, one write.
    private func stepRadius(owner: String, steps: Int) -> LightSetResult? {
        guard steps != 0, isSelected(owner), var value = controller.freshValue(.radius) else { return nil }
        let start = value
        for _ in 0..<abs(steps) {
            guard let next = LightSnap.nextRadius(from: value, up: steps > 0) else { return nil }
            value = next
        }
        guard !LightSnap.same(value, start, wraps: false) else { return nil }
        return controller.set(.radius, value, owner: owner)
    }

    private func pick(at point: CGPoint, layout: LightGizmoLayout) -> SurfacePick? {
        guard let picker else { return nil }
        let ndc = layout.projection.viewNDC(point: point)
        let size = layout.projection.viewSize
        return picker.pick(SIMD2<Float>(Float(ndc.x), Float(ndc.y)), Float(size.width / size.height))
    }
}

// MARK: - Press ownership

/// #699: when a gizmo press re-aims its light at the rig centre.
enum LightAimRecentre {
    /// macOS: a press on `target` with `clickCount` (NSEvent's: 2 for the
    /// second press of a double-click) ends; `hasMoved` when it dragged past
    /// the slop. True only for a double-click (or more) on the aim dot that
    /// never dragged: a single click or any drag stays today's.
    static func onRelease(target: LightGizmoTarget?, clickCount: Int, hasMoved: Bool) -> Bool {
        target == .aimDot && clickCount >= 2 && !hasMoved
    }
}

/// Which input owns a press, from its start to its end, whatever the mode does
/// meanwhile (plan 4.13; the viewport wires it in Lights mode):
/// - a press on a target opens a session and owns the press (`.gizmo`): no
///   camera event is sent for any of it;
/// - an option-press off every target is a highlight candidate: released
///   without a drag it places a highlight; dragged past the slop it is
///   today's camera drag;
/// - anything else is the camera's.
/// While it owns a press, drags and the release are consumed even after Esc
/// or Done ended the mode (`endSession()`): the session stops writing, and the
/// rest of the drag never falls into the camera path. On iOS a change whose
/// start differs from the recorded one is a new press (OrbitTouchSequence),
/// so a cancelled sequence never drives the next.
struct LightGizmoPointer {
    enum Route: Equatable {
        /// The gizmo consumed it.
        case gizmo
        /// An option-press off every target, not yet a drag.
        case highlightCandidate
        /// Today's camera path.
        case camera
    }

    private(set) var session: LightGizmoDragSession?
    /// The current press is the gizmo's (until its release).
    private(set) var ownsPress = false
    /// Where an option-press off every target began, and the layout then.
    private(set) var candidate: CGPoint?
    private var candidateLayout: LightGizmoLayout?
    /// The last option-click's outcome.
    private(set) var lastHighlight: LightGizmoHighlightResult?
    /// The last double-click on the aim dot (#699): true ran `aim=centre`,
    /// false was refused; nil before the first.
    private(set) var lastRecentre: Bool?
    /// The current press's click count (2 for a double-click's second press).
    private var pressClickCount = 1
    private var touch = OrbitTouchSequence()

    init() {}

    /// A press at `point` (`option`: the option key is down; `clickCount`:
    /// NSEvent's, 2 for a double-click's second press). `layout` is nil when
    /// the gizmo is not shown.
    @MainActor
    mutating func press(at point: CGPoint, option: Bool, layout: LightGizmoLayout?,
                        interaction: LightGizmoInteraction, clickCount: Int = 1) -> Route {
        forgetPress()
        pressClickCount = clickCount
        guard let layout else { return .camera }
        if LightGizmoHitTest.target(at: point, layout: layout) != nil {
            guard let started = interaction.press(at: point, layout: layout) else { return .camera }
            session = started
            ownsPress = true
            return .gizmo
        }
        if option {
            candidate = point
            candidateLayout = layout
            return .highlightCandidate
        }
        return .camera
    }

    /// A drag to `point`.
    @MainActor
    mutating func drag(to point: CGPoint, interaction: LightGizmoInteraction) -> Route {
        if ownsPress {
            if var s = session {
                interaction.move(&s, to: point)
                session = s
            }
            return .gizmo
        }
        if let start = candidate {
            let slop = candidateLayout?.metrics.dragSlop ?? LightGizmoMetrics().dragSlop
            guard gizmoDistance(point, start) >= slop else { return .highlightCandidate }
            candidate = nil
            candidateLayout = nil
            return .camera
        }
        return .camera
    }

    /// The press ends at `point`. A highlight candidate that never dragged
    /// places a highlight (at its press point) and is consumed. A double-click
    /// on the aim dot that never dragged aims its light at the centre (#699).
    @MainActor
    mutating func release(at point: CGPoint, interaction: LightGizmoInteraction) -> Route {
        if ownsPress {
            var recentre: String?
            if let s = session, !s.isEnded,
               LightAimRecentre.onRelease(target: s.target, clickCount: pressClickCount, hasMoved: s.hasMoved) {
                recentre = s.owner
            }
            session?.end()
            session = nil
            ownsPress = false
            pressClickCount = 1
            if let recentre { lastRecentre = interaction.aimAtCentre(name: recentre) }
            return .gizmo
        }
        if let start = candidate, let layout = candidateLayout {
            candidate = nil
            candidateLayout = nil
            lastHighlight = interaction.placeHighlight(at: start, layout: layout)
            return .gizmo
        }
        return .camera
    }

    /// iOS: a pan change of the sequence that began at `start` (the touch-down
    /// point), now at `point`. A new start is a new press.
    @MainActor
    mutating func touchChanged(start: CGPoint, at point: CGPoint, layout: LightGizmoLayout?,
                               interaction: LightGizmoInteraction) -> Route {
        if touch.isNewPress(startingAt: start) {
            let route = press(at: start, option: false, layout: layout, interaction: interaction)
            guard route == .gizmo else { return route }
        }
        return drag(to: point, interaction: interaction)
    }

    /// iOS: the pan ended at `point`.
    @MainActor
    mutating func touchEnded(at point: CGPoint, interaction: LightGizmoInteraction) -> Route {
        let route = release(at: point, interaction: interaction)
        touch.end()
        return route
    }

    /// The mode ended mid-press: the session writes no more, and the rest of
    /// the press is still swallowed (no camera event at the press point).
    mutating func endSession() {
        session?.end()
        candidate = nil
        candidateLayout = nil
    }

    /// Forget the press entirely (a cancelled gesture): the next input is a
    /// new press.
    mutating func cancel() {
        forgetPress()
        touch.end()
    }

    /// The press is over: no session, nothing owned, no candidate (the touch
    /// sequence's start is kept, so its next change is not a new press).
    private mutating func forgetPress() {
        session?.end()
        session = nil
        ownsPress = false
        pressClickCount = 1
        candidate = nil
        candidateLayout = nil
    }
}

// MARK: - What the gizmo says

/// The gizmo's words, worked out from the controller in one place so the
/// tests check them without drawing: one VoiceOver element per knob, the
/// Shadow chip (the inspector's strings and rules, #620) and a one-token
/// summary for logs. nil unless Lights mode is active with a selected light.
struct LightGizmoState: Equatable {
    /// One knob as VoiceOver presents it.
    struct KnobElement: Equatable, Identifiable {
        var name: String
        /// `key light`.
        var label: String
        /// `in front of the molecule, orbit -60 degrees, pitch 25 degrees,
        /// radius 3.0 scene sizes, 30 angstroms`.
        var value: String
        var isSelected: Bool
        var isBehind: Bool
        /// `Select key`.
        var selectAction: String
        var identifier: String

        var id: String { name.lowercased() }
    }

    /// The per-light Shadow chip beside the selected knob.
    struct Chip: Equatable {
        var label: String
        var help: String
        /// `On` or `Off`.
        var value: String
        var isOn: Bool
        /// The cap notice after a refused press, nil when none.
        var notice: String?
        /// The light casts a shadow the scene does not show.
        var showsHint: Bool
        var hint: String
        var turnOnTitle: String
        var turnOnLabel: String
        var turnOnHelp: String
        var identifier: String
    }

    static let containerLabel = "Light gizmo"
    static let identifier = "lights.gizmo"
    static let chipIdentifier = "lights.gizmo.shadow"
    static let frontValue = "in front of the molecule"
    static let behindValue = "behind the molecule"

    static func knobIdentifier(_ name: String) -> String { "lights.gizmo.knob." + name.lowercased() }

    var selected: String
    /// Rig order.
    var front: [String]
    var behind: [String]
    var beam: Double
    var softness: Double
    var aim: LightRigSnapshot.Aim
    var knobs: [KnobElement]
    var chip: Chip

    /// `sceneShadowsOn`: the scene's Shadows switch as last read (nil:
    /// unknown, no hint).
    @MainActor
    init?(_ controller: LightsController, sceneShadowsOn: Bool? = nil) {
        guard let inspector = LightsInspectorState(controller, sceneShadowsOn: sceneShadowsOn),
              let lights = controller.rig?.lights, let light = controller.selectedLight else { return nil }
        let size = controller.rig?.size
        selected = light.name
        front = lights.filter { !controller.isBehind($0.name) }.map(\.name)
        behind = lights.filter { controller.isBehind($0.name) }.map(\.name)
        beam = light.beam
        softness = light.softness
        aim = light.aim
        knobs = lights.enumerated().map { i, l in
            let p = controller.placement(at: i) ?? l.placement
            let isBehind = controller.isBehind(l.name)
            let value = (isBehind ? Self.behindValue : Self.frontValue)
                + ", orbit " + LightInspectorFormat.spoken(.orbit, p.orbit, frameSize: size)
                + ", pitch " + LightInspectorFormat.spoken(.pitch, p.pitch, frameSize: size)
                + ", radius " + LightInspectorFormat.spoken(.radius, p.radius, frameSize: size)
            return KnobElement(name: l.name, label: "\(l.name) light", value: value,
                               isSelected: i == controller.selectedIndex, isBehind: isBehind,
                               selectAction: LightsOrbitState.selectAction(l.name),
                               identifier: Self.knobIdentifier(l.name))
        }
        chip = Chip(label: LightsInspectorState.shadowLabel, help: LightsInspectorState.shadowHelp,
                    value: inspector.shadowValue, isOn: inspector.isShadowed, notice: inspector.notice,
                    showsHint: inspector.showsShadowsHint, hint: LightsInspectorState.shadowsOffHint,
                    turnOnTitle: LightsInspectorState.turnOnTitle, turnOnLabel: LightsInspectorState.turnOnLabel,
                    turnOnHelp: LightsInspectorState.turnOnHelp, identifier: Self.chipIdentifier)
    }

    /// One space-free token for logs and the simulator evidence (logged as
    /// `gizmo=<summary>`):
    /// `key,front:key|fill,behind:rim,beam:45.0,softness:0.40,aim:centre`.
    var summary: String {
        func token(_ name: String) -> String {
            name.components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
        }
        func list(_ names: [String]) -> String { names.isEmpty ? "-" : names.map(token).joined(separator: "|") }
        return token(selected) + ",front:" + list(front) + ",behind:" + list(behind)
            + ",beam:" + String(format: "%.1f", beam) + ",softness:" + String(format: "%.2f", softness)
            + ",aim:" + aim.rawValue
    }
}

// MARK: - DEBUG gestures

#if DEBUG
/// What a DEBUG gizmo gesture needs from the app: the overlay's own size, the
/// engine's picker and the scene state the layout reads.
struct GizmoAutoContext {
    var viewSize: CGSize?
    var picker: LightGizmoPicker?
    var gridMode = false
    var sceneShadowsOn: Bool?
    var metrics = LightGizmoMetrics()
}

/// Gizmo gestures a simulator run applies (PYMOL_AUTOLIGHTS_EDIT, debug builds
/// only), driven through LightGizmoInteraction with the overlay's layout, so a
/// run exercises the hit test, the grab offsets, the trackball and its band,
/// the ring measure, the pick, the owner guard and the writes. Keys avoid the
/// inspector's and the orbit view's:
/// - `knob:<light>:<orbit>:<pitch>`: press the knob, then 12 ticks to the
///   trackball point of that direction (out through the band and back in when
///   the side changes);
/// - `flip:<light>`: out past the band and back to the mirrored point;
/// - `outer:<beam>`, `inner:<softness>`: drag the selected light's handle;
/// - `aimat:<x>:<y>`: drag the aim dot to scene NDC (x, y) (a real pick);
/// - `wheel:<light>:<steps>`: wheel notches on the knob (+ farther);
/// - `kpinch:<light>:<factor>`: a pinch on the knob from 1 to that factor;
/// - `hl:<x>:<y>`: an option-click at scene NDC (x, y);
/// - `gshadow:<0|1>`: the Shadow chip, pressed when the light differs;
/// - `tpinch:<light>:<factor>[:<span>]` (#623): a two-finger touch sequence
///   on the knob through LightTwoFingerSequence (the pan begins on the knob
///   with the fingers `span` pt apart, 60 by default; the pinch and the
///   twist join 30 pt away), then pinch ticks to the factor on the light the
///   sequence named; logs the owner, the radius, the beam and what the pan
///   and the twist did;
/// - `lpress:<x>:<y>` or `lpress:<light>` (#623): a touch long-press at scene
///   NDC (x, y), or on that light's knob, through LightTouchRouter (declined
///   on a point target), then the highlight;
/// - `gprobe:<light>:<dx>:<dy>` (#623): the hit test at the knob's centre
///   plus (dx, dy) points; logs the target or `camera`.
enum GizmoAutoGesture: Equatable {
    case knob(String, Double, Double)
    case flip(String)
    case outer(Double)
    case inner(Double)
    case aimAt(Double, Double)
    case wheel(String, Int)
    case pinch(String, Double)
    case highlight(Double, Double)
    case shadow(Bool)
    case touchPinch(String, Double, Double?)
    case longPress(Double, Double)
    case longPressKnob(String)
    case probe(String, Double, Double)

    static let keys: Set<String> = ["knob", "flip", "outer", "inner", "aimat", "wheel", "kpinch", "hl", "gshadow",
                                    "tpinch", "lpress", "gprobe"]

    /// The fingers' span of a `tpinch` without one (a pinch on a knob).
    static let autoPinchSpan: Double = 60
    /// How far the pinch and twist of a `tpinch` begin from the knob.
    static let autoPinchDrift: CGFloat = 30

    /// `token`'s key is a gizmo gesture's (whether or not the rest parses).
    static func claims(_ token: String) -> Bool {
        let key = token.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return keys.contains(key.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The gesture `token` describes, or nil.
    static func parse(_ token: String) -> GizmoAutoGesture? {
        let parts = token.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.first?.lowercased() else { return nil }
        func number(_ i: Int) -> Double? {
            guard parts.indices.contains(i), let x = Double(parts[i]), x.isFinite else { return nil }
            return x
        }
        func name(_ i: Int) -> String? {
            parts.indices.contains(i) && !parts[i].isEmpty ? parts[i] : nil
        }
        switch key {
        case "knob":
            guard parts.count == 4, let n = name(1), let o = number(2), let p = number(3) else { return nil }
            return .knob(n, o, p)
        case "flip":
            guard parts.count == 2, let n = name(1) else { return nil }
            return .flip(n)
        case "outer":
            guard parts.count == 2, let b = number(1) else { return nil }
            return .outer(b)
        case "inner":
            guard parts.count == 2, let s = number(1) else { return nil }
            return .inner(s)
        case "aimat", "hl":
            guard parts.count == 3, let x = number(1), let y = number(2) else { return nil }
            return key == "hl" ? .highlight(x, y) : .aimAt(x, y)
        case "wheel":
            guard parts.count == 3, let n = name(1), let s = number(2), s == s.rounded(), s != 0,
                  abs(s) <= 32 else { return nil }
            return .wheel(n, Int(s))
        case "kpinch":
            guard parts.count == 3, let n = name(1), let f = number(2), f > 0 else { return nil }
            return .pinch(n, f)
        case "gshadow":
            guard parts.count == 2, let v = number(1), v == 0 || v == 1 else { return nil }
            return .shadow(v == 1)
        case "tpinch":
            guard parts.count == 3 || parts.count == 4, let n = name(1), let f = number(2), f > 0 else { return nil }
            if parts.count == 4 {
                guard let span = number(3), span > 0 else { return nil }
                return .touchPinch(n, f, span)
            }
            return .touchPinch(n, f, nil)
        case "lpress":
            if parts.count == 3 {
                guard let x = number(1), let y = number(2) else { return nil }
                return .longPress(x, y)
            }
            guard parts.count == 2, let n = name(1) else { return nil }
            return .longPressKnob(n)
        case "gprobe":
            guard parts.count == 4, let n = name(1), let dx = number(2), let dy = number(3) else { return nil }
            return .probe(n, dx, dy)
        default:
            return nil
        }
    }

    /// The token as logged.
    var token: String {
        switch self {
        case .knob(let n, let o, let p): return "knob:\(n):\(Self.fmt(o)):\(Self.fmt(p))"
        case .flip(let n): return "flip:\(n)"
        case .outer(let b): return "outer:\(Self.fmt(b))"
        case .inner(let s): return "inner:\(Self.fmt(s))"
        case .aimAt(let x, let y): return "aimat:\(Self.fmt(x)):\(Self.fmt(y))"
        case .wheel(let n, let s): return "wheel:\(n):\(s)"
        case .pinch(let n, let f): return "kpinch:\(n):\(Self.fmt(f))"
        case .highlight(let x, let y): return "hl:\(Self.fmt(x)):\(Self.fmt(y))"
        case .shadow(let on): return "gshadow:\(on ? 1 : 0)"
        case .touchPinch(let n, let f, let span):
            return "tpinch:\(n):\(Self.fmt(f))" + (span.map { ":" + Self.fmt($0) } ?? "")
        case .longPress(let x, let y): return "lpress:\(Self.fmt(x)):\(Self.fmt(y))"
        case .longPressKnob(let n): return "lpress:\(n)"
        case .probe(let n, let dx, let dy): return "gprobe:\(n):\(Self.fmt(dx)):\(Self.fmt(dy))"
        }
    }

    /// Run the gesture; one `<token> -> <result> <values>` line: the last
    /// write's result (`none` when nothing was written, `miss` when the press
    /// hit no target, `noview` before the overlay has a size, `nolayout` when
    /// the gizmo is hidden) and the selected light's values after.
    @MainActor
    static func apply(_ gesture: GizmoAutoGesture, to controller: LightsController,
                      context: GizmoAutoContext?) -> String {
        let t = gesture.token
        guard let context, let size = context.viewSize, size.width > 0, size.height > 0 else {
            return "\(t) -> noview"
        }
        guard let layout = LightGizmoLayout.make(
            LightGizmoInputs(controller: controller, viewSize: size, gridMode: context.gridMode,
                             sceneShadowsOn: context.sceneShadowsOn), metrics: context.metrics)
        else { return "\(t) -> nolayout" }
        let interaction = LightGizmoInteraction(controller: controller, picker: context.picker)
        let ticks = LightGizmoMetrics.autoTicks
        var last: LightSetResult?

        func value(_ p: LightParameter, _ places: Int) -> String {
            controller.value(p).map { String(format: "%.\(places)f", $0 + 0) } ?? "-"
        }
        func result() -> String { last.map { "\($0)" } ?? "none" }
        func placement() -> String { "\(t) -> \(result()) orbit=\(value(.orbit, 0)) pitch=\(value(.pitch, 0))" }
        func aimText() -> String {
            guard let l = controller.selectedLight else { return "aim=-" }
            guard l.aim == .point else { return "aim=centre" }
            return String(format: "aim=%.2f,%.2f,%.2f", l.aimPoint.x, l.aimPoint.y, l.aimPoint.z)
        }
        /// Press `target` at `point` (through the hit test when it agrees).
        func start(_ target: LightGizmoTarget, at point: CGPoint) -> LightGizmoDragSession? {
            if LightGizmoHitTest.target(at: point, layout: layout) == target {
                return interaction.press(at: point, layout: layout)
            }
            return interaction.begin(target, at: point, layout: layout)
        }
        func drag(_ s: inout LightGizmoDragSession, _ path: [CGPoint]) {
            for p in path {
                if let r = interaction.move(&s, to: p) { last = r }
                if s.isEnded { break }
            }
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ n: Int) -> [CGPoint] {
            (1...max(n, 1)).map { k in
                let f = CGFloat(k) / CGFloat(max(n, 1))
                return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
            }
        }
        /// Outside the band at the angle of `towards` from the centre.
        func outside(_ towards: CGPoint, fallback: CGPoint) -> CGPoint {
            var v = CGVector(dx: towards.x - layout.centre.x, dy: towards.y - layout.centre.y)
            if hypot(v.dx, v.dy) < 1e-6 {
                v = CGVector(dx: fallback.x - layout.centre.x, dy: fallback.y - layout.centre.y)
            }
            if hypot(v.dx, v.dy) < 1e-6 { v = CGVector(dx: 1, dy: 0) }
            let l = hypot(v.dx, v.dy)
            let r = layout.bandRadius + 6
            return CGPoint(x: layout.centre.x + v.dx / l * r, y: layout.centre.y + v.dy / l * r)
        }

        switch gesture {
        case .knob(let name, let orbit, let pitch):
            guard let knob = layout.knob(named: name),
                  var s = start(.knob(knob.name), at: knob.centre), let ball = s.trackball
            else { return "\(t) -> miss" }
            let d = LightGizmoLayout.direction(orbit: orbit, pitch: pitch)
            let end = ball.pointer(for: d)
            if LightDepth.isBehind(orbit: orbit, pitch: pitch) == knob.isBehind {
                drag(&s, line(knob.centre, end, ticks))
            } else {
                let out = outside(end, fallback: knob.centre)
                drag(&s, line(knob.centre, out, ticks / 2) + line(out, end, ticks - ticks / 2))
            }
            return placement()
        case .flip(let name):
            guard let knob = layout.knob(named: name),
                  var s = start(.knob(knob.name), at: knob.centre) else { return "\(t) -> miss" }
            let out = outside(knob.centre, fallback: knob.centre)
            drag(&s, line(knob.centre, out, ticks / 2) + line(out, knob.centre, ticks - ticks / 2))
            return placement() + " behind=\(LightDepth.isBehind(orbit: controller.value(.orbit) ?? 0, pitch: controller.value(.pitch) ?? 0) ? 1 : 0)"
        case .outer(let beam), .inner(let beam):
            let isOuter: Bool
            if case .outer = gesture { isOuter = true } else { isOuter = false }
            guard let sel = layout.selected, let aim = sel.aimDot,
                  let handle = isOuter ? sel.outerHandle : sel.innerHandle,
                  var s = start(isOuter ? .outerHandle : .innerHandle, at: handle.point)
            else { return "\(t) -> miss" }
            let half = acos(min(max(sel.cosOuter, -1), 1))
            let alpha = isOuter ? beam / 2 * .pi / 180 : (1 - min(max(beam, 0), 1)) * half
            let wanted = sel.aimDistance * tan(alpha)
            let end = Self.solve(from: aim, through: handle.point, radius: wanted, session: s,
                                 limit: 4 * max(size.width, size.height))
            drag(&s, line(handle.point, end, ticks))
            let field: LightParameter = isOuter ? .beam : .softness
            return "\(t) -> \(result()) \(field.field)=\(value(field, isOuter ? 1 : 2))"
        case .aimAt(let x, let y):
            guard let aim = layout.selected?.aimDot, var s = start(.aimDot, at: aim) else { return "\(t) -> miss" }
            let end = layout.projection.point(sceneNDC: SIMD2(x, y))
            drag(&s, line(aim, end, ticks))
            return "\(t) -> \(result()) \(aimText())"
        case .wheel(let name, let steps):
            guard let knob = layout.knob(named: name),
                  LightGizmoHitTest.knob(at: knob.centre, layout: layout) != nil else { return "\(t) -> miss" }
            for _ in 0..<abs(steps) {
                if let r = interaction.scrollWheel(at: knob.centre, up: steps > 0, layout: layout) { last = r }
            }
            return "\(t) -> \(result()) radius=\(value(.radius, 2))"
        case .pinch(let name, let factor):
            guard let knob = layout.knob(named: name),
                  var s = interaction.beginPinch(at: knob.centre, layout: layout) else { return "\(t) -> miss" }
            for k in 1...ticks {
                let m = 1 + (factor - 1) * Double(k) / Double(ticks)
                if let r = interaction.pinch(&s, magnification: m) { last = r }
                if s.isEnded { break }
            }
            return "\(t) -> \(result()) radius=\(value(.radius, 2))"
        case .highlight(let x, let y):
            let r = interaction.placeHighlight(at: layout.projection.point(sceneNDC: SIMD2(x, y)), layout: layout)
            return "\(t) -> \(Self.text(r)) \(aimText())"
        case .touchPinch(let name, let factor, let span):
            guard let knob = layout.knob(named: name) else { return "\(t) -> miss" }
            let fingers = CGFloat(span ?? Self.autoPinchSpan)
            let knobAt: (CGPoint) -> String? = { LightGizmoHitTest.knob(at: $0, layout: layout) }
            var sequence = LightTwoFingerSequence()
            // The pan begins first, on the knob, and decides; the pinch and
            // the twist join after the centroid moved off the knob.
            let moved = CGPoint(x: knob.centre.x + Self.autoPinchDrift, y: knob.centre.y)
            _ = sequence.began(.pan, centroid: knob.centre, span: fingers, knob: knobAt)
            let owner = sequence.began(.pinch, centroid: moved, span: fingers, knob: knobAt)
            _ = sequence.began(.rotation, centroid: moved, span: fingers, knob: knobAt)
            if case .gizmo(let named) = owner, var s = interaction.beginPinch(named: named) {
                for k in 1...ticks {
                    let m = 1 + (factor - 1) * Double(k) / Double(ticks)
                    if let r = interaction.pinch(&s, magnification: m) { last = r }
                    if s.isEnded { break }
                }
            }
            let ownerText: String
            switch owner {
            case .gizmo(let named): ownerText = "gizmo(\(named))"
            case .camera: ownerText = "camera"
            }
            let pan = sequence.owner(of: .pan)?.isGizmo == true ? "ignored" : "camera"
            let twist = sequence.owner(of: .rotation)?.isGizmo == true ? "ignored" : "camera"
            for kind in LightTwoFingerKind.allCases { sequence.ended(kind) }
            return "\(t) -> \(result()) owner=\(ownerText) radius=\(value(.radius, 2)) beam=\(value(.beam, 1))"
                + " pan=\(pan) twist=\(twist) reset=\(sequence.isActive ? 0 : 1)"
        case .longPress, .longPressKnob:
            let point: CGPoint
            if case .longPress(let x, let y) = gesture {
                point = layout.projection.point(sceneNDC: SIMD2(x, y))
            } else if case .longPressKnob(let name) = gesture, let knob = layout.knob(named: name) {
                point = knob.centre
            } else {
                return "\(t) -> miss"
            }
            guard LightTouchRouter.shouldBeginLongPress(at: point, layout: layout) else {
                return "\(t) -> route=declined"
            }
            switch LightTouchRouter.longPress(at: point, layout: layout,
                                              hasSelection: controller.selectedLight != nil) {
            case .contextMenu: return "\(t) -> route=context_menu"
            case .ignore: return "\(t) -> route=ignore"
            case .highlight:
                let r = interaction.placeHighlight(at: point, layout: layout)
                return "\(t) -> route=highlight -> \(Self.text(r)) \(aimText())"
            }
        case .probe(let name, let dx, let dy):
            guard let knob = layout.knob(named: name) else { return "\(t) -> miss" }
            let p = CGPoint(x: knob.centre.x + CGFloat(dx), y: knob.centre.y + CGFloat(dy))
            let hit = LightGizmoHitTest.target(at: p, layout: layout).map(Self.text) ?? "camera"
            return "\(t) -> \(hit) touch=\(Self.fmt(Double(layout.metrics.minimumTarget)))"
        case .shadow(let on):
            guard let light = controller.selectedLight else { return "\(t) -> no_light" }
            if light.shadow != on { last = interaction.toggleShadow() }
            return "\(t) -> \(result()) shadow=\((controller.selectedLight?.shadow ?? false) ? 1 : 0)"
        }
    }

    /// The pointer on the line from the aim dot through `handle` whose ring
    /// radius (the session's measure plus grab) is `radius` Å: a scan for the
    /// first crossing, then bisection. The far end when none.
    private static func solve(from aim: CGPoint, through handle: CGPoint, radius: Double,
                              session: LightGizmoDragSession, limit: CGFloat) -> CGPoint {
        var v = CGVector(dx: handle.x - aim.x, dy: handle.y - aim.y)
        let l = hypot(v.dx, v.dy)
        v = l > 1e-9 ? CGVector(dx: v.dx / l, dy: v.dy / l) : CGVector(dx: 1, dy: 0)
        func at(_ s: CGFloat) -> CGPoint { CGPoint(x: aim.x + v.dx * s, y: aim.y + v.dy * s) }
        func f(_ s: CGFloat) -> Double? { session.ringRadius(at: at(s)).map { $0 - radius } }
        let n = 400
        var previous: (s: CGFloat, f: Double)?
        for k in 0...n {
            let s = limit * CGFloat(k) / CGFloat(n)
            guard let fs = f(s) else { continue }
            if let p = previous, (p.f <= 0) != (fs <= 0) {
                var lo = p.s, hi = s
                let loSign = p.f <= 0
                for _ in 0..<50 {
                    let mid = (lo + hi) / 2
                    guard let fm = f(mid) else { break }
                    if (fm <= 0) == loSign { lo = mid } else { hi = mid }
                }
                return at((lo + hi) / 2)
            }
            previous = (s, fs)
        }
        return at(limit)
    }

    private static func fmt(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(format: "%.0f", x) : String(x)
    }

    /// A highlight's outcome as logged.
    private static func text(_ r: LightGizmoHighlightResult) -> String {
        switch r {
        case .noSelection: return "no_selection"
        case .miss: return "miss"
        case .refused: return "refused"
        case .placed(let rim): return "placed rim=" + (rim.map { String(format: "%.0f", $0) } ?? "none")
        }
    }

    /// A hit target as logged.
    private static func text(_ target: LightGizmoTarget) -> String {
        switch target {
        case .knob(let name): return "knob:" + name
        case .aimDot: return "aim"
        case .outerHandle: return "outer_handle"
        case .innerHandle: return "inner_handle"
        case .outerRing: return "outer_ring"
        case .innerRing: return "inner_ring"
        case .rings: return "rings"
        }
    }
}
#endif

// MARK: - Vector helpers

private func gizmoDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

private func gizmoVector(_ from: CGPoint, _ to: CGPoint) -> SIMD2<Double> {
    SIMD2(Double(to.x - from.x), Double(to.y - from.y))
}

private func gizmoLength(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

private func gizmoPoint(_ origin: CGPoint, _ offset: SIMD2<Double>) -> CGPoint {
    CGPoint(x: Double(origin.x) + offset.x, y: Double(origin.y) + offset.y)
}

private func gizmoDot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

private func gizmoCross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func gizmoLength3(_ v: SIMD3<Double>) -> Double { gizmoDot(v, v).squareRoot() }

private func gizmoUnit3(_ v: SIMD3<Double>) -> SIMD3<Double> {
    let l = gizmoLength3(v)
    return l > 0 ? v / l : v
}
