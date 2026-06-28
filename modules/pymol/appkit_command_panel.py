"""Native macOS command panel for PyMOL using PyObjC.

Provides a log/feedback area, command input field, and button panel
that sits below the OpenGL viewport in the AppKit host.

Called from main_appkit.mm after the window is created.
"""

import objc
import AppKit
import Foundation

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_cmd = None
_log_text_view = None
_log_scroll_view = None
_input_field = None
_feedback_timer = None
_command_history = []
_history_index = -1
_delegate = None
_button_panel_view = None
_log_container = None
_retained = []  # prevent GC of ObjC objects

# Max lines in log before truncation
_MAX_LINES = 10000
_TRUNCATE_TO = 5000

# ---------------------------------------------------------------------------
# Theme colors (dark, matching chat panel)
# ---------------------------------------------------------------------------

_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.15, 0.15, 0.17, 1.0)
_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.8, 0.8, 0.8, 1.0)
_INPUT_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.12, 0.12, 0.14, 1.0)
_PROMPT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.4, 0.7, 1.0, 1.0)
_BUTTON_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.22, 0.22, 0.25, 1.0)
_BUTTON_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.85, 0.85, 0.85, 1.0)
_SEPARATOR_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.3, 0.3, 0.33, 1.0)


# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

def _do(cmd_str):
    """Execute a PyMOL command string."""
    try:
        _cmd.do(cmd_str)
    except Exception as e:
        _append_log(f"Error: {e}\n")


def _get_view_to_clipboard():
    """Copy cmd.get_view() output to clipboard."""
    try:
        v = _cmd.get_view()
        text = "cmd.set_view([\\\n"
        for i in range(0, 18, 3):
            text += f"    {v[i]:14.9f}, {v[i+1]:14.9f}, {v[i+2]:14.9f},\\\n"
        text += "])\n"
        pb = AppKit.NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.setString_forType_(text, AppKit.NSPasteboardTypeString)
        _append_log("View copied to clipboard.\n")
    except Exception as e:
        _append_log(f"Error getting view: {e}\n")


# ---------------------------------------------------------------------------
# Log area helpers
# ---------------------------------------------------------------------------

def _append_log(text):
    """Append text to the log text view and auto-scroll."""
    if _log_text_view is None:
        return

    storage = _log_text_view.textStorage()
    attrs = {
        AppKit.NSFontAttributeName:
            AppKit.NSFont.userFixedPitchFontOfSize_(11),
        AppKit.NSForegroundColorAttributeName: _TEXT_COLOR,
    }
    astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        text, attrs)
    storage.beginEditing()
    storage.appendAttributedString_(astr)
    storage.endEditing()

    # Truncate if too many lines
    full_text = storage.string()
    lines = full_text.split("\n")
    if len(lines) > _MAX_LINES:
        remove_count = len(lines) - _TRUNCATE_TO
        # Compute the cut point in NSString (UTF-16) units, NOT Python code-point
        # lengths: a non-BMP char (emoji) is 1 in Python len() but 2 UTF-16 units,
        # so summing len(line) would under-count and deleteCharactersInRange_ would
        # cut mid-character and garble the log. Walk the NSString's own newlines.
        ns = storage.string()
        total = ns.length()
        keep_from = 0
        found = 0
        while found < remove_count:
            r = ns.rangeOfString_options_range_("\n", 0, (keep_from, total - keep_from))
            if r.length == 0:  # no more newlines
                break
            keep_from = r.location + 1
            found += 1
        if keep_from > 0:
            storage.beginEditing()
            storage.deleteCharactersInRange_((0, keep_from))
            storage.endEditing()

    # Auto-scroll to bottom
    _log_text_view.scrollRangeToVisible_((storage.length(), 0))


def _poll_feedback_(timer):
    """NSTimer callback: poll PyMOL feedback and append to log."""
    if _cmd is None or _log_text_view is None:
        return
    try:
        fb = _cmd._get_feedback()
        if fb:
            for line in fb:
                if line:
                    _append_log(line + "\n")
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Input field delegate
# ---------------------------------------------------------------------------

class CommandInputDelegate(AppKit.NSObject):
    """Handles Enter, Up/Down arrow, and Tab in the command input field."""

    def control_textView_doCommandBySelector_(self, control, textView, sel):
        global _history_index

        sel_name = objc.selectorToKeyword(sel) if hasattr(objc, 'selectorToKeyword') else str(sel)

        if sel == b'insertNewline:' or sel_name == 'insertNewline:':
            # Execute command
            text = control.stringValue().strip()
            if text:
                _command_history.append(text)
                _history_index = len(_command_history)
                _append_log(f"PyMOL>{text}\n")
                _do(text)
            control.setStringValue_("")
            return True

        if sel == b'moveUp:' or sel_name == 'moveUp:':
            # Previous command in history
            if _command_history and _history_index > 0:
                _history_index -= 1
                control.setStringValue_(_command_history[_history_index])
                # Move cursor to end
                editor = control.currentEditor()
                if editor:
                    editor.moveToEndOfDocument_(None)
            return True

        if sel == b'moveDown:' or sel_name == 'moveDown:':
            # Next command in history
            if _command_history:
                _history_index += 1
                if _history_index < len(_command_history):
                    control.setStringValue_(_command_history[_history_index])
                else:
                    _history_index = len(_command_history)
                    control.setStringValue_("")
                editor = control.currentEditor()
                if editor:
                    editor.moveToEndOfDocument_(None)
            return True

        if sel == b'insertTab:' or sel_name == 'insertTab:':
            # Tab completion. cmd has no .complete(); the parser does, and it
            # returns the COMPLETED STRING (or None), printing the options to the
            # feedback log itself when there are several. (The old _cmd.complete()
            # raised AttributeError that the bare except swallowed → Tab did nothing.)
            text = control.stringValue()
            if text:
                try:
                    completed = _cmd._parser.complete(text)
                    if completed and completed != text:
                        control.setStringValue_(completed)
                        editor = control.currentEditor()
                        if editor:
                            editor.moveToEndOfDocument_(None)
                except Exception:
                    pass
            return True

        return False


# ---------------------------------------------------------------------------
# Button action target
# ---------------------------------------------------------------------------

class CommandButtonTarget(AppKit.NSObject):
    """ObjC target for button actions."""

    _command = objc.ivar('_command')

    @objc.typedSelector(b'v@:@')
    def buttonClicked_(self, sender):
        cmd_str = getattr(self, '_pymol_command', None)
        if cmd_str == '__get_view__':
            _get_view_to_clipboard()
        elif cmd_str == '__toggle_log__':
            _toggle_log_visibility()
        elif cmd_str:
            _do(cmd_str)


def _toggle_log_visibility():
    """Toggle visibility of the log+input area."""
    if _log_container is None:
        return
    hidden = _log_container.isHidden()
    _log_container.setHidden_(not hidden)
    # Resize button panel to fill if log is hidden
    parent = _log_container.superview()
    if parent:
        _relayout(parent)


def _relayout(container):
    """Relayout the command panel contents."""
    bounds = container.bounds()
    w = bounds.size.width
    h = bounds.size.height
    btn_w = 220.0

    if _log_container and not _log_container.isHidden():
        log_w = w - btn_w - 1  # 1px for separator
        _log_container.setFrame_(((0, 0), (log_w, h)))
        if _button_panel_view:
            _button_panel_view.setFrame_(((log_w + 1, 0), (btn_w, h)))
    else:
        if _button_panel_view:
            _button_panel_view.setFrame_(((0, 0), (w, h)))


# ---------------------------------------------------------------------------
# Build UI
# ---------------------------------------------------------------------------

def _make_button(title, command, frame):
    """Create a styled button with the given title and command."""
    btn = AppKit.NSButton.alloc().initWithFrame_(frame)
    btn.setTitle_(title)
    btn.setBezelStyle_(AppKit.NSBezelStyleSmallSquare)
    btn.setFont_(AppKit.NSFont.systemFontOfSize_(10))
    btn.setBordered_(True)
    btn.setWantsLayer_(True)
    btn.layer().setBackgroundColor_(_BUTTON_BG_COLOR.CGColor())
    btn.layer().setCornerRadius_(3.0)

    # Use attributed title for text color
    attrs = {
        AppKit.NSFontAttributeName: AppKit.NSFont.systemFontOfSize_(10),
        AppKit.NSForegroundColorAttributeName: _BUTTON_TEXT_COLOR,
    }
    astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        title, attrs)
    btn.setAttributedTitle_(astr)

    target = CommandButtonTarget.alloc().init()
    target._pymol_command = command
    _retained.append(target)
    btn.setTarget_(target)
    btn.setAction_(b'buttonClicked:')

    return btn


def _make_draw_ray_popup(frame):
    """Create a popup button with Draw/Ray options."""
    popup = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(frame, True)
    popup.setFont_(AppKit.NSFont.systemFontOfSize_(10))
    popup.setBezelStyle_(AppKit.NSBezelStyleSmallSquare)

    # First item is the title (shown when pullsDown=True)
    popup.addItemWithTitle_("Draw/Ray")
    popup.addItemWithTitle_("Draw")
    popup.addItemWithTitle_("Ray")
    popup.addItemWithTitle_("Ray (High Quality)")
    popup.addItemWithTitle_("Draw (Width x Height)")

    target = _DrawRayTarget.alloc().init()
    _retained.append(target)
    popup.setTarget_(target)
    popup.setAction_(b'menuSelected:')

    return popup


class _DrawRayTarget(AppKit.NSObject):
    """Target for the Draw/Ray popup button."""

    def menuSelected_(self, sender):
        idx = sender.indexOfSelectedItem()
        if idx == 1:    # Draw
            _do("draw")
        elif idx == 2:  # Ray
            _do("ray async=1")
        elif idx == 3:  # Ray (High Quality)
            _do("ray async=1, renderer=0")
        elif idx == 4:  # Draw (Width x Height)
            # Show a dialog for custom dimensions
            self._showDimensionDialog()

    def _showDimensionDialog(self):
        alert = AppKit.NSAlert.alloc().init()
        alert.setMessageText_("Draw/Ray with Custom Size")
        alert.setInformativeText_("Enter width and height in pixels:")
        alert.addButtonWithTitle_("Ray")
        alert.addButtonWithTitle_("Draw")
        alert.addButtonWithTitle_("Cancel")

        # Create accessory view with width/height fields
        container = AppKit.NSView.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, 200, 60))

        wLabel = AppKit.NSTextField.labelWithString_("Width:")
        wLabel.setFrame_(AppKit.NSMakeRect(0, 32, 50, 22))
        container.addSubview_(wLabel)

        wField = AppKit.NSTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(55, 32, 140, 22))
        wField.setStringValue_("1920")
        container.addSubview_(wField)

        hLabel = AppKit.NSTextField.labelWithString_("Height:")
        hLabel.setFrame_(AppKit.NSMakeRect(0, 4, 50, 22))
        container.addSubview_(hLabel)

        hField = AppKit.NSTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(55, 4, 140, 22))
        hField.setStringValue_("1080")
        container.addSubview_(hField)

        alert.setAccessoryView_(container)
        alert.window().setInitialFirstResponder_(wField)

        result = alert.runModal()
        w = wField.stringValue().strip()
        h = hField.stringValue().strip()
        if result == AppKit.NSAlertFirstButtonReturn:
            _do(f"ray {w}, {h}, async=1")
        elif result == AppKit.NSAlertSecondButtonReturn:
            _do(f"draw {w}, {h}")


def _build_button_panel(parent_view):
    """Build the button grid in the given view."""
    global _button_panel_view

    bounds = parent_view.bounds()
    _button_panel_view = parent_view

    parent_view.setWantsLayer_(True)
    parent_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())

    # Button definitions: rows of (title, command)
    # Matches the PyMOL internal GUI button layout
    rows = [
        [("Reset", "reset"), ("Zoom", "zoom animate=-1"),
         ("Orient", "orient animate=1"), ("Draw/Ray", "__draw_ray_popup__")],
        [("Unpick", "unpick"), ("Deselect", "deselect"),
         ("Rock", "rock"), ("Get View", "__get_view__")],
        [("|<", "rewind"), ("Stop", "mstop"),
         ("Play", "mplay"), (">|", "ending"), ("MClear", "mclear")],
        [("Builder", "wizard demo"), ("Properties", "set_key F1"),
         ("Rebuild", "rebuild")],
    ]

    btn_h = 26
    padding = 4
    top_padding = 8
    y = bounds.size.height - top_padding - btn_h

    for row in rows:
        # Filter out None entries
        active = [(t, c) for t, c in row if t is not None]
        if not active:
            y -= (btn_h + padding)
            continue

        n = len(active)
        total_pad = padding * (n + 1)
        btn_w = (bounds.size.width - total_pad) / n
        x = padding

        for title, command in active:
            frame = ((x, y), (btn_w, btn_h))
            if command == '__draw_ray_popup__':
                btn = _make_draw_ray_popup(frame)
            else:
                btn = _make_button(title, command, frame)
            btn.setAutoresizingMask_(AppKit.NSViewWidthSizable)
            parent_view.addSubview_(btn)
            x += btn_w + padding

        y -= (btn_h + padding)


def _build_log_area(parent_view):
    """Build the log text view and command input inside parent_view."""
    global _log_text_view, _log_scroll_view, _input_field, _delegate
    global _log_container

    _log_container = parent_view
    bounds = parent_view.bounds()
    w = bounds.size.width
    h = bounds.size.height

    parent_view.setWantsLayer_(True)
    parent_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())

    # Command input at the bottom (prompt label + text field)
    input_h = 28
    prompt_w = 55

    # Prompt label
    prompt_frame = ((4, 4), (prompt_w, input_h))
    prompt_label = AppKit.NSTextField.labelWithString_("PyMOL>")
    prompt_label.setFrame_(prompt_frame)
    prompt_label.setFont_(
        AppKit.NSFont.userFixedPitchFontOfSize_(12))
    prompt_label.setTextColor_(_PROMPT_COLOR)
    prompt_label.setBackgroundColor_(AppKit.NSColor.clearColor())
    prompt_label.setBezeled_(False)
    prompt_label.setEditable_(False)
    prompt_label.setSelectable_(False)
    prompt_label.setAutoresizingMask_(AppKit.NSViewMaxXMargin)
    parent_view.addSubview_(prompt_label)

    # Input text field
    input_frame = ((prompt_w + 4, 4), (w - prompt_w - 12, input_h))
    _input_field = AppKit.NSTextField.alloc().initWithFrame_(input_frame)
    _input_field.setFont_(
        AppKit.NSFont.userFixedPitchFontOfSize_(12))
    _input_field.setTextColor_(_TEXT_COLOR)
    _input_field.setBackgroundColor_(_INPUT_BG_COLOR)
    _input_field.setBezeled_(True)
    _input_field.setBezelStyle_(AppKit.NSTextFieldSquareBezel)
    _input_field.setFocusRingType_(AppKit.NSFocusRingTypeNone)
    _input_field.setPlaceholderString_("Enter command...")
    _input_field.setAutoresizingMask_(
        AppKit.NSViewWidthSizable)

    _delegate = CommandInputDelegate.alloc().init()
    _retained.append(_delegate)
    _input_field.setDelegate_(_delegate)
    parent_view.addSubview_(_input_field)

    # Separator line above input
    sep_frame = ((0, input_h + 8), (w, 1))
    sep = AppKit.NSView.alloc().initWithFrame_(sep_frame)
    sep.setWantsLayer_(True)
    sep.layer().setBackgroundColor_(_SEPARATOR_COLOR.CGColor())
    sep.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    parent_view.addSubview_(sep)

    # Log scroll view above the input
    log_y = input_h + 10
    log_h = h - log_y - 4
    scroll_frame = ((4, log_y), (w - 8, log_h))

    _log_scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(scroll_frame)
    _log_scroll_view.setHasVerticalScroller_(True)
    _log_scroll_view.setHasHorizontalScroller_(False)
    _log_scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    _log_scroll_view.setDrawsBackground_(True)
    _log_scroll_view.setBackgroundColor_(_BG_COLOR)
    _log_scroll_view.setBorderType_(AppKit.NSNoBorder)

    # Text view inside scroll view
    content_size = _log_scroll_view.contentSize()
    text_frame = ((0, 0), (content_size.width, content_size.height))
    _log_text_view = AppKit.NSTextView.alloc().initWithFrame_(text_frame)
    _log_text_view.setMinSize_((0, content_size.height))
    _log_text_view.setMaxSize_((1e7, 1e7))
    _log_text_view.setVerticallyResizable_(True)
    _log_text_view.setHorizontallyResizable_(False)
    _log_text_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    _log_text_view.textContainer().setContainerSize_(
        (content_size.width, 1e7))
    _log_text_view.textContainer().setWidthTracksTextView_(True)

    _log_text_view.setEditable_(False)
    _log_text_view.setSelectable_(True)
    _log_text_view.setRichText_(True)
    _log_text_view.setBackgroundColor_(_BG_COLOR)
    _log_text_view.setTextColor_(_TEXT_COLOR)
    _log_text_view.setFont_(
        AppKit.NSFont.userFixedPitchFontOfSize_(11))

    _log_scroll_view.setDocumentView_(_log_text_view)
    parent_view.addSubview_(_log_scroll_view)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup(container_view, cmd):
    """Build the command panel inside the given NSView.

    Called from main_appkit.mm after window creation.
    *container_view* is the NSView with identifier "commandPanel".
    *cmd* is the pymol.cmd module.
    """
    global _cmd, _feedback_timer

    _cmd = cmd

    bounds = container_view.bounds()
    w = bounds.size.width
    h = bounds.size.height

    container_view.setWantsLayer_(True)
    container_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())

    # Vertical separator at top of command panel
    top_sep = AppKit.NSView.alloc().initWithFrame_(((0, h - 1), (w, 1)))
    top_sep.setWantsLayer_(True)
    top_sep.layer().setBackgroundColor_(_SEPARATOR_COLOR.CGColor())
    top_sep.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewMinYMargin)
    container_view.addSubview_(top_sep)

    # Layout: log area (left) + button panel (right, 220px)
    btn_w = 220.0
    log_w = w - btn_w - 1  # 1px separator

    # Log area (left side)
    log_frame = ((0, 0), (log_w, h - 1))
    log_view = AppKit.NSView.alloc().initWithFrame_(log_frame)
    log_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    container_view.addSubview_(log_view)
    _build_log_area(log_view)

    # Vertical separator between log and buttons
    vsep_frame = ((log_w, 0), (1, h))
    vsep = AppKit.NSView.alloc().initWithFrame_(vsep_frame)
    vsep.setWantsLayer_(True)
    vsep.layer().setBackgroundColor_(_SEPARATOR_COLOR.CGColor())
    vsep.setAutoresizingMask_(
        AppKit.NSViewHeightSizable | AppKit.NSViewMinXMargin)
    container_view.addSubview_(vsep)

    # Button panel (right side)
    btn_frame = ((log_w + 1, 0), (btn_w, h - 1))
    btn_view = AppKit.NSView.alloc().initWithFrame_(btn_frame)
    btn_view.setAutoresizingMask_(
        AppKit.NSViewHeightSizable | AppKit.NSViewMinXMargin)
    container_view.addSubview_(btn_view)
    _build_button_panel(btn_view)

    # Start feedback polling timer (100ms)
    _feedback_timer = AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.1, _FeedbackTimerTarget.alloc().init(), b'pollFeedback:', None, True)
    # Ensure timer fires during event tracking
    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _feedback_timer, AppKit.NSEventTrackingRunLoopMode)


class _FeedbackTimerTarget(AppKit.NSObject):
    """ObjC target for the feedback polling NSTimer."""

    @objc.typedSelector(b'v@:@')
    def pollFeedback_(self, timer):
        _poll_feedback_(timer)


_retained.append(None)  # placeholder; actual instance added in setup()


def setup_buttons_only(container_view, cmd):
    """Build only the button panel (no log/input) in the given container."""
    global _cmd
    _cmd = cmd
    container_view.setWantsLayer_(True)
    container_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())
    _build_button_panel(container_view)


def setup_log_only(container_view, cmd):
    """Build only the log area + command input in the given container."""
    global _cmd, _feedback_timer
    _cmd = cmd
    container_view.setWantsLayer_(True)
    container_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())
    _build_log_area(container_view)

    # Start feedback polling timer
    _feedback_timer = AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.1, _FeedbackTimerTarget.alloc().init(), b'pollFeedback:', None, True)
    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _feedback_timer, AppKit.NSEventTrackingRunLoopMode)
