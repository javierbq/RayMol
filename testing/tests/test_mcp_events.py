import base64
import io
import unittest
from contextlib import redirect_stdout

import raymol_mcp.events as events


class TestMcpEvents(unittest.TestCase):
    def _cap(self, fn, *a):
        buf = io.StringIO()
        with redirect_stdout(buf):
            fn(*a)
        return buf.getvalue().strip()

    def test_started_emits_b64_port(self):
        line = self._cap(events.server_started, 51737)
        self.assertTrue(line.startswith("MCP:started:"))
        self.assertEqual(base64.b64decode(line.split(":", 2)[2]).decode(), "51737")

    def test_action_start_encodes_summary(self):
        line = self._cap(events.action_start, "fetch 1ubq")
        self.assertTrue(line.startswith("MCP:action:"))
        self.assertEqual(base64.b64decode(line.split(":", 2)[2]).decode(), "fetch 1ubq")

    def test_action_end_encodes_bool(self):
        line = self._cap(events.action_end, True)
        self.assertTrue(line.startswith("MCP:actionend:"))
        self.assertEqual(base64.b64decode(line.split(":", 2)[2]).decode(), "1")

    def test_connect_roundtrips_session_id(self):
        line = self._cap(events.client_connected, "abc123")
        self.assertTrue(line.startswith("MCP:connect:"))
        self.assertEqual(base64.b64decode(line.split(":", 2)[2]).decode(), "abc123")


if __name__ == "__main__":
    unittest.main()
