# RayMol Design mode — point-mutation editing (Phase 2b of #217)

**Date:** 2026-07-23
**Issue:** RayMol #217 (interactive on-device design tool)
**Builds on:** Phase 2a — Design mode / confidence visualization + propensity inspector, merged to `master` (`bda2b25fc`, PR javierbq/RayMol#221). Spec: `docs/superpowers/specs/2026-07-21-raymol-design-mode-confidence-viz-design.md`.

## 0. Context & scope

Phase 2a shipped a read-only Design mode: focus an object → color its backbone by per-residue MPNN confidence, dim the rest, hover/pin a residue to see its 20-AA propensity pills (element-colored sidechain sticks on hover). This slice (**2b**) makes it **editable**: click a propensity pill to mutate that residue, on a non-destructive working copy, with live re-scoring and controllable sidechain repacking. This is the core of #217's "per-position AA editing with live repack."

**In scope:** single-residue point-mutation editing on the focus object. **Out of scope (later slices):** multi-residue region redesign (2c), live repack of a whole selection via `design()`, per-edit undo history, iOS/iPad (2d), MAS (2e).

## 1. Scope & success criteria

**Workflow deliverable:** In Design mode, with a focus object scored, the user hovers/pins a residue and **clicks one of its propensity pills** to set that residue to that amino acid. The first edit creates a working copy `<obj>_design`; the original hides (a **compare** toggle flips back). The confidence coloring **re-scores automatically** and recolors. Sidechain **repacking** is controlled separately (a toggle + a "needs repack" indicator). The user edits residue-by-residue, then **Keeps** or **Discards** the working copy. The original object is never modified.

**Success when:**
1. Clicking a pill mutates the corresponding residue on the working copy and the confidence coloring updates within the interaction (re-score is backbone-based, no repack required).
2. Repacking is decoupled: an **Auto-repack** toggle, and a **"needs repack"** indicator that lights when geometry is stale and repacks on click (showing "Repacking sidechains…").
3. A repacked working copy shows correct all-atom sidechains for the edited sequence; the original is untouched and restorable.
4. Runs off the main thread (viewport stays responsive; a superseded action is dropped by the job token).
5. Keep leaves the working copy as a normal object; Discard removes it and re-shows the original.
6. Ships in the macOS build; iOS unaffected; no regression to Phase 2a.

## 2. The workflow (user-facing, primary)

1. Enter Design mode (⌃D), focus an object → it's scored + colored (2a).
2. Hover or pin a residue → its 20 propensity pills are live.
3. **Click a pill** → that residue's identity becomes that AA on the working copy `<obj>_design` (created on the first edit; original `disable`d). The heatmap **re-scores + recolors immediately**.
4. The mutated residue's now-stale sidechain is shown **backbone-only** until repacked. The **"needs repack"** indicator lights (unless Auto-repack is on).
5. **Auto-repack ON** → step 3 also repacks right away ("Repacking sidechains…"). **OFF** → edits accumulate; click the **"needs repack"** indicator to repack the whole structure on demand; it clears when in sync.
6. **compare** toggles the original back into view to A/B against the edited copy.
7. **Keep** (leave `<obj>_design`; if the indicator is still dirty, offer to repack first) or **Discard** (delete `<obj>_design`, re-enable the original).

Strip while editing:
`2kpo_design · A/96 F→L · 3 edits · [Auto-repack ▢] [⟳ needs repack] [compare] [Keep] [Discard]`

## 3. Why rescore and repack are decoupled (design foundation)

ProteinMPNN scores a residue from the **backbone geometry + the sequence**, independent of sidechain atom placement. Therefore a mutation changes the score input via the *sequence* alone — **re-scoring needs no repack**, and can run automatically and cheaply on every edit. **Repacking** (placing the new all-atom sidechains) is a separate, slower geometry step whose only role is a correct 3-D view + a keepable structure — so it is user-controlled (toggle + on-demand indicator), not forced on every keystroke.

## 4. Edit session & working copy

- **Creation:** the first mutation runs `cmd.create <obj>_design, <obj>` (via `get_unused_name`), which inherits the source object's matrices → the copy is born superposed on the original; then `cmd.disable <obj>` so only the copy shows. No PyMOL undo is relied upon.
- **State (on `DesignController`):** `editing: Bool`, `workingObject: String?`, `editedSequence: [Int]` (starts = the focus object's native sequence), `editCount: Int`, `repackDirty: Bool`, `autoRepack: Bool` (**defaults OFF** — editing stays snappy; the user opts in), `isRepacking: Bool`.
- **Keep:** leave `<obj>_design` in the scene (if `repackDirty`, prompt/auto-repack so the kept structure's sidechains match its sequence). **Discard:** `cmd.delete <obj>_design` + `cmd.enable <obj>`; reset edit state.
- **Compare:** toggles `enable/disable` of the original alongside the working copy.

## 5. The mutate → rescore → repack cycle

Per pill click on residue *i* → AA `x`:
1. **On main:** `editedSequence[i] = x`; `editCount += 1`; mark residue *i* sidechain **backbone-only** in the view; set `repackDirty = true`.
2. **Rescore (auto, off-main serial queue, job-token guarded):** `score(.leaveOneOut)` over the working copy's backbone + `editedSequence` → recolor via the 2a coloring path (`p.mpnn_conf` + `spectrum`). Refresh the propensity row for the active residue. This reuses the Phase-2a `DesignController` scoring machinery, now fed the **edited** sequence (`editedSequence`) rather than the object's native one.
3. **Repack (conditional):** if `autoRepack` is on (or the user clicks the "needs repack" indicator): set `isRepacking = true` + show **"Repacking sidechains…"**; off-main `repack(editedSequence)` → all-atom PDB; on main, load it into `<obj>_design` (`cmd.read_pdbstr`/`load_coordset`), restore the confidence coloring, clear `repackDirty`. MPNNKit's `repack` *is* the mutation mechanism — it places every sidechain for the edited sequence; no PyMOL mutagenesis wizard is used.

Rescore and repack both run on the existing single serial `DispatchQueue` with the `jobToken`, so rapid pill-clicks are coalesced and a superseded action is discarded.

## 6. UI

- **Interactive pills:** the propensity pills (2a `DesignOverlayView`) become buttons — clicking one calls the mutate action for the active (hovered/pinned) residue. The pill matching the residue's *current edited* identity is the "current" highlight; the native identity may be marked distinctly (e.g. a dot) so divergence from wild-type is visible.
- **Strip controls (edit session):** `Auto-repack` toggle, a clickable **"needs repack"** indicator (dim when clean, highlighted + count when dirty), `compare` toggle, `Keep`, `Discard`, and an `<obj>_design · N edits` readout. All in the `#if RAYMOL_MPNN` `DesignOverlayView`, split into small subviews (type-checker limit).
- **"Repacking sidechains…"** overlay/label while `isRepacking` (viewport stays interactive). Reuses the existing scoring-spinner affordance.
- All new state observed via the existing `@ObservedObject var controller: DesignController` (Phase-2a nested-observation fix).

## 7. Edge cases & errors

- **Repack/score failure** (MLX/OOM/pack): surface the error in the strip; roll the working copy back to its pre-edit state for that action; keep the session alive.
- **Same-AA click:** no-op (no edit, no dirty).
- **Non-scored / masked / non-polymer residues:** not mutable (pills inactive).
- **GLY/PRO:** `repack` handles placement; a mutation to/from PRO or GLY is a normal sequence edit + repack (no special-casing beyond what MPNNKit does).
- **Multi-state objects:** editing operates on the displayed state's backbone (consistent with 2a's `(object,state,sequenceHash)` model); the working copy is single-state.
- **Focus change / mode exit mid-session:** treated like Discard unless Kept (never leave a half-edited hidden original); the 2a `onChange(designMode)` restore path is extended to also tear down an unkept edit session.

## 8. Non-goals (this slice)

Multi-residue region redesign / `design()` over a selection (2c); per-edit undo history (Discard-and-restart only); saving/exporting flows beyond leaving the object in the scene; iOS/iPad; MAS.

## 9. Testing

- **Pure-logic units** (existing `PyMOLViewerTests` macOS target, `#if RAYMOL_MPNN`): applying a mutation to `editedSequence`; working-copy naming; `repackDirty` set on edit / cleared on repack; `autoRepack` gating; job-token supersession of a rapid second edit; Keep/Discard state transitions. (Injected closures as in the 2a `DesignController` tests — no real MPNN/Metal.)
- **Real on-host cycle** (gated `UnitTests_macOS_Inference` scheme): mutate a residue → `repack(editedSequence)` returns all-atom coords differing at the mutated sidechain → `score` returns finite log-probs for the edited sequence.
- **Python** (`raymol_design`): the working-copy create/disable/enable + coordinate-load helpers, and the backbone-only display toggle, via the symlink test recipe.
- **Functional (host):** click a pill → recolor (no repack) → indicator dirty → click indicator → "Repacking sidechains…" → correct sidechains; Auto-repack on → repack per edit; compare; Keep; Discard restores the original.

## 10. File map

- `swiftui/PyMOLViewer/Shared/DesignController.swift` — edit-session state + the mutate/rescore/repack actions (reusing the off-main queue + job token); working-copy lifecycle; `autoRepack`/`repackDirty`.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` (`DesignOverlayView`) — interactive pills, edit-session strip controls, "Repacking sidechains…", compare/Keep/Discard.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — the injected edit closures (mutate/working-copy create/coord-load/backbone-only display), wired to `raymol_design` helpers via `runPython`.
- `modules/pymol/raymol_design.py` — additive helpers: create/enable/disable working copy, load repacked coords, backbone-only display for stale residues.
- `swiftui/PyMOLViewerTests/` — the unit + gated-inference tests above.
- No `project.yml` / dependency change expected (MPNNKit `repack`/`score` already available from Phase 2a).

## 11. Future slices

2c — region redesign (`design()` over a multi-residue selection, fixed rest, accept/reject); live repack of a region. 2d — iOS/iPad (drop the macOS SPM platform filter, iOS 17, L-cap). 2e — MAS build.
