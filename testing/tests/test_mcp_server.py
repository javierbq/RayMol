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

    def test_tools_list_returns_general_and_raymol_tools(self):
        resp = server.handle_jsonrpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, "s1")
        names = {t["name"] for t in resp["result"]["tools"]}
        self.assertIn("run_pymol_command", names)
        self.assertIn("set_lighting", names)
        self.assertIn("predict_structure", names)

    def test_instructions_say_it_is_not_stock_pymol(self):
        # Clients that read "a PyMOL fork" write stock PyMOL; the instructions
        # must name what replaces each habit.
        req = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
               "params": {"protocolVersion": "2025-06-18"}}
        text = server.handle_jsonrpc(req, "s1")["result"]["instructions"]
        self.assertIn("NOT stock PyMOL", text)
        for tool in ("set_lighting", "set_material", "set_render_effects",
                     "export_image", "predict_structure", "raymol_help"):
            self.assertIn(tool, text)

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

    def _post(self, body, token, session=None):
        data = json.dumps(body).encode()
        headers = {"Content-Type": "application/json",
                   "Authorization": "Bearer %s" % token}
        if session:
            headers["Mcp-Session-Id"] = session
        req = rq.Request("http://127.0.0.1:%d/mcp" % self.port, data=data,
                         headers=headers)
        return rq.urlopen(req, timeout=5)

    def _initialize(self):
        """Complete a handshake and return the issued session id."""
        resp = self._post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                           "params": {"protocolVersion": "2025-06-18"}},
                          "secret-token")
        sid = resp.headers.get("Mcp-Session-Id")
        resp.close()
        return sid

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

    def test_request_refreshes_known_session_last_seen(self):
        # do_POST's atomic check-and-touch used to live in a server._touch()
        # helper; it is now inlined, so drive it through HTTP where it lives.
        sid = self._initialize()
        server._sessions[sid] = 0.0                 # age it well past the TTL
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"},
                   "secret-token", session=sid).close()
        self.assertGreater(server._sessions[sid], 0.0)
        self.assertEqual(server._prune_idle(now=server._sessions[sid] + 1.0), [])

    def test_request_does_not_resurrect_unknown_session(self):
        # The touch is deliberately check-THEN-set under one lock: an id the
        # server never issued (or a sweep already pruned) must not be re-added,
        # which would defeat idle expiry entirely.
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"},
                   "secret-token", session="never-issued").close()
        self.assertNotIn("never-issued", server._sessions)


class TestHttpKeepAlive(unittest.TestCase):
    """An early reply must still consume the request body: on a kept-alive
    connection the unread JSON was parsed as the next request line, so the
    client's following request failed with "400 Bad request syntax"."""

    def setUp(self):
        self.port = server.start(0, "secret-token", version="9.8.7")

    def tearDown(self):
        server.stop()

    def _conn(self):
        import http.client
        return http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)

    def _request(self, conn, token, method="POST", path="/mcp", body=None):
        data = json.dumps(body if body is not None else
                          {"jsonrpc": "2.0", "id": 1, "method": "ping"})
        conn.request(method, path, body=data, headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer %s" % token})
        resp = conn.getresponse()
        payload = resp.read()
        return resp.status, payload

    def test_request_after_401_on_same_connection_succeeds(self):
        conn = self._conn()
        self.addCleanup(conn.close)
        self.assertEqual(self._request(conn, "wrong")[0], 401)
        status, payload = self._request(conn, "secret-token")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(payload)["result"], {})

    def test_request_after_404_on_same_connection_succeeds(self):
        conn = self._conn()
        self.addCleanup(conn.close)
        self.assertEqual(self._request(conn, "secret-token", path="/nope")[0],
                         404)
        self.assertEqual(self._request(conn, "secret-token")[0], 200)

    def test_get_is_405_with_allow(self):
        conn = self._conn()
        self.addCleanup(conn.close)
        conn.request("GET", "/mcp",
                     headers={"Authorization": "Bearer secret-token"})
        resp = conn.getresponse()
        resp.read()
        self.assertEqual(resp.status, 405)
        self.assertIn("POST", resp.getheader("Allow"))

    def test_server_info_carries_app_version(self):
        conn = self._conn()
        self.addCleanup(conn.close)
        status, payload = self._request(conn, "secret-token", body={
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18"}})
        self.assertEqual(status, 200)
        info = json.loads(payload)["result"]["serverInfo"]
        self.assertEqual(info["version"], "9.8.7")
        self.assertEqual(info["title"], "RayMol")


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

    def test_prune_at_exactly_ttl_keeps_session(self):
        # Boundary: expiry is `now - t > TTL`, so a session idle for exactly
        # the TTL survives. Guards the off-by-one if that ever becomes >=.
        now = 10000.0
        server._sessions = {"edge": now - server.SESSION_TTL}
        self.assertEqual(server._prune_idle(now=now), [])
        self.assertIn("edge", server._sessions)


if __name__ == "__main__":
    unittest.main()
