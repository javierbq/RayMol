#if os(macOS)
import XCTest
@testable import RayMol

/// ``RFD3ResultWriter`` is where four separate silent-wrong-answers are stopped, so it is
/// where most of this feature's logic-under-test lives. Every fixture below is built from
/// the engine's ACTUAL output conventions, verified by reading `RFD3Output.makePDB`:
///
/// * the designed chain's records come FIRST (designed tokens precede target tokens),
/// * there is one `TER` at the very end, not one per chain,
/// * both chains are renumbered 1..N,
/// * chain A's residue NAMES are the sequence head's argmax, not the input's,
/// * only N, CA, C, O and CB are emitted,
/// * and every coordinate is in a frame translated by an origin the API never exposes.
///
/// A fixture that got any of those wrong would let the writer's bug through, so they are
/// stated here rather than assumed.
final class RFD3ResultWriterTests: XCTestCase {

    /// The translation the engine applies. Arbitrary and deliberately large: a bug that
    /// forgets to undo it must be unmissable, not a rounding difference.
    private let origin = SIMD3<Double>(17.5, -42.25, 8.125)

    private func atom(_ name: String, _ x: Double, _ y: Double, _ z: Double)
        -> InferenceJob.DesignAtom
    {
        InferenceJob.DesignAtom(name: name, xyz: [x, y, z])
    }

    /// A target with FULL sidechains and its own numbering, including an insertion code --
    /// everything the engine's output throws away.
    /// `shift` moves the WHOLE input target along x. Not a deformation and not a
    /// different origin: it is what a target the user translated -- or one deposited far
    /// from the origin -- looks like, and it is the only way a coordinate the PDB cannot
    /// write reaches `compose`, because the target half is emitted verbatim.
    private func target(shift: Double = 0) -> [InferenceJob.DesignResidue] {
        let residues: [InferenceJob.DesignResidue] = [
            InferenceJob.DesignResidue(
                chain: "H", resi: "45", resn: "TRP",
                atoms: [atom("N", 1, 0, 0), atom("CA", 2, 0, 0), atom("C", 3, 0, 0),
                        atom("O", 3, 1, 0), atom("CB", 2, -1, 0),
                        // A sidechain atom the engine never emits. It must survive.
                        atom("CG", 2, -2, 0), atom("CD1", 2, -3, 0)]),
            InferenceJob.DesignResidue(
                chain: "H", resi: "45A", resn: "SER",
                atoms: [atom("N", 5, 0, 0), atom("CA", 6, 0, 0), atom("C", 7, 0, 0),
                        atom("O", 7, 1, 0), atom("CB", 6, -1, 0), atom("OG", 6, -2, 0)]),
            InferenceJob.DesignResidue(
                chain: "H", resi: "46", resn: "GLY",
                atoms: [atom("N", 9, 0, 0), atom("CA", 10, 0, 0), atom("C", 11, 0, 0),
                        atom("O", 11, 1, 0)]),
        ]
        guard shift != 0 else { return residues }
        return residues.map { residue in
            InferenceJob.DesignResidue(
                chain: residue.chain, resi: residue.resi, resn: residue.resn,
                atoms: residue.atoms.map {
                    InferenceJob.DesignAtom(name: $0.name,
                                            xyz: [$0.xyz[0] + shift, $0.xyz[1], $0.xyz[2]])
                })
        }
    }

    /// The engine's output for that target plus a 2-residue design, in the engine's frame.
    ///
    /// `rigidShift` displaces the WHOLE output (target and design together), which is what
    /// a different origin looks like and is absorbed by construction. `deform` moves one
    /// target atom only, which is what no translation can absorb and what the writer
    /// refuses.
    private func engineOutput(rigidShift: Double = 0, deform: Double = 0) -> String {
        var lines: [String] = []
        var serial = 1
        func record(_ name: String, _ resn: String, _ chain: String, _ number: Int,
                    _ xyz: SIMD3<Double>) {
            let padded = name.count >= 4 ? name
                : " " + name.padding(toLength: 3, withPad: " ", startingAt: 0)
            lines.append("ATOM  " + String(format: "%5d", serial) + " " + padded + " "
                         + resn + " " + chain + String(format: "%4d", number) + "    "
                         + String(format: "%8.3f%8.3f%8.3f", xyz.x, xyz.y, xyz.z)
                         + "  1.00  0.00          "
                         + String(name.first!))
            serial += 1
        }
        // DESIGNED CHAIN FIRST, as the engine writes it.
        for index in 0 ..< 2 {
            let base = SIMD3<Double>(Double(index) * 4 + 30, 5, 5) - origin
                + SIMD3(rigidShift, 0, 0)
            for (offset, name) in ["N", "CA", "C", "O", "CB"].enumerated() {
                record(name, "ALA", "B", index + 1,
                       base + SIMD3(Double(offset) * 0.5, 0, 0))
            }
        }
        // Then the target, renumbered 1..N, five atoms at most, and with residue names
        // that are the sequence head's argmax rather than the input's.
        for (index, residue) in target().enumerated() {
            for source in residue.atoms
            where RFD3ResultWriter.emittedAtomNames.contains(source.name) {
                // The deformation lands on ONE atom, so the mean offset barely moves and
                // the residual is essentially the whole displacement -- which is the
                // quantity the writer refuses on.
                let wobble = (index == 0 && source.name == "CA") ? deform : 0
                let xyz = SIMD3(source.xyz[0], source.xyz[1], source.xyz[2])
                    - origin + SIMD3(rigidShift + wobble, 0, 0)
                record(source.name, "LEU", "A", index + 1, xyz)
            }
        }
        lines.append("TER")
        lines.append("END")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `targetShift` moves the INPUT target only, leaving the engine's output where it
    /// was -- which is exactly what a target far from the session origin looks like from
    /// the engine's side, since the featurizer works in a frame translated by that very
    /// distance. The recovered offset absorbs it and the residual stays zero, so nothing
    /// upstream refuses first, and what lands out of range is the coordinates this type
    /// EMITS.
    private func compose(rigidShift: Double = 0, deform: Double = 0,
                         designLength: Int = 2,
                         designSequence: String = "GW",
                         targetShift: Double = 0) throws -> String {
        try RFD3ResultWriter.compose(
            target: target(shift: targetShift), designChain: "D",
            designLength: designLength,
            designSequence: designSequence,
            resultPDB: engineOutput(rigidShift: rigidShift, deform: deform),
            remarks: ["DESIGN KEY abc123"])
    }

    private struct Row {
        let name: String, resn: String, chain: String, resi: String
        let xyz: SIMD3<Double>
    }

    private func rows(_ pdb: String) -> [Row] {
        pdb.split(separator: "\n").compactMap { line -> Row? in
            guard line.hasPrefix("ATOM") else { return nil }
            let text = String(line)
            func slice(_ a: Int, _ b: Int) -> String {
                let i = text.index(text.startIndex, offsetBy: a)
                let j = text.index(text.startIndex, offsetBy: min(b, text.count))
                return String(text[i ..< j]).trimmingCharacters(in: .whitespaces)
            }
            guard let x = Double(slice(30, 38)), let y = Double(slice(38, 46)),
                  let z = Double(slice(46, 54)) else { return nil }
            return Row(name: slice(12, 16), resn: slice(17, 20), chain: slice(21, 22),
                       resi: slice(22, 27), xyz: SIMD3(x, y, z))
        }
    }

    // MARK: The four things Result.pdb gets wrong

    func testTheDesignedChainIsTranslatedBackIntoTheSessionFrame() throws {
        let out = try compose()
        let design = rows(out).filter { $0.chain == "D" }
        XCTAssertEqual(design.count, 10, "2 residues x 5 atoms")
        // The engine placed design residue 1's N at (30,5,5) - origin. Undoing the
        // translation must put it back at (30,5,5) -- in the frame the target lives in.
        let first = try XCTUnwrap(design.first { $0.resi == "1" && $0.name == "N" })
        XCTAssertEqual(first.xyz.x, 30, accuracy: 1e-3)
        XCTAssertEqual(first.xyz.y, 5, accuracy: 1e-3)
        XCTAssertEqual(first.xyz.z, 5, accuracy: 1e-3)
    }

    func testTheTargetIsEmittedVerbatim() throws {
        let out = try compose()
        let emitted = rows(out).filter { $0.chain == "H" }
        // Every atom, sidechains included -- 7 + 6 + 4, not the 5 + 5 + 4 the engine emits.
        XCTAssertEqual(emitted.count, 17)
        XCTAssertNotNil(emitted.first { $0.name == "CD1" },
                        "a sidechain atom the engine drops must survive")
        // Original coordinates, NOT the engine's translated copy.
        let ca = try XCTUnwrap(emitted.first { $0.resi == "45" && $0.name == "CA" })
        XCTAssertEqual(ca.xyz.x, 2, accuracy: 1e-3)
        // Original residue NAMES: the engine reported LEU for all three.
        XCTAssertEqual(Set(emitted.map(\.resn)), ["TRP", "SER", "GLY"])
        // Original numbering, insertion code included, not 1..N.
        XCTAssertEqual(Set(emitted.map(\.resi)), ["45", "45A", "46"])
    }

    func testTheInsertionCodeLandsInItsOwnColumn() throws {
        XCTAssertEqual(RFD3ResultWriter.splitResi("45A").number, "45")
        XCTAssertEqual(RFD3ResultWriter.splitResi("45A").insertionCode, "A")
        XCTAssertEqual(RFD3ResultWriter.splitResi("46").insertionCode, "")
        XCTAssertEqual(RFD3ResultWriter.splitResi("-3").number, "-3")
        // Column 27 exactly, or every reader mis-parses the residue number.
        let record = try XCTUnwrap(RFD3ResultWriter.atomRecord(
            serial: 1, name: "CA", resName: "SER", chain: "H", resi: "45A",
            xyz: SIMD3(1, 2, 3)))
        let index = record.index(record.startIndex, offsetBy: 26)
        XCTAssertEqual(record[index], "A")
    }

    // MARK: The PDB's fixed columns

    /// Columns 31-38, 39-46 and 47-54 of an ATOM record, as a reader takes them.
    private func coordinateColumns(_ record: String) -> (String, String, String) {
        let characters = Array(record)
        func field(_ start: Int) -> String {
            String(characters[(start - 1) ..< (start + 7)])
        }
        return (field(31), field(39), field(47))
    }

    func testACoordinateTooWideForItsColumnsIsRefusedRatherThanWritten() throws {
        // `%8.3f` has a width MINIMUM, not a width maximum: one character more and the
        // field widens, pushing every later field right. The line stays 80-ish columns of
        // plausible text, so nothing raises -- a reader simply takes eight characters
        // from column 39 and gets the spaces the overflow pushed there. Measured against
        // PyMOL: (-1000.0, 1.0, 2.0) written, (-1000.0, 0.0, 0.0) read back.
        //
        // Each component separately, because a guard that only checked x would pass a
        // test that only overflowed x.
        for bad in [SIMD3<Double>(-1000, 1, 2), SIMD3(1, -1000, 2), SIMD3(1, 2, -1000),
                    SIMD3(10000, 1, 2), SIMD3(1, 10000, 2), SIMD3(1, 2, 10000),
                    // Rounds UP to the nine-character 10000.000, so the bound has to be
                    // checked before the formatting, not after.
                    SIMD3(9999.9996, 1, 2),
                    SIMD3(.nan, 1, 2), SIMD3(1, .infinity, 2)] {
            XCTAssertNil(RFD3ResultWriter.atomRecord(
                serial: 1, name: "N", resName: "ALA", chain: "B", resi: "1", xyz: bad),
                "\(bad) is not representable in 8 columns and must be refused")
        }
    }

    func testAnIdentifierTooWideForItsColumnsIsRefusedRatherThanTruncated() throws {
        // The identifier columns fail DIFFERENTLY from the coordinate ones, and worse.
        // `%8.3f` overflows and pushes later fields right; `pad` keeps the SUFFIX, so the
        // line stays perfectly well-formed and simply names a different residue. Residue
        // 10000 is written as 0000; -1000 as 1000, changing sign as well as magnitude; a
        // two-character mmCIF chain `AA` as `A`, merging it with whatever else that letter
        // names.
        //
        // Nothing raises and nothing looks wrong. That makes this the exact silent
        // wrong-answer this type exists to prevent -- two of its four listed failure modes
        // are "the target's identity" and "the numbering the hotspot selection was written
        // in", and truncating either IS those failures rather than a workaround for them.
        for (chain, resi) in [("AA", "1"), ("ABC", "1"),
                              ("A", "10000"), ("A", "-1000"), ("A", "123456"),
                              // Two-character insertion code: column 27 holds one.
                              ("A", "45AB")] {
            XCTAssertNil(RFD3ResultWriter.atomRecord(
                serial: 1, name: "N", resName: "ALA", chain: chain, resi: resi,
                xyz: SIMD3(1, 2, 3)),
                "chain \"\(chain)\" residue \"\(resi)\" does not fit and must be refused")
            XCTAssertFalse(RFD3ResultWriter.isRepresentable(chain: chain, resi: resi))
        }

        // The widest that DO fit are still written -- an inclusive bound, like the
        // coordinate one, so the check refuses only what the format genuinely cannot hold.
        for (chain, resi) in [("A", "9999"), ("A", "-999"), ("A", "45A"), ("", "1")] {
            XCTAssertTrue(RFD3ResultWriter.isRepresentable(chain: chain, resi: resi))
            XCTAssertNotNil(RFD3ResultWriter.atomRecord(
                serial: 1, name: "N", resName: "ALA", chain: chain, resi: resi,
                xyz: SIMD3(1, 2, 3)))
        }
    }

    func testEmitRefusesAnUnwritableIdentifierWithItsOwnErrorNotTheCoordinateOne() throws {
        // Separate cases because they are FIXED differently: a coordinate out of range
        // means "move the target nearer the origin", an identifier that does not fit means
        // "renumber it, or pick a single-letter chain". Telling a user with a chain called
        // `AA` to move their structure sends them nowhere.
        let wideChain = [InferenceJob.DesignResidue(
            chain: "AA", resi: "1", resn: "GLY",
            atoms: [atom("N", 1, 0, 0), atom("CA", 2, 0, 0),
                    atom("C", 3, 0, 0), atom("O", 3, 1, 0)])]
        XCTAssertThrowsError(try RFD3ResultWriter.emit(
            target: wideChain, designChain: "D",
            designResidues: [[RFD3ResultWriter.Atom(name: "N", xyz: SIMD3(5, 0, 0)),
                              RFD3ResultWriter.Atom(name: "CA", xyz: SIMD3(6, 0, 0)),
                              RFD3ResultWriter.Atom(name: "C", xyz: SIMD3(7, 0, 0)),
                              RFD3ResultWriter.Atom(name: "O", xyz: SIMD3(7, 1, 0))]],
            designSequence: "G", remarks: [])) { error in
            guard case RFD3ResultWriter.ComposeError.identifierNotRepresentable(
                    let chain, let resi) = error else {
                return XCTFail("expected identifierNotRepresentable, got \(error)")
            }
            XCTAssertEqual(chain, "AA")
            XCTAssertEqual(resi, "1")
        }
    }

    func testTheExtremesThatDoFitAreStillWrittenAndStayInTheirColumns() throws {
        // The bounds are inclusive, and the point of stating them exactly is that the
        // widest values the format CAN hold are not thrown away with the ones it cannot.
        let extreme = SIMD3<Double>(-999.999, 9999.999, -999.999)
        let record = try XCTUnwrap(RFD3ResultWriter.atomRecord(
            serial: 1, name: "CA", resName: "ALA", chain: "B", resi: "1", xyz: extreme))
        let (x, y, z) = coordinateColumns(record)
        XCTAssertEqual(x, "-999.999")
        XCTAssertEqual(y, "9999.999")
        XCTAssertEqual(z, "-999.999")
        // And the fields after them are untouched -- occupancy at columns 55-60.
        let characters = Array(record)
        XCTAssertEqual(String(characters[54 ..< 60]), "  1.00")
    }

    func testAResultWithAnUnwritableCoordinateIsRefusedNotHalfWritten() {
        // The trajectory degrades to "no live view"; a RESULT does not get that option.
        // A design silently placed at coordinates it was not built at is worse than a
        // design that failed with a message saying why.
        XCTAssertThrowsError(try compose(targetShift: 12000)) { error in
            guard case RFD3ResultWriter.ComposeError.coordinateOutOfRange = error else {
                return XCTFail("expected .coordinateOutOfRange, got \(error)")
            }
            XCTAssertTrue("\(error)".contains("eight-column"), "\(error)")
        }
    }

    func testATargetFarFromTheOriginButStillWritableComposes() throws {
        // The positive control for the refusal above: the same fixture, shifted to just
        // inside the range instead of past it. Without this, a guard that refused
        // EVERYTHING would pass the test above.
        let out = try compose(targetShift: 900)
        let emitted = rows(out).filter { $0.chain == "H" }
        XCTAssertEqual(emitted.count, 17)
        let first = try XCTUnwrap(emitted.first { $0.resi == "45" && $0.name == "N" })
        XCTAssertEqual(first.xyz.x, 901, accuracy: 1e-3)
    }

    func testTheDesignedChainIsNamedFromTheSequenceNotThePDB() throws {
        // The engine's fixture says ALA for both designed residues; the public
        // `binderSequence` says G then W. The sequence is the documented output.
        let out = try compose(designSequence: "GW")
        let design = rows(out).filter { $0.chain == "D" }
        XCTAssertEqual(design.first { $0.resi == "1" }?.resn, "GLY")
        XCTAssertEqual(design.first { $0.resi == "2" }?.resn, "TRP")
    }

    // MARK: Refusals

    func testADeformedTargetIsRefusedRatherThanEmitted() {
        // The emitted target is the ORIGINAL coordinates, so if the model changed the
        // target's shape the design was built against something else. Refused, not rounded.
        XCTAssertThrowsError(try compose(deform: 2.0)) { error in
            guard case RFD3ResultWriter.ComposeError.targetDeformed(let by, _) = error
            else {
                return XCTFail("expected .targetDeformed, got \(error)")
            }
            // One atom of seventeen matched, so the mean absorbs ~1/14 of it.
            XCTAssertGreaterThan(by, 1.5)
        }
    }

    func testDeformationWithinToleranceStillComposes() throws {
        // Float32 accumulation over 200 steps is not a deformed target. The tolerance
        // exists for that, and the measured value in every benchmark is 0.000.
        let out = try compose(deform: RFD3ResultWriter.driftToleranceAngstrom / 2)
        XCTAssertFalse(rows(out).filter { $0.chain == "D" }.isEmpty)
    }

    func testARigidShiftOfTheWholeOutputIsAbsorbedWithThePoseIntact() throws {
        // A rigid shift is what a DIFFERENT ORIGIN looks like, and undoing it is this
        // type's entire job -- so it must not be refused, and the design must land in the
        // same place as it would without one. Pinned because it looks like drift and is
        // not: the property being asserted is that a translation carries the design with
        // the target rather than leaving them inconsistent.
        //
        // A rigid shift the ENGINE did not intend -- the target genuinely moving as a
        // block -- is caught by RFD3JobManager against Stats.targetDriftMaxA instead. This
        // layer cannot see one and does not need to.
        let baseline = rows(try compose())
        let shifted = rows(try compose(rigidShift: 137.5))
        XCTAssertEqual(baseline.count, shifted.count)
        for (lhs, rhs) in zip(baseline, shifted) {
            XCTAssertEqual(lhs.name, rhs.name)
            XCTAssertEqual(lhs.resi, rhs.resi)
            XCTAssertEqual(lhs.xyz.x, rhs.xyz.x, accuracy: 1e-3)
            XCTAssertEqual(lhs.xyz.y, rhs.xyz.y, accuracy: 1e-3)
            XCTAssertEqual(lhs.xyz.z, rhs.xyz.z, accuracy: 1e-3)
        }
    }

    func testAShortDesignIsRefusedRatherThanTruncated() {
        XCTAssertThrowsError(try compose(designLength: 3)) { error in
            guard case RFD3ResultWriter.ComposeError.designLengthMismatch(
                let expected, let found) = error else {
                return XCTFail("expected .designLengthMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(found, 2)
        }
    }

    func testOutputWithNoTargetChainIsRefused() {
        XCTAssertThrowsError(
            try RFD3ResultWriter.compose(
                target: target(), designChain: "D", designLength: 1,
                designSequence: "A",
                resultPDB: "ATOM      1  N   ALA B   1       0.000   0.000   0.000\nEND\n",
                remarks: [])
        ) { error in
            guard case RFD3ResultWriter.ComposeError.noTargetAtoms = error else {
                return XCTFail("expected .noTargetAtoms, got \(error)")
            }
        }
    }

    func testEveryComposeErrorSaysSomethingUseful() {
        // These reach the user as a failed job's message, so an empty or generic one is a
        // seventeen-minute run that produced nothing and explained nothing.
        let errors: [RFD3ResultWriter.ComposeError] = [
            .noTargetAtoms, .noDesignAtoms(expected: 60),
            .designLengthMismatch(expected: 60, found: 59), .unmatchedTargetAtoms,
            .targetDeformed(byAngstrom: 3.5, tolerance: 0.25),
        ]
        for error in errors {
            XCTAssertGreaterThan(error.description.count, 40, "\(error)")
            XCTAssertEqual((error as Error).localizedDescription, error.description)
        }
    }

    // MARK: Provenance

    func testTheDesignKeyTravelsInTheFile() throws {
        let out = try compose()
        XCTAssertTrue(out.contains("REMARK 300 DESIGN KEY abc123"), out.prefix(400).description)
    }

    func testTheFileEndsWithATerminatorAndEND() throws {
        let out = try compose()
        let lines = out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, "END")
        XCTAssertEqual(lines.filter { $0.hasPrefix("TER") }.count, 2,
                       "one TER per chain, unlike the engine's single trailing one")
    }

    // MARK: One emitter, so the live seed and the result are the same atoms

    /// The frame a rollout would produce for this fixture's 2-residue design, in the
    /// order `RFD3Trajectory.frame` returns it.
    private func liveFrame() -> [SIMD3<Double>] {
        (0 ..< 10).map { SIMD3(Double($0) * 1.5, 60, -20) }
    }

    func testTheLiveSeedIsTheSameAtomsInTheSameOrderAsTheResult() throws {
        // THE contract this refactor exists for. A live run seeds its object from
        // `RFD3Trajectory.seed` and, when the design lands, appends the result's
        // coordinates to that same object with `load_coordset` -- which matches
        // coordinates to atoms BY POSITION and checks nothing. If the two ever emitted a
        // different atom order, every atom of the finished design would be silently
        // placed on a different atom, and nothing anywhere would say so.
        //
        // They cannot, because there is one emitter. This is the assertion that keeps it
        // that way: identity (name, chain, residue number) atom by atom, over the whole
        // object rather than over the generated chain, because the target is half of it.
        let seed = try XCTUnwrap(RFD3Trajectory.seed(target: target(), length: 2,
                                                     chain: "D", coords: liveFrame()))
        let result = rows(try compose())
        let live = rows(seed.pdb)
        XCTAssertEqual(live.count, result.count)
        XCTAssertEqual(live.count, 27, "17 target atoms + 2 residues x 5")
        for (index, (a, b)) in zip(live, result).enumerated() {
            XCTAssertEqual(a.name, b.name, "atom \(index) name")
            XCTAssertEqual(a.chain, b.chain, "atom \(index) chain")
            XCTAssertEqual(a.resi, b.resi, "atom \(index) resi")
        }
    }

    func testTheLiveSeedCarriesTheTargetAtItsRealCoordinates() throws {
        // The seed is not the generated chain alone any more. The target has to be in it,
        // verbatim, or the object the user watches is not the object the design lands in
        // -- and the first thing they would see is the target vanishing.
        let seed = try XCTUnwrap(RFD3Trajectory.seed(target: target(), length: 2,
                                                     chain: "D", coords: liveFrame()))
        let live = rows(seed.pdb)
        let composed = rows(try compose())
        for index in 0 ..< seed.targetAtomCount {
            XCTAssertEqual(live[index].xyz.x, composed[index].xyz.x, accuracy: 1e-3)
            XCTAssertEqual(live[index].xyz.y, composed[index].xyz.y, accuracy: 1e-3)
            XCTAssertEqual(live[index].xyz.z, composed[index].xyz.z, accuracy: 1e-3)
            XCTAssertEqual(live[index].resn, composed[index].resn)
        }
    }

    func testOnlyTheGeneratedChainDiffersBetweenTheSeedAndTheResult() throws {
        // What the seed does NOT have: the answer. Its generated chain carries a rollout
        // frame under poly-ALA names, and the delivered result carries the real
        // coordinates under the real sequence. Both differences are expected and both are
        // repaired at delivery -- the coordinates by appending a state, the names by
        // renaming the chain once.
        let seed = try XCTUnwrap(RFD3Trajectory.seed(target: target(), length: 2,
                                                     chain: "D", coords: liveFrame()))
        let live = rows(seed.pdb)
        let composed = rows(try compose(designSequence: "GW"))
        for index in seed.targetAtomCount ..< live.count {
            XCTAssertEqual(live[index].resn, "ALA", "the seed's names must be poly-ALA")
        }
        XCTAssertEqual(composed[seed.targetAtomCount].resn, "GLY")
        XCTAssertEqual(composed[live.count - 1].resn, "TRP")
    }

    func testTheEmittedLayoutIsTheLayoutTheRecordsActuallyHave() throws {
        // The numbers the seed hands Python are the emitter's own account of what it
        // wrote. If they were counted anywhere else they could disagree with the string,
        // and the frame path would splice into the wrong slice for the whole run.
        let seed = try XCTUnwrap(RFD3Trajectory.seed(target: target(), length: 2,
                                                     chain: "D", coords: liveFrame()))
        XCTAssertEqual(seed.targetAtomCount, 17)
        XCTAssertEqual(seed.designAtomCount, 10)
        XCTAssertEqual(seed.designFirstSerial,
                       RFD3ResultWriter.designFirstSerial(target: target()))
        let atoms = seed.pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, seed.targetAtomCount + seed.designAtomCount)
        // The record at that serial really is the generated chain's first atom.
        func serial(_ line: Substring) -> Int {
            Int(String(line.dropFirst(6).prefix(5)).trimmingCharacters(in: .whitespaces))
                ?? -1
        }
        XCTAssertEqual(serial(atoms[seed.targetAtomCount]), seed.designFirstSerial)
        XCTAssertEqual(rows(seed.pdb)[seed.targetAtomCount].chain, "D")
    }

    func testAnUnwritableTargetLeavesNoSeedRatherThanAMisColumnedOne() throws {
        // `emit` throws on a coordinate the PDB's eight columns cannot hold, and the
        // result path lets that fail the design. The LIVE path may not: it degrades to
        // no live view, which is why `seed` returns an optional rather than propagating.
        XCTAssertNil(RFD3Trajectory.seed(target: target(shift: 12000), length: 2,
                                         chain: "D", coords: liveFrame()))
    }
}
#endif
