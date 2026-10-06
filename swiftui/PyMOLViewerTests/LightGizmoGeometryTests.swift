import CoreGraphics
import XCTest
@testable import RayMol

// The light gizmo's camera, projection and front/behind rule (#622 part 1):
// pure values, no engine. The projection is checked against the renderer's
// formulas (the GetFovWidth slope, the orthoscopic height, the letterbox
// sub-rect of SurfacePick.sceneNDC); LightGizmoLiveTests (part 3) checks it
// against the core's own surface pick.

/// A 25-float view as PyMOLBridge_GetView writes it: identity rotation, the
/// camera `distance` Å from the origin, view[24] +fov when orthoscopic.
private func view(fov: Float = 20, distance: Float = 50, ortho: Bool = false) -> [Float] {
    var v = [Float](repeating: 0, count: 25)
    v[0] = 1; v[5] = 1; v[10] = 1; v[15] = 1
    v[18] = -distance
    v[22] = distance - 10
    v[23] = distance + 10
    v[24] = ortho ? fov : -fov
    return v
}

/// The renderer's perspective half-height slope for `fov` degrees.
private func slope(_ fov: Double) -> Double {
    tan(2 * tan(fov * .pi / 360) / 2)
}

final class LightCameraProjectionTests: XCTestCase {

    func testPerspective() throws {
        let camera = try XCTUnwrap(LightCameraProjection(view: view(), letterboxAspect: 0,
                                                         fieldOfView: nil))
        XCTAssertFalse(camera.orthoscopic)
        XCTAssertEqual(camera.fovDegrees, 20)
        XCTAssertEqual(camera.cameraDistance, 50)
        XCTAssertEqual(camera.letterboxAspect, 0)
        XCTAssertEqual(camera.fovWidth, 2 * tan(10 * Double.pi / 180), accuracy: 1e-12)
        // tan(GetFovWidth / 2), not tan(fov / 2) (metal_pick.camera).
        XCTAssertEqual(camera.slope, slope(20), accuracy: 1e-12)
        XCTAssertNotEqual(camera.slope, tan(10 * Double.pi / 180), accuracy: 1e-4)
    }

    func testOrthoscopic() throws {
        let camera = try XCTUnwrap(LightCameraProjection(view: view(fov: 30, distance: 80, ortho: true),
                                                         letterboxAspect: 1.5, fieldOfView: 20))
        XCTAssertTrue(camera.orthoscopic)
        XCTAssertEqual(camera.fovDegrees, 30, "the view's own field of view wins")
        XCTAssertEqual(camera.letterboxAspect, 1.5)
        // SceneProjectionMatrix: max(1e-4, -pos.z) GetFovWidth / 2.
        XCTAssertEqual(camera.orthoHalfHeight, 80 * tan(15 * Double.pi / 180), accuracy: 1e-9)
        var near = camera
        near.cameraDistance = -3
        XCTAssertEqual(near.orthoHalfHeight, 1e-4 * camera.fovWidth / 2, accuracy: 1e-15)
    }

    func testFieldOfViewFallback() throws {
        // |view[24]| <= 1: the polled field_of_view, as metal_pick.camera does.
        for flag: Float in [0, -1, 0.5, 1] {
            var v = view()
            v[24] = flag
            let camera = try XCTUnwrap(LightCameraProjection(view: v, letterboxAspect: 0,
                                                             fieldOfView: 35), "\(flag)")
            XCTAssertEqual(camera.fovDegrees, 35, "\(flag)")
            XCTAssertEqual(camera.orthoscopic, flag > 0, "\(flag)")
            XCTAssertNil(LightCameraProjection(view: v, letterboxAspect: 0, fieldOfView: nil),
                         "no usable field of view: \(flag)")
            XCTAssertNil(LightCameraProjection(view: v, letterboxAspect: 0, fieldOfView: 1))
            XCTAssertNil(LightCameraProjection(view: v, letterboxAspect: 0, fieldOfView: .nan))
        }
        // Just above 1 is the view's own.
        var v = view()
        v[24] = -1.5
        XCTAssertEqual(LightCameraProjection(view: v, letterboxAspect: 0, fieldOfView: 35)?.fovDegrees,
                       1.5)
    }

    func testBadViewsGiveNil() {
        XCTAssertNil(LightCameraProjection(view: Array(view().prefix(18)), letterboxAspect: 0,
                                           fieldOfView: 20), "the legacy 18-float layout")
        XCTAssertNil(LightCameraProjection(view: view() + [0], letterboxAspect: 0, fieldOfView: 20))
        XCTAssertNil(LightCameraProjection(view: [], letterboxAspect: 0, fieldOfView: 20))
        for bad: Float in [.nan, .infinity, -.infinity] {
            for index in [0, 18, 24] {
                var v = view()
                v[index] = bad
                XCTAssertNil(LightCameraProjection(view: v, letterboxAspect: 0, fieldOfView: 20),
                             "\(bad) at \(index)")
            }
        }
        XCTAssertNil(LightCameraProjection(view: view(fov: 180), letterboxAspect: 0, fieldOfView: 20))
    }

    func testLetterboxIsZeroUnlessPositiveAndFinite() throws {
        for (given, kept) in [(Float(0), 0.0), (-1, 0), (.nan, 0), (.infinity, 0), (2, 2)] {
            let camera = try XCTUnwrap(LightCameraProjection(view: view(), letterboxAspect: given,
                                                             fieldOfView: nil))
            XCTAssertEqual(camera.letterboxAspect, kept, "\(given)")
        }
    }
}

final class LightGizmoProjectionTests: XCTestCase {

    private func camera(ortho: Bool = false, letterbox: Double = 0, fov: Double = 20,
                        distance: Double = 50) -> LightCameraProjection {
        LightCameraProjection(orthoscopic: ortho, fovDegrees: fov, cameraDistance: distance,
                              letterboxAspect: letterbox)
    }

    private func assertPoint(_ got: CGPoint?, _ want: CGPoint, accuracy: Double = 1e-9,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let got else { return XCTFail("no point \(message)", file: file, line: line) }
        XCTAssertEqual(Double(got.x), Double(want.x), accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(Double(got.y), Double(want.y), accuracy: accuracy, message, file: file, line: line)
    }

    func testPerspectivePoints() throws {
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(), viewSize: CGSize(width: 400, height: 300)))
        XCTAssertEqual(p.sceneRect, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(p.aspect, 4.0 / 3.0, accuracy: 1e-12)
        // On the axis: the view's centre.
        assertPoint(p.point(eye: SIMD3<Double>(0, 0, -50)), CGPoint(x: 200, y: 150))
        // ndc = (x / (d t a), y / (d t)); +y up, so a point above the axis is
        // above the centre (smaller y).
        let t = slope(20), a = 4.0 / 3.0
        let e = SIMD3<Double>(3, -2, -40)
        let ndc = SIMD2(3 / (40 * t * a), -2 / (40 * t))
        assertPoint(p.point(eye: e), CGPoint(x: 200 + ndc.x * 200, y: 150 - ndc.y * 150))
        XCTAssertEqual(p.sceneNDC(eye: e)?.x ?? .nan, ndc.x, accuracy: 1e-12)
        XCTAssertEqual(p.sceneNDC(eye: e)?.y ?? .nan, ndc.y, accuracy: 1e-12)
        // The top edge of the frustum at depth 40 is the view's top edge.
        assertPoint(p.point(eye: SIMD3<Double>(0, 40 * t, -40)), CGPoint(x: 200, y: 0))
        assertPoint(p.point(eye: SIMD3<Double>(-40 * t * a, 0, -40)), CGPoint(x: 0, y: 150))
        // Float input projects the same.
        assertPoint(p.point(eye: SIMD3<Float>(3, -2, -40)), CGPoint(x: 200 + ndc.x * 200,
                                                                     y: 150 - ndc.y * 150),
                    accuracy: 1e-4)
    }

    func testOrthoscopicPoints() throws {
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(ortho: true, distance: 60),
                                                   viewSize: CGSize(width: 300, height: 300)))
        let h = 60 * tan(10 * Double.pi / 180)   // max(1e-4, d) GetFovWidth / 2
        // Depth does not matter, and a point behind the eye still projects.
        for z in [-60.0, -10, 5] {
            assertPoint(p.point(eye: SIMD3<Double>(h / 2, h, z)), CGPoint(x: 225, y: 0), "\(z)")
        }
        XCTAssertEqual(p.pointsPerAngstrom(atDepth: -5) ?? .nan, 150 / h, accuracy: 1e-9)
        XCTAssertEqual(p.pointsPerAngstrom(atDepth: 3) ?? .nan, 150 / h, accuracy: 1e-9)
    }

    func testLetterboxWideView() throws {
        // A 4:3 scene in an 800 x 300 view: bars left and right.
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(letterbox: 4.0 / 3.0),
                                                   viewSize: CGSize(width: 800, height: 300)))
        XCTAssertEqual(p.sceneRect, CGRect(x: 200, y: 0, width: 400, height: 300))
        XCTAssertEqual(p.aspect, 4.0 / 3.0, accuracy: 1e-12)
        assertPoint(p.point(sceneNDC: SIMD2(1, 1)), CGPoint(x: 600, y: 0))
        assertPoint(p.point(sceneNDC: SIMD2(-1, -1)), CGPoint(x: 200, y: 300))
        assertPoint(p.point(eye: SIMD3<Double>(0, 0, -30)), CGPoint(x: 400, y: 150))
        XCTAssertNil(p.sceneNDC(point: CGPoint(x: 100, y: 150)), "in the left bar")
        XCTAssertNil(p.sceneNDC(point: CGPoint(x: 700, y: 150)), "in the right bar")
    }

    func testLetterboxTallView() throws {
        // A 4:3 scene in a 300 x 800 view: bars top and bottom.
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(letterbox: 4.0 / 3.0),
                                                   viewSize: CGSize(width: 300, height: 800)))
        XCTAssertEqual(Double(p.sceneRect.minX), 0)
        XCTAssertEqual(Double(p.sceneRect.width), 300)
        XCTAssertEqual(Double(p.sceneRect.height), 225, accuracy: 1e-9)
        XCTAssertEqual(Double(p.sceneRect.minY), (800 - 225) / 2, accuracy: 1e-9)
        assertPoint(p.point(sceneNDC: SIMD2(1, 1)), CGPoint(x: 300, y: 287.5))
        XCTAssertNil(p.sceneNDC(point: CGPoint(x: 150, y: 20)), "in the top bar")
        XCTAssertNotNil(p.sceneNDC(point: CGPoint(x: 150, y: 400)))
    }

    func testNearPlane() throws {
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(), viewSize: CGSize(width: 400, height: 300)))
        XCTAssertNil(p.point(eye: SIMD3<Double>(1, 1, -0.0005)), "in front of the near plane")
        XCTAssertNil(p.point(eye: SIMD3<Double>(1, 1, 0)), "at the eye")
        XCTAssertNil(p.point(eye: SIMD3<Double>(1, 1, 10)), "behind the eye")
        XCTAssertNil(p.point(eye: SIMD3<Double>(.nan, 1, -10)))
        XCTAssertNotNil(p.point(eye: SIMD3<Double>(1, 1, -0.002)))
        XCTAssertNil(p.pointsPerAngstrom(atDepth: 0))
        XCTAssertNil(p.pointsPerAngstrom(atDepth: 4))
        XCTAssertNil(LightGizmoProjection(camera: camera(), viewSize: .zero))
        XCTAssertNil(LightGizmoProjection(camera: camera(), viewSize: CGSize(width: 10, height: -1)))
    }

    /// The scene NDC of a view point equals what SurfacePick.sceneNDC makes of
    /// its view NDC (what the core's pick and click= take), letterbox or not.
    func testSceneNDCMatchesTheSurfacePickMapping() throws {
        let cases: [(CGSize, Double)] = [
            (CGSize(width: 400, height: 300), 0), (CGSize(width: 800, height: 300), 4.0 / 3.0),
            (CGSize(width: 300, height: 800), 4.0 / 3.0), (CGSize(width: 500, height: 500), 2),
        ]
        for (size, letterbox) in cases {
            let p = try XCTUnwrap(LightGizmoProjection(camera: camera(letterbox: letterbox), viewSize: size))
            for fx in stride(from: 0.0, through: 1.0, by: 0.125) {
                for fy in stride(from: 0.0, through: 1.0, by: 0.125) {
                    let point = CGPoint(x: fx * Double(size.width), y: fy * Double(size.height))
                    let v = p.viewNDC(point: point)
                    let pick = SurfacePick.sceneNDC(viewNDC: SIMD2(Float(v.x), Float(v.y)),
                                                    viewAspect: Float(size.width / size.height),
                                                    letterboxAspect: Float(letterbox))
                    let mine = p.sceneNDC(point: point)
                    let label = "\(size) \(letterbox) \(point)"
                    XCTAssertEqual(pick == nil, mine == nil, label)
                    if let pick, let mine {
                        XCTAssertEqual(Double(pick.x), mine.x, accuracy: 1e-5, label)
                        XCTAssertEqual(Double(pick.y), mine.y, accuracy: 1e-5, label)
                        // and back to the same point
                        let back = p.point(sceneNDC: mine)
                        XCTAssertEqual(Double(back.x), Double(point.x), accuracy: 1e-6, label)
                        XCTAssertEqual(Double(back.y), Double(point.y), accuracy: 1e-6, label)
                    }
                }
            }
        }
        // View NDC: top-left is (-1, 1), bottom-right (1, -1), +y up.
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(), viewSize: CGSize(width: 200, height: 100)))
        XCTAssertEqual(p.viewNDC(point: .zero), SIMD2(-1, 1))
        XCTAssertEqual(p.viewNDC(point: CGPoint(x: 200, y: 100)), SIMD2(1, -1))
    }

    /// ray(at: point(p)) passes through p, in perspective and orthoscopic,
    /// with and without a letterbox.
    func testRayThroughAProjectedPointHitsIt() throws {
        let points: [SIMD3<Double>] = [
            SIMD3(0, 0, -50), SIMD3(3, -2, -40), SIMD3(-8, 5, -70), SIMD3(12, 9, -35),
        ]
        for ortho in [false, true] {
            for letterbox in [0.0, 1.0] {
                let p = try XCTUnwrap(LightGizmoProjection(camera: camera(ortho: ortho, letterbox: letterbox),
                                                           viewSize: CGSize(width: 640, height: 360)))
                for e in points {
                    let label = "ortho \(ortho) letterbox \(letterbox) \(e)"
                    let point = try XCTUnwrap(p.point(eye: e), label)
                    let ray = try XCTUnwrap(p.ray(at: point), label)
                    XCTAssertEqual((ray.direction * ray.direction).sum(), 1, accuracy: 1e-12, label)
                    XCTAssertLessThan(ray.direction.z, 0, "the ray looks down -z: \(label)")
                    // Distance from e to the ray's line.
                    let w = e - ray.origin
                    let along = (w * ray.direction).sum()
                    let off = w - along * ray.direction
                    XCTAssertLessThan((off * off).sum().squareRoot(), 1e-9, label)
                    XCTAssertGreaterThan(along, 0, "e is in front of the origin: \(label)")
                    if ortho {
                        XCTAssertEqual(ray.direction, SIMD3(0, 0, -1), label)
                    } else {
                        XCTAssertEqual(ray.origin, .zero, label)
                    }
                }
            }
        }
        let p = try XCTUnwrap(LightGizmoProjection(camera: camera(), viewSize: CGSize(width: 10, height: 10)))
        XCTAssertNil(p.ray(at: CGPoint(x: CGFloat.nan, y: 0)))
    }

    /// One Å at depth z spans pointsPerAngstrom(z) points, across and up.
    func testPointsPerAngstrom() throws {
        for letterbox in [0.0, 2.0] {
            let p = try XCTUnwrap(LightGizmoProjection(camera: camera(letterbox: letterbox),
                                                       viewSize: CGSize(width: 600, height: 400)))
            for z in [-20.0, -50, -90] {
                let ppa = try XCTUnwrap(p.pointsPerAngstrom(atDepth: z))
                let a = try XCTUnwrap(p.point(eye: SIMD3<Double>(1, 2, z)))
                let b = try XCTUnwrap(p.point(eye: SIMD3<Double>(1, 3, z)))
                let c = try XCTUnwrap(p.point(eye: SIMD3<Double>(2, 2, z)))
                XCTAssertEqual(Double(a.y - b.y), ppa, accuracy: 1e-9, "up, \(z) \(letterbox)")
                XCTAssertEqual(Double(c.x - a.x), ppa, accuracy: 1e-9, "across, \(z) \(letterbox)")
                let half = Double(p.sceneRect.height) / 2
                XCTAssertEqual(ppa, half / (-z * slope(20)), accuracy: 1e-9)
            }
        }
    }
}

final class LightDepthTests: XCTestCase {

    func testTheRule() {
        // cos(orbit) cos(pitch) < -1e-4: behind the rig centre in eye depth.
        let cases: [(orbit: Double, pitch: Double, behind: Bool)] = [
            (0, 0, false), (45, 30, false), (88, 0, false), (-88, 0, false),
            (90, 0, false), (-90, 0, false),
            (92, 0, true), (-92, 0, true), (120, 40, true), (180, 0, true), (-150, -30, true),
            (180, 89, true), (0, 90, false), (180, 90, false), (180, -90, false),
            (0, 92, true),      // a pitch past the pole is behind (the core clamps first)
        ]
        for c in cases {
            XCTAssertEqual(LightDepth.isBehind(orbit: c.orbit, pitch: c.pitch), c.behind,
                           "orbit \(c.orbit) pitch \(c.pitch)")
            XCTAssertEqual(LightDepth.isBehind(LightPlacement(orbit: c.orbit, pitch: c.pitch, radius: 3)),
                           c.behind)
        }
    }

    func testFloatNoiseOnTheOutlineNeverFlips() {
        // A pinned light read back as a Float sits within ~1e-5 degrees of
        // where it is: on the outline it stays in front.
        for noise in stride(from: -1e-3, through: 1e-3, by: 1e-4) {
            XCTAssertFalse(LightDepth.isBehind(orbit: 90 + noise, pitch: 0), "orbit \(90 + noise)")
            XCTAssertFalse(LightDepth.isBehind(orbit: -90 - noise, pitch: 10), "orbit \(-90 - noise)")
            XCTAssertFalse(LightDepth.isBehind(orbit: 180, pitch: 90 - noise), "pitch \(90 - noise)")
        }
        let float = Double(Float(90.00001))
        XCTAssertFalse(LightDepth.isBehind(orbit: float, pitch: 0))
        // The tolerance is about 0.006 degrees: a hundredth of a degree past
        // the outline is behind.
        XCTAssertTrue(LightDepth.isBehind(orbit: 90.01, pitch: 0))
        XCTAssertEqual(LightDepth.tolerance, 1e-4)
    }
}
