#if os(macOS)
import Foundation
import RFD4MLX

/// Decides how much memory a design may claim, and refuses one that would claim more.
///
/// ## Why a guard, and why preventive
///
/// A design's peak allocation is quadratic in TOKEN count, and when it exceeds what Metal
/// can wire, mlx throws `std::runtime_error` from inside a Metal command-buffer completion
/// handler. That thread has no handler on its stack, so it reaches `std::terminate` and
/// the process dies with SIGABRT. A `do`/`catch` around the design does not catch it, and
/// neither does ``RFD4Runtime/withMLXErrorsAsThrows(_:)``. On macOS that costs the user
/// their whole session, unsaved work included — not just the job. Refusing the input
/// before any GPU work is the only defence available in-process.
///
/// ## Tokens, not atoms — and this is where porting RFD3's policy goes wrong
///
/// ``RFD3SizeGuard`` is denominated in ATOMS, because RFdiffusion3's cost is driven by its
/// all-atom representation. RFD4-Proteina's trunk is tokenized by RESIDUE: the pair track
/// is `[n, n, c]` over tokens and every triangle operation reads and rewrites it. So one
/// target residue is one token exactly as one designed residue is, `tokens = target
/// residues + design length`, and nothing here counts atoms.
///
/// Carrying RFD3's per-residue atom estimate across would inflate `n` by roughly five to
/// fourteen times and, in a QUADRATIC, refuse essentially everything.
///
/// ## The arithmetic is NOT reproduced here, deliberately
///
/// Everything numeric delegates to `RFD4Budget`, which owns the measured curve
/// (`peak(n) = 1.56318e-05·n² − 8.14674e-04·n + 0.780` GB at fp16, reproducing its four
/// measurements to within 16 MB). Copying those coefficients into RayMol would create two
/// fits that drift, and the drift is already scheduled: the port records which commit to
/// revert if memory ever matters more than speed, and a copied constant would then refuse
/// designs that fit comfortably. What lives here is POLICY: which fraction of this machine
/// RayMol is willing to hand to one design.
///
/// ## fp16, because that is what ships
///
/// The shipped pack declares `precision: fp16` in its manifest and the loader is handed it
/// explicitly, so `RFD4_DTYPE` cannot reinterpret it. Asking `RFD4Budget` for the fp32
/// curve would therefore predict exactly 2.000x the real peak and refuse half the designs
/// that fit. `RFD4Budget.shippingPrecision` is the single declaration of which one that
/// is, and this guard takes it from there rather than naming `.fp16` itself.
///
/// ## The fraction, and why it matches RFD3's rather than PredictSizeGuard's
///
/// ``okFraction`` is 0.50, the same as ``RFD3SizeGuard/okFraction`` and below
/// ``PredictSizeGuard/warnFraction``'s 0.75. The reasoning is RFD3's and carries over
/// unchanged: a Boltz fold that overcommits on macOS gets slow, while this one aborts the
/// process, and the asymmetry is total — a refusal costs the user a smaller target, an
/// abort costs them their session.
///
/// One reason RFD3 gives does NOT carry over, and it is worth saying so rather than
/// leaving the number looking equally justified. RFD3's curve was measured on a bare CLI
/// with no renderer and no other MLX consumer. RFD4's fp16 curve has been checked against
/// something closer to a real run: the 100-design albumin campaign reports a high-water
/// mark of 2.79 GB against the curve's 2.84 GB at its largest design — 1.7% high, which is
/// the right direction for a guard. That is still a CLI rather than a live session, so the
/// margin stays where it is; it is simply better evidenced here.
///
/// Raise it only from measurement against a live session, not from a design that "should"
/// have fitted.
enum RFD4SizeGuard {

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
    /// macOS only, like the whole file — the iOS slice never links RFD4MLX.
    static var availableBytes: Int { Int(ProcessInfo.processInfo.physicalMemory) }

    /// The ceiling one design may peak at on this machine.
    static var budgetBytes: Int { Int(Double(availableBytes) * okFraction) }

    /// The precision the shipped pack runs in, and therefore the curve to ask about.
    /// Taken from the port rather than restated, so the two cannot disagree about what
    /// ships.
    static var precision: RFD4Budget.Precision { RFD4Budget.shippingPrecision }

    enum Decision: Equatable {
        case ok
        /// Fits, but claims more than ``warnFraction`` of the machine.
        case warn(predictedBytes: Int, budgetBytes: Int)
        /// Does not fit. `maxTokens` is the largest design that would.
        case refuse(tokens: Int, predictedBytes: Int, budgetBytes: Int, maxTokens: Int)
    }

    /// Pure, and separate from anything that reads the machine, so the policy is testable
    /// at sizes this host does not have — the split ``RFD3SizeGuard`` uses for the same
    /// reason.
    static func decide(tokens: Int, budgetBytes: Int) -> Decision {
        let predicted = RFD4Budget.predictedPeakBytes(tokens: tokens,
                                                      precision: precision)
        if predicted > budgetBytes {
            return .refuse(tokens: tokens, predictedBytes: predicted,
                           budgetBytes: budgetBytes,
                           maxTokens: RFD4Budget.maxTokens(budgetBytes: budgetBytes,
                                                           precision: precision))
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
    static func refusalMessage(tokens: Int, predictedBytes: Int, budgetBytes: Int,
                               maxTokens: Int) -> String {
        func gb(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }
        return "this design is too large to run safely: \(tokens) tokens would peak at "
             + "~\(gb(predictedBytes)), over the \(gb(budgetBytes)) this machine allows "
             + "one design (at most ~\(maxTokens) tokens fit). One residue is one token, "
             + "target or designed, so shrinking the target selection is what buys room."
    }
}
#endif
