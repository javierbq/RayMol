---
title: Morphing
description: Turn an NMR ensemble, trajectory snapshots or a set of predicted models into a smooth, looping morph for inspection and movies.
---

A multi-state object flips from one model to the next when it plays. A morph
makes it glide: RayMol computes the frames between consecutive models and
stores them as a new object beside the original, which plays smoothly in the
viewport, in movie clips and in exported videos.

## What a morph is

A morph is built from a **source**: any object with two or more states (models)
that all hold the same atoms, such as an NMR ensemble, snapshots from a
molecular dynamics trajectory, or several predicted models of one sequence
loaded as states.

- Every pair of consecutive models becomes one **leg** of interpolated frames
  (15 frames per model by default). With **Loop back to model 1** on (the
  default), the last model morphs back into the first, so playback loops
  without a jump.
- The **key frames** are the original models, copied exactly. At 15 frames per
  model, model 1 is frame 1, model 2 is frame 16, model 3 is frame 31, and so
  on, except that with Loop off the last model is the last frame (model 20 of
  20 is frame 285, not 286). Only the frames between key frames are computed.
- The default method, **Rigid segments**, splits each chain into rigid segments
  at the hinges where the two models differ, moves every segment along a screw
  path, and blends the motion across each hinge. **Linear** moves every atom
  along a straight line instead: faster, but parts that rotate can shrink or
  distort on the way.
- A **clean-up** pass then relaxes the intermediate frames with PyMOL's
  sculpting, with the backbone held fixed. Key frames are never sculpted.
- The result is a separate object named `<source>_morph`. The source keeps its
  states, coordinates and numbering; it is only hidden once the morph is
  complete.

A 20-model NMR ensemble at 15 frames per model gives a 300-frame morph, a
10-second loop at 30 fps.

## Morph from the Object panel

1. In the **Objects** tab, expand the multi-state object. Under its **State**
   slider, on the **Overlay all** line, are the **Fit**, **Split**, **Sync**
   and **Morph…** buttons.
2. Select **Morph…**. The Morph sheet opens, titled with the object's name
   (**Morph 2kpo**) and its model count.
3. Adjust the settings and select **Morph**.

| Setting | Range | Default | What it does |
| :--- | :--- | :--- | :--- |
| **Frames per model** | 2–120 | 15 | Frames in each leg, from one model to the next. |
| **Loop back to model 1** | On / off | On | Adds the leg from the last model back to the first. |
| **Method** | Rigid segments / Linear | Rigid segments | How the frames between two models are computed (see above). |
| **Clean-up cycles** | 0–10 | 3 | Sculpting on every intermediate frame, backbone fixed; each cycle is 10 sculpting iterations. 0 skips the clean-up. |
| **Rate** | Linear, Sinusoidal, Ramp up, Ramp down | Linear | The pace inside each leg: constant (Linear), easing out of and into every model (Sinusoidal), starting slowly (Ramp up), or ending slowly (Ramp down). |

The line under the settings summarises the job and updates as you change them,
for example `20 models → 300 frames · 10 s at 30 fps · ≈ 29 MB · creates
2kpo_morph, hides 2kpo`. The seconds use the movie frame rate, which is also
the speed the finished morph plays at. The line turns orange above the memory
warning level, and **Morph** is disabled above the limit (see
[Memory and size](#memory-and-size)). If the object shows a surface or mesh, a
second line reminds you that they are not carried to the morph.

The sheet remembers the settings you last morphed with.

### While it builds

The morph builds in the background, so you can keep rotating, restyling and
working with other objects. A card in the progress tray reads **Morphing
2kpo_morph**, `leg 6 of 20 · 30%`, with a **Cancel** button. The source stays
on screen meanwhile; the `2kpo_morph` row appears at once, switched off, and
its frame count rises as the legs land. **Morph…** is hidden on the source and
on the morph until the build finishes or is cancelled, so cancel the build to
change its settings.

**Cancel** deletes the partial morph and shows the source again; the card then
reads **Morph cancelled** until you select **Dismiss**. A build that fails (for
example, because the source was deleted) leaves a **Morph failed** card with
the reason.

### When it is done

- The source is hidden and the `2kpo_morph` row is shown, expanded, with a
  loop (repeat) icon before its frame count (tooltip "Morph of 2kpo · 300
  frames").
- It starts playing at the movie frame rate (its Play speed is set to match).
  While the Movie timeline is open, model playback is off, so the morph waits
  on its first frame instead.
- The **Name** line tells you where you are: `model 7` on a key frame, `7 → 8`
  between models, `20 → 1` on the leg that loops back.
- From here it is an ordinary multi-state object: the State slider, Play,
  Sweep and Loop clips, movie export and saved sessions treat it like any
  other. Lockstep clips need one extra step (see
  [Smooth playback in a movie](#smooth-playback-in-a-movie)).

### Rebuild or delete a morph

Select **Morph…** on the morph's own row to reopen the sheet, titled after the
source and filled in with the settings that built the morph. Change them and
select **Morph** to rebuild it under the same name (the summary reads
`rebuilds 2kpo_morph`), so movie clips and scenes that name it keep working.
Rebuilding replaces the morph straight away, even with unchanged settings: the
old morph is deleted and the source is shown again while the new one builds,
so if you cancel or the build fails, no morph is left and you morph again.
**Delete morph** removes the morph and shows the source again. Selecting
**Morph…** on the source also rebuilds its existing morph rather than making a
second one.

A morph saved in a session comes back as an ordinary multi-state object: its
row shows the frame count without the loop icon, and the sheet opens with your
remembered settings rather than the ones that built it. While its source is
loaded, **Morph…** still recognises it by its `<source>_morph` name and
rebuilds it in place.

## Smooth playback in a movie

A **Play models** clip in the Movie tab can play a morph instead of the raw
models:

1. In the preset row at the bottom of the **Movie** tab, pick **Play models**
   in the preset menu (the chip then reads **Models**), pick the object in the
   object menu (for example `2kpo · 20`), and select **Append**.
2. In the **Play models** sheet, turn on **Smooth transitions (morph)**. The
   line under it reads, for example, "Builds 2kpo_morph (20 models × 15
   frames) and plays that instead · 10 s at 30 fps".
3. Optionally open **Morph settings…** for frames per model, method, clean-up
   cycles and rate: the Morph sheet's controls, except Loop, which is always on
   here.
4. Select **Add**.

**Add** starts building `2kpo_morph` in the background, or reuses it when it
was already built in this session with the same settings from the unchanged
source (a morph restored from a saved session is always rebuilt), and appends
a clip named `2kpo_morph`, marked with the loop icon. If the morph is still
building, the movie is rebuilt once it is complete. A morph built this way
does not start playing in the Object panel.

- **Use Sweep or Loop** for a smooth clip. A finished morph is pinned to its
  own state, which a **Lockstep** clip does not move, so Lockstep plays the
  morph only after you select **Sync** on the morph's row in the Objects tab
  (playing or scrubbing it there pins it again).
- **Start and End count models**, not frames. Start 3, End 8 plays from model
  3 and stops exactly on model 8. The full range (1 to the last model) includes
  the leg back to model 1, so a Sweep clip ends where it started and the movie
  loops seamlessly.
- **Duration** follows the whole morph's natural length, frames ÷ movie frame
  rate (10 s for 300 frames at 30 fps), when you turn the toggle on or change
  frames per model, until you step Duration yourself. It ignores Start and End,
  so step it down for a shorter range: at natural speed a range lasts
  (End − Start) × frames per model ÷ frame rate, 2.5 s for Start 3, End 8 (the
  stepper moves in whole seconds). While smoothing, the stepper goes past 30 s
  when the natural length needs it.
- If you later rebuild the morph with a different number of frames per model,
  the clip keeps playing the same models: its range is remapped to the new
  frames when the movie is rebuilt.
- The toggle and the morph settings are remembered when you select **Add**.

The toggle is unavailable, with the reason under it, when the object menu is
set to **All** ("Pick one object to smooth") or the chosen object is already a
morph, finished, still building or restored from a session ("Already a smooth
morph"). Once a morph exists you can also pick it in the object menu
(`2kpo_morph · 300`) and add an ordinary Play-models clip.

## What a morph does not carry over

- **Surfaces and meshes.** PyMOL builds representations per state, so a surface
  on a 300-frame morph means 300 surfaces. The morph hides surface and mesh;
  the other representations (cartoon, sticks, lines, spheres, ribbon, dots,
  labels) carry over with their colours. You can still show a surface on it
  (`show surface, 2kpo_morph`), at the cost of one surface per frame.
- **Alternate locations after the first.** Only atoms with no alternate
  location or with altloc `A` are used; `B`, `C` and later conformers are left
  out.
- **Later changes to the source.** Settings set on the source object itself
  (materials, transparency, cartoon options) are copied when the morph is
  built, and global settings apply to both, but nothing you change on the
  source afterwards reaches the morph: morph again.

Some multi-state objects cannot be morphed: models that do not all hold the
same atoms, discrete objects (loaded with `discrete=1`, such as multi-compound
SDF libraries), and objects whose atoms are not uniquely identified by
segment, chain, residue number, residue name and atom name. They still offer
**Morph…**, but the morph is refused, nothing is created, and the reason
("models have different atoms; morph needs the same atoms in every model", or
"atom identifiers … are not unique") is printed in the console.

## Memory and size

A morph stores every frame, so its size grows with atoms × frames. An
atom-frame is one atom in one frame: 1,860 atoms × 300 frames is about 0.56
million atom-frames, roughly 29 MB. The Morph sheet counts about 53 bytes per
atom-frame (coordinates plus a cartoon) and reacts at two levels:

| | Warning (orange summary) | Limit (Morph disabled) |
| :--- | :--- | :--- |
| **macOS** | 200 MB, about 3.8 million atom-frames | 1 GB, about 19 million atom-frames |
| **iPhone & iPad** | 100 MB, about 1.9 million atom-frames | 400 MB, about 7.6 million atom-frames |

`morph_object`, which the sheet runs, enforces the same limit (1 GB in
command-line PyMOL too, on any platform) with its own estimate, counting every
representation the source shows: with cartoon and sticks shown, the macOS
limit falls to about 12.6 million atom-frames. Such a morph can be refused
although the sheet allowed it; the console then shows "Reduce frames per model
or morph fewer models".

To fit a large system, lower **Frames per model**, turn off **Loop back to
model 1** (one leg fewer), build the source from fewer models, or remove atoms
you do not need (waters, other chains) first. Clean-up takes most of the build
time: with 0 cycles a morph builds several times faster.

## Command line

`morph_object` does what the Morph sheet does:

```text
# In the app: builds in the background, with the same progress card
fetch 2kpo, async=0
morph_object 2kpo

# In a script, or in command-line PyMOL: complete before it returns
morph_object 2kpo, frames_per_model=30, loop=0, async_=0
```

Pass `async_=0` in scripts, and always in command-line PyMOL, where nothing
lands the frames of a background morph. It keeps its underscore: unlike
`fetch`, `morph_object` rejects `async=0`. `morph_cancel 2kpo_morph` stops a
morph being built and `morph_dismiss 2kpo_morph` clears the card of a
cancelled or failed one. Running `morph_object` again on the same source
rebuilds `2kpo_morph` in place when it was built in this session. For a morph
restored from a saved session, name it (`morph_object 2kpo, name=2kpo_morph`),
or a second morph, `2kpo_morph2`, is created beside it. A morph started from
the command line does not start playing by itself. The
[command reference](/RayMol/reference/commands/#morph_object) lists every
option (`method=linear`, `refinement=0`, `rate=sinusoidal`, `reuse=1`, …).

### Morph between two structures

PyMOL's `morph` command interpolates between two different objects, for
example the closed and open forms of adenylate kinase:

```text
fetch 1akeA 4akeA, async=0
align 1akeA, 4akeA
morph mout, 1akeA, 4akeA
```

- Superimpose the structures first (`align` or `super`): `morph` interpolates
  the coordinates as they are, so without it the whole protein also drifts
  across the screen.
- Each selection must lie within one object. Atoms are paired by a sequence
  alignment, so morph one chain of each entry (`fetch 1akeA` loads chain A
  only) or select matching chains. The result holds only the paired atoms, so
  ligands and waters drop out.
- `steps` sets the number of frames (30 by default); `refinement`, `method` and
  `rate` work as in `morph_object`, and `color_segments=1` colours the result
  by rigid segment.
- `morph` runs to completion before it returns and hides the input objects. It
  does not copy object settings or hide surfaces, and it shows no progress
  card.

`morph` also takes a single ensemble: `morph ens, 2kpo, state1=0` morphs
through every model and back to model 1 (add `state2=0` to stop at the last
model), with `steps` frames per model. See
[Movies & Scenes](/RayMol/guides/movies/) for building and exporting movies.
