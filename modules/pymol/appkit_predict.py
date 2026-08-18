"""Feed the macOS Predict tool bar: the registered predictors, and the chains of
an input resolved exactly as `predict` resolves it.

RayMol has no Python->Swift call path, so the bar cannot ask a function for these
values; it triggers `emit(input)` over runPython and reads the JSON this writes,
exactly as the object panel does with `appkit_inspector.poll_panel()`. The payload
can exceed PyMOL's ~1KB feedback-line cap, so it rides a tempfile and only the
short marker PREDICT_FORM:ready rides the feedback line.
"""

import json
import os
import tempfile

from pymol import cmd


def _predictors():
    """[{'id': str, 'msa': bool}] for every registered predictor, sorted by id.

    `msa` is the method's own `supports_msa`: the bar disables the MSA controls for
    a method (e.g. protenix) that would refuse an alignment.
    """
    from pymol.predictors import registry
    out = []
    for pid in registry.available():
        try:
            p = registry.get(pid)
            supports = bool(getattr(p, 'supports_msa', False))
        except Exception:
            supports = False
        out.append({'id': pid, 'msa': supports})
    return out


def _chains(input_str):
    """([{'id','length','object','chain'}], error).

    Resolved through `predict`'s own resolver so the bar shows exactly what would be
    folded, down to how modified residues are substituted. `object`/`chain` are the
    source (object, chain id) each chain was read from -- empty for a literal
    sequence, which has no provenance. Never raises: a bad input is a message in the
    bar, not a crash in the poll (a throw would also leave a stale/zero-byte file).
    """
    text = (input_str or '').strip()
    if not text:
        return [], None
    try:
        from pymol.predicting import resolve_input
        from pymol.predictors.base import parse_chains
        sequence, sources = resolve_input(text, quiet=1, _self=cmd)
        chains = parse_chains(sequence)
        out = []
        for i, (cid, seq) in enumerate(chains):
            obj, chn = (sources[i] if i < len(sources) else ('', ''))
            out.append({'id': cid, 'length': len(seq),
                        'object': obj or '', 'chain': chn or ''})
        return out, None
    except Exception as exc:
        return [], str(exc)


def emit(input_str=''):
    """Write pymol_predict_<pid>.json and print PREDICT_FORM:ready.

    Serialise BEFORE opening the file: open(..., 'w') truncates immediately, so a
    dumps() failure inside the `with` would leave a zero-byte file -- worse than a
    stale one. A process-local filename keeps multiple RayMol windows from
    overwriting each other's payload.
    """
    try:
        chains, error = _chains(input_str)
        payload = {'predictors': _predictors(), 'chains': chains, 'error': error}
        blob = json.dumps(payload)
        p = os.path.join(tempfile.gettempdir(), 'pymol_predict_%d.json' % os.getpid())
        with open(p, 'w') as f:
            f.write(blob)
        print('PREDICT_FORM:ready')
    except Exception as exc:
        print('PREDICT_FORM:err:' + str(exc))
