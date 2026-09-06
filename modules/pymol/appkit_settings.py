"""Settings catalog for the native app's searchable Settings panel.

Enumerates every PyMOL setting (name, type, current value) and writes the list
to a temp JSON file (too large for the ~1 KB feedback buffer, like appkit's
sequence panel), then prints SETTINGS:ready. The Swift SettingsSheet reads the
file and edits values via set_value() → cmd.set.

Setting types (pymol.setting): 1 boolean, 2 int, 3 float, 4 float3, 5 color,
6 string.
"""
import json

from pymol import cmd
from pymol import raymol_tmp
from pymol import setting as _setting


def _path():
    return raymol_tmp.channel_path('pymol_settings')


def catalog():
    """Write [{name,type,val}] for all global settings; emit SETTINGS:ready."""
    out = []
    try:
        names = sorted(_setting.get_name_list())
    except Exception:
        names = []
    for name in names:
        try:
            t = int(cmd.get_setting_tuple(name)[0])
            v = cmd.get(name)
        except Exception:
            continue
        out.append({'name': name, 'type': t, 'val': '' if v is None else str(v)})
    try:
        with open(_path(), 'w') as f:
            f.write(json.dumps(out))
        print('SETTINGS:ready')
    except Exception as e:
        print('SETTINGS:err ' + str(e))


def set_value(name, value):
    """Set one global setting; emit the refreshed value as SETVAL:<name>=<val>."""
    try:
        cmd.set(name, value)
        v = cmd.get(name)
        print('SETVAL:%s=%s' % (name, '' if v is None else str(v)))
    except Exception as e:
        print('SETTINGS:err ' + str(e))
