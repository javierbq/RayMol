import XCTest
@testable import RayMol

// Lights mode in the engine (#619): what each bar button runs, entering and
// leaving the mode, the document-replacement rule, and Revert against the
// LIVE engine (the bridge JSON before entry equals the JSON after Revert).
//
// The controller's own rules (selection, identity slots, enablement) are
// tested on fakes in LightsControllerTests.swift; the Python half
// (appkit_lights, the `lights` command strings) in
// testing/tests/raymol/lighting_mode.py.

// MARK: - What each button runs

/// The exact command strings and the Revert Python. The same literals are run
/// through the core by lighting_mode.py TestBarCommands: change both together.
final class LightsActionInvocationTests: XCTestCase {

    func testCommandStrings() {
        XCTAssertEqual(LightsAction.add.invocation, .command("lights add"))
        XCTAssertEqual(LightsAction.remove("fill").invocation, .command("lights remove, fill"))
        XCTAssertEqual(LightsAction.preset("three_point").invocation, .command("lights three_point"))
        XCTAssertEqual(LightsAction.recenter.invocation, .command("lights recenter"))
        XCTAssertEqual(LightsAction.setEnabled(true).invocation, .command("lights on"))
        XCTAssertEqual(LightsAction.setEnabled(false).invocation, .command("lights off"))
    }

    func testRestoreIsOnePythonCallWithTheBase64OfTheJSON() {
        for json in [#"{"version":1,"enabled":true,"lights":[]}"#, "null", "{\"a\":\"é \\\" '\"}"] {
            let encoded = Data(json.utf8).base64EncodedString()
            XCTAssertEqual(LightsAction.restore(json).invocation,
                           .python("from pymol import appkit_lights as _al\n_al.restore('\(encoded)')"),
                           json)
        }
    }

    func testRestoreLightIsOnePythonCallWithTheBase64OfTheJSONAndTheName() {
        // Revert this light (#620): lighting_inspector.py TestRestoreLight runs
        // the helper with the same arguments.
        for json in [#"{"version":1,"enabled":true,"lights":[]}"#, "null", "{\"a\":\"é \\\" '\"}"] {
            let encoded = Data(json.utf8).base64EncodedString()
            for name in ["key", "Light4", "_x"] {
                XCTAssertEqual(
                    LightsAction.restoreLight(name: name, json: json).invocation,
                    .python("from pymol import appkit_lights as _al\n"
                            + "_al.restore_light('\(encoded)', '\(name)')"),
                    "\(name) \(json)")
            }
        }
    }

    func testBadNamesRunNothing() {
        let bad = ["", "a,b", "a b", "it's", "x\"y", "1key", "key;reinitialize", "é",
                   "key')\nimport os", String(repeating: "a", count: 33)]
        for name in bad {
            XCTAssertNil(LightsAction.remove(name).invocation, "remove \(name)")
            XCTAssertNil(LightsAction.preset(name).invocation, "preset \(name)")
            XCTAssertNil(LightsAction.restoreLight(name: name, json: "null").invocation,
                         "restoreLight \(name)")
            XCTAssertNil(LightsAction.aimAtCentre(name).invocation, "aimAtCentre \(name)")
        }
    }

    /// #699's double-click or double-tap on the aim dot. lighting_gizmo.py
    /// TestAimCentreCommand runs this string through the core.
    func testAimAtCentreStrings() {
        XCTAssertEqual(LightsAction.aimAtCentre("key").invocation, .command("lights key, aim=centre"))
        XCTAssertEqual(LightsAction.aimAtCentre("Light4").invocation, .command("lights Light4, aim=centre"))
    }

    /// #622's ⌥-click: #612's click= helper, run once. lighting_gizmo.py
    /// TestHighlightCommand runs these exact strings through the core.
    func testHighlightStrings() {
        XCTAssertEqual(LightsAction.highlight(name: "key", x: 0.125, y: -0.0625, rim: nil, pin: false).invocation,
                       .command("lights key, click=0.1250/-0.0625"))
        XCTAssertEqual(LightsAction.highlight(name: "key", x: 0.125, y: -0.0625, rim: 145, pin: false).invocation,
                       .command("lights key, click=0.1250/-0.0625, rim=145"))
        XCTAssertEqual(LightsAction.highlight(name: "key", x: 0.125, y: -0.0625, rim: nil, pin: true).invocation,
                       .command("lights key, click=0.1250/-0.0625, pin=1"))
        XCTAssertEqual(LightsAction.highlight(name: "Light4", x: 0.125, y: -0.0625, rim: 145, pin: true).invocation,
                       .command("lights Light4, click=0.1250/-0.0625, rim=145, pin=1"))
        // A zero coordinate, negative zero normalised, and the range ends.
        XCTAssertEqual(LightsAction.highlight(name: "key", x: 0, y: 0.25, rim: nil, pin: false).invocation,
                       .command("lights key, click=0.0000/0.2500"))
        XCTAssertEqual(LightsAction.highlight(name: "key", x: -0.00001, y: -0.0, rim: nil, pin: false).invocation,
                       .command("lights key, click=0.0000/0.0000"))
        XCTAssertEqual(LightsAction.highlight(name: "key", x: -1, y: 1, rim: nil, pin: false).invocation,
                       .command("lights key, click=-1.0000/1.0000"))
        XCTAssertEqual(LightsAction.highlight(name: "key", x: 0.33333, y: -0.99996, rim: 30.4, pin: false).invocation,
                       .command("lights key, click=0.3333/-1.0000, rim=30"))
        XCTAssertEqual(LightsAction.clickCoordinate(-0.00004), "0.0000")
        XCTAssertEqual(LightsAction.rimDegrees(0.6), 1)
        XCTAssertEqual(LightsAction.rimDegrees(179.4), 179)
    }

    func testHighlightRefusalsRunNothing() {
        for name in ["", "a b", "key, rim=1", "1key", "key;reinitialize", "é"] {
            XCTAssertNil(LightsAction.highlight(name: name, x: 0, y: 0, rim: nil, pin: false).invocation, name)
        }
        for bad in [1.00001, -1.00001, 2, .nan, .infinity, -.infinity] {
            XCTAssertNil(LightsAction.highlight(name: "key", x: bad, y: 0, rim: nil, pin: false).invocation, "x \(bad)")
            XCTAssertNil(LightsAction.highlight(name: "key", x: 0, y: bad, rim: nil, pin: false).invocation, "y \(bad)")
        }
        // rim must round to 1...179 (0 is the mirror rule; the helper takes
        // under 180).
        for rim in [0, 0.4, -5, 179.5, 180, 200, .nan, .infinity] {
            XCTAssertNil(LightsAction.highlight(name: "key", x: 0, y: 0, rim: rim, pin: false).invocation,
                         "rim \(rim)")
        }
    }

    /// The Atmosphere card's switch (#726). lighting_atmosphere.py
    /// TestCardCommands runs these exact strings through the core.
    func testAtmosphereStrings() {
        XCTAssertEqual(LightsAction.atmosphereOff.invocation, .command("atmosphere off"))
        XCTAssertEqual(LightsAction.setAir([AirValue("haze", 0.2), AirValue("dust", 0.5)]).invocation,
                       .command("atmosphere haze=0.2, dust=0.5"))
        // A remembered air away from every default, in Swift's shortest
        // round-trip form (1e-05 is a typed value, which passes unrounded).
        XCTAssertEqual(LightsAction.setAir([
            AirValue("haze", 0.00001), AirValue("dust", 0.3), AirValue("dust_size", 0.6),
            AirValue("dust_speed", 2.5), AirValue("scatter", -0.25), AirValue("seed", 7),
        ]).invocation,
            .command("atmosphere haze=1e-05, dust=0.3, dust_size=0.6, dust_speed=2.5, scatter=-0.25, seed=7"))
        XCTAssertEqual(LightsAction.setAir([AirValue("dust_speed", 1), AirValue("scatter", 0.55)]).invocation,
                       .command("atmosphere dust_speed=1.0, scatter=0.55"))
        // A slider value on the grid prints its two decimals at most.
        XCTAssertEqual(LightsAction.setAir([AirValue("haze", AirParameter.haze.rounded(0.1 + 0.25))]).invocation,
                       .command("atmosphere haze=0.35"))
    }

    func testAtmosphereRefusalsRunNothing() {
        let bad: [[AirValue]] = [
            [],
            [AirValue("fog", 0.2)],
            [AirValue("Haze", 0.2)],
            [AirValue("haze;reinitialize", 0.2)],
            [AirValue("enabled", 1)],
            [AirValue("haze", .nan)],
            [AirValue("dust", .infinity)],
            [AirValue("scatter", -.infinity)],
            [AirValue("seed", 1.5)],
            [AirValue("seed", -1)],
            [AirValue("seed", 1e20)],
            [AirValue("haze", 0.2), AirValue("dust", .nan)],
        ]
        for values in bad {
            XCTAssertNil(LightsAction.setAir(values).invocation, "\(values)")
        }
        XCTAssertEqual(AirValue("seed", 0).text, "0")
        XCTAssertEqual(AirValue("seed", 1_000_000).text, "1000000")
    }

    func testRejectionLines() {
        XCTAssertEqual(LightsAction.atmosphereOff.rejectionLine,
                       " atmosphere: not a valid air value; nothing was run")
        XCTAssertEqual(LightsAction.setAir([]).rejectionLine,
                       " atmosphere: not a valid air value; nothing was run")
        for action in [LightsAction.add, .remove("x y"), .preset("1"), .restoreLight(name: "", json: "null"),
                       .highlight(name: "", x: 0, y: 0, rim: nil, pin: false)] {
            XCTAssertEqual(action.rejectionLine, " lights: not a light or preset name; nothing was run")
        }
    }

    func testGoodNames() {
        for name in ["key", "_x", "Light4", "a_b_9", String(repeating: "a", count: 32)] {
            XCTAssertTrue(LightsAction.isValidName(name), name)
            XCTAssertEqual(LightsAction.remove(name).invocation, .command("lights remove, \(name)"))
        }
    }
}

// MARK: - Live-engine support

/// Shared by the live tests below and LightsInspectorLiveTests.swift: wait for
/// the host app's engine, and put the rig, the mode, the view and the taps back
/// afterwards (PyMOLEngine.shared is shared with every other test class).
@MainActor
enum LightsLive {
    static var engine: PyMOLEngine { PyMOLEngine.shared }

    struct EngineNotReady: Error, CustomStringConvertible {
        var description: String { "PyMOLEngine.shared never became ready" }
    }

    /// Wait (up to 20 s) for the engine; XCTFail + throw when it never comes up
    /// (a live test that skipped would have checked nothing). Then leave every
    /// mode, clear the rig and remember the camera.
    static func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready after 20 s: the live Lights test ran nothing")
            throw EngineNotReady()
        }
        engine.setInteractionMode(.viewing)
        engine.runPython(
            "from pymol import cmd as _lmt_cmd, lighting as _lmt_l\n"
            + "_lmt_l.set_lights(None, _self=_lmt_cmd)\n"
            + "if '_lmt_view' not in globals():\n"
            + "    _lmt_view = _lmt_cmd.get_view()\n")
        XCTAssertNil(engine.lightRigJSON(), "the rig was not cleared")
    }

    static func tearDown() {
        engine.pythonTap = nil
        engine.commandTap = nil
        engine.viewportInputTap = nil
        engine.lightsController.eyeDemand = .pinnedOnly
        engine.setInteractionMode(.viewing)
        engine.runPython(
            "from pymol import cmd as _lmt_cmd, lighting as _lmt_l\n"
            + "_lmt_l.set_lights(None, _self=_lmt_cmd)\n"
            + "_lmt_cmd.delete('lmt_pep')\n"
            + "if '_lmt_view' in globals():\n"
            + "    _lmt_cmd.set_view(_lmt_view)\n"
            + "    del _lmt_view\n")
    }

    /// A small peptide, so `lights recenter` has molecules to frame.
    static func addPeptide() {
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.fab('ACDEFG', 'lmt_pep')\n")
    }

    /// Three lights away from the defaults: a camera key with a shadow, a fill
    /// aimed at a point (its selection holds a double quote), a pinned rim;
    /// air set. `enabled` as given.
    static func threeLights(enabled: Bool) -> String {
        """
        {'enabled': \(enabled ? "True" : "False"), 'centre': [0.0, 0.0, 0.0], 'size': 10.0,
         'ambient': 0.1, 'classic': 0.25,
         'air': {'haze': 0.1, 'dust': 0.3, 'dust_size': 0.5, 'dust_speed': 2.0,
                 'scatter': -0.25, 'seed': 7},
         'lights': [
           {'name': 'key', 'orbit': 12.5, 'pitch': 3.0, 'radius': 2.0, 'shadow': True},
           {'name': 'fill', 'orbit': -60.0, 'pitch': 20.0, 'aim': 'point',
            'aim_point': [1.0, 2.0, 3.0], 'aim_selection': 'resn "ALA"',
            'color': [0.5, 0.75, 1.0], 'warmth': 4000.0},
           {'name': 'rim', 'anchor': 'pinned', 'position': [5.0, 6.0, -30.0],
            'outline': True, 'beam': 30.0, 'softness': 0.1}]}
        """
    }

    /// Remove the rig (lighting.set_lights(None)).
    static func clearRig(file: StaticString = #filePath, line: UInt = #line) {
        engine.runPython(
            "from pymol import cmd as _lmt_cmd, lighting as _lmt_l\n"
            + "_lmt_l.set_lights(None, _self=_lmt_cmd)\n")
        XCTAssertNil(engine.lightRigJSON(), "the rig was not cleared", file: file, line: line)
    }

    /// lighting.set_lights(`dict`) in the live interpreter; returns the JSON.
    @discardableResult
    static func setRig(_ dict: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        engine.runPython(
            "from pymol import cmd as _lmt_cmd, lighting as _lmt_l\n"
            + "_lmt_l.set_lights(\(dict), _self=_lmt_cmd)\n")
        let json = engine.lightRigJSON()
        XCTAssertNotNil(json, "set_lights raised", file: file, line: line)
        return json
    }
}

// MARK: - The mode in the engine

@MainActor
final class LightsModeEngineTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }

    override func setUp() {
        super.setUp()
        reset()
    }

    override func tearDown() {
        reset()
        LightsLive.tearDown()
        super.tearDown()
    }

    private func reset() {
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        engine.setBinderDesignMode(false)
        engine.setInteractionMode(.viewing)
    }

    func testEnteringTwiceKeepsTheEntrySnapshot() throws {
        try LightsLive.requireEngine()
        let entry = LightsLive.setRig(LightsLive.threeLights(enabled: true))
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.entryJSON, entry)

        LightsLive.setRig("{'lights': [{'name': 'solo'}]}")
        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.entryJSON, entry,
                       "entering again while in the mode must keep the first snapshot")
        XCTAssertTrue(controller.isActive)
    }

    func testEnteringLightsClearsHoverReadout() {
        engine.hoverReadout = "ALA 12 CA"
        engine.setInteractionMode(.lights)
        XCTAssertNil(engine.hoverReadout,
                     "the hover pick is skipped in Lights mode, so a stale readout would stay up")
    }

    func testEndsLightsModeClassifier() {
        let table: [(String, Bool)] = [
            // full session loads replace the document and its rig (spec §6)
            ("load x.pse", true),
            ("load /tmp/My Session.PSE", true),
            ("  LOAD x.pse, obj  ", true),
            ("load x.psw", true),
            ("load x.pze", true),
            ("load x.pse.gz", true),
            ("load \"a b.pse\"", true),
            ("load x.dat, format=pse", true),
            ("load x.pse, partial=0", true),
            // partial restores skip the rig (spec §6)
            ("load x.pse, partial=1", false),
            ("load x.pse, partial = 1", false),
            ("load x.pse, , 0, , 1, -1, 1, None, -1, 1", false),
            // reinitialize clears the rig only for everything (spec §4.4)
            ("reinitialize", true),
            ("reinitialize everything", true),
            ("reinitialize what=everything", true),
            ("reinitialize settings", false),
            ("reinitialize store", false),
            ("reinitialize store_defaults", false),
            ("reinitialize original_settings", false),
            ("reinitialize purge_defaults", false),
            ("reinitialize everything, pep", false),
            // nothing that keeps the document
            ("save x.pse", false),
            ("load x.pdb", false),
            ("load x.pse.pdb", false),
            ("fetch 1ubq", false),
            ("lights three_point", false),
            // PyMOL's unambiguous prefixes of reinitialize reach it too
            ("reinit", true),
            ("rein", true),
            ("rei", true),
            ("REI everything", true),
            ("rei settings", false),
            ("re", false),
            ("r", false),
            ("reinitializ", true),
            ("reinitializes", false),
            ("reload", false),
            ("", false),
            // a `;` chain ends the mode when any command in it would
            ("zoom; reinitialize", true),
            ("zoom; load x.pdb", false),
        ]
        for (command, expected) in table {
            XCTAssertEqual(PyMOLEngine.endsLightsMode(command: command), expected, command)
        }
    }

    func testDocumentReplacementHookEndsLightsMode() {
        // Only the hook runs, never the command: the shared host keeps its
        // objects and settings.
        engine.setInteractionMode(.lights)
        engine.noteCommandForLightsMode("load x.pdb")
        XCTAssertEqual(engine.interactionMode, .lights)
        XCTAssertTrue(controller.isActive)

        engine.noteCommandForLightsMode("reinitialize settings")
        XCTAssertEqual(engine.interactionMode, .lights)

        engine.noteCommandForLightsMode("reinitialize")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.entryJSON, "the old document's snapshot must go")

        engine.setInteractionMode(.lights)
        engine.noteCommandForLightsMode("load /tmp/x.pse")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)
    }

    func testHookIgnoresCommandsOutsideTheMode() {
        engine.setInteractionMode(.move)
        engine.noteCommandForLightsMode("reinitialize")
        XCTAssertEqual(engine.interactionMode, .move, "only Lights mode is ended by the hook")
    }

    func testDocumentGenerationChangeEndsLightsMode() {
        var generation: UInt32 = 10
        let originalReader = engine.documentGenerationReader
        defer { engine.documentGenerationReader = originalReader }
        engine.documentGenerationReader = { generation }

        engine.setInteractionMode(.lights)
        XCTAssertEqual(engine.interactionMode, .lights)
        XCTAssertTrue(controller.isActive)

        // Generation unchanged -> the mode stays .lights.
        engine.noteDocumentGenerationForLightsMode()
        XCTAssertEqual(engine.interactionMode, .lights)
        XCTAssertTrue(controller.isActive)

        // Generation changes while in Lights mode -> ends the mode.
        generation = 11
        engine.noteDocumentGenerationForLightsMode()
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.entryJSON, "the old document's snapshot must go")

        // Outside Lights mode (e.g. .move), a changed generation does nothing.
        engine.setInteractionMode(.move)
        generation = 12
        engine.noteDocumentGenerationForLightsMode()
        XCTAssertEqual(engine.interactionMode, .move, "only Lights mode is ended by the generation hook")

        // Re-entering after an ended mode takes a fresh baseline, so a stale counter
        // does not immediately end the new session.
        engine.setInteractionMode(.lights)
        XCTAssertEqual(engine.interactionMode, .lights)
        XCTAssertTrue(controller.isActive)
        engine.noteDocumentGenerationForLightsMode()
        XCTAssertEqual(engine.interactionMode, .lights, "stale counter does not end new session")

        generation = 13
        engine.noteDocumentGenerationForLightsMode()
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)
    }

    func testRevertActionRejectsStaleDocumentGeneration() {
        var generation: UInt32 = 20
        let originalReader = engine.documentGenerationReader
        defer { engine.documentGenerationReader = originalReader }
        engine.documentGenerationReader = { generation }

        engine.setInteractionMode(.lights)
        generation = 21
        engine.performLightsAction(.restore("{}"))
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)

        engine.setInteractionMode(.lights)
        generation = 22
        engine.performLightsAction(.restoreLight(name: "key", json: "{}"))
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(controller.isActive)
    }
}

// MARK: - Revert against the live engine

@MainActor
final class LightsRevertBridgeTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }

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

    private final class Lines { var lines: [String] = [] }

    func testRevertRestoresTheRigExactly() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.entryJSON, entry)
        XCTAssertFalse(controller.canRevert, "nothing changed yet")

        // Bridge edits: an orbit, a colour, a position that pins the light.
        controller.select(name: "key")
        XCTAssertEqual(controller.edit("orbit", 47.25), .ok)
        XCTAssertEqual(controller.edit("color", SIMD3(1.0, 0.5, 0.25)), .ok)
        controller.select(name: "fill")
        XCTAssertEqual(controller.edit("position", SIMD3(3.0, 4.0, 5.0)), .ok)
        // Bar actions: add, remove, a preset, Re-centre, off.
        controller.add()
        XCTAssertEqual(controller.rig?.lights.count, 4)
        controller.removeSelected()
        XCTAssertEqual(controller.rig?.lights.count, 3)
        controller.applyPreset("softbox")
        controller.recentre()
        controller.setEnabled(false)
        XCTAssertEqual(controller.isOn, false)
        XCTAssertNotEqual(engine.lightRigJSON(), entry)
        XCTAssertTrue(controller.canRevert)

        controller.revert()
        XCTAssertEqual(engine.lightRigJSON(), entry, "Revert must restore the rig byte for byte")
        XCTAssertFalse(controller.canRevert)
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "fill", "rim"])
    }

    func testRevertToNoRig() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()   // the first light captures its frame from molecules
        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.entryJSON, "null")
        controller.add()
        XCTAssertNotNil(engine.lightRigJSON())
        XCTAssertTrue(controller.canRevert)

        controller.revert()
        XCTAssertNil(engine.lightRigJSON(), "Revert to no rig must remove it (not turn it off)")
        XCTAssertNil(controller.rig)
        XCTAssertFalse(controller.canRevert)
    }

    func testRevertToRigOff() throws {
        try LightsLive.requireEngine()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: false)))
        engine.setInteractionMode(.lights)
        XCTAssertFalse(controller.isOn)
        controller.setEnabled(true)
        XCTAssertTrue(controller.isOn)
        controller.select(index: 2)
        XCTAssertEqual(controller.edit("beam", 45), .ok)

        controller.revert()
        XCTAssertEqual(engine.lightRigJSON(), entry)
        XCTAssertFalse(controller.isOn)
    }

    func testRevertKeepsModeOpenAndRepeats() throws {
        try LightsLive.requireEngine()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        for preset in ["softbox", "three_point"] {
            controller.applyPreset(preset)
            controller.add()
            controller.revert()
            XCTAssertEqual(engine.lightRigJSON(), entry, "after \(preset)")
            XCTAssertEqual(engine.interactionMode, .lights, "Revert must not leave the mode")
            XCTAssertTrue(controller.isActive)
            XCTAssertEqual(controller.entryJSON, entry, "Revert keeps the snapshot")
        }
    }

    func testReEnteringTakesANewSnapshot() throws {
        try LightsLive.requireEngine()
        LightsLive.setRig(LightsLive.threeLights(enabled: true))
        engine.setInteractionMode(.lights)
        controller.add()
        let edited = engine.lightRigJSON()
        engine.setInteractionMode(.viewing)
        XCTAssertNil(controller.entryJSON, "Done drops the snapshot")

        engine.setInteractionMode(.lights)
        XCTAssertEqual(controller.entryJSON, edited, "a new entry snapshots the rig as it is now")
        controller.revert()
        XCTAssertEqual(engine.lightRigJSON(), edited, "Revert goes back to the new entry, not the old one")
    }

    func testDoneAndEscKeepEdits() throws {
        try LightsLive.requireEngine()
        LightsLive.setRig(LightsLive.threeLights(enabled: true))
        engine.setInteractionMode(.lights)
        controller.add()
        let afterAdd = engine.lightRigJSON()
        engine.setInteractionMode(.viewing)              // Done
        XCTAssertEqual(engine.lightRigJSON(), afterAdd, "Done keeps the edits")
        XCTAssertFalse(controller.isActive)

        engine.setInteractionMode(.lights)
        controller.select(index: 0)
        XCTAssertEqual(controller.edit("orbit", 33), .ok)
        let afterEdit = engine.lightRigJSON()
        XCTAssertTrue(engine.exitActiveInteractionMode())  // Esc
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertEqual(engine.lightRigJSON(), afterEdit, "Esc keeps the edits (only Revert discards)")
        XCTAssertFalse(controller.isActive)
    }

    func testEnterAndLeaveWithNoRigCreatesNoRig() throws {
        try LightsLive.requireEngine()
        engine.setInteractionMode(.lights)
        XCTAssertNil(engine.lightRigJSON(), "entering must not create a rig")
        engine.setInteractionMode(.viewing)
        XCTAssertNil(engine.lightRigJSON(), "Done must not create a rig")
        engine.setInteractionMode(.lights)
        XCTAssertTrue(engine.exitActiveInteractionMode())
        XCTAssertNil(engine.lightRigJSON(), "Esc must not create a rig")
    }

    func testContinuousEditsRunNoPython() throws {
        try LightsLive.requireEngine()
        let entry = LightsLive.setRig(LightsLive.threeLights(enabled: true))
        engine.setInteractionMode(.lights)
        controller.select(name: "key")
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        var changes = 0
        var last = entry
        // No run-loop pumping in the loop, so the poll timers cannot fire: every
        // line a tap sees would be the edits' own.
        for i in 0..<50 {
            XCTAssertEqual(controller.edit("orbit", Double(i) * 3 + 1), .ok)
            let json = engine.lightRigJSON()
            if json != last { changes += 1 }
            last = json
        }
        engine.pythonTap = nil
        engine.commandTap = nil
        XCTAssertEqual(changes, 50, "every edit must reach the rig")
        XCTAssertEqual(controller.selectedLight?.orbit, 148)
        XCTAssertEqual(python.lines, [], "a drag tick must run no Python (#610)")
        XCTAssertEqual(commands.lines, [], "a drag tick must run no console command")
    }

    func testBarCommandsReachTheCore() throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        engine.setInteractionMode(.lights)
        let commands = Lines()
        engine.commandTap = { commands.lines.append($0) }

        controller.add()
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key"])
        controller.applyPreset("three_point")
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "fill", "rim"])
        controller.select(name: "fill")
        controller.removeSelected()
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "rim"])
        let centreBefore = controller.rig?.centre
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.translate([10, 0, 0], 'lmt_pep')\n")
        controller.recentre()
        XCTAssertNotEqual(controller.rig?.centre, centreBefore, "Re-centre must move the centre")
        controller.setEnabled(false)
        XCTAssertEqual(controller.isOn, false)
        controller.setEnabled(true)
        XCTAssertEqual(controller.isOn, true)

        engine.commandTap = nil
        XCTAssertEqual(commands.lines, ["lights add", "lights three_point", "lights remove, fill",
                                        "lights recenter", "lights off", "lights on"])
    }

    func testPanelPollMirrorsConsoleEditsOnlyInLightsMode() throws {
        try LightsLive.requireEngine()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        XCTAssertFalse(controller.canRevert)

        // A console edit reaches the bar on the next poll, not before.
        engine.runCommand("lights softbox")
        XCTAssertNotEqual(engine.lightRigJSON(), entry)
        XCTAssertFalse(controller.canRevert, "no poll yet: the bar still shows the entry rig")
        engine.panelPolled.send()
        XCTAssertTrue(controller.canRevert, "the poll must mirror the console edit into the bar")
        let shown = controller.rig

        // Outside Lights mode the poll leaves the controller alone.
        engine.setInteractionMode(.viewing)
        engine.runCommand("lights three_point")
        engine.panelPolled.send()
        XCTAssertEqual(controller.rig, shown, "the poll must not refresh outside Lights mode")
    }

    func testPresetMenuMatchesPython() throws {
        try LightsLive.requireEngine()
        engine.setInteractionMode(.lights)
        XCTAssertFalse(controller.presets.isEmpty, "the preset menu did not load")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-lmt-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.runPython(
            "import json as _lmt_json\n"
            + "from pymol import lighting_commands as _lmt_lc\n"
            + "with open(r'''\(url.path)''', 'w', encoding='utf-8') as _lmt_f:\n"
            + "    _lmt_json.dump([[n, d] for n, d in _lmt_lc.presets()], _lmt_f)\n")
        let data = try Data(contentsOf: url)
        let pairs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String]])
        XCTAssertEqual(controller.presets.map(\.name), pairs.map { $0[0] })
        XCTAssertEqual(controller.presets.map(\.description), pairs.map { $0[1] })
    }
}

// MARK: - Timeline Scene Rename Tests (#655)

final class SceneRenameTimelineTests: XCTestCase {

    func testEmptyListStaysEmpty() {
        let result = PyMOLEngine.renamingScene(in: [], from: "A", to: "B")
        XCTAssertTrue(result.isEmpty)
    }

    func testRenamesOnlyMatchingSceneItemsAndLeavesOthersAlone() {
        let idA1 = UUID()
        let transA1 = PyMOLEngine.Transition(seconds: 3.5, linear: true)
        let itemA1 = PyMOLEngine.TimelineItem(
            id: idA1,
            kind: .scene(name: "A"),
            transition: transA1,
            pinnedState: 2,
            atFrame: 10
        )

        let idCam = UUID()
        let transCam = PyMOLEngine.Transition(seconds: 1.0, linear: false)
        let itemCam = PyMOLEngine.TimelineItem(id: idCam, kind: .camera, transition: transCam)

        let idB = UUID()
        let itemB = PyMOLEngine.TimelineItem(id: idB, kind: .scene(name: "B"))

        let idStates = UUID()
        let spec = PyMOLEngine.StatesSpec(objects: ["obj1"], mode: .sweep, firstModel: 1, lastModel: 5, durationSeconds: 2.0)
        let itemStates = PyMOLEngine.TimelineItem(id: idStates, kind: .states(spec))

        let idA2 = UUID()
        let itemA2 = PyMOLEngine.TimelineItem(id: idA2, kind: .scene(name: "A"))

        let items = [itemA1, itemCam, itemB, itemStates, itemA2]
        let result = PyMOLEngine.renamingScene(in: items, from: "A", to: "C")

        XCTAssertEqual(result.count, 5)

        // itemA1 was renamed to C, keeping id, transition, pinnedState, atFrame
        XCTAssertEqual(result[0].id, idA1)
        XCTAssertEqual(result[0].kind, .scene(name: "C"))
        XCTAssertEqual(result[0].transition, transA1)
        XCTAssertEqual(result[0].pinnedState, 2)
        XCTAssertEqual(result[0].atFrame, 10)

        // itemCam is untouched
        XCTAssertEqual(result[1], itemCam)

        // itemB is untouched
        XCTAssertEqual(result[2], itemB)

        // itemStates is untouched
        XCTAssertEqual(result[3], itemStates)

        // itemA2 was renamed to C, keeping id and other fields
        XCTAssertEqual(result[4].id, idA2)
        XCTAssertEqual(result[4].kind, .scene(name: "C"))
        XCTAssertEqual(result[4].transition, itemA2.transition)
        XCTAssertNil(result[4].pinnedState)
        XCTAssertNil(result[4].atFrame)
    }

    func testUnmatchedSceneNameLeavesItemsUnchanged() {
        let itemA = PyMOLEngine.TimelineItem(kind: .scene(name: "A"))
        let itemB = PyMOLEngine.TimelineItem(kind: .scene(name: "B"))
        let items = [itemA, itemB]
        let result = PyMOLEngine.renamingScene(in: items, from: "Nonexistent", to: "C")
        XCTAssertEqual(result, items)
    }

    func testSceneRenameEventParsesTheFeedbackLine() {
        // raymol_scenes._emit_rename: SCENERENAME:<b64 old>:<b64 new>
        let old = Data("A: one".utf8).base64EncodedString()
        let new = Data("Café".utf8).base64EncodedString()
        let parsed = PyMOLEngine.sceneRenameEvent("SCENERENAME:\(old):\(new)")
        XCTAssertEqual(parsed?.0, "A: one")
        XCTAssertEqual(parsed?.1, "Café")
        XCTAssertNil(PyMOLEngine.sceneRenameEvent("MOVIEEXPORT:{}"))
        XCTAssertNil(PyMOLEngine.sceneRenameEvent("SCENERENAME:not base64!:x"))
        XCTAssertNil(PyMOLEngine.sceneRenameEvent("SCENERENAME:\(old)"))
    }
}

// MARK: - Mouse legend in Lights mode (#677)

final class MouseLegendPresentationTests: XCTestCase {
    func testLightsHidesTheLegendWhateverThePreference() {
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: false, interactionMode: .lights), .hidden)
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: true, interactionMode: .lights), .hidden)
    }

    func testOtherModesFollowThePreference() {
        let modes: [InteractionMode] = [.viewing, .move, .boxSelect]
        for mode in modes {
            XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: false, interactionMode: mode), .expanded, "for mode \(mode)")
            XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: true, interactionMode: mode), .collapsed, "for mode \(mode)")
        }
    }

    func testLeavingLightsRestoresThePreviousPresentation() {
        // Expanded preference: hidden while in lights, expanded again when back to viewing.
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: false, interactionMode: .lights), .hidden)
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: false, interactionMode: .viewing), .expanded)

        // Collapsed preference: hidden while in lights, collapsed again when back to viewing.
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: true, interactionMode: .lights), .hidden)
        XCTAssertEqual(MouseLegendPresentation.resolve(collapsed: true, interactionMode: .viewing), .collapsed)
    }
}
