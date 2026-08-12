#if os(macOS)
import Foundation

/// Predicts the peak memory a Boltz run needs and decides whether to proceed, warn, or
/// refuse.
///
/// This exists because boltz-mlx's own preflight cannot be relied on. Its activation
/// estimate under-predicts measured peaks by **10–25×** (115 tokens / 889 atoms
/// estimates ~60 MB against a measured 1.43 GB; 384 tokens estimates ~622 MB against a
/// measured 6.84 GB), and under its phone defaults the memory check can never fire at
/// all because the token cap always binds first. Its own handoff notes concede the
/// limits are "conservative estimates, not measurements".
///
/// It stays **preventive** rather than reactive for the same reason `DesignSizeGuard`
/// does: ``MLXRuntime/withMLXErrorsAsThrows(_:)`` makes MLX-*reported* errors catchable,
/// but a jetsam SIGKILL is an asynchronous OS kill that no Swift handler can intercept —
/// and on macOS that takes the user's unsaved session with it, not just the job.
///
/// Constants are fitted to RayMol's own measured MLX peak memory on an M3 Pro / 36 GiB at
/// the shipped operating point (recycling 3 / 200 steps, Release, single chain, no MSA),
/// swept 60→900 residues — see `PredictSizeGuardTests.measured` for the full table.
///
/// **This guard has been wrong in the optimistic direction twice, both times for the same
/// reason: the fit was extrapolating past its data.** That history is the point, not
/// trivia — it is the failure mode to design against:
///
/// 1. Fitted against boltz-mlx's published 117- and 225-token figures, memory looks
///    *sub*-linear — solving for a quadratic coefficient there even yields a negative one,
///    because the weight pack dominates that range. That fit ran **27% optimistic at 600
///    residues**.
/// 2. Refitted to 600, it ran **27% optimistic again at 900** — identically wrong, one
///    level up, because the pairwise ~N² term keeps steepening.
///
/// The current constants cover every measured point from 60 to 900 with no shortfall and at
/// most 1.50× conservatism. **Do not extrapolate past 900 either.** If a larger input must
/// be supported, measure it first; the honest ceiling is ``maximumTokens``, set to what has
/// actually been measured.
///
/// Retune all four together from new device data, and **never let the fit sit below
/// measurement** — that is what licenses a run which then gets jetsam-killed.
/// `testEstimateNeverSitsBelowMeasurement` pins the whole table for exactly this reason; an
/// earlier version pinned only two points, which is how shortfall #1 survived.
enum PredictSizeGuard {

    // MARK: - Tunable constants

    /// Model-resident floor. Small, because the linear and quadratic terms now carry the
    /// curve across the whole measured range instead of the intercept papering over the
    /// small end.
    static let fixedOverheadBytes = 200 * 1024 * 1024
    /// Linear term, bytes per token.
    static let bytesPerToken = 14_500_000
    /// Quadratic term, bytes per token² — the pairwise tensors. 12.5× the original value;
    /// see the type doc for the two successive under-predictions that produced it.
    static let bytesPerTokenSquared = 25_000
    /// At or below this fraction of available memory, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction, refuse.
    static let warnFraction = 0.75
    /// Hard ceiling regardless of memory: the largest input actually MEASURED end to end
    /// (900 residues → 32.71 GB peak, 42 min of inference). `BoltzInputLimits.desktop`
    /// would allow 1024, but the estimate there is ~41 GB — beyond a 36 GiB machine — and
    /// nothing above ~384 has ever been validated for structural quality. Raise this only
    /// alongside a measurement, never alongside an extrapolation.
    static let maximumTokens = 900

    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingTokens: Int)
    }

    /// Fitted peak-memory estimate.
    static func estimatedBytes(tokens: Int) -> Int {
        fixedOverheadBytes
            + tokens * bytesPerToken
            + tokens * tokens * bytesPerTokenSquared
    }

    static func decide(tokens: Int, availableBytes: Int) -> Decision {
        guard tokens <= maximumTokens else {
            return .refuse(maxFittingTokens: min(maximumTokens,
                                                 largestFittingTokenCount(availableBytes)))
        }
        let estimate = estimatedBytes(tokens: tokens)
        let fraction = Double(estimate) / Double(max(availableBytes, 1))
        if fraction <= okFraction { return .ok }
        if fraction <= warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
        }
        return .refuse(maxFittingTokens: largestFittingTokenCount(availableBytes))
    }

    /// Physical memory, as the budget the estimate is compared against.
    static var availableBytes: Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    private static func largestFittingTokenCount(_ availableBytes: Int) -> Int {
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
