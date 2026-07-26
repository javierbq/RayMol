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
