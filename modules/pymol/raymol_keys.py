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
    'CTRL-M': 'Move Objects (Tools menu)',
    'CTRL-E': 'Measure Distances (Tools menu)',
    'CTRL-S': 'Box Select (Tools menu)',
    'CTRL-D': 'Enter/Exit Design Mode (Tools menu)',
    'CTRL-P': 'Enter/Exit Predict Mode (Tools menu)',
    'CTRL-B': 'Binder Design (Tools menu)',
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


# ---------------------------------------------------------------------------
# Key dispatch (RayMol#260)
#
# Upstream cmd._special does two things when a special key is pressed: fire the
# cmd.set_key binding if there is one, and otherwise recall the scene or view
# NAMED after the key. That second step is what makes the F-key scene workflow
# work on desktop PyMOL: CTRL-F1 stores "scene F1" (a real default binding), and
# a bare F1 recalls it (no binding -- the fallthrough does it).
#
# RayMol cannot call _special, because PyMOL_Special also grabs the arrow keys
# for the core's hidden Ortho prompt, which RayMol does not use. So invoke()
# mirrors just the binding + scene/view part.

# Special-key names that may fall back to a scene or view of the same name.
# The arrows are excluded on purpose: left/right are movie-frame bindings by
# default (so they never reach the fallback anyway), and a fallback here would
# bring back the arrow-grabbing we deliberately bypass _special to avoid.
_ARROW_KEYS = frozenset(('left', 'right', 'up', 'down'))
_FALLBACK_KEYS = frozenset(
    ['F%d' % n for n in range(1, 13)]
    + ['pgup', 'pgdn', 'home', 'end', 'insert'])


def invoke(token, _self=None, _invoke_key=None):
    '''
    Fire the cmd.set_key binding for a canonical key token; for a bare
    special-key name with no binding, recall the scene or view of that name.

    Returns True iff something fired, which is the contract the key monitor
    depends on: it consumes the event only when this returns True, so an unbound
    key still falls through to the macOS menus.

    Exceptions from a bound callable or from scene/view recall propagate to the
    caller (the bridge prints the traceback and still counts the key as fired).
    '''
    if _self is None:
        from pymol import cmd as _self
    if _invoke_key is None:
        from pymol import internal
        _invoke_key = internal._invoke_key

    if _invoke_key(token, 1, _self):
        return True

    if token in _ARROW_KEYS or token not in _FALLBACK_KEYS:
        return False

    from pymol.shortcut import Shortcut

    # Same order and same Shortcut-based interpretation as cmd._special: scenes
    # first, then views; an exact name wins, else a unique "<key>-..." prefix
    # (so a scene named "F1-intro" answers to F1).
    view_sc = getattr(getattr(_self, '_pymol', None), '_view_dict_sc', None)
    for fn, sc in (
            (_self.scene, Shortcut(_self.get_scene_list())),
            (_self.view, view_sc),
    ):
        if sc is None:
            continue
        if token in sc.keywords:
            fn(token)
            return True
        autocomp = sc.interpret(token + '-')
        if isinstance(autocomp, str):
            fn(autocomp)
            return True

    return False
