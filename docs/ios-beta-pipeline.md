# iOS beta pipeline (Xcode Cloud → TestFlight internal)

Every change to `master` that touches non-documentation files produces a
TestFlight build for internal testers.
Design rationale: `docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md`.

macOS is unaffected — it keeps the Developer-ID DMG + Sparkle + Homebrew-cask
path (`swiftui/make_dmg.sh`, `swiftui/publish_release.sh`).

## How it fits together

1. `.github/workflows/ios-deps-artifact.yml` builds `deps_ios` and publishes it
   as prerelease `ios-deps-<fingerprint>`. Runs only when a dep script changes.
2. Xcode Cloud, on each `master` change, runs
   `swiftui/ci_scripts/ci_post_clone.sh`: fetch that artifact, patch the
   Homebrew prefix in `swiftui/PyMOLBridge.xcconfig`, stamp the version,
   `xcodegen`, build `libpymol_core.a`, assert inputs.
3. The Archive action signs (Apple manages the certificates) and the TestFlight
   internal post-action distributes to the beta group.

## One-time setup (human only — cannot be scripted)

**Entry point: Integrate ▸ Create Workflow in Xcode.**
Not `Product ▸ Xcode Cloud` — that menu item does not exist in current Xcode.
The brief and early plan both said `Product`; that is wrong.

This cannot be done via the App Store Connect API: Apple exposes no
`POST /v1/ciProducts`. Creating a product also installs Apple's GitHub App on
the repository and accepts the Xcode Cloud terms, which requires a human
approving both in the UI.

### What the wizard creates — and what to disable immediately

The wizard creates an **enabled `Default` workflow** that archives BOTH
`PyMOLViewer_macOS` and `PyMOLViewer_iOS` on every push to `master`, clean.
Every one of those runs fails (master has no staged `deps_ios` artifact) and
burns Xcode Cloud compute hours. **Disable or delete it before the first
commit lands on master.**

The `Default` workflow has already been disabled (`isEnabled=false`) on the
current product. Do not re-enable it.

### Current App Store Connect identifiers (for reference)

| Resource | ID |
| --- | --- |
| `ciProduct` (RayMol) | `31B61601-5F00-4089-8306-3F23CFFF1778` |
| `scmRepository` (javierbq/RayMol) | `910c12f6-c5bd-4936-bcc5-d46a86db32f0` |
| `Default` workflow (disabled) | `E3C4DD78-DED4-4E91-8A8F-E9E75CBBAF37` |
| `SPIKE - validation` workflow | `d6ebe935-3298-4b47-831a-b03af5ec4fe2` |

Delete the `SPIKE - validation` workflow once the production `iOS Beta (master)`
workflow is running successfully.

## App Store Connect workflow settings

Product RayMol, App ID `6781513038`, repository `javierbq/RayMol`.

| Setting | Value |
| --- | --- |
| Name | `iOS Beta (master)` |
| Start Condition | **Branch Changes** on `master` |
| Files/folders condition | **Exclude** `docs/**` and `*.md` |
| Auto-cancel Builds | **On** |
| Environment | Xcode latest release, macOS latest |
| Action | **Archive**, scheme `PyMOLViewer_iOS`, platform iOS |
| Restrict Editing | **On** (`isLockedForEditing: true`; Apple requires it for review-eligible builds — see ordering note below) |
| Post-action | TestFlight **internal** testing → group `Beta` |
| Post-action | Email and/or Slack notification on failure |

`scripts/asc_xcode_cloud_workflow.py` can create most of these settings via the
API. Run it with `--dry-run` first to inspect the payload.

**Required ordering — the lock must come last:**
A locked workflow (`isLockedForEditing: true`) is **read-only in the UI** — the
edit affordance is disabled. The TestFlight post-action and notifications cannot
be set via the API (see that script's "What this cannot set" section), so the
workflow must be editable when those steps happen. The correct sequence is:

1. `python3 scripts/asc_xcode_cloud_workflow.py --write` — creates the workflow
   **unlocked** so the UI is editable.
2. In App Store Connect → Xcode Cloud → *iOS Beta (master)* → **Edit**:
   add the TestFlight Internal Testing post-action (group `Beta`) and a failure
   notification (email and/or Slack).
3. `python3 scripts/asc_xcode_cloud_workflow.py --lock --update-id <ID> --write`
   — patches `isLockedForEditing` to `true` for review eligibility. Do this
   **after** step 2; a locked workflow cannot be edited.

A files/folders condition is only available for branch, pull-request and tag
changes — not for schedules. That is a deliberate reason this pipeline is
change-triggered rather than time-triggered; Xcode Cloud cannot skip a
scheduled build when nothing changed.

## Two Xcode Cloud API constraints worth knowing

**`workflow_dispatch` requires the workflow file to be on the default branch.**
`gh workflow run "iOS deps artifact"` reports "could not find any workflows
named ..." even with the branch pushed, and `gh workflow list` omits the
workflow entirely. Branch-defined `push`/`pull_request` triggers DO fire.
Bootstrap routes when the file is not yet on `master`:
- Temporarily add the feature branch to the workflow's `branches:` list and
  disable the `paths:` filter for one run, or
- Land the file on `master` first, then trigger `workflow_dispatch`.

**An Xcode Cloud workflow cannot have zero start conditions.**
`POST /v1/ciWorkflows` returns `409 "At least one start condition must be
provided"` when `branchStartCondition` is absent. "Manual-only" cannot be
expressed by omission. Workaround: point the branch condition at a pattern that
never matches (`__spike-manual-only-never-matches__`); manual runs via
`POST /v1/ciBuildRuns` are unaffected by the start condition.

A manual build run is **rejected unless the branch is named in the start
condition**: `409 branch <name> is not associated with the workflow`. This means
a workflow that can build any arbitrary branch does not exist — the branch must
be listed explicitly in `branchStartCondition.source.patterns`.

`POST /v1/ciBuildRuns` takes the branch as a **relationship** to
`scmGitReferences`, not a `sourceBranchOrTagName` attribute.

## Measured timing (replaces the plan's estimates)

| Step | Measured | Plan estimate |
| --- | --- | --- |
| `ios-deps-artifact.yml` (full build) | **6m 39s** | ~30 min |
| deps tarball size | **66 MB** (from 267 MB pruned tree; 304 MB before pruning) | — |
| iOS core build on Xcode Cloud | **33 seconds** | 10–15 min |
| Full Xcode Cloud build (ARCHIVE action) | **~4m 10s** | — |

Current published artifact: `ios-deps-a0663ba183cc`.

## Environment facts baked into `ci_post_clone.sh`

- `brew --prefix` on Xcode Cloud resolves to **`/usr/local`**, not
  `/opt/homebrew`. Never hardcode either path.
- `cmake` is NOT preinstalled on Xcode Cloud; Homebrew is, and works without
  `sudo`.
- Required Homebrew packages: `cmake glm xcodegen libpng freetype`. The iOS
  branch of `appkit/CMakeLists.txt` reads PNG and freetype **headers** from
  `$BREW/include` while linking cross-compiled `.a` files from
  `deps_ios/install_device`. GLEW, libxml2, libomp and netcdf are excluded by
  `NOT PYMOL_IOS` guards.
- **Two** places need the brew prefix:
  1. The exported `PYMOL_EXTERNAL_PREFIX` env var, which CMake reads.
  2. `swiftui/PyMOLBridge.xcconfig` line 22, which is hardcoded to
     `/opt/homebrew` in the committed file and fed to every compile unit as
     `-I$(PYMOL_EXTERNAL_PREFIX)/include`. Build 4 failed with
     `'glm/vec3.hpp' file not found` for exactly this reason.
     `ci_post_clone.sh` patches the line in-place with `sed` and then
     verifies the substitution applied before proceeding.
- The CMake core build reads Python headers from the
  **`ios-arm64_x86_64-simulator`** slice even for device builds, and silently
  falls back to an uninstalled Homebrew `python@3.13` if `deps_ios` is absent.
  Build 2 failed in `contrib/champ` with `'Python.h' file not found` for this
  reason. `deps_ios` must be staged before the core build, never after.

## Testers

Internal testing requires **no Beta App Review**. Up to 100 testers, each on
up to 30 devices. A tester must be an App Store Connect user with the Account
Holder, Admin, App Manager, Developer or Marketing role.

Add one: App Store Connect → Users and Access → invite with one of those roles,
then TestFlight → Internal Testing → group `Beta` → add the tester.

Builds remain installable for **90 days**, and up to **100 builds** can be
active at once. At a few builds per week this stays well inside both limits.
If it approaches them, expire the oldest builds in App Store Connect.

## Versions and build numbers

- **Marketing version** is derived by `scripts/nightly_version.sh` as the next
  minor after `swiftui/project.yml`'s `MARKETING_VERSION` (e.g., `1.8.0` →
  betas are `1.9.0`).
- **Build number** is Xcode Cloud's `CI_BUILD_NUMBER`.
- App Store Connect requires the `(version, build)` pair to be unique. iOS does
  not require build numbers to increase across versions; only macOS does.

**Convention when cutting a release:** bump `MARKETING_VERSION` in
`swiftui/project.yml` **to** the released version — never in advance.
Pre-bumping makes betas leapfrog the version being prepared.

`scripts/tests/run_nightly_version_test.sh`'s real-repo check asserts only a
format (`^[0-9]+\.[0-9]+\.0$`), deliberately not a literal value, so it
survives releases without needing an update. But failing to bump
`MARKETING_VERSION` at release time means betas will carry a version number
higher than the release until you do.

Never derive the version from git tags: this repo carries the inherited PyMOL
version line, so the newest tag by version sort is `v3.2.0` while RayMol's own
releases top out at `v1.8.0`.

## Bumping a dependency

1. Edit the pin in `scripts/fetch_ios_python.sh`, `scripts/build_ios_deps.sh`,
   `scripts/build_numpy_ios.sh` or `scripts/bundle_biopython.sh`.
2. Merge to `master`. The deps workflow fires automatically on the changed
   script, and a new fingerprint yields a new artifact.
3. The next Xcode Cloud build fetches the new fingerprint automatically.

To rebuild without a pin change:
```bash
gh workflow run "iOS deps artifact" -R javierbq/RayMol
```
This only works if the workflow file is on `master` (see bootstrap note above).

Keep old `ios-deps-*` prereleases while any branch still fingerprints to them.
Deleting one breaks builds of those commits.

**Download-stats note:** `.github/workflows/download-stats.yml` snapshots ALL
releases and their assets, so `ios-deps-*` prereleases now appear in the gist
time series. This is harmless today because any downstream analysis filters by
`.dmg` assets for the macOS release chart. If the download-stats consumer is
ever updated, exclude assets matching `deps_ios-*.tar.gz` explicitly.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no published deps artifact for fingerprint <fp>` | A dep script changed without the deps workflow running. Run `gh workflow run "iOS deps artifact" -R javierbq/RayMol` on `master`, then re-run the build. |
| `shasum: WARNING: 1 computed checksum did NOT match` | Truncated download, usually the proxy. Re-run the build. |
| `MISSING: deps_ios/...` from `assert_ios_build_inputs.sh` | The artifact was built from an incomplete tree. Re-run the deps workflow and inspect its `prune_ios_deps.sh` output. |
| `WRONG ARCH: libpymol_core.a archs = 'x86_64'` | `build_ios.sh` ran without `device`. `ci_post_clone.sh` passes it; check for a local edit. |
| Upload rejected as a duplicate build | `apply_ci_versions.sh` did not apply. It verifies its own substitution — check the log for its `project.yml -> ...` line. |
| Build not triggered by a push | The files/folders condition excluded every changed path (docs-only change). Expected behaviour. |
| `'glm/vec3.hpp' file not found` or `'png.h' file not found` | Homebrew prefix mismatch. Either the `PYMOL_EXTERNAL_PREFIX` env var or `PyMOLBridge.xcconfig` line 22 still points at `/opt/homebrew`. Check the `sed` patch in `ci_post_clone.sh`. |
| `'Python.h' file not found` (in `contrib/champ`) | `deps_ios` was not staged before the core build (step 5 ran before step 2). Check step ordering in `ci_post_clone.sh`. |
| `gh workflow run` reports "could not find any workflows named ..." | The workflow file is not on the default branch yet. See the bootstrap note above. |
| Xcode Cloud build start returns `409 branch ... is not associated with the workflow` | The branch being built is not listed in the workflow's start condition patterns. Add it, or switch to a build run on the branch already in the condition. |
| Default workflow fires on every push and fails | The `Default` wizard-created workflow is still enabled. Disable or delete it in App Store Connect. |

## Local checks

Run all five test suites before pushing:

```bash
bash scripts/tests/run_ios_deps_fingerprint_test.sh
bash scripts/tests/run_nightly_version_test.sh
bash scripts/tests/run_prune_ios_deps_test.sh
bash scripts/tests/run_apply_ci_versions_test.sh
bash scripts/tests/run_assert_ios_build_inputs_test.sh
```
