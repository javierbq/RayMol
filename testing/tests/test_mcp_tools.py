import unittest

import raymol_mcp.tools as tools


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
