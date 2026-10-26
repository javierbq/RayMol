---
title: PyMOL Commands & API
description: Reference guide to standard PyMOL commands, RayMol extension commands, and Python scripting.
---

RayMol embeds the open-source PyMOL C++ engine and an embedded CPython 3.13 interpreter. Standard PyMOL commands, selection syntax, and the `pymol.cmd` Python API work natively, augmented by RayMol-specific commands for studio lighting, physically-based materials, glycobiology, on-device structure prediction, generative binder design (experimental, macOS only), multiple-sequence alignments, and quality metrics.

## Core commands

Standard PyMOL commands are fully supported in the command input bar and scripts:

| Command | Example | Description |
| :--- | :--- | :--- |
| `fetch` | `fetch 1ubq, async=0` | Download a structure from the Protein Data Bank. |
| `show` / `hide` | `show cartoon, polymer` | Toggle a representation for a selection. |
| `color` | `color marine, chain A` | Apply a named color to a selection. |
| `select` | `select active_site, byres ligand around 4` | Create a named atom selection. |
| `distance` | `distance contacts, ligand, polymer, 3.5` | Create a distance measurement between selections. |
| `save` | `save analysis.pse` | Save a structure, selection, or session based on the extension. |
| `ray` | `ray 2400, 1600` | Run PyMOL's high-quality CPU ray tracer. |

---

## RayMol commands

RayMol adds specialized commands for studio lighting, physically-based materials, automated SNFG glycan cartoon generation, screen-space box selection, structure prediction, generative design, multiple-sequence alignments, metric scoring, and smooth morphs of multi-state objects.

### Rendering & Lighting

Commands for configuring studio lighting rigs, atmospheric haze and dust, and offline video exports.

#### `lights`
Configure a studio lighting rig of up to six directional spotlights placed around the scene.
- **Syntax**: `lights [preset | name | keyword] [, field=value, ...]`
- **Keywords**: `add`, `remove`, `presets`, `recenter`, `on`, `off`, `clear`
- **Fields**: `orbit`, `pitch`, `radius`, `beam`, `softness`, `color`, `rgb`, `warmth`, `intensity`, `highlight`, `falloff`, `shadow`, `outline`, `size`, `aim`, `anchor`, `pin`, `position`, `name`; rig fields `ambient`, `classic`; placement helpers `target=sele`, `highlight=sele`, `click=x/y`, `rim=deg`
- **Python**: `cmd.lights(...)`, `cmd.get_lights()`, `cmd.set_lights(rig)`
- **Guide**: [Studio Lights & Atmosphere](/RayMol/guides/lighting/)
- **Example**: `lights three_point` or `lights key, orbit=-45, pitch=35, color=warm, intensity=1.2`

#### `atmosphere`
Control the air the studio lights shine through: haze and floating dust. The air shows only inside the beams, and only while the lights are on. It is drawn by the Metal renderer (live view, image and movie exports, with or without Metal ray tracing, and per cell in `grid_mode`); the CPU `ray` command never shows it.
- **Syntax**: `atmosphere [off | field=value, ...]`
- **Fields**: `haze` (0–1), `dust` (0–1), `dust_size` (0.05–2), `dust_speed` (0–10), `scatter` (-0.9–0.9), `seed` (0–1000000), `dust_glow` (0–4), `dust_opacity` (0–1)
- **Example**: `atmosphere haze=0.3, dust=0.5, dust_speed=1.0`

#### `movie_export`
Render high-fidelity movies or image sequences through the Metal exporter with quality overrides. Runs asynchronously inside the RayMol app and reports the finished file in the log; it is not available in command-line PyMOL.
- **Syntax**: `movie_export filename [, width [, height [, quality [, format [, codec [, fps [, supersample [, rt_samples [, ray [, bitrate [, first [, last ]]]]]]]]]]]]`
- **Arguments**: `filename` (path ending in `.mp4`, `.mov`, `.gif`, or folder for PNG sequence), `quality` (`draft`, `standard`, `high`, `maximum`), `format` (`mp4`, `mov`, `gif`, `png`), `codec` (`h264`, `hevc`, `prores`), `first`, `last` (frame range; `last=0` = final frame)
- **Example**: `movie_export presentation.mp4, width=1920, height=1080, quality=high, codec=hevc`

---

### Materials

#### `apply_look`
Assign a curated material style, custom surface knobs, and coordinated atom base coat to a single layer of an object.
- **Syntax**: `apply_look look, object, layer`
- **Arguments**: `look` (`gold`, `copper`, `bronze`, `steel`, `chrome`, `statuary`, `terracotta`), `object` (target object name), `layer` (`cartoon`, `surface`, `stick`, `sphere`)
- **Example**: `apply_look gold, 1ubq, cartoon`

---

### Glycobiology

RayMol includes built-in support for the Symbol Nomenclature for Glycans (SNFG), providing 3D cartoon symbols and carbohydrate topology inspection. See the [Glycobiology Guide](/RayMol/guides/glycobiology/) for complete residue catalogues and interpretation details.

#### `glycocolor`
Apply official SNFG color schemes to recognized carbohydrate residues without changing representation visibility.
- **Syntax**: `glycocolor [selection]`
- **Example**: `glycocolor 4byh`

#### `glycocartoon`
Construct Metal-rendered 3D SNFG symbols (spheres, cubes, cones, diamonds) and covalent inter-sugar linkers for recognized carbohydrate residues.
- **Syntax**: `glycocartoon [selection [, size [, draw_linkers [, state ]]]]`
- **Example**: `glycocartoon 4byh, size=2.5`

#### `glycocartoon_hide`
Remove the SNFG 3D cartoon geometry generated for a specific selection and restore stick visibility.
- **Syntax**: `glycocartoon_hide [selection]`
- **Example**: `glycocartoon_hide 4byh`

#### `glycocartoon_hide_all`
Delete every generated SNFG cartoon object in the session and show sticks again on all recognized carbohydrate residues.
- **Syntax**: `glycocartoon_hide_all`
- **Example**: `glycocartoon_hide_all`

#### `glyco_tree`
Analyze carbohydrate connectivity and output a JSON-formatted glycan forest containing linkage positions, puckering parameters, and ring conformations.
- **Syntax**: `glyco_tree [selection [, state ]]`
- **Example**: `glyco_tree 4byh`

#### `glyco_remediate`
Inspect residue geometry and print an advisory carbohydrate identity assessment without modifying the underlying coordinate structure.
- **Syntax**: `glyco_remediate [selection [, state ]]`
- **Example**: `glyco_remediate 4byh`

---

### Selection & Picking

#### `box_select`
Select all visible, drawn atoms projected inside a rectangular screen-space bounding box.
- **Syntax**: `box_select x1, y1, x2, y2 [, name [, mode [, selection [, state ]]]]`
- **Arguments**: `x1, y1, x2, y2` (coordinates in viewport pixels with bottom-left origin), `name` (target selection name, default `sele`), `mode` (`replace`, `add`, `subtract`)
- **Example**: `box_select 100, 100, 500, 400, mode=add`

---

### Design & Structure Prediction

RayMol integrates on-device neural network inference via MLX for AlphaFold/Boltz-style structure prediction and RFdiffusion-style backbone generation. Boltz-2 is available on all platforms; Protenix is macOS-only. On iPhone and iPad, Predict and Design require physical hardware running iOS/iPadOS 18+ (not supported on the Simulator).

#### Structure Prediction

##### `predict`
Submit an asynchronous structure prediction job from a sequence or loaded protein chains using a registered neural network model.
- **Syntax**: `predict predictor, sequence [, name [, recycling_steps [, diffusion_steps [, seed [, n_models [, msa [, msa_depth ]]]]]]]`
- **Arguments**: `predictor` (`boltz2` on all platforms, or `protenix` on macOS), `sequence` (amino acid sequence or loaded object/selection), `name` (resulting object name, default derived from sequence), `recycling_steps` (default `3`), `diffusion_steps` (default `200`), `seed` (fresh per run when omitted), `n_models` (default `1`, max `20` — each is a full run), `msa` (one `/`-separated slot per chain), `msa_depth` (default `16384`)
- **Example**: `predict boltz2, MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ, name=target_pred`

##### `predict_status`
Query the execution status, progress percentage, current phase, and ETA of pending or completed prediction jobs.
- **Syntax**: `predict_status [job_id]`
- **Example**: `predict_status`

##### `predict_cancel`
Stop a running prediction. `job_id` is a job id, or the name of a pending object — which cancels every model still outstanding for it.
- **Syntax**: `predict_cancel job_id`
- **Example**: `predict_cancel target_pred`

##### `predict_dismiss`
Clear the retained card of a prediction that failed or was cancelled (successful runs retire their own card). With no name, clears all of them. Works only inside the RayMol app.
- **Syntax**: `predict_dismiss [name]`
- **Example**: `predict_dismiss target_pred`

##### `predict_result`
Manually retrieve and load finished structure prediction coordinates into a named molecular object.
- **Syntax**: `predict_result job_id [, name ]`
- **Example**: `predict_result pending-9c21ab40f7d3, my_folded_model` (ids come from `predict_status`)

##### `predict_weights`
Inspect local weight bundle cache state or pre-download neural network weights.
- **Syntax**: `predict_weights [predictor [, download [, async_ ]]]`
- **Example**: `predict_weights boltz2, download=1`

##### `predict_weights_cancel`
Stop an in-progress model weight bundle download.
- **Syntax**: `predict_weights_cancel [predictor]`
- **Example**: `predict_weights_cancel boltz2`

---

#### Generative Backbone Design

##### `binder_design`
Generate de novo protein backbone binders against a designated target structure using a diffusion model (e.g. `rfd3`). *Experimental, macOS only; not enabled in the app UI by default.*
- **Syntax**: `binder_design generator, target [, hotspots [, length [, name [, n_designs [, diffusion_steps [, recycling_steps [, seed [, live_view [, live_steps [, keep_frames ]]]]]]]]]]`
- **Example**: `binder_design rfd3, target_obj, hotspots=resi 45+48+52, length=70, n_designs=4`

##### `design_status`
Report progress, diffusion phase, and status for running backbone design jobs.
- **Syntax**: `design_status [job_id]`
- **Example**: `design_status`

##### `design_cancel`
Halt an active diffusion design job or entire batch.
- **Syntax**: `design_cancel job_id`
- **Example**: `design_cancel rfd3_design_7a1c` — an object or batch-group name also works

##### `design_dismiss`
Clear the card of a design that failed or was cancelled and remove its empty placeholder object. Works only inside the RayMol app.
- **Syntax**: `design_dismiss [name]`
- **Example**: `design_dismiss rfd3_design_7a1c`

##### `design_result`
Load finished backbone design coordinates into an object.
- **Syntax**: `design_result job_id [, name ]`
- **Example**: `design_result pending-5be10c92a4f1, my_binder` (ids come from `design_status`)

##### `design_weights`
Check availability or download weights for backbone generation models.
- **Syntax**: `design_weights [generator [, download ]]`
- **Example**: `design_weights rfd3, download=1`

##### `design_weights_cancel`
Cancel an active weight bundle download for generative models.
- **Syntax**: `design_weights_cancel [generator]`
- **Example**: `design_weights_cancel rfd3`

---

#### Multiple-Sequence Alignments (MSA)

##### `load_msa`
Load a multiple-sequence alignment (`.a3m` or aligned `.fasta`, optionally gzipped) into the session.
- **Syntax**: `load_msa filename [, name [, target [, chain ]]]`
- **Example**: `load_msa barnase.a3m, barnase_aln, 1brs, A`

##### `msa_list`
List all MSA alignments currently stored in the active session.
- **Syntax**: `msa_list`
- **Example**: `msa_list`

##### `msa_delete`
Remove a stored MSA object from the session.
- **Syntax**: `msa_delete name`
- **Example**: `msa_delete barnase_aln`

##### `msa_rename`
Rename a stored MSA alignment object.
- **Syntax**: `msa_rename name, new_name`
- **Example**: `msa_rename old_aln, new_aln`

##### `msa_attach`
Associate a loaded alignment with a specific target object and chain for downstream prediction.
- **Syntax**: `msa_attach name, target [, chain ]`
- **Example**: `msa_attach barnase_aln, 1brs, A`

##### `msa_detach`
Disassociate an alignment from its attached target object while keeping the alignment in the session.
- **Syntax**: `msa_detach name`
- **Example**: `msa_detach barnase_aln`

##### `msa_server`
Display or configure the remote ColabFold MMseqs2 MSA server endpoint. The default server is `https://api.colabfold.com`, and `save` defaults to `1`.
- **Syntax**: `msa_server [server [, save ]]`
- **Example**: `msa_server server=https://colabfold.example.org, save=1`

##### `msa_search`
Initiate an asynchronous MMseqs2 alignment search against an MSA server for a given sequence or object chain.
- **Syntax**: `msa_search sequence [, name [, target [, chain [, server [, mode [, refresh ]]]]]]`
- **Example**: `msa_search 1ubq, target=1ubq, chain=A`

##### `msa_status`
Check the status of pending background MSA searches.
- **Syntax**: `msa_status [search_id]`
- **Example**: `msa_status`

##### `msa_cancel`
Cancel an ongoing background MSA search. With no id, every running search is cancelled.
- **Syntax**: `msa_cancel [search_id]`
- **Example**: `msa_cancel msa-3f2a91c40b7e` (ids come from `msa_status`)

---

#### Quality Metrics & Scoring

##### `metrics_list`
List all recorded metric runs (confidence, pLDDT, PAE, design scores) attached to objects in the session.
- **Syntax**: `metrics_list [object [, tool ]]`
- **Example**: `metrics_list my_model`

##### `metrics_get`
Retrieve recorded metric summaries, scalar values, or per-residue array data for an object.
- **Syntax**: `metrics_get [run [, key [, object [, state [, tool ]]]]]`
- **Example**: `metrics_get key=plddt, object=my_model`

##### `metrics_delete`
Delete metric runs for a specific run ID, an object, or all objects.
- **Syntax**: `metrics_delete name`
- **Example**: `metrics_delete my_model`

##### `metrics_color`
Color an object by a per-residue metric array (e.g. pLDDT or interface confidence) using PyMOL color ramps.
- **Syntax**: `metrics_color key [, object [, run [, state [, palette [, minimum [, maximum [, selection [, tool ]]]]]]]]`
- **Example**: `metrics_color plddt, my_model, palette=rainbow`

##### `metrics_export`
Export recorded metrics to `.json` (full data including PAE matrices) or `.csv` (tabular per-residue values).
- **Syntax**: `metrics_export filename [, object [, run ]]`
- **Example**: `metrics_export scores.json, my_model`

##### `metrics_load`
Load external metric files conforming to the RayMol schema and attach them to an existing object.
- **Syntax**: `metrics_load filename [, object ]`
- **Example**: `metrics_load external_metrics.json, my_model`

##### `metrics_schema`
Print the specification, units, scope, and expected ranges for metrics reported by a tool.
- **Syntax**: `metrics_schema [tool]`
- **Example**: `metrics_schema boltz2`

---

### Movies & Playback

Commands that turn the models of a multi-state object into a smooth, looping morph. The [Morphing guide](/RayMol/guides/morph/) covers the Object panel's **Morph…** sheet and the Movie tab's **Smooth transitions (morph)** toggle, which run the same job.

#### `morph_object`
Build a smoothly playing morph of a multi-state object (an NMR ensemble, trajectory snapshots, predicted models). Each pair of consecutive models becomes `frames_per_model` states, the key frames are exact copies of the models, and the result is a separate object, `<source>_morph`: the source keeps its states and is hidden once the morph is complete. Inside the RayMol app the morph builds in the background, with a progress card in the tray; with `async_=0` it is complete when the command returns, which scripts and command-line PyMOL need (outside the app nothing lands the frames of a background morph). Running it again on the same source rebuilds a morph built in this session in place; the old morph is deleted as soon as the rebuild starts. For a morph restored from a saved session, pass `name=<source>_morph` to rebuild it in place; without a name a new `<source>_morph2` is built beside it. Refuses sources with one model, models with different atoms, discrete objects, objects whose atoms are not uniquely identified by segment, chain, residue number, residue name and atom name, objects with no atoms in altloc `A` or without one, objects that are not molecules, and morphs larger than the memory limit: 1 GB or a quarter of the computer's memory, whichever is larger (on iPhone and iPad, 400 MB or half the memory available to RayMol), against an estimate of the memory the finished morph holds (coordinates plus the representations the source shows, cartoon costing the most; see the guide's Memory and size). Nothing is created when a morph is refused; in the app the reason appears in a **Morph failed** card in the progress tray.
- **Syntax**: `morph_object source [, name [, frames_per_model [, loop [, method [, refinement [, rate [, copy_look [, async_ [, reuse ]]]]]]]]]`
- **Arguments**: `source` (multi-state object; every model must hold the same atoms), `name` (default `<source>_morph`, or `<source>_morph2`, … when that name is taken by something that is not a morph of `source` built in this session; a molecule with the same number of atoms that you create under a name a morph of `source` had earlier in this session, even a cancelled one, counts as that morph and is replaced. An explicit name may replace only such a morph or a molecule named `<source>_morph` or `<source>_morph<N>`; any other existing object is refused), `frames_per_model` (default `15`, at least `2`), `loop` (default `1`: the last model morphs back into the first), `method` (`rigimol`, the default, moves rigid segments on screw paths; `linear` interpolates every atom in a straight line), `refinement` (sculpting clean-up cycles on the intermediate frames, default `3`; `0` for none), `rate` (`linear` by default, `sinusoidal`, `ramp_up`, `ramp_down`), `copy_look` (default `1`: copy the settings set on the source object), `async_` (default `1`; written with the underscore, `async=0` is rejected), `reuse` (default `0`; `1` keeps an existing morph built in this session with the same settings from the unchanged source)
- **Guide**: [Morphing](/RayMol/guides/morph/)
- **Example**: `fetch 2kpo, async=0` then `morph_object 2kpo` in the app, or `morph_object 2kpo, async_=0` in a script (300 states from 20 models); `morph_object 2kpo, frames_per_model=30, loop=0, async_=0` builds 570 states ending on model 20

#### `morph_cancel`
Stop a morph that is being built: the partial object is deleted and the source is shown again. Its tray card then reads "Morph cancelled" until dismissed. Cancelling a rebuild also loses the previous morph, which was deleted when the rebuild started.
- **Syntax**: `morph_cancel name`
- **Arguments**: `name` (the morph object being built)
- **Example**: `morph_cancel 2kpo_morph`

#### `morph_dismiss`
Clear the tray card of a morph that was cancelled or failed (a completed morph leaves no card).
- **Syntax**: `morph_dismiss name`
- **Example**: `morph_dismiss 2kpo_morph`

#### `morph`
Interpolate between two conformations, from two objects or two states of one, into a new multi-state object. RayMol's open-source implementation of the PyMOL command: rigid segments found by core and hinge analysis move along screw paths, and sculpting cleans up the intermediates. It runs to completion before returning, keeps only the paired atoms, and hides the input objects; it does not copy object settings or show a progress card.
- **Syntax**: `morph name, sele1 [, sele2 [, state1 [, state2 [, refinement [, steps [, method [, match [, quiet [, rate [, core_fraction [, min_hinge [, hinge_blend [, hide [, color_segments ]]]]]]]]]]]]]]`
- **Arguments**: `name` (object to create; it cannot be one of the input objects, a group or a selection. An existing molecule of that name, such as the output of an earlier `morph`, is replaced once the new morph is built; a morph that fails leaves it as it was), `sele1`, `sele2` (default `sele1`; each must lie within one object. Two different selections of one object pair only with `match=in` or `like`, which morph the atoms both hold; to morph chain A into chain B, `create` them as separate objects first), `state1` (default `1`; `0` morphs through every model of `sele1` and back to model 1), `state2` (default `2` when both selections are the same atoms, otherwise `1`; with `state1=0`, `state2=0` stops at the last model), `refinement` (default `3`), `steps` (states per leg, default `30`), `method` (`rigimol` default, or `linear`), `match` (how two objects' atoms are paired: `align` default, `super`, `in`, `like`, or an alignment object), `rate` (`linear` default, `sinusoidal`, `ramp_up`, `ramp_down`), `core_fraction` (default `0.5`), `min_hinge` (default `6` residues), `hinge_blend` (default `3` residues), `hide` (default `1`: disable the inputs), `color_segments` (default `0`; `1` colours the result by rigid segment)
- **Guide**: [Morphing](/RayMol/guides/morph/#morph-between-two-structures)
- **Example**: `fetch 1akeA 4akeA, async=0`, `align 1akeA, 4akeA`, `morph mout, 1akeA, 4akeA`

---

## Python scripting & startup

Run `.pml` command scripts or `.py` Python scripts using the console `run` command or `@` syntax:

```text
run path/to/script.py
@path/to/script.pml
```

Within Python scripts, the `cmd` module exposes the PyMOL and RayMol API:

```python
from pymol import cmd

cmd.fetch("1ubq", async_=0)
cmd.show("cartoon", "1ubq")
cmd.color("marine", "1ubq")
cmd.apply_look("gold", "1ubq", "cartoon")
cmd.lights("three_point")
```

### Startup configuration (`~/.raymolrc`)

On macOS, RayMol runs a startup script at launch, if present: `~/.raymolrc.py` (Python syntax) and then `~/.raymolrc` (PyMOL command syntax). The Mac App Store build is sandboxed, so its home folder is its container (`~/Library/Containers/io.raymol.RayMol/Data/`). iPadOS and iOS have no user-visible home directory, so startup scripts are not loaded there.

If an existing desktop `~/.pymolrc` or `~/.pymolrc.py` is detected on macOS, RayMol prompts the user on first launch to import it into `~/.raymolrc`.

### Available Python packages

RayMol embeds a self-contained CPython 3.13 runtime with:
- **Python standard library**: Complete Python 3.13 stdlib modules.
- **NumPy**: Bundled on macOS and available in iOS device builds.
- **Biopython (`Bio`)**: Bundled in embedded Python (`import Bio`). On macOS, full compiled extensions are supported. On iOS the compiled C extensions are stripped, so submodules that need them (for example `Bio.Align`, `Bio.pairwise2`) cannot be imported; the pure-Python modules, including `Bio.Seq`, `Bio.SeqRecord`, `Bio.SeqUtils`, `Bio.Data` and `Bio.PDB`, work.
- **PyMOL modules**: Core packages `pymol`, `chempy`, and extension modules `_cmd` and `_champ`.
- **Unavailable packages**: Desktop-only GUI libraries (`PyQt5`, `PyQt6`, `PySide2`, `PySide6`, `tkinter`) are not bundled because RayMol uses native SwiftUI and Metal interfaces. Installing extra packages with `pip` is not supported: the bundled interpreter lives inside the signed application bundle.

See the [PyMOL command reference](https://pymolwiki.org/index.php/Category:Commands) for stock PyMOL commands.
