"""Main-thread marshalling for the in-process MCP server.

MCP tool handlers run on http.server request-handler threads. In the embedded
Metal build ``pymol._pymol.glutThread`` is never set, so ``is_gui_thread()`` is
True on every thread and a ``cmd`` call made on a handler thread runs
synchronously OFF the main thread, racing the main thread's ``SceneRenderMetal``
(which drives the core natively, not via the cmd API). The app documents that
off-main core access corrupts the interpreter state, so this races/crashes.

``run_on_main(fn)`` hands ``fn`` to the app's MAIN thread and blocks the calling
handler until the result (or exception) is ready. The app drains the queue once
per ~100ms Timer tick by calling ``drain_main_thread_queue()`` (on the main
thread, via PyMOLBridge_RunPython). This is the same "all core access on main"
invariant the SwiftUI app's ``runHeavy`` already relies on.

Stdlib-only (queue + threading) so this imports without a built PyMOL.
"""

import queue
import threading

_main_q = queue.Queue()
_main_ident = None        # thread id of the draining (main) thread; set on first drain
_TIMEOUT = 30.0           # seconds; longer than the slowest CPU ray-trace


def run_on_main(fn, timeout=_TIMEOUT):
    """Run ``fn()`` on the app's main thread and return its result.

    Called from an MCP request-handler thread: enqueues the work and blocks
    until the main thread drains it (or ``timeout`` elapses). Any exception
    ``fn`` raised is re-raised here (with its original traceback). If we are
    already ON the main thread (re-entrancy — a queued fn called us back), run
    ``fn`` inline: the draining thread is the only consumer, so enqueuing would
    self-deadlock.
    """
    if _main_ident is not None and threading.get_ident() == _main_ident:
        return fn()
    box = {}
    done = threading.Event()
    _main_q.put((fn, box, done))
    if not done.wait(timeout):
        raise TimeoutError(
            "RayMol main thread did not process the request within %ss "
            "(is the app rendering / responsive?)" % timeout)
    if "exc" in box:
        raise box["exc"]
    return box.get("val")


def drain_main_thread_queue():
    """Run all queued work on the MAIN thread, then return.

    Called once per Timer tick from PyMOLEngine.pollFeedback (main thread, via
    PyMOLBridge_RunPython). Each item's result/exception is recorded and its
    waiter signalled. Must never raise (it runs inside the app's feedback pump).
    """
    global _main_ident
    _main_ident = threading.get_ident()
    while True:
        try:
            fn, box, done = _main_q.get_nowait()
        except queue.Empty:
            break
        try:
            box["val"] = fn()
        except BaseException as e:  # propagate to the waiting handler thread
            box["exc"] = e
        finally:
            done.set()
