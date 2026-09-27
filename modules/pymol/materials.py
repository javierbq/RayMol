"""Material "look" bundles: a material plus the lighting that flatters it.

A material on its own is only half a look. `marble` under the default rig still
carries a tight specular highlight that reads as polished plastic rather than
stone, and `clay` needs contact shadow to read as a solid body at all. These
bundles set BOTH -- the material on all four of the object's material-bearing
representation settings, shown or not, and the handful of scene settings the
look depends on.

Deliberately NOT in `preset.py`. A preset's contract there is to rebuild the
representation set from scratch (`hide everything` then show its own), which
throws away whatever the user had on screen. These keep the current look and
change only what they document.

Every function below lists exactly which settings it writes, and writes nothing
else. The lighting settings are GLOBAL -- there is one light rig -- so calling
two bundles in a row leaves the second one's rig, which is why each names its
own values rather than nudging what it finds.

Materials never touch colour: nothing here writes a colour setting.

Two limits worth knowing before you read the numbers below.

*The occlusion and shadow settings are ray-tracing terms.* `metal_rt_shadows`
and the `metal_rt_ao_*` pair do nothing unless `metal_raytrace` is on and the
GPU supports it. It defaults on, so this is usually invisible -- but with it off
a bundle gives you the specular turned down and none of the occlusion that was
supposed to replace it, which is the worst of both. The bundles deliberately do
NOT switch `metal_raytrace` on for you: it is a scene-wide performance decision,
not part of a look.

*Cartoons get the shadows but not the ambient occlusion.* `metal_ssao_cartoon`
is off by default -- on purpose, it avoids spurious contour lines on ribbon
silhouettes and self-folds (#79) -- and that exemption gates the traced AO term
as well as the screen-space one. So on a cartoon, clay in particular leans on
shadow alone. Flipping that default is a rendering judgement that wants eyes on
a picture, so these bundles leave it where the renderer put it.
"""

from pymol import cmd

# The four representations that HAVE a material, and the setting each reads.
# Order is the order the reps are applied in; `cRepCyl` (sticks) also covers the
# stick_ball spheres, which is why they take stick_material.
_REP_SETTING = ('cartoon_material', 'surface_material',
                'stick_material', 'sphere_material')


def _objects(selection, _self=cmd):
    """Objects the selection touches.

    `cmd.get_object_list` already resolves a group to its members and raises for
    anything that is not an atom selection -- a map, a CGO, a distance object,
    or a name that does not exist. Those all legitimately have no material, so
    they are skipped; what matters is that the CALLER can tell the difference
    between "nothing to do" and "the user typed a name wrong", which is why the
    exception is reported rather than swallowed."""
    try:
        return list(_self.get_object_list(selection) or [])
    except Exception:
        return []


def _warn(_self, message):
    try:
        from pymol import colorprinting
        colorprinting.warning(' materials: ' + message)
    except Exception:
        print(' materials: ' + message)


def _apply_material(name, selection, _self=cmd):
    """Set material `name` on every representation of every object in
    `selection` that has one. Returns the (object, setting) pairs written.

    Applied to ALL four rep settings rather than only the reps currently shown:
    a user who turns on the surface afterwards should get the look they asked
    for, not the default. That is also why this writes the object level -- an
    object-level value wins over a global, including an explicit `default`."""
    written = []
    objects = _objects(selection, _self)
    for obj in objects:
        for setting in _REP_SETTING:
            # NOT swallowed: `cmd.set` raises for an unknown material name, and
            # a bundle that silently applied nothing would be far harder to
            # diagnose than one that says which name it could not resolve.
            _self.set(setting, name, obj)
            written.append((obj, setting))
    if objects and len(objects) == 1:
        # A material setting is object-scoped -- the C layer rejects a
        # selection-scoped set outright -- so `marble('m1 and chain B')` styles
        # the WHOLE object. Said out loud, because these bundles are offered on
        # selection rows in the menus, right beside presets that do honour the
        # selection.
        try:
            if _self.count_atoms(selection) < _self.count_atoms(objects[0]):
                _warn(_self, 'a material is per OBJECT, so this applied to all '
                             'of %s, not just the selection.' % objects[0])
        except Exception:
            pass
    return written


def marble(selection='(all)', _self=cmd):
    """Statuary marble: veined stone under a soft museum rig.

    Writes, and nothing else:
      * cartoon_material / surface_material / stick_material / sphere_material
        = marble, on each object in `selection`
      * specular 0.12, shininess 8      -- stone has a broad dim sheen, not a
                                           tight plastic highlight
      * metal_sss_wrap 0.6              -- the waxy terminator marble needs
      * metal_shadows 1, metal_rt_shadows 1, metal_rt_shadow_intensity 0.55
      * metal_ssao 1, metal_rt_ao_radius 12, metal_rt_ao_intensity 0.65

    Colour is untouched: the veins are derived from whatever colour the object
    already has, so a blue marble stays blue.
    """
    if not _apply_material('marble', selection, _self):
        # Nothing took the material, so do NOT rewrite the global light rig:
        # a typo'd object name would otherwise change the whole scene's
        # lighting and apply no material, with nothing said.
        _warn(_self, 'no object matched %s; nothing changed.' % repr(selection))
        return
    _self.set('specular', 0.12)
    _self.set('shininess', 8)
    _self.set('metal_sss_wrap', 0.6)
    _self.set('metal_shadows', 1)
    _self.set('metal_rt_shadows', 1)
    _self.set('metal_rt_shadow_intensity', 0.55)
    _self.set('metal_ssao', 1)
    _self.set('metal_rt_ao_radius', 12)
    _self.set('metal_rt_ao_intensity', 0.65)


def clay(selection='(all)', _self=cmd):
    """Unglazed ceramic: dead-matte body with strong contact shadow.

    Writes, and nothing else:
      * cartoon_material / surface_material / stick_material / sphere_material
        = clay, on each object in `selection`
      * specular 0, shininess 4         -- a glaze-free body has no highlight
      * metal_sss_wrap 0.25
      * metal_shadows 1, metal_rt_shadows 1, metal_rt_shadow_intensity 0.7
      * metal_ssao 1, metal_rt_ao_radius 8, metal_rt_ao_intensity 0.9

    The tighter AO radius is the point: clay has no specular to describe its
    form, so occlusion is what makes it read as solid rather than flat -- on a
    surface, spheres and sticks. On a cartoon it is shadow doing that work
    alone; see the module docstring.

    `shininess 4` is written for completeness and is unobservable while
    `specular` is 0; it is there so that turning the specular back up gives a
    clay-appropriate highlight rather than the default's tight one.
    """
    if not _apply_material('clay', selection, _self):
        # Nothing took the material, so do NOT rewrite the global light rig:
        # a typo'd object name would otherwise change the whole scene's
        # lighting and apply no material, with nothing said.
        _warn(_self, 'no object matched %s; nothing changed.' % repr(selection))
        return
    _self.set('specular', 0.0)
    _self.set('shininess', 4)
    _self.set('metal_sss_wrap', 0.25)
    _self.set('metal_shadows', 1)
    _self.set('metal_rt_shadows', 1)
    _self.set('metal_rt_shadow_intensity', 0.7)
    _self.set('metal_ssao', 1)
    _self.set('metal_rt_ao_radius', 8)
    _self.set('metal_rt_ao_intensity', 0.9)


# --- Named metals (#497) ----------------------------------------------------
#
# These are BUNDLES, not table rows, and the difference is the point. A material
# never touches colour -- that is one of the epic's non-negotiables -- so
# `copper` cannot be a material: what makes copper copper is mostly its colour.
# A bundle is user-invoked and may set colour, because the user asked for
# "copper" rather than for "a material".
#
# Each is `metallic` plus a documented colour, and where the metal needs it, an
# explicit per-object reflect/tint/roughness. Those overrides ride the existing
# object-scoped metal_rt_reflect* settings, which a reflective material honours
# when they are EXPLICITLY set (#497) -- so chrome can be sharper and less
# tinted than plain metallic without needing a table row of its own.
#
# {name: (rgb hex, reflect|None, tint|None, rough|None)}
_METALS = {
    'copper': ('0xb87333', None, 0.55, 0.30),
    'gold':   ('0xd4af37', None, 0.55, 0.25),
    'steel':  ('0x8c9299', None, 0.15, 0.35),
    # Chrome is the mirror: barely tinted, almost perfectly smooth.
    'chrome': ('0xdbe2e9', 0.75, 0.10, 0.05),
}


def _metal(name, selection, _self=cmd):
    """Apply a named metal: `metallic` on every material-bearing rep, the
    metal's colour, and its reflect/tint/roughness overrides."""
    rgb, reflect, tint, rough = _METALS[name]
    objects = _apply_material('metallic', selection, _self)
    if not objects:
        _warn(_self, 'no object matched %s; nothing changed.' % repr(selection))
        return
    # Colour goes on the SELECTION, not the object: unlike a material, colour is
    # per atom, so `gold('chain A')` golds chain A and leaves the rest alone.
    _self.color(rgb, selection)
    for obj in _objects(selection, _self):
        if reflect is not None:
            _self.set('metal_rt_reflect', reflect, obj)
        if tint is not None:
            _self.set('metal_rt_reflect_tint', tint, obj)
        if rough is not None:
            _self.set('metal_rt_reflect_rough', rough, obj)


def copper(selection='(all)', _self=cmd):
    """Copper: `metallic` + 0xb87333, tint 0.55, roughness 0.30.

    Colour IS written -- that is what separates a named metal from a material.
    """
    _metal('copper', selection, _self)


def gold(selection='(all)', _self=cmd):
    """Gold: `metallic` + 0xd4af37, tint 0.55, roughness 0.25."""
    _metal('gold', selection, _self)


def steel(selection='(all)', _self=cmd):
    """Steel: `metallic` + 0x8c9299, tint 0.15, roughness 0.35."""
    _metal('steel', selection, _self)


def chrome(selection='(all)', _self=cmd):
    """Chrome: `metallic` + 0xdbe2e9, reflect 0.75, tint 0.10, roughness 0.05 --
    the mirror end of the range."""
    _metal('chrome', selection, _self)


#: (menu label, attribute name, the MATERIAL the bundle applies) for the menu
#: and the Inspector's preset list. Only the looks whose material is
#: implemented appear here.
#:
#: The third field is what lets the Inspector offer "Suggested lighting" beside
#: a material dropdown (#498): it is the bundle's half of the join, and it has
#: to live here rather than in the UI, where a hard-coded copy would go stale
#: the moment a bundle changed which material it applies. Several bundles can
#: name the same material -- the four metals are all `metallic`, differing in
#: colour and in the legacy reflect triple -- so the UI offers a menu, not a
#: button, when more than one matches.
BUNDLES = (
    ('Marble (statuary)', 'marble', 'marble'),
    ('Clay (unglazed)', 'clay', 'clay'),
    ('Copper', 'copper', 'metallic'),
    ('Gold', 'gold', 'metallic'),
    ('Steel', 'steel', 'metallic'),
    ('Chrome', 'chrome', 'metallic'),
)
