// SetPlot.swift — the Data drawer's Plot tab (#418, spec §4.3, wireframe frame 2).
//
// One scatter over the SAME filtered rows the Table tab shows. Not "a plot of the set":
// the plot and the table read `engine.filteredSetRows`, so brushing a column in the
// header and looking at the plot cannot show you two different populations. Spec §4.3
// says it in one line — "the plot reads the same filtered rows as the table; no separate
// state" — and that is the only reason this file can be as small as it is.
//
// `SetPlotModel` is the whole of the geometry and none of the drawing: domains, the
// value → point mapping and its inverse, hit-testing, a rubber band to a set of row ids,
// and a rubber band to a pair of `SetBrush` ranges. It is a value type with no SwiftUI
// in it, for the reason `SetTableModel` is: SetPlotModelTests can pin every one of those
// decisions without a window, and a scale that is off by a pixel is a failing test rather
// than a squint.
//
// The filter language is not here. A brush produces a `SetBrush`, which prints itself as
// `plddt >= 80 and plddt <= 92` and goes to Python like anything typed; this file never
// decides what an expression means (#418: there is exactly one grammar, filter.py).

import Foundation
import SwiftUI

// MARK: - Plot model (pure)

/// What the plot colours points by: nothing, a metric column's ramp, or a category.
enum SetPlotColor: Equatable, Hashable {
    case none
    /// A wide-table column name; the ramp is `SetTableModel.goodness`, so a point is
    /// tinted the way its table cell is.
    case metric(String)
    case category(SetPlotCategory)
}

/// The non-numeric things a set can be split by. All four come from a `SetRow` field
/// that is already loaded, so colouring by one costs no read (spec §4.3: "color by a
/// third or by set/tag").
enum SetPlotCategory: String, CaseIterable, Identifiable, Hashable {
    case tag, parent, run, staged

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tag: return "Tag"
        case .parent: return "Parent"
        case .run: return "Run"
        case .staged: return "Staged"
        }
    }

    /// The bucket a row falls in. "" means "no value", which is drawn grey and sorted
    /// last rather than made into a category of its own.
    func value(of row: SetRow) -> String {
        switch self {
        case .tag: return row.firstTag
        case .parent: return row.parents.first ?? ""
        case .run: return row.runID ?? ""
        case .staged: return row.isStaged ? "staged" : ""
        }
    }
}

/// One placed point.
struct SetPlotPoint: Equatable, Identifiable {
    let id: String
    let name: String
    /// In the plot rect's coordinates: x rightwards, y DOWNWARDS (the value axis is
    /// already flipped), so a view can draw at it without thinking about it again.
    let position: CGPoint
    let x: Double
    let y: Double
    let isStaged: Bool
    let isStarred: Bool
    let isRejected: Bool
    /// 0…1 with 1 = good, for `.metric` colouring; nil when the column has no domain
    /// or the value is absent, which draws the neutral dot.
    let goodness: Double?
    /// The category bucket for `.category` colouring; "" when there is none.
    let category: String
}

/// Everything the Plot tab computes from rows, two columns and a rect.
///
/// Rebuilt per render like `SetTableModel`, and cheap for the reason that one is: a
/// thousand points is a thousand multiplications. Above that the drawing, not the
/// arithmetic, is the cost, which is why the view draws with `Canvas`.
struct SetPlotModel: Equatable {
    let rows: [SetRow]
    let xColumn: MetricColumn?
    let yColumn: MetricColumn?
    let color: SetPlotColor
    let size: CGSize
    /// Entry ids currently selected in the table; the plot rings them.
    let selection: Set<String>
    /// The entry in the peek object, drawn large (spec §4.3).
    let peekedID: String?

    init(rows: [SetRow], xColumn: MetricColumn?, yColumn: MetricColumn?,
         color: SetPlotColor = .none, size: CGSize = CGSize(width: 100, height: 100),
         selection: Set<String> = [], peekedID: String? = nil) {
        self.rows = rows
        self.xColumn = xColumn
        self.yColumn = yColumn
        self.color = color
        self.size = size
        self.selection = selection
        self.peekedID = peekedID
    }

    // MARK: domains

    /// The axis range for a column.
    ///
    /// The spec's `lo`/`hi` win when it has them, exactly as the histogram's do, so two
    /// runs of one tool plot on the same axes and a point does not move because the
    /// filter changed. With no domain the observed range is used and padded by 5%, so
    /// the extreme candidates — the ones the user is looking for — are not drawn on the
    /// frame. A degenerate range (one value, or none) opens to ±0.5 so the point lands
    /// in the middle instead of dividing by zero.
    static func domain(values: [Double], lo: Double?, hi: Double?) -> ClosedRange<Double> {
        let finite = values.filter { $0.isFinite }
        guard let observedLow = finite.min(), let observedHigh = finite.max() else {
            if let lo, let hi, hi > lo { return lo...hi }
            return -0.5...0.5
        }
        // Padding goes on the OPEN ends only. A metric that declares `lo=0` and no
        // ceiling means the axis starts at zero; padding that end would say the
        // opposite, and a plot whose origin drifts with the data is the thing the
        // declared domain exists to prevent.
        let pad = observedHigh > observedLow ? (observedHigh - observedLow) * 0.05 : 0.5
        var low = lo ?? (observedLow - pad)
        var high = hi ?? (observedHigh + pad)
        if !(high > low) {
            low = observedLow - pad
            high = observedHigh + pad
        }
        return high > low ? low...high : (observedLow - 0.5)...(observedLow + 0.5)
    }

    var xDomain: ClosedRange<Double> {
        Self.domain(values: values(of: xColumn), lo: xColumn?.lo, hi: xColumn?.hi)
    }

    var yDomain: ClosedRange<Double> {
        Self.domain(values: values(of: yColumn), lo: yColumn?.lo, hi: yColumn?.hi)
    }

    private func values(of column: MetricColumn?) -> [Double] {
        guard let name = column?.column else { return [] }
        return rows.compactMap { $0.values[name]?.number }
    }

    // MARK: scales

    /// Where a value sits along an axis of `length` points. `flipped` is the Y axis:
    /// screen y grows downwards and a value axis grows upwards. Clamped, because an
    /// out-of-domain value (a pLDDT of 101 from a tool that rounds) belongs on the
    /// frame, not off-screen.
    static func position(_ value: Double, in domain: ClosedRange<Double>,
                         length: CGFloat, flipped: Bool) -> CGFloat {
        guard length > 0 else { return 0 }
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, value.isFinite else { return flipped ? length : 0 }
        let f = min(max((value - domain.lowerBound) / span, 0), 1)
        return flipped ? length * (1 - f) : length * f
    }

    /// The inverse: what value a point on the axis stands for. Used to turn a rubber
    /// band back into the range a brush would filter on.
    static func value(at position: CGFloat, in domain: ClosedRange<Double>,
                      length: CGFloat, flipped: Bool) -> Double {
        guard length > 0 else { return domain.lowerBound }
        var f = Double(position / length)
        if flipped { f = 1 - f }
        f = min(max(f, 0), 1)
        return domain.lowerBound + f * (domain.upperBound - domain.lowerBound)
    }

    // MARK: points

    /// Rows placed in the rect. A row with no value on either axis is NOT drawn at zero
    /// — an unmeasured entry is not a bad one (the metrics store's rule) — it is left
    /// out, and `unplaced` says how many, so the plot can admit it.
    var points: [SetPlotPoint] {
        guard let xName = xColumn?.column, let yName = yColumn?.column else { return [] }
        let dx = xDomain, dy = yDomain
        return rows.compactMap { row in
            guard let x = row.values[xName]?.number, let y = row.values[yName]?.number,
                  x.isFinite, y.isFinite else { return nil }
            return SetPlotPoint(
                id: row.id,
                name: row.name,
                position: CGPoint(x: Self.position(x, in: dx, length: size.width, flipped: false),
                                  y: Self.position(y, in: dy, length: size.height, flipped: true)),
                x: x, y: y,
                isStaged: row.isStaged,
                isStarred: row.starred,
                isRejected: row.rejected,
                goodness: goodness(of: row),
                category: categoryValue(of: row))
        }
    }

    /// How many rows could not be placed because a coordinate is missing.
    var unplaced: Int {
        guard let xName = xColumn?.column, let yName = yColumn?.column else { return rows.count }
        return rows.filter { $0.values[xName]?.number == nil || $0.values[yName]?.number == nil }
            .count
    }

    private func goodness(of row: SetRow) -> Double? {
        guard case .metric(let name) = color,
              let column = columnsByName[name] else { return nil }
        return SetTableModel.goodness(row.values[name] ?? .null, column)
            ?? SetTableModel.rampFraction(row.values[name] ?? .null, column)
    }

    private func categoryValue(of row: SetRow) -> String {
        guard case .category(let kind) = color else { return "" }
        return kind.value(of: row)
    }

    /// Columns the model was given a domain for, by wide-table name. Built from the
    /// two axes plus the colour column, which is everything it needs.
    private var columnsByName: [String: MetricColumn] {
        var out: [String: MetricColumn] = [:]
        for column in [xColumn, yColumn, resolvedColorColumn] {
            if let column, let name = column.column { out[name] = column }
        }
        return out
    }

    /// The spec of the column `.metric` colours by. Either axis when it is one of
    /// them; otherwise the view hands it over, because the model is given a column
    /// NAME and a ramp needs the `lo`/`hi` that only the spec has.
    private var resolvedColorColumn: MetricColumn? {
        guard case .metric(let name) = color else { return nil }
        if xColumn?.column == name { return xColumn }
        if yColumn?.column == name { return yColumn }
        return colorColumn
    }
    /// Set by the view when the colour column is neither axis. A `var` with a default
    /// so every `init` call keeps working and the type stays Equatable.
    var colorColumn: MetricColumn? = nil

    /// The distinct category buckets, in a stable order: named buckets alphabetically,
    /// then "" (no value) last, because "untagged" is not a finding.
    var categories: [String] {
        guard case .category = color else { return [] }
        let found = Set(rows.map { categoryValue(of: $0) })
        let named = found.filter { !$0.isEmpty }.sorted()
        return found.contains("") ? named + [""] : named
    }

    // MARK: brushing

    /// The rows a rubber band covers — spec §4.3's "brushing selects rows". A band that
    /// is a click rather than a drag (under a point in either direction) selects
    /// nothing, so a stray click does not clear the selection by "brushing" one pixel.
    func rowIDs(in rect: CGRect) -> Set<String> {
        guard rect.width >= 1, rect.height >= 1 else { return [] }
        return Set(points.filter { rect.contains($0.position) }.map(\.id))
    }

    /// The same rubber band as a pair of column ranges, for "filter to the brush": the
    /// two clauses go through `SetFilterComposer` and then through Python's grammar,
    /// which is the same path a header histogram takes.
    func brushes(in rect: CGRect) -> [SetBrush] {
        guard rect.width >= 1, rect.height >= 1,
              let xName = xColumn?.column, let yName = yColumn?.column else { return [] }
        let dx = xDomain, dy = yDomain
        let x0 = Self.value(at: rect.minX, in: dx, length: size.width, flipped: false)
        let x1 = Self.value(at: rect.maxX, in: dx, length: size.width, flipped: false)
        // Flipped, so the TOP of the band is the larger value.
        let y0 = Self.value(at: rect.maxY, in: dy, length: size.height, flipped: true)
        let y1 = Self.value(at: rect.minY, in: dy, length: size.height, flipped: true)
        return [SetBrush(column: xName, lo: x0, hi: x1),
                SetBrush(column: yName, lo: y0, hi: y1)]
    }

    /// The point under the pointer, for hover and for the peek. Nearest within
    /// `radius`; ties go to the later point, which is the one drawn on top.
    func nearest(to location: CGPoint, within radius: CGFloat = 12) -> SetPlotPoint? {
        var best: SetPlotPoint?
        var bestDistance = radius * radius
        for point in points {
            let dx = point.position.x - location.x
            let dy = point.position.y - location.y
            let d = dx * dx + dy * dy
            if d <= bestDistance {
                bestDistance = d
                best = point
            }
        }
        return best
    }

    /// Five ticks across an axis, at round-ish numbers of the domain's own scale.
    static func ticks(_ domain: ClosedRange<Double>, count: Int = 5) -> [Double] {
        guard count > 1, domain.upperBound > domain.lowerBound else { return [] }
        let step = (domain.upperBound - domain.lowerBound) / Double(count - 1)
        return (0..<count).map { domain.lowerBound + Double($0) * step }
    }
}

#if os(macOS)

import AppKit

// MARK: - Plot tab

/// The scatter. One `Canvas` for the whole plot area — grid, points and tick labels —
/// rather than a view per point: a thousand entries is a thousand shapes, and SwiftUI's
/// view identity machinery is the wrong price for a dot. Drawing everything in one
/// canvas also means the drag and the hover arrive in ONE coordinate space, which is the
/// space the model computes in, so no gesture location is ever converted twice.
///
/// Three gestures over that space, all resolved through `SetPlotModel`: drag brushes a
/// rubber band and selects the rows inside it, hover peeks (debounced) and raises the
/// card, and the card's buttons are the same three verbs the table row menu has.
struct SetPlotView: View {
    let set: SetEntry
    let rows: [SetRow]
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var xKey: String = ""
    @State private var yKey: String = ""
    @State private var colorChoice: SetPlotColor = .none
    @State private var band: CGRect? = nil
    @State private var bandOrigin: CGPoint? = nil
    @State private var hovered: SetPlotPoint? = nil
    @State private var hoverWork: DispatchWorkItem? = nil

    /// Room for the y tick labels on the left and the x ones underneath.
    private static let leftGutter: CGFloat = 46
    private static let bottomGutter: CGFloat = 16
    private static let topGutter: CGFloat = 8
    private static let rightGutter: CGFloat = 10
    private static let cardSize = CGSize(width: 150, height: 58)

    private var numericColumns: [MetricColumn] {
        // `self.` because a computed property whose body opens with `set` is parsed
        // as a setter declaration.
        self.set.columns.filter { $0.isScalar && $0.dtype != "str" }
    }

    private func column(_ key: String) -> MetricColumn? {
        numericColumns.first { $0.column == key }
    }

    private func model(size: CGSize) -> SetPlotModel {
        var model = SetPlotModel(rows: rows, xColumn: column(xKey), yColumn: column(yKey),
                                 color: colorChoice, size: size,
                                 selection: engine.setSelection,
                                 peekedID: engine.peekedEntryID)
        if case .metric(let name) = colorChoice { model.colorColumn = column(name) }
        return model
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(hairline).frame(height: 1)
            if numericColumns.count < 2 {
                emptyState
            } else {
                plotArea
                // The distribution along x, which doubles as the range filter
                // (spec §4.3). The SAME component as the table header's histogram, so
                // the two brushes produce the same expression through the same grammar.
                // The WHOLE set's distribution, the same one the table header brushes
                // on — not the filtered rows'. Binning the filtered rows made the
                // strip's domain shrink mid-drag on a column with no declared lo/hi,
                // so the same pointer position meant a different value from one event
                // to the next and the brush could never widen again.
                SetHistogramBrushView(
                    column: column(xKey),
                    bins: engine.setHistograms[xKey]?.bins ?? [],
                    domain: engine.setHistograms[xKey]?.domain,
                    brush: engine.setBrushes.first { $0.column == xKey },
                    onBrush: { brush, commit in
                        engine.updateBrush(set, brush, column: xKey, commit: commit)
                    })
                    .frame(height: 18)
                    .padding(.leading, Self.leftGutter)
                    .padding(.trailing, Self.rightGutter)
                    .padding(.bottom, 2)
            }
            Rectangle().fill(hairline).frame(height: 1)
            footer
        }
        .onAppear(perform: chooseDefaults)
        .onDisappear { hoverWork?.cancel() }
    }

    private var hairline: Color { themeManager.active.panelText.color.opacity(0.18) }

    /// x, y and colour default to the columns the user already cares about: the set's
    /// ranking key on Y — it is the one they sorted by — and the next numeric column on
    /// X. A plot that opens on two arbitrary columns has to be configured before it
    /// says anything, and most of the time nobody bothers.
    private func chooseDefaults() {
        guard xKey.isEmpty, yKey.isEmpty else { return }
        let names = numericColumns.compactMap(\.column)
        // Through `numericColumns`, not `set.rankingColumn`: a set ranked on a STRING
        // column would otherwise name an axis the menu never offers, and the plot
        // would open empty with no way to tell why.
        let ranking = names.first { $0 == self.set.rankingKey }
        yKey = ranking ?? names.first ?? ""
        xKey = names.first { $0 != yKey } ?? yKey
    }

    // MARK: the plot area

    private var plotArea: some View {
        GeometryReader { geo in
            let rect = Self.plotRect(in: geo.size)
            let model = self.model(size: rect.size)
            ZStack(alignment: .topLeading) {
                canvas(model: model, rect: rect)
                if let hovered {
                    hoverCard(hovered, rect: rect)
                }
            }
            .contentShape(Rectangle())
            .gesture(brushGesture(model: model, rect: rect))
            .onContinuousHover { phase in handleHover(phase, model: model, rect: rect) }
        }
    }

    private static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: leftGutter, y: topGutter,
               width: max(size.width - leftGutter - rightGutter, 1),
               height: max(size.height - topGutter - bottomGutter, 1))
    }

    private func canvas(model: SetPlotModel, rect: CGRect) -> some View {
        Canvas { context, _ in
            let origin = rect.origin
            var grid = Path()
            for i in 0...4 {
                let x = rect.minX + rect.width * CGFloat(i) / 4
                let y = rect.minY + rect.height * CGFloat(i) / 4
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                grid.move(to: CGPoint(x: rect.minX, y: y))
                grid.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            context.stroke(grid, with: .color(PanelTheme.disabledColor.opacity(0.15)),
                           lineWidth: 0.5)

            let categories = model.categories
            for point in model.points {
                let at = CGPoint(x: origin.x + point.position.x, y: origin.y + point.position.y)
                let selected = model.selection.contains(point.id)
                let peeked = point.id == model.peekedID
                // Spec §4.3: staged points are ringed, the peek point is large.
                let radius: CGFloat = peeked ? 6 : (selected ? 4 : 3)
                let box = CGRect(x: at.x - radius, y: at.y - radius,
                                 width: radius * 2, height: radius * 2)
                let fill = Self.pointColor(point, model: model, categories: categories)
                context.fill(Path(ellipseIn: box),
                             with: .color(point.isRejected ? fill.opacity(0.25) : fill))
                if point.isStaged {
                    context.stroke(Path(ellipseIn: box.insetBy(dx: -2.5, dy: -2.5)),
                                   with: .color(PanelTheme.accentColor), lineWidth: 1.5)
                }
                if point.isStarred {
                    // The four the user picked out of a thousand have to be findable
                    // in the cloud, not only in the table.
                    context.stroke(Path(ellipseIn: box.insetBy(dx: -1.5, dy: -1.5)),
                                   with: .color(PanelTheme.atomTranspColor), lineWidth: 1.5)
                }
                if selected {
                    context.stroke(Path(ellipseIn: box.insetBy(dx: -4, dy: -4)),
                                   with: .color(PanelTheme.textColor.opacity(0.8)), lineWidth: 1)
                }
                if peeked {
                    context.stroke(Path(ellipseIn: box.insetBy(dx: -1, dy: -1)),
                                   with: .color(PanelTheme.textColor), lineWidth: 1.5)
                }
            }

            for value in SetPlotModel.ticks(model.yDomain) {
                let y = rect.minY + SetPlotModel.position(value, in: model.yDomain,
                                                          length: rect.height, flipped: true)
                context.draw(Self.tick(value, column: column(yKey)),
                             at: CGPoint(x: rect.minX - 5, y: y), anchor: .trailing)
            }
            for value in SetPlotModel.ticks(model.xDomain) {
                let x = rect.minX + SetPlotModel.position(value, in: model.xDomain,
                                                          length: rect.width, flipped: false)
                context.draw(Self.tick(value, column: column(xKey)),
                             at: CGPoint(x: x, y: rect.maxY + 7), anchor: .center)
            }

            if let band {
                context.fill(Path(band), with: .color(PanelTheme.accentColor.opacity(0.12)))
                context.stroke(Path(band), with: .color(PanelTheme.accentColor), lineWidth: 1)
            }
        }
    }

    private static func tick(_ value: Double, column: MetricColumn?) -> Text {
        Text(column.map { SetTableModel.format(.number(value), $0) } ?? "")
            .font(.system(size: 8).monospacedDigit())
            .foregroundColor(PanelTheme.disabledColor)
    }

    // MARK: controls

    private var controls: some View {
        HStack(spacing: 10) {
            axisMenu("x", key: $xKey)
            axisMenu("y", key: $yKey)
            colorMenu
            Spacer(minLength: 8)
            if case .category = colorChoice { legend }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }

    private func axisMenu(_ label: String, key: Binding<String>) -> some View {
        Menu {
            ForEach(numericColumns) { column in
                Button(SetTableModel.header(column)) { key.wrappedValue = column.column ?? "" }
            }
        } label: {
            Text("\(label): \(column(key.wrappedValue).map(SetTableModel.header) ?? "—")")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which column this axis plots")
    }

    private var colorMenu: some View {
        Menu {
            Button("None") { colorChoice = .none }
            Divider()
            ForEach(numericColumns) { column in
                Button(SetTableModel.header(column)) {
                    colorChoice = .metric(column.column ?? "")
                }
            }
            Divider()
            ForEach(SetPlotCategory.allCases) { kind in
                Button(kind.label) { colorChoice = .category(kind) }
            }
        } label: {
            Text("color: \(colorLabel)").font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Colour points by a third column, or split them by tag, parent or run")
    }

    private var colorLabel: String {
        switch colorChoice {
        case .none: return "—"
        case .metric(let name): return column(name).map(SetTableModel.header) ?? name
        case .category(let kind): return kind.label
        }
    }

    private var legend: some View {
        let categories = model(size: CGSize(width: 1, height: 1)).categories
        return HStack(spacing: 8) {
            ForEach(categories.prefix(6), id: \.self) { value in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Self.categoryColor(value, in: categories))
                        .frame(width: 6, height: 6)
                    Text(value.isEmpty ? "(none)" : value)
                        .font(.system(size: 9))
                        .foregroundColor(PanelTheme.disabledColor)
                        .lineLimit(1)
                }
            }
            if categories.count > 6 {
                Text("+\(categories.count - 6)")
                    .font(.system(size: 9))
                    .foregroundColor(PanelTheme.disabledColor)
            }
        }
    }

    // MARK: colour

    private static func pointColor(_ point: SetPlotPoint, model: SetPlotModel,
                                   categories: [String]) -> Color {
        switch model.color {
        case .none:
            return PanelTheme.accentColor.opacity(0.75)
        case .metric:
            guard let g = point.goodness else { return PanelTheme.disabledColor }
            // The table's ramp, so a point and its cell agree about what is good.
            return Color(.sRGB, red: 0.85 + (0.20 - 0.85) * g,
                         green: 0.35 + (0.65 - 0.35) * g,
                         blue: 0.30 + (0.40 - 0.30) * g, opacity: 0.9)
        case .category:
            return categoryColor(point.category, in: categories)
        }
    }

    /// A categorical palette indexed by the bucket's POSITION, so the legend and the
    /// points cannot disagree and a tag keeps its colour as long as the set does.
    /// Grey is reserved for "no value".
    static func categoryColor(_ value: String, in categories: [String]) -> Color {
        guard !value.isEmpty, let index = categories.firstIndex(of: value) else {
            return PanelTheme.disabledColor
        }
        let palette: [Color] = [
            Color(.sRGB, red: 0.27, green: 0.53, blue: 0.85, opacity: 0.9),
            Color(.sRGB, red: 0.90, green: 0.52, blue: 0.20, opacity: 0.9),
            Color(.sRGB, red: 0.25, green: 0.68, blue: 0.42, opacity: 0.9),
            Color(.sRGB, red: 0.80, green: 0.35, blue: 0.55, opacity: 0.9),
            Color(.sRGB, red: 0.55, green: 0.45, blue: 0.80, opacity: 0.9),
            Color(.sRGB, red: 0.75, green: 0.70, blue: 0.25, opacity: 0.9),
        ]
        return palette[index % palette.count]
    }

    // MARK: interaction

    private func brushGesture(model: SetPlotModel, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = bandOrigin ?? value.startLocation
                bandOrigin = origin
                band = CGRect(x: min(origin.x, value.location.x),
                              y: min(origin.y, value.location.y),
                              width: abs(value.location.x - origin.x),
                              height: abs(value.location.y - origin.y))
            }
            .onEnded { _ in
                let finished = band
                band = nil
                bandOrigin = nil
                guard let finished else { return }
                // Brushing SELECTS rows (spec §4.3); it does not filter. The table
                // highlights and scrolls to them and the footer's verbs act on them,
                // which is the linked half of this ticket. Turning a band INTO a
                // filter is the footer's "Filter to brush", a separate deliberate act.
                let ids = model.rowIDs(in: finished.offsetBy(dx: -rect.minX, dy: -rect.minY))
                engine.setSelection = ids
            }
    }

    private func handleHover(_ phase: HoverPhase, model: SetPlotModel, rect: CGRect) {
        switch phase {
        case .active(let location):
            // Inside the card the pointer is USING it (Stage / ★ / ✕), not leaving the
            // point, so the card stands. Without this the card vanishes the moment the
            // pointer crosses onto its own buttons.
            if let hovered, Self.cardRect(for: hovered, in: rect).contains(location) { return }
            let local = CGPoint(x: location.x - rect.minX, y: location.y - rect.minY)
            let point = model.nearest(to: local)
            if point?.id != hovered?.id {
                hovered = point
                schedulePeek(point)
            }
        case .ended:
            hovered = nil
            hoverWork?.cancel()
        @unknown default:
            hovered = nil
        }
    }

    /// The same 120 ms debounce the table's hover has, for the same reason: a peek is
    /// N chain loads and a superposition, and a pointer swept across a thousand points
    /// would queue a thousand of them.
    private func schedulePeek(_ point: SetPlotPoint?) {
        hoverWork?.cancel()
        guard let point, point.id != engine.peekedEntryID,
              let row = rows.first(where: { $0.id == point.id }) else { return }
        let work = DispatchWorkItem { [set] in engine.peekEntry(set, row) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Where the hover card sits, clamped inside the plot so a point near an edge does
    /// not push it out of the drawer. One function, used both to place it and to tell
    /// whether the pointer is on it.
    private static func cardRect(for point: SetPlotPoint, in rect: CGRect) -> CGRect {
        let x = min(rect.minX + point.position.x + 10, max(rect.maxX - cardSize.width, rect.minX))
        let y = min(max(rect.minY + point.position.y - 30, rect.minY),
                    max(rect.maxY - cardSize.height, rect.minY))
        return CGRect(origin: CGPoint(x: x, y: y), size: cardSize)
    }

    /// Spec §4.3's hover card: what the point is, and the three verbs.
    private func hoverCard(_ point: SetPlotPoint, rect: CGRect) -> some View {
        let row = rows.first { $0.id == point.id }
        let frame = Self.cardRect(for: point, in: rect)
        return VStack(alignment: .leading, spacing: 2) {
            Text(point.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                if let x = column(xKey) {
                    Text("\(x.title) \(SetTableModel.format(.number(point.x), x))")
                }
                if let y = column(yKey) {
                    Text("\(y.title) \(SetTableModel.format(.number(point.y), y))")
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundColor(PanelTheme.disabledColor)
            .lineLimit(1)
            if let row {
                HStack(spacing: 4) {
                    Button(row.isStaged ? "Unstage" : "Stage") { engine.toggleStage(set, [row]) }
                        .help("set_stage / set_unstage this entry")
                    Button(row.starred ? "★" : "☆") { engine.setStar(set, [row], on: !row.starred) }
                        .help(row.starred ? "Unstar (set_star, on=0)" : "Star (set_star)")
                    Button("✕") { engine.setReject(set, [row], on: !row.rejected) }
                        .help(row.rejected ? "Clear the reject flag" : "Reject (set_reject)")
                }
                .controlSize(.mini)
                .font(.system(size: 9))
            }
        }
        .padding(5)
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(PanelTheme.buttonBackground))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(hairline, lineWidth: 1))
        .foregroundColor(PanelTheme.textColor)
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: chrome

    private var footer: some View {
        let model = self.model(size: CGSize(width: 100, height: 100))
        return HStack(spacing: 8) {
            Text("\(rows.count) shown"
                 + (model.unplaced > 0 ? " · \(model.unplaced) without both values" : ""))
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(PanelTheme.disabledColor)
                .help(model.unplaced > 0
                      ? "An entry with no value on an axis is left out rather than drawn "
                        + "at zero — an unmeasured entry is not a bad one."
                      : "Every filtered entry is on the plot")
            if !engine.setSelection.isEmpty {
                Text("\(engine.setSelection.count) selected")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(PanelTheme.textColor)
            }
            Spacer()
            Button("Filter to selection") { filterToSelection(model: model) }
                .controlSize(.small)
                .disabled(engine.setSelection.isEmpty)
                .help("Turn the brushed points into a range filter on both axes "
                      + "(set_filter), so the table, the plot and every set_* command "
                      + "narrow together")
            Button("Clear selection") { engine.setSelection = [] }
                .controlSize(.small)
                .disabled(engine.setSelection.isEmpty)
                .help("Deselect every point; the table follows")
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    /// The selected points' bounding box, as two range brushes. Goes through
    /// `SetFilterComposer` and then through Python's grammar, which is the same path a
    /// typed expression takes — Swift builds the string and decides nothing else.
    private func filterToSelection(model: SetPlotModel) {
        let chosen = model.points.filter { engine.setSelection.contains($0.id) }
        guard !chosen.isEmpty, let xName = column(xKey)?.column,
              let yName = column(yKey)?.column else { return }
        let xs = chosen.map(\.x), ys = chosen.map(\.y)
        engine.updateBrushes(set, [SetBrush(column: xName, lo: xs.min()!, hi: xs.max()!),
                                   SetBrush(column: yName, lo: ys.min()!, hi: ys.max()!)])
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Two numeric columns are needed to plot")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(PanelTheme.textColor)
            Text("This set declares \(numericColumns.count). Columns come from the "
                 + "metric schema of whatever produced the entries, so a set imported "
                 + "without a score file has none until one is added.")
                .font(.system(size: 11))
                .foregroundColor(PanelTheme.disabledColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
