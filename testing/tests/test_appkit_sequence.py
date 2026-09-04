"""Unit tests for pymol.appkit_sequence — headless, no PyMOL required.

Covers the sequence-panel data builder: per-object guide-residue rows
(_object_rows), the theme-preview rename, and the BIMO-style gap-alignment
merge (_apply_alignments) that re-lays-out members of an enabled alignment so
aligned residues share a column. `cmd` is replaced with a fake that executes
iterate() expressions against in-memory atom dicts.
"""

import os
import sys
import types
import unittest

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub
# Only when absent (a real `pymol -ckqy` run already has the real cmd; don't clobber it).
if not hasattr(sys.modules["pymol"], "cmd"):
    sys.modules["pymol"].cmd = types.SimpleNamespace()

from pymol import appkit_sequence as seq


class FakeCmd:
    """In-memory object model that can execute the two iterate() expressions
    appkit_sequence uses:
      - `r.append([chain, resi, resn, str(color)])`  over `(obj) and guide`
      - `mm[index] = (chain, resi)`                   over `obj`
    """

    def __init__(self, objects, enabled=None, raw=None, parents=None):
        # objects: {name: {"type": str, "atoms": [ {chain,resi,resn,color,index}, ... ]}}
        self._objects = objects
        # {child: parent_group} — what appkit_inspector.group_parents would report.
        self.parents = dict(parents or {})
        # `enabled=None` means "everything"; an explicit empty set means nothing
        # is enabled and must NOT fall back to all (that masked the #380 case).
        self._enabled = set(objects.keys()) if enabled is None else set(enabled)
        self._raw = raw or {}

    def get_type(self, name):
        return self._objects[name]["type"]

    def get_names(self, kind="objects", enabled_only=0):
        names = list(self._objects.keys())
        if kind == "public_group_objects":
            names = [n for n in names
                     if self._objects[n]["type"] == "object:group"]
        if enabled_only:
            names = [n for n in names if n in self._enabled]
        return names

    def get_raw_alignment(self, aln):
        return self._raw.get(aln)

    def get_color_tuple(self, ci):
        return (0.1 * ci, 0.2, 0.3)

    def iterate(self, selection, expression, space=None):
        space = space if space is not None else {}
        base, guide_only = selection.strip(), False
        if base.endswith(" and guide"):
            base = base[: -len(" and guide")].strip()
            guide_only = True
        base = base.strip("()")
        atoms = self._objects.get(base, {}).get("atoms", [])
        for atom in atoms:
            if guide_only and not atom.get("guide", True):
                continue
            ns = dict(space)
            ns.update(atom)
            exec(expression, {}, ns)


class _FakeInspector:
    """Stands in for pymol.appkit_inspector's cached group_parents().

    _visible_objects() imports it lazily to walk the group chain; the real one
    reads `get_session`, which this fake cmd deliberately does not model, so the
    map is served straight from FakeCmd instead.
    """

    @staticmethod
    def group_parents(objs, groups):
        return dict(getattr(seq.cmd, "parents", {}))


_MISSING = object()
_saved_inspector = (_MISSING, _MISSING)


def setUpModule():
    # Scoped, not global: `from pymol import appkit_inspector` resolves the
    # attribute on the package first, so leaving either binding in place hands
    # the fake to every later test module in the same pytest process (that took
    # out test_appkit_objpanel_poll / _widen_clip / _inspector_transparency).
    global _saved_inspector
    _saved_inspector = (
        sys.modules.get("pymol.appkit_inspector", _MISSING),
        getattr(sys.modules["pymol"], "appkit_inspector", _MISSING),
    )
    sys.modules["pymol.appkit_inspector"] = _FakeInspector
    setattr(sys.modules["pymol"], "appkit_inspector", _FakeInspector)


def tearDownModule():
    mod, attr = _saved_inspector
    if mod is _MISSING:
        sys.modules.pop("pymol.appkit_inspector", None)
    else:
        sys.modules["pymol.appkit_inspector"] = mod
    if attr is _MISSING:
        try:
            delattr(sys.modules["pymol"], "appkit_inspector")
        except AttributeError:
            pass
    else:
        setattr(sys.modules["pymol"], "appkit_inspector", attr)


def _mol(name_atoms):
    return {"type": "object:molecule", "atoms": name_atoms}


def _atom(chain, resi, resn, color, index, guide=True):
    return {"chain": chain, "resi": resi, "resn": resn,
            "color": color, "index": index, "guide": guide}


class ObjectRowsTest(unittest.TestCase):
    def test_basic_rows_cols_posmap(self):
        cmd = FakeCmd({
            "molA": _mol([_atom("A", "1", "ALA", 5, 101),
                          _atom("A", "2", "GLY", 6, 102)]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA"])
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["name"], "molA")
        self.assertEqual(out[0]["residues"],
                         [["A", "1", "ALA", "5"], ["A", "2", "GLY", "6"]])
        self.assertEqual(set(cols.keys()), {"5", "6"})
        self.assertEqual(posmap["molA"], {("A", "1"): 0, ("A", "2"): 1})

    def test_non_molecule_and_empty_skipped(self):
        cmd = FakeCmd({
            "molA": _mol([_atom("A", "1", "ALA", 5, 101)]),
            "aln": {"type": "object:alignment", "atoms": []},
            "empty": _mol([]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "aln", "empty"])
        self.assertEqual([d["name"] for d in out], ["molA"])

    def test_theme_preview_renamed_but_posmap_keyed_by_real_name(self):
        cmd = FakeCmd({
            "__theme_preview": _mol([_atom("A", "1", "ALA", 5, 101)]),
        })
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["__theme_preview"])
        self.assertEqual(out[0]["name"], "example")      # display remap
        self.assertIn("__theme_preview", posmap)          # posmap real name


class ApplyAlignmentsTest(unittest.TestCase):
    def _two_aligned_mols(self, enabled):
        # molA resi 1,2,3 (idx 101-103); molB resi 1,2,3 (idx 201-203).
        objects = {
            "molA": _mol([_atom("A", "1", "ALA", 5, 101),
                          _atom("A", "2", "GLY", 6, 102),
                          _atom("A", "3", "SER", 7, 103)]),
            "molB": _mol([_atom("B", "1", "ALA", 5, 201),
                          _atom("B", "2", "GLY", 6, 202),
                          _atom("B", "3", "SER", 7, 203)]),
            "aln": {"type": "object:alignment", "atoms": []},
        }
        # Align resi2<->resi2 and resi3<->resi3 (resi1 unaligned on both).
        raw = {"aln": [
            [("molA", 102), ("molB", 202)],
            [("molA", 103), ("molB", 203)],
        ]}
        return FakeCmd(objects, enabled=enabled, raw=raw)

    def test_enabled_alignment_inserts_gaps_and_shares_columns(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB", "aln"})
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "molB"])
        seq._apply_alignments(out, posmap)
        rows = {d["name"]: d["residues"] for d in out}
        # Both members padded to equal length.
        self.assertEqual(len(rows["molA"]), len(rows["molB"]))
        # The unaligned leading residues are offset by a gap on the other row.
        self.assertEqual(rows["molA"][0], ["A", "1", "ALA", "5"])
        self.assertEqual(rows["molB"][0], seq._GAP)
        self.assertEqual(rows["molA"][1], seq._GAP)
        self.assertEqual(rows["molB"][1], ["B", "1", "ALA", "5"])
        # Aligned residues (resi2, resi3) occupy the SAME column on both rows.
        for col in range(len(rows["molA"])):
            a, b = rows["molA"][col], rows["molB"][col]
            if a != seq._GAP and b != seq._GAP:
                self.assertEqual(a[1], b[1])  # same resi in a shared column

    def test_disabled_alignment_is_noop(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB"})  # aln NOT enabled
        seq.cmd = cmd
        out, cols, posmap = seq._object_rows(["molA", "molB"])
        before = {d["name"]: list(d["residues"]) for d in out}
        seq._apply_alignments(out, posmap)
        after = {d["name"]: d["residues"] for d in out}
        self.assertEqual(before, after)   # no gaps inserted

    def test_build_preview_skips_alignment(self):
        cmd = self._two_aligned_mols(enabled={"molA", "molB", "aln"})
        seq.cmd = cmd
        data = seq._build(["molA", "molB"], preview=True)
        # preview=True must NOT gap-align even with the alignment enabled.
        rows = {d["name"]: d["residues"] for d in data["objects"]}
        self.assertNotIn(seq._GAP, rows["molA"])
        self.assertNotIn(seq._GAP, rows["molB"])

    def test_build_fills_color_tuples(self):
        cmd = FakeCmd({"molA": _mol([_atom("A", "1", "ALA", 5, 101)])},
                      enabled={"molA"})
        seq.cmd = cmd
        data = seq._build(["molA"], preview=False)
        self.assertEqual(data["colors"]["5"], (0.5, 0.2, 0.3))


class PollTest(unittest.TestCase):
    """poll() must publish rows for ENABLED objects only (issue #380)."""

    def _payload(self, cmd, preview=False):
        import json
        import tempfile
        seq.cmd = cmd
        seq.poll(preview=preview)
        p = os.path.join(tempfile.gettempdir(), "pymol_seq.json")
        with open(p) as f:
            return json.load(f)

    def _two_mols(self, enabled):
        return FakeCmd({
            "molA": _mol([_atom("A", "1", "ALA", 5, 101)]),
            "molB": _mol([_atom("B", "1", "GLY", 6, 201)]),
        }, enabled=enabled)

    def test_disabled_object_gets_no_row(self):
        data = self._payload(self._two_mols({"molA"}))
        self.assertEqual([d["name"] for d in data["objects"]], ["molA"])

    def test_all_enabled_gets_all_rows(self):
        data = self._payload(self._two_mols({"molA", "molB"}))
        self.assertEqual([d["name"] for d in data["objects"]], ["molA", "molB"])

    def test_all_disabled_gets_no_rows(self):
        data = self._payload(self._two_mols(set()))
        self.assertEqual(data["objects"], [])

    def test_requests_enabled_only_from_the_core(self):
        # Guard the actual mechanism: get_names must be asked with enabled_only,
        # not filtered afterwards (a plain 'public_objects' call regressed #380).
        cmd = self._two_mols({"molA"})
        calls = []
        inner = cmd.get_names

        def spy(kind="objects", enabled_only=0):
            calls.append((kind, enabled_only))
            return inner(kind, enabled_only)

        cmd.get_names = spy
        self._payload(cmd)
        self.assertIn(("public_objects", 1), calls)

    def test_preview_ignores_enabled_state(self):
        # The theme-studio example is enabled-agnostic: it is the only thing on
        # screen during a preview, and it is not a public object at all.
        cmd = FakeCmd({
            "__theme_preview": _mol([_atom("A", "1", "ALA", 5, 101)]),
        }, enabled=set())
        data = self._payload(cmd, preview=True)
        self.assertEqual([d["name"] for d in data["objects"]], ["example"])


class VisibleObjectsTest(unittest.TestCase):
    """Group ancestry, which `enabled_only` alone does not cover (issue #380).

    Disabling a group hides its members in the viewport but leaves each member's
    own enabled flag set, so the row set has to require the whole chain.
    """

    def _grouped(self, enabled):
        # g_outer > g_inner > molA ; molB at top level.
        objects = {
            "molA": _mol([_atom("A", "1", "ALA", 5, 101)]),
            "molB": _mol([_atom("B", "1", "GLY", 6, 201)]),
            "g_inner": {"type": "object:group", "atoms": []},
            "g_outer": {"type": "object:group", "atoms": []},
        }
        parents = {"molA": "g_inner", "g_inner": "g_outer"}
        return FakeCmd(objects, enabled=enabled, parents=parents)

    def test_all_groups_enabled_keeps_the_member(self):
        cmd = self._grouped({"molA", "molB", "g_inner", "g_outer"})
        seq.cmd = cmd
        self.assertEqual(seq._visible_objects(), ["molA", "molB"])

    def test_disabled_parent_group_drops_the_member(self):
        cmd = self._grouped({"molA", "molB", "g_outer"})   # g_inner off
        seq.cmd = cmd
        self.assertEqual(seq._visible_objects(), ["molB"])

    def test_disabled_grandparent_group_drops_the_member(self):
        cmd = self._grouped({"molA", "molB", "g_inner"})   # g_outer off
        seq.cmd = cmd
        self.assertEqual(seq._visible_objects(), ["molB"])

    def test_groups_do_not_hide_top_level_objects(self):
        cmd = self._grouped({"molB"})                      # everything else off
        seq.cmd = cmd
        self.assertEqual(seq._visible_objects(), ["molB"])

    def test_cyclic_parent_map_terminates(self):
        # A corrupt/stale parent map must not spin. Both are enabled, so the only
        # thing under test is that the walk ends.
        objects = {
            "molA": _mol([_atom("A", "1", "ALA", 5, 101)]),
            "gx": {"type": "object:group", "atoms": []},
        }
        seq.cmd = FakeCmd(objects, enabled={"molA", "gx"},
                          parents={"molA": "gx", "gx": "molA"})
        self.assertEqual(seq._visible_objects(), ["molA"])   # 'gx' is a group

    def test_group_member_gets_no_sequence_row(self):
        # End to end through poll(), the way the panel sees it.
        cmd = self._grouped({"molA", "molB", "g_outer"})   # g_inner off
        seq.cmd = cmd
        seq.poll()
        import json
        import tempfile
        with open(os.path.join(tempfile.gettempdir(), "pymol_seq.json")) as f:
            data = json.load(f)
        self.assertEqual([d["name"] for d in data["objects"]], ["molB"])


class GapConstantTest(unittest.TestCase):
    def test_gap_shape(self):
        # Empty chain/resi, resn '-', color '-1' (no color entry).
        self.assertEqual(seq._GAP, ["", "", "-", "-1"])


if __name__ == "__main__":
    unittest.main()
