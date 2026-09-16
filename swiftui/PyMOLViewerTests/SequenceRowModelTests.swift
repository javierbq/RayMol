// SequenceRowModelTests.swift — the Sequences tab's decisions (#419).
//
// Four things are pinned here, and each is a decision the spec leaves to the
// implementation, which is exactly the kind that rots without a test:
//
//   * `SequenceArrayTests` — the CROSS-LANGUAGE round trip. Python wrote known values
//     through `pymol.sets.blobs.encode_f32` into a committed container; this reads the
//     same file with `SetsStore` and asserts the exact floats. The two expectation
//     lists are deliberately separate copies, one per language: a shared constant
//     would let both sides drift together.
//   * `SequenceLazyLoadTests` — a thousand-entry set draws the tab without reading a
//     thousand blobs (#421). Asserted on a counter, not on a stopwatch.
//   * `SequenceRowModelTests` — alignment by shared parent, the collapse threshold,
//     the consensus band, and the mapping of an array onto a row's cells.
//   * `SequenceStripMigrationTests` — what a user who had the strip open sees on the
//     first launch after it moved (#419 decision 3), and what one who had it closed
//     sees, which is nothing.

import XCTest
import SQLite3
@testable import RayMol

// MARK: - Cross-language: the committed fixture

/// The container `TestSwiftResidueArrayFixture` in `testing/tests/test_appkit_sets.py`
/// writes. Regenerate with `RAYMOL_WRITE_SWIFT_FIXTURE=1` on that suite; the Python
/// test fails if the committed file stops matching what `pymol.sets.blobs` produces,
/// and this one fails if Swift stops reading what Python wrote.
final class SequenceArrayTests: XCTestCase {

    /// Located from `#filePath` rather than a test-bundle resource: a resource would
    /// need four more `.pbxproj` entries and a copy phase to assert the same thing,
    /// and the file is only ever read.
    private static var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/residue_arrays.raymol")
            .path
    }

    /// A COPY, in a temp dir. The fixture is committed, a checkout may be read-only,
    /// and SQLite wants to be able to write beside a file it opens even when it does
    /// not (the Python side takes it out of WAL for the same reason).
    private func openFixture() throws -> (SetsStore, URL) {
        let source = Self.fixturePath
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing at \(source); regenerate it with"
                          + " RAYMOL_WRITE_SWIFT_FIXTURE=1 on test_appkit_sets.py")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol419-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("residue_arrays.raymol")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        guard let store = SetsStore(path: copy.path) else {
            throw XCTSkip("could not open the fixture copy")
        }
        return (store, dir)
    }

    /// Entry ids are generated, so the fixture's are found by name.
    private func ids(_ store: SetsStore) -> [String: String] {
        var out: [String: String] = [:]
        for record in store.lineageEntries() { out[record.name] = record.id }
        return out
    }

    func testTheExactFloatsPythonWroteComeBack() throws {
        let (store, dir) = try openFixture()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        let ids = self.ids(store)
        let parent = try XCTUnwrap(ids["p_0001"])
        let details = store.entryDetails(entryIDs: [parent])
        let detail = try XCTUnwrap(details[parent])

        // The multi-chain whole-entry array. The index is what lines the strip up
        // under a two-chain row, so it is asserted as well as the values.
        let plddt = try XCTUnwrap(detail.arrays("plddt").first)
        XCTAssertEqual(plddt.chain, nil, "a whole-entry array has no chain")
        XCTAssertEqual(plddt.index.map(\.chain), ["A", "A", "A", "B", "B"])
        XCTAssertEqual(plddt.index.map(\.resi), ["1", "2", "3", "10", "11"])
        // EQUALITY, not an epsilon: every value in the fixture is exactly
        // representable as a float32, so a tolerance here would hide a real decode
        // bug — a byte-swapped read of 91.5 is not 91.5 ± anything, but a subtly
        // wrong scale might be.
        XCTAssertEqual(plddt.values[0], 91.5)
        XCTAssertEqual(plddt.values[1], 88.25)
        XCTAssertNil(plddt.values[2], "None went in as NaN and must come back absent,"
                     + " not as 0.0 — an unmeasured residue is not a residue that"
                     + " scored zero")
        XCTAssertEqual(plddt.values[3], 70.0)
        XCTAssertEqual(plddt.values[4], 42.125)

        // The per-chain array beside it: the reader has to key by chain NAME, not by
        // the order it met the two arrays.
        let nativeFit = try XCTUnwrap(detail.arrays("native_fit").first)
        XCTAssertEqual(nativeFit.chain, "A")
        XCTAssertEqual(nativeFit.index.map(\.resi), ["1", "2", "3"])
        XCTAssertEqual(nativeFit.values, [-1.5, -0.25, -6.0])

        let certainty = try XCTUnwrap(detail.arrays("certainty").first)
        XCTAssertEqual(certainty.values[0], 0.0, "a real zero is not an absent value")
        XCTAssertEqual(certainty.values[1], 0.5)
        XCTAssertEqual(certainty.values[2], 1.0)
        XCTAssertNil(certainty.values[3])
        XCTAssertEqual(certainty.values[4], 0.25)

        XCTAssertEqual(detail.sequences, ["A": "MKV", "B": "GG"])
    }

    func testTheChildCarriesTheParentLinkLineageReads() throws {
        let (store, dir) = try openFixture()
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        let ids = self.ids(store)
        let parent = try XCTUnwrap(ids["p_0001"])
        let child = try XCTUnwrap(ids["c_0001"])
        let records = store.lineageEntries()
        let childRecord = try XCTUnwrap(records.first { $0.id == child })
        XCTAssertEqual(childRecord.parents, [parent])
        let model = LineageModel(entries: records)
        XCTAssertEqual(model.descendants(of: parent), [child])
        XCTAssertEqual(model.nodesByID[parent]?.layer, 0)
        XCTAssertEqual(model.nodesByID[child]?.layer, 1,
                       "a child draws one column right of its parent")
    }

    /// The decoder's refusals, which are the reason a wrong strip cannot be drawn.
    func testAShortBlobIsRefusedRatherThanTruncated() {
        // Four bytes = one float, claimed as two. Returning one value would put every
        // later residue's confidence under the wrong residue.
        XCTAssertNil(SetsStore.decodeF32([0, 0, 0, 0], count: 2))
        XCTAssertNil(SetsStore.decodeF32([0, 0, 0, 0, 0], count: 1))
        XCTAssertEqual(SetsStore.decodeF32([], count: 0) ?? [1], [])
        // Little-endian: 0x3F800000 is 1.0 and arrives least significant byte first.
        XCTAssertEqual(SetsStore.decodeF32([0x00, 0x00, 0x80, 0x3F], count: 1) ?? [],
                       [1.0])
        // A NaN payload is absent, whichever NaN it is.
        let nan: [Double?] = SetsStore.decodeF32([0x01, 0x00, 0xC0, 0x7F], count: 1) ?? []
        XCTAssertEqual(nan.count, 1)
        let first: Double? = nan.isEmpty ? 0 : nan[0]
        XCTAssertNil(first)
    }

    func testAMalformedIndexDropsTheStripRatherThanMisalignIt() {
        XCTAssertEqual(SetsStore.decodeResidueIndex("not json").count, 0)
        XCTAssertEqual(SetsStore.decodeResidueIndex("[[\"A\"]]").count, 0,
                       "a pair short of a chain and a resi is not an index entry")
        let good = SetsStore.decodeResidueIndex("[[\"A\",\"1\"],[\"B\",\"12\"]]")
        XCTAssertEqual(good.map(\.chain), ["A", "B"])
        XCTAssertEqual(good.map(\.resi), ["1", "12"])
    }

    func testSequencesDecodeAsAChainMap() {
        XCTAssertEqual(SetsStore.decodeSequences(#"{"A":"MKV","B":"GG"}"#),
                       ["A": "MKV", "B": "GG"])
        XCTAssertEqual(SetsStore.decodeSequences("{}"), [:])
        XCTAssertEqual(SetsStore.decodeSequences("["), [:])
    }
}

// MARK: - Lazy loading

/// #421, non-negotiable: "residue arrays load on demand for the Sequences tab". A set
/// of a thousand entries must not read a thousand blobs to draw a tab.
///
/// Asserted on `SetsStore.arrayBlobReads`, which counts blobs the connection actually
/// pulled. A timing assertion would pass on a fast machine with the bug in it.
final class SequenceLazyLoadTests: XCTestCase {

    private var dir: URL!
    private var path: String!
    private static let entryCount = 1000

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol419-lazy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("big.raymol").path
        try Self.layDownContainer(at: path, entries: Self.entryCount)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testDrawingTheTabReadsOnlyTheRowsOnScreen() throws {
        let store = try XCTUnwrap(SetsStore(path: path))
        defer { store.close() }
        let ids = store.lineageEntries().map(\.id)
        XCTAssertEqual(ids.count, Self.entryCount)
        XCTAssertEqual(store.arrayBlobReads, 0, "listing entries reads no blobs at all")

        // The first screenful: one row's `onAppear`, expanded by the look-ahead.
        let window = SetsStore.sequenceWindow(around: ids[0], in: ids)
        XCTAssertEqual(window.count, SetsStore.sequenceLookAhead + 1,
                       "at the top of the list the window is clamped, not wrapped")
        let details = store.entryDetails(entryIDs: window)
        XCTAssertEqual(details.count, window.count)
        // One residue array per entry in this fixture.
        XCTAssertEqual(store.arrayBlobReads, window.count)
        XCTAssertLessThan(store.arrayBlobReads, Self.entryCount / 10,
                          "drawing the tab must not cost the whole set")

        // Scroll to the middle: one more window, not the file.
        let before = store.arrayBlobReads
        let mid = SetsStore.sequenceWindow(around: ids[500], in: ids)
        XCTAssertEqual(mid.count, 2 * SetsStore.sequenceLookAhead + 1)
        _ = store.entryDetails(entryIDs: mid)
        XCTAssertEqual(store.arrayBlobReads - before, mid.count)

        // And the values are real, not a placeholder the cheapness bought.
        let one = try XCTUnwrap(details[ids[0]])
        XCTAssertEqual(one.arrays("plddt").first?.values.count, 3)
        XCTAssertEqual(one.sequences["A"], "MKV")
    }

    func testAnEmptyRequestCostsNothing() throws {
        let store = try XCTUnwrap(SetsStore(path: path))
        defer { store.close() }
        XCTAssertEqual(store.entryDetails(entryIDs: []).count, 0)
        XCTAssertEqual(store.entryDetails(entryIDs: [""]).count, 0)
        XCTAssertEqual(store.arrayBlobReads, 0)
    }

    func testTheWindowIsClampedAtBothEnds() {
        let order = (0..<5).map { "e\($0)" }
        XCTAssertEqual(SetsStore.sequenceWindow(around: "e0", in: order, lookAhead: 2),
                       ["e0", "e1", "e2"])
        XCTAssertEqual(SetsStore.sequenceWindow(around: "e4", in: order, lookAhead: 2),
                       ["e2", "e3", "e4"])
        XCTAssertEqual(SetsStore.sequenceWindow(around: "e2", in: order, lookAhead: 1),
                       ["e1", "e2", "e3"])
        // A row that is not in the order at all (a delivery that landed between the
        // render and the appear) asks for itself and nothing else.
        XCTAssertEqual(SetsStore.sequenceWindow(around: "gone", in: order), ["gone"])
        XCTAssertEqual(SetsStore.sequenceWindow(around: "e0", in: []), ["e0"])
    }

    /// A container with `entries` rows, each with one three-value residue array.
    /// Written with raw SQL rather than through Python: this test is about the
    /// READ side's cost, and the shape of the schema is already pinned by
    /// `TestSchemaContract` on the Python side and by the fixture above.
    ///
    /// `encoding` is a knob for the allowlist test — everything but `f32` must be
    /// refused rather than decoded as if it were f32.
    static func layDownContainer(at path: String, entries: Int, setID: String = "s1",
                                 encoding: String = "f32") throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("could not create a scratch database")
        }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "?"
                sqlite3_free(err)
                throw NSError(domain: "fixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(message): \(sql)"])
            }
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try exec("""
            CREATE TABLE entries (
              id TEXT PRIMARY KEY, set_id TEXT NOT NULL, ord INTEGER NOT NULL,
              name TEXT NOT NULL, run_id TEXT, created REAL NOT NULL,
              sequences TEXT NOT NULL DEFAULT '{}', n_chains INTEGER NOT NULL DEFAULT 0,
              n_residues INTEGER NOT NULL DEFAULT 0, parents TEXT NOT NULL DEFAULT '[]',
              starred INTEGER NOT NULL DEFAULT 0, rejected INTEGER NOT NULL DEFAULT 0,
              tags TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
              staged_object TEXT, pinned INTEGER NOT NULL DEFAULT 0)
            """)
        try exec("""
            CREATE TABLE arrays (
              entry_id TEXT NOT NULL, key TEXT NOT NULL, scope TEXT NOT NULL,
              chain TEXT, blob TEXT NOT NULL, encoding TEXT NOT NULL,
              scale REAL, offset REAL, index_json TEXT NOT NULL,
              PRIMARY KEY (entry_id, key, chain))
            """)
        try exec("""
            CREATE TABLE blobs (hash TEXT PRIMARY KEY, kind TEXT NOT NULL,
              bytes BLOB NOT NULL, size INTEGER NOT NULL, refs INTEGER NOT NULL DEFAULT 0)
            """)
        try exec("CREATE TABLE runs (id TEXT PRIMARY KEY, set_id TEXT NOT NULL,"
                 + " tool TEXT NOT NULL, tool_version TEXT NOT NULL DEFAULT '',"
                 + " created REAL NOT NULL, inputs TEXT NOT NULL DEFAULT '{}',"
                 + " parent_set_id TEXT, note TEXT NOT NULL DEFAULT '')")
        // 90.0, 80.0, 70.0 as little-endian float32, one blob PER ENTRY so the read
        // count is the entry count and content addressing cannot flatter the test.
        try exec("BEGIN")
        for i in 0..<entries {
            let id = "e\(i)"
            try exec("""
                INSERT INTO entries (id, set_id, ord, name, created, sequences,
                                     n_chains, n_residues)
                VALUES ('\(id)', '\(setID)', \(i), 'd_\(i)', 1.0, '{"A":"MKV"}', 1, 3)
                """)
            // The three floats, with the entry index folded into the last byte of the
            // third so every blob hashes differently.
            let last = String(format: "%02X", i % 256)
            try exec("INSERT INTO blobs (hash, kind, bytes, size, refs) VALUES"
                     + " ('h\(id)', '\(encoding)', X'0000B4420000A0420000\(last)42', 12, 1)")
            try exec("""
                INSERT INTO arrays (entry_id, key, scope, chain, blob, encoding, index_json)
                VALUES ('\(id)', 'plddt', 'residue', NULL, 'h\(id)', '\(encoding)',
                        '[["A","1"],["A","2"],["A","3"]]')
                """)
        }
        try exec("COMMIT")
    }
}

// MARK: - The layout, the threshold and the band

final class SequenceRowModelTests: XCTestCase {

    private func make(_ name: String, _ sequences: [String: String],
                       parents: [String] = [], run: String? = nil,
                       ord: Int = 0) -> SequenceEntryInput {
        SequenceEntryInput(id: name, name: name, ord: ord, sequences: sequences,
                           parents: parents, runID: run)
    }

    private func letters(_ row: SequenceEntryRow) -> String {
        row.cells.map { $0.isBreak ? "|" : $0.letter }.joined()
    }

    // MARK: alignment by parent

    func testRowsOfOneParentSharePaddingSoAColumnIsAPosition() {
        // Eight sequences off one backbone is the case this exists for; three will do.
        // One is a residue short, which is what makes the padding observable.
        let model = SequenceRowModel(entries: [
            make("s1", ["A": "MKVLA"], parents: ["bb1"]),
            make("s2", ["A": "MRVLA"], parents: ["bb1"]),
            make("s3", ["A": "MKVL"], parents: ["bb1"]),
        ])
        XCTAssertEqual(model.rows.map { self.letters($0) }, ["MKVLA", "MRVLA", "MKVL-"])
        XCTAssertEqual(Set(model.rows.map(\.cells.count)).count, 1,
                       "every row of a group has the same number of columns")
        // Column 4 means "position 4" on all three, which is the whole point.
        XCTAssertEqual(model.rows.map { $0.cells[4].letter }, ["A", "A", "-"])
        XCTAssertFalse(model.rows[2].cells[4].isResidue,
                       "the pad is a gap, and a gap is not selectable or measurable")
    }

    func testTwoParentsAreTwoColumnSpaces() {
        // Rows of different backbones are not being compared position by position, so
        // they are not padded against each other: a 5-residue design does not get 40
        // columns of gap because something else in the set is 45 long.
        let model = SequenceRowModel(entries: [
            make("a1", ["A": "MKV"], parents: ["bb1"]),
            make("b1", ["A": "MKVLAQ"], parents: ["bb2"]),
        ])
        XCTAssertEqual(model.rows[0].cells.count, 3)
        XCTAssertEqual(model.rows[1].cells.count, 6)
        XCTAssertEqual(model.rows[0].groupKey, "bb1")
        XCTAssertEqual(model.rows[1].groupKey, "bb2")
    }

    func testAChainOneRowLacksIsARunOfGaps() {
        // A binder whose target chain was not written still lines its OWN chain up
        // under the rows that have both, rather than sliding left by the target's
        // length — which is the bug this shape prevents.
        let model = SequenceRowModel(entries: [
            make("with", ["A": "MKV", "B": "GG"], parents: ["bb1"]),
            make("without", ["B": "GG"], parents: ["bb1"]),
        ])
        XCTAssertEqual(letters(model.rows[0]), "MKV|GG")
        XCTAssertEqual(letters(model.rows[1]), "---|GG")
        XCTAssertEqual(model.rows[0].cells.count, model.rows[1].cells.count)
    }

    func testChainsAreOrderedTheSameWayOnEveryRow() {
        // The store writes `sequences` as a JSON object and a dictionary has no order.
        // Two rows disagreeing about which chain comes first would be a silent
        // mis-alignment, so the order is sorted and not first-seen.
        let model = SequenceRowModel(entries: [
            make("one", ["B": "GG", "A": "MKV"], parents: ["bb1"]),
            make("two", ["A": "MKV", "B": "GG"], parents: ["bb1"]),
        ])
        XCTAssertEqual(letters(model.rows[0]), "MKV|GG")
        XCTAssertEqual(letters(model.rows[1]), "MKV|GG")
    }

    func testWithNoParentTheRunIsTheGroup() {
        // The first generation has no parents at all. The entries of one run are still
        // siblings, so they still share a column space.
        let model = SequenceRowModel(entries: [
            make("d1", ["A": "MKVL"], run: "r1"),
            make("d2", ["A": "MKV"], run: "r1"),
            make("x1", ["A": "MK"], run: "r2"),
        ])
        XCTAssertEqual(letters(model.rows[0]), "MKVL")
        XCTAssertEqual(letters(model.rows[1]), "MKV-")
        XCTAssertEqual(letters(model.rows[2]), "MK", "another run is another space")
    }

    func testWithNeitherParentNorRunEverythingSharesOneSpace() {
        let model = SequenceRowModel(entries: [
            make("d1", ["A": "MKVL"]),
            make("d2", ["A": "MK"]),
        ])
        XCTAssertEqual(letters(model.rows[1]), "MK--")
        XCTAssertEqual(model.rows[1].groupKey, "")
    }

    // MARK: collapse

    func testTheThresholdIsTwoHundredAndIsTheBoundaryItSays() {
        XCTAssertEqual(SequenceRowModel.defaultCollapseThreshold, 200)
        func model(_ n: Int) -> SequenceRowModel {
            SequenceRowModel(entries: (0..<n).map { make("d\($0)", ["A": "MK"]) })
        }
        XCTAssertFalse(model(200).isCollapsed, "exactly the threshold still draws rows")
        XCTAssertTrue(model(201).isCollapsed)
        XCTAssertEqual(model(200).displayedRows.count, 200)
        XCTAssertEqual(model(200).collapsedRowCount, 0)
    }

    func testCollapsedKeepsTheSelectedRowsOnTop() {
        let entries = (0..<300).map { make("d\($0)", ["A": "MK"]) }
        let model = SequenceRowModel(entries: entries, selection: ["d7", "d200"])
        XCTAssertTrue(model.isCollapsed)
        XCTAssertEqual(model.displayedRows.map(\.id), ["d7", "d200"])
        XCTAssertEqual(model.collapsedRowCount, 298,
                       "the caption has to name the population the band is over")
        // The band is over EVERY row, not the two that are showing.
        XCTAssertEqual(model.consensus.count, 2)
        XCTAssertEqual(model.consensus[0].count, 300)
    }

    func testTheThresholdIsAParameterSoATestCanUseSmallNumbers() {
        let entries = (0..<4).map { make("d\($0)", ["A": "MK"]) }
        XCTAssertTrue(SequenceRowModel(entries: entries, collapseThreshold: 3).isCollapsed)
        XCTAssertFalse(SequenceRowModel(entries: entries, collapseThreshold: 4).isCollapsed)
    }

    // MARK: consensus

    func testTheBandCountsWhatIsThereAndMarksWhatNeverVaries() {
        let model = SequenceRowModel(entries: [
            make("a", ["A": "MKV"], parents: ["p"]),
            make("b", ["A": "MRV"], parents: ["p"]),
            make("c", ["A": "MRV"], parents: ["p"]),
        ])
        let band = model.consensus
        XCTAssertEqual(band.count, 3)
        XCTAssertEqual(band[0].letter, "M")
        XCTAssertTrue(band[0].isInvariant, "position 1 is M on all three")
        XCTAssertEqual(band[0].fraction, 1.0)
        XCTAssertEqual(band[1].letter, "R", "two Rs beat one K")
        XCTAssertEqual(band[1].distinct, 2)
        XCTAssertEqual(band[1].fraction, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertFalse(band[1].isInvariant)
        XCTAssertTrue(band[2].isInvariant)
    }

    func testGapsAreNotResiduesInTheBand() {
        let model = SequenceRowModel(entries: [
            make("a", ["A": "MKV"], parents: ["p"]),
            make("b", ["A": "MK"], parents: ["p"]),
        ])
        let band = model.consensus
        XCTAssertEqual(band[2].count, 1, "only one row reaches column 2")
        XCTAssertEqual(band[2].letter, "V")
        XCTAssertEqual(band[2].fraction, 1.0,
                       "the fraction is of the rows that HAVE a residue here")
    }

    func testAColumnEveryRowGapsIsEmptyRatherThanAGuess() {
        let model = SequenceRowModel(entries: [make("a", [:])])
        XCTAssertEqual(model.consensus, [])
    }

    func testTiesAreBrokenTheSameWayTwiceRunning() {
        let entries = [make("a", ["A": "K"], parents: ["p"]),
                       make("b", ["A": "R"], parents: ["p"])]
        let first = SequenceRowModel(entries: entries).consensus
        let second = SequenceRowModel(entries: entries.reversed()).consensus
        XCTAssertEqual(first[0].letter, second[0].letter,
                       "a band that changes when the rows arrive in another order is"
                       + " a band nobody can read")
        XCTAssertEqual(first[0].letter, "K")
    }

    // MARK: arrays onto rows

    private func array(_ key: String, _ index: [(String, String)],
                       _ values: [Double?], chain: String? = nil) -> ResidueArray {
        ResidueArray(key: key, chain: chain,
                     index: index.map { ResidueArray.ResidueKey(chain: $0.0, resi: $0.1) },
                     values: values)
    }

    func testAMultiChainArrayLandsOnTheRightChains() {
        let model = SequenceRowModel(entries: [make("a", ["A": "MKV", "B": "GG"])])
        let row = model.rows[0]
        let values = SequenceRowModel.heatValues(
            row: row,
            arrays: [array("plddt",
                           [("A", "1"), ("A", "2"), ("A", "3"), ("B", "10"), ("B", "11")],
                           [90, 80, nil, 70, 60])])
        // cells: M K V | G G  — the break carries no value.
        XCTAssertEqual(values.count, row.cells.count)
        XCTAssertEqual(values[0], 90)
        XCTAssertEqual(values[1], 80)
        XCTAssertNil(values[2], "absent stays absent through the mapping")
        XCTAssertNil(values[3], "the chain break is not a residue")
        XCTAssertEqual(values[4], 70)
        XCTAssertEqual(values[5], 60)
    }

    func testALengthMismatchDrawsNothingRatherThanSlideEverythingLeft() {
        let model = SequenceRowModel(entries: [make("a", ["A": "MKV"])])
        let values = SequenceRowModel.heatValues(
            row: model.rows[0],
            arrays: [array("plddt", [("A", "1"), ("A", "2")], [90, 80])])
        XCTAssertEqual(values, [nil, nil, nil],
                       "two values under three residues is not a strip, it is a guess")
    }

    func testOneBadChainDoesNotCostTheOtherItsStrip() {
        let model = SequenceRowModel(entries: [make("a", ["A": "MKV", "B": "GG"])])
        let values = SequenceRowModel.heatValues(
            row: model.rows[0],
            arrays: [array("plddt", [("A", "1"), ("A", "2"), ("A", "3"), ("B", "10")],
                           [90, 80, 70, 60])])
        XCTAssertEqual(values[0], 90)
        XCTAssertEqual(values[1], 80)
        XCTAssertEqual(values[2], 70)
        XCTAssertNil(values[4], "chain B is one value short of its two residues")
        XCTAssertNil(values[5])
    }

    func testAGapNeverCarriesAValue() {
        let model = SequenceRowModel(entries: [
            make("long", ["A": "MKV"], parents: ["p"]),
            make("short", ["A": "MK"], parents: ["p"]),
        ])
        let values = SequenceRowModel.heatValues(
            row: model.rows[1],
            arrays: [array("plddt", [("A", "1"), ("A", "2")], [90, 80])])
        XCTAssertEqual(values, [90, 80, nil])
    }

    func testAnUnnamedChainJoinsAMonomersOnlyChain() {
        // `_add_array` stores a blank chain id as "", and a monomer loaded from a PDB
        // with no chain column has one. Without this the commonest single-chain case
        // would silently have no strip.
        let model = SequenceRowModel(entries: [make("a", ["A": "MKV"])])
        let values = SequenceRowModel.heatValues(
            row: model.rows[0],
            arrays: [array("plddt", [("", "1"), ("", "2"), ("", "3")], [90, 80, 70])])
        XCTAssertEqual(values, [90, 80, 70])
    }

    // MARK: heat tracks

    func testTheDomainsAreDesignModesOwn() {
        let nativeFit = SequenceHeatTrack.known.first { $0.key == "native_fit" }
        XCTAssertEqual(nativeFit?.domain.lowerBound, -6)
        XCTAssertEqual(nativeFit?.domain.upperBound, 0)
        let certainty = SequenceHeatTrack.known.first { $0.key == "certainty" }
        XCTAssertEqual(certainty?.domain, 0...1)
        #if RAYMOL_MPNN
        XCTAssertEqual(SequenceHeatTrack.nativeFitDomain.lowerBound,
                       Double(DesignColor.nativeFitDomain.lowerBound),
                       "the strip and Design mode must ramp over the same range, or a"
                       + " residue is one colour in the viewport and another here")
        XCTAssertEqual(SequenceHeatTrack.certaintyDomain.upperBound,
                       Double(DesignColor.certaintyDomain.upperBound))
        #endif
    }

    func testASetsOwnDeclarationWinsOverTheFallback() {
        // A predictor that scores confidence 0…1 rather than 0…100 needs no edit here.
        let column = MetricColumn(key: "plddt", scope: "residue", lo: 0, hi: 1,
                                  higherIsBetter: true, tool: "someothertool",
                                  column: nil)
        let track = SequenceHeatTrack.track(key: "plddt", columns: [column])
        XCTAssertEqual(track?.domain, 0...1)
        XCTAssertEqual(SequenceHeatTrack.track(key: "plddt", columns: [])?.domain,
                       0...100, "with nothing declared, pLDDT is 0…100")
    }

    func testAnUnknownResidueArrayGetsNoInventedDomain() {
        XCTAssertNil(SequenceHeatTrack.track(key: "wholly_new", columns: []),
                     "a domain guessed from the values in front of you is the"
                     + " auto-scaling the metrics store exists to refuse")
        // Declared but with no domain either: still nothing to ramp against.
        let undomained = MetricColumn(key: "wholly_new", scope: "residue", column: nil)
        XCTAssertNil(SequenceHeatTrack.track(key: "wholly_new", columns: [undomained]))
        // Declared WITH a domain, it draws — which is how a fifth predictor's residue
        // metric gets a strip with no edit here.
        let column = MetricColumn(key: "wholly_new", scope: "residue", lo: 0, hi: 5,
                                  higherIsBetter: false, column: nil)
        let track = SequenceHeatTrack.track(key: "wholly_new", columns: [column])
        XCTAssertEqual(track?.domain, 0...5)
        XCTAssertEqual(track?.higherIsBetter, false)
        XCTAssertEqual(SequenceHeatTrack.tracks(columns: [column]).map(\.key),
                       ["wholly_new"])
        XCTAssertEqual(SequenceHeatTrack.tracks(columns: [undomained]).count, 0,
                       "a residue array with no domain contributes no strip")
    }

    func testGoodnessIsOrientedSoOneIsGoodAndAbsentIsNothing() {
        let plddt = try! XCTUnwrap(SequenceHeatTrack.track(key: "plddt", columns: []))
        XCTAssertEqual(plddt.goodness(100), 1)
        XCTAssertEqual(plddt.goodness(0), 0)
        XCTAssertEqual(plddt.goodness(50), 0.5)
        XCTAssertEqual(plddt.goodness(140), 1, "out of domain clamps, it does not wrap")
        XCTAssertNil(plddt.goodness(nil), "absent draws nothing, not a zero")
        XCTAssertNil(plddt.goodness(.nan))
        // An RMSD-like residue metric: low is good, so the ramp is inverted, exactly
        // as `SetTableModel.goodness` does it for the table cell.
        let column = MetricColumn(key: "err", scope: "residue", lo: 0, hi: 10,
                                  higherIsBetter: false, column: nil)
        let err = try! XCTUnwrap(SequenceHeatTrack.track(key: "err", columns: [column]))
        XCTAssertEqual(err.goodness(0), 1)
        XCTAssertEqual(err.goodness(10), 0)
    }

    func testTracksComeOutInOneOrderWhateverTheSetDeclares() {
        let columns = [
            MetricColumn(key: "certainty", scope: "residue", column: nil),
            MetricColumn(key: "plddt", scope: "residue", column: nil),
            MetricColumn(key: "score", scope: "object", column: "score"),
        ]
        XCTAssertEqual(SequenceHeatTrack.tracks(columns: columns).map(\.key),
                       ["plddt", "certainty"],
                       "the strips under one row must be in the same order as under"
                       + " every other row, so the order is the spec's, not the file's")
        XCTAssertEqual(SequenceHeatTrack.tracks(columns: []).count, 0)
    }
}

// MARK: - The strip's one-time move (#419 decision 3)

final class SequenceStripMigrationTests: XCTestCase {

    func testAStripThatWasOpenBecomesTheDrawerOnSequences() {
        let answer = PanelLayout.sequenceStripMigration(
            legacyStripVisible: true, drawerVisible: false, alreadyMigrated: false)
        XCTAssertTrue(answer.drawerVisible,
                      "a visible pane must not vanish because it moved")
        XCTAssertTrue(answer.openSequencesTab)
        XCTAssertTrue(answer.didMigrate)
    }

    func testAStripThatWasClosedChangesNothing() {
        // The honest answer in both directions: turning a pane ON for someone who
        // closed it is the same discourtesy as taking one away.
        for drawer in [true, false] {
            let answer = PanelLayout.sequenceStripMigration(
                legacyStripVisible: false, drawerVisible: drawer, alreadyMigrated: false)
            XCTAssertEqual(answer.drawerVisible, drawer)
            XCTAssertFalse(answer.openSequencesTab)
            XCTAssertTrue(answer.didMigrate, "it still only asks once")
        }
    }

    func testAFreshInstallHasNothingToMigrate() {
        let answer = PanelLayout.sequenceStripMigration(
            legacyStripVisible: nil, drawerVisible: false, alreadyMigrated: false)
        XCTAssertFalse(answer.drawerVisible)
        XCTAssertFalse(answer.openSequencesTab)
    }

    func testTheSecondLaunchDoesNotReopenTheDrawer() {
        // The whole reason there is a flag: an iPad user who turns the strip back on
        // must not find the Mac's drawer open again on the next launch.
        let answer = PanelLayout.sequenceStripMigration(
            legacyStripVisible: true, drawerVisible: false, alreadyMigrated: true)
        XCTAssertFalse(answer.drawerVisible)
        XCTAssertFalse(answer.openSequencesTab)
        XCTAssertFalse(answer.didMigrate)
    }

    func testAgainstARealDefaultsDomainItRunsExactlyOnce() throws {
        let name = "raymol419.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: PanelLayout.sequenceVisibleKey)

        let first = PanelLayout.migrateSequenceStrip(defaults: defaults)
        XCTAssertTrue(first.didMigrate)
        XCTAssertTrue(first.openSequencesTab)
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.dataDrawerVisibleKey),
                      "the drawer is what the strip became")
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.sequenceMigratedKey))
        // The legacy key is READ and left alone: iOS still draws its strip from it
        // until #420, and a Mac launch must not close an iPad's pane.
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.sequenceVisibleKey))

        // Close the drawer, relaunch: it stays closed.
        defaults.set(false, forKey: PanelLayout.dataDrawerVisibleKey)
        let second = PanelLayout.migrateSequenceStrip(defaults: defaults)
        XCTAssertFalse(second.didMigrate)
        XCTAssertFalse(second.drawerVisible)
        XCTAssertFalse(second.openSequencesTab)
    }

    func testTheLegacyKeyIsStillPartOfTheNamespace() {
        // iOS reads it, so it stays in `allKeys` and keeps its namespace test.
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.sequenceVisibleKey))
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.sequenceMigratedKey))
    }

    func testEveryTabIsAvailableNowAndOnlySequencesWorksWithoutASet() {
        for tab in DataDrawerTab.allCases {
            XCTAssertTrue(tab.isAvailable, "\(tab.rawValue) shipped in #419")
            // The tooltip has to describe the tab rather than promise it. Asserting
            // on the absence of "#419" was circular — the code produced that string
            // too, so the test only said "the code says what the code says".
            XCTAssertFalse(tab.help.isEmpty, tab.rawValue)
            for promise in ["Coming", "coming", "not yet", "will be"] {
                XCTAssertFalse(tab.help.contains(promise),
                               "\(tab.rawValue) still advertises itself as unbuilt:"
                               + " \(tab.help)")
            }
        }
        // #456: "works without a set" is no longer a fact about any TAB. The scene
        // rows that made Sequences qualify are the drawer's band now, so the property
        // moved to the thing it describes — and every tab is a view of a set again.
        XCTAssertTrue(SequenceBandView.worksWithoutASet)
    }
}

// MARK: - The scene rows become a drawer BAND (#456)

/// One test per state a user can arrive in. There are two migrations now and they can
/// have run in either combination, which is the whole reason this is a pure function:
/// the way to annoy someone twice is to take their sequence view away, give it back on
/// a tab, and then take it away again when the tab stops holding it.
final class SequenceBandMigrationTests: XCTestCase {

    /// #419 firing on this same launch: the strip's own flag is the answer.
    private func stripFired(visible: Bool) -> PanelLayout.SequenceStripMigration {
        PanelLayout.sequenceStripMigration(legacyStripVisible: visible,
                                           drawerVisible: false, alreadyMigrated: false)
    }
    private var stripAbsent: PanelLayout.SequenceStripMigration {
        PanelLayout.sequenceStripMigration(legacyStripVisible: nil,
                                           drawerVisible: false, alreadyMigrated: false)
    }
    private var stripSpent: PanelLayout.SequenceStripMigration {
        PanelLayout.sequenceStripMigration(legacyStripVisible: true,
                                           drawerVisible: false, alreadyMigrated: true)
    }

    private func band(_ strip: PanelLayout.SequenceStripMigration,
                      drawer: Bool = false, tab: DataDrawerTab = .table,
                      stored: Bool = false, already: Bool = false)
        -> PanelLayout.SequenceBandMigration {
        PanelLayout.sequenceBandMigration(stripMigration: strip, drawerVisible: drawer,
                                          drawerTab: tab, storedBandVisible: stored,
                                          alreadyMigrated: already)
    }

    // Case 1: never migrated, `sequenceVisible` true. They came straight from a build
    // with a strip and it was up; the band is what it became.
    func testAStripThatWasUpBecomesTheBand() {
        let answer = band(stripFired(visible: true))
        XCTAssertTrue(answer.bandVisible, "a visible pane must not vanish because it moved")
        XCTAssertTrue(answer.didMigrate)
    }

    // Case 2: never migrated, `sequenceVisible` false. Off is a choice too.
    func testAStripThatWasDownDoesNotBecomeABand() {
        let answer = band(stripFired(visible: false))
        XCTAssertFalse(answer.bandVisible)
        XCTAssertTrue(answer.didMigrate, "it still only asks once")
    }

    // Case 3: never migrated, the key was never written — a fresh install, or a user
    // who never touched the strip. Same answer as "off", for the same reason.
    func testAFreshInstallStartsWithoutTheBand() {
        let answer = band(stripAbsent)
        XCTAssertFalse(answer.bandVisible)
        XCTAssertTrue(answer.didMigrate)
    }

    // Case 4: #419 already spent, and it left them on the Sequences tab with the drawer
    // open. That IS the sequence view being up — and the scene rows are about to leave
    // that tab, so without this they would lose the same pane a second time.
    func testAnAlreadyMigratedUserOnTheSequencesTabGetsTheBand() {
        let answer = band(stripSpent, drawer: true, tab: .sequences)
        XCTAssertTrue(answer.bandVisible)
        XCTAssertTrue(answer.didMigrate)
    }

    // Case 5: #419 spent, the tab is remembered as Sequences, but the drawer is CLOSED.
    // Nothing is on screen, so nothing is being taken away; turning the band on would
    // be opening a pane for someone who closed it.
    func testAClosedDrawerIsNotASequenceViewWhateverTabItRemembers() {
        let answer = band(stripSpent, drawer: false, tab: .sequences)
        XCTAssertFalse(answer.bandVisible)
        XCTAssertTrue(answer.didMigrate)
    }

    // Case 6: #419 spent, drawer open on some other tab. They are triaging, not reading
    // sequences; the band arrives off and ⌘2 is how they ask for it.
    func testAnAlreadyMigratedUserOnAnotherTabDoesNotGetTheBand() {
        for tab in [DataDrawerTab.table, .plot, .lineage] {
            XCTAssertFalse(band(stripSpent, drawer: true, tab: tab).bandVisible, tab.rawValue)
        }
    }

    // Case 7: this migration has already run. The stored flag is the answer and nothing
    // is written — otherwise turning the band off would be undone on the next launch.
    func testTheSecondLaunchLeavesTheBandWhereTheUserPutIt() {
        for stored in [true, false] {
            let answer = band(stripSpent, drawer: true, tab: .sequences,
                              stored: stored, already: true)
            XCTAssertEqual(answer.bandVisible, stored)
            XCTAssertFalse(answer.didMigrate)
        }
    }

    /// Against a real domain, in the order a launch runs them: #419 first (it writes
    /// `dataDrawerVisible`), then #456 reading what #419 left. A user with the strip up
    /// and no drawer ends with BOTH the drawer and the band on.
    func testBothMigrationsRunInOrderAgainstRealDefaults() throws {
        let name = "raymol456.band.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: PanelLayout.sequenceVisibleKey)

        let strip = PanelLayout.migrateSequenceStrip(defaults: defaults)
        let first = PanelLayout.migrateSequenceBand(stripMigration: strip, defaults: defaults)
        XCTAssertTrue(strip.didMigrate)
        XCTAssertTrue(first.didMigrate)
        XCTAssertTrue(first.bandVisible)
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.dataDrawerVisibleKey))
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.sequenceBandVisibleKey))
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.sequenceBandMigratedKey))

        // Turn the band off and relaunch: it stays off.
        defaults.set(false, forKey: PanelLayout.sequenceBandVisibleKey)
        let second = PanelLayout.migrateSequenceBand(
            stripMigration: PanelLayout.migrateSequenceStrip(defaults: defaults),
            defaults: defaults)
        XCTAssertFalse(second.didMigrate)
        XCTAssertFalse(second.bandVisible)
    }

    /// The #419-migrated user, against a real domain: their defaults already carry the
    /// spent strip flag, an open drawer and the Sequences tab, and no #456 flag.
    func testTheAlreadyMigratedUserIsCarriedForwardAgainstRealDefaults() throws {
        let name = "raymol456.carry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: PanelLayout.sequenceVisibleKey)
        defaults.set(true, forKey: PanelLayout.sequenceMigratedKey)
        defaults.set(true, forKey: PanelLayout.dataDrawerVisibleKey)
        defaults.set(DataDrawerTab.sequences.rawValue, forKey: PanelLayout.dataDrawerTabKey)

        let strip = PanelLayout.migrateSequenceStrip(defaults: defaults)
        XCTAssertFalse(strip.didMigrate, "#419's flag is spent")
        let answer = PanelLayout.migrateSequenceBand(stripMigration: strip, defaults: defaults)
        XCTAssertTrue(answer.bandVisible,
                      "they are looking at the scene rows right now; the band is where"
                      + " those rows went")
        XCTAssertTrue(defaults.bool(forKey: PanelLayout.sequenceBandVisibleKey))
    }

    /// Case 4 for the user it actually exists to rescue (#456 review): #419 migrated
    /// them and they never opened a set afterwards, so `dataDrawerTabKey` was never
    /// written — `PyMOLEngine.dataDrawerTab`'s `didSet` does not fire on init, and
    /// nothing else wrote it. The key is ABSENT here, which is the state #419 really
    /// leaves; setting it by hand (as the test below this one does) was assuming away
    /// the bug.
    func testAMigratedUserWhoNeverTouchedATabStillGetsTheBand() throws {
        let name = "raymol456.notab.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: PanelLayout.sequenceVisibleKey)

        // #419, for real, against this domain — including the tab it chooses.
        let strip = PanelLayout.migrateSequenceStrip(defaults: defaults)
        XCTAssertTrue(strip.openSequencesTab)
        XCTAssertEqual(defaults.string(forKey: PanelLayout.dataDrawerTabKey),
                       DataDrawerTab.sequences.rawValue,
                       "#419 chose Sequences; if it does not WRITE it, the choice is"
                       + " gone by the next launch and #456 cannot see it")

        // Now a launch of THIS build, with #419's flag spent and nothing else touched.
        let later = try XCTUnwrap(UserDefaults(suiteName: name))
        let answer = PanelLayout.migrateSequenceBand(
            stripMigration: PanelLayout.migrateSequenceStrip(defaults: later),
            defaults: later)
        XCTAssertTrue(answer.bandVisible)
    }

    func testTheBandKeysArePartOfTheNamespace() {
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.sequenceBandVisibleKey))
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.sequenceBandMigratedKey))
    }
}

// MARK: - What the drawer draws, and what ⌘2 closes (#456)

final class DataDrawerContentTests: XCTestCase {

    func testTheFourShapesOfTheDrawer() {
        XCTAssertEqual(DataDrawer.content(hasSet: true, bandVisible: true), .bandOverTabs,
                       "the point of #456: the scene sequences and the set together")
        XCTAssertEqual(DataDrawer.content(hasSet: true, bandVisible: false), .tabsAlone)
        XCTAssertEqual(DataDrawer.content(hasSet: false, bandVisible: true), .bandAlone,
                       "no set open: the strip, in its new home, with no tab bar")
        XCTAssertEqual(DataDrawer.content(hasSet: false, bandVisible: false), .empty)
    }

    /// `worksWithoutASet` is a claim about the BAND now, not about a tab — and it is
    /// load-bearing rather than decorative: it is what makes the no-set drawer draw the
    /// band instead of the "No set open" copy.
    func testTheNoSetDrawerIsTheBandBecauseTheBandWorksWithoutASet() {
        XCTAssertTrue(SequenceBandView.worksWithoutASet)
        XCTAssertEqual(DataDrawer.content(hasSet: false, bandVisible: true),
                       SequenceBandView.worksWithoutASet ? .bandAlone : .empty)
    }

    /// ⌘2 must never close a drawer ⌘4 opened (#456 review).
    func testHidingTheBandOnlyClosesTheDrawerItOpened() {
        XCTAssertTrue(PyMOLEngine.drawerClosesWithBand(hasSet: false, openedByBand: true),
                      "⌘2 opened it and there is nothing else in it")
        XCTAssertFalse(PyMOLEngine.drawerClosesWithBand(hasSet: false, openedByBand: false),
                       "the user opened this drawer with ⌘4; leave it where they put it")
        for opened in [true, false] {
            XCTAssertFalse(
                PyMOLEngine.drawerClosesWithBand(hasSet: true, openedByBand: opened),
                "with a set open the height goes back to the tab, it does not close")
        }
    }
}

// MARK: - Regressions from the #455 review

/// The consensus band, and the seam between the model and the loader that made it
/// draw nothing above the threshold.
///
/// `SequenceRowModelTests.testCollapsedKeepsTheSelectedRowsOnTop` passes literal
/// sequences to the model and so could never have caught this: the model was right,
/// and nothing was loading the sequences it needed. These tests go at the loader.
final class ConsensusBandTests: XCTestCase {

    private var dir: URL!
    private var path: String!
    private static let entryCount = 300

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol419-band-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("band.raymol").path
        try SequenceLazyLoadTests.layDownContainer(at: path, entries: Self.entryCount,
                                                   setID: "s1")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Blocker 1. The band is over the WHOLE set, so the sequences of the whole set
    /// have to be readable without reading the whole set's blobs.
    func testTheBandsSequencesLoadWithoutReadingASingleBlob() throws {
        let store = try XCTUnwrap(SetsStore(path: path))
        defer { store.close() }
        let sequences = store.sequencesOfSet(setID: "s1")
        XCTAssertEqual(sequences.count, Self.entryCount,
                       "every entry, not the ones that happened to be on screen")
        XCTAssertEqual(sequences["e0"], ["A": "MKV"])
        XCTAssertEqual(store.arrayBlobReads, 0,
                       "the band needs sequences, and sequences are text in `entries`;"
                       + " reading 300 blobs to draw one band is the cost #421 forbids")
    }

    /// The failure exactly as reported: 300 entries, nothing selected, nothing loaded.
    /// Before the fix every row had zero cells and `consensus` was empty while the
    /// caption claimed 300.
    func testAnUnloadedCollapsedSetHasAnEmptyBandAndACaptionThatSaysSo() {
        let rows = (0..<Self.entryCount).map { i in
            SequenceEntryInput(id: "e\(i)", name: "d_\(i)", ord: i, sequences: [:])
        }
        let model = SequenceRowModel(entries: rows)
        XCTAssertTrue(model.isCollapsed)
        XCTAssertTrue(model.displayedRows.isEmpty, "nothing is selected")
        XCTAssertTrue(model.consensus.isEmpty, "and so nothing has been loaded")
        // The caption may not say 300. This is the assertion that was false before:
        // `collapsedRowCount` is 300 here, and it was what the caption read.
        XCTAssertEqual(model.consensusPopulation, 0,
                       "the caption names what the band was computed over, and with"
                       + " nothing loaded that is nothing")
        XCTAssertEqual(model.collapsedRowCount, 300,
                       "the two differ, which is the whole reason the caption uses"
                       + " the first one")
    }

    /// The partial case, which is the one that lies rather than merely disappoints: a
    /// band drawn from 23 of 1000 rows, captioned as 997.
    func testAPartiallyLoadedBandNeverClaimsThePopulation() {
        var rows: [SequenceEntryInput] = []
        for i in 0..<Self.entryCount {
            // Only the first 23 have sequences, as if only they had been scrolled past.
            rows.append(SequenceEntryInput(id: "e\(i)", name: "d_\(i)", ord: i,
                                           sequences: i < 23 ? ["A": "MKV"] : [:]))
        }
        let model = SequenceRowModel(entries: rows, selection: ["e0", "e1", "e2"])
        XCTAssertEqual(model.displayedRows.count, 3)
        XCTAssertEqual(model.consensus.first?.count, 23)
        XCTAssertEqual(model.consensusPopulation, 23,
                       "the caption and the band have to agree; 297 was the lie")
        XCTAssertNotEqual(model.consensusPopulation, model.collapsedRowCount)
    }

    /// Once loaded, the two numbers agree — which is the state the bulk read produces
    /// and the one a user normally sees.
    func testALoadedBandCountsThemAll() {
        let rows = (0..<Self.entryCount).map { i in
            SequenceEntryInput(id: "e\(i)", name: "d_\(i)", ord: i,
                               sequences: ["A": "MKV"])
        }
        let model = SequenceRowModel(entries: rows)
        XCTAssertEqual(model.consensusPopulation, Self.entryCount)
        XCTAssertEqual(model.consensus.count, 3)
        XCTAssertTrue(model.consensus[0].isInvariant)
    }

    /// The flag that keeps the bulk read from starving the per-row one. Before it,
    /// `requestSequenceDetails` filtered on presence, so an id the band had already
    /// put in the dictionary never had its arrays read and no strip ever appeared.
    func testASequenceOnlyDetailStillOwesItsArrays() {
        let bulk = SetEntryDetail(id: "e1", sequences: ["A": "MKV"], arrays: [],
                                  arraysLoaded: false)
        XCTAssertFalse(bulk.arraysLoaded)
        XCTAssertTrue(bulk.arrays.isEmpty)
        let full = bulk.withArrays([ResidueArray(key: "plddt", chain: nil, index: [],
                                                 values: [])])
        XCTAssertTrue(full.arraysLoaded)
        XCTAssertEqual(full.sequences, ["A": "MKV"], "the bulk read's text survives")
        // An entry that genuinely has no arrays is loaded, not owing.
        XCTAssertTrue(SetEntryDetail(id: "e2").arraysLoaded)
    }

    /// The bound on the blob half. Sequences stay (the band needs them); arrays are
    /// evicted least-recently-read first, and an evicted entry goes back to owing.
    func testArraysAreBoundedAndSequencesAreNot() {
        var details: [String: SetEntryDetail] = [:]
        var order: [String] = []
        for i in 0..<10 {
            let id = "e\(i)"
            details[id] = SetEntryDetail(id: id, sequences: ["A": "MKV"],
                                         arrays: [ResidueArray(key: "plddt", chain: nil,
                                                               index: [], values: [])],
                                         arraysLoaded: true)
            order.append(id)
        }
        let out = PyMOLEngine.evictSequenceArrays(details, order: &order, limit: 4)
        XCTAssertEqual(order, ["e6", "e7", "e8", "e9"], "least recently read go first")
        XCTAssertEqual(out.count, 10, "no entry is forgotten…")
        XCTAssertEqual(out["e0"]?.sequences, ["A": "MKV"], "…and no sequence is lost")
        XCTAssertTrue(out["e0"]!.arrays.isEmpty)
        XCTAssertFalse(out["e0"]!.arraysLoaded, "an evicted entry owes its arrays again")
        XCTAssertFalse(out["e9"]!.arrays.isEmpty)
        // Under the limit, nothing moves.
        var short = ["a", "b"]
        _ = PyMOLEngine.evictSequenceArrays([:], order: &short, limit: 4)
        XCTAssertEqual(short, ["a", "b"])
    }
}

/// Per-chain residue arrays (review item 3), the `goodness` orientation (5), and the
/// encoding allowlist (10).
final class SequenceHeatStripRegressionTests: XCTestCase {

    private func row(_ sequences: [String: String]) -> SequenceEntryRow {
        SequenceRowModel(entries: [
            SequenceEntryInput(id: "a", name: "a", sequences: sequences)
        ]).rows[0]
    }

    private func array(_ key: String, chain: String?, _ index: [(String, String)],
                       _ values: [Double?]) -> ResidueArray {
        ResidueArray(key: key, chain: chain,
                     index: index.map { ResidueArray.ResidueKey(chain: $0.0, resi: $0.1) },
                     values: values)
    }

    /// Item 3 AT THE SEAM THAT BROKE. The merge below was always right; what was
    /// wrong is that the view only ever got ONE array, because `SetEntryDetail` handed
    /// it `.first`. A test that passes both arrays in by hand cannot see that, so this
    /// one goes through the detail exactly as `entryRow` does.
    func testADetailHandsOverEveryArrayUnderAKeyNotJustTheFirst() {
        let detail = SetEntryDetail(id: "e1", sequences: ["A": "MKV", "B": "GG"], arrays: [
            array("plddt", chain: "A", [("A", "1"), ("A", "2"), ("A", "3")],
                  [100, 100, 100]),
            array("plddt", chain: "B", [("B", "10"), ("B", "11")], [20, 20]),
            array("certainty", chain: nil,
                  [("A", "1"), ("A", "2"), ("A", "3"), ("B", "10"), ("B", "11")],
                  [1, 1, 1, 1, 1]),
        ])
        XCTAssertEqual(detail.arrays("plddt").count, 2,
                       "`arrays`' primary key is (entry_id, key, chain) — one metric is"
                       + " legitimately several rows")
        XCTAssertEqual(detail.arrays("plddt").compactMap(\.chain), ["A", "B"])
        XCTAssertEqual(detail.arrays("certainty").count, 1)
        XCTAssertEqual(detail.arrays("nope").count, 0)
        // End to end, the way the view does it: detail → heatValues → strip.
        let values = SequenceRowModel.heatValues(row: row(["A": "MKV", "B": "GG"]),
                                                 arrays: detail.arrays("plddt"))
        XCTAssertEqual(values[0], 100)
        XCTAssertEqual(values[4], 20,
                       "chain B scored 20; taking only the first array drew it as a"
                       + " chain nobody had scored")
        XCTAssertEqual(values[5], 20)
    }

    /// The same, against the COMMITTED fixture, which really does ship a whole-entry
    /// array and a chain-scoped one for the same entry.
    func testTheFixturesTwoArraysBothSurviveTheDetail() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/residue_arrays.raymol").path
        guard FileManager.default.fileExists(atPath: source) else {
            throw XCTSkip("fixture missing")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol419-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("f.raymol")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let store = try XCTUnwrap(SetsStore(path: copy.path))
        defer { store.close() }
        let id = try XCTUnwrap(store.lineageEntries().first { $0.name == "p_0001" }?.id)
        let detail = try XCTUnwrap(store.entryDetails(entryIDs: [id])[id])
        XCTAssertEqual(detail.arrays.count, 3, "plddt, native_fit/A, certainty")
        XCTAssertEqual(detail.arrays("native_fit").first?.chain, "A")
        XCTAssertEqual(detail.arrays("plddt").count, 1)
    }

    /// The merge itself: `plddt/A = 100` and `plddt/B = 20`.
    func testEveryChainsArrayIsUsedNotJustTheFirst() {
        let row = self.row(["A": "MKV", "B": "GG"])
        let values = SequenceRowModel.heatValues(row: row, arrays: [
            array("plddt", chain: "A", [("A", "1"), ("A", "2"), ("A", "3")],
                  [100, 100, 100]),
            array("plddt", chain: "B", [("B", "10"), ("B", "11")], [20, 20]),
        ])
        XCTAssertEqual(values[0], 100)
        XCTAssertEqual(values[2], 100)
        XCTAssertNil(values[3], "the chain break")
        XCTAssertEqual(values[4], 20, "a chain that scored badly is not an unscored one")
        XCTAssertEqual(values[5], 20)
    }

    func testTheChainScopedArrayWinsOverAWholeEntryOne() {
        // Both exist in the store's schema — `(entry_id, key, chain)` — and the
        // chain-scoped one is the more specific statement.
        let row = self.row(["A": "MKV", "B": "GG"])
        let values = SequenceRowModel.heatValues(row: row, arrays: [
            array("plddt", chain: nil,
                  [("A", "1"), ("A", "2"), ("A", "3"), ("B", "10"), ("B", "11")],
                  [1, 1, 1, 1, 1]),
            array("plddt", chain: "A", [("A", "1"), ("A", "2"), ("A", "3")], [9, 9, 9]),
        ])
        XCTAssertEqual(values[0], 9)
        XCTAssertEqual(values[4], 1, "chain B keeps the whole-entry values")
    }

    func testTheOrderTheArraysArriveInDoesNotMatter() {
        let row = self.row(["A": "MKV", "B": "GG"])
        let whole = array("plddt", chain: nil,
                          [("A", "1"), ("A", "2"), ("A", "3"), ("B", "10"), ("B", "11")],
                          [1, 1, 1, 1, 1])
        let specific = array("plddt", chain: "A",
                             [("A", "1"), ("A", "2"), ("A", "3")], [9, 9, 9])
        XCTAssertEqual(SequenceRowModel.heatValues(row: row, arrays: [whole, specific]),
                       SequenceRowModel.heatValues(row: row, arrays: [specific, whole]))
    }

    func testNoArraysIsNoValues() {
        let row = self.row(["A": "MKV"])
        XCTAssertEqual(SequenceRowModel.heatValues(row: row, arrays: []), [nil, nil, nil])
    }

    /// Item 5. `higherIsBetter == nil` means "neither end is better", and the strip
    /// used to paint it high=green while `SetTableModel.goodness` left the same metric
    /// untinted in the table — two views, one `MetricSpec`, opposite claims.
    func testNeitherEndBeingBetterPaintsNothingJustLikeTheTable() {
        let track = SequenceHeatTrack(key: "elapsed_s", label: "Elapsed",
                                      domain: 0...100, higherIsBetter: nil)
        XCTAssertNil(track.goodness(100))
        XCTAssertNil(track.goodness(0))
        XCTAssertNil(track.goodness(50))
        // The table's answer for the same spec, which is what it now agrees with.
        let column = MetricColumn(key: "elapsed_s", scope: "object", lo: 0, hi: 100,
                                  higherIsBetter: nil, column: "elapsed_s")
        XCTAssertNil(SetTableModel.goodness(.number(50), column))
        // And such a track is not offered as a pill that could only ever draw blank.
        let residue = MetricColumn(key: "elapsed_s", scope: "residue", lo: 0, hi: 100,
                                   higherIsBetter: nil, column: nil)
        XCTAssertEqual(SequenceHeatTrack.tracks(columns: [residue]).count, 0)
    }

    func testTheKnownTracksStillRamp() {
        // The fix must not quietly disable the three the spec names.
        for track in SequenceHeatTrack.known {
            XCTAssertNotNil(track.higherIsBetter, track.key)
            XCTAssertNotNil(track.goodness(track.domain.upperBound), track.key)
        }
    }
}

/// The encoding allowlist (review item 10) and the persisted tab (item 4).
final class SequenceEncodingAndTabTests: XCTestCase {

    /// Item 10. The guard used to be `!= "u8q"`, so ANY future encoding of the same
    /// width would have been decoded as f32 and drawn as a plausible, wrong strip.
    /// The bytes below are valid f32; the only thing wrong with them is the label.
    func testAnUnrecognisedEncodingIsRefusedNotDecodedAsF32() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol419-enc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for encoding in ["f32", "u8q", "f16", "f32v2"] {
            let path = dir.appendingPathComponent("\(encoding).raymol").path
            try SequenceLazyLoadTests.layDownContainer(at: path, entries: 1,
                                                       encoding: encoding)
            let store = try XCTUnwrap(SetsStore(path: path))
            defer { store.close() }
            let detail = try XCTUnwrap(store.entryDetails(entryIDs: ["e0"])["e0"])
            if encoding == "f32" {
                // The third value carries the entry index so every blob hashes
                // differently; the first two are the fixed ones.
                let values = detail.arrays("plddt").first?.values
                XCTAssertEqual(values?.count, 3, "the one encoding this build understands")
                XCTAssertEqual(values?[0], 90)
                XCTAssertEqual(values?[1], 80)
            } else {
                XCTAssertTrue(detail.arrays("plddt").isEmpty,
                              "\(encoding) is not f32, so it draws no strip rather"
                              + " than a strip that happens to be wrong")
            }
        }
    }

    /// Item 4. The drawer's tab has to survive a relaunch, or the strip's migration is
    /// a one-launch courtesy: Sequences once, Table every launch after.
    func testTheTabIsRestoredAndTheMigrationStillWins() {
        let migrated = PanelLayout.SequenceStripMigration(
            drawerVisible: true, openSequencesTab: true, didMigrate: true)
        let quiet = PanelLayout.SequenceStripMigration(
            drawerVisible: false, openSequencesTab: false, didMigrate: false)
        // The migration is the one thing that overrides a stored tab.
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: migrated, stored: "Table"),
                       .sequences)
        // Otherwise the stored choice comes back — this is the assertion that was
        // false before, when there was no key at all and every launch got .table.
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: quiet, stored: "Sequences"),
                       .sequences)
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: quiet, stored: "Lineage"),
                       .lineage)
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: quiet, stored: "Plot"),
                       .plot)
        // Nothing stored, or a name from a build that had a tab this one does not:
        // Table, rather than a drawer parked on something it cannot draw.
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: quiet, stored: nil), .table)
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: quiet, stored: "Wobble"),
                       .table)
    }

    func testTheTabKeyIsPartOfTheNamespace() {
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.dataDrawerTabKey))
    }

    /// It round-trips through a real defaults domain, which is what a relaunch is.
    func testTheTabSurvivesARelaunchAgainstRealDefaults() throws {
        let name = "raymol419.tab.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: .alreadyDone,
                                                     stored: defaults.string(
                                                        forKey: PanelLayout.dataDrawerTabKey)),
                       .table)
        defaults.set(DataDrawerTab.sequences.rawValue, forKey: PanelLayout.dataDrawerTabKey)
        XCTAssertEqual(PanelLayout.restoredDrawerTab(migration: .alreadyDone,
                                                     stored: defaults.string(
                                                        forKey: PanelLayout.dataDrawerTabKey)),
                       .sequences)
    }
}

/// Blocker 2: an arriving set must not replace the sequence view with the Table, and
/// item 8: the scene rows keep the strip's own sizing.
final class SequenceTabSurvivalTests: XCTestCase {

    /// A campaign makes a new set active repeatedly — once per child set — and every
    /// one of those used to land the user on Table.
    func testASetChangeLeavesTheTabAlone() {
        for tab in DataDrawerTab.allCases {
            XCTAssertEqual(PyMOLEngine.tabAfterSetChange(tab), tab,
                           "\(tab.rawValue) can draw for any set, so a new set is no"
                           + " reason to take it away")
        }
    }

    /// The rule is written out rather than assumed, so a tab this build cannot draw
    /// would still be rescued. Nothing is in that state today, which is what this
    /// asserts. (Before #456 the test also admitted `worksWithoutASet`; the scene rows
    /// that made Sequences qualify are the band now, and the band is not a tab.)
    func testNoTabNeedsRescuing() {
        XCTAssertTrue(DataDrawerTab.allCases.allSatisfy(\.isAvailable))
    }

    /// Item 8. The strip sized itself to its row count and could be dragged taller;
    /// pinning the scene rows at a flat 130pt was a reduction for the same content.
    /// This is the strip's own formula, unchanged — through #419, which put it in a
    /// tab, and through #456, which made it the drawer's band.
    func testTheSceneRowsKeepTheStripsHeightFormula() {
        XCTAssertEqual(SequenceBandView.sceneHeight(1), 60)
        XCTAssertEqual(SequenceBandView.sceneHeight(2), 90)
        XCTAssertEqual(SequenceBandView.sceneHeight(5), 180)
        XCTAssertEqual(SequenceBandView.sceneHeight(99), 180, "capped at five rows")
        XCTAssertEqual(SequenceBandView.sceneHeight(0), 60,
                       "an empty strip still occupies one row's worth")
        XCTAssertGreaterThan(SequenceBandView.sceneHeight(5), 130,
                             "the flat 130pt cap was below what five rows need")
        // The view's formula and the layout's are the same one, or the split would
        // start at a height the drawer's arithmetic never accounted for.
        for objects in [0, 1, 2, 5, 99] {
            XCTAssertEqual(SequenceBandView.sceneHeight(objects),
                           PanelLayout.sequenceBandIdealHeight(objects: objects))
        }
    }

    /// The `.id()` that makes the split re-adopt its ideal height when objects load.
    /// It has to change exactly when the ideal height does and not on every count.
    func testTheBandsHeightIdentityTracksTheRowsItCharges() {
        XCTAssertEqual(SequenceBandView.heightIdentity(0), 1)
        XCTAssertEqual(SequenceBandView.heightIdentity(1), 1)
        XCTAssertEqual(SequenceBandView.heightIdentity(3), 3)
        XCTAssertEqual(SequenceBandView.heightIdentity(5), 5)
        XCTAssertEqual(SequenceBandView.heightIdentity(40), 5,
                       "past the five-row cap the ideal height stops moving, so the"
                       + " identity has to stop moving with it")
    }
}
