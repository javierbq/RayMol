"""Native macOS object/selection panel for PyMOL using PyObjC.

Displays loaded objects and selections with A/S/H/L/C action buttons,
replacing the GL-rendered internal GUI panel.

Called from main_appkit.mm after the window is created.
"""

import objc
import AppKit
import Foundation

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_cmd = None
_container = None
_scroll_view = None
_stack_view = None
_poll_timer = None
_prev_names = []  # previous list for change detection
_retained = []  # prevent GC of ObjC objects

# ---------------------------------------------------------------------------
# Theme colors (dark, matching other panels)
# ---------------------------------------------------------------------------

_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.15, 0.15, 0.17, 1.0)
_ROW_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.18, 0.18, 0.20, 1.0)
_ROW_ALT_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.16, 0.16, 0.18, 1.0)
_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.85, 0.85, 0.85, 1.0)
_SELECTION_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.5, 0.75, 1.0, 1.0)
_BUTTON_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.25, 0.25, 0.28, 1.0)
_BUTTON_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.85, 0.85, 0.85, 1.0)
_HEADER_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.6, 0.6, 0.6, 1.0)

# ---------------------------------------------------------------------------
# Representation and color lists
# ---------------------------------------------------------------------------

_REPRESENTATIONS = [
    'cartoon', 'sticks', 'spheres', 'surface', 'mesh',
    'lines', 'ribbon', 'dots', 'everything'
]

_LABEL_OPTIONS = [
    ('None', ''),
    ('Residues', 'resn+resi'),
    ('Chains', 'chain'),
    ('Atoms', 'name'),
]

_COLOR_OPTIONS = [
    ('By Element', 'cbag'),
    ('By Chain', 'cbc'),
    ('Spectrum', 'spectrum'),
    ('Green', 'green'),
    ('Cyan', 'cyan'),
    ('Yellow', 'yellow'),
    ('Red', 'red'),
    ('Blue', 'blue'),
    ('White', 'white'),
    ('Gray', 'gray'),
]

_ACTION_OPTIONS = [
    ('Zoom', 'zoom'),
    ('Orient', 'orient'),
    ('Center', 'center'),
    ('Delete', 'delete'),
]

# ---------------------------------------------------------------------------
# ObjC helper classes
# ---------------------------------------------------------------------------

class ObjPanel_FlippedView(AppKit.NSView):
    """An NSView subclass with flipped (top-left origin) coordinates."""
    def isFlipped(self):
        return True


class ObjPanel_ButtonTarget(AppKit.NSObject):
    """Target for popup button actions."""

    def initWithName_cmd_action_(self, name, cmd, action):
        self = objc.super(ObjPanel_ButtonTarget, self).init()
        if self is None:
            return None
        self._name = name
        self._cmd = cmd
        self._action = action
        return self

    @objc.typedSelector(b'v@:@')
    def popupAction_(self, sender):
        idx = sender.indexOfSelectedItem()
        if idx < 0:
            return
        title = str(sender.itemTitleAtIndex_(idx))
        name = self._name
        action = self._action

        try:
            if action == 'show':
                self._cmd.show(title.lower(), name)
            elif action == 'hide':
                self._cmd.hide(title.lower(), name)
            elif action == 'label':
                for label_name, expr in _LABEL_OPTIONS:
                    if label_name == title:
                        if expr:
                            self._cmd.label(name, expr)
                        else:
                            self._cmd.label(name, '')
                        break
            elif action == 'color':
                for color_name, color_val in _COLOR_OPTIONS:
                    if color_name == title:
                        if color_val == 'cbag':
                            self._cmd.util.cbag(name)
                        elif color_val == 'cbc':
                            self._cmd.util.cbc(name)
                        elif color_val == 'spectrum':
                            self._cmd.spectrum('count', selection=name)
                        else:
                            self._cmd.color(color_val, name)
                        break
            elif action == 'action':
                for act_name, act_cmd in _ACTION_OPTIONS:
                    if act_name == title:
                        if act_cmd == 'zoom':
                            self._cmd.zoom(name)
                        elif act_cmd == 'orient':
                            self._cmd.orient(name)
                        elif act_cmd == 'center':
                            self._cmd.center(name)
                        elif act_cmd == 'delete':
                            self._cmd.delete(name)
                        break
        except Exception as e:
            print(f"ObjPanel action error: {e}")


class ObjPanel_CheckboxTarget(AppKit.NSObject):
    """Target for visibility checkbox."""

    def initWithName_cmd_(self, name, cmd):
        self = objc.super(ObjPanel_CheckboxTarget, self).init()
        if self is None:
            return None
        self._name = name
        self._cmd = cmd
        return self

    @objc.typedSelector(b'v@:@')
    def toggle_(self, sender):
        try:
            if sender.state() == AppKit.NSControlStateValueOn:
                self._cmd.enable(self._name)
            else:
                self._cmd.disable(self._name)
        except Exception as e:
            print(f"ObjPanel checkbox error: {e}")


class ObjPanel_TimerTarget(AppKit.NSObject):
    """Target for the poll timer."""

    @objc.typedSelector(b'v@:@')
    def poll_(self, timer):
        _poll_objects()


# ---------------------------------------------------------------------------
# UI building
# ---------------------------------------------------------------------------

def _make_popup_button(title, items, target, action_sel):
    """Create a small popup button with the given items."""
    btn = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(
        AppKit.NSMakeRect(0, 0, 28, 20), True)
    btn.setBezelStyle_(AppKit.NSBezelStyleSmallSquare)
    btn.setBordered_(True)
    btn.setFont_(AppKit.NSFont.systemFontOfSize_(9))

    # Title item (shown when closed)
    btn.addItemWithTitle_(title)
    btn.itemAtIndex_(0).setAttributedTitle_(
        AppKit.NSAttributedString.alloc().initWithString_attributes_(
            title, {
                AppKit.NSFontAttributeName: AppKit.NSFont.boldSystemFontOfSize_(9),
                AppKit.NSForegroundColorAttributeName: _BUTTON_TEXT_COLOR,
            }))

    for item_title in items:
        btn.addItemWithTitle_(item_title)

    btn.setTarget_(target)
    btn.setAction_(action_sel)
    return btn


def _build_row(name, is_selection, enabled):
    """Build a single row NSView for an object or selection."""
    row_height = 24
    row = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, 220, row_height))
    row.setWantsLayer_(True)

    # Checkbox
    checkbox = AppKit.NSButton.alloc().initWithFrame_(
        AppKit.NSMakeRect(4, 2, 18, 20))
    checkbox.setButtonType_(AppKit.NSButtonTypeSwitch)
    checkbox.setTitle_('')
    checkbox.setState_(
        AppKit.NSControlStateValueOn if enabled else AppKit.NSControlStateValueOff)

    cb_target = ObjPanel_CheckboxTarget.alloc().initWithName_cmd_(name, _cmd)
    _retained.append(cb_target)
    checkbox.setTarget_(cb_target)
    checkbox.setAction_(objc.selector(cb_target.toggle_, signature=b'v@:@'))
    row.addSubview_(checkbox)

    # Name label
    display_name = name
    if is_selection:
        try:
            count = _cmd.count_atoms(name)
            display_name = f"{name} ({count})"
        except Exception:
            pass

    label = AppKit.NSTextField.labelWithString_(display_name)
    label.setFrame_(AppKit.NSMakeRect(24, 2, 80, 18))
    label.setFont_(AppKit.NSFont.systemFontOfSize_(11))
    label.setTextColor_(_SELECTION_TEXT_COLOR if is_selection else _TEXT_COLOR)
    label.setLineBreakMode_(AppKit.NSLineBreakByTruncatingTail)
    label.setDrawsBackground_(False)
    label.setBezeled_(False)
    label.setEditable_(False)
    label.setSelectable_(False)
    row.addSubview_(label)

    # A/S/H/L/C popup buttons
    button_defs = [
        ('A', [opt[0] for opt in _ACTION_OPTIONS], 'action'),
        ('S', [r.capitalize() for r in _REPRESENTATIONS], 'show'),
        ('H', [r.capitalize() for r in _REPRESENTATIONS], 'hide'),
        ('L', [opt[0] for opt in _LABEL_OPTIONS], 'label'),
        ('C', [opt[0] for opt in _COLOR_OPTIONS], 'color'),
    ]

    x_offset = 108
    btn_width = 22
    btn_spacing = 1

    for btn_title, items, action in button_defs:
        target = ObjPanel_ButtonTarget.alloc().initWithName_cmd_action_(
            name, _cmd, action)
        _retained.append(target)

        popup = _make_popup_button(
            btn_title, items, target,
            objc.selector(target.popupAction_, signature=b'v@:@'))
        popup.setFrame_(AppKit.NSMakeRect(x_offset, 2, btn_width, 20))
        row.addSubview_(popup)
        x_offset += btn_width + btn_spacing

    return row


def _rebuild_rows(objects, selections, enabled_set):
    """Rebuild all rows using manual top-down layout in the document view."""
    global _retained

    # Remove all subviews from the document view
    doc = _scroll_view.documentView()
    for sv in list(doc.subviews()):
        sv.removeFromSuperview()

    _retained = []

    row_height = 26
    header_height = 18
    w = doc.bounds().size.width
    y = 0  # Start from top (flipped view)

    # "Objects" header
    header = AppKit.NSTextField.labelWithString_('Objects')
    header.setFont_(AppKit.NSFont.boldSystemFontOfSize_(11))
    header.setTextColor_(_HEADER_COLOR)
    header.setFrame_(AppKit.NSMakeRect(6, y, w - 12, header_height))
    doc.addSubview_(header)
    y += header_height + 2

    # Object rows
    for name in objects:
        enabled = name in enabled_set
        row = _build_row(name, False, enabled)
        row.setFrame_(AppKit.NSMakeRect(0, y, w, row_height))
        doc.addSubview_(row)
        y += row_height + 1

    # "Selections" header (if any)
    if selections:
        y += 4
        sel_header = AppKit.NSTextField.labelWithString_('Selections')
        sel_header.setFont_(AppKit.NSFont.boldSystemFontOfSize_(11))
        sel_header.setTextColor_(_HEADER_COLOR)
        sel_header.setFrame_(AppKit.NSMakeRect(6, y, w - 12, header_height))
        doc.addSubview_(sel_header)
        y += header_height + 2

        for name in selections:
            enabled = name in enabled_set
            row = _build_row(name, True, enabled)
            row.setFrame_(AppKit.NSMakeRect(0, y, w, row_height))
            doc.addSubview_(row)
            y += row_height + 1

    # Resize document view to fit content
    doc.setFrameSize_(AppKit.NSMakeSize(w, max(y, doc.bounds().size.height)))


def _poll_objects():
    """Poll PyMOL for current objects/selections and rebuild if changed."""
    global _prev_names

    if not _cmd:
        return

    try:
        objects = list(_cmd.get_names('public_objects') or [])
        selections = list(_cmd.get_names('public_selections') or [])
        # Always include "all" at the top (it's a built-in, not returned by get_names)
        if 'all' not in objects:
            objects.insert(0, 'all')
    except Exception as e:
        try:
            all_names = list(_cmd.get_names() or [])
            objects = all_names
            selections = []
        except Exception:
            return

    current = objects + ['|'] + selections
    if current == _prev_names:
        return

    _prev_names = current

    # Get enabled set
    enabled_set = set()
    try:
        enabled_objects = set(_cmd.get_names('public_objects', enabled_only=1) or [])
        enabled_sels = set(_cmd.get_names('public_selections', enabled_only=1) or [])
        enabled_set = enabled_objects | enabled_sels
    except Exception:
        enabled_set = set(objects + selections)

    try:
        _rebuild_rows(objects, selections, enabled_set)
        with open('/tmp/pymol_objpanel.log', 'a') as f:
            f.write(f"poll: objects={objects} selections={selections} rebuilt OK\n")
    except Exception as e:
        with open('/tmp/pymol_objpanel.log', 'a') as f:
            import traceback
            f.write(f"poll ERROR: {e}\n{traceback.format_exc()}\n")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup(container_view, cmd):
    """Build the object panel inside the given NSView container.

    Called from main_appkit.mm after the window is created.
    """
    global _cmd, _container, _scroll_view, _stack_view, _poll_timer

    _cmd = cmd
    _container = container_view

    bounds = container_view.bounds()

    # Scroll view filling the container
    _scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(bounds)
    _scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    _scroll_view.setHasVerticalScroller_(True)
    _scroll_view.setHasHorizontalScroller_(False)
    _scroll_view.setDrawsBackground_(True)
    _scroll_view.setBackgroundColor_(_BG_COLOR)
    _scroll_view.setBorderType_(AppKit.NSNoBorder)

    # Flipped document view for top-down layout
    doc_view = ObjPanel_FlippedView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, bounds.size.width, bounds.size.height))
    doc_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)

    _scroll_view.setDocumentView_(doc_view)
    container_view.addSubview_(_scroll_view)

    # Start polling timer
    timer_target = ObjPanel_TimerTarget.alloc().init()
    _retained.append(timer_target)

    _poll_timer = AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.5, timer_target,
        objc.selector(timer_target.poll_, signature=b'v@:@'),
        None, True)

    # Also fire during event tracking so panel stays responsive during drags
    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _poll_timer, AppKit.NSRunLoopCommonModes)

    # Initial poll
    _poll_objects()
