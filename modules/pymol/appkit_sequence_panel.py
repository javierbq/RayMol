"""Native macOS sequence viewer panel for PyMOL using PyObjC.

Displays the one-letter amino acid sequence for loaded molecular objects
as a horizontal scrollable bar at the top of the viewport area (below
the log panel). Shows/hides based on the seq_view setting.

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
_content_view = None
_poll_timer = None
_prev_snapshot = None  # change detection
_retained = []  # prevent GC of ObjC objects

# Height of the sequence bar (in points)
SEQ_BAR_HEIGHT = 22

# ---------------------------------------------------------------------------
# Theme colors
# ---------------------------------------------------------------------------

_BG_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.13, 0.13, 0.15, 1.0)
_TEXT_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.85, 0.85, 0.85, 1.0)
_HEADER_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.55, 0.75, 1.0, 1.0)
_SEPARATOR_COLOR = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(
    0.4, 0.4, 0.4, 1.0)

# Chain colors — cycle through these for different chains
_CHAIN_COLORS = [
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.3, 1.0, 0.3, 1.0),   # green
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.3, 0.8, 1.0, 1.0),   # cyan
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 1.0, 0.3, 1.0),   # yellow
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.5, 0.3, 1.0),   # orange
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(1.0, 0.3, 1.0, 1.0),   # magenta
    AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(0.85, 0.85, 0.85, 1.0), # white
]

# Three-letter to one-letter amino acid code mapping
_AA3TO1 = {
    'ALA': 'A', 'ARG': 'R', 'ASN': 'N', 'ASP': 'D', 'CYS': 'C',
    'GLN': 'Q', 'GLU': 'E', 'GLY': 'G', 'HIS': 'H', 'ILE': 'I',
    'LEU': 'L', 'LYS': 'K', 'MET': 'M', 'PHE': 'F', 'PRO': 'P',
    'SER': 'S', 'THR': 'T', 'TRP': 'W', 'TYR': 'Y', 'VAL': 'V',
    # Common modified residues
    'MSE': 'M', 'HSD': 'H', 'HSE': 'H', 'HSP': 'H',
    # Nucleic acids
    'DA': 'A', 'DC': 'C', 'DG': 'G', 'DT': 'T',
    'A': 'A', 'C': 'C', 'G': 'G', 'U': 'U',
}

_MONO_FONT = None


# ---------------------------------------------------------------------------
# Sequence extraction
# ---------------------------------------------------------------------------

def _get_sequences():
    """Return a list of (object_name, [(chain, one_letter_code, resi), ...]).

    Only includes objects that are enabled and have seq_view on.
    """
    if not _cmd:
        return []

    results = []
    try:
        names = _cmd.get_names('public_objects', enabled_only=1) or []
    except Exception:
        return []

    for name in names:
        try:
            obj_type = _cmd.get_type(name)
            if obj_type != 'object:molecule':
                continue
        except Exception:
            continue

        # Build residue list from atom data
        residues = []
        seen = set()
        try:
            model = _cmd.get_model(name + " and guide")  # CA atoms (or P for nucleic)
            if model and model.atom:
                for atom in model.atom:
                    key = (atom.chain, atom.resn, atom.resi)
                    if key in seen:
                        continue
                    seen.add(key)
                    one_letter = _AA3TO1.get(atom.resn.upper(), '?')
                    residues.append((atom.chain, one_letter, atom.resi, atom.resn))
        except Exception:
            # Fallback: try get_fastastr
            try:
                fasta = _cmd.get_fastastr(name)
                if fasta:
                    for line in fasta.strip().split('\n'):
                        if not line.startswith('>'):
                            for ch in line.strip():
                                residues.append(('', ch, '', ''))
            except Exception:
                continue

        if residues:
            results.append((name, residues))

    return results


# ---------------------------------------------------------------------------
# UI building
# ---------------------------------------------------------------------------

class SeqPanel_FlippedView(AppKit.NSView):
    """NSView with flipped coordinates for left-to-right layout."""
    def isFlipped(self):
        return True


class SeqPanel_TimerTarget(AppKit.NSObject):
    """Target for the poll timer."""

    @objc.typedSelector(b'v@:@')
    def poll_(self, timer):
        _poll_sequence()


class SeqPanel_ClickTarget(AppKit.NSObject):
    """Target for clicking on a residue to select it."""

    def initWithCmd_objName_resi_chain_(self, cmd, obj_name, resi, chain):
        self = objc.super(SeqPanel_ClickTarget, self).init()
        if self is None:
            return None
        self._cmd = cmd
        self._obj_name = obj_name
        self._resi = resi
        self._chain = chain
        return self

    @objc.typedSelector(b'v@:@')
    def clicked_(self, sender):
        try:
            sel = self._obj_name
            if self._chain:
                sel += " and chain " + self._chain
            if self._resi:
                sel += " and resi " + str(self._resi)
            self._cmd.select("sele", sel)
            self._cmd.center(sel, animate=-1)
        except Exception as e:
            print(f"SeqPanel click error: {e}")


def _build_sequence_content(sequences):
    """Build the horizontal sequence content inside the scroll view."""
    global _retained
    _retained = []

    if _content_view is None:
        return

    # Remove existing subviews
    for sv in list(_content_view.subviews()):
        sv.removeFromSuperview()

    if not sequences:
        _content_view.setFrameSize_(AppKit.NSMakeSize(
            _scroll_view.bounds().size.width, SEQ_BAR_HEIGHT))
        return

    global _MONO_FONT
    if _MONO_FONT is None:
        _MONO_FONT = AppKit.NSFont.fontWithName_size_('Menlo', 11.0)
        if _MONO_FONT is None:
            _MONO_FONT = AppKit.NSFont.userFixedPitchFontOfSize_(11.0)

    char_width = 8.5  # approximate width of a monospace char at size 11
    x = 4.0  # starting x position
    y = 2.0  # vertical position

    chain_color_map = {}
    color_idx = 0

    for obj_name, residues in sequences:
        # Object name label
        label = AppKit.NSTextField.labelWithString_(obj_name + ": ")
        label.setFont_(AppKit.NSFont.boldSystemFontOfSize_(10))
        label.setTextColor_(_HEADER_COLOR)
        label.sizeToFit()
        label_width = label.frame().size.width
        label.setFrame_(AppKit.NSMakeRect(x, y, label_width, SEQ_BAR_HEIGHT - 4))
        label.setDrawsBackground_(False)
        label.setBezeled_(False)
        label.setEditable_(False)
        label.setSelectable_(False)
        _content_view.addSubview_(label)
        x += label_width + 2

        # Residues
        prev_chain = None
        for chain, one_letter, resi, resn in residues:
            # Assign color per chain
            if chain not in chain_color_map:
                chain_color_map[chain] = _CHAIN_COLORS[color_idx % len(_CHAIN_COLORS)]
                color_idx += 1

            # Chain separator
            if prev_chain is not None and chain != prev_chain:
                sep = AppKit.NSTextField.labelWithString_("|")
                sep.setFont_(_MONO_FONT)
                sep.setTextColor_(_SEPARATOR_COLOR)
                sep.setFrame_(AppKit.NSMakeRect(x, y, char_width, SEQ_BAR_HEIGHT - 4))
                sep.setDrawsBackground_(False)
                sep.setBezeled_(False)
                sep.setEditable_(False)
                sep.setSelectable_(False)
                _content_view.addSubview_(sep)
                x += char_width

            prev_chain = chain

            # Residue button (clickable label)
            btn = AppKit.NSButton.alloc().initWithFrame_(
                AppKit.NSMakeRect(x, y, char_width, SEQ_BAR_HEIGHT - 4))
            btn.setBezelStyle_(AppKit.NSBezelStyleInline)
            btn.setBordered_(False)
            btn.setTitle_(one_letter)
            btn.setFont_(_MONO_FONT)

            # Style the button text with chain color
            color = chain_color_map.get(chain, _TEXT_COLOR)
            attrs = {
                AppKit.NSFontAttributeName: _MONO_FONT,
                AppKit.NSForegroundColorAttributeName: color,
            }
            astr = AppKit.NSAttributedString.alloc().initWithString_attributes_(
                one_letter, attrs)
            btn.setAttributedTitle_(astr)

            # Tooltip with residue info
            tooltip = resn if resn else one_letter
            if resi:
                tooltip += " " + str(resi)
            if chain:
                tooltip += " (chain " + chain + ")"
            btn.setToolTip_(tooltip)

            # Click target
            target = SeqPanel_ClickTarget.alloc().initWithCmd_objName_resi_chain_(
                _cmd, obj_name, resi, chain)
            _retained.append(target)
            btn.setTarget_(target)
            btn.setAction_(objc.selector(target.clicked_, signature=b'v@:@'))

            _content_view.addSubview_(btn)
            x += char_width

        # Gap between objects
        x += char_width * 2

    # Resize content to fit
    _content_view.setFrameSize_(AppKit.NSMakeSize(
        max(x + 4, _scroll_view.bounds().size.width), SEQ_BAR_HEIGHT))


def _poll_sequence():
    """Poll for seq_view setting and update the sequence display."""
    if not _cmd or not _container:
        return

    try:
        seq_view = int(_cmd.get('seq_view'))
    except Exception:
        seq_view = 0

    if seq_view:
        if _container.isHidden():
            _container.setHidden_(False)
            _notify_layout_change()

        sequences = _get_sequences()
        # Build a snapshot for change detection
        snapshot = str(sequences)
        global _prev_snapshot
        if snapshot != _prev_snapshot:
            _prev_snapshot = snapshot
            _build_sequence_content(sequences)
    else:
        if not _container.isHidden():
            _container.setHidden_(True)
            _prev_snapshot = None
            _notify_layout_change()


def _notify_layout_change():
    """Tell the app delegate to relayout after show/hide."""
    try:
        delegate = AppKit.NSApp.delegate()
        if hasattr(delegate, 'relayoutCenter'):
            delegate.relayoutCenter()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def setup(container_view, cmd):
    """Build the sequence panel inside the given NSView container.

    Called from main_appkit.mm after the window is created.
    """
    global _cmd, _container, _scroll_view, _content_view, _poll_timer

    _cmd = cmd
    _container = container_view

    bounds = container_view.bounds()

    # Horizontal scroll view
    _scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, bounds.size.width, SEQ_BAR_HEIGHT))
    _scroll_view.setAutoresizingMask_(
        AppKit.NSViewWidthSizable | AppKit.NSViewHeightSizable)
    _scroll_view.setHasVerticalScroller_(False)
    _scroll_view.setHasHorizontalScroller_(True)
    _scroll_view.setDrawsBackground_(True)
    _scroll_view.setBackgroundColor_(_BG_COLOR)
    _scroll_view.setBorderType_(AppKit.NSNoBorder)

    # Content view (wider than visible area for scrolling)
    _content_view = SeqPanel_FlippedView.alloc().initWithFrame_(
        AppKit.NSMakeRect(0, 0, bounds.size.width, SEQ_BAR_HEIGHT))
    _content_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)

    _scroll_view.setDocumentView_(_content_view)
    container_view.addSubview_(_scroll_view)

    # Start hidden — seq_view defaults to off
    container_view.setHidden_(True)

    # Poll timer
    timer_target = SeqPanel_TimerTarget.alloc().init()
    _retained.append(timer_target)

    _poll_timer = AppKit.NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.5, timer_target,
        objc.selector(timer_target.poll_, signature=b'v@:@'),
        None, True)

    AppKit.NSRunLoop.currentRunLoop().addTimer_forMode_(
        _poll_timer, AppKit.NSRunLoopCommonModes)
