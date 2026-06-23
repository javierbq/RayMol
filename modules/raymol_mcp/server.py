"""Built-in MCP server for RayMol (stdlib-only, localhost, token-authed).

Runs an http.server.ThreadingHTTPServer on 127.0.0.1 inside the embedded
interpreter on a daemon thread. Speaks MCP "Streamable HTTP": JSON-RPC 2.0 over
HTTP POST to /mcp, answered with a single application/json response (no SSE).

Threading: tool bodies call PyMOL's cmd API from this server thread. Safe because
this is a real Python thread holding the GIL/API lock -- the model the old Raymond
worker used. Never call the C bridge from here.
"""

import json
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from raymol_mcp import events, tools

PROTOCOL_VERSION = "2025-06-18"
SERVER_INFO = {"name": "raymol", "version": "1.0.0"}
INSTRUCTIONS = (
    "RayMol is a molecular visualization app (a PyMOL fork). You drive it via "
    "these tools. Use run_pymol_command for single PyMOL statements (fetch, show, "
    "color, set; pass async=0 on fetch/load so it blocks), and run_python for "
    "multi-step logic with the 'cmd' API (plus numpy as np and Bio when "
    "available); state persists across run_python calls. Call get_session_state to "
    "see loaded objects and the camera, and capture_viewport to see the current "
    "view as an image. search_pdb finds PDB IDs to fetch. Prefer making one change "
    "at a time and capturing the viewport to verify results."
)

# A session is dropped after this many seconds with no request. Claude Code sends no keepalive when idle, so 300s avoids flapping the count during normal between-task idleness; the desktop bridge sends an explicit DELETE on quit for instant cleanup.
SESSION_TTL = 300.0
SWEEP_INTERVAL = 20.0

_lock = threading.Lock()
_httpd = None
_thread = None
_port = None
_token = None
_sessions = {}  # sid -> last_seen (monotonic)
_trusted = False
_stop_sweeper = threading.Event()
_sweeper = None


def set_trusted(value):
    global _trusted
    _trusted = bool(value)


def _touch(sid):
    if sid:
        _sessions[sid] = time.monotonic()


def _prune_idle(now=None):
    now = time.monotonic() if now is None else now
    dead = [s for s, t in list(_sessions.items()) if now - t > SESSION_TTL]
    for s in dead:
        _sessions.pop(s, None)
        events.client_disconnected(s)
    return dead


def _sweep_loop():
    while not _stop_sweeper.wait(SWEEP_INTERVAL):
        try:
            _prune_idle()
        except Exception:
            pass  # never let a sweep error kill the thread


def _summary(name, args):
    if name == "run_pymol_command":
        return args.get("command", "command")
    if name == "search_pdb":
        return "search PDB: %s" % args.get("query", "")
    return {"run_python": "run_python",
            "get_session_state": "read session state",
            "capture_viewport": "capture viewport"}.get(name, name)


def _ok(req_id, result):
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def _err(req_id, code, message):
    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": code, "message": message}}


def handle_jsonrpc(message, session_id):
    method = message.get("method")
    req_id = message.get("id")

    if method == "notifications/initialized":
        return None
    if method == "initialize":
        client_ver = (message.get("params") or {}).get("protocolVersion")
        version = client_ver if client_ver == PROTOCOL_VERSION else PROTOCOL_VERSION
        return _ok(req_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER_INFO,
            "instructions": INSTRUCTIONS,
        })
    if method == "ping":
        return _ok(req_id, {})
    if method == "tools/list":
        return _ok(req_id, {"tools": tools.TOOLS})
    if method == "tools/call":
        if not _trusted:
            return _ok(req_id, {"content": [{"type": "text",
                "text": "RayMol is waiting for the user to approve this connection. "
                        "Ask the user to click Allow in RayMol, then retry."}],
                "isError": True})
        params = message.get("params") or {}
        name = params.get("name", ""); args = params.get("arguments") or {}
        events.action_start(_summary(name, args))
        result = tools.call(name, args)
        events.action_end(not result.get("isError", False))
        return _ok(req_id, result)
    if req_id is None:
        return None  # unknown notification: ignore
    return _err(req_id, -32601, "method not found: %s" % method)


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass  # silence default stderr logging

    def _authed(self):
        return self.headers.get("Authorization", "") == "Bearer %s" % _token

    def _reject(self, code, text):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.rstrip("/") != "/mcp":
            return self._reject(404, "not found")
        if not self._authed():
            return self._reject(401, "unauthorized")

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            message = json.loads(raw.decode("utf-8"))
        except Exception:
            return self._reject(400, "invalid json")

        session_id = self.headers.get("Mcp-Session-Id")
        is_init = isinstance(message, dict) and message.get("method") == "initialize"
        if is_init:
            session_id = uuid.uuid4().hex
            _sessions[session_id] = time.monotonic()
            events.client_connected(session_id)
        elif session_id and session_id in _sessions:
            _touch(session_id)

        response = handle_jsonrpc(message, session_id or "")

        if response is None:
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        body = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if is_init and session_id:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        if not self._authed():
            return self._reject(401, "unauthorized")
        session_id = self.headers.get("Mcp-Session-Id")
        if session_id and session_id in _sessions:
            _sessions.pop(session_id, None)
            events.client_disconnected(session_id)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()


def start(port, token):
    global _httpd, _thread, _port, _token, _trusted, _sweeper, _stop_sweeper
    with _lock:
        if _httpd is not None:
            return _port
        _token = token
        _trusted = False
        bind_port = port if port else 0
        _httpd = ThreadingHTTPServer(("127.0.0.1", bind_port), _Handler)
        _port = _httpd.server_address[1]
        _thread = threading.Thread(target=_httpd.serve_forever,
                                   name="raymol-mcp", daemon=True)
        _thread.start()
        _stop_sweeper.clear()
        _sweeper = threading.Thread(target=_sweep_loop,
                                    name="raymol-mcp-sweep", daemon=True)
        _sweeper.start()
        events.server_started(_port)
        return _port


def stop():
    global _httpd, _thread, _port, _sessions, _trusted, _sweeper, _stop_sweeper
    with _lock:
        if _httpd is None:
            return
        _stop_sweeper.set()
        sids = list(_sessions.keys())
        _sessions = {}                      # cleared first: a waking sweeper finds nothing
        _httpd.shutdown()
        _httpd.server_close()
        worker = _thread
        sweeper = _sweeper
        _httpd = None
        _thread = None
        _sweeper = None
        _port = None
        _trusted = False
        if worker is not None:
            worker.join(timeout=2)
        if sweeper is not None:
            sweeper.join(timeout=2)
        for s in sids:
            events.client_disconnected(s)
        events.server_stopped()


def status():
    return {"running": _httpd is not None, "port": _port, "clients": len(_sessions)}
