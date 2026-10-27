"""What the MCP server tells a client about RayMol.

A model reading "a PyMOL fork" falls back on the PyMOL it already knows, so
the instructions lead with what is different and name the tool or command
that replaces each stock-PyMOL habit. ``raymol_help`` (native.py) serves the
longer GUIDE and any command's own manual, so the instructions stay short
enough for clients that put them in every prompt.
"""

INSTRUCTIONS = (
    "RayMol is a native macOS/iOS molecular viewer built on PyMOL, but it is "
    "NOT stock PyMOL: it renders with Metal and adds features PyMOL does not "
    "have. Use the RayMol tools for them rather than PyMOL equivalents:\n"
    "- Lighting: set_lighting (studio rig of spot lights with shadows, "
    "presets three_point, softbox, rembrandt, neon, ...) instead of "
    "'set light'/'set ambient'; set_atmosphere for haze and dust.\n"
    "- Materials: set_material (glass, frosted_glass, metallic, marble, "
    "jelly, clay, ...) per object and representation, colours untouched.\n"
    "- Render quality: set_render_effects (Metal AO, shadows, real-time "
    "ray tracing, outlines, depth of field, tone mapping) instead of "
    "ray_* settings, which only affect the CPU 'ray' command.\n"
    "- Images and movies: capture_viewport to look (Metal render, what the "
    "user sees); export_image and export_movie for files, instead of "
    "'ray'/'png'/'mpng'; morph_object turns an ensemble into a smooth "
    "morph, instead of stepping raw states with mset/mplay.\n"
    "- On-device AI: predict_structure folds sequences locally (Boltz-2, "
    "Protenix) with no external service; job_status tracks jobs. Also "
    "msa_search/load_msa, metrics_list/metrics_get, usalign, apply_look.\n"
    "Call raymol_help for the feature guide, or raymol_help with a command "
    "name for its manual. get_session_state reports objects, the camera and "
    "RayMol state (lights, effects, materials, scenes, jobs).\n"
    "Everything else is PyMOL: run_pymol_command for one statement (pass "
    "async=0 to fetch/load), run_python for multi-step logic with 'cmd' "
    "(state persists). Make one change at a time and capture_viewport to "
    "verify."
)

GUIDE = """\
RAYMOL FEATURE GUIDE

RayMol keeps PyMOL's command language and Python API (cmd) and adds the
features below. The live view, capture_viewport and export_image all render
with the Metal renderer; PyMOL's 'ray' is the CPU tracer and does not draw
studio lights, atmosphere or Metal effects.

LIGHTING  (tool set_lighting; commands lights, atmosphere; raymol_help lights)
  A studio rig of up to 6 spot lights placed around the molecules, up to 3
  casting shadows. Presets: three_point, softbox, spotlight, rembrandt, neon,
  sunset, underlight. Each light has orbit/pitch (degrees around the subject,
  as the camera sees it), radius, beam, softness, color/warmth, intensity,
  shadow, aim. The rig is saved in .pse files and recalled by scenes.
    lights three_point
    lights key, orbit=-60, pitch=40, warmth=3200
    lights add, rim, orbit=170, pitch=20, color=cyan
    atmosphere haze=0.3, dust=0.5        (needs the rig on)

MATERIALS  (tool set_material; raymol_help materials)
  Per object and per representation (cartoon, surface, stick, sphere):
  default, matte, plastic, metallic, glass, frosted_glass, jelly, marble,
  clay, rubber. A material never changes colour or other settings.
    set surface_material, glass, myprotein
    set cartoon_material, marble, myprotein
    set material_default, matte
  apply_look gives a layer a named look (material + knobs + colour).

RENDER EFFECTS  (tool set_render_effects; raymol_help effects)
  metal_ssao, metal_shadows, metal_raytrace (real-time ray-traced AO and
  shadows), metal_rt_samples, metal_outline (+ _color, _width), metal_dof
  (+ _aperture, _focus, _autofocus), metal_tonemap, metal_exposure,
  metal_msaa. Use these, not ray_shadows / ray_trace_mode /
  ambient_occlusion_mode.
    dof_focus organic        (depth of field focused on a selection)

IMAGES AND MOVIES  (tools capture_viewport, export_image, export_movie)
  export_image writes the app's Save Image render (Metal, optional ray
  tracing). export_movie renders mset/scene/Timeline movies to mp4, mov, gif
  or PNG frames with quality presets draft, standard, high, maximum.
    movie_export ~/Desktop/spin.mp4, 1920, 1080, quality=high

MORPHS  (commands morph_object, morph_cancel, morph_dismiss)
  Turns a multi-state object whose models share their atoms (NMR ensemble,
  trajectory frames, predicted models) into a smoothly playing morph: a new
  object <source>_morph with interpolated frames between consecutive models
  (by default looping back to model 1). Use it instead of stepping raw
  states with mset/mplay. It builds in the background: poll
  raymol.morph_jobs in get_session_state until its status is done,
  cancelled or error (morph_dismiss clears a cancelled or failed record;
  async_=0 waits for it but blocks the app). With no movie defined, frames
  follow its states, so mplay and export_movie play it.
    morph_object 2kpo                    (builds 2kpo_morph)
    morph_object 2kpo, frames_per_model=10, loop=0
    morph_cancel 2kpo_morph              (stop a build and drop it)
    morph_dismiss 2kpo_morph             (forget a cancelled or failed build)
  RayMol's 'morph' command morphs between two objects (or through an
  ensemble with state1=0).

STRUCTURE PREDICTION, ON DEVICE  (tools predict_structure, job_status)
  Folds protein sequences locally with Boltz-2 or Protenix (weights download
  once on first use). Chains of a complex are separated by "/". Results load
  as an object; several models land as states superposed on model 1.
    predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ
    predict boltz2, MKTAY/GSHMA, name=dimer
    predict_status
  Alignments: msa_search builds one on a ColabFold server, load_msa reads an
  a3m; pass them with msa=. Confidence numbers are recorded as metrics.

METRICS  (raymol_help metrics_list)
  metrics_list, metrics_get, metrics_color (colour by pLDDT and other
  per-residue metrics), metrics_export, metrics_load.

GLYCANS
  glycocartoon draws SNFG symbols for the glycans in a selection,
  glycocolor applies SNFG colours, glycocartoon_hide removes them;
  glyco_tree prints the glycan tree as JSON.
    glycocartoon all

OTHER ADDITIONS
  usalign (TM-align superposition), box_select, fasta, scenes that also
  recall lights, settings and object motion, and Move mode / the Timeline in
  the app's UI.

Ask raymol_help with any command name for its full manual.
"""

# Commands added after the MCP guard's snapshot (testing/tests/
# test_mcp_command_coverage.py) that agents should NOT be pointed at, each
# with the reason: UI plumbing, test hooks, internals. Every other new command
# must be named in GUIDE (or INSTRUCTIONS) so MCP clients learn it exists.
NOT_FOR_AGENTS = {
    # "name": "why agents never need it",
}

_EFFECTS_HELP = """\
RENDER EFFECTS (set_render_effects field -> setting)

  ssao             metal_ssao             screen-space ambient occlusion
  shadows          metal_shadows          screen-space directional shadows
  raytrace         metal_raytrace         real-time ray-traced AO + shadows
  rt_shadows       metal_rt_shadows       trace shadow rays (needs raytrace)
  rt_samples       metal_rt_samples       AO rays per pixel, 1..256
  rt_ao_intensity  metal_rt_ao_intensity  AO darkening, 0..1
  outline          metal_outline          silhouette outline
  outline_color    metal_outline_color    outline colour
  outline_width    metal_outline_width    outline width in pixels
  dof              metal_dof              depth of field
  dof_aperture     metal_dof_aperture     max blur radius in pixels
  dof_focus        metal_dof_focus        focus distance, 0 = auto
  tonemap          metal_tonemap          filmic (ACES) tone mapping
  exposure         metal_exposure         exposure multiplier, 1 = neutral
  msaa             metal_msaa             4x multisampling

Current values:
"""


def _command_doc(cmd, name):
    entry = cmd.keyword.get(name)
    if not entry:
        return None
    fn = entry[0]
    doc = getattr(fn, "__doc__", None)
    return doc.strip("\n") if doc else None


def help_text(topic=""):
    """The guide, a named topic, or a command's manual. Main thread only."""
    from pymol import cmd
    key = topic.strip().lower()
    if not key or key in ("raymol", "guide", "features", "overview"):
        return GUIDE
    if key in ("materials", "material"):
        names = [n for _, n in cmd.get_material_names()]
        return (_command_doc(cmd, "material")
                or "") + "\nMaterials in this build: " + ", ".join(names)
    if key in ("effects", "render", "render_effects", "metal"):
        from raymol_mcp import native
        values = native.effects_state(cmd)
        return _EFFECTS_HELP + "\n".join(
            "  %-16s %s" % (k, v) for k, v in values.items())
    if key in ("presets", "lighting_presets"):
        from pymol import lighting_commands
        return "Lighting presets:\n" + "\n".join(
            "  %-12s %s" % (name, desc)
            for name, desc in lighting_commands.presets())
    if key in ("predictors", "prediction"):
        from pymol.predictors import registry
        return ("Structure predictors in this build: "
                + ", ".join(registry.available())
                + "\n\n" + (_command_doc(cmd, "predict") or ""))
    doc = _command_doc(cmd, key)
    if doc:
        return doc
    raise ValueError(
        "no help for %r. Topics: materials, effects, presets, predictors, "
        "or any command name (lights, atmosphere, predict, movie_export, "
        "metrics_list, msa_search, usalign, apply_look, ...)." % topic)
