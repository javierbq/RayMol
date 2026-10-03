import XCTest
@testable import RayMol

/// Coverage for the Swift side of the surface pick (#614):
/// `PyMOLEngine.pickSurface` / `prepareSurfacePick`, the `SurfacePick` value
/// the bridge's output parses into, and the letterbox mapping from view NDC to
/// the scene viewport's NDC.
///
/// The test bundle has no bridging header (project.yml blanks it), so it never
/// calls `PyMOLBridge_*` itself: it goes through the engine's static seams,
/// whose signatures use Swift types only.
///
/// The live test runs against the real engine and a real Metal frame. Its
/// point is the cartoon's preshader-to-ray swap: the first frame that draws a
/// cartoon moves its primitive CGO to another owner, and the pick grid
/// references that CGO's arrays in place. Picks before and after the frame
/// must agree, and the grid must survive it. Headless CI never draws, so only
/// this test covers the swap.
@MainActor
final class SurfacePickTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    // MARK: - Parsing the bridge's output

    private let rawHit: [Float] = [1, 2, 3, 0, 0.6, 0.8, 98.5, 0.75]

    func testRawParsing() throws {
        let hit = try XCTUnwrap(SurfacePick(raw: rawHit, flags: 1))
        XCTAssertEqual(hit.point, SIMD3(1, 2, 3))
        XCTAssertEqual(hit.normal, SIMD3(0, 0.6, 0.8))
        XCTAssertEqual(hit.depth, 98.5)
        XCTAssertEqual(hit.facing, 0.75)
        XCTAssertFalse(hit.inside)
        XCTAssertFalse(hit.cap)

        // The flag bits: 1 = hit, 2 = inside, 4 = cap.
        let inside = try XCTUnwrap(SurfacePick(raw: rawHit, flags: 1 | 2))
        XCTAssertTrue(inside.inside)
        XCTAssertFalse(inside.cap)
        let cap = try XCTUnwrap(SurfacePick(raw: rawHit, flags: 1 | 4))
        XCTAssertFalse(cap.inside)
        XCTAssertTrue(cap.cap)
        let both = try XCTUnwrap(SurfacePick(raw: rawHit, flags: 7))
        XCTAssertTrue(both.inside && both.cap)
    }

    func testRawParsingRejectsMissesAndBadData() {
        XCTAssertNil(SurfacePick(raw: rawHit, flags: 0), "0 is the bridge's miss")
        XCTAssertNil(SurfacePick(raw: rawHit, flags: 2),
                     "flag bits without the hit bit are not a hit")
        XCTAssertNil(SurfacePick(raw: Array(rawHit.prefix(7)), flags: 1))
        XCTAssertNil(SurfacePick(raw: rawHit + [0], flags: 1))
        XCTAssertNil(SurfacePick(raw: [], flags: 1))
        for i in rawHit.indices {
            var nan = rawHit
            nan[i] = .nan
            XCTAssertNil(SurfacePick(raw: nan, flags: 1), "NaN at \(i)")
            var inf = rawHit
            inf[i] = .infinity
            XCTAssertNil(SurfacePick(raw: inf, flags: 1), "infinity at \(i)")
        }
    }

    // MARK: - Letterbox mapping

    private func assertNDC(_ got: SIMD2<Float>?, _ want: SIMD2<Float>,
                           _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let got else {
            XCTFail("expected \(want), got nil. \(message)", file: file, line: line)
            return
        }
        XCTAssertEqual(got.x, want.x, accuracy: 1e-5, message, file: file, line: line)
        XCTAssertEqual(got.y, want.y, accuracy: 1e-5, message, file: file, line: line)
    }

    func testNoLetterboxIsTheIdentity() {
        let p = SIMD2<Float>(0.3, -0.7)
        for lb: Float in [0, -1, .nan, .infinity] {
            for va: Float in [0.5, 1, 2.4, 0, .nan] {
                assertNDC(SurfacePick.sceneNDC(viewNDC: p, viewAspect: va, letterboxAspect: lb),
                          p, "letterbox \(lb), view aspect \(va)")
            }
        }
        // Equal aspects: the sub-rect is the whole view.
        assertNDC(SurfacePick.sceneNDC(viewNDC: p, viewAspect: 1.5, letterboxAspect: 1.5), p)
    }

    func testWideViewHasBarsLeftAndRight() {
        // A 2:1 view showing a 1:1 scene: the scene is the middle half.
        let map = { (x: Float, y: Float) in
            SurfacePick.sceneNDC(viewNDC: SIMD2(x, y), viewAspect: 2, letterboxAspect: 1)
        }
        assertNDC(map(0, 0), SIMD2(0, 0))
        assertNDC(map(0.25, 0.5), SIMD2(0.5, 0.5))
        assertNDC(map(-0.5, 1), SIMD2(-1, 1), "the sub-rect's corner")
        assertNDC(map(0.5, -1), SIMD2(1, -1), "the sub-rect's corner")
        XCTAssertNil(map(0.6, 0), "right bar")
        XCTAssertNil(map(-0.75, 0.2), "left bar")
        XCTAssertNil(map(0, 1.2), "outside the view")
    }

    func testTallViewHasBarsTopAndBottom() {
        // A 1:2 view showing a 1:1 scene: the scene is the middle half.
        let map = { (x: Float, y: Float) in
            SurfacePick.sceneNDC(viewNDC: SIMD2(x, y), viewAspect: 0.5, letterboxAspect: 1)
        }
        assertNDC(map(0.5, 0.25), SIMD2(0.5, 0.5))
        assertNDC(map(1, 0.5), SIMD2(1, 1), "the sub-rect's corner")
        assertNDC(map(-1, -0.5), SIMD2(-1, -1), "the sub-rect's corner")
        XCTAssertNil(map(0, 0.6), "top bar")
        XCTAssertNil(map(0.1, -0.9), "bottom bar")
    }

    func testMappingMatchesTheBridgesSubRect() {
        // PyMOLBridge_RenderMetalFrame on a 1000x500 drawable with a 1.5
        // letterbox: vpW = 750, ox = 125. The sub-rect's left and right pixel
        // edges map to -1 and +1, its centre to 0.
        let width: Float = 1000, height: Float = 500, lb: Float = 1.5
        let vpW = (height * lb).rounded(), ox = (width - vpW) / 2
        for (px, want) in [(ox, Float(-1)), (ox + vpW, 1), (width / 2, 0)] {
            let viewX = px / width * 2 - 1
            assertNDC(SurfacePick.sceneNDC(viewNDC: SIMD2(viewX, 0.3),
                                           viewAspect: width / height, letterboxAspect: lb),
                      SIMD2(want, 0.3), "pixel \(px)")
        }
        XCTAssertNil(SurfacePick.sceneNDC(viewNDC: SIMD2((ox - 2) / width * 2 - 1, 0),
                                          viewAspect: width / height, letterboxAspect: lb),
                     "two pixels into the left bar")
    }

    func testNonFiniteInputIsAMiss() {
        XCTAssertNil(SurfacePick.sceneNDC(viewNDC: SIMD2(.nan, 0), viewAspect: 1, letterboxAspect: 0))
        XCTAssertNil(SurfacePick.sceneNDC(viewNDC: SIMD2(0, .infinity), viewAspect: 2, letterboxAspect: 1))
        XCTAssertNil(SurfacePick.sceneNDC(viewNDC: SIMD2(0, 0), viewAspect: 0, letterboxAspect: 1),
                     "with a letterbox the view aspect decides where the bars are")
        XCTAssertNil(SurfacePick.sceneNDC(viewNDC: SIMD2(0, 0), viewAspect: .nan, letterboxAspect: 1))
    }

    // MARK: - The bridge's null guards, through the seams

    func testNilHandleIsAMiss() {
        XCTAssertNil(PyMOLEngine.surfacePick(handle: nil, sceneNDCX: 0, sceneNDCY: 0,
                                             updateReps: false))
        XCTAssertNil(PyMOLEngine.surfacePick(handle: nil, sceneNDCX: 0, sceneNDCY: 0,
                                             updateReps: true))
        XCTAssertEqual(PyMOLEngine.surfacePickPrepare(handle: nil, updateReps: true), 0)
        XCTAssertEqual(PyMOLEngine.letterboxAspect(handle: nil), 0)
    }

    // MARK: - Live

    /// The pinned camera of testing/tests/raymol/lighting_pick.py: identity
    /// rotation, the eye at z = +100 looking down -z at the origin, slab
    /// [50, 150], perspective with field_of_view 20.
    private static let pinnedView =
        "(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, "
        + "0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 50.0, 150.0, -20.0)"

    private var savedView: [Float]?
    private var liveSceneBuilt = false

    override func tearDown() {
        engine.exportRenderActive = false
        if liveSceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "for _n in ('lt614probe', 'lt614surf', 'lt614pep'):\n"
                + "    _c.delete(_n)\n"
                + "for _n in globals().pop('_lt614_enabled', []):\n"
                + "    _c.enable(_n)\n")
            liveSceneBuilt = false
        }
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        super.tearDown()
    }

    /// Spin the main run loop (never block it) until the engine is up.
    private func waitForEngine(timeout: TimeInterval = 20) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !engine.isReady && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard engine.isReady else {
            throw XCTSkip("the PyMOL engine did not come up under the test host in \(timeout) s")
        }
    }

    /// Run `body` in the live interpreter with `_c` (pymol.cmd) and an `_out`
    /// dict in scope, and read `_out` back as JSON. Empty when the code raised.
    private func python(_ body: String) -> [String: Any] {
        let path = NSTemporaryDirectory() + "lt614_surface_pick.json"
        try? FileManager.default.removeItem(atPath: path)
        engine.runPython(
            "import json as _json\n"
            + "from pymol import cmd as _c\n"
            + "_out = {}\n"
            + body + "\n"
            + "open(r'\(path)', 'w').write(_json.dumps(_out))\n")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    /// The projection the pick uses, from a 25-float view (PyMOLBridge_GetView):
    /// eye = R (p - origin) + pos, depth = -eye.z, and NDC with the
    /// GetFovWidth half-height slope tan(2 tan(fov / 2) / 2).
    private struct Camera {
        let rot: [Double]   // 4x4, column-major
        let pos: SIMD3<Double>
        let origin: SIMD3<Double>
        let tanHalf: Double

        init?(view: [Float]) {
            guard view.count == 25, view[24] < 0 else { return nil }  // perspective
            rot = view[0..<16].map(Double.init)
            pos = SIMD3(Double(view[16]), Double(view[17]), Double(view[18]))
            origin = SIMD3(Double(view[19]), Double(view[20]), Double(view[21]))
            let fov = Double(abs(view[24])) * .pi / 180
            tanHalf = tan(2 * tan(fov / 2) / 2)
        }

        func eye(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = p - origin
            return SIMD3(rot[0] * d.x + rot[4] * d.y + rot[8] * d.z,
                         rot[1] * d.x + rot[5] * d.y + rot[9] * d.z,
                         rot[2] * d.x + rot[6] * d.y + rot[10] * d.z) + pos
        }

        /// (scene NDC, eye depth) of a world point.
        func project(_ p: SIMD3<Double>, aspect: Double) -> (SIMD2<Double>, Double) {
            let e = eye(p)
            let depth = -e.z
            return (SIMD2(e.x / (depth * tanHalf * aspect), e.y / (depth * tanHalf)), depth)
        }

        /// The eye in world space: R^T (0 - pos) + origin.
        var eyeWorld: SIMD3<Double> {
            SIMD3((0..<3).map { j in
                -(rot[4 * j] * pos.x + rot[4 * j + 1] * pos.y + rot[4 * j + 2] * pos.z)
            }) + origin
        }
    }

    /// The inverse of SurfacePick.sceneNDC, to aim at a scene point.
    private func viewNDC(scene s: SIMD2<Float>, viewAspect va: Float,
                         letterboxAspect lb: Float) -> SIMD2<Float> {
        guard lb.isFinite, lb > 0 else { return s }
        return va > lb ? SIMD2(s.x * lb / va, s.y) : SIMD2(s.x, s.y * va / lb)
    }

    private func double3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    private func length(_ v: SIMD3<Float>) -> Float {
        (v * v).sum().squareRoot()
    }

    /// The hit lies on the camera ray through `scene` at its reported depth,
    /// and its (nudged) unit normal faces the camera.
    private func assertOnRay(_ hit: SurfacePick, scene: SIMD2<Float>, camera: Camera,
                             aspect: Double, file: StaticString = #filePath,
                             line: UInt = #line) {
        let p = double3(hit.point)
        let (ndc, depth) = camera.project(p, aspect: aspect)
        XCTAssertEqual(depth, Double(hit.depth), accuracy: 1e-3,
                       "depth of \(hit.point)", file: file, line: line)
        XCTAssertEqual(ndc.x, Double(scene.x), accuracy: 1e-3,
                       "\(hit.point) is off the ray through \(scene)", file: file, line: line)
        XCTAssertEqual(ndc.y, Double(scene.y), accuracy: 1e-3,
                       "\(hit.point) is off the ray through \(scene)", file: file, line: line)
        XCTAssertEqual(length(hit.normal), 1, accuracy: 1e-4, file: file, line: line)
        // The silhouette nudge guarantees at least 0.05 toward the camera; the
        // pre-nudge `facing` may dip below 0 on a grazing, smooth-shaded hit.
        let toCamera = camera.eyeWorld - p
        let v = toCamera / (toCamera * toCamera).sum().squareRoot()
        XCTAssertGreaterThanOrEqual((double3(hit.normal) * v).sum(), 0.05 - 1e-4,
                                    "the normal at \(hit.point) does not face the camera",
                                    file: file, line: line)
    }

    func testLivePicksAcrossTheCartoonSwap() throws {
        try waitForEngine()
        savedView = engine.captureView()
        XCTAssertNotNil(savedView)

        // A probe sphere and a one-atom surface at the origin, and a 12-residue
        // helix centred there; only the probe enabled. Nothing has drawn them yet.
        liveSceneBuilt = true
        let setup = python(
            "_lt614_enabled = _c.get_names('objects', enabled_only=1)\n"
            + "for _n in _lt614_enabled:\n"
            + "    _c.disable(_n)\n"
            + "_c.pseudoatom('lt614probe', pos=[0.0, 0.0, 0.0], vdw=2.0)\n"
            + "_c.show_as('spheres', 'lt614probe')\n"
            + "_c.pseudoatom('lt614surf', pos=[0.0, 0.0, 0.0], vdw=2.0)\n"
            + "_c.show_as('surface', 'lt614surf')\n"
            + "_c.fab('AAAAAAAAAAAA', 'lt614pep', ss=1)\n"
            + "_c.dss('lt614pep')\n"
            + "_c.show_as('cartoon', 'lt614pep')\n"
            + "_e = _c.get_extent('lt614pep')\n"
            + "_c.translate([-(_e[0][i] + _e[1][i]) / 2.0 for i in range(3)],\n"
            + "             selection='lt614pep', camera=0)\n"
            + "_c.disable('lt614surf')\n"
            + "_c.disable('lt614pep')\n"
            + "_c.set_view(\(Self.pinnedView))\n"
            + "_out['extent'] = _c.get_extent('lt614pep')\n"
            + "_out['viewport'] = list(_c.get_viewport(output=0))\n")
        let extent = try XCTUnwrap(setup["extent"] as? [[Double]], "setup failed: \(setup)")
        let viewport = try XCTUnwrap(setup["viewport"] as? [Double], "setup failed: \(setup)")
        XCTAssertEqual(extent.count, 2)
        XCTAssertEqual(viewport.count, 2)
        XCTAssertGreaterThan(viewport[1], 0)
        let sceneAspect = viewport[0] / viewport[1]
        let camera = try XCTUnwrap(engine.captureView().flatMap(Camera.init(view:)))
        XCTAssertEqual(camera.pos.z, -100, accuracy: 1e-3, "the pinned view was not applied")

        // The pick maps view NDC through the live letterbox; aim with the same.
        let letterbox = engine.currentLetterboxAspect
        let px = engine.viewportPixelSize
        let viewAspect = px.width > 0 && px.height > 0
            ? Float(px.width / px.height) : Float(sceneAspect)
        let pick = { (scene: SIMD2<Float>, update: Bool) -> SurfacePick? in
            let v = self.viewNDC(scene: scene, viewAspect: viewAspect, letterboxAspect: letterbox)
            if let back = SurfacePick.sceneNDC(viewNDC: v, viewAspect: viewAspect,
                                               letterboxAspect: letterbox) {
                XCTAssertEqual(back.x, scene.x, accuracy: 1e-4)
                XCTAssertEqual(back.y, scene.y, accuracy: 1e-4)
            }
            return self.engine.pickSurface(viewNDCX: v.x, viewNDCY: v.y,
                                           viewAspect: viewAspect, updateReps: update)
        }

        // 1. The probe sphere: its front pole, facing the camera.
        let probe = try XCTUnwrap(pick(SIMD2(0, 0), true), "the probe sphere was not picked")
        XCTAssertEqual(probe.point.x, 0, accuracy: 1e-2)
        XCTAssertEqual(probe.point.y, 0, accuracy: 1e-2)
        XCTAssertEqual(probe.point.z, 2, accuracy: 1e-2)
        XCTAssertEqual(probe.normal.x, 0, accuracy: 1e-2)
        XCTAssertEqual(probe.normal.y, 0, accuracy: 1e-2)
        XCTAssertEqual(probe.normal.z, 1, accuracy: 1e-2)
        XCTAssertEqual(probe.depth, 98, accuracy: 1e-2)
        XCTAssertGreaterThan(probe.facing, 0.99)
        XCTAssertFalse(probe.inside)
        XCTAssertFalse(probe.cap)
        assertOnRay(probe, scene: SIMD2(0, 0), camera: camera, aspect: sceneAspect)
        XCTAssertNil(pick(SIMD2(0.9, 0.9), false), "empty space is a miss")

        // Refused while a movie export owns the core off the main thread.
        engine.exportRenderActive = true
        XCTAssertNil(pick(SIMD2(0, 0), false), "picked during a movie export")
        XCTAssertEqual(engine.prepareSurfacePick(), 0, "prepared during a movie export")
        engine.exportRenderActive = false

        // 2. The cartoon, before any frame has drawn it (its CGO is still the
        // preshader): a 5x5 grid over the central 60% of its projected box.
        _ = python("_c.disable('lt614probe')\n_c.enable('lt614pep')\n")
        var corners: [SIMD2<Double>] = []
        for x in [extent[0][0], extent[1][0]] {
            for y in [extent[0][1], extent[1][1]] {
                for z in [extent[0][2], extent[1][2]] {
                    corners.append(camera.project(SIMD3(x, y, z), aspect: sceneAspect).0)
                }
            }
        }
        let lo = SIMD2(corners.map(\.x).min()!, corners.map(\.y).min()!)
        let hi = SIMD2(corners.map(\.x).max()!, corners.map(\.y).max()!)
        var grid: [SIMD2<Float>] = []
        for i in 0..<5 {
            for j in 0..<5 {
                let t = SIMD2(0.2 + 0.6 * Double(i) / 4, 0.2 + 0.6 * Double(j) / 4)
                let p = lo + (hi - lo) * t
                grid.append(SIMD2(Float(p.x), Float(p.y)))
            }
        }
        let before = grid.map { pick($0, true) }
        let hits = zip(grid, before).compactMap { s, h in h.map { (s, $0) } }
        XCTAssertGreaterThanOrEqual(hits.count, 3, "too few cartoon hits: \(before)")
        for (scene, hit) in hits {
            assertOnRay(hit, scene: scene, camera: camera, aspect: sceneAspect)
            XCTAssertFalse(hit.cap)
        }

        // 3. A real offscreen Metal frame: RepCartoon::render with a GUI runs
        // the preshader-to-ray swap.
        let png = NSTemporaryDirectory() + "lt614_surface_pick.png"
        try? FileManager.default.removeItem(atPath: png)
        engine.renderHiResPNG(png, width: 64, height: 48, rayTraced: 0)
        let attributes = try? FileManager.default.attributesOfItem(atPath: png)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0, "no frame rendered (is there a Metal renderer?)")
        try? FileManager.default.removeItem(atPath: png)

        // 4. The same grid, without an update: the same answers from the same
        // grid -- no stale or dangling reference across the swap.
        let after = grid.map { pick($0, false) }
        for (k, (b, a)) in zip(before, after).enumerated() {
            guard let b, let a else {
                XCTAssertEqual(b == nil, a == nil, "hit/miss changed at \(grid[k])")
                continue
            }
            XCTAssertLessThanOrEqual(length(a.point - b.point), 1e-4, "point moved at \(grid[k])")
            XCTAssertLessThanOrEqual(length(a.normal - b.normal), 1e-4, "normal turned at \(grid[k])")
            XCTAssertEqual(a.depth, b.depth, accuracy: 1e-4)
            XCTAssertEqual(a.facing, b.facing, accuracy: 1e-4)
            XCTAssertEqual(a.inside, b.inside)
            XCTAssertEqual(a.cap, b.cap)
        }
        let identical = zip(before, after).filter { $0 == $1 }.count
        // The cartoon's grid outlived the swap: nothing needed building.
        let warm = python(
            "from pymol import metal_pick as _mp\n"
            + "_out.update(_mp.surface_warm(update=False))\n")
        XCTAssertEqual(warm["accels"] as? Int, 1, "\(warm)")
        XCTAssertEqual(warm["built"] as? Int, 0, "the cartoon's grid was rebuilt after the frame: \(warm)")

        // 5. The one-atom surface: within half an Angstrom of r = 2.
        _ = python("_c.disable('lt614pep')\n_c.enable('lt614surf')\n")
        let surface = try XCTUnwrap(pick(SIMD2(0, 0), true), "the surface was not picked")
        XCTAssertEqual(length(surface.point), 2, accuracy: 0.5)
        XCTAssertGreaterThan(surface.point.z, 0, "the far side of the surface was picked")
        XCTAssertGreaterThan(surface.facing, 0)
        XCTAssertFalse(surface.inside)
        assertOnRay(surface, scene: SIMD2(0, 0), camera: camera, aspect: sceneAspect)

        // 6. Prepare reports the grids it holds.
        let prepared = engine.prepareSurfacePick()
        XCTAssertGreaterThanOrEqual(prepared, 1)

        // One line in the test log saying which steps ran (L5 evidence).
        print("SurfacePickTests live: probe \(probe.point) n \(probe.normal) depth \(probe.depth); "
              + "cartoon \(hits.count)/\(grid.count) hits, \(identical)/\(grid.count) bit-identical after the frame; "
              + "frame \(size) B (letterbox \(letterbox), scene aspect \(sceneAspect)); "
              + "warm \(warm); surface \(surface.point) facing \(surface.facing); "
              + "prepare \(prepared)")
    }
}
