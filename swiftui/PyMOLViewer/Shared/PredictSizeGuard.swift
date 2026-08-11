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
/// Constants are fitted to boltz-mlx's measured M3 Pro peaks at recycling 3 / 50 steps:
/// 20 tokens → 0.61 GB, 117 → 2.24 GB, 225 → 3.47 GB.
///
/// **The fit is dominated by a large constant, not by curvature, and that is
/// counter-intuitive.** Runtime is super-linear in tokens (the pairwise tensors are ~N²),
/// so the obvious move is a quadratic-heavy memory fit — but solving for a quadratic
/// coefficient against the 117- and 225-token points yields a *negative* one: going from
/// 117 to 225 tokens nearly doubles the input while peak memory rises only ~55%, because
/// the ~505 MiB weight pack plus allocator overhead dominates this range. So the model is
/// a large intercept plus a linear term, with only a small quadratic term to keep
/// extrapolation beyond the measured range (where the pairwise tensors should reassert)
/// from being optimistic.
///
/// Retune all four constants together from new device data, and **never let the fit sit
/// below measurement** — a guard that under-predicts licenses a run that dies. That is
/// what `PredictSizeGuardTests.testEstimateTracksTheMeasuredCurve` exists to catch, and
/// it caught exactly this on the first attempt.
enum PredictSizeGuard {

    // MARK: - Tunable constants

    /// Model-resident floor: the ~505 MiB int8 pack plus graph and allocator overhead,
    /// with margin. Most of a small prediction's footprint is here, not in the input.
    static let fixedOverheadBytes = 1000 * 1024 * 1024
    /// Linear term, bytes per token. Endpoint-to-endpoint slope of the measured curve
    /// between 117 and 225 tokens, rounded up.
    static let bytesPerToken = 13_000_000
    /// Small quadratic term, bytes per token². Deliberately modest: it does not fit the
    /// measured range (see above) and exists to keep extrapolation conservative.
    static let bytesPerTokenSquared = 2_000
    /// At or below this fraction of available memory, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction, refuse.
    static let warnFraction = 0.75
    /// Hard ceiling regardless of memory. `BoltzInputLimits.desktop` stops at 1024
    /// tokens, and nothing above ~384 has ever been validated for quality.
    static let maximumTokens = 1024

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
