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

    // MARK: - morphTarget

    func testMorphTargetFromMorphCardIsTheCardNamed() {
        let t = MorphSettings.morphTarget(card: "2kpo_morph2", source: "2kpo",
                                          objects: ["2kpo": 20, "2kpo_morph2": 300],
                                          groups: [], morphSources: [:])
        XCTAssertEqual(t.name, "2kpo_morph2")
        XCTAssertTrue(t.explicit)
    }

    func testMorphTargetNewMorphLeavesNameToPython() {
        let t = MorphSettings.morphTarget(card: "2kpo", source: "2kpo", objects: ["2kpo": 20],
                                          groups: [], morphSources: [:])
        XCTAssertEqual(t.name, "2kpo_morph")
        XCTAssertFalse(t.explicit)
    }

    /// After a session reload Python has no job record: unnamed it would build
    /// `2kpo_morph2` while the sheet said `2kpo_morph`.
    func testMorphTargetReloadedMorphIsNamed() {
        let t = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                          objects: ["2kpo": 20, "2kpo_morph": 1200],
                                          groups: [], morphSources: [:])
        XCTAssertEqual(t.name, "2kpo_morph")
        XCTAssertTrue(t.explicit)
    }

    /// This session built it: Python reuses it by its registry, so no name.
    func testMorphTargetKnownMorphIsReusedUnnamed() {
        let t = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                          objects: ["2kpo": 20, "2kpo_morph": 1200],
                                          groups: [], morphSources: ["2kpo_morph": "2kpo"])
        XCTAssertEqual(t.name, "2kpo_morph")
        XCTAssertFalse(t.explicit)
    }

    /// Spec §5.1: `_morph2` when the name is taken by a non-morph. A user's
    /// one-state molecule, a group, or a known morph of another object.
    func testMorphTargetTakenByNonMorphGoesToMorph2() {
        let user = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                             objects: ["2kpo": 20, "2kpo_morph": 1],
                                             groups: [], morphSources: [:])
        XCTAssertEqual(user.name, "2kpo_morph2")
        XCTAssertFalse(user.explicit)
        let group = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                              objects: ["2kpo": 20, "2kpo_morph": 1],
                                              groups: ["2kpo_morph"], morphSources: [:])
        XCTAssertEqual(group.name, "2kpo_morph2")
        XCTAssertFalse(group.explicit)
        let foreign = MorphSettings.morphTarget(
            card: "2kpo", source: "2kpo",
            objects: ["2kpo": 20, "2kpo_morph": 300, "2kpo_morph2": 1, "2kpo_morph3": 300],
            groups: [], morphSources: ["2kpo_morph": "other", "2kpo_morph3": "2kpo"])
        XCTAssertEqual(foreign.name, "2kpo_morph3")     // _morph2 is a user object
        XCTAssertFalse(foreign.explicit)
    }

    // MARK: - Sheet pre-fill

    /// A command-line morph can carry values the Steppers cannot show; they are
    /// clamped so pressing Morph cannot save them as the new default.
    func testPrefillClampsToStepperRanges() {
        var saved = MorphSettings()
        saved.movieSmooth = true
        var cli = MorphSettings()
        cli.framesPerModel = 200; cli.refinement = 20; cli.loop = false
        cli.method = "linear"; cli.rate = "ramp up"
        let s = MorphSheet.prefill(saved: saved, existing: cli)
        XCTAssertEqual(s.framesPerModel, 120)
        XCTAssertEqual(s.refinement, 10)
        XCTAssertFalse(s.loop)
        XCTAssertEqual(s.method, "linear")
        XCTAssertEqual(s.rate, "ramp up")
        XCTAssertTrue(s.movieSmooth)                    // not carried by the wire spec
        cli.framesPerModel = 1; cli.refinement = -3
        let low = MorphSheet.prefill(saved: saved, existing: cli)
        XCTAssertEqual(low.framesPerModel, 2)
        XCTAssertEqual(low.refinement, 0)
        XCTAssertEqual(MorphSheet.prefill(saved: saved, existing: nil), saved)
        XCTAssertEqual(MorphSheet.framesRange, 2...120)
        XCTAssertEqual(MorphSheet.refinementRange, 0...10)
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

    // MARK: - MorphSheet summary

    func testSheetSummaryLine() {
        let sum = MorphSettings().summary(models: 20, atoms: 1860, fps: 30)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30, showBytes: true,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: false),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 29 MB · creates 2kpo_morph, hides 2kpo")
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30, showBytes: true,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: true),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 29 MB · rebuilds 2kpo_morph")
        // From the source, when its morph is already loaded (e.g. after a reload)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30, showBytes: true,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: false, targetExists: true),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 29 MB · rebuilds 2kpo_morph, hides 2kpo")
    }

    func testSheetSummaryOmitsBytesWithoutAtomsAndGuardsZeroFPS() {
        var s = MorphSettings()
        s.framesPerModel = 10
        let sum = s.summary(models: 20, atoms: 0, fps: 0)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 0, showBytes: false,
                                   source: "a", target: "a_morph", isMorphObject: false),
            "20 models → 200 frames · 200 s at 1 fps · creates a_morph, hides a")
    }

    func testSheetMemoryTier() {
        XCTAssertEqual(MorphSheet.memoryTier(bytes: nil), .ok)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 200, warnAbove: 200, refuseAbove: 1000), .ok)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 201, warnAbove: 200, refuseAbove: 1000), .warn)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 1001, warnAbove: 200, refuseAbove: 1000), .refuse)
        // macOS thresholds (the test host is macOS).
        XCTAssertEqual(MorphSheet.warnBytes, 200e6)
        XCTAssertEqual(MorphSheet.refuseBytes, 1e9)
    }

    func testObjMetaCarriesAtomCount() {
        XCTAssertEqual(PyMOLEngine.parseObjMeta(["natoms": 1860]).atomCount, 1860)
        XCTAssertNil(PyMOLEngine.parseObjMeta(["state": 1]).atomCount)
    }
}
#endif
