# RayMol MCP Broker — Design

Date: 2026-08-19

## Problem

Opening a Claude client while RayMol is closed produces an MCP error. Two
separate defects cause it.

**Claude Code.** `MCPServerManager.connectClaudeCode` registers RayMol as a
direct HTTP endpoint — `--transport http http://127.0.0.1:<port>/mcp` plus a
bearer token — capturing a snapshot of an ephemeral port. The entry is wrong
whenever RayMol is closed, and goes stale whenever RayMol restarts on a
different port. The live `~/.claude.json` on the development machine pins
port 51737.

**Claude desktop app.** `MCPDesktopInstaller.bridgeCommand()` returns
`Bundle.main.executablePath`, so whichever build ran the install — including a
Debug build inside a git worktree — writes its own path into
`claude_desktop_config.json`. The live config points at
`.../build_mac_dd/Build/Products/Debug/RayMol.app/Contents/MacOS/RayMol`.
When that build directory is cleaned, Claude cannot spawn the command and
reports a hard error.

The stdio bridge itself (`MCPBridge`) already degrades correctly when RayMol is
absent: it answers `initialize`, `tools/list` and `ping` locally and returns a
friendly message for tool calls. What it cannot do is *start* RayMol, and it
resolves exactly one target through a single `mcp.json` handoff file.

## Non-goal: a resident login-item daemon

The originating idea was a companion executable launched at login that owns the
MCP endpoint permanently. A resident process buys exactly one capability: a
stable endpoint for a client that cannot spawn a process. Both target clients —
the Claude desktop app and the Claude Code CLI — spawn stdio servers. A daemon
would therefore add a login item, a crash/restart story, an update story, and a
second artifact to sign and notarize, in exchange for no capability that is
used.

The existing `--mcp-bridge` stdio proxy already provides the always-available
endpoint, because the client spawns it on demand. This design hardens that
proxy into a broker rather than introducing a daemon. If a non-spawning client
(remote session, another machine, plain `curl`) becomes a requirement, the
registry defined below is the part a daemon would need, and this design does
not preclude adding one later.

## Architecture

Three components. The registry is the only shared surface: RayMol never knows a
broker exists, and the broker reaches RayMol only over its documented loopback
MCP endpoint.

### Instance registry (RayMol side)

Every running RayMol whose MCP server is up writes

```
~/Library/Application Support/RayMol/instances/<pid>.json
{ "pid": 4412, "port": 51737, "token": "…", "appPath": "/Applications/RayMol.app",
  "name": "RayMol", "installed": true, "startedAt": "2026-08-19T10:31:02Z" }
```

with mode 0600. Written when the `MCP:started` feedback event arrives and
removed on stop and on quit — the same lifecycle as today's
`writeHandoff`/`removeHandoff`, generalized from one canonical file to one file
per instance. `mcp.json` continues to be written exactly as it is today, so
existing readers are unaffected.

`name` is the bundle display name, so suffixed development builds
(`RayMol-287.app`, `RayMol-PR290.app`) self-identify. `installed` is true when
`appPath` is under `/Applications`.

### Broker (`RayMol --mcp-bridge`)

`MCPBridge` grows from "proxy to a fixed handoff file" into "resolve a target,
launch it when absent, then proxy". It remains a stdio process spawned per
client session. Its existing offline behavior — local `initialize`,
`tools/list`, `ping` — is retained as the fallback when resolution fails, so the
server never presents as errored.

### Client registration

Both clients register the same stdio command. `connectClaudeCode` stops
registering an HTTP transport and registers the broker command instead, which is
what makes the Claude Code entry survive RayMol closures and restarts.

## Target selection

Resolution order, first hit wins:

1. **Explicit `instance` argument** on the tool call — an in-conversation
   override, so naming a build rebinds mid-session.
2. **`RAYMOL_MCP_INSTANCE`** environment variable — for scripted and VM setups
   that cannot pass arguments.
3. **Sticky binding** — once a broker process resolves a target it stays bound
   for the life of the client session. Without this, disambiguation would be
   requested on every call.
4. **Registry scan.**

Scan outcomes:

- **Exactly one live instance** — bind it, sticky. A running development build
  therefore wins over an idle installed app, which is the desired behavior
  during testing.
- **Zero** — cold-launch the installed app (below).
- **Two or more** — return a tool result with `isError: true` listing each
  instance and its key, instructing the model to ask the user and re-issue with
  `instance:`. No silent tie-break: guessing wrong drives the wrong window,
  which the user may not notice.

**Instance keys** are the bundle display name (`RayMol`, `RayMol-287`). On a
name collision the key becomes `RayMol#4412`. A bare pid is always accepted.

**Tool surface.** The broker injects an optional `instance` string property into
every tool's `inputSchema` and strips it before forwarding, so
`modules/raymol_mcp/tools.py` requires no change. The broker additionally serves
one native tool, `list_raymol_instances`, so targets can be enumerated without a
failed call first. The static mirror in `MCPBridge.localToolsList` receives the
same injection.

## Cold launch and trust

Triggered by a tool call that resolves to zero instances:

1. The broker sets `raymol.mcp.enabled = true` in its own `UserDefaults`. The
   broker process is RayMol's own binary and therefore shares RayMol's defaults
   domain, so the launched app auto-starts its server even where it has never
   been enabled. No environment-variable or `open` argument passing is required.
2. Launch `/Applications/RayMol.app` via `NSWorkspace.openApplication`.
3. Poll the registry for a fresh entry, ceiling 20 seconds. Engine
   initialization plus Python server start is slow enough that a short timeout
   would flake.
4. Bind, then forward the original call. The client observes one slow call
   rather than an error.

No launch lock is required: `openApplication` on an already-launching app
activates it, so two brokers racing converge on one instance.

**Trust remains a human gate.** A model-initiated cold launch is not a
user-initiated connect, so `initialize` raises RayMol's normal Allow prompt, and
`server.py` already answers untrusted `tools/call` with a retry instruction that
the broker forwards verbatim. The cold path is therefore: tool call → RayMol
opens → user clicks Allow → retry succeeds. `noteUserInitiatedConnect` exists to
skip that prompt for connections the user started, and correctly does not apply
here. A cold start costs one click; a background tool call must not silently
acquire control of a newly opened app.

## Error handling

Every failure returns an actionable tool result. The server is never dead.

| Condition | Behavior |
|---|---|
| Corrupt or unreadable registry entry | Skip the entry, continue scanning |
| Entry pid dead, or port returns 401 (stale token) | Prune the file, rescan |
| `/Applications/RayMol.app` missing on cold launch | `isError` naming the expected path |
| Launch succeeds, no registration within 20 s | `isError` — open Connect ▸ Enable AI control |
| Two or more instances | Ambiguity listing |
| RayMol quits mid-session | Sticky binding drops; next call re-resolves and cold-launches |

The existing 120-second proxy timeout in `MCPBridge.proxy` is unchanged.

## Migration

Neither live configuration self-heals until Connect is re-run, so both need a
one-time repair alongside the code changes.

- `MCPDesktopInstaller.bridgeCommand()` prefers
  `/Applications/RayMol.app/Contents/MacOS/RayMol` when it exists, falling back
  to the running bundle only when no installed app is present. This is the root
  cause of the desktop-app failure.
- `connectClaudeCode` runs `claude mcp remove raymol` before adding, so the
  stale HTTP entry is replaced rather than shadowed.
- The two configurations on the development machine are repaired by hand as part
  of the work.

## Testing

Resolution logic is pure and unit-tested in
`swiftui/PyMOLViewerTests/MCPBrokerTests.swift`:

- registry parse and stale-prune, including a corrupt entry and a dead pid
- key disambiguation, including the `RayMol#<pid>` collision case
- `instance` argument injection and stripping
- the ambiguity payload shape
- `MCPBridge.localToolsList` matches `TOOLS` in `modules/raymol_mcp/tools.py`

End-to-end verification is performed by the implementer, not delegated to the
user: with every RayMol quit, raw JSON-RPC lines are piped into
`RayMol --mcp-bridge` from a shell harness, asserting that RayMol launches,
registers, and the tool call returns. The same harness covers the two-instance
ambiguity case by launching a suffixed development build alongside the installed
app.

## Files touched

- `swiftui/PyMOLViewer/Shared/MCPBridge.swift` — broker resolution, cold launch,
  `instance` injection, `list_raymol_instances`
- `swiftui/PyMOLViewer/Shared/MCPServerManager.swift` — registry write/remove,
  `connectClaudeCode` registers stdio and removes the stale entry first
- `swiftui/PyMOLViewer/Shared/MCPDesktopInstaller.swift` — `bridgeCommand()`
  prefers the installed app
- `swiftui/PyMOLViewerTests/MCPBrokerTests.swift` — new
