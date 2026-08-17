# Adding a structure predictor

RayMol's prediction backend is a registry of interchangeable predictors plus a shared,
predictor-agnostic weight cache. Adding a method means adding one module and one line.

See [the design](superpowers/specs/2026-08-11-structure-prediction-backend-design.md) for why
it is shaped this way.

## Layout

| File | Responsibility |
|---|---|
| `modules/pymol/predicting.py` | the `cmd.*` surface; you should not need to touch it |
| `modules/pymol/predictors/base.py` | `Predictor` contract, `PredictionSpec`, `PredictionOptions` |
| `modules/pymol/predictors/weights.py` | `WeightBundle`, `BundledSource`, `WeightCache` |
| `modules/pymol/predictors/registry.py` | `register` / `get` / `available` / `unregister` |
| `modules/pymol/predictors/host.py` | transport to the Swift inference host |
| `modules/pymol/predictors/_template.py` | copy-me skeleton |

## Shipped predictors

| id | runtime | weights | notes |
|---|---|---|---|
| `boltz2` | `boltz` | affine-int8, 507 MB | the default |
| `boltz2-bf16` | `boltz` | dense bfloat16, 996 MB | same model, same runtime, unquantized |
| `protenix-base` | `protenix` | affine-int8, 214 MB | complexes, single sequence. **Not runnable yet** — no build carries the `protenix` runtime, see #309 |

## Runtimes

A predictor's **runtime** is the Swift backend that runs it, named on the wire by
`host.submit(..., runtime=)`. It is a separate axis from the predictor id: `boltz2` and
`boltz2-bf16` are two predictors and one runtime, because `host.submit` sends `weights_dir`
per job and the Swift side picks its matmul path from the artifact manifest — a dense pack
declares no quantization block — so one runtime serves both.

The distinction has to be on the wire because weights and featurizer are method-specific.
Running one method's request on another's backend does not fail; it tokenizes with the
wrong featurizer and returns a confident wrong structure. So:

- `BoltzJobManager` implements `boltz` and **refuses** any other in `preflight`, before it
  applies its size model — which is fitted to Boltz's measured peaks and would be
  meaningless applied to another method's request even as a refusal.
- `PyMOLBridge` advertises what is actually linked in `RAYMOL_PREDICT_RUNTIMES`, which is
  what lets `check_available` refuse **before** a weight download rather than after.
- `Request.runtime` is **optional** on the Swift side, absent meaning `boltz`. A
  non-optional field would turn any Python/Swift version skew into "malformed prediction
  request" instead of a refusal that names the missing runtime. The same reasoning applies
  to `object_name` and `alignments`.

That default is also the trap: a new predictor that forgets to pass `runtime=` is silently
dispatched to Boltz. `predict_runtime.py` asserts every registered predictor names one.

`boltz2-bf16` subclasses `Boltz2Predictor` and overrides nothing but `weight_bundle`, which
is what "two predictors, one runtime" looks like in practice. It needs boltz-mlx >= 0.2.0.

It is **not** an upgrade. On an M3 Pro at 117 tokens, recycling 3 / 200 steps, dense
bfloat16 costs 2x the disk, +63% peak RSS (620 MiB -> 1012 MiB) and +22% wall clock
(14.50 s -> 17.76 s), because MLX's `quantizedMM` beats a dense fp16 matmul on these
memory-bound shapes. And it buys no *demonstrated* accuracy: the two packs differ by
3.1 A at a fixed seed, while the model's own seed-to-seed spread within int8 alone is
4.9-7.0 A. Ranking them needs ground truth and many samples per condition. It exists so
that experiment is possible on-device.

Note also that the Boltz-2 checkpoint is float32 throughout — there are no original
bfloat16 weights to load. Both dense widths are a narrowing of that float32, and
float16 is the closer one at identical size (`--precision float16` exports it).

## Steps

1. **Copy the template** to `modules/pymol/predictors/<your_id>.py` and pick a permanent
   `id`. It appears in user scripts and saved sessions: treat it as API. Avoid making it
   an *extension* of an existing id if you can: `boltz2-bf16` shares a prefix with
   `boltz2`, so `predict b<Tab>` now stops at `boltz2` with no `, ` separator instead of
   completing to a runnable command.

2. **Write the tests first.** Add `testing/tests/predict/predict_<your_id>.py` subclassing
   `pymol.testing.PyMOLTestCase`. Do **not** name it `test_*.py` unless you want the pytest
   lane — the runner routes on that prefix (`testing/testing.py:692-697`). Mock the network by
   patching `pymol.predictors.weights._urlopen`; never reach a real server. Run it with:

   ```
   pymol -ckqy testing/testing.py --run testing/tests/predict/predict_<your_id>.py
   ```

   Two things that will bite you:

   - **Test `quiet=0` as well as the default.** `parsing.py:417-420` sets `quiet=0` for any
     command-line invocation whose argspec contains `quiet`, while the Python API defaults to
     `quiet=1`. A suite that only exercises `quiet=1` never takes a single message-emitting
     branch. That is not hypothetical: the first cut of this backend was 48/48 green while
     every one of those branches raised `AttributeError` on a `colorprinting` helper that does
     not exist.
   - **A sibling import needs an explicit `sys.path` shim.** The runner imports test files by
     path and never adds their directory to `sys.path`, and `setUp`'s chdir does not affect
     module resolution. See the top of `testing/tests/predict/predict_api.py`.

3. **Declare the weight bundle.** Publish the zip, then record the sha256 **of the bytes you
   uploaded** — re-exporting a quantized model is not guaranteed to reproduce them bitwise, so
   never hash a local rebuild and assume it matches. `members` must be the exact archive-root
   entry set; `WeightCache` asserts it after extraction, because a predictor handed a
   partially-extracted bundle usually misbehaves rather than failing.

4. **Implement `check_available`** so the predictor disappears cleanly where it cannot run
   rather than failing mid-run. Platform, OS floor, host presence — not weight state, which the
   weight manager is allowed to fix by downloading.

   If your method needs a Swift backend of its own, call `host.require_runtime` after
   `host.require_available`: the two failures have different remedies ("you are headless"
   versus "this build does not carry that backend"), and checking here is what refuses
   BEFORE a multi-hundred-megabyte download rather than after it. A bulk
   `predict_weights download=1` also consults this, so a predictor that cannot run is
   reported but not fetched.

5. **Implement `parse_spec` to reject, not repair.** If the backend silently ignores input it
   does not support, catching that is your job: check what it does with a ligand, a nucleic
   acid, an `X`, and an empty chain, and raise for each. boltz-mlx is the cautionary case —
   its `fromResidues` *excludes* non-canonical residues with a diagnostic and returns success,
   so handing it a selection containing a ligand yields a protein-only complex with the ligand
   quietly gone.

6. **Implement `validate_options` to reject unknown options.** The base class does this for you
   if `option_defaults` is accurate. Accepting and ignoring a quality knob produces results the
   user believes are something they are not. Note that a knob you want to *reject* must still
   appear as a named parameter on `cmd.predict`, or Python raises `TypeError` before your
   validation runs.

7. **Declare `supports_msa` — and mean it.** It is `False` on the base class, so a method that
   says nothing REFUSES `predict ..., msa=...` by name. That is the point: a predictor that
   accepted an alignment and folded single-sequence anyway would return a worse structure with
   nothing in the result saying the alignment had been dropped. Upstream Boltz is the
   cautionary case here — it silently substitutes a depth-1 dummy MSA when an a3m does not
   match its chain, so every score it then reports describes the wrong complex.

   Setting it `True` means three things:

   - read `spec.alignments` in `submit`. It is `{chain id: MSA}` and it is **partial**: a chain
     with no entry is folded single-sequence. Mixed is the design case, not an edge case — a
     real alignment for the target and none for a designed binder, which has no homologs.
   - add `'msa_depth': MAX_MSA_DEPTH` to `option_defaults`, or the depth lever is rejected by
     name. That is correct for a method with no depth to lever, and wrong for one that has.
   - keep the alignment's bytes intact. `MSA.a3m` is the file VERBATIM because the parser at
     the far end reproduces upstream's bugs deliberately; re-serializing it from a parse makes
     any parity claim a statement about a file that no longer exists.

   The base `bind_alignments` already refuses an alignment whose query is not exactly the
   chain's sequence. Override it only to add a constraint of your own, then call `super()`.

8. **`submit` must not block.** `cmd.predict` is reachable from the console, which runs on the
   main thread, so blocking stalls the render loop for the whole inference.

   Nothing on that thread may block for long, and the reason is sharper than "the UI stutters":
   the app drains PyMOL's feedback buffer from a **main-run-loop timer**, so a blocked main
   thread cannot deliver even the messages describing why it is blocked. That is exactly how
   #284 happened — the weight download ran inline and its own `download NN%` lines were
   invisible until it had finished.

   You get the weight fetch handled for you. `predictors/fetching.py` runs it on a thread and
   `predicting.pump()` submits your job once the bytes land, so `submit` is simply called
   later — still on the main thread, so it may use the session normally. The **worker** is the
   thread with the hard restriction: filesystem and `print` only, never the PyMOL session,
   because RayMol's Metal renderer reads object state on the main thread without taking
   PyMOL's API lock. If you extend the fetcher, keep every session touch inside `pump()`.

9. **Register it** in `predictors/__init__.py`'s `_register_builtins()` — the only file that
   changes outside your own.

10. **Make CI run your tests.** `.github/workflows/raymol-embedded-tests.yml` hand-enumerates
   test paths. The `testing/tests/predict` directory is already listed, so a new file inside it
   runs automatically. If you add a path by hand anywhere in that list, **rebase onto master
   first** — the list has silently dropped files before, and PR #259 had to retro-add seven.

11. **If your predictor adds Swift**, hand-compile **both** the macOS and iOS slices before
    merging. No CI job compiles Swift, and the shared target has broken each platform from the
    other before (#174, #226/#238).
