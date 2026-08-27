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
