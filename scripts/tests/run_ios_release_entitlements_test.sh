#!/bin/bash
# Pins the iOS Release entitlements to a file the self-hosted beta pipeline can
# archive AD HOC (CODE_SIGN_IDENTITY=-, then cloud signing at export).
# `keychain-access-groups` needs a provisioning profile, so an ad hoc archive
# dies with '"PyMOLViewer_iOS" has entitlements that require signing with a
# development certificate' (first puma dry run, 2026-10-14). The macOS slice
# hit the same wall on Xcode Cloud and got RayMolMac.entitlements; iOS now
# gets RayMolIOSApp.entitlements. Nothing in the app calls the Keychain APIs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YML="$ROOT/swiftui/project.yml"
PBX="$ROOT/swiftui/PyMOLViewer.xcodeproj/project.pbxproj"
FAILED=0
ok ()   { echo "  ok: $1"; }
fail () { echo "  FAIL: $1"; FAILED=1; }

echo "== iOS Release entitlements =="

# The active (uncommented) iphoneos override in project.yml.
LINE="$(grep -E '^[[:space:]]+"CODE_SIGN_ENTITLEMENTS\[sdk=iphoneos\*\]":' "$YML")"
COUNT="$(grep -cE '^[[:space:]]+"CODE_SIGN_ENTITLEMENTS\[sdk=iphoneos\*\]":' "$YML")"
[ "$COUNT" = 1 ] && ok "exactly one active iphoneos entitlements override" \
  || fail "expected one active iphoneos entitlements override in project.yml, found $COUNT"
REL="$(sed -E 's/.*:[[:space:]]*//' <<<"$LINE")"
FILE="$ROOT/swiftui/$REL"

if [ -n "$REL" ] && [ -f "$FILE" ]; then
  ok "override points at an existing file ($REL)"
  plutil -lint -s "$FILE" && ok "$REL is a valid plist" || fail "$REL is not a valid plist"
  grep -q "keychain-access-groups" "$FILE" \
    && fail "$REL carries keychain-access-groups (ad hoc archive will fail)" \
    || ok "$REL has no keychain-access-groups"
else
  fail "iphoneos entitlements override missing or points at a missing file ('$REL')"
fi

# The committed, xcodegen-generated project must carry the same override, or
# a checkout that skips xcodegen archives with the old entitlements.
grep -qF "\"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]\" = $REL;" "$PBX" \
  && ok "project.pbxproj carries the iphoneos override (regenerated)" \
  || fail "project.pbxproj lacks '\"CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]\" = $REL;' — run xcodegen"

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
