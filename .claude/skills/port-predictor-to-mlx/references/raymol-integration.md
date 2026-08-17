# Phase 6 — RayMol integration + publishing

Two halves: **wire the package into RayMol** so `cmd.predict` reaches it, and (if open-sourcing)
**publish a curated public repo** + weights. The `boltz-mlx` + RayMol `#224` work is the template.

## Wiring the SPM package into RayMol

- **Consume by `url:` + `from: <tag>`, never `path:`.** `swiftui/project.yml` points `<Net>MLX` at
  `url: https://github.com/javierbq/<net>-mlx.git`, `from: <tag>`; `project.pbxproj` uses an
  `XCRemoteSwiftPackageReference`; `Package.resolved` pins the tag + commit. Developing against a
  local `path: ../../../<net>-mlx` is fine, but shipping it is **the** recurring un-mergeable
  defect (hit on #269 and again on #293). Flip it back before every PR and grep the diff to be
  sure.
- **Compile both slices by hand.** No CI compiles iOS. Build `PyMOLViewer_macOS` *and* the iOS
  target locally; the shared Swift boundary breaks in both directions and only shows up here.
  `xcodebuild` needs `-skipPackagePluginValidation` for the MLX plugin packages.
- **Two-stage macOS build.** Build the C++ core first, *then* `xcodebuild` — `xcodebuild` alone
  silently links a stale `libpymol_core.a`. Verify the **runtime** dylib (`RayMol.debug.dylib`),
  not the source.

## Weights as a verified release asset

The quantized pack is too big for git and must be fetched at runtime:

- Publish `<net>-mlx-int8-v1.zip` as a **GitHub release asset** on the package repo. Record its
  exact byte size and **sha256 computed from the *served* asset** (download it back, re-hash — do
  not trust the local file's hash).
- The Swift/Python weight cache downloads, verifies sha256, extracts, then writes a sentinel
  (`.ok`) **last** and atomically (`os.replace`). Pin the expected hash in the predictor.
- Adding a second precision is a new predictor id that overrides only `weight_bundle` and a new
  release asset — one Swift runtime serves both packs (`host.submit` passes `weights_dir` per job).
- Budget an hour for a cold fetch — the release CDN has run at **0.5–1 MB/s** for a ~1 GB asset;
  don't read a long download as a hang.

## The `cmd.predict` predictor plugin (Python side)

Mirror `modules/pymol/predictors/`: `errors, base, registry, weights, host, <net>, _template`.
The Swift bridge and embedded-interpreter traps that cost real debugging:

- **`setenv` from C must precede `Py_InitializeFromConfig`.** Python snapshots `os.environ` once at
  startup; a later C `setenv` is visible to C `getenv` but **invisible to `os.environ`**. Set
  `RAYMOL_PREDICT_HOST` (and any config the Python layer reads) *before* init.
- **Do long work on a Swift queue, not a Python thread.** A background Python thread is
  GIL-starved in the embedded app (~364 KB/s zip extraction, ~1000× too slow) because the main
  thread holds the GIL persistently. `cmd.predict`'s synchronous `ensure()` is fine; anything
  concurrent must be Swift.
- **Cancel must actually interrupt inference.** If `predict()` runs in a detached `Task{}` that is
  never `.cancel()`d, the model's `Task.checkCancellation()` can't fire and "cancel" is a no-op —
  a confirmed HIGH defect on #269. Thread the cancellation through.
- **The first uncached call blocks on a ~500 MB download.** If `predict()` is documented "returns
  immediately" but synchronously runs `WeightCache.ensure()`, it blocks the main thread silently
  under `quiet=1`. Make the download explicitly asynchronous / surfaced.
- **Feedback is invisible while the main thread is blocked** — surface progress off the blocked
  thread, or the user sees a frozen app during a legitimate long run.

## Wire the CI so the Python tests actually run

RayMol's CI lists test files **by hand**, so a new `testing/tests/predict/` silently never runs
unless you add it. Add the **directory** to `raymol-embedded-tests.yml` (the one variant that
can't re-orphan files) and confirm the full list runs green locally. Python-layer test traps that
passed-while-broken: `colorprinting` has **no `info`** (only error/warning/suggest/parrot) and
`quiet=0` is the *default* command path — a suite testing only `quiet=1` can be 48/48 green while
every message branch raises `AttributeError`. Test both, and assert reflectively that every
`colorprinting.X` a module calls exists. A knob you intend to *reject* still needs to be a named
parameter or Python raises `TypeError` before your validation runs.

## Publishing a curated public repo (if open-sourcing)

A public repo is effectively permanent (scraped/cached even if deleted) — do a safety pass first
and get explicit sign-off before pushing:

- **Scan for and strip:** internal hostnames (e.g. `*.accipiterbio.internal`), Apple team IDs,
  device UDIDs, personal/work emails, company bundle ids / namespaces, and any company-internal
  validation work. A scrub-in-place is not enough — identifiers persist in `git log`.
- **Push a fresh, squashed history** (orphan commit) authored as the **public** identity
  (`javierbq@gmail.com`), so nothing leaks via `git log`.
- **Keep the upstream LICENSE + attribution** (Boltz is MIT); add a README describing the port.
- **Exclude weights** — keep `.artifacts/` gitignored; users export their own from a checkpoint
  they supply, per the README quick-start.
- Verify the **remote** is clean (0 sensitive matches) after pushing, not just the local tree.

Sending anything to a public host is outward-facing and irreversible — confirm with the user before
the first push, and prefer HTTPS if their `~/.ssh/config` is broken (don't edit their ssh config).
