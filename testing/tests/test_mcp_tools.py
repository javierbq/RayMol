import json
import sys
import types
import unittest

import raymol_mcp.tools as tools


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
