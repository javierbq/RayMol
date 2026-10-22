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

    // MARK: - statesClipRange

    /// Plain clip (no morphStride) passes firstModel/lastModel through unchanged.
    func testStatesClipRangePlain() {
        let s = PyMOLEngine.StatesSpec(objects: ["x"], firstModel: 3, lastModel: 8)
        XCTAssertTrue(PyMOLEngine.statesClipRange(spec: s, models: 20, currentStride: nil) == (3, 8))
    }

    /// Morph clip maps model indices to absolute states using the current stride.
    /// Re-morphing with a different stride (currentStride != morphStride) remaps correctly.
    func testStatesClipRangeMorphRemaps() {
        var s = PyMOLEngine.StatesSpec(objects: ["x_morph"], firstModel: 3, lastModel: 8)
        s.morphStride = 15
        XCTAssertTrue(PyMOLEngine.statesClipRange(spec: s, models: 20, currentStride: 15) == (31, 106))
        XCTAssertTrue(PyMOLEngine.statesClipRange(spec: s, models: 20, currentStride: 10) == (21, 71))
    }

    /// Full model range produces the (1, 0) sentinel so PyMOL sweeps all states.
    func testStatesClipRangeMorphFull() {
        var s = PyMOLEngine.StatesSpec(objects: ["x_morph"], firstModel: 1, lastModel: 20)
        s.morphStride = 15
        XCTAssertTrue(PyMOLEngine.statesClipRange(spec: s, models: 20, currentStride: 15) == (1, 0))
    }

    // MARK: - adoptingMorphStrides

    private func morphClip(_ name: String, first: Int, last: Int,
                           stride: Int?) -> PyMOLEngine.TimelineItem {
        var s = PyMOLEngine.StatesSpec(objects: [name], firstModel: first, lastModel: last)
        s.morphStride = stride
        return PyMOLEngine.TimelineItem(kind: .states(s))
    }

    private func frames(_ n: Int) -> MorphSettings {
        var s = MorphSettings()
        s.framesPerModel = n
        return s
    }

    /// A regenerated morph's clips take its new stride with their model indices
    /// kept, so the stride a session save writes is the one the movie is built
    /// with, and a reload (no registry spec) maps the clip to the same states:
    /// 21–71 for models 3–8 at 10 frames per model, not 31–106.
    func testRegeneratedMorphClipsAdoptTheNewStride() throws {
        let clip = morphClip("m", first: 3, last: 8, stride: 15)
        let plain = PyMOLEngine.TimelineItem(kind: .states(
            PyMOLEngine.StatesSpec(objects: ["m"], firstModel: 3, lastModel: 8)))
        let other = morphClip("n", first: 2, last: 4, stride: 15)
        let items = [clip, plain, other]
        let adopted = try XCTUnwrap(PyMOLEngine.adoptingMorphStrides(
            items, previous: [:], current: ["m": frames(10)]))
        XCTAssertEqual(adopted.map(\.id), items.map(\.id))
        guard case .states(let s) = adopted[0].kind else { return XCTFail("not a states clip") }
        XCTAssertEqual(s.morphStride, 10)
        XCTAssertEqual(s.firstModel, 3)
        XCTAssertEqual(s.lastModel, 8)
        XCTAssertEqual(adopted[1], plain)       // a plain clip has no stride
        XCTAssertEqual(adopted[2], other)       // another morph's clip is left alone
        // The session save writes 10; a reload with no registry maps it to 21–71.
        let data = try JSONEncoder().encode(PyMOLEngine.timelineRecords(adopted))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual((json[0]["states"] as? [String: Any])?["morphStride"] as? Int, 10)
        let reloaded = PyMOLEngine.timelineItems(
            from: try JSONDecoder().decode([PyMOLEngine.TimelineRecord].self, from: data))
        guard case .states(let r) = reloaded[0].kind else { return XCTFail("not a states clip") }
        XCTAssertTrue(PyMOLEngine.statesClipRange(spec: r, models: 20, currentStride: nil) == (21, 71))
    }

    /// Only a change of the morph's own stride is adopted. An unchanged spec, a
    /// record the registry dropped (a session load restored the morph: the
    /// clip's saved stride stands), a clip already at the stride and a
    /// multi-object clip leave the lane alone.
    func testOnlyAStrideChangeIsAdopted() {
        let items = [morphClip("m", first: 3, last: 8, stride: 15)]
        XCTAssertNil(PyMOLEngine.adoptingMorphStrides(
            items, previous: ["m": frames(10)], current: ["m": frames(10)]))
        XCTAssertNil(PyMOLEngine.adoptingMorphStrides(
            items, previous: ["m": frames(10)], current: [:]))
        XCTAssertNil(PyMOLEngine.adoptingMorphStrides(
            items, previous: [:], current: ["m": frames(15)]))
        var multi = PyMOLEngine.StatesSpec(objects: ["m", "x"], firstModel: 1, lastModel: 0)
        multi.morphStride = 15
        XCTAssertNil(PyMOLEngine.adoptingMorphStrides(
            [PyMOLEngine.TimelineItem(kind: .states(multi))],
            previous: [:], current: ["m": frames(10)]))
    }

    // MARK: - States clip models and label

    /// A morph clip's models: the source's states when this session built it, else
    /// the morph's own states ÷ stride (restored from a session, or still building).
    func testMorphClipModels() {
        XCTAssertEqual(PyMOLEngine.morphClipModels(name: "m", stride: 15,
                                                   morphSources: ["m": "src"],
                                                   stateCounts: ["src": 20, "m": 300]), 20)
        XCTAssertEqual(PyMOLEngine.morphClipModels(name: "m", stride: 10, morphSources: [:],
                                                   stateCounts: ["m": 200]), 20)
        XCTAssertEqual(PyMOLEngine.morphClipModels(name: "m", stride: 15, morphSources: [:],
                                                   stateCounts: ["m": 16]), 1)
        XCTAssertEqual(PyMOLEngine.morphClipModels(name: "m", stride: 15, morphSources: [:],
                                                   stateCounts: [:]), 1)
    }

    /// The range suffix counts the clip's own models, so a full-range morph clip is
    /// not labelled "1–20" because its 300-state morph raised the global maximum;
    /// a morph clip carries the morph glyph.
    func testStatesClipLabel() {
        var m = PyMOLEngine.StatesSpec(objects: ["2kpo_morph"], firstModel: 1, lastModel: 20)
        m.morphStride = 15
        XCTAssertTrue(PyMOLEngine.statesClipLabel(m, models: 20) == ("2kpo_morph", "repeat"))
        m.firstModel = 3; m.lastModel = 8
        XCTAssertTrue(PyMOLEngine.statesClipLabel(m, models: 20) == ("2kpo_morph 3–8", "repeat"))
        let sweep = PyMOLEngine.StatesSpec(objects: ["2kpo"], mode: .sweep, firstModel: 1, lastModel: 20)
        XCTAssertTrue(PyMOLEngine.statesClipLabel(sweep, models: 20) == ("2kpo", "film.stack"))
        let loop = PyMOLEngine.StatesSpec(objects: ["2kpo"], mode: .loop, firstModel: 1, lastModel: 0)
        XCTAssertTrue(PyMOLEngine.statesClipLabel(loop, models: 20) == ("2kpo", "repeat"))
        let all = PyMOLEngine.StatesSpec(objects: nil, firstModel: 2, lastModel: 0)
        XCTAssertTrue(PyMOLEngine.statesClipLabel(all, models: 20) == ("20 models 2–20", "film.stack"))
        let two = PyMOLEngine.StatesSpec(objects: ["a", "b"], firstModel: 1, lastModel: 5)
        XCTAssertTrue(PyMOLEngine.statesClipLabel(two, models: 20) == ("2 objects 1–5", "film.stack"))
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

// MARK: - Play-models Add over an untracked movie (#901)

/// A session can carry a movie no Timeline lane describes; the first Timeline add
/// then waits for the user to agree to replace it. The Play-models sheet's smooth
/// Add is one action (start the morph, append its clip, remember the settings), so
/// it is held as one: Cancel on the prompt starts no morph, Replace runs it all.
/// Uses the live engine the unit-test host runs. The morph's source does not
/// exist, so the confirmed call fails in Python and builds nothing.
final class PlayModelsAddHoldTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var python: [String] = []
    private var savedItems: [PyMOLEngine.TimelineItem] = []

    override func setUpWithError() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready")
            throw NSError(domain: "PyMOLEngine", code: 1)
        }
        savedItems = engine.timelineItems
        engine.timelineItems = []
        engine.untrackedMovie = true
        engine.pythonTap = { [unowned self] in self.python.append($0) }
    }

    override func tearDown() {
        engine.pythonTap = nil
        engine.pendingTimelineAdd = nil
        engine.clearMovieItems()
        engine.timelineItems = savedItems
        super.tearDown()
    }

    private func smoothAdd() {
        var settings = MorphSettings()
        settings.framesPerModel = 5
        settings.refinement = 0
        settings.loop = true
        let plan = MorphMovie.AddPlan(
            morph: .init(source: "t12a_nosrc", name: nil, target: "t12a_nosrc_morph",
                         settings: settings),
            objects: ["t12a_nosrc_morph"], morphStride: 5, save: nil)
        engine.addPlayModelsClip(plan, mode: .sweep, firstModel: 1, lastModel: 0, seconds: 4)
    }

    private var morphCalls: [String] {
        python.filter { $0.contains("morph_object(") && $0.contains("t12a_nosrc") }
    }

    func testCancelledReplaceStartsNoMorph() {
        smoothAdd()
        XCTAssertNotNil(engine.pendingTimelineAdd)      // the replace prompt is up
        engine.pendingTimelineAdd = nil                 // Cancel
        XCTAssertEqual(morphCalls, [])
        XCTAssertEqual(engine.timelineItems, [])
    }

    func testConfirmedReplaceStartsTheMorphAndAddsItsClip() {
        smoothAdd()
        XCTAssertEqual(morphCalls, [])
        engine.confirmMovieReplace()
        XCTAssertEqual(morphCalls.count, 1)
        XCTAssertFalse(engine.untrackedMovie)
        guard engine.timelineItems.count == 1,
              case .states(let spec) = engine.timelineItems[0].kind else {
            return XCTFail("expected one states clip, got \(engine.timelineItems)")
        }
        XCTAssertEqual(spec.objects, ["t12a_nosrc_morph"])
        XCTAssertEqual(spec.morphStride, 5)
    }
}

/// A regenerate's completion rebuilds the movie with the finished morph's
/// stride: the poll records the new spec before it reports the completion, so a
/// 3–8 clip recorded at 15 frames per model and re-morphed at 10 plays states
/// 21–71 (not 31–106), and the clip keeps that stride for the next save.
/// Uses the live engine the unit-test host runs (the rebuild is read through
/// `pythonTap`); the objects it names do not exist, and it restores what it changes.
final class MorphCompletionRebuildTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var python: [String] = []
    private var savedItems: [PyMOLEngine.TimelineItem] = []
    private var savedObjects: [ObjectEntry] = []
    private var savedRunning: Set<String> = []
    private var savedSources: [String: String] = [:]
    private var savedSpecs: [String: MorphSettings] = [:]
    private var savedJobs: [PredictionJobState] = []
    private var savedExpanded: String?
    private let morph = "t12f_src_morph"

    override func setUpWithError() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready")
            throw NSError(domain: "PyMOLEngine", code: 1)
        }
        savedItems = engine.timelineItems
        savedObjects = engine.objects
        savedRunning = engine.runningMorphs
        savedSources = engine.morphSources
        savedSpecs = engine.morphSpecs
        savedJobs = engine.morphJobs
        savedExpanded = engine.expandedDetail
        engine.pythonTap = { [unowned self] in self.python.append($0) }
    }

    override func tearDown() {
        engine.pythonTap = nil
        engine.runningMorphs = savedRunning
        engine.morphSources = savedSources
        engine.morphSpecs = savedSpecs
        engine.morphJobs = savedJobs
        engine.objects = savedObjects
        engine.objectFPS[morph] = nil
        engine.expandedDetail = savedExpanded
        engine.clearMovieItems()
        engine.timelineItems = savedItems
        super.tearDown()
    }

    /// (first, last) of every states clip in the last `appkit_movie.rebuild` sent.
    private func lastRebuildRanges() throws -> [(Int, Int)] {
        let call = try XCTUnwrap(python.last { $0.contains("_am.rebuild(") }, "no rebuild sent")
        let b64 = try XCTUnwrap(call.components(separatedBy: "b64decode('").last?
            .components(separatedBy: "')").first)
        let data = try XCTUnwrap(Data(base64Encoded: b64))
        let spec = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return spec.filter { ($0["states"] as? Int) == 1 }.map {
            (($0["first"] as? Int) ?? -1, ($0["last"] as? Int) ?? -1)
        }
    }

    func testRegenerateCompletionRebuildsWithTheNewStride() throws {
        engine.objects = [
            ObjectEntry(id: "obj_t12f_src", name: "t12f_src", isEnabled: false,
                        isSelection: false, atomCount: nil, stateCount: 20),
            ObjectEntry(id: "obj_\(morph)", name: morph, isEnabled: true,
                        isSelection: false, atomCount: nil, stateCount: 200),
        ]
        var spec = PyMOLEngine.StatesSpec(objects: [morph], firstModel: 3, lastModel: 8)
        spec.morphStride = 15
        engine.timelineItems = [PyMOLEngine.TimelineItem(kind: .states(spec))]
        // While the re-morph built, the registry listed no finished morph by this name.
        engine.morphSources = [:]
        engine.morphSpecs = [:]
        engine.runningMorphs = [morph]
        python.removeAll()
        var settings = MorphSettings()
        settings.framesPerModel = 10
        engine.applyMorphPoll(jobs: [], running: [], sources: [morph: "t12f_src"],
                              specs: [morph: settings])
        let ranges = try lastRebuildRanges()
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.0, 21)
        XCTAssertEqual(ranges.first?.1, 71)
        guard case .states(let after) = engine.timelineItems.first?.kind else {
            return XCTFail("the clip is gone: \(engine.timelineItems)")
        }
        XCTAssertEqual(after.morphStride, 10)
        XCTAssertEqual(after.firstModel, 3)
        XCTAssertEqual(after.lastModel, 8)
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
