#if os(macOS)
import BoltzMLX
import XCTest
@testable import RayMol

/// The MSA half of the wire (#297): decoding `alignments`, reading each a3m into the
/// parser that will consume it, and reporting a failure with the message it carried.
///
/// These pin the same contract `testing/tests/predict/predict_msa.py` pins from the
/// other side. If the two disagree, the feature is broken in a way neither suite would
/// catch alone — which is the whole reason the wire is tested twice.
final class BoltzJobManagerMSATests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A 5-residue query and `depth - 1` distinct homologs, written as host.py would.
    @discardableResult
    private func writeA3M(_ name: String, query: String = "MKTAY",
                          depth: Int = 3) throws -> String {
        var lines = [">query", query]
        let letters = Array("ACDEFGHIKLMNPQRSTVWY")
        var residues = Array(query)
        for row in 1 ..< max(depth, 1) {
            residues[row % residues.count] = letters[row % letters.count]
            lines.append(">homolog_\(row)")
            lines.append(String(residues))
        }
        let path = dir.appendingPathComponent("\(name).a3m").path
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true,
                                                         encoding: .utf8)
        return path
    }

    private func writeRequest(job: String,
                              chains: [(String, String)],
                              alignments: [[String: String]]? = nil,
                              msaDepth: Int? = nil) throws -> URL {
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        var payload: [String: Any] = [
            "job_id": job,
            "weights_dir": dir.path,
            "chains": chains.map { ["chain": $0.0, "sequence": $0.1] },
            "recycling_steps": 3,
            "diffusion_steps": 200,
            "seed": 0,
            "out_path": dir.appendingPathComponent("out.pdb").path,
            "status_path": dir.appendingPathComponent("status.json").path,
        ]
        if let alignments { payload["alignments"] = alignments }
        if let msaDepth { payload["msa_depth"] = msaDepth }
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return url
    }

    // MARK: - Decoding

    /// The field is OPTIONAL, so a request written by a Python side that predates #297
    /// still decodes. A non-optional field would turn any skew into a hard "malformed
    /// request" failure instead of a single-sequence run.
    func testARequestWithoutAlignmentsStillDecodes() throws {
        let url = try writeRequest(job: "old", chains: [("A", "MKTAY")])
        let parsed = try BoltzJobManager.parseRequest(at: url)
        XCTAssertNil(parsed.alignments)
        XCTAssertNil(parsed.msaDepth)
    }

    func testAlignmentsDecodeWithSnakeCaseKeys() throws {
        let path = try writeA3M("one")
        let url = try writeRequest(job: "a1", chains: [("A", "MKTAY")],
                                   alignments: [["chain": "A", "a3m_path": path]],
                                   msaDepth: 16_384)
        let parsed = try BoltzJobManager.parseRequest(at: url)
        XCTAssertEqual(parsed.alignments?.map(\.chain), ["A"])
        XCTAssertEqual(parsed.alignments?.first?.a3mPath, path)
        XCTAssertEqual(parsed.msaDepth, 16_384)
    }

    // MARK: - Loading

    func testEachChainsAlignmentReachesTheParser() throws {
        let a = try writeA3M("a", query: "MKTAY", depth: 3)
        let b = try writeA3M("b", query: "GSHMA", depth: 5)
        let url = try writeRequest(job: "a2", chains: [("A", "MKTAY"), ("B", "GSHMA")],
                                   alignments: [["chain": "A", "a3m_path": a],
                                                ["chain": "B", "a3m_path": b]])
        let loaded = try BoltzJobManager.loadAlignments(
            try BoltzJobManager.parseRequest(at: url))
        XCTAssertEqual(Set(loaded.keys), ["A", "B"])
        XCTAssertEqual(loaded["A"]?.depth, 3)
        XCTAssertEqual(loaded["B"]?.depth, 5)
        XCTAssertEqual(loaded["A"]?.queryLength, 5)
    }

    /// Mixed is the design case: an alignment for the target, none for the binder. The
    /// map has ONE entry and the featurizer gives the other chain its depth-1 dummy.
    func testAChainWithNoAlignmentIsSimplyAbsentFromTheMap() throws {
        let a = try writeA3M("mixed", query: "MKTAY", depth: 4)
        let url = try writeRequest(job: "a3", chains: [("A", "MKTAY"), ("B", "GSHMA")],
                                   alignments: [["chain": "A", "a3m_path": a]])
        let loaded = try BoltzJobManager.loadAlignments(
            try BoltzJobManager.parseRequest(at: url))
        XCTAssertEqual(Array(loaded.keys), ["A"])
    }

    func testNoAlignmentsMeansAnEmptyMapNotAFailure() throws {
        let url = try writeRequest(job: "a4", chains: [("A", "MKTAY")])
        XCTAssertEqual(try BoltzJobManager.loadAlignments(
            try BoltzJobManager.parseRequest(at: url)).count, 0)
    }

    /// The depth lever is applied by the PARSER, which counts rows after deduplication
    /// and always keeps the query — a count that is not the file's line numbers, which
    /// is why it is not applied as a slice anywhere else.
    func testMsaDepthTruncatesFromTheTop() throws {
        let path = try writeA3M("deep", query: "MKTAY", depth: 10)
        let url = try writeRequest(job: "a5", chains: [("A", "MKTAY")],
                                   alignments: [["chain": "A", "a3m_path": path]],
                                   msaDepth: 4)
        let loaded = try BoltzJobManager.loadAlignments(
            try BoltzJobManager.parseRequest(at: url))
        XCTAssertEqual(loaded["A"]?.depth, 4)
    }

    func testAMissingA3mFailsRatherThanFoldingSingleSequence() throws {
        let url = try writeRequest(
            job: "a6", chains: [("A", "MKTAY")],
            alignments: [["chain": "A",
                          "a3m_path": dir.appendingPathComponent("gone.a3m").path]])
        let request = try BoltzJobManager.parseRequest(at: url)
        XCTAssertThrowsError(try BoltzJobManager.loadAlignments(request))
    }

    /// Absent `msa_depth` falls back to upstream's own cap rather than to "no limit":
    /// only a hand-written request can reach this, and silently unbounded depth is the
    /// one fallback that could exhaust memory.
    func testAbsentDepthFallsBackToUpstreamsCap() throws {
        let path = try writeA3M("nodepth", query: "MKTAY", depth: 3)
        let url = try writeRequest(job: "a7", chains: [("A", "MKTAY")],
                                   alignments: [["chain": "A", "a3m_path": path]])
        let loaded = try BoltzJobManager.loadAlignments(
            try BoltzJobManager.parseRequest(at: url))
        XCTAssertEqual(loaded["A"]?.depth, 3)
        XCTAssertEqual(BoltzInputLimits.desktop.maximumMSADepth, 16_384)
    }

    // MARK: - Failure messages

    /// `localizedDescription` on a plain Swift error bridges through NSError and returns
    /// a placeholder naming only the case NUMBER. For `msaQueryMismatch` that is
    /// destructive: the message is the only thing that says which chain and position
    /// disagree, and upstream Boltz does not throw there at all — it substitutes a dummy
    /// MSA and reports numbers for the wrong complex.
    func testAFeaturizerMismatchKeepsItsMessage() {
        let error = BoltzFeaturizerError.msaQueryMismatch(chain: "A", positions: [7, 9])
        let message = BoltzJobManager.message(for: error)
        XCTAssertEqual(message, error.description)
        XCTAssertTrue(message.contains("chain A"))
        XCTAssertFalse(message.contains("The operation couldn"),
                       "the NSError placeholder means the real message was lost")
    }

    func testALengthMismatchKeepsItsMessage() {
        let error = BoltzFeaturizerError.msaLengthMismatch(chain: "B", expected: 110,
                                                           found: 108)
        let message = BoltzJobManager.message(for: error)
        XCTAssertTrue(message.contains("110"))
        XCTAssertTrue(message.contains("108"))
    }

    /// Reachable only if the two parsers disagree — Python checks every row's column
    /// count at `load_msa` — so it is reported plainly rather than as a raw enum case.
    func testAParseErrorIsReportedInWords() {
        let message = BoltzJobManager.message(
            for: MSAParseError.rowLengthMismatch(row: 2, expected: 24, found: 20))
        XCTAssertTrue(message.contains("row 3"), message)
        XCTAssertTrue(message.contains("24"), message)
        XCTAssertFalse(message.contains("rowLengthMismatch"), message)
    }

    func testAnEmptyAlignmentIsReportedInWords() {
        let message = BoltzJobManager.message(for: MSAParseError.empty)
        XCTAssertTrue(message.contains("no sequences"), message)
    }

    /// An NSError-backed failure — a missing a3m is one — already has a good
    /// localizedDescription, and must not be replaced by a raw `String(describing:)`.
    func testACocoaErrorKeepsItsLocalizedDescription() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "no such file"])
        XCTAssertEqual(BoltzJobManager.message(for: error), "no such file")
    }

    // MARK: - End to end

    /// A mismatched alignment must land as a FAILED JOB carrying the featurizer's own
    /// message — the acceptance criterion for #297's first non-negotiable, driven
    /// through the real `handle(marker:)` entry point rather than asserted on a helper.
    ///
    /// No weights needed, and that is not a trick: `featurize` runs before the predictor
    /// is loaded, so a mismatch is caught without a 505 MB bundle. That ordering is
    /// itself worth pinning — it is what makes a wrong a3m cost seconds instead of a
    /// download.
    func testAMismatchedAlignmentFailsTheJobWithTheFeaturizersMessage() throws {
        let job = "msa-e2e-\(UUID().uuidString.prefix(8))"
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let requestURL = temp.appendingPathComponent("raymol_predict_req_\(job).json")
        let statusURL = temp.appendingPathComponent("raymol_predict_status_\(job).json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: statusURL)
        }

        // Same length, one residue different: msaQueryMismatch rather than
        // msaLengthMismatch, because it is the one whose message names a POSITION and
        // therefore the one that loses the most to an NSError placeholder.
        let a3m = try writeA3M("mismatch", query: "MKTAW", depth: 3)
        let payload: [String: Any] = [
            "job_id": job,
            "weights_dir": temp.appendingPathComponent("no-such-weights").path,
            "chains": [["chain": "A", "sequence": "MKTAY"]],
            "recycling_steps": 3, "diffusion_steps": 200, "seed": 0,
            "out_path": dir.appendingPathComponent("out.pdb").path,
            "status_path": statusURL.path,
            "alignments": [["chain": "A", "a3m_path": a3m]],
            "msa_depth": 16_384,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: requestURL)

        BoltzJobManager.shared.handle(marker: "PREDICT:submit:\(job)")

        let settled = expectation(description: "job settles")
        let poll = DispatchQueue(label: "poll")
        func check(_ attempt: Int) {
            if let data = try? Data(contentsOf: statusURL),
               let status = try? JSONDecoder().decode(BoltzJobManager.Status.self,
                                                      from: data),
               status.state != "queued" {
                return settled.fulfill()
            }
            guard attempt < 300 else { return settled.fulfill() }
            poll.asyncAfter(deadline: .now() + 0.1) { check(attempt + 1) }
        }
        poll.async { check(0) }
        wait(for: [settled], timeout: 40)

        let data = try Data(contentsOf: statusURL)
        let status = try JSONDecoder().decode(BoltzJobManager.Status.self, from: data)
        XCTAssertEqual(status.state, "failed")
        let error = try XCTUnwrap(status.error)
        XCTAssertTrue(error.contains("chain A"), error)
        XCTAssertFalse(error.contains("The operation couldn"),
                       "the featurizer's message was replaced by the NSError "
                       + "placeholder: \(error)")
    }
}
#endif
