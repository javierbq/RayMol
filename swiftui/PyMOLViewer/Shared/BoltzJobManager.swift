#if os(macOS) || os(iOS)
import BoltzMLX
import Foundation
import os

/// Runs the `boltz` inference runtime: Boltz predictions on behalf of Python, and the
/// runtime a request that names none is routed to.
///
/// The job SHELL — the wire format, atomic status writes, the write-then-discard settle
/// ordering, placeholder discard and result autoload — is ``InferenceJob``, and the
/// `PREDICT:` marker is ``InferenceRouter``'s. What is here is only what is Boltz's: its
/// featurizer, its weights, its size model and its metrics.
///
/// Because the Python API is a job handle, nothing here needs to return a value to
/// Python: status and result are files that Python polls. That is what makes the missing
/// Python→Swift bridge direction unnecessary rather than something to build.
final class BoltzJobManager: InferenceRuntime {

    static let shared = BoltzJobManager()

    /// The one inference runtime this manager implements, as it appears on the wire.
    /// Kept in step with `pymol.predictors.boltz2.RUNTIME`, and with the value
    /// `PyMOLBridge` advertises in `RAYMOL_PREDICT_RUNTIMES` — that variable is what lets
    /// a predictor whose backend is NOT linked here refuse in `check_available` instead
    /// of submitting a job that only gets refused after a weight download.
    static let runtimeName = "boltz"

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

    // MARK: - InferenceRuntime

    /// Refuse or accept a submitted request. Runs on the MAIN thread, called by
    /// ``InferenceRouter``.
    ///
    /// Nothing here decides which runtime a request belongs to any more: the router does
    /// that, and reaching this method means either the request named `boltz`, named nothing
    /// (which means `boltz`), or named a runtime this build does not carry. `preflight`
    /// still refuses the third case BY NAME — that is how a Python side offering a method
    /// this build did not link gets a real error instead of a job that never reports.
    func submit(_ request: InferenceJob.Request) {
        if let failure = Self.preflight(request) {
            // Refused before any work: the placeholder Python just created will never
            // be filled, so drop it rather than leaving an empty stub behind.
            InferenceJob.settle(request, failure,
                                to: URL(fileURLWithPath: request.statusPath))
            return
        }
        queue.async { self.run(request) }
    }

    /// Note a cancel. Idempotent, and safe for a job id this manager never had — the
    /// marker carries no runtime, so cancels are broadcast to every runtime and each
    /// keeps only its own.
    ///
    /// Cancels the live TASK, because that is what actually interrupts compute, and
    /// records the request for the coarse phase checks (a cancel can arrive before the
    /// task is registered). Cancels for jobs already in a terminal state are ignored, so
    /// `cancelled` cannot grow without bound from stray or post-completion markers.
    func cancel(jobID: String) {
        stateQueue.sync {
            if let task = runningTasks[jobID] {
                cancelled.insert(jobID)
                task.cancel()
            } else if !InferenceJob.hasTerminalStatus(jobID: jobID) {
                cancelled.insert(jobID)
            }
        }
    }

    // MARK: - Preflight


    /// Refuse before allocating anything. Returns nil when the run may proceed.
    ///
    /// Sees only what the REQUEST says, because it runs on the main thread from
    /// `pollFeedback`: the alignment's real depth costs a parse of the a3m, which
    /// belongs on the inference queue. `alignmentPreflight` makes that second check.
    static func preflight(_ request: InferenceJob.Request) -> InferenceJob.Status? {
        // Runtime first, before any sizing: the size model below is Boltz's, fitted to
        // Boltz's measured peaks, so applying it to another method's request would be
        // meaningless even as a refusal. Absent means Boltz, per
        // `InferenceJob.Request.runtime`.
        if let runtime = request.runtime, runtime != runtimeName {
            return InferenceJob.refusal(
                "this build of RayMol does not carry the '\(runtime)' inference runtime")
        }
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .refuseDepth:
            // Unreachable: this call passes no depth, so it defaults to 1. Handled
            // rather than defaulted away so that adding a depth here cannot silently
            // become "proceed".
            return InferenceJob.refusal("the alignment is too large for this machine")
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
            return InferenceJob.refusal(
                "input of \(tokens) residues is too large for this machine; "
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
    static func alignmentPreflight(_ request: InferenceJob.Request,
                                   alignments: [String: MSAAlignment])
        -> InferenceJob.Status?
    {
        guard let deepest = alignments.values.map(\.depth).max(), deepest > 1 else {
            return nil
        }
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens, msaDepth: deepest,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .ok, .warn:
            return nil
        case let .refuseDepth(maxFittingDepth):
            return InferenceJob.refusal(
                maxFittingDepth >= 1
                    ? "an alignment \(deepest) rows deep is too large for this machine "
                    + "at \(tokens) residues; retry with msa_depth=\(maxFittingDepth)"
                    : "\(tokens) residues with an alignment is too large for this "
                    + "machine")
        case let .refuse(maxFittingTokens):
            return InferenceJob.refusal(
                "input of \(tokens) residues is too large for this machine; "
                + "at most about \(maxFittingTokens) fit")
        }
    }

    // MARK: - Metrics

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
    private static func writeMetrics(request: InferenceJob.Request,
                                     scored: ScoredStructure,
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
        try? InferenceJob.writeStatus(
            InferenceJob.Status(state: "running", phase: phase, fraction: fraction,
                                error: nil, resultPath: nil, peakBytes: nil,
                                elapsedSeconds: nil,
                                step: step, totalSteps: totalSteps),
            to: url)
    }

    private func run(_ request: InferenceJob.Request) {
        let statusURL = URL(fileURLWithPath: request.statusPath)
        // Captured by report() below; filled in once inference completes.
        var peak: Int? = nil
        var footprint: Int? = nil
        var elapsed: Double? = nil
        func report(_ state: String, _ phase: String, _ fraction: Double,
                    error: String? = nil, result: String? = nil) {
            try? InferenceJob.writeStatus(
                InferenceJob.Status(state: state, phase: phase, fraction: fraction,
                                    error: error, resultPath: result,
                                    peakBytes: peak, footprintBytes: footprint,
                                    elapsedSeconds: elapsed),
                to: statusURL)
        }
        func isCancelled() -> Bool {
            stateQueue.sync { cancelled.contains(request.jobID) }
        }
        func settle(_ state: String, _ phase: String, error: String? = nil) {
            InferenceJob.settle(
                request,
                InferenceJob.Status(state: state, phase: phase, fraction: 0,
                                    error: error, resultPath: nil,
                                    peakBytes: peak, footprintBytes: footprint,
                                    elapsedSeconds: elapsed),
                to: statusURL)
        }

        report("running", "featurize", 0.0)
        Self.logMemory("start", jobID: request.jobID)
        let sampler = Self.FootprintSampler()
        sampler.start()
        // Pin the display for the whole run, taken HERE rather than left to the view
        // layer: the view learns about a job only through the ~500 ms object-panel poll,
        // and a fold has been observed freezing at diffusion step 42 because the phone
        // locked inside that window. See PredictScreenAwake.setJobActive.
        PredictScreenAwake.setJobActive(true)
        defer {
            PredictScreenAwake.setJobActive(false)
            sampler.stop()
            Self.logMemory("end", jobID: request.jobID)
        }
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
                InferenceJob.settle(request, failure, to: statusURL)
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
            let throttle = InferenceJob.StepThrottle()
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
            // Read at the same moment as the MLX peak, before anything is released, so
            // the two describe the same instant.
            footprint = max(sampler.peak, MLXRuntime.currentFootprintBytes)

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
            InferenceJob.loadResult(request)
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
    static func loadAlignments(_ request: InferenceJob.Request) throws
        -> [String: MSAAlignment]
    {
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

    /// Samples `phys_footprint` on a timer and keeps the maximum seen.
    ///
    /// Exists because neither number recorded before it is the peak the OS kills on.
    /// MLX's own high-water mark excludes its buffer cache, and a single `phys_footprint`
    /// read taken after `memorySnapshot()` is a POST-RELEASE reading — measured at 1.05 GB
    /// for both a 110- and a 164-residue fold whose MLX peaks were 1.38 and 2.00 GB, which
    /// is how you can tell it is not measuring the peak of anything. Only sampling
    /// throughout gives the quantity `os_proc_available_memory()` is denominated in, and
    /// therefore the only quantity ``PredictSizeGuard``'s budget comparison is actually
    /// about.
    ///
    /// 200 ms and a plain background thread: inference runs tens of seconds, so a few
    /// hundred samples is ample resolution, and a `task_info` call is a syscall costing
    /// microseconds. Deliberately not a DispatchSourceTimer on the shared queue — the
    /// point is to keep sampling while that queue is saturated by inference.
    final class FootprintSampler {
        private let lock = NSLock()
        private var _peak = 0
        private var running = true

        var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }

        func start() {
            Thread.detachNewThread { [weak self] in
                while true {
                    guard let self else { return }
                    self.lock.lock()
                    let go = self.running
                    if go { self._peak = max(self._peak, MLXRuntime.currentFootprintBytes) }
                    self.lock.unlock()
                    if !go { return }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }

        func stop() { lock.lock(); running = false; lock.unlock() }
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
