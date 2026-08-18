# Prediction Progress Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a running structure prediction an always-visible, honest progress card in a stacked scrollable tray shared with weight downloads, and make a failed prediction say why.

**Architecture:** A predictor declares its pipeline as ordered `(phase, start, end)` bands; `compose_progress` folds a job's per-phase `fraction` into one monotone 0–1 plus a `moving` flag, where a zero-width band means "started, cannot say how far in" and renders as an indeterminate bar. The record rides the object panel's existing 500 ms tempfile payload into a new `@Published` array on `PyMOLEngine`, which a new `ProgressTray` renders alongside the weight-download card. Pull, not push: there is no Python→Swift call path, and the poll already runs ungated.

**Tech Stack:** Python 3 (no type hints, `%`-formatting, `#:` attribute comments), Swift 6 / SwiftUI, XCTest, PyMOL's `testing.PyMOLTestCase` runner, xcodegen.

**Spec:** [docs/superpowers/specs/2026-08-14-prediction-progress-design.md](../specs/2026-08-14-prediction-progress-design.md)

## Scope

This plan covers **increments 0–2** of the spec. It ends with a working tray showing live prediction progress, per-card Cancel, and persistent error cards.

**Increment 3 (measured diffusion progress) is deliberately excluded.** It requires tagging `javierbq/boltz-mlx` v0.1.2, which is spec open question 1 and undecided. It gets its own plan once that is answered. Nothing in this plan blocks it: `boltz2.py`'s table already declares the `trunk` and `diffusion` bands, so increment 3 is a Swift-side change with no Python edit.

## Global Constraints

- **Python style in `modules/pymol/`:** no type hints anywhere; old-style `%` formatting with a tuple, never f-strings or `.format()`; `#:` (single hash-colon) for attribute comments, never `##:`; intra-package imports are explicit relative one level (`from .errors import ...`).
- **`_self=cmd` MUST be the last parameter** of every `predicting.py` command function. `pymol2/cmd2.py:93-118` inspects the argspec and injects the instance by that name; moving or omitting it breaks the `pymol2` API.
- **`quiet=0` is the command-line default.** `parsing.py` sets it for any command-line invocation whose argspec contains `quiet`, while the Python API defaults to `quiet=1`. Every message-emitting branch must be exercised at `quiet=0` in tests.
- **The 500 ms poll path must never raise.** `poll_panel`'s single outer `except` writes **no file at all**, so a throw freezes the whole object panel on a stale list.
- **The poll must stay O(pending objects), never O(jobs) or O(objects).** One status-file read per pending object per tick. `n_models` can be 20.
- **Do not delete a non-empty object.** `discard_pending` deletes only when `count_atoms(name) == 0`.
- **`_PENDING` values are lists, not scalars.** `register_pending` appends; `deliver_result`'s `finally` pops exactly one id and removes the key only when the list empties.
- **New Swift struct fields need defaults** if the struct has memberwise initializers in use — `ObjectEntry`'s first five fields have no defaults and every field added since does.
- **`xcodebuild` requires `-skipPackagePluginValidation -skipMacroValidation`** or it fails at exit 65 on mlx-swift's plugin trust gate before compiling anything.
- **No CI compiles Swift, and none compiles iOS.** Hand-compile both slices before merge (#174, #226, #238).
- **The engine's command surface is `runCommand(_ command: String)` and `runPython(_ code: String)`.** There is no `runProgressCommand`. Overlay actions go through `runCommand` so they echo in the console.

## Prerequisites (run once before Task 1)

Build the shadow `PYTHONPATH` the Python tests need. The repo's `.venv` pymol is a broken namespace package; the naive `pymol -ckqy` will import Homebrew's upstream pymol and silently test the wrong code.

```bash
SHADOW=/tmp/raymol-shadow
WT=/Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211
HB=/opt/homebrew/lib/python3.14/site-packages/pymol
rm -rf "$SHADOW"; mkdir -p "$SHADOW/pymol"
for f in "$WT/modules/pymol"/*; do ln -sfn "$f" "$SHADOW/pymol/$(basename "$f")"; done
for f in "$HB"/*; do b=$(basename "$f"); [ -e "$SHADOW/pymol/$b" ] || ln -sfn "$(readlink -f "$f")" "$SHADOW/pymol/$b"; done
for p in raymol_mcp chempy pymol2 web; do ln -sfn "$WT/modules/$p" "$SHADOW/$p"; done
```

**The Python test command used by every task below** (verified 2026-08-14: 137 passed, 0 failed on a clean tree). `PYMOL_DATA` is not optional — without it `cmd.fragment(...)` dies with `unable to load fragment 'ala'`, which reads exactly like a real regression:

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211 && \
PYMOL_DATA="$PWD/data" PYTHONPATH=/tmp/raymol-shadow /opt/homebrew/bin/pymol \
  -ckqy testing/testing.py --run testing/tests/predict
```

Always run the **whole** `testing/tests/predict` directory, never a single file: the files share one interpreter and leak global state.

**The Swift test command:**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && \
xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30
```

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `swiftui/PyMOLViewer/Shared/BoltzJobManager.swift` | one `settle` helper that writes the terminal status **then** discards the placeholder | 1 |
| `swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift` | pins the settle ordering | 1 |
| `modules/pymol/predictors/base.py` | `compose_progress` (mechanism), `Predictor.progress_phases = ()`, `Predictor.progress()` | 2, 3 |
| `modules/pymol/predictors/boltz2.py` | boltz2's own band table | 3 |
| `modules/pymol/predictors/_template.py` | the copy-me declaration | 3 |
| `docs/predictors.md` | "declare your phases or your users get a spinner" | 3 |
| `modules/pymol/predicting.py` | `_TRACK`, `pending_info`, `pending_detail` as formatter, `predict_cancel` by object, `_RECENT`, `predict_dismiss` | 4, 6, 10, 11 |
| `modules/pymol/appkit_inspector.py` | the `pending_jobs` payload key | 5 |
| `modules/pymol/api.py`, `keywords.py`, `completing.py` | the 3-file wiring for `predict_dismiss` | 11 |
| `testing/tests/predict/predict_progress.py` | every Python assertion in this plan | 2–6, 10, 11 |
| `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` | `PredictionJobState` + `PanelPayload.pending_jobs` decode | 7 |
| `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` | `@Published var predictionJobs` | 7 |
| `swiftui/PyMOLViewerTests/PendingJobTests.swift` | verbatim-payload decoder tests + item mapping | 7, 8 |
| `swiftui/PyMOLViewer/Shared/ProgressTray.swift` | **new** — `ProgressItem`, `ProgressCard`, `ProgressTray` | 8, 12 |
| `swiftui/PyMOLViewer/Shared/ContentView.swift` | rewire `busyOverlay`; delete `WeightDownloadOverlay` | 9 |

---

## Task 1: Write the terminal status before discarding the placeholder

Six bad-exit paths record a failure *after* deleting `_PENDING[name]`, the map every progress view reads. Nothing downstream in this plan can show an error until this is fixed. `discardPlaceholder` is `private static` and dispatches through `PyMOLEngine.shared`, so it is invisible to XCTest — the fix therefore introduces one `settle` helper with a DEBUG tap, matching the repo's existing `pythonTap` seam convention.

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/BoltzJobManager.swift:159-187`, `:266-378`
- Test: `swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift`

**Interfaces:**
- Produces: `BoltzJobManager.settle(_ request: Request, _ status: Status, to url: URL)` — private static; and `BoltzJobManager.settleTap: ((String) -> Void)?` — `#if DEBUG` only, receives `"write"` then `"discard"`.

- [ ] **Step 1: Write the failing test**

Add to `swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift`, inside the existing `#if os(macOS)` block and test class. The preflight refusal path is chosen because `PredictSizeGuard.decide` is pure — it needs no MLX, no weights, and no engine.

```swift
    /// The status file must be on disk BEFORE the placeholder is taken down.
    /// discard_pending pops _PENDING, which is the map every progress view reads;
    /// discarding first strands the error where nothing can observe it.
    func testPreflightRefusalWritesStatusBeforeDiscardingPlaceholder() throws {
        var order: [String] = []
        BoltzJobManager.settleTap = { order.append($0) }
        defer { BoltzJobManager.settleTap = nil }

        // 100k residues: far past any machine's fitting size, so preflight refuses
        // without touching MLX.
        let jobID = "test-\(UUID().uuidString.prefix(12))"
        try writeRequest(job: jobID,
                         chains: [("A", String(repeating: "A", count: 100_000))],
                         diffusionSteps: 200)
        BoltzJobManager.shared.handle(marker: "PREDICT:submit:\(jobID)")

        XCTAssertEqual(order, ["write", "discard"],
                       "status must be written before the placeholder is discarded")

        let statusURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raymol_predict_status_\(jobID).json")
        let status = try JSONDecoder().decode(
            BoltzJobManager.Status.self, from: Data(contentsOf: statusURL))
        XCTAssertEqual(status.state, "failed")
        XCTAssertNotNil(status.error)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/BoltzJobManagerTests 2>&1 | tail -30
```

Expected: FAIL to compile with `type 'BoltzJobManager' has no member 'settleTap'`.

- [ ] **Step 3: Add the settle helper and the DEBUG tap**

In `BoltzJobManager.swift`, immediately after `writeStatus` (which ends at line 139):

```swift
    #if DEBUG
    /// Test seam: receives "write" then "discard" for each terminal settle. Same
    /// pattern as PyMOLEngine's pythonTap -- `settle`'s ordering is the whole point
    /// of the function and is otherwise invisible, because discardPlaceholder is a
    /// main-queue hop into PyMOLEngine.shared that a unit test cannot observe.
    static var settleTap: ((String) -> Void)?
    #endif

    /// Record a terminal status, THEN take the placeholder down. Order is
    /// load-bearing: `discard_pending` pops `_PENDING`, the map every Python-derived
    /// progress view is built from, so discarding first records the failure after the
    /// only thing that could observe it has been deleted -- which is why an 11-minute
    /// run that failed used to just make its object vanish.
    ///
    /// One function rather than six call-pairs so a seventh exit cannot get it wrong.
    private static func settle(_ request: Request, _ status: Status, to url: URL) {
        try? writeStatus(status, to: url)
        #if DEBUG
        settleTap?("write")
        #endif
        discardPlaceholder(request)
        #if DEBUG
        settleTap?("discard")
        #endif
    }
```

- [ ] **Step 4: Replace the preflight site (line 179-183)**

Replace:

```swift
            if let failure = Self.preflight(request) {
                // Refused before any work: the placeholder Python just created will never
                // be filled, so drop it rather than leaving an empty stub behind.
                Self.discardPlaceholder(request)
                try? Self.writeStatus(failure, to: URL(fileURLWithPath: request.statusPath))
                return
            }
```

with:

```swift
            if let failure = Self.preflight(request) {
                // Refused before any work: the placeholder Python just created will never
                // be filled, so drop it rather than leaving an empty stub behind.
                Self.settle(request, failure, to: URL(fileURLWithPath: request.statusPath))
                return
            }
```

- [ ] **Step 5: Replace the five sites inside `run(_:)`**

`run` builds its `Status` through the nested `report` closure, which captures `var peak`/`var elapsed`. Keep that closure for the *running* reports and add a sibling that settles. Immediately after the existing `func isCancelled()` declaration, add:

```swift
        func settle(_ state: String, _ phase: String, error: String? = nil) {
            Self.settle(request,
                        Status(state: state, phase: phase, fraction: 0,
                               error: error, resultPath: nil,
                               peakBytes: peak, elapsedSeconds: elapsed),
                        to: statusURL)
        }
```

Then replace each pair. Unsupported input:

```swift
            guard canonical.diagnostics.isEmpty else {
                settle("failed", "featurize",
                       error: "unsupported input: \(canonical.diagnostics)")
                return
            }
```

Post-featurize cancel:

```swift
            if isCancelled() {
                settle("cancelled", "featurize"); return
            }
```

Post-inference cancel:

```swift
            if isCancelled() {
                settle("cancelled", "inference"); return
            }
```

The two `catch` blocks:

```swift
        } catch is CancellationError {
            settle("cancelled", "inference")
        } catch {
            settle("failed", "inference", error: error.localizedDescription)
        }
```

Leave `report("done", "done", 1.0, result: request.outPath)` and every `report("running", …)` exactly as they are — the success path deliberately loads before reporting done.

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/BoltzJobManagerTests 2>&1 | tail -30
```

Expected: PASS, and no other test in the class regresses.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/BoltzJobManager.swift swiftui/PyMOLViewerTests/BoltzJobManagerTests.swift
git commit -m "fix(predict): write the terminal status before discarding the placeholder

All six bad-exit paths recorded the failure after discard_pending had popped
_PENDING, so the error landed after the only map observing it was gone. One
settle() helper now owns the ordering, with a DEBUG tap pinning it."
```

---

## Task 2: `compose_progress` — the band mechanism

**Files:**
- Modify: `modules/pymol/predictors/base.py` (append after `parse_chains`, before `class PredictionOptions`)
- Create: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Produces: `compose_progress(status, phases)` → `(fraction, moving)` where `fraction` is `float|None` and `moving` is `bool`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/predict/predict_progress.py`. The `sys.path` shim is required — the runner imports test files by path and never adds their directory to `sys.path`.

```python
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from pymol import testing


BANDS = (
    ('featurize', 0.00, 0.03),
    ('load',      0.03, 0.10),
    ('inference', 0.10, 0.10),
    ('diffusion', 0.40, 0.97),
    ('done',      1.00, 1.00),
)


class TestComposeProgress(testing.PyMOLTestCase):

    def compose(self, phase, fraction):
        from pymol.predictors.base import compose_progress
        return compose_progress({'phase': phase, 'fraction': fraction}, BANDS)

    def testAWidebandMapsTheLocalFractionIntoIt(self):
        # 0.40 + 0.42 * (0.97 - 0.40) = 0.6394
        fraction, moving = self.compose('diffusion', 0.42)
        self.assertAlmostEqual(fraction, 0.6394, places=4)
        self.assertTrue(moving)

    def testAZeroSpanBandReturnsTheFloorAndIsNotMoving(self):
        """'started, cannot say how far in' -- the UI must draw a spinner."""
        fraction, moving = self.compose('inference', 0.9)
        self.assertAlmostEqual(fraction, 0.10)
        self.assertFalse(moving)

    def testAnUnknownPhaseSaysNothingRatherThanZero(self):
        """None never means zero: 'queued' must not slam the bar back to 0%."""
        self.assertEqual(self.compose('queued', 0.0), (None, False))
        self.assertEqual(self.compose('download', 0.5), (None, False))

    def testAFractionOutsideTheUnitRangeIsClamped(self):
        self.assertAlmostEqual(self.compose('diffusion', 2.0)[0], 0.97)
        self.assertAlmostEqual(self.compose('diffusion', -1.0)[0], 0.40)

    def testMalformedStatusNeverRaises(self):
        """It runs on a 500 ms main-thread poll; a throw freezes the object panel."""
        from pymol.predictors.base import compose_progress
        for status in ({}, {'phase': 'diffusion'},
                       {'phase': 'diffusion', 'fraction': 'x'},
                       {'phase': 'diffusion', 'fraction': None},
                       {'phase': None, 'fraction': 0.5}):
            self.assertEqual(compose_progress(status, BANDS), (None, False))

    def testAnEmptyBandTableAlwaysSaysNothing(self):
        from pymol.predictors.base import compose_progress
        self.assertEqual(
            compose_progress({'phase': 'diffusion', 'fraction': 0.5}, ()),
            (None, False))
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211 && PYMOL_DATA="$PWD/data" PYTHONPATH=/tmp/raymol-shadow /opt/homebrew/bin/pymol -ckqy testing/testing.py --run testing/tests/predict 2>&1 | tail -20
```

Expected: FAIL with `ImportError: cannot import name 'compose_progress'`.

- [ ] **Step 3: Implement `compose_progress`**

In `modules/pymol/predictors/base.py`, after `parse_chains` ends and before `class PredictionOptions`:

```python
#: A band is (phase, start, end) on an overall 0..1 scale, and a job's
#: status()['fraction'] is completion WITHIN its phase, restarting at 0 on each
#: phase change. The composition is
#:
#:     overall = start + local * (end - start)
#:
#: `end == start` -- a "zero-span" band -- means the backend reports only that
#: the phase BEGAN, not movement inside it. The composer returns the floor and
#: flags moving=False, and the UI draws an indeterminate bar plus a live elapsed
#: clock rather than a determinate one frozen at a made-up number.
#:
#: BANDS ARE LAYOUT, NOT TIME. Widths cannot track wall clock and must not be
#: read as an estimate of it: 'load' is ~10 s cold and ~0 s warm (the predictor
#: is kept alive across predictions), and boltz2's inference is 6.5 s at 60
#: residues and 675 s at 600. The bar is honest about WHICH PHASE and HOW FAR
#: THROUGH IT, never about time remaining.
#:
#: base.py names no phases on purpose: phase names belong to a backend's
#: pipeline, not to the infrastructure. See Boltz2Predictor.progress_phases.


def compose_progress(status, phases):
    """Fold one status dict into overall progress: (fraction, moving).

    fraction -- 0..1 across the whole run, or None when nothing can be said: a
                phase absent from `phases` (including 'queued', which carries no
                information at all), a missing key, or a fraction that is not a
                number. A caller holding a previous value should keep it; None
                never means zero.
    moving   -- True when the phase's band has width, so a determinate bar is
                honest. False when the backend only reports that the phase began.

    Total by construction: called from a 500 ms poll on the main thread, so it
    MUST NOT raise.
    """
    try:
        phase = status.get('phase')
        for name, start, end in phases:
            if name != phase:
                continue
            if end <= start:
                return start, False
            local = float(status.get('fraction') or 0.0)
            local = min(max(local, 0.0), 1.0)
            return start + local * (end - start), True
    except Exception:
        return None, False
    return None, False
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211 && PYMOL_DATA="$PWD/data" PYTHONPATH=/tmp/raymol-shadow /opt/homebrew/bin/pymol -ckqy testing/testing.py --run testing/tests/predict 2>&1 | tail -20
```

Expected: PASS, total count 137 + 6 = 143.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/predictors/base.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): compose_progress folds a per-phase fraction into one bar

The mechanism only -- base.py names no phases, because phase names belong to a
backend's pipeline. A zero-span band is how a backend says 'started this phase,
cannot say how far in' and renders as a spinner rather than a frozen bar."
```

---

## Task 3: `Predictor.progress()` and boltz2's table

**Files:**
- Modify: `modules/pymol/predictors/base.py` (`class Predictor`, after `option_defaults`), `modules/pymol/predictors/boltz2.py`, `modules/pymol/predictors/_template.py`, `docs/predictors.md`
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Consumes: `compose_progress` from Task 2.
- Produces: `Predictor.progress_phases` (tuple, default `()`); `Predictor.progress(self, status)` → `(fraction, moving)`.

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/predict/predict_progress.py`:

```python
class TestPredictorProgress(testing.PyMOLTestCase):

    def testTheBaseClassDeclaresNoPhases(self):
        """Phase names belong to a backend, not the infrastructure. A predictor
        that says nothing must get a spinner, never another backend's bar."""
        from pymol.predictors.base import Predictor
        self.assertEqual(Predictor.progress_phases, ())

    def testProgressIsConcreteSoExistingPredictorsStillInstantiate(self):
        from pymol.predictors.base import Predictor
        self.assertNotIn('progress', Predictor.__abstractmethods__)
        self.assertEqual(sorted(Predictor.__abstractmethods__),
                         ['check_available', 'parse_spec', 'submit'])

    def testBoltz2DeclaresItsOwnPipeline(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        names = [p[0] for p in Boltz2Predictor.progress_phases]
        self.assertEqual(names, ['featurize', 'load', 'inference',
                                 'trunk', 'diffusion', 'write', 'done'])

    def testBoltz2InferenceIsZeroSpanUntilTheUpstreamPatchLands(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        fraction, moving = Boltz2Predictor().progress(
            {'phase': 'inference', 'fraction': 0.5})
        self.assertFalse(moving)
        self.assertAlmostEqual(fraction, 0.10)

    def testBoltz2DiffusionIsDeterminate(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        fraction, moving = Boltz2Predictor().progress(
            {'phase': 'diffusion', 'fraction': 0.5})
        self.assertTrue(moving)
        self.assertGreater(fraction, 0.40)
        self.assertLess(fraction, 0.97)

    def testBandsAreOrderedAndWithinTheUnitRange(self):
        from pymol.predictors.boltz2 import Boltz2Predictor
        for name, start, end in Boltz2Predictor.progress_phases:
            self.assertLessEqual(start, end, name)
            self.assertGreaterEqual(start, 0.0, name)
            self.assertLessEqual(end, 1.0, name)

    def testTheTemplateDeclaresPhasesSoACopyInheritsABar(self):
        from pymol.predictors import _template
        self.assertTrue(_template.TemplatePredictor.progress_phases)
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL with `AttributeError: type object 'Predictor' has no attribute 'progress_phases'`.

- [ ] **Step 3: Add the attribute and method to `Predictor`**

In `base.py`, immediately after the `option_defaults` class attribute and before `@abc.abstractmethod def check_available`:

```python
    #: This predictor's pipeline phases, ordered, as (phase, start, end) bands.
    #: EMPTY BY DEFAULT on purpose: the base class makes no claim about anyone's
    #: pipeline. A predictor that declares nothing gets an indeterminate card with
    #: a live elapsed clock -- the correct rendering of no information, and far
    #: better than a bar derived from some other backend's phase names.
    progress_phases = ()
```

And after `validate_options` (the file's current last method):

```python
    def progress(self, status):
        """Overall progress for one of this predictor's jobs: (fraction, moving).

        CONCRETE, like validate_options -- never abstract. This class is a public
        extension point and a new @abc.abstractmethod would break every predictor
        already written against it. That also makes this the escape hatch: a
        backend the band table cannot express overrides this method instead.

        `status` is exactly what job.status() returned. This DERIVES from it and
        never stores a second copy, so status()['fraction'] stays the single
        source of truth and the two cannot drift.

        Never raises.
        """
        return compose_progress(status, self.progress_phases)
```

- [ ] **Step 4: Add boltz2's table**

In `modules/pymol/predictors/boltz2.py`, inside `class Boltz2Predictor`, immediately after `option_defaults`:

```python
    #: 'inference' is the coarse phase the host writes today, and it is zero-span
    #: because boltz-mlx v0.1.1 reports nothing from inside predictScored. 'trunk'
    #: and 'diffusion' replace it once v0.1.2's per-step callbacks land -- declared
    #: from day one so that increment is a Swift-side change with no rename and no
    #: edit here. They overlap 'inference' deliberately: they are alternative names
    #: for the same span, and exactly one of the three is ever the current phase.
    #:
    #: The weight fetch is absent on purpose. Its card owns that window and has a
    #: genuinely measured bytes/total bar; including it here would leave a
    #: warm-cache run -- every run after the first -- starting at ~25%.
    progress_phases = (
        ('featurize', 0.00, 0.03),
        ('load',      0.03, 0.10),
        ('inference', 0.10, 0.10),
        ('trunk',     0.10, 0.40),
        ('diffusion', 0.40, 0.97),
        ('write',     0.97, 1.00),
        ('done',      1.00, 1.00),
    )
```

- [ ] **Step 5: Add the template declaration**

In `modules/pymol/predictors/_template.py`, add a new section after the `-- Weights --` block:

```python
    # -- Progress ----------------------------------------------------------
    # YOUR pipeline's phases, not anyone else's. The base class declares none,
    # so leaving this empty shows an indeterminate spinner and an elapsed clock
    # -- correct when you have nothing to report, wrong if you do. Give a phase
    # a non-empty band ONLY if your backend really reports movement inside it;
    # a zero-span band is how you say "started this phase, cannot say how far
    # in". Widths are LAYOUT, not a time estimate -- see compose_progress.
    progress_phases = (('setup', 0.00, 0.10),
                       ('sample', 0.10, 0.95),
                       ('write', 0.95, 1.00),
                       ('done', 1.00, 1.00))
```

- [ ] **Step 6: Document it**

In `docs/predictors.md`, insert a new numbered step between the current step 7 (`submit` must not block) and step 8 (Register it), renumbering the rest:

```markdown
8. **Declare your progress phases, or your users get a spinner.** `progress_phases` is
   an ordered tuple of `(phase, start, end)` bands on an overall 0–1 scale; your job's
   `status()['fraction']` is completion *within* the current phase, and the app composes
   the two. The base class declares none, so a predictor that skips this shows an
   indeterminate card — which is correct if you genuinely cannot report movement, and a
   missed opportunity if you can. Give a phase a zero-width band (`end == start`) to say
   "started, cannot say how far in": that is honest, and far better than a bar frozen at
   a made-up number. Widths are layout, not a time estimate — they cannot track wall
   clock, because the same phase varies by orders of magnitude with input size.
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the Python test command. Expected: PASS, 150 total.

- [ ] **Step 8: Commit**

```bash
git add modules/pymol/predictors/base.py modules/pymol/predictors/boltz2.py modules/pymol/predictors/_template.py docs/predictors.md testing/tests/predict/predict_progress.py
git commit -m "feat(predict): Predictor.progress(), with boltz2's phases in boltz2.py

Concrete, not abstract -- a new abstractmethod would break every predictor
already written against the class, and concreteness doubles as the escape hatch
for a backend the band table cannot express."
```

---

## Task 4: `pending_info` — per-object progress, folded across models

**Files:**
- Modify: `modules/pymol/predicting.py` (`_PENDING` block, `pending_detail`, `register_pending`, `discard_pending`, `clear_pending`, `deliver_result`)
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Consumes: `Predictor.progress` from Task 3.
- Produces: `pending_info(name, _self=cmd)` → dict with keys `state`, `phase`, `fraction` (float|None), `moving` (bool), `detail` (str), `models_done` (int), `models_total` (int), `elapsed` (float), `error` (str|None), `bundle` (str|None). `pending_detail(name, _self=cmd)` keeps its existing signature and return type.

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/predict/predict_progress.py`:

```python
class ProgressStubJob:
    """A job whose status is scripted, and which counts how often it is read.

    predict_api.StubJob returns a fixed terminal status that ~15 existing tests
    assert on, so it must not be modified -- this is its progress-aware sibling.
    """

    _counter = 0

    def __init__(self, statuses):
        ProgressStubJob._counter += 1
        self.job_id = 'progress-%d' % ProgressStubJob._counter
        self.statuses = list(statuses)
        self.status_calls = 0

    def status(self):
        self.status_calls += 1
        return self.statuses[min(self.status_calls - 1, len(self.statuses) - 1)]

    def cancel(self):
        self.cancelled = True


class TestPendingInfo(testing.PyMOLTestCase):

    def setUp(self):
        from pymol import predicting
        from pymol.predictors import registry
        from pymol.predictors.base import Predictor, PredictionSpec, parse_chains

        class ProgressStub(Predictor):
            id = 'progress_stub'
            name = 'Progress stub'
            progress_phases = (('featurize', 0.00, 0.03),
                               ('load', 0.03, 0.10),
                               ('inference', 0.10, 0.10),
                               ('diffusion', 0.40, 0.97),
                               ('done', 1.00, 1.00))

            def check_available(self):
                return None

            def parse_spec(self, sequence, name=''):
                return PredictionSpec(parse_chains(sequence), name)

            def submit(self, spec, options, weights_path):
                raise AssertionError('tests register jobs directly')

        registry.register(ProgressStub(), replace=True)
        self.predicting = predicting

    def tearDown(self):
        from pymol.predictors import registry
        self.predicting.clear_pending()
        registry.unregister('progress_stub')
        self.cmd.delete('all')

    def register(self, name, statuses_per_job):
        jobs = []
        for statuses in statuses_per_job:
            job = ProgressStubJob(statuses)
            job.predictor_id = 'progress_stub'
            self.predicting._JOBS[job.job_id] = job
            self.predicting.register_pending(name, job.job_id, _self=self.cmd)
            jobs.append(job)
        return jobs

    def testOnlyOneStatusIsReadPerPendingObjectPerPoll(self):
        """n_models can be 20; the poll runs on the main thread every 500 ms."""
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.5}]] * 5)
        self.predicting.pending_info('multi', _self=self.cmd)
        self.assertEqual(sum(j.status_calls for j in jobs), 1)

    def testProgressIsFoldedAcrossModels(self):
        self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.0}]] * 3)
        info = self.predicting.pending_info('multi', _self=self.cmd)
        self.assertEqual(info['models_total'], 3)
        self.assertEqual(info['models_done'], 0)
        # first model at band floor 0.40, folded over 3 -> ~0.133
        self.assertAlmostEqual(info['fraction'], 0.40 / 3, places=3)
        self.assertIn('model 1 of 3', info['detail'])

    def testTheComposedFractionNeverDecreases(self):
        """The real cold sequence dips at 'queued' and again on cancel."""
        self.register('mono', [[{'phase': 'featurize', 'fraction': 1.0},
                                {'phase': 'load', 'fraction': 1.0},
                                {'phase': 'diffusion', 'fraction': 0.5},
                                {'phase': 'queued', 'fraction': 0.0},
                                {'phase': 'diffusion', 'fraction': 0.0}]])
        seen = []
        for _ in range(5):
            seen.append(self.predicting.pending_info('mono', _self=self.cmd)['fraction'])
        for earlier, later in zip(seen, seen[1:]):
            self.assertGreaterEqual(later, earlier, seen)

    def testAJobWhoseStatusRaisesStillProducesARecord(self):
        class Exploding(ProgressStubJob):
            def status(self):
                raise RuntimeError('boom')

        job = Exploding([])
        job.predictor_id = 'progress_stub'
        self.predicting._JOBS[job.job_id] = job
        self.predicting.register_pending('boom', job.job_id, _self=self.cmd)
        info = self.predicting.pending_info('boom', _self=self.cmd)
        self.assertEqual(info['state'], 'running')
        self.assertIsNone(info['fraction'])
        self.assertFalse(info['moving'])

    def testPendingDetailKeepsItsDocumentedPrefix(self):
        """predict_weights_async and predict_autoload assert on this string."""
        self.register('mono', [[{'phase': 'diffusion', 'fraction': 0.5}]])
        self.assertTrue(
            self.predicting.pending_detail('mono', _self=self.cmd).startswith('pending'))

    def testPendingDetailIsNoneForAnUnknownName(self):
        self.assertIsNone(self.predicting.pending_detail('nope', _self=self.cmd))

    def testTheMonotoneFloorIsRetiredOnSuccessSoAReRunCountsFromOne(self):
        self.register('again', [[{'phase': 'done', 'fraction': 1.0}]])
        self.predicting.discard_pending('again', _self=self.cmd)
        self.register('again', [[{'phase': 'featurize', 'fraction': 0.0}]] * 2)
        info = self.predicting.pending_info('again', _self=self.cmd)
        self.assertEqual(info['models_total'], 2)
        self.assertIn('model 1 of 2', info['detail'])
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL with `AttributeError: module 'pymol.predicting' has no attribute 'pending_info'`.

- [ ] **Step 3: Add `_TRACK` beside `_PENDING`**

In `modules/pymol/predicting.py`, immediately after the `_PENDING` declaration:

```python
#: name -> per-object progress bookkeeping the job handles cannot supply:
#: {'total': N, 'done': k, 'started': monotonic_seconds, 'floor': fraction}.
#: `floor` is a monotone clamp -- bands make monotonicity meaningful, this makes
#: it guaranteed against a phase table that drifts, HostJob's 'queued' fallback,
#: and the fraction reset every terminal path in Swift writes.
_TRACK = {}
```

- [ ] **Step 4: Record and retire the bookkeeping**

In `register_pending`, after the existing `_PENDING.setdefault(name, []).append(job_id)`:

```python
    import time
    track = _TRACK.setdefault(
        name, {'total': 0, 'done': 0, 'started': time.monotonic(), 'floor': 0.0})
    track['total'] += 1
```

In `discard_pending`, alongside the existing `_PENDING.pop(name, None)`:

```python
    _TRACK.pop(name, None)
```

In `clear_pending`, alongside the existing `_PENDING` clear:

```python
    _TRACK.clear()
```

In `deliver_result`'s `finally` block, inside the branch that pops one id, bump the counter, and drop `_TRACK` on the branch that removes the key entirely:

```python
        remaining = _PENDING.get(name)
        if remaining:
            remaining.pop(0)
            track = _TRACK.get(name)
            if track is not None:
                track['done'] += 1
            if not remaining:
                _PENDING.pop(name, None)
                _TRACK.pop(name, None)
```

- [ ] **Step 5: Add `pending_info` and rewrite `pending_detail` as its formatter**

Replace the existing `pending_detail` with:

```python
def pending_info(name, _self=cmd):
    """Structured progress for a placeholder, or None if it is not pending.

    Keys: state, phase, fraction (0..1 or None), moving, detail, models_done,
    models_total, elapsed, error.

    ONE status read per pending OBJECT, never per model: this runs on the main
    thread every 500 ms and n_models can be 20. The first outstanding job is the
    one in flight; the rest are queued behind it.

    Never raises. The whole body -- status(), the composition AND the arithmetic
    -- is inside one try, because appkit_inspector's caller writes no file at all
    if this throws, which freezes the object panel on a stale list.
    """
    import time
    job_ids = _PENDING.get(name)
    if not job_ids:
        return None
    track = _TRACK.get(name) or {'total': len(job_ids), 'done': 0,
                                 'started': time.monotonic(), 'floor': 0.0}
    info = {'state': 'running', 'phase': 'pending', 'fraction': None,
            'moving': False, 'models_done': track['done'],
            'models_total': max(track['total'], 1),
            'elapsed': max(time.monotonic() - track['started'], 0.0),
            'error': None, 'detail': 'pending', 'bundle': None}
    try:
        job = _JOBS.get(job_ids[0])
        if job is not None:
            # The weight bundle this job is still waiting on, or None once it has
            # been submitted. The tray hides a prediction card while its bundle's
            # own download card is up, so a cold-cache run shows ONE card and not
            # two describing the same transfer at two different percentages.
            bundle = getattr(job, '_bundle', None)
            if bundle is not None and getattr(job, '_real', None) is None:
                info['bundle'] = getattr(bundle, 'id', None)
            status = job.status()
            info['state'] = status.get('state') or 'running'
            info['phase'] = status.get('phase') or 'pending'
            info['error'] = status.get('error')
            fraction, moving = _job_progress(job, status)
            if fraction is not None:
                whole = (track['done'] + fraction) / info['models_total']
                whole = max(whole, track.get('floor', 0.0))
                track['floor'] = whole
                info['fraction'] = whole
                info['moving'] = moving
            elif track.get('floor'):
                info['fraction'] = track['floor']
        info['detail'] = _format_detail(info)
    except Exception:
        pass
    return info


def _job_progress(job, status):
    """(fraction, moving) from the job's own predictor, or (None, False)."""
    try:
        from .predictors import registry
        predictor = registry.get(getattr(job, 'predictor_id', '') or '')
        return predictor.progress(status)
    except Exception:
        return None, False


def _format_detail(info):
    """'pending: diffusion 64% (model 1 of 3)'. Short -- it is a tooltip."""
    parts = ['pending: %s' % info['phase']]
    if info['fraction'] is not None and info['moving']:
        parts.append('%d%%' % int(info['fraction'] * 100))
    detail = ' '.join(parts)
    if info['models_total'] > 1:
        detail += ' (model %d of %d)' % (
            min(info['models_done'] + 1, info['models_total']), info['models_total'])
    return detail


def pending_detail(name, _self=cmd):
    """One-line description of the job a placeholder is waiting on, or None.

    This is the string the object panel shows on hover, so it must stay short and
    must never raise: it is rendered from a 500 ms poll on the main thread. It is
    now a thin formatter over pending_info, so the tooltip and the progress card
    can never disagree.
    """
    info = pending_info(name, _self=_self)
    return None if info is None else info['detail']
```

- [ ] **Step 6: Record the predictor id on every job**

`_job_progress` needs to know which predictor owns a job. In `predict()`, inside the `for index in range(count)` loop, immediately after `_JOBS[job.job_id] = job`:

```python
        # Which predictor to ask for progress bands. Set here rather than required
        # of every job class, so a third-party handle needs no new attribute.
        try:
            job.predictor_id = predictor_obj.id
        except AttributeError:
            pass          # __slots__ handle: it simply gets the spinner
```

- [ ] **Step 7: Run the tests to verify they pass**

Run the Python test command. Expected: PASS. The pre-existing `predict_weights_async.py` and `predict_autoload.py` assertions on `pending_detail` must still pass — confirm the total is 150 + 7 = 157 with 0 failures.

- [ ] **Step 8: Commit**

```bash
git add modules/pymol/predicting.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): pending_info, with a monotone floor and model folding

pending_detail becomes a thin formatter over it, so the object-panel tooltip and
the progress card can never disagree. One status read per pending OBJECT, never
per model -- n_models can be 20 and this runs on the main thread at 2 Hz."
```

---

## Task 5: Carry the record on the object-panel payload

**Files:**
- Modify: `modules/pymol/appkit_inspector.py:440-459` (`_pending_map`), `:498-516` (the payload dict)
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Consumes: `pending_info` from Task 4.
- Produces: payload key `pending_jobs` — `{object_name: {state, phase, fraction, moving, detail, models_done, models_total, elapsed, error}}`, every value a JSON scalar or null. `pending` keeps its `Dict[str, str]` type.

- [ ] **Step 1: Write the failing test**

Append to `testing/tests/predict/predict_progress.py`, inside `TestPendingInfo`:

```python
    def testThePayloadCarriesTheRecordAndKeepsPendingAStringMap(self):
        """Swift decodes `pending` as [String: String]; widening it would break
        the whole PanelPayload decode and take the object list with it."""
        import json
        import os
        import tempfile
        from pymol import appkit_inspector

        self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.5}]] * 2)
        appkit_inspector.poll_panel()
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % os.getpid())
        with open(path) as handle:
            payload = json.load(handle)

        self.assertIsInstance(payload['pending']['multi'], str)
        record = payload['pending_jobs']['multi']
        self.assertEqual(record['models_total'], 2)
        for key, value in record.items():
            self.assertIsInstance(value, (str, int, float, bool, type(None)),
                                  'pending_jobs.%s is not a scalar' % key)

    def testPollPanelStillWritesAFileWhenAJobExplodes(self):
        import os
        import tempfile
        from pymol import appkit_inspector

        class Exploding(ProgressStubJob):
            def status(self):
                raise RuntimeError('boom')

        job = Exploding([])
        job.predictor_id = 'progress_stub'
        self.predicting._JOBS[job.job_id] = job
        self.predicting.register_pending('boom', job.job_id, _self=self.cmd)
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_objpanel_%d.json' % os.getpid())
        if os.path.exists(path):
            os.remove(path)
        appkit_inspector.poll_panel()
        self.assertTrue(os.path.exists(path))
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL with `KeyError: 'pending_jobs'`.

- [ ] **Step 3: Replace `_pending_map` with `_pending_maps`**

In `modules/pymol/appkit_inspector.py`, replace the whole `_pending_map` function:

```python
def _pending_maps():
    """(detail_map, record_map) for prediction placeholders still waiting.

    Two maps from ONE pass, so the hover tooltip and the progress card are the
    same computation and cannot disagree.

    Never raises: a failure here would freeze the whole object panel on a stale
    list, because the caller's single `except` writes no file at all.
    """
    try:
        from pymol import predicting
        names = predicting.pending_objects()
        if not names:
            return {}, {}
        details, records = {}, {}
        for name in names:
            try:
                info = predicting.pending_info(name)
            except Exception:
                info = None
            if info is None:
                details[name] = 'pending'
                continue
            details[name] = info.get('detail') or 'pending'
            records[name] = info
        return details, records
    except Exception:
        return {}, {}
```

- [ ] **Step 4: Emit both keys in the payload**

In `poll_panel`, replace the single `'pending': _pending_map(),` line. The call must happen **before** the `payload = {` literal so both maps come from one pass:

```python
        # Structure prediction (#224, #291): objects that are empty placeholders
        # waiting on a running job. `pending` is the hover tooltip (a plain string
        # map -- Swift decodes it as [String: String] and widening it would fail
        # the whole payload decode). `pending_jobs` is the structured record the
        # progress tray renders.
        #
        # Cheap by construction: normally empty, and only pending names read a
        # status file -- one read per pending OBJECT, never per model. This poll
        # runs on the MAIN thread every 500 ms and was already a measured hot spot
        # (PR #270), so it must stay O(pending), never O(objects).
        pending_details, pending_records = _pending_maps()
        payload = {
```

and inside the dict literal, replacing the old `'pending'` entry:

```python
            'pending': pending_details,
            'pending_jobs': pending_records,
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Python test command. Expected: PASS, 159 total.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/appkit_inspector.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): carry a structured progress record on the panel payload

One pass produces both the tooltip string and the record, so they cannot
disagree. `pending` keeps its [String: String] shape -- widening it would fail
the whole PanelPayload decode and take the object list down with it."
```

---

## Task 6: `predict_cancel` accepts an object name

The card's Cancel is per *object*, but `n_models` registers N jobs against one name. Cancelling `job_ids[0]` would leave N−1 running.

**Files:**
- Modify: `modules/pymol/predicting.py:621-640` (`predict_cancel`)
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Produces: `predict_cancel(job_id, quiet=1, _self=cmd)` — `job_id` now also accepts a pending object name, cancelling every job registered against it.

- [ ] **Step 1: Write the failing test**

Append to `TestPendingInfo`:

```python
    def testCancellingByObjectNameStopsEveryModel(self):
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.1}]] * 3)
        self.predicting.predict_cancel('multi', quiet=1, _self=self.cmd)
        for job in jobs:
            self.assertTrue(getattr(job, 'cancelled', False), job.job_id)

    def testCancellingByJobIdStillCancelsExactlyThatJob(self):
        jobs = self.register('multi', [[{'phase': 'diffusion', 'fraction': 0.1}]] * 2)
        self.predicting.predict_cancel(jobs[0].job_id, quiet=1, _self=self.cmd)
        self.assertTrue(getattr(jobs[0], 'cancelled', False))
        self.assertFalse(getattr(jobs[1], 'cancelled', False))
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL — the object-name call raises because no job has that id.

- [ ] **Step 3: Resolve a name to its job ids**

In `predict_cancel`, immediately after the existing `pump(_self=_self)` call and before the existing `_job(job_id)` lookup:

```python
    # A pending OBJECT name cancels every model registered against it. The
    # progress card's Cancel is per object, and with n_models > 1 cancelling only
    # _PENDING[name][0] would leave the other N-1 running. Job ids are
    # 'pending-<12 hex>' / backend-specific and never collide with object names,
    # so this cannot shadow a real id.
    ids = _PENDING.get(job_id)
    if ids:
        for one in list(ids):
            try:
                _job(one).cancel()
            except Exception as exc:
                colorprinting.warning(' predict_cancel: %s (%s)' % (one, exc))
        if not int(quiet):
            colorprinting.parrot(' predict_cancel: cancelled %d job(s) for %s'
                                 % (len(ids), job_id))
        return
```

- [ ] **Step 4: Update the docstring**

In `predict_cancel`'s docstring, change the `ARGUMENTS` line for `job_id` to:

```
    job_id = string: the job to cancel, or the name of a pending object -- which
        cancels every model still outstanding for it.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Python test command. Expected: PASS, 161 total.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/predicting.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): predict_cancel accepts a pending object name

The progress card's Cancel is per object; with n_models > 1, cancelling only the
first registered job left the rest running."
```

---

## Task 7: Decode the record into a `@Published` array

**Files:**
- Modify: `swiftui/PyMOLViewer/Panels/ObjectPanel.swift` (the `PanelPayload` Codable struct and `parseObjectPanelFeedback`), `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:98-127`
- Create: `swiftui/PyMOLViewerTests/PendingJobTests.swift`

**Interfaces:**
- Consumes: the `pending_jobs` payload key from Task 5.
- Produces: `struct PredictionJobState: Codable, Equatable, Identifiable` with `id: String` (the object name), `state`, `phase: String`, `fraction: Double?`, `moving: Bool`, `detail: String`, `modelsDone: Int`, `modelsTotal: Int`, `elapsed: Double`, `error: String?`, `bundle: String?`, plus `var isError: Bool`; and `PyMOLEngine.predictionJobs: [PredictionJobState]`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/PendingJobTests.swift`. The payload string is captured **verbatim** from a real `poll_panel()` tempfile — never hand-written to agree with the decoder, which is the discipline `WeightsFetchStateTests.swift` established.

```swift
import XCTest
@testable import RayMol

final class PendingJobTests: XCTestCase {

    /// Captured from $TMPDIR/pymol_objpanel_<pid>.json during a real 2-model run.
    private let payload = """
    {"objects":["multi"],"selections":[],"enabled":[],"sel_counts":{},
     "nstate":{"multi":1},"has_transp":{"multi":false},"groups":[],"parent":{},
     "pending":{"multi":"pending: diffusion 64% (model 1 of 2)"},
     "pending_jobs":{"multi":{"state":"running","phase":"diffusion",
       "fraction":0.3196,"moving":true,
       "detail":"pending: diffusion 64% (model 1 of 2)",
       "models_done":0,"models_total":2,"elapsed":412.5,"error":null}}}
    """

    func testTheRecordDecodesFromARealPayload() throws {
        let decoded = try JSONDecoder().decode(
            PanelPayload.self, from: Data(payload.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["multi"])
        XCTAssertEqual(job.phase, "diffusion")
        XCTAssertEqual(job.fraction ?? 0, 0.3196, accuracy: 0.0001)
        XCTAssertTrue(job.moving)
        XCTAssertEqual(job.modelsTotal, 2)
        XCTAssertEqual(job.elapsed, 412.5, accuracy: 0.01)
        XCTAssertNil(job.error)
        XCTAssertFalse(job.isError)
    }

    /// An older bundled Python has no pending_jobs key. The object list must
    /// still decode -- otherwise the whole panel freezes on a stale list.
    func testAPayloadWithoutPendingJobsStillDecodes() throws {
        let old = """
        {"objects":["a"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"a":1},"has_transp":{"a":false},"groups":[],"parent":{},
         "pending":{}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.objects, ["a"])
        XCTAssertNil(decoded.pending_jobs)
    }

    /// A partially-populated record must not fail the WHOLE payload decode.
    func testARecordMissingOptionalFieldsStillDecodes() throws {
        let partial = """
        {"objects":["p"],"selections":[],"enabled":[],"sel_counts":{},
         "nstate":{"p":1},"has_transp":{"p":false},"groups":[],"parent":{},
         "pending":{"p":"pending"},
         "pending_jobs":{"p":{"state":"running","phase":"pending"}}}
        """
        let decoded = try JSONDecoder().decode(PanelPayload.self, from: Data(partial.utf8))
        let job = try XCTUnwrap(decoded.pending_jobs?["p"])
        XCTAssertNil(job.fraction)
        XCTAssertFalse(job.moving)
        XCTAssertEqual(job.modelsTotal, 1)
    }

    func testBothErrorAndFailedCountAsAnErrorState() {
        // Swift's host writes "failed"; _DeferredJob writes "error". Neither wire
        // is migrated, so the single consumer must accept both.
        for state in ["error", "failed"] {
            let job = PredictionJobState(
                id: "x", state: state, phase: "inference", fraction: nil,
                moving: false, detail: "d", modelsDone: 0, modelsTotal: 1,
                elapsed: 1, error: "boom")
            XCTAssertTrue(job.isError, state)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodegen generate && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/PendingJobTests 2>&1 | tail -30
```

Expected: FAIL to compile with `cannot find type 'PredictionJobState'`.

- [ ] **Step 3: Add `PredictionJobState`**

In `ObjectPanel.swift`, immediately before the `PanelPayload` struct:

```swift
/// One pending prediction, as reported by `predicting.pending_info`.
///
/// Every field except `state` and `phase` is Optional-or-defaulted on the wire:
/// a partially-populated record must not fail the WHOLE PanelPayload decode and
/// take the object list down with it.
struct PredictionJobState: Codable, Equatable, Identifiable {
    /// The object name. Unique per pending placeholder, which is exactly the
    /// granularity of one card -- n_models shares one object and one card.
    let id: String
    let state: String
    let phase: String
    let fraction: Double?
    let moving: Bool
    let detail: String
    let modelsDone: Int
    let modelsTotal: Int
    let elapsed: Double
    let error: String?
    /// The weight bundle this job is still waiting on, or nil once submitted.
    /// The tray hides this card while that bundle's own download card is up.
    let bundle: String?

    /// Swift's host writes "failed"; _DeferredJob writes "error". Neither wire is
    /// migrated, so the single consumer accepts both.
    var isError: Bool { state == "error" || state == "failed" || state == "cancelled" }

    enum CodingKeys: String, CodingKey {
        case state, phase, fraction, moving, detail, error, bundle
        case modelsDone = "models_done", modelsTotal = "models_total", elapsed
    }

    init(id: String, state: String, phase: String, fraction: Double?, moving: Bool,
         detail: String, modelsDone: Int, modelsTotal: Int, elapsed: Double,
         error: String?, bundle: String? = nil) {
        self.id = id; self.state = state; self.phase = phase
        self.fraction = fraction; self.moving = moving; self.detail = detail
        self.modelsDone = modelsDone; self.modelsTotal = modelsTotal
        self.elapsed = elapsed; self.error = error; self.bundle = bundle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ""                       // filled in from the dictionary key
        state = try c.decode(String.self, forKey: .state)
        phase = try c.decode(String.self, forKey: .phase)
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        moving = try c.decodeIfPresent(Bool.self, forKey: .moving) ?? false
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? "pending"
        modelsDone = try c.decodeIfPresent(Int.self, forKey: .modelsDone) ?? 0
        modelsTotal = try c.decodeIfPresent(Int.self, forKey: .modelsTotal) ?? 1
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        bundle = try c.decodeIfPresent(String.self, forKey: .bundle)
    }

    /// `id` comes from the payload's dictionary key, not the record body.
    func withID(_ name: String) -> PredictionJobState {
        PredictionJobState(id: name, state: state, phase: phase, fraction: fraction,
                           moving: moving, detail: detail, modelsDone: modelsDone,
                           modelsTotal: modelsTotal, elapsed: elapsed, error: error,
                           bundle: bundle)
    }
}
```

- [ ] **Step 4: Add the payload key**

In the `PanelPayload` struct, add alongside the existing `pending` property:

```swift
    /// #291. Optional so an older bundled Python still decodes and the tray simply
    /// shows no prediction cards.
    let pending_jobs: [String: PredictionJobState]?
```

- [ ] **Step 5: Publish the array**

In `PyMOLEngine.swift`, immediately after `@Published var weightsFetch: WeightsFetchState?`:

```swift
    /// Running predictions, newest-object-first, refreshed by the 500 ms panel
    /// poll. Rendered by ProgressTray. Guarded on assignment like every other
    /// collection here -- an unguarded 2 Hz assignment re-lays-out the tray on
    /// every tick even when nothing changed.
    @Published var predictionJobs: [PredictionJobState] = []
```

In `parseObjectPanelFeedback`, inside the existing `DispatchQueue.main.async` block that assigns the object list:

```swift
            let jobs = (payload.pending_jobs ?? [:])
                .map { $0.value.withID($0.key) }
                .sorted { $0.id < $1.id }
            if self.predictionJobs != jobs { self.predictionJobs = jobs }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Swift test command from Step 2. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Panels/ObjectPanel.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/PendingJobTests.swift
git commit -m "feat(predict): decode pending_jobs into @Published predictionJobs

Optional key and defaulted fields throughout: an older bundled Python, or a
partially-populated record, must not fail the whole PanelPayload decode and take
the object list with it."
```

---

## Task 8: `ProgressTray.swift` — the item model, the card, the tray

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/ProgressTray.swift`
- Test: `swiftui/PyMOLViewerTests/PendingJobTests.swift`

**Interfaces:**
- Consumes: `PredictionJobState` (Task 7), the existing `WeightsFetchState`.
- Produces: `ProgressItem` with `static func weights(_:) -> ProgressItem` and `static func prediction(_:) -> ProgressItem`; `ProgressCard`; `ProgressTray(items:onAction:)`; `ProgressCard.formatElapsed(_:) -> String`.

- [ ] **Step 1: Write the failing test**

Append to `PendingJobTests.swift`:

```swift
extension PendingJobTests {

    func testAPredictionItemCarriesAPerObjectCancelCommand() {
        let job = PredictionJobState(
            id: "my pred", state: "running", phase: "diffusion", fraction: 0.5,
            moving: true, detail: "pending: diffusion 64%", modelsDone: 0,
            modelsTotal: 2, elapsed: 12, error: nil)
        let item = ProgressItem.prediction(job)
        XCTAssertEqual(item.id, "predict:my pred")
        XCTAssertEqual(item.buttonTitle, "Cancel")
        // Quoted: object names may contain spaces.
        XCTAssertEqual(item.cancelCommand, "predict_cancel \"my pred\"")
        XCTAssertTrue(item.moving)
        XCTAssertFalse(item.isError)
    }

    func testAFailedPredictionShowsItsErrorAndOffersDismiss() {
        let job = PredictionJobState(
            id: "p", state: "failed", phase: "inference", fraction: nil,
            moving: false, detail: "pending", modelsDone: 0, modelsTotal: 1,
            elapsed: 600, error: "input of 9000 residues is too large")
        let item = ProgressItem.prediction(job)
        XCTAssertTrue(item.isError)
        XCTAssertEqual(item.buttonTitle, "Dismiss")
        XCTAssertEqual(item.detail, "input of 9000 residues is too large")
        XCTAssertFalse(item.moving)
    }

    func testElapsedIsFormattedCoarsely() {
        XCTAssertEqual(ProgressCard.formatElapsed(4), "4 sec")
        XCTAssertEqual(ProgressCard.formatElapsed(95), "2 min")
        XCTAssertEqual(ProgressCard.formatElapsed(4000), "1 hr 7 min")
    }

    private func job(_ id: String, state: String = "running",
                     bundle: String? = nil) -> PredictionJobState {
        PredictionJobState(id: id, state: state, phase: "inference", fraction: nil,
                           moving: false, detail: "d", modelsDone: 0, modelsTotal: 1,
                           elapsed: 1, error: state == "running" ? nil : "boom",
                           bundle: bundle)
    }

    /// A cold-cache run must show ONE card, not two describing the same transfer
    /// at two different percentages.
    func testAPredictionWaitingOnALiveDownloadIsHidden() {
        let fetch = WeightsFetchState(
            id: "boltz2-mlx-int8", state: "running", phase: "download",
            fraction: 0.4, received: 200, total: 500, elapsed: 10, error: nil)
        let items = ProgressItem.tray(weights: fetch,
                                      predictions: [job("p", bundle: "boltz2-mlx-int8")])
        XCTAssertEqual(items.map(\.id), ["weights:boltz2-mlx-int8"])
    }

    func testAPredictionWaitingOnADIFFERENTBundleIsStillShown() {
        let fetch = WeightsFetchState(
            id: "other", state: "running", phase: "download",
            fraction: 0.4, received: 200, total: 500, elapsed: 10, error: nil)
        let items = ProgressItem.tray(weights: fetch,
                                      predictions: [job("p", bundle: "boltz2-mlx-int8")])
        XCTAssertEqual(items.count, 2)
    }

    func testRunningCardsSortAboveErrorCards() {
        let items = ProgressItem.tray(
            weights: nil,
            predictions: [job("zzz-failed", state: "failed"), job("aaa-running")])
        XCTAssertEqual(items.map(\.id), ["predict:aaa-running", "predict:zzz-failed"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Swift test command. Expected: FAIL to compile with `cannot find 'ProgressItem' in scope`.

- [ ] **Step 3: Create the file**

Create `swiftui/PyMOLViewer/Shared/ProgressTray.swift`. No `#if os(macOS)` — the tray also hosts weight downloads, and gating it would leave iOS silently frozen the day a bundle downloads there.

```swift
// ProgressTray.swift — one stacked, max-height, scrollable tray of non-blocking
// progress cards: weight downloads and running predictions in the same corner.
//
// Deliberately NOT a scrim. A scrim is a truth claim that the main thread is
// blocked (see CalculatingOverlay); everything in this tray runs off-main and
// the app stays fully interactive for the whole ten-plus minutes.
import SwiftUI

/// One row. Kind-agnostic on purpose: the button runs `cancelCommand` verbatim
/// through runCommand, so the view knows nothing about jobs or downloads.
struct ProgressItem: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    let detail: String
    let fraction: Double?
    let moving: Bool
    let isError: Bool
    let buttonTitle: String
    let cancelCommand: String?
    /// Set on a prediction still waiting on a weight fetch, so the tray can drop
    /// it while the download's own card is showing the same thing.
    let bundle: String?

    static func weights(_ fetch: WeightsFetchState) -> ProgressItem {
        ProgressItem(
            id: "weights:\(fetch.id)",
            icon: fetch.isError ? "exclamationmark.triangle.fill" : "arrow.down.circle",
            title: fetch.isError ? "Model weights failed to download"
                                 : "Downloading model weights",
            detail: WeightDownloadDetail.text(fetch),
            fraction: fetch.fraction,
            moving: !fetch.isError,
            isError: fetch.isError,
            buttonTitle: fetch.isError ? "Dismiss" : "Cancel",
            cancelCommand: fetch.isError ? nil : "predict_weights_cancel \(fetch.id)",
            bundle: fetch.id)
    }

    static func prediction(_ job: PredictionJobState) -> ProgressItem {
        var parts: [String] = []
        if job.modelsTotal > 1 {
            parts.append("model \(min(job.modelsDone + 1, job.modelsTotal)) of \(job.modelsTotal)")
        }
        parts.append("\(ProgressCard.formatElapsed(job.elapsed)) elapsed")
        return ProgressItem(
            id: "predict:\(job.id)",
            icon: job.isError ? "exclamationmark.triangle.fill" : "atom",
            title: job.isError ? "Prediction failed: \(job.id)" : "Predicting \(job.id)",
            detail: job.isError ? (job.error ?? "Unknown error")
                                : ([job.phase.capitalized] + parts).joined(separator: " · "),
            fraction: job.fraction,
            moving: job.moving && !job.isError,
            isError: job.isError,
            buttonTitle: job.isError ? "Dismiss" : "Cancel",
            cancelCommand: job.isError ? "predict_dismiss \(quoted(job.id))"
                                       : "predict_cancel \(quoted(job.id))",
            bundle: job.bundle)
    }

    /// Object names may contain spaces, and the command line splits on them.
    private static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// Everything the tray should show, in order.
    ///
    /// A static rather than a computed property on ContentView so the merge, the
    /// filter and the sort are unit-testable without instantiating a View.
    static func tray(weights: WeightsFetchState?,
                     predictions: [PredictionJobState]) -> [ProgressItem] {
        var items: [ProgressItem] = []
        if let weights { items.append(.weights(weights)) }
        // While a bundle is fetching, its OWN card is the measured one; a
        // prediction merely waiting on it would show the same transfer again at a
        // different number.
        let fetching = Set(items.compactMap(\.bundle))
        items += predictions
            .map(ProgressItem.prediction)
            .filter { item in item.bundle.map { !fetching.contains($0) } ?? true }
        // Running first, so a live job is never pushed below the fold by a stale
        // error card the user has not dismissed.
        return items.sorted { lhs, rhs in
            lhs.isError == rhs.isError ? lhs.id < rhs.id : !lhs.isError
        }
    }
}

/// The detail line for a weight fetch, lifted from WeightDownloadOverlay so the
/// download card reads exactly as it did before the tray existed.
enum WeightDownloadDetail {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f
    }()

    static func text(_ fetch: WeightsFetchState) -> String {
        if fetch.isError { return fetch.error ?? "Unknown error" }
        let percent = "\(Int((min(max(fetch.fraction, 0), 1) * 100).rounded()))%"
        if fetch.isExtracting { return "Unpacking… \(percent)" }
        var parts = [percent]
        if fetch.total > 0 {
            let done = byteFormatter.string(fromByteCount: Int64(fetch.received))
            let total = byteFormatter.string(fromByteCount: Int64(fetch.total))
            parts.append("\(done) of \(total)")
        }
        if let left = fetch.secondsRemaining.map(ProgressCard.formatRemaining) {
            parts.append(left)
        }
        return parts.joined(separator: " · ")
    }
}

/// One row of the tray. This is WeightDownloadOverlay's card, minus its fixed
/// 340pt width (which moves to the container) and minus its own material (nested
/// materials stack and read opaque).
struct ProgressCard: View {
    let item: ProgressItem
    let onAction: (ProgressItem) -> Void

    /// Deliberately coarse. A to-the-second countdown on a multi-minute download
    /// invites the reader to trust a number derived from an average rate.
    static func formatRemaining(_ seconds: Double) -> String {
        switch seconds {
        case ..<10:   return "almost done"
        case ..<90:   return "\(Int(seconds.rounded())) sec left"
        case ..<3600: return "\(Int((seconds / 60).rounded())) min left"
        default:      return "over an hour left"
        }
    }

    /// Coarse for the same reason, and never counts down -- this one is measured.
    static func formatElapsed(_ seconds: Double) -> String {
        switch seconds {
        case ..<60:   return "\(Int(seconds.rounded())) sec"
        case ..<3600: return "\(Int((seconds / 60).rounded())) min"
        default:
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds - Double(hours) * 3600) / 60)
            return "\(hours) hr \(minutes) min"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.caption)
                    .foregroundStyle(item.isError ? .orange : .secondary)
                Text(item.title)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.cancelCommand != nil || item.isError {
                    Button(item.buttonTitle) { onAction(item) }
                        .controlSize(.small)
                        .accessibilityIdentifier("progressTray.action.\(item.id)")
                }
            }
            if !item.isError {
                if item.moving, let fraction = item.fraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                } else {
                    // Honest: the backend reports only that the phase began.
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(item.detail)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityIdentifier("progressTray.card.\(item.id)")
    }
}

/// The container. Bottom-trailing, capped in height, scrolling past the cap.
struct ProgressTray: View {
    let items: [ProgressItem]
    let onAction: (ProgressItem) -> Void

    /// Rendered rows. Bounded so SwiftUI's diff cost cannot grow with n_models.
    private static let maxRows = 8

    private var shown: ArraySlice<ProgressItem> { items.prefix(Self.maxRows) }
    private var overflow: Int { max(items.count - Self.maxRows, 0) }

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        stack
                            // 340 + 2*16 padding = 372, against an iPhone SE's 375pt.
                            .frame(width: min(340, geo.size.width - 32))
                            .background(.ultraThinMaterial,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.secondary.opacity(0.25)))
                            .shadow(radius: 6)
                            // A FRACTION, never a constant: on iOS the tray is
                            // clipped to the viewport, which is far shorter than
                            // the window.
                            .frame(maxHeight: max(140, geo.size.height * 0.45))
                            .padding(16)
                    }
                }
            }
        }
        // Animate insert/remove only -- NOT the 2 Hz fraction tick, which would
        // re-run the transition on every poll.
        .animation(.easeInOut(duration: 0.18), value: items.map(\.id))
        .allowsHitTesting(!items.isEmpty)
    }

    private var stack: some View {
        // Hug one or two cards; scroll past that. Same shape as
        // sceneButtonsOverlay's ViewThatFits, turned vertical.
        ViewThatFits(in: .vertical) {
            rows
            ScrollView(.vertical, showsIndicators: false) { rows }
                // The native scrollbar only appears mid-scroll (#131), so the
                // fade is the resting cue that there is more below. Applied to
                // the SCROLLING branch only -- on the outer view it would fade
                // the hugging branch too.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(shown)) { item in
                ProgressCard(item: item, onAction: onAction)
                if item.id != shown.last?.id || overflow > 0 {
                    Divider().opacity(0.4)
                }
            }
            if overflow > 0 {
                Text("+\(overflow) more")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodegen generate && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/PendingJobTests 2>&1 | tail -30
```

Expected: PASS. `xcodegen generate` is required — the file is new, and `build_macos.sh` never touches the Xcode project.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ProgressTray.swift swiftui/PyMOLViewerTests/PendingJobTests.swift
git commit -m "feat(ui): ProgressTray — a stacked, capped, scrollable card tray

Kind-agnostic rows: each button runs its own cancelCommand verbatim through
runCommand, so the view knows nothing about jobs vs downloads. The container
owns the single material; rows drop theirs, because nested materials stack and
read opaque."
```

---

## Task 9: Rewire `busyOverlay` and delete `WeightDownloadOverlay`

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift:285-305` (`busyOverlay`), `:4410-4528` (delete `WeightDownloadOverlay`)

**Interfaces:**
- Consumes: `ProgressTray`, `ProgressItem` (Task 8); `engine.predictionJobs` (Task 7); the existing `engine.weightsFetch`.

- [ ] **Step 1: Replace the weights branch of `busyOverlay`**

Replace the whole `if let fetch = engine.weightsFetch { WeightDownloadOverlay(...) }` branch with:

```swift
        // #284 + #291. One tray for every non-blocking background job, deliberately
        // NOT gated on isBusy: these run on their own threads, so the app is fully
        // usable while they are on screen. Declared after busyOverlay so the tray
        // stays ABOVE the busy scrim -- `predict` is not in heavyLabel, so a fetch
        // and a `ray` genuinely co-occur and the tray's Cancel must stay hittable.
        ProgressTray(items: ProgressItem.tray(weights: engine.weightsFetch,
                                              predictions: engine.predictionJobs)) { item in
            guard let command = item.cancelCommand else { return }
            engine.runCommand(command)
        }
```

The merge, filter and sort live on `ProgressItem.tray` (Task 8) rather than in a
computed property here, so they are unit-tested without instantiating a View.

- [ ] **Step 2: Delete `WeightDownloadOverlay`**

Delete the entire `struct WeightDownloadOverlay: View { ... }` (ContentView.swift:4423-4528). Leaving it would pin two independently bottom-trailing cards in the same 16 pt corner. `formatRemaining` and the byte formatter now live on `ProgressCard` / `WeightDownloadDetail`.

- [ ] **Step 3: Retarget the surviving test**

In `swiftui/PyMOLViewerTests/WeightsFetchStateTests.swift`, change every `WeightDownloadOverlay.formatRemaining(` to `ProgressCard.formatRemaining(`. Change nothing else — its verbatim `WEIGHTS:` payload captures still pin that wire, which this plan does not touch.

- [ ] **Step 4: Build and test both slices**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodegen generate && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -30
```

Expected: PASS, whole suite.

Then compile the iOS slice by hand — **no CI does this**, and `ContentView.swift`'s shared region has leaked platform-only symbols in both directions three times (#174, #226, #238):

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodebuild build -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewerTests/WeightsFetchStateTests.swift
git commit -m "feat(ui): route weight downloads and predictions into one progress tray

WeightDownloadOverlay is deleted rather than left alongside -- two independently
bottom-trailing cards would collide in the same corner. The bundle filter stops a
cold-cache run showing two cards for the same download."
```

---

## Task 10: Retain terminal records so a failure sticks

**Files:**
- Modify: `modules/pymol/predicting.py` (`_RECENT`, `discard_pending`, `deliver_result`, `pending_objects`)
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Produces: `_RECENT` dict; `pending_info` returns records for retained terminal jobs too.

- [ ] **Step 1: Write the failing test**

Append to `TestPendingInfo`:

```python
    def testAFailedJobIsRetainedWithItsErrorAfterThePlaceholderGoes(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'out of memory'}]])
        self.predicting.pending_info('boom', _self=self.cmd)   # observe it once
        self.predicting.discard_pending('boom', _self=self.cmd)
        info = self.predicting.pending_info('boom', _self=self.cmd)
        self.assertIsNotNone(info, 'a failed job must survive its placeholder')
        self.assertEqual(info['state'], 'failed')
        self.assertEqual(info['error'], 'out of memory')

    def testASuccessfulJobIsNotRetained(self):
        self.register('ok', [[{'state': 'done', 'phase': 'done', 'fraction': 1.0}]])
        self.predicting.pending_info('ok', _self=self.cmd)
        self.predicting.discard_pending('ok', _self=self.cmd)
        self.assertIsNone(self.predicting.pending_info('ok', _self=self.cmd))

    def testRetentionIsCapped(self):
        for index in range(20):
            name = 'boom%d' % index
            self.register(name, [[{'state': 'failed', 'phase': 'inference',
                                   'fraction': 0.0, 'error': 'x'}]])
            self.predicting.pending_info(name, _self=self.cmd)
            self.predicting.discard_pending(name, _self=self.cmd)
        self.assertLessEqual(len(self.predicting._RECENT), 16)

    def testClearPendingDropsRetainedRecords(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'x'}]])
        self.predicting.pending_info('boom', _self=self.cmd)
        self.predicting.discard_pending('boom', _self=self.cmd)
        self.predicting.clear_pending()
        self.assertEqual(self.predicting._RECENT, {})
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL — `pending_info` returns `None` after discard.

- [ ] **Step 3: Add `_RECENT` and capture on discard**

Beside `_TRACK`:

```python
#: name -> the last record of a job that ended badly, held so the card can say
#: WHY an eleven-minute run produced nothing. Success is not retained: the loaded
#: object is its own confirmation. Capped, oldest-first, so a scripted loop of
#: failures cannot grow it without bound.
_RECENT = {}

#: How many terminal records to hold.
MAX_RECENT = 16
```

In `discard_pending`, before the existing `_PENDING.pop(name, None)`:

```python
    # Capture BEFORE the pop: this is the only moment the record still exists and
    # we already know the outcome. Uses the last observed record rather than
    # re-reading status(), because Swift's cleanup may already have removed the
    # status file by the time the poll gets here.
    last = _LAST_INFO.pop(name, None)
    if last is not None and last.get('state') in ('error', 'failed', 'cancelled'):
        while len(_RECENT) >= MAX_RECENT:
            _RECENT.pop(next(iter(_RECENT)))
        _RECENT[name] = last
```

- [ ] **Step 4: Remember the last observed record**

Beside `_RECENT`:

```python
#: name -> the most recent pending_info() result, so discard_pending can retain a
#: terminal one without re-reading a status file that may already be gone.
_LAST_INFO = {}
```

In `pending_info`, immediately before `return info`:

```python
    _LAST_INFO[name] = info
```

and at the top of `pending_info`, replace the early return so retained records surface:

```python
    job_ids = _PENDING.get(name)
    if not job_ids:
        return _RECENT.get(name)
```

In `clear_pending`, alongside the `_TRACK.clear()` added in Task 4:

```python
    _RECENT.clear()
    _LAST_INFO.clear()
```

- [ ] **Step 5: Include retained names in the poll**

In `appkit_inspector._pending_maps`, replace `names = predicting.pending_objects()` with:

```python
        names = list(predicting.pending_objects())
        names += [n for n in predicting.recent_objects() if n not in names]
```

and add to `predicting.py`, beside `pending_objects`:

```python
def recent_objects():
    """Names whose job ended badly and whose card is still waiting to be seen."""
    return list(_RECENT)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run the Python test command. Expected: PASS, 165 total.

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/predicting.py modules/pymol/appkit_inspector.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): retain a failed job's record so its card can say why

Success is not retained -- the loaded object is its own confirmation. Capture
happens on discard, from the last observed record rather than a re-read, because
Swift's cleanup may already have removed the status file."
```

---

## Task 11: `predict_dismiss`

**Files:**
- Modify: `modules/pymol/predicting.py` (new function at the end, before `_job`), `modules/pymol/api.py:31-39`, `modules/pymol/keywords.py:204-211`, `modules/pymol/completing.py:87-118`
- Test: `testing/tests/predict/predict_progress.py`

**Interfaces:**
- Produces: `predict_dismiss(name='', quiet=1, _self=cmd)`; completer `_pending_card_shortcut()`.

- [ ] **Step 1: Write the failing test**

Append to `TestPendingInfo`:

```python
    def testDismissRemovesARetainedCard(self):
        self.register('boom', [[{'state': 'failed', 'phase': 'inference',
                                 'fraction': 0.0, 'error': 'x'}]])
        self.predicting.pending_info('boom', _self=self.cmd)
        self.predicting.discard_pending('boom', _self=self.cmd)
        self.cmd.predict_dismiss('boom')
        self.assertIsNone(self.predicting.pending_info('boom', _self=self.cmd))

    def testDismissWithNoArgumentClearsThemAll(self):
        for name in ('a', 'b'):
            self.register(name, [[{'state': 'failed', 'phase': 'inference',
                                   'fraction': 0.0, 'error': 'x'}]])
            self.predicting.pending_info(name, _self=self.cmd)
            self.predicting.discard_pending(name, _self=self.cmd)
        self.cmd.predict_dismiss()
        self.assertEqual(self.predicting._RECENT, {})

    def testDismissAtQuietZeroDoesNotExplode(self):
        """parsing.py forces quiet=0 for command-line calls; a suite that only
        tests quiet=1 never enters a single message-emitting branch."""
        self.cmd.predict_dismiss('nothing-here', quiet=0)

    def testDismissIsReachableAsACommand(self):
        from pymol import keywords
        self.assertIn('predict_dismiss', keywords.get_command_keywords())
```

- [ ] **Step 2: Run the test to verify it fails**

Run the Python test command. Expected: FAIL with `AttributeError: 'Cmd' object has no attribute 'predict_dismiss'`.

- [ ] **Step 3: Add the function**

In `predicting.py`, before `_job`. Note `_self=cmd` stays last:

```python
def predict_dismiss(name='', quiet=1, _self=cmd):
    """
DESCRIPTION

    "predict_dismiss" clears the retained card for a prediction that failed or was
    cancelled. Success needs no dismissal -- the loaded object is its own
    confirmation and its card retires on its own.

USAGE

    predict_dismiss [ name ]

ARGUMENTS

    name = string: the object whose card to clear. Omit to clear every one.

SEE ALSO

    predict, predict_status, predict_cancel
    """
    pump(_self=_self)
    if name:
        removed = _RECENT.pop(name, None) is not None
    else:
        removed = bool(_RECENT)
        _RECENT.clear()
    if not int(quiet):
        if removed:
            colorprinting.parrot(' predict_dismiss: cleared %s'
                                 % (name or 'all cards'))
        else:
            colorprinting.warning(' predict_dismiss: nothing to clear')
```

- [ ] **Step 4: Wire it into the cmd namespace**

`modules/pymol/api.py` — add to the existing `from .predicting import` continuation block:

```python
from .predicting import \
      predict,              \
      predict_status,       \
      predict_cancel,       \
      predict_dismiss,      \
      predict_result,       \
      predict_weights,      \
      predict_weights_cancel
```

`modules/pymol/keywords.py` — add after the `'predict_cancel'` row:

```python
        'predict_dismiss': [ self_cmd.predict_dismiss , 0 , 0 , ''  , parsing.STRICT ],
```

`modules/pymol/completing.py` — add the completer beside `_predict_job_shortcut`:

```python
def _pending_card_shortcut():
    """Objects with a retained progress card, for predict_dismiss. Never raises."""
    try:
        from pymol import predicting
        return Shortcut(predicting.recent_objects())
    except Exception:
        return Shortcut([])
```

then, in `get_auto_arg_list`, beside the other `aa_predict*` locals:

```python
    aa_predict_card_c = [_pending_card_shortcut, 'object', ', ']
```

and in the 1st-positional dict, after `'predict_cancel'`:

```python
        'predict_dismiss': aa_predict_card_c,
```

- [ ] **Step 5: Run the tests to verify they pass**

Run the Python test command. Expected: PASS, 169 total.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/predicting.py modules/pymol/api.py modules/pymol/keywords.py modules/pymol/completing.py testing/tests/predict/predict_progress.py
git commit -m "feat(predict): predict_dismiss clears a retained failure card

Three-file wiring (api/keywords/completing) because predicting.py carries no
decorators -- api.py's star-import is what makes cmd.predict_dismiss exist."
```

---

## Task 12: End-to-end verification in a disposable VM

The Python and Swift suites cannot prove the tray renders. This task is manual and produces no code.

**Files:** none.

- [ ] **Step 1: Run the full Python suite**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211 && PYMOL_DATA="$PWD/data" PYTHONPATH=/tmp/raymol-shadow /opt/homebrew/bin/pymol -ckqy testing/testing.py --run testing/tests/predict 2>&1 | tail -10
```

Expected: `OK`, 169 tests, 0 failures.

- [ ] **Step 2: Run the full Swift suite and build both slices**

```bash
cd /Users/jcastellanos/repos/RayMol/.claude/worktrees/laughing-hopper-459211/swiftui && xcodegen generate && xcodebuild test -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -20 && xcodebuild build -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation 2>&1 | tail -10
```

Expected: both succeed.

- [ ] **Step 3: Drive the app in a VM**

Use the `raymol-mac-vm` skill. Verify each of these and capture a screenshot of each:

1. **Warm-cache predict** — `predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ`. One card appears: "Predicting …", **indeterminate** bar, phase name, a ticking elapsed clock. Close the object panel: the card stays.
2. **`n_models=3`** — one card reading `model 1 of 3`, advancing to `2 of 3`. Its Cancel stops the whole prediction, not one model.
3. **Cold cache** — delete the weight cache first. Only the weights card shows during the download, with its measured bytes/total bar; the prediction card appears when the fetch completes. **Never two cards for the same download.**
4. **Failure** — `predict boltz2, <a 9000-residue sequence>` to trip `PredictSizeGuard`. An orange error card appears with the refusal text and a **Dismiss** button; Dismiss removes it. Before Task 1 this produced nothing at all.
5. **Overflow** — submit enough jobs to exceed 8 cards. The tray scrolls, the bottom edge fades, and the footer reads `+N more`.
6. **Non-blocking** — while a prediction runs, rotate the structure and load another file. Both must work; no scrim ever appears.

- [ ] **Step 4: Open the PR**

```bash
git push -u origin claude/issue-295-review-ac2a7c
gh pr create -R javierbq/RayMol --base master --title "feat(predict): ambient progress tray for running predictions (#291)" --body "$(cat <<'EOF'
Implements increments 0-2 of the design.

## What changed
- `Predictor` gains `progress_phases` + a concrete `progress()`. `base.py` names no
  phases; boltz2's table lives in `boltz2.py`.
- `pending_info()` folds per-phase fractions into one monotone per-object bar,
  reading one status file per pending object per tick.
- A new `ProgressTray` renders weight downloads and predictions as stacked cards
  in one capped, scrollable container. `WeightDownloadOverlay` is deleted.
- A failed prediction now says why. All six bad-exit paths wrote the terminal
  status *after* discarding the placeholder, so the error landed after the map
  observing it was gone.

## Not in this PR
Measured diffusion-step progress (increment 3) needs an upstream `boltz-mlx`
v0.1.2 tag. Until then the inference phase draws an honest indeterminate bar
rather than an interpolated guess. `boltz2.py` already declares the `trunk` and
`diffusion` bands, so that increment is Swift-side only.

## Testing
- `testing/tests/predict`: 169 passed, 0 failed
- `UnitTests_macOS`: passed
- iOS slice hand-compiled (no CI does)
- Manually verified in a disposable macOS VM: warm/cold cache, n_models=3,
  per-card Cancel, failure card + Dismiss, tray overflow scrolling, and that the
  app stays interactive throughout

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Notes

**Spec coverage.** §4.1 → Task 2. §4.2 → Task 3. §4.3 → Task 3. §4.4 → Task 3. §5.2 → Tasks 4, 5, 7. §5.4 → Tasks 6, 9. §6.1 → Task 1. §6.2 → no code (documented in the spec so the malformed-request path is not "fixed" by mistake). §6.3 → Tasks 10, 11. §6.4 → Task 7 (`isError` accepts both). §6.5 → Task 4 (`_TRACK['floor']`) and Task 8 (card branches on state). §6.6 → Tasks 2, 4, 5. §7.1–7.3 → Tasks 8, 9. §8 → every task. §9 increments 0–2 → Tasks 1–11. §9 increments 3–4 → out of scope, stated above.

**Deviations from the spec, both discovered while writing exact steps:**

1. **The spec says the card's button calls `engine.runProgressCommand(...)`. That method does not exist** — the engine's surface is `runCommand(_:)` and `runPython(_:)`. Task 9 uses `runCommand`, which is also what `cancelWeightsDownload` documents as the correct route.
2. **The spec treats increment 0 as a pure line swap. It cannot be tested as one** — `discardPlaceholder` is `private static` and dispatches through `PyMOLEngine.shared`, so a unit test cannot observe it. Task 1 therefore introduces a single `settle` helper with a `#if DEBUG` tap, which is both testable and removes the possibility of a seventh site getting the order wrong.

3. **The spec's dedup filter could not have worked as described.** It says "a prediction item whose `bundle` matches a live weights item is dropped", but nothing in the spec ever populates `bundle` on a prediction. Task 4 now reports it from the job's `_bundle` (only while `_real is None`, i.e. still deferred), and the merge/filter/sort moved from a `ContentView` computed property onto `ProgressItem.tray(weights:predictions:)` so it is unit-testable without instantiating a View.

**Deliberate deferral.** The spec's 5-second "done" card (§6.3) is **not** implemented here: `_RECENT` retains only `error`/`cancelled`. That is spec open question 6, which is still open, and the tray reads correctly without it — a finished prediction's card simply disappears as its object appears populated in the panel. Adding it later is a one-line change to the retention predicate plus a TTL sweep.

Items 1–3 should be corrected in the spec when this lands.
