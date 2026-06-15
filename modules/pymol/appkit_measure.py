"""Pick-driven measurement (distance / angle / dihedral) for the Metal app.

Accumulates atom-precise picks via metal_pick._pick_atom and, once enough atoms
are collected, emits the measurement with cmd.distance/angle/dihedral (whose
dashes + labels already render on Metal). Picks are highlighted in 'sele' so the
user sees what they've selected. Emits MEASURE:<json> feedback that
PyMOLEngine.parseMeasureFeedback() turns into the status text.
"""
from pymol import cmd
from pymol import metal_pick

_kind = 'distance'        # distance | angle | dihedral
_NEED = {'distance': 2, 'angle': 3, 'dihedral': 4}
_picks = []               # accumulated atom-expr strings
_counter = 0


def set_mode(kind):
    global _kind
    _kind = kind if kind in _NEED else 'distance'
    reset()


def reset():
    global _picks
    _picks = []
    _clear_sele()
    _emit()


def _clear_sele():
    try:
        if 'sele' in (cmd.get_names('selections') or []):
            cmd.select('sele', 'none')
            cmd.enable('sele')
    except Exception:
        pass


def _emit(value=None):
    import json
    d = {'kind': _kind, 'count': len(_picks), 'need': _NEED.get(_kind, 2)}
    if value is not None:
        d['value'] = value
    print('MEASURE:' + json.dumps(d))


def pick(ndc_x, ndc_y, aspect):
    """One measurement tap: pick the front-most atom and accumulate it."""
    global _picks
    try:
        best = metal_pick._pick_atom(ndc_x, ndc_y, aspect)
        if best is None:
            return
        _picks.append(metal_pick.atom_expr(best))
        # Highlight the accumulated picks so far.
        try:
            cmd.select('sele', ' or '.join(_picks))
            cmd.enable('sele')
        except Exception:
            pass
        if len(_picks) >= _NEED.get(_kind, 2):
            value = _commit(list(_picks))
            _picks = []
            _clear_sele()
            _emit(value)
        else:
            _emit()
    except Exception as e:
        print('MEASURE_ERR:' + str(e))


def _commit(picks):
    """Create the measurement object and return its value (rounded)."""
    global _counter
    _counter += 1
    try:
        if _kind == 'distance':
            v = cmd.distance('dist%02d' % _counter, picks[0], picks[1])
            return None if v is None else round(float(v), 2)
        if _kind == 'angle':
            v = cmd.angle('ang%02d' % _counter, picks[0], picks[1], picks[2])
            return None if v is None else round(float(v), 1)
        if _kind == 'dihedral':
            v = cmd.dihedral('dih%02d' % _counter, picks[0], picks[1], picks[2], picks[3])
            return None if v is None else round(float(v), 1)
    except Exception as e:
        print('MEASURE_ERR:' + str(e))
    return None


def clear_all():
    """Delete every measurement object (ObjectDist/angle/dihedral)."""
    try:
        for o in (cmd.get_names('objects') or []):
            try:
                if cmd.get_type(o) == 'object:measurement':
                    cmd.delete(o)
            except Exception:
                pass
    except Exception as e:
        print('MEASURE_ERR:' + str(e))
    reset()
