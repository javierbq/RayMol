"""On-device Vertex AI access-token minting from a service-account JSON key.

gcloud-printed access tokens expire after ~1h, which is painful on a mobile
device with no shell. This module lets the user paste a Google service-account
JSON key once; we then mint (and transparently refresh) short-lived Vertex AI
OAuth access tokens entirely on-device, with NO dependency on google-auth or
the `cryptography` package (both impractical on iOS — google-auth pulls in
cryptography, which is Rust-based and ships no iOS wheels).

The flow is the standard OAuth 2.0 JWT-bearer grant (RFC 7523), implemented
with the pure-Python `rsa` + `pyasn1` packages (bundled like numpy):

  1. Load the SA `private_key` (a PKCS#8 PEM). base64-decode the PEM body to
     DER, pyasn1-decode the PrivateKeyInfo SEQUENCE, take the OCTET STRING at
     index 2 (the wrapped PKCS#1 RSAPrivateKey), and
     rsa.PrivateKey.load_pkcs1(inner, format='DER').
  2. Build a signed JWT assertion (RS256) whose claims request the
     cloud-platform scope for the SA (iss = client_email, aud = token_uri).
  3. POST the assertion to the token endpoint; parse {access_token, expires_in}.
  4. Cache the token and refresh ~5 min before expiry.

Only the standard library + rsa + pyasn1 are imported. If the latter two are
unavailable (e.g. an old bundle that didn't ship them), mint() raises a clear
RuntimeError that ai_chat surfaces to the user.
"""

import json
import time
import base64
import threading
import urllib.request
import urllib.error

# Refresh this many seconds BEFORE the token's stated expiry so an in-flight
# request can't race the expiry boundary.
_REFRESH_SKEW = 300  # 5 minutes

# Default Google OAuth token endpoint (overridden by the SA JSON's token_uri).
_DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token'

# The scope a Vertex AI rawPredict call needs.
_SCOPE = 'https://www.googleapis.com/auth/cloud-platform'


def _b64url(data):
    """URL-safe base64 WITHOUT padding (JWT segment encoding)."""
    if isinstance(data, str):
        data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _load_pkcs8_rsa_key(private_key_pem):
    """Load a PKCS#8 PEM RSA private key using ONLY rsa + pyasn1.

    Returns an rsa.PrivateKey. Raises RuntimeError with a clear message if the
    pure-Python crypto packages are missing or the key can't be parsed.
    """
    try:
        import rsa as _rsa
        from pyasn1.codec.der import decoder as _der_decoder
    except ImportError as exc:
        raise RuntimeError(
            "On-device token minting needs the pure-Python 'rsa' and 'pyasn1' "
            "packages, which are not available in this build. Paste a GCP "
            "access token instead (gcloud auth print-access-token)."
        ) from exc

    # Strip the PEM armor and whitespace; keep only the base64 body lines.
    body = ''.join(
        line.strip()
        for line in private_key_pem.splitlines()
        if line.strip() and 'PRIVATE KEY' not in line
    )
    try:
        der = base64.b64decode(body)
    except Exception as exc:
        raise RuntimeError("Service-account private_key is not valid base64 PEM.") from exc

    try:
        # PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
        info, _ = _der_decoder.decode(der)
        inner = info[2].asOctets()  # the wrapped PKCS#1 RSAPrivateKey (DER)
        return _rsa.PrivateKey.load_pkcs1(inner, format='DER')
    except Exception as exc:
        raise RuntimeError(
            "Could not parse the service-account RSA private key (expected an "
            "unencrypted PKCS#8 PEM)."
        ) from exc


def _build_assertion(sa_info, now):
    """Build a signed JWT bearer assertion for the SA, valid for 1 hour."""
    client_email = sa_info.get('client_email', '')
    token_uri = sa_info.get('token_uri') or _DEFAULT_TOKEN_URI
    private_key_pem = sa_info.get('private_key', '')
    if not client_email or not private_key_pem:
        raise RuntimeError(
            "Service-account JSON is missing 'client_email' or 'private_key'.")

    key = _load_pkcs8_rsa_key(private_key_pem)

    header = {"alg": "RS256", "typ": "JWT"}
    # Include the key id when present (harmless, and lets Google pick the cert).
    if sa_info.get('private_key_id'):
        header["kid"] = sa_info['private_key_id']

    claims = {
        "iss": client_email,
        "scope": _SCOPE,
        "aud": token_uri,
        "iat": now,
        "exp": now + 3600,
    }

    signing_input = (
        _b64url(json.dumps(header, separators=(',', ':')))
        + "."
        + _b64url(json.dumps(claims, separators=(',', ':')))
    )

    import rsa as _rsa  # already importable (validated by _load_pkcs8_rsa_key)
    signature = _rsa.sign(signing_input.encode('ascii'), key, 'SHA-256')
    return signing_input + "." + _b64url(signature), token_uri


def _request_access_token(sa_info, now, timeout=30):
    """Exchange a freshly-built JWT assertion for an access token.

    Returns (access_token, expires_at_epoch). Raises RuntimeError on failure.
    """
    assertion, token_uri = _build_assertion(sa_info, now)

    form = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': assertion,
    }).encode('ascii')

    req = urllib.request.Request(
        token_uri,
        data=form,
        headers={'Content-Type': 'application/x-www-form-urlencoded'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode('utf-8'))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode('utf-8', errors='replace')
        raise RuntimeError(f"Token endpoint HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Token endpoint unreachable: {exc.reason}") from exc

    token = payload.get('access_token')
    if not token:
        raise RuntimeError(f"Token endpoint returned no access_token: {payload}")
    expires_in = int(payload.get('expires_in', 3600))
    return token, now + expires_in


# urllib.parse is referenced in _request_access_token; import after the helpers
# so the module top stays a clean list of submodules.
import urllib.parse  # noqa: E402


class VertexTokenMinter:
    """Caches a minted Vertex access token and refreshes it near expiry.

    Keyed on the SA's client_email + private_key_id so changing the pasted SA
    JSON invalidates the cache. Thread-safe (the AI worker runs off-main).
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._token = None
        self._expires_at = 0.0
        self._key_id = None  # (client_email, private_key_id) of the cached token

    def _cache_key(self, sa_info):
        return (sa_info.get('client_email', ''), sa_info.get('private_key_id', ''))

    def mint(self, sa_info):
        """Return a valid access token for *sa_info*, minting/refreshing as needed.

        sa_info: the parsed service-account JSON dict. Raises RuntimeError with a
        user-facing message on any failure (missing fields, bad key, network).
        """
        if not isinstance(sa_info, dict):
            raise RuntimeError("Service-account credentials are not a JSON object.")

        cache_key = self._cache_key(sa_info)
        now = time.time()
        with self._lock:
            if (self._token
                    and self._key_id == cache_key
                    and now < self._expires_at - _REFRESH_SKEW):
                return self._token

            token, expires_at = _request_access_token(sa_info, int(now))
            self._token = token
            self._expires_at = expires_at
            self._key_id = cache_key
            return token

    def invalidate(self):
        """Drop the cached token (e.g. after the SA JSON changes)."""
        with self._lock:
            self._token = None
            self._expires_at = 0.0
            self._key_id = None


# Module-level singleton used by ai_chat.
_minter = VertexTokenMinter()


def mint(sa_info):
    """Convenience wrapper: mint/refresh a token via the module singleton."""
    return _minter.mint(sa_info)


def invalidate():
    """Drop the singleton's cached token."""
    _minter.invalidate()
