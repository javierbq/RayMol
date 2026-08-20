# Design-mode multi-residue selection

**Date:** 2026-08-19
**Branch:** `claude/residue-design-selection-7ca455`
**Platforms:** macOS + iOS (Design mode is gated on `RAYMOL_MPNN`, now enabled for both)

## Problem

Design mode and normal (viewing) mode disagree about what a click means.

In **normal mode**, a viewport click runs `metal_pick.pick_at`, which *toggles* the
picked residue in and out of PyMOL's `sele`. Clicking three residues selects three;
clicking a selected one removes it; clicking empty space clears. Multi-residue
selection is the default and needs no ceremony.

In **design mode**, a click runs `DesignController.handleViewportHit` →
`tapResidue` → `setPinned`, which sets a single `pinnedResidueIndex`. Only one
residue can be active at a time. Multi-residue selection *does* exist
(`selectedResidueIndices`) but is reachable only via:

- the "Select region…" lasso dropdown (named selections), or
- flipping the modal **"Tap to edit region"** toggle (`regionEditMode`, the
  `hand.tap` button) so that taps call `toggleRegionResidue` instead of pinning, or
- on macOS only, shift-clicking a column of the sequence strip.

So the same physical gesture means "replace the single selection" in one mode and
"add to the selection" in the other, and the multi-select path is behind a mode
switch users must discover. That inconsistency is the bug.

Additionally the data flow is inverted: `setPinned` owns `pinnedResidueIndex` and
then *pushes* a one-residue `sele` outward via `raymol_design.set_pinned_indicator`
purely so the renderer draws a pink committed-selection marker. `sele` is an
output of design mode rather than its input.

## Goals

1. A plain click in design mode builds a multi-residue selection exactly as it
   does in normal mode.
2. One residue selected → today's single-residue behavior is preserved verbatim
   (propensity pill row, tap-a-pill to mutate).
3. Two or more selected → the region is automatically designated on `sele`, so the
   "Redesign selection · N res" action targets it with no dropdown step.
4. `sele` becomes the single source of truth, so a selection made anywhere —
   Seeker/sequence panel, `select` at the command line, the object panel — drives
   design mode too.

## Non-goals

- Auto-*running* a redesign. Reaching 2+ residues arms the Redesign button; MPNN
  inference fires only on an explicit press. (Auto-run would burn an inference per
  click and discard every intermediate result.)
- Single-residue redesign through the region path. One residue keeps the
  propensity-pill route, which already expresses "mutate this position".
- Reworking the design overlay's layout, coloring modes, repack, or compare paths.
  This change is confined to how a selection is made and how the mode is derived.

## Behavior specification

### Click → `sele`

| Click target | Effect |
|---|---|
| Residue on the focus object, not in `sele` | add that residue to `sele` |
| Residue on the focus object, already in `sele` | remove that residue from `sele` |
| Residue on a **different** object | refocus design to that object, then `sele` ← just that residue |
| Empty space | `sele` ← `none` |

Clicking an already-selected residue both deselects and unpins. The old
single-residue behavior (`setPinned` toggles the pin off when the same residue is
clicked twice) already agreed with normal-mode toggle semantics, so the two
unify without a special case.

### `sele` → mode

Let `N` = number of designable residues in `sele ∩ scope(focusObject, editSourceObject)`.

| `N` | Resulting state |
|---|---|
| 0 | `pinnedResidueIndex = nil`, `selectedResidueIndices = []`. Propensity row renders in its existing greyed/idle form. |
| 1 | `pinnedResidueIndex = i`, `selectedResidueIndices = []`. `regionModeActive` stays `false`, so the propensity pill row and pill-tap mutation behave exactly as today. |
| ≥2 | `pinnedResidueIndex = nil`, `selectedResidueIndices = [...]`. `regionModeActive` becomes `true`, so the palette row replaces the pills and "Redesign selection · N res" is armed. |

Keeping `selectedResidueIndices` empty at `N == 1` is deliberate: `regionModeActive`
is defined as `!selectedResidueIndices.isEmpty` and gates the pills-vs-palette
switch, so this preserves goal 2 without editing every consumer.

Residues that are not designable (missing backbone, `valid == false`) are dropped
from the count and from the region, as `pickSelection` already does.

The region's label (`selectedSelectionName`, shown on the lasso button) follows the
last explicit designation: `pickSelection(name)` records `name`, and any subsequent
click clears that record so the label falls back to `"sele"`. This keeps a
dropdown-chosen region readable as e.g. `interface` while a click-built one reads
as `sele`.

`sele` residues that live on objects other than the focus object are ignored for
design purposes — they still render pink, but the region is always
`sele ∩ focus object`. This falls out of reusing the existing `_scope` helper.

## Architecture

### Inverting the data flow

```
click ──▶ toggle residue in 'sele'   (Python, residue-scoped)
              │
              ▼
        syncFromSele()               (Swift, @MainActor)
              │  sele ∩ scope(focus, editSource) → full-length guide indices
              │  → filter to valid
              │
              ├─▶ N == 1  → pinnedResidueIndex = i,   selectedResidueIndices = []
              └─▶ N >= 2  → pinnedResidueIndex = nil, selectedResidueIndices = [...]
```

`pinnedResidueIndex` and `selectedResidueIndices` remain `@Published` properties
(much of the UI reads them) but become **derived state, written only by
`syncFromSele()`**. The outward `sele` write in `set_pinned_indicator` leaves the
pin path entirely: the pink marker *is* `sele`, which the renderer already draws.

### Reuse

`raymol_design.selected_design_indices(obj, selection, state, src)` already does
the hard part — it maps a named selection to full-length residue indices in the
object's canonical guide order, and its `_scope(obj, src)` already covers the
edit-session case where the focus object is the working copy `foo_design01` while
the selection was made on the original `foo` (matched by `(chain, resi)`
identity). Passing `selection='sele'` is sufficient; no new mapping logic.

### New / changed surfaces

**`modules/pymol/raymol_design.py`**

- `design_selection_state(obj, state, src='')` — writes
  `$TMPDIR/raymol_design_sele.json` = `{'indices': [int], 'digest': str, 'n_total': int}`.
  `indices` is `sele ∩ scope` in guide order (same contract as
  `selected_design_indices`); `digest` is a cheap fingerprint of the selected
  `(chain, resi)` set for change detection; `n_total` is the residue count of
  `sele` across all objects, so the UI can tell "nothing selected" from
  "selected, but on another structure".
- `toggle_sele_residue(obj, chain, resi, src='')` — add/remove one residue in
  `sele` using the same idiom as `pick_at` (`cmd.select('sele', ..., enable=1)`),
  and `set_sele_residue(obj, chain, resi, src='')` / `clear_sele()` for the
  refocus and empty-space cases. The writers take `src` and resolve the residue
  through the same `_scope(obj, src)` the readers use — a WRITE scoped to the
  focus object alone disagrees with the residue-identity READ from the first
  mutation of an edit session onward (see D9).
- `set_design_active(on)` — module flag read by the poll (see Refresh).
- `set_pinned_indicator` keeps its definition but loses every call site: nothing in
  the pin path or in `exit()` writes `sele` outward any more (see D2).

**`swiftui/PyMOLViewer/Shared/DesignController.swift`**

- New injected closures (matching the existing closure-injection pattern so unit
  tests keep bypassing PyMOL): `SeleStateFn` (read indices + digest),
  `ToggleSeleFn`, `SetSeleFn`, `ClearSeleFn`.
  Their **defaults maintain an in-memory residue set** rather than being no-ops, so
  the state machine is exercisable without PyMOL. This matters for existing tests:
  `DesignEditingTests` calls `setPinned(chain:resi:)` and then asserts
  `pinnedResidueIndex == 1`, which would fail against no-op stubs now that the
  property is derived. With the in-memory default those assertions keep passing
  unchanged.
- `syncFromSele()` — the state machine above.
- `tapResidue(residueIndex:)` — toggles `sele`, then syncs. No longer branches on
  `regionEditMode`.
- `handleViewportHit(object:chain:resi:hasResidue:)` — extended to the four-row
  table above; empty `object` now clears `sele` instead of no-op'ing.
- `pickSelection(name)` — sets `sele ← name`, then syncs, so one truth remains.
- `clearSelection()` — clears `sele`, then syncs.
- `setPinned` — retained for the sequence-strip/test call sites but reduced to a
  `sele` toggle + sync; it no longer writes `pinnedResidueIndex` directly.

**`swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`**

- Wire the new closures.
- `designPickResidue` (iOS) currently early-returns when the pick misses, so an
  empty-space tap cannot clear. Change it to call
  `handleViewportHit(object: "", …, hasResidue: false)` on a miss.
- Set the Python design-active flag on design enter/exit.

**`ContentView.swift`** (macOS design bar) and **`DesignCompactPanel.swift`** (iOS)

- Sequence-strip clicks route through the same toggle path as viewport clicks; the
  macOS-only shift-click gesture is deleted (D8), removing the strip's last
  `#if os(macOS)` branch.
- The region-edit toggle is deleted from both the macOS design bar
  (`regionEditToggle`) and the iOS compact panel (`regionEditButton`) (D6).

## Refresh: noticing external `sele` changes

Design-mode clicks refresh synchronously, so the poll is only a backstop for
changes made *outside* design mode (a typed `select`, a Seeker drag, the object
panel).

Rather than adding a timer, piggyback the existing 500 ms
`appkit_inspector.poll_panel` tick, which already gathers selection *names*. It
gains the `sele` digest, computed **only while design mode is active** (the
`set_design_active` flag). Swift re-derives via `syncFromSele()` only when the
digest differs from the last one seen.

This gate matters: `poll_panel` runs on the main thread every 500 ms and is a
previously measured hot spot (PR #270 fixed a 713 ms tick on a large `.pse`). Three
tiers of cost:

- **Design mode off** — one boolean check (`set_design_active`'s flag), nothing else.
- **Design mode on, `sele` unchanged** — the digest only: one `cmd.iterate` over
  the guide atoms of `sele`, i.e. O(selected residues), plus an md5 of the key
  list. The digest matches, so Swift skips the re-derive.
- **Design mode on, `sele` changed** — the re-derive runs `sele_design_indices`,
  and that is **not** O(selected residues): it calls `_obj_residue_order(obj)`, a
  `cmd.iterate` with a Python callback over EVERY guide residue of the focus
  object, plus a second `iterate` over `sele ∩ scope`. So the changed-tick cost is
  O(residues in the focus object) on the main thread — the same shape as the PR
  #270 hot path, though bounded by one focus object rather than a whole session,
  and it cannot recur faster than 2 Hz or without the selection actually changing.

The digest gate is therefore load-bearing, not an optimisation: it is what keeps
the O(object) work off the quiet ticks.

## Decisions

- **D1 — Clicks always expand to residue scope**, ignoring `mouse_selection_mode`.
  With that setting on *atom* (0), `_mode_expr` returns a single-atom expression;
  `selected_design_indices` matches through `guide` atoms, so picking a side-chain
  atom would map to **zero** residues — a click that silently selects nothing.
  Design operates on residues, so residue scope is forced. Whole-chain regions
  remain reachable via the lasso dropdown or a Seeker chain-select.
- **D2 — Exiting design mode no longer clears `sele`.** Today `exit()` sends
  `pinnedIndicatorFn("", "", "")`, wiping the selection. Once `sele` is the user's
  ordinary selection, destroying it on a mode change is the surprising behavior.
- **D3 — 2+ residues auto-*designate*, never auto-run.** See Non-goals.
- **D4 — A click on a non-focus object refocuses *and* selects that residue**, so
  there is no dead first click. Previously it refocused and discarded the selection.
- **D5 — The lasso dropdown stays**, rewritten to set `sele` rather than snapshot
  its own copy.
- **D7 — Sidechain sticks stay tied to `{pinned} ∪ {hovered}`.** `reconcileSticks`
  is not extended to the region: at `N >= 2` the pin is `nil`, so only the hovered
  residue shows transient sticks. Showing sticks for every region member would
  explode on a large region, and the global "show sidechains" toggle already
  covers that intent.
- **D6 — `regionEditMode` is removed entirely.** The count of `sele` now decides
  single-vs-region, so the modal toggle has no job left, and a control that changes
  nothing reads as a bug. Deleted: the `@Published var regionEditMode`, its branch
  in `tapResidue`, its reset in `clearRegionState`, `regionEditToggle` in
  `ContentView.swift`, and `regionEditButton` in `DesignCompactPanel.swift`. No
  XCUITest depends on its `"Tap to edit region"` accessibility label (only
  historical plan docs mention it, which stay untouched).
- **D8 — The macOS shift-click shortcut is removed too.** Once a plain tap toggles
  region membership, `TapGesture().modifiers(.shift)` calling
  `toggleRegionResidue` is an exact duplicate of the plain tap. Its own comment
  documents the hazard: if SwiftUI ever delivered both, the position would be
  "toggled twice — added then removed — a silent no-op". Deleting it also removes
  the last `#if os(macOS)` divergence in the sequence strip, which is valuable given
  this file's history of platform-only symbols leaking across targets.
- **D9 — `sele` writes are scoped identically to `sele` reads.** Both sides go
  through `_scope(obj, src)`, so a residue is addressed by `(chain, resi)` identity
  across an edit session's working copy and its original, not by object membership.
  Two consequences are deliberate: a scoped "add" marks the residue on *both*
  objects (which is what makes it survive a repack's topology replace of the
  working copy), and `_sele_residue_keys()` therefore folds `<src>_designNN` onto
  `<src>` so one residue marked twice is still counted once — otherwise `n_total`
  exceeds the in-scope count and the UI invents a "+N on another structure" badge.
  Asymmetric scoping made a region member impossible to remove mid-session and let
  every repack silently shrink the region.

## Testing

TDD. This repo hand-lists test files in CI, so tests go into files already
registered rather than new unregistered ones (a new file must also be added to
`.github/workflows/raymol-embedded-tests.yml`).

**Python — `testing/tests/raymol/design_region.py`** (already in CI)

- `design_selection_state` returns guide-order indices for a 1-residue, 3-residue,
  and empty `sele`.
- Non-designable (missing-backbone) residues are dropped.
- A `sele` spanning two objects yields only the focus object's residues.
- A `sele` made on the original maps onto the working copy `foo_design01` by
  `(chain, resi)` identity.
- `digest` changes iff the selected residue set changes (stable across a no-op
  re-select; different for a different set).
- `toggle_sele_residue` adds then removes; `clear_sele` empties.

**Swift — `swiftui/PyMOLViewerTests/DesignRegionTests.swift`**

- `syncFromSele` state machine at N = 0, 1, 2, 3, including the
  `pinnedResidueIndex` / `selectedResidueIndices` / `regionModeActive` triple.
- `handleViewportHit`: toggle on focus object; refocus-plus-select on another
  object; clear on empty space.
- Sequence-strip tap parity with a viewport tap.
- Region survives the transition into an edit session (working-copy focus).

**Existing tests that encode the old rule and must be rewritten**

Two blocks in `swiftui/PyMOLViewerTests/DesignIOSPortTests.swift` assert the
behavior this change removes, and will fail until updated:

- `testTapTogglesRegionWhenRegionEditModeIsOn` — asserts that with
  `regionEditMode = true` a *single* tap yields `selectedResidueIndices == [1]` and
  `pinnedResidueIndex == nil`. Under the new rule one tap is always `N == 1`, so it
  pins. Rewrite to the count-driven rule: one tap pins, a second tap on a different
  residue produces a 2-residue region with `pinnedResidueIndex == nil`.
- `testTapIgnoresInvalidResiduesInRegionEditMode` — same premise; keep the
  invalid-residue assertion but drop the `regionEditMode` framing.

Because D6 deletes `regionEditMode`, both of these stop compiling rather than
merely failing, so they are rewritten (not deleted) to assert the count-driven rule
— the multi-residue coverage they provide is exactly what this change needs.
`testTapPinsWhenRegionEditModeIsOff` loses its `regionEditMode` assertion but keeps
its body. `testHandleViewportHitRegionEditMode` (`DesignIOSPortTests:564`) likewise
becomes a plain multi-tap test. The stick-ownership tests at
`DesignIOSPortTests:1032` and `DesignEditingTests:363` survive unchanged (verified
against the new semantics).

**Manual / functional**

Both targets must be compiled by hand: no CI workflow runs `PyMOLViewerTests`, and
CI never compiles the iOS target, so a symbol that leaks across the
platform boundary is caught only locally. Functional verification of the click
behavior runs in a disposable macOS VM per the project's testing convention.

## Risks

- **Fighting over `sele`.** Two writers (design mode and `pick_at`) touch the same
  selection. Mitigated because design mode never runs `pick_at` — `MetalViewport`
  already routes design-mode clicks down a separate branch.
- **`cmd.enable('sele')` is exclusive for selections**, so enabling it disables
  others. This is pre-existing `pick_at` behavior and unchanged here; `_preselect`
  must stay `enable=0`, as it already is.
- **Poll cost** if the design-active gate is ever bypassed. Covered by the design-active
  gate plus the digest, so the re-derive is skipped on unchanged ticks.
