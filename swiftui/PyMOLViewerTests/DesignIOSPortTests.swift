#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignIOSPortTests: XCTestCase {

    func makeController() -> DesignController {
        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        return DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, _ in MPNNModel.ScoreResult(logProbs: [], currentAALogProb: []) },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }

    private func allValid(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    // A failed region redesign must leave a message the UI can render, and
    // clearError() must be the way it goes away (the banner's dismiss path).
    func testClearErrorResetsErrorText() async {
        let c = makeController()
        c.injectRegion(designRegion: { _, _, _, _, _ in [] },   // wrong length → failure
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertEqual(c.errorText, "Region redesign failed",
                       "a failed redesign must leave a user-visible message")

        c.clearError()
        XCTAssertNil(c.errorText, "clearError must clear the message the banner shows")
    }

    // MARK: – Task 4: size-guard wiring

    // A run predicted to exceed the budget must never reach the inference queue.
    func testOversizeRedesignIsRefused() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .refuse(maxFittingResidues: 500) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()

        XCTAssertEqual(designCalls, 0, "a refused run must not dispatch inference")
        XCTAssertNotNil(c.errorText, "a refused run must explain itself")
        XCTAssertNil(c.pendingSizeWarning, "refuse is terminal, not a confirmation")
    }

    // In the warn band the run is held pending explicit confirmation, and the
    // autosave fires first so a jetsam kill costs no work.
    func testWarnBandHoldsRunUntilConfirmedAndAutosavesFirst() async {
        let c = makeController()
        var designCalls = 0
        var autosaves = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.autosaveBeforeLargeRun = { autosaves += 1 }
        c.sizeDecisionProvider = { n in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertEqual(designCalls, 0, "warn must hold the run, not start it")
        XCTAssertNotNil(c.pendingSizeWarning)
        XCTAssertEqual(c.pendingSizeWarning?.residueCount, 3)
        XCTAssertEqual(autosaves, 0, "autosave belongs to the confirm path, not the prompt")

        await c.confirmPendingWarning()
        XCTAssertEqual(autosaves, 1, "confirming must autosave before dispatching")
        XCTAssertEqual(designCalls, 1, "confirming must actually run the design")
        XCTAssertNil(c.pendingSizeWarning)
    }

    func testCancellingWarningRunsNothing() async {
        let c = makeController()
        var designCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.pendingSizeWarning)
        c.cancelPendingWarning()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 0)
    }

    // An explicit .ok decision (representing any non-blocking case) must never
    // hold or refuse the run. The provider must be consulted exactly once so
    // this test fails if the entire guard block were deleted (provider would be
    // consulted 0 times, not 1).
    func testOkDecisionNeverBlocks() async {
        let c = makeController()
        var designCalls = 0
        var providerCalls = 0
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.sizeDecisionProvider = { _ in providerCalls += 1; return .ok }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(designCalls, 1)
        XCTAssertEqual(providerCalls, 1,
                       "the guard must consult the provider exactly once per run")
    }

    // Regression: `suppressSizeGuardOnce` must not leak across calls.
    //
    // Failure scenario (pre-fix):
    // 1. Run lands in warn band → pendingSizeWarning is set.
    // 2. User clears the region (clearSelection does NOT clear pendingSizeWarning).
    // 3. User confirms the stale warning → confirmPendingWarning() sets
    //    suppressSizeGuardOnce=true and calls redesignSelectionAwait(), which
    //    immediately hits the "guard !selectedResidueIndices.isEmpty" early return
    //    BEFORE the flag is read and cleared (pre-fix location).  Flag stays true.
    // 4. Re-establish region; switch provider to .refuse.
    // 5. Next redesignSelectionAwait() bypasses the guard (flag=true), dispatches
    //    inference, and the device may be killed by jetsam with no diagnostic.
    //
    // After the fix the flag is consumed at function ENTRY (before every guard),
    // so step 3's early return leaves it cleared, and step 5 correctly refuses.
    func testSuppressSizeGuardOnceDoesNotLeak() async {
        let c = makeController()
        var designCalls = 0
        var providerCalls = 0

        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }

        // Step 1: first redesign lands in the warn band — run is held.
        c.sizeDecisionProvider = { _ in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.pendingSizeWarning, "warn band must set pendingSizeWarning")
        XCTAssertEqual(designCalls, 0, "warn band must hold the run")

        // Step 2: user clears the region while the warning is still pending.
        c.clearSelection()

        // Step 3: user confirms the (now stale) warning.
        // confirmPendingWarning() sets suppressSizeGuardOnce=true and calls
        // redesignSelectionAwait(). That re-entry hits the early return
        // (selectedResidueIndices is empty). Pre-fix: flag leaks as true.
        // Post-fix: flag is consumed at entry and cleared before any early return.
        await c.confirmPendingWarning()

        // Step 4: re-establish a region and switch to a refuse provider.
        c.pickSelection("reg")
        c.sizeDecisionProvider = { _ in providerCalls += 1; return .refuse(maxFittingResidues: 0) }

        // Step 5: the next redesign must be refused.
        // Pre-fix: stale suppressSizeGuardOnce=true bypasses the guard →
        //   designCalls=1, providerCalls=0. Test fails.
        // Post-fix: flag is false → provider is consulted → .refuse →
        //   designCalls=0, providerCalls=1. Test passes.
        await c.redesignSelectionAwait()

        XCTAssertEqual(designCalls, 0,
                       "a refused run must not dispatch inference — stale suppressSizeGuardOnce must not bypass the guard")
        XCTAssertEqual(providerCalls, 1,
                       "the size-guard provider must be consulted exactly once (leaked flag would skip it)")
        XCTAssertNotNil(c.errorText, "a refused run must set errorText")
        XCTAssertNil(c.pendingSizeWarning, "refuse is terminal — must not leave a pending warning")
    }

    // MARK: – Task 5: model release on exit

    // Exiting Design mode must free the ~model-resident weights, and must do it on
    // the inference queue so it can never race a running job.
    func testExitReleasesModelOffTheMainThread() {
        let c = makeController()
        let released = expectation(description: "model released")
        var releasedOnMain = true
        c.injectReleaseModel {
            releasedOnMain = Thread.isMainThread
            released.fulfill()
        }
        c.exit()
        wait(for: [released], timeout: 2.0)
        XCTAssertFalse(releasedOnMain,
                       "release must run on the inference queue, not the main thread")
    }

    // Release is ordered behind any queued inference, which is what makes it safe.
    func testReleaseIsOrderedAfterInFlightInference() async {
        let c = makeController()
        var order: [String] = []
        let done = expectation(description: "released")
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           order.append("design")
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0, 1] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectReleaseModel { order.append("release"); done.fulfill() }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.pickSelection("reg")

        await c.redesignSelectionAwait()
        c.exit()
        await fulfillment(of: [done], timeout: 2.0)
        XCTAssertEqual(order, ["design", "release"],
                       "release must not jump ahead of inference already dispatched")
    }

    // MARK: – Task 6: bounded DesignScoreCache

    // The cache key includes the sequence hash, so every edit inserts a new entry.
    // Without a bound it grows for the whole session.
    func testCacheEvictsOldestPastCapacity() {
        let cache = DesignScoreCache(capacity: 3)
        func key(_ i: Int) -> DesignCacheKey {
            DesignCacheKey(object: "m1", state: 1, sequenceHash: i)
        }
        let scores = DesignScores(nativeFit: [-1], certainty: [0.5])
        for i in 0..<5 { cache.set(key(i), scores) }

        XCTAssertEqual(cache.count, 3, "cache must not grow past its capacity")
        XCTAssertNil(cache.get(key(0)), "oldest entry must be evicted")
        XCTAssertNil(cache.get(key(1)))
        XCTAssertNotNil(cache.get(key(4)), "newest entry must survive")
    }

    // Re-setting an existing key must refresh it in place, not consume a second slot.
    func testOverwritingAKeyDoesNotConsumeCapacity() {
        let cache = DesignScoreCache(capacity: 2)
        let k = DesignCacheKey(object: "m1", state: 1, sequenceHash: 7)
        cache.set(k, DesignScores(nativeFit: [-1], certainty: [0.1]))
        cache.set(k, DesignScores(nativeFit: [-2], certainty: [0.2]))
        cache.set(DesignCacheKey(object: "m1", state: 1, sequenceHash: 8),
                  DesignScores(nativeFit: [-3], certainty: [0.3]))

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.get(k)?.nativeFit, [-2], "overwrite must win, and survive")
    }

    // An overwrite must NOT reset the key's eviction position.
    //
    // Under correct FIFO the earliest-inserted key is always the eviction victim
    // regardless of subsequent overwrites.  An LRU-on-overwrite implementation
    // would move the key to the back of the eviction order on each write, causing
    // a different (and still-useful) key to be dropped instead.
    //
    // Scenario (capacity 2):
    //   set(k1)          → order: [k1]
    //   set(k2)          → order: [k1, k2]   (full)
    //   set(k1, updated) → order must stay [k1, k2] — overwrite keeps k1's slot
    //   set(k3)          → evicts k1 (FIFO); surviving: k2, k3
    //
    // If order became [k2, k1] after the overwrite, k2 would be evicted — wrong.
    func testOverwriteDoesNotResetEvictionPosition() {
        let cache = DesignScoreCache(capacity: 2)
        func key(_ i: Int) -> DesignCacheKey {
            DesignCacheKey(object: "m1", state: 1, sequenceHash: i)
        }
        let k1 = key(1), k2 = key(2), k3 = key(3)

        cache.set(k1, DesignScores(nativeFit: [-1], certainty: [0.1]))  // k1 inserted first
        cache.set(k2, DesignScores(nativeFit: [-2], certainty: [0.2]))  // k2 inserted second
        cache.set(k1, DesignScores(nativeFit: [-9], certainty: [0.9]))  // overwrite — must NOT move k1 to back
        cache.set(k3, DesignScores(nativeFit: [-3], certainty: [0.3]))  // triggers one eviction

        // FIFO: k1 was inserted first → k1 is the victim; k2 and k3 survive.
        // LRU-on-overwrite bug: k2 would be evicted instead (k1 was "most recently written").
        XCTAssertEqual(cache.count, 2,
                       "FIFO: exactly 2 entries must survive after one eviction from a capacity-2 cache")
        XCTAssertNil(cache.get(k1),
                     "FIFO invariant: k1 was inserted first and must be the eviction victim — overwriting k1 must not promote it past k2")
        XCTAssertNotNil(cache.get(k2),
                        "FIFO invariant: k2 was inserted second; overwriting k1 must not bump k2 to the front of the eviction order")
        XCTAssertNotNil(cache.get(k3),
                        "FIFO invariant: k3 was just inserted and must always survive")
    }

    func testInvalidateDropsOnlyTheNamedObject() {
        let cache = DesignScoreCache(capacity: 8)
        let scores = DesignScores(nativeFit: [-1], certainty: [0.5])
        cache.set(DesignCacheKey(object: "keep", state: 1, sequenceHash: 1), scores)
        cache.set(DesignCacheKey(object: "drop", state: 1, sequenceHash: 2), scores)
        cache.invalidate(object: "drop")

        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.get(DesignCacheKey(object: "keep", state: 1, sequenceHash: 1)))
    }

    // The default sizeDecisionProvider routes through DesignSizeGuard.evaluate,
    // which returns .ok unconditionally on macOS regardless of residue count.
    // This test exercises the genuine production path and proves shipped macOS
    // behaviour does not change even for objects that would exhaust any iOS device.
    func testMacOSDefaultSizeProviderNeverBlocks() async {
        let c = makeController()
        var designCalls = 0
        let count = 1000   // far above any iOS headroom; irrelevant on macOS
        c.injectRegion(designRegion: { r, _, _, _, _ in
                           designCalls += 1
                           return Array(repeating: 0, count: r.count)
                       },
                       selectedIndices: { _, _, _, _ in [0] })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        // sizeDecisionProvider is NOT injected — exercises the real default path.
        c.setFocusForTest("m1", nativeSequence: Array(repeating: 5, count: count),
                          validFlags: allValid(count))
        c.pickSelection("reg")   // selectedIndices returns [0]

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning,
                     "macOS default provider (evaluate → .ok) must never block")
        XCTAssertNil(c.errorText)   // no error from the guard
        XCTAssertEqual(designCalls, 1, "macOS default provider must let the design run")
    }
}
#endif
