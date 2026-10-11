import XCTest
import Combine
import CoreGraphics
import simd
@testable import RayMol

// The orbit mini viewer (#621) against the LIVE engine: every press and drag
// tick goes through LightsOrbitInteraction with the card's own layout
// (LightsOrbitMetrics, the platform slop), as the view and the DEBUG gestures
// do, and reaches the core through the owner-guarded bridge setter in the same
// main-thread turn. So:
// - what the plan sets is what the core's JSON, the inspector rows and the eye
//   space the renderer resolves (LightRigResolve) all hold;
// - a pinned lamp circles the plan as the camera turns (the #620 frame hook);
// - the arc writes pitch only, the square radius only (the beam is kept);
// - Float noise on a pinned light writes nothing;
// - no gesture tick runs Python or a console command (#610);
// - a plan tap selects in the bar, and the card is gone outside the mode.
//
// The same rules are tested on fakes in LightsOrbitTests.swift. CI checks that
// the eye space is the block the Metal renderer reads, and its plan
// decomposition (testing/tests/raymol/lighting_orbit.py).

@MainActor
final class LightsOrbitLiveTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var controller: LightsController { engine.lightsController }
    private var interaction: LightsOrbitInteraction { LightsOrbitInteraction(controller: controller) }

    private final class Lines { var lines: [String] = [] }
    private struct NoSuchLight: Error {}

    /// Gesture ticks driven by the helpers below (a tick is one pointer move
    /// or pinch change, whether or not it wrote).
    private var ticks = 0

    override func setUp() {
        super.setUp()
        ticks = 0
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

    /// The three-light fixture on a peptide (key: a camera light at orbit
    /// 12.5, pitch 3, radius 2; fill: an aimed camera light; rim: pinned),
    /// Lights mode entered, `name` selected, the per-frame placements read.
    private func enterWithThreeLights(selecting name: String = "key") throws {
        try LightsLive.requireEngine()
        LightsLive.addPeptide()
        try XCTUnwrap(LightsLive.setRig(LightsLive.threeLights(enabled: true)))
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        controller.select(name: name)
        XCTAssertEqual(controller.selection.name, name)
        engine.lightsFrameRendered()
    }

    /// The card as it is drawn now: its state and its plan and arc layouts.
    private func card(_ c: LightsController? = nil, file: StaticString = #filePath,
                      line: UInt = #line) throws -> (state: LightsOrbitState, plan: OrbitPlanLayout,
                                                     arc: PitchArcLayout) {
        let state = try XCTUnwrap(LightsOrbitState(c ?? controller), "the orbit card shows nothing",
                                  file: file, line: line)
        return (state, OrbitPlanLayout(extent: state.extent), PitchArcLayout())
    }

    /// The rig as the core has it now (a bridge read).
    private func coreRig(file: StaticString = #filePath, line: UInt = #line) throws -> LightRigSnapshot {
        try XCTUnwrap(engine.lightRig(), "no rig", file: file, line: line)
    }

    /// The core's rig resolved to eye space now (what the renderer resolves).
    private func coreEyeSpace(file: StaticString = #filePath, line: UInt = #line) throws -> LightEyeSpace {
        try XCTUnwrap(engine.lightsEyeSpace(), "no eye space", file: file, line: line)
    }

    private func coreEye(_ index: Int, file: StaticString = #filePath,
                         line: UInt = #line) throws -> LightEyeSpace.Light {
        let eye = try coreEyeSpace(file: file, line: line)
        guard eye.lights.indices.contains(index) else {
            XCTFail("no light \(index)", file: file, line: line)
            throw NoSuchLight()
        }
        return eye.lights[index]
    }

    private func assertNear(_ a: Double?, _ b: Double, _ accuracy: Double, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil (\(message))", file: file, line: line) }
        XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
    }

    /// Orbits compared around the circle.
    private func assertSameOrbit(_ a: Double?, _ b: Double, _ accuracy: Double, _ message: String = "",
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil (\(message))", file: file, line: line) }
        XCTAssertEqual(LightAngles.wrap(a - b), 0, accuracy: accuracy, message, file: file, line: line)
    }

    /// Drag `session` along `path` (t in (0, 1]) in `steps` ticks; the results
    /// of the ticks that wrote. Every tick is checked against the core in the
    /// same turn: a write changed the core's JSON, the mirror is the core's rig
    /// and the shown value is the snapped one sent; a tick that wrote nothing
    /// left the core as it was.
    @discardableResult
    private func drag(_ session: inout OrbitDragSession, on c: LightsController? = nil, steps: Int = 12,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ path: (Double) -> CGPoint) -> [LightSetResult] {
        let c = c ?? controller
        let interaction = LightsOrbitInteraction(controller: c)
        var results: [LightSetResult] = []
        for k in 1...steps {
            let before = engine.lightRigJSON()
            let result = interaction.move(&session, to: path(Double(k) / Double(steps)))
            ticks += 1
            checkTick(result, sent: session.lastSent, parameter: session.parameter, before: before, on: c,
                      file: file, line: line)
            if let result { results.append(result) }
        }
        return results
    }

    private func checkTick(_ result: LightSetResult?, sent: Double?, parameter: LightParameter,
                           before: String?, on c: LightsController,
                           file: StaticString, line: UInt) {
        let after = engine.lightRigJSON()
        guard result == .ok else {
            XCTAssertEqual(after, before, "a tick that wrote nothing changed the core", file: file, line: line)
            return
        }
        XCTAssertNotEqual(after, before, "a \(parameter.field) write did not reach the core",
                          file: file, line: line)
        XCTAssertEqual(c.rig, engine.lightRig(), "the mirror must be republished in the same turn",
                       file: file, line: line)
        guard let sent else { return XCTFail("a write with nothing sent", file: file, line: line) }
        XCTAssertTrue(LightSnap.same(c.value(parameter) ?? .nan, sent, wraps: parameter.wraps),
                      "\(parameter.field): shown \(c.value(parameter) ?? .nan), sent \(sent)",
                      file: file, line: line)
    }

    /// Press `name`'s lamp at its centre and drag it along its ring to
    /// `orbit`, in strokes of at most 120° (each a gesture of `steps` ticks).
    @discardableResult
    private func dragLamp(_ name: String, to orbit: Double, on c: LightsController? = nil, steps: Int = 12,
                          file: StaticString = #filePath, line: UInt = #line) throws -> [LightSetResult] {
        let c = c ?? controller
        var results: [LightSetResult] = []
        for _ in 0..<3 {
            let card = try card(c, file: file, line: line)
            let lamp = try XCTUnwrap(card.state.lamp(named: name), "no lamp \(name)", file: file, line: line)
            let sweep = LightAngles.wrap(orbit - lamp.orbit)
            guard abs(sweep) > 1e-9 else { break }
            let stroke = max(min(sweep, 120), -120)
            let press = card.plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            var session = try XCTUnwrap(
                LightsOrbitInteraction(controller: c).beginPlan(at: press, state: card.state, layout: card.plan),
                "a press on \(name)'s lamp started nothing", file: file, line: line)
            XCTAssertEqual(session.target, .lamp(name: lamp.name, index: lamp.index), file: file, line: line)
            let distance = card.plan.drawnDistance(radius: lamp.radius)
            results += drag(&session, on: c, steps: steps, file: file, line: line) { t in
                card.plan.point(orbit: lamp.orbit + stroke * t, distance: distance)
            }
            if abs(stroke) == abs(sweep) { break }
        }
        return results
    }

    /// Press the selected light's radius square and drag it radially to
    /// `radius` at the plan's (frozen) scale.
    @discardableResult
    private func dragSquare(to radius: Double, on c: LightsController? = nil, steps: Int = 12,
                            file: StaticString = #filePath, line: UInt = #line) throws -> [LightSetResult] {
        let c = c ?? controller
        let card = try card(c, file: file, line: line)
        let s = card.state.selected
        let angle = card.plan.squareAngle(radius: s.radius)
        var session = try XCTUnwrap(
            LightsOrbitInteraction(controller: c).beginPlan(
                at: card.plan.squarePoint(orbit: s.orbit, radius: s.radius, angle: angle),
                state: card.state, layout: card.plan),
            "a press on the square started nothing", file: file, line: line)
        XCTAssertEqual(session.target, .radiusSquare, file: file, line: line)
        let from = card.plan.drawnDistance(radius: s.radius)
        let to = card.plan.ringRadius(radius)
        return drag(&session, on: c, steps: steps, file: file, line: line) { t in
            card.plan.point(orbit: s.orbit - angle, distance: from + (to - from) * CGFloat(t))
        }
    }

    /// Press the pitch handle and drag it along the arc to `pitch`.
    @discardableResult
    private func dragArc(to pitch: Double, on c: LightsController? = nil, steps: Int = 12,
                         file: StaticString = #filePath, line: UInt = #line) throws -> [LightSetResult] {
        let c = c ?? controller
        let card = try card(c, file: file, line: line)
        let s = card.state.selected
        var session = try XCTUnwrap(
            LightsOrbitInteraction(controller: c).beginArc(at: card.arc.point(pitch: s.pitch),
                                                           state: card.state, layout: card.arc),
            "a press on the pitch handle started nothing", file: file, line: line)
        XCTAssertEqual(session.target, .pitchHandle, file: file, line: line)
        return drag(&session, on: c, steps: steps, file: file, line: line) { t in
            card.arc.point(pitch: s.pitch + (pitch - s.pitch) * t)
        }
    }

    /// A pinch on the plan from 1 to `factor`.
    @discardableResult
    private func pinch(to factor: Double, steps: Int = 12,
                       file: StaticString = #filePath, line: UInt = #line) throws -> [LightSetResult] {
        var session = try XCTUnwrap(interaction.beginPinch(), "the pinch started nothing",
                                    file: file, line: line)
        var results: [LightSetResult] = []
        for k in 1...steps {
            let before = engine.lightRigJSON()
            let result = interaction.pinch(&session, magnification: 1 + (factor - 1) * Double(k) / Double(steps))
            ticks += 1
            checkTick(result, sent: session.lastSent, parameter: .radius, before: before, on: controller,
                      file: file, line: line)
            if let result { results.append(result) }
        }
        return results
    }

    /// A second LightsController on the live engine's bridge (the engine's
    /// own seams, plus counters), so a test can count the setter calls that
    /// reach the core.
    private final class Spy {
        var numberWrites: [(index: Int, field: String, value: Double)] = []
        var vectorWrites = 0
        var performed: [LightsAction] = []
    }

    private func spyController() -> (LightsController, Spy) {
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
            eyeSpace: { engine.lightsEyeSpace() }))
        c.begin()
        return (c, spy)
    }

    // MARK: the plan matches the inspector, the core and the render

    func testPlanEditsMatchTheInspectorAndTheRender() throws {
        try enterWithThreeLights()
        let entry = try XCTUnwrap(controller.entryRig)

        // Key's lamp dragged towards +100° (snaps to 105), the pitch handle to
        // +20°, the square to 2.5×: each writes only its own field.
        let lamp = try dragLamp("key", to: 100)
        XCTAssertFalse(lamp.isEmpty)
        XCTAssertTrue(lamp.allSatisfy { $0 == .ok })
        XCTAssertEqual(try coreRig().lights[0].orbit, 105, "the lamp snaps to the 15° grid")
        XCTAssertEqual(try coreRig().lights[0].pitch, 3, "a lamp drag writes orbit only")
        XCTAssertEqual(try coreRig().lights[0].radius, 2, "a lamp drag writes orbit only")

        XCTAssertFalse(try dragArc(to: 20).isEmpty)
        XCTAssertEqual(try coreRig().lights[0].orbit, 105, "the arc writes pitch only")
        XCTAssertFalse(try dragSquare(to: 2.5).isEmpty)

        // The core's JSON.
        let key = try coreRig().lights[0]
        XCTAssertEqual(key.orbit, 105)
        XCTAssertEqual(key.pitch, 20)
        XCTAssertEqual(key.radius, 2.5)
        XCTAssertEqual(key.anchor, .camera)
        XCTAssertEqual(key.beam, entry.lights[0].beam, "the plan never writes the beam")
        XCTAssertEqual(key.intensity, entry.lights[0].intensity)
        XCTAssertEqual(key.color, entry.lights[0].color, "the plan never changes a light's colour")
        XCTAssertEqual(try coreRig().lights[1], entry.lights[1], "fill untouched")
        XCTAssertEqual(try coreRig().lights[2], entry.lights[2], "rim untouched")

        // The inspector's rows and the plan show the same, from the one mirror.
        let inspector = try XCTUnwrap(LightsInspectorState(controller))
        XCTAssertEqual(inspector.row(.orbit)?.value, 105)
        XCTAssertEqual(inspector.row(.pitch)?.value, 20)
        XCTAssertEqual(inspector.row(.radius)?.value, 2.5)
        let card = try card()
        XCTAssertEqual(card.state.selected.orbit, 105)
        XCTAssertEqual(card.state.selected.pitch, 20)
        XCTAssertEqual(card.state.selected.radius, 2.5)
        XCTAssertEqual(card.state.radiusText, inspector.row(.radius)?.text)
        XCTAssertTrue(card.state.summary.hasPrefix("key,orbit:105.0,pitch:20.0,radius:2.50,"),
                      card.state.summary)

        // Eye space (the renderer's LightRigResolve): d = p - c decomposes as
        // the plan draws it.
        let eye = try coreEyeSpace()
        let light = eye.lights[0]
        let d = SIMD3<Double>(light.position - eye.centre)
        let length = simd_length(d)
        let size = Double(eye.size)
        XCTAssertGreaterThan(size, 0)
        assertNear(length / size, 2.5, 2.5e-4, "|d| / size is the radius")
        assertNear(asin(d.y / length) * 180 / .pi, 20, 1e-2, "asin(d.y / |d|) is the pitch")
        assertSameOrbit(atan2(d.x, d.z) * 180 / .pi, 105, 1e-2, "atan2(d.x, d.z) is the orbit")
        assertSameOrbit(Double(light.orbit), 105, 1e-3, "eye orbit")
        assertNear(Double(light.pitch), 20, 1e-3, "eye pitch")
        assertNear(Double(light.radius), 2.5, 1e-4, "eye radius")

        // Its (x, z) direction is the plan's lamp direction (camera at the
        // bottom: eye +z is screen down, eye +x screen right).
        let drawn = card.plan.lampPoint(orbit: card.state.selected.orbit, radius: card.state.selected.radius)
        let onPlan = simd_normalize(SIMD2<Double>(Double(drawn.x - card.plan.centre.x),
                                                  Double(drawn.y - card.plan.centre.y)))
        let inEye = simd_normalize(SIMD2<Double>(d.x, d.z))
        XCTAssertLessThan(simd_distance(onPlan, inEye), 1e-4,
                          "plan direction \(onPlan) vs eye-space (x, z) \(inEye)")
        assertNear(Double(hypot(drawn.x - card.plan.centre.x, drawn.y - card.plan.centre.y)
                          / card.plan.pointsPerSize), 2.5, 1e-6, "drawn on its 2.5× ring")
    }

    // MARK: pinned lamps

    func testPinnedLampsCircleAsTheCameraTurns() throws {
        try enterWithThreeLights(selecting: "rim")
        let before = try card().state
        let rim = try XCTUnwrap(before.lamp(named: "rim"))
        XCTAssertTrue(rim.isPinned)
        let key = try XCTUnwrap(before.lamp(named: "key"))
        let fill = try XCTUnwrap(before.lamp(named: "fill"))
        let plan = OrbitPlanLayout(extent: before.extent)
        let drawnBefore = plan.lampPoint(orbit: rim.orbit, radius: rim.radius)

        let controllerChanges = LightsChangeCounter()
        let watch = controller.objectWillChange.sink { _ in controllerChanges.count += 1 }
        defer { watch.cancel() }

        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.turn('y', 30)\n")
        engine.lightsFrameRendered()

        let after = try card().state
        let moved = try XCTUnwrap(after.lamp(named: "rim"))
        XCTAssertEqual(abs(LightAngles.wrap(moved.orbit - rim.orbit)), 30, accuracy: 0.5,
                       "a 30° turn about the camera's y axis moves the pinned lamp 30° round the plan")
        let eye = try coreEye(2)
        XCTAssertEqual(moved.orbit, Double(eye.orbit), accuracy: 1e-4, "the lamp is at the eye-space orbit")
        XCTAssertEqual(moved.pitch, Double(eye.pitch), accuracy: 1e-4)
        XCTAssertEqual(moved.radius, Double(eye.radius), accuracy: 1e-4)
        XCTAssertEqual(moved.pitch, rim.pitch, accuracy: 0.05, "a turn about y keeps the pitch")
        XCTAssertEqual(moved.radius, rim.radius, accuracy: 1e-3, "a turn keeps the radius")
        let drawnAfter = OrbitPlanLayout(extent: after.extent).lampPoint(orbit: moved.orbit, radius: moved.radius)
        XCTAssertGreaterThan(hypot(drawnAfter.x - drawnBefore.x, drawnAfter.y - drawnBefore.y), 10,
                             "the lamp is drawn somewhere else")
        XCTAssertEqual(after.selected.name, "rim")
        XCTAssertEqual(after.selected.orbit, moved.orbit, "the arc and labels follow too")

        // Camera lights stay put on the plan (decision 6).
        // (Its aim point is a world point, so its beam tick may turn: not compared.)
        func placed(_ lamp: LightsOrbitState.Lamp?) -> LightsOrbitState.Lamp? {
            lamp.map { var l = $0; l.aimOffset = nil; return l }
        }
        XCTAssertEqual(placed(after.lamp(named: "key")), placed(key), "a camera light does not move")
        XCTAssertEqual(placed(after.lamp(named: "fill")), placed(fill))
        XCTAssertEqual(Double(try coreEye(0).orbit), 12.5, accuracy: 1e-3)
        XCTAssertEqual(try coreRig().lights[2].anchor, .pinned, "the frame hook writes nothing")
        XCTAssertEqual(controllerChanges.count, 0, "a per-frame publish must not re-render the bar")

        // And back.
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.turn('y', -30)\n")
        engine.lightsFrameRendered()
        let back = try XCTUnwrap(try card().state.lamp(named: "rim"))
        XCTAssertEqual(LightAngles.wrap(back.orbit - rim.orbit), 0, accuracy: 0.05)
    }

    // MARK: each control writes only its own field

    func testPitchArcKeepsOrbitAndRadius() throws {
        try enterWithThreeLights()

        // A camera light: orbit and radius are stored, and kept exactly.
        let before = try coreRig().lights[0]
        let results = try dragArc(to: -40)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0 == .ok })
        let after = try coreRig().lights[0]
        XCTAssertEqual(after.pitch, -40)
        XCTAssertEqual(after.orbit, before.orbit, "the arc keeps the orbit")
        XCTAssertEqual(after.radius, before.radius, "the arc keeps the radius")
        XCTAssertEqual(after.anchor, .camera)
        XCTAssertEqual(after.beam, before.beam)

        // A pinned light: the core re-pins and derives orbit and radius from
        // where it is, so they stay (to Float precision).
        controller.select(name: "rim")
        engine.lightsFrameRendered()
        let rim = try coreEye(2)
        let pitch = Double(rim.pitch).rounded() + (rim.pitch > 0 ? -25 : 25)
        XCTAssertFalse(try dragArc(to: pitch).isEmpty)
        let moved = try coreEye(2)
        XCTAssertEqual(moved.anchor, .pinned, "the arc keeps the light pinned")
        XCTAssertEqual(try coreRig().lights[2].anchor, .pinned)
        assertNear(Double(moved.pitch), pitch, 1e-3, "rim pitch")
        assertSameOrbit(Double(moved.orbit), Double(rim.orbit), 1e-2, "the arc keeps a pinned orbit")
        assertNear(Double(moved.radius), Double(rim.radius), 1e-3, "the arc keeps a pinned radius")
        let lamp = try XCTUnwrap(try card().state.lamp(named: "rim"))
        assertNear(lamp.pitch, pitch, 1e-3, "the plan shows it")
        assertSameOrbit(lamp.orbit, Double(moved.orbit), 1e-4)
        XCTAssertEqual(try coreRig().lights[0], after, "key untouched")
    }

    func testRadiusSquareKeepsTheBeam() throws {
        try enterWithThreeLights()
        for (name, index, radius) in [("key", 0, 3.5), ("rim", 2, 2.0)] {
            controller.select(name: name)
            XCTAssertEqual(controller.set(.beam, 50), .ok, name)   // the inspector's slider
            engine.lightsFrameRendered()
            let light = try coreRig().lights[index]
            let eye = try coreEye(index)

            let results = try dragSquare(to: radius)
            XCTAssertFalse(results.isEmpty, name)
            XCTAssertTrue(results.allSatisfy { $0 == .ok }, name)
            let now = try coreRig().lights[index]
            let nowEye = try coreEye(index)
            XCTAssertEqual(now.beam, 50, "\(name): the square changed the beam")
            XCTAssertEqual(nowEye.cosOuter, eye.cosOuter, accuracy: 1e-6, "\(name): the cone changed")
            XCTAssertEqual(nowEye.cosInner, eye.cosInner, accuracy: 1e-6, "\(name): the soft edge changed")
            XCTAssertEqual(now.anchor, light.anchor, "\(name): the anchor changed")
            XCTAssertEqual(now.softness, light.softness)
            XCTAssertEqual(now.intensity, light.intensity)
            assertNear(Double(nowEye.radius), radius, 1e-3, "\(name) radius")
            assertSameOrbit(Double(nowEye.orbit), Double(eye.orbit), 1e-2, "\(name): the square kept the orbit")
            assertNear(Double(nowEye.pitch), Double(eye.pitch), 1e-2, "\(name): the square kept the pitch")
            assertNear(try card().state.selected.radius, radius, 1e-3, "\(name) on the plan")
            if light.anchor == .camera {
                XCTAssertEqual(now.radius, radius)
                XCTAssertEqual(now.orbit, light.orbit)
                XCTAssertEqual(now.pitch, light.pitch)
            }
        }

        // A pinch writes radius only too.
        controller.select(name: "key")
        let key = try coreRig().lights[0]
        XCTAssertFalse(try pinch(to: 0.4).isEmpty)
        let pinched = try coreRig().lights[0]
        XCTAssertEqual(pinched.radius, 1.5, "3.5 × 0.4 snaps to 1.5")
        XCTAssertEqual(pinched.beam, key.beam)
        XCTAssertEqual(pinched.orbit, key.orbit)
        XCTAssertEqual(pinched.pitch, key.pitch)
    }

    // MARK: Float noise

    func testPinnedFloatNoiseWritesNothing() throws {
        try enterWithThreeLights(selecting: "rim")
        XCTAssertFalse(try dragLamp("rim", to: 105).isEmpty)
        engine.lightsFrameRendered()
        let repinned = try XCTUnwrap(controller.value(.orbit))
        assertSameOrbit(repinned, 105, 1e-3, "after the drag")
        // A pinned light's placement is the eye-space Float, so it carries
        // noise. The re-pin may land on 105 exactly, so the camera turns by
        // 0.0006° (under LightSnap.tolerance, 1e-3) to make sure it is off
        // the grid by less than the tolerance, as noise is.
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.turn('y', 0.0006)\n")
        engine.lightsFrameRendered()
        let shown = try XCTUnwrap(controller.value(.orbit))
        print("LightsOrbitLiveTests: rim's pinned orbit reads \(repinned) after the drag to 105, "
              + "\(shown) after the 0.0006° turn")
        XCTAssertGreaterThan(abs(LightAngles.wrap(shown - 105)), 1e-5, "the noise is there")
        assertSameOrbit(shown, 105, 1e-3, "shown")
        assertSameOrbit(Double(try coreEye(2).orbit), shown, 1e-6, "core")
        let json = engine.lightRigJSON()

        // A new drag that stays inside the 105 bucket (±7.5°): nothing reaches
        // the core, so no needless re-pin.
        let offsets: [Double] = [4, -2, 6, -6, 7, 0, -7, 3]
        func wiggle(on c: LightsController) throws -> [LightSetResult] {
            let card = try card(c)
            let lamp = try XCTUnwrap(card.state.lamp(named: "rim"))
            let press = card.plan.lampPoint(orbit: lamp.orbit, radius: lamp.radius)
            var session = try XCTUnwrap(LightsOrbitInteraction(controller: c)
                .beginPlan(at: press, state: card.state, layout: card.plan))
            let distance = card.plan.drawnDistance(radius: lamp.radius)
            var k = 0
            return drag(&session, on: c, steps: offsets.count) { _ in
                defer { k += 1 }
                return card.plan.point(orbit: lamp.orbit + offsets[k], distance: distance)
            }
        }
        XCTAssertEqual(try wiggle(on: controller), [], "a drag inside the 105 bucket wrote")
        XCTAssertEqual(engine.lightRigJSON(), json, "no light_set may reach the core")

        // The same on a controller that counts the bridge setter calls.
        let (spy, counts) = spyController()
        defer { spy.end() }
        spy.select(name: "rim")
        XCTAssertEqual(try wiggle(on: spy), [])
        XCTAssertTrue(counts.numberWrites.isEmpty, "setter calls: \(counts.numberWrites)")
        XCTAssertEqual(counts.vectorWrites, 0)
        XCTAssertTrue(counts.performed.isEmpty)
        XCTAssertEqual(engine.lightRigJSON(), json)

        // A VoiceOver step from the pinned 105 ± noise goes to the next grid
        // value (120), not back to 105.
        XCTAssertEqual(interaction.stepOrbit(up: true, owner: "rim"), .ok)
        assertSameOrbit(Double(try coreEye(2).orbit), 120, 1e-3, "step up from a noisy 105")
        XCTAssertEqual(try coreRig().lights[2].anchor, .pinned)
    }

    // MARK: no Python per tick

    func testPlanEditsRunNoPython() throws {
        try enterWithThreeLights()
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }
        defer {
            engine.pythonTap = nil
            engine.commandTap = nil
        }

        // Lamp, arc, square and pinch strokes, back and forth, on key (a
        // camera light) and on rim (pinned). No run-loop pumping, so the poll
        // timers cannot fire: every line a tap sees would be the gestures'.
        var results: [LightSetResult] = []
        results += try dragLamp("key", to: 130, steps: 24)
        results += try dragLamp("key", to: -75, steps: 24)
        results += try dragArc(to: 60)
        results += try dragArc(to: -45)
        results += try dragSquare(to: 3.5)
        results += try dragSquare(to: 1)
        results += try pinch(to: 2)
        results += try pinch(to: 0.5)
        results += try dragLamp("rim", to: 0, steps: 24)   // a press selects rim
        results += try dragArc(to: 10)
        results += try dragSquare(to: 1.5)
        engine.pythonTap = nil
        engine.commandTap = nil

        XCTAssertGreaterThanOrEqual(ticks, 60, "at least 60 gesture ticks")
        XCTAssertGreaterThan(results.count, 30, "\(results.count) writes in \(ticks) ticks")
        XCTAssertTrue(results.allSatisfy { $0 == .ok }, "every grid change reached the rig")
        XCTAssertEqual(python.lines, [], "a plan gesture must run no Python (#610)")
        XCTAssertEqual(commands.lines, [], "a plan gesture must run no console command")
        XCTAssertEqual(controller.selection.name, "rim")
        XCTAssertEqual(try coreRig().lights.map(\.name), ["key", "fill", "rim"])
    }

    // MARK: selection and visibility

    func testPlanTapSelectsInTheBar() throws {
        try enterWithThreeLights()
        let json = engine.lightRigJSON()
        let card = try card()
        let fill = try XCTUnwrap(card.state.lamp(named: "fill"))
        let generation = controller.gestureGeneration
        let python = Lines(), commands = Lines()
        engine.pythonTap = { python.lines.append($0) }
        engine.commandTap = { commands.lines.append($0) }

        // Pressed and released without moving: a tap.
        let session = interaction.beginPlan(at: card.plan.lampPoint(orbit: fill.orbit, radius: fill.radius),
                                            state: card.state, layout: card.plan)
        engine.pythonTap = nil
        engine.commandTap = nil
        XCTAssertEqual(session?.target, .lamp(name: "fill", index: 1))
        XCTAssertEqual(controller.selection, LightSelection(name: "fill", index: 1))
        let bar = LightsBarState(controller)
        XCTAssertEqual(bar.chips.filter(\.isSelected).map(\.name), ["fill"], "the bar's chip follows the plan")
        XCTAssertEqual(LightsInspectorState(controller)?.name, "fill", "so does the inspector")
        let state = try XCTUnwrap(LightsOrbitState(controller))
        XCTAssertEqual(state.selected.name, "fill")
        XCTAssertEqual(state.lamps.map(\.slot), bar.chips.map(\.slot), "each lamp has its chip's colour")
        XCTAssertEqual(engine.lightRigJSON(), json, "a tap writes nothing")
        XCTAssertEqual(controller.gestureGeneration, generation + 1)
        XCTAssertEqual(python.lines, [])
        XCTAssertEqual(commands.lines, [])

        // And back: a chip tap shows on the plan.
        controller.select(name: "rim")
        XCTAssertEqual(LightsOrbitState(controller)?.selected.name, "rim")
        XCTAssertEqual(LightsOrbitState(controller)?.lamps.map(\.isSelected), [false, false, true])
    }

    func testOrbitViewHiddenOutsideTheMode() throws {
        try enterWithThreeLights()
        XCTAssertNotNil(LightsOrbitState(controller))

        // A drag under way when the mode ends (Done, Esc, another mode): the
        // next tick writes nothing and the session is over.
        func dragThenLeave(_ leave: () -> Void, _ message: String) throws {
            engine.setInteractionMode(.lights)
            let card = try card()
            let key = card.state.selected
            let distance = card.plan.drawnDistance(radius: key.radius)
            let press = card.plan.lampPoint(orbit: key.orbit, radius: key.radius)
            var session = try XCTUnwrap(interaction.beginPlan(at: press, state: card.state, layout: card.plan))
            XCTAssertEqual(interaction.move(&session, to: card.plan.point(orbit: key.orbit + 40, distance: distance)),
                           .ok, message)
            leave()
            XCTAssertNil(LightsOrbitState(controller), "the card draws nothing \(message)")
            let json = engine.lightRigJSON()
            XCTAssertNil(interaction.move(&session, to: card.plan.point(orbit: key.orbit + 80, distance: distance)),
                         message)
            XCTAssertTrue(session.isEnded, message)
            XCTAssertNil(interaction.beginPlan(at: press, state: card.state, layout: card.plan), message)
            XCTAssertNil(interaction.beginArc(at: card.arc.point(pitch: key.pitch), state: card.state,
                                              layout: card.arc), message)
            XCTAssertNil(interaction.beginPinch(), message)
            XCTAssertEqual(interaction.stepOrbit(up: true, owner: key.name), .badIndex, message)
            XCTAssertEqual(engine.lightRigJSON(), json, "nothing written \(message)")
        }
        try dragThenLeave({ engine.setInteractionMode(.viewing) }, "after Done")
        try dragThenLeave({ XCTAssertTrue(engine.exitActiveInteractionMode()) }, "after Esc")
        try dragThenLeave({ engine.setInteractionMode(.move) }, "after entering Move")

        // In the mode with no rig there is nothing to show.
        engine.setInteractionMode(.viewing)
        LightsLive.clearRig()
        engine.setInteractionMode(.lights)
        XCTAssertTrue(controller.isActive)
        XCTAssertNil(LightsOrbitState(controller), "no light, no orbit view")
    }
}
