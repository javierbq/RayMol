# Self-hosted beta runner (puma)

`.github/workflows/beta-selfhosted.yml` builds the iOS + macOS TestFlight betas
on the Mac mini **puma** (`ssh puma`). It runs nightly at 08:00 UTC when the repo
variable `SELFHOSTED_BETA_ENABLED` is `true`, and also on manual dispatch.
Design: `docs/superpowers/specs/2026-10-14-selfhosted-beta-pipeline-design.md`.

## One-time setup on puma

1. **Xcode components** (no sudo):
   ```bash
   xcodebuild -runFirstLaunch
   xcodebuild -downloadPlatform iOS          # puma was set up for macOS only
   xcodebuild -downloadComponent MetalToolchain
   ```
2. **Runner.** Mint a registration token. It is valid for 1 h and needs repo
   admin, so mint it from the MacBook:
   ```bash
   gh api -X POST repos/javierbq/RayMol/actions/runners/registration-token --jq .token
   ```
   Then on puma:
   ```bash
   mkdir -p ~/actions-runner && cd ~/actions-runner
   V="$(gh api repos/actions/runner/releases/latest --jq .tag_name | sed 's/^v//')"
   curl -fsSLO "https://github.com/actions/runner/releases/download/v$V/actions-runner-osx-arm64-$V.tar.gz"
   tar xzf "actions-runner-osx-arm64-$V.tar.gz"
   ./config.sh --url https://github.com/javierbq/RayMol --token <TOKEN> \
     --name puma --labels puma --unattended --replace
   ./env.sh                       # captures PATH; must include /opt/homebrew/bin
   grep -q /opt/homebrew/bin .path || echo "FIX: run ./env.sh from a shell where brew is on PATH"
   ./svc.sh install && ./svc.sh start && ./svc.sh status
   ```
   `svc.sh` installs a per-user LaunchAgent. It runs in javier's login session,
   including while the console is locked, which is the normal state of puma.
3. **Credentials.** Run from the MacBook. Use tar, not `scp -r`:
   ```bash
   tar -C ~ -czf - .appstoreconnect | ssh puma 'tar -C ~ -xzf - && chmod 700 ~/.appstoreconnect ~/.appstoreconnect/private_keys && chmod 600 ~/.appstoreconnect/raymol_telemetry.env ~/.appstoreconnect/private_keys/*'
   ```
4. **Verify** the runner is online:
   ```bash
   gh api repos/javierbq/RayMol/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
   ```
   Expect `puma`, `online`, labels `self-hosted`, `macOS`, `ARM64`, `puma`.

## Running it

| What | Command |
|---|---|
| Dry run (archive + `altool --validate-app`, no upload) | `gh workflow run beta-selfhosted.yml -R javierbq/RayMol --ref master -f validate_only=true` |
| Real beta now | `gh workflow run beta-selfhosted.yml -R javierbq/RayMol --ref master -f validate_only=false` |
| Watch | `gh run watch -R javierbq/RayMol $(gh run list -R javierbq/RayMol --workflow beta-selfhosted.yml --limit 1 --json databaseId --jq '.[0].databaseId')` |
| Turn the nightly on / off | `gh variable set SELFHOSTED_BETA_ENABLED -R javierbq/RayMol --body true` / `--body false` |
| Xcode Cloud Beta workflows | `~/.raymol-beta-venv/bin/python scripts/xcode_cloud_beta_workflows.py status\|disable\|enable` |
| Next build number | `~/.raymol-beta-venv/bin/python scripts/asc_next_build_number.py` |

The `Keep logs` step uploads the full `archive.log`, `export.log` and
`altool.log` of each leg as a run artifact, kept for 14 days.

## Behaviour worth knowing

- **One shared build number**, max in ASC + 1, for both legs of a run. iOS and
  macOS from the same night carry the same number, as they did on Xcode Cloud.
- **The nightly skips an already-built commit.** If the last successful
  scheduled run built master's current SHA, it does nothing. A manual dispatch
  always builds.
- **Master only.** A dispatch from any other ref fails in `plan` before
  anything is built.
- **Side effects on puma:** `ci_post_clone.sh` runs `brew install` on a fixed
  set of packages and turns off Xcode's plugin/macro fingerprint validation
  through `defaults`. That setting also affects interactive Xcode use on puma.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Job stuck "Waiting for a runner" | `ssh puma '~/actions-runner/svc.sh status'`; logs in `~/actions-runner/_diag/`. Jobs that wait more than 24 h are dropped, and the next nightly picks up. |
| `brew: command not found` / `xcodegen: command not found` in Stage | Runner `.path` lacks Homebrew: `cd ~/actions-runner && ./env.sh && ./svc.sh stop && ./svc.sh start` |
| Export fails with `No profiles` / `Cloud signing permission error` | The ASC key needs the Admin role (cloud-managed distribution certificates). Check in App Store Connect → Users and Access → Integrations. |
| `altool` prints `ERROR ITMS-90062`/`-90189` (duplicate or lower build) | Another system uploaded a higher number in the meantime, for example Xcode Cloud re-enabled after a quota reset. Run `xcode_cloud_beta_workflows.py status`, then re-dispatch. |
| `no published deps artifact for fingerprint …` (iOS) | Run the "iOS deps artifact" workflow on master, then re-dispatch. Same rule as on Xcode Cloud. |
| Disk filling up | `~/Library/Developer/Xcode/DerivedData` and `~/Library/Developer/Xcode/Archives` on puma; safe to delete. |
