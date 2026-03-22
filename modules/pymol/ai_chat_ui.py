"""Native macOS chat panel UI for PyMOL using PyObjC.

In AppKit mode, the chat UI is embedded as a subview of the main window.
In legacy GLUT mode, it creates a floating NSPanel alongside the GLUT window.
Imported by pymol.ai_chat; raises ImportError on non-macOS platforms.
"""

import AppKit
import Foundation

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_panel = None           # NSPanel instance (GLUT mode only, created lazily)
_visible = False        # current visibility
_text_view = None       # NSTextView for messages
_input_field = None     # NSTextField for user input
_status_label = None    # NSTextField used as a status indicator
_scroll_view = None     # NSScrollView wrapping the text view
_delegate = None        # InputDelegate instance (prevent GC)
_key_monitor = None     # global event monitor reference
_embedded = False       # True when running inside AppKit host
_container_view = None  # NSView provided by the AppKit host


# ---------------------------------------------------------------------------
# Public API called by ai_chat.py
# ---------------------------------------------------------------------------

def _init():
    """Install the Cmd+L key monitor (GLUT mode only).

    In embedded/AppKit mode, _setup_embedded() is called instead and
    Cmd+L is handled natively in the ObjC keyDown: handler.
    """
    if not _embedded:
        _install_key_monitor()


def _setup_embedded(container_view):
    """Set up the chat UI inside a container view provided by the AppKit host.

    This is called from main_appkit.mm after the window is created.
    The container is an NSView on the left side of the main window.
    """
    global _embedded, _container_view, _visible
    _embedded = True
    _container_view = container_view
    _visible = True
    _build_chat_subviews(container_view)


def toggle():
    """Show or hide the chat panel."""
    global _visible

    if _embedded:
        # In embedded mode, toggling is handled by the ObjC host
        # (toggleChatPanel in PyMOLAppDelegate). Nothing to do here.
        return

    # --- GLUT / NSPanel mode (backwards compatible) ---
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
    """Append a styled message to the chat view.

    *role* is one of 'user', 'assistant', 'result', or 'error'.
    """
    if _text_view is None:
        return

    storage = _text_view.textStorage()
    if storage.length() > 0:
        storage.appendAttributedString_(
            AppKit.NSAttributedString.alloc().initWithString_("\n"))

    attrs = _attrs_for_role(role)
    prefix = _prefix_for_role(role)
    line = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        prefix + text, attrs)
    storage.appendAttributedString_(line)

    # Auto-scroll to the bottom
    _text_view.scrollRangeToVisible_(
        Foundation.NSMakeRange(storage.length(), 0))


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
    if _text_view is None:
        return
    _text_view.textStorage().setAttributedString_(
        AppKit.NSAttributedString.alloc().initWithString_(""))


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _install_key_monitor():
    """Register a local key-event monitor for Cmd+L."""
    global _key_monitor

    def _key_handler(event):
        flags = event.modifierFlags()
        # Check Cmd is pressed (ignore if Shift/Ctrl/Alt also pressed)
        if (flags & AppKit.NSEventModifierFlagCommand
                and not (flags & AppKit.NSEventModifierFlagShift)
                and not (flags & AppKit.NSEventModifierFlagControl)
                and event.charactersIgnoringModifiers() == 'l'):
            # Use a timer to toggle after returning from the event handler,
            # which prevents the keystroke from reaching GLUT
            Foundation.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.0, _TimerToggle.alloc().init(), 'fire:', None, False)
            return None  # swallow the event
        return event

    _key_monitor = (
        AppKit.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            AppKit.NSEventMaskKeyDown, _key_handler))


_PANEL_WIDTH = 320
_original_glut_frame = None  # saved before shifting


def _get_glut_window():
    """Get the GLUT NSWindow."""
    # mainWindow() may return None if GLUT isn't focused; search all windows
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
        # Move GLUT window to the right to make room
        new_glut_frame = AppKit.NSMakeRect(
            frame.origin.x + _PANEL_WIDTH,
            frame.origin.y,
            frame.size.width,
            frame.size.height)
        glut_win.setFrame_display_animate_(new_glut_frame, True, True)
        # Place panel where the GLUT window used to be
        panel_frame = AppKit.NSMakeRect(
            frame.origin.x,
            frame.origin.y,
            _PANEL_WIDTH,
            frame.size.height)
        _panel.setFrame_display_(panel_frame, True)
    else:
        # Restore GLUT window to original position
        if _original_glut_frame:
            glut_win.setFrame_display_animate_(_original_glut_frame, True, True)
            _original_glut_frame = None


def _prefix_for_role(role):
    if role == 'user':
        return "You: "
    elif role == 'assistant':
        return "AI: "
    elif role == 'result':
        return "  > "
    elif role == 'error':
        return "Error: "
    return ""


def _attrs_for_role(role):
    """Return an NSDictionary of NSAttributedString attributes for *role*."""
    base_font = AppKit.NSFont.systemFontOfSize_(13.0)
    mono_font = AppKit.NSFont.userFixedPitchFontOfSize_(12.0) or base_font

    if role == 'user':
        return {
            AppKit.NSFontAttributeName: base_font,
            AppKit.NSForegroundColorAttributeName:
                AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                    0.29, 0.56, 0.85, 1.0),  # #4A90D9
        }
    elif role == 'assistant':
        return {
            AppKit.NSFontAttributeName: mono_font,
            AppKit.NSForegroundColorAttributeName:
                AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                    0.42, 0.75, 0.42, 1.0),  # #6BC06C
        }
    elif role == 'result':
        return {
            AppKit.NSFontAttributeName:
                AppKit.NSFont.systemFontOfSize_(11.0),
            AppKit.NSForegroundColorAttributeName:
                AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                    0.53, 0.53, 0.53, 1.0),  # #888888
        }
    elif role == 'error':
        return {
            AppKit.NSFontAttributeName: base_font,
            AppKit.NSForegroundColorAttributeName:
                AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                    0.88, 0.32, 0.32, 1.0),  # #E05252
        }
    return {AppKit.NSFontAttributeName: base_font}


# ---------------------------------------------------------------------------
# Panel construction
# ---------------------------------------------------------------------------

def _build_chat_subviews(parent_view):
    """Populate *parent_view* with the chat header, message area, input field.

    This is shared between the embedded AppKit mode and the GLUT NSPanel mode.
    """
    global _text_view, _input_field, _status_label, _scroll_view, _delegate

    parent_view.setAutoresizesSubviews_(True)
    bounds = parent_view.bounds()
    cw = bounds.size.width
    ch = bounds.size.height

    # -- Header (30px) -------------------------------------------------------
    header_y = ch - 30
    header = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, header_y, cw, 30))
    header.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewMinYMargin)

    title_label = AppKit.NSTextField.labelWithString_("AI Chat")
    title_label.setFrame_(AppKit.NSMakeRect(8, 2, 200, 24))
    title_label.setFont_(AppKit.NSFont.boldSystemFontOfSize_(14.0))
    title_label.setTextColor_(AppKit.NSColor.whiteColor())
    title_label.setAutoresizingMask_(AppKit.NSViewMaxXMargin)
    header.addSubview_(title_label)

    new_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 60, 2, 52, 24))
    new_btn.setTitle_("New")
    new_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
    new_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    _new_target = _NewButtonTarget.alloc().init()
    new_btn.setTarget_(_new_target)
    new_btn.setAction_('newConversation:')
    # prevent GC
    _build_chat_subviews._new_target = _new_target
    header.addSubview_(new_btn)
    parent_view.addSubview_(header)

    # -- Input area (40px) at the bottom -------------------------------------
    input_y = 0
    input_height = 40

    _input_field = AppKit.NSTextField.alloc().initWithFrame_(
        AppKit.NSMakeRect(8, input_y + 8, cw - 76, 24))
    _input_field.setPlaceholderString_("Ask PyMOL AI...")
    _input_field.setAutoresizingMask_(AppKit.NSViewWidthSizable)

    _delegate = InputDelegate.alloc().init()
    _input_field.setDelegate_(_delegate)

    send_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 64, input_y + 8, 56, 24))
    send_btn.setTitle_("Send")
    send_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
    send_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    _send_target = _SendButtonTarget.alloc().init()
    send_btn.setTarget_(_send_target)
    send_btn.setAction_('sendMessage:')
    _build_chat_subviews._send_target = _send_target

    parent_view.addSubview_(_input_field)
    parent_view.addSubview_(send_btn)

    # -- Status label (20px) just above input --------------------------------
    status_y = input_height
    _status_label = AppKit.NSTextField.labelWithString_("")
    _status_label.setFrame_(AppKit.NSMakeRect(8, status_y, cw - 16, 20))
    _status_label.setFont_(AppKit.NSFont.systemFontOfSize_(11.0))
    _status_label.setTextColor_(
        AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
            0.53, 0.53, 0.53, 1.0))
    _status_label.setHidden_(True)
    _status_label.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    parent_view.addSubview_(_status_label)

    # -- Scroll view (fills the rest) ----------------------------------------
    scroll_y = input_height + 20  # above status label
    scroll_height = header_y - scroll_y
    _scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, scroll_y, cw, scroll_height))
    _scroll_view.setHasVerticalScroller_(True)
    _scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    # Dark background for the scroll view in embedded mode
    if _embedded:
        _scroll_view.setBackgroundColor_(
            AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                0.15, 0.15, 0.17, 1.0))

    text_frame = AppKit.NSMakeRect(0, 0, cw, scroll_height)
    _text_view = AppKit.NSTextView.alloc().initWithFrame_(text_frame)
    _text_view.setEditable_(False)
    _text_view.setRichText_(True)
    _text_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    _text_view.textContainer().setWidthTracksTextView_(True)
    _text_view.setTextContainerInset_(AppKit.NSMakeSize(4.0, 4.0))
    # Dark background for the text view in embedded mode
    if _embedded:
        _text_view.setDrawsBackground_(True)
        _text_view.setBackgroundColor_(
            AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                0.15, 0.15, 0.17, 1.0))

    _scroll_view.setDocumentView_(_text_view)
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
                # Defer the message to avoid blocking the text field event cycle
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
