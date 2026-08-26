#if os(macOS)
import Foundation
import MLX
import RFD3Kit

/// Runs the `rfd3` runtime: the first BACKBONE GENERATOR behind a RayMol command, and the
/// first method here whose output did not exist as a sequence beforehand.
///
/// The job SHELL is ``InferenceJob`` — request decoding, atomic status writes, the
/// write-then-discard settle ordering, placeholder discard and result autoload are its
/// static helpers, used here rather than reimplemented. What is not shared is anything
/// method-specific, which for a generator is more than usual:
///
/// * **The input is a structure.** `Request.chains` is empty and `Request.target` carries
///   the residues, in the order the featurizer will tokenize them. Hotspots are POSITIONS
///   in that array, resolved on the Python side.
/// * **The output is composed, not copied.** See ``RFD3ResultWriter`` — the engine's PDB is
///   in a translated frame, renumbered, sidechain-free, and its target residue names are
///   the sequence head's argmax rather than the input's.
/// * **The result lands in `pymol.designing`, not `pymol.predicting`.** Two surfaces, two
///   pending tables; the shared helpers take the module name.
/// * **Cancellation is a poll, not a `Task`.** `designBinder` is synchronous, so there is
///   no task to cancel; `Options.shouldCancel` is checked once per diffusion step and once
///   after setup, and throws `RFD3ModelError.cancelled`. Needed rather than nice: a
///   full-length target is ~17 minutes per design.
final class RFD3JobManager: InferenceRuntime {

    static let shared = RFD3JobManager()

    /// The runtime this manager implements, as it appears on the wire. Kept in step with
    /// `pymol.generators.rfd3.RUNTIME` and with what `PyMOLBridge` advertises in
    /// `RAYMOL_PREDICT_RUNTIMES`.
    static let runtimeName = "rfd3"

    /// The Python surface that owns this runtime's placeholders and metric records.
    static let pythonModule = "designing"

    /// Capture one frame in this many diffusion steps when live view is on.
    ///
    /// Four gives ~50 frames from a 199-step run — about 1.7 s at 30 fps, enough to read
    /// as motion — against 199 round trips that would put roughly 1.2 MB of Python source
    /// through the main thread during a run that is already GPU-saturated.
    static let trajectoryStepInterval = 4

    /// The statement that creates the live object.
    ///
    /// It is created UNDER THE RESULT'S OWN NAME: a live run and a plain one leave the
    /// same single object in the session, built from the same writer, and the finished
    /// design arrives as one more state of it rather than as a second object beside it.
    ///
    /// The layout is passed rather than left to be guessed. Each frame carries the
    /// generated chain only — resending the static target fifty times would be pointless
    /// traffic — so the Python side splices it into the object, and to do that it has to
    /// know how many atoms precede the generated chain and how many are in it. Both come
    /// from `RFD3ResultWriter.Composed`, which is the emitter reporting its own layout;
    /// nothing here counts atoms on its own.
    ///
    /// The PDB argument is a multi-line string — `pythonMultilineLiteral` rather than
    /// `pythonLiteral`, which silently deletes newlines and would produce a single joined
    /// line that PyMOL's line-oriented PDB reader would parse as exactly one atom.
    static func seedPython(name: String, seed: RFD3ResultWriter.Composed) -> String {
        "from pymol import designing as _d\n"
        + "_d.trajectory_seed(\(InferenceJob.pythonLiteral(name)), "
        + "\(InferenceJob.pythonMultilineLiteral(seed.pdb)), "
        + "\(seed.targetAtomCount), \(seed.designAtomCount))"
    }

    /// The statement that appends one frame.
    ///
    /// Flat, three floats per atom, at millimetre precision — a trajectory is watched, not
    /// measured, and %.3f keeps a 300-atom frame around 7 KB of source instead of 15.
    static func framePython(name: String, coords: [SIMD3<Double>]) -> String {
        var body = ""
        body.reserveCapacity(coords.count * 24)
        for (index, xyz) in coords.enumerated() {
            if index > 0 { body += "," }
            body += String(format: "%.3f,%.3f,%.3f", xyz.x, xyz.y, xyz.z)
        }
        return "from pymol import designing as _d\n"
             + "_d.trajectory_frame(\(InferenceJob.pythonLiteral(name)), [\(body)])"
    }

    /// MLX must never run on the main thread; the command arrives ON it. Serial, so two
    /// designs cannot both hold the peak transient — the guard sizes one design, not two.
    private let queue = DispatchQueue(label: "io.raymol.design.rfd3", qos: .userInitiated)
    /// Guards `cancelled`, which the design thread reads and the main thread writes.
    private let stateQueue = DispatchQueue(label: "io.raymol.design.rfd3.state")
    private var cancelled = Set<String>()

    /// One loaded pack per weights directory, so a second design does not re-read 672 MB.
    /// Touched only from `queue`.
    private var loaded: [String: RFD3Model] = [:]

    private init() {}

    /// Test seam, matching `DesignController`'s injection pattern and the other managers'.
    /// UNGATED, like those: a `#if DEBUG` here would not compile against a Release app
    /// host.
    var cancelRequestedForTesting: Set<String> { stateQueue.sync { cancelled } }

    // MARK: InferenceRuntime

    /// Refuse or accept a submitted request. Runs on the MAIN thread.
    ///
    /// Only the request's SHAPE is judged here. The size refusal is on the worker, because
    /// sizing needs a built feature set and building one for a 700-token target is real
    /// CPU work — and the main thread is the one that renders and drains PyMOL's feedback
    /// buffer. It is still before any GPU work, which is the property that matters.
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
    /// only its own.
    func cancel(jobID: String) {
        stateQueue.sync {
            guard !InferenceJob.hasTerminalStatus(jobID: jobID) else { return }
            cancelled.insert(jobID)
        }
    }

    /// Refuse on what the request alone says, before allocating anything.
    ///
    /// Every check here is one the engine would NOT make. Its featurizer skips a residue it
    /// has no atom template for while the hotspot indices keep counting, so one unreadable
    /// residue silently shifts which residues the design is aimed at; and it happily
    /// designs against an empty target. The Python side refuses all of this first, so
    /// reaching any of these is a bug or a version skew rather than a user error — which is
    /// exactly why it is checked twice.
    static func preflight(_ request: InferenceJob.Request) -> InferenceJob.Status? {
        guard request.runtime == runtimeName else {
            // Unreachable through the router, which dispatches on this very field. Handled
            // rather than asserted so a future caller cannot quietly run a Boltz request
            // through a generator's featurizer.
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
        let hotspots = request.hotspots ?? []
        guard !hotspots.isEmpty else {
            return InferenceJob.refusal(
                "a backbone design needs hotspot residues: they set the sampler origin, so"
                + " without them the design is aimed at the whole target's centre of mass")
        }
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

        guard let wireTarget = request.target, let length = request.designLength else {
            // preflight already refused this; belt and braces so `run` has no optionals to
            // force-unwrap.
            settle(InferenceJob.refusal("malformed design request"))
            return
        }

        report("running", "featurize", 0.0)
        do {
            RFD3Runtime.configureOnce()

            let target = wireTarget.map { residue in
                RFD3Model.Residue(
                    resName: residue.resn,
                    // Discarded by the featurizer -- it identifies a residue purely by its
                    // position -- so 0 rather than a translation of the session's chain id
                    // that would read as meaningful. RayMol's own chain and numbering are
                    // carried by RFD3ResultWriter instead.
                    chain: 0,
                    resSeq: 0,
                    atoms: residue.atoms.compactMap { atom in
                        guard atom.xyz.count == 3 else { return nil }
                        return RFD3Model.Atom(
                            name: atom.name,
                            xyz: SIMD3(Float(atom.xyz[0]), Float(atom.xyz[1]),
                                       Float(atom.xyz[2])))
                    })
            }

            var options = RFD3Model.Options()
            options.binderLength = length
            options.hotspots = request.hotspots ?? []
            options.numTimesteps = request.diffusionSteps
            options.nRecycle = request.recyclingSteps
            options.seed = request.seed
            options.memoryBudgetBytes = RFD3SizeGuard.budgetBytes

            // BEFORE the pack is read. `preflight` is static and weight-free for exactly
            // this reason: an over-budget design must not cost the user a 672 MB load, and
            // above all it must be refused before any GPU work — an out-of-memory here is
            // a `std::terminate` from a Metal completion handler that no `catch` can
            // intercept, and on macOS it takes the unsaved session with it.
            //
            // `designBinder` re-featurizes internally and discards this `FeatSet`, so it is
            // fair to ask whether its `origin` is the one the run actually uses. It is: the
            // featurizer is deterministic in (target, hotspots, binderLength), all three of
            // which are identical between the two calls, and `origin` is derived from the
            // target and hotspot coordinates alone. The duplicated CPU featurization is the
            // price already paid to keep the refusal weight-free.
            let featSet = try RFD3Model.preflight(target: target, options: options,
                                                  budgetBytes: RFD3SizeGuard.budgetBytes)
            // Extract origin immediately so the FeatSet's tensors (tens of MB on a large
            // target) can be released as soon as ARC sees no more uses of featSet, rather
            // than staying reachable across the entire rollout.
            let origin = featSet.origin

            if isCancelled() {
                settle(cancelledStatus(phase: "featurize")); return
            }

            report("running", "load", 0.02)
            let model = try loadedModel(directory: request.weightsDir)

            report("running", "diffusion", 0.06)
            // Reset the high-water mark so each design is measured independently rather
            // than reporting the largest run this process has ever done.
            Memory.peakMemory = 0
            let started = Date()

            options.onProgress = { step, total in
                // `total` is numTimesteps - 1: the schedule has numTimesteps sigma levels
                // and one fewer transition. Reported as given, never re-derived from
                // request.diffusionSteps, or the bar would stop one step short forever.
                let fraction = total > 0 ? Double(step) / Double(total) : 0
                guard throttle.shouldEmit(stage: "diffusion", fraction: fraction,
                                          isFinal: step >= total,
                                          now: ProcessInfo.processInfo.systemUptime)
                else { return }
                report("running", "diffusion", fraction, step: step, totalSteps: total)
            }
            // The only cancellation point there is: `designBinder` is synchronous, so there
            // is no Task to cancel. Polled per step, so the worst case is one step -- of a
            // run whose steps are seconds each on a real target.
            options.shouldCancel = { [weak self] in
                guard let self else { return false }
                return self.stateQueue.sync { self.cancelled.contains(request.jobID) }
            }

            // Live view (#342). Installed only when asked for, so an ordinary run makes no
            // callback at all and pays nothing. Every failure here degrades to "no live
            // view": a design that would have succeeded must not fail because a frame
            // could not be drawn.
            if request.liveView == true, let objectName = request.objectName,
               !objectName.isEmpty {
                let interval = Self.trajectoryStepInterval
                var seeded = false
                // `onStepDenoised` streams px0 -- the denoiser's prediction of the CLEAN
                // structure at that step -- not the raw EDM iterate. It is the hook that
                // makes this feature watchable: the iterate's schedule starts at
                // `sigmaData`(16) x `sMax`(160) = 2560 A, so its early states are an
                // off-screen cloud, while px0 is protein-scale at every step because the
                // EDM output preconditioning scales the network's output by `sigmaData`
                // rather than by sigma. Measured upstream on a 50-step albumin rollout:
                // 33.9 A at step 1 against 6904.6 A for the iterate at the same step, and
                // 35.8 / 36.1 / 35.2 / 39.2 / 38.9 A at steps 1 / 10 / 20 / 30 / 49.
                options.onStepDenoised = { [weak self] step, materialise in
                    guard let self else { return }
                    // `total` is not passed to this callback, so the final-step rule uses
                    // the requested schedule's last transition: numTimesteps - 1.
                    guard RFD3Trajectory.shouldCapture(
                        step: step, interval: interval,
                        total: max(request.diffusionSteps - 1, 1)) else { return }
                    let coords = RFD3Trajectory.frame(flat: materialise(),
                                                      length: length, origin: origin)
                    guard !coords.isEmpty else { return }
                    if !seeded {
                        // The first captured frame IS state 1, and it is seeded with its
                        // own real coordinates: PyMOL infers bonds once, at read time,
                        // from the seed's coordinates, and a seed of coincident atoms
                        // refuses every bond for the life of the object. Seeded and
                        // RETURNED, never also appended, or this frame would be state 1
                        // and state 2 both.
                        //
                        // The seed carries the TARGET too, from the same writer the
                        // result comes out of, so the object the user watches is already
                        // the object the design lands in.
                        guard let seed = RFD3Trajectory.seed(
                            target: wireTarget, length: length,
                            chain: request.designChain ?? "B",
                            coords: coords) else { return }
                        seeded = true
                        self.runPythonOnMain(Self.seedPython(name: objectName,
                                                             seed: seed))
                        return
                    }
                    self.runPythonOnMain(Self.framePython(name: objectName,
                                                          coords: coords))
                }
            }

            let design = try RFD3Runtime.withMLXErrorsAsThrows {
                try model.designBinder(target: target, options: options)
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Memory.peakMemory

            report("running", "write", 0.96)
            // THE TARGET IS HELD FIXED, CHECKED RATHER THAN TRUSTED. `targetDriftMaxA` is
            // the engine's own measurement, taken in the engine's frame against the exact
            // coordinates it was handed, so it sees ANY movement -- including a rigid shift
            // of the whole target, which is precisely what `RFD3ResultWriter`'s residual
            // cannot see because it absorbs one by design. That is why both checks exist:
            // this one is the contract, that one is whether the emitted pair is coherent.
            //
            // Measured 0.000 A across every benchmarked run, so this refuses a broken run
            // rather than trimming a noisy one. It matters because the object is written
            // with the ORIGINAL target coordinates: if the model moved the target, the
            // design's pose is relative to something else.
            guard design.stats.targetDriftMaxA <= RFD3ResultWriter.driftToleranceAngstrom
            else {
                settle(InferenceJob.Status(
                    state: "failed", phase: "write", fraction: 0,
                    error: String(format:
                        "the target moved %.3f A during generation (tolerance %.3f A)."
                        + " It is held fixed by contract, and the design's position is"
                        + " only meaningful relative to where the target actually was,"
                        + " so this design is refused rather than emitted against"
                        + " coordinates it was not built against.",
                        design.stats.targetDriftMaxA,
                        RFD3ResultWriter.driftToleranceAngstrom),
                    resultPath: nil, peakBytes: peak, elapsedSeconds: elapsed))
                return
            }
            // The target is emitted from the ORIGINAL atoms and the design is translated
            // back onto them, so the object superposes on the structure it was designed
            // against.
            let text = try RFD3ResultWriter.compose(
                target: wireTarget,
                designChain: request.designChain ?? "B",
                designLength: length,
                designSequence: design.binderSequence,
                resultPDB: design.pdb,
                remarks: Self.remarks(request: request, design: design))
            try text.write(to: URL(fileURLWithPath: request.outPath),
                           atomically: true, encoding: .utf8)
            Self.writeMetrics(request: request,
                              geometry: Geometry(design.stats))
            // Load BEFORE reporting done, so a script that polls then reads the object
            // does not race the load.
            InferenceJob.loadResult(request, pythonModule: Self.pythonModule)
            report("done", "done", 1.0, result: request.outPath)
        } catch RFD3ModelError.cancelled {
            settle(cancelledStatus(phase: "diffusion"))
        } catch {
            // `String(describing:)` rather than `localizedDescription`: RFD3Kit's errors do
            // conform to LocalizedError as of 0.1.1, but this path also carries MLX and
            // Foundation errors that do not, and for those the localized form is the
            // useless generic fallback.
            settle(InferenceJob.Status(
                state: "failed", phase: "diffusion", fraction: 0,
                error: String(describing: error), resultPath: nil,
                peakBytes: peak, elapsedSeconds: elapsed))
        }
    }

    private func cancelledStatus(phase: String) -> InferenceJob.Status {
        InferenceJob.Status(state: "cancelled", phase: phase, fraction: 0,
                            error: nil, resultPath: nil, peakBytes: nil,
                            elapsedSeconds: nil)
    }

    /// Session work, hopped to the main thread. The rollout runs on a background queue and
    /// PyMOL's session may only be touched from the main one — the same rule
    /// `InferenceJob.loadResult` follows.
    ///
    /// Each call enqueues rather than blocks; the rollout never waits for a frame to
    /// render. The queue is FIFO, so the seed always precedes the frames. At most
    /// `diffusionSteps / trajectoryStepInterval` items accumulate — one seed plus 49
    /// frames for a 200-step run — which is acceptable without a drop policy.
    private func runPythonOnMain(_ source: String) {
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(source)
        }
    }

    /// Provenance written into the structure itself, so it survives an export.
    ///
    /// A design's identity is what a later refold is keyed to, and a PDB saved out of the
    /// session otherwise carries nothing that says which design it is. The metric record
    /// holds the same key; this is the copy that leaves RayMol with the file.
    static func remarks(request: InferenceJob.Request,
                        design: RFD3Model.Result) -> [String] {
        var lines = ["GENERATED BY RAYMOL / RFD3Kit (RFdiffusion3, MLX)"]
        if let key = request.designKey, !key.isEmpty {
            lines.append("DESIGN KEY \(key)")
        }
        lines.append("DESIGNED CHAIN \(request.designChain ?? "B")")
        lines.append("DESIGNED SEQUENCE \(design.binderSequence)")
        lines.append("SEED \(request.seed)  STEPS \(request.diffusionSteps)"
                     + "  RECYCLES \(request.recyclingSteps)")
        lines.append("TARGET HELD FIXED; DRIFT "
                     + String(format: "%.3f A", design.stats.targetDriftMaxA))
        // Says what has NOT been done, without using the word the naming rule reserves.
        // Worth carrying in the file itself: a PDB exported from here otherwise looks
        // exactly like a validated result to whoever opens it next.
        lines.append("THIS CHAIN WAS GENERATED, NOT VALIDATED: IT HAS NOT BEEN REFOLDED"
                     + " AND NO INTERFACE HAS BEEN SCORED")
        return lines
    }

    /// What a design measured, in RAYMOL's vocabulary.
    ///
    /// A translation layer over `RFD3Model.Stats`, and it earns its place twice. It is where
    /// every upstream field name carrying "binder" is renamed — a generated chain is a
    /// designed backbone until a refold and an interface gate say otherwise, which is a
    /// product rule rather than a wording preference. And it is what makes the metric
    /// document testable: `Stats` has public fields but only an internal initialiser, so a
    /// host cannot construct one, and a document format with no test is a schema mismatch
    /// waiting to be found by a user.
    ///
    /// The key names are declared on the other side too, in
    /// `modules/pymol/generators/metrics.py` (`GEOMETRY_SPECS`, with `STATS_FIELDS`
    /// recording this same mapping). A key written here and not declared there is dropped
    /// silently by the metric store, so `RFD3RuntimeTests` pins the set.
    struct Geometry {
        let designCACAMean: Double
        let backboneValidPercent: Double
        let designRadiusOfGyration: Double
        let interfaceMinDistance: Double
        let contactsUnder8A: Int
        let hotspotMinDistance: Double
        let targetDriftMax: Double

        init(designCACAMean: Double, backboneValidPercent: Double,
             designRadiusOfGyration: Double, interfaceMinDistance: Double,
             contactsUnder8A: Int, hotspotMinDistance: Double, targetDriftMax: Double) {
            self.designCACAMean = designCACAMean
            self.backboneValidPercent = backboneValidPercent
            self.designRadiusOfGyration = designRadiusOfGyration
            self.interfaceMinDistance = interfaceMinDistance
            self.contactsUnder8A = contactsUnder8A
            self.hotspotMinDistance = hotspotMinDistance
            self.targetDriftMax = targetDriftMax
        }

        init(_ stats: RFD3Model.Stats) {
            self.init(designCACAMean: stats.binderCACAmeanA,
                      backboneValidPercent: stats.backboneValidPct,
                      designRadiusOfGyration: stats.radiusOfGyrationA,
                      interfaceMinDistance: stats.interfaceMinA,
                      contactsUnder8A: stats.contactsUnder8A,
                      hotspotMinDistance: stats.binderToHotspotMinA,
                      targetDriftMax: stats.targetDriftMaxA)
        }

        /// One `pymol.metrics` value per number. State 1 throughout: each design is its own
        /// object with one state, and the Python side re-stamps the state it actually landed
        /// in anyway.
        var metricValues: [[String: Any]] {
            [
                ["key": "design_ca_ca_mean", "state": 1, "value": designCACAMean],
                ["key": "backbone_valid_pct", "state": 1, "value": backboneValidPercent],
                ["key": "design_radius_of_gyration", "state": 1,
                 "value": designRadiusOfGyration],
                ["key": "interface_min_distance", "state": 1, "value": interfaceMinDistance],
                ["key": "contacts_under_8a", "state": 1, "value": contactsUnder8A],
                ["key": "hotspot_min_distance", "state": 1, "value": hotspotMinDistance],
                ["key": "target_drift_max", "state": 1, "value": targetDriftMax],
            ]
        }
    }

    /// The geometry this run measured, as a `pymol.metrics` document (#308).
    ///
    /// Only what the RUNTIME measures. The design's identity, its length and what it cost
    /// are written by `pymol.designing`, which knows them; elapsed time and peak memory
    /// already reach the store through the status file and must not be sent twice from two
    /// sources that could disagree.
    static func writeMetrics(request: InferenceJob.Request, geometry: Geometry) {
        guard let path = request.metricsPath, !path.isEmpty else { return }
        // `tool` is overridden on the Python side with the GENERATOR id: this runtime knows
        // its own name, not which generator selected it.
        let document: [String: Any] = [
            "tool": runtimeName,
            "object": request.objectName ?? "",
            "values": geometry.metricValues,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The model for `directory`, loaded once.
    ///
    /// `verifyChecksums` is left at its default of true. The pack's own manifest pins a
    /// sha256 per file, and `Weights.subscript` calls `fatalError` on a key it cannot find
    /// — so a subtly wrong pack does not throw, it takes the process down. Hashing 672 MB
    /// once per session is the cheap side of that trade.
    private func loadedModel(directory: String) throws -> RFD3Model {
        if let cached = loaded[directory] { return cached }
        let model = try RFD3Model(packDirectory: URL(fileURLWithPath: directory))
        // One pack at a time: two 672 MB packs plus a design's peak transient is not a
        // budget RFD3SizeGuard sized for, and nothing switches packs mid-session today.
        loaded = [directory: model]
        return model
    }
}
#endif
