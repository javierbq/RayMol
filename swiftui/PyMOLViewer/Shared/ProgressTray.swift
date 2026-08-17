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
        /// Clear the published weight-fetch state via `engine.cancelWeightsDownload()`.
        /// Used on error cards: there is no running download to cancel, but the card
        /// must still be dismissable.
        case dismissWeightsFetch
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
            // Error cards have no running download to cancel, but still need a
            // Dismiss path; dismissWeightsFetch clears the published state locally.
            action: fetch.isError ? .dismissWeightsFetch
                                  : .command("predict_weights_cancel \(fetch.id)"),
            bundle: fetch.id)
    }

    static func prediction(_ job: PredictionJobState) -> ProgressItem {
        var parts: [String] = []
        if job.modelsTotal > 1 {
            parts.append("model \(min(job.modelsDone + 1, job.modelsTotal)) of \(job.modelsTotal)")
        }
        parts.append("\(ProgressCard.formatElapsed(job.elapsed)) elapsed")
        return ProgressItem(
            id: "predict:\(job.id)",
            icon: job.isError ? "exclamationmark.triangle.fill" : "atom",
            title: job.isError ? "Prediction failed: \(job.id)" : "Predicting \(job.id)",
            detail: job.isError ? (job.error ?? "Unknown error")
                                : ([job.phase.capitalized] + parts).joined(separator: " · "),
            fraction: job.fraction,
            moving: job.moving && !job.isError,
            isError: job.isError,
            buttonTitle: job.isError ? "Dismiss" : "Cancel",
            action: job.isError ? .command("predict_dismiss \(quoted(job.id))")
                                : .command("predict_cancel \(quoted(job.id))"),
            bundle: job.bundle)
    }

    /// Object names may contain spaces, and the command line splits on them.
    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// Everything the tray should show, in order.
    ///
    /// A static rather than a computed property on ContentView so the merge, the
    /// filter and the sort are unit-testable without instantiating a View.
    static func tray(weights: WeightsFetchState?,
                     predictions: [PredictionJobState]) -> [ProgressItem] {
        var items: [ProgressItem] = []
        if let weights { items.append(.weights(weights)) }
        // While a bundle is fetching, its OWN card is the measured one; a
        // prediction merely waiting on it would show the same transfer again at a
        // different number.
        let fetching = Set(items.compactMap(\.bundle))
        items += predictions
            .map(ProgressItem.prediction)
            .filter { item in item.bundle.map { !fetching.contains($0) } ?? true }
        // Running first, so a live job is never pushed below the fold by a stale
        // error card the user has not dismissed.
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
                    .foregroundStyle(item.isError ? .orange : .secondary)
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
struct ProgressTray: View {
    let items: [ProgressItem]
    let onAction: (ProgressItem) -> Void

    /// Rendered rows. Bounded so SwiftUI's diff cost cannot grow with n_models.
    private static let maxRows = 8

    private var shown: ArraySlice<ProgressItem> { items.prefix(Self.maxRows) }
    private var overflow: Int { max(items.count - Self.maxRows, 0) }

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        stack
                            // 340 + 2*16 padding = 372, against an iPhone SE's 375pt.
                            .frame(width: min(340, geo.size.width - 32))
                            .background(.ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.secondary.opacity(0.25)))
                            .shadow(radius: 6)
                            // A FRACTION, never a constant: on iOS the tray is
                            // clipped to the viewport, which is far shorter than
                            // the window.
                            .frame(maxHeight: max(140, geo.size.height * 0.45))
                            .padding(16)
                    }
                }
            }
        }
        // Animate insert/remove only -- NOT the 2 Hz fraction tick, which would
        // re-run the transition on every poll.
        .animation(.easeInOut(duration: 0.18), value: items.map(\.id))
        .allowsHitTesting(!items.isEmpty)
    }

    private var stack: some View {
        // Hug one or two cards; scroll past that. Same shape as
        // sceneButtonsOverlay's ViewThatFits, turned vertical.
        ViewThatFits(in: .vertical) {
            rows
            ScrollView(.vertical, showsIndicators: false) { rows }
                // The native scrollbar only appears mid-scroll (#131), so the
                // fade is the resting cue that there is more below. Applied to
                // the SCROLLING branch only -- on the outer view it would fade
                // the hugging branch too.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
        }
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
