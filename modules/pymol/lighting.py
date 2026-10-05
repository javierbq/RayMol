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

Scenes store their own rig (#617, raymol_scenes.py). ``_rig_to_session``
and ``_rig_from_session`` convert a rig dict to and from the positional list
the 'light_rig' session key holds, so per-scene rigs are saved in the same
lenient, forward-compatible format. ``_lights_blend`` is the frame command
scene movies carry on the interior frames of each transition
(raymol_scene_anim.py): it blends the two scenes' stored rigs.

Per-light shadow maps (#616): ``_light_frame`` also returns the frame's
studio shadow plan, and ``_light_shadow_frustum``, ``_light_shadow_map_size``,
``_light_shadow_tile``, ``_light_shadow_casters``, ``_gpu_time_summary`` and
``_gpu_frame_stats`` reach the same C++ as the renderer.
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


def _light_frame(matrix=None, grid=None, *, _self=cmd):
    '''One frame's lighting as the Metal renderer reads it (#613, #616):
    the classic light terms after decision 15, the rig packed for the GPU
    and its studio shadow maps. `matrix` is a world->eye 4x4 as 16 numbers
    in column-major order; None uses the live camera. `grid` is None for the
    scene's grid layout, or (n_col, n_row, first_slot) for a grid in its
    place. Reads only: nothing is written.

    {'ambient', 'direct', 'reflect', 'specular', 'shininess',
     'rig_on': bool, 'studio_shadows': bool, 'shadow_map_size': int,
     'rig': None or {'count', 'head': [4], 'block': [168],
                     'shadow_grid': [4], 'shadow_tile': [4],
                     'lights': [{'name', 'position', 'shadow_slot',
                                 'direction', 'cos_outer', 'radiance',
                                 'cos_inner', 'highlight', 'falloff',
                                 'falloff_ref', 'outline'}, ...]},
     'shadows': None or {'count', 'size', 'tiles', 'first_slot',
                         'slots': [{'slot', 'light', 'name', 'view',
                                    'proj', 'view_proj', 'tan_half_fov',
                                    'map_size', 'normal_offset',
                                    'depth_bias', 'near', 'far',
                                    'beam_fit'}, ...]}}

    With no rig, or a rig that is off, 'rig' and 'shadows' are None and the
    terms are the settings (specular and shininess after PyMOL's light-count
    adjustment). 'block' is the 672-byte block the GPU reads, as 168 floats
    (layer1/LightRigBlock.h has the offsets): floats 0-99 are the head and
    six lights (#613), 100-159 three shadow maps of 20 floats (a column-major
    eye -> light clip matrix, then tan(half fov), map size, normal offset and
    depth bias), 160-163 the shadow grid (tiles per side, first grid slot,
    columns, rows) and 164-167 the per-draw tile (0 here). 'lights' and
    'shadow_grid' are decoded from it. 'radiance' is color * warmth *
    intensity.

    Studio shadows are on ('studio_shadows') when the rig is on,
    metal_shadows is on and a light has `shadow`; the whole-pixel shadow is
    then off. 'shadows' is the plan: the first three shadowed lights with
    casters in front of them get map slots 0, 1, 2 ('shadow_slot', -1
    otherwise, and head[3] the count), with frusta fitted to the casters
    without overlays (_light_shadow_casters).'''
    if matrix is not None:
        matrix = [float(v) for v in matrix]
    if grid is not None:
        grid = tuple(int(v) for v in grid)
    with _self.lockcm:
        return _self._cmd.get_light_frame(_self._COb, matrix, grid)


def _light_shadow_frustum(pos, axis, cos_outer, centre, radius, *, _self=cmd):
    '''The studio shadow map frustum of a light at `pos` with unit beam
    `axis` and cone cos(outer) `cos_outer`, for casters inside the sphere
    (`centre`, `radius`), all in eye space (Å), as the renderer computes it
    (#616): {'view', 'proj', 'view_proj' (16 floats each, column-major),
    'tan_half_fov', 'near', 'far', 'beam_fit'}, or None when the casters are
    behind the light.'''
    with _self.lockcm:
        return _self._cmd.light_shadow_frustum(
            _self._COb, tuple(float(v) for v in pos),
            tuple(float(v) for v in axis), float(cos_outer),
            tuple(float(v) for v in centre), float(radius))


def _light_shadow_map_size(setting, mobile=False, *, _self=cmd):
    '''The texels per side of each studio shadow map for a
    metal_light_shadow_size of `setting` (#616): 0 or negative gives the
    platform default (2048, or 1024 when `mobile`); otherwise clamped to
    256..4096 (256..2048 mobile) and rounded down to a power of two.'''
    with _self.lockcm:
        return _self._cmd.light_shadow_map_size(
            _self._COb, int(setting), bool(mobile))


def _light_shadow_tile(cell, tiles, size, *, _self=cmd):
    '''Grid cell `cell`'s tile in a `tiles` x `tiles` atlas of a
    `size`-texel map (#616): {'x', 'y', 'size', 'uv': [u0, v0, du, dv]}; size
    0 for a cell outside the atlas.'''
    with _self.lockcm:
        return _self._cmd.light_shadow_tile(
            _self._COb, int(cell), int(tiles), int(size))


def _light_shadow_casters(*, _self=cmd):
    '''What the studio shadow maps are drawn from (#616): {'casters':
    [object names], 'excluded': [overlays: gadgets, gizmos and the Move
    gizmo], 'extent': [[min], [max]] or None (the box the frusta are fitted
    to, overlays left out), 'overlay_name': the Move gizmo's object name}.'''
    with _self.lockcm:
        return _self._cmd.get_light_shadow_casters(_self._COb)


def _gpu_time_summary(samples, *, _self=cmd):
    '''GPU frame-time statistics as the renderer computes them (#616):
    {'count', 'mean', 'median', 'p95' (nearest rank), 'max'} over the finite,
    non-negative `samples` (ms).'''
    with _self.lockcm:
        return _self._cmd.gpu_time_summary(
            _self._COb, [float(v) for v in samples])


def _gpu_frame_stats(*, _self=cmd):
    '''The renderer's recent GPU frame times while metal_gpu_timing is on
    (#616): the _gpu_time_summary keys plus 'last_ms', 'mode', 'shadow_maps'
    and 'shadow_size'; None with no Metal renderer or no frames yet.'''
    with _self.lockcm:
        return _self._cmd.get_gpu_frame_stats(_self._COb)


def _light_warmth(kelvin, *, _self=cmd):
    '''A light's warmth (kelvin) as the RGB multiplier the renderer applies
    to its colour, as a tuple (r, g, b): the black-body colour, white-balanced
    so 6500 K is exactly (1, 1, 1), with the largest channel 1. Warmer
    (lower) kelvin is redder, cooler (higher) bluer. Clamped to 1500-15000 K.'''
    with _self.lockcm:
        return tuple(_self._cmd.light_warmth_rgb(_self._COb, float(kelvin)))


def _rig_to_session(rig, *, _self=cmd):
    '''A rig dict (the get_lights() format) as the positional list the
    'light_rig' session key holds (#617). Strict like set_lights, then
    validated; never touches the live rig. Raises CmdException
    ("light_rig_to_session: <reason>").'''
    with _self.lockcm:
        return _self._cmd.light_rig_to_session(_self._COb, rig)


def _rig_from_session(lst, *, _self=cmd):
    '''A 'light_rig' session list read as leniently as the session key
    (#617): returns (dict, [warning, ...]). A newer version loads its known
    prefix with a warning, and lights past the 6th (or shadows past the 3rd)
    are dropped with a warning. Raises CmdException
    ("light_rig_from_session: <reason>") when the list does not read; never
    touches the live rig.'''
    with _self.lockcm:
        rig, warnings = _self._cmd.light_rig_from_session(_self._COb, lst)
    return rig, list(warnings)


def _lights_blend(a='', b='', t='', *, _self=cmd):
    '''Movie frame command (#617): `_lights_blend A, B, t` blends scene A's
    stored rig towards scene B's at the eased position t (names in UTF-8
    hex). raymol_scene_anim authors it; see lights_blend there. Bad
    arguments are ignored: it prints nothing and never raises.'''
    try:
        from pymol import raymol_scene_anim
        raymol_scene_anim.lights_blend(a, b, t, _self=_self)
    except Exception:
        pass
