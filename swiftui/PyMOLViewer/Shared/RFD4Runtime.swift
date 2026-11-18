#if os(macOS)
import Foundation

/// RFD4-Proteina's MLX policy, registered rather than assigned.
///
/// The mirror of ``BoltzRuntime``, ``ProtenixRuntime`` and ``RFD3Runtime``, and separate
/// from all three for the reason those types' docstrings give: ``MLXRuntime`` keeps the
/// most conservative cache ceiling any owner requires, so each runtime must register
/// under its OWN name. Registering under someone else's would overwrite their requirement
/// rather than being arbitrated against it, and whichever ran last would win — silently,
/// by call order.
///
/// ### Unlike RFD3Kit, this engine sets no limits of its own
///
/// `RFD3Runtime` documents that `Sampler.generate` wraps its rollout in
/// `MLXLimits.withLimits(cacheLimit: 96 MB, memoryLimit: 4 GB)` and restores what it
/// found on the way out, so the ceiling registered there governs only the pack load. The
/// RFD4 port does no such thing: it never touches `GPU.set(cacheLimit:)` or
/// `GPU.set(memoryLimit:)` anywhere, so what is registered here governs the WHOLE run,
/// load and trajectory alike.
///
/// Two consequences worth knowing rather than rediscovering:
///
/// * The ceiling is a real constraint on a 60-step trajectory rather than on a one-off
///   read, which is why it is larger than RFD3's 256 MB. The trunk reuses pair-track
///   buffers across steps, and a cache too small to hold them turns reuse into
///   reallocation on every step of all sixty.
/// * It does not bound allocation and cannot prevent an out-of-memory abort. mlx's Metal
///   allocator reads a cache limit to decide when to reclaim cached buffers; `malloc`
///   never consults it. Reducing the peak is ``RFD4SizeGuard``'s job, and it does it by
///   refusing the input rather than by tuning the allocator.
enum RFD4Runtime {

    /// Cache ceiling for a design: the pack load AND the trajectory, since this engine
    /// sets no limits of its own.
    ///
    /// 512 MB rather than RFD3's 256 MB, and the reason is the shape of the work rather
    /// than its size. RFD3's figure covers a sequential safetensors read with no reusable
    /// intermediates worth keeping. Here the same ceiling has to span sixty steps that
    /// each read and rewrite an `[n, n, c]` pair track, and those buffers are exactly the
    /// ones a cache exists to keep.
    ///
    /// Still a *request*: ``MLXRuntime`` resolves any disagreement downward, so Design
    /// mode's 96 MB ceiling cannot be raised by this.
    static let cacheLimitBytes = 512 * 1024 * 1024

    /// Identifies this requirement in ``MLXRuntime/cacheLimitRequirements``.
    ///
    /// Its own name, NOT "RFD3". The two runtimes can both be resident in one session —
    /// nothing stops a user generating with one method and then the other — and sharing
    /// an owner name would make the second registration overwrite the first's
    /// requirement instead of being arbitrated against it.
    static let cacheLimitOwner = "RFD4"

    /// Idempotent; safe from any thread. Call before loading a pack.
    static func configureOnce() {
        MLXRuntime.requireCacheLimit(cacheLimitBytes, owner: cacheLimitOwner)
    }

    /// Run `body` with MLX errors surfaced as Swift `throws` rather than terminating the
    /// process. Does **not** protect against the out-of-memory abort — see
    /// ``RFD4SizeGuard`` for why that one is unreachable from a `catch`.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try MLXRuntime.withMLXErrorsAsThrows(body)
    }
}
#endif
