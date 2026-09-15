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
page is about the UI that sits on top of them (#417, #418, tracking #421).

## Where things appear

- **Inspector → SETS.** One row per set: name, entry count, a small histogram of the
  ranking column, a spinner with `done / total` while a batch is still landing, and an
  "open in drawer" button. Saved **views** are listed under their set, one click to
  apply; the row shows the selector (`view:top50`) you would type. The section
  collapses when there is no set, so a session that never touches one looks exactly
  as before.
- **Inspector → OBJECTS.** A set's group is an ordinary group row. It holds exactly
  the set's staged objects and reads "5 of 1024 staged" — the rest of the set is in
  the drawer, not in the scene.
- **Data drawer** (macOS; `View ▸ Show Data Drawer`, ⌘4). A band below the viewport
  with a header naming the set, the tabs, the filter bar and the active tab. Table
  and Plot are live; Sequences and Lineage are drawn disabled until #419 lands. Drag
  the divider above it to resize; the height is remembered as a fraction of the
  window, like the console's.
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
**Unstage**, **Pin** (a pinned object survives "clear staged"), **Columns ▾** (what
shows), **Send to ▾** (the next tool, or an export — see below) and **Save view…**
(`set_view_save`, the active filter, sort and visible columns under a name usable as
`view:NAME`). Stage is disabled when the selection would not fit the stage budget, and the footer
says by how much; raise it with `set_budget`, or unstage (or pin) what is already
there. The header's "n of N staged · budget b" is the same arithmetic.

Every drawer action is a `set_*` command. Anything you can click you can also type,
script, or ask an agent to do over MCP; the drawer is a client of the command surface,
not a second one. `appkit_sets.open_set('name')` from Python opens a set in the drawer
the way a click does.

## Filtering

The drawer's filter bar takes an **expression** over the set's columns:

    plddt > 80 and rmsd < 1.5 and not rejected
    tags contains "patch-A" or starred
    iptm is null

It is the same language `set_filter` takes, because it *is* `set_filter`: the field
sends the string to Python, which compiles it with `pymol.sets.filter` and reports
what matched. There is exactly one grammar, and it is documented in §5 of the store
spec — columns, the flags `starred` / `rejected` / `staged` / `pinned`, `name` with
`like`, `tags contains`, `in (…)`, `is null`, and `and` / `or` / `not`. There is no
arithmetic, no `between` and no function calls; anything that needs them belongs in
Python over `set_get`.

The count beside the field is live ("212 of 1024 match"). An expression the grammar
rejects shows its own message with the offending token quoted, and leaves the set's
filter alone. Clearing the field brings every entry back.

**Header histograms are brushes.** Each numeric column has a small distribution under
its header; drag across it to filter to that range, click it to clear. A brush is
written as an ordinary expression (`plddt >= 80 and plddt <= 92`) and joined to
whatever you typed with `and`, so the two never disagree; a chip in the filter bar
shows each brushed range with an × to drop that one column, and **Edit as text** writes
the brushes into the field so you can edit the string that went to `set_filter`.

While you drag, the filter is only previewed — nothing is written to the file. It is
applied with `set_filter` when you let go, when you press Return, or after a moment's
pause in typing; that is the point at which `filtered`, `top:N`, `set_export` and
`predict set:<name>@filtered` see it too.

A **view** is a filter, a sort and a visible-column list under a name
(`set_view_save`). Views appear under their set in the inspector, apply with a click,
and are entry selectors everywhere: `set_export s, out.csv, view:top50`,
`predict boltz2, set:s@view:top50`.

## The Plot tab

One scatter over the same filtered rows the table shows — filter in one and the other
follows. Choose the x, y and colour columns from the menus, or colour by tag, parent,
run or staged state. Staged points are ringed, the peeked point is drawn large, and
hovering a point peeks it and raises a card with **Stage**, **★** and **✕**.

Drag a rubber band to select points; the table selects and scrolls to the same rows.
**Filter to selection** turns that band into range filters on both axes, through the
same expression path as a header brush. The strip under the x axis is that column's
distribution and brushes like a header histogram.

An entry with no value on one of the axes is left out rather than drawn at zero — an
unmeasured entry is not a bad one — and the footer says how many.

## Linked selection

Rows, points and the scene are one selection:

- selecting rows highlights their points, and vice versa;
- clicking a **staged object in the viewport** selects its row and scrolls to it. The
  link is the entry's `staged_object`, so it works for anything staged, however it was
  staged, and it costs no extra poll.

## Send to ▾

The footer's **Send to ▾** hands the current selection — or, with nothing selected, the
active filter — to the next tool as an entry selector, and says which in the menu.
**Predict** lists the registered predictors and runs
`predict <predictor>, set:<name>@<selector>`, which writes a child set whose entries
point back at the ones they were folded from. **Export** writes CSV, FASTA or a folder
of CIFs. **Design / MPNN** and **Binder Design** are disabled with a note saying why:
they still take a target *object*, not a set.

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

**An untitled session's sets survive a quit** (#447). The working file is pid-scoped,
but it is deleted on the way out only when every set in it is empty; one that holds
entries is renamed `recovered_<date>_<pid>.raymol` and kept, and the same is true of a
file a crash left behind (which the next launch used to sweep). On quit RayMol also
writes the session into it, so what comes back is the scene as well as the sets.

On the next cold launch, if such a container exists, RayMol says so before you use the
window and offers **Open**, **Discard** or **Keep for Later**. Open reuses the ordinary
`.raymol` document path — the file opens in place, and results that land afterwards go
straight back into it — so the recovered session continues where it stopped. Discard
deletes it. Keep for Later leaves it alone and offers it again next time. If more than
one is waiting, the most recent is offered and the alert says how many there are.

Kept is not kept forever: RayMol keeps the **ten most recent** preserved containers and
drops anything **older than 30 days**, sweeping once on the first launch that touches
the store. Nothing is swept while it is open — not by this RayMol and not by a second
one — so the sweep can never pull a document out from under a running session.

Saving with `⌘S` (or `save x.raymol`) is still how you put the session somewhere you
chose: a recovered container lives in `~/Library/RayMolState` under a machine-generated
name, and Save As *copies* it to the path you pick, makes the copy the live document,
and then removes the recovered original — so the next launch does not offer to recover
work you just saved.

The offer is **macOS only** for now, and so is writing the session into the container on
quit. Under command-line PyMOL and on iOS the container is still preserved with its
entries — nothing is lost — but there is no alert, and a container preserved without
that final write carries the sets and not the scene. iOS keeps its own `autosave.pse`
path unchanged; wiring the offer there is #420's work.

## How the app stays fast

The object panel polls Python every 500 ms and that poll must not grow with the number
of entries. So set contents never cross that channel: Python prints one short `SETS:`
line carrying the file's path and version, only when something changed, and the app
reads the `.raymol` file itself with a read-only SQLite connection, re-reading only
when the version moves. A hover storm costs at most one peek load per 120 ms.

Filtering follows the same rule. What comes back from Python is not a list of rows but
the compiled `WHERE` fragment with its bound parameters, which the app runs against the
connection it already has. So entries that land while a batch is running fall on the
right side of the active filter with no round trip per delivery, and the table and the
plot cannot disagree about what matches. Column histograms are computed once per change
rather than per frame.
