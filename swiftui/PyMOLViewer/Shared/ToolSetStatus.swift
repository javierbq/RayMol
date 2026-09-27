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
/// **A run does not always create a set, and that was this line's first bug.** An
/// identical re-run -- same target, same options, same TYPED seed -- derives the same
/// design key, so `sets.batch.name_taken` answers False for the same tool against the
/// same reference, `designing._free_group_name` leaves the candidate alone and
/// `batch.open` appends a second run to the set the first one made. Measured: seed 7,
/// count 4, Generate, let it finish, Generate again -> one set, 8 entries, 2 runs, and
/// only 2 of the 4 new designs staged, because the free stage slots are
/// `budget - staged`, not `budget`. Both halves of "a new set * 4 entries * 4 staged"
/// were wrong, and only after the first batch had LANDED -- while it is still landing
/// the name is taken and bumps to `_2`, so the same button told the truth or not
/// depending on whether you waited. `sets_batch.py:417` and `:478` pin the Python.
///
/// So `extending` is not a prediction: it is `designing.preview_set` reporting a row it
/// READ, with that set's own name, its own budget and its own staged count.
///
/// **A new set still shows no NAME**, and that is the same honesty rather than a
/// leftover. The name would be `<generator>_batch_<key>` where `key` is a SHA-256 over
/// the target, the options and THE SEED -- and with the seed box empty (the default)
/// the seed is drawn at submit (`random.randrange`, designing.py:2921), so the digest
/// does not exist until the run does. Three more ways it could differ: `free_name` and
/// `_free_group_name` move a candidate aside to `_2` against sets, objects, groups and
/// live batches; for `n_designs = 1` the typed `name=` names the OBJECT while the set is
/// named as the batch would have been (designing.py:3078); and a preview that resolved
/// all of it would still be a name, not the name. A name that can differ from the one
/// created is worse than no name -- but a set that EXISTS has a name that cannot differ
/// from itself, which is why the extending case shows one.
struct PlannedSet: Equatable {
    /// The set this run will land in, when one already exists for this tool and target.
    struct Extending: Equatable {
        let name: String
        /// Entries of it with a live staged object right now. What makes the new
        /// designs' staged count `budget - staged` rather than `budget`.
        let stagedNow: Int

        init(name: String, stagedNow: Int) {
            self.name = name
            self.stagedNow = max(stagedNow, 0)
        }
    }

    /// `n` on the bar: one entry per member of the batch.
    let entries: Int
    /// The applicable stage budget -- `pymol.sets.binding.budget`, which prefers the
    /// SET's own `budget` column and falls back to the file's `meta.stage_budget`. Both
    /// come from Python (`DesignSetPlan.budget`) when a plan has arrived, so there is
    /// one copy of that rule; `SetsStore.defaultStageBudget()` is the fallback for the
    /// frame before the first round trip answers, and is the same number.
    let stageBudget: Int
    /// nil for a run that will create a set of its own.
    let extending: Extending?

    init(entries: Int, stageBudget: Int, extending: Extending? = nil) {
        self.entries = max(entries, 0)
        self.stageBudget = max(stageBudget, 0)
        self.extending = extending
    }

    /// How many members get an object as they land: the FREE stage slots, which an
    /// extended set has fewer of. The rest are entries in the container with no object
    /// until something stages them -- the whole point of a budget, and invisible unless
    /// it is said here.
    var staged: Int {
        min(entries, max(stageBudget - (extending?.stagedNow ?? 0), 0))
    }

    /// The one line the bar draws. `n = 1` gets it TOO, and says the same thing: #416
    /// makes a set for a single design as well (spec §8 decision 1), and a line that
    /// disappeared at `n = 1` would teach that a lone design is not in a set.
    var summary: String {
        let noun = entries == 1 ? "entry" : "entries"
        let head = extending.map { "→ extends “\($0.name)”" } ?? "→ a new set"
        guard staged > 0 else {
            // Reached when the set being extended has no free slot -- measured, with
            // `set_budget 2` and a settled two-design run: the entries are written and
            // `binder_design` says "budget full" per landing. (A budget of 0 cannot
            // happen: `set_budget` refuses below 1 and `defaultStageBudget()` only
            // accepts n > 0, so for a NEW set this branch is defensive only.)
            return "\(head) · \(entries) \(noun) · none staged, the budget is full"
        }
        return "\(head) · \(entries) \(noun) · \(staged) staged "
            + (staged == 1 ? "as it lands" : "as they land")
    }

    /// Why the line does not name a NEW set, and what "extends" means when it does name
    /// one. On the line itself as a tooltip rather than in the line, because it answers
    /// a question the reader only has once.
    var nameNote: String {
        if let extending {
            return "An identical earlier run made “\(extending.name)”, and this one"
                + " appends to it rather than making a second set: same tool, same"
                + " target, same options. \(extending.stagedNow) of its entries are"
                + " staged, so only the free slots of its budget of \(stageBudget) get"
                + " an object."
        }
        return "Every batch becomes a set (#416). Its name is a digest of the target,"
            + " the options and the seed — and with no seed typed the seed is drawn when"
            + " the run starts, so the name exists only once it has. It appears in the"
            + " SETS section and in the Data drawer the moment the batch opens."
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
/// while another is still landing). One takes the row and the rest are a `+N more` menu,
/// each carrying its own Open AND its own Cancel — a live batch must not be able to end up
/// with no Cancel anywhere in the bar.
///
/// **Ordered by SET ID, which is stable — deliberately not "newest first".** Newest first
/// was the first answer, and it is the hazard `ProgressTray.designBatch` was explicitly
/// designed against: with A running and B started, B takes the row and A drops into the
/// menu; when B finishes the row becomes A — same pixels, different set, different Cancel
/// target — so a click begun on B's Cancel can land on A's. A set id is assigned once and
/// never moves, so the row a pointer is travelling towards is the row it arrives at.
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
    /// The row then draws an INDETERMINATE bar and "landing…" rather than a confident
    /// "0 / 0" — the inspector badge's rule in this row's own vocabulary (that badge is a
    /// spinner; this is the same `ProgressView` with a nil value).
    let countsKnown: Bool
    /// Seconds left for the whole batch, or nil.
    ///
    /// **Python's number, not one composed here** — and what it is made of changes once.
    /// `designing._run_remaining` prices the designs still queued at the mean WALL TIME
    /// of the ones that have already succeeded (`batch['durations']`, banked in
    /// `deliver_result`) — or, before the first design completes, at the running design's
    /// own projection, which is the only evidence there is. Measured on a ten-design
    /// batch with nothing finished: `run_elapsed = 60`, phase remaining 60,
    /// `durations = ()` → 1140 s, so the row reads "19 min left" off one design's rate
    /// (`designing.py:1302`, the `elif left is not None` branch). It refuses to answer
    /// for the first ten seconds, between designs, and outside the dominant phase, which
    /// is what keeps it from being a confident number with nothing behind it.
    ///
    /// Nil is shown as nothing at all: the row falls back to `done / total`, which is
    /// counted rather than projected.
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

    /// Every batch of `tools`, in a stable order (by set id — see the type's note).
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
        // By SET ID, not by creation order: the row must not change identity under the
        // pointer when another batch of the same tool starts or finishes.
        return out.sorted { $0.setID < $1.setID }
    }
}

#if os(macOS)
extension PlannedSet {
    /// Build from what Python resolved, or from nothing at all.
    ///
    /// `plan == nil` is the pre-round-trip and no-set-store case and reads as a new set
    /// with the file's default budget -- which is what the bar said before #463's
    /// review, i.e. the fallback degrades to the old behaviour rather than to silence.
    ///
    /// macOS-only because `DesignSetPlan` is: the Binder Design bar and its Python round
    /// trip are. The value type above is not, so #420's iPad work can use it as is.
    init(entries: Int, plan: DesignSetPlan?, defaultBudget: Int) {
        var extending: Extending?
        if let plan, plan.extends, !plan.name.isEmpty {
            extending = Extending(name: plan.name, stagedNow: plan.staged)
        }
        self.init(entries: entries, stageBudget: plan?.budget ?? defaultBudget,
                  extending: extending)
    }
}

/// What differs between the two bars that draw the row: the command that cancels a whole
/// batch, and whether the row needs to say where the work came from.
///
/// A type rather than two parameters, so both answers are stated once, next to their
/// reasons, and can be asserted without a window (`ToolSetStatusTests`).
struct ToolBatchStyle: Equatable {
    /// The Python function whose one argument is a batch id, or **nil when this tool has
    /// no batch-level cancel at all**.
    ///
    /// nil is not "not yet": `predicting.pending_info` publishes no `batch`, so nothing
    /// on the wire ever names a predict set, and `predict_cancel` takes ONE OBJECT NAME.
    /// Passing `"predict_cancel"` here was inert only because `cancelJob` is always nil
    /// for a prediction today — the moment `predicting` publishes a batch (which the
    /// deferred collapsed tray row needs), it would start calling
    /// `predict_cancel('<set name>')`, which raises. nil makes that unreachable by
    /// construction instead of by coincidence (#463 review, fix 4).
    let cancelFunction: String?
    /// Said on the whole row, or nil when the row needs no explaining.
    let note: String?

    /// Binder Design: `design_cancel` takes the GROUP NAME of an `n_designs` batch, and
    /// that group name is the set's name.
    static let design = ToolBatchStyle(
        cancelFunction: "design_cancel",
        note: nil)

    /// Predict. The row is kept — it is the only place today that collapses a
    /// `predict set:` batch instead of showing one card per member — but a row inside a
    /// tool's bar reads as that tool's run, and with no Cancel beside it the absence
    /// reads as "this cannot be cancelled", which is false: every fold has its own tray
    /// card with one. So the row says where the work came from (#463 review, fix 5).
    static let predict = ToolBatchStyle(
        cancelFunction: nil,
        note: "Started from the Data drawer or the console; cancel individual folds in"
            + " the progress tray")
}

/// The progress row a tool bar draws for its own batches — "the place you start the work
/// is the place that reports it" (#463).
///
/// One view for both bars, because it is one report: they differ only in which tools they
/// drive and in their ``ToolBatchStyle``. It holds no decisions — `RunningToolBatch` and
/// that style made them all.
struct ToolBatchRow: View {
    let batches: [RunningToolBatch]
    let style: ToolBatchStyle
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

                // Only when a live job answers to the set's name AND this tool has a
                // batch cancel — see `RunningToolBatch.cancelJob` and
                // `ToolBatchStyle.cancelFunction`. A button that cannot name what it
                // stops is worse than no button.
                if let source = Self.cancelSource(style.cancelFunction, batch.cancelJob) {
                    Button("Cancel") { engine.runPython(source) }
                        .font(.system(size: 11)).buttonStyle(.plain)
                        .foregroundColor(.orange)
                        .accessibilityIdentifier("toolBatch.cancel")
                        .help("Stop the designs still running and queued in this batch")
                }

                // Every other live batch of this tool, each with its OWN Open and its own
                // Cancel: dropping out of the row must not drop a batch's only Cancel
                // (#463 review, fix 6).
                if batches.count > 1 {
                    Menu("+\(batches.count - 1) more") {
                        ForEach(batches.dropFirst()) { other in
                            Menu("\(other.setName) — \(other.detail)") {
                                Button("Open in the Data drawer") { open(other) }
                                if let source = Self.cancelSource(style.cancelFunction,
                                                                  other.cancelJob) {
                                    Button("Cancel this batch") {
                                        engine.runPython(source)
                                    }
                                }
                            }
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
            .help(style.note ?? "")
        }
    }

    /// The Python one-liner a Cancel runs, or nil when there is nothing to run.
    ///
    /// Pure and static so the two conditions (this tool HAS a batch cancel; a live job
    /// answers to this set's name) and the escaping are testable without a view.
    /// `runPython` and never the command channel: the PyMOL text parser does not strip
    /// the quotes from a quoted token, so a set name needs a real Python literal — and
    /// the import is load-bearing, since `__main__` starts empty in this embedding.
    static func cancelSource(_ function: String?, _ job: String?) -> String? {
        guard let function, !function.isEmpty, let job, !job.isEmpty else { return nil }
        return "from pymol import cmd as _c\n"
            + "_c.\(function)(\(PyMOLEngine.pythonLiteral(job)))"
    }

    private func open(_ batch: RunningToolBatch) {
        // The drawer's own door, so a batch opened from a bar and a set clicked in the
        // inspector land in exactly the same state.
        if let entry = engine.sets.first(where: { $0.id == batch.setID }) {
            engine.openSet(entry)
        }
    }
}
#endif
