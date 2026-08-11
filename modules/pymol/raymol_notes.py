"""Analysis Notes payload embedded directly in RayMol ``.pse`` sessions.

The PyMOL session dictionary is intentionally extensible.  RayMol stores the
JSON note document under ``raymol_notes`` and keeps linked images in a nested
dictionary keyed by their MD5 digest.  Older PyMOL versions ignore this key.
"""

import base64
import hashlib
import json
import os


SESSION_KEY = "raymol_notes"
_payload = None


def _safe_name(value):
    name = os.path.basename(str(value or ""))
    return name if name not in ("", ".", "..") else None


def stage(document_path, assets_directory):
    """Stage the live Swift note document for the next PyMOL session save."""
    global _payload
    with open(document_path, "r", encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict):
        raise ValueError("Analysis Notes document must be a JSON object")

    assets = {}
    if os.path.isdir(assets_directory):
        for entry in os.listdir(assets_directory):
            name = _safe_name(entry)
            if not name:
                continue
            path = os.path.join(assets_directory, name)
            if not os.path.isfile(path):
                continue
            with open(path, "rb") as handle:
                data = handle.read()
            digest = hashlib.md5(data).hexdigest()
            assets[digest] = {
                "file_name": name,
                "data": base64.b64encode(data).decode("ascii"),
            }

    _payload = {
        "version": int(document.get("version", 1)),
        "markdown": str(document.get("text", "")),
        "document": document,
        "assets": assets,
    }
    return 1


def export(document_path, assets_directory):
    """Materialize the restored payload into RayMol's temporary working area."""
    if not isinstance(_payload, dict):
        return 0
    document = _payload.get("document")
    if not isinstance(document, dict):
        document = {
            "version": int(_payload.get("version", 1)),
            "updatedAt": "1970-01-01T00:00:00Z",
            "text": str(_payload.get("markdown", "")),
        }
    os.makedirs(os.path.dirname(document_path), exist_ok=True)
    os.makedirs(assets_directory, exist_ok=True)
    with open(document_path, "w", encoding="utf-8") as handle:
        json.dump(document, handle, ensure_ascii=False, sort_keys=True)

    for value in (_payload.get("assets") or {}).values():
        if not isinstance(value, dict):
            continue
        name = _safe_name(value.get("file_name"))
        encoded = value.get("data")
        if not name or not isinstance(encoded, str):
            continue
        try:
            data = base64.b64decode(encoded, validate=True)
        except Exception:
            continue
        with open(os.path.join(assets_directory, name), "wb") as handle:
            handle.write(data)
    return 1


def clear():
    global _payload
    _payload = None


def session_save(session, **_kwargs):
    if isinstance(_payload, dict):
        session[SESSION_KEY] = _payload
    return 1


def session_restore(session, **_kwargs):
    global _payload
    value = session.get(SESSION_KEY)
    _payload = value if isinstance(value, dict) else None
    return 1
