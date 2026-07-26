#if RAYMOL_MPNN
import Foundation
#if os(iOS)
import os
#endif

/// Predicts the peak memory an MPNN inference run will need and decides whether
/// to proceed silently, warn, or refuse.
///
/// This exists because overshoot on iOS is unrecoverable in two independent ways:
/// jetsam is an uncatchable SIGKILL, and mlx-swift's default error handler prints
/// then exits (mlx-swift/Source/MLX/ErrorHandler.swift:4), so DesignController's
/// do/catch can never observe an allocation failure. The only workable strategy is
/// prediction before dispatch.
///
/// Constants derive from a physical-device measurement table (iPhone 15 Pro, 8 GB)
/// in docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §2.
/// The table is concave (local slopes range from 0.80 to 1.76 MB/residue); a chord
/// through the endpoints would pass below every interior point by up to 181 MB and
/// silently consume the 25 % reserve. The slope used here (1.4 MB/residue) is the
/// endpoint-to-endpoint slope; the margin lives entirely in the intercept plus the
/// reserve. Retune all four numbers together from device data (Task 14).
enum DesignSizeGuard {

    // MARK: – Tunable constants

    /// Marginal cost of one residue. Endpoint-to-endpoint slope of the measured table.
    static let bytesPerResidue = 1_400_000
    /// Model-resident floor chosen as an upper envelope over the measured table.
    ///
    /// With slope 1.4 MB/residue the largest residual over the measured points is
    /// 341 MB (at L = 1 272), so 384 MB dominates every measured point when the
    /// source table's `peakMB` figures are read as MB (10^6 bytes). If those figures
    /// are actually MiB (2^20 bytes) the required intercept would be ~445 MB and
    /// 384 MB would fall ~42 MB short at L = 1 272 — roughly 4 % of the reserve
    /// rather than the ~100 % the old chord fit consumed. Task 14 measures RayMol's
    /// own device numbers and resolves the unit question.
    static let fixedOverheadBytes = 384 * 1024 * 1024   // 402_653_184
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
    /// Use this entry point in tests: it exercises the full arithmetic on any host
    /// platform, including macOS, where `evaluate` is unconditionally `.ok`.
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
