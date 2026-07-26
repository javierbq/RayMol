# iOS Beta Builds to TestFlight via Xcode Cloud — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a TestFlight build for internal testers automatically whenever `master` changes, replacing the hand-run `archive_appstore.sh iOS` + manual `altool` upload.

**Architecture:** Two pipelines split by how often their inputs change. A rarely-run GitHub Actions job builds the pinned 618 MB `deps_ios` tree and publishes it as a fingerprint-tagged GitHub prerelease asset. Xcode Cloud's `ci_post_clone.sh` fetches that artifact, stamps version/build, regenerates the Xcode project, builds `libpymol_core.a`, and hands off to an Archive action whose post-action distributes to a TestFlight internal group. The split exists because Xcode Cloud has **no arbitrary-directory cache**, so without it every build would re-run the numpy meson cross-build.

**Tech Stack:** Xcode Cloud (`ci_scripts` hooks, zsh/bash, no sudo, HTTP proxy), GitHub Actions (`macos-latest`, arm64), bash, CMake, xcodegen, `gh` CLI, TestFlight internal testing.

**Spec:** `docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md`

## Global Constraints

- **Scope is iOS/iPadOS only.** Never modify `swiftui/make_dmg.sh`, `swiftui/publish_release.sh`, `appcast.xml`, or anything on the macOS Developer-ID/Sparkle/Homebrew-cask path.
- **Repo:** `javierbq/RayMol` (public). `gh` CLI locally defaults to the upstream `schrodinger/pymol-open-source` — always pass `-R javierbq/RayMol` in local commands. Inside GitHub Actions the current repo is implicit.
- **Git flow:** never commit or push to `master`. Work on the current feature branch and open a PR into `master`.
- **Worktree:** all edits go to the worktree path `/Users/jcastellanos/repos/RayMol/.claude/worktrees/icloud-run-nightly-beta-27099f`, never `/Users/jcastellanos/repos/RayMol` (which is checked out to an unrelated branch, `codex/test`).
- **Fingerprint format:** first **12 lowercase hex characters** of a sha256, over exactly these six files in this fixed order: `scripts/setup_ios_deps.sh`, `scripts/fetch_ios_python.sh`, `scripts/build_ios_deps.sh`, `scripts/build_numpy_ios.sh`, `scripts/bundle_biopython.sh`, `scripts/prune_ios_deps.sh`. `prune_ios_deps.sh` is included because it shapes the published artifact's contents — tightening the prune changes what the artifact contains, not just the bring-up behaviour. *(Human-approved amendment to the original plan.)*
- **Artifact naming:** release tag `ios-deps-<fingerprint>`, assets `deps_ios-<fingerprint>.tar.gz` and `deps_ios-<fingerprint>.tar.gz.sha256`. Always a **prerelease** — it must never become `latest`, which would break the macOS updater's `releases/latest/download/appcast.xml` feed.
- **Marketing version is derived from `swiftui/project.yml`, never from git tags.** `git tag | sort -V | tail -1` yields `v3.2.0` (inherited PyMOL line) while RayMol's own releases top out at `v1.8.0`. A tag-based scheme would stamp betas `3.3.0` and permanently burn that version in App Store Connect.
- **Pinned dep versions** (all default literals inside the dep scripts): `PY_APPLE_SUPPORT_TAG=3.13-b12`, `FREETYPE_VERSION=2.13.3`, `LIBPNG_VERSION=1.6.44`, `NUMPY_VERSION=2.4.6`, `BIO_VERSION=1.87`, `IOS_DEPLOYMENT_TARGET=16.0`.
- **Xcode Cloud environment facts:** `ci_scripts` must sit beside the `.xcodeproj` (→ `swiftui/ci_scripts/`), only **one** such directory is recognised per repo, scripts run with `ci_scripts` as cwd, **no `sudo`**, network egress via `$HTTP_PROXY`/`$HTTPS_PROXY`. Homebrew, CocoaPods and Git LFS are preinstalled; **cmake and xcodegen are not**. `CI_PRIMARY_REPOSITORY_PATH=/Volumes/workspace/repository`; `CI_BUILD_NUMBER` is a monotonic integer.
- **Every new script hard-fails rather than defaulting.** A wrong version or a missing dep is unrecoverable in App Store Connect, so stopping beats guessing. Match the existing loud-failure style of `make_dmg.sh`.
- **No new secrets.** The repo is public, so the deps artifact is fetched tokenlessly, and Apple performs all distribution signing.
- **Test convention:** this repo has no bats/shunit2. Shell tests are plain runnable scripts, following `swiftui/tests/run_whats_new_logic_test.sh`. New tests go in `scripts/tests/run_<name>_test.sh`, exit non-zero on failure.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `scripts/ios_deps_fingerprint.sh` | **Create.** Emit the 12-hex fingerprint of the dep bring-up. The single shared source of truth between both pipelines. |
| `scripts/nightly_version.sh` | **Create.** Emit the beta marketing version (`<major>.<minor+1>.0`) from `project.yml`. |
| `scripts/prune_ios_deps.sh` | **Create.** Reduce a populated `deps_ios/` to only what the Xcode build links, asserting nothing required was removed. |
| `scripts/apply_ci_versions.sh` | **Create.** In-place rewrite of `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in a `project.yml`, with verification. |
| `scripts/assert_ios_build_inputs.sh` | **Create.** Pre-`xcodebuild` gate: core library exists and is arm64, every `deps_ios` path the device build needs is present. |
| `scripts/tests/run_*_test.sh` | **Create (5 files).** One runner per script above. |
| `.github/workflows/ios-deps-artifact.yml` | **Create.** Build + prune + package + publish the deps artifact. Thin: all logic lives in the tested scripts. |
| `swiftui/ci_scripts/ci_post_clone.sh` | **Create.** Xcode Cloud orchestration — toolchain, fetch deps, stamp versions, xcodegen, build core, assert. |
| `docs/ios-beta-pipeline.md` | **Create.** Operator runbook: the App Store Connect settings that cannot live in the repo, plus how to bump deps and add testers. |

Logic is deliberately pulled **out** of the YAML and out of `ci_post_clone.sh` into small single-purpose scripts, because neither a GitHub Actions workflow nor an Xcode Cloud hook can be run locally — but each of those scripts can be unit-tested on a laptop in under a second.

---

## Task 1: Xcode Cloud validation spike (throwaway)

The whole design rests on one unverified assumption: that files `ci_post_clone.sh` writes into the repository survive into `xcodebuild`. Apple's docs say scripts' created files are deleted; universal CocoaPods/xcodegen practice says repo mutations persist. **Resolve this before building anything else** — the fallback (Git LFS-committing a 618 MB tree) is materially worse and would change most later tasks.

This spike also harvests the three other unknowns cheaply: proxy/network reachability, whether `brew install cmake glm xcodegen` works, and **how long a full PyMOL core build takes** on Xcode Cloud hardware (the spec's undocumented-timeout risk).

**This task requires a human with App Store Connect access.** A subagent cannot create an Xcode Cloud workflow. The agent's job is to write the two spike scripts and the exact instructions; the human runs the build and reports the log.

**Files:**
- Create: `swiftui/ci_scripts/ci_post_clone.sh` (temporary spike content, replaced in Task 8)
- Create: `swiftui/ci_scripts/ci_pre_xcodebuild.sh` (temporary, deleted in Task 8)

**Interfaces:**
- Consumes: nothing.
- Produces: a recorded answer to "do repo mutations persist?" plus a measured core-build duration. Task 8 depends on the answer being *yes*.

- [ ] **Step 1: Write the spike post-clone script**

Create `swiftui/ci_scripts/ci_post_clone.sh`:

```bash
#!/bin/bash
# TEMPORARY Xcode Cloud validation spike — replaced by the real script in Task 8.
#
# Answers four questions that Apple's documentation leaves open, in one build:
#   1. Do files this script writes into the repository survive to later stages?
#   2. Does network egress work through the mandated $HTTP_PROXY?
#   3. Do `brew install cmake glm xcodegen` succeed with no sudo available?
#   4. How long does a full PyMOL iOS core build take on this hardware?
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "== spike: environment =="
echo "  CI_PRIMARY_REPOSITORY_PATH = $CI_PRIMARY_REPOSITORY_PATH"
echo "  CI_BUILD_NUMBER            = ${CI_BUILD_NUMBER:-<unset>}"
echo "  CI_START_CONDITION         = ${CI_START_CONDITION:-<unset>}"
echo "  HTTPS_PROXY                = ${HTTPS_PROXY:-<unset>}"
echo "  sw_vers                    = $(sw_vers -productVersion)"
echo "  xcodebuild                 = $(xcodebuild -version | head -1)"
echo "  preinstalled cmake?        = $(command -v cmake || echo NO)"
echo "  preinstalled python3       = $(python3 --version 2>&1)"

echo "== spike: Q3 toolchain via Homebrew (no sudo) =="
brew install cmake glm xcodegen
export PYMOL_EXTERNAL_PREFIX="$(brew --prefix)"
echo "  PYMOL_EXTERNAL_PREFIX = $PYMOL_EXTERNAL_PREFIX"
echo "  glm header            = $(ls "$PYMOL_EXTERNAL_PREFIX/include/glm/glm.hpp")"

echo "== spike: Q2 network through the proxy =="
# Any small public asset. A GitHub release download is the exact path the real
# script will use to fetch the deps artifact.
curl -fsSL -o /tmp/spike-probe.txt \
  "https://raw.githubusercontent.com/javierbq/RayMol/master/README.md"
echo "  fetched $(wc -c < /tmp/spike-probe.txt) bytes from raw.githubusercontent.com"

echo "== spike: Q1 write markers into the repository =="
echo "post-clone build ${CI_BUILD_NUMBER:-?}" > SPIKE_MARKER.txt
mkdir -p spike_marker_dir && echo ok > spike_marker_dir/inside.txt
( cd swiftui && xcodegen generate )   # mutates the committed .xcodeproj
echo "  wrote SPIKE_MARKER.txt, spike_marker_dir/, and regenerated the project"

echo "== spike: Q4 time a full core build =="
START=$(date +%s)
bash swiftui/build_ios.sh device
echo "  CORE_BUILD_SECONDS=$(( $(date +%s) - START ))"
ls -la build_ios_device/libpymol_core.a
lipo -archs build_ios_device/libpymol_core.a
```

- [ ] **Step 2: Write the spike pre-xcodebuild assertion**

Create `swiftui/ci_scripts/ci_pre_xcodebuild.sh`:

```bash
#!/bin/bash
# TEMPORARY validation spike — deleted in Task 8.
# Reports (does NOT fail) whether ci_post_clone.sh's repository writes survived.
set -uo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "== spike verdict: did post-clone repository writes persist? =="
for p in SPIKE_MARKER.txt spike_marker_dir/inside.txt build_ios_device/libpymol_core.a; do
  if [ -e "$p" ]; then echo "  PERSISTED: $p"; else echo "  GONE:      $p"; fi
done
echo "-- SPIKE_MARKER.txt contents --"
cat SPIKE_MARKER.txt 2>/dev/null || echo "  (absent)"
echo "== end spike verdict =="
```

Deliberately non-fatal: the point is to read the verdict from the log, not to fail the build.

- [ ] **Step 3: Make both executable and commit**

```bash
chmod +x swiftui/ci_scripts/ci_post_clone.sh swiftui/ci_scripts/ci_pre_xcodebuild.sh
git add swiftui/ci_scripts/
git commit -m "chore(ci): temporary Xcode Cloud validation spike

Probes the four things Apple does not document: whether post-clone
repository writes survive to later stages, proxy egress, Homebrew
toolchain installs without sudo, and full iOS core build duration.
Replaced by the real ci_post_clone.sh once the answers are known."
```

- [ ] **Step 4: Human — create the spike workflow in App Store Connect**

Push the branch, then in Xcode (Product ▸ Xcode Cloud ▸ Create Workflow) or App Store Connect:

1. Product: RayMol (App ID `6781513038`), repository `javierbq/RayMol`.
2. Name: `SPIKE — validation`.
3. Start Condition: **Manual** only (delete any default branch-change condition).
4. Environment: Xcode latest release, macOS latest.
5. Action: **Build** (not Archive — no signing, no upload, cheapest possible).
6. Scheme: `PyMOLViewer_iOS`, Platform: iOS.
7. No post-actions.
8. Branch: this feature branch.

Then start a build manually.

- [ ] **Step 5: Human — read the verdict and record it**

In the build log, find the `spike verdict` block and the `CORE_BUILD_SECONDS=` line. Append the findings to the spec:

```bash
# Fill in the real observed values, then:
git commit -am "docs(spec): record Xcode Cloud validation spike results"
```

Record in `docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md` under
"Risks to validate empirically on the first run": whether each path PERSISTED or
was GONE, the measured `CORE_BUILD_SECONDS`, the resolved `PYMOL_EXTERNAL_PREFIX`,
and whether the `Build` action completed without hitting any timeout.

**Decision gate:**
- All three paths **PERSISTED** → proceed to Task 2 as planned.
- Any path **GONE** → stop. The design needs revision: move the dep fetch and core build into `ci_pre_xcodebuild.sh` and re-run this spike; if they vanish there too, fall back to Git LFS-committing the pruned `deps_ios`. Do not start Tasks 2-8 until this is settled.

- [ ] **Step 6: Human — delete the spike workflow**

Delete the `SPIKE — validation` workflow in App Store Connect so it cannot fire again. The spike *scripts* stay on the branch until Task 8 replaces them.

---

## Task 2: `scripts/ios_deps_fingerprint.sh`

**Files:**
- Create: `scripts/ios_deps_fingerprint.sh`
- Test: `scripts/tests/run_ios_deps_fingerprint_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `bash scripts/ios_deps_fingerprint.sh` → prints 12 lowercase hex chars to stdout, exit 0. Exits 1 with a message on stderr if any of the six input files is missing. Called by Task 7 (workflow) and Task 8 (`ci_post_clone.sh`). *(Human-approved amendment: sixth file `scripts/prune_ios_deps.sh` added.)*

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_ios_deps_fingerprint_test.sh`:

```bash
#!/bin/bash
# Unit tests for scripts/ios_deps_fingerprint.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ios_deps_fingerprint.sh"
FAILED=0

check () {  # $1=label  $2=expected  $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
  else
    echo "  FAIL: $1 — expected '$2', got '$3'"; FAILED=1
  fi
}

INPUTS=(setup_ios_deps.sh fetch_ios_python.sh build_ios_deps.sh
        build_numpy_ios.sh bundle_biopython.sh prune_ios_deps.sh)

# Build a throwaway repo whose scripts/ holds stubs + a copy of the script under
# test. The script derives its root from its own location, so this fully
# isolates the test from the real dep scripts.
make_fixture () {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/scripts"
  for f in "${INPUTS[@]}"; do echo "stub $f" > "$dir/scripts/$f"; done
  cp "$SCRIPT" "$dir/scripts/ios_deps_fingerprint.sh"
  echo "$dir"
}

echo "== ios_deps_fingerprint =="

A="$(make_fixture)"
FP1="$(bash "$A/scripts/ios_deps_fingerprint.sh")"

# 1. format: exactly 12 lowercase hex characters
if [[ "$FP1" =~ ^[0-9a-f]{12}$ ]]; then echo "  ok: 12 lowercase hex chars"
else echo "  FAIL: format — got '$FP1'"; FAILED=1; fi

# 2. deterministic across runs
check "deterministic" "$FP1" "$(bash "$A/scripts/ios_deps_fingerprint.sh")"

# 3. identical inputs in a different temp dir give the same value (path-independent)
B="$(make_fixture)"
check "path-independent" "$FP1" "$(bash "$B/scripts/ios_deps_fingerprint.sh")"

# 4. changing ANY input changes the fingerprint (this is the whole point:
#    a pin bump must invalidate the published artifact)
for f in "${INPUTS[@]}"; do
  C="$(make_fixture)"
  echo "NUMPY_VERSION=99.99.99" >> "$C/scripts/$f"
  GOT="$(bash "$C/scripts/ios_deps_fingerprint.sh")"
  if [ "$GOT" != "$FP1" ]; then echo "  ok: changes when $f changes"
  else echo "  FAIL: fingerprint unchanged after editing $f"; FAILED=1; fi
  rm -rf "$C"
done

# 5. a missing input is a loud failure, not a silent partial hash
D="$(make_fixture)"; rm -f "$D/scripts/build_numpy_ios.sh"
if bash "$D/scripts/ios_deps_fingerprint.sh" >/dev/null 2>&1; then
  echo "  FAIL: succeeded despite a missing input"; FAILED=1
else
  echo "  ok: missing input exits non-zero"
fi

# 6. the real repo checkout produces a valid fingerprint
REAL="$(bash "$SCRIPT")"
if [[ "$REAL" =~ ^[0-9a-f]{12}$ ]]; then echo "  ok: real repo → $REAL"
else echo "  FAIL: real repo gave '$REAL'"; FAILED=1; fi

# 7. ordering is asserted against an independently-computed anchor.
#    Catches a transposition in the script's FILES array: the stubs are
#    filename-unique ("stub setup_ios_deps.sh" etc.), so concatenating them in
#    different orders produces different digests.  The canonical order is spelled
#    out here in the test — independent of the script's internal FILES array —
#    so any drift between the two sources of truth fails immediately.
E="$(make_fixture)"
EXPECTED="$(cat \
  "$E/scripts/setup_ios_deps.sh" \
  "$E/scripts/fetch_ios_python.sh" \
  "$E/scripts/build_ios_deps.sh" \
  "$E/scripts/build_numpy_ios.sh" \
  "$E/scripts/bundle_biopython.sh" \
  "$E/scripts/prune_ios_deps.sh" \
  | shasum -a 256 | cut -c1-12)"
check "fixture matches independently-computed expected order" \
  "$EXPECTED" "$(bash "$E/scripts/ios_deps_fingerprint.sh")"
rm -rf "$E"

rm -rf "$A" "$B" "$D"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
chmod +x scripts/tests/run_ios_deps_fingerprint_test.sh
bash scripts/tests/run_ios_deps_fingerprint_test.sh
```

Expected: FAIL — `cp: .../scripts/ios_deps_fingerprint.sh: No such file or directory`, because the script does not exist yet.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/ios_deps_fingerprint.sh`:

```bash
#!/bin/bash
# ios_deps_fingerprint.sh — emit a stable 12-hex fingerprint of the iOS
# dependency bring-up (deps_ios/).
#
# BOTH pipelines call THIS script, which is what makes the scheme safe:
#   * .github/workflows/ios-deps-artifact.yml publishes  ios-deps-<fingerprint>
#   * swiftui/ci_scripts/ci_post_clone.sh fetches exactly that tag
# so the deps a build links can never silently disagree with the dep scripts in
# that checkout. There is no lockfile to drift.
#
# Six scripts are hashed (in fixed order):
#   fetch_ios_python.sh    PY_APPLE_SUPPORT_TAG  3.13-b12
#   build_ios_deps.sh      FREETYPE_VERSION 2.13.3 / LIBPNG_VERSION 1.6.44
#   build_numpy_ios.sh     NUMPY_VERSION 2.4.6
#   bundle_biopython.sh    BIO_VERSION 1.87
#   setup_ios_deps.sh      (orchestrates the above four)
#   prune_ios_deps.sh      included because it shapes the published artifact's
#                          contents — tightening the prune changes what the
#                          artifact contains, not just the bring-up behaviour
# Bump any pin and the fingerprint changes, invalidating the old artifact. That
# is the intended behaviour, not a side effect.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# FIXED order — the value must never depend on glob or filesystem ordering.
FILES=(
  scripts/setup_ios_deps.sh
  scripts/fetch_ios_python.sh
  scripts/build_ios_deps.sh
  scripts/build_numpy_ios.sh
  scripts/bundle_biopython.sh
  scripts/prune_ios_deps.sh
)

for f in "${FILES[@]}"; do
  [ -f "$ROOT/$f" ] || { echo "ERROR: fingerprint input missing: $f" >&2; exit 1; }
done

# Hash contents only (never paths or mtimes) so the value is reproducible from
# any checkout location, on CI and on a laptop alike.
( cd "$ROOT" && cat "${FILES[@]}" ) | shasum -a 256 | cut -c1-12
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x scripts/ios_deps_fingerprint.sh
bash scripts/tests/run_ios_deps_fingerprint_test.sh
```

Expected: every `ok:` line, ending in `PASS`. Note the printed real-repo fingerprint — Task 7's first artifact will carry it.

- [ ] **Step 5: Commit**

```bash
git add scripts/ios_deps_fingerprint.sh scripts/tests/run_ios_deps_fingerprint_test.sh
git commit -m "feat(ci): fingerprint the iOS dependency bring-up

Shared by both pipelines so the published deps artifact and the dep
scripts in a checkout can never silently mismatch. Hashes the five
script bodies, which covers every pinned version implicitly."
```

---

## Task 3: `scripts/nightly_version.sh`

**Files:**
- Create: `scripts/nightly_version.sh`
- Test: `scripts/tests/run_nightly_version_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `bash scripts/nightly_version.sh [project.yml]` → prints `<major>.<minor+1>.0`, exit 0. Optional first argument overrides the `project.yml` path (this exists purely so the test can use fixtures). Exits 1 if the file is absent or holds no valid `X.Y.Z` `MARKETING_VERSION`. Called by Task 8.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_nightly_version_test.sh`:

```bash
#!/bin/bash
# Unit tests for scripts/nightly_version.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/nightly_version.sh"
FAILED=0
TMP="$(mktemp -d)"

# Write a project.yml fixture containing $1 as the MARKETING_VERSION line body.
# Indented to 8 spaces to match the real file's nesting under settings:.
fixture () {
  local file="$TMP/p$RANDOM.yml"
  {
    echo "settings:"
    echo "  base:"
    echo "        PRODUCT_NAME: RayMol"
    [ -n "$1" ] && echo "        MARKETING_VERSION: $1"
    echo "        CURRENT_PROJECT_VERSION: 23"
  } > "$file"
  echo "$file"
}

expect_ok () {  # $1=label $2=version-literal $3=expected output
  local got; got="$(bash "$SCRIPT" "$(fixture "$2")" 2>/dev/null)"
  if [ "$got" = "$3" ]; then echo "  ok: $1"
  else echo "  FAIL: $1 — expected '$3', got '$got'"; FAILED=1; fi
}

expect_fail () {  # $1=label $2=version-literal (may be empty)
  if bash "$SCRIPT" "$(fixture "$2")" >/dev/null 2>&1; then
    echo "  FAIL: $1 — should have exited non-zero"; FAILED=1
  else echo "  ok: $1"; fi
}

echo "== nightly_version =="

# Core behaviour: bump the MINOR, zero the PATCH.
expect_ok "1.8.0 -> 1.9.0"   '"1.8.0"'  "1.9.0"
expect_ok "1.9.9 -> 1.10.0"  '"1.9.9"'  "1.10.0"
expect_ok "0.1.0 -> 0.2.0"   '"0.1.0"'  "0.2.0"
expect_ok "2.0.3 -> 2.1.0"   '"2.0.3"'  "2.1.0"
# Double-digit minors must not be mangled by string comparison.
expect_ok "1.10.0 -> 1.11.0" '"1.10.0"' "1.11.0"
# Unquoted YAML scalar is still valid YAML and must parse.
expect_ok "unquoted 1.8.0"   '1.8.0'    "1.9.0"

# Hard failures — guessing a version is unrecoverable in App Store Connect.
expect_fail "missing MARKETING_VERSION" ""
expect_fail "two-component version"     '"1.8"'
expect_fail "non-numeric version"       '"1.8.0-beta"'
expect_fail "empty version"             '""'

# A missing file is a failure, not an empty result.
if bash "$SCRIPT" "$TMP/does-not-exist.yml" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILED=1
else echo "  ok: missing file exits non-zero"; fi

# Against the real repo (project.yml is at 1.8.0 today) the answer is 1.9.0,
# and with no argument it must default to swiftui/project.yml.
REAL="$(bash "$SCRIPT" 2>/dev/null)"
if [ "$REAL" = "1.9.0" ]; then echo "  ok: real repo → 1.9.0"
else echo "  FAIL: real repo → '$REAL' (expected 1.9.0; did project.yml move on?)"; FAILED=1; fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
chmod +x scripts/tests/run_nightly_version_test.sh
bash scripts/tests/run_nightly_version_test.sh
```

Expected: FAIL on every case — `bash: .../scripts/nightly_version.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/nightly_version.sh`:

```bash
#!/bin/bash
# nightly_version.sh — emit the marketing version for automated beta
# (TestFlight) builds: the next MINOR after whatever swiftui/project.yml
# currently declares.
#     project.yml MARKETING_VERSION 1.8.0  ->  1.9.0
#
# DO NOT derive this from git tags. This repo carries the inherited PyMOL
# version line, so `git tag | sort -V | tail -1` yields v3.2.0 while RayMol's
# own releases top out at v1.8.0. A tag-based scheme would stamp betas 3.3.0 and
# permanently burn that version in App Store Connect — versions cannot be
# deleted there.
#
# The line advances by itself: publish_release.sh already asserts the packaged
# version matches project.yml, so cutting 1.9.0 sets that field to 1.9.0 and
# betas move to 1.10.0.
#
# COROLLARY / CONVENTION: bump MARKETING_VERSION *to* the release version when
# cutting a release, never in advance — pre-bumping makes betas leapfrog the
# version actually being prepared.
#
# Usage: nightly_version.sh [path/to/project.yml]
# The optional argument exists for unit tests; production callers pass nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="${1:-$ROOT/swiftui/project.yml}"

[ -f "$PROJECT_YML" ] || { echo "ERROR: project.yml not found: $PROJECT_YML" >&2; exit 1; }

# Accept quoted or bare scalars, but require a strict three-component numeric
# version — anything else means the file changed shape and we must not guess.
CUR="$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([0-9]+\.[0-9]+\.[0-9]+)"?[[:space:]]*$/\1/p' \
        "$PROJECT_YML" | head -1)"

[ -n "$CUR" ] || {
  echo "ERROR: no valid MARKETING_VERSION (X.Y.Z) in $PROJECT_YML" >&2
  echo "       Refusing to guess — a wrong marketing version cannot be undone" >&2
  echo "       in App Store Connect." >&2
  exit 1; }

MAJOR="${CUR%%.*}"
REST="${CUR#*.}"
MINOR="${REST%%.*}"

# $(( )) forces integer arithmetic, so 1.9.x -> 1.10.0 rather than a string bug.
echo "${MAJOR}.$((MINOR + 1)).0"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x scripts/nightly_version.sh
bash scripts/tests/run_nightly_version_test.sh
```

Expected: all `ok:` lines then `PASS`, including `real repo → 1.9.0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/nightly_version.sh scripts/tests/run_nightly_version_test.sh
git commit -m "feat(ci): derive the beta marketing version from project.yml

Emits <major>.<minor+1>.0, deliberately NOT from git tags: the repo
carries the inherited PyMOL version line, so the newest tag by version
sort is v3.2.0 while RayMol's releases top out at v1.8.0. A tag-based
scheme would stamp betas 3.3.0 and burn that version in App Store
Connect permanently. Hard-fails rather than defaulting."
```

---

## Task 4: `scripts/prune_ios_deps.sh`

Reduces a fully-populated `deps_ios/` (618 MB locally) to only what the Xcode build links, then **asserts nothing required was removed**. Pruning too much is worse than not pruning at all: the failure would surface as an opaque linker error minutes into an Xcode Cloud archive.

**Files:**
- Create: `scripts/prune_ios_deps.sh`
- Test: `scripts/tests/run_prune_ios_deps_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `bash scripts/prune_ios_deps.sh <deps_ios-dir>` → removes intermediates, exit 0 on success. Exits 1 if the directory is missing or if any required path is absent afterwards. Called by Task 7.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_prune_ios_deps_test.sh`:

```bash
#!/bin/bash
# Unit tests for scripts/prune_ios_deps.sh, using a fixture deps_ios tree of
# empty files — the script only makes structural decisions, never reads content.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/prune_ios_deps.sh"
FAILED=0

SLICES=(ios-arm64 ios-arm64_x86_64-simulator)

# A complete, valid deps_ios as setup_ios_deps.sh leaves it: shipping paths
# plus the intermediates we expect to be pruned away.
make_fixture () {
  local d; d="$(mktemp -d)/deps_ios"; mkdir -p "$d"
  for s in "${SLICES[@]}"; do
    mkdir -p "$d/Python.xcframework/$s/Python.framework/Headers"
    : > "$d/Python.xcframework/$s/Python.framework/Python"
    mkdir -p "$d/Python.xcframework/$s/lib/python3.13/site-packages/Bio"
  done
  for p in install install_device; do
    mkdir -p "$d/$p/lib" "$d/$p/include"
    : > "$d/$p/lib/libpng16.a"; : > "$d/$p/lib/libfreetype.a"
  done
  mkdir -p "$d/numpy-ios/simulator/numpy" "$d/numpy-ios/device/numpy"
  # Intermediates that must be pruned.
  mkdir -p "$d/build_freetype" "$d/build_freetype_device" \
           "$d/build_libpng" "$d/build_libpng_device" "$d/build_python_ios" \
           "$d/freetype-2.13.3" "$d/libpng-1.6.44"
  : > "$d/freetype.tar.xz"; : > "$d/libpng.tar.xz"
  echo "$d"
}

echo "== prune_ios_deps =="

D="$(make_fixture)"
if ! bash "$SCRIPT" "$D" >/dev/null 2>&1; then
  echo "  FAIL: pruning a complete tree should succeed"; FAILED=1
else
  echo "  ok: complete tree prunes cleanly"
fi

# Intermediates gone.
for junk in build_freetype build_freetype_device build_libpng build_libpng_device \
            build_python_ios freetype-2.13.3 libpng-1.6.44 \
            freetype.tar.xz libpng.tar.xz; do
  if [ -e "$D/$junk" ]; then echo "  FAIL: intermediate survived: $junk"; FAILED=1
  else echo "  ok: pruned $junk"; fi
done

# Shipping paths intact.
for keep in \
  "Python.xcframework/ios-arm64/Python.framework/Python" \
  "Python.xcframework/ios-arm64/Python.framework/Headers" \
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python" \
  "install/lib/libpng16.a" "install/lib/libfreetype.a" \
  "install_device/lib/libpng16.a" "install_device/lib/libfreetype.a" \
  "numpy-ios/simulator/numpy" "numpy-ios/device/numpy"; do
  if [ -e "$D/$keep" ]; then echo "  ok: kept $keep"
  else echo "  FAIL: pruning destroyed $keep"; FAILED=1; fi
done

# Every required path is individually load-bearing: removing any one of them
# before pruning must make the script fail rather than publish a broken artifact.
for req in \
  "Python.xcframework/ios-arm64/Python.framework/Python" \
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "install_device/lib/libfreetype.a" \
  "numpy-ios/device/numpy"; do
  E="$(make_fixture)"; rm -rf "$E/$req"
  if bash "$SCRIPT" "$E" >/dev/null 2>&1; then
    echo "  FAIL: succeeded with $req missing"; FAILED=1
  else echo "  ok: fails when $req is missing"; fi
  rm -rf "$(dirname "$E")"
done

# A non-directory argument is a loud failure.
if bash "$SCRIPT" "/nonexistent/deps_ios" >/dev/null 2>&1; then
  echo "  FAIL: missing directory should exit non-zero"; FAILED=1
else echo "  ok: missing directory exits non-zero"; fi

# Missing argument entirely.
if bash "$SCRIPT" >/dev/null 2>&1; then
  echo "  FAIL: no argument should exit non-zero"; FAILED=1
else echo "  ok: no argument exits non-zero"; fi

rm -rf "$(dirname "$D")"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
chmod +x scripts/tests/run_prune_ios_deps_test.sh
bash scripts/tests/run_prune_ios_deps_test.sh
```

Expected: FAIL — the script does not exist, so the "complete tree prunes cleanly" case fails and the negative cases pass vacuously.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/prune_ios_deps.sh`:

```bash
#!/bin/bash
# prune_ios_deps.sh — reduce a populated deps_ios/ to ONLY what the Xcode build
# links, so the published artifact stays as small as possible to download on
# every Xcode Cloud build.
#
# What the build actually reads:
#   swiftui/PyMOLBridge.xcconfig — the linked libraries and Python headers:
#     Python.xcframework/<slice>/Python.framework/{Python,Headers}
#     install/lib/{libpng16.a,libfreetype.a}             simulator (platform 7)
#     install_device/lib/{libpng16.a,libfreetype.a}      device    (platform 2)
#   swiftui/project.yml (iOS build phases) — the bundled stdlib and packages:
#     Python.xcframework/<slice>/lib/python3.13          (stdlib + staged Bio)
#     numpy-ios/{simulator,device}/numpy
# Everything else is intermediate: CMake build trees, extracted freetype/libpng
# sources, and the downloaded tarballs.
#
# The REQUIRED assertion below matters more than the deletions: pruning too much
# is worse than not pruning, because a missing dep surfaces as an opaque linker
# error minutes into an Xcode Cloud archive rather than here.
set -euo pipefail

DEPS="${1:?usage: prune_ios_deps.sh <deps_ios dir>}"
[ -d "$DEPS" ] || { echo "ERROR: not a directory: $DEPS" >&2; exit 1; }

BEFORE="$(du -sh "$DEPS" | cut -f1)"

# --- drop intermediates -------------------------------------------------------
rm -rf "$DEPS"/build_freetype* "$DEPS"/build_libpng* "$DEPS"/build_python_ios
rm -rf "$DEPS"/freetype-* "$DEPS"/libpng-*
rm -f  "$DEPS"/*.tar.xz "$DEPS"/*.tar.gz

# --- assert the shipping set survived ----------------------------------------
REQUIRED=(
  "Python.xcframework/ios-arm64/Python.framework/Python"
  "Python.xcframework/ios-arm64/Python.framework/Headers"
  "Python.xcframework/ios-arm64/lib/python3.13"
  "Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python"
  "Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  "Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13"
  "Python.xcframework/ios-arm64_x86_64-simulator/lib/python3.13/site-packages/Bio"
  "install/lib/libpng16.a"
  "install/lib/libfreetype.a"
  "install_device/lib/libpng16.a"
  "install_device/lib/libfreetype.a"
  "numpy-ios/simulator/numpy"
  "numpy-ios/device/numpy"
)

MISSING=0
for r in "${REQUIRED[@]}"; do
  [ -e "$DEPS/$r" ] || { echo "MISSING: $r" >&2; MISSING=1; }
done
[ "$MISSING" = 0 ] || {
  echo "ERROR: deps_ios is incomplete after pruning (see MISSING above)." >&2
  echo "       Either setup_ios_deps.sh did not finish, or this script's" >&2
  echo "       delete patterns are too broad. Do NOT publish this tree." >&2
  exit 1; }

echo "pruned OK: $BEFORE -> $(du -sh "$DEPS" | cut -f1)"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x scripts/prune_ios_deps.sh
bash scripts/tests/run_prune_ios_deps_test.sh
```

Expected: all `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/prune_ios_deps.sh scripts/tests/run_prune_ios_deps_test.sh
git commit -m "feat(ci): prune deps_ios to the shipping set before publishing

Drops CMake build trees, extracted sources and tarballs, then asserts
every path PyMOLBridge.xcconfig links and project.yml's iOS build phases bundle is still present. The assertion is
the point: an over-broad prune would otherwise surface as an opaque
linker error inside Xcode Cloud."
```

---

## Task 5: `scripts/apply_ci_versions.sh`

**Files:**
- Create: `scripts/apply_ci_versions.sh`
- Test: `scripts/tests/run_apply_ci_versions_test.sh`

**Interfaces:**
- Consumes: a marketing version string from Task 3 (`nightly_version.sh`).
- Produces: `bash scripts/apply_ci_versions.sh <project.yml> <marketing-version> <build-number>` → rewrites both fields in place, exit 0. Exits 1 on a missing file, a marketing version that is not `X.Y.Z`, a non-integer build number, or an edit that did not apply. Called by Task 8.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_apply_ci_versions_test.sh`:

```bash
#!/bin/bash
# Unit tests for scripts/apply_ci_versions.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/apply_ci_versions.sh"
FAILED=0
TMP="$(mktemp -d)"

# Mirror the real project.yml's shape: 8-space indent under settings: base:.
fixture () {
  local f="$TMP/p$RANDOM.yml"
  {
    echo "settings:"
    echo "  base:"
    echo "        PRODUCT_NAME: RayMol"
    echo "        MARKETING_VERSION: \"1.8.0\""
    echo "        CURRENT_PROJECT_VERSION: 23"
    echo "        GENERATE_INFOPLIST_FILE: YES"
  } > "$f"
  echo "$f"
}

echo "== apply_ci_versions =="

F="$(fixture)"
if bash "$SCRIPT" "$F" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  ok: valid input succeeds"
else
  echo "  FAIL: valid input should succeed"; FAILED=1
fi

if grep -qE '^        MARKETING_VERSION: "1\.9\.0"$' "$F"; then
  echo "  ok: MARKETING_VERSION rewritten"
else echo "  FAIL: MARKETING_VERSION not rewritten"; FAILED=1; fi

if grep -qE '^        CURRENT_PROJECT_VERSION: 47$' "$F"; then
  echo "  ok: CURRENT_PROJECT_VERSION rewritten"
else echo "  FAIL: CURRENT_PROJECT_VERSION not rewritten"; FAILED=1; fi

# Indentation must be preserved — xcodegen would reject a re-indented file.
if grep -qE '^        PRODUCT_NAME: RayMol$' "$F"; then
  echo "  ok: surrounding lines and indentation untouched"
else echo "  FAIL: clobbered surrounding lines"; FAILED=1; fi

# Exactly one of each key (no duplicate lines appended).
[ "$(grep -c 'MARKETING_VERSION:' "$F")" = 1 ] \
  && echo "  ok: single MARKETING_VERSION line" \
  || { echo "  FAIL: duplicate MARKETING_VERSION lines"; FAILED=1; }

# Idempotent: re-applying the same values is a no-op success.
if bash "$SCRIPT" "$F" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  ok: idempotent"
else echo "  FAIL: second identical application failed"; FAILED=1; fi

# Validation. A bad version must never reach App Store Connect.
for bad in "1.9" "1.9.0-beta" "v1.9.0" "" "1.9.0.1"; do
  if bash "$SCRIPT" "$(fixture)" "$bad" "47" >/dev/null 2>&1; then
    echo "  FAIL: accepted bad marketing version '$bad'"; FAILED=1
  else echo "  ok: rejects marketing version '$bad'"; fi
done

for bad in "abc" "4.7" "-1" ""; do
  if bash "$SCRIPT" "$(fixture)" "1.9.0" "$bad" >/dev/null 2>&1; then
    echo "  FAIL: accepted bad build number '$bad'"; FAILED=1
  else echo "  ok: rejects build number '$bad'"; fi
done

if bash "$SCRIPT" "$TMP/absent.yml" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: missing file should exit non-zero"; FAILED=1
else echo "  ok: missing file exits non-zero"; fi

# A project.yml with no such keys must FAIL, not silently succeed — that would
# ship a duplicate (version, build) pair and the upload would be rejected.
NOKEYS="$TMP/nokeys.yml"; printf 'settings:\n  base:\n        PRODUCT_NAME: RayMol\n' > "$NOKEYS"
if bash "$SCRIPT" "$NOKEYS" "1.9.0" "47" >/dev/null 2>&1; then
  echo "  FAIL: succeeded on a project.yml with neither key"; FAILED=1
else echo "  ok: fails when the keys are absent"; fi

rm -rf "$TMP"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
chmod +x scripts/tests/run_apply_ci_versions_test.sh
bash scripts/tests/run_apply_ci_versions_test.sh
```

Expected: FAIL — script missing, so all positive assertions fail.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/apply_ci_versions.sh`:

```bash
#!/bin/bash
# apply_ci_versions.sh — rewrite MARKETING_VERSION and CURRENT_PROJECT_VERSION
# in a project.yml, in place.
#
# Used ONLY inside an ephemeral CI checkout. The committed project.yml keeps its
# release values; this edit exists purely so `xcodegen generate` picks up the
# beta version and Xcode Cloud's CI_BUILD_NUMBER. It is never committed.
#
# Why this must not silently no-op: App Store Connect requires the
# (CFBundleShortVersionString, CFBundleVersion) pair to be UNIQUE. If the edit
# fails to apply, every build after the first uploads a duplicate pair and is
# rejected — so the substitution is verified below and a no-op is fatal.
#
# Usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number>
set -euo pipefail

YML="${1:?usage: apply_ci_versions.sh <project.yml> <marketing-version> <build-number>}"
MKT="${2:-}"
BUILD="${3:-}"

[ -f "$YML" ] || { echo "ERROR: not found: $YML" >&2; exit 1; }
[[ "$MKT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: marketing version must be X.Y.Z, got '$MKT'" >&2; exit 1; }
# Xcode Cloud build numbers are always integers; Apple rejects hashes and
# timestamps outright.
[[ "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "ERROR: build number must be a non-negative integer, got '$BUILD'" >&2; exit 1; }

# Both keys must already exist — we rewrite, never append, so we cannot create a
# duplicate key or land one at the wrong nesting level.
grep -qE '^[[:space:]]*MARKETING_VERSION:' "$YML" || {
  echo "ERROR: no MARKETING_VERSION line in $YML" >&2; exit 1; }
grep -qE '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$YML" || {
  echo "ERROR: no CURRENT_PROJECT_VERSION line in $YML" >&2; exit 1; }

# \1 preserves the original indentation; xcodegen would reject a re-indented file.
/usr/bin/sed -i '' -E \
  -e "s/^([[:space:]]*)MARKETING_VERSION:.*/\1MARKETING_VERSION: \"$MKT\"/" \
  -e "s/^([[:space:]]*)CURRENT_PROJECT_VERSION:.*/\1CURRENT_PROJECT_VERSION: $BUILD/" \
  "$YML"

# Verify — a silent no-op here ships the wrong version.
grep -qE "^[[:space:]]*MARKETING_VERSION: \"$MKT\"$" "$YML" || {
  echo "ERROR: MARKETING_VERSION edit did not apply to $YML" >&2; exit 1; }
grep -qE "^[[:space:]]*CURRENT_PROJECT_VERSION: $BUILD$" "$YML" || {
  echo "ERROR: CURRENT_PROJECT_VERSION edit did not apply to $YML" >&2; exit 1; }

echo "project.yml -> $MKT ($BUILD)"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x scripts/apply_ci_versions.sh
bash scripts/tests/run_apply_ci_versions_test.sh
```

Expected: all `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/apply_ci_versions.sh scripts/tests/run_apply_ci_versions_test.sh
git commit -m "feat(ci): stamp beta version and build number into project.yml

In-place, ephemeral-checkout-only rewrite consumed by xcodegen. Requires
both keys to pre-exist and verifies the substitution landed: a silent
no-op would upload a duplicate (version, build) pair, which App Store
Connect rejects."
```

---

## Task 6: `scripts/assert_ios_build_inputs.sh`

The last gate before `xcodebuild` starts. Without it, a missing dependency surfaces as an opaque linker error minutes into an archive; with it, the failure names the exact missing path immediately.

**Files:**
- Create: `scripts/assert_ios_build_inputs.sh`
- Test: `scripts/tests/run_assert_ios_build_inputs_test.sh`

**Interfaces:**
- Consumes: a populated `deps_ios/` (Task 7's artifact) and `build_ios_device/libpymol_core.a` (produced by `swiftui/build_ios.sh device`).
- Produces: `bash scripts/assert_ios_build_inputs.sh [repo-root]` → exit 0 when every device-build input is present and the core library is arm64; exit 1 listing **all** problems otherwise. Called by Task 8.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/run_assert_ios_build_inputs_test.sh`:

```bash
#!/bin/bash
# Unit tests for scripts/assert_ios_build_inputs.sh.
#
# The arch check is exercised with a REAL arm64 static library built by clang,
# not a stub, because `lipo -archs` is what the script actually calls.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/assert_ios_build_inputs.sh"
FAILED=0

# Build a static library for $1 (e.g. arm64, x86_64) at $2.
make_lib () {
  local arch="$1" out="$2" tmp
  tmp="$(mktemp -d)"
  echo 'int raymol_probe(void){return 0;}' > "$tmp/p.c"
  clang -c -arch "$arch" "$tmp/p.c" -o "$tmp/p.o" 2>/dev/null
  mkdir -p "$(dirname "$out")"
  ar rcs "$out" "$tmp/p.o" 2>/dev/null
  rm -rf "$tmp"
}

# A fake repo root with everything the DEVICE build needs.
make_fixture () {
  local r; r="$(mktemp -d)"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers"
  : >     "$r/deps_ios/Python.xcframework/ios-arm64/Python.framework/Python"
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  mkdir -p "$r/deps_ios/install_device/lib"
  : >     "$r/deps_ios/install_device/lib/libpng16.a"
  : >     "$r/deps_ios/install_device/lib/libfreetype.a"
  mkdir -p "$r/deps_ios/numpy-ios/device/numpy"
  # Simulator headers are required even for the device build: appkit/CMakeLists.txt
  # unconditionally points its Python header search at this simulator slice.
  mkdir -p "$r/deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
  make_lib arm64 "$r/build_ios_device/libpymol_core.a"
  echo "$r"
}

echo "== assert_ios_build_inputs =="

R="$(make_fixture)"
if bash "$SCRIPT" "$R" >/dev/null 2>&1; then
  echo "  ok: complete tree passes"
else
  echo "  FAIL: complete tree should pass"; bash "$SCRIPT" "$R"; FAILED=1
fi

# Each dep path is individually load-bearing.
for req in \
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Python" \
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers" \
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio" \
  "deps_ios/install_device/lib/libpng16.a" \
  "deps_ios/install_device/lib/libfreetype.a" \
  "deps_ios/numpy-ios/device/numpy" \
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"; do
  F="$(make_fixture)"; rm -rf "$F/$req"
  if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
    echo "  FAIL: passed with $req missing"; FAILED=1
  else echo "  ok: fails when $req is missing"; fi
  rm -rf "$F"
done

# Missing core library.
F="$(make_fixture)"; rm -f "$F/build_ios_device/libpymol_core.a"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  echo "  FAIL: passed with no libpymol_core.a"; FAILED=1
else echo "  ok: fails when libpymol_core.a is absent"; fi
rm -rf "$F"

# Wrong architecture — a simulator core would link but never run on a device.
F="$(make_fixture)"; rm -f "$F/build_ios_device/libpymol_core.a"
make_lib x86_64 "$F/build_ios_device/libpymol_core.a"
if bash "$SCRIPT" "$F" >/dev/null 2>&1; then
  echo "  FAIL: accepted an x86_64 core library"; FAILED=1
else echo "  ok: rejects a non-arm64 core library"; fi
rm -rf "$F"

# Diagnostics: report EVERY problem at once, not just the first.
F="$(make_fixture)"
rm -rf "$F/deps_ios/numpy-ios/device/numpy" "$F/deps_ios/install_device/lib/libpng16.a"
OUT="$(bash "$SCRIPT" "$F" 2>&1)"
if grep -q "numpy-ios/device/numpy" <<<"$OUT" && grep -q "libpng16.a" <<<"$OUT"; then
  echo "  ok: lists all missing paths"
else echo "  FAIL: did not list all missing paths; got: $OUT"; FAILED=1; fi
rm -rf "$F"

rm -rf "$R"
[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
chmod +x scripts/tests/run_assert_ios_build_inputs_test.sh
bash scripts/tests/run_assert_ios_build_inputs_test.sh
```

Expected: FAIL — "complete tree should pass" fails because the script does not exist.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/assert_ios_build_inputs.sh`:

```bash
#!/bin/bash
# assert_ios_build_inputs.sh — fail LOUDLY, before xcodebuild starts, if
# anything the iOS DEVICE build links is missing or the wrong architecture.
#
# Without this, a missing dependency surfaces as an opaque linker error minutes
# into an Xcode Cloud archive. Paths below come from two sources:
#   swiftui/PyMOLBridge.xcconfig — the linked libraries and Python headers for
#     the device slice (Python.framework/Python, Python.framework/Headers,
#     install_device/lib/libpng16.a, install_device/lib/libfreetype.a)
#   swiftui/project.yml (iOS build phases) — the bundled stdlib, Biopython
#     and numpy paths (lib/python3.13, site-packages/Bio, numpy-ios/device/)
#
# Usage: assert_ios_build_inputs.sh [repo-root]     (defaults to this repo)
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
CORE="$ROOT/build_ios_device/libpymol_core.a"

PROBLEMS=0

if [ ! -f "$CORE" ]; then
  echo "MISSING: build_ios_device/libpymol_core.a (did swiftui/build_ios.sh device run?)" >&2
  PROBLEMS=1
else
  ARCHS="$(lipo -archs "$CORE" 2>/dev/null || echo "<unreadable>")"
  # Exactly arm64. A simulator build links fine and then cannot run on a device.
  if [ "$ARCHS" != "arm64" ]; then
    echo "WRONG ARCH: libpymol_core.a archs = '$ARCHS', expected 'arm64'" >&2
    echo "            (a simulator core here would produce an unrunnable app)" >&2
    PROBLEMS=1
  fi
fi

REQUIRED=(
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Python"
  "deps_ios/Python.xcframework/ios-arm64/Python.framework/Headers"
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13"
  "deps_ios/Python.xcframework/ios-arm64/lib/python3.13/site-packages/Bio"
  "deps_ios/install_device/lib/libpng16.a"
  "deps_ios/install_device/lib/libfreetype.a"
  "deps_ios/numpy-ios/device/numpy"
  # Required despite being a simulator path: appkit/CMakeLists.txt line 90
  # unconditionally points the Python header search path at the simulator slice
  # for ALL iOS core builds, including the device build done here. Without these
  # headers the compiler silently falls back to Homebrew's python@3.13 headers,
  # compiling the core against the wrong Python ABI. Do not remove this entry
  # to "clean up" the apparent inconsistency — it is load-bearing.
  # (Human-approved amendment — Finding 3 from the Task 7 review.)
  "deps_ios/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Headers"
)

# Report EVERY problem in one pass — fixing these one build at a time is slow.
for r in "${REQUIRED[@]}"; do
  [ -e "$ROOT/$r" ] || { echo "MISSING: $r" >&2; PROBLEMS=1; }
done

[ "$PROBLEMS" = 0 ] || {
  echo "ERROR: iOS device build inputs are incomplete (see above)." >&2
  echo "       deps_ios comes from the 'iOS deps artifact' workflow;" >&2
  echo "       libpymol_core.a comes from swiftui/build_ios.sh device." >&2
  exit 1; }

echo "iOS build inputs OK (core arm64 + deps_ios device slice complete)"
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
chmod +x scripts/assert_ios_build_inputs.sh
bash scripts/tests/run_assert_ios_build_inputs_test.sh
```

Expected: all `ok:` lines then `PASS`.

- [ ] **Step 5: Commit**

```bash
git add scripts/assert_ios_build_inputs.sh scripts/tests/run_assert_ios_build_inputs_test.sh
git commit -m "feat(ci): gate xcodebuild on complete, correct iOS build inputs

Asserts libpymol_core.a exists and is arm64 (a simulator core links but
produces an unrunnable app) and that every deps_ios path the device
slice of PyMOLBridge.xcconfig references is present. Reports all
problems at once rather than one per build."
```

---

## Task 7: `.github/workflows/ios-deps-artifact.yml`

Builds `deps_ios` once per pin change and publishes it as a fingerprint-tagged prerelease. Thin by design — every decision lives in the scripts tested in Tasks 2, 4.

**Files:**
- Create: `.github/workflows/ios-deps-artifact.yml`

**Interfaces:**
- Consumes: `scripts/ios_deps_fingerprint.sh` (Task 2), `scripts/prune_ios_deps.sh` (Task 4), and the existing `scripts/setup_ios_deps.sh`.
- Produces: a GitHub prerelease tagged `ios-deps-<fingerprint>` carrying `deps_ios-<fingerprint>.tar.gz` and `.tar.gz.sha256`. Task 8 fetches exactly these names.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ios-deps-artifact.yml`:

```yaml
name: iOS deps artifact

# Builds the pinned iOS dependency tree (deps_ios/) and publishes it as a
# fingerprinted GitHub prerelease asset, so Xcode Cloud can fetch it in a couple
# of minutes instead of re-running the numpy meson cross-build on every build.
#
# This workflow exists because Xcode Cloud has NO arbitrary-directory cache:
# without a prebuilt artifact, every single build would repeat a ~30 minute
# bring-up (a ~500 MB Python.xcframework download, freetype/libpng cross-builds
# for two slices, numpy via meson twice, Biopython staging).
#
# The tag is ios-deps-<fingerprint> from scripts/ios_deps_fingerprint.sh — the
# SAME script swiftui/ci_scripts/ci_post_clone.sh calls — so the artifact a
# build fetches always matches the dep scripts in that checkout.
#
# PRERELEASE on purpose: it must never become "latest", which would break the
# macOS updater's releases/latest/download/appcast.xml feed.
#
# Re-running is safe: an already-published fingerprint short-circuits.

on:
  push:
    branches: [master]
    paths:
      - scripts/setup_ios_deps.sh
      - scripts/fetch_ios_python.sh
      - scripts/build_ios_deps.sh
      - scripts/build_numpy_ios.sh
      - scripts/bundle_biopython.sh
      - scripts/ios_deps_fingerprint.sh
      - scripts/prune_ios_deps.sh
  workflow_dispatch: {}

permissions:
  contents: write   # gh release create

jobs:
  build-deps:
    runs-on: macos-latest   # Apple Silicon (arm64)
    steps:
      - uses: actions/checkout@v4

      - name: Compute deps fingerprint
        id: fp
        run: echo "fp=$(bash scripts/ios_deps_fingerprint.sh)" >> "$GITHUB_OUTPUT"

      # Skip the ~30 minute bring-up when this exact fingerprint is already
      # published, so re-runs and unrelated pushes are nearly free.
      - name: Check whether this fingerprint is already published
        id: check
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          if gh release view "ios-deps-${{ steps.fp.outputs.fp }}" >/dev/null 2>&1; then
            echo "exists=true" >> "$GITHUB_OUTPUT"
            echo "ios-deps-${{ steps.fp.outputs.fp }} already published — nothing to do."
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Install C build dependencies
        if: steps.check.outputs.exists == 'false'
        run: brew install cmake glm

      - name: Set up host Python 3.13
        id: py
        if: steps.check.outputs.exists == 'false'
        uses: actions/setup-python@v5
        with:
          python-version: "3.13"

      - name: Install cross-build tooling
        if: steps.check.outputs.exists == 'false'
        # lief is required by build_numpy_ios.sh to rewrite numpy's extension
        # modules from MH_BUNDLE to MH_DYLIB; without it App Store validation
        # rejects the upload (errors 90124/90171).
        run: python -m pip install --upgrade pip meson ninja cython build lief

      - name: Build deps_ios
        if: steps.check.outputs.exists == 'false'
        env:
          # build_numpy_ios.sh defaults PYHOST to Homebrew's python3.13, which
          # does NOT have meson/ninja/cython/lief installed above. Point it at
          # the setup-python interpreter that does.
          PYHOST: ${{ steps.py.outputs.python-path }}
        run: bash scripts/setup_ios_deps.sh

      - name: Prune to the shipping set
        if: steps.check.outputs.exists == 'false'
        run: bash scripts/prune_ios_deps.sh deps_ios

      - name: Package
        if: steps.check.outputs.exists == 'false'
        env:
          FP: ${{ steps.fp.outputs.fp }}
        run: |
          set -euo pipefail
          tar -czf "deps_ios-$FP.tar.gz" deps_ios
          # Written without a path component so `shasum -c` works from any cwd.
          shasum -a 256 "deps_ios-$FP.tar.gz" > "deps_ios-$FP.tar.gz.sha256"
          ls -lh "deps_ios-$FP.tar.gz"
          cat "deps_ios-$FP.tar.gz.sha256"

      - name: Publish prerelease
        if: steps.check.outputs.exists == 'false'
        env:
          GH_TOKEN: ${{ github.token }}
          FP: ${{ steps.fp.outputs.fp }}
        run: |
          set -euo pipefail
          gh release create "ios-deps-$FP" \
            --prerelease \
            --title "iOS deps $FP" \
            --notes "Prebuilt \`deps_ios\` for RayMol iOS builds.

          Fingerprint \`$FP\` covers scripts/{setup_ios_deps,fetch_ios_python,build_ios_deps,build_numpy_ios,bundle_biopython}.sh.
          Fetched by \`swiftui/ci_scripts/ci_post_clone.sh\` on every Xcode Cloud build.

          Pins: Python-Apple-support 3.13-b12, freetype 2.13.3, libpng 1.6.44, numpy 2.4.6, biopython 1.87, iOS deployment target 16.0.

          Prerelease so it never becomes \`latest\` (that would break the macOS Sparkle appcast feed). Do not delete while any branch still fingerprints to $FP." \
            "deps_ios-$FP.tar.gz" \
            "deps_ios-$FP.tar.gz.sha256"
```

- [ ] **Step 2: Validate the YAML parses and the referenced scripts exist**

```bash
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/ios-deps-artifact.yml')); print('steps:', len(d['jobs']['build-deps']['steps']))"
for s in scripts/ios_deps_fingerprint.sh scripts/prune_ios_deps.sh scripts/setup_ios_deps.sh; do test -x "$s" && echo "ok $s" || echo "MISSING/NOT-EXEC $s"; done
```

Expected: `steps: 10` and three `ok` lines. If `yaml` is unavailable, run `python3 -m pip install --user pyyaml` first.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ios-deps-artifact.yml
git commit -m "feat(ci): publish prebuilt deps_ios as a fingerprinted prerelease

Xcode Cloud has no arbitrary-directory cache, so without a prebuilt
artifact every build would repeat the ~30 minute iOS dependency bring-up
including the double numpy meson cross-build. Publishes
ios-deps-<fingerprint>; an already-published fingerprint short-circuits.
Prerelease so it never becomes 'latest' and cannot disturb the macOS
Sparkle appcast feed."
```

- [ ] **Step 4: Human — run the workflow once and confirm the artifact**

The workflow must publish before Task 8's `ci_post_clone.sh` can succeed. Push the branch, then run it manually (the `push` trigger is scoped to `master`, so a feature branch needs `workflow_dispatch`):

```bash
gh workflow run "iOS deps artifact" -R javierbq/RayMol --ref "$(git rev-parse --abbrev-ref HEAD)"
```

Watch it, then verify the assets exist under the expected names:

```bash
gh run watch -R javierbq/RayMol
FP="$(bash scripts/ios_deps_fingerprint.sh)"
gh release view "ios-deps-$FP" -R javierbq/RayMol
```

Expected: a prerelease holding `deps_ios-<FP>.tar.gz` and `deps_ios-<FP>.tar.gz.sha256`. Record the wall-clock duration and the tarball size in the plan — the tarball size sets the per-build download cost in Xcode Cloud.

Sanity-check the artifact round-trips before depending on it:

```bash
FP="$(bash scripts/ios_deps_fingerprint.sh)"   # re-derive: the cd below loses the repo
cd "$(mktemp -d)"
gh release download "ios-deps-$FP" -R javierbq/RayMol
shasum -a 256 -c "deps_ios-$FP.tar.gz.sha256"
tar -tzf "deps_ios-$FP.tar.gz" | head
```

Expected: `OK` from `shasum -c`, and the listing starts with `deps_ios/`.

---

## Task 8: `swiftui/ci_scripts/ci_post_clone.sh`

Replaces the Task 1 spike with the real orchestration. **Blocked on Task 1's decision gate** (repo mutations must persist) and on Task 7 having published an artifact.

**Files:**
- Create/replace: `swiftui/ci_scripts/ci_post_clone.sh`
- Delete: `swiftui/ci_scripts/ci_pre_xcodebuild.sh` (spike leftover)

**Interfaces:**
- Consumes: `scripts/ios_deps_fingerprint.sh` (Task 2), `scripts/nightly_version.sh` (Task 3), `scripts/apply_ci_versions.sh` (Task 5), `scripts/assert_ios_build_inputs.sh` (Task 6), the artifact from Task 7, and the existing `swiftui/build_ios.sh`.
- Produces: a checkout in which `xcodebuild` can archive `PyMOLViewer_iOS` — `deps_ios/` populated, `build_ios_device/libpymol_core.a` built, `swiftui/PyMOLViewer.xcodeproj` regenerated with the beta version and `CI_BUILD_NUMBER`.

- [ ] **Step 1: Replace the spike with the real script**

Overwrite `swiftui/ci_scripts/ci_post_clone.sh`:

```bash
#!/bin/bash
# ci_post_clone.sh — Xcode Cloud post-clone: stage everything xcodebuild needs
# that is not in the repository, then build the C++ core.
#
# Apple's environment, all of which this script depends on:
#   * runs with swiftui/ci_scripts as the working directory, so we cd to the repo
#   * NO sudo is available — Homebrew is preinstalled and needs none
#   * network egress goes through $HTTP_PROXY/$HTTPS_PROXY (curl honours them)
#   * only ONE ci_scripts directory is recognised per repo, and it must sit
#     beside the .xcodeproj — hence swiftui/ci_scripts/
#   * CI_PRIMARY_REPOSITORY_PATH = /Volumes/workspace/repository
#   * CI_BUILD_NUMBER is a monotonic integer assigned by Xcode Cloud
#
# `set -u` deliberately makes this fail fast outside Xcode Cloud, where
# CI_PRIMARY_REPOSITORY_PATH and CI_BUILD_NUMBER are unset.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

REPO="javierbq/RayMol"

echo "== 1/6  Toolchain =="
# Homebrew is preinstalled on Xcode Cloud; cmake, glm and xcodegen are not.
# glm is required even for iOS: appkit/CMakeLists.txt resolves glm/glm.hpp from
# PYMOL_EXTERNAL_PREFIX on the iOS path, NOT from deps_ios.
brew install cmake glm xcodegen
# Read the prefix rather than trusting the /opt/homebrew default.
export PYMOL_EXTERNAL_PREFIX="$(brew --prefix)"
echo "  PYMOL_EXTERNAL_PREFIX=$PYMOL_EXTERNAL_PREFIX"

echo "== 2/6  Fetch prebuilt deps_ios =="
FP="$(bash scripts/ios_deps_fingerprint.sh)"
TARBALL="deps_ios-$FP.tar.gz"
BASE="https://github.com/$REPO/releases/download/ios-deps-$FP"
echo "  fingerprint=$FP"
# Fail loudly when the artifact is absent. NEVER fall back to building deps
# inline, and never accept a different fingerprint: today's core linked against
# yesterday's numpy is exactly the stale-artifact class of bug that make_dmg.sh
# grew its staleness assertions to prevent.
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$BASE/$TARBALL" || {
  echo "ERROR: no published deps artifact for fingerprint $FP." >&2
  echo "       Run the 'iOS deps artifact' GitHub Actions workflow on master," >&2
  echo "       then re-run this build. Refusing to build deps inline." >&2
  exit 1; }
curl -fL --retry 3 --retry-delay 5 -o "$TARBALL.sha256" "$BASE/$TARBALL.sha256"
shasum -a 256 -c "$TARBALL.sha256"
tar -xzf "$TARBALL"
rm -f "$TARBALL" "$TARBALL.sha256"

echo "== 3/6  Stamp marketing version + build number =="
MKT="$(bash scripts/nightly_version.sh)"
bash scripts/apply_ci_versions.sh swiftui/project.yml "$MKT" "$CI_BUILD_NUMBER"

echo "== 4/6  Regenerate the Xcode project =="
# project.yml is the source of truth and the committed .pbxproj can lag it —
# skipping this is how PR #124's app-icon setting was once silently reverted.
# It is also what picks up the version stamp from step 3.
( cd swiftui && xcodegen generate )

echo "== 5/6  Build libpymol_core.a (device) =="
bash swiftui/build_ios.sh device

echo "== 6/6  Assert build inputs before xcodebuild =="
bash scripts/assert_ios_build_inputs.sh "$CI_PRIMARY_REPOSITORY_PATH"

echo "ci_post_clone OK — $MKT ($CI_BUILD_NUMBER), deps fingerprint $FP"
```

- [ ] **Step 2: Delete the spike assertion script**

```bash
git rm swiftui/ci_scripts/ci_pre_xcodebuild.sh
```

Its job is done — Task 1 recorded the persistence answer, and `assert_ios_build_inputs.sh` now covers the real preconditions.

- [ ] **Step 3: Verify it fails cleanly outside Xcode Cloud**

```bash
chmod +x swiftui/ci_scripts/ci_post_clone.sh
bash swiftui/ci_scripts/ci_post_clone.sh; echo "exit=$?"
```

Expected: a non-zero exit referencing an unbound `CI_PRIMARY_REPOSITORY_PATH`. This is correct — the script must never run against a developer's working tree, where it would overwrite `project.yml` and rebuild the core.

- [ ] **Step 4: Verify the helper wiring with a dry run of the pure steps**

The fetch and core build need Xcode Cloud, but the version stamping can be proven locally against a throwaway copy:

```bash
TMP="$(mktemp -d)"; mkdir -p "$TMP/swiftui"
cp swiftui/project.yml "$TMP/swiftui/project.yml"
MKT="$(bash scripts/nightly_version.sh)"
bash scripts/apply_ci_versions.sh "$TMP/swiftui/project.yml" "$MKT" 99
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" "$TMP/swiftui/project.yml"
git diff --quiet -- swiftui/project.yml && echo "ok: real project.yml untouched" || echo "FAIL: real project.yml modified"
rm -rf "$TMP"
```

Expected: `MARKETING_VERSION: "1.9.0"`, `CURRENT_PROJECT_VERSION: 99`, and `ok: real project.yml untouched`.

- [ ] **Step 5: Commit**

```bash
git add swiftui/ci_scripts/ci_post_clone.sh
git commit -m "feat(ci): real Xcode Cloud post-clone for iOS beta builds

Fetches the fingerprinted deps_ios artifact (checksum-verified), stamps
the derived beta version plus CI_BUILD_NUMBER into project.yml,
regenerates the project with xcodegen, builds the device core, and
asserts every build input before xcodebuild starts.

Refuses to build deps inline when the artifact is missing: linking
today's core against a mismatched numpy is the failure mode the
fingerprint exists to prevent. Replaces the validation spike."
```

---

## Task 9: Operator runbook + App Store Connect configuration

The App Store Connect side cannot live in the repo, so it must be documented precisely enough to rebuild from scratch. **Requires a human with App Store Connect access** for the configuration steps.

**Files:**
- Create: `docs/ios-beta-pipeline.md`

**Interfaces:**
- Consumes: everything from Tasks 2-8.
- Produces: a live Xcode Cloud workflow, and a document describing it.

- [ ] **Step 1: Write the runbook**

Create `docs/ios-beta-pipeline.md`:

````markdown
# iOS beta pipeline (Xcode Cloud → TestFlight internal)

Every change to `master` produces a TestFlight build for internal testers.
Design rationale: `docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md`.

macOS is unaffected — it keeps the Developer-ID DMG + Sparkle + Homebrew-cask
path (`swiftui/make_dmg.sh`, `swiftui/publish_release.sh`).

## How it fits together

1. `.github/workflows/ios-deps-artifact.yml` builds `deps_ios` and publishes it
   as prerelease `ios-deps-<fingerprint>`. Runs only when a dep script changes.
2. Xcode Cloud, on each `master` change, runs
   `swiftui/ci_scripts/ci_post_clone.sh`: fetch that artifact, stamp the
   version, `xcodegen`, build `libpymol_core.a`, assert inputs.
3. The Archive action signs (Apple manages the certificates) and the
   TestFlight-internal post-action distributes to the beta group.

## App Store Connect workflow settings

Product RayMol, App ID `6781513038`, repository `javierbq/RayMol`.

| Setting | Value |
| --- | --- |
| Name | `iOS Beta (master)` |
| Start Condition | **Branch Changes** on `master` |
| Files/folders condition | **Exclude** `docs/**` and `*.md` |
| Auto-cancel Builds | **On** |
| Environment | Xcode latest release, macOS latest |
| Action | **Archive**, scheme `PyMOLViewer_iOS`, platform iOS |
| Restrict Editing | **On** (Apple requires it for review-eligible builds) |
| Post-action | TestFlight **internal** testing → group `Beta` |
| Post-action | Email and/or Slack notification on failure |

A files/folders condition is only available for branch, pull-request and tag
changes — not for schedules. That is a deliberate reason this pipeline is
change-triggered rather than time-triggered; Xcode Cloud cannot skip a scheduled
build when nothing changed.

## Testers

Internal testing takes up to 100 testers, each on up to 30 devices, and needs
**no Beta App Review**. A tester must be an App Store Connect user with the
Account Holder, Admin, App Manager, Developer or Marketing role.

Add one: App Store Connect → Users and Access → invite with one of those roles,
then TestFlight → Internal Testing → group `Beta` → add the tester.

Builds remain installable for 90 days, and up to 100 builds can be shared at
once. At a few builds per week this stays well inside both limits; if it ever
approaches them, expire the oldest builds in App Store Connect.

## Versions and build numbers

- **Marketing version** is derived by `scripts/nightly_version.sh` as the next
  minor after `swiftui/project.yml`'s `MARKETING_VERSION` (today `1.8.0` →
  betas are `1.9.0`).
- **Build number** is Xcode Cloud's `CI_BUILD_NUMBER`.
- App Store Connect requires the `(version, build)` pair to be unique. iOS does
  not require build numbers to increase across versions; only macOS does.

**Convention:** when cutting a release, bump `MARKETING_VERSION` **to** the
release version — never in advance. Pre-bumping makes betas leapfrog the version
being prepared.

Never derive the version from git tags: this repo carries the inherited PyMOL
version line, so the newest tag by version sort is `v3.2.0` while RayMol's own
releases top out at `v1.8.0`.

## Bumping a dependency

1. Edit the pin in `scripts/fetch_ios_python.sh`, `scripts/build_ios_deps.sh`,
   `scripts/build_numpy_ios.sh` or `scripts/bundle_biopython.sh`.
2. Merge to `master`. The deps workflow fires automatically, and the changed
   script yields a new fingerprint, so a new artifact is published.
3. The next Xcode Cloud build fetches the new fingerprint automatically.

To rebuild without a pin change: `gh workflow run "iOS deps artifact" -R javierbq/RayMol`.

Keep old `ios-deps-*` prereleases while any branch still fingerprints to them —
deleting one breaks builds of those commits.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no published deps artifact for fingerprint <fp>` | A dep script changed without the deps workflow running. Run it on `master`, then re-run the build. |
| `shasum: WARNING: 1 computed checksum did NOT match` | Truncated download, usually the proxy. Re-run the build. |
| `MISSING: deps_ios/...` from `assert_ios_build_inputs.sh` | The artifact was built from an incomplete tree. Re-run the deps workflow and inspect its `prune_ios_deps.sh` output. |
| `WRONG ARCH: libpymol_core.a archs = 'x86_64'` | `build_ios.sh` ran without `device`. `ci_post_clone.sh` passes it; check for a local edit. |
| Upload rejected as a duplicate build | `apply_ci_versions.sh` did not apply. It verifies its own substitution, so check the log for its `project.yml -> ...` line. |
| Build not triggered by a push | The files/folders condition excluded every changed path (docs-only change). Expected behaviour. |

## Local checks

```bash
bash scripts/tests/run_ios_deps_fingerprint_test.sh
bash scripts/tests/run_nightly_version_test.sh
bash scripts/tests/run_prune_ios_deps_test.sh
bash scripts/tests/run_apply_ci_versions_test.sh
bash scripts/tests/run_assert_ios_build_inputs_test.sh
```
````

- [ ] **Step 2: Commit the runbook**

```bash
git add docs/ios-beta-pipeline.md
git commit -m "docs: operator runbook for the iOS beta pipeline

Records the App Store Connect settings that cannot live in the repo,
the tester/version conventions, how to bump a pinned dependency, and a
troubleshooting table keyed to the actual error strings the scripts emit."
```

- [ ] **Step 3: Human — create the real Xcode Cloud workflow**

Follow the settings table in `docs/ios-beta-pipeline.md` exactly. Point the
workflow at this feature branch initially (not `master`) so the first archive is
proven before it can distribute from `master`.

- [ ] **Step 4: Human — create the TestFlight internal group**

App Store Connect → TestFlight → Internal Testing → new group `Beta`, and add
yourself. Confirm the group is selected in the workflow's post-action.

---

## Task 10: End-to-end verification

Proves the spec's five acceptance criteria against the live pipeline. **Requires a human**; a subagent cannot read App Store Connect or install from TestFlight.

**Files:** none created. Updates the plan and spec with observed results.

**Interfaces:**
- Consumes: Tasks 1-9.
- Produces: a signed-off pipeline, plus measured compute cost.

- [ ] **Step 1: Trigger a build and confirm it archives**

Push a trivial code change (not docs) to the branch the workflow watches. Confirm
in the Xcode Cloud log that `ci_post_clone` printed all six `== n/6 ==` banners
and its final `ci_post_clone OK — <version> (<build>), deps fingerprint <fp>`.

- [ ] **Step 2: Confirm the build reaches TestFlight with the right identity**

App Store Connect → TestFlight. Expect version **1.9.0** and a build number
equal to the run's `CI_BUILD_NUMBER`.

If the build is present but not in the `Beta` group, the internal post-action did
not auto-distribute — Apple's docs conflict on this. Add it manually once to
unblock, then implement the documented fallback: an App Store Connect API call
attaching the build to the group, modelled on the JWT/ES256 pattern in
`.claude/skills/cut-mas-release/scripts/asc_status.py`, added to a new
`swiftui/ci_scripts/ci_post_xcodebuild.sh`. Record which behaviour you observed
in the spec's risk 3.

- [ ] **Step 3: Install on a device**

Accept the TestFlight invitation and install on an iPhone or iPad. Launch it,
load a structure, and confirm the embedded Python layer works — numpy is the
dependency most likely to be subtly broken by the artifact path, so run
something that imports it.

- [ ] **Step 4: Confirm a docs-only change does NOT build**

```bash
echo "" >> docs/ios-beta-pipeline.md
git commit -am "docs: whitespace, verifying the files/folders condition"
git push
```

Expected: no new Xcode Cloud build. If one starts, the files/folders exclusion is
misconfigured — fix it in App Store Connect and note it in the runbook.

- [ ] **Step 5: Confirm a broken build fails without distributing**

On a scratch branch, introduce a deliberate compile error in a Swift file, push,
and confirm the build fails, a notification arrives, and **no** build appears in
TestFlight. Delete the scratch branch afterwards.

- [ ] **Step 6: Record the real compute cost**

App Store Connect → Users and Access → Xcode Cloud shows usage (exportable as
CSV). Record actual minutes per build and extrapolate against the 25 included
compute hours per month, remembering Apple bills the **sum of per-action time**,
not wall clock. Update the spec's Cost section, replacing the 30-40 minute
estimate with the measured figure.

- [ ] **Step 7: Point the workflow at `master` and open the PR**

Once every check above passes, change the workflow's Start Condition branch from
the feature branch to `master`, then open the PR:

```bash
git push -u origin HEAD
gh pr create -R javierbq/RayMol --base master \
  --title "iOS beta builds to TestFlight via Xcode Cloud" \
  --body "Implements docs/superpowers/specs/2026-07-26-ios-nightly-beta-design.md.

Every change to master now produces a TestFlight build for internal testers.

- \`.github/workflows/ios-deps-artifact.yml\` publishes the pinned deps_ios tree as a fingerprinted prerelease, because Xcode Cloud has no arbitrary-directory cache and would otherwise repeat the ~30 min bring-up (including the double numpy meson cross-build) on every build.
- \`swiftui/ci_scripts/ci_post_clone.sh\` fetches that artifact, stamps the derived beta version plus CI_BUILD_NUMBER, regenerates the project, builds the device core, and asserts every input before xcodebuild.
- Five new scripts, each unit-tested: fingerprint, version derivation, prune, version stamping, input assertion.
- \`docs/ios-beta-pipeline.md\` records the App Store Connect settings that cannot live in the repo.

Internal-only track: external TestFlight forces clean (uncached) builds, gates on Beta App Review, and caps submissions at six per 24h. Marketing version comes from project.yml, never git tags — the newest tag by version sort is v3.2.0 (inherited PyMOL line) while RayMol's releases top out at v1.8.0.

macOS DMG/Sparkle/cask path untouched."
```

- [ ] **Step 8: Mark the spec's risks resolved**

Update the three entries under "Risks to validate empirically on the first run"
in the spec with what actually happened, and commit. A future reader must be able
to tell which risks were real.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Two-pipeline architecture | 7, 8 |
| Fingerprint, shared by both pipelines | 2 |
| Deps workflow: triggers, prune list, prerelease publish | 4, 7 |
| Loud failure on a missing artifact | 8 (step 1) |
| `ci_scripts` location, toolchain, proxy, `brew --prefix` | 8 |
| `CURRENT_PROJECT_VERSION` ← `CI_BUILD_NUMBER` | 5, 8 |
| `xcodegen` regeneration | 8 |
| Pre-`xcodebuild` assertions | 6, 8 |
| Version derived from `project.yml`, never tags | 3 |
| App Store Connect settings, Auto-cancel, Restrict Editing | 9 |
| TestFlight internal group | 9, 10 |
| Export compliance (already set; must not regress) | 10 (step 2 verifies via a successful upload) |
| Risk 1 — script-file persistence | 1 |
| Risk 2 — undocumented timeout | 1 (step 5 measures), 10 (step 6) |
| Risk 3 — internal post-action auto-distribution | 10 (step 2, incl. the ASC API fallback) |
| Cost measurement | 10 (step 6) |
| Verification criteria 1-5 | 10 (steps 1-5) |
| Out of scope: test action, retention janitor, external track, macOS | not implemented, by design |

No gaps.

**Placeholders:** none — every step carries runnable commands or complete file
contents. The three human-gated tasks (1, 9, 10) give exact settings and exact
values to record rather than "configure as needed".

**Type/name consistency:** `ios_deps_fingerprint.sh` output feeds the tag
`ios-deps-<fp>` and assets `deps_ios-<fp>.tar.gz{,.sha256}` identically in Tasks
7 and 8. `nightly_version.sh` → `apply_ci_versions.sh <yml> <mkt> <build>` argument
order matches between Tasks 3, 5 and 8. `assert_ios_build_inputs.sh [repo-root]`
is called with `"$CI_PRIMARY_REPOSITORY_PATH"` in Task 8, matching its optional
first argument in Task 6. Required-path lists in Tasks 4 and 6 are consistent:
Task 4 asserts both slices (it publishes both); Task 6 asserts the device slice
plus the simulator Python headers (`ios-arm64_x86_64-simulator/Python.framework/
Headers`) — because `appkit/CMakeLists.txt` line 90 unconditionally reads those
headers for all iOS core builds including device, so they are device-build
load-bearing even though they look like a simulator path. *(Human-approved
amendment — Finding 3 from the Task 7 review.)*

**Ordering constraint:** Task 1 is a hard gate — do not start Task 2 until repo
mutations are confirmed to persist. Task 8 additionally requires Task 7 step 4 to
have published an artifact.
