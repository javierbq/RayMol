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
# Menu option lists  (title, command, [color_rgb])
# ---------------------------------------------------------------------------

# Show/Hide share the same menu structure; Show calls cmd.show, Hide calls
# cmd.hide.  Entries: (label, representation_or_None, is_header).
# '---' = separator, items with cmd=None are disabled group headers.
_SHOW_HIDE_OPTIONS = [
    ('everything', 'everything'),
    ('---', None),
    ('lines', 'lines'),
    ('nonbonded', 'nonbonded'),
    ('---', None),
    ('sticks', 'sticks'),
    ('nb_spheres', 'nb_spheres'),
    ('---', None),
    ('ribbon', 'ribbon'),
    ('cartoon', 'cartoon'),
    ('labels', 'labels'),
    ('cell', 'cell'),
    ('dots', 'dots'),
    ('spheres', 'spheres'),
    ('mesh', 'mesh'),
    ('surface', 'surface'),
    ('volume', 'volume'),
    ('slice', 'slice'),
    ('extent', 'extent'),
    ('---', None),
    ('licorice', 'licorice'),
    ('wire', 'wire'),
    ('dashes', 'dashes'),
]

_LABEL_OPTIONS = [
    ('None', ''),
    ('---', None),
    ('Residues', 'resn+resi'),
    ('Chains', 'chain'),
    ('Segments', 'segi'),
    ('Atoms', 'name'),
    ('Elements', 'elem'),
]

# (title, command, color_rgb_or_None)
_COLOR_OPTIONS = [
    ('by element', 'util.cbag', None),
    ('by chain', 'util.cbc', None),
    ('by ss', 'util.cbss', None),
    ('by rep', None, None),
    ('spectrum', 'spectrum', None),
    ('auto', 'util.cba', None),
    ('---', None, None),
    ('reds', 'red', (1.0, 0.0, 0.0)),
    ('greens', 'green', (0.0, 1.0, 0.0)),
    ('blues', 'blue', (0.0, 0.3, 1.0)),
    ('yellows', 'yellow', (1.0, 1.0, 0.0)),
    ('magentas', 'magenta', (1.0, 0.0, 1.0)),
    ('cyans', 'cyan', (0.0, 1.0, 1.0)),
    ('oranges', 'orange', (1.0, 0.5, 0.0)),
    ('tints', 'lightteal', (0.7, 0.9, 0.9)),
    ('grays', 'gray', (0.5, 0.5, 0.5)),
]

_ACTION_OPTIONS = [
    ('Zoom', 'zoom'),
    ('Orient', 'orient'),
    ('Center', 'center'),
    ('---', None),
    ('Delete', 'delete'),
    ('Duplicate', 'copy'),
    ('Rename', None),
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
            if action in ('show', 'hide'):
                # Look up the representation command from _SHOW_HIDE_OPTIONS
                for opt_title, opt_cmd in _SHOW_HIDE_OPTIONS:
                    if opt_title == title and opt_cmd is not None:
                        if action == 'show':
                            if opt_cmd == 'as':
                                self._cmd.show('everything', name)
                            else:
                                self._cmd.show(opt_cmd, name)
                        else:
                            if opt_cmd == 'as':
                                self._cmd.hide('everything', name)
                            else:
                                self._cmd.hide(opt_cmd, name)
                        break
            elif action == 'label':
                for item in _LABEL_OPTIONS:
                    if item[0] == title and item[1] is not None:
                        if item[1]:
                            self._cmd.label(name, item[1])
                        else:
                            self._cmd.label(name, '')
                        break
            elif action == 'color':
                for item in _COLOR_OPTIONS:
                    if item[0] == title and item[1] is not None:
                        cmd_str = item[1]
                        if cmd_str.startswith('util.'):
                            func = getattr(self._cmd.util, cmd_str[5:])
                            func(name)
                        elif cmd_str == 'spectrum':
                            self._cmd.spectrum('count', selection=name)
                        else:
                            self._cmd.color(cmd_str, name)
                        break
            elif action == 'action':
                for item in _ACTION_OPTIONS:
                    if item[0] == title and item[1] is not None:
                        act_cmd = item[1]
                        if act_cmd == 'zoom':
                            self._cmd.zoom(name)
                        elif act_cmd == 'orient':
                            self._cmd.orient(name)
                        elif act_cmd == 'center':
                            self._cmd.center(name)
                        elif act_cmd == 'delete':
                            self._cmd.delete(name)
                        elif act_cmd == 'copy':
                            self._cmd.copy(name + '_copy', name)
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
    """Create a small popup button with structured menu items.

    *items* is a list of tuples.  Each tuple has at least two elements:
      (label, command_or_None [, color_rgb_or_None])
    '---' labels become separator items.  Items with command=None are
    rendered as disabled group headers.  If a color tuple is present the
    menu item text is rendered in that color.
    """
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

    for item_info in items:
        item_title = item_info[0]

        # Separator
        if item_title == '---':
            btn.menu().addItem_(AppKit.NSMenuItem.separatorItem())
            continue

        btn.addItemWithTitle_(item_title)
        menu_item = btn.lastItem()

        # Disabled group header (no command)
        if item_info[1] is None:
            menu_item.setEnabled_(False)

        # Colored text (color items)
        if len(item_info) > 2 and item_info[2] is not None:
            r, g, b = item_info[2]
            color = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
                r, g, b, 1.0)
            attrs = {
                AppKit.NSFontAttributeName: AppKit.NSFont.systemFontOfSize_(11),
                AppKit.NSForegroundColorAttributeName: color,
            }
            astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                item_title, attrs)
            menu_item.setAttributedTitle_(astr)

    btn.setTarget_(target)
    btn.setAction_(action_sel)
    return btn


def _build_row(name, is_selection, enabled, row_width=280):
    """Build a single row NSView for an object or selection."""
    row_height = 24
    row = AppKit.NSView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, row_width, row_height))
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

    # Name label — stretches up to the buttons
    display_name = name
    if is_selection:
        try:
            count = _cmd.count_atoms(name)
            display_name = f"{name} ({count})"
        except Exception:
            pass

    btn_width = 22
    btn_spacing = 1
    num_buttons = 5
    buttons_total = num_buttons * btn_width + (num_buttons - 1) * btn_spacing
    btn_start_x = row_width - buttons_total - 18  # 18px right margin (clear scrollbar)
    label_width = btn_start_x - 24 - 2  # 24=label x, 2=gap

    label = AppKit.NSTextField.labelWithString_(display_name)
    label.setFrame_(AppKit.NSMakeRect(24, 2, label_width, 18))
    label.setFont_(AppKit.NSFont.systemFontOfSize_(11))
    label.setTextColor_(_SELECTION_TEXT_COLOR if is_selection else _TEXT_COLOR)
    label.setLineBreakMode_(AppKit.NSLineBreakByTruncatingTail)
    label.setDrawsBackground_(False)
    label.setBezeled_(False)
    label.setEditable_(False)
    label.setSelectable_(False)
    row.addSubview_(label)

    # A/S/H/L/C popup buttons — right-aligned
    button_defs = [
        ('A', _ACTION_OPTIONS, 'action'),
        ('S', _SHOW_HIDE_OPTIONS, 'show'),
        ('H', _SHOW_HIDE_OPTIONS, 'hide'),
        ('L', _LABEL_OPTIONS, 'label'),
        ('C', _COLOR_OPTIONS, 'color'),
    ]

    x_offset = btn_start_x

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
        row = _build_row(name, False, enabled, row_width=w)
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
            row = _build_row(name, True, enabled, row_width=w)
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

    # Include selection counts in the comparison key so the panel
    # updates when selection content changes (not just names)
    sel_counts = []
    for s in selections:
        try:
            sel_counts.append(_cmd.count_atoms(s))
        except:
            sel_counts.append(0)

    current = objects + ['|'] + selections + ['#'] + [str(c) for c in sel_counts]
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
