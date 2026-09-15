import XCTest
@testable import RayMol

/// The Plot tab (#418) is thin over `SetPlotModel`, and everything the plot decides —
/// the axis domain, where a value lands, what a rubber band covers, and what a brush
/// says in the filter language — is a pure function of some rows, two columns and a
/// rect. These pin those decisions without a window.
///
/// The last group is the important one. A brush does not filter; it PRINTS
/// `plddt >= 80 and plddt <= 92` and sends it to Python, which owns the only filter
/// grammar there is. So the tests here say what the string looks like, and
/// `testing/tests/sets/sets_filter.py::BrushShapeTest` says that Python accepts exactly
/// that shape and counts the same rows `set_filter` does. Neither half can catch a
/// drift on its own, which is why both exist.
final class SetPlotModelTests: XCTestCase {

    // MARK: fixtures

    private let plddt = MetricColumn(key: "plddt", dtype: "float", label: "pLDDT",
                                     lo: 0, hi: 100, higherIsBetter: true, column: "plddt")
    private let rmsd = MetricColumn(key: "rmsd", dtype: "float", units: "Å", label: "RMSD",
                                    lo: 0, hi: 10, higherIsBetter: false, column: "rmsd")
    /// No declared domain: the axis has to come from what was measured.
    private let score = MetricColumn(key: "score", dtype: "float", label: "score",
                                     column: "score")
    private let verdict = MetricColumn(key: "verdict", dtype: "str", column: "verdict")

    private func row(_ name: String, ord: Int, plddt: Double? = nil, rmsd: Double? = nil,
                     score: Double? = nil, staged: Bool = false, starred: Bool = false,
                     rejected: Bool = false, tags: String = "", run: String? = nil,
                     parents: [String] = []) -> SetRow {
        var values: [String: MetricValue] = [:]
        values["plddt"] = plddt.map { .number($0) } ?? .null
        values["rmsd"] = rmsd.map { .number($0) } ?? .null
        values["score"] = score.map { .number($0) } ?? .null
        return SetRow(id: "id_\(name)", name: name, ord: ord, starred: starred,
                      rejected: rejected, pinned: false,
                      stagedObject: staged ? name : nil, nChains: 1, nResidues: 70,
                      tags: tags, runID: run, values: values, parents: parents)
    }

    /// Four placed points on a 100×100 rect, at the corners of the declared domains:
    /// pLDDT 0…100 across, RMSD 0…10 up (so a LOW rmsd is a HIGH y on screen… no: the
    /// axis is flipped, so rmsd 0 is at y = 100, the bottom).
    private var rows: [SetRow] {
        [
            row("a", ord: 1, plddt: 0, rmsd: 0, score: 1, tags: "patch-A", run: "r1"),
            row("b", ord: 2, plddt: 100, rmsd: 10, score: 5, staged: true, tags: "patch-B",
                run: "r1", parents: ["p1"]),
            row("c", ord: 3, plddt: 50, rmsd: 5, score: 3, starred: true, run: "r2",
                parents: ["p2"]),
            row("d", ord: 4, plddt: nil, rmsd: 2, score: 9),        // no x
        ]
    }

    private func model(_ rows: [SetRow]? = nil, size: CGSize = CGSize(width: 100, height: 100),
                       color: SetPlotColor = .none, selection: Set<String> = [],
                       peeked: String? = nil) -> SetPlotModel {
        SetPlotModel(rows: rows ?? self.rows, xColumn: plddt, yColumn: rmsd,
                     color: color, size: size, selection: selection, peekedID: peeked)
    }

    // MARK: domains

    func testDeclaredDomainWins() {
        // Two runs of one tool have to draw on the same axis, so the spec's lo/hi beat
        // whatever this particular set happens to contain.
        XCTAssertEqual(model().xDomain, 0...100)
        XCTAssertEqual(model().yDomain, 0...10)
    }

    func testObservedDomainIsPadded() {
        // With no declared domain the extremes are what the user is looking for, so
        // they must not be drawn on the frame.
        let domain = SetPlotModel.domain(values: [1, 5, 9], lo: nil, hi: nil)
        XCTAssertEqual(domain.lowerBound, 1 - 0.4, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 9 + 0.4, accuracy: 1e-9)
    }

    func testDegenerateDomainOpensRatherThanDividingByZero() {
        XCTAssertEqual(SetPlotModel.domain(values: [7, 7, 7], lo: nil, hi: nil), 6.5...7.5)
        XCTAssertEqual(SetPlotModel.domain(values: [], lo: nil, hi: nil), -0.5...0.5)
        // A spec whose hi is not above its lo is not a domain either.
        XCTAssertEqual(SetPlotModel.domain(values: [2, 4], lo: 5, hi: 5).lowerBound,
                       2 - 0.1, accuracy: 1e-9)
    }

    func testOneDeclaredBoundIsStillADomain() {
        // A metric with lo=0 and no ceiling: the axis starts at zero, and the open end
        // is padded like an observed one.
        let low = SetPlotModel.domain(values: [0.4, 0.6], lo: 0, hi: nil)
        XCTAssertEqual(low.lowerBound, 0)
        XCTAssertEqual(low.upperBound, 0.6 + 0.01, accuracy: 1e-9)
        let high = SetPlotModel.domain(values: [0.4, 0.6], lo: nil, hi: 1)
        XCTAssertEqual(high.lowerBound, 0.4 - 0.01, accuracy: 1e-9)
        XCTAssertEqual(high.upperBound, 1)
    }

    func testNonFiniteValuesAreIgnoredByTheDomain() {
        let domain = SetPlotModel.domain(values: [1, .nan, 3, .infinity], lo: nil, hi: nil)
        XCTAssertEqual(domain.lowerBound, 1 - 0.1, accuracy: 1e-9)
        XCTAssertEqual(domain.upperBound, 3 + 0.1, accuracy: 1e-9)
    }

    // MARK: scales

    func testPositionMapsTheDomainOntoTheAxis() {
        XCTAssertEqual(SetPlotModel.position(0, in: 0...100, length: 200, flipped: false), 0)
        XCTAssertEqual(SetPlotModel.position(50, in: 0...100, length: 200, flipped: false), 100)
        XCTAssertEqual(SetPlotModel.position(100, in: 0...100, length: 200, flipped: false), 200)
    }

    func testTheYAxisIsFlippedBecauseScreenYGrowsDownwards() {
        XCTAssertEqual(SetPlotModel.position(0, in: 0...10, length: 100, flipped: true), 100)
        XCTAssertEqual(SetPlotModel.position(10, in: 0...10, length: 100, flipped: true), 0)
    }

    func testPositionClampsRatherThanDrawingOffScreen() {
        // A tool that rounds a pLDDT to 101 belongs on the frame, not outside it.
        XCTAssertEqual(SetPlotModel.position(101, in: 0...100, length: 100, flipped: false), 100)
        XCTAssertEqual(SetPlotModel.position(-5, in: 0...100, length: 100, flipped: false), 0)
    }

    func testValueIsThePositionInverse() {
        for value in [0.0, 12.5, 50.0, 99.9, 100.0] {
            let p = SetPlotModel.position(value, in: 0...100, length: 250, flipped: false)
            XCTAssertEqual(SetPlotModel.value(at: p, in: 0...100, length: 250, flipped: false),
                           value, accuracy: 1e-9, "x round trip at \(value)")
            let q = SetPlotModel.position(value, in: 0...100, length: 250, flipped: true)
            XCTAssertEqual(SetPlotModel.value(at: q, in: 0...100, length: 250, flipped: true),
                           value, accuracy: 1e-9, "y round trip at \(value)")
        }
    }

    func testAZeroLengthAxisIsNotADivisionByZero() {
        XCTAssertEqual(SetPlotModel.position(50, in: 0...100, length: 0, flipped: false), 0)
        XCTAssertEqual(SetPlotModel.value(at: 10, in: 5...9, length: 0, flipped: false), 5)
    }

    // MARK: points

    func testPointsLandWhereTheScalesSayAndNullsAreLeftOut() {
        let points = model().points
        XCTAssertEqual(points.map(\.name), ["a", "b", "c"],
                       "an entry with no value on an axis is not drawn at zero")
        XCTAssertEqual(model().unplaced, 1)
        XCTAssertEqual(points[0].position, CGPoint(x: 0, y: 100))    // plddt 0, rmsd 0
        XCTAssertEqual(points[1].position, CGPoint(x: 100, y: 0))    // plddt 100, rmsd 10
        XCTAssertEqual(points[2].position, CGPoint(x: 50, y: 50))
    }

    func testPointsCarryTheFlagsTheViewDraws() {
        let points = model().points
        XCTAssertEqual(points.first { $0.name == "b" }?.isStaged, true)
        XCTAssertEqual(points.first { $0.name == "c" }?.isStarred, true)
        XCTAssertEqual(points.first { $0.name == "a" }?.isStaged, false)
    }

    func testWithoutBothAxesThereAreNoPoints() {
        let model = SetPlotModel(rows: rows, xColumn: nil, yColumn: rmsd)
        XCTAssertTrue(model.points.isEmpty)
        XCTAssertEqual(model.unplaced, rows.count)
    }

    func testAStringColumnHasNoPlaceOnAnAxis() {
        // `verdict` is a str column; it has a wide-table column but no numbers, so
        // every row is unplaced rather than placed at zero.
        let model = SetPlotModel(rows: rows, xColumn: verdict, yColumn: rmsd)
        XCTAssertTrue(model.points.isEmpty)
    }

    // MARK: colour

    func testMetricColourUsesTheTablesRamp() {
        var m = model(color: .metric("plddt"))
        m.colorColumn = plddt
        let byName = Dictionary(uniqueKeysWithValues: m.points.map { ($0.name, $0) })
        // higher_is_better, domain 0…100: pLDDT 100 is fully good, 0 fully bad.
        XCTAssertEqual(byName["a"]?.goodness, 0)
        XCTAssertEqual(byName["b"]?.goodness, 1)
        XCTAssertEqual(byName["c"]?.goodness, 0.5)
    }

    func testCategoriesAreStableAndPutNoValueLast() {
        let tagged = model(color: .category(.tag))
        XCTAssertEqual(tagged.categories, ["patch-A", "patch-B", ""],
                       "named buckets sort; \"untagged\" is not a finding, so it goes last")
        // "d" has no run, so the empty bucket is there too — and still last.
        XCTAssertEqual(model(color: .category(.run)).categories, ["r1", "r2", ""])
        XCTAssertEqual(model(color: .category(.parent)).categories, ["p1", "p2", ""])
        XCTAssertEqual(model(color: .category(.staged)).categories, ["staged", ""])
    }

    func testCategoryOfARowReadsTheFieldItNames() {
        let b = rows[1]
        XCTAssertEqual(SetPlotCategory.tag.value(of: b), "patch-B")
        XCTAssertEqual(SetPlotCategory.parent.value(of: b), "p1")
        XCTAssertEqual(SetPlotCategory.run.value(of: b), "r1")
        XCTAssertEqual(SetPlotCategory.staged.value(of: b), "staged")
        XCTAssertEqual(SetPlotCategory.tag.value(of: rows[2]), "")
    }

    // MARK: brushing → selection

    func testARubberBandSelectsThePointsInsideIt() {
        let ids = model().rowIDs(in: CGRect(x: 40, y: 40, width: 20, height: 20))
        XCTAssertEqual(ids, ["id_c"])
    }

    func testABandOverEverythingSelectsEveryPlacedPoint() {
        let ids = model().rowIDs(in: CGRect(x: -10, y: -10, width: 200, height: 200))
        XCTAssertEqual(ids, ["id_a", "id_b", "id_c"],
                       "the unplaced row cannot be brushed; it is not on the plot")
    }

    func testAClickIsNotABrush() {
        // Under a point in either direction is a click, and a click must not clear the
        // selection by "brushing" one pixel.
        XCTAssertTrue(model().rowIDs(in: CGRect(x: 50, y: 50, width: 0, height: 0)).isEmpty)
        XCTAssertTrue(model().rowIDs(in: CGRect(x: 50, y: 50, width: 0.5, height: 40)).isEmpty)
    }

    func testNearestFindsThePointUnderThePointer() {
        XCTAssertEqual(model().nearest(to: CGPoint(x: 52, y: 48))?.name, "c")
        XCTAssertNil(model().nearest(to: CGPoint(x: 52, y: 48), within: 1),
                     "a tight radius finds nothing rather than the nearest thing anywhere")
    }

    // MARK: brushing → the filter language

    func testABandBecomesARangeOnEachAxis() {
        // The top-left quarter: low pLDDT, high RMSD. y is flipped, so the TOP of the
        // band is the LARGER rmsd — getting that backwards would filter the complement.
        let brushes = model().brushes(in: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(brushes.count, 2)
        XCTAssertEqual(brushes[0].column, "plddt")
        XCTAssertEqual(brushes[0].lo, 0, accuracy: 1e-9)
        XCTAssertEqual(brushes[0].hi, 50, accuracy: 1e-9)
        XCTAssertEqual(brushes[1].column, "rmsd")
        XCTAssertEqual(brushes[1].lo, 5, accuracy: 1e-9)
        XCTAssertEqual(brushes[1].hi, 10, accuracy: 1e-9)
    }

    func testTheBrushPrintsTheExpressionPythonCompiles() {
        // The exact shape `sets_filter.py::BrushShapeTest` asserts compiles, and the
        // only thing Swift ever decides about the filter language.
        XCTAssertEqual(SetBrush(column: "plddt", lo: 80, hi: 92).clause,
                       "plddt >= 80 and plddt <= 92")
        XCTAssertEqual(SetBrush(column: "rmsd", lo: 0.5, hi: 1.75).clause,
                       "rmsd >= 0.5 and rmsd <= 1.75")
        XCTAssertEqual(SetBrush(column: "plddt__b", lo: 70, hi: 90).clause,
                       "plddt__b >= 70 and plddt__b <= 90",
                       "a chain scalar is a column like any other")
    }

    func testABrushIsNormalisedSoADragBackwardsStillReads() {
        let brush = SetBrush(column: "plddt", lo: 92, hi: 80)
        XCTAssertEqual(brush.lo, 80)
        XCTAssertEqual(brush.hi, 92)
        XCTAssertEqual(brush.clause, "plddt >= 80 and plddt <= 92")
    }

    func testABrushThatCannotBeWrittenSafelyIsNotWritten() {
        XCTAssertNil(SetBrush(column: "plddt", lo: .nan, hi: 1).clause)
        XCTAssertNil(SetBrush(column: "plddt", lo: 0, hi: .infinity).clause)
        XCTAssertNil(SetBrush(column: "drop table entries", lo: 0, hi: 1).clause,
                     "a column name that is not a column never reaches the expression")
        XCTAssertNil(SetBrush(column: "", lo: 0, hi: 1).clause)
    }

    func testNumbersPrintAsLiteralsTheGrammarReadsBackEXACTLY() {
        XCTAssertEqual(SetBrush.literal(80), "80", "integral: exact, and binds as INTEGER")
        XCTAssertEqual(SetBrush.literal(-12), "-12")
        XCTAssertEqual(SetBrush.literal(0.5), "0.5")
        // The bug this replaced: `%.6g` printed 40.10274153313269 as "40.1027", and a
        // `>=` on the rounded-UP end excluded the very row that defined it. Every
        // bound "Filter to selection" composes is a measured value, so this was the
        // common case, and the rows it lost were the extremes a triage user is after.
        for value in [40.10274153313269, 40.24152259971877, 1.0 / 3.0, -0.0000012345,
                      1e-5, 1e16, 9.87654321098765e-4, Double.pi] {
            let text = SetBrush.literal(value)
            XCTAssertEqual(Double(text), value,
                           "\(value) must read back as itself, printed as \(text)")
        }
    }

    func testTheClauseCarriesTheExactBoundAndTheChipRoundsIt() {
        let brush = SetBrush(column: "plddt", lo: 40.10274153313269, hi: 40.24152259971877)
        XCTAssertEqual(brush.clause,
                       "plddt >= 40.10274153313269 and plddt <= 40.24152259971877")
        // The human-facing label may round; the predicate may not.
        XCTAssertEqual(brush.rangeLabel, "40.1027 – 40.2415")
    }

    func testFilterToSelectionKeepsThePointsThatDefinedItsEdges() {
        // Five points whose plddt carries more than six significant figures — which is
        // to say, five measured points. The brushes composed from their own min and
        // max have to include all five.
        let values = [40.10274153313269, 40.13901288888891, 40.17,
                      40.20419283746519, 40.24152259971877]
        let rows = values.enumerated().map { i, v in
            row("p\(i)", ord: i, plddt: v, rmsd: Double(i) / 10)
        }
        let lo = values.min()!, hi = values.max()!
        let brush = SetBrush(column: "plddt", lo: lo, hi: hi)
        let bound = brush.clause!.split(separator: " ")
        let low = Double(bound[2])!, high = Double(bound[6])!
        let kept = rows.filter { row in
            guard let v = row.values["plddt"]?.number else { return false }
            return v >= low && v <= high
        }
        XCTAssertEqual(kept.count, 5,
                       "a bound printed lossily drops the row that defined it")
    }

    // MARK: composing the one expression

    func testTypedTextAloneIsTheExpressionVerbatim() {
        let composed = SetFilterComposer.compose(text: "plddt > 80", brushes: [])
        XCTAssertEqual(composed.expression, "plddt > 80")
        XCTAssertEqual(composed.textOffset, 0,
                       "with no brush an error offset is already an offset into what "
                       + "the user typed")
    }

    func testBrushesAloneCompose() {
        let composed = SetFilterComposer.compose(
            text: "  ", brushes: [SetBrush(column: "rmsd", lo: 0, hi: 2),
                                  SetBrush(column: "plddt", lo: 80, hi: 92)])
        XCTAssertEqual(composed.expression,
                       "(plddt >= 80 and plddt <= 92) and (rmsd >= 0 and rmsd <= 2)",
                       "brushes sort by column so the expression is stable across drags")
        XCTAssertEqual(composed.textOffset, -1)
    }

    func testATypedOrIsNotSwallowedByABrushesAnd() {
        let composed = SetFilterComposer.compose(
            text: "plddt > 90 or starred",
            brushes: [SetBrush(column: "rmsd", lo: 0, hi: 2)])
        XCTAssertEqual(composed.expression,
                       "(plddt > 90 or starred) and (rmsd >= 0 and rmsd <= 2)")
        XCTAssertEqual(composed.textOffset, 1, "the wrapping paren shifts it by one")
    }

    func testAnErrorOffsetMapsBackOntoWhatTheUserTyped() {
        let composed = SetFilterComposer.compose(
            text: "plddt > \"x\"", brushes: [SetBrush(column: "rmsd", lo: 0, hi: 2)])
        // Python reports offset 9 in the COMPOSED string; the user typed it at 8.
        XCTAssertEqual(composed.textOffset(forExpressionOffset: 9, textLength: 11), 8)
        XCTAssertEqual(SetFilterState.token(in: "plddt > \"x\"", at: 8), "\"x\"")
    }

    func testAnOffsetInsideABrushIsNotBlamedOnTheUser() {
        let composed = SetFilterComposer.compose(text: "starred",
                                                 brushes: [SetBrush(column: "rmsd", lo: 0, hi: 2)])
        XCTAssertNil(composed.textOffset(forExpressionOffset: 40, textLength: 7),
                     "pointing at a character the user cannot see is worse than not "
                     + "pointing at all")
    }

    func testAnEmptyFilterIsEmpty() {
        let composed = SetFilterComposer.compose(text: "   ", brushes: [])
        XCTAssertEqual(composed.expression, "")
        XCTAssertEqual(composed.textOffset, -1)
    }

    func testFlattenedIsWhatWentToSetFilter() {
        XCTAssertEqual(
            SetFilterComposer.flattened(text: "not rejected",
                                        brushes: [SetBrush(column: "plddt", lo: 80, hi: 92)]),
            "(not rejected) and (plddt >= 80 and plddt <= 92)")
    }

    // MARK: the axis strip

    func testAnImposedDomainWinsOverTheComputedOne() {
        // R2: the Plot tab hands the model the range its x strip was BINNED over, so
        // the bars and the points above them cannot disagree — and so the axis holds
        // still while a drag previews, instead of shrinking with the filtered rows.
        var m = model()
        XCTAssertEqual(m.xDomain, 0...100, "the declared domain, with no override")
        m.xDomainOverride = 20...60
        m.yDomainOverride = 1...3
        XCTAssertEqual(m.xDomain, 20...60)
        XCTAssertEqual(m.yDomain, 1...3)
        // And the points move with it: plddt 50 is now dead centre of 20…60.
        let centre = m.points.first { $0.name == "c" }
        XCTAssertEqual(centre?.position.x ?? -1, 75, accuracy: 1e-9)
    }

    func testAnOverriddenDomainStillClampsTheOutliers() {
        var m = model()
        m.xDomainOverride = 20...60
        // plddt 0 and 100 are outside it; they belong on the frame, not off-screen.
        let xs = m.points.map(\.position.x).sorted()
        XCTAssertEqual(xs.first, 0)
        XCTAssertEqual(xs.last, 100)
    }

    func testTicksSpanTheDomain() {
        let ticks = SetPlotModel.ticks(0...100, count: 5)
        XCTAssertEqual(ticks, [0, 25, 50, 75, 100])
        XCTAssertTrue(SetPlotModel.ticks(5...5).isEmpty)
    }

    // MARK: what Send to ▾ builds

    func testSendTargetsAreEntrySelectors() {
        XCTAssertEqual(SetSendTarget.filtered.selector, "filtered")
        XCTAssertEqual(SetSendTarget.view("top50").selector, "view:top50")
        XCTAssertEqual(SetSendTarget.selection(["d_0417", "d_0088"]).selector,
                       "d_0417+d_0088")
    }

    func testAnEmptySelectionFallsBackToTheFilter() {
        // Every set_* command defaults to `filtered`; sending "nothing" would be the
        // one case where the menu did something different from the console.
        XCTAssertEqual(SetSendTarget.selection([]).selector, "filtered")
        XCTAssertEqual(SetSendTarget.selection(["a+b"]).selector, "filtered",
                       "a name the selector language cannot express is not sent as one")
    }
}

/// The two drawer behaviours that are about TIMING and about what the UI claims, not
/// about geometry (#418 review, blockers 1-2 and R3). Driven through
/// `PyMOLEngine.shared` and its `pythonTap`, the way DesignModeStateTests drives the
/// engine: nothing here needs a running core, only the published state and the
/// expression the verbs would send.
final class SetFilterTimingTests: XCTestCase {

    private var engine: PyMOLEngine { PyMOLEngine.shared }

    private let plddt = MetricColumn(key: "plddt", dtype: "float", label: "pLDDT",
                                     lo: 0, hi: 100, higherIsBetter: true, column: "plddt")
    private let rmsd = MetricColumn(key: "rmsd", dtype: "float", lo: 0, hi: 10,
                                    higherIsBetter: false, column: "rmsd")

    private var set: SetEntry {
        SetEntry(id: "ab12cd34", name: "rfd3_a1", kind: "structures", tool: "rfd3",
                 count: 3, stagedCount: 1, budget: 6, groupName: "rfd3_a1",
                 reference: "", rankingKey: "plddt", sortKey: "plddt",
                 sortDescending: true, filter: "", columns: [plddt, rmsd],
                 histogram: [])
    }

    private func row(_ name: String, ord: Int, staged: Bool = false) -> SetRow {
        SetRow(id: "id_\(name)", name: name, ord: ord, starred: false, rejected: false,
               pinned: false, stagedObject: staged ? name : nil, nChains: 1,
               nResidues: 70, tags: "", runID: nil,
               values: ["plddt": .number(90), "rmsd": .number(1)])
    }

    override func setUp() {
        super.setUp()
        engine.pythonTap = nil      // first: the reset below emits Python
        engine.resetSetUIState()
        engine.setRows = []
        engine.activeSetID = nil
    }

    override func tearDown() {
        engine.pythonTap = nil
        engine.resetSetUIState()
        engine.setRows = []
        engine.activeSetID = nil
        super.tearDown()
    }

    /// BLOCKER 2. The filter bar's debounced work items must read the engine at FIRE
    /// time. They used to capture the expression composed at the keystroke, and a
    /// brush landing in between — a header drag, "Filter to selection", a chip's ×,
    /// all of which go through the engine where the bar's `@State` items cannot see
    /// them — was silently dropped from what `set_filter` received while its chip was
    /// still on screen. `set_export` and Send to ▾ then acted on a weaker filter than
    /// the UI claimed.
    func testADebouncedApplySeesABrushThatLandedAfterTheKeystroke() {
        var sent: [String] = []
        engine.setFilterText = "plddt > 80"
        // Exactly what SetFilterBar.schedule() builds.
        let work = DispatchWorkItem { [engine] in engine.applyCurrentFilter(self.set) }
        engine.pythonTap = { sent.append($0) }

        // ... and the brush arrives before the 600 ms is up.
        engine.setBrushes = [SetBrush(column: "rmsd", lo: 0, hi: 2)]
        work.perform()

        let last = sent.last ?? ""
        XCTAssertTrue(last.contains("(plddt > 80) and (rmsd >= 0 and rmsd <= 2)"),
                      "the apply must carry the brush that was on screen when it fired, "
                      + "not the expression composed one keystroke earlier: \(last)")
    }

    /// The same in the other direction: a chip's × before the fire must not be undone
    /// by an apply that still remembers the clause.
    func testADebouncedApplyDoesNotResurrectADroppedBrush() {
        var sent: [String] = []
        engine.setFilterText = "plddt > 80"
        engine.setBrushes = [SetBrush(column: "rmsd", lo: 0, hi: 2)]
        let work = DispatchWorkItem { [engine] in engine.applyCurrentFilter(self.set) }
        engine.pythonTap = { sent.append($0) }

        engine.setBrushes = []          // the × is clicked
        work.perform()

        let last = sent.last ?? ""
        XCTAssertFalse(last.contains("rmsd"),
                       "rows must not be hidden by a predicate nothing on screen "
                       + "mentions: \(last)")
        XCTAssertTrue(last.contains("plddt > 80"), last)
    }

    func testTheComposedExpressionIsWhatTheVerbsSend() {
        engine.setFilterText = "not rejected"
        engine.setBrushes = [SetBrush(column: "plddt", lo: 80, hi: 92)]
        XCTAssertEqual(engine.currentFilterExpression,
                       "(not rejected) and (plddt >= 80 and plddt <= 92)")
        engine.setFilterText = ""
        engine.setBrushes = []
        XCTAssertEqual(engine.currentFilterExpression, "")
    }

    /// R3. Clicking a staged object whose row the filter hides did nothing and said
    /// nothing. The drawer now names the entry and offers to clear the filter.
    func testAViewportClickOnAFilteredOutRowIsNamed() {
        engine.activeSetID = "ab12cd34"
        engine.setRows = [row("d_0001", ord: 1), row("d_0002", ord: 2, staged: true)]
        engine.setFilterMatches = ["id_d_0001"]          // d_0002 is filtered out
        engine.setViewportSelection = ["id_d_0002"]
        XCTAssertEqual(engine.viewportSelectionHidden.map(\.name), ["d_0002"])

        // Visible again: nothing to say.
        engine.setFilterMatches = ["id_d_0001", "id_d_0002"]
        XCTAssertTrue(engine.viewportSelectionHidden.isEmpty)
        // No filter at all: likewise, and without walking the rows.
        engine.setFilterMatches = nil
        XCTAssertTrue(engine.viewportSelectionHidden.isEmpty)
    }

    /// BLOCKER 1, end to end over the published state: the label counts the rows the
    /// drawer is showing.
    func testTheLabelCountsTheRowsTheDrawerShows() {
        engine.activeSetID = "ab12cd34"
        engine.setRows = (1...5).map { row("d_000\($0)", ord: $0) }
        engine.setFilterMatches = ["id_d_0001", "id_d_0002"]
        var state = SetFilterState()
        state.setID = "ab12cd34"
        state.fragment = "m.plddt > ?"
        state.params = [.number(80)]
        state.matched = 99                    // a stale compile, from before the batch
        state.total = 99
        engine.setFilter = state
        XCTAssertEqual(engine.filteredSetRows.count, 2)
        XCTAssertEqual(engine.setFilter.countLabel(matched: engine.filteredSetRows.count,
                                                   total: engine.setRows.count),
                       "2 of 5 match")
    }
}
