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

    /// The auto-play requests a poll leaves: only those that may still complete.
    /// A job whose record is terminal (failed, cancelled, refused) and a name that
    /// left the running set without a finished record (dismissed, deleted) lose
    /// theirs; otherwise a later build of that name that did not ask for auto-play
    /// (a Movie-tab smooth Add, a command-line morph) would start playing.
    func testAutoPlayAfterPoll() {
        // Cancelled or failed while building: dropped; the other one stays.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["a_morph", "b_morph"], previouslyRunning: ["a_morph", "b_morph"],
            nowRunning: ["b_morph"], sources: [:], failed: ["a_morph"], completed: []),
            ["b_morph"])
        // Refused at once (never ran): its error record drops it.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["r_morph"], previouslyRunning: [], nowRunning: [],
            sources: [:], failed: ["r_morph"], completed: []), [])
        // Refused next to a finished morph of that name: Python files the card
        // under "<name> (refused)".
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["f_morph"], previouslyRunning: [], nowRunning: [],
            sources: ["f_morph": "f"], failed: ["f_morph (refused)"], completed: []), [])
        // Left running with no record at all (dismissed): dropped.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["d_morph"], previouslyRunning: ["d_morph"], nowRunning: [],
            sources: [:], failed: [], completed: []), [])
        // Left running and finished: kept, for morphDidComplete to consume.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["c_morph"], previouslyRunning: ["c_morph"], nowRunning: [],
            sources: ["c_morph": "c"], failed: [], completed: ["c_morph"]), ["c_morph"])
        // Just requested, not listed by any poll yet: kept.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["n_morph"], previouslyRunning: [], nowRunning: [],
            sources: [:], failed: [], completed: []), ["n_morph"])
        // A new build of the name while an earlier refusal's card is still in the
        // tray (the user re-morphed without dismissing it): the build owns the
        // request, whether a poll lists it running, it finishes inside this poll
        // (a small morph no poll saw running), or it left running finished.
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["f_morph"], previouslyRunning: [], nowRunning: ["f_morph"],
            sources: [:], failed: ["f_morph (refused)"], completed: []), ["f_morph"])
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["f_morph"], previouslyRunning: [], nowRunning: [],
            sources: ["f_morph": "f"], failed: ["f_morph (refused)"],
            completed: ["f_morph"]), ["f_morph"])
        XCTAssertEqual(PyMOLEngine.autoPlayAfterPoll(
            autoPlay: ["f_morph"], previouslyRunning: ["f_morph"], nowRunning: [],
            sources: ["f_morph": "f"], failed: ["f_morph (refused)"],
            completed: ["f_morph"]), ["f_morph"])
    }

    /// The engine applies that rule on every poll, and a morph started without
    /// auto-play clears an earlier request for its target. The test host runs a
    /// live engine: the morph's source does not exist, so Python refuses it and
    /// files a failed record, which the test removes.
    func testAutoPlayRequestsAreClearedByPollsAndByANonAutoPlayMorph() {
        let engine = PyMOLEngine.shared
        let saved = (engine.morphJobs, engine.runningMorphs)
        defer {
            engine.runPython("from pymol import morph_jobs as _mj\n"
                             + "_mj.morph_dismiss('t4ap_src_morph')\n"
                             + "_mj._JOBS.pop('t4ap_src_morph', None)")
            engine.morphJobs = saved.0
            engine.runningMorphs = saved.1
        }
        var s = MorphSettings()
        s.framesPerModel = 2
        s.refinement = 0
        engine.morph(source: "t4ap_src", settings: s, autoPlay: true)
        XCTAssertTrue(engine.morphAutoPlay.contains("t4ap_src_morph"))
        engine.morph(source: "t4ap_src", settings: s, autoPlay: false)
        XCTAssertFalse(engine.morphAutoPlay.contains("t4ap_src_morph"))
        engine.morph(source: "t4ap_src", settings: s, autoPlay: true)
        XCTAssertTrue(engine.morphAutoPlay.contains("t4ap_src_morph"))
        engine.applyMorphPoll(
            jobs: [PredictionJobState.fixture(id: "t4ap_src_morph", state: "error",
                                              error: "morph: refused")],
            running: [], sources: [:], specs: [:], builds: [:])
        XCTAssertFalse(engine.morphAutoPlay.contains("t4ap_src_morph"))
    }

    /// A finished morph whose build number no poll has reported is a completion,
    /// whether or not a poll saw it building: a small morph lands inside one
    /// poll's pump, and a rebuild with the same settings changes nothing else.
    func testNewlyBuiltMorphs() {
        XCTAssertEqual(PyMOLEngine.newlyBuiltMorphs(builds: ["a": 3, "b": 4, "c": 5],
                                                    seen: [3, 9]), ["b", "c"])
        XCTAssertEqual(PyMOLEngine.newlyBuiltMorphs(builds: ["a": 3], seen: [3]), [])
        XCTAssertEqual(PyMOLEngine.newlyBuiltMorphs(builds: [:], seen: [3]), [])
    }

    /// The panel payload's morph record carries its build number; a record
    /// without one (an older bundled Python) still decodes, with none.
    func testMorphRecordDecodesItsBuildNumber() throws {
        let json = """
        {"objects":["s","s_morph","t_morph"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"s":5,"s_morph":50,"t_morph":20},"has_transp":{},"groups":[],"parent":{},
         "pending":{},
         "morph":{"s_morph":{"source":"s","build":7,
                             "spec":{"frames_per_model":10,"loop":1,"method":"rigimol",
                                     "refinement":3,"rate":"linear","copy_look":1}},
                  "t_morph":{"source":"t",
                             "spec":{"frames_per_model":5,"loop":1,"method":"rigimol",
                                     "refinement":0,"rate":"linear","copy_look":1}}}}
        """
        let payload = try JSONDecoder().decode(PanelPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.morph?["s_morph"]?.build, 7)
        XCTAssertEqual(payload.morph?["s_morph"]?.spec.frames_per_model, 10)
        XCTAssertNil(payload.morph?["t_morph"]?.build)
        XCTAssertEqual(payload.morph?["t_morph"]?.source, "t")
        // No morph_bytes_per_frame (an older bundled Python): still decodes.
        XCTAssertNil(payload.morph_bytes_per_frame)
    }

    /// Python's bytes per morph frame of each multi-state molecule, the figure
    /// both sheets multiply by their frames.
    func testPanelPayloadCarriesMorphBytesPerFrame() throws {
        let json = """
        {"objects":["2kpo"],"selections":[],"enabled":["2kpo"],"sel_counts":{},
         "nstate":{"2kpo":20},"morph":{},"morph_bytes_per_frame":{"2kpo":2890000}}
        """
        let payload = try JSONDecoder().decode(PanelPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.morph_bytes_per_frame, ["2kpo": 2_890_000])
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

    /// Stopping every per-object player for the Movie tab hands the objects back to
    /// the movie: each timer pinned its object with `set state`, so releasing
    /// unsets it. A plain stop leaves the states alone. Uses the live engine's
    /// command tap; the objects named do not exist.
    func testStopAllObjectStatesReleasingUnpinsTheObjects() {
        let engine = PyMOLEngine.shared
        var commands: [String] = []
        engine.commandTap = { commands.append($0) }
        defer { engine.commandTap = nil }
        engine.playingObjects = ["t4rel_a", "t4rel_b"]
        engine.stopAllObjectStates()
        XCTAssertEqual(commands, [])
        XCTAssertTrue(engine.playingObjects.isEmpty)
        engine.playingObjects = ["t4rel_a", "t4rel_b"]
        engine.stopAllObjectStates(releasing: true)
        XCTAssertEqual(Set(commands), ["unset state, t4rel_a", "unset state, t4rel_b"])
        XCTAssertTrue(engine.playingObjects.isEmpty)
    }

    /// The registry calls a player sends to appkit_movie, which keeps a playing
    /// object's timer pin out of a saved session (close-out B).
    static func registryCalls(_ python: [String]) -> [String] {
        python.filter { $0.contains("note_object_playing(") || $0.contains("clear_playing_objects(") }
    }

    /// Stopping a player takes it out of the Python registry; stopping one that
    /// is not playing sends nothing, and stopping them all clears the registry
    /// whether or not the objects are released. The live engine's Python tap
    /// records the calls; the objects named do not exist.
    func testStoppingPlayersUpdatesThePythonRegistry() {
        let engine = PyMOLEngine.shared
        var python: [String] = []
        engine.pythonTap = { python.append($0) }
        defer { engine.pythonTap = nil }
        engine.playingObjects = []
        engine.stopObjectStates("t4reg_a")
        XCTAssertEqual(Self.registryCalls(python), [])
        engine.playingObjects = ["t4reg_a", "t4reg_b"]
        engine.stopObjectStates("t4reg_a")
        XCTAssertEqual(Self.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.note_object_playing('t4reg_a', False)",
        ])
        python.removeAll()
        engine.stopAllObjectStates()
        XCTAssertEqual(Self.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.clear_playing_objects()",
        ])
        python.removeAll()
        engine.playingObjects = ["t4reg_a"]
        engine.stopAllObjectStates(releasing: true)
        XCTAssertEqual(Self.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.clear_playing_objects()",
        ])
        python.removeAll()
        engine.stopAllObjectStates()                    // nothing playing
        XCTAssertEqual(Self.registryCalls(python), [])
    }

    /// iOS memory warning (spec §5.6; OOM is uncatchable there): every morph still
    /// building is cancelled, which frees its partial object and the worker's leg,
    /// per-object playback stops, and the console says why. Records already failed
    /// or cancelled are left alone. The live engine's Python tap records the calls;
    /// the jobs named do not exist, so morph_cancel does nothing.
    func testMemoryWarningCancelsBuildingMorphs() {
        let engine = PyMOLEngine.shared
        let saved = engine.morphJobs
        var python: [String] = []
        engine.pythonTap = { python.append($0) }
        defer {
            engine.pythonTap = nil
            engine.morphJobs = saved
        }
        engine.morphJobs = [
            PredictionJobState.fixture(id: "t4mw_run", state: "running"),
            PredictionJobState.fixture(id: "t4mw_queued", state: "queued"),
            PredictionJobState.fixture(id: "t4mw_err", state: "error", error: "x"),
            PredictionJobState.fixture(id: "t4mw_cancel", state: "cancelled"),
        ]
        engine.playingObjects = ["t4mw_play"]
        engine.cancelMorphsForMemoryWarning()
        XCTAssertEqual(Set(python.filter { $0.contains("morph_cancel(") }), [
            "from pymol import cmd as _c\n_c.morph_cancel('t4mw_queued')",
            "from pymol import cmd as _c\n_c.morph_cancel('t4mw_run')",
        ])
        XCTAssertTrue(engine.playingObjects.isEmpty)
        XCTAssertEqual(engine.feedbackLog.last, "morph: cancelled on memory warning")
        // Nothing building: no cancel, no console line.
        python.removeAll()
        let lines = engine.feedbackLog.count
        engine.morphJobs = [PredictionJobState.fixture(id: "t4mw_err", state: "error", error: "x")]
        engine.cancelMorphsForMemoryWarning()
        XCTAssertEqual(python.filter { $0.contains("morph_cancel(") }, [])
        XCTAssertEqual(engine.feedbackLog.count, lines)
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
        // A plain single-object clip is measured against that object's own models,
        // whatever else is loaded: its full range has no suffix.
        var plain = PyMOLEngine.StatesSpec(objects: ["1nmr"], firstModel: 1, lastModel: 20)
        XCTAssertTrue(PyMOLEngine.statesClipLabel(plain, models: 20) == ("1nmr", "film.stack"))
        plain.lastModel = 10
        XCTAssertTrue(PyMOLEngine.statesClipLabel(plain, models: 20) == ("1nmr 1–10", "film.stack"))
    }

    /// A clip that plays nothing reads "label — note" when it is wide enough; a
    /// narrow one shows the note alone (the lane draws the ⚠ glyph before it), so
    /// the reason is not cut off. The name stays in the tooltip and the menu.
    func testStatesClipCaption() {
        let note = "not built · morph 2kpo to fill"
        XCTAssertEqual(PyMOLEngine.statesClipCaption(label: "2kpo_morph", note: nil, width: 40),
                       "2kpo_morph")
        XCTAssertEqual(PyMOLEngine.statesClipCaption(label: "2kpo_morph", note: note, width: 400),
                       "2kpo_morph — \(note)")
        XCTAssertEqual(PyMOLEngine.statesClipCaption(label: "2kpo_morph", note: note, width: 160),
                       "2kpo_morph — \(note)")
        XCTAssertEqual(PyMOLEngine.statesClipCaption(label: "2kpo_morph", note: note, width: 159),
                       note)
        XCTAssertEqual(PyMOLEngine.statesClipCaption(label: "2kpo_morph", note: note, width: 30),
                       note)
    }

    // MARK: - Clips whose objects are not loaded

    /// An object a states clip names counts as missing only when two polls in a
    /// row found it absent. One poll's payload can be older than the lane it is
    /// applied to: a smooth Add creates its morph and adds the clip between a
    /// poll's gathering and its arrival, and that clip must not flash as missing.
    func testMissingClipObjectsNeedTwoPolls() {
        let items = [
            morphClip("m", first: 1, last: 0, stride: 10),
            PyMOLEngine.TimelineItem(kind: .states(
                PyMOLEngine.StatesSpec(objects: ["x", "y"], firstModel: 1, lastModel: 0))),
            PyMOLEngine.TimelineItem(kind: .states(
                PyMOLEngine.StatesSpec(objects: nil, firstModel: 1, lastModel: 0))),
            PyMOLEngine.TimelineItem(kind: .camera),
            PyMOLEngine.TimelineItem(kind: .scene(name: "gone")),
        ]
        let first = PyMOLEngine.clipObjectsPoll(items: items, loaded: ["x"], previouslyAbsent: [])
        XCTAssertEqual(first.absent, ["m", "y"])
        XCTAssertEqual(first.missing, [])
        let second = PyMOLEngine.clipObjectsPoll(items: items, loaded: ["x"],
                                                 previouslyAbsent: first.absent)
        XCTAssertEqual(second.missing, ["m", "y"])
        let third = PyMOLEngine.clipObjectsPoll(items: items, loaded: ["x", "m"],
                                                previouslyAbsent: second.absent)
        XCTAssertEqual(third.absent, ["y"])
        XCTAssertEqual(third.missing, ["y"])
        // The stale poll after an Add, then the first fresh one: never missing.
        let lane = [morphClip("n_morph", first: 1, last: 0, stride: 15)]
        let stale = PyMOLEngine.clipObjectsPoll(items: lane, loaded: ["n"], previouslyAbsent: [])
        XCTAssertEqual(stale.missing, [])
        let fresh = PyMOLEngine.clipObjectsPoll(items: lane, loaded: ["n", "n_morph"],
                                                previouslyAbsent: stale.absent)
        XCTAssertEqual(fresh.absent, [])
        XCTAssertEqual(fresh.missing, [])
    }

    /// A morph clip's source, by the `<source>_morph[N]` convention, when it is loaded.
    func testMorphClipSource() {
        var m = PyMOLEngine.StatesSpec(objects: ["2kpo_morph"], firstModel: 1, lastModel: 0)
        m.morphStride = 60
        XCTAssertEqual(PyMOLEngine.morphClipSource(m, loaded: ["2kpo"]), "2kpo")
        XCTAssertNil(PyMOLEngine.morphClipSource(m, loaded: ["other"]))
        m.objects = ["2kpo_morph2"]
        XCTAssertEqual(PyMOLEngine.morphClipSource(m, loaded: ["2kpo"]), "2kpo")
        let plain = PyMOLEngine.StatesSpec(objects: ["2kpo_morph"], firstModel: 1, lastModel: 0)
        XCTAssertNil(PyMOLEngine.morphClipSource(plain, loaded: ["2kpo"]))
    }

    /// The caption of a clip that plays nothing: a morph clip says it was not built
    /// and which object to morph; a plain clip says its object is not loaded.
    func testStatesClipMissingNote() {
        var m = PyMOLEngine.StatesSpec(objects: ["2kpo_morph"], firstModel: 1, lastModel: 0)
        m.morphStride = 60
        XCTAssertEqual(PyMOLEngine.statesClipMissingNote(m, missing: ["2kpo_morph"],
                                                         loaded: ["2kpo"]),
                       "not built · morph 2kpo to fill")
        XCTAssertEqual(PyMOLEngine.statesClipMissingNote(m, missing: ["2kpo_morph"], loaded: []),
                       "not built · morph its source to fill")
        XCTAssertNil(PyMOLEngine.statesClipMissingNote(m, missing: [], loaded: ["2kpo"]))
        let one = PyMOLEngine.StatesSpec(objects: ["2kpo"], firstModel: 1, lastModel: 0)
        XCTAssertEqual(PyMOLEngine.statesClipMissingNote(one, missing: ["2kpo"], loaded: []),
                       "not loaded")
        let three = PyMOLEngine.StatesSpec(objects: ["a", "b", "c"], firstModel: 1, lastModel: 0)
        XCTAssertEqual(PyMOLEngine.statesClipMissingNote(three, missing: ["a", "c"], loaded: ["b"]),
                       "a, c not loaded")
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
    private var savedSeen: Set<Int> = []
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
        savedSeen = engine.seenMorphBuilds
        engine.pythonTap = { [unowned self] in self.python.append($0) }
    }

    override func tearDown() {
        engine.pythonTap = nil
        engine.seenMorphBuilds = savedSeen
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
                              specs: [morph: settings], builds: [morph: 9_001])
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

    // MARK: Morphs no poll saw building

    /// A source of 5 models, its morph built at 10 frames per model, and a smooth
    /// Play-models clip of models 2-4 made for that stride: what the Add leaves
    /// when the morph is small enough to start and finish inside one poll's pump.
    private func smallMorphLane() {
        engine.objects = [
            ObjectEntry(id: "obj_t12f_src", name: "t12f_src", isEnabled: false,
                        isSelection: false, atomCount: nil, stateCount: 5),
            ObjectEntry(id: "obj_\(morph)", name: morph, isEnabled: true,
                        isSelection: false, atomCount: nil, stateCount: 50),
        ]
        var spec = PyMOLEngine.StatesSpec(objects: [morph], firstModel: 2, lastModel: 4)
        spec.morphStride = 10
        engine.timelineItems = [PyMOLEngine.TimelineItem(kind: .states(spec))]
        engine.runningMorphs = []
        engine.expandedDetail = nil
    }

    private func frames(_ n: Int) -> MorphSettings {
        var s = MorphSettings()
        s.framesPerModel = n
        return s
    }

    /// A regenerate at a new stride that no poll saw building: the registry's
    /// stride changes (15 to 10), the clip already carries 10 so nothing is
    /// adopted, and the new build number is what reports the completion. The
    /// movie is rebuilt with models 2-4 at 10 frames per model: states 11-31.
    func testFastRegenerateNoPollSawBuildingRebuilds() throws {
        smallMorphLane()
        engine.morphSources = [morph: "t12f_src"]
        engine.morphSpecs = [morph: frames(15)]
        engine.seenMorphBuilds = [9_101]
        python.removeAll()
        engine.applyMorphPoll(jobs: [], running: [], sources: [morph: "t12f_src"],
                              specs: [morph: frames(10)], builds: [morph: 9_102])
        let ranges = try lastRebuildRanges()
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.0, 11)
        XCTAssertEqual(ranges.first?.1, 31)
        XCTAssertEqual(engine.expandedDetail, morph)        // morphDidComplete ran
        XCTAssertTrue(engine.seenMorphBuilds.contains(9_102))
    }

    /// The same for a first build: the morph appears in the registry already
    /// finished, never having been listed as running.
    func testFastFirstBuildNoPollSawBuildingRebuilds() throws {
        smallMorphLane()
        engine.morphSources = [:]
        engine.morphSpecs = [:]
        engine.seenMorphBuilds = []
        python.removeAll()
        engine.applyMorphPoll(jobs: [], running: [], sources: [morph: "t12f_src"],
                              specs: [morph: frames(10)], builds: [morph: 9_103])
        let ranges = try lastRebuildRanges()
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges.first?.0, 11)
        XCTAssertEqual(ranges.first?.1, 31)
        XCTAssertEqual(engine.expandedDetail, morph)
    }

    /// A morph started from the Object panel (auto-play on) while an earlier
    /// refusal's card for its name is still in the tray plays when it completes:
    /// the polls that list it running and then finished keep its request. The
    /// morph call reaches the live engine's Python, which refuses it (no such
    /// source) and files a record; the test removes it.
    func testAutoPlayOutlivesAnEarlierRefusalCard() {
        smallMorphLane()
        engine.morphSources = [:]
        engine.morphSpecs = [:]
        engine.seenMorphBuilds = []
        defer {
            engine.runPython("from pymol import morph_jobs as _mj\n"
                             + "_mj.morph_dismiss('\(morph)')\n"
                             + "_mj._JOBS.pop('\(morph)', None)")
            engine.stopObjectStates(morph)
        }
        var settings = frames(10)
        settings.refinement = 0
        engine.morph(source: "t12f_src", settings: settings, autoPlay: true)
        let card = PredictionJobState.fixture(id: "\(morph) (refused)", state: "error",
                                              error: "morph: refused")
        engine.applyMorphPoll(jobs: [card, PredictionJobState.fixture(id: morph)],
                              running: [morph], sources: [:], specs: [:], builds: [:])
        XCTAssertTrue(engine.morphAutoPlay.contains(morph))
        engine.applyMorphPoll(jobs: [card], running: [], sources: [morph: "t12f_src"],
                              specs: [morph: frames(10)], builds: [morph: 9_105])
        XCTAssertTrue(engine.playingObjects.contains(morph), "the morph did not auto-play")
    }

    /// A build already reported is not a completion again: the next polls, and a
    /// Theme studio restore that keeps the record, rebuild nothing.
    func testAReportedBuildIsNotACompletionAgain() {
        smallMorphLane()
        engine.morphSources = [morph: "t12f_src"]
        engine.morphSpecs = [morph: frames(10)]
        engine.seenMorphBuilds = [9_104]
        python.removeAll()
        engine.applyMorphPoll(jobs: [], running: [], sources: [morph: "t12f_src"],
                              specs: [morph: frames(10)], builds: [morph: 9_104])
        XCTAssertFalse(python.contains { $0.contains("_am.rebuild(") })
        XCTAssertNil(engine.expandedDetail)
    }
}

/// Morph clips on the real engine and the host app's own panel polls; the movie
/// is read back from Python. Cleans up what it creates.
///
/// - The review's repro: a smooth Play-models Add of a morph small enough to
///   start and finish inside one poll's pump. No poll lists such a morph as
///   running; before build numbers nothing reported its completion, and the
///   movie kept the rebuild the Add made while the morph had one state, with no
///   track for it.
/// - A clip naming a morph that is not loaded (a session saved while it was
///   being built, reopened): the polls mark it, and its Build action fills it.
final class MorphClipLiveTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var savedItems: [PyMOLEngine.TimelineItem] = []
    private var savedUntracked = false
    private var savedExpanded: String?
    private let source = "t12r2_src"
    private var morph: String { source + "_morph" }

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
        savedUntracked = engine.untrackedMovie
        savedExpanded = engine.expandedDetail
    }

    override func tearDown() {
        engine.runPython("from pymol import cmd as _c, morph_jobs as _mj\n"
                         + "_mj.morph_cancel('\(morph)')\n"
                         + "_mj.morph_dismiss('\(morph)')\n"
                         + "_mj._JOBS.pop('\(morph)', None)\n"
                         + "_c.delete('\(source)*')")
        engine.stopObjectStates(morph)
        engine.objectFPS[morph] = nil
        engine.clearMovieItems()
        engine.timelineItems = savedItems
        engine.untrackedMovie = savedUntracked
        engine.expandedDetail = savedExpanded
        super.tearDown()
    }

    /// Movie frame → state of the morph's own state track, and the movie length.
    private func morphTrack() throws -> (track: [Int: Int], length: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-t12r2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        engine.runPython("""
        import json as _t12_json
        from pymol import cmd as _t12_c
        _t12_track = {}
        for _t12_e in _t12_c.get_session('\(morph)', partial=1)['names']:
            if _t12_e and _t12_e[0] == '\(morph)':
                for _t12_i, _t12_v in enumerate(_t12_e[5][0][13] or []):
                    if _t12_v and _t12_v[19]:
                        _t12_track[_t12_i + 1] = _t12_v[20] + 1
        with open(r'''\(url.path)''', 'w', encoding='utf-8') as _t12_f:
            _t12_json.dump({'track': _t12_track, 'length': _t12_c.get_movie_length()}, _t12_f)
        """)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let raw = json["track"] as? [String: Int] ?? [:]
        let track = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
        return (track, json["length"] as? Int ?? 0)
    }

    /// A 5-model peptide: its morph at 10 frames per model builds within one pump.
    private func makeSource() {
        engine.runPython("""
        from pymol import cmd as _c
        _c.fab('ACDEFGHIK', '\(source)')
        for _k in range(2, 6):
            _c.create('\(source)', '\(source)', 1, _k)
            _c.rotate('y', 25 * (_k - 1), '\(source) and resi 5-9', _k)
        """)
    }

    /// Spins the run loop (the host's polls) until `done`, or 15 s.
    private func spin(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !done() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testSmallSmoothAddFillsTheMovie() throws {
        makeSource()
        engine.clearMovieItems()
        var settings = MorphSettings()
        settings.framesPerModel = 10
        settings.refinement = 0
        settings.loop = true
        let plan = MorphMovie.AddPlan(
            morph: .init(source: source, name: nil, target: morph, settings: settings),
            objects: [morph], morphStride: 10, save: nil)
        let seen = engine.seenMorphBuilds
        engine.addPlayModelsClip(plan, mode: .sweep, firstModel: 2, lastModel: 4, seconds: 4)
        XCTAssertEqual(try morphTrack().track, [:])     // the Add rebuilt it with one state
        // The host app's own polls land the morph and report it: a poll has seen
        // its build (the engine's morph state may still hold an earlier test's).
        var sawRunning = false
        spin {
            sawRunning = sawRunning || engine.runningMorphs.contains(morph)
            return engine.seenMorphBuilds != seen && engine.morphSources[morph] != nil
        }
        XCTAssertEqual(engine.morphSources[morph], source, "the morph never finished")
        // Models 2-4 at 10 frames per model: states 11 to 31 over the clip.
        let (track, length) = try morphTrack()
        XCTAssertGreaterThan(length, 1)
        XCTAssertEqual(track[1], 11, "track \(track), a poll saw it running: \(sawRunning)")
        XCTAssertEqual(track[length], 31, "track \(track), a poll saw it running: \(sawRunning)")
        print("MorphClipLiveTests: a poll saw the morph running: \(sawRunning)")
    }

    func testMissingMorphClipIsMarkedThenFilled() throws {
        makeSource()
        engine.clearMovieItems()
        var spec = PyMOLEngine.StatesSpec(objects: [morph], firstModel: 2, lastModel: 4)
        spec.morphStride = 10
        engine.timelineItems = [PyMOLEngine.TimelineItem(kind: .states(spec))]
        spin { !engine.statesClipMissing(spec).isEmpty
               && engine.objects.contains { $0.name == source }
               && engine.morphSources[morph] == nil }
        XCTAssertEqual(engine.statesClipMissing(spec), [morph])
        XCTAssertEqual(PyMOLEngine.statesClipMissingNote(spec, missing: [morph],
                                                         loaded: engine.objects.map(\.name)),
                       "not built · morph \(source) to fill")
        let seen = engine.seenMorphBuilds
        engine.fillMorphClip(spec)
        spin { engine.seenMorphBuilds != seen && engine.morphSources[morph] != nil }
        XCTAssertEqual(engine.morphSources[morph], source, "the morph never finished")
        let (track, length) = try morphTrack()
        XCTAssertEqual(track[1], 11, "track \(track)")
        XCTAssertEqual(track[length], 31, "track \(track)")
        XCTAssertEqual(engine.statesClipMissing(spec), [])
        guard case .states(let after) = engine.timelineItems.first?.kind else {
            return XCTFail("the clip is gone: \(engine.timelineItems)")
        }
        XCTAssertEqual(after.morphStride, 10)       // built at the clip's own stride
    }
}

/// The lane's view of clips whose objects are not loaded, through the engine:
/// two polls publish the missing object, a loaded object is never missing, and
/// a morph clip's "fill" action morphs its source at the clip's own stride into
/// the clip's object. Uses the live engine the unit-test host runs (the morph
/// call is read through `pythonTap`; its source does not exist in Python, so
/// the call fails there and builds nothing); restores what it changes.
final class MissingClipObjectTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var python: [String] = []
    private var savedItems: [PyMOLEngine.TimelineItem] = []
    private var savedObjects: [ObjectEntry] = []
    private var savedAbsent: Set<String> = []
    private var savedMissing: Set<String> = []
    private let morph = "t12b_src_morph"

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
        savedAbsent = engine.absentClipObjects
        savedMissing = engine.missingClipObjects
        engine.pythonTap = { [unowned self] in self.python.append($0) }
    }

    override func tearDown() {
        engine.pythonTap = nil
        engine.absentClipObjects = savedAbsent
        engine.missingClipObjects = savedMissing
        engine.objects = savedObjects
        engine.clearMovieItems()
        engine.timelineItems = savedItems
        super.tearDown()
    }

    private var clip: PyMOLEngine.StatesSpec {
        var spec = PyMOLEngine.StatesSpec(objects: [morph], firstModel: 1, lastModel: 0)
        spec.morphStride = 60
        return spec
    }

    func testTwoPollsMarkTheClipsObjectMissing() {
        engine.objects = [ObjectEntry(id: "obj_t12b_src", name: "t12b_src", isEnabled: true,
                                      isSelection: false, atomCount: nil, stateCount: 20)]
        engine.timelineItems = [PyMOLEngine.TimelineItem(kind: .states(clip))]
        engine.absentClipObjects = []
        engine.missingClipObjects = []
        engine.applyClipObjectPoll(loaded: ["t12b_src"])
        XCTAssertEqual(engine.statesClipMissing(clip), [])      // one poll is not enough
        engine.applyClipObjectPoll(loaded: ["t12b_src"])
        XCTAssertEqual(engine.missingClipObjects, [morph])
        XCTAssertEqual(engine.statesClipMissing(clip), [morph])
        // Loaded since (the panel's list already has it): not missing.
        engine.objects.append(ObjectEntry(id: "obj_\(morph)", name: morph, isEnabled: true,
                                          isSelection: false, atomCount: nil, stateCount: 1))
        XCTAssertEqual(engine.statesClipMissing(clip), [])
    }

    func testFillMorphsTheSourceAtTheClipsStride() {
        engine.objects = [ObjectEntry(id: "obj_t12b_src", name: "t12b_src", isEnabled: true,
                                      isSelection: false, atomCount: nil, stateCount: 20)]
        python.removeAll()
        engine.fillMorphClip(clip)
        let calls = python.filter { $0.contains("morph_object(") }
        XCTAssertEqual(calls.count, 1)
        let call = calls.first ?? ""
        XCTAssertTrue(call.contains("morph_object('t12b_src', name='\(morph)', "), call)
        XCTAssertTrue(call.contains("frames_per_model=60, loop=1,"), call)
        XCTAssertTrue(call.contains("reuse=0)"), call)
        // No loaded source: nothing to morph.
        engine.objects = []
        python.removeAll()
        engine.fillMorphClip(clip)
        XCTAssertFalse(python.contains { $0.contains("morph_object(") })
    }
}

/// Per-object players (a morph's auto-play, an object's Play) end when the session
/// they play is replaced, before the new one loads: a timer tick after the load
/// would send `set state` to a restored object of the same name and pin it there.
/// The Theme studio's restore puts back the very session it hid, so they keep
/// playing through it. Uses the live engine the unit-test host runs; the loads
/// name files that do not exist, and the test restores what it changes.
final class SessionReplaceStopsPlayersTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var savedItems: [PyMOLEngine.TimelineItem] = []
    private var savedUntracked = false

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
        savedUntracked = engine.untrackedMovie
    }

    override func tearDown() {
        engine.playingObjects = []
        engine.runPython("from pymol import cmd as _c\n_c.delete('t5ss_*')")
        engine.pendingTimelineAdd = nil
        engine.timelineItems = savedItems
        engine.untrackedMovie = savedUntracked
        super.tearDown()
    }

    /// Spins the run loop (the host's polls) until `done`, or `seconds`.
    private func spin(_ seconds: Double = 5, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// File > Open, drag-drop, Open With and a `load x.pse` typed in the console
    /// all run the load through runCommand, which stops the players first. A
    /// structure file joins the session, and a partial session load merges into
    /// it: the players go on.
    func testASessionLoadStopsPlayersFirst() {
        engine.playingObjects = ["t5ss_a"]
        engine.loadStructure(path: "/nonexistent-t5ss/t5ss_x.pdb", name: "t5ss_x")
        XCTAssertEqual(engine.playingObjects, ["t5ss_a"])
        engine.runCommand("load /nonexistent-t5ss/t5ss_x.pse, partial=1")
        XCTAssertEqual(engine.playingObjects, ["t5ss_a"])
        engine.loadStructure(path: "/nonexistent-t5ss/t5ss_x.pse", name: "t5ss_x")
        XCTAssertEqual(engine.playingObjects, [])
        engine.playingObjects = ["t5ss_a"]
        engine.runCommand("load /nonexistent-t5ss/t5ss_x.pse")
        XCTAssertEqual(engine.playingObjects, [])
    }

    /// Closing the Theme studio restores the session it snapshotted, which
    /// announces a restored Timeline like any session load. That restore keeps
    /// the players; any other announced one (a session loaded from MCP or a
    /// Python `cmd.load`, which never pass through runCommand) stops them.
    func testThemeStudioRestoreKeepsPlayers() {
        engine.runPython("from pymol import cmd as _c\n"
                         + "_c.fab('AGA', 't5ss_obj')\n_c.create('t5ss_obj', 't5ss_obj', 1, 2)")
        spin { engine.objects.contains { $0.name == "t5ss_obj" } }
        engine.playingObjects = ["t5ss_obj"]
        engine.beginThemePreview()
        engine.endThemePreview()
        XCTAssertTrue(engine.themeRestorePending)
        spin { !engine.themeRestorePending }
        spin(0.5) { false }                 // the main-queue work the lines queued
        XCTAssertFalse(engine.themeRestorePending, "the restore's lines were never read")
        XCTAssertEqual(engine.playingObjects, ["t5ss_obj"])
        engine.runPython("from pymol import appkit_movie as _am\n_am._emit_timeline([])")
        spin { engine.playingObjects.isEmpty }
        XCTAssertEqual(engine.playingObjects, [])
    }

    /// What appkit_movie's player registry holds now, read back through a file.
    private func pythonRegistry() -> [String]? {
        let path = NSTemporaryDirectory() + "t5ss_registry_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.runPython("import json\nfrom pymol import appkit_movie as _am\n"
                         + "open(\(InferenceJob.pythonLiteral(path)), 'w').write("
                         + "json.dumps(_am.playing_objects()))")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Close-out B: starting a player notes the object in appkit_movie once, not
    /// on every tick, so a session saved while it plays leaves out the pin its
    /// ticks set; stopping the player takes it out again. A re-time (fps change)
    /// stops and starts it.
    func testPlayerStartAndStopNoteThePythonRegistry() {
        engine.runPython("from pymol import cmd as _c\n"
                         + "_c.fab('AGA', 't5ss_reg')\n_c.create('t5ss_reg', 't5ss_reg', 1, 2)")
        spin { engine.objects.contains { $0.name == "t5ss_reg" && $0.stateCount > 1 } }
        var python: [String] = []
        engine.pythonTap = { python.append($0) }
        defer {
            engine.pythonTap = nil
            engine.stopObjectStates("t5ss_reg")
            engine.objectFPS["t5ss_reg"] = nil
        }
        engine.startObjectStates("t5ss_reg")
        XCTAssertEqual(engine.playingObjects, ["t5ss_reg"])
        spin(0.4) { false }                 // several ticks at 15 fps
        XCTAssertEqual(MorphEngineTests.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.note_object_playing('t5ss_reg', True)",
        ])
        XCTAssertEqual(pythonRegistry(), ["t5ss_reg"])

        python.removeAll()
        engine.setObjectFPS("t5ss_reg", 30)
        XCTAssertEqual(MorphEngineTests.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.note_object_playing('t5ss_reg', False)",
            "from pymol import appkit_movie as _am\n_am.note_object_playing('t5ss_reg', True)",
        ])
        XCTAssertEqual(pythonRegistry(), ["t5ss_reg"])

        python.removeAll()
        engine.stopObjectStates("t5ss_reg")
        XCTAssertEqual(MorphEngineTests.registryCalls(python), [
            "from pymol import appkit_movie as _am\n_am.note_object_playing('t5ss_reg', False)",
        ])
        XCTAssertEqual(pythonRegistry(), [])
    }

    /// The object-level `state` (the pin) `name` carries now, read back through
    /// a file: its value, "none" when it has none, nil when it could not be read.
    private func pythonPin(_ name: String) -> String? {
        let path = NSTemporaryDirectory() + "t5ss_pin_\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }
        engine.runPython("from pymol import cmd as _c, setting as _s\n"
                         + "_i = _s._get_index('state')\n"
                         + "_v = [v for i, t, v in (_c.get_object_settings("
                         + "\(InferenceJob.pythonLiteral(name))) or []) if i == _i]\n"
                         + "open(\(InferenceJob.pythonLiteral(path)), 'w').write("
                         + "str(_v[0]) if _v else 'none')")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Close-out B review: the Objects panel's rename of a playing object
    /// leaves no timer pin on it. `cmd.set_name` drops the pin the ticks left,
    /// and the rename stops the player at once: the new name here extends the
    /// old one, and PyMOL matches an unambiguous name prefix, so a tick of
    /// `set state, k, t5ss_ren` left running until the panel poll would pin
    /// `t5ss_ren2` again. Kept, that pin would freeze the object in every
    /// later save.
    func testRenamingAPlayingObjectLeavesNoTimerPin() {
        engine.runPython("from pymol import cmd as _c\n"
                         + "_c.fab('AGA', 't5ss_ren')\n_c.create('t5ss_ren', 't5ss_ren', 1, 2)")
        spin { engine.objects.contains { $0.name == "t5ss_ren" && $0.stateCount > 1 } }
        defer {
            engine.stopObjectStates("t5ss_ren")
            engine.objectFPS["t5ss_ren"] = nil
        }
        engine.startObjectStates("t5ss_ren")
        spin(0.4) { false }                 // several ticks at 15 fps
        let pinned = pythonPin("t5ss_ren")
        XCTAssertTrue(pinned == "1" || pinned == "2", "the ticks pin the object: \(String(describing: pinned))")

        engine.renameObject("t5ss_ren", to: "t5ss_ren2")
        XCTAssertEqual(pythonPin("t5ss_ren2"), "none")
        XCTAssertEqual(engine.playingObjects, [])
        XCTAssertEqual(pythonRegistry(), [])
        spin(0.4) { false }                 // a timer left running would tick here
        XCTAssertEqual(pythonPin("t5ss_ren2"), "none")
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
