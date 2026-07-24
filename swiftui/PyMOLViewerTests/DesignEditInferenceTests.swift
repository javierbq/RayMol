#if RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

/// Real on-host mutate → repack → rescore smoke test (Phase 2b, Task 7).
///
/// Exercises the ACTUAL MPNNKit `repack()` and `score()` on an edited sequence —
/// the first end-to-end test that goes beyond stubbed closures.
///
/// Gated: skipped unless `MPNN_INFERENCE=1` is set in the environment so the
/// normal fast suite never blocks on MLX weight loading.
/// Run with:
///   cd swiftui && MPNN_INFERENCE=1 xcodebuild test \
///     -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS_Inference \
///     -destination 'platform=macOS' -skipPackagePluginValidation \
///     -only-testing:PyMOLViewerTests/DesignEditInferenceTests
final class DesignEditInferenceTests: XCTestCase {

    // MARK: - Backbone fixture (matches DesignInferenceSmokeTests)

    /// 8-residue linear backbone with plausible bond geometry.
    /// CA atoms spaced 3.8 Å apart; N/C/O at ideal covalent distances.
    private static func makeResidues() -> [MPNNModel.Residue] {
        (0 ..< 8).map { i in
            let z = Float(i) * 3.8
            let n  = SIMD3<Float>(-1.20,  0.00, z - 0.77)   // N-CA ≈ 1.46 Å
            let ca = SIMD3<Float>( 0.00,  0.00, z)
            let c  = SIMD3<Float>( 1.30,  0.00, z + 0.77)   // CA-C ≈ 1.52 Å
            let o  = SIMD3<Float>( 1.30,  1.23, z + 0.77)   // C=O ≈ 1.23 Å
            return MPNNModel.Residue(n: n, ca: ca, c: c, o: o, chain: 0, resSeq: i + 1)
        }
    }

    /// Native sequence: [ALA, HIS, TYR, ASN, LYS, GLN, GLY, VAL] (indices in ALPHABET "ACDEFGHIKLMNPQRSTVWYX")
    private static let nativeSequence: [Int] = [0, 6, 19, 11, 8, 13, 5, 17]

    // MARK: - Gated test

    func testMutateRepackRescore() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MPNN_INFERENCE"] == "1",
            "Real-inference smoke; set MPNN_INFERENCE=1 to enable (loads ~24 MB weights + runs MLX)."
        )

        // 1. Load the real model from the bundled .mpnnpack.
        let packURL = try XCTUnwrap(
            MPNNGate.packURL,
            "MPNN.mpnnpack not found in Bundle.main — app was not built with MPNN resources."
        )
        let model = try MPNNModel(packDirectory: packURL)

        // 2. Build backbone + edited sequence (pos 3: ASN→LEU, index 11→9).
        let residues = Self.makeResidues()
        var edited = Self.nativeSequence           // copy
        edited[3] = 9                              // LEU (alphabet index 9 = 'L')
        XCTAssertEqual(residues.count, edited.count)

        // 3. Repack side chains for the edited sequence → must produce non-empty PDB.
        let rp = try model.repack(residues, sequence: edited)
        XCTAssertFalse(rp.pdb.isEmpty,
                       "repack() returned an empty PDB for the edited sequence")
        // atomConfidence is L×14; shape sanity.
        XCTAssertEqual(rp.atomConfidence.count, residues.count,
                       "atomConfidence must have one row per residue")
        for (i, row) in rp.atomConfidence.enumerated() {
            XCTAssertEqual(row.count, 14, "atomConfidence[\(i)] must have 14 atom-slot columns")
        }

        // 4. Score the edited sequence with leave-one-out.
        let sr = try model.score(residues, sequence: edited, mode: .leaveOneOut, seed: 0)

        // Shape: one row per residue, 21 columns each.
        XCTAssertEqual(sr.logProbs.count, residues.count,
                       "logProbs must have one row per residue")
        for (i, row) in sr.logProbs.enumerated() {
            XCTAssertEqual(row.count, 21,
                           "logProbs[\(i)] must have 21 columns (20 AAs + X)")
        }

        // currentAALogProb: one value per residue when a sequence is provided.
        let curLP = try XCTUnwrap(sr.currentAALogProb,
                                  "currentAALogProb should not be nil when a sequence is supplied")
        XCTAssertEqual(curLP.count, residues.count,
                       "currentAALogProb must have one value per residue")

        // All logProbs must be finite and ≤ 0 (log-probability space).
        for (i, row) in sr.logProbs.enumerated() {
            for (j, v) in row.enumerated() {
                XCTAssert(v.isFinite,   "logProbs[\(i)][\(j)] = \(v) is not finite")
                XCTAssertLessThanOrEqual(v, 0.0,
                    "logProbs[\(i)][\(j)] = \(v) must be ≤ 0 (log-probability)")
            }
        }
        for (i, v) in curLP.enumerated() {
            XCTAssert(v.isFinite, "currentAALogProb[\(i)] = \(v) is not finite")
            XCTAssertLessThanOrEqual(v, 0.0,
                "currentAALogProb[\(i)] = \(v) must be ≤ 0 (log-probability)")
        }

        // 5. Emit sample values so the run log records real numbers for verification.
        print("[DesignEditInferenceTests] packURL: \(packURL.lastPathComponent)")
        print("[DesignEditInferenceTests] native seq: \(Self.nativeSequence)")
        print("[DesignEditInferenceTests] edited seq: \(edited) (pos 3: ASN→LEU)")
        print("[DesignEditInferenceTests] repack pdb length: \(rp.pdb.count) chars")
        print("[DesignEditInferenceTests] curLP[0..3]: \(curLP.prefix(4).map { String(format: "%.4f", $0) })")
        print("[DesignEditInferenceTests] logProbs[3][0..4]: \(sr.logProbs[3].prefix(5).map { String(format: "%.4f", $0) })")
        print("[DesignEditInferenceTests] logProbs[3][9] (LEU prob): \(String(format: "%.4f", sr.logProbs[3][9]))")
    }

    func testDesignRegionFixesRestAndHonorsOmit() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MPNN_INFERENCE"] == "1",
            "Real-inference; set MPNN_INFERENCE=1 to enable.")
        let packURL = try XCTUnwrap(MPNNGate.packURL)
        let model = try MPNNModel(packDirectory: packURL)

        let residues = Self.makeResidues()
        let native = Self.nativeSequence
        let L = residues.count

        // Redesign only positions 1 and 2; hold the rest fixed to native.
        let free: Set<Int> = [1, 2]
        let fixed = Set(0..<L).subtracting(free)
        // Omit CYS (index 4) everywhere.
        let omit = Array(repeating: Set([4]), count: L)

        var opts = MPNNModel.DesignOptions()
        opts.temperature = 0; opts.seed = 0
        opts.fixedPositions = fixed
        opts.nativeSequence = native
        opts.omit = omit
        let r1 = try model.design(residues, options: opts)
        XCTAssertEqual(r1.indices.count, L)

        // Fixed positions keep their native identity.
        for i in fixed {
            XCTAssertEqual(r1.indices[i], native[i],
                           "fixed position \(i) must remain native")
        }
        // Omitted AA never appears at a designed position.
        for i in free {
            XCTAssertNotEqual(r1.indices[i], 4, "CYS omitted but appeared at \(i)")
        }
        // Determinism: same inputs → identical result.
        let r2 = try model.design(residues, options: opts)
        XCTAssertEqual(r1.indices, r2.indices, "greedy + fixed seed must be reproducible")

        print("[DesignRegion] free \(Array(free).sorted()) → \(free.map { r1.indices[$0] })")
    }
}
#endif
