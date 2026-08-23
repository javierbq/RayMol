# Adding a backbone generator

A **generator** produces a protein chain that did not exist. A **predictor** folds a chain
you already have. RayMol keeps them in two packages because that difference goes all the way
down to the input: a predictor takes chain sequences, a generator takes a target
**structure**.

If you are adding a structure predictor, you want [predictors.md](predictors.md) instead.

## Why this is not `predict`

`cmd.predict` maps sequences to a structure. Its whole contract says so:

| | a predictor | a generator |
|---|---|---|
| input | chain sequences, typed or read from a selection | a target structure, plus the interface residues to engage, plus a length |
| output | a fold of the chains you named | a chain that did not exist |
| spec | `PredictionSpec(chains, name, alignments)` | has no sequence to put in `chains` |
| alignments | a real capability (`supports_msa`) | meaningless — nothing to align |

So `Predictor` is the wrong base class. A generator routed through it would have to
implement `parse_spec(sequence)`, and the only honest implementation raises — which would
turn the registry's contract into "every entry folds a sequence, except the ones that do
not", and would offer a generator in `predict`'s Tab-completion.

**What is shared IS shared, by import.** `predictors.weights` (bundles and the digest-pinned
cache), `predictors.fetching` (the non-blocking weight fetch), `predictors.host` (the
request/status file transport) and `predictors.metrics` (the shared metric spec sets) are all
method-agnostic and are reused unchanged. Only the spec, the contract and the command surface
are new.

## Layout

| File | Responsibility |
|---|---|
| `modules/pymol/designing.py` | the `cmd.*` surface; you should not need to touch it |
| `modules/pymol/generators/base.py` | `Generator` contract, `TargetStructure`, `DesignSpec`, `DesignOptions` |
| `modules/pymol/generators/registry.py` | `register` / `get` / `available` / `unregister` |
| `modules/pymol/generators/metrics.py` | the shared geometry spec sets |
| `modules/pymol/generators/rfd3.py` | the shipped method — copy this |
| `swiftui/PyMOLViewer/Shared/InferenceJob.swift` | the wire and the job shell, shared with every predictor |
| `swiftui/PyMOLViewer/Shared/InferenceRouter.swift` | `InferenceRuntime`, and the one table of runtimes |
| `swiftui/PyMOLViewer/Shared/RFD3JobManager.swift` | the Swift runtime that runs it |
| `swiftui/PyMOLViewer/Shared/RFD3ResultWriter.swift` | turning engine output into the object |
| `swiftui/PyMOLViewer/Shared/RFD3SizeGuard.swift` | how much memory one run may claim |

A generator is not a second kind of job. `InferenceJob` carries a design request's `target`,
`hotspots`, `design_length`, `design_chain` and `design_key` alongside a prediction's
`chains` and `alignments`, and `InferenceRouter` dispatches both on the same `PREDICT:`
marker. What differs is the manager the router hands it to, and the Python surface that owns
the placeholder — `designing` rather than `predicting`, which the shell's helpers take as
`pythonModule:`.

## Shipped generators

| id | runtime | weights | notes |
|---|---|---|---|
| `rfd3` | `rfd3` | fp32, 625 MB | RFdiffusion3 via [rfd3-mlx](https://github.com/javierbq/rfd3-mlx), macOS only |

fp32 is the only precision offered because it is the only one the Swift engine has a matmul
path for. int8 measures near-lossless on these weights (coordinate RMSD 0.06–0.09 Å, 97.5–100%
sequence agreement, 9/9 designs docked) and is 3.5× smaller, but it needs `linear()` extended
upstream first — and its large-system latency is bimodal, two of nine runs spiking to 2030 s
and 6979 s against a 389 s median, so it is not a free win either.

## The naming rule

**A generated chain is a "designed backbone", never a "binder"** — in UI strings, object
names, metric keys and metric labels. This is a product rule, not a wording preference:
generation alone does not establish that the chain binds anything. Confirming it needs a
refold of the pair and an interface gate, neither of which RayMol does yet. A measured run
from the port's own benchmarking makes the point — a design scoring min_ipSAE 0.70 had its
chain docked 15.6 Å from the reference pose. The scalar passed it; the pose is what failed.

RFD3Kit's own API says `designBinder` / `binderSequence` / `binderLength`, and those call
sites are unavoidable. `RFD3RuntimeTests.testNoUserFacingStringCallsTheOutputABinder` greps
for the word and allows exactly those symbols, so the boundary is enforced rather than
remembered.

## Steps

1. **Copy `rfd3.py`** to `modules/pymol/generators/<your_id>.py` and pick a permanent `id`.
   It appears in user scripts and in saved metric records: treat it as API. No id may be a
   prefix of another, or `design_backbone <Tab>` stops at a dead end
   (`generate_runtime.testNoGeneratorIdIsAPrefixOfAnother`).

2. **Write the tests first**, in `testing/tests/generate/`. That directory is a *directory*
   entry in `.github/workflows/raymol-embedded-tests.yml`, so a new file inside it runs in CI
   automatically. Do **not** name it `test_*.py` unless you want the pytest lane
   (`testing/testing.py:692-697`). Run one file with:

   ```
   pymol -ckqy testing/testing.py --run testing/tests/generate/<your_file>.py
   ```

   `generate_harness.py` gives you a stub generator, a stub job that writes a real two-chain
   PDB, a `settle()` that waits out the background fetch, a `deliver()` that does what the
   Swift runtime does when a job finishes, and a base test case that restores the host
   environment, the weight-dir override, the registry and the job tables. Two traps the
   prediction suite already paid for:

   - **Test `quiet=0` as well as the default.** `parsing.py:417-420` sets `quiet=0` for any
     command-line invocation whose argspec has `quiet`, while the Python API defaults to
     `quiet=1`. A suite that only exercises `quiet=1` never takes a single message-emitting
     branch. Include the message-helper existence guard too
     (`generate_api.testEveryMessageHelperUsedByDesigningExists`).
   - **Call `settle()` INSIDE the `patch(_urlopen)` block.** The fetch worker outlives the
     call that started it, so an exited patch leaves the thread reaching for the real URL —
     surfacing as a DNS error inside some unrelated test.

3. **Declare the weight bundle.** Publish the zip, then record the sha256 **of the bytes the
   release actually serves** — re-download and hash it rather than hashing the local file you
   uploaded. `members` is the exact archive-root entry set; `WeightCache` asserts it after
   extraction, because a partially-extracted pack usually misbehaves rather than failing.

4. **Implement `check_available`** so the method disappears cleanly where it cannot run.
   Call `host.require_available` and then `host.require_runtime`: the two failures have
   different remedies ("you are headless" versus "this build does not carry that backend"),
   and checking here is what refuses BEFORE a several-hundred-megabyte download. It is also
   the whole platform story — the iOS build advertises `boltz` alone, so no `sys.platform`
   test is needed to keep a macOS-only method off a phone.

5. **Implement `parse_target` to reject, not repair.** Your input is a `TargetStructure` the
   command layer already read out of the session. Reject anything the backend would accept
   and quietly reinterpret. For RFD3 that is: a second chain (the featurizer gives every
   target residue the same `asym_id` and numbers them contiguously, so two chains become one
   joined by a peptide bond that is not there), a residue it has no atom template for, a
   residue whose atoms are not contiguous, a length or token count past the ceilings.

   **Whatever your engine silently drops, catch it here.** RFD3Kit is the cautionary case
   twice over: its PDB reader returns success having discarded every non-standard residue,
   and `designBinder(targetPDB:)` does not design against the PDB you give it at all — it
   routes through `autoTarget`, which substitutes its own most-compact 95-residue window and
   its own three hotspots.

6. **Ship the target as data, not as PDB text.** `DesignSpec.target_wire()` produces one
   entry per residue, in token order, and `TargetStructure.hotspots` are POSITIONS in that
   array. One parse, on the Python side, is one chance to disagree instead of two — and it is
   what lets insertion codes survive (RFD3Kit's reader keys on `(chain, resSeq, resName)` and
   never reads column 27, so 45 and 45A would merge into one residue holding both sets of
   atoms).

   Hotspots are **indices, not residue numbers**. The featurizer tests membership against a
   residue's position in the array it was handed and never reads a residue number, so a
   hotspot given as `45` conditions the design on the 46th residue — a design aimed at the
   wrong place, which looks like a bad design rather than a bug.

7. **Apply the object matrix when you read the session.** `cmd.iterate_state` reports an
   atom's STORED coordinates; `cmd.get_coords` and `cmd.get_pdbstr` both apply the object's
   TTT matrix and `iterate_state` does not. Measured: after `translate [10,0,0], object=t`,
   `get_coords` reads 9.999 for an atom `iterate_state` still reads as −0.001. RayMol ships
   Move mode, which is exactly a TTT matrix, so a user can move a target and then design
   against it — and without this the design is generated against where the target used to be.
   `designing._apply_object_matrix` does it; reuse that rather than rediscovering it.

8. **Declare `metric_specs` — geometry, not confidence.** A generator has no confidence head:
   the sampler emits coordinates and a sequence, and nothing in it predicts how right they
   are. `generators/metrics.py` carries `DESIGN_SPECS`. Declare only what your method
   genuinely produces: a caller that finds `plddt` in the schema is entitled to conclude the
   tool can produce it (`generate_runtime.testAGeometryOnlyGeneratorDeclaresNoConfidenceKeys`
   pins this).

   Anything the **runtime** measures and Python cannot see is written by the Swift side as a
   metric document at `request.metrics_path`, in the format [metrics.md](metrics.md) gives.
   `RFD3JobManager.Geometry` is the worked example, and it is a translation layer rather than
   a direct dump for two reasons: it is where the upstream field names carrying "binder" are
   renamed, and `RFD3Model.Stats` has public fields but only an internal initialiser, so a
   host cannot construct one for a test. Elapsed time and peak memory already reach the store
   through the status file — do not send them twice from two sources that could disagree.

9. **Emit the target and the designed chain TOGETHER, with the target where it already was.**
   That pair is what a later refold takes as input, so splitting it here makes the refold step
   re-derive it. And the target must be emitted from the ORIGINAL atoms — see
   `RFD3ResultWriter`, which exists because the engine's output is in a translated frame,
   renumbered 1..N per chain, sidechain-free, and carries the sequence head's argmax as chain
   A's residue names rather than the input's identities.

10. **Give every design a stable identity.** `DesignSpec.design_key` hashes the generator,
    the weight pack, the target's residues AND coordinates, the hotspots, the length, the seed
    and the schedule. Everything that changes the coordinates goes in, and nothing that does
    not — the object name is deliberately excluded, so two identically-specified designs under
    different names key the same. A later refold carries the same key, which is what makes
    refold-versus-design RMSD computable without guessing which design a prediction came from.

11. **One design per object.** Two designs at two seeds are different molecules with
    different sequences, not samples of one distribution over one input, so they must not
    stack as states of one object — there would be one metric row per state with nothing
    saying which sequence each described. (`n_models` of a *prediction* is the opposite case,
    which is why it does stack.)

12. **`submit` must not block.** `cmd.design_backbone` is reachable from the console, which
    runs on the main thread, and the app drains PyMOL's feedback buffer from a main-run-loop
    timer — so a blocked main thread cannot even deliver the messages describing why it is
    blocked. The weight fetch is handled for you: `predictors/fetching.py` runs it on a thread
    and `designing.pump()` submits your job once the bytes land.

    On the Swift side this is `InferenceRuntime.submit(_:)`, which the router calls on the
    main thread: refuse there, then hand the work to your own queue. Its sibling
    `cancel(jobID:)` is not optional — the router broadcasts every cancel over its whole
    table, and a runtime that starts jobs it cannot stop is a design the user watches for
    seventeen minutes. Both come from one entry in `InferenceRouter.runtimes`, so the two
    cannot drift apart. Settle every terminal path through `InferenceJob.settle`, which
    writes the status BEFORE discarding the placeholder: `discard_pending` re-reads the
    status to decide whether to keep a failure card, so the reverse order makes a failed run
    simply vanish.

13. **Declare `progress_phases`,** or your users get a spinner. Bands are `(phase, start,
    end)` on an overall 0–1 scale and your job's `status()['fraction']` is completion *within*
    the current phase. Widths are layout, not a time estimate.

14. **Register it** in `generators/__init__.py`'s `_register_builtins()`.

15. **If you add Swift, hand-compile BOTH slices before merging.** No CI job compiles Swift,
    and the shared target has broken each platform from the other three times (#174,
    #226/#238):

    ```
    cd swiftui && xcodegen generate
    xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
        -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation build
    xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS \
        -destination 'generic/platform=iOS Simulator' \
        -skipPackagePluginValidation -skipMacroValidation build
    ```

## The size guard, and why it is not optional

RFD3's out-of-memory failure is **not recoverable**. Peak allocation is quadratic in atom
count, and when it exceeds what Metal can wire, mlx throws `std::runtime_error` from inside a
Metal command-buffer completion handler — on a thread with no handler on its stack, so it
reaches `std::terminate` and the process dies with SIGABRT. A `do`/`catch` does not catch it,
`MLXRuntime.withMLXErrorsAsThrows` does not catch it, and `Memory.memoryLimit` only triggers
cache reclaim. On macOS it takes the user's unsaved session with it.

So the only defence is refusing the input first, and it happens in three places:

| where | what it refuses | why there |
|---|---|---|
| `generators/rfd3.py` `parse_target` | a target past `MAX_TOKENS`, a length past `MAX_DESIGN_LENGTH` | a TIME bound, before any download |
| `RFD3JobManager.preflight` | a malformed request — no target, no hotspots, an out-of-range index | main thread, cheap, immediate feedback |
| `RFD3Model.preflight` with `RFD3SizeGuard.budgetBytes` | a design whose predicted peak exceeds this machine's budget | static and weight-free, so it costs no pack read and touches no GPU |

**Never copy `RFD3Budget`'s coefficients into RayMol.** `RFD3SizeGuard` owns the *fraction*
(0.50 of physical memory — lower than both `RFD3Budget`'s 0.60 default and
`PredictSizeGuard`'s 0.75 wall, because the failure is worse and the measured curve came from
a bare CLI with no renderer) and delegates every number to `RFD3Budget`. The drift is already
scheduled: row-blocking the motif `SinusoidalDistEmbed` upstream takes the quadratic term from
~995 to ~62 bytes per atom², a ~16× cut, and a copied constant would then refuse designs that
fit comfortably.

## Cancellation

A design is **minutes**, so cancel has to mean something. `designBinder` is synchronous, so
there is no `Task` to cancel: `RFD3Model.Options.shouldCancel` is polled before setup, again
after setup, and once per diffusion step, and throws `RFD3ModelError.cancelled`. That hook is
why RayMol needs rfd3-mlx **≥ 0.1.1**; `RFD3JobManager` does not compile against 0.1.0.

Note that `onProgress`'s `total` is `numTimesteps - 1` — the EDM schedule has `numTimesteps`
sigma levels and one fewer transition between them. Drive a bar from the reported `total`,
never from the requested step count, or it stops one step short of the end forever.

## Measured cost

fp32, 200 diffusion steps × 2 recycles, M3 Pro, against full human serum albumin (578 target
residues + a 60-residue design = 638 tokens):

| | |
|---|---|
| wall clock | 821–1321 s per design, median 1001 s (**~17 minutes**) |
| target drift | 0.000 Å |
| backbone bonds in range | 98.3% |
| interface distance | 3.0 Å |

Cost is dominated by the target, quadratically — the port's standalone 50-mer generation is
15.5 s at the same schedule. A small epitope is seconds; a whole protein is a coffee break per
design, and `n_designs` multiplies it.
