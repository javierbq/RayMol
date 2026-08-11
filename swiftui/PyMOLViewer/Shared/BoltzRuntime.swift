#if os(macOS)
import Foundation

/// Structure prediction's MLX policy. The process-wide MLX configuration itself lives
/// in ``MLXRuntime``; this type contributes only the numbers prediction requires.
///
/// Registering rather than assigning is load-bearing. boltz-mlx's own
/// `MemoryPlanner.apply()` assigns `Memory.cacheLimit` on **every** predict call, and
/// `MLXRuntime` keeps the most conservative ceiling any owner requires — so a
/// prediction-side ask can never raise Design mode's 96 MB and get the app
/// jetsam-killed. If this type wrote MLX directly, whoever ran last would win,
/// silently and by call order.
enum BoltzRuntime {

    /// Larger than Design mode's ceiling: the trunk's pairwise tensors reuse big
    /// buffers, and a Mac is not jetsam-constrained the way a phone is. This is a
    /// *request*, not a claim — ``MLXRuntime`` resolves any disagreement downward.
    static let cacheLimitBytes = 256 * 1024 * 1024

    /// Identifies this requirement in ``MLXRuntime/cacheLimitRequirements``.
    static let cacheLimitOwner = "Boltz"

    /// Idempotent; safe from any thread. Call before constructing a `BoltzPredictor`.
    static func configureOnce() {
        MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
    }

    /// Run `body` with MLX errors surfaced as Swift `throws` rather than terminating
    /// the process. Does **not** protect against jetsam — see ``PredictSizeGuard``.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try MLXRuntime.withMLXErrorsAsThrows(body)
    }
}
#endif
