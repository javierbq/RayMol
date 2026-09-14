// SetsStore.swift — the Swift side of a `.raymol` container (#417, tracking #421).
//
// A set can hold ten thousand entries, and the object panel's 500 ms poll must not
// grow with that count (#271, #398). So set CONTENTS never cross the Python → Swift
// feedback channel. Python prints one short `SETS:` marker (appkit_sets.py) carrying
// the container's path and `meta.version`, and only when either changed; this file
// opens that path READ-ONLY with the system SQLite (no package dependency) and
// re-reads the tables when the version moves. Between markers it does nothing.
//
// The schema is `modules/pymol/sets/schema.py` (spec §2.2), format version 1. Column
// names are declared once, there; everything read here is named the same way so a
// rename in one place shows up as a compile-time string here rather than an empty
// table at runtime.
//
// Concurrency, stated once: Python is the ONLY writer and holds its own connection,
// WAL mode, in this same process. A second read-only connection is what WAL is for;
// the one caveat is POSIX advisory locks, which are per PROCESS, so closing this
// connection's descriptor while Python holds a lock on the same file would drop
// Python's lock too. This connection therefore closes only when the marker's path
// changes — that is, after Python has already moved to (or deleted) another file.

import Foundation
import SQLite3

// MARK: - Model

/// One column of a set, decoded from `sets.columns` — a JSON list of `MetricSpec`
/// dicts plus `chain`, `tool` and `column` (the `m_<set_id>` column name, or null
/// for an array-scope metric that has no scalar column). The table's columns come
/// from THIS and nowhere else: a fifth predictor needs no UI edit (#421).
struct MetricColumn: Identifiable, Equatable, Hashable, Decodable {
    let key: String
    let scope: String
    let dtype: String
    let units: String
    let label: String
    let lo: Double?
    let hi: Double?
    /// nil when the question does not apply (an elapsed time is neither).
    let higherIsBetter: Bool?
    let chain: String?
    let tool: String
    /// The wide-table column, `key` or `key__chain`; nil for residue/pair arrays.
    let column: String?

    var id: String { column ?? "\(key)#\(chain ?? "")" }
    var isScalar: Bool { column != nil }
    /// "plddt/B" for a chain scalar, else the spec's label.
    var title: String {
        if let chain, !chain.isEmpty { return "\(label)/\(chain)" }
        return label
    }

    private enum CodingKeys: String, CodingKey {
        case key, scope, dtype, units, label, lo, hi, chain, tool, column
        case higherIsBetter = "higher_is_better"
    }

    init(key: String, scope: String = "object", dtype: String = "float", units: String = "",
         label: String = "", lo: Double? = nil, hi: Double? = nil,
         higherIsBetter: Bool? = nil, chain: String? = nil, tool: String = "",
         column: String? = nil) {
        self.key = key
        self.scope = scope
        self.dtype = dtype
        self.units = units
        self.label = label.isEmpty ? key : label
        self.lo = lo
        self.hi = hi
        self.higherIsBetter = higherIsBetter
        self.chain = chain
        self.tool = tool
        self.column = column
    }

    /// Every field but `key` is optional on the way in: the JSON is written by
    /// `MetricSpec.as_dict()` today, but a file from a newer build may carry more
    /// (or, after a migration, less), and one strict field would drop every column.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .key)
        self.init(
            key: key,
            scope: (try? c.decodeIfPresent(String.self, forKey: .scope)) ?? "object",
            dtype: (try? c.decodeIfPresent(String.self, forKey: .dtype)) ?? "float",
            units: (try? c.decodeIfPresent(String.self, forKey: .units)) ?? "",
            label: (try? c.decodeIfPresent(String.self, forKey: .label)) ?? key,
            lo: try? c.decodeIfPresent(Double.self, forKey: .lo),
            hi: try? c.decodeIfPresent(Double.self, forKey: .hi),
            higherIsBetter: try? c.decodeIfPresent(Bool.self, forKey: .higherIsBetter),
            chain: try? c.decodeIfPresent(String.self, forKey: .chain),
            tool: (try? c.decodeIfPresent(String.self, forKey: .tool)) ?? "",
            column: try? c.decodeIfPresent(String.self, forKey: .column))
    }
}

/// A cell. `null` is a real state — an unmeasured entry is not zero (the metrics
/// store's own rule) — and the table sorts it last whichever way the column goes.
enum MetricValue: Equatable, Hashable {
    case number(Double)
    case text(String)
    case null

    var number: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    var isNull: Bool { self == .null }
}

/// One entry of a set, as the drawer's table shows it. Identity and flags from
/// `entries`, scalars from the set's wide table keyed by column name. Sequences,
/// parents and arrays are NOT here: they load lazily, when a tab needs them (#419).
struct SetRow: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let ord: Int
    let starred: Bool
    let rejected: Bool
    let pinned: Bool
    let stagedObject: String?
    let nChains: Int
    let nResidues: Int
    let tags: String
    let runID: String?
    let values: [String: MetricValue]

    var isStaged: Bool { stagedObject != nil }
    func value(_ column: MetricColumn) -> MetricValue {
        guard let name = column.column else { return .null }
        return values[name] ?? .null
    }
}

/// A batch still landing in a set (#416's `pymol.sets.batch.running()`), as the
/// marker forwards it. `total` may be 0 while a job has not sized itself yet.
struct BatchProgress: Equatable, Hashable, Decodable {
    let done: Int
    let total: Int
    let tool: String
}

/// The `SETS:` marker's payload. Every field is what appkit_sets.state() documents;
/// `running` and `trunc` are optional because the marker drops the former (and adds
/// the latter) when it would otherwise cross PyMOL's feedback-line cap.
struct SetsMarker: Decodable, Equatable {
    let v: Int
    let path: String
    let active: String
    let peek: String
    let running: [String: BatchProgress]?
    let trunc: Int?
}

// MARK: - Read-only connection

/// A read-only connection to one `.raymol` file. Every method is a plain query; the
/// caller (PyMOLEngine.applySetsMarker) decides WHEN to call, which is only on a
/// version change. Not thread-safe: opened with NOMUTEX and used from the main
/// thread only, where the feedback poll runs.
final class SetsStore {
    let path: String
    private var db: OpaquePointer?

    /// Bins in the SETS-section histogram. Twelve reads as a shape at 40pt wide
    /// without becoming a bar chart the eye wants to measure.
    static let histogramBins = 12
    /// The store's own default when neither the set nor `meta.stage_budget` says
    /// (binding.DEFAULT_BUDGET). Kept equal, not read from Python, so an empty
    /// file still shows a budget.
    static let defaultStageBudget = 6

    /// nil when the file cannot be opened read-only (missing, not SQLite, no
    /// permission). A `.raymol` misnamed or half-written fails later, per query,
    /// as empty results — never as a crash in the poll.
    init?(path: String) {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        db = handle
        // A WAL writer mid-checkpoint can hold a reader off for a moment; wait
        // briefly rather than report an empty table for one tick.
        sqlite3_busy_timeout(handle, 250)
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    /// `meta.version`, or nil when the file is not a container.
    func version() -> Int? {
        guard let row = query("SELECT value FROM meta WHERE key = 'version'").first,
              case .text(let text)? = row["value"] else { return nil }
        return Int(text)
    }

    /// `meta.stage_budget`, else the store's default.
    func defaultStageBudget() -> Int {
        guard let row = query("SELECT value FROM meta WHERE key = 'stage_budget'").first,
              case .text(let text)? = row["value"], let n = Int(text), n > 0 else {
            return Self.defaultStageBudget
        }
        return n
    }

    /// Every set, in creation order, with its counts, columns and ranking histogram.
    /// `running` is merged in so a row can carry its badge without a second lookup.
    func sets(running: [String: BatchProgress] = [:]) -> [SetEntry] {
        let budgetDefault = defaultStageBudget()
        let rows = query("""
            SELECT s.id, s.name, s.kind, s.tool, s.group_name, s.budget, s.ranking_key,
                   s.sort_key, s.sort_desc, s.filter, s.columns, s.reference,
                   (SELECT count(*) FROM entries e WHERE e.set_id = s.id) AS n,
                   (SELECT count(*) FROM entries e WHERE e.set_id = s.id
                       AND e.staged_object IS NOT NULL) AS staged
            FROM sets s ORDER BY s.created, s.rowid
            """)
        return rows.compactMap { row -> SetEntry? in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            let columns = Self.decodeColumns(row.string("columns") ?? "[]")
            let rankingKey = row.string("ranking_key") ?? ""
            let ranking = columns.first { $0.column == rankingKey && $0.isScalar }
            let bins = ranking.map { self.histogram(setID: id, column: $0) } ?? []
            return SetEntry(
                id: id,
                name: name,
                kind: row.string("kind") ?? "structures",
                tool: row.string("tool") ?? "",
                count: row.int("n") ?? 0,
                stagedCount: row.int("staged") ?? 0,
                budget: row.int("budget").flatMap { $0 > 0 ? $0 : nil } ?? budgetDefault,
                groupName: row.string("group_name") ?? name,
                reference: row.string("reference") ?? "",
                rankingKey: rankingKey,
                sortKey: row.string("sort_key") ?? "",
                sortDescending: (row.int("sort_desc") ?? 1) != 0,
                filter: row.string("filter") ?? "",
                columns: columns,
                histogram: bins,
                running: running[id])
        }
    }

    /// The entries of one set in delivery order (`e.ord`), each with every scalar
    /// column the set declares. Sorting is the table model's job, locally: the
    /// whole point of reading the file is that a re-sort costs no round trip.
    func rows(setID: String, columns: [MetricColumn]) -> [SetRow] {
        guard Self.isSafeIdentifier(setID) else { return [] }
        let scalar = columns.compactMap { $0.column }.filter(Self.isSafeIdentifier)
        // Only declared, validated names are ever interpolated, and each is quoted
        // — the store enforces ^[a-z][a-z0-9_]*$ on write, and this re-checks so a
        // hand-edited file cannot turn a column name into SQL.
        let metricSelect = scalar.map { ", m.\(Self.quote($0)) AS \(Self.quote("m_" + $0))" }
            .joined()
        let sql = """
            SELECT e.id, e.name, e.ord, e.starred, e.rejected, e.pinned, e.staged_object,
                   e.n_chains, e.n_residues, e.tags, e.run_id\(metricSelect)
            FROM entries e LEFT JOIN \(Self.quote("m_" + setID)) m ON m.entry_id = e.id
            WHERE e.set_id = ? ORDER BY e.ord
            """
        return query(sql, bind: [setID]).compactMap { row -> SetRow? in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            var values: [String: MetricValue] = [:]
            for column in scalar {
                values[column] = row["m_" + column] ?? .null
            }
            return SetRow(
                id: id, name: name, ord: row.int("ord") ?? 0,
                starred: (row.int("starred") ?? 0) != 0,
                rejected: (row.int("rejected") ?? 0) != 0,
                pinned: (row.int("pinned") ?? 0) != 0,
                stagedObject: row.string("staged_object"),
                nChains: row.int("n_chains") ?? 0,
                nResidues: row.int("n_residues") ?? 0,
                tags: row.string("tags") ?? "",
                runID: row.string("run_id"),
                values: values)
        }
    }

    /// The ranking column's distribution, binned over the spec's `lo`/`hi` when it
    /// has them (so two runs of the same tool draw on the same axis) and over the
    /// observed range otherwise.
    func histogram(setID: String, column: MetricColumn) -> [Int] {
        guard let name = column.column, Self.isSafeIdentifier(name),
              Self.isSafeIdentifier(setID), column.dtype != "str" else { return [] }
        let sql = "SELECT \(Self.quote(name)) AS v FROM \(Self.quote("m_" + setID))"
            + " WHERE \(Self.quote(name)) IS NOT NULL"
        let values = query(sql).compactMap { $0["v"]?.number }
        return SetTableModel.histogram(values: values, bins: Self.histogramBins,
                                       lo: column.lo, hi: column.hi)
    }

    // MARK: Plumbing

    static func decodeColumns(_ json: String) -> [MetricColumn] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([MetricColumn].self, from: data) else {
            return []
        }
        return list
    }

    /// schema.KEY_RE, plus the `__chain` suffix column_name() produces and the
    /// hex set ids. Anything else never reaches a SQL string.
    static func isSafeIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, !s.isEmpty, s.count <= 128 else { return false }
        guard CharacterSet.letters.contains(first) || CharacterSet.decimalDigits.contains(first)
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return s.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    typealias Record = [String: MetricValue]

    /// Run one statement and return its rows keyed by result-column name. Errors
    /// (a table that is not there yet, a file mid-migration) are an empty result:
    /// the marker will fire again on the next write and the read will be retried.
    private func query(_ sql: String, bind: [String] = []) -> [Record] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        for (i, text) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), text, -1, sqliteTransient)
        }
        let n = sqlite3_column_count(stmt)
        var names: [String] = []
        for i in 0..<n {
            names.append(sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "c\(i)")
        }
        var out: [Record] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_ROW { break }
            var record: Record = [:]
            for i in 0..<n {
                let value: MetricValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    value = .number(Double(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    value = .number(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    value = sqlite3_column_text(stmt, i).map { .text(String(cString: $0)) } ?? .null
                case SQLITE_BLOB:
                    // Never selected here; blobs live in `blobs` and load lazily.
                    value = .null
                default:
                    value = .null
                }
                record[names[Int(i)]] = value
            }
            out.append(record)
        }
        return out
    }
}

/// `SQLITE_TRANSIENT` is a macro Swift does not import; this is its value.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension Dictionary where Key == String, Value == MetricValue {
    func string(_ key: String) -> String? {
        switch self[key] {
        case .text(let s)?: return s
        case .number(let d)?: return d == d.rounded() ? String(Int(d)) : String(d)
        default: return nil
        }
    }
    func int(_ key: String) -> Int? {
        switch self[key] {
        case .number(let d)?: return Int(d)
        case .text(let s)?: return Int(s)
        default: return nil
        }
    }
}

// MARK: - PyMOLEngine: the marker, and the drawer's verbs

extension PyMOLEngine {
    /// Consume one `SETS:` feedback line. Called by pollFeedback on the main
    /// thread; everything below is synchronous SQLite over a local file — a
    /// thousand-row set reads in low single-digit milliseconds — and only runs
    /// when the marker says something changed.
    func parseSetsFeedback(_ line: String) {
        guard line.hasPrefix("SETS:"),
              let data = line.dropFirst("SETS:".count).data(using: .utf8),
              let marker = try? JSONDecoder().decode(SetsMarker.self, from: data) else {
            return
        }
        applySetsMarker(marker)
    }

    /// Reopen on a path change, re-read on a version change, and publish — each
    /// assignment guarded, because the marker also fires when only the peek moved
    /// and repainting the whole table for that is exactly the per-tick cost #421
    /// forbids.
    func applySetsMarker(_ marker: SetsMarker) {
        if marker.path != setsStorePath {
            // Order matters (see the header note on advisory locks): Python has
            // already left the old file by the time it reports a new path.
            setsStore?.close()
            setsStore = nil
            setsStorePath = marker.path
            setsVersion = -1
            if !marker.path.isEmpty {
                setsStore = SetsStore(path: marker.path)
            }
        }
        let running = marker.running ?? [:]
        let versionChanged = marker.v != setsVersion
        let active: String? = marker.active.isEmpty ? nil : marker.active
        let peek: String? = marker.peek.isEmpty ? nil : marker.peek
        var nextSets = sets
        var nextRows = setRows
        if versionChanged || running != setsRunning {
            nextSets = setsStore?.sets(running: running) ?? []
        }
        if versionChanged || active != activeSetID {
            if let active, let set = nextSets.first(where: { $0.id == active }) {
                nextRows = setsStore?.rows(setID: active, columns: set.columns) ?? []
            } else {
                nextRows = []
            }
        }
        setsVersion = marker.v
        let publish = {
            if self.sets != nextSets { self.sets = nextSets }
            if self.setsRunning != running { self.setsRunning = running }
            if self.activeSetID != active {
                self.activeSetID = active
                // A set opened from Python (an MCP agent's appkit_sets.open_set, or
                // the console) shows the drawer exactly as the SETS row's click does;
                // closing is left to the user, so a set_delete does not yank the band.
                if active != nil { self.dataDrawerVisible = true }
            }
            if self.setRows != nextRows { self.setRows = nextRows }
            if self.peekedEntryID != peek { self.peekedEntryID = peek }
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    /// The set the drawer is showing, resolved against the current list.
    var activeSet: SetEntry? {
        guard let activeSetID else { return nil }
        return sets.first { $0.id == activeSetID }
    }

    // MARK: verbs
    //
    // Every action is a public `set_*` command or an appkit_sets helper that wraps
    // one; Swift never writes the file (#421: "every drawer action has a set_*
    // command"). Names are the store's own — set names share the MSA alphabet and
    // entry names refuse `+` and `:` — so quoting them is stripping the one
    // character that could close a Python string.

    private func pyQuoted(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "") + "'"
    }

    /// Show `set` in the drawer. Optimistic: the marker confirms within a poll
    /// tick, but the rows are read now so the table does not flash empty first.
    func openSet(_ set: SetEntry) {
        activeSetID = set.id
        setRows = setsStore?.rows(setID: set.id, columns: set.columns) ?? []
        dataDrawerVisible = true
        runPythonQuiet("from pymol import appkit_sets as _s\n_s.open_set(\(pyQuoted(set.name)))")
    }

    func closeDataDrawer() {
        dataDrawerVisible = false
        peekedEntryID = nil
        runPython("from pymol import appkit_sets as _s\n_s.close_set()")
    }

    /// `set_peek set, entry` through the helper that records WHICH entry, so the
    /// row can show ◐. runPython, not Quiet: this draws.
    func peekEntry(_ set: SetEntry, _ row: SetRow) {
        peekedEntryID = row.id
        runPython("from pymol import appkit_sets as _s\n_s.peek(\(pyQuoted(set.name)), \(pyQuoted(row.name)))")
    }

    func clearPeek() {
        guard peekedEntryID != nil else { return }
        peekedEntryID = nil
        runPython("from pymol import appkit_sets as _s\n_s.clear_peek()")
    }

    /// Space: stage the entries if none is staged, else unstage them. A budget
    /// refusal is a console warning naming what to unstage, not an exception.
    func toggleStage(_ set: SetEntry, _ rows: [SetRow]) {
        guard let selector = Self.entrySelector(rows) else { return }
        runPython("from pymol import appkit_sets as _s\n_s.toggle_stage(\(pyQuoted(set.name)), \(pyQuoted(selector)))")
    }

    func stage(_ set: SetEntry, _ rows: [SetRow]) {
        guard let selector = Self.entrySelector(rows.filter { !$0.isStaged }) else { return }
        runPython("from pymol import appkit_sets as _s\n_s.toggle_stage(\(pyQuoted(set.name)), \(pyQuoted(selector)))")
    }

    func unstage(_ set: SetEntry, _ rows: [SetRow]) {
        guard let selector = Self.entrySelector(rows.filter { $0.isStaged }) else { return }
        runPython("from pymol import cmd as _c\n_c.set_unstage(\(pyQuoted(set.name)), \(pyQuoted(selector)))")
    }

    func setStar(_ set: SetEntry, _ rows: [SetRow], on: Bool) {
        guard let selector = Self.entrySelector(rows) else { return }
        runPythonQuiet("from pymol import cmd as _c\n_c.set_star(\(pyQuoted(set.name)), \(pyQuoted(selector)), \(on ? 1 : 0))")
    }

    func setReject(_ set: SetEntry, _ rows: [SetRow], on: Bool) {
        guard let selector = Self.entrySelector(rows) else { return }
        runPythonQuiet("from pymol import cmd as _c\n_c.set_reject(\(pyQuoted(set.name)), \(pyQuoted(selector)), \(on ? 1 : 0))")
    }

    /// Pin only applies to staged entries; the command refuses the others, so they
    /// are filtered here rather than producing a console error per click.
    func setPin(_ set: SetEntry, _ rows: [SetRow], on: Bool) {
        guard let selector = Self.entrySelector(rows.filter { $0.isStaged }) else { return }
        runPythonQuiet("from pymol import cmd as _c\n_c.set_pin(\(pyQuoted(set.name)), \(pyQuoted(selector)), \(on ? 1 : 0))")
    }

    /// A header click. `set_sort` also makes a metric column the set's ranking
    /// key, so the SETS-section histogram follows the sort the user chose.
    func setSort(_ set: SetEntry, key: String, descending: Bool) {
        guard SetsStore.isSafeIdentifier(key) else { return }
        runPythonQuiet("from pymol import cmd as _c\n_c.set_sort(\(pyQuoted(set.name)), '\(key)', \(descending ? 1 : 0))")
    }

    /// Paths go through a raw triple-quoted literal, the same way saveSession's do.
    func exportSet(_ set: SetEntry, to path: String, rows: [SetRow]) {
        let selector = Self.entrySelector(rows) ?? "all"
        let safePath = path.replacingOccurrences(of: "'''", with: "")
        runPython("from pymol import cmd as _c\n_c.set_export(\(pyQuoted(set.name)), r'''\(safePath)''', \(pyQuoted(selector)))")
    }

    func saveSetView(_ set: SetEntry, named view: String) {
        let clean = view.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        runPythonQuiet("from pymol import cmd as _c\n_c.set_view_save(\(pyQuoted(set.name)), \(pyQuoted(clean)))")
    }

    /// `a+b+c` — the selector language's several-by-name form (spec §4.1). Entry
    /// names cannot contain `+`, by the store's own rule.
    static func entrySelector(_ rows: [SetRow]) -> String? {
        let names = rows.map(\.name).filter { !$0.isEmpty && !$0.contains("+") }
        return names.isEmpty ? nil : names.joined(separator: "+")
    }
}
