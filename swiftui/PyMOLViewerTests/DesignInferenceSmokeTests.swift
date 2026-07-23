#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

/// Real on-host MPNN inference smoke test.
/// Loads the 24 MB weights from the bundled MPNN.mpnnpack and runs a
/// `score(.leaveOneOut)` over a small hardcoded backbone to confirm the
/// full inference path works inside RayMol's build.
///
/// Gated: skipped unless `MPNN_INFERENCE=1` is set in the environment so the
/// normal fast suite never blocks on MLX weight loading.
/// Run with:
///   cd swiftui && MPNN_INFERENCE=1 xcodebuild test \
///     -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS \
///     -destination 'platform=macOS' -skipPackagePluginValidation \
///     -only-testing:PyMOLViewerTests/DesignInferenceSmokeTests
final class DesignInferenceSmokeTests: XCTestCase {

    // MARK: - Helpers

    /// Build an 8-residue linear backbone with plausible bond geometry.
    /// CA atoms are spaced 3.8 Å apart (ideal alpha-carbon spacing).
    /// N is ~1.46 Å from CA, C is ~1.52 Å from CA, O extends ~1.23 Å from C.
    private static func makeResidues() -> [MPNNModel.Residue] {
        (0 ..< 8).map { i in
            let z = Float(i) * 3.8
            // N slightly before CA along chain
            let n  = SIMD3<Float>(-1.20,  0.00, z - 0.77)   // N-CA ≈ 1.46 Å
            let ca = SIMD3<Float>( 0.00,  0.00, z)
            // C slightly after CA
            let c  = SIMD3<Float>( 1.30,  0.00, z + 0.77)   // CA-C ≈ 1.52 Å
            // O extends perpendicular from C (C=O ≈ 1.23 Å)
            let o  = SIMD3<Float>( 1.30,  1.23, z + 0.77)
            return MPNNModel.Residue(n: n, ca: ca, c: c, o: o, chain: 0, resSeq: i + 1)
        }
    }

    /// A trivial valid sequence of length 8: [ALA, GLY, VAL, LEU, ILE, PRO, PHE, TRP]
    private static let testSequence: [Int] = [0, 6, 19, 11, 8, 13, 5, 17]

    // MARK: - Tests

    func testRealMPNNInferenceSmokeLeaveOneOut() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MPNN_INFERENCE"] == "1",
            "Real-inference smoke; set MPNN_INFERENCE=1 to enable (loads 24 MB weights + runs MLX)."
        )

        // 1. Locate and load the real model from the bundled .mpnnpack.
        let packURL = try XCTUnwrap(
            MPNNGate.packURL,
            "MPNN.mpnnpack not found in Bundle.main — app was not built with resources."
        )
        let model = try MPNNModel(packDirectory: packURL)

        // 2. Build a small backbone and a matching native sequence.
        let residues = Self.makeResidues()
        let seq = Self.testSequence
        XCTAssertEqual(residues.count, seq.count)          // sanity

        // 3. Run real inference: leave-one-out scoring.
        let result = try model.score(residues, sequence: seq, mode: .leaveOneOut, seed: 0)

        // 4. Shape assertions.
        XCTAssertEqual(result.logProbs.count, residues.count,
                       "logProbs must have one row per residue")
        for (i, row) in result.logProbs.enumerated() {
            XCTAssertEqual(row.count, 21,
                           "Row \(i) must have 21 columns (20 AAs + X)")
        }

        let curLP = try XCTUnwrap(result.currentAALogProb,
                                  "currentAALogProb should not be nil when sequence is provided")
        XCTAssertEqual(curLP.count, residues.count,
                       "currentAALogProb must have one value per residue")

        // 5. All values must be finite and log-probs must be ≤ 0.
        for (i, row) in result.logProbs.enumerated() {
            for (j, v) in row.enumerated() {
                XCTAssert(v.isFinite, "logProbs[\(i)][\(j)] = \(v) is not finite")
                XCTAssertLessThanOrEqual(v, 0.0,
                    "logProbs[\(i)][\(j)] = \(v) must be ≤ 0 (it is a log-probability)")
            }
        }
        for (i, v) in curLP.enumerated() {
            XCTAssert(v.isFinite, "currentAALogProb[\(i)] = \(v) is not finite")
            XCTAssertLessThanOrEqual(v, 0.0,
                "currentAALogProb[\(i)] = \(v) must be ≤ 0")
        }

        // 6. Print a few sample values so the run log captures real numbers.
        print("[DesignInferenceSmokeTests] packURL: \(packURL.lastPathComponent)")
        print("[DesignInferenceSmokeTests] residues: \(residues.count), seq: \(seq)")
        print("[DesignInferenceSmokeTests] curLP[0..3]: \(curLP.prefix(4).map { String(format: "%.4f", $0) })")
        print("[DesignInferenceSmokeTests] logProbs[0][0..4]: \(result.logProbs[0].prefix(5).map { String(format: "%.4f", $0) })")
    }
}
#endif
