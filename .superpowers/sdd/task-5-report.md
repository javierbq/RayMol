## Task 5 Report — Wire real edit closures on PyMOLEngine

### Status: DONE

### Commit
`15ae1f0a8` — `feat(design): wire real edit closures (working copy, mutate-display, repack, load) on PyMOLEngine (2b)`

### Production-injection mechanism
**Init parameters with defaults** (matching Phase-2a's pattern exactly). The 6 edit closures (`makeWorkingCopy`, `mutateDisplay`, `discard`, `compare`, `repack`, `loadRepacked`) were added as optional `nonisolated init` parameters on `DesignController` with the same no-op defaults previously hardcoded. This means all existing test call sites (`makeController()`) continue to compile without change; the production path (`PyMOLEngine.designController` lazy init) passes the real closures at construction time, with no reliance on the `#if DEBUG` inject hooks.

### Type-alias changes (required to support real implementations)
- `MutateDisplayFn`: changed from `(String, Int, Int)` to `(String, String, String, Int)` = `(obj, chain, resi, aa)`. The controller now resolves chain+resi from `lastSet[focusObject]` in `applyMutationState` before calling the closure, so the engine closure can pass them straight to Python without needing access to controller internals.
- `RepackFn`: changed from `([Int])` to `([MPNNModel.Residue], [Int])` = `(residues, seq)`. The controller captures `focusObject's validResidues` on the main actor in `repackNowAwait` before dispatching off-main, so the real closure (`model.repack(residues, sequence: seq)`) can run safely on the inference queue.
- `DesignEditingTests.swift` updated for both type changes (8 + 4 occurrences).

### Each closure's wiring
- **makeWorkingCopy(src)**: derives `dst = src + "_design"`, calls `runPython _rd.make_working_copy(src, dst)`, returns `dst`.
- **mutateDisplay(obj, chain, resi, aa)**: calls `runPython _rd.mutate_residue_display(obj, chain, resi, aa)` — Python helper alters `resn` then calls `set_residue_backbone_only`.
- **discard(dst)**: strips `"_design"` suffix to recover `src`, calls `runPython _rd.discard_working_copy(src, dst)`.
- **compare(on)**: reads `focusObject` via `MainActor.assumeIsolated` (compare is always called on @MainActor), calls `runPython _rd.set_compare(src, on)`.
- **repack(residues, seq)**: pure MLX call — `loadedMPNNModel().repack(residues, sequence: seq).pdb`. Runs off-main on the inference queue.
- **loadRepacked(obj, pdb)**: writes multi-line PDB string to `$TMPDIR/raymol_repack.pdb`, calls `runPython _rd.load_repacked(obj, open(path).read())` — same temp-file marshalling pattern as `applyColoring`.

### Python helper added
`mutate_residue_display(obj, chain, resi, aa_index)` in `modules/pymol/raymol_design.py`: maps MPNN index → 3-letter resname via new `_INDEX_TO_THREE` lookup dict, calls `cmd.alter(res_sel, "resn='<three>'")`, then `set_residue_backbone_only(...on=True)` to hide stale sidechain. Index 20 (X/masked) is a no-op.

### Build results
- **macOS**: BUILD SUCCEEDED.
- **iOS Swift-compile**: no Swift source errors; only signing failure (no development team in headless env) — no design/mlx leakage.

## Fix: mutate_display test + rebuild

### Changes (commit 358f868c3)

**testMutateResidueDisplay** added to `testing/tests/raymol/design_editing.py`:
- Loads ARG fragment, shows sticks, discovers chain/resi at runtime (build-dependent assignment).
- Calls `rd.mutate_residue_display('m', chain, resi, 9)` (MPNN index 9 = LEU) and asserts return `'DESIGN_MUTDISP:ok'`.
- Reads resulting `resn` via `cmd.get_model` (avoids name-shadowing from iterate variable `resn`); asserts `'LEU'`.
- Asserts stale sidechain sticks are hidden: `count_atoms('m and rep sticks and not name N+CA+C+O') == 0`.
- Asserts idx=20 (masked/X) returns a string containing `'noop'` (`'DESIGN_MUTDISP:noop'`).

**cmd.rebuild(res_sel)** added in `modules/pymol/raymol_design.py` `mutate_residue_display`, immediately after `cmd.alter(res_sel, "resn='<three>'")` and before `set_residue_backbone_only`. Scoped to the residue selection so label/representation state dependent on `resn` refreshes deterministically rather than waiting for the next user-triggered redraw.

**Invariant comment** added in `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` at the `discard` closure's ternary: `// dst is always src + "_design" (from makeWorkingCopy); the else-branch is unreachable in the normal path.`

### Results
- Python: 5 tests, all OK (including new `testMutateResidueDisplay`).
- macOS build: BUILD SUCCEEDED.
