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

    /// The object a Morph started from `card` writes (spec §5.2: Morph always
    /// rebuilds the source's morph object). The card passes it to `morph_object`
    /// as `name`, so the sheet's "creates …"/"rebuilds …" line, the capsule's
    /// running-job watch, auto-play and the job itself all name the same object.
    ///
    /// - A morph's own card (`card != source`): the card itself, rebuilt in place.
    /// - A source's card: `<source>_morph`, also when an object of that name is
    ///   already loaded. After a session reload Python has no job record for it
    ///   and, given no name, would build `<source>_morph2`, which the sheet never
    ///   mentioned; named, its explicit-name rule (the `<source>_morph` convention,
    ///   molecular objects only) rebuilds it in place. A group of that name, or a
    ///   morph known to belong to another source, is not this source's morph:
    ///   then Python's own fallback, the first `<source>_morphN` (N ≥ 2) that is
    ///   free or a known morph of this source.
    ///
    /// - Parameters:
    ///   - objects: names of the loaded objects (the panel's object list).
    ///   - groups: the names in `objects` that are groups.
    ///   - morphSources: completed morphs of this session, morph → source.
    static func morphTarget(card: String, source: String, objects: [String],
                            groups: Set<String>, morphSources: [String: String]) -> String {
        if card != source { return card }
        let base = morphName(for: source)
        let ours = !objects.contains(base)
            || (!groups.contains(base)
                && conventionalSource(of: base, existing: objects) == source
                && (morphSources[base] ?? source) == source)
        if ours { return base }
        var n = 2
        while true {
            let candidate = "\(base)\(n)"
            if !objects.contains(candidate) || morphSources[candidate] == source {
                return candidate
            }
            n += 1
        }
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
