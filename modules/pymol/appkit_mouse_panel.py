"""Native macOS mouse mode / selection mode panel for PyMOL using PyObjC.

Replicates the original ButMode panel: mouse button mapping grid,
selecting/picking line, state/frame line, and transport controls.

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
_text_view = None
_poll_timer = None
_prev_snapshot = None
_retained = []  # prevent GC of ObjC objects

# ---------------------------------------------------------------------------
# Theme colors — match the original ButMode C++ exactly
# ---------------------------------------------------------------------------

_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.2, 0.2, 0.22, 1.0)

# White: "Mouse Mode" header, "L M R Wheel" column headers
_WHITE = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.9, 0.9, 0.9, 1.0)

# Green: action codes (Rota, Move, etc.), mode name ("3-Button Viewing")
_GREEN = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.2, 1.0, 0.2, 1.0)

# Red: "Buttons", "& Keys", modifier labels (Shft, Ctrl, CtSh)
_RED = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 0.3, 0.3, 1.0)

# Yellow: "SnglClk", "DblClk", state numbers
_YELLOW = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    1.0, 1.0, 0.4, 1.0)

# Cyan: selection mode name ("Residues", "Chains", etc.)
_CYAN = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.3, 1.0, 1.0, 1.0)

# Gray: fallback
_GRAY = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.8, 0.8, 0.8, 1.0)

# Transport button colors
_BUTTON_BG = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.28, 0.28, 0.30, 1.0)
_BUTTON_TEXT = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.9, 0.55, 0.75, 1.0)

_MONO_FONT = None  # set in setup()

# ---------------------------------------------------------------------------
# Action code abbreviations — maps action string -> 5-char display code
# ---------------------------------------------------------------------------

CODE = {
    'rota': 'Rota ', 'move': 'Move ', 'movz': 'MovZ ', 'clip': 'Clip ',
    'rotz': 'RotZ ', 'clpn': 'ClpN ', 'clpf': 'ClpF ',
    'lb':   ' lb  ', 'mb':   ' mb  ', 'rb':   ' rb  ',
    '+lb':  '+lb  ', '+mb':  '+mb  ', '+rb':  '+rb  ',
    'pkat': 'PkAt ', 'pkbd': 'PkBd ', 'rotf': 'RotF ',
    'torf': 'TorF ', 'movf': 'MovF ', 'orig': 'Orig ',
    '+lbx': '+lBx ', '-lbx': '-lBx ', 'lbbx': 'lbBx ',
    'none': '  -  ', 'cent': 'Cent ', 'pktb': 'PkTB ',
    'slab': 'Slab ', 'movs': 'MovS ', 'pk1':  'Pk1  ',
    'mova': 'MovA ', 'menu': 'Menu ', 'sele': 'Sele ',
    '+/-':  '+/-  ', '+box': '+Box ', '-box': '-Box ',
    'mvsz': 'MvSZ ', 'clik': 'Clik ', 'mvoz': 'MvOZ ',
    'movo': 'MovO ', 'roto': 'RotO ', 'drgm': 'DrgM ',
    'rotv': 'RotV ', 'movv': 'MovV ', 'mvvz': 'MvVZ ',
    'drgo': 'DrgO ', 'mvfz': 'MvFZ ', 'mvaz': 'MvAZ ',
    'rotl': 'RotL ', 'movl': 'MovL ', 'mvzl': 'MvzL ',
    'imsz': 'IMSZ ', 'imvz': 'IMvZ ', 'box':  ' Box ',
    'irtz': 'IRtZ ',
    'rotd': 'RotD ', 'movd': 'MovD ', 'mvdz': 'MvDZ ',
}

BLANK = '     '

# ---------------------------------------------------------------------------
# Selection mode names (indexed by mouse_selection_mode setting)
# ---------------------------------------------------------------------------

_SELECTION_MODE_NAMES = [
    'Atoms', 'Residues', 'Chains', 'Segments',
    'Objects', 'Molecules', 'C-alphas',
]

# ---------------------------------------------------------------------------
# Mouse mode data — imported from pymol.controlling at runtime
# ---------------------------------------------------------------------------

def _get_mode_dict():
    try:
        from pymol.controlling import mode_dict
        return mode_dict
    except ImportError:
        return {}


def _get_mode_name_dict():
    try:
        from pymol.controlling import mode_name_dict
        return mode_name_dict
    except ImportError:
        return {}


def _get_mouse_ring():
    try:
        from pymol.controlling import mouse_ring
        return mouse_ring
    except ImportError:
        return ['three_button_viewing']


# ---------------------------------------------------------------------------
# Build the Mode[0..21] array from the controlling mode_dict
# ---------------------------------------------------------------------------

# Maps (button_str, modifier_str) -> index in Mode[] array
_BUTTON_MOD_TO_INDEX = {
    ('l', 'none'): 0,  ('m', 'none'): 1,  ('r', 'none'): 2,
    ('l', 'shft'): 3,  ('m', 'shft'): 4,  ('r', 'shft'): 5,
    ('l', 'ctrl'): 6,  ('m', 'ctrl'): 7,  ('r', 'ctrl'): 8,
    ('l', 'ctsh'): 9,  ('m', 'ctsh'): 10, ('r', 'ctsh'): 11,
    ('w', 'none'): 12, ('w', 'shft'): 13, ('w', 'ctrl'): 14, ('w', 'ctsh'): 15,
    ('double_left', 'none'): 16, ('double_middle', 'none'): 17, ('double_right', 'none'): 18,
    ('single_left', 'none'): 19, ('single_middle', 'none'): 20, ('single_right', 'none'): 21,
}


def _build_mode_array(mode_list):
    """Convert a mode_dict entry list into a 22-element Mode[] array of action strings."""
    mode = ['none'] * 22
    for entry in mode_list:
        btn, mod, act = entry[0], entry[1], entry[2]
        idx = _BUTTON_MOD_TO_INDEX.get((btn, mod))
        if idx is not None:
            mode[idx] = act.lower()
    return mode


def _code_for(action):
    """Return the 5-char display code for an action string."""
    return CODE.get(action.lower(), action[:5].ljust(5))


# ---------------------------------------------------------------------------
# Resolve the current mouse mode key
# ---------------------------------------------------------------------------

def _resolve_mode_key():
    """Return the current mode_key string and display name."""
    if _cmd is None:
        return 'three_button_viewing', '3-Button Viewing'

    try:
        button_mode_name = _cmd.get_setting_string('button_mode_name')
    except Exception:
        button_mode_name = '3-Button Viewing'

    mode_name_dict = _get_mode_name_dict()

    # Reverse lookup: find mode key from the display name
    mode_key = None
    for k, v in mode_name_dict.items():
        if v == button_mode_name:
            mode_key = k
            break

    # Fallback: try the mouse_ring
    if mode_key is None:
        try:
            bm = int(_cmd.get_setting_int('button_mode'))
            ring = _get_mouse_ring()
            if 0 <= bm < len(ring):
                mode_key = ring[bm]
            elif bm < 0:
                from pymol.controlling import mode_name_list
                idx = (-1 - bm) % len(mode_name_list)
                mode_key = mode_name_list[idx]
        except Exception:
            pass

    if mode_key is None:
        mode_key = 'three_button_viewing'

    return mode_key, button_mode_name


# ---------------------------------------------------------------------------
# Build the attributed string for the entire panel
# ---------------------------------------------------------------------------

def _build_panel_text():
    """Build an NSAttributedString replicating the original ButMode panel."""
    if _cmd is None:
        return None
    if _MONO_FONT is None:
        return None

    mode_key, button_mode_name = _resolve_mode_key()

    mode_dict = _get_mode_dict()
    mode_list = mode_dict.get(mode_key, [])
    mode = _build_mode_array(mode_list)

    try:
        sel_mode = int(_cmd.get_setting_int('mouse_selection_mode'))
    except Exception:
        sel_mode = 1

    try:
        state = int(_cmd.get('state'))
    except Exception:
        state = 1

    try:
        n_states = int(_cmd.count_states('all'))
    except Exception:
        n_states = 1
    if n_states < 1:
        n_states = 1

    # Check if single-left-click maps to PkAt (pick atom)
    single_left_is_pkat = (mode[19] == 'pkat')

    # Selection mode name
    sel_name = _SELECTION_MODE_NAMES[sel_mode] if 0 <= sel_mode < len(
        _SELECTION_MODE_NAMES) else 'Atoms'

    # --- Build attributed string ---
    result = AppKit.NSMutableAttributedString.alloc().init()

    def _append(text, color):
        attrs = {
            AppKit.NSFontAttributeName: _MONO_FONT,
            AppKit.NSForegroundColorAttributeName: color,
        }
        seg = AppKit.NSAttributedString.alloc().initWithString_attributes_(
            text, attrs)
        result.appendAttributedString_(seg)

    # Row 1: Mouse Mode  <mode_name>
    _append("Mouse Mode ", _WHITE)
    _append(button_mode_name, _GREEN)
    _append("\n", _WHITE)

    # Row 2: Buttons  L     M     R   Wheel
    _append("Buttons", _RED)
    _append("  L    M    R  Wheel\n", _WHITE)

    # Row 3:  & Keys <actions>
    _append("  & Keys", _RED)
    _append(" ", _GREEN)
    _append(_code_for(mode[0]), _GREEN)
    _append(_code_for(mode[1]), _GREEN)
    _append(_code_for(mode[2]), _GREEN)
    _append(_code_for(mode[12]), _GREEN)
    _append("\n", _GREEN)

    # Row 4:    Shft <actions>
    _append("    Shft", _RED)
    _append(" ", _GREEN)
    _append(_code_for(mode[3]), _GREEN)
    _append(_code_for(mode[4]), _GREEN)
    _append(_code_for(mode[5]), _GREEN)
    _append(_code_for(mode[13]), _GREEN)
    _append("\n", _GREEN)

    # Row 5:    Ctrl <actions>
    _append("    Ctrl", _RED)
    _append(" ", _GREEN)
    _append(_code_for(mode[6]), _GREEN)
    _append(_code_for(mode[7]), _GREEN)
    _append(_code_for(mode[8]), _GREEN)
    _append(_code_for(mode[14]), _GREEN)
    _append("\n", _GREEN)

    # Row 6:    CtSh <actions>
    _append("    CtSh", _RED)
    _append(" ", _GREEN)
    _append(_code_for(mode[9]), _GREEN)
    _append(_code_for(mode[10]), _GREEN)
    _append(_code_for(mode[11]), _GREEN)
    _append(_code_for(mode[15]), _GREEN)
    _append("\n", _GREEN)

    # Row 7: SnglClk <actions>
    _append(" SnglClk", _YELLOW)
    _append(" ", _GREEN)
    _append(_code_for(mode[19]), _GREEN)
    _append(_code_for(mode[20]), _GREEN)
    _append(_code_for(mode[21]), _GREEN)
    _append("\n", _GREEN)

    # Row 8: DblClk <actions>
    _append("  DblClk", _YELLOW)
    _append(" ", _GREEN)
    _append(_code_for(mode[16]), _GREEN)
    _append(_code_for(mode[17]), _GREEN)
    _append(_code_for(mode[18]), _GREEN)
    _append("\n", _GREEN)

    # Row 9: Selecting/Picking line
    if single_left_is_pkat:
        _append("Picking ", _GREEN)
        _append("Atoms (and Joints)", _CYAN)
    else:
        _append("Selecting ", _GREEN)
        _append(sel_name, _CYAN)
    _append("\n", _GREEN)

    # Row 10: State/Frame line
    has_movie = False
    try:
        movie_len = int(_cmd.count_frames())
        has_movie = movie_len > 1
    except Exception:
        pass

    if has_movie:
        _append("Frame ", _GREEN)
    else:
        _append("State", _GREEN)
    _append("  %4d/%4d" % (state, n_states), _YELLOW)
    _append("\n", _GRAY)

    return result


def _build_snapshot():
    """Return a hashable snapshot of the current state for change detection."""
    if _cmd is None:
        return None
    try:
        button_mode_name = _cmd.get_setting_string('button_mode_name')
        sel_mode = _cmd.get_setting_int('mouse_selection_mode')
        state = _cmd.get('state')
        n_states = _cmd.count_states('all')
        try:
            n_frames = _cmd.count_frames()
        except Exception:
            n_frames = 0
        return (button_mode_name, sel_mode, state, n_states, n_frames)
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Transport button actions
# ---------------------------------------------------------------------------

class _TransportTarget(AppKit.NSObject):
    """Target for transport control buttons."""

    def initWithCommand_(self, command):
        self = objc.super(_TransportTarget, self).init()
        if self is None:
            return None
        self._command = command
        return self

    @objc.typedSelector(b'v@:@')
    def buttonClicked_(self, sender):
        if _cmd is None:
            return
        try:
            cmd_str = self._command
            if cmd_str == 'rewind':
                _cmd.rewind()
            elif cmd_str == 'backward':
                _cmd.backward()
            elif cmd_str == 'stop':
                _cmd.mstop()
            elif cmd_str == 'play':
                _cmd.mplay()
            elif cmd_str == 'forward':
                _cmd.forward()
            elif cmd_str == 'ending':
                _cmd.ending()
            elif cmd_str == 'seq_view':
                sv = int(_cmd.get_setting_int('seq_view'))
                _cmd.set('seq_view', 1 - sv)
            elif cmd_str == 'rock':
                _cmd.rock(-1)
            elif cmd_str == 'fullscreen':
                _cmd.full_screen()
            elif cmd_str == 'mouse_mode_forward':
                from pymol.controlling import mouse as _mouse_cmd
                _mouse_cmd(action='forward', _self=_cmd)
            elif cmd_str == 'sel_mode_forward':
                from pymol.controlling import mouse as _mouse_cmd
                _mouse_cmd(action='select_forward', _self=_cmd)
        except Exception as e:
            print(f"Mouse panel transport error: {e}")


# ---------------------------------------------------------------------------
# Click handler for the text view (cycles modes)
# ---------------------------------------------------------------------------

class _ModeClickTarget(AppKit.NSObject):
    """Button target: cycle mouse mode forward."""

    @objc.typedSelector(b'v@:@')
    def clicked_(self, sender):
        if _cmd is None:
            return
        import sys
        try:
            from pymol.controlling import mouse_ring
            bm = int(_cmd.get_setting_int("button_mode"))
            bm = (bm + 1) % len(mouse_ring)
            _cmd.set("button_mode", str(bm), quiet=1)
            print(f"[mouse_panel] mode -> {bm}", file=sys.stderr, flush=True)
        except Exception as e:
            print(f"[mouse_panel] mode ERROR: {e}", file=sys.stderr, flush=True)
            import traceback
            traceback.print_exc(file=sys.stderr)


class _SelectionClickTarget(AppKit.NSObject):
    """Button target: cycle selection mode forward."""

    @objc.typedSelector(b'v@:@')
    def clicked_(self, sender):
        if _cmd is None:
            return
        import sys
        try:
            sm = int(_cmd.get_setting_int("mouse_selection_mode"))
            sm = (sm + 1) % 7
            _cmd.set("mouse_selection_mode", str(sm), quiet=1)
            print(f"[mouse_panel] sel -> {sm}", file=sys.stderr, flush=True)
        except Exception as e:
            print(f"[mouse_panel] sel ERROR: {e}", file=sys.stderr, flush=True)
            import traceback
            traceback.print_exc(file=sys.stderr)


# ---------------------------------------------------------------------------
# Polling
# ---------------------------------------------------------------------------

class _PollTimerTarget(AppKit.NSObject):
    """Target for the poll timer."""

    @objc.typedSelector(b'v@:@')
    def poll_(self, timer):
        _poll_panel()


def _poll_panel():
    """Poll PyMOL for changes and rebuild the panel text if needed."""
    global _prev_snapshot

    if _cmd is None or _text_view is None:
        return

    try:
        snapshot = _build_snapshot()
        if snapshot is None:
            snapshot = ('3-Button Viewing', 1, 1, 1, 0)
        if snapshot == _prev_snapshot:
            return
        _prev_snapshot = snapshot

        astr = _build_panel_text()
        if astr is None:
            return

        storage = _text_view.textStorage()
        storage.beginEditing()
        rng = (0, storage.length())
        storage.replaceCharactersInRange_withAttributedString_(rng, astr)
        storage.endEditing()
    except Exception as e:
        import sys
        print(f"[mouse_panel] poll error: {e}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# UI building
# ---------------------------------------------------------------------------

def _make_transport_button(title, command, frame):
    """Create a small transport control button."""
    btn = AppKit.NSButton.alloc().initWithFrame_(frame)
    btn.setBezelStyle_(AppKit.NSBezelStyleSmallSquare)
    btn.setBordered_(True)
    btn.setWantsLayer_(True)
    btn.layer().setBackgroundColor_(_BUTTON_BG.CGColor())
    btn.layer().setCornerRadius_(2.0)

    attrs = {
        AppKit.NSFontAttributeName: AppKit.NSFont.userFixedPitchFontOfSize_(9),
        AppKit.NSForegroundColorAttributeName: _BUTTON_TEXT,
    }
    astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
        title, attrs)
    btn.setAttributedTitle_(astr)

    target = _TransportTarget.alloc().initWithCommand_(command)
    _retained.append(target)
    btn.setTarget_(target)
    btn.setAction_(b'buttonClicked:')

    return btn


def _build_transport_bar(parent_view, y_offset, width):
    """Build the row of 9 transport buttons: |< < S P > >| S v F"""
    btn_h = 18
    padding = 1

    # 9 transport buttons matching original PyMOL: |< < ■ ▶ > >| S ▼ F
    transport_defs = [
        ('|<',           'rewind'),
        ('<',            'backward'),
        ('\u25A0',       'stop'),       # ■
        ('\u25B6',       'play'),       # ▶
        ('>',            'forward'),
        ('>|',           'ending'),
        ('S',            'seq_view'),
        ('\u25BC',       'rock'),       # ▼
        ('F',            'fullscreen'),
    ]

    n = len(transport_defs)
    total_pad = padding * (n + 1)
    btn_w = (width - total_pad) / n
    x = padding

    for title, command in transport_defs:
        frame = ((x, y_offset), (btn_w, btn_h))
        btn = _make_transport_button(title, command, frame)
        parent_view.addSubview_(btn)
        x += btn_w + padding

    return btn_h


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup(container_view, cmd):
    """Build the mouse panel inside the given NSView container.

    Called from main_appkit.mm after the window is created.
    *container_view* is the NSView designated for the mouse panel.
    *cmd* is the pymol.cmd module.
    """
    global _cmd, _container, _text_view, _poll_timer, _MONO_FONT

    _cmd = cmd
    _container = container_view
    _MONO_FONT = AppKit.NSFont.userFixedPitchFontOfSize_(10)

    bounds = container_view.bounds()
    w = bounds.size.width
    h = bounds.size.height

    container_view.setWantsLayer_(True)
    container_view.layer().setBackgroundColor_(_BG_COLOR.CGColor())

    # Transport buttons at the bottom
    transport_h = _build_transport_bar(container_view, 2, w)

    # Two small cycling buttons at the right edge
    cycle_btn_w = 22
    cycle_btn_h = 14

    # Text view — plain NSTextView, no scroll view
    # Added BEFORE the M/S buttons so buttons are on top in the z-order
    text_y = transport_h + 4
    text_h = h - text_y - 2
    text_frame = AppKit.NSMakeRect(2, text_y, w - cycle_btn_w - 6, text_h)
    _text_view = AppKit.NSTextView.alloc().initWithFrame_(text_frame)
    _text_view.setEditable_(False)
    _text_view.setSelectable_(False)
    _text_view.setRichText_(True)
    _text_view.setDrawsBackground_(False)
    _text_view.setTextColor_(_GRAY)
    _text_view.setFont_(_MONO_FONT)
    _text_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    _text_view.textContainer().setWidthTracksTextView_(True)
    container_view.addSubview_(_text_view)

    # Mode cycle button (top-right of text area)
    # Added AFTER text view so they sit on top and receive mouse clicks
    mode_btn = _make_transport_button("M", "mouse_mode_forward",
        ((w - cycle_btn_w - 2, h - cycle_btn_h - 2), (cycle_btn_w, cycle_btn_h)))
    container_view.addSubview_(mode_btn)

    sel_btn = _make_transport_button("S", "sel_mode_forward",
        ((w - cycle_btn_w - 2, h - 2 * cycle_btn_h - 4), (cycle_btn_w, cycle_btn_h)))
    container_view.addSubview_(sel_btn)

    # Initial render — force an initial text to verify the view works
    try:
        _poll_panel()
    except Exception as e:
        import sys
        print(f"[mouse_panel] initial poll failed: {e}", file=sys.stderr, flush=True)

    # If poll didn't populate text, write a placeholder
    if _text_view.textStorage().length() == 0:
        try:
            astr = _build_panel_text()
            if astr and astr.length() > 0:
                _text_view.textStorage().setAttributedString_(astr)
            else:
                _text_view.setString_(" Mouse Mode  3-Button Viewing\n Loading...")
        except Exception:
            _text_view.setString_(" Mouse Mode  3-Button Viewing\n Loading...")

    # Start polling timer (500ms)
    timer_target = _PollTimerTarget.alloc().init()
    _retained.append(timer_target)

    _poll_timer = (
        AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, timer_target,
            objc.selector(timer_target.poll_, signature=b'v@:@'),
            None, True))

    # Also fire during event tracking so panel stays responsive
    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _poll_timer, AppKit.NSRunLoopCommonModes)
