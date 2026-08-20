#if os(macOS) || os(iOS)
import BoltzMLX
import Foundation
import os

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

    /// The one inference runtime this manager implements, as it appears on the wire.
    /// Kept in step with `pymol.predictors.boltz2.RUNTIME`, and with the value
    /// `PyMOLBridge` advertises in `RAYMOL_PREDICT_RUNTIMES` — that variable is what lets
    /// a predictor whose backend is NOT linked here refuse in `check_available` instead
    /// of submitting a job that only gets refused after a weight download.
    static let boltzRuntime = "boltz"

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
        /// Which backend must run this job. OPTIONAL, absent meaning ``boltzRuntime`` —
        /// every Python side that predates a second runtime wrote no such key, and the
        /// only runtime that existed then was this one. A request naming a runtime this
        /// build does not carry is REFUSED in `preflight`, never run here: the weights and
        /// the featurizer are method-specific, so running one method's request on
        /// another's backend would not fail, it would return a confident wrong answer.
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
            case peakBytes = "peak_bytes", elapsedSeconds = "elapsed_s"
            case step, totalSteps = "total_steps"
        }
    }

    /// Rate-limits the status writes driven by boltz-mlx's per-step callback.
    ///
    /// Same policy, and the same two constants, as the weight fetcher's marker
    /// throttle (`modules/pymol/predictors/fetching.py:38-41` --
    /// `MARKER_INTERVAL = 0.15`, `MARKER_FRACTION_STEP = 0.01`, applied in `_emit`
    /// at `:261-276`): skip a write only when BOTH too little time has passed AND
    /// the bar would not visibly move, and never skip a stage's final step. A
    /// 200-step run on a small input steps in milliseconds, and one status file
    /// per step would be 200 atomic writes in a burst.
    ///
    /// `@unchecked Sendable` with its own lock, and pointedly NOT `stateQueue`:
    /// the callback runs synchronously inside the sampling loop on the actor's
    /// executor, while `stateQueue` is entered from the MAIN thread on every
    /// cancel and is held for the ~10 s model build. Blocking the sampling loop
    /// behind that would stall inference itself.
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
    private static func settle(_ request: Request, _ status: Status, to url: URL) {
        try? writeStatus(status, to: url)
        #if DEBUG
        settleTap?("write")
        #endif
        discardPlaceholder(request)
        #if DEBUG
        settleTap?("discard")
        #endif
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
            // Broadcast: a cancel marker carries only a job id, so there is nothing in it
            // to route on. Every manager keeps only its own ids, and a cancel for a job
            // this one never had is a no-op. macOS only because Protenix is: iOS links
            // no second manager, so there is nothing to broadcast to.
            #if os(macOS)
            ProtenixJobManager.shared.cancel(jobID: marker.jobID)
            #endif
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
            // Routed BEFORE preflight, because preflight below is Boltz's: its size model
            // is fitted to Boltz's peaks, and its runtime check exists to refuse backends
            // nothing implements. A protenix request is not that -- it has a manager.
            //
            // This manager owns the marker only because it was here first. When a third
            // runtime lands, lift the parse-and-route out into a dispatcher rather than
            // adding another branch here.
            //
            // macOS only, and the iOS arm needs no fallback branch: PyMOLBridge.mm
            // advertises "boltz" alone there, so host.require_runtime refuses a protenix
            // request in Python before any marker is printed. If one somehow arrived, it
            // would fall through to Self.preflight below, whose runtime check refuses
            // exactly this case with an accurate message.
            #if os(macOS)
            if request.runtime == ProtenixJobManager.runtimeName {
                ProtenixJobManager.shared.submit(request)
                return
            }
            #endif
            if let failure = Self.preflight(request) {
                // Refused before any work: the placeholder Python just created will never
                // be filled, so drop it rather than leaving an empty stub behind.
                Self.settle(request, failure, to: URL(fileURLWithPath: request.statusPath))
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
    ///
    /// Sees only what the REQUEST says, because it runs on the main thread from
    /// `pollFeedback`: the alignment's real depth costs a parse of the a3m, which
    /// belongs on the inference queue. `alignmentPreflight` makes that second check.
    static func preflight(_ request: Request) -> Status? {
        // Runtime first, before any sizing: the size model below is Boltz's, fitted to
        // Boltz's measured peaks, so applying it to another method's request would be
        // meaningless even as a refusal. Absent means Boltz, per `Request.runtime`.
        if let runtime = request.runtime, runtime != boltzRuntime {
            return refusal("this build of RayMol does not carry the '\(runtime)' "
                         + "inference runtime")
        }
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .refuseDepth:
            // Unreachable: this call passes no depth, so it defaults to 1. Handled
            // rather than defaulted away so that adding a depth here cannot silently
            // become "proceed".
            return refusal("the alignment is too large for this machine")
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
            return refusal("input of \(tokens) residues is too large for this machine; "
                         + "at most about \(maxFittingTokens) fit")
        }
    }

    /// Refuse a run whose ALIGNMENT is what will not fit. Returns nil to proceed.
    ///
    /// The deepest alignment is used against the total token count, rather than summing
    /// per-chain products. It is the conservative reading of the two — a dimer with one
    /// deep alignment is charged as though both chains carried it — and it is the one
    /// that cannot license a run that then dies, which is the only direction that
    /// matters here.
    static func alignmentPreflight(_ request: Request,
                                   alignments: [String: MSAAlignment]) -> Status? {
        guard let deepest = alignments.values.map(\.depth).max(), deepest > 1 else {
            return nil
        }
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens, msaDepth: deepest,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .ok, .warn:
            return nil
        case let .refuseDepth(maxFittingDepth):
            return refusal(
                maxFittingDepth >= 1
                    ? "an alignment \(deepest) rows deep is too large for this machine "
                    + "at \(tokens) residues; retry with msa_depth=\(maxFittingDepth)"
                    : "\(tokens) residues with an alignment is too large for this "
                    + "machine")
        case let .refuse(maxFittingTokens):
            return refusal("input of \(tokens) residues is too large for this machine; "
                         + "at most about \(maxFittingTokens) fit")
        }
    }

    /// Both refusals read the same to a caller; only the advice differs.
    static func refusal(_ message: String) -> Status {
        Status(state: "failed", phase: "preflight", fraction: 0, error: message,
               resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
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

    /// (chain, resi) for every residue, numbered exactly as the PDB written beside it.
    ///
    /// A MIRROR of `StructureWriter.pdb`'s numbering — 1-based per chain, reset at each
    /// chain break — and it has to stay one. The metric arrays are indexed by residue,
    /// and PyMOL reads its residue numbers out of that PDB, so any drift between the two
    /// would land every per-residue confidence on the wrong residue: an array that is
    /// still the right length, still plausible, and silently off by a register.
    private static func residueIndex(_ canonical: CanonicalStructure) -> [[String]] {
        var out: [[String]] = []
        var previousChain: String?
        var resSeq = 0
        for residue in canonical.orderedResidues {
            if let previous = previousChain, previous != residue.hostChain { resSeq = 0 }
            previousChain = residue.hostChain
            resSeq += 1
            out.append([residue.hostChain, String(resSeq)])
        }
        return out
    }

    /// Write the confidence numbers as a `pymol.metrics` document.
    ///
    /// Only what the RUNTIME knows: elapsed time and peak memory reach the store through
    /// the status file, and the options and seed through the Python side, so nothing is
    /// reported twice from two sources that could disagree.
    ///
    /// Best effort by construction. A prediction that folded must not be reported as
    /// failed because its metrics could not be serialized, so every failure here is
    /// swallowed and the run is simply recorded without them.
    private static func writeMetrics(request: Request, scored: ScoredStructure,
                                     canonical: CanonicalStructure) {
        guard let path = request.metricsPath, !path.isEmpty else { return }
        let index = residueIndex(canonical)
        var values: [[String: Any]] = []

        // Length checks rather than trust: a count mismatch means the scores and the
        // structure do not describe the same prediction, which is exactly what
        // StructureWriter refuses to write through. Skipped, not guessed at.
        if scored.plddt.count == index.count, !index.isEmpty {
            values.append(["key": "plddt", "state": 0, "index": index,
                           "values": scored.plddt])
            // The producer writes its own summary. The store never derives one: which
            // residues went into a mean is a property of the tool, not of the store.
            values.append(["key": "mean_plddt", "state": 0,
                           "value": scored.plddt.reduce(0, +) / Double(scored.plddt.count)])
        }
        if scored.tokenCount == index.count,
           scored.pae.count == index.count * index.count {
            values.append(["key": "pae", "state": 0, "index": index,
                           "values": scored.pae])
            // The matrix's own summary, written by the producer for the reason
            // `mean_plddt` is: which entries went into it is a property of the tool.
            //
            // OFF THE DIAGONAL. PAE(i, i) is definitionally near zero and says nothing,
            // so counting it would pull the mean down by roughly 1/n — ~3% at 35
            // residues, worse the shorter the chain. Needs n >= 2 to mean anything.
            let n = index.count
            if n > 1 {
                var total = 0.0
                for i in 0..<n {
                    for j in 0..<n where i != j { total += scored.pae[i * n + j] }
                }
                values.append(["key": "mean_pae", "state": 0,
                               "value": total / Double(n * (n - 1))])
            }
        }
        // nil for a single chain, where an interface score is undefined. Absent rather
        // than 0, which would read as a terrible interface instead of no interface.
        //
        // Both directions of ipSAE go across: `min_ipsae` is the gate (the worse
        // direction is what a designed interface should be judged on) and `ipsae` is
        // max(A->B, B->A), which boltz-mlx reports for continuity with the reference
        // implementation and which will read higher. Sending only one of them would
        // leave a reader unable to tell which normalisation they had.
        if let interface = scored.interfaceScores() {
            values.append(["key": "min_ipsae", "state": 0, "value": interface.minIPSAE])
            values.append(["key": "ipsae", "state": 0, "value": interface.ipsae])
            values.append(["key": "ipae", "state": 0, "value": interface.ipae])
        }
        guard !values.isEmpty else { return }

        // `tool` is overwritten by the Python side, which knows which PREDICTOR selected
        // this runtime — boltz2 and boltz2-bf16 are one runtime and two tools, and only
        // the command layer can tell them apart. Sent anyway so the file is readable on
        // its own. `state` is likewise restamped: how many models already sit in the
        // object is not knowable here.
        let document: [String: Any] = [
            "tool": "boltz2",
            "object": request.objectName ?? "",
            "values": values,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
        let url = URL(fileURLWithPath: path)
        let temp = url.appendingPathExtension("tmp")
        // Complete, or not there at all: the Python side opens this by path the moment
        // the load marker fires, which is a poll away from this write.
        guard (try? data.write(to: temp)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: temp)
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
    static func discardPlaceholder(_ request: Request) {
        guard let objectName = request.objectName, !objectName.isEmpty else { return }
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(
                "from pymol import predicting as _p; "
                + "_p.discard_pending(\(pythonLiteral(objectName)))")
        }
    }

    // MARK: - Inference

    /// Records one step of a running phase, from inside boltz-mlx's callback.
    ///
    /// STATIC, and not `run()`'s nested `report`. That is forced, not stylistic:
    /// the callback is `@Sendable` because it crosses into an actor, and a
    /// `@Sendable` closure MAY NOT capture mutable locals -- which is exactly what
    /// `report` closes over (`var peak`, `var elapsed`). Those two are nil for the
    /// whole of inference anyway; they are only known once it has finished.
    ///
    /// Takes no lock and touches no MLX: it runs synchronously inside the sampling
    /// loop, so everything it does is on inference's critical path.
    private static func reportStep(to url: URL, phase: String, fraction: Double,
                                   step: Int, totalSteps: Int) {
        try? writeStatus(Status(state: "running", phase: phase, fraction: fraction,
                                error: nil, resultPath: nil, peakBytes: nil,
                                elapsedSeconds: nil,
                                step: step, totalSteps: totalSteps),
                         to: url)
    }

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
        func settle(_ state: String, _ phase: String, error: String? = nil) {
            Self.settle(request,
                        Status(state: state, phase: phase, fraction: 0,
                               error: error, resultPath: nil,
                               peakBytes: peak, elapsedSeconds: elapsed),
                        to: statusURL)
        }

        report("running", "featurize", 0.0)
        Self.logMemory("start", jobID: request.jobID)
        defer { Self.logMemory("end", jobID: request.jobID) }
        do {
            BoltzRuntime.configureOnce()

            let canonical = try CanonicalStructure.fromSequences(
                request.chains.map { ($0.chain, $0.sequence) })
            // The featurizer SILENTLY EXCLUDES residues it cannot template rather than
            // failing, and hasBlockingDiagnostics only counts missingBackbone /
            // noTemplateAtoms. So anything reported at all is refused here, instead of
            // returning a structure that quietly is not what was asked for.
            guard canonical.diagnostics.isEmpty else {
                settle("failed", "featurize",
                       error: "unsupported input: \(canonical.diagnostics)")
                return
            }
            let alignments = try Self.loadAlignments(request)
            // The SECOND size check, and the one that can see the alignment. `preflight`
            // runs on the main thread from pollFeedback and may only look at the request,
            // where the depth is a CAP (16384 by default) rather than what the a3m
            // actually holds — deciding on the cap would refuse a 200-row alignment as
            // though it were 16,384. The real depth is only known once the a3m is parsed,
            // and parsing megabytes of it on the main thread is not an option. Here it is
            // known, this is the inference queue, and nothing large has been allocated
            // yet: featurize on the next line is where the tensors appear.
            if let failure = Self.alignmentPreflight(request, alignments: alignments) {
                // settle, not discard-then-write: discard_pending pops _PENDING, the map
                // every progress view reads, so discarding first records the refusal
                // after the only thing that could show it is gone.
                Self.settle(request, failure, to: statusURL)
                return
            }
            let features = try BoltzFeaturizer().featurize(canonical,
                                                          alignments: alignments)

            if isCancelled() {
                settle("cancelled", "featurize"); return
            }
            report("running", "load", 0.1)
            let predictor = try loadedPredictor(directory: request.weightsDir)

            // "trunk" at 0.0, not the old "inference" at 0.2: inference's band is
            // ZERO-SPAN (predictors/boltz2.py) and only ever meant "started, cannot
            // say how far in". boltz-mlx v0.2.1 can say, so the phase is named from
            // the outset and the first callback replaces this within one recycle.
            // Both bands start at 0.10, so the bar does not jump.
            report("running", "trunk", 0.0)
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
            // The one place progress can be observed at all: BoltzPredictor is an
            // actor that never suspends during a prediction, so nothing outside can
            // poll it. boltz-mlx v0.2.1 emits after the MLX.eval that forces
            // materialization in each of the two loops that have one -- trunk
            // recycling and diffusion sampling -- so a reported step is a step that
            // has genuinely been computed, not one merely queued into MLX's lazy
            // graph.
            let throttle = StepThrottle()
            let onProgress: @Sendable (BoltzProgress) -> Void = { progress in
                // "trunk" / "diffusion" EXACTLY: predictors/boltz2.py declares a
                // band under each of those names. Spelled out here rather than
                // taken from Stage.rawValue so the contract lives on RayMol's side
                // of the boundary, where the band table it must match also lives.
                let phase: String
                switch progress.stage {
                case .trunk: phase = "trunk"
                case .diffusion: phase = "diffusion"
                }
                // Stage-LOCAL: status()['fraction'] is completion within the phase,
                // and Python's compose_progress maps it into that phase's band.
                let fraction = progress.fraction
                guard throttle.shouldEmit(
                    stage: phase, fraction: fraction,
                    isFinal: progress.completed >= progress.total,
                    now: ProcessInfo.processInfo.systemUptime) else { return }
                Self.reportStep(to: statusURL, phase: phase, fraction: fraction,
                                step: progress.completed, totalSteps: progress.total)
            }
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
                                                        options: options,
                                                        onProgress: onProgress) })
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Self.awaitSyncValue { await predictor.memorySnapshot().peakMemory }

            if isCancelled() {
                settle("cancelled", "inference"); return
            }
            report("running", "write", 0.95)
            // pLDDT into the B-factor column, which is what `spectrum b` colours by.
            let text = try StructureWriter.pdb(structure: scored.structure,
                                              canonical: canonical,
                                              plddt: scored.plddt)
            try text.write(to: URL(fileURLWithPath: request.outPath),
                           atomically: true, encoding: .utf8)
            // What this run MEASURED, beside the structure it measured (#308). Written
            // BEFORE the load below, because `deliver_result` reads it as part of
            // loading: a file that appeared afterwards would leave the run recorded
            // with its provenance and cost and none of its confidence numbers.
            Self.writeMetrics(request: request, scored: scored, canonical: canonical)
            // Load BEFORE reporting done: predict_status returning done should already
            // imply the object is populated, or a script that polls then reads the object
            // races the load.
            Self.loadResult(request)
            report("done", "done", 1.0, result: request.outPath)
        } catch is CancellationError {
            settle("cancelled", "inference")
        } catch {
            // Failed, carrying the message — and NOT retried without the alignment.
            // Upstream Boltz silently substitutes a dummy MSA when an a3m does not match
            // its chain, so every score it then reports describes the wrong complex with
            // nothing saying so. boltz-mlx throws instead, on purpose; retrying here
            // would undo that and reintroduce the exact failure it was written to
            // prevent.
            settle("failed", "inference", error: Self.message(for: error))
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

    /// Record the memory position around a fold, on the `com.raymol.predict` subsystem.
    ///
    /// Exists because the numbers this feature is governed by cannot be obtained any other
    /// way on a phone. `PredictSizeGuard`'s whole iOS fit is reasoned against what
    /// `os_proc_available_memory()` actually reports on the device, and the way that
    /// question gets answered wrongly is by nobody ever asking it — the guard's three
    /// recorded failures were all fits nobody checked against a measurement. A jetsam kill
    /// also leaves no crash log worth reading, so the LAST line logged before a
    /// disappearance is frequently the only evidence of what the run was asking for.
    ///
    /// Logged rather than asserted: this is diagnostic, it must never change behaviour,
    /// and `os_log` survives the process being killed where a `print` to a detached
    /// stdout does not. Cheap enough to leave in shipping builds — twice per fold.
    static func logMemory(_ marker: String, jobID: String) {
        let footprint = MLXRuntime.currentFootprintBytes
        #if os(iOS)
        let available = os_proc_available_memory()
        #else
        let available = 0
        #endif
        let mb = { (b: Int) in b / (1024 * 1024) }
        Logger(subsystem: "com.raymol.predict", category: "memory")
            .log("predict \(marker, privacy: .public) job=\(jobID, privacy: .public) footprint=\(mb(footprint), privacy: .public)MiB available=\(mb(available), privacy: .public)MiB cacheLimit=\(mb(MLXRuntime.activeCacheLimitBytes), privacy: .public)MiB")
    }

    /// The memory plan handed to `BoltzPredictor`, per platform.
    ///
    /// In both arms `cacheLimit` is pinned to whatever ``MLXRuntime`` has arbitrated,
    /// because `MemoryPlanner.apply()` assigns `MLX.Memory.cacheLimit` on **every**
    /// predict call. Passing the arbitrated value makes that assignment re-assert the
    /// agreed ceiling rather than substitute boltz-mlx's own default and quietly
    /// out-vote the min-wins registry.
    ///
    /// **macOS — `.desktop` limits.** boltz-mlx's default preset is phone-sized (256
    /// tokens, 2 048 atoms, 1 024 MSA rows) and would refuse anything real on a Mac.
    ///
    /// **iOS — the phone preset, explicitly.** `BoltzInputLimits` has no `.phone`
    /// static; the phone numbers ARE `MemoryPlanner`'s defaults, so they are written out
    /// here rather than obtained by omitting arguments — an upstream change to those
    /// defaults should be a visible diff, not a silent change to what an iPhone will
    /// accept. 2 048 atoms is the binding limit in practice, not the 256 tokens: a
    /// single-chain protein runs about 7.7 atoms per residue, so ~265 residues reaches
    /// the atom cap first. Both sit above ``PredictSizeGuard/iOSMaximumTokens``, which is
    /// the gate that actually decides, and this is the belt to its braces — it refuses
    /// inside the runtime if anything ever reaches here ungated.
    ///
    /// `memoryLimit` is the substantive iOS change: see
    /// ``BoltzRuntime/memoryLimitBytes`` for why a 6 GB default cannot fire on a phone.
    private static var memoryPlanner: MemoryPlanner {
        #if os(iOS)
        return MemoryPlanner(
            limits: BoltzInputLimits(maximumTokens: 256, maximumAtoms: 2_048,
                                     maximumMSADepth: 1_024),
            memoryLimit: BoltzRuntime.memoryLimitBytes,
            cacheLimit: MLXRuntime.activeCacheLimitBytes)
        #else
        return MemoryPlanner(limits: .desktop,
                             cacheLimit: MLXRuntime.activeCacheLimitBytes)
        #endif
    }

    /// Reuses the loaded predictor when the weights directory is unchanged.
    private func loadedPredictor(directory: String) throws -> BoltzPredictor {
        try stateQueue.sync {
            if let existing = predictor, predictorDirectory == directory { return existing }
            let built = try BoltzRuntime.withMLXErrorsAsThrows {
                try BoltzPredictor(modelDirectory: URL(fileURLWithPath: directory),
                                   memoryPlanner: Self.memoryPlanner)
            }
            predictor = built
            predictorDirectory = directory
            return built
        }
    }
}
#endif
