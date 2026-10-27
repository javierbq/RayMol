#if os(macOS)
import XCTest
@testable import RayMol

/// Unit coverage for `MorphSettings`, `MorphClipMapping`, and `MorphCompletion`.
///
/// All tests are pure (no engine calls) so they run in the macOS unit-test host
/// without launching PyMOL.
final class MorphSettingsTests: XCTestCase {

    // MARK: - Summary

    /// The bytes are Python's figure for one frame (morph_jobs.bytes_per_frame,
    /// overhead included) times the frames, as morph_estimate computes them.
    func testSummaryAtMovieFPS() {
        let s = MorphSettings()
        let sum = s.summary(models: 20, atoms: 1656, bytesPerFrame: 2_890_000, fps: 30)
        XCTAssertEqual(sum.legs, 20)
        XCTAssertEqual(sum.frames, 300)
        XCTAssertEqual(sum.seconds, 10, accuracy: 1e-9)
        XCTAssertEqual(sum.bytes, 300 * 2_890_000)
    }

    /// No figure from Python (the poll has not published one): no estimate.
    func testSummaryWithoutBytesPerFrameHasNoEstimate() {
        XCTAssertNil(MorphSettings().summary(models: 20, atoms: 1656, bytesPerFrame: nil,
                                             fps: 30).bytes)
    }

    func testSummaryNoLoop() {
        var s = MorphSettings()
        s.loop = false
        let sum = s.summary(models: 20, atoms: 10, bytesPerFrame: 1000, fps: 30)
        XCTAssertEqual(sum.legs, 19)
        XCTAssertEqual(sum.bytes, 19 * 15 * 1000)
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
        // A group reports its members' states (count_states), so the group guard,
        // not the state count, is what sends this one to _morph2.
        let group = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                              objects: ["2kpo": 20, "2kpo_morph": 20],
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

    /// Until its first leg lands, a morph being built has one state and no finished
    /// record; it still counts as this source's morph, so the source card's Morph…
    /// capsule stays hidden and its sheet names `2kpo_morph`, not `2kpo_morph2`.
    func testMorphTargetCountsABuildingMorph() {
        let t = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                          objects: ["2kpo": 20, "2kpo_morph": 1],
                                          groups: [], morphSources: [:],
                                          building: ["2kpo_morph"])
        XCTAssertEqual(t.name, "2kpo_morph")
        XCTAssertFalse(t.explicit)
        // Another source's building morph is not this source's.
        let other = MorphSettings.morphTarget(card: "2kpo", source: "2kpo",
                                              objects: ["2kpo": 20, "2kpo_morph": 1],
                                              groups: [], morphSources: [:],
                                              building: ["1nmr_morph"])
        XCTAssertEqual(other.name, "2kpo_morph2")
        // A morph's own card is the card, named, building or not.
        let own = MorphSettings.morphTarget(card: "2kpo_morph", source: "2kpo",
                                            objects: ["2kpo": 20, "2kpo_morph": 1],
                                            groups: [], morphSources: [:],
                                            building: ["2kpo_morph"])
        XCTAssertEqual(own.name, "2kpo_morph")
        XCTAssertTrue(own.explicit)
    }

    /// The row's ⟳ badge and its tooltip: the registry's source, else the
    /// `<source>_morph` convention (a morph a relaunch brought back), as the
    /// card's sheet resolves it.
    func testBadgeSource() {
        XCTAssertEqual(MorphSettings.badgeSource(registry: "2kpo", name: "2kpo_morph",
                                                 existing: ["2kpo_morph"]), "2kpo")
        XCTAssertEqual(MorphSettings.badgeSource(registry: nil, name: "2kpo_morph",
                                                 existing: ["2kpo", "2kpo_morph"]), "2kpo")
        XCTAssertNil(MorphSettings.badgeSource(registry: nil, name: "2kpo_morph",
                                               existing: ["2kpo_morph"]))
        XCTAssertNil(MorphSettings.badgeSource(registry: nil, name: "1nmr",
                                               existing: ["1nmr", "2kpo"]))
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

    /// A key the saved JSON lacks (one a later build added, or this build's
    /// movieSmooth in an older save) takes its default; the keys present keep
    /// what was saved instead of the whole struct falling back to defaults.
    func testDecodeKeepsSavedKeysWhenOneIsMissing() throws {
        let json = #"{"framesPerModel":42,"loop":false,"method":"linear","refinement":5,"rate":"ramp up"}"#
        let s = try JSONDecoder().decode(MorphSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.framesPerModel, 42)
        XCTAssertFalse(s.loop)
        XCTAssertEqual(s.method, "linear")
        XCTAssertEqual(s.refinement, 5)
        XCTAssertEqual(s.rate, "ramp up")
        XCTAssertFalse(s.movieSmooth)                   // the default
        // A key of the wrong type falls back alone; unknown keys are ignored.
        let odd = #"{"framesPerModel":"many","refinement":2,"later":1}"#
        let t = try JSONDecoder().decode(MorphSettings.self, from: Data(odd.utf8))
        XCTAssertEqual(t.framesPerModel, MorphSettings().framesPerModel)
        XCTAssertEqual(t.refinement, 2)
        // The encoding is unchanged: every key, read back equal.
        var all = MorphSettings()
        all.movieSmooth = true; all.framesPerModel = 7
        XCTAssertEqual(try JSONDecoder().decode(MorphSettings.self,
                                                from: JSONEncoder().encode(all)), all)
    }

    // MARK: - MorphCompletion

    func testCompletionPlanRespectsTimelineMode() {
        XCTAssertFalse(MorphCompletion.shouldAutoPlay(requested: true, timelineMode: true))
        XCTAssertTrue(MorphCompletion.shouldAutoPlay(requested: true, timelineMode: false))
    }

    // MARK: - MorphSheet summary

    /// 2kpo shown as cartoon: Python's 2.89 MB per frame × 300 frames, and the
    /// build-time hint (1860 atoms, 3 clean-up cycles: ≈ 28 s).
    func testSheetSummaryLine() {
        let sum = MorphSettings().summary(models: 20, atoms: 1860, bytesPerFrame: 2_890_000, fps: 30)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: false),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 867 MB · creates 2kpo_morph, hides 2kpo"
                + " · ≈ 28 s to build")
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: true),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 867 MB · rebuilds 2kpo_morph"
                + " · ≈ 28 s to build")
        // From the source, when its morph is already loaded (e.g. after a reload)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 30,
                                   source: "2kpo", target: "2kpo_morph",
                                   isMorphObject: false, targetExists: true),
            "20 models → 300 frames · 10 s at 30 fps · ≈ 867 MB · rebuilds 2kpo_morph, hides 2kpo"
                + " · ≈ 28 s to build")
    }

    func testSheetSummaryOmitsBytesWithoutAtomsAndGuardsZeroFPS() {
        var s = MorphSettings()
        s.framesPerModel = 10
        let sum = s.summary(models: 20, atoms: 0, bytesPerFrame: nil, fps: 0)
        XCTAssertEqual(
            MorphSheet.summaryLine(sum, models: 20, fps: 0,
                                   source: "a", target: "a_morph", isMorphObject: false),
            "20 models → 200 frames · 200 s at 1 fps · creates a_morph, hides a")
    }

    /// Spec §5.2's build-time hint, from measured costs: per atom per leg, plus
    /// per atom per frame growing with the clean-up cycles. Shown above 10 s.
    func testBuildSeconds() {
        // 2kpo, 20 legs: 300 frames at 3 cycles (measured 32 s), 1200 (117 s), at 0 (8 s).
        XCTAssertEqual(MorphSettings.buildSeconds(atoms: 1860, legs: 20, frames: 300,
                                                  refinement: 3), 28.086, accuracy: 0.01)
        XCTAssertEqual(MorphSettings.buildSeconds(atoms: 1860, legs: 20, frames: 1200,
                                                  refinement: 3), 106.764, accuracy: 0.01)
        XCTAssertEqual(MorphSettings.buildSeconds(atoms: 1860, legs: 20, frames: 300,
                                                  refinement: 0), 9.672, accuracy: 0.01)
        // 50k atoms, 3 models × 15 frames at 3 cycles (measured 88 s).
        XCTAssertEqual(MorphSettings.buildSeconds(atoms: 50_220, legs: 3, frames: 45,
                                                  refinement: 3), 113.75, accuracy: 0.01)
        XCTAssertEqual(MorphSettings.buildSeconds(atoms: 0, legs: 20, frames: 300,
                                                  refinement: 3), 0)
        XCTAssertEqual(MorphSettings().summary(models: 20, atoms: 1860, bytesPerFrame: nil,
                                               fps: 30).buildSeconds, 28.086, accuracy: 0.01)
        XCTAssertNil(MorphSheet.buildTime(10))
        XCTAssertNil(MorphSheet.buildTime(0))
        XCTAssertEqual(MorphSheet.buildTime(10.4), "≈ 10 s to build")
        XCTAssertEqual(MorphSheet.buildTime(75), "≈ 75 s to build")
        XCTAssertEqual(MorphSheet.buildTime(99.4), "≈ 99 s to build")
        XCTAssertEqual(MorphSheet.buildTime(106.8), "≈ 2 min to build")
        XCTAssertEqual(MorphSheet.buildTime(600), "≈ 10 min to build")
    }

    func testSheetMemoryTier() {
        let th = (warn: 200.0, refuse: 1000.0)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: nil, thresholds: th), .ok)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 200, thresholds: th), .ok)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 201, thresholds: th), .warn)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 1000, thresholds: th), .warn)
        XCTAssertEqual(MorphSheet.memoryTier(bytes: 1001, thresholds: th), .refuse)
    }

    func testObjMetaCarriesAtomCount() {
        XCTAssertEqual(PyMOLEngine.parseObjMeta(["natoms": 1860]).atomCount, 1860)
        XCTAssertNil(PyMOLEngine.parseObjMeta(["state": 1]).atomCount)
    }

    // MARK: - MorphMovie (Play-models sheet, spec §5.7)

    func testMovieToggleAvailability() {
        let objs = ["2kpo": 20, "2kpo_morph": 300, "movie": 40]
        XCTAssertEqual(MorphMovie.availability(target: nil, objects: objs,
                                               morphSources: [:], building: []),
                       .unavailable(reason: "Pick one object to smooth"))
        XCTAssertEqual(MorphMovie.availability(target: "2kpo", objects: objs,
                                               morphSources: ["2kpo_morph": "2kpo"], building: []),
                       .available)
        // This session's morph.
        XCTAssertEqual(MorphMovie.availability(target: "2kpo_morph", objects: objs,
                                               morphSources: ["2kpo_morph": "2kpo"], building: []),
                       .unavailable(reason: "Already a smooth morph"))
        // A morph a session reload brought back: the `<source>_morph` convention (§5.9).
        XCTAssertEqual(MorphMovie.availability(target: "2kpo_morph", objects: objs,
                                               morphSources: [:], building: []),
                       .unavailable(reason: "Already a smooth morph"))
        // A morph still being built (not yet in morphSources), whatever its name.
        XCTAssertEqual(MorphMovie.availability(target: "movie", objects: objs,
                                               morphSources: [:], building: ["movie"]),
                       .unavailable(reason: "Already a smooth morph"))
        XCTAssertEqual(MorphMovie.availability(target: "movie", objects: objs,
                                               morphSources: [:], building: []),
                       .available)
    }

    func testMovieNaturalSecondsRoundsToATenth() {
        XCTAssertEqual(MorphMovie.naturalSeconds(models: 20, framesPerModel: 15, fps: 30), 10)
        XCTAssertEqual(MorphMovie.naturalSeconds(models: 20, framesPerModel: 13, fps: 30), 8.7)
        XCTAssertEqual(MorphMovie.naturalSeconds(models: 20, framesPerModel: 60, fps: 30), 40)
        XCTAssertEqual(MorphMovie.naturalSeconds(models: 20, framesPerModel: 15, fps: 24), 12.5)
    }

    /// 1…30 s, widened to 1…max(30, ⌈natural⌉) while smoothing.
    func testMovieDurationRange() {
        XCTAssertEqual(MorphMovie.durationRange(smooth: false, natural: 40), 1...30)
        XCTAssertEqual(MorphMovie.durationRange(smooth: true, natural: 10), 1...30)
        XCTAssertEqual(MorphMovie.durationRange(smooth: true, natural: 40), 1...40)
        XCTAssertEqual(MorphMovie.durationRange(smooth: true, natural: 40.2), 1...41)
    }

    /// Natural length while smoothing and Duration is unedited; the user's value
    /// otherwise; always inside the stepper's current range.
    func testMovieDurationUpdateRule() {
        XCTAssertEqual(MorphMovie.duration(current: 8, smooth: true, edited: false, natural: 10), 10)
        XCTAssertEqual(MorphMovie.duration(current: 8, smooth: true, edited: false, natural: 40), 40)
        XCTAssertEqual(MorphMovie.duration(current: 8, smooth: true, edited: true, natural: 40), 8)
        XCTAssertEqual(MorphMovie.duration(current: 12, smooth: false, edited: false, natural: 10), 12)
        // Off again: back inside 1…30.
        XCTAssertEqual(MorphMovie.duration(current: 40, smooth: false, edited: false, natural: 40), 30)
        // Edited to 40 at 60 frames per model, then frames per model lowered.
        XCTAssertEqual(MorphMovie.duration(current: 40, smooth: true, edited: true, natural: 10), 30)
        // A natural length under a second is the stepper's 1 s floor.
        XCTAssertEqual(MorphMovie.duration(current: 8, smooth: true, edited: false, natural: 0.1), 1)
        // Off again with Duration unedited: the value the sheet opened with (8 s),
        // not the natural length the toggle wrote.
        XCTAssertEqual(MorphMovie.duration(current: 10, smooth: false, edited: false,
                                           natural: 10, opening: 8), 8)
        XCTAssertEqual(MorphMovie.duration(current: 30, smooth: false, edited: false,
                                           natural: 40, opening: 8), 8)
        // Edited: the user's value stays when smoothing turns off.
        XCTAssertEqual(MorphMovie.duration(current: 12, smooth: false, edited: true,
                                           natural: 10, opening: 8), 12)
        // Smoothing ignores the opening value.
        XCTAssertEqual(MorphMovie.duration(current: 8, smooth: true, edited: false,
                                           natural: 10, opening: 8), 10)
    }

    func testMovieCaption() {
        XCTAssertEqual(
            MorphMovie.caption(.available, smooth: true, target: "2kpo_morph",
                               models: 20, framesPerModel: 15, fps: 30),
            "Builds 2kpo_morph (20 models × 15 frames) and plays that instead · 10 s at 30 fps")
        XCTAssertEqual(
            MorphMovie.caption(.available, smooth: true, target: "2kpo_morph2",
                               models: 20, framesPerModel: 10, fps: 30),
            "Builds 2kpo_morph2 (20 models × 10 frames) and plays that instead · 6.7 s at 30 fps")
        XCTAssertNil(MorphMovie.caption(.available, smooth: false, target: "2kpo_morph",
                                        models: 20, framesPerModel: 15, fps: 30))
        XCTAssertEqual(
            MorphMovie.caption(.unavailable(reason: "Pick one object to smooth"), smooth: true,
                               target: "x_morph", models: 20, framesPerModel: 15, fps: 30),
            "Pick one object to smooth")
        // The memory note follows the seconds while smoothing, and only then.
        XCTAssertEqual(
            MorphMovie.caption(.available, smooth: true, target: "2kpo_morph",
                               models: 20, framesPerModel: 15, fps: 30, memory: "≈ 867 MB"),
            "Builds 2kpo_morph (20 models × 15 frames) and plays that instead · 10 s at 30 fps"
                + " · ≈ 867 MB")
        XCTAssertNil(MorphMovie.caption(.available, smooth: false, target: "2kpo_morph",
                                        models: 20, framesPerModel: 15, fps: 30,
                                        memory: "≈ 867 MB"))
        XCTAssertEqual(
            MorphMovie.caption(.unavailable(reason: "Already a smooth morph"), smooth: true,
                               target: "x_morph", models: 20, framesPerModel: 15, fps: 30,
                               memory: "≈ 867 MB"),
            "Already a smooth morph")
    }

    // MARK: - Memory (both sheets, spec §5.6)

    /// The thresholds morph_jobs.thresholds() uses: on macOS 1/16 and 1/4 of the
    /// machine's memory (at least 200 MB and 1 GB), on iOS 1/4 and 1/2 of what the
    /// app may still allocate (at least 100 MB and 400 MB; the floors when unknown).
    func testMemoryThresholds() {
        let gib: UInt64 = 1 << 30
        let mac = MorphSheet.memoryThresholds(physical: 36 * gib, available: nil, iOS: false)
        XCTAssertEqual(mac.warn, Double(36 * gib) / 16)
        XCTAssertEqual(mac.refuse, Double(36 * gib) / 4)
        let smallMac = MorphSheet.memoryThresholds(physical: 2_000_000_000, available: 5, iOS: false)
        XCTAssertEqual(smallMac.warn, 200e6)
        XCTAssertEqual(smallMac.refuse, 1e9)
        let ios = MorphSheet.memoryThresholds(physical: 8 * gib, available: 3_000_000_000, iOS: true)
        XCTAssertEqual(ios.warn, 750e6)
        XCTAssertEqual(ios.refuse, 1.5e9)
        let tight = MorphSheet.memoryThresholds(physical: 8 * gib, available: 600_000_000, iOS: true)
        XCTAssertEqual(tight.warn, 150e6)
        XCTAssertEqual(tight.refuse, 400e6)
        let unknown = MorphSheet.memoryThresholds(physical: 8 * gib, available: nil, iOS: true)
        XCTAssertEqual(unknown.warn, 100e6)
        XCTAssertEqual(unknown.refuse, 400e6)
        // The test host's live figures: the macOS rule on its own memory.
        let live = MorphSheet.currentThresholds()
        let host = MorphSheet.memoryThresholds(physical: ProcessInfo.processInfo.physicalMemory,
                                               available: nil, iOS: false)
        XCTAssertEqual(live.warn, host.warn)
        XCTAssertEqual(live.refuse, host.refuse)
    }

    /// The Play-models caption's estimate: the morph's frames (a loop) times
    /// Python's bytes per frame, orange above warn, with the remedy above refuse.
    func testMovieMemoryNote() {
        XCTAssertEqual(MorphMovie.estimatedBytes(models: 20, framesPerModel: 15,
                                                 bytesPerFrame: 2_890_000), 300 * 2_890_000)
        XCTAssertNil(MorphMovie.estimatedBytes(models: 20, framesPerModel: 15, bytesPerFrame: nil))
        let th = (warn: 200e6, refuse: 1e9)
        let none = MorphMovie.memoryNote(bytes: nil, thresholds: th)
        XCTAssertNil(none.text)
        XCTAssertEqual(none.tier, .ok)
        let ok = MorphMovie.memoryNote(bytes: 29_000_000, thresholds: th)
        XCTAssertEqual(ok.text, "≈ 29 MB")
        XCTAssertEqual(ok.tier, .ok)
        let warn = MorphMovie.memoryNote(bytes: 412_000_000, thresholds: th)
        XCTAssertEqual(warn.text, "≈ 412 MB")
        XCTAssertEqual(warn.tier, .warn)
        let refuse = MorphMovie.memoryNote(bytes: 3_470_000_000, thresholds: th)
        XCTAssertEqual(refuse.text, "≈ 3.5 GB · reduce frames per model")
        XCTAssertEqual(refuse.tier, .refuse)
    }

    /// Add cannot submit a smooth clip whose morph Python would refuse; a plain
    /// clip, or a smooth one under the limit, can be added.
    func testMovieAddDisabledAtTheRefuseTier() {
        XCTAssertFalse(MorphMovie.canAdd(smoothOn: true, tier: .refuse))
        XCTAssertTrue(MorphMovie.canAdd(smoothOn: true, tier: .warn))
        XCTAssertTrue(MorphMovie.canAdd(smoothOn: true, tier: .ok))
        XCTAssertTrue(MorphMovie.canAdd(smoothOn: false, tier: .refuse))
    }

    /// Python sizes up only a morph it would build. It keeps a finished morph of
    /// the source whose spec matches the one sent before it estimates anything
    /// (reuse), and Add submits no job while that morph is building. Neither is
    /// refused, so neither disables Add: the note shows the size alone, at `.ok`.
    func testMovieAddStaysEnabledWhenPythonWouldNotSizeTheMorph() {
        var s = MorphSettings()
        s.framesPerModel = 120
        s.loop = false                      // the Object panel's last choice
        s.movieSmooth = true
        var built = s                       // the registry's spec: loop on, no toggle
        built.loop = true
        built.movieSmooth = false
        let sources = ["2kpo_morph": "2kpo"]
        let plan = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: s,
                                      objects: ["2kpo": 20, "2kpo_morph": 2400], groups: [],
                                      morphSources: sources, building: [])
        // Reused: the finished morph of this source was built with these settings.
        XCTAssertFalse(MorphMovie.sizesMorph(plan, morphSources: sources,
                                             morphSpecs: ["2kpo_morph": built]))
        // Built again, so sized: another spec, no spec known, another source's morph.
        var other = built
        other.refinement = 0
        XCTAssertTrue(MorphMovie.sizesMorph(plan, morphSources: sources,
                                            morphSpecs: ["2kpo_morph": other]))
        XCTAssertTrue(MorphMovie.sizesMorph(plan, morphSources: sources, morphSpecs: [:]))
        XCTAssertTrue(MorphMovie.sizesMorph(plan, morphSources: ["2kpo_morph": "1nmr"],
                                            morphSpecs: ["2kpo_morph": built]))
        // A first build is sized.
        let first = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: s,
                                       objects: ["2kpo": 20], groups: [],
                                       morphSources: [:], building: [])
        XCTAssertTrue(MorphMovie.sizesMorph(first, morphSources: [:], morphSpecs: [:]))
        // Already building: no job, nothing sized. A plain clip has no morph.
        let building = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: s,
                                          objects: ["2kpo": 20, "2kpo_morph": 1], groups: [],
                                          morphSources: [:], building: ["2kpo_morph"])
        XCTAssertFalse(MorphMovie.sizesMorph(building, morphSources: [:], morphSpecs: [:]))
        let plain = MorphMovie.addPlan(target: "2kpo", smooth: false, settings: s,
                                       objects: ["2kpo": 20], groups: [],
                                       morphSources: [:], building: [])
        XCTAssertFalse(MorphMovie.sizesMorph(plain, morphSources: [:], morphSpecs: [:]))
        // Above the limit but not sized: the size alone, `.ok`, so Add stays enabled.
        let th = (warn: 200e6, refuse: 1e9)
        let kept = MorphMovie.memoryNote(bytes: 6_936_000_000, thresholds: th, sized: false)
        XCTAssertEqual(kept.text, "≈ 6.9 GB")
        XCTAssertEqual(kept.tier, .ok)
        XCTAssertTrue(MorphMovie.canAdd(smoothOn: true, tier: kept.tier))
        let sized = MorphMovie.memoryNote(bytes: 6_936_000_000, thresholds: th, sized: true)
        XCTAssertEqual(sized.text, "≈ 6.9 GB · reduce frames per model")
        XCTAssertFalse(MorphMovie.canAdd(smoothOn: true, tier: sized.tier))
    }

    /// The resolver is the Object panel's (MorphSettings.morphTarget), except that a
    /// morph still being built counts as this source's morph: its object has one
    /// state and no completed record yet, so the resolver alone would say `_morph2`.
    func testMovieTargetCountsARunningMorphAsTheSources() {
        let new = MorphMovie.target(source: "2kpo", objects: ["2kpo": 20],
                                    groups: [], morphSources: [:], building: [])
        XCTAssertEqual(new.name, "2kpo_morph")
        XCTAssertFalse(new.explicit)
        let running = MorphMovie.target(source: "2kpo", objects: ["2kpo": 20, "2kpo_morph": 1],
                                        groups: [], morphSources: [:], building: ["2kpo_morph"])
        XCTAssertEqual(running.name, "2kpo_morph")
        XCTAssertFalse(running.explicit)
        let reloaded = MorphMovie.target(source: "2kpo", objects: ["2kpo": 20, "2kpo_morph": 300],
                                         groups: [], morphSources: [:], building: [])
        XCTAssertEqual(reloaded.name, "2kpo_morph")
        XCTAssertTrue(reloaded.explicit)
    }

    func testMovieAddPlanSmooth() {
        var s = MorphSettings()
        s.loop = false                      // the Object panel's last choice
        s.framesPerModel = 20
        let plan = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: s,
                                      objects: ["2kpo": 20], groups: [],
                                      morphSources: [:], building: [])
        var sent = s
        sent.loop = true                    // implied on for the Movie path
        XCTAssertEqual(plan.morph, MorphMovie.AddPlan.MorphCall(
            source: "2kpo", name: nil, target: "2kpo_morph", settings: sent))
        XCTAssertEqual(plan.objects, ["2kpo_morph"])
        XCTAssertEqual(plan.morphStride, 20)
        var saved = s
        saved.movieSmooth = true            // the sheet's own loop is saved, not the forced one
        XCTAssertEqual(plan.save, saved)
    }

    func testMovieAddPlanNamesAReloadedMorph() {
        let plan = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: MorphSettings(),
                                      objects: ["2kpo": 20, "2kpo_morph": 300], groups: [],
                                      morphSources: [:], building: [])
        XCTAssertEqual(plan.morph?.name, "2kpo_morph")
        XCTAssertEqual(plan.morph?.target, "2kpo_morph")
        XCTAssertEqual(plan.objects, ["2kpo_morph"])
    }

    func testMovieAddPlanToggleOffIsAPlainClipAndRemembersOff() {
        var s = MorphSettings()
        s.movieSmooth = true
        let plan = MorphMovie.addPlan(target: "2kpo", smooth: false, settings: s,
                                      objects: ["2kpo": 20], groups: [],
                                      morphSources: [:], building: [])
        XCTAssertNil(plan.morph)
        XCTAssertEqual(plan.objects, ["2kpo"])
        XCTAssertNil(plan.morphStride)
        XCTAssertEqual(plan.save?.movieSmooth, false)
    }

    /// Unavailable toggle: a plain clip, and the saved toggle is left alone.
    func testMovieAddPlanUnavailableLeavesSettingsAlone() {
        let all = MorphMovie.addPlan(target: nil, smooth: true, settings: MorphSettings(),
                                     objects: ["2kpo": 20], groups: [],
                                     morphSources: [:], building: [])
        XCTAssertNil(all.morph)
        XCTAssertNil(all.objects)
        XCTAssertNil(all.morphStride)
        XCTAssertNil(all.save)
        let morph = MorphMovie.addPlan(target: "2kpo_morph", smooth: true, settings: MorphSettings(),
                                       objects: ["2kpo": 20, "2kpo_morph": 300], groups: [],
                                       morphSources: ["2kpo_morph": "2kpo"], building: [])
        XCTAssertNil(morph.morph)
        XCTAssertEqual(morph.objects, ["2kpo_morph"])
        XCTAssertNil(morph.morphStride)
        XCTAssertNil(morph.save)
    }

    /// Python refuses a second job on a target being built; the clip names it and
    /// is rebuilt when it completes.
    func testMovieAddPlanWhileItsMorphIsBuilding() {
        let plan = MorphMovie.addPlan(target: "2kpo", smooth: true, settings: MorphSettings(),
                                      objects: ["2kpo": 20, "2kpo_morph": 1], groups: [],
                                      morphSources: [:], building: ["2kpo_morph"])
        XCTAssertNil(plan.morph)
        XCTAssertEqual(plan.objects, ["2kpo_morph"])
        XCTAssertEqual(plan.morphStride, 15)
        XCTAssertEqual(plan.save?.movieSmooth, true)
    }

    func testNumberFormatting() {
        XCTAssertEqual(MorphSettings.number(10), "10")
        XCTAssertEqual(MorphSettings.number(6.6667), "6.7")
        XCTAssertEqual(MorphSettings.number(29.97), "30")
    }
}
#endif
