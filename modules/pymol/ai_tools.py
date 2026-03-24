"""AI tool definitions and implementations for PyMOL agentic chat.

Defines the Anthropic tool_use schema for each tool and provides
execute_tool() to dispatch tool calls from the agentic loop.
"""

import json
import base64
import os

# ---------------------------------------------------------------------------
# Tool definitions (Anthropic tool_use schema format)
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
        "name": "execute_command",
        "description": (
            "Execute one or more PyMOL commands and return the result of each. "
            "Commands are separated by newlines and executed sequentially. Each "
            "command is run via cmd.do() on the main thread. Returns 'OK' or an "
            "error message for each command. Use this when you need to run a "
            "command and confirm it succeeded, rather than putting commands in "
            "the JSON 'script' field which executes silently."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": (
                        "One or more PyMOL commands separated by newlines. "
                        "Example: 'fetch 1ubq\\nshow cartoon\\ncolor green, ss h'"
                    )
                }
            },
            "required": ["command"]
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
# Tool implementations
# ---------------------------------------------------------------------------

def _tool_get_session_state(tool_input, cmd):
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

    result = _run_on_main(_gather)
    return json.dumps(result, indent=2)


def _tool_execute_command(tool_input, cmd):
    """Execute PyMOL commands on the main thread, returning per-line results."""
    command_text = tool_input.get("command", "")
    lines = [l.strip() for l in command_text.splitlines() if l.strip()]

    if not lines:
        return "No commands to execute."

    results = []

    def _exec():
        for line in lines:
            try:
                cmd.do(line, 0, 1)
                results.append(f"OK: {line}")
            except Exception as exc:
                results.append(f"Error: {line} => {exc}")

    _run_on_main(_exec)
    return "\n".join(results) if results else "No commands executed."


def _tool_capture_viewport(tool_input, cmd):
    """Capture the PyMOL viewport as a base64-encoded PNG string."""
    width = tool_input.get("width", 0) or 0
    height = tool_input.get("height", 0) or 0

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
            # Give PyMOL a moment to finish writing
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

    if png_data[0] and len(png_data[0]) > 0:
        return base64.b64encode(png_data[0]).decode('ascii')
    else:
        return "Error: Failed to capture viewport image."


def _tool_search_pdb(tool_input, cmd):
    """Search the RCSB PDB. Does NOT require main thread (pure network)."""
    query = tool_input.get("query", "")
    max_results = tool_input.get("max_results", 5)

    if not query:
        return json.dumps({"error": "No query provided."})

    # Clamp max_results
    max_results = max(1, min(25, max_results))

    try:
        from pymol.ai_pdb_search import search_pdb
        results = search_pdb(query, max_results=max_results)
        return json.dumps(results, indent=2)
    except Exception as exc:
        return json.dumps({"error": f"PDB search failed: {exc}"})


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

_TOOL_HANDLERS = {
    "get_session_state": _tool_get_session_state,
    "execute_command": _tool_execute_command,
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
