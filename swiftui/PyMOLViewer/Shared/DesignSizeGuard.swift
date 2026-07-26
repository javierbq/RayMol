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
/// Constants derive from a physical-device measurement (iPhone 15 Pro, 8 GB) in
/// docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §2:
/// MLX peak active memory is linear in residue count, slope 1.32 MB/residue,
/// intercept ~55 MB. Retune all four numbers together from device data (Task 15).
enum DesignSizeGuard {

    // MARK: – Tunable constants

    /// Marginal cost of one residue. Measured slope 1.32 MB, rounded up for margin.
    static let bytesPerResidue = 1_400_000
    /// Model-resident floor: measured ~55 MB intercept + the 96 MB MLX cache clamp.
    static let fixedOverheadBytes = 160 * 1024 * 1024   // 167_772_160
    /// At or below this fraction of the remaining budget, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction of the remaining budget, refuse.
    ///
    /// The 25% reserve is not arbitrary padding: MLX's reported peak EXCLUDES its
    /// buffer cache (mlx-swift/Source/MLX/Memory.swift:171-178), so true
    /// phys_footprint runs above this estimate by an amount nobody has measured.
    static let warnFraction = 0.75

    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingResidues: Int)
    }

    /// Predicted peak bytes for `residueCount` residues.
    static func estimatedBytes(residueCount: Int) -> Int {
        fixedOverheadBytes + max(0, residueCount) * bytesPerResidue
    }

    /// Largest residue count that stays inside `warnFraction` of `availableBytes`.
    /// Zero when even the fixed overhead does not fit.
    static func maxFittingResidues(availableBytes: Int) -> Int {
        let ceiling = Double(availableBytes) * warnFraction - Double(fixedOverheadBytes)
        guard ceiling > 0 else { return 0 }
        return Int(ceiling / Double(bytesPerResidue))
    }

    /// Two-tier policy. `availableBytes <= 0` means "budget unknown" and always
    /// yields `.ok` — that is the macOS path, where swap makes the question
    /// meaningless and shipped behaviour must not change.
    static func evaluate(residueCount: Int, availableBytes: Int) -> Decision {
        guard availableBytes > 0, residueCount > 0 else { return .ok }
        let estimate = estimatedBytes(residueCount: residueCount)
        let available = Double(availableBytes)
        if Double(estimate) <= available * okFraction { return .ok }
        if Double(estimate) <= available * warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
        }
        return .refuse(maxFittingResidues: maxFittingResidues(availableBytes: availableBytes))
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

    /// Human-readable size for the warn/refuse copy, e.g. "2.3 GB".
    static func formatted(bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
#endif
