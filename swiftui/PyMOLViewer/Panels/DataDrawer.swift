// DataDrawer.swift — the Data drawer, its Table tab and its filter bar (#417 and
// #418, spec §4.2, wireframe frames 1 and 2).
//
// The inspector is the SCENE column; tables want width, so the set browser is a
// drawer across the bottom of the viewport. This step ships the Table tab and the
// three verbs — peek, stage, pin — that make the triage loop work end to end for a
// design batch: sort, arrow through the top twenty, star, stage, save. #418 adds the
// filter bar, the header histograms as range brushes, the Plot tab (SetPlot.swift),
// linked selection and Send to ▾. The Sequences and Lineage tabs are #419; iPad and
// iPhone layouts are #420, so the views here are macOS-only and the drawer is simply
// absent on iOS.
//
// The filter is the one thing in here with a rule attached: Swift composes an
// expression STRING (`SetFilterComposer`) and sends it to Python, which compiles it
// with `pymol.sets.filter` and sends back the parameterised fragment. There is exactly
// one grammar and it is Python's; nothing below parses an expression, and a brush is
// nothing more than a range that knows how to print itself.
//
// `SetTableModel` is the part that is pure — sort, number format, budget arithmetic,
// the default sort direction and the colour ramp all fall out of `MetricSpec`, and
// none of it needs a window — so SetTableModelTests can pin it. The views below are
// thin over it.

import Foundation
import SwiftUI

// MARK: - Table model (pure)

/// Everything the Table tab computes from a set and its rows. A value type with no
/// SwiftUI in it, rebuilt on each render from published state — cheap for a
/// thousand rows, and free of the "which copy is current" problem a cached sort
/// would have when the store re-reads underneath it.
struct SetTableModel: Equatable {
    /// Scalar columns only, in declaration order. Array-scope metrics (residue,
    /// pair) have no cell in this table; they are for the Sequences tab (#419).
    let columns: [MetricColumn]
    let rows: [SetRow]
    /// "" = delivery order; "name"; or a metric column name.
    let sortKey: String
    let sortDescending: Bool
    let budget: Int
    let stagedCount: Int

    init(columns: [MetricColumn], rows: [SetRow], sortKey: String = "",
         sortDescending: Bool = true, budget: Int = SetsStore.defaultStageBudget,
         stagedCount: Int = 0) {
        self.columns = columns.filter { $0.isScalar }
        self.rows = rows
        self.sortKey = sortKey
        self.sortDescending = sortDescending
        self.budget = max(budget, 0)
        self.stagedCount = max(stagedCount, 0)
    }

    /// The model for a set as the store describes it, with an optional local sort
    /// override (a header click applies at once; the marker confirms a tick later).
    init(set: SetEntry, rows: [SetRow], sortKey: String? = nil, sortDescending: Bool? = nil) {
        self.init(columns: set.columns, rows: rows,
                  sortKey: sortKey ?? set.sortKey,
                  sortDescending: sortDescending ?? set.sortDescending,
                  budget: set.budget, stagedCount: set.stagedCount)
    }

    // MARK: sort

    /// The direction a column sorts on first click. `higher_is_better == false`
    /// (an RMSD, an energy) puts the best at the top by sorting ascending;
    /// everything else — including "neither", where the user most likely wants the
    /// large values — sorts descending.
    static func defaultDescending(_ column: MetricColumn) -> Bool {
        column.higherIsBetter != false
    }

    /// Rows in the active sort. NULLs go last whichever way the column sorts — an
    /// unmeasured entry is not "the worst" — and ties keep delivery order, so a
    /// re-sort is stable and the same file always shows the same table.
    var sorted: [SetRow] {
        guard !sortKey.isEmpty else { return rows.sorted { $0.ord < $1.ord } }
        if sortKey == "name" {
            return rows.sorted {
                let c = $0.name.localizedStandardCompare($1.name)
                if c != .orderedSame { return sortDescending ? c == .orderedDescending : c == .orderedAscending }
                return $0.ord < $1.ord
            }
        }
        if sortKey == "ord" || sortKey == "created" {
            return rows.sorted { sortDescending ? $0.ord > $1.ord : $0.ord < $1.ord }
        }
        guard columns.contains(where: { $0.column == sortKey }) else {
            return rows.sorted { $0.ord < $1.ord }
        }
        return rows.sorted { a, b in
            let va = a.values[sortKey] ?? .null
            let vb = b.values[sortKey] ?? .null
            switch (va, vb) {
            case (.null, .null):
                return a.ord < b.ord
            case (.null, _):
                return false
            case (_, .null):
                return true
            default:
                let order = Self.compare(va, vb)
                if order == .orderedSame { return a.ord < b.ord }
                return sortDescending ? order == .orderedDescending : order == .orderedAscending
            }
        }
    }

    /// Numbers before text, numbers numerically, text by locale.
    static func compare(_ a: MetricValue, _ b: MetricValue) -> ComparisonResult {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.number, .text):
            return .orderedAscending
        case (.text, .number):
            return .orderedDescending
        case (.text(let s), .text(let t)):
            return s.localizedStandardCompare(t)
        default:
            return .orderedSame
        }
    }

    /// What a header click does: a second click on the active column flips it, a
    /// first click applies the column's default direction.
    func toggledSort(_ key: String) -> (key: String, descending: Bool) {
        if key == sortKey { return (key, !sortDescending) }
        if let column = columns.first(where: { $0.column == key }) {
            return (key, Self.defaultDescending(column))
        }
        return (key, key != "name")
    }

    // MARK: format

    /// Decimals for a float column from its declared domain: 0–100 (pLDDT) reads
    /// at one decimal, 0–10 (an RMSD in Å) at two, 0–1 (ipTM) at three. With no
    /// domain, `%.3g` — three significant figures, whatever the magnitude.
    static func decimals(for column: MetricColumn) -> Int? {
        guard let lo = column.lo, let hi = column.hi, hi > lo else { return nil }
        let span = hi - lo
        if span >= 100 { return 1 }
        if span >= 10 { return 2 }
        return 3
    }

    /// The cell text. Null is an en dash — visibly "no value", not a zero and not
    /// blank (blank would read as "still loading" in a table that never does).
    static func format(_ value: MetricValue, _ column: MetricColumn) -> String {
        switch value {
        case .null:
            return "–"
        case .text(let s):
            return s
        case .number(let v):
            switch column.dtype {
            case "bool":
                return v != 0 ? "yes" : "no"
            case "int":
                return String(Int(v.rounded()))
            default:
                if let d = decimals(for: column) {
                    return String(format: "%.\(d)f", v)
                }
                return String(format: "%.3g", v)
            }
        }
    }

    /// The header text: label, with units when the spec has them.
    static func header(_ column: MetricColumn) -> String {
        column.units.isEmpty ? column.title : "\(column.title) (\(column.units))"
    }

    // MARK: colour ramp

    /// Where a value sits in the column's declared domain, 0…1, clamped. nil when
    /// the spec has no domain, the value is not a number, or the column is text:
    /// nothing to ramp against, so the cell stays untinted rather than auto-scaled
    /// to whatever this one set happens to contain (the metrics store's rule).
    static func rampFraction(_ value: MetricValue, _ column: MetricColumn) -> Double? {
        guard case .number(let v) = value, column.dtype != "str",
              let lo = column.lo, let hi = column.hi, hi > lo else { return nil }
        return min(max((v - lo) / (hi - lo), 0), 1)
    }

    /// The ramp oriented so 1 is GOOD: inverted for `higher_is_better == false`,
    /// nil when the spec says neither (an elapsed time has no good end).
    static func goodness(_ value: MetricValue, _ column: MetricColumn) -> Double? {
        guard let better = column.higherIsBetter, let f = rampFraction(value, column) else {
            return nil
        }
        return better ? f : 1 - f
    }

    // MARK: budget

    var budgetRemaining: Int { max(budget - stagedCount, 0) }
    var isOverBudget: Bool { stagedCount > budget }
    /// True when `n` more objects fit under the budget.
    func canStage(_ n: Int) -> Bool { n > 0 && stagedCount + n <= budget }

    /// Why Stage will not act on `n` rows, or nil when it will.
    ///
    /// The footer button is disabled on this and shows it, because the refusal
    /// otherwise reaches the user only as a `set_stage` warning in a console that
    /// may well be closed — so the button looked like it did nothing (#417 review).
    /// The text names the way out, the way `SetBudgetExceeded` does.
    func stageRefusal(_ n: Int) -> String? {
        if n < 1 { return "Select rows, or peek one, to stage" }
        guard !canStage(n) else { return nil }
        return "Staging \(n) more would put \(stagedCount + n) objects in the scene;"
            + " the budget is \(budget). Unstage or pin some first, or raise it"
            + " with set_budget."
    }

    /// The same refusal, short enough for the footer beside the count.
    func stageRefusalSummary(_ n: Int) -> String? {
        guard n >= 1, !canStage(n) else { return nil }
        return "\(n) selected · \(budgetRemaining) under budget"
    }
    /// "5 of 1024 staged · budget 6" — what the group row and the footer both say.
    var budgetLabel: String {
        "\(stagedCount) of \(rows.count) staged · budget \(budget)"
    }

    // MARK: stage state

    /// The leading state glyph: ● staged, ○ not, ◐ the entry in the peek object.
    static func stageGlyph(_ row: SetRow, peekedID: String?) -> String {
        if row.id == peekedID && !row.isStaged { return "◐" }
        return row.isStaged ? "●" : "○"
    }

    // MARK: keyboard navigation

    /// The row `step` places away from `id` in the sorted order; with no `id`,
    /// the first (step > 0) or last row. Clamped at the ends, so arrowing past
    /// the top stays on the top rather than wrapping.
    func neighbor(of id: String?, step: Int) -> SetRow? {
        let order = sorted
        guard !order.isEmpty else { return nil }
        guard let id, let index = order.firstIndex(where: { $0.id == id }) else {
            return step >= 0 ? order.first : order.last
        }
        let next = min(max(index + step, 0), order.count - 1)
        return order[next]
    }

    // MARK: histogram

    /// The range the histogram bins over: the spec's domain when it has one (so two
    /// runs of one tool draw on the same axis) and the observed range otherwise.
    ///
    /// Public and separate from `histogram` because a BRUSH has to invert it (#418): a
    /// drag across the bars is a range of pixels, and turning that back into
    /// `plddt >= 80 and plddt <= 92` needs the same two numbers the bars were binned
    /// over. Two copies of this arithmetic would be two copies that drift, and the
    /// symptom would be a brush that filters a range next to the one under the pointer.
    /// nil when there is nothing to bin.
    static func histogramDomain(values: [Double], lo: Double?, hi: Double?)
        -> ClosedRange<Double>? {
        let finite = values.filter { $0.isFinite }
        guard let observedLow = finite.min(), let observedHigh = finite.max() else { return nil }
        // Each bound independently: a MetricSpec may declare only one (a drift with
        // `lo=0` and no ceiling), and the declared end is the point — a histogram of
        // 0.4…0.6 that does not start at zero says the opposite of what the spec does,
        // and a brush on its leftmost bar writes `>= 0.4` rather than `>= 0`.
        var low = lo ?? observedLow
        var high = hi ?? observedHigh
        if !(high > low) {
            low = observedLow
            high = observedHigh
        }
        return high > low ? low...high : observedLow...observedLow
    }

    /// Bin `values` over `histogramDomain`. Values outside it land in the edge bins.
    /// Empty input → empty output.
    static func histogram(values: [Double], bins: Int, lo: Double?, hi: Double?) -> [Int] {
        guard bins > 0, !values.isEmpty else { return [] }
        let finite = values.filter { $0.isFinite }
        guard let domain = histogramDomain(values: finite, lo: lo, hi: hi) else { return [] }
        var counts = [Int](repeating: 0, count: bins)
        let low = domain.lowerBound, high = domain.upperBound
        if !(high > low) {
            // Every value is the same: one full bin in the middle.
            counts[bins / 2] = finite.count
            return counts
        }
        let width = (high - low) / Double(bins)
        for v in finite {
            var i = Int(((v - low) / width).rounded(.down))
            i = min(max(i, 0), bins - 1)
            counts[i] += 1
        }
        return counts
    }
}

/// One column's distribution over the WHOLE set, with the range it was binned over so
/// a brush can map pixels back to values (#418). Computed when the rows are re-read,
/// never per render — #417 measured the scan at ~0.5 ms for a thousand entries, and
/// paying it per frame is exactly the per-tick cost #421 forbids.
struct SetColumnHistogram: Equatable {
    let bins: [Int]
    let lo: Double
    let hi: Double

    var domain: ClosedRange<Double> { lo <= hi ? lo...hi : hi...lo }
    var isEmpty: Bool { bins.isEmpty || !(hi > lo) }
}

// MARK: - Brushes and the composed expression (pure)

/// A range dragged on one column's histogram — in the table header, or on a Plot axis
/// (#418, spec §4.2: "click the header histogram to brush a range").
///
/// It is a RANGE, not a predicate: the only thing it knows how to do is print itself as
/// `col >= lo and col <= hi`, which then goes to Python like anything typed. That is the
/// whole of Swift's part in the filter language — build a string — and it is deliberate.
/// The grammar has no BETWEEN and no arithmetic (spec §5), so this shape is not a
/// simplification of something richer; it is the language.
struct SetBrush: Equatable, Identifiable, Hashable {
    /// The wide-table column name (`plddt`, or `plddt__b` for a chain scalar).
    let column: String
    let lo: Double
    let hi: Double

    var id: String { column }

    init(column: String, lo: Double, hi: Double) {
        self.column = column
        self.lo = min(lo, hi)
        self.hi = max(lo, hi)
    }

    /// `plddt >= 80 and plddt <= 92`, or nil when the range is not something the
    /// grammar could read (a non-finite bound, or a column name that is not a column).
    var clause: String? {
        guard lo.isFinite, hi.isFinite, SetsStore.isSafeIdentifier(column) else { return nil }
        return "\(column) >= \(Self.literal(lo)) and \(column) <= \(Self.literal(hi))"
    }

    /// A number the filter tokenizer reads back as EXACTLY the same number.
    ///
    /// This used to print `%.6g`, and six significant figures is lossy for essentially
    /// every measured float. A pixel-derived drag does not care — its bounds are
    /// arbitrary — but "Filter to selection" composes from the selected points' own
    /// min and max, and rounding `lo` up or `hi` down excludes the very row that
    /// defined it: five points spanning 40.10274153313269…40.24152259971877 filtered
    /// to four, and the one that set the maximum was the one that vanished. With two
    /// axes there are four such boundaries, and the extremes are exactly what a triage
    /// user is hunting.
    ///
    /// Integral values print as integers — exact, and the grammar binds them as
    /// INTEGER, which is what an `int` column wants. Everything else uses Swift's
    /// `description`, the shortest form that round-trips, whose exponent spellings
    /// (`1e-05`, `1e+16`) the grammar's number reader accepts.
    static func literal(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// "80 – 92", for the chip that shows what is brushed. SIX significant figures, on
    /// purpose: this is read by a human, where `40.10274153313269` is noise. The
    /// clause it stands for is exact.
    static func displayLiteral(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.6g", v)
    }

    var rangeLabel: String { "\(Self.displayLiteral(lo)) – \(Self.displayLiteral(hi))" }
}

/// The one expression the drawer sends: what the user typed, ANDed with every brush.
///
/// Composition only — no parsing. The typed text is passed through verbatim (wrapped in
/// parentheses when it has to share with a brush, so a typed `a or b` is not swallowed
/// by the `and`), and `textOffset` says where it ended up, so a `SetFilterError` offset
/// coming back from Python can be mapped onto the characters the user actually typed.
/// Getting that wrong would underline the wrong token, which is worse than none.
struct ComposedFilter: Equatable {
    let expression: String
    /// Where the typed text starts inside `expression`, or -1 when it contributed none.
    let textOffset: Int

    /// The offset within the typed text that a Python error at `offset` points at, or
    /// nil when the error is in a brush clause rather than in anything typed.
    func textOffset(forExpressionOffset offset: Int, textLength: Int) -> Int? {
        guard textOffset >= 0, offset >= textOffset else { return nil }
        let local = offset - textOffset
        return local <= textLength ? local : nil
    }
}

enum SetFilterComposer {
    /// Join the typed expression and the brushes with `and`, each part parenthesised
    /// when there is more than one. An empty result means "no filter", which is what
    /// `filter.compile` maps an empty string to.
    static func compose(text: String, brushes: [SetBrush]) -> ComposedFilter {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clauses = brushes.sorted { $0.column < $1.column }.compactMap(\.clause)
        if clauses.isEmpty {
            // No brush: the typed text IS the expression, so every error offset that
            // comes back is already an offset into what the user sees.
            return ComposedFilter(expression: typed,
                                  textOffset: typed.isEmpty ? -1 : 0)
        }
        if typed.isEmpty {
            return ComposedFilter(expression: clauses.map { "(\($0))" }
                                    .joined(separator: " and "),
                                  textOffset: -1)
        }
        let parts = ["(\(typed))"] + clauses.map { "(\($0))" }
        return ComposedFilter(expression: parts.joined(separator: " and "), textOffset: 1)
    }

    /// The composed expression as a single typed string — what "Edit as text" does, so
    /// the user can see and change literally what went to `set_filter`.
    static func flattened(text: String, brushes: [SetBrush]) -> String {
        compose(text: text, brushes: brushes).expression
    }
}

#if os(macOS)

import AppKit
import UniformTypeIdentifiers

// MARK: - Drawer

/// The band below the viewport: a header naming the set and its tabs, the active
/// tab, and the footer with the selection actions. Hidden by default and absent on
/// iOS (#420). The set it shows is `engine.activeSetID`, which PYTHON owns (the
/// marker carries it), so an MCP agent's `appkit_sets.open_set` lands here too.
struct DataDrawer: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairline).frame(height: 1)
            if let set = engine.activeSet {
                // Keyed by the set, like the tabs below: the bar's debounced apply
                // captures the set it was typed into, and without this a click on
                // another set 600 ms later persisted a half-typed expression as the
                // FIRST set's filter — which is what `filtered` and Send to ▾ read.
                // Re-keying destroys the view, and its onDisappear cancels both.
                SetFilterBar(set: set)
                    .id(set.id)
                Rectangle().fill(hairline).frame(height: 1)
                switch engine.dataDrawerTab {
                case .plot:
                    SetPlotView(set: set, rows: engine.filteredSetRows)
                        .id(set.id)
                default:
                    SetTableView(set: set, rows: engine.filteredSetRows)
                        .id(set.id)      // a new set starts with a fresh selection
                }
            } else {
                emptyState
            }
        }
        .background(PanelTheme.background)
    }

    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }

    private var header: some View {
        HStack(spacing: 10) {
            Text("DATA")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(PanelTheme.headerColor)
            if let set = engine.activeSet {
                Text("·").foregroundColor(PanelTheme.disabledColor)
                Text(set.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PanelTheme.textColor)
                    .lineLimit(1)
                if let running = set.running {
                    RunningBadge(progress: running)
                }
            }
            tabStrip
            Spacer(minLength: 8)
            if let set = engine.activeSet {
                Text(SetTableModel(set: set, rows: engine.setRows).budgetLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(set.stagedCount > set.budget
                                     ? PanelTheme.atomTranspColor : PanelTheme.disabledColor)
                    .help("Staged entries are real objects in the set's group and count "
                          + "against the stage budget (set_budget). Pin one to keep it "
                          + "across \"clear staged\".")
                if engine.peekedEntryID != nil {
                    Button { engine.clearPeek() } label: {
                        Label("Clear peek", systemImage: "eye.slash")
                            .labelStyle(.iconOnly)
                            .font(.system(size: 11))
                            .foregroundColor(PanelTheme.headerColor)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the ghost cartoon (set_peek with no arguments)")
                }
            }
            Button { engine.closeDataDrawer() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(PanelTheme.headerColor)
            }
            .buttonStyle(.plain)
            .help("Close the Data drawer (⌘4)")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    /// Table and Plot ship; Sequences and Lineage are drawn DISABLED rather than
    /// hidden: the drawer's shape is decided (spec §4), and a user who sees where they
    /// will go learns the layout once.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(DataDrawerTab.allCases) { item in
                tab(item)
            }
        }
    }

    private func tab(_ item: DataDrawerTab) -> some View {
        let active = engine.dataDrawerTab == item
        return Text(item.rawValue)
            .font(.system(size: 10, weight: active ? .semibold : .regular))
            .foregroundColor(!item.isAvailable ? PanelTheme.disabledColor
                             : (active ? PanelTheme.textColor : PanelTheme.headerColor))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                            .fill(active ? PanelTheme.buttonBackground : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { if item.isAvailable { engine.dataDrawerTab = item } }
            .help(item.help)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No set open")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(PanelTheme.textColor)
            Text(engine.sets.isEmpty
                 ? "Sets appear in the inspector's SETS section once a batch delivers "
                   + "into one, or after set_create / set_import at the command line."
                 : "Click a set in the inspector's SETS section to browse it here.")
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.disabledColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "3 / 10 rfd3" with a spinner, while a batch is still landing in a set.
struct RunningBadge: View {
    let progress: BatchProgress

    /// Nothing known but "it is running": the marker dropped the counts to stay
    /// under the feedback-line cap (see appkit_sets.marker). Showing the spinner
    /// alone is honest; "0 / 0" would not be.
    private var countsKnown: Bool { progress.done > 0 || progress.total > 0 }

    var body: some View {
        HStack(spacing: 4) {
            ProgressView().progressViewStyle(.circular).controlSize(.mini)
                .frame(width: 10, height: 10)
            if countsKnown {
                Text(progress.total > 0 ? "\(progress.done) / \(progress.total)" : "\(progress.done)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(PanelTheme.disabledColor)
            }
            if !progress.tool.isEmpty {
                Text(progress.tool)
                    .font(.system(size: 9))
                    .foregroundColor(PanelTheme.disabledColor)
            }
        }
        .help(countsKnown ? "A batch is still delivering into this set"
                          : "A batch is still delivering into this set (progress unavailable)")
    }
}

// MARK: - Table tab

/// The virtualized table. A `List` (NSTableView underneath, so only visible rows
/// exist) rather than SwiftUI `Table`: the columns are DATA — a fifth predictor adds
/// one with no UI edit — and `Table` cannot take a dynamic column list on the
/// macOS 14.0 floor. Sorting, formatting and the ramp are `SetTableModel`.
///
/// Keys, while the list has focus: ↑↓ move the peek, space stages/unstages, `s`
/// stars, `x` rejects. Esc is NOT here: ContentView's Esc monitor consumes
/// keyCode 53 ahead of the responder chain, so it clears the peek as a rung of
/// that ladder (engine.clearPeekIfShowing) and a handler here would be dead. Hover peeks after a short debounce, so a sweep down the
/// table costs one load at the row the pointer settles on, not one per row.
struct SetTableView: View {
    let set: SetEntry
    let rows: [SetRow]
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    /// The selection lives on the ENGINE, not here: the plot brushes into the same
    /// set and the viewport writes into it too (#418). One selection, three places to
    /// change it, which is what "linked" means.
    private var selection: Binding<Set<String>> {
        Binding(get: { engine.setSelection }, set: { engine.setSelection = $0 })
    }
    /// Local sort override, applied the instant a header is clicked; the marker
    /// brings the store's copy of the same choice a tick later and it matches.
    @State private var sortKey: String? = nil
    @State private var sortDescending: Bool? = nil
    @State private var hoverWork: DispatchWorkItem? = nil
    @State private var showSaveView = false
    @State private var viewName = ""
    @FocusState private var listFocused: Bool

    private static let starWidth: CGFloat = 20
    private static let stateWidth: CGFloat = 20
    private static let nameWidth: CGFloat = 150
    private static let rowHeight: CGFloat = 22
    /// Metric columns share what is left of the width, between these bounds.
    private static let metricMin: CGFloat = 60
    private static let metricMax: CGFloat = 110

    private var model: SetTableModel {
        // Hidden columns are dropped HERE rather than in the store: which columns show
        // is a property of this view on the data (and of a saved view), not of the set.
        SetTableModel(columns: set.columns.filter { !engine.setHiddenColumns.contains($0.column ?? "") },
                      rows: rows,
                      sortKey: sortKey ?? set.sortKey,
                      sortDescending: sortDescending ?? set.sortDescending,
                      budget: set.budget, stagedCount: set.stagedCount)
    }

    /// What the footer's verbs act on: the selection, else the peeked row.
    private var actionRows: [SetRow] {
        if !engine.setSelection.isEmpty {
            return rows.filter { engine.setSelection.contains($0.id) }
        }
        if let peeked = engine.peekedEntryID, let row = rows.first(where: { $0.id == peeked }) {
            return [row]
        }
        return []
    }

    /// Every scalar column, hidden or not — what the Columns ▾ menu offers and what a
    /// saved view records as "visible".
    private var allScalarColumns: [MetricColumn] { self.set.columns.filter(\.isScalar) }
    private var visibleColumnNames: [String] {
        allScalarColumns.compactMap(\.column)
            .filter { !engine.setHiddenColumns.contains($0) }
    }

    var body: some View {
        let model = self.model
        GeometryReader { geo in
            let metricWidth = Self.metricWidth(total: geo.size.width, columns: model.columns.count)
            VStack(spacing: 0) {
                headerRow(model: model, metricWidth: metricWidth)
                // Spec §4.2: "column headers are the filter UI". One strip per column,
                // draggable, writing `col >= lo and col <= hi` into the same filter
                // every other route goes through.
                histogramRow(model: model, metricWidth: metricWidth)
                Rectangle().fill(hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    List(model.sorted, id: \.id, selection: selection) { row in
                        SetTableRowView(row: row, columns: model.columns,
                                        metricWidth: metricWidth,
                                        isPeeked: row.id == engine.peekedEntryID,
                                        onStar: { engine.setStar(set, [row], on: !row.starred) },
                                        onToggleStage: { engine.toggleStage(set, [row]) })
                            .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                            .listRowSeparator(.hidden)
                            .onHover { inside in if inside { schedulePeek(row) } }
                            .contextMenu { rowMenu(row) }
                            .id(row.id)
                    }
                    .listStyle(.plain)
                    .environment(\.defaultMinListRowHeight, Self.rowHeight)
                    .scrollContentBackground(.hidden)
                    .background(PanelTheme.background)
                    .focused($listFocused)
                    .onKeyPress(.upArrow) { movePeek(-1, proxy: proxy); return .handled }
                    .onKeyPress(.downArrow) { movePeek(+1, proxy: proxy); return .handled }
                    .onKeyPress(.space) { stageAction(); return .handled }
                    .onKeyPress(KeyEquivalent("s")) { starAction(); return .handled }
                    .onKeyPress(KeyEquivalent("x")) { rejectAction(); return .handled }
                    // Viewport -> row (#418). The marker already tells us which of the
                    // set's STAGED objects hold atoms of `sele`; clicking one in the
                    // viewport therefore lands here, with no poll of our own and with
                    // no second object -> entry mapping: the link is
                    // `entries.staged_object`, read by SetsStore with the row.
                    .onChange(of: engine.setViewportSelection) { ids in
                        guard let first = ids.first,
                              rows.contains(where: { $0.id == first }) else { return }
                        engine.setSelection = Set(ids)
                        withAnimation(nil) { proxy.scrollTo(first) }
                    }
                    // A brush in the Plot tab selects rows; coming back to the table
                    // should show them rather than leave the user to hunt.
                    .onChange(of: engine.setSelection) { ids in
                        guard ids.count == 1, let only = ids.first,
                              rows.contains(where: { $0.id == only }) else { return }
                        withAnimation(nil) { proxy.scrollTo(only) }
                    }
                }
                Rectangle().fill(hairline).frame(height: 1)
                footer(model: model)
            }
        }
        .onDisappear { hoverWork?.cancel() }
        .alert("Save view", isPresented: $showSaveView) {
            TextField("View name", text: $viewName)
            Button("Save") {
                engine.saveSetView(set, named: viewName, columns: visibleColumnNames)
                viewName = ""
            }
            Button("Cancel", role: .cancel) { viewName = "" }
        } message: {
            Text("Saves the set's active filter, sort and visible columns as a named "
                 + "view (set_view_save), usable as view:NAME in every set_* command "
                 + "and as predict set:\(set.name)@view:NAME.")
        }
    }

    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }

    static func metricWidth(total: CGFloat, columns: Int) -> CGFloat {
        let fixed = starWidth + stateWidth + nameWidth + 24
        guard columns > 0, total.isFinite, total > fixed else { return metricMin }
        return min(max((total - fixed) / CGFloat(columns), metricMin), metricMax)
    }

    // MARK: header

    private func headerRow(model: SetTableModel, metricWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("☆").frame(width: Self.starWidth)
                .help("Starred")
            Text("◐").frame(width: Self.stateWidth)
                .help("● staged  ○ not staged  ◐ peeked")
            headerCell("name", title: "id", model: model, alignment: .leading)
                .frame(width: Self.nameWidth, alignment: .leading)
            ForEach(model.columns) { column in
                headerCell(column.column ?? column.id, title: SetTableModel.header(column),
                           model: model, alignment: .trailing)
                    .frame(width: metricWidth, alignment: .trailing)
                    .help(column.tool.isEmpty ? column.key : "\(column.key) — \(column.tool)")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(PanelTheme.headerColor)
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    private func histogramRow(model: SetTableModel, metricWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: Self.starWidth + Self.stateWidth + Self.nameWidth)
            ForEach(model.columns) { column in
                SetHistogramBrushView(
                    column: column,
                    bins: engine.setHistograms[column.column ?? ""]?.bins ?? [],
                    domain: engine.setHistograms[column.column ?? ""]?.domain,
                    brush: engine.setBrushes.first { $0.column == column.column },
                    onBrush: { brush, commit in
                        engine.updateBrush(set, brush, column: column.column ?? "",
                                           commit: commit)
                    })
                    .frame(width: metricWidth, height: 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: 16)
    }

    private func headerCell(_ key: String, title: String, model: SetTableModel,
                            alignment: Alignment) -> some View {
        let active = model.sortKey == key
        return Button {
            let next = model.toggledSort(key)
            sortKey = next.key
            sortDescending = next.descending
            engine.setSort(set, key: next.key, descending: next.descending)
        } label: {
            HStack(spacing: 2) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title).lineLimit(1).truncationMode(.middle)
                if active {
                    Image(systemName: model.sortDescending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundColor(active ? PanelTheme.textColor : PanelTheme.headerColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: footer

    private func footer(model: SetTableModel) -> some View {
        let targets = actionRows
        let unstaged = targets.filter { !$0.isStaged }
        let staged = targets.filter { $0.isStaged }
        return HStack(spacing: 8) {
            Text(engine.setSelection.isEmpty
                 ? "\(rows.count) entries"
                 : "\(engine.setSelection.count) of \(rows.count) selected")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
            if model.isOverBudget {
                Text("over budget")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(PanelTheme.atomTranspColor)
                    .help("More objects are staged than the budget allows; unstage "
                          + "some or raise it with set_budget.")
            }
            // The budget refusal, where the click is (#417 review). Without it the
            // only account of why nothing happened went to the console.
            if let summary = model.stageRefusalSummary(unstaged.count) {
                Text(summary)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(PanelTheme.atomTranspColor)
                    .help(model.stageRefusal(unstaged.count) ?? "")
            }
            Spacer()
            let stageRefusal = model.stageRefusal(unstaged.count)
            footerButton("Stage", help: stageRefusal
                         ?? "Load \(unstaged.count) as objects in the set's group (set_stage)") {
                engine.stage(set, unstaged)
            }
            .disabled(stageRefusal != nil)
            footerButton("Unstage", help: "Delete the staged objects, keep the entries (set_unstage)") {
                engine.unstage(set, staged)
            }
            .disabled(staged.isEmpty)
            footerButton(staged.allSatisfy(\.pinned) && !staged.isEmpty ? "Unpin" : "Pin",
                         help: "A pinned object survives \"clear staged\" (set_pin)") {
                let on = !(staged.allSatisfy(\.pinned) && !staged.isEmpty)
                engine.setPin(set, staged, on: on)
            }
            .disabled(staged.isEmpty)
            columnsMenu
            SetSendMenu(set: set, target: sendTarget,
                        exportCSV: { exportPanel(ext: "csv") },
                        exportFASTA: { exportPanel(ext: "fasta") },
                        exportFolder: { exportFolder() })
            footerButton("Save view…",
                         help: "Save the active filter, sort and visible columns as a "
                             + "view (set_view_save)") {
                showSaveView = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    /// What Send to ▾ acts on: the rows the user picked, else the active filter — the
    /// same fallback every `set_*` command has, so an empty selection means "everything
    /// that passes" rather than nothing.
    private var sendTarget: SetSendTarget {
        let names = actionRows.map(\.name)
        return names.isEmpty ? .filtered : .selection(names)
    }

    /// Which columns show. A property of this view on the data, saved into a view
    /// rather than into the set, so two people can look at one set differently.
    private var columnsMenu: some View {
        Menu {
            ForEach(allScalarColumns) { column in
                let name = column.column ?? ""
                Button {
                    if engine.setHiddenColumns.contains(name) {
                        engine.setHiddenColumns.remove(name)
                    } else {
                        engine.setHiddenColumns.insert(name)
                    }
                } label: {
                    Label(SetTableModel.header(column),
                          systemImage: engine.setHiddenColumns.contains(name) ? "" : "checkmark")
                }
            }
            Divider()
            Button("Show all") { engine.setHiddenColumns = [] }
        } label: {
            Text("Columns").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hide columns you are not triaging on. Saved with a view (set_view_save).")
    }

    private func footerButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10))
        }
        .controlSize(.small)
        .help(help)
    }

    // MARK: row menu

    @ViewBuilder private func rowMenu(_ row: SetRow) -> some View {
        Button("Peek") { engine.peekEntry(set, row) }
        Button(row.isStaged ? "Unstage" : "Stage") { engine.toggleStage(set, [row]) }
        if row.isStaged {
            Button(row.pinned ? "Unpin" : "Pin") { engine.setPin(set, [row], on: !row.pinned) }
            Button("Zoom to object") {
                if let obj = row.stagedObject {
                    engine.runCommand("zoom \(obj), animate=-1")
                }
            }
        }
        Divider()
        Button(row.starred ? "Unstar" : "Star") { engine.setStar(set, [row], on: !row.starred) }
        Button(row.rejected ? "Unreject" : "Reject") { engine.setReject(set, [row], on: !row.rejected) }
        Divider()
        Button("Copy name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.name, forType: .string)
        }
    }

    // MARK: actions

    /// Hover → peek, after 120 ms of the pointer resting on the row. A peek is N
    /// chain loads plus a superposition; without the debounce a sweep down a
    /// thousand rows would queue a thousand of them.
    private func schedulePeek(_ row: SetRow) {
        hoverWork?.cancel()
        guard row.id != engine.peekedEntryID else { return }
        let work = DispatchWorkItem { [set] in engine.peekEntry(set, row) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func movePeek(_ step: Int, proxy: ScrollViewProxy) {
        hoverWork?.cancel()
        // From the selection when there is one and nothing is peeked yet, so
        // "click a row, press ↓" starts from where the user is looking.
        let anchor = engine.peekedEntryID ?? engine.setSelection.first
        guard let next = model.neighbor(of: anchor, step: step) else { return }
        engine.peekEntry(set, next)
        engine.setSelection = [next.id]
        withAnimation(nil) { proxy.scrollTo(next.id) }
    }

    /// Space: stage the target rows, or unstage them when every one is staged.
    /// The toggle itself is Python's (appkit_sets.toggle_stage), so the drawer and
    /// the console agree on what a mixed selection means.
    private func stageAction() {
        let targets = actionRows
        guard !targets.isEmpty else { return }
        engine.toggleStage(set, targets)
    }

    private func starAction() {
        let targets = actionRows
        guard !targets.isEmpty else { return }
        engine.setStar(set, targets, on: !targets.allSatisfy(\.starred))
    }

    private func rejectAction() {
        let targets = actionRows
        guard !targets.isEmpty else { return }
        engine.setReject(set, targets, on: !targets.allSatisfy(\.rejected))
    }

    private func exportPanel(ext: String) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(set.name).\(ext)"
        panel.canCreateDirectories = true
        panel.title = "Export \(set.name) as \(ext.uppercased())"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.exportSet(set, to: url.path, rows: actionRows)
    }

    private func exportFolder() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = set.name
        panel.canCreateDirectories = true
        panel.title = "Export \(set.name) as a folder of CIFs + entries.csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.exportSet(set, to: url.path, rows: actionRows)
    }
}

// MARK: - Filter bar (#418)

/// The expression field, the live count and the brush chips (spec §4.2).
///
/// Two debounces, and the difference between them is the whole design:
///
///   * PREVIEW, at 120 ms — `appkit_sets.preview_filter`. Compiles the expression and
///     reports the count and any error. It does NOT write, so typing does not bump the
///     container's version, and a thousand rows are not re-read per keystroke.
///   * APPLY, at 600 ms of quiet (or on Return) — `set_filter`. The expression becomes
///     the SET's, which is what `filtered`, `top:N`, `set_export` and
///     `predict set:x@filtered` all read. Without this the drawer would show one
///     population and Send to ▾ would act on another.
///
/// Nothing here parses. The field's text goes to `SetFilterComposer`, which joins it
/// with the brushes, and Python decides what the result means; what comes back is a
/// count, a message and an offset, and the offset is mapped back onto the typed text by
/// the composer so the token quoted in the error is the token the user can see.
struct SetFilterBar: View {
    let set: SetEntry
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var previewWork: DispatchWorkItem? = nil
    @State private var applyWork: DispatchWorkItem? = nil
    @FocusState private var fieldFocused: Bool

    private var composed: ComposedFilter {
        SetFilterComposer.compose(text: engine.setFilterText, brushes: engine.setBrushes)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.headerColor)
            TextField("filter: plddt > 80 and rmsd < 1.5 and not rejected",
                      text: Binding(get: { engine.setFilterText },
                                    set: { engine.setFilterText = $0; schedule() }))
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospaced())
                .foregroundColor(PanelTheme.textColor)
                .focused($fieldFocused)
                .onSubmit { applyNow() }
                .frame(minWidth: 160)
                .help("An expression over this set's columns, the flags (starred, "
                      + "rejected, staged, pinned), name and tags. The same language "
                      + "set_filter takes, because it IS set_filter.")
            chips
            if !engine.setBrushes.isEmpty {
                // The brushes, flattened into the field. Spec §4.2 says a brush
                // "writes the expression into the filter bar"; keeping them as chips
                // until asked is what makes "clear this one column" possible, and
                // this is the way to the other half — the literal string that went to
                // set_filter, editable.
                Button("Edit as text") {
                    engine.setFilterText = SetFilterComposer.flattened(
                        text: engine.setFilterText, brushes: engine.setBrushes)
                    engine.setBrushes = []
                    applyNow()
                }
                .controlSize(.mini)
                .font(.system(size: 9))
                .help("Write the brushes into the field as the expression they are, so "
                      + "you can edit it. The filter does not change.")
            }
            if !engine.setFilterText.isEmpty || !engine.setBrushes.isEmpty {
                Button {
                    engine.setFilterText = ""
                    engine.setBrushes = []
                    applyNow()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(PanelTheme.disabledColor)
                .help("Clear the filter; every entry comes back (set_filter with no expression)")
            }
            Spacer(minLength: 6)
            status
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .onDisappear {
            previewWork?.cancel()
            applyWork?.cancel()
        }
    }

    /// One chip per brushed column: what is brushed, and the way to drop just that one
    /// (spec §4.2, "allow clearing per column").
    private var chips: some View {
        ForEach(engine.setBrushes) { brush in
            HStack(spacing: 3) {
                Text("\(columnTitle(brush.column)) \(brush.rangeLabel)")
                    .font(.system(size: 9).monospacedDigit())
                Button {
                    engine.updateBrush(set, nil, column: brush.column, commit: true)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(PanelTheme.accentColor.opacity(0.18)))
            .foregroundColor(PanelTheme.textColor)
            .help("Brushed on the \(columnTitle(brush.column)) histogram. As an "
                  + "expression: \(brush.clause ?? "") — click × to drop it.")
        }
    }

    /// The count, or the grammar's complaint. Spec §4.2 asks for "212 of 1024 match";
    /// an error replaces it, because a count next to a rejected expression would be a
    /// count of the PREVIOUS filter and would read as if the new one had worked.
    @ViewBuilder private var status: some View {
        HStack(spacing: 6) {
            // The viewport pointed at a row the filter is hiding (#418 review R3).
            // Doing nothing and saying nothing was the previous behaviour.
            if let hidden = engine.viewportSelectionHidden.first {
                Button("Show \(hidden.name)") {
                    engine.setFilterText = ""
                    engine.setBrushes = []
                    applyNow()
                }
                .controlSize(.mini)
                .font(.system(size: 9))
                .help("\(hidden.name) is the entry of the object you clicked, and the "
                      + "active filter excludes it. This clears the filter.")
            }
            if !engine.setFilter.error.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text(errorText)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(PanelTheme.atomTranspColor)
                // The table has NOT changed — a rejected expression was never applied,
                // so what is on screen is still the set's filter. Saying so is the
                // other half of keeping the rows (see filterMatchDecision).
                .help(engine.setFilter.error + "\n\nThe table still shows the set's "
                      + "filter; nothing was applied.")
            } else {
                // Both numbers from the rows on screen, never from the payload: during
                // a landing batch the expression does not change, so Python does not
                // re-compile and its count goes stale while the table keeps
                // re-filtering locally.
                Text(engine.setFilter.countLabel(matched: engine.filteredSetRows.count,
                                                 total: engine.setRows.count))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(engine.setFilter.isActive ? PanelTheme.textColor
                                                               : PanelTheme.disabledColor)
                    .help(engine.setFilter.isActive
                          ? "Entries matching the active filter, out of the whole set"
                          : "No filter; every entry is shown")
            }
        }
    }

    /// The message with the offending token quoted, when the failure is in something
    /// the user typed. An offset inside a BRUSH clause is not quoted back: the user did
    /// not type it, and pointing at a character they cannot see is worse than not
    /// pointing at all.
    private var errorText: String {
        let state = engine.setFilter
        guard let local = composed.textOffset(forExpressionOffset: state.offset,
                                              textLength: engine.setFilterText.count),
              let token = SetFilterState.token(in: engine.setFilterText, at: local) else {
            return state.error
        }
        return "\(state.error) — at ‘\(token)’"
    }

    private func columnTitle(_ name: String) -> String {
        set.columns.first { $0.column == name }?.title ?? name
    }

    /// Both work items read the engine at FIRE time rather than capturing what was
    /// composed at this keystroke. A brush that changes in between — a header drag,
    /// "Filter to selection", a chip's × — goes through the engine, where these
    /// `@State` items cannot see it and cannot be cancelled by it; a captured
    /// expression therefore either dropped the brush while its chip was still on
    /// screen or resurrected one the user had just removed.
    private func schedule() {
        previewWork?.cancel()
        applyWork?.cancel()
        let preview = DispatchWorkItem { engine.previewCurrentFilter(set) }
        let apply = DispatchWorkItem { engine.applyCurrentFilter(set) }
        previewWork = preview
        applyWork = apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: preview)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: apply)
    }

    private func applyNow() {
        previewWork?.cancel()
        applyWork?.cancel()
        engine.applyCurrentFilter(set)
    }
}

// MARK: - The header / axis histogram, as a range brush (#418)

/// A column's distribution, with a drag that turns into `col >= lo and col <= hi`.
///
/// One component, used by the table header and by the Plot tab's x axis, so "brush a
/// range" is one behaviour with one implementation and one expression shape. The view
/// maps pixels to values through `domain` — the SAME range the bars were binned over
/// (`SetTableModel.histogramDomain`), which is why that function is public: two copies
/// of the arithmetic would drift, and the symptom would be a brush that filters the
/// range next to the one under the pointer.
///
/// A drag PREVIEWS as it moves and APPLIES when it ends, so a sweep across the bars
/// does not write to the container once per pixel. A click without a drag clears the
/// column's brush, which is the cheapest possible "undo this one".
struct SetHistogramBrushView: View {
    let column: MetricColumn?
    let bins: [Int]
    let domain: ClosedRange<Double>?
    let brush: SetBrush?
    /// (brush or nil to clear, commit) — commit is false while the drag is live.
    let onBrush: (SetBrush?, Bool) -> Void

    @State private var dragFrom: CGFloat? = nil
    @State private var dragTo: CGFloat? = nil
    @State private var previewWork: DispatchWorkItem? = nil

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.clear)
                if !bins.isEmpty {
                    bars(width: width, height: height)
                }
                if let region = selectionRegion(width: width) {
                    Rectangle()
                        .fill(PanelTheme.accentColor.opacity(0.22))
                        .frame(width: max(region.width, 1), height: height)
                        .offset(x: region.minX)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFrom = dragFrom ?? value.startLocation.x
                        dragTo = value.location.x
                        // Debounced for the reason the filter field's preview is: a
                        // sweep across the bars is dozens of drag events, and each
                        // preview compiles the expression and counts twice on the
                        // PyMOL thread. The highlight follows the pointer regardless —
                        // it is drawn from `dragFrom`/`dragTo`, not from the preview.
                        if let brush = brush(from: dragFrom!, to: value.location.x, width: width) {
                            previewWork?.cancel()
                            let work = DispatchWorkItem { onBrush(brush, false) }
                            previewWork = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
                        }
                    }
                    .onEnded { value in
                        previewWork?.cancel()
                        let from = dragFrom ?? value.startLocation.x
                        dragFrom = nil
                        dragTo = nil
                        if abs(value.location.x - from) < 2 {
                            // A click, not a drag: drop this column's brush.
                            onBrush(nil, true)
                        } else {
                            onBrush(brush(from: from, to: value.location.x, width: width), true)
                        }
                    })
            .help(helpText)
        }
    }

    private func bars(width: CGFloat, height: CGFloat) -> some View {
        let peak = max(bins.max() ?? 1, 1)
        let barWidth = width / CGFloat(bins.count)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(bins.enumerated()), id: \.offset) { _, count in
                Rectangle()
                    .fill(PanelTheme.headerColor.opacity(0.45))
                    .frame(width: max(barWidth - 0.5, 0.5),
                           height: max(height * CGFloat(count) / CGFloat(peak), count > 0 ? 1 : 0))
                    .frame(width: barWidth, alignment: .center)
            }
        }
        .frame(width: width, height: height, alignment: .bottom)
    }

    /// Where the current brush sits, in points. The live drag wins over the committed
    /// brush so the highlight tracks the pointer rather than the last preview to land.
    private func selectionRegion(width: CGFloat) -> CGRect? {
        if let from = dragFrom, let to = dragTo {
            return CGRect(x: min(from, to), y: 0, width: abs(to - from), height: 1)
        }
        guard let brush, let domain, domain.upperBound > domain.lowerBound else { return nil }
        let span = domain.upperBound - domain.lowerBound
        let x0 = CGFloat((brush.lo - domain.lowerBound) / span) * width
        let x1 = CGFloat((brush.hi - domain.lowerBound) / span) * width
        return CGRect(x: max(min(x0, x1), 0), y: 0,
                      width: min(abs(x1 - x0), width), height: 1)
    }

    private func brush(from: CGFloat, to: CGFloat, width: CGFloat) -> SetBrush? {
        guard let name = column?.column, let domain,
              domain.upperBound > domain.lowerBound else { return nil }
        let lo = SetPlotModel.value(at: min(from, to), in: domain, length: width, flipped: false)
        let hi = SetPlotModel.value(at: max(from, to), in: domain, length: width, flipped: false)
        return SetBrush(column: name, lo: lo, hi: hi)
    }

    private var helpText: String {
        guard let column else { return "" }
        // A column whose values are all the same has a zero-width domain, so a drag
        // has no range to mean and does nothing. Saying that is better than a strip
        // that looks draggable and is not.
        guard let domain, domain.upperBound > domain.lowerBound else {
            return "\(column.title) has one value across this set, so there is no range"
                + " to brush"
        }
        var text = "Drag to filter \(column.title) to a range; click to clear it"
        if let brush, let clause = brush.clause { text += " — now: \(clause)" }
        return text
    }
}

// MARK: - Send to ▾ (#418)

/// The footer menu that hands the selection (or the filter, or a view) to the next
/// tool. Every item builds a CONSOLE COMMAND and runs it through the ordinary command
/// path, so an agent over MCP can do exactly what the menu does and the session log
/// records what happened.
///
/// A tool that cannot yet take a set is DISABLED and says why, rather than hidden: the
/// user's question is "can I send this to MPNN", and an absent menu item answers it
/// with silence. #416 built the `predict` side; design and binder design still read a
/// target object, not a set.
struct SetSendMenu: View {
    let set: SetEntry
    let target: SetSendTarget
    let exportCSV: () -> Void
    let exportFASTA: () -> Void
    let exportFolder: () -> Void
    @EnvironmentObject var engine: PyMOLEngine

    private var predictors: [PredictorInfo] { engine.predictController.availablePredictors }

    var body: some View {
        Menu {
            Section("Acting on \(target.label)") {
                if predictors.isEmpty {
                    Button("Predict…") {}
                        .disabled(true)
                        .help("No predictor is registered in this build yet; open the "
                              + "Predict bar once so the list loads.")
                } else {
                    Menu("Predict") {
                        ForEach(predictors) { predictor in
                            Button(predictor.id) {
                                engine.sendSetToPredict(set, selector: target.selector,
                                                        predictor: predictor.id)
                            }
                        }
                    }
                }
                Button("Design / MPNN…") {}
                    .disabled(true)
                    .help("MPNN does not take a set as its input yet — it designs on an "
                          + "object. Stage the candidates, or Export a folder, and run "
                          + "design on those. Tracked on #421.")
                Button("Binder Design…") {}
                    .disabled(true)
                    .help("binder_design starts from a TARGET object and hotspots, not "
                          + "from a set of candidates. Tracked on #421.")
            }
            Divider()
            Menu("Export") {
                Button("CSV…", action: exportCSV)
                Button("FASTA…", action: exportFASTA)
                Button("Folder of CIFs…", action: exportFolder)
            }
            if !set.views.isEmpty {
                Divider()
                Menu("Apply a view") {
                    ForEach(set.views) { view in
                        Button(view.name) { engine.applySetView(set, view) }
                    }
                }
            }
        } label: {
            Text("Send to").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Hand \(target.label) to the next tool as the selector "
              + "set:\(set.name)@\(target.selector)")
    }
}

/// One row: star, stage-state, name, then a cell per metric column tinted by the
/// spec's ramp. Stateless — the List recycles these — so nothing here is @State.
private struct SetTableRowView: View {
    let row: SetRow
    let columns: [MetricColumn]
    let metricWidth: CGFloat
    let isPeeked: Bool
    let onStar: () -> Void
    let onToggleStage: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onStar) {
                Text(row.starred ? "★" : "☆")
                    .foregroundColor(row.starred ? PanelTheme.atomTranspColor : PanelTheme.disabledColor)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(row.starred ? "Unstar (s)" : "Star (s)")

            Button(action: onToggleStage) {
                Text(SetTableModel.stageGlyph(row, peekedID: isPeeked ? row.id : nil))
                    .foregroundColor(row.isStaged ? PanelTheme.accentColor
                                     : (isPeeked ? PanelTheme.textColor : PanelTheme.disabledColor))
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(row.isStaged ? "Staged as \(row.stagedObject ?? row.name) — click to unstage (space)"
                               : "Click to stage (space)")

            HStack(spacing: 3) {
                Text(row.name)
                    .fontWeight(isPeeked ? .semibold : .regular)
                    .strikethrough(row.rejected)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundColor(PanelTheme.accentColor)
                        .help("Pinned")
                }
            }
            .frame(width: 150, alignment: .leading)
            .foregroundColor(row.rejected ? PanelTheme.disabledColor : PanelTheme.textColor)

            ForEach(columns) { column in
                let value = row.value(column)
                Text(SetTableModel.format(value, column))
                    .lineLimit(1)
                    .frame(width: metricWidth, alignment: .trailing)
                    .padding(.vertical, 2)
                    .background(rampTint(value, column))
                    .foregroundColor(value.isNull ? PanelTheme.disabledColor : PanelTheme.textColor)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11).monospacedDigit())
        .frame(height: 22)
        .contentShape(Rectangle())
        .help(tooltip)
    }

    /// A faint tint from "bad" (warm) to "good" (cool green) at 22% opacity: enough
    /// to read the column's shape at a glance, not enough to fight the text.
    private func rampTint(_ value: MetricValue, _ column: MetricColumn) -> Color {
        guard let g = SetTableModel.goodness(value, column) else { return .clear }
        let bad = (r: 0.85, g: 0.35, b: 0.30)
        let good = (r: 0.20, g: 0.65, b: 0.40)
        return Color(.sRGB,
                     red: bad.r + (good.r - bad.r) * g,
                     green: bad.g + (good.g - bad.g) * g,
                     blue: bad.b + (good.b - bad.b) * g,
                     opacity: 0.22)
    }

    private var tooltip: String {
        var parts = ["\(row.name) — \(row.nChains) chain\(row.nChains == 1 ? "" : "s"), \(row.nResidues) residues"]
        if let obj = row.stagedObject { parts.append("staged as \(obj)") }
        if row.pinned { parts.append("pinned") }
        if row.rejected { parts.append("rejected") }
        if !row.tags.isEmpty { parts.append("tags: \(row.tags)") }
        return parts.joined(separator: " · ")
    }
}

#endif
