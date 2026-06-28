"""Theme-studio live preview.

While the RayMol Theme studio is open, the current scene is momentarily replaced
by a small bundled example molecule (cartoon + sidechain sticks) so the user can
see the impact of theme color/style/render changes on a real structure. The full
prior session (objects, reps, colors, selections, settings, camera) is captured
in memory via cmd.get_session and restored exactly via cmd.set_session when the
studio closes. Existing objects are never restyled — only hidden during preview.
"""
from pymol import cmd

_saved = None              # full session dict captured at begin()
OBJ = "__theme_preview"     # reserved name for the example object


def begin(path):
    """Snapshot the current session, then show only the example molecule.

    Guarded so a second begin() (e.g. studio re-opened without a restore) does
    not overwrite the real snapshot with the preview scene.
    """
    global _saved
    try:
        if _saved is None:
            _saved = cmd.get_session(partial=0, quiet=1)
    except Exception as e:
        _saved = None
        print("THEMEPREVIEW_ERR:snapshot:" + str(e))
    # Never mutate the scene unless we hold a valid snapshot to restore from. If
    # get_session failed (and we have no prior snapshot), bailing here keeps the
    # user's real scene intact — otherwise disable("all") below would hide it with
    # no way back (restore() with _saved is None only deletes the preview object).
    if _saved is None:
        print("THEMEPREVIEW_ERR:begin:no snapshot, scene left untouched")
        return
    try:
        cmd.delete(OBJ)
        cmd.load(path, OBJ)
        if cmd.count_atoms(OBJ) == 0:
            # File load produced nothing — fall back to a built peptide (offline,
            # uses bundled chempy fragment pkls).
            cmd.delete(OBJ)
            cmd.fab("ACDEFGHIKLMNPQRSTVWY", OBJ, ss=1)
        # Show only the example.
        cmd.disable("all")
        cmd.enable(OBJ)
        style()
        cmd.orient(OBJ)
        print("THEMEPREVIEW:begin")
    except Exception as e:
        print("THEMEPREVIEW_ERR:begin:" + str(e))


def style():
    """Fixed cartoon + sidechain-sticks rep on the example, themed by the active
    palette (chain/element colors + cartoon flat-sheets/fancy-helices). bg_color
    and metal_outline are applied globally by raymol_theme.set_palette, so they
    already reflect the live edit. Re-run on every theme edit while open."""
    try:
        from pymol import raymol_theme as _rt
        cmd.hide("everything", OBJ)
        cmd.show("cartoon", OBJ)
        cmd.show("sticks", "(%s and (sidechain or name CA) and not hydro)" % OBJ)
        # CA shared cleanly between cartoon trace and sidechain stick.
        cmd.set("cartoon_side_chain_helper", 1, OBJ)
        cmd.set("cartoon_flat_sheets", 1 if _rt._flat_sheets else 0, OBJ)
        cmd.set("cartoon_fancy_helices", 1 if _rt._fancy_helices else 0, OBJ)
        _rt.cbc("(%s)" % OBJ)
        _rt.cnc("(%s)" % OBJ)
    except Exception as e:
        print("THEMEPREVIEW_ERR:style:" + str(e))


def restore():
    """Delete the example and restore the captured session exactly (camera
    included). An empty snapshot restores to an empty scene."""
    global _saved
    try:
        cmd.delete(OBJ)
        if _saved is not None:
            cmd.set_session(_saved, partial=0, quiet=1)
            _saved = None
        print("THEMEPREVIEW:restore")
    except Exception as e:
        _saved = None
        print("THEMEPREVIEW_ERR:restore:" + str(e))
