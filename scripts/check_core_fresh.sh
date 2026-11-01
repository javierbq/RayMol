#!/bin/bash
# check_core_fresh.sh — keep the Xcode app from silently linking a STALE
# libpymol_core.a (GitHub issue #400).
#
# The Xcode project has no build dependency on the core: it links whatever
# static library already sits in build_macos_swiftui/ (or build_ios/,
# build_ios_device/), so a C++ edit does not reach the app until somebody
# remembers to rerun swiftui/build_macos.sh. This script closes that gap in two
# halves that share one definition of "what the core was built from":
#
#   stamp BUILD_DIR [FINGERPRINT]
#       Written by build_macos.sh / build_ios.sh after a successful core build:
#       BUILD_DIR/core_sha.txt =
#           git_sha=<HEAD at build time>
#           dirty=0|1            (core sources differed from HEAD)
#           source_fingerprint=<sha1 of the core source CONTENTS>
#           settings_hash=<blob id of layer1/SettingInfo.h>
#       Callers take `fingerprint` BEFORE compiling and pass it in, so a source
#       edited mid-build leaves a stamp that does not match and is reported stale
#       instead of being blessed.
#
#   check [BUILD_DIR]
#       The Xcode pre-build phase. Recomputes the fingerprint and compares it to
#       the stamp; a mismatch fails the build with
#           libpymol_core.a is stale: run swiftui/build_macos.sh
#       BUILD_DIR defaults from $PLATFORM_NAME (macosx / iphonesimulator /
#       iphoneos), which Xcode exports into script phases.
#
#   fingerprint     print the current source fingerprint
#   settings-hash [BUILD_DIR]
#                   no argument: print the blob id of layer1/SettingInfo.h.
#                   With BUILD_DIR: print "changed" when an existing lib there is
#                   unstamped or its stamp recorded a different SettingInfo.h
#                   (the incremental-build hazard that build_macos.sh documents,
#                   which then forces CLEAN=1). Silent when there is no lib yet.
#   sha [BUILD_DIR] print "1fc5fc9" / "1fc5fc9-dirty" from the stamp (the app
#                   copies it into Info.plist so the console banner shows it)
#
# WHY CONTENT, NOT MTIMES. The obvious check ("is any core source newer than the
# lib?") is wrong in this repo's own workflow: every git worktree links the
# SHARED build_* directories of master, and a fresh worktree's files all carry
# the checkout time, so mtimes would call every worktree's core stale. Hashing
# file contents makes "stale" mean "the C++ differs from what the lib was built
# from", independent of mtimes, checkout time and branch switches. It also means
# Swift-only edits never trigger it: only the files CMake compiles into the core
# (layer0-5, layerGraphics, ov, contrib, include, appkit, the shader sources) are
# hashed. `touch` alone does not make a core stale either - no content changed.
#
# FAIL-OPEN where a failure would say nothing about the core: no git (a source
# tarball), or a build dir built before stamping existed, only WARN. A missing
# libpymol_core.a, or a fingerprint mismatch, FAILS.
#
# Escape hatch: RAYMOL_SKIP_CORE_CHECK=1 (environment OR an xcodebuild build
# setting on the command line - Xcode exports build settings to script phases).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Everything CMake (appkit/CMakeLists.txt) compiles into libpymol_core.a, plus
# the shader generator and the CMake files themselves.
PATHSPECS=(layer0 layer1 layer2 layer3 layer4 layer5 layerGraphics ov contrib
           include appkit data/shaders create_shadertext.py CMakeLists.txt)
EXT_RE='\.(c|cc|cpp|cxx|h|hh|hpp|hxx|inc|inl|m|mm|cmake|txt|fs|vs|gs|tsc|tse|shared)$|^create_shadertext\.py$'

STAMP_NAME="core_sha.txt"

in_git() { git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# 40-hex fingerprint of the working-tree CONTENT of the core sources (tracked or
# untracked-but-not-ignored, so a new file counts and a deleted one drops out).
fingerprint() {
  in_git || return 1
  local files
  files="$(
    cd "$ROOT" || exit 1
    export LC_ALL=C
    comm -23 \
      <(git ls-files -c -o --exclude-standard -- "${PATHSPECS[@]}" | grep -E "$EXT_RE" | sort -u) \
      <(git ls-files -d -- "${PATHSPECS[@]}" | sort -u)
  )" || return 1
  [ -n "$files" ] || return 1
  (
    cd "$ROOT" || exit 1
    # hash-object prints one blob id per path, in input order; pairing it with
    # the path means a rename changes the fingerprint too.
    paste -d' ' <(printf '%s\n' "$files" | git hash-object --stdin-paths) <(printf '%s\n' "$files")
  ) | shasum | cut -c1-40
}

# Blob id of the settings-defaults header. An incremental CMake build does not
# reliably recompile the generated settings table when it changes (see the
# header of swiftui/build_macos.sh), so the stamp records it and the build
# script forces a clean build when it differs from the previous stamp.
settings_hash() {
  [ -f "$ROOT/layer1/SettingInfo.h" ] && git -C "$ROOT" hash-object "$ROOT/layer1/SettingInfo.h" 2>/dev/null || true
}

cmd_settings_hash() {
  if [ -z "${1:-}" ]; then settings_hash; return 0; fi
  local f="$1/$STAMP_NAME" old
  # No library yet: a from-scratch build cannot carry a stale object.
  [ -f "$1/libpymol_core.a" ] || return 0
  # A library with no stamp (built before stamping existed) or a stamp without
  # the field cannot prove its settings table is current, and the stamp about to
  # be written would vouch for it: treat it as changed so the build goes clean.
  old=""; [ -f "$f" ] && old="$(stamp_value "$f" settings_hash)"
  [ -n "$old" ] || { echo changed; return 0; }
  [ "$old" = "$(settings_hash)" ] || echo changed
}

# Resolve the build directory + the script that rebuilds it, from $1 or Xcode's
# PLATFORM_NAME. Sets BUILD_DIR and REBUILD.
resolve_dir() {
  if [ -n "${1:-}" ]; then
    BUILD_DIR="$1"
    REBUILD="swiftui/build_macos.sh (or build_ios.sh)"
    return 0
  fi
  case "${PLATFORM_NAME:-}" in
    macosx)          BUILD_DIR="$ROOT/build_macos_swiftui"; REBUILD="swiftui/build_macos.sh" ;;
    iphonesimulator) BUILD_DIR="$ROOT/build_ios";           REBUILD="swiftui/build_ios.sh" ;;
    iphoneos)        BUILD_DIR="$ROOT/build_ios_device";    REBUILD="swiftui/build_ios.sh device" ;;
    *) echo "error: check_core_fresh.sh: no BUILD_DIR given and PLATFORM_NAME='${PLATFORM_NAME:-}' is not macosx/iphoneos/iphonesimulator" >&2
       return 2 ;;
  esac
}

stamp_value() { sed -n "s/^$2=//p" "$1" | head -1; }

cmd_stamp() {
  local dir="${1:-}" fp="${2:-}"
  [ -n "$dir" ] || { echo "usage: $0 stamp BUILD_DIR [FINGERPRINT]" >&2; return 2; }
  mkdir -p "$dir"
  local sha="unknown" dirty=0
  if in_git; then
    sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    # `cut -c4-` drops porcelain's two status columns + space, so EXT_RE's
    # anchored create_shadertext.py alternative sees a bare path.
    if [ -n "$(cd "$ROOT" && git status --porcelain -- "${PATHSPECS[@]}" 2>/dev/null | cut -c4- | grep -E "$EXT_RE")" ]; then dirty=1; fi
  fi
  [ -n "$fp" ] || fp="$(fingerprint || true)"
  # Write-then-rename so a reader never sees a half-written stamp.
  local tmp; tmp="$(mktemp "$dir/.core_sha.XXXXXX")" || return 1
  { echo "git_sha=$sha"; echo "dirty=$dirty"; echo "source_fingerprint=$fp"
    echo "settings_hash=$(settings_hash)"; } > "$tmp"
  mv -f "$tmp" "$dir/$STAMP_NAME"
  echo "== core stamp: ${sha:0:9}$([ "$dirty" = 1 ] && echo '-dirty') -> $dir/$STAMP_NAME =="
}

cmd_sha() {
  resolve_dir "${1:-}" || return 2
  local f="$BUILD_DIR/$STAMP_NAME" sha
  [ -f "$f" ] || return 0
  sha="$(stamp_value "$f" git_sha)"
  [ -n "$sha" ] && [ "$sha" != unknown ] || return 0
  printf '%s' "${sha:0:9}"
  [ "$(stamp_value "$f" dirty)" = 1 ] && printf -- '-dirty'
  printf '\n'
}

cmd_check() {
  case "${RAYMOL_SKIP_CORE_CHECK:-}" in
    1|true|yes|on) echo "note: libpymol_core.a freshness check skipped (RAYMOL_SKIP_CORE_CHECK=$RAYMOL_SKIP_CORE_CHECK)"; return 0 ;;
  esac
  resolve_dir "${1:-}" || return 2
  local lib="$BUILD_DIR/libpymol_core.a" stamp="$BUILD_DIR/$STAMP_NAME"

  if [ ! -f "$lib" ]; then
    echo "error: $lib is missing: run $REBUILD" >&2
    return 1
  fi
  if [ ! -f "$stamp" ]; then
    echo "warning: $stamp not found, so libpymol_core.a staleness cannot be checked (built before stamping existed): run $REBUILD to stamp it" >&2
    return 0
  fi
  local want have
  want="$(stamp_value "$stamp" source_fingerprint)"
  if [ -z "$want" ]; then
    echo "warning: $stamp has no source_fingerprint (built without git?), staleness check skipped" >&2
    return 0
  fi
  if ! have="$(fingerprint)"; then
    echo "warning: cannot fingerprint core sources here (no git work tree), staleness check skipped" >&2
    return 0
  fi
  if [ "$want" != "$have" ]; then
    local sha; sha="$(stamp_value "$stamp" git_sha)"
    echo "error: libpymol_core.a is stale: run $REBUILD" >&2
    echo "       The core sources changed since it was built (core built from ${sha:0:9})." >&2
    echo "       Set RAYMOL_SKIP_CORE_CHECK=1 to bypass this check." >&2
    return 1
  fi
  echo "libpymol_core.a is fresh ($(cmd_sha "$BUILD_DIR"))"
}

case "${1:-}" in
  fingerprint) fingerprint || { echo "error: cannot fingerprint (not a git work tree?)" >&2; exit 1; } ;;
  stamp) shift; cmd_stamp "$@" ;;
  sha)   shift; cmd_sha "$@" ;;
  settings-hash) shift; cmd_settings_hash "$@" ;;
  check) shift; cmd_check "$@" ;;
  *) echo "usage: $0 {fingerprint | settings-hash [BUILD_DIR] | stamp BUILD_DIR [FINGERPRINT] | sha [BUILD_DIR] | check [BUILD_DIR]}" >&2; exit 2 ;;
esac
