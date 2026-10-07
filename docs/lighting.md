# Studio lights

A light rig is a set of up to six spot lights placed around the molecules,
plus the air they shine through (haze and floating dust). Each light has its
own colour, warmth, beam and shadow. You set a rig up with the `lights` and
`atmosphere` commands, or in the app's Lights mode, and the Metal renderer
draws it on macOS, iPhone and iPad.

- **A rig never changes an object's colours, materials or settings.** It is
  applied at render time; `lights off` gives you PyMOL's own lighting back,
  exactly as it was.
- **No rig, no change.** Without a rig, or with the rig off, every image is
  the one RayMol drew before studio lights existed, byte for byte.
- **Metal only.** The CPU `ray` command keeps PyMOL's own lights and says so
  (see [Metal only](#metal-only-the-cpu-ray-tracer-and-exports)).

The pictures that go with this page are rendered from the repository by one
command (see [Regenerating the gallery](#regenerating-the-gallery)); no
image is committed.

## Quick start

Pick a preset, adjust a light, add some haze:

```pymol
lights three_point
lights key, warmth=3800, intensity=1.3
lights rim, color=cyan
atmosphere haze=0.2, dust=0.4
lights
```

The last line prints the rig: each light's placement, beam, colour and
shadow, and the air. `lights off` turns the rig off and keeps it; `lights on`
brings it back:

```pymol
lights three_point
lights off
lights on
```

In the app, choose **Enter Lights Mode** in the **Tools** menu (or
**Lights** in the toolbar's tools menu) to edit the same rig with the mouse
or by touch (see [In the app](#in-the-app)).

## Concepts

**The rig belongs to the scene.** There is one rig per PyMOL session. It is
not an object (it never appears in the object list and never widens the
scene's extent) and it is not a setting. `.pse` files save it, `reinitialize`
clears it, and `reinitialize settings` leaves it alone.

**On and off.** The rig is on when it is enabled and holds at least one
light. While it is on, PyMOL's own lights (`direct`, `reflect`, `specular`)
are scaled by the rig's `classic` value (0 by default, so only the studio
lights shine), and the rig's `ambient` replaces the `ambient` setting. No
setting is written: `lights off` turns the rig off, keeps it, and PyMOL's
lights are back exactly as they were.

**Camera and pinned lights.** A camera light (the default) follows the
camera: its orbit, pitch and radius place it around the rig's centre as the
camera sees it, so turning the molecule keeps it lit from the same side. A
pinned light (`pin=1`) stays where it is in world space, so it turns with the
molecules. A pinned light is fixed in space, not attached to one object:
moving one object does not move it.

**Aim.** A light aims at the rig's centre by default (`aim=centre`). It can
also aim at a world point, or at a selection: the light then aims at the
point the selection's centroid is at that moment, and does not follow the
atoms afterwards. Aim again to update it.

**The frame.** The rig's centre is the midpoint of the box around the
enabled objects, and its size (1x) is half the box diagonal: the edge of the
molecules. Both are captured when the first light is added or a preset is
applied, and again only when you re-centre (`lights recenter`, or
**Re-centre** in Lights mode). Showing, hiding or zooming never moves the
lights.

**Units and angles.**

- Radius is in scene sizes: 1 is the edge of the molecules, 4 (the default)
  is four times as far from the centre. `lights` prints the distance in Å
  alongside, for example `radius 4 (145.6 A)`.
- Orbit 0 is at the camera, +90 camera-right, -90 camera-left and 180 behind
  the molecule (a rim light). Orbit wraps into (-180, 180].
- Pitch 0 is level with the camera and +90 straight above, relative to the
  camera's up, not the molecule's.
- The beam is the cone's full angle in degrees. It stays fixed when the
  radius changes, as with a real spotlight, so a light moved closer lights a
  smaller patch.

**Limits.** A rig holds at most 6 lights, and at most 3 of them cast
shadows.

**Overlays.** The Lights-mode knobs, rings and labels are drawn by the app
over the viewport, never as scene geometry: they never cast shadows, never
enter ray tracing and never widen the scene's extent. A light's `outline`
(the beam's edge drawn on the molecules) is a drawing cue: it lights
nothing and casts nothing.

## The lights command

### Usage

```text
lights                               print the rig
lights presets                       list the presets
lights <preset> [, ambient=a] [, classic=c]
lights add [, name] [, field=value ...]
lights <name>                        print one light
lights <name>, field=value [, field=value ...]
lights remove, <name>
lights on | off | clear | recenter
lights ambient=a [, classic=c]       edit the rig
```

Arguments are separated by commas, as in every PyMOL command, so `lights`
chains with `;`. Keywords, presets and light names match ignoring case.

- `lights add` adds a light. Without a name it takes the first unused of
  key, fill, rim, light4, light5, light6. The first light captures the frame
  and turns the rig on.
- `lights remove, <name>` removes one light. Removing the last turns the rig
  off.
- `lights presets` lists the presets with their descriptions.
- `lights recenter` captures the centre and size again from what is shown
  now.
- `lights on` turns the rig on again (it needs lights); `lights off` turns it
  off and keeps it.
- `lights clear` removes every light. The rig keeps its air, `ambient` and
  `classic`, and is off until `lights add` or a preset.

```pymol
lights three_point
lights add, top, pitch=80, beam=90, intensity=0.4
lights top, softness=1
lights remove, top
lights presets
```

Every error names the field or value and changes nothing. In a `;` chain,
PyMOL skips the rest of the line after an error:

```text
PyMOL>lights three_point
PyMOL>lights key, pitch=100
 Error: lights: key: pitch=100 is out of range -90 to 90 (degrees)
PyMOL>lights key orbit=-45
 Error: lights: 'key orbit=-45': separate arguments with commas, e.g. lights key, orbit=-45, pitch=35
PyMOL>lights add, spot, shadow=1
PyMOL>lights add, back, orbit=180, shadow=1
PyMOL>lights rim, shadow=1
 Error: lights: rim: shadow=1: at most 3 lights cast shadows (key, spot, back already do)
```

### Presets

A preset replaces the lights, `ambient` and `classic` (0 for every preset),
keeps the air, turns the rig on and captures the frame again. Only
`ambient=` and `classic=` can be given with it; edit a light afterwards for
anything else.

| Preset | Lights | Ambient | Description |
| --- | --- | --- | --- |
| `three_point` | key, fill, rim | 0.1 | Classic portrait: warm key with shadow, cool fill, white rim |
| `softbox` | left, right, top | 0.16 | Product shot: two big soft white boxes, gentle top light |
| `spotlight` | spot, bounce | 0.05 | Theatre: one narrow beam from above, the rest falls off |
| `rembrandt` | key, kicker | 0.04 | Dramatic: one hard warm key high to the side, almost no fill |
| `neon` | magenta, cyan, front | 0.06 | Coloured rims: magenta and cyan from behind, dim violet front |
| `sunset` | sun, sky | 0.08 | Low orange sun from one side, blue sky fill from the other |
| `underlight` | under, rim | 0.04 | Horror-film: green-tinted key from below, red rim |

Each preset's first light casts a shadow. `spotlight` aims its spot a little
off the centre (0.25 sizes left and 0.15 up, as the camera sees it when the
preset is applied). Preset colours are literal RGB, so `set_color` never
changes a preset.

```pymol
lights neon, ambient=0.1
lights sunset
```

### Light fields

A number outside its range is an error (orbit wraps instead). Booleans take
1/0, on/off, true/false or yes/no. The alias is the prototype's name for the
field, still accepted.

| Field | Alias | Range | Default | What |
| --- | --- | --- | --- | --- |
| `orbit` | `az` | -180 to 180 (wraps), degrees | 0 | Around the centre: 0 at the camera, 90 camera-right, 180 behind. |
| `pitch` | `el` | -90 to 90, degrees | 30 | Up and down: 0 level with the camera, 90 above. |
| `radius` | `dist` | 0.5 to 8, scene sizes | 4 | Distance from the centre; 1 is the edge of the molecules. |
| `beam` | | 1 to 170, degrees | 45 | The cone's full angle; fixed when the radius changes. |
| `softness` | `soft` | 0 to 1 | 0.4 | The share of the cone that fades out at its edge. |
| `color` | `colour` | each channel 0 to 1 | white | A PyMOL colour name (a unique start is enough), `0xRRGGBB` or r/g/b. `color=warm`, `neutral` or `cool` set white with warmth 3200, 6500 or 9000 K. |
| `rgb` | | each channel 0 to 1 (or 0 to 255) | | Sets `color` from r/g/b or `[r,g,b]`. |
| `warmth` | `kelvin` | 1500 to 15000, kelvin | 6500 | Colour temperature; multiplies `color`. Lower is warmer. |
| `intensity` | `int` | 0 to 4 | 1 | Brightness. Bright rigs roll off without whitening (see [Exposure and HDR](#exposure-and-hdr)). |
| `highlight` | `spec` | 0 to 1 | 0.5 | Strength of the light's coloured specular highlight. |
| `falloff` | | 0 to 2 | 2 | Brightness goes as (aim distance / distance)^falloff: 2 is inverse square, 0 none. |
| `shadow` | | 0 or 1 | 0 | The light casts its own shadow (at most 3 lights do). |
| `outline` | `cue` | 0 or 1 | 0 | Draw the beam's edge on the molecules. |
| `aim` | | `centre`, a point or a selection | centre | Where the light points: the rig centre, a world point `x/y/z` in Å, or a selection's centroid (resolved once). |
| `anchor` | | `camera` or `pinned` | camera | Whether the light follows the camera or stays put in the scene. |
| `pin` | | 0 or 1 | | `pin=1` pins the light where it is now; `pin=0` makes it a camera light again (stored as `anchor`). |
| `position` | | world point in Å | | Pins the light at that point. |
| `name` | | letters, digits and _ | | Renames the light (at most 32 characters, unique ignoring case, not a preset or keyword). |
| `aim_point` | | world point in Å | | Stored: the point the light aims at, set by `aim=` and the placement helpers. |
| `aim_selection` | | text | | Stored: the selection `aim_point` came from (display only). |

Fields that set the same thing cannot be given together: `color` with
`rgb`, `color=warm/neutral/cool` with `warmth`, `pin` with `anchor`,
`position` with `orbit`, `pitch`, `radius` or `pin=0`, and a field with its
alias. A pinned light shows its current orbit, pitch and radius in `lights
<name>`, and setting one of them moves it there and keeps it pinned.

```pymol
lights three_point
lights key, orbit=-60, pitch=20, color=warm
lights fill, rgb=0.6/0.8/1.0, intensity=0.5
lights rim, beam=30, softness=0.2, outline=1
lights key, aim=organic
lights key, aim=centre
```

### Rig fields

| Field | Alias | Range | Default | What |
| --- | --- | --- | --- | --- |
| `ambient` | | 0 to 1 | 0.05 | Replaces the `ambient` setting while the rig is on. |
| `classic` | | 0 to 1 | 0 | Scales PyMOL's own direct, reflect and specular lights while the rig is on. |
| `enabled` | | set by `lights on` and `lights off` | 0 | Whether the rig is on (an empty rig is off). |
| `centre` | | world point in Å | | The frame's centre, captured with the first light, by a preset and by `lights recenter`. |
| `size` | | at least 1 Å | | Half the box diagonal, captured with the centre; `radius` is in multiples of it. |

With no rig, `lights ambient=...` (like `atmosphere ...`) creates an empty
rig that is off and holds the value.

```pymol
lights three_point
lights ambient=0.15, classic=0.3
```

### Placement helpers

Helpers are resolved once, when they are given; the light does not follow
the atoms or the surface afterwards. `highlight=` and `click=` use the
native surface pick: whatever is drawn as a surface, cartoon, spheres or
sticks.

- `target=<selection>` aims at the selection's centroid and fits the beam
  to the selection (its radius plus 1.5 Å). The light keeps its anchor,
  orbit, pitch and radius.
- `highlight=<selection>` places the light so that the drawn surface at the
  selection's centre (as the camera sees it) shows a highlight: along the
  mirror direction of its normal. The selection must be on screen, and the
  surface hit must be its own (within 1.5 Å of one of its atoms). Not in grid
  mode (use `click=`).
- `click=x/y` does the same for the surface under a point of the viewport:
  x and y from -1 to 1, 0/0 the centre, 1/1 the top right corner.
- `rim=<degrees>` goes with `highlight=` or `click=`: it turns the light that
  many degrees (0 to under 180) away from the camera direction, towards the
  side of the surface, for a rim light. 0 is the mirror rule.
- `pin=1` with a helper pins the light where the helper put it.

`highlight=` and `click=` store the picked point as the aim and place the
light on its radius as a camera light. When the picked point is on or beyond
that radius, the radius is raised to put the light half a size past it, with
a note; past 8 that is an error (re-centre first). The beam is fitted to a
10 Å patch around the point unless `beam=` is given. One helper at a time;
`orbit`, `pitch` and `position` cannot be given with `highlight=` or
`click=`, and `aim` with no helper.

```pymol
lights three_point
lights key, target=organic
lights add, spot, highlight=organic, beam=20
lights rim, highlight=organic, rim=150
lights key, pin=1
turn y, 90
lights key
```

`click=` depends on the window's shape, so its result differs from window to
window:

```text
lights rim, click=0.3/0.2, rim=150, pin=1
```

In the app, the same placement is an option-click (macOS) or a long press
(iOS) on the molecule in Lights mode.

### From Python

`cmd.lights` and `cmd.atmosphere` take the same arguments as the commands,
with numbers, booleans and lists as field values. `cmd.lights()` returns the
rig as `cmd.get_lights()` does, `cmd.lights('<name>')` that light's dict,
`cmd.lights('presets')` the `[(name, description), ...]` list, and
`cmd.lights('add', ...)` the new light's name.

`cmd.get_lights()` returns the whole rig as a dict (or `None` with no rig),
and `cmd.set_lights(rig)` replaces it from such a dict (`None` removes it):

```python
from pymol import cmd
cmd.lights('three_point')
cmd.lights('key', orbit=-30, intensity=1.4, shadow=True)
name = cmd.lights('add', pitch=-40, color=[0.6, 0.8, 1.0], intensity=0.5)
rig = cmd.get_lights()
rig['lights'][0]['warmth'] = 3800
cmd.set_lights(rig)
cmd.atmosphere(haze=0.2, dust=0.3)
```

The dict is versioned (`'version': 1`) and holds `enabled`, `centre`,
`size`, `ambient`, `classic`, `air` and `lights`, with the fields of the
tables above. `set_lights` fills missing keys with their defaults, captures
the frame when the dict has lights and no `centre` and `size`, and refuses a
bad dict with a `CmdException` naming the key (the rig is then unchanged).

## The atmosphere command

```text
atmosphere                           print the air
atmosphere field=value [, field=value ...]
atmosphere off                       every field back to its default
```

The air is haze and floating dust that the studio lights shine through. It
shows only inside the beams, and only while the lights are on.

```pymol
lights three_point
atmosphere haze=0.3, dust=0.5, dust_size=0.4, dust_speed=1
atmosphere seed=7
atmosphere
atmosphere off
```

- With no rig, `atmosphere field=...` creates a rig that is off and has no
  lights; the air shows once a preset or `lights add` turns it on.
- **Presets carry no air.** A preset keeps the current air, and so do
  `lights off` and `lights clear`; `atmosphere off` resets it.
- The air is set with `atmosphere` (console, scripts, sessions and scenes)
  or with the app's **Atmosphere** card (see [The Atmosphere
  card](#the-atmosphere-card)). The two mirror each other.

### Air fields

| Field | Alias | Range | Default | What |
| --- | --- | --- | --- | --- |
| `haze` | | 0 to 1 | 0 | The amount of haze in the air. |
| `dust` | | 0 to 1 | 0 | The amount of floating dust. |
| `dust_size` | | 0.05 to 2 | 0.35 | The size of the dust motes, relative to the size of the scene (the rig's frame). |
| `dust_speed` | | 0 to 10 | 1 | How fast the dust drifts: 1 is real time, 0 holds it still. |
| `scatter` | | -0.9 to 0.9 | 0.55 | Forward scattering (g): above 0, the air glows more where a beam points towards the camera. |
| `seed` | | 0 to 1000000 | 0 | The dust pattern (a whole number). |

### How the air renders and redraws

- The air is its own pass after the scene is drawn (with Metal ray tracing
  on or off), before transparency.
- Haze is lit only inside the cones, and every shadowed light shadows it:
  the molecule's shadow in the haze is a light shaft. Shafts need a light with
  `shadow=1` and `metal_shadows` on. Dust motes glint only inside beams.
- The air spans the rig's frame, so showing, hiding or zooming never moves it
  (`lights recenter` does). It needs something shown: with nothing enabled,
  or only overlays such as the Move gizmo, there is no air. It is not drawn
  in `grid_mode` (#686).
- Haze alone is still: only dust moves. The live view redraws for the dust
  only while the rig is on with dust and `dust_speed` above 0, the dust clock
  is not pinned, no movie plays, nothing is in grid mode and something is
  shown. The app then redraws at most 30 times a second, and only while it is
  active and its window visible. In Low Power Mode, or at a serious or
  critical thermal state, the dust holds still.
- **The dust clock.** `metal_light_air_time` 0 or more pins it to that many
  seconds (before `dust_speed`), for repeatable renders. Below 0 (the
  default), exports and a playing movie use movie time (frame N at
  (N - 1) / `movie_fps` seconds), so a movie export is repeatable; an
  offscreen still with no movie uses time 0 (but see #688); the live view
  uses the wall clock.
- The air pass runs at half resolution by default on the Mac and on iOS
  (`metal_light_air_resolution`), and the haze takes one shadow tap per step
  (`metal_light_air_shadow_filter`); see [Settings](#settings).

### Backlit haze

Haze above about 0.3 with a light behind the molecule (a rim or back light
aimed near the camera) can wash the picture out: the air only adds light, and
forward scattering is strongest looking into the beam. Lower the haze, move
the light, or lower the exposure (`set metal_exposure, 0.6`): under HDR,
exposure scales the air with the lit scene, and the molecule keeps its
colour and contrast. The haze itself is unchanged: it still has no
extinction (#683, open; see [Known limits](#known-limits)). With the 8-bit
knee (`metal_light_hdr 2`), the frame clips to white instead. The app's
Atmosphere card shows a hint while this applies.

```pymol
lights three_point
atmosphere haze=0.35, dust=0.6
set metal_exposure, 0.5
set metal_exposure, 1
```

## Shadows

Any light can cast its own shadow (`shadow=1`, or **Shadow** in the
inspector), in its own colour: a red light's shadow is where the red light
does not reach.

- Each shadowed light gets its own shadow map, for the first three shadowed
  lights in rig order (a rig holds at most 3), filtered over 3x3 texels.
- Studio shadows need the scene's `metal_shadows` on. At `metal_shadows 0`,
  shadowed lights render unshadowed (the inspector says so, with a
  **Turn On** button).
- While any studio shadow is on, PyMOL's whole-pixel shadow (the classic
  Metal shadow and the traced one) is off, so the molecule is not shadowed
  twice.
- The light overlays never cast shadows, and the maps are fitted to the
  molecules without them.
- In grid mode (`grid_mode 1`), each map is a tile atlas, one tile per grid
  cell, and each cell is shadowed by its own objects only. The tile side is
  the map size divided by the larger of the grid's columns and rows (rounded
  down), so a large grid has coarser shadows.
- Bezier tube cartoons neither cast nor receive studio shadows (#663).
- With `metal_raytrace 1`, what a traced reflection shows is lit by the
  studio lights but not studio-shadowed (#664).
- `metal_light_shadow_size` sets each map's texels per side: 0 is the
  platform default (2048 on the Mac, 1024 on iOS); other values are clamped
  to 256 to 4096 (256 to 2048 on iOS) and rounded down to a power of two.

```pymol
lights three_point
lights rim, shadow=1
set metal_light_shadow_size, 1024
set metal_light_shadow_size, 0
```

## Exposure and HDR

Under a rig, light is kept in scene units, where a bright rig goes above 1.
It is multiplied by `metal_exposure` and then mapped once through a
hue-preserving tone curve before the image is stored. So a bright light rolls
off towards white keeping its hue, instead of whitening early, and a light up
to `intensity` 4 stays readable. The image is still stored in 8 bits per
channel; there is no float render target.

- **Exposure under a rig.** With a rig on and HDR on, `metal_exposure`
  scales what the rig lights (the studio lights and PyMOL's `classic` terms)
  and the air. It no longer scales the background, labels, unlit lines or
  outlines. This changes #13's whole-frame exposure while a rig is on: a
  session saved with an exposure other than 1 renders its background
  differently from before.
- **No rig, a rig that is off, or `metal_light_hdr 2`:** exposure is the
  whole-frame multiplier it always was.
- `metal_tonemap` (**Filmic tone-map** in the Scene panel's Effects) applies
  its ACES curve after the rig's curve, at exposure 1, since the exposure is
  already applied.
- `metal_light_hdr`: 0 is the platform default (HDR on the Mac and on iOS;
  the iOS value is provisional until #623's device run); 1 HDR; 2 the 8-bit
  soft knee, exactly as before HDR; any other value reads as 0. It is read
  only while a rig is on, and it is not part of a scene's look.
- Exposure is the remedy for a bright rig and for backlit haze (see [Backlit
  haze](#backlit-haze)).
- The Scene panel's **Exposure** slider (Effects, 0.2 to 2.0) is the same
  `metal_exposure`; its help text does not yet say what it scales under a
  rig (#733).

```pymol
lights spotlight
lights spot, intensity=3.5
set metal_exposure, 0.6
set metal_light_hdr, 2
set metal_light_hdr, 0
set metal_exposure, 1
```

The materials' own classic terms still pass their 8-bit knee before the
rig's curve (#731); see [Materials under studio lights](materials.md#under-studio-lights)
and [Known limits](#known-limits).

## In the app

### macOS

**Entering.** Choose **Enter Lights Mode** in the **Tools** menu, or
**Lights** in the toolbar's tools menu. Lights mode is an interaction mode,
like Move and Measure: entering it leaves the others.

**The Lights bar.** It floats at the top of the viewport and shows a chip per
light (with the light's identity colour, hollow while the light is behind
the molecule), add and remove buttons, **Presets**, **Re-centre**, the
**Lights on** / **Lights off** switch, **Revert** and **Done**.

- **Re-centre** captures the centre and 1x size from the molecules again,
  as `lights recenter` does.
- **Revert** puts back the rig you had when you entered Lights mode, air
  included. **Done** (or Esc) keeps your edits and leaves the mode. Light
  and air edits register no undo: Revert is the way back.

One light is selected at a time, and the bar, the gizmo, the orbit view and
the inspector share it. Every edit shows in all of them, and in the
`lights` command's output, at once.

**The orbit view.** A card in the column beside the scene: a flat plan of
the rig seen from above, with the camera at the bottom and +90 to the right,
beside a pitch arc for the selected light.

- Drag a lamp to change its orbit only, in 15 degree steps. A tap selects a
  light.
- Drag the square on the selected light's ring, or pinch the plan, to change
  the radius only, in steps of 0.5x. The beam keeps its angle.
- Drag the arc to change the pitch only (-90 to +90).
- A pinned light moves round the plan as the molecule turns.

**The inspector.** It sits under the orbit view and holds the selected
light's exact values: **Orbit** and **Pitch** (a dial, a field and a stepper:
the stepper moves 5 degrees, and the Up and Down arrow keys in a field 1
degree), sliders for **Radius**, **Intensity**, **Warmth**, **Beam** and
**Softness**, colour swatches and a picker, the **Shadow** and **Pin**
toggles, **Revert this light** and **Delete**. A Shadow press on a fourth
light says that at most 3 lights cast shadows; when the scene's **Shadows**
switch is off, a hint offers **Turn On**.

**The gizmo.** It is drawn over the scene in Lights mode: a knob per light
on a sphere around the subject, filled in front and hollow behind the
molecule.

- Drag a knob to move the light; dragging it across the outline swaps front
  and behind.
- The selected light shows its beam: drag the outer ring to set the beam,
  the inner ring to set the softness, and the aim dot to re-aim the light at
  the surface under the pointer.
- Scroll over a knob to change its radius.
- Option-click the molecule to place a highlight there (the `click=`
  helper: the mirror rule, or a rim light near the outline).
- A **Shadow** chip beside the selected knob toggles its shadow.

### The Atmosphere card

The **Atmosphere** card edits the rig's air: **Haze**, **Dust**,
**Dust size** and **Dust speed**, each a slider with a typed field, and
**Scatter (g)** under a disclosure. The dust seed is set only with
`atmosphere seed=` (#740). Ranges and defaults are the `atmosphere` command's.

- **The switch.** The card's header holds an on/off switch. Off runs
  exactly `atmosphere off` (every field back to its default), after the card
  remembers the air you had. On puts the remembered air back with one
  `atmosphere` command, or, with nothing remembered, a start look of haze 0.2
  and dust 0.5. The memory lasts one Lights-mode visit.
- **Mirroring.** A slider or a typed value changes the air at once, and an
  `atmosphere` command typed in the console shows in the card. Sessions and
  scenes store the air as they always did.
- **Revert** in the bar restores the air you entered with; **Done** keeps
  your edits. The card registers no undo.
- **Hints.** One hint at a time explains why the air may not show: with no light,
  "Haze and dust show only inside a light's beam. Add a light to see them."; with
  the lights off, "The air shows only while the lights are on."; and with
  haze above about 0.3 and a light behind the molecule, "Haze above about 0.3
  with a light behind the molecule can wash the picture out. Lower the haze or
  move the light." (see [Backlit haze](#backlit-haze)). A collapsed card shows
  the hint as a glyph in its header.
- **Where it sits.** On macOS, a third card under the inspector in the side
  column; it starts expanded when the air is on as you enter Lights mode. On
  iPad, under the inspector, collapsed to its header. On iPhone, a section
  after the inspector's rows in the sheet and in the landscape side panel; an
  **Atmosphere** button in the sheet's header opens it. With no light, the
  iPhone shows a compact air-only sheet (the card's header, its hint and its
  rows), so the switch is reachable before the first light.

### iPhone and iPad

The light tools are placed by size class, not by device:

- **iPhone (portrait), and iPad Slide Over:** a two-height sheet docked
  under the viewport. Compact, it shows the plan beside Pitch, Intensity and
  a Colour button; pulled up (More), the plan and the pitch arc stay pinned
  and every inspector row scrolls below them.
- **iPhone in landscape:** the same tools in the trailing side panel.
- **iPad:** the orbit view floats over the viewport in a corner
  (bottom-leading by default; drag its header to move it to another corner,
  which is remembered), and the inspector sits at the top trailing corner,
  starting collapsed to its header.

**Touch.** Every light target is at least 44 pt. Only the knobs, rings, the
square and the aim dot edit lights; every other gesture stays a camera
gesture. Pinch on a knob to change its radius, and long-press the molecule
to place a highlight (as option-click does on the Mac).

**iOS defaults are provisional.** They hold until #623's device run: the
shadow map size
(1024), the air resolution (half), the air's shadow filter (one tap), the
30-a-second dust cap and HDR (on). See [Performance and
iOS](#performance-and-ios).

## Scenes, sessions and movies

- **Sessions.** A `.pse` saves the rig, air included (the `light_rig`
  session key). A full session with no rig clears the rig on load; a partial
  restore leaves it alone. Older RayMol builds ignore the key and open the
  file with PyMOL's lighting.
- **Scenes.** Each `scene` stores its own rig and air (`raymol_scene_lights`
  in the session), and recalling the scene restores them. A scene stored with
  no rig on records "off", so recalling it turns the rig off; a scene from an
  older `.pse` has no entry and leaves the rig alone.
- **Movies.** Scene movies blend the rig between scenes with the camera's
  easing. Lights are matched by name. Orbit, pitch, radius, beam, softness,
  intensity, warmth, highlight, falloff, `ambient`, `classic` and the air's
  values blend; angles take the shortest way round, and colour blends in
  linear RGB. A light in only one of the two scenes fades in or out. Shadow,
  outline, anchor, aim and the rig's on/off switch change at the cut.
- **Limits.** The loop-wrap of a looping movie, from the last scene back to
  the first, does not blend the rig (#656). Recalling a scene with animation
  in the live view switches the rig at once while the camera moves (#661).
  The dust jumps when `dust_speed` differs between two scenes (#687).

```pymol
lights three_point
scene warm, store
lights neon
scene cool, store
scene warm
```

## Metal only: the CPU ray tracer and exports

Studio lights are drawn by the Metal renderer only. This was decided in #626:
PyMOL's CPU ray tracer keeps PyMOL's own lights and never reads the rig.
When it traces an image while the rig is on, it prints one line per command:

```text
 Ray: studio lights are Metal-only; this ray-traced image uses PyMOL's lights.
```

- The commands that print it: `ray`, `png ..., ray=1`, a `png` or `save
  x.png` in a session with no Metal view (such as `pymol -c`), and `mpng` in
  ray mode (once per call). The image is exactly the one traced
  with no rig.
- It is a Ray warning: `feedback disable, ray, warnings` silences it.
- The `classic` scaling and the `ambient` replacement (see
  [Concepts](#concepts)) apply to Metal only; the CPU tracer uses the
  `ambient`, `direct`, `reflect` and `specular` settings as they are.
- Geometry and scene exports (`save` to `.pov`, `.wrl`, `.obj`, `.dae`,
  `.idtf` or `.gltf`, and `get_povray`) never carry the rig and print no
  notice. Those that carry lights at all carry PyMOL's own.
- In the app, image exports render with Metal, so they keep the studio look,
  including **Ray-traced (AO + shadows)** (Metal ray tracing), and so does a
  `png` typed in the app's console without `ray=1`.
- The MCP `capture_viewport` tool renders with the CPU ray tracer, so its
  image has no studio lights; while the rig is on it adds a `Note:` with the
  notice after the image (#643).

```text
lights three_point
png ~/lit.png, width=1200, height=800, ray=1
 Ray: studio lights are Metal-only; this ray-traced image uses PyMOL's lights.
feedback disable, ray, warnings
```

## Settings

The rig itself is not a setting. These settings tune how it renders; the
platform defaults of the `metal_light_*` settings on iOS are provisional
until #623's device run.

| Setting | What | Default | Saved in scenes |
| --- | --- | --- | --- |
| `metal_light_shadow_size` | Texels per side of each studio shadow map. Other values are clamped to 256 to 4096 (256 to 2048 on iOS) and rounded down to a power of two. | `0`: 2048 on the Mac, 1024 on iOS | no |
| `metal_light_air_resolution` | The air pass's resolution: 1 full, 2 half; anything else reads as 0. | `0`: half on the Mac, half on iOS | no |
| `metal_light_air_time` | Below 0 the dust follows its clock; 0 or more pins the clock to that many seconds, for repeatable renders. | `-1` | no |
| `metal_light_air_shadow_filter` | The haze's shadow lookup per step: 1 one tap, 2 the 3x3 lookup; anything else reads as 0. Dust motes always use the 3x3. | `0`: one tap on the Mac, one tap on iOS | no |
| `metal_light_hdr` | The rig's colour: 1 HDR (exposure and a hue-preserving tone curve), 2 the 8-bit soft knee as before HDR; anything else reads as 0. | `0`: HDR on the Mac, HDR on iOS | no |
| `metal_gpu_timing` | Debug readout of GPU frame times: 0 off, 1 a summary about once a second, 2 every frame (see [Performance and iOS](#performance-and-ios)). | `0` | no |
| `metal_shadows` | The scene's Shadows switch; studio shadows need it on. | `on` | yes |
| `metal_exposure` | Exposure: under a rig with HDR, it scales the lit scene and the air; otherwise the whole frame. | `1` | yes |
| `metal_tonemap` | The filmic (ACES) tone curve, after the rig's own. | `off` | yes |

The `metal_light_*` settings and `metal_gpu_timing` are read only while they
matter (a rig on, a shadowed light, the air drawn) and are not part of a
scene's look, so scenes do not store them. They are global settings, and a
`.pse` saves them like any other setting.

## Performance and iOS

**The budget.** On an iPhone with an A16 or newer and an M-series iPad, with
a 1,300-atom protein, 3 shadowed lights and dust on: 60 frames a second
sustained, and at most about 4 ms of added GPU time per frame against no
rig. It is checked on devices in #623.

**The GPU-time readout.** `set metal_gpu_timing, 1` logs a summary of the
GPU frame times about once a second; `2` logs every frame. Offscreen frames
(exports) are logged in both modes. The lines go to the app's log (Console
on macOS, the Xcode console on iOS):

```text
RendererMetal: gpu_ms window n=60 median=3.10 p95=3.80 max=4.20 shadow_maps=3 shadow_size=1024
RendererMetal: gpu_ms frame=3.12 shadow_maps=3 shadow_size=1024 offscreen=0
```

Times are in milliseconds, with the number and size of the studio shadow
maps drawn that frame. Turning the setting on, or changing its mode, starts
the statistics afresh.

**Fallback switches.** For a device that misses the budget:

- `metal_light_shadow_size` (smaller maps);
- `metal_light_air_resolution` (2, half);
- `metal_light_air_shadow_filter` (1, one tap);
- `metal_light_hdr 2` (the 8-bit knee);
- fewer shadowed lights.

**Launch switches.** For calibrating the dust's redraw rate, the app reads
two environment variables once at launch:

- `RAYMOL_AIR_FPS=<n>`, with n from 1 to 120, replaces the cap of 30 air
  redraws a second;
- `RAYMOL_AIR_LOG=1` logs each change of why the dust holds still, with Low
  Power Mode and the thermal state, so a device run can see the policy act.

The iOS defaults (1024 shadow maps, half-resolution air, one tap, HDR on,
30 redraws a second) are provisional until #623's device run.

## Known limits

Open follow-ups of the lighting work (#610) that you may notice:

- **Shadows.** Bezier tube cartoons neither cast nor receive studio shadows
  (#663). Traced reflection hits are not studio-shadowed (#664) and take the
  `default` material's light response (#709). Shadows have one softness, set
  by the 3x3 filter; soft shadows from a light's size are planned (#741,
  #742).
- **Overlays.** The Lights-mode overlays never cast, but the Move gizmo and
  gadgets still enter PyMOL's classic Metal shadow pre-pass and the
  ray-tracing structure (#662), and a rig created while the Move gizmo is
  shown frames it too (#669). The frame also counts enabled objects whose
  representations are all hidden (#690).
- **The air.** The haze only adds light (it has no extinction), so haze
  above about 0.3 with a light behind the molecule washes the picture out;
  lower the exposure, the haze or the light (#683, see [Backlit
  haze](#backlit-haze)). No air in grid mode (#686). Transparent-background
  exports drop the air over the empty background (#684). Animated dust
  redraws the whole scene on every tick (#685). An offscreen still of a
  multi-state object with no movie takes its dust time from the state
  (#688). The dust jumps when `dust_speed` is blended across scenes (#687).
  The dust seed has no control in the Atmosphere card (#740).
- **Materials and HDR.** The studio diffuse lights a material's plain base
  colour, not its procedural pattern (#710). Glass glints on sphere impostors
  do not show (#713). The materials' own classic terms pass their 8-bit knee
  before the rig's curve (#731); the traced rig composite keeps some classic
  terms in display units (#729); ambient occlusion is composited after the
  tone curve (#732). Bloom, EDR output, 16-bit export and ACES in scene units
  are not done (#735). Measurement dashes take the rig's lighting (#738).
- **Scenes and movies.** The loop-wrap of a looping movie (#656) and an
  animated scene recall in the live view (#661) do not blend the rig.
- **Placement.** A highlight placed on a small patch can fit the beam to a
  few degrees (#723); set `beam=` to widen it.
- **The app.** The gizmo's ring handles can land off-screen or under the bars
  (#693). A plain click in Lights mode still picks atoms (#696). The gizmo is
  not projected per cell in grid mode (#697). On iPad, an open camera dock can
  lift the orbit card onto the key knob (#718), and typing in the inspector
  can resize the viewport (#725). On iOS, the inspector's Orbit and Pitch
  steppers are under 44 pt (#720), and on small rings the 44 pt ring band
  covers the whole interior (#721). The Scene panel's Exposure help text does
  not say what exposure scales under a rig (#733).
- **Exports and MCP.** The MCP `capture_viewport` tool renders with the CPU
  ray tracer, without the studio look (#643). Metal exports do not draw ramp
  gadgets or `bg_gradient` (#689).

## Regenerating the gallery

`scripts/lighting/gallery.py` renders the gallery for this page from a clean
checkout: 56 images in seven sections, each with a contact sheet. It drives a
built app headless through the lighting harness (`scripts/lighting/render.py`,
on `testing/data/1rx1.pdb`), so it needs a RayMol.app copied with its own
bundle id (the harness refuses `io.raymol.RayMol` and an app with MCP
enabled), plus Pillow and numpy:

```text
python3 scripts/lighting/gallery.py --app /tmp/RayMol-dev.app --out /tmp/lighting-gallery
open /tmp/lighting-gallery/index.html
```

| Section | Images | Scene file | Shows |
| --- | --- | --- | --- |
| `rigs` | 8 | `gallery.json` | PyMOL's own lights, then each preset |
| `light` | 12 | `gallery.json` | One light field at a time: beam, softness, warmth, colour |
| `place` | 6 | `gallery.json` | `target=`, `highlight=` and `rim=`; a camera light against a pinned one |
| `shadows` | 5 | `gallery.json` | Per-light coloured shadows, raster and traced |
| `air` | 9 | `gallery.json` | Haze, dust and shafts, with Metal ray tracing off and on; the pinned dust clock |
| `exposure` | 6 | `lighting_624.json` | HDR roll-off, exposure, the 8-bit knee and backlit haze |
| `materials` | 10 | `lighting_615_gallery.json` | Every material under `three_point` |

A full run is three harness calls (one per scene file) and takes about ten
minutes.

- `--sections air,exposure` renders only those sections (the others are
  assembled from disk when present).
- `--dry-run` writes every scene script and prints the harness calls it
  would make, without launching anything (no `--app` needed).
- `--skip-render` only assembles the sheets, checks and pages from images
  already on disk, for example after rendering each scene file with the
  harness directly.
- `--timeout N` is the harness's per-image limit, in seconds.

The output directory holds `<scene file stem>/` (the harness's images and
`render.json`), `<section>.png` (each section's sheet: a caption row, then
the images in order), `index.html` and `gallery.json` (the checks, and the
app's build against the checkout's HEAD). Every path is checked before
anything is deleted, and a run clears only the sections it renders.

Each section's checks compare pairs of images (each preset against PyMOL's
lights, each step of a sweep against the one before): a pair that does not
differ fails, which catches a command the renderer ignored. Nothing judged by
eye is automated. The exit code is 0 when every requested image rendered and
every check passed, 1 when an image or a check failed, and 2 for a refusal
or a usage error. The images are never committed.
