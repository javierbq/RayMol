# raymol_keys.py
#
# RayMol delivers cmd.set_key bindings via an NSEvent monitor that consumes a
# key event only when a binding actually fired (RayMol#258). That rule gives the
# user's ~/.raymolrc the last word for free — but it also means a binding can
# quietly take over a key the app itself uses as a menu shortcut, and the user
# would just see the menu item stop responding to its key.
#
# This module names that collision out loud, once, right after ~/.raymolrc runs.
#
# Only the CTRL-letter keys can collide: every other RayMol menu shortcut
# carries ⌘, and the Swift classifier passes ⌘ events straight through to the
# menus.

# Canonical key token -> the menu command it would shadow.
#
# Mirrors the ⌃-letter entries of AppShortcuts in
# swiftui/PyMOLViewer/Shared/PyMOLApp.swift — a new ⌃ shortcut there must be
# added here too (AppShortcutsTests pins the set on the Swift side).
APP_SHORTCUTS = {
    'CTRL-M': 'Move Objects (Mouse menu)',
    'CTRL-E': 'Measure Distances (Mouse menu)',
    'CTRL-B': 'Box Select (Mouse menu)',
    'CTRL-D': 'Enter/Exit Design Mode (Design menu)',
    'CTRL-P': 'Enter/Exit Predict Mode (Predict menu)',
}

# CTRL-D only exists in RAYMOL_MPNN builds, so the caller says whether the
# Design menu is present rather than this module guessing.
_DESIGN_ONLY = ('CTRL-D',)


def audit_shadowed(has_design=False, _self=None):
    '''
    Print one warning per user binding that shadows a RayMol menu shortcut.

    Returns the list of lines printed, so callers and tests can inspect the
    result. Never raises: this runs on the launch path, and a broken audit must
    not take the app's startup with it.
    '''
    try:
        if _self is None:
            from pymol import cmd as _self

        mappings = getattr(_self, 'key_mappings', None)
        if not isinstance(mappings, dict):
            return []

        lines = []
        for key, label in sorted(APP_SHORTCUTS.items()):
            if key in _DESIGN_ONLY and not has_design:
                continue
            # An empty mapping is how set_key(key, '') CLEARS a binding.
            if not mappings.get(key):
                continue
            line = (" RayMol: %s is bound by your startup script; it now"
                    " overrides the \"%s\" shortcut (the menu item still works"
                    " by click)." % (key, label))
            print(line)
            lines.append(line)
        return lines
    except Exception as e:
        # The docstring's promise, kept: this runs on the launch path, so a bug
        # here must degrade to "no warning" rather than break startup — including
        # when the reporting print is itself what fails (closed or custom stdout).
        try:
            print(' Warning: RayMol shortcut audit failed: %s' % (e,))
        except Exception:
            pass
        return []
