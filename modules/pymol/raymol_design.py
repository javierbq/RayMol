"""RayMol Design-mode core helpers: residue enumeration, coloring, and
exact visual-state save/restore. Mirrors the appkit_sequence bundled-module
pattern (writes JSON to TMPDIR, returns a short marker)."""
import base64
import hashlib
import json
import os
import tempfile

from pymol import cmd

# 3-letter -> MPNN alphabet index ("ACDEFGHIKLMNPQRSTVWYX", X=20).
_ONE = {'ALA': 'A', 'ARG': 'R', 'ASN': 'N', 'ASP': 'D', 'CYS': 'C', 'GLN': 'Q', 'GLU': 'E',
        'GLY': 'G', 'HIS': 'H', 'ILE': 'I', 'LEU': 'L', 'LYS': 'K', 'MET': 'M', 'PHE': 'F',
        'PRO': 'P', 'SER': 'S', 'THR': 'T', 'TRP': 'W', 'TYR': 'Y', 'VAL': 'V'}
_ALPHABET = "ACDEFGHIKLMNPQRSTVWYX"
_AA_INDEX = {c: i for i, c in enumerate(_ALPHABET)}
# MPNN alphabet index -> 3-letter resname (index 20 / 'X' -> 'UNK').
_ONE_LETTER_TO_THREE = {v: k for k, v in _ONE.items()}
_ONE_LETTER_TO_THREE['X'] = 'UNK'
_INDEX_TO_THREE = {i: _ONE_LETTER_TO_THREE.get(c, 'UNK') for i, c in enumerate(_ALPHABET)}

#: What ProteinMPNN measures, declared for the metric store (#308).
#:
#: Both are per RESIDUE and per STATE: the score depends on the backbone the sequence
#: was threaded onto, so a design run against model 2 of a five-model prediction is not
#: a statement about model 1. The domains are DesignColor.nativeFitDomain and
#: .certaintyDomain, kept in step with the Swift legend so a stored array colours the
#: same way the live panel did.
#:
#: Registered at import, not at first use: the object panel and `metrics_list` may meet
#: a run restored from a .pse before Design mode has been opened in this session.
_MPNN_TOOL = 'mpnn'
_MPNN_SPECS = (
    dict(key='native_fit', scope='residue', units='log P', label='Native fit',
         lo=-6.0, hi=0.0, higher_is_better=True, summarizes='mean',
         description='Log-probability MPNN assigns to the residue actually present,'
                     ' scored leave-one-out against the backbone.'),
    dict(key='certainty', scope='residue', label='Certainty', lo=0.0, hi=1.0,
         higher_is_better=True, summarizes='mean',
         description='1 - Shannon entropy / ln(21) over the 21-letter distribution:'
                     ' 0 is flat, 1 is one-hot.'),
)

try:
    from pymol.metrics import schema as _metric_schema
    _metric_schema.register(_MPNN_TOOL, [
        _metric_schema.MetricSpec(**spec) for spec in _MPNN_SPECS], replace=True)
except Exception as _mt_e:      # pragma: no cover - bookkeeping must never break design
    print(' design: could not declare MPNN metrics (%s)' % _mt_e)


def _tmp(name):
    return os.path.join(tempfile.gettempdir(), name)


def enumerate_design_residues(obj, state):
    state = int(state)
    # Guide atoms give one row per residue in canonical (chain, resv, inscode) order.
    order = []
    cmd.iterate('(%s) and polymer and guide' % obj,
                'order.append((chain, resi, resn))', space={'order': order})
    # Backbone atom coords for the same residues.
    atoms = {}

    def _collect(chain, resi, name, x, y, z):
        atoms.setdefault((chain, resi), {})[name] = (x, y, z)

    cmd.iterate_state(state, '(%s) and polymer and name N+CA+C+O' % obj,
                      '_collect(chain, resi, name, x, y, z)',
                      space={'_collect': _collect})
    residues = []
    for (chain, resi, resn) in order:
        bb = atoms.get((chain, resi), {})
        valid = all(k in bb for k in ('N', 'CA', 'C', 'O'))
        aa = _AA_INDEX.get(_ONE.get(resn, 'X'), 20)
        residues.append({
            'chain': chain, 'resi': resi, 'resn': resn, 'aa': aa, 'valid': valid,
            'n':  list(bb['N'])  if 'N'  in bb else None,
            'ca': list(bb['CA']) if 'CA' in bb else None,
            'c':  list(bb['C'])  if 'C'  in bb else None,
            'o':  list(bb['O'])  if 'O'  in bb else None,
        })
    with open(_tmp('raymol_design_residues.json'), 'w') as f:
        json.dump({'object': obj, 'state': state, 'residues': residues}, f)
    return 'DESIGN_RESIDUES:ready'


def _scope(obj, src):
    """Selection scope covering the target object and (if editing) its source.

    A region selection is normally made on the ORIGINAL object; once editing
    begins the focus is the working copy '<obj>_designNN', which has identical
    (chain, resi) residues. Scoping to both means selections made on either
    resolve to the target structure by residue identity, so the region does not
    vanish the moment a working copy is created.
    """
    if src and src != obj:
        return '((%s) or (%s))' % (obj, src)
    return '(%s)' % obj


def _residue_pred(chain, resi):
    """One residue as an object-free predicate, tolerating an empty chain id.

    Split out of _residue_sel so the same residue term can be intersected with
    either a single object or the whole _scope(obj, src) — see _scoped_residue_sel.
    """
    if chain:
        return 'chain %s and resi %s' % (chain, resi)
    return 'resi %s' % resi


#: mouse_selection_mode -> the selection keyword that expands one residue to what
#: a CLICK at that level means. Atom (0), residue (1) and C-alpha (6) have no
#: entry on purpose: as far as Design is concerned they ARE the residue (a lone
#: atom or a lone CA contains nothing designable, so a click at those levels would
#: otherwise select nothing at all).
_LEVEL_KEYWORD = {2: 'bychain', 3: 'bysegi', 4: 'byobject', 5: 'bymol'}


def _level_keyword():
    """The expansion keyword for the CURRENT selection level, or '' for residue."""
    try:
        return _LEVEL_KEYWORD.get(int(cmd.get_setting_int('mouse_selection_mode')), '')
    except Exception:
        return ''


def _scoped_level_sel(obj, chain, resi, src):
    """What a Design-mode CLICK on (chain, resi) designates, at the current level.

    'sele' IS the design region, so a click has to put in 'sele' exactly what a
    click puts there everywhere else in the app: in chain mode the chain, in
    object mode the object. Design used to force residue scope at every level,
    which left the region saying "one residue" while the mouse mode said "chains"
    and the viewport drew the whole chain pink -- the selection and the thing being
    designed disagreed, and only the click path was to blame.

    Re-derived from (obj, chain, resi) rather than shared with
    metal_pick._mode_expr because the design pick payload carries no atom name;
    the by* keywords need none, and expansion from any atom of the residue is the
    same set as expansion from the clicked atom for every level Design honours.

    The expansion happens INSIDE _scope(obj, src) and is re-intersected with it:
    the scope is what makes the write resolve where the read resolves (see
    _scoped_residue_sel), and expanding first would grow the intermediate
    selection through every object that happens to share a residue number before
    the scope narrowed it back to the same answer.
    """
    scope = _scope(obj, src)
    inner = '%s and (%s)' % (scope, _residue_pred(chain, resi))
    kw = _level_keyword()
    if not kw:
        return inner
    return '%s and (%s (%s))' % (scope, kw, inner)


def _scoped_residue_sel(obj, chain, resi, src):
    """One residue within the READ scope: the target object plus its edit source.

    Design-mode 'sele' READS resolve residues through _scope(obj, src) — by
    (chain, resi) IDENTITY across the working copy and the original — so the
    WRITES must use the same scope or the two disagree the moment an edit session
    repoints the focus at the working copy while the selection still sits on the
    original's atoms.  Writing object-scoped there made a region member impossible
    to remove (the toggle saw no focus-object atoms in 'sele', so it ADDED them,
    and the read deduped the result back to the same region) and let a repack's
    topology replace silently drop residues clicked during the session, because
    their only 'sele' membership lived on the atoms the replace annihilated.
    """
    return '%s and (%s)' % (_scope(obj, src), _residue_pred(chain, resi))



def _obj_residue_order(obj):
    """(chain, resi) for obj's polymer residues in canonical guide order —
    the same order enumerate_design_residues emits, so indices align with the
    Swift DesignResidueSet.residues array."""
    order = []
    try:
        cmd.iterate('(%s) and polymer and guide' % obj,
                    'order.append((chain, resi))', space={'order': order})
    except Exception:
        return []
    return order


# Design mode active? The selection digest below is O(selected residues) and is
# called from appkit_inspector.poll_panel, which runs on the MAIN thread every
# 500 ms and is a measured hot spot (PR #270). Gating on this flag keeps the cost
# at a single boolean check whenever Design mode is not on. A list rather than a
# bare module global so the setter never needs `global`.
_DESIGN_ACTIVE = [False]


def set_design_active(on):
    """Arm or disarm the Design-mode 'sele' digest computed by poll_panel."""
    _DESIGN_ACTIVE[0] = bool(on) if isinstance(on, bool) else bool(int(on))
    return 'DESIGN_ACTIVE:%d' % (1 if _DESIGN_ACTIVE[0] else 0)


def _sele_residue_keys():
    """Sorted, de-duplicated (model, chain, resi) of the active 'sele's residues.

    '?sele' rather than 'sele' so a session that has never had a selection yields
    [] instead of raising. Guide atoms only, plus set(), so the key set is one
    entry per residue regardless of how many of its atoms (or altloc guides) the
    user picked.

    Keyed on the RAW model name, deliberately: this is what the change digest is
    built from, so it must be at least as sensitive as the state it guards. Two
    independent objects that merely look like a working-copy pair ('foo' and
    'foo_design') must not collapse, or moving the same residue selection from one
    to the other would leave the digest unchanged, the poll would skip the
    re-derive, and the region would never arm. The consequence — one residue marked
    on BOTH a working copy and its original counts twice here — is handled where
    the information to handle it exists: sele_design_indices knows `obj` and `src`
    and reports the off-scope count directly as `n_off`.
    """
    keys = []
    try:
        cmd.iterate('(?sele) and polymer and guide',
                    'keys.append((model, chain, resi))', space={'keys': keys})
    except Exception:
        return []
    return sorted(set(keys))


def _digest_of(keys):
    """Stable short fingerprint of a residue-key list."""
    return '%d:%s' % (len(keys),
                      hashlib.md5(repr(keys).encode('utf-8')).hexdigest()[:16])


def sele_digest():
    """Fingerprint of the active 'sele' residue set, or '' when Design is off.

    Used purely for change detection: the Swift side re-derives its selection
    state only when this value differs from the last one it saw.
    """
    if not _DESIGN_ACTIVE[0]:
        return ''
    return _digest_of(_sele_residue_keys())


def sele_design_indices(obj, state, src=''):
    """Map the active 'sele' -> full-length residue indices in obj's guide order.

    Hard-wired to 'sele': the viewer's ordinary selection is the single source of
    truth for what Design mode is working on, and the only one — there is no
    named-selection path. Scoped through _scope(obj, src) so a selection made
    on the ORIGINAL object still maps onto a focused working copy by (chain, resi)
    identity once an edit session has begun.

    Output: $TMPDIR/raymol_design_sele.json =
        {'indices': [int], 'digest': str, 'n_total': int}
      indices  - 'sele' within the scope, as 0-based indices into obj's guide order
      digest   - fingerprint of the WHOLE 'sele' residue set (all objects)
      n_off    - residues in 'sele' that lie OUTSIDE the scope (on neither obj nor
                 src), so the caller can say "selected, but on another structure"
                 instead of silently ignoring them. Computed from the model names
                 directly; do NOT reconstruct it as n_total - len(indices).
      n_total  - count of distinct (model, chain, resi) keys in 'sele' across all
                 objects. NOT a residue count: during an edit session one residue
                 marked on both the working copy and the original counts twice
                 here, which is exactly why n_off exists as its own field

    `state` is accepted for signature symmetry with enumerate_design_residues but
    is unused: guide order is read from the current state.
    Returns 'DESIGN_SELE:<n>'.
    """
    order = _obj_residue_order(obj)
    scope = _scope(obj, src)
    sel_res = set()
    try:
        cmd.iterate('%s and (?sele) and polymer and guide' % scope,
                    'sel_res.add((chain, resi))', space={'sel_res': sel_res})
    except Exception:
        pass
    indices = [i for i, cr in enumerate(order) if cr in sel_res]
    keys = _sele_residue_keys()
    # Off-scope count straight from the model names. A residue marked on BOTH the
    # working copy and the original is in scope on both, so it is excluded here by
    # construction — no de-duplication of the key set required, and none performed
    # (the digest must stay maximally sensitive).
    in_scope = set([obj]) | (set([src]) if src else set())
    n_off = sum(1 for m, _c, _r in keys if m not in in_scope)
    payload = {'indices': indices,
               'digest': _digest_of(keys),
               'n_off': n_off,
               'n_total': len(keys)}
    try:
        with open(_tmp('raymol_design_sele.json'), 'w') as f:
            json.dump(payload, f)
    except Exception:
        pass
    return 'DESIGN_SELE:%d' % len(indices)


def toggle_sele_residue(obj, chain, resi, src=''):
    """Add or remove one CLICK's worth of atoms in the active 'sele'.

    Deliberately mirrors metal_pick.pick_at's toggle idiom so that a click means
    the same thing in Design mode as in normal mode: already selected -> remove,
    otherwise add, at the level `mouse_selection_mode` names (see
    _scoped_level_sel -- in chain mode this designates the chain, not the one
    residue under the pointer). Always leaves 'sele' enabled so the renderer's
    pink committed pass draws it.

    `src` is the edit-session source object, and it is what makes the toggle
    ACTUALLY a toggle: the residue is resolved through _scoped_residue_sel, the
    same scope sele_design_indices reads, so membership is tested and cleared on
    the working copy AND the original together. See _scoped_residue_sel for what
    an object-scoped write broke. Returns 'DESIGN_SELE_TOGGLE:on' or ':off'.
    """
    expr = '(%s)' % _scoped_level_sel(obj, chain, resi, src)
    try:
        already = cmd.count_atoms('(?sele) and %s' % expr) > 0
    except Exception:
        already = False
    if already:
        cmd.select('sele', '(?sele) and not %s' % expr, enable=1)
    else:
        cmd.select('sele', '(?sele) or %s' % expr, enable=1)
    return 'DESIGN_SELE_TOGGLE:%s' % ('off' if already else 'on')


def set_sele_residue(obj, chain, resi, src=''):
    """Replace the active 'sele' with exactly one click's worth of atoms.

    Used when a Design-mode click lands on a DIFFERENT object than the current
    focus: design retargets to that object and the selection starts fresh there,
    so residues of the previous focus never linger in the region.
    Scoped through `src` for the same reason toggle_sele_residue is — the write
    must be visible to a read that resolves by residue identity across an edit
    session's working copy and its original. Returns 'DESIGN_SELE_SET:ok'.
    """
    cmd.select('sele', _scoped_level_sel(obj, chain, resi, src), enable=1)
    return 'DESIGN_SELE_SET:ok'


def drop_object_from_sele(obj):
    """Narrow the active 'sele' so none of `obj`'s atoms are in it.

    Called when an edit session ENDS by keeping the working copy. A residue added
    during a session is deliberately marked on both the copy and the original (that
    is what survives a repack), but the Keep path clears `editSourceObject` while
    the copy lives on — so from then on no Design write can address the copy, and a
    click that removes a region member would leave it selected and pink there, with
    a spurious off-structure badge and no way to clear it from the UI. Narrowing at
    teardown keeps the invariant that 'sele' membership only ever lives on objects
    the current scope can address.

    enable follows emptiness: an enabled EMPTY 'sele' would suppress every other
    selection, because cmd.enable is exclusive for selections.
    Returns 'DESIGN_SELE_DROP:<remaining atoms>'.
    """
    try:
        n = cmd.select('sele', '(?sele) and not (%s)' % obj, enable=1) or 0
    except Exception:
        return 'DESIGN_SELE_DROP:err'
    if not n:
        cmd.select('sele', 'none', enable=0)
    return 'DESIGN_SELE_DROP:%d' % n


def clear_sele():
    """Empty the active 'sele' (a Design-mode click on empty space).

    enable=0 — deliberately NOT what metal_pick.pick_at does (it leaves 'sele'
    enabled and empty): there is nothing left to draw, and an enabled empty
    selection would still suppress every other selection, because cmd.enable is
    exclusive for selections.
    Returns 'DESIGN_SELE_CLEAR:ok'.
    """
    cmd.select('sele', 'none', enable=0)
    return 'DESIGN_SELE_CLEAR:ok'


def resolve_target(expr_b64):
    """Resolve a target expression to the ONE object Design will work on (#371).

    Backs the target text box, which accepts an object name OR any selection
    expression — 'polymer and chain A', a named selection, '1abc and chain B'.
    Design itself only ever works on one focused structure, so a multi-object
    expression narrows to the first object rather than failing; `n_objects` reports
    that it narrowed, so the caller can say so.

    The argument is base64 of UTF-8: it is USER text that the Swift side
    interpolates into a runPython string, where a quote or a backslash would
    otherwise end the literal.

    Output: $TMPDIR/raymol_design_target.json =
        {'object': str, 'n_objects': int, 'error': str}
      object     - the resolved object name, '' when nothing matched
      n_objects  - how many objects the expression covered
      error      - why it resolved to nothing (a rejected selector, or no match)
    Returns 'DESIGN_TARGET:<object>'.
    """
    payload = {'object': '', 'n_objects': 0, 'error': ''}
    try:
        expr = base64.b64decode(expr_b64).decode('utf-8')
    except Exception as e:
        expr, payload['error'] = '', 'undecodable expression (%s)' % e
    if expr:
        try:
            names = cmd.get_object_list('(%s)' % expr) or []
        except Exception as e:
            # A rejected selector, an unknown name, an unbalanced paren: all the
            # same to the field, which just needs something to show the user.
            payload['error'] = str(e) or 'invalid selection'
        else:
            payload['n_objects'] = len(names)
            if names:
                payload['object'] = names[0]
            else:
                payload['error'] = 'no structure matches'
    try:
        with open(_tmp('raymol_design_target.json'), 'w') as f:
            json.dump(payload, f)
    except Exception:
        pass
    return 'DESIGN_TARGET:%s' % payload['object']


def select_region(expr_b64):
    """Point the active 'sele' at `expr` (#371).

    Backs the region text box. It WRITES 'sele' rather than keeping a second
    region of its own, which is the whole point: typing an expression and clicking
    residues then feed one pipeline, and everything downstream —
    sele_design_indices, the digest-gated poll, the pink markers — is untouched.

    Base64 for the same reason resolve_target takes it. A rejected selector leaves
    the live selection exactly as it was.

    enable follows emptiness, as in drop_object_from_sele: an enabled EMPTY 'sele'
    would suppress every other selection, because cmd.enable is exclusive for
    selections.

    Output: $TMPDIR/raymol_design_select.json = {'ok': bool, 'count': int, 'error': str}
      ok     - the selector was accepted (a valid expression matching nothing is
               ok=True, count=0 — that is an empty region, not a mistake)
      count  - atoms now in 'sele'
    Returns 'DESIGN_SELECT:<count>' or 'DESIGN_SELECT:err'.
    """
    payload = {'ok': False, 'count': 0, 'error': ''}
    try:
        expr = base64.b64decode(expr_b64).decode('utf-8')
    except Exception as e:
        expr, payload['error'] = '', 'undecodable expression (%s)' % e
    if expr:
        try:
            n = int(cmd.select('sele', '(%s)' % expr, enable=1) or 0)
        except Exception as e:
            payload['error'] = str(e) or 'invalid selection'
        else:
            payload['ok'] = True
            payload['count'] = n
            if not n:
                cmd.select('sele', 'none', enable=0)
    try:
        with open(_tmp('raymol_design_select.json'), 'w') as f:
            json.dump(payload, f)
    except Exception:
        pass
    return 'DESIGN_SELECT:%d' % payload['count'] if payload['ok'] else 'DESIGN_SELECT:err'


def _record_design_metrics(obj, metric, rows, state=0):
    """Keep a scored design pass in the metric store. Never raises.

    The FULL index goes in, masked residues included, with their value as None. Absent
    is not zero: a residue with no backbone was not scored, and recording it as 0.0
    would put a real-looking number -- a terrible native fit -- where there is no
    measurement. `MetricValue.as_map()` drops them again for colouring.

    One run per scored pass, so re-scoring after a mutation is a new run rather than an
    overwrite: that history is the point of a design session.
    """
    if not metric:
        # An older caller that does not say which score it is passing. Recording it
        # under a guessed key would put native-fit numbers in a certainty column.
        return None
    try:
        from pymol.metrics import binding
        from pymol.metrics import store as metric_store
        if not state:
            state = cmd.get_state()
        index, values = [], []
        for row in rows:
            index.append((row['chain'], row['resi']))
            values.append(row.get('value'))
        value = metric_store.value(_MPNN_TOOL, metric, state=int(state),
                                   index=index, values=values)
        return binding.record(obj, _MPNN_TOOL, [value],
                              inputs={'metric': metric, 'n_scored': len(
                                  [v for v in values if v is not None])})
    except Exception as exc:
        print(' design: could not record %s metrics for %s (%s)' % (metric, obj, exc))
        return None


def apply_design_coloring(obj, values_json_path, palette, lo, hi, metric='',
                          state=0):
    """Write per-residue scalar and apply spectrum coloring.

    values_json_path: path to JSON list of {'chain', 'resi', 'value'} dicts.
    palette: PyMOL palette name (e.g. 'blue_white_red').
    lo, hi: domain min/max used by the Swift legend; passed to spectrum when
            minimum/maximum kwargs are supported, otherwise auto-scaling is used.
    metric: which score these values are — 'native_fit' or 'certainty'
            (DesignColorMeaning). Recorded in the metric store under that name;
            empty means "do not record", which is what an older caller gets.
    state: the model the scores were computed against {default: 0, the displayed
            state}.
    Returns 'DESIGN_COLOR:ok'.

    Storage: the METRIC STORE owns these values (#308) — they are recorded against
    the object before anything is coloured, so they survive a .pse, can be exported,
    and can be re-applied with metrics_color after another tool has coloured over the
    column. The p.mpnn_conf / B-factor write below is a rendering channel only.

    That distinction matters because neither write is a record. `p.mpnn_conf` is per
    ATOM: it carries no run, no units and no provenance, and it does not survive a .pse.
    And `b` — which is where these scores land on a build WITHOUT p.* properties, i.e.
    stock open-source PyMOL rather than RayMol's own build — is one unlabelled scalar
    per atom, so there the design score displaces whatever a prediction left in it, with
    nothing saying the column had changed meaning.

    Spectrum is run only over scored polymer residues — masked residues and
    non-polymer atoms (ligands, ions, waters) keep their baseline color.
    """
    # -- Fix 1: Un-dim -- reset this object's transparency settings back to the
    # snapshot baseline so a previously-dimmed object is fully visible when it
    # becomes the focus.  If the snapshot is absent (e.g. loaded mid-mode) or
    # the object is not recorded in it, skip gracefully.
    snap_path = _tmp('raymol_design_snapshot.json')
    if os.path.exists(snap_path):
        try:
            with open(snap_path) as _snap_f:
                snap = json.load(_snap_f)
            baseline = snap.get('settings', {}).get(obj)
            if baseline:
                for s, v in baseline.items():
                    try:
                        cmd.set(s, float(v), obj)
                    except Exception:
                        pass
        except Exception:
            pass

    with open(values_json_path) as f:
        rows = json.load(f)
    # Build vmap only for rows that carry an actual score value.  Rows with
    # value=null represent masked (missing-backbone) residues and are excluded.
    vmap = {(r['chain'], r['resi']): float(r['value'])
            for r in rows if r.get('value') is not None}

    if not vmap:
        # No scored residues; nothing to alter or spectrum.
        return 'DESIGN_COLOR:ok'

    # Record BEFORE colouring, so the numbers are kept even if the spectrum call
    # cannot run (an unknown palette, a build without minimum/maximum). The store is
    # where they live; the colour is a view of them.
    _record_design_metrics(obj, metric, rows, state)

    # -- Fix 2: Build a selection of exactly the scored polymer residues so
    # that masked residues and all non-polymer atoms keep their baseline color
    # instead of being clamped to the first palette color (the -9999 sentinel).
    from collections import defaultdict
    chain_resis = defaultdict(list)
    for (chain, resi) in vmap:
        chain_resis[chain].append(resi)

    chain_parts = []
    for ch, resis in chain_resis.items():
        resi_str = '+'.join(str(r) for r in resis)
        if ch:
            chain_parts.append('(chain %s and resi %s)' % (ch, resi_str))
        else:
            # Empty chain: select by resi only.
            chain_parts.append('(resi %s)' % resi_str)
    scored_sel = '(%s) and polymer and (%s)' % (obj, ' or '.join(chain_parts))

    def _lookup(chain, resi):
        return vmap.get((chain, resi), -9999.0)

    # Attempt incentive-only per-atom property first; fall back to B-factor.
    prop_field = 'p.mpnn_conf'
    try:
        cmd.alter(scored_sel, 'p.mpnn_conf = _lookup(chain, resi)',
                  space={'_lookup': _lookup})
    except Exception as e:
        if 'IncentiveOnly' not in type(e).__name__:
            raise
        # Open-Source PyMOL raises IncentiveOnlyException for p.* properties;
        # fall back to storing values in the B-factor column instead.
        prop_field = 'b'
        cmd.alter(scored_sel, 'b = _lookup(chain, resi)',
                  space={'_lookup': _lookup})

    try:
        cmd.spectrum(prop_field, palette, scored_sel,
                     minimum=float(lo), maximum=float(hi))
    except TypeError:
        # This PyMOL build does not support minimum/maximum kwargs;
        # spectrum auto-scales over the values present. The Swift legend
        # still uses the lo/hi domain it passed.
        cmd.spectrum(prop_field, palette, scored_sel)

    return 'DESIGN_COLOR:ok'


# ---------------------------------------------------------------------------
# Visual-state save / dim / restore  (Task 7)
# ---------------------------------------------------------------------------
# Transparency setting names that are saved and restored per-object.
_TRANSP = [
    'cartoon_transparency',
    'transparency',
    'stick_transparency',
    'sphere_transparency',
    'ribbon_transparency',
    'surface_transparency',
]


def _get_transp_settings(obj):
    """Return a dict of {setting_name: float} for all known transparency settings.

    Silently skips any setting name unknown to this PyMOL build (e.g.
    'surface_transparency' is absent in some open-source builds).
    """
    result = {}
    for s in _TRANSP:
        try:
            result[s] = cmd.get_setting_float(s, obj)
        except Exception:
            pass
    return result


def snapshot_visual_state(objects_csv):
    """Snapshot per-atom colors and transparency settings for a set of objects.

    objects_csv: comma-separated PyMOL object names.

    Saves:
      - per-atom color (integer color index) keyed by atom *index* (str in JSON)
      - each transparency setting from _TRANSP per object (unknown settings skipped)

    Writes to $TMPDIR/raymol_design_snapshot.json.
    Returns 'DESIGN_SNAP:ok'.
    """
    objs = [o.strip() for o in objects_csv.split(',') if o.strip()]
    colors = {}
    settings = {}
    for o in objs:
        d = {}
        cmd.iterate(o, 'd[index] = color', space={'d': d})
        # JSON keys must be strings; int color values are fine.
        colors[o] = {str(k): v for k, v in d.items()}
        settings[o] = _get_transp_settings(o)
    snap = {'objects': objs, 'colors': colors, 'settings': settings}
    with open(_tmp('raymol_design_snapshot.json'), 'w') as f:
        json.dump(snap, f)
    return 'DESIGN_SNAP:ok'


def dim_object(obj, gray_color, transparency):
    """Color obj with gray_color and set all transparency settings to transparency.

    Unknown settings (absent in some PyMOL builds) are silently skipped.
    Returns 'DESIGN_DIM:ok'.
    """
    cmd.color(gray_color, obj)
    for s in _TRANSP:
        try:
            cmd.set(s, float(transparency), obj)
        except Exception:
            pass
    return 'DESIGN_DIM:ok'


def restore_visual_state():
    """Restore exact per-atom colors and transparency settings from snapshot.

    Loads $TMPDIR/raymol_design_snapshot.json written by snapshot_visual_state.
    For each object: restores transparency settings, then restores per-atom
    colors via alter (JSON string keys are converted back to int for matching),
    then calls recolor() to flush the display.
    Returns 'DESIGN_RESTORE:ok'.
    """
    with open(_tmp('raymol_design_snapshot.json')) as f:
        snap = json.load(f)
    for o in snap['objects']:
        # Restore transparency settings first.
        for s, v in snap['settings'][o].items():
            cmd.set(s, float(v), o)
        # JSON keys are strings; convert back to int to match `index` (int) in alter.
        int_colors = {int(k): v for k, v in snap['colors'][o].items()}
        cmd.alter(o, 'color = _d.get(index, color)', space={'_d': int_colors})
    cmd.recolor()
    return 'DESIGN_RESTORE:ok'


# ---------------------------------------------------------------------------
# Per-residue hover / pin sidechain sticks  (Phase 2a)
# ---------------------------------------------------------------------------
# Non-destructive preview: show sidechain sticks (colored by element) for the
# residue under the pointer (transient) and the pinned residue (persistent).
# We remember the EXACT per-atom colors we overwrote so stick-off restores them
# precisely — same faithful capture/restore pattern as snapshot_visual_state,
# but scoped to a single residue's sidechain. Residues the user already
# stick-repped themselves are detected and left completely untouched.
_STICK_COLORS = {}

# Module-level store for the full visual state (per-atom colors + transparency
# settings) saved when compare first turns on. Keyed by src object name; popped
# on compare-off or reset_compare.
# Shape: {src: {'colors': {str(index): color_int}, 'settings': {name: float}}}
_COMPARE_STATE = {}


def _residue_sel(obj, chain, resi):
    """Build a residue selection on ONE object, tolerating an empty chain id."""
    return '(%s) and %s' % (obj, _residue_pred(chain, resi))


def set_residue_sticks(obj, chain, resi, on):
    """Non-destructively show/hide sidechain sticks for a single residue.

    on truthy: if the residue's sidechain has no sticks yet AND has sidechain
      atoms, show sticks there and color by element (util.cnc keeps carbons,
      colors N/O/S/... ). Remembers the atoms' prior colors so stick-off can
      restore them, and reports whether WE added the sticks. A residue that
      already carries sticks (the user's own) is left untouched (added=False).
    on falsy: hide the sticks and restore the exact colors we overwrote — but
      only for residues WE previously added (tracked in _STICK_COLORS).

    Writes {'added': bool, 'chain': .., 'resi': ..} to
    $TMPDIR/raymol_design_sticks.json so the Swift caller can record, on a
    show, whether it now manages this residue's sticks.
    Never raises into the caller; returns a short marker string.
    """
    added = False
    try:
        on = bool(on) if isinstance(on, bool) else bool(int(on))
        res_sel = _residue_sel(obj, chain, resi)
        # Include CA so the CA–CB bond is drawn — otherwise the sidechain sticks
        # float detached from the backbone (PyMOL's `sidechain` excludes CA).
        # Exclude hydrogens (`not hydro`) — H sticks just clutter the preview.
        side_sel = '(%s) and (sidechain or name CA) and not hydro' % res_sel
        key = '%s\x01%s\x01%s' % (obj, chain, resi)
        if on:
            # Only add if the sidechain has atoms and none are already sticks
            # (never clobber a residue the user drew sticks on).
            has_atoms = cmd.count_atoms(side_sel) > 0
            already = cmd.count_atoms('(%s) and rep sticks' % side_sel) > 0
            if has_atoms and not already:
                # Capture the exact per-atom colors before recoloring by element.
                prior = {}
                cmd.iterate(side_sel, 'prior[index] = color',
                            space={'prior': prior})
                _STICK_COLORS[key] = prior
                cmd.show('sticks', side_sel)
                try:
                    cmd.util.cnc(side_sel, _self=cmd)
                except Exception:
                    pass
                added = True
        else:
            prior = _STICK_COLORS.pop(key, None)
            # Only touch residues we actually added sticks to.
            if prior is not None:
                cmd.hide('sticks', side_sel)
                cmd.alter(side_sel, 'color = _d.get(index, color)',
                          space={'_d': prior})
                cmd.recolor(side_sel)
    except Exception:
        pass
    try:
        with open(_tmp('raymol_design_sticks.json'), 'w') as f:
            json.dump({'added': bool(added), 'chain': chain, 'resi': resi}, f)
    except Exception:
        pass
    return 'DESIGN_STICKS:%s' % ('added' if added else 'noop')


# ---- Phase 2b: point-mutation editing helpers (additive) ----

def make_working_copy(src):
    """Create a non-destructive working copy of src, choosing a unique name.

    Uses cmd.get_unused_name so a previously-kept working copy (e.g. src_design)
    is not overwritten — the new session gets src_design01 etc.  The chosen
    name is written to $TMPDIR/raymol_design_working.json for the Swift caller
    to read back (runPython is fire-and-forget; no return channel).
    The copy inherits source transformation matrices so the two objects are
    superposed.  Returns 'DESIGN_WORK:<dst>'.
    """
    dst = cmd.get_unused_name(src + '_design')
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.create(dst, src, zoom=0)  # zoom=0: no camera reset; inherits source matrices → superposed
    cmd.disable(src)
    try:
        with open(_tmp('raymol_design_working.json'), 'w') as f:
            json.dump({'src': src, 'dst': dst}, f)
    except Exception:
        pass
    return 'DESIGN_WORK:%s' % dst


def _restore_compare_state(src):
    """Restore per-atom colors and transparency settings from _COMPARE_STATE[src].

    Pops the entry. Returns True if state was present, False otherwise.
    """
    state = _COMPARE_STATE.pop(src, None)
    if state is None:
        return False
    int_colors = {int(k): v for k, v in state['colors'].items()}
    cmd.alter(src, 'color = _d.get(index, color)', space={'_d': int_colors})
    for s, v in state['settings'].items():
        try:
            cmd.set(s, float(v), src)
        except Exception:
            pass
    cmd.recolor(src)
    return True


def _apply_compare_overlap(src):
    """Overlap mode: grey + transparent, no grid.

    Grid mode 0; enable src; color grey70; set all transparency settings to 0.5.
    """
    cmd.set('grid_mode', 0)
    cmd.enable(src)
    cmd.color('grey70', src)
    for s in _TRANSP:
        try:
            cmd.set(s, 0.5, src)
        except Exception:
            pass


def _apply_compare_grid(src):
    """Grid mode: restore saved colors + fully opaque, grid enabled.

    Restores per-atom colors from _COMPARE_STATE (saved at compare-first-on);
    sets all transparency settings to 0 (fully opaque); enables grid_mode 1.
    """
    state = _COMPARE_STATE.get(src)
    if state:
        int_colors = {int(k): v for k, v in state['colors'].items()}
        cmd.alter(src, 'color = _d.get(index, color)', space={'_d': int_colors})
        cmd.recolor(src)
    for s in _TRANSP:
        try:
            cmd.set(s, 0.0, src)
        except Exception:
            pass
    cmd.set('grid_mode', 1)
    cmd.enable(src)


def set_compare(src, on, side_by_side=False):
    """Enable/disable compare view for src (original parent).

    on truthy: save src per-atom colors + transparency into _COMPARE_STATE (once
      on first call); then apply overlap or grid per side_by_side:
      - side_by_side=False (overlap, default): grid_mode 0; enable src; color
        grey70; set transparency ~0.5 so it ghosts behind the design.
      - side_by_side=True (grid): grid_mode 1; enable src; restore saved colors +
        set transparency 0 (own confidence coloring, fully opaque).
      Toggling side_by_side while on switches between the two modes.
    on falsy: restore saved colors + transparency; disable src; grid_mode 0.

    Returns 'DESIGN_CMP:ok'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    _sbs = bool(side_by_side) if isinstance(side_by_side, bool) else bool(int(side_by_side))
    if _on:
        # Save full visual state on first compare-on; idempotent on subsequent calls.
        if src not in _COMPARE_STATE:
            colors = {}
            cmd.iterate(src, 'colors[index] = color', space={'colors': colors})
            _COMPARE_STATE[src] = {
                'colors': {str(k): v for k, v in colors.items()},
                'settings': _get_transp_settings(src),
            }
        if _sbs:
            _apply_compare_grid(src)
        else:
            _apply_compare_overlap(src)
    else:
        _restore_compare_state(src)
        cmd.disable(src)
        cmd.set('grid_mode', 0)
    return 'DESIGN_CMP:ok'


def reset_compare(src):
    """Restore src's saved compare colors + transparency (if any) and clear grid_mode.

    Does NOT enable or disable src.  Called by teardown so grid_mode is turned
    off and the parent is un-greyed, while the teardown's own enable/discard
    logic independently handles object visibility.
    Returns 'DESIGN_CMPRESET:ok'.
    """
    _restore_compare_state(src)
    cmd.set('grid_mode', 0)
    return 'DESIGN_CMPRESET:ok'


def discard_working_copy(src, dst):
    """Delete the working copy dst and re-enable the original src.

    Safe to call even if dst no longer exists.
    Returns 'DESIGN_DISCARD:ok'.
    """
    if dst in cmd.get_object_list():
        cmd.delete(dst)
    cmd.enable(src)
    return 'DESIGN_DISCARD:ok'


def set_residue_backbone_only(obj, chain, resi, on):
    """Hide sidechain representations for a single residue while a mutation is pending.

    on truthy: hide sticks/lines/spheres/nb_spheres on the sidechain atoms
      (everything except backbone N, CA, C, O) so stale pre-mutation coordinates
      are not shown.  Repack + rep-refresh restores them, so the off branch is a
      deliberate no-op.
    on falsy: no-op (caller reloads coords via load_repacked, which triggers a
      full representation refresh).
    Returns 'DESIGN_BBONLY:ok'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    side = '(%s) and (not name N+CA+C+O)' % _residue_sel(obj, chain, resi)
    if _on:
        for rep in ('sticks', 'lines', 'spheres', 'nb_spheres'):
            cmd.hide(rep, side)
    return 'DESIGN_BBONLY:ok'


def mutate_residue_display(obj, chain, resi, aa_index):
    """Visually apply a pending single-residue mutation to the working copy.

    1. Updates the residue name (resn) via cmd.alter so labels reflect the new
       amino-acid identity.
    2. Hides stale sidechain representations via set_residue_backbone_only so
       pre-repack side-chain coordinates are not shown to the user.

    aa_index: MPNN alphabet index (0-20); index 20 ('X'/masked) is a no-op.
    Returns 'DESIGN_MUTDISP:ok' or 'DESIGN_MUTDISP:noop'.
    """
    try:
        idx = int(aa_index)
    except (ValueError, TypeError):
        return 'DESIGN_MUTDISP:noop'
    if idx >= 20:
        # Masked/unknown residue — leave untouched.
        return 'DESIGN_MUTDISP:noop'
    three = _INDEX_TO_THREE.get(idx, 'UNK')
    res_sel = _residue_sel(obj, chain, resi)
    try:
        cmd.alter(res_sel, "resn='%s'" % three)
        cmd.rebuild(res_sel)  # flush label/rep state that depends on resn immediately
    except Exception:
        pass
    set_residue_backbone_only(obj, chain, resi, True)
    return 'DESIGN_MUTDISP:ok'


def load_repacked(obj, pdb_str, src=''):
    """Replace obj's structure from an all-atom PDB string (repack output).

    Full topology replace: reads pdb_str into a temp object, copies the
    current transform matrix from obj onto the temp (preserving superposition
    with the parent), then deletes obj and renames temp → obj.  This correctly
    adopts point mutations where the residue's atom set changed (e.g. ALA→TRP):
    cmd.update(matchmaker=1) can only copy coordinates onto atoms that already
    match by name, so it silently leaves the old sidechain intact when the atom
    set differs.  Replacing the entire object always adopts the new topology.

    After renaming, cartoon rep is enabled so the replaced object is visible.
    On any failure after read but before rename, the temp object is cleaned up.

    The replace annihilates obj's atoms, and with them their 'sele' membership. The
    same residues usually stay marked on the edit source, but make_working_copy
    DISABLED that object — so the region would remain armed while the pink pass drew
    nothing at all. Every residue Design's scope considers selected is therefore
    re-asserted onto the replaced (visible) object afterwards; `src` is what makes
    the pre-session residues, which were only ever marked on the original, part of
    that set. Returns 'DESIGN_REPACKED:ok'.
    """
    # Capture the camera view BEFORE any structural replacement so the viewport
    # does not jump when load+delete+rename triggers PyMOL's auto-zoom.
    v = cmd.get_view()
    # Which residues does Design's scope consider selected? Read BEFORE the replace:
    # afterwards obj's own atoms are gone.
    sele_keys = []
    try:
        cmd.iterate('%s and (?sele) and polymer and guide' % _scope(obj, src),
                    'k.append((chain, resi))', space={'k': sele_keys})
    except Exception:
        sele_keys = []
    tmp = cmd.get_unused_name('_rp')
    renamed = False
    try:
        cmd.read_pdbstr(pdb_str, tmp)
        # Copy the source object's transformation matrix to tmp BEFORE deleting
        # the source, so the replaced object stays in the same frame (superposed
        # on the original parent).  Silently skip if not supported or if obj is gone.
        try:
            cmd.matrix_copy(obj, tmp)
        except Exception:
            pass
        cmd.delete(obj)
        cmd.set_name(tmp, obj)
        renamed = True
        # Replacing the object resets representations; restore cartoon so the
        # working copy is visible immediately (conf coloring is re-applied by
        # the Swift caller after this returns).
        cmd.show_as('cartoon', obj)
    finally:
        if not renamed and tmp in cmd.get_object_list():
            cmd.delete(tmp)
    # Re-assert the region's 'sele' membership on the object the user can SEE.
    # Grouped per chain ('resi 3+4+5') rather than one term per residue, so a large
    # region stays a short expression.
    if renamed and sele_keys:
        by_chain = {}
        for chain, resi in set(sele_keys):
            by_chain.setdefault(chain, set()).add(resi)
        terms = []
        for chain, resis in by_chain.items():
            terms.append('(%s)' % _residue_pred(chain, '+'.join(sorted(resis))))
        try:
            cmd.select('sele', '(?sele) or ((%s) and (%s))'
                       % (obj, ' or '.join(terms)), enable=1)
        except Exception:
            pass
    # Restore the camera view exactly as it was before the replace (zoom=0 on
    # create already prevented the initial zoom; this covers the repack path).
    cmd.set_view(v)
    return 'DESIGN_REPACKED:ok'


def set_pinned_indicator(obj, chain, resi):
    """Set or clear the persistent committed 'sele' marker for the pinned residue.

    If chain and resi are non-empty, commits the residue's atoms to the PyMOL
    'sele' selection with enable=1 so the renderer draws the pink committed-
    selection pass persistently (the same indicator family as a normal click, but
    driven by the Design-mode pin rather than a user tap).  If either is empty,
    clears 'sele' to 'none' with enable=0 so no stale marker persists after
    unpinning, focus-change, teardown, or exit from Design mode.
    Returns 'DESIGN_PIN:ok'.
    """
    if resi:  # resi non-empty → set indicator (chain may legitimately be empty)
        cmd.select('sele', _residue_sel(obj, chain, resi), enable=1)
    else:      # resi empty → clear (controller sends ("", "", "") on unpin/teardown)
        cmd.select('sele', 'none', enable=0)
    return 'DESIGN_PIN:ok'


def show_all_sidechains(obj, on):
    """Show or hide all sidechain sticks on obj.

    on truthy: show sticks for '(obj) and (sidechain or name CA) and not hydro'
      (CA included so the CA–CB bond draws from the backbone; hydrogens excluded),
      then apply cnc coloring so
      heteroatoms are colored by element while carbons inherit the residue's
      current confidence color.
    on falsy: hide sticks for the same selection.

    Returns 'DESIGN_SIDECHAINS:on' or 'DESIGN_SIDECHAINS:off'.
    """
    _on = bool(on) if isinstance(on, bool) else bool(int(on))
    # Exclude hydrogens (`not hydro`) — H sticks just clutter the display.
    sel = '(%s) and (sidechain or name CA) and not hydro' % obj
    if _on:
        cmd.show('sticks', sel)
        try:
            cmd.util.cnc(sel, _self=cmd)
        except Exception:
            pass
    else:
        cmd.hide('sticks', sel)
    return 'DESIGN_SIDECHAINS:%s' % ('on' if _on else 'off')
