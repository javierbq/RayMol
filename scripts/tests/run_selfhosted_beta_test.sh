#!/bin/bash
# Unit tests for scripts/selfhosted_beta.sh — the archive/export/upload half of
# the self-hosted beta pipeline. xcodebuild and xcrun are PATH stubs, so this
# pins the flags, the validate/upload switch and every failure gate in seconds;
# the real tools only run on puma.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/selfhosted_beta.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; KEYS="$TMP/keys"; ENVF="$TMP/asc.env"; CALLS="$TMP/calls"
mkdir -p "$BIN" "$KEYS"
FAILED=0

printf '# test creds\nexport ASC_KEY_ID="KID123"\nASC_ISSUER='"'"'iss-uuid'"'"'\nASC_VENDOR=1\n' > "$ENVF"
echo "fake key" > "$KEYS/AuthKey_KID123.p8"

cat > "$BIN/xcodebuild" <<'EOF'
#!/bin/bash
echo "xcodebuild $*" >> "$CALLS"
echo "Command line invocation: xcodebuild $*"
if [ "${STUB_ARCHIVE_FAIL:-0}" = 1 ] && [ "${*: -1}" = archive ]; then exit 65; fi
prev=""
for a in "$@"; do
  if [ "$prev" = -exportPath ]; then
    mkdir -p "$a"
    case "${STUB_EXPORT:-one}" in
      one)   echo payload > "$a/RayMol.$STUB_EXT" ;;
      empty) : > "$a/RayMol.$STUB_EXT" ;;
      two)   echo p > "$a/RayMol.$STUB_EXT"; echo p > "$a/Other.$STUB_EXT" ;;
      none)  ;;
    esac
  fi
  prev="$a"
done
exit 0
EOF
cat > "$BIN/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$CALLS"
echo "Running altool with $*"
if [ -n "${STUB_ALTOOL_OUT_FILE:-}" ]; then cat "$STUB_ALTOOL_OUT_FILE"
elif [[ " $* " == *" --validate-app "* ]]; then echo "VERIFY SUCCEEDED with no errors"
else echo "UPLOAD SUCCEEDED with no errors"; fi
exit "${STUB_ALTOOL_RC:-0}"
EOF
chmod +x "$BIN/xcodebuild" "$BIN/xcrun"

# go "<VAR=val ...>" <script args...>   (vars must not contain spaces)
go () {
  local vars="$1"; shift
  : > "$CALLS"
  # shellcheck disable=SC2086
  env PATH="$BIN:$PATH" CALLS="$CALLS" ASC_ENV_FILE="$ENVF" ASC_KEY_DIR="$KEYS" \
      RAYMOL_BETA_OUT="$TMP/out" $vars bash "$SCRIPT" "$@" >"$TMP/stdout" 2>&1
  RC=$?
}
check () {
  if eval "$2"; then echo "  ok: $1"
  else echo "  FAIL: $1 (rc=$RC)"; sed 's/^/      /' "$TMP/stdout"; FAILED=1; fi
}
called () { grep -qF -- "$1" "$CALLS"; }

echo "== selfhosted_beta =="

go "STUB_EXT=ipa" iOS
check "iOS upload succeeds" '[ "$RC" -eq 0 ]'
check "iOS archives PyMOLViewer_iOS for generic iOS" 'called "-scheme PyMOLViewer_iOS" && called "-destination generic/platform=iOS"'
check "archive is ad hoc with plugin/macro validation skipped" 'called "CODE_SIGN_IDENTITY=-" && called "AD_HOC_CODE_SIGNING_ALLOWED=YES" && called "-skipPackagePluginValidation" && called "-skipMacroValidation"'
check "export uses the ASC API key from the env file" 'called "-authenticationKeyID KID123" && called "-authenticationKeyIssuerID iss-uuid" && called "-authenticationKeyPath $KEYS/AuthKey_KID123.p8" && called "-allowProvisioningUpdates"'
check "export options are app-store-connect for team VT99UQUQ89" 'grep -q "<string>app-store-connect</string>" "$TMP/out/ExportOptions.plist" && grep -q "<string>VT99UQUQ89</string>" "$TMP/out/ExportOptions.plist"'
check "iOS uploads the .ipa with altool -t ios" 'called "xcrun altool --upload-app -f $TMP/out/export/RayMol.ipa -t ios --apiKey KID123 --apiIssuer iss-uuid"'

check "archive hides the shell-script environment from the log" 'called "-hideShellScriptEnvironment"'
check "archive builds in a fresh DerivedData inside the wiped output dir" 'called "-derivedDataPath $TMP/out/DerivedData"'
check "export keeps the stamped build number (no Xcode renumbering)" 'grep -q "<key>manageAppVersionAndBuildNumber</key><false/>" "$TMP/out/ExportOptions.plist"'
check "logs never contain the ASC key id or issuer" '! grep -rqE "KID123|iss-uuid" "$TMP/out/logs" && grep -q "Command line invocation" "$TMP/out/logs/export.log"'

go "STUB_EXT=pkg" macOS --validate-only
check "macOS validate-only succeeds" '[ "$RC" -eq 0 ]'
check "macOS archives PyMOLViewer_macOS for generic macOS" 'called "-scheme PyMOLViewer_macOS" && called "-destination generic/platform=macOS"'
check "validate-only validates the .pkg with -t macos and never uploads" 'called "xcrun altool --validate-app -f $TMP/out/export/RayMol.pkg -t macos" && ! called "--upload-app"'

printf 'ERROR ITMS-90062: This bundle is invalid.\n' > "$TMP/itms.txt"
go "STUB_EXT=ipa STUB_ALTOOL_OUT_FILE=$TMP/itms.txt" iOS
check "ITMS error with rc 0 fails the run" '[ "$RC" -ne 0 ] && called "--upload-app"'

printf 'Some unrecognised altool chatter\n' > "$TMP/odd.txt"
go "STUB_EXT=ipa STUB_ALTOOL_OUT_FILE=$TMP/odd.txt" iOS
check "altool output without a success line fails the run" '[ "$RC" -ne 0 ] && called "--upload-app"'

printf 'No errors uploading '"'"'RayMol.ipa'"'"'\n' > "$TMP/legacy.txt"
go "STUB_EXT=ipa STUB_ALTOOL_OUT_FILE=$TMP/legacy.txt" iOS
check "legacy altool success wording is accepted" '[ "$RC" -eq 0 ]'

printf 'UPLOAD SUCCEEDED with no errors\n' > "$TMP/wrongmode.txt"
go "STUB_EXT=pkg STUB_ALTOOL_OUT_FILE=$TMP/wrongmode.txt" macOS --validate-only
check "validate-only needs the VERIFY success line, not UPLOAD" '[ "$RC" -ne 0 ]'

go "STUB_EXT=ipa STUB_ALTOOL_RC=1" iOS
check "altool non-zero exit fails the run" '[ "$RC" -ne 0 ] && called "--upload-app"'

go "STUB_EXT=ipa STUB_ARCHIVE_FAIL=1" iOS
check "archive failure stops before export and altool" '[ "$RC" -ne 0 ] && called "-archivePath" && ! called "-exportArchive" && ! called "xcrun"'

mkdir -p "$TMP/out/export"; echo stale > "$TMP/out/export/RayMol.ipa"
go "STUB_EXT=ipa STUB_EXPORT=none" iOS
check "stale package from previous run is never uploaded" '[ "$RC" -ne 0 ] && called "-exportArchive" && ! called "xcrun"'

go "STUB_EXT=ipa STUB_EXPORT=empty" iOS
check "empty export package fails before altool" '[ "$RC" -ne 0 ] && called "-exportArchive" && ! called "xcrun"'

go "STUB_EXT=ipa STUB_EXPORT=two" iOS
check "ambiguous export (two packages) fails before altool" '[ "$RC" -ne 0 ] && called "-exportArchive" && ! called "xcrun"'

go "" tvOS
check "unknown platform is a usage error (rc 2)" '[ "$RC" -eq 2 ] && ! called "xcodebuild"'

go "STUB_EXT=ipa" iOS --upload
check "unknown flag is a usage error (rc 2)" '[ "$RC" -eq 2 ] && ! called "xcodebuild"'

go "STUB_EXT=ipa ASC_KEY_DIR=$TMP/nowhere" iOS
check "missing API key fails before any build" '[ "$RC" -ne 0 ] && grep -q "API key not found" "$TMP/stdout" && ! called "xcodebuild"'

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
