#!/bin/bash
# selfhosted_beta.sh — archive, export, and validate or upload ONE RayMol beta
# on the self-hosted runner (puma). Runs AFTER swiftui/ci_scripts/ci_post_clone.sh
# has staged deps, stamped version + build number and regenerated the project;
# this covers only what Xcode Cloud itself did after that hook.
#
# Usage: scripts/selfhosted_beta.sh <iOS|macOS> [--validate-only]
#
# Signing: the archive is ad hoc (macOS) or unsigned (iOS, see below), and Apple
# cloud signing mints the Distribution identity at export, authenticated by the ASC API key — so no private key
# lives in puma's keychain, which matters because puma's console is usually
# locked. Same split Xcode Cloud used.
#
# Env overrides (tests, unusual setups):
#   ASC_ENV_FILE     default ~/.appstoreconnect/raymol_telemetry.env
#   ASC_KEY_DIR      default ~/.appstoreconnect/private_keys
#   RAYMOL_BETA_OUT  default <repo>/build_selfhosted/<platform>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage () { echo "usage: $0 <iOS|macOS> [--validate-only]" >&2; exit 2; }

PLATFORM="${1:-}"
MODE=upload
[ "$#" -le 2 ] || usage
case "${2:-}" in
  "") ;;
  --validate-only) MODE=validate ;;
  *) usage ;;
esac
case "$PLATFORM" in
  # iOS archives UNSIGNED. An ad hoc iOS archive dies at planning with
  # '"PyMOLViewer_iOS" has entitlements that require signing with a development
  # certificate': Xcode injects base entitlements (application-identifier, team,
  # keychain group) that only a provisioning profile can back, whatever the
  # entitlements file says, and puma has no Apple account. Xcode Cloud gets past
  # it only inside its managed account. Export then signs the unsigned app with
  # the Distribution identity and takes its entitlements from the App Store
  # profile (verified on puma 2026-10-14 with a probe app). macOS ad hoc works and
  # keeps its archived entitlements (RayMolMac.entitlements), so it stays as is.
  iOS)   SCHEME=PyMOLViewer_iOS;   DEST='generic/platform=iOS';   ALTOOL_TYPE=ios;   EXT=ipa
         SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO) ;;
  macOS) SCHEME=PyMOLViewer_macOS; DEST='generic/platform=macOS'; ALTOOL_TYPE=macos; EXT=pkg
         SIGN_ARGS=(CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES) ;;
  *) usage ;;
esac

ENV_FILE="${ASC_ENV_FILE:-$HOME/.appstoreconnect/raymol_telemetry.env}"
KEY_DIR="${ASC_KEY_DIR:-$HOME/.appstoreconnect/private_keys}"
# Read the two names we need; never `source` the file (it holds other secrets
# and is not ours to execute).
read_var () {
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1=[\"']?([^\"']*)[\"']?[[:space:]]*\$/\\2/p" "$ENV_FILE" | tail -1
}
[ -f "$ENV_FILE" ] || { echo "ERROR: credentials file $ENV_FILE not found" >&2; exit 1; }
ASC_KEY_ID="$(read_var ASC_KEY_ID)"
ASC_ISSUER="$(read_var ASC_ISSUER)"
[ -n "$ASC_KEY_ID" ] && [ -n "$ASC_ISSUER" ] || {
  echo "ERROR: ASC_KEY_ID / ASC_ISSUER missing from $ENV_FILE" >&2; exit 1; }
KEY="$KEY_DIR/AuthKey_$ASC_KEY_ID.p8"
[ -f "$KEY" ] || { echo "ERROR: API key not found at $KEY" >&2; exit 1; }

OUT="${RAYMOL_BETA_OUT:-$ROOT/build_selfhosted/$PLATFORM}"
# Start from nothing: a package left by an earlier run must never be uploaded
# in place of the one this run failed to produce.
rm -rf "$OUT"
mkdir -p "$OUT/logs"
ARCHIVE="$OUT/RayMol-$PLATFORM.xcarchive"
EXPORT="$OUT/export"

# Log artifacts are downloadable by anyone on this public repo, so the ASC key
# id and issuer (kept out of the repo by policy) are scrubbed as logs are
# written rather than afterwards — a failure path can never skip it.
redact () { sed -e "s/$ASC_KEY_ID/***/g" -e "s/$ASC_ISSUER/***/g"; }

fail_with_log () {
  tail -60 "$2" >&2 || true
  echo "ERROR: $1 failed (full log: $2)" >&2
  exit 1
}

echo "== 1/3  archive $SCHEME (${SIGN_ARGS[*]}) =="
# Fresh DerivedData inside $OUT (wiped above) — like Xcode Cloud, never an
# incremental build on top of last night's (cf. stale-core DMGs). The shell
# script environment of the runner's login session stays out of the log.
xcodebuild -project "$ROOT/swiftui/PyMOLViewer.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination "$DEST" -archivePath "$ARCHIVE" \
  -derivedDataPath "$OUT/DerivedData" -hideShellScriptEnvironment \
  -skipPackagePluginValidation -skipMacroValidation \
  "${SIGN_ARGS[@]}" \
  archive 2>&1 | redact > "$OUT/logs/archive.log" || fail_with_log archive "$OUT/logs/archive.log"

echo "== 2/3  export for App Store Connect (cloud signing via ASC API key) =="
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>VT99UQUQ89</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
<!-- The build number comes from App Store Connect (max + 1) via
     ci_post_clone.sh and is what the VALID poll waits for; Xcode must not
     renumber it at export. -->
<key>manageAppVersionAndBuildNumber</key><false/>
<!-- Embedded third-party binaries ship stripped; symbol upload only produces
     ~40 harmless failures. Same choice as swiftui/archive_appstore.sh. -->
<key>uploadSymbols</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER" \
  2>&1 | redact > "$OUT/logs/export.log" || fail_with_log export "$OUT/logs/export.log"

shopt -s nullglob
PKGS=("$EXPORT"/*."$EXT")
shopt -u nullglob
[ "${#PKGS[@]}" -eq 1 ] || {
  echo "ERROR: expected exactly one .$EXT in $EXPORT, found ${#PKGS[@]}" >&2; exit 1; }
[ -s "${PKGS[0]}" ] || { echo "ERROR: ${PKGS[0]} is empty" >&2; exit 1; }

echo "== 3/3  altool --$MODE-app ${PKGS[0]##*/} =="
case "$MODE" in
  upload)   OK_RE='UPLOAD SUCCEEDED|No errors uploading' ;;
  validate) OK_RE='VERIFY SUCCEEDED|No errors validating' ;;
esac
set +e
API_PRIVATE_KEYS_DIR="$KEY_DIR" xcrun altool "--$MODE-app" -f "${PKGS[0]}" \
  -t "$ALTOOL_TYPE" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER" \
  2>&1 | redact > "$OUT/logs/altool.log"
RC=${PIPESTATUS[0]}
set -e
cat "$OUT/logs/altool.log"
# altool can exit 0 while reporting a rejection, and its error wording drifts
# between Xcode versions: require the positive success line for this mode, and
# still fail on any known error line.
if [ "$RC" -ne 0 ] || grep -qE 'ERROR ITMS-|\*\*\* Error|^ERROR:' "$OUT/logs/altool.log" \
   || ! grep -qE "$OK_RE" "$OUT/logs/altool.log"; then
  echo "ERROR: altool --$MODE-app failed (rc=$RC)" >&2
  exit 1
fi
echo "selfhosted_beta OK — $PLATFORM $MODE ${PKGS[0]##*/}"
