#!/bin/bash
# Unit tests for scripts/selfhosted_runner_job_guard.sh — the job-started hook
# on puma that is the actual security boundary of the self-hosted runner.
# javierbq/RayMol is public: any fork PR can add its own workflow targeting the
# `puma` label, and a dispatch runs the workflow file from the dispatched ref,
# so nothing inside a workflow can protect the runner. This guard must admit
# exactly beta-selfhosted.yml on master (schedule or dispatch) and refuse
# everything else, failing closed when a variable is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/selfhosted_runner_job_guard.sh"
FAILED=0
GOOD_WF='javierbq/RayMol/.github/workflows/beta-selfhosted.yml@refs/heads/master'

# expect <allow|refuse> <label> <repo> <event> <ref> <workflow_ref>   ("-" = unset)
expect () {
  local want="$1" label="$2" rc out
  local -a vars=()
  [ "$3" = - ] || vars+=("GITHUB_REPOSITORY=$3")
  [ "$4" = - ] || vars+=("GITHUB_EVENT_NAME=$4")
  [ "$5" = - ] || vars+=("GITHUB_REF=$5")
  [ "$6" = - ] || vars+=("GITHUB_WORKFLOW_REF=$6")
  out="$(env -u GITHUB_REPOSITORY -u GITHUB_EVENT_NAME -u GITHUB_REF -u GITHUB_WORKFLOW_REF \
           "${vars[@]+"${vars[@]}"}" bash "$SCRIPT" 2>&1)"; rc=$?
  if [ "$want" = allow ] && [ "$rc" -eq 0 ]; then echo "  ok: $label -> allowed"
  elif [ "$want" = refuse ] && [ "$rc" -ne 0 ] && grep -q "refused" <<<"$out"; then echo "  ok: $label -> refused"
  else echo "  FAIL: $label (rc=$rc, want $want): $out"; FAILED=1; fi
}

echo "== selfhosted_runner_job_guard =="
expect allow  "nightly on master"                javierbq/RayMol schedule          refs/heads/master "$GOOD_WF"
expect allow  "manual dispatch on master"        javierbq/RayMol workflow_dispatch refs/heads/master "$GOOD_WF"

expect refuse "fork PR adding its own workflow"  javierbq/RayMol pull_request      refs/pull/9/merge 'javierbq/RayMol/.github/workflows/evil.yml@refs/pull/9/merge'
expect refuse "fork PR, beta workflow name"      javierbq/RayMol pull_request      refs/pull/9/merge 'javierbq/RayMol/.github/workflows/beta-selfhosted.yml@refs/pull/9/merge'
expect refuse "pull_request_target"              javierbq/RayMol pull_request_target refs/heads/master "$GOOD_WF"
expect refuse "push to master"                   javierbq/RayMol push              refs/heads/master "$GOOD_WF"
expect refuse "dispatch from another branch"     javierbq/RayMol workflow_dispatch refs/heads/feature 'javierbq/RayMol/.github/workflows/beta-selfhosted.yml@refs/heads/feature'
expect refuse "other workflow file on master"    javierbq/RayMol workflow_dispatch refs/heads/master 'javierbq/RayMol/.github/workflows/evil.yml@refs/heads/master'
expect refuse "branch-name prefix trick"         javierbq/RayMol workflow_dispatch refs/heads/master 'javierbq/RayMol/.github/workflows/beta-selfhosted.yml@refs/heads/master-evil'
expect refuse "another repository"               someone/RayMol  schedule          refs/heads/master 'someone/RayMol/.github/workflows/beta-selfhosted.yml@refs/heads/master'
expect refuse "workflow ref unset (fail closed)" javierbq/RayMol schedule          refs/heads/master -
expect refuse "everything unset (fail closed)"   -               -                 -                 -

[ "$FAILED" = 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
