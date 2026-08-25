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
                guard c.x.isFinite && c.y.isFinite && c.z.isFinite else { return [] }
                out.append(c)
            }
        }
        return out
    }

    /// A poly-ALA backbone for the designed chain, used ONCE to give the trajectory
    /// object its atoms. Coordinates are zero; the first real frame overwrites them.
    ///
    /// Poly-ALA is forced, not lazy: states of one object share a single atom set
    /// including residue names, and the sequence head's argmax changes during the rollout
    /// — a residue is LEU at step 40 and VAL at step 80. A fixed identity is also the
    /// honest rendering of "the sequence is not settled yet". The engine allocates CB for
    /// every designed residue, so ALA fits the atom set exactly.
    static func seedPDB(length: Int, chain: String) -> String {
        var lines: [String] = []
        var serial = 1
        for residue in 0 ..< max(length, 0) {
            for name in emittedSlots {
                lines.append(RFD3ResultWriter.atomRecord(
                    serial: serial, name: name, resName: "ALA",
                    chain: chain, resi: String(residue + 1),
                    xyz: SIMD3(0, 0, 0)))
                serial += 1
            }
        }
        lines.append(RFD3ResultWriter.terRecord(serial: serial))
        lines.append("END")
        return lines.joined(separator: "\n") + "\n"
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
