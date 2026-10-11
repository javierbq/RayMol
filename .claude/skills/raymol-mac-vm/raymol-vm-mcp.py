#!/usr/bin/env python3
"""Drive RayMol's built-in MCP server over HTTP from the host.

RayMol's MCP server is MCP "Streamable HTTP": JSON-RPC 2.0 over HTTP POST to
`/mcp`, bearer-token authed. This CLI talks to it directly (no MCP client
registration), which is what lets the host drive a RayMol running INSIDE a
mac-vm-test VM: the VM app must be launched with RAYMOL_MCP_BIND=0.0.0.0 (so the
server binds a reachable interface) and RAYMOL_MCP_AUTOTRUST=1 (so tool calls
don't wait for an interactive Allow click). See SKILL.md.

Endpoint + token resolution (first that applies wins):
  1. --endpoint / --token flags
  2. $RAYMOL_VM_ENDPOINT / $RAYMOL_VM_TOKEN
  3. --vm-ip IP  -> SSH into the VM, read the handoff file
     ~/Library/Application Support/RayMol/mcp.json ({port, token}), and build
     http://IP:port/mcp

Stdlib only (urllib/json/base64/subprocess/argparse) so it runs under any
python3 with no install step.

Examples:
  raymol-vm-mcp.py --vm-ip 192.168.64.33 discover        # print endpoint+token
  raymol-vm-mcp.py --vm-ip 192.168.64.33 ping            # health check
  raymol-vm-mcp.py --vm-ip 192.168.64.33 cmd "fetch 1ubq, async=0"
  raymol-vm-mcp.py --vm-ip 192.168.64.33 cmd "hide everything; show cartoon; util.cbc"
  raymol-vm-mcp.py --vm-ip 192.168.64.33 capture /tmp/shot.png
  raymol-vm-mcp.py --vm-ip 192.168.64.33 state
  raymol-vm-mcp.py --vm-ip 192.168.64.33 py "print(cmd.get_names('objects'))"
  raymol-vm-mcp.py --vm-ip 192.168.64.33 search "hiv protease" --limit 5
  raymol-vm-mcp.py --vm-ip 192.168.64.33 register --run   # add native raymol-vm MCP server
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

PROTOCOL_VERSION = "2025-06-18"
DEFAULT_SSH_USER = "admin"
DEFAULT_SSH_KEY = os.path.expanduser("~/.mac-vm-pool/id_ed25519")
HANDOFF_PATH = "$HOME/Library/Application Support/RayMol/mcp.json"
# capture_viewport falls back to a CPU ray-trace when the app has no Metal
# frame yet (#643), so give tool calls a generous read timeout.
INIT_TIMEOUT = 10
CALL_TIMEOUT = 180


def _eprint(*a):
    print(*a, file=sys.stderr)


# --- VM handoff discovery over SSH ---------------------------------------

def ssh_discover(vm_ip, key=DEFAULT_SSH_KEY, user=DEFAULT_SSH_USER):
    """Read {port, token} from the VM's RayMol handoff file over SSH."""
    cmd = [
        "ssh", "-i", key,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "%s@%s" % (user, vm_ip),
        'cat "%s"' % HANDOFF_PATH,
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            "discovery failed: could not read %s on %s@%s\n%s\n"
            "Is RayMol running in the VM with the server enabled "
            "(RAYMOL_MCP_ENABLE=1)? Has the handoff file been written yet?"
            % (HANDOFF_PATH, user, vm_ip, proc.stderr.strip())
        )
    try:
        obj = json.loads(proc.stdout)
        port, token = int(obj["port"]), str(obj["token"])
    except Exception as e:
        raise SystemExit("discovery: bad handoff JSON on %s: %r (%s)"
                         % (vm_ip, proc.stdout, e))
    return "http://%s:%d/mcp" % (vm_ip, port), token


def resolve_endpoint(args):
    """Resolve (endpoint, token) from flags, env, or SSH discovery."""
    endpoint = args.endpoint or os.environ.get("RAYMOL_VM_ENDPOINT")
    token = args.token or os.environ.get("RAYMOL_VM_TOKEN")
    if endpoint and token:
        return endpoint, token
    if args.vm_ip:
        return ssh_discover(args.vm_ip, args.key, args.ssh_user)
    raise SystemExit(
        "no endpoint: pass --endpoint URL --token TOK, set "
        "$RAYMOL_VM_ENDPOINT/$RAYMOL_VM_TOKEN, or pass --vm-ip IP to discover."
    )


# --- Minimal MCP-over-HTTP client ----------------------------------------

class Client:
    def __init__(self, endpoint, token):
        self.endpoint = endpoint
        self.token = token
        self.session_id = None

    def _post(self, message, timeout):
        body = json.dumps(message).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Authorization": "Bearer %s" % self.token,
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        req = urllib.request.Request(self.endpoint, data=body,
                                     method="POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                sid = r.headers.get("Mcp-Session-Id")
                if sid:
                    self.session_id = sid
                raw = r.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            if e.code == 401:
                raise SystemExit(
                    "401 unauthorized: bearer token mismatch or stale. "
                    "Re-run `discover` (the token is per-app-launch)."
                )
            raise SystemExit("HTTP %d from %s: %s"
                             % (e.code, self.endpoint, e.read().decode("utf-8", "replace")))
        except urllib.error.URLError as e:
            raise SystemExit(
                "cannot reach %s: %s\nChecklist: RayMol running in the VM? "
                "launched with RAYMOL_MCP_BIND=0.0.0.0? VM IP correct? "
                "guest firewall open on the port?" % (self.endpoint, e.reason)
            )

    def initialize(self):
        resp = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "raymol-vm-mcp", "version": "1.0.0"},
            },
        }, INIT_TIMEOUT)
        if not resp or "result" not in resp:
            raise SystemExit("initialize failed: %r" % resp)
        # Be a well-behaved client: announce initialized (server 202s / ignores).
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"},
                   INIT_TIMEOUT)
        return resp["result"]

    def call_tool(self, name, arguments, timeout=CALL_TIMEOUT):
        resp = self._post({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        }, timeout)
        if not resp:
            raise SystemExit("empty response to tools/call %s" % name)
        if "error" in resp:
            raise SystemExit("JSON-RPC error: %s" % resp["error"])
        return resp.get("result", {})

    def close(self):
        if not self.session_id:
            return
        headers = {"Authorization": "Bearer %s" % self.token,
                   "Mcp-Session-Id": self.session_id}
        req = urllib.request.Request(self.endpoint, method="DELETE",
                                     headers=headers)
        try:
            urllib.request.urlopen(req, timeout=INIT_TIMEOUT).read()
        except Exception:
            pass  # best-effort session cleanup


# --- result rendering -----------------------------------------------------

def _first_text(result):
    for item in result.get("content", []):
        if item.get("type") == "text":
            return item.get("text", "")
    return ""


def _first_image_b64(result):
    for item in result.get("content", []):
        if item.get("type") == "image":
            return item.get("data")
    return None


def emit_tool_result(result, exit_on_error=True):
    """Print a text result; return isError. Exits nonzero on tool error."""
    is_error = bool(result.get("isError"))
    text = _first_text(result)
    if is_error:
        _eprint(text or "(tool error, no text)")
        if exit_on_error:
            raise SystemExit(2)
    else:
        if text:
            print(text)
    return is_error


# --- subcommands ----------------------------------------------------------

def cmd_discover(args):
    endpoint, token = resolve_endpoint(args)
    print(json.dumps({"endpoint": endpoint, "token": token}, indent=2))
    _eprint("\n# shell exports:")
    _eprint("export RAYMOL_VM_ENDPOINT=%s" % endpoint)
    _eprint("export RAYMOL_VM_TOKEN=%s" % token)


def cmd_ping(args):
    endpoint, token = resolve_endpoint(args)
    c = Client(endpoint, token)
    try:
        info = c.initialize()
        print(json.dumps({"ok": True, "endpoint": endpoint,
                          "serverInfo": info.get("serverInfo")}, indent=2))
    finally:
        c.close()


def _with_client(args, fn):
    endpoint, token = resolve_endpoint(args)
    c = Client(endpoint, token)
    try:
        c.initialize()
        return fn(c)
    finally:
        c.close()


def cmd_run(args):
    _with_client(args, lambda c: emit_tool_result(
        c.call_tool("run_pymol_command", {"command": args.command})))


def cmd_py(args):
    code = args.code
    if args.file:
        with open(args.file) as f:
            code = f.read()
    if not code:
        raise SystemExit("py: provide code inline or with --file")
    _with_client(args, lambda c: emit_tool_result(
        c.call_tool("run_python", {"code": code})))


def cmd_state(args):
    _with_client(args, lambda c: emit_tool_result(
        c.call_tool("get_session_state", {})))


def cmd_capture(args):
    def _do(c):
        result = c.call_tool("capture_viewport",
                             {"width": args.width, "height": args.height})
        if result.get("isError"):
            emit_tool_result(result)  # prints error + exits
            return
        b64 = _first_image_b64(result)
        if not b64:
            raise SystemExit("capture: no image in response: %r" % result)
        with open(args.out, "wb") as f:
            f.write(base64.b64decode(b64))
        print("wrote %s (%d bytes)" % (args.out, os.path.getsize(args.out)))
    _with_client(args, _do)


def cmd_search(args):
    _with_client(args, lambda c: emit_tool_result(
        c.call_tool("search_pdb", {"query": args.query, "limit": args.limit})))


def cmd_call(args):
    try:
        arguments = json.loads(args.json_args) if args.json_args else {}
    except Exception as e:
        raise SystemExit("call: --args must be JSON: %s" % e)
    _with_client(args, lambda c: print(json.dumps(
        c.call_tool(args.tool, arguments), indent=2)))


def cmd_register(args):
    endpoint, token = resolve_endpoint(args)
    add = ["claude", "mcp", "add", "--transport", "http", args.name, endpoint,
           "--header", "Authorization: Bearer %s" % token, "--scope", "user"]
    printable = " ".join(
        (a if " " not in a else '"%s"' % a) for a in add)
    if args.run:
        subprocess.run(["claude", "mcp", "remove", args.name, "--scope", "user"],
                       capture_output=True, text=True)  # idempotent
        proc = subprocess.run(add, capture_output=True, text=True)
        sys.stdout.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        if proc.returncode == 0:
            _eprint("\nRegistered '%s'. In Claude Code run /mcp (or restart) "
                    "to attach. Remove later: claude mcp remove %s --scope user"
                    % (args.name, args.name))
        raise SystemExit(proc.returncode)
    print(printable)
    _eprint("\n# not run (pass --run to execute). Remove later:")
    _eprint("claude mcp remove %s --scope user" % args.name)


def build_parser():
    p = argparse.ArgumentParser(
        prog="raymol-vm-mcp.py",
        description="Drive RayMol's MCP server over HTTP (host -> VM).")
    p.add_argument("--endpoint", help="MCP URL, e.g. http://IP:PORT/mcp")
    p.add_argument("--token", help="bearer token")
    p.add_argument("--vm-ip", help="VM IP; discover endpoint+token over SSH")
    p.add_argument("--key", default=DEFAULT_SSH_KEY, help="SSH key for discovery")
    p.add_argument("--ssh-user", default=DEFAULT_SSH_USER, help="SSH user (default admin)")
    sub = p.add_subparsers(dest="sub", required=True)

    sub.add_parser("discover", help="print endpoint+token").set_defaults(func=cmd_discover)
    sub.add_parser("ping", help="initialize (health check)").set_defaults(func=cmd_ping)
    sub.add_parser("state", help="get_session_state").set_defaults(func=cmd_state)

    sp = sub.add_parser("cmd", help="run_pymol_command")
    sp.add_argument("command")
    sp.set_defaults(func=cmd_run)

    sp = sub.add_parser("py", help="run_python")
    sp.add_argument("code", nargs="?", default="")
    sp.add_argument("--file", help="read code from a file instead")
    sp.set_defaults(func=cmd_py)

    sp = sub.add_parser("capture", help="capture_viewport -> PNG file")
    sp.add_argument("out")
    sp.add_argument("--width", type=int, default=640)
    sp.add_argument("--height", type=int, default=480)
    sp.set_defaults(func=cmd_capture)

    sp = sub.add_parser("search", help="search_pdb")
    sp.add_argument("query")
    sp.add_argument("--limit", type=int, default=10)
    sp.set_defaults(func=cmd_search)

    sp = sub.add_parser("call", help="generic tools/call")
    sp.add_argument("tool")
    sp.add_argument("json_args", nargs="?", default="", metavar="JSON")
    sp.set_defaults(func=cmd_call)

    sp = sub.add_parser("register", help="add native raymol-vm MCP server (fresh session)")
    sp.add_argument("--name", default="raymol-vm")
    sp.add_argument("--run", action="store_true", help="execute claude mcp add")
    sp.set_defaults(func=cmd_register)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
