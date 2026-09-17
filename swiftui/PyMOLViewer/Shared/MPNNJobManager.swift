#if os(macOS) && RAYMOL_MPNN
import Foundation
import MPNNKit

/// Runs the `mpnn` runtime: sequence design behind a RayMol command (#453).
///
/// **Nothing here is a second implementation of ProteinMPNN.** Design mode has run
/// `MPNNModel.design` and `MPNNModel.score` in process since Phase 2a; this manager gives
/// the same two calls a job shell, so the console and the drawer can reach them and their
/// results can land in a set. The per-residue numbers come back through ``DesignColor``,
/// which is the same code the live panel colours from — so a stored array colours the way
/// the panel did, rather than the way a second derivation of it happened to.
///
/// What is method-specific, and therefore here rather than in ``InferenceJob``:
///
/// * **The input is a BACKBONE, by path.** `Request.backbonePath` names a JSON in the
///   shape `raymol_design.enumerate_design_residues` writes, and it is parsed by
///   ``DesignResidueSet/parse(jsonAt:)`` — the parser Design mode already uses. One
///   parser, because `fixedPositions` and every returned array are positions in that
///   array, and two decoders is two chances to disagree about which residue is index 7.
/// * **The output is N results, not one structure.** A job samples `nSequences` sequences
///   from one encoder pass, and writes them as a JSON document at `outPath` (see
///   ``composeResult(backbone:samples:fixed:elapsed:)``). `metricsPath` is deliberately unused:
///   a metrics document describes one object, and this job produces neither.
/// * **The weights are BUNDLED.** `MPNNGate.packURL`, not `request.weightsDir` — the pack
///   is a resource of the app, so no run can be gated on a download and `weights_dir`
///   arrives empty.
/// * **The model cache is this manager's own.** `PyMOLEngine.loadedMPNNModel()` is
///   documented as belonging to `DesignController.inferenceQueue` alone; reaching into it
///   from this queue would be a data race on an `MPNNModel?`.
/// * **Cancellation is a poll BETWEEN SEQUENCES.** `design` is one synchronous forward
///   pass with no cancellation point inside it, so the worst case is one sample —
///   sub-second on the sizes Design mode runs interactively.
final class MPNNJobManager: InferenceRuntime {

    static let shared = MPNNJobManager()

    /// The runtime this manager implements, as it appears on the wire. Kept in step with
    /// `pymol.designers.mpnn.RUNTIME` and with what `PyMOLBridge` advertises in
    /// `RAYMOL_PREDICT_RUNTIMES`.
    static let runtimeName = "mpnn"

    /// The Python surface that owns this runtime's pending table and its delivery.
    /// NOT `designing`: a designed sequence has no object, so it shares no table with a
    /// generated backbone — see `designing_sequences.py`'s module docstring.
    static let pythonModule = "designing_sequences"

    /// Ceiling on sequences per job, matching `pymol.designers.mpnn.MAX_SEQUENCES`.
    /// Checked on both sides for the reason every other bound is: the Python one is the
    /// friendly refusal and this one is the contract.
    static let maxSequences = 32

    /// MLX must never run on the main thread; the marker arrives ON it. Serial, so two
    /// jobs cannot both hold the peak transient.
    ///
    /// Nothing here consults `DesignSizeGuard`: its `evaluate` returns `.ok`
    /// unconditionally off iOS, and this manager is macOS-only, so it would refuse
    /// nothing. The size bound that does apply is `pymol.designers.mpnn.MAX_RESIDUES`,
    /// which says so out loud.
    private let queue = DispatchQueue(label: "io.raymol.design.mpnn", qos: .userInitiated)
    /// Guards `cancelled`, which the design thread reads and the main thread writes.
    private let stateQueue = DispatchQueue(label: "io.raymol.design.mpnn.state")
    private var cancelled = Set<String>()

    /// The loaded pack. One entry, keyed by pack path, so a batch of a thousand backbones
    /// reads it once. Touched only from `queue`.
    private var loaded: [String: MPNNModel] = [:]

    private init() {}

    /// Test seam, matching the other managers'. UNGATED, like those: a `#if DEBUG` here
    /// would not compile against a Release app host.
    var cancelRequestedForTesting: Set<String> { stateQueue.sync { cancelled } }

    // MARK: Injected inference

    /// Returns the designed ALPHABET INDICES, which is all `run` reads off a
    /// `DesignResult` -- and the only part of one a test can build, since
    /// `MPNNModel.DesignResult` has no public initialiser.
    typealias DesignFn =
        ([MPNNModel.Residue], MPNNModel.DesignOptions) throws -> [Int]
    typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult

    /// The two model calls, injectable. Nil means "load the bundled pack and use it",
    /// which is every real run.
    ///
    /// Injection rather than a mock object, matching `DesignController`'s
    /// `designRegionFn` / `scoreFn`, and for the same reason: `run` is where the seed
    /// derivation, the `fixedPositions` remap, the `omit` mapping, the cancel poll and
    /// the write → `loadResult` → `report("done")` ordering all live, and every one of
    /// them is otherwise reachable only through a 100 MB pack and a GPU. With these, a
    /// test drives a real backbone file through the real `run` to a real document.
    ///
    /// Set on the shared instance, so a test must clear them in `tearDown`.
    var designFn: DesignFn?
    var scoreFn: ScoreFn?

    /// Run a request on THIS thread, for tests. `submit` hops to `queue`, which a test
    /// would then have to wait on; there is nothing about the queue hop under test.
    func runForTesting(_ request: InferenceJob.Request) {
        run(request)
    }

    // MARK: InferenceRuntime

    func submit(_ request: InferenceJob.Request) {
        if let failure = Self.preflight(request) {
            InferenceJob.settle(request, failure,
                                to: URL(fileURLWithPath: request.statusPath),
                                pythonModule: Self.pythonModule)
            return
        }
        queue.async { self.run(request) }
    }

    func cancel(jobID: String) {
        stateQueue.sync {
            guard !InferenceJob.hasTerminalStatus(jobID: jobID) else { return }
            cancelled.insert(jobID)
        }
    }

    /// Refuse on what the request alone says, before allocating anything.
    ///
    /// Every check is one the model would NOT make. `MPNNModel.design` on an empty residue
    /// array throws, but on a backbone whose every position is fixed it returns the native
    /// sequence back — a result that looks like a design and is not one — and the Python
    /// side's `require_designable` refuses that first. Reaching any of these is a skew
    /// rather than a user error, which is exactly why it is checked twice.
    static func preflight(_ request: InferenceJob.Request) -> InferenceJob.Status? {
        guard request.runtime == runtimeName else {
            return InferenceJob.refusal(
                "this request is for the '\(request.runtime ?? "boltz")' runtime, not"
                + " '\(runtimeName)'")
        }
        guard let path = request.backbonePath, !path.isEmpty else {
            return InferenceJob.refusal(
                "a sequence design needs a backbone, and this request carries none")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return InferenceJob.refusal("the backbone file \(path) is not there")
        }
        let count = request.nSequences ?? 1
        guard count >= 1, count <= maxSequences else {
            return InferenceJob.refusal(
                "n_sequences must be between 1 and \(maxSequences), got \(count)")
        }
        guard MPNNGate.packURL != nil else {
            return InferenceJob.refusal(
                "the ProteinMPNN model pack is missing from this build")
        }
        return nil
    }

    // MARK: Design

    private func run(_ request: InferenceJob.Request) {
        let statusURL = URL(fileURLWithPath: request.statusPath)
        var elapsed: Double? = nil
        let throttle = InferenceJob.StepThrottle()

        func report(_ state: String, _ phase: String, _ fraction: Double,
                    error: String? = nil, result: String? = nil,
                    step: Int? = nil, totalSteps: Int? = nil) {
            var status = InferenceJob.Status(
                state: state, phase: phase, fraction: fraction, error: error,
                resultPath: result, peakBytes: nil, elapsedSeconds: elapsed)
            status.step = step
            status.totalSteps = totalSteps
            try? InferenceJob.writeStatus(status, to: statusURL)
        }
        func isCancelled() -> Bool {
            stateQueue.sync { cancelled.contains(request.jobID) }
        }
        func settle(_ status: InferenceJob.Status) {
            InferenceJob.settle(request, status, to: statusURL,
                                pythonModule: Self.pythonModule)
        }

        // BEFORE any work. A campaign submits one job per backbone and this queue is
        // SERIAL, so most of a thousand sit here; a cancel of the batch must drop each of
        // them without reading a backbone it will never design against.
        if isCancelled() {
            settle(cancelledStatus(phase: "queued")); return
        }
        guard let backbonePath = request.backbonePath else {
            settle(InferenceJob.refusal("malformed sequence-design request")); return
        }

        let started = Date()
        do {
            // Must precede any MLX allocation: sets the buffer-cache ceiling that Design
            // mode established, and in a simulator switches MLX to the CPU backend.
            MPNNRuntime.configureOnce()
            let backbone = try DesignResidueSet.parse(
                jsonAt: URL(fileURLWithPath: backbonePath))
            let residues = backbone.validResidues
            guard !residues.isEmpty else {
                settle(InferenceJob.refusal(
                    "the backbone has no residue with all of N, CA, C and O"))
                return
            }
            let native = backbone.nativeSequence
            // The pack is read only when it is going to be used: an injected run must not
            // need 100 MB of weights on disk to exercise this function.
            let model = (designFn == nil || scoreFn == nil) ? try loadedModel() : nil
            let design = designFn ?? { residues, options in
                try MPNNRuntime.withMLXErrorsAsThrows {
                    try model!.design(residues, options: options).indices
                }
            }
            let score = scoreFn ?? { residues, sequence in
                try MPNNRuntime.withMLXErrorsAsThrows {
                    try model!.score(residues, sequence: sequence, mode: .leaveOneOut,
                                     seed: 0)
                }
            }

            var options = MPNNModel.DesignOptions()
            options.temperature = Float(request.temperature ?? 0.1)
            options.nativeSequence = native
            // POSITIONS in the FULL residue array on the wire, but `fixedPositions` is
            // resolved against the array actually handed to the model -- which excludes
            // residues with no backbone. Mapped here rather than on the Python side,
            // because only this side knows which residues survived `validResidues`.
            options.fixedPositions = Self.fixedInValidOrder(
                wire: request.fixedPositions ?? [], backbone: backbone)
            if let omit = request.omit, !omit.isEmpty {
                let banned = Set(omit.compactMap { letter in
                    MPNNModel.alphabet.firstIndex(of: letter)
                })
                options.omit = Array(repeating: banned, count: residues.count)
            }

            let count = request.nSequences ?? 1
            var samples: [Sample] = []
            for index in 0..<count {
                if isCancelled() {
                    settle(cancelledStatus(phase: "design")); return
                }
                // A DISTINCT seed per sample, derived from the one seed the request
                // carries, or every sample of a run would be the same draw. Derived
                // rather than random so the whole set is reproducible from `seed=N`.
                options.seed = request.seed &+ UInt64(index)
                let designed = try design(residues, options)
                // Scored leave-one-out against the sequence just designed, which is what
                // makes `native_fit` a statement about THIS sequence on THIS backbone.
                let scored = try score(residues, designed)
                samples.append(Sample(
                    number: index + 1, seed: options.seed ?? 0,
                    temperature: Double(options.temperature),
                    indices: designed,
                    scores: DesignColor.scores(from: scored,
                                               validMask: backbone.residues.map(\.valid))))
                let fraction = Double(index + 1) / Double(count)
                if throttle.shouldEmit(stage: "design", fraction: fraction,
                                       isFinal: index + 1 >= count,
                                       now: ProcessInfo.processInfo.systemUptime) {
                    report("running", "design", fraction, step: index + 1,
                           totalSteps: count)
                }
            }
            elapsed = Date().timeIntervalSince(started)

            let document = Self.composeResult(backbone: backbone, samples: samples,
                                              fixed: options.fixedPositions,
                                              elapsed: elapsed ?? 0)
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: request.outPath), options: .atomic)
            // Hands the document to Python, which turns it into entries or into metric
            // runs. `loadResult` is shared with every other runtime -- what differs is
            // only which module's `deliver_result` it names.
            InferenceJob.loadResult(request, pythonModule: Self.pythonModule)
            report("done", "done", 1.0, result: request.outPath)
        } catch {
            elapsed = Date().timeIntervalSince(started)
            // `String(describing:)` rather than `localizedDescription`, as the other
            // managers use: MPNNInputError is a plain enum and its localized description
            // is the useless "The operation couldn't be completed".
            settle(InferenceJob.Status(
                state: "failed", phase: "design", fraction: 0,
                error: String(describing: error), resultPath: nil, peakBytes: nil,
                elapsedSeconds: elapsed))
        }
    }

    private func cancelledStatus(phase: String) -> InferenceJob.Status {
        InferenceJob.Status(state: "cancelled", phase: phase, fraction: 0, error: nil,
                            resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
    }

    /// The bundled pack, loaded once. Its own cache rather than the engine's, for the
    /// reason given on the type: `PyMOLEngine._mpnnModel` belongs to Design mode's queue.
    private func loadedModel() throws -> MPNNModel {
        guard let url = MPNNGate.packURL else {
            throw NSError(domain: "raymol.design.mpnn", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "MPNN model pack not found in bundle."])
        }
        if let cached = loaded[url.path] { return cached }
        let model = try MPNNRuntime.withMLXErrorsAsThrows {
            try MPNNModel(packDirectory: url)
        }
        loaded = [url.path: model]
        return model
    }

    // MARK: The result document

    /// One sampled sequence and what it measured.
    struct Sample {
        let number: Int
        let seed: UInt64
        let temperature: Double
        /// Alphabet indices over the VALID residues, in their order.
        let indices: [Int]
        /// Per-residue arrays over the FULL residue list, nil where unscored.
        let scores: DesignScores
    }

    /// Wire positions mapped into the array the model is handed.
    ///
    /// The Python side numbers `fixed_positions` against every residue it enumerated,
    /// because that is the array whose indices a user's selection resolves to. The model
    /// sees only the residues with a complete backbone. A fixed position naming a residue
    /// that did not survive is DROPPED rather than shifted: it names nothing the model can
    /// hold, and shifting it would hold a different residue.
    static func fixedInValidOrder(wire: [Int], backbone: DesignResidueSet) -> Set<Int> {
        guard !wire.isEmpty else { return [] }
        let asked = Set(wire)
        var out = Set<Int>()
        var valid = 0
        for (index, residue) in backbone.residues.enumerated() {
            guard residue.valid else { continue }
            if asked.contains(index) { out.insert(valid) }
            valid += 1
        }
        return out
    }

    /// The result document, in the shape `designing_sequences._read_result` reads.
    ///
    /// **THE KEYS ARE A CONTRACT** (spec §5). `index` is shared by every sample because
    /// they share a backbone, and it is the index both per-residue arrays are written
    /// against. An unscored residue is `NSNull` in the arrays and stays that way: absent is
    /// not zero -- a residue with no backbone was not scored, and a 0.0 there would read as
    /// a real and terrible measurement.
    ///
    /// `chains` covers EVERY residue of the backbone, with the native letter where the
    /// model wrote none, so the entry's sequence is the thing a later `predict` folds.
    /// `fixed` is in VALID order -- the same set handed to `MPNNModel.DesignOptions`.
    /// It is a parameter rather than something derived here because a held position is
    /// not visible in the result: `MPNNModel.design` returns the NATIVE letter at a fixed
    /// position (that is how `DesignController` reads it), so counting those as designed
    /// scored every one of them as recovered and made `sequence_recovery` a function of
    /// how much was held rather than of what the model wrote. Measured before the fix:
    /// a 3-of-10-residue region reported ≥ 0.7 whatever MPNN produced (#453 review,
    /// finding 3). The set path is unaffected -- nothing is held there -- but this is a
    /// column the drawer sorts on.
    static func composeResult(backbone: DesignResidueSet, samples: [Sample],
                              fixed: Set<Int> = [], elapsed: Double) -> [String: Any] {
        let index = backbone.residues.map { [$0.chain, $0.resi] }
        var sequences: [[String: Any]] = []
        for sample in samples {
            var letters: [Character] = []
            var cursor = 0
            var recovered = 0, designed = 0
            for residue in backbone.residues {
                guard residue.valid, cursor < sample.indices.count else {
                    letters.append(Self.letter(for: residue.aa))
                    continue
                }
                let designedIndex = sample.indices[cursor]
                letters.append(Self.letter(for: designedIndex))
                if !fixed.contains(cursor) {
                    designed += 1
                    if designedIndex == residue.aa { recovered += 1 }
                }
                cursor += 1
            }
            var chains: [String: String] = [:]
            for (residue, letter) in zip(backbone.residues, letters) {
                chains[residue.chain, default: ""].append(letter)
            }
            var scalars: [String: Any] = [
                "temperature": sample.temperature,
            ]
            if designed > 0 {
                scalars["sequence_recovery"] = Double(recovered) / Double(designed)
            }
            if let mean = Self.mean(sample.scores.nativeFit) {
                scalars["mean_native_fit"] = mean
            }
            if let mean = Self.mean(sample.scores.certainty) {
                scalars["mean_certainty"] = mean
            }
            sequences.append([
                "n": sample.number,
                "seed": sample.seed,
                "chains": chains,
                "scalars": scalars,
                "arrays": ["native_fit": Self.wire(sample.scores.nativeFit),
                           "certainty": Self.wire(sample.scores.certainty)],
            ])
        }
        return ["designer": runtimeName, "elapsed_s": elapsed, "index": index,
                "sequences": sequences]
    }

    /// One-letter code for an alphabet index, `X` for anything outside it.
    static func letter(for index: Int) -> Character {
        guard index >= 0, index < MPNNModel.alphabet.count else { return "X" }
        return MPNNModel.alphabet[index]
    }

    /// `[Float?]` as a JSON array, an unscored residue as null.
    ///
    /// Spelled with an explicit `-> Any` and a `guard` rather than `map { … } ?? NSNull()`:
    /// that expression type-checks, because Swift promotes both sides to `Any`, and yields
    /// an array of `Optional<Double>` boxed as `Any` -- which `JSONSerialization` accepts
    /// and writes as numbers, so the nulls quietly stop being nulls. Caught by
    /// `testTheResultDocumentIsTheShapePythonReads`, which is why it asserts on `NSNull`
    /// rather than on the serialised bytes.
    static func wire(_ values: [Float?]) -> [Any] {
        values.map { value -> Any in
            guard let value else { return NSNull() }
            return Double(value)
        }
    }

    /// Mean over the scored residues, or nil when none were.
    static func mean(_ values: [Float?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return Double(present.reduce(0, +)) / Double(present.count)
    }
}
#endif
