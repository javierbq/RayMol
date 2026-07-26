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
/// returns — the handler does NOT need to terminate. Wrap every inference call
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
        MLX.GPU.set(cacheLimit: cacheLimitBytes)

        #if targetEnvironment(simulator)
        // The iOS Simulator's Metal cannot allocate MLX's private-storage heaps
        // (MTLStorageModePrivate assertion), and its architecture()->name() is null
        // (std::string(nullptr) abort under iOS 26 libc++ hardening). Force the CPU
        // backend and supply an arch string so the pipeline can run in the Simulator.
        // Real devices use the GPU — this block is simulator-only, and without it the
        // first inference in any simulator ABORTS the process rather than throwing.
        setenv("MLX_METAL_GPU_ARCH", "applegpu_g15g", 1)
        MLX.Device.setDefault(device: Device(.cpu))
        #endif
    }()

    /// Idempotent; safe to call from any thread. Call before the first MPNNKit call.
    static func configureOnce() { _ = applied }

    /// Run `body` with MLX errors surfaced as Swift `throws` instead of terminating
    /// the process. mlx-swift's default behaviour is `fatalError` when no handler is
    /// installed (`ErrorHandler.dispatch` in mlx-swift 0.31.6); wrapping here makes
    /// MLX-reported errors catchable so `DesignController`'s do/catch can set
    /// `errorText` and display the banner rather than crashing.
    ///
    /// Note: this does NOT protect against jetsam — see class doc above.
    static func withMLXErrorsAsThrows<R>(_ body: () throws -> R) throws -> R {
        try withError { try body() }
    }
}
#endif
