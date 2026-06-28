"""Built-in MCP server for RayMol (stdlib-only, localhost, token-authed).

Runs an http.server.ThreadingHTTPServer on 127.0.0.1 inside the embedded
interpreter on a daemon thread. Speaks MCP "Streamable HTTP": JSON-RPC 2.0 over
HTTP POST to /mcp, answered with a single application/json response (no SSE).

Threading: tool bodies call PyMOL's cmd API from this server thread. Safe because
this is a real Python thread holding the GIL/API lock -- the model the old Raymond
worker used. Never call the C bridge from here.
"""

import json
import os
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

_lock = threading.Lock()            # guards server lifecycle (start/stop)
_httpd = None
_thread = None
_port = None
_token = None
_sessions = {}  # sid -> last_seen (monotonic)
# Guards _sessions, mutated from request-handler threads + the sweeper thread.
# Lock rules: never hold it across events.* (which does blocking stdout I/O) or
# httpd.shutdown(); if both locks are needed, take _lock first (never nest _lock
# inside _sessions_lock) — request handlers only ever take _sessions_lock.
_sessions_lock = threading.Lock()
_trusted = False
_stop_sweeper = threading.Event()
_sweeper = None


def set_trusted(value):
    global _trusted
    _trusted = bool(value)


def _prune_idle(now=None):
    now = time.monotonic() if now is None else now
    with _sessions_lock:
        dead = [s for s, t in _sessions.items() if now - t > SESSION_TTL]
        for s in dead:
            _sessions.pop(s, None)
    # Emit OUTSIDE the lock (events.* does blocking stdout I/O). pop-then-emit
    # means each sid disconnects exactly once even if do_DELETE races us.
    for s in dead:
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
            with _sessions_lock:
                _sessions[session_id] = time.monotonic()
            # Skip the connect event (which raises the "Allow" prompt) when
            # auto-trust is on for testing — there is nothing to approve.
            if not _trusted:
                events.client_connected(session_id)
        elif session_id:
            # Atomic check-and-touch: refresh last_seen only for a KNOWN session,
            # under one lock so a concurrent sweep can't prune between the
            # membership test and the update (which would resurrect the session).
            with _sessions_lock:
                if session_id in _sessions:
                    _sessions[session_id] = time.monotonic()

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
        # Atomic pop-once so a concurrent sweep can't also pop+emit for this sid
        # (double client_disconnected). Emit outside the lock (blocking I/O).
        existed = False
        if session_id:
            with _sessions_lock:
                existed = _sessions.pop(session_id, None) is not None
        if existed:
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
        # Dev/testing auto-trust: when RAYMOL_MCP_AUTOTRUST=1 is present in the
        # process environment, skip the interactive "Allow" approval. This env var
        # is NEVER set in a shipped build (apps launched via Finder / `open` have
        # no such variable), so production always requires the user's explicit
        # click. Set it only when launching the binary directly for testing.
        _trusted = os.environ.get("RAYMOL_MCP_AUTOTRUST") == "1"
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
        with _sessions_lock:                # cleared first: a waking sweeper finds nothing
            sids = list(_sessions.keys())
            _sessions.clear()
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
    # Emit disconnects/stopped OUTSIDE both locks (events.* does blocking I/O).
    for s in sids:
        events.client_disconnected(s)
    events.server_stopped()


def status():
    with _sessions_lock:
        n = len(_sessions)
    return {"running": _httpd is not None, "port": _port, "clients": n}
