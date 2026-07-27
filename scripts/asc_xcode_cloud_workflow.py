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
  * One ARCHIVE action, scheme PyMOLViewer_iOS, platform IOS,
    buildDistributionAudience INTERNAL_ONLY (permanent — see comment in payload)
  * Branch start condition on master, autoCancel enabled
  * filesAndFoldersRule: null at creation (undocumented matcher shape — add in UI,
    then read back via GET and encode here; see comment in payload)
  * isEnabled: true, isLockedForEditing: FALSE (unlocked at creation — see below)

Run with --dry-run (the default) to print the payload and send nothing.
Pass --write to create the workflow.
Pass --lock --update-id <ID> --write to lock it AFTER the UI steps are done.

WHY isLockedForEditing IS DEFERRED (not set at creation)
=========================================================
Apple requires isLockedForEditing: true for any workflow whose archive action
distributes review-eligible builds to TestFlight. HOWEVER, a locked workflow
is read-only in the App Store Connect UI — the edit affordance is disabled.

Three mandatory post-creation steps cannot be done via the API (see below):
the files/folders exclusion rule, the TestFlight internal-testing post-action,
and failure notifications. All three MUST be added in the UI before the
workflow is locked. Creating the workflow locked and then telling the operator
to "edit it in the UI" sends them to a read-only page — a dead end with no
error message.

Correct order:
  1. --write   : create unlocked, so the UI is editable
  2. UI         : add all THREE settings, files/folders rule first —
                    a. files/folders rule: exclude 'docs/**' and '*.md'
                    b. TestFlight Internal Testing post-action (group 'Beta')
                    c. failure notification (email and/or Slack)
  3. --lock     : PATCH isLockedForEditing to true (review eligibility)

Skipping (a) is the costly one: once locked, the exclusion is unreachable
without unlocking again, and every docs-only push to master then archives and
uploads a pointless build.

WHAT THIS CANNOT SET VIA THE API
=================================
The following settings are NOT expressible through the ciWorkflows REST endpoint
and must be configured manually in App Store Connect after the workflow is created:

  * Files/folders exclusion rule (exclude 'docs/**' and '*.md'): Apple's
    CiFilePatternMatcher field names are undocumented and an initial guess
    (pattern, matchType, inverse) was rejected as unknown properties, so
    filesAndFoldersRule is sent as null at creation. Add the rule in the UI,
    then read the real shape back via GET /v1/ciWorkflows/<id> and encode it
    here so future re-creations can set it via the API.

  * TestFlight internal testing post-action: there is no documented REST endpoint
    for ciWorkflow post-actions that attaches a TestFlight internal-testing step
    with a named group (e.g. "Beta"). The ARCHIVE action sets
    buildDistributionAudience = INTERNAL_ONLY, which marks the build as
    internal-only (permanent — it can never be promoted to external testing or
    App Store submission). INTERNAL_ONLY does NOT attach the build to a named
    TestFlight group; that requires a UI post-action step. Whether that post-action
    auto-distributes is unverified (Apple's docs are ambiguous on this point).

  * Email and Slack notifications: ciWorkflow notification settings are not
    exposed by the App Store Connect REST API v1 as of July 2026.

These three items remain manual. This script prints an explicit reminder.

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


def _build_payload(pid: str, repo_id: str, xcode_id: str, macos_id: str, locked: bool = False) -> dict:
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
                    "archives PyMOLViewer_iOS and routes it for internal "
                    "TestFlight testing. Managed by "
                    "scripts/asc_xcode_cloud_workflow.py."
                ),
                "isEnabled": True,
                # isLockedForEditing is passed as a parameter (default False).
                # At creation it must be False so the operator can edit the
                # workflow in the UI to add the files/folders exclusion rule,
                # the TestFlight post-action and notifications (none of the
                # three is expressible via the API). Once those
                # UI steps are done, run `--lock --update-id <ID> --write` to
                # patch it to True. Apple requires True for review-eligible
                # builds, but setting True at creation makes the UI read-only,
                # blocking the mandatory manual steps — a dead end.
                "isLockedForEditing": locked,
                "clean": True,
                "containerFilePath": CONTAINER_FILE_PATH,
                "branchStartCondition": {
                    "source": {
                        "isAllMatch": False,
                        "patterns": [
                            {"pattern": PRODUCTION_BRANCH, "isPrefix": False}
                        ],
                    },
                    # filesAndFoldersRule: set to None (no rule at creation).
                    #
                    # INTENT: skip builds for docs/**-only and *.md-only pushes.
                    #
                    # WHY NULL: our initial guess of
                    #   matchers[].{pattern, matchType, inverse}
                    # was rejected by Apple with "contains additional unknown
                    # property 'pattern'" (and matchType, and inverse). The real
                    # CiFilesAndFoldersCondition matcher field names are not
                    # publicly documented and cannot be inferred safely.
                    #
                    # CORRECT PROCEDURE (one-time, after --write):
                    #   1. Add the docs/**/*.md exclusion rule once in the
                    #      App Store Connect UI (the workflow is created unlocked,
                    #      so the edit affordance is active).
                    #   2. Read the real shape back:
                    #        GET /v1/ciWorkflows/<id>
                    #      and inspect branchStartCondition.filesAndFoldersRule
                    #      in the response.
                    #   3. Encode the real shape here and commit it, so future
                    #      re-creations set the rule via the API.
                    "filesAndFoldersRule": None,
                    "autoCancel": True,
                },
                "actions": [
                    {
                        "name": "Archive iOS",
                        "actionType": "ARCHIVE",
                        "destination": None,
                        # INTERNAL_ONLY: the pipeline's explicit policy decision.
                        # Valid values from Apple are INTERNAL_ONLY and
                        # APP_STORE_ELIGIBLE. (A third value was rejected by Apple as invalid.)
                        #
                        # PERMANENT CONSEQUENCE: a build archived as INTERNAL_ONLY
                        # can NEVER be promoted to external testing or submitted
                        # to the App Store — it is permanently restricted to
                        # internal tester groups. This is intentional: real iOS
                        # App Store submissions use swiftui/archive_appstore.sh,
                        # not this pipeline. If APP_STORE_ELIGIBLE is ever needed,
                        # PATCH the workflow and produce a NEW build; existing
                        # INTERNAL_ONLY builds stay ineligible forever.
                        "buildDistributionAudience": "INTERNAL_ONLY",
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
    ap.add_argument(
        "--lock",
        action="store_true",
        default=False,
        help=(
            "PATCH isLockedForEditing to true on --update-id. "
            "Run this AFTER adding the TestFlight post-action and notifications "
            "in the App Store Connect UI (a locked workflow is read-only in the UI). "
            "Requires --update-id and --write."
        ),
    )
    args = ap.parse_args()

    if args.lock and not args.update_id:
        sys.exit("ERROR: --lock requires --update-id <WORKFLOW_ID>")
    if args.lock and args.dry_run:
        print("(dry run) Would PATCH isLockedForEditing=true on workflow", args.update_id)
        print("  Pass --write to actually send the patch.")
        return

    if not (KEY_ID and ISSUER):
        sys.exit(
            "ERROR: set ASC_KEY_ID and ASC_ISSUER environment variables.\n"
            "  ASC_KEY_ID  : the key ID from App Store Connect (10 chars)\n"
            "  ASC_ISSUER  : the issuer UUID from App Store Connect\n"
            "  ASC_KEY_FILE: optional override for the .p8 path\n"
            "                (default: ~/.appstoreconnect/private_keys/"
            "AuthKey_<ASC_KEY_ID>.p8)"
        )

    # --lock --write: only needs to PATCH one field; skip full discovery.
    if args.lock:
        print(f"== lock workflow {args.update_id} ==")
        print("  Patching isLockedForEditing=true (review eligibility).")
        print("  Confirm ALL THREE UI settings are already configured — the")
        print("  files/folders exclusion rule ('docs/**', '*.md'), the TestFlight")
        print("  post-action (group 'Beta') and failure notifications. A locked")
        print("  workflow cannot be edited, so anything missing stays missing.")
        lock_payload = {
            "data": {
                "type": "ciWorkflows",
                "id": args.update_id,
                "attributes": {"isLockedForEditing": True},
            }
        }
        wf = _call("PATCH", f"ciWorkflows/{args.update_id}", lock_payload)["data"]
        wid = wf["id"]
        locked_val = wf.get("attributes", {}).get("isLockedForEditing")
        print(f"  workflow {wid} isLockedForEditing={locked_val}")
        print("Workflow is now locked (read-only in the UI).")
        return

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

    # Create unlocked so the UI is editable for the mandatory post-action and
    # notification steps. Lock separately with --lock after those are done.
    payload = _build_payload(pid, repo["id"], xcode["id"], mac["id"], locked=False)

    print()
    print("== payload ==")
    print(json.dumps(payload, indent=2))

    print()
    print("== what this script CANNOT set (manual steps required after creation) ==")
    print("  1. Files/folders exclusion rule (exclude 'docs/**' and '*.md').")
    print("     filesAndFoldersRule is sent as null: Apple's CiFilePatternMatcher")
    print("     field names are undocumented. Add it in the UI, then read the real")
    print("     shape back via GET /v1/ciWorkflows/<id> and encode it here.")
    print("  2. TestFlight internal testing post-action with a named group ('Beta').")
    print("     The ARCHIVE action sets buildDistributionAudience=INTERNAL_ONLY,")
    print("     which marks the *build* as internal-only (it can never be promoted")
    print("     to external testing or submitted to the App Store — permanent).")
    print("     INTERNAL_ONLY does NOT by itself attach the build to a TestFlight")
    print("     group; that is the UI post-action step. Whether the post-action")
    print("     then auto-distributes is unverified — Apple's docs are ambiguous.")
    print("     The named group ('Beta') must be selected in the workflow editor.")
    print("  3. Email / Slack failure notifications.")
    print("     Workflow notification settings are not exposed by the ASC REST API.")
    print()
    print("  Ordered steps after --write:")
    print("    1. UI: App Store Connect → Xcode Cloud → iOS Beta (master) → Edit")
    print("           Add the files/folders rule: exclude 'docs/**' and '*.md'")
    print("           Add TestFlight Internal Testing post-action (group 'Beta')")
    print("           Add failure notification (email and/or Slack)")
    print("           All THREE — possible because the workflow is created UNLOCKED.")
    print("    2. script: --lock --update-id <ID> --write  (locks for review eligibility)")
    print("           A locked workflow is read-only in the UI — do this LAST.")

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
    print("NEXT STEPS — complete in order:")
    print()
    print("  1. (UI) Open the workflow in App Store Connect → Xcode Cloud →")
    print("         iOS Beta (master) → Edit, and add all THREE settings:")
    print("         a. Files/folders rule: exclude 'docs/**' and '*.md'")
    print("         b. Post-action: TestFlight Internal Testing → group 'Beta'")
    print("         c. Notification: email on failure (and optionally Slack webhook)")
    print("         The workflow is UNLOCKED so the edit button is active.")
    print("         Do NOT skip (a): after step 2 locks the workflow the exclusion")
    print("         is unreachable, and every docs-only push to master would then")
    print("         archive and upload a pointless build.")
    print()
    print("  2. (script) Lock the workflow once step 1 is done — Apple requires")
    print("     isLockedForEditing=true for review-eligible builds. A locked workflow")
    print("     is read-only in the UI, so this step MUST come after step 1:")
    print(f"       python3 scripts/asc_xcode_cloud_workflow.py \\")
    print(f"         --lock --update-id {wid} --write")
    print()
    print("  3. (UI) Delete the 'SPIKE - validation' throwaway workflow")
    print("     (ID d6ebe935-3298-4b47-831a-b03af5ec4fe2) once the production")
    print("     workflow has produced its first successful archive.")


if __name__ == "__main__":
    main()
