import CoreGraphics
import SwiftUI
import XCTest
@testable import RayMol

// The Lights tools' touch targets (#623 Part 1): the 44 pt floor in every
// orbit-view and gizmo hit test, the iOS ring-handle separation, the #693
// in-view handle rule, the overlay's knob frames and chip placement by
// reach, and the iOS swatch columns. The iOS profile (slop 14, minimum
// target 44) is passed as a parameter, so these macOS tests check the iOS
// numbers; the macOS profile (slop 6, minimum 0) must be unchanged.

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

private func offset(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
    CGPoint(x: p.x + dx, y: p.y + dy)
}

/// Eight unit directions: the axes and the diagonals.
private let eightDirections: [CGVector] = (0..<8).map { k in
    let a = Double(k) * .pi / 4
    return CGVector(dx: cos(a), dy: sin(a))
}

private func along(_ p: CGPoint, _ u: CGVector, _ d: CGFloat) -> CGPoint {
    CGPoint(x: p.x + u.dx * d, y: p.y + u.dy * d)
}

/// Sketch 2's three lights (key −45° / +35° / 3.0×, selected; fill 60° /
/// 2.0×; rim 150° / 4.0×) and a controller in Lights mode on them.
@MainActor
private func orbitRig() -> (FakeRigStore, LightsController) {
    let store = FakeRigStore()
    store.setRig(["key", "fill", "rim"])
    store.lights[0].orbit = -45
    store.lights[0].pitch = 35
    store.lights[0].radius = 3
    store.lights[1].orbit = 60
    store.lights[1].pitch = 10
    store.lights[1].radius = 2
    store.lights[2].orbit = 150
    store.lights[2].pitch = -15
    store.lights[2].radius = 4
    let controller = LightsController(seams: store.seams)
    controller.begin()
    return (store, controller)
}

/// The gizmo's test rig (LightGizmoTests): key (-45°, +30°, 3×, selected),
/// fill (60°, +10°, 2×), rim (160°, -20°, 3×, behind), faithful eye space
/// under a perspective camera 200 Å away, with the gizmo's demand.
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
    store.eyeOffset = SIMD3<Double>(0, 0, -200)
    store.projection = LightCameraProjection(orthoscopic: false, fovDegrees: 20, cameraDistance: 200,
                                             letterboxAspect: 0)
    setup(store)
    let controller = LightsController(seams: store.seams)
    controller.eyeDemand = .everyFrame
    controller.begin()
    return (store, controller)
}

private let gizmoViewSize = CGSize(width: 800, height: 600)

@MainActor
private func gizmoLayout(_ controller: LightsController, metrics: LightGizmoMetrics,
                         size: CGSize = gizmoViewSize) -> LightGizmoLayout? {
    LightGizmoLayout.make(LightGizmoInputs(controller: controller, viewSize: size, gridMode: false,
                                           sceneShadowsOn: true),
                          metrics: metrics)
}

/// The iOS and macOS touch profiles.
private let iosMetrics = LightGizmoMetrics(slop: 14, minimumTarget: 44)
private let macMetrics = LightGizmoMetrics(slop: 6, minimumTarget: 0)

/// Knob A (unselected, front) at (200, 150), C (behind) at (200, 450),
/// the selected knob B at (600, 120); B's aim dot at (600, 400) inside
/// its rings (outer 100 pt, inner 50 pt, 72 samples each), its handles
/// on the rings to the right.
private func handLayout(_ metrics: LightGizmoMetrics) throws -> LightGizmoLayout {
    let camera = LightCameraProjection(orthoscopic: false, fovDegrees: 20, cameraDistance: 200,
                                       letterboxAspect: 0)
    let projection = try XCTUnwrap(LightGizmoProjection(camera: camera, viewSize: gizmoViewSize))
    let placement = LightPlacement(orbit: 0, pitch: 0, radius: 3)
    func knob(_ name: String, _ index: Int, _ centre: CGPoint, selected: Bool, behind: Bool)
        -> LightGizmoLayout.Knob {
        LightGizmoLayout.Knob(
            name: name, index: index, slot: index, centre: centre,
            radius: selected ? metrics.selectedKnobRadius : metrics.knobRadius,
            direction: SIMD3(0, 0, 1), placement: placement, isSelected: selected, isBehind: behind,
            isShadowed: false, isShadowDimmed: false, opacity: 1, label: name,
            labelPoint: offset(centre, 0, -14), labelDirection: CGVector(dx: 0, dy: -1))
    }
    let aim = CGPoint(x: 600, y: 400)
    func ring(_ r: CGFloat) -> LightGizmoLayout.Ring {
        LightGizmoLayout.Ring(radius: Double(r) / 10, samples: (0..<72).map { k in
            let a = Double(k) * 2 * .pi / 72
            return CGPoint(x: aim.x + r * CGFloat(cos(a)), y: aim.y + r * CGFloat(sin(a)))
        })
    }
    var selected = LightGizmoLayout.Selected(
        name: "b", index: 1, placement: placement, beam: 45, softness: 0.5, target: SIMD3(0, 0, -200),
        direction: SIMD3(0, 0, -1), aimDistance: 30, cosOuter: 0.7, cosInner: 0.9, aimDot: aim)
    selected.outerRing = ring(100)
    selected.innerRing = ring(50)
    selected.outerHandle = .init(point: offset(aim, 100, 0), ringPoint: offset(aim, 100, 0), isOffRing: false)
    selected.innerHandle = .init(point: offset(aim, 50, 0), ringPoint: offset(aim, 50, 0), isOffRing: false)
    return LightGizmoLayout(
        projection: projection, metrics: metrics, centre: CGPoint(x: 400, y: 300), sphereRadius: 150,
        knobs: [knob("a", 0, CGPoint(x: 200, y: 150), selected: false, behind: false),
                knob("b", 1, CGPoint(x: 600, y: 120), selected: true, behind: false),
                knob("c", 2, CGPoint(x: 200, y: 450), selected: false, behind: true)],
        drawingOrder: [2, 0, 1], selected: selected, isOn: true, rigSize: 10)
}

@MainActor
final class LightsTouchTargetTests: XCTestCase {

    // MARK: the rule

    func testTheFloorAndTheReach() {
        #if os(macOS)
        XCTAssertEqual(LightsTouch.minimumTarget, 0, "macOS keeps the pointer reach")
        #else
        XCTAssertEqual(LightsTouch.minimumTarget, 44)
        #endif
        XCTAssertEqual(LightsTouch.reach(drawn: 6, slop: 14, minimumTarget: 44), 22, "a floor")
        XCTAssertEqual(LightsTouch.reach(drawn: 9, slop: 14, minimumTarget: 44), 23, "not a bigger slop")
        XCTAssertEqual(LightsTouch.reach(drawn: 6, slop: 6, minimumTarget: 0), 12, "macOS unchanged")
        XCTAssertEqual(LightGizmoMetrics(slop: 14, minimumTarget: 44).handleSeparation, 44,
                       "iOS handle targets never overlap")
        XCTAssertEqual(LightGizmoMetrics(slop: 14).handleSeparation, 12,
                       "macOS default profile with the iOS slop keeps 12")
        XCTAssertEqual(LightGizmoMetrics(slop: 6).handleSeparation, 12)
        XCTAssertEqual(LightGizmoMetrics().minimumTarget, LightsTouch.minimumTarget)
        XCTAssertEqual(OrbitPlanLayout(extent: 4).minimumTarget, LightsTouch.minimumTarget)
        XCTAssertEqual(PitchArcLayout().minimumTarget, LightsTouch.minimumTarget)
    }

    func testSwatchColumns() {
        XCTAssertEqual(LightsTouch.swatchColumns(width: 351), 6, "the phone sheet")
        XCTAssertEqual(LightsTouch.swatchColumns(width: 264), 6, "six 44 pt targets exactly")
        XCTAssertEqual(LightsTouch.swatchColumns(width: 263.9), 3)
        XCTAssertEqual(LightsTouch.swatchColumns(width: 260), 3, "the 284 pt card's content")
    }

    // MARK: the orbit plan

    func testPlanLampsHaveA22PointFloor() throws {
        let (_, controller) = orbitRig()
        let state = try XCTUnwrap(LightsOrbitState(controller))
        let ios = OrbitPlanLayout(extent: state.extent, slop: 14, minimumTarget: 44)
        let slop14 = OrbitPlanLayout(extent: state.extent, slop: 14, minimumTarget: 0)
        let mac = OrbitPlanLayout(extent: state.extent, slop: 6, minimumTarget: 0)
        for lamp in state.lamps {
            let target = OrbitTarget.lamp(name: lamp.name, index: lamp.index)
            for u in eightDirections {
                let c = ios.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
                let near = along(c, u, 21.9), far = along(c, u, 22.1)
                XCTAssertEqual(OrbitHitTest.plan(at: near, layout: ios, state: state), target,
                               "\(lamp.name) \(u) at 21.9")
                XCTAssertNotEqual(OrbitHitTest.plan(at: far, layout: ios, state: state), target,
                                  "\(lamp.name) \(u) at 22.1")
                if !lamp.isSelected {
                    // Drawn 6 + slop 14 = 20 < 22: only the floor reaches 21.9.
                    XCTAssertNil(OrbitHitTest.plan(at: far, layout: ios, state: state), "\(lamp.name) \(u)")
                    XCTAssertNotEqual(OrbitHitTest.plan(at: near, layout: slop14, state: state), target,
                                      "\(lamp.name) \(u): no floor, no hit at 21.9")
                }
            }
            // macOS: drawn plus 6, as before.
            let c = mac.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            let reach = (lamp.isSelected ? LightsOrbitMetrics.selectedLampRadius : LightsOrbitMetrics.lampRadius) + 6
            let t = LightAngles.offset(orbit: lamp.orbit + 90)
            let tangent = CGVector(dx: t.dx, dy: t.dy)
            XCTAssertEqual(OrbitHitTest.plan(at: along(c, tangent, reach - 0.1), layout: mac, state: state),
                           target, lamp.name)
            XCTAssertNil(OrbitHitTest.plan(at: along(c, tangent, reach + 0.1), layout: mac, state: state),
                         lamp.name)
        }
    }

    func testTheSquareHasA22PointFloorPerAxis() throws {
        let (_, controller) = orbitRig()
        let state = try XCTUnwrap(LightsOrbitState(controller))
        let ios = OrbitPlanLayout(extent: state.extent, slop: 14, minimumTarget: 44)
        let s = state.selected
        let c = ios.squarePoint(orbit: s.orbit, radius: s.radius, angle: ios.squareAngle(radius: s.radius))
        XCTAssertEqual(ios.squareReach, 22, "5 + 14 = 19 becomes 22")
        // On the axes: 22.1 misses the square.
        for (dx, dy) in [(22.1, 0.0), (-22.1, 0), (0, 22.1), (0, -22.1)] {
            XCTAssertNotEqual(OrbitHitTest.plan(at: offset(c, dx, dy), layout: ios, state: state), .radiusSquare,
                              "(\(dx), \(dy))")
        }
        // A 44 pt box: its corners at (21.9, 21.9) still hit.
        for (dx, dy) in [(21.9, 21.9), (-21.9, 21.9), (21.9, -21.9), (-21.9, -21.9)] {
            XCTAssertEqual(OrbitHitTest.plan(at: offset(c, dx, dy), layout: ios, state: state), .radiusSquare,
                           "(\(dx), \(dy))")
        }
        // macOS: half side 5 plus slop 6.
        let mac = OrbitPlanLayout(extent: state.extent, slop: 6, minimumTarget: 0)
        let m = mac.squarePoint(orbit: s.orbit, radius: s.radius, angle: mac.squareAngle(radius: s.radius))
        XCTAssertEqual(mac.squareReach, 11)
        XCTAssertEqual(OrbitHitTest.plan(at: offset(m, 10.9, 10.9), layout: mac, state: state), .radiusSquare)
        XCTAssertNil(OrbitHitTest.plan(at: offset(m, 11.1, 0), layout: mac, state: state))
    }

    func testThePitchHandleAndTrackHaveA22PointFloor() {
        let ios = PitchArcLayout(slop: 14, minimumTarget: 44)
        let mac = PitchArcLayout(slop: 6, minimumTarget: 0)
        XCTAssertEqual(ios.handleReach, 22, "7 + 14 = 21 becomes 22")
        XCTAssertEqual(ios.trackReach, 22, "14 becomes 22")
        XCTAssertEqual(mac.handleReach, 13)
        XCTAssertEqual(mac.trackReach, 6)
        let pitch = 10.0
        let h = ios.point(pitch: pitch)
        for u in eightDirections {
            XCTAssertEqual(OrbitHitTest.pitch(at: along(h, u, 21.9), layout: ios, pitch: pitch), .pitchHandle,
                           "\(u)")
            XCTAssertNotEqual(OrbitHitTest.pitch(at: along(h, u, 22.1), layout: ios, pitch: pitch), .pitchHandle,
                              "\(u)")
        }
        // The track at -60°, away from the handle, perpendicular to the arc.
        let p = ios.point(pitch: -60)
        let o = LightAngles.offset(pitch: -60)
        let outward = CGVector(dx: o.dx, dy: o.dy), inward = CGVector(dx: -o.dx, dy: -o.dy)
        for u in [outward, inward] {
            XCTAssertEqual(OrbitHitTest.pitch(at: along(p, u, 21.9), layout: ios, pitch: 80), .pitchTrack)
            XCTAssertNil(OrbitHitTest.pitch(at: along(p, u, 22.1), layout: ios, pitch: 80))
        }
        XCTAssertNil(OrbitHitTest.pitch(at: along(p, outward, 6.1), layout: mac, pitch: 80), "macOS unchanged")
        XCTAssertEqual(OrbitHitTest.pitch(at: along(p, outward, 5.9), layout: mac, pitch: 80), .pitchTrack)
    }

    /// The square's angle needs a chord of 2·max(selected lamp + slop, 22):
    /// 44 on iOS and 28 on macOS, both as before the floor.
    func testTheSquareAngleIsUnchangedInBothProfiles() {
        func before(_ radius: Double, _ layout: OrbitPlanLayout) -> Double {
            let r = Double(layout.drawnDistance(radius: radius))
            let needed = 2 * Double(LightsOrbitMetrics.selectedLampRadius + layout.slop)
            if 2 * r * sin(45.0 / 2 * .pi / 180) >= needed { return 45 }
            guard needed < 2 * r else { return 180 }
            return 2 * asin(needed / (2 * r)) * 180 / .pi
        }
        let ios = OrbitPlanLayout(extent: 4, slop: 14, minimumTarget: 44)
        let mac = OrbitPlanLayout(extent: 4, slop: 6, minimumTarget: 0)
        for radius in [0.0, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6] {
            XCTAssertEqual(ios.squareAngle(radius: radius), before(radius, ios), accuracy: 1e-12, "\(radius)")
            XCTAssertEqual(mac.squareAngle(radius: radius), before(radius, mac), accuracy: 1e-12, "\(radius)")
        }
        // A small ring needs a wider angle on iOS than on macOS.
        XCTAssertGreaterThan(ios.squareAngle(radius: 1), mac.squareAngle(radius: 1))
    }

    // MARK: the gizmo, on a layout placed by hand

    func testRoundGizmoTargetsHaveA22PointFloor() throws {
        let ios = try handLayout(iosMetrics)
        let mac = try handLayout(macMetrics)
        let aim = try XCTUnwrap(ios.selected?.aimDot)
        for u in eightDirections {
            for knob in ios.knobs where !knob.isSelected {
                // Drawn 7 + 14 = 21 < 22: the floor.
                XCTAssertEqual(LightGizmoHitTest.target(at: along(knob.centre, u, 21.9), layout: ios),
                               .knob(knob.name), "\(knob.name) \(u)")
                XCTAssertEqual(LightGizmoHitTest.knob(at: along(knob.centre, u, 21.9), layout: ios), knob.name)
                XCTAssertNil(LightGizmoHitTest.target(at: along(knob.centre, u, 22.1), layout: ios),
                             "\(knob.name) \(u)")
                // macOS: 7 + 6.
                XCTAssertEqual(LightGizmoHitTest.target(at: along(knob.centre, u, 12.9), layout: mac),
                               .knob(knob.name))
                XCTAssertNil(LightGizmoHitTest.target(at: along(knob.centre, u, 13.1), layout: mac))
            }
            // The selected knob keeps its larger reach (9 + 14 = 23).
            let b = ios.knobs[1]
            XCTAssertEqual(LightGizmoHitTest.target(at: along(b.centre, u, 22.9), layout: ios), .knob("b"))
            XCTAssertNil(LightGizmoHitTest.target(at: along(b.centre, u, 23.1), layout: ios))
            // The aim dot: 4 + 14 = 18 becomes 22.
            XCTAssertEqual(LightGizmoHitTest.target(at: along(aim, u, 21.9), layout: ios), .aimDot, "\(u)")
            XCTAssertNil(LightGizmoHitTest.target(at: along(aim, u, 22.1), layout: ios), "\(u)")
            XCTAssertNil(LightGizmoHitTest.target(at: along(aim, u, 10.1), layout: mac), "macOS: 4 + 6")
        }
    }

    func testHandlesHaveA22PointFloorPerAxis() throws {
        let ios = try handLayout(iosMetrics)
        let s = try XCTUnwrap(ios.selected)
        XCTAssertEqual(iosMetrics.handleReach, 22, "4.5 + 14 = 18.5 becomes 22")
        XCTAssertEqual(macMetrics.handleReach, 10.5)
        for (handle, target) in [(s.outerHandle!.point, LightGizmoTarget.outerHandle),
                                 (s.innerHandle!.point, LightGizmoTarget.innerHandle)] {
            for (dx, dy) in [(21.9, 21.9), (-21.9, 21.9), (21.9, -21.9), (-21.9, -21.9)] {
                XCTAssertEqual(LightGizmoHitTest.target(at: offset(handle, dx, dy), layout: ios), target,
                               "\(target) (\(dx), \(dy))")
            }
            for (dx, dy) in [(22.1, 0.0), (-22.1, 0), (0, 22.1), (0, -22.1)] {
                XCTAssertNotEqual(LightGizmoHitTest.target(at: offset(handle, dx, dy), layout: ios), target,
                                  "\(target) (\(dx), \(dy))")
            }
        }
    }

    func testRingLinesHaveA22PointFloor() throws {
        let ios = try handLayout(iosMetrics)
        let mac = try handLayout(macMetrics)
        let aim = CGPoint(x: 600, y: 400)
        // The outer ring at 180° (left of the aim dot), the inner one at 90°
        // (below it): sample points, away from the handles, perpendicular to
        // the line in both directions.
        let outer = offset(aim, -100, 0), inner = offset(aim, 0, 50)
        for (p, u, target) in [(outer, CGVector(dx: -1, dy: 0), LightGizmoTarget.outerRing),
                               (outer, CGVector(dx: 1, dy: 0), .outerRing),
                               (inner, CGVector(dx: 0, dy: 1), .innerRing),
                               (inner, CGVector(dx: 0, dy: -1), .innerRing)] {
            XCTAssertEqual(LightGizmoHitTest.target(at: along(p, u, 21.9), layout: ios), target, "\(target) \(u)")
            XCTAssertNil(LightGizmoHitTest.target(at: along(p, u, 22.1), layout: ios), "\(target) \(u)")
            XCTAssertNil(LightGizmoHitTest.knob(at: along(p, u, 21.9), layout: ios), "rings are not knobs")
        }
        // macOS: half the stroke plus 6.
        XCTAssertEqual(LightGizmoHitTest.target(at: offset(outer, -6.9, 0), layout: mac), .outerRing)
        XCTAssertNil(LightGizmoHitTest.target(at: offset(outer, -7.1, 0), layout: mac))
    }

    /// 22.1 pt from every target is the camera's, in all eight directions.
    func testOffTargetIsCamera() throws {
        let ios = try handLayout(iosMetrics)
        let s = try XCTUnwrap(ios.selected)
        var points: [CGPoint] = []
        for knob in ios.knobs where !knob.isSelected {
            points += eightDirections.map { along(knob.centre, $0, 22.1) }
        }
        points += eightDirections.map { along(ios.knobs[1].centre, $0, 23.1) }
        points += eightDirections.map { along(s.aimDot!, $0, 22.1) }
        for p in points {
            XCTAssertNil(LightGizmoHitTest.target(at: p, layout: ios), "\(p)")
        }
        XCTAssertNil(LightGizmoHitTest.target(at: CGPoint(x: 5, y: 5), layout: ios), "empty space")
        XCTAssertNil(LightGizmoHitTest.target(at: offset(s.aimDot!, -75, 0), layout: ios),
                     "between the rings, 25 pt from each")
    }

    // MARK: the gizmo, laid out from the rig

    func testIOSHandlesKeep44PointsApart() throws {
        for softness in [0.0, 0.4, 1.0] {
            let (_, controller) = gizmoRig { $0.lights[0].softness = softness }
            let s = try XCTUnwrap(gizmoLayout(controller, metrics: iosMetrics)?.selected)
            let aim = try XCTUnwrap(s.aimDot)
            let outer = try XCTUnwrap(s.outerHandle).point, inner = try XCTUnwrap(s.innerHandle).point
            XCTAssertGreaterThanOrEqual(dist(outer, aim), 88 - 1e-9, "\(softness)")
            XCTAssertGreaterThanOrEqual(dist(inner, aim), 44 - 1e-9, "\(softness)")
            XCTAssertGreaterThanOrEqual(dist(inner, outer), 44 - 1e-6, "\(softness)")
            // Each handle is still hit at its own centre.
            let l = try XCTUnwrap(gizmoLayout(controller, metrics: iosMetrics))
            XCTAssertEqual(LightGizmoHitTest.target(at: outer, layout: l), .outerHandle, "\(softness)")
            XCTAssertEqual(LightGizmoHitTest.target(at: inner, layout: l), .innerHandle, "\(softness)")
        }
    }

    /// #693: handles that would leave the view move to the rightmost ring
    /// sample whose two handles stay inside it; handles already inside never
    /// move.
    func testHandlesStayInsideTheView() throws {
        for metrics in [iosMetrics, macMetrics] {
            // The default rig: inside, at the rightmost samples, as before.
            let (_, plain) = gizmoRig()
            let p = try XCTUnwrap(gizmoLayout(plain, metrics: metrics)?.selected)
            XCTAssertEqual(p.outerHandle?.ringPoint, p.outerRing?.rightmost, "unchanged when inside")
            XCTAssertEqual(p.innerHandle?.ringPoint, p.innerRing?.rightmost, "unchanged when inside")

            // The narrowest beam whose outer ring runs off the view's right
            // edge (the case #693 is about).
            let view = CGRect(origin: .zero, size: gizmoViewSize)
                .insetBy(dx: metrics.handleReach, dy: metrics.handleReach)
            var wide: LightGizmoLayout?
            for beam in stride(from: 60.0, through: 160, by: 10) {
                let (_, controller) = gizmoRig { $0.lights[0].beam = beam }
                if let l = gizmoLayout(controller, metrics: metrics),
                   let x = l.selected?.outerRing?.rightmost?.x, x > gizmoViewSize.width {
                    wide = l
                    break
                }
            }
            let l = try XCTUnwrap(wide, "no beam runs the ring off the view")
            let s = try XCTUnwrap(l.selected)
            let outerRing = try XCTUnwrap(s.outerRing), innerRing = try XCTUnwrap(s.innerRing)
            let outer = try XCTUnwrap(s.outerHandle), inner = try XCTUnwrap(s.innerHandle)
            XCTAssertTrue(view.contains(outer.point), "outer \(outer.point)")
            XCTAssertTrue(view.contains(inner.point), "inner \(inner.point)")
            // Both on the same sample index, the outer handle on its ring.
            let k = try XCTUnwrap(outerRing.samples.firstIndex { $0 == outer.ringPoint })
            XCTAssertEqual(inner.ringPoint, innerRing.samples[k] ?? s.aimDot)
            XCTAssertFalse(outer.isOffRing)
            // No sample farther right would do.
            for sample in outerRing.samples.compactMap({ $0 }) where sample.x > outer.ringPoint.x {
                let j = try XCTUnwrap(outerRing.samples.firstIndex { $0 == sample })
                let candidate = sample.x > view.maxX || sample.y < view.minY || sample.y > view.maxY
                    || (innerRing.samples[j].map { !view.contains($0) } ?? false)
                XCTAssertTrue(candidate, "sample \(j) at \(sample) was inside")
            }
            // Still hit where they are drawn.
            XCTAssertEqual(LightGizmoHitTest.target(at: outer.point, layout: l), .outerHandle)
            XCTAssertEqual(LightGizmoHitTest.target(at: inner.point, layout: l), .innerHandle)
        }
    }

    // MARK: the overlay

    func testOverlayFramesAndChipUseTheReach() throws {
        let (_, controller) = gizmoRig()
        let state = try XCTUnwrap(LightGizmoState(controller))
        for metrics in [iosMetrics, macMetrics] {
            let l = try XCTUnwrap(gizmoLayout(controller, metrics: metrics))
            for e in LightGizmoOverlay.knobElements(l, state: state) {
                let knob = try XCTUnwrap(l.knob(named: e.knob.name))
                XCTAssertEqual(e.frame.width, 2 * metrics.reach(knob.radius), accuracy: 1e-9)
                XCTAssertEqual(e.frame.midX, knob.centre.x, accuracy: 1e-9)
            }
            let unselected = try XCTUnwrap(LightGizmoOverlay.knobElements(l, state: state)
                .first { $0.knob.name == "fill" })
            XCTAssertEqual(unselected.frame.width, metrics.minimumTarget > 0 ? 44 : 26, accuracy: 1e-9)
            let place = try XCTUnwrap(LightGizmoOverlay.chipPlacement(l))
            let key = try XCTUnwrap(l.knob(named: "key"))
            XCTAssertGreaterThanOrEqual(dist(place.point, key.centre),
                                        metrics.reach(key.radius) + LightGizmoOverlay.chipGap - 1e-9)
        }
    }
}

// MARK: - Touch routing (#623 Part 2)

/// The fake scene's pick (as LightGizmoTests' FakePicker): the plane at world
/// z = 0 under gizmoRig's camera, facing it by 0.8.
private final class PlanePicker {
    var prepares = 0
    var picks = 0

    var seam: LightGizmoPicker {
        LightGizmoPicker(prepare: { self.prepares += 1 }, pick: { ndc, aspect in
            self.picks += 1
            let slope = tan(tan(10 * Double.pi / 180))
            let depth = 200.0
            let eye = SIMD3<Double>(depth * Double(ndc.x) * slope * Double(aspect),
                                    depth * Double(ndc.y) * slope, -depth)
            let world = eye + SIMD3<Double>(0, 0, 200)
            return SurfacePick(raw: [Float(world.x), Float(world.y), Float(world.z), 0, 0, 1,
                                     Float(depth), 0.8], flags: 1)
        })
    }
}

@MainActor
final class LightsTouchRoutingTests: XCTestCase {

    private let all = LightTwoFingerKind.allCases

    /// Every order the three recognizers of the family can begin in.
    private var orders: [[LightTwoFingerKind]] {
        func permutations(_ items: [LightTwoFingerKind]) -> [[LightTwoFingerKind]] {
            guard items.count > 1 else { return [items] }
            return items.indices.flatMap { i -> [[LightTwoFingerKind]] in
                var rest = items
                let first = rest.remove(at: i)
                return permutations(rest).map { [first] + $0 }
            }
        }
        return permutations(all)
    }

    // MARK: geometry

    func testThePressPointAndTheSpan() {
        XCTAssertEqual(LightTouchGeometry.pressPoint(location: CGPoint(x: 100, y: 80),
                                                     translation: CGPoint(x: 12, y: -5)),
                       CGPoint(x: 88, y: 85), "where the finger came down (#702)")
        XCTAssertEqual(LightTouchGeometry.pressPoint(location: CGPoint(x: 3, y: 4), translation: .zero),
                       CGPoint(x: 3, y: 4))
        XCTAssertEqual(LightTouchGeometry.span([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40)]), 50)
        XCTAssertEqual(LightTouchGeometry.span([CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 40), CGPoint(x: 900, y: 0)]),
                       50, "the first two touches")
        XCTAssertEqual(LightTouchGeometry.span([CGPoint(x: 1, y: 1)]), .infinity)
        XCTAssertEqual(LightTouchGeometry.span([]), .infinity)
        XCTAssertEqual(LightTouchMetrics.knobPinchMaxSpan, 120, "#623 Q9")
    }

    // MARK: the two-finger sequence

    /// A knob named "key" within 10 pt of (100, 100).
    private func knobAt(_ p: CGPoint) -> String? {
        dist(p, CGPoint(x: 100, y: 100)) <= 10 ? "key" : nil
    }

    func testTheFirstToBeginDecidesInAnyOrder() {
        let onKnob = CGPoint(x: 104, y: 98), offKnob = CGPoint(x: 160, y: 100)
        for order in orders {
            // The first begins on the knob: the whole sequence is the gizmo's,
            // even for the kinds that begin after the centroid moved off it.
            var sequence = LightTwoFingerSequence()
            XCTAssertEqual(sequence.began(order[0], centroid: onKnob, span: 60, knob: knobAt), .gizmo("key"),
                           "\(order)")
            for kind in order.dropFirst() {
                XCTAssertEqual(sequence.began(kind, centroid: offKnob, span: 60, knob: knobAt), .gizmo("key"),
                               "\(order) \(kind)")
            }
            for kind in all { XCTAssertEqual(sequence.owner(of: kind), .gizmo("key"), "\(order) \(kind)") }
            // The first begins off the knob: the camera's, even when a later
            // kind begins on it.
            var camera = LightTwoFingerSequence()
            XCTAssertEqual(camera.began(order[0], centroid: offKnob, span: 60, knob: knobAt), .camera)
            for kind in order.dropFirst() {
                XCTAssertEqual(camera.began(kind, centroid: onKnob, span: 60, knob: knobAt), .camera,
                               "\(order) \(kind)")
            }
        }
    }

    func testASpanOver120IsTheCameras() {
        let onKnob = CGPoint(x: 100, y: 100)
        for kind in all {
            var s = LightTwoFingerSequence()
            XCTAssertEqual(s.began(kind, centroid: onKnob, span: 120, knob: knobAt), .gizmo("key"), "at most 120")
            s = LightTwoFingerSequence()
            XCTAssertEqual(s.began(kind, centroid: onKnob, span: 120.1, knob: knobAt), .camera, "a wide pinch zooms")
            s = LightTwoFingerSequence()
            XCTAssertEqual(s.began(kind, centroid: onKnob, span: .infinity, knob: knobAt), .camera, "one touch")
        }
    }

    func testTheOwnerIsKeptPerKindUntilAllEnd() {
        var s = LightTwoFingerSequence()
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.began(.pinch, centroid: CGPoint(x: 100, y: 100), span: 50, knob: knobAt), .gizmo("key"))
        XCTAssertNil(s.owner(of: .pan), "the pan has not begun: its .changed is not the gizmo's")
        XCTAssertEqual(s.began(.pan, centroid: CGPoint(x: 400, y: 400), span: 50, knob: knobAt), .gizmo("key"))
        XCTAssertEqual(s.owner(of: .pinch), .gizmo("key"), ".changed")
        XCTAssertEqual(s.ended(.pinch), .gizmo("key"), ".ended keeps the owner")
        XCTAssertNil(s.owner(of: .pinch))
        XCTAssertTrue(s.isActive, "the pan is still down")
        XCTAssertEqual(s.owner(of: .pan), .gizmo("key"))
        XCTAssertEqual(s.began(.rotation, centroid: CGPoint(x: 400, y: 400), span: 200, knob: knobAt),
                       .gizmo("key"), "a late twist joins the sequence")
        XCTAssertEqual(s.ended(.rotation), .gizmo("key"))
        XCTAssertEqual(s.ended(.pan), .gizmo("key"), "no button-up for a pan that sent no button-down")
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.owner)
        XCTAssertNil(s.ended(.pan), "an end without a begin")
        // Reset: the next sequence decides afresh.
        XCTAssertEqual(s.began(.rotation, centroid: CGPoint(x: 300, y: 100), span: 50, knob: knobAt), .camera)
        XCTAssertEqual(s.ended(.rotation), .camera)
        XCTAssertFalse(s.isActive)
        // A kind that begins again before it ended (a lost end) is a new
        // sequence.
        XCTAssertEqual(s.began(.pinch, centroid: CGPoint(x: 300, y: 100), span: 50, knob: knobAt), .camera)
        XCTAssertEqual(s.began(.pinch, centroid: CGPoint(x: 100, y: 100), span: 50, knob: knobAt), .gizmo("key"))
        XCTAssertEqual(s.active, [.pinch])
    }

    func testTheCameraWhenTheGizmoIsHidden() {
        // Outside Lights mode (or grid mode, an export) there is no layout,
        // so no knob is ever found.
        for kind in all {
            var s = LightTwoFingerSequence()
            XCTAssertEqual(s.began(kind, centroid: CGPoint(x: 100, y: 100), span: 30, knob: { _ in nil }), .camera)
        }
    }

    /// The real hit test: the sequence names the fill knob, then the pinch
    /// opens fill's radius session by name after the centroid moved off it;
    /// each change writes the radius only, owner-guarded, no command.
    func testAKnobPinchWritesOnlyTheRadius() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(gizmoLayout(controller, metrics: iosMetrics))
        let fill = try XCTUnwrap(l.knob(named: "fill"))
        let knob: (CGPoint) -> String? = { LightGizmoHitTest.knob(at: $0, layout: l) }
        var s = LightTwoFingerSequence()
        // 21.9 pt off the fill knob: inside its 44 pt target.
        XCTAssertEqual(s.began(.pan, centroid: offset(fill.centre, 21.9, 0), span: 70, knob: knob), .gizmo("fill"))
        let moved = offset(fill.centre, 0, 60)
        XCTAssertNil(knob(moved), "the centroid moved off every knob")
        XCTAssertEqual(s.began(.pinch, centroid: moved, span: 70, knob: knob), .gizmo("fill"))
        XCTAssertEqual(s.began(.rotation, centroid: moved, span: 70, knob: knob), .gizmo("fill"))
        guard case .gizmo(let name)? = s.owner(of: .pinch) else { return XCTFail() }
        let interaction = LightGizmoInteraction(controller: controller)
        var session = try XCTUnwrap(interaction.beginPinch(named: name))
        XCTAssertEqual(controller.selection.name, "fill", "selected first")
        XCTAssertEqual(interaction.pinch(&session, magnification: 1.2), .ok)
        XCTAssertEqual(store.lights[1].radius, 2.5, "0.5× grid")
        XCTAssertEqual(interaction.pinch(&session, magnification: 1.5), .ok)
        XCTAssertEqual(store.lights[1].radius, 3)
        XCTAssertNil(interaction.pinch(&session, magnification: 1.52), "the same step")
        XCTAssertEqual(store.numberWrites.map(\.field), ["radius", "radius"])
        XCTAssertEqual(store.lights[1].beam, 45, "the beam is kept")
        XCTAssertEqual(store.lights[0].radius, 3)
        XCTAssertEqual(store.lights[1].orbit, 60, "the pan and the twist wrote nothing")
        XCTAssertEqual(store.lights[1].pitch, 10)
        XCTAssertTrue(store.performed.isEmpty, "no command per tick")
        // Owner-guarded: once another light is selected, nothing is written.
        controller.select(name: "key")
        XCTAssertNotEqual(interaction.pinch(&session, magnification: 2.5), .ok)
        XCTAssertEqual(store.numberWrites.count, 2)
        XCTAssertEqual(store.lights[0].radius, 3)
        XCTAssertEqual(store.lights[1].radius, 3)
        for kind in all { s.ended(kind) }
        XCTAssertFalse(s.isActive)
        XCTAssertNil(interaction.beginPinch(named: "nobody"), "a light that is gone")
    }

    // MARK: long-press and option-tap

    func testLongPressIsDeclinedOnlyOnPointTargets() throws {
        let l = try handLayout(iosMetrics)
        let s = try XCTUnwrap(l.selected)
        let points: [(String, CGPoint)] = [
            ("knob a", l.knobs[0].centre), ("knob a at 21.9", offset(l.knobs[0].centre, 0, 21.9)),
            ("knob b", l.knobs[1].centre), ("knob c (behind)", l.knobs[2].centre),
            ("aim dot", s.aimDot!), ("outer handle", s.outerHandle!.point),
            ("inner handle", s.innerHandle!.point),
        ]
        for (what, p) in points {
            XCTAssertFalse(LightTouchRouter.shouldBeginLongPress(at: p, layout: l), what)
            XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: l, hasSelection: true), .ignore, what)
        }
        // A ring line (the outer ring left of the aim dot, the inner one
        // below it) and empty space: the press is a highlight.
        let aim = s.aimDot!
        for (what, p, target) in [("outer ring", offset(aim, -100, 0), LightGizmoTarget.outerRing),
                                  ("inner ring", offset(aim, 0, 50), .innerRing),
                                  ("outer ring at 21.9", offset(aim, -121.9, 0), .outerRing)] {
            XCTAssertEqual(LightGizmoHitTest.target(at: p, layout: l), target, what)
            XCTAssertTrue(LightTouchRouter.shouldBeginLongPress(at: p, layout: l), what)
            XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: l, hasSelection: true), .highlight, what)
        }
        for p in [CGPoint(x: 5, y: 5), offset(l.knobs[0].centre, 22.1, 0), offset(aim, -75, 0)] {
            XCTAssertTrue(LightTouchRouter.shouldBeginLongPress(at: p, layout: l), "\(p)")
            XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: l, hasSelection: true), .highlight, "\(p)")
            XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: l, hasSelection: false), .ignore,
                           "no light to highlight")
        }
        // The gizmo hidden: the atom context menu, and nothing is declined.
        for p in [l.knobs[0].centre, CGPoint(x: 5, y: 5)] {
            XCTAssertTrue(LightTouchRouter.shouldBeginLongPress(at: p, layout: nil))
            XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: nil, hasSelection: true), .contextMenu)
        }
        for target in [LightGizmoTarget.knob("a"), .aimDot, .outerHandle, .innerHandle] {
            XCTAssertTrue(LightTouchRouter.isPointTarget(target), "\(target)")
        }
        for target in [LightGizmoTarget.outerRing, .innerRing, .rings] {
            XCTAssertFalse(LightTouchRouter.isPointTarget(target), "\(target)")
        }
    }

    func testOptionTapPlacesAHighlightOffEveryTarget() throws {
        let l = try handLayout(iosMetrics)
        let s = try XCTUnwrap(l.selected)
        XCTAssertTrue(LightTouchRouter.optionTap(at: CGPoint(x: 5, y: 5), layout: l))
        XCTAssertTrue(LightTouchRouter.optionTap(at: offset(s.aimDot!, -75, 0), layout: l), "inside the rings")
        for p in [l.knobs[0].centre, s.aimDot!, s.outerHandle!.point, offset(s.aimDot!, -100, 0)] {
            XCTAssertFalse(LightTouchRouter.optionTap(at: p, layout: l), "on a target it is a tap: \(p)")
        }
        XCTAssertFalse(LightTouchRouter.optionTap(at: CGPoint(x: 5, y: 5), layout: nil), "gizmo hidden: a pick")
    }

    /// The press routes to #622's placeHighlight: one `lights` command, no
    /// write; a declined press runs nothing.
    func testALongPressPlacesOneHighlight() throws {
        let (store, controller) = gizmoRig()
        let l = try XCTUnwrap(gizmoLayout(controller, metrics: iosMetrics))
        let picker = PlanePicker()
        let interaction = LightGizmoInteraction(controller: controller, picker: picker.seam)
        let p = CGPoint(x: 500, y: 200)
        XCTAssertNil(LightGizmoHitTest.target(at: p, layout: l))
        XCTAssertEqual(LightTouchRouter.longPress(at: p, layout: l, hasSelection: controller.selectedLight != nil),
                       .highlight)
        XCTAssertEqual(interaction.placeHighlight(at: p, layout: l), .placed(rim: nil))
        XCTAssertEqual(store.performed.count, 1, "one command for the press")
        XCTAssertTrue(store.numberWrites.isEmpty)
        let knob = l.knobs[1].centre
        XCTAssertFalse(LightTouchRouter.shouldBeginLongPress(at: knob, layout: l))
        XCTAssertEqual(picker.picks, 1)
    }
}
