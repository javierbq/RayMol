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
