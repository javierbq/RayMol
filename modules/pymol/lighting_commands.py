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
'''

import copy
import math
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
    unit = _UNITS.get(field)
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

    def parse(self, where, scope, name, value):
        '''One value of a numeric or boolean field, strictly typed.'''
        kind, _default, lo, hi = self.scopes[scope][name]
        if kind == 'bool':
            return _parse_bool(where, name, value)
        if kind == 'int':
            return _parse_int(where, name, value, lo, hi)
        if kind in ('float', 'angle'):
            return _parse_number(where, name, value, lo, hi,
                                 angle=(kind == 'angle'))
        raise _error(where, '%s cannot be set this way' % name)

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


def _view_rows(_self):
    '''The rows of the model-to-camera rotation (camera x, y and z axes in
    world space), from this instance's get_view(). The rotation is
    column-major in both layouts (see metal_pick.camera).'''
    v = _self.get_view(quiet=1)
    if len(v) >= 25:
        return ((v[0], v[4], v[8]), (v[1], v[5], v[9]), (v[2], v[6], v[10]))
    return ((v[0], v[3], v[6]), (v[1], v[4], v[7]), (v[2], v[5], v[8]))


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


# --- the transaction --------------------------------------------------------

class _Change(object):
    '''What one call does. `rig` is the new rig (a dict, None to remove the
    rig, or _KEEP); `steps` are (light, field, callable) run after it, in
    order; `lines` are printed unless quiet, `always` whatever quiet is;
    `finish` (run under the lock after the steps) returns the result and may
    add lines.'''

    def __init__(self, rig=_KEEP):
        self.rig = rig
        self.steps = []
        self.lines = []
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
        for line in change.lines:
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
    rgb              r/g/b or [r,g,b], each 0 to 1 (or 0 to 255 when any is
                     above 1); sets color
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
                     the selection's centroid as it is now (aim again to
                     follow moved atoms). Parentheses force a selection:
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
    and keeps it pinned.

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

    Helpers, resolved once when they are given, with the native surface
    pick (the light does not follow the atoms afterwards):

    target=sele      aim at the selection's centroid and fit the beam to
                     it; the light keeps its anchor, orbit, pitch and radius
    highlight=sele   place the light where the selection shows a highlight:
                     along the mirror direction of the drawn surface the
                     camera sees at the selection's centre (not in grid
                     mode; the surface must belong to the selection)
    click=x/y        the same for the surface under a point of the
                     viewport, x and y from -1 to 1 (0/0 is the centre)
    rim=deg          with highlight= or click=: place the light deg degrees
                     (0 to under 180) away from the camera direction, around
                     the surface normal, instead; 0 is the mirror rule

    A helper stores the picked point as the aim (aim_point) and places a
    camera light (add pin=1 to pin it there). The beam is fitted (about a
    10 A patch for highlight and click) unless beam= is given. When the
    picked point lies beyond the light's radius, the radius is raised with
    a note; past 8 it is an error ("lights recenter" first). orbit and
    pitch cannot be given with highlight or click, and rim needs one of
    them.

EXAMPLES

    lights three_point
    lights key, orbit=-45, pitch=35, color=warm
    lights add, rim, orbit=160, pitch=30, color=cyan, intensity=2
    lights rim, shadow=1
    lights key, aim=organic
    lights key, pin=1
    lights add, spot, highlight=organic, beam=20
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
    '''lights name, field=value ...: the per-light edits (#612 part 2).'''
    raise _error('lights: %s' % old['lights'][index]['name'],
                 'light fields cannot be edited yet (%s)' % ', '.join(fields))


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
    if fields:
        raise _error(where, 'light fields cannot be given yet (%s); add the '
                     'light, then edit it' % ', '.join(fields))
    lights_now = old['lights'] if old is not None else []
    if len(lights_now) >= MAX_LIGHTS:
        raise _error(where, 'the rig already has %d lights, the most it '
                     'holds' % MAX_LIGHTS)
    if name:
        _check_name(where, name, lights_now)
    new_light = {'name': name} if name else {}
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

    def finish():
        added = lighting.get_lights(_self=_self)['lights'][-1]['name']
        change.lines.append(" lights: added '%s'" % added)
        if not rig['enabled']:
            change.lines.append(" lights: the rig is off ('lights on' shows "
                                "it)")
        return added

    change.finish = finish
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
