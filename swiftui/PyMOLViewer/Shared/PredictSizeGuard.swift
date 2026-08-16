#if os(macOS)
import Foundation

/// Predicts the peak memory a Boltz run needs and decides whether to proceed, warn, or
/// refuse.
///
/// This exists because boltz-mlx's own preflight cannot be relied on. Its activation
/// estimate under-predicts measured peaks by **10–25×** (115 tokens / 889 atoms
/// estimates ~60 MB against a measured 1.43 GB; 384 tokens estimates ~622 MB against a
/// measured 6.84 GB), and under its phone defaults the memory check can never fire at
/// all because the token cap always binds first. Its own handoff notes concede the
/// limits are "conservative estimates, not measurements".
///
/// It stays **preventive** rather than reactive for the same reason `DesignSizeGuard`
/// does: ``MLXRuntime/withMLXErrorsAsThrows(_:)`` makes MLX-*reported* errors catchable,
/// but a jetsam SIGKILL is an asynchronous OS kill that no Swift handler can intercept —
/// and on macOS that takes the user's unsaved session with it, not just the job.
///
/// Constants are fitted to RayMol's own measured MLX peak memory on an M3 Pro / 36 GiB at
/// the shipped operating point (recycling 3 / 200 steps, single chain), swept 60→900
/// residues with no alignment and again over a (tokens × MSA depth) grid — see
/// `PredictSizeGuardTests.measured` and `.measuredWithMSA` for the full tables, and
/// `PredictMSAMemorySweepTests` for the harness that produces the second one.
///
/// **Alignment depth was a dimension this did not model at all, and it is not small.**
/// At 115 residues, peak memory runs 2.19 GB at depth 64 and **7.90 GB at depth 16,384** —
/// so the token-only estimate of 2.20 GB was 3.6× optimistic for a deep alignment, which
/// is the same failure mode as the two below, in a direction nobody had measured. It is
/// also not smooth: memory is flat in depth while the MSA tensors still fit in buffers
/// MLX is recycling anyway (250 residues measures 3.88 GB at every depth from 1 to 1024),
/// then climbs steeply once they do not. A term derived from the tensor shapes rather
/// than measured would have missed both halves of that.
///
/// **This guard has been wrong in the optimistic direction twice, both times for the same
/// reason: the fit was extrapolating past its data.** That history is the point, not
/// trivia — it is the failure mode to design against:
///
/// 1. Fitted against boltz-mlx's published 117- and 225-token figures, memory looks
///    *sub*-linear — solving for a quadratic coefficient there even yields a negative one,
///    because the weight pack dominates that range. That fit ran **27% optimistic at 600
///    residues**.
/// 2. Refitted to 600, it ran **27% optimistic again at 900** — identically wrong, one
///    level up, because the pairwise ~N² term keeps steepening.
/// 3. The MSA term above is the same story a third time, caught before it shipped rather
///    than after: the guard did not model depth, and depth costs 3.6× at the ceiling.
///
/// The current constants cover every measured point with no shortfall. **Do not extrapolate
/// past the data in either dimension**: the honest ceilings are ``maximumTokens`` and
/// ``maximumMSADepth``, each set to what has actually been measured. If a larger input must
/// be supported, measure it first.
///
/// Retune all five together from new device data, and **never let the fit sit below
/// measurement** — that is what licenses a run which then gets jetsam-killed.
/// `testEstimateNeverSitsBelowMeasurement` pins both tables for exactly this reason; an
/// earlier version pinned only two points, which is how shortfall #1 survived.
enum PredictSizeGuard {

    // MARK: - Tunable constants

    /// Model-resident floor. Small, because the linear and quadratic terms now carry the
    /// curve across the whole measured range instead of the intercept papering over the
    /// small end.
    static let fixedOverheadBytes = 200 * 1024 * 1024
    /// Linear term, bytes per token.
    static let bytesPerToken = 14_500_000
    /// Quadratic term, bytes per token² — the pairwise tensors. 12.5× the original value;
    /// see the type doc for the two successive under-predictions that produced it.
    static let bytesPerTokenSquared = 25_000
    /// Bilinear term, bytes per (token × alignment row beyond the first) — the MSA
    /// module's own tensors, which are depth × tokens wide.
    ///
    /// **Measured, not derived**, over the (tokens × depth) grid in
    /// `PredictMSAMemorySweepTests` — the type doc explains why nothing here may be
    /// fitted analytically. The cost per row·token is nothing like constant: the grid
    /// needs anywhere from 1.5 KB to 3.8 KB depending on the cell, and is *negative*
    /// wherever the MSA still fits inside buffers MLX was recycling anyway. So this is
    /// the WORST cell (3,763 B at 115 residues / depth 4096) plus ~20%, which is what
    /// makes one linear term safe across a relationship that is not linear.
    static let bytesPerTokenMSARow = 4_500
    /// At or below this fraction of available memory, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction, refuse.
    static let warnFraction = 0.75
    /// Hard ceiling regardless of memory: the largest input actually MEASURED end to end
    /// (900 residues → 32.71 GB peak, 42 min of inference). `BoltzInputLimits.desktop`
    /// would allow 1024, but the estimate there is ~41 GB — beyond a 36 GiB machine — and
    /// nothing above ~384 has ever been validated for structural quality. Raise this only
    /// alongside a measurement, never alongside an extrapolation.
    static let maximumTokens = 900
    /// Hard ceiling on alignment depth: the deepest actually MEASURED, which is also
    /// upstream's `const.max_msa_seqs` and `BoltzInputLimits.desktop.maximumMSADepth`.
    /// The two agreeing is a coincidence of this sweep having reached the cap, not a
    /// reason to raise either — raise this only alongside a measurement.
    static let maximumMSADepth = 16_384

    enum Decision: Equatable {
        case ok
        case warn(estimatedBytes: Int, availableBytes: Int)
        case refuse(maxFittingTokens: Int)
        /// Refused because of the ALIGNMENT rather than the sequence. Distinct from
        /// `refuse` because the remedy is different and specific: lowering `msa_depth`
        /// keeps the same target foldable, where "use a shorter sequence" does not.
        case refuseDepth(maxFittingDepth: Int)
    }

    /// Fitted peak-memory estimate.
    ///
    /// `msaDepth - 1` rather than `msaDepth`, so depth 1 reduces EXACTLY to the
    /// token-only formula the existing 17-point no-MSA table was fitted against. That
    /// table's runs did have an alignment — upstream's depth-1 dummy — so depth 1 is
    /// its true zero, and the whole of it stays valid evidence for this function.
    static func estimatedBytes(tokens: Int, msaDepth: Int = 1) -> Int {
        fixedOverheadBytes
            + tokens * bytesPerToken
            + tokens * tokens * bytesPerTokenSquared
            + tokens * max(msaDepth - 1, 0) * bytesPerTokenMSARow
    }

    static func decide(tokens: Int, msaDepth: Int = 1, availableBytes: Int) -> Decision {
        guard tokens <= maximumTokens else {
            return .refuse(maxFittingTokens: min(maximumTokens,
                                                 largestFittingTokenCount(availableBytes)))
        }
        guard msaDepth <= maximumMSADepth else {
            return .refuseDepth(maxFittingDepth: maximumMSADepth)
        }
        let estimate = estimatedBytes(tokens: tokens, msaDepth: msaDepth)
        let fraction = Double(estimate) / Double(max(availableBytes, 1))
        if fraction <= okFraction { return .ok }
        if fraction <= warnFraction {
            return .warn(estimatedBytes: estimate, availableBytes: availableBytes)
        }
        // Blame the alignment when the alignment is what does not fit. A user who is
        // told "at most 300 residues fit" for a 250-residue target with a deep MSA has
        // been told something both true and useless; `msa_depth` is the lever that
        // actually makes THIS run possible.
        if msaDepth > 1 {
            let fitting = largestFittingMSADepth(tokens: tokens,
                                                 availableBytes: availableBytes)
            if fitting >= 1 { return .refuseDepth(maxFittingDepth: fitting) }
        }
        return .refuse(maxFittingTokens: largestFittingTokenCount(availableBytes))
    }

    /// Physical memory, as the budget the estimate is compared against.
    static var availableBytes: Int {
        Int(ProcessInfo.processInfo.physicalMemory)
    }

    private static func largestFittingTokenCount(_ availableBytes: Int) -> Int {
        let budget = Int(Double(availableBytes) * warnFraction)
        var best = 0
        var tokens = 1
        while tokens <= maximumTokens {
            if estimatedBytes(tokens: tokens) <= budget { best = tokens } else { break }
            tokens += 1
        }
        return best
    }

    /// The deepest alignment that still fits at this token count, or 0 if even a
    /// single-sequence run does not. Halved rather than decremented: the answer is a
    /// number the user will type into `msa_depth`, and stepping one row at a time over
    /// a 16,384-row range to land on a value like 9,133 would be slower and no more
    /// useful than a round power of two.
    private static func largestFittingMSADepth(tokens: Int, availableBytes: Int) -> Int {
        let budget = Int(Double(availableBytes) * warnFraction)
        var depth = maximumMSADepth
        while depth > 1 {
            if estimatedBytes(tokens: tokens, msaDepth: depth) <= budget { return depth }
            depth /= 2
        }
        return estimatedBytes(tokens: tokens, msaDepth: 1) <= budget ? 1 : 0
    }
}
#endif
