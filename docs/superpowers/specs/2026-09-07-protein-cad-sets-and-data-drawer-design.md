# Protein CAD workspace: Sets, Entries and the Data drawer

**Date:** 2026-09-07
**Status:** proposal (design only, nothing implemented)
**Wireframe:** [2026-09-07-protein-cad-sets-and-data-drawer-wireframe.html](2026-09-07-protein-cad-sets-and-data-drawer-wireframe.html)
**Builds on:** metrics store (#308), group tree (#255), alignments section (#296), batch
groups in `designing.py`, Design mode (#217), predict/binder bars.

## 1. The problem

RayMol inherited PyMOL's one noun. Everything you load is an *object*: it has a name, a
row in the panel with A/S/H/L/C, an enabled flag, representations, a row in the sequence
strip, and a place in the scene. Groups nest objects. That model was built for sessions
with three molecules in them.

A design campaign is not that. One `binder_design` run with `n_designs=1000` produces a
thousand backbones; MPNN produces eight sequences per backbone; Boltz folds each; every
step measures things. The user's real job is *triage*: filter thousands of candidates
down to a handful, look hard at those, and send the survivors to the next tool.

Where the current implementation breaks under that load:

| surface | today | at 1000+ |
|---|---|---|
| Objects panel | one row per object, five buttons each, LazyVStack | a scrolling wall; a collapsed group hides it but gives no way to sort, filter or compare inside |
| Viewport | every enabled object renders | 1000 overlaid cartoons say nothing; the interesting view is 1 focus + a faint ensemble |
| Sequence strip | one row per *visible* object | a thousand rows is an MSA, and it has no metric context |
| Metrics store | full per-run, per-scope values, `summaries()` ready | "No UI consumes it yet; the panel section was stripped back out of #308 until the presentation is settled" |
| Polling | Swift polls `get_names` and details every 500 ms on the main thread | O(objects) work per tick; #271 already had to claw this back once |
| Batch delivery | `_join_batch_group` puts each finished design in a group | a group is a *scene* container, so 1000 results means 1000 loaded, rep'd, rendered objects |
| Memory/render | each object carries reps and GPU buffers | measured structure-count ceilings in the MCP benchmarking notes are far below a campaign's size |

The metrics store already made the key observation: "the design problem is SCOPE, not
storage." The UI has the same problem. The object is the wrong scope for a candidate.

## 2. Diagnosis: one word is doing two jobs

"Object" currently means both

1. **a record**: a thing that exists in the session, has identity, data, provenance, and
2. **a scene actor**: a thing that is loaded, represented and drawn.

In every mature CAD-shaped tool these are different nouns. Maestro's Project Table lists
*entries*; an "in workspace" toggle decides which are also in the 3D view. Cytoscape,
Spotfire and Foldseek's result view do the same with linked table, plot and canvas.
The fix for RayMol is not a faster object list. It is to split the noun.

## 3. Concept model

- **Entry**: one candidate. Has an id, a sequence per chain, an optional structure (a
  file reference, loaded lazily), scalar metrics (entry scope), array metrics (residue
  scope, loaded lazily), provenance (tool, run inputs, parent entry ids), and user state
  (star, tag, rejected, note). An entry is data. It is never drawn by itself.
- **Set**: an ordered collection of entries with a shared column schema. Produced by a
  batch job (RFD3, MPNN sampling, Boltz on many inputs), by import (a folder of PDB/CIF +
  a CSV or score file, a FASTA, an a3m), or by a tool run on another set. A set is the
  unit the user browses.
- **View**: a saved filter + sort + column layout over a set. Smart-folder semantics.
  Views are what you feed into the next tool ("predict everything in `top50`").
- **Object**: unchanged. A materialized scene actor. Staging an entry creates an object
  linked to the entry by id. Unstaging deletes the object and keeps the entry.
- **Group as footprint**: every set owns one group. The group contains exactly the set's
  staged objects. The Objects panel therefore keeps working as it does today, but a group
  row now reads "rfd3_batch_a1 · 5 of 1024 staged" instead of holding 1024 rows.
- **Lineage**: entries know their parents. A folded sequence points at the MPNN sequence
  entry, which points at the RFD3 backbone entry, which points at the target object and
  hotspots. This is what makes "send to next tool" a graph and not a pile of files.
- **Selection at two levels, linked**: *entry selection* (rows in a set) and *atom
  selection* (PyMOL selections, unchanged). Selecting rows highlights their points in the
  plot and their objects, if staged, in the scene. Clicking a staged object in the scene
  selects its row.

Three verbs connect the levels:

| verb | effect | cost |
|---|---|---|
| **peek** | hover a row, or arrow through rows: the entry is drawn transiently, superposed on the reference, replacing the previous peek | one hidden object, reused; never appears in the panel |
| **stage** | the entry becomes a real object in the set's group | a loaded object; counts against a stage budget |
| **pin** | a staged object survives "clear staged" and set switches | none |

## 4. Layout

The right inspector stays what it is: the *scene* column. Tables want width, so the set
browser is a **Data drawer** across the bottom, above the console.

There are **two independent sequence viewers** (amended 2026-09-16, #457; see §8
decision 2). The **Object viewer** — today's sequence strip, `SequencePanel` — stays in
its own pane at the TOP, above the viewport, with its own divider and ⌘2. The **Entry
viewer** is the drawer's Sequences tab. They are two different nouns, so they are two
different viewers: neither one's placement or visibility depends on the other's.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ toolbar ▸ mode strip (View · Move · Measure · Design · Binder)   Predict ▾   │
├────────────────────────────────────────────────────────┬────────────────────┤
│ 4HHB_target A MVHLTPEEKSAVTALWGKVNVDEVGGEALGRLLVVYPWT… │ Objects Scenes …   │ ← OBJECT viewer (⌘2)
│ d_0417      A GSHMNAFDENNIPKGPYEWYFKSRNFIPADDFEYEQMMP… │ ▾ OBJECTS          │   its own pane, own divider
│ ═══════════════ (drag divider) ════════════════════════│   ☑ 4HHB_target    │
│                                                        │   ▾ rfd3_a1  5/1024│
│                  3D viewport                           │     ☑ d_0417 ★     │
│                                                        │     ☑ d_0088       │
│   focus entry solid · pinned entries colored           │ ▾ SETS             │
│   peeked entry outlined · ensemble ghost (opt.)        │   rfd3_a1    1024 ▮▮▯│
│                                                        │   mpnn_a1    8192 ▮▮▮│
│                                                        │   boltz_a1    212 ▮▯▯│
│                                                        │ ▾ SELECTIONS       │
├────────────────────────────────────────────────────────┴────────────────────┤
│ DATA · rfd3_a1                             3 of 1024 staged · budget 6   ✕ │
│ [Table] [Plot] [Sequences] [Lineage]     filter: plddt>80… ⌕   212 of 1024 │
│ ☆ 👁 id      plddt ▾  iptm   rmsd   len  tool   parent    tags              │
│ ★ ● d_0417   91.2    0.84   1.1    72   rfd3   4HHB      hydrophobic-patch │
│ ☆ ● d_0088   89.7    0.81   0.9    68   rfd3   4HHB                        │
│ ☆ ○ d_0351   88.0    0.77   1.4    75   rfd3   4HHB                        │
│   ⋮  (virtualized: 212 of 1024 match)                 [Stage] [Send to ▾]  │
├─────────────────────────────────────────────────────────────────────────────┤
│ console                                                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

On the **Sequences** tab the drawer's body is the ENTRY viewer instead — one row per
selected or filtered entry, with its heat strip — while the Object viewer at the top is
untouched. That is the picture the decision is for: both viewers on screen, showing two
different things, neither able to take the other's place.

The **Object viewer** is one row per enabled scene object (#380). Its ideal height is
`min(max(objects, 1), 5) × 30 + 30`, capped at 400, and it is drag-resizable. ⌘2, the
View menu and the rail's **Seq** pill toggle it and nothing else.

The **Entry viewer** is the drawer's Sequences tab, toggled by the drawer's own
visibility (⌘4) and tab selection. With no set open the drawer shows "No set open" —
every tab here is a view of a set.

Both panes compete for the same column, and the drawer is the one that yields: in a
window that cannot hold the console, the Object viewer, a viewport and a drawer with one
table row, the drawer draws a one-line "needs more room" hint offering **Hide Console**
and **Hide Sequences**. At the app's 771pt default height with the console up, that is
the state from two enabled objects on.

### 4.1 Inspector: a SETS section

Follows the precedent of the Alignments section: a set is "deliberately NOT an
`ObjectEntry`". A set row shows its name, entry count, a tiny histogram of the ranking
column, a running-job badge while its batch is still landing, and an "open in drawer"
affordance. Its group appears under OBJECTS as normal, holding only staged objects.

### 4.2 Drawer: Table tab

- Columns come from the metric schema. `MetricSpec` already has label, units, lo/hi,
  `higher_is_better` and `summarizes`. That gives number formatting, default sort
  direction, a color ramp and a per-column histogram for free.
- Two fixed leading columns: star and stage-state (● staged, ○ not, ◐ peeked).
- Column headers are the filter UI: click the header histogram to brush a range. The
  filter field accepts an expression (`plddt > 80 and rmsd < 1.5 and not rejected`).
  Row count updates live: "212 of 1024 match".
- Row hover peeks. Space stages/unstages. `s` stars. `x` rejects. Arrow keys move the peek.
- Selection actions in the footer: Stage, Pin, Export (FASTA, CSV, PDB folder), Send to ▾
  (Predict, Design/MPNN), Save as View. **Not Binder Design**: a generator produces a set
  rather than consuming one, and running a campaign per selected entry is a combinatorial
  flow nobody wants. It keeps taking a target object and hotspots (decided 2026-09-15).
- Optional thumbnail column, rendered lazily by the peek object off-screen.

### 4.3 Drawer: Plot tab

One scatter, x and y chosen from the numeric columns, color by a third or by set/tag.
Brushing selects rows. Points of staged entries are ringed; the peek point is large. A
histogram strip along each axis doubles as the range filter. The plot reads the same
filtered rows as the table; no separate state.

### 4.4 Drawer: Sequences tab

Rows are the *selected or filtered entries* (cap at a few hundred, then show a
logo/consensus band instead), aligned by parent backbone position when they share a
parent, gap-aware when an alignment object is enabled. Per-residue metrics (pLDDT, MPNN
native fit, certainty) draw as a heat strip under each row using the same domains Design
mode uses.

Scene objects are **not** rows here (amended 2026-09-15 #456, 2026-09-16 #457). They are
the Object viewer's, in its own pane above the viewport — see §4 and §8 decision 2. This
tab is one noun, entries; the Object viewer is the other, objects.

### 4.5 Drawer: Lineage tab

A left-to-right DAG: target → backbones → sequences → folds. Node size or color from a
chosen metric. Clicking a node filters the table to its descendants. This is the view
that answers "which backbones produced foldable sequences" without a spreadsheet.

### 4.6 Viewport conventions

- One **reference** (the target, or the first pinned entry) defines the frame; staged
  and peeked entries are superposed on it by default.
- **Focus** entry: full color, full reps. **Pinned**: distinct categorical colors, or the
  chosen metric ramp. **Peek**: outline/ghost so it never gets confused with staged.
- **Ensemble ghost** (toggle): the filtered set drawn as thin CA traces at low alpha, from
  a precomputed coordinate array rather than objects. Bounded by count; above the cap it
  samples. This is the only way "show me the 212 that pass" is honest and cheap.

### 4.7 iPad and iPhone

iPad: the drawer is the existing bottom panel (`panelFrac`), with the same tabs. iPhone:
sets open as a full-screen sheet with Table and Plot only; peek is a tap, stage is a
swipe action. The inspector's SETS section is the entry point on every size class.

## 5. Flows this has to make easy

1. **Binder campaign.** `binder_design rfd3, 4HHB, hotspots, n_designs=1000` creates set
   `rfd3_a1`, its group, and stages the first result so the viewport is not empty.
   Entries land progressively with their metrics. The user sorts by the ranking column,
   brushes `rmsd < 1.5`, peeks through the top 20 with arrow keys, stars four, stages
   them, and runs "Send to ▾ MPNN" on the starred view. That produces `mpnn_a1` with
   parent links. "Send to ▾ Predict" on `mpnn_a1` produces `boltz_a1`. Lineage shows
   which backbones survived.
2. **Import a folder.** Drop a directory with `*.pdb` and `score.sc` / `*.csv` on the
   window: a set, columns inferred from the file, structures referenced not loaded.
3. **Compare three.** Stage three, pin them, color by entry, superpose on the target,
   open Sequences to see where they differ, with per-residue confidence under each.
4. **Agent-driven triage over MCP.** `set_filter`, `set_sort`, `set_stage` and
   `set_export` as commands means an agent can do steps 1's triage without a UI, then
   hand the user a scene with the survivors staged.
5. **Save and reopen.** The `.pse` restores sets, views, staged objects and lineage.

## 6. Scale rules

- **Never poll a set.** Set contents move Python → Swift on change only, with a version
  number, over the existing file-marker channel (`SEQPANEL:ready` pattern). The Swift side
  holds a columnar model and does filter/sort/brush locally; 100k rows is fine there.
- **Virtualize everything.** `Table`/`NSTableView` for rows; the plot draws from arrays.
- **Structures are lazy.** An entry holds a path (or a compressed blob) until peeked or
  staged. Residue arrays load on demand for the Sequences tab.
- **A stage budget.** Default small (single digits); user-adjustable; the panel says
  "5 of 1024 staged". Exceeding it prompts to unstage or pin. The number should come from
  the structure-count measurements already made for MCP capture, not a guess.
- **Peek reuses one object**, hidden from the panel and the sequence rows, so a hover
  storm costs one `load` and one `delete` at most per tick.
- **Storage: one file, and it is not the `.pse`.** A `.pse` is a pickle: read whole,
  written whole, every member materialized in memory. Sets go in a `.raymol` file, which
  is a SQLite database that *carries* the `.pse` as one blob, unchanged:
  - `session`: the ordinary `.pse` bytes. Staged objects, scenes and the metrics of loaded
    objects live there exactly as today.
  - `sets`, `entries`, `runs`, `views`: entry rows with sequences, scalar metrics as
    indexed columns, run inputs stored once per run, parent ids, star/tag/reject.
  - `blobs`: gzipped mmCIF structures, float32 residue arrays, uint8 PAE at 0.125 Å.
    Content-addressed by hash, so the rigid target RFD3 writes into every design is
    stored once.
  - `links`: entry id ↔ staged object name, so scene and table find each other on reload.

  Consequences: results are written as they land, so a six-hour batch survives a crash
  and Save is "write the pse blob"; opening a 1 GB file costs what a small one does;
  Swift reads the database directly, read-only, in WAL mode, so the drawer needs no JSON
  marker channel for set contents (only a `SETS:v<n>` change notice); `sqlite3` is on every
  machine and "Export set as folder" writes CIFs and a CSV for anyone who wants files.
  A campaign of 1000 backbones, 8000 sequences and 200 folds is on the order of 45 MB.
  Thumbnails and diffusion trajectories are the two things that would dominate, so both
  are opt-in: thumbnails render lazily for rows scrolled past with a capped cache, and
  trajectory frames are kept only for staged or pinned entries.
  `save x.pse` keeps writing plain PyMOL content and warns that sets were left out;
  opening a `.pse` works as now; an untitled session keeps its database in an autosave
  location and moves it on Save As; iOS uses the same file.

## 7. Where it lands in the code

| piece | where | notes |
|---|---|---|
| Set store | `modules/pymol/sets/` mirroring `metrics/` (`store.py` over `sqlite3`, `schema.py` DDL + migrations, `blobs.py`, `document.py` import/export, `binding.py`, `errors.py`) | reuses `metrics.schema` for columns; the `.raymol` container owns the file, `_session_save_tasks`/`_session_restore_tasks` only carry the link table and the active view |
| Container | `modules/pymol/raymol_file.py`: open/save/save-as of `.raymol`, autosave location, `.pse` blob in/out | `PyMOLApp.swift` gains the UTType, document type, Save/Save As routing, and the #349 replace-session guard for the new extension |
| Command surface | `modules/pymol/setting_sets.py` → `cmd.set_create/add/list/filter/sort/stage/unstage/pin/export/import/view_save` | the MCP story is these commands |
| Batch delivery | `designing.py`: `_join_batch_group` becomes "add entry to set; stage if within budget" | group semantics stay; the group is the footprint |
| Predict on a set | `predicting.py` accepts a set/view as input and writes a child set | parent ids carried in `inputs` |
| Metrics | `store.summaries()` gets its consumer; `MetricSpec` drives columns | the "presentation settled" question from #308 is answered by the table |
| Inspector | `ObjectPanel.swift`: `SetEntry` + SETS section, next to `AlignmentEntry` | group row badge "n of N staged" |
| Drawer | `Panels/DataDrawer.swift` with `SetTableView`, `SetPlotView`, `SequencesView` (moved from `SequencePanel.swift`), `LineageView` | `PanelLayout` gains `dataDrawerVisibleKey`, `dataDrawerFracKey` |
| Engine | `PyMOLEngine`: `SetsStore` read-only SQLite connection, refresh on `SETS:v<n>` marker, peek/stage calls | no per-tick work; filters and sorts are queries |
| Python emitters | `appkit_sets.py` emits only the change marker and the active-set/peek state | set contents are read from the database, not shuttled as JSON |
| Tool panels | `Shared/ToolSetStatus.swift`: `PlannedSet` ("what will this run create") and `RunningToolBatch` ("what of this tool's work is running"), drawn by `BinderDesignBar` and `PredictBar`; `designing.preview_set` behind `appkit_design.emit` | **added by #463.** The table stopped here, and the tools' own UI was the omission: the bar that starts a batch has to say a batch becomes a set, and the batch has to report where it was started. The naming rules stay in `designing.py` -- the bar asks, it does not derive |


**Amended 2026-09-17 (#463).** The row above was added after five of the six steps had
shipped and the gap was found from the other side: every surface the table lists is a
place a set is *browsed*, and none is a place work is *started*. A tool panel that cannot
name the set it is about to create -- or report the batch it just started -- leaves the
command line as the only place the model is whole, which is the asymmetry §2 is about.

## 8. Decisions to make

Recommendations first.

1. **Does every batch become a set, even `n_designs=1`?** Yes. One model. A one-entry set
   auto-stages its entry, so the user experience for `n=1` is unchanged.
2. **Does the sequence strip move into the drawer?** ~~Yes. Two sequence views would
   compete.~~ **No — there are TWO sequence viewers, and they are independent**
   (reversed 2026-09-16, #457; supersedes #419's tab and #456's band).

   Javier: *"there should be two sequence viewers operating independently. One for the
   sequences of the enabled objects in the session and a separate one to examine the
   sequences of a set. The first one should be the current one in its top position, the
   latter should be displayed on the drawer."*

   The reasoning, which is the reasoning this whole design rests on: the strip is an
   **Object** view — the sequences of the enabled scene objects — and a set's entry rows
   are an **Entry** view — the contents of a set. That is the Entry/Object split of §2
   and §3. Two nouns are two viewers. They are therefore **independently placed** (the
   Object viewer in its own pane at the top, above the viewport, where it has always
   been; the Entry viewer in the drawer's Sequences tab) and **independently toggled**
   (⌘2 for the first, the drawer's own visibility and tab for the second). Not one view,
   not alternatives, not stacked in one container.

   "Two sequence views would compete" was the original argument for the move, and it was
   wrong twice over. It read *competition for pixels* as a reason to merge two things
   that are not the same thing — and merging them cost more than it saved: #419 made
   them alternatives, so you could not watch the scene sequence while triaging in the
   Table, and #456's band fixed that by putting an Object view inside an Entry
   container, where its height came out of the set's table. What the panes actually
   compete for is **column height**, which is a layout question with a layout answer:
   each viewer is independently closable, the drawer is the pane that yields, and when
   there is not room for all of them the drawer says so and offers to close either pane
   above it (§4).

   No migration carries anyone across the reversal, and none is needed: the drawer has
   never shipped, so #419's and #456's one-time migrations only ever ran against dev
   builds. Both are deleted along with their keys, and `raymol.panels.sequenceVisible`
   is the Object viewer's single source of truth again, on every platform — iPad and
   iPhone never stopped drawing the pane in its own slot.
3. **Sidecar bundle vs. embed in `.pse` vs. a new container?** New single-file container,
   `.raymol`, a SQLite database carrying the `.pse` as a blob. Decided 2026-09-07: one file
   for portability, incremental writes for crash safety and cheap saves, random access for
   lazy loading, and a store Swift can query directly. See §6.
4. **Left rail of sets vs. SETS section in the inspector?** Inspector section. Less new
   chrome, follows the Alignments precedent, works on iPad without a new pane.
5. **Ensemble ghost in phase 1?** No. It is the most expensive piece and the table +
   peek covers the triage flow. Add it once the columnar coordinate cache exists.

## 9. Phasing

Each step is a PR into `master` that leaves the app shippable.

1. **Store + container, no UI.** `pymol.sets` over SQLite, the `.raymol` open/save path,
   `set_*` commands, tests under `testing/tests/api/sets.py`. Usable from the console and
   over MCP on day one.
2. **Batch → set.** `designing.py` delivers into a set and stages within budget; the group
   is the footprint. Predict accepts a set/view as input and writes a child set.
3. **Inspector SETS section + Data drawer with the Table tab + peek/stage/pin.** The
   triage loop works end to end for RFD3 output. Metrics finally have a UI.
4. **Filters, Plot tab, linked selection, saved views, Send to ▾.** The campaign flow.
5. **Sequences tab (strip migration), per-residue heat strips, Lineage tab.**
6. **Import of external folders/score files, ensemble ghost, iPad/iPhone layouts.**
