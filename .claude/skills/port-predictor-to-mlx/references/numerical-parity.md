# Phase 3 — numerical parity (developed alongside Phase 2)

Parity is how you know the port is the *same network*, not a plausible-looking different one. Two
tiers, and you need both:

- **Tensor/boundary parity** — each ported module's output matches upstream PyTorch on the same
  input. This is where bugs are localizable and cheap to fix.
- **End-to-end golden** — a fixed (seed, input) produces the same final structure through both the
  Swift path and a byte-identical reference, guarding against drift the per-boundary checks miss.

## What "match" means, tier by tier

- **Deterministic-at-inference tensors: pin bitwise.** Features with no RNG (MSA, profile,
  res-type one-hots) must match **exactly** (max abs diff 0.000). If they don't, you have a real
  bug (ordering, off-by-one, a "corrected" upstream quirk) — not quantization noise. Boltz pins
  **7/7** MSA tensors bitwise on a 249×384 monomer *and* on a gap-expanding binder+target fixture.
- **Quantized module boundaries: match to the quantization floor.** int8 group-64 sets a hard
  ceiling; `boltz-mlx` reports every module boundary at **Pearson r ≥ 0.9997**. Record that
  number as *the* acceptance bar and treat any boundary below it as a bug in that module.
- **Randomly-augmented tensors: distribution-check only** (e.g. `ref_pos`). You cannot pin these;
  assert shape + summary statistics, not values.

## Module-boundary fixtures (`make-fixtures`)

The exporter records, from a real forward pass, the input and output tensor of each module
boundary. The Swift test loads the input, runs its ported module, and compares to the recorded
output. Gate the fixtures behind an env var (`BOLTZ_MSA_REF_DIR`, `BOLTZ_CONF_MODEL`, …) so the
suite runs without the (large, gitignored) fixtures in CI, and skips cleanly when they're absent.

**A skipped test that looks green is the trap here.** Boltz has a pre-existing
`swift test` "failure" where an XCTSkip sits *inside* an `XCTAssertEqual` for a missing env-gated
fixture — it neither runs nor is obviously skipped. Make skips explicit and loud, and periodically
run the suite *with* fixtures present so you know the parity tests actually execute.

## Parity arithmetic that bites

- **Reduction order changes the low bits.** A sum done in a different order passes at 1e-7 on one
  fixture and drifts over hundreds of evals. When a boundary is *close* but not bit-identical on a
  deterministic tensor, suspect accumulation order before suspecting a real difference.
- **Set the error budget from the actual path, not a round number.** For RFD3 the binder `dm.X_L`
  path's honest budget is **1.34e-5**, not the 6.9e-6 an unconditional-50 fixture suggests (at
  I=50 a k=128 mask is all-True, so that fixture exercises nothing). A pass that is an `OR` over a
  loose threshold hides compounding drift — pick the tightest defensible bound for the path you
  actually ship.
- **Fixture representativeness matters more than fixture count.** RFD3's committed fixtures have
  motif sparsity **47.97%** vs production **0.136%** (169× off, exactly where the optimization you
  want to verify helps *least*); the other fixture has zero motif atoms. A fixture that doesn't
  resemble production traffic can pass while the shipped path is wrong.

## End-to-end golden through byte-identical copies

When the same source files exist in two places (e.g. RayMol vendors a copy of the Swift core), a
fix must land in **both**, and the golden must run through **both**. RFD3 shares 12 files between
`swift/Sources/RFD3Core/` and `RFD3Kit/Sources/RFD3Kit/`; the gate before *any* numerical change
is a `designBinder`-level golden — fixed seed + target ⇒ exact output sequence + coordinate hash —
run through both copies. Diverging copies is how a fix silently reaches only one target.

## Confidence/scoring-head parity is usually cheap

If the head reuses trunk blocks (Boltz confidence = the same pairformer, 8 blocks vs 64), it ports
1:1 and quantizes almost losslessly: int8 round-trip on Boltz confidence moved ipTM by **2.2e-4**
and kept PAE Pearson **0.999959** — no separate fp16 pack needed, +25 MiB. But still export the
head's feeder modules (the distogram) and its full config (Phase 1 traps), or the head runs on
garbage.
