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

    func testFirstMutationBeginsEditAndMarksDirty() {
        var created: [String] = []
        let c = makeController()
        c.injectEdit(
            makeWorkingCopy: { src in created.append(src); return src + "_design" },
            mutateDisplay: { _, _, _, _ in },
            discard: { _ in },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])   // GLY, GLY, GLY
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
            discard: { discarded.append($0) },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
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
            discard: { discardCalls.append($0) },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
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
            discard: { _ in },
            compare: { _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
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
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _ in }, compare: { _ in })
        c.injectScore { _, seq in
            scoredSeqs.append(seq)
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3.0, count: 21), count: seq.count),
                currentAALogProb: Array(repeating: -3.0, count: seq.count))
        }
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
        await c.applyMutationAwait(residueIndex: 1, aa: 9)   // await the rescore
        XCTAssertEqual(scoredSeqs.last, [5, 9, 5])            // rescored with the EDITED sequence
    }

    // MARK: – Task 4: repack action + auto-repack toggle + dirty flag

    func testRepackClearsDirtyAndLoadsCoords() async {
        var repackedSeqs: [[Int]] = []; var loaded: [(String, String)] = []
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(
            repack: { _, seq in repackedSeqs.append(seq); return "PDBDATA" },
            loadRepacked: { obj, pdb in loaded.append((obj, pdb)) })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
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
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(repack: { _, _ in repacks += 1; return "P" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5]); c.autoRepack = true
        await c.applyMutationAwait(residueIndex: 0, aa: 1)
        XCTAssertEqual(repacks, 1)      // repack ran exactly once
        XCTAssertFalse(c.repackDirty)  // dirty cleared by auto-repack
    }

    // Fix 2: keepEditsAwait must repack when dirty before closing the session.
    func testKeepAwaitRepacksIfDirty() async {
        var repackCalls = 0
        let c = makeController()
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _ in }, compare: { _ in })
        c.injectScore { _, s in
            MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: -3, count: 21), count: s.count),
                currentAALogProb: Array(repeating: -3, count: s.count))
        }
        c.injectRepack(repack: { _, _ in repackCalls += 1; return "PDBDATA" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])
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
        let rescoreDone = XCTestExpectation(description: "rescore done")

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
        c.injectEdit(makeWorkingCopy: { $0 + "_design" }, mutateDisplay: { _, _, _, _ in }, discard: { _ in }, compare: { _ in })
        c.injectRepack(repack: { _, _ in "PDBDATA" }, loadRepacked: { _, _ in })
        c.setFocusForTest("m1", nativeSequence: [5, 5, 5])

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
}
#endif
