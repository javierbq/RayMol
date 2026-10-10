import Combine
import CoreGraphics
import XCTest
@testable import RayMol

/// The orbit mini viewer's model (#621): the shared gesture API, snapping,
/// the plan and arc geometry, the hit tests, the drag and pinch sessions,
/// what the card shows and the interaction, all on fake seams (no engine).
/// The live-engine tests are in LightsOrbitLiveTests.

/// A fake store with the three lights of sketch 2 (key -45° / +35° / 3.0×,
/// fill, rim) and a controller in Lights mode on it.
@MainActor
private func sketchRig() -> (FakeRigStore, LightsController) {
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

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

// MARK: - The shared gesture API

@MainActor
final class LightsGestureAPITests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        let (s, c) = sketchRig()
        store = s
        controller = c
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    func testBeginGestureReturnsTheOwnerAndBumpsOnce() {
        let before = controller.gestureGeneration
        XCTAssertEqual(controller.beginGesture(), "key")
        XCTAssertEqual(controller.gestureGeneration, before + 1)
        controller.select(name: "fill")
        XCTAssertEqual(controller.beginGesture(), "fill")
        XCTAssertEqual(controller.gestureGeneration, before + 2)
        XCTAssertTrue(store.numberWrites.isEmpty, "beginning a gesture writes nothing")

        // The owner is lowercased.
        store.setRig(["Key", "Fill"])
        controller.refresh()
        XCTAssertEqual(controller.selection.name, "Fill")
        XCTAssertEqual(controller.beginGesture(), "fill")
    }

    func testBeginGestureRefusesWhenItCannotEdit() {
        let before = controller.gestureGeneration
        store.busy = true
        XCTAssertNil(controller.beginGesture())
        store.busy = false
        controller.end()
        XCTAssertNil(controller.beginGesture())
        controller.begin()
        store.setRig([])
        controller.refresh()
        XCTAssertNil(controller.selection.name)
        XCTAssertNil(controller.beginGesture())
        XCTAssertEqual(controller.gestureGeneration, before, "no bump without an editable light")
    }

    func testOwnerSetWritesWhileTheOwnerIsSelected() {
        XCTAssertEqual(controller.set(.orbit, 30, owner: "KEY"), .ok, "case is ignored")
        XCTAssertEqual(store.lights[0].orbit, 30)
        XCTAssertEqual(controller.value(.orbit), 30, "the mirror shows it in the same turn")
        XCTAssertEqual(store.numberWrites.map { $0.index }, [0])
    }

    func testOwnerSetRefusesAnotherLight() {
        XCTAssertEqual(controller.set(.orbit, 30, owner: "fill"), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(store.lights[1].orbit, 60)
    }

    func testOwnerSetRereadsAStaleMirrorBeforeTheNameCheck() {
        // key removed from the console; the mirror is a second old and was
        // not re-read: fill now sits at the selected index 0.
        store.removeLight("key")
        store.clock += 1
        XCTAssertEqual(controller.set(.orbit, 30, owner: "key"), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(controller.selection.name, "fill", "the re-read repaired the selection")
        XCTAssertEqual(store.lights[0].orbit, 60, "fill untouched")
    }

    func testOwnerSetRefusesWhenItCannotEdit() {
        store.busy = true
        XCTAssertEqual(controller.set(.orbit, 30, owner: "key"), .badIndex)
        store.busy = false
        controller.end()
        XCTAssertEqual(controller.set(.orbit, 30, owner: "key"), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testFreshValueReadsWhatStepAddsTo() {
        // A camera light: the stored value, re-read when stale.
        XCTAssertEqual(controller.freshValue(.beam), 45)
        store.lights[0].beam = 60
        store.clock += 1
        XCTAssertEqual(controller.freshValue(.beam), 60)
        XCTAssertEqual(store.eyeReads, 0, "no pinned light: no eye read")

        // A pinned light: its eye placement, read now (no frame rendered).
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["key"] = LightPlacement(orbit: 40, pitch: 12, radius: 5)
        let reads = store.eyeReads
        XCTAssertEqual(controller.freshValue(.orbit), 40)
        XCTAssertEqual(store.eyeReads, reads + 1)
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        XCTAssertEqual(controller.value(.orbit), 45)

        controller.end()
        XCTAssertNil(controller.freshValue(.orbit))
    }
}

// MARK: - Snapping

final class LightSnapTests: XCTestCase {
    func testOrbitSnapsTo15Degrees() {
        let cases: [(Double, Double)] = [(7, 0), (8, 15), (-52, -45), (172, 165), (173, 180),
                                         (-173, 180), (-180, 180), (180, 180), (0, 0), (-7, 0),
                                         (104.99999, 105), (365, 0)]
        for (input, expected) in cases {
            XCTAssertEqual(LightSnap.orbit(input), expected, "\(input)")
        }
        for x in stride(from: -400.0, through: 400, by: 0.7) {
            let s = LightSnap.orbit(x)!
            XCTAssertEqual(s.truncatingRemainder(dividingBy: 15), 0, "\(x)")
            XCTAssertTrue(s > -180 && s <= 180, "\(x) -> \(s)")
            XCTAssertFalse(s.sign == .minus && s == 0, "never -0")
        }
    }

    func testRadiusSnapsToHalfSizesInRange() {
        let cases: [(Double, Double)] = [(0.2, 0.5), (2.74, 2.5), (2.75, 3), (9, 8), (0.5, 0.5),
                                         (8, 8), (-3, 0.5), (4.24, 4)]
        for (input, expected) in cases {
            XCTAssertEqual(LightSnap.radius(input), expected, "\(input)")
        }
    }

    func testPitchRoundsToTheQuantumAndClamps() {
        XCTAssertEqual(LightSnap.pitch(34.6), 35)
        XCTAssertEqual(LightSnap.pitch(-12.4), -12)
        XCTAssertEqual(LightSnap.pitch(95), 90)
        XCTAssertEqual(LightSnap.pitch(-120), -90)
        let zero = LightSnap.pitch(-0.3)!
        XCTAssertEqual(zero, 0)
        XCTAssertEqual(zero.sign, .plus, "never -0")
    }

    func testNonFiniteGivesNil() {
        for x in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(LightSnap.orbit(x))
            XCTAssertNil(LightSnap.radius(x))
            XCTAssertNil(LightSnap.pitch(x))
            XCTAssertNil(LightSnap.nextOrbit(from: x, up: true))
            XCTAssertNil(LightSnap.nextRadius(from: x, up: false))
            XCTAssertNil(LightSnap.pinch(start: 3, magnification: x))
        }
        XCTAssertNil(LightSnap.pinch(start: 3, magnification: 0))
        XCTAssertNil(LightSnap.pinch(start: 3, magnification: -1))
    }

    func testPinch() {
        XCTAssertEqual(LightSnap.pinch(start: 3, magnification: 1.5), 4.5)
        XCTAssertEqual(LightSnap.pinch(start: 3, magnification: 0.1), 0.5)
        XCTAssertEqual(LightSnap.pinch(start: 3, magnification: 10), 8)
        XCTAssertEqual(LightSnap.pinch(start: 3, magnification: 1.05), 3)
    }

    func testNextOrbit() {
        XCTAssertEqual(LightSnap.nextOrbit(from: -47, up: true), -45)
        XCTAssertEqual(LightSnap.nextOrbit(from: -47, up: false), -60)
        XCTAssertEqual(LightSnap.nextOrbit(from: -45, up: true), -30)
        XCTAssertEqual(LightSnap.nextOrbit(from: -45, up: false), -60)
        XCTAssertEqual(LightSnap.nextOrbit(from: 180, up: true), -165)
        XCTAssertEqual(LightSnap.nextOrbit(from: -165, up: false), 180)
        // Float noise on a pinned light counts as on the grid.
        XCTAssertEqual(LightSnap.nextOrbit(from: 104.9996, up: true), 120)
        XCTAssertEqual(LightSnap.nextOrbit(from: 105.0004, up: false), 90)
        XCTAssertEqual(LightSnap.nextOrbit(from: Double(Float(104.99999)), up: true), 120)
    }

    func testNextRadius() {
        XCTAssertEqual(LightSnap.nextRadius(from: 2.49995, up: true), 3)
        XCTAssertEqual(LightSnap.nextRadius(from: 2.2, up: true), 2.5)
        XCTAssertEqual(LightSnap.nextRadius(from: 2.2, up: false), 2)
        XCTAssertEqual(LightSnap.nextRadius(from: 8, up: true), 8)
        XCTAssertEqual(LightSnap.nextRadius(from: 0.5, up: false), 0.5)
        XCTAssertEqual(LightSnap.nextRadius(from: 12, up: false), 8, "a far pinned light steps into range")
    }

    func testSame() {
        XCTAssertTrue(LightSnap.same(179.9995, -180, wraps: true))
        XCTAssertFalse(LightSnap.same(179.9995, -180, wraps: false))
        XCTAssertTrue(LightSnap.same(105, Double(Float(105.00001)), wraps: true))
        XCTAssertTrue(LightSnap.same(3, 3.0009, wraps: false))
        XCTAssertFalse(LightSnap.same(3, 3.0011, wraps: false))
        XCTAssertEqual(LightSnap.tolerance, LightsController.eyeDriftTolerance)
    }
}

// MARK: - The plan

@MainActor
final class OrbitPlanLayoutTests: XCTestCase {
    private let mac = OrbitPlanLayout(extent: 4, slop: 6)

    private func assertPoint(_ p: CGPoint, _ x: CGFloat, _ y: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-9, file: file, line: line)
    }

    func testExtent() {
        XCTAssertEqual(OrbitPlanLayout.extent(for: []), 4)
        XCTAssertEqual(OrbitPlanLayout.extent(for: [4.0005]), 4)
        XCTAssertEqual(OrbitPlanLayout.extent(for: [0.5, 4]), 4)
        XCTAssertEqual(OrbitPlanLayout.extent(for: [4.5]), 8)
        XCTAssertEqual(OrbitPlanLayout.extent(for: [1, 2, 6]), 8)
        XCTAssertEqual(OrbitPlanLayout.extent(for: [12]), 8)
        XCTAssertEqual(OrbitPlanLayout(extent: 4).rings, [1, 2, 3, 4])
        XCTAssertEqual(OrbitPlanLayout(extent: 8).rings, [2, 4, 6, 8])
    }

    func testTheCardsPlanIsBigEnough() {
        let layout = OrbitPlanLayout(extent: 4)
        XCTAssertEqual(layout.size, LightsOrbitMetrics.planSize)
        XCTAssertGreaterThanOrEqual(layout.outerRadius, 88)
        XCTAssertEqual(layout.ringRadius(4), layout.outerRadius, accuracy: 1e-9)
        XCTAssertEqual(OrbitPlanLayout(extent: 8).ringRadius(8), layout.outerRadius, accuracy: 1e-9)
        // The card: padding, the plan, the gap, the arc, padding.
        XCTAssertEqual(12 + LightsOrbitMetrics.planSize.width + 8 + LightsOrbitMetrics.arcSize.width + 12,
                       LightsInspector.width)
    }

    func testCameraAtTheBottomPlus90Right() {
        let c = mac.centre
        let r = mac.ringRadius(2)
        assertPoint(mac.lampPoint(orbit: 0, radius: 2), c.x, c.y + r)
        assertPoint(mac.lampPoint(orbit: 90, radius: 2), c.x + r, c.y)
        assertPoint(mac.lampPoint(orbit: 180, radius: 2), c.x, c.y - r)
        assertPoint(mac.lampPoint(orbit: -90, radius: 2), c.x - r, c.y)
    }

    func testInverseMapsRoundTrip() {
        for extent in [4.0, 8.0] {
            let layout = OrbitPlanLayout(extent: extent, slop: 6)
            for orbit in stride(from: -165.0, through: 180, by: 15) {
                for radius in stride(from: 0.5, through: extent, by: 0.5) {
                    let p = layout.lampPoint(orbit: orbit, radius: radius)
                    XCTAssertEqual(LightAngles.wrap(layout.orbit(at: p)! - orbit), 0, accuracy: 1e-9,
                                   "\(orbit) \(radius) @\(extent)")
                    XCTAssertEqual(layout.radius(at: p), radius, accuracy: 1e-9)
                }
            }
        }
        // The centre has no angle.
        XCTAssertNil(mac.orbit(at: mac.centre))
        XCTAssertNil(mac.orbit(at: CGPoint(x: mac.centre.x + 1.5, y: mac.centre.y)))
        XCTAssertNotNil(mac.orbit(at: CGPoint(x: mac.centre.x + 2.5, y: mac.centre.y)))
    }

    func testLampsPastTheExtentAreDrawnOnTheOuterRing() {
        let wide = OrbitPlanLayout(extent: 8, slop: 6)
        // A pinned light at 12 sizes (after `lights recenter`).
        XCTAssertTrue(wide.isClamped(radius: 12))
        XCTAssertTrue(wide.isOutOfRange(radius: 12))
        XCTAssertEqual(distance(wide.lampPoint(orbit: 30, radius: 12), wide.centre), wide.outerRadius,
                       accuracy: 1e-9)
        // A light at 6 under a gesture's frozen extent of 4.
        XCTAssertTrue(mac.isClamped(radius: 6))
        XCTAssertTrue(mac.isOutOfRange(radius: 6))
        XCTAssertEqual(distance(mac.lampPoint(orbit: -100, radius: 6), mac.centre), mac.outerRadius,
                       accuracy: 1e-9)
        // A pinned light nearer than 0.5: drawn where it is.
        XCTAssertFalse(mac.isClamped(radius: 0.2))
        XCTAssertTrue(mac.isOutOfRange(radius: 0.2))
        XCTAssertEqual(distance(mac.lampPoint(orbit: 0, radius: 0.2), mac.centre), mac.ringRadius(0.2),
                       accuracy: 1e-9)
        // In range.
        for radius in [0.5, 2, 4, 4.0005] {
            XCTAssertFalse(mac.isOutOfRange(radius: radius), "\(radius)")
        }
    }

    func testSquareSitsAt45DegreesUnlessItsRingIsSmall() {
        for radius in [2.0, 2.5, 3, 4] {
            let angle = mac.squareAngle(radius: radius)
            XCTAssertEqual(angle, 45, "\(radius)")
            let p = mac.squarePoint(orbit: -45, radius: radius, angle: angle)
            XCTAssertEqual(LightAngles.wrap(mac.orbit(at: p)! - (-90)), 0, accuracy: 1e-9)
            XCTAssertEqual(mac.radius(at: p), radius, accuracy: 1e-9)
        }
        for slop in [CGFloat(6), 14] {
            let layout = OrbitPlanLayout(extent: 4, slop: slop)
            let needed = 2 * (LightsOrbitMetrics.selectedLampRadius + slop)
            for radius in stride(from: 0.5, through: 4, by: 0.5) {
                let angle = layout.squareAngle(radius: radius)
                XCTAssertGreaterThanOrEqual(angle, 45)
                XCTAssertLessThanOrEqual(angle, 180)
                let lamp = layout.lampPoint(orbit: 20, radius: radius)
                let square = layout.squarePoint(orbit: 20, radius: radius, angle: angle)
                if angle < 180 {
                    XCTAssertGreaterThanOrEqual(distance(lamp, square), needed - 1e-9, "\(radius) @\(slop)")
                }
                if angle > 45 && angle < 180 {
                    XCTAssertEqual(distance(lamp, square), needed, accuracy: 1e-9, "the smallest angle")
                }
            }
            XCTAssertEqual(layout.squareAngle(radius: 0.5), 180, "a 0.5x ring is too small: opposite")
        }
        // A light past the extent: its square is on the outer ring.
        let p = mac.squarePoint(orbit: 0, radius: 7, angle: mac.squareAngle(radius: 7))
        XCTAssertEqual(distance(p, mac.centre), mac.outerRadius, accuracy: 1e-9)
    }

    func testPlanDirectionIsTheEyeSpaceDirection() {
        // Spec §4.3: p = (sin o cos f, sin f, cos o cos f), x camera-right,
        // z towards the camera; the plan draws the camera at the bottom, so
        // its (x, y) offset is the normalised eye-space (x, z).
        for orbit in [-150.0, -90, -45, 0, 30, 90, 135, 180] {
            for pitch in [-60.0, 0, 35, 80] {
                let o = orbit * .pi / 180, f = pitch * .pi / 180
                let x = sin(o) * cos(f), z = cos(o) * cos(f)
                let n = (x * x + z * z).squareRoot()
                let offset = LightAngles.offset(orbit: orbit)
                XCTAssertEqual(offset.dx, x / n, accuracy: 1e-12, "\(orbit) \(pitch)")
                XCTAssertEqual(offset.dy, z / n, accuracy: 1e-12, "\(orbit) \(pitch)")
                let p = mac.lampPoint(orbit: orbit, radius: 2)
                XCTAssertEqual(Double(p.x - mac.centre.x) / Double(mac.ringRadius(2)), x / n, accuracy: 1e-9)
                XCTAssertEqual(Double(p.y - mac.centre.y) / Double(mac.ringRadius(2)), z / n, accuracy: 1e-9)
            }
        }
    }
}

// MARK: - The pitch arc

final class PitchArcLayoutTests: XCTestCase {
    private let arc = PitchArcLayout(slop: 6)

    func testOrientation() {
        let c = arc.centre
        XCTAssertEqual(arc.size, LightsOrbitMetrics.arcSize)
        XCTAssertLessThan(c.x, arc.size.width / 4, "centred near the left edge")
        let level = arc.point(pitch: 0)
        XCTAssertEqual(level.x, c.x + arc.radiusX, accuracy: 1e-9)
        XCTAssertEqual(level.y, c.y, accuracy: 1e-9)
        let up = arc.point(pitch: 90)
        XCTAssertEqual(up.x, c.x, accuracy: 1e-9)
        XCTAssertEqual(up.y, c.y - arc.radiusY, accuracy: 1e-9)
        let down = arc.point(pitch: -90)
        XCTAssertEqual(down.y, c.y + arc.radiusY, accuracy: 1e-9)
        XCTAssertEqual(PitchArcLayout.ticks, [-90, -45, 0, 45, 90])
        // The whole arc and its handle fit the canvas.
        XCTAssertLessThanOrEqual(level.x + LightsOrbitMetrics.handleRadius, arc.size.width)
        XCTAssertGreaterThanOrEqual(up.y - LightsOrbitMetrics.handleRadius, 0)
        XCTAssertLessThanOrEqual(down.y + LightsOrbitMetrics.handleRadius, arc.size.height)
    }

    /// #681: the arc fills the canvas height (a flatter ellipse), not the
    /// 58 pt width's half circle.
    func testTheArcFillsTheCanvasHeight() {
        let top = arc.point(pitch: 90), bottom = arc.point(pitch: -90)
        let extent = bottom.y - top.y
        XCTAssertGreaterThanOrEqual(extent, 0.9 * arc.size.height)
        XCTAssertLessThanOrEqual(extent, arc.size.height)
        XCTAssertGreaterThan(arc.radiusY, arc.radiusX, "flatter, not a small circle")
        for size in [CGSize(width: 58, height: 196), CGSize(width: 98, height: 194), CGSize(width: 70, height: 300)] {
            let a = PitchArcLayout(size: size, slop: 6)
            XCTAssertGreaterThanOrEqual(a.point(pitch: -90).y - a.point(pitch: 90).y,
                                        size.height - 2 * LightsOrbitMetrics.arcMargin - 1e-9, "\(size)")
            XCTAssertLessThanOrEqual(a.point(pitch: 0).x, size.width - LightsOrbitMetrics.arcMargin + 1e-9)
        }
    }

    func testEndpointsAreTheRange() {
        XCTAssertEqual(arc.pitch(at: arc.point(pitch: 90)), 90, accuracy: 1e-9)
        XCTAssertEqual(arc.pitch(at: arc.point(pitch: -90)), -90, accuracy: 1e-9)
        XCTAssertEqual(arc.pitch(at: arc.point(pitch: 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(arc.pitch(at: CGPoint(x: arc.centre.x, y: 0)), 90, accuracy: 1e-9, "canvas top")
        XCTAssertEqual(arc.pitch(at: CGPoint(x: arc.centre.x, y: arc.size.height)), -90, accuracy: 1e-9,
                       "canvas bottom")
    }

    /// A pointer anywhere on the ray through the handle maps to its pitch.
    func testPointerOnTheRayMapsToThePitch() {
        for pitch in stride(from: -85.0, through: 85, by: 10) {
            let p = arc.point(pitch: pitch), c = arc.centre
            for k in [0.4, 1.0, 1.6] {
                let q = CGPoint(x: c.x + (p.x - c.x) * k, y: c.y + (p.y - c.y) * k)
                XCTAssertEqual(arc.pitch(at: q), pitch, accuracy: 1e-9)
            }
        }
    }

    func testRoundTripAndClamp() {
        for pitch in stride(from: -90.0, through: 90, by: 5) {
            XCTAssertEqual(arc.pitch(at: arc.point(pitch: pitch)), pitch, accuracy: 1e-9)
        }
        let c = arc.centre
        XCTAssertEqual(arc.pitch(at: CGPoint(x: c.x - 6, y: c.y - 3)), 90, "left half, above: +90")
        XCTAssertEqual(arc.pitch(at: CGPoint(x: c.x - 6, y: c.y + 3)), -90, "left half, below: -90")
    }
}

// MARK: - Hit tests

@MainActor
final class OrbitHitTestTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!
    private let mac = OrbitPlanLayout(extent: 4, slop: 6)
    private let touch = OrbitPlanLayout(extent: 4, slop: 14)

    override func setUp() {
        super.setUp()
        let (s, c) = sketchRig()
        store = s
        controller = c
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private var state: LightsOrbitState { LightsOrbitState(controller)! }

    private func lampPoint(_ name: String, _ layout: OrbitPlanLayout) -> CGPoint {
        let lamp = state.lamp(named: name)!
        return layout.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
    }

    private func hit(_ p: CGPoint, _ layout: OrbitPlanLayout) -> OrbitTarget? {
        OrbitHitTest.plan(at: p, layout: layout, state: state)
    }

    func testEachLampAtItsCentreAndAtItsEdge() {
        for (index, name) in ["key", "fill", "rim"].enumerated() {
            for layout in [mac, touch] {
                let p = lampPoint(name, layout)
                XCTAssertEqual(hit(p, layout), .lamp(name: name, index: index))
                let reach = (name == "key" ? LightsOrbitMetrics.selectedLampRadius
                                           : LightsOrbitMetrics.lampRadius) + layout.slop
                // Along the ring's tangent at the lamp is clear of the others.
                let lamp = state.lamp(named: name)!
                let t = LightAngles.offset(orbit: lamp.orbit + 90)
                let inside = CGPoint(x: p.x + (reach - 0.5) * t.dx, y: p.y + (reach - 0.5) * t.dy)
                let outside = CGPoint(x: p.x + (reach + 0.5) * t.dx, y: p.y + (reach + 0.5) * t.dy)
                XCTAssertEqual(hit(inside, layout), .lamp(name: name, index: index), "\(name) @\(layout.slop)")
                XCTAssertNil(hit(outside, layout), "\(name) @\(layout.slop)")
            }
        }
    }

    func testEmptySpaceRingsLabelsAndTheDiscHitNothing() {
        let c = mac.centre
        XCTAssertNil(hit(c, mac), "the centre")
        XCTAssertNil(hit(mac.point(orbit: 100, distance: mac.ringRadius(0.6)), mac), "inside the 1x disc")
        XCTAssertNil(hit(mac.point(orbit: 100, distance: mac.ringRadius(1)), mac), "the 1x ring")
        XCTAssertNil(hit(mac.point(orbit: -150, distance: mac.ringRadius(2)), mac), "the 2x ring")
        // Ring labels just above each ring on the vertical axis, the tick
        // labels inside the outer ring band.
        for ring in mac.rings {
            XCTAssertNil(hit(CGPoint(x: c.x, y: c.y - mac.ringRadius(ring) + 6), mac), "\(ring)x label")
        }
        XCTAssertNil(hit(CGPoint(x: c.x, y: c.y + mac.outerRadius - 8), mac), "0° label")
        XCTAssertNil(hit(CGPoint(x: c.x + mac.outerRadius - 10, y: c.y), mac), "90° label")
        XCTAssertNil(hit(CGPoint(x: 2, y: 2), mac), "a corner")
    }

    func testOverlappingLampsNearestWins() {
        store.lights[1].orbit = 60
        store.lights[1].radius = 2
        store.lights[2].orbit = 70
        store.lights[2].radius = 2
        controller.refresh()
        let fill = lampPoint("fill", touch), rim = lampPoint("rim", touch)
        XCTAssertLessThan(distance(fill, rim), 10, "their hit regions overlap")
        func toward(_ a: CGPoint, _ b: CGPoint, _ d: CGFloat) -> CGPoint {
            let n = distance(a, b)
            return CGPoint(x: a.x + (b.x - a.x) * d / n, y: a.y + (b.y - a.y) * d / n)
        }
        XCTAssertEqual(hit(toward(fill, rim, 3), touch), .lamp(name: "fill", index: 1))
        XCTAssertEqual(hit(toward(rim, fill, 3), touch), .lamp(name: "rim", index: 2))
        // An exact tie between two other lamps: the one drawn last (rig order).
        store.lights[1].orbit = 120
        store.lights[1].radius = 3
        store.lights[2].orbit = 120
        store.lights[2].radius = 3
        controller.refresh()
        XCTAssertEqual(hit(lampPoint("fill", touch), touch), .lamp(name: "rim", index: 2))
    }

    func testTheSelectedLampBeatsTheSquareOnATie() {
        // key at 0.5x, orbit 90: its square is opposite (-90), the centre is
        // exactly between them and inside both at the touch slop.
        store.lights[0].orbit = 90
        store.lights[0].radius = 0.5
        controller.refresh()
        XCTAssertEqual(touch.squareAngle(radius: 0.5), 180)
        let c = touch.centre
        let lamp = lampPoint("key", touch)
        let square = touch.squarePoint(orbit: 90, radius: 0.5, angle: 180)
        XCTAssertEqual(distance(c, lamp), distance(c, square), "an exact tie")
        XCTAssertEqual(hit(c, touch), .lamp(name: "key", index: 0))
    }

    func testTheSquareBeatsAFartherLamp() {
        // fill sits 8 pt from key's square.
        let s = state.selected
        let angle = mac.squareAngle(radius: s.radius)
        let square = mac.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle)
        let squareOrbit = mac.orbit(at: square)!
        let near = mac.point(orbit: squareOrbit + 8 / Double(mac.ringRadius(3)) * 180 / .pi,
                             distance: mac.ringRadius(3))
        store.lights[1].orbit = mac.orbit(at: near)!
        store.lights[1].radius = 3
        controller.refresh()
        XCTAssertEqual(hit(square, mac), .radiusSquare)
        let between = CGPoint(x: square.x + (near.x - square.x) * 0.4, y: square.y + (near.y - square.y) * 0.4)
        XCTAssertEqual(hit(between, mac), .radiusSquare)
        XCTAssertEqual(hit(near, mac), .lamp(name: "fill", index: 1))
    }

    func testTheSquareNextToASmallRingsLamp() {
        store.lights[0].radius = 0.5
        controller.refresh()
        for layout in [mac, touch] {
            let s = state.selected
            let square = layout.squarePoint(orbit: s.orbit, radius: s.radius,
                                            angle: layout.squareAngle(radius: s.radius))
            XCTAssertEqual(hit(square, layout), .radiusSquare, "@\(layout.slop)")
            XCTAssertEqual(hit(lampPoint("key", layout), layout), .lamp(name: "key", index: 0), "@\(layout.slop)")
        }
    }

    func testClampedAndFrozenLampsAreHitWhereDrawn() {
        // rim at 6 under a frozen extent of 4: on the outer ring.
        store.lights[2].radius = 6
        controller.refresh()
        XCTAssertEqual(state.extent, 8)
        let onOuter = mac.point(orbit: 150, distance: mac.outerRadius)
        XCTAssertEqual(hit(onOuter, mac), .lamp(name: "rim", index: 2))
        XCTAssertNil(hit(mac.point(orbit: 150, distance: mac.ringRadius(3)), mac))

        // A pinned rim at 12 sizes, at the fitted extent 8.
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["rim"] = LightPlacement(orbit: 150, pitch: -15, radius: 12)
        controller.frameRendered()
        let wide = OrbitPlanLayout(extent: state.extent, slop: 6)
        XCTAssertEqual(wide.extent, 8)
        XCTAssertEqual(hit(wide.point(orbit: 150, distance: wide.outerRadius), wide),
                       .lamp(name: "rim", index: 2))
    }

    func testAPinnedLampIsHitWhereItsEyePlacementPutsIt() {
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        controller.select(name: "key")
        // The camera turned: rim now shows at orbit 30, radius 2.5.
        store.eyePlacements["rim"] = LightPlacement(orbit: 30, pitch: 0, radius: 2.5)
        controller.frameRendered()
        XCTAssertEqual(hit(mac.lampPoint(orbit: 30, radius: 2.5), mac), .lamp(name: "rim", index: 2))
        XCTAssertNil(hit(mac.lampPoint(orbit: 150, radius: 4), mac), "not where it was stored")
    }

    func testTheArc() {
        let arc = PitchArcLayout(slop: 6)
        let c = arc.centre
        XCTAssertEqual(OrbitHitTest.pitch(at: arc.point(pitch: 35), layout: arc, pitch: 35), .pitchHandle)
        let nearHandle = CGPoint(x: arc.point(pitch: 35).x + 10, y: arc.point(pitch: 35).y)
        XCTAssertEqual(OrbitHitTest.pitch(at: nearHandle, layout: arc, pitch: 35), .pitchHandle)
        XCTAssertEqual(OrbitHitTest.pitch(at: arc.point(pitch: -60), layout: arc, pitch: 35), .pitchTrack)
        let justOff = CGPoint(x: c.x + arc.radiusX + 5, y: c.y)
        XCTAssertEqual(OrbitHitTest.pitch(at: justOff, layout: arc, pitch: 35), .pitchTrack)
        XCTAssertNil(OrbitHitTest.pitch(at: CGPoint(x: c.x + arc.radiusX + 7, y: c.y), layout: arc, pitch: 35))
        XCTAssertNil(OrbitHitTest.pitch(at: c, layout: arc, pitch: 35), "the centre")
        XCTAssertNil(OrbitHitTest.pitch(at: CGPoint(x: c.x + arc.radiusX / 2, y: c.y), layout: arc, pitch: 35),
                     "inside the arc")
        XCTAssertNil(OrbitHitTest.pitch(at: CGPoint(x: c.x - 4, y: c.y - arc.radiusY + 2), layout: arc,
                                        pitch: 0), "left of the centre")
    }

    func testALargerSlopReachesFarther() {
        let fill = lampPoint("fill", mac)
        let t = LightAngles.offset(orbit: 60 + 90)
        let p = CGPoint(x: fill.x + 16 * t.dx, y: fill.y + 16 * t.dy)
        XCTAssertNil(hit(p, mac))
        XCTAssertEqual(hit(p, touch), .lamp(name: "fill", index: 1))
        // 10 pt outside the arc, away from the handle.
        let arc = PitchArcLayout(slop: 6), wideArc = PitchArcLayout(slop: 14)
        let o = LightAngles.offset(pitch: -60)
        let off = CGPoint(x: arc.point(pitch: -60).x + 10 * o.dx, y: arc.point(pitch: -60).y + 10 * o.dy)
        XCTAssertNil(OrbitHitTest.pitch(at: off, layout: arc, pitch: 80))
        XCTAssertEqual(OrbitHitTest.pitch(at: off, layout: wideArc, pitch: 80), .pitchTrack)
        #if os(macOS)
        XCTAssertEqual(LightsOrbitMetrics.defaultSlop, 6)
        #else
        XCTAssertEqual(LightsOrbitMetrics.defaultSlop, 14)
        #endif
        XCTAssertEqual(2 * (LightsOrbitMetrics.selectedLampRadius + 14), 44, "a 44 pt selected lamp on iOS")
    }
}

// MARK: - Sessions

final class OrbitDragSessionTests: XCTestCase {
    private let plan = OrbitPlanLayout(extent: 4, slop: 14)
    private let arc = PitchArcLayout(slop: 14)

    private func lampSession(orbit: Double, radius: Double, press: CGPoint? = nil,
                             pitch: Double = 0) -> OrbitDragSession {
        let at = press ?? plan.lampPoint(orbit: orbit, radius: radius)
        return OrbitDragSession(target: .lamp(name: "key", index: 0), owner: "Key", press: at,
                                placement: LightPlacement(orbit: orbit, pitch: pitch, radius: radius),
                                plan: plan, arc: nil)!
    }

    func testNeedsItsLayout() {
        let p = LightPlacement(orbit: 0, pitch: 0, radius: 2)
        XCTAssertNil(OrbitDragSession(target: .lamp(name: "key", index: 0), owner: "key", press: .zero,
                                      placement: p, plan: nil, arc: arc))
        XCTAssertNil(OrbitDragSession(target: .pitchHandle, owner: "key", press: .zero,
                                      placement: p, plan: plan, arc: nil))
        XCTAssertEqual(lampSession(orbit: 0, radius: 2).owner, "key", "lowercased")
    }

    func testNothingInsideTheDragSlop() {
        var s = lampSession(orbit: 0, radius: 2)
        let p = plan.lampPoint(orbit: 0, radius: 2)
        XCTAssertNil(s.move(to: CGPoint(x: p.x + 2.5, y: p.y), current: 0))
        XCTAssertFalse(s.hasMoved)
        XCTAssertNil(s.move(to: p, current: 0))
    }

    func testALampMoveGivesOrbitSnapped() {
        var s = lampSession(orbit: 0, radius: 2)
        let to = plan.point(orbit: 50, distance: plan.ringRadius(2))
        XCTAssertEqual(s.move(to: to, current: 0), OrbitEdit(parameter: .orbit, value: 45))
        XCTAssertEqual(s.parameter, .orbit)
        // Repeated ticks at one grid value: one edit.
        XCTAssertNil(s.move(to: plan.point(orbit: 48, distance: plan.ringRadius(2)), current: 45))
        XCTAssertNil(s.move(to: plan.point(orbit: 52, distance: plan.ringRadius(2)), current: 45))
        // Even before the mirror shows it.
        XCTAssertNil(s.move(to: plan.point(orbit: 46, distance: plan.ringRadius(2)), current: 0))
        XCTAssertEqual(s.move(to: plan.point(orbit: 61, distance: plan.ringRadius(2)), current: 45)?.value, 60)
        // Back over the start: wraps around the circle.
        var w = lampSession(orbit: 175, radius: 2)
        XCTAssertEqual(w.move(to: plan.point(orbit: -170, distance: plan.ringRadius(2)), current: 175)?.value,
                       -165)
    }

    func testTheGrabOffsetNeverJumpsTheLight() {
        // A press 12 pt off a 1x lamp's centre (inside the touch slop), then
        // a 4 pt move along the ring.
        let lamp = plan.lampPoint(orbit: 0, radius: 1)
        let press = CGPoint(x: lamp.x + 12, y: lamp.y)
        var s = lampSession(orbit: 0, radius: 1, press: press)
        let c = plan.centre
        let r = distance(press, c)
        let a = atan2(Double(press.x - c.x), Double(press.y - c.y)) + 4 / Double(r)
        let moved = CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y + r * CGFloat(cos(a)))
        let edit = s.move(to: moved, current: 0)
        XCTAssertTrue(edit == nil || abs(edit!.value) <= 15, "\(String(describing: edit))")
        // Without the offset the pointer's own angle would be two steps away.
        XCTAssertGreaterThan(LightSnap.orbit(plan.orbit(at: moved)!)!, 15)
    }

    func testAPressAtTheCentreUsesTheLampsOrbit() {
        var s = lampSession(orbit: 30, radius: 0.5, press: plan.centre)
        XCTAssertEqual(s.pointerAtPress, 30)
        XCTAssertEqual(s.move(to: plan.point(orbit: 92, distance: 20), current: 30)?.value, 90)
        XCTAssertNil(s.move(to: CGPoint(x: plan.centre.x + 1, y: plan.centre.y), current: 90),
                     "the centre has no angle")
    }

    func testTheCurrentValueIsNotWrittenAgainEvenWithFloatNoise() {
        let pinned = Double(Float(105.00001))
        var s = lampSession(orbit: pinned, radius: 2)
        XCTAssertNil(s.move(to: plan.point(orbit: 108, distance: plan.ringRadius(2)), current: pinned))
        XCTAssertNil(s.move(to: plan.point(orbit: 101, distance: plan.ringRadius(2)), current: pinned))
        XCTAssertEqual(s.move(to: plan.point(orbit: 115, distance: plan.ringRadius(2)), current: pinned)?.value,
                       120)
    }

    func testTheSquareGivesRadiusAtTheFrozenScale() {
        let place = LightPlacement(orbit: -45, pitch: 35, radius: 3)
        let angle = plan.squareAngle(radius: 3)
        let square = plan.squarePoint(orbit: -45, radius: 3, angle: angle)
        var s = OrbitDragSession(target: .radiusSquare, owner: "key", press: square, placement: place,
                                 plan: plan, arc: nil)!
        XCTAssertEqual(s.squareAngle, angle)
        XCTAssertEqual(s.plan?.extent, 4)
        XCTAssertEqual(s.parameter, .radius)
        let out = plan.point(orbit: -45 - angle, distance: plan.ringRadius(4.5))
        XCTAssertEqual(s.move(to: out, current: 3), OrbitEdit(parameter: .radius, value: 4.5),
                       "past the frozen extent of 4")
        XCTAssertEqual(s.plan?.extent, 4, "the scale stays frozen")
    }

    func testTheSquarePressedOffCentreKeepsItsRadius() {
        let place = LightPlacement(orbit: -45, pitch: 35, radius: 3)
        let angle = plan.squareAngle(radius: 3)
        let dir = LightAngles.offset(orbit: -45 - angle)
        let square = plan.squarePoint(orbit: -45, radius: 3, angle: angle)
        // 5 pt outside the square's centre, radially.
        let press = CGPoint(x: square.x + 5 * dir.dx, y: square.y + 5 * dir.dy)
        var s = OrbitDragSession(target: .radiusSquare, owner: "key", press: press, placement: place,
                                 plan: plan, arc: nil)!
        let pps = plan.pointsPerSize
        func radial(_ sizes: CGFloat) -> CGPoint {
            CGPoint(x: press.x + sizes * pps * dir.dx, y: press.y + sizes * pps * dir.dy)
        }
        XCTAssertNil(s.move(to: radial(-0.2), current: 3), "0.2x in: still 3")
        XCTAssertNil(s.move(to: radial(0.2), current: 3), "0.2x out: still 3")
        XCTAssertEqual(s.move(to: radial(-0.3), current: 3)?.value, 2.5)
    }

    func testThePitchHandleUsesTheGrabOffsetAndTheTrackIsAbsolute() {
        let place = LightPlacement(orbit: 0, pitch: 0, radius: 2)
        let handle = arc.point(pitch: 0)
        let press = CGPoint(x: handle.x, y: handle.y - 6)
        var s = OrbitDragSession(target: .pitchHandle, owner: "key", press: press, placement: place,
                                 plan: nil, arc: arc)!
        let to = CGPoint(x: handle.x, y: handle.y - 9)
        let expected = LightSnap.pitch(arc.pitch(at: to) - arc.pitch(at: press))!
        XCTAssertEqual(s.move(to: to, current: 0), OrbitEdit(parameter: .pitch, value: expected))
        XCTAssertLessThan(expected, LightSnap.pitch(arc.pitch(at: to))!, "relative, not absolute")

        var t = OrbitDragSession(target: .pitchTrack, owner: "key", press: arc.point(pitch: -60),
                                 placement: place, plan: nil, arc: arc)!
        XCTAssertEqual(t.move(to: arc.point(pitch: -50), current: 0), OrbitEdit(parameter: .pitch, value: -50))
    }

    func testEndedSessionsGiveNothing() {
        var s = lampSession(orbit: 0, radius: 2)
        s.end()
        XCTAssertTrue(s.isEnded)
        XCTAssertNil(s.move(to: plan.point(orbit: 90, distance: plan.ringRadius(2)), current: 0))
    }

    func testPinchSession() {
        var p = OrbitPinchSession(owner: "Key", radiusAtStart: 3)
        XCTAssertEqual(p.owner, "key")
        XCTAssertEqual(p.change(magnification: 1.5, current: 3), 4.5)
        XCTAssertNil(p.change(magnification: 1.5, current: 4.5))
        XCTAssertNil(p.change(magnification: 1.52, current: 4.5), "the same grid value")
        XCTAssertNil(p.change(magnification: 1.02, current: 3), "back to the current value")
        XCTAssertEqual(p.change(magnification: 0.1, current: 4.5), 0.5)
        XCTAssertNil(p.change(magnification: 0, current: 0.5))
        p.end()
        XCTAssertNil(p.change(magnification: 2, current: 0.5))
    }
}

// MARK: - The interaction

@MainActor
final class LightsOrbitInteractionTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!
    private let plan = OrbitPlanLayout(extent: 4, slop: 6)
    private let arc = PitchArcLayout(slop: 6)

    override func setUp() {
        super.setUp()
        let (s, c) = sketchRig()
        store = s
        controller = c
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private var interaction: LightsOrbitInteraction { LightsOrbitInteraction(controller: controller) }
    private var state: LightsOrbitState { LightsOrbitState(controller)! }

    private func lampPoint(_ name: String) -> CGPoint {
        let lamp = state.lamp(named: name)!
        return plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
    }

    private func squarePoint() -> CGPoint {
        let s = state.selected
        return plan.squarePoint(orbit: s.orbit, radius: s.radius, angle: plan.squareAngle(radius: s.radius))
    }

    /// Drag `session` along the ring of a lamp at `radius` from `from` to
    /// `to` degrees in `ticks` ticks; the results of the ticks that wrote.
    private func dragLamp(_ session: inout OrbitDragSession, radius: Double, from: Double, to: Double,
                          ticks: Int = 12) -> [LightSetResult] {
        var results: [LightSetResult] = []
        for k in 1...ticks {
            let o = from + (to - from) * Double(k) / Double(ticks)
            if let r = interaction.move(&session, to: plan.point(orbit: o, distance: plan.ringRadius(radius))) {
                results.append(r)
            }
        }
        return results
    }

    func testATapOnAnotherLampSelectsItAndWritesNothing() {
        let before = controller.gestureGeneration
        let session = interaction.beginPlan(at: lampPoint("fill"), state: state, layout: plan)
        XCTAssertEqual(session?.target, .lamp(name: "fill", index: 1))
        XCTAssertEqual(session?.owner, "fill")
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1))
        XCTAssertEqual(controller.gestureGeneration, before + 1)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testPressAndDragOnAnotherLampOrbitsItOnly() {
        var session = interaction.beginPlan(at: lampPoint("fill"), state: state, layout: plan)!
        let results = dragLamp(&session, radius: 2, from: 60, to: 100)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0 == .ok })
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.field == "orbit" && $0.index == 1 })
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.value.truncatingRemainder(dividingBy: 15) == 0 })
        XCTAssertEqual(store.lights[1].orbit, 105)
        XCTAssertEqual(store.lights[1].pitch, 10)
        XCTAssertEqual(store.lights[1].radius, 2)
        XCTAssertEqual(store.lights[0].orbit, -45, "key untouched")
        XCTAssertTrue(store.performed.isEmpty, "no Python")
    }

    func testTheSquareWritesRadiusOnlyAndKeepsTheBeam() {
        var session = interaction.beginPlan(at: squarePoint(), state: state, layout: plan)!
        XCTAssertEqual(session.target, .radiusSquare)
        let angle = session.squareAngle!
        for k in 1...12 {
            let d = plan.ringRadius(3 + (2.5 - 3) * Double(k) / 12)
            interaction.move(&session, to: plan.point(orbit: -45 - angle, distance: d))
        }
        XCTAssertEqual(store.numberWrites.map { $0.field }, ["radius"])
        XCTAssertEqual(store.lights[0].radius, 2.5)
        XCTAssertEqual(store.lights[0].beam, 45)
        XCTAssertEqual(store.lights[0].orbit, -45)
        XCTAssertEqual(store.lights[0].pitch, 35)
    }

    func testTheArcWritesPitchOnly() {
        var session = interaction.beginArc(at: arc.point(pitch: 35), state: state, layout: arc)!
        XCTAssertEqual(session.target, .pitchHandle)
        for k in 1...12 {
            interaction.move(&session, to: arc.point(pitch: 35 + (20 - 35) * Double(k) / 12))
        }
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.field == "pitch" && $0.index == 0 })
        XCTAssertEqual(store.lights[0].pitch, 20)
        XCTAssertEqual(store.lights[0].orbit, -45)
        XCTAssertEqual(store.lights[0].radius, 3)
        // A press on the track brings the handle to the pointer.
        var track = interaction.beginArc(at: arc.point(pitch: -60), state: state, layout: arc)!
        XCTAssertEqual(track.target, .pitchTrack)
        interaction.move(&track, to: arc.point(pitch: -66))
        XCTAssertEqual(store.lights[0].pitch, -66)
        XCTAssertNil(interaction.beginArc(at: arc.centre, state: state, layout: arc))
    }

    func testAPinchWritesRadiusOnly() {
        var pinch = interaction.beginPinch()!
        XCTAssertEqual(pinch.owner, "key")
        XCTAssertEqual(interaction.pinch(&pinch, magnification: 1.5), .ok)
        XCTAssertNil(interaction.pinch(&pinch, magnification: 1.5))
        XCTAssertEqual(store.numberWrites.map { $0.field }, ["radius"])
        XCTAssertEqual(store.lights[0].radius, 4.5)
        XCTAssertEqual(store.lights[0].beam, 45)
    }

    func testNothingStartsWhenItCannotEdit() {
        let s = state
        let fill = lampPoint("fill"), key = lampPoint("key")
        store.busy = true
        XCTAssertNil(interaction.beginPlan(at: fill, state: s, layout: plan))
        XCTAssertNil(interaction.beginArc(at: arc.point(pitch: 35), state: s, layout: arc))
        XCTAssertNil(interaction.beginPinch())
        XCTAssertEqual(controller.selection.name, "key", "a refused press selects nothing")
        store.busy = false
        controller.end()
        XCTAssertNil(interaction.beginPlan(at: key, state: s, layout: plan))
        XCTAssertNil(interaction.beginPinch())
        controller.begin()
        store.setRig([])
        controller.refresh()
        XCTAssertNil(LightsOrbitState(controller))
        XCTAssertNil(interaction.beginPinch())
        XCTAssertNil(interaction.beginPlan(at: plan.lampPoint(orbit: -45, radius: 3), state: s, layout: plan))
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertTrue(store.performed.isEmpty)
    }

    func testRemovedBehindAStaleMirrorWritesNothing() {
        var session = interaction.beginPlan(at: lampPoint("key"), state: state, layout: plan)!
        var pinch = interaction.beginPinch()!
        store.removeLight("key")
        store.clock += 1
        XCTAssertEqual(interaction.move(&session, to: plan.point(orbit: 0, distance: plan.ringRadius(3))),
                       .badIndex)
        XCTAssertTrue(session.isEnded)
        XCTAssertNil(interaction.move(&session, to: plan.point(orbit: 30, distance: plan.ringRadius(3))))
        XCTAssertEqual(controller.selection.name, "fill")
        XCTAssertEqual(interaction.pinch(&pinch, magnification: 2), .badIndex)
        XCTAssertTrue(pinch.isEnded)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(store.lights[0].orbit, 60, "fill untouched")
        XCTAssertEqual(store.lights[0].radius, 2)
    }

    func testAVoiceOverStepForARemovedLightWritesNothing() {
        store.removeLight("key")
        store.clock += 1
        XCTAssertEqual(interaction.stepOrbit(up: true, owner: "key"), .badIndex)
        XCTAssertEqual(interaction.stepRadius(up: true, owner: "key"), .badIndex)
        XCTAssertEqual(interaction.stepPitch(up: true, owner: "key"), .badIndex)
        XCTAssertTrue(store.numberWrites.isEmpty)
        XCTAssertEqual(store.lights[0].orbit, 60)
    }

    func testRemovedWithAFreshMirrorEndsTheSession() {
        var session = interaction.beginPlan(at: lampPoint("key"), state: state, layout: plan)!
        store.removeLight("key")
        controller.refresh()
        XCTAssertEqual(interaction.move(&session, to: plan.point(orbit: 0, distance: plan.ringRadius(3))),
                       .badIndex)
        XCTAssertTrue(session.isEnded)
        XCTAssertTrue(store.numberWrites.isEmpty)
    }

    func testALampThatVanishedBeforeThePressStartsNothing() {
        let rendered = state
        store.removeLight("fill")
        controller.refresh()
        let before = controller.gestureGeneration
        XCTAssertNil(interaction.beginPlan(at: plan.lampPoint(orbit: 60, radius: 2), state: rendered,
                                           layout: plan))
        XCTAssertEqual(controller.selection.name, "key")
        XCTAssertEqual(controller.gestureGeneration, before)
    }

    func testDoneMidDragWritesNothingMore() {
        var session = interaction.beginPlan(at: lampPoint("key"), state: state, layout: plan)!
        XCTAssertEqual(interaction.move(&session, to: plan.point(orbit: -20, distance: plan.ringRadius(3))), .ok)
        let writes = store.numberWrites.count
        controller.end()   // Esc = Done
        XCTAssertNil(interaction.move(&session, to: plan.point(orbit: 40, distance: plan.ringRadius(3))))
        XCTAssertTrue(session.isEnded)
        XCTAssertEqual(store.numberWrites.count, writes)
    }

    func testManyTicksWriteOnlyGridChanges() {
        var session = interaction.beginPlan(at: lampPoint("key"), state: state, layout: plan)!
        let loads = store.presetLoads
        let results = dragLamp(&session, radius: 3, from: -45, to: 135, ticks: 120)
        // -30, -15, ..., 135: twelve new grid values, each written once.
        XCTAssertEqual(results.count, 12)
        XCTAssertEqual(store.numberWrites.map { $0.value }, Array(stride(from: -30.0, through: 135, by: 15)))
        XCTAssertTrue(store.numberWrites.allSatisfy { $0.field == "orbit" })
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertEqual(store.presetLoads, loads)
        XCTAssertEqual(store.lights[0].orbit, 135)
    }

    func testAFarPinnedLampIsRepinnedInRange() {
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["rim"] = LightPlacement(orbit: 150, pitch: -15, radius: 12)
        controller.frameRendered()
        let s = state
        XCTAssertEqual(s.extent, 8)
        XCTAssertTrue(s.selected.isOutOfRange)
        let wide = OrbitPlanLayout(extent: s.extent, slop: 6)
        var session = interaction.beginPlan(at: wide.lampPoint(orbit: 150, radius: 12), state: s, layout: wide)!
        let writes = store.numberWrites.count
        for k in 1...12 {
            interaction.move(&session, to: wide.point(orbit: 150 + 30 * Double(k) / 12, distance: wide.outerRadius))
        }
        XCTAssertEqual(store.numberWrites.dropFirst(writes).map { $0.field }, ["orbit", "orbit"])
        XCTAssertEqual(store.currentPlacement(2), LightPlacement(orbit: 180, pitch: -15, radius: 8),
                       "the re-pin clamps the derived radius, as the core does")
    }

    func testVoiceOverSteps() {
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["key"] = LightPlacement(orbit: 104.99999, pitch: 35, radius: 3)
        let before = controller.gestureGeneration
        XCTAssertEqual(interaction.stepOrbit(up: true, owner: "key"), .ok)
        XCTAssertEqual(store.currentPlacement(0).orbit, 120)
        XCTAssertEqual(interaction.stepOrbit(up: false, owner: "Key"), .ok)
        XCTAssertEqual(store.currentPlacement(0).orbit, 105)
        XCTAssertEqual(interaction.stepRadius(up: true, owner: "key"), .ok)
        XCTAssertEqual(store.currentPlacement(0).radius, 3.5)
        XCTAssertEqual(interaction.stepPitch(up: false, owner: "key"), .ok)
        XCTAssertEqual(store.currentPlacement(0).pitch, 30)
        XCTAssertEqual(controller.gestureGeneration, before + 4, "each step drops typed text")
        let writes = store.numberWrites.count
        XCTAssertEqual(interaction.stepOrbit(up: true, owner: "fill"), .badIndex)
        XCTAssertEqual(store.numberWrites.count, writes)
        interaction.select(name: "rim")
        XCTAssertEqual(controller.selection.name, "rim")
    }
}

// MARK: - What the card shows

@MainActor
final class LightsOrbitStateTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!

    override func setUp() {
        super.setUp()
        let (s, c) = sketchRig()
        store = s
        controller = c
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    func testNilUnlessActiveWithASelectedLight() {
        XCTAssertNotNil(LightsOrbitState(controller))
        controller.end()
        XCTAssertNil(LightsOrbitState(controller), "after Done")
        let fresh = LightsController(seams: store.seams)
        XCTAssertNil(LightsOrbitState(fresh), "inactive")
        let empty = FakeRigStore()
        let noRig = LightsController(seams: empty.seams)
        noRig.begin()
        XCTAssertNil(LightsOrbitState(noRig), "no rig")
        empty.setRig([])
        noRig.refresh()
        XCTAssertNil(LightsOrbitState(noRig), "no lights")
    }

    func testLampsInRigOrderWithTheBarsSlots() {
        let s = LightsOrbitState(controller)!
        XCTAssertEqual(s.lamps.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(s.lamps.map(\.index), [0, 1, 2])
        XCTAssertEqual(s.lamps.map(\.slot), ["key", "fill", "rim"].map { controller.identitySlot(for: $0) })
        XCTAssertEqual(s.lamps.map(\.isSelected), [true, false, false])
        XCTAssertEqual(s.selected.name, "key")
        XCTAssertEqual(s.lamps.map(\.orbit), [-45, 60, 150])
        XCTAssertEqual(s.lamps.map(\.radius), [3, 2, 4])
        XCTAssertEqual(s.extent, 4)
        XCTAssertTrue(s.isOn)
        XCTAssertTrue(s.canEdit)
        XCTAssertEqual(s.others.map(\.name), ["fill", "rim"])

        // A pinned lamp from eye space.
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["rim"] = LightPlacement(orbit: 120, pitch: -5, radius: 3.5)
        controller.frameRendered()
        let pinned = LightsOrbitState(controller)!.lamp(named: "RIM")!
        XCTAssertTrue(pinned.isPinned)
        XCTAssertEqual(pinned.orbit, 120)
        XCTAssertEqual(pinned.pitch, -5)
        XCTAssertEqual(pinned.radius, 3.5)
    }

    func testLabels() {
        store.lights[0].pitch = 0
        store.lights[1].pitch = 30
        store.lights[2].pitch = -15
        controller.refresh()
        var s = LightsOrbitState(controller)!
        XCTAssertEqual(s.lamps.map(\.labelText), ["0°", "+30°", "−15°"])
        XCTAssertEqual(s.radiusText, "3.0× · 30 Å")
        XCTAssertEqual(s.orbitText, "−45°")
        XCTAssertEqual(s.pitchText, "0°")

        // An out-of-range pinned rim.
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        store.eyePlacements["rim"] = LightPlacement(orbit: 150, pitch: 30, radius: 12)
        controller.frameRendered()
        s = LightsOrbitState(controller)!
        XCTAssertEqual(s.extent, 8)
        XCTAssertTrue(s.selected.isOutOfRange)
        XCTAssertEqual(s.selected.labelText, "+30° · 12.0×")
        XCTAssertEqual(s.lamps.filter(\.isOutOfRange).map(\.name), ["rim"])
        XCTAssertEqual(LightsOrbitState.label(pitch: 30, radius: 0.2, outOfRange: true), "+30° · 0.2×")
    }

    func testExtentRigOffAndBusy() {
        store.lights[1].radius = 6
        controller.refresh()
        XCTAssertEqual(LightsOrbitState(controller)?.extent, 8)
        XCTAssertEqual(LightsOrbitState(controller)?.lamps.contains { $0.isOutOfRange }, false)
        controller.setEnabled(false)
        XCTAssertEqual(LightsOrbitState(controller)?.isOn, false)
        store.busy = true
        XCTAssertEqual(LightsOrbitState(controller)?.canEdit, false)
    }

    func testVoiceOverStrings() {
        let s = LightsOrbitState(controller)!
        XCTAssertEqual(s.containerLabel, "Orbit view, key")
        XCTAssertEqual(s.planLabel, "Orbit, key")
        XCTAssertEqual(s.planValue, "-45 degrees, 3.0 scene sizes, 30 angstroms")
        XCTAssertEqual(s.pitchLabel, "Pitch, key")
        XCTAssertEqual(s.pitchValue, "35 degrees")
        XCTAssertEqual(s.planActions, ["Increase radius", "Decrease radius", "Select fill", "Select rim"])
        XCTAssertEqual(LightsOrbitState.collapseLabel(collapsed: true), "Expand orbit view")
        XCTAssertEqual(LightsOrbitState.collapseLabel(collapsed: false), "Collapse orbit view")
        XCTAssertEqual([LightsOrbitState.identifier, LightsOrbitState.planIdentifier,
                        LightsOrbitState.pitchIdentifier, LightsOrbitState.collapseIdentifier],
                       ["lights.orbit", "lights.orbit.plan", "lights.orbit.pitch", "lights.orbit.collapse"])
        XCTAssertEqual([LightsOrbitState.orbitTitle, LightsOrbitState.pitchTitle], ["Orbit", "Pitch"])
    }

    func testSummaries() {
        let s = LightsOrbitState(controller)!
        XCTAssertEqual(s.summary, "key,orbit:-45.0,pitch:35.0,radius:3.00,extent:4,lamps:key|fill|rim")
        XCTAssertFalse(s.summary.contains(" "))
        XCTAssertFalse(s.summary.contains("orbit="), "orbit= stays the inspector's field")
        XCTAssertEqual(s.collapsedSummary, "−45° · +35° · 3.0×")
        store.lights[0].orbit = -0.01
        controller.refresh()
        XCTAssertTrue(LightsOrbitState(controller)!.summary.hasPrefix("key,orbit:0.0,"), "never -0.0")
    }
}

// MARK: - Mirroring with the bar and the inspector

@MainActor
final class LightsOrbitMirroringTests: XCTestCase {
    private var store: FakeRigStore!
    private var controller: LightsController!
    private let plan = OrbitPlanLayout(extent: 4, slop: 6)
    private let arc = PitchArcLayout(slop: 6)

    override func setUp() {
        super.setUp()
        let (s, c) = sketchRig()
        store = s
        controller = c
    }

    override func tearDown() {
        controller = nil
        store = nil
        super.tearDown()
    }

    private var interaction: LightsOrbitInteraction { LightsOrbitInteraction(controller: controller) }
    private var state: LightsOrbitState { LightsOrbitState(controller)! }
    private var inspector: LightsInspectorState { LightsInspectorState(controller)! }

    func testAChipSelectShowsOnThePlan() {
        controller.select(name: "rim")   // what a chip tap calls
        XCTAssertEqual(state.selected.name, "rim")
        XCTAssertEqual(state.lamps.map(\.isSelected), [false, false, true])
    }

    func testAPlanTapSelectsTheChipAndTheInspector() {
        let fill = state.lamp(named: "fill")!
        _ = interaction.beginPlan(at: plan.lampPoint(orbit: fill.orbit, radius: fill.radius),
                                  state: state, layout: plan)
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1))
        XCTAssertEqual(inspector.name, "fill")
        XCTAssertEqual(inspector.slot, state.selected.slot, "the lamp's colour is the chip's")
    }

    func testPlanEditsShowInTheInspectorInTheSameTurn() {
        var lamp = interaction.beginPlan(at: plan.lampPoint(orbit: -45, radius: 3), state: state, layout: plan)!
        interaction.move(&lamp, to: plan.point(orbit: -100, distance: plan.ringRadius(3)))
        XCTAssertEqual(inspector.row(.orbit)?.value, -105)
        XCTAssertEqual(state.selected.orbit, -105)

        var pitch = interaction.beginArc(at: arc.point(pitch: 35), state: state, layout: arc)!
        interaction.move(&pitch, to: arc.point(pitch: 20))
        XCTAssertEqual(inspector.row(.pitch)?.value, 20)

        let s = state.selected
        let angle = plan.squareAngle(radius: s.radius)
        var square = interaction.beginPlan(at: plan.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle),
                                           state: state, layout: plan)!
        interaction.move(&square, to: plan.point(orbit: s.orbit - angle, distance: plan.ringRadius(2.5)))
        XCTAssertEqual(inspector.row(.radius)?.value, 2.5)
        XCTAssertEqual(inspector.row(.radius)?.text, state.radiusText)
    }

    func testInspectorEditsShowOnThePlanInTheSameTurn() {
        XCTAssertEqual(controller.set(.orbit, 30), .ok)
        XCTAssertEqual(state.selected.orbit, 30)
        XCTAssertEqual(controller.set(.pitch, -20), .ok)
        XCTAssertEqual(state.selected.pitch, -20)
        XCTAssertEqual(controller.set(.radius, 6), .ok)
        XCTAssertEqual(state.selected.radius, 6)
        XCTAssertEqual(state.extent, 8)
    }

    func testDeleteAndPresetsUpdateTheLamps() {
        controller.removeSelected()
        XCTAssertEqual(state.lamps.map(\.name), ["fill", "rim"])
        XCTAssertEqual(state.selected.name, "fill")
        controller.applyPreset("softbox")
        XCTAssertEqual(state.lamps.map(\.name), ["left", "right", "top"])
        XCTAssertEqual(state.selected.name, "left")
    }

    func testAGestureBumpsTheGenerationOncePerPress() {
        let before = controller.gestureGeneration
        var session = interaction.beginPlan(at: plan.lampPoint(orbit: -45, radius: 3), state: state, layout: plan)!
        for k in 1...20 {
            interaction.move(&session, to: plan.point(orbit: -45 + 4 * Double(k), distance: plan.ringRadius(3)))
        }
        XCTAssertGreaterThan(store.numberWrites.count, 1)
        XCTAssertEqual(controller.gestureGeneration, before + 1)
    }

    func testAPinnedFramePublishChangesThePlanNotTheController() {
        controller.select(name: "rim")
        XCTAssertEqual(controller.setPinned(true), .ok)
        let before = state
        let changes = LightsChangeCounter()
        let sink = controller.objectWillChange.sink { _ in changes.count += 1 }
        defer { sink.cancel() }
        store.eyePlacements["rim"] = LightPlacement(orbit: 180, pitch: -15, radius: 4)
        controller.frameRendered()
        XCTAssertNotEqual(state, before)
        XCTAssertEqual(state.selected.orbit, 180)
        XCTAssertEqual(changes.count, 0, "the bar is not re-rendered per frame")
    }
}

// MARK: - DEBUG gestures

#if DEBUG
@MainActor
final class OrbitAutoGestureTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(OrbitAutoGesture.parse("tap:fill"), .tap("fill"))
        XCTAssertEqual(OrbitAutoGesture.parse("plan:key:100"), .plan("key", 100))
        XCTAssertEqual(OrbitAutoGesture.parse(" square:2.5 "), .square(2.5))
        XCTAssertEqual(OrbitAutoGesture.parse("arc:-20"), .arc(-20))
        XCTAssertEqual(OrbitAutoGesture.parse("pinch:1.5"), .pinch(1.5))
        for bad in ["plan:key", "square:x", "arc:", "pinch:0", "tap:", "pinch:-1", "arc:nan", "plan::30",
                    "tap:a:b", "orbit:30"] {
            XCTAssertNil(OrbitAutoGesture.parse(bad), bad)
        }
        XCTAssertTrue(OrbitAutoGesture.claims("plan:key"))
        XCTAssertTrue(OrbitAutoGesture.claims("Pinch:0"))
        XCTAssertFalse(OrbitAutoGesture.claims("orbit:30"))
        XCTAssertFalse(OrbitAutoGesture.claims("spin:3"))
        XCTAssertEqual(OrbitAutoGesture.plan("key", 100).token, "plan:key:100")
        XCTAssertEqual(OrbitAutoGesture.square(2.5).token, "square:2.5")
    }

    func testAppliesThroughTheInteraction() {
        let (store, controller) = sketchRig()
        let lines = ["plan:key:100", "square:2.5", "arc:20", "pinch:1.5", "tap:fill"].map {
            OrbitAutoGesture.apply(OrbitAutoGesture.parse($0)!, to: controller)
        }
        XCTAssertEqual(lines, ["plan:key:100 -> ok orbit=105", "square:2.5 -> ok radius=2.5",
                               "arc:20 -> ok pitch=20", "pinch:1.5 -> ok radius=4",
                               "tap:fill -> ok selected=fill"])
        XCTAssertEqual(store.lights[0].orbit, 105)
        XCTAssertEqual(store.lights[0].pitch, 20)
        XCTAssertEqual(store.lights[0].radius, 4)
        XCTAssertEqual(store.lights[1].orbit, 60, "the tap wrote nothing")
        XCTAssertTrue(store.performed.isEmpty)
        XCTAssertEqual(OrbitAutoGesture.apply(.tap("nobody"), to: controller), "tap:nobody -> miss")
        controller.end()
        XCTAssertEqual(OrbitAutoGesture.apply(.arc(10), to: controller), "arc:10 -> no_light")
    }

    /// #623: the gestures run on the canvases the active placement shows:
    /// the compact sheet's 164 pt plan, the expanded sheet's least pinned
    /// plan (120) beside its widest arc (98), and the side panel's.
    func testAppliesAtThePlacementSizes() {
        let sizes: [(String, CGSize, CGSize)] = [
            ("compact", CGSize(width: 164, height: 164), LightsOrbitMetrics.arcSize),
            ("pinned 120", CGSize(width: 120, height: 120), CGSize(width: 98, height: 120)),
            ("pinned 194", CGSize(width: 194, height: 194), CGSize(width: 98, height: 194)),
        ]
        for (name, plan, arc) in sizes {
            let (store, controller) = sketchRig()
            let lines = ["plan:key:100", "square:2.5", "arc:20", "pinch:1.5", "tap:fill"].map {
                OrbitAutoGesture.apply(OrbitAutoGesture.parse($0)!, to: controller, planSize: plan, arcSize: arc)
            }
            XCTAssertEqual(lines, ["plan:key:100 -> ok orbit=105", "square:2.5 -> ok radius=2.5",
                                   "arc:20 -> ok pitch=20", "pinch:1.5 -> ok radius=4",
                                   "tap:fill -> ok selected=fill"], name)
            XCTAssertEqual(store.lights[0].orbit, 105, name)
            XCTAssertTrue(store.performed.isEmpty, name)
        }
        // LightsAutoEdit passes the sizes through.
        let (store, controller) = sketchRig()
        let parsed = LightsAutoEdit.parse("arc:-20")
        XCTAssertEqual(LightsAutoEdit.apply(parsed.tokens, to: controller,
                                            orbitPlanSize: CGSize(width: 120, height: 120),
                                            orbitArcSize: CGSize(width: 98, height: 120)),
                       ["arc:-20 -> ok pitch=-20"])
        XCTAssertEqual(store.lights[0].pitch, -20)
    }
}
#endif
