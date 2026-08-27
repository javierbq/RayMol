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
                // 2. The first accepted frame is written as a PDB by `seed`, and the
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

    /// The object a live run streams into: the TARGET at its real coordinates plus a
    /// poly-ALA generated chain seeded from the FIRST captured frame.
    ///
    /// Emitted by ``RFD3ResultWriter/emit(target:designChain:designResidues:designSequence:remarks:extraRecords:)``,
    /// the same function that writes the finished result, and that is the load-bearing
    /// part. The live object IS the result object: when the run ends, the design's real
    /// coordinates are appended to it as one more state instead of a second object being
    /// created. Appending only works while the two are the same atoms in the same order,
    /// so they are built by one function rather than by two that have to agree.
    ///
    /// `coords` is the first captured frame, exactly as ``frame(flat:length:origin:)``
    /// returns it: residue-major, ``emittedSlots`` order within a residue. That frame
    /// becomes state 1 rather than an extra state after a placeholder — so the caller must
    /// NOT also append it — and it carries real coordinates rather than zeros: an
    /// all-origin state 1 was a state no step of the rollout ever produced, and PyMOL
    /// infers the generated chain's bonds from it once and for all.
    ///
    /// Connectivity for the generated chain rides along as CONECT records rather than
    /// being left to the coordinates; see ``conectRecords(length:firstSerial:)`` for why
    /// inference is not good enough even at px0's protein scale. The TARGET needs none:
    /// its coordinates are the real, settled structure, which PyMOL bonds correctly.
    ///
    /// Returns `nil` when `coords` is not exactly one entry per emitted slot, or when any
    /// coordinate — of the frame OR of the target — falls outside
    /// `RFD3ResultWriter.coordinateRange` and so cannot be written in the PDB's
    /// eight-column fields. Either way the mismatch degrades to "no live view" rather
    /// than to a mis-shaped or mis-columned object.
    ///
    /// Poly-ALA is forced, not lazy: states of one object share a single atom set
    /// including residue names, and the sequence head's argmax changes during the rollout
    /// — a residue is LEU at step 40 and VAL at step 80. A fixed identity is also the
    /// honest rendering of "the sequence is not settled yet". It is not the identity the
    /// user is left with: delivery renames the chain to the design's real sequence before
    /// appending the final state, and residue names in PyMOL are per-OBJECT rather than
    /// per-state, so the finished object shows the designed sequence in every state.
    static func seed(target: [InferenceJob.DesignResidue], length: Int, chain: String,
                     coords: [SIMD3<Double>]) -> RFD3ResultWriter.Composed? {
        guard length > 0, coords.count == length * emittedSlots.count else { return nil }
        let residues: [[RFD3ResultWriter.Atom]] = (0 ..< length).map { residue in
            emittedSlots.enumerated().map { slot, name in
                RFD3ResultWriter.Atom(
                    name: name, xyz: coords[residue * emittedSlots.count + slot])
            }
        }
        // Numbered before emitting rather than after: the CONECT records have to name the
        // serials the generated chain will get, and those start after the target and its
        // TER. `Composed.designFirstSerial` reports the same number back, which is what
        // lets a test hold the prediction against the emission.
        let firstSerial = RFD3ResultWriter.designFirstSerial(target: target)
        // `try?` rather than `try`: a target or a frame the PDB's columns cannot hold is
        // "no live view", never a thrown error into a running rollout.
        return try? RFD3ResultWriter.emit(
            target: target, designChain: chain, designResidues: residues,
            designSequence: String(repeating: "A", count: length),
            remarks: [],
            extraRecords: conectRecords(length: length, firstSerial: firstSerial))
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
    ///
    /// `firstSerial` is the PDB serial of the generated chain's first atom. It is a
    /// parameter rather than 1 because the generated chain no longer starts the file: the
    /// target is written before it, and a CONECT record naming serial 1 would bond two
    /// atoms of the TARGET instead. Take it from
    /// ``RFD3ResultWriter/designFirstSerial(target:)``.
    static func conectRecords(length: Int, firstSerial: Int) -> [String] {
        guard length > 0 else { return [] }
        let slots = emittedSlots.count
        func serial(_ residue: Int, _ name: String) -> Int {
            firstSerial + residue * slots + (emittedSlots.firstIndex(of: name) ?? 0)
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

    // MARK: The playback head

    /// How often the playback head reconsiders which state to show, per second.
    ///
    /// Its own constant, deliberately NOT `PlaybackState.movieFPS`: that is the user's
    /// setting for the user's movies, and a design's pacing is not their movie's pacing.
    /// Changing one must not change the other.
    static let playbackTicksPerSecond = 15

    /// How long the head aims to take to close whatever gap it has, in milliseconds.
    ///
    /// This is what makes the motion EVEN rather than arrival-driven. The head deliberately
    /// runs about this far behind the newest captured state while frames are still coming,
    /// and closes the gap when they stop — so a burst of five frames arriving at once is
    /// paced out over roughly a second instead of snapping through in one redraw, and a
    /// steady one-per-second stream advances once per second rather than whenever the GPU
    /// happens to hand a frame over.
    static let playbackCatchUpMilliseconds = 1000

    /// THE pacing decision: which state the head should be showing on this tick.
    ///
    /// Pure, and the one seam the whole feature turns on. Everything else is a timer and a
    /// `set state` — this is the only place that decides anything, which is what makes it
    /// testable at all: the live path needs a 672 MB pack and a real MLX rollout, so an
    /// expression buried in it is an expression no test ever runs.
    ///
    /// It is also where INTERPOLATION would go, if the follow-on is asked for: this would
    /// return a state plus a fraction between it and the next, and nothing around it would
    /// have to move.
    ///
    /// The rule is self-balancing. `backlog / catchUp` is the rate needed to clear the gap
    /// in `catchUpMilliseconds`, so a bigger backlog drains faster and a smaller one waits
    /// longer. Left alone with frames arriving at a steady rate, the head settles at
    /// whatever backlog makes its pace match theirs. It advances ONE state at a time and
    /// never skips, so every captured frame is seen.
    ///
    /// Returns `shown` unchanged to mean "stay put" — nothing new (`newest <= shown`),
    /// or not enough ticks have passed yet.
    static func nextPlaybackState(shown: Int, newest: Int, ticksWaited: Int,
                                  ticksPerSecond: Int = playbackTicksPerSecond,
                                  catchUpMilliseconds: Int = playbackCatchUpMilliseconds)
        -> Int
    {
        guard newest > shown, ticksPerSecond > 0, catchUpMilliseconds > 0 else {
            return shown
        }
        let backlog = newest - shown
        // Integer arithmetic on purpose: no accumulating float drift over a run that can
        // be thousands of ticks long. `max(1, ...)` because a large backlog rounds the
        // wait to zero and a head that advances on EVERY tick is the fastest it may go.
        let ticksPerState = max(1, (ticksPerSecond * catchUpMilliseconds)
                                   / (1000 * backlog))
        return ticksWaited >= ticksPerState ? shown + 1 : shown
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
