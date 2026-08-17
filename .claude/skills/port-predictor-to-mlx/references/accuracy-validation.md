# Phases 4 & 5 — accuracy validation and benchmarking

Parity (Phase 3) proves the port is the same *computation*. This phase proves the **int8 model is
good enough to trust** and measures what it costs. The headline question is usually *"is int8
lossless?"* — and the first job is to reframe it honestly.

## "Lossless" needs redefining before you can test it

int8 is **not** bit-lossless — 8-bit weights can't be. The defensible, testable claim is:

> **int8 causes no *meaningful* loss vs fp32** — the int8-vs-fp32 difference is no larger than the
> model's own fp32 **run-to-run variance**, AND int8's accuracy against ground truth is
> statistically equivalent to fp32's.

The trap that makes naïve benchmarks worthless: structure prediction is **stochastic**, so the
yardstick is not zero — it's the fp32 self-variance. A single-seed int8-vs-fp32 RMSD is meaningless
because two fp32 runs at different seeds already differ. On Boltz, int8-vs-bf16 at the same seed is
**3.10 Å**, but int8-vs-itself across seeds is **4.9–7.0 Å** — the precision delta sits *below* the
sampling noise, so that A/B **cannot rank the packs at all.** Never let a single-seed number
masquerade as an accuracy result.

## Two comparison modes

1. **Matched-noise (deterministic — isolates quantization).** Feed *identical* injected
   initial/step noise + identity augmentation to both precisions, then Kabsch-superpose the two
   outputs over identical atom order → per-target RMSD/lDDT/TM. This is the *only* way a difference
   is attributable to precision rather than to two different valid conformations. Boltz matched-noise
   int8-vs-fp32 is **sub-Ångström for 5 of 6 sizes** (0.22–1.82 Å, all under a 2.0 Å gate).
2. **Free-sampling ensemble (the real-world test).** K seeds per target per precision → the fp32
   seed-to-seed spread *is* the noise floor that int8-vs-fp32 must fall within. Report distributions,
   not point estimates.

## Run at the production regime, or the numbers lie

Low diffusion-step counts inflate differences: Boltz's `prot_no_msa` was **3.19 Å at 20 steps but
0.64 Å at 50**, and the confidence metric's own quality gate *fails* at 20 steps. Validate at the
regime the network was **trained** for (Boltz: recycling 3 / 200 steps), plus a {20, 50, 200} sweep
to show convergence. Every speed number quoted from a fast-default regime is scoring a wrong
structure.

## Dataset — the biggest lever

~30–50 **real, diverse targets** with MSAs and experimental structures, ideally **post-dating the
training cutoff** to avoid memorization (a slice of recent CAMEO/CASP or a curated PDB set). Well-
determined targets (real MSAs) have low sampler variance, so any residual int8 gap is attributable
to quantization rather than chaos — toy truncations of one no-MSA protein are under-determined and
produce the 1.8–3 Å outliers that mean nothing. Mix sizes; add complexes / protein–ligand only if
those paths and their memory envelopes are validated.

## Metrics and the pre-registered verdict

- **int8 vs fp32:** all-atom RMSD, Cα-lDDT, TM-score (+ DockQ for complexes; ligand-RMSD /
  PoseBusters for ligands).
- **vs ground truth (the one that matters):** lDDT / TM for *both* precisions → paired
  **Δaccuracy = acc(int8) − acc(fp32)** per target.
- **confidence preservation:** correlation of predicted pLDDT / PAE (int8 vs fp32) and top-model
  ranking agreement.
- **Verdict (fix the margin *before* running):** both of — (a) mean matched-noise int8-vs-fp32 RMSD
  ≤ fp32 seed-to-seed RMSD; (b) a **TOST equivalence test** on Δ(lDDT-to-truth) with a margin set
  in advance (e.g. ±1 lDDT point, or ± the measured fp32 self-variance). Report per-target and
  aggregate (mean ± 95% CI), paired across targets.

## Compute

fp32 × 200 steps × ~40 targets × K seeds is heavy for a Mac — run the **fp32 reference on the SLURM
cluster** (there's a `smith:boltz-predict` path) and keep the Mac for the int8 candidate. For binder
triage the interface metric is cheap: `min_ipsae` needs only the PAE matrix + two chain lengths
(~40 lines of Swift); `agent-smith`'s `compute_ipsae.py` + its test fixtures are the reference. Do
**not** anchor a threshold to an unsourced number — an ipSAE cutoff from a different `d0`
normalization moves the operating point in the permissive direction on the one number a design run
gates on. Leave calibration to the user's labelled set.

## Phase 5 — performance & size benchmarks

Report these so the on-device viability is legible, all with **model load excluded** and the model
loaded once:

- **Speed vs a real baseline.** Boltz int8-MLX beats PyTorch-fp32-MPS **3.2× → 1.2×** across
  40→384 tokens — biggest exactly where it matters (small proteins, the on-device regime, where MPS
  pays per-step dispatch + a CPU-fallback SVD). At large sizes both go compute-bound and converge.
  Be honest that part of the win is int8 vs fp32, not MLX vs MPS.
- **Model size per precision** (same weights): int8 529 MB / fp16 ~992 MB / fp32 ~1.85 GB — the
  ~3.75× shrink is what makes the phone budget work (int8 is the constant memory floor; activations
  add ~0.6–1.4 GB peak).
- **On-device run.** Actually run it on the target iPhone and record wall time + peak RSS at the
  shipping operating point. Boltz: ~3–13 s per small protein at ~0.6–1.4 GB on an iPhone 15 Pro,
  inside the 8 GB budget. Note DEBUG builds are an upper bound (materially slower than release).
- **Precision A/B, if you built dense packs.** Boltz bf16-dense is **slower** (+22% wall, +63% RSS,
  2× disk) and its accuracy delta vs int8 sits below sampling noise — i.e. dense is not worth it
  here. Measure before assuming "full precision" is an upgrade.

Land all of this as `validation/{quality,benchmark,device}/report.md` + raw JSON assets, mirroring
`boltz-mlx/validation/`. The reports are part of the deliverable — they are what lets the next
person (and RayMol review) trust the port.
