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

**The rule is about the OUTPUT, not about the word.**

**A generated chain is a "designed backbone", never a "binder"** — so nothing that NAMES OR
DESCRIBES the result may call it one: object names, metric keys, metric labels, status lines.
This is a product rule, not a wording preference: generation alone does not establish that the
chain binds anything. Confirming it needs a refold of the pair and an interface gate, neither
of which RayMol does yet. A measured run from the port's own benchmarking makes the point — a
design scoring min_ipSAE 0.70 had its chain docked 15.6 Å from the reference pose. The scalar
passed it; the pose is what failed.

**The tool's own name may.** The mode is called **Binder Design**, and that is a claim about
what RFdiffusion3 is FOR — a property of the method, not of any chain it produced. A menu item
saying what you came to do asserts nothing about the result; an object called `binder_1` does.
Where a string is genuinely ambiguous between the two, it says "designed backbone".

RFD3Kit's own API says `designBinder` / `binderSequence` / `binderLength`, and those call
sites are unavoidable. `RFD3RuntimeTests.testNoUserFacingStringCallsTheOutputABinder` greps
for the word over the files that produce user-visible text, allowing those symbols and the
tool's name, so the boundary is enforced rather than remembered.

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

## `n_designs`: one command is one batch

`design_backbone ..., n_designs=10` submits ten designs. They are **not** ten independent
jobs the user can act on separately: `RFD3JobManager`'s queue is **serial**, so exactly one
of them is ever running and the other nine are waiting their turn. Two things follow, and
both hang off a single **batch identity** derived once in `design_backbone`, where the N
specs are built.

**The identity IS the group name.** One string that is the group the finished designs land
in, the title of the progress row, and the argument `design_cancel` and `design_dismiss`
accept — so there is nothing to keep in step between them. Derived from the FIRST design's
key as `<generator>_batch_<key>` (`rfd3_batch_1f4c9e02`), or from `name` when the caller
gave one; "batch" rather than "designs", because `rfd3_designs_<key>` would differ from its
own first member by a single letter. It is legalised through `cmd.get_legal_name` and moved
aside if a **molecule** already answers to it — `cmd.group` on an existing molecule name
*raises*, measured, and it would do so inside delivery, minutes after the command returned.
An existing **group** is not a collision: adding to it is what makes an identical re-run
land back where the first one did.

**`n_designs=1` gets none of this.** A group of one is noise and a batch of one is the row
that already exists, so a single design publishes no batch fields at all and makes no group.

### The group exists from the moment the command returns

Grouping happens at **submit**, on the placeholders, and again at delivery. The clutter this
removes is **mid-run** clutter — ten `rfd3_design_*` rows sitting at top level for the hours
a batch takes — so a group that only formed at delivery would leave that picture unchanged
for the whole run and tidy it up after the user had stopped looking.
`cmd.group(g, name, action='add')` costs **0.0012 ms**, consumes no auto-colour slot, and
leaves the member enabled. The second join at delivery is not belt-and-braces: when a live
recording cannot be finished, `deliver_result` deletes the object and loads the result
fresh, and a deleted object takes its group membership with it.

Being early has three costs. Each is handled.

**A partial session is a READ, not a save.** This is the one that decides whether up-front
grouping works at all, and it is not obvious. RayMol reads the object TREE out of
`cmd.get_session(partial=1)` — `entry[6]` is an object's parent — because nothing else
reports a group's non-molecular children: `cmd.get_object_list` returns the *molecular
leaves*, so it reports a group of zero-atom placeholders as **empty**. But
`designing.session_save` is a session-save task, so it ran on that read too and stripped
the pending placeholders out of it. Measured: `group_parents` returned `{}`, so the panel
drew ten flat rows *next to an empty group* — worse than not grouping at all.
`session_save` now returns early for a partial session (the key `partial` is present, with
value `None`). A partial session already omits view, settings, movie and selections, and
`cmd.save('x.pse')` passes `partial=0`, so nothing that writes a `.pse` takes that branch.
`predicting.session_save` still filters a partial read; a pending *prediction* placeholder
dragged into a group therefore loses its nesting in the panel — a shipped path this change
does not own.

**An empty group must not survive.** A batch cancelled or failed before anything landed
leaves no group, exactly as it leaves no placeholders. The teardown is guarded hard, because
**`cmd.delete` on a group deletes its members too** — measured. Three conditions, all
required: the group exists, every name the batch registered is gone, and the *session* says
the group has no children at all. That last one is what stops the teardown destroying an
object the user dragged in. The membership check is real rather than trusting our own list;
the cheap "is any of mine still here?" pre-filter in front of it exists because
`get_session` serialises every object — **0.11 ms at 200 atoms, 1.29 ms at 2,000, 7.01 ms at
10,000** — and `discard_pending` runs on the main thread every time a job settles.

**A mid-run session save must carry neither.** An empty group is a real object and *does*
round-trip (measured: saved to a `.pse`, it reopens as an empty group), so `session_save`
drops a batch's group when nothing of it survived the placeholder filter. Membership there
comes from the session being saved, so an object the user dragged into the group keeps it.

Applied **identically to a live run and a plain one**. That is not decoration: this branch's
standing invariant is that `keep_frames=0` leaves a session indistinguishable from
`live_view=0`, and a design inside a group in one mode and at the top level in the other
would break it on the object list. The invariant test now runs **both** arms grouped as well
as both ungrouped, and `parent` is one of its axes. A live design is therefore seeded,
animated, identity-checked, state-pinned and delivered from *inside* a group, and the
animation costs the same there: 0.059 ms/tick either way on the same 750-atom object.

### One row, and what it says

`ProgressItem.designBatch` collapses every design record sharing a `batch` into one row.
The batch's `total` comes from the wire (`batch_total`) and **never** from counting the
records present — a delivered design leaves *no* record at all, so a row that counted rows
would report a ten-design batch as a seven-design one by the time it was three in.

**How far through** is the lowest-indexed member that has not settled. Submission order is
queue order, so that member is the one running and every index below it has finished one
way or another. The bar is `(index - 1 + the running design's own fraction) / total`, and
the percentage in the text quotes that same number.

A **partial failure is not a batch failure**. While anything is still running the row stays
a running row and appends `· 1 failed`; only when nothing is left does it become terminal,
and it then reads `1 of 10 failed: <batch>` rather than implying all ten did. A batch nobody
cancelled and that all succeeded simply has no row, because it has no records.

The terminal titles say `failed` and `cancelled`, not `designs failed` and `designs
cancelled`, and that word was dropped on a **measurement**, not a preference: the title is
`lineLimit(1)` in a 340 pt card, and with the real fonts `1 of 10 designs failed:
rfd3_batch_1f4c9e02` is 235.1 pt against 236.2 pt of room while the cancelled spelling is
264.1 pt — over by 28. Truncation is at the tail, so what it eats is the batch **name**, the
half that identifies the row. Dropping one redundant word (this is a design card, with a
design card's icon) buys 45 pt. A unit test measures every batch title against that geometry
so the margin cannot be spent by accident.

**One Cancel stops the lot.** It passes the batch id, which `design_cancel` resolves to
every job of that invocation still outstanding — the running one and the queued ones. A
queued design is refused at the top of `RFD3JobManager.run`, before it featurizes anything;
the next cancellation point is after `RFD3Model.preflight`, which is seconds of CPU per
queued design, so without that check a batch cancel drains slowly instead of at once.
Cancelled members leave **nothing** (their placeholders go with them, the rule the live view
already follows, and the group goes with the last of them) and their cards are retained so
the row can say what happened. **Designs that already finished are untouched and stay in the
group** — cancel stops what has not finished; it does not destroy minutes of completed work.

Nothing about a design's own identity changes: the design key, the object name, the metric
run and the result bytes are what they would be for `n_designs=1` at the same seed. The
batch travels on the **panel** wire (`designing.pending_info` → `design_jobs`), not in the
inference request — the runtime has nothing to do with a batch.

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
  With `keep_frames` off, which is the default, no captured frames are kept at all and the
  object ends as the design alone; see below.

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

### The cartoon evolves, and the target copy is hidden

**Secondary structure is re-assigned on every captured frame**, so the cartoon develops as
the rollout runs rather than appearing only at the end. Scoped to the generated chain: the
target's coordinates never move, so re-deriving its `ss` every second is work for an answer
that cannot change.

The cost is driven by the GENERATED CHAIN's length, not by the object's size -- worth stating
because the object is the obvious thing to measure and it is the wrong variable. Measured
here, holding the object at 900 atoms and varying only the chain: a 24-residue design costs
0.060 ms, a 60-residue one -- `design_backbone`'s default `length` -- costs **0.201 ms**, and
100 residues costs 0.528 ms. Going the other way, +40% atoms at a fixed 60-residue chain
(900 -> 1260) moves it by 3%. So quote the default: **0.201 ms for `dss` plus 0.014 ms for the
cartoon rebuild it dirties, about 0.02% of one main thread** at roughly one captured frame a
second.

Per captured frame rather than per display tick because secondary structure is a slowly
varying property and ~1 Hz is what the eye needs. Cost is not the constraint even so: at the
30 Hz display rate a 60-residue design would be ~0.65% of one main thread, which is
affordable -- it is 30x the work for a picture that does not change 30x a second.

**A caveat that is inherent rather than a bug, so it is written down here rather than left
to be discovered.** `ss` in PyMOL is a per-ATOM property, which means it belongs to the
OBJECT and not to a state. The assignment therefore reflects whichever state `dss` last
looked at — so with `keep_frames=1`, scrubbing back to an earlier kept frame shows that
frame's coordinates wearing the *latest* frame's secondary structure. Nothing can fix that
short of one `ss` per state, which PyMOL does not have. Delivery still runs `dss` against
the **final** state, so a finished design's secondary structure comes from the design and
never from the last interpolated position.

**The target copy is hidden.** The design object is the target plus the generated chain, and
the user already has their own target loaded — so the target half draws duplicate geometry
directly on top of their structure. It is hidden, leaving only the generated chain displayed.

The atoms **stay**: they are what makes the pair a refold's input, they are in the result
file and in the metrics, and hiding is a display flag rather than a deletion. Verified on a
real run — atom count, bonds, metrics and the result bytes are all untouched.

Applied to **every** design object, live or not. The reason for hiding is "this chain
duplicates a target you already have", which is just as true without the live view — and
doing it live-only would make a live object look different from a plain one, which is
exactly the difference `keep_frames=0` exists to avoid.

Hidden **once**, where the object is created, and never again: if you show the target chain
yourself mid-run, nothing puts it back.

### Keeping the frames, or not: `keep_frames`

**Off by default.** Watching the design diffuse is the point; the states are opt-in. A live
run therefore leaves the same single-state object a `live_view=0` run does, unless you ask
for more.

`design_backbone ..., keep_frames=1` — or the **Keep frames** checkbox on the bar, which is
enabled only while **Live** is checked — keeps every captured model frame as a state you can
scrub afterwards. `live_steps` still means the number of MODEL frames captured either way:
with the toggle off they are captured, used to animate, and simply not kept, and the
submit-time echo says so rather than promising states that will not exist.

It is built by **not appending**, never by deleting afterwards. With the toggle off the
object holds the single display state throughout — animated exactly as it is with the toggle
on, because the interpolation's two ends come from the record rather than from states — and
at delivery that slot becomes the design. (Deleting states at the end would have been worse:
PyMOL has no clean per-state delete, and `create`-and-rename would drop the object's
settings.)

**The invariant, and the reason the default is safe: with the toggle off the finished object
is indistinguishable from a plain `live_view=0` run.** Same state count, same coordinates,
same bonds including orders, same residue names, same secondary structure, same metrics,
same design key, same result bytes — and **no leftover per-object `state` pin**, which takes
one extra step: the seed sets one so the "has the user taken over?" check has an unambiguous
baseline, so delivery removes it again when there is only one state to show.

`keep_frames` is a presentation parameter like `live_view` and `live_steps`: absent from
`option_defaults`, absent from `design_key`, and refused as a contradiction if passed with
`live_view=0`.

With the toggle ON the identity check has a subtlety worth knowing. It compares the state
this recording writes to against the coordinates it last put there — the display slot once
there is one, state 1 before that. It used to compare state 1 against the SEED, which worked
only while state 1 was never rewritten; with the frames discarded the object's single state
IS the animated display, so the anchor follows the writes instead.

### Which state is on show

Through the OBJECT's own `state` setting, never `cmd.frame`. `cmd.frame` writes the global
MOVIE frame, and `CObject::getCurrentState` prefers an object's own `state` setting and only
falls back to the global -- so in any session that already carries an `mset` (a Timeline the
user built, a movie, a reopened `.pse`) `cmd.frame` maps through the movie and the object
never moves. Measured with `mset '1 x10'`: states grew 2, 3, 4, 5 while the displayed state
stayed 1, 1, 1, 1, and after delivery the object showed **state 1** -- the step-4 poly-ALA
seed wearing the designed residue names, which `cmd.save` at its default `state=-1` would
have exported as the design.

The cost, stated rather than papered over: a live object **whose frames were kept** is
**pinned** to its final state. To replay the rollout afterwards, move that setting -- the
object panel's per-object state control does exactly this -- or `unset state, <name>` to hand
the object back to the global frame.

On the default path (`keep_frames=0`) there is nothing to pin and nothing to replay: the
object has one state, so the pin is skipped and the seed's own is removed.

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
