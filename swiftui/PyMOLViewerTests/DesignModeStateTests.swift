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
}
