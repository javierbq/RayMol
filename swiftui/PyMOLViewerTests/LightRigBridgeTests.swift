import XCTest
@testable import RayMol

/// The light-rig bridge (#611, spec §4.4): PyMOLBridge_LightsJSON, LightSet,
/// LightSetVector and LightsEyeSpace, through PyMOLEngine's Swift wrappers
/// (LightRigBridge.swift), against the LIVE engine of the host app.
///
/// The CI Python tests (testing/tests/raymol/lighting_*.py) cover the C++ maths
/// through _cmd; these show the bridge reaches the same C++ on macOS: its JSON
/// decodes to what cmd.get_lights() returns, its eye space equals
/// pymol.lighting._lights_eye() and the camera read back with captureView(),
/// and its status codes come through.
///
/// The live tests fail (never skip) when the engine is not ready: a skipped
/// bridge test would have checked nothing. Each one starts and ends with no rig
/// and the host's own camera, since PyMOLEngine.shared is shared by every test.
@MainActor
final class LightRigBridgeTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    private static let probePath = NSTemporaryDirectory() + "/lightrig611_probe.json"

    private struct EngineNotReady: Error, CustomStringConvertible {
        var description: String { "PyMOLEngine.shared never became ready" }
    }

    /// Wait (up to 20 s, pumping the run loop) for the host app's engine, then
    /// clear the rig and remember the camera. XCTFail + throw when it never
    /// comes up, so the test body does not run and the test counts as failed.
    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready after 20 s: the live light-rig bridge test ran nothing")
            throw EngineNotReady()
        }
        engine.runPython(
            "from pymol import cmd as _lrb_cmd\n"
            + "_lrb_cmd.set_lights(None)\n"
            + "_lrb_view = _lrb_cmd.get_view()\n")
        XCTAssertNil(engine.lightRigJSON(), "the rig was not cleared")
    }

    override func tearDown() {
        engine.runPython(
            "from pymol import cmd as _lrb_cmd\n"
            + "_lrb_cmd.set_lights(None)\n"
            + "if '_lrb_view' in globals():\n"
            + "    _lrb_cmd.set_view(_lrb_view)\n"
            + "    del _lrb_view\n")
        try? FileManager.default.removeItem(atPath: Self.probePath)
        super.tearDown()
    }

    // MARK: - fixtures

    /// centre (0,0,0), size 10, air set, and three lights:
    /// key   camera light at orbit 0, pitch 0, radius 2, shadowed;
    /// fill  camera light aimed at a point, tinted;
    /// rim   pinned at a world point, outlined, a narrow beam.
    private static let threeLights = """
        {'enabled': False, 'centre': [0.0, 0.0, 0.0], 'size': 10.0,
         'ambient': 0.1, 'classic': 0.25,
         'air': {'haze': 0.2, 'dust': 0.3, 'dust_size': 0.5, 'dust_speed': 2.0,
                 'scatter': -0.25, 'seed': 7},
         'lights': [
           {'name': 'key', 'orbit': 0.0, 'pitch': 0.0, 'radius': 2.0, 'shadow': True},
           {'name': 'fill', 'orbit': -60.0, 'pitch': 20.0, 'aim': 'point',
            'aim_point': [1.0, 2.0, 3.0], 'aim_selection': 'organic',
            'color': [0.5, 0.75, 1.0], 'warmth': 4000.0},
           {'name': 'rim', 'anchor': 'pinned', 'position': [5.0, 6.0, -30.0],
            'outline': True, 'beam': 30.0, 'softness': 0.1}]}
        """

    /// cmd.set_lights(`dict`) in the live interpreter; asserts a rig resulted.
    private func setRig(_ dict: String, file: StaticString = #filePath, line: UInt = #line) {
        engine.runPython("from pymol import cmd as _lrb_cmd\n_lrb_cmd.set_lights(\(dict))\n")
        XCTAssertNotNil(engine.lightRigJSON(), "cmd.set_lights raised", file: file, line: line)
    }

    /// The str that the Python expression `expr` gives, through a temp file
    /// (runPython has no return channel). `_lrb_json`, `_lrb_cmd` and
    /// `_lrb_lighting` are in scope.
    private func python(_ expr: String) -> String? {
        let path = Self.probePath
        try? FileManager.default.removeItem(atPath: path)
        engine.runPython(
            "import json as _lrb_json\n"
            + "from pymol import cmd as _lrb_cmd, lighting as _lrb_lighting\n"
            + "with open(r'\(path)', 'w') as _lrb_f:\n"
            + "    _lrb_f.write(\(expr))\n")
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// world -> eye with the live camera, from captureView() (cmd.get_view()'s
    /// 25 floats): eye = R·(p - origin) + pos. The oracle metal_pick.camera()
    /// uses, computed here so it does not come from the code under test.
    private func oracle(_ p: SIMD3<Double>, file: StaticString = #filePath, line: UInt = #line) -> SIMD3<Float> {
        guard let v = engine.captureView() else {
            XCTFail("no view", file: file, line: line)
            return .zero
        }
        let d = SIMD3<Float>(Float(p.x) - v[19], Float(p.y) - v[20], Float(p.z) - v[21])
        return SIMD3<Float>(v[0] * d.x + v[4] * d.y + v[8] * d.z + v[16],
                            v[1] * d.x + v[5] * d.y + v[9] * d.z + v[17],
                            v[2] * d.x + v[6] * d.y + v[10] * d.z + v[18])
    }

    private func assertClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ accuracy: Float = 1e-3,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for k in 0..<3 {
            XCTAssertEqual(a[k], b[k], accuracy: accuracy, "\(message) [\(k)]: \(a) vs \(b)",
                           file: file, line: line)
        }
    }

    // MARK: - offline

    /// The exact v1 key set the core writes (LightRigToJSON), including a light
    /// of every kind, decodes; so does an empty rig with no frame (nulls).
    func testDecodesFixture() throws {
        let json = """
            {"version":1,"enabled":true,"centre":[1.5,-2.0,3.25],"size":12.5,"ambient":0.05,"classic":0.0,
             "air":{"haze":0.25,"dust":0.0,"dust_size":0.35,"dust_speed":1.0,"scatter":0.55,"seed":3},
             "lights":[
              {"name":"key","anchor":"camera","orbit":-45.0,"pitch":35.0,"radius":4.0,"position":[0.0,0.0,0.0],
               "aim":"centre","aim_point":[0.0,0.0,0.0],"aim_selection":"","beam":45.0,"softness":0.4,
               "color":[1.0,1.0,1.0],"warmth":6500.0,"intensity":1.0,"highlight":0.5,"falloff":2.0,
               "shadow":true,"outline":false},
              {"name":"fill","anchor":"camera","orbit":60.0,"pitch":10.0,"radius":3.0,"position":[0.0,0.0,0.0],
               "aim":"point","aim_point":[1.0,2.0,3.0],"aim_selection":"organic","beam":90.0,"softness":0.8,
               "color":[0.5,0.75,1.0],"warmth":4000.0,"intensity":0.5,"highlight":0.25,"falloff":1.0,
               "shadow":false,"outline":false},
              {"name":"rim","anchor":"pinned","orbit":0.0,"pitch":30.0,"radius":4.0,"position":[5.0,6.0,-7.0],
               "aim":"centre","aim_point":[0.0,0.0,0.0],"aim_selection":"","beam":30.0,"softness":0.1,
               "color":[1.0,0.9,0.8],"warmth":9000.0,"intensity":2.0,"highlight":1.0,"falloff":0.0,
               "shadow":false,"outline":true}]}
            """
        let rig = try LightRigSnapshot.decode(Data(json.utf8))
        XCTAssertEqual(rig.version, 1)
        XCTAssertTrue(rig.enabled)
        XCTAssertEqual(rig.centre, SIMD3(1.5, -2.0, 3.25))
        XCTAssertEqual(rig.size, 12.5)
        XCTAssertEqual(rig.air, .init(haze: 0.25, dust: 0, dustSize: 0.35, dustSpeed: 1, scatter: 0.55, seed: 3))
        XCTAssertEqual(rig.lights.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(rig.lights.map(\.anchor), [.camera, .camera, .pinned])
        XCTAssertEqual(rig.lights.map(\.aim), [.centre, .point, .centre])
        XCTAssertEqual(rig.lights[0].orbit, -45)
        XCTAssertTrue(rig.lights[0].shadow)
        XCTAssertEqual(rig.lights[1].aimPoint, SIMD3(1, 2, 3))
        XCTAssertEqual(rig.lights[1].aimSelection, "organic")
        XCTAssertEqual(rig.lights[1].color, SIMD3(0.5, 0.75, 1.0))
        XCTAssertEqual(rig.lights[1].warmth, 4000)
        XCTAssertEqual(rig.lights[2].position, SIMD3(5, 6, -7))
        XCTAssertTrue(rig.lights[2].outline)
        XCTAssertEqual(rig.lights[2].falloff, 0)

        let empty = try LightRigSnapshot.decode(Data("""
            {"version":1,"enabled":false,"centre":null,"size":null,"ambient":0.05,"classic":0.0,
             "air":{"haze":0.0,"dust":0.0,"dust_size":0.35,"dust_speed":1.0,"scatter":0.55,"seed":0},
             "lights":[]}
            """.utf8))
        XCTAssertNil(empty.centre)
        XCTAssertNil(empty.size)
        XCTAssertTrue(empty.lights.isEmpty)

        // A vector must have exactly 3 numbers.
        XCTAssertThrowsError(try LightRigSnapshot.decode(Data(json.replacingOccurrences(
            of: "\"centre\":[1.5,-2.0,3.25]", with: "\"centre\":[1.5,-2.0]").utf8)))
    }

    /// The PYMOL_LIGHT_SET_* codes (pymol::LightSetStatus) map to the cases.
    func testStatusCodes() {
        XCTAssertEqual(LightSetResult(status: 1), .ok)
        XCTAssertEqual(LightSetResult(status: 0), .unknownField)
        XCTAssertEqual(LightSetResult(status: -1), .badIndex)
        XCTAssertEqual(LightSetResult(status: -2), .refused)
        XCTAssertEqual(LightSetResult(status: -3), .badValue)
        XCTAssertEqual(LightSetResult(status: -4), .noRig)
    }

    // MARK: - live engine

    func testNoRig() throws {
        try requireEngine()
        XCTAssertNil(engine.lightRigJSON())
        XCTAssertNil(engine.lightRig())
        XCTAssertNil(engine.lightsEyeSpace())
        XCTAssertEqual(engine.setLight(0, "orbit", 10), .noRig)
        XCTAssertEqual(engine.setLight(-1, "enabled", 1), .noRig)
        XCTAssertEqual(engine.setLight(0, "color", SIMD3(1, 0, 0)), .noRig)
        XCTAssertNil(engine.lightRigJSON(), "a failed write must not create a rig")
    }

    /// An empty rig exists but has no frame (and so no eye-space lights) until
    /// its first light.
    func testEmptyRigHasNoFrame() throws {
        try requireEngine()
        setRig("{}")
        let rig = try XCTUnwrap(engine.lightRig())
        XCTAssertNil(rig.centre)
        XCTAssertNil(rig.size)
        XCTAssertTrue(rig.lights.isEmpty)
        XCTAssertFalse(rig.enabled)
        let eye = try XCTUnwrap(engine.lightsEyeSpace())
        XCTAssertFalse(eye.hasFrame)
        XCTAssertTrue(eye.lights.isEmpty)
        XCTAssertEqual(engine.setLight(0, "orbit", 10), .badIndex)
    }

    /// The bridge's JSON decodes to exactly what cmd.get_lights() returns.
    func testJsonMatchesPython() throws {
        try requireEngine()
        setRig(Self.threeLights)
        let bridge = try XCTUnwrap(engine.lightRig())
        let fromPython = try XCTUnwrap(python("_lrb_json.dumps(_lrb_cmd.get_lights())"))
        XCTAssertEqual(bridge, try LightRigSnapshot.decode(Data(fromPython.utf8)))

        XCTAssertEqual(bridge.version, 1)
        XCTAssertFalse(bridge.enabled)
        XCTAssertEqual(bridge.centre, SIMD3(0, 0, 0))
        XCTAssertEqual(bridge.size, 10)
        XCTAssertEqual(bridge.ambient, 0.1)
        XCTAssertEqual(bridge.classic, 0.25)
        XCTAssertEqual(bridge.air, .init(haze: 0.2, dust: 0.3, dustSize: 0.5, dustSpeed: 2, scatter: -0.25, seed: 7))
        XCTAssertEqual(bridge.lights.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(bridge.lights.map(\.anchor), [.camera, .camera, .pinned])
        XCTAssertEqual(bridge.lights.map(\.aim), [.centre, .point, .centre])
        XCTAssertEqual(bridge.lights.map(\.shadow), [true, false, false])
        XCTAssertEqual(bridge.lights.map(\.outline), [false, false, true])
        XCTAssertEqual(bridge.lights[1].aimPoint, SIMD3(1, 2, 3))
        XCTAssertEqual(bridge.lights[1].aimSelection, "organic")
        XCTAssertEqual(bridge.lights[1].color, SIMD3(0.5, 0.75, 1.0))
        XCTAssertEqual(bridge.lights[1].warmth, 4000)
        XCTAssertEqual(bridge.lights[2].position, SIMD3(5, 6, -30))
        XCTAssertEqual(bridge.lights[2].beam, 30)
    }

    /// Orbit +90° puts a camera light to the camera's right (+x), whatever the
    /// camera: centre c, size 10, radius 2, pitch 0 gives p - c = (20, 0, 0).
    func testSetLightOrbitPlus90IsPlusX() throws {
        try requireEngine()
        setRig(Self.threeLights)
        engine.runPython("_lrb_cmd.turn('y', 35)\n_lrb_cmd.turn('x', -20)\n")
        XCTAssertEqual(engine.setLight(0, "orbit", 90), .ok)
        XCTAssertEqual(engine.lightRig()?.lights[0].orbit, 90)
        let eye = try XCTUnwrap(engine.lightsEyeSpace())
        let key = eye.lights[0]
        assertClose(key.position - eye.centre, SIMD3(20, 0, 0), 1e-3, "p - c")
        assertClose(key.direction, SIMD3(-1, 0, 0), 1e-5, "direction")
        XCTAssertEqual(key.aimDistance, 20, accuracy: 1e-3)
        XCTAssertEqual(key.orbit, 90, accuracy: 1e-4)

        // Orbit -90 is camera-left, pitch +90 straight up.
        XCTAssertEqual(engine.setLight(0, "orbit", -90), .ok)
        let left = try XCTUnwrap(engine.lightsEyeSpace())
        assertClose(left.lights[0].position - left.centre, SIMD3(-20, 0, 0), 1e-3, "orbit -90")
        XCTAssertEqual(engine.setLight(0, "pitch", 90), .ok)
        let up = try XCTUnwrap(engine.lightsEyeSpace())
        assertClose(up.lights[0].position - up.centre, SIMD3(0, 20, 0), 1e-3, "pitch +90")
    }

    /// Under a rotated view the bridge's eye space equals _cmd's
    /// (pymol.lighting._lights_eye()) for camera, aimed and pinned lights, and
    /// the centre, the aim point and the pinned light match the camera read
    /// back with captureView().
    func testEyeSpaceMatchesPythonUnderRotatedView() throws {
        try requireEngine()
        setRig(Self.threeLights)
        engine.runPython("_lrb_cmd.turn('y', 35)\n_lrb_cmd.turn('x', -20)\n_lrb_cmd.move('z', -12)\n")

        let eye = try XCTUnwrap(engine.lightsEyeSpace())
        XCTAssertTrue(eye.hasFrame)
        XCTAssertFalse(eye.enabled)
        XCTAssertEqual(eye.size, 10)
        XCTAssertEqual(eye.lights.count, 3)

        struct PyEye: Decodable {
            struct Light: Decodable {
                let name, anchor, aim: String
                let position, target, direction: [Float]
                let aimDistance, cosOuter, cosInner, orbit, pitch, radius: Float
                let shadow, outline: Bool
            }
            let enabled: Bool
            let centre: [Float]?
            let size: Float?
            let lights: [Light]
        }
        let text = try XCTUnwrap(python("_lrb_json.dumps(_lrb_lighting._lights_eye())"))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let py = try decoder.decode(PyEye.self, from: Data(text.utf8))
        let vec: ([Float]) -> SIMD3<Float> = { SIMD3($0[0], $0[1], $0[2]) }

        XCTAssertEqual(py.lights.count, eye.lights.count)
        assertClose(eye.centre, vec(try XCTUnwrap(py.centre)), 1e-5, "centre")
        for (got, want) in zip(eye.lights, py.lights) {
            assertClose(got.position, vec(want.position), 1e-5, "\(want.name) position")
            assertClose(got.target, vec(want.target), 1e-5, "\(want.name) target")
            assertClose(got.direction, vec(want.direction), 1e-6, "\(want.name) direction")
            XCTAssertEqual(got.aimDistance, want.aimDistance, accuracy: 1e-5)
            XCTAssertEqual(got.cosOuter, want.cosOuter, accuracy: 1e-6)
            XCTAssertEqual(got.cosInner, want.cosInner, accuracy: 1e-6)
            XCTAssertEqual(got.orbit, want.orbit, accuracy: 1e-4)
            XCTAssertEqual(got.pitch, want.pitch, accuracy: 1e-4)
            XCTAssertEqual(got.radius, want.radius, accuracy: 1e-5)
            XCTAssertEqual(got.anchor.rawValue, want.anchor)
            XCTAssertEqual(got.aim.rawValue, want.aim)
            XCTAssertEqual(got.shadow, want.shadow)
            XCTAssertEqual(got.outline, want.outline)
        }

        // Independent of the resolver: the camera as captureView() reads it.
        assertClose(eye.centre, oracle(SIMD3(0, 0, 0)), 1e-3, "centre vs oracle")
        assertClose(eye.lights[1].target, oracle(SIMD3(1, 2, 3)), 1e-3, "fill aim point vs oracle")
        assertClose(eye.lights[2].position, oracle(SIMD3(5, 6, -30)), 1e-3, "rim (pinned) vs oracle")
        // The view really is rotated: the pinned light is not at its world point.
        XCTAssertGreaterThan(length(eye.lights[2].position - SIMD3<Float>(5, 6, -30)), 1)
        // The cone: cos(beam/2) and the prototype's soft edge.
        XCTAssertEqual(eye.lights[2].cosOuter, Float(cos(15.0 * Double.pi / 180)), accuracy: 1e-6)
        XCTAssertEqual(eye.lights[2].cosInner, Float(cos(15.0 * 0.9 * Double.pi / 180)), accuracy: 1e-6)
    }

    /// color, aim_point and position are set whole, in one call each.
    func testVectorFields() throws {
        try requireEngine()
        setRig(Self.threeLights)
        engine.runPython("_lrb_cmd.turn('y', 50)\n")

        XCTAssertEqual(engine.setLight(0, "color", SIMD3(0.25, 0.5, 2.0)), .ok)
        XCTAssertEqual(engine.lightRig()?.lights[0].color, SIMD3(0.25, 0.5, 1.0), "clamped into 0...1")

        // aim_point aims the light at it and clears the selection text.
        XCTAssertEqual(engine.setLight(1, "aim_point", SIMD3(-4, 5, 6)), .ok)
        var rig = try XCTUnwrap(engine.lightRig())
        XCTAssertEqual(rig.lights[1].aim, .point)
        XCTAssertEqual(rig.lights[1].aimPoint, SIMD3(-4, 5, 6))
        XCTAssertEqual(rig.lights[1].aimSelection, "")
        assertClose(try XCTUnwrap(engine.lightsEyeSpace()).lights[1].target,
                    oracle(SIMD3(-4, 5, 6)), 1e-3, "fill target")

        // position pins the light there.
        XCTAssertEqual(engine.setLight(0, "position", SIMD3(12, -3, 4)), .ok)
        rig = try XCTUnwrap(engine.lightRig())
        XCTAssertEqual(rig.lights[0].anchor, .pinned)
        XCTAssertEqual(rig.lights[0].position, SIMD3(12, -3, 4))
        let eye = try XCTUnwrap(engine.lightsEyeSpace())
        XCTAssertEqual(eye.lights[0].anchor, .pinned)
        assertClose(eye.lights[0].position, oracle(SIMD3(12, -3, 4)), 1e-3, "pinned key")
    }

    /// Pinning keeps the light where it is; it then stays at its world point
    /// while the camera turns, and unpinning keeps it where it is too.
    func testPinAndUnpinKeepTheLight() throws {
        try requireEngine()
        setRig(Self.threeLights)
        XCTAssertEqual(engine.setLight(0, "orbit", 40), .ok)
        let before = try XCTUnwrap(engine.lightsEyeSpace()).lights[0].position
        XCTAssertEqual(engine.setLight(0, "anchor", 1), .ok)
        XCTAssertEqual(engine.lightRig()?.lights[0].anchor, .pinned)
        assertClose(try XCTUnwrap(engine.lightsEyeSpace()).lights[0].position, before, 1e-3, "pin")

        let world = try XCTUnwrap(engine.lightRig()?.lights[0].position)
        engine.runPython("_lrb_cmd.turn('y', 70)\n")
        let turned = try XCTUnwrap(engine.lightsEyeSpace()).lights[0].position
        assertClose(turned, oracle(world), 1e-3, "pinned after turn")
        XCTAssertGreaterThan(length(turned - before), 1, "a pinned light turns with the molecule")

        XCTAssertEqual(engine.setLight(0, "anchor", 0), .ok)
        XCTAssertEqual(engine.lightRig()?.lights[0].anchor, .camera)
        assertClose(try XCTUnwrap(engine.lightsEyeSpace()).lights[0].position, turned, 1e-3, "unpin")
    }

    /// Every refusal returns its code and leaves the rig exactly as it was.
    func testRefusals() throws {
        try requireEngine()
        setRig("""
            {'centre': [0.0, 0.0, 0.0], 'size': 10.0, 'lights': [
              {'name': 'a', 'shadow': True}, {'name': 'b', 'shadow': True},
              {'name': 'c', 'shadow': True}, {'name': 'd'}]}
            """)
        let before = try XCTUnwrap(engine.lightRigJSON())
        let cases: [(String, () -> LightSetResult, LightSetResult)] = [
            ("unknown field", { self.engine.setLight(0, "colour", 1) }, .unknownField),
            ("light field at the rig index", { self.engine.setLight(-1, "orbit", 1) }, .unknownField),
            ("rig field at a light index", { self.engine.setLight(0, "haze", 0.5) }, .unknownField),
            ("index past the end", { self.engine.setLight(4, "orbit", 1) }, .badIndex),
            ("index below -1", { self.engine.setLight(-2, "orbit", 1) }, .badIndex),
            ("huge index", { self.engine.setLight(Int.max, "orbit", 1) }, .badIndex),
            ("a 4th shadow", { self.engine.setLight(3, "shadow", 1) }, .refused),
            ("text field", { self.engine.setLight(0, "name", 1) }, .refused),
            ("the frame", { self.engine.setLight(-1, "size", 5) }, .refused),
            ("NaN", { self.engine.setLight(0, "orbit", .nan) }, .badValue),
            ("inf", { self.engine.setLight(0, "color", SIMD3(.infinity, 0, 0)) }, .badValue),
            ("anchor 0.5", { self.engine.setLight(0, "anchor", 0.5) }, .badValue),
            ("a vector as a number", { self.engine.setLight(0, "color", 1) }, .badValue),
            ("a number as a vector", { self.engine.setLight(0, "orbit", SIMD3(1, 2, 3)) }, .badValue),
        ]
        for (label, call, want) in cases {
            XCTAssertEqual(call(), want, label)
            XCTAssertEqual(engine.lightRigJSON(), before, "\(label) changed the rig")
        }
    }

    /// Rig and air fields live at index -1; numbers are clamped into range.
    func testRigLevelFields() throws {
        try requireEngine()
        setRig(Self.threeLights)
        XCTAssertEqual(engine.setLight(-1, "enabled", 1), .ok)
        XCTAssertEqual(engine.lightRig()?.enabled, true)
        XCTAssertEqual(engine.lightsEyeSpace()?.enabled, true)
        XCTAssertEqual(engine.setLight(-1, "enabled", 0), .ok)
        XCTAssertEqual(engine.lightRig()?.enabled, false)

        XCTAssertEqual(engine.setLight(-1, "ambient", 2), .ok)
        XCTAssertEqual(engine.setLight(-1, "haze", 0.5), .ok)
        XCTAssertEqual(engine.setLight(-1, "seed", 42), .ok)
        let rig = try XCTUnwrap(engine.lightRig())
        XCTAssertEqual(rig.ambient, 1, "clamped into 0...1")
        XCTAssertEqual(rig.air.haze, 0.5)
        XCTAssertEqual(rig.air.seed, 42)
    }

    /// A write that changed the rig asks the viewport for a frame; a refused
    /// one does not.
    func testSetLightRequestsRedraw() throws {
        try requireEngine()
        setRig(Self.threeLights)
        // requestViewportRedraw posts synchronously on the main thread, and
        // nothing here spins the run loop, so only these writes are counted.
        let posts = PostCounter()
        let token = NotificationCenter.default.addObserver(
            forName: PyMOLEngine.forceRedrawNotification, object: nil, queue: nil) { _ in posts.count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertEqual(engine.setLight(0, "intensity", 2), .ok)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(engine.setLight(0, "color", SIMD3(1, 0, 0)), .ok)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(engine.setLight(0, "colour", 1), .unknownField)
        XCTAssertEqual(engine.setLight(0, "orbit", .nan), .badValue)
        XCTAssertEqual(posts.count, 2)
    }
}

/// Counts notifications; touched on the main thread only.
private final class PostCounter: @unchecked Sendable {
    var count = 0
}

private func length(_ v: SIMD3<Float>) -> Float {
    (v * v).sum().squareRoot()
}
