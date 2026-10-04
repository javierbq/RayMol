import CoreGraphics
import ImageIO
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
        XCTAssertEqual(PyMOLEngine.surfacePickRelease(handle: nil), 0)
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
                + "for _n in ('lt614probe', 'lt614surf', 'lt614pep', 'lt614dna', 'lt614br'):\n"
                + "    _c.delete(_n)\n"
                + "if '_lt614_transparency_mode' in globals():\n"
                + "    _c.set('transparency_mode', globals().pop('_lt614_transparency_mode'))\n"
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

    /// RGBA8 pixels of a PNG, top row first.
    private func pngPixels(_ path: String) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (w, h, rgba) : nil
    }

    /// Render an offscreen Metal frame (the full pipeline, rasterized) and
    /// return its pixels; nil when no frame was written.
    private func renderFrame(width: Int, height: Int)
        -> (width: Int, height: Int, rgba: [UInt8])? {
        let png = NSTemporaryDirectory() + "lt614_surface_pick.png"
        try? FileManager.default.removeItem(atPath: png)
        engine.renderHiResPNG(png, width: width, height: height, rayTraced: 0)
        defer { try? FileManager.default.removeItem(atPath: png) }
        return pngPixels(png)
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
        // the preshader-to-ray swap. First the same frame with the helix
        // disabled (a disabled object is not rendered, so no swap yet), to
        // tell the helix's pixels from the background, whatever it is.
        let (fw, fh) = (128, 96)
        _ = python("_c.disable('lt614pep')\n")
        let empty = try XCTUnwrap(renderFrame(width: fw, height: fh),
                                  "no frame rendered (is there a Metal renderer?)")
        _ = python("_c.enable('lt614pep')\n")
        let frame = try XCTUnwrap(renderFrame(width: fw, height: fh),
                                  "no frame rendered (is there a Metal renderer?)")
        XCTAssertEqual(frame.width, fw)
        XCTAssertEqual(frame.height, fh)
        XCTAssertEqual(empty.rgba.count, frame.rgba.count)
        // The frame is composed at its own aspect: where the helix projects
        // in it (the central 60% of its projected box, in pixels).
        let frameAspect = Double(fw) / Double(fh)
        var boxLo = SIMD2(Double.infinity, Double.infinity)
        var boxHi = -boxLo
        for x in [extent[0][0], extent[1][0]] {
            for y in [extent[0][1], extent[1][1]] {
                for z in [extent[0][2], extent[1][2]] {
                    let ndc = camera.project(SIMD3(x, y, z), aspect: frameAspect).0
                    let pixel = SIMD2((ndc.x + 1) / 2 * Double(fw), (1 - ndc.y) / 2 * Double(fh))
                    boxLo = SIMD2(min(boxLo.x, pixel.x), min(boxLo.y, pixel.y))
                    boxHi = SIMD2(max(boxHi.x, pixel.x), max(boxHi.y, pixel.y))
                }
            }
        }
        let inLo = boxLo + (boxHi - boxLo) * 0.2, inHi = boxHi - (boxHi - boxLo) * 0.2
        var inside = 0, changed = 0, outsideChanged = 0, outside = 0
        for row in 0..<fh {
            for col in 0..<fw {
                let i = 4 * (row * fw + col)
                let delta = (0..<3).map { abs(Int(frame.rgba[i + $0]) - Int(empty.rgba[i + $0])) }.max()!
                let c = SIMD2(Double(col) + 0.5, Double(row) + 0.5)
                if c.x >= inLo.x && c.x <= inHi.x && c.y >= inLo.y && c.y <= inHi.y {
                    inside += 1
                    if delta > 24 { changed += 1 }
                } else if c.x < boxLo.x - 2 || c.x > boxHi.x + 2 || c.y < boxLo.y - 2 || c.y > boxHi.y + 2 {
                    outside += 1
                    if delta > 24 { outsideChanged += 1 }
                }
            }
        }
        // The helix was drawn in this frame: a good share of its box changed,
        // and (nearly) nothing well outside it did.
        XCTAssertGreaterThan(inside, 50, "the helix projects to too few pixels")
        XCTAssertGreaterThan(changed, max(20, inside / 10),
                             "the frame did not draw the cartoon (\(changed)/\(inside) changed)")
        XCTAssertLessThan(outsideChanged, max(4, outside / 50),
                          "pixels changed away from the helix (\(outsideChanged)/\(outside))")

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

        // 6. Prepare reports the grids it holds; release drops them all (the
        // memory goes back), and the next pick builds what it needs again.
        let prepared = engine.prepareSurfacePick()
        XCTAssertGreaterThanOrEqual(prepared, 1)
        let released = engine.releaseSurfacePick()
        XCTAssertGreaterThanOrEqual(released, prepared)
        XCTAssertEqual(engine.releaseSurfacePick(), 0, "a grid survived the release")
        let again = try XCTUnwrap(pick(SIMD2(0, 0), false), "no pick after the release")
        XCTAssertEqual(again, surface)
        engine.exportRenderActive = true
        XCTAssertEqual(engine.releaseSurfacePick(), 0, "released during a movie export")
        engine.exportRenderActive = false

        // One line in the test log saying which steps ran (L5 evidence).
        print("SurfacePickTests live: probe \(probe.point) n \(probe.normal) depth \(probe.depth); "
              + "cartoon \(hits.count)/\(grid.count) hits, \(identical)/\(grid.count) bit-identical after the frame; "
              + "frame \(fw)x\(fh), helix \(changed)/\(inside) px drawn "
              + "(letterbox \(letterbox), scene aspect \(sceneAspect)); "
              + "warm \(warm); surface \(surface.point) facing \(surface.facing); "
              + "prepare \(prepared), release \(released)")
    }

    /// Live checks of what only the app builds or records: sticks with open
    /// ends at a branched atom (use_shaders is forced on), and the cartoon
    /// sphere treatment a frame decides (per-atom transparency, recorded by
    /// RepCartoonCGOGenerate; transparency_mode, read only then).
    func testLiveGeometryOnlyTheAppBuilds() throws {
        try waitForEngine()
        savedView = engine.captureView()
        XCTAssertNotNil(savedView)
        liveSceneBuilt = true

        // A three-bond junction at CB, bonds made CA-CB first, so CB-CC
        // (along the view axis, toward the camera) and CB-CD are open at CB:
        // lighting_pick.py's TestBranchedSticks.
        let built = python(
            "_lt614_enabled = _c.get_names('objects', enabled_only=1)\n"
            + "for _n in _lt614_enabled:\n"
            + "    _c.disable(_n)\n"
            + "_lt614_transparency_mode = _c.get('transparency_mode')\n"
            + "for _n, _p in (('CA', (-1.45, 0.25, -0.30)), ('CB', (0.0, 0.0, 0.0)),\n"
            + "               ('CC', (0.0, 0.0, 1.5)), ('CD', (0.85, -0.70, 0.95))):\n"
            + "    _c.pseudoatom('lt614br', name=_n, pos=list(_p))\n"
            + "for _a, _b in (('CA', 'CB'), ('CB', 'CC'), ('CB', 'CD')):\n"
            + "    _c.bond('lt614br and name ' + _a, 'lt614br and name ' + _b)\n"
            + "_c.show_as('sticks', 'lt614br')\n"
            + "_c.set_view(\(Self.pinnedView))\n"
            + "_out['r'] = _c.get_setting_float('stick_radius', 'lt614br')\n"
            + "_out['use_shaders'] = _c.get_setting_int('use_shaders')\n"
            + "_out['viewport'] = list(_c.get_viewport(output=0))\n")
        let r = try XCTUnwrap(built["r"] as? Double, "setup failed: \(built)")
        let viewport = try XCTUnwrap(built["viewport"] as? [Double], "setup failed: \(built)")
        XCTAssertEqual(viewport.count, 2)
        XCTAssertGreaterThan(viewport[1], 0)
        let sceneAspect = viewport[0] / viewport[1]
        XCTAssertEqual(built["use_shaders"] as? Int, 1, "the app runs with use_shaders on")
        let camera = try XCTUnwrap(engine.captureView().flatMap(Camera.init(view:)))
        XCTAssertEqual(camera.pos.z, -100, accuracy: 1e-3, "the pinned view was not applied")
        let letterbox = engine.currentLetterboxAspect
        let px = engine.viewportPixelSize
        let viewAspect = px.width > 0 && px.height > 0
            ? Float(px.width / px.height) : Float(sceneAspect)
        let pick = { (scene: SIMD2<Float>, update: Bool) -> SurfacePick? in
            let v = self.viewNDC(scene: scene, viewAspect: viewAspect, letterboxAspect: letterbox)
            return self.engine.pickSurface(viewNDCX: v.x, viewNDCY: v.y,
                                           viewAspect: viewAspect, updateReps: update)
        }

        // Straight down CB-CC: in through CC's ball, out through the open
        // end at CB. The front is CC's ball, 1.5 A in front of CB's.
        let axis = try XCTUnwrap(pick(SIMD2(0, 0), true), "the junction was not picked")
        XCTAssertEqual(axis.depth, Float(100 - 1.5 - r), accuracy: 1e-2)
        XCTAssertEqual(axis.normal.z, 1, accuracy: 1e-3)
        XCTAssertFalse(axis.cap)

        // The junction just in front of the near plane, interior cap on: a
        // ray down CB-CC is capped at the plane. Its front, CC's ball, is in
        // front of the plane, but the bond's infinite tube runs on behind
        // it, and that is what cyl_shade decides the cap from.
        _ = python("_c.translate([0.0, 0.0, 50.4], 'lt614br', camera=0)\n"
                   + "_c.set('metal_interior_cap', 1, 'lt614br')\n")
        let aim = camera.project(SIMD3(0.03, 0.02, 51.9), aspect: sceneAspect).0
        let capped = try XCTUnwrap(pick(SIMD2(Float(aim.x), Float(aim.y)), true),
                                   "no interior cap down the open bond")
        XCTAssertTrue(capped.cap)
        XCTAssertEqual(capped.depth, 50, accuracy: 1e-2)

        // TTT single-strand DNA, cartoon_ring_mode 4: the middle base's ring
        // sphere (radius 1.5) centred on the near plane, that base at
        // per-atom cartoon_transparency 0.5 (the object's stays 0). (No
        // numpy in the app: iterate_state, not get_coords.)
        let dna = python(
            "_c.disable('lt614br')\n"
            + "_c.fnab('TTT', name='lt614dna', mode='DNA', form='B', dbl_helix=0)\n"
            + "_c.show_as('cartoon', 'lt614dna')\n"
            + "_c.set('cartoon_ring_mode', 4, 'lt614dna')\n"
            + "_c.set('cartoon_ring_radius', 1.5, 'lt614dna')\n"
            + "_r = []\n"
            + "_c.iterate_state(1, 'lt614dna and resi 2 and name N1+C2+N3+C4+C5+C6',\n"
            + "                 '_r.append((x, y, z))', space={'_r': _r})\n"
            + "_m = [sum(p[k] for p in _r) / len(_r) for k in range(3)]\n"
            + "_c.translate([-_m[0], -_m[1], 50.0 - _m[2]], 'lt614dna', camera=0)\n"
            + "_c.set('cartoon_transparency', 0.5, 'lt614dna and resi 2')\n"
            + "_c.set('transparency_mode', 2)\n"
            + "_c.set_view(\(Self.pinnedView))\n"
            + "_out['object_transparency'] = _c.get_setting_float('cartoon_transparency', 'lt614dna')\n")
        XCTAssertEqual(dna["object_transparency"] as? Double, 0, "setup failed: \(dna)")

        // Before any frame: nothing has recorded the per-atom transparency,
        // so the sphere is an impostor, see-through where the plane cuts it.
        XCTAssertNil(pick(SIMD2(0, 0), true), "the cut impostor sphere was picked")

        // A frame: RepCartoonCGOGenerate sees the per-atom transparency and
        // tessellates the spheres, so the cut sphere shows its far wall.
        _ = try XCTUnwrap(renderFrame(width: 64, height: 48), "no frame rendered")
        let tessellated = try XCTUnwrap(pick(SIMD2(0, 0), false),
                                        "the frame's tessellated sphere was not picked")
        XCTAssertTrue(tessellated.inside)
        XCTAssertEqual(tessellated.depth, 51.5, accuracy: 1e-2)

        // transparency_mode 3 would have kept impostors, but the frame has
        // decided: cartoons are not rebuilt, so the pick keeps the far wall.
        _ = python("_c.set('transparency_mode', 3)\n")
        let kept = try XCTUnwrap(pick(SIMD2(0, 0), true),
                                 "the pick followed transparency_mode, not the drawn spheres")
        XCTAssertEqual(kept, tessellated)

        print("SurfacePickTests live geometry: junction axis depth \(axis.depth), "
              + "near-plane cap \(capped.cap) at \(capped.depth); ring sphere before frame nil, "
              + "after frame inside \(tessellated.inside) at \(tessellated.depth), "
              + "after transparency_mode 3 \(kept.depth)")
    }
}
