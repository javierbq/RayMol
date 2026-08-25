#if os(macOS)
import XCTest
@testable import RayMol

/// Turning a rollout frame into something PyMOL can hold as one state of an object.
///
/// The whole file is pure arithmetic on purpose: the live path cannot be reached from a
/// unit test (it needs a 672 MB pack and a real MLX rollout), so everything that CAN be
/// decided without one is decided here.
final class RFD3TrajectoryTests: XCTestCase {

    /// A synthetic flat [L, 3] array where atom i sits at (i, 0, 0), so any slicing
    /// mistake shows up as a wrong x.
    private func flat(atoms: Int) -> [Float] {
        (0 ..< atoms).flatMap { [Float($0), 0, 0] }
    }

    func testAFrameKeepsFiveAtomsPerDesignedResidue() {
        // The engine lays the designed chain out FIRST, 14 dense slots per residue, and
        // only N/CA/C/O/CB are real -- the same subset the final writer keeps.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14 * 6 + 40),
                                     length: 6, origin: SIMD3(0, 0, 0))
        XCTAssertEqual(f.count, 5 * 6)
    }

    func testAFrameTakesTheDesignedChainAndNotTheTarget() {
        // Residue r's slot s is at atom r*14 + s. Residue 1's CA (slot 1) is atom 15.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14 * 3 + 40),
                                     length: 3, origin: SIMD3(0, 0, 0))
        XCTAssertEqual(f[0].x, 0, accuracy: 1e-6)     // residue 0, N   -> atom 0
        XCTAssertEqual(f[1].x, 1, accuracy: 1e-6)     // residue 0, CA  -> atom 1
        XCTAssertEqual(f[5].x, 14, accuracy: 1e-6)    // residue 1, N   -> atom 14
        XCTAssertEqual(f[6].x, 15, accuracy: 1e-6)    // residue 1, CA  -> atom 15
    }

    func testTheOriginIsAddedSoAFrameLandsOnTheTarget() {
        // Coordinates arrive as `input - origin`; adding it back is what puts the frame
        // beside the structure it is being designed against instead of tens of A away.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14),
                                     length: 1, origin: SIMD3(10, -5, 2.5))
        XCTAssertEqual(f[0].x, 10, accuracy: 1e-6)
        XCTAssertEqual(f[0].y, -5, accuracy: 1e-6)
        XCTAssertEqual(f[0].z, 2.5, accuracy: 1e-6)
    }

    func testAShortArrayYieldsNoFrameRatherThanCrashing() {
        // A malformed frame must degrade to "no live view", never take the design down.
        XCTAssertTrue(RFD3Trajectory.frame(flat: [1, 2, 3], length: 6,
                                           origin: SIMD3(0, 0, 0)).isEmpty)
    }

    func testTheSeedPDBHasOneResidueOfFiveAtomsPerDesignedResidue() {
        let pdb = RFD3Trajectory.seedPDB(length: 4, chain: "B")
        let atoms = pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, 20)
        // Poly-ALA, and that is forced: states of one object share a single atom set, and
        // the sequence head's argmax churns during the rollout, so per-state residue names
        // are not representable.
        XCTAssertTrue(atoms.allSatisfy { $0.contains("ALA") })
        XCTAssertTrue(atoms.allSatisfy { $0.dropFirst(21).first == "B" })
    }

    func testTheCaptureIntervalGivesTheExpectedFrameCount() {
        // Every 4th step of 199, plus the last one so the trajectory ends where the design
        // does rather than three steps short.
        let kept = (1 ... 199).filter {
            RFD3Trajectory.shouldCapture(step: $0, interval: 4, total: 199)
        }
        XCTAssertEqual(kept.first, 4)
        XCTAssertEqual(kept.last, 199)
        XCTAssertEqual(kept.count, 50)
    }
}
#endif
