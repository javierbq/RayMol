#if os(macOS) || os(iOS)
import Foundation

// MARK: - MorphSettings

/// Persistent user preferences for the Morph feature.
///
/// Designed to be a pure value type with no engine dependency so it can be
/// unit-tested without launching PyMOL.
struct MorphSettings: Codable, Equatable {

    // MARK: - Stored properties (all match the Python `morph_object` defaults)

    /// Number of interpolated frames inserted between each pair of source models.
    var framesPerModel: Int = 15       // 2...120
    /// Whether the morph plays as a loop (last model connects back to first).
    var loop: Bool = true
    /// Interpolation method passed to `morph_object`.  "rigimol" | "linear"
    var method: String = "rigimol"
    /// Number of sculpt-refinement passes per frame.  0...10
    var refinement: Int = 3
    /// Playback rate curve.  "linear" | "sinusoidal" | "ramp up" | "ramp down"
    var rate: String = "linear"
    /// Whether the Timeline's Play-models button shows smoothed (morph) playback.
    var movieSmooth: Bool = false

    // MARK: - Persistence

    static let defaultsKey = "raymol.morph.settings"

    /// Load from `defaults`, returning factory defaults if the key is absent or undecodable.
    static func load(_ defaults: UserDefaults = .standard) -> MorphSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(MorphSettings.self, from: data)
        else { return MorphSettings() }
        return settings
    }

    /// Persist to `defaults`.
    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Summary

    /// Quick preview of what a morph job will produce before the user starts it.
    struct Summary: Equatable {
        /// Number of model-to-model transitions (= models when looped, models-1 otherwise).
        let legs: Int
        /// Total rendered frames  =  `legs × framesPerModel`.
        let frames: Int
        /// Wall-clock length at the given frame rate.
        let seconds: Double
        /// Memory the finished morph holds: the frames times Python's bytes per
        /// frame. nil when Python has not published that figure.
        let bytes: Int?
        /// Rough time the app takes to build it, in seconds; 0 when the atom
        /// count is unknown. A hint only (spec §5.2), see `buildSeconds(…)`.
        let buildSeconds: Double
    }

    /// Estimate the output size and duration for a given molecule and frame rate.
    ///
    /// - Parameters:
    ///   - models: Number of states in the source object.
    ///   - atoms: Atom count of the source object (0 when unknown), for the build time.
    ///   - bytesPerFrame: `morph_jobs.bytes_per_frame` of the source, from the
    ///     panel payload's `morph_bytes_per_frame`: coordinates plus the
    ///     representations the source shows, overhead included. The same figure
    ///     `morph_estimate` multiplies, so the sheet and `morph_object` agree.
    ///   - fps: Display frame rate in frames per second.
    func summary(models: Int, atoms: Int, bytesPerFrame: Int?, fps: Double) -> Summary {
        let legs = loop ? models : models - 1
        let frames = legs * framesPerModel
        let seconds = Double(frames) / max(fps, 1)
        return Summary(legs: legs, frames: frames, seconds: seconds,
                       bytes: bytesPerFrame.map { frames * $0 },
                       buildSeconds: Self.buildSeconds(atoms: atoms, legs: legs, frames: frames,
                                                       refinement: refinement))
    }

    /// Seconds the app takes to build a morph, roughly (spec §5.2): 0.05 ms per
    /// atom per leg, plus per atom per frame 0.014 ms and 0.011 ms more per
    /// clean-up cycle. Measured headless at the app's cadence (`pump(100)` every
    /// 500 ms): 2kpo (1860 atoms) 300 frames took 8 s at 0 cycles and 32 s at 3,
    /// 1200 frames 117 s at 3, 45 frames 3.6 s at 3; 50k atoms × 45 frames 88 s
    /// at 3. This reads them within ±30 %. `morph_jobs.build_seconds` (Python's
    /// `morph_estimate['seconds']`) uses the same three constants.
    static func buildSeconds(atoms: Int, legs: Int, frames: Int, refinement: Int) -> Double {
        let perAtomFrame = 1.4e-5 + 1.1e-5 * Double(max(refinement, 0))
        return Double(atoms) * (Double(legs) * 0.05e-3 + Double(frames) * perAtomFrame)
    }

    // MARK: - Python command

    /// Build the two-line Python snippet that submits the job to `morph_jobs`.
    ///
    /// Every string argument goes through `InferenceJob.pythonLiteral` so that
    /// object names with apostrophes or backslashes never break the call.
    ///
    /// - Parameters:
    ///   - source: Name of the multi-state PyMOL object to morph.
    ///   - name: Desired name for the output morph object, or nil to let Python pick.
    ///   - reuse: When true, reuse an existing morph object in place.
    func pythonCall(source: String, name: String?, reuse: Bool = false) -> String {
        let srcLit = InferenceJob.pythonLiteral(source)
        let namePart: String
        if let n = name {
            namePart = "name=\(InferenceJob.pythonLiteral(n))"
        } else {
            namePart = "name=None"
        }
        let loopInt    = loop   ? 1 : 0
        let reuseInt   = reuse  ? 1 : 0
        let methLit    = InferenceJob.pythonLiteral(method)
        let rateLit    = InferenceJob.pythonLiteral(rate)
        return "from pymol import morph_jobs as _mj\n"
            + "_mj.morph_object(\(srcLit), \(namePart), "
            + "frames_per_model=\(framesPerModel), loop=\(loopInt), "
            + "method=\(methLit), refinement=\(refinement), "
            + "rate=\(rateLit), copy_look=1, async_=1, reuse=\(reuseInt))"
    }

    // MARK: - Name helpers

    /// Canonical morph-object name for a given source object.
    static func morphName(for source: String) -> String { source + "_morph" }

    /// Reverse: given a morph object name, return the source name when it
    /// follows the `<source>_morph` or `<source>_morphN` convention AND the
    /// inferred source is present in `existing`.
    ///
    /// Used during session restore (spec §5.9) to reconnect the morph sheet
    /// to its source without storing redundant state in the PSE.
    ///
    /// - Returns: The source name, or nil when `name` does not match the
    ///   pattern or the inferred source is absent from `existing`.
    static func conventionalSource(of name: String, existing: [String]) -> String? {
        guard let regex = conventionalName,
              let match = regex.firstMatch(
                  in: name,
                  range: NSRange(name.startIndex..., in: name)),
              let sourceRange = Range(match.range(at: 1), in: name)
        else { return nil }
        let source = String(name[sourceRange])
        return existing.contains(source) ? source : nil
    }

    /// `<source>_morph` optionally followed by digits, at the end of the name.
    /// Built once: the Object panel asks for every multi-state row it draws.
    private static let conventionalName = try? NSRegularExpression(pattern: #"^(.+)_morph(\d+)?$"#)

    /// The source a row's ⟳ badge and its "Morph of …" tooltip name: the
    /// registry's (`registry`, this app run's finished morphs), else the one the
    /// `<source>_morph` convention points at, so a morph a relaunch brought back
    /// reads as a morph, as its card's sheet already treats it (spec §5.9).
    static func badgeSource(registry: String?, name: String, existing: [String]) -> String? {
        registry ?? conventionalSource(of: name, existing: existing)
    }

    /// The object a Morph started from `card` writes, and whether its name is
    /// passed to `morph_object`. The sheet's "creates …"/"rebuilds …" line, the
    /// capsule's running-job watch, auto-play and the job all use this answer.
    ///
    /// - A morph's own card (`card != source`): the card itself, named, so a
    ///   re-morph rebuilds it in place.
    /// - A source's card, named only for a morph restored from a session: an
    ///   object `<source>_morph` that is not a known morph of this session
    ///   (`morphSources`) and is a multi-state molecule (`molecules`). Python has
    ///   no job record for it and, unnamed, would build `<source>_morph2`; named,
    ///   its explicit-name rule rebuilds it in place (spec §5.2). That rule takes
    ///   only a molecule: a group's or an alignment's name selects atoms, so it
    ///   reports states too, but naming it would be refused.
    /// - Otherwise no name: Python's registry decides (spec §5.1, `_morph2` only
    ///   when the name is taken by a non-morph), and this mirrors its choice:
    ///   the first of `<source>_morph`, `<source>_morph2`, … that is free or a
    ///   known morph of this source.
    ///
    /// A morph of this source still being built (`building`) counts as one of its
    /// known morphs: until its first leg lands it has one state and no finished
    /// record, so it would otherwise read as a user's molecule and send the answer
    /// on to `_morph2`, while Python's registry targets the running job.
    ///
    /// - Parameters:
    ///   - objects: the loaded objects (not selections), name → state count.
    ///   - groups: the names in `objects` that are groups.
    ///   - molecules: the multi-state molecules not being built: the keys of
    ///     `PyMOLEngine.morphBytesPerFrame`, which Python publishes only for those.
    ///   - morphSources: completed morphs of this session, morph → source.
    ///   - building: names of morph jobs queued or running.
    static func morphTarget(card: String, source: String, objects: [String: Int],
                            groups: Set<String>, molecules: Set<String>,
                            morphSources: [String: String],
                            building: Set<String> = []) -> (name: String, explicit: Bool) {
        if card != source { return (card, true) }
        var sources = morphSources
        for name in building where sources[name] == nil
            && conventionalSource(of: name, existing: [source]) == source {
            sources[name] = source
        }
        let base = morphName(for: source)
        if let states = objects[base], sources[base] == nil,
           !groups.contains(base), states > 1, molecules.contains(base) {
            return (base, true)
        }
        var candidate = base
        var n = 2
        while objects[candidate] != nil && sources[candidate] != source {
            candidate = "\(base)\(n)"
            n += 1
        }
        return (candidate, false)
    }

    // MARK: - Formatting

    /// Whole numbers without a decimal ("10"), anything else to one place ("6.7"):
    /// seconds and fps in the sheets' summary lines.
    static func number(_ x: Double) -> String {
        abs(x - x.rounded()) < 0.05 ? String(Int(x.rounded())) : String(format: "%.1f", x)
    }

    /// A memory estimate in the sheets: "< 1 MB", "≈ 29 MB", "≈ 1.2 GB".
    static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1e6
        if mb < 1 { return "< 1 MB" }
        if mb < 1000 { return "≈ \(Int(mb.rounded())) MB" }
        return String(format: "≈ %.1f GB", mb / 1000)
    }
}

// MARK: - Decoding

extension MorphSettings {
    /// Each key on its own: a key the saved JSON lacks (one a later build adds,
    /// or `movieSmooth` in a save older than it) or cannot read takes its
    /// default, and the others keep what was saved. The synthesized decoder
    /// threw on the first missing key, and `load()` then dropped every saved
    /// value. Encoding stays synthesized (every key). In an extension, so the
    /// memberwise and `MorphSettings()` initializers remain.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        framesPerModel = value(.framesPerModel, framesPerModel)
        loop = value(.loop, loop)
        method = value(.method, method)
        refinement = value(.refinement, refinement)
        rate = value(.rate, rate)
        movieSmooth = value(.movieSmooth, movieSmooth)
    }
}

// MARK: - MorphMovie

/// The Movie tab's "Smooth transitions (morph)" toggle in the Play-models sheet
/// (spec §5.7): when it can be used, what the line under it says, the Duration it
/// implies, and what Add does. Pure, so the sheet only wires it.
enum MorphMovie {

    /// Whether the toggle can be used for the sheet's target, and why not.
    enum Availability: Equatable {
        case available
        case unavailable(reason: String)
    }

    /// Off for "all models" (`target == nil`): a morph is built from one object.
    /// Off for a target that is already a morph: a completed morph of this session
    /// (`morphSources`), one still being built (`building`, not yet in
    /// `morphSources`), or one a session reload brought back, recognised by the
    /// `<source>_morph` convention as the Object panel does (spec §5.9). Smoothing a
    /// morph would morph every one of its frames.
    ///
    /// - Parameters:
    ///   - objects: the loaded objects (not selections), name → state count.
    ///   - building: names of morph jobs queued or running.
    static func availability(target: String?, objects: [String: Int],
                             morphSources: [String: String],
                             building: Set<String>) -> Availability {
        guard let t = target else { return .unavailable(reason: "Pick one object to smooth") }
        if morphSources[t] != nil || building.contains(t)
            || MorphSettings.conventionalSource(of: t, existing: Array(objects.keys)) != nil {
            return .unavailable(reason: "Already a smooth morph")
        }
        return .available
    }

    /// The object a smooth clip of `source` plays, and whether its name is passed
    /// to `morph_object`: the Object panel's resolver for the source's own card
    /// (MorphSettings.morphTarget), a morph of this source still being built
    /// counting as its morph.
    static func target(source: String, objects: [String: Int], groups: Set<String>,
                       molecules: Set<String>, morphSources: [String: String],
                       building: Set<String>) -> (name: String, explicit: Bool) {
        MorphSettings.morphTarget(card: source, source: source, objects: objects,
                                  groups: groups, molecules: molecules,
                                  morphSources: morphSources, building: building)
    }

    /// Length of the smooth clip at its natural speed: the morph's frames (a
    /// loop, so models × frames per model) at the movie rate, to 0.1 s.
    static func naturalSeconds(models: Int, framesPerModel: Int, fps: Double) -> Double {
        let s = MorphClipMapping.naturalSeconds(models: models, stride: framesPerModel,
                                                loop: true, fps: fps)
        return (s * 10).rounded() / 10
    }

    /// The Duration stepper's range without smoothing.
    static let plainDurationRange: ClosedRange<Double> = 1...30

    /// The Duration stepper's range: 1…30 s, widened while smoothing to
    /// 1…max(30, ⌈natural⌉) so a long morph's natural length (40 s at 60 frames
    /// per model) can be shown and kept.
    static func durationRange(smooth: Bool, natural: Double) -> ClosedRange<Double> {
        smooth ? 1...max(plainDurationRange.upperBound, natural.rounded(.up))
               : plainDurationRange
    }

    /// Duration after the toggle or frames per model changed: the natural length
    /// while smoothing, unless the user has edited Duration since the sheet opened;
    /// with smoothing off and Duration unedited, the value the sheet opened with
    /// (`opening`, when given: the toggle had overwritten it with the natural
    /// length); otherwise the current value. Kept inside the stepper's range,
    /// which shrinks when smoothing turns off or frames per model drops.
    static func duration(current: Double, smooth: Bool, edited: Bool,
                         natural: Double, opening: Double? = nil) -> Double {
        let range = durationRange(smooth: smooth, natural: natural)
        let d: Double
        if edited {
            d = current
        } else if smooth {
            d = natural
        } else {
            d = opening ?? current
        }
        return min(max(d, range.lowerBound), range.upperBound)
    }

    /// The line under the toggle: "Builds 2kpo_morph (20 models × 15 frames) and
    /// plays that instead · 10 s at 30 fps" while on, followed by `memory` (the
    /// estimate, `memoryNote`'s text) when given; why Add waits while the morph
    /// it would name is still being built (`waitsFor`, AddPlan); the reason
    /// while unavailable; nothing while off. `target` is the resolved morph name.
    static func caption(_ availability: Availability, smooth: Bool, target: String,
                        models: Int, framesPerModel: Int, fps: Double,
                        memory: String? = nil, waitsFor: String? = nil) -> String? {
        switch availability {
        case .unavailable(let reason):
            return reason
        case .available:
            guard smooth else { return nil }
            if let waitsFor { return "\(waitsFor) is still being built · Add once it is done" }
            let s = naturalSeconds(models: models, framesPerModel: framesPerModel, fps: fps)
            let line = "Builds \(target) (\(models) models × \(framesPerModel) frames) "
                + "and plays that instead · \(MorphSettings.number(s)) s at "
                + "\(MorphSettings.number(max(fps, 1))) fps"
            return memory.map { "\(line) · \($0)" } ?? line
        }
    }

    /// Memory the smooth clip's morph would hold: its frames (a loop, so models ×
    /// frames per model) times Python's bytes per frame of the source (the panel
    /// payload's `morph_bytes_per_frame`), as `morph_estimate` computes it; nil
    /// without that figure.
    static func estimatedBytes(models: Int, framesPerModel: Int, bytesPerFrame: Int?) -> Int? {
        var loop = MorphSettings()
        loop.framesPerModel = framesPerModel
        loop.loop = true
        return loop.summary(models: models, atoms: 0, bytesPerFrame: bytesPerFrame, fps: 1).bytes
    }

    /// The caption's memory part and its tier against `thresholds` (spec §5.6,
    /// as the Morph sheet judges it): "≈ 412 MB", with the remedy appended above
    /// the refuse threshold ("≈ 3.5 GB · reduce frames per model"). No text and
    /// `.ok` while the estimate is unknown. A morph Python will not size up
    /// (`sized` false, see `sizesMorph`) shows its size alone, at `.ok`: Python
    /// refuses nothing it does not build, so neither the remedy nor a disabled
    /// Add would be true.
    static func memoryNote(bytes: Int?, thresholds: (warn: Double, refuse: Double),
                           sized: Bool = true)
        -> (text: String?, tier: MorphSheet.MemoryTier) {
        guard let bytes else { return (nil, .ok) }
        let size = MorphSettings.megabytes(bytes)
        guard sized else { return (size, .ok) }
        let tier = MorphSheet.memoryTier(bytes: bytes, thresholds: thresholds)
        return (tier == .refuse ? "\(size) · reduce frames per model" : size, tier)
    }

    /// Whether Add may run: not for a smooth clip whose morph Python would refuse
    /// for its size, which would leave a clip naming an object that never
    /// appears, nor while the morph it would name is still being built
    /// (`waitsFor`, AddPlan). A plain clip, or a smooth one under the limit, can
    /// be added.
    static func canAdd(smoothOn: Bool, tier: MorphSheet.MemoryTier,
                       waitsFor: String? = nil) -> Bool {
        !(smoothOn && (tier == .refuse || waitsFor != nil))
    }

    /// Whether Python sizes up the morph Add would ask for (spec §5.6): only one
    /// it builds. Not when Add submits no job (`plan.morph` nil: a plain clip, or
    /// Add waits for that morph's build), nor for a reuse: `morph_object` keeps a
    /// finished morph whose source and spec match the ones sent before it
    /// estimates anything (spec §5.2), as the registry's `morphSources` and
    /// `morphSpecs` show here. Python also compares the source's fingerprint:
    /// an edited source is rebuilt, and refused when too large, which leaves its
    /// clip naming the old morph and a refusal card in the tray. On iOS this is
    /// reachable: the finished morph's own memory lowers the available-memory
    /// thresholds that it passed when it was built.
    static func sizesMorph(_ plan: AddPlan, morphSources: [String: String],
                           morphSpecs: [String: MorphSettings]) -> Bool {
        guard let call = plan.morph else { return false }
        guard morphSources[call.target] == call.source,
              var built = morphSpecs[call.target] else { return true }
        built.movieSmooth = call.settings.movieSmooth   // the sheet's, not the job's
        return built != call.settings
    }

    /// What Add does.
    struct AddPlan: Equatable {
        /// The morph job to submit before the clip (`engine.morph(…, autoPlay: false,
        /// reuse: true)`: Python keeps an existing morph whose spec and source
        /// fingerprint match, spec §5.2).
        struct MorphCall: Equatable {
            let source: String
            /// Passed to `morph_object` only when the resolver says so.
            let name: String?
            /// The object the job writes.
            let target: String
            /// Loop forced on: the Movie path implies it (spec §5.7).
            let settings: MorphSettings
        }
        /// nil for a plain clip, and while Add waits (`waitsFor`).
        let morph: MorphCall?
        /// The clip's objects (nil = all multi-state objects).
        let objects: [String]?
        /// Set for a smooth clip: Start/End are model indices, remapped to the
        /// morph's states at each rebuild.
        let morphStride: Int?
        /// The settings to persist (the toggle remembers on and off), or nil to leave
        /// them alone when the toggle could not be used.
        let save: MorphSettings?
        /// The morph a smooth Add would name while it is still being built: Add
        /// waits (canAdd). Python refuses a second job on it, and the running one
        /// may not be what the sheet asks for (an Object-panel morph with Loop off,
        /// another rate). Once it is done, Add's reuse keeps it if it matches and
        /// rebuilds it otherwise (spec §5.2).
        var waitsFor: String? = nil
    }

    static func addPlan(target: String?, smooth: Bool, settings: MorphSettings,
                        objects: [String: Int], groups: Set<String>,
                        molecules: Set<String>, morphSources: [String: String],
                        building: Set<String>) -> AddPlan {
        guard let source = target,
              availability(target: source, objects: objects, morphSources: morphSources,
                           building: building) == .available
        else {
            return AddPlan(morph: nil, objects: target.map { [$0] }, morphStride: nil, save: nil)
        }
        var saved = settings
        saved.movieSmooth = smooth
        guard smooth else {
            return AddPlan(morph: nil, objects: [source], morphStride: nil, save: saved)
        }
        let resolved = Self.target(source: source, objects: objects, groups: groups,
                                   molecules: molecules, morphSources: morphSources,
                                   building: building)
        if building.contains(resolved.name) {
            return AddPlan(morph: nil, objects: [resolved.name],
                           morphStride: settings.framesPerModel, save: saved,
                           waitsFor: resolved.name)
        }
        var sent = settings
        sent.loop = true
        let call = AddPlan.MorphCall(source: source,
                                     name: resolved.explicit ? resolved.name : nil,
                                     target: resolved.name, settings: sent)
        return AddPlan(morph: call, objects: [resolved.name],
                       morphStride: settings.framesPerModel, save: saved)
    }
}

// MARK: - MorphClipMapping

/// Maps logical model indices (1…N) to absolute PyMOL movie frame numbers.
///
/// PyMOL's `mview` / clip commands operate on absolute frame numbers.
/// A morph object with N models and F frames per model occupies frames
/// `[1, 1 + (N-1)·F]`; model k starts at `1 + (k-1)·F`.
enum MorphClipMapping {

    /// Convert a (firstModel, lastModel) window into absolute frame numbers.
    ///
    /// Input clamping (applied before the mapping):
    ///  - `firstModel` is clamped to `1...models`
    ///  - `lastModel == 0` is treated as `models` (convention: 0 means "end")
    ///  - `lastModel` is then clamped to `firstModel...models`
    ///
    /// When the result spans the entire object (first == 1 && last == models
    /// after clamping) the function returns `(1, 0)`, which PyMOL interprets
    /// as "no restriction" — the caller should omit clip arguments entirely.
    ///
    /// - Parameters:
    ///   - firstModel: First model to include (1-based).
    ///   - lastModel: Last model to include (1-based); 0 means "last model".
    ///   - models: Total number of models in the morph object.
    ///   - stride: Frames per model (`framesPerModel`).
    static func absoluteRange(
        firstModel: Int, lastModel: Int, models: Int, stride: Int
    ) -> (first: Int, last: Int) {
        let clampedFirst = max(1, min(firstModel, models))
        let resolvedLast = lastModel == 0 ? models : lastModel
        let clampedLast  = max(clampedFirst, min(resolvedLast, models))

        // Full range → sentinel (1, 0): no clip needed.
        if clampedFirst == 1 && clampedLast == models { return (1, 0) }

        return (1 + (clampedFirst - 1) * stride,
                1 + (clampedLast  - 1) * stride)
    }

    /// Wall-clock duration of a complete morph playback at a given frame rate.
    ///
    /// Guards against fps ≤ 0 (returns a finite value rather than infinity/NaN).
    static func naturalSeconds(models: Int, stride: Int, loop: Bool, fps: Double) -> Double {
        let legs = loop ? models : models - 1
        return Double(legs * stride) / max(fps, 1)
    }
}

// MARK: - MorphCompletion

/// Post-job completion routing rules.
enum MorphCompletion {

    /// Whether the morph object should begin playing immediately after the job lands.
    ///
    /// Auto-play is suppressed in Timeline mode because the Timeline drives
    /// playback itself; the object would fight with its own timeline track.
    static func shouldAutoPlay(requested: Bool, timelineMode: Bool) -> Bool {
        requested && !timelineMode
    }
}
#endif
