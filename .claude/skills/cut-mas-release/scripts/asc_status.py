#!/usr/bin/env python3
"""Print RayMol's App Store Connect version states + recent builds.

Signs a short-lived ES256 JWT from the ASC API key and queries the ASC API.
Use in Step 1 (check nothing is in review + find the last build number) and
after submit (confirm WAITING_FOR_REVIEW). Also poll after `altool --upload-app`
until the new build shows processingState=VALID before attaching it.

Requires PyJWT + cryptography (both ship with the Homebrew python3 used here):
    /opt/homebrew/bin/python3 -c "import jwt, cryptography"
If missing:  /opt/homebrew/bin/python3 -m pip install pyjwt cryptography

Config via env. The Key ID + Issuer are account identifiers — find them in
ASC ▸ Users and Access ▸ Integrations ▸ App Store Connect API (they're not kept
in this public repo):
    ASC_KEY_ID   required  (the 10-char API key id)
    ASC_ISSUER   required  (the issuer UUID)
    ASC_APP_ID   default 6781513038  (RayMol — public App Store id)
    ASC_KEY_FILE default ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
"""
import json
import os
import sys
import time
import urllib.request

try:
    import jwt  # PyJWT
except ImportError:
    sys.exit("PyJWT not installed: /opt/homebrew/bin/python3 -m pip install pyjwt cryptography")

KEY_ID = os.environ.get("ASC_KEY_ID")   # required — ASC ▸ Users and Access ▸ Integrations
ISSUER = os.environ.get("ASC_ISSUER")   # required — the issuer UUID for that key
APP_ID = os.environ.get("ASC_APP_ID", "6781513038")  # RayMol (public App Store id)
if not KEY_ID or not ISSUER:
    sys.exit(
        "Set ASC_KEY_ID and ASC_ISSUER (find them in ASC ▸ Users and Access ▸ "
        "Integrations ▸ App Store Connect API). The matching private key goes in "
        "~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8"
    )
KEY_FILE = os.environ.get(
    "ASC_KEY_FILE",
    os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"),
)


def _token():
    p8 = open(KEY_FILE).read()
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        p8,
        algorithm="ES256",
        headers={"kid": KEY_ID, "typ": "JWT"},
    )


def _get(url, tok):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def main():
    tok = _token()
    base = "https://api.appstoreconnect.apple.com/v1"

    print("=== App Store versions (state) ===")
    v = _get(
        f"{base}/apps/{APP_ID}/appStoreVersions?limit=8"
        "&fields[appStoreVersions]=versionString,appStoreState,platform,createdDate",
        tok,
    )
    for d in v["data"]:
        a = d["attributes"]
        print(f"  {a.get('platform',''):10} {a.get('versionString',''):8} "
              f"{a.get('appStoreState','')}  ({(a.get('createdDate') or '')[:10]})")

    print("=== recent builds ===")
    b = _get(
        f"{base}/builds?filter[app]={APP_ID}&limit=8&sort=-uploadedDate"
        "&fields[builds]=version,processingState,expired,uploadedDate",
        tok,
    )
    for d in b["data"]:
        a = d["attributes"]
        print(f"  build {a.get('version',''):5} {a.get('processingState',''):12} "
              f"expired={a.get('expired')}  ({(a.get('uploadedDate') or '')[:16]})")


if __name__ == "__main__":
    main()
