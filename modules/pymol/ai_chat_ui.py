"""Native macOS chat panel UI for PyMOL using PyObjC.

This module provides an NSPanel-based chat interface that overlays the left
side of the PyMOL GLUT window.  It is imported by pymol.ai_chat and will
raise ImportError on non-macOS platforms (ai_chat handles that gracefully).
"""

import AppKit
import Foundation
import objc

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_panel = None        # NSPanel instance (created lazily)
_visible = False     # current visibility
_text_view = None    # NSTextView for messages
_input_field = None  # NSTextField for user input
_status_label = None # NSTextField used as a status indicator
_scroll_view = None  # NSScrollView wrapping the text view
_delegate = None     # InputDelegate instance (prevent GC)
_key_monitor = None  # reference to the installed event monitor


# ---------------------------------------------------------------------------
# Public API called by ai_chat.py
# ---------------------------------------------------------------------------

def _init():
    """Install the Cmd+L key monitor. The panel itself is created lazily."""
    _install_key_monitor()


def toggle():
    """Show or hide the chat panel, creating it on first call."""
    global _panel, _visible

    if _panel is None:
        _create_panel()

    _visible = not _visible
    if _visible:
        glut_win = AppKit.NSApp.mainWindow()
        if glut_win:
            _position_panel()
            _panel.orderFront_(None)
            glut_win.addChildWindow_ordered_(_panel, AppKit.NSWindowAbove)
        else:
            _panel.orderFront_(None)
    else:
        glut_win = AppKit.NSApp.mainWindow()
        if glut_win and _panel:
            glut_win.removeChildWindow_(_panel)
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
        if (event.modifierFlags() & AppKit.NSEventModifierFlagCommand
                and event.charactersIgnoringModifiers() == 'l'):
            from pymol import ai_chat
            ai_chat._toggle_panel()
            return None  # swallow the event
        return event

    _key_monitor = (
        AppKit.NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            AppKit.NSEventMaskKeyDown, _key_handler))


def _position_panel():
    """Position the panel to overlay the left edge of the GLUT window."""
    glut_win = AppKit.NSApp.mainWindow()
    if not glut_win or not _panel:
        return
    frame = glut_win.frame()
    panel_width = 320
    panel_frame = AppKit.NSMakeRect(
        frame.origin.x,
        frame.origin.y,
        panel_width,
        frame.size.height)
    _panel.setFrame_display_(panel_frame, True)


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

def _create_panel():
    """Build the NSPanel and all its subviews."""
    global _panel, _text_view, _input_field, _status_label, _scroll_view
    global _delegate

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

    content = _panel.contentView()
    content.setAutoresizesSubviews_(True)
    cw = panel_width
    ch = panel_height

    # -- Header (30px) -------------------------------------------------------
    header_y = ch - 30
    header = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, header_y, cw, 30))
    header.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewMinYMargin)

    title_label = AppKit.NSTextField.labelWithString_("AI Chat")
    title_label.setFrame_(AppKit.NSMakeRect(8, 2, 200, 24))
    title_label.setFont_(AppKit.NSFont.boldSystemFontOfSize_(14.0))
    title_label.setAutoresizingMask_(AppKit.NSViewMaxXMargin)
    header.addSubview_(title_label)

    new_btn = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(cw - 60, 2, 52, 24))
    new_btn.setTitle_("New")
    new_btn.setBezelStyle_(AppKit.NSBezelStyleRounded)
    new_btn.setAutoresizingMask_(AppKit.NSViewMinXMargin)
    new_btn.setTarget_(_NewButtonTarget.alloc().init())
    new_btn.setAction_(objc.selector(
        _NewButtonTarget.newConversation_, signature=b'v@:@'))
    # prevent target from being GC'd
    new_btn.target().retain()
    header.addSubview_(new_btn)
    content.addSubview_(header)

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
    send_btn.setTarget_(_SendButtonTarget.alloc().init())
    send_btn.setAction_(objc.selector(
        _SendButtonTarget.sendMessage_, signature=b'v@:@'))
    send_btn.target().retain()

    content.addSubview_(_input_field)
    content.addSubview_(send_btn)

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
    content.addSubview_(_status_label)

    # -- Scroll view (fills the rest) ----------------------------------------
    scroll_y = input_height + 20  # above status label
    scroll_height = header_y - scroll_y
    _scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, scroll_y, cw, scroll_height))
    _scroll_view.setHasVerticalScroller_(True)
    _scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)

    text_frame = AppKit.NSMakeRect(0, 0, cw, scroll_height)
    _text_view = AppKit.NSTextView.alloc().initWithFrame_(text_frame)
    _text_view.setEditable_(False)
    _text_view.setRichText_(True)
    _text_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    _text_view.textContainer().setWidthTracksTextView_(True)
    _text_view.setTextContainerInset_(AppKit.NSMakeSize(4.0, 4.0))

    _scroll_view.setDocumentView_(_text_view)
    content.addSubview_(_scroll_view)


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
                from pymol import ai_chat
                ai_chat._on_user_message(text)


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
            from pymol import ai_chat
            ai_chat._on_user_message(text)


class _Updater(AppKit.NSObject):
    """Helper for dispatching UI updates from worker threads."""

    def doUpdate_(self, info):
        role = info['role']
        content = info['content']
        results = info['results']
        if role == 'error':
            show_message('error', content)
        else:
            show_message('assistant', content)
            for r in results:
                show_message('result', r)
        hide_status()
