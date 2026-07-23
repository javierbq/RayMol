# RayMol Design mode — confidence visualization (Phase 2a of #217)

**Date:** 2026-07-21
**Issue:** RayMol #217 (interactive on-device design tool)
**Depends on:** Phase 1 — MPNNKit `score()`/`design()`/`repack()` API, merged to `main` in
`javierbq/proteinmpnn-mlx` (see that repo's `docs/superpowers/specs/2026-07-20-mpnnkit-interactive-design-api-design.md`).

## 0. Context & decomposition

Phase 1 shipped the headless MPNNKit inference primitives. Phase 2 is the RayMol viewer
integration. It is too large for one spec, so it is decomposed into slices; **this spec is the
first slice (2a): a read-only confidence-visualization mode.** It deliberately stands up the entire
integration spine — the SPM dependency on MPNNKit, off-main inference, selection→residue mapping,
per-residue coloring, the legend, and score-result caching — with the smallest possible interaction
surface, so the risky infrastructure is proven before interactive editing is built on top.

Later slices (not in scope here): per-position amino-acid editing, region redesign, live repack,
new-object-per-result management, iOS/iPad support, and a Mac App Store build. See §11.

## 1. Scope & success criteria

Deliver a **Design mode** — a peer of the existing Move and Measure modes (not a panel or tab).

Behaviour:
- Entering the mode lets the user **pick a focus object**. The focus object is colored by
  per-residue MPNN confidence; **every other object becomes semitransparent gray.**
- **Clicking another object** in the viewport makes it the focus (colored); the previous focus and
  all others re-gray.
- A mode control strip offers a **native-fit ⇄ certainty** toggle and a **legend**.
- **Exiting the mode restores the pre-mode colors and transparency of every object exactly.**
- Computed scores are **cached per object** and reused across mode/object switches; a cache entry is
  valid until that object's sequence (or displayed state) changes.

Strictly **read-only**: no sequence or coordinate changes; coloring and transparency only.

**Success when:**
1. Scoring a loaded structure colors it consistently with MPNNKit's already-verified outputs.
2. The run is off the main thread — the viewport stays interactive during inference (seconds-scale).
3. Toggling native-fit/certainty recolors the focus object instantly from cache (no recompute).
4. Switching focus between already-scored objects is instant (cache hit).
5. Exiting the mode returns every object to its exact pre-mode color + transparency.
6. Ships in the notarized macOS DMG; the iOS build is unaffected (no min-OS bump, no new deps).
7. No regressions to existing modes/features.

## 2. Prerequisite infrastructure

### 2.1 Extract MPNNKit to its own repo
MPNNKit currently lives in a subdirectory of `proteinmpnn-ios`, so an SPM **git-URL** dependency
cannot resolve it (SPM requires `Package.swift` at the repo root). Extract the package into its own
root-level repo **`proteinmpnn-mlx`** (`Package.swift` at root; `Sources/`, `Tests/`, and the
`.mpnnpack` build under it). `proteinmpnn-ios` remains the Python oracle / `port/` / dev home. Tag
the new repo `v0.1.0` and depend on that tag.

### 2.2 Wire the dependency into RayMol (`swiftui/project.yml`)
- Add `proteinmpnn-mlx` to the top-level `packages:` block (git URL, pinned `from:`/exact), and a
  target `dependencies:` entry — **with a `platforms: [macOS]` filter, exactly like Sparkle**
  (`project.yml:19-23`, `393-399`). The filter keeps mlx-swift out of the iOS target, so **iOS
  deployment target stays 16, with no `.so` framework-wrapping and no simulator exposure this slice.**
- Place the entry **outside** the `RAYMOL_SPARKLE_BEGIN/END` markers so `archive_appstore.sh`'s
  `sed`-strip does not remove it from the (future) MAS build.
- Introduce a new compile gate **`RAYMOL_MPNN`** following the `RayMolBuild` enum pattern
  (`ContentView.swift:18-38`); enabled on macOS, compiled out on iOS. Do **not** reuse
  `RAYMOL_MAS_RESTRICTED`.
- Because `xcodegen` is re-run at release time by `make_dmg.sh` (~line 109) and `archive_appstore.sh`
  (27/35), **all** of this must live in `project.yml`, never the generated `.pbxproj`.

### 2.3 Toolchain / min-OS
mlx-swift needs **Xcode 16 / Swift 6** and **macOS 14**. Bump `xcodeVersion` and `SWIFT_VERSION`
(`project.yml:26-27`) and the macOS `deploymentTarget` 13 → 14 (`project.yml:4-7`). iOS stays 16
(the platform filter means the iOS target never links mlx).

### 2.4 Weights
`MPNN.mpnnpack` is ~24 MB (design 10 MB + packer 14 MB safetensors + small json/geometry). Bundle it
directly into the macOS app Resources as a folder reference (like `1ubq.cif`), or follow the
fetch-script + gitignored-dir + `postBuildScript` copy pattern used for embedded Python
(`project.yml:308-337`). `MPNNPack.swift`'s loader reads it from `Bundle.main`.

### 2.5 Signing
`make_dmg.sh`'s deepest-first nested-Mach-O signer (`:194-246`) must sign any `.metallib`/dylibs
mlx-swift ships; the DeveloperID entitlements already set `disable-library-validation`. Verify a
clean notarize+staple. MAS is deferred (§11).

## 3. Runtime architecture — the inference path

MPNN calls touch **MLX/Metal only, not the PyMOL GIL**, so they follow the proven **MovieExporter**
thread-split (`MovieExportSheet.swift:130-167`), *not* `runHeavy` (which runs on-main and would
freeze the UI, `PyMOLEngine.swift:861`) and *not* the MCP/copilot path (30 s / 120 s timeouts).

A new **`DesignController`** (`ObservableObject`) owns the flow:
1. **On main:** read the focus object's polymer guide residues + backbone N/CA/C/O coordinates via
   the bridge; build `[MPNNModel.Residue]` **plus a parallel `index → (chain, resi-string)` table**
   for write-back. (Selection/enumeration per §5.3.)
2. **Off main (a dedicated serial `DispatchQueue`):** run `score(.leaveOneOut)` → `MLX.eval`. One job
   at a time (the ~2.4 GB peak forbids concurrent inference); a monotonically increasing **job token**
   causes a superseded result to be discarded.
3. **Back on main (`DispatchQueue.main.async`):** write per-residue values into `p.mpnn_conf`
   (`cmd.alter`) and recolor (`spectrum`), then update the legend domain. All core mutation goes
   through `PyMOLEngine.runCommand` (`PyMOLEngine.swift:776`).

The `MPNNModel` (weights) is **loaded once and kept resident** on the controller (first focus/first
score); a per-call reload would compound the memory peak. The viewport stays live throughout (we do
**not** set `exportRenderActive`). Cancellation is cooperative between calls — a single `eval` is
atomic and cannot be interrupted.

## 4. Focus & coloring model

- The **focus object** is the single object colored by per-residue score. Every other object is
  dimmed to semitransparent gray.
- **Two switchable color meanings**, both derived from one `score(.leaveOneOut)` result:
  - **Native-fit** = `currentAALogProb[i]` — the log-prob of the current residue given its context.
    Low = the model dislikes the native residue there.
  - **Certainty** = negative Shannon entropy of the per-position distribution `exp(logProbs[i])`
    (higher = more peaked = more certain), independent of the native identity — how decisively the
    model would pick some residue there. (Max-probability is a simpler substitute if entropy proves
    noisy in practice, but the spec commits to negative entropy.)
  A segmented control in the mode strip switches which drives the coloring; toggling recolors from
  the cached arrays and rescales the legend — no recompute.
- Coloring writes a per-atom custom property `p.mpnn_conf` on the focus object's polymer and applies
  `spectrum p.mpnn_conf, <palette>, <focus object>` (the Python `spectrumany` path handles custom
  properties; the C fast path does not — `viewing.py:2060`). Normalization: a fixed, interpretable
  domain chosen in Swift per color-meaning (not `spectrum`'s auto min/max), so the legend is stable.
- **Legend:** a **SwiftUI overlay** (gradient bar + min/max/unit) in the mode strip. The native
  `ObjectGadgetRamp` is effectively dead under the Metal renderer (`useProgram` is a stub,
  `RendererMetal.mm:3402`) and must not be relied on.
- **Dim style (default):** non-focus objects colored gray + ~0.7 transparency across
  cartoon/stick/surface/sphere reps.

## 5. Interaction & mode plumbing

### 5.1 Mode registration
Add `designMode` state to `PyMOLEngine` (mirroring `measureMode`, `PyMOLEngine.swift:130-136`),
routed through a `setDesignMode` that clears `interactionMode`/`measureMode` — reusing the manual
**mutual-exclusion** pattern in `setInteractionMode`/`setMeasureMode` (`:1929-1972`).

### 5.2 Entry points & control strip
- A macOS toolbar item + a `CommandMenu` shortcut, peers of Move/Measure (`ContentView.swift:2558-2615`,
  `PyMOLApp.swift:127-222`).
- A **contextual overlay** modeled on `moveOverlay`/`measureOverlay` (`ContentView.swift:2859-2962`):
  focus-object name, the native-fit/certainty toggle, the legend, and a spinner during compute. This
  is the mode's floating control strip — **not** a panel/tab. (Split into small computed properties
  to stay under the SwiftUI type-checker limit.)

### 5.3 Focus selection & click-to-refocus
- Reuse the existing viewport pick (`longPressPick`/`hoverPreview`, `PyMOLEngine.swift:2187-2247`,
  yielding a `LongPressHit` with obj/chain/resi). In design mode a **click** (no drag) picks the
  object under the cursor and refocuses; a **drag** still orbits — using the Move-mode tap-vs-drag
  dead-zone (`moveDragSlop`) so a shaky click is not misread as an orbit.
- **On enter:** if exactly one scorable object is enabled, auto-focus it; otherwise show a
  "click an object to design" hint until the first pick.
- The residue enumeration for `[Residue]` uses the guide-atom sequence exactly as the sequence panel
  does (`appkit_sequence.py`): `iterate '(<obj>) and polymer and guide'` for the canonical
  chain-grouped, ascending, gap-free order, then backbone `N+CA+C+O` coords per residue; chain
  strings map to ints in first-seen order; the `resi`-string (with insertion code) is retained in the
  index table.

## 6. Visual-state save/restore — the "exact restore" invariant

- **On enter:** snapshot every object's per-atom colors and the transparency settings the mode
  touches. Mechanism: stash each atom's original color in a scratch property (e.g.
  `p._design_savedcolor`) and record the per-object transparency setting values. This snapshot is the
  single baseline source of truth.
- **Focus switches always restyle from the baseline** (previous focus → gray, new focus → score), so
  repeated switching never drifts or compounds transparency/color.
- **On exit** (or switching to another mode): reapply the baseline verbatim (colors + transparency),
  then delete the scratch property. Every object returns exactly to its pre-mode appearance.
- The baseline is independent of the score cache (§7): clearing/rebuilding scores never affects
  restore correctness.

## 7. Score cache

- `DesignController` holds a cache keyed by **`(objectName, displayedState, sequenceHash)`** →
  `{ nativeFit: [Float], certainty: [Float], residueIndexTable }`.
- `sequenceHash` = a hash of the object's guide-residue `resn` list in order (cheap; detects sequence
  edits and reloads). `displayedState` is included because multi-state/NMR/trajectory objects share a
  sequence but differ in coordinates per state.
- **On focus:** compute the key → **hit = instant recolor from cached arrays; miss = score off-main
  (§3), then store.**
- **Invalidation:** an entry is dropped when its object's `sequenceHash` or displayed state changes,
  or the object is deleted. The cache **persists across mode enter/exit and focus switches** for the
  session lifetime.

## 8. Edge cases & error handling

- **Missing backbone atoms** (terminal/incomplete/altloc residues lacking N/CA/C/O): mask those
  residues out of the `[Residue]` array, keep the index table aligned, color them neutrally and
  exclude them from the legend domain — never feed broken geometry to MPNN.
- **Non-polymer** (ligands/ions/waters): excluded from scoring. In the focus object they remain at
  baseline color (not dimmed); non-focus objects are fully dimmed.
- **Multi-state / NMR / trajectory:** score the currently displayed state's coordinates; the state is
  part of the cache key.
- **Insertion codes / empty chain IDs:** the index table keeps the full `resi`-string identity
  (never collapse `100`/`100A`); an empty chain maps to a valid MPNN chain int; the whole object is
  scored as one multi-chain complex (`chainLabels`).
- **Failures:** missing/corrupt pack, or an MLX/OOM error → surfaced in the mode overlay; that object
  is left at baseline (un-dimmed); never a half-colored or stuck state.
- **Object deleted or changed while focused:** drop the cache entry; if the focus object vanishes,
  clear focus and no-op gracefully.

## 9. Testing

- MPNNKit inference is already unit-tested in its own repo (21/21 + oracle parity) — not re-tested
  here.
- **RayMol pure-logic unit tests** via the existing `appkit_*` headless harness + `FakeCmd` stubs (no
  Metal required): the selection→`[Residue]` builder (guide enumeration, backbone extraction, chain
  mapping, missing-atom masking), `sequenceHash`, cache hit/miss/invalidation, and the
  score→color normalization.
- **Save/restore regression guard:** snapshot → mutate → restore reissues the exact captured colors
  and transparency (asserted at the command level with a recording stub).
- **Functional:** build macOS and drive it (mac-vm-test / MCP live-capture) for the mode UX — enter
  dims the others, focus colors, click-refocus works, the toggle recolors, exit restores exactly.
  Because the VM's paravirtual GPU will not run mlx reliably, the **inference-in-the-loop** check runs
  on the **host**; the mode UX (dim/refocus/restore) is exercised with a precomputed/stubbed score so
  it does not depend on the GPU.

## 10. Non-goals (this slice)

No per-position AA editing, region redesign, repack, or result objects; no iOS/iPad (macOS-only via
the platform filter); no copilot/MCP scoring tool; no per-chain/selection scoping (whole object); MAS
build deferred (DMG channel first); no requirement that `p.mpnn_conf` persist across session
save/load.

## 11. Future slices (recorded, not in scope)

- **2b — Interactive editing:** per-position AA popover (hover on desktop, tap on touch) driving
  `design()` with fixed positions / bias / omit; new superposed result objects with explicit
  Delete/Discard (undo does not cover object creation — never mutate the input in place).
- **2c — Region redesign + live repack:** selection-as-design-mask; `repack()` side chains; result
  objects.
- **2d — iOS/iPad:** drop the macOS platform filter, bump iOS to 17, framework-wrap, add an L-cap +
  memory-pressure guard (the ~2.4 GB peak), on-device validation.
- **2e — Mac App Store build:** verify mlx under the MAS sandbox (no `disable-library-validation`).

## 12. File map (RayMol)

- `swiftui/project.yml` — package dep (macOS-filtered), `RAYMOL_MPNN` gate, toolchain/min-OS bump,
  weights bundling.
- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `designMode` state + `setDesignMode`
  mutual-exclusion; the on-main residue/coord read helper; `runCommand` write-back.
- `swiftui/PyMOLViewer/Shared/DesignController.swift` *(new)* — model lifecycle, serial inference
  queue, job token, score cache, save/restore baseline, focus state, color-meaning.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` — `designOverlay` control strip + legend;
  toolbar/menu entry; click-to-focus wiring; mutual-exclusion with move/measure overlays.
- `swiftui/PyMOLViewer/Shared/GizmoOverlay.swift` — extend `InteractionMode` if design is modeled as
  an interaction mode.
- `swiftui/PyMOLViewer/Shared/PyMOLApp.swift` — `CommandMenu` shortcut.
- macOS Resources — `MPNN.mpnnpack`.
- Tests — RayMol-side pure-logic + save/restore unit tests (headless harness).
</content>
