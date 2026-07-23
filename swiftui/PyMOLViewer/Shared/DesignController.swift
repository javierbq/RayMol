#if RAYMOL_MPNN
import Foundation
import MPNNKit
import Combine

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
    typealias LoadRepackedFn = (String, String) -> Void

    /// Show or hide all sidechain sticks on `obj` (with cnc element coloring on show).
    typealias ShowAllSidechainsFn = (String, Bool) -> Void

    /// Apply per-residue coloring to `objectName`.
    /// `values`: (chain, resi, scalar?) for every residue in the set order.
    typealias ColorFn = (_ obj: String, _ values: [(String, String, Float?)],
                         _ palette: String, _ lo: Float, _ hi: Float) -> Void

    /// Show/hide non-destructive sidechain sticks for one residue on `obj`.
    /// Returns whether WE added the sticks on a show (`on == true`) — the
    /// residue had none before; `false` if it already had sticks (user's own)
    /// or on a hide. Used so hover-off only removes sticks we introduced.
    typealias SticksFn = (_ obj: String, _ chain: String, _ resi: String, _ on: Bool) -> Bool

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
    private var loadRepacked: LoadRepackedFn = { _, _ in }
    private var showAllSidechainsFn: ShowAllSidechainsFn = { _, _ in }

    // MARK: – Edit-session published state (Task 2)

    @Published private(set) var editing = false
    @Published private(set) var editCount = 0
    @Published private(set) var repackDirty = false
    @Published var autoRepack = true
    @Published private(set) var isRepacking = false
    /// True while the compare toggle is on (original structure shown alongside the working copy).
    @Published private(set) var compareEnabled = false
    /// True while the Side-by-side grid layout is selected (only meaningful when compareEnabled).
    /// false = overlap (grey + transparent ghost behind design); true = grid (own confidence colors).
    @Published private(set) var sideBySide = false
    /// True while all sidechain sticks are shown on the design (and parent when compare is on).
    @Published private(set) var showSidechains = false
    /// Mean per-residue native-fit log-probability over the valid residues of the focus object.
    /// nil until the first score result arrives. Updated after every rescore (including edits).
    /// Higher (closer to 0) = better sequence–structure fit.
    @Published var sequenceScore: Float?
    private(set) var workingObject: String?
    private(set) var editedSequence: [Int] = []
    /// The source object that the current edit session is based on.
    /// Set when the session begins; cleared in teardownEditSession.
    private(set) var editSourceObject: String?

    // MARK: – Private state

    private let cache = DesignScoreCache()
    /// Single serial queue for all off-main MPNN inference (scoring and repack).
    /// Serial guarantees MLX model calls never overlap; continuations resume back on MainActor.
    private let inferenceQueue = DispatchQueue(label: "io.raymol.design.inference", qos: .userInitiated)
    /// Incremented on each focus/rescore; a superseded score checks its captured token against this.
    private var rescoreToken: Int = 0
    /// Incremented on each repack; superseded repacks are discarded without touching rescoreToken.
    private var repackToken: Int = 0
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
                     loadRepacked: @escaping LoadRepackedFn = { _, _ in },
                     showAllSidechains: @escaping ShowAllSidechainsFn = { _, _ in }) {
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
    }

    // MARK: – Public interface

    /// Called when entering Design mode: snapshot current visuals, auto-focus if exactly one object.
    func enter() {
        snapshot(allObjects)
        if allObjects.count == 1 { focus(allObjects[0]) }
    }

    /// Called when exiting Design mode: restore visuals and cancel any pending score.
    func exit() {
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
        rescoreToken += 1; repackToken += 1   // cancel any in-flight scoring or repack
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

    /// Pin or unpin a residue. Tapping the same residue again toggles the pin
    /// off. Pinned sticks are persistent; unpinning removes them (unless the
    /// residue is also currently hovered, in which case reconcile keeps them
    /// as transient hover sticks).
    func setPinned(chain: String, resi: String) {
        let idx = residueIndex(chain: chain, resi: resi)
        pinnedResidueIndex = (idx == pinnedResidueIndex) ? nil : idx
        reconcileSticks()
    }

    /// Switch the coloring meaning and immediately recolor the focused object from cache.
    func setMeaning(_ m: DesignColorMeaning) {
        colorMeaning = m
        if let o = focusObject { recolor(o) }
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
            teardownSticks(on: previous)
            hoveredResidueIndex = nil
            pinnedResidueIndex = nil
        }
        focusObject = object
        for o in allObjects where o != object { dim(o) }
        // Hoist token capture so both the success continuation and the catch can guard against it.
        rescoreToken += 1
        let token = rescoreToken
        do {
            let set = try enumerate(object, currentState(object))
            lastSet[object] = set
            syncFocusResidues()   // populate sequence strip as soon as residues are known

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

            // Capture what we need before leaving the main actor.
            let residues = set.validResidues
            let native = set.nativeSequence
            let validMask = set.residues.map { $0.valid }
            let scoreFn = score     // capture @MainActor-isolated property on main, then hand off

            let scores: DesignScores = try await withCheckedThrowingContinuation { cont in
                inferenceQueue.async {
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
            isScoring = false
            updateSequenceScore(from: scores)
            recolor(object)

        } catch {
            // A superseded or post-exit() throw must not clobber state owned by the current job.
            guard token == rescoreToken else { return }
            isScoring = false
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
        applyColoring(object, values, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound)
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
        }
        rescoreToken += 1; repackToken += 1
        editing = false
        editCount = 0
        repackDirty = false
        isRepacking = false
        workingObject = nil
        editedSequence = []
        editSourceObject = nil
        compareEnabled = false   // bare assignment — do NOT call setCompare(false)
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
        await rescoreWorkingObject()
        if autoRepack { await repackNowAwait() }
    }

    /// Place all sidechains for the current edited sequence off-main, then load the
    /// resulting all-atom PDB into the working object and clear `repackDirty`.
    /// Job-token guarded (superseded by a subsequent mutation or focus change).
    func repackNowAwait() async {
        guard editing, let w = workingObject, repackDirty else { return }
        // C3: we need the residue set to project the sequence; bail if unavailable.
        guard let focus = focusObject, let set = lastSet[focus] else { return }
        isRepacking = true
        // Use a separate repackToken so repacks supersede each other but do NOT
        // cancel a concurrent in-flight rescore (which uses rescoreToken).
        repackToken += 1; let token = repackToken
        // I1: capture the FULL sequence before dispatch so we can detect a mid-repack mutation.
        let capturedFullSeq = editedSequence
        // C3: project through the valid-residue mask to align with validResidues.
        let seq = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let residues = set.validResidues
        let repackFn = repack     // capture @MainActor-isolated property before leaving
        let pdb: String? = try? await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                do { cont.resume(returning: try repackFn(residues, seq)) }
                catch { cont.resume(throwing: error) }
            }
        }
        guard token == repackToken else { isRepacking = false; return }
        if let pdb, !pdb.isEmpty {
            // I1: only load if the sequence has not changed since dispatch.
            if capturedFullSeq == editedSequence {
                loadRepacked(w, pdb)
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
                    applyColoring(w, vals, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound)
                }
                // Stale sidechain sticks are gone (object was replaced); clear tracking
                // and re-add for the pinned/hovered residue on the fresh atoms.
                teardownSticks(on: w)
                reconcileSticks()
                // Re-apply global sidechain display if the user had it turned on.
                if showSidechains { showAllSidechainsFn(w, true) }
            }
            // else: mutation happened mid-repack; leave repackDirty = true so the
            // next repack (triggered by the new mutation) loads the current coords.
        }
        isRepacking = false
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
        let residues = set.validResidues
        // C3: project editedSequence through the valid mask to align with validResidues.
        let seq = zip(set.residues, editedSequence).compactMap { $0.0.valid ? $0.1 : nil }
        let validMask = set.residues.map { $0.valid }
        let scoreFn = score               // capture @MainActor-isolated property before leaving

        let result: MPNNModel.ScoreResult? = try? await withCheckedThrowingContinuation { cont in
            inferenceQueue.async {
                do { cont.resume(returning: try scoreFn(residues, seq)) }
                catch { cont.resume(throwing: error) }
            }
        }

        // Back on MainActor. Discard if a newer mutation superseded this one.
        guard token == rescoreToken, let r = result else { return }

        let scores = DesignColor.scores(from: r, validMask: validMask)
        cache.set(DesignCacheKey(object: w, state: set.state, sequenceHash: seq.hashValue), scores)
        updateSequenceScore(from: scores)

        let scalar = DesignColor.scalar(scores, colorMeaning)
        let values: [(String, String, Float?)] = zip(set.residues, scalar).map { ($0.chain, $0.resi, $1) }
        let dom = DesignColor.domain(colorMeaning)
        legendDomain = dom
        applyColoring(w, values, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound)
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
