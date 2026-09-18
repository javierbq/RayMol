import SwiftUI

// ToolSetStatus.swift — the two facts a tool's own bar never told anyone (#463).
//
// Everything the Sets epic built before this moves in ONE direction: out of the drawer,
// through Send to ▾, as a console command. No tool panel knew sets existed — so the bar
// that starts a batch did not say a batch becomes a set (#416 made every one of them
// one), and the batch reported its progress only as a badge in the inspector's SETS
// section, which is not where the work was started.
//
// Both halves are VALUE TYPES with no view in them, for the reason `SetTableModel`,
// `SetPlotModel` and `LineageModel` are: a bar is a stack of controls and the only thing
// worth testing about these is the arithmetic and the wording, neither of which needs a
// window. `ToolBatchRow` at the bottom is the one view, and it holds no decisions.

/// What pressing the tool's run button will create in the set store.
///
/// **There is no name here, and that is the finding rather than an omission.** The set a
/// `binder_design` run creates is named `<generator>_batch_<key>`, where `key` is
/// `DesignSpec.design_key` — a SHA-256 over the target's residues and coordinates, the
/// options, the weights version and THE SEED. With the seed box empty (the default, and
/// what the placeholder says) the seed does not exist until `designing.binder_design`
/// draws it at submit (`random.randrange`, designing.py:2921), so the digest cannot be
/// computed before Generate is pressed: any name shown here would be a name of a run that
/// is not the one about to start. Three more reasons the same way:
///
///   * even with a seed typed, the candidate passes `sets.batch.free_name` /
///     `designing._free_group_name`, which move it aside to `_2` against sets, objects,
///     groups and live batches — state that can change between this line being drawn and
///     the button being pressed;
///   * for `n_designs = 1` the `name=` a user typed is NOT the set's name at all. The set
///     is named as the batch would have been (designing.py:3078) while the object takes
///     the typed name, so echoing the box here would be wrong in the commonest case;
///   * a preview helper that resolved all of this would have to resolve the target, which
///     is the round trip the bar already pays for once.
///
/// A name that can differ from the one created is worse than no name, so the line says
/// what is certain — that a set is created, how many entries it will hold, and how many
/// of them appear as objects — and `nameNote` says when the name arrives.
struct PlannedSet: Equatable {
    /// `n` on the bar: one entry per member of the batch.
    let entries: Int
    /// The set's stage budget — `sets.binding.budget`, which is the file's
    /// `meta.stage_budget` or `binding.DEFAULT_BUDGET`. Read through
    /// `SetsStore.defaultStageBudget()`, the same source the drawer and the SETS
    /// section use; there is deliberately no second copy of this number in Swift.
    let stageBudget: Int

    init(entries: Int, stageBudget: Int) {
        self.entries = max(entries, 0)
        self.stageBudget = max(stageBudget, 0)
    }

    /// How many members get an object as they land. The rest are entries in the
    /// container with no object until something stages them — which is the whole point
    /// of a budget, and is invisible unless it is said here.
    var staged: Int { min(entries, stageBudget) }

    /// The one line the bar draws. `n = 1` gets it TOO, and says the same thing: #416
    /// makes a set for a single design as well (spec §8 decision 1), and a line that
    /// disappeared at `n = 1` would teach that a lone design is not in a set.
    var summary: String {
        let noun = entries == 1 ? "entry" : "entries"
        guard staged > 0 else {
            // Reachable only with a budget of 0, which `set_budget` allows: the entries
            // are written and nothing is drawn until the user stages something.
            return "→ a new set · \(entries) \(noun) · none staged"
        }
        return "→ a new set · \(entries) \(noun) · \(staged) staged "
            + (staged == 1 ? "as it lands" : "as they land")
    }

    /// Why the line does not name the set. On the line itself as a tooltip rather than
    /// in the line, because it answers a question the reader only has once.
    var nameNote: String {
        "Every batch becomes a set (#416). Its name is a digest of the target, the"
        + " options and the seed — and with no seed typed the seed is drawn when the run"
        + " starts, so the name exists only once it has. It appears in the SETS section"
        + " and in the Data drawer the moment the batch opens."
    }
}

/// A batch still landing, as the bar that drives its tool sees it.
///
/// **How a batch is matched to a bar**: by TOOL. `sets.batch.running()` publishes
/// `{done, total, tool}` per set id and nothing finer — no bar, no window, no submitter —
/// and the honest reading of that is "batches whose tool this bar drives": the ids in
/// `BinderDesignController.availableGenerators` for the Binder bar,
/// `PredictController.availablePredictors` for Predict. No new Python-side identity was
/// added to do better; one would have to be plumbed from the panel through `binder_design`
/// into `batch.open`, and until a second window can drive the same tool it would record
/// something nothing reads.
///
/// Two batches of one tool at once is therefore possible (an `n_designs=4` run submitted
/// while another is still landing). The NEWEST gets the row and the rest are a `+N more`
/// menu: they are one line each in a bar that is already four rows tall, the newest is the
/// one just started and so the one being watched, and every other one is one click from
/// its own set in the drawer. "Newest" is the container's own creation order — `SetsStore`
/// reads `ORDER BY s.created, s.rowid` — not a timestamp invented here.
struct RunningToolBatch: Equatable, Identifiable {
    let setID: String
    let setName: String
    /// The tool that opened the batch, as the marker said it — or, when the marker had
    /// to drop the counts and sent bare ids, the `sets.tool` column of the set itself.
    /// The two are written from the same string by `batch.open`, so the fallback is the
    /// same fact from the file rather than a guess.
    let tool: String
    let done: Int
    let total: Int
    /// Entries of this set that have a staged object right now, from the container —
    /// not the budget, which is what the PLAN above promises.
    let staged: Int
    /// False when the marker dropped the counts to stay under PyMOL's feedback-line cap.
    /// The row then shows a spinner and "landing…" rather than a confident "0 / 0", the
    /// same rule the inspector badge follows.
    let countsKnown: Bool
    /// Seconds left for the whole batch, or nil.
    ///
    /// **Measured, never guessed.** This is `designing._run_remaining`, which prices the
    /// designs still queued at the mean WALL TIME of the ones that have already
    /// succeeded (`batch['durations']`, banked in `deliver_result`) and smooths the
    /// result. It reaches Swift on the pending-job record as `run_remaining`, so it is
    /// present exactly when a job of this batch is on the wire and has been running long
    /// enough for Python to be willing to say. Nil is shown as nothing at all: the row
    /// falls back to `done / total`, which is measured too.
    let remaining: Double?
    /// What the tool's cancel command takes, or nil when nothing on the wire names this
    /// set. `design_cancel` accepts the GROUP NAME of an `n_designs` batch, and the group
    /// name IS the set name (`designing.binder_design`: `set_name = batch_id`), so a job
    /// whose `batch` is this set's name is the proof that the name is a live job id.
    ///
    /// Nil for a single design — it makes no group, so the set name names no job; its own
    /// tray card carries the only Cancel, which is where it has always been. Nil for every
    /// prediction, because `predicting.pending_info` publishes no `batch` at all and
    /// `predict_cancel` takes one object name, not a batch.
    let cancelJob: String?

    var id: String { setID }

    /// nil while the counts are unknown, so the bar draws an indeterminate bar rather
    /// than an empty one that looks like no progress.
    var fraction: Double? {
        guard countsKnown, total > 0 else { return nil }
        return min(max(Double(done) / Double(total), 0), 1)
    }

    /// "312 / 1000 · 6 staged · over an hour left".
    ///
    /// The estimate uses `ProgressCard.formatRemaining`, the tray's own buckets, so the
    /// bar and the tray cannot disagree about the same seconds. Those buckets top out at
    /// "over an hour left" — a to-the-hour countdown off a mean of a handful of designs
    /// is more precision than the number has — so a two-hour batch reads "over an hour
    /// left" here rather than the "~2 h left" #463 sketched.
    var detail: String {
        var parts = [countsKnown ? "\(done) / \(total)" : "landing…"]
        parts.append("\(staged) staged")
        if let remaining { parts.append(ProgressCard.formatRemaining(remaining)) }
        return parts.joined(separator: " · ")
    }

    /// Every batch of `tools`, newest first.
    ///
    /// Pure, and the whole matching rule is here: a bar passes the tool ids it can drive
    /// and gets back rows. With nothing running — or with every running batch belonging
    /// to another tool — it returns `[]` and the bar is byte-for-byte what it was before
    /// #463, which is the compatibility contract and what `ToolSetStatusTests` pins.
    static func forTools(_ tools: [String], sets: [SetEntry],
                         jobs: [PredictionJobState] = [],
                         countsKnown: Bool = true) -> [RunningToolBatch] {
        let driven = Set(tools.filter { !$0.isEmpty })
        guard !driven.isEmpty else { return [] }
        var out: [RunningToolBatch] = []
        for entry in sets {
            guard let progress = entry.running else { continue }
            let tool = progress.tool.isEmpty ? entry.tool : progress.tool
            guard driven.contains(tool) else { continue }
            // Terminal records are skipped: a failed or cancelled member is still on the
            // wire until it is dismissed, and its `run_remaining` is whatever it held
            // when it stopped. Only a live member can price what is left.
            let members = jobs.filter { $0.batch == entry.name && !$0.isError }
            out.append(RunningToolBatch(
                setID: entry.id, setName: entry.name, tool: tool,
                done: progress.done, total: progress.total, staged: entry.stagedCount,
                countsKnown: countsKnown && progress.total > 0,
                remaining: members.compactMap(\.runRemaining).first,
                cancelJob: members.isEmpty ? nil : entry.name))
        }
        return out.reversed()
    }
}

#if os(macOS)
/// The progress row a tool bar draws for its own batches — "the place you start the work
/// is the place that reports it" (#463).
///
/// One view for both bars, because it is one report: the Binder bar and the Predict bar
/// differ only in which tools they drive and which command cancels. It holds no decisions
/// — `RunningToolBatch` made them all — so there is nothing here to test that
/// `ToolSetStatusTests` does not already cover.
struct ToolBatchRow: View {
    let batches: [RunningToolBatch]
    /// The tool's cancel command, e.g. `design_cancel`. Called with `cancelJob`, through
    /// `runPython` and never the command channel: the PyMOL text parser does not strip
    /// the quotes from a quoted token, so a set name needs a real Python literal.
    let cancelFunction: String
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    var body: some View {
        if let batch = batches.first {
            HStack(spacing: 8) {
                Text(batch.setName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)

                ProgressView(value: batch.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                    .accessibilityIdentifier("toolBatch.bar")

                Text(batch.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
                    .lineLimit(1)
                    .accessibilityIdentifier("toolBatch.detail")

                Spacer(minLength: 0)

                Button("Open") { open(batch) }
                    .font(.system(size: 11)).buttonStyle(.plain)
                    .accessibilityIdentifier("toolBatch.open")
                    .help("Show this set in the Data drawer")

                // Only when a live job answers to the set's name — see
                // `RunningToolBatch.cancelJob`. A button that cannot name what it stops
                // is worse than no button.
                if let job = batch.cancelJob {
                    Button("Cancel") { cancel(job) }
                        .font(.system(size: 11)).buttonStyle(.plain)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("toolBatch.cancel")
                        .help("Stop the designs still running and queued in this batch")
                }

                if batches.count > 1 {
                    Menu("+\(batches.count - 1) more") {
                        ForEach(batches.dropFirst()) { other in
                            Button("\(other.setName) — \(other.detail)") { open(other) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 11))
                    .fixedSize()
                    .accessibilityIdentifier("toolBatch.more")
                    .help("Other batches of this tool still landing")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(theme.active.accent.color.opacity(0.08))
        }
    }

    private func open(_ batch: RunningToolBatch) {
        // The drawer's own door, so a batch opened from a bar and a set clicked in the
        // inspector land in exactly the same state.
        if let entry = engine.sets.first(where: { $0.id == batch.setID }) {
            engine.openSet(entry)
        }
    }

    private func cancel(_ job: String) {
        engine.runPython("from pymol import cmd as _c\n"
                         + "_c.\(cancelFunction)(\(PyMOLEngine.pythonLiteral(job)))")
    }
}
#endif
