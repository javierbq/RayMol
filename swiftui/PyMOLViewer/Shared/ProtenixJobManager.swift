#if os(macOS)
import Foundation
import MLX
import ProtenixMLX

/// Runs the `protenix` inference runtime: the second backend behind `cmd.predict`.
///
/// The job SHELL is shared with ``BoltzJobManager`` — marker parsing, request decoding,
/// atomic status writes, placeholder discard and result autoload are its static helpers,
/// used here rather than reimplemented, because "the status file went missing on a
/// cancelled job" is the class of bug you only find in production. What is not shared is
/// everything inside `run`: the featurizer, the weights and the network are
/// method-specific, which is the whole reason a request has to name its runtime.
///
/// Three differences from the Boltz path are worth knowing:
///
/// * **Featurization happens here, in Swift.** Boltz's featurizer needs a
///   `CanonicalStructure`; Protenix's needs only the sequences, because the canonical-20
///   reference conformers ship inside `ProtenixMLX`. There is no CCD on the device.
/// * **Cancellation is a callback, not a `Task`.** `ProtenixPredictor.fold` is
///   synchronous, so there is no `Task` to cancel; instead the progress handler returns
///   false and the fold throws. That handler fires after every trunk recycle and every
///   diffusion step, which is finer than the Boltz path manages — its trunk has no
///   cancellation points at all.
/// * **Progress is real.** `FoldProgress.fraction` is weighted by measured phase cost, so
///   the reported fraction tracks the wall clock instead of jumping at phase boundaries.
final class ProtenixJobManager {

    static let shared = ProtenixJobManager()

    /// The runtime this manager implements, as it appears on the wire. Kept in step with
    /// `pymol.predictors.protenix.RUNTIME` and with what `PyMOLBridge` advertises in
    /// `RAYMOL_PREDICT_RUNTIMES`.
    static let runtimeName = "protenix"

    /// MLX must never run on the main thread; `cmd.predict` arrives ON it. Serial, so two
    /// folds cannot both hold a 3.9 GB peak — the guard sizes one run, not two.
    private let queue = DispatchQueue(label: "io.raymol.predict.protenix",
                                      qos: .userInitiated)
    /// Guards `cancelled`, which the inference thread reads and the main thread writes.
    private let stateQueue = DispatchQueue(label: "io.raymol.predict.protenix.state")
    private var cancelled = Set<String>()

    /// One loaded predictor per weights directory, so a second fold with the same pack
    /// does not re-read 214 MB. Touched only from `queue`.
    private var loaded: [String: ProtenixPredictor] = [:]

    private init() {}

    // MARK: Entry points, called by BoltzJobManager's marker routing

    /// Refuse or accept a submitted request. Runs on the MAIN thread.
    func submit(_ request: BoltzJobManager.Request) {
        if let failure = Self.preflight(request) {
            BoltzJobManager.discardPlaceholder(request)
            try? BoltzJobManager.writeStatus(
                failure, to: URL(fileURLWithPath: request.statusPath))
            return
        }
        queue.async { self.run(request) }
    }

    /// Note a cancel. Idempotent, and safe for a job id this manager never had — the
    /// marker carries no runtime, so cancels are broadcast to every manager and each
    /// keeps only its own.
    func cancel(jobID: String) {
        stateQueue.sync {
            guard !BoltzJobManager.hasTerminalStatus(jobID: jobID) else { return }
            cancelled.insert(jobID)
        }
    }

    /// Refuse before allocating anything, on what the request alone says.
    static func preflight(_ request: BoltzJobManager.Request) -> BoltzJobManager.Status? {
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch ProtenixSizeGuard.decide(tokens: tokens,
                                        availableBytes: PredictSizeGuard.availableBytes) {
        case .refuse(let maxFitting):
            return BoltzJobManager.refusal(
                "\(tokens) residues is too large for this machine; at most "
                + "\(maxFitting) fit")
        case .refuseDepth:
            // Unreachable: Protenix declares no msa_depth, so no request carries one.
            // Handled rather than defaulted away so that adding alignments later cannot
            // silently become "proceed".
            return BoltzJobManager.refusal("alignments are not supported by protenix")
        case .ok, .warn:
            // `.warn` proceeds, matching the Boltz path: the tier is not surfaced
            // anywhere yet, and inventing a caution channel for it here would be
            // speculative.
            return nil
        }
    }

    // MARK: Inference

    private func run(_ request: BoltzJobManager.Request) {
        let statusURL = URL(fileURLWithPath: request.statusPath)
        var peak: Int? = nil
        var elapsed: Double? = nil
        @Sendable func report(_ state: String, _ phase: String, _ fraction: Double,
                              error: String? = nil, result: String? = nil) {
            try? BoltzJobManager.writeStatus(
                BoltzJobManager.Status(state: state, phase: phase, fraction: fraction,
                                       error: error, resultPath: result,
                                       peakBytes: peak, elapsedSeconds: elapsed),
                to: statusURL)
        }
        func isCancelled() -> Bool {
            stateQueue.sync { cancelled.contains(request.jobID) }
        }

        report("running", "featurize", 0.0)
        do {
            ProtenixRuntime.configureOnce()

            // Featurized HERE, from sequence alone. The reference conformers are a
            // resource inside ProtenixMLX, so nothing on this machine needs the CCD.
            // Non-canonical residues throw rather than being folded as X — the Python
            // side refuses them first, so reaching this is a bug, not a user error.
            let bundle = try Featurizer.bundle(
                chains: request.chains.map {
                    Featurizer.Chain(id: $0.chain, sequence: $0.sequence)
                },
                name: request.objectName ?? "prediction")

            if isCancelled() {
                BoltzJobManager.discardPlaceholder(request)
                report("cancelled", "featurize", 0); return
            }

            report("running", "load", 0.05)
            let predictor = try loadedPredictor(directory: request.weightsDir)

            report("running", "inference", 0.1)
            // Reset the high-water mark so each fold is measured independently rather
            // than reporting the largest fold this process has ever run.
            Memory.peakMemory = 0
            let started = Date()

            // The progress handler is the ONLY cancellation point: fold() is synchronous,
            // so there is no Task to cancel. Returning false makes it throw. It fires per
            // trunk recycle and per diffusion step, so the worst case is one step rather
            // than the whole run — which is better than the Boltz path manages, where the
            // trunk cannot be interrupted at all.
            let prediction = try ProtenixRuntime.withMLXErrorsAsThrows {
                try predictor.foldScored(
                    bundle: bundle,
                    seed: request.seed,
                    recyclingSteps: request.recyclingSteps,
                    diffusionSteps: request.diffusionSteps,
                    progress: { [weak self] progress in
                        guard let self else { return true }
                        if self.stateQueue.sync(
                            execute: { self.cancelled.contains(request.jobID) })
                        {
                            return false
                        }
                        // Status is a file write per step. At 200 steps over minutes that
                        // is cheap next to a Pairformer pass, and it is what makes the
                        // panel's poll show motion instead of a frozen 10%.
                        report("running", progress.phase.rawValue,
                               0.1 + 0.85 * progress.fraction)
                        return true
                    })
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Memory.peakMemory

            report("running", "write", 0.95)
            // pLDDT into the B-factor column, which is what `spectrum b` colours by. The
            // scores are real here — Protenix's confidence head is ported and verified —
            // even though this branch's predictor declares no metric_specs yet, so the
            // per-residue array reaches the viewer through the PDB rather than the store.
            let text = StructureWriter.pdb(
                coordinates: prediction.coordinates,
                atoms: bundle.metadata.atoms,
                bFactors: prediction.scores?.plddt)
            try text.write(to: URL(fileURLWithPath: request.outPath),
                           atomically: true, encoding: .utf8)
            // Load BEFORE reporting done, so a script that polls then reads the object
            // does not race the load.
            BoltzJobManager.loadResult(request)
            report("done", "done", 1.0, result: request.outPath)
        } catch ProtenixError.cancelled {
            BoltzJobManager.discardPlaceholder(request)
            report("cancelled", "inference", 0)
        } catch {
            BoltzJobManager.discardPlaceholder(request)
            report("failed", "inference", 0,
                   error: (error as? LocalizedError)?.errorDescription
                       ?? error.localizedDescription)
        }
    }

    /// The predictor for `directory`, loaded once.
    private func loadedPredictor(directory: String) throws -> ProtenixPredictor {
        if let cached = loaded[directory] { return cached }
        let artifact = try ProtenixArtifact.load(from: URL(fileURLWithPath: directory))
        let predictor = try ProtenixPredictor(artifact: artifact)
        // One pack at a time: two 214 MB packs plus their activations is not a budget the
        // size guard sized for, and nothing switches packs mid-session today.
        loaded = [directory: predictor]
        return predictor
    }
}
#endif
