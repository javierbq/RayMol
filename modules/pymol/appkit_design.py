"""Feed the macOS Binder Design bar: the registered generators, and a target
resolved exactly as `binder_design` resolves it.

The peer of `appkit_predict`, and deliberately the same mechanism: RayMol has no
Python->Swift call path, so the bar cannot ask a function for these values. It
triggers `emit(target, hotspots)` over runPython and reads the JSON this writes,
with only the short marker DESIGN_FORM:ready riding the feedback line (the payload
can exceed PyMOL's ~1KB cap).

Why resolve at all, rather than let Generate find out: every refusal in
`designing.resolve_target` and `parse_target` is one the user can fix by changing a
selection -- a hotspot outside the target, a second chain, a target with nothing
readable in it. Showing them BEFORE the run is the difference between a bar that
tells you what it will do and one that waits seventeen minutes to disagree.
"""

import json
import os
import tempfile

from pymol import cmd


def _generators():
    """[{'id': str}] for every registered generator that can ACTUALLY RUN here.

    Filtered by each generator's own `check_available()`, not merely by what is
    registered: the registry is platform-independent, but `rfd3` needs the Swift
    runtime that only the macOS build links, and under headless `pymol -c` nothing
    consumes the marker at all. Offering a method the host cannot run turns a clear
    "not in this build" into a menu entry that fails after the user has picked a
    target.

    Never raises: one bad method must not empty the whole menu, and a generator whose
    availability cannot be established is treated as unavailable -- the conservative
    direction.
    """
    from pymol.generators import registry
    out = []
    for gid in registry.available():
        try:
            generator = registry.get(gid)
        except Exception:
            continue
        try:
            generator.check_available()
        except Exception:
            continue
        out.append({'id': gid})
    return out


def _target(target_str, hotspots_str, generator_id):
    """({'residues','chain','state','hotspots','length_max'} or None, error).

    Resolved through `binder_design`'s OWN resolver and the generator's own
    `parse_target`, so the bar reports exactly what would be designed against --
    including the residues excluded because the engine cannot read them.

    Never raises: a bad selection is a message in the bar, not a crash in the poll.
    A throw here would also leave a stale or zero-byte payload behind.
    """
    target_str = (target_str or '').strip()
    hotspots_str = (hotspots_str or '').strip()
    # An EMPTY hotspot field is a resolvable form, not an unfinished one: no hotspots
    # means unguided placement, and the bar has to be able to show what that will design
    # against. Only the target is genuinely required.
    if not target_str:
        return None, None
    try:
        from pymol import designing
        from pymol.generators import registry
        structure = designing.resolve_target(target_str, hotspots_str, quiet=1,
                                             _self=cmd)
        summary = {
            'residues': structure.n_residues,
            'chain': structure.residues[0].chain if structure.residues else '',
            'state': structure.state,
            'hotspots': len(structure.hotspots),
        }
        # Validate against the METHOD too, at its default length, so a target that is
        # fine to read but too large to design is caught here rather than at Generate.
        # The length the user actually picked is checked on Run; this catches the
        # target-side ceilings, which are the ones a selection change fixes.
        if generator_id:
            try:
                generator = registry.get(generator_id)
                generator.parse_target(structure, 1)
            except Exception as exc:
                return summary, str(exc)
        return summary, None
    except Exception as exc:
        return None, str(exc)


def emit(target_str='', hotspots_str='', generator_id=''):
    """Write pymol_design_<pid>.json and print DESIGN_FORM:ready.

    Serialise BEFORE opening the file: open(..., 'w') truncates immediately, so a
    dumps() failure inside the `with` would leave a zero-byte file -- worse than a
    stale one. A process-local filename keeps multiple RayMol windows from
    overwriting each other's payload.
    """
    try:
        summary, error = _target(target_str, hotspots_str, generator_id)
        payload = {'generators': _generators(), 'target': summary, 'error': error}
        blob = json.dumps(payload)
        path = os.path.join(tempfile.gettempdir(),
                            'pymol_design_%d.json' % os.getpid())
        with open(path, 'w') as handle:
            handle.write(blob)
        print('DESIGN_FORM:ready')
    except Exception as exc:
        print('DESIGN_FORM:err:' + str(exc))
