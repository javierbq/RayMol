"""
Build native macOS menu bar for the AppKit host.

Translates the PyMOL menu hierarchy (from _gui.py) into an NSMenu bar
using PyObjC.  Called once during startup from main_appkit.mm.
"""

import objc
import webbrowser
import AppKit

# ---------------------------------------------------------------------------
# Module-level state
# ---------------------------------------------------------------------------

_cmd = None

# We must prevent the GC from collecting ObjC action targets.
_retained = []

_tag_counter = 0

# tag -> PyMOL command string
_command_map = {}

# tag -> setting name (for toggle / check items)
_toggle_map = {}

# tag -> (setting_name, value) for radio items
_radio_map = {}


# ---------------------------------------------------------------------------
# ObjC helper classes
# ---------------------------------------------------------------------------

class _MenuTarget(AppKit.NSObject):
    """Receives actions from simple command menu items."""

    @objc.python_method
    def _do(self, cmd_str):
        try:
            _cmd.do(cmd_str)
        except Exception as e:
            print(f"[appkit_menus] command error: {e}")

    def doCommand_(self, sender):
        tag = sender.tag()
        cmd_str = _command_map.get(tag, '')
        if cmd_str:
            self._do(cmd_str)

    def doToggle_(self, sender):
        tag = sender.tag()
        setting = _toggle_map.get(tag)
        if setting:
            try:
                cur = _cmd.get_setting_int(setting)
                _cmd.set(setting, 1 - cur)
            except Exception:
                _cmd.do(f"set {setting}, toggle")

    def doRadio_(self, sender):
        tag = sender.tag()
        info = _radio_map.get(tag)
        if info:
            setting, value = info
            _cmd.set(setting, value)

    # --- File dialogs ---

    def openFile_(self, sender):
        panel = AppKit.NSOpenPanel.openPanel()
        panel.setAllowsMultipleSelection_(True)
        panel.setCanChooseFiles_(True)
        panel.setCanChooseDirectories_(False)
        if panel.runModal() == AppKit.NSModalResponseOK:
            for url in panel.URLs():
                path = str(url.path())
                _cmd.load(path)

    def saveSession_(self, sender):
        panel = AppKit.NSSavePanel.savePanel()
        panel.setAllowedFileTypes_(["pse"])
        panel.setNameFieldStringValue_("session.pse")
        if panel.runModal() == AppKit.NSModalResponseOK:
            path = str(panel.URL().path())
            _cmd.save(path)

    def saveSessionQuick_(self, sender):
        try:
            fn = _cmd.get("session_file")
            if fn:
                _cmd.save(fn)
            else:
                self.saveSession_(sender)
        except Exception:
            self.saveSession_(sender)

    def exportPNG_(self, sender):
        panel = AppKit.NSSavePanel.savePanel()
        panel.setAllowedFileTypes_(["png"])
        panel.setNameFieldStringValue_("image.png")
        if panel.runModal() == AppKit.NSModalResponseOK:
            path = str(panel.URL().path())
            _cmd.png(path)

    def runScript_(self, sender):
        panel = AppKit.NSOpenPanel.openPanel()
        panel.setAllowsMultipleSelection_(False)
        panel.setCanChooseFiles_(True)
        panel.setAllowedFileTypes_(["pml", "py", "pse", "psw"])
        if panel.runModal() == AppKit.NSModalResponseOK:
            path = str(panel.URL().path())
            if path.endswith('.pml'):
                _cmd.do(f"@{path}")
            elif path.endswith(('.pse', '.psw')):
                _cmd.load(path)
            else:
                _cmd.do(f"run {path}")

    def fetchPDB_(self, sender):
        alert = AppKit.NSAlert.alloc().init()
        alert.setMessageText_("Fetch Structure")
        alert.setInformativeText_("Enter a PDB code (e.g. 1ubq):")
        alert.addButtonWithTitle_("Fetch")
        alert.addButtonWithTitle_("Cancel")

        field = AppKit.NSTextField.alloc().initWithFrame_(
            AppKit.NSMakeRect(0, 0, 200, 24))
        field.setStringValue_("")
        alert.setAccessoryView_(field)
        alert.window().setInitialFirstResponder_(field)

        if alert.runModal() == AppKit.NSAlertFirstButtonReturn:
            code = str(field.stringValue()).strip()
            if code:
                _cmd.fetch(code)

    def openURL_(self, sender):
        tag = sender.tag()
        url = _command_map.get(tag, '')
        if url:
            webbrowser.open(url)


# Singleton target
_target = None


def _get_target():
    global _target
    if _target is None:
        _target = _MenuTarget.alloc().init()
        _retained.append(_target)
    return _target


# ---------------------------------------------------------------------------
# Menu construction helpers
# ---------------------------------------------------------------------------

def _next_tag():
    global _tag_counter
    _tag_counter += 1
    return _tag_counter


def _menu_cmd(menu, title, command, key='', modifiers=None):
    """Add a menu item that executes a PyMOL command string."""
    tag = _next_tag()
    _command_map[tag] = command
    item = menu.addItemWithTitle_action_keyEquivalent_(
        title, 'doCommand:', key)
    item.setTag_(tag)
    item.setTarget_(_get_target())
    if modifiers is not None:
        item.setKeyEquivalentModifierMask_(modifiers)
    return item


def _menu_url(menu, title, url, key=''):
    """Add a menu item that opens a URL in the default browser."""
    tag = _next_tag()
    _command_map[tag] = url
    item = menu.addItemWithTitle_action_keyEquivalent_(
        title, 'openURL:', key)
    item.setTag_(tag)
    item.setTarget_(_get_target())
    return item


def _menu_action(menu, title, action, key='', modifiers=None):
    """Add a menu item with a specific selector on the shared target."""
    item = menu.addItemWithTitle_action_keyEquivalent_(
        title, action, key)
    item.setTarget_(_get_target())
    if modifiers is not None:
        item.setKeyEquivalentModifierMask_(modifiers)
    return item


def _menu_toggle(menu, title, setting, key=''):
    """Add a checkbox menu item that toggles a PyMOL setting."""
    tag = _next_tag()
    _toggle_map[tag] = setting
    item = menu.addItemWithTitle_action_keyEquivalent_(
        title, 'doToggle:', key)
    item.setTag_(tag)
    item.setTarget_(_get_target())
    return item


def _menu_radio(menu, title, setting, value, key=''):
    """Add a radio-style menu item that sets a PyMOL setting to a value."""
    tag = _next_tag()
    _radio_map[tag] = (setting, value)
    item = menu.addItemWithTitle_action_keyEquivalent_(
        title, 'doRadio:', key)
    item.setTag_(tag)
    item.setTarget_(_get_target())
    return item


def _sep(menu):
    menu.addItem_(AppKit.NSMenuItem.separatorItem())


def _submenu(parent_menu, title):
    sub = AppKit.NSMenu.alloc().initWithTitle_(title)
    sub.setAutoenablesItems_(False)
    item = parent_menu.addItemWithTitle_action_keyEquivalent_(
        title, None, '')
    parent_menu.setSubmenu_forItem_(sub, item)
    return sub


# Modifier mask constants
_CMD = AppKit.NSEventModifierFlagCommand
_SHIFT = AppKit.NSEventModifierFlagShift
_CMD_SHIFT = _CMD | _SHIFT


# ---------------------------------------------------------------------------
# Menu builders
# ---------------------------------------------------------------------------

def _add_file_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("File")
    menu.setAutoenablesItems_(False)

    _menu_action(menu, "Open...", 'openFile:', 'o')
    _menu_action(menu, "Get PDB...", 'fetchPDB_:', 'f', _CMD_SHIFT)
    _sep(menu)
    _menu_action(menu, "Save Session", 'saveSessionQuick_:', 's')
    _menu_action(menu, "Save Session As...", 'saveSession:', 's', _CMD_SHIFT)
    _sep(menu)

    # Export Image As submenu
    export_img = _submenu(menu, "Export Image As")
    _menu_action(export_img, "PNG...", 'exportPNG_:')

    _sep(menu)

    _menu_action(menu, "Run Script...", 'runScript_:')
    _sep(menu)

    # Reinitialize submenu
    reinit = _submenu(menu, "Reinitialize")
    _menu_cmd(reinit, "Everything", "reinitialize")
    _menu_cmd(reinit, "Original Settings", "reinitialize original_settings")
    _menu_cmd(reinit, "Stored Settings", "reinitialize settings")
    _sep(reinit)
    _menu_cmd(reinit, "Store Current Settings", "reinitialize store_defaults")

    _sep(menu)

    # Log File submenu
    logfile = _submenu(menu, "Log File")
    _menu_cmd(logfile, "Close", "log_close")

    _sep(menu)
    _menu_cmd(menu, "Quit", "quit", 'q')

    item.setSubmenu_(menu)


def _add_edit_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Edit")
    menu.setAutoenablesItems_(False)

    _menu_cmd(menu, "Undo", "undo", 'z')
    _menu_cmd(menu, "Redo", "redo", 'z', _CMD_SHIFT)

    item.setSubmenu_(menu)


def _add_build_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Build")
    menu.setAutoenablesItems_(False)

    # Fragment submenu
    frag = _submenu(menu, "Fragment")
    fragments = [
        ("Acetylene", "editor.attach_fragment('pk1','acetylene',2,0)"),
        ("Amide N->C", "editor.attach_fragment('pk1','formamide',3,1)"),
        ("Amide C->N", "editor.attach_fragment('pk1','formamide',5,0)"),
        ("Bromine", "replace Br,1,1"),
        ("Carbon", "replace C,4,4"),
        ("Carbonyl", "editor.attach_fragment('pk1','formaldehyde',2,0)"),
        ("Chlorine", "replace Cl,1,1"),
        ("Cyclobutyl", "editor.attach_fragment('pk1','cyclobutane',4,0)"),
        ("Cyclopentyl", "editor.attach_fragment('pk1','cyclopentane',5,0)"),
        ("Cyclopentadiene", "editor.attach_fragment('pk1','cyclopentadiene',5,0)"),
        ("Cyclohexyl", "editor.attach_fragment('pk1','cyclohexane',7,0)"),
        ("Cycloheptyl", "editor.attach_fragment('pk1','cycloheptane',8,0)"),
        ("Fluorine", "replace F,1,1"),
        ("Iodine", "replace I,1,1"),
        ("Methane", "editor.attach_fragment('pk1','methane',1,0)"),
        ("Nitrogen", "replace N,4,3"),
        ("Oxygen", "replace O,4,2"),
        ("Sulfer", "replace S,2,2"),
        ("Sulfonyl", "editor.attach_fragment('pk1','sulfone',3,1)"),
        ("Phosphorus", "replace P,4,3"),
    ]
    for label, cmd_str in fragments:
        _menu_cmd(frag, label, cmd_str)

    # Residue submenu
    res = _submenu(menu, "Residue")
    residues = [
        ("Acetyl", "ace"), ("Alanine", "ala"), ("Amine", "nhh"),
        ("Aspartate", "asp"), ("Asparagine", "asn"), ("Arginine", "arg"),
        ("Cysteine", "cys"), ("Glutamate", "glu"), ("Glutamine", "gln"),
        ("Glycine", "gly"), ("Histidine", "his"), ("Isoleucine", "ile"),
        ("Leucine", "leu"), ("Lysine", "lys"), ("Methionine", "met"),
        ("N-Methyl", "nme"), ("Phenylalanine", "phe"), ("Proline", "pro"),
        ("Serine", "ser"), ("Threonine", "thr"), ("Tryptophan", "trp"),
        ("Tyrosine", "tyr"), ("Valine", "val"),
    ]
    for label, code in residues:
        _menu_cmd(res, label, f"editor.attach_amino_acid('pk1','{code}')")
    _sep(res)
    _menu_radio(res, "Helix", "secondary_structure", 1)
    _menu_radio(res, "Antiparallel Beta Sheet", "secondary_structure", 2)
    _menu_radio(res, "Parallel Beta Sheet", "secondary_structure", 3)

    _sep(menu)

    # Sculpting submenu
    sculpt = _submenu(menu, "Sculpting")
    _menu_toggle(sculpt, "Auto-Sculpting", "auto_sculpt")
    _menu_toggle(sculpt, "Sculpting", "sculpting")
    _sep(sculpt)
    _menu_cmd(sculpt, "Activate", "sculpt_activate all")
    _menu_cmd(sculpt, "Deactivate", "sculpt_deactivate all")
    _menu_cmd(sculpt, "Clear Memory", "sculpt_purge")

    _sep(menu)
    _menu_cmd(menu, "Cycle Bond Valence", "cycle_valence")
    _menu_cmd(menu, "Fill Hydrogens on (pk1)", "h_fill")
    _menu_cmd(menu, "Invert (pk2)-(pk1)-(pk3)", "invert")
    _menu_cmd(menu, "Create Bond (pk1)-(pk2)", "bond")
    _sep(menu)
    _menu_cmd(menu, "Remove (pk1)", "remove pk1")
    _sep(menu)
    _menu_cmd(menu, "Make (pk1) Positive", "alter pk1, formal_charge=1")
    _menu_cmd(menu, "Make (pk1) Negative", "alter pk1, formal_charge=-1")
    _menu_cmd(menu, "Make (pk1) Neutral", "alter pk1, formal_charge=0")

    item.setSubmenu_(menu)


def _add_movie_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Movie")
    menu.setAutoenablesItems_(False)

    # Append submenu
    append = _submenu(menu, "Append")
    for secs in [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 18, 24, 30, 48, 60]:
        label = f"{secs} second" if secs == 1 else f"{secs} seconds"
        _menu_cmd(append, label, f"movie.add_blank({secs})")

    _sep(menu)
    _menu_cmd(menu, "Reset", "mset;rewind")
    _sep(menu)

    # Frame Rate submenu
    fps = _submenu(menu, "Frame Rate")
    _menu_radio(fps, "30 FPS", "movie_fps", 30.0)
    _menu_radio(fps, "15 FPS", "movie_fps", 15.0)
    _menu_radio(fps, "5 FPS", "movie_fps", 5.0)
    _menu_radio(fps, "1 FPS", "movie_fps", 1.0)
    _menu_radio(fps, "0.3 FPS", "movie_fps", 0.3)
    _sep(fps)
    _menu_toggle(fps, "Show Frame Rate", "show_frame_rate")
    _menu_cmd(fps, "Reset Meter", "meter_reset")

    _sep(menu)
    _menu_toggle(menu, "Auto Interpolate", "movie_auto_interpolate")
    _menu_toggle(menu, "Show Panel", "movie_panel")
    _menu_toggle(menu, "Loop Frames", "movie_loop")
    _menu_toggle(menu, "Draw Frames", "draw_frames")
    _menu_toggle(menu, "Ray Trace Frames", "ray_trace_frames")
    _menu_toggle(menu, "Cache Frame Images", "cache_frames")
    _menu_cmd(menu, "Clear Image Cache", "mclear")
    _sep(menu)
    _menu_toggle(menu, "Static Singletons", "static_singletons")
    _menu_toggle(menu, "Show All States", "all_states")

    item.setSubmenu_(menu)


def _add_display_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Display")
    menu.setAutoenablesItems_(False)

    _menu_toggle(menu, "Sequence", "seq_view")

    # Sequence Mode submenu
    seqmode = _submenu(menu, "Sequence Mode")
    for label, val in [("Residue Codes", 0), ("Residue Names", 1),
                       ("Chain Identifiers", 3), ("Atom Names", 2),
                       ("States", 4)]:
        _menu_radio(seqmode, label, "seq_view_format", val)
    _sep(seqmode)
    for label, val in [("All Residue Numbers", 2), ("Top Sequence Only", 1),
                       ("Object Names Only", 0), ("No Labels", 3)]:
        _menu_radio(seqmode, label, "seq_view_label_mode", val)

    _sep(menu)
    _menu_toggle(menu, "Internal GUI", "internal_gui")
    _menu_toggle(menu, "Internal Prompt", "internal_prompt")

    # Internal Feedback submenu
    fb = _submenu(menu, "Internal Feedback")
    for val in [0, 1, 3, 5]:
        _menu_radio(fb, str(val), "internal_feedback", val)

    _sep(menu)
    _menu_toggle(menu, "Stereo", "stereo")

    # Stereo Mode submenu
    stereo = _submenu(menu, "Stereo Mode")
    for label, cmd_str in [
        ("Anaglyph Stereo", "stereo anaglyph"),
        ("Cross-Eye Stereo", "stereo crosseye"),
        ("Wall-Eye Stereo", "stereo walleye"),
        ("Quad-Buffered Stereo", "stereo quadbuffer"),
    ]:
        _menu_cmd(stereo, label, cmd_str)
    _sep(stereo)
    _menu_cmd(stereo, "Swap Sides", "stereo swap")
    _sep(stereo)
    _menu_cmd(stereo, "Off", "stereo off")

    _sep(menu)

    # Zoom submenu
    zoom = _submenu(menu, "Zoom")
    for ang in [4, 6, 8, 12, 20]:
        _menu_cmd(zoom, f"{ang} Angstrom Sphere", f"zoom center, {ang}, animate=-1")
    _menu_cmd(zoom, "All", "zoom animate=-1")
    _menu_cmd(zoom, "Complete", "zoom animate=-1, complete=1")

    # Clip submenu
    clip = _submenu(menu, "Clip")
    _menu_cmd(clip, "Nothing", "clip atoms, 5, all")
    for slab in [8, 12, 16, 20, 30]:
        _menu_cmd(clip, f"{slab} Angstrom Slab", f"clip slab, {slab}")

    _sep(menu)

    # Background submenu
    bg = _submenu(menu, "Background")
    _menu_toggle(bg, "Opaque", "opaque_background")
    _sep(bg)
    _menu_cmd(bg, "White", "bg_color white")
    _menu_cmd(bg, "Light Grey", "bg_color grey80")
    _menu_cmd(bg, "Grey", "bg_color grey50")
    _menu_cmd(bg, "Black", "bg_color black")

    # Color Space submenu
    cspace = _submenu(menu, "Color Space")
    _menu_cmd(cspace, "CMYK (for publications)", "space cmyk")
    _menu_cmd(cspace, "PyMOL (for video + web)", "space pymol")
    _menu_cmd(cspace, "RGB (default)", "space rgb")

    # Quality submenu
    quality = _submenu(menu, "Quality")
    _menu_cmd(quality, "Maximum Performance", "util.performance(100)")
    _menu_cmd(quality, "Reasonable Performance", "util.performance(66)")
    _menu_cmd(quality, "Reasonable Quality", "util.performance(33)")
    _menu_cmd(quality, "Maximum Quality", "util.performance(0)")

    # Grid submenu
    grid = _submenu(menu, "Grid")
    for label, val in [("By Object", 1), ("By State", 2),
                       ("By Object-State", 3), ("Disable", 0)]:
        _menu_radio(grid, label, "grid_mode", val)

    _sep(menu)
    _menu_toggle(menu, "Orthoscopic View", "orthoscopic")
    _menu_toggle(menu, "Show Valences", "valence")
    _menu_toggle(menu, "Smooth Lines", "line_smooth")
    _menu_toggle(menu, "Depth Cue (Fogging)", "depth_cue")
    _menu_toggle(menu, "Two Sided Lighting", "two_sided_lighting")
    _menu_toggle(menu, "Specular Reflections", "specular")
    _menu_toggle(menu, "Animation", "animation")
    _menu_toggle(menu, "Roving Detail", "roving_detail")

    item.setSubmenu_(menu)


def _add_setting_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Setting")
    menu.setAutoenablesItems_(False)

    # Label submenu
    label_menu = _submenu(menu, "Label")
    label_size = _submenu(label_menu, "Size")
    for val in [10, 14, 18, 24, 36, 48, 72]:
        _menu_radio(label_size, f"{val} Point", "label_size", val)
    _sep(label_size)
    for val in [0.3, 0.5, 1, 2, 4]:
        _menu_radio(label_size, f"{val} Angstrom", "label_size", -val)

    label_font = _submenu(label_menu, "Font")
    for label, val in [
        ("Sans", 5), ("Sans Oblique", 6), ("Sans Bold", 7),
        ("Sans Bold Oblique", 8), ("Serif", 9), ("Serif Oblique", 17),
        ("Serif Bold", 10), ("Serif Bold Oblique", 18),
        ("Mono", 11), ("Mono Oblique", 12), ("Mono Bold", 13),
        ("Mono Bold Oblique", 14), ("Gentium Roman", 15),
        ("Gentium Italic", 16),
    ]:
        _menu_radio(label_font, label, "label_font_id", val)

    _menu_toggle(label_menu, "Show Connectors", "label_connector")

    # Lines & Sticks submenu
    sticks = _submenu(menu, "Lines & Sticks")
    _menu_toggle(sticks, "Ball and Stick", "stick_ball")
    stick_ratio = _submenu(sticks, "Ball and Stick Ratio")
    for label, val in [("1.0", 1.0), ("1.5", 1.5), ("VDW", -1.0)]:
        _menu_radio(stick_ratio, label, "stick_ball_ratio", val)
    _sep(sticks)
    stick_radius = _submenu(sticks, "Stick Radius")
    for val in [0.1, 0.2, 0.25]:
        _menu_radio(stick_radius, str(val), "stick_radius", val)
    line_width = _submenu(sticks, "Line Width")
    for val in [1.0, 1.49, 3.0]:
        _menu_radio(line_width, str(val), "line_width", val)
    _menu_toggle(sticks, "Lines As Cylinders", "line_as_cylinders")

    # Cartoon submenu
    cartoon = _submenu(menu, "Cartoon")
    rings = _submenu(cartoon, "Rings and Bases")
    for label, val in [
        ("Filled Rings (Round Edges)", 1),
        ("Filled Rings (Flat Edges)", 2),
        ("Filled Rings (with Border)", 3),
        ("Spheres", 4),
        ("Base Ladders", 0),
    ]:
        _menu_radio(rings, label, "cartoon_ring_mode", val)
    _sep(rings)
    for label, val in [
        ("Bases and Sugars", 1), ("Bases Only", 2),
        ("Non-protein Rings", 3), ("All Rings", 4),
    ]:
        _menu_radio(rings, label, "cartoon_ring_finder", val)

    _menu_toggle(cartoon, "Side Chain Helper", "cartoon_side_chain_helper")
    _menu_toggle(cartoon, "Round Helices", "cartoon_round_helices")
    _menu_toggle(cartoon, "Fancy Helices", "cartoon_fancy_helices")
    _menu_toggle(cartoon, "Cylindrical Helices", "cartoon_cylindrical_helices")
    _menu_toggle(cartoon, "Flat Sheets", "cartoon_flat_sheets")
    _menu_toggle(cartoon, "Fancy Sheets", "cartoon_fancy_sheets")
    _menu_toggle(cartoon, "Smooth Loops", "cartoon_smooth_loops")
    _menu_toggle(cartoon, "Discrete Colors", "cartoon_discrete_colors")

    sampling = _submenu(cartoon, "Sampling")
    _menu_radio(sampling, "Atom count dependent", "cartoon_sampling", -1)
    for val in [2, 7, 14]:
        _menu_radio(sampling, str(val), "cartoon_sampling", val)

    gap = _submenu(cartoon, "Gap Cutoff")
    for val in [0, 5, 10, 20]:
        _menu_radio(gap, str(val), "cartoon_gap_cutoff", val)

    # Ribbon submenu
    ribbon = _submenu(menu, "Ribbon")
    _menu_toggle(ribbon, "Side Chain Helper", "ribbon_side_chain_helper")
    _menu_toggle(ribbon, "Trace Atoms", "ribbon_trace_atoms")
    _sep(ribbon)
    _menu_radio(ribbon, "As Lines", "ribbon_as_cylinders", 0)
    _menu_radio(ribbon, "As Cylinders", "ribbon_as_cylinders", 1)

    # Surface submenu
    surface = _submenu(menu, "Surface")
    surf_color = _submenu(surface, "Color")
    _menu_radio(surf_color, "White", "surface_color", 0)
    _menu_radio(surf_color, "Gray", "surface_color", 25)
    _menu_radio(surf_color, "Default (Atomic)", "surface_color", -1)
    _sep(surface)
    _menu_radio(surface, "Dot", "surface_type", 1)
    _menu_radio(surface, "Wireframe", "surface_type", 2)
    _menu_radio(surface, "Solid", "surface_type", 0)
    _sep(surface)
    _menu_toggle(surface, "Solvent Accessible", "surface_solvent")
    _menu_toggle(surface, "Smooth Edges", "surface_smooth_edges")
    _menu_toggle(surface, "Edge Proximity", "surface_proximity")

    # Transparency submenu
    trans = _submenu(menu, "Transparency")
    for label, setting in [("Surface", "transparency"),
                           ("Sphere", "sphere_transparency"),
                           ("Cartoon", "cartoon_transparency"),
                           ("Stick", "stick_transparency")]:
        sub = _submenu(trans, label)
        for lab, val in [("Off", 0.0), ("20%", 0.2), ("40%", 0.4),
                         ("50%", 0.5), ("60%", 0.6), ("80%", 0.8)]:
            _menu_radio(sub, lab, setting, val)

    # Rendering submenu
    rendering = _submenu(menu, "Rendering")
    _menu_toggle(rendering, "OpenGL 2.0 Shaders", "use_shaders")
    _sep(rendering)
    _menu_toggle(rendering, "Antialias (Ray Tracing)", "antialias")
    aa = _submenu(rendering, "Antialias (Real Time)")
    for label, val in [("Off", 0), ("FXAA", 1), ("SMAA", 2)]:
        _menu_radio(aa, label, "antialias_shader", val)
    _sep(rendering)
    shadows = _submenu(rendering, "Shadows")
    for val in ["none", "light", "medium", "heavy", "black"]:
        _menu_cmd(shadows, val.title(), f"util.ray_shadows('{val}')")
    _sep(shadows)
    for val in ["matte", "soft", "occlusion", "occlusion2"]:
        _menu_cmd(shadows, val.title(), f"util.ray_shadows('{val}')")

    _sep(rendering)
    _menu_toggle(rendering, "Cull Backfaces", "backface_cull")

    _sep(menu)

    # PDB File Loading submenu
    pdb_load = _submenu(menu, "PDB File Loading")
    _menu_toggle(pdb_load, "Ignore PDB Segment Identifier", "ignore_pdb_segi")

    # mmCIF File Loading submenu
    cif_load = _submenu(menu, "mmCIF File Loading")
    _menu_toggle(cif_load, "Use \"auth\" Identifiers", "cif_use_auth")

    _sep(menu)

    # Auto-Show submenu
    autoshow = _submenu(menu, "Auto-Show ...")
    _menu_toggle(autoshow, "Cartoon/Sticks/Spheres by Classification",
                 "auto_show_classified")
    _sep(autoshow)
    _menu_toggle(autoshow, "Auto-Show Lines", "auto_show_lines")
    _menu_toggle(autoshow, "Auto-Show Spheres", "auto_show_spheres")
    _menu_toggle(autoshow, "Auto-Show Nonbonded", "auto_show_nonbonded")
    _sep(autoshow)
    _menu_toggle(autoshow, "Auto-Show New Selections", "auto_show_selections")
    _menu_toggle(autoshow, "Auto-Hide Selections", "auto_hide_selections")

    _menu_toggle(menu, "Auto-Zoom New Objects", "auto_zoom")
    _menu_toggle(menu, "Auto-Remove Hydrogens", "auto_remove_hydrogens")
    _sep(menu)
    _menu_toggle(menu, "Show Text (Esc)", "text")
    _menu_toggle(menu, "Overlay Text", "overlay")

    item.setSubmenu_(menu)


def _add_scene_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Scene")
    menu.setAutoenablesItems_(False)

    _menu_cmd(menu, "Next", "scene '', next")
    _menu_cmd(menu, "Previous", "scene '', previous")
    _sep(menu)
    _menu_cmd(menu, "Append", "scene new, store")

    # Append... submenu
    append = _submenu(menu, "Append...")
    _menu_cmd(append, "Camera", "scene new, store, color=0, rep=0")
    _menu_cmd(append, "Color", "scene new, store, view=0, rep=0")
    _menu_cmd(append, "Reps", "scene new, store, view=0, color=0")
    _menu_cmd(append, "Reps + Color", "scene new, store, view=0")

    _menu_cmd(menu, "Insert Before", "scene '', insert_before")
    _menu_cmd(menu, "Insert After", "scene '', insert_after")
    _menu_cmd(menu, "Update", "scene auto, update")
    _sep(menu)
    _menu_cmd(menu, "Delete", "scene auto, clear")
    _sep(menu)

    # Recall / Store / Clear F-key submenus
    for label, action in [("Recall", "recall"), ("Store", "store"),
                          ("Clear", "clear")]:
        sub = _submenu(menu, label)
        for i in range(1, 13):
            _menu_cmd(sub, f"F{i}", f"scene F{i}, {action}")

    _sep(menu)
    _menu_toggle(menu, "Buttons", "scene_buttons")

    # Cache submenu
    cache = _submenu(menu, "Cache")
    _menu_cmd(cache, "Enable", "cache enable")
    _menu_cmd(cache, "Optimize", "cache optimize")
    _menu_cmd(cache, "Read Only", "cache read_only")
    _menu_cmd(cache, "Disable", "cache disable")

    item.setSubmenu_(menu)


def _add_mouse_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Mouse")
    menu.setAutoenablesItems_(False)

    # Selection Mode submenu
    sel = _submenu(menu, "Selection Mode")
    for label, val in [("Atoms", 0), ("Residues", 1), ("Chains", 2),
                       ("Segments", 3), ("Objects", 4), ("Molecules", 5),
                       ("C-alphas", 6)]:
        _menu_radio(sel, label, "mouse_selection_mode", val)

    _sep(menu)
    _menu_cmd(menu, "3 Button Motions", "config_mouse three_button_motions")
    _menu_cmd(menu, "3 Button Editing", "config_mouse three_button_editing")
    _menu_cmd(menu, "3 Button Viewing", "mouse three_button_viewing")
    _menu_cmd(menu, "3 Button Lights", "mouse three_button_lights")
    _menu_cmd(menu, "3 Button All Modes", "config_mouse three_button_all_modes")
    _menu_cmd(menu, "2 Button Editing", "config_mouse two_button_editing")
    _menu_cmd(menu, "2 Button Viewing", "config_mouse two_button")
    _menu_cmd(menu, "1 Button Viewing Mode", "mouse one_button_viewing")
    _menu_cmd(menu, "Emulate Maestro", "mouse three_button_maestro")
    _sep(menu)
    _menu_toggle(menu, "Virtual Trackball", "virtual_trackball")
    _menu_toggle(menu, "Show Mouse Grid", "mouse_grid")
    _menu_toggle(menu, "Roving Origin", "roving_origin")

    item.setSubmenu_(menu)


def _add_wizard_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Wizard")
    menu.setAutoenablesItems_(False)

    _menu_cmd(menu, "Appearance", "wizard appearance")
    _menu_cmd(menu, "Measurement", "wizard measurement")

    # Mutagenesis submenu
    mut = _submenu(menu, "Mutagenesis")
    _menu_cmd(mut, "Protein", "wizard mutagenesis")
    _menu_cmd(mut, "Nucleic Acids", "wizard nucmutagenesis")

    _menu_cmd(menu, "Pair Fitting", "wizard pair_fit")
    _sep(menu)
    _menu_cmd(menu, "Density", "wizard density")
    _menu_cmd(menu, "Filter", "wizard filter")
    _menu_cmd(menu, "Sculpting", "wizard sculpting")
    _sep(menu)
    _menu_cmd(menu, "Label", "wizard label")
    _menu_cmd(menu, "Charge", "wizard charge")
    _sep(menu)

    # Demo submenu
    demo = _submenu(menu, "Demo")
    for label, code in [
        ("Representations", "reps"), ("Cartoon Ribbons", "cartoon"),
        ("Roving Detail", "roving"), ("Roving Density", "roving_density"),
        ("Transparency", "trans"), ("Ray Tracing", "ray"),
        ("Sculpting", "sculpt"), ("Scripted Animation", "anime"),
        ("Electrostatics", "elec"), ("Compiled Graphics Objects", "cgo"),
        ("Molscript/Raster3D Input", "raster3d"),
    ]:
        _menu_cmd(demo, label, f"wizard demo, {code}")
    _sep(demo)
    _menu_cmd(demo, "End Demonstration", "replace_wizard demo, finish")

    item.setSubmenu_(menu)


def _add_help_menu(menubar):
    item = AppKit.NSMenuItem.alloc().init()
    menubar.addItem_(item)
    menu = AppKit.NSMenu.alloc().initWithTitle_("Help")
    menu.setAutoenablesItems_(False)

    _menu_url(menu, "PyMOL Home Page", "http://www.pymol.org")
    _menu_url(menu, "PyMOL Product Page",
              "https://www.schrodinger.com/platform/products/pymol/")
    _menu_url(menu, "PyMOL Community Wiki", "http://www.pymolwiki.org")
    _sep(menu)
    _menu_url(menu, "PyMOL Command Reference",
              "http://pymol.org/pymol-command-ref.html")
    _menu_url(menu, "PyMOL 3 Documentation",
              "https://learn.schrodinger.com/public/pymol/current/Content/pymol/pymol_home.htm")
    _sep(menu)

    # Topics submenu
    topics = _submenu(menu, "Topics")
    _menu_url(topics, "Selection Algebra",
              "https://pymolwiki.org/index.php/Selection_Algebra")
    _menu_url(topics, "Settings",
              "https://pymolwiki.org/index.php/Settings")
    _menu_url(topics, "Timeline Python API",
              "https://pymolwiki.org/index.php/Timeline_Python_API")

    _sep(menu)
    _menu_url(menu, "PyMOL Mailing List",
              "https://lists.sourceforge.net/lists/listinfo/pymol-users")
    _sep(menu)
    _menu_url(menu, "How to Cite PyMOL", "http://pymol.org/citing")
    _menu_url(menu, "Sponsorship Information",
              "http://pymol.org/funding.html")

    item.setSubmenu_(menu)


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

def setup_menus(cmd_module):
    """Build and install the full PyMOL menu bar.

    Called from main_appkit.mm after PyMOL and Python are initialised.
    """
    global _cmd
    _cmd = cmd_module

    menubar = AppKit.NSApp.mainMenu()
    if menubar is None:
        menubar = AppKit.NSMenu.alloc().init()
        AppKit.NSApp.setMainMenu_(menubar)

    # Keep app menu (index 0), remove everything else
    while menubar.numberOfItems() > 1:
        menubar.removeItemAtIndex_(1)

    _add_file_menu(menubar)
    _add_edit_menu(menubar)
    _add_build_menu(menubar)
    _add_movie_menu(menubar)
    _add_display_menu(menubar)
    _add_setting_menu(menubar)
    _add_scene_menu(menubar)
    _add_mouse_menu(menubar)
    _add_wizard_menu(menubar)
    _add_help_menu(menubar)
