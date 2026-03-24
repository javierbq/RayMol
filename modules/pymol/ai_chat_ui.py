"""Native macOS chat panel UI for PyMOL using PyObjC.

Modern chat-bubble interface with right-aligned user messages (blue bubbles)
and left-aligned assistant messages (green text on dark background).

In AppKit mode, the chat UI is embedded as a subview of the main window.
In legacy GLUT mode, it creates a floating NSPanel alongside the GLUT window.
Imported by pymol.ai_chat; raises ImportError on non-macOS platforms.
"""

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


def _ensure_colors():
    """Create cached NSColor instances (must be called on main thread)."""
    global _COLOR_BG, _COLOR_USER_BUBBLE, _COLOR_USER_TEXT
    global _COLOR_ASSISTANT_TEXT, _COLOR_ERROR_TEXT, _COLOR_RESULT_TEXT
    global _COLOR_INPUT_BG, _COLOR_INPUT_TEXT, _COLOR_STATUS_TEXT, _COLOR_ACCENT

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

    # Update container height to fit all messages
    total_height = y_offset + bubble_view.frame().size.height + 8.0
    container_frame = _message_container.frame()
    visible_height = _scroll_view.contentView().bounds().size.height
    new_height = max(total_height, visible_height)
    _message_container.setFrameSize_(AppKit.NSMakeSize(container_width, new_height))

    # Auto-scroll to bottom
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


def update_on_main_thread(role, content, results):
    """Thread-safe wrapper: dispatches UI updates to the main thread."""
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
    global _message_views
    if _message_container is None:
        return
    for v in _message_views:
        v.removeFromSuperview()
    _message_views = []
    # Reset container height
    if _scroll_view is not None:
        visible_height = _scroll_view.contentView().bounds().size.height
        container_width = _scroll_view.contentView().bounds().size.width
        _message_container.setFrameSize_(
            AppKit.NSMakeSize(container_width, visible_height))


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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
    """User message: right-aligned blue bubble with white text."""
    font = AppKit.NSFont.systemFontOfSize_(13.0)
    label = _create_text_label(text, font, _COLOR_USER_TEXT, max_text_width)

    label_size = label.frame().size
    bubble_w = label_size.width + 2 * padding
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


def _create_assistant_view(text, container_width, margin, max_text_width):
    """Assistant message: left-aligned green text, no bubble."""
    font = AppKit.NSFont.systemFontOfSize_(13.0)
    label = _create_text_label(text, font, _COLOR_ASSISTANT_TEXT, max_text_width)

    label_size = label.frame().size
    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin, 0, label_size.width, label_size.height))
    label.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(label)

    return wrapper


def _create_error_view(text, container_width, margin, max_text_width):
    """Error message: left-aligned red italic text."""
    base_font = AppKit.NSFont.systemFontOfSize_(13.0)
    font_mgr = AppKit.NSFontManager.sharedFontManager()
    italic_font = font_mgr.convertFont_toHaveTrait_(
        base_font, AppKit.NSItalicFontMask)
    if italic_font is None:
        italic_font = base_font

    label = _create_text_label(text, italic_font, _COLOR_ERROR_TEXT,
                               max_text_width)

    label_size = label.frame().size
    wrapper = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(margin, 0, label_size.width, label_size.height))
    label.setFrameOrigin_(AppKit.NSMakePoint(0, 0))
    wrapper.addSubview_(label)

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

def _build_chat_subviews(parent_view):
    """Populate *parent_view* with the chat header, message area, input field."""
    global _message_container, _input_field, _status_label, _scroll_view, _delegate

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

    title_label = AppKit.NSTextField.labelWithString_("AI Chat")
    title_label.setFrame_(AppKit.NSMakeRect(12, 6, 200, 24))
    title_label.setFont_(AppKit.NSFont.boldSystemFontOfSize_(15.0))
    title_label.setTextColor_(AppKit.NSColor.whiteColor())
    title_label.setAutoresizingMask_(AppKit.NSViewMaxXMargin)
    header.addSubview_(title_label)

    new_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 60, 6, 52, 24))
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
    """Target for the 'Send' button."""

    def sendMessage_(self, sender):
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
