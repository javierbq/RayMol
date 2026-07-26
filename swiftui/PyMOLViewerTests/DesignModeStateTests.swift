import XCTest
@testable import RayMol

@MainActor
final class DesignModeStateTests: XCTestCase {
    /// The gizmo geometry temp file readGizmo() consumes. Deleted between tests
    /// as belt-and-braces hygiene: in practice live Python rewrites it on every
    /// _emit(), but a stale file from a real RayMol run must never be able to
    /// leak an active gizmo into a fixture.
    static let gizmoJSONPath =
        (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_gizmo.json")

    override func setUp() {
        super.setUp()
        resetEngine()
    }

    override func tearDown() {
        resetEngine()
        super.tearDown()
    }

    /// PyMOLEngine.shared is a singleton shared by every test in the target, so
    /// each test must both start and end from a known state. Deleting the gizmo
    /// temp file gives readGizmo() a known-empty baseline — without it, a stale
    /// file left by a real RayMol run on the dev machine leaks into assertions
    /// and makes them machine-dependent.
    private func resetEngine() {
        let e = PyMOLEngine.shared
        e.pythonTap = nil          // first: the resets below emit Python
        e.setDesignMode(false)
        e.setMeasureMode(nil)
        e.setInteractionMode(.viewing)
        try? FileManager.default.removeItem(atPath: Self.gizmoJSONPath)
    }

    func testPythonTapObservesEmissions() {
        let e = PyMOLEngine.shared
        var captured: [String] = []
        e.pythonTap = { captured.append($0) }
        e.runPython("# probe")
        XCTAssertTrue(
            captured.contains("# probe"),
            "pythonTap must fire regardless of engine readiness "
            + "(isReady = \(e.isReady))")
    }

    func testDesignModeIsMutuallyExclusive() {
        let e = PyMOLEngine.shared
        // Enter Move mode, then Design — design must win.
        e.setInteractionMode(.move)
        e.setDesignMode(true)
        XCTAssertTrue(e.designMode)
        XCTAssertEqual(e.interactionMode, .viewing)   // move cleared
        // Entering Measure mode must clear Design.
        e.setMeasureMode(.distance)
        XCTAssertFalse(e.designMode)
    }

    func testDesignModeOffDoesNotClearOtherModes() {
        let e = PyMOLEngine.shared
        // Turning Design off (already off) should not disturb other modes.
        e.setInteractionMode(.viewing)
        e.setDesignMode(false)
        XCTAssertFalse(e.designMode)
        XCTAssertEqual(e.interactionMode, .viewing)
    }

    func testEnteringMoveModeClearsDesign() {
        let e = PyMOLEngine.shared
        e.setDesignMode(true)
        XCTAssertTrue(e.designMode)
        e.setInteractionMode(.move)
        XCTAssertFalse(e.designMode)
        XCTAssertEqual(e.interactionMode, .move)
    }

    func testEnteringDesignFromMoveTearsDownMoveState() {
        let e = PyMOLEngine.shared
        // SEEDING ORDER MATTERS — two constraints:
        //  1. Move mode first: the hoveredHandle didSet is guarded on
        //     interactionMode == .move, so seeding it earlier is a no-op.
        //  2. adjustFrameToggle/moveShiftHeld fire didSet -> syncAdjustFrame(),
        //     which calls readGizmo() and NILS gizmo + activeMoveObject (live
        //     Python writes active:false — no structure is loaded). So set the
        //     toggles BEFORE the plain fields, or the seed is wiped out.
        e.setInteractionMode(.move)
        e.adjustFrameToggle = true      // triggers readGizmo
        e.moveShiftHeld = true          // syncAdjustFrame early-returns here
        e.hoveredHandle = .rz           // didSet emits set_hover, no readGizmo
        e.armedAxis = .y
        e.activeMoveObject = "mol1"
        e.gizmo = GizmoGeometry(json: ["obj": "mol1", "center": [0.0, 0.0]])
        XCTAssertNotNil(e.gizmo, "precondition: seeded gizmo geometry")
        XCTAssertNotNil(e.activeMoveObject, "precondition: seeded active object")

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }   // install AFTER seeding

        e.setDesignMode(true)

        XCTAssertTrue(e.designMode)
        XCTAssertEqual(e.interactionMode, .viewing)
        XCTAssertNil(e.activeMoveObject)
        XCTAssertNil(e.gizmo)
        XCTAssertNil(e.armedAxis)
        XCTAssertNil(e.hoveredHandle)
        XCTAssertFalse(e.adjustFrameToggle)
        XCTAssertFalse(e.moveShiftHeld)
        XCTAssertTrue(
            captured.contains { $0.contains("_mm.cleanup()") },
            "metal_move.cleanup() must run, or the _move_gizmo CGO is stranded "
            + "in the scene where the user cannot delete it. Captured: \(captured)")
    }

    func testExitingMoveDoesNotPushAdjustFrameDuringTeardown() {
        let e = PyMOLEngine.shared
        e.setInteractionMode(.move)
        e.adjustFrameToggle = true      // arms lastAdjustSent = true

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }   // install AFTER arming

        e.setInteractionMode(.viewing)

        // Before the fix, clearing adjustFrameToggle fires didSet ->
        // syncAdjustFrame(), which emits set_adjust(0) AND calls readGizmo() —
        // re-reading the gizmo temp file before cleanup() has invalidated it,
        // which resurrects gizmo + activeMoveObject on any host where that file
        // still describes an active gizmo. Clearing lastAdjustSent first makes
        // syncAdjustFrame early-return, so no set_adjust is emitted at all.
        XCTAssertFalse(
            captured.contains { $0.contains("set_adjust") },
            "teardown must not push adjust-frame: syncAdjustFrame's readGizmo() "
            + "can resurrect the state cleanup() is about to drop. "
            + "Captured: \(captured)")
        // cleanup() must still be the thing that runs.
        XCTAssertTrue(
            captured.contains { $0.contains("_mm.cleanup()") },
            "Captured: \(captured)")
        XCTAssertFalse(e.adjustFrameToggle)
    }

    func testEnteringDesignFromMeasureRunsMeasureReset() {
        let e = PyMOLEngine.shared
        e.setMeasureMode(.distance)
        XCTAssertEqual(e.measureMode, .distance, "precondition: in measure mode")

        var captured: [String] = []
        e.pythonTap = { captured.append($0) }

        e.setDesignMode(true)

        XCTAssertTrue(e.designMode)
        XCTAssertNil(e.measureMode)
        // The measureMode flag alone passes both before and after the fix — the
        // bare assignment already nils it. Only the emission proves teardown ran.
        XCTAssertTrue(
            captured.contains { $0.contains("_am.reset()") },
            "appkit_measure.reset() must run. Captured: \(captured)")
    }
}
