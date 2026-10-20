"""MCP tool definitions + dispatcher for the RayMol MCP server.

Tools call PyMOL's ``cmd`` API, imported LAZILY inside functions so this module
imports standalone (for unit tests) without a built PyMOL. Handlers run on the
MCP server's HTTP request-handler threads, but every ``cmd``-touching body is
run via ``mainthread.run_on_main`` so it executes on the app's MAIN thread — the
only thread where the embedded core is safe to touch (it races
``SceneRenderMetal`` otherwise; see mainthread.py). Never call the C bridge
(PyMOLBridge_*) from here; only the Python ``cmd`` API.

The general tools are defined here; RayMol's own (lighting, materials, Metal
effects, export, on-device prediction, help) are in native.py, and
``list_tools``/``call`` serve both.

``capture_viewport``: in the app it renders through the Metal Save Image path (`exporting._metal_png`
-> `_cmd.metal_png` -> the bridge's registered `PyMOLBridge_RenderHiResPNG`, on
the main thread), so the image is what the user sees, studio lights included;
with no Metal renderer (pip/GLUT build, headless) it falls back to the CPU ray
tracer (cmd.png ray=1), which uses PyMOL's lights, and a text note follows the
image when a rig is on (#626, #643).
"""

import base64
import contextlib
import io
import json
import os
import sys
import tempfile
import threading
import traceback
import urllib.parse
import urllib.request

from raymol_mcp import native
from raymol_mcp.mainthread import run_on_main

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

    def _body():
        from pymol import cmd
        cmd.do(cmd_str)
        cmd.sync()
        return _text("ok")

    try:
        return native.with_habit_notes(run_on_main(_body), cmd_str)
    except Exception:
        return _error(traceback.format_exc())


class _TeeStdout:
    """Write to the real stdout AND capture into ``buf``.

    The core's feedback sink reads the app's real stdout, and the Swift host
    acts on marker lines printed there (``PREDICT:submit:<job>`` from
    predictors/host.py, ...). A bare ``redirect_stdout(buf)`` swallowed them,
    so a job submitted through run_python was never started (#596).
    """

    def __init__(self, real, buf):
        self._real = real
        self._buf = buf

    def write(self, s):
        self._buf.write(s)
        if self._real is not None:
            self._real.write(s)
        return len(s)

    def flush(self):
        if self._real is not None:
            self._real.flush()

    def __getattr__(self, name):
        return getattr(self._real, name)


def _run_python(args):
    code = args.get("code", "")
    if not code:
        return _error("missing 'code'")

    def _body():
        ns = _namespace()
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(_TeeStdout(sys.stdout, buf)):
                exec(code, ns)
            from pymol import cmd
            cmd.sync()
            out = buf.getvalue()
            return _text(out if out else "ok")
        except Exception:
            return _error(buf.getvalue() + "\n" + traceback.format_exc())

    try:
        return native.with_habit_notes(run_on_main(_body), code)
    except Exception:
        return _error(traceback.format_exc())


def _get_session_state(args):
    def _body():
        from pymol import cmd
        objects = []
        for name in cmd.get_names("objects"):
            otype = cmd.get_type(name)
            # Only molecule objects are valid atom-selections. A measurement,
            # map, CGO or group name fed to count_atoms('(name)') raises a C++
            # "Invalid selection name" Selector-Error (same gotcha metal_pick.py
            # documents), which would otherwise abort the whole call.
            objects.append({
                "name": name,
                "type": otype,
                "atoms": (cmd.count_atoms("(%s)" % name)
                          if otype == "object:molecule" else 0),
            })
        state = {
            "objects": objects,
            "selections": cmd.get_names("selections"),
            "view": list(cmd.get_view()),
            "frame": cmd.get_frame(),
            "n_frames": cmd.count_frames(),
            # Lights, effects, materials, scenes and jobs: showing them is
            # how an agent learns RayMol has them.
            "raymol": native.raymol_state(cmd),
        }
        return _text(json.dumps(state, indent=2, default=str))

    try:
        return run_on_main(_body)
    except Exception:
        return _error(traceback.format_exc())


def _capture_viewport(args):
    path = None
    try:
        # Clamp to a sane maximum: width/height come straight from the caller and
        # bound the render (GPU or CPU), so an unbounded size is a DoS.
        width = max(1, min(int(args.get("width", 640)), 2048))
        height = max(1, min(int(args.get("height", 480)), 2048))
        fd, path = tempfile.mkstemp(suffix=".png", prefix="raymol_mcp_capture_")
        os.close(fd)

        # Runs on the main thread (touches the scene/renderer); the tempfile
        # create/read/cleanup stay off-main.
        def _render():
            from pymol import cmd, exporting, lighting
            # In the app: the Metal Save Image render, i.e. what the user sees
            # (studio lights, shadows, air, Metal ray tracing). WYSIWYG: ray=-1.
            if exporting._metal_png(path, width, height) and \
                    os.path.getsize(path) > 0:
                return None
            # No Metal renderer (pip/GLUT, headless, or the app before its
            # first frame): the CPU tracer, which keeps PyMOL's lights.
            # ray=1 ray-traces and writes the PNG in one synchronous call; a
            # separate cmd.ray + cmd.png(prior=1) fails with "no prior image
            # available" when driven from the MCP server thread. The rig's
            # notice (#626) is read in the same main-thread call, so the rig
            # cannot change in between.
            cmd.png(path, width=width, height=height, ray=1)
            return lighting._lights_ray_notice()
        notice = run_on_main(_render)

        with open(path, "rb") as f:
            data = base64.b64encode(f.read()).decode("ascii")
        # The image stays first: clients read content[0].
        content = [{"type": "image", "data": data, "mimeType": "image/png"}]
        if notice:
            content.append({"type": "text", "text": "Note: " + notice})
        return {"content": content, "isError": False}
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
                        "access, prefer run_python. For RayMol's lighting, "
                        "materials, render effects, export and prediction, "
                        "the dedicated tools are simpler."),
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
                        "State persists across calls. stdout is returned. Use it "
                        "for multi-step logic and data access; RayMol features "
                        "also have their own cmd functions (cmd.lights, "
                        "cmd.atmosphere, cmd.predict, cmd.movie_export, ...)."),
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
                        "(18 floats), current frame and frame count, and "
                        "'raymol': the studio light rig and atmosphere, Metal "
                        "render effects, materials, scenes and on-device "
                        "prediction jobs."),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "capture_viewport",
        "description": ("Render the current view and return it as a PNG image "
                        "so you can see the structure. Optional width/height "
                        "(default 640x480). In the RayMol app it uses the "
                        "app's Metal renderer, so the image is what the user "
                        "sees, studio lights (set_lights) included. Without a "
                        "Metal view (headless) it falls back to the CPU ray "
                        "tracer, which may take a moment and uses PyMOL's "
                        "lights; a text note then follows the image when a "
                        "rig is on."),
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


def list_tools():
    """Every tool this server offers: the general ones, then RayMol's own."""
    return TOOLS + native.tools()


def call(name, arguments):
    fn = _DISPATCH.get(name) or native.DISPATCH.get(name)
    if fn is None:
        return _error("unknown tool: %s" % name)
    try:
        return fn(arguments or {})
    except Exception:
        return _error(traceback.format_exc())
