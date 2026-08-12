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
    /// Construction loads ~505 MiB and builds the graph (~10 s), so it is kept alive
    /// across predictions rather than rebuilt per job.
    private var predictor: BoltzPredictor?
    private var predictorDirectory: String?

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

    struct Request: Codable {
        let jobID: String
        let weightsDir: String
        let chains: [Chain]
        let recyclingSteps: Int
        let diffusionSteps: Int
        let seed: UInt64
        let outPath: String
        let statusPath: String

        enum CodingKeys: String, CodingKey {
            case jobID = "job_id", weightsDir = "weights_dir", chains
            case recyclingSteps = "recycling_steps", diffusionSteps = "diffusion_steps"
            case seed, outPath = "out_path", statusPath = "status_path"
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
            stateQueue.sync { cancelled.insert(marker.jobID) }
        case .submit:
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("raymol_predict_req_\(marker.jobID).json")
            guard let request = try? Self.parseRequest(at: url) else { return }
            if let failure = Self.preflight(request) {
                try? Self.writeStatus(failure, to: URL(fileURLWithPath: request.statusPath))
                return
            }
            queue.async { self.run(request) }
        }
    }

    /// Refuse before allocating anything. Returns nil when the run may proceed.
    static func preflight(_ request: Request) -> Status? {
        let tokens = request.chains.reduce(0) { $0 + $1.sequence.count }
        switch PredictSizeGuard.decide(tokens: tokens,
                                       availableBytes: PredictSizeGuard.availableBytes) {
        case .ok, .warn:
            return nil
        case let .refuse(maxFittingTokens):
            return Status(state: "failed", phase: "preflight", fraction: 0,
                          error: "input of \(tokens) residues is too large for this "
                               + "machine; at most about \(maxFittingTokens) fit",
                          resultPath: nil, peakBytes: nil, elapsedSeconds: nil)
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
                report("failed", "featurize", 0,
                       error: "unsupported input: \(canonical.diagnostics)")
                return
            }
            let features = try BoltzFeaturizer().featurize(canonical, alignments: [:])

            if isCancelled() { report("cancelled", "featurize", 0); return }
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
            let structure = try BoltzRuntime.withMLXErrorsAsThrows {
                try Self.awaitSync { try await predictor.predict(featurized: features,
                                                                options: options) }
            }
            elapsed = Date().timeIntervalSince(started)
            peak = Self.awaitSyncValue { await predictor.memorySnapshot().peakMemory }

            // MemoryPlanner.apply() runs inside the actor on EVERY predict and assigns
            // MLX.Memory.cacheLimit unconditionally, so it has just overwritten whatever
            // MLXRuntime arbitrated. Re-assert the arbitrated minimum, or a subsequent
            // Design-mode inference inherits prediction's larger ceiling and can be
            // jetsam-killed.
            BoltzRuntime.configureOnce()

            if isCancelled() { report("cancelled", "inference", 0); return }
            report("running", "write", 0.95)
            let text = try StructureWriter.pdb(structure: structure, canonical: canonical)
            try text.write(to: URL(fileURLWithPath: request.outPath),
                           atomically: true, encoding: .utf8)
            report("done", "done", 1.0, result: request.outPath)
        } catch is CancellationError {
            report("cancelled", "inference", 0)
        } catch {
            report("failed", "inference", 0, error: error.localizedDescription)
        }
        stateQueue.sync { cancelled.remove(request.jobID) }
    }

    /// Bridge the actor's async API onto this synchronous queue. Blocking a thread is
    /// acceptable here precisely because the queue is dedicated to one inference at a
    /// time; it must never be done on the main thread.
    private static func awaitSync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>!
        Task {
            do { outcome = .success(try await body()) }
            catch { outcome = .failure(error) }
            done.signal()
        }
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
