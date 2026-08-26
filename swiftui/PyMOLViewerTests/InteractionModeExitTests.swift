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
/// leaving the mode, and what Accept / Cancel actually emit.
///
/// The gestures and the Return key can't be driven from a test, so this pins
/// down the layer both of them funnel through — `setBoxRect`,
/// `acceptBoxSelection`, `cancelBoxSelection` — using the DEBUG `pythonTap`
/// seam to read the Python the engine intended to run.
@MainActor
final class BoxSelectModeTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

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

    /// Enter the mode with `rect` already drawn, with the tap installed AFTER the
    /// seeding so only the action under test is captured.
    private func armed(_ rect: BoxRect, capturing: inout [String]) {
        engine.setInteractionMode(.boxSelect)
        engine.setBoxRect(rect)
        let box = CaptureBox()
        engine.pythonTap = { box.lines.append($0) }
        self.capture = box
        capturing = []
    }

    private final class CaptureBox { var lines: [String] = [] }
    private var capture: CaptureBox?

    private let rect = BoxRect(minX: -0.4, minY: -0.3, maxX: 0.5, maxY: 0.6)

    // MARK: - Mode plumbing

    func testEnteringBoxSelectLeavesTheOtherTools() {
        engine.setInteractionMode(.move)
        engine.setInteractionMode(.boxSelect)
        XCTAssertEqual(engine.interactionMode, .boxSelect)

        engine.setMeasureMode(.distance)
        engine.setInteractionMode(.boxSelect)
        XCTAssertNil(engine.measureMode,
                     "Box Select is exclusive with Measure, like Move is")
    }

    func testLeavingTheModeForgetsTheBox() {
        engine.setInteractionMode(.boxSelect)
        engine.setBoxRect(rect)
        XCTAssertEqual(engine.boxRect, rect)
        engine.setInteractionMode(.viewing)
        XCTAssertNil(engine.boxRect,
                     "a rectangle left behind would have no mode to explain it")
    }

    func testEscExitsBoxSelect() {
        engine.setInteractionMode(.boxSelect)
        XCTAssertTrue(engine.exitActiveInteractionMode(),
                      "Esc must back out of Box Select like every other tool")
        XCTAssertEqual(engine.interactionMode, .viewing)
    }

    func testDegenerateRectIsNotWorthPreviewing() {
        engine.setInteractionMode(.boxSelect)
        var _ignored: [String] = []
        armed(rect, capturing: &_ignored)
        engine.setBoxRect(BoxRect(minX: 0, minY: 0, maxX: 0.001, maxY: 0.001))
        XCTAssertFalse(capture?.lines.contains { $0.contains("box_preview_ndc") } ?? true,
                       "a stray click must not fire a preview over every atom")
    }

    // MARK: - Accept / Cancel

    func testAcceptCommitsTheBoxAndExits() {
        var lines: [String] = []
        armed(rect, capturing: &lines)
        engine.acceptBoxSelection()

        let emitted = capture?.lines.joined(separator: "\n") ?? ""
        XCTAssertTrue(emitted.contains("box_select_ndc(-0.4, -0.3, 0.5, 0.6"),
                      "expected the drawn rectangle, got: \(emitted)")
        XCTAssertTrue(emitted.contains("name='sele'"))
        XCTAssertTrue(emitted.contains("mode='replace'"))
        XCTAssertEqual(engine.interactionMode, .viewing, "accept leaves the mode")
    }

    func testAcceptHonorsAnOverriddenMode() {
        var lines: [String] = []
        armed(rect, capturing: &lines)
        engine.acceptBoxSelection(mode: .subtract)
        XCTAssertTrue((capture?.lines.joined() ?? "").contains("mode='subtract'"))
    }

    func testAcceptUsesTheOverlaySettingWhenNotOverridden() {
        engine.setInteractionMode(.boxSelect)
        engine.setBoxRect(rect)
        engine.boxSelectMode = .add
        let box = CaptureBox()
        engine.pythonTap = { box.lines.append($0) }
        engine.acceptBoxSelection()
        XCTAssertTrue(box.lines.joined().contains("mode='add'"))
    }

    func testAcceptWithNoBoxCommitsNothing() {
        engine.setInteractionMode(.boxSelect)
        let box = CaptureBox()
        engine.pythonTap = { box.lines.append($0) }
        engine.acceptBoxSelection()
        XCTAssertFalse(box.lines.joined().contains("box_select_ndc"),
                       "entering and immediately accepting must not touch 'sele'")
        XCTAssertEqual(engine.interactionMode, .viewing)
    }

    func testCancelNeverCommits() {
        var lines: [String] = []
        armed(rect, capturing: &lines)
        engine.cancelBoxSelection()
        XCTAssertFalse((capture?.lines.joined() ?? "").contains("box_select_ndc"))
        XCTAssertEqual(engine.interactionMode, .viewing)
    }

    func testLeavingClearsThePreviewHighlight() {
        var lines: [String] = []
        armed(rect, capturing: &lines)
        engine.cancelBoxSelection()
        XCTAssertTrue((capture?.lines.joined() ?? "").contains("box_preview_clear"),
                      "the cyan preview atoms must not outlive the box")
    }
}
