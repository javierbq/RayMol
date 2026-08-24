#if os(macOS) || os(iOS)
import Foundation

/// A backend that runs inference jobs for one method — its featurizer, its weights, its
/// model — behind the three members ``InferenceRouter`` needs to reach it.
///
/// **To add a runtime:** conform your manager, then add its singleton to
/// ``InferenceRouter/runtimes``. That one entry is the whole registration, and it makes the
/// runtime routable and cancellable together.
///
/// Nothing method-specific belongs here. The featurizer, the weights, the size model and
/// the result writer stay the conformer's own; the router needs only a runtime's name and
/// how to start and stop a job.
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

/// Turns a `PREDICT:` feedback marker into a job on the runtime that owns it.
///
/// ``handle(marker:)`` is the only entry point, and `PyMOLEngine.pollFeedback()` is its
/// only caller — once per `PREDICT:` line, on the main thread. There are two verbs:
///
/// * `PREDICT:submit:<jobID>` decodes `raymol_predict_req_<jobID>.json` out of the temp
///   dir and hands the request to one runtime.
/// * `PREDICT:cancel:<jobID>` carries no runtime — a marker holds only a job id — so it
///   goes to every entry in ``runtimes``, and each keeps only its own ids.
///
/// A submit is routed by `Request.runtime`, and all three of these are normal:
///
/// * a name matching a ``runtimes`` entry goes there;
/// * NO name means ``defaultRuntime``, because every Python side that predates a second
///   runtime wrote no such key;
/// * a name this build does not carry ALSO reaches ``defaultRuntime``, whose `preflight`
///   refuses it BY NAME — which is how a Python side offering a method that was never
///   linked gets a real error instead of a job that never reports.
///
/// A request that will not decode gets a `failed` status written straight to its derived
/// status path: without one, Python polls `queued` forever.
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

    /// Where a request naming no runtime goes — and where one naming an unknown runtime
    /// goes too, to be refused by name.
    ///
    /// It must ALSO appear in ``runtimes``. Otherwise a cancel for the commonest kind of
    /// job — one that named no runtime at all — would never reach the manager running it.
    /// `InferenceRouterTests` pins that.
    static let defaultRuntime: any InferenceRuntime = BoltzJobManager.shared

    /// Every runtime this build links, and the ONE table both `submit` and `cancel` read.
    ///
    /// Adding an entry registers a runtime for both, in the same line. **Keep it that
    /// way:** a second list beside this one is how a runtime ends up startable but not
    /// stoppable — a running job the user has no way to cancel.
    ///
    /// A runtime is claimed by exactly one entry, because weights and featurizer are
    /// method-specific: running one method's request on another's backend does not fail —
    /// it tokenizes with the wrong featurizer and returns a confident wrong answer.
    ///
    /// iOS links Boltz alone (see PyMOLBridge.mm), so a foreign runtime there reaches
    /// Boltz's refusal rather than being silently accepted.
    static let runtimes: [any InferenceRuntime] = {
        var table: [any InferenceRuntime] = [BoltzJobManager.shared]
        #if os(macOS)
        table.append(ProtenixJobManager.shared)
        #endif
        return table
    }()

    /// The runtime that claims `name`, or ``defaultRuntime`` when nothing does.
    private static func runtime(for name: String?) -> any InferenceRuntime {
        guard let name else { return defaultRuntime }
        return runtimes.first { type(of: $0).runtimeName == name } ?? defaultRuntime
    }

    // MARK: - Entry point from pollFeedback()

    /// Dispatch one `PREDICT:` marker. See the type's documentation for the verbs and the
    /// routing rules.
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
