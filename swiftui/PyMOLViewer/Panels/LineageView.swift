// LineageView.swift — the Data drawer's Lineage tab (#419, spec §4.5, wireframe
// frame 4).
//
// "A left-to-right DAG: target → backbones → sequences → folds. Node size or color
// from a chosen metric. Clicking a node filters the table to its descendants. This is
// the view that answers 'which backbones produced foldable sequences' without a
// spreadsheet."
//
// Where the graph comes from. Two edges, not one, because the store has two:
//
//   * `entries.parents` — a JSON list of entry ids, which may point into ANOTHER set.
//     This is the real edge: one fold's parent is one MPNN sequence, whose parent is
//     one RFD3 backbone. Already loaded with every row (`SetRow.parents`), and read
//     across the whole file by `SetsStore.lineageEntries`.
//   * `runs.parent_set_id` — the SET-level edge. A tool that delivers a set without
//     writing per-entry parents still records which set it consumed, and that is what
//     keeps "sequences" to the right of "backbones" when the per-entry links are
//     missing (store spec §1: lineage is the parent link; §2.2 for both columns).
//
// A node's column is the LONGER of the two answers, so an entry can never draw to the
// left of something it descends from by either route.
//
// **Clicking a node drives the Table's SELECTION, not a filter — and that is a CHOICE,
// not an impossibility.** Being precise about which, because the first draft of this
// comment overclaimed. What the grammar genuinely refuses (store spec §5, pinned by
// `TestLineageCannotBeAFilter` in `testing/tests/test_appkit_sets.py`) is naming entry
// IDS: `column` must be a declared column of the set, `id` is not a column at all, and
// `in` is explicitly refused on the two entry columns that do exist
// (`filter._validate_node`: "'in' is not valid on name"). But entry NAMES are unique
// within a set and `name = 'a' or name = 'b' or …` compiles perfectly well — a
// 212-term chain is 212 bound parameters and valid SQL — so "these descendants" IS
// expressible, at length.
//
// We decline to synthesise it. A filter is a thing the user reads, edits and saves as
// a view; a 212-term disjunction the UI wrote is none of those, it would be
// regenerated on every click, and it would put a second producer of filter text beside
// the one place (`SetFilterComposer`) that builds it today. The Table already has a
// linked selection that the plot, the viewport and the keyboard all write into, and
// "these specific rows" is exactly what a selection is for. So a node click writes into
// that, and the Table scrolls to it.
//
// `LineageModel` is pure, like `SetTableModel` and `SetPlotModel`: the graph build,
// the layering and the descendant walk are decisions with tests on them.

import Foundation
import SwiftUI

// MARK: - Model (pure)

/// One node: an entry, placed.
struct LineageNode: Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let setID: String
    /// 0 is the leftmost column. See `LineageModel` for how it is computed.
    let layer: Int
    /// Position within the layer, in delivery order. The view's y.
    let row: Int
    let parents: [String]
    let rejected: Bool
    /// The chosen metric. `.some(nil)` means "this set declares the column and this
    /// entry has no value" — a prediction that failed, which the spec draws hollow.
    /// `.none` means "not loaded", which is most of the file: only the ACTIVE set's
    /// scalars are read (#417), and a node whose metric was never asked for must not
    /// be drawn as one that failed.
    let metric: Double??

    /// Spec §4.5: "hollow for rejected or failed".
    var isHollow: Bool {
        if rejected { return true }
        if case .some(.none) = metric { return true }
        return false
    }
    /// True when nothing is known about this node's metric, which draws neither hollow
    /// nor sized — a plain filled dot.
    var metricUnknown: Bool {
        if case .none = metric { return true }
        return false
    }
    var metricValue: Double? {
        if case .some(.some(let v)) = metric { return v }
        return nil
    }
}

/// One drawn edge, parent → child. A named struct rather than a tuple so the model
/// can store it and stay `Equatable` — which is what keeps the graph off the main
/// thread's critical path (see `LineageModel`).
struct LineageEdge: Equatable, Hashable {
    let from: String
    let to: String
}

/// The DAG, laid out.
///
/// Everything derived is computed ONCE, in `init`, and stored. It used to be computed
/// properties, and on a 9000-entry campaign `edges` + `layers` + `nodesByID` were ~7 ms
/// EACH TIME they were touched — which a `Canvas` touches per frame and an `==` touches
/// per version bump.
struct LineageModel: Equatable {
    /// Every node, in layer then row order.
    let nodes: [LineageNode]
    /// Parent id → child ids. The direction a descendant walk goes.
    let children: [String: [String]]
    /// The metric column the nodes are sized by, when one was chosen.
    let metricColumn: MetricColumn?
    /// Every node by id — the lookup `draw` needs per edge.
    let nodesByID: [String: LineageNode]
    /// Edges, parents restricted to nodes that exist: an entry may name a parent in a
    /// set that was deleted, and an edge to nothing is a line to nowhere.
    let edges: [LineageEdge]
    /// How many nodes are in each column, left to right. The canvas's height comes
    /// from this without materialising the columns themselves.
    let layerSizes: [Int]

    /// Nodes grouped by column, left to right.
    var layers: [[LineageNode]] {
        guard !layerSizes.isEmpty else { return [] }
        var out = [[LineageNode]](repeating: [], count: layerSizes.count)
        for node in nodes { out[node.layer].append(node) }
        return out
    }

    init(entries: [LineageEntryRecord],
         runs: [LineageRunRecord] = [],
         metric: [String: Double?] = [:],
         metricColumn: MetricColumn? = nil) {
        self.metricColumn = metricColumn

        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // -- the set-level layer, from runs.parent_set_id ------------------------
        var parentSetOfSet: [String: Set<String>] = [:]
        for run in runs {
            if let parent = run.parentSetID, !parent.isEmpty, parent != run.setID {
                parentSetOfSet[run.setID, default: []].insert(parent)
            }
        }
        var setLayer: [String: Int] = [:]
        func layerOfSet(_ setID: String, _ seen: inout Set<String>) -> Int {
            if let known = setLayer[setID] { return known }
            // A cycle cannot happen in a file this build wrote, but a hand-edited or
            // half-migrated one must terminate rather than spin the poll.
            guard !seen.contains(setID) else { return 0 }
            seen.insert(setID)
            var best = 0
            for parent in parentSetOfSet[setID] ?? [] {
                best = max(best, layerOfSet(parent, &seen) + 1)
            }
            seen.remove(setID)
            setLayer[setID] = best
            return best
        }
        for entry in entries {
            var seen = Set<String>()
            _ = layerOfSet(entry.setID, &seen)
        }

        // -- the entry-level layer, from entries.parents --------------------------
        var entryLayer: [String: Int] = [:]
        func layerOfEntry(_ id: String, _ seen: inout Set<String>) -> Int {
            if let known = entryLayer[id] { return known }
            guard let record = byID[id], !seen.contains(id) else { return 0 }
            seen.insert(id)
            var best = 0
            // `parent != id`: a self-parent is not a generation. Without this an entry
            // that names itself was placed one column right of itself and drew a
            // degenerate self-loop — a curve from a dot back to the same dot.
            for parent in record.parents where parent != id && byID[parent] != nil {
                best = max(best, layerOfEntry(parent, &seen) + 1)
            }
            seen.remove(id)
            // The LONGER of the two answers: a fold whose own parents are missing still
            // sits to the right of the sequences its run consumed, and a fold whose
            // parents ARE recorded can never be drawn left of them.
            let layer = max(best, setLayer[record.setID] ?? 0)
            entryLayer[id] = layer
            return layer
        }
        for entry in entries {
            var seen = Set<String>()
            _ = layerOfEntry(entry.id, &seen)
        }

        var kids: [String: [String]] = [:]
        var wires: [LineageEdge] = []
        for entry in entries {
            for parent in entry.parents where parent != entry.id && byID[parent] != nil {
                kids[parent, default: []].append(entry.id)
                wires.append(LineageEdge(from: parent, to: entry.id))
            }
        }
        self.children = kids
        self.edges = wires

        // -- place ---------------------------------------------------------------
        var rowInLayer: [Int: Int] = [:]
        var placed: [LineageNode] = []
        // Delivery order within a set, sets in the order the entries arrived: the
        // same order the Table's default sort uses, so the two views agree.
        for entry in entries.sorted(by: {
            ($0.setID, $0.ord, $0.id) < ($1.setID, $1.ord, $1.id)
        }) {
            let layer = entryLayer[entry.id] ?? 0
            let row = rowInLayer[layer] ?? 0
            rowInLayer[layer] = row + 1
            placed.append(LineageNode(
                id: entry.id, name: entry.name, setID: entry.setID,
                layer: layer, row: row, parents: entry.parents,
                rejected: entry.rejected,
                metric: metric.index(forKey: entry.id).map { metric[$0].value }))
        }
        let ordered = placed.sorted { ($0.layer, $0.row) < ($1.layer, $1.row) }
        self.nodes = ordered
        self.nodesByID = Dictionary(ordered.map { ($0.id, $0) },
                                    uniquingKeysWith: { a, _ in a })
        var sizes = [Int](repeating: 0, count: (ordered.map(\.layer).max() ?? -1) + 1)
        for node in ordered { sizes[node.layer] += 1 }
        self.layerSizes = sizes
    }

    // MARK: descendants

    /// Every entry reachable downward from `id`, NOT including `id` itself.
    ///
    /// Breadth-first with a visited set, so a diamond — two MPNN sequences off one
    /// backbone, both folded, both folds compared against the same target — is walked
    /// once per node rather than once per path.
    func descendants(of id: String) -> Set<String> {
        var out: Set<String> = []
        var queue = children[id] ?? []
        while let next = queue.popLast() {
            guard out.insert(next).inserted else { continue }
            queue.append(contentsOf: children[next] ?? [])
        }
        return out
    }

    /// The node and everything under it — what a click selects, because a user who
    /// clicks a backbone wants the backbone AND what came of it.
    func subtree(of id: String) -> Set<String> {
        var out = descendants(of: id)
        if nodes.contains(where: { $0.id == id }) { out.insert(id) }
        return out
    }

    /// 0…1 with 1 = good, for the node's size. nil when the metric is unknown or has
    /// no domain, which draws the default dot — `SetTableModel.goodness`'s rule, so a
    /// node and its table row read the same way.
    func goodness(_ node: LineageNode) -> Double? {
        guard let column = metricColumn, let value = node.metricValue else { return nil }
        return SetTableModel.goodness(.number(value), column)
    }
}

#if os(macOS)

// MARK: - View

/// The DAG, drawn. Columns left to right, one dot per entry, lines to each parent.
///
/// A `Canvas`, not a stack of shapes: a campaign is 1000 backbones and 8000 sequences,
/// and 9000 SwiftUI views is a hang. Hit-testing is the model's arithmetic run
/// backwards — the same shape `SetPlotView` uses, and for the same reason.
struct LineageView: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    /// Column pitch and row pitch. Small enough that a few hundred entries fit a
    /// drawer, large enough that a dot is clickable.
    private static let columnWidth: CGFloat = 130
    private static let rowHeight: CGFloat = 16
    private static let margin: CGFloat = 18
    private static let maxRadius: CGFloat = 5

    private var model: LineageModel { engine.lineageModel }
    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }
    /// What a click said, when it had something to say. Cleared by the next click.
    @State private var clickNote = ""

    /// Entry ids the Table is actually showing — the only ids a click can select.
    /// Nodes outside it are drawn faint, so "this one is in another set" is visible
    /// BEFORE the click rather than as a click that appears to do nothing.
    private var reachable: Set<String> { Set(engine.setRows.map(\.id)) }

    var body: some View {
        let model = self.model
        VStack(spacing: 0) {
            header(model: model)
            Rectangle().fill(hairline).frame(height: 1)
            if model.nodes.isEmpty {
                emptyState
            } else {
                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    let size = canvasSize(model: model)
                    let reachable = self.reachable
                    Canvas { context, _ in
                        draw(model: model, reachable: reachable, in: &context)
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { point in click(model: model, at: point) }
                }
                .background(PanelTheme.background)
            }
        }
        // The rebuild happens HERE and only here. `applySetsMarker` used to do it too,
        // which meant ~45 ms of main thread twice per delivery on a 9000-entry
        // campaign; it now only bumps the counter this watches.
        .onAppear { engine.refreshLineage() }
        .onChange(of: engine.setsVersionTick) { _ in engine.refreshLineage() }
    }

    private func header(model: LineageModel) -> some View {
        HStack(spacing: 8) {
            Text("\(model.nodes.count) entries · \(model.layerSizes.count) generations")
                .font(.system(size: 10))
                .foregroundColor(PanelTheme.disabledColor)
            if let column = model.metricColumn {
                Text("sized by \(SetTableModel.header(column))")
                    .font(.system(size: 10))
                    .foregroundColor(PanelTheme.headerColor)
                    .help("The active set's ranking column. Hollow = rejected, or no"
                          + " value at all — a run that failed.")
            }
            Spacer(minLength: 0)
            Text(clickNote.isEmpty
                 ? "click a node to select it and its descendants in the Table"
                 : clickNote)
                .font(.system(size: 9))
                .foregroundColor(clickNote.isEmpty ? PanelTheme.disabledColor
                                 : PanelTheme.atomTranspColor)
                .help("Entry names could be or-chained into a filter, but a 212-term"
                      + " expression the UI wrote is not something you could read or"
                      + " save as a view — so a node click drives the Table's linked"
                      + " selection, which is what \"these specific rows\" is for."
                      + " Faint nodes are in another set and cannot be selected here.")
        }
        .padding(.horizontal, 10)
        .frame(height: 20)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No lineage yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(PanelTheme.textColor)
            Text("Lineage is drawn from entry parents and from a run's parent set."
                 + " Send a set to MPNN or Predict and the child set's entries arrive"
                 + " with the links already on them.")
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.disabledColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: geometry

    private func canvasSize(model: LineageModel) -> CGSize {
        let columns = max(model.layerSizes.count, 1)
        let tallest = model.layerSizes.max() ?? 1
        return CGSize(width: CGFloat(columns) * Self.columnWidth + 2 * Self.margin,
                      height: CGFloat(max(tallest, 1)) * Self.rowHeight + 2 * Self.margin)
    }

    private func position(_ node: LineageNode) -> CGPoint {
        CGPoint(x: Self.margin + CGFloat(node.layer) * Self.columnWidth,
                y: Self.margin + CGFloat(node.row) * Self.rowHeight)
    }

    private func radius(_ model: LineageModel, _ node: LineageNode) -> CGFloat {
        guard let g = model.goodness(node) else { return 3 }
        return 2 + (Self.maxRadius - 2) * CGFloat(g)
    }

    /// The rect a draw pass has to cover, padded by one column and a few rows so a
    /// curve whose endpoints are both off-screen but whose belly is not still draws.
    static func cullRect(_ visible: CGRect) -> CGRect {
        visible.insetBy(dx: -columnWidth, dy: -4 * rowHeight)
    }

    private func draw(model: LineageModel, reachable: Set<String>,
                      in context: inout GraphicsContext) {
        // A 9000-entry campaign is a 128 000pt canvas; without this every frame
        // strokes an 8000-curve path and fills 9000 ellipses to show about forty of
        // them. `clipBoundingRect` is the slice actually being asked for.
        let cull = Self.cullRect(context.clipBoundingRect)
        var wires = Path()
        for edge in model.edges {
            guard let parent = model.nodesByID[edge.from],
                  let child = model.nodesByID[edge.to] else { continue }
            let from = position(parent), to = position(child)
            let span = CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                              width: abs(to.x - from.x), height: abs(to.y - from.y))
            guard cull.intersects(span.insetBy(dx: -1, dy: -1)) else { continue }
            wires.move(to: from)
            // A shallow S, so a fan of eight children off one backbone reads as a fan
            // rather than as eight lines crossing the same pixels.
            wires.addCurve(to: to,
                           control1: CGPoint(x: from.x + Self.columnWidth * 0.5, y: from.y),
                           control2: CGPoint(x: to.x - Self.columnWidth * 0.5, y: to.y))
        }
        context.stroke(wires, with: .color(PanelTheme.disabledColor.opacity(0.35)),
                       lineWidth: 1)
        let selected = engine.setSelection
        for node in model.nodes {
            let p = position(node)
            guard cull.contains(p) else { continue }
            let r = radius(model, node)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            // Faint for a node the Table cannot select — it belongs to another set.
            let colour = tint(model, node)
                .opacity(reachable.contains(node.id) ? 1 : 0.4)
            if node.isHollow {
                context.stroke(Path(ellipseIn: rect), with: .color(colour), lineWidth: 1.2)
            } else {
                context.fill(Path(ellipseIn: rect), with: .color(colour))
            }
            if selected.contains(node.id) {
                let ring = rect.insetBy(dx: -3, dy: -3)
                context.stroke(Path(ellipseIn: ring),
                               with: .color(PanelTheme.accentColor), lineWidth: 1.5)
            }
        }
    }

    private func tint(_ model: LineageModel, _ node: LineageNode) -> Color {
        guard let g = model.goodness(node) else { return PanelTheme.headerColor }
        return SequenceEntryRowsView.tint(g)
    }

    // MARK: click

    /// Nearest node within a generous radius. Nearest rather than "inside the dot":
    /// the dots are 4–10pt and a metric-sized one can be small, and a click that
    /// silently does nothing is the worst of the three outcomes.
    ///
    /// Which is also why a click that selects NOTHING says so. The subtree of a
    /// backbone is entirely inside the child set when the child set is the one open —
    /// the commonest thing to click, and it used to be a no-op with no account of why.
    private func click(model: LineageModel, at point: CGPoint) {
        var best: (node: LineageNode, distance: CGFloat)? = nil
        for node in model.nodes {
            let p = position(node)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= Self.rowHeight, best == nil || d < best!.distance {
                best = (node, d)
            }
        }
        guard let hit = best?.node else { return }
        let subtree = model.subtree(of: hit.id)
        let selected = engine.selectLineageSubtree(subtree)
        clickNote = Self.clickNote(node: hit, subtree: subtree, selected: selected)
    }

    /// What the header says after a click. Pure, so the wording is testable.
    static func clickNote(node: LineageNode, subtree: Set<String>, selected: Int)
        -> String {
        if selected > 0 { return "" }
        if subtree.count > 1 {
            return "\(node.name) and its \(subtree.count - 1) descendants are in"
                + " another set — open that set to select them"
        }
        return "\(node.name) is in another set — open that set to select it"
    }
}

#endif
