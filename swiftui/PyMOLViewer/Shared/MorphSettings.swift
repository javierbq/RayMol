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
        /// Conservative RAM estimate (×1.1 overhead factor).
        let bytes: Int
    }

    /// Estimate the output size and duration for a given molecule and frame rate.
    ///
    /// - Parameters:
    ///   - models: Number of states in the source object.
    ///   - atoms: Atom count of the source object.
    ///   - fps: Display frame rate in frames per second.
    ///   - repCostPerAtom: Per-atom representation cost in bytes (default 36).
    func summary(models: Int, atoms: Int, fps: Double, repCostPerAtom: Int = 36) -> Summary {
        let legs = loop ? models : models - 1
        let frames = legs * framesPerModel
        let seconds = Double(frames) / max(fps, 1)
        let bytes = Int(Double(atoms * frames * (12 + repCostPerAtom)) * 1.1)
        return Summary(legs: legs, frames: frames, seconds: seconds, bytes: bytes)
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
        // Pattern: <source>_morph optionally followed by one or more digits, at end of string.
        guard let regex = try? NSRegularExpression(pattern: #"^(.+)_morph(\d+)?$"#),
              let match = regex.firstMatch(
                  in: name,
                  range: NSRange(name.startIndex..., in: name)),
              let sourceRange = Range(match.range(at: 1), in: name)
        else { return nil }
        let source = String(name[sourceRange])
        return existing.contains(source) ? source : nil
    }

    /// The object a Morph started from `card` writes, and whether its name is
    /// passed to `morph_object`. The sheet's "creates …"/"rebuilds …" line, the
    /// capsule's running-job watch, auto-play and the job all use this answer.
    ///
    /// - A morph's own card (`card != source`): the card itself, named, so a
    ///   re-morph rebuilds it in place.
    /// - A source's card, named only for a morph restored from a session: an
    ///   object `<source>_morph` that is not a known morph of this session
    ///   (`morphSources`), not a group, and has more than one state. Python has no
    ///   job record for it and, unnamed, would build `<source>_morph2`; named, its
    ///   explicit-name rule rebuilds it in place (spec §5.2).
    /// - Otherwise no name: Python's registry decides (spec §5.1, `_morph2` only
    ///   when the name is taken by a non-morph), and this mirrors its choice:
    ///   the first of `<source>_morph`, `<source>_morph2`, … that is free or a
    ///   known morph of this source.
    ///
    /// - Parameters:
    ///   - objects: the loaded objects (not selections), name → state count.
    ///   - groups: the names in `objects` that are groups.
    ///   - morphSources: completed morphs of this session, morph → source.
    static func morphTarget(card: String, source: String, objects: [String: Int],
                            groups: Set<String>,
                            morphSources: [String: String]) -> (name: String, explicit: Bool) {
        if card != source { return (card, true) }
        let base = morphName(for: source)
        if let states = objects[base], morphSources[base] == nil,
           !groups.contains(base), states > 1 {
            return (base, true)
        }
        var candidate = base
        var n = 2
        while objects[candidate] != nil && morphSources[candidate] != source {
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
    /// to `morph_object`: the Object panel's resolver (MorphSettings.morphTarget),
    /// except that a morph of this source still being built counts as its morph.
    /// Such an object has one state and no completed record yet, so the resolver
    /// alone would take it for a user's molecule and answer `<source>_morph2`,
    /// while Python's registry targets the running job.
    static func target(source: String, objects: [String: Int], groups: Set<String>,
                       morphSources: [String: String],
                       building: Set<String>) -> (name: String, explicit: Bool) {
        var sources = morphSources
        for name in building where sources[name] == nil
            && MorphSettings.conventionalSource(of: name, existing: [source]) == source {
            sources[name] = source
        }
        return MorphSettings.morphTarget(card: source, source: source, objects: objects,
                                         groups: groups, morphSources: sources)
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
    /// otherwise the current value. Kept inside the stepper's range, which shrinks
    /// when smoothing turns off or frames per model drops.
    static func duration(current: Double, smooth: Bool, edited: Bool,
                         natural: Double) -> Double {
        let range = durationRange(smooth: smooth, natural: natural)
        let d = smooth && !edited ? natural : current
        return min(max(d, range.lowerBound), range.upperBound)
    }

    /// The line under the toggle: "Builds 2kpo_morph (20 models × 15 frames) and
    /// plays that instead · 10 s at 30 fps" while on, the reason while unavailable,
    /// nothing while off. `target` is the resolved morph name.
    static func caption(_ availability: Availability, smooth: Bool, target: String,
                        models: Int, framesPerModel: Int, fps: Double) -> String? {
        switch availability {
        case .unavailable(let reason):
            return reason
        case .available:
            guard smooth else { return nil }
            let s = naturalSeconds(models: models, framesPerModel: framesPerModel, fps: fps)
            return "Builds \(target) (\(models) models × \(framesPerModel) frames) "
                + "and plays that instead · \(MorphSettings.number(s)) s at "
                + "\(MorphSettings.number(max(fps, 1))) fps"
        }
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
        /// nil for a plain clip, and when this morph is already being built: Python
        /// would refuse a second job, and the clip naming it is rebuilt when it
        /// completes.
        let morph: MorphCall?
        /// The clip's objects (nil = all multi-state objects).
        let objects: [String]?
        /// Set for a smooth clip: Start/End are model indices, remapped to the
        /// morph's states at each rebuild.
        let morphStride: Int?
        /// The settings to persist (the toggle remembers on and off), or nil to leave
        /// them alone when the toggle could not be used.
        let save: MorphSettings?
    }

    static func addPlan(target: String?, smooth: Bool, settings: MorphSettings,
                        objects: [String: Int], groups: Set<String>,
                        morphSources: [String: String],
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
                                   morphSources: morphSources, building: building)
        var sent = settings
        sent.loop = true
        let call = building.contains(resolved.name) ? nil
            : AddPlan.MorphCall(source: source, name: resolved.explicit ? resolved.name : nil,
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
