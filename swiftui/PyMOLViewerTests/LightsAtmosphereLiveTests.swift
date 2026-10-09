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
