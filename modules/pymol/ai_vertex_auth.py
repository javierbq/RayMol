"""Vertex AI authentication via service account JSON.

Generates OAuth2 access tokens from a Google Cloud service account key file
using RS256-signed JWTs. Caches tokens until near expiry.

Requires the `cryptography` library for RSA signing.
Falls back to `gcloud auth print-access-token` if unavailable.
"""

import json
import base64
import time
import urllib.parse
import urllib.request
import urllib.error
import subprocess

_HAS_CRYPTO = False
try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    _HAS_CRYPTO = True
except ImportError:
    pass

# Token cache
_cached_token = None
_cached_expiry = 0
_cached_sa_path = None

_TOKEN_LIFETIME = 3600  # 1 hour
_TOKEN_MARGIN = 300     # refresh 5 min before expiry


def _b64url(data):
    """Base64url encode without padding."""
    if isinstance(data, str):
        data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def _create_jwt(sa_info):
    """Create a signed JWT for Google OAuth2 token exchange."""
    now = int(time.time())

    header = _b64url(json.dumps({
        'alg': 'RS256',
        'typ': 'JWT',
    }))

    claims = _b64url(json.dumps({
        'iss': sa_info['client_email'],
        'scope': 'https://www.googleapis.com/auth/cloud-platform',
        'aud': sa_info.get('token_uri', 'https://oauth2.googleapis.com/token'),
        'iat': now,
        'exp': now + _TOKEN_LIFETIME,
    }))

    signing_input = header + b'.' + claims

    # Sign with RSA-SHA256
    private_key = serialization.load_pem_private_key(
        sa_info['private_key'].encode('utf-8'),
        password=None,
    )
    signature = private_key.sign(
        signing_input,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )

    return signing_input + b'.' + _b64url(signature)


def _exchange_jwt_for_token(jwt_bytes, token_uri):
    """Exchange a signed JWT for an OAuth2 access token."""
    data = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': jwt_bytes.decode('ascii'),
    }).encode('utf-8')

    req = urllib.request.Request(
        token_uri,
        data=data,
        headers={'Content-Type': 'application/x-www-form-urlencoded'},
        method='POST',
    )

    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.loads(resp.read().decode('utf-8'))

    return result['access_token'], result.get('expires_in', _TOKEN_LIFETIME)


def _token_from_sa_info(sa_info):
    """Generate an access token from parsed service account info dict."""
    token_uri = sa_info.get('token_uri', 'https://oauth2.googleapis.com/token')
    jwt = _create_jwt(sa_info)
    token, expires_in = _exchange_jwt_for_token(jwt, token_uri)
    return token, time.time() + expires_in


def _token_from_sa_json(sa_path):
    """Generate an access token from a service account JSON file."""
    with open(sa_path) as f:
        sa_info = json.load(f)
    return _token_from_sa_info(sa_info)


def _token_from_gcloud():
    """Get an access token via gcloud CLI (fallback)."""
    try:
        result = subprocess.run(
            ['gcloud', 'auth', 'print-access-token'],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            token = result.stdout.strip()
            # gcloud tokens last ~1 hour
            return token, time.time() + _TOKEN_LIFETIME
    except Exception:
        pass
    return None, 0


def get_access_token_from_data(sa_json_str):
    """Get a valid OAuth2 access token from raw SA JSON string.

    Args:
        sa_json_str: Raw JSON string of the service account key.

    Returns:
        Access token string, or empty string on failure.
    """
    global _cached_token, _cached_expiry, _cached_sa_path

    cache_key = 'data:' + sa_json_str[:40]
    if (_cached_token
            and _cached_sa_path == cache_key
            and time.time() < _cached_expiry - _TOKEN_MARGIN):
        return _cached_token

    if not _HAS_CRYPTO:
        print("[ai_vertex_auth] cryptography library not available")
        return ''

    try:
        sa_info = json.loads(sa_json_str)
        token, expiry = _token_from_sa_info(sa_info)
    except Exception as e:
        print(f"[ai_vertex_auth] SA auth failed: {e}")
        return ''

    _cached_token = token
    _cached_expiry = expiry
    _cached_sa_path = cache_key
    return token


def get_access_token(sa_json_path=''):
    """Get a valid OAuth2 access token for Vertex AI.

    Args:
        sa_json_path: Path to service account JSON file. If empty, falls back
                      to gcloud CLI.

    Returns:
        Access token string, or empty string on failure.
    """
    global _cached_token, _cached_expiry, _cached_sa_path

    # Return cached token if still valid
    if (_cached_token
            and _cached_sa_path == sa_json_path
            and time.time() < _cached_expiry - _TOKEN_MARGIN):
        return _cached_token

    token = None
    expiry = 0

    if sa_json_path and _HAS_CRYPTO:
        try:
            token, expiry = _token_from_sa_json(sa_json_path)
        except Exception as e:
            print(f"[ai_vertex_auth] SA JSON auth failed: {e}")
    elif sa_json_path and not _HAS_CRYPTO:
        print("[ai_vertex_auth] cryptography library not available, trying gcloud CLI")

    if not token:
        token, expiry = _token_from_gcloud()

    if token:
        _cached_token = token
        _cached_expiry = expiry
        _cached_sa_path = sa_json_path
        return token

    return ''


def parse_sa_json(path):
    """Parse a service account JSON file and return summary info.

    Returns dict with project_id, client_email, or empty dict on error.
    """
    try:
        with open(path) as f:
            sa = json.load(f)
        return {
            'project_id': sa.get('project_id', ''),
            'client_email': sa.get('client_email', ''),
        }
    except Exception:
        return {}


def clear_cache():
    """Clear the cached token."""
    global _cached_token, _cached_expiry, _cached_sa_path
    _cached_token = None
    _cached_expiry = 0
    _cached_sa_path = None
