#if os(macOS)
import Foundation

/// Protenix's MLX policy, registered rather than assigned.
///
/// The mirror of ``BoltzRuntime``, and separate from it for the reason that type's own
/// docstring gives: ``MLXRuntime`` keeps the most conservative ceiling any owner
/// requires, so each runtime must register under its OWN name. Registering under
/// `"Boltz"` would overwrite Boltz's requirement rather than being arbitrated against
/// it, and whichever ran last would win — silently, and by call order.
enum ProtenixRuntime {

    /// Larger than Boltz's 256 MB request, because Protenix leans on the pair
    /// representation harder: 48 Pairformer blocks over an N×N×c_z tensor, ten recycles,
    /// then a confidence head over the same tensor. Bigger reusable buffers are exactly
    /// what the cache exists to keep. Still a *request* — ``MLXRuntime`` resolves any
    /// disagreement downward, so Design mode's 96 MB ceiling cannot be raised by this.
    static let cacheLimitBytes = 512 * 1024 * 1024

    /// Identifies this requirement in ``MLXRuntime/cacheLimitRequirements``.
    static let cacheLimitOwner = "Protenix"

    /// Idempotent; safe from any thread. Call before constructing a predictor.
    static func configureOnce() {
        MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
    }

    /// Run `body` with MLX errors surfaced as Swift `throws` rather than terminating the
    /// process. Does **not** protect against jetsam — see ``ProtenixSizeGuard``.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try MLXRuntime.withMLXErrorsAsThrows(body)
    }
}
#endif
