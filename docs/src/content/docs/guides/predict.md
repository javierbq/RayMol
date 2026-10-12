---
title: Structure Prediction
description: Fold single sequences and multi-chain complexes on-device in RayMol using Boltz-2 and Protenix.
---

RayMol includes an on-device structure prediction engine powered by Apple Silicon
MLX. You can fold individual protein sequences or multi-chain complexes directly
in the viewer without sending structural data to cloud prediction APIs or
manually exporting and importing coordinate files.

Open the prediction bar by choosing **Tools ▸ Enter Predict Mode** or pressing `⌃P`.

:::note[Platform availability]
Structure prediction requires Apple Silicon hardware running **macOS** or physical
**iOS 18+** / **iPadOS 18+**. The iOS Simulator is not supported. On iOS, prediction
offers the `boltz2` runtime.
:::

## Available predictors

RayMol registers structure predictors through a unified model registry:

- **`boltz2`** (*default*): Affine int8-quantized Boltz-2 model (~0.5 GB weight
  download). Balances low memory usage with high structural fidelity. Available on
  both macOS and iOS.
- **`boltz2-bf16`**: Unquantized dense bfloat16 Boltz-2 weights (~1 GB). Produces
  identical tokenization and model architecture at twice the disk (~0.5 GB → ~1 GB),
  about 63% more peak memory and ~20% slower, with no demonstrated accuracy gain
  over int8 on-device. macOS only — it is refused on iPhone/iPad because the
  on-device memory guard is calibrated against the int8 pack.
- **`protenix-base-int8`** and five sibling packs — `protenix-{base,v2}-{int8,fp16,bf16}`,
  225–610 MB depending on the pack — AlphaFold3-class predictor supporting single chains
  and complexes with a confidence head. macOS only. Typing `protenix` on the command line
  is a shorthand for `protenix-v2-int8`; it is not itself a selectable id.

Predictor weights are not bundled into the base app download to keep the initial
installer small. On first run with any predictor, RayMol downloads the pinned
weight bundle from GitHub releases into a local on-device cache.

## Inputs and setup

The docked Predict bar accepts:

- **Sequence**: Raw one-letter amino acid sequences (e.g. `MKTII...`). Separate
  multiple chains with a forward slash `/` (e.g. `SEQ1/SEQ2`). A comma cannot be
  used — the command parser reads it as an argument separator.
- **Selection**: Any active PyMOL selection (such as `sele` or `chain A`). RayMol
  extracts the contiguous amino acid sequences and chains automatically.
- **Loaded object**: Click the cube menu beside the input field to choose any
  molecule currently in the session.

### Predictor options

In the main Predict bar:

- **Model selector**: lists every predictor this device can run — on macOS `boltz2`,
  `boltz2-bf16` and the six `protenix-*` packs; on iPhone/iPad only `boltz2`.
- **Model count (`×N`)**: Number of independent sample models to generate (default
  `1`, up to `20`). Multiple models are saved as separate states of a single result
  object.
- **MSA checkbox**: Toggle multiple sequence alignment retrieval. Disabled when
  the selected model does not support external MSAs.

Click the sliders button (**Advanced options**) to expose:

- **Recycling steps (`recycle`)**: Number of recycling iterations (default `3`,
  range 1–10).
- **Diffusion steps (`diffuse`)**: Number of reverse-diffusion sampling steps
  (default `200`, range 10–500).
- **Random seed (`seed`)**: Set an explicit integer for reproducible sampling, or
  leave on `auto` for a randomized run.
- **MSA depth (`depth`)**: Maximum alignment sequences passed to the featurizer
  (leave on `auto` or customize).
- **MSA mode (`mode`)**: Alignment filtering strategy (`env`, `all`, `env-nofilter`,
  `nofilter`).
- **MSA server (`server`)**: Choose between the public ColabFold server or any
  custom private server.
- **Result name (`name`)**: custom PyMOL object name for the output (defaults to
  `<predictor>_prediction_<digest>`, e.g. `boltz2_prediction_f2b2e116`; re-folding
  the same sequence with the same method appends another model to that object).

## Multiple sequence alignments (MSA)

Structure predictors achieve higher accuracy when guided by multiple sequence
alignments. RayMol can query ColabFold MSA servers directly from the interface:

1. Enable the **MSA** toggle on the Predict bar.
2. Under **MSA for:**, toggle which individual chains should receive an alignment.
   Mixed queries are supported: for instance, you can query an alignment for a
   natural target chain while leaving a designed synthetic chain single-sequence.
3. Choose the server in Advanced options or the MSA server picker.

### Configure MSA servers

You can configure your own private MMseqs2 / ColabFold server endpoint (for
example, inside an institutional intranet):

- Open the **Server** dropdown and choose **Edit…** or click **＋** (**Add MSA
  server**).
- Enter the server URL and choose whether it becomes your default (used by new
  sessions and by `msa_search` in the console). Picking a server from the
  dropdown without that option applies to this session only.
- From the console, `msa_server https://your-server.example` sets and saves
  the default server (see the [command reference](/RayMol/reference/commands/)).

:::caution[Privacy and data transit]
Structure inference runs **100% offline and on-device** on your Apple Silicon
GPU. However, when the **MSA** toggle is enabled, your chain sequences are sent
over HTTPS to the chosen ColabFold MSA server. If you work with confidential or
proprietary sequences, disable the MSA toggle to fold in single-sequence mode, or
route requests to an internal private MSA server.
:::

## Progress tray and execution

Click **Run** to submit the job. Prediction runs asynchronously in the background
without freezing the PyMOL rendering loop or blocking user interaction.

The floating **Progress Tray** displays active and queued tasks:

- **Weight downloads**: Displays download progress and byte counts. If a download
  is cancelled or fails, RayMol discards partial bytes cleanly.
- **Active job phases**: The progress bar advances through `featurize`, `load`,
  `trunk`, `diffusion` and `write`. Weight downloads and alignment searches are
  reported separately — the download as its own tray card, the MSA search in the
  Predict bar itself.
- **Countdown timer**: Displays remaining time for the current phase (e.g. `this phase: 2 min left`).
- **Cancel**: Click the **Cancel** button on any card to abort execution.
- **Failure retention**: Failed jobs remain visible in the tray with an error
  diagnostic so you can inspect what went wrong, adjust settings, and retry.
- **Screen awake (iPhone/iPad)**: While a prediction is running RayMol keeps the
  screen from dimming, because a suspended app loses GPU access and the run with it.
  Switching apps or locking the device still ends the fold. On macOS no sleep
  assertion is taken.

## Results and confidence metrics

When inference finishes, the predicted structure loads into PyMOL as an object
(with states corresponding to the requested model count):

- **pLDDT confidence**: Per-residue confidence scores ($0$–$100$) are stored with
  the object. Higher values indicate higher local confidence.
- **PAE matrix**: Predicted Aligned Error matrices (in Ångströms, $0$–$32$ Å) are
  stored per model.
- **Interface metrics**: For multi-chain complexes, interface confidence scores
  such as `ipae`, `ipsae`, and `min_ipsae` are computed.

These metrics are recorded by the Boltz-2 predictors. Protenix currently reports
pLDDT only through the B-factor column (colour it with `spectrum b`); it stores
nothing in the metric store yet.

To color the result by confidence:

```text
metrics_color plddt, boltz2_prediction_f2b2e116
```

For detailed inspection, export, and cross-model comparison of confidence
numbers, see the [Metrics guide](/RayMol/guides/metrics/).

## Size limits and performance

Inference memory scales quadratically with sequence length. RayMol enforces an
internal memory preflight before initiating model allocation:

- If the estimate lands between 50% and 75% of the memory budget RayMol warns
  before running and offers **Run anyway** or **Cancel**. Above 75% the run is
  refused and names the largest input that would fit. Hard ceilings apply as well:
  900 residues on macOS and 164 on iPhone/iPad for Boltz-2, 700 (base) or 550 (v2)
  residues for Protenix.
- **Benchmarked timings** on an Apple M3 Pro (12-core, 36 GiB RAM) using
  `boltz2` (int8, 3 recycling steps, 200 diffusion steps):
  - 117 residues: ~14.5 s (peak memory ~0.6 GB).
  - 200 residues: ~41 s (~3.5 GB).
  - 400 residues: ~2.8 min (~7.4 GB).
  - 600 residues: ~11 min (~13 GB).

Single-sequence predictions complete rapidly; complex multi-chain systems with
deep MSAs require more memory and runtime.

## Related workflows

- Learn how to select specific residues and chains in [Selecting](/RayMol/guides/selecting/).
- Redesign sequences for predicted backbones in [Sequence Design](/RayMol/guides/design/).
- Query and export stored confidence scores in [Metrics](/RayMol/guides/metrics/).
- View scripting options in [Commands Reference](/RayMol/reference/commands/).
