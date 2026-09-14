// DataDrawer.swift — the Data drawer and its Table tab (#417, spec §4.2, wireframe
// frame 1).
//
// The inspector is the SCENE column; tables want width, so the set browser is a
// drawer across the bottom of the viewport. This step ships the Table tab and the
// three verbs — peek, stage, pin — that make the triage loop work end to end for a
// design batch: sort, arrow through the top twenty, star, stage, save. Filters, the
// Plot tab and linked selection are #418; the Sequences and Lineage tabs are #419;
// iPad and iPhone layouts are #420, so the views here are macOS-only and the drawer
// is simply absent on iOS.
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

    /// Bin `values` over `[lo, hi]` when the spec has a domain (so two runs of one
    /// tool draw on the same axis) and over the observed range otherwise. Values
    /// outside the domain land in the edge bins. Empty input → empty output.
    static func histogram(values: [Double], bins: Int, lo: Double?, hi: Double?) -> [Int] {
        guard bins > 0, !values.isEmpty else { return [] }
        let finite = values.filter { $0.isFinite }
        guard !finite.isEmpty else { return [] }
        var low = lo ?? finite.min()!
        var high = hi ?? finite.max()!
        if !(high > low) {
            low = finite.min()!
            high = finite.max()!
        }
        var counts = [Int](repeating: 0, count: bins)
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
                SetTableView(set: set, rows: engine.setRows)
                    .id(set.id)      // a new set starts with a fresh selection
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

    /// Table is the one tab this step ships. The other three are drawn disabled,
    /// not hidden: the drawer's shape is decided (spec §4), and a user who sees
    /// where Plot and Sequences will go learns the layout once.
    private var tabStrip: some View {
        HStack(spacing: 2) {
            tab("Table", active: true, help: "Entries as rows; columns come from the set's metrics")
            tab("Plot", active: false, help: "Coming with filters and linked selection (#418)")
            tab("Sequences", active: false, help: "Coming when the sequence strip moves here (#419)")
            tab("Lineage", active: false, help: "Coming with the Sequences tab (#419)")
        }
    }

    private func tab(_ title: String, active: Bool, help: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: active ? .semibold : .regular))
            .foregroundColor(active ? PanelTheme.textColor : PanelTheme.disabledColor)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4)
                            .fill(active ? PanelTheme.buttonBackground : Color.clear))
            .help(help)
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

    var body: some View {
        HStack(spacing: 4) {
            ProgressView().progressViewStyle(.circular).controlSize(.mini)
                .frame(width: 10, height: 10)
            Text(progress.total > 0 ? "\(progress.done) / \(progress.total)" : "\(progress.done)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
            if !progress.tool.isEmpty {
                Text(progress.tool)
                    .font(.system(size: 9))
                    .foregroundColor(PanelTheme.disabledColor)
            }
        }
        .help("A batch is still delivering into this set")
    }
}

// MARK: - Table tab

/// The virtualized table. A `List` (NSTableView underneath, so only visible rows
/// exist) rather than SwiftUI `Table`: the columns are DATA — a fifth predictor adds
/// one with no UI edit — and `Table` cannot take a dynamic column list on the
/// macOS 14.0 floor. Sorting, formatting and the ramp are `SetTableModel`.
///
/// Keys, while the list has focus: ↑↓ move the peek, space stages/unstages, `s`
/// stars, `x` rejects. Hover peeks after a short debounce, so a sweep down the
/// table costs one load at the row the pointer settles on, not one per row.
struct SetTableView: View {
    let set: SetEntry
    let rows: [SetRow]
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var selection = Set<String>()
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
        SetTableModel(set: set, rows: rows, sortKey: sortKey, sortDescending: sortDescending)
    }

    /// What the footer's verbs act on: the selection, else the peeked row.
    private var actionRows: [SetRow] {
        if !selection.isEmpty { return rows.filter { selection.contains($0.id) } }
        if let peeked = engine.peekedEntryID, let row = rows.first(where: { $0.id == peeked }) {
            return [row]
        }
        return []
    }

    var body: some View {
        let model = self.model
        GeometryReader { geo in
            let metricWidth = Self.metricWidth(total: geo.size.width, columns: model.columns.count)
            VStack(spacing: 0) {
                headerRow(model: model, metricWidth: metricWidth)
                Rectangle().fill(hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    List(model.sorted, id: \.id, selection: $selection) { row in
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
                    .onKeyPress(.space) { stageAction(toggle: true); return .handled }
                    .onKeyPress(KeyEquivalent("s")) { starAction(); return .handled }
                    .onKeyPress(KeyEquivalent("x")) { rejectAction(); return .handled }
                    .onKeyPress(.escape) {
                        if engine.peekedEntryID != nil { engine.clearPeek(); return .handled }
                        return .ignored
                    }
                }
                Rectangle().fill(hairline).frame(height: 1)
                footer(model: model)
            }
        }
        .onDisappear { hoverWork?.cancel() }
        .alert("Save view", isPresented: $showSaveView) {
            TextField("View name", text: $viewName)
            Button("Save") { engine.saveSetView(set, named: viewName); viewName = "" }
            Button("Cancel", role: .cancel) { viewName = "" }
        } message: {
            Text("Saves the set's active filter and sort as a named view "
                 + "(set_view_save), usable as view:NAME in every set_* command.")
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
            Text(selection.isEmpty
                 ? "\(rows.count) entries"
                 : "\(selection.count) of \(rows.count) selected")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
            if model.isOverBudget {
                Text("over budget")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(PanelTheme.atomTranspColor)
                    .help("More objects are staged than the budget allows; unstage "
                          + "some or raise it with set_budget.")
            }
            Spacer()
            footerButton("Stage", help: unstaged.isEmpty
                         ? "Select rows (or peek one) to stage"
                         : (model.canStage(unstaged.count)
                            ? "Load \(unstaged.count) as objects in the set's group (set_stage)"
                            : "Staging \(unstaged.count) would exceed the budget of \(model.budget)")) {
                engine.stage(set, unstaged)
            }
            .disabled(unstaged.isEmpty)
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
            Menu {
                Button("CSV…") { exportPanel(ext: "csv") }
                Button("FASTA…") { exportPanel(ext: "fasta") }
                Button("Folder of CIFs…") { exportFolder() }
            } label: {
                Text("Export").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Write the selection (or every entry) out with set_export")
            footerButton("Save view…", help: "Save the active filter and sort as a view (set_view_save)") {
                showSaveView = true
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
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
        let anchor = engine.peekedEntryID ?? selection.first
        guard let next = model.neighbor(of: anchor, step: step) else { return }
        engine.peekEntry(set, next)
        selection = [next.id]
        withAnimation(nil) { proxy.scrollTo(next.id) }
    }

    private func stageAction(toggle: Bool) {
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
