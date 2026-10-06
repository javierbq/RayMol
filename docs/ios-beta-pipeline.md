# iOS beta pipeline (Xcode Cloud → TestFlight internal)

Every change to `master` that touches non-documentation files produces a
TestFlight build for internal testers.
Design rationale: `docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md`.

A sibling workflow, **macOS Beta (master)**, does the same for the Mac: every
such change also produces a Mac App Store-variant TestFlight build. See
[macOS beta](#macos-beta-macos-beta-master) below. Public macOS releases are
unaffected — they keep the Developer-ID DMG + Sparkle + Homebrew-cask path
(`swiftui/make_dmg.sh`, `swiftui/publish_release.sh`) and the manual Mac App
Store path (`swiftui/archive_appstore.sh`).

## How it fits together

1. `.github/workflows/ios-deps-artifact.yml` builds `deps_ios` and publishes it
   as prerelease `ios-deps-<fingerprint>`. Runs only when a dep script changes.
2. Xcode Cloud, on each `master` change, runs
   `swiftui/ci_scripts/ci_post_clone.sh`: fetch that artifact, patch the
   Homebrew prefix in `swiftui/PyMOLBridge.xcconfig`, stamp the version,
   `xcodegen`, build `libpymol_core.a`, assert inputs.
3. The Archive action signs (Apple manages the certificates) and the TestFlight
   internal post-action distributes to the beta group. Builds are archived
   `INTERNAL_ONLY` — permanently internal-only, never App Store eligible — and
   whether the post-action truly auto-distributes is unverified. See
   *Build distribution audience* below before relying on either.

## macOS beta (`macOS Beta (master)`)

Before this workflow existed, Mac testers only ever got a TestFlight build when
someone cut a Mac App Store release by hand (`cut-mas-release`), so TestFlight
on the Mac showed exactly one build per release while iOS got one per master
push.

**What runs.** The same `swiftui/ci_scripts/ci_post_clone.sh` — Apple allows one
`ci_scripts` directory per repository — which asks `scripts/ci_platform.sh`
whether the action is iOS or macOS (`CI_PRODUCT_PLATFORM`, cross-checked with
`CI_XCODE_SCHEME`). For macOS it:

1. writes the same two plugin-trust defaults as iOS (Design mode links
   mlx-swift into the macOS slice too);
2. `brew install`s the iOS set plus **`libomp`** — the app links
   `opt/libomp/lib/libomp.a` statically — and patches the Homebrew prefix in
   `PyMOLBridge.xcconfig` exactly as for iOS;
3. stages `deps_macos` with `scripts/setup_macos_deps.sh`: python-build-standalone
   3.13 plus pinned numpy and Biopython, imported through the embedded
   interpreter to prove the tree works. There is no prebuilt artifact; it all
   downloads from upstream in about a minute;
4. stamps the version and build number exactly as for iOS;
5. rewrites `project.yml` as the **Mac App Store variant** with
   `scripts/apply_mas_restrictions.sh` — Sparkle package stripped,
   `RAYMOL_MAS_RESTRICTED` added to the macOS compilation conditions. TestFlight
   for Mac only accepts sandboxed App Store builds, and Xcode Cloud's own
   `xcodebuild archive` takes no extra flags, so the flag that
   `archive_appstore.sh` passes on its command line has to live in the
   generated project instead. Both paths now call the same script;
6. `xcodegen generate`, then `CLEAN=1 swiftui/build_macos.sh`;
7. `scripts/assert_macos_build_inputs.sh`: arm64 core, embedded Python +
   numpy + Bio, Homebrew libraries, and a generated project with no Sparkle
   package and with `RAYMOL_MAS_RESTRICTED`.

**Signing.** Xcode Cloud archives ad hoc (`CODE_SIGN_IDENTITY=-`) and re-signs
for distribution at export. On macOS an ad-hoc archive refuses entitlements
that need a provisioning profile ("has entitlements that require signing with a
development certificate"). The shared `RayMol.entitlements` carried one,
`keychain-access-groups`, which nothing in the app uses, so the macOS slice now
signs with `RayMolMac.entitlements`: sandbox, network client and user-selected
files only. Export re-signs the app and every embedded Python Mach-O as Apple
Distribution. A local rehearsal reproduced all of this — the same hook, Xcode
Cloud's exact archive flags, an App Store export, then
`altool --validate-app` → `VERIFY SUCCEEDED`.

**Package resolution.** Dropping Sparkle changes the package graph from the
one the committed `Package.resolved` describes. Xcode Cloud resolves strictly.
`xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution
-onlyUsePackageVersionsFromResolvedFile` was verified against exactly this
edit: the unused Sparkle pin is ignored, and every other package keeps its pin.

**Build numbers — the one rule iOS does not have.** A Mac app's build number
must increase across *all* versions, not just within one. Apple's "Setting the
next build number for Xcode Cloud builds" says so outright. Xcode Cloud also
stamps its own `CI_BUILD_NUMBER` into every build it distributes: the export
options it logs carry `"buildNumber"`. Once a macOS beta ships as, say,
`1.12.1 (190)`, the next Mac App Store **release** must be numbered above 190,
not `CURRENT_PROJECT_VERSION + 1`. The `cut-mas-release` and `cut-macos-release`
skills therefore take the release build number from the highest macOS build on
App Store Connect. The DMG shares `CURRENT_PROJECT_VERSION`; Sparkle only
needs it to increase, so the jump is harmless there.

**Creating the workflow** (only after this lands on `master`, because the
workflow builds `master`'s `ci_post_clone.sh`):

```bash
python3 scripts/asc_xcode_cloud_workflow.py --platform macos            # dry run
python3 scripts/asc_xcode_cloud_workflow.py --platform macos --write
```

Then do the same three UI steps as for iOS: files/folders rule, the TestFlight
Internal Testing post-action to group `Beta`, and failure notifications. Lock it
last. The script refuses to create a second workflow with the same name.

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
| Files/folders condition | **Exclude** `docs/**` and `*.md` — **UI step only** (see note below) |
| Auto-cancel Builds | **On** |
| Environment | Xcode latest release, macOS latest |
| Action | **Archive**, scheme `PyMOLViewer_iOS`, platform iOS |
| Build distribution audience | `INTERNAL_ONLY` — **permanent per build**, see note below |
| Restrict Editing | **On** (`isLockedForEditing: true`; Apple requires it for review-eligible builds — see ordering note below) |
| Post-action | TestFlight **internal** testing → group `Beta` |
| Post-action | Email and/or Slack notification on failure |

`scripts/asc_xcode_cloud_workflow.py` can create most of these settings via the
API. Run it with `--dry-run` first to inspect the payload.

**Build distribution audience — `INTERNAL_ONLY`, and it is irreversible:**
The Archive action sets `buildDistributionAudience: INTERNAL_ONLY`, which marks
every build this pipeline produces as internal-only. That marking is permanent
for a build once archived: an `INTERNAL_ONLY` build can **never** be promoted to
external TestFlight testing, and can never be submitted to the App Store. It is
restricted to internal tester groups forever.

The escape is a PATCH plus a rebuild, and it does not rescue existing builds:
PATCH the workflow's `buildDistributionAudience` to `APP_STORE_ELIGIBLE`, then
produce a **new** build. Every build archived before that change stays
ineligible permanently.

This is a deliberate choice rather than an oversight — the real iOS App Store
submission path is `swiftui/archive_appstore.sh`, entirely separate from this
pipeline, so nothing here ever needs to be App Store eligible.

Two further limits on what the audience value actually does:

- `INTERNAL_ONLY` does **not** by itself attach a build to a TestFlight group.
  Attaching it to group `Beta` is the post-action's job — the UI step in the
  table above, which the ASC API cannot express.
- Whether that post-action then genuinely auto-distributes to the group is
  **unverified**. Apple's own documentation contradicts itself: one page states
  that Xcode Cloud builds must be added to groups manually, another describes an
  automatic internal-testing post-action. This is a known open risk in the
  design, not a settled fact. Confirm on the first real build that testers were
  actually notified; if they were not, add the build to the group by hand.

**Required ordering — the lock must come last:**
A locked workflow (`isLockedForEditing: true`) is **read-only in the UI** — the
edit affordance is disabled. Three settings cannot be configured via the API and
must be added in the UI before locking:
- TestFlight Internal Testing post-action (group `Beta`)
- Failure notifications (email and/or Slack)
- **Files/folders exclusion rule** (see note below)

The correct sequence is:

1. `python3 scripts/asc_xcode_cloud_workflow.py --write` — creates the workflow
   **unlocked** so the UI is editable.
2. In App Store Connect → Xcode Cloud → *iOS Beta (master)* → **Edit**:
   - Add the files/folders rule: exclude `docs/**` and `*.md` (see note below).
   - Add the TestFlight Internal Testing post-action (group `Beta`).
   - Add a failure notification (email and/or Slack).
3. `python3 scripts/asc_xcode_cloud_workflow.py --lock --update-id <ID> --write`
   — patches `isLockedForEditing` to `true` for review eligibility. Do this
   **after** step 2; a locked workflow cannot be edited.

**Files/folders rule — UI step and read-back procedure:**
The script sets `filesAndFoldersRule: null` at creation because Apple's
`CiFilePatternMatcher` field names are undocumented and our initial guess
(`pattern`, `matchType`, `inverse`) was rejected by the API with "unknown
property" errors. After completing step 2 above:

1. Read the real shape back from the API:
   ```
   GET https://api.appstoreconnect.apple.com/v1/ciWorkflows/<id>
   ```
   and inspect `data.attributes.branchStartCondition.filesAndFoldersRule`.
2. Encode those exact field names into `scripts/asc_xcode_cloud_workflow.py`
   and commit, so future re-creations set the rule via the API.

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

**External testers are not available on this pipeline.** Its builds are archived
`INTERNAL_ONLY`, so they can never be promoted to external testing — internal
groups are the only possible audience. See *Build distribution audience* above
for the PATCH-plus-rebuild escape.

Builds remain installable for **90 days**, and up to **100 builds** can be
active at once. At a few builds per week this stays well inside both limits.
If it approaches them, expire the oldest builds in App Store Connect.

## Versions and build numbers

- **Marketing version** is the next **patch** after `swiftui/project.yml`'s
  `MARKETING_VERSION`, from `scripts/nightly_version.sh` (`1.9.1` → betas are
  `1.9.2`). It is **stable across betas** — every beta rides `1.9.2` until a
  release claims it; only the build number moves.
- **Build number** is Xcode Cloud's `CI_BUILD_NUMBER`.
- **Tester-visible label** is `scripts/beta_label.sh`'s `1.9.2-beta29`, written
  to the `RayMolBetaLabel` Info.plist key and shown in the app's Settings pane.
- App Store Connect requires the `(version, build)` pair to be unique. iOS does
  not require build numbers to increase across versions; only macOS does.

### Why betas cannot ride the current version

A beta **must** sit on a version that has never been approved. Once a version
ships, App Store Connect closes its pre-release train permanently. On
2026-08-10, with iOS `1.9.1` live (`READY_FOR_SALE`), an upload under `1.9.1`
was rejected with:

```
ITMS-90186: Invalid Pre-Release Train — the train version '1.9.1' is closed
            for new build submissions
ITMS-90062: CFBundleShortVersionString [1.9.1] must contain a higher version
            than the previously approved version [1.9.1]
```

So "don't bump, claim nothing" is not the conservative option — it is a rejected
upload. The **next patch** is the smallest claim Apple permits: one version
ahead, and the one most likely to ship next anyway, so in the usual case nothing
is stranded. (An earlier scheme bumped the next *minor* and did strand a
TestFlight `1.10.0` above a live `1.8.0` for a release nobody had planned.)

### Why the label is not the version

`CFBundleShortVersionString` must be one to three period-separated integers, so
`1.9.2-beta29` is rejected at upload. Apple only ever sees `1.9.2 (29)`. The
readable label carries the same identity through the one channel we control —
the Info.plist key — and is display text, never something Apple validates or
sorts on.

**Convention when cutting a release:** bump `MARKETING_VERSION` in
`swiftui/project.yml` **to** the released version — never in advance. This
script reads that field as "the last version that shipped", so the beta train
advances by itself the moment a release lands. Pre-bumping makes betas skip a
version.

`scripts/tests/run_nightly_version_test.sh`'s real-repo check derives its
expectation from `project.yml` with an independent `sed` plus independent
arithmetic — never by calling the script — so it stays non-circular and stays
correct across every future release bump.

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
| A build cannot be promoted to external testing or submitted to the App Store | It was archived `INTERNAL_ONLY` — permanent for that build. PATCH the workflow to `APP_STORE_ELIGIBLE` and produce a NEW build; this one stays ineligible. For an actual App Store submission use `swiftui/archive_appstore.sh` instead. |
| macOS: `ERROR: ... libomp.a missing` | `brew install` did not include `libomp`, or its keg layout moved. The app links `$(PYMOL_EXTERNAL_PREFIX)/opt/libomp/lib/libomp.a` by path. |
| macOS: `numpy X != Y` / `Bio X != Y` from `setup_macos_deps.sh` | A pin and the downloaded wheel disagree. Bump `NUMPY_VERSION` / `BIO_VERSION` deliberately in the script. |
| macOS: `NOT MAS: ... Sparkle` from `assert_macos_build_inputs.sh` | `apply_mas_restrictions.sh` did not run before `xcodegen`, or a Sparkle entry was added outside the `RAYMOL_SPARKLE_BEGIN/END` markers. |
| macOS: upload rejected with error 90296 (App Sandbox) | Same cause as above: a Sparkle helper reached the archive. |
| macOS: a Mac App Store release upload says its build number must be higher | A macOS beta already used a higher number. Number the release above the highest macOS build on App Store Connect (see *Build numbers* in the macOS section). |
| `ERROR: unsupported CI_PRODUCT_PLATFORM` / `disagrees with CI_XCODE_SCHEME` | `scripts/ci_platform.sh` only knows the two RayMol schemes. A new workflow needs an entry there first. |
| A build appears in TestFlight but testers were not notified | The `INTERNAL_ONLY` audience does not attach a build to a group; only the UI post-action does, and its auto-distribution is unverified. Add the build to group `Beta` manually in App Store Connect. |

## Local checks

Run every suite before pushing (CI globs the same directory, so a new suite
needs no workflow edit):

```bash
for t in scripts/tests/run_*_test.sh; do bash "$t" || echo "FAILED: $t"; done
```

The macOS-specific suites are `run_ci_platform_test.sh`,
`run_apply_mas_restrictions_test.sh` and `run_assert_macos_build_inputs_test.sh`.
