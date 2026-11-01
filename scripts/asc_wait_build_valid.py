#!/usr/bin/env python3
"""Wait until an uploaded RayMol build is VALID in App Store Connect.

    asc_wait_build_valid.py --build 363 --platform iOS|macOS [--timeout-min 40]

`altool --upload-app` succeeding only means the package was accepted for
processing. Apple can still mark the build INVALID afterwards and say so by
email (ITMS-90208 arrives that way). A beta counts as delivered only once
processingState is VALID, so the self-hosted pipeline waits for that state
before turning green. Exits 0 on VALID, and 1 on INVALID, FAILED or timeout.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

PLATFORMS = {"iOS": "IOS", "macOS": "MAC_OS"}
QUERY = ("/v1/builds?filter[app]={app}&filter[version]={build}"
         "&filter[preReleaseVersion.platform]={platform}"
         "&fields[builds]=version,processingState&limit=1")


def wait_valid(get, app_id, build, platform, timeout_s, interval_s,
               sleep=time.sleep, now=time.monotonic, out=print):
    if platform not in PLATFORMS:
        raise ValueError(f"unknown platform {platform!r} (expected iOS or macOS)")
    path = QUERY.format(app=app_id, build=build, platform=PLATFORMS[platform])
    deadline = now() + timeout_s
    while True:
        data = get(path).get("data", [])
        state = data[0]["attributes"].get("processingState") if data else None
        out(f"{platform} build {build}: {state or 'not listed yet'}")
        if state == "VALID":
            return 0
        if state in ("INVALID", "FAILED"):
            out(f"ERROR: {platform} build {build} is {state} in App Store Connect "
                "(check the App Store Connect email for the ITMS reason)")
            return 1
        if now() + interval_s > deadline:
            out(f"ERROR: timed out after {timeout_s // 60} min waiting for "
                f"{platform} build {build} to become VALID (last state: {state})")
            return 1
        sleep(interval_s)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Wait for an uploaded build to become VALID.")
    ap.add_argument("--build", type=int, required=True)
    ap.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    ap.add_argument("--app", default=asc_api.RAYMOL_APP_ID)
    ap.add_argument("--timeout-min", type=int, default=40)
    ap.add_argument("--interval-s", type=int, default=30)
    args = ap.parse_args(argv)
    return wait_valid(asc_api.get, args.app, args.build, args.platform,
                      timeout_s=args.timeout_min * 60, interval_s=args.interval_s)


if __name__ == "__main__":
    sys.exit(main())
