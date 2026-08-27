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

## Watching a design diffuse

`design_backbone ..., live_view=1` -- or the **Live** checkbox on the bar -- builds the
design's own object as the rollout runs, one state per captured frame, animating smoothly
between them. Replay it afterwards from the object panel's per-object state
control (see "Which state is on show" below for why it is that rather than the frame slider).

**There is one object, not two.** It is the result's object, under the result's own name,
holding what the result holds: the target as supplied, plus the generated chain. When the
design lands it is appended as one more state and left showing.

What is IDENTICAL between a live run and a plain one, and what is not, precisely -- because
"the same object" is true of the design and not of the container:

| | live | plain |
|---|---|---|
| result file on disk | **byte-identical** | **byte-identical** |
| the design's coordinates | **0.000 A** apart | **0.000 A** apart |
| design key, metrics, metric count | the same | the same |
| bonds, orders included | **identical** (462 vs 462 measured) [^cm] | **identical** |
| states | 51 (the rollout, then the design) | 1 |
| object `state` setting | pinned to the final state | unset |

The remaining difference that matters is the pin: a live object is not a drop-in substitute
for a plain one inside a movie. It is explained under "Which state is on show".

[^cm]: At the default `connect_mode`. `ExecutiveRebond` hardcodes a `connect_mode` of 3, so
    a live-built design ignores a user-set one; measured, the two agree at modes 0, 2 and 3
    and diverge at mode 1, where a plain load produces **no bonds at all** and the live
    object still has its 90. The live result is the better one there, so this is scoping,
    not a defect.

That is possible because both come out of ONE writer, `RFD3ResultWriter.emit`. The finished
design is appended with `load_coordset`, which matches coordinates to atoms by POSITION and
checks nothing, so the seed and the result have to be the same atoms in the same order. Two
builders that must agree eventually disagree; one builder cannot. (`cmd.load` into the
existing object is not an option and not a shortcut: mismatched residue names make PyMOL
treat the incoming atoms as new ones -- measured, a 450-atom object became 530.)

While it runs, two things differ from the delivered result and both are repaired at
delivery:

* the generated chain's coordinates are a rollout frame rather than the answer;
* its residues are named **ALA**, because states of one object share a single atom set and
  the sequence head's argmax churns during the rollout -- a residue is LEU at step 40 and
  VAL at step 80. Delivery renames the chain to the design's real sequence, read out of the
  result. Residue names in PyMOL are per-OBJECT rather than per-state, so every state then
  shows the designed sequence; the target's names are untouched.

### How many states you get: `live_steps`

By default a live run captures every `RFD3JobManager.trajectoryStepInterval` (**4**) steps,
so the default 200-step run leaves **51 states** -- 50 captured frames plus the delivered
design. The FIRST captured frame is the object's state 1, not an extra state after an empty
placeholder.

`design_backbone ..., live_steps=N` asks for a different number. It is a count of STATES,
not an interval: you say how many you want in the object and the every-Nth-step is derived,
because scrub granularity and movie length are what a user actually reasons about. Passing
it turns the live view on by itself.

**Approximate, and refused rather than clamped.** The interval is a whole number of steps,
so the achievable counts are quantised -- over the default 199 rollout steps they run 199,
100, 67, 50, 40, 34, ... and you get the **nearest achievable** count to what you asked. Not
the nearest below: asked for 99 of 199, "at most" would hand back 67 where nearest gives 100.
A count below 1, or above `diffusion_steps - 1` (the rollout has no more steps to capture),
is a command error naming the permitted range and the schedule it came from -- submit-time
input validation, before any job exists, not a runtime degrade.

You are told the real number **before the run starts**, under `quiet=0`:

```
design: live view will capture 29 states (the nearest to the 30 requested -- the interval
is a whole number of steps, so the reachable counts are spaced out), every 7 of the 199
rollout steps; the finished design is appended after them.
```

That is a real run, and the object it produced has **30** states: the 29 captured frames
plus the delivered design.

`live_view=0` alongside `live_steps` is a **contradiction and is refused**: it asks for a
recording length and for no recording at once, and either reading silently throws one of them
away. Drop whichever you did not mean.

### Where the derivation lives, and what the wire carries

`pymol.designing.capture_interval(frames, total)` -- on the PYTHON side, and it is the only
place frames become an interval. That side also knows `diffusion_steps`, which is what lets
the achievable count be reported before the run rather than discovered after it. The wire
then carries `live_interval`, the derived every-Nth-step. Moving to interval semantics later
means returning `frames` unchanged from that one function.

The runtime does no arithmetic ABOUT THE CADENCE — it captures every Kth step — but it does
still compute one thing: the rollout's length, `max(diffusionSteps - 1, 1)`, for
`shouldCapture`'s final-step arm. **That is a cross-language coupling**, and the only one
this feature has: `designing.rollout_step_count` computes the same quantity, and if the two
disagreed the count echoed at submit time would be a lie about the object you get. Both ends
carry a comment pointing at the other, and a Python test greps the Swift source for the
expression so a change on that side fails the suite.

It SCANS rather than dividing, because `round(total / frames)` is not always right: 7 frames
over 199 steps rounds to interval 28, which yields 8, while 29 yields exactly 7.

A request that carries no `live_interval` falls back to
`RFD3JobManager.trajectoryStepInterval`, which is 4. That is not an edge case: Python sends
the key only when `live_steps` was given, so **every live run without `live_steps` uses this
fallback** -- including the app's **Live** checkbox, which sends no count -- as does an older
Python. Being an interval rather than a count is why the states it yields move with the
schedule: 50 at `diffusion_steps` 200, but 5 at 20 and 2 at 6.

Each frame on the wire carries the **generated chain only**. Resending the static target
fifty times would be pointless traffic, so `trajectory_seed` records how many atoms precede
the generated chain and how many are in it -- both reported by the writer that emitted the
seed, from `RFD3ResultWriter.Composed`, never counted or guessed on the Python side -- and
`trajectory_frame` splices each frame onto the target's coordinates from state 1. The
atom-count guard therefore compares against the GENERATED CHAIN's atom count, not the
object's; a frame sized for the whole object is refused. The seed also remembers the
generated chain's own state-1 coordinates and every frame checks them, so a frame cannot
land on an object that merely shares the name -- yesterday's `.pse` of the same design,
reopened mid-run, matches on atom count exactly, and what separates them is that its state 1
is the finished structure where the recording's is the step-4 seed. Remembered in
`_TRAJECTORY`, never written into the object: a token stamped into state 1's title looked
tidier and was not, because `ObjectMoleculeLoadCoords` copies the first coordinate set --
`CoordSet`'s copy carries `Name` -- so it spread to every appended state and the inspector
rendered it as a **Name** row for the whole run.

### Smooth motion, without inventing any states

The captured frames arrive about once a second, so showing each one as it lands is a
slideshow: the atoms teleport from one conformation to the next. The live view interpolates
instead — but **it does not add states to do it**.

The object holds exactly one state per captured model frame, as it always has. Alongside
them sits **one extra state, the display**, whose coordinates are rewritten
`RFD3Trajectory.playbackTicksPerSecond` (30) times a second with a position interpolated
between the last two captured frames. That constant is the only definition of the rate:
`display_fraction` is a function of elapsed TIME rather than of tick count, so the Python
side gives the right answer at any rate and at irregular ticks. So:

* every state in the object is model output, and nothing has to be labelled or explained;
* the display state is overwritten by the next captured frame as soon as it lands, so no
  interpolated coordinate outlives the gap it belonged to;
* at delivery the display state becomes the finished design, and the finished object is the
  captured frames plus the design — **the same states a run without smoothing produces**.

The display necessarily runs **one frame behind**: a gap can only be animated once both of
its ends are known. The first captured frame has no predecessor, so it is simply shown.

`display_fraction` is time-based rather than tick-counted, so a tick that arrives late lands
where it belongs rather than where a punctual tick would have been, and it **saturates at 1**
rather than extrapolating: if the next frame is slow the display waits on the newest captured
frame and never runs past a coordinate the model produced. `interpolate_frame` returns both
endpoints **by copy rather than by arithmetic**, because `a + (b - a) * t` is not bit-for-bit
`a` at t=0 nor `b` at t=1 in floating point, and the model's own coordinates are never
approximated.

**Cost.** Per tick, on the main thread, while a GPU rollout runs. Measured on the real
450-atom design:

| | |
|---|---|
| working tick (interpolate + identity check + load) | **0.182 ms** |
| — of which the identity check | 0.132 ms |
| idle tick (gap run out, next frame not yet landed) | **0.004 ms** |
| at 30 Hz | **0.55% of one main thread**, 5.5 ms/s |

The identity check dominates, and it earns it: it is the only thing between this loop and
someone else's coordinates. It sits *after* the fraction early-out on purpose — a tick that
writes nothing needs no guard on a write, which is what keeps an idle tick at 0.004 ms rather
than paying the check to discover it has nothing to do.

The forced repaint is a real GPU frame and is **not** conditional — the coordinates change on
nearly every tick, which is what smooth motion is, so there is no cheaper condition to test.
That is what showing motion costs and it is not specific to this approach.

**If the user moves the object** — the panel's state control, a typed `set state`, a scrubbed
slider — the object is no longer showing the display state, which is the only thing the
animation touches. That is detected exactly, with no polling, and the animation stops for the
rest of the run rather than dragging the user back thirty times a second. Delivery still pins
to the finished design afterwards.

The last hop, from the final captured frame into the delivered design, is **not** animated:
the head is stopped before delivery so it cannot race the pin. That is one jump, at the end.

### Which state is on show

Through the OBJECT's own `state` setting, never `cmd.frame`. `cmd.frame` writes the global
MOVIE frame, and `CObject::getCurrentState` prefers an object's own `state` setting and only
falls back to the global -- so in any session that already carries an `mset` (a Timeline the
user built, a movie, a reopened `.pse`) `cmd.frame` maps through the movie and the object
never moves. Measured with `mset '1 x10'`: states grew 2, 3, 4, 5 while the displayed state
stayed 1, 1, 1, 1, and after delivery the object showed **state 1** -- the step-4 poly-ALA
seed wearing the designed residue names, which `cmd.save` at its default `state=-1` would
have exported as the design.

The cost, stated rather than papered over: a delivered live object is **pinned** to its final
state. To replay the rollout afterwards, move that setting -- the object panel's per-object
state control does exactly this -- or `unset state, <name>` to hand the object back to the
global frame.

### What is streamed: px0, not the iterate

The stream is `RFD3Model.Options.onStepDenoised`, which carries **px0** -- the denoiser's
prediction of the CLEAN structure at that step -- and not the raw EDM iterate. That choice
is what makes the feature watchable rather than merely correct. The iterate's schedule
starts at `sigma_data` (16) x `s_max` (160) = 2560 A, so its early states are an off-screen
cloud; px0 stays protein-scale, because the EDM output preconditioning scales the
network's output by `sigma_data` rather than by sigma. Measured upstream on a 50-step
albumin rollout: **33.9 A at step 1**, against 6,904.6 A for the iterate at the same step,
and 35.8 / 36.1 / 35.2 / 39.2 / 38.9 A at steps 1 / 10 / 20 / 30 / 49. You see a structure
wriggling into shape from the first captured frame, not a cloud collapsing into the
viewport half way through the run.

That holds comfortably at the default 200 steps. `diffusion_steps` is user-settable,
though, and a very short schedule gives the model fewer, coarser steps to work with: at
`diffusion_steps=6` a captured px0 frame was measured at 156 A by step 4 and 335 A by
step 5. Still well inside the writer's representable range, so nothing is dropped or
corrupted -- just less tidy to watch.

Requires rfd3-mlx **>= 0.1.3**; 0.1.3 removed the older `onStepCoords` hook rather than
deprecating it.

### Why the seed states its bonds -- and unbonds the two chains

PyMOL decides connectivity ONCE, when the seed is read; `load_coordset` moves atoms and
never re-bonds them. So the bonds you are watching for the whole rollout are whatever PyMOL
made of the FIRST captured frame, which is step 4 of 199 and is not a settled backbone.
(Only until delivery: it re-derives them from the finished structure -- see below. Before it
did, that step-4 guess was the object's connectivity for life, and went into every saved
session. Note that PyMOL's bond table is per OBJECT, so delivery's re-derivation replaces
the connectivity of *every* state, not only the last one -- the rollout states end up drawn
with the finished structure's bonds. Scrub back after unpinning and that is what you see.)
Two consequences, and they pull in opposite directions.

**The generated chain needs bonds stated.** The seed carries **CONECT records** for it,
numbered from `Composed.designFirstSerial` -- the generated chain no longer starts at serial
1, and a record naming serial 1 would bond two atoms of the target. Inference is not good
enough here even at px0's protein scale: it does not fail loudly, it degrades. Measured on a
24-residue poly-ALA chain that needs **119** bonds (4 per residue plus 23 peptide bonds),
seeded without CONECT: 89 / 54 / 37 bonds at 1 / 2 / 3 A of per-atom jitter, and 5 from a
protein-scale cloud. With CONECT it is 119 in every one of those cases -- and 119, not 238,
from settled geometry, because PyMOL MERGES stated bonds with what it would have inferred.
The topology is known a priori anyway: this chain is poly-ALA with a fixed atom set.

**The two chains need bonds REMOVED.** That merge is also why the seed cannot simply be
read and left alone. A generated chain is *meant* to sit against the target, so an early,
unsettled frame routinely puts some of its atoms within bonding distance of target atoms,
and PyMOL bonds them -- permanently. Measured on a real 24-residue design against a
40-residue target: an early frame produced **34** inter-chain bonds where the finished
structure has **0**, drawn as sticks joining the design to the target in every state. So
`trajectory_seed` unbonds the target from the generated chain immediately after reading,
addressing both by **rank** from the recorded layout. Nothing legitimate is lost: the result
path produces no inter-chain bonds either.

### Delivery re-derives the bonds, and why it must

The seed's connectivity is for the RECORDING, and it is not the connectivity the delivered
design should have. Two reasons, and each on its own is enough:

* **A plain `CONECT` is order ONE.** The result file carries no CONECT, so a plain run
  INFERS the generated chain's carbonyls as DOUBLE bonds. Without re-deriving, the same
  design came out with C=O order 2 without `live_view` and order 1 with it -- measured on
  an 8-residue design, 8 double bonds on the generated chain against 0. That is visible,
  not bookkeeping: `valence` is on by default and both the wire and cylinder renderers
  branch on bond order. It persisted into any saved session.
* **The seed is bonded from step 4 of 199**, which is why it needs stated records at all,
  and why the two chains have to be unbonded from each other there. The finished structure
  deserves neither crutch.

So `_finish_trajectory` calls `rebond` on the FINAL state -- the delivered design, which is
exactly what a plain run bonds from. Measured on the real 450-atom design: **462 bonds
against 462, identical including orders, zero differing bonds**, and identical again after a
`.pse` round trip. A delivered design's chemistry does not depend on a view-only checkbox.

An oddity worth knowing while reading those numbers, though it is no longer a live/plain
difference: the engine allocates five atoms for every designed residue including glycine,
which has no CB, and the unused slot comes back **coincident with the CA** -- measured 0.01 A
from it against 1.52 A for every other residue in the same design, which puts it 1.47 A from
its own N and 1.52 A from its own C, so inference bonds it to both. That is upstream of this
branch, is tracked separately, and is now identical with and without live view.

### Two orders, and which one addresses what

PyMOL keeps atoms in a SORTED order -- `AtomInfoCompare` orders by chain before residue
number, and `retain_order` is 0 -- which is **not** the order the writer emitted them in.
`rank` is the file position; `index` is the sorted position. They coincide only when the
target's chain letter sorts before the generated chain's, and `_free_chain_id` hands the
generated chain `'B'` for every target except a chain-B one, so for 24 of the 26 letters the
generated chain sorts **first** and `index 1-<offset>` spans both chains. Measured on a
target/design pair of H/B: `rank 0-19` is `{H}`, `index 1-20` is `{H, B}`.

So everything on this path is addressed by rank: the unbond, the order proof, and the
residue rename at delivery. `load_coordset` is rank-keyed too, which is why it is the
primitive the frames go through -- measured by pushing the design's file-order slice 500 A
and watching chain B, and only chain B, move.

Note what is *not* a reason: the target cannot share the generated chain's letter.
`_free_chain_id` picks one the target does not use, over a target `require_single_chain` has
already reduced to a single chain.

### Coordinates come from PDB text, never from `cmd.get_coordset`

Worth knowing before extending any of this. `cmd.get_coordset` is numpy-backed and returns
**None** in the packaged macOS app, while returning a real array under the headless PyMOL
the test suite runs on. Built on it, live view failed on every real design and passed every
test: the seed threw on the None and left no record, all fifty frames were dropped, and
delivery fell back to `cmd.load` on top of the seeded object -- 450 atoms became 530.

Both coordinate reads therefore slice the fixed columns of PDB TEXT (`_pdb_atom_records`):
the seed string in `trajectory_seed`, the result file in `_finish_trajectory`. That is also
the order `load_coordset` wants -- "the original atom order (order from PDB file)", not the
property-sorted order `iterate` and `load_coords` use -- and the file is the only thing that
has it. The seed then PROVES the two orders agree, once, by checking every atom PyMOL holds
against the atom the string wrote at that position; a reader that sorted would otherwise put
target coordinates on the generated chain for a whole run, silently.

### Camera, lifetime and failure

Seeding does not move the camera, and neither does any frame or the delivery: a design is
minutes long and the user is looking at the target, so the object appearing in the object
panel is all the announcement it gets. Off by default -- turning a one-state result into a
51-state one is a reasonable thing to opt into and an unreasonable thing to be given.

**A run that does not finish leaves nothing.** The object bears the design's own name, so a
rollout frozen at step 84 must not be left under it: it would be indistinguishable from a
finished design in the object panel, carry no metrics and no design key, and survive into a
saved session. `discard_pending` -- what the runtime calls on cancel or failure -- therefore
deletes it, and `session_save` drops it from a `.pse` saved mid-run, both keyed on the same
record that says every atom in there came from the recording. Once the design has landed the
record is gone and the object is an ordinary result that neither will touch. This is a
change from the earlier two-object model, where a cancelled run left its `<result>_traj`
recording behind.

Metrics are unaffected: `record_run` still files once, from `deliver_result`, against the
object name, with the state it landed in -- which is `count_states`, the last state for a
live run and the only one for a plain one, in both cases the finished coordinates.

Every failure in this path degrades to "no live view" and never fails the design. If the
seed cannot be composed or read there is simply no recording, and the design loads at the
end exactly as it would without `live_view`. If a recording cannot be completed into the
result -- an object the user edited, a result that no longer lines up -- it is thrown away
and the result is loaded plainly, with a warning saying so. Every refusal on this path is
audible: a seed that cannot be used says why, once, and puts the empty placeholder back so
the design keeps its row in the object panel for the rest of the run.

A frame is dropped WHOLE, never half-loaded, when its
atom count is not the generated chain's, when it is not three floats per atom, when any
coordinate is non-finite, or when one falls outside what a PDB ATOM record can represent
(`RFD3ResultWriter.coordinateRange`, -999.999 to 9999.999 A). The last of those is the same
guard for the same reason: the writer's coordinate columns are eight characters wide and
`%8.3f` widens rather than truncates, so a value needing nine would shift every later field
on the line and be read back as different coordinates entirely -- silently, since the line
still parses. The guard and the formatter share one definition of the range so they cannot
drift apart.

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
