#if os(macOS)
import XCTest
@testable import RayMol

/// Unit coverage for `MorphSettings`, `MorphClipMapping`, and `MorphCompletion`.
///
/// All tests are pure (no engine calls) so they run in the macOS unit-test host
/// without launching PyMOL.
final class MorphSettingsTests: XCTestCase {

    // MARK: - Summary

    func testSummaryAtMovieFPS() {
        let s = MorphSettings()
        let sum = s.summary(models: 20, atoms: 1656, fps: 30)
        XCTAssertEqual(sum.legs, 20)
        XCTAssertEqual(sum.frames, 300)
        XCTAssertEqual(sum.seconds, 10, accuracy: 1e-9)
        XCTAssertEqual(sum.bytes, Int(Double(1656 * 300 * 48) * 1.1))
    }

    func testSummaryNoLoop() {
        var s = MorphSettings()
        s.loop = false
        XCTAssertEqual(s.summary(models: 20, atoms: 10, fps: 30).legs, 19)
    }

    // MARK: - MorphClipMapping

    func testNaturalSecondsGuardsZeroFPS() {
        XCTAssertEqual(MorphClipMapping.naturalSeconds(models: 20, stride: 15, loop: true, fps: 0), 300)
    }

    func testAbsoluteRangeFullSendsZero() {
        XCTAssertTrue(MorphClipMapping.absoluteRange(firstModel: 1, lastModel: 20, models: 20, stride: 15) == (1, 0))
    }

    func testAbsoluteRangePartial() {
        XCTAssertTrue(MorphClipMapping.absoluteRange(firstModel: 3, lastModel: 8, models: 20, stride: 15) == (31, 106))
    }

    func testAbsoluteRangeTwoModels() {
        XCTAssertTrue(MorphClipMapping.absoluteRange(firstModel: 1, lastModel: 2, models: 2, stride: 10) == (1, 0))
        XCTAssertTrue(MorphClipMapping.absoluteRange(firstModel: 2, lastModel: 2, models: 2, stride: 10) == (11, 11))
    }

    // MARK: - pythonCall

    func testPythonCallEscapesAndDefaults() {
        let call = MorphSettings().pythonCall(source: "2kpo+A.1", name: nil)
        XCTAssertTrue(call.hasPrefix("from pymol import morph_jobs as _mj\n"))
        XCTAssertTrue(call.contains("_mj.morph_object('2kpo+A.1', name=None, frames_per_model=15, loop=1, method='rigimol', refinement=3, rate='linear', copy_look=1, async_=1, reuse=0)"))
        XCTAssertTrue(MorphSettings().pythonCall(source: "x", name: nil, reuse: true).hasSuffix("reuse=1)"))
    }

    // MARK: - conventionalSource

    func testConventionalSource() {
        XCTAssertEqual(MorphSettings.conventionalSource(of: "2kpo_morph", existing: ["2kpo", "2kpo_morph"]), "2kpo")
        XCTAssertEqual(MorphSettings.conventionalSource(of: "2kpo_morph2", existing: ["2kpo"]), "2kpo")
        XCTAssertNil(MorphSettings.conventionalSource(of: "2kpo_morph", existing: ["2kpo_morph"]))
        XCTAssertNil(MorphSettings.conventionalSource(of: "plain", existing: ["plain"]))
    }

    // MARK: - UserDefaults round-trip

    func testDefaultsRoundTrip() {
        let d = UserDefaults(suiteName: "MorphSettingsTests")!
        d.removePersistentDomain(forName: "MorphSettingsTests")
        var s = MorphSettings()
        s.framesPerModel = 42
        s.rate = "ramp up"
        s.save(d)
        XCTAssertEqual(MorphSettings.load(d), s)
        XCTAssertEqual(MorphSettings.load(UserDefaults(suiteName: "Empty")!), MorphSettings())
    }

    // MARK: - MorphCompletion

    func testCompletionPlanRespectsTimelineMode() {
        XCTAssertFalse(MorphCompletion.shouldAutoPlay(requested: true, timelineMode: true))
        XCTAssertTrue(MorphCompletion.shouldAutoPlay(requested: true, timelineMode: false))
    }
}
#endif
