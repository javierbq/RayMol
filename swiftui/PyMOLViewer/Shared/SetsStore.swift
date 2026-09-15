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
    /// Entry ids this came from (`entries.parents`). Cheap text, read with the row
    /// because the Plot tab colours by parent (#418) and the Lineage tab (#419) will
    /// want it; the STRUCTURES and arrays those parents point at stay lazy.
    let parents: [String]
    let values: [String: MetricValue]

    init(id: String, name: String, ord: Int, starred: Bool, rejected: Bool,
         pinned: Bool, stagedObject: String?, nChains: Int, nResidues: Int,
         tags: String, runID: String?, values: [String: MetricValue],
         parents: [String] = []) {
        self.id = id
        self.name = name
        self.ord = ord
        self.starred = starred
        self.rejected = rejected
        self.pinned = pinned
        self.stagedObject = stagedObject
        self.nChains = nChains
        self.nResidues = nResidues
        self.tags = tags
        self.runID = runID
        self.parents = parents
        self.values = values
    }

    var isStaged: Bool { stagedObject != nil }
    /// The first tag, which is what a categorical colour uses; "" when untagged.
    var firstTag: String { tags.split(separator: " ").first.map(String.init) ?? "" }
    func value(_ column: MetricColumn) -> MetricValue {
        guard let name = column.column else { return .null }
        return values[name] ?? .null
    }
}

/// One saved view: a named filter + sort + visible-column list over a set (#418,
/// spec §4.2 "Save as View"). A view is also an ENTRY SELECTOR — `view:<name>` — so
/// the same name that applies it in the drawer feeds `predict set:<set>@view:<name>`
/// and every other `set_*` command.
struct SetView: Identifiable, Equatable, Hashable {
    let name: String
    let filter: String
    let sortKey: String
    let sortDescending: Bool
    /// The columns the drawer should show. Empty means "whatever is showing": a view
    /// saved before this list existed must not blank the table.
    let columns: [String]

    var id: String { name }

    init(name: String, filter: String = "", sortKey: String = "",
         sortDescending: Bool = true, columns: [String] = []) {
        self.name = name
        self.filter = filter
        self.sortKey = sortKey
        self.sortDescending = sortDescending
        self.columns = columns
    }

    /// What the row's tooltip says it will do.
    var summary: String {
        var parts: [String] = []
        parts.append(filter.isEmpty ? "no filter" : filter)
        if !sortKey.isEmpty { parts.append("sorted by \(sortKey) \(sortDescending ? "↓" : "↑")") }
        if !columns.isEmpty { parts.append("\(columns.count) columns") }
        return parts.joined(separator: " · ")
    }
}

/// A batch still landing in a set (#416's `pymol.sets.batch.running()`), as the
/// marker forwards it. `total` may be 0 while a job has not sized itself yet.
struct BatchProgress: Equatable, Hashable, Decodable {
    let done: Int
    let total: Int
    let tool: String

    /// A batch known to be running, with nothing else known: the marker dropped the
    /// counts to stay under the feedback-line cap and sent bare ids.
    static let unknown = BatchProgress(done: 0, total: 0, tool: "")

    init(done: Int, total: Int, tool: String) {
        self.done = done
        self.total = total
        self.tool = tool
    }
}

/// The `SETS:` marker's payload. Every field is what appkit_sets.state() documents.
///
/// `running` arrives in TWO shapes, and both have to decode or the whole marker is
/// dropped and the drawer freezes on its last state:
///
///   * `{"<set id>": {"done": n, "total": n, "tool": "..."}}` — the normal case.
///   * `["<set id>", ...]` — the counts were dropped to keep the line under PyMOL's
///     feedback-line cap (`trunc` is then 1). The badge still belongs on those rows;
///     it just cannot show numbers.
///
/// Normalised here into one dictionary, with a zeroed `BatchProgress` for the ids,
/// so nothing downstream has to know which shape arrived — `truncated` is what the
/// badge reads to keep it from rendering a confident "0 / 0".
struct SetsMarker: Decodable, Equatable {
    let v: Int
    let path: String
    let active: String
    let peek: String
    let running: [String: BatchProgress]
    /// Entry ids of the active set whose STAGED OBJECT holds atoms of `sele`, so a
    /// click in the viewport can select and scroll to its row (#418). Absent — the
    /// normal case — when nothing staged is selected.
    let sel: [String]
    let trunc: Int?

    var truncated: Bool { (trunc ?? 0) != 0 }

    private enum CodingKeys: String, CodingKey {
        case v, path, active, peek, running, sel, trunc
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        path = try c.decode(String.self, forKey: .path)
        active = try c.decode(String.self, forKey: .active)
        peek = try c.decode(String.self, forKey: .peek)
        trunc = try? c.decodeIfPresent(Int.self, forKey: .trunc)
        sel = (try? c.decodeIfPresent([String].self, forKey: .sel)) ?? []
        if let detailed = try? c.decodeIfPresent([String: BatchProgress].self, forKey: .running) {
            running = detailed
        } else if let ids = try? c.decodeIfPresent([String].self, forKey: .running) {
            running = Dictionary(ids.map { ($0, BatchProgress.unknown) },
                                 uniquingKeysWith: { a, _ in a })
        } else {
            running = [:]
        }
    }

    /// For tests and previews.
    init(v: Int, path: String, active: String = "", peek: String = "",
         running: [String: BatchProgress] = [:], sel: [String] = [],
         trunc: Int? = nil) {
        self.v = v
        self.path = path
        self.active = active
        self.peek = peek
        self.running = running
        self.sel = sel
        self.trunc = trunc
    }
}

// MARK: - The compiled filter (#418)

/// What `pymol.sets.filter.compile` made of an expression, as `appkit_sets` writes it
/// to the filter channel.
///
/// The whole point is the `sql` field. There is ONE filter grammar and it is Python's;
/// the drawer sends the string it composed and gets back the parameterised fragment the
/// grammar produced, which this side binds and runs. That is why a brush, a typed
/// expression, a saved view and an MCP `set_filter` cannot mean four different things.
///
/// `params` arrive as a JSON array of numbers and strings — the values `filter.py`
/// bound — and are decoded into `MetricValue` so they can be bound back in the same
/// order. Nothing is ever spliced into SQL text on either side.
struct SetFilterPayload: Decodable, Equatable {
    let set: String
    let expr: String
    let sql: String
    let params: [MetricValue]
    let n: Int
    let total: Int
    let error: String
    let offset: Int
    let applied: Int

    private enum CodingKeys: String, CodingKey {
        case set, expr, sql, params, n, total, error, offset, applied
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        set = try c.decode(String.self, forKey: .set)
        expr = (try? c.decodeIfPresent(String.self, forKey: .expr)) ?? ""
        sql = (try? c.decodeIfPresent(String.self, forKey: .sql)) ?? ""
        n = (try? c.decodeIfPresent(Int.self, forKey: .n)) ?? 0
        total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
        error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? ""
        offset = (try? c.decodeIfPresent(Int.self, forKey: .offset)) ?? -1
        applied = (try? c.decodeIfPresent(Int.self, forKey: .applied)) ?? 0
        var values: [MetricValue] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .params) {
            while !list.isAtEnd {
                if let d = try? list.decode(Double.self) {
                    values.append(.number(d))
                } else if let t = try? list.decode(String.self) {
                    values.append(.text(t))
                } else if let b = try? list.decode(Bool.self) {
                    values.append(.number(b ? 1 : 0))
                } else {
                    _ = try? list.decode(AnyNull.self)
                    values.append(.null)
                }
            }
        }
        params = values
    }

    private struct AnyNull: Decodable {}
}

/// The drawer's filter, as the drawer holds it: the expression it sent, what Python
/// said about it, and enough to draw the count and the error.
struct SetFilterState: Equatable {
    var setID = ""
    var expression = ""
    var fragment = ""
    var params: [MetricValue] = []
    /// How many entries match, from Python — the authority, and what the count reads.
    var matched = 0
    var total = 0
    /// `SetFilterError.message`, already stripped of CmdException's " Error: " prefix.
    var error = ""
    /// Where in `expression` the parser stopped, or -1.
    var offset = -1
    /// True when this is the set's PERSISTED filter (a `set_filter`), false for a
    /// preview of something being typed or dragged.
    var applied = false

    var isActive: Bool { !fragment.isEmpty && error.isEmpty }

    /// "212 of 1024 match" — spec §4.2.
    func countLabel(total totalRows: Int) -> String {
        guard isActive else { return "\(totalRows) entries" }
        return "\(matched) of \(total) match"
    }

    /// The token at `offset`, so an error can quote back the thing it tripped on.
    /// nil when the offset is past the end — an "end of input" failure has no token,
    /// and inventing one would point at the wrong character.
    static func token(in text: String, at offset: Int) -> String? {
        guard offset >= 0, offset < text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: offset)
        let token = text[start...].prefix { !$0.isWhitespace }
        return token.isEmpty ? nil : String(token)
    }

    init() {}

    init(payload: SetFilterPayload) {
        setID = payload.set
        expression = payload.expr
        fragment = payload.sql
        params = payload.params
        matched = payload.n
        total = payload.total
        error = payload.error
        offset = payload.offset
        applied = payload.applied != 0
    }
}

// MARK: - Cold-launch recovery (#447)

/// One container a previous RayMol left behind, from the `SETSRECOVER:` marker
/// (`pymol.appkit_sets.recovery_payload`). Spec §2.1: the working file for an
/// untitled session IS the autosave, so this is the app's "you have unsaved work"
/// record — a whole session's sets, and usually the scene with them.
struct RecoverableContainer: Decodable, Equatable, Identifiable, Hashable {
    /// Absolute path of the preserved `.raymol`. Also the identity: there is one
    /// row per file, and the file names carry a timestamp and the dead pid.
    let path: String
    let sets: Int
    let entries: Int
    /// 1 when the container carries a session blob — a quit checkpointed the scene
    /// into it. 0 after a crash, where the entries survived and the camera did not.
    let session: Int
    /// Unix time of the file's last write.
    let modified: Double

    var id: String { path }
    var carriesSession: Bool { session != 0 }
    var date: Date { Date(timeIntervalSince1970: modified) }

    init(path: String, sets: Int, entries: Int, session: Int = 0, modified: Double = 0) {
        self.path = path
        self.sets = sets
        self.entries = entries
        self.session = session
        self.modified = modified
    }
}

/// The `SETSRECOVER:` payload: the newest few containers, plus how many there are.
/// `n` can exceed `files.count` — the marker drops files, never the count, to stay
/// under PyMOL's feedback-line cap (appkit_sets.recovery_marker).
struct SetsRecoveryMarker: Decodable, Equatable {
    let n: Int
    let files: [RecoverableContainer]

    init(n: Int, files: [RecoverableContainer]) {
        self.n = n
        self.files = files
    }
}

/// What a cold launch should do about work the last run left behind.
enum LaunchRestore: Equatable {
    /// Start empty: nothing was left, or the launch is opening a specific document.
    case nothing
    /// Reload the rolling `autosave.pse` (iOS today; macOS has no autosave).
    case autosave
    /// Ask the user about a preserved `.raymol` before the window is used.
    case offerRecovery(RecoverableContainer)
}

extension PyMOLEngine {
    /// The launch decision, as a pure function so the policy can be tested without a
    /// window, an alert or a running core (#447).
    ///
    /// The rules, in order, and why:
    ///
    /// 1. **A document being opened wins.** Double-clicking a file, or `open x.pdb`,
    ///    says what this launch is for; putting a recovery alert in front of it would
    ///    be answering a question the user did not ask. What was preserved is still
    ///    preserved, and is offered on the next plain launch.
    /// 2. **A recoverable `.raymol` beats `autosave.pse`.** The container carries the
    ///    session blob too (`checkpoint_session` writes it on the way out), so
    ///    recovering it restores the scene AND the sets, where the `.pse` restores the
    ///    scene and silently drops hours of design results — which is issue #447
    ///    itself. When the container carries no session (a crash before the
    ///    checkpoint), recovering it still costs only the camera.
    /// 3. **Declining falls back to the autosave**, so Discard/Keep on macOS (where
    ///    there is no autosave) leaves an empty session, and on iOS resumes the scene.
    /// 4. Only a container that actually holds entries is offered: an empty one is
    ///    deleted at exit and never reaches here, and if one ever did, "recover 0
    ///    designs" is not a question worth a modal.
    static func launchRestore(recoverable: [RecoverableContainer],
                              autosavePresent: Bool,
                              openRequested: Bool,
                              recoveryDeclined: Bool = false) -> LaunchRestore {
        if openRequested { return .nothing }
        if !recoveryDeclined,
           let best = recoverable.filter({ $0.entries > 0 })
               .max(by: { $0.modified < $1.modified }) {
            return .offerRecovery(best)
        }
        return autosavePresent ? .autosave : .nothing
    }
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
        let views = viewsBySet()
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
                views: views[id] ?? [],
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
                   e.n_chains, e.n_residues, e.tags, e.run_id, e.parents\(metricSelect)
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
                values: values,
                parents: Self.decodeParents(row.string("parents") ?? "[]"))
        }
    }

    /// The entry ids a compiled filter fragment matches, or nil when the fragment
    /// could not even be prepared (#418).
    ///
    /// The fragment and its params come from `pymol.sets.filter.compile`, over the
    /// channel `appkit_sets` writes — Swift never decides what an expression means, it
    /// binds what the grammar produced. The FROM and the two aliases are the ones
    /// `rows()` uses above and the ones `filter.py` documents (`e` = entries, `m` = the
    /// set's wide table), so the predicate lands on exactly the rows the table holds.
    ///
    /// nil, not an empty set, on a prepare failure: "nothing matches" and "I could not
    /// ask" are different answers, and showing an empty table for the second one would
    /// claim a thousand candidates had been filtered away.
    func matchingIDs(setID: String, fragment: String, params: [MetricValue]) -> Set<String>? {
        guard Self.isSafeIdentifier(setID) else { return nil }
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sql = """
            SELECT e.id FROM entries e
            LEFT JOIN \(Self.quote("m_" + setID)) m ON m.entry_id = e.id
            WHERE e.set_id = ? AND (\(trimmed))
            """
        guard let rows = queryBound(sql, bind: [.text(setID)] + params) else { return nil }
        return Set(rows.compactMap { record -> String? in
            if case .text(let id)? = record["id"] { return id }
            return nil
        })
    }

    /// Every saved view, by set id. One query for the whole file: a set has a handful
    /// of views and this runs only when the container's version moved.
    func viewsBySet() -> [String: [SetView]] {
        var out: [String: [SetView]] = [:]
        for row in query("""
            SELECT set_id, name, filter, sort_key, sort_desc, columns
            FROM views ORDER BY set_id, created, rowid
            """) {
            guard let setID = row.string("set_id"), let name = row.string("name") else { continue }
            out[setID, default: []].append(SetView(
                name: name,
                filter: row.string("filter") ?? "",
                sortKey: row.string("sort_key") ?? "",
                sortDescending: (row.int("sort_desc") ?? 1) != 0,
                columns: Self.decodeParents(row.string("columns") ?? "[]")))
        }
        return out
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

    /// A JSON list of strings (`entries.parents`, `views.columns`) — [] on anything
    /// this build does not recognise, for the reason MetricColumn decodes leniently:
    /// one strict field must not cost the whole row.
    static func decodeParents(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

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

    /// `query`, but binding typed values (a filter fragment's params are numbers as
    /// often as text) and reporting a prepare failure as nil rather than as no rows.
    private func queryBound(_ sql: String, bind: [MetricValue]) -> [Record]? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s):
                sqlite3_bind_text(stmt, index, s, -1, sqliteTransient)
            case .number(let v):
                // An integral literal binds as INTEGER so a comparison against an int
                // column keeps its type; SQLite compares the two numerically either
                // way, but a REAL bound against a TEXT-affinity column would not.
                if v == v.rounded(), abs(v) < 9.2e18 {
                    sqlite3_bind_int64(stmt, index, Int64(v))
                } else {
                    sqlite3_bind_double(stmt, index, v)
                }
            case .null:
                sqlite3_bind_null(stmt, index)
            }
        }
        var out: [Record] = []
        let n = sqlite3_column_count(stmt)
        var names: [String] = []
        for i in 0..<n {
            names.append(sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "c\(i)")
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            var record: Record = [:]
            for i in 0..<n {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    record[names[Int(i)]] = .number(Double(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT:
                    record[names[Int(i)]] = .number(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT:
                    record[names[Int(i)]] = sqlite3_column_text(stmt, i)
                        .map { .text(String(cString: $0)) } ?? .null
                default:
                    record[names[Int(i)]] = .null
                }
            }
            out.append(record)
        }
        return out
    }

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
        // The marker drops the COUNTS before it drops the sets (appkit_sets.marker),
        // so a truncated line still says which sets are busy as a list of ids, which
        // the decode above has already normalised; `truncated` is what stops the
        // badge from rendering "0 / 0" as though it knew.
        let running = marker.running
        let truncated = marker.truncated
        let versionChanged = marker.v != setsVersion
        let active: String? = marker.active.isEmpty ? nil : marker.active
        let peek: String? = marker.peek.isEmpty ? nil : marker.peek
        var nextSets = sets
        var nextRows = setRows
        var rowsChanged = false
        if versionChanged || running != setsRunning {
            nextSets = setsStore?.sets(running: running) ?? []
        }
        if versionChanged || active != activeSetID {
            if let active, let set = nextSets.first(where: { $0.id == active }) {
                nextRows = setsStore?.rows(setID: active, columns: set.columns) ?? []
            } else {
                nextRows = []
            }
            rowsChanged = true
        }
        // The histograms the header brushes and the plot's axis strips draw from are
        // recomputed HERE — once per change — rather than per render (#418).
        let nextHistograms: [String: SetColumnHistogram]? = rowsChanged
            ? Self.histograms(rows: nextRows,
                              columns: active.flatMap { id in
                                  nextSets.first { $0.id == id }?.columns } ?? [])
            : nil
        let viewportSelection = marker.sel
        setsVersion = marker.v
        let publish = {
            if self.sets != nextSets { self.sets = nextSets }
            if self.setsRunning != running { self.setsRunning = running }
            if self.setsRunningTruncated != truncated { self.setsRunningTruncated = truncated }
            if self.activeSetID != active {
                self.activeSetID = active
                // A set opened from Python (or closed under us) starts with a fresh
                // filter, selection and column choice, for the reason the peek is
                // cleared below: none of it is about the set now showing.
                self.resetSetUIState()
                // A set opened from Python (an MCP agent's appkit_sets.open_set, or
                // the console) shows the drawer exactly as the SETS row's click does;
                // closing is left to the user, so a set_delete does not yank the band.
                // In a window too short for a table this surfaces as the one-line
                // "needs more room" hint rather than a band that draws nothing
                // (macDrawerBand), so it never costs the viewport a table's worth of
                // height for no table.
                if active != nil { self.dataDrawerVisible = true }
            }
            if self.setRows != nextRows { self.setRows = nextRows }
            if let nextHistograms, self.setHistograms != nextHistograms {
                self.setHistograms = nextHistograms
            }
            if self.peekedEntryID != peek { self.peekedEntryID = peek }
            if self.setViewportSelection != viewportSelection {
                self.setViewportSelection = viewportSelection
            }
            // Entries that landed while a batch runs have to fall on the right side of
            // the active filter without another round trip to Python — which is the
            // reason the fragment, not a row list, is what comes over the channel.
            if rowsChanged { self.refreshFilterMatches() }
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    // MARK: recovery (#447)

    /// Consume the one `SETSRECOVER:` line printed at launch.
    func parseSetsRecoveryFeedback(_ line: String) {
        let prefix = "SETSRECOVER:"
        guard line.hasPrefix(prefix),
              let data = line.dropFirst(prefix.count).data(using: .utf8),
              let marker = try? JSONDecoder().decode(SetsRecoveryMarker.self, from: data) else {
            return
        }
        applyRecoveryMarker(marker)
    }

    /// Turn the marker into the launch decision and publish it. The POLICY is
    /// `launchRestore`, which is pure and tested; this only applies its answer, so
    /// the rule cannot quietly diverge between the alert and the test.
    func applyRecoveryMarker(_ marker: SetsRecoveryMarker) {
        let decision = Self.launchRestore(recoverable: marker.files,
                                          autosavePresent: Self.autosavePresentAtLaunch,
                                          openRequested: launchOpenRequested,
                                          recoveryDeclined: recoveryAnswered)
        let publish = {
            switch decision {
            case .offerRecovery(let file):
                self.recoveryCount = max(marker.n, marker.files.count)
                self.recoveryOffer = file
            case .autosave, .nothing:
                // On macOS `.autosave` cannot happen (there is no autosave.pse) and
                // `.nothing` means the launch already has a job; either way the
                // container stays on disk under the retention policy and is offered
                // on a later launch. Nothing is deleted by NOT answering.
                self.recoveryOffer = nil
            }
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    /// The user answered. Called by all three buttons, so no answer can leave the
    /// offer armed for a second alert later in the process.
    func clearRecoveryOffer() {
        recoveryAnswered = true
        recoveryOffer = nil
        recoveryCount = 0
    }

    /// Discard: the container is deleted, through the store, which refuses any path
    /// that is not one of its own preserved files.
    func discardRecovery(_ file: RecoverableContainer) {
        runPython("from pymol import appkit_sets as _as\n"
                  + "_as.discard_recovered(\(Self.pythonLiteral(file.path)))")
        clearRecoveryOffer()
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

    /// `name` as a single-quoted Python string literal, ESCAPED, not stripped.
    ///
    /// Stripping was a real bug (#417 review): the store's name rules refuse quotes
    /// and whitespace but allow a BACKSLASH, so an entry named `a\\b` — which
    /// `set_import` of `a\\b.cif` produces — had its backslash deleted and every
    /// verb then ran against `ab`. That is a SetNotFound traceback at best, and if
    /// the set also holds an entry named `ab`, the wrong entry is starred, rejected
    /// or unstaged, which deletes the wrong object. Escaping cannot lose a
    /// character, so the name that leaves here is the name the store has.
    static func pythonLiteral(_ name: String) -> String {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")   // first: it would double the others
            .replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }

    private func pyQuoted(_ name: String) -> String { Self.pythonLiteral(name) }

    /// Show `set` in the drawer. Optimistic: the marker confirms within a poll
    /// tick, but the rows are read now so the table does not flash empty first.
    func openSet(_ set: SetEntry) {
        // The previous set's ghost is not part of this one: leaving it up would
        // draw an entry that is in no visible row, with peekedEntryID pointing
        // outside setRows so nothing shows ◐ either.
        if set.id != activeSetID {
            clearPeek()
            resetSetUIState()
        }
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

    /// Esc's rung for the Data drawer (#417), returning true when there was a peek
    /// to clear.
    ///
    /// A rung on ContentView's Esc ladder rather than an `.onKeyPress` in the
    /// drawer: the Esc monitor is an `NSEvent` local monitor that consumes keyCode
    /// 53 ahead of the responder chain, so a SwiftUI key handler in the table never
    /// runs (the first version of this shipped as dead code, caught in review).
    /// Going through the ladder also makes it work wherever the focus is, which is
    /// the behaviour a ghost on screen deserves.
    @discardableResult
    func clearPeekIfShowing() -> Bool {
        guard peekedEntryID != nil else { return false }
        clearPeek()
        return true
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

    /// `a+b+c` — the selector language's several-by-name form (spec §4.1). Entry
    /// names cannot contain `+`, by the store's own rule.
    static func entrySelector(_ rows: [SetRow]) -> String? {
        let names = rows.map(\.name).filter { !$0.isEmpty && !$0.contains("+") }
        return names.isEmpty ? nil : names.joined(separator: "+")
    }

    // MARK: - Filters (#418)

    /// Consume one `SETSFILTER:` line: the compiled fragment for an expression the
    /// drawer sent, or for one a console/MCP `set_filter` applied under it.
    ///
    /// File-backed for the reason the object list is (#231): a long expression compiles
    /// to a fragment longer than PyMOL's 1024-byte feedback line, and a filter that
    /// stops working past some length is not a behaviour anyone could explain.
    func parseSetsFilterFeedback(_ line: String) {
        guard line.hasPrefix("SETSFILTER:") else { return }
        let path = TempChannel.path(TempChannel.Stem.setsFilter)
        guard let data = FileManager.default.contents(atPath: path),
              let payload = try? JSONDecoder().decode(SetFilterPayload.self, from: data)
        else { return }
        applySetsFilter(payload)
    }

    func applySetsFilter(_ payload: SetFilterPayload) {
        let publish = {
            // A payload for a set the drawer has since left is not ours: applying it
            // would filter the NEW set's rows by the OLD set's expression.
            guard payload.set == self.activeSetID else { return }
            let state = SetFilterState(payload: payload)
            if self.setFilter != state { self.setFilter = state }
            self.refreshFilterMatches()
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    /// Run the compiled fragment over this set's rows. Cheap and local — one indexed
    /// query over a file already open — which is what lets the table re-filter when
    /// entries land rather than asking Python again per delivery.
    func refreshFilterMatches() {
        guard let setID = activeSetID, setFilter.setID == setID,
              setFilter.error.isEmpty, !setFilter.fragment.isEmpty else {
            if setFilterMatches != nil { setFilterMatches = nil }
            return
        }
        let matches = setsStore?.matchingIDs(setID: setID, fragment: setFilter.fragment,
                                             params: setFilter.params)
        if matches == nil {
            // Could not even prepare it. Show every row and say so, rather than an
            // empty table that reads as "your filter excluded everything".
            setFilter.error = "This build could not apply the compiled filter; every"
                + " entry is shown. The set_* commands still use it."
        }
        if setFilterMatches != matches { setFilterMatches = matches }
    }

    /// The rows the drawer shows: the active set's entries under the active filter.
    /// The Table tab and the Plot tab read THIS, so they cannot disagree (spec §4.3).
    var filteredSetRows: [SetRow] {
        guard let matches = setFilterMatches else { return setRows }
        return setRows.filter { matches.contains($0.id) }
    }

    /// Everything about the drawer that belongs to one set and must not follow the
    /// user into the next one.
    func resetSetUIState() {
        setFilterText = ""
        setBrushes = []
        setFilter = SetFilterState()
        setFilterMatches = nil
        setSelection = []
        setViewportSelection = []
        setHiddenColumns = []
        dataDrawerTab = .table
    }

    /// Set or clear one column's brush and push the composed expression.
    ///
    /// `commit` is the difference between a drag in progress and a drag that ended: a
    /// live drag only PREVIEWS (no write, so no version bump and no re-read of a
    /// thousand rows per pixel), and letting go applies it with `set_filter`, which is
    /// what makes it the filter every `set_*` command and every MCP call then sees.
    func updateBrush(_ set: SetEntry, _ brush: SetBrush?, column: String, commit: Bool) {
        var next = setBrushes.filter { $0.column != column }
        if let brush { next.append(brush) }
        pushBrushes(set, next, commit: commit)
    }

    /// Replace every brush at once — "Filter to selection" in the Plot tab.
    func updateBrushes(_ set: SetEntry, _ brushes: [SetBrush]) {
        pushBrushes(set, brushes, commit: true)
    }

    private func pushBrushes(_ set: SetEntry, _ brushes: [SetBrush], commit: Bool) {
        setBrushes = brushes
        let composed = SetFilterComposer.compose(text: setFilterText, brushes: brushes)
        if commit {
            applySetFilter(set, composed.expression)
        } else {
            previewSetFilter(set, composed.expression)
        }
    }

    /// Ask Python what an expression means WITHOUT applying it: every keystroke and
    /// every step of a histogram drag. No write, so no version bump and no re-read of
    /// a thousand rows per pixel.
    func previewSetFilter(_ set: SetEntry, _ expression: String) {
        runPythonQuiet("from pymol import appkit_sets as _s\n"
                       + "_s.preview_filter(\(pyQuoted(set.name)), \(Self.pythonLiteral(expression)))")
    }

    /// `set_filter` — the expression becomes the set's, which is what `filtered`,
    /// `top:N`, `set_export` and `predict set:x@filtered` all read.
    func applySetFilter(_ set: SetEntry, _ expression: String) {
        runPythonQuiet("from pymol import appkit_sets as _s\n"
                       + "_s.apply_filter(\(pyQuoted(set.name)), \(Self.pythonLiteral(expression)))")
    }

    // MARK: - Saved views (#418)

    /// Save the active filter, the active sort and the visible columns as a view.
    /// Columns go as a `+`-joined list, the separator the selector language already
    /// uses, so nothing has to be quoted inside the literal.
    func saveSetView(_ set: SetEntry, named view: String, columns: [String]) {
        let clean = view.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let list = columns.filter { SetsStore.isSafeIdentifier($0) }.joined(separator: "+")
        runPythonQuiet("from pymol import cmd as _c\n"
                       + "_c.set_view_save(\(pyQuoted(set.name)), \(pyQuoted(clean)),"
                       + " columns=\(Self.pythonLiteral(list)))")
    }

    /// Apply a view: its filter and sort become the set's, through `set_filter` and
    /// `set_sort`, so the console and an MCP agent see the same state the drawer does.
    /// The COLUMN list is applied here, because which columns are on screen is the
    /// drawer's business and the store has no opinion about it.
    func applySetView(_ set: SetEntry, _ view: SetView) {
        setFilterText = view.filter
        setBrushes = []
        if !view.columns.isEmpty {
            let visible = Set(view.columns)
            setHiddenColumns = Set(set.columns.compactMap(\.column)
                                    .filter { !visible.contains($0) })
        }
        runPythonQuiet("from pymol import appkit_sets as _s\n"
                       + "_s.apply_view(\(pyQuoted(set.name)), \(pyQuoted(view.name)))")
    }

    func deleteSetView(_ set: SetEntry, _ view: SetView) {
        runPythonQuiet("from pymol import cmd as _c\n"
                       + "_c.set_view_delete(\(pyQuoted(set.name)), \(pyQuoted(view.name)))")
    }

    // MARK: - Send to ▾ (#418)

    /// `predict <predictor>, set:<name>@<selector>` — #416's set input. The child set
    /// with its parent links is `predict`'s own job; this only names the input.
    func sendSetToPredict(_ set: SetEntry, selector: String, predictor: String) {
        let input = "\(SetSendTarget.setPrefix)\(set.name)@\(selector)"
        runCommand("predict \(predictor), \(input)")
    }
}

/// What a Send to ▾ item acts on: the rows the user picked, the active filter, or a
/// saved view. All three are ENTRY SELECTORS (spec §4.1), which is the whole reason
/// the menu can hand any of them to any tool that takes a set.
enum SetSendTarget: Equatable {
    case selection([String])      // entry names
    case filtered
    case view(String)

    static let setPrefix = "set:"

    /// The selector string. `filtered` is the default every `set_*` command already
    /// takes, so an empty selection falls back to it rather than to nothing.
    var selector: String {
        switch self {
        case .selection(let names):
            let usable = names.filter { !$0.isEmpty && !$0.contains("+") }
            return usable.isEmpty ? "filtered" : usable.joined(separator: "+")
        case .filtered:
            return "filtered"
        case .view(let name):
            return "view:\(name)"
        }
    }

    var label: String {
        switch self {
        case .selection(let names): return "\(names.count) selected"
        case .filtered: return "the filter"
        case .view(let name): return "view \(name)"
        }
    }
}

/// Which tab of the Data drawer is showing. Table and Plot ship in #418; Sequences
/// and Lineage are #419 and are drawn disabled rather than hidden, so the drawer's
/// shape is learned once (spec §4).
enum DataDrawerTab: String, CaseIterable, Identifiable, Equatable {
    case table = "Table"
    case plot = "Plot"
    case sequences = "Sequences"
    case lineage = "Lineage"

    var id: String { rawValue }
    var isAvailable: Bool { self == .table || self == .plot }

    var help: String {
        switch self {
        case .table: return "Entries as rows; columns come from the set's metrics"
        case .plot: return "One scatter over the same filtered rows; brush to select"
        case .sequences: return "Coming when the sequence strip moves here (#419)"
        case .lineage: return "Coming with the Sequences tab (#419)"
        }
    }
}

extension PyMOLEngine {
    /// One histogram per scalar numeric column, over every row of the set — not the
    /// filtered ones, so brushing a column does not collapse the shape you are
    /// brushing on. Binned over the spec's domain when it has one, which is what makes
    /// two runs of the same tool comparable.
    static func histograms(rows: [SetRow],
                           columns: [MetricColumn]) -> [String: SetColumnHistogram] {
        var out: [String: SetColumnHistogram] = [:]
        for column in columns where column.isScalar && column.dtype != "str" {
            guard let name = column.column else { continue }
            let values = rows.compactMap { $0.values[name]?.number }
            guard let domain = SetTableModel.histogramDomain(values: values,
                                                             lo: column.lo, hi: column.hi)
            else { continue }
            out[name] = SetColumnHistogram(
                bins: SetTableModel.histogram(values: values, bins: SetsStore.histogramBins,
                                              lo: column.lo, hi: column.hi),
                lo: domain.lowerBound, hi: domain.upperBound)
        }
        return out
    }
}
