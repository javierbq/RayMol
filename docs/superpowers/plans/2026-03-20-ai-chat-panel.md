# AI Chat Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the console-based AI mode toggle with a native macOS Cocoa chat panel docked to the left of the PyMOL viewport, supporting agentic multi-turn LLM conversations.

**Architecture:** A PyObjC NSPanel overlays the left portion of the GLUT window. `glViewport` is adjusted so the 3D scene renders only in the right portion. The conversation engine runs LLM calls in background threads; UI updates happen on the main thread via `performSelectorOnMainThread:`. The panel is created lazily on first toggle.

**Tech Stack:** Python, PyObjC (pyobjc-framework-Cocoa), AppKit (NSPanel, NSTextView, NSTextField, NSScrollView), urllib.request for LLM HTTP calls, threading for async.

**Spec:** `docs/superpowers/specs/2026-03-20-ai-chat-panel-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `modules/pymol/ai_chat.py` | Create | Conversation engine: message history, LLM providers, command execution with output capture, agentic retry, `ai_config` command |
| `modules/pymol/ai_chat_ui.py` | Create | PyObjC/AppKit UI: NSPanel, NSTextView message display, NSTextField input, Cmd+L shortcut, "AI" tab button, window tracking |
| `modules/pymol/ai_mode.py` | Delete | Replaced entirely by ai_chat.py |
| `modules/pymol/__init__.py` | Modify (line 607-608) | Change `ai_mode` import to `ai_chat` |
| `layer1/Ortho.cpp` | Modify | Remove AIMode flag, AI routing in OrthoParseCurrentLine, Shift+Tab interception |
| `layer1/Ortho.h` | Modify (line 117-119) | Remove OrthoSetAIMode/OrthoGetAIMode declarations |
| `layer4/Cmd.cpp` | Modify | Remove CmdSetAIMode function and method table entry |
| `pyproject.toml` | Modify (line 29) | Add `[ai]` optional dependency group |

---

### Task 1: Install PyObjC and verify Cocoa works in GLUT context

**Files:**
- Modify: `pyproject.toml:29-37`

- [ ] **Step 1: Install PyObjC in the venv**

```bash
source .venv/bin/activate
pip install pyobjc-framework-Cocoa
```

- [ ] **Step 2: Verify PyObjC can create a window alongside GLUT**

```bash
source .venv/bin/activate
pymol -cqx -d "python import AppKit; print('AppKit OK:', AppKit.NSApp is not None)"
```

Expected: prints `AppKit OK: True` (confirms freeglut has initialized NSApp)

- [ ] **Step 3: Add optional dependency to pyproject.toml**

Add after the `dev` group at line 37:

```toml
ai = [
  "pyobjc-framework-Cocoa>=10.0; sys_platform == 'darwin'",
]
```

- [ ] **Step 4: Commit**

```bash
git add pyproject.toml
git commit -m "feat: add pyobjc-framework-Cocoa as optional [ai] dependency"
```

---

### Task 2: Remove old AI mode from C++ and Python

**Files:**
- Modify: `layer1/Ortho.cpp`
- Modify: `layer1/Ortho.h:117-119`
- Modify: `layer4/Cmd.cpp`
- Delete: `modules/pymol/ai_mode.py`
- Modify: `modules/pymol/__init__.py:607-608`

- [ ] **Step 1: Remove AIMode from Ortho.cpp**

In `layer1/Ortho.cpp`:

1. Remove `bool AIMode{};` from COrtho class (~line 111)
2. Remove `OrthoSetAIMode()` and `OrthoGetAIMode()` functions (~line 329-340)
3. Revert Shift+Tab interception in case 9 (~line 963): remove the `if (mod & cOrthoSHIFT)` block, restore original:
```cpp
    case 9: /* CTRL I -- tab */
      if (mod & cOrthoCTRL) {
```
4. Revert AI routing in `OrthoParseCurrentLine` (~line 1074-1082): replace the `if (I->AIMode)` block with just:
```cpp
    PParse(G, buffer);
```

Keep: `OrthoSetPrompt()` function and Ctrl+V paste fix.

- [ ] **Step 2: Remove AIMode declarations from Ortho.h**

Remove these 2 lines (~line 118-119):
```cpp
void OrthoSetAIMode(PyMOLGlobals * G, bool mode);
bool OrthoGetAIMode(PyMOLGlobals * G);
```

Keep: `void OrthoSetPrompt(PyMOLGlobals * G, const char *prompt);`

- [ ] **Step 3: Remove CmdSetAIMode from Cmd.cpp**

1. Remove the `CmdSetAIMode` function (~line 2218-2227)
2. Remove `{"set_ai_mode", CmdSetAIMode, METH_VARARGS},` from `Cmd_methods[]` (~line 6662)

Keep: `CmdSetPrompt` and its method table entry.

- [ ] **Step 4: Delete ai_mode.py and update __init__.py**

```bash
rm modules/pymol/ai_mode.py
```

In `modules/pymol/__init__.py`, replace lines 607-608:
```python
    from pymol import ai_mode
    ai_mode._init(cmd)
```
With:
```python
    from pymol import ai_chat
    ai_chat._init(cmd)
```

- [ ] **Step 5: Verify build**

```bash
rm -rf build
source .venv/bin/activate
PREFIX_PATH=/opt/homebrew pip install --no-build-isolation --config-settings glut=true .
pymol -cqx -d "print('build OK')"
```

Expected: `build OK`, no import errors.

- [ ] **Step 6: Commit**

```bash
git add layer1/Ortho.cpp layer1/Ortho.h layer4/Cmd.cpp modules/pymol/__init__.py
git rm modules/pymol/ai_mode.py
git commit -m "refactor: remove console-based AI mode in preparation for chat panel"
```

---

### Task 3: Create ai_chat.py — conversation engine and LLM providers

**Files:**
- Create: `modules/pymol/ai_chat.py`

- [ ] **Step 1: Create ai_chat.py with config, providers, and conversation engine**

Create `modules/pymol/ai_chat.py` with:

1. **Config and state** — same `_ai_config` dict from old ai_mode.py (provider, api_keys, models from env vars)
2. **`_init(cmd)`** — registers `ai_config` command, attempts lazy UI import
3. **`ai_config(args)`** — same as before (show/set provider, key, model)
4. **`_toggle_panel()`** — calls `ai_chat_ui.toggle()` if available, else prints error
5. **Conversation history** — `_messages` list of dicts `{'role': 'user'|'assistant'|'result'|'error', 'content': str}`, capped at 50 entries
6. **`_on_user_message(text)`** — appends user message, spawns LLM thread
7. **`_call_llm()`** — builds messages array with system prompt + history + session state, calls provider
8. **`_execute_commands(response_text)`** — parses response into commands, executes each with stdout capture, returns results list
9. **`_handle_response(response_text)`** — executes commands, appends results, retries on error (max 2)
10. **LLM provider functions** — `_call_anthropic`, `_call_openai`, `_call_gemini` (copied from ai_mode.py)
11. **`_get_session_context()`** — gathers objects/selections
12. **`SYSTEM_PROMPT`** — agentic version (allows brief reasoning + commands)
13. **`clear_conversation()`** — resets `_messages` list

Key difference from ai_mode.py: the conversation is stateful. Each LLM call sends the full history so it can self-correct.

The `_on_user_message` flow:
```python
def _on_user_message(text):
    _messages.append({'role': 'user', 'content': text})
    if _has_ui:
        ai_chat_ui.show_message('user', text)
        ai_chat_ui.show_status('Thinking...')

    def _worker():
        try:
            response = _call_llm()
            results = _execute_commands(response)
            _messages.append({'role': 'assistant', 'content': response})
            for r in results:
                _messages.append({'role': 'result', 'content': r})
            # Trim history
            while len(_messages) > 50:
                _messages.pop(0)
            if _has_ui:
                ai_chat_ui.update_on_main_thread('assistant', response, results)
        except Exception as e:
            if _has_ui:
                ai_chat_ui.update_on_main_thread('error', str(e), [])

    threading.Thread(target=_worker, daemon=True).start()
```

- [ ] **Step 2: Verify ai_chat.py imports without UI**

```bash
source .venv/bin/activate
python3 -c "from pymol import ai_chat; print('ai_chat imported, has_ui:', ai_chat._has_ui)"
```

Expected: `ai_chat imported, has_ui: False` (since ai_chat_ui.py doesn't exist yet)

- [ ] **Step 3: Verify ai_config works in PyMOL**

```bash
pymol -cqx -d "ai_config"
```

Expected: prints current AI config (provider, model, key status)

- [ ] **Step 4: Commit**

```bash
git add modules/pymol/ai_chat.py
git commit -m "feat: add ai_chat.py conversation engine with LLM providers"
```

---

### Task 4: Create ai_chat_ui.py — NSPanel with message display

**Files:**
- Create: `modules/pymol/ai_chat_ui.py`

- [ ] **Step 1: Create ai_chat_ui.py with panel, message view, and input**

Create `modules/pymol/ai_chat_ui.py` with PyObjC:

1. **`_panel`** — NSPanel instance (None until first toggle). Style: `NSWindowStyleMaskTitled | NSWindowStyleMaskResizable`. Non-activating (`NSWindowStyleMaskNonactivatingPanel`) so GLUT keeps focus for 3D interaction when clicking the viewport.
2. **`_message_view`** — NSTextView inside NSScrollView (read-only). Uses NSAttributedString for message styling (different colors for user/AI/result/error).
3. **`_input_field`** — NSTextField at the bottom. Delegate handles Enter key to submit.
4. **`_send_button`** — NSButton "Send" next to input field.
5. **`_status_label`** — NSTextField (label) for "Thinking..." status.
6. **`_new_convo_button`** — NSButton "New" in header to clear conversation.
7. **`_tab_window`** — small NSWindow with "AI" button, shown when panel is hidden.

Layout (from top to bottom):
- Header bar: "AI Chat" label + "New" button (24px)
- Message scroll view (fills remaining space)
- Status label (hidden when not thinking)
- Input field + Send button (40px)

8. **`_init()`** — installs Cmd+L key monitor via `NSEvent.addLocalMonitorForEventsMatchingMask_handler_`
9. **`toggle()`** — shows/hides panel, adjusts GLUT viewport, shows/hides tab
10. **`_get_glut_window()`** — gets the GLUT NSWindow via `NSApp.mainWindow()` or `NSApp.windows()[0]`
11. **`_position_panel()`** — positions panel at left edge of GLUT window, matching its height
12. **`_observe_glut_resize()`** — uses `NSNotificationCenter` to watch for `NSWindowDidResizeNotification` on the GLUT window, repositions panel accordingly
13. **Message display functions:**
    - `show_message(role, text)` — appends styled text to message view
    - `show_status(text)` / `hide_status()` — shows/hides thinking indicator
    - `update_on_main_thread(role, content, results)` — dispatches UI update via `performSelectorOnMainThread:`

The Cmd+L monitor:
```python
def _key_handler(event):
    if event.modifierFlags() & AppKit.NSEventModifierFlagCommand:
        if event.charactersIgnoringModifiers() == 'l':
            toggle()
            return None  # swallow the event
    return event

AppKit.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
    AppKit.NSEventMaskKeyDown, _key_handler)
```

The GLUT viewport adjustment on toggle:
```python
def _adjust_viewport(panel_open, panel_width):
    """Adjust PyMOL's viewport to make room for the panel."""
    from pymol import cmd
    if panel_open:
        # Tell PyMOL to offset the viewport
        cmd.set('internal_gui_control_size', 0)  # if needed
        # Use _cmd to set viewport offset
        from pymol import _cmd
        _cmd.viewport(_cmd._COb, panel_width, 0)  # trigger reshape
    else:
        pass  # restore full viewport
```

Note: The exact viewport adjustment mechanism will need to be adapted based on how PyMOL's `OrthoReshape` works. The simplest approach is to call `glutReshapeWindow` after adjusting the panel, which triggers `OrthoReshape` naturally.

- [ ] **Step 2: Verify panel creation works**

```bash
source .venv/bin/activate
ANTHROPIC_API_KEY=test pymol -x
```

Then press Cmd+L in the PyMOL window. Expected: chat panel appears on the left.

- [ ] **Step 3: Commit**

```bash
git add modules/pymol/ai_chat_ui.py
git commit -m "feat: add native macOS chat panel UI with PyObjC"
```

---

### Task 5: Wire up panel ↔ conversation engine

**Files:**
- Modify: `modules/pymol/ai_chat.py`
- Modify: `modules/pymol/ai_chat_ui.py`

- [ ] **Step 1: Connect input submission to conversation engine**

In `ai_chat_ui.py`, the input field's action (Enter key or Send button click) calls:
```python
from pymol import ai_chat
ai_chat._on_user_message(text)
```

In `ai_chat.py`, the `_on_user_message` function calls UI update functions:
```python
if _has_ui:
    from pymol import ai_chat_ui
    ai_chat_ui.show_message('user', text)
    ai_chat_ui.show_status('Thinking...')
```

And the worker thread callback:
```python
if _has_ui:
    from pymol import ai_chat_ui
    ai_chat_ui.update_on_main_thread('assistant', response, results)
    ai_chat_ui.hide_status()
```

- [ ] **Step 2: Connect "New conversation" button**

The "New" button calls `ai_chat.clear_conversation()` which resets `_messages` and calls `ai_chat_ui.clear_messages()`.

- [ ] **Step 3: Connect error display**

LLM errors (network, auth, rate limit) are caught in the worker thread and displayed:
```python
except urllib.error.HTTPError as e:
    error_msg = "API error: %s %s" % (e.code, e.reason)
    if _has_ui:
        ai_chat_ui.update_on_main_thread('error', error_msg, [])
except Exception as e:
    if _has_ui:
        ai_chat_ui.update_on_main_thread('error', str(e), [])
```

- [ ] **Step 4: Test end-to-end with a real API key**

```bash
source .venv/bin/activate
ANTHROPIC_API_KEY=sk-ant-... pymol -x
```

1. Press Cmd+L to open panel
2. Type "fetch 1ubq and show as cartoon"
3. Verify: message appears in chat, "Thinking..." shows, commands appear, molecule loads
4. Send follow-up: "color it red"
5. Verify: AI remembers context, colors the molecule

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/ai_chat.py modules/pymol/ai_chat_ui.py
git commit -m "feat: wire up chat panel to conversation engine with agentic flow"
```

---

### Task 6: Add "AI" tab button and window tracking

**Files:**
- Modify: `modules/pymol/ai_chat_ui.py`

- [ ] **Step 1: Create the "AI" tab button**

When the panel is hidden, show a small NSWindow (24px wide, ~80px tall) at the left edge of the GLUT window. It contains a rotated "AI" label (NSButton). Clicking it calls `toggle()`.

```python
_tab_window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
    ((glut_x - 24, glut_y + glut_h // 2 - 40), (24, 80)),
    AppKit.NSWindowStyleMaskBorderless,
    AppKit.NSBackingStoreBuffered, False)
_tab_window.setLevel_(AppKit.NSFloatingWindowLevel)
_tab_window.setBackgroundColor_(AppKit.NSColor.colorWithRed_green_blue_alpha_(0.1, 0.1, 0.2, 0.95))
```

- [ ] **Step 2: Add window move/resize tracking**

Observe `NSWindowDidMoveNotification` and `NSWindowDidResizeNotification` on the GLUT window:
```python
AppKit.NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
    _observer, 'glutWindowMoved:', AppKit.NSWindowDidMoveNotification, glut_nswindow)
```

When the GLUT window moves or resizes, reposition the panel and tab to match.

- [ ] **Step 3: Test tracking behavior**

Launch PyMOL, open the panel, move/resize the GLUT window. Panel should follow. Close panel, verify "AI" tab appears and follows the window.

- [ ] **Step 4: Commit**

```bash
git add modules/pymol/ai_chat_ui.py
git commit -m "feat: add AI tab button and GLUT window tracking"
```

---

### Task 7: Final integration and cleanup

**Files:**
- Modify: `modules/pymol/__init__.py`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Rebuild and run full verification**

```bash
rm -rf build
source .venv/bin/activate
pip install pyobjc-framework-Cocoa
PREFIX_PATH=/opt/homebrew pip install --no-build-isolation --config-settings glut=true .
```

Run through all verification steps from the spec (happy path + failure modes).

- [ ] **Step 2: Update CLAUDE.md with new commands**

Add to the CLAUDE.md section about AI mode:
- `ai_config` command usage
- Cmd+L shortcut
- PyObjC dependency note

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md modules/pymol/__init__.py
git commit -m "docs: update CLAUDE.md with chat panel usage"
```

---

## Build & Test Commands

```bash
# Full rebuild
rm -rf build && source .venv/bin/activate && PREFIX_PATH=/opt/homebrew pip install --no-build-isolation --config-settings glut=true .

# Launch for testing
pymol -x

# Launch with API key
ANTHROPIC_API_KEY=sk-ant-... pymol -x

# Non-interactive test
pymol -cqx -d "ai_config" -d "print('OK')"
```
