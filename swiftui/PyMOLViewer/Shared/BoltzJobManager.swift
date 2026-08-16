#if os(macOS)
import BoltzMLX
import Foundation

/// Runs Boltz predictions on behalf of Python.
///
/// RayMol has no Python→Swift call path: `PyMOLBridge.h` is one-directional and no Swift
/// function carries a C symbol. So `cmd.predict` writes a request JSON and prints a
/// `PREDICT:` marker, which `PyMOLEngine.pollFeedback()` already scans on a 100 ms timer
/// — exactly how `OBJPANEL:` and `SETTINGS:ready` work. Payloads travel as tempfiles
/// because the feedback line caps at ~1 KB.
///
/// Because the Python API is a job handle, nothing here needs to return a value to
/// Python: status and result are files that Python polls. That is what makes the missing
/// bridge direction unnecessary rather than something to build.
final class BoltzJobManager {

    static let shared = BoltzJobManager()

    /// MLX must never run on the main thread. `cmd.predict` from the console arrives ON
    /// the main thread, which is exactly why submit is fire-and-forget.
    private let queue = DispatchQueue(label: "io.raymol.predict.inference",
                                      qos: .userInitiated)
    /// Serializes access to `predictor`, which is expensive to build, and to `cancelled`.
    private let stateQueue = DispatchQueue(label: "io.raymol.predict.state")
    private var cancelled = Set<String>()
    /// Live inference tasks by job id. Cancelling the TASK is what actually interrupts
    /// compute: boltz-mlx guards each diffusion step with `Task.checkCancellation()`, which
    /// reads the running task's flag — so a cancel that only sets a side-channel flag never
    /// stops the work. Held under `stateQueue`.
    private var runningTasks: [String: Task<Void, Never>] = [:]
    /// Construction loads ~505 MiB and builds the graph (~10 s), so it is kept alive
    /// across predictions rather than rebuilt per job.
    private var predictor: BoltzPredictor?
    private var predictorDirectory: String?

    // MARK: - Test seam

    /// Observability for the cancel path, which is otherwise unassertable: a regression
    /// could turn cancel back into a no-op with every test still green. Mirrors
    /// `DesignController`'s `inject*` seams and is likewise ungated, so the test bundle
    /// can be built against a Release host.
    var cancelRequestedForTesting: Set<String> { stateQueue.sync { cancelled } }
    var runningJobIDsForTesting: Set<String> { stateQueue.sync { Set(runningTasks.keys) } }

    /// Registers a live task exactly as `run()` does, so a test can prove that a cancel
    /// marker cancels it rather than merely recording a flag.
    func registerTaskForTesting(_ task: Task<Void, Never>, jobID: String) {
        stateQueue.sync {
            runningTasks[jobID] = task
            // Mirrors run()'s registration exactly, including the already-cancelled
            // check — a seam that skipped it would make the race test vacuous.
            if cancelled.contains(jobID) { task.cancel() }
        }
    }

    func resetForTesting() {
        stateQueue.sync { cancelled.removeAll(); runningTasks.removeAll() }
    }

    // MARK: - Marker parsing

    enum Verb: String { case submit, cancel }
    struct Marker: Equatable { let verb: Verb; let jobID: String }

    static func parseMarker(_ line: String) -> Marker? {
        guard line.hasPrefix("PREDICT:") else { return nil }
        let body = line.dropFirst("PREDICT:".count)
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let verb = Verb(rawValue: String(parts[0])),
              !parts[1].isEmpty else { return nil }
        return Marker(verb: verb, jobID: String(parts[1]))
    }

    // MARK: - Wire format (must match modules/pymol/predictors/host.py)

    struct Chain: Codable { let chain: String; let sequence: String }

    /// One chain's multiple-sequence alignment, as a PATH to an a3m.
    ///
    /// A path rather than inline text because an alignment is megabytes — the barnase
    /// one boltz-mlx tests against is ~1.3 MB — and base64 inside a JSON this decodes in
    /// one gulp buys nothing over a file that is read once and dropped. Python writes
    /// each file BEFORE the request that names it, so a request that decodes has its
    /// alignments already complete on disk.
    struct Alignment: Codable {
        let chain: String
        let a3mPath: String

        enum CodingKeys: String, CodingKey { case chain, a3mPath = "a3m_path" }
    }

    struct Request: Codable {
        let jobID: String
        let weightsDir: String
        let chains: [Chain]
        let recyclingSteps: Int
        let diffusionSteps: Int
        let seed: UInt64
        let outPath: String
        let statusPath: String
        /// Per-chain alignments. OPTIONAL, so a request written by a Python side that
        /// predates #297 still decodes — the same reasoning as `objectName` below.
        ///
        /// PARTIAL by design: a chain that is absent gets upstream's depth-1 dummy MSA
        /// (`BoltzFeaturizer` falls back to `MSAAlignment.singleSequence`), which is
        /// exactly the designed-binder case — a real alignment for the target, none for
        /// the binder, because a designed binder has no homologs to align.
        let alignments: [Alignment]?
        /// Rows to read from each a3m, from the top. Optional for the same reason.
        let msaDepth: Int?
        /// Object the finished structure is loaded into. Python creates an empty
        /// placeholder under this name at submit time; loading into it lands at state 1,
        /// and a repeat prediction of the same sequence appends model 2, 3, ...
        ///
        /// OPTIONAL on purpose. Absent means "do not auto-load" — a legitimate state, and
        /// it keeps the wire backward compatible: a non-optional field would turn any
        /// Python/Swift skew into a hard "malformed request" failure instead of simply
        /// falling back to the explicit `predict_result` flow. Same reasoning as the
        /// object panel's optional `groups`/`pending` fields.
        let objectName: String?

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", weightsDir = "weights_dir", chains
            case recyclingSteps = "recycling_steps", diffusionSteps = "diffusion_steps"
            case seed, outPath = "out_path", statusPath = "status_path"
            case objectName = "object_name"
            case alignments, msaDepth = "msa_depth"
        }
    }

    struct Status: Codable {
        let state: String        // queued | running | done | failed | cancelled
        let phase: String
        let fraction: Double
        let error: String?
        let resultPath: String?
        /// MLX's peak-memory high-water mark for THIS prediction, in bytes. Nil until the
        /// run finishes. Reported because process RSS does not attribute MLX's Metal
        /// allocations at all -- sampling RSS during a 250-residue run showed ~9 MB of
        /// growth against a multi-GB actual -- so this is the only honest instrument, and
        /// it is what `PredictSizeGuard`'s constants must be fitted against.
        let peakBytes: Int?
        /// Wall time for the inference itself, excluding the one-time model load.
        let elapsedSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case state, phase, fraction, error, resultPath = "result_path"
            case peakBytes = "peak_bytes", elapsedSeconds = "elapsed_s"
        }
    }

    static func parseRequest(at url: URL) throws -> Request {
        try JSONDecoder().decode(Request.self, from: try Data(contentsOf: url))
    }

    /// Atomic, so a poller never reads a half-written status.
    static func writeStatus(_ status: Status, to url: URL) throws {
        let data = try JSONEncoder().encode(status)
        let temp = url.appendingPathExtension("tmp")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    // MARK: - Entry point from pollFeedback()

    func handle(marker line: String) {
        guard let marker = Self.parseMarker(line) else { return }
        switch marker.verb {
        case .cancel:
            // Cancel the live task so compute actually stops, and record the request for
            // the coarse phase checks (a cancel can arrive before the task is registered).
            // Ignore cancels for jobs already in a terminal state, so `cancelled` cannot
            // grow without bound from stray or post-completion markers.
            stateQueue.sync {
                if let task = runningTasks[marker.jobID] {
                    cancelled.insert(marker.jobID)
                    task.cancel()
                } else if !Self.hasTerminalStatus(jobID: marker.jobID) {
                    cancelled.insert(marker.jobID)
                }
            }
        case .submit:
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("raymol_predict_req_\(marker.jobID).json")
            let request: Request
            do {
                request = try Self.parseRequest(at: url)
            } catch {
                // Without this, an unparseable request returns silently and Python polls
                // `queued` forever — asymmetric with preflight, which does write `failed`.
                // The status path follows host.py's naming convention, so it is derivable
                // even when the payload is not.
                try? Self.writeStatus(
                    Status(state: "failed", phase: "request", fraction: 0,
                           error: "malformed prediction request: "
                                + error.localizedDescription,
                           resultPath: nil, peakBytes: nil, elapsedSeconds: nil),
                    to: Self.statusURL(jobID: marker.jobID))
                return
            }
            if let failure = Self.preflight(request) {
                // Refused before any work: the placeholder Python just created will never
                // be filled, so drop it rather than leaving an empty stub behind.
                Self.discardPlaceholder(request)
                try? Self.writeStatus(failure, to: URL(fileURLWithPath: request.statusPath))
                return
            }
            queue.async { self.run(request) }
        }
    }

    /// host.py's naming convention, so a status can be reported even for a request that
    /// could not be decoded.
    static func statusURL(jobID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_status_\(jobID).json")
    }

    /// True when a status file already records a terminal state, i.e. cancelling is moot.
    static func hasTerminalStatus(jobID: String) -> Bool {
        guard let data = try? Data(contentsOf: statusURL(jobID: jobID)),
              let status = try? JSONDecoder().decode(Status.self, from: data)
        else { return false }
        return ["done", "failed", "cancelled"].contains(status.state)
    }

    /// Refuse before allocating anything. Returns nil when the run may proceed.
    static func preflight(_ request: Request) -> Status? {
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .ok, .warn:
            // `.warn` deliberately proceeds, so `okFraction` has no effect on this path
            // today — the tier is not yet surfaced anywhere. It is kept rather than
            // collapsed because the shape is shared with `DesignSizeGuard`, whose
            // controller DOES show a caution, and because #217's deferred "Predict" menu
            // item is where a caution belongs. Adding a caution field to the wire format
            // for a feature with no UI would be speculative; when that UI lands, surface
            // `.warn` there rather than reviving it here.
            return nil
        case let .refuse(maxFittingTokens):
            return Status(state: "failed", phase: "preflight", fraction: 0,
                          error: "input of \(tokens) residues is too large for this "
                               + "machine; at most about \(maxFittingTokens) fit",
                          resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
        }
    }

    // MARK: - Handing the result back to Python

    /// Hands the finished structure to Python, which loads it into the placeholder and
    /// retires the pending mark in one step.
    ///
    /// One Python entry point rather than a load plus a bookkeeping call: a name left
    /// marked pending after a successful load would be stripped from every subsequent
    /// session save. `deliver_result` also pins `zoom=0` -- a prediction can land many
    /// minutes after submit, and moving the camera then would interrupt the user.
    private static func loadResult(_ request: Request) {
        guard let objectName = request.objectName, !objectName.isEmpty else { return }
        let path = pythonLiteral(request.outPath)
        let name = pythonLiteral(objectName)
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(
                "from pymol import predicting as _p; "
                + "_p.deliver_result(\(path), \(name), seed=\(request.seed))")
        }
    }

    /// A Python string literal for an arbitrary path. Paths come from our own temp dir,
    /// but building source text without quoting is how injection bugs start.
    private static func pythonLiteral(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "") + "'"
    }

    /// Drops the placeholder when a job will never produce a structure. Python only
    /// deletes it if it is still empty, so this cannot destroy a completed result.
    private static func discardPlaceholder(_ request: Request) {
        guard let objectName = request.objectName, !objectName.isEmpty else { return }
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(
                "from pymol import predicting as _p; "
                + "_p.discard_pending(\(pythonLiteral(objectName)))")
        }
    }

    // MARK: - Inference

    private func run(_ request: Request) {
        let statusURL = URL(fileURLWithPath: request.statusPath)
        // Captured by report() below; filled in once inference completes.
        var peak: Int? = nil
        var elapsed: Double? = nil
        func report(_ state: String, _ phase: String, _ fraction: Double,
                    error: String? = nil, result: String? = nil) {
            try? Self.writeStatus(Status(state: state, phase: phase, fraction: fraction,
                                         error: error, resultPath: result,
                                         peakBytes: peak, elapsedSeconds: elapsed),
                                  to: statusURL)
        }
        func isCancelled() -> Bool {
            stateQueue.sync { cancelled.contains(request.jobID) }
        }

        report("running", "featurize", 0.0)
        do {
            BoltzRuntime.configureOnce()

            let canonical = try CanonicalStructure.fromSequences(
                request.chains.map { ($0.chain, $0.sequence) })
            // The featurizer SILENTLY EXCLUDES residues it cannot template rather than
            // failing, and hasBlockingDiagnostics only counts missingBackbone /
            // noTemplateAtoms. So anything reported at all is refused here, instead of
            // returning a structure that quietly is not what was asked for.
            guard canonical.diagnostics.isEmpty else {
                Self.discardPlaceholder(request)
                report("failed", "featurize", 0,
                       error: "unsupported input: \(canonical.diagnostics)")
                return
            }
            let features = try BoltzFeaturizer().featurize(
                canonical, alignments: try Self.loadAlignments(request))

            if isCancelled() {
                Self.discardPlaceholder(request)
                report("cancelled", "featurize", 0); return
            }
            report("running", "load", 0.1)
            let predictor = try loadedPredictor(directory: request.weightsDir)

            report("running", "inference", 0.2)
            var options = BoltzPredictionOptions()
            options.recyclingSteps = request.recyclingSteps
            options.diffusionSteps = request.diffusionSteps
            options.seed = request.seed

            // Reset the high-water mark so each prediction is measured independently --
            // the same reset-then-snapshot pattern boltz-mlx's own benchmark harness uses.
            Self.awaitSyncVoid { await predictor.resetPeakMemory() }
            let started = Date()
            // MemoryPlanner.apply() runs inside the actor on EVERY predict and assigns
            // MLX.Memory.cacheLimit unconditionally, overwriting whatever MLXRuntime
            // arbitrated. Re-assert on EVERY exit including a throw -- otherwise a failed
            // prediction leaves prediction's larger ceiling installed and a subsequent
            // Design-mode inference inherits it and can be jetsam-killed.
            // NOTE apply() also pins Memory.memoryLimit to boltz's 6 GB default, which
            // RayMol does not arbitrate and accepts for the life of the process.
            defer { BoltzRuntime.configureOnce() }
            // predictScored, not predict: pLDDT only exists on the scored path, because
            // it is a head on the confidence module. That module is real extra work — see
            // the cost note below — but a prediction with no per-residue confidence is
            // much less useful, since confidence is what a viewer colours by.
            let scored = try BoltzRuntime.withMLXErrorsAsThrows {
                try Self.awaitSyncCancellable(
                    register: { task in
                        self.stateQueue.sync {
                            self.runningTasks[request.jobID] = task
                            // Close the registration race. A cancel arriving between the
                            // post-featurize check and this point found no task to cancel
                            // and only set the flag, so nothing ever stopped the compute:
                            // observed live, a job cancelled at ~12 s ran the full 49 s to
                            // "done". Re-checking under the same lock that publishes the
                            // task makes the two atomic, so the cancel cannot be dropped.
                            if self.cancelled.contains(request.jobID) { task.cancel() }
                        }
                    },
                    { try await predictor.predictScored(featurized: features,
                                                        options: options) })
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Self.awaitSyncValue { await predictor.memorySnapshot().peakMemory }

            if isCancelled() {
                Self.discardPlaceholder(request)
                report("cancelled", "inference", 0); return
            }
            report("running", "write", 0.95)
            // pLDDT into the B-factor column, which is what `spectrum b` colours by.
            let text = try StructureWriter.pdb(structure: scored.structure,
                                              canonical: canonical,
                                              plddt: scored.plddt)
            try text.write(to: URL(fileURLWithPath: request.outPath),
                           atomically: true, encoding: .utf8)
            // Load BEFORE reporting done: predict_status returning done should already
            // imply the object is populated, or a script that polls then reads the object
            // races the load.
            Self.loadResult(request)
            report("done", "done", 1.0, result: request.outPath)
        } catch is CancellationError {
            Self.discardPlaceholder(request)
            report("cancelled", "inference", 0)
        } catch {
            // Failed, carrying the message — and NOT retried without the alignment.
            // Upstream Boltz silently substitutes a dummy MSA when an a3m does not match
            // its chain, so every score it then reports describes the wrong complex with
            // nothing saying so. boltz-mlx throws instead, on purpose; retrying here
            // would undo that and reintroduce the exact failure it was written to
            // prevent.
            Self.discardPlaceholder(request)
            report("failed", "inference", 0, error: Self.message(for: error))
        }
        stateQueue.sync {
            cancelled.remove(request.jobID)
            runningTasks.removeValue(forKey: request.jobID)
        }
    }

    // MARK: - Alignments

    /// Reads each chain's a3m into the parser that will consume it.
    ///
    /// The truncation is the PARSER's own (`maximumSequences`), not a slice taken here:
    /// it counts rows after deduplication and after the query, which is a different
    /// count from the file's line numbers, and applying a second, cruder cut first
    /// would silently mean something else.
    ///
    /// `taxonomy: nil` is deliberate and not a gap. Cross-chain pairing reads taxonomy
    /// only from `>UniRef100_*` headers and only when a database is supplied, so it is
    /// inert for locally generated files. Marking a multimer's rows as paired without
    /// one would assert co-evolution across the very interface an interface score
    /// measures — and that fails by reading HIGH rather than by crashing.
    static func loadAlignments(_ request: Request) throws -> [String: MSAAlignment] {
        guard let entries = request.alignments, !entries.isEmpty else { return [:] }
        // Nil only for a request written before #297, which also carries no alignments —
        // so this fallback is for a hand-written request, and it is upstream's own cap.
        let depth = request.msaDepth ?? BoltzInputLimits.desktop.maximumMSADepth
        var loaded: [String: MSAAlignment] = [:]
        for entry in entries {
            let text = try String(contentsOfFile: entry.a3mPath, encoding: .utf8)
            loaded[entry.chain] = try MSAAlignment.a3m(text, maximumSequences: depth,
                                                      taxonomy: nil)
        }
        return loaded
    }

    /// The message an error actually carries.
    ///
    /// `localizedDescription` bridges a plain Swift error through `NSError` and returns a
    /// placeholder naming only the case NUMBER — "The operation couldn't be completed.
    /// (BoltzMLX.BoltzFeaturizerError error 5.)". For most failures that is merely poor.
    /// For `msaQueryMismatch` it is destructive: that error's entire job is to say which
    /// chain and which position disagree, and it is the only thing standing between the
    /// user and a confident score for the wrong complex — upstream Boltz does not throw
    /// at all there, it substitutes a dummy MSA and reports numbers.
    static func message(for error: Error) -> String {
        switch error {
        case let error as BoltzFeaturizerError:
            return error.description
        case let error as MSAParseError:
            // Reachable only if the two parsers disagree: Python checks every row's
            // column count at `load_msa`, before any of this. Worth saying plainly
            // rather than as a raw enum case, because "they disagree" is the news.
            switch error {
            case .empty:
                return "the alignment file contains no sequences"
            case let .rowLengthMismatch(row, expected, found):
                return "row \(row + 1) of the alignment has \(found) aligned columns "
                     + "but the query has \(expected)"
            }
        default:
            return error.localizedDescription
        }
    }

    /// Bridge the actor's async API onto this synchronous queue. Blocking a thread is
    /// acceptable here precisely because the queue is dedicated to one inference at a
    /// time; it must never be done on the main thread.
    private static func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
        try awaitSyncCancellable(register: { _ in }, body)
    }

    /// As ``awaitSync(_:)``, but hands the task to `register` so a cancel marker can
    /// `.cancel()` it. That is the only thing that interrupts compute — boltz-mlx's
    /// per-diffusion-step `Task.checkCancellation()` reads the RUNNING task's flag, so
    /// discarding the handle (as this did originally) makes cancel a silent no-op that
    /// merely throws away a completed result.
    private static func awaitSyncCancellable<T>(
        register: (Task<Void, Never>) -> Void,
        _ body: @escaping () async throws -> T
    ) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>!
        let task = Task {
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
            done.signal()
        }
        register(task)
        done.wait()
        return try outcome.get()
    }

    /// Non-throwing variants of ``awaitSync(_:)`` for the actor's measurement calls.
    private static func awaitSyncVoid(_ body: @escaping () async -> Void) {
        let done = DispatchSemaphore(value: 0)
        Task { await body(); done.signal() }
        done.wait()
    }

    private static func awaitSyncValue<T>(_ body: @escaping () async -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        var out: T!
        Task { out = await body(); done.signal() }
        done.wait()
        return out
    }

    /// Reuses the loaded predictor when the weights directory is unchanged.
    private func loadedPredictor(directory: String) throws -> BoltzPredictor {
        try stateQueue.sync {
            if let existing = predictor, predictorDirectory == directory { return existing }
            let built = try BoltzRuntime.withMLXErrorsAsThrows {
                try BoltzPredictor(
                    modelDirectory: URL(fileURLWithPath: directory),
                    // The default preset is phone-sized (256 tokens) and would refuse
                    // anything real. cacheLimit is pinned to whatever MLXRuntime has
                    // arbitrated so this planner's apply() re-asserts the agreed
                    // ceiling instead of substituting its own 64 MiB default.
                    memoryPlanner: MemoryPlanner(limits: .desktop,
                                                 cacheLimit: MLXRuntime.activeCacheLimitBytes))
            }
            predictor = built
            predictorDirectory = directory
            return built
        }
    }
}
#endif
