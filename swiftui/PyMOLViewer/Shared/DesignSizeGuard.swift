#if RAYMOL_MPNN
import Foundation
#if os(iOS)
import os
#endif

/// Predicts the peak memory an MPNN inference run will need and decides whether
/// to proceed silently, warn, or refuse.
///
/// This exists because iOS memory overshoot is ultimately unrecoverable via jetsam —
/// an OS SIGKILL that cannot be caught regardless of error handling. MLX-**reported**
/// errors (shape mismatches, allocation failures that MLX detects and reports) ARE
/// catchable as of mlx-swift 0.31.6 via `withError()` (see `MPNNRuntime.withMLXErrorsAsThrows`),
/// so DesignController's do/catch can now observe those. A jetsam kill is entirely
/// different: the OS terminates the process asynchronously when physical memory pressure
/// exceeds the app's budget, and no Swift handler can intercept it. The guard must
/// therefore remain preventive rather than reactive — it prevents the inference from
/// starting when the predicted memory footprint would push into jetsam territory.
///
/// Constants derive from a physical-device measurement table (iPhone 15 Pro, 8 GB)
/// in ~/repos/proteinmpnn-ios/device_results/on_device_results_optimized.json.
/// The table is broadly concave (local slopes 1.763, 1.730, 1.549, 1.738, 1.715,
/// 1.438, 0.959, 0.800 MB/residue — broadly decreasing but not monotonically so).
/// The slope used here (1.4 MB/residue) is the endpoint-to-endpoint slope of the
/// measured curve; the margin lives entirely in the intercept (upper envelope) plus
/// the 25 % reserve. Retune all four numbers together from device data (Task 14).
enum DesignSizeGuard {

    // MARK: – Tunable constants

    /// Marginal cost of one residue. Endpoint-to-endpoint slope of the measured table.
    static let bytesPerResidue = 1_400_000
    /// Model-resident floor chosen as an upper envelope over the measured table.
    ///
    /// Source: ~/repos/proteinmpnn-ios/device_results/on_device_results_optimized.json
    /// The table's `peakMB` figures are MiB (2^20 bytes), not MB (10^6 bytes):
    /// multiplying each by 2^20 yields an exact integer for every row; multiplying
    /// by 10^6 yields an integer for none.
    ///
    /// Fit method: bytesPerResidue is the endpoint-to-endpoint slope of the measured
    /// curve. The maximum observed local slope is 1.763 MB/residue — well above the
    /// 1.4 MB/residue endpoint slope — so the slope is NOT "rounded up for margin";
    /// all margin lives in this intercept (upper envelope) plus the 25 % reserve.
    ///
    /// With 448 MiB (469_762_048 B) the model dominates all nine measured points.
    /// Tightest margin: 25_418_540 bytes (~24 MiB) at L = 1_272 residues.
    static let fixedOverheadBytes = 448 * 1024 * 1024   // 469_762_048
    /// At or below this fraction of the remaining budget, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction of the remaining budget, refuse.
    ///
    /// The 25 % reserve is not arbitrary padding: MLX's reported peak EXCLUDES its
    /// buffer cache (mlx-swift/Source/MLX/Memory.swift:171-178), so true
    /// phys_footprint runs above this estimate by an amount nobody has measured.
    static let warnFraction = 0.75

    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingResidues: Int)
    }

    /// Predicted peak bytes for `residueCount` residues.
    /// Returns `Int.max` on arithmetic overflow (absurd inputs refuse rather than trap).
    static func estimatedBytes(residueCount: Int) -> Int {
        let (product, overflow1) = max(0, residueCount).multipliedReportingOverflow(by: bytesPerResidue)
        if overflow1 { return Int.max }
        let (total, overflow2) = fixedOverheadBytes.addingReportingOverflow(product)
        return overflow2 ? Int.max : total
    }

    /// Largest residue count that stays inside `warnFraction` of `availableBytes`.
    /// Zero when even the fixed overhead does not fit.
    static func maxFittingResidues(availableBytes: Int) -> Int {
        let ceiling = Double(availableBytes) * warnFraction - Double(fixedOverheadBytes)
        guard ceiling > 0 else { return 0 }
        return Int(ceiling / Double(bytesPerResidue))
    }

    /// Pure arithmetic decision. `availableBytes <= 0` means "budget unknown" and
    /// always yields `.ok` — that is the fallback for any platform where swap makes
    /// the question meaningless, or when the budget is temporarily unavailable.
    ///
    /// - Important: For tests only. Production callers must use `evaluate`, which
    ///   enforces macOS inertness structurally — `evaluate` returns `.ok`
    ///   unconditionally on non-iOS regardless of the `availableBytes` argument,
    ///   and that guarantee cannot be bypassed by passing a non-zero value.
    static func decide(residueCount: Int, availableBytes: Int) -> Decision {
        guard availableBytes > 0, residueCount > 0 else { return .ok }
        let estimate = estimatedBytes(residueCount: residueCount)
        let available = Double(availableBytes)
        if Double(estimate) <= available * okFraction { return .ok }
        if Double(estimate) <= available * warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
        }
        return .refuse(maxFittingResidues: maxFittingResidues(availableBytes: availableBytes))
    }

    /// Platform-aware wrapper.
    ///
    /// On iOS this delegates to `decide`; on all other platforms it returns `.ok`
    /// unconditionally, regardless of the `availableBytes` argument. The macOS
    /// inertness is structural — no caller convention can accidentally activate the
    /// guard on a platform where swap makes jetsam impossible. Shipped macOS
    /// behaviour must not change.
    static func evaluate(residueCount: Int, availableBytes: Int) -> Decision {
        #if os(iOS)
        return decide(residueCount: residueCount, availableBytes: availableBytes)
        #else
        return .ok
        #endif
    }

    /// Remaining memory budget for this process, or 0 when unknown.
    ///
    /// os_proc_available_memory() reports what is left before this app is jetsammed,
    /// which already accounts for whatever structures are loaded — that is why the
    /// policy uses it instead of a static residue cap.
    static var availableBytesNow: Int {
        #if os(iOS)
        return os_proc_available_memory()
        #else
        return 0
        #endif
    }

    /// Human-readable size for the warn/refuse copy.
    /// Uses `.memory` style — divisions are 1 024-byte kibibytes, so e.g.
    /// 2 502 653 184 B → "2.33 GB".
    static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
#endif
