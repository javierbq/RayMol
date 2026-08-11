#!/bin/bash
# Unit tests for the package-plugin trust step of swiftui/ci_scripts/ci_post_clone.sh.
#
# WHY THIS SUITE EXISTS. mlx-swift ships a `CudaBuild` build-tool plugin. Xcode
# will not run an untrusted package plugin, and Xcode Cloud has no dialog to
# trust it at, so its Archive - iOS action fails outright with
#     Plugin "CudaBuild" from package "mlx-swift" must be enabled before it can be used
# Every iOS Beta build from #22 to #23 died exactly there. The cure is two
# `defaults write` calls in ci_post_clone.sh, because Xcode Cloud runs its own
# xcodebuild and we cannot pass it -skipPackagePluginValidation.
#
# The failure mode this suite guards is narrow and nasty: one of the two keys is
# spelled with Apple's own typo — IDESkipPackagePluginFingerprintValidat*at*ion.
# "Correcting" it produces a key nothing reads, `defaults write` still exits 0,
# and the break resurfaces 20 minutes later inside a build whose flags we do not
# control. Nothing else in the repo can catch that, and ci_post_clone.sh itself
# cannot run outside Xcode Cloud (it `set -u`s on CI_PRIMARY_REPOSITORY_PATH),
# so the assertions below are made against its source text plus — when an Xcode
# is installed — the key names Xcode itself contains.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/swiftui/ci_scripts/ci_post_clone.sh"
FAILED=0

# The exact strings Xcode recognises. GOOD_PLUGIN carries Apple's doubled "at".
GOOD_PLUGIN="IDESkipPackagePluginFingerprintValidatation"
GOOD_MACRO="IDESkipMacroFingerprintValidation"
# The plausible "fix" someone will eventually apply to GOOD_PLUGIN. It is inert.
TYPO_FIX="IDESkipPackagePluginFingerprintValidation"

echo "== ci_post_clone plugin trust =="

if [ ! -f "$HOOK" ]; then
  echo "  FAIL: hook not found: $HOOK"
  echo "FAILURES"; exit 1
fi

# 1. Both keys are actually written, to the domain xcodebuild reads.
for KEY in "$GOOD_PLUGIN" "$GOOD_MACRO"; do
  if grep -qE "^defaults write com\.apple\.dt\.Xcode $KEY -bool YES$" "$HOOK"; then
    echo "  ok: writes $KEY"
  else
    echo "  FAIL: no 'defaults write com.apple.dt.Xcode $KEY -bool YES' line in ci_post_clone.sh"
    FAILED=1
  fi
done

# 2. The corrected spelling must never appear. grep for it as a whole word so
#    the doubled-"at" form above cannot satisfy this check by accident.
if grep -qE "(^|[^a-zA-Z])$TYPO_FIX([^a-zA-Z]|$)" "$HOOK"; then
  echo "  FAIL: found the 'corrected' spelling $TYPO_FIX — Xcode does not read that key."
  echo "        Apple's own string is $GOOD_PLUGIN (doubled 'at'). Restore it."
  FAILED=1
else
  echo "  ok: no inert 'corrected' spelling"
fi

# 3. The writes are verified by a read-back. A `defaults write` that silently
#    no-ops must not reach the archive action unnoticed — same discipline as the
#    xcconfig and project.yml patches elsewhere in the hook.
if grep -qE 'defaults read com\.apple\.dt\.Xcode' "$HOOK"; then
  for KEY in "$GOOD_PLUGIN" "$GOOD_MACRO"; do
    # The key must be in the verification loop's own key list, not merely
    # mentioned somewhere in the file — a prose reference verifies nothing.
    if grep -qE "^for KEY in .*$KEY" "$HOOK"; then
      echo "  ok: $KEY write is read back"
    else
      echo "  FAIL: $KEY is not in the read-back verification loop's key list"
      FAILED=1
    fi
  done
else
  echo "  FAIL: no 'defaults read com.apple.dt.Xcode' read-back at all —"
  echo "        a silent no-op write would reach the archive action unnoticed"
  FAILED=1
fi

# 4. Cross-check the key names against the installed Xcode. This is what makes
#    the suite more than a restatement of the source: if a future Xcode renames
#    or de-typos either key, this fails and tells us to write BOTH spellings
#    rather than silently regressing the pipeline.
DEVDIR="$(xcode-select -p 2>/dev/null || true)"
CANDIDATES=(
  "$DEVDIR/../Frameworks/IDEFoundation.framework/Versions/A/IDEFoundation"
  "$DEVDIR/../SharedFrameworks/SwiftPM.framework/Versions/A/SwiftPM"
  "$DEVDIR/../SharedFrameworks/IDESwiftPackageCore.framework/Versions/A/IDESwiftPackageCore"
)
FOUND_BIN=0
for KEY in "$GOOD_PLUGIN" "$GOOD_MACRO"; do
  HIT=0
  for BIN in "${CANDIDATES[@]}"; do
    [ -f "$BIN" ] || continue
    FOUND_BIN=1
    # Count rather than `grep -q`: -q exits on the first match, which SIGPIPEs
    # `strings` (141), and `set -o pipefail` above then reports the whole
    # pipeline as failed even though the string WAS found. -c drains the stream.
    N="$(strings -a "$BIN" 2>/dev/null | grep -cxF "$KEY" || true)"
    if [ "${N:-0}" -gt 0 ]; then HIT=1; break; fi
  done
  if [ "$FOUND_BIN" = 0 ]; then continue; fi
  if [ "$HIT" = 1 ]; then
    echo "  ok: Xcode contains $KEY"
  else
    echo "  FAIL: the installed Xcode does not contain the string $KEY."
    echo "        Apple may have renamed it; find the current name with"
    echo "        strings -a <IDEFoundation> | grep '^IDESkip' and write BOTH."
    FAILED=1
  fi
done
if [ "$FOUND_BIN" = 0 ]; then
  # Announce loudly rather than pass quietly — an unrun assertion is not a pass.
  echo "  SKIP: no Xcode framework binary found under '$DEVDIR/..'; key names"
  echo "        not cross-checked against Xcode on this machine."
fi

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
