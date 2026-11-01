#!/usr/bin/env python3
"""Print the next TestFlight build number for RayMol.

It is 1 + the highest build number App Store Connect holds for the app,
across iOS and macOS, releases and betas, expired or not. One shared counter
keeps Apple's rule that Mac build numbers always increase across versions,
the same way Xcode Cloud's CI_BUILD_NUMBER did.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api  # noqa: E402

PAGE = "/v1/builds?filter[app]={app}&limit=200&fields[builds]=version"


def iter_build_pages(get, app_id):
    path = PAGE.format(app=app_id)
    while path:
        page = get(path)
        yield page
        path = (page.get("links") or {}).get("next")


def build_number(version):
    """'362' -> 362, '32.190' -> 32 (Apple orders by the leading component
    first), anything non-numeric -> None."""
    head = str(version).split(".", 1)[0]
    return int(head) if head.isdigit() else None


def next_build_number(pages):
    numbers = []
    for page in pages:
        for build in page.get("data", []):
            n = build_number(build.get("attributes", {}).get("version", ""))
            if n is not None:
                numbers.append(n)
    if not numbers:
        raise ValueError("App Store Connect returned no numeric builds for the app; "
                         "refusing to guess (wrong app id or key without access?)")
    return max(numbers) + 1


def main(argv=None):
    ap = argparse.ArgumentParser(description="Print the next RayMol TestFlight build number.")
    ap.add_argument("--app", default=asc_api.RAYMOL_APP_ID)
    args = ap.parse_args(argv)
    try:
        print(next_build_number(iter_build_pages(asc_api.get, args.app)))
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
