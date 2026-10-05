'''
The app's Lights mode helpers (#619, lighting epic #610).

The Lights bar runs the `lights` command (#612) for its buttons, through the
app's command line, so the console echoes each one. Python is used for only
two things, both here:

* ``restore(json_b64)``: *Revert*. Puts back the rig the app read through
  PyMOLBridge_LightsJSON when the mode was entered ('null' when there was no
  rig). The JSON holds the shortest floats that read back exactly and
  set_lights stores in-range values unchanged, so the rig comes back byte for
  byte (the bridge JSON before entry equals the JSON after Revert).
* ``write_presets(path_b64)``: writes the preset list for the bar's menu,
  once per process, as [{"name": n, "description": d}, ...] (the format the
  Swift side decodes).

Both take base64 text, so the app never quotes JSON or a path into Python
source. Both print at most one line, return a bool and never raise: a Revert
or a menu load must not throw into the app.

Continuous edits (drags in the gizmo, orbit view and inspector) never come
here: they go through the bridge setters, without Python.

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
