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
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/PyMOLViewer-aqnajyficesyypbspyruqcvqhkhp/Build/Products/Release"
ENTITLEMENTS="$SWIFTUI/RayMol_DeveloperID.entitlements"
WORK="$PYMOL_ROOT/build_dmg"
APPNAME="RayMol"
VERSION="${VERSION:-1.0.0}"

: "${DEVID:?Set DEVID to your 'Developer ID Application: NAME (TEAMID)' identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-RayMol-notary}"

echo "== 1/8  Build Release app (unsigned; we Developer-ID-sign below) =="
xcodebuild -project "$SWIFTUI/PyMOLViewer.xcodeproj" -scheme PyMOLViewer_macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
SRC_APP="$DERIVED/$APPNAME.app"
[ -d "$SRC_APP" ] || { echo "ERROR: built app not found at $SRC_APP"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
cp -R "$SRC_APP" "$WORK/$APPNAME.app"
APP="$WORK/$APPNAME.app"

echo "== 2/8  Sign every embedded Mach-O, deepest path first =="
# Robust: enumerate ALL real files, keep the Mach-O ones (incl. extensionless
# executables like python3.13), sign deepest-first so nested code is sealed
# before its container.
find "$APP" -type f | while read -r f; do
  file "$f" | grep -q "Mach-O" && printf '%d\t%s\n' "$(grep -o / <<<"$f" | wc -l)" "$f"
done | sort -rn | cut -f2- | while read -r macho; do
  codesign --force --options runtime --timestamp --sign "$DEVID" "$macho"
done

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
hdiutil create -volname "$APPNAME" -srcfolder "$DMGROOT" -fs HFS+ -format UDZO -ov "$DMG"

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
