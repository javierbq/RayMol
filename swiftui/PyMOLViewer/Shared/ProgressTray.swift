// ProgressTray.swift — one stacked, max-height, scrollable tray of non-blocking
// progress cards: weight downloads and running predictions in the same corner.
//
// Deliberately NOT a scrim. A scrim is a truth claim that the main thread is
// blocked (see CalculatingOverlay); everything in this tray runs off-main and
// the app stays fully interactive for the whole ten-plus minutes.
import SwiftUI

/// One row. Kind-agnostic on purpose: the view dispatches `action` through the
/// tray's closure without knowing what kind of job produced the item.
struct ProgressItem: Identifiable, Equatable {
    /// What the tray's Cancel/Dismiss button should do when tapped.
    enum Action: Equatable {
        /// Run a PyMOL command through the engine's command channel.
        case command(String)
        /// Run a Python source string through `engine.runPython(_:)`. Use this
        /// when an argument must be passed as a properly-escaped Python literal
        /// rather than a parser-split token — the PyMOL text parser does NOT strip
        /// surrounding double-quotes from `"[^"]*"` matches, so a quoted object name
        /// arrives with the quotes still attached.
        ///
        /// The source MUST import what it uses. `runPython` lands in `__main__`,
        /// which starts EMPTY in RayMol's embedding (see `raymolrc._seed_main_namespace`,
        /// which binds `cmd` there only when `~/.raymolrc.py` exists). A bare
        /// `cmd.foo()` is therefore a silent NameError for most users.
        case python(String)
        /// Stop every in-flight weight download and clear the published state, via
        /// `engine.cancelWeightsDownload()`.
        ///
        /// Both weight branches route through here. The per-bundle command spelling
        /// cannot: `predict_weights_cancel` takes a PREDICTOR id, while
        /// `WeightsFetchState.id` is the BUNDLE id, so `predict_weights_cancel
        /// boltz2-mlx-int8` raises PredictorNotFound and the download carries on.
        /// Cancel-all is also exactly right here — `weightsFetch` holds at most one
        /// fetch, so there is nothing else to spare — and clearing the state locally
        /// is what makes the card go away immediately rather than at the next poll.
        case cancelWeightsFetch
        /// No button is shown (reserved for future use).
        case none
    }

    let id: String
    let icon: String
    let title: String
    let detail: String
    let fraction: Double?
    let moving: Bool
    let isError: Bool
    /// A terminal state that is NOT a failure. Still `isError` for layout purposes
    /// (Dismiss button, no bar, sorted below live jobs), but drawn grey, not orange:
    /// the user pressed Cancel and does not need to be alarmed by their own action.
    var isCancelled: Bool = false
    let buttonTitle: String
    let action: Action
    /// Set on a prediction still waiting on a weight fetch, so the tray can drop
    /// it while the download's own card is showing the same thing.
    let bundle: String?

    static func weights(_ fetch: WeightsFetchState) -> ProgressItem {
        ProgressItem(
            id: "weights:\(fetch.id)",
            icon: fetch.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle",
            title: fetch.isError ? "Model weights failed to download"
                                 : "Downloading model weights",
            detail: WeightDownloadDetail.text(fetch),
            fraction: fetch.fraction,
            moving: !fetch.isError,
            isError: fetch.isError,
            buttonTitle: fetch.isError ? "Dismiss" : "Cancel",
            // BOTH branches: see cancelWeightsFetch. A running fetch cannot be
            // stopped by id here (bundle id != predictor id), and an error card has
            // nothing to stop but still has to clear itself.
            action: .cancelWeightsFetch,
            bundle: fetch.id)
    }

    static func prediction(_ job: PredictionJobState) -> ProgressItem {
        var parts: [String] = []
        // The exact position within the phase, which the bar cannot say: the bar
        // is the WHOLE job across every model, this is diffusion step 84 of 200.
        if let step = job.step, let total = job.totalSteps, total > 0 {
            parts.append("step \(step) of \(total)")
        }
        if job.modelsTotal > 1 {
            parts.append("model \(min(job.modelsDone + 1, job.modelsTotal)) of \(job.modelsTotal)")
        }
        let elapsed = "\(ProgressCard.formatElapsed(job.elapsed)) elapsed"
        // An estimate when there is a measured rate to derive one from, and the
        // measured clock otherwise. Never both: the card's detail line is two
        // lines at most, and a countdown is what the reader came for.
        //
        // The SCOPED spelling: this estimate covers the current phase, and it sits
        // beside a whole-job percentage and "model k of N". See formatPhaseRemaining.
        parts.append(job.remaining.map(ProgressCard.formatPhaseRemaining) ?? elapsed)

        // Three states, not two. A cancellation is terminal like a failure — same
        // Dismiss button, same sort position, no progress bar — but it is the user's
        // own doing, so it must not be reported as a failure. settle("cancelled")
        // writes error: nil, so the failure branch rendered it as
        // "Prediction failed: X — Unknown error", which is both wrong and alarming.
        let icon: String
        let title: String
        let detail: String
        if job.isCancelled {
            icon = "xmark.circle"
            title = "Prediction cancelled: \(job.id)"
            // Nothing to explain; the elapsed clock is the only fact worth keeping.
            detail = elapsed
        } else if job.isError {
            icon = "exclamationmark.triangle.fill"
            title = "Prediction failed: \(job.id)"
            detail = job.error ?? "Unknown error"
        } else {
            icon = "atom"
            title = "Predicting \(job.id)"
            // The percentage is the COMPOSED whole-job fraction -- the very number
            // the bar below it draws -- so the text and the bar can never disagree.
            // Omitted when the bar is indeterminate, since there is then no number
            // to agree with. `step k of N` says where in the phase we are.
            var head = job.phase.capitalized
            if job.moving, let fraction = job.fraction {
                head += " \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
            }
            detail = ([head] + parts).joined(separator: " · ")
        }

        return ProgressItem(
            id: "predict:\(job.id)",
            icon: icon,
            title: title,
            detail: detail,
            fraction: job.fraction,
            moving: job.moving && !job.isError,
            isError: job.isError,
            isCancelled: job.isCancelled,
            buttonTitle: job.isError ? "Dismiss" : "Cancel",
            // Python path rather than command-channel: the PyMOL text parser does
            // not strip surrounding quotes from its "[^"]*" token, so a quoted
            // object name would arrive with the quotes still attached.
            //
            // The import is load-bearing, not decoration: runPython executes in
            // __main__, which is EMPTY in this embedding unless the user happens to
            // have a ~/.raymolrc.py. A bare `cmd.predict_cancel(...)` was a silent
            // NameError, so Cancel and Dismiss did nothing at all for most users.
            action: job.isError ? .python(pythonCall("predict_dismiss", job.id))
                                : .python(pythonCall("predict_cancel", job.id)),
            bundle: job.bundle)
    }

    /// A running or finished BACKBONE DESIGN.
    ///
    /// A sibling of `prediction(_:)` rather than a parameter on it. The wire record is the
    /// same shape -- `designing.pending_info` produces the same keys as
    /// `predicting.pending_info`, deliberately, so one decoder serves both -- but every
    /// user-visible word differs, and a design's numbers differ in kind: there is one
    /// design per object, so there is no "model k of N", and it takes MINUTES rather than
    /// seconds, which makes the elapsed clock the useful half rather than the fallback.
    ///
    /// The word "binder" appears nowhere. A generated chain is a designed backbone until it
    /// has been refolded and passed an interface gate, and this card is seen long before
    /// either.
    static func design(_ job: PredictionJobState) -> ProgressItem {
        var parts: [String] = []
        // Diffusion step k of N. On a real target each step is seconds, so this is the
        // line that says the job is alive at all.
        if let step = job.step, let total = job.totalSteps, total > 0 {
            parts.append("step \(step) of \(total)")
        }
        let elapsed = "\(ProgressCard.formatElapsed(job.elapsed)) elapsed"
        // BOTH, unlike a prediction's card. A design is minutes long and its phase estimate
        // covers only the current phase, so the elapsed clock is the number a user actually
        // tracks -- dropping it in favour of a scoped countdown would hide the one honest
        // measure of a seventeen-minute run.
        if let remaining = job.remaining {
            parts.append(ProgressCard.formatPhaseRemaining(remaining))
        }
        parts.append(elapsed)

        let icon: String
        let title: String
        let detail: String
        if job.isCancelled {
            icon = "xmark.circle"
            title = "Design cancelled: \(job.id)"
            detail = elapsed
        } else if job.isError {
            icon = "exclamationmark.triangle.fill"
            title = "Design failed: \(job.id)"
            detail = job.error ?? "Unknown error"
        } else {
            // Not "atom": a design is not a fold, and the tray may show both at once.
            icon = "wand.and.stars"
            title = "Designing \(job.id)"
            var head = job.phase.capitalized
            if job.moving, let fraction = job.fraction {
                head += " \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
            }
            detail = ([head] + parts).joined(separator: " · ")
        }

        return ProgressItem(
            id: "design:\(job.id)",
            icon: icon,
            title: title,
            detail: detail,
            fraction: job.fraction,
            moving: job.moving && !job.isError,
            isError: job.isError,
            isCancelled: job.isCancelled,
            buttonTitle: job.isError ? "Dismiss" : "Cancel",
            // `design_*`, not `predict_*`: the two surfaces keep separate job tables, so a
            // design's object name means nothing to predict_cancel. The `.python` channel
            // and the import are load-bearing for the reasons `prediction(_:)` gives.
            action: job.isError ? .python(pythonCall("design_dismiss", job.id))
                                : .python(pythonCall("design_cancel", job.id)),
            bundle: job.bundle)
    }

    /// One `design_backbone n_designs=N` invocation, as ONE row.
    ///
    /// N designs from one command are not N jobs a user can act on independently: the
    /// runtime runs them on a SERIAL queue, so exactly one is ever running and the rest
    /// are waiting their turn. Listing ten rows, nine of them reading "Queued", reports
    /// work that has not started as if it were ten separate jobs, and offers ten Cancels
    /// where the user wants one.
    ///
    /// **The batch does not shrink as it succeeds.** A design that lands leaves no record
    /// at all -- `deliver_result` pops it from every table -- so the size comes from
    /// `batchTotal` on the wire and never from counting the rows that are left.
    ///
    /// **How far through** is the lowest-indexed member that has not settled. Submission
    /// order IS queue order, so that member is the one running (or the one about to), and
    /// every index below it has finished one way or another. Derived rather than counted
    /// for the same reason: the successes are not there to count.
    ///
    /// A PARTIAL FAILURE is not a batch failure. While anything is still running the row
    /// stays a running row and merely says how many have failed so far; only when nothing
    /// is left does it become a terminal card, and even then it says how many of the N
    /// failed rather than implying all of them did.
    static func designBatch(_ members: [PredictionJobState]) -> ProgressItem {
        // Sorted by index, with the id as a tiebreak so the choice is total and stable:
        // the tray is rebuilt from a 2 Hz poll, and a row that reorders under the pointer
        // makes Cancel unclickable.
        let ordered = members.sorted {
            ($0.batchIndex ?? 0, $0.id) < ($1.batchIndex ?? 0, $1.id)
        }
        let batch = ordered.first?.batch ?? ""
        let total = max(ordered.compactMap(\.batchTotal).max() ?? ordered.count, 1)
        let failed = ordered.filter { $0.isError && !$0.isCancelled }
        let cancelled = ordered.filter(\.isCancelled)
        // The batch's own clock, not one design's: every member is registered in the same
        // instant, so the largest elapsed is the time since the command was typed.
        let elapsed = "\(ProgressCard.formatElapsed(ordered.map(\.elapsed).max() ?? 0))"
                    + " elapsed"

        guard let current = ordered.first(where: { !$0.isError }) else {
            // Nothing left running. Whatever is still on the wire is a terminal record
            // that has not been dismissed -- the successes are already gone.
            let icon: String
            let title: String
            let detail: String
            if let first = failed.first {
                icon = "exclamationmark.triangle.fill"
                // "designs" is dropped on purpose, and it is not a style choice: the
                // title is `lineLimit(1)` in a 340 pt card, and MEASURED with the real
                // font, "1 of 10 designs failed: rfd3_batch_1f4c9e02" is 235.1 pt against
                // 236.2 pt of room -- and the CANCELLED spelling was 264.1 pt, truncating
                // by 28. Truncation is at the tail, so what it eats is the batch NAME,
                // which is the half that identifies the row. Dropping one redundant word
                // (this is a design card, with a design card's icon) buys 45 pt.
                title = "\(failed.count) of \(total) failed: \(batch)"
                // The first failure's own message, plus a count when there are more --
                // a two-line card cannot carry ten reasons, and the individual cards are
                // gone by construction.
                var parts = [first.error ?? "Unknown error"]
                if failed.count > 1 { parts.append("and \(failed.count - 1) more") }
                if !cancelled.isEmpty { parts.append("\(cancelled.count) cancelled") }
                detail = parts.joined(separator: " · ")
            } else {
                icon = "xmark.circle"
                title = "\(cancelled.count) of \(total) cancelled: \(batch)"
                detail = elapsed
            }
            return ProgressItem(
                id: "design:\(batch)", icon: icon, title: title, detail: detail,
                fraction: nil, moving: false, isError: true,
                isCancelled: failed.isEmpty, buttonTitle: "Dismiss",
                action: .python(pythonCall("design_dismiss", batch)),
                bundle: ordered.first?.bundle)
        }

        let index = current.batchIndex ?? 1
        // Whole-batch: the designs already behind this one, plus how far this one has got.
        // The bar and the percentage read the same number, as they do on every other card.
        let fraction = current.fraction.map {
            (Double(index - 1) + min(max($0, 0), 1)) / Double(total)
        }
        var head = current.phase.capitalized
        if current.moving, let fraction {
            head += " \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        }
        var parts = ["design \(index) of \(total)"]
        if let step = current.step, let steps = current.totalSteps, steps > 0 {
            parts.append("step \(step) of \(steps)")
        }
        if let remaining = current.remaining {
            parts.append(ProgressCard.formatPhaseRemaining(remaining))
        }
        parts.append(elapsed)
        // Said while the rest are still running, so a batch that ends with nine designs
        // and one failure never reads as ten successes.
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if !cancelled.isEmpty { parts.append("\(cancelled.count) cancelled") }

        return ProgressItem(
            id: "design:\(batch)",
            icon: "wand.and.stars",
            title: "Designing \(batch)",
            detail: ([head] + parts).joined(separator: " · "),
            fraction: fraction,
            moving: current.moving,
            isError: false,
            buttonTitle: "Cancel",
            // The BATCH id, which `design_cancel` resolves to every job of that
            // invocation still outstanding -- the one running and the ones queued behind
            // it. One button, because there is one thing the user wants to stop.
            action: .python(pythonCall("design_cancel", batch)),
            bundle: current.bundle)
    }

    /// A self-contained Python statement calling `cmd.<function>(<name>)`.
    ///
    /// `_c` rather than `cmd`: the name is bound in `__main__` for the duration of
    /// the statement, and an unusual one cannot shadow something a user's
    /// `~/.raymolrc.py` put there.
    private static func pythonCall(_ function: String, _ name: String) -> String {
        "from pymol import cmd as _c\n_c.\(function)(\(InferenceJob.pythonLiteral(name)))"
    }

    /// Everything the tray should show, in order.
    ///
    /// A static rather than a computed property on ContentView so the merge, the
    /// filter and the sort are unit-testable without instantiating a View.
    /// `designs` is defaulted, so every existing call site and test is unchanged and the
    /// tray degrades to exactly its previous behaviour when nothing is designing.
    static func tray(weights: WeightsFetchState?,
                     predictions: [PredictionJobState],
                     designs: [PredictionJobState] = []) -> [ProgressItem] {
        var items: [ProgressItem] = []
        if let weights { items.append(.weights(weights)) }
        // While a bundle is fetching, its OWN card is the measured one; a
        // prediction merely waiting on it would show the same transfer again at a
        // different number. A design waiting on a bundle is hidden for the same
        // reason -- and it is the same `bundle` field, so the same filter covers it.
        let fetching = Set(items.compactMap(\.bundle))
        // Designs from ONE `n_designs` command collapse into ONE row; everything else is
        // a row of its own. `batch` is present only on a design record and only when the
        // command asked for more than one, so a prediction and a lone design both take
        // the untouched path -- which is what keeps the prediction lane, shipped
        // behaviour this feature does not own, exactly as it was.
        var batches: [String: [PredictionJobState]] = [:]
        var singles: [PredictionJobState] = []
        for job in designs {
            if let batch = job.batch, !batch.isEmpty { batches[batch, default: []].append(job) }
            else { singles.append(job) }
        }
        items += (predictions.map(ProgressItem.prediction)
                  + singles.map(ProgressItem.design)
                  // `batches` is a dictionary, so this map's order is undefined -- and it
                  // does not matter, because the sort below is TOTAL: every row's id is
                  // unique, so `lhs.id < rhs.id` decides every pair within a tier. Sorting
                  // the keys here as well was measured to change the answer on nothing.
                  + batches.values.map(ProgressItem.designBatch))
            .filter { item in item.bundle.map { !fetching.contains($0) } ?? true }
        // Running first, so a live job is never pushed below the fold by a stale
        // error card the user has not dismissed. Within a tier by id, which puts
        // "design:" before "predict:" -- arbitrary but STABLE, which is what stops
        // the rows reordering under the pointer on every poll.
        return items.sorted { lhs, rhs in
            lhs.isError == rhs.isError ? lhs.id < rhs.id : !lhs.isError
        }
    }
}

/// The detail line for a weight fetch, lifted from WeightDownloadOverlay so the
/// download card reads exactly as it did before the tray existed.
enum WeightDownloadDetail {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    static func text(_ fetch: WeightsFetchState) -> String {
        if fetch.isError { return fetch.error ?? "Unknown error" }
        let percent = "\(Int((min(max(fetch.fraction, 0), 1) * 100).rounded()))%"
        if fetch.isExtracting { return "Unpacking… \(percent)" }
        var parts = [percent]
        if fetch.total > 0 {
            let done = byteFormatter.string(fromByteCount: Int64(fetch.received))
            let total = byteFormatter.string(fromByteCount: Int64(fetch.total))
            parts.append("\(done) of \(total)")
        }
        if let left = fetch.secondsRemaining.map(ProgressCard.formatRemaining) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }
}

/// One row of the tray. This is WeightDownloadOverlay's card, minus its fixed
/// 340pt width (which moves to the container) and minus its own material (nested
/// materials stack and read opaque).
struct ProgressCard: View {
    let item: ProgressItem
    let onAction: (ProgressItem) -> Void

    /// Deliberately coarse. A to-the-second countdown on a multi-minute download
    /// invites the reader to trust a number derived from an average rate.
    static func formatRemaining(_ seconds: Double) -> String {
        switch seconds {
        case ..<10:   return "almost done"
        case ..<90:   return "\(Int(seconds.rounded())) sec left"
        case ..<3600:
            let mins = Int((seconds / 60).rounded())
            // Rounding can carry 59.5 min → 60; route those to the next bucket.
            if mins >= 60 { return "over an hour left" }
            return "\(mins) min left"
        default:      return "over an hour left"
        }
    }

    /// The SCOPED spelling, for a prediction card. Wraps the buckets rather than
    /// replacing them, so the weight-download card above keeps its wording.
    ///
    /// The scope is stated because the number is scoped: `PredictionJobState.remaining`
    /// measures the CURRENT PHASE only, while everything beside it on the card -- the
    /// percentage, the bar, "model 4 of 20" -- is the whole job. Unqualified, the two
    /// read as one claim: a 1.10.0 capture shows "Diffusion 19% · step 141 of 200 ·
    /// model 4 of 20 · almost done", where "almost done" means diffusion is seconds
    /// from step 200 but reads as if the run were finishing with sixteen models to go.
    ///
    /// "phase" and not the friendlier "model": diffusion is band 0.40–0.97 of a model
    /// and `write` follows it, so a phase estimate is not a model estimate and must not
    /// be sold as one. No whole-JOB countdown is offered at all — compose_progress's
    /// bands are layout, not time, so there is nothing honest to extrapolate one from.
    ///
    /// Identical to `predicting.format_phase_remaining`, for the same reason
    /// `formatRemaining` is identical to `format_remaining`: the hover tooltip and the
    /// card must never word one estimate two different ways.
    static func formatPhaseRemaining(_ seconds: Double) -> String {
        "this phase: " + formatRemaining(seconds)
    }

    /// Coarse for the same reason, and never counts down -- this one is measured.
    static func formatElapsed(_ seconds: Double) -> String {
        switch seconds {
        case ..<60:
            let s = Int(seconds.rounded())
            // Rounding can carry 59.5 s → 60; bump to "1 min" rather than "60 sec".
            if s >= 60 { return "1 min" }
            return "\(s) sec"
        case ..<3600:
            let m = Int((seconds / 60).rounded())
            // Rounding can carry 3570–3599 s → 60 min; bump to "1 hr 0 min".
            if m >= 60 { return "1 hr 0 min" }
            return "\(m) min"
        default:
            var hours = Int(seconds / 3600)
            var minutes = Int(((seconds - Double(hours) * 3600) / 60).rounded())
            // Rounding can carry e.g. 7199 s → 1 hr 60 min; propagate the carry.
            if minutes == 60 { hours += 1; minutes = 0 }
            return "\(hours) hr \(minutes) min"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.caption)
                    // Orange is reserved for something that went wrong. A job the
                    // user cancelled themselves is grey, like a running one.
                    .foregroundStyle(item.isError && !item.isCancelled
                                     ? .orange : .secondary)
                Text(item.title)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.action != .none {
                    Button(item.buttonTitle) { onAction(item) }
                        .controlSize(.small)
                        .accessibilityIdentifier("progressTray.action.\(item.id)")
                }
            }
            if !item.isError {
                if item.moving, let fraction = item.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    // Honest: the backend reports only that the phase began.
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(item.detail)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityIdentifier("progressTray.card.\(item.id)")
    }
}

/// The container. Bottom-trailing, capped in height, scrolling past the cap.
/// Natural height of the tray's rows, reported up from a background reader.
///
/// Measured rather than capped with `.frame(maxHeight:)`, because that modifier
/// does not cap: it makes a view FLEXIBLE up to the value, so against a tall
/// parent the tray expanded to the full allowance and drew a mostly-empty box.
/// Hugging exactly AND refusing to grow past a limit needs the real height.
private struct TrayContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ProgressTray: View {
    let items: [ProgressItem]
    let onAction: (ProgressItem) -> Void

    /// Minimised across launches: a long prediction outlives the window, and a
    /// user who collapsed the tray once means it for the whole session.
    @AppStorage("progressTrayCollapsed") private var collapsed = false

    @State private var contentHeight: CGFloat = 0

    /// Rendered rows. Bounded so SwiftUI's diff cost cannot grow with n_models.
    private static let maxRows = 8

    private var shown: ArraySlice<ProgressItem> { items.prefix(Self.maxRows) }
    private var overflow: Int { max(items.count - Self.maxRows, 0) }
    private var errorCount: Int { items.filter(\.isError).count }
    private var runningCount: Int { items.count - errorCount }

    /// Mean of whatever reports a real fraction. Nil when nothing does, which is
    /// why the collapsed pill falls back to a bare count rather than "0%".
    private var aggregate: Double? {
        let known = items.filter { !$0.isError && $0.moving }.compactMap(\.fraction)
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    private var summary: String {
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if errorCount > 0 { parts.append("\(errorCount) failed") }
        if collapsed, let f = aggregate {
            parts.append("\(Int((min(max(f, 0), 1) * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    /// Never taller than 45% of the viewport, and never taller than the viewport
    /// itself less its padding -- on iOS the tray is clipped to the viewport,
    /// which is far shorter than the window.
    private func cap(_ size: CGSize) -> CGFloat {
        max(120, min(size.height * 0.45, size.height - 32))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if !items.isEmpty { tray(in: geo.size) }
                }
            }
            .padding(16)
        }
        // Animate insert/remove and the collapse, NOT the 2 Hz fraction tick --
        // animating that would re-run the transition on every poll.
        .animation(.easeInOut(duration: 0.18), value: items.map(\.id))
        .animation(.easeInOut(duration: 0.18), value: collapsed)
        .allowsHitTesting(!items.isEmpty)
    }

    private func tray(in size: CGSize) -> some View {
        let limit = cap(size)
        let scrolls = contentHeight > limit
        return VStack(spacing: 0) {
            header
            if !collapsed {
                Divider().opacity(0.4)
                ScrollView(.vertical, showsIndicators: scrolls) {
                    rows.background(
                        GeometryReader { inner in
                            Color.clear.preference(
                                key: TrayContentHeightKey.self, value: inner.size.height)
                        })
                }
                .onPreferenceChange(TrayContentHeightKey.self) { contentHeight = $0 }
                // Hug the rows exactly; stop growing at the limit.
                .frame(height: min(max(contentHeight, 1), limit))
                // No rubber-banding on a tray that already fits.
                .scrollDisabled(!scrolls)
                // The native scrollbar only appears mid-scroll (#131), so the
                // fade is the resting cue that there is more below -- and only
                // when there IS more, or it would dim the last visible row.
                .mask(scrolls ? AnyView(fade) : AnyView(Color.black))
            }
        }
        // 340 + 2*16 padding = 372, against an iPhone SE's 375pt.
        .frame(width: min(340, size.width - 32))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.secondary.opacity(0.25)))
        .shadow(radius: 6)
    }

    private var fade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Collapsed, this is the only thing on screen saying a job failed,
            // so it carries the warning colour rather than staying neutral.
            if collapsed && errorCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text(summary)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show running jobs" : "Minimise")
            .accessibilityIdentifier("progressTray.collapse")
            .accessibilityLabel(collapsed ? "Show running jobs" : "Minimise progress tray")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown)) { item in
                ProgressCard(item: item, onAction: onAction)
                if item.id != shown.last?.id || overflow > 0 {
                    Divider().opacity(0.4)
                }
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}
