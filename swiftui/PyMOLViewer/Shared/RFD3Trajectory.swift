#if os(macOS)
import Foundation

/// Turns one frame of an RFD3 rollout into something PyMOL can hold as a state.
///
/// Pure arithmetic, deliberately: the live path itself needs a 672 MB pack and a real MLX
/// rollout to reach, so every decision that can be made without one is made here where a
/// unit test can reach it.
enum RFD3Trajectory {

    /// Dense atom slots the featurizer allocates per DESIGNED residue (`BINDER_SLOTS`:
    /// N, CA, C, O, CB, V0...V8). The designed chain is laid out first, so designed
    /// residue `r`'s slot `s` is atom `r * slotsPerDesignResidue + s`.
    static let slotsPerDesignResidue = 14

    /// The slots that are real atoms rather than placeholders — the same subset
    /// ``RFD3ResultWriter/emittedAtomNames`` keeps, in the same order.
    static let emittedSlots = ["N", "CA", "C", "O", "CB"]

    /// The designed chain's atoms from a flat `[L, 3]` rollout frame, back in the
    /// session's frame.
    ///
    /// Returns empty rather than throwing on a short array: a malformed frame must
    /// degrade to "no live view", never take a design down.
    static func frame(flat: [Float], length: Int,
                      origin: SIMD3<Float>) -> [SIMD3<Double>] {
        let needed = length * slotsPerDesignResidue * 3
        guard length > 0, flat.count >= needed else { return [] }
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(length * emittedSlots.count)
        for residue in 0 ..< length {
            for slot in 0 ..< emittedSlots.count {
                let atom = residue * slotsPerDesignResidue + slot
                let base = atom * 3
                let c = SIMD3(Double(flat[base] + origin.x),
                               Double(flat[base + 1] + origin.y),
                               Double(flat[base + 2] + origin.z))
                // NaN or Inf early in a rollout is possible. `String(format: "%.3f",
                // NaN)` emits bare `nan`, an undefined name in Python — the NameError
                // fires in the argument list before trajectory_frame's own guard, producing
                // a traceback per frame instead of the promised silent degrade.
                //
                // The same guard also bounds the MAGNITUDE, and it uses the PDB writer's
                // own range rather than a number of its own. Two reasons, and the second is
                // why it is this range and not a rounder one:
                //
                // 1. A finite-but-enormous coordinate (3.4e38 from a diffusion blowup on
                //    its way to Inf) is accepted by the atom store but takes the session's
                //    GLOBAL view matrix non-finite on the next zoom, breaking the user's
                //    camera for the rest of the session. Worse than "no live view".
                // 2. The first accepted frame is written as a PDB by `seedPDB`, and the
                //    PDB's coordinate columns are eight characters wide. A guard that
                //    admits more than the formatter can represent hands the formatter a
                //    value it cannot write — which, before this, it wrote anyway, nine
                //    characters wide, shifting every later field on the line. Sharing
                //    `RFD3ResultWriter.coordinateRange` is what makes the two incapable of
                //    disagreeing.
                //
                // A frame carrying one is dropped WHOLE, exactly as a non-finite one is:
                // half a frame would misplace atoms rather than skip them.
                guard RFD3ResultWriter.isRepresentable(c) else { return [] }
                out.append(c)
            }
        }
        return out
    }

    /// A poly-ALA backbone for the designed chain, used ONCE to give the trajectory
    /// object its atoms — and, just as importantly, its BONDS.
    ///
    /// `coords` is the FIRST captured frame, exactly as ``frame(flat:length:origin:)``
    /// returns it: residue-major, ``emittedSlots`` order within a residue. That frame
    /// becomes state 1 rather than an extra state after a placeholder — so the caller must
    /// NOT also append it — and the zeros this used to write are gone: an all-origin state
    /// 1 was a state of the trajectory that no step of the rollout ever produced, and it
    /// dragged every framing of the object (`zoom` gave z = -318.66 across all states
    /// against -23.39 on the first real one).
    ///
    /// Connectivity rides along as CONECT records rather than being left to the
    /// coordinates; see ``conectRecords(length:)`` for why inference is not good enough
    /// even at px0's protein scale.
    ///
    /// Returns `""` when `coords` is not exactly one entry per emitted slot, or when any
    /// coordinate falls outside `RFD3ResultWriter.coordinateRange` and so cannot be
    /// written in the PDB's eight-column fields. Either way the mismatch degrades to "no
    /// live view" rather than to a mis-shaped or mis-columned object.
    ///
    /// Poly-ALA is forced, not lazy: states of one object share a single atom set
    /// including residue names, and the sequence head's argmax changes during the rollout
    /// — a residue is LEU at step 40 and VAL at step 80. A fixed identity is also the
    /// honest rendering of "the sequence is not settled yet". The engine allocates CB for
    /// every designed residue, so ALA fits the atom set exactly.
    static func seedPDB(length: Int, chain: String, coords: [SIMD3<Double>]) -> String {
        guard length > 0, coords.count == length * emittedSlots.count else { return "" }
        var lines: [String] = []
        var serial = 1
        for residue in 0 ..< length {
            for (slot, name) in emittedSlots.enumerated() {
                // nil means the coordinate does not fit the PDB's eight-column fields.
                // `frame` already rejects those, so reaching this is a caller passing
                // coordinates it did not get from `frame` — still "no live view" rather
                // than a mis-columned object, because a design must never fail here.
                guard let line = RFD3ResultWriter.atomRecord(
                    serial: serial, name: name, resName: "ALA",
                    chain: chain, resi: String(residue + 1),
                    xyz: coords[residue * emittedSlots.count + slot]) else { return "" }
                lines.append(line)
                serial += 1
            }
        }
        lines.append(RFD3ResultWriter.terRecord(serial: serial))
        lines.append(contentsOf: conectRecords(length: length))
        lines.append("END")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The designed chain's bonds, stated rather than inferred.
    ///
    /// Connectivity is decided ONCE, when this string is read, and `load_coordset` never
    /// re-bonds. So the object's bonds for its entire life — including the converged
    /// final state the user scrubs to, and into any saved session — are whatever PyMOL
    /// made of the FIRST captured frame, which is step 4 of 199 and is not a settled
    /// backbone.
    ///
    /// That is why inference is not good enough even now that the stream is px0 and
    /// protein-scale. What distance inference returns depends on how unsettled that one
    /// early frame happens to be, and it degrades smoothly rather than failing loudly.
    /// Measured on a 24-residue poly-ALA chain that needs 119 bonds, seeded WITHOUT
    /// CONECT: 119 bonds from settled geometry, 89 with 1 Å of per-atom jitter, 54 with
    /// 2 Å, 37 with 3 Å, and 5 from a protein-scale (54 Å) cloud. With CONECT it is 119
    /// in every one of those cases — and 119, not 238, from settled geometry, because
    /// PyMOL MERGES stated bonds with what it would have inferred rather than adding to
    /// them.
    ///
    /// The topology is known a priori anyway: this object is poly-ALA with a fixed atom
    /// set, so re-deriving it from a guess buys nothing and risks the whole trajectory
    /// rendering as loose crosses.
    ///
    /// Poly-ALA backbone topology: N-CA, CA-C, C-O and CA-CB within a residue, and
    /// C(i)-N(i+1) between them — `4 * length + (length - 1)` records. PyMOL merges these
    /// with anything it would have inferred, so a converged frame is not double-bonded.
    static func conectRecords(length: Int) -> [String] {
        guard length > 0 else { return [] }
        let slots = emittedSlots.count
        func serial(_ residue: Int, _ name: String) -> Int {
            residue * slots + (emittedSlots.firstIndex(of: name) ?? 0) + 1
        }
        var records: [String] = []
        for residue in 0 ..< length {
            for (from, to) in [("N", "CA"), ("CA", "C"), ("C", "O"), ("CA", "CB")] {
                records.append(String(format: "CONECT%5d%5d",
                                      serial(residue, from), serial(residue, to)))
            }
            if residue + 1 < length {
                records.append(String(format: "CONECT%5d%5d",
                                      serial(residue, "C"), serial(residue + 1, "N")))
            }
        }
        return records
    }

    /// Whether this step's coordinates are worth materialising.
    ///
    /// Every `interval`-th step, plus the final one so the recording ends where the design
    /// does rather than up to `interval - 1` steps short of it.
    static func shouldCapture(step: Int, interval: Int, total: Int) -> Bool {
        guard interval > 0 else { return false }
        return step % interval == 0 || step == total
    }
}
#endif
