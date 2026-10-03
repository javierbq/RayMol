'''
The native light rig (#611, lighting epic #610).

A rig is up to six spot lights placed around the molecules, plus the rig's
`ambient` and `classic` terms and the air (haze and dust). It is owned by the
scene in C++ (one rig per PyMOL instance), saved in .pse files, and cleared by
`reinitialize`. It is not a setting and never writes one, and it is not an
object: it never appears in the object list or widens the scene extent.

Nothing renders the rig yet: shading lands in #613 and the `lights` and
`atmosphere` commands in #612. This module is the scripting access of #611:

* ``get_lights()`` returns the rig as a dict, or None when there is no rig.
* ``set_lights(rig)`` replaces it from such a dict (None removes it).

The dict format is versioned (version 1); the C++ field table defines its
keys, kinds, defaults and ranges (``_light_fields()``).

The private helpers (``_light_set``, ``_light_get``, ``_lights_eye``,
``_lights_json``) call the same C++ as the app bridge, so the tests can
check the rig maths (eye space, pin conversions, JSON) from Python.
'''

import sys

cmd = sys.modules["pymol.cmd"]


def get_lights(*, _self=cmd):
    '''
DESCRIPTION

    "get_lights" returns the light rig as a dict, or None when there is
    no rig.

PYMOL API

    cmd.get_lights()

    The dict (version 1):

    {'version': 1, 'enabled': bool,
     'centre': [x, y, z] or None, 'size': float or None,
     'ambient': float, 'classic': float,
     'air': {'haze', 'dust', 'dust_size', 'dust_speed', 'scatter', 'seed'},
     'lights': [{'name', 'anchor', 'orbit', 'pitch', 'radius', 'position',
                 'aim', 'aim_point', 'aim_selection', 'beam', 'softness',
                 'color', 'warmth', 'intensity', 'highlight', 'falloff',
                 'shadow', 'outline'}, ...]}

    'centre' and 'size' are the rig frame (world Angstrom): the box
    midpoint and half-diagonal of the enabled objects, captured when the
    first light is added and again only on re-centre. A light's 'radius' is
    in multiples of 'size'.

SEE ALSO

    set_lights
    '''
    with _self.lockcm:
        return _self._cmd.get_lights(_self._COb)


def set_lights(rig, *, _self=cmd):
    '''
DESCRIPTION

    "set_lights" replaces the light rig with a dict in the get_lights
    format, or removes it with None.

PYMOL API

    cmd.set_lights(dict rig)

    Missing keys take their defaults, and a light without a name takes the
    first unused of key, fill, rim, light4, light5, light6. Out-of-range
    numbers are clamped (orbit wraps into (-180, 180]). When the rig has
    lights and no 'centre'/'size', the frame is captured from the enabled
    objects in the current state (atoms with solvent excluded, plus maps,
    meshes, isosurfaces and CGOs).

    These raise CmdException naming the key, and leave the rig unchanged:
    unknown keys, a newer version, wrong types, non-finite numbers, only
    one of 'centre' and 'size', a pinned light without 'position', a light
    aimed at a point without 'aim_point', more than 6 lights, more than 3
    shadowed lights, and a bad or duplicate name (letters, digits and _,
    unique ignoring case).

EXAMPLE

    cmd.set_lights({'enabled': True, 'lights': [
        {'name': 'key', 'orbit': -45, 'pitch': 35, 'shadow': True},
        {'name': 'rim', 'orbit': 160, 'pitch': 30, 'color': [0, 1, 1]}]})

SEE ALSO

    get_lights
    '''
    with _self.lockcm:
        _self._cmd.set_lights(_self._COb, rig)


def _lights_recenter(*, _self=cmd):
    '''Capture the rig's centre and 1x size again from the current scene
    (`lights recenter`). Raises CmdException when there is no rig.'''
    with _self.lockcm:
        _self._cmd.lights_recenter(_self._COb)


def _light_fields(*, _self=cmd):
    '''The rig's field table, from C++: a list of
    (scope, name, kind, default, min, max) tuples. scope is 'rig', 'air'
    or 'light'; kind is 'bool', 'int', 'float', 'angle' (wraps into
    (min, max]), 'vec3', 'str', 'name', 'camera|pinned' or 'centre|point';
    min and max are None for unbounded fields.'''
    with _self.lockcm:
        return _self._cmd.get_light_fields(_self._COb)


def _light_set(index, field, value, *, _self=cmd):
    '''Set one field of light `index` (-1: the rig and its air) through the
    C++ setter the app bridge calls per drag tick. `value` is a number or 3
    numbers (color, aim_point, position). Numbers are clamped (orbit wraps);
    anchor 1/0 pins/unpins the light where it is now; orbit, pitch or
    radius on a pinned light re-pins it; position pins; aim_point aims at
    the point. Raises CmdException("<status>: <message>"), the status being
    'unknown field', 'bad index', 'refused', 'bad value' or 'no rig'; the
    rig is then unchanged.'''
    with _self.lockcm:
        _self._cmd.light_set(_self._COb, int(index), str(field), value)


def _light_get(index, field, *, _self=cmd):
    '''One field of light `index` (-1: the rig and its air), as get_lights()
    holds it. Raises CmdException("<status>: <message>") like _light_set.'''
    with _self.lockcm:
        return _self._cmd.light_get(_self._COb, int(index), str(field))


def _lights_eye(matrix=None, *, _self=cmd):
    '''The rig resolved to eye space by the C++ resolver the app bridge uses,
    or None when there is no rig. `matrix` is a world->eye 4x4 as 16 numbers
    in column-major order; None uses the live camera (as the bridge does).

    {'enabled', 'centre': [x, y, z] or None (eye space), 'size',
     'lights': [{'name', 'anchor', 'aim', 'position', 'target',
                 'direction', 'aim_distance', 'cos_outer', 'cos_inner',
                 'orbit', 'pitch', 'radius', 'shadow', 'outline'}, ...]}

    A pinned light's orbit, pitch and radius are derived from where it is
    now; a camera light's are its stored values.'''
    if matrix is not None:
        matrix = [float(v) for v in matrix]
    with _self.lockcm:
        return _self._cmd.get_lights_eye(_self._COb, matrix)


def _lights_json(*, _self=cmd):
    '''The rig as JSON, as the app bridge reads it (PyMOLBridge_LightsJSON),
    or None when there is no rig. Same keys, order and types as
    get_lights().'''
    with _self.lockcm:
        return _self._cmd.get_lights_json(_self._COb)
