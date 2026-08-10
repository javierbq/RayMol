import json
import sys
import threading
import time
import types
import unittest

import raymol_mcp.mainthread as mainthread
import raymol_mcp.tools as tools


def claim_main_thread(testcase):
    """Make the calling thread pass for the app's main thread.

    Tool bodies are marshalled through ``mainthread.run_on_main``, which blocks
    for 30s waiting on an app main thread to drain the queue -- headless there
    is none, so every tool call would time out. Draining once here records this
    thread as the main thread, after which ``run_on_main`` takes its documented
    re-entrancy path and runs the body inline. ``_main_ident`` is a process
    global, so restore it or later tests inherit a bogus main thread.
    """
    testcase.addCleanup(setattr, mainthread, "_main_ident",
                        mainthread._main_ident)
    mainthread.drain_main_thread_queue()


class _FakeCmd:
    """Minimal ``cmd`` stand-in for get_session_state.

    A measurement object (``hb_x``) raises on ``count_atoms`` exactly the way
    PyMOL's selector rejects a non-molecule object name with "Invalid selection
    name" (verified against the live app). A molecule (``mol1``) counts fine.
    """

    _TYPES = {"mol1": "object:molecule", "hb_x": "object:measurement"}

    def get_names(self, kind):
        return ["mol1", "hb_x"] if kind == "objects" else ["sele1"]

    def get_type(self, name):
        return self._TYPES[name]

    def count_atoms(self, selection):
        if "hb_x" in selection:
            raise Exception('Error: Invalid selection name "hb_x".')
        return 100

    def get_view(self):
        return tuple(float(i) for i in range(18))

    def get_frame(self):
        return 3

    def count_frames(self):
        return 5


class TestGetSessionStateNonMolecule(unittest.TestCase):
    """get_session_state must not blow up when the session holds objects that
    aren't molecules (measurements, maps, CGOs, groups) -- their names aren't
    valid atom-selections, so count_atoms('(name)') raises. Regression for the
    Claude-driving crash where an hb_* H-bond object aborted the whole call."""

    def setUp(self):
        claim_main_thread(self)
        self._saved = sys.modules.get("pymol")
        fake = types.ModuleType("pymol")
        fake.cmd = _FakeCmd()
        sys.modules["pymol"] = fake

    def tearDown(self):
        if self._saved is not None:
            sys.modules["pymol"] = self._saved
        else:
            sys.modules.pop("pymol", None)

    def test_non_molecule_object_does_not_error(self):
        res = tools._get_session_state({})
        self.assertFalse(res["isError"], res["content"][0]["text"])
        state = json.loads(res["content"][0]["text"])
        objs = {o["name"]: o for o in state["objects"]}
        self.assertEqual(objs["mol1"]["atoms"], 100)
        # measurement object is still listed, just not atom-counted
        self.assertEqual(objs["hb_x"]["type"], "object:measurement")
        self.assertEqual(objs["hb_x"]["atoms"], 0)
        self.assertEqual(state["selections"], ["sele1"])


class TestMainThreadMarshalling(unittest.TestCase):
    """run_on_main() is the seam every tool body now goes through. It was
    untested, which is how test_non_molecule_object_does_not_error silently
    rotted into a 30s timeout when tools.py started marshalling through it."""

    def setUp(self):
        self.addCleanup(setattr, mainthread, "_main_ident",
                        mainthread._main_ident)

    def test_worker_thread_work_runs_on_the_draining_thread(self):
        # The real topology: a handler thread enqueues, the main thread drains.
        main_ident = threading.get_ident()
        box = {}
        started = threading.Event()

        def worker():
            started.set()
            try:
                box["ran_on"] = mainthread.run_on_main(threading.get_ident)
            except BaseException as e:      # surface instead of hanging silently
                box["exc"] = e

        t = threading.Thread(target=worker)
        t.start()
        self.assertTrue(started.wait(5), "worker never started")
        deadline = time.monotonic() + 5.0
        while t.is_alive() and time.monotonic() < deadline:
            mainthread.drain_main_thread_queue()
            time.sleep(0.01)
        t.join(timeout=5)
        self.assertFalse(t.is_alive(), "run_on_main never returned")
        self.assertNotIn("exc", box)
        # The body ran on the draining thread, not the caller's.
        self.assertEqual(box["ran_on"], main_ident)

    def test_exception_propagates_to_the_caller(self):
        box = {}

        def boom():
            raise ValueError("kaboom")

        def worker():
            try:
                mainthread.run_on_main(boom)
            except BaseException as e:
                box["exc"] = e

        t = threading.Thread(target=worker)
        t.start()
        deadline = time.monotonic() + 5.0
        while t.is_alive() and time.monotonic() < deadline:
            mainthread.drain_main_thread_queue()
            time.sleep(0.01)
        t.join(timeout=5)
        self.assertIsInstance(box.get("exc"), ValueError)
        self.assertEqual(str(box["exc"]), "kaboom")

    def test_reentrant_call_on_main_thread_runs_inline(self):
        # A queued fn calling back into run_on_main must not self-deadlock:
        # the draining thread is the only consumer.
        mainthread.drain_main_thread_queue()        # claim main-thread identity
        self.assertEqual(mainthread.run_on_main(lambda: "inline"), "inline")

    def test_timeout_when_nothing_drains(self):
        # No drainer and we are not the main thread -> bounded failure, not a hang.
        mainthread._main_ident = None
        with self.assertRaises(TimeoutError):
            mainthread.run_on_main(lambda: None, timeout=0.05)


class TestMcpToolsRegistry(unittest.TestCase):
    def test_tools_list_has_five_named_tools(self):
        names = {t["name"] for t in tools.TOOLS}
        self.assertEqual(names, {
            "run_pymol_command", "run_python",
            "get_session_state", "capture_viewport", "search_pdb",
        })

    def test_every_tool_has_description_and_schema(self):
        for t in tools.TOOLS:
            self.assertTrue(t["description"].strip())
            self.assertEqual(t["inputSchema"]["type"], "object")

    def test_unknown_tool_is_error_not_exception(self):
        res = tools.call("nope", {})
        self.assertTrue(res["isError"])
        self.assertEqual(res["content"][0]["type"], "text")


if __name__ == "__main__":
    unittest.main()
