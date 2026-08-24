#if os(macOS) || os(iOS)
import Foundation

/// What a manager must be for the router to reach it.
///
/// Exists to kill a naming drift that had already started: the first manager called its
/// wire name `boltzRuntime`, the second called its `runtimeName`, and nothing enforced a
/// shape because each new runtime was wired in by hand at the call site. A protocol makes
/// the table uniform, which is what lets ``InferenceRouter`` dispatch by loop instead of by
/// a branch per runtime — and a branch per runtime is exactly how a runtime ends up
/// routable but not cancellable.
///
/// Deliberately three members and no more. Everything method-specific — the featurizer, the
/// weights, the size model, the result writer — is the conformer's own business; the router
/// only needs to know a runtime's name and how to start and stop a job.
protocol InferenceRuntime: AnyObject {
    /// This runtime's name as it appears on the wire, in `Request.runtime`. Kept in step
    /// with the Python side's `RUNTIME` constant and with what `PyMOLBridge` advertises in
    /// `RAYMOL_PREDICT_RUNTIMES` — that variable is what lets a method whose backend is NOT
    /// linked here refuse in `check_available` instead of submitting a job that only gets
    /// refused after a weight download.
    static var runtimeName: String { get }

    /// Refuse or accept a submitted request. Runs on the MAIN thread, so it must not block:
    /// the app drains PyMOL's feedback buffer from a main-run-loop timer, and a blocked main
    /// thread cannot deliver even the messages describing why it is blocked.
    func submit(_ request: InferenceJob.Request)

    /// Note a cancel. Must be idempotent, and safe for a job id this runtime never had — a
    /// cancel marker carries only a job id, so it is broadcast to every runtime and each
    /// keeps only its own.
    func cancel(jobID: String)
}

/// Owns the `PREDICT:` marker and the table of runtimes it can reach.
///
/// The dispatcher lives here rather than inside one of its own targets. It used to be a
/// branch inside ``BoltzJobManager/handle(marker:)``, which made the two managers a cycle:
/// Protenix reached in for the wire types and the shell, and Boltz reached back out to
/// route and to broadcast cancels. Boltz owned the marker only because it was written
/// first, and the note at that branch asked for exactly this — "when a third runtime
/// lands, lift the parse-and-route out into a dispatcher rather than adding another branch
/// here". Doing it now rather than then means the third runtime arrives as a peer instead
/// of being added to a cycle.
enum InferenceRouter {

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

    // MARK: - The table

    /// The runtime a request that names NO runtime is handed to.
    ///
    /// `nil` means Boltz, per ``InferenceJob/Request/runtime``: every Python side that
    /// predates a second runtime wrote no such key, and the only runtime that existed then
    /// was this one.
    ///
    /// It is also where a request naming a runtime this build does not carry lands — see
    /// ``runtime(for:)``.
    static let defaultRuntime: any InferenceRuntime = BoltzJobManager.shared

    /// Every runtime this build links.
    ///
    /// ONE list, read by both `submit` and `cancel`. That is the point of it: when the two
    /// were written out separately, keeping them in step was a thing a human had to
    /// remember, and a runtime that is routable but not cancellable is a job the user
    /// cannot stop. Adding a third runtime is now one line, and it cannot be added to one
    /// path and forgotten in the other.
    ///
    /// A runtime is claimed by exactly one entry because the weights and the featurizer are
    /// method-specific: running one method's request on another's backend does not fail, it
    /// tokenizes with the wrong featurizer and returns a confident wrong answer.
    ///
    /// iOS carries the Boltz runtime alone (see PyMOLBridge.mm), so nothing else is linked
    /// there and a foreign runtime must reach Boltz's refusal rather than be silently
    /// accepted.
    static let runtimes: [any InferenceRuntime] = {
        var table: [any InferenceRuntime] = [BoltzJobManager.shared]
        #if os(macOS)
        table.append(ProtenixJobManager.shared)
        #endif
        return table
    }()

    /// The runtime that claims `name`, or the default.
    ///
    /// An unclaimed runtime deliberately falls through to the default, whose `preflight`
    /// refuses it BY NAME. That is how a Python side offering a method this build did not
    /// link gets a real error instead of a job that never reports.
    private static func runtime(for name: String?) -> any InferenceRuntime {
        guard let name else { return defaultRuntime }
        return runtimes.first { type(of: $0).runtimeName == name } ?? defaultRuntime
    }

    // MARK: - Entry point from pollFeedback()

    /// Dispatch one `PREDICT:` marker. The single entry point `PyMOLEngine.pollFeedback()`
    /// calls, for every job.
    static func handle(marker line: String) {
        guard let marker = parseMarker(line) else { return }
        switch marker.verb {
        case .cancel:
            // Broadcast: a cancel marker carries only a job id, so there is nothing in it
            // to route on. Every runtime keeps only its own ids, and a cancel for a job
            // this one never had is a no-op.
            for runtime in runtimes { runtime.cancel(jobID: marker.jobID) }
        case .submit:
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("raymol_predict_req_\(marker.jobID).json")
            let request: InferenceJob.Request
            do {
                request = try InferenceJob.parseRequest(at: url)
            } catch {
                // Without this, an unparseable request returns silently and Python polls
                // `queued` forever — asymmetric with preflight, which does write `failed`.
                // The status path follows host.py's naming convention, so it is derivable
                // even when the payload is not. `writeStatus` rather than `settle`: there
                // is no decoded request, so there is no object name to discard.
                try? InferenceJob.writeStatus(
                    InferenceJob.Status(state: "failed", phase: "request", fraction: 0,
                                        error: "malformed prediction request: "
                                             + error.localizedDescription,
                                        resultPath: nil, peakBytes: nil,
                                        elapsedSeconds: nil),
                    to: InferenceJob.statusURL(jobID: marker.jobID))
                return
            }
            runtime(for: request.runtime).submit(request)
        }
    }
}
#endif
