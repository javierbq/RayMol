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
