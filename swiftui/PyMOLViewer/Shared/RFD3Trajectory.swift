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
                // The magnitude cap catches finite-but-enormous values (e.g. 3.4e38 from a
                // diffusion blowup passing through 1e30 on its way to Inf). A coordinate
                // that large is accepted by the atom store but corrupts the session's global
                // view matrix on the next zoom — view[9..16] go non-finite and the user's
                // camera is broken for the rest of the session. That is worse than "no live
                // view". 1e6 Å is generous by any physical measure.
                guard c.x.isFinite && c.y.isFinite && c.z.isFinite,
                      abs(c.x) < 1e6 && abs(c.y) < 1e6 && abs(c.z) < 1e6 else { return [] }
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
    /// coordinates; see ``conectRecords(length:)`` for why inference cannot do it.
    ///
    /// Returns `""` when `coords` is not exactly one entry per emitted slot, so a
    /// mismatch degrades to "no live view" rather than to a mis-shaped object.
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
                lines.append(RFD3ResultWriter.atomRecord(
                    serial: serial, name: name, resName: "ALA",
                    chain: chain, resi: String(residue + 1),
                    xyz: coords[residue * emittedSlots.count + slot]))
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
    /// Distance inference cannot do this job here, which is why the coordinates alone are
    /// not enough. The first captured frame is the RAW EDM iterate, and that schedule
    /// starts at `sigmaData` (16) x `sMax` (160) = 2560 Å: in a measured 24-residue live
    /// run, state 1 spanned 153,687 Å and PyMOL bonded nothing at all. The chain contracts
    /// as the rollout proceeds — 443 Å by state 20, 18.7 Å by state 50 — but connectivity
    /// is decided ONCE, when this string is read, and `load_coordset` never re-bonds. An
    /// unbonded seed therefore renders every state, including the converged final one the
    /// user scrubs to, as 120 disconnected crosses with no backbone trace, for the life of
    /// the object and into any saved session.
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
