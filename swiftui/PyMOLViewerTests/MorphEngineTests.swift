#if os(macOS)
import XCTest
@testable import RayMol

/// Unit coverage for morph engine plumbing: `ProgressItem.morph`, the `tray(morphs:)` lane,
/// and `PyMOLEngine.completedMorphs`. All tests are pure (no engine calls) so they run in
/// the macOS unit-test host without launching PyMOL.
final class MorphEngineTests: XCTestCase {

    // MARK: - ProgressItem.morph

    func testMorphItemRunning() {
        let j = PredictionJobState.fixture(id: "2kpo_morph", state: "running",
                                           phase: "landing", fraction: 0.35,
                                           modelsDone: 7, modelsTotal: 20)
        let item = ProgressItem.morph(j)
        XCTAssertEqual(item.title, "Morphing 2kpo_morph")
        XCTAssertEqual(item.detail, "leg 7 of 20 · 35%")
        XCTAssertEqual(item.buttonTitle, "Cancel")
        XCTAssertEqual(item.action,
                       .python("from pymol import cmd as _c\n_c.morph_cancel('2kpo_morph')"))
    }

    func testMorphItemCancelled() {
        let j = PredictionJobState.fixture(id: "x_morph", state: "cancelled")
        let item = ProgressItem.morph(j)
        XCTAssertTrue(item.isCancelled)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
    }

    func testMorphItemFailed() {
        let j = PredictionJobState.fixture(id: "y_morph", state: "error",
                                           error: "Sculpt failed")
        let item = ProgressItem.morph(j)
        XCTAssertEqual(item.title, "Morph failed: y_morph")
        XCTAssertEqual(item.detail, "Sculpt failed")
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        XCTAssertTrue(item.isError)
        XCTAssertFalse(item.isCancelled)
    }

    // MARK: - tray(morphs:)

    func testTrayIncludesMorphs() {
        let items = ProgressItem.tray(
            weights: nil,
            predictions: [],
            designs: [],
            morphs: [PredictionJobState.fixture(id: "m", state: "running")])
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - PyMOLEngine.completedMorphs

    func testCompletionDetection() {
        XCTAssertEqual(
            PyMOLEngine.completedMorphs(
                previouslyRunning: ["a_morph", "b_morph"],
                nowRunning: ["b_morph"],
                known: ["a_morph": "a"]),
            ["a_morph"])
    }

    /// A job that disappears from running but is NOT in the morph dict is an
    /// error/cancellation, not a completion.
    func testCompletionDetectionErrorCase() {
        XCTAssertEqual(
            PyMOLEngine.completedMorphs(
                previouslyRunning: ["a_morph"],
                nowRunning: [],
                known: [:]),
            [])
    }
}

// MARK: - Test-only PredictionJobState fixture
// Controller decision 5: test-target only; never add to the app target.

extension PredictionJobState {
    static func fixture(
        id: String = "test_morph",
        state: String = "running",
        phase: String = "interpolating",
        fraction: Double? = 0.5,
        moving: Bool = true,
        detail: String = "",
        modelsDone: Int = 5,
        modelsTotal: Int = 10,
        elapsed: Double = 30,
        error: String? = nil,
        bundle: String? = nil
    ) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: phase, fraction: fraction,
                           moving: moving, detail: detail, modelsDone: modelsDone,
                           modelsTotal: modelsTotal, elapsed: elapsed,
                           error: error, bundle: bundle)
    }
}
#endif
