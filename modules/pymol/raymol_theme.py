"""RayMol theme engine helper.

Holds the active palette (chain cycle + non-carbon element colors + default
style + render toggles), applies the immediate scene-wide bits (bg_color,
metal_outline), and themes NEW objects at load time via apply_to(). Existing
objects are never restyled/recolored on a theme change.
"""
from pymol import cmd

# Active palette globals (defaults match the SwiftUI Midnight preset).
_chain_cycle = []          # list of (r,g,b)
_element_colors = {}       # {"N": (r,g,b), ...}  (carbon intentionally absent)
_default_style = "cartoon"
_flat_sheets = False
_fancy_helices = False

_CHAIN_PREFIX = "raymol_chain_"
_ELEM_PREFIX = "raymol_elem_"


def _hex(rgb):
    return "0x%02x%02x%02x" % (int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))


def set_palette(bg=None, outline=False, flat_sheets=False, fancy_helices=False,
                ray_trace=False, shadows=True,
                default_style="cartoon", chain_cycle=None, element_colors=None,
                apply_render_toggles=True):
    """Store the active palette and apply the immediate scene-wide settings.

    Called by Swift (PyMOLEngine.applyTheme) on every theme change. Defines
    named colors for the chain cycle and non-carbon elements so apply_to() can
    reference them. Does NOT touch existing objects.

    `apply_render_toggles` gates the three render-state settings
    (metal_outline / metal_raytrace / metal_shadows). These are scene state that
    a loaded/restored .pse OWNS, so the passive launch-time theme re-assertion
    passes False to avoid clobbering the just-restored session (see
    ContentView.applyPersistedTheme). Explicit theme changes and fresh/empty
    launches pass True (the default) so the theme establishes them. Chrome
    (bg_color + palette colors) is applied unconditionally either way.
    """
    global _chain_cycle, _element_colors, _default_style, _flat_sheets, _fancy_helices
    _default_style = default_style or "cartoon"
    _flat_sheets = bool(flat_sheets)
    _fancy_helices = bool(fancy_helices)

    if bg is not None:
        cmd.bg_color(_hex(bg))
    # Outline is OFF in every theme (product decision, RayMol 1.6.1). Force it off
    # UNCONDITIONALLY on every theme apply — OUTSIDE the apply_render_toggles gate
    # — so it's off even on a restored/opened session (when render toggles are
    # otherwise suppressed) and regardless of a stale compiled core default or a
    # pre-1.6.1 cached theme. set_palette runs on every launch, so this is the
    # reliable place to enforce it. `outline` is kept only for signature/back-compat.
    cmd.set("metal_outline", 0)
    if apply_render_toggles:
        cmd.set("metal_raytrace", 1 if ray_trace else 0)
        cmd.set("metal_shadows", 1 if shadows else 0)

    _chain_cycle = list(chain_cycle or [])
    for i, rgb in enumerate(_chain_cycle):
        cmd.set_color("%s%d" % (_CHAIN_PREFIX, i), list(rgb))

    _element_colors = dict(element_colors or {})
    for elem, rgb in _element_colors.items():
        cmd.set_color("%s%s" % (_ELEM_PREFIX, elem.upper()), list(rgb))


def cbc(selection="(all)"):
    """Color by chain using the active palette's chain cycle.

    Cycles raymol_chain_<i> over the chains present in `selection`. Falls back
    to PyMOL's util.cbc when no palette is set.
    """
    if not _chain_cycle:
        from pymol import util
        util.cbc(selection=selection)
        return
    chains = cmd.get_chains(selection)
    if not chains:
        # No explicit chains — color the whole selection with the first swatch.
        cmd.color("%s0" % _CHAIN_PREFIX, selection)
        return
    for i, ch in enumerate(chains):
        color = "%s%d" % (_CHAIN_PREFIX, i % len(_chain_cycle))
        sel = "(%s) and chain %s" % (selection, ch) if ch else "(%s)" % selection
        cmd.color(color, sel)


def cnc(selection="(all)"):
    """Color non-carbon atoms by the active element palette; carbon untouched."""
    if not _element_colors:
        from pymol import util
        util.cnc(selection=selection)
        return
    for elem in _element_colors:
        cmd.color("%s%s" % (_ELEM_PREFIX, elem.upper()),
                  "(%s) and elem %s" % (selection, elem))


def apply_default_style(obj):
    """Apply the active default representation + cartoon settings to `obj`."""
    style = _default_style
    cmd.set("cartoon_flat_sheets", 1 if _flat_sheets else 0, obj)
    cmd.set("cartoon_fancy_helices", 1 if _fancy_helices else 0, obj)
    if style == "cartoon":
        cmd.hide("everything", obj); cmd.show("cartoon", obj)
    elif style == "sticks":
        cmd.hide("everything", obj); cmd.show("sticks", obj)
    elif style == "spheres":
        cmd.hide("everything", obj); cmd.show("spheres", obj)
    elif style == "ball_stick":
        cmd.hide("everything", obj); cmd.show("sticks", obj); cmd.show("spheres", obj)
        cmd.set("sphere_scale", 0.25, obj); cmd.set("stick_radius", 0.14, obj)
    elif style == "surface":
        cmd.show("surface", obj)
    elif style == "pretty":
        cmd.hide("everything", obj); cmd.show("cartoon", obj)


def apply_to(obj):
    """Theme a NEWLY loaded object: default style + themed chain/element colors."""
    try:
        apply_default_style(obj)
        cbc("(%s)" % obj)
        cnc("(%s)" % obj)
    except Exception as e:
        print("raymol_theme.apply_to(%r) failed: %s" % (obj, e))
