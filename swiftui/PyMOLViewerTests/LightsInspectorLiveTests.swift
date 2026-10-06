import XCTest
import Combine
import simd
@testable import RayMol

// The inspector's edit path against the LIVE engine (#620): every typed edit
// (LightsEditing.swift) reaches the core through the bridge setters in the same
// main-thread turn, the core's clamps and re-pin rules hold through it, the
// per-frame hook keeps a pinned light's placement in step with the camera, and
// none of it runs Python or a console command. Revert this light and Delete
// are the two button presses: one Python call and the bar's command.
//
// The same rules are tested on fakes in LightsEditingTests.swift; the core's
// own semantics in CI (testing/tests/raymol/lighting_rig.py, lighting_eye.py),
// and the frame hook's gating by lighting_inspector.py TestInspectorSource.

@MainActor
final class LightsInspectorLiveTests: XCTestCase {
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

    /// The three-light fixture on a peptide, Lights mode entered, `name`
    /// selected. Returns the entry JSON.
    @discardableResult
    private func enterWithThreeLights(selecting name: String = "key") throws -> String {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        let entry = try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        controller.select(name: name)
        XCTAssertEqual(controller.selection.name, name)
        return entry
    }

    /// The rig as the core has it now (a bridge read).
    private func coreRig(file: StaticString = #filePath, line: UInt = #line) throws -> LightRigSnapshot {
        try XCTUnwrap(engine.lightRig(), "no rig", file: file, line: line)
    }

    /// Light `index` of the core's rig resolved to eye space now.
    private func coreEye(_ index: Int, file: StaticString = #filePath,
                         line: UInt = #line) throws -> LightEyeSpace.Light {
        let eye = try XCTUnwrap(engine.lightsEyeSpace(), "no eye space", file: file, line: line)
        XCTAssertTrue(eye.lights.indices.contains(index), "no light \(index)", file: file, line: line)
        return eye.lights[index]
    }

    private func assertNear(_ a: Double?, _ b: Double, _ accuracy: Double, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil (\(message))", file: file, line: line) }
        XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
    }

    /// The controller's mirror is the core's rig: an edit is visible to every
    /// observer in the same turn.
    private func assertMirrorIsCurrent(_ message: String = "",
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(controller.rig, engine.lightRig(),
                       "the mirror must be republished in the same turn \(message)",
                       file: file, line: line)
    }

    // MARK: every control reaches the core

    func testEveryControlReachesTheCore() throws {
        try enterWithThreeLights()
        // The sliders, dials and typed fields: `set`, one per parameter.
        let targets: [LightParameter: Double] = [
            .orbit: -45, .pitch: 35, .radius: 3, .intensity: 1.8,
            .warmth: 3800, .beam: 40, .softness: 0.5,
        ]
        for parameter in LightParameter.allCases {
            let target = try XCTUnwrap(targets[parameter])
            let before = engine.lightRigJSON()
            XCTAssertEqual(controller.set(parameter, target), .ok, parameter.label)
            XCTAssertNotEqual(engine.lightRigJSON(), before, "\(parameter.label) did not reach the core")
            assertNear(try coreRig().lights[0].value(of: parameter), target, 1e-9, parameter.label)
            assertNear(controller.value(parameter), target, 1e-9, parameter.label)
            assertMirrorIsCurrent(parameter.label)
        }

        // The steppers: `step`, from the current value.
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        assertNear(try coreRig().lights[0].orbit, -40, 1e-9, "orbit step")
        XCTAssertEqual(controller.step(.pitch, by: -5), .ok)
        assertNear(try coreRig().lights[0].pitch, 30, 1e-9, "pitch step")
        assertMirrorIsCurrent("step")

        // Two-field moves (#621, #622): `setPlacement`.
        XCTAssertEqual(controller.setPlacement(orbit: 100, pitch: -20, radius: 4), .ok)
        let moved = try coreRig().lights[0]
        assertNear(moved.orbit, 100, 1e-9, "placement orbit")
        assertNear(moved.pitch, -20, 1e-9, "placement pitch")
        assertNear(moved.radius, 4, 1e-9, "placement radius")
        assertMirrorIsCurrent("setPlacement")

        // The swatches and the picker: `setColour`.
        XCTAssertEqual(controller.setColour(SIMD3(0, 1, 1)), .ok)
        XCTAssertEqual(try coreRig().lights[0].color, SIMD3(0, 1, 1))
        XCTAssertEqual(controller.setColour(SIMD3(0.25, 0.5, 0.75)), .ok)
        XCTAssertEqual(try coreRig().lights[0].color, SIMD3(0.25, 0.5, 0.75))
        assertMirrorIsCurrent("setColour")

        // Pin: where the light is now; unpin: it follows the camera from there.
        let placed = try coreEye(0)
        XCTAssertEqual(controller.setPinned(true), .ok)
        XCTAssertEqual(try coreRig().lights[0].anchor, .pinned)
        let pinned = try coreEye(0)
        XCTAssertEqual(pinned.anchor, .pinned)
        XCTAssertLessThan(simd_distance(pinned.position, placed.position), 1e-3,
                          "pinning must not move the light")
        XCTAssertEqual(controller.setPinned(false), .ok)
        XCTAssertEqual(try coreRig().lights[0].anchor, .camera)
        XCTAssertLessThan(simd_distance(try coreEye(0).position, placed.position), 1e-3,
                          "unpinning must not move the light")
        assertMirrorIsCurrent("setPinned")

        // Only the selected light was touched.
        let entry = try XCTUnwrap(controller.entryRig)
        XCTAssertEqual(try coreRig().lights[1], entry.lights[1], "fill must be untouched")
        XCTAssertEqual(try coreRig().lights[2], entry.lights[2], "rim must be untouched")
    }

    func testParameterRangesMatchTheCore() throws {
        try enterWithThreeLights()
        for parameter in LightParameter.allCases {
            let range = parameter.range
            let cases: [(sent: Double, expected: Double)]
            if parameter.wraps {
                // Orbit wraps into (-180, 180], as LightAngles.wrap does.
                cases = [(range.lowerBound - 1, 179), (range.upperBound + 1, -179),
                         (range.lowerBound, 180), (range.upperBound, 180),
                         (370, 10)]
                for c in cases { XCTAssertEqual(LightAngles.wrap(c.sent), c.expected, accuracy: 1e-9) }
            } else {
                cases = [(range.lowerBound - 1, range.lowerBound),
                         (range.upperBound + 1, range.upperBound),
                         (range.lowerBound, range.lowerBound),
                         (range.upperBound, range.upperBound)]
            }
            for (sent, expected) in cases {
                XCTAssertEqual(controller.set(parameter, sent), .ok, "\(parameter.label) \(sent)")
                assertNear(try coreRig().lights[0].value(of: parameter), expected, 1e-9,
                           "\(parameter.label) \(sent)")
                assertNear(controller.value(parameter), expected, 1e-9, "\(parameter.label) mirror")
            }
        }
    }

    func testEditsShowInEyeSpaceInTheSameTurn() throws {
        try enterWithThreeLights()
        // What #622 projects: the cone and the position, with no frame between.
        XCTAssertEqual(controller.set(.beam, 60), .ok)
        assertNear(Double(try coreEye(0).cosOuter), cos(30 * Double.pi / 180), 1e-5, "beam")
        XCTAssertEqual(controller.set(.softness, 0.5), .ok)
        assertNear(Double(try coreEye(0).cosInner), cos(15 * Double.pi / 180), 1e-5, "softness")
        XCTAssertEqual(controller.set(.orbit, 90), .ok)
        let key = try coreEye(0)
        let rig = try XCTUnwrap(engine.lightsEyeSpace())
        assertNear(Double(key.orbit), 90, 1e-3, "orbit")
        let offset = key.position - rig.centre
        let distance = Double(rig.size) * 2   // key's radius is 2 scene sizes
        assertNear(Double(offset.x), distance * cos(3 * Double.pi / 180), 1e-2,
                   "orbit +90 is camera-right")
        assertNear(Double(offset.z), 0, 1e-2, "orbit 90 is level with the centre")
        XCTAssertEqual(controller.placement(at: 0), LightPlacement(orbit: 90, pitch: 3, radius: 2))

        // A pinned light's placement is in `eye` in the same turn too (refresh
        // reads eye space while a light is pinned), not one frame later.
        controller.select(name: "rim")
        XCTAssertEqual(controller.set(.orbit, -30), .ok)
        let rim = try coreEye(2)
        XCTAssertEqual(rim.anchor, .pinned)
        assertNear(Double(rim.orbit), -30, 1e-3, "rim orbit in eye space")
        assertNear(controller.placement(at: 2)?.orbit, -30, 1e-3, "rim orbit in eye.placements")
        assertNear(controller.value(.orbit), -30, 1e-3, "rim orbit shown")
    }

    func testRadiusKeepsTheBeam() throws {
        try enterWithThreeLights()
        for (name, index) in [("key", 0), ("rim", 2)] {
            controller.select(name: name)
            XCTAssertEqual(controller.set(.beam, 50), .ok)
            let anchor = try coreRig().lights[index].anchor
            let cosOuter = try coreEye(index).cosOuter
            for radius in [0.5, 3, 8] {
                XCTAssertEqual(controller.set(.radius, radius), .ok, "\(name) \(radius)")
                let light = try coreRig().lights[index]
                XCTAssertEqual(light.beam, 50, "\(name): radius \(radius) changed the beam")
                XCTAssertEqual(light.anchor, anchor, "\(name): radius \(radius) changed the anchor")
                let eye = try coreEye(index)
                XCTAssertEqual(eye.cosOuter, cosOuter, accuracy: 1e-6,
                               "\(name): radius \(radius) changed the cone")
                assertNear(Double(eye.radius), radius, 1e-3, "\(name) radius")
                assertNear(controller.value(.radius), radius, 1e-3, "\(name) radius shown")
            }
        }
    }

    // MARK: pinned lights and the frame hook

    func testPinnedOrbitEditRepins() throws {
        try enterWithThreeLights()
        XCTAssertEqual(controller.setPinned(true), .ok)
        let before = try coreEye(0)
        assertNear(Double(before.orbit), 12.5, 1e-3, "pinned where it was")

        XCTAssertEqual(controller.set(.orbit, 40), .ok)
        let after = try coreEye(0)
        XCTAssertEqual(after.anchor, .pinned, "an orbit edit must keep the light pinned")
        XCTAssertEqual(try coreRig().lights[0].anchor, .pinned)
        assertNear(Double(after.orbit), 40, 1e-3, "orbit")
        assertNear(Double(after.pitch), Double(before.pitch), 1e-3, "pitch derived from where it was")
        assertNear(Double(after.radius), Double(before.radius), 1e-3, "radius derived from where it was")
        assertNear(controller.placement(at: 0)?.orbit, 40, 1e-3, "eye.placements in the same turn")

        // A stepper press on a pinned light adds to its current orbit.
        XCTAssertEqual(controller.step(.orbit, by: 5), .ok)
        assertNear(Double(try coreEye(0).orbit), 45, 1e-3, "step")
        XCTAssertEqual(try coreRig().lights[0].anchor, .pinned)
    }

    func testPlacementsFollowTheCamera() throws {
        try enterWithThreeLights()
        XCTAssertEqual(controller.setPinned(true), .ok)
        engine.lightsFrameRendered()
        let before = try XCTUnwrap(controller.placement(at: 0))
        let fillBefore = try XCTUnwrap(controller.placement(at: 1))

        var controllerChanges = 0
        var eyeChanges = 0
        let watchController = controller.objectWillChange.sink { _ in controllerChanges += 1 }
        let watchEye = controller.eye.objectWillChange.sink { _ in eyeChanges += 1 }
        defer { watchController.cancel(); watchEye.cancel() }

        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.turn('y', 30)\n")
        engine.lightsFrameRendered()

        let after = try XCTUnwrap(controller.placement(at: 0))
        let eye = try coreEye(0)
        XCTAssertEqual(after.orbit, Double(eye.orbit), accuracy: 1e-4, "placement is the eye-space orbit")
        XCTAssertEqual(after.pitch, Double(eye.pitch), accuracy: 1e-4)
        XCTAssertEqual(after.radius, Double(eye.radius), accuracy: 1e-4)
        XCTAssertEqual(abs(LightAngles.wrap(after.orbit - before.orbit)), 30, accuracy: 0.05,
                       "a 30° turn about the camera's y axis must move the pinned orbit by 30°")
        XCTAssertEqual(after.pitch, before.pitch, accuracy: 0.05)
        XCTAssertEqual(after.radius, before.radius, accuracy: 1e-3)
        XCTAssertEqual(controller.placement(at: 1), fillBefore, "a camera light keeps its stored placement")
        XCTAssertEqual(try coreRig().lights[0].anchor, .pinned, "the hook writes nothing")
        XCTAssertGreaterThan(eyeChanges, 0, "the move must be published to the eye state")
        XCTAssertEqual(controllerChanges, 0, "a per-frame publish must not re-render the bar")

        // A still camera publishes nothing more.
        eyeChanges = 0
        engine.lightsFrameRendered()
        XCTAssertEqual(eyeChanges, 0)
    }

    func testFrameHookRefreshesAfterAConsoleRemove() throws {
        try enterWithThreeLights(selecting: "rim")
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.placements.count, 3)
        // Removed behind the mirror's back (no poll): the eye read has two
        // lights, the mirror three, so the hook re-reads the rig rather than
        // publish fill's numbers as rim's.
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.do('lights remove, fill')\n")
        XCTAssertEqual(controller.rig?.lights.count, 3, "no poll yet")
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "rim"])
        XCTAssertEqual(controller.eye.placements.count, 2)
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 1))
        assertNear(controller.placement(at: 1)?.orbit, Double(try coreEye(1).orbit), 1e-4, "rim")
    }

    func testFrameHookDoesNothingOutsideTheMode() throws {
        try enterWithThreeLights()
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.placements.count, 3)
        let json = engine.lightRigJSON()

        engine.setInteractionMode(.viewing)
        XCTAssertEqual(controller.eye.placements, [], "Done clears the eye state")
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.placements, [], "the hook must do nothing outside Lights mode")
        engine.setInteractionMode(.move)
        engine.lightsFrameRendered()
        XCTAssertEqual(controller.eye.placements, [])
        XCTAssertNil(controller.eye.eyeSpace)
        XCTAssertEqual(engine.lightRigJSON(), json, "the hook never writes the rig")
    }

    func testSetPlacementFromThePole() throws {
        try enterWithThreeLights()
        XCTAssertEqual(controller.set(.pitch, 90), .ok)
        XCTAssertEqual(controller.setPinned(true), .ok)
        let pole = try coreEye(0)
        XCTAssertEqual(pole.anchor, .pinned)
        assertNear(Double(pole.pitch), 90, 1e-2, "at the pole")

        // Pitch is written first: written first from the pole, orbit would be
        // re-derived from an undefined angle and lost.
        XCTAssertEqual(controller.setPlacement(orbit: 30, pitch: 20), .ok)
        let moved = try coreEye(0)
        XCTAssertEqual(moved.anchor, .pinned)
        assertNear(Double(moved.orbit), 30, 1e-3, "orbit")
        assertNear(Double(moved.pitch), 20, 1e-3, "pitch")
        assertNear(Double(moved.radius), 2, 1e-3, "radius")
        assertNear(controller.placement(at: 0)?.orbit, 30, 1e-3, "shown orbit")
        assertNear(controller.placement(at: 0)?.pitch, 20, 1e-3, "shown pitch")
    }

    // MARK: no Python per edit

    func testInspectorEditsRunNoPython() throws {
        try enterWithThreeLights()
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }

        // Every kind of inspector control, 12 kinds x 5 rounds. No run-loop
        // pumping in the loop, so the poll timers cannot fire: every line a tap
        // sees would be the edits' own.
        let edits: [(String, (Double) -> LightSetResult)] = [
            ("orbit dial", { self.controller.set(.orbit, -60 + 25 * $0) }),
            ("pitch dial", { self.controller.set(.pitch, -20 + 10 * $0) }),
            ("radius slider", { self.controller.set(.radius, 1 + 0.5 * $0) }),
            ("intensity slider", { self.controller.set(.intensity, 0.5 + 0.3 * $0) }),
            ("warmth slider", { self.controller.set(.warmth, 2000 + 1000 * $0) }),
            ("beam slider", { self.controller.set(.beam, 20 + 10 * $0) }),
            ("softness slider", { self.controller.set(.softness, 0.1 + 0.15 * $0) }),
            ("orbit stepper", { _ in self.controller.step(.orbit, by: 5) }),
            ("pitch stepper", { _ in self.controller.step(.pitch, by: -5) }),
            ("placement", { self.controller.setPlacement(orbit: 100 - 10 * $0, pitch: 15 + $0,
                                                         radius: 3 + 0.2 * $0) }),
            ("colour", { self.controller.setColour(SIMD3(1, 0.2 * $0, 0.5)) }),
            ("pin", { self.controller.setPinned(Int($0) % 2 == 0) }),
        ]
        var count = 0
        var changes = 0
        var last = engine.lightRigJSON()
        for round in 0..<5 {
            for (name, edit) in edits {
                XCTAssertEqual(edit(Double(round)), .ok, "\(name), round \(round)")
                count += 1
                let json = engine.lightRigJSON()
                if json != last { changes += 1 }
                last = json
            }
        }
        engine.pythonTap = nil
        engine.commandTap = nil
        XCTAssertEqual(count, 60)
        XCTAssertEqual(changes, 60, "every edit must reach the rig")
        XCTAssertEqual(python.lines, [], "an inspector edit must run no Python (#610)")
        XCTAssertEqual(commands.lines, [], "an inspector edit must run no console command")
    }

    // MARK: the two button presses

    func testRevertThisLightRestoresOnlyThatLight() throws {
        let entry = try enterWithThreeLights()
        let entryRig = try LightRigSnapshot.decode(Data(entry.utf8))
        XCTAssertFalse(controller.canRevertLight, "nothing changed yet")

        XCTAssertEqual(controller.set(.orbit, 70), .ok)
        XCTAssertEqual(controller.setColour(SIMD3(0, 1, 1)), .ok)
        XCTAssertEqual(controller.setPinned(true), .ok)
        controller.select(name: "fill")
        XCTAssertEqual(controller.set(.intensity, 2.5), .ok)
        controller.select(name: "key")
        XCTAssertTrue(controller.canRevertLight)

        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        controller.revertSelectedLight()
        engine.pythonTap = nil
        engine.commandTap = nil

        let encoded = Data(entry.utf8).base64EncodedString()
        XCTAssertEqual(python.lines,
                       ["from pymol import appkit_lights as _al\n_al.restore_light('\(encoded)', 'key')"],
                       "Revert this light is exactly one Python call")
        XCTAssertEqual(commands.lines, [])
        let now = try coreRig()
        XCTAssertEqual(now.lights.map(\.name), ["key", "fill", "rim"])
        XCTAssertEqual(now.lights[0], entryRig.lights[0], "key must be back as it was at entry")
        XCTAssertEqual(now.lights[1].intensity, 2.5, "fill keeps its edit")
        XCTAssertEqual(now.lights[2], entryRig.lights[2])
        XCTAssertEqual(now.ambient, entryRig.ambient)
        XCTAssertEqual(now.air, entryRig.air)
        assertMirrorIsCurrent("after Revert this light")
        XCTAssertEqual(controller.selection, LightSelection(name: "key", index: 0))
        XCTAssertFalse(controller.canRevertLight, "key is back: nothing left to revert")
        controller.select(name: "fill")
        XCTAssertTrue(controller.canRevertLight, "fill still differs from its entry")
    }

    func testDeleteRunsTheBarCommand() throws {
        try enterWithThreeLights(selecting: "fill")
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        controller.removeSelected()
        engine.pythonTap = nil
        engine.commandTap = nil

        XCTAssertEqual(commands.lines, ["lights remove, fill"])
        XCTAssertEqual(python.lines, [], "Delete is the bar's console command, not Python")
        XCTAssertEqual(try coreRig().lights.map(\.name), ["key", "rim"])
        XCTAssertEqual(controller.rig?.lights.map(\.name), ["key", "rim"])
        XCTAssertEqual(controller.selection, LightSelection(name: "rim", index: 1),
                       "the light that slid into the slot is selected")
        XCTAssertEqual(controller.eye.placements.count, 2)
    }

    // MARK: visibility

    /// The card shows (LightsInspectorState exists: the mode is active with a
    /// selected light) and its controls are live.
    private var inspectorShows: Bool {
        LightsInspectorState(controller) != nil && controller.canEdit
    }

    func testInspectorHiddenOutsideTheMode() throws {
        try enterWithThreeLights()
        XCTAssertTrue(inspectorShows)

        engine.setInteractionMode(.viewing)   // Done
        XCTAssertFalse(inspectorShows, "after Done")
        XCTAssertNil(LightsInspectorState(controller), "the card draws nothing after Done")
        let json = engine.lightRigJSON()
        XCTAssertEqual(controller.set(.orbit, 80), .badIndex, "an edit after Done is refused")
        XCTAssertEqual(engine.lightRigJSON(), json)
        XCTAssertEqual(controller.eye.placements, [])

        engine.setInteractionMode(.lights)
        XCTAssertTrue(inspectorShows)
        XCTAssertTrue(engine.exitActiveInteractionMode())   // Esc
        XCTAssertFalse(inspectorShows, "after Esc")

        engine.setInteractionMode(.lights)
        XCTAssertTrue(inspectorShows)
        engine.setInteractionMode(.move)
        XCTAssertFalse(inspectorShows, "after entering Move")
        XCTAssertEqual(controller.setColour(SIMD3(1, 0, 0)), .badIndex)
        XCTAssertEqual(engine.lightRigJSON(), json)

        // In the mode with no rig there is nothing to inspect.
        engine.setInteractionMode(.viewing)
        LightsLive.clearRig()
        engine.setInteractionMode(.lights)
        XCTAssertFalse(inspectorShows, "no light, no inspector")
    }
}
