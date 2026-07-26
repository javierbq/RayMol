# iOS beta builds to TestFlight via Xcode Cloud

**Date:** 2026-07-26
**Status:** Design approved, pending implementation plan

## Goal

Ship RayMol iOS/iPadOS builds to beta testers automatically, without a human
driving a build. Today every iOS submission is hand-run: `archive_appstore.sh
iOS` archives, but its export step uses account-based signing, so the export and
the `altool` upload have to be re-run by hand with App Store Connect API-key
flags. This replaces that with a pipeline that produces a TestFlight build
whenever `master` moves.

**On the name:** "nightly" is the colloquial label for this stream, but it is
triggered *per change to `master`*, not on a clock — see
[Decisions](#decisions). Same outcome, strictly less waste: testers get a build
whenever master actually moves, and no build when it doesn't.

Scope is **iOS/iPadOS only**. macOS keeps its existing Developer-ID DMG +
Sparkle + Homebrew-cask release path (`make_dmg.sh` / `publish_release.sh`)
unchanged; nothing here touches it.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| CI system | **Xcode Cloud** | Apple performs distribution signing, so no Developer ID / distribution certificate lives in a repo secret. The 1.8.0 submission needed an Admin-role ASC key and hit "Cloud signing permission error" with App-Manager; taking signing out of our hands removes that whole class of failure. |
| TestFlight track | **Internal only** | Internal needs no Beta App Review. External forces a *clean, uncached* build, caps submissions at six per 24 h, and serialises to one build per version in review — all hostile to a per-merge stream. |
| `deps_ios` provisioning | **Prebuilt artifact, fetched per build** | Xcode Cloud has no arbitrary-directory cache. Rebuilding the 618 MB tree nightly would dominate cost and re-run the fragile numpy cross-build every time. |
| Trigger | **Branch Changes on `master`** | Xcode Cloud cannot skip a *scheduled* build when nothing changed. Per-change builds are inherently change-gated, and they alone support Apple's files/folders custom conditions. |
| Marketing version | **Derived from `project.yml`** | Auto-advancing, deterministic, offline, and immune to the inherited PyMOL tag line (see [Versioning](#versioning)). |

## Architecture

Two pipelines, split along how often their inputs change.

```
scripts/{fetch_ios_python,build_ios_deps,build_numpy_ios,bundle_biopython}.sh
        │  (changes only on a pin bump)
        ▼
[GitHub Actions: ios-deps-artifact]  ──►  GitHub Release  ios-deps-<fingerprint>
                                             │  deps_ios-<fingerprint>.tar.gz
                                             │  deps_ios-<fingerprint>.tar.gz.sha256
                                             │
master ──change──► [Xcode Cloud]  ci_post_clone.sh ──fetch + verify──┘
                        │  derive version, set build number, xcodegen,
                        │  build libpymol_core.a (device)
                        ▼
                     Archive  (Apple signs)  ──►  TestFlight internal group
```

### Why the split

Everything in `deps_ios` is pinned third-party code: a BeeWare
`Python.xcframework` (tag pinned to `3.13-b12`, because b13+ moved the stdlib to
`lib-<arch>/` and would silently break bundling), freetype 2.13.3, libpng
1.6.44, numpy 2.4.6, and Biopython. It changes only when someone edits a dep
script or bumps a pin. Rebuilding it per commit costs ~30 minutes of the ~35-40
minute build for zero benefit.

## Pipeline 1 — `deps_ios` artifact

New workflow `.github/workflows/ios-deps-artifact.yml`, `runs-on: macos-latest`
(arm64).

**Triggers:** `workflow_dispatch`, plus `push` to `master` touching any of
`scripts/setup_ios_deps.sh`, `scripts/fetch_ios_python.sh`,
`scripts/build_ios_deps.sh`, `scripts/build_numpy_ios.sh`,
`scripts/bundle_biopython.sh`.

**Steps:**

1. `brew install cmake glm`
2. Host Python 3.13 via `actions/setup-python`, then
   `pip install meson ninja cython build lief`. `build_numpy_ios.sh` requires
   `lief` for the MH_BUNDLE → MH_DYLIB rewrite and its own precheck already
   asserts these imports. Note it defaults `PYHOST` to
   `$PYMOL_EXTERNAL_PREFIX/bin/python3.13`, so either set `PYHOST` to the
   `setup-python` interpreter or install into the Homebrew one — the plan must
   pick one explicitly.
3. Run `scripts/setup_ios_deps.sh` unmodified — it is already idempotent and
   ordered.
4. **Prune** to only what the Xcode build consumes, per
   `swiftui/PyMOLBridge.xcconfig`:
   - keep `Python.xcframework/` (with Biopython staged into
     `<slice>/lib/python3.13/site-packages`), `install/`, `install_device/`,
     `numpy-ios/{simulator,device}/`
   - drop `build_freetype*`, `build_libpng*`, `build_python_ios`, the extracted
     `freetype-*`/`libpng-*` source trees, and `*.tar.xz`
5. `tar -czf` the pruned tree; emit a `.sha256` beside it.
6. Publish both as assets on a GitHub **prerelease** tagged
   `ios-deps-<fingerprint>`, via `gh release create` using the workflow's
   built-in `GITHUB_TOKEN`. Prerelease so it never becomes `latest` and cannot
   disturb the Sparkle appcast's `latest/download/appcast.xml` contract used by
   the macOS updater. Re-publishing an existing fingerprint is a no-op, not an
   error — the workflow is safe to re-run.

Immutable, fingerprint-tagged releases mean an older commit still resolves the
deps it was built against.

### The fingerprint

New `scripts/ios_deps_fingerprint.sh` emits the **first 12 hex characters of a
sha256** over the four dep scripts plus `setup_ios_deps.sh`, in a fixed order.
Hashing the script bodies covers the pins implicitly, since every pin
(`PY_APPLE_SUPPORT_TAG`, `FREETYPE_VERSION`, `LIBPNG_VERSION`,
`NUMPY_VERSION`) is a default literal inside those scripts. **Both pipelines
call this same script**, so code and deps cannot silently mismatch — there is no
lockfile to drift.

If the nightly computes a fingerprint with no published artifact, it **fails
loudly** telling the operator to run the deps workflow. It must never fall back
to building deps inline or to a "closest" artifact: building today's core
against yesterday's numpy is exactly the stale-artifact failure mode this repo
has been bitten by before (`make_dmg.sh`'s staleness assertions exist for the
same reason).

## Pipeline 2 — Xcode Cloud

### Repository side

Apple requires custom build scripts in a directory named `ci_scripts` located
beside the Xcode project, and recognises **only one per repository**. The
project is `swiftui/PyMOLViewer.xcodeproj`, so: **`swiftui/ci_scripts/`**.

Scripts run with `ci_scripts` as the working directory, under `zsh`, **without
`sudo`**. Network egress goes through a mandatory proxy exposed as `HTTP_PROXY`
/ `HTTPS_PROXY`; `curl` honours these by default.

**`swiftui/ci_scripts/ci_post_clone.sh`:**

1. `cd "$CI_PRIMARY_REPOSITORY_PATH"` (`/Volumes/workspace/repository`)
2. `brew install cmake glm xcodegen` — Homebrew is preinstalled. `glm` is
   required even for iOS: `appkit/CMakeLists.txt` resolves `glm/glm.hpp` from
   `PYMOL_EXTERNAL_PREFIX` on the iOS path, not from `deps_ios`.
3. `export PYMOL_EXTERNAL_PREFIX="$(brew --prefix)"` rather than trusting the
   `/opt/homebrew` default.
4. Fetch `deps_ios-<fingerprint>.tar.gz` + `.sha256`, **verify the checksum
   before extracting**, unpack to `deps_ios/`. The repo is public, so this needs
   no token.
5. `MARKETING_VERSION` ← `scripts/nightly_version.sh`;
   `CURRENT_PROJECT_VERSION` ← `$CI_BUILD_NUMBER`. Both applied as an **in-place
   edit of `swiftui/project.yml` inside the ephemeral CI checkout, never
   committed** — the repo keeps its release values, and the edit exists only so
   `xcodegen` picks them up in the next step.
6. `cd swiftui && xcodegen generate` — `project.yml` is the source of truth and
   the committed `.pbxproj` can lag it. `make_dmg.sh` and `archive_appstore.sh`
   both regenerate for this reason; skipping it is how PR #124's app-icon
   setting was once reverted.
7. `bash swiftui/build_ios.sh device` → `build_ios_device/libpymol_core.a`
8. **Assert before handing off to `xcodebuild`:** `libpymol_core.a` exists and
   `lipo -archs` reports `arm64`; every `deps_ios` path named in
   `PyMOLBridge.xcconfig` exists. Fail loudly — a missing dep otherwise
   surfaces as an opaque link error minutes later.

No `ci_pre_xcodebuild.sh` or `ci_post_xcodebuild.sh` is needed for v1. Build
notifications use Xcode Cloud's native email/Slack post-actions rather than a
script.

### App Store Connect side

Configured in the Xcode Cloud UI, not in the repo:

- **Start condition:** Branch Changes on `master`, with a files/folders custom
  condition excluding `docs/` and top-level `*.md`. (Custom conditions are
  documented for branch/PR/tag changes — *not* for schedules. This is a
  concrete benefit of the per-change trigger.)
- **Auto-cancel Builds: ON** — a burst of merges supersedes queued archives
  instead of stacking redundant ones.
- **Action:** Archive, iOS.
- **Restrict Editing: ON** — Apple requires it for builds eligible for review.
- **Post-action:** TestFlight internal testing → a dedicated internal group
  (e.g. "Beta").
- **Post-action:** email and/or Slack notification on failure.

## Versioning

`CFBundleVersion` ← `CI_BUILD_NUMBER`, a monotonic integer Xcode Cloud assigns.
This replaces the value hardcoded in `project.yml` (currently `23`), which would
otherwise make every upload a duplicate after the first.

Apple's actual constraint is that the **`(CFBundleShortVersionString,
CFBundleVersion)` pair must be unique**. iOS does *not* require build numbers to
increase across marketing versions — only macOS does — so `CI_BUILD_NUMBER` is
sufficient without coordination against the macOS release line.

### `scripts/nightly_version.sh`

Reads `MARKETING_VERSION` from `swiftui/project.yml` and emits
`<major>.<minor+1>.0`. Today `1.8.0` → **`1.9.0`**.

**It must not derive the version from git tags.** The repo carries the
inherited PyMOL version line, so `git tag | sort -V | tail -1` yields `v3.2.0`
while RayMol's own releases top out at `v1.8.0`. A tag-based implementation
would stamp betas `3.3.0` and permanently burn that version in App Store
Connect — versions cannot be deleted. The script will carry this rationale as a
header comment.

It **hard-fails** on a missing or malformed `MARKETING_VERSION` rather than
defaulting. A wrong version here is unrecoverable, so guessing is worse than
stopping.

The line advances by itself: `publish_release.sh` already asserts the packaged
version matches `project.yml`, so cutting 1.9.0 sets that field to `1.9.0` and
the beta stream moves to `1.10.0`.

**Convention this imposes:** bump `project.yml`'s `MARKETING_VERSION` *to* the
release version as part of cutting a release, not in advance. Pre-bumping makes
betas leapfrog the version actually being prepared.

## Export compliance

Already handled — `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO` is set in
`project.yml`. Without it every upload would stall in "Missing Compliance"
awaiting a manual answer, which would defeat automation. No change needed;
noted so it is not accidentally removed.

## Risks to validate empirically on the first run

These are genuine unknowns, not things to design around speculatively. Each has
a fallback.

1. **Do files `ci_post_clone.sh` writes into the repo survive into
   `xcodebuild`?** Apple states scripts' created files are deleted and are not
   shared between scripts, but universal practice (CocoaPods, xcodegen) depends
   on repository mutations persisting. The wording is most plausibly about the
   script's own temp area, not `CI_PRIMARY_REPOSITORY_PATH`.
   *Fallback:* move dep fetch + core build into `ci_pre_xcodebuild.sh`; failing
   that, commit the pruned `deps_ios` via Git LFS (preinstalled on Xcode Cloud).
   **This is the single assumption the whole design rests on — prove it with a
   throwaway build before building anything else.**

2. **Xcode Cloud's build timeout.** Undocumented; nowhere in Apple's Xcode
   Cloud documentation. A full PyMOL core compile plus archive is long enough
   that a hidden ceiling is a real risk.
   *Fallback:* measure the first successful run; if it is close to any observed
   ceiling, prebuild more (e.g. publish the core as an artifact too) or reduce
   parallelism-induced overhead.

3. **Does the TestFlight-internal post-action actually auto-distribute?**
   Apple's docs conflict: one page says Xcode Cloud builds must be added to
   groups manually, another describes an internal-testing post-action that
   distributes automatically.
   *Fallback:* an ASC API call to attach the build to the internal group,
   reusing the existing JWT/ES256 tooling pattern in
   `.claude/skills/cut-mas-release/scripts/asc_status.py`.

## Cost

25 compute hours/month are included with the Apple Developer Program; the next
tier is 100 h at US$49.99/month. A compute hour is the **sum of per-action
execution time**, not build wall-clock, and parallel actions each bill.

With deps prebuilt, a build is roughly: `brew install` (~1-2 min) + deps fetch
and verify (~2-4 min) + core build (~10-15 min) + xcodegen and archive (~10-15
min) ≈ **30-40 min**. Per-merge rather than nightly, at RayMol's observed merge
cadence, this sits well inside the free tier. Numbers are estimates until the
first run reports actual usage; Apple exposes usage as CSV in App Store Connect
under Users and Access → Xcode Cloud.

## Verification

The design is done when:

1. A throwaway Xcode Cloud build proves risk 1 (deps survive into `xcodebuild`).
2. The deps workflow publishes an artifact, and a build fetches it, verifies its
   checksum, and links against it.
3. A build lands in TestFlight with the expected marketing version (`1.9.0`) and
   a `CI_BUILD_NUMBER` build number, and an internal tester can install it on a
   device.
4. A docs-only commit to `master` produces **no** build.
5. A deliberately broken commit fails the build and sends a notification,
   without publishing to TestFlight.

## Out of scope for v1

- **A test action before archiving.** Would need a second simulator-slice core
  build, roughly doubling compute. Additive later; the build itself already
  gates compile errors.
- **Build retention janitor.** Internal builds expire after 90 days and Apple
  allows up to 100 shared builds. Per-merge cadence will not approach that
  soon; revisit if it does.
- **External TestFlight / public link.** Requires clean builds, Beta App Review,
  and respects a six-per-24 h submission cap. If wanted later, promote a
  known-good beta by hand rather than automating the external track.
- **macOS.** Unchanged.

## Apple constraints this design depends on

Load-bearing facts, verified against Apple documentation rather than
recollection:

- No arbitrary-directory cache in Xcode Cloud; derived data is cached
  implicitly, with no documented cache key/path mechanism —
  <https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference>
- `ci_scripts` hooks, location, cwd, `zsh`, no `sudo`, one directory per repo —
  <https://developer.apple.com/documentation/xcode/writing-custom-build-scripts>
- `CI_BUILD_NUMBER`, `CI_PRIMARY_REPOSITORY_PATH`, `HTTP_PROXY`/`HTTPS_PROXY` —
  <https://developer.apple.com/documentation/xcode/environment-variable-reference>
- Homebrew, CocoaPods, and Git LFS preinstalled; Carthage not —
  <https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud>
- External TestFlight requires a clean build —
  <https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution>
- External review, one-build-per-version-in-review, six submissions per 24 h —
  <https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers>
- Internal testing needs no Beta App Review; 100 testers, 30 devices each —
  <https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers>
- Custom conditions apply to branch/PR/tag changes, not schedules —
  <https://developer.apple.com/documentation/xcode/configuring-start-conditions>
- `(version, build)` pair uniqueness; macOS alone requires increasing builds —
  <https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds>
- Compute hours: 25 included, 100 h at US$49.99/mo, billed as summed per-action
  time — <https://developer.apple.com/xcode-cloud/>

Not documented anywhere, and therefore treated as unknown above: any Xcode
Cloud build timeout, the precise scope of "other cached information", and
whether a failed upload consumes a build number.
