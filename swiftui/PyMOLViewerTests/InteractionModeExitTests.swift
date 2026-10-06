import XCTest
@testable import RayMol

/// Coverage for the shared "Esc backs out of the active mode" routing (#235).
///
/// The Esc key itself is an `NSEvent` local monitor in `ContentView`, which a
/// unit test cannot press. What IS testable — and what actually carries the
/// behavior — is `PyMOLEngine.exitActiveInteractionMode()`: the single routine
/// both Esc and the overlays' ✕ buttons funnel through. These tests pin down
/// its contract: exits the active mode via that mode's own path, reports
/// whether it did anything (so Esc knows whether to fall through to clearing
/// the selection), and stays a no-op when no mode is active.
@MainActor
final class InteractionModeExitTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    // PyMOLEngine is a singleton shared with the other test classes, so start
    // and finish every case from a known-clean viewing state.
    override func setUp() {
        super.setUp()
        resetToViewing()
    }

    override func tearDown() {
        resetToViewing()
        super.tearDown()
    }

    private func resetToViewing() {
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setPredictMode(false)
        #if os(macOS)
        engine.setBinderDesignMode(false)
        #endif
        engine.setInteractionMode(.viewing)
    }

    // MARK: - Exits each mode

    func testExitsMoveMode() {
        engine.setInteractionMode(.move)
        XCTAssertEqual(engine.interactionMode, .move)

        XCTAssertTrue(engine.exitActiveInteractionMode(), "should report that it exited a mode")
        XCTAssertEqual(engine.interactionMode, .viewing)
    }

    func testExitsDesignMode() {
        engine.setDesignMode(true)
        XCTAssertTrue(engine.designMode)

        XCTAssertTrue(engine.exitActiveInteractionMode())
        XCTAssertFalse(engine.designMode)
    }

    func testExitsMeasureMode() {
        engine.setMeasureMode(.distance)
        XCTAssertEqual(engine.measureMode, .distance)

        XCTAssertTrue(engine.exitActiveInteractionMode())
        XCTAssertNil(engine.measureMode)
    }

    func testExitsEachMeasureKind() {
        for kind in [MeasureKind.distance, .angle, .dihedral] {
            engine.setMeasureMode(kind)
            XCTAssertEqual(engine.measureMode, kind)
            XCTAssertTrue(engine.exitActiveInteractionMode(), "\(kind) should be exitable")
            XCTAssertNil(engine.measureMode, "\(kind) should have been cleared")
        }
    }

    // MARK: - Binder Design joins the exclusion set (#342)

    #if os(macOS)
    func testExitsBinderDesignMode() {
        // The bar had no keyboard way out: `exitActiveInteractionMode` did not know the
        // mode existed, so Esc fell through to clearing the selection and left the bar up.
        engine.setBinderDesignMode(true)
        XCTAssertTrue(engine.binderDesignMode)

        XCTAssertTrue(engine.exitActiveInteractionMode())
        XCTAssertFalse(engine.binderDesignMode)
    }

    func testEveryOtherExclusiveModeClearsBinderDesign() {
        // Exclusivity was implemented in ONE direction only: entering Binder Design
        // cleared the other four, and `setPredictMode` cleared it back, but Design,
        // Measure, Move and Box Select did not. Two docked bars then fight for the one
        // strip above the viewport.
        //
        // Table-driven so a mode added later has an obvious place to be listed, and each
        // case re-enters Binder Design first so they are independent.
        let entries: [(String, () -> Void)] = [
            ("Design", { self.engine.setDesignMode(true) }),
            ("Measure", { self.engine.setMeasureMode(.distance) }),
            ("Move", { self.engine.setInteractionMode(.move) }),
            ("Box Select", { self.engine.setInteractionMode(.boxSelect) }),
            ("Predict", { self.engine.setPredictMode(true) }),
            ("Lights", { self.engine.setInteractionMode(.lights) }),
        ]
        for (name, enter) in entries {
            engine.setBinderDesignMode(true)
            XCTAssertTrue(engine.binderDesignMode, "precondition for \(name)")
            enter()
            XCTAssertFalse(engine.binderDesignMode,
                           "entering \(name) must clear Binder Design — two docked bars "
                           + "cannot share the strip above the viewport")
            resetToViewing()
        }
    }

    func testEnteringBinderDesignStillClearsTheOthers() {
        // The direction that already worked, pinned so the refactor into
        // `clearBinderDesignMode` cannot quietly drop it.
        engine.setMeasureMode(.distance)
        engine.setBinderDesignMode(true)
        XCTAssertNil(engine.measureMode)
        XCTAssertFalse(engine.designMode)
        XCTAssertFalse(engine.predictMode)
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertTrue(engine.binderDesignMode)
    }
    #endif

    // MARK: - Lights joins the exclusion set (#619)

    func testExitsLightsMode() {
        engine.setInteractionMode(.lights)
        XCTAssertEqual(engine.interactionMode, .lights)
        XCTAssertTrue(engine.lightsController.isActive)

        XCTAssertTrue(engine.exitActiveInteractionMode(), "Esc must leave Lights mode like every other mode")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(engine.lightsController.isActive)
    }

    func testSecondExitAfterLightsIsANoOp() {
        engine.setInteractionMode(.lights)
        XCTAssertTrue(engine.exitActiveInteractionMode())
        XCTAssertFalse(engine.exitActiveInteractionMode(),
                       "a second Esc must fall through to the selection stages")
        XCTAssertFalse(engine.lightsController.isActive)
    }

    /// #622: the gizmo shows whenever Lights mode is on, so the eye demand
    /// follows the mode. Entering sets `.everyFrame` BEFORE `begin()` (its
    /// refresh already publishes the eye space and the projection, with no
    /// frame rendered); leaving, by Done/Esc or another mode, sets
    /// `.pinnedOnly` (both cleared) and releases the aim dot's pick grids.
    func testLightsDemandFollowsTheMode() throws {
        try LightsLive.requireEngine()
        defer { LightsLive.tearDown() }
        LightsLive.addPeptide()
        engine.runPython("from pymol import cmd as _lmt_cmd\n_lmt_cmd.show_as('sticks', 'lmt_pep')\n")
        LightsLive.setRig(LightsLive.threeLights(enabled: true))
        let controller = engine.lightsController
        XCTAssertEqual(controller.eyeDemand, .pinnedOnly)

        for leave in ["Esc", "Move"] {
            engine.setInteractionMode(.lights)
            XCTAssertEqual(controller.eyeDemand, .everyFrame, leave)
            XCTAssertEqual(controller.eye.eyeSpace?.lights.count, 3, "published by begin(): \(leave)")
            let projection = try XCTUnwrap(controller.eye.projection, "published by begin(): \(leave)")
            XCTAssertEqual(projection, engine.lightCameraProjection(), leave)
            XCTAssertFalse(projection.orthoscopic, leave)
            // Entering again changes nothing.
            engine.setInteractionMode(.lights)
            XCTAssertEqual(controller.eyeDemand, .everyFrame, leave)

            // The aim dot's grids, as a press would build them.
            XCTAssertGreaterThanOrEqual(engine.prepareSurfacePick(), 1, leave)
            if leave == "Esc" {
                XCTAssertTrue(engine.exitActiveInteractionMode())
            } else {
                engine.setInteractionMode(.move)
            }
            XCTAssertEqual(controller.eyeDemand, .pinnedOnly, leave)
            XCTAssertNil(controller.eye.eyeSpace, leave)
            XCTAssertNil(controller.eye.projection, leave)
            XCTAssertEqual(engine.releaseSurfacePick(), 0, "leaving Lights must release the grids: \(leave)")
            engine.setInteractionMode(.viewing)
        }
    }

    /// #622: leaving Lights mode, by Esc or another mode, clears the light
    /// gizmo: no hover or drag state, the pointer's session ended (it writes
    /// no more; the press stays swallowed until its release, so the rest of
    /// a drag never reaches the camera), and the pick grids released.
    func testLeavingLightsClearsTheGizmo() throws {
        try LightsLive.requireEngine()
        defer {
            engine.lightGizmoPointer.cancel()
            LightsLive.tearDown()
        }
        LightsLive.addPeptide()
        // The camera at z = +100 looking at the origin (the rig's centre);
        // LightsLive.tearDown puts the user's view back.
        engine.runPython(
            "from pymol import cmd as _lmt_cmd\n"
            + "_lmt_cmd.show_as('spheres', 'lmt_pep')\n"
            + "_lmt_cmd.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, "
            + "0.0, 0.0, -100.0, 0.0, 0.0, 0.0, 50.0, 150.0, -20.0))\n")
        LightsLive.setRig(LightsLive.threeLights(enabled: true))
        let controller = engine.lightsController
        let size = CGSize(width: 800, height: 600)

        for leave in ["Esc", "Move"] {
            engine.setInteractionMode(.lights)
            controller.select(name: "key")
            engine.lightsFrameRendered()
            let layout = try XCTUnwrap(engine.lightGizmoLayout(viewSize: size), leave)
            let key = try XCTUnwrap(layout.knob(named: "key"), leave)
            let interaction = LightGizmoInteraction(controller: controller, picker: engine.lightGizmoPicker)
            XCTAssertEqual(engine.lightGizmoPointer.press(at: key.centre, option: false, layout: layout,
                                                          interaction: interaction), .gizmo, leave)
            engine.lightGizmoUI.hovered = .knob("key")
            engine.lightGizmoUI.track(engine.lightGizmoPointer.session, layout: layout)
            XCTAssertEqual(engine.lightGizmoUI.active, .knob("key"), leave)
            XCTAssertGreaterThanOrEqual(engine.prepareSurfacePick(), 1, leave)
            let json = engine.lightRigJSON()

            if leave == "Esc" {
                XCTAssertTrue(engine.exitActiveInteractionMode())
            } else {
                engine.setInteractionMode(.move)
            }
            XCTAssertNil(engine.lightGizmoUI.hovered, leave)
            XCTAssertNil(engine.lightGizmoUI.active, leave)
            XCTAssertNil(engine.lightGizmoUI.readout, leave)
            XCTAssertEqual(engine.lightGizmoPointer.session?.isEnded, true, "the session is ended: \(leave)")
            XCTAssertTrue(engine.lightGizmoPointer.ownsPress, "the press is still swallowed: \(leave)")
            let away = CGPoint(x: key.centre.x + 40, y: key.centre.y + 30)
            XCTAssertEqual(engine.lightGizmoPointer.drag(to: away, interaction: interaction), .gizmo, leave)
            XCTAssertEqual(engine.lightRigJSON(), json, "no write after leaving: \(leave)")
            XCTAssertEqual(engine.lightGizmoPointer.release(at: away, interaction: interaction), .gizmo, leave)
            XCTAssertFalse(engine.lightGizmoPointer.ownsPress, leave)
            XCTAssertEqual(engine.releaseSurfacePick(), 0, "leaving Lights must release the grids: \(leave)")
            XCTAssertNil(engine.lightGizmoLayout(viewSize: size), "no gizmo outside the mode: \(leave)")
            engine.setInteractionMode(.viewing)
        }
    }

    /// Every other exclusive mode, with how to enter it and whether it is on.
    private var otherModes:[(name: String, enter: () -> Void, isOn: () -> Bool)] {
        var modes: [(name: String, enter: () -> Void, isOn: () -> Bool)] = [
            ("Move", { self.engine.setInteractionMode(.move) }, { self.engine.interactionMode == .move }),
            ("Box Select", { self.engine.setInteractionMode(.boxSelect) },
             { self.engine.interactionMode == .boxSelect }),
            ("Measure", { self.engine.setMeasureMode(.distance) }, { self.engine.measureMode != nil }),
            ("Predict", { self.engine.setPredictMode(true) }, { self.engine.predictMode }),
        ]
        #if RAYMOL_MPNN
        modes.append(("Design", { self.engine.setDesignMode(true) }, { self.engine.designMode }))
        #endif
        #if os(macOS)
        modes.append(("Binder Design", { self.engine.setBinderDesignMode(true) },
                      { self.engine.binderDesignMode }))
        #endif
        return modes
    }

    func testEnteringLightsLeavesEveryOtherMode() {
        for mode in otherModes {
            mode.enter()
            XCTAssertTrue(mode.isOn(), "precondition for \(mode.name)")
            XCTAssertEqual(engine.lightsController.isActive, engine.interactionMode == .lights, mode.name)

            engine.setInteractionMode(.lights)
            XCTAssertFalse(mode.isOn(), "entering Lights must leave \(mode.name)")
            XCTAssertEqual(engine.interactionMode, .lights, mode.name)
            XCTAssertEqual(engine.lightsController.isActive, engine.interactionMode == .lights, mode.name)
            resetToViewing()
            XCTAssertFalse(engine.lightsController.isActive, "after leaving from \(mode.name)")
        }
    }

    func testEveryOtherModeLeavesLights() {
        for mode in otherModes {
            engine.setInteractionMode(.lights)
            XCTAssertTrue(engine.lightsController.isActive, "precondition for \(mode.name)")

            mode.enter()
            XCTAssertTrue(mode.isOn(), "\(mode.name) did not enter")
            XCTAssertNotEqual(engine.interactionMode, .lights,
                              "entering \(mode.name) must leave Lights: two bars cannot share the strip")
            XCTAssertFalse(engine.lightsController.isActive, mode.name)
            XCTAssertEqual(engine.lightsController.isActive, engine.interactionMode == .lights, mode.name)
            resetToViewing()
        }
    }

    // MARK: - No-op when nothing is active

    func testNoOpWhenNoModeIsActive() {
        XCTAssertFalse(engine.exitActiveInteractionMode(),
                       "with no mode active it must report false so Esc falls through to clearing the selection")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(engine.designMode)
        XCTAssertNil(engine.measureMode)
    }

    func testSecondExitIsANoOp() {
        engine.setInteractionMode(.move)
        XCTAssertTrue(engine.exitActiveInteractionMode())
        // A second Esc has no mode left to leave and must hand off to the
        // selection stages rather than silently consuming the key.
        XCTAssertFalse(engine.exitActiveInteractionMode())
    }

    // MARK: - Goes through the mode's real exit path

    func testExitingMoveTearsDownGizmoState() {
        engine.setInteractionMode(.move)
        engine.activeMoveObject = "1ubq"
        engine.armedAxis = .x
        engine.adjustFrameToggle = true

        XCTAssertTrue(engine.exitActiveInteractionMode())

        // Proves Esc routed through setInteractionMode(.viewing) rather than
        // just flipping the mode flag: the whole gizmo satellite state is gone.
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertNil(engine.activeMoveObject)
        XCTAssertNil(engine.armedAxis)
        XCTAssertNil(engine.gizmo)
        XCTAssertFalse(engine.adjustFrameToggle)
        XCTAssertFalse(engine.moveShiftHeld)
    }

    // MARK: - Defensive

    func testUnwindsEveryModeIfStateIsDesynchronized() {
        // The three modes are mutually exclusive, so this state should be
        // unreachable — force it directly (bypassing the setters' exclusion) to
        // pin the contract that a single exit still leaves nothing stranded.
        engine.interactionMode = .move
        engine.designMode = true
        engine.measureMode = .angle

        XCTAssertTrue(engine.exitActiveInteractionMode())

        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertFalse(engine.designMode)
        XCTAssertNil(engine.measureMode)
    }
}

/// Coverage for the Box Select tool's engine-side contract (#358): entering and
/// leaving the mode, and what dragging the box actually emits.
///
/// The gestures can't be driven from a test, so this pins down the layer they
/// funnel through — `toggleBoxSelect`, `setBoxRect`, `endBoxSelection` — using
/// the DEBUG `pythonTap` seam to read the Python the engine intended to run.
///
/// Two behaviours carry the tool's whole feel and are the point of these tests:
/// entering ARMS a rectangle (so it selects something at once rather than
/// showing an empty viewport), and every rectangle change commits by itself (so
/// there is no Accept control to find).
@MainActor
final class BoxSelectModeTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    private final class CaptureBox { var lines: [String] = [] }
    private var capture = CaptureBox()

    private let rect = BoxRect(minX: -0.4, minY: -0.3, maxX: 0.5, maxY: 0.6)

    override func setUp() {
        super.setUp()
        reset()
    }

    override func tearDown() {
        reset()
        super.tearDown()
    }

    private func reset() {
        engine.pythonTap = nil
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)
        engine.setInteractionMode(.viewing)
    }

    /// Start capturing Python from here on, so the seeding above stays out of it.
    private func startCapture() {
        capture = CaptureBox()
        let box = capture
        engine.pythonTap = { box.lines.append($0) }
    }

    private var emitted: String { capture.lines.joined(separator: "\n") }

    /// Spin the run loop until `needle` shows up, or the timeout expires.
    ///
    /// Commits are throttled (leading edge, then a trailing catch-up on the main
    /// queue), so a rectangle change that lands inside the window — which is
    /// every one of these tests, since entering the mode already fired — is
    /// DEFERRED rather than emitted inline. Asserting synchronously would be
    /// asserting on the throttle, not on the behaviour.
    private func waitForEmit(containing needle: String,
                             timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if emitted.contains(needle) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return emitted.contains(needle)
    }

    // MARK: - Mode plumbing

    func testToggleEntersAndLeaves() {
        engine.toggleBoxSelect()
        XCTAssertEqual(engine.interactionMode, .boxSelect)
        engine.toggleBoxSelect()
        XCTAssertEqual(engine.interactionMode, .viewing,
                       "the Selections-panel control is a toggle, so it must also close the mode")
    }

    func testEnteringBoxSelectLeavesTheOtherTools() {
        engine.setInteractionMode(.move)
        engine.setInteractionMode(.boxSelect)
        XCTAssertEqual(engine.interactionMode, .boxSelect)

        engine.setMeasureMode(.distance)
        engine.setInteractionMode(.boxSelect)
        XCTAssertNil(engine.measureMode,
                     "Box Select is exclusive with Measure, like Move is")
    }

    func testEscExitsBoxSelect() {
        engine.setInteractionMode(.boxSelect)
        XCTAssertTrue(engine.exitActiveInteractionMode(),
                      "Esc must back out of Box Select like every other tool")
        XCTAssertEqual(engine.interactionMode, .viewing)
    }

    // MARK: - Entering arms a box

    func testEnteringArmsAndCommitsARectangle() {
        startCapture()
        engine.setInteractionMode(.boxSelect)
        XCTAssertEqual(engine.boxRect, .initial,
                       "the tool must open with a box down, not an empty viewport")
        XCTAssertTrue(emitted.contains("box_begin('sele')"),
                      "the snapshot has to exist before the first commit")
        XCTAssertTrue(emitted.contains("box_commit_ndc"),
                      "the armed box must select something immediately")
        // box_begin must precede the commit, or the first commit composes against
        // a stale (or missing) snapshot.
        XCTAssertLessThan(emitted.range(of: "box_begin")!.lowerBound,
                          emitted.range(of: "box_commit_ndc")!.lowerBound)
    }

    func testLeavingTheModeForgetsTheBoxAndClosesTheSession() {
        engine.setInteractionMode(.boxSelect)
        startCapture()
        engine.endBoxSelection()
        XCTAssertNil(engine.boxRect,
                     "a rectangle left behind would have no mode to explain it")
        XCTAssertEqual(engine.interactionMode, .viewing)
        XCTAssertTrue(emitted.contains("box_finish()"),
                      "the pre-box snapshot must not outlive the tool")
    }

    // MARK: - Commit on drag

    func testDraggingTheBoxCommitsWithNoAcceptStep() {
        engine.setInteractionMode(.boxSelect)
        startCapture()
        engine.setBoxRect(rect)
        XCTAssertTrue(waitForEmit(containing: "box_commit_ndc(-0.4, -0.3, 0.5, 0.6"),
                      "expected the dragged rectangle, got: \(emitted)")
        XCTAssertTrue(emitted.contains("name='sele'"))
    }

    func testTheToolOnlyEverAdds() {
        engine.setInteractionMode(.boxSelect)
        startCapture()
        engine.setBoxRect(rect)
        XCTAssertTrue(waitForEmit(containing: "mode='add'"))
        XCTAssertFalse(emitted.contains("mode='replace'"),
                       "the interactive tool must never overwrite the selection")
        XCTAssertFalse(emitted.contains("mode='subtract'"))
    }

    func testDegenerateRectIsNotWorthCommitting() {
        engine.setInteractionMode(.boxSelect)
        startCapture()
        engine.setBoxRect(BoxRect(minX: 0, minY: 0, maxX: 0.001, maxY: 0.001))
        XCTAssertFalse(waitForEmit(containing: "box_commit_ndc", timeout: 0.3),
                       "a stray click must not re-commit an empty rectangle")
    }
}
