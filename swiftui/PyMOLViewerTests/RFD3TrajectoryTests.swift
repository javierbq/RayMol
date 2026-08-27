#if os(macOS)
import XCTest
@testable import RayMol

/// Turning a rollout frame into something PyMOL can hold as one state of an object.
///
/// The whole file is pure arithmetic on purpose: the live path cannot be reached from a
/// unit test (it needs a 672 MB pack and a real MLX rollout), so everything that CAN be
/// decided without one is decided here.
final class RFD3TrajectoryTests: XCTestCase {

    /// A synthetic flat [L, 3] array where atom i sits at (i, i + 0.5, i + 0.25).
    ///
    /// All three components differ, and differ from each other, on purpose: with the
    /// y and z of every atom held at 0 a transposition of the two — reading `base + 2`
    /// as y and `base + 1` as z — passed every assertion in this file.
    private func flat(atoms: Int) -> [Float] {
        (0 ..< atoms).flatMap { [Float($0), Float($0) + 0.5, Float($0) + 0.25] }
    }

    /// One entry per emitted slot, distinct in all three components, in the order
    /// `frame(flat:length:origin:)` returns and `seed` consumes.
    private func seedCoords(length: Int) -> [SIMD3<Double>] {
        (0 ..< length * RFD3Trajectory.emittedSlots.count).map {
            SIMD3(Double($0), Double($0) + 0.5, Double($0) + 0.25)
        }
    }

    /// A target as the wire carries one: `residues` residues of `atomsEach` atoms, far
    /// enough from the generated chain's fixture coordinates to tell the two apart in a
    /// written record.
    private func target(residues: Int,
                        atomsEach: Int = 4) -> [InferenceJob.DesignResidue] {
        let names = ["N", "CA", "C", "O", "CB"]
        return (0 ..< residues).map { residue in
            InferenceJob.DesignResidue(
                chain: "A", resi: String(residue + 41), resn: "GLY",
                atoms: (0 ..< atomsEach).map { slot in
                    InferenceJob.DesignAtom(
                        name: names[slot % names.count],
                        xyz: [-100 - Double(residue), Double(slot), 50])
                })
        }
    }

    /// The seed's PDB text for a DESIGN-ONLY object -- no target -- which is what most
    /// of the assertions below are about. `seed` returns nil on refusal, and a test that
    /// wants the refusal asserts on that instead.
    private func seedPDB(length: Int, chain: String,
                         coords: [SIMD3<Double>]) -> String {
        RFD3Trajectory.seed(target: [], length: length, chain: chain,
                            coords: coords)?.pdb ?? ""
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
        // y and z of the same atom, so a transposition of the two is a failure rather
        // than three zeros agreeing with three zeros.
        XCTAssertEqual(f[6].y, 15.5, accuracy: 1e-6)
        XCTAssertEqual(f[6].z, 15.25, accuracy: 1e-6)
    }

    func testTheOriginIsAddedSoAFrameLandsOnTheTarget() {
        // Coordinates arrive as `input - origin`; adding it back is what puts the frame
        // beside the structure it is being designed against instead of tens of A away.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14),
                                     length: 1, origin: SIMD3(10, -5, 2.5))
        // Atom 0 of the fixture is (0, 0.5, 0.25).
        XCTAssertEqual(f[0].x, 10, accuracy: 1e-6)
        XCTAssertEqual(f[0].y, -4.5, accuracy: 1e-6)
        XCTAssertEqual(f[0].z, 2.75, accuracy: 1e-6)
    }

    func testAShortArrayYieldsNoFrameRatherThanCrashing() {
        // A malformed frame must degrade to "no live view", never take the design down.
        XCTAssertTrue(RFD3Trajectory.frame(flat: [1, 2, 3], length: 6,
                                           origin: SIMD3(0, 0, 0)).isEmpty)
    }

    func testTheSeedPDBHasOneResidueOfFiveAtomsPerDesignedResidue() {
        let pdb = seedPDB(length: 4, chain: "B",
                                         coords: seedCoords(length: 4))
        let atoms = pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, 20)
        // Poly-ALA, and that is forced: states of one object share a single atom set, and
        // the sequence head's argmax churns during the rollout, so per-state residue names
        // are not representable.
        XCTAssertTrue(atoms.allSatisfy { $0.contains("ALA") })
        XCTAssertTrue(atoms.allSatisfy { $0.dropFirst(21).first == "B" })
    }

    func testTheSeedCarriesTheFirstFramesRealCoordinates() {
        // The whole point of the seed. PyMOL infers bonds ONCE, at read time, from the
        // coordinates in this string; load_coordset never re-bonds. A seed of coincident
        // atoms refuses every bond permanently, so the object renders as unbonded crosses
        // with no backbone for its entire life — measured, 0 bonds vs 119 from a seed
        // carrying real coordinates for a 24-residue design.
        let pdb = seedPDB(length: 2, chain: "B",
                                         coords: seedCoords(length: 2))
        let atoms = pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, 10)
        XCTAssertFalse(pdb.contains("   0.000   0.000   0.000"),
                       "the seed must not be a block of origin atoms")
        // Atom 0 is (0, 0.5, 0.25) and atom 6 (residue 1, CA) is (6, 6.5, 6.25), in the
        // PDB's 8.3f columns — which also pins the residue-major slot order.
        XCTAssertTrue(atoms[0].contains("   0.000   0.500   0.250"), String(atoms[0]))
        XCTAssertTrue(atoms[6].contains("   6.000   6.500   6.250"), String(atoms[6]))
    }

    func testTheSeedStatesItsBondsInsteadOfLeavingThemToBeInferred() {
        // Connectivity is decided ONCE, at read time, from the FIRST captured frame --
        // step 4 of 199, which px0 makes protein-scale but not a settled backbone. What
        // distance inference makes of it is a function of how unsettled it happens to be:
        // measured on a 24-residue chain needing 119 bonds, seeded without CONECT, 89 / 54
        // / 37 bonds at 1 / 2 / 3 A of per-atom jitter and 5 from a protein-scale cloud.
        // Whatever it decides is then the object's connectivity for life, including the
        // converged state the user scrubs to and into any saved session. The CONECT
        // records make the answer 119 regardless -- and 119, not 238, from settled
        // geometry, because PyMOL merges them with what it would have inferred.
        //
        // With a TARGET in front of it, which is what production seeds: the generated
        // chain no longer starts at serial 1, so a record naming serial 1 would bond two
        // atoms of the TARGET to each other.
        let seed = XCTUnwrap2(RFD3Trajectory.seed(target: target(residues: 3), length: 4,
                                                  chain: "B",
                                                  coords: seedCoords(length: 4)))
        let pdb = seed.pdb
        let conect = pdb.split(separator: "\n").filter { $0.hasPrefix("CONECT") }
            .map(String.init)
        // 4 within each residue (N-CA, CA-C, C-O, CA-CB) + 3 peptide bonds.
        XCTAssertEqual(conect.count, 4 * 4 + 3)
        // 12 target atoms, then a TER, so the generated chain starts at serial 14.
        XCTAssertEqual(seed.designFirstSerial, 14)
        let first = seed.designFirstSerial
        // Residue 0 is `first ..< first + 5` in emittedSlots order, so N-CA is 14-15 and
        // CA-CB is 15-18; the peptide bond joins residue 0's C (16) to residue 1's N (19).
        func record(_ a: Int, _ b: Int) -> String {
            String(format: "CONECT%5d%5d", a, b)
        }
        XCTAssertTrue(conect.contains(record(first, first + 1)),
                      conect.joined(separator: "|"))
        XCTAssertTrue(conect.contains(record(first + 1, first + 4)),
                      conect.joined(separator: "|"))
        XCTAssertTrue(conect.contains(record(first + 2, first + 5)),
                      conect.joined(separator: "|"))
        // And nothing pointing into the target.
        XCTAssertFalse(conect.contains(record(1, 2)), conect.joined(separator: "|"))
        // After the chain terminator and before END, where a PDB reader expects them.
        let lines = pdb.split(separator: "\n")
        XCTAssertLessThan(lines.firstIndex(where: { $0.hasPrefix("TER") }) ?? .max,
                          lines.firstIndex(where: { $0.hasPrefix("CONECT") }) ?? 0)
        XCTAssertEqual(lines.last, "END")
    }

    func testAOneResidueSeedHasNoPeptideBondToInvent() {
        let conect = RFD3Trajectory.conectRecords(length: 1, firstSerial: 1)
        XCTAssertEqual(conect.count, 4)
        XCTAssertTrue(RFD3Trajectory.conectRecords(length: 0, firstSerial: 1).isEmpty)
    }

    func testASeedWithTheWrongCoordinateCountIsRefused() {
        // Degrades to "no live view" (an empty string the caller skips) rather than to a
        // half-filled object that every later frame would then fail the atom-count guard
        // against.
        XCTAssertTrue(seedPDB(length: 4, chain: "B", coords: []).isEmpty)
        XCTAssertTrue(seedPDB(length: 4, chain: "B",
                                             coords: seedCoords(length: 3)).isEmpty)
        XCTAssertTrue(seedPDB(length: 0, chain: "B", coords: []).isEmpty)
    }

    func testTheSeedAcceptsExactlyWhatAFrameProduces() {
        // The first captured frame becomes state 1, so what `frame` returns has to be
        // what `seedPDB` takes -- same count, same order. A skew between the two is the
        // difference between a seeded trajectory and no live view at all, and it would
        // not show up anywhere else without a 672 MB pack and a real rollout.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14 * 6 + 40), length: 6,
                                     origin: SIMD3(1, 2, 3))
        let pdb = seedPDB(length: 6, chain: "B", coords: f)
        XCTAssertFalse(pdb.isEmpty, "seedPDB rejected a frame that frame() produced")
        XCTAssertEqual(pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }.count,
                       30)
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

    func testTheSeedStatementNamesTheResultObjectAndItsLayout() {
        // The live object IS the result object -- no `_traj` suffix, no second object --
        // and the statement carries the layout the frame path needs to splice into it.
        let seed = RFD3Trajectory.seed(target: target(residues: 3), length: 2,
                                       chain: "B", coords: seedCoords(length: 2))
        let source = RFD3JobManager.seedPython(name: "rfd3_design_ab12cd34",
                                               seed: XCTUnwrap2(seed),
                                               receiptPath: "/tmp/r.seed")
        XCTAssertTrue(source.contains("'rfd3_design_ab12cd34'"), source)
        XCTAssertFalse(source.contains("_traj"), source)
        // 12 target atoms before the generated chain, 10 atoms in it.
        XCTAssertTrue(source.contains(", 12, 10)"), source)
    }

    func testTheSeedStatementReportsWhetherPythonAcceptedIt() {
        // `PyMOLEngine.runPython` returns Void -- the bridge is one-directional -- so the
        // only way the rollout can learn that the seed was REFUSED is for the statement to
        // write the answer somewhere. Without it, 49 more frames go through the main
        // thread at ~7 KB of source each, into a recording that does not exist.
        let seed = XCTUnwrap2(RFD3Trajectory.seed(target: target(residues: 3), length: 2,
                                                  chain: "B",
                                                  coords: seedCoords(length: 2)))
        let source = RFD3JobManager.seedPython(name: "d", seed: seed,
                                               receiptPath: "/tmp/x.seed")
        XCTAssertTrue(source.contains("_ok = _d.trajectory_seed("), source)
        XCTAssertTrue(source.contains("open('/tmp/x.seed', 'w')"), source)
        XCTAssertTrue(source.contains("'1' if _ok else '0'"), source)
    }

    /// `XCTUnwrap` throws, and these tests are not `throws`. One helper rather than a
    /// `try!` per call site.
    private func XCTUnwrap2<T>(_ value: T?,
                               file: StaticString = #filePath,
                               line: UInt = #line) -> T {
        guard let value else {
            XCTFail("expected a value", file: file, line: line)
            fatalError("unreachable")
        }
        return value
    }

    func testTheFrameStatementImportsAndEscapesTheName() {
        // runPython lands in a __main__ that is EMPTY in this embedding, so a bare
        // designing.trajectory_frame(...) is a silent NameError -- the same trap the tray's
        // Cancel button hit.
        let source = RFD3JobManager.framePython(name: "it's_a_traj",
                                                coords: [SIMD3(1, 2, 3)])
        XCTAssertTrue(source.contains("from pymol import designing as _d"), source)
        XCTAssertTrue(source.contains("'it\\'s_a_traj'"), source)
        XCTAssertTrue(source.contains("1.000"), source)
    }

    func testAFrameStatementIsFlatAndThreePerAtom() {
        let source = RFD3JobManager.framePython(
            name: "t", coords: [SIMD3(1, 2, 3), SIMD3(4, 5, 6)])
        // Flat, because trajectory_frame takes a flat list and reshapes -- one list of six
        // is cheaper to parse than two lists of three.
        XCTAssertTrue(source.contains("[1.000,2.000,3.000,4.000,5.000,6.000]"), source)
    }

    func testTheDefaultFrameCountIsAConstantNotALiteral() {
        XCTAssertEqual(RFD3JobManager.defaultTrajectoryFrames, 50)
        // And it still produces exactly what the old fixed interval of 4 did at the
        // default schedule, which is what makes this a refactor of the default rather
        // than a change to it.
        XCTAssertEqual(RFD3Trajectory.captureInterval(frames: 50, total: 199), 4)
        XCTAssertEqual(RFD3Trajectory.frameCount(interval: 4, total: 199), 50)
    }

    // MARK: live_steps — a frame COUNT, turned into an interval in one place

    /// What the rollout would actually capture at `interval`, counted by replaying
    /// `shouldCapture` rather than by trusting `frameCount`.
    private func captured(interval: Int, total: Int) -> [Int] {
        (1 ... total).filter {
            RFD3Trajectory.shouldCapture(step: $0, interval: interval, total: total)
        }
    }

    func testFrameCountAgreesWithWhatShouldCaptureActuallyYields() {
        // `frameCount` is arithmetic and `shouldCapture` is the rule. If they disagreed,
        // every derived interval would be off and nothing else here would notice.
        for total in [199, 99, 60, 19, 5, 1] {
            for interval in 1 ... total {
                XCTAssertEqual(RFD3Trajectory.frameCount(interval: interval, total: total),
                               captured(interval: interval, total: total).count,
                               "interval \(interval) over \(total)")
            }
        }
    }

    func testTheDerivedIntervalYieldsTheRequestedNumberOfFrames() {
        // Including 1, counts that divide evenly, and counts that cannot land exactly.
        // 199 steps admits 199, 100, 67, 50, 40, 34, ... so 7 is reachable (interval 29)
        // while `round(199/7)` = 28 would give 8 — which is why the derivation scans.
        let total = 199
        for wanted in [1, 2, 4, 7, 10, 12, 25, 40, 50, 67, 100, 199] {
            let interval = RFD3Trajectory.captureInterval(frames: wanted, total: total)
            XCTAssertEqual(captured(interval: interval, total: total).count, wanted,
                           "asked \(wanted), interval \(interval)")
        }
    }

    func testAnUnreachableCountLandsOnTheNEARESTAchievableOne() {
        // The counts are quantised, so exactness is often impossible. Nearest, not
        // nearest-below: asked 99 of 199, "at most" would give 67 and this gives 100.
        let total = 199
        let interval = RFD3Trajectory.captureInterval(frames: 99, total: total)
        XCTAssertEqual(captured(interval: interval, total: total).count, 100)
        // And it is genuinely the nearest — no interval does better.
        for candidate in 1 ... total {
            let count = RFD3Trajectory.frameCount(interval: candidate, total: total)
            XCTAssertGreaterThanOrEqual(abs(count - 99), abs(100 - 99),
                                        "interval \(candidate) gave \(count)")
        }
    }

    func testTheFinalRolloutStepIsAlwaysCaptured() {
        // At every count, at every schedule: the recording must end where the design
        // does, not up to `interval - 1` steps short of it.
        for total in [199, 99, 60, 19, 5, 1] {
            for wanted in [1, 3, 7, 12, 50, total] where wanted <= total {
                let interval = RFD3Trajectory.captureInterval(frames: wanted, total: total)
                XCTAssertTrue(
                    RFD3Trajectory.shouldCapture(step: total, interval: interval,
                                                 total: total),
                    "wanted \(wanted) of \(total) -> interval \(interval)")
            }
        }
    }

    func testAskingForEveryStepGivesEveryStep() {
        let interval = RFD3Trajectory.captureInterval(frames: 199, total: 199)
        XCTAssertEqual(interval, 1)
        XCTAssertEqual(captured(interval: interval, total: 199).count, 199)
    }

    func testTheDerivationIsSafeAtTheEdges() {
        // Python refuses these before a job exists; this is belt and braces, because the
        // one thing the derivation may not do is return 0 and make `shouldCapture` refuse
        // every step for the whole run.
        for frames in [0, -1, 1_000_000] {
            for total in [199, 1] {
                let interval = RFD3Trajectory.captureInterval(frames: frames, total: total)
                XCTAssertGreaterThanOrEqual(interval, 1, "frames \(frames)")
                XCTAssertFalse(captured(interval: interval, total: total).isEmpty)
            }
        }
        XCTAssertGreaterThanOrEqual(RFD3Trajectory.captureInterval(frames: 5, total: 0), 1)
    }

    func testSeedPythonPreservesNewlinesInThePDBPayload() {
        // pythonLiteral deletes newlines (single-line token contract). seedPython must
        // use pythonMultilineLiteral so PyMOL's line-oriented PDB reader sees record
        // separators and can parse more than the first atom.
        let seed = XCTUnwrap2(RFD3Trajectory.seed(target: [], length: 2, chain: "B",
                                                  coords: seedCoords(length: 2)))
        // The PDB has multiple ATOM records separated by real newlines.
        XCTAssertTrue(seed.pdb.contains("\n"), "the seed must be a multi-line string")
        let source = RFD3JobManager.seedPython(name: "traj", seed: seed,
                                               receiptPath: "/tmp/t.seed")
        // The two-character escape sequence must be in the source, not a joined line.
        XCTAssertTrue(source.contains("\\n"), source)
        // Each ATOM record's newline must survive as a \n escape: the buggy pythonLiteral
        // path deletes them, so the joined line has the same ATOM count but zero \n
        // escapes -- that is what this assertion separates.
        let atomCount = source.components(separatedBy: "ATOM").count - 1
        let escapedNewlines = source.components(separatedBy: "\\n").count - 1
        XCTAssertGreaterThanOrEqual(escapedNewlines, atomCount,
            "each ATOM record separator must appear as \\n in the Python source")
    }

    // MARK: The guard and the formatter agree about what can be written

    func testAFrameIsDroppedWhenACoordinateCannotBeWrittenInEightColumns() {
        // The guard used to admit anything under 1e6 while the PDB writer downstream of it
        // could only represent -999.999...9999.999 -- so a value in between was accepted
        // here and then written NINE characters wide, shifting every later field on the
        // line. Measured against PyMOL: (-1000.0, 1.0, 2.0) in, (-1000.0, 0.0, 0.0) out.
        //
        // Whole frame, not one atom: half a frame would misplace atoms rather than skip
        // them, and the object's atom count would stop matching.
        for (component, value) in [(0, -1000.0), (1, -1000.0), (2, -1000.0),
                                   (0, 10000.0), (1, 10000.0), (2, 10000.0)] {
            var raw = flat(atoms: 14)
            raw[component] = Float(value)
            XCTAssertTrue(
                RFD3Trajectory.frame(flat: raw, length: 1, origin: SIMD3(0, 0, 0)).isEmpty,
                "component \(component) at \(value) must drop the frame")
        }
        // The origin is added BEFORE the check, so a frame that is fine on its own and
        // lands out of range once placed beside the target is caught too.
        XCTAssertTrue(RFD3Trajectory.frame(flat: flat(atoms: 14), length: 1,
                                           origin: SIMD3(-1000, 0, 0)).isEmpty)
    }

    func testAFrameAtTheWritableExtremeIsStillKept() {
        // The positive control. A guard that dropped everything would pass the test above,
        // and dropping legitimate frames is the failure mode the user actually notices --
        // a live view that never appears.
        //
        // Just inside the bound rather than exactly on it, on purpose: these arrive as
        // Float32, whose spacing near 1000 is ~6e-5, so a value written as the exact
        // bound can land a hair outside it once rounded. Conservative in the safe
        // direction, but not something to hang a test on.
        let raw: [Float] = [-999.9, 9999.9, -999.9]
            + [Float](repeating: 0, count: (14 - 1) * 3)
        let f = RFD3Trajectory.frame(flat: raw, length: 1, origin: SIMD3(0, 0, 0))
        XCTAssertEqual(f.count, 5)
        XCTAssertEqual(f[0].x, -999.9, accuracy: 1e-2)
        XCTAssertEqual(f[0].y, 9999.9, accuracy: 1e-2)
    }

    func testASeedIsRefusedRatherThanWrittenWithShiftedColumns() {
        // `frame` already rejects these, so this is the writer's own belt-and-braces: a
        // caller passing coordinates it did not get from `frame` still gets "no live
        // view" rather than an object whose y and z were silently read as zero.
        var coords = seedCoords(length: 2)
        coords[3] = SIMD3(-1000, 1, 2)
        XCTAssertTrue(seedPDB(length: 2, chain: "B", coords: coords)
                        .isEmpty)
    }

    func testEverySeedRecordKeepsItsCoordinatesInTheirOwnColumns() {
        // The structural invariant, asserted on the whole seed rather than one record:
        // columns 31-38, 39-46 and 47-54 must each parse as the number that was written.
        let coords = seedCoords(length: 3)
        let pdb = seedPDB(length: 3, chain: "B", coords: coords)
        let atoms = pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, 15)
        for (index, line) in atoms.enumerated() {
            let characters = Array(line)
            func field(_ start: Int) -> Double? {
                Double(String(characters[(start - 1) ..< (start + 7)])
                    .trimmingCharacters(in: .whitespaces))
            }
            XCTAssertEqual(field(31) ?? .nan, coords[index].x, accuracy: 1e-3, String(line))
            XCTAssertEqual(field(39) ?? .nan, coords[index].y, accuracy: 1e-3, String(line))
            XCTAssertEqual(field(47) ?? .nan, coords[index].z, accuracy: 1e-3, String(line))
        }
    }

    func testANonFiniteCoordinateYieldsNoFrameRatherThanCrashing() {
        // NaN from the rollout would produce bare `nan` in the Python source -- an
        // undefined name. The frame must degrade to empty before reaching framePython.
        var rawNaN = flat(atoms: 14)
        rawNaN[1] = Float.nan   // Y component of atom 0 (slot N of residue 0)
        let f = RFD3Trajectory.frame(flat: rawNaN, length: 1, origin: SIMD3(0, 0, 0))
        XCTAssertTrue(f.isEmpty)
    }
}
#endif
