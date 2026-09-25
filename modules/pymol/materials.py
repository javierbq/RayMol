"""Material "look" bundles: a material plus the lighting that flatters it.

A material on its own is only half a look. `marble` under the default rig still
carries a tight specular highlight that reads as polished plastic rather than
stone, and `clay` needs contact shadow to read as a solid body at all. These
bundles set BOTH -- the material on the object's active representations, and the
handful of scene settings the look depends on.

Deliberately NOT in `preset.py`. A preset's contract there is to rebuild the
representation set from scratch (`hide everything` then show its own), which
throws away whatever the user had on screen. These keep the current look and
change only what they document.

Every function below lists exactly which settings it writes, and writes nothing
else. The lighting settings are GLOBAL -- there is one light rig -- so calling
two bundles in a row leaves the second one's rig, which is why each names its
own values rather than nudging what it finds.

Materials never touch colour: nothing here writes a colour setting.
"""

from pymol import cmd

# The four representations that HAVE a material, and the setting each reads.
# Order is the order the reps are applied in; `cRepCyl` (sticks) also covers the
# stick_ball spheres, which is why they take stick_material.
_REP_SETTING = (
    ('cartoon', 'cartoon_material'),
    ('surface', 'surface_material'),
    ('sticks',  'stick_material'),
    ('spheres', 'sphere_material'),
)


def _objects(selection, _self=cmd):
    """Object names the selection touches, without groups.

    `cmd.set` expands a group to its members, so setting on the group as well
    would write every member twice -- harmless but confusing in the log, and it
    makes the "writes nothing else" promise harder to check."""
    try:
        names = _self.get_object_list(selection)
    except Exception:
        return []
    out = []
    for n in names or []:
        try:
            if _self.get_type(n) == 'object:group':
                continue
        except Exception:
            pass
        out.append(n)
    return out


def _apply_material(name, selection, _self=cmd):
    """Set material `name` on every representation of every object in
    `selection` that has one. Returns the (object, setting) pairs written.

    Applied to ALL four rep settings rather than only the reps currently shown:
    a user who turns on the surface afterwards should get the look they asked
    for, not the default. That is also why this writes the object level -- an
    object-level value wins over a global, including an explicit `default`."""
    written = []
    for obj in _objects(selection, _self):
        for _rep, setting in _REP_SETTING:
            try:
                _self.set(setting, name, obj)
                written.append((obj, setting))
            except Exception:
                pass    # setting absent in this build
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
    _apply_material('marble', selection, _self)
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
    form, so occlusion is what makes it read as solid rather than flat.
    """
    _apply_material('clay', selection, _self)
    _self.set('specular', 0.0)
    _self.set('shininess', 4)
    _self.set('metal_sss_wrap', 0.25)
    _self.set('metal_shadows', 1)
    _self.set('metal_rt_shadows', 1)
    _self.set('metal_rt_shadow_intensity', 0.7)
    _self.set('metal_ssao', 1)
    _self.set('metal_rt_ao_radius', 8)
    _self.set('metal_rt_ao_intensity', 0.9)


#: Bundle name -> function, for the menu and the Inspector's preset list. Only
#: the looks whose material is implemented appear here.
BUNDLES = (
    ('Marble (statuary)', 'marble'),
    ('Clay (unglazed)', 'clay'),
)
