# Release failure modes & recovery

Hard-won lessons from cutting v1.3–v1.5.x. Read the relevant entry when a step misbehaves.

## Stale `libpymol_core.a` — ships a binary missing C++ changes, no error
`xcodebuild` and `make_dmg.sh` only **link** the prebuilt `build_macos_swiftui/libpymol_core.a`; they never rebuild it. If any C++/Metal file (`layer*`, `layerGraphics/`) changed since the last core build, the change is silently absent at runtime even though the build reports SUCCESS. This shipped a broken v1.3.0 (a merged fix was in the source but not the `.a`) → had to hotfix v1.3.1.
**Cure:** run `swiftui/build_macos.sh` from the final release checkout before `make_dmg.sh`. Verify `stat -f '%Sm' build_macos_swiftui/libpymol_core.a` is newer than your last C++ edit / the release commit.

## Wrong checkout — built the wrong branch's code + version
`make_dmg.sh`/`build_macos.sh`/`publish_release.sh` compute `PYMOL_ROOT` from the **script's own location**. On v1.4.1, running the release from the main repo (`cd /Users/jcastellanos/repos/RayMol`) while it was on a different branch built that branch's app at the old version — notarized fine, wrong bits. 
**Cure:** run the scripts by absolute path *inside the release worktree*, and always verify `build_dmg/RayMol.app/Contents/Info.plist` shows the intended version BEFORE publishing.

## Direct push to master is BLOCKED
As of the CLAUDE.md "development workflow conventions" (PR #86), the harness DENIES `git push origin HEAD:master`. The earlier habit of pushing release bump/appcast commits straight to master no longer works.
**Cure:** everything via PR — `git push -u origin <branch>` → `gh pr create -R javierbq/RayMol --base master` → `gh pr merge --merge`. `gh pr merge` is the sanctioned merge (not a direct push). **Tag** pushes (`git push origin vX.Y.Z`) are still allowed — only default-**branch** pushes are gated.

## `hdiutil create` fails under the automated harness (TCC /Volumes block)
The original `make_dmg.sh` step 6 used `hdiutil create -srcfolder`, which mounts a temp volume at `/Volumes/RayMol`; macOS TCC blocks that in automated runs (`Operation not permitted`) even with the sandbox disabled — but it works in the user's own Terminal. Worse, the script used to exit 0 anyway.
**Status:** fixed on master — `make_dmg.sh` now packages mount-free via `hdiutil makehybrid` + `convert`. If you ever hit the old error on an old checkout, the recovery is: `hdiutil makehybrid -hfs -hfs-volume-name RayMol -o /tmp/raw.dmg build_dmg/dmgroot && hdiutil convert /tmp/raw.dmg -format UDZO -o RayMol-X.Y.Z.dmg`, then codesign + notarize + staple the DMG manually.

## DerivedData hash is path-keyed — worktree builds land elsewhere
Xcode's default DerivedData dir is keyed off the `.xcodeproj`'s absolute path, so a worktree gets a different hash than the main repo. `make_dmg.sh` used to read from a hardcoded main-repo hash and would fail ("built app not found") from a worktree.
**Status:** fixed on master — `make_dmg.sh` pins `-derivedDataPath "$PYMOL_ROOT/build_mac_release_dd"`, so it builds from any checkout.

## Sparkle EdDSA key must be in the app, or every update is rejected
If the app ships without `SUPublicEDKey`, Sparkle rejects updates as "improperly signed / (Ed)DSA key removal" on the client (broke the first v1.3.2/build 10). The key injection is a build-phase race.
**Status:** `make_dmg.sh` step 1b re-asserts `SUPublicEDKey` (read from the signing keychain via Sparkle's `generate_keys -p`, so it matches the private key `publish_release.sh` signs the appcast with) and fails fast if absent. Step 6 of this skill verifies it's present.

## Keychain locked / notary profile missing → hangs deep in the build
Signing reads the Developer-ID key from the login keychain; a locked keychain or an unattended prompt hangs the sign step ~30 min in. `make_dmg.sh` and `publish_release.sh` both `caffeinate` and preflight the notary profile, but run the Preflight in SKILL.md yourself first so it fails in seconds, not deep in the build.

## Build the DMG in the BACKGROUND
`make_dmg.sh` runs 20–40 min (Release build + sign every embedded Mach-O + two notarization waits + DMG). The foreground shell timeout is ~10 min. Run it as a background command and poll / wait for the completion notification.

## `capture_viewport` (MCP) can't prove a Metal post-pass feature
`capture_viewport` is a CPU raytrace that bypasses Metal post passes (outline, surface contour, etc.). To verify a live-Metal feature, screenshot the on-screen window (`screencapture`) instead. Relevant when functionally testing rendering fixes in an RC.

## xcodegen rewrites pbxproj TEMP_ UUIDs
`make_dmg.sh`/`build.sh` run `xcodegen generate`, which rewrites `project.pbxproj` (including `TEMP_…` UUID churn). If it dirties the tree in a repo you didn't mean to touch, `git checkout` that noise. The version strings in the regenerated pbxproj (repeated across its build configs) will match `project.yml`.
