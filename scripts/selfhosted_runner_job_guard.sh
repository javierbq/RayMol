#!/bin/bash
# selfhosted_runner_job_guard.sh — job-started hook for the self-hosted runner
# on puma (ACTIONS_RUNNER_HOOK_JOB_STARTED). This is the runner's security
# boundary, not the workflow's `github.ref` check.
#
# javierbq/RayMol is public. A fork PR can add its OWN workflow that targets
# the `puma` label, and a workflow_dispatch runs the workflow file from the
# dispatched ref, so a check inside any workflow can be edited away by the
# code it is meant to stop. puma holds an Admin App Store Connect key on disk.
# The runner therefore runs a COPY of this script installed outside the job
# workspace (docs/ci/selfhosted-beta-runner.md). Before any step of any job
# runs, the copy admits exactly one thing:
#
#   repository  javierbq/RayMol
#   event       schedule | workflow_dispatch
#   ref         refs/heads/master
#   workflow    javierbq/RayMol/.github/workflows/beta-selfhosted.yml@refs/heads/master
#
# Anything else, including a missing variable, is refused (non-zero exit fails
# the job). GitHub does not let a workflow override GITHUB_* variables.
set -uo pipefail

REPO="javierbq/RayMol"
WORKFLOW_REF="$REPO/.github/workflows/beta-selfhosted.yml@refs/heads/master"

refuse () {
  echo "selfhosted_runner_job_guard: refused — $1" >&2
  echo "  repo='${GITHUB_REPOSITORY:-}' event='${GITHUB_EVENT_NAME:-}' ref='${GITHUB_REF:-}'" >&2
  echo "  workflow='${GITHUB_WORKFLOW_REF:-}'" >&2
  echo "  This runner only runs $WORKFLOW_REF (schedule or workflow_dispatch)." >&2
  exit 1
}

[ "${GITHUB_REPOSITORY:-}" = "$REPO" ] || refuse "wrong repository"
case "${GITHUB_EVENT_NAME:-}" in
  schedule|workflow_dispatch) ;;
  *) refuse "event is not schedule or workflow_dispatch" ;;
esac
[ "${GITHUB_REF:-}" = "refs/heads/master" ] || refuse "ref is not refs/heads/master"
[ "${GITHUB_WORKFLOW_REF:-}" = "$WORKFLOW_REF" ] || refuse "workflow is not beta-selfhosted.yml on master"

echo "selfhosted_runner_job_guard: allowed $GITHUB_WORKFLOW_REF ($GITHUB_EVENT_NAME)"
