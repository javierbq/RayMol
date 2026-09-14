# Sets 2/6: batch delivery lands in a set; predict reads a set or view

**Date:** 2026-09-13
**Issue:** #416, part of #421 (tracking); depends on #415 (merged as #422)
**Parent designs:** [sets store and .raymol container](2026-09-07-sets-store-and-raymol-container-design.md)
§1, §2.1, §4, §6, §7; [protein CAD](2026-09-07-protein-cad-sets-and-data-drawer-design.md)
§3, §5 flow 1, §6, §8 decision 1
**Status:** what ships in this step. The schema is untouched (format version 1), so
everything here is behaviour on top of what #415 laid down.

## 0. Scope

`binder_design` delivers every design into a set and stages only as many as the budget
allows; `predict` accepts a set or a view as its input and writes a child set with one
entry per model. The shared "a running tool delivers into a set" logic is one module,
`pymol.sets.batch`, used by both. No UI: the inspector SETS section and the drawer are
#417, which reads the same SQLite file and polls one cheap function here (§7).

## 1. Placeholders versus the budget

**Today.** `binder_design n_designs=N` creates N zero-atom placeholder objects at submit,
grouped at once so the panel is tidy mid-run, and the Swift runtime delivers each finished
design by *object name*: `deliver_result(path, name, seed)`. That name is the key of every
pending table (`_PENDING`, `_TRACK`, `_BATCH_OF`, `_LAST_INFO`, `_RECENT`), of
`pending_info`, `discard_pending`, `design_cancel`, and of the session-save filter.

**After.** The object name stays the delivery key and every table keeps its shape, but a
placeholder object is created only for the members that will be staged when they land:
the first `budget` of them (`binding.budget(set_row)` read once at submit). Members
beyond the budget are registered in the same tables with **no object**
(`register_pending(name, job_id, placeholder=False)`). This is safe because nothing that
publishes progress looks for the object: `appkit_inspector._pending_maps` iterates
`pending_objects()` -- the `_PENDING` keys -- and asks `pending_info(name)`, which reads
dicts and the job handle; `discard_pending` deletes an object only if one exists; the
session-save filter drops names that are pending *and* in the session, so a name that is
not in the session is simply not there. So a 1000-design batch shows as one tray row with
`batch_total=1000`, and the Objects panel shows the batch group holding at most `budget`
rows, from the moment the command returns to the moment the last design lands.

At delivery the runtime hands us a path and a name. `deliver_result` loads into the name
as it always did -- `cmd.load` creates the object when there is no placeholder -- and the
design is then written to the set (§2) and either kept as the staged object or, when the
set's staged count already equals the budget, deleted again (§4). The object exists for
the few milliseconds between load and the staging decision, which is what makes one load
path serve both cases.

**`n_designs=1`** is indistinguishable from today except that a one-entry set exists and
its entry is linked to the object: a placeholder as today, no group (`designing._BATCH`
stays empty, so the tray row and `design_cancel <object>` are what they were), the object
has the same name, dss, title and state pin. The set is named like a batch's would be
(`<generator>_batch_<key>`, moved aside if taken) and its `group_name` is that name, so a
later `set_stage` on it creates the group then; the delivered object itself is not moved
into a group of one.

The one cost of keeping every member in `_PENDING` is that the panel poll calls
`pending_info` once per pending name every 500 ms. MEASURED with the fake in
`sets_batch.py` on a 1000-design batch: 200 ms per poll, of which 170 ms was
`_batch_frontier` rescanning the batch's names from index 0 for every member -- a million
dict lookups per tick. Settling is monotone, so the frontier now resumes from the last
settled prefix (`entry['frontier']`) and the same poll costs 6 ms. `job.status()` on a
queued host job is a file stat and was not the problem; no record is synthesised.

## 2. What lands where

**At submit** (`batch.open`), because `running()` (§7) is keyed by set id and the badge
must exist while the batch lands: `create_set(batch_id, kind='structures',
tool=<generator id>, group_name=batch_id)`, `update_set(reference=<target object>)` --
the object `resolve_target` read the target from, one by construction -- and ONE
`add_run(set_id, tool, tool_version=<weights version>, inputs=...)` per `binder_design`
invocation. `inputs` is `designing._run_inputs` less the per-design seed, plus
`n_designs`, `seeds` (all of them, in submission order) and `weights`. The store's
`generation()` is captured on the batch.

**An identical re-run extends its set.** Today an identical re-run lands back in the
group its first run made ("adding to it is the whole point"), and the group is now the
set's footprint, so the set follows: when the batch id names a set the SAME generator
wrote, `open` adds a second run row to it and the new designs are appended as entries
(`_2` on a repeated design name, as the object gets), staged only while the set has room.
A set of another tool -- or one the user imported -- under that name is a collision and
the batch moves aside to `_2`, as it does for a molecule holding its group's name.
`n_designs=1` follows the same rule, so two single designs against one target are two
entries of one set.

**At delivery** (`batch.land`), after the object is complete -- loaded or live-finished,
dss'd, pinned, and after `record_run` has filed the design's metrics in the metrics store
against the object, exactly as today:

1. Generation check: `store.generation()` must equal the value captured at submit. On a
   mismatch `land` raises `SetError` naming the batch; `deliver_result` warns once and
   falls back to today's behaviour -- the object stays, joins the batch group -- so a
   `load other.raymol` under a running batch loses nothing and never writes into the wrong
   document. The batch is marked detached: later members skip the write without a second
   warning and it leaves `running()`.
2. `binding.capture_object(set_id, name, name=<entry name>, run_id=<batch run>,
   states=<the delivered state>)` writes the entry: one CIF blob per chain from
   `get_cifstr` (§3), sequences per polymer chain, and every scalar and array the metrics
   run on the object carries, declaring columns from the generator's `MetricSpec`s. The
   entry name is the object name through `legal_entry_name`. Two extra columns are
   declared under the generator's tool id and written on the same call: `seed` (int) and,
   for predictions, `model` (int).
3. Only then the staging decision (§4). The write happens BEFORE it, so a crash mid-batch
   loses at most the design in flight.

`capture_object` gains one additive parameter: `states` may be an int, meaning that one
state. Today it accepts `'all'` and `'current'`; a live design with `keep_frames=1` has
its finished design in its LAST state and the global `cmd.get_state()` may point anywhere,
so `deliver_result` names the state it just landed in.

## 3. The target chain is stored once

Blobs are content-addressed by sha256 of the CIF text. Measured on two objects holding the
same chain A: `get_cifstr` output differs in exactly two lines, `data_<object>` and
`_entry.id <object>`; every `_atom_site` row is byte-identical (and `dss` writes nothing
into the CIF -- there is no `_struct_conf`). So the header is canonicalised on capture:
`binding.canonical_cif(text, chain)` rewrites those two lines to `data_<chain>` /
`_entry.id <chain>`, and `capture_object` stores the result. A target held fixed across a
batch is then one blob however many designs carry it, and `set_add` of two different
objects sharing a chain dedupes too, which it did not before. Nothing that READS a blob
cares about the label: `_load_chains` ignores it, `write_folder` concatenates blocks, and
`_split_cif_blocks` splits on `data_` whatever follows. The test asserts
`blob_stats()['count'] == N + 1` for N designs against one target and prints the stats.

Whether the REAL runtime re-centres the target per design (which would defeat this by
moving the coordinates, not the header) is the measurement spec §2.3 asked for; it needs
an RFD3 batch on real weights and is not taken here (§9).

## 4. Staging within the budget

The first `budget` entries to land are staged; later ones are entries only.

- **Staged** means: the delivered object is kept under its name, added to the batch group
  (`n_designs > 1`), and linked (`entries.staged_object = name`). It IS the object the
  user sees today: same name, group, dss, seed title, and the pin to the final state for a
  live run. No superposition is done for a design -- it already contains the target where
  the target was -- and no metrics write-back is needed, because `record_run` already
  filed the run against this very object. A prediction is superposed on the child set's
  reference when there is one (§5), for the reason `binding.stage` does it.
- **Not staged** means: `metrics.store.forget_object(name)` and `cmd.delete(name)`.
  The entry keeps the chains, sequences and every number; `set_stage` brings it back.

"Within budget" is decided at delivery from `binding._staged` (live links only), not from
the member's index, so a failed member frees its slot for the next one and a user who
unstages a design mid-batch gets the slot refilled. `keep_frames` frames therefore survive
only as states of a staged (or pinned) object; the entry stores the finished design's state
only, and unstaging discards the frames with the object, as the parent design says.

## 5. `predict` reads a set or view

Syntax, pinned: the `sequence` argument accepts `set:<name>` and
`set:<name>@<selector>`, where the selector is any §4.1 selector of the store spec
(`starred`, `top:20`, `view:top50`, `run:<id>`, `d_0417+d_0088`, `all`, `filtered`).
`@` because `/` is the literal-sequence chain separator and `,` is the parser's argument
separator; both `:` and `@` survive `parsing.STRICT` inside an argument (measured with
`cmd.do`). Without a selector the set's `filtered` entries are used, the same default
`set_export` has. An entry's sequence is its `sequences` field, chains in key order,
joined with `/`; an entry with no sequence is refused by name. Alignments: `msa=` applies
to every entry (same chain layout across a set), and there are no attachments to inherit
because an entry is not an object.

Results land in a **child set** named `<predictor>_<n>`, the first n from 1 for which
that name is free as a set, a group, an object and a batch id (the batch's own free-name
rule extended to sets), or `name=` when given (refused if taken). The child is created at
submit with `tool=<predictor>`, `reference` copied from the parent set, and one
`add_run(child, tool, tool_version, inputs={predictor, options, seeds, n_models,
'parent_set': <parent id>, 'selector': <as typed>, 'parents': [<entry ids>]},
parent_set_id=<parent id>)`. One entry PER MODEL (`n_models=5` on 20 entries is 100
entries sharing one run), named `<parent entry>` for `n_models=1` and
`<parent entry>_m<k>` otherwise, each with `parents=[<its parent entry id>]` and columns
`model` and `seed` beside the predictor's `MetricSpec` columns from its metrics run.

Every model is its own object at delivery -- not a state of one object per parent -- so
that an entry is one set of coordinates (store spec §1) and staging, unstaging and the
budget mean the same thing they mean for a design. The object is named after the entry,
moved aside with `_2` if taken, exactly as `binding.stage` names it. Placeholders follow
§1: the first `budget` (entry, model) pairs get one; the rest are pending without an
object. `superpose_on_first_model` has nothing to do on a one-state object and is left in
place for the literal-sequence path, which is unchanged.

## 6. Session

`session_save` in both modules keeps doing what it does: pending placeholders leave the
`.pse`, a batch group whose every child was filtered leaves with them. Sets are in the
container and are never written into a `.pse`. Concretely, for a mid-batch session:

- `save x.raymol`: the session blob is written into the open document; the sets are
  already there; later results keep landing in `x.raymol`.
- `save x.pse`: plain PyMOL. Staged designs that have landed go in as ordinary objects,
  pending members and an all-pending group stay out, and the existing warning names the
  sets left behind. Reopening that `.pse` later gives the staged objects and no sets.
- `load x.pse`, `load other.raymol`, `reinitialize` while a batch runs: the store's
  generation changes, so the remaining members' writes are refused (§2.1) and those designs
  land as plain objects in the batch group with one warning. A `.raymol` document is
  closed, not deleted, so what had landed is on disk; the pid-scoped working file of an
  untitled session is removed by those commands today (#415), which is the one path where
  landed entries are lost -- refusing the load while a batch runs is a one-line guard in
  `binding.load_raymol` that this step does not add (§9).

There is no `session_restore` in either module today and none is added: a pending job
does not survive the process, and the set's entries need nothing restored.

## 7. Contract with #417

`pymol.sets.batch.running(set_id=None)` returns
`{set_id: {'done': int, 'total': int, 'tool': str}}` for every set whose batch is still
landing, `{}` when none, never raises, and reads process state only (no SQL): the UI polls
it every 500 ms. `done` counts members that have SETTLED -- landed, failed or cancelled --
so it reaches `total` when the batch is over; the set's entry count, read from the file,
is the number that actually landed. A batch leaves `running()` when its last member
settles or when it detaches (§2.1).

A batch that settles with NO entries deletes its empty set, as today's batch deletes its
empty group: a cancelled campaign leaves nothing behind. A set with entries is kept.

## 8. Tests (`testing/tests/sets/sets_batch.py`)

A fake generator (its own module-level `MAX_DESIGNS`, designs jittered by seed so the
designed chains are distinct blobs) and a fake predictor, both delivered by calling
`deliver_result` the way the runtime does:

- 50 designs, budget 6: a 50-entry set, a group with exactly 6 members, exactly 6 staged
  links, `blob_stats()['count'] == 51`, run inputs carry 50 seeds, columns come from
  `DESIGN_SPECS`; `save x.raymol` then `load x.raymol` gives the same counts and the same
  staged names.
- `n_designs=1`: no group, the object as today, a one-entry set whose entry is staged.
- An identical re-run: one set, two runs, four entries, one group; a set of another tool
  under the batch's name is left alone and the batch lands in `_2`.
- `predict` over `set:<name>@top:2` with `n_models=3`: a child set of 6 entries, one run
  with `parent_set_id` and two parent ids, each entry's `parents` is its own parent,
  `model` is 1..3, the child stages within budget.
- A generation change mid-batch (`load other.raymol`): `batch.land` raises `SetError`,
  `deliver_result` keeps the object in the group, the new document has no such set, and
  `running()` no longer lists the batch.
- `running()` shape and cost; `pending_info` cost for 1000 pending members.

`testing/tests/generate/generate_api.py` keeps its batch tests; the ones that assert on
placeholders or `_BATCH` for `n_designs=1` still hold because those paths are unchanged.

## 9. Deferred

- **Real-runtime dedupe measurement.** Whether RFD3 re-centres the target per design.
- **Refusing `load` while a batch runs.** A guard in `binding.load_raymol` /
  `importing.load_pse`; behavioural, so not made under the additive-only rule.
- **`rfd3.MAX_DESIGNS` is 10.** The "done when" of #416 says 1000; the bound lives in
  `generators/rfd3.py`, which this step does not own. Raising it is one line.
- **Trajectory frames as opt-in blobs** for staged/pinned entries. Frames live only in the
  object today.
- **The MPNN step** (a sequence generator writing a `sequences` set) does not exist yet;
  `predict set:` already folds sequence-only entries, which is the flow it will need.
