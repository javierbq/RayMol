import CoreGraphics
import XCTest
@testable import RayMol

// The light gizmo's model (#622 part 2): the layout and its visibility rules,
// the hit test, the trackball and its band, the drag sessions (knob, rings,
// aim), radius, highlight placement, press ownership, mirroring with the bar,
// inspector and orbit view, the Shadow chip, the VoiceOver strings and the
// DEBUG gestures, all on fake seams (no engine). LightGizmoLiveTests (part 3)
// runs the same code on the live engine.

/// The fake camera: the world translated by (0, 0, -200) (FakeRigStore's
/// faithful eye space), perspective, 20 degrees, no letterbox.
private let cameraOffset = SIMD3<Double>(0, 0, -200)
private let viewSize = CGSize(width: 800, height: 600)

private func perspective(letterbox: Double = 0) -> LightCameraProjection {
    LightCameraProjection(orthoscopic: false, fovDegrees: 20, cameraDistance: 200,
                          letterboxAspect: letterbox)
}

/// A store with key (-45°, +30°, 3×, in front), fill (60°, +10°, 2×, in
/// front) and rim (160°, -20°, 3×, behind), faithful eye space under the fake
/// camera, and a controller in Lights mode with the gizmo's demand.
@MainActor
private func gizmoRig(_ setup: (FakeRigStore) -> Void = { _ in }) -> (FakeRigStore, LightsController) {
    let store = FakeRigStore()
    store.setRig(["key", "fill", "rim"])
    store.lights[0].orbit = -45
    store.lights[0].pitch = 30
    store.lights[0].radius = 3
    store.lights[1].orbit = 60
    store.lights[1].pitch = 10
    store.lights[1].radius = 2
    store.lights[2].orbit = 160
    store.lights[2].pitch = -20
    store.lights[2].radius = 3
    store.eyeOffset = cameraOffset
    store.projection = perspective()
    setup(store)
    let controller = LightsController(seams: store.seams)
    controller.eyeDemand = .everyFrame
    controller.begin()
    return (store, controller)
}

@MainActor
private func layout(_ controller: LightsController, size: CGSize = viewSize, grid: Bool = false,
                    shadowsOn: Bool? = true, slop: CGFloat = 6) -> LightGizmoLayout? {
    LightGizmoLayout.make(LightGizmoInputs(controller: controller, viewSize: size, gridMode: grid,
                                           sceneShadowsOn: shadowsOn),
                          metrics: LightGizmoMetrics(slop: slop))
}

/// The renderer's perspective slope for 20 degrees (LightCameraProjection).
private let slope20 = tan(tan(10 * Double.pi / 180))

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

private func offset(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
    CGPoint(x: p.x + dx, y: p.y + dy)
}

private func assertPoint(_ got: CGPoint?, _ want: CGPoint, accuracy: CGFloat = 1e-6,
                         _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    guard let got else { return XCTFail("nil point \(message)", file: file, line: line) }
    XCTAssertEqual(got.x, want.x, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(got.y, want.y, accuracy: accuracy, message, file: file, line: line)
}

/// A pick of the fake scene: the plane at world z = 0 (eye z = -200), facing
/// the camera by `facing`.
private final class FakePicker {
    var prepares = 0
    var picks: [SIMD2<Float>] = []
    var facing: Float = 0.8
    /// A pick at this view NDC misses.
    var misses: (SIMD2<Float>) -> Bool = { _ in false }

    var seam: LightGizmoPicker {
        LightGizmoPicker(prepare: { self.prepares += 1 }, pick: { ndc, aspect in
            self.picks.append(ndc)
            guard !self.misses(ndc) else { return nil }
            let depth = -cameraOffset.z
            let eye = SIMD3<Double>(depth * Double(ndc.x) * slope20 * Double(aspect),
                                    depth * Double(ndc.y) * slope20, -depth)
            let world = eye - cameraOffset
            return SurfacePick(raw: [Float(world.x), Float(world.y), Float(world.z), 0, 0, 1,
                                     Float(depth), self.facing], flags: 1)
        })
    }

    /// The world point the fake pick finds at view point `p`.
    func world(at p: CGPoint, size: CGSize = viewSize) -> SIMD3<Double> {
        let x = 2 * Double(p.x / size.width) - 1, y = 1 - 2 * Double(p.y / size.height)
        let depth = -cameraOffset.z
        let a = Double(size.width / size.height)
        return SIMD3(Double(Float(depth * Double(Float(x)) * slope20 * Double(Float(a)))),
                     Double(Float(depth * Double(Float(y)) * slope20)), 0)
    }
}

/// The pointer on the line from `a` through `b` whose ring radius in
/// `session` is `radius` Å (a scan, then bisection).
private func pointer(for radius: Double, in session: LightGizmoDragSession, from a: CGPoint,
                     through b: CGPoint) -> CGPoint? {
    let l = dist(a, b)
    let ux = (b.x - a.x) / l, uy = (b.y - a.y) / l
    func at(_ s: CGFloat) -> CGPoint { CGPoint(x: a.x + ux * s, y: a.y + uy * s) }
    func f(_ s: CGFloat) -> Double? { session.ringRadius(at: at(s)).map { $0 - radius } }
    var previous: (CGFloat, Double)?
    for k in 0...2000 {
        let s = CGFloat(k) * 0.5
        guard let v = f(s) else { continue }
        if let (ps, pv) = previous, (pv <= 0) != (v <= 0) {
            var lo = ps, hi = s
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                guard let m = f(mid) else { break }
                if (m <= 0) == (pv <= 0) { lo = mid } else { hi = mid }
            }
            return at((lo + hi) / 2)
        }
        previous = (s, v)
    }
    return nil
}

/// The ring sample farthest from every point target (knobs, aim dot,
/// handles), and that distance.
private func clearSample(_ ring: LightGizmoLayout.Ring, _ layout: LightGizmoLayout) -> (CGPoint, CGFloat) {
    var targets = layout.knobs.map(\.centre)
    if let s = layout.selected {
        targets += [s.aimDot, s.outerHandle?.point, s.innerHandle?.point].compactMap { $0 }
    }
    let best = ring.samples.compactMap { $0 }.map { p in (p, targets.map { dist(p, $0) }.min() ?? .infinity) }
        .max { $0.1 < $1.1 }!
    return best
}

// MARK: - Layout

@MainActor
final class LightGizmoLayoutTests: XCTestCase {

    func testOneKnobPerLightOnTheSphere() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        assertPoint(l.centre, CGPoint(x: 400, y: 300), accuracy: 1e-3)
        let perAngstrom = 300 / (200 * slope20)
        XCTAssertEqual(Double(l.sphereRadius), 1.2 * 10 * perAngstrom, accuracy: 1e-3)
        XCTAssertEqual(l.knobs.map(\.name), ["key", "fill", "rim"])
        for (knob, (o, p)) in zip(l.knobs, [(-45.0, 30.0), (60.0, 10.0), (160.0, -20.0)]) {
            let d = LightGizmoLayout.direction(orbit: o, pitch: p)
            assertPoint(knob.centre, CGPoint(x: l.centre.x + l.sphereRadius * CGFloat(d.x),
                                             y: l.centre.y - l.sphereRadius * CGFloat(d.y)),
                        accuracy: 1e-3, knob.name)
            XCTAssertEqual(knob.placement.orbit, o, accuracy: 1e-4)
            XCTAssertEqual(knob.placement.pitch, p, accuracy: 1e-4)
        }
        XCTAssertEqual(l.knobs.map(\.isBehind), [false, false, true], "rim is hollow")
        XCTAssertEqual(l.knobs.map(\.isSelected), [true, false, false])
        XCTAssertEqual(l.knobs.map(\.radius), [9, 7, 7])
        XCTAssertEqual(l.knobs.map(\.slot), [0, 1, 2], "identity colours")
        XCTAssertEqual(l.knobs.map(\.opacity), [1, 1, 1])
        // Behind knobs, front knobs, then the selected one.
        XCTAssertEqual(l.drawingOrder, [2, 1, 0])
    }

    func testOnlyTheSelectedLightHasAimDotRingsAndHandles() throws {
        let (store, controller) = gizmoRig()
        var l = try XCTUnwrap(layout(controller))
        var s = try XCTUnwrap(l.selected)
        XCTAssertEqual(s.name, "key")
        assertPoint(s.aimDot, l.centre, accuracy: 1e-3, "aimed at the centre")
        XCTAssertEqual(s.aimDistance, 30, accuracy: 1e-3)
        let outer = try XCTUnwrap(s.outerRing)
        let inner = try XCTUnwrap(s.innerRing)
        XCTAssertEqual(outer.radius, 30 * tan(22.5 * .pi / 180), accuracy: 1e-3)
        XCTAssertEqual(inner.radius, 30 * tan(22.5 * 0.6 * .pi / 180), accuracy: 1e-3)
        XCTAssertEqual(outer.samples.count, 72)
        XCTAssertNotNil(s.outerHandle)
        XCTAssertNotNil(s.innerHandle)
        XCTAssertEqual(l.aimLine?.from, l.knobs[0].centre)

        controller.select(name: "fill")
        l = try XCTUnwrap(layout(controller))
        s = try XCTUnwrap(l.selected)
        XCTAssertEqual(s.name, "fill")
        XCTAssertEqual(s.aimDistance, 20, accuracy: 1e-3)
        XCTAssertEqual(l.drawingOrder.last, 1)
        XCTAssertEqual(store.numberWrites.count, 0, "drawing writes nothing")
    }

    func testRingSamplesLieOnTheConeSection() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let s = try XCTUnwrap(l.selected)
        for ring in [s.outerRing!, s.innerRing!] {
            for case let p? in ring.samples {
                // The ray through each sample meets the aim plane at the ring's
                // radius from the aim point.
                let m = try XCTUnwrap(LightRingMeasure(projection: l.projection, target: s.target,
                                                       axis: s.direction, press: p, grazingCos: 0))
                XCTAssertTrue(m.usesAimPlane)
                XCTAssertEqual(try XCTUnwrap(m.radius(at: p)), ring.radius, accuracy: 1e-6 * 200)
            }
        }
    }

    func testRingRadiiFollowTheCosines() throws {
        for (beam, softness) in [(10.0, 0.0), (45.0, 0.4), (120.0, 1.0), (170.0, 0.5)] {
            let (_, controller) = gizmoRig {
                $0.lights[0].beam = beam
                $0.lights[0].softness = softness
            }
            let s = try XCTUnwrap(layout(controller)?.selected, "\(beam)")
            XCTAssertEqual(s.outerRing!.radius, s.aimDistance * tan(acos(s.cosOuter)), accuracy: 1e-9)
            XCTAssertEqual(s.innerRing!.radius, s.aimDistance * tan(acos(min(s.cosInner, 1))), accuracy: 1e-9)
            XCTAssertLessThanOrEqual(s.innerRing!.radius, s.outerRing!.radius + 1e-9)
        }
    }

    func testSphereClamp() throws {
        // Far away: the rig is small on screen, the sphere stays 64 pt.
        var (_, controller) = gizmoRig { $0.eyeOffset = SIMD3(0, 0, -4000) }
        XCTAssertEqual(try XCTUnwrap(layout(controller)).sphereRadius, 64, accuracy: 1e-9)
        // Close and small: 0.42 of the shorter side, even under 64.
        (_, controller) = gizmoRig { $0.eyeOffset = SIMD3(0, 0, -60) }
        let small = CGSize(width: 200, height: 150)
        XCTAssertEqual(try XCTUnwrap(layout(controller, size: small)).sphereRadius, 0.42 * 150, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(layout(controller)).sphereRadius, 0.42 * 600, accuracy: 1e-9)
    }

    func testRigOffDimsTheKnobs() throws {
        let (store, controller) = gizmoRig()
        controller.setEnabled(false)
        XCTAssertFalse(store.enabled)
        let l = try XCTUnwrap(layout(controller), "still shown, still editable")
        XCTAssertEqual(l.knobs.map(\.opacity), [0.45, 0.45, 0.45])
        XCTAssertFalse(l.isOn)
    }

    func testAPinnedLightUsesItsEyePlacement() throws {
        let (store, controller) = gizmoRig()
        XCTAssertEqual(controller.setPinned(true), .ok)   // key pinned where it is
        store.eyePlacements["key"] = LightPlacement(orbit: 120, pitch: -10, radius: 3)
        controller.frameRendered()
        let l = try XCTUnwrap(layout(controller))
        let d = LightGizmoLayout.direction(orbit: 120, pitch: -10)
        assertPoint(l.knobs[0].centre, CGPoint(x: l.centre.x + l.sphereRadius * CGFloat(d.x),
                                               y: l.centre.y - l.sphereRadius * CGFloat(d.y)), accuracy: 1e-3)
        XCTAssertTrue(l.knobs[0].isBehind)
        XCTAssertTrue(controller.isBehind("key"), "the chip and the knob agree")
    }

    func testHiddenUnlessTheGizmoShows() throws {
        var (store, controller) = gizmoRig()
        XCTAssertNotNil(layout(controller))
        XCTAssertNil(layout(controller, grid: true), "grid mode")
        store.busy = true
        XCTAssertNil(layout(controller), "a movie export")
        store.busy = false
        controller.eyeDemand = .pinnedOnly
        XCTAssertNil(layout(controller), "no eye data")
        controller.eyeDemand = .everyFrame
        controller.frameRendered()
        XCTAssertNotNil(layout(controller))
        controller.end()
        XCTAssertNil(layout(controller), "Lights mode off")

        (store, controller) = gizmoRig { $0.setRig([]) }
        XCTAssertNil(layout(controller), "no lights")

        (store, controller) = gizmoRig { $0.eyeOffset = SIMD3(0, 0, 50) }
        XCTAssertNil(layout(controller), "the rig centre is behind the camera")

        (store, controller) = gizmoRig { $0.projection = nil }
        XCTAssertNil(layout(controller), "no projection")

        (store, controller) = gizmoRig()
        XCTAssertNil(layout(controller, size: .zero), "no view yet")

        // Inputs whose eye space has another light count describe another rig.
        var inputs = LightGizmoInputs(controller: controller, viewSize: viewSize, gridMode: false,
                                      sceneShadowsOn: nil)
        inputs.lights.removeLast()
        XCTAssertNil(LightGizmoLayout.make(inputs))
    }

    func testHandlesSitAtTheRightmostSample() throws {
        let (_, controller) = gizmoRig()
        let s = try XCTUnwrap(layout(controller)?.selected)
        let outer = try XCTUnwrap(s.outerHandle)
        let inner = try XCTUnwrap(s.innerHandle)
        assertPoint(outer.ringPoint, try XCTUnwrap(s.outerRing?.rightmost))
        assertPoint(inner.ringPoint, try XCTUnwrap(s.innerRing?.rightmost))
        for p in s.outerRing!.samples.compactMap({ $0 }) { XCTAssertLessThanOrEqual(p.x, outer.ringPoint.x) }
        // Wide apart rings: the handles are on them.
        XCTAssertFalse(outer.isOffRing)
        XCTAssertFalse(inner.isOffRing)
        assertPoint(outer.point, outer.ringPoint)
        assertPoint(inner.point, inner.ringPoint)
    }

    func testHandleSeparationAtSoftnessZeroAndOne() throws {
        for softness in [0.0, 1.0] {
            let (_, controller) = gizmoRig { $0.lights[0].softness = softness }
            let s = try XCTUnwrap(layout(controller)?.selected)
            let aim = try XCTUnwrap(s.aimDot)
            let outer = try XCTUnwrap(s.outerHandle).point
            let inner = try XCTUnwrap(s.innerHandle).point
            XCTAssertGreaterThanOrEqual(dist(outer, aim), 24 - 1e-9, "\(softness)")
            XCTAssertGreaterThanOrEqual(dist(inner, aim), 12 - 1e-9, "\(softness)")
            XCTAssertGreaterThanOrEqual(dist(inner, outer), 12 - 1e-6, "\(softness)")
            XCTAssertTrue(s.innerHandle!.isOffRing, "moved off its ring: \(softness)")
        }
        // Softness 1: the inner ring collapses onto the aim dot; its handle
        // goes 12 pt from the dot towards the outer handle.
        let (_, controller) = gizmoRig { $0.lights[0].softness = 1 }
        let s = try XCTUnwrap(layout(controller)?.selected)
        XCTAssertEqual(s.innerRing!.radius, 0, accuracy: 1e-9)
        let aim = s.aimDot!, outer = s.outerHandle!.point, inner = s.innerHandle!.point
        XCTAssertEqual(dist(inner, aim), 12, accuracy: 1e-9)
        let cross = (outer.x - aim.x) * (inner.y - aim.y) - (outer.y - aim.y) * (inner.x - aim.x)
        XCTAssertEqual(cross, 0, accuracy: 1e-6, "on the line from the dot to the outer handle")
        // A tiny beam: the outer handle keeps 24 pt from the dot.
        let (_, tiny) = gizmoRig { $0.lights[0].beam = 1 }
        let t = try XCTUnwrap(layout(tiny)?.selected)
        XCTAssertEqual(dist(t.outerHandle!.point, t.aimDot!), 24, accuracy: 1e-9)
        XCTAssertTrue(t.outerHandle!.isOffRing)
    }

    func testLabelsAndReadout() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        XCTAssertEqual(l.knobs.map(\.label), ["key 3.0×", "fill", "rim"])
        for knob in l.knobs {
            XCTAssertGreaterThan(dist(knob.labelPoint, l.centre), dist(knob.centre, l.centre), knob.name)
            XCTAssertEqual(dist(knob.labelPoint, knob.centre), knob.radius + 4, accuracy: 1e-9)
        }
        XCTAssertEqual(l.readout(for: .knob("key")), "Orbit −45° · Pitch +30°")
        XCTAssertEqual(l.readout(for: .knob("RIM")), "Orbit 160° · Pitch −20°")
        XCTAssertEqual(l.readout(for: .outerHandle), "Beam 45°")
        XCTAssertEqual(l.readout(for: .outerRing), "Beam 45°")
        XCTAssertEqual(l.readout(for: .innerRing), "Softness 0.40")
        XCTAssertEqual(l.readout(for: .rings), "Beam 45° · Softness 0.40")
        XCTAssertNil(l.readout(for: .aimDot))
        XCTAssertNil(l.readout(for: .knob("nobody")))
        XCTAssertEqual(l.radiusReadout("fill"), "Radius 2.0× · 20 Å")
    }

    func testShadowMark() throws {
        let (_, controller) = gizmoRig { $0.lights[1].shadow = true }
        var l = try XCTUnwrap(layout(controller, shadowsOn: true))
        XCTAssertEqual(l.knobs.map(\.isShadowed), [false, true, false])
        XCTAssertEqual(l.knobs.map(\.isShadowDimmed), [false, false, false])
        l = try XCTUnwrap(layout(controller, shadowsOn: false))
        XCTAssertEqual(l.knobs.map(\.isShadowDimmed), [false, true, false], "the scene's Shadows are off")
        l = try XCTUnwrap(layout(controller, shadowsOn: nil))
        XCTAssertEqual(l.knobs.map(\.isShadowDimmed), [false, false, false], "unknown: not dimmed")
    }

    func testOrthoscopicAndLetterbox() throws {
        let (_, ortho) = gizmoRig {
            $0.projection = LightCameraProjection(orthoscopic: true, fovDegrees: 20, cameraDistance: 200,
                                                  letterboxAspect: 0)
        }
        let o = try XCTUnwrap(layout(ortho))
        assertPoint(o.centre, CGPoint(x: 400, y: 300), accuracy: 1e-3)
        XCTAssertEqual(Double(o.sphereRadius), 1.2 * 10 * 300 / (200 * tan(10 * Double.pi / 180)), accuracy: 1e-3)
        let (_, boxed) = gizmoRig { $0.projection = perspective(letterbox: 1) }
        let b = try XCTUnwrap(layout(boxed))
        XCTAssertEqual(b.projection.sceneRect, CGRect(x: 100, y: 0, width: 600, height: 600))
        assertPoint(b.centre, CGPoint(x: 400, y: 300), accuracy: 1e-3)
    }
}

// MARK: - Hit test

@MainActor
final class LightGizmoHitTestTests: XCTestCase {

    func testKnobsInFrontAndBehind() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        for knob in l.knobs {
            XCTAssertEqual(LightGizmoHitTest.target(at: knob.centre, layout: l), .knob(knob.name))
            XCTAssertEqual(LightGizmoHitTest.knob(at: knob.centre, layout: l), knob.name)
        }
    }

    func testSlop() throws {
        let (_, controller) = gizmoRig()
        for slop: CGFloat in [6, 14] {
            let l = try XCTUnwrap(layout(controller, slop: slop))
            let fill = l.knobs[1]
            // Straight down from the fill knob (nothing else there).
            XCTAssertEqual(LightGizmoHitTest.target(at: offset(fill.centre, 0, 7 + slop), layout: l),
                           .knob("fill"), "\(slop)")
            XCTAssertNil(LightGizmoHitTest.knob(at: offset(fill.centre, 0, 7 + slop + 0.5), layout: l),
                         "\(slop)")
        }
    }

    func testStackedKnobsAndRanks() throws {
        // fill and light4 at the same place (front), rim behind it on screen.
        let (_, controller) = gizmoRig {
            $0.setRig(["key", "fill", "light4", "rim"])
            $0.lights[0].orbit = -45
            for i in [1, 2] {
                $0.lights[i].orbit = 30
                $0.lights[i].pitch = 0
            }
            $0.lights[3].orbit = 150   // sin 150 = sin 30: the same screen point
            $0.lights[3].pitch = 0
        }
        var l = try XCTUnwrap(layout(controller))
        assertPoint(l.knobs[3].centre, l.knobs[1].centre, accuracy: 1e-3)
        // Exact tie between two front knobs: the later in drawing order.
        XCTAssertEqual(LightGizmoHitTest.target(at: l.knobs[1].centre, layout: l), .knob("light4"))
        // Selected beats front, front beats behind.
        controller.select(name: "fill")
        l = try XCTUnwrap(layout(controller))
        XCTAssertEqual(LightGizmoHitTest.target(at: l.knobs[1].centre, layout: l), .knob("fill"))
        controller.select(name: "key")
        l = try XCTUnwrap(layout(controller))
        XCTAssertEqual(LightGizmoHitTest.target(at: offset(l.knobs[3].centre, 0.2, 0), layout: l),
                       .knob("light4"), "front over behind")
        // Inside a knob beats the slop of another.
        let inside = offset(l.knobs[1].centre, 0, -6)
        XCTAssertEqual(LightGizmoHitTest.target(at: inside, layout: l), .knob("light4"))
    }

    func testAimDotUnderAFrontPoleKnob() throws {
        // key at the front pole: its knob covers the aim dot.
        let (_, controller) = gizmoRig {
            $0.lights[0].orbit = 0
            $0.lights[0].pitch = 0
        }
        let l = try XCTUnwrap(layout(controller))
        assertPoint(l.knobs[0].centre, l.selected!.aimDot!, accuracy: 1e-3)
        XCTAssertEqual(LightGizmoHitTest.target(at: l.centre, layout: l), .aimDot, "reachable at its centre")
        XCTAssertEqual(LightGizmoHitTest.target(at: offset(l.centre, 6, 0), layout: l), .knob("key"),
                       "inside the knob, outside the dot")
        XCTAssertEqual(LightGizmoHitTest.knob(at: l.centre, layout: l), "key", "knobs only")
    }

    func testHandles() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let s = try XCTUnwrap(l.selected)
        XCTAssertEqual(LightGizmoHitTest.target(at: s.outerHandle!.point, layout: l), .outerHandle)
        XCTAssertEqual(LightGizmoHitTest.target(at: s.innerHandle!.point, layout: l), .innerHandle)
        // Chebyshev: the square's corner plus the slop.
        XCTAssertEqual(LightGizmoHitTest.target(at: offset(s.outerHandle!.point, 10.4, -10.4), layout: l),
                       .outerHandle)
        XCTAssertNil(LightGizmoHitTest.knob(at: s.outerHandle!.point, layout: l))
    }

    func testHandlesAtSoftnessZeroAndOne() throws {
        for softness in [0.0, 1.0] {
            let (_, controller) = gizmoRig { $0.lights[0].softness = softness }
            let l = try XCTUnwrap(layout(controller))
            let s = try XCTUnwrap(l.selected)
            XCTAssertEqual(LightGizmoHitTest.target(at: s.innerHandle!.point, layout: l), .innerHandle,
                           "\(softness)")
            XCTAssertEqual(LightGizmoHitTest.target(at: s.outerHandle!.point, layout: l), .outerHandle,
                           "\(softness)")
            XCTAssertEqual(LightGizmoHitTest.target(at: s.aimDot!, layout: l), .aimDot, "\(softness)")
        }
    }

    func testRingLines() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let s = try XCTUnwrap(l.selected)
        let (outer, clearOuter) = clearSample(s.outerRing!, l)
        XCTAssertGreaterThan(clearOuter, 30)
        XCTAssertEqual(LightGizmoHitTest.target(at: outer, layout: l), .outerRing)
        let (inner, clearInner) = clearSample(s.innerRing!, l)
        XCTAssertGreaterThan(clearInner, 20)
        XCTAssertEqual(LightGizmoHitTest.target(at: inner, layout: l), .innerRing)
        // Within the slop plus half the stroke, along the line to the dot.
        let aim = s.aimDot!
        let d = dist(outer, aim)
        let away = CGPoint(x: outer.x + (outer.x - aim.x) / d * 6.5, y: outer.y + (outer.y - aim.y) / d * 6.5)
        XCTAssertEqual(LightGizmoHitTest.target(at: away, layout: l), .outerRing)
        let far = CGPoint(x: outer.x + (outer.x - aim.x) / d * 9, y: outer.y + (outer.y - aim.y) / d * 9)
        XCTAssertNil(LightGizmoHitTest.target(at: far, layout: l))
        XCTAssertNil(LightGizmoHitTest.knob(at: outer, layout: l), "rings are not knobs")
    }

    func testCoincidentRings() throws {
        let (_, controller) = gizmoRig { $0.lights[0].softness = 0 }
        let l = try XCTUnwrap(layout(controller))
        let s = try XCTUnwrap(l.selected)
        let (p, _) = clearSample(s.outerRing!, l)
        XCTAssertEqual(LightGizmoHitTest.target(at: p, layout: l), .rings)
    }

    func testInteriorsAndEmptySpaceAreTheCameras() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let s = try XCTUnwrap(l.selected)
        let (inner, _) = clearSample(s.innerRing!, l)
        let aim = s.aimDot!
        let mid = CGPoint(x: (inner.x + aim.x) / 2, y: (inner.y + aim.y) / 2)
        XCTAssertNil(LightGizmoHitTest.target(at: mid, layout: l), "inside the inner ring")
        XCTAssertNil(LightGizmoHitTest.target(at: CGPoint(x: 5, y: 5), layout: l))
        XCTAssertNil(LightGizmoHitTest.target(at: l.knobs[1].labelPoint.applying(.init(translationX: 30, y: 0)),
                                              layout: l), "past a label")
    }
}

// MARK: - Trackball

final class LightTrackballTests: XCTestCase {
    private let c = CGPoint(x: 100, y: 100)
    private let r: CGFloat = 50
    private let hold = sin(2 * Double.pi / 180)

    private func ball(behind: Bool = false, knob: CGPoint? = nil, press: CGPoint? = nil) -> LightTrackball {
        LightTrackball(centre: c, radius: r, knob: knob ?? c, press: press ?? c, behind: behind,
                       metrics: LightGizmoMetrics(slop: 6))
    }

    private func at(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint { CGPoint(x: c.x + ux * r, y: c.y - uy * r) }

    func testBothHemispheres() {
        var front = ball()
        var d = front.direction(at: at(0.5, 0))
        XCTAssertEqual(d.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(d.z, 0.75.squareRoot(), accuracy: 1e-12)
        var a = LightTrackball.angles(of: d, keeping: 0)
        XCTAssertEqual(a.orbit, 30)
        XCTAssertEqual(a.pitch, 0)
        var behind = ball(behind: true)
        d = behind.direction(at: at(0.5, 0.5))
        XCTAssertLessThan(d.z, 0)
        a = LightTrackball.angles(of: d, keeping: 0)
        XCTAssertEqual(a.pitch, 30)
        XCTAssertGreaterThan(abs(a.orbit), 90)
        XCTAssertTrue(LightDepth.isBehind(orbit: a.orbit, pitch: a.pitch))
        XCTAssertEqual(LightTrackball.angles(of: front.direction(at: c), keeping: 40).orbit, 0, "the front pole")
        XCTAssertEqual(LightTrackball.angles(of: behind.direction(at: c), keeping: 40).orbit, 180, "the back pole")
    }

    func testHoldsTwoDegreesOffTheOutline() {
        var b = ball()
        // Just inside: |dz| is held at sin 2°.
        var d = b.direction(at: at(0.9999, 0))
        XCTAssertEqual(d.z, hold, accuracy: 1e-12)
        XCTAssertEqual(LightTrackball.angles(of: d, keeping: 0).orbit, 88)
        // Outside, inside the band: on the outline at the pointer's angle.
        d = b.direction(at: at(1.2, 0))
        XCTAssertEqual(d.z, hold, accuracy: 1e-12)
        XCTAssertEqual(d.x, cos(2 * Double.pi / 180), accuracy: 1e-12)
        XCTAssertTrue(b.isOutside)
        XCTAssertFalse(b.isBehind, "no flip inside the band")
        // The poles: pitch at most 88.
        d = b.direction(at: at(0, 1))
        XCTAssertEqual(LightTrackball.angles(of: d, keeping: 0).pitch, 88)
        d = b.direction(at: at(0, -3))
        XCTAssertEqual(LightTrackball.angles(of: d, keeping: 0).pitch, -88)
        XCTAssertEqual(LightTrackball.angles(of: SIMD3(0, 1, 0), keeping: 40).orbit, 40, "orbit kept at a pole")
    }

    func testTheBandFlipsOncePerExcursion() {
        var b = ball()
        let band = 1 + 14 / r
        _ = b.direction(at: at(band - 0.01, 0))
        XCTAssertFalse(b.isBehind, "between the outline and the band")
        _ = b.direction(at: at(band + 0.01, 0))
        XCTAssertTrue(b.isBehind, "past the band: hollow at once")
        _ = b.direction(at: at(band + 0.5, 0.3))
        _ = b.direction(at: at(1.1, 0))
        _ = b.direction(at: at(band + 0.2, 0))
        XCTAssertTrue(b.isBehind, "once per excursion")
        var d = b.direction(at: at(0.5, 0))
        XCTAssertFalse(b.isOutside)
        XCTAssertLessThan(d.z, 0, "back inside: behind")
        XCTAssertEqual(LightTrackball.angles(of: d, keeping: 0).orbit, 150)
        _ = b.direction(at: at(-(band + 0.1), 0))
        XCTAssertFalse(b.isBehind, "a new excursion flips again")
        d = b.direction(at: at(-0.5, 0))
        XCTAssertEqual(LightTrackball.angles(of: d, keeping: 0).orbit, -30)
    }

    func testReleasedOutsideCommitsTheFlip() {
        var b = ball()
        let d = b.direction(at: at(2, 0))
        let a = LightTrackball.angles(of: d, keeping: 0)
        XCTAssertEqual(a.orbit, 92)
        XCTAssertTrue(LightDepth.isBehind(orbit: a.orbit, pitch: a.pitch))
    }

    func testRoundingNeverCrossesTheSilhouette() {
        for behind in [false, true] {
            for i in -40...40 {
                for j in -40...40 {
                    var b = ball(behind: behind)
                    let d = b.direction(at: at(CGFloat(i) / 20, CGFloat(j) / 20))
                    XCTAssertEqual((d * d).sum(), 1, accuracy: 1e-9)
                    XCTAssertGreaterThanOrEqual(abs(d.z), hold - 1e-12)
                    let a = LightTrackball.angles(of: d, keeping: 0)
                    // The side the session is on now (past the band it flipped).
                    XCTAssertEqual(LightDepth.isBehind(orbit: a.orbit, pitch: a.pitch), b.isBehind, "\(i) \(j)")
                    XCTAssertLessThanOrEqual(abs(a.pitch), 88)
                    if b.isBehind {
                        XCTAssertGreaterThanOrEqual(abs(a.orbit), 92, "\(i) \(j)")
                    } else {
                        XCTAssertLessThanOrEqual(abs(a.orbit), 88, "\(i) \(j)")
                    }
                }
            }
        }
    }

    func testGrabOffsetAndInverse() {
        // Pressed 10 pt right of a knob at the centre: the press itself is the
        // knob's own direction.
        var b = ball(knob: c, press: CGPoint(x: 110, y: 100))
        let d = b.direction(at: CGPoint(x: 110, y: 100))
        XCTAssertEqual(d, SIMD3(0, 0, 1))
        let target = LightGizmoLayout.direction(orbit: -60, pitch: 40)
        var again = b
        let back = again.direction(at: b.pointer(for: target))
        XCTAssertEqual(back.x, target.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, target.y, accuracy: 1e-9)
        XCTAssertEqual(back.z, target.z, accuracy: 1e-9)
        let a = LightTrackball.angles(of: back, keeping: 0)
        XCTAssertEqual(a.orbit, -60)
        XCTAssertEqual(a.pitch, 40)
    }
}

// MARK: - Drags

@MainActor
final class LightGizmoDragTests: XCTestCase {

    func testKnobDragWritesBothValuesAfterTheSlop() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        let knob = l.knobs[0]
        let press = offset(knob.centre, 2, 1)
        var s = try XCTUnwrap(interaction.press(at: press, layout: l))
        XCTAssertEqual(s.target, .knob("key"))
        XCTAssertEqual(s.owner, "key")
        XCTAssertNil(interaction.move(&s, to: offset(press, 1, 1)), "inside the drag slop")
        XCTAssertTrue(store.numberWrites.isEmpty)
        // The grab offset: the press point stands for the knob.
        let target = LightGizmoLayout.direction(orbit: -60, pitch: 40)
        let to = s.trackball!.pointer(for: target)
        XCTAssertEqual(interaction.move(&s, to: to), .ok)
        XCTAssertEqual(store.numberWrites.map(\.field), ["pitch", "orbit"], "pitch first")
        XCTAssertEqual(store.lights[0].orbit, -60)
        XCTAssertEqual(store.lights[0].pitch, 40)
        XCTAssertEqual(store.lights[0].radius, 3, "radius kept")
        XCTAssertNil(interaction.move(&s, to: offset(to, 0.1, 0)), "the same 1° values: no write")
        XCTAssertEqual(store.numberWrites.count, 2)
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertTrue(store.vectorWrites.isEmpty)
    }

    func testAPressOnAnotherKnobSelectsIt() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        let before = controller.gestureGeneration
        var s = try XCTUnwrap(interaction.press(at: l.knobs[2].centre, layout: l))
        XCTAssertEqual(controller.selection.name, "rim")
        XCTAssertEqual(s.owner, "rim")
        XCTAssertEqual(s.isBehind, true)
        XCTAssertEqual(controller.gestureGeneration, before + 1)
        XCTAssertNotNil(interaction.move(&s, to: offset(l.knobs[2].centre, 20, 0)))
        XCTAssertEqual(store.numberWrites.map(\.index), [2, 2])
        XCTAssertTrue(LightDepth.isBehind(store.lights[2].placement), "still behind")
    }

    func testTheSessionEndsWhenTheOwnerIsLost() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        store.removeLight("key")   // a console remove: fill slides into index 0
        store.clock += 1
        XCTAssertEqual(interaction.move(&s, to: offset(l.knobs[0].centre, 30, 0)), .badIndex)
        XCTAssertTrue(s.isEnded)
        XCTAssertTrue(store.numberWrites.isEmpty, "nothing written to fill")
        XCTAssertNil(interaction.move(&s, to: offset(l.knobs[0].centre, 40, 0)))
    }

    func testTheSessionEndsWithTheMode() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        XCTAssertEqual(interaction.move(&s, to: offset(l.knobs[0].centre, 20, 0)), .ok)
        let orbit = store.lights[0].orbit
        controller.end()   // Esc = Done: the edit stays
        XCTAssertNil(interaction.move(&s, to: offset(l.knobs[0].centre, 40, 0)))
        XCTAssertTrue(s.isEnded)
        XCTAssertEqual(store.lights[0].orbit, orbit)
    }

    func testARefusedWriteEndsTheSession() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        store.ready = false
        XCTAssertEqual(interaction.move(&s, to: offset(l.knobs[0].centre, 20, 0)), .noRig)
        XCTAssertTrue(s.isEnded)
    }

    func testOuterRingDragOnTheAimPlane() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let sel = try XCTUnwrap(l.selected)
        let interaction = LightGizmoInteraction(controller: controller)
        let handle = sel.outerHandle!.point
        var s = try XCTUnwrap(interaction.press(at: handle, layout: l))
        XCTAssertEqual(s.target, .outerHandle)
        XCTAssertEqual(s.mode, .outer)
        XCTAssertTrue(s.measure!.usesAimPlane, "an oblique ring, not grazing")
        XCTAssertEqual(s.outerGrab, 0, accuracy: 1e-3, "the handle is on its ring")
        let wanted = 30 * tan(15 * Double.pi / 180)
        let to = try XCTUnwrap(pointer(for: wanted, in: s, from: sel.aimDot!, through: handle))
        XCTAssertEqual(interaction.move(&s, to: to), .ok)
        XCTAssertEqual(store.numberWrites.map(\.field), ["beam"])
        XCTAssertEqual(store.lights[0].beam, 30)
        XCTAssertEqual(store.lights[0].softness, 0.4, "softness kept")
        // The redrawn ring passes under the pointer.
        let after = try XCTUnwrap(layout(controller)?.selected?.outerRing)
        XCTAssertEqual(after.radius, wanted, accuracy: 1e-3)
        XCTAssertLessThan(try XCTUnwrap(LightGizmoHitTest.nearest(to, on: after)).distance, 1)
    }

    func testInnerRingDragSetsSoftness() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let sel = try XCTUnwrap(l.selected)
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: sel.innerHandle!.point, layout: l))
        XCTAssertEqual(s.mode, .inner)
        let half = 22.5 * Double.pi / 180
        let wanted = 30 * tan((1 - 0.6) * half)
        let to = try XCTUnwrap(pointer(for: wanted, in: s, from: sel.aimDot!, through: sel.innerHandle!.point))
        XCTAssertEqual(interaction.move(&s, to: to), .ok)
        XCTAssertEqual(store.numberWrites.map(\.field), ["softness"])
        XCTAssertEqual(store.lights[0].softness, 0.6, accuracy: 1e-12)
        XCTAssertEqual(store.lights[0].beam, 45, "beam kept")
    }

    func testAPressOnTheRingLineIsRelative() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let sel = try XCTUnwrap(l.selected)
        let (p, _) = clearSample(sel.outerRing!, l)
        let aim = sel.aimDot!
        let d = dist(p, aim)
        let out = CGPoint(x: p.x + (p.x - aim.x) / d * 3.5, y: p.y + (p.y - aim.y) / d * 3.5)
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: out, layout: l))
        XCTAssertEqual(s.target, .outerRing)
        // Pressed 3.5 pt outside the drawn ring: the press stands for the ring,
        // so moving back onto the drawn ring narrows the beam (relative)
        // rather than writing the beam the ring already shows (absolute).
        XCTAssertEqual(interaction.move(&s, to: p), .ok)
        XCTAssertLessThan(store.lights[0].beam, 45)
    }

    func testGrazingRingsAreMeasuredOnTheViewPlane() throws {
        // key at orbit 90: its beam runs across the view, the ring is edge-on.
        let (store, controller) = gizmoRig {
            $0.lights[0].orbit = 90
            $0.lights[0].pitch = 0
        }
        let l = try XCTUnwrap(layout(controller))
        let sel = try XCTUnwrap(l.selected)
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.begin(.outerHandle, at: sel.outerHandle!.point, layout: l))
        XCTAssertFalse(s.measure!.usesAimPlane)
        XCTAssertEqual(s.measure!.normal, SIMD3(0, 0, 1))
        let aim = sel.aimDot!
        let handle = sel.outerHandle!.point
        let far = CGPoint(x: aim.x + (handle.x - aim.x) * 1.5, y: aim.y + (handle.y - aim.y) * 1.5)
        XCTAssertEqual(interaction.move(&s, to: far), .ok)
        XCTAssertGreaterThan(store.lights[0].beam, 45)
    }

    func testCoincidentRingsResolveOnTheFirstMove() throws {
        for inward in [true, false] {
            let (store, controller) = gizmoRig { $0.lights[0].softness = 0 }
            let l = try XCTUnwrap(layout(controller))
            let sel = try XCTUnwrap(l.selected)
            let (p, _) = clearSample(sel.outerRing!, l)
            let interaction = LightGizmoInteraction(controller: controller)
            var s = try XCTUnwrap(interaction.press(at: p, layout: l))
            XCTAssertEqual(s.target, .rings)
            XCTAssertEqual(s.mode, .rings)
            let aim = sel.aimDot!
            let f: CGFloat = inward ? 0.8 : 1.2
            let to = CGPoint(x: aim.x + (p.x - aim.x) * f, y: aim.y + (p.y - aim.y) * f)
            XCTAssertEqual(interaction.move(&s, to: to), .ok)
            XCTAssertEqual(s.mode, inward ? .inner : .outer)
            XCTAssertEqual(store.numberWrites.map(\.field), [inward ? "softness" : "beam"])
            if inward {
                XCTAssertGreaterThan(store.lights[0].softness, 0)
            } else {
                XCTAssertGreaterThan(store.lights[0].beam, 45)
            }
        }
    }

    func testAimDragWritesThePickedPoint() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let picker = FakePicker()
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        let aim = try XCTUnwrap(l.selected?.aimDot)
        let press = offset(aim, 1, 0)
        var s = try XCTUnwrap(interaction.press(at: press, layout: l))
        XCTAssertEqual(s.target, .aimDot)
        XCTAssertEqual(picker.prepares, 1, "prepared once at the press")
        let to = offset(press, 60, -30)
        XCTAssertEqual(interaction.move(&s, to: to), .ok)
        XCTAssertEqual(store.vectorWrites.count, 1)
        XCTAssertEqual(store.vectorWrites.first?.field, "aim_point")
        let want = picker.world(at: offset(aim, 60, -30))   // the grab offset
        let got = try XCTUnwrap(store.lights[0].aimPoint)
        XCTAssertEqual(got.x, want.x, accuracy: 1e-4)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-4)
        XCTAssertEqual(got.z, 0, accuracy: 1e-4)
        XCTAssertTrue(store.numberWrites.isEmpty)
        // The same point again: no write. A miss: no write, the dot stays.
        XCTAssertNil(interaction.move(&s, to: offset(to, 0, 0)))
        picker.misses = { _ in true }
        XCTAssertNil(interaction.move(&s, to: offset(to, 20, 0)))
        XCTAssertEqual(store.vectorWrites.count, 1)
        XCTAssertEqual(picker.prepares, 1)
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testNoPickerNoAimSession() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        XCTAssertNil(interaction.press(at: l.selected!.aimDot!, layout: l))
    }

    /// Per-tick seam counts: knob at most 2 number writes, ring and radius
    /// 1, aim 1 vector write; nothing performed (no Python, no console).
    func testPerTickCounts() throws {
        let (store, controller) = gizmoRig()
        let picker = FakePicker()
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        var l = try XCTUnwrap(layout(controller))
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        for k in 1...30 {
            let n = store.numberWrites.count
            interaction.move(&s, to: offset(l.knobs[0].centre, CGFloat(k) * 2, CGFloat(k)))
            XCTAssertLessThanOrEqual(store.numberWrites.count - n, 2)
        }
        l = try XCTUnwrap(layout(controller))
        let sel = try XCTUnwrap(l.selected)
        s = try XCTUnwrap(interaction.press(at: sel.outerHandle!.point, layout: l))
        for k in 1...20 {
            let n = store.numberWrites.count
            interaction.move(&s, to: offset(sel.outerHandle!.point, CGFloat(k) * 3, 0))
            XCTAssertLessThanOrEqual(store.numberWrites.count - n, 1)
        }
        s = try XCTUnwrap(interaction.press(at: sel.aimDot!, layout: l))
        for k in 1...20 {
            let n = store.vectorWrites.count
            interaction.move(&s, to: offset(sel.aimDot!, CGFloat(k) * 3, 0))
            XCTAssertLessThanOrEqual(store.vectorWrites.count - n, 1)
        }
        for _ in 1...4 {
            let n = store.numberWrites.count
            interaction.scrollWheel(at: l.knobs[0].centre, up: true, layout: l)
            XCTAssertLessThanOrEqual(store.numberWrites.count - n, 1)
        }
        XCTAssertGreaterThan(store.numberWrites.count, 10)
        XCTAssertGreaterThan(store.vectorWrites.count, 5)
        XCTAssertTrue(store.performed.isEmpty, "no button-press action per tick")
    }
}

// MARK: - Radius

@MainActor
final class LightGizmoRadiusTests: XCTestCase {

    func testWheelNotchesOnAKnob() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        XCTAssertEqual(interaction.scrollWheel(at: l.knobs[1].centre, up: true, layout: l), .ok)
        XCTAssertEqual(controller.selection.name, "fill", "selected first")
        XCTAssertEqual(store.lights[1].radius, 2.5)
        XCTAssertEqual(interaction.scrollWheel(at: l.knobs[1].centre, up: false, layout: l), .ok)
        XCTAssertEqual(store.lights[1].radius, 2)
        XCTAssertEqual(store.numberWrites.map(\.field), ["radius", "radius"])
        XCTAssertEqual(store.lights[1].beam, 45, "the beam is kept")
        XCTAssertNil(interaction.scrollWheel(at: CGPoint(x: 5, y: 5), up: true, layout: l))
        XCTAssertEqual(store.numberWrites.count, 2)
        store.lights[1].radius = 8
        store.clock += 1
        XCTAssertNil(interaction.scrollWheel(at: l.knobs[1].centre, up: true, layout: l), "at the end")
        XCTAssertEqual(store.numberWrites.count, 2)
    }

    func testTrackpadScrollIsLatched() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        XCTAssertNil(interaction.beginScroll(at: CGPoint(x: 5, y: 5), layout: l), "off a knob: the camera's")
        var s = try XCTUnwrap(interaction.beginScroll(at: l.knobs[0].centre, layout: l))
        XCTAssertNil(interaction.scroll(&s, deltaY: 10))
        XCTAssertEqual(interaction.scroll(&s, deltaY: 14), .ok)
        XCTAssertEqual(store.lights[0].radius, 3.5)
        XCTAssertEqual(interaction.scroll(&s, deltaY: 48), .ok, "two steps, one write")
        XCTAssertEqual(store.lights[0].radius, 4.5)
        XCTAssertEqual(interaction.scroll(&s, deltaY: -30), .ok)
        XCTAssertEqual(store.lights[0].radius, 4)
        XCTAssertEqual(store.numberWrites.count, 3)
        controller.select(name: "fill")   // the scroll stays latched to key
        XCTAssertNil(interaction.scroll(&s, deltaY: 40))
        XCTAssertEqual(store.numberWrites.count, 3)
        XCTAssertEqual(store.lights[1].radius, 2)
    }

    func testPinchOnAKnob() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        XCTAssertNil(interaction.beginPinch(at: CGPoint(x: 5, y: 5), layout: l))
        var s = try XCTUnwrap(interaction.beginPinch(at: l.knobs[2].centre, layout: l))
        XCTAssertEqual(controller.selection.name, "rim")
        XCTAssertEqual(interaction.pinch(&s, magnification: 1.5), .ok)
        XCTAssertEqual(store.lights[2].radius, 4.5)
        XCTAssertNil(interaction.pinch(&s, magnification: 1.52), "the same 0.5× step")
        XCTAssertEqual(store.numberWrites.map(\.field), ["radius"])
        XCTAssertEqual(store.lights[2].beam, 45)
    }
}

// MARK: - Highlight

@MainActor
final class LightGizmoHighlightTests: XCTestCase {

    func testMirrorRuleAwayFromTheOutline() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let picker = FakePicker()
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 500, y: 200), layout: l), .placed(rim: nil))
        XCTAssertEqual(picker.prepares, 1)
        XCTAssertEqual(store.performed.count, 1)
        guard case .highlight(let name, let x, let y, let rim, let pin) = store.performed[0] else {
            return XCTFail("\(store.performed)")
        }
        XCTAssertEqual(name, "key")
        XCTAssertEqual(x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(y, 1.0 / 3, accuracy: 1e-12)
        XCTAssertNil(rim)
        XCTAssertFalse(pin)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testRimRuleNearTheOutline() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let picker = FakePicker()
        picker.facing = 0.1
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 300, y: 300), layout: l), .placed(rim: 145))
        guard case .highlight(_, _, _, let rim, _) = store.performed.last else { return XCTFail() }
        XCTAssertEqual(rim, 145)
        picker.facing = 0.3
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 300, y: 300), layout: l), .placed(rim: nil),
                       "0.3 is the mirror rule")
    }

    func testAPinnedLightStaysPinned() throws {
        let (store, controller) = gizmoRig()
        XCTAssertEqual(controller.setPinned(true), .ok)
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller, picker: FakePicker().seam)
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 420, y: 310), layout: l), .placed(rim: nil))
        guard case .highlight(_, _, _, _, let pin) = store.performed.last else { return XCTFail() }
        XCTAssertTrue(pin)
    }

    func testAMissOrNoSelectionDoesNothing() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let picker = FakePicker()
        picker.misses = { _ in true }
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 420, y: 310), layout: l), .miss)
        XCTAssertTrue(store.performed.isEmpty)
        // Outside the scene rect (a letterbox bar): nothing picked or run.
        let (boxedStore, boxed) = gizmoRig { $0.projection = perspective(letterbox: 1) }
        let bl = try XCTUnwrap(layout(boxed))
        let p2 = FakePicker()
        XCTAssertEqual(LightGizmoInteraction(controller: boxed, picker: p2.seam)
                        .placeHighlight(at: CGPoint(x: 50, y: 300), layout: bl), .miss)
        XCTAssertEqual(p2.picks.count, 0)
        XCTAssertTrue(boxedStore.performed.isEmpty)
        // No selection (the mode ended).
        controller.end()
        XCTAssertEqual(interaction.placeHighlight(at: CGPoint(x: 420, y: 310), layout: l), .noSelection)
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertEqual(picker.prepares, 1)
    }
}

// MARK: - Press ownership

@MainActor
final class LightGizmoPointerTests: XCTestCase {

    func testAHitIsTheGizmosAndAMissTheCameras() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var pointer = LightGizmoPointer()
        let knob = l.knobs[0].centre
        XCTAssertEqual(pointer.press(at: knob, option: false, layout: l, interaction: interaction), .gizmo)
        XCTAssertTrue(pointer.ownsPress)
        XCTAssertEqual(pointer.drag(to: offset(knob, 30, 0), interaction: interaction), .gizmo)
        XCTAssertEqual(store.numberWrites.count, 2)
        XCTAssertEqual(pointer.release(at: offset(knob, 30, 0), interaction: interaction), .gizmo)
        XCTAssertFalse(pointer.ownsPress)

        let empty = CGPoint(x: 5, y: 5)
        XCTAssertEqual(pointer.press(at: empty, option: false, layout: l, interaction: interaction), .camera)
        XCTAssertEqual(pointer.drag(to: offset(empty, 30, 0), interaction: interaction), .camera)
        XCTAssertEqual(pointer.release(at: offset(empty, 30, 0), interaction: interaction), .camera)
        XCTAssertEqual(pointer.press(at: knob, option: false, layout: nil, interaction: interaction), .camera,
                       "no gizmo shown")
        XCTAssertEqual(store.numberWrites.count, 2)
    }

    func testAClickOnAKnobOnlySelects() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var pointer = LightGizmoPointer()
        XCTAssertEqual(pointer.press(at: l.knobs[1].centre, option: false, layout: l, interaction: interaction),
                       .gizmo)
        XCTAssertEqual(pointer.release(at: l.knobs[1].centre, interaction: interaction), .gizmo)
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testOptionClickOffTargetsPlacesAHighlight() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller, picker: FakePicker().seam)
        var pointer = LightGizmoPointer()
        let p = CGPoint(x: 500, y: 200)
        XCTAssertEqual(pointer.press(at: p, option: true, layout: l, interaction: interaction), .highlightCandidate)
        XCTAssertTrue(store.performed.isEmpty, "nothing at the press")
        XCTAssertEqual(pointer.drag(to: offset(p, 1, 1), interaction: interaction), .highlightCandidate)
        XCTAssertEqual(pointer.release(at: offset(p, 1, 1), interaction: interaction), .gizmo)
        XCTAssertEqual(pointer.lastHighlight, .placed(rim: nil))
        XCTAssertEqual(store.performed.count, 1, "one command for the click")
        // An option-drag stays the camera's.
        XCTAssertEqual(pointer.press(at: p, option: true, layout: l, interaction: interaction), .highlightCandidate)
        XCTAssertEqual(pointer.drag(to: offset(p, 10, 0), interaction: interaction), .camera)
        XCTAssertEqual(pointer.release(at: offset(p, 10, 0), interaction: interaction), .camera)
        XCTAssertEqual(store.performed.count, 1)
        // An option-press on a target is the target's.
        XCTAssertEqual(pointer.press(at: l.knobs[0].centre, option: true, layout: l, interaction: interaction),
                       .gizmo)
    }

    func testTheRestOfADragAfterTheModeEndedIsSwallowed() throws {
        let (store, controller) = gizmoRig()
        let interaction = LightGizmoInteraction(controller: controller)
        for viaEndSession in [false, true] {
            var pointer = LightGizmoPointer()
            controller.begin()
            let l = try XCTUnwrap(layout(controller))
            let knob = l.knobs[0].centre
            XCTAssertEqual(pointer.press(at: knob, option: false, layout: l, interaction: interaction), .gizmo)
            XCTAssertEqual(pointer.drag(to: offset(knob, 25, 0), interaction: interaction), .gizmo)
            let writes = store.numberWrites.count
            controller.end()   // Esc
            if viaEndSession { pointer.endSession() }
            XCTAssertEqual(pointer.drag(to: offset(knob, 50, 0), interaction: interaction), .gizmo)
            XCTAssertEqual(pointer.drag(to: offset(knob, 70, 10), interaction: interaction), .gizmo)
            XCTAssertEqual(pointer.release(at: offset(knob, 70, 10), interaction: interaction), .gizmo)
            XCTAssertEqual(store.numberWrites.count, writes, "nothing written after Esc")
            XCTAssertEqual(pointer.drag(to: offset(knob, 80, 10), interaction: interaction), .camera,
                           "the next press is new")
        }
    }

    func testACancelledTouchNeverDrivesTheNext() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var pointer = LightGizmoPointer()
        let knob = l.knobs[0].centre
        XCTAssertEqual(pointer.touchChanged(start: knob, at: offset(knob, 20, 0), layout: l,
                                            interaction: interaction), .gizmo)
        let writes = store.numberWrites.count
        XCTAssertGreaterThan(writes, 0)
        // The sequence is cancelled (no end); the next starts on empty space.
        let empty = CGPoint(x: 5, y: 5)
        XCTAssertEqual(pointer.touchChanged(start: empty, at: offset(empty, 20, 0), layout: l,
                                            interaction: interaction), .camera)
        XCTAssertEqual(pointer.touchChanged(start: empty, at: offset(empty, 40, 0), layout: l,
                                            interaction: interaction), .camera)
        XCTAssertEqual(store.numberWrites.count, writes, "the cancelled session wrote nothing more")
        XCTAssertEqual(pointer.touchEnded(at: offset(empty, 40, 0), interaction: interaction), .camera)
        // A new sequence on a knob starts a new session.
        let fill = l.knobs[1].centre
        XCTAssertEqual(pointer.touchChanged(start: fill, at: offset(fill, 0, 20), layout: l,
                                            interaction: interaction), .gizmo)
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(pointer.touchEnded(at: offset(fill, 0, 20), interaction: interaction), .gizmo)
    }
}

// MARK: - Mirroring

@MainActor
final class LightGizmoMirroringTests: XCTestCase {

    func testABarSelectMovesTheRingsInTheSameTurn() throws {
        let (_, controller) = gizmoRig()
        XCTAssertEqual(layout(controller)?.selected?.name, "key")
        controller.select(index: 2)
        let l = try XCTUnwrap(layout(controller))
        XCTAssertEqual(l.selected?.name, "rim")
        XCTAssertEqual(l.knobs[2].radius, 9)
        XCTAssertEqual(l.drawingOrder.last, 2)
    }

    func testAKnobPressSelectsInTheBarInspectorAndOrbitView() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        _ = LightGizmoInteraction(controller: controller).press(at: l.knobs[1].centre, layout: l)
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(LightsInspectorState(controller)?.name, "fill")
        XCTAssertEqual(LightsOrbitState(controller)?.selected.name, "fill")
        XCTAssertEqual(l.knobs.map(\.slot), l.knobs.map { controller.identitySlot(for: $0.name) })
    }

    func testAGizmoTickShowsInTheInspectorAndOrbitView() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        let to = s.trackball!.pointer(for: LightGizmoLayout.direction(orbit: -60, pitch: 40))
        XCTAssertEqual(interaction.move(&s, to: to), .ok)
        XCTAssertEqual(LightsInspectorState(controller)?.row(.orbit)?.value, -60)
        XCTAssertEqual(LightsInspectorState(controller)?.row(.pitch)?.value, 40)
        XCTAssertEqual(LightsOrbitState(controller)?.selected.orbit, -60)
        let after = try XCTUnwrap(layout(controller))
        assertPoint(after.knobs[0].centre, to, accuracy: 0.01, "the knob is under the pointer")
    }

    func testInspectorAndPlanEditsShowInTheGizmoInTheSameTurn() throws {
        let (_, controller) = gizmoRig()
        XCTAssertEqual(controller.set(.beam, 30), .ok)
        XCTAssertEqual(layout(controller)?.selected?.outerRing?.radius ?? 0, 30 * tan(15 * Double.pi / 180),
                       accuracy: 1e-3)
        let owner = try XCTUnwrap(controller.beginGesture())
        XCTAssertEqual(controller.set(.orbit, 30, owner: owner), .ok)   // a plan lamp tick
        let l = try XCTUnwrap(layout(controller))
        let d = LightGizmoLayout.direction(orbit: 30, pitch: 30)
        assertPoint(l.knobs[0].centre, CGPoint(x: l.centre.x + l.sphereRadius * CGFloat(d.x),
                                               y: l.centre.y - l.sphereRadius * CGFloat(d.y)), accuracy: 1e-3)
    }
}

// MARK: - Shadow chip and words

@MainActor
final class LightGizmoChipStateTests: XCTestCase {

    func testTheChipIsTheInspectorsShadow() throws {
        let (store, controller) = gizmoRig()
        var chip = try XCTUnwrap(LightGizmoState(controller)?.chip)
        XCTAssertEqual(chip.label, LightsInspectorState.shadowLabel)
        XCTAssertEqual(chip.help, LightsInspectorState.shadowHelp)
        XCTAssertEqual(chip.value, "Off")
        XCTAssertEqual(chip.identifier, "lights.gizmo.shadow")
        XCTAssertFalse(chip.isOn)
        XCTAssertEqual(LightGizmoInteraction(controller: controller).toggleShadow(), .ok)
        XCTAssertTrue(store.lights[0].shadow)
        chip = try XCTUnwrap(LightGizmoState(controller)?.chip)
        XCTAssertEqual(chip.value, LightsInspectorState(controller)?.shadowValue)
        XCTAssertEqual(chip.value, "On")
        XCTAssertEqual(store.numberWrites.map(\.field), ["shadow"])
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testAFourthShadowIsRefusedWithTheNotice() throws {
        let (store, controller) = gizmoRig {
            $0.setRig(["key", "fill", "rim", "light4"])
            for i in 1...3 { $0.lights[i].shadow = true }
        }
        XCTAssertEqual(LightGizmoInteraction(controller: controller).toggleShadow(), .refused)
        XCTAssertFalse(store.lights[0].shadow, "the core is unchanged")
        let chip = try XCTUnwrap(LightGizmoState(controller)?.chip)
        XCTAssertEqual(chip.notice, LightsInspectorState.shadowCapNotice)
        XCTAssertEqual(LightsInspectorState(controller)?.notice, chip.notice, "shown in both")
    }

    func testTheShadowsOffHint() throws {
        let (_, controller) = gizmoRig { $0.lights[0].shadow = true }
        XCTAssertEqual(LightGizmoState(controller, sceneShadowsOn: false)?.chip.showsHint, true)
        XCTAssertEqual(LightGizmoState(controller, sceneShadowsOn: true)?.chip.showsHint, false)
        XCTAssertEqual(LightGizmoState(controller, sceneShadowsOn: nil)?.chip.showsHint, false)
        let chip = try XCTUnwrap(LightGizmoState(controller, sceneShadowsOn: false)?.chip)
        XCTAssertEqual(chip.hint, LightsInspectorState.shadowsOffHint)
        XCTAssertEqual(chip.turnOnTitle, LightsInspectorState.turnOnTitle)
        XCTAssertEqual(chip.turnOnLabel, LightsInspectorState.turnOnLabel)
    }
}

@MainActor
final class LightGizmoStateTests: XCTestCase {

    func testSummaryAndVoiceOver() throws {
        let (_, controller) = gizmoRig()
        let state = try XCTUnwrap(LightGizmoState(controller))
        XCTAssertEqual(state.summary, "key,front:key|fill,behind:rim,beam:45.0,softness:0.40,aim:centre")
        XCTAssertEqual(state.knobs.map(\.label), ["key light", "fill light", "rim light"])
        XCTAssertEqual(state.knobs[0].value,
                       "in front of the molecule, orbit -45 degrees, pitch 30 degrees, radius 3.0 scene sizes, 30 angstroms")
        XCTAssertEqual(state.knobs[2].value,
                       "behind the molecule, orbit 160 degrees, pitch -20 degrees, radius 3.0 scene sizes, 30 angstroms")
        XCTAssertEqual(state.knobs.map(\.isSelected), [true, false, false])
        XCTAssertEqual(state.knobs.map(\.isBehind), [false, false, true])
        XCTAssertEqual(state.knobs[1].selectAction, "Select fill")
        XCTAssertEqual(state.knobs[1].identifier, "lights.gizmo.knob.fill")
        XCTAssertEqual(LightGizmoState.containerLabel, "Light gizmo")
        controller.end()
        XCTAssertNil(LightGizmoState(controller))
    }

    func testTheSummaryFollowsAFlip() throws {
        let (_, controller) = gizmoRig()
        let l = try XCTUnwrap(layout(controller))
        let interaction = LightGizmoInteraction(controller: controller)
        var s = try XCTUnwrap(interaction.press(at: l.knobs[0].centre, layout: l))
        // Out past the band to the left, then released outside the disc.
        let out = CGPoint(x: l.centre.x - l.sphereRadius - 20, y: l.centre.y)
        interaction.move(&s, to: offset(l.knobs[0].centre, -5, 0))
        interaction.move(&s, to: out)
        XCTAssertEqual(s.isBehind, true)
        XCTAssertTrue(s.isOutside)
        XCTAssertTrue(controller.isBehind("key"), "core, chip and knob agree at once")
        XCTAssertTrue(try XCTUnwrap(layout(controller)).knobs[0].isBehind)
        XCTAssertEqual(LightGizmoState(controller)?.summary,
                       "key,front:fill,behind:key|rim,beam:45.0,softness:0.40,aim:centre")
    }
}

// MARK: - DEBUG gestures

#if DEBUG
@MainActor
final class GizmoAutoGestureTests: XCTestCase {

    func testParse() {
        XCTAssertEqual(GizmoAutoGesture.parse("knob:key:-60:40"), .knob("key", -60, 40))
        XCTAssertEqual(GizmoAutoGesture.parse(" flip:key "), .flip("key"))
        XCTAssertEqual(GizmoAutoGesture.parse("outer:30"), .outer(30))
        XCTAssertEqual(GizmoAutoGesture.parse("inner:0.6"), .inner(0.6))
        XCTAssertEqual(GizmoAutoGesture.parse("aimat:0.15:0.05"), .aimAt(0.15, 0.05))
        XCTAssertEqual(GizmoAutoGesture.parse("wheel:key:-2"), .wheel("key", -2))
        XCTAssertEqual(GizmoAutoGesture.parse("kpinch:rim:1.5"), .pinch("rim", 1.5))
        XCTAssertEqual(GizmoAutoGesture.parse("hl:0.1:-0.2"), .highlight(0.1, -0.2))
        XCTAssertEqual(GizmoAutoGesture.parse("gshadow:1"), .shadow(true))
        XCTAssertEqual(GizmoAutoGesture.parse("GSHADOW:0"), .shadow(false))
        for bad in ["knob:key:30", "knob::30:0", "flip:", "outer:x", "inner:", "aimat:1", "wheel:key:1.5",
                    "wheel:key:0", "kpinch:rim:0", "kpinch:rim", "hl:1:nan", "gshadow:2", "orbit:30", "tap:fill"] {
            XCTAssertNil(GizmoAutoGesture.parse(bad), bad)
        }
        for g: GizmoAutoGesture in [.knob("key", -60, 40), .flip("key"), .outer(30), .inner(0.6),
                                    .aimAt(0.15, 0.05), .wheel("key", -2), .pinch("rim", 1.5),
                                    .highlight(0.1, -0.2), .shadow(true)] {
            XCTAssertEqual(GizmoAutoGesture.parse(g.token), g, g.token)
        }
    }

    func testNoKeyCollisions() {
        let inspector: Set<String> = Set(LightParameter.allCases.map(\.rawValue))
            .union(["expand", "pin", "shadow", "color", "colour"])
        XCTAssertTrue(GizmoAutoGesture.keys.isDisjoint(with: inspector))
        XCTAssertTrue(GizmoAutoGesture.keys.isDisjoint(with: OrbitAutoGesture.keys))
        for key in OrbitAutoGesture.keys.union(inspector) {
            XCTAssertFalse(GizmoAutoGesture.claims(key + ":1"), key)
        }
        for key in GizmoAutoGesture.keys {
            XCTAssertFalse(OrbitAutoGesture.claims(key + ":1"), key)
            XCTAssertTrue(GizmoAutoGesture.claims(key.uppercased() + ":x"), key)
        }
    }

    func testLightsAutoEditClaimsTheGizmoTokens() {
        let parsed = LightsAutoEdit.parse("orbit:30;knob:key:-60:40;tap:fill;gshadow:1;outer:x;expand")
        XCTAssertEqual(parsed.tokens, [.set(.orbit, 30), .gizmo(.knob("key", -60, 40)), .gesture(.tap("fill")),
                                       .gizmo(.shadow(true)), .expand])
        XCTAssertEqual(parsed.rejected, ["outer:x"], "a gizmo key never reaches the inspector's forms")
        let (_, controller) = gizmoRig()
        XCTAssertEqual(LightsAutoEdit.apply([.gizmo(.flip("key"))], to: controller), ["flip:key -> noview"])
    }

    private func context(_ picker: FakePicker? = nil) -> GizmoAutoContext {
        GizmoAutoContext(viewSize: viewSize, picker: picker?.seam, gridMode: false, sceneShadowsOn: true,
                         metrics: LightGizmoMetrics(slop: 6))
    }

    func testAppliesThroughTheInteraction() throws {
        let (store, controller) = gizmoRig()
        let picker = FakePicker()
        func run(_ token: String) -> String {
            GizmoAutoGesture.apply(GizmoAutoGesture.parse(token)!, to: controller, context: context(picker))
        }
        XCTAssertEqual(run("knob:key:-60:40"), "knob:key:-60:40 -> ok orbit=-60 pitch=40")
        XCTAssertEqual(store.lights[0].orbit, -60)
        XCTAssertEqual(store.lights[0].pitch, 40)
        XCTAssertEqual(run("outer:30"), "outer:30 -> ok beam=30.0")
        XCTAssertEqual(store.lights[0].beam, 30)
        XCTAssertEqual(run("inner:0.6"), "inner:0.6 -> ok softness=0.60")
        XCTAssertEqual(store.lights[0].softness, 0.6, accuracy: 1e-12)
        XCTAssertEqual(run("aimat:0.1:0.05"), "aimat:0.1:0.05 -> ok aim=4.75,1.78,0.00")
        XCTAssertEqual(run("wheel:fill:2"), "wheel:fill:2 -> ok radius=3.00")
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(run("kpinch:rim:1.5"), "kpinch:rim:1.5 -> ok radius=4.50")
        XCTAssertEqual(run("gshadow:1"), "gshadow:1 -> ok shadow=1")
        XCTAssertEqual(run("gshadow:1"), "gshadow:1 -> none shadow=1")
        XCTAssertTrue(store.lights[2].shadow)
        XCTAssertTrue(store.performed.isEmpty, "no command so far")
        XCTAssertEqual(run("hl:0.25:0.1"), "hl:0.25:0.1 -> placed rim=none aim=0.00,0.00,1.00")
        XCTAssertEqual(store.performed.count, 1)
        XCTAssertEqual(run("knob:nobody:0:0"), "knob:nobody:0:0 -> miss")
    }

    func testFlipCrossesTheBand() throws {
        let (store, controller) = gizmoRig()
        let line = GizmoAutoGesture.apply(.flip("key"), to: controller, context: context())
        XCTAssertEqual(line, "flip:key -> ok orbit=-135 pitch=30 behind=1")
        XCTAssertEqual(store.lights[0].orbit, -135)
        XCTAssertTrue(controller.isBehind("key"))
        // And a knob token to the other side goes out and back in.
        XCTAssertEqual(GizmoAutoGesture.apply(.knob("key", -30, 20), to: controller, context: context()),
                       "knob:key:-30:20 -> ok orbit=-30 pitch=20")
        XCTAssertFalse(controller.isBehind("key"))
    }

    // MARK: #623's touch tokens

    func testParseTheTouchTokens() {
        XCTAssertEqual(GizmoAutoGesture.parse("tpinch:key:1.5"), .touchPinch("key", 1.5, nil))
        XCTAssertEqual(GizmoAutoGesture.parse("TPINCH:key:1.5:200"), .touchPinch("key", 1.5, 200))
        XCTAssertEqual(GizmoAutoGesture.parse("lpress:0.2:-0.1"), .longPress(0.2, -0.1))
        XCTAssertEqual(GizmoAutoGesture.parse("lpress:key"), .longPressKnob("key"))
        XCTAssertEqual(GizmoAutoGesture.parse("gprobe:fill:21.9:0"), .probe("fill", 21.9, 0))
        for bad in ["tpinch:key", "tpinch:key:0", "tpinch::1.5", "tpinch:key:1.5:0", "tpinch:key:1.5:x",
                    "tpinch:key:1.5:200:1", "lpress", "lpress:", "lpress:1:x", "lpress:1:2:3",
                    "gprobe:fill:1", "gprobe::1:2", "gprobe:fill:x:0"] {
            XCTAssertNil(GizmoAutoGesture.parse(bad), bad)
        }
        for g: GizmoAutoGesture in [.touchPinch("key", 1.5, nil), .touchPinch("key", 2, 200),
                                    .longPress(0.2, -0.1), .longPressKnob("rim"), .probe("fill", 21.9, -3)] {
            XCTAssertEqual(GizmoAutoGesture.parse(g.token), g, g.token)
            XCTAssertTrue(GizmoAutoGesture.claims(g.token), g.token)
        }
        XCTAssertEqual(GizmoAutoGesture.touchPinch("key", 1.5, 200).token, "tpinch:key:1.5:200")
    }

    /// `tpinch`: the pan decides on the knob, the pinch opens by name off it,
    /// the radius moves on the 0.5× grid and nothing else; a wide span is
    /// the camera's and writes nothing.
    func testTouchPinchThroughTheSequence() throws {
        let (store, controller) = gizmoRig()
        func run(_ token: String) -> String {
            GizmoAutoGesture.apply(GizmoAutoGesture.parse(token)!, to: controller, context: context())
        }
        XCTAssertEqual(run("tpinch:key:1.5:200"),
                       "tpinch:key:1.5:200 -> none owner=camera radius=3.00 beam=45.0 pan=camera twist=camera reset=1")
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(run("tpinch:key:1.5"),
                       "tpinch:key:1.5 -> ok owner=gizmo(key) radius=4.50 beam=45.0 pan=ignored twist=ignored reset=1")
        XCTAssertEqual(store.numberWrites.map(\.field), ["radius", "radius", "radius"],
                       "one write per 0.5× step (3.5, 4, 4.5), radius only")
        XCTAssertEqual(run("tpinch:fill:2:120"),
                       "tpinch:fill:2:120 -> ok owner=gizmo(fill) radius=4.00 beam=45.0 pan=ignored twist=ignored reset=1")
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(store.lights[1].orbit, 60)
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertEqual(run("tpinch:nobody:2"), "tpinch:nobody:2 -> miss")
    }

    /// `lpress` declines on a knob and places a highlight off the targets;
    /// `gprobe` names the target at an offset from a knob, with the iOS
    /// 44 pt floor (21.9 pt hits, 22.1 pt is the camera's).
    func testLongPressAndProbeTokens() throws {
        let (store, controller) = gizmoRig()
        let picker = FakePicker()
        XCTAssertEqual(GizmoAutoGesture.apply(.longPressKnob("fill"), to: controller, context: context(picker)),
                       "lpress:fill -> route=declined")
        XCTAssertTrue(store.performed.isEmpty)
        let line = GizmoAutoGesture.apply(.longPress(0.25, 0.1), to: controller, context: context(picker))
        XCTAssertTrue(line.hasPrefix("lpress:0.25:0.1 -> route=highlight -> placed rim=none"), line)
        XCTAssertEqual(store.performed.count, 1)
        XCTAssertEqual(GizmoAutoGesture.apply(.longPressKnob("nobody"), to: controller, context: context(picker)),
                       "lpress:nobody -> miss")

        var ios = context()
        ios.metrics = LightGizmoMetrics(slop: 14, minimumTarget: 44)
        XCTAssertEqual(GizmoAutoGesture.apply(.probe("fill", 21.9, 0), to: controller, context: ios),
                       "gprobe:fill:21.9:0 -> knob:fill touch=44")
        XCTAssertEqual(GizmoAutoGesture.apply(.probe("fill", 22.1, 0), to: controller, context: ios),
                       "gprobe:fill:22.1:0 -> camera touch=44")
        XCTAssertEqual(GizmoAutoGesture.apply(.probe("fill", 21.9, 0), to: controller, context: context()),
                       "gprobe:fill:21.9:0 -> camera touch=0", "macOS: 7 + 6")
        XCTAssertEqual(GizmoAutoGesture.apply(.probe("nobody", 0, 0), to: controller, context: ios),
                       "gprobe:nobody:0:0 -> miss")
    }

    func testWithoutAViewOrALayout() {
        let (_, controller) = gizmoRig()
        XCTAssertEqual(GizmoAutoGesture.apply(.outer(30), to: controller, context: nil), "outer:30 -> noview")
        var grid = context()
        grid.gridMode = true
        XCTAssertEqual(GizmoAutoGesture.apply(.outer(30), to: controller, context: grid), "outer:30 -> nolayout")
        XCTAssertEqual(GizmoAutoGesture.apply(.aimAt(0, 0), to: controller, context: context()),
                       "aimat:0:0 -> miss", "no picker: no aim session")
    }
}
#endif
