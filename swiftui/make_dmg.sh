#!/bin/bash
# make_dmg.sh — Build a fully notarized, Developer-ID-signed RayMol.dmg for
# direct (outside-the-App-Store) distribution.
#
# This is SEPARATE from the App Store build: the App Store archive is signed with
# Apple Distribution + App Store provisioning and will not run on other Macs.
# Here we re-sign the whole bundle (incl. every embedded CPython/Tcl/NumPy
# binary) with Developer ID + Hardened Runtime, notarize it, staple it, and wrap
# it in a signed + notarized + stapled DMG.
#
# ── One-time prerequisites ────────────────────────────────────────────────────
#  1. A "Developer ID Application" certificate in your login keychain:
#       Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸
#       "+" ▸ Developer ID Application
#     Verify:  security find-identity -v -p codesigning | grep "Developer ID"
#
#  2. Notary credentials stored as a notarytool keychain profile. Either:
#       # App-specific password (appleid.apple.com ▸ Sign-In & Security):
#       xcrun notarytool store-credentials RayMol-notary \
#         --apple-id <your-apple-id> --team-id VT99UQUQ89 \
#         --password <app-specific-password>
#       # …or an App Store Connect API key (.p8):
#       xcrun notarytool store-credentials RayMol-notary \
#         --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#   DEVID="Developer ID Application: Your Name (VT99UQUQ89)" \
#   NOTARY_PROFILE=RayMol-notary \
#   bash swiftui/make_dmg.sh
#
set -euo pipefail

PYMOL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTUI="$PYMOL_ROOT/swiftui"
# DerivedData path is keyed off the .xcodeproj's absolute path, so building from
# a git worktree lands in a different dir than a hardcoded main-repo hash. Pin it
# explicitly (below, via -derivedDataPath) so the build location is deterministic
# from any checkout — main repo or worktree. Artifact contents are unaffected.
RELEASE_DD="$PYMOL_ROOT/build_mac_release_dd"
DERIVED="$RELEASE_DD/Build/Products/Release"
ENTITLEMENTS="$SWIFTUI/RayMol_DeveloperID.entitlements"
WORK="$PYMOL_ROOT/build_dmg"
APPNAME="RayMol"
VERSION="${VERSION:-1.0.0}"

: "${DEVID:?Set DEVID to your 'Developer ID Application: NAME (TEAMID)' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-RayMol-notary}"

# --- Preflight (hardening after the 1.2.1 build got tripped up) ---------------
# Keep the Mac awake for the whole run. This script has two multi-minute Apple
# notarization waits; a sleep/lock cycle during one of them locked the keychain
# and evicted the notary credential, so the 2nd notarization failed AFTER the
# app was already built, signed, and notarized. -w $$ stops caffeinate on exit.
caffeinate -dims -w "$$" &

# Verify the notary credential is reachable BEFORE the long build + first
# notarization, so a missing/locked profile fails in seconds instead of ~40 min
# in. (notarytool reads the profile from the keychain; this also surfaces a
# locked keychain immediately.)
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notary profile '$NOTARY_PROFILE' is not reachable (missing or keychain locked)."
  echo "  Re-store it:  xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "                  --apple-id <id> --team-id VT99UQUQ89 --password <app-specific-pw>"
  echo "  Then verify:  xcrun notarytool history --keychain-profile $NOTARY_PROFILE"
  exit 1
fi
# ------------------------------------------------------------------------------

echo "== 1/8  Build Release app (unsigned; we Developer-ID-sign below) =="
# Regenerate the Xcode project from project.yml first: this script builds the
# .xcodeproj directly (unlike build.sh, it does not run xcodegen), so without
# this a project.yml change — e.g. the Homebrew-dylib bundling post-build phase
# that makes the app self-contained — would silently NOT make it into the
# release build. Skipped (with a warning) if xcodegen is unavailable.
if command -v xcodegen >/dev/null 2>&1; then
  ( cd "$SWIFTUI" && xcodegen generate >/dev/null )
else
  echo "  WARNING: xcodegen not found — building the existing .xcodeproj as-is."
fi
xcodebuild -project "$SWIFTUI/PyMOLViewer.xcodeproj" -scheme PyMOLViewer_macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$RELEASE_DD" \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
SRC_APP="$DERIVED/$APPNAME.app"
[ -d "$SRC_APP" ] || { echo "ERROR: built app not found at $SRC_APP"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$SRC_APP" "$WORK/$APPNAME.app"
APP="$WORK/$APPNAME.app"

echo "== 1b/8  Ensure Sparkle auto-update keys are in Info.plist =="
# CRITICAL: the build-time injection (project.yml 'Sparkle: inject…' run-script
# phase) edits the generated Info.plist but declares no dependency on it, so its
# ordering vs Xcode's Info.plist processing is a RACE. When it loses, the app
# ships WITHOUT SUPublicEDKey — and Sparkle rejects every such update on the
# client as "(Ed)DSA key removal" → "The update is improperly signed and could
# not be validated." (This is exactly what broke the first 1.3.2/build 10.)
# Re-assert the keys here, deterministically, on the copied app BEFORE signing
# so the signature covers them and BEFORE the long notarization so a keyless
# build fails fast instead of shipping. The public key is read from the signing
# keychain (generate_keys -p) so it ALWAYS matches the private key that
# publish_release.sh's sign_update uses to sign the appcast.
PLIST="$APP/Contents/Info.plist"
GEN_KEYS="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*Sparkle/bin/generate_keys' 2>/dev/null | head -1)"
[ -x "$GEN_KEYS" ] || { echo "ERROR: Sparkle generate_keys not found; build the project once so SPM resolves Sparkle."; exit 1; }
ED_PUB="$("$GEN_KEYS" -p 2>/dev/null)"
[ -n "$ED_PUB" ] || { echo "ERROR: could not read the Sparkle EdDSA public key from the keychain (is it unlocked?)."; exit 1; }
/usr/bin/plutil -replace SUFeedURL -string "https://github.com/javierbq/RayMol/releases/latest/download/appcast.xml" "$PLIST"
/usr/bin/plutil -replace SUPublicEDKey -string "$ED_PUB" "$PLIST"
/usr/bin/plutil -replace SUEnableAutomaticChecks -bool true "$PLIST"
/usr/bin/plutil -replace SUScheduledCheckInterval -integer 86400 "$PLIST"
GOT="$(/usr/bin/plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null)"
[ "$GOT" = "$ED_PUB" ] || { echo "ERROR: SUPublicEDKey injection/verification failed."; exit 1; }
echo "  SUPublicEDKey=$ED_PUB injected + verified in $PLIST"

echo "== 2/8  Sign every embedded Mach-O, deepest path first =="
# Enumerate ALL real files, keep the Mach-O ones (incl. extensionless
# executables like python3.13), sign deepest-first so nested code is sealed
# before its container. Capture the list with `|| true`: the enumeration
# pipeline exits non-zero whenever the final file is non-Mach-O (grep -q → 1),
# which would otherwise trip `set -e -o pipefail` after a fully successful run.
#
# EXCLUDE the main executable (Contents/MacOS/$APPNAME): the bundled Homebrew
# dylibs (libfreetype/libpng, embedded by the build's Frameworks phase) sit at
# the SAME path depth as it, so the deepest-first sort can't guarantee they are
# signed before it — and codesign refuses to sign the main binary while a linked
# nested dylib is still unsigned ("code object is not signed at all in
# subcomponent"). The main executable is sealed (with entitlements + hardened
# runtime) by the bundle-level sign in step 3/8, after all nested code is signed.
machos="$( { find "$APP" -type f ! -path "$APP/Contents/MacOS/$APPNAME" | while read -r f; do
  file "$f" | grep -q "Mach-O" && printf '%d\t%s\n' "$(grep -o / <<<"$f" | wc -l)" "$f"
done | sort -rn | cut -f2-; } || true )"
while IFS= read -r macho; do
  [ -n "$macho" ] || continue
  # Retry the secure timestamp: Apple's TSA (timestamp.apple.com) occasionally
  # throttles rapid batch requests across dozens of nested binaries.
  signed=0
  for attempt in 1 2 3 4 5; do
    if codesign --force --options runtime --timestamp --sign "$DEVID" "$macho"; then signed=1; break; fi
    echo "  (timestamp retry $attempt for $(basename "$macho"))"; sleep 5
  done
  [ "$signed" = 1 ] || { echo "ERROR: could not sign $macho after retries"; exit 1; }
done <<< "$machos"

# Sparkle re-seal: the flat loop above signs each nested Mach-O as a bare file,
# but Sparkle ships nested *bundles* (Updater.app + XPCServices/*.xpc) whose
# seals must be re-established as bundles, inside-out, or `codesign --verify
# --deep` reports "nested code is modified or invalid". Sign the helpers, then
# the framework itself. Guarded so non-Sparkle builds are unaffected.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  echo "== 2b/8  Re-seal Sparkle nested bundles (inside-out) =="
  SPV="$SPARKLE_FW/Versions/Current"
  for sp in \
    "$SPV/XPCServices/Downloader.xpc" \
    "$SPV/XPCServices/Installer.xpc" \
    "$SPV/Autoupdate" \
    "$SPV/Updater.app" \
    "$SPARKLE_FW"; do
    [ -e "$sp" ] || continue
    codesign --force --options runtime --timestamp --sign "$DEVID" "$sp"
  done
fi

echo "== 3/8  Sign the app bundle (Hardened Runtime + entitlements) =="
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== 4/8  Notarize the app =="
ZIP="$WORK/$APPNAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== 5/8  Staple the app =="
xcrun stapler staple "$APP"

echo "== 6/8  Build the DMG (app + /Applications drop target) =="
DMGROOT="$WORK/dmgroot"; rm -rf "$DMGROOT"; mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
DMG="$PYMOL_ROOT/$APPNAME-$VERSION.dmg"
rm -f "$DMG"
# Mount-free packaging: `hdiutil create -srcfolder` mounts a temp volume at
# /Volumes/RayMol, which sandbox/TCC blocks in automated runs. makehybrid +
# convert produces an identical UDZO DMG without ever mounting a volume.
RAW="$WORK/raw.dmg"; rm -f "$RAW"
hdiutil makehybrid -hfs -hfs-volume-name "$APPNAME" -o "$RAW" "$DMGROOT"
hdiutil convert "$RAW" -format UDZO -o "$DMG"
rm -f "$RAW"

echo "== 7/8  Sign + notarize + staple the DMG =="
codesign --force --timestamp --sign "$DEVID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "== 8/8  Verify =="
echo "-- app (expect: accepted, source=Notarized Developer ID) --"
spctl -a -vvv "$APP" 2>&1 || true
echo "-- dmg --"
spctl -a -t open --context context:primary-signature -vvv "$DMG" 2>&1 || true
echo ""
echo "DONE → $DMG"
