# Self-hosted beta pipeline (GitHub Actions on puma) — design

**Status:** approved in conversation 2026-10-14, awaiting spec review
**Replaces:** Xcode Cloud workflows `iOS Beta (master)` and `macOS Beta (master)`

## Why

The Xcode Cloud compute quota ran out on 2026-10-12. From run #364 onward every
beta run was cancelled 5–16 s after creation without starting, so the last beta
that reached TestFlight is build 360 (iOS) / 362 (macOS). Sixteen master commits
since then, including the whole lighting series #869–#877, have no beta.

We already own a Mac that builds RayMol every day (the Mac mini `puma`), so beta
builds move there. They run as GitHub Actions jobs on a self-hosted runner, and
Apple compute is no longer used.

## Decisions (made with the user)

| Question | Decision |
|---|---|
| Runner host | `puma` (M4 Mac mini, macOS 27, Xcode 27, always on, Tailscale) |
| Trigger | Nightly cron on master's tip, plus manual `workflow_dispatch` |
| Xcode Cloud | Disable both Beta workflows once the new pipeline has delivered a build. Self-hosted becomes the only beta pipeline. |
| Platforms | iOS and macOS, both in the first version |
| Structure | GitHub-Actions-native workflow that calls scripts in the repo (not a script that lives only on puma) |

## Success criteria

1. A manual dispatch with `validate_only=true` archives both platforms on puma
   and passes `altool --validate-app` without uploading anything.
2. A manual dispatch with `validate_only=false` uploads one iOS and one macOS
   build. Both reach `VALID` in TestFlight and appear to the internal **Beta**
   group with no manual step.
3. The nightly run does the same on its own. A night with no new commits on
   master produces no build.
4. Both Xcode Cloud Beta workflows are disabled, and the only beta builds that
   appear in TestFlight afterwards come from puma.

## Architecture

```
GitHub (schedule 08:00 UTC | workflow_dispatch)
  └─ job "plan"   (runs-on: [self-hosted, macOS, puma])
       • scheduled runs: no-op unless vars.SELFHOSTED_BETA_ENABLED == 'true'
       • resolves master's SHA
       • skips if the last successful scheduled run built that SHA (nightly only)
       • BUILD = max(build number of every ASC build for app 6781513038) + 1
  └─ job "beta"   (needs: plan; matrix: [iOS, macOS]; max-parallel: 1)
       1. checkout (default clean: wipes last run's edits and deps)
       2. bash swiftui/ci_scripts/ci_post_clone.sh  ← unchanged Xcode Cloud hook
            env: CI_PRIMARY_REPOSITORY_PATH=$GITHUB_WORKSPACE
                 CI_BUILD_NUMBER=$BUILD
                 CI_PRODUCT_PLATFORM=iOS|macOS
                 CI_XCODE_SCHEME=PyMOLViewer_iOS|PyMOLViewer_macOS
                 CI_XCODEBUILD_ACTION=archive
       3. bash scripts/selfhosted_beta.sh <platform> [--validate-only]   ← NEW
            xcodebuild archive  (ad hoc, same flags Xcode Cloud used)
            xcodebuild -exportArchive  (app-store-connect, ASC API key, cloud signing)
            xcrun altool --validate-app | --upload-app  (ASC API key)
       4. upload the .xcarchive logs and the export log as workflow artifacts
```

### Components

**`.github/workflows/beta-selfhosted.yml` (new)**
- `on: schedule: cron '0 8 * * *'` (08:00 UTC, 01:00 Pacific) and
  `workflow_dispatch` with input `validate_only` (bool, default `true`).
  A manual dispatch always builds.
- `concurrency: group: beta-selfhosted, cancel-in-progress: false`. One build
  at a time on one machine. A nightly run that starts while a manual run is
  still going waits for it.
- Runs only on `refs/heads/master`. A dispatch from any other ref fails in
  `plan`, because a self-hosted runner that signs and ships must never build
  untrusted code. PRs never trigger it.
- `timeout-minutes: 90` per matrix leg.

**`scripts/selfhosted_beta.sh <iOS|macOS> [--validate-only]` (new)**
This is the only new build logic. It covers what Xcode Cloud did after
`ci_post_clone.sh`:
- archives with `CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES` plus
  `-skipPackagePluginValidation -skipMacroValidation`, which matches the
  Xcode Cloud log;
- exports with `method=app-store-connect`, `signingStyle=automatic`,
  `uploadSymbols=false` (same reason as `archive_appstore.sh`) and
  `-allowProvisioningUpdates -authenticationKeyPath/-ID/-IssuerID`, so Apple
  cloud signing mints the Distribution identity and no private key has to sit
  in puma's keychain;
- then runs `altool --validate-app` or `--upload-app` with
  `--apiKey/--apiIssuer`;
- reads `ASC_KEY_ID` and `ASC_ISSUER` from `~/.appstoreconnect/raymol_telemetry.env`
  and the key from `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`, which
  are the same files the release skills use.

`archive_appstore.sh` stays as the release path and is not modified. It runs
xcodegen and the core build itself and uses account signing. Bending it to
handle beta builds as well would couple the two flows.

**`scripts/asc_next_build_number.py` (new)**
Signs an ES256 JWT, pages through `/v1/builds?filter[app]=6781513038`, and
prints `max(version) + 1`. Releases and betas on both platforms share one
counter. That keeps Apple's rule that Mac build numbers always increase, and
it matches what Xcode Cloud's `CI_BUILD_NUMBER` did, so an iOS and a macOS
build from the same night get the same number, as 202/203 did before. The
number is read from ASC on every run and never stored. Build numbers on
cancelled Xcode Cloud runs (up to 388) were never uploaded, so they cannot
collide with these.

**Skip-if-built (nightly only)**
`plan` runs `gh run list --workflow beta-selfhosted.yml --event schedule
--status success --limit 1 --json headSha`. If that SHA is master's current
tip, `plan` exits successfully and builds nothing. If a manual upload already
built the same SHA, the next nightly run builds it one more time. That costs
one extra build and keeps state out of ASC. Manual dispatches never skip.

**Enable switch**
Scheduled runs only proceed when the repo variable
`SELFHOSTED_BETA_ENABLED == 'true'` (`if:` on `plan`). Until that variable is
set, the merged workflow does nothing on its cron, so no jobs queue for a
runner that does not exist and expire into failure emails. Manual dispatches
ignore the variable.

### Runner on puma (one-time setup, documented in the plan)

- Install the Xcode iOS platform (`xcodebuild -downloadPlatform iOS`); puma
  was set up for macOS builds only.
- Install `actions-runner` in `~/actions-runner`, registered to
  `javierbq/RayMol` with the labels `self-hosted,macOS,puma`.
- Install it with `./svc.sh install` as a per-user LaunchAgent for `javier`.
  It runs in the logged-in session, so it starts when javier logs in and keeps
  running while the console is locked.
- The workspace persists between runs, so step 1 uses the default
  `actions/checkout` clean (`git clean -ffdx` + reset). That undoes the hook's
  in-place `sed` patches and also removes the dependency trees. Keeping them
  would save nothing, because `ci_post_clone.sh` re-downloads `deps_ios` every
  run regardless. Laying a new dependency tree over an old one is also the
  stale-artifact bug class the hook already guards against.
- Copy `~/.appstoreconnect/` from this MacBook to puma with mode 600. The user
  does this step because it involves credentials.

## Error handling

- Every step fails fast (`set -euo pipefail`). `ci_post_clone.sh` already
  checks each of its patches by reading the result back.
- `selfhosted_beta.sh` checks that the `.ipa`/`.pkg` exists and is non-empty
  before it uploads. If `altool` exits 0 but prints `ERROR ITMS-`, the script
  treats that as a failure.
- If one matrix leg fails, the other still runs (`fail-fast: false`), so a
  broken iOS slice does not hold up the Mac beta.
- When a scheduled workflow fails, GitHub sends its default email. No other
  notification channel is added in this version.
- If puma is offline, the job waits in the queue. GitHub drops jobs that wait
  for a self-hosted runner for more than 24 h, so the next night's run takes
  over.

## Side effects on puma (accepted)

`ci_post_clone.sh` changes the machine in two ways. It runs `brew install` on a
fixed set of packages, which is idempotent. It also writes two keys to
`defaults` that turn off Xcode's plugin and macro fingerprint validation for
every Xcode project on puma. That second change also affects interactive work
on puma. We accept it because `archive_appstore.sh` and the puma build notes
already pass the matching flags.

## Rollout

1. Merge the PR that adds the workflow and scripts. Nothing runs yet, because
   no runner exists.
2. User sets up the puma runner and copies the ASC key to it.
3. Dispatch with `validate_only=true` and fix problems until both legs are green.
4. Dispatch with `validate_only=false` and confirm both builds are `VALID` and
   visible to the Beta group.
5. Disable both Xcode Cloud Beta workflows through the ASC API
   (`PATCH /v1/ciWorkflows/{id}` with `isEnabled=false`). This is a production
   change, so the user runs the command.
6. Set the repo variable `SELFHOSTED_BETA_ENABLED=true` to turn on the
   nightly cron, then check the results after the first two nights.

## Testing

- `scripts/tests/run_selfhosted_beta_test.sh` is a new shell test and follows
  the existing `run_*_test.sh` pattern. It stubs `xcodebuild`/`altool` on
  `PATH` and checks the archive/export/upload arguments, the
  validate-only/upload switch, and the `ERROR ITMS-` detection. The existing
  `ios-pipeline-script-tests.yml` globs `run_*_test.sh`, so CI picks the test
  up with no YAML change.
- `asc_next_build_number.py` gets a unit test that uses a recorded, paginated
  `/v1/builds` response, so it runs offline.
- Rollout steps 3–4 are the end-to-end test.

## Non-goals

- **Xcode Cloud's iOS Test action** (`LightsUITests_iOS`): it stops along with
  the workflow. Moving UI tests to puma is a separate follow-up.
- External TestFlight groups and Beta App Review.
- Release builds. The `cut-*-release` skills and `archive_appstore.sh` do not
  change.
- Removing `ci_post_clone.sh`. It stays as the staging script for both systems,
  in case Xcode Cloud is ever re-enabled.
