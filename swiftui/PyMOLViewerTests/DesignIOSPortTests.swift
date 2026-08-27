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
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })
    }

    private func allValid(_ n: Int) -> [Bool] { Array(repeating: true, count: n) }

    // A failed region redesign must leave a message the UI can render, and
    // clearError() must be the way it goes away (the banner's dismiss path).
    func testClearErrorResetsErrorText() async {
        let c = makeController()
        c.injectRegion(designRegion: { _, _, _, _, _ in [] })   // wrong length → failure
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
                       })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .refuse(maxFittingResidues: 500) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
                       })
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
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
                       })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.sizeDecisionProvider = { _ in .warn(estimatedBytes: 3_000_000_000, availableBytes: 4_000_000_000) }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
                       })
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
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
    // 2. User clears the region (clearing does NOT clear pendingSizeWarning).
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
                       })
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
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

        await c.redesignSelectionAwait()
        XCTAssertNotNil(c.pendingSizeWarning, "warn band must set pendingSizeWarning")
        XCTAssertEqual(designCalls, 0, "warn band must hold the run")

        // Step 2: user clears the region while the warning is still pending.
        c.handleViewportHit(object: "", chain: "", resi: "", hasResidue: false)

        // Step 3: user confirms the (now stale) warning.
        // confirmPendingWarning() sets suppressSizeGuardOnce=true and calls
        // redesignSelectionAwait(). That re-entry hits the early return
        // (selectedResidueIndices is empty). Pre-fix: flag leaks as true.
        // Post-fix: flag is consumed at entry and cleared before any early return.
        await c.confirmPendingWarning()

        // Step 4: re-establish a region and switch to a refuse provider.
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)
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

    // MARK: – Compact panel: colorMeaning binding correctness

    // Setting colorMeaning via Picker's $binding in DesignSettingsSheet used to
    // set the @Published property directly, bypassing setMeaning(_:) and therefore
    // never calling recolor(). This test verifies that setMeaning updates the
    // property AND invokes applyColoring — the symptom was a Picker that moved but
    // left the structure visually unchanged until an unrelated redraw fired.
    //
    // setMeaning calls recolor(focusObject) which only calls applyColoring when
    // there are scores in the cache, so the test must run the full focus/scoring
    // pipeline via focusAwait before exercising setMeaning. A local controller is
    // constructed (rather than makeController()) so we can count applyColoring calls.
    func testSetMeaningUpdatesPropertyAndTriggersRecolor() async {
        var lastPalette: String?
        let residueSet = DesignResidueSet(object: "stub", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)])
        let c = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in
                MPNNModel.ScoreResult(
                    logProbs: [[Float](repeating: Float(log(1.0 / 21.0)), count: 21)],
                    currentAALogProb: [-1.0])
            },
            applyColoring: { _, _, palette, _, _, _, _ in lastPalette = palette },
            dim: { _ in }, snapshot: { _ in }, restore: { })
        c.enter()
        await c.focusAwait("stub")

        // After focus, the default meaning is nativeFit → red_white_blue palette.
        XCTAssertEqual(c.colorMeaning, .nativeFit,
                       "default colorMeaning must be nativeFit after focus")
        XCTAssertEqual(lastPalette, "red_white_blue",
                       "focus must apply the nativeFit palette")

        // Changing meaning via setMeaning must (a) update the property and
        // (b) call applyColoring (recolor) immediately with the new palette.
        // The DesignSettingsSheet binding bug was: $controller.colorMeaning bypassed
        // setMeaning, so the palette never changed until an unrelated redraw fired.
        c.setMeaning(.certainty)
        XCTAssertEqual(c.colorMeaning, .certainty,
                       "setMeaning must update colorMeaning")
        XCTAssertEqual(lastPalette, "blue_white_red",
                       "setMeaning must call recolor — direct @Published binding bypasses this and leaves the palette stale")

        // Switching back must also trigger a recolor.
        c.setMeaning(.nativeFit)
        XCTAssertEqual(c.colorMeaning, .nativeFit)
        XCTAssertEqual(lastPalette, "red_white_blue",
                       "setMeaning(.nativeFit) must also trigger a recolor")
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
                       })
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
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

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
                       })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        // sizeDecisionProvider is NOT injected — exercises the real default path.
        // autoRepack disabled: this test is about the size guard, not repack success.
        // (After the Bug-2 fix, a no-op repack closure would set errorText, which
        // would incorrectly shadow the guard assertion below.)
        c.autoRepack = false
        c.setFocusForTest("m1", nativeSequence: Array(repeating: 5, count: count),
                          validFlags: allValid(count))
        c.tapResidue(residueIndex: 0); c.tapResidue(residueIndex: 1)

        await c.redesignSelectionAwait()
        XCTAssertNil(c.pendingSizeWarning,
                     "macOS default provider (evaluate → .ok) must never block")
        XCTAssertNil(c.errorText,
                     "no error from the size guard on macOS; autoRepack disabled so repack cannot set errorText here")
        XCTAssertEqual(designCalls, 1, "macOS default provider must let the design run")
    }

    // One tap pins for inspection; the region stays empty so the propensity pills
    // still show. This is the single-residue behaviour the change preserves.
    func testSingleTapPinsAndDoesNotBuildARegion() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.tapResidue(residueIndex: 1)

        XCTAssertEqual(c.pinnedResidueIndex, 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "one residue must not enter region mode")
    }

    // A second tap on a different residue turns the selection into a region and
    // drops the pin — no mode toggle involved.
    func testSecondTapBuildsRegionAndDropsThePin() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.tapResidue(residueIndex: 1)
        c.tapResidue(residueIndex: 0)
        XCTAssertEqual(c.selectedResidueIndices, [0, 1], "region stays sorted")
        XCTAssertNil(c.pinnedResidueIndex)

        // Tapping a member removes it, dropping back to single-residue mode.
        c.tapResidue(residueIndex: 1)
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)
        XCTAssertEqual(c.pinnedResidueIndex, 0)
    }

    // Non-designable positions can never be pinned or enter a region, however
    // many times they are tapped.
    func testTapIgnoresNonDesignableResidues() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5],
                          validFlags: [true, false, true])

        c.tapResidue(residueIndex: 1)
        XCTAssertNil(c.pinnedResidueIndex,
                     "a residue with no backbone is not designable")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty)

        // A designable residue alongside it still works normally.
        c.tapResidue(residueIndex: 2)
        XCTAssertEqual(c.pinnedResidueIndex, 2)
    }

    // MARK: – Task 8: MPNNRuntime configuration

    // The constant must match the value measured by the reference harness as the
    // point beyond which the MLX buffer pool causes guaranteed jetsam kills on any iPhone.
    func testCacheLimitConstantIs96MB() {
        XCTAssertEqual(MPNNRuntime.cacheLimitBytes, 96 * 1024 * 1024)
    }

    // configureOnce() must genuinely install the limit, not merely declare it.
    // activeCacheLimitBytes is a thin read-through of MLX.Memory.cacheLimit, exposed
    // on MPNNRuntime so the test target can assert without importing MLX directly.
    func testConfigureOnceInstallsCacheLimit() {
        MPNNRuntime.configureOnce()
        XCTAssertEqual(MPNNRuntime.activeCacheLimitBytes, MPNNRuntime.cacheLimitBytes,
                       "configureOnce() must set MLX.Memory.cacheLimit to cacheLimitBytes")
    }

    // MARK: – Bug 1: unified viewport-hit routing (handleViewportHit)

    // This is the exact failure the user reported: touching a different structure
    // to retarget the design did nothing on iOS, because the iOS guard returned early
    // for the "different object" case (and always for nil focusObject).
    func testHandleViewportHitRefocusesOnDifferentObject() async {
        let c = makeController()
        c.setFocusForTest("obj1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        XCTAssertEqual(c.focusObject, "obj1")

        c.handleViewportHit(object: "obj2", chain: "", resi: "", hasResidue: false)
        // focus() spawns a Task on the MainActor; yield so it runs until its first
        // suspension point, by which time focusObject has been set to "obj2".
        await Task.yield()

        XCTAssertEqual(c.focusObject, "obj2",
                       "tapping a different object must refocus — this is the reported iOS bug")
    }

    // Multi-object scenario: nothing is focused yet when the user taps a structure
    // (enter() only auto-focuses when there is exactly ONE object).
    func testHandleViewportHitRefocusesWhenFocusIsNil() async {
        let c = makeController()
        XCTAssertNil(c.focusObject, "focusObject starts nil")

        c.handleViewportHit(object: "obj1", chain: "", resi: "", hasResidue: false)
        await Task.yield()

        XCTAssertEqual(c.focusObject, "obj1",
                       "tapping any object when nothing is focused must refocus")
    }

    // Same-object tap with a valid residue → routed through tapResidue (not
    // setPinned directly), so the tap toggles 'sele' and the COUNT decides the mode
    // — one residue pins — identically on both platforms.
    func testHandleViewportHitPinsOnFocusObjectWithResidue() {
        let c = makeController()
        c.setFocusForTest("obj1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        // setFocusForTest creates residues chain "A" resi "1"/"2"/"3" at indices 0/1/2.

        c.handleViewportHit(object: "obj1", chain: "A", resi: "2", hasResidue: true)

        XCTAssertEqual(c.pinnedResidueIndex, 1,
                       "hitting the focus object's residue (resi '2' = index 1) must pin it")
        XCTAssertTrue(c.selectedResidueIndices.isEmpty,
                      "pinning via handleViewportHit must not build a region")
    }

    // Two viewport hits on the focus object accumulate into a region, so the
    // viewport and the sequence strip agree without any mode switch.
    func testHandleViewportHitAccumulatesRegionOnFocusObject() {
        let c = makeController()
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.handleViewportHit(object: "m1", chain: "A", resi: "2", hasResidue: true)
        XCTAssertEqual(c.pinnedResidueIndex, 1)

        c.handleViewportHit(object: "m1", chain: "A", resi: "3", hasResidue: true)
        XCTAssertEqual(c.selectedResidueIndices, [1, 2])
        XCTAssertNil(c.pinnedResidueIndex)
    }

    // An empty object name means the tap landed on empty space — must be a no-op.
    func testHandleViewportHitEmptyObjectIsNoOp() {
        let c = makeController()
        c.setFocusForTest("obj1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        c.handleViewportHit(object: "", chain: "A", resi: "1", hasResidue: true)

        XCTAssertEqual(c.focusObject, "obj1",
                       "an empty object name must be a no-op — focus must not change")
        XCTAssertNil(c.pinnedResidueIndex,
                     "an empty object name must not pin any residue")
    }

    // MARK: – Phase 2d: Mode-lock (isCalculating) tests

    // 1. isCalculating is true for each of the four flags independently, and false when all clear.
    //    isRescoring, isRedesigning, isRepacking are private(set) so we verify the OR logic
    //    through isScoring (the one publicly-writable flag). A separate test covers each
    //    private flag end-to-end via its triggering operation.
    func testIsCalculatingReflectsEachFlag() {
        let c = makeController()
        XCTAssertFalse(c.isCalculating, "baseline: all flags clear → isCalculating must be false")

        c.isScoring = true
        XCTAssertTrue(c.isCalculating, "isScoring=true must make isCalculating true")
        c.isScoring = false
        XCTAssertFalse(c.isCalculating, "isScoring=false must restore isCalculating to false")
    }

    // 2. A superseded cache-miss focus followed by a cache-hit focus must not strand isScoring.
    //    This is the regression test for defect (b): the old code did not clear isScoring at
    //    the top of focusAwait, so a superseded job's `true` persisted through a cache-hit
    //    successor that returned early without touching the flag.
    func testSuperseededScoringThenCacheHitDoesNotStrandIsScoring() async {
        let semaphore = DispatchSemaphore(value: 0)
        let obj2Scoring = XCTestExpectation(description: "obj2 score in flight")

        let oneResidue: [DesignResidue] = [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1),
                          valid: true)
        ]
        let obj1Set = DesignResidueSet(object: "obj1", state: 1, residues: oneResidue)
        let obj2Set = DesignResidueSet(object: "obj2", state: 1, residues: oneResidue)
        let goodResult = MPNNModel.ScoreResult(
            logProbs: [[Float](repeating: -3, count: 21)], currentAALogProb: [-3])
        var isFirstCall = true

        let c = DesignController(
            enumerate: { obj, _ in obj == "obj1" ? obj1Set : obj2Set },
            score: { _, _ in
                if isFirstCall {
                    isFirstCall = false
                    return goodResult   // obj1: fast, seeds the cache
                }
                // obj2: slow — blocks until released
                obj2Scoring.fulfill()
                semaphore.wait()
                return goodResult
            },
            applyColoring: { _, _, _, _, _, _, _ in },
            dim: { _ in }, snapshot: { _ in }, restore: { })

        // Step 1: seed cache for obj1
        await c.focusAwait("obj1")
        XCTAssertFalse(c.isScoring, "isScoring must be clear after a successful cache-miss focus")

        // Step 2: start slow focus on obj2 (non-awaited)
        let slowTask = Task { await c.focusAwait("obj2") }
        await fulfillment(of: [obj2Scoring], timeout: 2.0)
        XCTAssertTrue(c.isScoring, "isScoring must be true while obj2 is scoring")

        // Step 3: re-focus obj1 (cache hit) — bumps token.
        //   Bug:  isScoring is NOT cleared at the token bump → cache hit returns → isScoring stranded.
        //   Fix:  isScoring IS cleared at the token bump → cache hit returns → isScoring = false.
        await c.focusAwait("obj1")

        // Step 4: release obj2 and let its task finish
        semaphore.signal()
        await slowTask.value

        XCTAssertFalse(c.isScoring,
            "isScoring must not be stranded: a superseded cache-miss followed by " +
            "a cache-hit must leave isScoring false")
    }

    // 3. rescoreWorkingObject's isRescoring flag is set during its inference and cleared afterwards.
    //    The flag is read inside the score closure (which runs on the inference queue). This
    //    is technically outside the @MainActor isolation of DesignController, but is safe for
    //    this one-shot test read: isRescoring was set true on the main actor before dispatch
    //    (happens-before), and the inference queue reads it atomically.
    func testIsRescoringSetDuringRescoreAndClearedAfter() async {
        var capturedIsRescoring = false
        let c = makeController()
        c.autoRepack = false
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectScore { [weak c] _, s in
            // isRescoring is set true by rescoreWorkingObject before this closure is dispatched.
            capturedIsRescoring = c?.isRescoring ?? false
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        await c.applyMutationAwait(residueIndex: 0, aa: 1)

        XCTAssertTrue(capturedIsRescoring,
            "isRescoring must be true while rescoreWorkingObject is dispatched on the inference queue")
        XCTAssertFalse(c.isRescoring,
            "isRescoring must be cleared by the token-guarded defer after inference completes")
    }

    // 4. Engine setters are blocked when isCalculating is true.
    //    PyMOLEngine is a singleton wired to the live C core; its lazy designController
    //    initializer sets up real Python closures but does not execute them at init time, so
    //    accessing it in tests is safe. We verify the guard through PyMOLEngine.shared (the
    //    same singleton InteractionModeExitTests already uses) by setting isScoring — the one
    //    publicly-writable flag — to simulate an ongoing calculation.
    func testEngineSettersBlockedByIsCalculating() {
        let engine = PyMOLEngine.shared
        // Ensure a clean baseline (design controller lazily initialized on first access).
        engine.setInteractionMode(.viewing)
        engine.setDesignMode(false)
        engine.setMeasureMode(nil)

        // Simulate an ongoing MLX inference via the publicly-writable isScoring flag.
        engine.designController.isScoring = true
        XCTAssertTrue(engine.designController.isCalculating,
            "precondition: isScoring=true must make isCalculating true")

        engine.setInteractionMode(.move)
        XCTAssertEqual(engine.interactionMode, .viewing,
            "setInteractionMode must not change mode when isCalculating is true")

        engine.setMeasureMode(.distance)
        XCTAssertNil(engine.measureMode,
            "setMeasureMode must not change mode when isCalculating is true")

        // Clean up so downstream tests start from a known state.
        engine.designController.isScoring = false
        XCTAssertFalse(engine.designController.isCalculating)
    }

    // 5. exitActiveInteractionMode returns false when all setters are blocked.
    //    A false return lets the Esc monitor propagate the key rather than silently
    //    consuming it with nothing happening.
    func testExitActiveInteractionModeReturnsFalseWhenBlocked() {
        let engine = PyMOLEngine.shared
        // Force design mode on via direct assignment (bypasses the setter guard,
        // matching the desynchronized-state pattern in InteractionModeExitTests:114-116).
        engine.designMode = true

        engine.designController.isScoring = true
        XCTAssertTrue(engine.designController.isCalculating,
            "precondition: isScoring=true must make isCalculating true")

        let result = engine.exitActiveInteractionMode()

        XCTAssertFalse(result,
            "exitActiveInteractionMode must return false when all setters are blocked — " +
            "so the Esc monitor propagates the key instead of silently consuming it")
        XCTAssertTrue(engine.designMode,
            "designMode must remain true when the exit is blocked by an ongoing calculation")

        // Clean up.
        engine.designController.isScoring = false
        engine.designMode = false
    }

    // MARK: – Phase 2d: Superseded-job optimisation (TokenMirror fix)

    // 1. A superseded rescore must NOT invoke the score closure for every mutation.
    //
    // Mechanism: the score closure signals that it has started (blocking the serial inference
    // queue), then waits for the test to release it.  While it waits, the test dispatches two
    // more mutations — these update the rescoreMirror to their tokens and queue their closures.
    // Once the gate opens: closure 1 finishes; closure 2 finds mirror=3 ≠ token=2 → bails;
    // closure 3 finds mirror=3 == token=3 → runs.  Total scoreFn invocations: 2 (not 3).
    //
    // Non-flake argument: score closure 1 explicitly blocks the inference queue via a
    // DispatchSemaphore (background thread only — never the main actor).  Mutations 2 and 3
    // are dispatched only AFTER closure 1 has signaled it is blocking (XCTestExpectation).
    // `Task.yield()` is used to give the main-actor Tasks time to reach their first suspension
    // point (after dispatching to the queue and updating the mirror), before the gate opens.
    // The final `fulfillment(of:)` waits for a definite "all done" signal, not a sleep.
    func testSupersededRescoreDoesNotInvokeScoreClosure() async {
        let c = makeController()
        c.autoRepack = false
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: Array(repeating: 5, count: 5), validFlags: allValid(5))

        var scoreInvocations = 0
        let score1Started = XCTestExpectation(description: "score closure 1 started")
        let score1Gate    = DispatchSemaphore(value: 0)
        let allDone       = XCTestExpectation(description: "all three mutations done")
        allDone.expectedFulfillmentCount = 3
        var firstCall = true

        c.injectScore { _, s in
            scoreInvocations += 1
            if firstCall {
                firstCall = false
                score1Started.fulfill()   // signal main actor: queue is now blocked
                score1Gate.wait()         // block inference queue (NOT main thread)
            }
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }

        // Mutation 1: dispatches its score closure to the queue (starts, then blocks).
        Task { await c.applyMutationAwait(residueIndex: 0, aa: 1); allDone.fulfill() }
        await Task.yield()   // let task 1 reach its suspension point (closure dispatched)

        // Wait until score closure 1 is actually inside scoreFn (blocking the queue).
        await fulfillment(of: [score1Started], timeout: 2.0)

        // Queue is now blocked.  Dispatch mutations 2 and 3 — they update the mirror to 2/3
        // and queue their closures, but cannot start until closure 1 releases the queue.
        Task { await c.applyMutationAwait(residueIndex: 1, aa: 2); allDone.fulfill() }
        await Task.yield(); await Task.yield()   // let task 2 dispatch + update mirror → 2
        Task { await c.applyMutationAwait(residueIndex: 2, aa: 3); allDone.fulfill() }
        await Task.yield(); await Task.yield()   // let task 3 dispatch + update mirror → 3

        // Release the gate: closure 1 returns; closure 2 → mirror check bails; closure 3 runs.
        score1Gate.signal()

        await fulfillment(of: [allDone], timeout: 5.0)

        // With fix:    scoreInvocations == 2 (closures 1 and 3 ran; closure 2 was superseded)
        // Without fix: scoreInvocations == 3 (all three ran)
        XCTAssertLessThan(scoreInvocations, 3,
            "with the TokenMirror fix, superseded score closure 2 must bail before invoking " +
            "scoreFn; only closures 1 (already started before superseded) and 3 (winner) run")
    }

    // 2. A superseded rescore must NOT set errorText — supersession is not a failure.
    func testSupersededRescoreDoesNotSetErrorText() async {
        let c = makeController()
        c.autoRepack = false
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: Array(repeating: 5, count: 5), validFlags: allValid(5))

        let score1Started = XCTestExpectation(description: "score closure 1 started")
        let score1Gate    = DispatchSemaphore(value: 0)
        let allDone       = XCTestExpectation(description: "all mutations done")
        allDone.expectedFulfillmentCount = 2
        var firstCall = true

        c.injectScore { _, s in
            if firstCall {
                firstCall = false
                score1Started.fulfill()
                score1Gate.wait()
            }
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }

        // Start mutation 1, wait for its closure to be inside scoreFn.
        Task { await c.applyMutationAwait(residueIndex: 0, aa: 1); allDone.fulfill() }
        await Task.yield()
        await fulfillment(of: [score1Started], timeout: 2.0)

        // Dispatch mutation 2 to supersede mutation 1 (updates mirror → 2).
        Task { await c.applyMutationAwait(residueIndex: 1, aa: 2); allDone.fulfill() }
        await Task.yield(); await Task.yield()

        // Release gate: closure 1 finishes; closure 2 bails via mirror check (with fix).
        score1Gate.signal()
        await fulfillment(of: [allDone], timeout: 5.0)

        XCTAssertNil(c.errorText,
            "a superseded score job must not set errorText — " +
            "SupersededJobError is an implementation detail, not a user-visible failure")
    }

    // 3. The non-superseded path (single mutation, no racing) must still run and produce a result.
    func testNonSupersededRescoreStillProducesResult() async {
        let c = makeController()
        c.autoRepack = false
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3.0, count: s.count))
        }

        await c.applyMutationAwait(residueIndex: 0, aa: 1)

        XCTAssertNil(c.errorText,
            "a single (non-superseded) rescore must not set errorText")
        XCTAssertNotNil(c.sequenceScore,
            "a single rescore must update sequenceScore")
        XCTAssertFalse(c.isRescoring,
            "isRescoring must be cleared after a successful rescore")
    }

    // MARK: – Bug 2: repack error reporting

    // `repackNowAwait` previously swallowed every error with `try?`, so a failing
    // repack was invisible to the user despite the error banner having been added in
    // Task 1 precisely for this purpose.  After the fix, a thrown repack error must
    // set errorText and the token-guarded `defer` must still clear isRepacking.
    func testRepackErrorSetsErrorTextAndClearsIsRepacking() async {
        struct RepError: Error { let msg: String }
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectRepack(repack: { _, _ in throw RepError(msg: "simulated MLX failure") },
                       loadRepacked: { _, _, _ in })
        // Rescore (called after repack in the new order) must succeed; inject a
        // well-formed result so it doesn't throw and erroneously set errorText from a
        // different code path. rescoreWorkingObject does not clear errorText, so the
        // error set by the failing repack survives until the test's XCTAssertNotNil.
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        // Mutate residue 0 from aa=5 to aa=1; autoRepack=true → triggers repackNowAwait.
        await c.applyMutationAwait(residueIndex: 0, aa: 1)

        XCTAssertNotNil(c.errorText,
                        "a throwing repack must set errorText so the error banner fires")
        XCTAssertFalse(c.isRepacking,
                       "the token-guarded defer must clear isRepacking even on the error path")
    }

    // MARK: – Phase 2d: mutation immediacy (repack-before-rescore + sidechain sticks)

    // 1. `applyMutationAwait` must invoke the repack closure BEFORE the score closure.
    //
    // Rationale: the repack is what the user SEES (new sidechain geometry) and is
    // several times cheaper; the score only drives confidence colouring. Running repack
    // first makes the structural change visible on-screen ~5× sooner on a physical device.
    // Both closures run on the same serial inference queue, so the order is deterministic.
    func testApplyMutationRepacksBeforeRescoring() async {
        var callOrder: [String] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        // repack closure runs on the inference queue (off-main).
        c.injectRepack(
            repack: { _, _ in callOrder.append("repack"); return "ATOM  ..." },
            loadRepacked: { _, _, _ in })
        // score closure also runs on the inference queue (off-main); both are serial.
        c.injectScore { _, s in
            callOrder.append("score")
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        await c.applyMutationAwait(residueIndex: 0, aa: 1)

        XCTAssertEqual(callOrder, ["repack", "score"],
            "repack must be invoked before score — the structural change must " +
            "arrive on-screen before the more expensive confidence-colouring pass; " +
            "assert is on CALL ORDER, not just that both happened")
    }

    // 2. The mutated residue's sidechain is requested after the mutation and is
    //    re-requested after the repack's topology replace.
    //
    // Mechanism: `reconcileSticks()` includes the pinned residue in the desired
    // set, so after `loadRepacked` clears PyMOL's per-atom representations,
    // `teardownSticks + reconcileSticks` re-adds the sticks on the fresh atoms.
    // This is already wired: no extra code is needed beyond what was already there,
    // but this test pins down the behaviour so a refactor can't silently break it.
    func testMutatedResidueSticksShownAndReShownAfterRepack() async {
        var events: [String] = []

        let c = makeController()
        c.injectSetSticks { _, _, resi, on in
            events.append(on ? "show-\(resi)" : "hide-\(resi)")
            return on   // report that WE added the sticks so teardown will hide them
        }
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        // loadRepacked runs on the main actor (synchronously after the continuation).
        // teardownSticks + reconcileSticks also run on the main actor, so ordering
        // within the block is deterministic.
        c.injectRepack(
            repack: { _, _ in "ATOM  ..." },
            loadRepacked: { _, _, _ in events.append("topology-replace") })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        // This test is about the PER-RESIDUE reconcile path, which is only live while
        // the global show-all is off — reconcileSticks() early-returns otherwise.
        // Sidechains now default ON, so turn them off to reach the path under test.
        // (The default-on path is covered by
        // testRepackReShowsAllSidechainsWhenTheyAreOn below.)
        c.setShowSidechains(false)

        // Pin residue 1 (chain "A", resi "2") — this is the residue we will mutate.
        // On iOS, pill mutations always apply to the active (pinned) residue.
        c.setPinned(chain: "A", resi: "2")

        // Clear events collected during setPinned so we can focus on the mutation path.
        events.removeAll()

        await c.applyMutationAwait(residueIndex: 1, aa: 9)

        // Verify that "show-2" appears AFTER "topology-replace" in the event log.
        // This proves that reconcileSticks re-adds the pinned residue's sticks on
        // the freshly-loaded topology (not just before the repack).
        let ri = events.firstIndex(of: "topology-replace")
        XCTAssertNotNil(ri, "loadRepacked (topology replace) must have been called")
        if let ri {
            let showAfterRepack = events[ri...].contains { $0 == "show-2" }
            XCTAssertTrue(showAfterRepack,
                "the mutated residue's sidechain (resi '2') must be re-requested after " +
                "the topology replace — reconcileSticks must add pinned sticks post-repack")
        }
    }

    // With sidechains ON (the default), a repack replaces the object's topology and
    // annihilates its sticks, so the GLOBAL show-all must be re-issued for the
    // working object — the counterpart of the per-residue path above.
    func testRepackReShowsAllSidechainsWhenTheyAreOn() async {
        let c = makeController()
        var showAllCalls: [(String, Bool)] = []
        var events: [String] = []
        c.injectShowAllSidechains { obj, on in
            showAllCalls.append((obj, on))
            events.append(on ? "show-all-\(obj)" : "hide-all-\(obj)")
        }
        c.injectSetSticks { _, _, _, on in on }
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.injectRepack(
            repack: { _, _ in "ATOM  ..." },
            loadRepacked: { _, _, _ in events.append("topology-replace") })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        XCTAssertTrue(c.showSidechains, "pre-condition: sidechains default on")
        events.removeAll()

        await c.applyMutationAwait(residueIndex: 1, aa: 9)

        let ri = events.firstIndex(of: "topology-replace")
        XCTAssertNotNil(ri, "loadRepacked (topology replace) must have been called")
        if let ri {
            XCTAssertTrue(events[ri...].contains { $0 == "show-all-m1_design" },
                "after the topology replace the global show-all must be re-issued for " +
                "the working object, or the design ends up with no sidechains visible")
        }
    }

    // 3. Sticks the controller did not add (setSticksFn returned false = user's own)
    //    must never be hidden by the controller. This is the ownership rule baked into
    //    reconcileSticks and teardownSticks via the `managedSticks[key] = added` guard.
    //
    // No existing test covers this specific invariant — testReconcileSticksIsNoOpWhenShowSidechainsOn
    // tests the early-return guard (showSidechains == true), which is a separate path.
    // An iOS tap that MISSES must reach the controller as an empty hit so it
    // clears the selection. The old designPickResidue returned early on a miss,
    // making empty-space taps silently inert.
    func testEmptyHitClearsThroughTheSameRouting() {
        let c = makeController()
        var clearCalls = 0
        c.injectSele(clearSele: { clearCalls += 1 })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.tapResidue(residueIndex: 0)

        c.handleViewportHit(object: "", chain: "", resi: "", hasResidue: false)

        XCTAssertEqual(clearCalls, 1,
                       "a miss must clear 'sele' through the injected closure")
        XCTAssertEqual(c.focusObject, "m1", "a miss must not change focus")
    }

    func testSticksNotOwnedByControllerAreNeverRemoved() {
        var hiddenResidue: [String] = []
        let c = makeController()
        // setSticksFn always returns false: the residue already has sticks (user's own).
        c.injectSetSticks { _, _, resi, on in
            if !on { hiddenResidue.append(resi) }
            return false   // report that the residue already had sticks — WE did not add them
        }
        c.injectEdit(makeWorkingCopy: { $0 + "_design" },
                     mutateDisplay: { _, _, _, _ in },
                     discard: { _, _ in }, compare: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))

        // Pin resi "2": setSticksFn(on=true) returns false → managedSticks["A\u{1}2"] = false.
        c.setPinned(chain: "A", resi: "2")

        hiddenResidue.removeAll()   // ignore any hide calls that happened before the test body

        // Switch pin to resi "3": reconcileSticks sees "2" no longer wanted.
        // Because managedSticks["A\u{1}2"] == false (not added by us), it must NOT
        // call setSticksFn(on=false) for resi "2" — the ownership rule.
        c.setPinned(chain: "A", resi: "3")

        XCTAssertFalse(hiddenResidue.contains("2"),
            "a residue whose sticks the controller did not add (setSticksFn returned false) " +
            "must never be hidden by the controller — ownership rule: only remove what we added")
    }
}
#endif
