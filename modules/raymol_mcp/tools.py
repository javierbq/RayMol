"""MCP tool definitions + dispatcher for the RayMol MCP server.

Tools call PyMOL's ``cmd`` API directly, imported LAZILY inside functions so this
module imports standalone (for unit tests) without a built PyMOL. They run on the
MCP server's Python thread (a real threading.Thread), so cmd's API lock serialises
access safely -- the same model the old Raymond worker used. Never call the C
bridge (PyMOLBridge_*) from here; only the Python ``cmd`` API.

``capture_viewport`` renders with the CPU ray-tracer (cmd.ray) because cmd.png
without ray reads a GL framebuffer the Metal app does not have.
"""

import base64
import contextlib
import io
import json
import os
import tempfile
import threading
import traceback
import urllib.parse
import urllib.request

# Persistent namespace for run_python; seeded on first use.
_py_ns = None
_py_ns_lock = threading.Lock()


def _namespace():
    global _py_ns
    with _py_ns_lock:
        if _py_ns is None:
            from pymol import cmd
            ns = {"__name__": "__mcp_exec__", "cmd": cmd}
            try:
                import numpy as np
                ns["np"] = np
            except Exception:
                pass
            try:
                import Bio
                ns["Bio"] = Bio
            except Exception:
                pass
            _py_ns = ns
    return _py_ns


def _text(s):
    return {"content": [{"type": "text", "text": str(s)}], "isError": False}


def _error(s):
    return {"content": [{"type": "text", "text": str(s)}], "isError": True}


# --- Tool implementations -------------------------------------------------

def _run_pymol_command(args):
    cmd_str = args.get("command", "")
    if not cmd_str:
        return _error("missing 'command'")
    from pymol import cmd
    try:
        cmd.do(cmd_str)
        cmd.sync()
        return _text("ok")
    except Exception:
        return _error(traceback.format_exc())


def _run_python(args):
    code = args.get("code", "")
    if not code:
        return _error("missing 'code'")
    ns = _namespace()
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            exec(code, ns)
        from pymol import cmd
        cmd.sync()
        out = buf.getvalue()
        return _text(out if out else "ok")
    except Exception:
        return _error(buf.getvalue() + "\n" + traceback.format_exc())


def _get_session_state(args):
    from pymol import cmd
    try:
        objects = []
        for name in cmd.get_names("objects"):
            objects.append({
                "name": name,
                "type": cmd.get_type(name),
                "atoms": cmd.count_atoms("(%s)" % name),
            })
        state = {
            "objects": objects,
            "selections": cmd.get_names("selections"),
            "view": list(cmd.get_view()),
            "frame": cmd.get_frame(),
            "n_frames": cmd.count_frames(),
        }
        return _text(json.dumps(state, indent=2))
    except Exception:
        return _error(traceback.format_exc())


def _capture_viewport(args):
    from pymol import cmd
    path = None
    try:
        width = int(args.get("width", 640))
        height = int(args.get("height", 480))
        fd, path = tempfile.mkstemp(suffix=".png", prefix="raymol_mcp_capture_")
        os.close(fd)
        # ray=1 ray-traces and writes the PNG in one synchronous call. A separate
        # cmd.ray + cmd.png(prior=1) fails with "no prior image available" when
        # driven from the MCP server thread.
        cmd.png(path, width=width, height=height, ray=1)
        with open(path, "rb") as f:
            data = base64.b64encode(f.read()).decode("ascii")
        return {"content": [{"type": "image", "data": data,
                             "mimeType": "image/png"}], "isError": False}
    except Exception:
        return _error(traceback.format_exc())
    finally:
        if path:
            try:
                os.remove(path)
            except OSError:
                pass


def _search_pdb(args):
    query = args.get("query", "")
    if not query:
        return _error("missing 'query'")
    try:
        limit = int(args.get("limit", 10))
        body = {
            "query": {"type": "terminal", "service": "full_text",
                      "parameters": {"value": query}},
            "return_type": "entry",
            "request_options": {"paginate": {"start": 0, "rows": limit}},
        }
        url = ("https://search.rcsb.org/rcsbsearch/v2/query?json="
               + urllib.parse.quote(json.dumps(body)))
        with urllib.request.urlopen(url, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        ids = [r["identifier"] for r in data.get("result_set", [])]
        return _text(json.dumps({"pdb_ids": ids}, indent=2))
    except Exception:
        return _error(traceback.format_exc())


# --- Registry + dispatcher ------------------------------------------------

TOOLS = [
    {
        "name": "run_pymol_command",
        "description": ("Run one PyMOL command-language statement (e.g. "
                        "'fetch 1ubq, async=0', 'show cartoon', "
                        "'color red, chain A'). For multi-step logic or data "
                        "access, prefer run_python."),
        "inputSchema": {
            "type": "object",
            "properties": {"command": {"type": "string"}},
            "required": ["command"],
        },
    },
    {
        "name": "run_python",
        "description": ("Execute arbitrary Python in a persistent namespace with "
                        "'cmd' (the PyMOL API), and 'np'/'Bio' if available. "
                        "State persists across calls. stdout is returned. This is "
                        "the most powerful tool -- prefer it for anything beyond a "
                        "single command."),
        "inputSchema": {
            "type": "object",
            "properties": {"code": {"type": "string"}},
            "required": ["code"],
        },
    },
    {
        "name": "get_session_state",
        "description": ("Return the current session as JSON: objects "
                        "(name/type/atom count), named selections, camera view "
                        "(18 floats), current frame and frame count."),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "capture_viewport",
        "description": ("Ray-trace the current view and return it as a PNG image "
                        "so you can see the structure. Optional width/height "
                        "(default 640x480). CPU ray-tracing may take a moment."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "width": {"type": "integer", "default": 640},
                "height": {"type": "integer", "default": 480},
            },
        },
    },
    {
        "name": "search_pdb",
        "description": ("Full-text search of the RCSB PDB; returns matching PDB "
                        "IDs. Use run_pymol_command 'fetch <id>, async=0' to load "
                        "one."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer", "default": 10},
            },
            "required": ["query"],
        },
    },
]

_DISPATCH = {
    "run_pymol_command": _run_pymol_command,
    "run_python": _run_python,
    "get_session_state": _get_session_state,
    "capture_viewport": _capture_viewport,
    "search_pdb": _search_pdb,
}


def call(name, arguments):
    fn = _DISPATCH.get(name)
    if fn is None:
        return _error("unknown tool: %s" % name)
    try:
        return fn(arguments or {})
    except Exception:
        return _error(traceback.format_exc())
