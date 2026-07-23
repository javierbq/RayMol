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

    /// Run MPNN scoring off-main; called on the inference serial queue.
    typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult

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
    private let score: ScoreFn
    private let applyColoring: ColorFn
    private let dim: (String) -> Void
    private let snapshot: ([String]) -> Void
    private let restore: () -> Void
    private let setSticksFn: SticksFn
    /// Returns the currently-displayed state (1-based) for `object`. Wired to the engine in Task 10.
    private let currentStateFn: (String) -> Int

    // MARK: – Private state

    private let cache = DesignScoreCache()
    /// Serial queue for off-main inference; continuations resume back on MainActor.
    private let queue = DispatchQueue(label: "io.raymol.design.inference", qos: .userInitiated)
    /// Incremented on each focus; a superseded focus checks its captured token against this.
    private var jobToken = 0
    /// Most-recently enumerated residue set per object (for recolor without re-enumerating).
    private var lastSet: [String: DesignResidueSet] = [:]
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
                     currentState: @escaping (String) -> Int = { _ in 1 }) {
        self.enumerate = enumerate
        self.score = score
        self.applyColoring = applyColoring
        self.dim = dim
        self.snapshot = snapshot
        self.restore = restore
        self.setSticksFn = setSticks
        self.currentStateFn = currentState
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
        restore()
        focusObject = nil
        isScoring = false
        errorText = nil
        hoveredResidueIndex = nil
        pinnedResidueIndex = nil
        jobToken += 1   // cancel any in-flight scoring
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
            teardownSticks(on: previous)
            hoveredResidueIndex = nil
            pinnedResidueIndex = nil
        }
        focusObject = object
        for o in allObjects where o != object { dim(o) }
        // Hoist token capture so both the success continuation and the catch can guard against it.
        jobToken += 1
        let token = jobToken
        do {
            let set = try enumerate(object, currentState(object))
            lastSet[object] = set

            let key = DesignCacheKey(object: object, state: set.state, sequenceHash: set.sequenceHash)
            if cache.get(key) != nil {
                // Cache hit: recolor without re-scoring.
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
                queue.async {
                    do {
                        let result = try scoreFn(residues, native)
                        cont.resume(returning: DesignColor.scores(from: result, validMask: validMask))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }

            // Back on MainActor. Discard the result if a newer focus superseded this one.
            guard token == jobToken else { return }

            errorText = nil
            cache.set(key, scores)
            isScoring = false
            recolor(object)

        } catch {
            // A superseded or post-exit() throw must not clobber state owned by the current job.
            guard token == jobToken else { return }
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
    private func reconcileSticks() {
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
}
#endif
