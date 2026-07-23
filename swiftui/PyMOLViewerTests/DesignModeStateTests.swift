import XCTest
@testable import RayMol

@MainActor
final class DesignModeStateTests: XCTestCase {
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
