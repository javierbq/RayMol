#if os(macOS) || os(iOS)
import Foundation
#if os(iOS)
import os   // os_proc_available_memory()
#endif

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
///
/// ## iOS
///
/// Two things change on a phone, and only two:
///
/// - ``availableBytes`` becomes `os_proc_available_memory()` rather than
///   `physicalMemory`. This is the change that matters. See that property.
/// - ``maximumTokens`` becomes ``iOSMaximumTokens``, the largest input actually folded
///   on device.
///
/// and the three fitted terms take iOS values. **Reusing the Mac constants is safe but
/// over-conservative.** Measured against the device footprints below it over-predicts by
/// 1.23–1.39×, so it would not have got anyone jetsam-killed — but it is cautious enough
/// to REFUSE sizes that fold perfectly well: at 130 residues it estimates 2.52 GB against
/// the measured 3.27 GB budget (77%, past ``warnFraction``) for a fold that actually
/// peaked at 2.00 GB and finished in 64 s. The iOS terms buy back that headroom without
/// giving up margin over any measurement.
///
/// ### How the iOS constants were derived
///
/// From a device sweep on the target hardware — iPhone 15 Pro, iOS 26.6, Release build,
/// single chain, no MSA, at the shipped operating point (3 recycles / 200 diffusion
/// steps). **Peak `phys_footprint`, sampled every 200 ms throughout the run** by
/// `BoltzJobManager.FootprintSampler`:
///
/// | residues | wall  | MLX peak | peak phys_footprint |
/// |---------:|------:|---------:|--------------------:|
/// | 110      |  39 s |  1.38 GB |          **1.72 GB** |
/// | 130      |  64 s |  1.75 GB |          **2.00 GB** |
/// | 164      | 250 s |  2.00 GB |          **2.35 GB** |
///
/// `os_proc_available_memory()` on that device, with a session open, solves to about
/// **3.27 GB** (back-derived from the guard's own refusal of a 200-residue input naming
/// 180 as the largest that fit).
///
/// ### The units correction, which is the whole story here
///
/// **These constants were first fitted against MLX's high-water mark, and that was
/// wrong.** `MLX.Memory` excludes its own buffer cache
/// (mlx-swift/Source/MLX/Memory.swift:171-178), so it under-reports the process by
/// 300–350 MB at these sizes. The budget it gets compared against —
/// `os_proc_available_memory()` — is denominated in `phys_footprint`, so comparing an
/// MLX-peak estimate to it is comparing two different quantities and quietly favouring
/// the optimistic one.
///
/// Fitted against MLX peak, this curve estimated 1.68 / 1.89 / 2.26 GB — **below the
/// measured footprint at every single point**, i.e. precisely the failure the three
/// numbered items above describe, for a fourth time and by a new mechanism. It was caught
/// only because the footprint was sampled rather than assumed. A single `phys_footprint`
/// read taken after inference does NOT catch it either: that is a post-release reading,
/// and it returned 1.05 GB for both the 110- and the 164-residue run.
///
/// The shipped terms are refitted to the footprint column with an **11–15% reserve** at
/// every measured point (1.15× / 1.11× / 1.15×). Modest on purpose: three real points
/// across the range of interest justify far less padding than one point did, and
/// `warnFraction` already withholds a further 25% on top.
///
/// Note the macOS arm still fits MLX peak against `physicalMemory` — the same mismatch,
/// but harmless there because a Mac has swap and installed RAM is a soft wall. Left alone
/// deliberately; changing shipped macOS behaviour is not this port's business.
///
/// ### What this fit does NOT know
///
/// - ``bytesPerTokenMSARow`` is still NOT rescaled — see that constant. No MSA fold has
///   been run on device, and inventing a measurement is what all four failures were.
/// - ``iOSMaximumTokens`` is 164: the largest input actually folded to completion here.
///   Not the 256 the runtime's phone preset allows, and not a round 200. Note the wall
///   time at 164 was 250 s against 99 s for the same input in an earlier run — a 2.5×
///   spread that suggests thermal or memory-pressure throttling and is itself a reason
///   not to treat that size as comfortable.
///
enum PredictSizeGuard {

    // MARK: - Tunable constants

    /// Model-resident floor. Small, because the linear and quadratic terms now carry the
    /// curve across the whole measured range instead of the intercept papering over the
    /// small end.
    static var fixedOverheadBytes: Int { isPhone ? 850 * 1024 * 1024 : 200 * 1024 * 1024 }
    /// Linear term, bytes per token.
    static var bytesPerToken: Int { isPhone ? 7_500_000 : 14_500_000 }
    /// Quadratic term, bytes per token² — the pairwise tensors. 12.5× the original value;
    /// see the type doc for the two successive under-predictions that produced it.
    static var bytesPerTokenSquared: Int { isPhone ? 21_500 : 25_000 }
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
    ///
    /// **Deliberately NOT halved for iOS**, unlike the three terms above. Those were
    /// rescaled to a device measurement; this one has none — no MSA fold has ever been
    /// run on an iPhone. Halving it "to match" would be inventing a measurement, which is
    /// the exact move this type's three recorded failures all were. It stays at the
    /// conservative Mac value, which on a phone budget means a deep alignment is refused
    /// on memory well before ``iOSMaximumMSADepth`` binds — the honest place to refuse it.
    static let bytesPerTokenMSARow = 4_500
    /// At or below this fraction of available memory, proceed silently.
    static let okFraction = 0.50
    /// Above this fraction, refuse.
    static let warnFraction = 0.75
    /// Hard ceiling regardless of memory: the largest input actually MEASURED end to end.
    ///
    /// **macOS — 900.** 900 residues → 32.71 GB peak, 42 min of inference.
    /// `BoltzInputLimits.desktop` would allow 1024, but the estimate there is ~41 GB —
    /// beyond a 36 GiB machine — and nothing above ~384 has ever been validated for
    /// structural quality.
    ///
    /// **iOS — see ``iOSMaximumTokens``.** A phone is a different machine running a
    /// different memory plan, so it gets its own measured ceiling rather than a scaled
    /// version of the Mac's.
    ///
    /// Raise either only alongside a measurement, never alongside an extrapolation.
    static var maximumTokens: Int {
        #if os(iOS)
        return iOSMaximumTokens
        #else
        return 900
        #endif
    }

    /// iOS hard token ceiling — the largest input actually folded to completion on a
    /// physical iPhone.
    ///
    /// **Provisional: 117**, which is boltz-mlx's own published device figure
    /// (iPhone 15 Pro, 117 tokens / 899 atoms, ~1.4 GB peak footprint —
    /// `examples/BoltzMLXDemo/DEVICE_BENCHMARK.md`). It is deliberately NOT set to the
    /// 256 that `BoltzInputLimits`' phone-sized default allows, and not to the
    /// 100–150-residue range this port targets, because neither has been folded on
    /// hardware. The type doc above records three separate occasions on which this
    /// guard's fit was optimistic, every one of them because it extrapolated past its
    /// data; a ceiling set to what we *hope* works would be the fourth.
    ///
    /// Raise it to the largest size that has actually completed on device, and record
    /// the run. Nothing else licenses a change here.
    static let iOSMaximumTokens = 164
    /// Hard ceiling on alignment depth: the deepest actually MEASURED, which is also
    /// upstream's `const.max_msa_seqs` and `BoltzInputLimits.desktop.maximumMSADepth`.
    /// The two agreeing is a coincidence of this sweep having reached the cap, not a
    /// reason to raise either — raise this only alongside a measurement.
    static var maximumMSADepth: Int { isPhone ? iOSMaximumMSADepth : 16_384 }

    /// iOS alignment-depth ceiling — boltz-mlx's own phone preset cap, which
    /// `BoltzJobManager.memoryPlanner` independently enforces on iOS, so the two agree
    /// and neither is a surprise. It is a backstop only: at any depth approaching it the
    /// memory fraction refuses first (117 residues at depth 1 024 estimates ~2.3 GB
    /// against an app budget near 2.5 GB), which is the refusal that names `msa_depth` as
    /// the remedy. Nothing here has been measured on device; see
    /// ``bytesPerTokenMSARow``.
    static let iOSMaximumMSADepth = 1_024

    /// Whether the fitted constants above should take their iOS values.
    ///
    /// A single switch rather than five `#if`s, so the two fits cannot be mixed — a
    /// half-converted set (say, a phone intercept against a Mac quadratic) would produce
    /// a curve nobody fitted and nobody measured.
    private static var isPhone: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

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

    /// The budget the estimate is compared against.
    ///
    /// **The two platforms answer genuinely different questions, and using one number
    /// for both is what made this guard meaningless on a phone.**
    ///
    /// - macOS: `physicalMemory`. A Mac has swap, so RAM is a soft wall — the question
    ///   is "will this thrash", and installed RAM is the right scale for it.
    /// - iOS: `os_proc_available_memory()` — bytes remaining before *this app* is
    ///   jetsammed. `physicalMemory` on an iPhone 15 Pro reports 8 GB, of which a normal
    ///   app may use roughly a third; comparing a fold's peak against 8 GB would have
    ///   licensed runs at ~3× the app's actual budget, and the failure mode is a SIGKILL
    ///   that no Swift handler can catch and that takes the unsaved session with it.
    ///   This is exactly ``DesignSizeGuard/availableBytesNow``, for exactly its reasons,
    ///   and it is live rather than static: it already accounts for whatever structures
    ///   are currently loaded, which a fixed cap could not.
    static var availableBytes: Int {
        #if os(iOS)
        return os_proc_available_memory()
        #else
        return Int(ProcessInfo.processInfo.physicalMemory)
        #endif
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
