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
