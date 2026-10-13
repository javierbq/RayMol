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
                                              .dustSpeed: 3.45, .scatter: -0.42,
                                              .dustGlow: 2.5, .dustOpacity: 0.4]
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
        // 7 fields x 10 slider ticks. No run-loop pumping in the loop, so the
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
        XCTAssertEqual(count, 70)
        XCTAssertEqual(changes, 70, "every tick must reach the rig")
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

        // #810: console dust_glow and dust_opacity show in the card
        engine.runCommand("atmosphere dust_glow=2, dust_opacity=0.5")
        engine.panelPolled.send()
        let stateGlow = try XCTUnwrap(AtmosphereCardState(controller))
        XCTAssertEqual(stateGlow.row(.dustGlow)?.value, 2.0)
        XCTAssertEqual(stateGlow.row(.dustOpacity)?.value, 0.5)
        XCTAssertEqual(stateGlow.row(.dustGlow)?.text, "2.00")
        XCTAssertEqual(stateGlow.row(.dustOpacity)?.text, "0.50")

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
        XCTAssertEqual(controller.setAir(.dustGlow, 2.5), .ok)
        XCTAssertEqual(controller.setAir(.dustOpacity, 0.75), .ok)
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

/// Issue #663: bezier tube cartoons cast and receive studio shadows.
@MainActor
final class BezierTubeStudioShadowTests: XCTestCase {
    // Image boxes (x0, y0, x1, y1; row 0 at the top) of the 400 x 300
    // render. castBox: on the sphere, inside the band the tube shadows and
    // clear of the tube itself. receiveBox: on the tube, inside the
    // occluder's shadow and clear of the occluder itself.
    private static let castBox = (x0: 190, y0: 110, x1: 210, y1: 130)
    private static let receiveBox = (x0: 190, y0: 143, x1: 210, y1: 157)

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('bt663*')
            _c.set('metal_shadows', globals().pop('_bt663_shadows', 1))
            _c.set('metal_raytrace', globals().pop('_bt663_raytrace', 0))
            _c.set('bg_rgb', globals().pop('_bt663_bg', [0.0, 0.0, 0.0]))
            _c.set_lights(globals().pop('_bt663_rig', None))
            for _n in globals().pop('_bt663_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _bt663_enabled = _c.get_names('objects', enabled_only=1)
        _bt663_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _bt663_shadows = _c.get_setting_int('metal_shadows')
        _bt663_raytrace = _c.get_setting_int('metal_raytrace')
        _bt663_rig = _c.get_lights()
        for _n in _bt663_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('metal_raytrace', 0)
        _c.set('metal_shadows', 1)
        # Explicit centre and size: adding or removing an object must not move the light.
        _c.set_lights({'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0,
                                   'pitch': 20.0, 'shadow': True}]})
        """)
    }

    /// The fixed camera, set after the objects exist: loading the first
    /// object auto-zooms, which would replace the view (and its clipping).
    private func frameScene() {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func passes(forget: Bool = false) throws -> Int {
        let out = NSTemporaryDirectory() + "issue_663_passes.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        open(r'\(out)', 'w').write(str(_c._cmd.get_light_shadow_map_passes(_c._COb, \(forget ? 1 : 0))))
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no readout written")
        return try XCTUnwrap(Int(text))
    }

    private func render() throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_663_render.png"
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
        return rgba
    }

    private func differs(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var diff = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                diff += 1
            }
        }
        return diff
    }

    private func boxMean(_ px: [UInt8], x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        guard x1 > x0 && y1 > y0 else { return 0.0 }
        let width = 400
        var total = 0.0
        var count = 0
        for y in y0..<y1 {
            let rowOffset = y * width * 4
            for x in x0..<x1 {
                let i = rowOffset + x * 4
                guard i + 2 < px.count else { continue }
                let r = Double(px[i])
                let g = Double(px[i + 1])
                let b = Double(px[i + 2])
                total += (r + g + b) / 3.0
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0.0
    }

    func testTubeCastsAStudioShadow() throws {
        try requireEngine()
        buildScene()
        engine.runPython("""
        from pymol import cmd as _c, cgo
        _c.pseudoatom('bt663s', pos=[0.0, 0.0, 0.0], vdw=1.0)
        _c.show_as('spheres', 'bt663s')
        _c.color('white', 'bt663s')
        _c.set('sphere_scale', 6.0, 'bt663s')
        obj = [cgo.COLOR, 1.0, 1.0, 1.0,
               cgo.BEZIER,
               -12.0, 5.1, 12.2,
               -4.0, 5.1, 12.2,
               4.0, 5.1, 12.2,
               12.0, 5.1, 12.2]
        _c.load_cgo(obj, 'bt663t')
        _c.set('cartoon_tube_radius', 1.5, 'bt663t')
        _c.disable('bt663t')
        """)
        frameScene()
        let without = try render()
        engine.runPython("from pymol import cmd as _c\n_c.enable('bt663t')")
        let withTube = try render()
        let b = Self.castBox
        let meanWithout = boxMean(without, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
        let meanWith = boxMean(withTube, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
        XCTAssertGreaterThanOrEqual(
            meanWithout - meanWith, 20.0,
            "tube must cast a shadow onto the sphere (mean without=\(meanWithout), with=\(meanWith))")

        _ = try passes(forget: true)
        let uncached = try render()
        XCTAssertTrue(
            uncached == withTube,
            "uncached frame differs from cached in \(differs(uncached, withTube)) pixels")
    }

    func testTubeReceivesAStudioShadow() throws {
        try requireEngine()
        buildScene()
        engine.runPython("""
        from pymol import cmd as _c, cgo
        obj = [cgo.COLOR, 1.0, 1.0, 1.0,
               cgo.BEZIER,
               -12.0, 0.0, 0.0,
               -4.0, 0.0, 0.0,
               4.0, 0.0, 0.0,
               12.0, 0.0, 0.0]
        _c.load_cgo(obj, 'bt663r')
        _c.set('cartoon_tube_radius', 2.0, 'bt663r')
        _c.pseudoatom('bt663o', pos=[-5.6, 4.1, 9.7], vdw=1.0)
        _c.show_as('spheres', 'bt663o')
        _c.color('white', 'bt663o')
        _c.set('sphere_scale', 2.5, 'bt663o')
        _c.disable('bt663o')
        """)
        frameScene()
        let unoccluded = try render()
        engine.runPython("from pymol import cmd as _c\n_c.enable('bt663o')")
        let occluded = try render()
        let b = Self.receiveBox
        let meanUnoccluded = boxMean(unoccluded, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
        let meanOccluded = boxMean(occluded, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
        XCTAssertGreaterThanOrEqual(
            meanUnoccluded - meanOccluded, 20.0,
            "tube must receive a shadow from the sphere (mean unoccluded=\(meanUnoccluded), occluded=\(meanOccluded))")
    }
}

/// Issue #714: glass under a shadowed studio key, and glass in the tracer.
/// lighting_615.json's glass_surface_sh_* and glass_surface_*_rt1 rows show a
/// glass surface alone, so they match their unshadowed and rt0 twins byte for
/// byte: transparent geometry draws nothing into the studio shadow maps (the
/// pre-pass is opaque only, SceneRenderLightShadowMaps) and, at
/// metal_rt_transparent 0, is not in the ray-traced scene. Here an opaque
/// sphere gives each path something to show in the glass:
/// - the sphere stands between the shadowed key and the glass, so the glass
///   must receive the sphere's studio shadow;
/// - the glass stands in front of the sphere, from the camera and from the
///   key, so with metal_rt_transparent 1 it must occlude the sphere in the
///   traced AO, seen through the glass.
@MainActor
final class GlassStudioShadowAndTracerTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('gs714*')
            for _n, _v in globals().pop('_gs714_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_gs714_rig', None))
            for _n in globals().pop('_gs714_enabled', []):
                _c.enable(_n)
            """)
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

    /// A grey80 glass surface (gs714g: one pseudoatom's surface) and an opaque
    /// grey80 sphere (gs714s), on black, under one shadowed camera key at
    /// orbit -30, pitch 20 (front, left and above), with an explicit centre
    /// and size so the objects never move the light. Studio shadows start
    /// off; ray tracing is chosen per render.
    private func buildScene(glassAt glass: String, glassVdw: Double,
                            sphereAt sphere: String, sphereScale: Double) {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _gs714_enabled = _c.get_names('objects', enabled_only=1)
        _gs714_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_rt_transparent',
            'metal_temporal_ao', 'metal_rt_ao_intensity', 'metal_rt_ao_radius')}
        _gs714_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _gs714_rig = _c.get_lights()
        for _n in _gs714_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_shadows', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('metal_temporal_ao', 0)
        _c.pseudoatom('gs714s', pos=\(sphere), vdw=1.0)
        _c.show_as('spheres', 'gs714s')
        _c.set('sphere_scale', \(sphereScale), 'gs714s')
        _c.pseudoatom('gs714g', pos=\(glass), vdw=\(glassVdw))
        _c.show_as('surface', 'gs714g')
        _c.set('surface_material', 'glass', 'gs714g')
        _c.color('grey80', 'gs714s or gs714g')
        _c.set_lights({'enabled': True, 'ambient': 0.06, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': True}]})
        # The fixed camera, after the objects: the first object auto-zooms.
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_714_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    /// The pixels `name` covers: a render with only that object shown, where
    /// any channel is above the black background's noise.
    private func footprint(of name: String) throws -> [Bool] {
        let other = name == "gs714g" ? "gs714s" : "gs714g"
        engine.runPython("from pymol import cmd as _c\n_c.disable('\(other)')")
        let px = try render(rayTraced: 0)
        engine.runPython("from pymol import cmd as _c\n_c.enable('\(other)')")
        return stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) > 3 }
    }

    /// The largest per-channel difference between two renders over `region`.
    private func maxDelta(_ a: [UInt8], _ b: [UInt8], in region: [Bool]) -> Int {
        guard a.count == b.count, a.count == region.count * 4 else { return -1 }
        var best = 0
        for (p, inside) in region.enumerated() where inside {
            for c in 0..<3 {
                best = max(best, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c])))
            }
        }
        return best
    }

    /// The sphere (radius 2.5) sits on the key's line in front of the glass
    /// (radius 6), as in BezierTubeStudioShadowTests' receive case: turning
    /// the studio shadows on must darken the glass where the sphere shadows
    /// it. The region is the glass's footprint minus the sphere's.
    func testGlassReceivesTheStudioShadow() throws {
        try requireEngine()
        buildScene(glassAt: "[0.0, 0.0, 0.0]", glassVdw: 6.0,
                   sphereAt: "[-5.6, 4.1, 9.7]", sphereScale: 2.5)
        let glass = try footprint(of: "gs714g")
        let sphere = try footprint(of: "gs714s")
        let region = zip(glass, sphere).map { $0 && !$1 }
        XCTAssertGreaterThan(region.filter { $0 }.count, 5000, "the glass is not in the frame")
        let off = try render(rayTraced: 0)
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', 1)")
        let on = try render(rayTraced: 0)
        let delta = maxDelta(off, on, in: region)
        print("714-shadow glass max delta=\(delta)")
        XCTAssertGreaterThanOrEqual(delta, 10, "the glass receives no studio shadow from the sphere")
    }

    /// The glass (radius 5) in front of the sphere (radius 6), the key shadowed
    /// and metal_rt_transparent 1: the ray-traced render must differ from the
    /// raster one inside the glass's footprint, and from the ray-traced render
    /// at metal_rt_transparent 0, so the difference is the glass in the tracer
    /// (a lone convex sphere occludes nothing). The traced AO is turned up
    /// (intensity 1, radius 8 A): at the defaults, glass (alpha 0.15) moves
    /// the sphere behind it by about 7 levels.
    func testGlassEntersTheTracer() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene(glassAt: "[0.0, 0.0, 9.0]", glassVdw: 5.0,
                   sphereAt: "[0.0, 0.0, 0.0]", sphereScale: 6.0)
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_shadows', 1)
        _c.set('metal_rt_ao_intensity', 1.0)
        _c.set('metal_rt_ao_radius', 8.0)
        """)
        let glass = try footprint(of: "gs714g")
        XCTAssertGreaterThan(glass.filter { $0 }.count, 5000, "the glass is not in the frame")
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_rt_transparent', 1)")
        let rt0 = try render(rayTraced: 0)
        let rt1 = try render(rayTraced: 1)
        let again = try render(rayTraced: 1)
        guard maxDelta(rt1, again, in: glass) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_rt_transparent', 0)")
        let opaqueOnly = try render(rayTraced: 1)
        let traced = maxDelta(rt0, rt1, in: glass)
        let byGlass = maxDelta(opaqueOnly, rt1, in: glass)
        print("714-rt glass max delta rt1-rt0=\(traced) transparent1-0=\(byGlass)")
        XCTAssertGreaterThanOrEqual(traced, 10, "rt1 and rt0 match in the glass at metal_rt_transparent 1")
        XCTAssertGreaterThanOrEqual(byGlass, 10, "the glass is not in the ray-traced scene")
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
            R = steps
        }
        guard L != -1, R != -1 else {
            XCTFail("the big sphere was not found on the scanned line")
            return (0.0, 0.0)
        }
        XCTAssertGreaterThan(R - L, 80, "the big sphere is not on the scanned line")
        let k = Double(R - L) / 12.0
        let centre = Double(L + R) / 2.0  // along the scan
        let colRange: Range<Int>, rowRange: Range<Int>
        if overhead {
            let cx = Double(w) / 2.0, cy = Double(h - 1) - centre  // scan i is row h - 1 - i
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

/// Issue #664: Traced reflection hits ignore studio shadows.
/// At `metal_raytrace 1`, `rt_composite` traces a reflection ray per reflective
/// pixel. When the studio light rig is on, reflected hit points receive the
/// studio shadows under `kRTLightShadow` so a metallic mirror shows reflected
/// geometry darkened by the studio shadow as it is in the raster image.
@MainActor
final class ReflectionStudioShadowTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('rs664*')
            for _n, _v in globals().pop('_rs664_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_rs664_rig', None))
            for _n in globals().pop('_rs664_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene(shadow: Bool) {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _rs664_enabled = _c.get_names('objects', enabled_only=1)
        _rs664_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_rt_transparent',
            'metal_temporal_ao', 'metal_rt_ao_intensity', 'metal_rt_ao_radius')}
        _rs664_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _rs664_rig = _c.get_lights()
        for _n in _rs664_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_shadows', 1)
        _c.set('metal_rt_transparent', 0)

        # Mirror sphere: metallic, reflect 1.0, tint 0.0, rough 0.0
        _c.pseudoatom('rs664m', pos=[4.0, 0.0, 0.0], vdw=4.5)
        _c.show_as('spheres', 'rs664m')
        _c.set('sphere_material', 'metallic', 'rs664m')
        _c.set('sphere_material_reflect', 1.0, 'rs664m')
        _c.set('sphere_material_tint', 0.0, 'rs664m')
        _c.set('sphere_material_rough', 0.0, 'rs664m')

        # Target sphere: grey80
        _c.pseudoatom('rs664t', pos=[-4.0, 0.0, -2.0], vdw=3.5)
        _c.show_as('spheres', 'rs664t')
        _c.color('grey80', 'rs664t')

        # Caster sphere between key light and target
        _c.pseudoatom('rs664c', pos=[-7.3, 2.4, 3.7], vdw=2.2)
        _c.show_as('spheres', 'rs664c')
        _c.color('grey80', 'rs664c')

        _c.set_lights({'enabled': True, 'ambient': 0.06, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': \(shadow ? "True" : "False")}]})

        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func setLightShadow(_ shadow: Bool) {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_lights({'enabled': True, 'ambient': 0.06, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': \(shadow ? "True" : "False")}]})
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_664_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func footprint(of name: String) throws -> [Bool] {
        let others = ["rs664m", "rs664t", "rs664c"].filter { $0 != name }
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.disable('\(other)')")
        }
        let px = try render(rayTraced: 0)
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.enable('\(other)')")
        }
        return stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) > 3 }
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8], in region: [Bool]) -> Int {
        guard a.count == b.count, a.count == region.count * 4 else { return -1 }
        var best = 0
        for (p, inside) in region.enumerated() where inside {
            for c in 0..<3 {
                best = max(best, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c])))
            }
        }
        return best
    }

    func testReflectionStudioShadow() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene(shadow: true)

        let mirror = try footprint(of: "rs664m")
        let target = try footprint(of: "rs664t")
        let caster = try footprint(of: "rs664c")

        var minX = Self.width, maxX = 0, minY = Self.height, maxY = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                if mirror[y * Self.width + x] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        XCTAssertGreaterThan(maxX - minX, 40, "mirror sphere not found in frame")

        // Rectangular box inside mirror footprint on the side where the target reflection shows
        let boxMinX = minX + (maxX - minX) / 8
        let boxMaxX = minX + (maxX - minX) * 4 / 8
        let boxMinY = minY + (maxY - minY) / 4
        let boxMaxY = maxY - (maxY - minY) / 4

        var box = [Bool](repeating: false, count: Self.width * Self.height)
        for y in boxMinY...boxMaxY {
            for x in boxMinX...boxMaxX {
                let idx = y * Self.width + x
                box[idx] = mirror[idx] && !target[idx] && !caster[idx]
            }
        }
        let boxCount = box.filter { $0 }.count
        XCTAssertGreaterThan(boxCount, 100, "the box region inside the mirror is too small: \(boxCount)")

        // Determinism skip: two rt1 renders with the same settings must match in the box
        let rt1On1 = try render(rayTraced: 1)
        let rt1On2 = try render(rayTraced: 1)
        guard maxDelta(rt1On1, rt1On2, in: box) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }

        // Render four images
        let rt1ShadowOn = rt1On1
        setLightShadow(false)
        let rt1ShadowOff = try render(rayTraced: 1)
        let rt0ShadowOff = try render(rayTraced: 0)
        setLightShadow(true)
        let rt0ShadowOn = try render(rayTraced: 0)

        let rt1Delta = maxDelta(rt1ShadowOn, rt1ShadowOff, in: box)
        let rt0Delta = maxDelta(rt0ShadowOn, rt0ShadowOff, in: box)
        print("664 rt1 delta=\(rt1Delta) rt0 delta=\(rt0Delta)")

        XCTAssertGreaterThanOrEqual(rt1Delta, 20, "the traced reflection ignores the studio shadow")
        XCTAssertLessThanOrEqual(rt0Delta, 3, "rt0 mirror changes with studio shadow")
    }
}

/// Issue #729: Traced metallic reflection tint loses surface hue under HDR.
/// Under an HDR light rig (kRTLightRig && kLightHdr), the metallic reflection tint
/// in rt_composite scales down by its largest channel to at most 1 instead of clamping
/// each channel individually. This preserves the surface's chroma near highlights
/// rather than washing out toward white.
@MainActor
final class ReflectionHdrTintTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('rt729*')
            for _n, _v in globals().pop('_rt729_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_rt729_rig', None))
            for _n in globals().pop('_rt729_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _rt729_enabled = _c.get_names('objects', enabled_only=1)
        _rt729_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_rt_transparent',
            'metal_temporal_ao', 'metal_rt_ao_intensity', 'metal_rt_ao_radius',
            'metal_light_hdr')}
        _rt729_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _rt729_rig = _c.get_lights()
        for _n in _rt729_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('metal_light_hdr', 1)

        # Mirror sphere: metallic, reflect 1.0, tint 1.0, rough 0.0
        _c.pseudoatom('rt729m', pos=[4.0, 0.0, 0.0], vdw=4.5)
        _c.show_as('spheres', 'rt729m')
        _c.set_color('rt729gold', [1.0, 0.8, 0.3])
        _c.color('rt729gold', 'rt729m')
        _c.set('sphere_material', 'metallic', 'rt729m')
        _c.set('sphere_material_reflect', 1.0, 'rt729m')
        _c.set('sphere_material_tint', 1.0, 'rt729m')
        _c.set('sphere_material_rough', 0.0, 'rt729m')

        # Target sphere: grey80
        _c.pseudoatom('rt729t', pos=[-4.0, 0.0, -2.0], vdw=3.5)
        _c.show_as('spheres', 'rt729t')
        _c.color('grey80', 'rt729t')

        _c.set_lights({'enabled': True, 'ambient': 0.3, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': False,
                                   'intensity': 3.0}]})

        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_729_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func footprint(of name: String) throws -> [Bool] {
        let others = ["rt729m", "rt729t"].filter { $0 != name }
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.disable('\(other)')")
        }
        let px = try render(rayTraced: 0)
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.enable('\(other)')")
        }
        return stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) > 3 }
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8], in region: [Bool]) -> Int {
        guard a.count == b.count, a.count == region.count * 4 else { return -1 }
        var best = 0
        for (p, inside) in region.enumerated() where inside {
            for c in 0..<3 {
                best = max(best, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c])))
            }
        }
        return best
    }

    func testTracedMetallicTintKeepsHueUnderHdr() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()

        let mirror = try footprint(of: "rt729m")
        let rt0 = try render(rayTraced: 0)
        let rt1a = try render(rayTraced: 1)
        let rt1b = try render(rayTraced: 1)
        guard maxDelta(rt1a, rt1b, in: mirror) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let rt1 = rt1a

        func chroma(_ r: Double, _ g: Double, _ b: Double) -> Double {
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            guard maxC > 0.0 else { return 0.0 }
            return (maxC - minC) / maxC
        }

        var sumRatio = 0.0
        var n = 0
        for (p, inside) in mirror.enumerated() where inside {
            let r0 = Double(rt0[p * 4])
            let g0 = Double(rt0[p * 4 + 1])
            let b0 = Double(rt0[p * 4 + 2])
            let max0 = max(r0, g0, b0)
            guard max0 >= 160.0 else { continue }

            let r1 = Double(rt1[p * 4])
            let g1 = Double(rt1[p * 4 + 1])
            let b1 = Double(rt1[p * 4 + 2])
            let max1 = max(r1, g1, b1)
            guard max1 >= 60.0 else { continue }

            let c0 = chroma(r0, g0, b0)
            guard c0 >= 0.2 else { continue }

            let c1 = chroma(r1, g1, b1)
            sumRatio += c1 / c0
            n += 1
        }
        let ratio = n > 0 ? sumRatio / Double(n) : 0.0
        print("729 pixels=\(n) ratio=\(ratio)")
        XCTAssertGreaterThanOrEqual(n, 200)
        XCTAssertGreaterThanOrEqual(ratio, 0.85, "the traced metallic reflection lost the surface's hue under HDR")
    }
}

/// #739: Metal fast-math bit-test NaN guards drop non-finite air terms.
@MainActor
final class FiniteGuardLiveTests: XCTestCase {
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
        _fg739_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'metal_light_air_time', 'metal_raytrace', 'metal_temporal_ao',
            'metal_light_hdr', 'metal_exposure')}
        _c.set('metal_raytrace', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_light_air_time', 1.25)
        """)
        LightsLive.addPeptide()

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
        engine.runPython("""
        from pymol import cmd as _c
        _c._cmd.set_metal_air_debug_poison(_c._COb, 0)
        """)
        if let win = testWindow {
            win.orderOut(nil)
            win.contentView = nil
            testWindow = nil
        }
        mtkView = nil
        engine.runPython("""
        from pymol import cmd as _c
        for _n, _v in globals().pop('_fg739_settings', {}).items():
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
    private func frame(airTick: Bool = false, width: Int = 400, height: Int = 300) -> Bool {
        let targetSize = CGSize(width: width, height: height)
        if mtkView.drawableSize != targetSize {
            mtkView.drawableSize = targetSize
        }
        let presented = engine.renderMetalFrame(view: mtkView, width: width, height: height, airTick: airTick)
        XCTAssertTrue(presented, "every frame the tests count must return presented == true")
        waitForInFlight()
        return presented
    }

    private func capture(_ name: String) throws -> [UInt8] {
        let path = NSTemporaryDirectory() + "issue_739_\(name).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.capturePNG(path)
        frame(airTick: false)
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

    private func rig(haze: Double, dust: Double) {
        let dict = """
        {'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 10.0,
         'ambient': 0.1, 'classic': 0.25,
         'air': {'haze': \(haze), 'dust': \(dust), 'dust_size': 0.5, 'dust_speed': 2.0,
                 'scatter': -0.25, 'seed': 7},
         'lights': [
           {'name': 'key', 'orbit': 12.5, 'pitch': 3.0, 'radius': 2.0, 'shadow': True},
           {'name': 'fill', 'orbit': -60.0, 'pitch': 20.0, 'aim': 'point',
            'aim_point': [1.0, 2.0, 3.0], 'aim_selection': 'resn "ALA"',
            'color': [0.5, 0.75, 1.0], 'warmth': 4000.0},
           {'name': 'rim', 'anchor': 'pinned', 'position': [5.0, 6.0, -30.0],
            'outline': True, 'beam': 30.0, 'softness': 0.1}]}
        """
        LightsLive.setRig(dict)
    }

    private func poison(_ on: Bool) {
        engine.runPython("""
        from pymol import cmd as _c
        _c._cmd.set_metal_air_debug_poison(_c._COb, \(on ? 1 : 0))
        """)
    }

    func testPoisonedHazeDrawsTheAirOffFrameKnee() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 2)")
        rig(haze: 0.0, dust: 0.0)
        let off = try capture("knee_off")
        rig(haze: 0.6, dust: 0.0)
        let clean = try capture("knee_clean")
        poison(true)
        let poisoned = try capture("knee_poisoned")

        XCTAssertTrue(isNonUniform(off), "the scene must have drawn (non-uniform)")
        XCTAssertNotEqual(fnv1a(clean), fnv1a(off), "clean haze must differ from haze off")
        XCTAssertEqual(fnv1a(poisoned), fnv1a(off), "the guards drop a non-finite air term")

        let hOff = fnv1a(off)
        let hPoisoned = fnv1a(poisoned)
        print(String(format: "739-poison knee off %016llx poisoned %016llx", hOff, hPoisoned))
    }

    func testPoisonedHazeDrawsTheAirOffFrameHDR() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 1)")
        rig(haze: 0.0, dust: 0.0)
        let off = try capture("hdr_off")
        rig(haze: 0.6, dust: 0.0)
        let clean = try capture("hdr_clean")
        poison(true)
        let poisoned = try capture("hdr_poisoned")

        XCTAssertTrue(isNonUniform(off), "the scene must have drawn (non-uniform)")
        XCTAssertNotEqual(fnv1a(clean), fnv1a(off), "clean haze must differ from haze off")
        XCTAssertEqual(poisoned.count, off.count, "byte counts must match")

        var maxDiff: Int = 0
        for i in 0..<min(poisoned.count, off.count) {
            let diff = abs(Int(poisoned[i]) - Int(off[i]))
            if diff > maxDiff {
                maxDiff = diff
            }
        }
        print("739-poison hdr max byte diff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1, "HDR composite with non-finite air must round-trip within 1 level")
        let hOff = fnv1a(off)
        let hPoisoned = fnv1a(poisoned)
        print(String(format: "739-poison hdr off %016llx poisoned %016llx", hOff, hPoisoned))
    }

    /// An offscreen export (engine.renderHiResPNG, as the glass tracer
    /// tests use): deterministic, and ray traced when `rayTraced` is 1.
    private func export(_ name: String, rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_739_\(name).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rayTraced)
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
        return rgba
    }

    /// Two exports of one scene: equal and drawn; prints the hash, which the
    /// reviewer compares against master's shaders out of band (#739: finite
    /// frames are byte-identical).
    private func hashScene(_ name: String, rayTraced: Int) throws {
        let a = try export("\(name)_a", rayTraced: rayTraced)
        let b = try export("\(name)_b", rayTraced: rayTraced)
        XCTAssertEqual(fnv1a(a), fnv1a(b), "two \(name) exports must be equal")
        XCTAssertTrue(isNonUniform(a), "the \(name) export must have drawn")
        print(String(format: "739-hash %@ %016llx", name, fnv1a(a)))
    }

    func testNormalFrameHashes() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 1)")
        rig(haze: 0.0, dust: 0.0)
        try hashScene("rig", rayTraced: 0)
        rig(haze: 0.6, dust: 0.5)
        try hashScene("air", rayTraced: 0)
        guard engine.rayTracingSupported else {
            print("739-hash rt skipped")
            return
        }
        rig(haze: 0.0, dust: 0.0)
        try hashScene("rt", rayTraced: 1)
        rig(haze: 0.6, dust: 0.5)
        try hashScene("rt-air", rayTraced: 1)
    }
}

/// Issue #732: Ambient occlusion applies in scene units under an HDR light rig.
/// Under an HDR rig, AO (both SSAO and ray-traced AO) darkens scene light before
/// the tone curve T:
///   color = T(Tinv(color) * ao)
/// rather than multiplying the tone-mapped display colour directly (color *= ao).
/// Below T's knee (0.55), both T and Tinv are the identity so the calculation matches
/// color * ao exactly. In a crease, occluding the scene light avoids darkening after
/// compression, so an exposure blend gives e3 == T(3 * e1).
@MainActor
final class HdrAmbientOcclusionTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('ao732*')
            for _n, _v in globals().pop('_ao732_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_ao732_rig', None))
            for _n in globals().pop('_ao732_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        import math
        from pymol import cmd as _c
        _ao732_enabled = _c.get_names('objects', enabled_only=1)
        _ao732_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_ssao', 'metal_msaa',
            'metal_rt_transparent', 'metal_temporal_ao', 'metal_rt_ao_intensity',
            'metal_rt_ao_radius', 'metal_light_hdr', 'metal_exposure')}
        _ao732_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _ao732_rig = _c.get_lights()
        for _n in _ao732_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_shadows', 0)
        _c.set('metal_msaa', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('metal_light_hdr', 1)
        _c.set('metal_exposure', 1.0)

        # Cluster of 7 grey50 pseudoatom spheres (vdw 2.0), centres 3.4 A apart
        _names = ['ao732a', 'ao732b', 'ao732c', 'ao732d', 'ao732e', 'ao732f', 'ao732g']
        _c.pseudoatom(_names[0], pos=[0.0, 0.0, 0.0], vdw=2.0)
        _c.show_as('spheres', _names[0])
        _c.color('grey50', _names[0])
        for _i in range(6):
            _ang = _i * math.pi / 3.0
            _c.pseudoatom(_names[_i + 1], pos=[3.4 * math.cos(_ang), 3.4 * math.sin(_ang), 0.0], vdw=2.0)
            _c.show_as('spheres', _names[_i + 1])
            _c.color('grey50', _names[_i + 1])

        _c.set_lights({'enabled': True, 'ambient': 0.2, 'centre': [0, 0, 0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -20.0, 'pitch': 15.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 0.0, 'shadow': False,
                                   'intensity': 1.0}]})

        _c.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -40, 0, 0, 0, 20, 60, -20))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_732_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    /// Exact port of light_tone: scale the colour by light_tone_scalar(m) / m.
    private func T(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let knee = 0.55
        let white = 10.0
        let m = max(rgb.0, max(rgb.1, rgb.2))
        if m <= knee {
            return rgb
        }
        if m >= white {
            let scale = 1.0 / m
            return (rgb.0 * scale, rgb.1 * scale, rgb.2 * scale)
        }
        let s = 1.0 - knee
        let w = (white - knee) / s
        let t = (m - knee) / s
        let scalar = knee + s * t * (1.0 + t / (w * w)) / (1.0 + t)
        let scale = scalar / m
        return (rgb.0 * scale, rgb.1 * scale, rgb.2 * scale)
    }

    private func assertAOInSceneUnits(rayTraced: Int) throws {
        // The frame without AO finds the creases (and the light before AO).
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_ssao', 0)
        _c.set('metal_rt_ao_intensity', 0.0)
        """)
        let noAO = try render(rayTraced: rayTraced)
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_ssao', 1)
        _c.set('metal_rt_ao_intensity', 1.0)
        """)

        // The same AO at exposure 1 and 3. A traced frame must be deterministic
        // for the comparison to mean anything (as in #729).
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_exposure', 1.0)")
        let e1: [UInt8]
        if rayTraced == 1 {
            let e1a = try render(rayTraced: 1)
            let e1b = try render(rayTraced: 1)
            guard e1a == e1b else {
                throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
            }
            e1 = e1a
        } else {
            e1 = try render(rayTraced: 0)
        }

        engine.runPython("from pymol import cmd as _c\n_c.set('metal_exposure', 3.0)")
        let e3 = try render(rayTraced: rayTraced)

        // Surface pixels below the knee at exposure 1, darkened by AO by at least
        // 8 levels, and above the knee at exposure 3. With AO in scene units
        // e1 = L * ao and e3 = T(3 * L * ao) = T(3 * e1); on master
        // e3 = T(3 * L) * ao, tens of levels darker.
        var n = 0
        var maxErr = 0
        for p in 0..<(Self.width * Self.height) {
            let offset = p * 4
            let rNo = Double(noAO[offset])
            let gNo = Double(noAO[offset + 1])
            let bNo = Double(noAO[offset + 2])
            let maxNo = max(rNo, max(gNo, bNo))
            guard maxNo > 8.0, maxNo <= 130.0 else { continue }

            let r1 = Double(e1[offset])
            let g1 = Double(e1[offset + 1])
            let b1 = Double(e1[offset + 2])
            let max1 = max(r1, max(g1, b1))
            guard (maxNo - max1) >= 8.0 else { continue }
            guard (3.0 * max1 / 255.0) >= 0.75 else { continue }

            let pred = T((3.0 * r1 / 255.0, 3.0 * g1 / 255.0, 3.0 * b1 / 255.0))
            let errR = abs(Int(e3[offset]) - Int(round(pred.0 * 255.0)))
            let errG = abs(Int(e3[offset + 1]) - Int(round(pred.1 * 255.0)))
            let errB = abs(Int(e3[offset + 2]) - Int(round(pred.2 * 255.0)))
            let err = max(errR, max(errG, errB))
            maxErr = max(maxErr, err)
            n += 1
        }

        print("732 rt=\(rayTraced) pixels=\(n) maxErr=\(maxErr)")
        XCTAssertGreaterThanOrEqual(n, 100, "too few AO-darkened pixels to test")
        XCTAssertLessThanOrEqual(maxErr, 4, "AO did not darken the scene light under the HDR rig: the occluded crease is not T(3 * occluded)")
    }

    func testSSAOAppliesInSceneUnitsUnderHdr() throws {
        try requireEngine()
        buildScene()
        try assertAOInSceneUnits(rayTraced: 0)
    }

    func testTracedAOAppliesInSceneUnitsUnderHdr() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        try assertAOInSceneUnits(rayTraced: 1)
    }
}


/// Issue #686: draw the atmosphere (haze and dust) in grid_mode, per cell.
@MainActor
final class GridAirTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('ga686*')
            _c.set('grid_mode', globals().pop('_ga686_grid', 0))
            _c.set('metal_shadows', globals().pop('_ga686_shadows', 1))
            _c.set('metal_raytrace', globals().pop('_ga686_raytrace', 0))
            _c.set('metal_light_air_resolution', globals().pop('_ga686_air_res', 0))
            _c.set('metal_light_air_time', globals().pop('_ga686_air_time', -1.0))
            _c.set('bg_rgb', globals().pop('_ga686_bg', [0.0, 0.0, 0.0]))
            _c.set_lights(globals().pop('_ga686_rig', None))
            for _n in globals().pop('_ga686_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _ga686_enabled = _c.get_names('objects', enabled_only=1)
        _ga686_bg = list(_c.get_color_tuple(_c.get_setting_tuple('bg_rgb')[1][0]))
        _ga686_grid = _c.get_setting_int('grid_mode')
        _ga686_shadows = _c.get_setting_int('metal_shadows')
        _ga686_raytrace = _c.get_setting_int('metal_raytrace')
        _ga686_air_res = _c.get_setting_int('metal_light_air_resolution')
        _ga686_air_time = _c.get_setting_float('metal_light_air_time')
        _ga686_rig = _c.get_lights()
        for _n in _ga686_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('metal_raytrace', 0)
        _c.set('metal_shadows', 1)
        _c.set('metal_light_air_resolution', 1)
        _c.set('metal_light_air_time', 2.0)
        _c.pseudoatom('ga686a', pos=[0.0, 0.0, 0.0], vdw=1.0)
        _c.show_as('spheres', 'ga686a')
        _c.color('white', 'ga686a')
        _c.create('ga686b', 'ga686a')
        _c.set('sphere_scale', 4.0, 'ga686*')
        _c.set('grid_mode', 1)
        """)
        frameScene()
    }

    private func frameScene() {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func setRig(haze: Double) {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_lights({'enabled': True, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0,
                                   'pitch': 20.0, 'beam': 40.0, 'shadow': True}],
                       'air': {'haze': \(haze), 'dust': 0.0}})
        """)
    }

    private func render() throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "ga686_render.png"
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
        return rgba
    }

    private func assertSpheresDrawnInBothHalves(_ haze0: [UInt8]) {
        let width = 400, height = 300
        var leftBright = 0, rightBright = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let lum = (Double(haze0[i]) + Double(haze0[i + 1]) + Double(haze0[i + 2])) / 3.0
                if lum > 50.0 {
                    if x < 200 { leftBright += 1 } else { rightBright += 1 }
                }
            }
        }
        XCTAssertGreaterThan(leftBright, 100, "left cell sphere must be drawn")
        XCTAssertGreaterThan(rightBright, 100, "right cell sphere must be drawn")
    }

    func testHazeShowsInEveryGridCell() throws {
        try requireEngine()
        buildScene()
        setRig(haze: 0.0)
        let haze0 = try render()
        assertSpheresDrawnInBothHalves(haze0)

        setRig(haze: 0.3)
        let haze3 = try render()

        let width = 400, height = 300
        for (halfName, xRange) in [("left", 0..<200), ("right", 200..<400)] {
            var bgCount = 0
            var bgGainSum = 0.0
            var gainedCount = 0
            for y in 0..<height {
                for x in xRange {
                    let i = (y * width + x) * 4
                    let lum0 = (Double(haze0[i]) + Double(haze0[i + 1]) + Double(haze0[i + 2])) / 3.0
                    let lum3 = (Double(haze3[i]) + Double(haze3[i + 1]) + Double(haze3[i + 2])) / 3.0
                    if lum0 <= 2.0 {
                        bgCount += 1
                        let gain = lum3 - lum0
                        bgGainSum += gain
                        if gain >= 1.0 {
                            gainedCount += 1
                        }
                    }
                }
            }
            XCTAssertGreaterThan(bgCount, 500, "enough background pixels in \(halfName) half")
            let meanGain = bgCount > 0 ? bgGainSum / Double(bgCount) : 0.0
            print("ga686 \(halfName) bgCount=\(bgCount) meanGain=\(meanGain) gained=\(gainedCount)")
            XCTAssertGreaterThanOrEqual(meanGain, 1.0, "\(halfName) half background luminance must rise by >= 1.0 level")
            XCTAssertGreaterThanOrEqual(gainedCount, 500, "\(halfName) half must have >= 500 pixels gain light")
        }
    }

    func testCellsMarchTheirOwnRays() throws {
        try requireEngine()
        buildScene()
        setRig(haze: 0.0)
        let haze0 = try render()
        assertSpheresDrawnInBothHalves(haze0)

        setRig(haze: 0.3)
        let haze3 = try render()

        let width = 400, height = 300
        var leftAirSum = 0.0
        var rightAirSum = 0.0

        for row in 0..<6 {
            for col in 0..<8 {
                let x0 = col * 25
                let x1 = x0 + 25
                let y0 = row * 50
                let y1 = y0 + 50

                var leftBoxSum = 0.0
                var rightBoxSum = 0.0
                let boxPixels = 25 * 50

                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let iL = (y * width + x) * 4
                        let iR = (y * width + (x + 200)) * 4
                        let lum0L = (Double(haze0[iL]) + Double(haze0[iL + 1]) + Double(haze0[iL + 2])) / 3.0
                        let lum3L = (Double(haze3[iL]) + Double(haze3[iL + 1]) + Double(haze3[iL + 2])) / 3.0
                        let lum0R = (Double(haze0[iR]) + Double(haze0[iR + 1]) + Double(haze0[iR + 2])) / 3.0
                        let lum3R = (Double(haze3[iR]) + Double(haze3[iR + 1]) + Double(haze3[iR + 2])) / 3.0
                        let airL = lum3L - lum0L
                        let airR = lum3R - lum0R
                        leftBoxSum += airL
                        rightBoxSum += airR
                    }
                }
                leftAirSum += leftBoxSum
                rightAirSum += rightBoxSum
                let leftMean = leftBoxSum / Double(boxPixels)
                let rightMean = rightBoxSum / Double(boxPixels)
                let boxDiff = abs(leftMean - rightMean)
                XCTAssertLessThanOrEqual(
                    boxDiff, 2.0,
                    "box (col=\(col), row=\(row)) left=\(leftMean) right=\(rightMean) diff=\(boxDiff) exceeds 2.0")
            }
        }

        let halfPixels = 200 * 300
        let leftTotalMean = leftAirSum / Double(halfPixels)
        let rightTotalMean = rightAirSum / Double(halfPixels)
        let maxTotalMean = max(leftTotalMean, rightTotalMean)
        let totalDiff = abs(leftTotalMean - rightTotalMean)
        print("ga686 leftTotalMean=\(leftTotalMean) rightTotalMean=\(rightTotalMean) diff=\(totalDiff)")
        XCTAssertGreaterThan(leftTotalMean, 0.5, "left half has air")
        XCTAssertGreaterThan(rightTotalMean, 0.5, "right half has air")
        XCTAssertLessThanOrEqual(
            totalDiff, 0.10 * maxTotalMean,
            "halves total means left=\(leftTotalMean) right=\(rightTotalMean) differ by > 10%")
    }
}

/// Issue #709: Traced reflection hits take the neutral material response.
/// At `metal_raytrace 1` with a studio rig on, `rt_composite` lights what a
/// reflection ray hits with the rig. The hit must take ITS material's studio
/// response (the per-occurrence table's response terms, as `bindMaterialU`
/// gives the raster draw), not `light_response_neutral()`: a fully tinted
/// metallic sphere (studio diffuse 1 - reflect * tint = 0) seen in a mirror
/// must lose the rig's diffuse there as it does in the raster image.
@MainActor
final class ReflectionHitMaterialTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('rh709*')
            for _n, _v in globals().pop('_rh709_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_rh709_rig', None))
            for _n in globals().pop('_rh709_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _rh709_enabled = _c.get_names('objects', enabled_only=1)
        _rh709_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'depth_cue', 'metal_shadows', 'metal_rt_transparent', 'metal_temporal_ao')}
        _rh709_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _rh709_rig = _c.get_lights()
        for _n in _rh709_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_shadows', 0)
        _c.set('metal_rt_transparent', 0)

        # Mirror sphere: metallic, reflect 1.0, tint 0.0, rough 0.0
        _c.pseudoatom('rh709m', pos=[4.0, 0.0, 0.0], vdw=4.5)
        _c.show_as('spheres', 'rh709m')
        _c.set('sphere_material', 'metallic', 'rh709m')
        _c.set('sphere_material_reflect', 1.0, 'rh709m')
        _c.set('sphere_material_tint', 0.0, 'rh709m')
        _c.set('sphere_material_rough', 0.0, 'rh709m')

        # Target sphere: grey80, the default material until the test changes it
        _c.pseudoatom('rh709t', pos=[-4.0, 0.0, -2.0], vdw=3.5)
        _c.show_as('spheres', 'rh709t')
        _c.color('grey80', 'rh709t')

        _c.set_lights({'enabled': True, 'ambient': 0.06, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': False}]})

        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    /// The target as a fully tinted metal (studio diffuse 0), or back to default.
    private func setTargetMetal(_ metal: Bool) {
        if metal {
            engine.runPython("""
            from pymol import cmd as _c
            _c.set('sphere_material', 'metallic', 'rh709t')
            _c.set('sphere_material_reflect', 1.0, 'rh709t')
            _c.set('sphere_material_tint', 1.0, 'rh709t')
            _c.set('sphere_material_rough', 1.0, 'rh709t')
            """)
        } else {
            engine.runPython("""
            from pymol import cmd as _c
            for _n in ('sphere_material', 'sphere_material_reflect',
                       'sphere_material_tint', 'sphere_material_rough'):
                _c.unset(_n, 'rh709t')
            """)
        }
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_709_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func footprint(of name: String) throws -> [Bool] {
        let others = ["rh709m", "rh709t"].filter { $0 != name }
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.disable('\(other)')")
        }
        let px = try render(rayTraced: 0)
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.enable('\(other)')")
        }
        return stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) > 3 }
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8], in region: [Bool]) -> Int {
        guard a.count == b.count, a.count == region.count * 4 else { return -1 }
        var best = 0
        for (p, inside) in region.enumerated() where inside {
            for c in 0..<3 {
                best = max(best, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c])))
            }
        }
        return best
    }

    private func meanSum(_ px: [UInt8], in region: [Bool]) -> Double {
        var total = 0, count = 0
        for (p, inside) in region.enumerated() where inside {
            total += Int(px[p * 4]) + Int(px[p * 4 + 1]) + Int(px[p * 4 + 2])
            count += 1
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    func testReflectionHitTakesItsMaterialResponse() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()

        let mirror = try footprint(of: "rh709m")
        let target = try footprint(of: "rh709t")

        var minX = Self.width, maxX = 0, minY = Self.height, maxY = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where mirror[y * Self.width + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX - minX, 40, "mirror sphere not found in frame")

        // The mirror's third facing the target: its reflection is a crescent
        // along the mirror's left rim, so the box reaches the rim.
        let boxMaxX = minX + (maxX - minX) / 3
        var box = [Bool](repeating: false, count: Self.width * Self.height)
        for y in minY...maxY {
            for x in minX...boxMaxX {
                let idx = y * Self.width + x
                box[idx] = mirror[idx] && !target[idx]
            }
        }
        let boxCount = box.filter { $0 }.count
        XCTAssertGreaterThan(boxCount, 100, "the box region inside the mirror is too small: \(boxCount)")

        let rtDefault = try render(rayTraced: 1)
        let rtDefault2 = try render(rayTraced: 1)
        guard maxDelta(rtDefault, rtDefault2, in: box) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }

        setTargetMetal(true)
        let rtMetal = try render(rayTraced: 1)
        let rasterMetal = try render(rayTraced: 0)
        setTargetMetal(false)
        let rasterDefault = try render(rayTraced: 0)

        let rtDelta = maxDelta(rtDefault, rtMetal, in: box)
        let rasterDelta = maxDelta(rasterDefault, rasterMetal, in: box)
        let meanDefault = meanSum(rtDefault, in: box)
        let meanMetal = meanSum(rtMetal, in: box)
        print("709 rt delta=\(rtDelta) raster delta=\(rasterDelta) mean default=\(meanDefault) metal=\(meanMetal)")

        XCTAssertGreaterThanOrEqual(rtDelta, 20, "the traced reflection ignores the hit's material")
        XCTAssertLessThan(meanMetal, meanDefault,
                          "a metal whose studio diffuse is 0 must reflect darker than the default material")
        XCTAssertLessThanOrEqual(rasterDelta, 3, "the raster mirror changed with the target's material")
    }
}

/// Issue #852: Cast shadows apply in scene units under an HDR light rig.
/// Under an HDR rig, the whole-pixel cast shadow factor (both shadow map and
/// ray-traced shadow) darkens scene light together with AO before the tone curve T:
///   color = T(Tinv(color) * (ao * shade))
/// rather than multiplying the tone-mapped display colour directly (color *= shade).
/// Below T's knee (0.55), both T and Tinv are the identity so the calculation matches
/// color * ao * shade exactly. In a cast shadow, occluding the scene light avoids
/// darkening after compression, so an exposure blend gives e3 == T(3 * e1).
@MainActor
final class HdrCastShadowTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('sh852*')
            for _n, _v in globals().pop('_sh852_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_sh852_rig', None))
            for _n in globals().pop('_sh852_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _sh852_enabled = _c.get_names('objects', enabled_only=1)
        _sh852_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_ssao', 'metal_msaa',
            'metal_rt_transparent', 'metal_temporal_ao', 'metal_rt_ao_intensity',
            'metal_rt_ao_radius', 'metal_light_hdr', 'metal_exposure',
            'metal_rt_shadows', 'metal_rt_shadow_intensity', 'light')}
        _sh852_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _sh852_settings['light'] = list(_c.get_setting_tuple('light')[1])
        _sh852_rig = _c.get_lights()
        for _n in _sh852_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_msaa', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('metal_light_hdr', 1)
        _c.set('metal_exposure', 1.0)
        _c.set('metal_ssao', 0)
        _c.set('metal_rt_ao_intensity', 0.0)
        _c.set('metal_shadows', 0)
        _c.set('metal_rt_shadows', 1)
        _c.set('metal_rt_shadow_intensity', 0.45)
        _c.set('light', [-0.4, -0.4, -1.0])

        _c.pseudoatom('sh852r', pos=[0.0, 0.0, 0.0], vdw=5.0)
        _c.show_as('spheres', 'sh852r')
        _c.color('grey50', 'sh852r')

        _c.pseudoatom('sh852o', pos=[2.78, 2.78, 11.96], vdw=1.5)
        _c.show_as('spheres', 'sh852o')
        _c.color('grey50', 'sh852o')

        _c.set_lights({'enabled': True, 'ambient': 0.2, 'centre': [0, 0, 0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -20.0, 'pitch': 15.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 0.0, 'shadow': False,
                                   'intensity': 1.0}]})

        _c.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -40, 0, 0, 0, 20, 60, -20))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_852_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    /// Exact port of light_tone: scale the colour by light_tone_scalar(m) / m.
    private func T(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let knee = 0.55
        let white = 10.0
        let m = max(rgb.0, max(rgb.1, rgb.2))
        if m <= knee {
            return rgb
        }
        if m >= white {
            let scale = 1.0 / m
            return (rgb.0 * scale, rgb.1 * scale, rgb.2 * scale)
        }
        let s = 1.0 - knee
        let w = (white - knee) / s
        let t = (m - knee) / s
        let scalar = knee + s * t * (1.0 + t / (w * w)) / (1.0 + t)
        let scale = scalar / m
        return (rgb.0 * scale, rgb.1 * scale, rgb.2 * scale)
    }

    private func assertShadowInSceneUnits(rayTraced: Int) throws {
        // Render noShadow at exposure 1 with metal_shadows 0
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_shadows', 0)
        _c.set('metal_exposure', 1.0)
        """)
        let noShadow = try render(rayTraced: rayTraced)

        // Then metal_shadows 1; e1 at exposure 1 (for RT render twice and XCTSkip if they differ)
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', 1)")
        let e1: [UInt8]
        if rayTraced == 1 {
            let e1a = try render(rayTraced: 1)
            let e1b = try render(rayTraced: 1)
            guard e1a == e1b else {
                throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
            }
            e1 = e1a
        } else {
            e1 = try render(rayTraced: 0)
        }

        // e3 at exposure 3
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_exposure', 3.0)")
        let e3 = try render(rayTraced: rayTraced)

        // Lit surface pixels the shadow darkens by at least 8 levels, below the
        // knee once shadowed at exposure 1 (the shadow's fixed 0.45 leaves too
        // narrow a band if the unshadowed light must be below it as well), and
        // above the knee at exposure 3. With the shadow in scene units
        // e1 = L * shade and e3 = T(3 * L * shade) = T(3 * e1); on master
        // e3 = T(3 * L) * shade, tens of levels darker.
        var n = 0
        var maxErr = 0
        for p in 0..<(Self.width * Self.height) {
            let offset = p * 4
            let rNo = Double(noShadow[offset])
            let gNo = Double(noShadow[offset + 1])
            let bNo = Double(noShadow[offset + 2])
            let maxNo = max(rNo, max(gNo, bNo))
            guard maxNo > 8.0 else { continue }

            let r1 = Double(e1[offset])
            let g1 = Double(e1[offset + 1])
            let b1 = Double(e1[offset + 2])
            let max1 = max(r1, max(g1, b1))
            guard (maxNo - max1) >= 8.0 else { continue }
            guard max1 <= 135.0 else { continue }
            guard (3.0 * max1 / 255.0) >= 0.75 else { continue }

            let pred = T((3.0 * r1 / 255.0, 3.0 * g1 / 255.0, 3.0 * b1 / 255.0))
            let errR = abs(Int(e3[offset]) - Int(round(pred.0 * 255.0)))
            let errG = abs(Int(e3[offset + 1]) - Int(round(pred.1 * 255.0)))
            let errB = abs(Int(e3[offset + 2]) - Int(round(pred.2 * 255.0)))
            let err = max(errR, max(errG, errB))
            maxErr = max(maxErr, err)
            n += 1
        }

        print("852 rt=\(rayTraced) pixels=\(n) maxErr=\(maxErr)")
        XCTAssertGreaterThanOrEqual(n, 100, "too few shadow-darkened pixels to test")
        XCTAssertLessThanOrEqual(maxErr, 4, "the cast shadow did not darken the scene light under the HDR rig: the shadowed pixel is not T(3 * shadowed)")
    }

    func testShadowMapShadowAppliesInSceneUnitsUnderHdr() throws {
        try requireEngine()
        buildScene()
        try assertShadowInSceneUnits(rayTraced: 0)
    }

    func testTracedShadowAppliesInSceneUnitsUnderHdr() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        try assertShadowInSceneUnits(rayTraced: 1)
    }
}


/// Issue #683: Beer-Lambert extinction along the view ray.
@MainActor
final class AirExtinctionTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
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
        _ext683_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'metal_light_air_time', 'metal_raytrace', 'metal_temporal_ao',
            'metal_light_hdr', 'metal_exposure', 'metal_light_air_resolution')}
        _ext683_bg = _c.get('bg_rgb')
        _c.set('bg_rgb', 'black')
        _c.set('metal_raytrace', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_light_air_time', 1.25)
        _c.set('metal_light_air_resolution', 1)
        """)
        LightsLive.addPeptide()
        engine.runPython("from pymol import cmd as _c\n_c.orient('lmt_pep')")
        waitForInFlight()
    }

    override func tearDown() {
        engine.runPython("""
        from pymol import cmd as _c
        _c._cmd.set_metal_air_debug_poison(_c._COb, 0)
        for _n, _v in globals().pop('_ext683_settings', {}).items():
            _c.set(_n, _v)
        if '_ext683_bg' in globals():
            _c.set('bg_rgb', globals().pop('_ext683_bg'))
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

    private func export(_ name: String, rayTraced: Int = 0) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_683_\(name).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rayTraced)
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
        return rgba
    }

    private func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return hash
    }

    private func rig(haze: Double, dust: Double, intensity: Double) {
        let dict = """
        {'enabled': True, 'centre': list(_lmt_cmd.centerofmass('lmt_pep')), 'size': 10.0,
         'ambient': 0.5, 'classic': 0.5,
         'air': {'haze': \(haze), 'dust': \(dust), 'dust_size': 0.5, 'dust_speed': 2.0,
                 'scatter': 0.0, 'seed': 7},
         'lights': [{'name': 'key', 'orbit': 0.0, 'pitch': 0.0, 'intensity': \(intensity),
                     'shadow': False}]}
        """
        LightsLive.setRig(dict)
    }

    func testHazeAttenuatesTheSurfaceExponentially() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 2)")
        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let I0 = try export("exp_haze0")
        rig(haze: 0.3, dust: 0.0, intensity: 0.0)
        let I1 = try export("exp_haze1")
        rig(haze: 0.6, dust: 0.0, intensity: 0.0)
        let I2 = try export("exp_haze2")
        rig(haze: 0.9, dust: 0.0, intensity: 0.0)
        let I3 = try export("exp_haze3")

        func lum(_ px: [UInt8], _ i: Int) -> Double {
            0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        }

        let width = 400
        let height = 300
        var count = 0
        var sum1 = 0.0
        var sum2 = 0.0
        var sum3 = 0.0

        for p in 0..<(width * height) {
            let i = p * 4
            let L0 = lum(I0, i)
            if L0 >= 60.0 {
                count += 1
                let L1 = lum(I1, i)
                let L2 = lum(I2, i)
                let L3 = lum(I3, i)
                sum1 += log(max(L1, 0.5) / L0)
                sum2 += log(max(L2, 0.5) / L0)
                sum3 += log(max(L3, 0.5) / L0)
            }
        }

        XCTAssertGreaterThanOrEqual(count, 500, "at least 500 lit molecule pixels required")
        let m1 = sum1 / Double(count)
        let m2 = sum2 / Double(count)
        let m3 = sum3 / Double(count)
        print(String(format: "683-ext m1 %.4f m2 %.4f m3 %.4f count %d", m1, m2, m3, count))

        XCTAssertLessThan(m1, -0.05, "the haze must attenuate the surface")
        XCTAssertLessThanOrEqual(abs(m2 / m1 - 2.0), 0.15, "optical depth must scale linearly with haze (m2/m1)")
        XCTAssertLessThanOrEqual(abs(m3 / m1 - 3.0), 0.3, "optical depth must scale linearly with haze (m3/m1)")

        var nearLit = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                if lum(I0, idx) > 0.0 {
                    let y0 = max(0, y - 3), y1 = min(height - 1, y + 3)
                    let x0 = max(0, x - 3), x1 = min(width - 1, x + 3)
                    for ny in y0...y1 {
                        for nx in x0...x1 {
                            nearLit[ny * width + nx] = true
                        }
                    }
                }
            }
        }

        // The empty background is never attenuated and the unlit haze adds
        // nothing: it stays black.
        var background = 0
        var changed = 0
        for p in 0..<(width * height) where !nearLit[p] {
            let idx = p * 4
            guard I0[idx] == 0 && I0[idx + 1] == 0 && I0[idx + 2] == 0 else { continue }
            background += 1
            if I3[idx] != 0 || I3[idx + 1] != 0 || I3[idx + 2] != 0 { changed += 1 }
        }
        XCTAssertGreaterThan(background, 10_000, "the export must show black background")
        XCTAssertEqual(changed, 0, "background pixels changed under haze 0.9")
    }

    func testZeroDensityIsANoOpKnee() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 2)")
        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let off = try export("zero_knee_off")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0)
        let dustOnly = try export("zero_knee_dust")
        XCTAssertEqual(fnv1a(off), fnv1a(dustOnly), "zero density must be byte-identical at knee")
        XCTAssertEqual(off, dustOnly, "arrays must match byte-for-byte")
    }

    func testZeroDensityIsANoOpHDR() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 1)")
        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let off = try export("zero_hdr_off")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0)
        let dustOnly = try export("zero_hdr_dust")
        XCTAssertEqual(off.count, dustOnly.count, "byte counts must match")
        var maxDiff = 0
        for i in 0..<min(off.count, dustOnly.count) {
            let diff = abs(Int(off[i]) - Int(dustOnly[i]))
            if diff > maxDiff {
                maxDiff = diff
            }
        }
        print("683-zero hdr max byte diff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1, "HDR composite with zero density must round-trip within 1 level")
    }

    func testPoisonedDensityKeepsTheSurface() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_light_hdr', 2)")
        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let off = try export("poison_off")
        rig(haze: 0.6, dust: 0.0, intensity: 0.0)
        engine.runPython("from pymol import cmd as _c\n_c._cmd.set_metal_air_debug_poison(_c._COb, 1)")
        let poisoned = try export("poison_on")
        XCTAssertEqual(fnv1a(off), fnv1a(poisoned), "poisoned density must be byte-identical to off")
        XCTAssertEqual(off, poisoned, "arrays must match byte-for-byte")
    }
}

/// Issue #855: Traced reflection hit material gaps: transparent layer material
/// response, procedural albedo, and glass glints.
@MainActor
final class ReflectionHitMaterialGapsTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('rh855*')
            for _n, _v in globals().pop('_rh855_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_rh855_rig', None))
            for _n in globals().pop('_rh855_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene(rtTransparent: Int = 0) {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _rh855_enabled = _c.get_names('objects', enabled_only=1)
        _rh855_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'depth_cue', 'metal_shadows', 'metal_rt_transparent', 'metal_temporal_ao')}
        _rh855_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _rh855_rig = _c.get_lights()
        for _n in _rh855_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_shadows', 0)
        _c.set('metal_rt_transparent', \(rtTransparent))

        # Mirror sphere: metallic, reflect 1.0, tint 0.0, rough 0.0
        _c.pseudoatom('rh855m', pos=[4.0, 0.0, 0.0], vdw=4.5)
        _c.show_as('spheres', 'rh855m')
        _c.set('sphere_material', 'metallic', 'rh855m')
        _c.set('sphere_material_reflect', 1.0, 'rh855m')
        _c.set('sphere_material_tint', 0.0, 'rh855m')
        _c.set('sphere_material_rough', 0.0, 'rh855m')

        # Target sphere: grey80, the default material until the test changes it
        _c.pseudoatom('rh855t', pos=[-4.0, 0.0, -2.0], vdw=3.5)
        _c.show_as('spheres', 'rh855t')
        _c.color('grey80', 'rh855t')

        _c.set_lights({'enabled': True, 'ambient': 0.06, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 1.0, 'shadow': False}]})

        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 20.0, 100.0, -20.0))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_855_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func footprint(of name: String) throws -> [Bool] {
        let others = ["rh855m", "rh855t"].filter { $0 != name }
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.disable('\(other)')")
        }
        let px = try render(rayTraced: 0)
        for other in others {
            engine.runPython("from pymol import cmd as _c\n_c.enable('\(other)')")
        }
        return stride(from: 0, to: px.count, by: 4).map { max(px[$0], px[$0 + 1], px[$0 + 2]) > 3 }
    }

    private func maxDelta(_ a: [UInt8], _ b: [UInt8], in region: [Bool]) -> Int {
        guard a.count == b.count, a.count == region.count * 4 else { return -1 }
        var best = 0
        for (p, inside) in region.enumerated() where inside {
            for c in 0..<3 {
                best = max(best, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c])))
            }
        }
        return best
    }

    private func meanSum(_ px: [UInt8], in region: [Bool]) -> Double {
        var total = 0, count = 0
        for (p, inside) in region.enumerated() where inside {
            total += Int(px[p * 4]) + Int(px[p * 4 + 1]) + Int(px[p * 4 + 2])
            count += 1
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    private func computeBoxRegion() throws -> [Bool] {
        let mirror = try footprint(of: "rh855m")
        let target = try footprint(of: "rh855t")

        var minX = Self.width, maxX = 0, minY = Self.height, maxY = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width where mirror[y * Self.width + x] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX - minX, 40, "mirror sphere not found in frame")

        let boxMaxX = minX + (maxX - minX) / 3
        var box = [Bool](repeating: false, count: Self.width * Self.height)
        for y in minY...maxY {
            for x in minX...boxMaxX {
                let idx = y * Self.width + x
                box[idx] = mirror[idx] && !target[idx]
            }
        }
        let boxCount = box.filter { $0 }.count
        XCTAssertGreaterThan(boxCount, 100, "the box region inside the mirror is too small: \(boxCount)")
        return box
    }

    func testTransparentHitTakesItsMaterialResponse() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene(rtTransparent: 1)
        engine.runPython("from pymol import cmd as _c\n_c.set('sphere_transparency', 0.4, 'rh855t')")

        let box = try computeBoxRegion()
        let rt1 = try render(rayTraced: 1)
        let rt2 = try render(rayTraced: 1)
        guard maxDelta(rt1, rt2, in: box) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }

        // A = target default material (already set)
        let rtA = rt1
        let meanA = meanSum(rtA, in: box)

        // B = target metallic, reflect 1.0, tint 1.0, rough 1.0 (studio diffuse 0)
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('sphere_material', 'metallic', 'rh855t')
        _c.set('sphere_material_reflect', 1.0, 'rh855t')
        _c.set('sphere_material_tint', 1.0, 'rh855t')
        _c.set('sphere_material_rough', 1.0, 'rh855t')
        """)
        let rtB = try render(rayTraced: 1)
        let meanB = meanSum(rtB, in: box)
        let delta = maxDelta(rtA, rtB, in: box)
        print("855 trans hit delta=\(delta) meanA=\(meanA) meanB=\(meanB)")

        XCTAssertGreaterThanOrEqual(delta, 20, "transparent hit material response was ignored")
        XCTAssertLessThan(meanB, meanA, "metallic transparent hit with diffuse 0 must reflect darker than default")
    }

    func testMirroredProceduralAlbedo() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene(rtTransparent: 0)
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('sphere_material', 'marble', 'rh855t')
        _c.set('sphere_material_knob2', 0.5, 'rh855t')
        _c.set('sphere_material_knob5', 0.0, 'rh855t')
        """)

        let box = try computeBoxRegion()
        let rt1 = try render(rayTraced: 1)
        let rt2 = try render(rayTraced: 1)
        guard maxDelta(rt1, rt2, in: box) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }

        // A = knob5 0.0 (vein contrast 0: plain stone)
        let rtA = rt1

        // B = knob5 1.0 (vein contrast 1.0)
        engine.runPython("from pymol import cmd as _c\n_c.set('sphere_material_knob5', 1.0, 'rh855t')")
        let rtB = try render(rayTraced: 1)
        let delta = maxDelta(rtA, rtB, in: box)
        let meanA = meanSum(rtA, in: box)
        let meanB = meanSum(rtB, in: box)
        print("855 marble albedo delta=\(delta) meanA=\(meanA) meanB=\(meanB)")

        XCTAssertGreaterThanOrEqual(delta, 20, "mirrored procedural albedo was ignored")
    }

    func testMirroredGlassTakesTheGlints() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene(rtTransparent: 1)
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('sphere_material', 'glass', 'rh855t')
        _c.set('sphere_material_knob1', 0.0, 'rh855t')
        """)

        let box = try computeBoxRegion()
        let rt1 = try render(rayTraced: 1)
        let rt2 = try render(rayTraced: 1)
        guard maxDelta(rt1, rt2, in: box) == 0 else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }

        // A = knob1 0.0 (Reflection 0: no glints)
        let rtA = rt1

        // B = knob1 1.0 (Reflection 1.0: glints on)
        engine.runPython("from pymol import cmd as _c\n_c.set('sphere_material_knob1', 1.0, 'rh855t')")
        let rtB = try render(rayTraced: 1)
        let delta = maxDelta(rtA, rtB, in: box)
        let meanA = meanSum(rtA, in: box)
        let meanB = meanSum(rtB, in: box)
        print("855 glass glints delta=\(delta) meanA=\(meanA) meanB=\(meanB)")

        XCTAssertGreaterThanOrEqual(delta, 20, "mirrored glass glints were ignored")
    }
}

/// Issue #668: With metal_raytrace 1, flat quads (e.g. backdrops) should not have
/// an AO brightness seam along their diagonal caused by averaging with unrelated
/// buffer neighbours.
@MainActor
final class FlatQuadSeamTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    // The strip's traced AO factor at its centre (mean over x 185..<215) on
    // master, where rt_tri_normal_smooth averages a full quad either side
    // (measured 0.753). A facet-only normal reads about 0.87 there.
    private static let masterStripAO = 0.75

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('seam668*')
            for _n, _v in globals().pop('_seam668_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_seam668_rig', None))
            for _n in globals().pop('_seam668_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _seam668_enabled = _c.get_names('objects', enabled_only=1)
        _seam668_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_shadows', 'metal_ssao', 'metal_msaa',
            'metal_rt_transparent', 'metal_temporal_ao', 'metal_light_hdr')}
        _seam668_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _seam668_rig = _c.get_lights()
        for _n in _seam668_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_shadows', 0)
        _c.set('metal_msaa', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('metal_ssao', 0)
        _c.set('metal_light_hdr', 0)
        _c.set_lights({'enabled': True, 'ambient': 0.3, 'centre': [0, 0, 0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': 0.0, 'pitch': 0.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 0.0, 'shadow': False,
                                   'intensity': 0.6}]})
        _c.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -80, 0, 0, 0, 40, 120, -20))
        """)
    }

    private func loadQuad() {
        engine.runPython("""
        from pymol import cmd as _c
        _q = [2.0, 5.0, 6.0, 0.8, 0.8, 0.8, 5.0, 0.0, 0.0, 1.0, 4.0, -10.0, -10.0, 0.0, 4.0, 10.0, -10.0, 0.0, 4.0, -10.0, 10.0, 0.0, 4.0, 10.0, 10.0, 0.0, 3.0]
        _c.load_cgo(_q, 'seam668q', zoom=0)
        """)
    }

    // The quad and, in the same strip, a wall bent 90 degrees away from the
    // camera along its top edge: buffer neighbours that DO share vertices with
    // the quad but are not part of its plane (an L-shaped backdrop, a box).
    private func loadBentQuad() {
        engine.runPython("""
        from pymol import cmd as _c
        _b = [2.0, 5.0, 6.0, 0.8, 0.8, 0.8, 5.0, 0.0, 0.0, 1.0, 4.0, -10.0, -10.0, 0.0, 4.0, 10.0, -10.0, 0.0, 4.0, -10.0, 10.0, 0.0, 4.0, 10.0, 10.0, 0.0, 4.0, -10.0, 10.0, -10.0, 4.0, 10.0, 10.0, -10.0, 3.0]
        _c.load_cgo(_b, 'seam668b', zoom=0)
        """)
    }

    private func loadNeighbour() {
        engine.runPython("""
        from pymol import cmd as _c
        _x = [2.0, 4.0, 6.0, 0.8, 0.8, 0.8, 4.0, 60.0, 0.0, -5.0, 4.0, 60.0, 5.0, 5.0, 4.0, 60.0, -5.0, 5.0, 4.0, 61.0, 0.0, -5.0, 4.0, 61.0, 5.0, 5.0, 4.0, 61.0, -5.0, 5.0, 3.0]
        _c.load_cgo(_x, 'seam668x', zoom=0)
        """)
    }

    private func loadStripAndFloor() {
        engine.runPython("""
        import math
        from pymol import cmd as _c
        _o = [2.0, 5.0, 6.0, 0.8, 0.8, 0.8]
        for _i in range(61):
            _x = -15.0 + _i * 0.5
            _t = math.radians(_i * 25.0)
            for _s in (-1.0, 1.0):
                _o += [4.0, _x, _s * 1.6 * math.cos(_t), _s * 1.6 * math.sin(_t)]
        _o += [3.0]
        _c.load_cgo(_o, 'seam668s', zoom=0)
        _f = [2.0, 5.0, 6.0, 0.8, 0.8, 0.8, 5.0, 0.0, 0.0, 1.0, 4.0, -18.0, -6.0, -2.5, 4.0, 18.0, -6.0, -2.5, 4.0, -18.0, 6.0, -2.5, 4.0, 18.0, 6.0, -2.5, 3.0]
        _c.load_cgo(_f, 'seam668f', zoom=0)
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_668_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func lum(_ px: [UInt8], _ x: Double, _ y: Double) -> Double {
        let xi = max(0, min(Self.width - 1, Int(round(x))))
        let yi = max(0, min(Self.height - 1, Int(round(y))))
        let offset = (yi * Self.width + xi) * 4
        return (Double(px[offset]) + Double(px[offset + 1]) + Double(px[offset + 2])) / 3.0
    }

    private func step(_ px: [UInt8], diagonal d: Int, offset o: Double) -> Double {
        let s = 1.0 / sqrt(2.0)
        let u: (x: Double, y: Double) = (d == 0) ? (s, s) : (s, -s)
        let n: (x: Double, y: Double) = (u.y, -u.x)
        var total = 0.0
        for t in -90...90 {
            let pxCoord = 199.5 + Double(t) * u.x + o * n.x
            let pyCoord = 149.5 + Double(t) * u.y + o * n.y
            let pPlusL = lum(px, pxCoord + 3.0 * n.x, pyCoord + 3.0 * n.y)
            let pMinusL = lum(px, pxCoord - 3.0 * n.x, pyCoord - 3.0 * n.y)
            total += (pPlusL - pMinusL)
        }
        return total / 181.0
    }

    private func seam(_ px: [UInt8], _ d: Int) -> Double {
        abs(step(px, diagonal: d, offset: 0) - step(px, diagonal: d, offset: 20))
    }

    private func diagMean(_ px: [UInt8]) -> Double {
        let s = 1.0 / sqrt(2.0)
        let u: (x: Double, y: Double) = (s, s)
        var total = 0.0
        for t in -90...90 {
            let pxCoord = 199.5 + Double(t) * u.x
            let pyCoord = 149.5 + Double(t) * u.y
            total += lum(px, pxCoord, pyCoord)
        }
        return total / 181.0
    }

    func testTracedAOHasNoSeamAcrossAFlatQuadsDiagonal() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        loadQuad()
        loadNeighbour()

        let rt0 = try render(rayTraced: 0)

        let rt1a = try render(rayTraced: 1)
        let rt1b = try render(rayTraced: 1)
        guard rt1a == rt1b else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let rt1 = rt1a

        let mean0 = diagMean(rt0)
        XCTAssertGreaterThan(mean0, 100.0, "the quad is drawn")

        let seam0 = seam(rt1, 0)
        let seam1 = seam(rt1, 1)
        XCTAssertLessThanOrEqual(seam0, 1.0, "seam across diagonal d=0")
        XCTAssertLessThanOrEqual(seam1, 1.0, "seam across diagonal d=1")

        let mean1 = diagMean(rt1)
        let meanDiff = abs(mean1 - mean0)
        XCTAssertLessThanOrEqual(meanDiff, 1.0, "an open flat quad is not self-occluded")

        print(String(format: "668 seam d0=%.3f d1=%.3f mean0=%.3f mean1=%.3f diff=%.3f",
                     seam0, seam1, mean0, mean1, meanDiff))
    }

    func testUnrelatedTrianglesDoNotChangeAQuadsTracedAO() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        loadQuad()

        let rtAloneA = try render(rayTraced: 1)
        let rtAloneB = try render(rayTraced: 1)
        guard rtAloneA == rtAloneB else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let rtAlone = rtAloneA

        loadNeighbour()

        let rtNeighbourA = try render(rayTraced: 1)
        let rtNeighbourB = try render(rayTraced: 1)
        guard rtNeighbourA == rtNeighbourB else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let rtNeighbour = rtNeighbourA

        var maxDiff = 0
        for y in 60..<240 {
            for x in 110..<290 {
                let offset = (y * Self.width + x) * 4
                for c in 0..<3 {
                    let diff = abs(Int(rtAlone[offset + c]) - Int(rtNeighbour[offset + c]))
                    if diff > maxDiff {
                        maxDiff = diff
                    }
                }
            }
        }
        print("668 quad alone vs with neighbour max channel diff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1, "unrelated triangles changed the quad's traced AO")
    }

    func testABentNeighbourDoesNotTiltAQuadsTracedAO() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        loadQuad()
        let aloneA = try render(rayTraced: 1)
        let aloneB = try render(rayTraced: 1)
        guard aloneA == aloneB else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        engine.runPython("from pymol import cmd as _c\n_c.delete('seam668q')")
        loadBentQuad()
        let bentA = try render(rayTraced: 1)
        let bentB = try render(rayTraced: 1)
        guard bentA == bentB else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let seam0 = seam(bentA, 0)
        let seam1 = seam(bentA, 1)
        var maxDiff = 0
        for y in 60..<240 {
            for x in 110..<290 {
                let offset = (y * Self.width + x) * 4
                for c in 0..<3 {
                    maxDiff = max(maxDiff, abs(Int(aloneA[offset + c]) - Int(bentA[offset + c])))
                }
            }
        }
        print(String(format: "668 bent seam d0=%.3f d1=%.3f maxDiff=%d", seam0, seam1, maxDiff))
        XCTAssertLessThanOrEqual(seam0, 1.0, "seam across diagonal d=0 next to a bent face")
        XCTAssertLessThanOrEqual(seam1, 1.0, "seam across diagonal d=1 next to a bent face")
        XCTAssertLessThanOrEqual(maxDiff, 1, "a face bent away from the quad changed the quad's traced AO")
    }

    func testTwistedStripKeepsItsSmoothedAO() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        loadStripAndFloor()

        let rt0 = try render(rayTraced: 0)

        let rt1a = try render(rayTraced: 1)
        let rt1b = try render(rayTraced: 1)
        guard rt1a == rt1b else {
            throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
        }
        let rt1 = rt1a

        var fValues = [Double]()
        for x in 185..<215 {
            var sum1 = 0.0
            var sum0 = 0.0
            for y in 147...152 {
                sum1 += lum(rt1, Double(x), Double(y))
                sum0 += lum(rt0, Double(x), Double(y))
            }
            XCTAssertGreaterThan(sum0, 0.0, "rt0 sum at x=\(x) must be > 0")
            fValues.append(sum1 / sum0)
        }

        let meanF = fValues.reduce(0.0, +) / Double(fValues.count)
        print(String(format: "668 strip mean AO=%.4f", meanF))
        XCTAssertEqual(meanF, Self.masterStripAO, accuracy: 0.05,
                       "twisted strip should keep its smoothed AO factor")
    }
}

/// Issue #810: dust_glow and dust_opacity in live Metal renders.
@MainActor
final class DustLookTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
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
        _dl810_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'metal_light_air_time', 'metal_raytrace', 'metal_temporal_ao',
            'metal_light_hdr', 'metal_exposure', 'metal_light_air_resolution',
            'metal_light_air_alpha', 'ray_opaque_background')}
        _dl810_bg = _c.get('bg_rgb')
        _c.set('bg_rgb', 'black')
        _c.set('metal_raytrace', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_light_air_time', 1.25)
        _c.set('metal_light_air_resolution', 1)
        _c.set('metal_light_hdr', 2)
        """)
        LightsLive.addPeptide()
        engine.runPython("from pymol import cmd as _c\n_c.orient('lmt_pep')")
        waitForInFlight()
    }

    override func tearDown() {
        engine.runPython("""
        from pymol import cmd as _c
        for _n, _v in globals().pop('_dl810_settings', {}).items():
            _c.set(_n, _v)
        if '_dl810_bg' in globals():
            _c.set('bg_rgb', globals().pop('_dl810_bg'))
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

    private func export(_ name: String, rayTraced: Int = 0) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_810_\(name).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rayTraced)
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
        return rgba
    }

    private func rig(haze: Double = 0.0, dust: Double, intensity: Double,
                     glow: Double? = nil, opacity: Double? = nil) {
        var airParts = [
            "'haze': \(haze)",
            "'dust': \(dust)",
            "'dust_size': 0.5",
            "'dust_speed': 2.0",
            "'scatter': 0.0",
            "'seed': 7"
        ]
        if let glow { airParts.append("'dust_glow': \(glow)") }
        if let opacity { airParts.append("'dust_opacity': \(opacity)") }
        let airDict = "{" + airParts.joined(separator: ", ") + "}"
        let dict = """
        {'enabled': True, 'centre': list(_lmt_cmd.centerofmass('lmt_pep')), 'size': 10.0,
         'ambient': 0.5, 'classic': 0.5,
         'air': \(airDict),
         'lights': [{'name': 'key', 'orbit': 0.0, 'pitch': 0.0, 'intensity': \(intensity),
                     'shadow': False}]}
        """
        LightsLive.setRig(dict)
    }

    func testDefaultsAreByteIdentical() throws {
        rig(haze: 0.0, dust: 0.8, intensity: 1.5, glow: nil, opacity: nil)
        let absent = try export("defaults_absent")
        rig(haze: 0.0, dust: 0.8, intensity: 1.5, glow: 1.0, opacity: 0.0)
        let explicit = try export("defaults_explicit")
        XCTAssertEqual(absent, explicit, "defaults must be byte-identical to absent keys")
    }

    func testZeroGlowAddsNothing() throws {
        rig(haze: 0.0, dust: 0.0, intensity: 1.5)
        let dust0 = try export("zero_glow_dust0")
        rig(haze: 0.0, dust: 0.8, intensity: 1.5, glow: 0.0, opacity: 0.0)
        let glow0 = try export("zero_glow_glow0")
        XCTAssertEqual(glow0, dust0, "glow 0 (opacity 0) must be byte-identical to dust 0")
    }

    func testGlowScalesTheMotesLight() throws {
        func lum(_ px: [UInt8], _ i: Int) -> Double {
            0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])
        }

        rig(haze: 0.0, dust: 0.0, intensity: 0.6)
        let base = try export("glow_base")
        rig(haze: 0.0, dust: 0.8, intensity: 0.6, glow: 1.0, opacity: 0.0)
        let g1 = try export("glow_1")
        rig(haze: 0.0, dust: 0.8, intensity: 0.6, glow: 0.5, opacity: 0.0)
        let g05 = try export("glow_05")
        rig(haze: 0.0, dust: 0.8, intensity: 0.6, glow: 3.0, opacity: 0.0)
        let g3 = try export("glow_3")

        let width = 400, height = 300
        var moteCount = 0
        var sum1 = 0.0
        var sum05 = 0.0
        var sum3 = 0.0

        for p in 0..<(width * height) {
            let i = p * 4
            let Lbase = lum(base, i)
            let L1 = lum(g1, i)
            let diff1 = L1 - Lbase
            if diff1 >= 2.0 {
                moteCount += 1
                sum1 += diff1
                sum05 += max(0.0, lum(g05, i) - Lbase)
                sum3 += max(0.0, lum(g3, i) - Lbase)
            }
        }

        let ratio05 = sum1 > 0 ? sum05 / sum1 : 0
        let ratio3 = sum1 > 0 ? sum3 / sum1 : 0
        print(String(format: "810-glow motes=%d sum1=%.1f sum05=%.1f (%.3f) sum3=%.1f (%.3f)",
                     moteCount, sum1, sum05, ratio05, sum3, ratio3))

        XCTAssertGreaterThanOrEqual(moteCount, 50, "glow 1 mote pixel count >= 50")
        XCTAssertGreaterThanOrEqual(ratio05, 0.4, "glow 0.5 sum / glow 1 sum within 0.4..0.6")
        XCTAssertLessThanOrEqual(ratio05, 0.6, "glow 0.5 sum / glow 1 sum within 0.4..0.6")
        XCTAssertGreaterThan(ratio3, 1.8, "glow 3 sum / glow 1 sum > 1.8")
    }

    func testOpacityDarkensBehindUnlitMotes() throws {
        engine.runPython("from pymol import cmd as _c\n_c.set('bg_rgb', 'white')")

        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let base = try export("opacity_base")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0, glow: 1.0, opacity: 0.0)
        let op0 = try export("opacity_0")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0, glow: 1.0, opacity: 0.5)
        let op05 = try export("opacity_05")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0, glow: 1.0, opacity: 1.0)
        let op1 = try export("opacity_1")

        XCTAssertEqual(op0, base, "opacity 0 must be byte-identical to dust 0")

        let width = 400, height = 300
        var darkBgCount = 0
        var darkMoleculeCount = 0
        var sumDark1 = 0.0
        var sumDark05 = 0.0

        for p in 0..<(width * height) {
            let i = p * 4
            let isWhiteBg = (base[i] == 255 && base[i + 1] == 255 && base[i + 2] == 255)
            if isWhiteBg {
                let dark = 255.0 - Double(op1[i])
                if dark >= 8.0 {
                    darkBgCount += 1
                }
                if dark > 0.0 {
                    sumDark1 += dark
                    let dark05 = 255.0 - Double(op05[i])
                    sumDark05 += max(0.0, dark05)
                }
            } else {
                if op1[i] < base[i] || op1[i + 1] < base[i + 1] || op1[i + 2] < base[i + 2] {
                    darkMoleculeCount += 1
                }
            }
        }

        let ratioDark = sumDark1 > 0 ? sumDark05 / sumDark1 : 0
        print(String(format: "810-opacity darkBg=%d darkMol=%d sum1=%.1f sum05=%.1f (%.3f)",
                     darkBgCount, darkMoleculeCount, sumDark1, sumDark05, ratioDark))

        XCTAssertGreaterThanOrEqual(darkBgCount, 50, "at least 50 bg pixels darker than 255 by >= 8")
        XCTAssertGreaterThanOrEqual(ratioDark, 0.35, "opacity 0.5 darkening / opacity 1 within 0.35..0.65")
        XCTAssertLessThanOrEqual(ratioDark, 0.65, "opacity 0.5 darkening / opacity 1 within 0.35..0.65")
        XCTAssertGreaterThan(darkMoleculeCount, 0, "molecule pixels must also darken somewhere at opacity 1")
    }

    func testOpaqueMotesCountTowardAlpha() throws {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('ray_opaque_background', 0)
        _c.set('metal_light_air_alpha', 1)
        """)

        rig(haze: 0.0, dust: 0.0, intensity: 0.0)
        let dust0 = try export("alpha_dust0")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0, glow: 1.0, opacity: 0.0)
        let op0 = try export("alpha_op0")
        rig(haze: 0.0, dust: 0.8, intensity: 0.0, glow: 1.0, opacity: 1.0)
        let op1 = try export("alpha_op1")

        let width = 400, height = 300
        var op0AlphaCount = 0
        var op1AlphaCount = 0

        for p in 0..<(width * height) {
            let i = p * 4
            if dust0[i + 3] == 0 {
                if op0[i + 3] > 0 {
                    op0AlphaCount += 1
                }
                if op1[i + 3] > 0 {
                    op1AlphaCount += 1
                }
            }
        }

        print("810-alpha op0Count=\(op0AlphaCount) op1Count=\(op1AlphaCount)")
        XCTAssertEqual(op0AlphaCount, 0, "at opacity 0, background pixels keep alpha 0")
        XCTAssertGreaterThanOrEqual(op1AlphaCount, 50, "at opacity 1, at least 50 background pixels gain alpha > 0")
    }
}

/// Issue #735: ACES as the rig's scene-unit curve under HDR studio lighting.
@MainActor
final class HdrAcesSceneCurveTests: XCTestCase {
    private static let width = 400
    private static let height = 300

    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('ac735*')
            for _n, _v in globals().pop('_ac735_settings', {}).items():
                _c.set(_n, _v)
            _c.set_lights(globals().pop('_ac735_rig', None))
            for _n in globals().pop('_ac735_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _ac735_enabled = _c.get_names('objects', enabled_only=1)
        _ac735_settings = {_n: _c.get_setting_tuple(_n)[1][0] for _n in (
            'bg_rgb', 'depth_cue', 'metal_msaa', 'metal_temporal_ao', 'metal_ssao',
            'metal_rt_ao_intensity', 'metal_shadows', 'metal_rt_shadows',
            'metal_rt_transparent', 'specular', 'metal_light_hdr', 'metal_tonemap',
            'metal_exposure')}
        _ac735_settings['bg_rgb'] = list(_c.get_setting_tuple('bg_rgb')[1])
        _ac735_rig = _c.get_lights()
        for _n in _ac735_enabled:
            _c.disable(_n)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('depth_cue', 0)
        _c.set('metal_msaa', 0)
        _c.set('metal_temporal_ao', 0)
        _c.set('metal_ssao', 0)
        _c.set('metal_rt_ao_intensity', 0.0)
        _c.set('metal_shadows', 0)
        _c.set('metal_rt_shadows', 0)
        _c.set('metal_rt_transparent', 0)
        _c.set('specular', 0.0)
        _c.set('metal_light_hdr', 1)

        _c.pseudoatom('ac735s', pos=[0.0, 0.0, 0.0], vdw=5.0)
        _c.show_as('spheres', 'ac735s')
        _c.set_color('ac735c', [1.0, 0.3, 0.1])
        _c.color('ac735c', 'ac735s')

        _c.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -40, 0, 0, 0, 20, 60, -20))
        """)
    }

    private func render(rayTraced: Int) throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_735_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: Self.width, height: Self.height, rayTraced: rayTraced)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Self.width)
        XCTAssertEqual(image.height, Self.height)
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

    private func assertAcesKeepsHue(rayTraced: Int) throws {
        engine.runPython("""
        from pymol import cmd as _c
        _c.set_lights({'enabled': True, 'ambient': 0.2, 'centre': [0.0, 0.0, 0.0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -20.0, 'pitch': 15.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 0.0, 'shadow': False,
                                   'intensity': 3.0}]})
        _c.set('metal_tonemap', 1)
        _c.set('metal_exposure', 2.0)
        """)

        let rendered: [UInt8]
        if rayTraced == 1 {
            let r1 = try render(rayTraced: 1)
            let r2 = try render(rayTraced: 1)
            guard r1 == r2 else {
                throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
            }
            rendered = r1
        } else {
            rendered = try render(rayTraced: 0)
        }

        var pixels = 0
        var maxHueErr = 0.0
        for p in 0..<(Self.width * Self.height) {
            let offset = p * 4
            let r = Double(rendered[offset])
            let g = Double(rendered[offset + 1])
            let b = Double(rendered[offset + 2])
            guard r >= 200.0, r > g, r > b else { continue }
            let errG = abs(g / r - 0.3)
            let errB = abs(b / r - 0.1)
            let hueErr = max(errG, errB)
            if hueErr > maxHueErr {
                maxHueErr = hueErr
            }
            pixels += 1
        }

        print("735 rt=\(rayTraced) pixels=\(pixels) maxHueErr=\(maxHueErr)")
        XCTAssertGreaterThanOrEqual(pixels, 200, "too few bright highlight pixels to test")
        XCTAssertLessThanOrEqual(maxHueErr, 0.04, "the highlight lost its hue: ACES ran per channel on display values")
    }

    func testAcesKeepsHueUnderHdrRig() throws {
        try requireEngine()
        buildScene()
        try assertAcesKeepsHue(rayTraced: 0)
    }

    func testTracedAcesKeepsHueUnderHdrRig() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        try assertAcesKeepsHue(rayTraced: 1)
    }

    private func narkowiczAces(_ x: Double) -> Double {
        let a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14
        return (x * (a * x + b)) / (x * (c * x + d) + e)
    }

    func testAcesWithoutRigIsThePostPass() throws {
        try requireEngine()
        buildScene()

        engine.runPython("""
        from pymol import cmd as _c
        _c.set_lights(None)
        _c.set('metal_tonemap', 0)
        _c.set('metal_exposure', 1.0)
        """)
        let imgA = try render(rayTraced: 0)

        engine.runPython("""
        from pymol import cmd as _c
        _c.set('metal_tonemap', 1)
        _c.set('metal_exposure', 1.5)
        """)
        let imgB = try render(rayTraced: 0)

        var pixels = 0
        var maxDiff = 0
        for p in 0..<(Self.width * Self.height) {
            let offset = p * 4
            let rA = Double(imgA[offset])
            let gA = Double(imgA[offset + 1])
            let bA = Double(imgA[offset + 2])
            let maxA = max(rA, max(gA, bA))
            guard maxA > 8.0 else { continue }

            for ch in 0..<3 {
                let aVal = Double(imgA[offset + ch])
                let bVal = Int(imgB[offset + ch])
                let inVal = 1.5 * aVal / 255.0
                let acesVal = max(0.0, min(1.0, narkowiczAces(inVal)))
                let expected = Int(round(255.0 * acesVal))
                let diff = abs(bVal - expected)
                if diff > maxDiff {
                    maxDiff = diff
                }
            }
            pixels += 1
        }

        print("735 no-rig pixels=\(pixels) maxDiff=\(maxDiff)")
        XCTAssertGreaterThanOrEqual(pixels, 1000, "too few pixels to test post pass parity")
        XCTAssertLessThanOrEqual(maxDiff, 3, "without a rig the frame is no longer the per-channel ACES post pass")
    }

    /// Hue-preserving ACES on the largest channel, as light_aces (MSL).
    private func acesHue(_ c: [Double]) -> [Double] {
        let m = c.max() ?? 0.0
        guard m > 0.0 else { return [0.0, 0.0, 0.0] }
        let y = min(narkowiczAces(m), 1.0)
        return c.map { $0 * y / m }
    }

    /// Its inverse on a display colour, as light_aces_inverse (MSL).
    private func acesHueInverse(_ c: [Double]) -> [Double] {
        let c = c.map { min(max($0, 0.0), 1.0) }
        let m = c.max() ?? 0.0
        guard m > 0.0 else { return [0.0, 0.0, 0.0] }
        let a = 2.51 - 2.43 * m
        let b = 0.03 - 0.59 * m
        let x = 0.28 * m / (b + (b * b + 0.56 * a * m).squareRoot())
        return c.map { $0 * x / m }
    }

    /// The cast shadow (and AO) darken the scene light through the ACTIVE
    /// curve's inverse: with ACES as the rig's curve, a shadowed pixel at
    /// exposure 1 is A(L * shade), so at exposure 3 it must be
    /// A(3 * Ainv(e1)). Had the shadow pass kept T's inverse while the rig
    /// mapped through ACES, e1 would be A(Tinv(A(L)) * shade) and this
    /// prediction would miss by tens of levels. On master, ACES ran after
    /// the rig per channel and the prediction misses as well.
    private func assertShadowThroughAcesInverse(rayTraced: Int) throws {
        engine.runPython("""
        from pymol import cmd as _c
        _ac735_settings['metal_rt_shadow_intensity'] = _c.get_setting_tuple('metal_rt_shadow_intensity')[1][0]
        _ac735_settings['light'] = list(_c.get_setting_tuple('light')[1])
        _c.delete('ac735s')
        _c.pseudoatom('ac735r', pos=[0.0, 0.0, 0.0], vdw=5.0)
        _c.show_as('spheres', 'ac735r')
        _c.color('ac735c', 'ac735r')
        _c.pseudoatom('ac735o', pos=[2.78, 2.78, 11.96], vdw=1.5)
        _c.show_as('spheres', 'ac735o')
        _c.color('ac735c', 'ac735o')
        _c.set('metal_rt_shadows', 1)
        _c.set('metal_rt_shadow_intensity', 0.45)
        _c.set('light', [-0.4, -0.4, -1.0])
        _c.set('metal_tonemap', 1)
        _c.set_lights({'enabled': True, 'ambient': 0.2, 'centre': [0, 0, 0], 'size': 20.0,
                       'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -20.0, 'pitch': 15.0,
                                   'radius': 3.0, 'beam': 80.0, 'highlight': 0.0, 'shadow': False,
                                   'intensity': 1.0}]})
        _c.set('metal_shadows', 0)
        _c.set('metal_exposure', 1.0)
        """)
        let noShadow = try render(rayTraced: rayTraced)
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', 1)")
        let e1: [UInt8]
        if rayTraced == 1 {
            let a = try render(rayTraced: 1)
            let b = try render(rayTraced: 1)
            guard a == b else {
                throw XCTSkip("two ray-traced frames of the same scene differ: not deterministic here")
            }
            e1 = a
        } else {
            e1 = try render(rayTraced: 0)
        }
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_exposure', 3.0)")
        let e3 = try render(rayTraced: rayTraced)

        var n = 0
        var maxErr = 0
        for p in 0..<(Self.width * Self.height) {
            let o = p * 4
            let no = (0..<3).map { Double(noShadow[o + $0]) }
            let one = (0..<3).map { Double(e1[o + $0]) }
            let maxNo = no.max()!, max1 = one.max()!
            // shadowed (darker by 8+ levels), not near black, and below the
            // clip at exposure 3's input
            guard maxNo - max1 >= 8.0, max1 >= 24.0, max1 <= 200.0 else { continue }
            let pred = acesHue(acesHueInverse(one.map { $0 / 255.0 }).map { 3.0 * $0 })
            let err = (0..<3).map { abs(Int(e3[o + $0]) - Int((pred[$0] * 255.0).rounded())) }.max()!
            maxErr = max(maxErr, err)
            n += 1
        }
        print("735 shadow rt=\(rayTraced) pixels=\(n) maxErr=\(maxErr)")
        XCTAssertGreaterThanOrEqual(n, 100, "too few shadowed pixels to test")
        XCTAssertLessThanOrEqual(maxErr, 3, "the cast shadow did not darken the scene light through ACES's inverse")
    }

    func testShadowUsesTheAcesInverse() throws {
        try requireEngine()
        buildScene()
        try assertShadowThroughAcesInverse(rayTraced: 0)
    }

    func testTracedShadowUsesTheAcesInverse() throws {
        try requireEngine()
        guard engine.rayTracingSupported else {
            throw XCTSkip("Hardware ray tracing is not supported on this device")
        }
        buildScene()
        try assertShadowThroughAcesInverse(rayTraced: 1)
    }
}
