#!/bin/bash
# End-to-end check for the MCP broker.
#
#   1. a client handshake (initialize + tools/list) must NOT launch anything
#   2. a tools/call with nothing running MUST cold-launch the app and return
#
# Drives a SUFFIXED dev build via RAYMOL_MCP_INSTALLED_APP so it never clobbers
# the user's installed /Applications/RayMol.app.
#
# Usage: swiftui/tools/mcp_broker_e2e.sh /path/to/RayMol-broker.app
set -uo pipefail
APP="${1:?usage: mcp_broker_e2e.sh /path/to/RayMol-<suffix>.app}"
NAME="$(basename "$APP" .app)"
BIN="$APP/Contents/MacOS/$NAME"
REG="$HOME/Library/Application Support/RayMol/instances"
export RAYMOL_MCP_INSTALLED_APP="$APP"

[ -x "$BIN" ] || { echo "FAIL: no executable at $BIN"; exit 1; }

echo "== quitting $NAME =="
pkill -x "$NAME" 2>/dev/null
sleep 3
echo "registry after quit: $(ls "$REG" 2>/dev/null | wc -l | tr -d ' ') entries"

echo "== initialize + tools/list must NOT launch anything =="
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | "$BIN" --mcp-bridge | head -2 | cut -c1-160
sleep 2
if pgrep -x "$NAME" >/dev/null; then echo "FAIL: a client handshake launched the app"; exit 1; fi
echo "OK: handshake did not launch the app"

echo "== tools/call must cold-launch =="
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session_state","arguments":{}}}' \
  | "$BIN" --mcp-bridge | tail -1 | cut -c1-400
echo
pgrep -x "$NAME" >/dev/null && echo "OK: $NAME is running" || { echo "FAIL: not launched"; exit 1; }
echo "registry now: $(ls "$REG" 2>/dev/null | wc -l | tr -d ' ') entries"
ls "$REG" 2>/dev/null
