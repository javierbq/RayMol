"""Guard: a new RayMol command must be visible to MCP clients.

An agent driving RayMol over MCP only uses what it is told exists. When a
command is added, this fails until the command is named in the agent guide
(raymol_mcp/guide.py GUIDE or INSTRUCTIONS) or listed in
guide.NOT_FOR_AGENTS with the reason agents never need it. See "MCP
awareness" in CLAUDE.md for the full checklist (typed tool, session state,
habit notes).

KNOWN_COMMANDS is the snapshot of commands that existed when the guard was
added; it is never edited to make this pass.
"""

import re
import unittest

from pymol import cmd

from raymol_mcp import guide

KNOWN_COMMANDS = frozenset("""
    plugin_load plugin_pref_save
    abort accept alias align alignto alphatoall alter alter_state angle
    api apply_look as assert assign_stereo atmosphere attach backward
    bg_color bg_colour binder_design bond box_select button cache
    callout capture cartoon cd cealign center center_all centerofmass
    check class clean clip cls color color_deep colour config_mouse copy
    copy_to count_atoms count_discrete count_frames count_states create
    curve_new cycle_valence decline def del delete delete_states
    deprotect desaturate deselect design_cancel design_dismiss
    design_result design_status design_weights design_weights_cancel
    diagnostics dihedral dir disable distance drag draw dss dump edit
    edit_mode editing_ring embed enable ending exec extra_fit extract
    fab fasta feedback fetch fit fix_chemistry flag fnab focal_blur for
    fork forward fragment frame full_screen fuse get get_angle get_area
    get_bond get_chains get_clip get_dihedral get_distance get_extent
    get_position get_property get_property_list get_renderer
    get_sasa_relative get_symmetry get_title get_type get_version
    get_view get_viewport global glyco_remediate glyco_tree glycocartoon
    glycocartoon_hide glycocartoon_hide_all glycocolor gradient group
    h_add h_fill h_fix help help_setting hide id_atom identify if import
    index indicate intra_fit intra_rms intra_rms_cur invert isodot
    isolevel isomesh isosurface iterate iterate_state join_states label
    lights load load_embedded load_msa load_mtz load_png load_traj
    loadall log log_close log_open look_at ls madd map_double map_halve
    map_new map_set map_set_border map_trim mappend mask matrix_copy
    matrix_reset matrix_transfer mclear mcopy mdelete mdo mdump mem
    meter_reset metrics_color metrics_delete metrics_export metrics_get
    metrics_list metrics_load metrics_schema middle minsert mmatrix
    mmove morph mouse move movie.load movie.nutate movie.pause
    movie.produce movie.rock movie.roll movie.screw movie.sweep
    movie.tdroll movie.zoom movie_export mplay mpng msa_attach
    msa_cancel msa_delete msa_detach msa_list msa_rename msa_search
    msa_server msa_status mse2met mset mstop mtoggle multifilesave
    multisave mview order orient origin overlap pair_fit pass pbc_unwrap
    pbc_wrap phi_psi pi_interactions png pop predict predict_cancel
    predict_dismiss predict_result predict_status predict_weights
    predict_weights_cancel print protect protonate pseudoatom pwd python
    quit raise ramp_new ramp_update ray rebond rebuild recolor recolour
    redo reference refresh refresh_wizard reinitialize remove
    remove_picked rename replace replace_wizard reset resume rewind rms
    rms_cur rock rotate run save scene scene_order sculpt_activate
    sculpt_deactivate sculpt_iterate sculpt_purge select set
    set_atom_property set_bond set_color set_colour set_dihedral set_fov
    set_geometry set_key set_name set_property set_symmetry set_title
    set_view show show_as skip slice_new smooth sort space spawn
    spectrum spheroid splash split_chains split_states stereo super
    symexp symmetry_copy system toggle torsion translate try turn unbond
    undo ungroup uniquify unmask unpick unset unset_bond unset_deep
    update usalign util.cbab util.cbac util.cbag util.cbak util.cbam
    util.cbao util.cbap util.cbas util.cbaw util.cbay util.cbc
    util.chainbow util.cnc util.mrock util.mroll util.rainbow util.ss
    valence vdw_fit view viewport volume volume_color volume_panel
    volume_ramp_new while window wizard zoom
""".split())


def _load_import_time_commands():
    """Import every pymol module that registers commands when imported
    (a module-level <cmd>.extend("name", ...), e.g. raymol_glycan, glyco,
    metal_pick), so the set
    checked is the same whatever other tests happened to import first."""
    import importlib
    import os
    import pymol
    root = os.path.dirname(pymol.__file__)
    # cmd.extend("name", fn) at top level, or under a try (metal_pick's
    # _cmd_reg.extend('dof_focus', ...)).
    pattern = re.compile(r"^\s*\w+\.extend\(\s*['\"]", re.M)
    for folder, dirs, files in os.walk(root):
        # Only real (sub)packages: skips data such as pymol_path/examples.
        dirs[:] = [d for d in dirs
                   if os.path.exists(os.path.join(folder, d, "__init__.py"))]
        for f in files:
            if not f.endswith(".py"):
                continue
            path = os.path.join(folder, f)
            with open(path, encoding="utf-8", errors="replace") as fh:
                if not pattern.search(fh.read()):
                    continue
            rel = os.path.relpath(path, os.path.dirname(root))[:-3]
            name = rel.replace(os.sep, ".")
            if name.endswith(".__init__"):
                name = name[:-len(".__init__")]
            importlib.import_module(name)


def _builtin_commands(keyword):
    """Public commands defined by RayMol's own modules (not user plugins,
    not test fixtures, not _internal ones). pymol.testing is the test
    runner itself, which registers run_testfiles."""
    out = set()
    for name, entry in keyword.items():
        module = getattr(entry[0], "__module__", "") or ""
        if (not name.startswith("_") and module.startswith("pymol")
                and module != "pymol.testing"):
            out.add(name)
    return out


def _uncovered(keyword):
    """New commands that agents are neither told about nor excused from."""
    text = guide.GUIDE + "\n" + guide.INSTRUCTIONS
    missing = []
    for name in sorted(_builtin_commands(keyword) - KNOWN_COMMANDS):
        if name in guide.NOT_FOR_AGENTS:
            continue
        if not re.search(r"(?<![\w.])%s(?![\w])" % re.escape(name), text):
            missing.append(name)
    return missing


class TestNewCommandsReachMcp(unittest.TestCase):
    def test_every_new_command_is_in_the_agent_guide(self):
        _load_import_time_commands()
        missing = _uncovered(cmd.keyword)
        self.assertEqual(missing, [], (
            "New command(s) %s are invisible to MCP clients. Name each in "
            "GUIDE in modules/raymol_mcp/guide.py (one line and an example), "
            "or add it to guide.NOT_FOR_AGENTS with the reason agents never "
            "need it. Then follow the rest of 'MCP awareness' in CLAUDE.md."
            % ", ".join(missing)))

    def test_guard_flags_an_unlisted_command(self):
        # The check itself: a command from a pymol module that the guide
        # never names must be reported, and an opted-out one must not.
        def fake(*a, **k):
            pass
        fake.__module__ = "pymol.fake_feature"
        keyword = dict(cmd.keyword)
        keyword["zz_new_feature"] = [fake, 0, 0, "", 0]
        self.assertIn("zz_new_feature", _uncovered(keyword))
        guide.NOT_FOR_AGENTS["zz_new_feature"] = "test"
        try:
            self.assertNotIn("zz_new_feature", _uncovered(keyword))
        finally:
            del guide.NOT_FOR_AGENTS["zz_new_feature"]

    def test_opt_outs_are_real_new_commands(self):
        # A stale or pointless entry hides nothing; keep the list honest.
        for name in guide.NOT_FOR_AGENTS:
            self.assertIn(name, cmd.keyword, name)
            self.assertNotIn(name, KNOWN_COMMANDS, name)


if __name__ == "__main__":
    unittest.main()
