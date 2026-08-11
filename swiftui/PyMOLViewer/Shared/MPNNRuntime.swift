#if RAYMOL_MPNN
import Foundation

/// Design mode's MLX policy. The process-wide MLX configuration itself lives in
/// ``MLXRuntime`` — this type contributes only the numbers Design mode requires and
/// forwards everything else, so that a second MLX consumer (structure prediction, under
/// RAYMOL_BOLTZ) cannot silently clobber them by call order.
///
/// The cache-limit value below was established by the proteinmpnn-ios bench harness
/// (app/MPNNBench/MPNNBenchApp.swift) and is a prerequisite for running inference on iOS
/// at all — see docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §6.1.
///
/// Error handling and the Simulator caveat are documented on ``MLXRuntime``. In short:
/// MLX-reported errors are catchable via ``withMLXErrorsAsThrows(_:)`` and must wrap every
/// call that can touch MLX, including model construction (`MPNNModel(packDirectory:)`);
/// a jetsam SIGKILL is not catchable, which is why `DesignSizeGuard` stays preventive.
enum MPNNRuntime {

    /// Ceiling on MLX's buffer cache. Without it the pool was measured above 5 GB
    /// at L~1000, which is a guaranteed jetsam kill on any iPhone.
    static let cacheLimitBytes = 96 * 1024 * 1024

    /// Identifies Design mode's requirement in ``MLXRuntime/cacheLimitRequirements``.
    static let cacheLimitOwner = "MPNN"

    /// Idempotent; safe to call from any thread. Call before the first MPNNKit call.
    ///
    /// Registering rather than assigning is what makes this safe alongside boltz-mlx,
    /// whose `MemoryPlanner.apply()` assigns `Memory.cacheLimit` on every predict:
    /// ``MLXRuntime/requireCacheLimit(_:owner:)`` keeps the most conservative ceiling, so
    /// a larger prediction-side ask can never raise Design mode's 96 MB.
    static func configureOnce() {
        MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
    }

    /// The active MLX cache limit in bytes.
    ///
    /// Exposed for testing only so that the test target can verify `configureOnce()`
    /// actually installs the limit without importing MLX directly.
    static var activeCacheLimitBytes: Int { MLXRuntime.activeCacheLimitBytes }

    /// Run `body` with MLX errors surfaced as Swift `throws` instead of terminating the
    /// process. See ``MLXRuntime/withMLXErrorsAsThrows(_:)`` for the full semantics,
    /// including the non-fail-fast caveat.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try MLXRuntime.withMLXErrorsAsThrows(body)
    }
}
#endif
