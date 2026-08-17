---
name: port-predictor-to-mlx
description: Engineering playbook for porting a PyTorch biomolecular predictor network — structure predictors (Boltz-2, AlphaFold-style), diffusion models (RFdiffusion3), or inverse-folding nets (ProteinMPNN) — to a native Swift + MLX implementation that RayMol runs on iOS / iPadOS / macOS. Covers the feasibility/science gate, int8 weight export, layer-by-layer MLX-Swift translation, numerical parity, structural/accuracy ("is int8 lossless?") validation, on-device benchmarking, and RayMol integration + open-source publishing. Use this whenever the user wants to port / bring / run a folding, docking, diffusion, or sequence-design network natively / on-device / on iPhone / in MLX / in Swift for RayMol, quantize a model to int8 for the app, validate an MLX port against fp32, or asks how a boltz-mlx-style port is structured — even if they only name the model (Boltz, RFD3, MPNN) and not the words "MLX" or "port".
---

# Port a predictor network to Swift + MLX for RayMol

This is the repeatable process for taking a PyTorch biomolecular predictor and making it run
**natively inside RayMol** on Apple silicon — trunk + head reimplemented in
[mlx-swift](https://github.com/ml-explore/mlx-swift), weights quantized to int8, features
computed in Swift, and the whole thing validated hard enough that you can trust its output.

The reference implementation this skill is distilled from is **`javierbq/boltz-mlx`** (Boltz-2
structure prediction, shipped in RayMol via `cmd.predict`). Read it alongside this skill — it is
the concrete shape of every abstract instruction here. Its layout is the deliverable template
(see "The deliverable" below).

## Read this first — two truths that reshape the whole project

Most of the risk in a predictor port is *not* the matmuls. Internalize these before scoping:

1. **Featurization is usually the schedule, not the network.** Embedding upstream Python
   featurization on-device is a dead end — it drags in torch + rdkit (62 `.so`) + scipy + numba
   (LLVM JIT) against RayMol's embedded interpreter that has only numpy + biopython. For Boltz,
   upstream featurization measured **~915 s for one 401-token complex** vs ~7 s for the forward
   pass. The win is that a **Swift** featurizer is tractable and *small* (Boltz's 2.1 GB `~/.boltz`
   cache collapses to ~20 KB of reference-atom constants for canonical-20 proteins). Budget the
   featurizer as a first-class subproject with its own parity harness — see
   `references/swift-mlx-port.md`.

2. **The science gate comes before the engineering.** A folding/scoring network is only worth
   porting if its *output metric actually discriminates* on the inputs RayMol will feed it. Boltz
   confidence had **never** scored a real two-chain de-novo complex when the port began (every
   fixture was a monomer, so ipTM ≡ 0 by the chain-mask). Prove the metric works in Python at the
   **production regime** (recycling 3 / 200 steps — not the fast 20-step default that scores a
   3 Å-wrong structure) *before* committing engineering weeks. This is **Phase 0** and it can
   fail the project cheaply.

## The deliverable — "a Swift-MLX port suitable for RayMol"

A self-contained, MIT-compatible SPM package mirroring `boltz-mlx`:

```
<net>-mlx/
├── Package.swift                     # SPM package, repo ROOT (SPM has no subdir support)
├── Sources/
│   ├── <Net>MLX/                     # the MLX inference library: quantized layers,
│   │                                 #   trunk, head/sampler, and the Swift featurizer
│   └── <Net>MLXCLI/                  # a macOS command-line runner (predict from a feature bundle)
├── src/
│   ├── <net>_mlx_export/             # Python exporter: export-model / export-features / make-fixtures
│   └── <upstream>/                   # vendored upstream package (for export + parity), license kept
├── tests/                            # Swift parity + unit tests
├── validation/{benchmark,quality,device}/   # int8-vs-fp32 parity, accuracy, on-device speed/memory
└── README.md, LICENSE                # crediting upstream, MIT
```

Plus the two things that make it *RayMol's*, which live outside this package:

- **A tagged release + a weights release asset.** RayMol consumes the package by
  `url:` + `from: <tag>` in `swiftui/project.yml` (never a local `path:` — that is the recurring
  un-mergeable trap). The quantized weights ship as a **GitHub release asset**, not in git,
  fetched at runtime and **sha256-verified**.
- **A RayMol predictor plugin** in `modules/pymol/predictors/` reachable via `cmd.predict`, plus a
  CI entry so its Python tests actually run.

See `references/raymol-integration.md` for both.

## The seven phases

Work them roughly in order, but Phase 0 gates everything and parity (Phase 3) is developed
*alongside* the port (Phase 2), not after. Each reference file is loaded only when you reach that
phase — keep them closed until then.

| # | Phase | What you produce | Reference |
|---|-------|------------------|-----------|
| 0 | **Feasibility & science gate** | A go/no-go: does the metric discriminate at production settings? What is the peak-memory model? Do the SPM deps resolve? | this file, below |
| 1 | **Weight export (Python)** | An exporter that turns a checkpoint into an int8 MLX artifact + manifest, plus feature bundles and module-boundary fixtures | `references/weight-export.md` |
| 2 | **Swift-MLX port** | The trunk + head + sampler + featurizer in mlx-swift, quantization-aware from day one | `references/swift-mlx-port.md` |
| 3 | **Numerical parity** | Every module boundary matches upstream PyTorch to the quantization floor (r ≥ 0.9997); deterministic tensors pinned bitwise | `references/numerical-parity.md` |
| 4 | **Accuracy validation** | The "is int8 lossless?" benchmark: matched-noise RMSD vs the fp32 self-variance floor, at production step counts, against ground truth | `references/accuracy-validation.md` |
| 5 | **Perf & size benchmarks** | Tokens×atoms scaling, peak RSS, model size per precision, on-device (iPhone) run | `references/accuracy-validation.md` |
| 6 | **RayMol integration + publish** | Tagged package, weights asset, `cmd.predict` plugin, CI wiring, curated public repo | `references/raymol-integration.md` |

## Phase 0 — feasibility & science gate (do this before any Swift)

Cheap work that can kill or reshape the project. Produce a short written gate doc.

- **Prove the metric discriminates.** Run the *upstream* model in Python on a labelled set at the
  **production regime** and compute the actual figure of merit (e.g. AUC of `min_ipsae` for binder
  triage, lDDT/TM vs ground truth for folding). If it does not separate signal from noise here, no
  port will save it. Do not skip because "the paper says it works" — the paper's regime is rarely
  RayMol's.
- **Model peak memory as a function of input size**, and fit it *conservatively*. The failure mode
  is a fit that sits **below** measurement and licenses a run that OOMs. Two hard-won facts:
  peak is often **sub-linear in tokens** once the weight pack dominates (a quadratic-heavy fit
  guesses low), and an MLX OOM thrown from a Metal completion handler is **`std::terminate` →
  uncatchable** — you cannot try/catch your way out, so the model must **pre-flight refuse**
  oversized inputs (an atom/token cap) or run under XPC. Keep a test asserting the fit never falls
  under a measured point.
- **Check SPM consumability now.** mlx-swift pins are tight (one usable tag, `exact:` has no
  consumer override). Confirm `Package.swift` is at the **repo root** and every dependency has a
  real tag before you build anything on top.
- **Establish the precision default.** int8 group-64 is the right default: ~3.75× smaller than
  fp32 and *faster* (quantized matmul beats dense fp16 on these memory-bound ops). Dense fp16/bf16
  packs exist but cost 2× disk, +63% RAM, +22% time — build them only if a validation demands it.
  Note the checkpoint's true dtype: "bf16-trained" nets are usually stored **fp32** on disk, so
  "full precision" is a narrowing choice, not a free upgrade.

Gate output: metric-discriminates verdict + memory model + dep-resolution proof + precision choice.
Only then start Phase 1.

## Non-negotiables (each cost real debugging time)

- **No CI compiles iOS.** RayMol's shared Swift boundary breaks in *both* directions and only
  surfaces when you compile the iOS slice by hand. Compile **both** macOS and iOS targets locally
  before claiming a Swift change is done.
- **Never merge a local `path:` dependency.** Developing against `path: ../../../<net>-mlx` is
  fine; shipping it is the recurring un-mergeable defect. Flip to `url:` + `from: <tag>` and pin
  `Package.resolved` before the PR.
- **Weights are release assets, sha256-verified — never in git.** Verify the hash of the *served*
  asset by downloading it back and re-hashing, not the local file you uploaded.
- **Validate the *runtime*, not the source.** A Debug macOS build runs from
  `Contents/MacOS/RayMol.debug.dylib` (72 MB), not the 58 KB stub; `strings` the dylib.
  Release DMGs have silently shipped stale code — verify the binary you actually built.
- **Same-seed or it's not a comparison.** `cmd.predict` randomizes the seed per call unless you
  pass one. Two "identical" predictions are two different samples; matched-noise is the only way to
  attribute a difference to precision (Phase 4).

## Worked example & prior art

- **`javierbq/boltz-mlx`** — the canonical port. Read `README.md`, `Sources/BoltzMLX/`,
  `src/boltz_mlx_export/`, and `validation/` before starting your own.
- **RayMol memory** (recall these): `raymol-224-predict-backend-state` (end-to-end integration +
  traps), `boltz-swift-msa-featurizer` (featurizer parity landmines), `boltz-dense-precision-pack`
  (precision A/B), `raymol-ondevice-design-funnel` (feasibility math, OOM uncatchability, the
  science gate). RFD3 and ProteinMPNN are separate ports with their own divergences (RFD3's EMA
  shadow weights genuinely differ; MPNN already ships) — the process is the same, the constants are
  not.
