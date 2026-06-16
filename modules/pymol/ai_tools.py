"""AI tool definitions and implementations for PyMOL agentic chat.

Defines tools in two formats:
1. Claude Agent SDK format using @tool decorator and create_sdk_mcp_server
2. Legacy Anthropic tool_use schema (TOOL_DEFINITIONS + execute_tool) as fallback

The SDK path is preferred when claude_agent_sdk is installed; otherwise the
legacy path is used automatically.
"""

import asyncio
import json
import base64
import os
import sys
import io
import tempfile
import traceback

# ---------------------------------------------------------------------------
# SDK availability check
# ---------------------------------------------------------------------------

try:
    from claude_agent_sdk import tool, create_sdk_mcp_server, ToolAnnotations
    _HAS_SDK = True
except ImportError:
    _HAS_SDK = False

# ---------------------------------------------------------------------------
# Main-thread helper
# ---------------------------------------------------------------------------

def _run_on_main(func):
    """Run *func* on the main thread, returning its result.

    Tries to import run_on_main_thread from ai_chat_ui (provided by Agent A).
    If unavailable (headless / testing), calls func directly.
    """
    try:
        from pymol.ai_chat_ui import run_on_main_thread
        return run_on_main_thread(func)
    except (ImportError, AttributeError):
        # Fallback: call directly (may deadlock if called from worker thread
        # in a GUI session, but allows headless/test usage).
        return func()


# ---------------------------------------------------------------------------
# Legacy tool definitions (Anthropic tool_use schema format)
# ---------------------------------------------------------------------------

TOOL_DEFINITIONS = [
    {
        "name": "get_session_state",
        "description": (
            "Retrieve the current state of the PyMOL session including all "
            "loaded objects (molecules, maps, groups, etc.) with atom counts, "
            "named selections with atom counts, the current camera view matrix "
            "(18 floats: 9 rotation, 3 position, 3 origin, 3 clipping/fog), "
            "and the viewport dimensions in pixels. Use this tool whenever you "
            "need to understand what the user currently has loaded or how the "
            "scene is oriented."
        ),
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    },
    {
        "name": "run_python",
        "description": (
            "THIS IS HOW YOU ACT. Execute a block of Python code inside the live "
            "PyMOL session and return whatever it printed plus any traceback. The "
            "code runs in a PERSISTENT namespace (variables/imports survive across "
            "calls in this conversation) preloaded with: `cmd` (the PyMOL API — "
            "cmd.fetch, cmd.show, cmd.color, cmd.align, cmd.alter, cmd.get_model, "
            "cmd.do(\"...\") for command-language, etc.), `np` (numpy), `Bio` "
            "(Biopython, if available), and `WORKDIR` (a writable temp directory "
            "string you may read/write). The code RUNS FOR REAL and the scene "
            "updates. Use print(...) to surface values you need (atom counts, "
            "RMSD, residue lists) so you can verify and self-correct. Drive every "
            "action this way: load/fetch, show/hide, color/spectrum, select, "
            "orient/zoom, align/super, set, label, alter, analysis with numpy/Bio, "
            "etc. If something raises, you will see the full traceback — fix it and "
            "try again."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": (
                        "Python source to execute. Example: "
                        "'cmd.fetch(\"1ubq\"); cmd.show_as(\"cartoon\"); "
                        "cmd.util.cbc(); cmd.orient(); "
                        "print(cmd.count_atoms(\"all\"))'"
                    )
                }
            },
            "required": ["code"]
        }
    },
    {
        "name": "capture_viewport",
        "description": (
            "Capture a screenshot of the current PyMOL viewport as a PNG image. "
            "The image is returned as a base64-encoded string. You can optionally "
            "specify width and height in pixels; if omitted the current viewport "
            "size is used. Use this tool when the user asks you to look at, "
            "analyze, or comment on the current visualization."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "width": {
                    "type": "integer",
                    "description": "Image width in pixels. Defaults to current viewport width."
                },
                "height": {
                    "type": "integer",
                    "description": "Image height in pixels. Defaults to current viewport height."
                }
            },
            "required": []
        }
    },
    {
        "name": "search_pdb",
        "description": (
            "Search the RCSB Protein Data Bank for structures matching a text "
            "query. Returns a list of matching PDB entries with their ID, title, "
            "source organism, and resolution. Use this tool when the user asks "
            "about available structures, wants to find a protein, or needs help "
            "choosing which PDB entry to load."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Search query text, e.g. 'human hemoglobin', "
                        "'CRISPR Cas9', 'insulin receptor'."
                    )
                },
                "max_results": {
                    "type": "integer",
                    "description": "Maximum number of results to return (default 5, max 25)."
                }
            },
            "required": ["query"]
        }
    },
]


# ---------------------------------------------------------------------------
# Tool implementations (shared by both SDK and legacy paths)
# ---------------------------------------------------------------------------

def _impl_get_session_state(cmd):
    """Gather objects, selections, view, and viewport from the PyMOL session."""

    def _gather():
        state = {"objects": [], "selections": [], "view": None, "viewport": None}

        # Objects
        try:
            names = cmd.get_names('objects') or []
            for name in names:
                try:
                    obj_type = cmd.get_type(name)
                except Exception:
                    obj_type = "unknown"
                try:
                    count = cmd.count_atoms(name)
                except Exception:
                    count = 0
                state["objects"].append({
                    "name": name,
                    "type": obj_type,
                    "atom_count": count
                })
        except Exception:
            pass

        # Named selections
        try:
            sels = cmd.get_names('public_selections') or []
            for name in sels:
                try:
                    count = cmd.count_atoms(name)
                except Exception:
                    count = 0
                state["selections"].append({
                    "name": name,
                    "atom_count": count
                })
        except Exception:
            pass

        # Camera view (18 floats)
        try:
            view = cmd.get_view()
            state["view"] = list(view)
        except Exception:
            pass

        # Viewport size
        try:
            vp = cmd.get_viewport()
            state["viewport"] = {"width": vp[0], "height": vp[1]}
        except Exception:
            pass

        return state

    return _run_on_main(_gather)


# ---------------------------------------------------------------------------
# Persistent Python execution namespace (one per conversation/process)
# ---------------------------------------------------------------------------
#
# The run_python tool exec()s the model's code in THIS dict so variables,
# imports, and intermediate results persist across tool calls within a session.
# It is built lazily on first use and reused thereafter. WORKDIR is a per-session
# temp directory the model may read/write (created once, reused).

_py_namespace = None


def _get_py_namespace(cmd):
    """Return the persistent run_python namespace, building it on first use.

    Preloads `cmd` (PyMOL API), `np` (numpy, guarded), `Bio` (biopython,
    guarded — a missing Bio must NOT break the tool), and `WORKDIR` (a reusable
    per-session temp dir). The dict lives at module scope so user variables
    survive across calls in a conversation.
    """
    global _py_namespace
    if _py_namespace is not None:
        # Keep cmd fresh in case the module is re-init'd with a new handle.
        _py_namespace['cmd'] = cmd
        return _py_namespace

    workdir = tempfile.mkdtemp(prefix='raymol_ai_')

    ns = {
        '__name__': '__raymol_ai__',
        '__builtins__': __builtins__,
        'cmd': cmd,
        'WORKDIR': workdir,
    }

    # numpy — bundled on macOS, may be absent on iOS. Guard it.
    try:
        import numpy as _np
        ns['np'] = _np
    except Exception:
        ns['np'] = None

    # Biopython — pure-python subset bundled; some submodules need numpy and may
    # be unavailable. Importing the top-level package must never raise here.
    try:
        import Bio as _Bio
        ns['Bio'] = _Bio
    except Exception:
        ns['Bio'] = None

    _py_namespace = ns
    return _py_namespace


def _impl_run_python(code, cmd):
    """Exec model-authored Python in the live session; return stdout + traceback.

    Runs on the WORKER thread (NOT _run_on_main). The code may call cmd.do(...)
    or mutate the session via the cmd.* API; those enqueue onto PyMOL's command
    queue (cmd.do from a non-GUI thread only ENQUEUES). After exec we cmd.sync()
    to WAIT for the render loop (main thread) to drain and run that queue before
    returning, so the scene actually changes before the model sees "done". We do
    NOT hop to the main thread: the main thread IS the render thread and cannot
    drain its own queue while blocked inside this call; sync() releases the GIL
    and the API lock while it waits, so the render thread is free to run the
    queued work, and it returns on empty-queue or timeout (never hangs).

    sys.stdout/stderr are redirected to capture print() output; on exception the
    full traceback is appended. The combined text is returned so the model can
    verify results and self-correct.
    """
    if not code or not str(code).strip():
        return "No code to execute."

    ns = _get_py_namespace(cmd)

    buf = io.StringIO()
    old_stdout, old_stderr = sys.stdout, sys.stderr
    tb_text = ''
    sys.stdout = buf
    sys.stderr = buf
    try:
        exec(compile(code, '<run_python>', 'exec'), ns, ns)
    except Exception:
        tb_text = traceback.format_exc()
    finally:
        sys.stdout = old_stdout
        sys.stderr = old_stderr

    # Wait for any queued cmd.do/mutations to actually run on the render thread.
    try:
        cmd.sync(3.0)
    except Exception:
        pass

    out = buf.getvalue()
    parts = []
    if out.strip():
        parts.append(out.rstrip())
    if tb_text:
        parts.append("Traceback (the code raised — fix and retry):\n" + tb_text.rstrip())
    if not parts:
        return "(ran successfully; no output)"
    return "\n".join(parts)


def _impl_capture_viewport(width, height, cmd):
    """Capture the PyMOL viewport as base64 PNG bytes (or None on failure)."""
    png_data = [None]

    def _capture():
        # First try: cmd.png(None, ...) returns PNG bytes directly
        try:
            result = cmd.png(None, width, height, ray=0, quiet=1)
            if result and isinstance(result, (bytes, bytearray)) and len(result) > 0:
                png_data[0] = bytes(result)
                return
        except Exception:
            pass

        # Fallback: write to a temp file and read it back
        try:
            tmp_path = '/tmp/_pymol_ai_capture.png'
            cmd.png(tmp_path, width, height, ray=0, quiet=1)
            import time
            time.sleep(0.3)
            if os.path.exists(tmp_path):
                with open(tmp_path, 'rb') as f:
                    png_data[0] = f.read()
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
        except Exception:
            pass

    _run_on_main(_capture)
    return png_data[0]


def _impl_search_pdb(query, max_results):
    """Search the RCSB PDB. Does NOT require main thread (pure network)."""
    max_results = max(1, min(25, max_results))

    from pymol.ai_pdb_search import search_pdb
    return search_pdb(query, max_results=max_results)


# ---------------------------------------------------------------------------
# SDK tool definitions (only created when claude_agent_sdk is available)
# ---------------------------------------------------------------------------

pymol_server = None

if _HAS_SDK:
    from pymol import cmd as _cmd

    @tool(
        "get_session_state",
        "Retrieve the current state of the PyMOL session including all "
        "loaded objects (molecules, maps, groups, etc.) with atom counts, "
        "named selections with atom counts, the current camera view matrix "
        "(18 floats: 9 rotation, 3 position, 3 origin, 3 clipping/fog), "
        "and the viewport dimensions in pixels. Use this tool whenever you "
        "need to understand what the user currently has loaded or how the "
        "scene is oriented.",
        {},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_get_session_state(args):
        try:
            state = await asyncio.to_thread(_impl_get_session_state, _cmd)
            return {"content": [{"type": "text", "text": json.dumps(state, indent=2)}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "run_python",
        "THIS IS HOW YOU ACT. Execute Python code inside the live PyMOL session "
        "and return its printed output plus any traceback. The namespace is "
        "persistent across calls and preloaded with `cmd` (PyMOL API), `np` "
        "(numpy), `Bio` (biopython, if available), and `WORKDIR` (a writable "
        "temp dir). The code runs for real and the scene updates. Use print() to "
        "surface values you need. Drive every action this way (fetch/show/color/"
        "align/alter/analysis); on error you get the full traceback to self-correct.",
        {"code": str},
    )
    async def sdk_run_python(args):
        code = args.get("code", "")
        if not code:
            return {"content": [{"type": "text", "text": "No code to execute."}], "is_error": True}
        try:
            result = await asyncio.to_thread(_impl_run_python, code, _cmd)
            return {"content": [{"type": "text", "text": result}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "capture_viewport",
        "Capture a screenshot of the current PyMOL viewport as a PNG image. "
        "The image is returned as a base64-encoded string. You can optionally "
        "specify width and height in pixels; if omitted the current viewport "
        "size is used. Use this tool when the user asks you to look at, "
        "analyze, or comment on the current visualization.",
        {"width": int, "height": int},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_capture_viewport(args):
        width = args.get("width", 0) or 0
        height = args.get("height", 0) or 0
        try:
            png_bytes = await asyncio.to_thread(_impl_capture_viewport, width, height, _cmd)
            if png_bytes and len(png_bytes) > 0:
                b64 = base64.b64encode(png_bytes).decode('ascii')
                return {"content": [{"type": "image", "data": b64, "mimeType": "image/png"}]}
            else:
                return {"content": [{"type": "text", "text": "Error: Failed to capture viewport image."}], "is_error": True}
        except Exception as exc:
            return {"content": [{"type": "text", "text": f"Error: {exc}"}], "is_error": True}

    @tool(
        "search_pdb",
        "Search the RCSB Protein Data Bank for structures matching a text "
        "query. Returns a list of matching PDB entries with their ID, title, "
        "source organism, and resolution. Use this tool when the user asks "
        "about available structures, wants to find a protein, or needs help "
        "choosing which PDB entry to load.",
        {"query": str, "max_results": int},
        annotations=ToolAnnotations(readOnlyHint=True),
    )
    async def sdk_search_pdb(args):
        query = args.get("query", "")
        max_results = args.get("max_results", 5)
        if not query:
            return {"content": [{"type": "text", "text": json.dumps({"error": "No query provided."})}], "is_error": True}
        try:
            results = await asyncio.to_thread(_impl_search_pdb, query, max_results)
            return {"content": [{"type": "text", "text": json.dumps(results, indent=2)}]}
        except Exception as exc:
            return {"content": [{"type": "text", "text": json.dumps({"error": f"PDB search failed: {exc}"})}], "is_error": True}

    # Build the MCP server
    pymol_server = create_sdk_mcp_server(
        name="pymol",
        version="1.0.0",
        tools=[sdk_get_session_state, sdk_run_python, sdk_capture_viewport, sdk_search_pdb],
    )


# ---------------------------------------------------------------------------
# Legacy dispatcher (fallback when SDK is not available)
# ---------------------------------------------------------------------------

def _tool_get_session_state(tool_input, cmd):
    result = _impl_get_session_state(cmd)
    return json.dumps(result, indent=2)


def _tool_run_python(tool_input, cmd):
    code = tool_input.get("code", "")
    return _impl_run_python(code, cmd)


def _tool_capture_viewport(tool_input, cmd):
    width = tool_input.get("width", 0) or 0
    height = tool_input.get("height", 0) or 0
    png_bytes = _impl_capture_viewport(width, height, cmd)
    if png_bytes and len(png_bytes) > 0:
        return base64.b64encode(png_bytes).decode('ascii')
    else:
        return "Error: Failed to capture viewport image."


def _tool_search_pdb(tool_input, cmd):
    query = tool_input.get("query", "")
    max_results = tool_input.get("max_results", 5)
    if not query:
        return json.dumps({"error": "No query provided."})
    max_results = max(1, min(25, max_results))
    try:
        results = _impl_search_pdb(query, max_results)
        return json.dumps(results, indent=2)
    except Exception as exc:
        return json.dumps({"error": f"PDB search failed: {exc}"})


_TOOL_HANDLERS = {
    "get_session_state": _tool_get_session_state,
    "run_python": _tool_run_python,
    "capture_viewport": _tool_capture_viewport,
    "search_pdb": _tool_search_pdb,
}


def execute_tool(tool_name, tool_input, cmd_module):
    """Dispatch a tool call to the appropriate handler.

    Parameters
    ----------
    tool_name : str
        Name of the tool to execute (must match a key in TOOL_DEFINITIONS).
    tool_input : dict
        The input parameters for the tool call.
    cmd_module : object
        The PyMOL cmd module (or equivalent) to pass to the handler.

    Returns
    -------
    str or dict
        The result of the tool execution, typically a JSON string or an
        error message string.
    """
    handler = _TOOL_HANDLERS.get(tool_name)
    if handler is None:
        return f"Error: Unknown tool '{tool_name}'."

    try:
        return handler(tool_input or {}, cmd_module)
    except Exception as exc:
        return f"Error executing tool '{tool_name}': {exc}"
