#if os(macOS)
import XCTest
@testable import RayMol

/// Unit coverage for morph engine plumbing: `ProgressItem.morph`, the `tray(morphs:)` lane,
/// `PyMOLEngine.completedMorphs`, the per-object playback timer rules and the State row's
/// slider. All but `testMorphStopsPlaybackOfItsTarget` are pure (no engine calls); that one
/// uses the live engine the unit-test host runs, and cleans up after itself.
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

    // MARK: - Per-object playback timers

    /// Every playing object missing from the published list stops, whatever
    /// deleted it; playing objects still loaded, and loaded objects not playing,
    /// are left alone.
    func testTimersToStop() {
        XCTAssertEqual(
            PyMOLEngine.timersToStop(playing: ["2kpo_morph", "1nmr"],
                                     objects: ["1nmr", "2kpo", "other"]),
            ["2kpo_morph"])
        XCTAssertEqual(PyMOLEngine.timersToStop(playing: [], objects: ["a"]), [])
        XCTAssertEqual(PyMOLEngine.timersToStop(playing: ["a"], objects: []), ["a"])
    }

    /// Re-morphing a playing morph stops its timer before the rebuild is sent.
    /// The test host runs a live engine, so the job really starts; it is
    /// cancelled and everything it made removed before the test ends.
    func testMorphStopsPlaybackOfItsTarget() {
        let engine = PyMOLEngine.shared
        engine.runPython("from pymol import cmd as _c\n"
                         + "_c.fab('AGA', 't8b_src')\n_c.create('t8b_src', 't8b_src', 1, 2)")
        defer {
            engine.runPython("from pymol import cmd as _c, morph_jobs as _mj\n"
                             + "_mj.morph_cancel('t8b_src_morph')\n"
                             + "_mj.morph_dismiss('t8b_src_morph')\n"
                             + "_mj._JOBS.pop('t8b_src_morph', None)\n"
                             + "_c.delete('t8b_src*')")
            engine.stopObjectStates("t8b_src_morph")
        }
        engine.playingObjects.insert("t8b_src_morph")   // as if auto-played earlier
        var s = MorphSettings()
        s.framesPerModel = 2
        s.refinement = 0
        engine.morph(source: "t8b_src", settings: s, autoPlay: false, name: "t8b_src_morph")
        XCTAssertFalse(engine.playingObjects.contains("t8b_src_morph"))
    }

    // MARK: - State slider

    /// A tick mark per state is O(states) AppKit work on every layout pass (on
    /// macOS 15 SwiftUI's stepped Slider is an NSSlider; ~1.8 s when a 1200-frame
    /// morph's card expanded). Ensembles keep their ticks; long objects get none.
    /// Only the running app shows the cost (newer macOS draws the slider in
    /// SwiftUI, with no NSSlider a test could inspect).
    func testStateSliderStepsOnlySmallObjects() {
        XCTAssertEqual(StateSlider.step(forStates: 20), 1)
        XCTAssertEqual(StateSlider.step(forStates: StateSlider.maxTickMarks), 1)
        XCTAssertNil(StateSlider.step(forStates: StateSlider.maxTickMarks + 1))
        XCTAssertNil(StateSlider.step(forStates: 1200))
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
