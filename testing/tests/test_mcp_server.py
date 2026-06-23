import base64
import io
import json
import unittest
import urllib.request as rq
from contextlib import redirect_stdout

import raymol_mcp.server as server


class TestJsonRpc(unittest.TestCase):
    def setUp(self):
        server.set_trusted(True)

    def tearDown(self):
        server.set_trusted(False)

    def test_initialize_returns_protocol_capability_instructions(self):
        req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
               "params": {"protocolVersion": "2025-06-18"}}
        resp = server.handle_jsonrpc(req, "s1")
        self.assertEqual(resp["id"], 1)
        self.assertEqual(resp["result"]["protocolVersion"], server.PROTOCOL_VERSION)
        self.assertIn("tools", resp["result"]["capabilities"])
        self.assertTrue(resp["result"]["instructions"].strip())

    def test_tools_list_returns_five(self):
        resp = server.handle_jsonrpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, "s1")
        self.assertEqual(len(resp["result"]["tools"]), 5)

    def test_unknown_method_is_jsonrpc_error(self):
        resp = server.handle_jsonrpc({"jsonrpc": "2.0", "id": 3, "method": "bogus"}, "s1")
        self.assertEqual(resp["error"]["code"], -32601)

    def test_notification_returns_none(self):
        self.assertIsNone(
            server.handle_jsonrpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, "s1"))

    def test_tools_call_unknown_tool_emits_action_events_and_iserror(self):
        # Uses an unknown tool name so no live PyMOL is needed; still exercises the
        # action_start/action_end wrapping and error propagation.
        buf = io.StringIO()
        with redirect_stdout(buf):
            resp = server.handle_jsonrpc(
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                 "params": {"name": "nope", "arguments": {}}}, "s1")
        out = buf.getvalue()
        self.assertTrue(resp["result"]["isError"])
        self.assertIn("MCP:action:", out)
        self.assertIn("MCP:actionend:", out)

    def test_tools_call_blocked_when_untrusted(self):
        server.set_trusted(False)
        buf = io.StringIO()
        with redirect_stdout(buf):
            resp = server.handle_jsonrpc({"jsonrpc": "2.0", "id": 9,
                "method": "tools/call",
                "params": {"name": "run_pymol_command",
                           "arguments": {"command": "bg_color white"}}}, "s1")
        out = buf.getvalue()
        self.assertTrue(resp["result"]["isError"])
        self.assertIn("approve", resp["result"]["content"][0]["text"].lower())
        self.assertNotIn("MCP:action:", out)


class TestHttpAuth(unittest.TestCase):
    def setUp(self):
        self.port = server.start(0, "secret-token")

    def tearDown(self):
        server.stop()

    def _post(self, body, token):
        data = json.dumps(body).encode()
        req = rq.Request("http://127.0.0.1:%d/mcp" % self.port, data=data,
                         headers={"Content-Type": "application/json",
                                  "Authorization": "Bearer %s" % token})
        return rq.urlopen(req, timeout=5)

    def test_missing_token_is_401(self):
        with self.assertRaises(rq.HTTPError) as ctx:
            self._post({"jsonrpc": "2.0", "id": 1, "method": "ping"}, "wrong")
        self.assertEqual(ctx.exception.code, 401)
        ctx.exception.close()

    def test_initialize_over_http_sets_session_and_counts_client(self):
        resp = self._post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                           "params": {"protocolVersion": "2025-06-18"}}, "secret-token")
        self.assertEqual(resp.status, 200)
        self.assertTrue(resp.headers.get("Mcp-Session-Id"))
        payload = json.loads(resp.read())
        resp.close()
        self.assertEqual(payload["result"]["serverInfo"]["name"], "raymol")
        self.assertEqual(server.status()["clients"], 1)


class TestSessionExpiry(unittest.TestCase):
    def setUp(self):
        server._sessions = {}

    def test_prune_removes_idle_and_emits_disconnect(self):
        now = 10000.0
        server._sessions = {"old": now - (server.SESSION_TTL + 10),  # idle past TTL
                            "fresh": now - 5.0}                        # fresh
        buf = io.StringIO()
        with redirect_stdout(buf):
            dead = server._prune_idle(now=now)
        self.assertEqual(dead, ["old"])
        self.assertIn("fresh", server._sessions)
        self.assertIn("MCP:disconnect:", buf.getvalue())

    def test_prune_keeps_all_fresh(self):
        now = 10000.0
        server._sessions = {"a": now - 5.0, "b": now - (server.SESSION_TTL - 5)}
        dead = server._prune_idle(now=now)
        self.assertEqual(dead, [])
        self.assertEqual(set(server._sessions), {"a", "b"})

    def test_touch_refreshes_last_seen(self):
        server._sessions = {"a": 0.0}
        server._touch("a")
        dead = server._prune_idle(now=server._sessions["a"] + 1.0)
        self.assertEqual(dead, [])


if __name__ == "__main__":
    unittest.main()
