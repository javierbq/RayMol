#if os(macOS)
import Foundation

/// RFdiffusion3's MLX policy, registered rather than assigned.
///
/// The mirror of ``BoltzRuntime`` and ``ProtenixRuntime``, and separate from both for the
/// reason those types' docstrings give: ``MLXRuntime`` keeps the most conservative cache
/// ceiling any owner requires, so each runtime must register under its OWN name.
/// Registering under someone else's would overwrite their requirement rather than being
/// arbitrated against it, and whichever ran last would win — silently, by call order.
///
/// ### RFD3Kit sets its own limits during a rollout, and that is fine
///
/// `Sampler.generate` wraps the whole rollout in `MLXLimits.withLimits(cacheLimit: 96 MB,
/// memoryLimit: 4 GB)` and restores whatever it found on the way out — including on a
/// throw. So the ceiling registered here governs the pack LOAD and anything outside the
/// rollout, while the rollout runs under RFD3Kit's own measured pair. Two consequences
/// worth knowing rather than rediscovering:
///
/// * Another MLX workload running concurrently with a design — an MPNN score, a Boltz
///   fold — sees 96 MB / 4 GB for the duration. Nothing is left in that state afterwards,
///   but a fold that overlaps a design is tuned by the design.
/// * `memoryLimit` does not bound allocation. mlx's Metal allocator reads it only to
///   decide when to reclaim cached buffers; `malloc` never consults it. It reduces the
///   peak, it cannot prevent an out-of-memory abort. That is ``RFD3SizeGuard``'s job.
enum RFD3Runtime {

    /// Cache ceiling for the pack load. Modest, because the load is one sequential
    /// safetensors read of 672 MB into MLX arrays and has no reusable intermediates worth
    /// keeping — unlike Protenix's pair track, which is why that runtime asks for 512 MB.
    /// Still a *request*: ``MLXRuntime`` resolves any disagreement downward, so Design
    /// mode's 96 MB ceiling cannot be raised by this.
    static let cacheLimitBytes = 256 * 1024 * 1024

    /// Identifies this requirement in ``MLXRuntime/cacheLimitRequirements``.
    static let cacheLimitOwner = "RFD3"

    /// Idempotent; safe from any thread. Call before loading a pack.
    static func configureOnce() {
        MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
    }

    /// Run `body` with MLX errors surfaced as Swift `throws` rather than terminating the
    /// process. Does **not** protect against the out-of-memory abort — see
    /// ``RFD3SizeGuard`` for why that one is unreachable from a `catch`.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try MLXRuntime.withMLXErrorsAsThrows(body)
    }
}
#endif
