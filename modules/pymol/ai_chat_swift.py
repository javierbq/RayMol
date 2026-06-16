"""Headless delivery sink for the AI chat backend in the SwiftUI/Metal app.

This module is a drop-in replacement for ``pymol.ai_chat_ui`` (the AppKit/PyObjC
chat panel) on platforms where AppKit is unavailable (iOS) or unwanted (the
native SwiftUI macOS app). It exposes the SAME hook function names that
``pymol.ai_chat`` calls on its UI layer, but instead of driving NSViews it
emits *tagged feedback lines* via ``print()``.

Those lines flow through the embedded interpreter's stdout into PyMOL's
feedback buffer (``cmd._get_feedback``), which ``PyMOLEngine.pollFeedback``
drains every 100 ms and parses. Because the poll splits the buffer on newlines,
any text that may contain newlines (assistant messages, errors, the questions
JSON) is base64-encoded so it survives the split as a single line.

Tag protocol (parsed in PyMOLEngine.swift):

    AICHAT:user:<base64>        user echo (role == 'user')
    AICHAT:assistant:<base64>   assistant message
    AICHAT:result:<base64>      tool/result message
    AICHAT:error:<base64>       error message
    AISTATUS:<plain text>       transient status ('Thinking...', '' to clear)
    AIQUESTIONS:<base64 json>   follow-up question buttons (list of dicts)
    AIBUSY:1 / AIBUSY:0         worker started / finished
    AIDONE:                     turn finished (emitted alongside AIBUSY:0)

The bytes are flushed immediately so each line reaches the next poll tick
promptly rather than sitting in a buffer until the worker exits.
"""

import base64
import json
import sys


# ---------------------------------------------------------------------------
# Low-level emit helpers
# ---------------------------------------------------------------------------

def _b64(text):
    """UTF-8 → base64 ASCII (single line, newline-safe)."""
    if text is None:
        text = ''
    return base64.b64encode(str(text).encode('utf-8')).decode('ascii')


def _emit(line):
    """Print one tagged feedback line and flush so the poll picks it up now."""
    try:
        print(line)
        sys.stdout.flush()
    except Exception:
        # Never let a delivery failure crash the worker thread.
        pass


# ---------------------------------------------------------------------------
# Hook surface — mirrors pymol.ai_chat_ui exactly so ai_chat can bind to either
# ---------------------------------------------------------------------------

def _init():
    """No-op: the SwiftUI panel owns its own lifecycle. Present for parity."""
    pass


def toggle():
    """No-op: the SwiftUI app toggles the panel natively, not via Python."""
    pass


def show_message(role, text):
    """Append a message to the SwiftUI chat. role: user|assistant|result|error."""
    tag = role if role in ('user', 'assistant', 'result', 'error') else 'assistant'
    _emit('AICHAT:%s:%s' % (tag, _b64(text)))


def show_status(text):
    """Transient status line ('Thinking...', 'Executing...', '' clears it)."""
    # Status is short and single-line by construction; keep it plain so the
    # Swift side can show it directly without decoding.
    _emit('AISTATUS:%s' % ('' if text is None else str(text).replace('\n', ' ')))


def hide_status():
    """Clear the status indicator."""
    show_status('')


def set_busy(busy):
    """Worker started (True) / finished (False). Drives the typing indicator."""
    _emit('AIBUSY:1' if busy else 'AIBUSY:0')
    if not busy:
        # Signal end-of-turn so the UI can settle (clear pending status, etc.).
        _emit('AIDONE:')


def is_cancel_requested():
    """No cancel affordance in the headless sink (yet); never cancel."""
    return False


def update_on_main_thread(role, content, results, status=None):
    """Thread-safe UI update used by both ai_chat workers.

    Matches ai_chat_ui.update_on_main_thread: when *status* is provided and
    *role* is None it's a status-only update; otherwise it's a message. There is
    no main thread to hop to here — emitting to stdout is already thread-safe
    (the worker holds the GIL), so we forward directly.
    """
    if status is not None and role is None:
        show_status(status)
        return
    show_message(role, content)


def show_question_buttons(questions):
    """Follow-up question buttons. *questions*: [{text, type?, options[]}]."""
    if not questions:
        return
    try:
        payload = json.dumps(questions)
    except Exception:
        return
    _emit('AIQUESTIONS:%s' % _b64(payload))


def clear_messages():
    """Reset the conversation in the SwiftUI chat."""
    _emit('AICHAT:clear:')
