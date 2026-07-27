#!/usr/bin/env python3
"""Create or update the production Xcode Cloud workflow for iOS beta builds.

WHY THIS SCRIPT EXISTS
======================
The original plan specified a manual UI settings table in docs/ios-beta-pipeline.md.
Encoding those settings in a script instead makes the configuration reviewable in
git, reproducible, and auditable across changes — the same reason CI configs live
in .github/workflows rather than in a web UI.

WHAT IT CREATES
===============
Workflow "iOS Beta (master)" on the RayMol ciProduct:
  * One ARCHIVE action, scheme PyMOLViewer_iOS, platform IOS
  * Branch start condition on master, autoCancel enabled
  * Files-and-folders rule excluding docs/** and *.md
  * isEnabled: true, isLockedForEditing: true

Run with --dry-run (the default) to print the payload and send nothing.
Pass --write to actually create or update the workflow.

WHAT THIS CANNOT SET VIA THE API
=================================
The following settings are NOT expressible through the ciWorkflows REST endpoint
and must be configured manually in App Store Connect after the workflow is created:

  * TestFlight internal testing post-action: there is no documented REST endpoint
    for ciWorkflow post-actions that attaches a TestFlight internal-testing step
    with a named group (e.g. "Beta"). The ARCHIVE action can specify
    buildDistributionAudience = INTERNAL_TESTERS to route the IPA to internal
    testers, but selecting a specific named TestFlight group requires the Xcode
    or App Store Connect UI.

  * Email and Slack notifications: ciWorkflow notification settings are not
    exposed by the App Store Connect REST API v1 as of July 2026.

These two items remain manual. This script prints an explicit reminder.

PREREQUISITES
=============
  * Xcode Cloud must already be enabled for the RayMol product (one-time human
    step in Xcode: Integrate > Create Workflow). If GET /v1/ciProducts returns no
    results, this script exits with a clear error.
  * Env vars: ASC_KEY_ID, ASC_ISSUER
  * Private key: ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
    Override path with ASC_KEY_FILE.
  * PyJWT installed (pip install PyJWT cryptography).

The key must have the Admin or App Manager role; a Developer-role key returns 403.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# Fail early and clearly if PyJWT is missing.
try:
    import jwt
except ImportError:
    sys.exit("ERROR: PyJWT not installed. Run: pip install PyJWT cryptography")

BASE = "https://api.appstoreconnect.apple.com/v1"

WORKFLOW_NAME = "iOS Beta (master)"
SCHEME = "PyMOLViewer_iOS"
CONTAINER_FILE_PATH = "swiftui/PyMOLViewer.xcodeproj"
PRODUCTION_BRANCH = "master"

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

KEY_ID = os.environ.get("ASC_KEY_ID")
ISSUER = os.environ.get("ASC_ISSUER")


def _key_file() -> str:
    explicit = os.environ.get("ASC_KEY_FILE")
    if explicit:
        return explicit
    if not KEY_ID:
        return ""
    return os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8")


def _token() -> str:
    """Return a fresh ES256 JWT. Never print key material or the JWT itself."""
    key_file = _key_file()
    if not os.path.exists(key_file):
        sys.exit(
            f"ERROR: private key not found at {key_file}\n"
            f"  Set ASC_KEY_FILE to override the path, or place the key there."
        )
    now = int(time.time())
    with open(key_file) as f:
        secret = f.read()
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        secret,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def _call(method: str, path: str, payload=None):
    """Make one ASC API call; exit on HTTP error with the error detail."""
    url = f"{BASE}/{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_token()}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            errs = json.loads(raw).get("errors", [])
            detail = "; ".join(
                f"{x.get('title')}: {x.get('detail')}" for x in errs
            )
        except Exception:
            detail = raw[:500]
        sys.exit(f"ERROR: HTTP {e.code} on {method} /{path}\n  {detail}")


def _pick(items, label, chooser=None):
    """Return the first item matching chooser, or the first item if chooser is
    None. Exit if the list is empty."""
    if not items:
        sys.exit(f"ERROR: no {label} found — is Xcode Cloud onboarded?")
    if chooser:
        for it in items:
            if chooser(it):
                return it
        # Fall back to first if chooser found nothing.
        print(f"  warning: no {label} matched the chooser; using the first")
    if len(items) > 1:
        print(f"  note: {len(items)} {label} found; using the first")
    return items[0]


# ---------------------------------------------------------------------------
# Workflow payload
# ---------------------------------------------------------------------------


def _build_payload(pid: str, repo_id: str, xcode_id: str, macos_id: str) -> dict:
    """Return the ciWorkflows POST/PATCH body for the production workflow.

    FILES-AND-FOLDERS RULE NOTE
    ---------------------------
    Apple's CiFilePatternMatcher shape (as documented in the ASC REST API):
      pattern   : string
      matchType : FILE | FILE_EXTENSION | DIRECTORY | DIRECTORY_OR_DESCENDANT
      inverse   : bool  (true = exclude this pattern, i.e. do NOT trigger)

    Setting inverse=true on each matcher means "skip the build when EVERY
    changed file matches one of these exclusion patterns". This is the correct
    encoding for "ignore docs/ and *.md pushes".

    VERIFY BEFORE --write: Apple's REST documentation for CiFilePatternMatcher
    has not always listed `inverse` as a writable field. If the API rejects the
    payload with a 400/422 on the matchers, try removing `inverse` and
    re-encoding the logic as include-only patterns (i.e., enumerate paths that
    DO trigger the build — less precise but always accepted).
    """
    return {
        "data": {
            "type": "ciWorkflows",
            "attributes": {
                "name": WORKFLOW_NAME,
                "description": (
                    "Nightly iOS beta pipeline: every non-docs push to master "
                    "archives PyMOLViewer_iOS and distributes to internal testers "
                    "via TestFlight. Managed by scripts/asc_xcode_cloud_workflow.py."
                ),
                "isEnabled": True,
                # isLockedForEditing: Apple requires this to be true for any
                # workflow that uploads to TestFlight (i.e. review-eligible builds).
                "isLockedForEditing": True,
                "clean": True,
                "containerFilePath": CONTAINER_FILE_PATH,
                "branchStartCondition": {
                    "source": {
                        "isAllMatch": False,
                        "patterns": [
                            {"pattern": PRODUCTION_BRANCH, "isPrefix": False}
                        ],
                    },
                    "filesAndFoldersRule": {
                        "matchers": [
                            {
                                "pattern": "docs",
                                "matchType": "DIRECTORY_OR_DESCENDANT",
                                "inverse": True,
                            },
                            {
                                "pattern": ".md",
                                "matchType": "FILE_EXTENSION",
                                "inverse": True,
                            },
                        ]
                    },
                    "autoCancel": True,
                },
                "actions": [
                    {
                        "name": "Archive iOS",
                        "actionType": "ARCHIVE",
                        "destination": None,
                        # INTERNAL_TESTERS routes the IPA to internal testers but
                        # does NOT select a specific named TestFlight group — that
                        # step must be configured in the post-action UI. See the
                        # "What this cannot set" section in this file's header.
                        "buildDistributionAudience": "INTERNAL_TESTERS",
                        "testConfiguration": None,
                        "scheme": SCHEME,
                        "platform": "IOS",
                        "isRequiredToPass": True,
                    }
                ],
            },
            "relationships": {
                "product": {"data": {"type": "ciProducts", "id": pid}},
                "repository": {"data": {"type": "scmRepositories", "id": repo_id}},
                "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": xcode_id}},
                "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": macos_id}},
            },
        }
    }


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(
        description="Create or update the production iOS beta Xcode Cloud workflow."
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="(default) Print the payload and send nothing.",
    )
    ap.add_argument(
        "--write",
        dest="dry_run",
        action="store_false",
        help="Actually create or update the workflow via the API.",
    )
    ap.add_argument(
        "--update-id",
        metavar="WORKFLOW_ID",
        default=None,
        help="PATCH an existing workflow instead of creating a new one.",
    )
    args = ap.parse_args()

    if not (KEY_ID and ISSUER):
        sys.exit(
            "ERROR: set ASC_KEY_ID and ASC_ISSUER environment variables.\n"
            "  ASC_KEY_ID  : the key ID from App Store Connect (10 chars)\n"
            "  ASC_ISSUER  : the issuer UUID from App Store Connect\n"
            "  ASC_KEY_FILE: optional override for the .p8 path\n"
            "                (default: ~/.appstoreconnect/private_keys/"
            "AuthKey_<ASC_KEY_ID>.p8)"
        )

    print("== discover ==")
    products = _call("GET", "ciProducts?limit=50").get("data", [])
    if not products:
        sys.exit(
            "ERROR: GET /v1/ciProducts returned no results.\n"
            "  Xcode Cloud is not enabled for this team yet, or the key\n"
            "  does not have Admin/App Manager access.\n"
            "\n"
            "  One-time onboarding (human, cannot be done via API):\n"
            "    Open Xcode → Integrate ▸ Create Workflow\n"
            "    Grant access to javierbq/RayMol, accept the Xcode Cloud terms.\n"
            "  Then re-run this script."
        )

    product = _pick(
        products,
        "ciProducts",
        lambda p: p.get("attributes", {}).get("name") == "RayMol",
    )
    pid = product["id"]
    print(f"  product {pid}  name={product.get('attributes', {}).get('name')!r}")

    repos = _call("GET", f"ciProducts/{pid}/primaryRepositories?limit=20").get(
        "data", []
    )
    repo = _pick(
        repos,
        "repositories",
        lambda r: r.get("attributes", {}).get("repositoryName") == "RayMol",
    )
    ra = repo.get("attributes", {})
    print(f"  repo    {repo['id']}  {ra.get('ownerName')}/{ra.get('repositoryName')}")

    xcodes = _call("GET", "ciXcodeVersions?limit=20").get("data", [])
    xcode = _pick(
        xcodes,
        "xcode versions",
        lambda v: v.get("attributes", {}).get("name") == "Latest Release",
    )
    print(f"  xcode   {xcode['id']}  {xcode.get('attributes', {}).get('name')!r}")

    macos_versions = _call(
        "GET", f"ciXcodeVersions/{xcode['id']}/macOsVersions?limit=20"
    ).get("data", [])
    mac = _pick(
        macos_versions,
        "macOS versions",
        lambda v: v.get("attributes", {}).get("name") == "Latest Release",
    )
    print(f"  macos   {mac['id']}  {mac.get('attributes', {}).get('name')!r}")

    payload = _build_payload(pid, repo["id"], xcode["id"], mac["id"])

    print()
    print("== payload ==")
    print(json.dumps(payload, indent=2))

    print()
    print("== what this script CANNOT set (manual steps required after creation) ==")
    print("  1. TestFlight internal testing post-action with a named group ('Beta').")
    print("     The ARCHIVE action sets buildDistributionAudience=INTERNAL_TESTERS,")
    print("     which routes the IPA, but selecting a specific TestFlight group")
    print("     requires the App Store Connect or Xcode UI workflow editor.")
    print("  2. Email / Slack failure notifications.")
    print("     Workflow notification settings are not exposed by the ASC REST API.")
    print()
    print("  After running --write, complete these two steps in the UI:")
    print("    App Store Connect → Xcode Cloud → iOS Beta (master) → Edit")
    print("    Add post-action: TestFlight Internal Testing → group 'Beta'")
    print("    Add notification: email on failure (and optionally Slack webhook)")

    if args.dry_run:
        print()
        print("(dry run — nothing sent. Pass --write to create/update for real.)")
        return

    if args.update_id:
        print(f"\n== PATCH workflow {args.update_id} ==")
        # For PATCH, relationships are not required; only attributes change.
        patch_payload = {
            "data": {
                "type": "ciWorkflows",
                "id": args.update_id,
                "attributes": payload["data"]["attributes"],
            }
        }
        wf = _call("PATCH", f"ciWorkflows/{args.update_id}", patch_payload)["data"]
        wid = wf["id"]
        print(f"  updated workflow {wid}  name={wf.get('attributes', {}).get('name')!r}")
    else:
        print("\n== POST ciWorkflows ==")
        wf = _call("POST", "ciWorkflows", payload)["data"]
        wid = wf["id"]
        print(
            f"  created workflow {wid}  name={wf.get('attributes', {}).get('name')!r}"
        )

    print()
    print(f"  Workflow ID: {wid}")
    print(
        "  App Store Connect URL: "
        "https://appstoreconnect.apple.com/teams/<team>/apps/6781513038/xcode/workflows"
    )
    print()
    print("NEXT STEPS (manual):")
    print("  1. Open the workflow in App Store Connect and add the TestFlight")
    print("     internal testing post-action pointing at group 'Beta'.")
    print("  2. Add a failure notification (email and/or Slack).")
    print(
        "  3. Delete the 'SPIKE - validation' throwaway workflow "
        "(ID d6ebe935-3298-4b47-831a-b03af5ec4fe2) once the production"
    )
    print("     workflow has produced its first successful archive.")


if __name__ == "__main__":
    main()
