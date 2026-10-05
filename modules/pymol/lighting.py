'''
The native light rig (#611, lighting epic #610).

A rig is up to six spot lights placed around the molecules, plus the rig's
`ambient` and `classic` terms and the air (haze and dust). It is owned by the
scene in C++ (one rig per PyMOL instance), saved in .pse files, and cleared by
`reinitialize`. It is not a setting and never writes one, and it is not an
object: it never appears in the object list or widens the scene extent.

The Metal renderer shades the rig (#613). While the rig is on (enabled,
with at least one light) PyMOL's own lights are scaled by the rig's
`classic` and its `ambient` replaces the `ambient` setting (decision 15).
That happens at render time: no setting is ever written, and with no rig, or
a rig that is off, rendering is exactly what it was. The `lights` and
`atmosphere` commands (#612, lighting_commands.py) edit the rig from the
command line through this module. This module is the scripting access:

* ``get_lights()`` returns the rig as a dict, or None when there is no rig.
* ``set_lights(rig)`` replaces it from such a dict (None removes it).

The dict format is versioned (version 1); the C++ field table defines its
keys, kinds, defaults and ranges (``_light_fields()``).

The private helpers (``_light_set``, ``_light_get``, ``_lights_eye``,
``_lights_json``) call the same C++ as the app bridge, and ``_light_frame``
and ``_light_warmth`` the same C++ as the renderer, so the tests can check
the rig maths (eye space, pin conversions, JSON, decision 15, the packed
GPU block, kelvin) from Python.
The CPU `ray` tracer never draws the rig (#626); ``_lights_ray_notice()``
is the notice it prints.
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


def _lights_ray_notice(*, _self=cmd):
    '''The notice the CPU ray tracer prints (as " Ray: <notice>") when it
    traces an image while the rig is on, or None when the rig is not on (no
    rig, disabled, or no lights). Studio lighting is Metal-only (#626): `ray`,
    `png ..., ray=1`, a headless `png` and `mpng` in ray mode keep PyMOL's
    own lights.'''
    with _self.lockcm:
        return _self._cmd.get_lights_ray_notice(_self._COb)


def _light_frame(matrix=None, *, _self=cmd):
    '''One frame's lighting as the Metal renderer reads it (#613): the
    classic light terms after decision 15 and the rig packed for the GPU.
    `matrix` is a world->eye 4x4 as 16 numbers in column-major order; None
    uses the live camera. Reads only: nothing is written.

    {'ambient', 'direct', 'reflect', 'specular', 'shininess',
     'rig_on': bool,
     'rig': None or {'count', 'head': [4], 'block': [100],
                     'lights': [{'name', 'position', 'shadow_slot',
                                 'direction', 'cos_outer', 'radiance',
                                 'cos_inner', 'highlight', 'falloff',
                                 'falloff_ref', 'outline'}, ...]}}

    With no rig, or a rig that is off, 'rig' is None and the terms are the
    settings (specular and shininess after PyMOL's light-count adjustment).
    'block' is the 400-byte block the GPU reads, as 100 floats, and
    'lights' is decoded from it (layer1/LightRigBlock.h has the offsets).
    'radiance' is color * warmth * intensity; 'shadow_slot' is -1 until
    per-light shadows (#616).'''
    if matrix is not None:
        matrix = [float(v) for v in matrix]
    with _self.lockcm:
        return _self._cmd.get_light_frame(_self._COb, matrix)


def _light_warmth(kelvin, *, _self=cmd):
    '''A light's warmth (kelvin) as the RGB multiplier the renderer applies
    to its colour, as a tuple (r, g, b): the black-body colour, white-balanced
    so 6500 K is exactly (1, 1, 1), with the largest channel 1. Warmer
    (lower) kelvin is redder, cooler (higher) bluer. Clamped to 1500-15000 K.'''
    with _self.lockcm:
        return tuple(_self._cmd.light_warmth_rgb(_self._COb, float(kelvin)))
