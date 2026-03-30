"""Native macOS chat panel UI for PyMOL using PyObjC.

Modern chat-bubble interface with right-aligned user messages (blue bubbles)
and left-aligned assistant messages (green text on dark background).

In AppKit mode, the chat UI is embedded as a subview of the main window.
In legacy GLUT mode, it creates a floating NSPanel alongside the GLUT window.
Imported by pymol.ai_chat; raises ImportError on non-macOS platforms.
"""

import re
import threading
import AppKit
import Foundation
import objc

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_panel = None           # NSPanel instance (GLUT mode only, created lazily)
_visible = False        # current visibility
_scroll_view = None     # NSScrollView wrapping the message container
_message_container = None  # Flipped NSView holding message bubble subviews
_message_views = []     # list of message NSView subviews for clear_messages()
_input_field = None     # NSTextField for user input
_status_label = None    # NSTextField used as a status indicator
_delegate = None        # InputDelegate instance (prevent GC)
_key_monitor = None     # global event monitor reference
_embedded = False       # True when running inside AppKit host
_container_view = None  # NSView provided by the AppKit host

# Streaming state
_streaming_view = None  # the NSView currently being streamed into
_streaming_label = None  # the NSTextField inside the streaming view
_streaming_active = False

# Busy / cancel state
_busy = False
_cancel_requested = False
_send_button = None     # reference to the send button for appearance changes

# Question button targets (prevent GC)
_question_targets = []

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

_COLOR_BG = None        # dark bg, lazily created
_COLOR_USER_BUBBLE = None
_COLOR_USER_TEXT = None
_COLOR_ASSISTANT_TEXT = None
_COLOR_ERROR_TEXT = None
_COLOR_RESULT_TEXT = None
_COLOR_INPUT_BG = None
_COLOR_INPUT_TEXT = None
_COLOR_STATUS_TEXT = None
_COLOR_ACCENT = None
_COLOR_QUESTION_BG = None
_COLOR_QUESTION_TEXT = None


def _ensure_colors():
    """Create cached NSColor instances (must be called on main thread)."""
    global _COLOR_BG, _COLOR_USER_BUBBLE, _COLOR_USER_TEXT
    global _COLOR_ASSISTANT_TEXT, _COLOR_ERROR_TEXT, _COLOR_RESULT_TEXT
    global _COLOR_INPUT_BG, _COLOR_INPUT_TEXT, _COLOR_STATUS_TEXT, _COLOR_ACCENT
    global _COLOR_QUESTION_BG, _COLOR_QUESTION_TEXT

    if _COLOR_BG is not None:
        return

    _c = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_
    _COLOR_BG = _c(0.15, 0.15, 0.17, 1.0)             # #262629
    _COLOR_USER_BUBBLE = _c(0.29, 0.56, 0.85, 1.0)     # #4A90D9
    _COLOR_USER_TEXT = AppKit.NSColor.whiteColor()
    _COLOR_ASSISTANT_TEXT = _c(0.90, 0.90, 0.90, 1.0)   # near-white
    _COLOR_ERROR_TEXT = _c(0.88, 0.32, 0.32, 1.0)       # #E05252
    _COLOR_RESULT_TEXT = _c(0.53, 0.53, 0.53, 1.0)      # #888888
    _COLOR_INPUT_BG = _c(0.20, 0.20, 0.20, 1.0)         # #333333
    _COLOR_INPUT_TEXT = _c(0.90, 0.90, 0.90, 1.0)
    _COLOR_STATUS_TEXT = _c(0.53, 0.53, 0.53, 1.0)
    _COLOR_ACCENT = _c(0.29, 0.56, 0.85, 1.0)           # #4A90D9
    _COLOR_QUESTION_BG = _c(0.22, 0.22, 0.25, 1.0)      # slightly lighter
    _COLOR_QUESTION_TEXT = _c(0.70, 0.85, 1.0, 1.0)      # light blue


# ---------------------------------------------------------------------------
# Main-thread dispatch helper
# ---------------------------------------------------------------------------

# Module-level storage for main-thread dispatch (PyObjC class variables
# don't work reliably for storing Python callables on NSObject subclasses).
# A lock serializes concurrent callers so the shared globals are not
# clobbered when multiple worker threads call run_on_main_thread().
_mt_lock = threading.Lock()
_mt_func = None
_mt_result = None
_mt_event = None


class _MainThreadExecutor(AppKit.NSObject):
    """NSObject that executes a stored callable on the main thread."""

    def doExecute_(self, _ignored):
        global _mt_func, _mt_result, _mt_event
        try:
            _mt_result[0] = _mt_func()
        except Exception as exc:
            _mt_result[1] = exc
        finally:
            if _mt_event is not None:
                _mt_event.set()


def run_on_main_thread(func, timeout=10.0):
    """Execute *func* on the main thread and wait for the result.

    Uses performSelectorOnMainThread with waitUntilDone_:False plus a
    threading.Event to avoid deadlocks when the main thread is inside
    the PyMOL render loop.

    A threading.Lock serializes callers so the module-level globals
    (_mt_func, _mt_result, _mt_event) are not clobbered by concurrent
    worker threads.

    Returns the result of func(). Raises if func raised or if timeout.
    """
    if threading.current_thread() is threading.main_thread():
        return func()

    with _mt_lock:
        global _mt_func, _mt_result, _mt_event
        result = [None, None]  # [value, exception]
        event = threading.Event()
        _mt_func = func
        _mt_result = result
        _mt_event = event
        executor = _MainThreadExecutor.alloc().init()
        executor.performSelectorOnMainThread_withObject_waitUntilDone_(
            'doExecute:', None, False)
        if not event.wait(timeout=timeout):
            raise TimeoutError("run_on_main_thread timed out after %.1f seconds" % timeout)
        if result[1] is not None:
            raise result[1]
        return result[0]


# ---------------------------------------------------------------------------
# Streaming message support
# ---------------------------------------------------------------------------

class _StreamUpdater(AppKit.NSObject):
    """NSObject for dispatching streaming text updates to the main thread."""
    _text = ''

    def doStreamUpdate_(self, _ignored):
        _do_update_streaming_message(_StreamUpdater._text)


def begin_streaming_message():
    """Create an empty assistant bubble for streaming. Must be called from main thread."""
    global _streaming_view, _streaming_label, _streaming_active

    if _message_container is None or _scroll_view is None:
        return

    _ensure_colors()

    container_width = _scroll_view.contentView().bounds().size.width
    margin = 12.0
    max_text_width = container_width - 2 * margin

    font = AppKit.NSFont.systemFontOfSize_(13.0)
    # Start with empty text — will be filled as streaming text arrives
    label = _create_text_label(" ", font, _COLOR_ASSISTANT_TEXT, max_text_width)
    label_size = label.frame().size

    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin, 0, label_size.width, label_size.height))
    label.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(label)

    # Position below the last message
    y_offset = 0.0
    if _message_views:
        last = _message_views[-1]
        y_offset = last.frame().origin.y + last.frame().size.height + 8.0

    wrapper.setFrameOrigin_(AppKit.NSMakePoint(margin, y_offset))

    _message_container.addSubview_(wrapper)
    _message_views.append(wrapper)

    _streaming_view = wrapper
    _streaming_label = label
    _streaming_active = True

    _update_container_height()
    _scroll_to_bottom()


def update_streaming_message(text):
    """Update the in-progress streaming bubble. Thread-safe (dispatches to main thread)."""
    if not _streaming_active:
        return
    _StreamUpdater._text = text
    updater = _StreamUpdater.alloc().init()
    updater.performSelectorOnMainThread_withObject_waitUntilDone_(
        'doStreamUpdate:', None, False)


def _do_update_streaming_message(text):
    """Actually update the streaming label on the main thread."""
    global _streaming_view, _streaming_label

    if _streaming_label is None or _streaming_view is None:
        return
    if _scroll_view is None:
        return

    container_width = _scroll_view.contentView().bounds().size.width
    margin = 12.0
    max_text_width = container_width - 2 * margin

    display_text = text if text else "..."
    _streaming_label.setStringValue_(display_text)

    # Re-measure and resize
    font = _streaming_label.font()
    _tw, th = _measure_text(display_text, font, max_text_width)
    new_h = th + 4
    _streaming_label.setFrameSize_(AppKit.NSMakeSize(max_text_width, new_h))
    _streaming_view.setFrameSize_(AppKit.NSMakeSize(max_text_width, new_h))

    _update_container_height()
    _scroll_to_bottom()


def finalize_streaming_message():
    """Mark streaming as complete. Thread-safe (dispatches to main thread)."""
    finalizer = _StreamFinalizer.alloc().init()
    finalizer.performSelectorOnMainThread_withObject_waitUntilDone_(
        'doFinalize:', None, False)


class _StreamFinalizer(AppKit.NSObject):
    def doFinalize_(self, _ignored):
        global _streaming_view, _streaming_label, _streaming_active
        _streaming_view = None
        _streaming_label = None
        _streaming_active = False


# ---------------------------------------------------------------------------
# Question buttons
# ---------------------------------------------------------------------------

class _QuestionButtonTarget(AppKit.NSObject):
    """Target for question option buttons. Sends the option text as a user message."""
    _option_text = ''

    def buttonClicked_(self, sender):
        text = sender.title()
        if text:
            _DeferredMessage._pending_text = text
            Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.0, _DeferredMessage.alloc().init(), 'fire:', None, False)


# Store references to prevent GC
_question_targets = []


def show_question_buttons(questions):
    """Render clickable option buttons below the last message.

    *questions* is a list of dicts: [{"text": "Which chain?", "options": ["A", "B"]}]
    Dispatches to main thread if needed.
    """
    if not questions:
        return

    if threading.current_thread() is not threading.main_thread():
        _QuestionDispatcher._questions = questions
        dispatcher = _QuestionDispatcher.alloc().init()
        dispatcher.performSelectorOnMainThread_withObject_waitUntilDone_(
            'doShow:', None, False)
        return

    _do_show_question_buttons(questions)


class _QuestionDispatcher(AppKit.NSObject):
    _questions = None

    def doShow_(self, _ignored):
        _do_show_question_buttons(_QuestionDispatcher._questions)


def _do_show_question_buttons(questions):
    """Actually create and add question button views (must run on main thread).

    Builds all question groups, then adds ONE submit button at the bottom
    that collects answers from all groups.
    """
    global _question_targets

    if _message_container is None or _scroll_view is None:
        return

    _ensure_colors()

    container_width = _scroll_view.contentView().bounds().size.width
    margin = 12.0
    available_width = container_width - 2 * margin

    # Collect all checkbox/radio groups so the single Submit can read them
    all_groups = []  # list of (question_text, buttons_list, is_single)

    for q in questions:
        question_text = q.get('text', '')
        options = q.get('options', [])
        q_type = q.get('type', 'single')
        if not options:
            continue

        is_single = (q_type != 'multiple')
        wrapper, buttons = _build_choice_group(
            question_text, options, available_width, is_single)
        all_groups.append((question_text, buttons, is_single))

        # Position below last message
        y_offset = 0.0
        if _message_views:
            last = _message_views[-1]
            y_offset = last.frame().origin.y + last.frame().size.height + 8.0

        wrapper.setFrameOrigin_(AppKit.NSMakePoint(margin, y_offset))
        _message_container.addSubview_(wrapper)
        _message_views.append(wrapper)

    # Add ONE submit button at the bottom for all groups
    if all_groups:
        submit_height = 32.0
        submit_wrapper = AppKit.NSView.alloc().initWithFrame_(
            AppKit.NSMakeRect(margin, 0, available_width, submit_height))

        submit_btn = AppKit.NSButton.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, 100, submit_height))
        submit_btn.setTitle_("Submit")
        submit_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
        submit_btn.setFont_(AppKit.NSFont.boldSystemFontOfSize_(13.0))

        target = _ChoiceSubmitTarget.alloc().init()
        _ChoiceSubmitTarget._all_groups = all_groups
        submit_btn.setTarget_(target)
        submit_btn.setAction_('submitClicked:')
        _question_targets.append(target)
        submit_wrapper.addSubview_(submit_btn)

        y_offset = 0.0
        if _message_views:
            last = _message_views[-1]
            y_offset = last.frame().origin.y + last.frame().size.height + 8.0
        submit_wrapper.setFrameOrigin_(AppKit.NSMakePoint(margin, y_offset))
        _message_container.addSubview_(submit_wrapper)
        _message_views.append(submit_wrapper)

    _update_container_height()
    _scroll_to_bottom()


def _build_choice_group(question_text, options, available_width, is_single):
    """Build a question group with radio buttons (single) or checkboxes (multiple).

    Returns (wrapper_view, buttons_list). No submit button — the caller adds
    one shared Submit for all groups.
    """
    check_height = 22.0
    check_spacing = 4.0

    total_height = 0.0
    if question_text:
        total_height += 22.0
    total_height += len(options) * (check_height + check_spacing)

    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, available_width, total_height))

    cur_y = total_height

    if question_text:
        cur_y -= 20.0
        qlabel = AppKit.NSTextField.labelWithString_(question_text)
        qlabel.setFrame_(AppKit.NSMakeRect(0, cur_y, available_width, 18))
        qlabel.setFont_(AppKit.NSFont.systemFontOfSize_(11.0))
        qlabel.setTextColor_(_COLOR_STATUS_TEXT)
        wrapper.addSubview_(qlabel)
        cur_y -= 4.0

    buttons = []
    btn_type = AppKit.NSButtonTypeRadio if is_single else AppKit.NSButtonTypeSwitch
    for opt in options:
        cur_y -= check_height
        btn = AppKit.NSButton.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, cur_y, available_width, check_height))
        btn.setButtonType_(btn_type)
        btn.setTitle_(opt)
        btn.setFont_(AppKit.NSFont.systemFontOfSize_(12.0))
        btn.setState_(AppKit.NSControlStateValueOff)
        wrapper.addSubview_(btn)
        buttons.append(btn)
        cur_y -= check_spacing

    # Pre-select first radio option
    if is_single and buttons:
        buttons[0].setState_(AppKit.NSControlStateValueOn)

    return wrapper, buttons


class _ChoiceSubmitTarget(AppKit.NSObject):
    """Target for the shared Submit button across all question groups."""
    _all_groups = []  # list of (question_text, buttons_list, is_single)

    def submitClicked_(self, sender):
        parts = []
        for question_text, buttons, is_single in _ChoiceSubmitTarget._all_groups:
            selected = [b.title() for b in buttons
                        if b.state() == AppKit.NSControlStateValueOn]
            if selected:
                if is_single:
                    parts.append(selected[0])
                else:
                    parts.append(', '.join(selected))
        if parts:
            text = '; '.join(parts) if len(parts) > 1 else parts[0]
            _DeferredMessage._pending_text = text
            Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.0, _DeferredMessage.alloc().init(), 'fire:', None, False)


# ---------------------------------------------------------------------------
# Flipped container (top-to-bottom layout)
# ---------------------------------------------------------------------------

class _FlippedView(AppKit.NSView):
    """An NSView subclass that flips the coordinate system so origin is top-left."""

    def isFlipped(self):
        return True


# ---------------------------------------------------------------------------
# Public API called by ai_chat.py
# ---------------------------------------------------------------------------

def _init():
    """Install the Cmd+L key monitor (GLUT mode only)."""
    if not _embedded:
        _install_key_monitor()


def _setup_embedded(container_view):
    """Set up the chat UI inside a container view provided by the AppKit host."""
    global _embedded, _container_view, _visible
    _embedded = True
    _container_view = container_view
    _visible = True
    _build_chat_subviews(container_view)


def toggle():
    """Show or hide the chat panel."""
    global _visible

    if _embedded:
        return

    global _panel
    if _panel is None:
        _create_panel()

    _visible = not _visible
    glut_win = _get_glut_window()
    if _visible:
        if glut_win:
            _position_panel_and_shift_glut(glut_win, opening=True)
            _panel.orderFront_(None)
            glut_win.addChildWindow_ordered_(_panel, AppKit.NSWindowAbove)
        else:
            _panel.orderFront_(None)
    else:
        if glut_win and _panel:
            glut_win.removeChildWindow_(_panel)
            _position_panel_and_shift_glut(glut_win, opening=False)
        _panel.orderOut_(None)


def show_message(role, text):
    """Append a styled message bubble to the chat view.

    *role* is one of 'user', 'assistant', 'result', or 'error'.
    """
    if _message_container is None or _scroll_view is None:
        return

    _ensure_colors()

    container_width = _scroll_view.contentView().bounds().size.width
    bubble_view = _create_message_bubble(role, text, container_width)

    # Position below the last message
    y_offset = 0.0
    if _message_views:
        last = _message_views[-1]
        y_offset = last.frame().origin.y + last.frame().size.height + 8.0

    frame = bubble_view.frame()
    bubble_view.setFrameOrigin_(AppKit.NSMakePoint(frame.origin.x, y_offset))

    _message_container.addSubview_(bubble_view)
    _message_views.append(bubble_view)

    _update_container_height()
    _scroll_to_bottom()


def show_status(text):
    """Show the status label with the given text (e.g. 'Thinking...')."""
    if _status_label is None:
        return
    _status_label.setStringValue_(text)
    _status_label.setHidden_(not bool(text))


def hide_status():
    """Hide the status indicator."""
    show_status('')


def set_busy(busy):
    """Called by ai_chat when worker starts/stops. Updates send button appearance."""
    global _busy, _cancel_requested
    _busy = busy
    if not busy:
        _cancel_requested = False
    # Update button on main thread
    updater = _BusyUpdater.alloc().init()
    _BusyUpdater._busy = busy
    updater.performSelectorOnMainThread_withObject_waitUntilDone_(
        'doUpdate:', None, False)


def is_cancel_requested():
    """Check if user clicked stop."""
    return _cancel_requested


class _BusyUpdater(AppKit.NSObject):
    """Dispatches send button appearance changes to the main thread."""
    _busy = False

    def doUpdate_(self, _ignored):
        if _send_button is None:
            return
        _ensure_colors()
        if _BusyUpdater._busy:
            _send_button.setTitle_("\u25A0")  # black square (stop)
            _send_button.setContentTintColor_(
                AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                    0.88, 0.32, 0.32, 1.0))  # red tint
        else:
            _send_button.setTitle_("\u2191")  # up arrow (send)
            _send_button.setContentTintColor_(_COLOR_ACCENT)


def update_on_main_thread(role, content, results, status=None):
    """Thread-safe wrapper: dispatches UI updates to the main thread.

    If *status* is provided (and role is None), just updates the status label.
    """
    if status is not None and role is None:
        show_status(status)
        return
    info = {
        'role': role,
        'content': content,
        'results': results,
    }
    updater = _Updater.alloc().init()
    updater.performSelectorOnMainThread_withObject_waitUntilDone_(
        'doUpdate:', info, False)


def clear_messages():
    """Clear all messages from the chat view."""
    global _message_views, _streaming_view, _streaming_label, _streaming_active
    global _question_targets
    if _message_container is None:
        return
    for v in _message_views:
        v.removeFromSuperview()
    _message_views = []
    _streaming_view = None
    _streaming_label = None
    _streaming_active = False
    _question_targets = []
    # Reset container height
    if _scroll_view is not None:
        visible_height = _scroll_view.contentView().bounds().size.height
        container_width = _scroll_view.contentView().bounds().size.width
        _message_container.setFrameSize_(
            AppKit.NSMakeSize(container_width, visible_height))


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _update_container_height():
    """Recalculate and set the message container height to fit all messages."""
    if _scroll_view is None or _message_container is None:
        return
    container_width = _scroll_view.contentView().bounds().size.width
    total_height = 8.0
    if _message_views:
        last = _message_views[-1]
        total_height = last.frame().origin.y + last.frame().size.height + 8.0
    visible_height = _scroll_view.contentView().bounds().size.height
    new_height = max(total_height, visible_height)
    _message_container.setFrameSize_(AppKit.NSMakeSize(container_width, new_height))


def _scroll_to_bottom():
    """Scroll the message area to the very bottom."""
    if _scroll_view is None or _message_container is None:
        return
    container_height = _message_container.frame().size.height
    visible_height = _scroll_view.contentView().bounds().size.height
    if container_height > visible_height:
        point = AppKit.NSMakePoint(0, container_height - visible_height)
        _scroll_view.contentView().scrollToPoint_(point)
        _scroll_view.reflectScrolledClipView_(_scroll_view.contentView())


def _create_message_bubble(role, text, container_width):
    """Create an NSView representing a single chat message bubble.

    Returns an NSView positioned with x-origin set for alignment
    (right for user, left for others). The caller sets the y-origin.
    """
    margin = 12.0
    bubble_padding = 8.0
    max_text_width = container_width - 2 * margin - 2 * bubble_padding
    # For non-bubble messages, allow more width
    max_text_width_nobubble = container_width - 2 * margin

    if role == 'user':
        return _create_user_bubble(text, container_width, margin,
                                   bubble_padding, max_text_width)
    elif role == 'assistant':
        return _create_assistant_view(text, container_width, margin,
                                      max_text_width_nobubble)
    elif role == 'error':
        return _create_error_view(text, container_width, margin,
                                  max_text_width_nobubble)
    elif role == 'result':
        return _create_result_view(text, container_width, margin,
                                   max_text_width_nobubble)
    else:
        return _create_assistant_view(text, container_width, margin,
                                      max_text_width_nobubble)


def _measure_text(text, font, max_width):
    """Measure the size needed to render text with word wrapping."""
    attrs = {
        AppKit.NSFontAttributeName: font,
    }
    astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        text, attrs)
    # Use boundingRectWithSize to calculate wrapped text size
    rect = astr.boundingRectWithSize_options_(
        AppKit.NSMakeSize(max_width, 10000.0),
        AppKit.NSStringDrawingUsesLineFragmentOrigin
        | AppKit.NSStringDrawingUsesFontLeading)
    return rect.size.width, rect.size.height


def _create_text_label(text, font, text_color, max_width, alignment=None):
    """Create a non-editable, wrapping NSTextField for message text."""
    # Measure the text height at the given width
    tw, th = _measure_text(text, font, max_width)
    # Use measured width (capped) and height (with a small buffer)
    w = min(tw + 4, max_width)
    h = th + 4

    label = AppKit.NSTextField.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, max_width, h))
    label.setStringValue_(text)
    label.setFont_(font)
    label.setTextColor_(text_color)
    label.setBezeled_(False)
    label.setDrawsBackground_(False)
    label.setEditable_(False)
    label.setSelectable_(True)
    label.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    label.cell().setWraps_(True)

    if alignment is not None:
        label.setAlignment_(alignment)

    # Force the frame to the measured size
    label.setFrameSize_(AppKit.NSMakeSize(max_width, h))

    return label


def _create_user_bubble(text, container_width, margin, padding, max_text_width):
    """User message: right-aligned blue bubble with white text, tightly wrapped."""
    font = AppKit.NSFont.systemFontOfSize_(13.0)

    # Measure actual text size to wrap bubble tightly
    tw, th = _measure_text(text, font, max_text_width)
    # Tight bubble width: measured text + padding on each side, capped
    tight_width = min(tw + 8, max_text_width)  # small extra for rounding

    label = _create_text_label(text, font, _COLOR_USER_TEXT, tight_width)

    label_size = label.frame().size
    bubble_w = tight_width + 2 * padding
    bubble_h = label_size.height + 2 * padding

    # Right-align the bubble
    bubble_x = container_width - margin - bubble_w

    # Outer view (the bubble)
    bubble = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(bubble_x, 0, bubble_w, bubble_h))
    bubble.setWantsLayer_(True)
    bubble.layer().setBackgroundColor_(
        _COLOR_USER_BUBBLE.CGColor())
    bubble.layer().setCornerRadius_(10.0)

    # Position label inside bubble
    label.setFrameOrigin_(AppKit.NSMakePoint(padding, padding))
    bubble.addSubview_(label)

    return bubble


def _markdown_to_attributed_string(text, font, text_color, max_width):
    """Convert basic markdown to an NSMutableAttributedString.

    Supported syntax:
    - **bold** -> bold font
    - *italic* -> italic font
    - ## Header -> larger bold font
    - - item / bullet -> bullet character + indented text
    - 1. item -> numbered list preserved
    - Newlines preserved
    """
    import re

    font_mgr = AppKit.NSFontManager.sharedFontManager()
    font_size = font.pointSize()
    bold_font = AppKit.NSFont.boldSystemFontOfSize_(font_size)
    italic_font = font_mgr.convertFont_toHaveTrait_(font, AppKit.NSItalicFontMask)
    if italic_font is None:
        italic_font = font
    bold_italic_font = font_mgr.convertFont_toHaveTrait_(
        bold_font, AppKit.NSItalicFontMask)
    if bold_italic_font is None:
        bold_italic_font = bold_font
    header_font = AppKit.NSFont.boldSystemFontOfSize_(font_size + 3)

    result = AppKit.NSMutableAttributedString.alloc().init()

    # Default paragraph style
    default_para = AppKit.NSMutableParagraphStyle.alloc().init()
    default_para.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)

    # Indented paragraph style for list items
    list_para = AppKit.NSMutableParagraphStyle.alloc().init()
    list_para.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
    list_para.setHeadIndent_(16.0)
    list_para.setFirstLineHeadIndent_(0.0)

    lines = text.split('\n')
    for i, line in enumerate(lines):
        if i > 0:
            newline = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                '\n', {AppKit.NSFontAttributeName: font,
                       AppKit.NSForegroundColorAttributeName: text_color})
            result.appendAttributedString_(newline)

        # Check for headers (## Header)
        header_match = re.match(r'^(#{1,3})\s+(.+)$', line)
        if header_match:
            header_text = header_match.group(2)
            header_astr = _parse_inline_markdown(
                header_text, header_font, bold_font, italic_font,
                bold_italic_font, text_color, default_para)
            result.appendAttributedString_(header_astr)
            continue

        # Check for bullet list (- item or * item or bullet)
        bullet_match = re.match(r'^(\s*)[-*\u2022]\s+(.+)$', line)
        if bullet_match:
            indent = bullet_match.group(1)
            item_text = bullet_match.group(2)
            bullet_str = '\u2022 '
            bullet_astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                bullet_str,
                {AppKit.NSFontAttributeName: font,
                 AppKit.NSForegroundColorAttributeName: text_color,
                 AppKit.NSParagraphStyleAttributeName: list_para})
            result.appendAttributedString_(bullet_astr)
            item_astr = _parse_inline_markdown(
                item_text, font, bold_font, italic_font,
                bold_italic_font, text_color, list_para)
            result.appendAttributedString_(item_astr)
            continue

        # Check for numbered list (1. item)
        num_match = re.match(r'^(\s*)(\d+)\.\s+(.+)$', line)
        if num_match:
            num = num_match.group(2)
            item_text = num_match.group(3)
            num_str = '%s. ' % num
            num_astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                num_str,
                {AppKit.NSFontAttributeName: font,
                 AppKit.NSForegroundColorAttributeName: text_color,
                 AppKit.NSParagraphStyleAttributeName: list_para})
            result.appendAttributedString_(num_astr)
            item_astr = _parse_inline_markdown(
                item_text, font, bold_font, italic_font,
                bold_italic_font, text_color, list_para)
            result.appendAttributedString_(item_astr)
            continue

        # Regular line: parse inline markdown
        line_astr = _parse_inline_markdown(
            line, font, bold_font, italic_font,
            bold_italic_font, text_color, default_para)
        result.appendAttributedString_(line_astr)

    return result


def _parse_inline_markdown(text, font, bold_font, italic_font,
                           bold_italic_font, text_color, para_style):
    """Parse inline **bold** and *italic* markers in text.

    Returns an NSMutableAttributedString.
    """
    import re

    result = AppKit.NSMutableAttributedString.alloc().init()
    base_attrs = {
        AppKit.NSFontAttributeName: font,
        AppKit.NSForegroundColorAttributeName: text_color,
        AppKit.NSParagraphStyleAttributeName: para_style,
    }

    # Pattern matches **bold**, *italic*, or plain text segments
    # Process bold first (** **), then italic (* *)
    pattern = re.compile(r'(\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|\*(.+?)\*)')

    last_end = 0
    for m in pattern.finditer(text):
        # Add plain text before this match
        if m.start() > last_end:
            plain = text[last_end:m.start()]
            plain_astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                plain, base_attrs)
            result.appendAttributedString_(plain_astr)

        if m.group(2):  # ***bold italic***
            attrs = dict(base_attrs)
            attrs[AppKit.NSFontAttributeName] = bold_italic_font
            seg = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                m.group(2), attrs)
            result.appendAttributedString_(seg)
        elif m.group(3):  # **bold**
            attrs = dict(base_attrs)
            attrs[AppKit.NSFontAttributeName] = bold_font
            seg = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                m.group(3), attrs)
            result.appendAttributedString_(seg)
        elif m.group(4):  # *italic*
            attrs = dict(base_attrs)
            attrs[AppKit.NSFontAttributeName] = italic_font
            seg = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                m.group(4), attrs)
            result.appendAttributedString_(seg)

        last_end = m.end()

    # Add remaining plain text
    if last_end < len(text):
        plain = text[last_end:]
        plain_astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
            plain, base_attrs)
        result.appendAttributedString_(plain_astr)

    # If no matches at all, return the whole text as plain
    if result.length() == 0:
        plain_astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
            text, base_attrs)
        result.appendAttributedString_(plain_astr)

    return result


def _create_markdown_text_view(text, font, text_color, max_width):
    """Create an NSTextView displaying markdown-rendered attributed text."""
    attr_str = _markdown_to_attributed_string(text, font, text_color, max_width)

    # Create text view with initial frame, then resize to fit
    text_view = AppKit.NSTextView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, max_width, 10))
    text_view.textStorage().setAttributedString_(attr_str)
    text_view.setEditable_(False)
    text_view.setSelectable_(True)
    text_view.setDrawsBackground_(False)
    text_view.setTextContainerInset_(AppKit.NSMakeSize(0, 0))
    text_view.textContainer().setLineFragmentPadding_(0)
    text_view.textContainer().setWidthTracksTextView_(True)

    # Force layout and measure actual height
    text_view.layoutManager().ensureLayoutForTextContainer_(
        text_view.textContainer())
    used_rect = text_view.layoutManager().usedRectForTextContainer_(
        text_view.textContainer())
    height = used_rect.size.height + 4

    text_view.setFrameSize_(AppKit.NSMakeSize(max_width, height))
    return text_view


def _create_assistant_view(text, container_width, margin, max_text_width):
    """Assistant message: left-aligned text with markdown rendering, no bubble."""
    font = AppKit.NSFont.systemFontOfSize_(13.0)
    text_view = _create_markdown_text_view(
        text, font, _COLOR_ASSISTANT_TEXT, max_text_width)

    view_size = text_view.frame().size
    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin, 0, view_size.width, view_size.height))
    text_view.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(text_view)

    return wrapper


def _create_error_view(text, container_width, margin, max_text_width):
    """Error message: left-aligned red italic text with markdown rendering."""
    base_font = AppKit.NSFont.systemFontOfSize_(13.0)
    font_mgr = AppKit.NSFontManager.sharedFontManager()
    italic_font = font_mgr.convertFont_toHaveTrait_(
        base_font, AppKit.NSItalicFontMask)
    if italic_font is None:
        italic_font = base_font

    text_view = _create_markdown_text_view(
        text, italic_font, _COLOR_ERROR_TEXT, max_text_width)

    view_size = text_view.frame().size
    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin, 0, view_size.width, view_size.height))
    text_view.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(text_view)

    return wrapper


def _create_result_view(text, container_width, margin, max_text_width):
    """Result message: left-aligned gray text, smaller font, indented."""
    font = AppKit.NSFont.systemFontOfSize_(11.0)
    indent = 16.0
    effective_width = max_text_width - indent

    label = _create_text_label(text, font, _COLOR_RESULT_TEXT, effective_width)

    label_size = label.frame().size
    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin + indent, 0,
                          label_size.width, label_size.height))
    label.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(label)

    return wrapper


def _install_key_monitor():
    """Register a local key-event monitor for Cmd+L."""
    global _key_monitor

    def _key_handler(event):
        flags = event.modifierFlags()
        if (flags & AppKit.NSEventModifierFlagCommand
                and not (flags & AppKit.NSEventModifierFlagShift)
                and not (flags & AppKit.NSEventModifierFlagControl)
                and event.charactersIgnoringModifiers() == 'l'):
            Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.0, _TimerToggle.alloc().init(), 'fire:', None, False)
            return None
        return event

    _key_monitor = (
        AppKit.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            AppKit.NSEventMaskKeyDown, _key_handler))


_PANEL_WIDTH = 320
_original_glut_frame = None


def _get_glut_window():
    """Get the GLUT NSWindow."""
    for win in AppKit.NSApp.windows():
        if win is not _panel and win.title() == "PyMOL Viewer":
            return win
    return AppKit.NSApp.mainWindow()


def _position_panel_and_shift_glut(glut_win, opening):
    """Position panel to the left and shift the GLUT window right, or restore."""
    global _original_glut_frame
    if not _panel or not glut_win:
        return

    if opening:
        frame = glut_win.frame()
        _original_glut_frame = frame
        new_glut_frame = AppKit.NSMakeRect(
            frame.origin.x + _PANEL_WIDTH,
            frame.origin.y,
            frame.size.width,
            frame.size.height)
        glut_win.setFrame_display_animate_(new_glut_frame, True, True)
        panel_frame = AppKit.NSMakeRect(
            frame.origin.x,
            frame.origin.y,
            _PANEL_WIDTH,
            frame.size.height)
        _panel.setFrame_display_(panel_frame, True)
    else:
        if _original_glut_frame:
            glut_win.setFrame_display_animate_(_original_glut_frame, True, True)
            _original_glut_frame = None


# ---------------------------------------------------------------------------
# Panel construction
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# API key prompt & account modal
# ---------------------------------------------------------------------------

def prompt_for_credentials():
    """Show a dialog letting the user choose provider and enter credentials."""
    # Delay to allow the main window to fully render before showing a modal
    Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        1.0, _CredentialPromptHelper.alloc().init(), 'fire:', None, False)


def prompt_for_api_key():
    """Show a dialog asking for the Anthropic API key."""
    Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.1, _ApiKeyPromptHelper.alloc().init(), 'fire:', None, False)


def prompt_for_vertex_config():
    """Show a dialog to configure Vertex AI."""
    Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.1, _VertexConfigHelper.alloc().init(), 'fire:', None, False)


def show_account_modal():
    """Show a modal with the current login status and a logout button."""
    Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.0, _AccountModalHelper.alloc().init(), 'fire:', None, False)


class _CredentialPromptHelper(AppKit.NSObject):
    """Provider selection dialog shown on first launch."""

    def fire_(self, timer):
        alert = AppKit.NSAlert.alloc().init()
        alert.setMessageText_("Configure AI Provider")
        alert.setInformativeText_(
            "Choose how to connect to Claude:")
        alert.addButtonWithTitle_("Anthropic API Key")
        alert.addButtonWithTitle_("Google Vertex AI")
        alert.addButtonWithTitle_("Cancel")
        alert.setAlertStyle_(AppKit.NSAlertStyleInformational)

        response = alert.runModal()
        if response == AppKit.NSAlertFirstButtonReturn:
            prompt_for_api_key()
        elif response == AppKit.NSAlertSecondButtonReturn:
            prompt_for_vertex_config()


class _ApiKeyPromptHelper(AppKit.NSObject):
    def fire_(self, timer):
        alert = AppKit.NSAlert.alloc().init()
        alert.setMessageText_("Anthropic API Key")
        alert.setInformativeText_(
            "Enter your Anthropic API key.\n"
            "It will be stored securely in your macOS Keychain.")
        alert.addButtonWithTitle_("Save")
        alert.addButtonWithTitle_("Cancel")
        alert.setAlertStyle_(AppKit.NSAlertStyleInformational)

        input_field = AppKit.NSSecureTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, 320, 24))
        input_field.setPlaceholderString_("sk-ant-...")
        alert.setAccessoryView_(input_field)
        alert.window().setInitialFirstResponder_(input_field)

        response = alert.runModal()
        if response == AppKit.NSAlertFirstButtonReturn:
            key = input_field.stringValue().strip()
            if key:
                from pymol import ai_chat
                ai_chat.set_api_key(key)
                show_message('assistant', 'API key saved. Using Anthropic API.')


class _VertexConfigHelper(AppKit.NSObject):
    """Vertex AI configuration dialog with SA JSON file picker."""

    def fire_(self, timer):
        from pymol import ai_chat

        # First, open file picker for SA JSON
        panel = AppKit.NSOpenPanel.openPanel()
        panel.setTitle_("Select Service Account JSON")
        panel.setMessage_("Choose your Google Cloud service account key file")
        panel.setAllowedFileTypes_(["json"])
        panel.setAllowsMultipleSelection_(False)
        panel.setCanChooseDirectories_(False)

        if panel.runModal() != AppKit.NSModalResponseOK:
            return

        sa_path = str(panel.URLs()[0].path())

        # Parse the SA JSON to get project_id
        try:
            from pymol.ai_vertex_auth import parse_sa_json
            sa_info = parse_sa_json(sa_path)
        except Exception:
            sa_info = {}

        project_id = sa_info.get('project_id', '')
        client_email = sa_info.get('client_email', '')

        # Show config dialog with pre-filled project ID
        alert = AppKit.NSAlert.alloc().init()
        alert.setMessageText_("Vertex AI Configuration")

        info_text = f"Service Account: {client_email}\n" if client_email else ""
        info_text += "Configure your Vertex AI settings below."
        alert.setInformativeText_(info_text)
        alert.addButtonWithTitle_("Save")
        alert.addButtonWithTitle_("Cancel")

        # Create accessory view with project ID and region fields
        accessory = AppKit.NSView.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, 320, 70))

        project_label = AppKit.NSTextField.labelWithString_("Project ID:")
        project_label.setFrame_(AppKit.NSMakeRect(0, 46, 80, 20))
        accessory.addSubview_(project_label)

        project_field = AppKit.NSTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(85, 44, 235, 24))
        project_field.setStringValue_(project_id)
        project_field.setPlaceholderString_("my-gcp-project")
        accessory.addSubview_(project_field)

        region_label = AppKit.NSTextField.labelWithString_("Region:")
        region_label.setFrame_(AppKit.NSMakeRect(0, 12, 80, 20))
        accessory.addSubview_(region_label)

        region_field = AppKit.NSTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(85, 10, 235, 24))
        region_field.setStringValue_(
            ai_chat._ai_config['vertex_ai'].get('region', 'us-east5'))
        region_field.setPlaceholderString_("us-east5")
        accessory.addSubview_(region_field)

        alert.setAccessoryView_(accessory)
        alert.window().setInitialFirstResponder_(project_field)

        response = alert.runModal()
        if response == AppKit.NSAlertFirstButtonReturn:
            pid = project_field.stringValue().strip()
            rgn = region_field.stringValue().strip() or 'us-east5'
            if pid:
                ai_chat.set_vertex_config(sa_path, pid, rgn)
                show_message('assistant',
                             f'Vertex AI configured.\n'
                             f'Project: {pid}\n'
                             f'Region: {rgn}')


class _AccountModalHelper(AppKit.NSObject):
    def fire_(self, timer):
        from pymol import ai_chat

        alert = AppKit.NSAlert.alloc().init()
        provider = ai_chat.get_provider()

        if ai_chat.is_logged_in():
            if provider == 'vertex_ai':
                vc = ai_chat._ai_config['vertex_ai']
                alert.setMessageText_("Account")
                alert.setInformativeText_(
                    f"Provider: Vertex AI\n"
                    f"Project: {vc.get('project_id', 'N/A')}\n"
                    f"Region: {vc.get('region', 'N/A')}\n"
                    f"Model: {ai_chat._ai_config['models'].get('vertex_ai', 'N/A')}")
            else:
                masked = ai_chat.get_masked_key()
                alert.setMessageText_("Account")
                alert.setInformativeText_(
                    f"Provider: Anthropic\n"
                    f"API Key: {masked}\n"
                    f"Model: {ai_chat._ai_config['models'].get('anthropic', 'N/A')}")

            alert.addButtonWithTitle_("Done")
            alert.addButtonWithTitle_("Switch Provider")
            alert.addButtonWithTitle_("Logout")

            response = alert.runModal()
            if response == AppKit.NSAlertSecondButtonReturn:
                # Switch provider — show selection dialog
                sel = AppKit.NSAlert.alloc().init()
                sel.setMessageText_("Select Provider")
                sel.setInformativeText_("Choose an AI provider:")
                sel.addButtonWithTitle_("Anthropic API Key")
                sel.addButtonWithTitle_("Vertex AI")
                sel.addButtonWithTitle_("Cancel")
                sel_response = sel.runModal()
                if sel_response == AppKit.NSAlertFirstButtonReturn:
                    prompt_for_api_key()
                elif sel_response == AppKit.NSAlertSecondButtonReturn:
                    prompt_for_vertex_config()
            elif response == AppKit.NSAlertThirdButtonReturn:
                ai_chat.logout()
        else:
            alert.setMessageText_("Not Logged In")
            alert.setInformativeText_("No credentials are configured.")
            alert.addButtonWithTitle_("Anthropic API Key")
            alert.addButtonWithTitle_("Vertex AI")
            alert.addButtonWithTitle_("Cancel")

            response = alert.runModal()
            if response == AppKit.NSAlertFirstButtonReturn:
                prompt_for_api_key()
            elif response == AppKit.NSAlertSecondButtonReturn:
                prompt_for_vertex_config()


class _AccountButtonTarget(AppKit.NSObject):
    """Target for the user icon button in the header."""

    def showAccount_(self, sender):
        show_account_modal()


# ---------------------------------------------------------------------------
# Build chat subviews
# ---------------------------------------------------------------------------

def _build_chat_subviews(parent_view):
    """Populate *parent_view* with the chat header, message area, input field."""
    global _message_container, _input_field, _status_label, _scroll_view, _delegate
    global _send_button

    _ensure_colors()

    parent_view.setAutoresizesSubviews_(True)
    if parent_view.respondsToSelector_('setWantsLayer:'):
        parent_view.setWantsLayer_(True)
        parent_view.layer().setBackgroundColor_(_COLOR_BG.CGColor())

    bounds = parent_view.bounds()
    cw = bounds.size.width
    ch = bounds.size.height

    # -- Header (36px) -------------------------------------------------------
    header_height = 36.0
    header_y = ch - header_height
    header = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, header_y, cw, header_height))
    header.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewMinYMargin)
    header.setWantsLayer_(True)
    # Slightly lighter than background for subtle separation
    header.layer().setBackgroundColor_(
        AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.18, 0.18, 0.20, 1.0).CGColor())

    title_label = AppKit.NSTextField.labelWithString_("AiMOL Chat")
    title_label.setFrame_(AppKit.NSMakeRect(12, 6, 200, 24))
    title_label.setFont_(AppKit.NSFont.boldSystemFontOfSize_(15.0))
    title_label.setTextColor_(AppKit.NSColor.whiteColor())
    title_label.setAutoresizingMask_(AppKit.NSViewMaxXMargin)
    header.addSubview_(title_label)

    # User account button (person icon, top-right)
    account_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 32, 6, 24, 24))
    account_btn.setTitle_("\U0001F464")  # bust silhouette
    account_btn.setBordered_(False)
    account_btn.setFont_(AppKit.NSFont.systemFontOfSize_(14.0))
    account_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    account_btn.setToolTip_("Account settings")
    _account_target = _AccountButtonTarget.alloc().init()
    account_btn.setTarget_(_account_target)
    account_btn.setAction_('showAccount:')
    _build_chat_subviews._account_target = _account_target
    header.addSubview_(account_btn)

    new_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 90, 6, 52, 24))
    new_btn.setTitle_("New")
    new_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
    new_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    _new_target = _NewButtonTarget.alloc().init()
    new_btn.setTarget_(_new_target)
    new_btn.setAction_('newConversation:')
    _build_chat_subviews._new_target = _new_target
    header.addSubview_(new_btn)
    parent_view.addSubview_(header)

    # -- Input area (50px) at the bottom -------------------------------------
    input_area_height = 50.0
    input_area = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, cw, input_area_height))
    input_area.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewMaxYMargin)
    input_area.setWantsLayer_(True)
    input_area.layer().setBackgroundColor_(
        AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.13, 0.13, 0.15, 1.0).CGColor())

    # Send button (right side)
    send_btn_size = 32.0
    send_btn_x = cw - 8 - send_btn_size
    send_btn_y = (input_area_height - send_btn_size) / 2.0
    send_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(send_btn_x, send_btn_y, send_btn_size, send_btn_size))
    send_btn.setTitle_("\u2191")  # up arrow
    send_btn.setBezelStyle_(AppKit.NSBezelStyleCircular)
    send_btn.setFont_(AppKit.NSFont.boldSystemFontOfSize_(16.0))
    send_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    _send_target = _SendButtonTarget.alloc().init()
    send_btn.setTarget_(_send_target)
    send_btn.setAction_('sendMessage:')
    _build_chat_subviews._send_target = _send_target
    _send_button = send_btn
    input_area.addSubview_(send_btn)

    # Text input field
    field_x = 8.0
    field_w = cw - 8 - send_btn_size - 16
    field_h = 28.0
    field_y = (input_area_height - field_h) / 2.0
    _input_field = AppKit.NSTextField.alloc().initWithFrame_(
        AppKit.NSMakeRect(field_x, field_y, field_w, field_h))
    _input_field.setPlaceholderString_("Reply")
    _input_field.setFont_(AppKit.NSFont.systemFontOfSize_(13.0))
    _input_field.setTextColor_(_COLOR_INPUT_TEXT)
    _input_field.setDrawsBackground_(True)
    _input_field.setBackgroundColor_(_COLOR_INPUT_BG)
    _input_field.setBezeled_(True)
    _input_field.setBezelStyle_(AppKit.NSTextFieldRoundedBezel)
    _input_field.setFocusRingType_(AppKit.NSFocusRingTypeNone)
    _input_field.setAutoresizingMask_(AppKit.NSViewWidthSizable)

    _delegate = InputDelegate.alloc().init()
    _input_field.setDelegate_(_delegate)

    input_area.addSubview_(_input_field)
    parent_view.addSubview_(input_area)

    # -- Status label (20px) just above input --------------------------------
    status_y = input_area_height
    _status_label = AppKit.NSTextField.labelWithString_("")
    _status_label.setFrame_(AppKit.NSMakeRect(12, status_y + 2, cw - 24, 18))
    _status_label.setFont_(AppKit.NSFont.systemFontOfSize_(11.0))
    _status_label.setTextColor_(_COLOR_STATUS_TEXT)
    _status_label.setHidden_(True)
    _status_label.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    parent_view.addSubview_(_status_label)

    # -- Scroll view (fills the rest) ----------------------------------------
    scroll_y = input_area_height + 20  # above status label
    scroll_height = header_y - scroll_y
    _scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, scroll_y, cw, scroll_height))
    _scroll_view.setHasVerticalScroller_(True)
    _scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    _scroll_view.setDrawsBackground_(True)
    _scroll_view.setBackgroundColor_(_COLOR_BG)

    # Create a flipped container view as the document view
    _message_container = _FlippedView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, cw, scroll_height))
    _message_container.setAutoresizingMask_(AppKit.NSViewWidthSizable)

    _scroll_view.setDocumentView_(_message_container)
    parent_view.addSubview_(_scroll_view)


def _create_panel():
    """Build the NSPanel and all its subviews (GLUT mode only)."""
    global _panel

    panel_width = 320
    panel_height = 600

    style = (AppKit.NSWindowStyleMaskTitled
             | AppKit.NSWindowStyleMaskClosable
             | AppKit.NSWindowStyleMaskResizable
             | AppKit.NSWindowStyleMaskNonactivatingPanel)

    _panel = AppKit.NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
        AppKit.NSMakeRect(100, 100, panel_width, panel_height),
        style,
        AppKit.NSBackingStoreBuffered,
        False,
    )
    _panel.setTitle_("AI Chat")
    _panel.setFloatingPanel_(True)
    _panel.setBecomesKeyOnlyIfNeeded_(True)
    _panel.setReleasedWhenClosed_(False)

    _build_chat_subviews(_panel.contentView())


# ---------------------------------------------------------------------------
# ObjC helper classes
# ---------------------------------------------------------------------------

class InputDelegate(AppKit.NSObject):
    """Delegate for the input text field -- fires on Enter."""

    def controlTextDidEndEditing_(self, notification):
        movement = notification.userInfo().get('NSTextMovement', 0)
        if movement == AppKit.NSReturnTextMovement:
            field = notification.object()
            text = field.stringValue().strip()
            if text:
                field.setStringValue_('')
                _DeferredMessage._pending_text = text
                Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                    0.0, _DeferredMessage.alloc().init(), 'fire:', None, False)


class _NewButtonTarget(AppKit.NSObject):
    """Target for the 'New' button."""

    def newConversation_(self, sender):
        from pymol import ai_chat
        ai_chat.clear_conversation()


class _SendButtonTarget(AppKit.NSObject):
    """Target for the 'Send' button. Doubles as stop button when busy."""

    def sendMessage_(self, sender):
        global _cancel_requested
        if _busy:
            _cancel_requested = True
            return
        if _input_field is None:
            return
        text = _input_field.stringValue().strip()
        if text:
            _input_field.setStringValue_('')
            _DeferredMessage._pending_text = text
            Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.0, _DeferredMessage.alloc().init(), 'fire:', None, False)


class _DeferredMessage(AppKit.NSObject):
    """Fires _on_user_message from a timer to avoid blocking the text field."""
    _pending_text = ''

    def fire_(self, timer):
        text = _DeferredMessage._pending_text
        if text:
            _DeferredMessage._pending_text = ''
            from pymol import ai_chat
            ai_chat._on_user_message(text)


class _TimerToggle(AppKit.NSObject):
    """Fires toggle from a timer to avoid GLUT seeing the keystroke."""

    def fire_(self, timer):
        from pymol import ai_chat
        ai_chat._toggle_panel()


class _Updater(AppKit.NSObject):
    """Helper for dispatching UI updates from worker threads."""

    def doUpdate_(self, info):
        role = info['role']
        content = info['content']
        results = info['results']
        if role == 'error':
            show_message('error', content)
        else:
            show_message(role, content)
            for r in results:
                show_message('result', r)
        hide_status()


class _StatusUpdater(AppKit.NSObject):
    """Helper for dispatching status updates from worker threads."""
    _text = ''

    def doStatus_(self, ignored):
        show_status(_StatusUpdater._text)
        hide_status()
