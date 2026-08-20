#if os(macOS) || os(iOS)
import Foundation
#if os(iOS)
import os   // os_proc_available_memory()
#endif

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

    /// MLX buffer-cache ceiling this feature requests. A *request*, not a claim —
    /// ``MLXRuntime`` resolves any disagreement downward (min-wins).
    ///
    /// **macOS — 256 MB.** Larger than Design mode's ceiling: the trunk's pairwise
    /// tensors reuse big buffers, and a Mac is not jetsam-constrained the way a phone
    /// is.
    ///
    /// **iOS — 64 MB.** Lower than Design mode's 96 MB, and lower on purpose. The cache
    /// is retained memory that counts against `phys_footprint`, which is the number
    /// jetsam kills on; a fold's own tensors already run to ~1.4 GB against an app
    /// budget of roughly 2–3 GB, so cache is the cheapest gigabyte-fraction to give
    /// back. The asymmetry documented on ``MLXRuntime/requireCacheLimit(_:owner:)``
    /// applies directly: too low costs allocator churn — slower, never fatal — while too
    /// high risks an uncatchable SIGKILL. 64 MB is also boltz-mlx's own phone default
    /// (`MemoryPlanner.init`), so this asks for no more than upstream sized for a phone.
    ///
    /// Because arbitration is min-wins and process-global, on iOS this ALSO pulls Design
    /// mode's effective ceiling from 96 MB to 64 MB whenever both are registered. That is
    /// the intended direction and is safe by construction — a smaller cache cannot make
    /// Design fail, only churn — but it is a real behaviour change on iOS and is called
    /// out here rather than left to be discovered.
    static var cacheLimitBytes: Int {
        #if os(iOS)
        return 64 * 1024 * 1024
        #else
        return 256 * 1024 * 1024
        #endif
    }

    #if os(iOS)
    /// The `MLX.Memory.memoryLimit` a phone run should install, in bytes.
    ///
    /// This exists to convert an *uncatchable* failure into a catchable one. Past this
    /// ceiling MLX reports an allocation failure, which ``withMLXErrorsAsThrows(_:)``
    /// turns into a Swift `throw` that ``BoltzJobManager`` can fail the job on; without
    /// it the same overshoot arrives as a jetsam SIGKILL that kills the app and the
    /// unsaved session. boltz-mlx's own default is 6 GB — a desktop number that on a
    /// phone sits far above the point where the OS has already killed us, so it can
    /// never fire.
    ///
    /// Set to the app's whole jetsam ceiling (`available + already used`) rather than to
    /// this run's budget, and that choice is deliberate on two counts:
    ///
    /// - `MLX.Memory.memoryLimit` is **process-global and not arbitrated** by
    ///   ``MLXRuntime`` (which mediates only `cacheLimit`). A ceiling sized to one Boltz
    ///   run would outlive the run and clamp Design mode's next inference too. Sizing it
    ///   to the device ceiling leaves every other MLX consumer exactly as it was, because
    ///   nothing may legitimately exceed that number anyway.
    /// - Per-input budgeting is ``PredictSizeGuard``'s job, and it runs *before* the job
    ///   is submitted. This is the backstop underneath it, not a second opinion.
    ///
    /// Read live at configure time, not cached: `os_proc_available_memory()` moves with
    /// whatever structures are loaded, and a value captured at launch would be stale by
    /// the time a session has a target open in it.
    static var memoryLimitBytes: Int {
        let footprint = MLXRuntime.currentFootprintBytes
        let available = os_proc_available_memory()
        // Floor at 1 GB so a pathological reading (footprint unavailable, or a device
        // already near its limit) cannot install a ceiling so low that MLX refuses to
        // load the weights at all — that would turn a memory backstop into a hard
        // "prediction is broken", which is a worse failure than the one it prevents.
        return max(1024 * 1024 * 1024, available + footprint)
    }
    #endif

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
