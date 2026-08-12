# Structure-prediction backend — pluggable predictors + cached model weights — design

**Issue:** [RayMol#224](https://github.com/javierbq/RayMol/issues/224)
**Date:** 2026-08-11
**Scope:** Backend only, no UI. macOS only for the first real predictor; iOS deferred (§10).
**First real predictor:** [javierbq/boltz-mlx](https://github.com/javierbq/boltz-mlx) — a Swift/MLX int8 port of Boltz-2.

## Problem

RayMol cannot run structure prediction. We want several methods available without each
wiring itself ad-hoc into the app, and without shipping hundreds of megabytes of weights
in the app bundle. #224 asks for two things: a swappable predictor abstraction with a
registry, and a model-weight manager that downloads a bundle once on first use, verifies
it by checksum, extracts it, and reuses the cache thereafter.

Two consumers already depend on this. #217 deferred its `"Predict"` menu item here. And
#249 must decide whether to bundle Design mode's 24 MB `MPNN.mpnnpack` into the iOS app or
fetch it on demand — which is exactly this ticket's machinery, so the weight manager must
be **predictor-agnostic** rather than coupled to the registry.

## Decisions

| Decision | Choice |
|---|---|
| Where inference runs | On-device Swift/MLX (`BoltzPredictor`, a Swift `actor`) |
| Who owns the abstraction | **Python** — `modules/pymol/predicting.py` holds registry + weight manager |
| Ticket scope | Framework **and** boltz-mlx wired end to end |
| Weights hosting | GitHub Release asset |
| API shape | Job handle: submit → poll status → `result()`, with cancel |
| Cache dir config | Python module global + `RAYMOL_WEIGHTS_DIR` env override (no new C++ setting) |
| Inference isolation | In-process, with a *preventive* size guard |
| Structure writer | PDB for v1, by **promoting boltz-mlx's existing test-only writer** into its `Sources/`. Not new code, and not MPNNKit's. mmCIF is the upgrade path |
| Platform gating | `#if os(macOS)` — **no dedicated compilation condition.** Prediction ships in every macOS build; iOS is simply not compiled |
| Inference options | Upstream Boltz's own defaults, overridable per call from the command line |

### Resolved while designing

- **Weights licensing is MIT.** Upstream `jwohlwend/boltz` states "All the code and weights
  are provided under MIT license, making them freely available for both academic and
  commercial uses", and the Hugging Face `boltz-community/boltz-2` model card — the actual
  host of `boltz2_conf.ckpt` — carries `license: mit`. Redistributing a derived int8
  artifact is permitted, carrying the MIT notice.
- **No mlx-swift version conflict.** MPNNKit pins mlx-swift `exact: "0.31.6"`; boltz-mlx
  pins mlx-swift `exact: "0.31.6"`. Identical. RayMol's committed `Package.resolved`
  already sits on mlx-swift 0.31.6, swift-argument-parser 1.8.2, and swift-numerics 1.1.1
  — every one matching boltz-mlx's own resolution. No fork, no vendoring, no pin relaxation.
- **boltz-mlx metadata.** SwiftPM product `BoltzMLX`; platforms `.macOS(.v14)`/`.iOS(.v17)`,
  matching the iOS 17.0 floor already forced at `swiftui/project.yml:6-9`.

### Still open

- **boltz-mlx has zero tags.** SwiftPM needs a semver tag (or an explicit `revision:` pin).
  Tag `v0.1.0` as part of Phase 2, which touches that repo anyway.
- **The artifact must be minted and hashed once, by hand.** `mx.quantize` runs on Metal and
  is not guaranteed bitwise-reproducible across MLX versions or Apple Silicon generations,
  so a hash minted on one Mac may not reproduce on another. One human exports once, uploads
  those exact bytes, and pins the hashes **of the uploaded bytes**.

## What exists today

### There is no Python→Swift call path

This is the constraint that shapes everything.

- `grep -rn "@_cdecl\|@convention(c)" swiftui/` → **zero hits**. No Swift function has a C
  symbol, so nothing in Swift is addressable from C or Python.
- `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h` is one-directional by construction: every
  symbol is `PyMOLBridge_*`, i.e. C functions that *Swift imports*. No callback
  registration, no function-pointer setter, no delegate.
- Exactly two Python modules are registered, both core PyMOL:
  `PyMOLBridge.mm:76` `PyImport_AppendInittab("_cmd", …)` and `:80` `…("_champ", …)`.
- No `ctypes`/`cdll` anywhere in `modules/pymol/` or `modules/raymol_mcp/`.

Swift→Python, by contrast, is rich: `PyMOLBridge_RunCommand` (`PyMOLBridge.mm:328`),
`PyMOLBridge_RunPython` (`:377`), and typed calls like `PyMOLBridge_InvokeKey` (`:276`).

**Consequence:** Design mode is UI→Swift→Python, never the reverse.
`DesignCompactPanel.swift:240` → `DesignController.swift:788/793` → off-main hop at `:866`
onto `inferenceQueue` (`:253`) → `designFn`, a *Swift* closure at `PyMOLEngine.swift:2211-2224`.
Python's only role is providing inputs. `raymol_design.py` has no `cmd.extend`; there is no
`design` command at all.

### The channels that do exist

- **Structured payloads go through tempfiles**, because PyMOL's feedback line caps at
  ~1 KB — documented at `modules/pymol/appkit_inspector.py:344-351`, where printing
  `OBJPANEL:<json>` inline overflowed the cap at ~16 objects and the truncated fragment
  still carried the prefix but failed JSON decode. Existing instances: `pymol_gizmo.json`,
  `pymol_objpanel.json`, `pymol_seqsel.json`, `pymol_objdetail.json`, `pymol_settings.json`.
- **Python→Swift *notification*** is a short prefix marker on the feedback line, polled by
  Swift: `PyMOLEngine.swift:308` `feedbackTimer`, scheduled at `:632` on a 0.1 s interval,
  handled by `pollFeedback()` at `:2818-2888`, which dispatches an if/else-if ladder on
  `OBJPANEL:`, `OBJDETAIL:`, `SESSIONVP:`, `SEQPANEL:`, `SEQSEL:`, `PLAYBACK:`,
  `SELPREVIEW:`, `MEASURE:`, `SETTINGS:ready` (`:2857`), `SETVAL:`, `MCP:`.
  Fire-and-forget: no return value, no blocking.

### `fetch`'s download machinery is not reusable

`modules/pymol/importing.py` is the prior art #224 points at, but little of it survives
contact with a 533 MiB checksummed bundle:

- `cmd.file_read` → `internal.py:279` buffers the **entire** body in memory, and silently
  gunzips/bunzips by magic number. Fine for `.zip` (`PK`), fatal for a `.tar.gz` digest.
- No integrity check of any kind. Cache validity is bare `os.path.exists`
  (`importing.py:1219-1221`) — no size, mtime, or checksum.
- No atomic publish: `open(file,'wb')` writes straight to the final path, so a crash or two
  concurrent fetches leave a truncated file that the existence check then accepts as valid.
- No locking, and no timeout anywhere (no `socket.setdefaulttimeout`).
- Default `fetch_path` is literally `"."` (`layer1/SettingInfo.h:607`), and it is
  session-blacklisted (`layer1/Setting.cpp:644`) — upstream deliberately keeps paths out of
  `.pse` files.

Reusable: the setting-driven-destination idiom, the mirror-list retry loop with
`colorprinting.warning` per URL and one terminal `colorprinting.error`, and the
`quiet`/`colorprinting` conventions. Everything else is new code.

### Python runtime constraints

`requires-python = ">=3.9"`; the embedded interpreter is CPython **3.13**
(`project.yml:51`, `PyMOLBridge.mm:83`). **`requests` is not available at runtime** — it is
a dev-only extra, and the shipped `site-packages` holds only `Bio`, `numpy`, `pip` on macOS.
Use `urllib.request`, as `internal.py:10`, `importing.py:519`, and `commanding.py:23`
already do. `hashlib`, `zipfile`, `ssl` are all in the bundled stdlib.

## Architecture

Python never calls Swift. The **job-handle** API makes the missing bridge direction
unnecessary rather than something to build: submit returns immediately, so nothing needs a
synchronous return value from Swift.

```
cmd.predict('boltz2', 'MKT…')                 [Python, main thread, returns a handle]
  registry lookup            → PredictorNotFound if unknown
  predictor.check_available() → PredictorUnavailable if no Swift host / wrong platform
  WeightCache.ensure('boltz2-mlx-int8')  → downloads 533 MiB once, verifies, extracts
  write  <tmp>/raymol_predict_req_<job>.json   {weights_dir, chains, options, out_path}
  print  "PREDICT:submit:<job>"                ← existing feedback-marker channel
  return PredictionJob(job_id)
        │
        │  ≤100 ms  (PyMOLEngine.swift:632 feedbackTimer → pollFeedback() :2818)
        ▼
BoltzJobManager                    [Swift, io.raymol.predict.inference queue]
  PredictSizeGuard.decide(tokens:) → refuse before allocating anything
  CanonicalStructure.fromSequences → inspect .diagnostics, refuse on anything dropped
  BoltzFeaturizer().featurize(…)
  BoltzPredictor.predictScored(…)   wrapped in MLXRuntime.withMLXErrorsAsThrows
  StructureWriter → <out_path>.cif
  writes <tmp>/raymol_predict_status_<job>.json after each phase / diffusion step
        │
        ▼
job.status()  → ('inference', 0.62)            [Python: a file read]
job.result()  → cmd.load(cif, name)            [Python: caller's thread]
job.cancel()  → print "PREDICT:cancel:<job>"   → Swift's per-step checkCancellation()
```

This adds **one `else if` branch** to an existing prefix ladder and reuses the tempfile
handoff every RayMol feature already uses. No new C ABI, no `@_cdecl`, no GIL work under
`_PYMOL_EMBEDDED` (where `PAutoBlock` is a no-op — `PyMOLBridge.mm:596-604`), and MLX stays
off the main thread. Cancellation lands on boltz's existing `Task.checkCancellation()`
sites, one of which is per diffusion step (`AtomDiffusion.swift:70`), so worst-case
cancellation latency is one step.

The new branch must **not** be wrapped in the macOS-only `#if` used for `MCP:` (`:2864`),
so the same code path is available when iOS is enabled later.

### Rejected alternatives

- **A `_raymol` builtin extension module + the repo's first `@_cdecl` entry points.** Gives
  a true synchronous call, at the cost of a new C ABI to version and explicit GIL handling
  plus a `run_on_main`-style hop to return results. It also buys very little: `cmd.predict`
  from the console arrives *on* the main thread under `cmd.do`, so a synchronous submit that
  blocks on 9–32 s of MLX would stall the render loop. The job-handle API is precisely the
  mitigation, which makes the synchronous call unnecessary.
- **`ctypes`/`dlsym` onto `@_cdecl` symbols.** No `ctypes` usage exists in `modules/` today,
  and whether `_ctypes` is present in the embedded stdlib is unverified.
- **Localhost HTTP, like MCP.** Works, but is macOS-only and is *deleted* from the MAS build
  (`modules/raymol_mcp` removed from Resources at `project.yml:391`). Unacceptable for a
  first-class `cmd.*` feature.

### Trade-off accepted

`cmd.predict` **only runs inside the SwiftUI app.** Under headless `pymol -c`, nothing
consumes the marker. So a predictor must advertise availability, and the Boltz predictor
reports unavailable when the host is absent — detected via a `RAYMOL_PREDICT_HOST`
environment variable published beside `PyMOLBridge.mm:115-116`, mirroring how `PYMOL_PATH`
and `PYMOL_DATA` are published today. This is not merely a graceful degradation: it is what
satisfies #224's required "predictor unavailable on the current device/platform" failure
mode, and what makes the offline test suite possible.

## Component 1 — predictor registry

`modules/pymol/predicting.py`. Wiring, verified against how `fetch` reaches both `cmd.fetch`
and the command line:

1. Module preamble mirrors `importing.py:22`: `cmd = sys.modules["pymol.cmd"]`.
2. `modules/pymol/api.py:30` — a new `from .predicting import \` block.
3. `modules/pymol/keywords.py:204` — rows for `predict`, `predict_status`, `predict_cancel`,
   inserted among the existing `'p'` rows (`:199-210`).
4. `modules/pymol/cmd.py:343` is `from .api import *` — no edit needed.

**Every public signature must end `_self=cmd`.** This is load-bearing, not cosmetic:
`pymol2/cmd2.py:93-118` binds `_self=<instance>` only if `_self` is in the argspec (or the
function has `**kwargs`); **otherwise it copies the function verbatim and it silently talks
to the global instance.** A missing `_self` is a cross-instance leak with no error.

**Parsing mode:** `parsing.STRICT` while a sequence is one whitespace/comma/`=`-free token —
the same situation as `fab` (`keywords.py:86`, `editor.py:1051`). If multimer input uses
`:`-joined or comma-separated chains, use `LITERAL1` (sequence first, remainder verbatim;
`parsing.py:165-168`) or require quoting, because STRICT would shred it into extra
positionals.

**Job handle vs the console:** from `cmd.do` the return value is discarded, so the `predict`
keyword must *print* the job id, with the handle retrievable via `cmd.predict_status(job_id)`.

Interface:

```python
class Predictor:                 # protocol / ABC
    id: str                      # stable selector, e.g. 'boltz2'
    name: str                    # human-readable
    weight_bundle: WeightBundle | None
    def check_available(self) -> None   # raises PredictorUnavailable
    def submit(self, spec, *, options) -> PredictionJob

register(predictor)              # discoverable through the registry
get(predictor_id) -> Predictor   # raises PredictorNotFound
available() -> list[str]
```

Swappability is the point: call sites depend only on `Predictor`, so the test suite
registers a stub and exercises the whole flow with no Swift and no network.

### Public API

```python
cmd.predict(predictor, sequence, name='', *,
            recycling_steps=3, diffusion_steps=200, seed=0,
            quiet=1, _self=cmd)          -> PredictionJob   (prints the job id)

cmd.predict_status(job_id='', *, quiet=1, _self=cmd)  -> dict   (all jobs if omitted)
cmd.predict_cancel(job_id, *, quiet=1, _self=cmd)
cmd.predict_result(job_id, name='', *, quiet=1, _self=cmd)     -> object name
cmd.predict_weights(predictor='', *, download=0, quiet=1, _self=cmd)  -> dict
```

So the command line reads exactly as requested:

```
predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ, diffusion_steps=300
```

Per-predictor options are passed through as explicit keyword arguments rather than
`**kwargs`. That is deliberate: `prepare_call` (`parsing.py:352-353`) forces
`mode = NO_CHECK` when `co_flags & 0xC` is set, so a `**kwargs` signature silently disables
the declared `STRICT` type checking — which is exactly why `fetch`'s declared STRICT checks
nothing. Explicit keywords keep the checking, and `parse_arg` already handles `name=value`
on the command line.

A predictor rejects options it does not implement rather than ignoring them, so
`diffusion_samples=4` raises `PredictionOptionError` instead of quietly producing one
sample. Silent acceptance of an ignored quality knob is the worst available behaviour.

**Multimer input uses `/` as the chain separator**, not a comma: `'MKTAY/GSHMA'` → chains
`A`, `B`. Commas are the argument separator that `parsing.parse_arg` splits on, so a
comma-separated chain list would be shredded into extra positionals before the function ever
sees it. `/` also matches PyMOL's existing chain-ish selector idiom. Chain ids are assigned
`A`, `B`, `C`… and constrained to a single uppercase character, which is what keeps PDB
column alignment safe.

## Component 2 — `WeightCache`

Predictor-agnostic by design, so #249 consumes it rather than growing a second downloader.

```python
@dataclass(frozen=True)
class WeightBundle:
    id: str            # 'boltz2-mlx-int8'
    version: str       # 'v1'
    url: str           # GitHub Release asset
    sha256: str        # of the zip's bytes
    size: int          # expected bytes, for a cheap pre-check and progress
    members: tuple[str, ...]   # exact expected archive entries

class BundledSource:   # for #249: already present in the .app, never downloaded
    def resolve(self) -> str
```

`ensure(bundle_id) -> path` must be able to return a path it did **not** download —
`MPNN.mpnnpack` is bundled today and resolved only via `Bundle.main`
(`MPNNGate.swift:7`, copied by `project.yml:447-461`).

### Download and publish protocol

Every step here exists to avoid a specific failure mode `fetch` currently has:

1. Stream to `<cache>/.incoming/<sha256>.part` with `urllib.request`, hashing **while**
   streaming. Never buffer 533 MiB in memory. Set an explicit timeout.
2. Compare the digest. Mismatch → delete the partial and raise `WeightChecksumMismatch`.
   Nothing is published, so the cache is never left corrupt.
3. Extract to `<cache>/.incoming/<sha256>.d/`, then assert the extracted set is **exactly**
   `WeightBundle.members`. This assertion is mandatory, not defensive: `BoltzArtifact.load`
   loads `config.json` **only if it exists** (`BoltzArtifact.swift:13-15`), so a truncated
   extract missing it produces a silently misconfigured predictor rather than an error.
   Python's assertion is the only guard.
4. `os.replace()` the directory into `<cache>/<id>/<version>/` — atomic publish.
5. Write a `.ok` sentinel **last**, containing the digest. **Cache validity is the
   sentinel's presence and content, never directory existence** — this is what makes an
   interrupted download impossible to mistake for a valid cache.
6. Re-validation: sentinel content ≠ expected digest → discard and re-download.
7. Concurrency: an `O_CREAT|O_EXCL` lockfile carrying pid and mtime, with stale-lock
   breaking. A second caller waits on the lock rather than starting a second download.

### Cache location

Resolution order: `RAYMOL_WEIGHTS_DIR` (published by Swift) → module global (settable from
`~/.raymolrc.py`) → per-platform default.

Defaults, and why:

| Channel | Directory |
|---|---|
| Notarized DMG (unsandboxed) | `~/Library/Application Support/RayMol/weights` |
| MAS (sandboxed) | the same call redirects into `~/Library/Containers/io.raymol.RayMol/Data/…` |
| iOS | `<container>/Library/Application Support/RayMol/weights` |

Application Support, not Caches — Caches is purgeable and the user waited for 533 MiB.
Mark it excluded from backup. Not `Documents/` on iOS: `LSSupportsOpeningDocumentsInPlace`
is set (`project.yml:243`), making Documents user-visible in Files. The app bundle is
read-only and signed (`PyMOLBridge.mm:94` disables bytecode writing for this reason), so
writing next to `MPNN.mpnnpack` is impossible.

No new C++ setting. A `REC_s` at index 831 would be faithful to #224's "a setting analogous
to `fetch_path`" wording, but it costs a full two-stage macOS rebuild and permanently burns
a session index — and `fetch_path` is itself session-blacklisted, so even upstream keeps
paths out of sessions.

## Component 3 — the Swift job runner

New, under `#if os(macOS)`. `project.yml` edits, following the MPNNKit precedent:

- `packages:` — add `boltz-mlx` with `from: 0.1.0`, after the `mlx-swift` entry at `:28-30`.
  Keep `from:` not `exact:`, for the reason recorded at `:23-27`. **That tag does not exist
  yet** — Phase 2 must create it, or this entry needs an explicit `revision:` pin instead.
- target `dependencies:` — `- package: boltz-mlx` / `product: BoltzMLX` with
  `platforms: [macOS]` (the platform-filter template is Sparkle at `:476-477`), appended
  after `:471` and **outside** the `RAYMOL_SPARKLE_BEGIN` markers at `:472`, or
  `archive_appstore.sh`'s sed-strip removes it from the MAS build.
- **No new `SWIFT_ACTIVE_COMPILATION_CONDITIONS` key.** Unlike Design mode, prediction is
  not opt-in: it ships in every macOS build, so there is no flag to set and no way to
  forget to set it. Gate the Swift with `#if os(macOS)`, and let the `platforms: [macOS]`
  dependency filter keep `BoltzMLX` out of the iOS link entirely.
- `-skipPackagePluginValidation` is already passed by `make_dmg.sh:123-127` and
  `archive_appstore.sh:39`; any mlx-swift consumer requires it.
- No source-list edit: `sources: - path: PyMOLViewer` is a directory glob.
- Do **not** copy the `postBuildScripts` copy phase at `:447-461`. That exists because
  `MPNN.mpnnpack` is bundled; these weights are downloaded into a writable directory.

`MLXRuntime` is correspondingly gated `#if RAYMOL_MPNN || os(macOS)`: always present on
macOS for prediction, and still present on iOS for Design mode. The trade-off accepted by
dropping the flag is that prediction code cannot be compiled out of a macOS build for
bisection or binary-size reasons — acceptable, because the alternative is a flag that
must be remembered in three per-SDK keys and whose absence fails silently.

### Two things that would ship a broken feature

**boltz-mlx's own defaults fail its own quality gate, so RayMol adopts upstream Boltz's.**
`BoltzPredictionOptions()` defaults to `recyclingSteps: 0, diffusionSteps: 20`, and at 20
steps the matched-noise release gate scores **3.19 Å RMSD / 0.685 lDDT — FAIL** against a
≤2.0 Å / ≥0.90 bar. At 50 steps it passes (0.64 Å / 0.977). Rather than pick a number off
that curve, take upstream's, which is both higher quality and the figure users will expect:

| Knob | Upstream default | RayMol default | Notes |
|---|---|---|---|
| `recycling_steps` | 3 | **3** | `src/boltz/main.py:852` |
| `sampling_steps` → `diffusion_steps` | 200 | **200** | `main.py:858` |
| `step_scale` | 1.5 for Boltz-2 | **1.5** | `main.py:876`. **Already correct and not a per-call knob** — the Swift sampler reads it from the artifact's `config.json` (`BoltzModelConfiguration.swift:130`, key `step_scale`), and the exported pack carries exactly `1.5`. |
| `diffusion_samples` | 1 | **n/a** | Not plumbed in the port, and only diffusion sample 0 escapes `BoltzPredictor` anyway. Document as unsupported rather than silently accept-and-ignore. |
| `seed` | `None` (unseeded) | **0** | Deliberate divergence: a viewer benefits from a reproducible default. Documented in the command help. |

The port's `BoltzPredictionOptions` carries **only** `recyclingSteps`, `diffusionSteps`, and
`seed` (`BoltzTypes.swift:4-14`), so those three are exactly the exposable surface. Note
also that `config.json`'s `num_sampling_steps: 5` is an inert training hparam — the sampler
takes its step count from the options, not the config.

**Measured end to end, 2026-08-11 (the first measurement at the shipped operating point).**
On an M3 Pro, a 33-residue monomer at recycling 3 / 200 diffusion steps: **~95 s cold**
(including the ~10 s model load) and **73.5 s warm**. ⚠️ Both are **Debug** builds
(`SWIFT_OPTIMIZATION_LEVEL: -Onone`), so they are an upper bound and are **not comparable**
to boltz-mlx's Release benchmark numbers — re-measure against Release before quoting
anything to a user or sizing a UI.

Even allowing for Debug, this is materially worse than the extrapolation below predicted:
73.5 s at **33** tokens versus an extrapolated ~30 s at 117. For small inputs the cost is
dominated by the fixed per-step work of 200 diffusion steps, not by the ~N² term, so
scaling the 50-step figures understates the 200-step cost at low token counts. Treat 200
steps as expensive regardless of sequence length, and surface progress accordingly.

**The original extrapolation, retained for contrast.** Every published figure is at 50 steps
(8.90 s / 2.24 GB at 117 tokens; 32.16 s / 3.47 GB at 225, on an M3 Pro). Runtime is ~linear
in diffusion steps and super-linear (~N²) in tokens, so 200 steps multiplies the diffusion
component roughly fourfold — on the order of 30 s at ~117 tokens and minutes at ~225. Those
are extrapolations, not measurements: **do not quote the 50-step numbers as if they applied
at 200**, and confirm the latency is acceptable before wiring any UI. This is also the
strongest argument for the progress channel, since none exists in boltz-mlx.

Also pass `MemoryPlanner(limits: .desktop)` (1024 tokens) or the phone default of 256
refuses anything real. Keep the `BoltzPredictor` **alive across predictions** —
construction does the full ~533 MiB safetensors load and graph build (~10 s), and `init` is
synchronous and `nonisolated`, so it must be constructed off the main thread.

**`MemoryPlanner.apply()` clobbers Design mode.** It writes process-global
`MLX.Memory.cacheLimit` on *every* predict; `MPNNRuntime.cacheLimitBytes = 96 MB` exists to
bound Design mode against jetsam. Addressed by the `MLXRuntime` extraction below.

### `PredictSizeGuard`

boltz's own preflight cannot be trusted: its activation estimate under-predicts measured
peaks by **10–25×** (115 tok / 889 atoms estimates ≈60 MB, measured 1.43 GB; 384 tok
estimates ≈622 MB, measured 6.84 GB), and its own handoff notes concede the iOS limits are
"conservative estimates, not measurements". Under the phone defaults the memory check can
never even fire — the token cap always binds first.

So mirror `DesignSizeGuard` (`swiftui/PyMOLViewer/Shared/DesignSizeGuard.swift`), which
already solves this shape for MPNN: an ok/warn/refuse decision fitted to a measured curve,
kept **preventive** because jetsam is an uncatchable SIGKILL. Fit the constants to boltz's
measured peaks in `validation/device/mac_scaling.json` and `scaling_iphone15pro.json`, and
enforce before anything is allocated.

### Why in-process is acceptable — and what it costs

As shipped, mlx-c's default error handler calls `exit(-1)`, and mlx-swift's `memoryLimit` is
a throttle rather than a boundary. But RayMol already established the mitigation for Design
mode: `withError` makes MLX-**reported** errors catchable as of mlx-swift 0.31.6. Wrapping
every MLX-touching call converts the allocator's `std::runtime_error` paths into Swift
`throws`.

What remains uncatchable is jetsam, and on macOS an uncatchable memory failure kills RayMol
and the user's unsaved session — not just the job. In-process is therefore accepted **only**
alongside a preventive guard and a hard token ceiling, and the residual session-loss risk
should be stated in the issue rather than left implicit. Out-of-process isolation (XPC or a
helper) is the correct general answer and should be filed as a follow-up covering **both**
boltz and MPNNKit.

## `MLXRuntime` extraction (implemented in this branch)

`MPNNRuntime` could not be reused by a second MLX consumer, for three reasons:

1. The entire file was wrapped `#if RAYMOL_MPNN`, lines 1–108, so it does not exist unless
   Design mode is compiled in. Prediction ships in every macOS build and must not acquire a
   dependency on Design mode's opt-in flag — that would weld together two features #249
   needs gated independently per SDK, and it would fail as a wall of compile errors the
   first time anyone turned `RAYMOL_MPNN` off.
2. The part worth sharing had no MPNN content: `withMLXErrorsAsThrows` was
   `try withError { try body() }`, pure mlx-swift. Wrong home.
3. The part that *is* MPNN-specific is exactly what conflicts. `cacheLimitBytes = 96 MB` is
   justified by measurement and pinned by `DesignIOSPortTests.swift:505`, while boltz
   overwrites the same process-global on every predict. Reusing `MPNNRuntime` would not
   resolve that collision, only obscure it into last-writer-wins by call order.

New `swiftui/PyMOLViewer/Shared/MLXRuntime.swift`, gated `#if RAYMOL_MPNN || os(macOS)`,
owns:

- `withMLXErrorsAsThrows` — moved verbatim, semantics unchanged.
- `configureDeviceOnce()` — the Simulator carve-out (`MLX_METAL_GPU_ARCH`, `Device(.cpu)`),
  which is device-level rather than MPNN-level. Ordering is preserved: `setenv` still runs
  before anything can construct a Metal device, because MLX latches that variable into a
  function-local static on first read.
- `requireCacheLimit(_:owner:)` — **one arbitrated owner of the process-global cache
  limit.** Min-wins, and the asymmetry is the justification: a limit that is too low costs
  only allocator churn, while one that is too high risks an uncatchable jetsam kill. So a
  later, larger request must never raise a ceiling an earlier owner needs low. Each owner's
  ask stays visible via `cacheLimitRequirements` so a disagreement is diagnosable instead of
  order-dependent. The Simulator branch still deliberately does not assign
  `Memory.cacheLimit` (assigning it constructs the MetalAllocator), but does record the
  requirement so the bookkeeping remains testable.

`MPNNRuntime` keeps its 96 MB constant and its full public API — `cacheLimitBytes`,
`configureOnce()`, `activeCacheLimitBytes`, `withMLXErrorsAsThrows` — so all five existing
call sites (`PyMOLEngine.swift:2034/2040/2063/2181/2223`) and the existing tests are
untouched. It no longer imports MLX, which restores the "only one file imports MLX"
invariant, now held by `MLXRuntime`.

## Structure hand-off

An earlier draft of this design claimed no writer existed and one had to be written from
scratch. **That was wrong**, and the corrected picture materially reduces the work.

### What actually exists

| | PDB | mmCIF |
|---|---|---|
| MPNNKit (already linked by RayMol) | **`PDBWriter.swift:14`** — production, MIT, 72 lines, column-correct, already regression-tested upstream (`fix/pdbwriter-unknown-restype`). `internal`, not `public`. | none |
| boltz-mlx | **`tests/BoltzMLXTests/MSAEndToEndTests.swift:239-272`** — ~40 lines, `private`, written against boltz's own public types and its actual coordinate order | none |
| boltz-mlx `Sources/` | none (emits SafeTensors only) | none |
| RayMol `swiftui/` | none | none |

So: **no mmCIF writer exists anywhere** — that clause of the original claim survives. A PDB
writer is not new work; there are two, and one is already written against exactly the right
types.

### The premise that was wrong

`BoltzStructure` carries no atom identity, but the *caller* does. `CanonicalStructure`
(`CanonicalStructure.swift:87`) and its `orderedResidues` (`:100`) are **public**, exposing
`threeLetter`, `hostChain`, `hostResSeq`, `hostInsCode` (`:32-38`); `AAResidueTemplates`
(`AAResidueTemplates.swift:69`) is public and gives ordered heavy-atom `name` +
`atomicNumber`. And `featurize` *takes* a `CanonicalStructure` (`BoltzFeaturizer.swift:206`),
so whoever ran the prediction is already holding the identity. Coordinates come back in
exactly that order, already unpadded (`BoltzPredictor.swift:193-206`).

Consequence: the adapter is a single sequential walk —
`for residue in orderedResidues { for atom in template.atoms { coordinates[i] } }` — and it
is the walk the test helper already implements. This also **removes the need for the
`ScoredStructure`-retains-`Layout` change** an earlier draft proposed; that was a workaround
for a problem that does not exist.

### Decision

**Promote `MSAEndToEndTests.writePDB` into `Sources/BoltzMLX/Write/StructureWriter.swift`**
as a public writer taking `(BoltzStructure, CanonicalStructure)`. Emit **PDB for v1**.

Gaps to close while promoting — the helper is a test helper, not a viewer-grade writer:

1. It emits no `TER` (`:271` goes straight to `END`); add it at chain breaks or multi-chain
   output reads as fused.
2. Residues must be renumbered **1-based per chain**; `hostResSeq` is **0-based** for
   sequence-derived structures, and the helper already documents why writing it verbatim
   "silently defeats residue-wise comparison in a viewer" (`:245-253`).
3. It drops insertion codes; emit column 27, or antibody numbering collides.
4. Constrain chain ids to a single uppercase character on the way in (RayMol controls them),
   since `hostChain` is a `String` interpolated into a 1-column field.
5. Widen the element map beyond `[6,7,8,16]` (`:241`) only if non-protein components ever land.
6. **B-factor stays `0.00`.** It is tempting to write confidence there, and two independent
   reviews of this design suggested doing so — **there is no pLDDT to write.**
   `ConfidenceModule.swift:7` is explicit: *"SCOPE: PAE ONLY. pLDDT, PDE, pTM/ipTM and
   resolved-ness are deliberately not computed."* A per-token PAE row-reduction is a
   different quantity; if it is ever used there it must be labelled as such, never as pLDDT.
7. No `OXT`, ever — the featurizer drops the trailing `OXT` on every residue including chain
   termini. That is what the checkpoint was trained on; do not "fix" it.
8. Heavy atoms only, single model. `diffusion_samples` is unplumbed, so there is no
   multi-model output to serialize and no multi-state ambiguity to resolve.

### Alternatives, and why not

- **Adapt MPNNKit's `PDBWriter`.** Three transforms to reuse 72 lines of `String(format:)`:
  a `public` shim (it and `AtomNames` are internal), binning flat atoms into its
  `[1,L,14,3]` AF2 grid, and permuting names because **boltz's atom order is its own
  template order, not AF2 atom14 order**. Strictly more work than promoting the writer that
  already matches.
- **Port boltz's Python `to_pdb`/`to_mmcif`.** **Not implementable.** Verified against
  RayMol's actual bundled interpreter (`deps_macos/python-standalone/python/bin/python3.13`):
  `rdkit`, `torch`, `mashumaro`, `ihm`, `modelcif`, and `gemmi` are all
  `ModuleNotFoundError` — site-packages holds only `Bio`, `numpy`, `pip`. They also consume
  a `Structure` npz table the MLX path never builds.
- **Biopython `PDBIO`/`MMCIFIO`.** Genuinely available and importable in that interpreter —
  worth recording, since it is the only battle-tested mmCIF emitter on hand. But it still
  needs the same identity walk to populate `StructureBuilder`, so it saves formatting only
  while adding a heavy object graph. Reach for it only if strict mmCIF validity matters.
- **`cmd.fab` + `cmd.load_coordset`, no serializer at all.** Reconciling `fab`'s atom order
  and hydrogens against boltz's heavy-atom template order is a silent-mismatch generator.

**mmCIF is the upgrade path**, not the v1 target: for a flat all-atom list an `_atom_site`
`loop_` is arguably easier to get right than fixed-column PDB, and it dodges PDB's 4-char
atom-name and 26-chain ceilings. Take it first only if multi-chain designs or non-protein
components are on the near roadmap.

### Getting it into the session

The job is asynchronous, so Swift cannot return a value and the result must land in a file
regardless — Swift writes `<tmp>/raymol_predict_result_<job>.pdb` and `job.result()` calls
`cmd.load(path, name)`. File **contents** must never cross the feedback-marker line, which
caps at ~1 KB (`appkit_inspector.py:344-351`).

**Do not run the download on a background Python thread inside the app.** Measured: an
extraction that should take seconds ran at ~364 KB/s — roughly 1000× too slow — because the
embedded app's main thread holds the GIL persistently (the same reason `PAutoBlock` is a
no-op under `_PYMOL_EMBEDDED`), starving any other Python thread. `cmd.predict` calls
`WeightCache.ensure()` synchronously on the caller's thread and is unaffected; this matters
only if someone later adds a "download in the background" affordance, which must be done on
a Swift queue rather than a Python thread.

Recorded for the synchronous case, because it is the established RayMol precedent and worth
matching if a blocking path is ever added: `raymol_design.py:608 load_repacked(obj, pdb_str)`
loads MPNNKit's PDB **string** via `cmd.read_pdbstr` (`importing.py:1008`), bracketed by
`get_view`/`set_view` with a `matrix_copy` → `delete` → `set_name` dance. The
`NSTemporaryDirectory()/raymol_repack.pdb` tempfile at `PyMOLEngine.swift:2183-2194` is
**unnecessary** for that path — its stated reason (avoiding multi-line escaping in the
`runPython` string) is already solved by base64 elsewhere in the same file (`:2345-2347`),
and it uses a fixed filename, swallows write errors with `try?`, and never cleans up. For
mmCIF there is no `read_cifstr`; the in-memory route is `cmd.load_raw(text, 'cif', name)`.

## Input contract

What Python passes across the bridge:

| Field | Notes |
|---|---|
| `weights_dir` | verified-extracted directory |
| `chains` | ordered `(chain_id, one_letter_sequence)`; single uppercase char if emitting PDB |
| `recycling_steps` | **3**, not the default 0 |
| `diffusion_steps` | **50**, not the default 20 |
| `seed` | int |
| `limits` | `.desktop` on macOS |
| `out_path` | absolute temp path |

Featurization needs **no downloaded data and no GPU**: `AAResidueTemplates` is a compiled
Swift literal, and there is no CCD dictionary, no `~/.boltz`, no `ccd.pkl`. The weights
artifact is the only download.

**Not supported, and must be rejected with a clear error rather than silently mangled:**
ligands (the token axis is one token per *residue*), DNA/RNA (`mol_type` hardwired to 0),
modified residues, cyclic peptides, and real structural templates. `fromSequences` throws on
any letter outside the canonical 20 — **including `X`, `U`, `B`, `Z`**.

**Load-bearing gotcha:** `fromResidues` (the path a future "fold this selection" feature
would use) does **not** throw on non-canonical residues — it silently *excludes* them with a
diagnostic, and `hasBlockingDiagnostics` only counts `.missingBackbone`/`.noTemplateAtoms`.
Handing it a selection containing a ligand, a nucleic acid, or an MSE yields a successfully
featurized protein-only complex with the offending residues quietly gone. **RayMol must
inspect `structure.diagnostics` itself and refuse.**

MSA is out of scope for v1 (`alignments: [:]`, single-sequence mode), which also sidesteps
the MSA-depth limit. The Swift code supports a3m parsing and asserts bitwise parity against
Python, but the repo's own prose contradicts that, and the discrepancy is unresolved.

## Error taxonomy

#224 §E requires defined, testable failures. Python-side errors, all subclasses of
`pymol.CmdException`:

| #224 failure mode | Error | Raised by |
|---|---|---|
| unknown predictor | `PredictorNotFound` | registry lookup — no Swift equivalent exists |
| network failure | `WeightDownloadFailed` | streaming download; wraps `URLError`/`HTTPError`/timeout |
| checksum mismatch | `WeightChecksumMismatch` | digest compare; nothing published |
| disk full / unwritable | `WeightCacheUnwritable` | wraps `OSError`/`ENOSPC`; no Swift representation exists |
| malformed input | `PredictionInputError` | Python pre-validation + mapped Swift featurizer errors |
| platform unavailable | `PredictorUnavailable` | `check_available()` — no host, Simulator, unsupported OS |

Swift-side errors must be mapped to stable **string codes** in the status file, because
`BoltzError`'s ten cases carry no error code, domain, or numeric mapping. Three cases mean
something other than what they say and must not be reported as corrupt-artifact:

- `.missingTensor("confidence_module")` = *this pack has no confidence head* (a
  configuration problem — the structure-only pack loads fine but `predictScored` throws).
- `.tensorShapeMismatch(name: "sample_atom_coords", …)` is thrown **post-inference** on an
  internal invariant break.
- `CancellationError` is not a `BoltzError` at all.

`BoltzError` has **no OOM case and no device-unsupported case** — those are RayMol's to
synthesize, which is what `PredictSizeGuard` and `check_available()` are for.

## Weight bundle contract

The exporter writes exactly three files, flat, no subdirectories:

| File | Notes |
|---|---|
| `model.safetensors` | always one shard, never sharded |
| `manifest.json` | tensor table + quantization spec; ~3.1 MB, 11,280 tensor specs |
| `config.json` | architecture contract; ~2.7 KB |

Measured totals: confidence pack **558,824,147 B (532.9 MiB)**; structure-only pack
531,734,657 B. The README's "529 MB" and two other figures in that repo each describe a
different pack and are individually stale — **use the byte count of the artifact actually
uploaded.**

Ship the **confidence** pack. The confidence head is optional in the pack and a
structure-only pack loads fine, but `predictScored` then throws, and PAE is the only
confidence signal the port produces at all.

Zip layout: exactly those three entries at the archive root — no top-level directory, no
`__MACOSX`, no extras. Verify the **zip's** SHA-256, then assert the extracted set.

## Testing

TDD, offline, network mocked. New category `testing/tests/predict/`.

Conventions, verified in `testing/testing.py`:

- Routing split at `:692-697`: `test_*.py` → **pytest**; any other filename → **unittest /
  `PyMOLTestCase`**. `predict` is not in the `("properties","settings")` escape tuple.
- `--run all` globs `**/*.py` recursively (`:679`), so a new directory needs no registration.
- `PyMOLTestCase.setUp` (`:405-418`) does `cmd.reinitialize()`, `viewport(640,480)`, and
  **chdir to the defining file's directory**, so relative fixture paths resolve against
  `testing/tests/predict/`.
- `unittest.mock` is importable unguarded and already used in CI (`test_metal_pick.py:10`).
- Temp files: `testing.mktemp(suffix)` / `testing.mkdtemp()` (`:251-281`). `cmd.mktemp` does
  not exist.
- If any file is written pytest-style, add `testing/tests/predict/conftest.py` with the
  autouse `cmd.reinitialize()` fixture (mirror of `testing/tests/api/conftest.py`) — pytest
  runs after the unittest lane **in the same process** (`:723`).

Coverage, per #224's validation list:

- **Registry:** register, retrieve, unknown-name error, and swapping two implementations
  behind the interface.
- **WeightCache:** downloads once then serves from cache (assert the download function is
  invoked **exactly once**); checksum success; checksum mismatch leaves no cache and raises;
  an interrupted/partial download is never mistaken for valid (kill after `.part`, assert no
  `.ok`); correct extraction layout; re-download when the sentinel fails re-validation;
  concurrent callers produce one download.
- **Stub predictor:** full flow — declare weights → lazy fetch → run → return a structure —
  with a fixture zip and no Swift.
- **Error handling:** each of the six failure modes above.
- **`MLXRuntime` (Swift/XCTest):** min-wins arbitration, order-independence, per-owner
  bookkeeping, error passthrough, and that `MPNNRuntime` still installs its 96 MB through
  the shared owner.

The network is mocked by patching the module's `urlopen`, in preference to either idiom
already in the tree (`fetch_host` redirected to a `file://` mirror; a real local server on
an ephemeral port), because the download path here is ours rather than `cmd.file_read`'s.

### CI

**`--run all` executes nowhere in CI.** `build.yml` would auto-discover the new directory
but the workflow is `disabled_manually` at the GitHub level. The suite that runs is
`raymol-embedded-tests.yml`, which **hand-enumerates every test file** in one `--run` list —
28 of them on `master` as of 2026-08-11, terminating at line 75
(`testing/tests/raymol/scene_ttt.py`).

One edit: add a trailing `\` to the terminal line and one line for the **directory**:

```yaml
              testing/tests/predict
```

A directory argument is globbed by `testing.py:687-689`, so new files inside `predict/` run
automatically. This is the only variant that does not re-create the enumeration gotcha,
which is a recurring failure mode in this file: PR #259 had to retro-add seven files that
had been silently unrun.

**Rebase this branch onto `master` before touching that workflow.** The branch was cut at
`db718f11c`, which predates PR #259, so its copy of the file still holds the pre-#259 list
of 21. Editing the stale copy risks reverting those seven files back out of CI.

Any new third-party import must also be added to `:38`, which installs only
`setuptools wheel numpy cmake pillow pytest`.

**No CI workflow compiles Swift or runs XCTest.** Shared-target platform symbols have leaked
between macOS and iOS in both directions before (#174, #226/#238), so every Swift change
here must be hand-compiled for **both** slices before merge.

## Folder structure

```
modules/pymol/
  predicting.py              cmd-facing API only — thin, no logic
  predictors/
    __init__.py              registers the built-ins; the only place that does
    base.py                  Predictor ABC, PredictionSpec, PredictionJob, PredictionOptions
    errors.py                the six error types
    weights.py               WeightBundle, BundledSource, WeightCache
    host.py                  marker+tempfile transport to the Swift host; availability probe
    boltz2.py                first real predictor
    _template.py             copy-me skeleton (see below)
docs/predictors.md           the how-to below, as shipped documentation
testing/tests/predict/
  predict_registry.py        register / retrieve / unknown / swap
  predict_weights.py         download-once, checksum, partial, extraction, re-validation
  predict_errors.py          one test per failure mode in §Error taxonomy
  predict_stub.py            the stub predictor, full flow, no Swift and no network
  data/stub_bundle.zip       3-entry fixture with a known sha256
```

`setup.py:849-863 get_packages()` walks `modules/` directories, so `pymol/predictors/`
is packaged with no `setup.py` edit. Test fixtures resolve relatively because
`PyMOLTestCase.setUp` chdirs to the defining file's directory (`testing.py:405-418`).

Why a subpackage rather than one module: `predicting.py` stays the `cmd.*` surface and
nothing else, so adding a predictor never touches the file that `api.py` and `keywords.py`
depend on. Each predictor is then one self-contained file that can be read, tested, and
deleted independently.

## Predictor template

`modules/pymol/predictors/_template.py` — copy, rename, fill in. The leading underscore
keeps `__init__.py` from registering it.

```python
"""Skeleton for a new RayMol structure predictor.

Copy to modules/pymol/predictors/<your_id>.py, then follow docs/predictors.md.
Everything below is required unless marked optional.
"""
from .base import Predictor, PredictionSpec, PredictionOptions
from .errors import PredictionInputError, PredictionOptionError, PredictorUnavailable
from .weights import WeightBundle


class TemplatePredictor(Predictor):
    # -- Identity -----------------------------------------------------------
    id = 'template'                  # stable selector; never change it once shipped
    name = 'Template predictor'      # human-readable, for listings

    # -- Weights ------------------------------------------------------------
    # None if the method needs no weights. Hash and size are of the ZIP's bytes,
    # and `members` is the exact expected set of archive entries at the root:
    # WeightCache asserts it after extraction, because a predictor that loads a
    # partially-extracted bundle usually misbehaves instead of failing.
    weight_bundle = WeightBundle(
        id='template-v1',
        version='v1',
        url='https://github.com/<owner>/<repo>/releases/download/<tag>/bundle.zip',
        sha256='0' * 64,
        size=0,
        members=('config.json', 'model.safetensors'),
    )

    # -- Options ------------------------------------------------------------
    # Only what the backend genuinely honours. Anything omitted is REJECTED by
    # validate_options(), never silently ignored.
    option_defaults = {'recycling_steps': 3, 'diffusion_steps': 200, 'seed': 0}

    # -- Capability ---------------------------------------------------------
    def check_available(self):
        """Raise PredictorUnavailable if this cannot run here and now.

        Check the things that are true before any work: platform, OS version,
        whether a host capable of running the backend is present. Do NOT check
        whether weights are cached — that is the weight manager's job and it is
        allowed to fix it by downloading.
        """
        raise PredictorUnavailable(f'{self.id}: not implemented')

    # -- Input validation ---------------------------------------------------
    def parse_spec(self, sequence, *, name=''):
        """Turn user input into a PredictionSpec, or raise PredictionInputError.

        Reject here, loudly, rather than letting the backend silently drop
        residues it does not understand. Chain ids must be single uppercase
        characters so PDB columns stay aligned.
        """
        raise PredictionInputError('template: not implemented')

    def validate_options(self, options):
        unknown = set(options) - set(self.option_defaults)
        if unknown:
            raise PredictionOptionError(
                f'{self.id} does not support: {", ".join(sorted(unknown))}')
        merged = dict(self.option_defaults)
        merged.update(options)
        return PredictionOptions(**merged)

    # -- Run ----------------------------------------------------------------
    def submit(self, spec, options, weights_path):
        """Start the run and return a PredictionJob immediately.

        MUST NOT BLOCK. cmd.predict is reachable from the console, which runs on
        the main thread; blocking here stalls the render loop for the whole
        inference. Return a handle whose status() is a cheap poll.
        """
        raise NotImplementedError


PREDICTOR = TemplatePredictor()
```

## Adding a predictor — `docs/predictors.md`

1. **Copy the template** to `modules/pymol/predictors/<your_id>.py` and pick a permanent
   `id`. The id appears in user scripts and saved sessions, so treat it as API.
2. **Write the tests first.** Add `testing/tests/predict/predict_<your_id>.py` subclassing
   `pymol.testing.PyMOLTestCase`. Do not name it `test_*.py` unless you want the pytest lane
   — `testing.py:692-697` routes on that prefix. Mock the network by patching your module's
   `urlopen`; never reach a real server.
3. **Declare the weight bundle.** Publish the zip, then record the sha256 **of the bytes you
   uploaded** — re-exporting is not guaranteed to reproduce them bitwise. `members` must be
   the exact archive-root entry set.
4. **Implement `check_available`** so the predictor disappears cleanly where it cannot run,
   instead of failing mid-run. Platform, OS floor, host presence — not weight state.
5. **Implement `parse_spec` to reject, not repair.** If the backend silently ignores input it
   does not support, that is your problem to catch: verify what it does with a ligand, a
   nucleic acid, an `X`, and an empty chain, and raise for each. boltz-mlx's `fromResidues`
   is the cautionary case — it *excludes* non-canonical residues with a diagnostic and
   returns success.
6. **Implement `validate_options` to reject unknown options.** Accepting and ignoring a
   quality knob produces results the user believes are something they are not.
7. **`submit` must not block.** See the template's note.
8. **Register it** in `predictors/__init__.py` — the only file that changes outside your own.
9. **Add the test file** to the `--run` list in `.github/workflows/raymol-embedded-tests.yml`
   if you did not add the whole `testing/tests/predict` directory, and **rebase onto master
   first** — that list is hand-maintained and has silently dropped files before.
10. **If your predictor adds Swift**, hand-compile **both** the macOS and iOS slices before
    merging. No CI job compiles Swift, and the shared target has broken each platform from
    the other before.

## Phasing

| Phase | Deliverable | Blocked on |
|---|---|---|
| 0 | `MLXRuntime` extraction + tests | — (done in this branch) |
| 1 | Python framework: registry, `WeightCache`, errors, `testing/tests/predict/` | — |
| 2 | Promote boltz-mlx's test writer to `Sources/BoltzMLX/Write/StructureWriter.swift`; tag `v0.1.0` | — |
| 3 | Mint the artifact zip, hash it, publish as a GitHub Release asset | Phase 2 tag |
| 4 | SwiftPM dep, `BoltzJobManager`, `PREDICT:` marker, `PredictSizeGuard` | 2, 3 |
| 5 | End-to-end verification on macOS hardware | 1–4 |

Phase 1 is independently valuable and independently shippable: it is #224's original stated
scope, is fully offline-testable, and touches no Swift. If artifact hosting or the upstream
PR slips, Phase 1 still lands.

**Deferred to follow-ups:** iOS enablement (Simulator cannot run MLX at all, and every
on-device boltz run above 115 tokens was never completed because iOS suspends the app
mid-run); out-of-process inference isolation for both boltz and MPNNKit; MSA support;
migrating #249's `MPNN.mpnnpack` onto `WeightCache`.

## Risks

1. **Session loss on an uncatchable OOM** — mitigated but not eliminated by the preventive
   guard. State it in the issue.
2. **A 533 MiB post-install download on MAS** is technically legal (the entitlement set
   grants `network.client` and container writes) but App Review's stance on it is unknown.
3. **Accuracy claims must not be inherited.** Every number in boltz-mlx is
   agreement-with-upstream, not correctness — there is no lDDT/RMSD against experimental
   structures anywhere, and nothing was benchmarked at upstream's published compute level.
   Do not surface upstream's benchmark figures in RayMol's UI or docs.
4. **`einsum` memory landmine** — a three-way contraction in `AtomEncoder` once materialized
   28 GB in a single buffer at 384 tokens, against MLX's 22.6 GB maximum. Fixed upstream by
   two explicit two-step contractions. The general lesson applies to any future MLX work in
   RayMol, including MPNNKit.
