#if os(macOS)
import Foundation
import MLX
import RFD4Core
import RFD4MLX

/// Runs the `rfd4` runtime: RFD4-Proteina, the second backbone generator behind a RayMol
/// command and the first that generates its target rather than holding it fixed.
///
/// The job SHELL is ``InferenceJob`` — request decoding, atomic status writes, the
/// write-then-discard settle ordering, placeholder discard and result autoload are its
/// static helpers, used here rather than reimplemented. The PDB EMITTER is
/// ``RFD3ResultWriter/emit(target:designChain:designResidues:designSequence:remarks:extraRecords:)``,
/// reused rather than copied: despite the name it imports nothing from RFD3Kit and holds
/// nothing method-specific, it simply writes the supplied target verbatim followed by a
/// generated chain. What IS RFD3-specific in that file is `compose` and `recoverOffset`,
/// which undo RFdiffusion3's translated frame and its argmax-renamed target — and neither
/// applies here, because ``RFD4Design`` has already put everything back in the caller's
/// frame and never renames the target.
///
/// ## What differs from RFD3JobManager, and why
///
/// * **The target is GENERATED.** RFD3 masks the target out of the noise and reproduces it
///   atom-for-atom, so `RFD3JobManager` can refuse a run whose `targetDriftMaxA` exceeds a
///   0.25 Å tolerance — the target is held fixed by contract and any movement is a defect.
///   Here the target is entered centred and randomly rotated and the model must place it,
///   so a small rebuild error is the CORRECT result. The equivalent check is a much looser
///   sanity bound (``maxRebuildRMSDAngstrom``) that separates "recovered the frame" from
///   "did not", and the number is reported under its own metric key rather than RFD3's.
/// * **Sizing is in TOKENS, not atoms.** One residue is one token here. See
///   ``RFD4SizeGuard``.
/// * **There is no live view.** `RFD4Design`'s step hook reports `(step, trunk passes)` and
///   no coordinates, so there is nothing to stream. The whole playback-head apparatus in
///   `RFD3JobManager` is therefore absent rather than stubbed; adding it means a new hook
///   in the port.
/// * **Cancellation is a poll, not a `Task`.** `RFD4Design.run` is synchronous, so there is
///   no task to cancel; `Options.shouldCancel` is checked once per flow step and throws
///   `GenerationCancelled`, which is a distinct type precisely so "the user pressed Cancel"
///   does not get reported as a failure.
final class RFD4JobManager: InferenceRuntime {

    static let shared = RFD4JobManager()

    /// The runtime this manager implements, as it appears on the wire. Kept in step with
    /// `pymol.generators.rfd4.RUNTIME` and with what `PyMOLBridge` advertises in
    /// `RAYMOL_PREDICT_RUNTIMES`.
    static let runtimeName = "rfd4"

    /// The Python surface that owns this runtime's placeholders and metric records. The
    /// same one `rfd3` uses: both are generators, and `pymol.designing` is the generator
    /// surface.
    static let pythonModule = "designing"

    /// The released schedule, fixed at 60 flow steps.
    ///
    /// Taken from the port rather than from `request.diffusionSteps`, and that is the
    /// point: every released `thinking` strategy is DEFINED over a 60-step trajectory and
    /// its recycle bands are indexed against those steps, so the count is not a knob. The
    /// Python side sends `diffusion_steps` only because `Request` decodes it as a
    /// non-optional Int; reading it here would let a stale or hand-written request
    /// misreport the progress denominator.
    static var flowSteps: Int { ReleasedRecycleStrategy.nsteps }

    /// The recycle schedule a design runs. `thinkingMedium` — 180 trunk passes over the
    /// 60 steps, against `thinkingLow`'s 120 and `thinkingHigh`'s 300.
    ///
    /// Not a request field, because the Python side has no option for it: `DesignOptions`
    /// carries three fixed slots and none of them can hold an enum, and a per-generator
    /// attribute could not enter `design_key` — which it must, since changing it changes
    /// the coordinates. Exposing it is a shared-code change, and until then one declared
    /// default here is better than a second undeclared one at the far end.
    static let strategy: ReleasedRecycleStrategy = .thinkingMedium

    /// How far the rebuilt target may sit from the supplied one before the design is
    /// refused.
    ///
    /// **This is not RFD3's 0.25 Å drift tolerance and must not be read as one.** There the
    /// target is reproduced atom-for-atom and the measured value is 0.000 Å across every
    /// benchmarked run, so the tolerance is tight because any movement is a bug. Here the
    /// target is generated from its conditioning in a frame the model chose, so a non-zero
    /// value is expected and the question is categorical rather than quantitative: did the
    /// superposition recover the frame at all, or is the design placed against something
    /// that is not the selected structure?
    ///
    /// 5 Å is the bound the port's own end-to-end test uses for exactly that question, and
    /// it is deliberately wide. A failed recovery puts the rebuilt target tens of Ångström
    /// away, so this separates the two outcomes with room to spare rather than trimming a
    /// noisy but correct run — which, for a design that cost minutes, is the error to
    /// avoid.
    static let maxRebuildRMSDAngstrom = 5.0

    /// MLX must never run on the main thread; the command arrives ON it. Serial, so two
    /// designs cannot both hold the peak transient — the guard sizes one design, not two.
    private let queue = DispatchQueue(label: "io.raymol.design.rfd4", qos: .userInitiated)
    /// Guards `cancelled`, which the design thread reads and the main thread writes.
    private let stateQueue = DispatchQueue(label: "io.raymol.design.rfd4.state")
    private var cancelled = Set<String>()

    /// One loaded pack per weights directory, so a second design does not re-read 871 MB.
    /// Touched only from `queue`.
    private var loaded: [String: Generator] = [:]

    private init() {}

    /// Test seam, matching `RFD3JobManager`'s and `DesignController`'s injection pattern.
    /// UNGATED, like those: a `#if DEBUG` here would not compile against a Release app
    /// host.
    var cancelRequestedForTesting: Set<String> { stateQueue.sync { cancelled } }

    // MARK: InferenceRuntime

    /// Refuse or accept a submitted request. Runs on the MAIN thread.
    ///
    /// Only the request's SHAPE is judged here. The size refusal is on the worker, because
    /// it needs the decoded target array — and the main thread is the one that renders and
    /// drains PyMOL's feedback buffer. It is still before any GPU work and before the pack
    /// load, which is the property that matters.
    func submit(_ request: InferenceJob.Request) {
        if let failure = Self.preflight(request) {
            InferenceJob.settle(request, failure,
                                to: URL(fileURLWithPath: request.statusPath),
                                pythonModule: Self.pythonModule)
            return
        }
        queue.async { self.run(request) }
    }

    /// Note a cancel. Idempotent, and safe for a job id this manager never had — the
    /// marker carries no runtime, so cancels are broadcast to every manager and each keeps
    /// only its own ids.
    func cancel(jobID: String) {
        stateQueue.sync {
            guard !InferenceJob.hasTerminalStatus(jobID: jobID) else { return }
            cancelled.insert(jobID)
        }
    }

    /// Refuse on what the request alone says, before allocating anything.
    ///
    /// Every check here is one the engine would NOT make. Its featurizer skips a residue it
    /// has no atom template for while the hotspot positions keep counting, so one
    /// unreadable residue silently shifts which residues the design is aimed at; and it
    /// designs happily against an empty target. The Python side refuses all of this first,
    /// so reaching any of these is a bug or a version skew rather than a user error — which
    /// is exactly why it is checked twice.
    static func preflight(_ request: InferenceJob.Request) -> InferenceJob.Status? {
        guard request.runtime == runtimeName else {
            // Unreachable through the router, which dispatches on this very field. Handled
            // rather than asserted so a future caller cannot quietly run another method's
            // request through this featurizer.
            return InferenceJob.refusal(
                "this request is for the '\(request.runtime ?? "boltz")' runtime, not"
                + " '\(runtimeName)'")
        }
        guard let target = request.target, !target.isEmpty else {
            return InferenceJob.refusal(
                "a backbone design needs a target structure, and this request carries"
                + " none")
        }
        guard let length = request.designLength, length >= 1 else {
            return InferenceJob.refusal(
                "a backbone design needs a length of at least 1 residue")
        }
        if let empty = target.first(where: { $0.atoms.isEmpty }) {
            return InferenceJob.refusal(
                "target residue \(empty.chain)/\(empty.resi) has no atoms")
        }
        // NO FLOOR ON HOTSPOTS. An empty set is unguided placement, which the featurizer
        // supports directly. Only the indices that ARE sent are bounds-checked.
        let hotspots = request.hotspots ?? []
        if let bad = hotspots.first(where: { $0 < 0 || $0 >= target.count }) {
            return InferenceJob.refusal(
                "hotspot index \(bad) is outside the \(target.count)-residue target")
        }
        return nil
    }

    // MARK: Generation

    private func run(_ request: InferenceJob.Request) {
        let statusURL = URL(fileURLWithPath: request.statusPath)
        var peak: Int? = nil
        var elapsed: Double? = nil
        let throttle = InferenceJob.StepThrottle()

        func report(_ state: String, _ phase: String, _ fraction: Double,
                    error: String? = nil, result: String? = nil,
                    step: Int? = nil, totalSteps: Int? = nil) {
            var status = InferenceJob.Status(
                state: state, phase: phase, fraction: fraction, error: error,
                resultPath: result, peakBytes: peak, elapsedSeconds: elapsed)
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

        // BEFORE any work at all. `submit` enqueues every design of an `n_designs` batch
        // at once and this queue is SERIAL, so later designs sit here for a long time;
        // when the tray's one Cancel stops the batch, each of those must fall out
        // immediately rather than featurizing a target it will never design against.
        if isCancelled() {
            settle(cancelledStatus(phase: "queued")); return
        }

        guard let wireTarget = request.target, let length = request.designLength else {
            // preflight already refused this; belt and braces so `run` has no optionals to
            // force-unwrap.
            settle(InferenceJob.refusal("malformed design request"))
            return
        }

        report("running", "featurize", 0.0)
        do {
            RFD4Runtime.configureOnce()

            let target = wireTarget.map { residue in
                RFD4Design.TargetResidue(
                    // The residue NAME is carried; the chain id and number are not, and
                    // that is the engine's contract rather than an omission. It renumbers
                    // the target 1..k per run and identifies residues by POSITION, so the
                    // session's own identifiers never enter the model — which is what
                    // lets insertion codes survive. They are put back by the emitter,
                    // from `wireTarget`, index-aligned to this array.
                    name: residue.resn,
                    atoms: residue.atoms.compactMap { atom in
                        guard atom.xyz.count == 3 else { return nil }
                        return RFD4Design.Atom(
                            name: atom.name,
                            xyz: Vec3(Float(atom.xyz[0]), Float(atom.xyz[1]),
                                      Float(atom.xyz[2])))
                    })
            }

            var options = RFD4Design.Options(designLength: length)
            options.hotspots = request.hotspots ?? []
            options.seed = request.seed
            options.strategy = Self.strategy

            // BEFORE the pack is read, and before any GPU work. An over-large design must
            // not cost the user an 871 MB load, and above all it must be refused rather
            // than run: an out-of-memory here is a `std::terminate` from a Metal
            // completion handler that no `catch` can intercept, and on macOS it takes the
            // unsaved session with it.
            let tokens = RFD4Design.tokenCount(target: target, designLength: length)
            let budget = RFD4SizeGuard.budgetBytes
            if case let .refuse(tokens, predicted, budgetBytes, maxTokens)
                = RFD4SizeGuard.decide(tokens: tokens, budgetBytes: budget) {
                settle(InferenceJob.refusal(
                    RFD4SizeGuard.refusalMessage(tokens: tokens,
                                                 predictedBytes: predicted,
                                                 budgetBytes: budgetBytes,
                                                 maxTokens: maxTokens)))
                return
            }

            // Everything the engine would quietly reinterpret, refused with the engine's
            // own messages — an unreadable residue, a hotspot out of range, a target too
            // fragmented for the contig's chain ids. Weight-free by construction, so this
            // too happens before the pack load.
            //
            // Caught HERE rather than left to the outer `catch`, so the refusal is
            // reported against the phase it actually happened in. Falling through would
            // label a rejected target as a failure in "sample", which is a phase this run
            // never reached — and the progress card shows that name to the user.
            do {
                try RFD4Design.preflight(target: target, options: options)
            } catch {
                settle(InferenceJob.Status(
                    state: "failed", phase: "featurize", fraction: 0,
                    error: String(describing: error), resultPath: nil,
                    peakBytes: nil, elapsedSeconds: nil))
                return
            }

            if isCancelled() {
                settle(cancelledStatus(phase: "featurize")); return
            }

            report("running", "load", 0.02)
            let generator = try loadedGenerator(directory: request.weightsDir)

            report("running", "sample", 0.06)
            // Reset the high-water mark so each design is measured independently rather
            // than reporting the largest run this process has ever done.
            Memory.peakMemory = 0
            let started = Date()

            let totalSteps = Self.flowSteps
            // NOT routed through `report`. `onStep` is `@Sendable` -- the port declares
            // it so, because `Options` is Sendable -- and `report` is a local function
            // closing over the mutable `peak` and `elapsed`, which a @Sendable closure
            // may not capture. Writing the status here from immutable captures only
            // (`statusURL`, `totalSteps`, and `throttle`, which is `@unchecked
            // Sendable`) is the same write with the same fields: during sampling `peak`
            // and `elapsed` are not yet known, so `report` would send nil for both
            // anyway.
            options.onStep = { step, _ in
                // `step` is the sampler's own index over the 60-step trajectory. The
                // second argument is the recycle depth for that step, which is motion
                // within a step rather than progress through the run, so it is not part
                // of the fraction.
                let fraction = totalSteps > 0
                    ? Double(step + 1) / Double(totalSteps) : 0
                guard throttle.shouldEmit(stage: "sample", fraction: fraction,
                                          isFinal: step + 1 >= totalSteps,
                                          now: ProcessInfo.processInfo.systemUptime)
                else { return }
                var status = InferenceJob.Status(
                    state: "running", phase: "sample", fraction: fraction, error: nil,
                    resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
                status.step = step + 1
                status.totalSteps = totalSteps
                try? InferenceJob.writeStatus(status, to: statusURL)
            }
            // The only cancellation point there is: `RFD4Design.run` is synchronous, so
            // there is no Task to cancel. Polled per flow step, so the worst case is one
            // step — of a run whose steps are seconds each on a real target.
            options.shouldCancel = { [weak self] in
                guard let self else { return false }
                return self.stateQueue.sync { self.cancelled.contains(request.jobID) }
            }

            let design = try RFD4Runtime.withMLXErrorsAsThrows {
                try RFD4Design.run(generator, target: target, options: options)
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Memory.peakMemory

            report("running", "write", 0.96)
            // DID THE SUPERPOSITION RECOVER THE FRAME? Checked rather than trusted,
            // because a failed recovery is invisible downstream: the object is a
            // well-formed complex whose design sits in the wrong pose, and nothing after
            // this point can tell. See `maxRebuildRMSDAngstrom` for why the bound is wide
            // and why it is NOT RFD3's drift tolerance.
            guard design.stats.targetRebuildRMSDA <= Self.maxRebuildRMSDAngstrom else {
                settle(InferenceJob.Status(
                    state: "failed", phase: "write", fraction: 0,
                    error: String(format:
                        "the rebuilt target sits %.3f A from the target supplied"
                        + " (limit %.3f A), so the frame the design was generated in"
                        + " could not be recovered. The design's position is only"
                        + " meaningful relative to the target, so it is refused rather"
                        + " than emitted in a pose that cannot be trusted.",
                        design.stats.targetRebuildRMSDA,
                        Self.maxRebuildRMSDAngstrom),
                    resultPath: nil, peakBytes: peak, elapsedSeconds: elapsed))
                return
            }

            // The target is emitted from the ORIGINAL atoms -- every atom, sidechains
            // included, with its own chain id, numbering and insertion codes -- and the
            // design has already been carried into that same frame by the engine's
            // superposition. `design.rebuiltTarget` is deliberately NOT used: it is the
            // model's reconstruction, and the caller's own coordinates are exact.
            let composed = try RFD3ResultWriter.emit(
                target: wireTarget,
                designChain: request.designChain ?? "B",
                designResidues: design.designResidues.map { atoms in
                    atoms.map { RFD3ResultWriter.Atom(
                        name: $0.name,
                        xyz: SIMD3(Double($0.xyz.x), Double($0.xyz.y),
                                   Double($0.xyz.z))) }
                },
                designSequence: design.designSequence,
                remarks: Self.remarks(request: request, design: design))
            try composed.pdb.write(to: URL(fileURLWithPath: request.outPath),
                                   atomically: true, encoding: .utf8)
            Self.writeMetrics(request: request, geometry: Geometry(design.stats))
            // Load BEFORE reporting done, so a script that polls then reads the object
            // does not race the load.
            InferenceJob.loadResult(request, pythonModule: Self.pythonModule)
            report("done", "done", 1.0, result: request.outPath)
        } catch is GenerationCancelled {
            // A DISTINCT type, caught before the general arm, which is the whole reason
            // the port throws one: a cancelled design is not a failed design, and
            // reporting it as one puts a red error card in front of someone who pressed
            // Cancel.
            settle(cancelledStatus(phase: "sample"))
        } catch {
            // `String(describing:)` rather than `localizedDescription`: RFD4's own errors
            // conform to LocalizedError, but this path also carries MLX and Foundation
            // errors that do not, and for those the localized form is the useless generic
            // fallback.
            settle(InferenceJob.Status(
                state: "failed", phase: "sample", fraction: 0,
                error: String(describing: error), resultPath: nil,
                peakBytes: peak, elapsedSeconds: elapsed))
        }
    }

    private func cancelledStatus(phase: String) -> InferenceJob.Status {
        InferenceJob.Status(state: "cancelled", phase: phase, fraction: 0,
                            error: nil, resultPath: nil, peakBytes: nil,
                            elapsedSeconds: nil)
    }

    /// Provenance written into the structure itself, so it survives an export.
    ///
    /// A design's identity is what a later refold is keyed to, and a PDB saved out of the
    /// session otherwise carries nothing that says which design it is. The metric record
    /// holds the same key; this is the copy that leaves RayMol with the file.
    static func remarks(request: InferenceJob.Request,
                        design: RFD4Design.Result) -> [String] {
        var lines = ["GENERATED BY RAYMOL / RFD4-Proteina (MLX, fp16)"]
        if let key = request.designKey, !key.isEmpty {
            lines.append("DESIGN KEY \(key)")
        }
        lines.append("DESIGNED CHAIN \(request.designChain ?? "B")")
        lines.append("DESIGNED SEQUENCE \(design.designSequence)")
        lines.append("SEED \(request.seed)  FLOW STEPS \(flowSteps)"
                     + "  SCHEDULE \(strategy.rawValue)")
        // Said precisely, because the obvious reading of this line is RFD3's and it is
        // the wrong one: this model generates its target, so the number is a measure of
        // conditioning fidelity rather than of a contract violation.
        lines.append("TARGET REBUILT, NOT HELD FIXED; REBUILD RMSD "
                     + String(format: "%.3f A", design.stats.targetRebuildRMSDA))
        // Says what has NOT been done, without using the word the naming rule reserves.
        // Worth carrying in the file itself: a PDB exported from here otherwise looks
        // exactly like a validated result to whoever opens it next.
        lines.append("THIS CHAIN WAS GENERATED, NOT VALIDATED: IT HAS NOT BEEN REFOLDED"
                     + " AND NO INTERFACE HAS BEEN SCORED")
        return lines
    }

    /// What a design measured, in RAYMOL's vocabulary.
    ///
    /// A translation layer over `RFD4Design.Stats`, earning its place the same two ways
    /// `RFD3JobManager.Geometry` does: it is where any upstream name carrying "binder"
    /// would be renamed, and it is what makes the metric document testable without a
    /// loaded pack.
    ///
    /// The key names are declared on the other side too, in
    /// `modules/pymol/generators/metrics.py` (`RFD4_GEOMETRY_SPECS`). A key written here
    /// and not declared there is dropped silently by the metric store, so
    /// `RFD4RuntimeTests` pins the set.
    struct Geometry {
        let designCACAMean: Double
        let backboneValidPercent: Double
        let designRadiusOfGyration: Double
        /// nil when neither chain presented a CA to measure between. Written as no metric
        /// at all rather than as 0.0, which for a distance would read as a total clash in
        /// a design that has none.
        let interfaceMinDistance: Double?
        let contactsUnder8A: Int
        /// nil on an UNGUIDED run, for the same reason: a missing metric is honest, and a
        /// 0.0 on a `higher_is_better=false` distance is the best possible score recorded
        /// for a thing that was never measured.
        let hotspotMinDistance: Double?
        /// NOT `target_drift_max`. See `RFD4_GEOMETRY_SPECS` and
        /// ``maxRebuildRMSDAngstrom``.
        let targetRebuildRMSD: Double

        init(designCACAMean: Double, backboneValidPercent: Double,
             designRadiusOfGyration: Double, interfaceMinDistance: Double?,
             contactsUnder8A: Int, hotspotMinDistance: Double?,
             targetRebuildRMSD: Double) {
            self.designCACAMean = designCACAMean
            self.backboneValidPercent = backboneValidPercent
            self.designRadiusOfGyration = designRadiusOfGyration
            self.interfaceMinDistance = interfaceMinDistance
            self.contactsUnder8A = contactsUnder8A
            self.hotspotMinDistance = hotspotMinDistance
            self.targetRebuildRMSD = targetRebuildRMSD
        }

        /// Taken straight from the port's own `Stats`, which already reports both
        /// distances as optionals for the reason above — so there is no `isFinite ? x : 0`
        /// to undo here, unlike the RFD3 path.
        init(_ stats: RFD4Design.Stats) {
            self.init(designCACAMean: stats.designCACAMeanA,
                      backboneValidPercent: stats.backboneValidPct,
                      designRadiusOfGyration: stats.radiusOfGyrationA,
                      interfaceMinDistance: stats.interfaceMinA,
                      contactsUnder8A: stats.contactsUnder8A,
                      hotspotMinDistance: stats.hotspotMinA,
                      targetRebuildRMSD: stats.targetRebuildRMSDA)
        }

        /// One `pymol.metrics` value per number. State 1 throughout: each design is its
        /// own object with one state, and the Python side re-stamps the state it actually
        /// landed in anyway.
        var metricValues: [[String: Any]] {
            var values: [[String: Any]] = [
                ["key": "design_ca_ca_mean", "state": 1, "value": designCACAMean],
                ["key": "backbone_valid_pct", "state": 1, "value": backboneValidPercent],
                ["key": "design_radius_of_gyration", "state": 1,
                 "value": designRadiusOfGyration],
                ["key": "contacts_under_8a", "state": 1, "value": contactsUnder8A],
                ["key": "target_rebuild_rmsd", "state": 1, "value": targetRebuildRMSD],
            ]
            if let interfaceMinDistance {
                values.append(["key": "interface_min_distance", "state": 1,
                               "value": interfaceMinDistance])
            }
            if let hotspotMinDistance {
                values.append(["key": "hotspot_min_distance", "state": 1,
                               "value": hotspotMinDistance])
            }
            return values
        }
    }

    /// The geometry this run measured, as a `pymol.metrics` document.
    ///
    /// Only what the RUNTIME measures. The design's identity, its length and what it cost
    /// are written by `pymol.designing`, which knows them; elapsed time and peak memory
    /// already reach the store through the status file and must not be sent twice from two
    /// sources that could disagree.
    static func writeMetrics(request: InferenceJob.Request, geometry: Geometry) {
        guard let path = request.metricsPath, !path.isEmpty else { return }
        // `tool` is overridden on the Python side with the GENERATOR id: this runtime
        // knows its own name, not which generator selected it.
        let document: [String: Any] = [
            "tool": runtimeName,
            "object": request.objectName ?? "",
            "values": geometry.metricValues,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The generator for `directory`, loaded once.
    ///
    /// `Generator(weightsAtPathOrPack:)` takes either a pack directory or a bare
    /// safetensors and decides by what is on disk — RayMol always hands it a directory,
    /// because the weight cache extracts a bundle to `<root>/<id>/<version>/`.
    private func loadedGenerator(directory: String) throws -> Generator {
        if let cached = loaded[directory] { return cached }
        let generator = try Generator(weightsAtPathOrPack: directory)
        // One pack at a time: two 871 MB packs plus a design's peak transient is not a
        // budget RFD4SizeGuard sized for, and nothing switches packs mid-session today.
        loaded = [directory: generator]
        return generator
    }
}
#endif
