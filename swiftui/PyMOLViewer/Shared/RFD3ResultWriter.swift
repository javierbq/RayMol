#if os(macOS)
import Foundation

/// Turns RFD3Kit's design output into the object RayMol loads.
///
/// This is NOT a pass-through of `Result.pdb`, and every reason is a silent-wrong-answer
/// this type exists to prevent. `Result.pdb` is what the model produced, in the model's own
/// terms:
///
/// 1. **It is in a translated frame.** The featurizer stores `motif_pos = input − origin`,
///    where `origin` is the hotspot centre of mass pushed 10 Å along the core-to-hotspot
///    normal, and the sampler works in that frame throughout. Loaded as-is, the whole
///    complex lands tens of Ångström from the target the user selected — a design that
///    looks correct in isolation and is nowhere near the structure it was designed against.
/// 2. **Chain A's residue NAMES are the sequence head's argmax, not the input identities.**
///    `RFD3Output.makePDB` writes `AA3[seqIdx[t]]` for *every* token including the target's,
///    so a target's ALA can come back as LEU. The sequence head is not asked to reproduce
///    the target and is not scored on it.
/// 3. **It has no sidechains.** Only N, CA, C, O and CB survive; every `V*` slot is
///    dropped. The target sidechains that CONDITIONED the model are absent from its output.
/// 4. **It is renumbered 1..N per chain**, so the target's own numbering — the numbering
///    the user's hotspot selection was written in — is gone.
///
/// So the target half is emitted from the ORIGINAL atoms, verbatim, and only the designed
/// chain comes from the model, translated back. That is what makes the emitted object
/// superpose atom-for-atom on the structure it was designed against, and it is why
/// `targetDriftMaxA` is checked rather than trusted: if the model HAD moved the target, the
/// original coordinates would no longer describe where the design was built, and the pair
/// would be quietly inconsistent. See ``composeError`` `.targetMoved`.
///
/// The back-translation is exact because the map is a pure translation. Target atoms are
/// masked out of the noise at every step (`keep = 1 - is_motif_atom_with_fixed_coord`) and
/// the denoiser reproduces them, which is what `targetDriftMaxA ≈ 0` measures. So
/// `origin = mean(input − output)` over the target atoms recovers it, and the residual
/// around that mean is what is left: a change in the target's own SHAPE, which no
/// translation can absorb.
///
/// Note what that residual can and cannot see. A RIGID shift of the whole target is
/// absorbed by construction, and correctly so — undoing it carries the design with it and
/// the pose survives. A rigid shift is nonetheless caught one layer up, by
/// ``RFD3JobManager`` checking the engine's own `Stats.targetDriftMaxA`, which is measured
/// in the engine's frame and therefore sees any movement at all. That is why there are two
/// checks and not one.
enum RFD3ResultWriter {

    /// Atoms the engine emits, in the order it emits them. Not used to FILTER anything:
    /// it is here to document what a target residue's output half contains, which is why
    /// only these can contribute to the offset estimate.
    static let emittedAtomNames: Set<String> = ["N", "CA", "C", "O", "CB"]

    /// Every coordinate a PDB ATOM record can represent, in Angstrom.
    ///
    /// The PDB is FIXED-COLUMN: x, y and z occupy columns 31-38, 39-46 and 47-54, eight
    /// characters each, written `%8.3f`. Three decimals plus a point leaves four
    /// characters for the integer part and the sign, so `-999.999` is the most negative
    /// and `9999.999` the most positive value that fits. One character more and `%8.3f`
    /// widens the field instead of truncating it -- `printf` has no width CLAMP, only a
    /// width MINIMUM -- and every column after it on that line shifts right. A reader
    /// then takes eight characters from column 39 and gets whatever the overflow pushed
    /// there, which for a single overflowing x is the leading spaces of y: measured,
    /// `(-1000.0, 1.0, 2.0)` written and read back by PyMOL as `(-1000.0, 0.0, 0.0)`.
    /// Silently. There is no parse error to catch, because the line is still 80 columns
    /// of plausible-looking text.
    ///
    /// So this is not a policy choice, it is the format's own limit, and it is stated
    /// ONCE here because two things depend on it: ``atomRecord``, which refuses to write
    /// what it cannot write, and ``RFD3Trajectory/frame(flat:length:origin:)``, whose
    /// magnitude guard drops a frame BEFORE it reaches the writer. A guard and a
    /// formatter that disagree about the representable range is exactly the bug this
    /// closes -- the guard used to admit anything under 1e6.
    ///
    /// The bounds are compared against the UNROUNDED value on purpose, so 9999.9996 --
    /// which `%8.3f` would round up to the nine-character `10000.000` -- is refused
    /// rather than written.
    static let coordinateRange: ClosedRange<Double> = (-999.999) ... 9999.999

    /// Whether every component of `xyz` fits the PDB's eight-column coordinate fields.
    static func isRepresentable(_ xyz: SIMD3<Double>) -> Bool {
        [xyz.x, xyz.y, xyz.z].allSatisfy {
            $0.isFinite && coordinateRange.contains($0)
        }
    }

    enum ComposeError: Error, CustomStringConvertible, LocalizedError {
        case noTargetAtoms
        case noDesignAtoms(expected: Int)
        case designLengthMismatch(expected: Int, found: Int)
        case unmatchedTargetAtoms
        case targetDeformed(byAngstrom: Double, tolerance: Double)
        case coordinateOutOfRange(atom: String, resi: String, xyz: SIMD3<Double>)

        var description: String {
            switch self {
            case .noTargetAtoms:
                return "the design output carries no target chain, so the frame it was"
                     + " generated in cannot be recovered"
            case .noDesignAtoms(let expected):
                return "the design output carries no designed chain (expected"
                     + " \(expected) residues)"
            case .designLengthMismatch(let expected, let found):
                return "the design output has \(found) designed residues, not the"
                     + " \(expected) that were requested"
            case .unmatchedTargetAtoms:
                return "no target atom in the design output could be matched to the target"
                     + " that was supplied, so the generated chain cannot be placed"
            case .targetDeformed(let by, let tolerance):
                return String(format:
                    "the target changed SHAPE by %.3f A during generation (tolerance"
                    + " %.3f A). It is held rigid by contract: a rigid shift of the whole"
                    + " target is recoverable and is recovered, but a change in the"
                    + " distances between its own atoms is not -- the designed chain was"
                    + " built against a target that is not the one being written beside"
                    + " it. Refused rather than emitted.", by, tolerance)
            case .coordinateOutOfRange(let atom, let resi, let xyz):
                return String(format:
                    "atom %@ of residue %@ is at (%.3f, %.3f, %.3f), which the PDB's"
                    + " eight-column coordinate fields cannot represent (%.3f to %.3f A)."
                    + " Written anyway it would shift every later field on that line and"
                    + " be read back as different coordinates entirely, so it is refused."
                    + " Move the target nearer the origin and design again.",
                    atom, resi, xyz.x, xyz.y, xyz.z,
                    coordinateRange.lowerBound, coordinateRange.upperBound)
            }
        }

        var errorDescription: String? { description }
    }

    /// Largest change in the target's own SHAPE tolerated, in Angstrom.
    ///
    /// Deformation, not displacement, and the distinction is the whole design of
    /// ``recoverOffset``. A rigid translation of the target is exactly what this type
    /// undoes, so it cannot and need not be detected: undoing it puts the target back and
    /// carries the design with it, pose intact. What is NOT recoverable is the target's
    /// atoms moving relative to each other -- or a rotation, or a residue-order mismatch --
    /// because the emitted target is the ORIGINAL coordinates, so the design would be
    /// placed against a shape that is not the one written beside it.
    ///
    /// A rigid displacement is still caught, one layer up: ``RFD3JobManager`` checks the
    /// engine's own `Stats.targetDriftMaxA`, which is measured in the engine's frame and so
    /// sees any movement at all. Two independent checks, neither redundant.
    ///
    /// The measured value is 0.000 across every benchmarked run, so this is not a fitted
    /// threshold -- it is "not zero, but nowhere near a real deformation". Float32
    /// accumulation over 200 denoising steps is what it leaves room for.
    static let driftToleranceAngstrom = 0.25

    struct Atom {
        let name: String
        let xyz: SIMD3<Double>
    }

    /// An emitted object, plus WHERE the generated chain sits inside it.
    ///
    /// The layout is returned rather than inferred by whoever reads the string. Live
    /// view splices one chain of this object per frame, and "the generated chain is the
    /// last N atoms" is true only because ``emit`` writes it last -- a fact of this
    /// function, not of PDB files. Stated here, it travels with the object to the one
    /// place that needs it and cannot fall out of step with the writer.
    struct Composed {
        let pdb: String
        /// Atoms written BEFORE the generated chain: the target's, in target order.
        let targetAtomCount: Int
        /// Atoms of the generated chain.
        let designAtomCount: Int
        /// PDB serial of the generated chain's first atom. Not `targetAtomCount + 1`:
        /// a `TER` record consumes a serial between the two chains.
        let designFirstSerial: Int
    }

    /// Atoms ``emit`` will write for `target` -- every atom with a three-component
    /// position, which is the same filter the emission loop applies.
    static func targetAtomCount(_ target: [InferenceJob.DesignResidue]) -> Int {
        target.reduce(0) { $0 + $1.atoms.filter { $0.xyz.count == 3 }.count }
    }

    /// The serial ``emit`` will give the generated chain's first atom.
    ///
    /// Exposed so a caller that must number CONECT records can do it BEFORE emitting,
    /// rather than emitting twice or parsing the string back. `Composed.designFirstSerial`
    /// carries the same number afterwards, so a test can hold the two against each other.
    static func designFirstSerial(target: [InferenceJob.DesignResidue]) -> Int {
        targetAtomCount(target) + 2       // + 1 for the atom, + 1 for the TER between
    }

    /// One parsed chain of the engine's output: residue number -> atoms, in file order.
    struct ParsedChain {
        /// Residue numbers in the order they first appear -- the engine numbers 1..N per
        /// chain in token order, so this is token order.
        var order: [Int] = []
        var residues: [Int: [Atom]] = [:]
    }

    /// Parse the engine's PDB. Deliberately tolerant about record ORDER: the designed
    /// chain's records come FIRST in the file (designed tokens precede target tokens), and
    /// there is a single `TER` at the very end rather than one per chain, so nothing here
    /// may key off either.
    static func parse(_ pdb: String) -> [String: ParsedChain] {
        var chains: [String: ParsedChain] = [:]
        for line in pdb.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("ATOM"), line.count >= 54 else { continue }
            let text = String(line)
            func slice(_ from: Int, _ to: Int) -> String {
                let a = text.index(text.startIndex, offsetBy: from)
                let b = text.index(text.startIndex, offsetBy: min(to, text.count))
                return String(text[a ..< b]).trimmingCharacters(in: .whitespaces)
            }
            let name = slice(12, 16)
            let chain = slice(21, 22)
            guard let resSeq = Int(slice(22, 26)),
                  let x = Double(slice(30, 38)), let y = Double(slice(38, 46)),
                  let z = Double(slice(46, 54)) else { continue }
            var entry = chains[chain] ?? ParsedChain()
            if entry.residues[resSeq] == nil { entry.order.append(resSeq) }
            entry.residues[resSeq, default: []].append(
                Atom(name: name, xyz: SIMD3(x, y, z)))
            chains[chain] = entry
        }
        return chains
    }

    /// The translation from the engine's frame back into the session's, plus the residual
    /// around it -- which IS the target's drift, measured here rather than taken on trust.
    ///
    /// Averaged over every matched atom rather than taken from one: a mean over a few
    /// thousand atoms is immune to float noise in any single one, and the residual is then
    /// a real measurement instead of a comparison against an arbitrary reference atom.
    static func recoverOffset(target: [InferenceJob.DesignResidue],
                              output: ParsedChain)
        throws -> (offset: SIMD3<Double>, residual: Double)
    {
        var sum = SIMD3<Double>(0, 0, 0)
        var matched: [(SIMD3<Double>, SIMD3<Double>)] = []
        for (index, number) in output.order.enumerated() {
            guard index < target.count, let atoms = output.residues[number] else { continue }
            let source = target[index]
            var byName: [String: SIMD3<Double>] = [:]
            for atom in source.atoms where atom.xyz.count == 3 {
                byName[atom.name] = SIMD3(atom.xyz[0], atom.xyz[1], atom.xyz[2])
            }
            for atom in atoms {
                guard let original = byName[atom.name] else { continue }
                matched.append((original, atom.xyz))
                sum += original - atom.xyz
            }
        }
        guard !matched.isEmpty else { throw ComposeError.unmatchedTargetAtoms }
        let offset = sum / Double(matched.count)
        var residual = 0.0
        for (original, produced) in matched {
            let error = original - (produced + offset)
            residual = max(residual, (error * error).sum().squareRoot())
        }
        return (offset, residual)
    }

    /// The finished object: the target exactly as supplied, plus the generated chain
    /// translated back into the same frame.
    ///
    /// `designSequence` is the engine's own one-letter output and is what names the
    /// generated residues -- not the residue names in its PDB. The two agree, but the
    /// sequence is the documented public output while the PDB's names are a rendering of it.
    static func compose(target: [InferenceJob.DesignResidue],
                        designChain: String,
                        designLength: Int,
                        designSequence: String,
                        resultPDB: String,
                        remarks: [String]) throws -> String {
        guard !target.isEmpty else { throw ComposeError.noTargetAtoms }
        let chains = parse(resultPDB)
        guard let targetOut = chains["A"] else { throw ComposeError.noTargetAtoms }
        guard let designOut = chains["B"] else {
            throw ComposeError.noDesignAtoms(expected: designLength)
        }
        guard designOut.order.count == designLength else {
            throw ComposeError.designLengthMismatch(expected: designLength,
                                                    found: designOut.order.count)
        }
        let (offset, residual) = try recoverOffset(target: target, output: targetOut)
        guard residual <= driftToleranceAngstrom else {
            throw ComposeError.targetDeformed(byAngstrom: residual,
                                              tolerance: driftToleranceAngstrom)
        }
        // Translated back into the session's frame, then handed to the one emitter.
        let designResidues = designOut.order.map { number in
            (designOut.residues[number] ?? []).map {
                Atom(name: $0.name, xyz: $0.xyz + offset)
            }
        }
        return try emit(target: target, designChain: designChain,
                        designResidues: designResidues,
                        designSequence: designSequence, remarks: remarks).pdb
    }

    /// THE emitter: target chain then generated chain, in that order, and the only place
    /// either is written.
    ///
    /// Shared with live view rather than paralleled by it, and that is the point. A live
    /// run seeds its object from this and then splices ONE chain of it per frame, which
    /// works only while the atom ORDER of the seed and of the finished result are the
    /// same string of atoms. Two builders that must agree eventually disagree; one
    /// builder cannot. So the live path differs from the result path in exactly two
    /// arguments -- the coordinates it has (a rollout frame, not the engine's output) and
    /// the names it gives them (poly-ALA, because the sequence is not settled yet) -- and
    /// in nothing else.
    ///
    /// `designResidues` is already in the SESSION's frame: `compose` translates the
    /// engine's output back, `RFD3Trajectory` adds the featurizer's origin. Neither
    /// translation belongs here, because they are different translations.
    ///
    /// `extraRecords` is written after the closing `TER` and before `END`, which is where
    /// a PDB reader expects CONECT. Empty for the result -- adding records there would
    /// change what a non-live run produces -- and the seed's stated connectivity for a
    /// live run.
    static func emit(target: [InferenceJob.DesignResidue],
                     designChain: String,
                     designResidues: [[Atom]],
                     designSequence: String,
                     remarks: [String],
                     extraRecords: [String] = []) throws -> Composed {
        var lines: [String] = remarks.map { "REMARK 300 " + $0 }
        var serial = 1
        // A record the PDB's columns cannot hold is a REFUSAL here, not a clamp: the whole
        // point of this type is that the emitted object superposes atom-for-atom on the
        // structure it was designed against, and a coordinate silently rewritten to fit
        // breaks exactly that. See `coordinateRange`.
        func record(serial: Int, name: String, resName: String, chain: String,
                    resi: String, xyz: SIMD3<Double>) throws -> String {
            guard let line = atomRecord(serial: serial, name: name, resName: resName,
                                        chain: chain, resi: resi, xyz: xyz) else {
                throw ComposeError.coordinateOutOfRange(atom: name, resi: resi, xyz: xyz)
            }
            return line
        }
        // The target, verbatim: original coordinates, original chain id, original residue
        // numbering and insertion codes, original residue names, and every atom including
        // the sidechains the engine's output drops.
        var targetAtoms = 0
        for residue in target {
            for atom in residue.atoms where atom.xyz.count == 3 {
                lines.append(try record(serial: serial, name: atom.name,
                                        resName: residue.resn, chain: residue.chain,
                                        resi: residue.resi,
                                        xyz: SIMD3(atom.xyz[0], atom.xyz[1], atom.xyz[2])))
                serial += 1
                targetAtoms += 1
            }
        }
        lines.append(terRecord(serial: serial))
        serial += 1
        let designFirstSerial = serial
        // The generated chain.
        var designAtoms = 0
        let letters = Array(designSequence)
        for (index, atoms) in designResidues.enumerated() {
            let resName = index < letters.count ? threeLetter(letters[index]) : "UNK"
            for atom in atoms {
                lines.append(try record(serial: serial, name: atom.name,
                                        resName: resName, chain: designChain,
                                        resi: String(index + 1), xyz: atom.xyz))
                serial += 1
                designAtoms += 1
            }
        }
        lines.append(terRecord(serial: serial))
        lines.append(contentsOf: extraRecords)
        lines.append("END")
        return Composed(pdb: lines.joined(separator: "\n") + "\n",
                        targetAtomCount: targetAtoms,
                        designAtomCount: designAtoms,
                        designFirstSerial: designFirstSerial)
    }

    // MARK: - PDB record formatting

    /// Split PyMOL's `resi` into the PDB's residue-sequence and insertion-code columns.
    /// PyMOL carries the code inside `resi` ("45A"); the PDB has two fields.
    static func splitResi(_ resi: String) -> (number: String, insertionCode: String) {
        var digits = ""
        var rest = ""
        for character in resi {
            if rest.isEmpty && (character.isNumber || (digits.isEmpty && character == "-")) {
                digits.append(character)
            } else {
                rest.append(character)
            }
        }
        return (digits.isEmpty ? "0" : digits, String(rest.prefix(1)))
    }

    /// One ATOM record, or `nil` when `xyz` cannot be written in the PDB's fixed columns.
    ///
    /// OPTIONAL deliberately, rather than clamping or writing a wider field. A clamped
    /// coordinate is a wrong coordinate that looks right, and a wider field is a line
    /// every reader mis-parses; both are the silent-wrong-answer this whole type exists
    /// to prevent. Returning nil makes the compiler ask its caller what it wants instead.
    /// There is one now — ``emit`` — and it throws, because an object that cannot be
    /// written must not be half-written. What differs is what the two callers of `emit`
    /// do with that: the result path lets it fail the design, while
    /// ``RFD3Trajectory/seed(target:length:chain:coords:)`` swallows it into `nil`,
    /// because live view degrades to nothing and never fails a design.
    ///
    /// See ``coordinateRange`` for what the limit is and why it is the format's rather
    /// than ours.
    static func atomRecord(serial: Int, name: String, resName: String, chain: String,
                           resi: String, xyz: SIMD3<Double>) -> String? {
        guard isRepresentable(xyz) else { return nil }
        let (number, insertion) = splitResi(resi)
        // Columns 13-16. A name of four characters starts at 13; a shorter one is indented
        // by one, which is what puts the element letter in column 14 where readers expect
        // it. `CA` indented is calcium-vs-alpha-carbon: the same trap PyMOL's own writer
        // handles this way.
        let atomName = name.count >= 4
            ? String(name.prefix(4))
            : " " + name.padding(toLength: 3, withPad: " ", startingAt: 0)
        let element = String(name.first(where: { $0.isLetter }) ?? "C")
        return "ATOM  "
            + pad(String(serial), 5) + " "
            + atomName + " "
            + pad(resName, 3) + " "
            + (chain.isEmpty ? " " : String(chain.prefix(1)))
            + pad(number, 4)
            + (insertion.isEmpty ? " " : insertion)
            + "   "
            + String(format: "%8.3f%8.3f%8.3f", xyz.x, xyz.y, xyz.z)
            + "  1.00  0.00          "
            + pad(element, 2)
    }

    static func terRecord(serial: Int) -> String {
        "TER   " + pad(String(serial), 5)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width
            ? String(text.suffix(width))
            : String(repeating: " ", count: width - text.count) + text
    }

    private static let oneToThree: [Character: String] = [
        "A": "ALA", "R": "ARG", "N": "ASN", "D": "ASP", "C": "CYS", "Q": "GLN",
        "E": "GLU", "G": "GLY", "H": "HIS", "I": "ILE", "L": "LEU", "K": "LYS",
        "M": "MET", "F": "PHE", "P": "PRO", "S": "SER", "T": "THR", "W": "TRP",
        "Y": "TYR", "V": "VAL",
    ]

    static func threeLetter(_ letter: Character) -> String {
        oneToThree[letter] ?? "UNK"
    }
}
#endif
