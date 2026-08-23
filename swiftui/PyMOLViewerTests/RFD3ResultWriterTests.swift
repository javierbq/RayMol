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
    private func target() -> [InferenceJob.DesignResidue] {
        [
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

    private func compose(rigidShift: Double = 0, deform: Double = 0,
                         designLength: Int = 2,
                         designSequence: String = "GW") throws -> String {
        try RFD3ResultWriter.compose(
            target: target(), designChain: "D", designLength: designLength,
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

    func testTheInsertionCodeLandsInItsOwnColumn() {
        XCTAssertEqual(RFD3ResultWriter.splitResi("45A").number, "45")
        XCTAssertEqual(RFD3ResultWriter.splitResi("45A").insertionCode, "A")
        XCTAssertEqual(RFD3ResultWriter.splitResi("46").insertionCode, "")
        XCTAssertEqual(RFD3ResultWriter.splitResi("-3").number, "-3")
        // Column 27 exactly, or every reader mis-parses the residue number.
        let record = RFD3ResultWriter.atomRecord(
            serial: 1, name: "CA", resName: "SER", chain: "H", resi: "45A",
            xyz: SIMD3(1, 2, 3))
        let index = record.index(record.startIndex, offsetBy: 26)
        XCTAssertEqual(record[index], "A")
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
}
#endif
