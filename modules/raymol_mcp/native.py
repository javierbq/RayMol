"""RayMol-native MCP tools: typed wrappers over the fork's own commands.

An agent that only sees ``run_pymol_command``/``run_python`` writes the stock
PyMOL it learned in training (``ray``, ``set ray_shadows``, ``set light``) and
never finds the studio lights, materials, Metal effects, on-device prediction
or the Metal movie exporter. Tools named for those features are how a client
discovers them, so each one here is a thin, typed wrapper over the real
command (``lights``, ``atmosphere``, ``*_material``, ``metal_*``, ``predict``,
``binder_design``, ``movie_export``, ``exporting._metal_png``): the commands
keep all validation, and their errors come back as the tool's error text.

Like tools.py, ``cmd`` is imported lazily inside each body and every body runs
on the app's main thread through ``mainthread.run_on_main``. stdout is teed
(tools._TeeStdout), never swallowed: predict/design print the marker lines the
Swift host acts on (#596), and the printed text is part of the result.
"""

import contextlib
import io
import json
import os
import re
import sys
import traceback

from raymol_mcp.mainthread import run_on_main

# The render switches an agent reaches for, by tool field -> setting.
EFFECTS = {
    "ssao": "metal_ssao",
    "shadows": "metal_shadows",
    "raytrace": "metal_raytrace",
    "rt_shadows": "metal_rt_shadows",
    "rt_samples": "metal_rt_samples",
    "rt_ao_intensity": "metal_rt_ao_intensity",
    "outline": "metal_outline",
    "outline_color": "metal_outline_color",
    "outline_width": "metal_outline_width",
    "dof": "metal_dof",
    "dof_aperture": "metal_dof_aperture",
    "dof_focus": "metal_dof_focus",
    "tonemap": "metal_tonemap",
    "exposure": "metal_exposure",
    "msaa": "metal_msaa",
}

MATERIAL_LAYERS = ("cartoon", "surface", "stick", "sphere")
MATERIALS = ("default", "matte", "plastic", "metallic", "glass",
             "frosted_glass", "jelly", "marble", "clay", "rubber")
LIGHT_PRESETS = ("three_point", "softbox", "spotlight", "rembrandt", "neon",
                 "sunset", "underlight")
AIR_FIELDS = ("haze", "dust", "dust_size", "dust_speed", "scatter", "seed",
              "dust_glow", "dust_opacity")
LIGHT_FIELDS = ("orbit", "pitch", "radius", "beam", "softness", "size",
                "color", "warmth", "intensity", "highlight", "falloff",
                "shadow", "outline", "aim", "pin")


def binder_design_enabled():
    """Binder design is experimental: offered only where the app offers it."""
    return bool(os.environ.get("RAYMOL_EXPERIMENTAL_BINDER_DESIGN"))


def _text(s):
    return {"content": [{"type": "text", "text": str(s)}], "isError": False}


def _error(s):
    return {"content": [{"type": "text", "text": str(s)}], "isError": True}


def _on_main(body):
    """Run ``body()`` on the main thread with stdout teed into the result.

    ``body`` returns a JSON-able value; the tool result is that value (as
    JSON) after anything the command printed. A raised exception becomes an
    error result carrying the printed text and the exception message (the
    commands' own messages say what was wrong; a traceback would bury them).
    """
    from raymol_mcp.tools import _TeeStdout

    def _run():
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(_TeeStdout(sys.stdout, buf)):
                value = body()
            from pymol import cmd
            cmd.sync()
        except Exception as e:
            printed = buf.getvalue().strip()
            message = str(e).strip() or traceback.format_exc()
            return _error((printed + "\n" if printed else "") + message)
        printed = buf.getvalue().strip()
        parts = [printed] if printed else []
        if value is not None:
            parts.append(json.dumps(value, indent=2, default=str))
        return _text("\n".join(parts) if parts else "ok")

    try:
        return run_on_main(_run)
    except Exception:
        return _error(traceback.format_exc())


# --- state readers (shared with get_session_state) -------------------------

def effects_state(cmd):
    return {field: cmd.get(setting) for field, setting in EFFECTS.items()}


def lights_summary(cmd):
    """The rig in a few fields per light, or None when there is no rig."""
    rig = cmd.get_lights()
    if not rig:
        return None
    keep = ("name", "orbit", "pitch", "radius", "color", "warmth",
            "intensity", "shadow", "aim")
    return {
        "enabled": rig.get("enabled"),
        "ambient": rig.get("ambient"),
        "classic": rig.get("classic"),
        "air": rig.get("air"),
        "lights": [{k: light.get(k) for k in keep}
                   for light in rig.get("lights", [])],
    }


def raymol_state(cmd):
    """RayMol-only session state; each part is best-effort on its own."""
    state = {}

    def part(key, fn):
        try:
            state[key] = fn()
        except Exception as e:
            state[key] = "unavailable: %s" % (str(e).strip() or type(e).__name__)

    part("lights", lambda: lights_summary(cmd))
    part("render_effects", lambda: effects_state(cmd))
    part("material_default", lambda: cmd.get("material_default"))
    part("materials", lambda: _object_materials(cmd))
    part("scenes", lambda: list(cmd.get_scene_list()))
    part("prediction_jobs", _prediction_jobs)
    if binder_design_enabled():
        part("design_jobs", _design_jobs)
    return state


def _object_materials(cmd):
    """Per-object materials that differ from 'default'."""
    out = {}
    for name in cmd.get_names("objects"):
        if cmd.get_type(name) != "object:molecule":
            continue
        mats = {}
        for layer in MATERIAL_LAYERS:
            value = cmd.get(layer + "_material", name)
            if value and value != "default":
                mats[layer] = value
        if mats:
            out[name] = mats
    return out


def _prediction_jobs():
    from pymol import predicting
    return predicting.predict_status()


def _design_jobs():
    from pymol import designing
    return designing.design_status()


# --- tools -----------------------------------------------------------------

def _set_lighting(args):
    preset = str(args.get("preset") or "").strip()
    mode = str(args.get("mode") or "").strip()
    lights = args.get("lights") or []
    remove = args.get("remove") or []
    rig_fields = {k: args[k] for k in ("ambient", "classic") if k in args}
    if preset and mode in ("off", "clear"):
        return _error("give either a preset or mode=%s, not both" % mode)

    def body():
        from pymol import cmd
        if mode == "clear":
            cmd.lights("clear")
        if preset:
            cmd.lights(preset, **rig_fields)
        elif rig_fields:
            cmd.lights(**rig_fields)
        for name in remove:
            cmd.lights("remove", str(name))
        for spec in lights:
            spec = dict(spec)
            name = str(spec.pop("name", "") or "").strip()
            fields = {k: v for k, v in spec.items() if v is not None}
            existing = {l["name"].lower()
                        for l in (cmd.get_lights() or {}).get("lights", [])}
            if name.lower() in existing:
                if fields:
                    cmd.lights(name, **fields)
            elif name:
                cmd.lights("add", name, **fields)
            else:
                cmd.lights("add", **fields)
        if mode in ("on", "off", "recenter"):
            cmd.lights(mode)
        return {"lights": lights_summary(cmd)}

    return _on_main(body)


def _set_atmosphere(args):
    fields = {k: args[k] for k in AIR_FIELDS if args.get(k) is not None}
    off = bool(args.get("off"))

    def body():
        from pymol import cmd
        if off:
            cmd.atmosphere("off")
        if fields:
            cmd.atmosphere(**fields)
        rig = cmd.get_lights()
        return {"air": (rig or {}).get("air"),
                "lights_on": bool(rig and rig.get("enabled"))}

    return _on_main(body)


def _set_material(args):
    material = str(args.get("material") or "").strip()
    if not material:
        return _error("missing 'material'")
    layers = args.get("representations") or ["cartoon", "surface", "stick",
                                             "sphere"]
    target = str(args.get("object") or "").strip()
    bad = [l for l in layers if l not in MATERIAL_LAYERS]
    if bad:
        return _error("unknown representation(s) %s; materials apply to: %s"
                      % (", ".join(bad), ", ".join(MATERIAL_LAYERS)))

    def body():
        from pymol import cmd
        if not target:
            cmd.set("material_default", material)
            return {"material_default": cmd.get("material_default")}
        out = {}
        for layer in layers:
            cmd.set(layer + "_material", material, target)
            out[layer] = cmd.get(layer + "_material", target)
        return {target: out}

    return _on_main(body)


def _set_render_effects(args):
    changes = {EFFECTS[k]: v for k, v in args.items()
               if k in EFFECTS and v is not None}

    def body():
        from pymol import cmd
        for setting, value in changes.items():
            if isinstance(value, bool):
                value = int(value)
            cmd.set(setting, value)
        return effects_state(cmd)

    return _on_main(body)


def _export_image(args):
    path = str(args.get("path") or "").strip()
    if not path:
        return _error("missing 'path'")
    path = os.path.abspath(os.path.expanduser(path))
    width = max(16, min(int(args.get("width", 1920)), 8192))
    height = max(16, min(int(args.get("height", 1080)), 8192))
    ray = int(args.get("raytrace", -1))

    def body():
        from pymol import cmd, exporting
        if exporting._metal_png(path, width, height, ray) and \
                os.path.exists(path) and os.path.getsize(path) > 0:
            return {"path": path, "renderer": "metal",
                    "width": width, "height": height}
        cmd.png(path, width=width, height=height, ray=1)
        return {"path": path, "renderer": "cpu ray tracer (no Metal view)",
                "width": width, "height": height}

    return _on_main(body)


def _export_movie(args):
    path = str(args.get("path") or "").strip()
    if not path:
        return _error("missing 'path'")
    kwargs = {k: args[k] for k in ("width", "height", "quality", "fps",
                                   "first", "last", "codec")
              if args.get(k) is not None}
    if args.get("raytrace") is not None:
        kwargs["ray"] = int(bool(args["raytrace"]))

    def body():
        from pymol import cmd
        # The app's exporter needs at least 2 frames, and refuses fewer only
        # in its log, which the agent never sees.
        if int(cmd.count_frames()) <= 1:
            raise ValueError("there is no movie: build one first (mset, "
                             "scenes, or the Timeline), e.g. "
                             "run_pymol_command 'mset 1 x120' then "
                             "'util.mroll 1, 120, 1'")
        request = cmd.movie_export(path, **kwargs)
        return {"queued": request,
                "note": "The app renders the movie in the background with "
                        "Metal; the file exists when the log reports it."}

    return _on_main(body)


def _predict_structure(args):
    sequence = str(args.get("sequence") or "").strip()
    if not sequence:
        return _error("missing 'sequence'")
    predictor = str(args.get("predictor") or "boltz2").strip()
    kwargs = {k: args[k] for k in ("name", "n_models", "seed", "msa",
                                   "recycling_steps", "diffusion_steps")
              if args.get(k) not in (None, "")}

    def body():
        from pymol import cmd
        jobs = cmd.predict(predictor, sequence, **kwargs)
        jobs = jobs if isinstance(jobs, list) else [jobs]
        return {"job_ids": [j.job_id for j in jobs],
                "note": "The structure appears as a placeholder object now "
                        "and fills in when the job finishes. Poll with "
                        "job_status."}

    return _on_main(body)


def _design_binder(args):
    if not binder_design_enabled():
        return _error("binder design is not enabled in this RayMol")
    target = str(args.get("target") or "").strip()
    if not target:
        return _error("missing 'target'")
    generator = str(args.get("generator") or "rfd3").strip()
    kwargs = {k: args[k] for k in ("hotspots", "length", "name", "n_designs",
                                   "seed", "diffusion_steps")
              if args.get(k) not in (None, "")}

    def body():
        from pymol import cmd
        jobs = cmd.binder_design(generator, target, **kwargs)
        jobs = jobs if isinstance(jobs, list) else [jobs]
        return {"job_ids": [getattr(j, "job_id", j) for j in jobs],
                "note": "Poll with job_status."}

    return _on_main(body)


def _job_status(args):
    job_id = str(args.get("job_id") or "").strip()
    load = bool(args.get("load_result"))

    def body():
        from pymol import predicting
        out = {"prediction": predicting.predict_status(job_id)
               if job_id in predicting.job_ids() or not job_id else {}}
        if binder_design_enabled():
            from pymol import designing
            out["design"] = (designing.design_status(job_id)
                             if job_id in designing.job_ids() or not job_id
                             else {})
        if job_id and not any(out.values()):
            raise ValueError("no job %r; omit job_id to list every job"
                             % job_id)
        if load and job_id:
            if out["prediction"]:
                out["loaded"] = predicting.predict_result(job_id)
            elif out.get("design"):
                from pymol import designing
                out["loaded"] = designing.design_result(job_id)
        return out

    return _on_main(body)


def _raymol_help(args):
    topic = str(args.get("topic") or "").strip()

    def body():
        from raymol_mcp import guide
        return guide.help_text(topic)

    try:
        return _text(run_on_main(body))
    except Exception as e:
        return _error(str(e).strip() or traceback.format_exc())


# --- notes for stock-PyMOL habits ------------------------------------------

_HABITS = [
    (re.compile(r"(^|[;\n]|cmd\.)\s*ray\b"),
     "'ray' is PyMOL's CPU ray tracer: it skips RayMol's studio lights, air "
     "and Metal effects. Use capture_viewport to look, or export_image for a "
     "file rendered by the app's Metal renderer."),
    (re.compile(r"(^|[;\n]|cmd\.)\s*png\b"),
     "Use export_image (Metal render, the app's Save Image) for a PNG; "
     "'png' over MCP does not read the Metal view."),
    (re.compile(r"(^|[;\n]|cmd\.)\s*mpng\b"),
     "Use export_movie (the app's Metal movie exporter, mp4/mov/gif) "
     "instead of 'mpng'."),
    (re.compile(r"\b(ray_shadows?|ray_trace_mode|ray_trace_fog|"
                r"ambient_occlusion_mode|ambient_occlusion_scale|"
                r"antialias|ray_shadow_decay_factor)\b"),
     "That is a CPU ray-tracer setting; the live Metal view ignores it. Use "
     "set_render_effects (ssao, shadows, raytrace, outline, dof, tonemap)."),
    (re.compile(r"\bset\b[\s(\"']+(light|light[2-9]|light_count|ambient|"
                r"direct|reflect|spec_reflect|spec_power|shininess)\b"),
     "RayMol has studio lighting: set_lighting (presets such as three_point, "
     "softbox, rembrandt, or per-light orbit/pitch/color/shadow). PyMOL's "
     "own light settings only apply while the rig is off."),
]


def habit_notes(code):
    """Notes for stock-PyMOL idioms in ``code`` that RayMol does better."""
    return [note for pattern, note in _HABITS if pattern.search(code or "")]


def with_habit_notes(result, code):
    notes = habit_notes(code)
    if notes:
        result = dict(result)
        result["content"] = list(result.get("content", [])) + [
            {"type": "text", "text": "RayMol note: " + " ".join(notes)}]
    return result


# --- registry --------------------------------------------------------------

_NUM = {"type": "number"}
_BOOL = {"type": "boolean"}
_STR = {"type": "string"}

_LIGHT_SCHEMA = {
    "type": "object",
    "properties": {
        "name": {"type": "string", "description":
                 "Light name (key, fill, rim, ...). An unknown name adds a "
                 "light; a known one is edited."},
        "orbit": {"type": "number", "description":
                  "Degrees around the subject: 0 at the camera, 90 "
                  "camera-right, 180 behind (rim)."},
        "pitch": {"type": "number", "description": "Degrees up, -90..90."},
        "radius": {"type": "number", "description": "Scene sizes, 0.5..8."},
        "beam": {"type": "number", "description": "Cone degrees, 1..170."},
        "softness": {"type": "number", "description": "0..1."},
        "size": {"type": "number", "description":
                 "Source radius 0..1; softens traced shadows."},
        "color": {"type": "string", "description":
                  "PyMOL colour name, 0xRRGGBB, r/g/b, or warm/neutral/cool."},
        "warmth": {"type": "number", "description": "Kelvin, 1500..15000."},
        "intensity": {"type": "number", "description": "0..4, default 1."},
        "highlight": {"type": "number", "description": "Specular 0..1."},
        "falloff": {"type": "number", "description": "0..2 (2 = inverse square)."},
        "shadow": {"type": "boolean", "description": "Cast a shadow (max 3)."},
        "outline": {"type": "boolean", "description": "Draw the beam outline."},
        "aim": {"type": "string", "description":
                "centre, x/y/z in Angstrom, or a selection."},
        "pin": {"type": "boolean", "description":
                "Pin to the molecules instead of the camera."},
    },
}

TOOLS = [
    {
        "name": "set_lighting",
        "description": (
            "RayMol studio lighting for the Metal renderer: a rig of up to 6 "
            "spot lights with shadows (the 'lights' command). Apply a preset "
            "(three_point, softbox, spotlight, rembrandt, neon, sunset, "
            "underlight), add/edit/remove lights, set ambient, or turn the "
            "rig on/off/clear/recenter. Returns the rig. Prefer this over "
            "PyMOL's 'set light'/'set ambient'. Pair with set_atmosphere "
            "for haze and dust in the beams."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "preset": {"type": "string", "enum": list(LIGHT_PRESETS)},
                "ambient": {"type": "number", "description": "0..1"},
                "classic": {"type": "number", "description":
                            "Blend of PyMOL's own lighting kept, 0..1."},
                "lights": {"type": "array", "items": _LIGHT_SCHEMA,
                           "description": "Lights to add or edit, by name."},
                "remove": {"type": "array", "items": _STR,
                           "description": "Light names to remove."},
                "mode": {"type": "string",
                         "enum": ["on", "off", "clear", "recenter"]},
            },
        },
    },
    {
        "name": "set_atmosphere",
        "description": (
            "RayMol atmosphere: haze and floating dust that the studio "
            "lights shine through (light shafts with shadow=1). Shows only "
            "while the light rig is on (set_lighting) and only in the Metal "
            "renderer. off=true resets every field."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "haze": {"type": "number", "description": "0..1"},
                "dust": {"type": "number", "description": "0..1"},
                "dust_size": {"type": "number", "description": "0.05..2"},
                "dust_speed": {"type": "number", "description": "0..10, 0 still"},
                "scatter": {"type": "number", "description": "-0.9..0.9"},
                "seed": {"type": "integer"},
                "dust_glow": {"type": "number", "description": "0..4"},
                "dust_opacity": {"type": "number", "description": "0..1"},
                "off": _BOOL,
            },
        },
    },
    {
        "name": "set_material",
        "description": (
            "RayMol materials: what a representation is made of, without "
            "changing its colour (matte, plastic, metallic, glass, "
            "frosted_glass, jelly, marble, clay, rubber, default). Per "
            "object and per representation (cartoon, surface, stick, "
            "sphere), e.g. a glass surface over a marble cartoon. With no "
            "object it sets material_default for everything."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "material": {"type": "string", "enum": list(MATERIALS)},
                "object": {"type": "string", "description":
                           "Object name; omit to set the global default."},
                "representations": {
                    "type": "array",
                    "items": {"type": "string",
                              "enum": list(MATERIAL_LAYERS)},
                    "description": "Default: all four."},
            },
            "required": ["material"],
        },
    },
    {
        "name": "set_render_effects",
        "description": (
            "Metal renderer effects in the live view (metal_* settings): "
            "screen-space AO and shadows, real-time ray-traced AO and "
            "shadows, silhouette outline, depth of field, filmic tone "
            "mapping and exposure, MSAA. Give only the fields to change; "
            "returns them all. These replace PyMOL's ray_* settings, which "
            "only affect the CPU 'ray' command."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "ssao": _BOOL, "shadows": _BOOL,
                "raytrace": {"type": "boolean", "description":
                             "Real-time ray-traced AO + shadows."},
                "rt_shadows": _BOOL,
                "rt_samples": {"type": "integer", "description": "1..256"},
                "rt_ao_intensity": {"type": "number", "description": "0..1"},
                "outline": _BOOL,
                "outline_color": {"type": "string"},
                "outline_width": {"type": "number", "description": "pixels"},
                "dof": {"type": "boolean", "description": "Depth of field."},
                "dof_aperture": {"type": "number", "description":
                                 "Max blur px; larger = stronger."},
                "dof_focus": {"type": "number", "description":
                              "Eye-space focus distance; 0 = auto."},
                "tonemap": {"type": "boolean", "description": "Filmic (ACES)."},
                "exposure": {"type": "number", "description": "1 = neutral"},
                "msaa": _BOOL,
            },
        },
    },
    {
        "name": "export_image",
        "description": (
            "Save the current view as a PNG file rendered by the app's Metal "
            "renderer (the app's Save Image: studio lights, materials, "
            "effects). Use this instead of 'png'/'ray'. Falls back to the CPU "
            "ray tracer only without a Metal view."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Output .png path"},
                "width": {"type": "integer", "default": 1920},
                "height": {"type": "integer", "default": 1080},
                "raytrace": {"type": "integer", "enum": [-1, 0, 1],
                             "description": "-1 as the live view (default), "
                                            "0 off, 1 Metal ray tracing on"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "export_movie",
        "description": (
            "Render the movie (mset/scenes/Timeline) to mp4, mov, gif or a "
            "PNG folder with the app's Metal exporter (movie_export). Runs "
            "in the background. Use this instead of 'mpng'."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description":
                         ".mp4, .mov, .gif, or an empty folder"},
                "width": {"type": "integer", "default": 1920},
                "height": {"type": "integer", "default": 1080},
                "quality": {"type": "string",
                            "enum": ["draft", "standard", "high", "maximum"]},
                "fps": {"type": "integer"},
                "codec": {"type": "string", "enum": ["h264", "hevc", "prores"]},
                "raytrace": _BOOL,
                "first": {"type": "integer"},
                "last": {"type": "integer"},
            },
            "required": ["path"],
        },
    },
    {
        "name": "predict_structure",
        "description": (
            "Fold a protein (or complex) ON DEVICE with RayMol's built-in "
            "structure predictors (Boltz-2 by default, or Protenix). Takes "
            "a one-letter sequence, chains separated by '/', or the name of "
            "a loaded object. Returns job ids at once; the model appears as "
            "an object when done. Poll with job_status. No external server "
            "or API key needed."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "sequence": {"type": "string"},
                "predictor": {"type": "string", "default": "boltz2",
                              "description": "boltz2, protenix-v2-bf16, ... "
                                             "(raymol_help 'predictors')"},
                "name": {"type": "string"},
                "n_models": {"type": "integer", "default": 1},
                "seed": {"type": "integer"},
                "msa": {"type": "string", "description":
                        "Alignments per chain; see raymol_help 'predict'."},
                "recycling_steps": {"type": "integer"},
                "diffusion_steps": {"type": "integer"},
            },
            "required": ["sequence"],
        },
    },
    {
        "name": "job_status",
        "description": (
            "Status of RayMol's on-device prediction (and design) jobs: "
            "state, phase, progress. Omit job_id for every job. "
            "load_result=true loads a finished job's structure if it is not "
            "already in the session."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "job_id": {"type": "string"},
                "load_result": _BOOL,
            },
        },
    },
    {
        "name": "raymol_help",
        "description": (
            "What RayMol adds to PyMOL and how to use it. No topic: the "
            "feature guide. A topic: the full manual of a command (lights, "
            "atmosphere, predict, movie_export, metrics_list, msa_search, "
            "...) or one of: materials, effects, presets, predictors."),
        "inputSchema": {
            "type": "object",
            "properties": {"topic": {"type": "string"}},
        },
    },
]

_DESIGN_TOOL = {
    "name": "design_binder",
    "description": (
        "Experimental: design a protein binder ON DEVICE against a target "
        "selection with RayMol's built-in generator (RFdiffusion3). Returns "
        "job ids; poll with job_status."),
    "inputSchema": {
        "type": "object",
        "properties": {
            "target": {"type": "string", "description": "Atom selection"},
            "hotspots": {"type": "string", "description":
                         "Selection of interface residues to engage"},
            "length": {"type": "integer", "default": 60},
            "n_designs": {"type": "integer", "default": 1},
            "generator": {"type": "string", "default": "rfd3"},
            "name": {"type": "string"},
            "seed": {"type": "integer"},
            "diffusion_steps": {"type": "integer"},
        },
        "required": ["target"],
    },
}

DISPATCH = {
    "set_lighting": _set_lighting,
    "set_atmosphere": _set_atmosphere,
    "set_material": _set_material,
    "set_render_effects": _set_render_effects,
    "export_image": _export_image,
    "export_movie": _export_movie,
    "predict_structure": _predict_structure,
    "job_status": _job_status,
    "raymol_help": _raymol_help,
    "design_binder": _design_binder,
}


def tools():
    """The native tools this process offers (design only when enabled)."""
    return TOOLS + ([_DESIGN_TOOL] if binder_design_enabled() else [])
