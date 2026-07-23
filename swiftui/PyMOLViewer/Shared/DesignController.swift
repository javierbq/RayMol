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

    // MARK: – Closure type aliases (Task 10 wires in real implementations)

    /// Enumerate residues for `(objectName, state)`.
    typealias EnumerateFn = (String, Int) throws -> DesignResidueSet

    /// Run MPNN scoring off-main; called on the inference serial queue.
    typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult

    /// Apply per-residue coloring to `objectName`.
    /// `values`: (chain, resi, scalar?) for every residue in the set order.
    typealias ColorFn = (_ obj: String, _ values: [(String, String, Float?)],
                         _ palette: String, _ lo: Float, _ hi: Float) -> Void

    // MARK: – Injected dependencies

    private let enumerate: EnumerateFn
    private let score: ScoreFn
    private let applyColoring: ColorFn
    private let dim: (String) -> Void
    private let snapshot: ([String]) -> Void
    private let restore: () -> Void
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

    // MARK: – Init

    nonisolated init(enumerate: @escaping EnumerateFn,
                     score: @escaping ScoreFn,
                     applyColoring: @escaping ColorFn,
                     dim: @escaping (String) -> Void,
                     snapshot: @escaping ([String]) -> Void,
                     restore: @escaping () -> Void,
                     currentState: @escaping (String) -> Int = { _ in 1 }) {
        self.enumerate = enumerate
        self.score = score
        self.applyColoring = applyColoring
        self.dim = dim
        self.snapshot = snapshot
        self.restore = restore
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
        restore()
        focusObject = nil
        isScoring = false
        errorText = nil
        jobToken += 1   // cancel any in-flight scoring
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
}
#endif
