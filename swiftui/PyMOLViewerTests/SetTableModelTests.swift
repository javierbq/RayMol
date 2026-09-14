import SQLite3
import XCTest
@testable import RayMol

/// The Data drawer's Table tab (#417) is thin over `SetTableModel`, and everything
/// the table decides — sort, NULL placement, number format, default direction,
/// colour ramp, budget arithmetic, keyboard navigation, the histogram — is a pure
/// function of a `MetricSpec` and some rows. These pin those decisions without a
/// window. `SetsStoreTests` below reads a real container laid down with the same
/// DDL Python uses, so the column names agree in both readers.
final class SetTableModelTests: XCTestCase {

    // MARK: fixtures

    private let plddt = MetricColumn(key: "plddt", dtype: "float", units: "", label: "pLDDT",
                                     lo: 0, hi: 100, higherIsBetter: true, column: "plddt")
    private let rmsd = MetricColumn(key: "rmsd", dtype: "float", units: "Å", label: "RMSD",
                                    lo: 0, hi: 10, higherIsBetter: false, column: "rmsd")
    private let iptm = MetricColumn(key: "iptm", dtype: "float", lo: 0, hi: 1,
                                    higherIsBetter: true, column: "iptm")
    private let elapsed = MetricColumn(key: "elapsed_s", dtype: "float", units: "s",
                                       label: "elapsed", column: "elapsed_s")
    private let nContacts = MetricColumn(key: "n_contacts", dtype: "int", column: "n_contacts")
    private let passes = MetricColumn(key: "passes", dtype: "bool", column: "passes")
    private let note = MetricColumn(key: "verdict", dtype: "str", column: "verdict")
    private let array = MetricColumn(key: "pae", scope: "pair", dtype: "float", column: nil)

    private func row(_ name: String, ord: Int, plddt: Double? = nil, rmsd: Double? = nil,
                     staged: Bool = false, pinned: Bool = false, starred: Bool = false,
                     rejected: Bool = false) -> SetRow {
        var values: [String: MetricValue] = [:]
        values["plddt"] = plddt.map { .number($0) } ?? .null
        values["rmsd"] = rmsd.map { .number($0) } ?? .null
        return SetRow(id: "id_\(name)", name: name, ord: ord, starred: starred,
                      rejected: rejected, pinned: pinned,
                      stagedObject: staged ? name : nil, nChains: 1, nResidues: 70,
                      tags: "", runID: nil, values: values)
    }

    private var rows: [SetRow] {
        [
            row("d_0001", ord: 1, plddt: 80.0, rmsd: 1.5),
            row("d_0002", ord: 2, plddt: 95.0, rmsd: 0.9),
            row("d_0003", ord: 3, plddt: nil, rmsd: 2.0),      // unmeasured pLDDT
            row("d_0004", ord: 4, plddt: 95.0, rmsd: 1.1),     // ties d_0002 on pLDDT
            row("d_0005", ord: 5, plddt: 60.0, rmsd: nil),
        ]
    }

    // MARK: columns

    func testArrayScopeColumnsHaveNoCell() {
        let model = SetTableModel(columns: [plddt, array, rmsd], rows: [])
        XCTAssertEqual(model.columns.map(\.key), ["plddt", "rmsd"],
                       "a residue/pair array has no scalar column and so no table cell")
    }

    // MARK: sort

    func testDeliveryOrderByDefault() {
        let shuffled = Array(rows.reversed())
        let model = SetTableModel(columns: [plddt], rows: shuffled)
        XCTAssertEqual(model.sorted.map(\.ord), [1, 2, 3, 4, 5])
    }

    func testDescendingPutsBestFirstNullsLastTiesByDelivery() {
        let model = SetTableModel(columns: [plddt, rmsd], rows: rows,
                                  sortKey: "plddt", sortDescending: true)
        XCTAssertEqual(model.sorted.map(\.name),
                       ["d_0002", "d_0004", "d_0001", "d_0005", "d_0003"],
                       "95,95 (tie → ord), 80, 60, then the unmeasured entry")
    }

    func testAscendingStillPutsNullsLast() {
        // An unmeasured entry is not "the worst": it goes last both ways.
        let model = SetTableModel(columns: [plddt, rmsd], rows: rows,
                                  sortKey: "plddt", sortDescending: false)
        XCTAssertEqual(model.sorted.map(\.name),
                       ["d_0005", "d_0001", "d_0002", "d_0004", "d_0003"])
    }

    func testSortByNameAndByUnknownKey() {
        let byName = SetTableModel(columns: [plddt], rows: rows, sortKey: "name",
                                   sortDescending: true)
        XCTAssertEqual(byName.sorted.first?.name, "d_0005")
        // A stale sort key (its column was never declared in this file) falls back
        // to delivery order rather than producing nothing.
        let stale = SetTableModel(columns: [plddt], rows: rows, sortKey: "ghost",
                                  sortDescending: true)
        XCTAssertEqual(stale.sorted.map(\.ord), [1, 2, 3, 4, 5])
    }

    func testDefaultDirectionFollowsHigherIsBetter() {
        XCTAssertTrue(SetTableModel.defaultDescending(plddt), "higher is better → best on top")
        XCTAssertFalse(SetTableModel.defaultDescending(rmsd), "lower is better → ascending")
        XCTAssertTrue(SetTableModel.defaultDescending(elapsed),
                      "neither → descending, the large values are what one looks for")
    }

    func testHeaderClickAppliesDefaultThenFlips() {
        let model = SetTableModel(columns: [plddt, rmsd], rows: rows,
                                  sortKey: "plddt", sortDescending: true)
        let first = model.toggledSort("rmsd")
        XCTAssertEqual(first.key, "rmsd")
        XCTAssertFalse(first.descending, "first click on an RMSD column sorts ascending")
        let again = model.toggledSort("plddt")
        XCTAssertEqual(again.key, "plddt")
        XCTAssertFalse(again.descending, "second click on the active column flips it")
    }

    func testNumbersSortBeforeText() {
        XCTAssertEqual(SetTableModel.compare(.number(1), .text("a")), .orderedAscending)
        XCTAssertEqual(SetTableModel.compare(.text("b"), .text("a")), .orderedDescending)
        XCTAssertEqual(SetTableModel.compare(.number(2), .number(2)), .orderedSame)
    }

    // MARK: format

    func testDecimalsComeFromTheDeclaredDomain() {
        XCTAssertEqual(SetTableModel.format(.number(91.234), plddt), "91.2", "0–100 → one decimal")
        XCTAssertEqual(SetTableModel.format(.number(1.1), rmsd), "1.10", "0–10 → two")
        XCTAssertEqual(SetTableModel.format(.number(0.84), iptm), "0.840", "0–1 → three")
    }

    func testNoDomainUsesThreeSignificantFigures() {
        XCTAssertEqual(SetTableModel.format(.number(14.1234), elapsed), "14.1")
        XCTAssertEqual(SetTableModel.format(.number(0.0123456), elapsed), "0.0123")
        XCTAssertEqual(SetTableModel.format(.number(12345), elapsed), "1.23e+04")
    }

    func testIntBoolTextAndNull() {
        XCTAssertEqual(SetTableModel.format(.number(42), nContacts), "42")
        XCTAssertEqual(SetTableModel.format(.number(1), passes), "yes")
        XCTAssertEqual(SetTableModel.format(.number(0), passes), "no")
        XCTAssertEqual(SetTableModel.format(.text("keep"), note), "keep")
        XCTAssertEqual(SetTableModel.format(.null, plddt), "–",
                       "absent is visibly absent, not a zero and not blank")
    }

    func testHeaderCarriesUnitsAndChain() {
        XCTAssertEqual(SetTableModel.header(rmsd), "RMSD (Å)")
        XCTAssertEqual(SetTableModel.header(plddt), "pLDDT")
        let chainScalar = MetricColumn(key: "plddt", label: "pLDDT", chain: "B", column: "plddt__b")
        XCTAssertEqual(SetTableModel.header(chainScalar), "pLDDT/B")
    }

    // MARK: colour ramp

    func testRampIsPositionInDomainClamped() {
        XCTAssertEqual(SetTableModel.rampFraction(.number(50), plddt)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(SetTableModel.rampFraction(.number(150), plddt)!, 1, accuracy: 1e-9)
        XCTAssertEqual(SetTableModel.rampFraction(.number(-3), plddt)!, 0, accuracy: 1e-9)
        XCTAssertNil(SetTableModel.rampFraction(.number(5), elapsed), "no domain → no ramp")
        XCTAssertNil(SetTableModel.rampFraction(.null, plddt))
        XCTAssertNil(SetTableModel.rampFraction(.text("x"), note))
    }

    func testGoodnessIsOrientedAndUndefinedForNeither() {
        XCTAssertEqual(SetTableModel.goodness(.number(90), plddt)!, 0.9, accuracy: 1e-9)
        XCTAssertEqual(SetTableModel.goodness(.number(1), rmsd)!, 0.9, accuracy: 1e-9,
                       "an RMSD of 1 Å on a 0–10 domain is 90% good")
        XCTAssertNil(SetTableModel.goodness(.number(5), elapsed),
                     "an elapsed time has no good end; the cell stays untinted")
    }

    // MARK: budget

    func testBudgetArithmetic() {
        let model = SetTableModel(columns: [], rows: rows, budget: 6, stagedCount: 4)
        XCTAssertEqual(model.budgetRemaining, 2)
        XCTAssertTrue(model.canStage(2))
        XCTAssertFalse(model.canStage(3))
        XCTAssertFalse(model.canStage(0))
        XCTAssertFalse(model.isOverBudget)
        XCTAssertEqual(model.budgetLabel, "4 of 5 staged · budget 6")
    }

    func testOverBudgetClampsRemainingToZero() {
        // A budget lowered under what is already staged: the panel says so and
        // refuses more, but never reports a negative remainder.
        let model = SetTableModel(columns: [], rows: rows, budget: 2, stagedCount: 4)
        XCTAssertEqual(model.budgetRemaining, 0)
        XCTAssertTrue(model.isOverBudget)
        XCTAssertFalse(model.canStage(1))
    }

    // MARK: stage glyph

    func testStageGlyphs() {
        let staged = row("a", ord: 1, staged: true)
        let plain = row("b", ord: 2)
        XCTAssertEqual(SetTableModel.stageGlyph(staged, peekedID: nil), "●")
        XCTAssertEqual(SetTableModel.stageGlyph(plain, peekedID: nil), "○")
        XCTAssertEqual(SetTableModel.stageGlyph(plain, peekedID: plain.id), "◐")
        XCTAssertEqual(SetTableModel.stageGlyph(staged, peekedID: staged.id), "●",
                       "a staged entry is drawn for real; the peek glyph would lie")
    }

    // MARK: keyboard navigation

    func testNeighborWalksTheSortedOrderAndClamps() {
        let model = SetTableModel(columns: [plddt], rows: rows, sortKey: "plddt",
                                  sortDescending: true)
        // sorted: d_0002, d_0004, d_0001, d_0005, d_0003
        XCTAssertEqual(model.neighbor(of: nil, step: 1)?.name, "d_0002", "↓ from nothing → top")
        XCTAssertEqual(model.neighbor(of: nil, step: -1)?.name, "d_0003", "↑ from nothing → bottom")
        XCTAssertEqual(model.neighbor(of: "id_d_0004", step: 1)?.name, "d_0001")
        XCTAssertEqual(model.neighbor(of: "id_d_0004", step: -1)?.name, "d_0002")
        XCTAssertEqual(model.neighbor(of: "id_d_0002", step: -1)?.name, "d_0002", "clamped at the top")
        XCTAssertEqual(model.neighbor(of: "id_d_0003", step: 1)?.name, "d_0003", "clamped at the bottom")
        XCTAssertNil(SetTableModel(columns: [], rows: []).neighbor(of: nil, step: 1))
    }

    // MARK: histogram

    func testHistogramBinsOverTheDeclaredDomain() {
        let bins = SetTableModel.histogram(values: [0, 5, 50, 95, 100, 120], bins: 10, lo: 0, hi: 100)
        XCTAssertEqual(bins.count, 10)
        XCTAssertEqual(bins[0], 2, "0 and 5 land in the first bin")
        XCTAssertEqual(bins[5], 1)
        XCTAssertEqual(bins[9], 3, "95, 100 (the top edge) and 120 (clamped) share the last bin")
        XCTAssertEqual(bins.reduce(0, +), 6)
    }

    func testHistogramWithoutDomainUsesObservedRange() {
        let bins = SetTableModel.histogram(values: [10, 20, 30], bins: 3, lo: nil, hi: nil)
        XCTAssertEqual(bins, [1, 1, 1])
    }

    func testHistogramDegenerateInputs() {
        XCTAssertEqual(SetTableModel.histogram(values: [], bins: 12, lo: 0, hi: 1), [])
        XCTAssertEqual(SetTableModel.histogram(values: [.nan], bins: 12, lo: 0, hi: 1), [])
        XCTAssertEqual(SetTableModel.histogram(values: [7, 7, 7], bins: 5, lo: nil, hi: nil),
                       [0, 0, 3, 0, 0], "all equal → one full middle bin, not a crash")
    }
}

/// The read-only reader against a container laid down with format-version-1 DDL —
/// the same statements `modules/pymol/sets/schema.py` runs, so a column renamed
/// there and not here fails HERE, in a test, rather than as an empty drawer.
final class SetsStoreTests: XCTestCase {

    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "setsstore_\(UUID().uuidString.prefix(8)).raymol"
        try Self.layDownContainer(at: path)
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    func testMissingFileOpensAsNil() {
        XCTAssertNil(SetsStore(path: NSTemporaryDirectory() + "does_not_exist_\(UUID()).raymol"))
    }

    func testNotAContainerReadsEmpty() throws {
        let junk = NSTemporaryDirectory() + "junk_\(UUID().uuidString.prefix(8)).raymol"
        try Data("hello".utf8).write(to: URL(fileURLWithPath: junk))
        defer { try? FileManager.default.removeItem(atPath: junk) }
        // Opening succeeds lazily; every query then reports nothing.
        let store = SetsStore(path: junk)
        XCTAssertNil(store?.version())
        XCTAssertEqual(store?.sets() ?? [], [])
    }

    func testReadsVersionSetsAndRows() throws {
        let store = try XCTUnwrap(SetsStore(path: path))
        XCTAssertEqual(store.version(), 7)
        XCTAssertEqual(store.defaultStageBudget(), 4, "meta.stage_budget wins over the default")

        let sets = store.sets(running: ["ab12cd34": BatchProgress(done: 3, total: 10, tool: "rfd3")])
        XCTAssertEqual(sets.count, 1)
        let set = try XCTUnwrap(sets.first)
        XCTAssertEqual(set.id, "ab12cd34")
        XCTAssertEqual(set.name, "rfd3_a1")
        XCTAssertEqual(set.groupName, "rfd3_a1")
        XCTAssertEqual(set.count, 3)
        XCTAssertEqual(set.stagedCount, 1)
        XCTAssertEqual(set.budget, 4, "no per-set budget → the file's default")
        XCTAssertEqual(set.rankingKey, "plddt")
        XCTAssertEqual(set.sortKey, "plddt")
        XCTAssertTrue(set.sortDescending)
        XCTAssertEqual(set.running, BatchProgress(done: 3, total: 10, tool: "rfd3"))
        XCTAssertEqual(set.columns.map(\.key), ["plddt", "rmsd", "pae"])
        XCTAssertEqual(set.columns.filter(\.isScalar).map(\.column), ["plddt", "rmsd__b"],
                       "the array column has no cell; the chain scalar is key__chain")
        XCTAssertEqual(set.columns[0].higherIsBetter, true)
        XCTAssertEqual(set.columns[1].higherIsBetter, false)
        XCTAssertEqual(set.columns[1].units, "A")
        XCTAssertEqual(set.histogram.count, SetsStore.histogramBins)
        XCTAssertEqual(set.histogram.reduce(0, +), 2, "two entries have a pLDDT; one is NULL")

        let rows = store.rows(setID: set.id, columns: set.columns)
        XCTAssertEqual(rows.map(\.name), ["d_0001", "d_0002", "d_0003"], "delivery order")
        XCTAssertEqual(rows[0].values["plddt"], .number(91.5))
        XCTAssertEqual(rows[0].values["rmsd__b"], .number(1.25))
        XCTAssertEqual(rows[2].values["plddt"], .null, "an unmeasured entry reads as NULL")
        XCTAssertTrue(rows[1].isStaged)
        XCTAssertEqual(rows[1].stagedObject, "d_0002")
        XCTAssertTrue(rows[1].pinned)
        XCTAssertTrue(rows[0].starred)
        XCTAssertTrue(rows[2].rejected)
        XCTAssertEqual(rows[0].nResidues, 72)
        XCTAssertEqual(rows[0].tags, "hydrophobic-patch")
    }

    func testUnsafeIdentifiersNeverReachSQL() {
        XCTAssertTrue(SetsStore.isSafeIdentifier("plddt__b"))
        XCTAssertTrue(SetsStore.isSafeIdentifier("ab12cd34"))
        XCTAssertFalse(SetsStore.isSafeIdentifier(""))
        XCTAssertFalse(SetsStore.isSafeIdentifier("m\"; DROP TABLE sets; --"))
        XCTAssertFalse(SetsStore.isSafeIdentifier("plddt/B"))
        XCTAssertFalse(SetsStore.isSafeIdentifier("_leading"))
        let store = SetsStore(path: path)
        XCTAssertEqual(store?.rows(setID: "x\"y", columns: []) ?? [], [])
    }

    func testMetricColumnDecodeTolerantOfMissingFields() throws {
        let json = #"[{"key":"plddt"},{"key":"x","column":"x","higher_is_better":null,"lo":null}]"#
        let columns = SetsStore.decodeColumns(json)
        XCTAssertEqual(columns.count, 2)
        XCTAssertEqual(columns[0].label, "plddt", "label defaults to the key")
        XCTAssertNil(columns[0].column)
        XCTAssertNil(columns[1].higherIsBetter)
        XCTAssertEqual(SetsStore.decodeColumns("not json"), [])
    }

    // MARK: fixture

    /// Format version 1, the columns the reader names, one set with three entries.
    /// WAL mode, like the real file, so the reader is exercised against a `-wal`.
    private static func layDownContainer(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("could not create a scratch database")
        }
        defer { sqlite3_close(db) }
        let statements = [
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            """
            CREATE TABLE sets (
              id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL,
              created REAL NOT NULL, tool TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
              group_name TEXT NOT NULL, budget INTEGER, ranking_key TEXT NOT NULL DEFAULT '',
              sort_key TEXT NOT NULL DEFAULT '', sort_desc INTEGER NOT NULL DEFAULT 1,
              filter TEXT NOT NULL DEFAULT '', columns TEXT NOT NULL DEFAULT '[]',
              reference TEXT NOT NULL DEFAULT '')
            """,
            """
            CREATE TABLE entries (
              id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
              ord INTEGER NOT NULL, name TEXT NOT NULL, run_id TEXT, created REAL NOT NULL,
              sequences TEXT NOT NULL DEFAULT '{}', n_chains INTEGER NOT NULL DEFAULT 0,
              n_residues INTEGER NOT NULL DEFAULT 0, parents TEXT NOT NULL DEFAULT '[]',
              starred INTEGER NOT NULL DEFAULT 0, rejected INTEGER NOT NULL DEFAULT 0,
              tags TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
              staged_object TEXT, pinned INTEGER NOT NULL DEFAULT 0, UNIQUE (set_id, name))
            """,
            """
            CREATE TABLE "m_ab12cd34" (
              entry_id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE,
              "plddt" REAL, "rmsd__b" REAL)
            """,
            "INSERT INTO meta VALUES ('format_version','1'),('version','7'),('stage_budget','4')",
            """
            INSERT INTO sets (id, name, kind, created, tool, group_name, ranking_key, sort_key,
                              sort_desc, columns)
            VALUES ('ab12cd34', 'rfd3_a1', 'structures', 1.0, 'rfd3', 'rfd3_a1', 'plddt', 'plddt', 1,
              '[{"key":"plddt","scope":"object","dtype":"float","units":"","label":"pLDDT",
                 "lo":0.0,"hi":100.0,"higher_is_better":true,"summarizes":"","description":"",
                 "chain":null,"tool":"rfd3","column":"plddt"},
                {"key":"rmsd","scope":"chain","dtype":"float","units":"A","label":"RMSD",
                 "lo":0.0,"hi":10.0,"higher_is_better":false,"summarizes":"","description":"",
                 "chain":"B","tool":"rfd3","column":"rmsd__b"},
                {"key":"pae","scope":"pair","dtype":"float","units":"A","label":"PAE",
                 "lo":0.0,"hi":31.75,"higher_is_better":false,"summarizes":"","description":"",
                 "chain":null,"tool":"rfd3","column":null}]')
            """,
            """
            INSERT INTO entries (id, set_id, ord, name, created, n_chains, n_residues, starred,
                                 rejected, tags, staged_object, pinned)
            VALUES ('e1', 'ab12cd34', 1, 'd_0001', 1.0, 2, 72, 1, 0, 'hydrophobic-patch', NULL, 0),
                   ('e2', 'ab12cd34', 2, 'd_0002', 1.0, 2, 68, 0, 0, '', 'd_0002', 1),
                   ('e3', 'ab12cd34', 3, 'd_0003', 1.0, 2, 75, 0, 1, '', NULL, 0)
            """,
            """
            INSERT INTO "m_ab12cd34" VALUES ('e1', 91.5, 1.25), ('e2', 89.7, 0.9), ('e3', NULL, 1.4)
            """,
        ]
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "?"
                sqlite3_free(err)
                XCTFail("fixture SQL failed: \(message)\n\(sql)")
                return
            }
        }
    }
}
