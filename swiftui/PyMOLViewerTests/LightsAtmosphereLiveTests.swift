import CoreGraphics
import ImageIO
import XCTest
@testable import RayMol

// The Atmosphere card's paths against the LIVE engine (#726): the field table
// the engine reads is the core's, every slider and typed value reaches the
// core through the bridge setter at index -1 with no Python or console
// command, a console `atmosphere` edit shows in the card after the poll's
// refresh, the switch's two commands restore the air byte for byte, Revert
// brings back the entry air (or removes a rig the switch created), Done and
// Esc keep the air, and a command that replaces the document drops the
// switch's memory.
//
// The same rules on fakes are in LightsAtmosphereTests.swift; the Python half
// (the helper, the command strings, the setter path, .pse and scenes) in
// testing/tests/raymol/lighting_atmosphere.py.

@MainActor
final class LightsAtmosphereLiveTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }

    private final class Lines { var lines: [String] = [] }

    override func setUp() {
        super.setUp()
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        engine.setBinderDesignMode(false)
    }

    override func tearDown() {
        LightsLive.tearDown()
        super.tearDown()
    }

    // MARK: helpers

    /// The three-light fixture (its air: haze 0.1, dust 0.3, dust_size 0.5,
    /// dust_speed 2, scatter -0.25, seed 7) on a peptide, Lights mode
    /// entered. Returns the entry JSON.
    @discardableResult
    private func enterWithThreeLights() throws -> String {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(controller.airFields.isEmpty, "the air field table did not load")
        return entry
    }

    /// The core's air now (a bridge read).
    private func coreAir(file: StaticString = #filePath, line: UInt = #line) throws -> LightRigSnapshot.Air {
        try XCTUnwrap(engine.lightRig()?.air, "no rig", file: file, line: line)
    }

    /// The air rows of lighting._light_fields() in the live interpreter.
    private func pythonAirRows() throws -> [[Any]] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-lat-air-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.runPython(
            "import json as _lat_json\n"
            + "from pymol import lighting as _lat_l\n"
            + "with open(r'''\(url.path)''', 'w', encoding='utf-8') as _lat_f:\n"
            + "    _lat_json.dump([list(r[1:]) for r in _lat_l._light_fields() if r[0] == 'air'], _lat_f)\n")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[Any]])
    }

    // MARK: the field table

    func testAirFieldsAreTheCoreTable() throws {
        try enterWithThreeLights()
        let rows = try pythonAirRows()
        XCTAssertEqual(controller.airFields.map(\.name), rows.map { $0[0] as? String })
        XCTAssertEqual(controller.airFields.map(\.kind), rows.map { $0[1] as? String })
        XCTAssertEqual(controller.airFields.map(\.defaultValue), rows.map { ($0[2] as? NSNumber)?.doubleValue })
        XCTAssertEqual(controller.airFields.map(\.min), rows.map { ($0[3] as? NSNumber)?.doubleValue })
        XCTAssertEqual(controller.airFields.map(\.max), rows.map { ($0[4] as? NSNumber)?.doubleValue })
        XCTAssertEqual(controller.airFields, FakeRigStore.airTable,
                       "the fakes' table (and AirFieldDecodeTests' literal) drifted from the core")
        for parameter in AirParameter.allCases {
            XCTAssertEqual(controller.airField(parameter)?.kind, "float", parameter.field)
        }
    }

    // MARK: every control reaches the core

    func testEveryControlReachesTheCore() throws {
        let entry = try enterWithThreeLights()
        let lightsBefore = try LightRigSnapshot.decode(Data(entry.utf8)).lights
        let values: [AirParameter: Double] = [.haze: 0.27, .dust: 0.61, .dustSize: 0.8,
                                              .dustSpeed: 3.45, .scatter: -0.42]
        for p in AirParameter.allCases {
            XCTAssertEqual(controller.setAir(p, values[p]!), .ok, p.field)
            XCTAssertEqual(p.value(in: try coreAir()), values[p], "\(p.field) in the core")
            XCTAssertEqual(controller.airValue(p), values[p], "\(p.field) in the mirror, same turn")
            XCTAssertEqual(AtmosphereCardState(controller)?.row(p)?.value, values[p], "\(p.field) in the card")
            XCTAssertEqual(engine.lightRig()?.air, controller.air, "what `atmosphere` reads is what the card shows")
        }
        // The core clamps to the table's ends.
        for p in AirParameter.allCases {
            let field = try XCTUnwrap(controller.airField(p))
            XCTAssertEqual(controller.setAir(p, field.max + 1), .ok)
            XCTAssertEqual(p.value(in: try coreAir()), field.max, "\(p.field) max")
            XCTAssertEqual(controller.setAir(p, field.min - 1), .ok)
            XCTAssertEqual(p.value(in: try coreAir()), field.min, "\(p.field) min")
            XCTAssertEqual(controller.setAir(p, .nan), .badValue)
            XCTAssertEqual(p.value(in: try coreAir()), field.min, "\(p.field): a refused value changes nothing")
        }
        // Slider ticks: on the grid, every stop the same value in the core.
        let dustSpeed = try XCTUnwrap(controller.airField(.dustSpeed))
        for position in [0.0, 0.25, 0.316, 0.5, 1.0] {
            let value = AirParameter.dustSpeed.sliderValue(position, dustSpeed)
            XCTAssertEqual(controller.setAirIfChanged(.dustSpeed, value), .ok)
            XCTAssertEqual(try coreAir().dustSpeed, value, "dust speed at \(position)")
        }
        // An air write never changes a light.
        XCTAssertEqual(engine.lightRig()?.lights, lightsBefore)
    }

    func testAirEditsRunNoPython() throws {
        let entry = try enterWithThreeLights()
        let lightsBefore = try LightRigSnapshot.decode(Data(entry.utf8)).lights
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        // 5 fields x 10 slider ticks. No run-loop pumping in the loop, so the
        // poll timers cannot fire: every line a tap sees would be the edits'.
        var count = 0
        var changes = 0
        var last = engine.lightRigJSON()
        for p in AirParameter.allCases {
            let field = try XCTUnwrap(controller.airField(p))
            let range = p.sliderRange(field)
            for i in 0..<10 {
                let position = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i + 1) / 11
                XCTAssertEqual(controller.setAirIfChanged(p, p.sliderValue(position, field)), .ok,
                               "\(p.field) tick \(i)")
                count += 1
                let json = engine.lightRigJSON()
                if json != last { changes += 1 }
                last = json
            }
        }
        engine.pythonTap = nil
        engine.commandTap = nil
        XCTAssertEqual(count, 50)
        XCTAssertEqual(changes, 50, "every tick must reach the rig")
        XCTAssertEqual(python.lines, [], "an air tick must run no Python (#610)")
        XCTAssertEqual(commands.lines, [], "an air tick must run no console command")
        XCTAssertEqual(engine.lightRig()?.lights, lightsBefore, "air ticks never change a light")
    }

    // MARK: mirroring with the command

    func testConsoleAtmosphereShowsInTheCard() throws {
        try enterWithThreeLights()
        engine.runCommand("atmosphere haze=0.3, dust=0.45")
        engine.panelPolled.send()   // the ~500 ms poll's refresh
        let state = try XCTUnwrap(AtmosphereCardState(controller))
        XCTAssertEqual(state.row(.haze)?.value, 0.3)
        XCTAssertEqual(state.row(.dust)?.value, 0.45)
        XCTAssertEqual(state.row(.haze)?.text, "0.30")
        XCTAssertEqual(state.row(.dust)?.text, "0.45")
        XCTAssertTrue(state.isOn)

        // Card -> command: what a card edit writes is what `atmosphere` reads.
        XCTAssertEqual(controller.setAir(.haze, 0.4), .ok)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-lat-cmd-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.runPython(
            "import json as _lat_json\n"
            + "from pymol import cmd as _lat_cmd\n"
            + "with open(r'''\(url.path)''', 'w', encoding='utf-8') as _lat_f:\n"
            + "    _lat_json.dump(_lat_cmd.atmosphere(quiet=1), _lat_f)\n")
        let printed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((printed["haze"] as? NSNumber)?.doubleValue, 0.4)
        XCTAssertEqual((printed["dust"] as? NSNumber)?.doubleValue, 0.45)
    }

    func testSwitchRunsTheCommandAndRestoresExactly() throws {
        try enterWithThreeLights()
        let before = try XCTUnwrap(engine.lightRigJSON())
        let commands = Lines()
        engine.commandTap = { commands.lines.append($0) }

        XCTAssertTrue(controller.setAtmosphere(on: false))
        XCTAssertEqual(try coreAir(), FakeRigStore.defaultAir, "Off: every air field at its table default")
        XCTAssertFalse(controller.airIsOn)
        XCTAssertNotNil(controller.airMemory)

        XCTAssertTrue(controller.setAtmosphere(on: true))
        engine.commandTap = nil
        XCTAssertEqual(commands.lines, [
            "atmosphere off",
            "atmosphere haze=0.1, dust=0.3, dust_size=0.5, dust_speed=2.0, scatter=-0.25, seed=7",
        ])
        XCTAssertEqual(engine.lightRigJSON(), before, "Off then On must restore the rig byte for byte")
        XCTAssertTrue(controller.airIsOn)
    }

    func testRevertRestoresTheEntryAir() throws {
        let entry = try enterWithThreeLights()
        XCTAssertEqual(controller.setAir(.haze, 0.9), .ok)
        XCTAssertEqual(controller.setAir(.scatter, 0.5), .ok)
        XCTAssertTrue(controller.setAtmosphere(on: false))
        XCTAssertTrue(controller.setAtmosphere(on: true))
        XCTAssertEqual(controller.setAir(.dustSpeed, 9.5), .ok)
        XCTAssertTrue(controller.canRevert)

        controller.revert()
        XCTAssertEqual(engine.lightRigJSON(), entry, "Revert must restore the entry air byte for byte")
        XCTAssertFalse(controller.canRevert)
    }

    func testDoneAndEscKeepTheAir() throws {
        try enterWithThreeLights()
        XCTAssertEqual(controller.setAir(.dust, 0.77), .ok)
        let afterEdit = engine.lightRigJSON()
        engine.setInteractionMode(.viewing)              // Done
        XCTAssertEqual(engine.lightRigJSON(), afterEdit, "Done keeps the air")

        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.setAtmosphere(on: false))
        let afterOff = engine.lightRigJSON()
        XCTAssertTrue(engine.exitActiveInteractionMode())  // Esc
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertEqual(engine.lightRigJSON(), afterOff, "Esc keeps the air (only Revert discards)")
        XCTAssertNil(controller.airMemory, "leaving the mode drops the switch's memory")
    }

    func testNoRigSwitchCreatesARigThatRevertRemoves() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.entryJSON, "null")
        XCTAssertNil(engine.lightRigJSON())
        let state = try XCTUnwrap(AtmosphereCardState(controller))
        XCTAssertTrue(state.canToggle)
        XCTAssertFalse(state.canEdit)
        XCTAssertEqual(state.hint, .noLights)

        let commands = Lines()
        engine.commandTap = { commands.lines.append($0) }
        XCTAssertTrue(controller.setAtmosphere(on: true))
        engine.commandTap = nil
        XCTAssertEqual(commands.lines, ["atmosphere haze=0.2, dust=0.5"])
        let rig = try XCTUnwrap(engine.lightRig(), "On must create a rig")
        XCTAssertFalse(rig.enabled, "the switch's rig is off")
        XCTAssertTrue(rig.lights.isEmpty, "and has no lights")
        XCTAssertEqual(rig.air.haze, 0.2)
        XCTAssertEqual(rig.air.dust, 0.5)
        XCTAssertTrue(controller.canEditAir)
        XCTAssertEqual(controller.setAir(.dust, 0.65), .ok)
        XCTAssertEqual(try coreAir().dust, 0.65)

        controller.revert()
        XCTAssertNil(engine.lightRigJSON(), "Revert must remove the rig the switch created")
        XCTAssertNil(controller.rig)
    }

    func testDocumentReplacementDropsTheAirMemory() throws {
        try enterWithThreeLights()
        XCTAssertTrue(controller.setAtmosphere(on: false))
        XCTAssertNotNil(controller.airMemory)
        // Only the hook runs, never the command: the shared host keeps its
        // objects and settings.
        engine.noteCommandForLightsMode("load x.pse")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertNil(controller.airMemory, "the old document's air must not come back in the new one")

        engine.setInteractionMode(.lights)
        XCTAssertNil(controller.airMemory)
        let commands = Lines()
        engine.commandTap = { commands.lines.append($0) }
        XCTAssertTrue(controller.setAtmosphere(on: true))
        engine.commandTap = nil
        XCTAssertEqual(commands.lines, ["atmosphere haze=0.2, dust=0.5"], "On uses the start look")
    }
}

#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import MetalKit

/// #685: on a dust-only tick, keep the last full live frame's pre-air image
/// and re-run only the post chain from the air pass on.
@MainActor
final class AirDustTickCacheTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var mtkView: MTKView!
    private var testWindow: NSWindow?
    private var savedExportRenderActive = false
    private var savedView: [Float]?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try LightsLive.requireEngine()
        savedExportRenderActive = engine.exportRenderActive
        engine.exportRenderActive = true
        savedView = engine.captureView()
        engine.runPython("""
        from pymol import cmd as _c
        _adt685_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'metal_light_air_time', 'metal_raytrace', 'metal_temporal_ao',
            'metal_exposure', 'metal_gpu_timing')}
        # Raster unless a test asks for ray tracing: with metal_raytrace and
        # metal_temporal_ao (both may be on in the host) the image is kept
        # only once the AO has settled (kAirCacheAOFrames).
        _c.set('metal_raytrace', 0)
        """)
        LightsLive.addPeptide()
        LightsLive.setRig(LightsLive.threeLights(enabled: true))

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 200, height: 150),
                           device: MTLCreateSystemDefaultDevice())
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.drawableSize = CGSize(width: 400, height: 300)
        self.mtkView = view

        let presented = engine.renderMetalFrame(view: view, width: 400, height: 300, airTick: false)
        if !presented {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
                               styleMask: .borderless,
                               backing: .buffered,
                               defer: false)
            win.contentView = view
            win.orderBack(nil)
            self.testWindow = win
            let retried = engine.renderMetalFrame(view: view, width: 400, height: 300, airTick: false)
            XCTAssertTrue(retried, "frame must present in hosted window")
        }
        waitForInFlight()
    }

    override func tearDown() {
        if let win = testWindow {
            win.orderOut(nil)
            win.contentView = nil
            testWindow = nil
        }
        mtkView = nil
        engine.runPython("""
        from pymol import cmd as _c
        for _n, _v in globals().pop('_adt685_settings', {}).items():
            _c.set(_n, _v)
        """)
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        engine.exportRenderActive = savedExportRenderActive
        LightsLive.tearDown()
        super.tearDown()
    }

    private func waitForInFlight() {
        let deadline = Date().addingTimeInterval(5.0)
        while engine.metalFramesInFlight > 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(engine.metalFramesInFlight, 0, "frames in flight did not retire within 5 s")
    }

    @discardableResult
    private func frame(airTick: Bool, width: Int = 400, height: Int = 300) -> Bool {
        let targetSize = CGSize(width: width, height: height)
        if mtkView.drawableSize != targetSize {
            mtkView.drawableSize = targetSize
        }
        let presented = engine.renderMetalFrame(view: mtkView, width: width, height: height, airTick: airTick)
        XCTAssertTrue(presented, "every frame the tests count must return presented == true")
        waitForInFlight()
        return presented
    }

    private func stats(forget: Bool = false) throws -> (scene: Int, post: Int, air: Int) {
        let out = NSTemporaryDirectory() + "issue_685_stats.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        res = _c._cmd.get_metal_air_cache_stats(_c._COb, \(forget ? 1 : 0))
        open(r'\(out)', 'w').write(f'{res[0]},{res[1]},{res[2]}' if res else 'none')
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no stats written")
        let parts = text.split(separator: ",")
        guard parts.count == 3,
              let s = Int(parts[0]),
              let p = Int(parts[1]),
              let a = Int(parts[2]) else {
            XCTFail("invalid stats format: \(text)")
            return (0, 0, 0)
        }
        return (s, p, a)
    }

    private func capture(_ name: String, airTick: Bool) throws -> [UInt8] {
        let path = NSTemporaryDirectory() + "issue_685_\(name).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.capturePNG(path)
        frame(airTick: airTick)
        let deadline = Date().addingTimeInterval(5.0)
        while !FileManager.default.fileExists(atPath: path) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "capturePNG file \(path) not created")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil), "no image source")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
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
        XCTAssertTrue(drawn)
        return rgba
    }

    private func settle() throws {
        var settled = false
        for _ in 0..<6 {
            let before = try stats().air
            frame(airTick: true)
            let after = try stats().air
            if after > before {
                settled = true
                break
            }
        }
        if !settled {
            XCTFail("settle failed: no dust-only frame within 6 frames")
        }
    }

    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return hash
    }

    private func isNonUniform(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let first = (bytes[0], bytes[1], bytes[2], bytes[3])
        for i in stride(from: 4, to: bytes.count, by: 4) {
            if (bytes[i], bytes[i+1], bytes[i+2], bytes[i+3]) != first {
                return true
            }
        }
        return false
    }

    private func readGpuMedian() throws -> Double {
        let out = NSTemporaryDirectory() + "issue_685_gpu_stats.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        stats = _c._cmd.get_gpu_frame_stats(_c._COb)
        med = stats.get('median', 0.0) if stats else 0.0
        open(r'\(out)', 'w').write(str(med))
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no gpu stats written")
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0
    }

    func testDustTickRunsOnlyThePostChain() throws {
        try settle()
        let s0 = try stats()
        frame(airTick: true)
        let s1 = try stats()
        XCTAssertEqual(s1.scene - s0.scene, 0)
        XCTAssertEqual(s1.post - s0.post, 1)
        XCTAssertEqual(s1.air - s0.air, 1)

        frame(airTick: false)
        let s2 = try stats()
        XCTAssertEqual(s2.scene - s1.scene, 1)
        XCTAssertEqual(s2.air - s1.air, 0)

        // A frame not rendered for the dust keeps no image (no copy during a
        // drag): the next tick is full and keeps one, the one after reuses it.
        frame(airTick: true)
        let s3 = try stats()
        XCTAssertEqual(s3.scene - s2.scene, 1, "the tick after a redisplay frame renders in full")
        frame(airTick: true)
        let s4 = try stats()
        XCTAssertEqual(s4.scene - s3.scene, 0)
        XCTAssertEqual(s4.air - s3.air, 1, "then the dust-only ticks resume")
    }

    func testChangesRenderAFullFrame() throws {
        try settle()

        let verifyChange: (@escaping () -> Void) throws -> Void = { [weak self] changeAction in
            guard let self = self else { return }
            changeAction()
            let s0 = try self.stats()
            self.frame(airTick: true)
            let s1 = try self.stats()
            XCTAssertEqual(s1.scene - s0.scene, 1, "change must force full frame")
            XCTAssertEqual(s1.air - s0.air, 0, "change must not be dust-only")
            try self.settle()
        }

        // Camera turn
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.turn('y', 10)")
        }

        // Object move
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.translate([1, 0, 0], 'lmt_pep')")
        }

        // Rep change
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.show('sticks')")
        }
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.hide('sticks')")
        }

        // A change that only calls SceneDirty (no redisplay request): the
        // title of a state. #666's ContentGeneration catches it.
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.set_title('lmt_pep', 1, 'adt685')")
        }

        // Setting change
        try verifyChange {
            self.engine.runPython("from pymol import cmd as _c\n_c.set('metal_exposure', 1.2)")
        }

        // Light change
        try verifyChange {
            self.engine.runPython("""
            from pymol import cmd as _c, lighting as _l
            rig = _l.get_lights(_self=_c)
            if rig and 'lights' in rig and len(rig['lights']) > 0:
                rig['lights'][0]['orbit'] = (rig['lights'][0].get('orbit', 0.0) + 15.0)
                _l.set_lights(rig, _self=_c)
            """)
        }

        // Resize
        let s0 = try stats()
        frame(airTick: true, width: 420, height: 300)
        let s1 = try stats()
        XCTAssertEqual(s1.scene - s0.scene, 1, "resize must force full frame")
        XCTAssertEqual(s1.air - s0.air, 0, "resize must not be dust-only")
        try settle()
    }

    func testDustTickMatchesAFullFrame() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_air_time', 1.25)")
        try settle()

        let s0 = try stats()
        let a = try capture("cached", airTick: true)
        let s1 = try stats()
        XCTAssertEqual(s1.air - s0.air, 1, "A must be dust-only")
        XCTAssertEqual(s1.scene - s0.scene, 0, "A must be dust-only")

        _ = try stats(forget: true)
        let b = try capture("full", airTick: true)
        let s2 = try stats()
        XCTAssertEqual(s2.scene, 1, "B must be full frame")

        XCTAssertEqual(a, b, "cached and full frame bytes must match byte for byte")
        XCTAssertTrue(isNonUniform(a), "the scene must have drawn (non-uniform)")
        let h = fnv1a(a)
        print(String(format: "685-dust-hash %016llx", h))
    }

    func testDustTickMatchesAFullFrameRayTraced() throws {
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_raytrace', 1)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_light_air_time', 1.25)
        """)
        try settle()

        let s0 = try stats()
        let a = try capture("cached_rt", airTick: true)
        let s1 = try stats()
        XCTAssertEqual(s1.air - s0.air, 1, "A must be dust-only")
        XCTAssertEqual(s1.scene - s0.scene, 0, "A must be dust-only")

        _ = try stats(forget: true)
        let b = try capture("full_rt", airTick: true)
        let s2 = try stats()
        XCTAssertEqual(s2.scene, 1, "B must be full frame")

        XCTAssertEqual(a, b, "cached and full RT frame bytes must match")
        XCTAssertTrue(isNonUniform(a), "the scene must have drawn (non-uniform)")
        let h = fnv1a(a)
        print(String(format: "685-dust-hash rt %016llx", h))
    }

    func testTemporalAOSettlesBeforeTheImageIsKept() throws {
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_raytrace', 1)
        _c.set('metal_temporal_ao', 1)
        _c.set('metal_light_air_time', 1.25)
        _c.turn('y', 15)
        """)
        _ = try stats(forget: true)

        // Every tick is full until a frame whose AO has accumulated
        // kAirCacheAOFrames (32) frames since the camera reset it was kept.
        var firstDustOnly = 0
        for tick in 1...60 {
            let sBefore = try stats()
            frame(airTick: true)
            let sAfter = try stats()
            if sAfter.air > sBefore.air {
                firstDustOnly = tick
                break
            }
            XCTAssertEqual(sAfter.scene - sBefore.scene, 1, "tick \(tick) must be full")
        }
        XCTAssertGreaterThan(firstDustOnly, 32, "the image was kept before the AO settled")
        XCTAssertLessThanOrEqual(firstDustOnly, 40, "temporal AO must settle and cache")
    }

    func testExportsRenderInFull() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_air_time', 1.25)")
        try settle()

        let p1 = NSTemporaryDirectory() + "issue_685_exp1.png"
        let p2 = NSTemporaryDirectory() + "issue_685_exp2.png"
        defer {
            try? FileManager.default.removeItem(atPath: p1)
            try? FileManager.default.removeItem(atPath: p2)
        }

        let s0 = try stats()
        engine.renderHiResPNG(p1, width: 400, height: 300, rayTraced: 0)
        let s1 = try stats()
        XCTAssertEqual(s1.scene - s0.scene, 1, "export must render scene")
        XCTAssertEqual(s1.air - s0.air, 0, "export is not an air-only frame")

        // The next frame(airTick: true) is full (scene +1)
        frame(airTick: true)
        let s2 = try stats()
        XCTAssertEqual(s2.scene - s1.scene, 1, "frame after export must be full")

        // Settle again so cache is valid
        try settle()
        let d1 = try XCTUnwrap(FileManager.default.contents(atPath: p1))

        _ = try stats(forget: true)
        engine.renderHiResPNG(p2, width: 400, height: 300, rayTraced: 0)
        let d2 = try XCTUnwrap(FileManager.default.contents(atPath: p2))

        XCTAssertEqual(d1, d2, "exports with and without valid cache must be byte-identical")
    }

    func testMovingDustChangesTheImageWithoutAScenePass() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_air_time', -1.0)")
        try settle()

        let s0 = try stats()
        let a = try capture("dust1", airTick: true)
        let s1 = try stats()
        XCTAssertEqual(s1.air - s0.air, 1, "frame 1 must be dust-only")
        XCTAssertEqual(s1.scene - s0.scene, 0, "frame 1 must skip scene")

        Thread.sleep(forTimeInterval: 0.15)

        let b = try capture("dust2", airTick: true)
        let s2 = try stats()
        XCTAssertEqual(s2.air - s1.air, 1, "frame 2 must be dust-only")
        XCTAssertEqual(s2.scene - s1.scene, 0, "frame 2 must skip scene")

        XCTAssertNotEqual(a, b, "dust movement must change image bytes")
    }

    func testGpuTimePerTick() throws {
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_raytrace', 1)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_gpu_timing', 1)
        """)

        // Render 20 full ticks
        for _ in 0..<20 {
            _ = try stats(forget: true)
            frame(airTick: true)
        }
        let fullMedian = try readGpuMedian()

        // Clear the store: the renderer takes the mode per frame, so a frame
        // must see 0 before the next one sees 1 again.
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_gpu_timing', 0)")
        frame(airTick: false)
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_gpu_timing', 1)")
        try settle()

        // Render 20 dust-only ticks
        for _ in 0..<20 {
            frame(airTick: true)
        }
        let dustMedian = try readGpuMedian()

        print("685-gpu-ms full=\(fullMedian) dust=\(dustMedian)")
        XCTAssertGreaterThan(fullMedian, 0.0, "full median must be > 0")
        XCTAssertGreaterThan(dustMedian, 0.0, "dust median must be > 0")
        XCTAssertLessThan(dustMedian, fullMedian, "a dust-only tick must cost less GPU time")
    }
}
#endif

/// Classic shadow-map impostor casters face the light (#665). The classic
/// pre-pass used to draw sphere and cylinder impostors as billboards facing the
/// camera, so with the key light (`light`) far from the view axis they cast a
/// sliver or nothing. Here the light comes from +x, nearly perpendicular to the
/// view: a sphere, or a stick, on the light's side of a big sphere must darken
/// the big sphere's light-facing side. Source pins: lighting_shadow_msl.py,
/// TestClassicShadowCastersFaceTheLight.
final class ClassicShadowImpostorCasterTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "_c.delete('cs665r or cs665c')\n"
                + "_c.set('metal_shadows', globals().pop('_cs665_shadows', 1))\n"
                + "_c.set('bg_rgb', globals().pop('_cs665_bg', [0.0, 0.0, 0.0]))\n"
                + "_c.set('light', globals().pop('_cs665_light', [-0.4, -0.4, -1.0]))\n"
                + "_c.set('orthoscopic', globals().pop('_cs665_ortho', 0))\n"
                + "_cs665_rig = globals().pop('_cs665_rig', None)\n"
                + "if _cs665_rig is not None:\n"
                + "    _c.set_lights(_cs665_rig)\n"
                + "for _n in globals().pop('_cs665_enabled', []):\n"
                + "    _c.enable(_n)\n")
            sceneBuilt = false
        }
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        super.tearDown()
    }

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            throw XCTSkip("the PyMOL engine did not come up under the test host")
        }
    }

    /// A big sphere (radius 6 A at x = -6) and a caster of radius 5 at x = 8:
    /// a sphere, or a stick nearly along the view axis. `light` [-1, 0, 0.1]
    /// puts the light at +x, slightly behind the view plane, so the caster
    /// shadows the big sphere's visible light-facing side. `overhead` turns
    /// the sphere scene a quarter turn: the big sphere at the origin, the
    /// caster at y = 14 and the light straight above (`light` [0, -1, 0]).
    /// Shadows start OFF, as in ClassicShadowMapLazyTests.
    private func buildScene(stick: Bool, overhead: Bool = false) {
        savedView = engine.captureView()
        sceneBuilt = true
        var py = "from pymol import cmd as _c\n"
        py += "_cs665_enabled = _c.get_names('objects', enabled_only=1)\n"
        py += "_cs665_bg = list(_c.get_setting_tuple('bg_rgb')[1])\n"
        py += "_cs665_shadows = _c.get_setting_int('metal_shadows')\n"
        py += "_cs665_light = list(_c.get_setting_tuple('light')[1])\n"
        py += "_cs665_ortho = _c.get_setting_int('orthoscopic')\n"
        py += "_cs665_rig = _c.get_lights()\n"
        py += "_c.set_lights(None)\n"
        py += "_c.set('metal_shadows', 0)\n"
        py += "for _n in _cs665_enabled:\n"
        py += "    _c.disable(_n)\n"
        py += "_c.pseudoatom('cs665r', pos=\(overhead ? "[0.0, 0.0, 0.0]" : "[-6.0, 0.0, 0.0]"), vdw=1.0)\n"
        py += "_c.show_as('spheres', 'cs665r')\n"
        py += "_c.set('sphere_scale', 6.0, 'cs665r')\n"
        if stick {
            py += "_c.pseudoatom('cs665c', name='A', pos=[8.0, -1.5, -8.0], vdw=1.0)\n"
            py += "_c.pseudoatom('cs665c', name='B', pos=[8.0, 1.5, 8.0], vdw=1.0)\n"
            py += "_c.bond('cs665c and name A', 'cs665c and name B')\n"
            py += "_c.show_as('sticks', 'cs665c')\n"
            py += "_c.set('stick_radius', 5.0, 'cs665c')\n"
        } else {
            py += "_c.pseudoatom('cs665c', pos=\(overhead ? "[0.0, 14.0, 0.0]" : "[8.0, 0.0, 0.0]"), vdw=1.0)\n"
            py += "_c.show_as('spheres', 'cs665c')\n"
            py += "_c.set('sphere_scale', 5.0, 'cs665c')\n"
        }
        py += "_c.color('white', 'cs665r or cs665c')\n"
        py += "_c.set('bg_rgb', [0.0, 0.0, 0.0])\n"
        py += "_c.set('light', \(overhead ? "[0.0, -1.0, 0.0]" : "[-1.0, 0.0, 0.1]"))\n"
        py += "_c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 40.0, 100.0, -20.0))\n"
        if stick {
            // After set_view, which carries the projection: the orthographic
            // camera's rays run nearly along the stick.
            py += "_c.set('orthoscopic', 1)\n"
        }
        engine.runPython(py)
    }

    private func render(shadows: Bool) throws -> (rgba: [UInt8], width: Int, height: Int) {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', \(shadows ? 1 : 0))")
        let png = NSTemporaryDirectory() + "issue_665_\(shadows ? "on" : "off").png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
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
        XCTAssertTrue(drawn)
        return (rgba, w, h)
    }

    /// The mean of (r + g + b) / 3 over a box on the big sphere, in each image:
    /// `along` (toward the light) and `across` in Angstrom from its centre.
    /// The sphere is the first lit run (black background, 12 A wide) of the
    /// shadows-off image's middle row from the left, or with `overhead` (the
    /// light above) of its middle column from the bottom.
    private func lightFacingSide(
        _ off: (rgba: [UInt8], width: Int, height: Int),
        _ on: (rgba: [UInt8], width: Int, height: Int),
        along: (Double, Double) = (3.5, 5.0), across: (Double, Double) = (-1.5, 1.5),
        overhead: Bool = false
    ) throws -> (off: Double, on: Double) {
        let w = off.width, h = off.height
        let steps = overhead ? h : w
        // The scan's i-th pixel: left to right on the middle row, or bottom to
        // top on the middle column.
        let pixel = { (i: Int) -> Int in
            overhead ? ((h - 1 - i) * w + w / 2) * 4 : ((h / 2) * w + i) * 4
        }
        var L = -1
        var R = -1
        for x in 0..<steps {
            let offset = pixel(x)
            let r = off.rgba[offset]
            let g = off.rgba[offset + 1]
            let b = off.rgba[offset + 2]
            let maxVal = max(r, max(g, b))
            if L == -1 {
                if maxVal > 4 {
                    L = x
                }
            } else {
                if maxVal <= 4 {
                    R = x
                    break
                }
            }
        }
        if L != -1 && R == -1 {
            R = w
        }
        guard L != -1, R != -1 else {
            XCTFail("the big sphere was not found on the middle row")
            return (0.0, 0.0)
        }
        XCTAssertGreaterThan(R - L, 80, "the big sphere is not on the middle row")
        let k = Double(R - L) / 12.0
        let centre = Double(L + R) / 2.0  // along the scan
        let colRange: Range<Int>, rowRange: Range<Int>
        if overhead {
            let cx = Double(w) / 2.0, cy = Double(h) - centre  // rows run down
            colRange = Int(cx + across.0 * k)..<Int(cx + across.1 * k)
            rowRange = Int(cy - along.1 * k)..<Int(cy - along.0 * k)
        } else {
            let cx = centre, cy = Double(h) / 2.0
            colRange = Int(cx + along.0 * k)..<Int(cx + along.1 * k)
            rowRange = Int(cy - across.1 * k)..<Int(cy - across.0 * k)  // +y is up
        }

        func meanBrightness(in img: (rgba: [UInt8], width: Int, height: Int)) -> Double {
            var sum = 0.0
            var count = 0
            for y in rowRange {
                guard y >= 0 && y < img.height else { continue }
                for x in colRange {
                    guard x >= 0 && x < img.width else { continue }
                    let idx = (y * img.width + x) * 4
                    let r = Double(img.rgba[idx])
                    let g = Double(img.rgba[idx + 1])
                    let b = Double(img.rgba[idx + 2])
                    sum += (r + g + b) / 3.0
                    count += 1
                }
            }
            return count > 0 ? sum / Double(count) : 0.0
        }

        let offMean = meanBrightness(in: off)
        let onMean = meanBrightness(in: on)
        return (off: offMean, on: onMean)
    }

    func testSphereCasterShadowsTheLightFacingSide() throws {
        try requireEngine()
        buildScene(stick: false)
        let offImg = try render(shadows: false)
        let onImg = try render(shadows: true)
        let (off, on) = try lightFacingSide(offImg, onImg)
        print("665-sphere lit=\(off) shadowed=\(on)")
        XCTAssertGreaterThan(off, 60, "the box is not on the lit side of the big sphere")
        XCTAssertGreaterThanOrEqual(off - on, 30, "the sphere casts no shadow on the light-facing side")
    }

    /// The stick runs nearly along the (orthographic) view axis. Cast with
    /// the camera's rays, it darkened only a ragged strip of the big sphere
    /// around y = 0; from the light it shadows a band about 10 A wide, so the
    /// boxes 2 to 3 A above and below the middle row are in its shadow.
    func testStickCasterShadowsTheLightFacingSide() throws {
        try requireEngine()
        buildScene(stick: true)
        let offImg = try render(shadows: false)
        let onImg = try render(shadows: true)
        for ys in [(2.0, 3.0), (-3.0, -2.0)] {
            let (off, on) = try lightFacingSide(offImg, onImg, along: (3.5, 4.5), across: ys)
            print("665-stick y=\(ys) lit=\(off) shadowed=\(on)")
            XCTAssertGreaterThan(off, 60, "the box at y=\(ys) is not on the lit side of the big sphere")
            XCTAssertGreaterThanOrEqual(off - on, 30, "the stick casts no shadow on the light-facing side at y=\(ys)")
        }
    }

    /// A light straight above (`light` [0, -1, 0]) made the classic light
    /// view NaN: lookAt's up (+y) was parallel to the light. The caster above
    /// the big sphere must shadow its top.
    func testOverheadLightCastsTheSphereShadow() throws {
        try requireEngine()
        buildScene(stick: false, overhead: true)
        let offImg = try render(shadows: false)
        let onImg = try render(shadows: true)
        let (off, on) = try lightFacingSide(offImg, onImg, overhead: true)
        print("665-overhead lit=\(off) shadowed=\(on)")
        XCTAssertGreaterThan(off, 60, "the box is not on the lit top of the big sphere")
        XCTAssertGreaterThanOrEqual(off - on, 30, "a light straight above casts no shadow")
    }
}
