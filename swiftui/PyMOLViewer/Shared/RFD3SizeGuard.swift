#if os(macOS)
import Foundation
import RFD3Kit

/// Decides how much memory a design may claim, and refuses one that would claim more.
///
/// ## Why a guard, and why preventive
///
/// A design's peak allocation is quadratic in atom count, and when it exceeds what Metal
/// can wire, mlx throws `std::runtime_error` from inside a Metal command-buffer completion
/// handler. That thread has no handler on its stack, so it reaches `std::terminate` and the
/// process dies with SIGABRT. A `do`/`catch` around the design does not catch it, and
/// neither does ``MLXRuntime/withMLXErrorsAsThrows(_:)``. On macOS that costs the user their
/// whole session, unsaved work included — not just the job. Refusing the input before any
/// GPU work is the only defence available in-process.
///
/// ## The arithmetic is NOT reproduced here, deliberately
///
/// Everything numeric delegates to `RFD3Budget`, which owns the measured curve
/// (`peak(A) = 995.5·A² − 524_880·A + 1.226e9`, max residual 0.96% over 1668–7268 atoms).
/// Copying those coefficients into RayMol would create two fits that drift, and the drift
/// is already scheduled: row-blocking the motif `SinusoidalDistEmbed` upstream takes the
/// quadratic term from ~995 to ~62 bytes per atom² — a ~16× cut — and a copied constant
/// would then refuse designs that fit comfortably. What lives here is POLICY: which
/// fraction of this machine RayMol is willing to hand to one design.
///
/// ## The fraction, and why it is lower than either neighbour
///
/// ``okFraction`` is 0.50, against `RFD3Budget.defaultMemoryFraction`'s 0.60 and
/// ``PredictSizeGuard/warnFraction``'s 0.75. Three reasons to be the most conservative of
/// the three rather than the most permissive:
///
/// 1. **The failure is worse.** A Boltz fold that overcommits on macOS gets slow (swap);
///    this one aborts the process. The asymmetry is total — a refusal costs the user a
///    smaller target, an abort costs them their session.
/// 2. **RFD3Budget's curve was measured on a bare CLI**, one design per process, with no
///    renderer, no loaded structures and no other MLX consumer. RayMol is all four.
/// 3. **The peak is a ~140 ms transient** inside `TokenInitializer`, and it is exactly
///    independent of `numTimesteps`. Nothing smooths it: no reclaim policy and no cache
///    limit can spread a single allocation over time, so the headroom has to be there
///    when it happens.
///
/// Raise it only from measurement against a live session, not from a design that "should"
/// have fitted.
enum RFD3SizeGuard {

    /// Fraction of physical memory one design may peak at. See the type doc.
    static let okFraction = 0.50

    /// Below this it is worth saying so, above it worth refusing. Only ``okFraction``
    /// gates anything today; this exists so the tier can be surfaced without re-deriving
    /// a second number, and so `decide` has somewhere honest to put "this is close".
    static let warnFraction = 0.40

    /// What this machine has. `physicalMemory` rather than anything dynamic: the abort
    /// this guard prevents is about what Metal can wire, and a Mac's free-memory figure
    /// swings with the page cache in a way that would make the same design fit or not fit
    /// depending on when it was asked.
    ///
    /// macOS only, like the whole file — the iOS slice never links RFD3Kit.
    static var availableBytes: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    /// The ceiling one design may peak at on this machine.
    static var budgetBytes: Int { Int(Double(availableBytes) * okFraction) }

    enum Decision: Equatable {
        case ok
        /// Fits, but claims more than ``warnFraction`` of the machine.
        case warn(predictedBytes: Int, budgetBytes: Int)
        /// Does not fit. `maxAtoms` is the largest design that would.
        case refuse(atoms: Int, predictedBytes: Int, budgetBytes: Int, maxAtoms: Int)
    }

    /// Pure, and separate from anything that reads the machine, so the policy is testable
    /// at sizes this host does not have — the split ``DesignSizeGuard`` uses for the same
    /// reason.
    static func decide(atoms: Int, budgetBytes: Int) -> Decision {
        let predicted = RFD3Budget.predictedPeakBytes(atoms: atoms)
        if predicted > budgetBytes {
            return .refuse(atoms: atoms, predictedBytes: predicted,
                           budgetBytes: budgetBytes,
                           maxAtoms: RFD3Budget.maxAtoms(budgetBytes: budgetBytes))
        }
        // Against the same budget the refusal uses, so the two tiers cannot disagree
        // about what "close" means: warnFraction/okFraction of the machine is
        // warnFraction/okFraction of this budget.
        let warnAt = Int(Double(budgetBytes) * (warnFraction / okFraction))
        if predicted > warnAt {
            return .warn(predictedBytes: predicted, budgetBytes: budgetBytes)
        }
        return .ok
    }

    /// A refusal a user can act on: what was asked, what it would cost, and what fits.
    static func refusalMessage(atoms: Int, predictedBytes: Int, budgetBytes: Int,
                              maxAtoms: Int) -> String {
        func gb(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
        return "this design is too large to run safely: \(atoms) atoms would peak at "
             + "~\(gb(predictedBytes)), over the \(gb(budgetBytes)) this machine allows "
             + "one design (at most ~\(maxAtoms) atoms fit). Shrink the target selection "
             + "or reduce the length — a designed residue costs 14 atoms against a target "
             + "residue's 5-8, so length is the expensive axis."
    }
}
#endif
