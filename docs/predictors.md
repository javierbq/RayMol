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

## Steps

1. **Copy the template** to `modules/pymol/predictors/<your_id>.py` and pick a permanent
   `id`. It appears in user scripts and saved sessions: treat it as API.

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

7. **`submit` must not block.** `cmd.predict` is reachable from the console, which runs on the
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

8. **Declare your progress phases, or your users get a spinner.** `progress_phases` is
   an ordered tuple of `(phase, start, end)` bands on an overall 0–1 scale; your job's
   `status()['fraction']` is completion *within* the current phase, and the app composes
   the two. The base class declares none, so a predictor that skips this shows an
   indeterminate card — which is correct if you genuinely cannot report movement, and a
   missed opportunity if you can. Give a phase a zero-width band (`end == start`) to say
   "started, cannot say how far in": that is honest, and far better than a bar frozen at
   a made-up number. Widths are layout, not a time estimate — they cannot track wall
   clock, because the same phase varies by orders of magnitude with input size.

9. **Register it** in `predictors/__init__.py`'s `_register_builtins()` — the only file that
   changes outside your own.

10. **Make CI run your tests.** `.github/workflows/raymol-embedded-tests.yml` hand-enumerates
    test paths. The `testing/tests/predict` directory is already listed, so a new file inside it
    runs automatically. If you add a path by hand anywhere in that list, **rebase onto master
    first** — the list has silently dropped files before, and PR #259 had to retro-add seven.

11. **If your predictor adds Swift**, hand-compile **both** the macOS and iOS slices before
    merging. No CI job compiles Swift, and the shared target has broken each platform from the
    other before (#174, #226/#238).
