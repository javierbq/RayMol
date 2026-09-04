"""Sequence-viewer data query for the native SwiftUI app.

Emits one residue row per *visible* molecular object (one guide atom per
residue, carrying its color index) for the SwiftUI SequencePanel. Visible means
enabled and not inside a disabled group — see `_visible_objects` (issue #380).
Mirrors the appkit_inspector / appkit_object_panel bundled-module pattern.

Alignment behavior (BIMO-style): an alignment object never appears as its own
row (it has no guide atoms, so it is naturally skipped). When an alignment
object is *enabled*, its member objects are re-laid-out with gap cells inserted
so that aligned residues share a column across the stacked rows. When the
alignment is disabled, members display normally with no gaps.

Writes the JSON to a temp file (same TMPDIR the Swift app reads) and the caller
prints the short `SEQPANEL:ready` marker — the payload can exceed PyMOL's ~1KB
feedback-line cap.
"""

from pymol import cmd

# A gap cell: empty chain/resi, resn '-' (the Swift parser renders it as a dim
# dash and excludes it from selection). color index '-1' has no color entry.
_GAP = ['', '', '-', '-1']


def _object_rows(names):
    """Per-object guide-residue rows + position lookup tables.

    Returns (out, cols, posmap) where
      out    = [{'name': str, 'residues': [[chain, resi, resn, colorIdx], ...]}]
      cols   = {colorIdx: None}  (filled with RGB tuples by the caller)
      posmap = {realname: {(chain, resi): row_index}}
    The display name may be remapped (theme-preview object -> 'example') but
    posmap is keyed by the *real* object name so alignment lookups still work.
    """
    out = []
    cols = {}
    posmap = {}
    for o in names:
        # Only molecular objects are rows. An alignment object spans its members'
        # atoms, so `(aln) and guide` would yield a bogus combined row — skip it
        # (BIMO: the alignment object is never shown as its own sequence).
        try:
            if cmd.get_type(o) != 'object:molecule':
                continue
        except Exception:
            continue
        r = []
        try:
            cmd.iterate('(%s) and guide' % o,
                        'r.append([chain, resi, resn, str(color)])',
                        space={'r': r})
        except Exception:
            pass
        # HETATM groups (co-crystal ligands, ions, waters) have no guide atom,
        # so the query above skips them entirely. Append one entry per
        # non-polymer residue (deduped, in atom order) tagged 'het' so they show
        # and are selectable in the sequence viewer like PyMOL — the Swift panel
        # spreads a het entry's 3-letter resn across columns (issue #201).
        try:
            het = []
            cmd.iterate('(%s) and not polymer and not hydro' % o,
                        'het.append([chain, resi, resn, str(color)])',
                        space={'het': het})
            seen = set()
            for e in het:
                key = (e[0], e[1], e[2])
                if key in seen:
                    continue
                seen.add(key)
                r.append([e[0], e[1], e[2], e[3], 'het'])
        except Exception:
            pass
        if not r:
            continue
        name = 'example' if o == '__theme_preview' else o
        out.append({'name': name, 'residues': r})
        posmap[o] = {(t[0], t[1]): i for i, t in enumerate(r)}
        for t in r:
            cols[t[3]] = None
    return out, cols, posmap


def _apply_alignments(out, posmap):
    """Rewrite member rows of each enabled alignment with gap-aligned columns.

    Mutates `out` in place: each aligned member's 'residues' list is replaced by
    an equal-length, gap-padded list so aligned residues line up column-wise.
    """
    try:
        enabled = set(cmd.get_names('public_objects', enabled_only=1) or [])
    except Exception:
        return
    alns = []
    for o in list(cmd.get_names('objects') or []):
        try:
            if cmd.get_type(o) == 'object:alignment' and o in enabled:
                alns.append(o)
        except Exception:
            pass
    if not alns:
        return

    # name -> the out dict (only displayed molecular objects)
    by_name = {d['name']: d for d in out}
    done = set()  # members already gap-aligned (first alignment wins)

    for aln in alns:
        try:
            raw = cmd.get_raw_alignment(aln)  # [[(model, atom_index), ...], ...]
        except Exception:
            continue
        if not raw:
            continue

        # Members of this alignment that are actually displayed and not yet done.
        members = []
        present_names = set()
        for col in raw:
            for mdl, _idx in col:
                present_names.add(mdl)
        for d in out:
            if d['name'] in present_names and d['name'] not in done \
                    and d['name'] in posmap:
                members.append(d['name'])
        if len(members) < 2:
            continue

        # atom index -> (chain, resi) per member, to resolve raw-alignment atoms.
        idxmap = {}
        for m in members:
            mm = {}
            try:
                cmd.iterate(m, 'mm[index] = (chain, resi)', space={'mm': mm})
            except Exception:
                pass
            idxmap[m] = mm

        # Per alignment column: {member: row_index}.
        colpos = []
        for col in raw:
            cmap = {}
            for mdl, idx in col:
                if mdl not in members or mdl in cmap:
                    continue
                cr = idxmap.get(mdl, {}).get(idx)
                if cr is None:
                    continue
                pos = posmap.get(mdl, {}).get(cr)
                if pos is None:
                    continue
                cmap[mdl] = pos
            if cmap:
                colpos.append(cmap)
        if not colpos:
            continue

        # Merge: walk alignment columns in order, flushing each member's leading
        # insertions (residues before its aligned anchor) as single-member
        # columns, then emit the shared aligned column.
        rows = {m: by_name[m]['residues'] for m in members}
        gapped = {m: [] for m in members}
        ptr = {m: 0 for m in members}

        def emit(present):
            for m in members:
                gapped[m].append(present.get(m, _GAP))

        for cmap in colpos:
            for m in members:
                target = cmap.get(m)
                if target is None:
                    continue
                while ptr[m] < target:
                    emit({m: rows[m][ptr[m]]})
                    ptr[m] += 1
            present = {}
            for m in members:
                target = cmap.get(m)
                if target is not None and ptr[m] == target:
                    present[m] = rows[m][target]
                    ptr[m] += 1
            if present:
                emit(present)
        # Trailing residues after the last aligned column.
        for m in members:
            while ptr[m] < len(rows[m]):
                emit({m: rows[m][ptr[m]]})
                ptr[m] += 1

        for m in members:
            by_name[m]['residues'] = gapped[m]
            done.add(m)


def _visible_objects():
    """Public objects that are actually DRAWN — the sequence panel's row set (#380).

    Two conditions, not one. `enabled_only=1` covers the object's own flag, but
    disabling a GROUP hides its members while leaving each member's own flag set
    (`ExecutiveGetNames` tests `rec->visible`, which the group cascade does not
    clear — verified 2026-09-04), so a member of a switched-off group would still
    get a row for something nowhere on screen. Walking the group chain and
    requiring every ancestor closes that.

    Reuses `appkit_inspector.group_parents`, which caches the (expensive)
    `get_session` parent walk behind a cheap tree-shape fingerprint — the
    inspector polls at the same cadence, so the map is normally already built.
    """
    try:
        enabled = set(cmd.get_names('public_objects', enabled_only=1) or [])
    except Exception:
        return []
    try:
        names = list(cmd.get_names('public_objects') or [])
    except Exception:
        return sorted(enabled)
    try:
        groups = list(cmd.get_names('public_group_objects') or [])
    except Exception:
        groups = []
    parents = {}
    if groups:
        try:
            from pymol import appkit_inspector
            parents = appkit_inspector.group_parents(names, groups) or {}
        except Exception:
            parents = {}
    gset = set(groups)
    out = []
    for o in names:
        # A group is a container, never a row (it has no atoms of its own), but it
        # still gates its members below — so it is excluded here, not earlier.
        if o not in enabled or o in gset:
            continue
        p = parents.get(o)
        seen = set()            # a corrupt parent map must terminate, not spin
        while p is not None and p not in seen:
            if p not in enabled:
                break
            seen.add(p)
            p = parents.get(p)
        else:
            out.append(o)
    return out


def _build(names, preview):
    out, cols, posmap = _object_rows(names)
    if not preview:
        _apply_alignments(out, posmap)
    for ci in list(cols.keys()):
        try:
            cols[ci] = cmd.get_color_tuple(int(ci))
        except Exception:
            cols[ci] = (0.8, 0.8, 0.8)
    return {'objects': out, 'colors': cols}


def poll(preview=False):
    """Write the sequence-panel JSON to a temp file; caller prints the marker.

    `preview` True reads only the reserved '__theme_preview' object (theme studio
    live preview); otherwise every visible public object.

    Only objects that are actually drawn get a row (issue #380) — a disabled
    object, or one inside a disabled group, contributes nothing to the viewport,
    so a sequence row for it is dead weight whose residue cells select atoms you
    cannot see. See `_visible_objects`.
    """
    import json
    import os
    import tempfile
    if preview:
        names = ['__theme_preview']
    else:
        names = _visible_objects()
    data = _build(names, preview)
    p = os.path.join(tempfile.gettempdir(), 'pymol_seq.json')
    with open(p, 'w') as f:
        f.write(json.dumps(data))
