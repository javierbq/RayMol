# AI Chat Panel Design Spec

## Problem

The current AI mode hijacks PyMOL's GLUT command prompt, toggling between command and AI input. This is clunky — the user loses the PyMOL prompt, can't paste easily, and there's no conversation history. The experience should be a dedicated chat panel that feels native and supports agentic multi-turn conversations.

## Solution

A native macOS NSPanel (via PyObjC) docked to the left of the PyMOL window, providing a chat interface for LLM-powered PyMOL control. The panel shows a scrollable conversation history, has a native text input with full macOS editing support (Cmd+V, selection, undo), and executes generated commands automatically.

## Architecture

### Components

1. **`modules/pymol/ai_chat.py`** — Conversation engine. Manages message history, LLM calls, command execution with result capture, agentic retry on errors. Replaces `ai_mode.py`.

2. **`modules/pymol/ai_chat_ui.py`** — PyObjC/AppKit UI. Creates and manages the NSPanel with:
   - NSScrollView + NSTextView for message display (read-only, attributed strings for styling)
   - NSTextField at bottom for user input
   - Send button (or Enter to submit)
   - "Thinking..." spinner/indicator
   - Resize handle on right edge

3. **LLM providers** — Reused from current `ai_mode.py` (Anthropic, OpenAI, Gemini via urllib.request). Moved into `ai_chat.py`.

4. **`ai_config` command** — Stays as a PyMOL command for setting provider/key/model at runtime.

### Panel Behavior

- **Toggle open/close:** Cmd+L keyboard shortcut (intercepted via Cocoa, not GLUT) + clickable "AI" tab on the left edge of the viewport
- **Docked left:** Panel sits to the left of the 3D viewport, resizing it. Not an overlay.
- **Default width:** ~320px, resizable by dragging the right edge
- **Window tracking:** Panel position follows the GLUT window
- **Collapsible:** When closed, only a small "AI" tab is visible on the left edge

### Conversation Model (Agentic)

Each LLM call includes:
- **System prompt** — PyMOL command reference + agentic instructions ("you can observe results and self-correct")
- **Full conversation history** — all user messages, AI responses, and command execution results
- **Fresh session state** — current objects, selections, gathered via `cmd.get_names()` at call time

After the AI responds with commands:
1. Execute each command via `cmd.do()`, capture output and errors
2. Append execution results to conversation history (e.g., "Executed: `fetch 1a3n` → OK" or "Error: ...")
3. If any command errored, automatically re-prompt the LLM with the error for self-correction (max 2 retries per turn)
4. Display everything in the chat panel — user message, AI commands, execution results

### Message Types in Chat

- **User message** — natural language input, right-aligned bubble
- **AI response** — generated commands shown as code blocks, left-aligned
- **Execution result** — success/error for each command, shown inline below the AI response
- **Status** — "Thinking..." indicator with spinner

### What Gets Removed

- `AIMode` flag in COrtho class (Ortho.cpp)
- AI mode input routing in `OrthoParseCurrentLine` (the `if (I->AIMode)` block)
- Shift+Tab interception in OrthoKey case 9
- `OrthoSetAIMode()` / `OrthoGetAIMode()` functions
- `CmdSetAIMode` in Cmd.cpp and its method table entry
- `modules/pymol/ai_mode.py` (replaced by ai_chat.py + ai_chat_ui.py)
- The `ai` toggle command
- `cmd._toggle_ai_mode` registration

### What Stays

- `OrthoSetPrompt()` and `CmdSetPrompt` — useful general utility
- Ctrl+V clipboard paste fix in Ortho.cpp
- `_get_system_clipboard()` in externing.py
- LLM provider logic (moved to ai_chat.py)

### Dependencies

- **pyobjc-framework-Cocoa** — for NSPanel, NSTextField, NSTextView, NSScrollView. Install via `pip install pyobjc-framework-Cocoa`.
- Optional dependency: if PyObjC is not installed, `ai_chat_ui.py` import fails gracefully and the chat panel is disabled with a message. `ai_config` still works; the feature just has no UI. This makes the build safe on Linux/Windows.
- Add `pyobjc-framework-Cocoa` to `pyproject.toml` under a new `[ai]` optional dependency group.

### GLUT/Cocoa Event Loop Coexistence

On macOS, freeglut internally uses a Cocoa NSApplication for its event loop. The GLUT main loop (`glutMainLoop`) drives `[NSApp run]` under the hood. This means Cocoa UI elements (NSPanel, NSTextField) work naturally — they receive events from the same run loop.

Strategy:
- Create the NSPanel lazily on first toggle. Since we're already inside `[NSApp run]` (via freeglut), the panel's event handling (typing, clicking, scrolling) works automatically.
- The Cmd+L monitor (`NSEvent.addLocalMonitorForEvents`) hooks into the same NSApp event stream.
- No need for a separate run loop, timer pumping, or secondary threads for UI.
- LLM HTTP calls run in a `threading.Thread` (same as current `ai_mode.py`). When results arrive, use `performSelectorOnMainThread:` to update the NSTextView safely.

### Viewport Resize (Docked Panel)

The GLUT window itself does not move or resize. Instead:
1. When the panel opens, call `glutPositionWindow` and `glutReshapeWindow` to shrink the GLUT window rightward by the panel width, and position the NSPanel in the vacated space on the left.
2. Alternatively (simpler): use `glViewport(panel_width, 0, window_width - panel_width, window_height)` to render the 3D scene only in the right portion. The NSPanel overlays the left portion of the GLUT window. This avoids moving the GLUT window entirely.
3. The NSPanel is created as a child window of the GLUT window's NSWindow (obtained via freeglut internals or `NSApp.mainWindow`), positioned at `(0, 0)` with height matching the GLUT window.

Recommended: **Option 2** (glViewport adjustment + overlay). It's simpler, avoids GLUT window management issues, and the NSPanel naturally sits on top of the left portion. PyMOL's `OrthoReshape` already handles viewport changes — we hook into it by adjusting the scene margins.

### Command Output Capture

Use `io.StringIO` to capture stdout/stderr around each `cmd.do()` call:

```python
import io, sys
old_stdout = sys.stdout
sys.stdout = capture = io.StringIO()
try:
    cmd.do(command)
finally:
    sys.stdout = old_stdout
output = capture.getvalue()
```

For PyMOL-specific feedback, also call `cmd._get_feedback()` after execution to capture internal messages. Combine both into the execution result string.

### Keyboard Shortcut (Cmd+L)

Intercepted at the Cocoa level using `NSEvent.addLocalMonitorForEvents` in the UI module. Since freeglut runs `[NSApp run]`, this monitor receives all key events including Cmd+L before GLUT sees them. Return `None` from the monitor to swallow the event.

### "AI" Tab (Collapsed State)

When the panel is closed, a small NSButton (styled as a vertical "AI" label) is placed at the left edge of the GLUT window as a child window. Clicking it toggles the panel open. When the panel is open, the button is hidden. This is a lightweight Cocoa NSWindow (not rendered in OpenGL).

### Conversation History Limits

- Maximum 50 messages in history (user + AI + results combined)
- When exceeded, oldest messages are dropped (sliding window)
- A "New conversation" button in the panel header clears history
- History does NOT persist across PyMOL sessions (in-memory only)

### System Prompt (Agentic)

The system prompt changes from "output ONLY commands" to an agentic format:

```
You are an AI assistant controlling PyMOL. You generate PyMOL commands to fulfill user requests.

Rules:
- Output PyMOL commands, one per line, no markdown fences
- After each turn, you will see execution results (success or error for each command)
- If a command errors, analyze the error and try a corrected approach
- You may briefly explain your reasoning (one line) before the commands
- Use the session state provided to understand what's currently loaded

[PyMOL command reference...]
```

This allows the AI to explain its reasoning in the chat while still producing executable commands.

### Panel ↔ PyMOL Communication

- **User submits message** → `ai_chat._on_user_message(text)` called from UI callback
- **LLM call** → `threading.Thread` makes HTTP request
- **AI generates commands** → thread calls `cmd.do(command)` (thread-safe, uses PyMOL's command queue)
- **Command output capture** → stdout redirect + `cmd._get_feedback()` around each `cmd.do()`
- **Panel update** → `performSelectorOnMainThread:` to append messages to NSTextView
- **Error retry** → if errors detected, automatically re-prompt LLM with error context (max 2 retries)

### Error Display

Additional message type:
- **LLM error** — network timeout, auth failure, rate limit. Displayed as a red-tinted bubble with retry button.

### Graceful Degradation

```python
# In ai_chat.py
try:
    from pymol import ai_chat_ui
    _has_ui = True
except ImportError:
    _has_ui = False
    # Chat panel unavailable — PyObjC not installed or not on macOS
```

If `_has_ui` is False, `ai_config` still works but toggle commands print "Chat panel requires macOS with pyobjc-framework-Cocoa."

### Initialization

In `modules/pymol/__init__.py`:
```python
from pymol import ai_chat
ai_chat._init(cmd)
```

`_init()` registers `ai_config` command and sets up the Cocoa panel (lazily — panel is created on first toggle, not at startup).

## Files

| File | Action | Description |
|------|--------|-------------|
| `modules/pymol/ai_chat.py` | New | Conversation engine, LLM providers, command execution |
| `modules/pymol/ai_chat_ui.py` | New | PyObjC/AppKit UI (NSPanel, views, layout) |
| `modules/pymol/ai_mode.py` | Delete | Replaced by ai_chat.py |
| `modules/pymol/__init__.py` | Modify | Import ai_chat instead of ai_mode |
| `layer1/Ortho.cpp` | Modify | Remove AIMode flag, AI routing, Shift+Tab; keep prompt setter and paste fix |
| `layer1/Ortho.h` | Modify | Remove OrthoSetAIMode/OrthoGetAIMode declarations |
| `layer4/Cmd.cpp` | Modify | Remove CmdSetAIMode; keep CmdSetPrompt |

## Verification

### Happy path
1. `pip install pyobjc-framework-Cocoa` in the venv
2. Rebuild PyMOL with `PREFIX_PATH=/opt/homebrew pip install --no-build-isolation --config-settings glut=true .`
3. Launch `pymol -x`
4. Press Cmd+L — chat panel appears on the left, viewport adjusts
5. Click "AI" tab when closed — same toggle behavior
6. Type "load hemoglobin and color by chain" — commands generated and executed
7. Send a follow-up message — verify conversation history persists
8. Verify error self-correction: ask for something that will fail, confirm AI retries
9. Press Cmd+L again — panel closes, viewport restores
10. `ai_config` command still works from PyMOL console
11. "New conversation" button clears history

### Failure modes
12. No API key configured → send a message → should show clear error in chat, not crash
13. LLM returns garbage/unparseable output → should display error bubble, not crash
14. Network timeout → should show timeout error with retry option
15. Resize GLUT window while panel is open → panel should track new size
16. Minimize/restore GLUT window → panel should reappear correctly
17. Without PyObjC installed → `ai_config` works, toggle prints "requires pyobjc" message
