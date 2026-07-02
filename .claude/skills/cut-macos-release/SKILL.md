---
name: cut-macos-release
description: Use when cutting, preparing, or publishing a new macOS RayMol release — the Sparkle auto-update / notarized-DMG flow. Covers deciding the version bump from what's on master, building and notarizing the DMG, and publishing the appcast + GitHub release. Trigger whenever the user says "prepare a release", "cut a release", "new release", "release", "release it", "ship it" / "ship the app", "bump the version", or asks to review master for a possible release — even if they don't name a version number or list the steps. This means shipping a macOS build to users; it does NOT mean merging an unrelated PR or shipping other code. macOS/Sparkle only — the iOS/Mac App Store archive is a separate flow this skill does not cover.
---

# Cut a macOS RayMol release

This drives the **macOS / Sparkle** release for RayMol (the SwiftUI+Metal app): decide the version, bump it, build a notarized Developer-ID DMG, and publish the `appcast.xml` + GitHub release that installed apps poll for auto-update. The iOS / Mac App Store archive (`archive_appstore.sh`) is a **separate flow not covered here**.

The default rhythm is **prep → test → publish**: stage everything and build a release-candidate for the user to test *before* anything ships. Publishing pushes an update to every installed app via Sparkle — treat it as outward-facing and irreversible, and never publish without the user's explicit go-ahead after they've seen a build.

## Non-negotiables (read first — each cost real time to learn)

1. **Never `git push` directly to `master`.** The repo convention (CLAUDE.md) forbids it and the harness is expected to block it. The bump, release notes, and appcast commit ALL go through a PR (`gh pr create` → `gh pr merge --merge`). **Tag** pushes (`git push origin vX.Y.Z`) are fine — only default-**branch** pushes are gated. "Release" from the user does NOT authorize a direct push.
2. **Build from the exact tagged commit.** The scripts resolve their root from the script's own location, so building from the wrong directory or an un-synced worktree silently ships the wrong bits. After the PR merges, re-sync the worktree to `origin/master` and assert its `HEAD` equals the release tag's commit before building (Step 5).
3. **Rebuild the C++ core, then the app (two stages).** `xcodebuild`/`make_dmg.sh` only *link* a prebuilt `libpymol_core.a`; they never rebuild it. If any C++/Metal file changed since the last core build, run `swiftui/build_macos.sh` first — and verify the `.a` is actually fresh — or you ship a binary missing those changes with no error (this shipped a broken v1.3.0).
4. **The build number must strictly increase past the last PUBLISHED build.** Sparkle compares updates on `CURRENT_PROJECT_VERSION`. Don't trust a hand-typed number: read it from the built app and compare against the live appcast's last `sparkle:version` (Step 6). A non-increasing build publishes cleanly but is silently never offered.
5. **Verify before you publish, verify the live feed after.** Confirm the app inside the DMG is the intended version, notarized, stapled, and carries the Sparkle key — then, post-publish, confirm `/latest/download/appcast.xml` serves the new version.

See `references/gotchas.md` for the full failure-mode catalog and recovery recipes. Read it if any step misbehaves.

## Where things live

- **Version:** `swiftui/project.yml` — `MARKETING_VERSION` (e.g. `1.5.1`) and `CURRENT_PROJECT_VERSION` (integer build). This is the xcodegen source of truth; `project.pbxproj` is regenerated from it and carries the same version strings across its build configs.
- **Release notes:** `docs/release-notes/vX.Y.Z.md` — Markdown, spliced into the appcast and used as the GitHub release body. See `references/release-notes-style.md`.
- **Scripts** (`swiftui/`): `build_macos.sh` (rebuild core `.a`, no env vars), `make_dmg.sh` (Release build → Developer-ID sign → notarize → DMG), `publish_release.sh` (EdDSA-sign → write `appcast.xml` → GitHub release).
- **Live auto-update feed:** the release **asset** at `https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml` (NOT the tracked repo copy — that's optional bookkeeping that drifts).

Version numbers below (`X.Y.Z`, build `N`) are placeholders — always read the live values, never assume the examples are current.

## Preflight (fail fast — check before the long build)

```bash
security find-identity -v -p codesigning | grep "Developer ID"     # signing identity present
xcrun notarytool history --keychain-profile RayMol-notary | head    # notary creds reachable
security show-keychain-info "$HOME/Library/Keychains/login.keychain-db"  # exits 0 when UNLOCKED
```
- The identity is `Developer ID Application: Javier Castellanos (VT99UQUQ89)`; the notary profile is `RayMol-notary`.
- The keychain check exits 0 (and prints key metadata) when unlocked; if it errors, unlock: `security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"`. A locked keychain hangs the sign step ~30 min into the build.
- `build_macos.sh` aborts immediately if `deps_macos/python-standalone/python` is missing — Step 2 sets up the symlink, but know this is the expected failure if it's absent.

## Step 1 — Review master and decide the version

```bash
git fetch origin --tags --quiet
LAST=$(git tag -l 'v*' --sort=-creatordate | head -1)     # latest release tag (any major)
echo "last tag: $LAST"
git log "$LAST"..origin/master --oneline --no-merges
git log "$LAST"..origin/master --no-merges --format='%s' | grep -oE '^[a-z]+' | sort | uniq -c | sort -rn
CUR_MARKETING=$(grep -E 'MARKETING_VERSION:' swiftui/project.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
CUR_BUILD=$(grep -E 'CURRENT_PROJECT_VERSION:' swiftui/project.yml | grep -oE '[0-9]+' | head -1)
echo "current: $CUR_MARKETING / build $CUR_BUILD"
```
- Sanity-check `$LAST` against `$CUR_MARKETING` — they should be the same release (or LAST one behind if a bump hasn't shipped).
- If the only commits past the tag are release bookkeeping (a bump + appcast commit), **there is nothing to release** — say so and stop; don't invent a release.
- Choose the bump from the commit mix (standard semver): any real `feat`s → **minor** (`1.5.1` → `1.6.0`); only `fix`/`perf`/`docs`/`build` → **patch** (`1.5.1` → `1.5.2`). New build `N = CUR_BUILD + 1`.
- The release is **macOS-facing**: fixes/features that only touch the iOS path (App Store) should NOT headline the macOS notes. Recommend the version + build to the user and confirm before proceeding.

## Step 2 — Create a release worktree, bump, and build a release-candidate

Isolate the release in a worktree off the tip you're releasing, and remember its path:
```bash
git worktree add -b release/X.Y.Z ../raymol-release-X.Y.Z origin/master
cd ../raymol-release-X.Y.Z
WT=$(pwd)                                  # reused in later steps
```
A worktree doesn't get git-ignored deps/build dirs, so wire them up (target the real main-repo path on this machine):
```bash
[ -e deps_macos ] || ln -s /Users/jcastellanos/repos/RayMol/deps_macos deps_macos
test -e deps_macos/python-standalone/python/include/python3.13/Python.h && echo "deps OK"
```

Bump the version and write notes:
- Edit `swiftui/project.yml`: set `MARKETING_VERSION` to `X.Y.Z` and `CURRENT_PROJECT_VERSION` to `N`.
- Write `docs/release-notes/vX.Y.Z.md` (see `references/release-notes-style.md`).

Build the RC and open it (two-stage — non-negotiable #3). Prefer delegating to the `multiplatform-build-deployer` agent, instructing it to build **from `$WT`, not the main repo**:
```bash
bash swiftui/build_macos.sh                             # rebuild core from THIS checkout
( cd swiftui && xcodegen generate )                     # regenerate pbxproj with the new version
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Debug -derivedDataPath swiftui/build_mac_dd CODE_SIGNING_ALLOWED=NO build
ps -eo pid,comm | awk '/build_mac_dd.*MacOS\/RayMol$/ {print $1}' | xargs -r kill   # relaunch fresh
open -n swiftui/build_mac_dd/Build/Products/Debug/RayMol.app
```
Confirm the launched app's `Info.plist` shows `X.Y.Z` / `N`, then **hand it to the user to test and wait for approval.** Note: the RC is a **Debug** build; the shipped DMG is **Release**. For an optimization/Metal-sensitive change, also smoke-test the actual notarized `build_dmg/RayMol.app` (Step 6) before publishing. Do not proceed until the user confirms.

## Step 3 — Land the bump via a PR (NOT a direct push)

```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj/project.pbxproj docs/release-notes/vX.Y.Z.md
# stage explicitly — never `git add -A`; build dirs (build_mac_dd/, build_dmg/, RayMol-*.dmg) are untracked
git commit -m "release: bump to X.Y.Z (build N)"
git push -u origin release/X.Y.Z
gh pr create -R javierbq/RayMol --base master --head release/X.Y.Z \
  --title "release: RayMol X.Y.Z (build N)" --body "..."
gh pr merge release/X.Y.Z -R javierbq/RayMol --merge --delete-branch=false
```
If the bug fixes for this release aren't already on master, put them in this same PR (or a prior one) — the tag must point at a commit that already contains them.

## Step 4 — Tag the merged master

```bash
git fetch origin --quiet
git tag -a vX.Y.Z -m "release: RayMol X.Y.Z (build N) — <one-line>" origin/master
git push origin vX.Y.Z          # tag pushes are allowed
```

## Step 5 — Re-sync, rebuild core, build the notarized DMG

Build **from the exact tagged commit** (non-negotiable #2). Re-sync the worktree and assert identity first:
```bash
git -C "$WT" fetch origin --quiet
git -C "$WT" reset --hard origin/master
[ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$WT" rev-parse vX.Y.Z^{commit})" ] \
  && echo "HEAD == tag ✓" || { echo "STOP: worktree HEAD != vX.Y.Z"; }
```
(The reset drops the local bump commit in favor of the merged version — same content — and re-drops the deps symlink only if it was tracked; it isn't, so it survives.)

Rebuild the core from the final checkout and **verify the `.a` is fresh** (non-negotiable #3):
```bash
bash "$WT/swiftui/build_macos.sh"
stat -f '%Sm' "$WT/build_macos_swiftui/libpymol_core.a"   # must be from THIS run, newer than the release commit
```
Then build the DMG (20–40 min — run in the background; absolute path so it can't build the wrong checkout):
```bash
DEVID="Developer ID Application: Javier Castellanos (VT99UQUQ89)" \
  VERSION=X.Y.Z NOTARY_PROFILE=RayMol-notary bash "$WT/swiftui/make_dmg.sh"
```
`make_dmg.sh` on master builds from any checkout (pinned `-derivedDataPath`) and packages mount-free (`hdiutil makehybrid`). Output: `$WT/RayMol-X.Y.Z.dmg`. It locates Sparkle's `generate_keys` inside resolved SPM DerivedData; if it errors "not found", the RC build in Step 2 should have resolved it — otherwise run `xcodebuild -resolvePackageDependencies`.

## Step 6 — Verify the DMG BEFORE publishing

```bash
APP="$WT/build_dmg/RayMol.app"
VER=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
N=$(/usr/bin/plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
KEY=$(/usr/bin/plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist")
LASTPUB=$(curl -sL https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml \
  | grep -oE '<sparkle:version>[0-9]+' | grep -oE '[0-9]+' | head -1)
echo "built: $VER / build $N ; sparkle key: ${KEY:+present} ; last published build: $LASTPUB"
xcrun stapler validate "$WT/RayMol-X.Y.Z.dmg"
```
Require: `VER` = `X.Y.Z`; `KEY` present; staple "worked"; and **`N` > `LASTPUB`** (strictly greater — non-negotiable #4). If `VER` is wrong you built the wrong checkout — STOP (see gotchas). Use the extracted `$N` as `BUILD=` below, not a hand-typed number.

## Step 7 — Publish

Gate on the tag existing at the right commit, then publish:
```bash
git ls-remote --tags origin vX.Y.Z      # must return the annotated tag; STOP if missing/wrong
cd "$WT"
VERSION=X.Y.Z BUILD=$N NOTES_FILE=docs/release-notes/vX.Y.Z.md bash swiftui/publish_release.sh
```
This EdDSA-signs the DMG, writes `appcast.xml`, and creates the `vX.Y.Z` GitHub release (DMG + stable `RayMol.dmg` + appcast). If the tag doesn't already exist, `gh release create` would lightweight-tag it at the default-branch tip — the gate above prevents a stray tag. (`publish_release.sh` finds Sparkle's `sign_update` in resolved SPM DerivedData; same `-resolvePackageDependencies` note as Step 5.)

## Step 8 — Verify live, then commit the appcast

```bash
gh release view vX.Y.Z -R javierbq/RayMol --json name,tagName,isDraft,assets \
  --jq '{name,tagName,isDraft,assets:[.assets[].name]}'
curl -sL https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml \
  | grep -E "sparkle:version|shortVersionString|enclosure url"
```
Confirm the feed serves `X.Y.Z` / build `N` with a matching signature. Then land the tracked `appcast.xml` via a **second small PR** (direct push is gated), based on `origin/master` so it fast-forwards:
```bash
cd "$WT"
cp appcast.xml /tmp/appcast.gen.xml
grep -q "shortVersionString>X.Y.Z" /tmp/appcast.gen.xml || echo "WARN: generated appcast doesn't mention X.Y.Z"
git checkout -- appcast.xml
git fetch origin --quiet && git checkout -B chore/appcast-X.Y.Z origin/master
cp /tmp/appcast.gen.xml appcast.xml && git add appcast.xml
git commit -m "release: RayMol X.Y.Z appcast"
git push -u origin chore/appcast-X.Y.Z
gh pr create -R javierbq/RayMol --base master --head chore/appcast-X.Y.Z \
  --title "release: RayMol X.Y.Z appcast" --body "Bookkeeping."
gh pr merge chore/appcast-X.Y.Z -R javierbq/RayMol --merge
```
(The appcast repo commit is optional bookkeeping — the live feed is the release asset — but it keeps the tracked copy in sync with prior releases.)

## Done

Report: the release URL, that the DMG is notarized/stapled and stamped `X.Y.Z`/`N`, that the live feed serves it, and the PR links. Installed apps will offer the update on their next check.
