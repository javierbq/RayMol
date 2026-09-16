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

// MARK: - Residue arrays (#419)

/// One residue-scope metric of one entry, decoded from its blob.
///
/// Swift decodes this itself, from the bytes, with no round trip to Python. The
/// drawer already reads the container directly (#417) and #421's rule is "never poll
/// a set": a per-row `set_array` call would put one Python round trip on the screen
/// for every row a scroll passes, which is the cost the whole design exists to avoid.
/// The format is `pymol.sets.blobs.encode_f32` — little-endian float32, one value per
/// `index_json` entry, NaN for absent — and only `cif` blobs are gzipped, so there is
/// nothing to decompress here. `TestSwiftResidueArrayFixture` in
/// `testing/tests/test_appkit_sets.py` writes known values through the Python encoder
/// into a committed container and `SequenceArrayTests` reads the same file back, so
/// the two halves of that sentence are pinned against each other rather than asserted.
///
/// `u8q` is pair scope only (`blobs.choose_encoding`: a residue array is one row, not
/// a matrix, so the 4× does not pay for the rounding), so a `u8q` row here is a file
/// this build does not understand and is skipped rather than guessed at.
struct ResidueArray: Equatable {
    /// The MetricSpec key: `plddt`, `native_fit`, `certainty`.
    let key: String
    /// The chain this array covers, or nil for the whole entry.
    let chain: String?
    /// `[[chain, resi], …]` from `arrays.index_json`, in value order.
    let index: [ResidueKey]
    /// One per `index` entry; nil where the blob held NaN ("not measured", which is
    /// not zero — the metrics store's rule, all the way down to the bytes).
    let values: [Double?]

    struct ResidueKey: Equatable, Hashable {
        let chain: String
        let resi: String
    }

    /// The value at a (chain, resi), or nil when the array does not cover it. Built
    /// once per array rather than searched per cell: a 400-residue strip against a
    /// 400-entry index is 160k comparisons otherwise, per render.
    func lookup() -> [ResidueKey: Double] {
        var out: [ResidueKey: Double] = [:]
        out.reserveCapacity(index.count)
        for (i, key) in index.enumerated() where i < values.count {
            if let v = values[i] { out[key] = v }
        }
        return out
    }
}

/// Everything the Sequences tab needs about one entry that is NOT in `SetRow`: its
/// per-chain sequences and its residue arrays.
///
/// The two halves load SEPARATELY, and the flag is why. Sequences are text in the
/// `entries` table and the consensus band needs all of them at once; arrays are blobs
/// and load per visible row (#421). So a detail can be here with its sequences and
/// without its arrays, and `arraysLoaded` is what tells the per-row loader that this
/// id still has a blob read owing — without it the bulk read for the band would look
/// like "already loaded" and no strip would ever appear again.
struct SetEntryDetail: Equatable {
    let id: String
    /// `entries.sequences` — `{chain: one-letter}`.
    let sequences: [String: String]
    let arrays: [ResidueArray]
    /// True once the array query has run for this entry — which is not the same as
    /// `!arrays.isEmpty`, because most entries have no residue arrays at all and
    /// re-reading them every time a row scrolls past would be the cost this is for.
    let arraysLoaded: Bool

    init(id: String, sequences: [String: String] = [:], arrays: [ResidueArray] = [],
         arraysLoaded: Bool = true) {
        self.id = id
        self.sequences = sequences
        self.arrays = arrays
        self.arraysLoaded = arraysLoaded
    }

    /// EVERY array under `key`, not the first.
    ///
    /// `arrays`' primary key is `(entry_id, key, chain)`, so one metric legitimately
    /// arrives as several rows — a whole-entry array plus a chain-scoped refinement,
    /// or one array per chain, which is what `set_add` writes for a per-chain
    /// predictor. Taking `.first` meant every chain but one drew as "not measured",
    /// so a chain that scored badly read as a chain that was never scored. They are
    /// merged per chain in `SequenceRowModel.heatValues`.
    func arrays(_ key: String) -> [ResidueArray] {
        arrays.filter { $0.key == key }
    }

    /// The same detail with its arrays filled in, keeping the sequences already read.
    func withArrays(_ arrays: [ResidueArray]) -> SetEntryDetail {
        SetEntryDetail(id: id, sequences: sequences, arrays: arrays, arraysLoaded: true)
    }
}

/// One entry as the Lineage tab sees it: identity, its set, its parents and the two
/// flags that draw a node hollow. No metrics and no structures — those are the Table's
/// and the viewport's business, and a lineage over 8000 sequences has to stay text.
struct LineageEntryRecord: Equatable, Hashable {
    let id: String
    let setID: String
    let name: String
    let ord: Int
    let parents: [String]
    let rejected: Bool
    let runID: String?
}

/// A `runs` row, for the SET-level part of the DAG: an MPNN set whose entries have no
/// `parents` still knows which set it came from, and that is what puts "sequences" to
/// the right of "backbones" when the per-entry links are absent (spec §4.5).
struct LineageRunRecord: Equatable, Hashable {
    let id: String
    let setID: String
    let parentSetID: String?
    let tool: String
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
    ///
    /// Both numbers come from the ROWS THE DRAWER IS SHOWING, not from `matched` /
    /// `total`, which are Python's answer at the moment the expression was compiled.
    /// During a landing batch the expression does not change, so nothing re-compiles
    /// and that answer goes stale while the table keeps re-filtering locally — the
    /// label said "307 of 1000 match" over a table showing 507 of 1200. The payload's
    /// numbers stay as the cross-check the tests make; the label is what the user
    /// reads, and it has to agree with what is under it.
    func countLabel(matched matchedRows: Int, total totalRows: Int) -> String {
        guard isActive else { return "\(totalRows) entries" }
        return "\(matchedRows) of \(totalRows) match"
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

    // MARK: Lazy per-entry reads (#419)

    /// How many rows either side of the one that just appeared are loaded with it.
    ///
    /// Small on purpose. The look-ahead exists so a steady scroll does not show a
    /// "loading…" row at the leading edge; it is not a prefetch of the set. Ten rows
    /// either side is about one drawer's height in each direction, which covers a flick
    /// without turning a glance into a read of forty entries.
    static let sequenceLookAhead = 10

    /// The ids to load when `id` comes on screen: itself and the look-ahead window
    /// around it, in the row order the tab is showing.
    ///
    /// Pure and separate from the load, so the window can be walked at the ends of the
    /// list (where a naive `index ± 10` traps) without a store, a view or a run loop.
    static func sequenceWindow(around id: String, in order: [String],
                               lookAhead: Int = sequenceLookAhead) -> [String] {
        guard let index = order.firstIndex(of: id) else { return [id] }
        let lo = max(index - lookAhead, 0)
        let hi = min(index + lookAhead, order.count - 1)
        guard lo <= hi else { return [id] }
        return Array(order[lo...hi])
    }


    /// How many array BLOBS this connection has read. The Sequences tab's contract is
    /// that a thousand-entry set costs the blobs of the rows on screen and no more
    /// (#421: "structures and arrays load lazily"), and the only way to hold a lazy
    /// loader to that is to count. `SequenceLazyLoadTests` asserts on this number.
    private(set) var arrayBlobReads = 0

    /// Sequences and residue arrays for a HANDFUL of entries — the rows a scroll has
    /// on screen, plus the look-ahead. Two queries for the batch, not two per row.
    ///
    /// The `IN (…)` list is built from bound `?` placeholders, never from the ids, so
    /// nothing about an entry id reaches SQL text. An empty request is an empty answer
    /// with no query at all, which is what a tab with nothing visible should cost.
    func entryDetails(entryIDs: [String]) -> [String: SetEntryDetail] {
        let ids = Array(Set(entryIDs)).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [:] }
        var sequences: [String: [String: String]] = [:]
        let holes = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        for row in queryBound("SELECT id, sequences FROM entries WHERE id IN (\(holes))",
                              bind: ids.map { .text($0) }) ?? [] {
            guard let id = row.string("id") else { continue }
            sequences[id] = Self.decodeSequences(row.string("sequences") ?? "{}")
        }
        var arrays: [String: [ResidueArray]] = [:]
        let sql = """
            SELECT a.entry_id, a.key, a.chain, a.encoding, a.index_json, b.bytes
            FROM arrays a JOIN blobs b ON b.hash = a.blob
            WHERE a.scope = 'residue' AND a.entry_id IN (\(holes))
            ORDER BY a.entry_id, a.rowid
            """
        for row in queryBlobs(sql, bind: ids.map { .text($0) }) {
            guard let entryID = row.entryID, let key = row.key else { continue }
            arrayBlobReads += 1
            // An ALLOWLIST, not a `!= "u8q"` denylist. `u8q` is a PAIR encoding
            // (blobs.choose_encoding) and a residue array in it came from a build this
            // one does not know — but so would any future encoding, and a denylist
            // would decode the next same-width one AS f32 and draw a plausible wrong
            // strip. Refusing everything unrecognised leaves the row with no strip,
            // which reads as "no data" — the honest answer, and the only one that
            // stays honest as the format grows.
            guard row.encoding == "f32" else { continue }
            let index = Self.decodeResidueIndex(row.indexJSON)
            guard let values = Self.decodeF32(row.bytes, count: index.count) else { continue }
            arrays[entryID, default: []].append(
                ResidueArray(key: key, chain: row.chain, index: index, values: values))
        }
        var out: [String: SetEntryDetail] = [:]
        for id in ids {
            out[id] = SetEntryDetail(id: id, sequences: sequences[id] ?? [:],
                                     arrays: arrays[id] ?? [], arraysLoaded: true)
        }
        return out
    }

    /// Every entry's SEQUENCES for one set, in one query, with no blob read at all.
    ///
    /// The consensus band is a statement about the whole population — "these 8000
    /// sequences never vary at position 31" — so it cannot be computed from the rows
    /// that happen to be on screen. It does not need their ARRAYS, though, and that is
    /// the distinction this method exists to draw: sequences are short text in the
    /// `entries` table (a 9000-entry campaign is a few MB and reads in ~1 ms), where
    /// arrays are blobs and stay per-row-lazy (#421).
    ///
    /// Without this the tab was silently empty above the threshold: nothing was
    /// displayed, so no row's `onAppear` fired, so no sequences loaded, so every row
    /// had zero cells and the band had zero columns — under a caption that said
    /// "1000 in the consensus band".
    func sequencesOfSet(setID: String) -> [String: [String: String]] {
        guard Self.isSafeIdentifier(setID) else { return [:] }
        var out: [String: [String: String]] = [:]
        for row in query("SELECT id, sequences FROM entries WHERE set_id = ? ORDER BY ord",
                         bind: [setID]) {
            guard let id = row.string("id") else { continue }
            out[id] = Self.decodeSequences(row.string("sequences") ?? "{}")
        }
        return out
    }

    /// `entries.sequences` — a JSON object of `{chain: one-letter}`.
    static func decodeSequences(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    /// `arrays.index_json` — `[[chain, resi], …]`. A malformed index is an empty one,
    /// which drops the strip rather than mis-aligning it against the sequence.
    static func decodeResidueIndex(_ json: String) -> [ResidueArray.ResidueKey] {
        guard let data = json.data(using: .utf8),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else { return [] }
        return pairs.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return ResidueArray.ResidueKey(chain: pair[0], resi: pair[1])
        }
    }

    /// `blobs.encode_f32` read back: `count` little-endian float32s, NaN → nil.
    ///
    /// nil — not a short array — when the byte count disagrees with the index, because
    /// the two are one unit: a strip drawn from a truncated array would line the wrong
    /// confidence up under the wrong residue, and every value after the break would be
    /// off by however many the file lost. `blobs.decode_f32` raises on the same
    /// mismatch, on purpose; this is the same refusal in Swift.
    static func decodeF32(_ bytes: [UInt8], count: Int) -> [Double?]? {
        guard count >= 0, bytes.count == count * 4 else { return nil }
        var out: [Double?] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let base = i * 4
            let bits = UInt32(bytes[base])
                | (UInt32(bytes[base + 1]) << 8)
                | (UInt32(bytes[base + 2]) << 16)
                | (UInt32(bytes[base + 3]) << 24)
            let value = Float(bitPattern: bits)
            out.append(value.isNaN ? nil : Double(value))
        }
        return out
    }

    // MARK: Lineage (#419)

    /// Every entry in the FILE, as lineage records. Cross-set by nature — a fold's
    /// parent is a sequence in another set, which is the whole point of the tab — so
    /// this is the one read here that is not scoped to the active set.
    ///
    /// Called when the Lineage tab is selected and when the version moves UNDER it,
    /// never on a tick: it is text, but it is text for every entry in the container.
    func lineageEntries() -> [LineageEntryRecord] {
        query("""
            SELECT id, set_id, name, ord, parents, rejected, run_id
            FROM entries ORDER BY set_id, ord, rowid
            """).compactMap { row in
            guard let id = row.string("id"), let setID = row.string("set_id") else {
                return nil
            }
            return LineageEntryRecord(
                id: id, setID: setID, name: row.string("name") ?? id,
                ord: row.int("ord") ?? 0,
                parents: Self.decodeParents(row.string("parents") ?? "[]"),
                rejected: (row.int("rejected") ?? 0) != 0,
                runID: row.string("run_id"))
        }
    }

    /// Every `runs` row: `parent_set_id` is the set-level edge (spec §1, "lineage is
    /// the parent link"), which is what orders sets when per-entry parents are absent.
    func lineageRuns() -> [LineageRunRecord] {
        query("SELECT id, set_id, parent_set_id, tool FROM runs ORDER BY created, rowid")
            .compactMap { row in
                guard let id = row.string("id"), let setID = row.string("set_id") else {
                    return nil
                }
                return LineageRunRecord(id: id, setID: setID,
                                        parentSetID: row.string("parent_set_id"),
                                        tool: row.string("tool") ?? "")
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
        // The fragment and its params are one unit. `SetFilterPayload` decodes
        // leniently — anything it does not recognise becomes `.null` — so a truncated
        // or corrupt channel could otherwise arrive as the right SHAPE with the wrong
        // values and run as a quietly different predicate. This function is careful to
        // return nil rather than an empty result everywhere else; here is the one
        // place that was taking the payload's word for it.
        guard sqlite3_bind_parameter_count(stmt) == Int32(bind.count) else { return nil }
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

    /// One row of the residue-array query. A BLOB column, which `query` deliberately
    /// never returns (it maps one to `.null`, because the tables it reads hold none),
    /// so this is its own small path rather than a widening of `MetricValue` — the
    /// alternative would put an `Data` case on the type every table cell is.
    struct ArrayBlobRow {
        let entryID: String?
        let key: String?
        let chain: String?
        let encoding: String
        let indexJSON: String
        let bytes: [UInt8]
    }

    /// The arrays + blobs join, with text bound and the blob read as bytes. Empty on
    /// any prepare failure, like `query`: the marker fires again on the next write.
    private func queryBlobs(_ sql: String, bind: [MetricValue]) -> [ArrayBlobRow] {
        guard let db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_parameter_count(stmt) == Int32(bind.count) else { return [] }
        for (i, value) in bind.enumerated() {
            if case .text(let s) = value {
                sqlite3_bind_text(stmt, Int32(i + 1), s, -1, sqliteTransient)
            } else {
                sqlite3_bind_null(stmt, Int32(i + 1))
            }
        }
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(stmt, index).map { String(cString: $0) }
        }
        var out: [ArrayBlobRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var bytes: [UInt8] = []
            if let raw = sqlite3_column_blob(stmt, 5) {
                let n = Int(sqlite3_column_bytes(stmt, 5))
                if n > 0 {
                    bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: n))
                }
            }
            out.append(ArrayBlobRow(entryID: text(0), key: text(1), chain: text(2),
                                    encoding: text(3) ?? "f32",
                                    indexJSON: text(4) ?? "[]", bytes: bytes))
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
                // selection and column choice, for the reason the peek is cleared
                // below: none of it is about the set now showing. The FILTER is the
                // one thing it inherits — the set's own, saved in the file — and the
                // compiled form of it arrives on the SETSFILTER line that `poll()`
                // prints right after this marker.
                self.resetSetUIState(
                    filterText: active.flatMap { id in
                        nextSets.first { $0.id == id }?.filter } ?? "")
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
            if rowsChanged {
                self.refreshFilterMatches()
                // The lazily-loaded sequences and arrays are keyed by entry id and
                // entries are immutable once delivered, so the ones already read stay
                // valid; what has to go is anything for an entry that is no longer in
                // the set (a `set_delete_entries`), or the tab would draw a row the
                // table does not have.
                let live = Set(nextRows.map(\.id))
                if !self.sequenceDetails.isEmpty {
                    let kept = self.sequenceDetails.filter { live.contains($0.key) }
                    if kept.count != self.sequenceDetails.count {
                        self.sequenceDetails = kept
                        self.sequenceArrayOrder.removeAll { !live.contains($0) }
                    }
                }
                // Entries arrived or left, so the band's bulk read is stale.
                self.sequenceBandSetID = nil
            }
            if versionChanged {
                // One counter the Lineage tab can watch: it holds a graph built over
                // the WHOLE file, which no single published property describes.
                //
                // The tick is ALL that happens here. Rebuilding the graph from this
                // side too meant ~45 ms of main thread (measured on 9000 entries)
                // twice per delivery — once here and once in the view's own
                // `onChange` of this very counter. The view owns the rebuild; this
                // owns telling it to.
                self.setsVersionTick &+= 1
            }
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
            resetSetUIState(filterText: set.filter)
        }
        activeSetID = set.id
        setRows = setsStore?.rows(setID: set.id, columns: set.columns) ?? []
        setHistograms = Self.histograms(rows: setRows, columns: set.columns)
        dataDrawerVisible = true
        // `emit_filter` alongside the open, not inside it: the set's saved filter has
        // to be compiled before the first frame, or the drawer shows rows the filter
        // excludes for as long as it takes the next poll to come round.
        runPythonQuiet("from pymol import appkit_sets as _s\n"
                       + "_s.open_set(\(pyQuoted(set.name)))\n"
                       + "_s.emit_filter(\(pyQuoted(set.name)))")
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
            // An APPLIED filter that is not one we sent came from the console, from
            // MCP, or from a view: adopt its text so the field shows what is actually
            // in force. Two guards, and both are needed. `lastSentFilterExpression`
            // keeps our OWN debounced apply from echoing back and overwriting the
            // characters typed since we sent it — the user types `plddt > 8`, we
            // apply, they type `0`, and without this the echo would put `plddt > 8`
            // back. The composed compare keeps a payload that already agrees from
            // clearing brushes for no reason.
            let composed = SetFilterComposer.compose(text: self.setFilterText,
                                                     brushes: self.setBrushes).expression
            if payload.applied != 0, payload.expr != self.lastSentFilterExpression,
               payload.expr != composed {
                self.setFilterText = payload.expr
                self.setBrushes = []
            }
            self.refreshFilterMatches()
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    /// What the drawer should do with its match set, given the filter's state.
    ///
    /// Pure, and separate from the query, because the interesting case is the one with
    /// no query in it: a REJECTED expression must leave the last good match set alone.
    /// Falling back to "every row" there was a lie the drawer told and then kept —
    /// `_poll_filter` has nothing to re-emit for an expression that was never applied,
    /// so the table sat at 1000 rows while the set admitted 307, and Send to ▾ on an
    /// empty selection acted on the 307 the user could not see.
    enum FilterMatchDecision: Equatable {
        /// No filter: every row shows.
        case all
        /// Keep whatever is on screen — the set's filter has not moved.
        case keep
        /// Run the fragment.
        case run
    }

    static func filterMatchDecision(_ state: SetFilterState, activeSetID: String?)
        -> FilterMatchDecision {
        guard let activeSetID, state.setID == activeSetID else { return .all }
        if !state.error.isEmpty { return .keep }
        return state.fragment.isEmpty ? .all : .run
    }

    /// Run the compiled fragment over this set's rows. Cheap and local — one indexed
    /// query over a file already open — which is what lets the table re-filter when
    /// entries land rather than asking Python again per delivery.
    func refreshFilterMatches() {
        switch Self.filterMatchDecision(setFilter, activeSetID: activeSetID) {
        case .all:
            if setFilterMatches != nil { setFilterMatches = nil }
        case .keep:
            break
        case .run:
            guard let setID = activeSetID else { return }
            let matches = setsStore?.matchingIDs(setID: setID, fragment: setFilter.fragment,
                                                 params: setFilter.params)
            guard let matches else {
                // Could not even prepare it. Keep what is on screen and say so; an
                // empty table would read as "your filter excluded everything".
                setFilter.error = "This build could not apply the compiled filter, so"
                    + " the table is unchanged. The set_* commands still use it."
                return
            }
            if setFilterMatches != matches { setFilterMatches = matches }
        }
    }

    /// The expression the drawer would send RIGHT NOW: what is typed, joined with the
    /// brushes that exist at this instant.
    ///
    /// A seam, and the reason it exists is a bug. The filter bar's debounced work items
    /// used to capture the expression at keystroke time, and a brush changed between
    /// the keystroke and the fire — a header drag, "Filter to selection", or a chip's ×
    /// — went through the engine, where the bar's `@State` work items could not see it
    /// and could not be cancelled. Either the brush was dropped while its chip was
    /// still on screen (so `set_export` and Send to ▾ acted on a weaker filter than the
    /// UI claimed) or a dropped clause was resurrected (so rows were hidden by a
    /// predicate nothing on screen mentioned). Reading the state at FIRE time cannot
    /// go stale, which is why nothing else may compose it.
    var currentFilterExpression: String {
        SetFilterComposer.compose(text: setFilterText, brushes: setBrushes).expression
    }

    func previewCurrentFilter(_ set: SetEntry) {
        previewSetFilter(set, currentFilterExpression)
    }

    func applyCurrentFilter(_ set: SetEntry) {
        applySetFilter(set, currentFilterExpression)
    }

    /// Entries the viewport selection points at that the active filter is hiding.
    ///
    /// Clicking a staged object whose row is filtered out did nothing at all, with no
    /// account of why (#418 review R3). Named here so the filter bar can say it, and
    /// offer the way out.
    var viewportSelectionHidden: [SetRow] {
        guard !setViewportSelection.isEmpty, setFilterMatches != nil else { return [] }
        let shown = Set(filteredSetRows.map(\.id))
        return setViewportSelection.compactMap { id in
            guard !shown.contains(id) else { return nil }
            return setRows.first { $0.id == id }
        }
    }

    /// The rows the drawer shows: the active set's entries under the active filter.
    /// The Table tab and the Plot tab read THIS, so they cannot disagree (spec §4.3).
    var filteredSetRows: [SetRow] {
        guard let matches = setFilterMatches else { return setRows }
        return setRows.filter { matches.contains($0.id) }
    }

    // MARK: - The Sequences tab's lazy loader (#419)

    /// What the Sequences tab has for an entry, or nil while it is still coming.
    func sequenceDetail(_ id: String) -> SetEntryDetail? { sequenceDetails[id] }

    /// A visible row asking for its sequence and arrays. Coalesced: every row that
    /// appears in one frame adds to `pendingSequenceDetails`, and the first of them
    /// schedules the single read that satisfies them all.
    ///
    /// The filter is on `arraysLoaded`, not on presence: the band's bulk read puts a
    /// sequences-only detail here for every entry in the set, and testing presence
    /// would make every one of them look satisfied and no strip would ever load.
    func requestSequenceDetails(around id: String, in order: [String]) {
        let wanted = SetsStore.sequenceWindow(around: id, in: order)
            .filter { sequenceDetails[$0]?.arraysLoaded != true
                      && !pendingSequenceDetails.contains($0) }
        guard !wanted.isEmpty else { return }
        let wasIdle = pendingSequenceDetails.isEmpty
        pendingSequenceDetails.formUnion(wanted)
        guard wasIdle else { return }
        DispatchQueue.main.async { [weak self] in self?.flushSequenceDetails() }
    }

    /// Read everything asked for since the last turn, in one pair of queries.
    func flushSequenceDetails() {
        let ids = Array(pendingSequenceDetails)
        pendingSequenceDetails.removeAll()
        guard !ids.isEmpty, let store = setsStore else { return }
        let loaded = store.entryDetails(entryIDs: ids)
        guard !loaded.isEmpty else { return }
        var next = sequenceDetails
        for (id, detail) in loaded {
            // Keep the sequences already read for this id (the band's bulk read may
            // have got there first); take the arrays and the loaded flag.
            if let existing = next[id], !existing.sequences.isEmpty {
                next[id] = existing.withArrays(detail.arrays)
            } else {
                next[id] = detail
            }
            sequenceArrayOrder.removeAll { $0 == id }
            sequenceArrayOrder.append(id)
        }
        sequenceDetails = Self.evictSequenceArrays(next, order: &sequenceArrayOrder)
    }

    /// Arrays kept in memory at once. Sequences are text and stay — the band needs all
    /// of them — but a fully scrolled 8000-entry set would otherwise hold 8000 float32
    /// tracks resident, which is not a cache, it is the file.
    ///
    /// 400 is ten drawer-heights of rows either side of wherever the user stopped, so
    /// scrolling back over what you just read is free and scrolling the whole set is
    /// bounded.
    static let sequenceArrayCacheLimit = 400

    /// Drop the ARRAYS (never the sequences) of the least-recently-read entries until
    /// at most `sequenceArrayCacheLimit` of them are resident. Pure, so the eviction
    /// policy can be walked without a store.
    static func evictSequenceArrays(_ details: [String: SetEntryDetail],
                                    order: inout [String],
                                    limit: Int = sequenceArrayCacheLimit)
        -> [String: SetEntryDetail] {
        guard order.count > limit else { return details }
        var out = details
        let evict = order.prefix(order.count - limit)
        for id in evict {
            guard let detail = out[id] else { continue }
            out[id] = SetEntryDetail(id: id, sequences: detail.sequences,
                                     arrays: [], arraysLoaded: false)
        }
        order.removeFirst(order.count - limit)
        return out
    }

    /// Load EVERY entry's sequences for the set the band is about to be computed over.
    ///
    /// Called once per set, when the tab collapses. Text only — no blob touches this
    /// path, which `SequenceBandTests` asserts on `arrayBlobReads` — and idempotent
    /// through `sequenceBandSetID`, because it is called from a view body's `onAppear`
    /// and a re-render must not re-read the set.
    func loadSequencesForBand(setID: String) {
        guard sequenceBandSetID != setID, let store = setsStore else { return }
        sequenceBandSetID = setID
        let sequences = store.sequencesOfSet(setID: setID)
        guard !sequences.isEmpty else { return }
        var next = sequenceDetails
        for (id, chains) in sequences where next[id] == nil {
            // arraysLoaded: false — this read deliberately fetched no blobs, and the
            // per-row loader has to still see these ids as owing one.
            next[id] = SetEntryDetail(id: id, sequences: chains, arrays: [],
                                      arraysLoaded: false)
        }
        sequenceDetails = next
    }

    /// Open the drawer with the scene band up — the View menu, the rail's Seq pill, and
    /// `PYMOL_AUTOSEQ`. The Mac's "show me the sequence" in every state.
    ///
    /// It deliberately does NOT touch `dataDrawerTab` (#456). The band is above the tab
    /// bar and draws whatever tab is selected, so asking for the scene sequences is no
    /// longer a reason to take away the Table someone was triaging in — which is the
    /// whole objection to #419's arrangement.
    func showSequenceBand() {
        sequenceBandVisible = true
        dataDrawerVisible = true
        fetchSequences()
    }

    /// ⌘2 / the Seq pill / `View ▸ Hide Sequences`: stop showing the scene sequences.
    ///
    /// The drawer closes with the band only when the band WAS the drawer — no set open,
    /// so there is no tab content to give the height back to and what is left would be
    /// the "No set open" placeholder nobody asked for. With a set open the drawer stays
    /// and the tab content takes the band's height.
    func hideSequenceBand() {
        sequenceBandVisible = false
        if activeSet == nil { closeDataDrawer() }
    }

    /// True when the scene sequences are actually on screen: the band's flag AND a
    /// drawer to draw it in. The state the ⌘2 menu item, the rail pill and #456's
    /// migration all mean by "the sequence view is up".
    var sequenceBandShowing: Bool { dataDrawerVisible && sequenceBandVisible }

    func toggleSequenceBand() {
        if sequenceBandShowing { hideSequenceBand() } else { showSequenceBand() }
    }

    // MARK: - The Lineage tab (#419)

    /// Rebuild the graph from the container. Called when the tab appears and when the
    /// version moves under it; never on a tick.
    func refreshLineage() {
        guard dataDrawerTab == .lineage, let store = setsStore else { return }
        // The metric is the ACTIVE set's ranking column, and its values are the rows
        // already in memory — nodes in other sets are left `metricUnknown` rather than
        // read, because sizing a 9000-node graph by a column most of it does not have
        // would mean a scalar read per set for a decoration.
        let column = activeSet.flatMap { set in
            set.columns.first { $0.column == set.rankingKey && $0.isScalar }
        }
        var metric: [String: Double?] = [:]
        if let name = column?.column {
            for row in setRows { metric[row.id] = row.values[name]?.number }
        }
        let next = LineageModel(entries: store.lineageEntries(), runs: store.lineageRuns(),
                                metric: metric, metricColumn: column)
        if lineageModel != next { lineageModel = next }
    }

    /// A node click: select the node and its descendants in the Table, and go there.
    ///
    /// SELECTION, not a filter — see the note at the top of LineageView.swift. Scoped
    /// to the active set because that is the only set the Table is showing.
    ///
    /// Returns how many rows it selected, and 0 is a real answer the caller must not
    /// swallow: a subtree entirely inside a CHILD set (click a backbone while the fold
    /// set is open, which is exactly what the tab invites) selects nothing here, and a
    /// click that silently does nothing is the worst of the three outcomes. The view
    /// says so, and draws those nodes dimmed so it is visible before the click.
    @discardableResult
    func selectLineageSubtree(_ ids: Set<String>) -> Int {
        let here = Set(setRows.map(\.id)).intersection(ids)
        guard !here.isEmpty else { return 0 }
        setSelection = here
        dataDrawerTab = .table
        return here.count
    }

    /// Everything about the drawer that belongs to one set and must not follow the
    /// user into the next one.
    func resetSetUIState(filterText: String = "") {
        setFilterText = filterText
        lastSentFilterExpression = filterText
        setBrushes = []
        setFilter = SetFilterState()
        setFilterMatches = nil
        setSelection = []
        setViewportSelection = []
        setHiddenColumns = []
        dataDrawerTab = Self.tabAfterSetChange(dataDrawerTab)
        // The TAB is deliberately NOT reset. This runs on every `activeSetID` change,
        // and a campaign makes a new set active repeatedly — `binder_design` then
        // `predict … @top:3` then the next round — so resetting it here yanked the
        // user off the Sequences tab once per child set, which is the same "a visible
        // pane must not vanish" rule the strip's migration exists to honour, broken at
        // the other end. Every tab has something to show for any set, so there is no
        // state to rescue them from. If a future tab ever does not, the test is
        // `!tab.isAvailable`, which is nothing today.
        //
        // The lazily-loaded sequences and arrays belong to the entries of the set
        // being left. Keeping them would grow without bound over a session and, worse,
        // a new set whose entry ids happened to collide would draw the old strips.
        sequenceDetails = [:]
        pendingSequenceDetails = []
        sequenceArrayOrder = []
        sequenceBandSetID = nil
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
        lastSentFilterExpression = expression
        runPythonQuiet("from pymol import appkit_sets as _s\n"
                       + "_s.preview_filter(\(pyQuoted(set.name)), \(Self.pythonLiteral(expression)))")
    }

    /// `set_filter` — the expression becomes the set's, which is what `filtered`,
    /// `top:N`, `set_export` and `predict set:x@filtered` all read.
    func applySetFilter(_ set: SetEntry, _ expression: String) {
        lastSentFilterExpression = expression
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
            // `+` joins names and `@` is what `predicting.parse_set_input` partitions
            // `set:<name>@<selector>` on, so a name carrying either cannot be written
            // as a selector. The store's own rules refuse both in an entry name today;
            // this is the composer refusing to build a selector it cannot mean.
            let usable = names.filter { !$0.isEmpty && !$0.contains("+") && !$0.contains("@") }
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

/// Which tab of the Data drawer is showing. All four ship as of #419; `isAvailable`
/// is kept because the drawer's shape is the spec's (§4) and a fifth tab landing
/// half-built should be drawn disabled rather than hidden, exactly as Sequences and
/// Lineage were between #418 and #419.
enum DataDrawerTab: String, CaseIterable, Identifiable, Equatable {
    case table = "Table"
    case plot = "Plot"
    case sequences = "Sequences"
    case lineage = "Lineage"

    var id: String { rawValue }
    var isAvailable: Bool { true }

    // There is deliberately no `worksWithoutASet` here any more (#456). It was true for
    // Sequences, because the scene rows were the top half of that tab and those draw
    // for any session. They are the drawer's BAND now — its own pane, above the tab
    // bar, drawn on whatever tab — so the property moved with them and is
    // `SequenceBandView.worksWithoutASet`. Every TAB is a view of a set, and what is
    // left of Sequences (the set's entry rows) has exactly as much to show without one
    // as the Table does: nothing.

    var help: String {
        switch self {
        case .table: return "Entries as rows; columns come from the set's metrics"
        case .plot: return "One scatter over the same filtered rows; brush to select"
        case .sequences:
            return "The selected or filtered entries as sequences, with per-residue"
                + " confidence under each. The SCENE sequences are the band above,"
                + " which is on whatever tab you pick (⌘2)."
        case .lineage:
            return "Which backbone each sequence and fold came from; click a node to"
                + " select it and its descendants in the Table"
        }
    }
}

extension PyMOLEngine {
    /// The tab the drawer should be on after the ACTIVE SET changes.
    ///
    /// Which is: the one it is already on. This used to be an unconditional `.table`,
    /// and it ran on every `activeSetID` change — so a campaign (`binder_design`, then
    /// `predict … @top:3`, then the next round) yanked the user off the Sequences tab
    /// once per child set, silently replacing the sequence view with a table. That is
    /// the same "a visible pane must not vanish" rule the strip's migration exists to
    /// honour, broken at the other end.
    ///
    /// The only tab that would have to be rescued is one this build cannot draw, which
    /// is nothing today — but the condition is written out rather than assumed, so a
    /// half-built tab added later cannot strand the drawer. (Before #456 the test also
    /// admitted `worksWithoutASet`; the scene rows that made Sequences qualify are the
    /// band now, and the band is not a tab.)
    static func tabAfterSetChange(_ current: DataDrawerTab) -> DataDrawerTab {
        current.isAvailable ? current : .table
    }

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
