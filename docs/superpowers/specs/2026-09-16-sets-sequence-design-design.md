# Sets 3/6: sequence design accepts a set or a view and writes a child set

**Date:** 2026-09-16
**Issue:** #453, part of #421 (tracking); depends on #416 (`pymol.sets.batch`)
**Parent designs:** [protein CAD](2026-09-07-protein-cad-sets-and-data-drawer-design.md)
§1, §5 flow 1, §8; [sets store and .raymol container](2026-09-07-sets-store-and-raymol-container-design.md)
§1; [batch delivery](2026-09-13-sets-batch-delivery-design.md) §1, §2, §4
**Status:** what ships in this step. The store schema is untouched (format version 1).

## 0. Scope, and the hole it fills

`binder_design` and `predict` both take and write sets. Sequence design does not: MPNN
runs in-process on the Swift side only, driven from Design mode, and there is no Python
command for it. So flow 1 breaks in the middle -- 1000 backbones triaged to 20 starred,
and no way to hand those 20 to MPNN. The drawer's **Send to ▾ → Design / MPNN** is
disabled and points here.

This step adds the command, the set delivery, the Swift runtime, and the menu item. It
does not add a second inference implementation: `MPNNModel` and `MPNNRuntime` already
exist and are called, not rewritten.

## 1. Where the code goes, and why a package

A `pymol.designers` package beside `pymol.predictors` and `pymol.generators`, plus a
command module `pymol.designing_sequences` beside `predicting.py` and `designing.py`.

The package earns its place on the same axis the other two do: `design_sequences
<method>, ...` resolves a method id, and an id namespace is a promise about what its
members can do. A designer takes a **backbone** and returns **sequences**; a predictor
takes sequences and returns a structure; a generator takes a target and returns a
backbone. None of the three can stand in for another, so a shared registry's contract
would be "every entry folds a sequence, except the ones that do not" -- the argument
`generators/registry.py` already makes. LigandMPNN and ESM-IF are the obvious second and
third entries and want exactly this shape.

What is shared IS shared, by import: `predictors.host` (transport), `predictors.weights`,
`predictors.metrics` (the shared spec sets), `sets.batch` (delivery). Only the spec, the
contract and the command surface are new.

    modules/pymol/designers/base.py       SequenceDesigner, BackboneSpec, SequenceDesignOptions
    modules/pymol/designers/registry.py   register / get / available / unregister
    modules/pymol/designers/metrics.py    what a sequence designer measures
    modules/pymol/designers/mpnn.py       the shipped method, RUNTIME = 'mpnn'
    modules/pymol/designing_sequences.py  cmd.design_sequences and friends

`designers/metrics.py` becomes the **single declaration** of the `mpnn` metric schema.
`raymol_design.py` registers `native_fit` and `certainty` today under the same tool id
with `replace=True`; two registrations of one tool id, with different spec sets, is a
last-one-wins race. `raymol_design` therefore imports the tuple instead of declaring it.

## 2. The command

    design_sequences designer, source [, name [, n_sequences [, temperature
        [, seed [, fixed [, omit ]]]]]]

`source` is an **object or selection** (today's Design-mode path, from the console) or
`set:<name>[@<selector>]`, parsed by `predicting.parse_set_input` -- the helper #416
added, reused rather than re-spelled. (#450 records that it splits on the first `@` and
should use `rpartition`; not fixed here.)

Registered in `keywords.py` and `api.py` with `parsing.STRICT`, as `predict` and
`binder_design` are. `design_sequences_status` and `design_sequences_cancel` come with it
-- cancellation is a requirement (§7), and a runtime that can be started but not stopped
is a job the user cannot escape.

**The object path is today's Design-mode path with a console in front of it.** It
enumerates the object's residues exactly as `raymol_design.enumerate_design_residues`
does, submits one job, prints the N sequences when they land, and records one metrics-store
run per sequence against the object -- `native_fit` and `certainty` as residue arrays over
the FULL index, masked residues written as None (absent is not zero: a residue with no
backbone was not scored). No set: an object is not a set, and `set_add` is the one step
between them. `n_sequences` defaults to 1 here, which is what Design mode does per click.

**The selection IS the region.** Residues of the object outside `source` are held at
their native identity, so `design_sequences mpnn, sele` redesigns what was picked and
`design_sequences mpnn, myobj` redesigns everything. Without that rule a narrower
selection would resolve to its object and silently redesign every residue in it -- a
different answer from the one the panel gives for the same picks. `fixed=` is the second
knob, for residues to pin INSIDE the region; it is refused for a set input, because a
selection is resolved against the session and a set entry is not in it.

**The set path** resolves the selector to entries, submits one job per entry, and writes
one child set.

## 3. One job per backbone, one entry per sequence

Decided: **one entry per designed sequence** (store spec §1 -- every row in the table is
something you can peek), and **one job per backbone**. 20 backbones x 8 sequences is 160
entries and 20 jobs, not 160: MPNN samples N sequences from one encoder pass, and one job
per sequence would re-run the encoder 8 times for nothing.

That splits the batch's two keys, which `sets.batch` keeps separate anyway:

* the **job key** is the delivery name the runtime echoes back -- the parent entry's name,
  moved aside if the session already answers to it. It is what `_PENDING`,
  `design_sequences_cancel` and `deliver_result` use.
* the **member keys** are `<job key>_s1 .. _sN`, one per sequence, registered with
  `batch.expect` before the job is submitted and landed with `batch.land_sequence` when it
  arrives. `batch.total` is entries x n_sequences, so `running()` counts sequences, which
  is what the drawer's badge should say.

Each entry carries `parents = [<backbone entry id>]`. All of them share ONE run row, added
by `batch.open(..., parent_set_id=<parent set id>)` with the designer, the options, the
selector as typed, every parent entry id and every seed as `inputs`.

## 4. `kind='sequences'`, and what `batch` gains

The child set is `kind='sequences'`: these entries have no structure blob until they are
folded. Two consequences inside `pymol.sets.batch`:

* **A new `land_sequence(member, sequences, scalars, arrays, specs)`**, beside `land`.
  `land` captures an entry FROM AN OBJECT (`binding.capture_object` reads chains and
  sequences out of the session); a designed sequence has no object and never will. So the
  entry is written straight with `Container.add_entry(..., sequences=..., chains=())`.
  Everything else is `land`'s: the `_still_ours` identity check first, the entry write,
  then settle. It is a second LANDING, not a second delivery path -- the batch, its
  identity check, its settle/reap and its `running()` are the same ones.
* **`open(kind=...)` gives a non-structures set zero stage slots.** Staging means "keep the
  delivered object"; there is no object, so `expect` must never promise a placeholder and
  `land_sequence` never stages. Read once at open, as the budget is.

## 5. The wire: request and result

**The keys below are a contract with `InferenceJob.Request` and with `MPNNJobManager`'s
result reader. Changing a name on one side without the other does not fail loudly: it
decodes to a job that runs with a default it was never asked for.**

Request, on top of what `host.submit` already writes (`job_id`, `runtime`, `weights_dir`,
`chains`, `out_path`, `status_path`, `metrics_path`, `object_name`, `seed`):

| key | type | meaning |
|---|---|---|
| `backbone_path` | str | path to a JSON in `enumerate_design_residues` shape: `{object, state, residues:[{chain,resi,resn,aa,valid,n,ca,c,o}]}`. A PATH, and that exact shape, so Swift reuses `DesignResidueSet.parse(jsonAt:)` verbatim -- one parser, not two that can disagree. |
| `n_sequences` | int | how many to sample from this backbone, 1..`MAX_SEQUENCES` (32). |
| `temperature` | float | MPNN sampling temperature. 0 is greedy argmax. |
| `fixed_positions` | [int] | 0-based POSITIONS in `residues` held at their native identity. Positions, not residue numbers, for the reason `hotspots` is: the model never reads a residue number. |
| `omit` | str | one-letter codes disallowed at every position, e.g. `C`. |

`recycling_steps` and `diffusion_steps` become **optional** on the Swift `Request`. They
are non-optional today, and a sequence designer has no diffusion schedule to send; the
three managers that read them take their own default. This is the rule `InferenceJob`
already states out loud -- a non-optional field turns any skew into "malformed prediction
request" for every runtime at once.

Result, written to `out_path` (a `.json`, not a `.pdb`):

```json
{"job_id": "...", "designer": "mpnn", "elapsed_s": 1.9,
 "index": [["A","12"], ["A","13"], ...],
 "sequences": [
   {"n": 1, "seed": 1234, "chains": {"A": "MKTAY..."},
    "scalars": {"sequence_recovery": 0.41, "mean_certainty": 0.72,
                "mean_native_fit": -1.23, "temperature": 0.1},
    "arrays": {"native_fit": [-0.9, null, ...], "certainty": [0.8, null, ...]}}]}
```

`index` is shared by every sequence (same backbone) and is the index both arrays are
written against, in backbone order. A masked residue is `null` in both, never 0.0.
`chains` covers every residue of the backbone, native letters at fixed and unscored
positions, so the entry's sequence is the thing a later `predict` would fold.

**`metrics_path` is unused by this runtime.** A metrics document describes one object;
this job produces N results and no object. Saying so here is cheaper than leaving a reader
to wonder why the file is never written.

## 6. Naming and collisions

The child set is `<designer id>_<n>` -- `mpnn_1`, `mpnn_2` -- from
`batch.free_numbered_name`, exactly as `predict` names `boltz2_1`. `name=` is honoured and
refused by name when a set, an object or a running batch already answers to it; the same
refusal `_predict_set` makes, and for the same reason: the name is already promised to the
run row and the tray by the time the first job starts.

A parent entry with **no structure** is refused before anything is submitted:

    entry d_0417 of mpnn_1 has no structure to design against (a sequence-only entry
    cannot be redesigned; fold it first with `predict`)

Refused for the whole invocation rather than skipped, because a batch that silently drops
a third of a starred view is a campaign with a hole in it that nothing reports.

## 7. Cancellation, and what is left behind

`design_sequences_cancel <job id>` cancels one backbone's job; `design_sequences_cancel`
with the child set's name cancels every job of that batch -- the one running and the ones
queued behind it -- as `design_cancel` accepts a batch id. Swift observes a cancel
**between sequences**: one `MPNNModel.design` call is a single synchronous forward pass
with no cancellation point inside it, so the worst case is one sequence, measured in
hundreds of milliseconds rather than RFD3's one diffusion step.

Every member of a cancelled job settles without landing. `batch._reap` then deletes the
set **if nothing landed at all**, so a campaign cancelled at once leaves nothing; a
campaign cancelled at sequence 40 of 160 keeps the 40 and their run row, which is the
record of what was attempted.

## 8. A `.pse` mid-run

Nothing is stripped, and nothing needs to be: `predicting.session_save` and
`designing.session_save` exist to keep zero-atom PLACEHOLDER objects out of a `.pse`, and
sequence design creates none -- a designed sequence has no object at any point. So this
module registers no session task, deliberately.

A `.pse` save mid-batch therefore leaves the batch running and writes nothing of it into
the file. Results keep landing in the working `.raymol` container, which a `.pse` save does
not touch, and `binding.warn_if_pse_leaves_sets` already tells the user that the sets are
the part a `.pse` cannot hold. What a `.pse` **load** does is what it already does for
every batch: `batch._still_ours` sees a different document, the batch detaches once with a
warning, and the remaining sequences are dropped rather than written into someone else's
set (#445).

## 9. Swift

`MPNNJobManager.swift`, `#if os(macOS) && RAYMOL_MPNN`, modelled on `RFD3JobManager`: a
`final class` singleton conforming to `InferenceRuntime`, one entry appended to
`InferenceRouter.runtimes`, `pythonModule = "designing_sequences"`, its own serial queue,
its own `MPNNModel` cache. It does **not** call `PyMOLEngine.loadedMPNNModel()`: that
cache is documented as belonging to `DesignController.inferenceQueue` alone, and a second
thread reaching into it is a data race on a `MPNNModel?`.

Weights are **bundled**, not fetched: `MPNNGate.packURL`. `weights_dir` is ignored, the
Python designer declares `weight_bundle = None`, and no download can gate a run.

Per sequence: `model.design(residues, options)` for the letters, then
`model.score(residues, sequence: designed, mode: .leaveOneOut)` and
`DesignColor.scores(from:validMask:)` for `native_fit` and `certainty` -- the same two
functions Design mode's panel already draws from, so a stored array colours the way the
live panel did.

`PyMOLBridge.mm` advertises `mpnn` in `RAYMOL_PREDICT_RUNTIMES` on **macOS only**, beside
`rfd3` and `protenix`. MPNN itself is linked on iOS too, but Design mode is gated there on
iOS 18 by `DesignAvailability`, which is a Swift decision the bridge cannot consult before
`Py_InitializeFromConfig`. Advertising a runtime this build may not offer is exactly what
that variable exists to prevent.

The drawer's **Design / MPNN…** item loses its `.disabled(true)` and its tooltip and runs
`design_sequences mpnn, set:<name>@<selector>` through a new
`PyMOLEngine.sendSetToDesignSequences`, mirroring `sendSetToPredict`.

## 10. Tests

Python, on a fake host (the suites already fake by registering a stub whose `submit`
returns a hand-written job -- `sets_batch.py`'s `FakeDesignJob`):

- N sequences x M backbones is an NxM-entry child set: one run row carrying
  `parent_set_id`, the selector and every parent id; each entry's `parents` is its own
  backbone; per-sequence columns (`sequence_recovery`, `mean_certainty`, seed, `n`) and
  the residue arrays present.
- The object path records one metrics run per sequence and creates no set.
- A `.raymol` round trip preserves the chain: parent set, child set, parent links, arrays.
- Cancellation mid-batch leaves no orphan set when nothing landed, and keeps what did.
- `predict set:<child>@all` folds the child set -- the whole chain in one test.
- A sequence-only parent is refused by name, before any job starts.

Swift: `MPNNRuntimeTests.swift` for the wire decode (built from the snake_case JSON
`host.py` writes, never the memberwise init) and the preflight refusals, plus the
`InferenceRouterTests` table assertion, which pins the runtime set and must name `mpnn`.

## 11. Deferred

- **iOS.** `MPNNJobManager` is macOS-gated; the iOS Design-mode path is unchanged.
- **Per-position `omit` and `bias`.** `MPNNModel.DesignOptions` carries both; the command
  offers one global omit string, which is the knob binder design actually reaches for.
- **Repack.** `MPNNModel.repack` would give each sequence a structure, and would make the
  child set `structures` rather than `sequences`. That is a different tool: the honest
  test of a designed sequence is a refold, which is what `predict set:` is for.
- **A designers submenu in the drawer.** One button naming `mpnn`, because `mpnn` is the
  only sequence-design runtime this build links; a second one needs the registry list
  pushed to Swift the way `availablePredictors` is.
- **`MAX_SEQUENCES = 32` is a foot-gun bound, not a measured ceiling.** A 100-residue
  backbone samples in well under a second; the limit exists so a typo cannot ask for
  100000.
