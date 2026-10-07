'''
The app's Lights mode helpers (#619, #620, lighting epic #610).

The Lights bar runs the `lights` command (#612) for its buttons, and the
Atmosphere card (#726) the `atmosphere` command for its On/Off switch,
through the app's command line, so the console echoes each one. Python is
used for only four things, all here, each on a button press or once per
process:

* ``restore(json_b64)``: the bar's *Revert*. Puts back the rig the app read
  through PyMOLBridge_LightsJSON when the mode was entered ('null' when
  there was no rig). The JSON holds the shortest floats that read back
  exactly and set_lights stores in-range values unchanged, so the rig comes
  back byte for byte (the bridge JSON before entry equals the JSON after
  Revert).
* ``restore_light(json_b64, name)``: the inspector's *Revert this light*
  (#620). Takes the same entry JSON and puts back only the light of that
  name (matched ignoring case), at the index it has now. Every other light,
  `enabled`, the frame, `ambient`, `classic` and the air stay as they are
  now. It restores what the bridge setters cannot (the aim selection text,
  pin and aim together). Matching is by name: a light whose name did not
  exist at entry has nothing to go back to, and a default name that was
  removed and added again (`lights add` reuses the first free one) counts
  as the entry light of that name.
* ``write_presets(path_b64)``: writes the preset list for the bar's menu,
  once per process, as [{"name": n, "description": d}, ...] (the format the
  Swift side decodes).
* ``write_air_fields(path_b64)``: writes the air rows of the rig's field
  table (lighting._light_fields(), from C++) for the Atmosphere card, once
  per process, as [{"name", "kind", "default", "min", "max"}, ...]. The
  card's slider ranges and defaults come from here, so the app holds no
  copy of them.

They take base64 text, so the app never quotes JSON or a path into Python
source (the light name is checked to be a plain name on the Swift side).
Each prints at most one line, returns a bool and never raises: a Revert or a
menu load must not throw into the app.

Continuous edits (drags in the gizmo, orbit view, inspector and Atmosphere
card, and the steppers and typed values) never come here: they go through
the bridge setters, without Python (the air through the rig's setter,
index -1).

Only the module functions of pymol.lighting are called, with `_self`, never
cmd.set_lights (as lighting_commands asks). Nothing runs at import.
'''

import base64
import binascii
import json
import sys

from pymol import CmdException

from . import lighting

cmd = sys.modules["pymol.cmd"]


def _decode(text_b64):
    '''base64 (ASCII) -> UTF-8 text. Raises ValueError with a short reason.'''
    if isinstance(text_b64, bytes):
        text_b64 = text_b64.decode('ascii')
    try:
        raw = base64.b64decode(text_b64, validate=True)
    except (binascii.Error, ValueError, TypeError):
        raise ValueError('the payload is not base64')
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError:
        raise ValueError('the payload is not UTF-8 text')


def _reason(exc):
    if isinstance(exc, CmdException):
        return exc.message or exc.label
    text = str(exc)
    return text or type(exc).__name__


def restore(json_b64, *, _self=cmd):
    '''
    Replace the rig with the base64 of its bridge JSON ('null' removes it).
    Prints ' lights: reverted', or one ' lights: revert failed: <reason>'
    line and leaves the rig as it was (set_lights is atomic). Returns True
    on success; never raises.
    '''
    try:
        text = _decode(json_b64)
        if text.strip() == 'null':
            rig = None
        else:
            try:
                rig = json.loads(text)
            except ValueError as exc:
                raise ValueError('the payload is not JSON (%s)' % exc)
            if not isinstance(rig, dict):
                raise ValueError('the payload is not a rig (a JSON object '
                                 'or null)')
        lighting.set_lights(rig, _self=_self)
    except Exception as exc:
        print(' lights: revert failed: %s' % _reason(exc))
        return False
    print(' lights: reverted')
    return True


def _named(lights, name):
    '''The index of the light called `name` (ignoring case) in a list of
    light dicts, or None.'''
    key = name.lower()
    for index, light in enumerate(lights):
        if (isinstance(light, dict) and isinstance(light.get('name'), str)
                and light['name'].lower() == key):
            return index
    return None


def restore_light(json_b64, name, *, _self=cmd):
    '''
    Put back the light called `name` (ignoring case) as it was in the rig
    whose bridge JSON is in base64 (the JSON the app read when the mode was
    entered). The light keeps its index in the current rig; every other
    light and the rig's own fields (enabled, the frame, ambient, classic,
    air) are left as they are now. Prints ' lights: <name> reverted', or one
    ' lights: revert failed: <reason>' line and leaves the rig as it was
    (set_lights is atomic, so a 4th shadowed light is refused whole).
    Returns True on success; never raises.
    '''
    try:
        if not isinstance(name, str) or not name:
            raise ValueError('no light name given')
        text = _decode(json_b64)
        try:
            entry = json.loads(text)
        except ValueError as exc:
            raise ValueError('the payload is not JSON (%s)' % exc)
        if entry is None:
            raise ValueError('there was no rig when the mode was entered')
        if not isinstance(entry, dict) or not isinstance(
                entry.get('lights'), list):
            raise ValueError('the payload is not a rig (a JSON object with '
                             'a light list)')
        at = _named(entry['lights'], name)
        if at is None:
            raise ValueError("no light named '%s' when the mode was entered"
                             % name)
        light = entry['lights'][at]
        rig = lighting.get_lights(_self=_self)
        if rig is None:
            raise ValueError('there is no rig now')
        index = _named(rig['lights'], name)
        if index is None:
            raise ValueError("no light named '%s' now" % name)
        rig['lights'][index] = light
        lighting.set_lights(rig, _self=_self)
    except Exception as exc:
        print(' lights: revert failed: %s' % _reason(exc))
        return False
    print(' lights: %s reverted' % light['name'])
    return True


def write_presets(path_b64, *, _self=cmd):
    '''
    Write the presets of the `lights` command, in display order, as UTF-8
    JSON [{"name": n, "description": d}, ...] to the path in base64.
    Returns True on success; on any error prints one
    ' lights: presets failed: <reason>' line and returns False. Never raises.
    '''
    try:
        path = _decode(path_b64)
        from . import lighting_commands
        presets = [{'name': name, 'description': description}
                   for name, description in lighting_commands.presets()]
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(presets, handle, ensure_ascii=False)
    except Exception as exc:
        print(' lights: presets failed: %s' % _reason(exc))
        return False
    return True


def write_air_fields(path_b64, *, _self=cmd):
    '''
    Write the air rows of the rig's field table (the 'air' scope of
    lighting._light_fields(), in table order) as UTF-8 JSON
    [{"name": n, "kind": k, "default": d, "min": lo, "max": hi}, ...] to
    the path in base64: the ranges and defaults of the Atmosphere card
    (#726). Reads the table only; the rig is never touched. Returns True on
    success; on any error prints one ' lights: air fields failed: <reason>'
    line and returns False. Never raises.
    '''
    try:
        path = _decode(path_b64)
        rows = [{'name': name, 'kind': kind, 'default': default,
                 'min': lo, 'max': hi}
                for scope, name, kind, default, lo, hi
                in lighting._light_fields(_self=_self) if scope == 'air']
        if not rows:
            raise ValueError('the field table has no air fields')
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(rows, handle, ensure_ascii=False, allow_nan=False)
    except Exception as exc:
        print(' lights: air fields failed: %s' % _reason(exc))
        return False
    return True
