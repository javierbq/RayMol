import XCTest
import Combine
import CoreGraphics
import ImageIO
import simd
@testable import RayMol

// The light gizmo (#622) against the LIVE engine. Every press and drag tick
// goes through LightGizmoInteraction with the layout the engine builds
// (`lightGizmoLayout(viewSize:)`) and the engine's picker
// (`lightGizmoPicker`: prepare and pick with updateReps: false), as the
// overlay, the viewport and the DEBUG gestures do. So:
// - the Swift projection lands a core SurfacePick hit back on the view point
//   it was picked at (perspective, orthoscopic, letterbox);
// - each knob sits along the direction the core's resolver puts its light
//   in, and a dragged knob lands under the pointer again (1° rounding);
// - a knob tick is at most two bridge setters, one redraw request each, and
//   no Python or console command (#610);
// - the band turns key into rim in one drag, released outside the disc;
// - a ring drag keeps its ring under the pointer (oblique rings included),
//   the radius stays; scroll and pinch keep the beam; the aim dot aims at
//   the picked point; an option-click runs one `lights` command;
// - the gizmo, the inspector and the orbit view mirror each other;
// - the gizmo adds nothing to the scene and is never in the Metal frame.
//
// The same rules are tested on fakes in LightGizmoTests.swift; the core's own
// semantics (behind rule, knob writes, aim_point, click=/rim=/pin=, the ring
// cone) in CI by testing/tests/raymol/lighting_gizmo.py.

@MainActor
final class LightGizmoLiveTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }
    private var interaction: LightGizmoInteraction {
        LightGizmoInteraction(controller: controller, picker: engine.lightGizmoPicker)
    }

    private final class Lines { var lines: [String] = [] }
    private struct Missing: Error, CustomStringConvertible { let description: String }
    /// Counts notifications; touched on the main thread only.
    private final class PostCounter: @unchecked Sendable { var count = 0 }

    /// The pinned camera of SurfacePickTests and lighting_pick.py: identity
    /// rotation, the eye at z = +100 looking down -z at the origin, slab
    /// [50, 150], perspective with field_of_view 20. The peptide is moved to
    /// the origin, where the rig's centre is.
    private static let pinnedView =
        "(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, "
        + "0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 50.0, 150.0, -20.0)"

    /// The view the gizmo is laid out in: 600 points tall at the core's scene
    /// aspect, so a view point picks what the core draws there.
    private var viewSize = CGSize(width: 800, height: 600)
    private var sceneBuilt = false
    private var letterboxSet = false

    override func setUp() {
        super.setUp()
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        engine.setBinderDesignMode(false)
    }

    override func tearDown() {
        if letterboxSet {
            engine.setLetterboxAspect(0)
            letterboxSet = false
        }
        if sceneBuilt {
            engine.setInteractionMode(.viewing)
            engine.runPython(
                "from pymol import cmd as _lgz_c\n"
                + "for _k, _v in globals().pop('_lgz_saved', {}).items():\n"
                + "    _lgz_c.set(_k, _v)\n"
                + "for _n in globals().pop('_lgz_enabled', []):\n"
                + "    _lgz_c.enable(_n)\n")
            sceneBuilt = false
        }
        LightsLive.tearDown()
        super.tearDown()
    }

    // MARK: the scene

    /// Run `body` in the live interpreter with `_c` (pymol.cmd) and an `_out`
    /// dict in scope; `_out` read back as JSON (empty when the code raised).
    @discardableResult
    private func python(_ body: String) -> [String: Any] {
        let path = NSTemporaryDirectory() + "lgz_live_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.runPython(
            "import json as _lgz_json\n"
            + "from pymol import cmd as _c\n"
            + "_out = {}\n"
            + body + "\n"
            + "open(r'\(path)', 'w').write(_lgz_json.dumps(_out))\n")
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return [:] }
        return dict
    }

    /// A six-residue peptide as spheres, centred on the origin, every other
    /// enabled object hidden, the pinned camera, `rig` set (default: the
    /// three-light fixture, centre at the origin: key a camera light with a
    /// shadow at orbit 12.5, pitch 3, radius 2; fill aimed at a point; rim
    /// pinned at (5, 6, -30), so behind the molecule), and the pick grids
    /// built once (outside any tap).
    private func buildScene(rig: String? = nil) throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        sceneBuilt = true
        let setup = python(
            "if '_lgz_saved' not in globals():\n"
            + "    _lgz_saved = {_k: _c.get(_k) for _k in ('orthoscopic', 'field_of_view',\n"
            + "                                            'metal_shadows', 'metal_raytrace')}\n"
            + "    _lgz_enabled = [_n for _n in _c.get_names('objects', enabled_only=1) if _n != 'lmt_pep']\n"
            + "for _n in _lgz_enabled:\n"
            + "    _c.disable(_n)\n"
            + "_c.show_as('spheres', 'lmt_pep')\n"
            + "_e = _c.get_extent('lmt_pep')\n"
            + "_c.translate([-(_e[0][i] + _e[1][i]) / 2.0 for i in range(3)],\n"
            + "             selection='lmt_pep', camera=0)\n"
            + "_c.set('orthoscopic', 0)\n"
            + "_c.set_view(\(Self.pinnedView))\n"
            + "_out['viewport'] = list(_c.get_viewport(output=0))\n")
        let viewport = try XCTUnwrap(setup["viewport"] as? [Double], "the scene setup failed: \(setup)")
        XCTAssertEqual(viewport.count, 2)
        XCTAssertGreaterThan(viewport[0], 0)
        XCTAssertGreaterThan(viewport[1], 0)
        viewSize = CGSize(width: 600 * viewport[0] / viewport[1], height: 600)
        _ = try XCTUnwrap(LightsLive.setRig(rig ?? LightsLive.threeLights(enabled: true)))
        XCTAssertGreaterThan(engine.prepareSurfacePick(updateReps: true), 0, "no pick grid was built")
    }

    /// Lights mode entered with `name` selected and a frame's eye read.
    private func enter(selecting name: String = "key") {
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.eyeDemand, .everyFrame, "the gizmo shows: every frame's eye space")
        controller.select(name: name)
        XCTAssertEqual(controller.selection.name, name)
        engine.lightsFrameRendered()
    }

    private func enterGizmo(selecting name: String = "key", rig: String? = nil) throws {
        try buildScene(rig: rig)
        enter(selecting: name)
    }

    // MARK: reads

    /// The gizmo as the engine lays it out now.
    private func layout(_ size: CGSize? = nil, file: StaticString = #filePath,
                        line: UInt = #line) throws -> LightGizmoLayout {
        try XCTUnwrap(engine.lightGizmoLayout(viewSize: size ?? viewSize), "the gizmo is hidden",
                      file: file, line: line)
    }

    private func projection(_ size: CGSize? = nil, file: StaticString = #filePath,
                            line: UInt = #line) throws -> LightGizmoProjection {
        let camera = try XCTUnwrap(engine.lightCameraProjection(), "no camera", file: file, line: line)
        return try XCTUnwrap(LightGizmoProjection(camera: camera, viewSize: size ?? viewSize),
                             file: file, line: line)
    }

    private func coreRig(file: StaticString = #filePath, line: UInt = #line) throws -> LightRigSnapshot {
        try XCTUnwrap(engine.lightRig(), "no rig", file: file, line: line)
    }

    private func coreEyeSpace(file: StaticString = #filePath, line: UInt = #line) throws -> LightEyeSpace {
        try XCTUnwrap(engine.lightsEyeSpace(), "no eye space", file: file, line: line)
    }

    /// World to eye with the live 25-float view (PyMOLBridge_GetView):
    /// eye = R (p - origin) + pos, R column-major.
    private struct LiveCamera {
        let rot: [Double]
        let pos: SIMD3<Double>
        let origin: SIMD3<Double>

        init?(view: [Float]) {
            guard view.count == 25 else { return nil }
            rot = view[0..<16].map(Double.init)
            pos = SIMD3(Double(view[16]), Double(view[17]), Double(view[18]))
            origin = SIMD3(Double(view[19]), Double(view[20]), Double(view[21]))
        }

        func eye(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = p - origin
            return SIMD3(rot[0] * d.x + rot[4] * d.y + rot[8] * d.z,
                         rot[1] * d.x + rot[5] * d.y + rot[9] * d.z,
                         rot[2] * d.x + rot[6] * d.y + rot[10] * d.z) + pos
        }
    }

    private func camera(file: StaticString = #filePath, line: UInt = #line) throws -> LiveCamera {
        try XCTUnwrap(engine.captureView().flatMap(LiveCamera.init(view:)), "no view", file: file, line: line)
    }

    /// The core's surface pick at a view point of `projection`'s view, as
    /// the gizmo's picker asks for it (updateReps: false).
    private func corePick(_ p: CGPoint, _ projection: LightGizmoProjection) -> SurfacePick? {
        let ndc = projection.viewNDC(point: p)
        let size = projection.viewSize
        return engine.pickSurface(viewNDCX: Float(ndc.x), viewNDCY: Float(ndc.y),
                                  viewAspect: Float(size.width / size.height), updateReps: false)
    }

    /// World coordinates of `selection`'s first atom.
    private func atom(_ selection: String, file: StaticString = #filePath,
                      line: UInt = #line) throws -> SIMD3<Double> {
        let atoms = try coordinates(selection, file: file, line: line)
        let xyz = try XCTUnwrap(atoms.first, "no atom \(selection)", file: file, line: line)
        return SIMD3(xyz[0], xyz[1], xyz[2])
    }

    /// World coordinates of every atom of `selection` (state 1).
    private func coordinates(_ selection: String, file: StaticString = #filePath,
                             line: UInt = #line) throws -> [[Double]] {
        let out = python(
            "_lgz_xyz = []\n"
            + "_c.iterate_state(1, '\(selection)', '_lgz_xyz.append([float(x), float(y), float(z)])',\n"
            + "                 space={'_lgz_xyz': _lgz_xyz})\n"
            + "_out['xyz'] = _lgz_xyz\n")
        let atoms = try XCTUnwrap(out["xyz"] as? [[Double]], "no coordinates for \(selection): \(out)",
                                  file: file, line: line)
        XCTAssertTrue(atoms.allSatisfy { $0.count == 3 }, file: file, line: line)
        return atoms
    }

    /// The scene facts the gizmo must never change: every name, the whole
    /// extent and what the shadow maps are drawn from.
    private func sceneFacts() -> NSDictionary {
        NSDictionary(dictionary: python(
            "from pymol import lighting as _lgz_l\n"
            + "_out['names'] = _c.get_names('all')\n"
            + "_out['extent'] = _c.get_extent()\n"
            + "_out['casters'] = _lgz_l._light_shadow_casters()\n"))
    }

    private func double3(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func assertPoint(_ got: CGPoint?, _ want: CGPoint, accuracy: CGFloat, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let got else { return XCTFail("no point (\(message))", file: file, line: line) }
        XCTAssertLessThanOrEqual(dist(got, want), accuracy, "\(got) vs \(want) \(message)",
                                 file: file, line: line)
    }

    /// Install the taps; returns what they saw once `stop` is called.
    private func tap() -> (python: Lines, commands: Lines, stop: () -> Void) {
        let python = Lines(), commands = Lines()
        let engine = self.engine
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        return (python, commands, {
            engine.pythonTap = nil
            engine.commandTap = nil
        })
    }

    /// Drag `session` along the straight line to `to` in `steps` ticks; the
    /// results of the ticks that wrote.
    @discardableResult
    private func drag(_ session: inout LightGizmoDragSession, from: CGPoint, to: CGPoint, steps: Int = 12,
                      on i: LightGizmoInteraction? = nil) -> [LightSetResult] {
        let i = i ?? interaction
        var results: [LightSetResult] = []
        for k in 1...steps {
            if let r = i.move(&session, to: lerp(from, to, CGFloat(k) / CGFloat(steps))) { results.append(r) }
        }
        return results
    }

    /// A ring sample the hit test gives to `target`, as far as possible from
    /// every point target.
    private func clearPoint(on ring: LightGizmoLayout.Ring, _ target: LightGizmoTarget,
                            in l: LightGizmoLayout) -> CGPoint? {
        let bounds = CGRect(origin: .zero, size: l.projection.viewSize).insetBy(dx: 10, dy: 10)
        var best: (point: CGPoint, clearance: CGFloat)?
        for case let p? in ring.samples where bounds.contains(p) {
            guard LightGizmoHitTest.target(at: p, layout: l) == target else { continue }
            var clearance = l.knobs.map { dist(p, $0.centre) - $0.radius }.min() ?? .infinity
            if let s = l.selected {
                for q in [s.aimDot, s.outerHandle?.point, s.innerHandle?.point].compactMap({ $0 }) {
                    clearance = min(clearance, dist(p, q))
                }
            }
            if best == nil || clearance > best!.clearance { best = (p, clearance) }
        }
        return best?.point
    }

    /// A view point over the peptide (an atom's projection) that is no gizmo
    /// target in `l` and whose pick faces the camera: what an option-click
    /// on the molecule hits.
    private func clickablePoint(in l: LightGizmoLayout, file: StaticString = #filePath,
                                line: UInt = #line) throws -> CGPoint {
        let atoms = try coordinates("lmt_pep", file: file, line: line)
        let cam = try camera(file: file, line: line)
        for a in atoms where a.count == 3 {
            guard let p = l.projection.point(eye: cam.eye(SIMD3(a[0], a[1], a[2]))),
                  LightGizmoHitTest.target(at: p, layout: l) == nil,
                  let hit = corePick(p, l.projection), hit.facing >= 0.5 else { continue }
            return p
        }
        XCTFail("no atom of the peptide is clear of the gizmo", file: file, line: line)
        throw Missing(description: "no clickable point")
    }

    /// Near the peptide's outline: scanning out from `start` in 0.5 pt steps,
    /// the first hit that grazes (facing under 0.3) and is no gizmo target,
    /// so a little inside the edge.
    private func grazingPoint(from start: CGPoint, in l: LightGizmoLayout, file: StaticString = #filePath,
                              line: UInt = #line) throws -> CGPoint {
        let directions = [CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0),
                          CGVector(dx: 0, dy: 1), CGVector(dx: 0.7071, dy: 0.7071), CGVector(dx: -0.7071, dy: -0.7071)]
        for direction in directions {
            for k in 1...800 {
                let p = CGPoint(x: start.x + direction.dx * CGFloat(k) * 0.5,
                                y: start.y + direction.dy * CGFloat(k) * 0.5)
                guard let hit = corePick(p, l.projection) else { break }
                if hit.facing < LightGizmoMetrics.rimFacing, LightGizmoHitTest.target(at: p, layout: l) == nil {
                    return p
                }
            }
        }
        XCTFail("no grazing hit near the peptide's outline", file: file, line: line)
        throw Missing(description: "no grazing point")
    }

    /// RGBA8 pixels of a PNG, top row first.
    private func pngPixels(_ path: String) -> [UInt8]? {
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
        return drawn ? rgba : nil
    }

    /// An offscreen Metal frame of the scene (`renderHiResPNG`), 320 x 240.
    /// With `RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR` set (TEST_RUNNER_ prefix through
    /// xcodebuild), a copy is kept there as `<keep>.png` for evidence.
    private func renderFrame(rayTraced: Int, keep: String? = nil, file: StaticString = #filePath,
                             line: UInt = #line) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "lgz_live_\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 320, height: 240, rayTraced: rayTraced)
        if let keep, let dir = ProcessInfo.processInfo.environment["RAYMOL_LIGHTGIZMO_SNAPSHOT_DIR"],
           !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let copy = (dir as NSString).appendingPathComponent(keep + ".png")
            try? FileManager.default.removeItem(atPath: copy)
            try? FileManager.default.copyItem(atPath: png, toPath: copy)
        }
        return try XCTUnwrap(pngPixels(png), "no frame rendered (is there a Metal renderer?)",
                             file: file, line: line)
    }

    /// How many different RGBA values a frame holds (a blank frame has one).
    private func colourCount(_ rgba: [UInt8]) -> Int {
        var seen = Set<UInt32>()
        var i = 0
        while i + 3 < rgba.count {
            seen.insert(UInt32(rgba[i]) << 24 | UInt32(rgba[i + 1]) << 16 | UInt32(rgba[i + 2]) << 8
                        | UInt32(rgba[i + 3]))
            i += 4
        }
        return seen.count
    }

    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return 256 }
        return zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    // MARK: the projection is the core's

    /// A core SurfacePick hit, taken to eye space with the live view and
    /// projected with the gizmo's projection, lands on the view point it was
    /// picked at (0.5 pt): perspective, orthoscopic, and a letterbox with bars
    /// left and right or top and bottom.
    func testProjectionMatchesTheCorePick() throws {
        try enterGizmo()
        let aspect = viewSize.width / viewSize.height

        try assertPicksProjectBack("perspective", size: viewSize)

        python("_c.set('orthoscopic', 1)\n")
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.projection?.orthoscopic, true, "the orthoscopic camera is published")
        try assertPicksProjectBack("orthoscopic", size: viewSize)
        python("_c.set('orthoscopic', 0)\n")

        // The letterbox at the scene's own aspect (so the core's viewport,
        // which only a live frame reshapes, stays right), in views wider and
        // taller than it.
        engine.setLetterboxAspect(Float(aspect))
        letterboxSet = true
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.projection?.letterboxAspect ?? 0, Double(Float(aspect)), accuracy: 1e-9)
        let wide = CGSize(width: 2 * viewSize.width, height: viewSize.height)
        try assertPicksProjectBack("letterbox, bars left and right", size: wide)
        try assertPicksProjectBack("letterbox, bars top and bottom",
                                   size: CGSize(width: viewSize.width, height: 2 * viewSize.height))
        let bar = CGPoint(x: 4, y: wide.height / 2)
        XCTAssertNil(try projection(wide).sceneNDC(point: bar), "a bar is outside the scene")
        XCTAssertNil(corePick(bar, try projection(wide)), "nothing is picked in a bar")
    }

    private func assertPicksProjectBack(_ name: String, size: CGSize,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let proj = try projection(size, file: file, line: line)
        let l = try layout(size, file: file, line: line)
        XCTAssertEqual(l.projection, proj, "\(name): the layout uses the published camera", file: file, line: line)
        let cam = try camera(file: file, line: line)
        let picker = engine.lightGizmoPicker

        // A 7 x 7 grid over the central 80% of the peptide's projected box.
        let out = python("_out['extent'] = _c.get_extent('lmt_pep')\n")
        let extent = try XCTUnwrap(out["extent"] as? [[Double]], file: file, line: line)
        var corners: [CGPoint] = []
        for x in [extent[0][0], extent[1][0]] {
            for y in [extent[0][1], extent[1][1]] {
                for z in [extent[0][2], extent[1][2]] {
                    corners += [proj.point(eye: cam.eye(SIMD3(x, y, z)))].compactMap { $0 }
                }
            }
        }
        XCTAssertEqual(corners.count, 8, file: file, line: line)
        let lo = CGPoint(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!)
        let hi = CGPoint(x: corners.map(\.x).max()!, y: corners.map(\.y).max()!)
        var hits = 0
        var worst: CGFloat = 0
        for i in 0..<7 {
            for j in 0..<7 {
                let p = CGPoint(x: lo.x + (hi.x - lo.x) * (0.1 + 0.8 * CGFloat(i) / 6),
                                y: lo.y + (hi.y - lo.y) * (0.1 + 0.8 * CGFloat(j) / 6))
                guard let hit = corePick(p, proj) else { continue }
                hits += 1
                let ndc = proj.viewNDC(point: p)
                XCTAssertEqual(picker.pick(SIMD2(Float(ndc.x), Float(ndc.y)),
                                           Float(size.width / size.height)), hit,
                               "\(name): the gizmo's picker is the core's pick", file: file, line: line)
                let e = cam.eye(double3(hit.point))
                XCTAssertEqual(-e.z, Double(hit.depth), accuracy: 1e-2, "\(name): depth", file: file, line: line)
                let q = try XCTUnwrap(proj.point(eye: e), "\(name): \(hit.point) does not project",
                                      file: file, line: line)
                worst = max(worst, dist(p, q))
                XCTAssertLessThanOrEqual(dist(p, q), 0.5, "\(name): picked at \(p), projects to \(q)",
                                         file: file, line: line)
            }
        }
        print("LightGizmoLiveTests: \(name): \(hits) hits, worst \(worst) pt")
        XCTAssertGreaterThanOrEqual(hits, 10, "\(name): too few hits on the peptide", file: file, line: line)
    }

    // MARK: knobs

    /// Each knob is the direction the core's resolver puts its light in
    /// (eye space, from the rig centre), filled or hollow by the same rule;
    /// a dragged knob lands under the pointer again, within the 1° rounding,
    /// for a front camera light and a pinned light behind, with a grab offset.
    func testKnobsAreTheResolversDirections() throws {
        try enterGizmo()
        let l = try layout()
        let eye = try coreEyeSpace()
        XCTAssertEqual(controller.eye.eyeSpace, eye, "the published eye space is the core's")
        XCTAssertEqual(controller.eye.projection, engine.lightCameraProjection())
        assertPoint(l.centre, try XCTUnwrap(try projection().point(eye: eye.centre)), accuracy: 1e-6,
                    "the sphere is centred on the rig centre")
        XCTAssertEqual(l.knobs.map(\.name), ["key", "fill", "rim"])
        for (i, knob) in l.knobs.enumerated() {
            let d = simd_normalize(double3(eye.lights[i].position - eye.centre))
            XCTAssertLessThan(simd_distance(knob.direction, d), 1e-4, "\(knob.name): \(knob.direction) vs \(d)")
            XCTAssertEqual(knob.isBehind, d.z < -LightDepth.tolerance, knob.name)
            assertPoint(knob.centre, CGPoint(x: l.centre.x + l.sphereRadius * CGFloat(d.x),
                                             y: l.centre.y - l.sphereRadius * CGFloat(d.y)),
                        accuracy: 0.05, knob.name)
            XCTAssertEqual(knob.slot, controller.identitySlot(for: knob.name), knob.name)
            XCTAssertEqual(knob.isBehind, controller.isBehind(knob.name), "\(knob.name): knob and chip agree")
        }
        XCTAssertEqual(l.knobs.map(\.isBehind), [false, false, true], "rim is behind the molecule")
        let selected = try XCTUnwrap(l.selected)
        XCTAssertEqual(selected.name, "key")
        assertPoint(selected.aimDot, try XCTUnwrap(l.projection.point(eye: eye.lights[0].target)),
                    accuracy: 1e-6, "the aim dot is the eye-space target")

        // Drags, pressed off the knob's centre (a grab offset).
        let moves: [(String, CGFloat, CGFloat)] = [("key", 0.35, -0.45), ("rim", -0.3, 0.25)]
        for (name, fx, fy) in moves {
            let before = try layout()
            let knob = try XCTUnwrap(before.knob(named: name))
            let press = CGPoint(x: knob.centre.x + 2, y: knob.centre.y - 1.5)
            var session = try XCTUnwrap(interaction.press(at: press, layout: before), name)
            XCTAssertEqual(session.target, .knob(name))
            XCTAssertEqual(controller.selection.name, name, "a press on a knob selects its light")
            let to = CGPoint(x: before.centre.x + before.sphereRadius * fx,
                             y: before.centre.y + before.sphereRadius * fy)
            let results = drag(&session, from: press, to: to)
            XCTAssertFalse(results.isEmpty, name)
            XCTAssertTrue(results.allSatisfy { $0 == .ok }, name)
            let after = try layout()
            let moved = try XCTUnwrap(after.knob(named: name))
            let want = CGPoint(x: to.x + knob.centre.x - press.x, y: to.y + knob.centre.y - press.y)
            XCTAssertLessThanOrEqual(dist(moved.centre, want), after.sphereRadius * .pi / 180,
                                     "\(name): the knob lands under the pointer (1° rounding)")
            XCTAssertEqual(moved.isBehind, knob.isBehind, "\(name) stays on its side inside the disc")
            let now = try coreEyeSpace()
            let index = moved.index
            let d = simd_normalize(double3(now.lights[index].position - now.centre))
            XCTAssertLessThan(simd_distance(moved.direction, d), 1e-4, "\(name): the resolver agrees")
            XCTAssertEqual(now.lights[index].anchor, eye.lights[index].anchor, "\(name): the anchor is kept")
        }
    }

    /// Sixty knob ticks: each is at most two bridge setters (pitch then
    /// orbit), one redraw request per write, the core's eye space changed and
    /// republished in the same main-thread turn, and no Python or console
    /// command. Counted on a second controller on the live bridge; then the
    /// same without Python on the engine's own controller for the pinned rim.
    func testKnobDragWritesEveryTickWithNoPython() throws {
        try enterGizmo()
        final class Spy {
            var numberWrites: [(index: Int, field: String, value: Double)] = []
            var vectorWrites = 0
            var performed: [LightsAction] = []
        }
        let spy = Spy()
        let engine = self.engine
        let c = LightsController(seams: LightsSeams(
            rigJSON: { engine.lightRigJSON() },
            setNumber: { index, field, value in
                spy.numberWrites.append((index, field, value))
                return engine.setLight(index, field, value)
            },
            setVector: { index, field, vector in
                spy.vectorWrites += 1
                return engine.setLight(index, field, vector)
            },
            perform: { spy.performed.append($0) },
            loadPresets: { [] },
            isReady: { engine.isReady },
            isBusy: { false },
            now: { ProcessInfo.processInfo.systemUptime },
            eyeSpace: { engine.lightsEyeSpace() },
            projection: { engine.lightCameraProjection() }))
        c.eyeDemand = .everyFrame
        c.begin()
        defer {
            c.end()
            c.eyeDemand = .pinnedOnly
        }
        c.select(name: "key")
        let l = try XCTUnwrap(LightGizmoLayout.make(LightGizmoInputs(
            controller: c, viewSize: viewSize, gridMode: false, sceneShadowsOn: nil)))
        let knob = try XCTUnwrap(l.knob(named: "key"))
        let gizmo = LightGizmoInteraction(controller: c)

        let posts = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: PyMOLEngine.forceRedrawNotification, object: nil, queue: nil) { _ in posts.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let taps = tap()
        var session = try XCTUnwrap(gizmo.press(at: knob.centre, layout: l))
        let start = atan2(-Double(knob.centre.y - l.centre.y), Double(knob.centre.x - l.centre.x))
        var written = 0
        for k in 1...60 {
            let theta = start + Double(k) * 6 * .pi / 180
            let p = CGPoint(x: l.centre.x + 0.6 * l.sphereRadius * CGFloat(cos(theta)),
                            y: l.centre.y - 0.6 * l.sphereRadius * CGFloat(sin(theta)))
            let writes0 = spy.numberWrites.count, posts0 = posts.count
            let eyeBefore = engine.lightsEyeSpace()
            let result = gizmo.move(&session, to: p)
            let writes = spy.numberWrites.count - writes0
            XCTAssertLessThanOrEqual(writes, 2, "tick \(k)")
            XCTAssertEqual(posts.count - posts0, writes, "tick \(k): one redraw request per bridge write")
            if result == .ok {
                written += 1
                XCTAssertGreaterThan(writes, 0, "tick \(k)")
                let fields = spy.numberWrites.suffix(writes).map(\.field)
                XCTAssertTrue(fields == ["pitch", "orbit"] || fields == ["pitch"] || fields == ["orbit"],
                              "tick \(k): \(fields)")
                let now = engine.lightsEyeSpace()
                XCTAssertNotEqual(now, eyeBefore, "tick \(k): the core's eye space did not change")
                XCTAssertEqual(c.eye.eyeSpace, now, "tick \(k): republished in the same turn")
                XCTAssertEqual(c.eye.projection, engine.lightCameraProjection(), "tick \(k)")
                XCTAssertEqual(c.rig, engine.lightRig(), "tick \(k): the mirror is the core's")
            } else {
                XCTAssertNil(result, "tick \(k)")
                XCTAssertEqual(writes, 0, "tick \(k)")
            }
        }
        taps.stop()
        XCTAssertGreaterThanOrEqual(written, 55, "\(written) of 60 ticks wrote")
        XCTAssertEqual(spy.vectorWrites, 0)
        XCTAssertTrue(spy.performed.isEmpty)
        XCTAssertEqual(taps.python.lines, [], "a knob tick must run no Python (#610)")
        XCTAssertEqual(taps.commands.lines, [], "a knob tick must run no console command")

        // The engine's own controller, the pinned rim (a re-pin per tick).
        controller.refresh()
        let rl = try layout()
        let rim = try XCTUnwrap(rl.knob(named: "rim"))
        let rimTaps = tap()
        let posts0 = posts.count
        var rimSession = try XCTUnwrap(interaction.press(at: rim.centre, layout: rl))
        let results = drag(&rimSession, from: rim.centre,
                           to: CGPoint(x: rl.centre.x - 0.5 * rl.sphereRadius, y: rl.centre.y + 0.3 * rl.sphereRadius),
                           steps: 24)
        rimTaps.stop()
        XCTAssertGreaterThan(results.count, 10)
        XCTAssertTrue(results.allSatisfy { $0 == .ok })
        XCTAssertGreaterThanOrEqual(posts.count - posts0, results.count, "every write asked for a frame")
        XCTAssertEqual(rimTaps.python.lines, [])
        XCTAssertEqual(rimTaps.commands.lines, [])
        XCTAssertEqual(try coreRig().lights[2].anchor, .pinned, "the drag keeps rim pinned")
        XCTAssertTrue(controller.isBehind("rim"), "a drag inside the disc keeps its side")
    }

    /// Key dragged out past the band and released outside the disc is behind
    /// the molecule: in the core, in `facing`, on the bar's chip and on the
    /// knob, at once.
    func testKeyBecomesRimInOneDrag() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        XCTAssertFalse(key.isBehind)
        let taps = tap()
        var session = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        let v = CGVector(dx: key.centre.x - l.centre.x, dy: key.centre.y - l.centre.y)
        let length = hypot(v.dx, v.dy)
        XCTAssertGreaterThan(length, 1)
        let out = CGPoint(x: l.centre.x + v.dx / length * (l.bandRadius + 10),
                          y: l.centre.y + v.dy / length * (l.bandRadius + 10))
        let results = drag(&session, from: key.centre, to: out)
        taps.stop()
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0 == .ok })
        XCTAssertEqual(session.isBehind, true, "the band flipped the knob")
        XCTAssertTrue(session.isOutside, "released outside the disc")
        XCTAssertEqual(taps.python.lines, [])
        XCTAssertEqual(taps.commands.lines, [])

        let light = try coreRig().lights[0]
        XCTAssertTrue(LightDepth.isBehind(orbit: light.orbit, pitch: light.pitch),
                      "the core holds a light behind: orbit \(light.orbit), pitch \(light.pitch)")
        XCTAssertGreaterThanOrEqual(abs(light.orbit), 92, "2° off the outline")
        let eye = try coreEyeSpace()
        XCTAssertLessThan(eye.lights[0].position.z - eye.centre.z, 0, "behind the centre in eye depth")
        XCTAssertTrue(controller.isBehind("key"), "facing")
        XCTAssertEqual(LightsBarState(controller).chips.first { $0.name == "key" }?.isBehind, true, "the chip")
        XCTAssertEqual(try layout().knob(named: "key")?.isBehind, true, "the knob")
        XCTAssertEqual(LightGizmoState(controller)?.behind.contains("key"), true, "VoiceOver")
        XCTAssertEqual(light.anchor, .camera)
    }

    // MARK: rings, radius, aim

    /// An outer-ring drag on an oblique ring sets the beam so that the
    /// redrawn ring passes under the pointer (to the 0.5° rounding); an
    /// inner-ring drag does the same for the softness. Neither touches the
    /// radius, the placement or the other ring's value.
    func testRingDragKeepsTheRingUnderThePointer() throws {
        try enterGizmo()
        XCTAssertEqual(controller.setPlacement(orbit: 55, pitch: 30), .ok)
        XCTAssertEqual(controller.set(.beam, 40), .ok)
        XCTAssertEqual(controller.set(.softness, 0.3), .ok)
        let entry = try coreRig().lights[0]
        let l = try layout()
        let s0 = try XCTUnwrap(l.selected)
        XCTAssertLessThan(abs(s0.direction.z), 0.9, "an oblique ring")
        let aim = try XCTUnwrap(s0.aimDot)

        let taps = tap()
        // Outer: outwards from the aim dot.
        let outerPress = try XCTUnwrap(clearPoint(on: try XCTUnwrap(s0.outerRing), .outerRing, in: l),
                                       "no clear point on the outer ring")
        var outer = try XCTUnwrap(interaction.press(at: outerPress, layout: l))
        XCTAssertEqual(outer.mode, .outer)
        XCTAssertEqual(outer.measure?.usesAimPlane, true, "measured on the aim plane")
        let outerTo = lerp(aim, outerPress, 1.3)
        let outerResults = drag(&outer, from: outerPress, to: outerTo)
        let outerWanted = try XCTUnwrap(outer.ringRadius(at: outerTo))
        XCTAssertFalse(outerResults.isEmpty)
        XCTAssertTrue(outerResults.allSatisfy { $0 == .ok })

        let l1 = try layout()
        let s1 = try XCTUnwrap(l1.selected)
        XCTAssertGreaterThan(s1.beam, 40)
        XCTAssertEqual(s1.softness, 0.3, "an outer drag keeps the softness")
        try assertRingUnderPointer(outerTo, wanted: outerWanted, ring: try XCTUnwrap(s1.outerRing),
                                   alphaError: 0.25 * .pi / 180, selected: s1, layout: l1, "outer")

        // Inner: towards the aim dot.
        let innerPress = try XCTUnwrap(clearPoint(on: try XCTUnwrap(s1.innerRing), .innerRing, in: l1),
                                       "no clear point on the inner ring")
        var inner = try XCTUnwrap(interaction.press(at: innerPress, layout: l1))
        XCTAssertEqual(inner.mode, .inner)
        let innerTo = lerp(try XCTUnwrap(s1.aimDot), innerPress, 0.75)
        let innerResults = drag(&inner, from: innerPress, to: innerTo)
        let innerWanted = try XCTUnwrap(inner.ringRadius(at: innerTo))
        taps.stop()
        XCTAssertFalse(innerResults.isEmpty)
        XCTAssertTrue(innerResults.allSatisfy { $0 == .ok })

        let l2 = try layout()
        let s2 = try XCTUnwrap(l2.selected)
        XCTAssertGreaterThan(s2.softness, 0.3)
        XCTAssertEqual(s2.beam, s1.beam, "an inner drag keeps the beam")
        let half = acos(s2.cosOuter)
        try assertRingUnderPointer(innerTo, wanted: innerWanted, ring: try XCTUnwrap(s2.innerRing),
                                   alphaError: 0.005 * half, selected: s2, layout: l2, "inner")

        XCTAssertEqual(taps.python.lines, [], "a ring drag must run no Python")
        XCTAssertEqual(taps.commands.lines, [])
        let light = try coreRig().lights[0]
        XCTAssertEqual(light.radius, entry.radius, "the radius is unchanged")
        XCTAssertEqual(light.orbit, entry.orbit)
        XCTAssertEqual(light.pitch, entry.pitch)
        XCTAssertEqual(light.beam, s2.beam)
        XCTAssertEqual(light.softness, s2.softness)
    }

    /// The redrawn `ring` is the one the pointer at `p` measured (`wanted`
    /// Å), to the value's rounding (`alphaError` radians of cone angle), and
    /// passes under the pointer in view points.
    private func assertRingUnderPointer(_ p: CGPoint, wanted: Double, ring: LightGizmoLayout.Ring,
                                        alphaError: Double, selected s: LightGizmoLayout.Selected,
                                        layout l: LightGizmoLayout, _ name: String,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let alpha = atan2(wanted, s.aimDistance)
        let bound = s.aimDistance * abs(tan(alpha + alphaError) - tan(alpha)) + 1e-6
        XCTAssertEqual(ring.radius, wanted, accuracy: bound, "\(name): ring radius vs the pointer's",
                       file: file, line: line)
        let perAngstrom = try XCTUnwrap(l.projection.pointsPerAngstrom(atDepth: s.target.z),
                                        file: file, line: line)
        let nearest = try XCTUnwrap(LightGizmoHitTest.nearest(p, on: ring), file: file, line: line)
        XCTAssertLessThanOrEqual(nearest.distance, CGFloat(bound * perAngstrom * 1.25) + 0.5,
                                 "\(name): the ring is \(nearest.distance) pt from the pointer",
                                 file: file, line: line)
    }

    /// Wheel notches and a latched trackpad scroll on a knob step its radius
    /// on the 0.5× grid; a pinch on another knob selects it and sets its
    /// radius. The beam and the cone never change, nor do orbit and pitch;
    /// off a knob nothing starts. No Python.
    func testScrollAndPinchKeepTheBeam() throws {
        try enterGizmo()
        XCTAssertEqual(controller.set(.beam, 50), .ok)
        XCTAssertEqual(controller.set(.softness, 0.3), .ok)
        let before = try coreRig()
        let eyeBefore = try coreEyeSpace()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let fill = try XCTUnwrap(l.knob(named: "fill"))
        var expected = before.lights[0].radius
        func next(_ up: Bool) throws {
            expected = try XCTUnwrap(LightSnap.nextRadius(from: expected, up: up))
        }

        let taps = tap()
        XCTAssertEqual(interaction.scrollWheel(at: key.centre, up: true, layout: l), .ok)
        try next(true)
        XCTAssertEqual(try coreRig().lights[0].radius, expected, "wheel up: farther")
        XCTAssertEqual(interaction.scrollWheel(at: key.centre, up: true, layout: l), .ok)
        try next(true)
        XCTAssertEqual(interaction.scrollWheel(at: key.centre, up: false, layout: l), .ok)
        try next(false)
        XCTAssertEqual(try coreRig().lights[0].radius, expected)
        var scroll = try XCTUnwrap(interaction.beginScroll(at: key.centre, layout: l))
        var stepped: [LightSetResult] = []
        for _ in 0..<5 {
            if let r = interaction.scroll(&scroll, deltaY: 10) { stepped.append(r) }
        }
        XCTAssertEqual(stepped, [.ok, .ok], "50 pt of trackpad scroll is two 24 pt steps")
        try next(true)
        try next(true)
        XCTAssertEqual(try coreRig().lights[0].radius, expected)

        var pinch = try XCTUnwrap(interaction.beginPinch(at: fill.centre, layout: l))
        XCTAssertEqual(controller.selection.name, "fill", "a pinch on a knob selects its light")
        var pinched: [LightSetResult] = []
        for k in 1...12 {
            if let r = interaction.pinch(&pinch, magnification: 1 + Double(k) / 12) { pinched.append(r) }
        }
        XCTAssertNil(interaction.scrollWheel(at: CGPoint(x: 3, y: 3), up: true, layout: l), "off a knob")
        XCTAssertNil(interaction.beginScroll(at: CGPoint(x: 3, y: 3), layout: l))
        XCTAssertNil(interaction.beginPinch(at: CGPoint(x: 3, y: 3), layout: l))
        taps.stop()
        XCTAssertFalse(pinched.isEmpty)
        XCTAssertTrue(pinched.allSatisfy { $0 == .ok })
        XCTAssertEqual(taps.python.lines, [], "scroll and pinch run no Python")
        XCTAssertEqual(taps.commands.lines, [])

        let after = try coreRig()
        let eyeAfter = try coreEyeSpace()
        XCTAssertGreaterThan(after.lights[1].radius, before.lights[1].radius, "the pinch widened fill's radius")
        for i in 0..<2 {
            let name = after.lights[i].name
            XCTAssertEqual(after.lights[i].beam, before.lights[i].beam, "\(name): the beam is kept")
            XCTAssertEqual(after.lights[i].softness, before.lights[i].softness, name)
            XCTAssertEqual(after.lights[i].orbit, before.lights[i].orbit, name)
            XCTAssertEqual(after.lights[i].pitch, before.lights[i].pitch, name)
            XCTAssertEqual(eyeAfter.lights[i].cosOuter, eyeBefore.lights[i].cosOuter, accuracy: 1e-6, name)
            XCTAssertEqual(eyeAfter.lights[i].cosInner, eyeBefore.lights[i].cosInner, accuracy: 1e-6, name)
        }
        XCTAssertEqual(after.lights[2], before.lights[2], "rim untouched")
    }

    /// The aim dot dragged onto the peptide aims the light at the core's
    /// SurfacePick point there (`aim_point`), with no Python; the dot is then
    /// drawn under the pointer; over empty space a tick writes nothing.
    func testAimDragAimsAtThePickedPoint() throws {
        try enterGizmo()
        let l = try layout()
        let s = try XCTUnwrap(l.selected)
        let aim = try XCTUnwrap(s.aimDot)
        XCTAssertEqual(LightGizmoHitTest.target(at: aim, layout: l), .aimDot)
        let cam = try camera()
        let to = try XCTUnwrap(l.projection.point(eye: cam.eye(try atom("lmt_pep and resi 3 and name CA"))))
        let expected = try XCTUnwrap(corePick(to, l.projection), "nothing to pick at residue 3")
        let entry = try coreRig().lights[0]
        XCTAssertEqual(entry.aim, .centre)

        let taps = tap()
        var session = try XCTUnwrap(interaction.press(at: aim, layout: l))
        XCTAssertEqual(session.mode, .aim)
        let results = drag(&session, from: aim, to: to)
        let json = engine.lightRigJSON()
        let miss = interaction.move(&session, to: CGPoint(x: 3, y: 3))
        taps.stop()
        XCTAssertNil(miss, "an aim tick over empty space writes nothing")
        XCTAssertEqual(engine.lightRigJSON(), json, "the light keeps its last aim")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0 == .ok })
        XCTAssertEqual(taps.python.lines, [], "an aim drag must run no Python (updateReps: false)")
        XCTAssertEqual(taps.commands.lines, [])

        let key = try coreRig().lights[0]
        XCTAssertEqual(key.aim, .point)
        XCTAssertLessThan(simd_distance(key.aimPoint, double3(expected.point)), 1e-4,
                          "aim_point \(key.aimPoint) vs the pick \(expected.point)")
        XCTAssertEqual(key.aimSelection, "")
        XCTAssertEqual(key.orbit, entry.orbit)
        XCTAssertEqual(key.pitch, entry.pitch)
        XCTAssertEqual(key.radius, entry.radius)
        let target = double3(try coreEyeSpace().lights[0].target)
        XCTAssertLessThan(simd_distance(target, cam.eye(key.aimPoint)), 1e-3, "the eye target is the point")
        assertPoint(try layout().selected?.aimDot, to, accuracy: 0.5, "the dot is drawn under the pointer")
    }

    // MARK: option-click

    /// An option-click places a highlight with exactly one `lights` command:
    /// the mirror rule over the molecule (the light in front of the picked
    /// point), the rim rule near its outline (`rim=145`, behind it), and a
    /// pinned light keeps its pin (`pin=1`).
    func testAltClickPlacesAHighlight() throws {
        try enterGizmo()

        /// Option-click at a point over the peptide (near its outline for the
        /// rim rule) with `name` selected, and check the one command and what
        /// it did.
        func click(_ name: String, rim: Double?, pin: Bool) throws {
            let l = try layout()
            let inside = try clickablePoint(in: l)
            let p = try rim == nil ? inside : grazingPoint(from: inside, in: l)
            let ndc = try XCTUnwrap(l.projection.sceneNDC(point: p))
            let want = try XCTUnwrap(LightsAction.highlight(name: name, x: ndc.x, y: ndc.y, rim: rim, pin: pin)
                .invocation)
            guard case .command(let command) = want else { return XCTFail("not a command: \(want)") }
            let pick = try XCTUnwrap(corePick(p, l.projection))
            XCTAssertEqual(pick.facing < LightGizmoMetrics.rimFacing, rim != nil, "\(name): facing \(pick.facing)")

            let taps = tap()
            var pointer = LightGizmoPointer()
            XCTAssertEqual(pointer.press(at: p, option: true, layout: l, interaction: interaction),
                           .highlightCandidate, name)
            XCTAssertEqual(pointer.release(at: p, interaction: interaction), .gizmo, name)
            taps.stop()
            XCTAssertEqual(pointer.lastHighlight, .placed(rim: rim), name)
            XCTAssertEqual(taps.commands.lines, [command], "\(name): exactly one console command")

            let rig = try coreRig()
            let index = try XCTUnwrap(rig.lights.firstIndex { $0.name == name })
            let light = rig.lights[index]
            XCTAssertEqual(light.aim, .point, name)
            XCTAssertLessThan(simd_distance(light.aimPoint, double3(pick.point)), rim == nil ? 0.05 : 0.25,
                              "\(name): aimed at \(light.aimPoint), picked \(pick.point)")
            XCTAssertEqual(light.anchor, pin ? .pinned : .camera, "\(name): the anchor")
            XCTAssertEqual(controller.rig, rig, "the mirror follows the command")
            let eye = try coreEyeSpace().lights[index]
            if rim == nil {
                XCTAssertGreaterThan(eye.position.z, eye.target.z, "\(name): the mirror rule lights from the front")
            } else {
                XCTAssertLessThan(eye.position.z, eye.target.z, "\(name): the rim rule lights from behind")
            }
        }
        try click("key", rim: nil, pin: false)
        try click("key", rim: LightGizmoMetrics.rimDegrees, pin: false)
        controller.select(name: "rim")
        try click("rim", rim: nil, pin: true)

        // Off the molecule: a miss runs nothing.
        let l = try layout()
        let json = engine.lightRigJSON()
        let taps = tap()
        var pointer = LightGizmoPointer()
        XCTAssertEqual(pointer.press(at: CGPoint(x: 3, y: 3), option: true, layout: l, interaction: interaction),
                       .highlightCandidate)
        XCTAssertEqual(pointer.release(at: CGPoint(x: 3, y: 3), interaction: interaction), .gizmo)
        taps.stop()
        XCTAssertEqual(pointer.lastHighlight, .miss)
        XCTAssertEqual(taps.commands.lines, [])
        XCTAssertEqual(engine.lightRigJSON(), json)
    }

    // MARK: mirroring

    /// The gizmo, the inspector and the orbit view are one model: a gizmo
    /// tick shows in the other two in the same turn, and their edits (and a
    /// bar select) show in the gizmo's layout in the same turn.
    func testMirroringWithTheInspectorAndTheOrbitView() throws {
        try enterGizmo()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        var session = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        let ball = try XCTUnwrap(session.trackball)
        let to = ball.pointer(for: LightGizmoLayout.direction(orbit: -60, pitch: 40))
        drag(&session, from: key.centre, to: to, steps: 6)
        XCTAssertEqual(try coreRig().lights[0].orbit, -60)
        XCTAssertEqual(try coreRig().lights[0].pitch, 40)
        let inspector = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(inspector.row(.orbit)?.value, -60)
        XCTAssertEqual(inspector.row(.pitch)?.value, 40)
        let orbit = try XCTUnwrap(LightsOrbitState(controller))
        XCTAssertEqual(orbit.selected.orbit, -60)
        XCTAssertEqual(orbit.selected.pitch, 40)

        // The inspector's beam: the rings in the same turn.
        XCTAssertEqual(controller.set(.beam, 30), .ok)
        let ringed = try XCTUnwrap(try layout().selected)
        XCTAssertEqual(ringed.beam, 30)
        XCTAssertEqual(try XCTUnwrap(ringed.outerRing).radius, ringed.aimDistance * tan(15 * Double.pi / 180),
                       accuracy: 1e-3)

        // A plan lamp drag: the knob in the same turn.
        let card = try XCTUnwrap(LightsOrbitState(controller))
        let plan = OrbitPlanLayout(extent: card.extent)
        let lamp = try XCTUnwrap(card.lamp(named: "key"))
        var planSession = try XCTUnwrap(LightsOrbitInteraction(controller: controller).beginPlan(
            at: plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius), state: card, layout: plan))
        XCTAssertEqual(LightsOrbitInteraction(controller: controller).move(
            &planSession, to: plan.point(orbit: lamp.orbit + 45, distance: plan.drawnDistance(radius: lamp.radius))),
                       .ok)
        let planned = try coreRig().lights[0]
        let knob = try XCTUnwrap(try layout().knob(named: "key"))
        XCTAssertLessThan(simd_distance(knob.direction,
                                        LightGizmoLayout.direction(orbit: planned.orbit, pitch: planned.pitch)), 1e-4)

        // A bar select moves the rings; a knob press selects back everywhere.
        controller.select(name: "fill")
        let filled = try layout()
        XCTAssertEqual(filled.selected?.name, "fill")
        _ = interaction.press(at: try XCTUnwrap(filled.knob(named: "key")).centre, layout: filled)
        XCTAssertEqual(controller.selection.name, "key")
        XCTAssertEqual(LightsBarState(controller).chips.filter(\.isSelected).map(\.name), ["key"])
        XCTAssertEqual(LightsInspectorState(controller)?.name, "key")
        XCTAssertEqual(LightsOrbitState(controller)?.selected.name, "key")
        XCTAssertEqual(try layout().selected?.name, "key")
    }

    // MARK: shadows

    /// The Shadow chip's press on a fourth light is refused by the cap: the
    /// core is unchanged and the notice shows in the chip and the inspector;
    /// with a shadow freed, it is accepted.
    func testFourthShadowRefusedFromTheGizmo() throws {
        try enterGizmo(selecting: "kick", rig: """
            {'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 10.0,
             'lights': [{'name': 'key', 'orbit': -30.0, 'pitch': 20.0, 'shadow': True},
                        {'name': 'fill', 'orbit': 40.0, 'pitch': 10.0, 'shadow': True},
                        {'name': 'rim', 'orbit': 160.0, 'pitch': 15.0, 'shadow': True},
                        {'name': 'kick', 'orbit': 80.0, 'pitch': -20.0}]}
            """)
        XCTAssertEqual(try layout().knobs.map(\.isShadowed), [true, true, true, false])
        let json = engine.lightRigJSON()
        XCTAssertNotEqual(interaction.toggleShadow(), .ok, "a fourth shadow is refused")
        XCTAssertEqual(engine.lightRigJSON(), json, "the core is unchanged")
        let chip = try XCTUnwrap(LightGizmoState(controller)?.chip)
        XCTAssertEqual(chip.notice, LightsInspectorState.shadowCapNotice)
        XCTAssertEqual(LightsInspectorState(controller)?.notice, chip.notice, "shown in both")
        XCTAssertFalse(chip.isOn)

        controller.select(name: "key")
        XCTAssertEqual(interaction.toggleShadow(), .ok, "key's shadow off")
        controller.select(name: "kick")
        XCTAssertEqual(interaction.toggleShadow(), .ok, "now kick may cast one")
        XCTAssertEqual(try coreRig().lights.map(\.shadow), [false, true, true, true])
        XCTAssertEqual(LightGizmoState(controller)?.chip.value, "On")
        XCTAssertEqual(try layout().knobs.map(\.isShadowed), [false, true, true, true])
    }

    // MARK: not in the scene

    /// A whole gizmo session (knob, rings, aim, scroll, an option-click) and
    /// leaving the mode change no object name, the scene's extent or the
    /// shadow casters: the gizmo is never scene geometry.
    func testGizmoAddsNothingToTheScene() throws {
        try buildScene()
        let before = sceneFacts()
        XCTAssertNotNil(before["names"], "the scene read failed: \(before)")
        XCTAssertNil(engine.lightGizmoLayout(viewSize: viewSize), "no gizmo outside Lights mode")
        enter()

        var l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        var knob = try XCTUnwrap(interaction.press(at: key.centre, layout: l))
        drag(&knob, from: key.centre, to: CGPoint(x: l.centre.x - 0.4 * l.sphereRadius, y: l.centre.y))
        l = try layout()
        if let ring = l.selected?.outerRing, let aim = l.selected?.aimDot,
           let p = clearPoint(on: ring, .outerRing, in: l), var s = interaction.press(at: p, layout: l) {
            drag(&s, from: p, to: lerp(aim, p, 1.2))
        } else {
            XCTFail("no outer ring to drag")
        }
        l = try layout()
        let cam = try camera()
        let ca = try XCTUnwrap(l.projection.point(eye: cam.eye(try atom("lmt_pep and resi 3 and name CA"))))
        if let aim = l.selected?.aimDot, var s = interaction.press(at: aim, layout: l) {
            drag(&s, from: aim, to: ca)
        } else {
            XCTFail("no aim dot to drag")
        }
        XCTAssertEqual(interaction.scrollWheel(at: try XCTUnwrap(l.knob(named: "key")).centre, up: true, layout: l),
                       .ok)
        l = try layout()
        let clear = try clickablePoint(in: l)
        var pointer = LightGizmoPointer()
        XCTAssertEqual(pointer.press(at: clear, option: true, layout: l, interaction: interaction),
                       .highlightCandidate)
        XCTAssertEqual(pointer.release(at: clear, interaction: interaction), .gizmo)
        XCTAssertEqual(pointer.lastHighlight, .placed(rim: nil))
        let entry = try XCTUnwrap(controller.entryRig)
        XCTAssertNotEqual(try coreRig().lights[0], entry.lights[0], "the session edited key")

        let during = sceneFacts()
        XCTAssertEqual(during, before, "the gizmo changed the scene: \(during) vs \(before)")
        engine.setInteractionMode(.viewing)
        XCTAssertNil(engine.lightGizmoLayout(viewSize: viewSize))
        XCTAssertEqual(sceneFacts(), before, "leaving the mode changed the scene")
    }

    /// An offscreen Metal frame (shadows on, key casting) is the same pixels
    /// outside Lights mode and inside it with the gizmo laid out and a knob
    /// session open: the overlay is never in the frame.
    func testGizmoIsNotInTheMetalFrame() throws {
        try buildScene()
        python("_c.set('metal_shadows', 1)\n")
        XCTAssertEqual(try coreRig().lights[0].shadow, true)
        let outside = try renderFrame(rayTraced: 0, keep: "live-frame-rt0-outside")
        XCTAssertGreaterThan(colourCount(outside), 50, "the frame shows the peptide, not a blank view")
        enter()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        let json = engine.lightRigJSON()
        var pointer = LightGizmoPointer()
        XCTAssertEqual(pointer.press(at: key.centre, option: false, layout: l, interaction: interaction), .gizmo)
        XCTAssertNotNil(pointer.session)
        XCTAssertEqual(engine.lightRigJSON(), json, "a press writes nothing")
        let inside = try renderFrame(rayTraced: 0, keep: "live-frame-rt0-gizmo")
        _ = pointer.release(at: key.centre, interaction: interaction)
        engine.setInteractionMode(.viewing)
        let after = try renderFrame(rayTraced: 0)
        XCTAssertEqual(maxDifference(outside, inside), 0, "the gizmo's mode changed the frame")
        XCTAssertEqual(maxDifference(outside, after), 0, "leaving the mode changed the frame")
    }

    /// The same at rayTraced 1, behind a determinism self-check: two frames
    /// with nothing changed must be equal, else the comparison means nothing
    /// and the test skips.
    func testGizmoIsNotInTheRayTracedFrame() throws {
        try buildScene()
        python("_c.set('metal_shadows', 1)\n")
        let first = try renderFrame(rayTraced: 1, keep: "live-frame-rt1-outside")
        XCTAssertGreaterThan(colourCount(first), 50, "the frame shows the peptide, not a blank view")
        let second = try renderFrame(rayTraced: 1)
        let noise = maxDifference(first, second)
        guard noise == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ by \(noise): not deterministic here")
        }
        enter()
        let l = try layout()
        let key = try XCTUnwrap(l.knob(named: "key"))
        var pointer = LightGizmoPointer()
        XCTAssertEqual(pointer.press(at: key.centre, option: false, layout: l, interaction: interaction), .gizmo)
        let inside = try renderFrame(rayTraced: 1, keep: "live-frame-rt1-gizmo")
        _ = pointer.release(at: key.centre, interaction: interaction)
        XCTAssertEqual(maxDifference(first, inside), 0, "the gizmo's mode changed the ray-traced frame")
    }

    // MARK: the camera turns

    /// `turn y, 120` carries the pinned rim from behind the molecule to the
    /// front: facing, the bar's chip, the knob and VoiceOver flip with the
    /// frame that follows, once; the camera light does not flip.
    func testTurningTheCameraFlipsAPinnedLightsChip() throws {
        try enterGizmo()
        func rimBehind() -> Bool? { LightsBarState(controller).chips.first { $0.name == "rim" }?.isBehind }
        XCTAssertTrue(controller.isBehind("rim"))
        XCTAssertEqual(rimBehind(), true)
        XCTAssertEqual(try layout().knob(named: "rim")?.isBehind, true)
        XCTAssertFalse(controller.isBehind("key"))

        let changes = LightsChangeCounter()
        let watch = controller.facing.objectWillChange.sink { _ in changes.count += 1 }
        defer { watch.cancel() }
        engine.runCommand("turn y, 120")
        engine.lightsFrameRendered()
        XCTAssertFalse(controller.isBehind("rim"), "the turn brought rim to the front")
        XCTAssertEqual(rimBehind(), false, "the chip")
        let l = try layout()
        let rim = try XCTUnwrap(l.knob(named: "rim"))
        XCTAssertFalse(rim.isBehind, "the knob")
        XCTAssertEqual(LightGizmoState(controller)?.front.contains("rim"), true, "VoiceOver")
        let eye = try coreEyeSpace()
        let d = simd_normalize(double3(eye.lights[2].position - eye.centre))
        XCTAssertLessThan(simd_distance(rim.direction, d), 1e-4, "the knob follows the camera")
        XCTAssertFalse(controller.isBehind("key"), "a camera light turns with the camera")
        XCTAssertEqual(changes.count, 1, "one publish for one crossing")
        engine.lightsFrameRendered()
        XCTAssertEqual(changes.count, 1, "a frame with no crossing publishes nothing")
        XCTAssertEqual(try coreRig().lights[2].anchor, .pinned)

        engine.runCommand("turn y, -120")
        engine.lightsFrameRendered()
        XCTAssertTrue(controller.isBehind("rim"))
        XCTAssertEqual(rimBehind(), true)
    }
}
