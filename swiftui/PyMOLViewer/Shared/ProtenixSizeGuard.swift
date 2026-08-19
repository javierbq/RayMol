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
///
/// **One curve per variant, because one curve for both was optimistic for v2** (#316).
/// Until that ticket this type held base's numbers and sized every Protenix fold with
/// them, v2 included. v2's pair track is 256 wide against base's 128, so its N² term is
/// roughly doubled, and the shortfall was real at every length that has now been
/// measured: 738 MiB against base's 547 at 60 residues, 2777 against 2279 at 250. That
/// is the same shape as the three shortfalls ``PredictSizeGuard`` records in its own
/// docstring — a curve applied past the data it was fitted to, running optimistic — and
/// optimistic is the direction that ends in a jetsam SIGKILL rather than a message.
enum ProtenixSizeGuard {

    /// Which pack a fold runs, and therefore which measured curve sizes it.
    ///
    /// Two variants ship at three precisions each; precision is absent here on purpose,
    /// because it is not what decides the peak. The weights differ by ~2x between int8
    /// and fp16, but the N² pair representation dwarfs them as the input grows — the
    /// tiny, mini and base packs measured within 10% of each other at 400 residues
    /// despite very different parameter counts. What separates base from v2 is the
    /// WIDTH of that pair tensor, which is a property of the variant.
    enum Variant {

        case base
        case v2

        /// The variant a weights directory holds, read off the bundle id in its path.
        ///
        /// Defaults to the EXPENSIVE variant, not the cheap one. A path this does not
        /// recognise means the guard does not know what it is about to size, and the
        /// only safe reading of "I do not know" is the curve that refuses soonest.
        /// Getting this backwards would make a typo in a bundle id silently license a
        /// fold against numbers from a smaller model.
        init(weightsDirectory: String) {
            self = weightsDirectory.contains("protenix-base-mlx") ? .base : .v2
        }

        /// (residues, peak MiB) at this pack's shipped operating point — recycling 10 /
        /// 200 steps, confidence head included — on an M-series Mac.
        var measured: [(tokens: Int, peakMiB: Int)] {
            switch self {
            case .base: return ProtenixSizeGuard.measured
            case .v2: return ProtenixSizeGuard.measuredV2
            }
        }

        /// Hard ceiling, matching this variant's cap in
        /// `pymol.predictors.protenix` (MAX_RESIDUES / V2_MAX_RESIDUES).
        var maximumTokens: Int {
            switch self {
            case .base: return ProtenixSizeGuard.maximumTokens
            case .v2: return ProtenixSizeGuard.maximumTokensV2
            }
        }
    }

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
        // 900 fits — 16.1 GiB, half the budget — and took 2.5 HOURS: 24x the wall clock
        // of 700 for 1.3x the length, because at 16 GiB on a 32 GiB machine the fold
        // starts paging. Kept in the table because interpolation between 700 and 900 is
        // then real rather than fitted, even though `maximumTokens` stops at 700.
        (900, 16513),
    ]

    /// Hard ceiling, matching `pymol.predictors.protenix.MAX_RESIDUES`.
    ///
    /// Now the largest length actually MEASURED, rather than below it. It was 400 —
    /// chosen because 700 costs 8.6 GB and six minutes for a structure whose own
    /// confidence is 26 — and was raised deliberately: that is a judgement about whether
    /// a fold is worth the wait, which belongs to whoever is waiting.
    ///
    /// Below the largest measurement (900) on purpose, and for a reason only measuring
    /// found: 900 residues FITS, at 16.1 GiB against a 32 GB budget, and takes 2.5 hours.
    /// That is 24x the wall clock of 700 for 1.3x the length — the fold stops being
    /// compute-bound and starts paging — for a structure whose own confidence is 26.4.
    /// The ceiling is therefore "where the time stops being worth it" rather than "where
    /// the data runs out". Both ends enforce it: Python refuses before the download, this
    /// refuses before the tensors.
    static let maximumTokens = 700

    /// v2's curve, measured the same way and at the same lengths as base's.
    ///
    /// Produced by `scripts/protenix_memory_sweep.py`, whose control run reproduced
    /// base's committed numbers to within 3.5% before any of this was recorded — a v2
    /// row from a harness that cannot reproduce base is evidence about the harness, not
    /// about v2.
    ///
    /// It sits ABOVE base at every length, by 35% at 60 residues and 22% at 250, which
    /// is exactly why the two cannot share a table.
    static let measuredV2: [(tokens: Int, peakMiB: Int)] = [
        (60, 738), (120, 1649), (250, 2777), (400, 5914), (550, 9068),
    ]

    /// v2's hard ceiling, matching `pymol.predictors.protenix.V2_MAX_RESIDUES`.
    ///
    /// The largest length v2 has been RUN at, and no further — the same rule base's cap
    /// follows. It was 250, chosen as a placeholder well inside what had been run
    /// because v2 had been swept at a single point (15 residues) and base's curve
    /// understates it. The sweep now exists, so the ceiling is data again rather than
    /// caution.
    static let maximumTokensV2 = 550

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
    static func estimatedBytes(tokens: Int, variant: Variant = .base) -> Int {
        let mib = estimatedPeakMiB(tokens: tokens, variant: variant)
        return mib * 1024 * 1024
    }

    static func estimatedPeakMiB(tokens: Int, variant: Variant = .base) -> Int {
        let measured = variant.measured
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
    /// `variant` has no default, deliberately. A default is precisely how this type came
    /// to size v2 folds with base's numbers: every call reads as if it had said which
    /// pack it meant, and none of them had. The estimate helpers below still default,
    /// because they are inspection rather than a gate on a real fold.
    static func decide(tokens: Int, variant: Variant,
                       availableBytes: Int) -> PredictSizeGuard.Decision {
        let budget = min(budgetBytes, availableBytes)
        let maximumTokens = variant.maximumTokens
        guard tokens <= maximumTokens else {
            return .refuse(maxFittingTokens: min(
                maximumTokens, largestFittingTokenCount(budget, variant: variant)))
        }
        let estimate = estimatedBytes(tokens: tokens, variant: variant)
        let fraction = Double(estimate) / Double(max(budget, 1))
        if fraction <= okFraction { return .ok }
        if fraction <= warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: budget)
        }
        return .refuse(maxFittingTokens: largestFittingTokenCount(budget,
                                                                   variant: variant))
    }

    /// The largest token count whose estimate stays inside the warn budget.
    static func largestFittingTokenCount(_ availableBytes: Int,
                                         variant: Variant = .base) -> Int {
        let budget = Int(Double(availableBytes) * warnFraction)
        var best = 0
        var tokens = 1
        while tokens <= variant.maximumTokens {
            if estimatedBytes(tokens: tokens, variant: variant) <= budget {
                best = tokens
            } else {
                break
            }
            tokens += 1
        }
        return best
    }
}
#endif
