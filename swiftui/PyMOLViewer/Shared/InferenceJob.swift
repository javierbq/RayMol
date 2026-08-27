#if os(macOS) || os(iOS)
import Foundation

/// The job SHELL every inference runtime shares: the wire format it speaks with Python,
/// and the file-based plumbing that carries a job from a marker to a settled status.
///
/// RayMol has no Python→Swift call path: `PyMOLBridge.h` is one-directional and no Swift
/// function carries a C symbol. So `cmd.predict` writes a request JSON and prints a
/// `PREDICT:` marker, which `PyMOLEngine.pollFeedback()` already scans on a 100 ms timer
/// — exactly how `OBJPANEL:` and `SETTINGS:ready` work. Payloads travel as tempfiles
/// because the feedback line caps at ~1 KB.
///
/// Because the Python API is a job handle, nothing here needs to return a value to Python:
/// status and result are files that Python polls. That is what makes the missing bridge
/// direction unnecessary rather than something to build.
///
/// **Neutral by construction, and it must stay that way.** Nothing in here knows a method:
/// no featurizer, no weights, no size model, and no `import` of any inference package. That
/// is what lets every runtime share it without depending on any other runtime. Anything
/// method-specific belongs in the manager that claims the runtime — see ``InferenceRuntime``.
enum InferenceJob {

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

    /// One job, as Python wrote it.
    ///
    /// **EVERY OPTIONAL FIELD HERE IS OPTIONAL ON PURPOSE.** A non-optional turns any
    /// Python/Swift version skew into "malformed prediction request" for *every* runtime at
    /// once, instead of a request that decodes and is refused by name. That property is
    /// what lets a Python side which predates a field keep working, and it is worth more
    /// than the type-level guarantee a non-optional would buy — the fields that must be
    /// present are checked by the manager that claims the runtime, which can say what is
    /// missing.
    struct Request: Codable {
        let jobID: String
        let weightsDir: String
        let chains: [Chain]
        /// Which backend must run this job. OPTIONAL, absent meaning
        /// ``BoltzJobManager/runtimeName`` — every Python side that predates a second
        /// runtime wrote no such key, and the only runtime that existed then was that one.
        /// A request naming a runtime this build does not carry reaches the default
        /// runtime's `preflight`, which REFUSES IT BY NAME: the weights and the featurizer
        /// are method-specific, so running one method's request on another's backend would
        /// not fail, it would return a confident wrong answer.
        let runtime: String?
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
        /// Where to write what this run MEASURED, as a `pymol.metrics` document (#308).
        ///
        /// The confidence numbers exist only in here: pLDDT rounded into a B-factor
        /// column was the only one that used to survive, and `ScoredStructure.pae` and
        /// `interfaceScores()` were computed on every run and thrown away. A PAE matrix
        /// is per residue PAIR and an interface score is per run, so neither fits in
        /// the PDB — hence a second file rather than more columns.
        ///
        /// Optional for the reason `objectName` is: absent simply means the Python side
        /// predates this and records the run without them, rather than the whole request
        /// failing to decode.
        let metricsPath: String?
        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", weightsDir = "weights_dir", chains, runtime
            case recyclingSteps = "recycling_steps", diffusionSteps = "diffusion_steps"
            case seed, outPath = "out_path", statusPath = "status_path"
            case objectName = "object_name", metricsPath = "metrics_path"
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
        /// The MAXIMUM `phys_footprint` this process reached during the run, in bytes,
        /// sampled every 200 ms (see ``BoltzJobManager/FootprintSampler``). Nil until the
        /// run finishes.
        ///
        /// **Not a duplicate of ``peakBytes``, and the difference is the point.** MLX's
        /// high-water mark EXCLUDES its own buffer cache
        /// (mlx-swift/Source/MLX/Memory.swift:171-178), so it under-reports what the
        /// system sees. `phys_footprint` is the quantity **jetsam kills on** and the one
        /// `os_proc_available_memory()` is denominated in — so on iOS it, not `peakBytes`,
        /// is what ``PredictSizeGuard``'s estimate is actually racing.
        ///
        /// The comment above about RSS being useless refers to `resident_size`, which
        /// omits compressed and IOKit-mapped pages and therefore misses Metal allocations
        /// entirely. `phys_footprint` includes them; the two are different instruments and
        /// only one of them was tried.
        ///
        /// Recorded rather than derived because the gap between the two is not a constant:
        /// it is whatever the cache happens to be holding, which is exactly the thing a
        /// fitted model cannot know.
        var footprintBytes: Int? = nil
        /// Wall time for the inference itself, excluding the one-time model load.
        let elapsedSeconds: Double?
        /// Steps completed within the CURRENT phase, and that phase's total --
        /// e.g. diffusion step 84 of 200. `fraction` is the same thing as a ratio;
        /// these are carried as well because "step 84 of 200" is a far more
        /// legible sentence than "42%", and because the ETA wants the raw counts.
        ///
        /// `var … = nil` rather than `let`: a default keeps the memberwise
        /// initialiser's existing call sites (and their tests) compiling, and
        /// Optional keeps a status file written before this field existed -- or by
        /// any phase that reports no steps at all -- decoding cleanly.
        var step: Int? = nil
        var totalSteps: Int? = nil

        enum CodingKeys: String, CodingKey {
            case state, phase, fraction, error, resultPath = "result_path"
            case peakBytes = "peak_bytes", footprintBytes = "footprint_bytes"
            case elapsedSeconds = "elapsed_s"
            case step, totalSteps = "total_steps"
        }
    }

    // MARK: - Progress throttling

    /// Rate-limits the status writes driven by a runtime's per-step callback.
    ///
    /// Same policy, and the same two constants, as the weight fetcher's marker
    /// throttle (`modules/pymol/predictors/fetching.py:38-41` --
    /// `MARKER_INTERVAL = 0.15`, `MARKER_FRACTION_STEP = 0.01`, applied in `_emit`
    /// at `:261-276`): skip a write only when BOTH too little time has passed AND
    /// the bar would not visibly move, and never skip a stage's final step. A
    /// 200-step run on a small input steps in milliseconds, and one status file
    /// per step would be 200 atomic writes in a burst.
    ///
    /// `@unchecked Sendable` with **its own lock**, and pointedly NOT a manager's
    /// `stateQueue`: the callback runs synchronously inside the sampling loop on the
    /// actor's executor, while `stateQueue` is entered from the MAIN thread on every
    /// cancel and is held for the ~10 s model build. Blocking the sampling loop
    /// behind that would stall inference itself. Living out here rather than inside
    /// one manager must not tempt anyone to share a queue with one.
    final class StepThrottle: @unchecked Sendable {
        /// Floor on the gap between two writes.
        static let interval: Double = 0.15
        /// ...but always write when the bar would visibly move.
        static let fractionStep: Double = 0.01

        private let lock = NSLock()
        private var lastStage = ""
        private var lastTime: Double = 0
        private var lastFraction: Double = 0

        /// `now` is injected rather than read here so the policy is testable
        /// without sleeping. Callers pass a MONOTONIC clock
        /// (`ProcessInfo.processInfo.systemUptime`), not wall time.
        func shouldEmit(stage: String, fraction: Double, isFinal: Bool,
                        now: Double) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            // A stage change is itself news: the phase NAME the card shows
            // changes, which no fraction comparison would catch.
            let forced = isFinal || stage != lastStage
            if !forced,
               now - lastTime < Self.interval,
               abs(fraction - lastFraction) < Self.fractionStep {
                return false
            }
            lastStage = stage
            lastTime = now
            lastFraction = fraction
            return true
        }
    }

    // MARK: - Request and status files

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

    /// A refusal, in the one shape every runtime's preflight returns. Both refusals read
    /// the same to a caller; only the advice differs.
    static func refusal(_ message: String) -> Status {
        Status(state: "failed", phase: "preflight", fraction: 0, error: message,
               resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
    }

    // MARK: - Settling a job

    #if DEBUG
    /// Test seam: receives "write" then "discard" for each terminal settle. Same
    /// pattern as PyMOLEngine's pythonTap -- `settle`'s ordering is the whole point
    /// of the function and is otherwise invisible, because discardPlaceholder is a
    /// main-queue hop into PyMOLEngine.shared that a unit test cannot observe.
    static var settleTap: ((String) -> Void)?
    #endif

    /// Record a terminal status, THEN take the placeholder down. Order is
    /// load-bearing: `discard_pending` pops `_PENDING`, the map every Python-derived
    /// progress view is built from, so discarding first records the failure after the
    /// only thing that could observe it has been deleted -- which is why an 11-minute
    /// run that failed used to just make its object vanish.
    ///
    /// One function rather than six call-pairs so a seventh exit cannot get it wrong.
    /// `discard_pending` reads the status FRESH to decide whether to retain a failure
    /// card, so the reverse order strands the failure where nothing can observe it.
    ///
    /// Internal rather than private: it moved out of the manager that used to own it, so
    /// every runtime now reaches it from outside. The ordering is the whole point of the
    /// function, and a second copy of it is a second chance to get it backwards.
    static func settle(_ request: Request, _ status: Status, to url: URL) {
        try? writeStatus(status, to: url)
        #if DEBUG
        settleTap?("write")
        #endif
        discardPlaceholder(request)
        #if DEBUG
        settleTap?("discard")
        #endif
    }

    // MARK: - Handing the result back to Python

    /// Hands the finished structure to Python, which loads it into the placeholder and
    /// retires the pending mark in one step.
    ///
    /// One Python entry point rather than a load plus a bookkeeping call: a name left
    /// marked pending after a successful load would be stripped from every subsequent
    /// session save. `deliver_result` also pins `zoom=0` -- a prediction can land many
    /// minutes after submit, and moving the camera then would interrupt the user.
    static func loadResult(_ request: Request) {
        guard let objectName = request.objectName, !objectName.isEmpty else { return }
        let path = pythonLiteral(request.outPath)
        let name = pythonLiteral(objectName)
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(
                "from pymol import predicting as _p; "
                + "_p.deliver_result(\(path), \(name), seed=\(request.seed))")
        }
    }

    /// Drops the placeholder when a job will never produce a structure. Python only
    /// deletes it if it is still empty, so this cannot destroy a completed result.
    static func discardPlaceholder(_ request: Request) {
        guard let objectName = request.objectName, !objectName.isEmpty else { return }
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(
                "from pymol import predicting as _p; "
                + "_p.discard_pending(\(pythonLiteral(objectName)))")
        }
    }

    /// A Python string literal for an arbitrary path or object name. Paths come from our
    /// own temp dir, but building source text without quoting is how injection bugs start.
    /// PyMOL's text parser does not strip quotes from a `"..."` token, so an object name
    /// has to be escaped exactly this way or a name with an apostrophe breaks the call.
    ///
    /// Newlines are DELETED, not escaped: every value that reaches here is a single token
    /// (a path, an object name, a predictor id), and a stray newline would end the
    /// statement mid-call. A multi-line payload must not be passed through this.
    ///
    /// Internal, and the only copy: PredictController and ProgressTray each carried a
    /// byte-identical private one, which is three chances to fix a quoting bug in two
    /// places.
    static func pythonLiteral(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "") + "'"
    }
}
#endif
