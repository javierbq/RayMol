---
name: raymol-mac-vm
description: Develop and functionally test the native macOS RayMol app inside an isolated, disposable macOS VM AND drive it over its built-in MCP server from the host. Use when working on the macOS SwiftUI/Metal RayMol app and you want to build it, run it in a throwaway VM (not the host UI), and load/color/render/measure structures in it via MCP from this session. Builds on the mac-vm-test skill + mac-vm-pool MCP; adds the RayMol-specific dev flags and a direct-HTTP MCP driver so host↔VM control works.
---

# raymol-mac-vm

Host-compile RayMol (macOS SwiftUI/Metal), run it in a **fresh disposable macOS
VM**, and **drive it over MCP from the host** — so macOS RayMol development can
lean on the isolated VM instead of the host's own UI.

This is the RayMol-specific companion to the generic **`mac-vm-test`** skill. It
reuses that skill's VM lifecycle (the `mac-vm-pool` MCP server) and SSH/tart
plumbing, and adds the two pieces RayMol needs:

1. **Dev flags** so the in-VM RayMol MCP server is reachable from the host and
   runs headlessly (no UI click). All three are read only from the process
   environment and are absent from any Finder/`open` launch, so they never
   affect shipped or App Store builds:
   - `RAYMOL_MCP_BIND=0.0.0.0` — bind a reachable interface instead of VM
     loopback (`modules/raymol_mcp/server.py`; default `127.0.0.1`).
   - `RAYMOL_MCP_ENABLE=1` — force the server to auto-start on a fresh clone
     even though the UI toggle is off (`swiftui/.../MCPServerManager.swift`).
   - `RAYMOL_MCP_AUTOTRUST=1` — skip the interactive "Allow" approval (existing
     flag; there's no one to click in a headless VM).
2. **`raymol-vm-mcp.py`** — a host-side driver that talks JSON-RPC straight to
   the VM's MCP endpoint (bearer-token authed). No `claude mcp add` needed, so
   it works in the *current* session (a freshly-registered MCP server otherwise
   won't attach until `/mcp`/restart).

`$SK` below is this skill's dir (`.claude/skills/raymol-mac-vm`). The driver is
`$SK/raymol-vm-mcp.py`.

## Prerequisites
Same as `mac-vm-test`: the `mac-vm-pool` MCP server running (so the
`mcp__mac-vm-pool__*` tools exist), a baked `mac-test-golden` image, the entitled
`tart` CLI in `$MVP_TART_BIN`, and the baked SSH key `~/.mac-vm-pool/id_ed25519`.
If `mac-vm-test` isn't set up, do that first.

## The loop — do these in order

### 1. Acquire a VM
Call `mcp__mac-vm-pool__acquire_vm` with a `client_id`. It returns
`{ lease_id, vm_name, ip, ... }`. Save `IP=<ip>`, `VM=<vm_name>`,
`LEASE=<lease_id>`. If it returns `{"queued": true}`, the 2-VM cap is full —
release something or stop.

### 2. Build RayMol ON THE HOST
Two-stage build (the C++ core is a static lib the app only *links*; `xcodebuild`
alone silently relinks a **stale** `libpymol_core.a`):
```bash
# Stage 1 — ONLY if you changed C++ core (layer*/appkit/layerGraphics).
# Swift/ObjC or Python (modules/) changes DO NOT need this.
bash swiftui/build_macos.sh

# Stage 2 — always. Bundles modules/ (incl. the edited raymol_mcp) + links the app.
xcodebuild -project swiftui/PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -configuration Debug -derivedDataPath swiftui/build_mac_dd build
APP="swiftui/build_mac_dd/Build/Products/Debug/RayMol.app"
```
(From a worktree without its own core: symlink `deps_macos` and
`build_macos_swiftui` from the main repo, or run stage 1 in the worktree — see
the `macos_swiftui_build_verify` memory.)

### 3. Install the .app into the VM
```bash
KEY=~/.mac-vm-pool/id_ed25519
SSHOPTS=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
ssh "${SSHOPTS[@]}" admin@"$IP" 'rm -rf ~/Apps/RayMol.app && mkdir -p ~/Apps'
scp "${SSHOPTS[@]}" -r "$APP" admin@"$IP":~/Apps/
```

### 4. Launch it in the VM **with the dev env**
The three `RAYMOL_MCP_*` vars must reach the GUI app's process. A plain
`launchctl setenv` over SSH does NOT reach the console Aqua session (an
`open`-launched app never sees it), so set them in the CONSOLE user's launchd
domain (needs root; passwordless sudo works on the golden image), then `open`.
**This is the verified path** (2026-07-04, golden image macOS 15.7.7):
```bash
ssh "${SSHOPTS[@]}" admin@"$IP" '
  set -e
  CUID=$(id -u)
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_BIND 0.0.0.0
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_AUTOTRUST 1
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_ENABLE 1
  open ~/Apps/RayMol.app
'
sleep 15   # engine inits async; auto-start retries ~10s, then binds + writes handoff
```
Confirm it took: `ssh "${SSHOPTS[@]}" admin@"$IP" 'ps eww -p $(pgrep -f "RayMol.app/Contents/MacOS/RayMol") | tr " " "\n" | grep RAYMOL_MCP'`
should list all three, and the server should listen on `*:PORT` (see step 5).

### 5. Discover the endpoint + token, then sanity-check
The app writes `~/Library/Application Support/RayMol/mcp.json` (`{port, token}`)
when the server starts. The driver reads it over SSH:
```bash
python3 "$SK/raymol-vm-mcp.py" --vm-ip "$IP" discover   # prints endpoint + token
python3 "$SK/raymol-vm-mcp.py" --vm-ip "$IP" ping        # initialize round-trip
```
`ping` printing `serverInfo` proves host↔VM MCP works. (You can export
`RAYMOL_VM_ENDPOINT`/`RAYMOL_VM_TOKEN` from `discover` to skip re-discovery on
every call, or just pass `--vm-ip "$IP"` each time.)

### 6. Drive RayMol
```bash
D=(python3 "$SK/raymol-vm-mcp.py" --vm-ip "$IP")
"${D[@]}" cmd "fetch 1ubq, async=0"
"${D[@]}" cmd "hide everything; show cartoon; spectrum count, rainbow; bg_color white"
"${D[@]}" state                       # loaded objects, selections, camera (JSON)
"${D[@]}" capture /tmp/ubq.png        # Metal-rendered PNG -> host file; then Read it
"${D[@]}" py "print(cmd.get_chains('1ubq'))"
"${D[@]}" search "hiv protease" --limit 5
```
`capture` writes the PNG on the host; open/Read it to verify the render. The 5
tools are `run_pymol_command` (`cmd`), `run_python` (`py`), `get_session_state`
(`state`), `capture_viewport` (`capture`), `search_pdb` (`search`).

### 7. ALWAYS release — even on failure
```bash
# On failure, first grab diagnostics:
"$MVP_TART_BIN" accessibility find "$VM" --app io.raymol.RayMol --max-results 100 \
  > /tmp/ax.txt 2>&1 || true
ssh "${SSHOPTS[@]}" admin@"$IP" 'screencapture -x /tmp/fail.png' || true
```
Then call `mcp__mac-vm-pool__release_vm` with `LEASE`. This destroys the VM, so
no MCP state, token, or app copy lingers.

## Native tools instead of the direct driver (optional)
If you'd rather use native `mcp__raymol-vm__*` tools, register the VM endpoint:
```bash
python3 "$SK/raymol-vm-mcp.py" --vm-ip "$IP" register --run   # claude mcp add raymol-vm
```
Then run `/mcp` (or start a fresh Claude Code session) to attach — a newly-added
MCP server does NOT connect to the session that added it. Remove it on release:
`claude mcp remove raymol-vm --scope user`. For an in-session agentic loop the
direct driver (steps 5–6) is simpler and leaves no config behind.

## Troubleshooting
- **`discover` fails / handoff missing** → the server didn't start. Confirm the
  process actually has the env (the `ps eww … grep RAYMOL_MCP` check in step 4 —
  if empty, the `launchctl asuser` setenv didn't land before `open`), the app is
  running, and give it a few more seconds (engine init + ~10s of auto-start retries).
- **`ping` → connection refused** → server not bound wide. Confirm the process
  env includes `RAYMOL_MCP_BIND=0.0.0.0` and the port listens on `*:` (not
  `127.0.0.1:`): `ssh "${SSHOPTS[@]}" admin@"$IP" 'lsof -nP -iTCP -sTCP:LISTEN | grep -i raymol'`.
- **`ping` → 401** → stale token. Re-run `discover` (token is per app launch).
- **`ping` → timeout (not refused)** → guest firewall may block the port. SSH
  (:22) works, so inbound is generally open; if a high port is filtered, allow it
  on the golden image (`socketfilterfw`) — a mac-vm-pool/golden-image change.
- **tool calls → "waiting for the user to approve"** → the process env is missing
  `RAYMOL_MCP_AUTOTRUST=1`.

## Security
`RAYMOL_MCP_BIND=0.0.0.0` is opt-in and dev-only; production stays loopback. In a
disposable NAT'd VM the listener is reachable only from the host (and at most one
sibling VM), never the LAN/internet, and **every request still requires the
bearer token**. The direct driver persists nothing to `~/.claude.json`. All three
flags are stripped from Mac App Store builds by `RAYMOL_MAS_RESTRICTED`.
