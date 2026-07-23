#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

@MainActor
final class DesignEditingTests: XCTestCase {

    // Build a controller with stub closures for the Phase-2a path (score/applyColoring/etc).
    // Edit-specific closures are injected via injectEdit(...) in each test.
    func makeController() -> DesignController {
        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        return DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, _ in
                MPNNModel.ScoreResult(logProbs: [], currentAALogProb: [])
            },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
    }

    // Convenience: all-valid residue flags for a given count.
    private func allValid(_ count: Int) -> [Bool] { Array(repeating: true, count: count) }

    func testFirstMutationBeginsEditAndMarksDirty() {
        var created: [String] = []
        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { src in created.append(src); return src + "_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _, _ in },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 1, aa: 9)               // -> LEU
        XCTAssertTrue(c.editing)
        XCTAssertEqual(created, ["m1"])                       // working copy made exactly once
        XCTAssertEqual(c.editedSequence[1], 9)
        XCTAssertEqual(c.editCount, 1)
        XCTAssertTrue(c.repackDirty)
        c.applyMutation(residueIndex: 2, aa: 9)               // second edit: no new copy
        XCTAssertEqual(created, ["m1"])
        XCTAssertEqual(c.editCount, 2)
    }

    func testDiscardResetsState() {
        var discarded: [String] = []
        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { $0 + "_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _, dst in discarded.append(dst) },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 0, aa: 1)
        c.discardEdits()
        XCTAssertFalse(c.editing)
        XCTAssertEqual(c.editCount, 0)
        XCTAssertEqual(discarded, ["m1_design"])
    }

    func testKeepEndsSessionWithoutDiscard() {
        var discardCalls: [String] = []
        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { $0 + "_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _, dst in discardCalls.append(dst) },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 0, aa: 9)    // begins session
        XCTAssertTrue(c.editing)
        c.keepEdits()
        XCTAssertFalse(c.editing)
        XCTAssertEqual(c.editCount, 0)
        XCTAssertTrue(discardCalls.isEmpty)         // discard closure must NOT have been called
    }

    func testSameAAAndOutOfRangeAreNoOps() {
        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { $0 + "_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _, _ in },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 1, aa: 9)    // real mutation — editCount == 1
        XCTAssertEqual(c.editCount, 1)
        let dirty = c.repackDirty

        // Same aa at same index — must be a no-op.
        c.applyMutation(residueIndex: 1, aa: 9)
        XCTAssertEqual(c.editCount, 1)
        XCTAssertEqual(c.repackDirty, dirty)

        // Out-of-range indices — must be no-ops.
        c.applyMutation(residueIndex: -1, aa: 3)
        c.applyMutation(residueIndex: 100, aa: 3)
        XCTAssertEqual(c.editCount, 1)
    }

    func testMutationRescoresWithEditedSequence() async {
        var scoredSeqs: [[Int]] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectScore { _, seq in
            scoredSeqs.append(seq)
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3.0, count: 21), count: seq.count),
                currentAALogProb: Array(repeating: -3.0, count: seq.count))
        }
        // All-valid so C3 projection passes through all residues.
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        await c.applyMutationAwait(residueIndex: 1, aa: 9)   // await the rescore
        XCTAssertEqual(scoredSeqs.last, [5, 9, 5])            // rescored with the EDITED sequence
    }

    // MARK: – Task 4: repack action + auto-repack toggle + dirty flag

    func testRepackClearsDirtyAndLoadsCoords() async {
        var repackedSeqs: [[Int]] = []; var loaded: [(String, String)] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(
            repack: { _, seq in repackedSeqs.append(seq); return "PDBDATA" },
            loadRepacked: { obj, pdb in loaded.append((obj, pdb)) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        await c.applyMutationAwait(residueIndex: 0, aa: 1)  // autoRepack=false → stays dirty
        XCTAssertTrue(c.repackDirty)
        await c.repackNowAwait()
        XCTAssertEqual(repackedSeqs.last, [1, 5, 5])        // repack called with edited sequence
        XCTAssertEqual(loaded.last?.0, "m1_design")         // loadRepacked called with working object
        XCTAssertFalse(c.repackDirty)                       // dirty cleared
        XCTAssertFalse(c.isRepacking)                       // flag cleared
    }

    func testAutoRepackRepacksOnEachEdit() async {
        var repacks = 0
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(repack: { _, _ in repacks += 1; return "P" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3)); c.autoRepack = true
        await c.applyMutationAwait(residueIndex: 0, aa: 1)
        XCTAssertEqual(repacks, 1)      // repack ran exactly once
        XCTAssertFalse(c.repackDirty)  // dirty cleared by auto-repack
    }

    // Fix 2: keepEditsAwait must repack when dirty before closing the session.
    func testKeepAwaitRepacksIfDirty() async {
        var repackCalls = 0
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(repack: { _, _ in repackCalls += 1; return "PDBDATA" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 0, aa: 1)     // begins session, marks dirty
        XCTAssertTrue(c.repackDirty)
        await c.keepEditsAwait()
        XCTAssertEqual(repackCalls, 1)    // repack ran exactly once
        XCTAssertFalse(c.repackDirty)    // dirty cleared
        XCTAssertFalse(c.editing)        // session ended
        XCTAssertEqual(c.editCount, 0)   // count reset
    }

    // Fix 3: a repack must NOT cancel an in-flight rescore.
    // Property under test: token independence — repackToken and rescoreToken are separate,
    // so calling repackNow() while a score is blocked does NOT discard the score result.
    //
    // Shape (single serial inferenceQueue — no concurrency required):
    //   1. applyMutation fires a detached Task → rescoreWorkingObject dispatches to inferenceQueue → blocks on semaphore.
    //   2. Wait for scoreStarted so the score is definitely executing.
    //   3. repackNow() (fire-and-forget) — queues the repack closure BEHIND the blocked score on the
    //      single queue; returns immediately with no deadlock because we do NOT await it here.
    //   4. Signal the semaphore → score finishes, guard (token == rescoreToken) passes because
    //      repackNow() only bumped repackToken → applyColoring fires → rescoreDone fulfilled.
    //   5. Assert applyColoring ran for "m1_design".
    //
    // Sanity-check: if the tokens were merged into one, repackNow() would bump it → the score's
    // guard would fail → applyColoring would never fire → rescoreDone would time out → test FAILs.
    func testRepackDoesNotCancelRescore() async throws {
        var recoloredObjs: [String] = []
        let scoreStarted = XCTestExpectation(description: "score started")
        let scoreSemaphore = DispatchSemaphore(value: 0)
        // applyColoring fires twice: once from the rescore (the original assertion),
        // and once from the repack's re-color pass (new: full topology replace resets
        // PyMOL atom colors so repackNowAwait re-applies from cache after loadRepacked).
        let rescoreDone = XCTestExpectation(description: "rescore done")
        rescoreDone.expectedFulfillmentCount = 2

        let emptySet = DesignResidueSet(object: "stub", state: 1, residues: [])
        let c = DesignController(
            enumerate: { _, _ in emptySet },
            score: { _, seq in
                scoreStarted.fulfill()
                scoreSemaphore.wait()    // block until released; repack queues behind this on the single serial queue
                return MPNNModel.ScoreResult(
                    logProbs: Array(repeating: Array(repeating: -3, count: 21), count: seq.count),
                    currentAALogProb: Array(repeating: -3, count: seq.count))
            },
            applyColoring: { obj, _, _, _, _ in
                recoloredObjs.append(obj)
                rescoreDone.fulfill()
            },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectRepack(repack: { _, _ in "PDBDATA" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: [true, true, true])

        // Sync mutation → detached Task starts rescoreWorkingObject → dispatches to inferenceQueue → blocks
        c.applyMutation(residueIndex: 0, aa: 1)

        // Wait until the score stub is actually executing (blocking on semaphore)
        await fulfillment(of: [scoreStarted], timeout: 2)

        // Fire-and-forget repack — queues behind the blocked score; must NOT bump rescoreToken.
        // Do NOT await repackNowAwait() here: that would deadlock on the single serial queue.
        c.repackNow()

        // Release the score; it should complete and apply coloring (rescoreToken unchanged)
        scoreSemaphore.signal()
        await fulfillment(of: [rescoreDone], timeout: 2)

        // The rescore's applyColoring must have fired for the working object
        XCTAssertTrue(recoloredObjs.contains("m1_design"),
                      "rescore coloring was discarded — repack incorrectly cancelled it")
    }

    // MARK: – Fix 2: focus follows working copy, pin preserved

    /// After the first mutation, focusObject must switch to the working copy, the
    /// pinned residue index must be preserved, the residue set must be carried (so
    /// residueIndex resolves), and the score cache must have an entry for the working
    /// object's native-sequence key (so activePropensity returns non-nil).
    func testBeginEditSwitchesFocusToWorkingCopyPreservingPin() async {
        let nativeSeq = [5, 5, 5]
        let residues = nativeSeq.enumerated().map { i, aa -> DesignResidue in
            DesignResidue(chain: "A", resi: "\(i + 1)", resn: "ALA", aa: aa,
                          backbone: MPNNModel.Residue(n: .zero, ca: .zero, c: .zero, o: .zero,
                                                      chain: 0, resSeq: i + 1),
                          valid: true)
        }
        let residueSet = DesignResidueSet(object: "m1", state: 1, residues: residues)

        let c = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, seq in
                MPNNModel.ScoreResult(
                    logProbs: Array(repeating: Array(repeating: -3.0, count: 21), count: seq.count),
                    currentAALogProb: Array(repeating: -3.0, count: seq.count))
            },
            applyColoring: { _, _, _, _, _ in },
            dim: { _ in },
            snapshot: { _ in },
            restore: { })
        c.injectEdit(
            makeWorkingCopy: { _ in "m1_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _, _ in },
            compare: { _ in })

        // Focus + score the original so the native-sequence cache entry exists for "m1".
        await c.focusAwait("m1")
        XCTAssertEqual(c.focusObject, "m1")

        // Pin residue at index 1 (chain "A", resi "2").
        c.setPinned(chain: "A", resi: "2")
        XCTAssertEqual(c.pinnedResidueIndex, 1, "pre-condition: pin must be set before mutation")

        // First mutation triggers beginEditIfNeeded + async rescore.
        await c.applyMutationAwait(residueIndex: 0, aa: 9)

        // Focus must have moved to the working copy.
        XCTAssertEqual(c.focusObject, "m1_design",
                       "focusObject did not switch to working copy after beginEditIfNeeded")
        // Pin must survive the focus switch (same residue ordering as the original).
        XCTAssertEqual(c.pinnedResidueIndex, 1,
                       "pinnedResidueIndex was cleared on edit-begin")
        // The residue set was carried: residueIndex must resolve for "m1_design".
        XCTAssertNotNil(c.residueIndex(chain: "A", resi: "2"),
                        "lastSet not carried to working copy — residueIndex returned nil")
        // activePropensity must be non-nil: cache has entry under working object's native key.
        XCTAssertNotNil(c.activePropensity,
                        "propensity row absent — score cache not carried / not populated for working copy")
    }

    // MARK: – M3: lock the C1/C2/C3 bug-fixes

    /// C3: score must receive a sequence aligned to validResidues only.
    ///
    /// Setup: 3 residues, residue 1 (middle) is invalid (no backbone).
    /// After mutating residue 0 (valid), the score stub must receive a
    /// length-2 sequence (the two valid residues only), not length-3.
    /// This test FAILS against pre-fix code that passes the full editedSequence.
    func testRescoreAlignsSequenceToValidResidues() async {
        var scoredSeqs: [[Int]] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _, _ in }, compare: { _ in })
        c.injectScore { _, seq in
            scoredSeqs.append(seq)
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3.0, count: 21), count: seq.count),
                currentAALogProb: Array(repeating: -3.0, count: seq.count))
        }
        // Residues 0 and 2 are valid; residue 1 is invalid (missing backbone).
        c.setFocusForTest("m1", nativeSequence: [5, 7, 3], validFlags: [true, false, true])
        // Mutate residue 0 (valid): aa 5 → 9
        await c.applyMutationAwait(residueIndex: 0, aa: 9)
        // C3 fix: score receives only the valid residues projected through the mask.
        // validResidues = [res0, res2]; projected seq = [9, 3].
        XCTAssertEqual(scoredSeqs.last?.count, 2,
                       "score received \(scoredSeqs.last?.count ?? -1) residues; expected 2 (valid-only)")
        XCTAssertEqual(scoredSeqs.last, [9, 3],
                       "score received wrong sequence; expected [9 (mutated), 3 (res2)]")
    }

    /// C1/C2: after discardEdits() the original object is re-enabled (not left hidden).
    ///
    /// Uses recording stubs to capture enable/disable calls. The discard closure
    /// re-enables src (as discard_working_copy does), and teardownEditSession must
    /// NOT call setCompare(false) (which would re-disable it) after discard.
    func testDiscardReenablesOriginal() {
        var enabledObjs: [String] = []
        var disabledObjs: [String] = []

        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { src in
                // Simulate make_working_copy disabling the original.
                disabledObjs.append(src)
                return src + "_design"
            },
            mutateDisplay: { _, _, _, _ in },
            discard: { src, _ in
                // Simulate discard_working_copy: re-enable original.
                enabledObjs.append(src)
            },
            compare: { _ in
                // compare(false) would call cmd.disable(src) — record it as disabled
                // so we can detect if teardown incorrectly fires it.
                if !enabledObjs.isEmpty {
                    disabledObjs.append("compare_false_fired")
                }
            })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5], validFlags: allValid(3))
        c.applyMutation(residueIndex: 0, aa: 9)    // triggers beginEditIfNeeded → disables src
        XCTAssertTrue(c.editing)

        c.discardEdits()
        XCTAssertFalse(c.editing)
        // The discard closure must have been called — original re-enabled.
        XCTAssertTrue(enabledObjs.contains("m1"),
                      "discard closure did not re-enable the original object")
        // compare(false) must NOT have been called after discard (that would disable the original).
        XCTAssertFalse(disabledObjs.contains("compare_false_fired"),
                       "setCompare(false) was called after discard — original may have been re-disabled")
    }
}
#endif
