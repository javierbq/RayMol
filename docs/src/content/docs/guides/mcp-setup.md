---
title: Model Context Protocol (MCP) Integration
description: Connect AI assistants like Claude Code and Claude for Mac to RayMol over the Model Context Protocol to automate visualization and analysis.
---

RayMol features a built-in Model Context Protocol (MCP) server that lets AI assistants and agents interact with your active molecular session. Through MCP, an AI client can load structures from the PDB, inspect loaded molecules and atom selections, execute PyMOL commands, run custom Python scripts, set up studio lighting, materials and render effects, predict structures on your Mac, export images and movies, and capture images of the viewport (640×480 by default, up to 2048×2048) to verify its visual output.

:::note[Platform availability]
The MCP server is available only in the direct-download macOS build (Homebrew or DMG). It is not included in the Mac App Store build and is not available on iPhone or iPad.
:::

## How it works & security model

RayMol's MCP integration is designed for security and transparency:

- **Local loopback only:** The server binds strictly to the local loopback address (`127.0.0.1`, default port `51737`). It cannot accept incoming connections from the local network or the internet.
- **Bearer token authentication:** Every request must provide a 32-character hexadecimal authorization token (`Authorization: Bearer <token>`) generated unique to your local RayMol installation.
- **Explicit authorization:** If a client connects that you didn't start from RayMol's own Connect buttons, RayMol asks **Allow Claude to control RayMol?**. Click **Allow**, or **Stop server** to turn the server off. Once allowed, connections are trusted until the server is turned off.
- **The "driving" banner:** Whenever an AI client invokes a tool in RayMol, a non-blocking green notification banner appears across the top of the RayMol window:
  
  ```text
  ● Claude is controlling RayMol · fetch 1ubq, async=0      [Stop]
  ```

  The banner displays the active command or action. Clicking **Stop** turns the MCP server off and disconnects all clients. A command already in progress finishes first.
- **Toolbar status indicator:** The RayMol toolbar includes an MCP status pill. The indicator dot glows yellow when the server is running without clients, turns green when an AI client is actively connected, and pulses while a tool is executing. Clicking the status pill displays recent activity logs and quick-connect options.

## Built-in MCP tools

RayMol tells connected AI models that it is not stock PyMOL. It gives them general tools for anything PyMOL can do, plus tools for RayMol's own features, so a model uses studio lights, materials and Metal rendering instead of falling back on PyMOL habits such as `ray` or `set light`.

General tools:

| Tool Name | Description |
| :--- | :--- |
| `run_pymol_command` | Executes a single PyMOL command statement (e.g., `fetch 1ubq, async=0`, `show cartoon`, `color marine, chain A`). |
| `run_python` | Evaluates Python code in a persistent execution namespace with access to the PyMOL API (`cmd`), NumPy (`np` if available), and Biopython (`Bio` if available). Global variables persist across consecutive calls. |
| `get_session_state` | Returns a structured JSON overview of the active session: loaded molecular objects, atom counts, named selections, current frame, the 18-float camera orientation matrix, and RayMol state (the light rig and atmosphere, render effects, materials, scenes and prediction jobs). |
| `capture_viewport` | Renders the live 3D viewport and returns a PNG image. Rendered images use RayMol's full Metal pipeline (including active studio light rigs and materials) so the AI model sees the exact scene. |
| `search_pdb` | Queries the RCSB Protein Data Bank via full-text search and returns matching PDB identifiers for subsequent retrieval. |

RayMol tools:

| Tool Name | Description |
| :--- | :--- |
| `set_lighting` | Studio lighting: apply a preset (`three_point`, `softbox`, `rembrandt`, `neon`, ...), add, edit or remove lights, or turn the rig on or off. Wraps the `lights` command. |
| `set_atmosphere` | Haze and dust in the light beams. Wraps the `atmosphere` command. |
| `set_material` | Sets a material (glass, metallic, marble, ...) per object and representation. |
| `set_render_effects` | Metal effects: ambient occlusion, shadows, real-time ray tracing, outlines, depth of field, tone mapping and exposure. |
| `export_image` | Saves a PNG rendered with Metal, the same render as **Save Image**. |
| `export_movie` | Renders the movie to MP4, MOV, GIF or PNG frames with the Metal exporter. Wraps `movie_export`. |
| `predict_structure` | Folds a sequence on your Mac with Boltz-2 or Protenix. Wraps `predict`. |
| `job_status` | Reports the state of prediction jobs. A finished structure loads into its placeholder object by itself. |
| `raymol_help` | Returns the RayMol feature guide, or the manual of any command. |

When a model uses a stock PyMOL idiom that RayMol replaces, such as `ray`, `png` or `set ray_shadows`, the command still runs, and the result includes a short note that names the RayMol tool to use instead.

## Connecting AI clients

To configure and launch the server:

![Connect an AI app sheet: RayMol MCP server toggle (on, listening on 127.0.0.1:51737), Claude Code section with Connect and Copy connection details buttons and the manual `claude mcp add --transport http raymol …` command, and Claude for Mac Install (.mcpb) / Set it up for me buttons](../../../assets/docs/mcp-connect.png)
*Connect ▸ Connect an AI app…*

1. Open RayMol on macOS.
2. Choose **Connect ▸ Connect an AI app…** from the menu bar, or choose **Connect ▸ Enable AI control** (`⌃⌘M`).
3. Toggle the **RayMol MCP server** switch to **On**. The sheet will confirm that the server is listening (for example, on `127.0.0.1:51737`).

### Claude Code

1. In the **Connect an AI app** sheet, locate the **Claude Code** section. If the CLI is installed, RayMol displays `✓ detected`. RayMol looks for the `claude` CLI in /opt/homebrew/bin, /usr/local/bin, ~/.claude/local and ~/.local/bin; otherwise the sheet shows it as not found and **Connect** shows the manual command.
2. Click **Connect**. RayMol registers itself with Claude Code (user scope) and adds a RayMol skill. In Claude Code, run `/mcp` or restart it.
3. Alternatively, click **Copy connection details** to copy the manual CLI command to your clipboard:

```bash
claude mcp add --transport http raymol http://127.0.0.1:51737/mcp --header "Authorization: Bearer <token>" --scope user
```

4. Run the command in your terminal, then click **Allow** in RayMol's prompt the first time Claude connects.

### Claude for Mac (Desktop)

Claude for Mac connects through a small helper mode of the RayMol app (`RayMol --mcp-bridge`):

1. In the **Connect an AI app** sheet, navigate to **Claude for Mac**.
2. Choose one of two installation methods:
   - **Install for Claude (.mcpb):** Generates an official `.mcpb` bundle in your Downloads folder and opens it in Claude. Confirm the prompt inside Claude, then restart the Claude app.
   - **Set it up for me:** Automatically merges the RayMol MCP bridge configuration directly into `~/Library/Application Support/Claude/claude_desktop_config.json`.
3. Restart Claude for Mac if instructed. You can now prompt Claude to visualize proteins, adjust colors, and inspect structures in RayMol.

### Other MCP clients

Any MCP client supporting the Streamable HTTP transport (JSON-RPC 2.0 over HTTP POST) can connect to RayMol:

- **Endpoint URL:** `http://127.0.0.1:<port>/mcp` (default port `51737`)
- **Headers:**
  - `Content-Type: application/json`
  - `Authorization: Bearer <your-token>`

For other clients, choose **Connect ▸ Copy connection details** to copy the endpoint URL and the `Authorization: Bearer …` header. (The sheet's own Copy button copies the full `claude mcp add …` command.) Both work only while the server is on.

## Troubleshooting

- **Server is off:** Ensure the **RayMol MCP server** toggle is enabled in **Connect ▸ Connect an AI app…**. If RayMol is quit and reopened, verify that the server has started.
- **Port already in use:** If port 51737 is in use, quit the other program using it (often a second copy of RayMol) and toggle the server off and on.
- **Connection refused or authentication failed:** If Claude fails to connect, choose **Connect ▸ Copy connection details** to copy the endpoint URL and the `Authorization: Bearer …` header (the sheet's own Copy button copies the full `claude mcp add …` command; both work only while the server is on), and update your client's authorization header with the active token.
- **Claude desktop not detecting tools:** Ensure you have completely quit Claude for Mac (`⌘Q`) and reopened it after running **Set it up for me** or installing the `.mcpb` bundle.
