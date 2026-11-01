#!/usr/bin/env python3
"""App Store Connect API client shared by the self-hosted beta pipeline.

Credentials are the same files the release skills use:
  ~/.appstoreconnect/raymol_telemetry.env      ASC_KEY_ID, ASC_ISSUER
  ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
ASC_ENV_FILE / ASC_KEY_DIR override those paths.

PyJWT is imported only when a token is minted, so the offline unit tests
(scripts/tests/asc_tools_test.py) run on a stock python3.
"""
import json
import os
import time
import urllib.error
import urllib.request

BASE = "https://api.appstoreconnect.apple.com"
RAYMOL_APP_ID = "6781513038"


def _paths():
    home = os.path.expanduser("~/.appstoreconnect")
    return (os.environ.get("ASC_ENV_FILE", os.path.join(home, "raymol_telemetry.env")),
            os.environ.get("ASC_KEY_DIR", os.path.join(home, "private_keys")))


def load_env(path):
    """Parse KEY=value lines (optionally `export`-prefixed and quoted) without
    executing the file."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip().strip("'\"")
    return out


def credentials():
    env_file, key_dir = _paths()
    env = load_env(env_file)
    key_id, issuer = env["ASC_KEY_ID"], env["ASC_ISSUER"]
    return key_id, issuer, os.path.join(key_dir, f"AuthKey_{key_id}.p8")


def token():
    import jwt  # PyJWT + cryptography; see docs/ci/selfhosted-beta-runner.md

    key_id, issuer, key_path = credentials()
    with open(key_path) as f:
        private_key = f.read()
    now = int(time.time())
    return jwt.encode({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
                      private_key, algorithm="ES256", headers={"kid": key_id})


def request(method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise SystemExit(f"ASC {method} {path} -> HTTP {e.code}: {detail}")
    return json.loads(raw) if raw else {}


def get(path):
    return request("GET", path)
