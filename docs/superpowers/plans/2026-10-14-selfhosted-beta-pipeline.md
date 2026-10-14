# Self-hosted Beta Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build RayMol iOS + macOS TestFlight betas nightly (and on demand) with GitHub Actions on the self-hosted Mac mini `puma`, replacing the quota-exhausted Xcode Cloud Beta workflows.

**Architecture:** The workflow `.github/workflows/beta-selfhosted.yml` runs on puma. A `plan` job decides whether to build and reads the next build number from App Store Connect. A two-leg `beta` matrix (iOS, macOS) then stages each platform with the existing Xcode Cloud hook `swiftui/ci_scripts/ci_post_clone.sh`, called unchanged with Xcode Cloud's env vars set by hand. After that, the new `scripts/selfhosted_beta.sh` archives ad hoc, exports with the ASC API key (Apple cloud signing), and validates or uploads with `altool`. Small Python tools that talk to App Store Connect share one client, `scripts/asc_api.py`.

**Tech Stack:** GitHub Actions (self-hosted macOS runner), bash (BSD userland), Python 3 stdlib + PyJWT/cryptography (only for live ASC calls), `xcodebuild`, `xcrun altool`, App Store Connect API.

**Spec:** `docs/superpowers/specs/2026-10-14-selfhosted-beta-pipeline-design.md`

## Global Constraints

- Runner labels: `self-hosted`, `macOS`, `puma`. The workflow only ever builds `refs/heads/master`.
- Trigger: `schedule` cron `0 8 * * *` (08:00 UTC) and `workflow_dispatch` with input `validate_only` (boolean, default `true`). Scheduled runs never validate-only; they upload.
- Scheduled runs are a no-op unless repo variable `SELFHOSTED_BETA_ENABLED == 'true'`. Manual dispatches ignore it.
- Concurrency group `beta-selfhosted`, `cancel-in-progress: false`. Matrix `max-parallel: 1`, `fail-fast: false`. `timeout-minutes: 90` per leg.
- App Store Connect app id `6781513038`. Team `VT99UQUQ89`. Xcode Cloud workflow ids: iOS `dae50fce-7bb7-43d8-a162-62cdf97269a9`, macOS `8da3fc21-ce16-4029-8050-02ac4ccd48b8`.
- Credentials: `~/.appstoreconnect/raymol_telemetry.env` (`ASC_KEY_ID`, `ASC_ISSUER`; lines may carry `export ` and quotes) + `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`. Overridable by `ASC_ENV_FILE` / `ASC_KEY_DIR`. Never `source` the env file. Read only those two names.
- Build number = max numeric build in ASC for the app (both platforms, releases + betas, expired included) + 1, computed once per run and given to both legs.
- Archive flags: `CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES -skipPackagePluginValidation -skipMacroValidation`. Export: `method=app-store-connect`, `teamID=VT99UQUQ89`, `signingStyle=automatic`, `destination=export`, `uploadSymbols=false`, `-allowProvisioningUpdates` + `-authenticationKeyPath/-ID/-IssuerID`.
- Shell scripts are macOS-only (BSD `sed`), `set -euo pipefail`. Tests follow the `scripts/tests/run_*_test.sh` convention (print `ok:`/`FAIL:` lines, end with `PASS` or exit 1), so `ios-pipeline-script-tests.yml` discovers them by glob.
- Unit tests must run offline on a stock `python3` with no PyJWT. `jwt` is imported lazily, only when a token is minted.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. PR body ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`. `gh` commands always pass `-R javierbq/RayMol`.

## Review Focus

1. **Build numbers compared as strings.** If ASC versions were compared as strings, `"99"` would beat `"362"`, the upload would be rejected as a duplicate or lower build, and every nightly would fail. They must be compared as integers. (Task 1 test `test_numeric_not_lexicographic`.)
2. **ASC returns no builds.** This happens with a wrong app id or a key without access. The script must refuse instead of printing `1`, because build 1 would collide and fail at upload with a confusing ITMS error. (Task 1 test `test_no_builds_refuses`.)
3. **`altool` exits 0 but prints `ERROR ITMS-…`.** The leg has to go red. Otherwise CI shows green while nothing reaches TestFlight, which is the silent failure this whole effort started from. (Task 2 case "ITMS error with rc 0".)
4. **The export produces nothing, but last night's package is still on disk.** The script must fail. It must not re-upload the stale file. (Task 2 case "stale package from previous run is never uploaded".)
5. **A manual dispatch from a non-master branch.** It must be refused before any build or signing step runs. A self-hosted signer must never build unreviewed code. (Task 7 step "non-master dispatch is refused".)

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/asc_api.py` (new) | Read the credentials, mint the ES256 JWT, make HTTP requests to App Store Connect. No CLI. |
| `scripts/asc_next_build_number.py` (new) | Page through `/v1/builds` and print max+1. |
| `scripts/xcode_cloud_beta_workflows.py` (new) | `status|disable|enable` for the two Xcode Cloud Beta workflows, reading back every write. |
| `scripts/selfhosted_beta.sh` (new) | Archive, export, then altool validate or upload, for one platform. Runs after `ci_post_clone.sh`. |
| `scripts/tests/asc_tools_test.py` (new) | Offline unittest for the three Python files. |
| `scripts/tests/run_asc_tools_test.sh` (new) | Glob-discoverable wrapper that runs the unittest above. |
| `scripts/tests/run_selfhosted_beta_test.sh` (new) | Tests `selfhosted_beta.sh` with stubbed `xcodebuild`/`xcrun`. |
| `.github/workflows/beta-selfhosted.yml` (new) | The pipeline. |
| `.github/workflows/ios-pipeline-script-tests.yml` (modify header comment only) | List the new scripts it now covers. |
| `.gitignore` (modify) | Ignore `build_selfhosted/`. |
| `docs/ci/selfhosted-beta-runner.md` (new) | Runbook: puma runner setup, rollout, troubleshooting. |

---

### Task 1: App Store Connect client and next-build-number tool

**Files:**
- Create: `scripts/asc_api.py`
- Create: `scripts/asc_next_build_number.py`
- Create: `scripts/tests/asc_tools_test.py`
- Create: `scripts/tests/run_asc_tools_test.sh`

**Interfaces:**
- Produces: `asc_api.load_env(path) -> dict[str,str]`; `asc_api.credentials() -> (key_id, issuer, key_path)`; `asc_api.request(method, path, body=None) -> dict`; `asc_api.get(path) -> dict`; `asc_api.RAYMOL_APP_ID == "6781513038"`.
- Produces: `asc_next_build_number.PAGE` (format string with `{app}`); `iter_build_pages(get, app_id)` (generator of page dicts, follows `links.next`); `build_number(version) -> int | None`; `next_build_number(pages) -> int` (raises `ValueError` when no numeric build exists); CLI prints the integer and exits 0, or prints `ERROR: …` to stderr and exits 1.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/asc_tools_test.py`:

```python
"""Offline unit tests for the App Store Connect helpers used by the
self-hosted beta pipeline. No network, no PyJWT: every ASC call goes through
an injected fake."""
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import asc_api  # noqa: E402
import asc_next_build_number as nbn  # noqa: E402


def fake_get(pages):
    calls = []

    def get(path):
        calls.append(path)
        return pages[path]

    get.calls = calls
    return get


def page(*versions, next_url=None):
    return {"data": [{"attributes": {"version": v}} for v in versions],
            "links": {"next": next_url} if next_url else {}}


FIRST = nbn.PAGE.format(app="APP")


class LoadEnvTest(unittest.TestCase):
    def test_export_quotes_comments(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write('# comment\n\nexport ASC_KEY_ID="KID123"\nASC_ISSUER=\'iss-uuid\'\nASC_VENDOR=94460417\n')
        try:
            env = asc_api.load_env(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(env["ASC_KEY_ID"], "KID123")
        self.assertEqual(env["ASC_ISSUER"], "iss-uuid")
        self.assertEqual(env["ASC_VENDOR"], "94460417")


class NextBuildNumberTest(unittest.TestCase):
    def test_max_across_pages_plus_one(self):
        get = fake_get({FIRST: page("203", "362", next_url="https://x/p2"),
                        "https://x/p2": page("361", "204")})
        self.assertEqual(nbn.next_build_number(nbn.iter_build_pages(get, "APP")), 363)
        self.assertEqual(get.calls, [FIRST, "https://x/p2"])

    def test_numeric_not_lexicographic(self):
        # As strings "99" > "362"; as build numbers it is not.
        self.assertEqual(nbn.next_build_number([page("99", "362", "1000")]), 1001)

    def test_dotted_and_non_numeric_versions(self):
        self.assertEqual(nbn.build_number("32.190"), 32)
        self.assertIsNone(nbn.build_number("beta"))
        self.assertIsNone(nbn.build_number(""))
        self.assertEqual(nbn.next_build_number([page("beta", "32.190", "40")]), 41)

    def test_no_builds_refuses(self):
        with self.assertRaises(ValueError):
            nbn.next_build_number([page()])
        with self.assertRaises(ValueError):
            nbn.next_build_number([page("beta", "")])

    def test_import_does_not_need_jwt(self):
        code = ("import sys; sys.path.insert(0, %r); "
                "import asc_next_build_number; print('jwt' in sys.modules)") % SCRIPTS
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), "False")


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

Create `scripts/tests/run_asc_tools_test.sh`:

```bash
#!/bin/bash
# Runs scripts/tests/asc_tools_test.py — offline unit tests for the App Store
# Connect helpers behind the self-hosted beta pipeline (asc_api.py,
# asc_next_build_number.py, xcode_cloud_beta_workflows.py). A wrong build
# number fails the TestFlight upload ~30 minutes into a nightly run, so the
# number logic is pinned here where it costs seconds.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "== asc tools =="
if python3 "$ROOT/scripts/tests/asc_tools_test.py"; then
  echo "PASS"
else
  echo "FAILURES"; exit 1
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run_asc_tools_test.sh`
Expected: `ModuleNotFoundError: No module named 'asc_api'` then `FAILURES`, exit 1.

- [ ] **Step 3: Write the implementation**

Create `scripts/asc_api.py`:

```python
#!/usr/bin/env python3
"""App Store Connect API client shared by the self-hosted beta pipeline.

Credentials are the same files the release skills use:
  ~/.appstoreconnect/raymol_telemetry.env      ASC_KEY_ID, ASC_ISSUER
  ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
ASC_ENV_FILE / ASC_KEY_DIR override those paths.

PyJWT is imported only when a token is minted, so the offline unit tests
(scripts/tests/asc_tools_test.py) run on a stock python3.
"""
import json
import os
import time
import urllib.error
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"
RAYMOL_APP_ID = "6781513038"


def _paths():
    home = os.path.expanduser("~/.appstoreconnect")
    return (os.environ.get("ASC_ENV_FILE", os.path.join(home, "raymol_telemetry.env")),
            os.environ.get("ASC_KEY_DIR", os.path.join(home, "private_keys")))


def load_env(path):
    """Parse KEY=value lines (optionally `export`-prefixed and quoted) without
    executing the file."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip().strip("'\"")
    return out


def credentials():
    env_file, key_dir = _paths()
    env = load_env(env_file)
    key_id, issuer = env["ASC_KEY_ID"], env["ASC_ISSUER"]
    return key_id, issuer, os.path.join(key_dir, f"AuthKey_{key_id}.p8")


def token():
    import jwt  # PyJWT + cryptography; see docs/ci/selfhosted-beta-runner.md

    key_id, issuer, key_path = credentials()
    with open(key_path) as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      private_key, algorithm="ES256", headers={"kid": key_id})


def request(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise SystemExit(f"ASC {method} {path} -> HTTP {e.code}: {detail}")
    return json.loads(raw) if raw else {}


def get(path):
    return request("GET", path)
```

Create `scripts/asc_next_build_number.py`:

```python
#!/usr/bin/env python3
"""Print the next TestFlight build number for RayMol.

It is 1 + the highest build number App Store Connect holds for the app,
across iOS and macOS, releases and betas, expired or not. One shared counter
keeps Apple's rule that Mac build numbers always increase across versions,
the same way Xcode Cloud's CI_BUILD_NUMBER did.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

PAGE = "/v1/builds?filter[app]={app}&limit=200&fields[builds]=version"


def iter_build_pages(get, app_id):
    path = PAGE.format(app=app_id)
    while path:
        page = get(path)
        yield page
        path = (page.get("links") or {}).get("next")


def build_number(version):
    """'362' -> 362, '32.190' -> 32 (Apple orders by the leading component
    first), anything non-numeric -> None."""
    head = str(version).split(".", 1)[0]
    return int(head) if head.isdigit() else None


def next_build_number(pages):
    numbers = []
    for page in pages:
        for build in page.get("data", []):
            n = build_number(build.get("attributes", {}).get("version", ""))
            if n is not None:
                numbers.append(n)
    if not numbers:
        raise ValueError("App Store Connect returned no numeric builds for the app; "
                         "refusing to guess (wrong app id or key without access?)")
    return max(numbers) + 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Print the next RayMol TestFlight build number.")
    ap.add_argument("--app", default=asc_api.RAYMOL_APP_ID)
    args = ap.parse_args(argv)
    try:
        print(next_build_number(iter_build_pages(asc_api.get, args.app)))
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash scripts/tests/run_asc_tools_test.sh`
Expected: 6 tests `ok`, then `PASS`, exit 0.

- [ ] **Step 5: Live check against ASC (read-only)**

Run from a machine that has the credentials and PyJWT (this MacBook):
`python3 scripts/asc_next_build_number.py`
Expected: a single integer at least `363`. On 2026-10-14 the highest uploaded build was 362.

- [ ] **Step 6: Commit**

```bash
git add scripts/asc_api.py scripts/asc_next_build_number.py scripts/tests/asc_tools_test.py scripts/tests/run_asc_tools_test.sh
git commit -m "ci: ASC client and next-build-number tool for the self-hosted beta pipeline

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `selfhosted_beta.sh` (archive, export, validate or upload)

**Files:**
- Create: `scripts/selfhosted_beta.sh`
- Create: `scripts/tests/run_selfhosted_beta_test.sh`
- Modify: `.gitignore` (append one line)

**Interfaces:**
- Consumes: the repo state that `swiftui/ci_scripts/ci_post_clone.sh` leaves behind: staged deps, version and build number stamped, `swiftui/PyMOLViewer.xcodeproj` regenerated.
- Produces: CLI `scripts/selfhosted_beta.sh <iOS|macOS> [--validate-only]`. It exits 0 on success, 2 on bad usage and 1 on any failure. Logs go to `$RAYMOL_BETA_OUT/logs/{archive,export,altool}.log`, where `RAYMOL_BETA_OUT` defaults to `<repo>/build_selfhosted/<platform>`. Task 4 uploads that `logs` dir as an artifact.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_selfhosted_beta_test.sh`:

```bash
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
if [ -n "${STUB_ALTOOL_OUT_FILE:-}" ]; then cat "$STUB_ALTOOL_OUT_FILE"; else echo "No errors uploading"; fi
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

go "STUB_EXT=pkg" macOS --validate-only
check "macOS validate-only succeeds" '[ "$RC" -eq 0 ]'
check "macOS archives PyMOLViewer_macOS for generic macOS" 'called "-scheme PyMOLViewer_macOS" && called "-destination generic/platform=macOS"'
check "validate-only validates the .pkg with -t macos and never uploads" 'called "xcrun altool --validate-app -f $TMP/out/export/RayMol.pkg -t macos" && ! called "--upload-app"'

printf 'ERROR ITMS-90062: This bundle is invalid.\n' > "$TMP/itms.txt"
go "STUB_EXT=ipa STUB_ALTOOL_OUT_FILE=$TMP/itms.txt" iOS
check "ITMS error with rc 0 fails the run" '[ "$RC" -ne 0 ]'

go "STUB_EXT=ipa STUB_ALTOOL_RC=1" iOS
check "altool non-zero exit fails the run" '[ "$RC" -ne 0 ]'

go "STUB_EXT=ipa STUB_ARCHIVE_FAIL=1" iOS
check "archive failure stops before export and altool" '[ "$RC" -ne 0 ] && ! called "-exportArchive" && ! called "xcrun"'

mkdir -p "$TMP/out/export"; echo stale > "$TMP/out/export/RayMol.ipa"
go "STUB_EXT=ipa STUB_EXPORT=none" iOS
check "stale package from previous run is never uploaded" '[ "$RC" -ne 0 ] && ! called "xcrun"'

go "STUB_EXT=ipa STUB_EXPORT=empty" iOS
check "empty export package fails before altool" '[ "$RC" -ne 0 ] && ! called "xcrun"'

go "STUB_EXT=ipa STUB_EXPORT=two" iOS
check "ambiguous export (two packages) fails before altool" '[ "$RC" -ne 0 ] && ! called "xcrun"'

go "" tvOS
check "unknown platform is a usage error (rc 2)" '[ "$RC" -eq 2 ] && ! called "xcodebuild"'

go "STUB_EXT=ipa" iOS --upload
check "unknown flag is a usage error (rc 2)" '[ "$RC" -eq 2 ] && ! called "xcodebuild"'

go "STUB_EXT=ipa ASC_KEY_DIR=$TMP/nowhere" iOS
check "missing API key fails before any build" '[ "$RC" -ne 0 ] && ! called "xcodebuild"'

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run_selfhosted_beta_test.sh`
Expected: every case `FAIL` (`bash: …/selfhosted_beta.sh: No such file or directory`), then `FAILURES`, exit 1.

- [ ] **Step 3: Write the implementation**

Create `scripts/selfhosted_beta.sh` (then `chmod +x scripts/selfhosted_beta.sh`):

```bash
#!/bin/bash
# selfhosted_beta.sh — archive, export, and validate or upload ONE RayMol beta
# on the self-hosted runner (puma). Runs AFTER swiftui/ci_scripts/ci_post_clone.sh
# has staged deps, stamped version + build number and regenerated the project;
# this covers only what Xcode Cloud itself did after that hook.
#
# Usage: scripts/selfhosted_beta.sh <iOS|macOS> [--validate-only]
#
# Signing: the archive is AD HOC and Apple cloud signing mints the Distribution
# identity at export, authenticated by the ASC API key — so no private key
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
  iOS)   SCHEME=PyMOLViewer_iOS;   DEST='generic/platform=iOS';   ALTOOL_TYPE=ios;   EXT=ipa ;;
  macOS) SCHEME=PyMOLViewer_macOS; DEST='generic/platform=macOS'; ALTOOL_TYPE=macos; EXT=pkg ;;
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

fail_with_log () {
  tail -60 "$2" >&2 || true
  echo "ERROR: $1 failed (full log: $2)" >&2
  exit 1
}

echo "== 1/3  archive $SCHEME (ad hoc) =="
xcodebuild -project "$ROOT/swiftui/PyMOLViewer.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination "$DEST" -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES \
  archive > "$OUT/logs/archive.log" 2>&1 || fail_with_log archive "$OUT/logs/archive.log"

echo "== 2/3  export for App Store Connect (cloud signing via ASC API key) =="
cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>teamID</key><string>VT99UQUQ89</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>export</string>
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
  > "$OUT/logs/export.log" 2>&1 || fail_with_log export "$OUT/logs/export.log"

shopt -s nullglob
PKGS=("$EXPORT"/*."$EXT")
shopt -u nullglob
[ "${#PKGS[@]}" -eq 1 ] || {
  echo "ERROR: expected exactly one .$EXT in $EXPORT, found ${#PKGS[@]}" >&2; exit 1; }
[ -s "${PKGS[0]}" ] || { echo "ERROR: ${PKGS[0]} is empty" >&2; exit 1; }

echo "== 3/3  altool --$MODE-app ${PKGS[0]##*/} =="
set +e
API_PRIVATE_KEYS_DIR="$KEY_DIR" xcrun altool "--$MODE-app" -f "${PKGS[0]}" \
  -t "$ALTOOL_TYPE" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER" \
  > "$OUT/logs/altool.log" 2>&1
RC=$?
set -e
cat "$OUT/logs/altool.log"
# altool can exit 0 while reporting a rejection; the log is the authority.
if [ "$RC" -ne 0 ] || grep -qE 'ERROR ITMS-|\*\*\* Error' "$OUT/logs/altool.log"; then
  echo "ERROR: altool --$MODE-app failed (rc=$RC)" >&2
  exit 1
fi
echo "selfhosted_beta OK — $PLATFORM $MODE ${PKGS[0]##*/}"
```

Append to `.gitignore`:

```
# Self-hosted beta pipeline output (scripts/selfhosted_beta.sh)
/build_selfhosted/
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `chmod +x scripts/selfhosted_beta.sh scripts/tests/run_selfhosted_beta_test.sh && bash scripts/tests/run_selfhosted_beta_test.sh`
Expected: 18 `ok:` lines, `PASS`, exit 0.

- [ ] **Step 5: Run the whole script-test suite (no regressions)**

Run: `for s in scripts/tests/run_*_test.sh; do bash "$s" >/dev/null 2>&1 && echo "PASS $s" || echo "FAIL $s"; done`
Expected: every line `PASS`.

- [ ] **Step 6: Commit**

```bash
git add scripts/selfhosted_beta.sh scripts/tests/run_selfhosted_beta_test.sh .gitignore
git commit -m "ci: selfhosted_beta.sh archives, exports and uploads one beta on puma

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Xcode Cloud Beta workflow switch

**Files:**
- Create: `scripts/xcode_cloud_beta_workflows.py`
- Modify: `scripts/tests/asc_tools_test.py` (add a test class)

**Interfaces:**
- Consumes: `asc_api.request(method, path, body=None)` from Task 1.
- Produces: CLI `python3 scripts/xcode_cloud_beta_workflows.py status|disable|enable`, which exits 0, or exits 1 if a read-back disagrees with what was written. Also `WORKFLOWS` (name → id), `patch_body(wf_id, enabled) -> dict`, and `run(cmd, request, out=print) -> int`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/tests/asc_tools_test.py`, before the `if __name__ == "__main__":` block:

```python
import xcode_cloud_beta_workflows as xcw  # noqa: E402


class FakeASC:
    """Minimal ciWorkflows store. ignore_writes simulates ASC accepting a
    PATCH without applying it."""

    def __init__(self, enabled=True, ignore_writes=False):
        self.state = {wf: enabled for wf in xcw.WORKFLOWS.values()}
        self.ignore_writes = ignore_writes
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        wf = path.rsplit("/", 1)[-1]
        if method == "PATCH" and not self.ignore_writes:
            self.state[wf] = body["data"]["attributes"]["isEnabled"]
        return {"data": {"id": wf, "attributes": {"isEnabled": self.state[wf]}}}


class XcodeCloudWorkflowsTest(unittest.TestCase):
    def test_patch_body_shape(self):
        self.assertEqual(xcw.patch_body("ID", False),
                         {"data": {"type": "ciWorkflows", "id": "ID",
                                   "attributes": {"isEnabled": False}}})

    def test_disable_both_and_read_back(self):
        fake, lines = FakeASC(enabled=True), []
        self.assertEqual(xcw.run("disable", fake, lines.append), 0)
        self.assertEqual(set(fake.state.values()), {False})
        patched = [p for m, p, _ in fake.calls if m == "PATCH"]
        self.assertEqual(sorted(patched), sorted(f"/v1/ciWorkflows/{w}" for w in xcw.WORKFLOWS.values()))
        self.assertTrue(all("isEnabled=False" in l for l in lines))

    def test_status_never_writes(self):
        fake = FakeASC(enabled=True)
        self.assertEqual(xcw.run("status", fake, lambda _: None), 0)
        self.assertFalse([c for c in fake.calls if c[0] != "GET"])

    def test_write_not_applied_is_an_error(self):
        fake, lines = FakeASC(enabled=True, ignore_writes=True), []
        self.assertEqual(xcw.run("disable", fake, lines.append), 1)
        self.assertTrue(any(l.startswith("ERROR") for l in lines))

    def test_unknown_command(self):
        with self.assertRaises(SystemExit):
            xcw.run("delete", FakeASC(), lambda _: None)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run_asc_tools_test.sh`
Expected: `ModuleNotFoundError: No module named 'xcode_cloud_beta_workflows'`, `FAILURES`.

- [ ] **Step 3: Write the implementation**

Create `scripts/xcode_cloud_beta_workflows.py`:

```python
#!/usr/bin/env python3
"""Show, disable or re-enable RayMol's two Xcode Cloud Beta workflows.

    python3 scripts/xcode_cloud_beta_workflows.py status|disable|enable

Disabling them is rollout step 5 of the self-hosted beta pipeline
(docs/superpowers/specs/2026-10-14-selfhosted-beta-pipeline-design.md).
Once puma delivers betas, Xcode Cloud has to stop. Otherwise it resumes at
the next quota reset and competes with puma for build numbers. Every write is
read back, because a PATCH that ASC accepts but does not apply would leave
both pipelines running without anyone noticing.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

WORKFLOWS = {
    "iOS Beta (master)": "dae50fce-7bb7-43d8-a162-62cdf97269a9",
    "macOS Beta (master)": "8da3fc21-ce16-4029-8050-02ac4ccd48b8",
}


def patch_body(wf_id, enabled):
    return {"data": {"type": "ciWorkflows", "id": wf_id, "attributes": {"isEnabled": enabled}}}


def _is_enabled(request, wf_id):
    return request("GET", f"/v1/ciWorkflows/{wf_id}")["data"]["attributes"]["isEnabled"]


def run(cmd, request, out=print):
    if cmd not in ("status", "disable", "enable"):
        raise SystemExit("usage: xcode_cloud_beta_workflows.py status|disable|enable")
    ok = True
    for name, wf_id in WORKFLOWS.items():
        if cmd != "status":
            want = cmd == "enable"
            request("PATCH", f"/v1/ciWorkflows/{wf_id}", patch_body(wf_id, want))
            got = _is_enabled(request, wf_id)
            if got != want:
                out(f"ERROR: {name}: wrote isEnabled={want}, read back isEnabled={got}")
                ok = False
                continue
        else:
            got = _is_enabled(request, wf_id)
        out(f"{name}: isEnabled={got}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(run(sys.argv[1] if len(sys.argv) > 1 else "", asc_api.request))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash scripts/tests/run_asc_tools_test.sh`
Expected: 11 tests `ok`, `PASS`.

- [ ] **Step 5: Live read-only check**

Run: `python3 scripts/xcode_cloud_beta_workflows.py status`
Expected: two lines, `iOS Beta (master): isEnabled=True` and `macOS Beta (master): isEnabled=True`. Do **not** run `disable` here, because that is Task 7 step 8.

- [ ] **Step 6: Commit**

```bash
git add scripts/xcode_cloud_beta_workflows.py scripts/tests/asc_tools_test.py
git commit -m "ci: script to show/disable/enable the Xcode Cloud Beta workflows

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The `beta-selfhosted.yml` workflow

**Files:**
- Create: `.github/workflows/beta-selfhosted.yml`
- Modify: `.github/workflows/ios-pipeline-script-tests.yml` (header comment lines 3–9 only)

**Interfaces:**
- Consumes: `scripts/asc_next_build_number.py` (Task 1, prints an int), `scripts/selfhosted_beta.sh <platform> [--validate-only]` (Task 2, logs in `build_selfhosted/<platform>/logs`), and `swiftui/ci_scripts/ci_post_clone.sh` (unchanged, reads `CI_PRIMARY_REPOSITORY_PATH`, `CI_BUILD_NUMBER`, `CI_PRODUCT_PLATFORM`, `CI_XCODE_SCHEME`, `CI_XCODEBUILD_ACTION`).
- Produces: workflow file name `beta-selfhosted.yml`, which the runbook and the skip check refer to by name.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/beta-selfhosted.yml`:

```yaml
name: Beta (self-hosted, puma)

# Builds RayMol iOS + macOS betas on the self-hosted Mac mini "puma" and
# uploads them to TestFlight. Replaces Xcode Cloud's "iOS Beta (master)" and
# "macOS Beta (master)" after the Xcode Cloud compute quota ran out (2026-10-12).
#   Design:  docs/superpowers/specs/2026-10-14-selfhosted-beta-pipeline-design.md
#   Runbook: docs/ci/selfhosted-beta-runner.md
#
# Staging is swiftui/ci_scripts/ci_post_clone.sh, UNCHANGED: it only reads the
# five CI_* variables set below, so both systems share one staging path.

on:
  schedule:
    - cron: '0 8 * * *'   # 08:00 UTC = 01:00 Pacific; only when SELFHOSTED_BETA_ENABLED == 'true'
  workflow_dispatch:
    inputs:
      validate_only:
        description: 'Validate with altool instead of uploading to TestFlight'
        type: boolean
        default: true

# One build at a time on one machine; a nightly that fires during a manual run
# waits rather than cancelling it.
concurrency:
  group: beta-selfhosted
  cancel-in-progress: false

permissions:
  contents: read
  actions: read   # gh run list in the skip check

jobs:
  plan:
    # Scheduled runs stay inert until the runner exists and the variable is set,
    # so no jobs queue for a missing runner and expire into failure emails.
    if: github.event_name != 'schedule' || vars.SELFHOSTED_BETA_ENABLED == 'true'
    runs-on: [self-hosted, macOS, puma]
    timeout-minutes: 15
    outputs:
      build: ${{ steps.num.outputs.build }}
      skip: ${{ steps.skip.outputs.skip }}
    steps:
      - name: Refuse anything but master
        # This runner signs and ships; it must never build unreviewed code.
        if: github.ref != 'refs/heads/master'
        run: |
          echo "::error::beta-selfhosted only builds refs/heads/master (got $GITHUB_REF)"
          exit 1

      - name: Skip if the last successful nightly built this commit
        id: skip
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          skip=false
          if [ "$GITHUB_EVENT_NAME" = schedule ]; then
            last="$(gh run list -R "$GITHUB_REPOSITORY" --workflow beta-selfhosted.yml \
                      --event schedule --status success --limit 1 \
                      --json headSha --jq '.[0].headSha // ""')"
            if [ "$last" = "$GITHUB_SHA" ]; then
              echo "master $GITHUB_SHA already has a nightly beta; nothing to do"
              skip=true
            fi
          fi
          echo "skip=$skip" >> "$GITHUB_OUTPUT"

      - uses: actions/checkout@v4
        if: steps.skip.outputs.skip != 'true'

      - name: Python venv for the ASC client (idempotent)
        if: steps.skip.outputs.skip != 'true'
        run: |
          set -euo pipefail
          python3 -m venv "$HOME/.raymol-beta-venv"
          "$HOME/.raymol-beta-venv/bin/pip" install -q --disable-pip-version-check PyJWT cryptography

      - name: Next build number (max in App Store Connect + 1)
        id: num
        if: steps.skip.outputs.skip != 'true'
        run: |
          set -euo pipefail
          n="$("$HOME/.raymol-beta-venv/bin/python" scripts/asc_next_build_number.py)"
          case "$n" in ''|*[!0-9]*) echo "::error::not a build number: '$n'"; exit 1 ;; esac
          echo "next build number: $n"
          echo "build=$n" >> "$GITHUB_OUTPUT"

  beta:
    needs: plan
    if: needs.plan.outputs.skip != 'true'
    runs-on: [self-hosted, macOS, puma]
    timeout-minutes: 90
    strategy:
      fail-fast: false    # a broken iOS slice must not hold back the Mac beta
      max-parallel: 1
      matrix:
        include:
          - platform: iOS
            scheme: PyMOLViewer_iOS
          - platform: macOS
            scheme: PyMOLViewer_macOS
    name: beta (${{ matrix.platform }})
    steps:
      # Default clean checkout: wipes last run's in-place edits AND its deps.
      # The hook re-fetches deps_ios every run anyway, and overlaying a new
      # deps tree on an old one is the stale-artifact bug class it guards against.
      - uses: actions/checkout@v4

      - name: Stage (ci_post_clone.sh, as on Xcode Cloud)
        env:
          CI_PRIMARY_REPOSITORY_PATH: ${{ github.workspace }}
          CI_BUILD_NUMBER: ${{ needs.plan.outputs.build }}
          CI_PRODUCT_PLATFORM: ${{ matrix.platform }}
          CI_XCODE_SCHEME: ${{ matrix.scheme }}
          CI_XCODEBUILD_ACTION: archive
        run: bash swiftui/ci_scripts/ci_post_clone.sh

      - name: Archive, export, ${{ (github.event_name == 'workflow_dispatch' && inputs.validate_only) && 'validate' || 'upload' }}
        run: >-
          bash scripts/selfhosted_beta.sh ${{ matrix.platform }}
          ${{ (github.event_name == 'workflow_dispatch' && inputs.validate_only) && '--validate-only' || '' }}

      - name: Keep logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: beta-logs-${{ matrix.platform }}-${{ github.run_number }}
          path: build_selfhosted/${{ matrix.platform }}/logs
          if-no-files-found: ignore
          retention-days: 14
```

- [ ] **Step 2: Lint it**

Run: `command -v actionlint >/dev/null || brew install actionlint; actionlint .github/workflows/beta-selfhosted.yml`
Expected: no output, exit 0. If `shellcheck` is installed, actionlint also checks the `run:` blocks. Fix any finding before continuing.

- [ ] **Step 3: Update the script-tests workflow header**

In `.github/workflows/ios-pipeline-script-tests.yml`, replace the comment block on lines 3–9:

```yaml
# Runs the unit tests for the iOS beta-pipeline helper scripts:
#   scripts/ios_deps_fingerprint.sh    scripts/apply_ci_versions.sh
#   scripts/nightly_version.sh         scripts/assert_ios_build_inputs.sh
#   scripts/prune_ios_deps.sh
# and, since the macOS beta workflow joined it, the macOS side of the same hook:
#   scripts/ci_platform.sh             scripts/apply_mas_restrictions.sh
#   scripts/assert_macos_build_inputs.sh
```

with:

```yaml
# Runs the unit tests for the iOS beta-pipeline helper scripts:
#   scripts/ios_deps_fingerprint.sh    scripts/apply_ci_versions.sh
#   scripts/nightly_version.sh         scripts/assert_ios_build_inputs.sh
#   scripts/prune_ios_deps.sh
# and, since the macOS beta workflow joined it, the macOS side of the same hook:
#   scripts/ci_platform.sh             scripts/apply_mas_restrictions.sh
#   scripts/assert_macos_build_inputs.sh
# and the self-hosted beta pipeline (beta-selfhosted.yml) on puma:
#   scripts/selfhosted_beta.sh         scripts/asc_next_build_number.py
#   scripts/xcode_cloud_beta_workflows.py
```

Run: `actionlint .github/workflows/ios-pipeline-script-tests.yml`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/beta-selfhosted.yml .github/workflows/ios-pipeline-script-tests.yml
git commit -m "ci: beta-selfhosted workflow builds iOS + macOS betas on puma

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Runbook

**Files:**
- Create: `docs/ci/selfhosted-beta-runner.md`

**Interfaces:**
- Consumes: workflow name `beta-selfhosted.yml`, the labels, the repo variable `SELFHOSTED_BETA_ENABLED`, the venv path `~/.raymol-beta-venv`, and the CLIs from Tasks 1–3.

- [ ] **Step 1: Write the runbook**

Create `docs/ci/selfhosted-beta-runner.md`:

````markdown
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
````

- [ ] **Step 2: Check every path the runbook names exists in the branch**

Run: `for p in .github/workflows/beta-selfhosted.yml scripts/xcode_cloud_beta_workflows.py scripts/asc_next_build_number.py scripts/selfhosted_beta.sh swiftui/ci_scripts/ci_post_clone.sh docs/superpowers/specs/2026-10-14-selfhosted-beta-pipeline-design.md; do test -e "$p" && echo "ok $p" || echo "MISSING $p"; done`
Expected: six `ok` lines.

- [ ] **Step 3: Commit**

```bash
git add docs/ci/selfhosted-beta-runner.md
git commit -m "docs(ci): runbook for the self-hosted beta runner on puma

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Pull request

**Files:** none new.

- [ ] **Step 1: Full local test pass**

Run: `for s in scripts/tests/run_*_test.sh; do bash "$s" >/dev/null 2>&1 && echo "PASS $s" || echo "FAIL $s"; done; actionlint .github/workflows/*.yml`
Expected: all `PASS`, actionlint silent.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin ci/selfhosted-beta-pipeline
gh pr create -R javierbq/RayMol --base master --head ci/selfhosted-beta-pipeline \
  --title "ci: self-hosted beta pipeline on puma (replaces Xcode Cloud betas)" \
  --body "$(cat <<'EOF'
Xcode Cloud's compute quota ran out on 2026-10-12. Since then every beta run has been cancelled before starting, and the last TestFlight beta is build 360/362. This PR moves the beta pipeline to a GitHub Actions self-hosted runner on puma.

- `beta-selfhosted.yml`: runs nightly at 08:00 UTC (once `SELFHOSTED_BETA_ENABLED=true`) and on manual dispatch (`validate_only` defaults to true). It only builds master. It reads the build number from App Store Connect as max + 1, shared by iOS and macOS.
- Staging reuses `swiftui/ci_scripts/ci_post_clone.sh` **unchanged**. The workflow supplies the five `CI_*` variables Xcode Cloud used to set.
- `scripts/selfhosted_beta.sh`: archives ad hoc, then exports with Apple cloud signing through the ASC API key, so puma's keychain needs no private key. Then `altool` validates or uploads. A run fails if altool prints `ITMS` errors even when it exits 0.
- `scripts/xcode_cloud_beta_workflows.py`: shows, disables or enables the Xcode Cloud Beta workflows and reads back every write.
- Runbook: `docs/ci/selfhosted-beta-runner.md`. Spec and plan are under `docs/superpowers/`.

Merging changes nothing yet. No runner exists, and the nightly is gated on the repo variable. Rollout steps are in the runbook.

## Test plan
- [x] `scripts/tests/run_selfhosted_beta_test.sh`: flags, validate/upload switch, ITMS detection, stale/empty/ambiguous export, usage errors
- [x] `scripts/tests/run_asc_tools_test.sh`: numeric max across pages, refusal on empty, read-back of Xcode Cloud writes
- [x] actionlint
- [ ] Rollout: validate-only dispatch on puma, then one real upload, then disable Xcode Cloud, then enable the nightly

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: a PR URL. The `iOS pipeline script tests` check discovers and passes the two new suites.

- [ ] **Step 3: Confirm CI picked up the new suites**

Run: `gh pr checks -R javierbq/RayMol --watch` and then `gh run view -R javierbq/RayMol --log $(gh run list -R javierbq/RayMol --workflow ios-pipeline-script-tests.yml --branch ci/selfhosted-beta-pipeline --limit 1 --json databaseId --jq '.[0].databaseId') | grep -E "PASS scripts/tests/run_(selfhosted_beta|asc_tools)_test.sh"`
Expected: both lines present.

Merging is the user's call. Per memory, release-style PRs here sometimes need `gh pr merge --admin`. Ask, don't assume.

---

### Task 7: Rollout (operational; user + agent)

The classifier blocks the agent from production deploys, credential copies and settings writes. Each step names who runs it. The agent verifies after each step.

- [ ] **Step 1 (user):** Merge the PR.
- [ ] **Step 2 (user):** Run the runbook's "One-time setup on puma", sections 1–4. Section 2 (raise the fork-PR approval policy) comes **before** the runner is registered, and section 3 installs the job guard hook.
- [ ] **Step 3 (agent): Verify the runner is online and locked down.** Run the runbook's section 5 command and expect `puma` `online`. Also confirm the approval policy reads `all_external_contributors`.
- [ ] **Step 4 (agent): Non-master dispatch is refused.** Run `gh workflow run beta-selfhosted.yml -R javierbq/RayMol --ref ci/selfhosted-beta-pipeline -f validate_only=true`, then `gh run watch`. Expect the job to be refused by the runner's job guard (`selfhosted_runner_job_guard: refused — ref is not refs/heads/master` in "Set up job"), with `beta` skipped and nothing archived. (If the branch was deleted on merge, push any throwaway branch from master and dispatch on it. Delete it afterwards.)
- [ ] **Step 5 (agent): Validate-only dispatch.** Run `gh workflow run beta-selfhosted.yml -R javierbq/RayMol --ref master -f validate_only=true` and watch it. Expect both legs green, with `altool --validate-app` in each leg's log reporting no errors. On failure, download the `beta-logs-*` artifact (`gh run download -R javierbq/RayMol <run-id>`), fix on a new branch with a PR, and repeat. Likely first-run issues are in the runbook's troubleshooting table.
- [ ] **Step 6 (user): Real upload.** Run `gh workflow run beta-selfhosted.yml -R javierbq/RayMol --ref master -f validate_only=false`. It is a production deploy, so the user runs it with the `!` prefix.
- [ ] **Step 7 (agent): Confirm delivery.** With read-only ASC calls, check that two new builds with the run's build number exist and both reach `processingState=VALID`. Expect them visible to the internal Beta group (`hasAccessToAllBuilds`).
- [ ] **Step 8 (user): Disable Xcode Cloud.** Run `~/.raymol-beta-venv/bin/python scripts/xcode_cloud_beta_workflows.py disable` on any machine with credentials and PyJWT. Expect both lines `isEnabled=False`, exit 0.
- [ ] **Step 9 (user): Enable the nightly.** Run `gh variable set SELFHOSTED_BETA_ENABLED -R javierbq/RayMol --body true`.
- [ ] **Step 10 (agent): Check after the first two nights.** Night 1 should upload, or skip if step 6 already built the same SHA through a dispatch. That is acceptable: the skip check only looks at scheduled runs, so night 1 rebuilds once. Night 2 with no new commits should skip with "already has a nightly beta". Record the outcome in memory (`macos_xcode_cloud_beta.md` / `ios_beta_pipeline_stranded_branch.md`): betas now come from puma, and Xcode Cloud is disabled.
