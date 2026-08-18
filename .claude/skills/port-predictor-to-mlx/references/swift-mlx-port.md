# Phase 2 — the Swift + MLX port

Reimplement the network in mlx-swift: the **trunk** (embeddings, template, MSA, Pairformer-style
blocks), the **head/sampler** (diffusion score model + sampler, or the confidence/scoring head),
and the **featurizer**. Build it **quantization-aware from the first layer** and develop parity
(Phase 3) in lockstep — never "port everything, then check."

## Translate module-by-module, verifying each boundary

Port one PyTorch module at a time and immediately check its output against a recorded fixture
(Phase 3). This keeps drift localized: when boundary *k* matches and *k+1* doesn't, the bug is in
*k+1*. Reuse blocks: Boltz's trunk and confidence pairformer blocks are **tensor-identical** (same
53 keys per block), so one `Pairformer.swift` serves both — look for this before writing a second
copy of anything.

## One quantization seam, not 122 call sites

Make quantization a storage detail *inside* the linear/embedding types, not a branch at every use.
`boltz-mlx` puts a `MatrixStorage` enum inside the existing `AffineLinear` / `AffineEmbedding`
(with an `init(denseWeight:)` alongside the quantized init), so adding the dense path touched
**zero** of the 122 sites that name those types. The weight store (`BoltzWeightStore`) branches
once on `manifest.quantization == nil` and hands each layer the right storage. Consequences:

- Adding fp16/bf16 later is a storage variant, not a rewrite.
- Layers read shapes from the manifest, never re-derive them.
- A whole pack is single-dtype; don't mix within a pack.

## The featurizer is a first-class subproject

You cannot embed upstream Python featurization on-device (torch + rdkit + scipy + numba vs
RayMol's numpy-only embedded interpreter; and it is ~130× slower than the forward pass anyway).
Write it in Swift, **MLX-free where possible** so it is pure and testable, and give it its own
parity harness against the `export-features` bundles. Real landmines from the Boltz MSA featurizer
(`Sources/BoltzMLX/Featurize/`):

- **Reproduce upstream bugs deliberately, and document them.** Boltz's deletion features
  (`deletion_value` / `has_deletion` / `deletion_mean`) are **identically zero** — not because
  alignments lack insertions, but because `construct_paired_msa` slices an empty query array inside
  its per-sequence loop. Emit zeros to match; park the parsed insertion counts as a seam if
  upstream ever fixes it. A "more correct" featurizer that emits real deletions **fails parity**.
- **Count then divide once.** `profile = one_hot(msa).float().mean(dim=0)` is an integer-valued sum
  with a single division. Accumulating `1/depth` per row drifts ~2e-6 at depth 249 and breaks
  bitwise parity — the only one of Boltz's 7 MSA tensors that failed first try.
- **Throw where upstream silently degrades.** A length-mismatched MSA, a taxonomy-less local a3m
  (kills all cross-chain pairing) — upstream limps on and mislabels; the Swift side should refuse,
  because the downstream score reads *plausible* while being of the wrong complex.
- **Share one vocabulary.** Gap/canonical/UNK/pad indexing must be identical between the MSA
  one-hot and the residue-type one-hot, or they silently disagree. Reuse a single residue-template
  table for both.

## Memory planning — the model must refuse what it cannot fit

An MLX OOM is uncatchable (`std::terminate` from a Metal completion handler). So capacity is a
**pre-flight** decision, not an exception to handle:

- Ship an **input-limits** type with distinct phone and desktop profiles (Boltz:
  `BoltzInputLimits.desktop` = 1024 tok / 16384 atoms / 16384 MSA rows; the `MemoryPlanner`
  default is phone-sized at 256 tok / 1024 rows and will refuse a real alignment). The **atom cap
  usually binds before the token cap** — size on atoms.
- Report the *true* input size to the planner. Boltz once hardcoded `msaDepth = 1`, so the planner
  under-counted a real MSA until `metadata.msaDepth` reported the real depth.
- **Arbitrate the MLX cache limit under a lock, and re-arbitrate after every run.**
  `MemoryPlanner.cacheLimit` defaults to 64 MiB and `apply()` re-assigns it on *every* predict,
  silently overwriting whatever the shared `MLXRuntime` arbitrated — so a later run (e.g. Design
  mode) can inherit a larger ceiling and get jetsam-killed. Construct with
  `cacheLimit: MLXRuntime.activeCacheLimitBytes` and re-call `configureOnce()` after each
  prediction. Assign the global `MLX.Memory.cacheLimit` *inside* the lock (an outside-the-lock
  assign is a lost-update race).
- Save-and-restore `memoryLimit` with `defer`; don't leave a 6 GB ceiling installed. On Boltz,
  `memoryLimit` is load-bearing (it gates a `gpu::finalize` + drain) — use ~4 GB, and going below
  4 GB buys nothing while costing ~40% wall time.

## Zero-work opportunities hide in "always zero outside a mask" tensors

Before optimizing matmuls, look for large intermediates that are **identically zero outside a
sparse mask**. RFD3's `SinusoidalDistEmbed` builds an `[A,A,64]` fp32 tensor (256 B/atom²) whose
output is zero everywhere except the motif block — at 555 tokens **99.86%** of that work is
multiplied by zero. Row-blocking it to the nonzero rows was **bit-identical** (max abs diff 0.0)
and cut peak from 995 → 62 B/atom². These wins are safe *because* they're bit-identical — prove
that with a fixture, don't assume it.

## Build/run gotchas

- The debug CLI dies with "Failed to load the default metallib" — only `.build/release/` has
  `mlx.metallib` beside the binary. Build `-c release` to actually run the CLI.
- SourceKit reports **"No such module 'MLX'"** in these packages even when `swift build` is clean.
  Trust the compiler, not the editor squiggle.
