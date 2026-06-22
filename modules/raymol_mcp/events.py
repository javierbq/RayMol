"""Tagged feedback emitters for the RayMol MCP server (Python -> Swift).

Each call prints one ``MCP:<kind>:<base64-payload>`` line and flushes stdout.
The line reaches PyMOL's feedback buffer (cmd._get_feedback), which
PyMOLEngine.pollFeedback drains and parses into MCPServerManager state.
Payloads are base64 so they survive the newline split, mirroring ai_chat_swift.
"""

import base64
import sys


def _b64(text):
    return base64.b64encode(str(text).encode("utf-8")).decode("ascii")


def emit(kind, detail=""):
    try:
        print("MCP:%s:%s" % (kind, _b64(detail)))
        sys.stdout.flush()
    except Exception:
        # Never let a delivery failure crash the server thread.
        pass


def server_started(port):
    emit("started", str(port))


def server_stopped():
    emit("stopped", "")


def client_connected(session_id):
    emit("connect", session_id)


def client_disconnected(session_id):
    emit("disconnect", session_id)


def action_start(summary):
    emit("action", summary)


def action_end(ok):
    emit("actionend", "1" if ok else "0")
