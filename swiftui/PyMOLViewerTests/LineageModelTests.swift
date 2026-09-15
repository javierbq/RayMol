// LineageModelTests.swift — the Lineage tab's graph (#419, spec §4.5).
//
// Three things, and the third is the one that decides a piece of UI behaviour:
//
//   * the layering — target → backbones → sequences → folds — from `entries.parents`
//     AND from `runs.parent_set_id`, including the cases where only one of the two is
//     recorded, and the case where a corrupt file would otherwise make it spin;
//   * `descendants` / `subtree`, which is what a node click acts on;
//   * that the click can only be a SELECTION. The filter grammar cannot name entry
//     ids (pinned on the Python side by `TestLineageCannotBeAFilter`), so the click
//     writes into the Table's linked selection. What is asserted here is the part
//     that lives in Swift: the subtree is intersected with the rows actually loaded,
//     because only the active set's rows are.

import XCTest
@testable import RayMol

final class LineageModelTests: XCTestCase {

    private func record(_ id: String, set: String, ord: Int = 0,
                        parents: [String] = [], rejected: Bool = false,
                        run: String? = nil) -> LineageEntryRecord {
        LineageEntryRecord(id: id, setID: set, name: id, ord: ord, parents: parents,
                           rejected: rejected, runID: run)
    }

    /// target → backbones → sequences → folds, as a binder campaign actually lands it.
    private var campaign: [LineageEntryRecord] {
        [
            record("t", set: "target", ord: 0),
            record("bb1", set: "rfd3", ord: 0, parents: ["t"]),
            record("bb2", set: "rfd3", ord: 1, parents: ["t"]),
            record("s1", set: "mpnn", ord: 0, parents: ["bb1"]),
            record("s2", set: "mpnn", ord: 1, parents: ["bb1"]),
            record("s3", set: "mpnn", ord: 2, parents: ["bb2"]),
            record("f1", set: "boltz", ord: 0, parents: ["s1"]),
            record("f2", set: "boltz", ord: 1, parents: ["s3"]),
        ]
    }

    // MARK: layering

    func testEachGenerationIsAColumnToTheRightOfItsParents() {
        let model = LineageModel(entries: campaign)
        let byID = model.nodesByID
        XCTAssertEqual(byID["t"]?.layer, 0)
        XCTAssertEqual(byID["bb1"]?.layer, 1)
        XCTAssertEqual(byID["s1"]?.layer, 2)
        XCTAssertEqual(byID["f1"]?.layer, 3)
        XCTAssertEqual(model.layers.count, 4, "four generations, four columns")
        XCTAssertEqual(model.layers[1].map(\.id), ["bb1", "bb2"])
        XCTAssertEqual(model.layers[2].map(\.id), ["s1", "s2", "s3"])
    }

    func testRowsWithinAColumnAreDeliveryOrder() {
        // The same order the Table's default sort uses, so the two views agree about
        // which of two entries came first.
        let model = LineageModel(entries: campaign)
        XCTAssertEqual(model.layers[2].map(\.row), [0, 1, 2])
        XCTAssertEqual(model.layers[2].map(\.id), ["s1", "s2", "s3"])
    }

    func testAParentSetPlacesEntriesThatCarryNoParentsOfTheirOwn() {
        // #416 delivers per-entry parents, but a tool (or an import) that only records
        // the run's input still knows which set it consumed — and that is enough to
        // put sequences to the right of backbones (store spec §2.2, runs.parent_set_id).
        let entries = [
            record("bb1", set: "rfd3", ord: 0, run: "r1"),
            record("s1", set: "mpnn", ord: 0, run: "r2"),
        ]
        let runs = [
            LineageRunRecord(id: "r1", setID: "rfd3", parentSetID: nil, tool: "rfd3"),
            LineageRunRecord(id: "r2", setID: "mpnn", parentSetID: "rfd3", tool: "mpnn"),
        ]
        let model = LineageModel(entries: entries, runs: runs)
        XCTAssertEqual(model.nodesByID["bb1"]?.layer, 0)
        XCTAssertEqual(model.nodesByID["s1"]?.layer, 1)
        XCTAssertTrue(model.edges.isEmpty, "there is no per-entry edge to draw")
    }

    func testTheLongerOfTheTwoAnswersWins() {
        // A fold whose own parent is a sequence (one hop) but whose RUN consumed a set
        // three generations along must not draw on top of the sequences.
        let entries = [
            record("bb1", set: "rfd3", run: "r1"),
            record("s1", set: "mpnn", parents: ["bb1"], run: "r2"),
            record("f1", set: "boltz", parents: ["s1"], run: "r3"),
        ]
        let runs = [
            LineageRunRecord(id: "r1", setID: "rfd3", parentSetID: nil, tool: "rfd3"),
            LineageRunRecord(id: "r2", setID: "mpnn", parentSetID: "rfd3", tool: "mpnn"),
            LineageRunRecord(id: "r3", setID: "boltz", parentSetID: "mpnn", tool: "boltz"),
        ]
        let model = LineageModel(entries: entries, runs: runs)
        XCTAssertEqual(model.nodesByID["f1"]?.layer, 2)
        // Now drop the per-entry link on the fold: the set edge alone still places it.
        let noParent = [entries[0], entries[1],
                        record("f1", set: "boltz", run: "r3")]
        XCTAssertEqual(LineageModel(entries: noParent, runs: runs)
                        .nodesByID["f1"]?.layer, 2)
    }

    func testAParentInAnotherSetIsAnEdgeAndAMissingOneIsNot() {
        // `entries.parents` "may point into other sets" (store spec §2.2) — that IS
        // the lineage. A parent that no longer exists (its set was deleted) must not
        // become a line to nowhere.
        let entries = [
            record("bb1", set: "rfd3"),
            record("s1", set: "mpnn", parents: ["bb1", "deleted"]),
        ]
        let model = LineageModel(entries: entries)
        XCTAssertEqual(model.edges.count, 1)
        XCTAssertEqual(model.edges.first?.from, "bb1")
        XCTAssertEqual(model.nodesByID["s1"]?.layer, 1,
                       "the missing parent contributes no depth either")
    }

    func testACycleTerminatesRatherThanSpins() {
        // Not something this build can write. A hand-edited or half-migrated file can,
        // and the graph is rebuilt on a version change — so an infinite walk would be
        // a hang in the poll, which is the worst place for one.
        let entries = [
            record("a", set: "s", parents: ["b"]),
            record("b", set: "s", parents: ["a"]),
        ]
        let model = LineageModel(entries: entries)
        XCTAssertEqual(model.nodes.count, 2)
        XCTAssertLessThan(model.descendants(of: "a").count, 3)
    }

    func testASetCycleTerminatesToo() {
        let entries = [record("a", set: "s1", run: "r1"), record("b", set: "s2", run: "r2")]
        let runs = [
            LineageRunRecord(id: "r1", setID: "s1", parentSetID: "s2", tool: "x"),
            LineageRunRecord(id: "r2", setID: "s2", parentSetID: "s1", tool: "x"),
        ]
        let model = LineageModel(entries: entries, runs: runs)
        XCTAssertEqual(model.nodes.count, 2)
    }

    func testAnEmptyFileIsAnEmptyGraphNotACrash() {
        let model = LineageModel(entries: [])
        XCTAssertTrue(model.nodes.isEmpty)
        XCTAssertTrue(model.layers.isEmpty)
        XCTAssertTrue(model.edges.isEmpty)
        XCTAssertTrue(model.descendants(of: "nothing").isEmpty)
        XCTAssertTrue(model.subtree(of: "nothing").isEmpty)
    }

    // MARK: descendants

    func testDescendantsAreEverythingUnderANodeAndNotTheNode() {
        let model = LineageModel(entries: campaign)
        XCTAssertEqual(model.descendants(of: "bb1"), ["s1", "s2", "f1"])
        XCTAssertEqual(model.descendants(of: "bb2"), ["s3", "f2"])
        XCTAssertEqual(model.descendants(of: "f1"), [], "a leaf has none")
        XCTAssertEqual(model.descendants(of: "t").count, 7,
                       "the target's descendants are the whole campaign")
    }

    func testTheSubtreeIncludesTheNodeBecauseThatIsWhatAClickMeans() {
        let model = LineageModel(entries: campaign)
        XCTAssertEqual(model.subtree(of: "bb1"), ["bb1", "s1", "s2", "f1"])
        XCTAssertEqual(model.subtree(of: "f2"), ["f2"])
    }

    func testADiamondIsWalkedOnceNotOncePerPath() {
        // Two sequences off one backbone, both folded into the SAME comparison entry.
        let entries = [
            record("bb", set: "a"),
            record("s1", set: "b", parents: ["bb"]),
            record("s2", set: "b", parents: ["bb"]),
            record("cmp", set: "c", parents: ["s1", "s2"]),
        ]
        let model = LineageModel(entries: entries)
        XCTAssertEqual(model.descendants(of: "bb"), ["s1", "s2", "cmp"])
        XCTAssertEqual(model.nodesByID["cmp"]?.layer, 2)
    }

    // MARK: hollow and size

    func testRejectedAndFailedDrawHollowAndUnknownDoesNot() {
        let entries = [
            record("ok", set: "s"),
            record("no", set: "s", rejected: true),
            record("failed", set: "s"),
            record("elsewhere", set: "other"),
        ]
        // `failed` has the column and no value; `elsewhere` is in a set whose scalars
        // were never read, which is most of the file.
        let metric: [String: Double?] = ["ok": 90, "no": 70, "failed": nil]
        let model = LineageModel(entries: entries, metric: metric)
        let byID = model.nodesByID
        XCTAssertFalse(try XCTUnwrap(byID["ok"]).isHollow)
        XCTAssertTrue(try XCTUnwrap(byID["no"]).isHollow, "rejected is hollow")
        XCTAssertTrue(try XCTUnwrap(byID["failed"]).isHollow,
                      "a declared column with no value is a run that failed")
        XCTAssertFalse(try XCTUnwrap(byID["elsewhere"]).isHollow,
                       "a metric nobody asked for is not a failure")
        XCTAssertTrue(try XCTUnwrap(byID["elsewhere"]).metricUnknown)
        XCTAssertFalse(try XCTUnwrap(byID["failed"]).metricUnknown)
    }

    func testTheNodeSizeIsTheTablesOwnRamp() {
        let column = MetricColumn(key: "plddt", scope: "object", lo: 0, hi: 100,
                                  higherIsBetter: true, column: "plddt")
        let model = LineageModel(entries: [record("a", set: "s"), record("b", set: "s")],
                                 metric: ["a": 90, "b": 10], metricColumn: column)
        let byID = model.nodesByID
        XCTAssertEqual(model.goodness(try XCTUnwrap(byID["a"])), 0.9)
        XCTAssertEqual(model.goodness(try XCTUnwrap(byID["b"])), 0.1)
        // With no column chosen there is nothing to size by, and the dots are plain.
        let plain = LineageModel(entries: [record("a", set: "s")], metric: ["a": 90])
        XCTAssertNil(plain.goodness(try XCTUnwrap(plain.nodesByID["a"])))
    }

    func testALowerIsBetterMetricInvertsTheSizeTheWayTheTableInvertsTheTint() {
        let column = MetricColumn(key: "rmsd", scope: "object", lo: 0, hi: 10,
                                  higherIsBetter: false, column: "rmsd")
        let model = LineageModel(entries: [record("a", set: "s")],
                                 metric: ["a": 0], metricColumn: column)
        XCTAssertEqual(model.goodness(try XCTUnwrap(model.nodesByID["a"])), 1,
                       "an RMSD of zero is the best there is, so it draws largest")
    }
}

// MARK: - Regressions from the #455 review

final class LineageRegressionTests: XCTestCase {

    private func record(_ id: String, set: String, ord: Int = 0,
                        parents: [String] = []) -> LineageEntryRecord {
        LineageEntryRecord(id: id, setID: set, name: id, ord: ord, parents: parents,
                           rejected: false, runID: nil)
    }

    /// An entry that names ITSELF as a parent was placed one column right of itself
    /// and drew a curve from a dot back to the same dot.
    func testASelfParentIsNotAGenerationAndDrawsNoLoop() {
        let model = LineageModel(entries: [record("a", set: "s", parents: ["a"])])
        XCTAssertEqual(model.nodesByID["a"]?.layer, 0, "it descends from nothing")
        XCTAssertTrue(model.edges.isEmpty, "and there is no edge to draw")
        XCTAssertTrue(model.descendants(of: "a").isEmpty)
        XCTAssertEqual(model.subtree(of: "a"), ["a"])
    }

    func testASelfParentBesideARealOneKeepsTheRealOne() {
        let model = LineageModel(entries: [
            record("p", set: "s"),
            record("c", set: "s", parents: ["c", "p"]),
        ])
        XCTAssertEqual(model.nodesByID["c"]?.layer, 1)
        XCTAssertEqual(model.edges, [LineageEdge(from: "p", to: "c")])
    }

    /// The derived state is computed once, in `init`. Recomputing `edges` / `layers` /
    /// `nodesByID` per access cost ~7 ms EACH on 9000 entries, which a `Canvas` pays
    /// per frame. This pins the shape rather than the timing: the same values, from
    /// stored properties.
    func testTheDerivedStateIsConsistentWithTheNodes() {
        let entries = [
            record("t", set: "a"),
            record("b1", set: "b", ord: 0, parents: ["t"]),
            record("b2", set: "b", ord: 1, parents: ["t"]),
            record("f1", set: "c", parents: ["b1"]),
        ]
        let model = LineageModel(entries: entries)
        XCTAssertEqual(model.layerSizes, [1, 2, 1])
        XCTAssertEqual(model.layerSizes.count, model.layers.count)
        XCTAssertEqual(model.layers.map(\.count), model.layerSizes)
        XCTAssertEqual(model.nodesByID.count, model.nodes.count)
        XCTAssertEqual(Set(model.edges), [LineageEdge(from: "t", to: "b1"),
                                          LineageEdge(from: "t", to: "b2"),
                                          LineageEdge(from: "b1", to: "f1")])
    }

    func testAnEmptyGraphHasEmptyDerivedState() {
        let model = LineageModel(entries: [])
        XCTAssertTrue(model.layerSizes.isEmpty)
        XCTAssertTrue(model.edges.isEmpty)
        XCTAssertTrue(model.nodesByID.isEmpty)
        XCTAssertTrue(model.layers.isEmpty)
    }

    /// The cull rect a draw pass uses. It has to be WIDER than the visible slice, or a
    /// curve whose endpoints are both off-screen but whose belly crosses it vanishes.
    func testTheCullRectIsPaddedByAColumn() {
        let visible = CGRect(x: 0, y: 1000, width: 800, height: 400)
        let cull = LineageView.cullRect(visible)
        XCTAssertLessThan(cull.minX, visible.minX)
        XCTAssertGreaterThan(cull.maxX, visible.maxX)
        XCTAssertLessThan(cull.minY, visible.minY)
        XCTAssertGreaterThan(cull.maxY, visible.maxY)
        XCTAssertTrue(cull.contains(visible), "it can only ever draw MORE than asked")
    }

    /// A click whose subtree is entirely in another set used to be a silent no-op —
    /// which `click`'s own comment calls the worst of the three outcomes, and which is
    /// exactly what clicking a backbone does while the fold set is the one open.
    func testAClickThatSelectsNothingSaysWhy() {
        let node = LineageNode(id: "bb1", name: "bb1", setID: "rfd3", layer: 0, row: 0,
                               parents: [], rejected: false, metric: nil)
        let note = LineageView.clickNote(node: node, subtree: ["bb1", "s1", "s2"],
                                         selected: 0)
        XCTAssertTrue(note.contains("bb1"), note)
        XCTAssertTrue(note.contains("another set"), note)
        XCTAssertTrue(note.contains("2 descendants"), note)
        // A lone node names itself and nothing else.
        XCTAssertFalse(LineageView.clickNote(node: node, subtree: ["bb1"], selected: 0)
                        .contains("descendants"))
        // And a click that DID select says nothing — the Table showing the rows is
        // the feedback.
        XCTAssertEqual(LineageView.clickNote(node: node, subtree: ["bb1"], selected: 1), "")
    }
}
