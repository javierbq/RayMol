# Sets 1/6: the `pymol.sets` store, the `.raymol` container, and the `set_*` commands

**Date:** 2026-09-07
**Issue:** #415, part of #421 (tracking)
**Parent design:** [2026-09-07-protein-cad-sets-and-data-drawer-design.md](2026-09-07-protein-cad-sets-and-data-drawer-design.md) §3, §6, §7
**Status:** proposal; the schema and command signatures here are what every later step
and every MCP client builds on, so they are the part to get right first.

## 0. Scope

The data layer, with no UI. After this lands, a user or an agent can, from the console:
build a set from a folder of structures, filter and sort it, peek and stage entries into
the scene, export it, save everything to one `.raymol` file, and reopen it.

Out of scope: the inspector section and the Data drawer (#417), batch delivery into a
set (#416), the expression-driven Plot and saved-view UI (#418), Swift reading the
database (#417), import of Rosetta score files and iOS file handling (#420).

## 1. Nouns, restated for this layer

| noun | is | lives in |
|---|---|---|
| **Set** | an ordered collection of entries with one column schema, owning one group | `sets` |
| **Entry** | one structure (one set of coordinates) or one sequence; the thing you can peek | `entries` |
| **Run** | one tool invocation: tool, version, inputs; shared by the entries it produced | `runs` |
| **Value** | one scalar metric of one entry, in a wide per-set table | `m_<set>` |
| **Array** | one residue- or pair-scope metric of one entry, as a blob | `arrays` + `blobs` |
| **View** | a saved filter + sort over a set | `views` |
| **Link** | entry ↔ staged object name | `entries.staged_object` |

Two rules that follow from "an entry is one set of coordinates":

- A Boltz run with five diffusion samples writes **five entries**, one per model, sharing
  a run and a `model` column. Not one entry with five states. Every row in the table is
  something you can peek, and per-model metrics need no state axis.
- A sequence-only entry (MPNN output before folding) has no structure blob and no
  arrays yet. Folding it writes a **child entry** in a child set, not a structure onto
  the sequence entry. Lineage is the link, as the parent design says.

## 2. The container

A `.raymol` file is a SQLite database. One file, portable by mail and by the Files app,
readable by `sqlite3` anywhere.

### 2.1 Pragmas and lifecycle

- `journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`. While a file is open,
  SQLite keeps `-wal` and `-shm` files beside it; they are checkpointed and removed on
  close. Copying a document while RayMol has it open copies a stale file. Documented,
  not worked around.
- **One writer.** Python on the main thread, which is where `designing.pump` and every
  `cmd.*` already run. Readers (a future Swift connection, #417) open read-only.
- **Always open.** The store has a database from startup, so a run never requires a
  Save first. In the app the working file for an untitled session IS the autosave: it
  lives where `PyMOLEngine` keeps `autosave.pse` today and is offered back on cold
  launch, so an untitled session with a six-hour batch survives a crash and a quit. Under
  command-line PyMOL with no app, the fallback is a pid-scoped `raymol_sets_<pid>.raymol`
  in `TMPDIR` (or `RAYMOL_SETS_DIR`), deleted on clean exit and swept on next launch, for
  the reason #399 pid-scoped the panel channels.
- **Results are written when they land**, not on Save. Opening a document opens it in
  place, so a batch that runs for six hours is on disk in the user's file after the first
  design. Only the session blob waits for an explicit Save. This is a deliberate trade:
  "nothing changes until I save" is worth less than "nothing is lost when it crashes"
  when a change is an hour of GPU time.
- **Save** (`save x.raymol`): if the open database *is* `x.raymol`, write the session
  blob and commit. Otherwise `VACUUM INTO` a temporary beside the target, remove the
  target and any stale `-wal`/`-shm` a crashed session left there, rename, open the
  copy and write the session blob, and only then remove the previous working file; on
  any failure the previous container is reopened, so no step can lose data. Save As is
  the second path.
- **Threads.** PyMOL reaches `cmd.*` from the GUI thread, `cmd.do`, the MCP server and
  `spawn`, so the connection is opened with `check_same_thread=False` and every
  statement runs under one reentrant lock; a failed `COMMIT` rolls back so the
  connection is never wedged in an open transaction. The active container has a
  `generation()` counter that a long-running writer (#416) checks before each write.
- **Process-global.** Like the metrics and MSA stores, there is one active container
  per process, shared by every `pymol2` instance. A limitation these stores share, not
  a decision taken here.
- **Load** (`load x.raymol`): close the current database, open `x.raymol`, read the
  session blob, hand it to `set_session`. Peek and staged objects come back from the
  `.pse` as ordinary objects; `entries.staged_object` says which entry each is.
- **`.pse` stays the default session format.** A session with no sets saves, opens and
  autosaves exactly as today; a user who never touches a set never sees `.raymol`.
  Decided 2026-09-07.
- **The format changes only when sets come into play**, and the user is told once. The
  first time a session that holds a non-empty set is saved (⌘S or Save As) with no
  `.raymol` document open, the app shows a sheet before the Save panel:

  > **This session now includes a set, which the PyMOL `.pse` format can't hold.**
  > RayMol will save it as a `.raymol` file: one file that carries the whole session,
  > including sets and their structures. It opens only in RayMol. You can still produce a
  > `.pse` for PyMOL at any time with File ▸ Export PyMOL Session…; it will contain the
  > loaded objects but not the sets.
  > [Save as .raymol]  [Save .pse without sets]  [Cancel]

  Save as `.raymol` copies the working database to the chosen path (beside the open
  `.pse`, with the same stem, when there is one) and makes it the live document.
  Saving the `.pse` without sets writes plain PyMOL and logs the warning below. The sheet
  is not shown again for that session once either choice is made; it does appear again
  in a new session that reaches the same point. On iOS the same text is an alert.
- **`save x.pse`** from the console or MCP writes plain PyMOL as today and, when any set
  is non-empty, prints one warning naming the sets left out and pointing at
  `save x.raymol`. Nothing set-related is embedded in a `.pse`, so an older RayMol or
  upstream PyMOL opens it unchanged.
- **Export PyMOL Session…** is a menu item that always writes a `.pse`, present whether
  or not the session has sets, so the escape hatch is visible before it is needed (#417).
- **`load x.pse`** clears the store to a fresh working file. A session restore task
  registered like the metrics one does this, so a `.pse` opened after a `.raymol` does
  not inherit the previous document's sets.

### 2.2 Schema, format version 1

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- format_version=1, created, app_version, version (monotonic, bumped on every write)

CREATE TABLE session (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  pse BLOB NOT NULL, saved REAL NOT NULL, pse_version REAL, app_version TEXT);

CREATE TABLE sets (
  id TEXT PRIMARY KEY,                 -- 8 hex chars, stable across renames
  name TEXT NOT NULL UNIQUE,           -- same alphabet as MSA names: no , / ' " ( ) [ ] { } whitespace
  kind TEXT NOT NULL,                  -- 'structures' | 'sequences' | 'mixed'
  created REAL NOT NULL, tool TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '',
  group_name TEXT NOT NULL,            -- the footprint group; created lazily on first stage
  budget INTEGER,                      -- NULL = the global setting
  ranking_key TEXT NOT NULL DEFAULT '',-- the column the inspector histogram and top:N use
  sort_key TEXT NOT NULL DEFAULT '', sort_desc INTEGER NOT NULL DEFAULT 1,
  filter TEXT NOT NULL DEFAULT '',     -- the active filter expression (§5), '' = none
  columns TEXT NOT NULL DEFAULT '[]'); -- JSON: ordered column keys with their MetricSpec dicts

CREATE TABLE runs (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  tool TEXT NOT NULL, tool_version TEXT NOT NULL DEFAULT '', created REAL NOT NULL,
  inputs TEXT NOT NULL DEFAULT '{}',   -- JSON, once per run, never per entry
  parent_set_id TEXT, note TEXT NOT NULL DEFAULT '');

CREATE TABLE entries (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  ord INTEGER NOT NULL,                -- delivery order; the default sort
  name TEXT NOT NULL,                  -- unique within the set; the label and the staged object's name
  run_id TEXT REFERENCES runs(id), created REAL NOT NULL,
  sequences TEXT NOT NULL DEFAULT '{}',-- JSON {chain: one-letter}
  n_chains INTEGER NOT NULL DEFAULT 0, n_residues INTEGER NOT NULL DEFAULT 0,
  parents TEXT NOT NULL DEFAULT '[]',  -- JSON [entry id]; may point into other sets
  starred INTEGER NOT NULL DEFAULT 0, rejected INTEGER NOT NULL DEFAULT 0,
  tags TEXT NOT NULL DEFAULT '',       -- space-separated
  note TEXT NOT NULL DEFAULT '',
  staged_object TEXT, pinned INTEGER NOT NULL DEFAULT 0,
  UNIQUE (set_id, name));
CREATE INDEX entries_set_ord ON entries(set_id, ord);
CREATE INDEX entries_staged ON entries(staged_object) WHERE staged_object IS NOT NULL;

CREATE TABLE chains (                  -- an entry's structure, one blob per chain
  entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  chain TEXT NOT NULL, ord INTEGER NOT NULL,
  blob TEXT NOT NULL REFERENCES blobs(hash),
  PRIMARY KEY (entry_id, chain));

CREATE TABLE arrays (
  entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  key TEXT NOT NULL, scope TEXT NOT NULL,          -- 'residue' | 'pair'
  chain TEXT,                                      -- NULL = whole entry
  blob TEXT NOT NULL REFERENCES blobs(hash),
  encoding TEXT NOT NULL,                          -- 'f32' | 'u8q'
  scale REAL, offset REAL,                         -- u8q: value = offset + scale * byte
  index_json TEXT NOT NULL,                        -- [[chain, resi], ...], as MetricValue.index
  PRIMARY KEY (entry_id, key, chain));

CREATE TABLE blobs (
  hash TEXT PRIMARY KEY,               -- sha256 hex of the UNCOMPRESSED bytes
  kind TEXT NOT NULL,                  -- 'cif' | 'f32' | 'u8q' | 'thumb'
  bytes BLOB NOT NULL,                 -- gzip(-6) of the content for 'cif'; raw for arrays
  size INTEGER NOT NULL,               -- uncompressed
  refs INTEGER NOT NULL DEFAULT 0);    -- maintained by the store; 0 → deleted on vacuum

CREATE TABLE views (
  id TEXT PRIMARY KEY, set_id TEXT NOT NULL REFERENCES sets(id) ON DELETE CASCADE,
  name TEXT NOT NULL, filter TEXT NOT NULL DEFAULT '',
  sort_key TEXT NOT NULL DEFAULT '', sort_desc INTEGER NOT NULL DEFAULT 1,
  columns TEXT NOT NULL DEFAULT '[]', created REAL NOT NULL,
  UNIQUE (set_id, name));

-- Per set, created with it and altered as keys appear:
CREATE TABLE m_<set_id> (
  entry_id TEXT PRIMARY KEY REFERENCES entries(id) ON DELETE CASCADE
  -- + one column per scalar key: REAL for float, INTEGER for int/bool, TEXT for str.
  -- A chain-scope scalar is a column named key__chain (plddt__B).
  -- Indexed on the ranking key; other indexes added by ANALYZE-driven need, not up front.
);
```

**Why a wide table per set and not one entry-attribute-value table.** The drawer and
`set_filter` only ever look at one set at a time, and `plddt > 80 and rmsd < 1.5 ORDER BY
plddt DESC` over a wide table is one indexed scan. Over EAV it is a self-join per
predicate. Column sets differ by tool anyway, so a shared wide table would be sparse and
would need `ALTER TABLE` for every new predictor. Identity and lineage stay in the shared
`entries` table, so cross-set questions still have one place to ask.

**Column names.** A key from `MetricSpec` is `[a-z0-9_]+`; the store rejects anything
else so a key can be quoted into SQL by construction, never interpolated. Chain scalars
use `__` because `/` is not a legal identifier character.

**As built.** `sets` also has `reference TEXT NOT NULL DEFAULT ''` (the superposition
target) and `meta` holds `stage_budget`; `n_residues` is the total sequence length
rather than a guide-atom count. Array-scope declarations are kept in `sets.columns`
with `column = NULL` so a set can list its arrays and their tool. Keys that collide
with `entries` fields (`name`, `tags`, ...) are refused, because `SELECT e.*, m.*`
would be ambiguous. Chain-scalar columns are lowercased (`plddt__b`) so the filter
grammar, whose identifiers are lowercase, can name them.

**Migrations.** `meta.format_version` is checked on open. A newer version than the build
knows refuses to open with a message that says which build wrote it. Older versions are
migrated forward inside a transaction; there is no downgrade path.

### 2.3 Blob formats

| kind | content | why |
|---|---|---|
| `cif` | gzip of one chain as mmCIF text, from `get_cifstr` on the peek object | one blob per chain so a rigid target shared by a batch is stored once; text so `sqlite3` + `zcat` gets a file out with no RayMol present |
| `f32` | little-endian float32 array, length = `len(index_json)` (residue) or its square (pair) | what `MetricValue.values` already is, in binary |
| `u8q` | uint8 array with `scale`/`offset`; used for **pair** scope when the spec has `lo`/`hi`, else `f32` | PAE is 0–31.75 Å; 0.125 Å steps lose nothing a plot can show and are 4× smaller than f32 |
| `thumb` | JPEG bytes | reserved; written only by #420 |

Content addressing dedupes identical bytes only. Whether RFD3 re-centres the target per
design, and so defeats chain dedupe, is a **measurement to take in #416** on a real batch;
if it does, a rigid-transform-aware dedupe is a later optimisation, not a schema change.

Hashes are of the uncompressed bytes so the same chain from a `.pdb` import and a
`get_cifstr` round trip do not have to compress identically to match.

## 3. Package layout

```
modules/pymol/sets/
    __init__.py     docstring; imports nothing heavy
    errors.py       SetError(CmdException) → SetNotFound, SetNameConflict, SetInputError,
                    SetFilterError, SetBudgetExceeded, SetFormatError
    schema.py       DDL, format version, migrations, the key → SQL type mapping
    store.py        the Container class: open/close/save/vacuum-into, sets/entries/runs/
                    views CRUD, wide-table maintenance, blob refcounts, version bump
    blobs.py        encode/decode for cif, f32, u8q; hashing; chain splitting
    filter.py       the expression grammar (§5): parse → AST → parameterised SQL
    binding.py      everything that asks the SESSION: stage/unstage/pin, peek, capture
                    an object into an entry, copy metrics runs in and out, group upkeep,
                    the .pse warning, the restore task
    document.py     import (folder, single file, fasta) and export (folder + CSV, fasta,
                    csv); no session access
modules/pymol/setting_sets.py   the cmd.set_* surface, in the style of metric.py
```

`store.py` never imports `cmd`. `binding.py` is the one module that does, mirroring the
metrics package. `blobs.py` imports `gzip`, `hashlib`, `struct`, `array`; no numpy, so it
runs in the bundle (the MCP notes record that numpy is not there).

Registration: `cmd.py` gets a block like the metrics one that appends
`binding.session_restore` to `_session_restore_tasks` and wraps the import in `try`.
`importing.loadfunctions['raymol']` and `exporting.savefunctions['raymol']` route the
container; `keywords.py` lists the commands with `parsing.STRICT`.

## 4. The command surface

Every drawer action in later steps is one of these. Arguments follow PyMOL conventions:
positional-or-keyword, `quiet=1`, `_self=cmd`. `entries` arguments accept the selector
language in §4.1.

| command | does | returns |
|---|---|---|
| `set_create name [, kind=structures, note=]` | new empty set; group name = `name` | set name |
| `set_delete name` | unstage all, delete the group if empty, drop the set and its `m_` table | |
| `set_rename old, new` | rename the set, its group and (if empty of other members) nothing else | |
| `set_list [name]` | no arg: every set with count and kind. With a set: its entries under the active filter and sort, one line each with the ranking key | list of dicts |
| `set_info name` | columns with their specs, counts (all / filtered / staged / starred / rejected), budget, group, tool(s) | dict |
| `set_add name, source [, entries=, run=, parents=, tool=, tool_version=, inputs=]` | add entries from an **object** (captures chains, sequences and every metrics-store run on it), a **structure file**, a **folder** of structure files, or a **FASTA** (sequence entries). Names default to the object / file stem, made unique within the set | entry names |
| `set_remove name, entries` | drop entries (unstaging first) | |
| `set_get name, entries [, key=]` | scalars plus `id`, `run_id`, `parents`, `sequences`, flags, `tags`, `note`, `staged`; or one field; or one array as `(index, values)` | |
| `set_set name, entries, key, value` | write `note`, `tags`, or a column declared under tool `user` or `import`; a tool's own measurements are read-only | |
| `set_filter name [, expr=]` | set (or clear) the active filter; prints `n of N match` | count |
| `set_sort name, key [, desc=1]` | set the active sort; a column also becomes the set's `ranking_key` | |
| `set_stage name, entries [, budget=]` | load each entry as an object named after it inside the set's group, superposed on the reference (§6); write its metrics into the metrics store; refuse past the budget with the names it would have to unstage | object names |
| `set_unstage name [, entries=staged]` | delete the objects (pinned ones only if named explicitly), remove their metrics runs, clear the links | |
| `set_pin name, entries [, on=1]` | pin/unpin staged entries | |
| `set_star name, entries [, on=1]` | | |
| `set_reject name, entries [, on=1]` | | |
| `set_tag name, entries, tag [, remove=0]` | | |
| `set_peek name, entry` / `set_peek` | draw one entry in the hidden peek object, replacing the previous; no args clears it | |
| `set_reference name [, object=]` | the object staged and peeked entries are superposed on; none until set (deriving it from a run's `target` input is #416's job, once batches write runs) | |
| `set_budget n [, name=]` | the stage budget for one set, or without a name the file's default (`meta.stage_budget`) | |
| `set_view_save name, view [, filter=, sort=]` | save the active (or given) filter and sort as a named view | |
| `set_view_delete name, view` | | |
| `set_export name, path [, entries=filtered, format=]` | `folder`: one CIF per entry plus `entries.csv`; `csv`: the table; `fasta`: sequences. Format from the path's extension when not given | path |
| `set_import path [, name=, kind=]` | `set_create` + `set_add` in one, named after the folder or file | set name |
| `set_schema name` | print the columns as `metrics_schema` prints a tool's | |

`load x.raymol` and `save x.raymol` are the existing commands with a new format.
`load x.raymol, partial=1` is refused: a partial load merges a scene, and two documents'
sets have no meaningful merge. `set_filter` and `set_view_save` are registered with
`parsing.LITERAL1`/`LITERAL2`, so on the command line everything after the fixed
arguments is the expression and `=` and commas inside it survive.

Names taken from objects and files are sanitised (`legal_entry_name`) and made unique
within the set with `_2`, `_3`...; a name typed for an entry is validated and a
conflict is refused.

### 4.1 Entry selectors

One string, no spaces, resolved against a set:

| selector | meaning |
|---|---|
| `d_0417` | one entry by name |
| `d_0417+d_0088` | several |
| `all` | every entry |
| `filtered` | the active filter's matches, in the active sort |
| `top:20` | the first 20 of `filtered` |
| `starred` · `rejected` · `staged` · `pinned` | by flag |
| `view:top50` | a saved view's matches |
| `run:<id>` | produced by one run |

Selectors are not composable with `and`/`or`; that is what `set_filter` is for. A name
that matches no entry is an error, not an empty selection: an agent that mistypes a name
must hear about it.

## 5. The filter expression

A small language compiled to a parameterised `WHERE` clause over `m_<set>` joined to
`entries`. It exists so the same string works in the console, over MCP, in a saved view
and in the drawer's filter bar (#418), and so the table can never see raw SQL.

```
expr     := or
or       := and ('or' and)*
and      := not ('and' not)*
not      := 'not' not | cmp
cmp      := '(' expr ')'
          | column op value
          | column 'in' '(' value (',' value)* ')'
          | column 'is' ['not'] 'null'
          | 'tags' 'contains' string
          | 'name' ('like' | '=' | '!=') string
          | flag
op       := '<' | '<=' | '>' | '>=' | '=' | '!='
column   := [a-z][a-z0-9_]* ('__' chain)?      -- must be a declared column of the set
value    := number | string | 'true' | 'false'
flag     := 'starred' | 'rejected' | 'staged' | 'pinned'
```

Rules: identifiers are validated against the set's columns before any SQL is built;
values are always bound parameters; `like` uses SQL semantics with `%` and `_`; a `null`
column value never matches a comparison, matching `MetricSpec.cast`'s "absent is not
zero". Errors name the token and offset. The grammar has no function calls, no
arithmetic and no subqueries on purpose: anything that needs them belongs in Python
over `set_get`.

## 6. Staging, peeking and the reference

- **Names.** A staged object is named after the entry. If that name is taken by an
  object that is not this entry's, `_2`, `_3` … is appended; `entries.staged_object`
  records the actual name, so nothing else has to guess.
- **Group.** Created on first stage as `group <set.group_name>`, members added with
  `group name, member, action=add`; removed when the last member is unstaged and the
  group has no other members. A user who drops something else into the group keeps it.
- **Budget.** `sets.budget`, else the setting `raymol_stage_budget` (default 6). Pinned
  entries count. `set_stage` past the budget raises `SetBudgetExceeded` listing the
  unpinned staged entries it would need to drop; it never drops them itself. The default
  is deliberately small; the structure-count measurements in the MCP notes are the
  place to read before raising it.
- **Metrics on staged objects.** Staging writes one metrics-store run per source run on
  the new object (`binding.record` with the same tool and inputs), so `metrics_color`
  and the `.pse` see a staged design exactly as they see a predicted one. Unstaging
  deletes those runs. Capturing an object into a set does the reverse copy.
- **Reference and superposition.** `set_reference` names an object. Staging and peeking
  `super` the new object onto it when both have polymer; failure to superpose is a
  warning, not an error. With no reference, objects land where their coordinates say.
- **Peek.** One object, `_raymol_peek`. The leading underscore keeps it out of
  `public_objects`, the panel, and the sequence rows. `set_peek` loads the entry's
  chains into it (after `delete` of the previous content), superposes, and applies a
  fixed look: cartoon only, one dim colour, `cartoon_transparency 0.5`. It is never
  written to a `.pse`: the session save task strips it from the session dictionary,
  so saving does not disturb what the user is looking at. `set_stage` of the peeked
  entry reuses nothing; it loads fresh, so a peek can never leak its look into a real
  object.
- **Loading an entry.** The CIF reader refuses to load into an existing object, so an
  entry's N chain blobs go into N hidden `_raymol_chain_<i>` temporaries and one
  `create` merges them; the temporaries are deleted at once. A peek or stage therefore
  costs N loads, one create and N deletes, not one load. The same merge reads a folder
  export back, whose CIF per entry is one `data_` block per chain.
- **Links follow the scene.** `delete` clears links whose objects are gone at once, so
  an object later created under a recycled name is never mistaken for the entry;
  `set_name` moves a link to the new name; a staged object missing from a loaded
  session is unlinked on restore.

## 7. What `set_add` captures from an object

For each chain of `object` (polymer or not): `get_cifstr('%s and chain %s')` → blob.
Sequences from `get_fastastr` per polymer chain. `n_residues` from `guide` atoms.
Every metrics-store run on the object becomes: scalars → columns of `m_<set>` (declared
from the run's `MetricSpec`s, so the set's `columns` grows as tools appear); residue and
pair arrays → `arrays` rows. The run's `inputs` and tool go to `runs`. An object with
states adds one entry per state, named `<object>_<state>`, unless `entries=current`.

For a **file**, the store loads it into `_raymol_peek`, captures as above, and clears
the peek. That is the one path, so a file and an object always yield the same entry.

## 8. Performance targets

Measured in `testing/tests/sets/sets_perf.py` on the test machine, printed, and asserted
loosely (a 3× margin) so a slow CI does not fail them spuriously:

| operation | target |
|---|---|
| open a file with 100k entries, list sets | < 200 ms, no blob read |
| `set_filter` on 100k entries, two predicates, indexed ranking key | < 100 ms |
| `set_add` of 1000 structure files, ~70 residues each | < 15 s (dominated by `load`) |
| `set_stage` of one entry | < 50 ms + `load` |
| `save` of an already-open document | < the `.pse` pickle time + 50 ms |

## 9. Tests

`testing/tests/sets/`, run with `pymol -ckqy testing/testing.py --run testing/tests/sets/<file>`:

- `sets_store.py`: DDL and migration guard; wide-table growth as keys appear; blob
  refcount and dedupe (the same chain added from two objects is one blob); u8q round
  trip within scale; rejection of a key that is not `[a-z0-9_]+`.
- `sets_filter.py`: every grammar production; precedence; `null` semantics; a table of
  hostile inputs (`plddt > 80; DROP TABLE`, an undeclared column, unbalanced quotes)
  each raising `SetFilterError` with an offset.
- `sets_commands.py`: each `set_*` command's happy path and its named error; the entry
  selector table; `set_stage` budget refusal lists the right names; staging writes
  metrics runs and unstaging removes them; `set_add` from an object with states.
- `sets_session.py`: `save x.raymol` → `load x.raymol` restores sets, staged links,
  active filter and views; `save x.pse` warns and carries no set data; `load x.pse`
  clears the store; Save As moves the working database and subsequent writes land in
  the new file; the peek object never reaches a `.pse`.
- `sets_document.py`: folder import with mixed `.pdb`/`.cif`, FASTA import, folder and
  CSV export round trip to a fresh set with equal scalars.
- `sets_perf.py`: §8.

The fake-generator delivery test belongs to #416.

## 10. Decisions taken here

1. **Wide table per set, not EAV.** For the query shape and the heterogeneity of
   columns across tools. (§2.2)
2. **One entry per model.** A Boltz five-sample run is five entries. (§1)
3. **Per-chain structure blobs.** Cheap to write, one `load` per chain to read, and the
   only way batch-shared chains can dedupe. Whether they do for RFD3 is measured in #416.
4. **Documents are written in place as results land.** Crash safety over
   "unsaved-changes" purity. Save writes only the session blob. (§2.1)
5. **Peek is a hidden `_`-prefixed object with a fixed look**, never a real object
   re-styled, so it cannot leak. (§6)
6. **The filter language is closed**: no functions, arithmetic or subqueries. (§5)
7. **`.pse` carries nothing about sets.** A warning, never a partial embed. (§2.1)

## 11. Open questions for review

- Default `raymol_stage_budget`: 6 is a placeholder until the MCP structure-count
  measurements are re-read for the current renderer.
- Whether `set_add` from a **folder** should also read a sibling `entries.csv` in this
  step, since the exporter writes one. It is ten lines and makes export → import
  lossless; the Rosetta `score.sc` reader stays in #420.
- iOS: Python's `sqlite3` module needs `libsqlite3` in the bundle; confirm the iOS
  Python build links it before #417 assumes it.
