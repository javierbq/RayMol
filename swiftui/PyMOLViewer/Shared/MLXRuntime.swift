#if RAYMOL_MPNN || os(macOS)
import Foundation
import MLX

/// Process-wide MLX configuration, shared by every RayMol feature that runs MLX
/// inference. This is the ONLY file in RayMol that imports MLX; feature-specific
/// runtimes (`MPNNRuntime`, `BoltzRuntime`) sit on top of it and contribute their own
/// policy rather than writing MLX directly.
///
/// It exists because MLX's relevant knobs are **process-global**, and RayMol now has
/// more than one MLX consumer:
///
/// - Design mode (`MPNNRuntime`, RAYMOL_MPNN) needs `Memory.cacheLimit` at 96 MB.
/// - Structure prediction (macOS, unconditional) drives boltz-mlx, whose own
///   `MemoryPlanner.apply()` assigns `Memory.cacheLimit`/`memoryLimit` on **every**
///   predict call.
///
/// The gate is `RAYMOL_MPNN || os(macOS)` rather than a dedicated compilation condition:
/// structure prediction ships in every macOS build, so there is no flag to set, while the
/// `RAYMOL_MPNN` arm keeps this type available to Design mode on iOS.
///
/// With both linked, whoever wrote last used to win — silently, by call order, with no
/// way to observe or test the outcome. `MLXRuntime` arbitrates instead (see
/// ``requireCacheLimit(_:owner:)``).
///
/// ### Error handling (mlx-swift 0.31.6)
///
/// MLX-**reported** errors are catchable via `withError()` / `withErrorHandler()`
/// (MLX/Source/MLX/ErrorHandler.swift): these install a task-local Swift closure, and
/// `ErrorHandler.dispatch()` calls it and returns — the handler does NOT need to
/// terminate. Without one, mlx-swift's default behaviour is `fatalError`. Wrap every call
/// that can touch MLX — including model construction — in
/// ``withMLXErrorsAsThrows(_:)`` so MLX errors surface as Swift `throws`.
///
/// A **jetsam SIGKILL** is entirely different: an OS kill delivered asynchronously when
/// physical memory pressure exceeds the app's budget. `withError` cannot catch it — the
/// process is already dead. That is why the per-feature size guards
/// (`DesignSizeGuard`, and prediction's equivalent) must stay *preventive* rather than
/// reactive, and why the cache-limit arbitration below is deliberately conservative.
enum MLXRuntime {

    // MARK: – Device configuration

    /// Applied exactly once, thread-safely: a `static let` initializer is run at most
    /// once by the runtime, which is precisely the semantics wanted here.
    private static let deviceConfigured: Void = {
        #if targetEnvironment(simulator)
        // KNOWN LIMITATION — MLX does not run in the iOS Simulator, and this block
        // does NOT make it work. Keep it anyway: it is the documented upstream
        // workaround, it is harmless, and it may be sufficient on other
        // Simulator/mlx-swift combinations.
        //
        // Measured on 2026-07-26, iPhone 17 Pro Simulator (iOS 26) + mlx-swift 0.31.6:
        // the first Design inference aborts with
        //   -[MTLSimDevice newHeapWithDescriptor:]:1226: failed assertion
        //   `MTLStorageModePrivate is required for heaps'
        // and it still aborts with `Device(.cpu)` as the default AND with the
        // Memory.cacheLimit assignment moved out of this path (both were tried).
        // Cause: MLX's allocator is Metal-backed regardless of the compute device —
        // Apple-silicon unified memory means arrays live in Metal buffers even for CPU
        // compute — so it builds heaps the Simulator forbids.
        //
        // ORDER MATTERS: setenv must precede anything that can construct a Metal
        // device, because MLX latches MLX_METAL_GPU_ARCH into a function-local static
        // on first read — first call wins. Hence this runs before any
        // requireCacheLimit() assignment, which would construct MLX's MetalAllocator.
        setenv("MLX_METAL_GPU_ARCH", "applegpu_g15g", 1)
        MLX.Device.setDefault(device: Device(.cpu))
        #endif
    }()

    /// Idempotent; safe to call from any thread. Call before the first MLX call.
    static func configureDeviceOnce() { _ = deviceConfigured }

    // MARK: – Arbitrated process-global cache limit

    private static let lock = NSLock()
    private static var requirements: [String: Int] = [:]

    /// Register the cache ceiling `owner` requires, and install the most conservative
    /// (smallest) ceiling any registered owner requires.
    ///
    /// **Min-wins, and the asymmetry is the whole point.** A cache limit that is too low
    /// costs only allocator churn — slower, never fatal. One that is too high risks a
    /// jetsam kill, which is uncatchable and takes the user's unsaved session with it. So
    /// when two features disagree, the safe resolution is the smaller number, regardless
    /// of who asked last. In particular a later, larger request must never RAISE a
    /// ceiling an earlier owner needs low.
    ///
    /// Re-registering the same `owner` replaces that owner's previous ask rather than
    /// accumulating — one feature revising its own requirement is not a conflict.
    static func requireCacheLimit(_ bytes: Int, owner: String) {
        configureDeviceOnce()
        lock.lock()
        defer { lock.unlock() }
        requirements[owner] = bytes
        let effective = requirements.values.min() ?? bytes
        // The INSTALL must happen under the same lock as the min computation. Computing
        // `effective` under the lock and assigning outside it is a lost update: two owners
        // racing can leave the LARGER ceiling installed while the registry min is smaller —
        // exactly the "a later larger request raised a ceiling someone needs low"
        // regression this type exists to forbid. Serial tests cannot catch it.
        #if targetEnvironment(simulator)
        // Deliberately NOT assigning Memory.cacheLimit: doing so constructs MLX's
        // MetalAllocator directly. Skipping it does not avoid the Simulator abort
        // documented above, but the clamp exists to bound GPU memory against jetsam and
        // is meaningless for a CPU default, so there is no reason to trip the allocator
        // early. The requirement is still recorded, so the bookkeeping stays testable.
        _ = effective
        #else
        MLX.Memory.cacheLimit = effective
        #endif
    }

    /// The active MLX cache limit in bytes, as reported by `MLX.Memory.cacheLimit`.
    ///
    /// Exposed so the test target can verify the limit is genuinely installed without
    /// importing MLX itself.
    static var activeCacheLimitBytes: Int { MLX.Memory.cacheLimit }

    /// Every registered owner's ask, so a disagreement can be diagnosed rather than
    /// inferred from call order.
    static var cacheLimitRequirements: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return requirements
    }

    /// Clears the registry so a test can assert arbitration from a known state.
    ///
    /// Not `#if DEBUG`: the test bundle may be built against a Release host, and
    /// `DesignController`'s existing `inject*` seams are likewise ungated. Clearing the
    /// registry cannot un-set `MLX.Memory.cacheLimit` — a caller that needs a specific
    /// installed value must re-register it (e.g. `MPNNRuntime.configureOnce()`).
    static func resetCacheLimitRequirementsForTesting() {
        lock.lock(); defer { lock.unlock() }
        requirements.removeAll()
    }

    // MARK: – Error handling

    /// Run `body` with MLX errors surfaced as Swift `throws` instead of terminating the
    /// process.
    ///
    /// **Non-fail-fast semantics**: `withError` records the first MLX error when it is
    /// reported but only throws at block exit. The wrapped library may continue computing
    /// on poisoned `MLXArray`s until the block returns (mlx-swift documents that using an
    /// array produced after an error "will likely result in additional errors"). No wrong
    /// result can escape because `check()` always throws before the block's value is
    /// returned, but failure is not fail-fast.
    ///
    /// Note: this does NOT protect against jetsam — see the type doc above.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try withError { try body() }
    }
}
#endif
