---
name: cut-mas-release
description: Use when submitting, pushing, or publishing a RayMol build to the **Mac App Store** — the sandboxed Apple-Distribution / App Store Connect flow (NOT the Sparkle notarized-DMG flow, which is `cut-macos-release`). Covers building the MAS archive (`archive_appstore.sh`, `RAYMOL_MAS_RESTRICTED` compiles out Sparkle + MCP), signing as Apple Distribution, uploading the build with `altool` + an ASC API key, and creating + submitting the App Store version in App Store Connect. Trigger whenever the user says "push to the App Store", "submit to the Mac App Store", "MAS release", "send it to App Review", "ship it on the App Store", "new App Store version", or asks to get a version onto the Mac App Store — even if they don't name a version or the steps. This is the Mac App Store channel; it does NOT mean the Sparkle/DMG release (use `cut-macos-release` for that) or the iOS App Store archive.
---

# Cut a Mac App Store (MAS) RayMol release

This drives the **Mac App Store** submission for RayMol: build a sandboxed, Apple-Distribution-signed archive, upload it to App Store Connect (ASC), and create + submit the App Store version for review. This is a **separate build and channel** from the Sparkle/notarized-DMG release (that's the `cut-macos-release` skill). Most releases ship on **both** channels at the same version — but the bits, the signing, and the distribution are different, so treat them independently.

The rhythm is **build → upload → submit**. The build + upload are things you can do autonomously; the ASC submission needs the user (they sign in — you never enter Apple ID credentials) and **Submit for Review is irreversible and outward-facing**, so the human clicks it.

App identity: **App ID `6781513038`**, team **`VT99UQUQ89`**, bundle **`io.raymol.RayMol`**. The live app is at `apps.apple.com/us/app/raymol/id6781513038?mt=12`.

## Non-negotiables (read first — each cost real time to learn)

1. **The MAS build is NOT the DMG build.** `archive_appstore.sh macOS` produces a build that is **sandboxed**, has **Sparkle removed** (MAS forbids self-update; Sparkle's helpers also fail sandbox validation with error 90296), has the **MCP server compiled out**, and has the **Tcl/Tk stack pruned** (it references a private API → guideline 2.5.1 rejection). All of this is driven by `SWIFT_ACTIVE_COMPILATION_CONDITIONS=... RAYMOL_MAS_RESTRICTED` plus a transient Sparkle-strip of `project.yml`. Never hand the Developer-ID/DMG app to the App Store, and never disable the strip.
2. **Build from the release TAG, not master.** "Not bleeding edge" — the MAS build should be the exact commit that shipped (or is shipping) on the other channels. Build in a worktree synced to the tag (see Step 2).
3. **Clean the C++ core first.** `archive_appstore.sh` only does an *incremental* core build, which can silently ship a stale setting default (see [[raymol_release_build_staleness]] in memory; a stale core once shipped `metal_outline` on). Run `CLEAN=1 bash swiftui/build_macos.sh` before archiving — unless you *just* clean-built the core for this exact tag (e.g. `make_dmg.sh` already did).
4. **Sign as Apple Distribution, and verify the EXPORTED app — not the xcarchive.** The intermediate archive can read as "Apple Development"; only the exported `.pkg`'s app must be `Apple Distribution: … (VT99UQUQ89)`. Verify after export, before uploading (Step 3).
5. **The build number must be unique and strictly higher than the last build on ASC.** ASC rejects a duplicate/lower `CFBundleVersion`. Read the last uploaded build from the ASC API (Step 1) — don't trust a hand-typed number.
6. **Only one version can be in App Review at a time.** Before creating a new version record, check ASC state: if a prior version is still `WAITING_FOR_REVIEW` / `IN_REVIEW` / `PENDING_DEVELOPER_RELEASE`, resolve it first (release it, or it blocks the new one).
7. **Never enter Apple ID credentials; the human signs into ASC. Submit for Review is theirs.** Drive the ASC web UI (create version, attach build, What's New, release option) but stop at **Submit for Review** — that's the irreversible, outward-facing step. The human signs in and clicks Submit.
8. **MAS "What's New" ≠ the DMG release notes.** Drop **Homebrew** (App Store users don't install that way, and pointing to another distribution channel in App Store metadata is discouraged) and drop **MCP / AI copilot** (compiled out of the sandboxed build). Keep the genuinely user-visible app features/fixes.

See `references/gotchas.md` for the full failure-mode catalog (the four original rejection items, the 90296 sandbox error, the headless-upload recipe, the ASC-API status quirk) and recovery recipes. Read it if any step misbehaves.

## Where things live

- **Build/export script:** `swiftui/archive_appstore.sh macOS` — strips Sparkle from a transient copy of `project.yml` (between the `# RAYMOL_SPARKLE_BEGIN/END` markers), regenerates, builds the core, then `xcodebuild archive` + `-exportArchive` with automatic Distribution signing. Output: `swiftui/build_export/macOS/RayMol.pkg`.
- **MAS build config:** `swiftui/project.yml` — the `# RAYMOL_SPARKLE_BEGIN/END` markers, the Tcl/Tk prune + `itms-services` strip in the "Bundle Python" phases, and the `RAYMOL_MAS_RESTRICTED`-gated `rm -rf .../raymol_mcp`.
- **Version:** `swiftui/project.yml` — `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` (shared with the Sparkle build; the tag already carries the right values).
- **ASC API key:** `~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8`. Set the **Key ID** and **Issuer** via env `ASC_KEY_ID` / `ASC_ISSUER` — find them in ASC ▸ Users and Access ▸ Integrations ▸ App Store Connect API (account identifiers, deliberately kept out of this public repo). The `.p8` private key never leaves disk; `altool` reads it from the path above by Key ID.
- **ASC status check:** `scripts/asc_status.py` (bundled) — signs an ES256 JWT with the key and prints the App Store version states + recent builds. Use it in Step 1 and to verify after submit.

## Preflight (fail fast — check before the long build)

```bash
ls ~/.appstoreconnect/private_keys/     # the AuthKey_<KeyID>.p8 upload key is present
: "${ASC_KEY_ID:?export ASC_KEY_ID}" "${ASC_ISSUER:?export ASC_ISSUER}"  # from ASC ▸ Integrations
xcodebuild -version                     # Xcode present
```
- **Xcode must be signed into the Apple Developer account** (Xcode ▸ Settings ▸ Accounts; an Apple ID that is Admin/App Manager on team `VT99UQUQ89`) so automatic Distribution signing can mint the profile. GOTCHA: `security find-identity -v` showing **no** "Apple Distribution" / "3rd Party Mac Developer" cert is **NORMAL** — Xcode 26 uses cloud-managed signing (fetches the cert per build, doesn't persist a keychain identity). Don't diagnose "missing cert" as a blocker; the archive's `-allowProvisioningUpdates` handles it. If the account isn't signed in, the archive fails at export — that's the signal to sign in.

## Step 1 — Decide the version/build and check ASC state

The MAS version normally **matches the current Sparkle/DMG release** (same tag → same `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). Confirm the intended version with the user, then read the live ASC state:

```bash
python3 <skill>/scripts/asc_status.py     # versions + recent builds (needs PyJWT; see the script)
```
- Confirm **no version is currently in review** (non-negotiable #6). The newest `READY_FOR_SALE` is the last public version — the "What's New" covers changes since it.
- Confirm the build you're about to ship is **> the last uploaded build**. (Builds that were only shipped on the Sparkle channel never reached ASC, so the last ASC build may be several behind the tag.)
- Recommend version + build to the user and confirm before the long build.

## Step 2 — Build the MAS archive from the tag

Build in a worktree synced to the release tag (non-negotiable #2). If you just ran `cut-macos-release` for this version, its worktree is already at the tag with a clean core — reuse it and skip the clean core rebuild. Otherwise:

```bash
git worktree add -b mas/vX.Y.Z ../raymol-mas-X.Y.Z vX.Y.Z
cd ../raymol-mas-X.Y.Z
MAIN_REPO=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
[ -e deps_macos ] || ln -s "$MAIN_REPO/deps_macos" deps_macos      # worktrees don't get git-ignored deps
CLEAN=1 bash swiftui/build_macos.sh                                # clean core (non-negotiable #3)
cd swiftui && ./archive_appstore.sh macOS                          # → build_export/macOS/RayMol.pkg (~15-25 min)
```
`archive_appstore.sh` backs up `project.yml`, strips Sparkle between the markers, `xcodegen generate`s, restores `project.yml`, builds, archives, and exports. It aborts if the Sparkle-strip markers are missing. Output: `swiftui/build_export/macOS/RayMol.pkg`.

## Step 3 — Verify the exported .pkg BEFORE uploading

```bash
PKG=swiftui/build_export/macOS/RayMol.pkg
TMP=$(mktemp -d); pkgutil --expand-full "$PKG" "$TMP/exp" >/dev/null
APP=$(find "$TMP/exp" -name RayMol.app -type d | head -1)
plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist"   # = X.Y.Z
plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist"              # = the build, > last ASC build
codesign -dvv "$APP" 2>&1 | grep Authority   # Authority=Apple Distribution: … (VT99UQUQ89)
codesign --verify --deep --strict "$APP" && echo "verify OK"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q app-sandbox && echo "sandbox OK"
ls "$APP/Contents/Frameworks" | grep -i sparkle && echo "!! SPARKLE PRESENT (bug)" || echo "Sparkle stripped OK"
test -d "$APP/Contents/Resources/modules/raymol_mcp" && echo "!! MCP PRESENT (bug)" || echo "MCP stripped OK"
rm -rf "$TMP"
```
Require: version = intended; **Apple Distribution** authority; deep-strict verify passes; **app-sandbox** present; **Sparkle + `raymol_mcp` absent**. Any failure → STOP (see gotchas). If the version is wrong you built the wrong checkout.

## Step 4 — Validate + upload the build

```bash
KEY="$ASC_KEY_ID"; ISS="$ASC_ISSUER"   # export first (ASC ▸ Integrations); not stored in this repo
xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$KEY" --apiIssuer "$ISS"   # VERIFY SUCCEEDED
xcrun altool --upload-app   -f "$PKG" -t macos --apiKey "$KEY" --apiIssuer "$ISS"   # UPLOAD SUCCEEDED
```
Uploading only makes the build **available** in ASC — it does NOT submit or publish. After upload, the build takes **a few minutes to appear + process** to `VALID` before it can be attached. Poll with `scripts/asc_status.py` until the build shows `VALID`.

## Step 5 — Create + submit the version in App Store Connect (human signs in)

The user chose "you drive, I sign in" or "you hand me a checklist." Either way, **you never enter Apple ID credentials** and the human clicks the final **Submit for Review**. Driving via the browser (real Chrome carries the user's ASC session):

1. Open `https://appstoreconnect.apple.com/apps/6781513038/distribution`. If it shows the login screen, **ask the user to sign in** (Apple ID + 2FA/passkey) — do not touch the fields. Wait for them to confirm.
2. Click the **`+`** next to "macOS App" → **New Version** → type `X.Y.Z` → Create.
3. In **What's New in This Version**, paste the MAS notes (non-negotiable #8 — no Homebrew, no MCP). Save.
4. **Build** section → **Add Build** → select `X.Y.Z (build)` → Done → Save. (The build must be `VALID` from Step 4.)
5. **App Store Version Release** → **Manually release this version** (so approval doesn't auto-go-live; the user releases when ready). This usually carries over from the last version.
6. Click **Add for Review** → a **Draft Submission** panel appears with the version "Ready to Submit". Export compliance usually does NOT prompt (the Info.plist declares `ITSAppUsesNonExemptEncryption` — RayMol is exempt, HTTPS only). Metadata (screenshots, description, keywords, URLs, age rating) carries over from the previous version.
7. **Hand off the final click:** the blue **Submit for Review** button is the human's. Do not click it.

## Step 6 — Verify + after approval

- After the user submits, confirm state with `scripts/asc_status.py` → the version should read `WAITING_FOR_REVIEW` (~24–48h; Apple emails on completion). Note: the API's version→build relationship can read "(no build attached)" even when one is; trust the UI for attachment, the API for state.
- Because **Manually release** was chosen, after approval the version sits at `PENDING_DEVELOPER_RELEASE` — the user clicks **Release This Version** in ASC to go live. Remind them.

## Done

Report: the version/build submitted, that the exported build was Apple-Distribution-signed + sandboxed with Sparkle/MCP stripped, that the build is `VALID` and attached, the current ASC state (`WAITING_FOR_REVIEW`), and that manual release is pending after approval.
