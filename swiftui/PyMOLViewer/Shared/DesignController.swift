#if RAYMOL_MPNN
import Foundation
import MPNNKit
import Combine

/// Thread-safe mirror of a @MainActor job token so the inference closure — which
/// runs on the serial background queue — can tell whether it has already been
/// superseded BEFORE spending an inference on a result nobody will read.
private final class TokenMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func set(_ v: Int) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Sentinel thrown inside an inference closure when the job token has already been
/// superseded by the time the closure starts. Using a typed error lets catch sites
/// distinguish "superseded" from "failed":
///   - rescoreWorkingObject uses `try?` → nil → existing guard returns early, no errorText.
///   - repackNowAwait uses do/catch → the `guard token == repackToken` check exits early.
///   - focusAwait uses do/catch → the `guard token == rescoreToken` check exits early.
///   - redesignSelectionAwait uses `try?` → nil → existing guard exits early, no errorText.
/// None of these paths reaches an `errorText = …` assignment, so supersession is never
/// reported as a failure to the user.
private struct SupersededJobError: Error {}

/// Orchestrates the Design mode lifecycle: scores residues off the main thread on a serial queue
/// with a job token (superseded focuses are discarded), caches results, and applies per-residue
/// coloring. Model lifecycle is managed by the injected `score` closure (wired in Task 10).
/// All published state and public methods are @MainActor.
@MainActor
final class DesignController: ObservableObject {
    @Published var focusObject: String?
    @Published var colorMeaning: DesignColorMeaning = .nativeFit
    @Published var isScoring = false
    @Published var legendDomain: ClosedRange<Float>?
    @Published var errorText: String?
    @Published var allObjects: [String] = []
    /// Residue index (into `lastSet[focusObject]?.residues`) currently under the
    /// pointer. nil = no hover / pointer not over a residue on the focus object.
    @Published var hoveredResidueIndex: Int?
    /// Residue index that has been pinned by a click. Persists until the user
    /// clicks the same residue again (toggle) or another residue is pinned.
    @Published var pinnedResidueIndex: Int?
    /// The Design tool's target field (#371). Holds either an object name or any
    /// selection expression; `applyTarget()` resolves it to the ONE structure Design
    /// works on. Peer of Design Backbone's `target` and Predict's `sequence /
    /// selection` — a text box, with the object dropdown as an optional way to fill it.
    @Published var targetText: String = ""
    /// The Design tool's region field (#371). The literal 'sele' is the default and
    /// means "whatever is selected right now", which is exactly what clicking
    /// residues builds. Any other expression is WRITTEN to 'sele' by
    /// `applySelection()`, so there is still one region pipeline and the click path
    /// is untouched.
    @Published var selectionText: String = DesignController.liveSelection

    /// PyMOL's live selection. Named rather than spelled out at each use because it
    /// is a sentinel VALUE in `selectionText`, not just a selection name: it means
    /// "read, do not write".
    static let liveSelection = "sele"

    // MARK: – Closure type aliases (Task 10 wires in real implementations)

    /// Enumerate residues for `(objectName, state)`.
    typealias EnumerateFn = (String, Int) throws -> DesignResidueSet

    // MARK: – Edit-session closure type aliases (Task 2; Task 10 wires real implementations)

    /// Create a working-copy object from `srcObject`; returns the new object name.
    typealias MakeWorkingCopyFn = (String) -> String
    /// Apply a backbone-only display mutation to `obj` at `chain`/`resi` for amino-acid `aa`.
    typealias MutateDisplayFn = (String, String, String, Int) -> Void
    /// Discard the working-copy object: deletes `dst` and re-enables `src`.
    typealias DiscardFn = (String, String) -> Void
    /// Re-enable the original source object on the Keep path (working copy is preserved).
    typealias EnableOriginalFn = (String) -> Void
    /// Toggle the compare view on/off with an optional side-by-side grid mode.
    /// Called with (on, sideBySide): on=true enables compare; sideBySide selects
    /// overlap (false, default) vs grid (true) layout.
    typealias CompareFn = (Bool, Bool) -> Void
    /// Restore the parent's saved compare colors and clear grid_mode without enabling/disabling.
    /// Called during teardown so grid mode never outlasts the edit session.
    typealias ResetCompareFn = (String) -> Void

    /// Run MPNN scoring off-main; called on the inference serial queue.
    typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult

    /// Run MPNN sidechain repack off-main for the given residues + sequence; returns an all-atom PDB string.
    typealias RepackFn = ([MPNNModel.Residue], [Int]) throws -> String
    /// Load a repacked PDB string into the named working-copy object.
    /// Replace an object's structure from a PDB string. The third parameter is the
    /// edit-session source: `load_repacked` re-asserts 'sele' onto the replaced
    /// (visible) object afterwards, and needs the scope to know which residues the
    /// region contains — the pre-session ones were only ever marked on the original.
    typealias LoadRepackedFn = (_ obj: String, _ pdb: String, _ src: String?) -> Void

    /// Show or hide all sidechain sticks on `obj` (with cnc element coloring on show).
    typealias ShowAllSidechainsFn = (String, Bool) -> Void

    /// Apply per-residue coloring to `objectName`.
    /// `values`: (chain, resi, scalar?) for every residue in the set order.
    /// `metric` and `state` are for the metric store (#308), not for the colour: the
    /// values are RECORDED against the object before they are rendered, so they
    /// survive the session and can be re-applied after another tool colours over the
    /// B-factor column. Without the name the Python side would be storing an unlabelled
    /// array — native fit and certainty are both "the scalar", and only here is it
    /// known which one this is.
    typealias ColorFn = (_ obj: String, _ values: [(String, String, Float?)],
                         _ palette: String, _ lo: Float, _ hi: Float,
                         _ metric: String, _ state: Int) -> Void

    /// Show/hide non-destructive sidechain sticks for one residue on `obj`.
    /// Returns whether WE added the sticks on a show (`on == true`) — the
    /// residue had none before; `false` if it already had sticks (user's own)
    /// or on a hide. Used so hover-off only removes sticks we introduced.
    typealias SticksFn = (_ obj: String, _ chain: String, _ resi: String, _ on: Bool) -> Bool

    /// Run MPNN region design off-main. Returns designed alphabet indices, length = residues.count.
    /// `temperature` > 0 samples (non-deterministic); the engine uses a nil seed so runs vary.
    typealias DesignRegionFn = (_ residues: [MPNNModel.Residue],
                                _ fixedPositions: Set<Int>,
                                _ nativeSequence: [Int],
                                _ omit: [Set<Int>],
                                _ temperature: Float) throws -> [Int]
    /// Read the active 'sele' for `obj`, scoped to `obj` + its edit `src`. Returns
    /// the full-length guide indices inside that scope, a digest of the WHOLE
    /// selection (used only for change detection), and the number of selected
    /// residues OUTSIDE that scope.
    ///
    /// `off` is reported, never derived. Python computes it from the model names it
    /// already has; reconstructing it here as "total selected − in scope" was the
    /// source of every wrong-badge variant, because during an edit session one
    /// residue legitimately carries 'sele' membership on both the working copy and
    /// the original and so appears twice in any whole-session total.
    typealias SeleStateFn = (_ obj: String, _ src: String?, _ state: Int)
        -> (indices: [Int], digest: String, off: Int)
    /// Add or remove one residue in the active 'sele'.
    ///
    /// `src` is the edit-session source object and is NOT optional decoration: the
    /// write has to resolve in the same scope `SeleStateFn` reads (`obj` + `src`,
    /// matched by residue identity). Object-scoped, a toggle inside an edit session
    /// could never REMOVE a region member — the focus object is the working copy
    /// while the selection sits on the original's atoms, so the toggle found
    /// nothing to remove and added instead — and residues clicked during the
    /// session lost their membership when a repack replaced the working copy's
    /// topology.
    typealias ToggleSeleFn = (_ obj: String, _ chain: String, _ resi: String,
                              _ src: String?) -> Void
    /// Replace the active 'sele' with exactly one residue. `src` scopes the write
    /// exactly as it does for `ToggleSeleFn`.
    typealias SetSeleResidueFn = (_ obj: String, _ chain: String, _ resi: String,
                                  _ src: String?) -> Void
    /// Empty the active 'sele'.
    typealias ClearSeleFn = () -> Void
    /// Narrow the active 'sele' so none of `obj`'s atoms are in it.
    typealias DropObjectFromSeleFn = (_ obj: String) -> Void
    /// Release the cached MPNN model. Invoked on the inference queue from `exit()`,
    /// never on the main thread — the model is owned by that queue.
    typealias ReleaseModelFn = () -> Void
    /// Resolve a target expression to the name of ONE object. nil = nothing matched
    /// (or the selector was rejected); the first object of a multi-object match wins,
    /// because Design only ever works on the focused structure.
    typealias ResolveTargetFn = (_ expression: String) -> String?
    /// Replace the active 'sele' with `expression`. Returns the number of atoms
    /// selected, or nil when PyMOL rejected the selector — 0 and nil are different
    /// answers ("matched nothing" vs "not a selection"), and the field reports both.
    typealias SelectRegionFn = (_ expression: String) -> Int?

    // MARK: – Injected dependencies

    private let enumerate: EnumerateFn
    private var score: ScoreFn
    private let applyColoring: ColorFn
    private let dim: (String) -> Void
    private let snapshot: ([String]) -> Void
    private let restore: () -> Void
    private var setSticksFn: SticksFn
    /// Returns the currently-displayed state (1-based) for `object`. Wired to the engine in Task 10.
    private let currentStateFn: (String) -> Int

    // MARK: – Edit-session injected closures (default no-ops; Task 10 replaces; #if DEBUG hooks inject in tests)

    private var makeWorkingCopy: MakeWorkingCopyFn = { $0 + "_design" }
    private var mutateDisplay: MutateDisplayFn = { _, _, _, _ in }
    private var discard: DiscardFn = { _, _ in }
    private var enableOriginalFn: EnableOriginalFn = { _ in }
    private var compare: CompareFn = { _, _ in }
    private var resetCompareFn: ResetCompareFn = { _ in }
    private var repack: RepackFn = { _, _ in "" }
    private var loadRepacked: LoadRepackedFn = { _, _, _ in }
    private var showAllSidechainsFn: ShowAllSidechainsFn = { _, _ in }
    private var designRegionFn: DesignRegionFn = { r, _, _, _, _ in Array(repeating: 0, count: r.count) }
    private var releaseModelFn: ReleaseModelFn = { }
    private var resolveTargetFn: ResolveTargetFn?
    private var selectRegionFn: SelectRegionFn?
    /// The object `targetText` last resolved to. Lets `focusAwait` tell "the field is
    /// stale" from "the field is the user's own expression for this very object", so
    /// a typed expression is never silently rewritten to the object name it matched.
    private var targetResolvedObject: String?

    // MARK: – 'sele' access (single source of truth)
    //
    // OPTIONAL rather than defaulted closures: a stored property's default value
    // cannot reference `self`, and the engine-free fallbacks below must read
    // `lastSet` / `focusObject`. nil therefore means "use the local fallback",
    // which is what unit tests get — and that matters, because
    // `pinnedResidueIndex` is now DERIVED: against no-op stubs every existing pin
    // assertion would read nil.
    private var seleStateFn: SeleStateFn?
    private var toggleSeleFn: ToggleSeleFn?
    private var setSeleResidueFn: SetSeleResidueFn?
    private var clearSeleFn: ClearSeleFn?
    private var dropObjectFromSeleFn: DropObjectFromSeleFn?

    /// In-memory stand-in for PyMOL's 'sele' used by the fallbacks. Keys are
    /// "chain\u{1}resi" — the same encoding `stickKey` produces.
    private var stubSele: Set<String> = []

    /// Digest of the selection the last `syncFromSele()` resolved. The panel-poll
    /// hook compares against this so it only re-derives when 'sele' really changed.
    private(set) var lastSeleDigest: String = ""

    // MARK: – Edit-session published state (Task 2)

    @Published private(set) var editing = false
    @Published private(set) var editCount = 0
    @Published private(set) var repackDirty = false
    @Published var autoRepack = true
    @Published private(set) var isRepacking = false
    /// True while `rescoreWorkingObject` has a score in flight on the inference queue.
    /// Follows the same token-guarded `defer` pattern as `isRepacking` and `isRedesigning`
    /// so a stranded flag can never permanently lock the toolbar.
    @Published private(set) var isRescoring = false
    /// True while the compare toggle is on (original structure shown alongside the working copy).
    @Published private(set) var compareEnabled = false
    /// True while the Side-by-side grid layout is selected (only meaningful when compareEnabled).
    /// false = overlap (grey + transparent ghost behind design); true = grid (own confidence colors).
    @Published private(set) var sideBySide = false
    /// True while all sidechain sticks are shown on the design (and parent when compare is on).
    /// True while all sidechain sticks are shown on the design (and parent when
    /// compare is on). Defaults ON: designing is a sidechain-level activity, so the
    /// target structure arrives with its sidechains visible.
    ///
    /// The default alone would be a REGRESSION rather than a feature —
    /// `reconcileSticks()` early-returns while this is set, on the assumption that a
    /// global show-all pass has already made every sidechain visible. So the flag is
    /// only ever true in company with that pass: `focusAwait` issues it for the new
    /// focus, and `exit()` / a focus change take it back down again.
    @Published private(set) var showSidechains = true
    /// Mean per-residue native-fit log-probability over the valid residues of the focus object.
    /// nil until the first score result arrives. Updated after every rescore (including edits).
    /// Higher (closer to 0) = better sequence–structure fit.
    @Published var sequenceScore: Float?
    private(set) var workingObject: String?
    private(set) var editedSequence: [Int] = []
    /// The source object that the current edit session is based on.
    /// Set when the session begins; cleared in teardownEditSession.
    private(set) var editSourceObject: String?

    /// Full-length residue indices (into set.residues) of the selected region, valid only.
    @Published private(set) var selectedResidueIndices: [Int] = []
    /// Allowed amino-acid alphabet indices (0..<20) for region sampling; toggled off → omit.
    @Published var paletteAllowed: Set<Int> = Set(0..<20)
    /// Residues in 'sele' that are NOT on the focus object. Design ignores them,
    /// so the UI surfaces the count rather than silently dropping them.
    @Published private(set) var seleResiduesOffFocus: Int = 0
    /// Pre-batch sequence + editCount captured before the last region redesign (nil = nothing to revert).
    @Published private(set) var redesignSnapshot: RedesignSnapshot?
    /// True while a region design() call is running off-main.
    @Published private(set) var isRedesigning = false
    /// Sampling temperature for region design (0 = greedy, higher = more diverse). The
    /// engine pairs this with a nil seed so each Redesign is non-deterministic.
    @Published var designTemperature: Float = 0.2

    /// Pending oversize confirmation, or nil. Set when a redesign lands in the
    /// guard's warn band; the UI presents it and calls confirm/cancel.
    @Published private(set) var pendingSizeWarning: SizeWarning?

    /// A run large enough to be worth confirming. `residueCount` is the total
    /// object length, not the selection size — MPNN's cost tracks the whole
    /// object regardless of how few positions are free.
    struct SizeWarning: Equatable {
        let residueCount: Int
        let estimatedBytes: Int
        let availableBytes: Int
    }

    /// Size decision for a run over `residueCount` residues. Injectable so the
    /// controller's warn/confirm/refuse wiring can be tested without depending on
    /// the guard's constants — which are retuned from device measurements later in
    /// this phase, and must not be able to silently invalidate these tests.
    /// The default routes through `evaluate`, which enforces macOS inertness:
    /// `evaluate` returns `.ok` unconditionally on non-iOS regardless of arguments.
    var sizeDecisionProvider: (Int) -> DesignSizeGuard.Decision = { count in
        DesignSizeGuard.evaluate(residueCount: count,
                                 availableBytes: DesignSizeGuard.availableBytesNow)
    }

    /// Write a session autosave before a confirmed large run, so a jetsam kill
    /// costs no user work. Wired to the engine in PyMOLEngine; no-op in tests.
    var autosaveBeforeLargeRun: () -> Void = { }

    /// Set for exactly one call by `confirmPendingWarning()` so the confirmed run
    /// is not re-gated into an infinite warn loop. Cleared on read.
    private var suppressSizeGuardOnce = false

    /// Region mode = a selection is designated. Drives the pill-row hat-switch + Redesign button.
    var regionModeActive: Bool { !selectedResidueIndices.isEmpty }

    /// Label for the blocking "Calculating…" overlay while a long design inference
    /// runs (nil = not busy). Covers exactly two edit-triggered heavy ops — a region
    /// redesign and a manual repack. The redesign clears `isRedesigning` BEFORE the
    /// follow-up rescore + repack (see `redesignSelectionAwait` line ~841), so this
    /// label does NOT span the follow-up phases; repack raises its own label while
    /// it runs. The initial focus scoring keeps its lightweight inline spinner
    /// (`isScoring`) rather than a full-screen block — it's quick on real hardware
    /// and shouldn't gate the whole UI on every object focus.
    var designBusyLabel: String? {
        if isRedesigning { return "Redesigning region…" }
        if isRepacking { return "Repacking sidechains…" }
        return nil
    }

    /// True while ANY MLX inference is in flight (focus scoring, working-object
    /// rescore, region redesign, or sidechain repack). This is the mode-lock
    /// predicate — distinct from `designBusyLabel`, which covers only the two
    /// long blocking operations and deliberately does NOT cover focus scoring or
    /// the post-redesign rescore.
    var isCalculating: Bool { isScoring || isRescoring || isRedesigning || isRepacking }

    struct RedesignSnapshot { let seq: [Int]; let editCount: Int }

    // MARK: – Private state

    private let cache = DesignScoreCache()
    /// Single serial queue for all off-main MPNN inference (scoring and repack).
    /// Serial guarantees MLX model calls never overlap; continuations resume back on MainActor.
    private let inferenceQueue = DispatchQueue(label: "io.raymol.design.inference", qos: .userInitiated)
    /// Incremented on each focus/rescore; a superseded score checks its captured token against this.
    private var rescoreToken: Int = 0
    /// Incremented on each repack; superseded repacks are discarded without touching rescoreToken.
    private var repackToken: Int = 0
    /// Incremented on each region redesign; a superseded design() checks this before applying.
    private var designToken: Int = 0
    /// Thread-safe mirrors of the main-actor job tokens for use inside inference
    /// closures (which run on the serial background queue).  Updated on the main
    /// actor immediately after each token increment; read by the closure at the top
    /// of each dispatch to bail before running inference when already superseded.
    private let rescoreMirror = TokenMirror()
    private let repackMirror  = TokenMirror()
    private let designMirror  = TokenMirror()
    /// Most-recently enumerated residue set per object (for recolor without re-enumerating).
    private var lastSet: [String: DesignResidueSet] = [:]
    /// Published residue list for the focus object. Updated whenever `focusObject` or
    /// the cached residue set for it changes; drives the 2-row sequence strip in the
    /// design overlay without exposing the private `lastSet` dict.
    @Published private(set) var focusResidues: [DesignResidue] = []
    /// Residues on the focus object for which WE currently show sidechain
    /// sticks, mapped to whether WE added them (true) vs the user already had
    /// them (false → never hide/restore). Keyed by `stickKey(chain, resi)`.
    /// Reconciled after every hover/pin change against the desired set
    /// {pinnedResidue} ∪ {hoveredResidue}.
    private var managedSticks: [String: Bool] = [:]

    // MARK: – Init

    nonisolated init(enumerate: @escaping EnumerateFn,
                     score: @escaping ScoreFn,
                     applyColoring: @escaping ColorFn,
                     dim: @escaping (String) -> Void,
                     snapshot: @escaping ([String]) -> Void,
                     restore: @escaping () -> Void,
                     setSticks: @escaping SticksFn = { _, _, _, _ in false },
                     currentState: @escaping (String) -> Int = { _ in 1 },
                     makeWorkingCopy: @escaping MakeWorkingCopyFn = { $0 + "_design" },
                     mutateDisplay: @escaping MutateDisplayFn = { _, _, _, _ in },
                     discard: @escaping DiscardFn = { _, _ in },
                     enableOriginal: @escaping EnableOriginalFn = { _ in },
                     compare: @escaping CompareFn = { _, _ in },
                     resetCompare: @escaping ResetCompareFn = { _ in },
                     repack: @escaping RepackFn = { _, _ in "" },
                     loadRepacked: @escaping LoadRepackedFn = { _, _, _ in },
                     showAllSidechains: @escaping ShowAllSidechainsFn = { _, _ in },
                     designRegion: @escaping DesignRegionFn = { r, _, _, _, _ in Array(repeating: 0, count: r.count) },
                     releaseModel: @escaping ReleaseModelFn = { },
                     seleState: SeleStateFn? = nil,
                     toggleSele: ToggleSeleFn? = nil,
                     setSeleResidue: SetSeleResidueFn? = nil,
                     clearSele: ClearSeleFn? = nil,
                     dropObjectFromSele: DropObjectFromSeleFn? = nil,
                     resolveTarget: ResolveTargetFn? = nil,
                     selectRegion: SelectRegionFn? = nil) {
        self.enumerate = enumerate
        self.score = score
        self.applyColoring = applyColoring
        self.dim = dim
        self.snapshot = snapshot
        self.restore = restore
        self.setSticksFn = setSticks
        self.currentStateFn = currentState
        self.makeWorkingCopy = makeWorkingCopy
        self.mutateDisplay = mutateDisplay
        self.discard = discard
        self.enableOriginalFn = enableOriginal
        self.compare = compare
        self.resetCompareFn = resetCompare
        self.repack = repack
        self.loadRepacked = loadRepacked
        self.showAllSidechainsFn = showAllSidechains
        self.designRegionFn = designRegion
        self.releaseModelFn = releaseModel
        self.seleStateFn = seleState
        self.toggleSeleFn = toggleSele
        self.setSeleResidueFn = setSeleResidue
        self.clearSeleFn = clearSele
        self.dropObjectFromSeleFn = dropObjectFromSele
        self.resolveTargetFn = resolveTarget
        self.selectRegionFn = selectRegion
    }

    // MARK: – Public interface

    /// Called when entering Design mode: snapshot current visuals, auto-focus if exactly one object.
    func enter() {
        snapshot(allObjects)
        if allObjects.count == 1 { focus(allObjects[0]) }
    }

    /// Called when exiting Design mode: restore visuals and cancel any pending score.
    func exit() {
        // Same reason the focus-change path does it: restore() below re-applies
        // colours and transparency but NOT representation visibility, so the
        // show-all pass has to be taken down explicitly or the user's structure is
        // left covered in sticks after leaving Design mode.
        if showSidechains, let obj = focusObject { showAllSidechainsFn(obj, false) }
        // Hide any sticks WE added first — restore() only re-applies colors and
        // transparency, not representation visibility, so it won't undo shown sticks.
        teardownSticks(on: focusObject)
        // C1/C2: If an edit session is active, discard the working copy and re-enable
        // the original BEFORE restoring colors/transparency. This ensures the original
        // is visible after exit. For read-only (Phase-2a) sessions with no active edit,
        // do NOT touch object enable state — just restore colors/transparency below.
        if editing {
            teardownEditSession(discardCopy: true)
        }
        restore()
        focusObject = nil
        syncFocusResidues()   // clear the sequence strip
        isScoring = false
        errorText = nil
        hoveredResidueIndex = nil
        pinnedResidueIndex = nil
        // D2: 'sele' IS the pink marker now, and it belongs to the user — leaving
        // Design mode must not wipe their selection, so nothing is pushed outward.
        clearRegionState()
        rescoreToken += 1; repackToken += 1   // cancel any in-flight scoring or repack
        rescoreMirror.set(rescoreToken); repackMirror.set(repackToken)
        // Free the model's resident weights. Dispatched to the inference queue
        // rather than run inline: `_mpnnModel` is unsynchronized and owned by that
        // serial queue, so a main-thread nil-out would race a running job. Queueing
        // it also orders the release behind any inference already dispatched.
        let release = releaseModelFn
        inferenceQueue.async { release() }
    }

    /// Dismiss the current error message. The Design overlay's error banner calls
    /// this on tap and on its auto-dismiss timer; `errorText` is otherwise only
    /// cleared implicitly by the next successful operation.
    func clearError() { errorText = nil }

    /// Unified viewport-hit routing shared between iOS (`designPickResidue`) and
    /// macOS (`onChange(of: engine.longPressHit)`).
    ///
    /// Four-way rule, matching normal-mode click semantics:
    ///   - `object` empty (a miss) → clear 'sele'; focus is untouched
    ///   - `object != focusObject` → refocus there AND select that residue (D4),
    ///     so the first click on another structure is never dead
    ///   - `object == focusObject && hasResidue` → toggle that residue in 'sele'
    ///   - `object == focusObject && !hasResidue` → no-op (a non-residue patch)
    func handleViewportHit(object: String, chain: String, resi: String, hasResidue: Bool) {
        guard !object.isEmpty else {
            // Empty-space click clears, exactly as metal_pick.pick_at does.
            if let fn = clearSeleFn { fn() } else { seleClearLocal() }
            syncFromSele()
            return
        }
        if object != focusObject {
            focusThenSelect(object: object, chain: chain, resi: resi, hasResidue: hasResidue)
        } else if hasResidue, let idx = residueIndex(chain: chain, resi: resi) {
            tapResidue(residueIndex: idx)
        }
        // object == focusObject && !hasResidue → no-op
    }

    /// Fire-and-forget refocus-then-select (used by the viewport hit path). Wraps
    /// `refocusAndSelect` in a Task, mirroring `focus` / `focusAwait`.
    private func focusThenSelect(object: String, chain: String, resi: String,
                                 hasResidue: Bool) {
        Task {
            await refocusAndSelect(object: object, chain: chain, resi: resi,
                                   hasResidue: hasResidue)
        }
    }

    /// Retarget design to `object`, then seed 'sele' with the clicked residue.
    ///
    /// The two steps cannot be reordered or collapsed: `focusAwait` is async (it
    /// enumerates residues and may score), and until it completes `lastSet[object]`
    /// does not exist — so a `syncFromSele()` run before it would resolve the new
    /// selection against the OLD object's residue set and silently produce garbage
    /// indices.
    private func refocusAndSelect(object: String, chain: String, resi: String,
                                  hasResidue: Bool) async {
        await focusAwait(object)
        // Two guards, for two different failures:
        //  - `lastSet[object] != nil`: a failed focus (enumerate threw) leaves no
        //    residue set, so a write would replace the user's selection with a
        //    residue that cannot resolve — neither their old selection nor a usable
        //    new one. Bail and leave 'sele' exactly as it was.
        //  - `focusObject == object`: existence is not CURRENCY. Two rapid clicks on
        //    two different non-focus objects spawn two Tasks; if the loser resumes
        //    last its write would land while the winner owns the focus, leaving
        //    'sele' on a NON-focused object — pink markers plus "nothing selected",
        //    because every read is scoped to the focus object.
        guard focusObject == object, lastSet[object] != nil else { return }
        if hasResidue {
            if let fn = setSeleResidueFn { fn(object, chain, resi, editSourceObject) }
            else { seleSetLocal(chain, resi) }
        } else {
            if let fn = clearSeleFn { fn() } else { seleClearLocal() }
        }
        syncFromSele()
    }

    // MARK: – Propensity hover/pin

    /// The "active" index for the propensity pill row: pinned takes precedence
    /// over hovered so the row stays up after a click.
    var activeResidueIndex: Int? { pinnedResidueIndex ?? hoveredResidueIndex }

    /// Find the index of a residue by chain+resi within the currently-focused
    /// object's residue list. Returns nil if there is no focus object, no
    /// cached set, or the residue isn't found.
    func residueIndex(chain: String, resi: String) -> Int? {
        guard let obj = focusObject, let set = lastSet[obj] else { return nil }
        return set.residues.firstIndex { $0.chain == chain && $0.resi == resi }
    }

    /// Propensity data for the active residue (hovered or pinned), or nil if
    /// none is active or the cache entry is missing/lacks propensities.
    var activePropensity: (propensities: [Float], nativeAA: Int, label: String)? {
        guard let obj = focusObject,
              let idx = activeResidueIndex,
              let set = lastSet[obj] else { return nil }
        let key = DesignCacheKey(object: obj, state: set.state, sequenceHash: set.sequenceHash)
        guard let scores = cache.get(key),
              idx < scores.propensities.count,
              let props = scores.propensities[idx],
              !props.isEmpty else { return nil }
        let res = set.residues[idx]
        let label = "\(res.chain)/\(res.resi) \(res.resn)"
        return (propensities: props, nativeAA: res.aa, label: label)
    }

    /// Update the hovered residue. Only for the FOCUS object; call
    /// `clearHover()` when the pointer leaves or is over a different object.
    /// Transient sidechain sticks follow the hovered residue.
    func setHovered(chain: String, resi: String) {
        hoveredResidueIndex = residueIndex(chain: chain, resi: resi)
        reconcileSticks()
    }

    /// Clear the hover indicator (pointer left viewport or moved to non-focus
    /// object). Drops the transient hover sticks (the pinned residue keeps its).
    func clearHover() {
        hoveredResidueIndex = nil
        reconcileSticks()
    }

    /// Toggle one residue addressed by (chain, resi). Retained because the sequence
    /// strip and several tests address residues that way. The pin itself is derived
    /// by `syncFromSele` — this method never writes `pinnedResidueIndex`.
    func setPinned(chain: String, resi: String) {
        guard let idx = residueIndex(chain: chain, resi: resi) else { return }
        tapResidue(residueIndex: idx)
    }

    /// Switch the coloring meaning and immediately recolor the focused object from cache.
    func setMeaning(_ m: DesignColorMeaning) {
        colorMeaning = m
        if let o = focusObject { recolor(o) }
    }

    // MARK: – The two typed inputs (#371)

    /// Fire-and-forget target apply (used by the UI on submit and by the object
    /// dropdown). Wraps `applyTargetAwait` in a Task, mirroring `focus`/`focusAwait`.
    func applyTarget() { Task { await applyTargetAwait() } }

    /// Resolve `targetText` to one structure and focus it. Awaitable so tests (and
    /// any caller that needs the focus to have happened) do not have to guess yields.
    func applyTargetAwait() async {
        let expr = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else { return }
        // An exact object name needs no engine round-trip. That is the dropdown's own
        // path, and the only one that works before the resolve seam is wired.
        let resolved: String?
        if allObjects.contains(expr) { resolved = expr } else { resolved = resolveTargetFn?(expr) }
        guard let object = resolved, !object.isEmpty else {
            errorText = "No structure matches '\(expr)'"
            return
        }
        errorText = nil
        targetText = expr               // normalise away the whitespace we trimmed
        targetResolvedObject = object
        await focusAwait(object)
    }

    /// Apply the region field: point 'sele' at `selectionText`, then re-derive the
    /// region from it — the same single pipeline a click goes through.
    func applySelection() {
        let expr = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, or the literal 'sele', means "what is selected right now". Rewriting
        // 'sele' from itself would be a no-op at best and would clobber the user's
        // clicks at worst, so this path only re-reads it.
        guard !expr.isEmpty, expr != Self.liveSelection else {
            if selectionText != Self.liveSelection { selectionText = Self.liveSelection }
            errorText = nil
            syncFromSele()
            return
        }
        guard let count = selectRegionFn?(expr) else {
            errorText = "Invalid selection '\(expr)'"
            return
        }
        selectionText = expr            // normalise away the whitespace we trimmed
        // A syntactically fine expression that matches nothing is worth saying out
        // loud: 'sele' is now empty, so the region silently disappeared.
        errorText = count > 0 ? nil : "No residues match '\(expr)'"
        syncFromSele()
    }

    /// The region field's scope button: go back to reading the live 'sele'. Peer of
    /// Design Backbone's hotspots scope button.
    func useCurrentSelection() {
        selectionText = Self.liveSelection
        errorText = nil
        syncFromSele()
    }

    /// Fire-and-forget focus (used by the UI). Wraps `focusAwait` in a Task.
    func focus(_ object: String) {
        Task { await focusAwait(object) }
    }

    /// Awaitable focus entry — used by unit tests so the full async lifecycle completes before asserting.
    ///
    /// On cache miss: scores off-main on `queue`, guards the job token, stores the result, then recolors.
    /// On cache hit: skips scoring, recolors immediately from cache.
    func focusAwait(_ object: String) async {
        // Switching focus: the previous object's hover/pin indices and managed
        // sticks are tied to its residue set, so tear them down cleanly.
        let previous = focusObject
        if previous != object {
            // C1/C2: If an edit session is active when focus changes, discard it
            // (delete working copy, re-enable source) before switching focus.
            if editing { teardownEditSession(discardCopy: true) }
            // Take the global show-all pass back down on the structure we are
            // leaving, or every object visited in one session accumulates sticks
            // (restore() re-applies colours and transparency, never representations).
            if showSidechains, let prev = previous { showAllSidechainsFn(prev, false) }
            teardownSticks(on: previous)
            hoveredResidueIndex = nil
            pinnedResidueIndex = nil   // re-derived below by syncFromSele for the new scope
            clearRegionState()
        }
        focusObject = object
        // Keep the target field showing what caused this focus: the object name for a
        // dropdown pick or auto-focus, the user's own expression when that is what
        // resolved here (#371).
        if targetResolvedObject != object {
            targetText = object
            targetResolvedObject = object
        }
        for o in allObjects where o != object { dim(o) }
        // Hoist token capture so both the success continuation and the catch can guard against it.
        rescoreToken += 1
        let token = rescoreToken
        rescoreMirror.set(token)   // update before dispatch so in-queue closures see the new value
        // New job owns the flag: wipe any stale `true` left by a superseded job.
        // This covers the cache-hit path too — a cache hit returns early without
        // ever reaching the `isScoring = true` below, so the flag stays false.
        isScoring = false
        do {
            let set = try enumerate(object, currentState(object))
            lastSet[object] = set
            syncFocusResidues()   // populate sequence strip as soon as residues are known
            syncFromSele()        // derive pin/region for the NEW focus's scope
            // Sidechains are shown by default (see `showSidechains`). Issued here,
            // after the residue set is known, so the flag and the on-screen state
            // cannot disagree — reconcileSticks() suppresses per-residue sticks
            // whenever the flag is set, so the flag must never be set alone.
            if showSidechains { showAllSidechainsFn(object, true) }

            let key = DesignCacheKey(object: object, state: set.state, sequenceHash: set.sequenceHash)
            if let scores = cache.get(key) {
                // Cache hit: recolor without re-scoring.
                updateSequenceScore(from: scores)
                recolor(object)
                return
            }

            // Cache miss: score off main.
            isScoring = true
            errorText = nil
            // Cleared on EVERY exit from the do-block (normal, guard, thrown) so a stranded
            // true can never permanently lock the toolbar. Token-guarded so a superseded job's
            // defer does not clear the flag out from under the winner.
            defer { if token == rescoreToken { isScoring = false } }

            // Capture what we need before leaving the main actor.
            let residues = set.validResidues
            let native = set.nativeSequence
            let validMask = set.residues.map { $0.valid }
            let scoreFn = score     // capture @MainActor-isolated property on main, then hand off

            let mirror = rescoreMirror   // capture class reference (not current value)
            let scores: DesignScores = try await withCheckedThrowingContinuation { cont in
                inferenceQueue.async {
                    // Early-exit BEFORE calling the model if this job was already superseded
                    // while waiting in the serial queue.  SupersededJobError is caught by the
                    // outer do/catch; the `guard token == rescoreToken` there exits cleanly.
                    guard mirror.get() == token else {
                        cont.resume(throwing: SupersededJobError()); return
                    }
                    do {
                        let result = try scoreFn(residues, native)
                        cont.resume(returning: DesignColor.scores(from: result, validMask: validMask))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }

            // Back on MainActor. Discard the result if a newer focus superseded this one.
            guard token == rescoreToken else { return }

            errorText = nil
            cache.set(key, scores)
            // isScoring cleared by the defer above on any exit from the do-block.
            updateSequenceScore(from: scores)
            recolor(object)

        } catch {
            // A superseded or post-exit() throw must not clobber state owned by the current job.
            // The defer in the do-block already ran by this point (Swift defers before catch),
            // so isScoring is already false for the winning token; no bare assignment needed.
            guard token == rescoreToken else { return }
            errorText = "\(error)"
        }
    }

    // MARK: – Private helpers

    /// Apply coloring from cache to `object` using the current `colorMeaning`.
    private func recolor(_ object: String) {
        guard let set = lastSet[object] else { return }
        let key = DesignCacheKey(object: object, state: set.state, sequenceHash: set.sequenceHash)
        guard let scores = cache.get(key) else { return }
        let scalar = DesignColor.scalar(scores, colorMeaning)
        let values: [(String, String, Float?)] = zip(set.residues, scalar).map { (res, val) in
            (res.chain, res.resi, val)
        }
        let dom = DesignColor.domain(colorMeaning)
        legendDomain = dom
        applyColoring(object, values, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound,
                      colorMeaning.metricKey, set.state)
    }

    /// Current displayed state for `object`. Delegates to the injected closure.
    private func currentState(_ object: String) -> Int { currentStateFn(object) }

    /// Sync `focusResidues` from `lastSet[focusObject]`. Call whenever either
    /// `focusObject` or `lastSet[focusObject]` changes so the published property
    /// stays current and the sequence-strip view re-renders correctly.
    private func syncFocusResidues() {
        focusResidues = focusObject.flatMap { lastSet[$0] }?.residues ?? []
    }

    // MARK: – Sidechain-stick reconciliation

    /// Stable dictionary key for a residue (chain + resi). Chain may be empty.
    private func stickKey(_ chain: String, _ resi: String) -> String {
        "\(chain)\u{1}\(resi)"
    }

    private func splitStickKey(_ key: String) -> (chain: String, resi: String) {
        let parts = key.components(separatedBy: "\u{1}")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    /// Drive the on-screen sidechain sticks to match the desired set:
    /// {pinnedResidue} ∪ {hoveredResidue} on the focus object. Residues we no
    /// longer want are hidden + their color restored (only if WE added them);
    /// newly-wanted residues get sticks shown (recording whether we added them).
    /// A residue that is both pinned and hovered appears once and never flickers.
    ///
    /// When `showSidechains` is on, every sidechain is already visible via the
    /// global show-all pass; hiding the non-pinned/non-hovered subset would undo
    /// that display. Return early so the broad show is untouched by hover/pin changes.
    private func reconcileSticks() {
        guard !showSidechains else { return }
        guard let obj = focusObject, let set = lastSet[obj] else { return }
        var desired = Set<String>()
        func want(_ idx: Int?) {
            if let i = idx, i >= 0, i < set.residues.count {
                let r = set.residues[i]
                desired.insert(stickKey(r.chain, r.resi))
            }
        }
        want(pinnedResidueIndex)
        want(hoveredResidueIndex)

        // Remove sticks we manage that are no longer wanted.
        for (key, added) in managedSticks where !desired.contains(key) {
            if added {
                let (c, r) = splitStickKey(key)
                _ = setSticksFn(obj, c, r, false)
            }
            managedSticks[key] = nil
        }
        // Add sticks for newly-wanted residues (idempotent: skip ones we track).
        for key in desired where managedSticks[key] == nil {
            let (c, r) = splitStickKey(key)
            managedSticks[key] = setSticksFn(obj, c, r, true)
        }
    }

    /// Hide every stick WE added on `obj` and forget them. Used on focus change
    /// and on exit, before restore() (which does not touch representations).
    private func teardownSticks(on obj: String?) {
        guard let obj = obj else { managedSticks.removeAll(); return }
        for (key, added) in managedSticks where added {
            let (c, r) = splitStickKey(key)
            _ = setSticksFn(obj, c, r, false)
        }
        managedSticks.removeAll()
    }

    /// Compute and publish `sequenceScore` as the mean of the non-nil `nativeFit`
    /// values in `scores`. nil if there are no valid residues.
    private func updateSequenceScore(from scores: DesignScores) {
        let valids = scores.nativeFit.compactMap { $0 }
        sequenceScore = valids.isEmpty ? nil : valids.reduce(0, +) / Float(valids.count)
    }

    // MARK: – Edit session teardown (C1/C2)

    /// Unified edit-session teardown. Cancels in-flight work, resets all mutable
    /// edit state, and ensures the ORIGINAL object ends up enabled/visible.
    ///
    /// - discardCopy: `true` → delete the working copy and re-enable the original
    ///   (via the `discard` closure). `false` (Keep path) → preserve the working
    ///   copy, but still re-enable the original (via `enableOriginalFn`).
    ///
    /// IMPORTANT: `compareEnabled` is reset via direct assignment — do NOT call
    /// `setCompare(false)` from here, as that would trigger the compare closure
    /// which calls `cmd.disable(src)` and leave the original hidden.
    private func teardownEditSession(discardCopy: Bool) {
        let src = editSourceObject
        let w = workingObject
        // Clear grid_mode and un-grey the parent BEFORE the discard/enable block so
        // grid mode never outlasts a session and the parent's confidence colors are
        // restored regardless of how the session ends (discard or keep).
        if let src { resetCompareFn(src) }
        // Restore focus to the source object (re-enabled below) before clearing state.
        if let src { focusObject = src }
        // Remove the working copy's residue-set entry and clear sticks tracking.
        if let w { lastSet[w] = nil }
        syncFocusResidues()   // re-point sequence strip at the source object's residues
        managedSticks.removeAll()
        if discardCopy {
            // discard(src, dst) deletes the working copy AND re-enables src.
            if let src, let w { discard(src, w) }
        } else {
            // Keep path: working copy stays; re-enable the original so both are visible.
            if let src { enableOriginalFn(src) }
            // ...and narrow 'sele' off the retained copy. A residue clicked during
            // the session is marked on BOTH objects (that is what survives a
            // repack), but `editSourceObject` is cleared below, so from here on no
            // Design write can address the copy: a click removing that region member
            // would leave it selected and pink there, with a spurious off-structure
            // badge and no way to clear it from the UI. Runs BEFORE the closing
            // `syncFromSele()` so the re-derive sees the narrowed selection.
            if let w, let fn = dropObjectFromSeleFn { fn(w) }
        }
        rescoreToken += 1; repackToken += 1
        rescoreMirror.set(rescoreToken); repackMirror.set(repackToken)
        editing = false
        editCount = 0
        repackDirty = false
        isRepacking = false
        workingObject = nil
        editedSequence = []
        editSourceObject = nil
        clearRegionState()
        compareEnabled = false   // bare assignment — do NOT call setCompare(false)
        // Re-derive: `clearRegionState()` above wipes the region, but 'sele' was
        // never touched by the teardown, so without this the derived state and
        // 'sele' silently disagree — pink markers on 2+ residues while the Redesign
        // button and palette row are gone. The panel poll cannot repair it: it is
        // digest-gated, and an unchanged 'sele' yields an identical digest, so the
        // re-derive is skipped and the wrong state persists until the user happens
        // to click a residue. Runs last, after `focusObject` has been re-pointed at
        // the source object, so the sync resolves against the right residue set.
        syncFromSele()
    }

    // MARK: – Engine-free 'sele' fallbacks
    //
    // Used when no closure is injected, so unit tests drive the REAL derivation
    // instead of no-op stubs. Behaviourally identical to the Python helpers:
    // toggle adds/removes, set replaces, clear empties.

    private func seleToggleLocal(_ chain: String, _ resi: String) {
        let k = stickKey(chain, resi)
        if stubSele.contains(k) { stubSele.remove(k) } else { stubSele.insert(k) }
    }

    private func seleSetLocal(_ chain: String, _ resi: String) {
        stubSele = [stickKey(chain, resi)]
    }

    private func seleClearLocal() { stubSele.removeAll() }

    /// Local counterpart of `SeleStateFn`: resolve `stubSele` against the focus
    /// object's residue set, in guide order.
    private func seleStateLocal() -> (indices: [Int], digest: String, off: Int) {
        guard let obj = focusObject, let set = lastSet[obj] else {
            return (indices: [], digest: "\(stubSele.count)", off: stubSele.count)
        }
        let idx = set.residues.enumerated().compactMap { i, r in
            stubSele.contains(stickKey(r.chain, r.resi)) ? i : nil
        }
        return (indices: idx, digest: "\(stubSele.count):\(idx)",
                off: max(0, stubSele.count - idx.count))
    }

    /// Read the current 'sele' state through the injected closure, or the local
    /// fallback when none is injected. Only reached with a focus object present
    /// (`syncFromSele` guards first), so the no-focus branch just defers to the
    /// fallback rather than inventing an empty result.
    private func readSeleState() -> (indices: [Int], digest: String, off: Int) {
        guard let obj = focusObject, let set = lastSet[obj] else { return seleStateLocal() }
        if let fn = seleStateFn { return fn(obj, editSourceObject, set.state) }
        return seleStateLocal()
    }

    // MARK: – Deriving the mode from 'sele'

    /// Re-derive the Design-mode selection state from the active 'sele'.
    ///
    /// This is the ONLY writer of `pinnedResidueIndex` and
    /// `selectedResidueIndices`. The count of DESIGNABLE residues in
    /// `sele ∩ scope(focusObject, editSourceObject)` picks the mode:
    ///   0  → nothing active (propensity row renders in its greyed idle form)
    ///   1  → that residue is pinned; the region stays empty so `regionModeActive`
    ///        is false and the propensity pills behave exactly as before
    ///   ≥2 → the region is designated on 'sele'; the pin is cleared so the
    ///        palette row and the Redesign button take over
    ///
    /// Returns the designable count, so callers and tests can assert the mode
    /// without re-reading three properties.
    @discardableResult
    func syncFromSele() -> Int {
        guard let obj = focusObject, let set = lastSet[obj] else {
            pinnedResidueIndex = nil
            selectedResidueIndices = []
            seleResiduesOffFocus = 0
            return 0
        }
        let state = readSeleState()
        lastSeleDigest = state.digest
        let inScope = state.indices.filter { $0 >= 0 && $0 < set.residues.count }
        let valid = inScope.filter { set.residues[$0].valid }.sorted()
        seleResiduesOffFocus = max(0, state.off)
        if valid.count >= 2 {
            selectedResidueIndices = valid
            pinnedResidueIndex = nil
        } else {
            selectedResidueIndices = []
            pinnedResidueIndex = valid.first
        }
        reconcileSticks()
        return valid.count
    }

    /// Panel-poll entry point: re-derive only when the observed digest differs from
    /// the last one resolved. Returns true iff a re-derive happened.
    ///
    /// The gate lives here rather than at the call site so it is testable without
    /// the engine, and so the no-focus case can be handled where it is understood:
    /// `syncFromSele()` cannot read a digest without a focus object (the read is
    /// scoped to one), so it leaves `lastSeleDigest` untouched and the 500 ms poll
    /// would re-derive on EVERY tick for as long as Design mode is on with no focus
    /// — republishing four `@Published` properties and invalidating the design bar,
    /// the compact panel and the sequence strip twice a second, indefinitely.
    /// Entering Design mode with 2+ objects loaded (so `enter()` does not
    /// auto-focus) and any non-empty 'sele' is exactly that state. Adopting the
    /// digest the poll itself saw closes it.
    ///
    /// The condition is "did the sync actually RESOLVE a digest", not
    /// `focusObject == nil`: there is a second no-digest path where `focusObject`
    /// is non-nil but `lastSet[obj]` is missing. `focusAwait` sets `focusObject`
    /// BEFORE calling `enumerate` and its catch only sets `errorText`, so after a
    /// failed focus the controller sits in exactly that state — and the poll would
    /// re-derive on every tick forever, which is the symptom this guard exists for.
    @discardableResult
    func syncFromSeleIfChanged(digest: String) -> Bool {
        guard digest != lastSeleDigest else { return false }
        let before = lastSeleDigest
        syncFromSele()
        if lastSeleDigest == before { lastSeleDigest = digest }
        return true
    }

    // MARK: – Region redesign: designation + palette (Task 2)

    /// Toggle one residue (full-length index) in the active 'sele'.
    ///
    /// The single gesture entry point: the viewport, the sequence strip, and the
    /// compact panel all land here, so a click means the same thing everywhere and
    /// the same thing it means in normal mode. The resulting mode (pin vs region)
    /// is DERIVED by `syncFromSele`, never decided here.
    func tapResidue(residueIndex i: Int) {
        guard let obj = focusObject, let set = lastSet[obj],
              i >= 0, i < set.residues.count else { return }
        let r = set.residues[i]
        if let fn = toggleSeleFn { fn(obj, r.chain, r.resi, editSourceObject) }
        else { seleToggleLocal(r.chain, r.resi) }
        syncFromSele()
    }

    /// Toggle an amino acid (0..<20) in/out of the region sampling palette.
    func togglePalette(_ aa: Int) {
        guard aa >= 0, aa < 20 else { return }
        if paletteAllowed.contains(aa) { paletteAllowed.remove(aa) } else { paletteAllowed.insert(aa) }
    }

    /// Reset all region state. Region state can exist without an edit session
    /// (residues selected before the first redesign), so this is called on
    /// mode exit and focus change too, not only in teardownEditSession.
    private func clearRegionState() {
        selectedResidueIndices = []
        paletteAllowed = Set(0..<20)
        redesignSnapshot = nil
        isRedesigning = false
        pendingSizeWarning = nil
        suppressSizeGuardOnce = false   // defence in depth: clear on focus change / mode exit
        designToken += 1   // cancel any in-flight region design
        designMirror.set(designToken)
    }

    // MARK: – Region redesign: the design() action + revert (Task 3)

    /// Fire-and-forget region redesign (UI button). Wraps redesignSelectionAwait.
    func redesignSelection() { Task { await redesignSelectionAwait() } }

    /// Run design() over the selected region with the rest of the sequence fixed,
    /// scatter the result into editedSequence, then rescore + (auto)repack.
    /// Snapshots editedSequence first for a one-level revert.
    func redesignSelectionAwait() async {
        // Consume the one-shot guard suppression at entry, before any early return.
        // Any path out of this function must leave the flag cleared — a stale `true`
        // would silently skip the memory check on a LATER, unrelated redesign, which
        // is the exact failure this guard exists to prevent (the guard is read below,
        // after beginEditIfNeeded() and the `set` lookup, where it has always lived).
        let skipGuard = suppressSizeGuardOnce
        suppressSizeGuardOnce = false

        guard !selectedResidueIndices.isEmpty else { return }
        guard paletteAllowed.contains(where: { $0 >= 0 && $0 < 20 }) else { return }  // ≥1 allowed AA
        beginEditIfNeeded()
        guard editing, let focus = focusObject, let set = lastSet[focus] else { return }

        // Memory gate. Consulted here only: repack and rescore run over the same
        // residue set, so clearing this gate clears them too, and three prompts for
        // one user action would be hostile. Focus scoring is deliberately ungated —
        // it is what populates the sequence strip, and refusing it would make an
        // object unopenable rather than merely un-redesignable.
        //
        // `suppressSizeGuardOnce` is set by `confirmPendingWarning()` so the
        // confirmed re-entry is not re-gated into an infinite warn loop. It is
        // consumed at function entry (above) so no early return can leave it stale.
        // Binding the decision to a `let` keeps the `switch` subject a plain value.
        let residueCount = set.residues.count
        let sizeDecision: DesignSizeGuard.Decision = skipGuard
            ? .ok
            : sizeDecisionProvider(residueCount)
        switch sizeDecision {
        case .ok:
            break
        case .warn(let estimate, let available):
            pendingSizeWarning = SizeWarning(residueCount: residueCount,
                                             estimatedBytes: estimate,
                                             availableBytes: available)
            return
        case .refuse(let maxFitting):
            pendingSizeWarning = nil
            errorText = maxFitting > 0
                ? "This structure is too large to design on this device (\(residueCount) residues; about \(maxFitting) would fit). Free memory or use a smaller structure."
                : "Not enough free memory to run Design. Close other apps and try again."
            return
        }

        // One-level revert snapshot (captures earlier manual edits + editCount).
        redesignSnapshot = RedesignSnapshot(seq: editedSequence, editCount: editCount)

        // Full-length ↔ valid-projected maps (the single-source-of-truth conversion).
        let validFullIndices = set.residues.enumerated().filter { $0.element.valid }.map { $0.offset }
        var fullToValid: [Int: Int] = [:]
        for (v, f) in validFullIndices.enumerated() { fullToValid[f] = v }
        let residues = set.validResidues
        let L = residues.count
        let nativeValid = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let freeValid = Set(selectedResidueIndices.compactMap { fullToValid[$0] })
        guard !freeValid.isEmpty else { redesignSnapshot = nil; return }
        let fixed = Set(0..<L).subtracting(freeValid)
        let inactive = Set((0..<20).filter { !paletteAllowed.contains($0) })
        let omit = Array(repeating: inactive, count: L)
        let designFn = designRegionFn
        let temp = designTemperature

        designToken += 1
        let token = designToken
        designMirror.set(token)   // update before dispatch so queued closures see the new value
        isRedesigning = true
        // The busy flag drives an INPUT-BLOCKING overlay, so it must never be left
        // set — `defer` clears it on every exit (early return, error, cancellation),
        // which a chain of manual assignments cannot guarantee. Guarded by the token
        // so a superseded call doesn't clear the flag out from under the winner.
        defer { if token == designToken { isRedesigning = false } }

        let dMirror = designMirror   // capture class reference (not current value)
        let result: [Int]? = try? await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                // Early-exit BEFORE calling the model if this job was already superseded.
                // SupersededJobError + try? → nil result; existing guard exits cleanly.
                guard dMirror.get() == token else {
                    cont.resume(throwing: SupersededJobError()); return
                }
                do { cont.resume(returning: try designFn(residues, fixed, nativeValid, omit, temp)) }
                catch { cont.resume(throwing: error) }
            }
        }

        guard token == designToken else { return }

        guard let result, result.count == L else {
            if let snap = redesignSnapshot { editedSequence = snap.seq; editCount = snap.editCount }
            redesignSnapshot = nil
            errorText = "Region redesign failed"
            return
        }

        // Scatter designed identities into free (full-length) positions only.
        var changed = 0
        let w = workingObject
        for v in freeValid {
            let f = validFullIndices[v]
            let aa = result[v]
            if editedSequence[f] != aa {
                editedSequence[f] = aa
                changed += 1
                if let w, f < set.residues.count {
                    let r = set.residues[f]
                    mutateDisplay(w, r.chain, r.resi, aa)   // backbone-only until repack
                }
            }
        }
        editCount += changed
        repackDirty = true

        // The redesign itself is done (the new sequence is applied). The follow-up
        // rescore/repack are separate operations that own their own busy flags, so a
        // slow — or stalled — repack can never strand the "Redesigning region…"
        // overlay. Repack raises its own "Repacking sidechains…" while it runs.
        isRedesigning = false

        await rescoreWorkingObject()
        if autoRepack { await repackNowAwait() }
    }

    /// Proceed with a redesign the user confirmed after a size warning. Writes an
    /// autosave first so a jetsam kill during the run costs no work, then re-enters
    /// the normal path with the guard suppressed for this one call.
    func confirmPendingWarning() async {
        guard pendingSizeWarning != nil else { return }
        pendingSizeWarning = nil
        autosaveBeforeLargeRun()
        suppressSizeGuardOnce = true
        await redesignSelectionAwait()
    }

    /// Dismiss a size warning without running anything.
    func cancelPendingWarning() { pendingSizeWarning = nil }

    /// Undo the last region redesign: restore the pre-batch sequence + editCount.
    /// One level; earlier manual edits (captured in the snapshot) are preserved.
    func revertRedesign() {
        guard let snap = redesignSnapshot else { return }
        editedSequence = snap.seq
        editCount = snap.editCount
        redesignSnapshot = nil
        repackDirty = true
        Task {
            await rescoreWorkingObject()
            if autoRepack { await repackNowAwait() }
        }
    }

    // MARK: – Edit session (Task 2 + 3 + 4)

    /// Starts an edit session for the focused object if one is not already active.
    /// Idempotent — safe to call multiple times; only the first call creates the working copy.
    func beginEditIfNeeded() {
        guard !editing, let focus = focusObject else { return }
        let native = lastSet[focus]?.residues.map { $0.aa } ?? []
        editedSequence = native
        editSourceObject = focus                // I2: store source before creating working copy
        let w = makeWorkingCopy(focus)          // I2: actual name returned by Python
        workingObject = w
        editing = true; editCount = 0; repackDirty = false

        // Carry the residue set from the original to the working copy so all residue-keyed
        // paths (activePropensity, reconcileSticks, applyMutationState chain/resi lookup)
        // target the SHOWN object without re-enumeration.
        if let set = lastSet[focus] {
            lastSet[w] = set
            // Carry the native-sequence score so the propensity row + coloring appear
            // immediately instead of waiting for the async rescore.
            let nativeKey = DesignCacheKey(object: focus, state: set.state, sequenceHash: set.sequenceHash)
            if let scores = cache.get(nativeKey) {
                cache.set(DesignCacheKey(object: w, state: set.state, sequenceHash: set.sequenceHash), scores)
            }
        }
        // Move sticks from the hidden original to the shown working copy.
        teardownSticks(on: focus)
        // Switch focus WITHOUT clearing the pin: direct assignment avoids setFocused/focus()
        // which would clear pinnedResidueIndex and hoveredResidueIndex.
        focusObject = w
        syncFocusResidues()   // re-point sequence strip at the working copy's residues
        // Reconcile so the pinned/hovered residue's sticks appear on the working copy.
        reconcileSticks()
    }

    /// Shared state-update kernel for `applyMutation` and `applyMutationAwait`.
    /// Returns `true` if the mutation was applied; `false` for no-ops (same aa or out-of-range).
    @discardableResult
    private func applyMutationState(residueIndex i: Int, aa: Int) -> Bool {
        beginEditIfNeeded()
        guard editing, i >= 0, i < editedSequence.count, editedSequence[i] != aa else { return false }
        // M2: invalid (missing-backbone) residues are not mutable.
        if let focus = focusObject, let set = lastSet[focus] {
            guard i < set.residues.count, set.residues[i].valid else { return false }
        }
        editedSequence[i] = aa
        editCount += 1
        repackDirty = true
        redesignSnapshot = nil   // a manual edit invalidates the one-level region-redesign revert
        if let w = workingObject {
            // Resolve chain + resi from the focus object's residue set (same ordering as editedSequence).
            let chain: String
            let resi: String
            if let focus = focusObject, let set = lastSet[focus], i >= 0, i < set.residues.count {
                chain = set.residues[i].chain
                resi  = set.residues[i].resi
            } else {
                chain = ""; resi = "\(i + 1)"
            }
            mutateDisplay(w, chain, resi, aa)
        }
        return true
    }

    /// Apply a single-residue amino-acid mutation to the current edit session.
    /// Begins the edit session on the first call. Kicks an off-main rescore (Task 3).
    func applyMutation(residueIndex i: Int, aa: Int) {
        guard applyMutationState(residueIndex: i, aa: aa) else { return }
        Task { await rescoreWorkingObject() }
    }

    /// Awaitable mutation + rescore — used by unit tests so the full async lifecycle
    /// completes before asserting. The sync `applyMutation` uses the same state-update
    /// path then fires `rescoreWorkingObject` in a background Task.
    func applyMutationAwait(residueIndex i: Int, aa: Int) async {
        guard applyMutationState(residueIndex: i, aa: aa) else { return }
        // Repack before rescore: the repack is what the user SEES (new sidechain
        // geometry) and is several times cheaper than scoring; the rescore only
        // drives confidence colouring. Running repack first makes the structural
        // change visible on-screen ~5× sooner on a physical device. Total time on
        // the serial inference queue is unchanged — only the order in which
        // feedback arrives.
        if autoRepack { await repackNowAwait() }
        await rescoreWorkingObject()
    }

    /// Place all sidechains for the current edited sequence off-main, then load the
    /// resulting all-atom PDB into the working object and clear `repackDirty`.
    /// Job-token guarded (superseded by a subsequent mutation or focus change).
    func repackNowAwait() async {
        guard editing, let w = workingObject, repackDirty else { return }
        // C3: we need the residue set to project the sequence; bail if unavailable.
        guard let focus = focusObject, let set = lastSet[focus] else { return }
        // Use a separate repackToken so repacks supersede each other but do NOT
        // cancel a concurrent in-flight rescore (which uses rescoreToken).
        repackToken += 1; let token = repackToken
        repackMirror.set(token)   // update before dispatch so queued closures see the new value
        isRepacking = true
        // Same input-blocking overlay as the redesign: clear on EVERY exit via
        // `defer`, token-guarded so a superseded repack can't clear the winner's flag.
        defer { if token == repackToken { isRepacking = false } }
        // I1: capture the FULL sequence before dispatch so we can detect a mid-repack mutation.
        let capturedFullSeq = editedSequence
        // C3: project through the valid-residue mask to align with validResidues.
        let seq = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let residues = set.validResidues
        let repackFn = repack     // capture @MainActor-isolated property before leaving
        // Use do/catch instead of try? so MLX / MPNNKit errors surface to the user
        // via the error banner (Task 1) rather than being silently swallowed.
        let pMirror = repackMirror   // capture class reference (not current value)
        let pdb: String
        do {
            pdb = try await withCheckedThrowingContinuation { cont in
                inferenceQueue.async {
                    // Early-exit BEFORE calling the model if this job was already superseded.
                    // SupersededJobError → catch below → guard token==repackToken exits clean
                    // (token won't match since the mirror advanced when we were superseded).
                    // This is NOT the same as an empty-PDB: that path reaches the
                    // `guard !pdb.isEmpty` check after a SUCCESSFUL return from repackFn;
                    // a superseded job never calls repackFn at all and never sets pdb.
                    guard pMirror.get() == token else {
                        cont.resume(throwing: SupersededJobError()); return
                    }
                    do { cont.resume(returning: try repackFn(residues, seq)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } catch {
            // Only report the error if this repack is still the winner; a superseded
            // job must not stomp the errorText owned by the cancelling call.
            // SupersededJobError lands here too, but its token will not match,
            // so the guard below exits without setting errorText.
            guard token == repackToken else { return }
            errorText = "Repack failed: \(error)"
            return   // isRepacking cleared by the `defer` above
        }
        guard token == repackToken else { return }
        guard !pdb.isEmpty else {
            errorText = "Repack produced no structure."
            return   // isRepacking cleared by the `defer` above
        }
        // I1: only load if the sequence has not changed since dispatch.
        if capturedFullSeq == editedSequence {
            #if DEBUG
            NSLog("[Design] loadRepacked: starting, pdb=%d chars into '%@'", pdb.count, w)
            #endif
            loadRepacked(w, pdb, editSourceObject)
            #if DEBUG
            NSLog("[Design] loadRepacked: done")
            #endif
            repackDirty = false
            // Full topology replace (load_repacked deletes+renames the object) clears
            // PyMOL's per-atom colors and representations.  Re-apply confidence
            // coloring from the cache — the sequence didn't change so no new score
            // is needed; the last rescoreWorkingObject() result is still valid.
            let colorSeq = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
            let colorKey = DesignCacheKey(object: w, state: set.state, sequenceHash: colorSeq.hashValue)
            if let scores = cache.get(colorKey) {
                let scalar = DesignColor.scalar(scores, colorMeaning)
                let vals: [(String, String, Float?)] = zip(set.residues, scalar).map { ($0.chain, $0.resi, $1) }
                let dom = DesignColor.domain(colorMeaning)
                applyColoring(w, vals, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound,
                              colorMeaning.metricKey, set.state)
            }
            // Stale sidechain sticks are gone (object was replaced); clear tracking
            // and re-add for the pinned/hovered residue on the fresh atoms.
            teardownSticks(on: w)
            reconcileSticks()
            // Re-apply global sidechain display if the user had it turned on.
            if showSidechains { showAllSidechainsFn(w, true) }
        }
        // else: mutation happened mid-repack (case c); repackDirty stays true so the
        // next repack (triggered by the new mutation) loads the current coords.
        // isRepacking cleared by the `defer` above (covers every exit path).
    }

    /// Sync fire-and-forget repack; called by UI buttons (Task 6). Wraps `repackNowAwait` in a Task.
    func repackNow() { Task { await repackNowAwait() } }

    /// Enable or disable the compare view (shows the original structure alongside
    /// the edited working copy). Updates `compareEnabled` and calls the injected
    /// `compare` closure so the PyMOL display follows.
    func setCompare(_ on: Bool) {
        compareEnabled = on
        compare(on, sideBySide)
    }

    /// Switch the compare layout between overlap (default) and side-by-side grid.
    /// Only has a visual effect when `compareEnabled` is true; always updates the
    /// `sideBySide` flag so the next compare-on picks up the chosen mode.
    func setSideBySide(_ on: Bool) {
        sideBySide = on
        guard compareEnabled else { return }
        compare(true, on)   // re-apply compare with the new layout
    }

    /// Show or hide all sidechain sticks on the focus object (and parent when
    /// compare is on). When turning OFF, calls `reconcileSticks()` so managed
    /// hover/pin sidechains remain shown.
    func setShowSidechains(_ on: Bool) {
        showSidechains = on
        if let obj = focusObject {
            showAllSidechainsFn(obj, on)
            if compareEnabled, let src = editSourceObject {
                showAllSidechainsFn(src, on)
            }
        }
        if !on { reconcileSticks() }
    }

    /// Score the working object off-main using the current `editedSequence`, then
    /// recolor it. Reuses the Phase-2a scoring block shape (serial queue +
    /// withCheckedThrowingContinuation + job-token guard). Task 4 adds repack.
    private func rescoreWorkingObject() async {
        guard let w = workingObject,
              let focus = focusObject,
              let set = lastSet[focus] else { return }
        rescoreToken += 1
        let token = rescoreToken
        rescoreMirror.set(token)   // update before dispatch so queued closures see the new value
        // New job takes ownership: wipe any stale `true` from a superseded rescore.
        isRescoring = false
        isRescoring = true
        // Cleared on every exit via token-guarded defer — same pattern as isRepacking and
        // isRedesigning — so a stranded flag cannot permanently lock the mode controls.
        defer { if token == rescoreToken { isRescoring = false } }
        let residues = set.validResidues
        // C3: project editedSequence through the valid mask to align with validResidues.
        let seq = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let validMask = set.residues.map { $0.valid }
        let scoreFn = score               // capture @MainActor-isolated property before leaving

        let rMirror = rescoreMirror   // capture class reference (not current value)
        let result: MPNNModel.ScoreResult? = try? await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                // Early-exit BEFORE calling the model if this job was already superseded.
                // SupersededJobError + try? → nil result; existing guard exits cleanly.
                guard rMirror.get() == token else {
                    cont.resume(throwing: SupersededJobError()); return
                }
                do { cont.resume(returning: try scoreFn(residues, seq)) }
                catch { cont.resume(throwing: error) }
            }
        }

        // Back on MainActor. Discard if a newer mutation superseded this one.
        // isRescoring cleared by the defer above when control leaves this function.
        guard token == rescoreToken, let r = result else { return }

        let scores = DesignColor.scores(from: r, validMask: validMask)
        cache.set(DesignCacheKey(object: w, state: set.state, sequenceHash: seq.hashValue), scores)
        updateSequenceScore(from: scores)

        let scalar = DesignColor.scalar(scores, colorMeaning)
        let values: [(String, String, Float?)] = zip(set.residues, scalar).map { ($0.chain, $0.resi, $1) }
        let dom = DesignColor.domain(colorMeaning)
        legendDomain = dom
        applyColoring(w, values, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound,
                      colorMeaning.metricKey, set.state)
    }

    /// Discard the working copy and reset all edit-session state.
    func discardEdits() {
        teardownEditSession(discardCopy: true)
    }

    /// End the edit session and keep the working-copy object (sync, no repack).
    /// Use `keepEditsAwait()` from async contexts to repack-if-dirty before closing.
    func keepEdits() {
        teardownEditSession(discardCopy: false)
    }

    /// Async variant of `keepEdits`: repacks first if `repackDirty`, then closes the session.
    /// Original object ends enabled (visible); working copy is preserved.
    func keepEditsAwait() async {
        if repackDirty { await repackNowAwait() }
        teardownEditSession(discardCopy: false)
    }

    // MARK: – Test hooks

#if DEBUG
    /// Inject edit-session closures after initialization. Used by unit tests only;
    /// matches the Phase-2a pattern of injecting stubs that bypass PyMOL / MLX.
    func injectEdit(makeWorkingCopy: @escaping MakeWorkingCopyFn,
                    mutateDisplay: @escaping MutateDisplayFn,
                    discard: @escaping DiscardFn,
                    compare: @escaping CompareFn,
                    enableOriginal: @escaping EnableOriginalFn = { _ in },
                    resetCompare: @escaping ResetCompareFn = { _ in }) {
        self.makeWorkingCopy = makeWorkingCopy
        self.mutateDisplay = mutateDisplay
        self.discard = discard
        self.compare = compare
        self.enableOriginalFn = enableOriginal
        self.resetCompareFn = resetCompare
    }

    /// Override the score closure for testing. Replaces the constructor-injected stub
    /// so that mutation rescores use the supplied function instead.
    func injectScore(_ fn: @escaping ScoreFn) {
        score = fn
    }

    /// Override the repack + loadRepacked closures for testing (Task 4).
    func injectRepack(repack: @escaping RepackFn, loadRepacked: @escaping LoadRepackedFn) {
        self.repack = repack
        self.loadRepacked = loadRepacked
    }

    /// Override the showAllSidechains closure for testing (Change 7).
    func injectShowAllSidechains(_ fn: @escaping ShowAllSidechainsFn) {
        self.showAllSidechainsFn = fn
    }

    /// Override the setSticks closure for testing (Change 8).
    func injectSetSticks(_ fn: @escaping SticksFn) {
        self.setSticksFn = fn
    }

    /// Override the region design closure for testing (Task 2/3).
    func injectRegion(designRegion: @escaping DesignRegionFn) {
        self.designRegionFn = designRegion
    }

    /// Override the 'sele' closures for testing. Any argument left nil keeps the
    /// engine-free local fallback for that operation.
    func injectSele(seleState: SeleStateFn? = nil,
                    toggleSele: ToggleSeleFn? = nil,
                    setSeleResidue: SetSeleResidueFn? = nil,
                    clearSele: ClearSeleFn? = nil,
                    dropObjectFromSele: DropObjectFromSeleFn? = nil) {
        if let seleState { self.seleStateFn = seleState }
        if let toggleSele { self.toggleSeleFn = toggleSele }
        if let setSeleResidue { self.setSeleResidueFn = setSeleResidue }
        if let clearSele { self.clearSeleFn = clearSele }
        if let dropObjectFromSele { self.dropObjectFromSeleFn = dropObjectFromSele }
    }

    /// Override the target/region field closures for testing (#371). Any argument
    /// left nil keeps the engine-free behaviour for that operation: an unresolvable
    /// target reports "no structure matches", and a typed region reports "invalid".
    func injectFields(resolveTarget: ResolveTargetFn? = nil,
                      selectRegion: SelectRegionFn? = nil) {
        if let resolveTarget { self.resolveTargetFn = resolveTarget }
        if let selectRegion { self.selectRegionFn = selectRegion }
    }

    /// Override the model-release closure for testing (Phase 2d).
    func injectReleaseModel(_ fn: @escaping ReleaseModelFn) {
        self.releaseModelFn = fn
    }

    /// Awaitable entry to the refocus-then-select path, so a test can await the
    /// async refocus deterministically instead of polling `focusObject` through a
    /// guessed number of `Task.yield()`s — `focusAwait` crosses a real
    /// DispatchQueue hop, so any fixed yield count is a race. Delegates to the SAME
    /// private method the synchronous `focusThenSelect` wraps in a Task; it does not
    /// duplicate the body. Mirrors `focus` / `focusAwait` and
    /// `applyMutation` / `applyMutationAwait`.
    func refocusAndSelectAwait(object: String, chain: String, resi: String,
                               hasResidue: Bool) async {
        await refocusAndSelect(object: object, chain: chain, resi: resi,
                               hasResidue: hasResidue)
    }

    /// Set focus + a synthetic residue set (built from `nativeSequence`) without the async
    /// score lifecycle. Mirrors the direct-stub construction in DesignControllerTests.
    /// `validFlags`: optional per-residue validity array; nil → all invalid (backbone: nil).
    /// Pass `[true, true, ...]` to make residues mutable (needed for M2 guard).
    func setFocusForTest(_ object: String, nativeSequence: [Int], validFlags: [Bool]? = nil) {
        focusObject = object
        let residues = nativeSequence.enumerated().map { i, aa -> DesignResidue in
            let isValid = validFlags.map { i < $0.count ? $0[i] : false } ?? false
            var bb: MPNNModel.Residue? = nil
            if isValid {
                bb = MPNNModel.Residue(n: .zero, ca: .zero, c: .zero, o: .zero,
                                       chain: 0, resSeq: i + 1)
            }
            return DesignResidue(chain: "A", resi: "\(i + 1)", resn: "UNK", aa: aa,
                                 backbone: bb, valid: isValid)
        }
        lastSet[object] = DesignResidueSet(object: object, state: 1, residues: residues)
    }
#endif
}
#endif
