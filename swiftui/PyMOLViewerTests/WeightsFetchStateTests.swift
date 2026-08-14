import XCTest
@testable import RayMol

/// The Swift half of the WEIGHTS: marker contract (#284).
///
/// The payloads below are VERBATIM captures from a real fetch driven through the app's
/// own command path — not hand-written to match the decoder, which would only prove the
/// decoder agrees with itself. If `pymol/predictors/fetching.py` renames or retypes a
/// key, these fail; without them the only symptom would be a progress sheet that
/// silently never appears, which is indistinguishable from the bug this fixed.
final class WeightsFetchStateTests: XCTestCase {

    private func decode(_ json: String) throws -> WeightsFetchState {
        try JSONDecoder().decode(WeightsFetchState.self, from: Data(json.utf8))
    }

    func testDecodesAnInFlightDownloadMarker() throws {
        let state = try decode("""
        {"id":"stub-slow","state":"running","phase":"download",\
        "fraction":0.3666640091135,"received":11534336,"total":31457508,"error":null}
        """)
        XCTAssertEqual(state.id, "stub-slow")
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isExtracting)
        XCTAssertFalse(state.isError)
        XCTAssertEqual(state.fraction, 0.3666640091135, accuracy: 1e-9)
        XCTAssertEqual(state.received, 11_534_336)
        XCTAssertEqual(state.total, 31_457_508)
        XCTAssertNil(state.error)
    }

    func testDecodesTheExtractPhase() throws {
        let state = try decode("""
        {"id":"stub-slow","state":"running","phase":"extract","fraction":0.5,\
        "received":0,"total":31457508,"error":null}
        """)
        XCTAssertTrue(state.isExtracting)
        XCTAssertTrue(state.isRunning)
        // Bytes are deliberately zero outside the download phase: the fraction counts
        // archive members there, so a byte count derived from it would be a lie. The
        // overlay must fall back to its "Unpacking…" label rather than show "0 MB of".
        XCTAssertEqual(state.received, 0)
    }

    func testDecodesTheTerminalDoneMarker() throws {
        let state = try decode("""
        {"id":"stub-slow","state":"done","phase":"extract","fraction":1.0,\
        "received":0,"total":31457508,"error":null}
        """)
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.isError)
    }

    func testDecodesACancelledMarker() throws {
        let state = try decode("""
        {"id":"boltz2-mlx-int8","state":"cancelled","phase":"download",\
        "fraction":0.12,"received":63520628,"total":529338573,"error":null}
        """)
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.isError)
    }

    func testDecodesAnErrorMarkerWithItsMessage() throws {
        let state = try decode("""
        {"id":"boltz2-mlx-int8","state":"error","phase":"download","fraction":0.0,\
        "received":0,"total":529338573,"error":"failed to fetch https://example/b.zip"}
        """)
        XCTAssertTrue(state.isError)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.error, "failed to fetch https://example/b.zip")
    }

    /// A marker that does not decode must be ignored, not crash the feedback poll --
    /// pollFeedback runs on the main thread every 100 ms and drives the whole UI.
    func testAMalformedPayloadDecodesToNilRatherThanThrowingIntoThePoll() {
        let junk = Data("{\"id\":\"x\"}".utf8)
        XCTAssertNil(try? JSONDecoder().decode(WeightsFetchState.self, from: junk))
    }

    /// `elapsed` was added after the first cut. A payload without it must still
    /// decode: losing the ETA is cosmetic, a failed decode would take the whole
    /// progress sheet with it and look exactly like the bug this all fixed.
    func testAPayloadWithoutElapsedStillDecodes() throws {
        let state = try decode("""
        {"id":"stub","state":"running","phase":"download","fraction":0.5,\
        "received":100,"total":200,"error":null}
        """)
        XCTAssertNil(state.elapsed)
        XCTAssertNil(state.secondsRemaining)
    }

    // -- ETA ------------------------------------------------------------------

    func testEstimatesTimeRemainingFromTheAverageRate() throws {
        // 100 MB of 500 MB in 10 s => 10 MB/s => 400 MB left => 40 s.
        let state = try decode("""
        {"id":"b","state":"running","phase":"download","fraction":0.2,\
        "received":104857600,"total":524288000,"elapsed":10.0,"error":null}
        """)
        let eta = try XCTUnwrap(state.secondsRemaining)
        XCTAssertEqual(eta, 40.0, accuracy: 0.5)
    }

    func testNoEstimateBeforeThereIsEnoughHistoryToMakeOneHonestly() throws {
        // A sub-second divisor produces an absurd figure; better to show nothing.
        let early = try decode("""
        {"id":"b","state":"running","phase":"download","fraction":0.001,\
        "received":1024,"total":524288000,"elapsed":0.2,"error":null}
        """)
        XCTAssertNil(early.secondsRemaining)

        // Extraction counts archive members, not bytes — a byte-derived ETA there
        // would be meaningless.
        let extracting = try decode("""
        {"id":"b","state":"running","phase":"extract","fraction":0.5,\
        "received":0,"total":524288000,"elapsed":60.0,"error":null}
        """)
        XCTAssertNil(extracting.secondsRemaining)
    }

    func testRemainingIsFormattedCoarsely() {
        // Coarse on purpose: a to-the-second countdown invites trust in a number
        // derived from an average rate.
        XCTAssertEqual(WeightDownloadOverlay.formatRemaining(4), "almost done")
        XCTAssertEqual(WeightDownloadOverlay.formatRemaining(45), "45 sec left")
        XCTAssertEqual(WeightDownloadOverlay.formatRemaining(240), "4 min left")
        XCTAssertEqual(WeightDownloadOverlay.formatRemaining(9000), "over an hour left")
    }
}
