# MAS release — failure modes & recovery

Hard-won specifics from RayMol's Mac App Store submissions (1.0 → 1.4.0 → 1.6.1 → 1.7.1). Read when a step misbehaves.

## The four original rejection items (all fixed in the build now — don't regress them)

RayMol's first submission (1.0 build 5) was rejected on four guidelines. The fixes are baked into `project.yml` / `archive_appstore.sh`, so every MAS build reproduces them. If a *new* rejection cites one of these, the mechanism below broke:

- **2.5.1 (private API):** the bundled Tcl/Tk `libtcl9tk9.0.dylib` referenced private `_NSWindowDidOrderOnScreenNotification`. Fix: the "Bundle Python" phase in `project.yml` prunes the whole Tcl/Tk stack from the embedded Python (the native Metal app never uses the legacy `pmg_tk` Tkinter GUI). If Tk creeps back, the prune glob missed it.
- **2.5.2 (itms-services):** false positive — the literal `itms-services` lives in CPython's stdlib `urllib/parse.py` (`uses_netloc`). Fix: the packaging phase `sed`s the token out. Not a real URL scheme use.
- **2.1(a) (launch crash on a clean machine):** the review machine has no Homebrew, so un-bundled Homebrew dylibs aborted launch. Fixed by bundling them (commit f97259da). A clean-VM launch test (the `mac-vm-test` / `raymol-mac-vm` skills) catches regressions.
- **1.5 (Support URL):** ASC Support URL must resolve. It's `https://raymol.io/support` (served from the RayMol website repo via GitHub Pages). Keep it live; ensure `support@raymol.io` actually receives mail.

## Error 90296 (App sandbox) — Sparkle is the offender

A second upload attempt failed with **90296: "App sandbox not enabled … Sparkle.framework helper executables."** The fix is NOT to sandbox Sparkle — **Sparkle must be excluded from the MAS build entirely** (self-update is disallowed on the MAS). Two things are required, and the flag alone is not enough:
1. `SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) RAYMOL_MAS_RESTRICTED` — compiles out all Sparkle + MCP code (guarded by `#if os(macOS) && !RAYMOL_MAS_RESTRICTED`).
2. **Remove the `- package: Sparkle` SPM dependency** — the binary hard-links `@rpath/Sparkle.framework`, so the flag alone still embeds (and fails to sandbox) the framework.

`archive_appstore.sh` does both: it strips the Sparkle package from a transient `project.yml` (between `# RAYMOL_SPARKLE_BEGIN/END`) and sets the compilation condition. The embedded Python `bin/` executables already get sandbox+inherit entitlements via `RayMolPython.entitlements`, so Sparkle was the only 90296 offender. If 90296 recurs, check that both the strip and the flag are in effect (verify Sparkle absent in the exported app — Step 3).

## Cloud-managed signing (Xcode 26) — "missing cert" is a red herring

`security find-identity -v` will show **no** "Apple Distribution" / "3rd Party Mac Developer" identity even when signing works fine. Xcode 26 fetches the distribution cert per build (cloud-managed) and doesn't persist a keychain identity. Don't chase a "missing cert." The real prerequisite is **Xcode signed into the Apple Developer account** (Settings ▸ Accounts). If it isn't, the archive fails at `-exportArchive` — sign in, then re-run. The exported app signs as `Apple Distribution: Javier Castellanos (VT99UQUQ89)` and the installer as `3rd Party Mac Developer Installer: … (VT99UQUQ89)`.

## Headless upload recipe (verified across 1.6.1 build 18 + 1.7.1 build 20)

No password needed — the API key `.p8` stays on disk; only non-secret IDs are passed:
```bash
KEY="$ASC_KEY_ID"; ISS="$ASC_ISSUER"   # export first; find in ASC ▸ Integrations (not stored in this repo)
xcrun altool --validate-app -f RayMol.pkg -t macos --apiKey "$KEY" --apiIssuer "$ISS"
xcrun altool --upload-app   -f RayMol.pkg -t macos --apiKey "$KEY" --apiIssuer "$ISS"
```
The `.p8` must be at `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`. The key is App Manager role. If it's rotated/revoked, mint a new one in ASC ▸ Users and Access ▸ Integrations ▸ App Store Connect API and update the KEY/ISS + `.p8`.

## Export compliance

Doesn't prompt at submission because the build's Info.plist declares `ITSAppUsesNonExemptEncryption` (RayMol uses only standard HTTPS → exempt). If ASC ever asks, the answer is: uses encryption = standard/exempt (HTTPS only), no non-exempt encryption.

## ASC API status quirk

The stdlib+PyJWT status check (`scripts/asc_status.py`) reads version **states** reliably, but the version→build **relationship** can report "(no build attached)" even when a build IS attached. Trust the **web UI** for build attachment; trust the **API** for the version state.

## "Latest" pinning after a rollback

If a prior Sparkle rollback pinned an older version as GitHub "Latest" or someone manually set the ASC "latest," a new App Store version still becomes the current one once `READY_FOR_SALE`. But if the ASC latest was manually pinned, explicitly confirm the new version is the one served after release. (This is mostly a Sparkle-side concern — see `cut-macos-release` — but keep the two channels' "current version" consistent.)

## Two versions / build numbers

- Only one version can be in review at a time. A prior `WAITING_FOR_REVIEW` blocks a new submission — release or remove it first.
- `CFBundleVersion` (build number) is shared with the Sparkle build via `project.yml`. Builds only ever shipped on Sparkle never reached ASC, so the last ASC build can be several numbers behind the tag — that's fine, as long as the new build is strictly greater than the last **ASC** build.
