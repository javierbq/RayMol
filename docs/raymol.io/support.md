# RayMol Support

**RayMol** is a native molecular visualization app for macOS, iPad, and iPhone —
real-time Metal rendering (cartoon, sticks, spheres, surfaces), hardware ray
tracing, themes, measurements, movies, PyMOL scripting, and — on macOS —
control by your own Claude (Claude Code or the Claude app) via a built-in MCP
server.

## Getting help

- **Email:** support@raymol.io
- **Issues / feature requests:** https://github.com/javierbq/RayMol/issues

When reporting a problem, it helps to include your device + OS version, the app
version (Settings shows it), and the steps to reproduce.

## Common topics

- **Opening structures:** use **Open File** for local `.pdb`/`.cif`/`.pse` and
  related formats, or **Fetch from PDB** to download by 4-letter PDB ID.
- **Drive RayMol with Claude (macOS):** RayMol has a built-in MCP server, so you
  can control it from your own Claude — either Claude Code or the Claude desktop
  app. It's off by default; turn it on under the **Connect** menu, then choose
  **Connect an AI app…** to link Claude. No API key is required — it uses your
  existing Claude. The server is local-only (127.0.0.1), token-protected, and
  asks you to approve each connection before it can drive the app.
- **Privacy:** see the [Privacy Policy](https://raymol.io/privacy).

---

RayMol is an independent application built on the open-source
[PyMOL](https://pymol.org) project (© Schrödinger, LLC), distributed under a
BSD-like license. RayMol is not affiliated with or endorsed by Schrödinger.
