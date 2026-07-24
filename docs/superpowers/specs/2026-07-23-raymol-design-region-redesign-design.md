# RayMol #217 Phase 2c — Region redesign (design)

**Status:** design (brainstormed 2026-07-23)
**Predecessors:** Phase 2a (Design mode + confidence viz, PR #221) and Phase 2b (point-mutation editing, PR #227), both merged to `master`.
**Depends on:** MPNNKit ≥ 0.1.2 (already pinned in RayMol).

**In scope:** multi-residue **region redesign** on the focus object — run MPNNKit `design()` over a chosen selection with the rest of the sequence held fixed, fold the single deterministic result into the existing 2b working copy, with a one-level revert. Amino-acid palette restriction via the existing pill row (repurposed as active/inactive toggles).

**Out of scope (later slices):** generating multiple candidate designs (N-variants / temperature sampling); per-position logit bias or a dedicated constraint panel; per-edit undo history beyond the single region-redesign revert; iOS/iPad (2d); MAS (2e); structure "Predict".

---

## 1. Scope & success criteria

**Workflow deliverable:** In Design mode, with a focus object scored, the user picks an existing selection from a **dropdown**, optionally toggles amino acids out of the sampling palette using the (repurposed) pill row, and clicks **Redesign selection**. `design()` runs deterministically over the selected positions, holding everything else fixed; the returned sequence is scattered into the working copy's `editedSequence` at those positions, the confidence coloring re-scores, and (per Auto-repack) the sidechains repack. A **Revert redesign** button undoes the last batch without discarding earlier manual pill edits. Keep/Discard commit the working copy exactly as in 2b. The original object is never modified.

**Success when:**
1. Choosing a selection from the dropdown and clicking **Redesign selection** changes only the selected (designable) positions of the working copy; every other position keeps its current identity.
2. The result is **deterministic and reproducible** (greedy decode + a fixed seed), so repeated runs on the same region + palette produce the same sequence.
3. The **palette toggles** constrain the redesign: a toggled-off amino acid never appears at a designed position.
4. After a redesign the heatmap recolors from the edited sequence, and — per Auto-repack — the region's sidechains repack to the new identities; the original stays untouched and restorable.
5. **Revert redesign** restores the sequence to the snapshot taken immediately before the batch; manual pill edits made *before* the redesign survive the revert.
6. Runs off the main thread (viewport stays responsive); a superseded redesign is dropped by its own job token and never cancels an in-flight rescore or repack.
7. Ships in the macOS build; iOS unaffected; no regression to Phase 2a/2b (single-residue editing still works when no selection is chosen).

---

## 2. The workflow (user-facing, primary)

1. Enter Design mode (⌃D), focus an object → it's scored + colored (2a).
2. Build a selection in the focus object with any PyMOL tool — viewport "S"-picking, the sequence viewer, or the command line (`select loopA, byres chain A and resi 90-101`). The overlay **consumes** selections; it never creates one.
3. Open the overlay's **selection dropdown**. It lists the session's named selections plus the active `sele` when non-empty, filtered to those that touch the focus object's designable residues, each with a count (`loopA · 12 res`). Pick one.
4. Picking **snapshots** that residue set as the region and enters **region mode**: the pill row switches to palette toggles, the chosen residues highlight in the sequence strip, and **`Redesign selection · N res`** lights up.
5. (Optional) toggle amino acids **off** in the pill row to exclude them from sampling (e.g. no new Cys, or hydrophobic-only). Default: all active.
6. Click **Redesign selection** → spinner "Redesigning region…"; `design()` runs off-main; on return, `editedSequence` is batch-updated at the selected positions, the heatmap recolors, and (per Auto-repack) the sidechains repack. You see the redesigned region in 3-D.
7. **Revert redesign** restores the pre-batch sequence; or refine any single position with the 2b pills (in single-residue mode); then **Keep** / **Discard** as in 2b.

Strip while in region mode (illustrative):
`2kpo_design · [selection: loopA · 12 res ▾] · palette: 18/20 · [Redesign selection] · [Revert redesign] · [Auto-repack ▣] [Keep] [Discard]`

---

## 3. Why region redesign folds into the 2b edit session

A region redesign is, in the end, **a batch of amino-acid identity changes** at a set of positions — the same kind of change a 2b pill click makes to one position. So it reuses 2b's entire spine: the working copy `<obj>_design`, the `editedSequence` model, backbone-based rescore, the decoupled whole-structure repack, and Keep/Discard. 2c adds exactly one new inference verb (`design()`), one new region-input surface (the dropdown), a palette-restriction reading of the existing pills, and a one-level revert. It is an **extension**, not a parallel subsystem — there is no second controller and no second working-copy lifecycle.

---

## 4. Region = a selection picked from a dropdown

- **Source:** the overlay reads the session's named selections (`cmd.get_names("selections")`) plus the active `sele` when non-empty. A `raymol_design` helper `list_design_selections(obj, state) → [(name, n_designable)]` filters these to selections whose residues intersect the focus object's designable set and returns per-selection counts. Selections that don't touch the focus object are hidden. The list refreshes when the menu opens.
- **Empty:** no qualifying selections → the dropdown shows "No selections — create one first" and **Redesign selection** is disabled.
- **Designation = pick-time snapshot:** picking a selection calls `selected_design_indices(obj, sele, state) → [Int]`, which maps the selection's residues to indices in the **valid-projected index space** (see §6) and **snapshots** them into `selectedResidueIndices`. The region stays fixed until the user re-picks from the dropdown — it does **not** track the underlying selection if that selection later changes, and a subsequently-deleted named selection leaves the (still-valid) frozen region intact.
- **Display:** the chosen region's residues highlight read-only in the 2b sequence strip so the user sees exactly what will change. There is **no drag-to-select** input on the strip in this slice.

---

## 5. Palette restriction via the repurposed pill row

The 2a/2b propensity pill row changes semantics by mode:

- **Single-residue mode** (no selection chosen in the dropdown): unchanged 2b behavior — each pill shows the active residue's per-AA propensity number, and clicking a pill mutates the pinned residue to that AA.
- **Region mode** (a selection is chosen): the same 20 pills **hide their numbers** and become **active / inactive toggles**. A toggled-off AA is excluded from sampling at every designed position. State lives in `paletteAllowed: Set<Int>` (default = all 20 active). This maps to `design()`'s `omit`: for each designed position, `omit = <the inactive AA indices>`. Guard: if fewer than one AA is active, **Redesign selection** is disabled.

This gives "omit Cys" / "hydrophobic core" for free with **no new panel** — the pill row simply changes hats with the mode.

---

## 6. The `design()` call — parameters, determinism, indexing

Per **Redesign selection** click:

- **Residue set:** `residues = set.validResidues` — the model operates only on residues with a complete backbone, identical to 2b's repack. `L = validResidues.count`.
- **Fixed vs. free:** `fixedPositions = { 0..<L } \ selectedResidueIndices` (every valid position not in the region). The free positions are the region.
- **Native sequence:** `nativeSequence` = the current `editedSequence` **projected through the valid mask** (`zip(residues, editedSequence).filter { $0.0.valid }.map { $0.1 }`). Fixed positions are therefore held to **whatever the user has already edited them to**, not necessarily wild-type. `nativeSequence` is required by `design()` because `fixedPositions` is non-empty.
- **Palette:** `omit` = an `[Set<Int>]` of length `L`; each entry = the inactive-palette AA indices (harmless on fixed positions, which are held by `fixedPositions`/`chainMask`).
- **Determinism:** `temperature = 0` (greedy argmax) **and a fixed `seed` (0)**. `design()` draws its decode order from `MLXRandom.normal`, so even greedy varies run-to-run without a pinned seed; a fixed seed + greedy makes the single result reproducible (success criterion 2).
- **Scatter-back:** `design()` returns `DesignResult.indices` (length `L`). Only the region positions are written: `for i in selectedResidueIndices { editedSequence_valid[i] = result.indices[i] }`, then un-projected back into the full `editedSequence` via the valid mask. Positions outside the region are guaranteed unchanged (they were fixed).

**Indexing discipline (called out because this is where a masking bug would bite):** `selectedResidueIndices`, `fixedPositions`, `nativeSequence`, `omit`, and `DesignResult.indices` all live in the **valid-projected** space (length `L = validResidues.count`), the same space 2b's `repackNowAwait()` already uses. The mapping from that space back to `editedSequence` / (chain, resi) goes through the valid mask, exactly as repack does. Unit tests pin this partition (§9).

---

## 7. Apply → rescore → (repack); Revert; Keep/Discard

1. **Snapshot for revert:** before scattering, `redesignSnapshot = editedSequence`.
2. **Apply (main):** scatter the region result into `editedSequence`; `editCount += <# positions actually changed>`; mark the changed residues' sidechains backbone-only; `repackDirty = true`.
3. **Rescore (off-main, `designToken`-guarded):** reuse 2b's backbone-based `score(.leaveOneOut)` over the working copy + edited sequence → recolor via the 2a `p.mpnn_conf` + `spectrum` path; refresh the propensity row.
4. **Repack (conditional):** if Auto-repack is on (or the user clicks the "needs repack" indicator), run 2b's existing **whole-structure** `repack(editedSequence)` and load it into `<obj>_design`.
5. **Revert redesign:** `editedSequence = redesignSnapshot` → rescore + (Auto-repack) repack. One level, scoped to the last batch. Because the snapshot is taken *after* any earlier manual edits, those edits survive the revert (success criterion 5). Revert is available until the next redesign or a Keep/Discard.
6. **Keep / Discard:** unchanged from 2b.

The redesign, rescore, and repack all run on the existing single serial `DispatchQueue`. A **separate `designToken`** (added alongside 2b's rescore/repack tokens) means a superseding redesign coalesces rapid clicks without cancelling an in-flight rescore or repack, and vice-versa.

---

## 8. Repack is whole-structure, not a region shortcut

`repack()` takes the full sequence and returns a full-structure PDB; the perf sweep established that repack wall-clock tracks **total L, not selection size** (`decodeSequence`/packer iterate all positions). So "live repack of a region" means: the region's changed identities get new sidechains via the **existing 2b whole-structure repack path** fed the batch-updated `editedSequence` — **no new repack code**. The UI copy must not imply "fast because I only selected a few residues"; the redesign+repack cost scales with the whole object.

---

## 9. Edge cases & errors

- **Selection spans multiple objects / non-focus atoms:** intersected down to the focus object; only its designable residues count.
- **Selection with zero designable residues** (all masked / incomplete backbone / non-polymer): hidden from the dropdown; if somehow chosen, Redesign is disabled with a "0 of N designable" note.
- **Palette emptied** (all pills inactive): Redesign disabled.
- **`design()` failure** (OOM / MLX / pack): surface the error in the strip; roll `editedSequence` back to `redesignSnapshot`; keep the session alive.
- **Mode exit / focus change mid-flow:** same teardown as an unkept 2b session (never leave a half-edited hidden original).
- **Region overlaps prior manual edits:** allowed — the redesign overwrites those positions (they were part of the free set) and the pre-batch snapshot still restores them on Revert.
- **Single-state vs. multi-state:** operates on the displayed state's backbone, consistent with 2a/2b; the working copy is single-state.

---

## 10. UI

- **Selection dropdown:** a SwiftUI `Menu`/`Picker` in the `DesignOverlayView`, populated from `list_design_selections`, refreshed on open, each row `name · N res`. Picking sets the region + enters region mode.
- **Pill row mode-switch:** driven by `regionModeActive` (a selection is chosen). Region mode hides propensity numbers and renders each pill as an active/inactive toggle bound to `paletteAllowed`.
- **Region strip highlight:** the chosen residues render read-only-highlighted in the existing two-row sequence strip.
- **Buttons:** `Redesign selection · N res` (disabled when no region, empty palette, or 0 designable), `Revert redesign` (enabled only when a `redesignSnapshot` exists), plus the unchanged 2b Auto-repack / needs-repack / compare / Keep / Discard controls.
- **"Redesigning region…"** progress affordance while the design job runs (reuses the scoring-spinner affordance); viewport stays interactive.
- All new state observed via the existing `@ObservedObject var controller: DesignController` (2a nested-observation fix). `DesignOverlayView` is split into small subviews to stay under the SwiftUI type-checker limit (2b already does this).

---

## 11. Testing

- **Pure-logic units** (`PyMOLViewerTests` macOS target, `#if RAYMOL_MPNN`, injected closures — no real MPNN/Metal): scatter of a region result into `editedSequence` touches only the region; fixed/free partition is the complement of `selectedResidueIndices`; `nativeSequence` = valid-projected `editedSequence`; `omit` derived from `paletteAllowed`; palette-empty guard; `redesignSnapshot`/revert restores pre-batch sequence and preserves earlier manual edits; `designToken` supersedes a rapid second redesign without cancelling a rescore/repack; region-mode trigger toggles on selection pick.
- **Real on-host inference** (gated `UnitTests_macOS_Inference` scheme): `design()` over a selection with the rest fixed returns a sequence differing from native **only** at the free positions; a toggled-off AA never appears at a designed position; repeated runs (fixed seed) are byte-identical.
- **Python** (`raymol_design`, symlink test recipe): `list_design_selections` filtering + counts; `selected_design_indices` maps a selection to the correct valid-projected indices for objects with masked/incomplete residues.
- **Functional (host, mac-vm-test):** create a selection → pick it in the dropdown → region highlights, pills become toggles → toggle off an AA → Redesign → region recolors + repacks, that AA absent → Revert restores → Keep/Discard.

---

## 12. File map

- `swiftui/PyMOLViewer/Shared/DesignController.swift` — `selectedResidueIndices`, `paletteAllowed`, `redesignSnapshot`, `regionModeActive`; actions `pickSelection(...)`, `redesignSelection()`, `revertRedesign()`, palette toggles; `designToken`; reuse of the off-main queue + rescore/repack path.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` (`DesignOverlayView`) — selection dropdown, pill mode-switch, region strip highlight, `Redesign selection` / `Revert redesign` buttons, "Redesigning region…".
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — injected `designRegion` closure (→ `model.design`) and the selection-listing / selection-mapping closures, all `#if RAYMOL_MPNN`.
- `modules/pymol/raymol_design.py` — additive helpers `list_design_selections`, `selected_design_indices`; region strip highlight relies on existing display helpers.

---

## 13. Non-goals (this slice)

Multiple candidate designs / temperature sampling / N-variants; per-position logit bias; a dedicated constraint panel beyond the palette toggles; multi-level undo; export flows beyond leaving the object in the scene; iOS/iPad; MAS.

## 14. Future slices (unchanged)

2d — iOS/iPad (drop the macOS SPM platform filter, iOS 17, L-cap / chunking for the ~2.4 GB peak). 2e — MAS build. "Predict" (structure prediction) remains a separate, deferred issue.
