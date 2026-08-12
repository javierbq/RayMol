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
/// swept 60→600 residues:
///
///     60 → 0.78 GB   200 → 3.48 GB   400 → 7.38 GB
///    100 → 1.76 GB   250 → 3.85 GB   450 → 7.90 GB
///    150 → 2.90 GB   300 → 4.64 GB   550 → 10.86 GB
///                    350 → 5.96 GB   600 → 13.11 GB
///
/// **The quadratic term is real, and the first version of this guard got that wrong.**
/// Fitted only against boltz-mlx's published 117- and 225-token figures, memory looks
/// *sub*-linear — solving for a quadratic coefficient there even yields a negative one,
/// because the ~505 MiB weight pack dominates that range. Extending the sweep to 600
/// residues shows the pairwise ~N² term reasserting hard: the earlier constants
/// (`B = 2_000`) under-predicted from 350 residues upward and were **27% optimistic at
/// 600** — precisely the direction that licenses a run which then gets jetsam-killed.
/// `B` is now 7× larger.
///
/// Retune all four together from new device data, and **never let the fit sit below
/// measurement**. `PredictSizeGuardTests.testEstimateNeverSitsBelowMeasurement` pins the
/// whole sweep for exactly this reason — the earlier test only pinned two points, which is
/// why the shortfall above 350 survived.
enum PredictSizeGuard {

    // MARK: - Tunable constants

    /// Model-resident floor: the ~505 MiB int8 pack plus graph and allocator overhead.
    /// Lower than the previous 1000 MiB because the quadratic term now carries the large
    /// end honestly rather than the intercept papering over it.
    static let fixedOverheadBytes = 700 * 1024 * 1024
    /// Linear term, bytes per token.
    static let bytesPerToken = 13_000_000
    /// Quadratic term, bytes per token² — the pairwise tensors. 7× the previous value:
    /// see the type doc for why the old figure under-predicted above 350 residues.
    static let bytesPerTokenSquared = 14_000
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
