# Progress reporting for structure prediction

Status: **approved design, not yet implemented**. Branch `claude/issue-295-review-ac2a7c`.

Closes the presentation half of #291 and the "running jobs are invisible" bullet of #288.
Builds on [the prediction backend design](2026-08-11-structure-prediction-backend-design.md).

---

## 1. The problem, measured

A prediction runs for minutes. From [`docs/predict-benchmark-boltz2-m3pro.csv`](../../predict-benchmark-boltz2-m3pro.csv)
(M3 Pro, Release, boltz-mlx v0.1.0, 200 diffusion steps): 600 residues is **675 s of inference**
against a ~10 s one-time model load and sub-millisecond featurization. `n_models` fans that out to
up to 20 jobs (`MAX_MODELS = 20`, `predicting.py:53`).

During all of it the app shows: a greyed-out enable toggle (`ObjectPanel.swift:2058`) and
`.help(entry.pendingDetail ?? "")` — a macOS-only hover tooltip (`ObjectPanel.swift:2196`).

The `fraction` those consumers read takes five values, written at phase boundaries in
`BoltzJobManager.run`: `0.0 featurize → 0.1 load → 0.2 inference → 0.95 write → 1.0 done`.

| run | wall clock pinned at fraction 0.2 |
|---|---|
| 600 res, cold cache | 675 s of 685 s — **98.5 %** |
| 600 res, warm (every run after the first) | **~100 %** |

The existing `fraction` is not merely coarse. It is a constant for the duration of the job.
Anything built on today's contract draws a bar that never moves.

A *failed* run shows less than that: nothing at all. See §6.

---

## 2. The crux — boltz2 cannot report progress today

**Verified against the consumed checkout**, `swiftui/build_mac_dd/SourcePackages/checkouts/boltz-mlx`,
git HEAD `d599477` = tag **v0.1.1**:

- `BoltzPredictor.predictScored(featurized:options:)` (`Sources/BoltzMLX/BoltzPredictor.swift:138`)
  takes exactly two parameters. Its body is
  `memoryPlanner.validate/apply → trunk(...) → conditioning(...) → diffusion.sample(...) →
  confidence(...) → structure(...)`, all synchronous, with only `Task.checkCancellation()` between
  stages.
- Zero occurrences of a closure parameter, delegate, `AsyncStream`, Combine publisher, `os_log` or
  `print` anywhere in `Sources/BoltzMLX/`.
- `BoltzPredictor` is an `actor` that never suspends during a prediction, so progress cannot even be
  *pulled* from outside: a watchdog's `await predictor.memorySnapshot()` queues behind the running
  call.
- RayMol's side is one opaque `await` (`BoltzJobManager.swift:331-347`). Everything between
  `report("running","inference",0.2)` (`:309`) and `report("running","write",0.95)` (`:355`) is
  inside it.

The backend design already conceded this in passing —
[":485"](2026-08-11-structure-prediction-backend-design.md): *"the strongest argument for the
progress channel, since none exists in boltz-mlx."*

### 2.1 The upstream patch (`javierbq/boltz-mlx`, tag v0.1.2)

```swift
// Sources/BoltzMLX/Diffusion/AtomDiffusion.swift — sample()
    clearCacheBetweenSteps: Bool = true,
    onStep: ((_ completed: Int, _ total: Int) -> Void)? = nil
  ) throws -> MLXArray

// …as the LAST statement of `for index in 0..<stepCount` (:69), i.e. AFTER
//   MLX.eval(coordinates)                                (:120)
//   if clearCacheBetweenSteps { Memory.clearCache() }     (:121-123)
      onStep?(index + 1, stepCount)
```

```swift
// Sources/BoltzMLX/Trunk/BoltzTrunk.swift — callAsFunction()
    clearCacheBetweenRecycles: Bool = true,
    onRecycle: ((Int, Int) -> Void)? = nil
  ) throws -> TrunkOutput
// `for _ in 0...recyclingSteps` (:55) becomes `for cycle in ...`;
// emit onRecycle?(cycle + 1, recyclingSteps + 1) after MLX.eval(sequence, pair) (:72).

// Sources/BoltzMLX/BoltzPredictor.swift — predictScored()
    onProgress: (@Sendable (BoltzProgress) -> Void)? = nil
// adapted into the trunk(...) and diffusion.sample(...) call sites.
// @Sendable because BoltzPredictor is an actor under swift-tools-version 6.0.
```

Every added parameter is default-nil and appended last, so `BoltzJobManager.swift:345`,
`BoltzMLXCLI`, the demo app and all upstream tests compile unchanged. The RayMol pin is
`from: 0.1.1` (`swiftui/project.yml:37-39`) — a **range** — so tagging v0.1.2 is picked up by
re-resolution and only `Package.resolved` moves. boltz-mlx's `exact: "0.31.6"` mlx-swift pin, shared
with MPNNKit, is untouched.

**Placement is the entire correctness argument.** MLX is lazy; a callback is truthful only where an
`eval` has forced materialization. Exactly two loops qualify: diffusion (`MLX.eval(coordinates)`,
`AtomDiffusion.swift:120`) and recycling (`MLX.eval(sequence, pair)`, `BoltzTrunk.swift:72`). The
64-block Pairformer loop (`Pairformer.swift:84-86`) has **no** eval and must **not** be
instrumented — it would fire 64 callbacks in milliseconds and then stall.

⚠️ The local clone at `~/repos/boltz-mlx` is at `ec4cc94`, two commits behind the consumed
`d599477`, and predates `StructureWriter.swift` and the pLDDT head. Branching from it authors the
patch against the wrong code.

### 2.2 The honest fallback, and the one place fabrication would live

Until v0.1.2 lands, inference gets a **zero-span band**: `('inference', 0.10, 0.10)`. `progress()`
returns `moving=False` and the card draws an **indeterminate** bar plus a live elapsed clock and the
phase name.

Stated plainly: **the 0.2→0.95 dead zone is the one place progress could be fabricated, and this
design refuses to fabricate it.** Wall-clock interpolation there would rest on two end-to-end
datapoints taken at 20 and 50 diffusion steps against a default of 200, with no instrumented
per-phase profile anywhere in the repo. A bar that creeps on a guess and then parks at 95 % for four
minutes is worse than a spinner that is honestly a spinner.

Weight-download progress is genuinely measured today (bytes / total) and stays measured.

---

## 3. Architecture — pull, with the one existing push left alone

**Decision: pull.**

- Python→Swift push does not exist. Zero `@_cdecl` / `@convention(c)` in the app; `PyMOLBridge.h` is
  one-directional by construction ([backend design §"There is no Python→Swift call
  path"](2026-08-11-structure-prediction-backend-design.md)). A Python-side listener API would be a
  callback that can never fire for the one predictor that matters.
- The pull cadence already exists and is ungated: `feedbackTimer` at 100 ms
  (`PyMOLEngine.swift:686`), `pollObjects` on every 5th tick (`:3133-3137`) → `poll_panel()` →
  `predicting.pump()`. 500 ms is invisible against a job measured in minutes.
- One source of truth. The tooltip, `predict_status` and the tray all read the same number and
  cannot drift — which is exactly what a second in-process Swift sink would risk.

**Where the line falls.** Weight-download progress stays **push** on its existing `WEIGHTS:` marker
(`fetching.py:33`, `_emit` at `:261-281`), because it originates on a Python worker thread that may
`print`. That wire, `WeightsFetchState`, and `WeightsFetchStateTests`' verbatim-capture pins are
**not touched**. Prediction progress is **pull**, riding the object panel's existing tempfile
payload. Both feed one tray; mixed cadence (150 ms downloads, 500 ms predictions) needs no
coordination.

**Inside inference the architecture *is* a listener** — the boltz-mlx `onStep` closure — because
nothing else can work there. Pull vs push is a question about the job→pixel hop, not about the
diffusion loop.

Two consequences accepted: the prediction card's elapsed clock advances in half-second steps, and a
cancel takes up to 500 ms to remove its card.

---

## 4. The `Predictor` base-class extension

`Predictor` (`predictors/base.py:99-144`) is four class attributes, three `@abc.abstractmethod`s
(`check_available`, `parse_spec`, `submit`), one concrete method (`validate_options`), no `__init__`,
no instance state, no declared job type. It is a public extension point documented in
[`docs/predictors.md`](../../predictors.md) and `_template.py`.

**A new `@abc.abstractmethod` would break every shipped and third-party predictor.** The addition is
therefore a class attribute plus a concrete method — the shape `validate_options` already
established.

### 4.1 Module level, `base.py`

`base.py` declares the **mechanism only**. It names no phases: phase names are a property of a
backend's pipeline, not of the infrastructure. `trunk` and `diffusion` are Boltz/AlphaFold-family
architecture terms — a single-forward-pass or server-backed predictor has neither — so they live in
`boltz2.py` (§4.3), not here.

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
#: THROUGH IT, never about time remaining. That is why the card shows a measured
#: elapsed clock beside it, and why an ETA (increment 4) must be derived from an
#: observed per-step rate and never from these numbers.


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
    MUST NOT raise. A fraction outside [0, 1] is clamped before it is mapped
    into its band.
    """
```

Two phase families are deliberately absent from every table:

- **`queued`.** `HostJob.status()`'s missing-file fallback reports it (`host.py:59-67`); mapping it to
  zero would slam the bar back to 0 % for every tick between submit and Swift's first status write.
- **`download` / `extract`.** The weight fetch is not part of the prediction's bar. §7.3's dedup
  filter already hides a prediction card while its bundle is downloading — the user sees the weights
  card, which has its own genuinely measured bytes/total bar. Including the fetch here would leave a
  warm-cache run (i.e. every run after the first) starting its bar at ~25 %, with a quarter of it
  dead.

Both fall through to unrecognised → `(None, False)` → hold the previous value, which is exactly right
for a window in which this card either is not on screen or has nothing to say.

### 4.2 On `class Predictor`

```python
    #: This predictor's pipeline phases, ordered. EMPTY BY DEFAULT on purpose:
    #: the base class makes no claim about anyone's pipeline. A predictor that
    #: declares nothing gets an indeterminate card with a live elapsed clock --
    #: the correct rendering of no information, and far better than a bar
    #: derived from some other backend's phase names.
    progress_phases = ()

    def progress(self, status):
        """Overall progress for one of this predictor's jobs: (fraction, moving).

        CONCRETE, like validate_options -- never abstract. This class is a public
        extension point and a new @abc.abstractmethod would break every predictor
        already written against it.

        `status` is exactly what job.status() returned. This DERIVES from it and
        never stores a second copy, so status()['fraction'] stays the single
        source of truth and the two cannot drift.

        Never raises.
        """
        return compose_progress(status, self.progress_phases)
```

Because `progress()` is concrete rather than abstract, it doubles as the **escape hatch**: a backend
the band table genuinely cannot express — say, one whose phase set depends on whether an MSA was
supplied — overrides `progress()` and returns its own `(fraction, moving)`. The class attribute is
the easy path; overriding is the general one. This is the same property that forced it to be
concrete in the first place.

`submit`'s one-line docstring (`base.py:133-134`) is replaced, because it and `_template.py` are the
only normative statements of the job contract:

```python
    @abc.abstractmethod
    def submit(self, spec, options, weights_path):
        """Start the run and return a job handle immediately. MUST NOT BLOCK.

        The handle must expose: job_id, status(), cancel(), spec.

        status() returns a dict whose 'phase' is a short string and whose
        'fraction' is completion WITHIN that phase, in [0, 1] -- not a global bar.
        Keys may be absent; every caller uses .get() with a default. The app turns
        (phase, fraction) into one monotone overall bar through this predictor's
        progress_phases, so a per-phase fraction that restarts at each phase
        boundary is correct and expected.
        """
```

### 4.3 boltz2's table, in `boltz2.py`

```python
class Boltz2Predictor(Predictor):
    #: 'inference' is the coarse phase the host writes today, and it is zero-span
    #: because boltz-mlx v0.1.1 reports nothing from inside predictScored. 'trunk'
    #: and 'diffusion' replace it once v0.1.2's per-step callbacks land -- they are
    #: declared from day one so that increment is a Swift-side change only, with no
    #: rename and no Python edit here.
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

`inference` overlapping `trunk`/`diffusion` is intentional and not a sequence: they are alternative
names for the same span, and exactly one of the three is ever the current phase.

The mechanism generalizes past diffusion. Three backends this repo does not have yet, expressed in
the same vocabulary:

| backend shape | table | what the user sees |
|---|---|---|
| single opaque forward pass (ESMFold-like) | `(('forward', 0.0, 0.0), ('write', 0.9, 1.0))` | spinner + elapsed for the whole run, then a brief finish — the accurate rendering, not a degraded one |
| server-backed | `(('upload', 0.0, 0.10), ('queued', 0.10, 0.10), ('running', 0.10, 0.85), ('fetch', 0.85, 1.0))` | measured, then an honest park while in someone else's queue, then measured again |
| sampler over N trajectories | `(('sample', 0.05, 0.95),)` with `fraction = completed / N` | a real bar; nothing diffusion-specific |

### 4.4 `_template.py`

The copy-me template (`predictors/_template.py:58-66`) is the highest-leverage edit in the change:
without it, no third-party predictor will ever report progress. Its `submit` docstring gains the
paragraph above, and the class gains a declaration — **not** commented out, because the base default
is empty and a predictor that leaves this alone gets no bar:

```python
    # Progress bands: YOUR pipeline's phases, not anyone else's. The base class
    # declares none, so a predictor that leaves this empty shows an indeterminate
    # spinner and an elapsed clock -- which is correct when you have nothing to
    # report, and wrong if you do. Give a phase a non-empty band ONLY if your
    # backend really reports movement inside it; a zero-span band is how you say
    # "started this phase, cannot say how far in", and the app draws the spinner
    # instead of a bar that lies.
    #
    # Widths are LAYOUT, not a time estimate -- see compose_progress in base.py.
    progress_phases = (('setup', 0.00, 0.10),
                       ('sample', 0.10, 0.95),
                       ('write', 0.95, 1.00),
                       ('done', 1.00, 1.00))
```

A predictor that deletes the declaration rather than editing it still degrades safely: an empty table
yields `(None, False)` for every phase, so the card is an indeterminate spinner with a live elapsed
clock. It can never show a *wrong* bar — only no bar. `docs/predictors.md` gains a step between the
current 7 and 8 saying, in one line, "declare your phases or your users get a spinner."

---

## 5. Data flow

### 5.1 Inference → status file (increment 3 only)

1. `AtomDiffusion.sample` loop body (`:69`): `MLX.eval(coordinates)` → `Memory.clearCache()` →
   `onStep(index+1, stepCount)`, on the actor's cooperative-pool thread.
2. `predictScored`'s adapter → RayMol's `@Sendable` closure at `BoltzJobManager.swift:345`.
3. `StepThrottle.shouldEmit(fraction)` — **0.15 s or 1 % movement**, the policy
   `fetching.py:38-41` already uses.
4. `BoltzJobManager.reportStep(to:phase:fraction:step:totalSteps:)`, a **static** function — *not*
   `run()`'s nested `report`. This is forced, not stylistic: `report` closes over `var peak` and
   `var elapsed` (`:270-271`), and a `@Sendable` closure may not capture mutable locals. It must also
   not `stateQueue.sync` (that queue is entered from the **main** thread on every cancel at `:151`
   and held for the ~10 s model build at `:424-441`) and must not touch MLX.
5. `writeStatus` → encode → sibling `.tmp` → `replaceItemAt` (`:133-139`) →
   `$TMPDIR/raymol_predict_status_<job>.json`.

Without the patch, steps 1–4 are absent and only the existing `report(...)` calls write the file.
Everything downstream is identical.

### 5.2 Status file → pixel

6. `feedbackTimer` (100 ms, `:686`) → `pollObjects` every 5th tick (`:3133-3137`) →
   `runPython("from pymol import appkit_inspector as _ai\n_ai.poll_panel()")`.
7. `poll_panel()` → `predicting.pump()` (already inside its own try, `appkit_inspector.py:479-483`).
8. `_pending_maps()` → for each pending **object**, `predicting.pending_info(name)` →
   `_JOBS[_PENDING[name][0]].status()`. **One status-file read per pending object per tick**, exactly
   as today (`predicting.py:114`) — never per model. This is the invariant `n_models=20` would
   otherwise multiply by 20.
9. job → its predictor → `progress(status)` → `compose_progress` maps e.g. `('diffusion', 0.42)`
   through band `(0.40, 0.97)` → `(0.639, True)`; folded across models as `(done_models + p) / N`;
   clamped to the object's monotone floor.
10. Record lands in `payload['pending_jobs'][name]`; the formatted string still lands in
    `payload['pending'][name]`, whose `Dict[str, str]` type is **unchanged**.
11. `json.dumps` → `$TMPDIR/pymol_objpanel_<pid>.json` → `print('OBJPANEL:ready')`.
12. Next 100 ms tick: `pollFeedback` → `parseObjectPanelFeedback` (`ObjectPanel.swift:3675+`) →
    `PanelPayload` decode, `pending_jobs` **Optional**.
13. `ObjectEntry.pendingDetail` → row tooltip (unchanged); `[PredictionJobState]` →
    `DispatchQueue.main.async` → `if self.predictionJobs != jobs { … }` → `@Published`.
14. `ContentView.busyOverlay` → `ProgressTray` → `ProgressCard` → pixels.

### 5.3 Weight download (wire unchanged)

`WeightCache.ensure`'s `progress('download', f)` (`weights.py:258-260`) on the
`raymol-weights-<id>` daemon thread → `fetching._emit` (throttled) → `print('WEIGHTS:' + json)` →
100 ms `pollFeedback` → `parseWeightsFeedback` → `@Published weightsFetch` → same tray.

### 5.4 Cancel

Card button → `runCommand(item.cancelCommand)` on the main thread (`PAutoBlock` is not safe off-main,
`PyMOLEngine.swift:957-960`) → e.g. `predict_cancel my_pred` → cancels **every** job registered
against that object → `HostJob.cancel()` prints `PREDICT:cancel:<job>` → `pollFeedback` →
`BoltzJobManager.handle(marker:)` → `stateQueue.sync` + `Task.cancel()` → observed at the next
`Task.checkCancellation()` in the diffusion loop (`AtomDiffusion.swift:70`). Coarser during
featurization and the trunk, which have no cancellation points today (see open question 5).

---

## 6. Failure and terminal states

### 6.1 The ordering bug — this blocks everything else

`discardPlaceholder` injects `_p.discard_pending(<name>)`, which pops `_PENDING` — the map every
Python-derived progress view is built from. **Six** exit paths record the failure *after* deleting
the thing that observes it:

| line | path | order today |
|---|---|---|
| `:181` | preflight refusal | `discardPlaceholder` → `writeStatus(failure)` |
| `:295-296` | unsupported input | `discardPlaceholder` → `report("failed","featurize")` |
| `:303-304` | post-featurize cancel | `discardPlaceholder` → `report("cancelled")` |
| `:352-353` | post-inference cancel | `discardPlaceholder` → `report("cancelled")` |
| `:368-369` | `catch is CancellationError` | `discardPlaceholder` → `report("cancelled")` |
| `:371-372` | `catch` | `discardPlaceholder` → `report("failed","inference")` |

**No progress UI of any shape can show a user why an 11-minute run produced nothing until this is
swapped.** The fix is to write the status first and discard second on all six. `report`/`writeStatus`
is a synchronous atomic file write and `discardPlaceholder` is an async `runPython` hop to the main
queue, so swapping introduces no race — it only guarantees the file is on disk before the observer is
torn down.

`report("done", …)` after `loadResult` stays as-is, deliberately: `predict_status` returning `done`
must already imply the object is populated.

### 6.2 The seventh path — the opposite bug

The malformed-request `catch` (`BoltzJobManager.swift:165-176`) writes a `failed` status and
**never** discards. The placeholder therefore stays in `_PENDING` forever, and today the object panel
shows a pending row that never resolves. Under this design that becomes the *correct* shape — a
retained error is what we want — provided the card branches on `state` before `fraction` (§6.5). No
code change; it is called out so it is not "fixed" by mistake.

### 6.3 Terminal retention

Matching the approved policy — **success fades, failure sticks**:

`discard_pending(name)` gains a capture step: before popping `_PENDING[name]`, if the job's status is
terminal-bad, stash the final record in `_RECENT[name]`. `deliver_result`'s `finally` stashes a
`done` record when the last slot retires. `_pending_maps()` emits `pending_jobs` from `_PENDING`
**and** `_RECENT`.

- `error` / `cancelled`: held until dismissed, backstopped at 30 minutes.
- `done`: held 5 s with a checkmark, then evicted — so rows do not reflow under the reader's eye
  mid-glance. It announces nothing new; the object is already in the panel.

`_RECENT` is capped at 16 entries, oldest-first eviction, cleared by `clear_pending()`.

Dismissal is a new exported command, `predict_dismiss <name>`, which the card's Dismiss button runs
(and which is independently useful from scripts).

### 6.4 Vocabulary

Swift writes `failed` (`BoltzJobManager.swift:296`, `:372`); `_DeferredJob` writes `error`
(`predicting.py:233`). **Neither wire is migrated.** The single consumer treats both as the error
state — `isError { state == "error" || state == "failed" }` — and `predict_result`'s `!= 'done'` gate
(`predicting.py:661`) is untouched.

### 6.5 State before fraction

The card branches on `state` first, never on `fraction`. Every terminal-bad path in Swift resets
fraction to 0, and `HostJob.cancel()` is fire-and-forget (`host.py:78`), so a cancelled job keeps
reporting its last written status until Swift notices.

`pending_info` additionally clamps the composed fraction to a **per-object monotone floor** (one
float in `_TRACK[name]`, retired with the record). Bands make monotonicity *meaningful*; the clamp
makes it *guaranteed* against phase-table drift, the `queued` fallback, and cancel resets.

### 6.6 Never-raise, at four levels

`poll_panel`'s single outer `except` writes **no file at all**, so a throw freezes the whole object
panel on a stale list (`appkit_inspector.py:441-445`, `:528-529`).

1. `compose_progress` is total: unknown phase, missing key, non-numeric fraction → `(None, False)`.
   One scan of a short tuple (7 entries for boltz2), no I/O.
2. `pending_info` wraps `status()`, the composition **and** the arithmetic in one `try`. This closes
   a live crash path: today's `pending_detail` guards only `job.status()` (`predicting.py:118-121`)
   and leaves `status.get(...)` / `int(float(fraction) * 100)` at `:122-124` unguarded. On failure it
   returns a minimal running record rather than dropping the card.
3. `_pending_maps` keeps the existing double guard: per-name `try` inside a module-level `try`
   returning `({}, {})`. `pump()` keeps its per-job try and its `colorprinting.warning`.
4. Swift decodes tolerantly. `pending_jobs` is Optional, so an older bundled Python decodes fine and
   the tray simply shows no prediction cards. Every nested field except `state` and `phase` is
   Optional, so a partial record cannot fail the **whole** `PanelPayload` decode and take the object
   list with it. `parseObjectPanelFeedback` / `parseWeightsFeedback` stay decode-or-return.

### 6.7 Torn reads

`HostJob.status()` already degrades a half-written or empty file to `queued` rather than raising, and
`writeStatus` is atomic. Increments 1–2 do not change write frequency at all. Increment 3 raises it
to at most ~7/s, throttled and still atomic; `report`'s `try?` still swallows a failed write, and a
lost one is superseded within 150 ms.

---

## 7. UI — one tray, one generalized card

### 7.1 Container — new, `swiftui/PyMOLViewer/Shared/ProgressTray.swift`

Platform-neutral, **no `#if os(macOS)`** — the reasoning already written at
`PyMOLEngine.swift:3074-3078` for the `WEIGHTS:` branch: gating the UI here would leave iOS silently
frozen the day a bundle downloads there. Picked up automatically by xcodegen
(`project.yml` globs `path: PyMOLViewer`); **no project.yml edit**. Its own top-level file
because `ContentView.swift` is 4547 lines and already split to stay under the type-checker budget
(`:402-405`).

- Attached at the two existing sites, unchanged: `ContentView.swift:490` (macOS window VStack) and
  `:2356` (iOS `viewportView`). No re-anchoring, no `zIndex` (the app has none).
- Replaces **only** the `if let fetch = engine.weightsFetch` branch of `busyOverlay` (`:292-297`).
  `CalculatingOverlay` (`:286-288`) and the design-mode branch (`:301-303`) are untouched — that
  branch's `!engine.isBusy` term exists solely to stop two 0.45 scrims stacking.
- Declaration order keeps the tray **above** the busy scrim. This is load-bearing: `predict` is not
  in `heavyLabel` (`PyMOLEngine.swift:944-952`), so a fetch and a `ray` genuinely co-occur and the
  tray's Cancel must stay hittable.
- **No scrim, ever.** A scrim is a truth claim that the main thread is blocked
  (`ContentView.swift:4420-4422`). Nothing in the tray blocks it.
- `GeometryReader` → bottom-trailing, `.padding(16)`. Width `min(340, geo.size.width - 32)`
  (340 + 32 = 372 against an iPhone SE's 375 pt). Height cap `max(140, geo.size.height * 0.45)` — a
  **fraction, never a constant**, because on iOS the tray is clipped to the viewport and the Movie
  tab already caps its panel at 72 % of screen (`ContentView.swift:1593`).
- `ViewThatFits(in: .vertical)`: hug for one or two cards, else a `ScrollView` at the capped height
  with a vertical `LinearGradient` edge-fade `.mask`. This is `sceneButtonsOverlay`'s pattern
  (`ContentView.swift:901-935`) turned vertical, including its #131 rationale — the native scrollbar
  only appears mid-scroll, so the fade is the resting affordance that the tray scrolls.
- **The container owns the single `.ultraThinMaterial`**, radius-10 `RoundedRectangle`,
  `.strokeBorder(.secondary.opacity(0.25))`, `.shadow(radius: 6)` — chrome lifted from
  `ContentView.swift:4520-4526`. Rows drop their own material: nested materials stack and read
  opaque.
- `.animation(.easeInOut(duration: 0.18), value: items.map(\.id))` — animates insert/remove only,
  never the 2 Hz fraction tick. (Today's `.transition` at `:4484` never plays because nothing wraps
  the assignment; this fixes it as a side effect.)
- At most 8 rows, sorted running → error → recently-done, with a "+N more" footer, so SwiftUI's diff
  is bounded independently of publisher behaviour.
- **No `accessibilityIdentifier` on the container** — SwiftUI propagates a container identifier to
  every descendant and would shadow the per-card ids, the bug documented verbatim at
  `WhatsNewModal.swift:66-69`. Per-row `progressTray.card.<id>` / `progressTray.cancel.<id>`; the
  tray itself is found via the env-gated invisible sentinel pattern (`ContentView.swift:2349-2353`).

### 7.2 Card — reused

`ProgressCard` is `WeightDownloadOverlay.card` (`ContentView.swift:4487-4527`) lifted essentially
verbatim: icon + title + `Spacer` + Cancel/Dismiss on the title row, then the `ProgressView`, then
one `.caption2` `.secondary` `lineLimit(2)` detail line; 12/10 padding, `.subheadline`/`.medium`
title.

Changed:

- `.frame(width: 340)` is **removed** — it moves to the container. The reason it was fixed (an
  unbounded `Spacer` in the title row, `:4435-4438`) is now bounded one level up.
- `ProgressView(value:)` when `item.moving`, bare indeterminate `ProgressView()` otherwise.
- Icon, title, detail and button action injected from the item, not hardcoded.
- `.primary` / `.secondary` only. It does **not** adopt `CalculatingOverlay`'s hardcoded
  `.foregroundStyle(.white)` (`:4541`), a latent contrast bug on the Paper and Dawn light themes.
- `formatRemaining` moves across unchanged and stays `static`, so
  `WeightsFetchStateTests.swift:121-128` keeps applying (retargeted to `ProgressCard`).
  `formatElapsed` joins it, equally coarse and equally static.

Newly written: `ProgressTray`, the `ProgressItem` adapter, `formatElapsed`. `struct
WeightDownloadOverlay` is **deleted** — leaving it in place would put two independently
bottom-trailing-pinned cards in the same 16 pt corner.

Theme: inherited indirectly from the app-level `.preferredColorScheme` + `.tint` already applied
above both attach sites (`:561-562`, `:1341-1342`). No `PanelTheme` adoption — it is file-private to
`ObjectPanel.swift`; deferred as a separate, purely visual PR.

### 7.3 The item model, and how the weights card joins

```swift
struct ProgressItem: Identifiable, Equatable {
    let id: String              // "weights:boltz2-mlx-int8" | "predict:<object>"
    let icon: String            // SF Symbol
    let title: String
    let detail: String
    let fraction: Double?       // nil, or ignored, when !moving
    let moving: Bool
    let isError: Bool
    let buttonTitle: String     // "Cancel" | "Dismiss"
    let cancelCommand: String?  // the PyMOL command this card's button runs
    let bundle: String?         // set on a prediction still waiting on this fetch

    static func weights(_ f: WeightsFetchState) -> ProgressItem
    static func prediction(_ j: PredictionJobState) -> ProgressItem
}
```

`busyOverlay` builds `items` from `engine.weightsFetch` (source unchanged) plus
`engine.predictionJobs`, then applies **one filter**: a prediction item whose `bundle` matches a live
weights item is dropped. That is what stops a cold-cache run showing two cards for the same download
at two different percentages.

Each card's button runs `item.cancelCommand` verbatim through `runCommand`, so Swift knows nothing
about job kinds and the per-card Cancel is correct by construction.

Copy:

| state | icon | bar | detail |
|---|---|---|---|
| weights | `arrow.down.circle` | determinate | `29% · 154.1 MB of 529.3 MB · 4 min left` (pixel-identical to today) |
| predicting, pre-v0.1.2 | `atom` | **indeterminate** | `Running inference · model 2 of 5 · 4 min elapsed` |
| predicting, post-v0.1.2 | `atom` | determinate | `Diffusion step 84 of 200 · model 2 of 5 · 3 min elapsed` |
| error | `exclamationmark.triangle.fill`, orange | none | the error text; button reads **Dismiss** |

---

## 8. Testing

Load-bearing assertions live on the **Python** side: no `.github/workflows` file invokes
`xcodebuild`, so the Swift suite is a local-only net.

### 8.1 Python — `testing/tests/predict/predict_progress.py` (new)

Named `predict_*`, **not** `test_*`: `testing/testing.py:691-695` routes any `test_*` stem to
`pytest.main()` instead of the unittest loader. Placed in `testing/tests/predict/`, which is listed
as a directory in CI's hand-enumerated path list
(`.github/workflows/raymol-embedded-tests.yml:76`), so a new file inside it runs automatically —
anywhere else is silently orphaned.

Seams reused: `predict_api.install_stub` (`:72-95`) — `check_available` returns `None`, so
`RAYMOL_PREDICT_HOST` is bypassed; `predict_weights_async.GatedResponse` (`:36-68`) to hold a
download at a chosen fraction; `captured_markers` (`:71-106`) for marker assertions against stdout,
**not** `cmd._get_feedback()`, which passes vacuously headless; `predict_boltz2`'s zero-Swift pattern
(`:126-131`) of writing a sequence of status JSONs to `job.status_path` and reading them back through
`HostJob.status()`.

A new `ProgressStubJob` with a **scripted** fraction sequence and a `status_calls` counter is defined
in the new file. `predict_api.StubJob.status` (`:57-59`) is a fixed terminal value that ~15 tests
assert on and is **not** modified.

1. **O(pending)** — 5 counting jobs against ONE placeholder, `poll_panel()`, assert
   `status_calls == 1`. Then 3 objects × 4 jobs → 3. Then unchanged with 200 non-pending objects.
   This pins the budget stated at `appkit_inspector.py:508-514` and is the guard rail against the
   obvious wrong turn.
2. **Monotonicity** across the real cold-cache sequence (download 0→1.0, extract 0.333/0.667/1.0,
   `queued` 0.0, featurize, load, inference, write, done): the composed value never decreases. This
   **fails against today's raw fraction at two points**, which is why it is worth writing.
3. Cancel does not regress (inference 0.2 then cancelled 0.0).
4. Unknown phase → `(None, False)`; zero-span phase → `moving == False`.
5. Malformed status (`fraction='x'`, `fraction=None`, `{}`, `status()` raising) never raises out of
   `pending_info`, `pending_detail`, `_pending_maps` or `poll_panel`.
6. `pending_detail` keeps its documented prefix — guards
   `predict_weights_async.py:201-202`'s `startswith('pending: download')` and
   `predict_autoload.py:222-228`.
7. `pending_info` folds models: 3 jobs, one delivered → `model 2 of 3`, fraction `(1+p)/3`.
8. Payload shape — read `pymol_objpanel_<pid>.json`; `pending` is still `Dict[str,str]` and every
   `pending_jobs` value contains only scalars, so it cannot grow a shape the Swift decoder rejects.
9. Terminal retention — a failed job leaves `_PENDING` and appears in `pending_jobs` with
   `state='error'` and its message; `predict_dismiss` removes it; `_RECENT` never exceeds 16.
10. `predict_cancel <object name>` cancels every job registered against it.
11. `_TRACK` is retired on both the success and failure paths — a second `predict` into the same name
    reports `model 1 of N`, not `1 of 2N`.

`tearDown` clears `_JOBS`, `_PENDING`, `_TRACK`, `_RECENT`, restores `registry._REGISTRY`, calls
`clear_pending()` **before** removing the temp root, and pops `RAYMOL_WEIGHTS_DIR`.

### 8.2 Swift (local, `UnitTests_macOS`)

New `PendingJobTests.swift`, following `WeightsFetchStateTests.swift:4-10`'s discipline: decode a
**verbatim** `pending_jobs` payload captured from a real `poll_panel()` tempfile, never hand-written
to agree with the decoder. Plus `testPayloadWithoutPendingJobsStillDecodes` and
`testRecordWithoutMovingOrElapsedStillDecodes` (the `elapsed` precedent at `:80-90`), `ProgressItem`
mapping, and `formatElapsed` bucket tests.

`BoltzJobManagerTests.swift`: at increment 0, assert the failure path writes a `failed` status
**before** the placeholder discard. At increment 3, add `progressFraction` bounds/clamping and
`step` / `total_steps` snake_case round-trip.

### 8.3 Manual

No CI compiles Swift and **none compiles iOS**; the shared target has broken each platform from the
other three times (#174, #226, #238). Hand-compile both slices before merge. Then, under the
`mac-vm-test` / `raymol-mac-vm` skill: warm-cache `predict` (one card, indeterminate bar, ticking
clock); `n_models=3` (`model 1 of 3` → `2 of 3`, per-card Cancel stops the whole prediction); cold
cache (weights card only, no duplicate); a deliberately failing prediction (error card with text,
Dismiss removes it); and enough concurrent items to force the tray to scroll.

---

## 9. Increments

Each is independently shippable and independently useful.

### Increment 0 — make failures observable (Swift, ~6 lines)

Swap `report(...)` / `writeStatus(...)` before `Self.discardPlaceholder(request)` on all six bad-exit
paths in §6.1. Add the XCTest pinning the ordering. Ships alone: today's tooltip and any future card
can finally see a failure.

### Increment 1 — the smallest thing that puts a real bar on screen

Python: `compose_progress` + the empty `progress_phases`/`progress()` on `Predictor` + boltz2's own
table in `boltz2.py` +
`submit`/`_template.py`/`docs/predictors.md` docs + `_TRACK` (total / done / started / floor per
pending object) + `pending_info()` + `pending_detail()` rewritten as its formatter + `_pending_maps()`
+ the `pending_jobs` payload key + `predict_cancel` accepting an object name + `predict_status`
printing a percentage at `quiet=0`.

Swift: `ProgressTray.swift` (tray + card + item), `PredictionJobState` + `@Published predictionJobs`
+ `PanelPayload.pending_jobs`, `busyOverlay` rewired, `WeightDownloadOverlay` deleted.

**No `BoltzJobManager.Status` change, no new marker, no upstream dependency.** Elapsed is derived in
Python from `_TRACK[name]['started']`, set at `register_pending`, so even the clock needs no Swift
wire change.

On screen: a determinate bar for weight downloads (as today, now in a stack), and for a prediction a
card with the phase name, `model k of N`, a live elapsed clock, a working per-card Cancel, and a
determinate bar wherever the backend actually reports movement — indeterminate through inference,
honestly.

### Increment 2 — terminal and error cards

`_RECENT` retention, capture in `discard_pending` / `deliver_result`, `predict_dismiss`, error/done
rendering and the Dismiss button, sorted ordering and the "+N more" footer. Depends on increment 0.

### Increment 3 — measured diffusion progress

Upstream: `onStep` / `onRecycle` / `onProgress`, tag v0.1.2, verify resolution, re-resolve.

RayMol: `Status` gains Optional `step` / `total_steps`; `BoltzJobManager` gains a **static**
`reportStep` plus `StepThrottle: @unchecked Sendable` (0.15 s or 1 %, terminal forced); and
`report("running","inference",0.2)` becomes `trunk` then `diffusion`. Preserve
`defer { BoltzRuntime.configureOnce() }` (`:326`) on every exit path.

Python: **nothing** — `boltz2.py`'s table already declares the `trunk` and `diffusion` bands, so the
host simply starts writing those phase names instead of `inference`. The detail line gains
"step 84 of 200". No edit to `base.py`, and no other predictor is touched.

### Increment 4 — optional polish

Prediction ETA from the per-step rate (generalizing `WeightsFetchState.secondsRemaining`'s
average-rate, suppress-below-1 s policy); trunk-pass `Task.checkCancellation()`; theming the tray via
a widened `PanelTheme`.

---

## 10. Open questions

Carried into implementation; none blocks increments 0–2.

1. **Tag `boltz-mlx` v0.1.2?** ~14 lines on a repo we own, pinned by range. But CI has hard-failed on
   package trust for an mlx-related dependency before (#267). Gate increment 3 on a verified Xcode
   Cloud resolve before a release, or is a local-only bump acceptable first?
2. **Is the trunk/diffusion band split worth measuring first?** 0.10–0.40 / 0.40–0.97 is a judgement
   call; no instrumented per-phase profile exists in the repo, and derived splits swing from ~26/73
   at 117 tokens to ~47/52 at 225. One instrumented run at recycling 3 / 200 steps would fit it.
3. **`predict_cancel` accepting an object name** as well as a job id is API widening on a shipped
   command. It is what makes the card's Cancel correct with `n_models > 1`. Acceptable, or a separate
   `predict_cancel_object`?
4. **macOS tray anchor.** `busyOverlay` attaches to the whole window (`ContentView.swift:490`), so
   the tray floats over the 340 pt inspector / Theme Studio column when open — true of today's
   weights card, but a taller tray makes it more visible. Leave, inset when the inspector is open, or
   re-anchor to `macViewport`?
5. **Add `Task.checkCancellation()` to the trunk recycling loop** while patching it? Nearly free, and
   it closes a real gap (a cancel during the trunk is unobserved for up to ~25 s at 225 tokens) — but
   it changes cancellation semantics and should be an explicit decision, not a side effect.
6. **Should a finished prediction get a 5-second "done" card?** The object is already visible in the
   panel, so it announces nothing new — but without it, cards vanish mid-glance and rows reflow under
   the reader's eye. (Currently specified as: yes, 5 s.)
7. **iOS overdraw.** The tray is clipped to `viewportView` and drawn under `topPaneRail` /
   `panelTongue` (applied after `busyOverlay` at `:1648`, `:1657`). Prediction is macOS-only today so
   this is latent; fixing it means re-anchoring or introducing a `zIndex` convention the app has
   never used. Fix now or file it?
8. **Add an `xcodebuild test -scheme UnitTests_macOS` CI step?** Every contract that must hold on
   every PR is currently asserted in Python because no workflow compiles Swift. Real improvement,
   real scope increase.

---

## 11. Scope note on iOS

Prediction cannot run on iOS today: `RAYMOL_PREDICT_HOST` is set only under `#if TARGET_OS_OSX`
(`PyMOLBridge.mm:112`), `Boltz2Predictor.check_available()` raises `PredictorUnavailable`, and
`BoltzJobManager.swift` is wholly `#if os(macOS)` with boltz-mlx behind a macOS platform filter in
`project.yml`. **There is no running prediction on iPadOS to indicate.**

The tray is nevertheless written platform-neutral, because it also hosts weight downloads and because
gating it would leave iOS silently frozen the day a downloadable bundle ships there — the reasoning
already recorded at `PyMOLEngine.swift:3074-3078`.

#291's acceptance criterion "the indicator appears on iPadOS" and #288's "completely invisible on
iOS" both rest on a false premise and should be reworded to be conditional on MLX-on-iOS landing.
