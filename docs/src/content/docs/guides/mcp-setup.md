---
title: Claude MCP Integration
description: Connect Claude for Mac or Claude Code to RayMol through the Model Context Protocol.
---

RayMol's local MCP server lets a supported AI app fetch structures, run PyMOL commands, inspect scenes, and capture the current viewport. Connections are local and token-protected.

:::note
MCP is available in the Homebrew and direct-download macOS builds. It is not included in the sandboxed App Store build.
:::

## Connect Claude Code

1. Launch RayMol.
2. Choose **Connect → Connect an AI app…**.
3. Turn on **RayMol MCP server** if it is not already running.
4. Under **Claude Code**, click **Connect**. If Claude Code is not detected, copy and run the manual command shown in the sheet.
5. Approve the connection in Claude when prompted.

## Connect Claude for Mac

1. In the same **Connect an AI app** sheet, start the RayMol MCP server.
2. Choose **Install for Claude (.mcpb)** and confirm the install in Claude, or choose **Set it up for me**.
3. Restart Claude if the installer asks you to.

The RayMol toolbar shows the MCP connection status. Disable the local server from the connection sheet whenever AI control is not needed.
