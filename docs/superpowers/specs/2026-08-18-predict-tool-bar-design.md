# Predict tool bar — design

**Date:** 2026-08-18
**Branch:** `claude/protein-prediction-ui-10c4ae`
**Status:** approved design, ready for implementation plan

## Problem

Structure prediction (`cmd.predict`, backends Boltz-2 and Protenix, the
progress tray, size guard, weight fetching) is fully built, but the only way to
*start* a prediction is to type `cmd.predict(...)` in the console. There is no
UI. We want a simple, discoverable way to start prediction jobs from the app.

## Goal

A **Predict** tool, reached from the macOS Tools menu (alongside Move · Measure
· Design), that raises a docked bar under the alignment — the same layout as the
other interaction tools. The bar is a small form that composes and submits a
`cmd.predict` call, with an optional MSA step that runs `msa_search` to build
alignments for the chains the user selects.

The bar must let the user:

- provide the input as a **pasted sequence**, a **selection string**, or by
  **picking a loaded object** (all three are what `cmd.predict`'s `sequence`
  argument already accepts natively);
- choose the **model** (predictor) from a dropdown;
- toggle **Use MSA**, and when on, pick — from a **multi-select of the input's
  chains** — which chains need an alignment;
- set the **number of models** (`n_models`, 1–20).

Advanced knobs live behind a disclosure. macOS only for now (prediction is
compiled `#if os(macOS)`; there is no iOS predict backend yet).

## Non-goals

- iOS / iPad Predict bar (deferred; the whole predict backend is macOS-only).
- Any new MSA-*creation* UI beyond the chain multi-select. `msa_search` does the
  creation; the bar only chooses which chains to search for.
- A new progress surface. The existing progress tray (#291) and the inspector's
  alignment / MSA-search sections (#296/#298) already render fold and search
  progress; the bar shows only a compact one-line status.
- Paired MSAs for complexes. `msa_search` is deliberately one unpaired alignment
  per chain; the bar honors that (one search per selected chain).

## Background: how the pieces already work

RayMol has **no Python→Swift call path** — `PyMOLBridge.h` is one-directional.
Swift drives Python two ways, both already in use for prediction:

1. **Compose a command string** and run it (`PyMOLEngine.runCommand` /
   `runPython`). `cmd.predict` writes a request JSON, prints a `PREDICT:` marker
   that `pollFeedback()` scans, and `BoltzJobManager` / `ProtenixJobManager`
   pick it up. This is how a prediction is submitted today.
2. **Read results back via a tempfile-JSON + feedback marker.**
   `appkit_inspector.poll_panel()` writes `pymol_objpanel_<pid>.json` (objects,
   selections, `alignments`, `msa_searches`, `pending_jobs`, …) and prints
   `OBJPANEL:ready`; Swift reads the file. `DesignController` uses the same
   family of tempfile reads.

Relevant commands (all already shipped):

- `predict(predictor, sequence, name='', recycling_steps=3, diffusion_steps=200,
  seed=None, n_models=1, msa='', msa_depth=None)` — `sequence` accepts a literal
  one-letter string (chains separated by `/`), a loaded object name, or an atom
  selection. `n_models` is 1..`MAX_MODELS` (=20). `msa` is one `/`-separated slot
  per chain naming a loaded alignment; an empty slot folds that chain
  single-sequence. With no `msa`, each chain read from the session folds with
  whatever alignment is *attached* to that object+chain.
- `registry.available()` — sorted predictor ids for the model dropdown.
- `msa_search(sequence, name='', target='', chain='', server='', mode='env',
  refresh=0)` — MMseqs2 search on a ColabFold server for **one** chain (a complex
  is refused). Returns immediately with a search id; runs minutes in the
  background; **caches to disk** keyed on (sequence, server, mode); lands the
  alignment attached to `target`+`chain` (or unattached when `target` is empty,
  e.g. a literal sequence). Poll with `msa_status`, stop with `msa_cancel`.
- `PredictSizeGuard` / `ProtenixSizeGuard` — `decide(tokens:msaDepth:availableBytes:)
  -> .ok | .warn(...)` and `estimatedBytes(...)`, `formatted(bytes:)`,
  `maximumTokens` (900), `maximumMSADepth` (16384). Design's bar already uses the
  peer `DesignSizeGuard` for its inline "run anyway / cancel" confirm row.

Interaction-mode exclusivity is centralized: `PyMOLEngine.exitActiveInteractionMode()`
leaves whatever mode is active, and each `setXMode` setter coordinates so only
one of Move / Measure / Design is ever on (see the mode-exclusion-teardown
design, 2026-07-25). Each active mode raises its own on-canvas bar; the Tools
menu glyph swaps to the active mode's icon.

## Approach

Mirror the **Design** tool end to end. It is the closest existing analog — an
exclusive interaction mode with a docked bar under the alignment, a controller
that composes Python commands and reads tempfile JSON back, a size-guard confirm
row, an error banner, and a settings sheet for set-once controls.

Rejected alternative: a modal sheet launched from the Tools menu (like
`MovieBuilderSheet`). Less code, but a floating dialog is not a docked bar and
contradicts the requested layout.

## Components

### 1. Mode plumbing (`PyMOLEngine.swift`, `ContentView.swift`)

- New `@Published var predictMode: Bool = false` on `PyMOLEngine`, and
  `func setPredictMode(_ on: Bool)` that, when turning on, exits the other modes
  (Move / Measure / Design) exactly as `setDesignMode` does, and is itself
  exited by `exitActiveInteractionMode()` and by the other setters. Add the
  matching line to `exitActiveInteractionMode()`.
- `activeInteractionTool` (ContentView) gains a Predict case →
  `("Predict", <macIcon>, <railIcon>)`; proposed glyph `atom` (fallback
  `sparkles`). This drives the Tools-menu label/glyph swap.
- `interactionToolItems` gains a **Predict** button (toggle + `checkmark` when
  active), wrapped `#if os(macOS)`. `toolsMenuHelp` mentions it on macOS.
- Docking: add `else if engine.predictMode { predictBar }` at the same
  alignment-strip insertion points the `designModeBar` uses (the macOS layout
  branch is the one that matters for v1). `predictBar` is a thin
  `@ViewBuilder` wrapper that instantiates `PredictBar(...)`, matching how
  `designModeBar` wraps `DesignOverlayView`.

### 2. `PredictController: ObservableObject` (`Shared/PredictController.swift`, new)

Owns form state and the run orchestration. All Python is issued as composed
command strings; all reads come from tempfile JSON.

**State (published):**

- `inputText: String` — the raw input (sequence / selection / object name).
- `chains: [Chain]` where `Chain = (id: String, length: Int)` — resolved from
  the input; drives the MSA multi-select and the token/size estimate.
- `resolveError: String?` — why the current input does not resolve.
- `availablePredictors: [String]`, `predictor: String` (selected).
- `useMSA: Bool`, `msaChains: Set<String>` (chain ids to search for).
- `nModels: Int` (1...20).
- Advanced: `recyclingSteps`, `diffusionSteps`, `seed: Int?`, `msaDepth: Int?`,
  `msaMode: String` (env/all/env-nofilter/nofilter), `resultName: String`,
  `server: String` (blank = the `msa_server` setting / default).
- `phase: Phase` — `.idle | .searching(remaining:Int) | .predicting | .error(String)`.
- `pendingSizeWarning` — for the inline confirm row (mirrors Design).

**Behavior:**

- `refresh()` — on entering the mode: trigger `appkit_predict.emit(input)`
  (see §4) and read predictors + objects. Objects come from the existing
  object-panel poll; predictors from the predict helper JSON.
- `resolveInput()` — debounced on `inputText` change: run `appkit_predict.emit`,
  read back `chains` / `resolveError`. Empty input clears chains.
- `run()` — the orchestration below.
- `cancel()` — `msa_cancel` any searches this run started, and `predict_cancel`
  a submitted job.

### 3. `PredictBar` (`Shared/PredictBar.swift`, new)

The docked form. Themed like `DesignOverlayView` (panel background, accent
tint). Rows, top to bottom:

1. **Error / status banner** (reuses the Design error-banner styling) and the
   **size-guard confirm row** (`pendingSizeWarning`, orange, inline "Run anyway /
   Cancel" — copied from `DesignCompactPanel.sizeWarningRow`).
2. **Input row:** a `TextField` (paste a sequence or a selection) + an **Object**
   `Menu` listing loaded objects that sets `inputText` to the chosen name +
   `chevron`. A small caption shows the resolved chains (e.g. "A · 129 · B · 44")
   or the resolve error.
3. **Model** `Picker` (`availablePredictors`) · **N models** stepper (1–20) ·
   **Use MSA** `Toggle`.
4. **When `useMSA`:** a multi-select of `chains` (a `Menu` of toggle rows, or a
   row of selectable chips) writing `msaChains`; plus a one-line privacy note
   naming the server when it is public.
5. **Advanced** `DisclosureGroup`: recycling steps, diffusion steps, seed,
   msa_depth, MSA mode, result name, server.
6. **Run** button (disabled while `chains` is empty, no predictor, or a run is in
   flight) + a close (`xmark`) that calls `engine.setPredictMode(false)`.

Set-once controls may alternatively live in a `PredictSettingsSheet` (like
`DesignSettingsSheet`); the disclosure is the default to keep everything on the
bar. Decide during implementation based on row width.

### 4. Python helper `modules/pymol/appkit_predict.py` (new)

One function, same tempfile-JSON pattern as `poll_panel()`:

```
emit(input_str) ->  writes pymol_predict_<pid>.json:
    { "predictors": [ids...],
      "chains": [ {"id": "A", "length": 129}, ... ],
      "error": "<message or null>" }
    then prints "PREDICT_FORM:ready"
```

- `predictors` from `registry.available()` (input-independent; included every
  call for simplicity).
- `chains` by resolving `input_str` through the *same* resolver `predict` uses —
  `resolve_input` → `parse_spec` → `spec.chains` (list of `(chain_id, sequence)`)
  — so what the bar shows is exactly what would be folded. Empty/whitespace input
  yields `chains: []`, `error: null`.
- Any resolve failure is caught and returned as `error` (never raises; a throw
  would leave a stale/zero-byte file, per the `poll_panel` rationale).

Swift routes the `PREDICT_FORM:` marker in `pollFeedback()` (next to
`OBJPANEL:`) to have `PredictController` read the file. Alignments and running
searches are **not** duplicated here — they are already in the object-panel poll
payload, which `PredictController` reads for MSA status.

## Data flow: the Run orchestration

Input → `appkit_predict.emit` → `chains` shown in the bar.

On **Run**, size-guard first: estimate tokens from `sum(chain.length)`, call the
selected backend's guard (`PredictSizeGuard` for boltz2, `ProtenixSizeGuard` for
protenix); on `.warn` show the inline confirm row and wait; on a hard-max
overflow, block with a message. Then:

**No MSA** — compose and submit immediately:

```
predict <predictor>, <input>, n_models=<N>
    [, recycling_steps=<r>][, diffusion_steps=<d>][, seed=<s>]
    [, msa_depth=<md>][, name=<name>]
```

`phase = .predicting`; the tray takes over. Done.

**With MSA** — for each id in `msaChains`:

- **Input is an object or selection** (there is a target to attach to): start
  `msa_search <input> and chain <id>, target=<obj>, chain=<id>[, mode=<m>]
  [, server=<srv>]`. When the search lands, the alignment is attached to
  `obj`+`id`, and a later `predict <predictor>, <input>` **auto-uses** it (no
  `msa=` needed).
- **Input is a literal pasted sequence** (no target): start `msa_search
  <that chain's subsequence>, name=<generated>[, mode][, server]`; capture the
  landed alignment's name to build a `/`-separated `msa=` slot string (empty slot
  for chains not selected).

`phase = .searching(remaining:)`. `PredictController` watches the object-panel
poll payload (`alignments`, `msa_searches`): as each needed alignment lands,
decrement `remaining`; when all needed alignments are present, **auto-submit the
`predict`** (with the `msa=` string in the literal-sequence case). If any search
reports an error, set `phase = .error(...)` and do **not** predict.

Because `msa_search` caches to disk, a chain that was already searched (this
session or a prior one) lands instantly, so re-running is cheap. A chain that
already has an attached alignment can skip the search entirely (object/selection
path) — the controller checks the poll's `alignments` map before starting one.

Submitted predictions flow through the existing
`BoltzJobManager`/`ProtenixJobManager` → placeholder object + progress tray →
result loaded as states 1..N of the named object.

## Error handling

- **Unresolvable input / no chains** → caption shows `resolveError`; Run
  disabled.
- **No predictors registered** → model picker shows an empty/"none" state; Run
  disabled.
- **Oversize** → inline confirm row (`.warn`) or a hard block above the guard's
  max, reusing the size-guard copy/formatting.
- **MSA on, public server** → a one-line "the sequence is sent to `<server>`"
  note in the bar. Clicking Run is the explicit consent; `msa_search`'s own
  first-use public-server warning still prints to the console.
- **Search failure** → `phase = .error`, predict blocked, detail also visible in
  the inspector's MSA-search section.
- **Fold failure** → surfaced by the existing tray's retained terminal record;
  the bar returns to `.idle`.

## Privacy / safety

`msa_search` sends the query sequence to a third-party ColabFold server by
default. This is user-initiated (they check Use MSA and click Run) and already
warned by the command. The bar makes the destination visible before Run. No new
outbound path is introduced; the default server and `msa_server` setting are
unchanged.

## Testing

**Unit** (`swiftui/PyMOLViewerTests/`, following the existing appkit/headless
harness with a `FakeCmd`):

- `PredictController` command composition: input × predictor × n_models ×
  advanced → exact `predict ...` string; `msaChains` × object-input →
  `msa_search ...` strings and the search-then-predict sequencing;
  literal-sequence input → correct `msa=` slot string.
- The state machine: `.searching(remaining:)` decrements as alignments land in a
  fed poll payload and auto-submits predict only when all are present; a fed
  search error blocks predict.
- `appkit_predict.emit` parsing: predictors list, chains for a monomer / a `/`
  multimer / an object / a bad input (error, no throw).

**Functional** (mac-vm-test, per project workflow):

- Tools → Predict raises the bar under the alignment; the Tools glyph swaps.
- Paste a monomer sequence → chains caption shows one chain → pick a model → set
  N=2 → Run → a prediction placeholder + tray card appear.
- Fetch an object, Predict it, Use MSA, select chain A, Run → an `msa_search`
  card appears, and once it lands a predict job follows automatically.
- Esc / the other Tools items exit Predict mode (exclusivity).

Build via the two-stage macOS path (core, then xcodebuild) per project memory;
name the dev build with a suffix.

## Files touched

- `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `predictMode`,
  `setPredictMode`, `exitActiveInteractionMode`, `PREDICT_FORM:` routing in
  `pollFeedback`.
- `swiftui/PyMOLViewer/Shared/ContentView.swift` — Predict in
  `interactionToolItems`, `activeInteractionTool`, `toolsMenuHelp`, and the
  `predictBar` docking slots.
- `swiftui/PyMOLViewer/Shared/PredictController.swift` — new.
- `swiftui/PyMOLViewer/Shared/PredictBar.swift` — new (bar + optional
  `PredictSettingsSheet`).
- `modules/pymol/appkit_predict.py` — new helper.
- `swiftui/PyMOLViewerTests/PredictControllerTests.swift` (+ a Python test for
  `appkit_predict`) — new.

## Open implementation choices (decide while building, not blocking)

- Advanced knobs as a `DisclosureGroup` on the bar vs. a `PredictSettingsSheet`.
- Predict icon (`atom` vs `sparkles`).
- Whether to also list running `msa_searches` inline in the bar or rely solely on
  the inspector/tray (default: rely on existing surfaces + the one-line status).
