# Sets and the Data drawer

A **set** is a collection of candidates — the output of a design batch, a folder of
predictions, an imported score file — browsed apart from the scene. Its entries are
data: sequences, a lazily loaded structure, scalar metrics, flags. Nothing in a set is
drawn until you **peek** it (a transient ghost) or **stage** it (a real object in the
set's group). This is how a thousand-design batch stays a thousand rows in a table
instead of a thousand objects in the panel.

Sets live in a `.raymol` file together with the session. The store, the `set_*`
commands and the file format are described in
`docs/superpowers/specs/2026-09-07-sets-store-and-raymol-container-design.md`; this
page is about the UI that sits on top of them (#417, tracking #421).

## Where things appear

- **Inspector → SETS.** One row per set: name, entry count, a small histogram of the
  ranking column, a spinner with `done / total` while a batch is still landing, and an
  "open in drawer" button. The section collapses when there is no set, so a session
  that never touches one looks exactly as before.
- **Inspector → OBJECTS.** A set's group is an ordinary group row. It holds exactly
  the set's staged objects and reads "5 of 1024 staged" — the rest of the set is in
  the drawer, not in the scene.
- **Data drawer** (macOS; `View ▸ Show Data Drawer`, ⌘4). A band below the viewport
  with a header naming the set, the tabs, and the Table tab. Plot, Sequences and
  Lineage are drawn disabled until #418/#419 land. Drag the divider above it to
  resize; the height is remembered as a fraction of the window, like the console's.
  In a short window the console and the sequence strip get their space first, and the
  drawer says so with a one-line hint rather than showing a table too short to hold a
  row — close either pane (⌘1 / ⌘2) or enlarge the window.
  iPad and iPhone show the SETS section but no drawer yet (#420).

## The Table tab

Two fixed columns lead every row:

| glyph | meaning |
|---|---|
| ★ / ☆ | starred — click or press `s` |
| ● | staged: a real object in the set's group |
| ○ | not staged |
| ◐ | the entry currently peeked (drawn as a ghost cartoon) |

The remaining columns come from the set's metric schema (`MetricSpec`): the header is
the metric's label with its units, numbers are formatted from the declared domain
(0–100 → one decimal, 0–10 → two, 0–1 → three), cells are tinted from "bad" to "good"
when the spec says which end is which, and a first click on a header sorts in the
column's natural direction (an RMSD ascending, a pLDDT descending). Unmeasured values
show as `–` and sort last either way. Rows are virtualized; ten thousand entries
scroll like ten.

Keys, while the table has focus:

| key | action | command it runs |
|---|---|---|
| hover, ↑ ↓ | peek the row (ghost cartoon superposed on the set's reference) | `set_peek set, entry` |
| space | stage / unstage the selection (or the peeked row) | `set_stage` / `set_unstage` |
| `s` | star / unstar | `set_star` |
| `x` | reject / unreject | `set_reject` |
| esc | clear the peek (works anywhere, not only in the table) | `set_peek` |

The footer acts on the selection (or, with none, on the peeked row): **Stage**,
**Unstage**, **Pin** (a pinned object survives "clear staged"), **Export** (CSV, FASTA
or a folder of CIFs plus `entries.csv`, via `set_export`) and **Save view…**
(`set_view_save`, the active filter and sort under a name usable as `view:NAME`).
Stage is disabled when the selection would not fit the stage budget, and the footer
says by how much; raise it with `set_budget`, or unstage (or pin) what is already
there. The header's "n of N staged · budget b" is the same arithmetic.

Every drawer action is a `set_*` command. Anything you can click you can also type,
script, or ask an agent to do over MCP; the drawer is a client of the command surface,
not a second one. `appkit_sets.open_set('name')` from Python opens a set in the drawer
the way a click does.

## The `.raymol` document

`.raymol` is RayMol's own session file: a SQLite database that carries the ordinary
`.pse` as one blob plus the sets, their structures and their metrics. It opens by
double-click, drag onto the viewport, or `File ▸ Open…`; the app opens it **in place**,
so results from a batch write straight into your file as they land, not on Save.
`⌘S` saves a `.raymol` document as `.raymol` and a `.pse` document as `.pse`; the Save
panel offers the open document's format first and the other second.

The first time a session that holds a set is saved with no `.raymol` open, RayMol asks
once whether to save as `.raymol` or as a plain `.pse` without the sets. A `.pse`
stays plain PyMOL — an upstream PyMOL opens it unchanged, and the console warns which
sets were left out. **File ▸ Export PyMOL Session…** always writes one, whether or not
the session has sets, and does *not* change the document you have open, so the next ⌘S
still goes to your `.raymol`. Opening a session file over a non-empty scene asks before
replacing it, for `.raymol` as for `.pse`.

An untitled session's working `.raymol` lives in `~/Library/RayMolState` (the app
container's Library on the sandboxed build), beside the autosaved session, rather than
in `$TMPDIR`, which the system may purge while a batch is running. Under command-line
PyMOL it falls back to `$TMPDIR`, or to `$RAYMOL_SETS_DIR` when that is set.

**Save before you quit.** The working file is pid-scoped and is deleted on a clean exit,
and a file left behind by a crash is swept on the next launch, so an untitled session's
sets do not survive quitting RayMol — only a `.raymol` you have saved does. Spec §2.1's
stronger rule, where an untitled session's working file *is* the autosave and is offered
back on cold launch, is not implemented yet; see the tracking issue.

## How the app stays fast

The object panel polls Python every 500 ms and that poll must not grow with the number
of entries. So set contents never cross that channel: Python prints one short `SETS:`
line carrying the file's path and version, only when something changed, and the app
reads the `.raymol` file itself with a read-only SQLite connection, re-reading only
when the version moves. A hover storm costs at most one peek load per 120 ms.
