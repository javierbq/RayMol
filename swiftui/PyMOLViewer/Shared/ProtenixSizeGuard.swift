#if os(macOS)
import Foundation

/// Decides whether a Protenix fold fits on this machine, from MEASURED peaks.
///
/// A separate type from ``PredictSizeGuard`` rather than a parameterisation of it. That
/// guard's constants are fitted to *Boltz* — its own docstring records three occasions
/// where extrapolating past its data ran optimistic, the last two by 27% each — and
/// Protenix is a different network at a different operating point in exactly the
/// directions that fit is weakest: 48 Pairformer blocks over an N×N pair tensor, ten
/// recycles rather than three, and a confidence head that runs four more Pairformer
/// blocks over that same tensor after the sampler. Sharing the numbers would have been
/// the fourth instance of the documented failure mode; sharing the *type* would have
/// risked Boltz's behaviour to save a few lines.
///
/// This guard does not fit a curve at all. It interpolates between measured points and
/// refuses beyond the last one, so it can never be optimistic about a size nobody has
/// run — the failure mode is "refuses something that would have worked", which costs a
/// user a message rather than their unsaved session.
enum ProtenixSizeGuard {

    /// (residues, peak MiB) at the shipped operating point — recycling 10 / 200 steps,
    /// confidence head included — for the base int8 pack on an M-series Mac.
    ///
    /// Measured against MLX's own high-water mark, NOT process RSS. That distinction is
    /// load-bearing: measured by RSS the same sweep reads 444 MiB at 60 residues and
    /// 323 MiB at 400, i.e. *falling* with problem size, because MLX allocates through
    /// Metal and recycles buffers in a cache it need not return to the OS. A guard fitted
    /// to those numbers would have concluded big inputs are cheap.
    static let measured: [(tokens: Int, peakMiB: Int)] = [
        (60, 547), (120, 942), (250, 2279), (400, 3868), (550, 6303), (700, 8622),
    ]

    /// Hard ceiling, matching `pymol.predictors.protenix.MAX_RESIDUES`.
    ///
    /// Now the largest length actually MEASURED, rather than below it. It was 400 —
    /// chosen because 700 costs 8.6 GB and six minutes for a structure whose own
    /// confidence is 26 — and was raised deliberately: that is a judgement about whether
    /// a fold is worth the wait, which belongs to whoever is waiting.
    ///
    /// It is still not an extrapolation. 700 is measured; beyond it nothing has been run,
    /// and `PredictSizeGuard`'s docstring records three separate occasions where guessing
    /// past the data ran optimistic. Both ends enforce this: Python refuses before the
    /// download, this refuses before the tensors.
    static let maximumTokens = 700

    /// The most memory one fold may target.
    ///
    /// Raised to 32 GB by request, from the previous `0.75 × physical`. On a 32 GiB
    /// machine that is effectively all of it, which is a deliberate trade and worth
    /// naming: MLX allocating to the ceiling while the app holds a session is how a
    /// jetsam SIGKILL happens, and that kill is asynchronous — no Swift handler can
    /// intercept it, and on macOS it takes the user's unsaved work with it. The mitigation
    /// is to save before a long fold, not to catch anything.
    ///
    /// Lower it here to go back to the conservative behaviour; the fractions below are
    /// applied to THIS rather than to physical memory, so one number moves the whole
    /// policy.
    static let budgetBytes = 32 * 1024 * 1024 * 1024

    /// Same tiers as `PredictSizeGuard`, deliberately: whatever fraction of a machine is
    /// prudent to hand one MLX model does not depend on which model it is.
    static let okFraction = PredictSizeGuard.okFraction
    static let warnFraction = PredictSizeGuard.warnFraction

    /// Peak bytes for `tokens`, by linear interpolation between measured points.
    ///
    /// Below the first point the first point's cost is used rather than scaling down to
    /// zero: ~500 MiB of that is the weight pack, which a 4-residue peptide pays in full.
    static func estimatedBytes(tokens: Int) -> Int {
        let mib = estimatedPeakMiB(tokens: tokens)
        return mib * 1024 * 1024
    }

    static func estimatedPeakMiB(tokens: Int) -> Int {
        guard let first = measured.first, let last = measured.last else { return 0 }
        if tokens <= first.tokens { return first.peakMiB }
        if tokens >= last.tokens {
            // Only reachable above `maximumTokens`, which `decide` refuses first. Kept
            // honest rather than extrapolating: the last measured cost, not a guess.
            return last.peakMiB
        }
        for (low, high) in zip(measured, measured.dropFirst()) {
            guard tokens >= low.tokens, tokens <= high.tokens else { continue }
            let span = Double(high.tokens - low.tokens)
            let position = Double(tokens - low.tokens) / span
            let cost = Double(low.peakMiB)
                + position * Double(high.peakMiB - low.peakMiB)
            return Int(cost.rounded(.up))
        }
        return last.peakMiB
    }

    /// Refuse, caution, or proceed. `nil`-free: every outcome is a case.
    ///
    /// `availableBytes` is what the machine has; the fold is sized against
    /// `min(budgetBytes, availableBytes)`, so a smaller machine is still protected by its
    /// own memory and a larger one is still bounded by the budget.
    static func decide(tokens: Int, availableBytes: Int) -> PredictSizeGuard.Decision {
        let budget = min(budgetBytes, availableBytes)
        guard tokens <= maximumTokens else {
            return .refuse(maxFittingTokens: min(maximumTokens,
                                                 largestFittingTokenCount(budget)))
        }
        let estimate = estimatedBytes(tokens: tokens)
        let fraction = Double(estimate) / Double(max(budget, 1))
        if fraction <= okFraction { return .ok }
        if fraction <= warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: budget)
        }
        return .refuse(maxFittingTokens: largestFittingTokenCount(budget))
    }

    /// The largest token count whose estimate stays inside the warn budget.
    static func largestFittingTokenCount(_ availableBytes: Int) -> Int {
        let budget = Int(Double(availableBytes) * warnFraction)
        var best = 0
        var tokens = 1
        while tokens <= maximumTokens {
            if estimatedBytes(tokens: tokens) <= budget { best = tokens } else { break }
            tokens += 1
        }
        return best
    }
}
#endif
