#!/bin/bash
# Unit tests for scripts/check_core_fresh.sh (GitHub issue #400): the pre-build
# guard that fails the Xcode build when libpymol_core.a is older than the core
# sources it was built from. Covers the stale, fresh and skip cases.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check_core_fresh.sh"
FAILED=0
# Every fixture lives under one parent that THIS shell owns: make_fixture runs
# inside $(...) subshells, so tracking paths in an array there would be lost.
FIXROOT="$(mktemp -d)"
trap 'rm -rf "$FIXROOT"' EXIT

ok ()   { echo "  ok: $1"; }
fail () { echo "  FAIL: $1"; FAILED=1; }

# expect <label> <want-rc> <cmd...>; the command's combined output lands in $OUT.
expect () {
  local label="$1" want="$2"; shift 2
  OUT="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" = "$want" ]; then ok "$label"; else fail "$label — rc=$rc, wanted $want; output: $OUT"; fi
}
contains () {  # <label> <needle>  — against $OUT
  case "$OUT" in *"$2"*) ok "$1" ;; *) fail "$1 — '$2' not in: $OUT" ;; esac
}
lacks () {
  case "$OUT" in *"$2"*) fail "$1 — unexpected '$2' in: $OUT" ;; *) ok "$1" ;; esac
}

# A throwaway git repo holding the script under test (it derives its root from
# its own location), a few core sources, a Swift file and a built lib + stamp.
make_fixture () {
  local d; d="$(mktemp -d "$FIXROOT/fx.XXXXXX")"
  mkdir -p "$d/scripts" "$d/layer1" "$d/layer4" "$d/include" "$d/data/shaders" \
           "$d/swiftui" "$d/docs" "$d/build_macos_swiftui" "$d/build_ios" "$d/build_ios_device"
  cp "$SCRIPT" "$d/scripts/check_core_fresh.sh"
  echo 'int scene() { return 1; }' > "$d/layer1/Scene.cpp"
  echo 'int cmd() { return 2; }'   > "$d/layer4/Cmd.cpp"
  echo '#define X 1'               > "$d/include/pymol.h"
  echo 'void main() {}'            > "$d/data/shaders/default.fs"
  echo 'print("shader gen")'       > "$d/create_shadertext.py"
  echo 'struct App {}'             > "$d/swiftui/App.swift"
  echo 'notes'                     > "$d/layer1/NOTES.md"
  echo 'docs'                      > "$d/docs/readme.md"
  echo 'build_*/'                  > "$d/.gitignore"
  for b in build_macos_swiftui build_ios build_ios_device; do echo 'fake lib' > "$d/$b/libpymol_core.a"; done
  ( cd "$d" && git init -q && git add -A && \
    git -c user.name=t -c user.email=t@t commit -q -m init )
  echo "$d"
}
chk () { bash "$1/scripts/check_core_fresh.sh" check "${@:2}"; }
stamp () { bash "$1/scripts/check_core_fresh.sh" stamp "$1/${2:-build_macos_swiftui}" ${3:+"$3"} >/dev/null; }

echo "== check_core_fresh =="

# --- fingerprint ----------------------------------------------------------------
A="$(make_fixture)"; B="$(make_fixture)"
FP="$(bash "$A/scripts/check_core_fresh.sh" fingerprint)"
if [[ "$FP" =~ ^[0-9a-f]{40}$ ]]; then ok "fingerprint is 40 hex chars"; else fail "fingerprint format: '$FP'"; fi
[ "$FP" = "$(bash "$A/scripts/check_core_fresh.sh" fingerprint)" ] && ok "fingerprint deterministic" || fail "fingerprint not deterministic"
[ "$FP" = "$(bash "$B/scripts/check_core_fresh.sh" fingerprint)" ] && ok "fingerprint is path-independent" || fail "fingerprint depends on path"

# --- fresh ----------------------------------------------------------------------
stamp "$A"
expect "fresh core passes" 0 chk "$A" "$A/build_macos_swiftui"
contains "fresh core says so" "is fresh"
expect "fresh core passes via PLATFORM_NAME=macosx" 0 env PLATFORM_NAME=macosx bash "$A/scripts/check_core_fresh.sh" check

# Swift-only / non-core edits must not trigger it.
echo '// edited' >> "$A/swiftui/App.swift"
echo 'more'      >> "$A/layer1/NOTES.md"
echo 'more'      >> "$A/docs/readme.md"
expect "Swift/doc/markdown edits do not trigger" 0 chk "$A" "$A/build_macos_swiftui"

# Touching a core source changes an mtime, not the content: a fresh worktree has
# new mtimes on every file and must not read as stale. Age the lib far into the
# past to prove mtimes play no part.
touch "$A/layer1/Scene.cpp"
touch -t 200001010000 "$A/build_macos_swiftui/libpymol_core.a"
expect "touch alone (newer source, ancient lib) does not trigger" 0 chk "$A" "$A/build_macos_swiftui"

# --- stale ----------------------------------------------------------------------
echo '// edit' >> "$A/layer1/Scene.cpp"
expect "edited core .cpp is stale" 1 env PLATFORM_NAME=macosx bash "$A/scripts/check_core_fresh.sh" check
contains "stale message" "libpymol_core.a is stale: run swiftui/build_macos.sh"
contains "stale message offers the escape hatch" "RAYMOL_SKIP_CORE_CHECK=1"
contains "stale message is an Xcode error line" "error: libpymol_core.a is stale"

# rebuild -> stamp again -> fresh
stamp "$A"
expect "restamped core is fresh again" 0 chk "$A" "$A/build_macos_swiftui"

for f in layer4/Cmd.cpp include/pymol.h data/shaders/default.fs create_shadertext.py; do
  C="$(make_fixture)"; stamp "$C"; echo '// edit' >> "$C/$f"
  expect "edit of $f is stale" 1 chk "$C" "$C/build_macos_swiftui"
done

C="$(make_fixture)"; stamp "$C"; echo 'int added;' > "$C/layer1/New.cpp"
expect "new untracked core source is stale" 1 chk "$C" "$C/build_macos_swiftui"

C="$(make_fixture)"; stamp "$C"; rm "$C/layer4/Cmd.cpp"
expect "deleted core source is stale" 1 chk "$C" "$C/build_macos_swiftui"

C="$(make_fixture)"; stamp "$C"; echo '// edit' >> "$C/layer1/Scene.cpp"; ( cd "$C" && git add -A )
expect "staged core edit is stale" 1 chk "$C" "$C/build_macos_swiftui"
( cd "$C" && git -c user.name=t -c user.email=t@t commit -q -m c )
expect "committed core edit is still stale" 1 chk "$C" "$C/build_macos_swiftui"

# A source edited WHILE the core was building: the build scripts take the
# fingerprint first, so the stamp must not bless the edit.
C="$(make_fixture)"
PRE="$(bash "$C/scripts/check_core_fresh.sh" fingerprint)"
echo '// mid-build edit' >> "$C/layer1/Scene.cpp"
stamp "$C" build_macos_swiftui "$PRE"
expect "mid-build edit reads as stale" 1 chk "$C" "$C/build_macos_swiftui"

# --- per-platform build dir + message --------------------------------------------
C="$(make_fixture)"; stamp "$C" build_ios; stamp "$C" build_ios_device
echo '// edit' >> "$C/layer1/Scene.cpp"
expect "iphonesimulator is stale" 1 env PLATFORM_NAME=iphonesimulator bash "$C/scripts/check_core_fresh.sh" check
contains "iphonesimulator message names build_ios.sh" "run swiftui/build_ios.sh"
expect "iphoneos is stale" 1 env PLATFORM_NAME=iphoneos bash "$C/scripts/check_core_fresh.sh" check
contains "iphoneos message names the device build" "run swiftui/build_ios.sh device"
expect "unknown platform is a usage error" 2 env PLATFORM_NAME= bash "$C/scripts/check_core_fresh.sh" check

# --- skip -----------------------------------------------------------------------
for v in 1 true yes on; do
  expect "RAYMOL_SKIP_CORE_CHECK=$v skips a stale core" 0 env RAYMOL_SKIP_CORE_CHECK=$v PLATFORM_NAME=macosx bash "$C/scripts/check_core_fresh.sh" check
done
contains "skip says so" "skipped"
expect "RAYMOL_SKIP_CORE_CHECK=0 does not skip" 1 env RAYMOL_SKIP_CORE_CHECK=0 PLATFORM_NAME=iphoneos bash "$C/scripts/check_core_fresh.sh" check

# --- fail-open cases ---------------------------------------------------------------
D="$(make_fixture)"   # lib exists but was never stamped
expect "unstamped core only warns" 0 chk "$D" "$D/build_macos_swiftui"
contains "unstamped warning" "warning:"

rm "$D/build_macos_swiftui/libpymol_core.a"
expect "missing lib fails" 1 chk "$D" "$D/build_macos_swiftui"
contains "missing lib message" "is missing: run"

N="$(mktemp -d "$FIXROOT/nogit.XXXXXX")"; mkdir -p "$N/scripts" "$N/build_macos_swiftui"
cp "$SCRIPT" "$N/scripts/"; echo lib > "$N/build_macos_swiftui/libpymol_core.a"
printf 'git_sha=unknown\ndirty=0\nsource_fingerprint=abc\n' > "$N/build_macos_swiftui/core_sha.txt"
expect "no git work tree only warns" 0 chk "$N" "$N/build_macos_swiftui"
contains "no-git warning" "warning:"

# --- stamp contents + sha subcommand ------------------------------------------------
E="$(make_fixture)"; stamp "$E"
HEAD_SHA="$(git -C "$E" rev-parse HEAD)"
S="$E/build_macos_swiftui/core_sha.txt"
grep -qx "git_sha=$HEAD_SHA" "$S" && ok "stamp records HEAD" || fail "stamp git_sha: $(cat "$S")"
grep -qx "dirty=0" "$S" && ok "clean tree stamps dirty=0" || fail "stamp dirty: $(cat "$S")"
grep -qx "source_fingerprint=$(bash "$E/scripts/check_core_fresh.sh" fingerprint)" "$S" && ok "stamp records the fingerprint" || fail "stamp fingerprint"
expect "sha subcommand" 0 bash "$E/scripts/check_core_fresh.sh" sha "$E/build_macos_swiftui"
[ "$OUT" = "${HEAD_SHA:0:9}" ] && ok "sha prints the short SHA" || fail "sha output '$OUT'"
echo '// edit' >> "$E/layer1/Scene.cpp"; stamp "$E"
grep -qx "dirty=1" "$S" && ok "edited tree stamps dirty=1" || fail "stamp dirty: $(cat "$S")"
OUT="$(bash "$E/scripts/check_core_fresh.sh" sha "$E/build_macos_swiftui")"
[ "$OUT" = "${HEAD_SHA:0:9}-dirty" ] && ok "sha prints -dirty" || fail "sha dirty output '$OUT'"
# The root-level generator is matched by an anchored regex alternative; the
# dirty check must still see it through porcelain's status-column prefix.
G="$(make_fixture)"; echo '# edit' >> "$G/create_shadertext.py"; stamp "$G"
grep -qx "dirty=1" "$G/build_macos_swiftui/core_sha.txt" && ok "edited create_shadertext.py stamps dirty=1" || fail "create_shadertext.py dirty: $(cat "$G/build_macos_swiftui/core_sha.txt")"
G="$(make_fixture)"; echo 'doc' >> "$G/docs/readme.md"; stamp "$G"
grep -qx "dirty=0" "$G/build_macos_swiftui/core_sha.txt" && ok "doc-only edit stamps dirty=0" || fail "doc dirty: $(cat "$G/build_macos_swiftui/core_sha.txt")"
OUT="$(bash "$E/scripts/check_core_fresh.sh" sha "$E/build_ios")"
[ -z "$OUT" ] && ok "sha is empty without a stamp" || fail "sha without stamp: '$OUT'"

if [ "$FAILED" = 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
