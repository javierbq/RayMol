'''
The `lights` and `atmosphere` commands (#612, lighting epic #610).

They script the native light rig of #611 (pymol.lighting): presets, adding,
editing and removing lights, the rig's on/off switch and the air.

Each call is one transaction under the API lock:

1. read the rig and the C++ field table, parse every argument and build the
   new rig (nothing is changed yet);
2. replace the rig with set_lights, then run the steps that need the frame
   just captured or the live camera, through the per-field setter;
3. print and return.

Any error in step 2 puts the old rig back, so nothing changes when an
argument is invalid, and every error is a CmdException starting with
"lights: " or "atmosphere: " (in a `;` chain PyMOL then skips the rest of the
line).

Only the module functions of pymol.lighting are called, with `_self`, never
cmd.set_lights or cmd.get_lights: each PyMOL instance acts on its own rig, and
a script that wraps cmd.set_lights (the lighting scene files do) can call
`lights` without recursing.

Field kinds and ranges are read from the C++ field table at call time; only
the presets, keywords and aliases are tables here. Nothing runs at import.

The placement helpers (target=, click=, highlight=<sele>, rim=) read the
instance's own camera (pymol.metal_pick.camera) and the drawn geometry
through the native surface pick of #614 (pymol.metal_pick.surface_at),
once, when they are given.
'''

import copy
import math
import numbers
import re
import sys

from pymol import CmdException

from . import lighting

cmd = sys.modules["pymol.cmd"]

# --- tables -----------------------------------------------------------------

KEYWORDS = ('add', 'remove', 'presets', 'recenter', 'on', 'off', 'clear')

# The rig's limits (layer1/LightRig.h); C++ checks them again on set_lights.
MAX_LIGHTS = 6
MAX_SHADOWS = 3
NAME_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]{0,31}$')

# The prototype's field names, kept as aliases (spec section 5).
ALIASES = {
    'az': 'orbit',
    'el': 'pitch',
    'dist': 'radius',
    'soft': 'softness',
    'int': 'intensity',
    'spec': 'highlight',
    'cue': 'outline',
    'kelvin': 'warmth',
    'colour': 'color',
}

# Light fields the command takes on top of the stored ones: rgb= sets color,
# pin= sets anchor, and the placement helpers (resolved once when given).
COMMAND_FIELDS = ('rgb', 'pin')
HELPERS = ('target', 'highlight', 'click', 'rim')

# Colour words that set white plus a warmth (kelvin) instead of a PyMOL
# colour: `color=warm` must not resolve to PyMOL's warmpink.
COLOUR_WARMTH = {'warm': 3200.0, 'neutral': 6500.0, 'cool': 9000.0}

# Stored fields set by other forms, and where to go instead.
_CAPTURED = ("is captured from the molecules; 'lights recenter' captures "
             "it again")
SET_ELSEWHERE = {
    'enabled': "is set by 'lights on' and 'lights off'",
    'centre': _CAPTURED,
    'size': _CAPTURED,
    'version': 'is not a field (get_lights reports the format version)',
    'aim_point': 'is set by aim= (centre, a point x/y/z or a selection) and '
                 'the placement helpers',
    'aim_selection': 'is set by aim=<selection> (it keeps the text for '
                     'display)',
}

_WHITE = [1.0, 1.0, 1.0]


def _light(name, **fields):
    light = {'name': name}
    light.update(fields)
    return light


# Each preset: (description, ambient, lights). classic is 0 for every preset;
# a light's unlisted fields take their defaults (radius 4, falloff 2, colour
# white, warmth 6500, highlight 0.5). Colours are literal RGB, so set_color
# can never change a preset. Ported from the prototype's PRESETS (its 2.5
# falloff for rembrandt is out of range and is 2 here).
PRESETS = {
    'three_point': (
        'Classic portrait: warm key with shadow, cool fill, white rim', 0.10, [
            _light('key', orbit=-45.0, pitch=35.0, beam=55.0, softness=0.5,
                   warmth=4500.0, intensity=1.15, highlight=0.6, shadow=True),
            _light('fill', orbit=55.0, pitch=5.0, beam=80.0, softness=0.8,
                   warmth=8000.0, intensity=0.35, highlight=0.1),
            _light('rim', orbit=165.0, pitch=40.0, beam=40.0, softness=0.4,
                   intensity=1.6, highlight=1.0),
        ]),
    'softbox': (
        'Product shot: two big soft white boxes, gentle top light', 0.16, [
            _light('left', orbit=-60.0, pitch=20.0, beam=120.0, softness=1.0,
                   intensity=0.75, highlight=0.25, shadow=True),
            _light('right', orbit=60.0, pitch=20.0, beam=120.0, softness=1.0,
                   intensity=0.55, highlight=0.25),
            _light('top', orbit=0.0, pitch=80.0, beam=110.0, softness=1.0,
                   intensity=0.35, highlight=0.15),
        ]),
    'spotlight': (
        'Theatre: one narrow beam from above, the rest falls off', 0.05, [
            _light('spot', orbit=-15.0, pitch=50.0, radius=3.0, beam=18.0,
                   softness=0.3, warmth=5200.0, intensity=1.8, highlight=0.9,
                   shadow=True),
            _light('bounce', orbit=20.0, pitch=-30.0, beam=90.0, softness=1.0,
                   warmth=7500.0, intensity=0.12, highlight=0.0),
        ]),
    'rembrandt': (
        'Dramatic: one hard warm key high to the side, almost no fill', 0.04, [
            _light('key', orbit=-70.0, pitch=45.0, radius=3.0, beam=60.0,
                   softness=0.3, warmth=3400.0, intensity=1.5, highlight=0.7,
                   falloff=2.0, shadow=True),
            _light('kicker', orbit=150.0, pitch=10.0, beam=30.0, softness=0.4,
                   warmth=6500.0, intensity=0.6, highlight=0.6),
        ]),
    'neon': (
        'Coloured rims: magenta and cyan from behind, dim violet front',
        0.06, [
            _light('magenta', orbit=-125.0, pitch=20.0, beam=55.0,
                   softness=0.5, color=[1.0, 0.0, 1.0], intensity=1.6,
                   highlight=1.0, shadow=True),
            _light('cyan', orbit=125.0, pitch=20.0, beam=55.0, softness=0.5,
                   color=[0.0, 1.0, 1.0], intensity=1.6, highlight=1.0),
            _light('front', orbit=0.0, pitch=0.0, beam=90.0, softness=1.0,
                   color=[0.5, 0.5, 1.0], intensity=0.25, highlight=0.1),
        ]),
    'sunset': (
        'Low orange sun from one side, blue sky fill from the other', 0.08, [
            _light('sun', orbit=-75.0, pitch=12.0, beam=70.0, softness=0.5,
                   warmth=2400.0, intensity=1.4, highlight=0.8, shadow=True),
            _light('sky', orbit=60.0, pitch=50.0, beam=110.0, softness=1.0,
                   warmth=14000.0, intensity=0.45, highlight=0.1),
        ]),
    'underlight': (
        'Horror-film: green-tinted key from below, red rim', 0.04, [
            _light('under', orbit=0.0, pitch=-55.0, beam=60.0, softness=0.5,
                   color=[0.6, 1.0, 0.55], intensity=1.3, highlight=0.6,
                   shadow=True),
            _light('rim', orbit=170.0, pitch=25.0, beam=40.0, softness=0.4,
                   color=[1.0, 0.0, 0.0], intensity=1.4, highlight=0.8),
        ]),
}

# Off-centre aims, in rig sizes along the camera's axes (x right, y up, z
# towards the viewer). Resolved once into a world aim point when the preset
# is applied, from the frame it captures and the camera at that moment.
PRESET_AIMS = {
    'spotlight': {'spot': (-0.25, 0.15, 0.0)},
}

# Units shown in out-of-range errors.
_UNITS = {
    'orbit': 'degrees', 'pitch': 'degrees', 'beam': 'degrees',
    'radius': 'scene sizes', 'warmth': 'kelvin',
}

_KEEP = object()        # the transaction leaves the rig as it is


def presets():
    '''The presets in display order, as [(name, description), ...] (for the
    lighting menu, #619).'''
    return [(name, preset[0]) for name, preset in PRESETS.items()]


# --- errors and values ------------------------------------------------------

def _error(where, message):
    return CmdException('%s: %s' % (where, message))


def _num(x):
    '''A number as the docs and messages print it: integers in full, other
    numbers as %g (ASCII only).'''
    x = float(x)
    if x == 0.0:
        return '0'
    if x.is_integer() and abs(x) < 1e15:
        return str(int(x))
    return '%g' % x


def _shown(value):
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, (int, float)):
        return _num(value) if math.isfinite(value) else repr(value)
    if isinstance(value, (list, tuple)):
        return '[%s]' % ','.join(_shown(v) for v in value)
    return repr(value)


_COMMA_RE = re.compile(r'\s[A-Za-z_]\w*\s*=')
_COMMA_EXAMPLE = {
    'lights': 'lights key, orbit=-45, pitch=35',
    'atmosphere': 'atmosphere haze=0.3, dust=0.5',
}


def _comma_hint(where, value):
    '''"; separate arguments with commas: ..." when a value that failed to
    parse holds another `name=`, as "atmosphere haze=0.3 dust=0.5" gives.'''
    if isinstance(value, str) and _COMMA_RE.search(value):
        command = where.split(':', 1)[0]
        return '; separate arguments with commas: %s' % (
            _COMMA_EXAMPLE.get(command, command + ' a=1, b=2'),)
    return ''


def _wrap_degrees(deg):
    '''Into (-180, 180], as LightWrapDegrees does.'''
    if -180.0 < deg <= 180.0:
        return deg
    r = math.fmod(deg, 360.0)
    if r <= -180.0:
        r += 360.0
    elif r > 180.0:
        r -= 360.0
    return r


def _out_of_range(where, field, value, lo, hi):
    unit = _UNITS.get(ALIASES.get(field, field))
    return _error(where, '%s=%s is out of range %s to %s%s' % (
        field, _shown(value), _num(lo), _num(hi),
        ' (%s)' % unit if unit else ''))


def _parse_number(where, field, value, lo=None, hi=None, angle=False):
    '''A finite float. Text goes through float(); a bool is refused. Out of
    range is an error naming the field, value and range; an angle wraps.'''
    if isinstance(value, bool):
        raise _error(where, '%s=%s: a number is needed, not a boolean' % (
            field, value))
    if isinstance(value, (int, float)):
        try:
            v = float(value)
        except OverflowError:
            v = math.inf
    else:
        text = str(value).strip()
        if not text:
            raise _error(where, '%s= needs a value' % field)
        try:
            v = float(text)
        except (ValueError, OverflowError):
            raise _error(where, '%s=%s is not a number%s' % (
                field, text, _comma_hint(where, text))) from None
    if not math.isfinite(v):
        raise _error(where, '%s=%s is not a finite number' % (
            field, _shown(value)))
    if angle:
        return _wrap_degrees(v)
    if lo is not None and not (lo <= v <= hi):
        raise _out_of_range(where, field, value, lo, hi)
    return v


_INT_RE = re.compile(r'^[+-]?[0-9]+$')


def _parse_int(where, field, value, lo=None, hi=None):
    '''A Python int: an integer literal, an int, or a float with an integral
    value (7.5 is an error).'''
    if isinstance(value, bool):
        raise _error(where, '%s=%s: a whole number is needed, not a boolean'
                     % (field, value))
    if isinstance(value, int):
        v = value
    elif isinstance(value, float):
        if not (math.isfinite(value) and value.is_integer()):
            raise _error(where, '%s=%s is not a whole number' % (
                field, _shown(value)))
        v = int(value)
    else:
        text = str(value).strip()
        if not text:
            raise _error(where, '%s= needs a value' % field)
        if not _INT_RE.match(text):
            raise _error(where, '%s=%s is not a whole number%s' % (
                field, text, _comma_hint(where, text)))
        v = int(text)
    if lo is not None and not (lo <= v <= hi):
        raise _out_of_range(where, field, value, lo, hi)
    return v


_TRUE = ('1', 'on', 'true', 'yes')
_FALSE = ('0', 'off', 'false', 'no')


def _parse_bool(where, field, value):
    '''1/0, on/off, true/false, yes/no (any case), a bool, or the ints 0/1.'''
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    text = str(value).strip().lower()
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    raise _error(where, '%s=%s: use 1/0, on/off, true/false or yes/no%s' % (
        field, _shown(value), _comma_hint(where, value)))


def _quiet(command, quiet):
    try:
        return bool(int(quiet))
    except (TypeError, ValueError):
        return _parse_bool(command, 'quiet', quiet)


class _Fields(object):
    '''The C++ field table (lighting._light_fields): scope -> {name: (kind,
    default, min, max)}, in table order.'''

    def __init__(self, rows):
        self.scopes = {'rig': {}, 'air': {}, 'light': {}}
        for scope, name, kind, default, lo, hi in rows:
            self.scopes.setdefault(scope, {})[name] = (kind, default, lo, hi)

    def names(self, scope):
        return list(self.scopes.get(scope, {}))

    def parse(self, where, scope, name, value, label=None):
        '''One value of a numeric or boolean field, strictly typed. Messages
        name the field as `label` (the alias the user typed) when given.'''
        kind, _default, lo, hi = self.scopes[scope][name]
        label = label or name
        if kind == 'bool':
            return _parse_bool(where, label, value)
        if kind == 'int':
            return _parse_int(where, label, value, lo, hi)
        if kind in ('float', 'angle'):
            return _parse_number(where, label, value, lo, hi,
                                 angle=(kind == 'angle'))
        raise _error(where, '%s cannot be set this way' % label)

    def defaults(self, scope):
        return {name: copy.deepcopy(entry[1])
                for name, entry in self.scopes.get(scope, {}).items()}


# --- the field classifier, for messages ------------------------------------

_RIG_EDITABLE = ('ambient', 'classic')


def _field_class(name, table):
    '''What a field name is: 'rig' (ambient, classic), 'air', 'light' (a
    light field, alias or helper), 'elsewhere' (set by another form) or
    None (unknown).'''
    if name in _RIG_EDITABLE:
        return 'rig'
    if name in SET_ELSEWHERE:
        return 'elsewhere'
    if name in table.scopes['air']:
        return 'air'
    if (name in table.scopes['light'] or name in ALIASES
            or name in COMMAND_FIELDS or name in HELPERS):
        return 'light'
    return None


def _light_field_list(table):
    names = []
    for name in table.names('light'):
        if name in SET_ELSEWHERE:
            continue
        aliases = [a for a, target in ALIASES.items() if target == name]
        names.append('%s (%s)' % (name, ', '.join(aliases)) if aliases
                     else name)
    return ', '.join(names + list(COMMAND_FIELDS))


def _unknown_field(where, name, table, context='light'):
    if context == 'air':
        known = 'fields: %s' % ', '.join(table.names('air'))
    elif context == 'preset':
        known = 'a preset takes only %s' % ', '.join(
            '%s=' % f for f in _RIG_EDITABLE)
    else:
        known = 'rig: %s; light: %s; placement: %s; air (atmosphere): %s' % (
            ', '.join(_RIG_EDITABLE), _light_field_list(table),
            ', '.join(HELPERS), ', '.join(table.names('air')))
    return _error(where, "unknown field '%s' (%s)" % (name, known))


def _field_error(where, name, value, table, context):
    '''The error for a field that `context` ('rig', 'air' or 'preset')
    does not take.'''
    cls = _field_class(name, table)
    if cls == 'elsewhere':
        return _error(where, '%s %s' % (name, SET_ELSEWHERE[name]))
    if cls == 'air':
        return _error(where, '%s is an atmosphere field: atmosphere %s=%s' % (
            name, name, _shown(value)))
    if cls == 'rig':
        return _error(where, '%s is a rig field: lights %s=%s' % (
            name, name, _shown(value)))
    if cls == 'light':
        if context == 'preset':
            return _error(where, '%s is a light field: apply the preset, '
                          'then edit a light (lights <name>, %s=%s)' % (
                              name, name, _shown(value)))
        return _error(where, 'which light? %s is a light field: '
                      'lights <name>, %s=%s or lights add, <name>, %s=%s' % (
                          name, name, _shown(value), name, _shown(value)))
    return _unknown_field(where, name, table, context)


# --- arguments --------------------------------------------------------------

def _word(value):
    if value is None:
        return ''
    return str(value).strip()


def _check_words(command, words, extra):
    if extra:
        raise _error(command, 'too many arguments: %s (%s)' % (
            ', '.join(repr(_shown(e)) for e in extra),
            'lights [word [, name]] [, field=value ...]'
            if command == 'lights' else
            'atmosphere [off] [, field=value ...]'))
    for w in words:
        if re.search(r'[\s=]', w):
            raise _error(command, "'%s': separate arguments with commas, "
                         "e.g. %s" % (w, _COMMA_EXAMPLE[command]))


def _lower_fields(command, fields):
    out = {}
    for key, value in fields.items():
        name = str(key).strip().lower()
        if name in out:
            raise _error(command, '%s is given twice' % name)
        out[name] = value
    return out


# --- rig helpers ------------------------------------------------------------

def _find_light(rig, name):
    '''Index of the light called `name` (ignoring case), or None.'''
    if rig is None:
        return None
    low = name.lower()
    for i, light in enumerate(rig['lights']):
        if light['name'].lower() == low:
            return i
    return None


def _reserved(name):
    '''"keyword" or "preset" when `name` is one (ignoring case), else None.'''
    low = name.lower()
    if low in KEYWORDS:
        return 'keyword'
    if low in PRESETS:
        return 'preset'
    return None


def _check_name(where, name, lights, skip=None):
    '''Names: the LightNameValid rule, not a preset or keyword, unique among
    the other lights (all ignoring case).'''
    if not NAME_RE.match(name):
        raise _error(where, "name '%s' is not valid (letters, digits and "
                     "_, not starting with a digit, at most 32 characters)"
                     % name)
    kind = _reserved(name)
    if kind:
        raise _error(where, "'%s' is a %s: a light cannot be named after a "
                     "preset or keyword" % (name, kind))
    for i, light in enumerate(lights):
        if i != skip and light['name'].lower() == name.lower():
            raise _error(where, "a light named '%s' already exists (names "
                         "are unique ignoring case)" % light['name'])


def _empty_rig():
    '''A rig that is off and has no lights: what a rig-level or air edit
    creates when there is no rig.'''
    return {'version': 1, 'enabled': False, 'centre': None, 'size': None,
            'lights': []}


def _is_on(rig):
    '''The rig draws (SceneLightsOn): enabled, with lights and a frame.'''
    return bool(rig and rig['enabled'] and rig['lights']
                and rig.get('centre') is not None)


def _camera(where, _self):
    '''This instance's camera, as metal_pick.camera parses it (rot is the
    row-major model-to-camera rotation: its rows are the camera's x, y and
    z axes in world space).'''
    from . import metal_pick
    cam = metal_pick.camera(_self)
    if cam is None:
        raise _error(where, 'no camera view to place the light from')
    return cam


def _view_rows(_self):
    '''The rows of the model-to-camera rotation (camera x, y and z axes in
    world space), from this instance's camera.'''
    rot = _camera('lights', _self).rot
    return (tuple(rot[0:3]), tuple(rot[3:6]), tuple(rot[6:9]))


def _aim_offset_step(index, offset, _self):
    '''Aim light `index` at the rig centre plus `offset` rig sizes along the
    camera's axes, as a world point (resolved once).'''
    def step():
        rig = lighting.get_lights(_self=_self)
        centre, size = rig['centre'], rig['size']
        rows = _view_rows(_self)
        point = [centre[k] + size * sum(offset[a] * rows[a][k]
                                        for a in range(3))
                 for k in range(3)]
        lighting._light_set(index, 'aim_point', point, _self=_self)
    return step


# --- values: vectors, colours, aim -----------------------------------------

def _split_parts(text, parens):
    '''The parts of "x/y/z" or "[x,y,z]" (and "(x,y,z)" when `parens`), or
    None for any other text.'''
    t = text.strip()
    if len(t) >= 2 and ((t[0] == '[' and t[-1] == ']')
                        or (parens and t[0] == '(' and t[-1] == ')')):
        return [p.strip() for p in t[1:-1].split(',')]
    if '/' in t:
        return [p.strip() for p in t.split('/')]
    return None


def _is_real(value):
    return isinstance(value, numbers.Real) and not isinstance(value, bool)


def _parse_vec(where, field, value, n=3, parens=False,
               form='x/y/z or [x,y,z]'):
    '''n finite numbers: a list or tuple (from Python), or text in `form`.'''
    if isinstance(value, (list, tuple)):
        parts = list(value)
    elif isinstance(value, str):
        parts = _split_parts(value, parens)
    else:
        parts = None
    if parts is None or len(parts) != n:
        raise _error(where, '%s=%s: give %s%s' % (
            field, _shown(value), form, _comma_hint(where, value)))
    out = []
    for part in parts:
        if _is_real(part):
            v = float(part)
        elif isinstance(part, str) and part.strip():
            try:
                v = float(part)
            except (ValueError, OverflowError):
                raise _error(where, "%s=%s: '%s' is not a number%s" % (
                    field, _shown(value), part.strip(),
                    _comma_hint(where, value))) from None
        else:
            raise _error(where, '%s=%s: give %s' % (
                field, _shown(value), form))
        if not math.isfinite(v):
            raise _error(where, '%s=%s: each value must be a finite number'
                         % (field, _shown(value)))
        out.append(v)
    return out


def _parse_rgb(where, field, value):
    '''r/g/b, [r,g,b], (r,g,b) or a sequence: each 0 to 1, or all whole
    numbers 0 to 255 when any is above 1.'''
    rgb = _parse_vec(where, field, value, 3, parens=True,
                     form='r/g/b or [r,g,b]')
    if max(rgb) > 1.0:
        if all(c.is_integer() and 0.0 <= c <= 255.0 for c in rgb):
            return [c / 255.0 for c in rgb]
    elif min(rgb) >= 0.0:
        return rgb
    raise _error(where, '%s=%s: each value is 0 to 1, or all are whole '
                 'numbers 0 to 255' % (field, _shown(value)))


# Colours PyMOL resolves from context (an atom, an object, the background):
# they have no RGB of their own, and "auto" would advance auto_color_next.
SPECIAL_COLOURS = ('auto', 'current', 'default', 'atomic', 'object',
                   'front', 'back')
_HEX_RE = re.compile(r'^0[xX][0-9a-fA-F]{6}$')
_DIGITS_RE = re.compile(r'^[-+0-9]+$')
_COLOUR_USE = 'use a colour name, 0xRRGGBB, r/g/b, rgb= or warmth='


def _parse_colour(where, field, value, _self):
    '''A light colour, as (rgb, warmth): warmth is the kelvin of the colour
    words warm, neutral and cool (white plus a warmth), else None.

    Nothing here writes state: special colours, digit-only text (a colour
    index; -2 would advance auto_color_next) and malformed 0x text are
    refused as text, hex is decoded here, names are matched here (exact,
    then a unique prefix, ignoring case), and C++ is only asked for the RGB
    of a listed index.'''
    if isinstance(value, (list, tuple)):
        return _parse_rgb(where, field, value), None
    if not isinstance(value, str):
        raise _error(where, '%s=%s: colour indices are not accepted; %s' % (
            field, _shown(value), _COLOUR_USE))
    text = value.strip()
    low = text.lower()
    if not text:
        raise _error(where, '%s= needs a value' % field)
    if low in COLOUR_WARMTH:
        return list(_WHITE), COLOUR_WARMTH[low]
    if low in SPECIAL_COLOURS:
        raise _error(where, '%s=%s: special colours have no RGB value; %s'
                     % (field, text, _COLOUR_USE))
    if low.startswith('0x'):
        if not _HEX_RE.match(text):
            raise _error(where, '%s=%s is not a hex colour (0xRRGGBB)' % (
                field, text))
        return [int(text[i:i + 2], 16) / 255.0 for i in (2, 4, 6)], None
    if _DIGITS_RE.match(text):
        raise _error(where, '%s=%s: colour indices are not accepted; %s' % (
            field, text, _COLOUR_USE))
    if '/' in text or text[0] in '[(':
        return _parse_rgb(where, field, text), None
    names = {}
    for name, index in _self.get_color_indices(all=1) or []:
        key = name.lower()
        if index >= 0 and key not in SPECIAL_COLOURS:
            names.setdefault(key, (name, index))
    hit = names.get(low)
    if hit is None:
        matches = [entry for key, entry in names.items()
                   if key.startswith(low)]
        if len(matches) > 1:
            shown = ', '.join(name for name, _ in matches[:8])
            more = len(matches) - 8
            raise _error(where, '%s=%s is ambiguous: %s%s' % (
                field, text, shown,
                ' and %d more' % more if more > 0 else ''))
        if not matches:
            ramps = [n.lower() for n in
                     (_self.get_names_of_type('object:ramp') or [])]
            if low in ramps:
                raise _error(where, '%s=%s is a colour ramp, not a colour'
                             % (field, text))
            raise _error(where, '%s=%s is not a PyMOL colour%s' % (
                field, text, _comma_hint(where, text)))
        hit = matches[0]
    rgb = _self.get_color_tuple(str(hit[1]))
    if not rgb:
        raise _error(where, '%s=%s has no RGB value' % (field, text))
    return [float(c) for c in rgb], None


def _parse_aim(where, field, value):
    '''aim=: ('centre',), ('point', xyz, '') or ('selection', text). Three
    numbers are a world point; parentheses force a selection.'''
    if isinstance(value, (list, tuple)):
        return ('point', _parse_vec(where, field, value), '')
    if not isinstance(value, str):
        raise _error(where, '%s=%s: give centre, x/y/z, [x,y,z] or a '
                     'selection' % (field, _shown(value)))
    text = value.strip()
    if not text:
        raise _error(where, '%s= needs a value' % field)
    if text.lower() in ('centre', 'center'):
        return ('centre',)
    if text[0] == '[':
        return ('point', _parse_vec(where, field, text), '')
    if text[0] != '(':
        parts = _split_parts(text, False)
        if parts is not None and len(parts) == 3:
            try:
                point = [float(p) for p in parts]
            except ValueError:
                point = None
            if point is not None:
                return ('point', _parse_vec(where, field, text), '')
    return ('selection', text)


def _drawn_atoms(sele, _self):
    '''The chempy atoms of a selection as they are drawn now, in world space
    (object matrices applied, as the frame capture and the pick use). Each
    object is read at its own effective state (get_object_state): a
    single-state object at every frame (static_singletons), the object's
    own state setting, every state with all_states. An object whose state
    is past its last one is not drawn and gives no atoms. (get_model at
    the global state would drop single-state objects above frame 1.)'''
    atoms = []
    for obj in _self.get_object_list('(%s)' % sele) or []:
        try:
            state = _self.get_object_state(obj)
        except CmdException:
            continue
        if state == 0:
            states = range(1, _self.count_states('%' + obj) + 1)
        else:
            states = (state,)
        part = '(%s) and %%%s' % (sele, obj)
        for s in states:
            atoms += _self.get_model(part, state=s).atom
    return atoms


def _selection_model(where, field, sele, _self):
    '''The chempy atoms of a selection as drawn now (see _drawn_atoms).'''
    try:
        atoms = _drawn_atoms(sele, _self)
        hidden = not atoms and _self.count_atoms('(%s)' % sele) > 0
    except CmdException:
        raise _error(where, '%s=%s is not a valid selection%s' % (
            field, sele, _comma_hint(where, sele))) from None
    if hidden:
        raise _error(where, '%s=%s: none of the selection\'s atoms is drawn '
                     'in the current state (%d)' % (
                         field, sele, _self.get_state()))
    if not atoms:
        raise _error(where, '%s=%s: the selection has no atoms' % (
            field, sele))
    return atoms


def _selection_atoms(where, field, sele, _self):
    '''The coordinates of a selection's atoms (see _selection_model).'''
    return [a.coord for a in _selection_model(where, field, sele, _self)]


def _centroid(coords):
    n = float(len(coords))
    return [sum(c[k] for c in coords) / n for k in range(3)]


# --- light fields -----------------------------------------------------------

_PLACE = ('orbit', 'pitch', 'radius')
_PICKS = ('click', 'highlight')         # helpers that pick a surface point


def _parse_click(where, field, value):
    '''click=x/y: two finite numbers, each -1 to 1 (viewport NDC, +y up).'''
    point = _parse_vec(where, field, value, 2, parens=True,
                       form='x/y or [x,y], each from -1 to 1')
    if not all(-1.0 <= v <= 1.0 for v in point):
        raise _error(where, '%s=%s: each value is -1 to 1 (0/0 is the '
                     'centre of the viewport, 1/1 its top right corner)' % (
                         field, _shown(value)))
    return tuple(point)


def _parse_rim(where, field, value):
    '''rim=deg: 0 to under 180 degrees (0 is the mirror rule).'''
    v = _parse_number(where, field, value)
    if not 0.0 <= v < 180.0:
        raise _error(where, '%s=%s is out of range 0 to under 180 (degrees)'
                     % (field, _shown(value)))
    return v


def _parse_selection_text(where, field, value):
    if not isinstance(value, str):
        raise _error(where, '%s=%s: give a selection' % (
            field, _shown(value)))
    text = value.strip()
    if not text:
        raise _error(where, '%s= needs a selection' % field)
    return text


def _looks_numeric(value):
    '''highlight=: a number (or a value meant as one) is the strength; any
    other text is the placement helper (Q4).'''
    if not isinstance(value, str):
        return True
    text = value.strip()
    if not text:
        return True
    try:
        float(text)
    except (ValueError, OverflowError):
        return False
    return True


class _LightSpec(object):
    '''The parsed fields of one "lights <name>, ..." or "lights add, ...".

    values    stored fields set straight in the light's dict (beam,
              softness, color, warmth, intensity, highlight, falloff,
              shadow, outline)
    place     orbit, pitch and radius: in the dict for a camera light,
              through the setter (a re-pin) for a pinned one
    pin       True or False (pin= or anchor=), or None
    position  a world point, or None
    aim       None, ('centre',), ('point', xyz, '') or
              ('point', xyz, selection text)
    name      the new name, or None
    helpers   the placement helpers, parsed: target and highlight (the
              selection text), click ((x, y)) and rim (degrees)
    given     role -> the field name as typed, for messages
    raw       role -> the value as given, for messages
    colour_word  warm, neutral or cool when color= was one, else None
    '''

    def __init__(self):
        self.values = {}
        self.place = {}
        self.pin = None
        self.position = None
        self.aim = None
        self.name = None
        self.helpers = {}
        self.given = {}
        self.raw = {}
        self.colour_word = None

    def typed(self, role):
        '''"field=value" as the user typed it.'''
        return '%s=%s' % (self.given[role], _shown(self.raw[role]))


def _role(given, value):
    '''What a typed light field sets: its canonical field, 'pin' for pin=
    and anchor=, or the helper's name.'''
    name = ALIASES.get(given, given)
    if name == 'anchor':
        return 'pin'
    if given == 'highlight' and not _looks_numeric(value):
        return 'highlight=<sele>'
    return name


def _parse_light_fields(where, table, fields, _self):
    '''Phase 1 for one light: parse and check every field, resolve colours
    and aim selections. Changes nothing.'''
    spec = _LightSpec()
    raw = []
    for given, value in fields.items():
        if _field_class(given, table) != 'light':
            raise _field_error(where, given, value, table, 'light')
        role = _role(given, value)
        if role in spec.given:
            if role == 'pin':
                raise _error(where, 'pin= and anchor= both set the anchor: '
                             'give one')
            raise _error(where, '%s is given twice (%s= and %s=)' % (
                ALIASES.get(given, given), spec.given[role], given))
        spec.given[role] = given
        spec.raw[role] = value
        raw.append((role, given, value))

    for role, given, value in raw:
        if role == 'name':
            name = _word(value)
            if not name:
                raise _error(where, '%s= needs a value' % given)
            spec.name = name
        elif role == 'pin':
            if given == 'pin':
                spec.pin = _parse_bool(where, given, value)
            else:
                text = str(value).strip().lower()
                if text not in ('camera', 'pinned'):
                    raise _error(where, '%s=%s: use camera or pinned%s' % (
                        given, _shown(value), _comma_hint(where, value)))
                spec.pin = text == 'pinned'
        elif role == 'position':
            spec.position = _parse_vec(where, given, value, parens=True)
        elif role == 'aim':
            spec.aim = _parse_aim(where, given, value)
        elif role == 'color':
            rgb, kelvin = _parse_colour(where, given, value, _self)
            spec.values['color'] = rgb
            if kelvin is not None:
                spec.values['warmth'] = kelvin
                spec.colour_word = value.strip().lower()
        elif role == 'rgb':
            spec.values['color'] = _parse_rgb(where, given, value)
        elif role == 'click':
            spec.helpers['click'] = _parse_click(where, given, value)
        elif role == 'rim':
            spec.helpers['rim'] = _parse_rim(where, given, value)
        elif role in ('target', 'highlight=<sele>'):
            spec.helpers[role.split('=')[0]] = _parse_selection_text(
                where, given, value)
        elif role in _PLACE:
            spec.place[role] = table.parse(where, 'light', role, value, given)
        else:
            spec.values[role] = table.parse(where, 'light', role, value,
                                            given)

    _check_conflicts(where, spec)

    if spec.aim is not None and spec.aim[0] == 'selection':
        sele = spec.aim[1]
        spec.aim = ('point', _centroid(_selection_atoms(
            where, spec.given['aim'], sele, _self)), sele)
    return spec


def _check_conflicts(where, spec):
    '''Fields that set the same thing, or that a helper computes.'''
    g = spec.given

    def say(a, b, why):
        return _error(where, '%s= and %s= %s' % (g[a], g[b], why))

    if 'color' in g and 'rgb' in g:
        raise say('color', 'rgb', 'both set the colour: give one')
    if spec.colour_word is not None and 'warmth' in g:
        raise _error(where, '%s sets white with warmth %s K: give %s= or '
                     '%s=, not both' % (
                         spec.typed('color'),
                         _num(COLOUR_WARMTH[spec.colour_word]),
                         g['warmth'], g['color']))
    if spec.position is not None:
        if spec.pin is False:
            raise say('position', 'pin', 'disagree: position= pins the '
                      'light')
        for f in _PLACE:
            if f in g:
                raise say('position', f, 'both place the light: give one')
    placing = [h for h in ('target', 'click', 'highlight')
               if h in spec.helpers]
    if len(placing) > 1:
        raise _error(where, '%s: give one placement helper' % ', '.join(
            '%s=' % h for h in placing))
    if spec.helpers and 'aim' in g:
        helper = (placing or ['rim'])[0]
        raise _error(where, 'aim= and %s= both set the aim: give one'
                     % helper)
    picks = [h for h in _PICKS if h in spec.helpers]
    if 'rim' in spec.helpers and not picks:
        raise _error(where, 'rim= needs click= or highlight=<selection>')
    if picks:
        for f in ('orbit', 'pitch'):
            if f in g:
                raise _error(where, '%s= and %s= both place the light: %s= '
                             'computes the direction' % (
                                 g[f], picks[0], picks[0]))
        if spec.position is not None:
            raise _error(where, '%s= and %s= both place the light: give one'
                         % (g['position'], picks[0]))


def _setter(index, field, value, _self):
    '''A post-step: one field through the C++ setter (it needs the frame or
    the live camera: pin, unpin, re-pin).'''
    return lambda: lighting._light_set(index, field, value, _self=_self)


def _apply_light(where, rig, index, spec, change, _self, label):
    '''Put the parsed fields into light `index` of the new rig, and queue
    the post-steps that need the frame or the camera, in order: unpin
    first; orbit, pitch and radius on a pinned light re-pin it; pin last.'''
    light = rig['lights'][index]
    light.update(spec.values)
    if spec.name is not None:
        light['name'] = spec.name
    if spec.aim is not None:
        if spec.aim[0] == 'centre':
            light['aim'] = 'centre'
            light['aim_selection'] = ''
        else:
            light['aim'] = 'point'
            light['aim_point'] = list(spec.aim[1])
            light['aim_selection'] = spec.aim[2]

    pinned = light['anchor'] == 'pinned'
    place = [(f, spec.place[f]) for f in _PLACE if f in spec.place]
    pin_field = spec.given.get('pin', 'pin')
    if any(h in spec.helpers for h in _PICKS):
        pass    # the pick places the light (radius, pin): _apply_helpers
    elif spec.position is not None:
        light['anchor'] = 'pinned'
        light['position'] = list(spec.position)
    elif pinned and spec.pin is False:
        change.steps.append((label, pin_field, _setter(index, 'anchor', 0,
                                                       _self)))
        for f, v in place:
            change.steps.append((label, f, _setter(index, f, v, _self)))
    elif pinned:
        for f, v in place:
            change.steps.append((label, f, _setter(index, f, v, _self)))
    else:
        light.update(dict(place))
        if spec.pin:
            change.steps.append((label, pin_field, _setter(
                index, 'anchor', 1, _self)))

    if spec.values.get('shadow'):
        others = [l['name'] for i, l in enumerate(rig['lights'])
                  if l['shadow'] and i != index]
        if len(others) >= MAX_SHADOWS:
            raise _error(where, '%s: at most %d lights cast shadows (%s '
                         'already do)' % (spec.typed('shadow'), MAX_SHADOWS,
                                          ', '.join(others)))

    if spec.helpers:
        _apply_helpers(where, rig, index, spec, change, _self, label)


# --- placement helpers (spec section 5, with the native pick of #614) -------
#
# Each helper is resolved once, when it is given. The picks and selections
# are read in Phase 1 (the camera does not change during the call); the
# placement itself needs the rig's frame, which set_lights may capture, so
# it is a post-step. Helpers store a world aim point and leave a camera
# light (#610's anchoring decision): pin=1 pins it where it was placed, and
# target= keeps the light's anchor.

_FIT_MARGIN = 1.15      # beam fit: the cone covers the patch with 15 % spare
_TARGET_PAD = 1.5       # target=: the selection's radius plus this (A)
_PATCH = 10.0           # click= and highlight=: the patch radius (A)
_NEAR = 1.5             # highlight=: the hit within vdW + this of an atom (A)
_BEYOND = 0.5           # a raised radius: this many sizes past the point
_SURFACE_WORDS = 'a surface, cartoon, sphere or stick'


def _sub(a, b):
    return [x - y for x, y in zip(a, b)]


def _dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def _norm(a):
    return math.sqrt(_dot(a, a))


def _unit(a):
    n = _norm(a)
    return [x / n for x in a] if n > 0.0 else None


def _rows(cam):
    '''The camera's x, y and z axes in world space (rows of rot).'''
    rot = cam.rot
    return [list(rot[0:3]), list(rot[3:6]), list(rot[6:9])]


def _camera_world(cam):
    '''The camera's world position: origin - rot^T pos.'''
    rows = _rows(cam)
    return [cam.origin[i] - sum(rows[k][i] * cam.pos[k] for k in range(3))
            for i in range(3)]


def _towards_camera(cam, point, ortho):
    '''Unit direction from a world point to the camera: along the camera's
    z axis when orthoscopic (every ray runs along -z), else to the eye.'''
    if ortho:
        return _rows(cam)[2]
    return _unit(_sub(_camera_world(cam), point)) or _rows(cam)[2]


def _light_direction(normal, view, rim, cam):
    '''Where the light sits from the picked point (unit). rim 0 is the
    mirror rule, u = 2(N.V)N - V: the highlight lands on the point. A rim
    of deg degrees turns V by deg towards the surface's side, around the
    normal: u = V cos(deg) + side sin(deg), side = unit(N - V(N.V)), or
    the camera's right (then up) when N is along V.'''
    if not rim:
        nv = _dot(normal, view)
        return _unit([2.0 * nv * n - v for n, v in zip(normal, view)])
    side = None
    for axis in (normal,) + tuple(_rows(cam)[:2]):
        along = _dot(axis, view)
        rest = [a - along * v for a, v in zip(axis, view)]
        if _norm(rest) >= 1e-6:
            side = _unit(rest)
            break
    t = math.radians(rim)
    return _unit([v * math.cos(t) + s * math.sin(t)
                  for v, s in zip(view, side)])


def _viewport_aspect(_self):
    '''Scene width / height, as get_viewport reports it, read without
    logging or printing.'''
    with _self.lockcm:
        width, height = _self._cmd.get_viewport(_self._COb)
    if not (width > 0 and height > 0):
        return None
    return float(width) / float(height)


def _project(cam, point, ortho, aspect):
    '''(ndc_x, ndc_y, depth) of a world point, as the renderer projects it
    (metal_pick.camera; the orthoscopic half-height is the pick's
    max(1e-4, -pos.z) * tan(fov/2)).'''
    rows = _rows(cam)
    d = _sub(point, cam.origin)
    eye = [_dot(rows[k], d) + cam.pos[k] for k in range(3)]
    depth = -eye[2]
    if ortho:
        h = max(1e-4, -cam.pos[2]) * math.tan(math.radians(cam.fov) / 2.0)
    else:
        if not depth > 0.0:
            return None, None, depth
        h = depth * cam.tan_half
    return eye[0] / (h * aspect), eye[1] / h, depth


def _pick_selection(where, typed, sele, cam, ortho, _self):
    '''highlight=<sele>: the drawn surface under the selection's centroid,
    among the selection's objects; it must belong to the selection (within
    vdW + 1.5 A of one of its atoms).'''
    from . import metal_pick
    if _self.get_setting_int('grid_mode'):
        raise _error(where, '%s: not available in grid mode (each cell has '
                     'its own view); use click=x/y' % typed)
    atoms = _selection_model(where, typed.split('=', 1)[0], sele, _self)
    centre = _centroid([a.coord for a in atoms])
    aspect = _viewport_aspect(_self)
    if aspect is None:
        raise _error(where, '%s: the viewport has no size' % typed)
    x, y, depth = _project(cam, centre, ortho, aspect)
    if x is None:
        raise _error(where, '%s: the selection is behind the camera' % typed)
    if abs(x) > 1.0 or abs(y) > 1.0:
        raise _error(where, '%s: the selection is off screen (its centre is '
                     'at %.2f/%.2f; the viewport is -1 to 1)' % (typed, x, y))
    objects = _self.get_object_list(sele) or []
    hit = metal_pick.surface_at(x, y, aspect=aspect, objects=objects,
                                _self=_self)
    if hit is None:
        raise _error(where, '%s: nothing drawn as %s at the selection\'s '
                     'centre; show it (e.g. as sticks) or use click=x/y' % (
                         typed, _SURFACE_WORDS))
    gap = min(_norm(_sub(hit.point, a.coord)) - a.vdw for a in atoms)
    if gap > _NEAR:
        raise _error(where, "%s: the pick hit the %s of '%s' in front of "
                     "the selection; show the selection (e.g. as sticks) or "
                     "use click=x/y" % (typed, hit.rep, hit.object))
    return hit


def _current_radius(rig, light):
    '''A light's radius now: stored for a camera light, derived from where
    a pinned light is (clamped into 0.5 to 8, as an unpin does).'''
    if light['anchor'] == 'pinned' and rig.get('centre') is not None:
        r = _norm(_sub(light['position'], rig['centre'])) / rig['size']
        return min(8.0, max(0.5, r))
    return light['radius']


def _beam_fit(index, reach, _self):
    '''A post-step: the beam that covers a patch of radius `reach` (A) at
    the light's aim distance, clamped into 1 to 170 degrees.'''
    def step():
        eye = lighting._lights_eye(_self=_self)
        distance = eye['lights'][index]['aim_distance']
        if distance > 0.0:
            beam = 2.0 * math.degrees(math.atan(_FIT_MARGIN * reach /
                                                distance))
        else:
            beam = 170.0
        beam = min(170.0, max(1.0, beam))
        lighting._light_set(index, 'beam', beam, _self=_self)
    return step


def _place_step(where, index, typed, point, direction, radius, pin, change,
                _self):
    '''A post-step: put the light on the sphere of `radius` rig sizes around
    the rig centre, along `direction` from the picked `point`, then make it
    a camera light there unless `pin`. When the point is on or outside that
    sphere the radius is raised to |point - centre| / size + 0.5 (with a
    note); past 8 it is an error.'''
    def step():
        rig = lighting.get_lights(_self=_self)
        centre, size = rig['centre'], rig['size']
        if centre is None or not size:
            raise _error(where, '%s: the rig has no frame to place the '
                         'light in' % typed)
        offset = _sub(point, centre)
        far = _norm(offset)
        r = radius
        if far >= r * size:
            raised = far / size + _BEYOND
            if raised > 8.0:
                raise _error(where, "%s: the picked point is %.1f sizes from "
                             "the rig centre, too far to place the light "
                             "(at most 7.5); run 'lights recenter' first" % (
                                 typed, far / size))
            change.notes.append(
                ' %s: radius raised from %s to %s so the light sits beyond '
                'the picked point' % (where, _g(r), '%.3g' % raised))
            r = raised
        b = _dot(direction, offset)
        q = far * far - (r * size) ** 2
        t = -b + math.sqrt(b * b - q)
        position = [p + t * u for p, u in zip(point, direction)]
        lighting._light_set(index, 'position', position, _self=_self)
        if not pin:
            lighting._light_set(index, 'anchor', 0, _self=_self)
    return step


def _apply_helpers(where, rig, index, spec, change, _self, label):
    '''target=, click=, highlight=<sele> and rim=: resolve the pick or the
    selection now (Phase 1), store the aim point, and queue the placement
    and the beam fit.'''
    light = rig['lights'][index]
    helpers = spec.helpers
    fit = 'beam' not in spec.given

    if 'target' in helpers:
        sele = helpers['target']
        coords = _selection_atoms(where, spec.given['target'], sele, _self)
        centre = _centroid(coords)
        reach = max(_norm(_sub(c, centre)) for c in coords) + _TARGET_PAD
        light['aim'] = 'point'
        light['aim_point'] = centre
        light['aim_selection'] = sele
        if fit:
            change.steps.append((label, 'beam', _beam_fit(index, reach,
                                                          _self)))
        return

    from . import metal_pick
    cam = _camera(where, _self)
    ortho = bool(_self.get_setting_boolean('orthoscopic'))
    if 'click' in helpers:
        role, sele = 'click', ''
        typed = spec.typed(role)
        x, y = helpers['click']
        hit = metal_pick.surface_at(x, y, _self=_self)
        if hit is None:
            raise _error(where, 'nothing drawn as %s under %s' % (
                _SURFACE_WORDS, typed))
    else:
        role = 'highlight=<sele>'
        sele = helpers['highlight']
        typed = spec.typed(role)
        hit = _pick_selection(where, typed, sele, cam, ortho, _self)

    point = [float(c) for c in hit.point]
    normal = _unit(hit.normal) or _towards_camera(cam, point, ortho)
    view = _towards_camera(cam, point, ortho)
    direction = _light_direction(normal, view, helpers.get('rim', 0.0), cam)
    radius = spec.place.get('radius', _current_radius(rig, light))
    light['aim'] = 'point'
    light['aim_point'] = point
    light['aim_selection'] = sele
    change.notes.append(" %s: %s picked the %s of '%s' at %s" % (
        where, typed, hit.rep, hit.object, _xyz(point)))
    change.steps.append((label, spec.given[role], _place_step(
        where, index, typed, point, direction, radius, spec.pin, change,
        _self)))
    if fit:
        change.steps.append((label, 'beam', _beam_fit(index, _PATCH, _self)))


def _light_report(change, index, header, _self, returns_name):
    '''A finish(): print light `index` as it is now, under the lines
    header(name, rig) gives; return its name when `returns_name` (add),
    else None.'''
    def finish():
        rig = lighting.get_lights(_self=_self)
        light = rig['lights'][index]
        change.lines += header(light['name'], rig)
        change.lines += _light_lines(light, _eye_lights(rig, _self)[index])
        return light['name'] if returns_name else None
    return finish


# --- the transaction --------------------------------------------------------

class _Change(object):
    '''What one call does. `rig` is the new rig (a dict, None to remove the
    rig, or _KEEP); `steps` are (light, field, callable) run after it, in
    order; `lines` and then `notes` are printed unless quiet, `always`
    whatever quiet is; `finish` (run under the lock after the steps)
    returns the result and may add lines.'''

    def __init__(self, rig=_KEEP):
        self.rig = rig
        self.steps = []
        self.lines = []
        self.notes = []
        self.always = []
        self.result = None
        self.finish = None


_STATUSES = ('unknown field', 'bad index', 'refused', 'bad value', 'no rig')


def _rewrite(command, light, field, exc):
    '''The message of a C++ failure, as "lights: <light>: <field>: ..."'''
    message = (getattr(exc, 'message', '') or str(exc)).strip()
    if message.startswith('set_lights: '):
        return '%s: %s' % (command, message[len('set_lights: '):])
    for status in _STATUSES:
        if message == status or message.startswith(status + ': '):
            rest = message[len(status) + 2:] or status
            return ': '.join([command] + [p for p in (light, field) if p]
                             + [rest])
    if message.startswith(command + ': '):
        return message
    return '%s: %s' % (command, message)


def _apply(command, change, old, _self):
    '''Phase 2: replace the rig, run the steps; on any error put `old` back
    (exactly: set_lights round-trips get_lights) and raise.'''
    if change.rig is _KEEP and not change.steps:
        return
    light = field = ''
    try:
        if change.rig is not _KEEP:
            lighting.set_lights(change.rig, _self=_self)
        for light, field, step in change.steps:
            step()
    except Exception as exc:
        try:
            lighting.set_lights(old, _self=_self)
        except Exception:
            pass
        if isinstance(exc, CmdException):
            raise CmdException(_rewrite(command, light, field, exc)) from exc
        raise


def _run(command, quiet, _self, build):
    '''One call: Phase 1 (build), Phase 2 (_apply), print, return.'''
    with _self.lockcm:
        old = lighting.get_lights(_self=_self)
        table = _Fields(lighting._light_fields(_self=_self))
        change = build(old, table)
        _apply(command, change, old, _self)
        if change.finish is not None:
            change.result = change.finish()
    for line in change.always:
        print(line)
    if not quiet:
        for line in change.lines + change.notes:
            print(line)
    return change.result


# --- printing ---------------------------------------------------------------

def _xyz(v):
    return '(%s)' % ', '.join('%.2f' % (c + 0.0) for c in v)


def _g(x):
    return '%g' % (x + 0.0)


def _light_lines(light, eye):
    '''A light as three lines. `eye` is its _lights_eye() entry (for a
    pinned light's current orbit, pitch and radius), or None.'''
    name = light['name']
    kind = _reserved(name)
    tag = ' (shadowed by the %s)' % kind if kind else ''
    if light['anchor'] == 'pinned':
        place = 'pinned at %s' % _xyz(light['position'])
        if eye is not None:
            place += ', now orbit %s, pitch %s, radius %s' % (
                _g(eye['orbit']), _g(eye['pitch']), _g(eye['radius']))
    else:
        place = 'camera, orbit %s, pitch %s, radius %s' % (
            _g(light['orbit']), _g(light['pitch']), _g(light['radius']))
    if light['aim'] == 'point':
        aim = 'aim %s' % _xyz(light['aim_point'])
        if light['aim_selection']:
            aim += " from '%s'" % light['aim_selection']
    else:
        aim = 'aim centre'
    return [
        '   %s%s: %s, %s' % (name, tag, place, aim),
        '      beam %s, softness %s, color %s, warmth %s, intensity %s' % (
            _g(light['beam']), _g(light['softness']),
            '/'.join(_g(c) for c in light['color']), _g(light['warmth']),
            _g(light['intensity'])),
        '      highlight %s, falloff %s, shadow %s, outline %s' % (
            _g(light['highlight']), _g(light['falloff']),
            'on' if light['shadow'] else 'off',
            'on' if light['outline'] else 'off'),
    ]


def _eye_lights(rig, _self):
    '''_lights_eye()'s light entries when a light is pinned, else Nones.'''
    if any(l['anchor'] == 'pinned' for l in rig['lights']):
        eye = lighting._lights_eye(_self=_self)
        if eye and len(eye['lights']) == len(rig['lights']):
            return eye['lights']
    return [None] * len(rig['lights'])


def _air_line(air, prefix=' air: '):
    return prefix + ', '.join(
        '%s %s' % (k, v if isinstance(v, int) and not isinstance(v, bool)
                   else _g(v)) for k, v in air.items())


def _rig_lines(rig, _self):
    if rig is None:
        return [' lights: no light rig']
    n = len(rig['lights'])
    head = ' lights: %s, %s, ambient %s, classic %s' % (
        'on' if rig['enabled'] else 'off',
        '%d light%s' % (n, '' if n == 1 else 's') if n else 'no lights',
        _g(rig['ambient']), _g(rig['classic']))
    if rig.get('centre') is not None:
        head += ', centre %s, size %.2f A' % (_xyz(rig['centre']), rig['size'])
    lines = [head]
    if not n:
        lines.append('   (no lights: PyMOL\'s own lights are used until a '
                     'preset or "lights add")')
    for light, eye in zip(rig['lights'], _eye_lights(rig, _self)):
        lines += _light_lines(light, eye)
    lines.append(_air_line(rig['air']))
    return lines


def _off_note(rig, what):
    if _is_on(rig):
        return []
    return [' %s shows only while the lights are on (lights on, or a '
            'preset)' % what]


# --- lights -----------------------------------------------------------------

def lights(word='', light='', *extra, quiet=1, _self=cmd, **fields):
    '''
DESCRIPTION

    "lights" sets up studio lighting for the Metal renderer: a rig of up
    to six spot lights placed around the molecules, with presets, per-light
    edits and placement helpers. The rig belongs to the scene: .pse files
    and scenes save it and "reinitialize" clears it. It is not a setting
    and not an object, and it never changes colours or materials.

USAGE

    lights                               print the rig
    lights presets                       list the presets
    lights preset [, ambient=a] [, classic=c]
    lights add [, name] [, field=value ...]
    lights name                          print one light
    lights name, field=value [, field=value ...]
    lights remove, name
    lights on | off | clear | recenter
    lights ambient=a [, classic=c]       edit the rig

    Arguments are separated by commas, as in every PyMOL command:
    "lights key, orbit=-45, pitch=35", not "lights key orbit=-45".
    Keywords, presets and light names match ignoring case.

KEYWORDS

    add       add a light: lights add [, name] [, field=value ...]. Without
              a name it takes the first unused of key, fill, rim, light4,
              light5, light6 (name= works too). A rig holds at most 6
              lights. The first light captures the frame and turns the
              rig on; adding to a rig that is off leaves it off.
    remove    remove a light: lights remove, name
    presets   list the presets
    recenter  capture the rig's centre and size again from what is shown
              now (showing, hiding or zooming never moves the lights)
    on        turn the rig on again (it needs lights)
    off       turn the rig off and keep it: PyMOL's own lights are used
    clear     remove all lights. The rig keeps its air, ambient and classic
              and is off until "lights add" or a preset.

PRESETS

    A preset replaces the lights, ambient and classic, keeps the air, turns
    the rig on and captures the frame again. Only ambient= and classic=
    can be given with it; edit a light afterwards for anything else.

    three_point  Classic portrait: warm key with shadow, cool fill, white rim
    softbox      Product shot: two big soft white boxes, gentle top light
    spotlight    Theatre: one narrow beam from above, the rest falls off
    rembrandt    Dramatic: one hard warm key high to the side, almost no fill
    neon         Coloured rims: magenta and cyan from behind, dim violet front
    sunset       Low orange sun from one side, blue sky fill from the other
    underlight   Horror-film: green-tinted key from below, red rim

    spotlight aims its spot a little off the centre (0.25 sizes left, 0.15
    up, as the camera sees it when the preset is applied).

LIGHT FIELDS

    field (alias): unit, range, default. A number outside its range is an
    error (orbit wraps instead). Booleans take 1/0, on/off, true/false or
    yes/no.

    orbit (az)       degrees, -180 to 180 (wraps), default 0: 0 at the
                     camera, 90 camera-right, 180 behind (a rim)
    pitch (el)       degrees, -90 to 90, default 30: 0 level with the
                     camera, 90 above (relative to the camera's up)
    radius (dist)    scene sizes, 0.5 to 8, default 4 (1 is the edge of the
                     molecules)
    beam             degrees, full cone, 1 to 170, default 45; it stays
                     fixed when radius changes
    softness (soft)  fraction of the cone that fades out, 0 to 1, default 0.4
    color (colour)   sRGB, each channel 0 to 1, default white: a PyMOL
                     colour name, 0xRRGGBB or r/g/b. color=warm, neutral
                     or cool set white with warmth 3200, 6500 or 9000 K.
                     Names match ignoring case, and a unique start of a
                     name is enough (oran is orange). Colours that depend
                     on context (auto, current, default, atomic, object,
                     front, back) and colour numbers are refused.
    rgb              r/g/b or [r,g,b], each 0 to 1 (or whole numbers 0 to
                     255 when any is above 1); sets color
    warmth (kelvin)  kelvin, 1500 to 15000, default 6500 (neutral); it
                     multiplies color
    intensity (int)  0 to 4, default 1 (above about 2 clips)
    highlight (spec) strength of the coloured specular, 0 to 1, default 0.5.
                     A selection instead of a number places the light (see
                     PLACEMENT).
    falloff          exponent, 0 to 2, default 2: brightness goes as (aim
                     distance / distance)^falloff; 2 is inverse square, 0
                     is none
    shadow           boolean, default 0. At most 3 lights cast shadows.
    outline (cue)    boolean, default 0: draw the beam's outline on the
                     geometry
    aim              centre or center (default), a world point x/y/z or
                     [x,y,z] in Angstrom, or a selection: the light aims at
                     the selection's centroid as it is drawn now, each
                     object in the state it shows (aim again to follow
                     moved atoms). Parentheses force a selection:
                     aim=(1/2/3).
    pin              boolean: 1 pins the light to the molecules where it is
                     now, 0 makes it a camera light again (stored as anchor)
    anchor           camera (default) or pinned: the same as pin
    position         x/y/z or [x,y,z] in world Angstrom: pins the light
                     there
    name             renames the light: letters, digits and _, not starting
                     with a digit, at most 32 characters, unique ignoring
                     case, and not a preset or keyword

    A camera light follows the camera: orbit, pitch and radius place it
    around the rig centre as the camera sees it. A pinned light stays put
    in world space, so it turns with the molecules; "lights name" shows its
    current orbit, pitch and radius, and setting one of them moves it there
    and keeps it pinned. With pin=1, the light is placed first (orbit,
    pitch, radius) and then pinned; with pin=0, it is unpinned first.

    Fields that set the same thing cannot be given together: color with
    rgb, color=warm/neutral/cool with warmth, pin with anchor, position
    with orbit, pitch, radius or pin=0, and a field with its alias.

    Stored fields set by other forms (get_lights shows them):

    aim_point        the world point the light aims at, set by aim= and
                     the placement helpers
    aim_selection    the selection text aim_point came from (display only)

RIG FIELDS

    ambient          0 to 1, default 0.05: replaces the ambient setting
                     while the rig is on
    classic          0 to 1, default 0: scales PyMOL's own direct, reflect
                     and specular lights while the rig is on
    enabled          set by "lights on" and "lights off"
    centre           world Angstrom: the box midpoint of the enabled
                     objects, captured with the first light, by a preset
                     and by "lights recenter"
    size             Angstrom, at least 1: half the box diagonal, captured
                     with centre; radius is in multiples of it

    With no rig, "lights ambient=..." (like "atmosphere ...") creates an
    empty rig that is off and holds the value.

    The air (haze, dust, dust_size, dust_speed, scatter, seed) is set with
    "atmosphere".

PLACEMENT

    Helpers, resolved once when they are given (the light does not follow
    the atoms or the surface afterwards). highlight= and click= use the
    native surface pick: what is drawn as a surface, cartoon, spheres or
    sticks.

    target=sele      aim at the selection's centroid and fit the beam to
                     the selection (its radius plus 1.5 A); the light keeps
                     its anchor, orbit, pitch and radius
    highlight=sele   place the light so that the drawn surface at the
                     selection's centre (as the camera sees it) shows a
                     highlight: along the mirror direction of its normal.
                     The selection must be on screen, and the surface hit
                     must be its own (within 1.5 A of an atom's vdW
                     sphere). Not in grid mode (use click=).
    click=x/y        the same for the surface under a point of the
                     viewport: x and y from -1 to 1, 0/0 the centre, 1/1
                     the top right corner (in grid mode, of the whole grid)
    rim=deg          with highlight= or click=: turn the light deg degrees
                     (0 to under 180) away from the camera direction,
                     towards the side of the surface, for a rim light; 0 is
                     the mirror rule

    highlight= and click= store the picked point as the aim (aim_point)
    and place the light on its radius (radius= if given, else the light's
    own, 4 for a new light), as a camera light; add pin=1 to pin it there.
    When the picked point is on or beyond that radius, the radius is
    raised to put the light half a size past it, with a note; past 8 that
    is an error ("lights recenter" first). The beam is fitted to a 10 A
    patch around the point (for target=, to the selection) unless beam= is
    given. One helper at a time (rim goes with highlight or click); orbit,
    pitch and position cannot be given with highlight or click, and aim
    cannot be given with any helper.

EXAMPLES

    lights three_point
    lights key, orbit=-45, pitch=35, color=warm
    lights add, rim, orbit=160, pitch=30, color=cyan, intensity=2
    lights rim, shadow=1
    lights key, aim=organic
    lights key, pin=1
    lights key, target=organic
    lights add, spot, highlight=organic, beam=20
    lights rim, click=0.3/0.2, rim=150, pin=1
    lights remove, rim
    lights off
    lights neon, ambient=0.1; atmosphere haze=0.3, dust=0.5

NOTES

    Only the Metal renderer draws the rig. The CPU ray tracer (ray,
    png ..., ray=1, mpng) keeps PyMOL's own lights and prints a notice
    while the rig is on.

    The commands never write a setting, a colour or a material.

    Every error names the field or value and changes nothing. In a ";"
    chain PyMOL skips the rest of the line after an error.

    A light named after a keyword or preset (possible from set_lights or
    a session) is shadowed by it; "lights" marks it, and set_lights can
    rename it.

    "atmosphere" shares the abbreviation "at" with "attach": type "attach"
    in full.

PYMOL API

    cmd.lights(str word='', str light='', int quiet=1, **fields)

    Returns get_lights() for "lights", that light's dict for "lights name",
    [(name, description), ...] for "lights presets", the new light's name
    for "lights add", and None otherwise. From Python, field values may be
    numbers, bools and lists as well as text.

SEE ALSO

    atmosphere, get_lights, set_lights, scene
    '''
    quiet = _quiet('lights', quiet)
    word = _word(word)
    light = _word(light)
    _check_words('lights', [w for w in (word, light) if w], extra)
    fields = _lower_fields('lights', fields)
    if not word and light:
        raise _error('lights', "'%s' needs a word before it: "
                     "lights <name or keyword>, ..." % light)

    def build(old, table):
        key = word.lower()
        if not word:
            if not fields:
                return _query_rig(old, _self)
            return _edit_rig(old, table, fields)
        if key in KEYWORDS:
            return _KEYWORD_HANDLERS[key](old, table, light, fields, _self)
        if key in PRESETS:
            return _apply_preset(key, old, table, light, fields, _self)
        index = _find_light(old, word)
        if index is not None:
            if light:
                raise _error('lights', "too many arguments: '%s' after "
                             "the light '%s'" % (
                                 light, old['lights'][index]['name']))
            if not fields:
                return _query_light(old, index, _self)
            return _edit_light(old, table, index, fields, _self)
        raise _unknown_word(word, old, bool(fields))

    return _run('lights', quiet, _self, build)


def _unknown_word(word, rig, with_fields):
    names = [l['name'] for l in rig['lights']] if rig else []
    message = "no light, preset or keyword named '%s' (lights: %s; " \
        "presets: %s; keywords: %s)" % (
            word, ', '.join(names) if names else 'none',
            ', '.join(PRESETS), ', '.join(KEYWORDS))
    if with_fields:
        message += "; to add one: lights add, %s, ..." % word
    return _error('lights', message)


def _query_rig(old, _self):
    change = _Change()
    change.always = _rig_lines(old, _self)
    change.result = old
    return change


def _query_light(old, index, _self):
    change = _Change()
    light = old['lights'][index]
    change.always = [' lights: %s (%s)' % (
        light['name'], 'on' if old['enabled'] else 'rig off')]
    change.always += _light_lines(light, _eye_lights(old, _self)[index])
    change.result = light
    return change


def _edit_rig(old, table, fields):
    '''lights ambient=..., classic=...: with no rig, an empty rig that is off
    holds the values.'''
    values = {}
    for name, value in fields.items():
        if _field_class(name, table) != 'rig':
            raise _field_error('lights', name, value, table, 'rig')
        values[name] = table.parse('lights', 'rig', name, value)
    rig = copy.deepcopy(old) if old is not None else _empty_rig()
    rig.update(values)
    change = _Change(rig)
    change.lines.append(' lights: %s' % ', '.join(
        '%s %s' % (k, _g(v)) for k, v in values.items()))
    if old is None:
        change.lines.append(' lights: created a light rig that is off and has '
                            'no lights; a preset or "lights add" lights it')
    return change


def _edit_light(old, table, index, fields, _self):
    '''lights name, field=value ...: edit one light (and rename it).'''
    where = 'lights: %s' % old['lights'][index]['name']
    spec = _parse_light_fields(where, table, fields, _self)
    rig = copy.deepcopy(old)
    if spec.name is not None:
        _check_name(where, spec.name, rig['lights'], skip=index)
    change = _Change(rig)
    label = spec.name or old['lights'][index]['name']
    _apply_light(where, rig, index, spec, change, _self, label)
    typed = ', '.join(spec.given[role] for role in spec.given)
    change.finish = _light_report(change, index, lambda name, rig_now: [
        " lights: edited '%s' (%s)" % (name, typed)], _self, False)
    return change


def _apply_preset(name, old, table, light, fields, _self):
    where = 'lights: %s' % name
    if light:
        raise _error(where, "too many arguments: a preset takes no light name "
                     "('%s'); only ambient= and classic=" % light)
    description, ambient, preset_lights = PRESETS[name]
    rig = {
        'version': 1,
        'enabled': True,
        'centre': None,        # captured again by set_lights
        'size': None,
        'ambient': ambient,
        'classic': 0.0,
        'lights': copy.deepcopy(preset_lights),
    }
    if old is not None:
        rig['air'] = copy.deepcopy(old['air'])
    for field, value in fields.items():
        if _field_class(field, table) != 'rig':
            raise _field_error(where, field, value, table, 'preset')
        rig[field] = table.parse(where, 'rig', field, value)
    change = _Change(rig)
    names = [l['name'] for l in preset_lights]
    for light_name, offset in PRESET_AIMS.get(name, {}).items():
        index = names.index(light_name)
        change.steps.append((light_name, 'aim', _aim_offset_step(
            index, offset, _self)))
    change.lines.append(' lights: %s: %s (ambient %s, classic %s)' % (
        name, ', '.join(names), _g(rig['ambient']), _g(rig['classic'])))
    return change


# --- keywords ---------------------------------------------------------------

def _no_arguments(keyword, light, fields):
    if light or fields:
        given = ([light] if light else []) + ['%s=' % f for f in fields]
        raise _error('lights', '%s takes no arguments (got %s)' % (
            keyword, ', '.join(given)))


def _kw_add(old, table, light, fields, _self):
    where = 'lights: add'
    name = light
    if 'name' in fields:
        given = _word(fields.pop('name'))
        if name:
            raise _error(where, "the name is given twice ('%s' and name=%s)"
                         % (name, given))
        name = given
        if not name:
            raise _error(where, 'name= needs a value')
    lights_now = old['lights'] if old is not None else []
    if len(lights_now) >= MAX_LIGHTS:
        raise _error(where, 'the rig already has %d lights, the most it '
                     'holds' % MAX_LIGHTS)
    if name:
        _check_name(where, name, lights_now)
    spec = _parse_light_fields(where, table, fields, _self)
    # A full default light, so the field logic sees its anchor and
    # placement; without a name, set_lights assigns key, fill, rim, ...
    new_light = table.defaults('light')
    new_light.pop('name', None)
    if name:
        new_light['name'] = name
    if old is None:
        rig = {'version': 1, 'enabled': True, 'centre': None, 'size': None,
               'lights': [new_light]}
    else:
        rig = copy.deepcopy(old)
        if not rig['lights']:
            # the first light: capture the frame now, turn the rig on
            rig['enabled'] = True
            rig['centre'] = None
            rig['size'] = None
        rig['lights'].append(new_light)
    change = _Change(rig)
    index = len(rig['lights']) - 1
    _apply_light(where, rig, index, spec, change, _self, name or 'add')

    def header(added, rig_now):
        lines = [" lights: added '%s'" % added]
        if not rig_now['enabled']:
            lines.append(" lights: the rig is off ('lights on' shows it)")
        return lines

    change.finish = _light_report(change, index, header, _self, True)
    return change


def _kw_remove(old, table, light, fields, _self):
    where = 'lights: remove'
    if 'name' in fields:
        given = _word(fields.pop('name'))
        if light:
            raise _error(where, "the name is given twice ('%s' and name=%s)"
                         % (light, given))
        light = given
    if fields:
        raise _error(where, 'takes only a light name (got %s)' % ', '.join(
            '%s=' % f for f in fields))
    if not light:
        raise _error(where, 'which light? lights remove, <name>')
    index = _find_light(old, light)
    if index is None:
        names = [l['name'] for l in old['lights']] if old else []
        raise _error(where, "no light named '%s' (lights: %s)" % (
            light, ', '.join(names) if names else 'none'))
    rig = copy.deepcopy(old)
    removed = rig['lights'].pop(index)['name']
    change = _Change(rig)
    change.lines.append(" lights: removed '%s'" % removed)
    if not rig['lights']:
        _make_empty(rig)
        change.lines.append(" lights: no lights left: the rig is off and "
                            "PyMOL's own lights are used; 'lights add' or a "
                            "preset lights it again")
    return change


def _make_empty(rig):
    '''No lights: off, no frame (an empty rig has none until its first
    light); the air, ambient and classic are kept.'''
    rig['lights'] = []
    rig['enabled'] = False
    rig['centre'] = None
    rig['size'] = None


def _kw_presets(old, table, light, fields, _self):
    _no_arguments('presets', light, fields)
    change = _Change()
    change.always = [' lights: %d presets (lights <preset> applies one):'
                     % len(PRESETS)]
    width = max(len(name) for name in PRESETS)
    change.always += ['   %-*s  %s' % (width, name, description)
                      for name, description in presets()]
    change.result = presets()
    return change


def _kw_recenter(old, table, light, fields, _self):
    _no_arguments('recenter', light, fields)
    if old is None:
        raise _error('lights', 'no light rig to re-centre')
    change = _Change()
    change.steps.append(('', 'recenter',
                         lambda: lighting._lights_recenter(_self=_self)))

    def finish():
        rig = lighting.get_lights(_self=_self)
        change.lines.append(' lights: re-centred: centre %s, size %.2f A' % (
            _xyz(rig['centre']), rig['size']))
        return None

    change.finish = finish
    return change


def _kw_on(old, table, light, fields, _self):
    _no_arguments('on', light, fields)
    if old is None:
        raise _error('lights', "on: no light rig; apply a preset ('lights "
                     "presets' lists them) or 'lights add, <name>'")
    if not old['lights']:
        raise _error('lights', "on: the rig has no lights; apply a preset or "
                     "'lights add, <name>'")
    if old['enabled']:
        change = _Change()
        change.lines.append(' lights: already on')
        return change
    rig = copy.deepcopy(old)
    rig['enabled'] = True
    change = _Change(rig)
    change.lines.append(' lights: on')
    return change


def _kw_off(old, table, light, fields, _self):
    _no_arguments('off', light, fields)
    if old is None or not old['enabled']:
        change = _Change()
        change.lines.append(' lights: no light rig' if old is None
                            else ' lights: already off')
        return change
    rig = copy.deepcopy(old)
    rig['enabled'] = False
    change = _Change(rig)
    change.lines.append(" lights: off (the rig is kept; 'lights on' turns it "
                        "back on)")
    return change


def _kw_clear(old, table, light, fields, _self):
    _no_arguments('clear', light, fields)
    if old is None:
        change = _Change()
        change.lines.append(' lights: no light rig')
        return change
    rig = copy.deepcopy(old)
    _make_empty(rig)
    change = _Change(rig)
    change.lines.append(" lights: cleared: no lights, the rig is off; its "
                        "air, ambient and classic are kept ('atmosphere off' "
                        "resets the air)")
    return change


_KEYWORD_HANDLERS = {
    'add': _kw_add,
    'remove': _kw_remove,
    'presets': _kw_presets,
    'recenter': _kw_recenter,
    'on': _kw_on,
    'off': _kw_off,
    'clear': _kw_clear,
}


# --- atmosphere -------------------------------------------------------------

def atmosphere(word='', *extra, quiet=1, _self=cmd, **fields):
    '''
DESCRIPTION

    "atmosphere" sets the air of the light rig: haze and floating dust
    that the studio lights shine through. The air shows only while the
    lights are on (see "lights").

USAGE

    atmosphere                           print the air
    atmosphere field=value [, field=value ...]
    atmosphere off                       every field back to its default

    Arguments are separated by commas: "atmosphere haze=0.3, dust=0.5".

FIELDS

    field: range, default. A number outside its range is an error.

    haze        0 to 1, default 0: amount of haze in the air
    dust        0 to 1, default 0: amount of floating dust
    dust_size   0.05 to 2, default 0.35: size of the dust motes
    dust_speed  0 to 10, default 1: how fast the dust drifts
    scatter     -0.9 to 0.9, default 0.55: forward scattering (g); above 0
                the air glows more where a beam points towards the camera
    seed        whole number, 0 to 1000000, default 0: the dust pattern

    With no rig, "atmosphere field=..." creates a rig that is off and has
    no lights: the air shows once a preset or "lights add" turns it on.
    A preset keeps the air, and so do "lights off" and "lights clear";
    "atmosphere off" resets it.

EXAMPLES

    atmosphere haze=0.3, dust=0.5, dust_size=0.4, dust_speed=1
    atmosphere seed=7
    atmosphere off

NOTES

    Only the Metal renderer draws the air; the CPU ray tracer never does.
    The command never writes a setting. Every error names the field or
    value and changes nothing.

PYMOL API

    cmd.atmosphere(str word='', int quiet=1, **fields)

    Returns the air as a dict for "atmosphere" (None with no rig), and
    None otherwise.

SEE ALSO

    lights, get_lights, set_lights
    '''
    quiet = _quiet('atmosphere', quiet)
    word = _word(word)
    _check_words('atmosphere', [word] if word else [], extra)
    fields = _lower_fields('atmosphere', fields)

    def build(old, table):
        if not word:
            if not fields:
                change = _Change()
                if old is None:
                    change.always = [' atmosphere: no light rig']
                else:
                    change.always = [_air_line(old['air'], ' atmosphere: ')]
                    change.always += _off_note(old, 'atmosphere: the air')
                    change.result = old['air']
                return change
            return _edit_air(old, table, fields)
        if word.lower() != 'off':
            raise _error('atmosphere', "unknown keyword '%s': use 'atmosphere "
                         "off', or atmosphere field=value, ... (fields: %s)"
                         % (word, ', '.join(table.names('air'))))
        if fields:
            raise _error('atmosphere', 'off takes no fields (got %s)' %
                         ', '.join('%s=' % f for f in fields))
        if old is None:
            change = _Change()
            change.lines.append(' atmosphere: no light rig')
            return change
        rig = copy.deepcopy(old)
        rig['air'] = table.defaults('air')
        change = _Change(rig)
        change.lines.append(' atmosphere: off (no haze, no dust)')
        return change

    return _run('atmosphere', quiet, _self, build)


def _edit_air(old, table, fields):
    values = {}
    for name, value in fields.items():
        if _field_class(name, table) != 'air':
            raise _field_error('atmosphere', name, value, table, 'air')
        values[name] = table.parse('atmosphere', 'air', name, value)
    rig = copy.deepcopy(old) if old is not None else _empty_rig()
    if 'air' not in rig:
        rig['air'] = table.defaults('air')
    rig['air'].update(values)
    change = _Change(rig)
    change.lines.append(_air_line(values, ' atmosphere: '))
    if old is None:
        change.lines.append(' atmosphere: created a light rig that is off '
                            'and has no lights; a preset or "lights add" '
                            'lights it')
    change.lines += _off_note(rig, 'atmosphere: the air')
    return change


# --- completion -------------------------------------------------------------

def _lights_shortcut(self_cmd=cmd):
    '''The first argument of `lights`: keywords, presets and the rig's light
    names. Never raises.'''
    from pymol.shortcut import Shortcut
    words = list(KEYWORDS) + list(PRESETS)
    return Shortcut(words + _light_names(self_cmd, skip_reserved=True))


def _light_names_shortcut(self_cmd=cmd):
    '''Light names (`lights remove, <Tab>`). Never raises.'''
    from pymol.shortcut import Shortcut
    return Shortcut(_light_names(self_cmd))


def _light_names(self_cmd, skip_reserved=False):
    try:
        rig = lighting.get_lights(_self=self_cmd)
        names = [l['name'] for l in rig['lights']] if rig else []
    except Exception:
        return []
    if skip_reserved:
        names = [n for n in names if not _reserved(n)]
    return names
