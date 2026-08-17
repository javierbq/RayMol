# Phase 1 — Weight export (the Python side)

Goal: a small, reproducible exporter that turns an upstream checkpoint into an **MLX artifact**
(quantized weights + a manifest) plus the **feature bundles** and **module-boundary fixtures** the
Swift side needs. In `boltz-mlx` this is `src/boltz_mlx_export/` with three CLI verbs:

```bash
boltz-mlx export-model    --checkpoint <ckpt> --output <dir> [--precision int8|float16|bfloat16]
boltz-mlx export-features <input.yaml>        --output <dir>
boltz-mlx make-fixtures   ...                 # PyTorch module-boundary tensors for parity tests
```

Modules to mirror: `cli.py` (verbs), `model_export.py` (weights), `feature_export.py` (features),
`fixtures.py` (parity references), `names.py` (name mapping), `quantization.py`, `schema.py`
(manifest), `tensor_io.py`. Vendor the upstream package under `src/<upstream>/` so export and
parity run against the real thing.

## The exporter contract

Write **safetensors** + a JSON **manifest**. The manifest is the seam between Python and Swift —
Swift branches on it and never re-derives shapes. For an int8 pack, each tensor carries packed
8-bit weights + fp16 `scales`/`biases` + `logical`/`physical` shape (physical is padded to the
quantization group size). A dense pack sets `quantization: null` and carries **no** scales/biases
and **no** logical/physical shape (padding only exists for quantization). A pack must be
**single-dtype** — MLX promotes a mixed fp16/bf16 op to fp32.

Default precision is **int8, group-64**. It is smaller *and* faster than dense (quantized matmul
wins on memory-bound ops); build dense fp16/bf16 only when a validation explicitly needs it.

## Landmines — every one shipped a silently-wrong model at least once

- **Know the checkpoint's true dtype.** "bf16-trained" networks are stored **fp32** on disk
  (Boltz: 5102 tensors, all `torch.float32`). The `bfloat16` branch in an exporter is usually
  defensive, not load-bearing. So exporting fp16 is *closer* to source than bf16 at equal size
  (10-bit vs 7-bit mantissa); bf16 is "faithful" only in the sense the net was trained in it.

- **EMA shadow weights — check whether the head uses them.** Diffusion/score models often keep an
  exponential-moving-average shadow of the parameters that is what actually gets used at inference.
  You **must** verify per-network: Boltz confidence has **0 of 5102** tensors differing from the
  EMA shadow (safe to ignore), but **RFD3 has 392 of 400 differing by up to 55%** — exporting the
  raw weights there ships a wrong model. Diff raw-vs-EMA before you trust either.

- **Name-prefix omissions silently drop a submodule.** Export code that filters by a
  `STRUCTURE_PREFIXES`-style allow-list will happily omit a head you need. Boltz's list omits
  **both** `confidence_module` and `distogram_module` — and the distogram *feeds* confidence via
  `pred_distogram_logits`, so adding only the first ships an unrunnable head. Enumerate what the
  forward pass actually reads, not what the prefix list happens to name.

- **`from_hparams`-style config loaders drop args and build a *different* model.** Boltz's
  `ModelConfiguration.from_hparams` silently drops `confidence_model_args`
  (`add_s_to_z_prod` / `add_s_input_to_s` / `add_z_input_to_z` / `use_separate_heads`, all True) —
  the defaults construct a subtly wrong head that still runs and still produces plausible numbers.
  Assert the reconstructed config equals the checkpoint's hparams field-by-field.

- **numpy has no bf16 dtype.** Write bf16/fp16 dense packs via `safetensors.torch`, not numpy.

- **Guard your CLI entrypoint.** `python -m <exporter>.cli` **silently exits 0 doing nothing** if
  the module has no `__main__` guard. Use the installed console script (`boltz-mlx …`) and add a
  smoke test that the artifact is non-empty.

## Feature bundles (`export-features`)

Emit the exact tensors the Swift featurizer must reproduce, from a small human-readable input
(a YAML naming sequences / MSAs / ligands). These bundles are *also* the parity reference for the
Swift featurizer (Phase 3). Two properties make bundles pinnable **bitwise**:

- **The inference feature path is deterministic** when training-only randomness is off. Boltz's
  `process()` sets `max_seqs_batch = max_seqs` and `msa_sampling = training and msa_sampling` with
  `training=False` — no RNG, so the MSA/profile tensors can be pinned exactly. The exception is
  anything randomly augmented per instance (e.g. `ref_pos`) — those cannot be pinned, only
  distribution-checked.
- **A mismatched input degrades silently upstream.** Boltz's `construct_paired_msa` compares only
  the *first* sequence's length, prints a warning, and continues at `msa_depth 1`. The Swift side
  should **throw** on the mismatch instead — losing the target's alignment means every downstream
  score is of the wrong complex with nothing in the output saying so.

## Rebuilding the Python side (it gets deleted / lives in a scratch venv)

The exporter's venv and vendored upstream are heavy and disposable. Record the exact rebuild:

```bash
uv venv .venv --python 3.12 && uv pip install -e . safetensors mlx
# plus any upstream data cache (Boltz: ~/.boltz/{mols,ccd.pkl}, ~1.8 GB, survives)
boltz-mlx export-model    --checkpoint <ckpt> --output <dir>   # regenerates the pack
boltz-mlx export-features <yaml> --output <dir>                # note --output is a required FLAG
```

Publish the artifact as a release asset (Phase 6); never commit it. Keep the export *command* in
the repo so anyone can regenerate byte-identical weights from a checkpoint they supply.
