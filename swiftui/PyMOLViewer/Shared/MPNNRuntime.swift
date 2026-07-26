#if RAYMOL_MPNN
import Foundation
import MLX

/// Process-wide MLX configuration. This is the ONLY file in RayMol that imports
/// MLX; everything else reaches MLX through MPNNKit.
///
/// Both settings below were established by the proteinmpnn-ios bench harness
/// (app/MPNNBench/MPNNBenchApp.swift) and are prerequisites for running inference
/// on iOS at all — see docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §6.1.
///
/// ### Error handling (mlx-swift 0.31.6 spike finding)
///
/// MLX-**reported** errors are catchable as of 0.31.6 via `withError()` /
/// `withErrorHandler()` (MLX/Source/MLX/ErrorHandler.swift). These install a
/// task-local Swift closure; `ErrorHandler.dispatch()` calls the closure and
/// returns — the handler does NOT need to terminate. Wrap every call that can
/// touch MLX — including model construction (`MPNNModel(packDirectory:)`) —
/// in `MPNNRuntime.withMLXErrorsAsThrows {}` so that MLX errors surface as
/// Swift `throws` instead of `fatalError`.
///
/// A **jetsam SIGKILL** is entirely different: it is an OS kill delivered asynchronously
/// when physical memory pressure exceeds the app's budget. `withError` cannot catch it —
/// the process is already dead. This is why `DesignSizeGuard` must remain preventive
/// rather than reactive: even though MLX errors are now catchable, jetsam is not.
enum MPNNRuntime {

    /// Ceiling on MLX's buffer cache. Without it the pool was measured above 5 GB
    /// at L~1000, which is a guaranteed jetsam kill on any iPhone.
    static let cacheLimitBytes = 96 * 1024 * 1024

    /// Applied exactly once, thread-safely: a `static let` initializer is run at
    /// most once by the runtime, which is precisely the semantics wanted here.
    private static let applied: Void = {
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
        // compute — so it builds heaps the Simulator forbids. MPNNKit requests no
        // device or stream of its own (verified), so there is nothing to override.
        //
        // Isolated to Design mode: launching with a structure loaded and Design never
        // entered produces no assertion; only entering Design does. So this is MLX,
        // not RayMol's Metal renderer.
        //
        // Consequence for verification: the Simulator can exercise Design's UI, entry
        // points and layout, but NOT inference. Anything touching MPNN requires real
        // hardware. The PYMOL_AUTODESIGN hook is still useful — it drives macOS and
        // real devices.
        //
        // ORDER MATTERS if this is ever revisited: setenv must precede anything that
        // can construct a Metal device, because MLX latches MLX_METAL_GPU_ARCH into a
        // function-local static on first read — first call wins.
        setenv("MLX_METAL_GPU_ARCH", "applegpu_g15g", 1)
        MLX.Device.setDefault(device: Device(.cpu))

        // Not setting Memory.cacheLimit here: assigning it constructs MLX's
        // MetalAllocator directly. Skipping it does not avoid the abort (see above),
        // but the clamp exists to bound GPU memory against jetsam and is meaningless
        // for a CPU default, so there is no reason to trip the allocator early.
        #else
        // Bound MLX's buffer cache on real devices, where it matters: unclamped the
        // pool was measured above 5 GB at L~1000, a guaranteed jetsam kill.
        MLX.Memory.cacheLimit = cacheLimitBytes
        #endif
    }()

    /// Idempotent; safe to call from any thread. Call before the first MPNNKit call.
    static func configureOnce() { _ = applied }

    /// The active MLX cache limit in bytes, as reported by ``MLX.Memory.cacheLimit``.
    ///
    /// Exposed for testing only so that the test target can verify `configureOnce()`
    /// actually installs the limit without importing MLX directly.
    static var activeCacheLimitBytes: Int { MLX.Memory.cacheLimit }

    /// Run `body` with MLX errors surfaced as Swift `throws` instead of terminating
    /// the process. mlx-swift's default behaviour is `fatalError` when no handler is
    /// installed (`ErrorHandler.dispatch` in mlx-swift 0.31.6); wrapping here makes
    /// MLX-reported errors catchable so `DesignController`'s do/catch can set
    /// `errorText` and display the banner rather than crashing.
    ///
    /// Use this for every call that can touch MLX — including model construction
    /// (`MPNNModel(packDirectory:)`) — not only inference calls.
    ///
    /// **Non-fail-fast semantics**: `withError` records the first MLX error when it
    /// is reported but only throws at block exit. MPNNKit may continue computing on
    /// poisoned `MLXArray`s until the block returns (mlx-swift documents that using
    /// an array produced after an error "will likely result in additional errors").
    /// No wrong result can escape because `check()` always throws before the block's
    /// value is returned, but failure is not fail-fast.
    ///
    /// Note: this does NOT protect against jetsam — see class doc above.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try withError { try body() }
    }
}
#endif
