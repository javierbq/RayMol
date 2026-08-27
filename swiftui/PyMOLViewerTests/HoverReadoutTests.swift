import XCTest
@testable import RayMol

/// Coverage for `HoverReadout` — the hover-identity chip in the viewport's
/// top-right corner (#359).
///
/// The whole point of keeping the formatter a pure function of
/// (pick payload, selection level) is that these rules can be pinned down
/// without a live core, a camera, or a gesture: the readout must name exactly
/// the scope a click at the current `mouse_selection_mode` would commit —
/// no finer (it would promise a precision the click doesn't have) and no
/// coarser (it would be useless for "which residue am I about to click?").
final class HoverReadoutTests: XCTestCase {

    /// A hit on `1abc / chain J / TYR 42 / CA`, single-state, segment A1.
    private func hit(mode: Int,
                     chain: String = "J",
                     segi: String = "A1",
                     stateCount: Int = 1,
                     state: Int = 1) -> HoverIdentity {
        HoverIdentity(object: "1abc", chain: chain, resi: "42", resn: "TYR",
                      segi: segi, name: "CA", mode: mode,
                      state: state, stateCount: stateCount)
    }

    // MARK: - One readout per selection level

    func testObjectLevelNamesOnlyTheObject() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 4)), "1abc",
                       "Object level commits the whole object — naming its chain "
                       + "or residue would advertise a scope the click never selects")
    }

    func testChainLevelStopsAtTheChain() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 2)), "1abc / chain J")
    }

    func testSegmentLevelNamesChainAndSegment() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 3)), "1abc / chain J / seg A1")
    }

    func testResidueLevelNamesTheResidue() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 1)), "1abc / chain J / TYR 42")
    }

    func testAtomLevelAppendsTheAtomName() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 0)), "1abc / chain J / TYR 42 / CA")
    }

    func testMoleculeLevelTagsTheAnchorResidue() {
        // mouse_selection_mode 5 commits `bymol` — the whole connected
        // component. The "mol" tag is what keeps it from being misread as a
        // residue-level pick of the same residue.
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 5)), "1abc / chain J / mol TYR 42")
    }

    func testCAlphaLevelReadsLikeResidueLevel() {
        // Mode 6 expands to the residue in `_mode_expr`, so the readout has to
        // agree with it rather than inventing a Cα-specific scope.
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 6)), "1abc / chain J / TYR 42")
    }

    // MARK: - State component

    func testStateOmittedForSingleStateObject() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 1, stateCount: 1)),
                       "1abc / chain J / TYR 42",
                       "a single-state object has no state worth naming — the chip "
                       + "stays short")
    }

    func testStateShownForMultiStateObject() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 1, stateCount: 20, state: 7)),
                       "1abc / state 7 / chain J / TYR 42",
                       "an NMR/trajectory hit must say WHICH state it picked — the "
                       + "pick projects the displayed state, not state 1")
    }

    func testStateShownAtEveryLevelIncludingObject() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 4, stateCount: 20, state: 7)),
                       "1abc / state 7")
    }

    // MARK: - Missing fields degrade instead of showing empty components

    func testBlankChainIsDroppedNotRenderedEmpty() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 1, chain: "")),
                       "1abc / TYR 42",
                       "a chainless atom must not produce a dangling \"chain \"")
    }

    func testChainLevelWithNoChainFallsBackToTheObject() {
        // `_mode_expr` selects the whole object when the atom carries no chain;
        // the readout has to fall back the same way.
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 2, chain: "")), "1abc")
    }

    func testSegmentLevelWithNoSegmentFallsBackToTheObject() {
        XCTAssertEqual(HoverReadout.text(for: hit(mode: 3, segi: "")), "1abc",
                       "`_mode_expr` selects the whole object for a segi-less atom, "
                       + "so naming the chain would overstate the pick")
    }

    func testNoObjectMeansNoReadout() {
        var id = hit(mode: 1)
        id.object = ""
        XCTAssertNil(HoverReadout.text(for: id))
    }

    // MARK: - Payload decoding

    func testDecodesAFullPayload() {
        let payload: [String: Any] = [
            "hit": true, "obj": "1abc", "chain": "J", "resi": "42",
            "resn": "TYR", "segi": "A1", "name": "CA",
            "mode": 0, "state": 3, "nstates": 12,
        ]
        XCTAssertEqual(HoverReadout.text(payload: payload),
                       "1abc / state 3 / chain J / TYR 42 / CA")
    }

    func testMissedPickProducesNoReadout() {
        XCTAssertNil(HoverReadout.decode(payload: ["hit": false]))
        XCTAssertNil(HoverReadout.text(payload: ["hit": false]),
                     "empty space must hide the chip, not leave the last hit on screen")
    }

    func testUnreadablePayloadProducesNoReadout() {
        XCTAssertNil(HoverReadout.text(payload: nil))
        XCTAssertNil(HoverReadout.text(payload: [:]),
                     "a payload with no `hit` key told us nothing — hide the chip")
    }

    func testPayloadWithoutModeDefaultsToResidue() {
        // mouse_selection_mode 1 (residue) is the app default and the fallback
        // `hover_preview_at` itself uses when the setting can't be read.
        let payload: [String: Any] = [
            "hit": true, "obj": "1abc", "chain": "J", "resi": "42", "resn": "TYR",
        ]
        XCTAssertEqual(HoverReadout.text(payload: payload), "1abc / chain J / TYR 42")
    }

    /// The level comes from the PAYLOAD (captured at pick time), not from the
    /// Swift-side scene mirror, which only refreshes on the ~500 ms poll. Right
    /// after a Tab (cycle selection level) the mirror is a level behind, and a
    /// chip formatted from it would name a scope the click no longer commits.
    func testLevelComesFromThePayload() {
        let payload: [String: Any] = [
            "hit": true, "obj": "1abc", "chain": "J", "resi": "42",
            "resn": "TYR", "segi": "A1", "name": "CA", "mode": 2,
        ]
        XCTAssertEqual(HoverReadout.text(payload: payload), "1abc / chain J")
    }
}
