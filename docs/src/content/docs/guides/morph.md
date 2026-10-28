---
title: Morphing
description: Turn an NMR ensemble, trajectory snapshots or a set of predicted models into a smooth, looping morph for inspection and movies.
---

A multi-state object flips from one model to the next when it plays. A morph
makes it glide: RayMol computes the frames between consecutive models and
stores them as a new object beside the original, which plays smoothly in the
viewport, in movie clips and in exported videos.

## What a morph is

A morph is built from a **source**: any molecular object with two or more
states (models) that all hold the same atoms, such as an NMR ensemble, snapshots from a
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
for example `20 models → 300 frames · 10 s at 30 fps · ≈ 867 MB · creates
2kpo_morph, hides 2kpo · ≈ 28 s to build`. The seconds use the movie frame
rate, which is also the speed the finished morph plays at. The build time is a
rough hint, shown when it is over 10 s; clean-up cycles add most of it. The
line turns orange above the memory warning level, and **Morph** is disabled
above the limit (see [Memory and size](#memory-and-size)). If the object shows
a surface or mesh, a second line reminds you that they are not carried to the
morph.

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

A session saved while a morph builds does not include the unfinished morph; a
movie clip that names it stays. After reopening the session the clip is dimmed
with a dashed outline and reads `2kpo_morph — not built · morph 2kpo to fill`
(with less of the clip on screen, `2kpo_morph — not built`, then just
`not built`; its tooltip carries the rest):
right-click it and select **Build 2kpo_morph from 2kpo** to morph the source
at the clip's own frames per model, or morph the source again yourself. Any
Play-models clip whose object is not loaded is marked the same way ("not
loaded"). Opening another session stops the build and leaves the card reading
**Morph cancelled**; starting a new session (**Clear Session**) stops it and
clears the card.

### When it is done

- The source is hidden and the `2kpo_morph` row is shown, expanded, with a
  loop (repeat) icon before its frame count (tooltip "Morph of 2kpo · 300
  frames").
- It starts playing at the movie frame rate (its Play speed is set to match).
  While the Movie timeline is open, model playback is off, so the morph
  follows the movie's current frame instead.
- The **Name** line tells you where you are: `model 7` on a key frame, `7 → 8`
  between models, `20 → 1` on the leg that loops back.
- From here it is an ordinary multi-state object: the State slider, Play,
  Sweep, Loop and Lockstep clips, movie export and saved sessions treat it
  like any other.

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

RayMol remembers how it built each morph since it was launched, for as long as
that morph is still loaded unchanged. This holds when you reopen a session you
saved with it in the same run, with no other session opened and no **Clear
Session** in between: the morph's row keeps the loop icon, **Morph…** on that
row opens with the settings that built it, and the Movie tab's **Add** can
reuse it. After a relaunch, **Clear Session** or opening another session, or
when the saved morph differs from the one RayMol last built under that name,
it comes back as an ordinary multi-state object: **Morph…** on its row opens
with your remembered settings rather than the ones that built it, and **Add**
rebuilds it. While its source is loaded, RayMol still recognises it by its
`<source>_morph` name: its row keeps the loop icon and the "Morph of 2kpo" tooltip, and **Morph…**
rebuilds it in place.

## Smooth playback in a movie

A **Play models** clip in the Movie tab can play a morph instead of the raw
models:

1. In the preset row at the bottom of the **Movie** tab, pick **Play models**
   in the preset menu (the chip then reads **Models**), pick the object in the
   object menu (for example `2kpo · 20`), and select **Append**.
2. In the **Play models** sheet, turn on **Smooth transitions (morph)**. The
   line under it reads, for example, "Builds 2kpo_morph (20 models × 15
   frames) and plays that instead · 10 s at 30 fps · ≈ 867 MB". As in the
   Morph sheet, it turns orange above the memory warning level; above the
   limit it adds "reduce frames per model" and **Add** is disabled. A finished
   morph that **Add** would reuse (see below) is never refused, so the line
   shows its size alone and **Add** stays enabled. While the morph **Add**
   would name is still being built (for example from the Object panel), the
   line reads "2kpo_morph is still being built · Add once it is done" and
   **Add** is disabled until it finishes: the running build may use other
   settings, such as Loop off.
3. Optionally open **Morph settings…** for frames per model, method, clean-up
   cycles and rate: the Morph sheet's controls, except Loop, which is always on
   here.
4. Select **Add**.

**Add** starts building `2kpo_morph` in the background and appends a clip
named `2kpo_morph`, marked with the loop icon. It reuses the morph instead when
it was built from the unchanged source with the same settings since RayMol was
launched and is still loaded unchanged (reopening a session you saved with it
in the same run, with no other session opened and no **Clear Session** in
between, keeps it reusable; after a relaunch, **Clear Session** or opening
another session, or when the saved morph differs, **Add** rebuilds it). The
clip fills in while the morph it started builds, and the movie is rebuilt once
it is complete. A morph built this way does not start playing in the Object
panel.

- **Sweep, Loop and Lockstep all play a morph.** Lockstep moves the global
  frame, so it does not move an object pinned to its own state. Playing or
  scrubbing a morph in the Objects tab pins it, and so does the auto-play
  after every build or rebuild from the Objects tab. Entering the Movie tab
  while it is still playing releases it; a morph you stopped or scrubbed
  stays on its frame until you select **Sync** on its row. A session saved
  while a morph is playing reopens with it on the movie's frame, ready for
  the Movie tab.
- **Start and End count models**, not frames. In Sweep mode, Start 3, End 8
  plays from model 3 and stops exactly on model 8. The full range (1 to the
  last model) includes the leg back to model 1, so a Sweep clip ends where it
  started and the movie loops seamlessly.
- **Loop plays forward, then back**, within the clip's Duration, so it ends
  where it started: a Start 3, End 8 Loop clip ends on model 3. It covers its
  range twice, so at natural speed it needs twice a Sweep clip's Duration:
  20 s rather than 10 s for the full 300-frame morph at 30 fps. The stepper
  goes up to 30 s, or to the natural length when that is longer, so for the
  full range of a morph longer than 15 s use Sweep instead.
- **Duration** follows the whole morph's natural length, frames ÷ movie frame
  rate (10 s for 300 frames at 30 fps), when you turn the toggle on or change
  frames per model, until you step Duration yourself. It ignores Start and End,
  so step it down for a shorter range: in Sweep mode, at natural speed a range
  lasts (End − Start) × frames per model ÷ frame rate, 2.5 s for Start 3,
  End 8 (the stepper moves in whole seconds). While smoothing, the stepper goes
  past 30 s when the natural length needs it.
- If you later rebuild the morph with a different number of frames per model,
  the clip keeps playing the same models: its range is remapped to the new
  frames when the movie is rebuilt.
- The toggle and the morph settings are remembered when you select **Add**.

The toggle is unavailable, with the reason under it, when the object menu is
set to **All** ("Pick one object to smooth"), the chosen object is already a
morph, finished, still building or restored from a session ("Already a smooth
morph"), or it is not a molecule, such as a group or an alignment ("Only a
molecule can be smoothed"). Once a morph exists you can also pick it in the object menu
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
same atoms (even when they hold the same number of atoms), discrete objects
(loaded with `discrete=1`, such as multi-compound SDF libraries), objects
whose atoms are not uniquely identified by segment, chain, residue number,
residue name and atom name, and objects with no atoms in altloc `A` or without
an altloc. They still offer **Morph…**, but the morph is refused and nothing
is created. The reason ("models have different atoms; morph needs the same
atoms in every model", "atom identifiers … are not unique") appears in a
**Morph failed** card in the progress tray, and in the console; **Dismiss**
clears the card. A morph too large for the memory limit is refused the same
way (see below). Objects that are not molecules (CGOs, maps, alignments) do
not offer **Morph…** at all, and `morph_object` refuses them ("… is not a
molecular object").

## Memory and size

A morph stores every frame, and RayMol keeps the representations of every
frame built so the morph plays without stalls. Its memory therefore grows with
frames × (atoms plus the representations the source shows, which the morph
copies). RayMol estimates it per frame from costs measured on its own
renderer:

| Per frame | Cost |
| :--- | :--- |
| Coordinates | about 45 bytes per atom |
| Cartoon | about 14 KB per residue, 31 KB per helix residue |
| Sticks | about 100 bytes per atom shown as sticks |
| Lines | about 80 bytes per atom |
| Spheres | about 65 bytes per atom |
| Ribbon | about 100 bytes per residue |
| Dots | about 1.6 KB per atom |
| Labels | about 130 bytes per labelled atom |

plus 10%. Surfaces and meshes are not carried to a morph and cost nothing.
Only atoms with no alternate location or altloc `A` count. Cartoon is the
largest part for most proteins: 2kpo (20 models, 110 residues, 59 of them in
helices) shown as cartoon needs about 2.9 MB per frame, so at 15 frames per
model (300 frames) the sheet reads `≈ 867 MB` (the finished morph measures
about 0.6 GB on a Mac). Shown as lines instead, the same morph needs about
77 MB. When a source has no secondary structure assigned, every cartoon
residue is counted as helix: the morph assigns its own when it is created.

The Morph sheet, and the Play-models sheet while smoothing, react at two
levels, which depend on the device's memory:

| | Warning (orange summary) | Limit (Morph disabled) |
| :--- | :--- | :--- |
| **macOS** | 200 MB or 1/16 of the Mac's memory, whichever is larger (1 GB on a 16 GB Mac) | 1 GB or 1/4 of the Mac's memory, whichever is larger (4 GB on a 16 GB Mac) |
| **iPhone & iPad** | 100 MB or 1/4 of the memory available to RayMol, whichever is larger | 400 MB or 1/2 of the memory available to RayMol, whichever is larger |

The memory available to RayMol on iPhone and iPad changes with what else is
running, so the levels are read again each time. The sheet and
`morph_object` use one estimate, computed by RayMol from the representations
the source shows, and the same levels (command-line PyMOL uses the macOS
rule, from the computer's memory). A morph refused for its size leaves a
**Morph failed** card reading "this morph needs about … MB. Reduce frames per
model or morph fewer models". On iPhone and iPad, when the system warns that
memory is low, RayMol cancels every morph being built (its card reads **Morph
cancelled**) and stops model playback in the Object panel; the console reads
`morph: cancelled on memory warning`.

To fit a large system, lower **Frames per model**, turn off **Loop back to
model 1** (one leg fewer), build the source from fewer models, hide
representations you do not need on the source (dots and cartoon cost the
most), or remove atoms you do not need (waters, other chains) first. Clean-up
takes most of the build time: with 0 cycles a morph builds several times
faster.

Every change to a finished morph's look (a colour, a material, transparency,
a shown representation, a theme) rebuilds all of its frames in the next
redraw: for 2kpo shown as cartoon, about 0.4 s at 300 frames and 1.5 s at
1,200 on an M-series Mac, the same cost as for any object with that many
states and atoms. Turning the camera and playing the morph are not slowed. If
edits feel slow, build the morph with fewer frames per model.

## Command line

`morph_object` does what the Morph sheet does:

```text
# In the app: builds in the background, with the same progress card
fetch 2kpo, async=0
morph_object 2kpo

# In a script, or in command-line PyMOL: complete before it returns
morph_object 2kpo, frames_per_model=30, loop=0, async_=0
```

Pass `async_=0` (or `async=0`, as for `fetch`) in scripts, and always in
command-line PyMOL, where nothing lands the frames of a background morph.
`morph_cancel 2kpo_morph` stops a
morph being built and `morph_dismiss 2kpo_morph` clears the card of a
cancelled or failed one. Running `morph_object` again on the same source
rebuilds `2kpo_morph` in place when it was built since RayMol was launched and
is still loaded unchanged (reopening a session you saved with it in the same
run, with no other session opened and no `reinitialize` (**Clear Session**) in
between, keeps it recognised). After a relaunch, `reinitialize` or opening
another session, or when the saved morph differs, it comes back as an ordinary
multi-state object: name it (`morph_object 2kpo, name=2kpo_morph`), or a
second morph, `2kpo_morph2`, is created beside it. A morph started from the command line does not start
playing by itself. The
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
  ligands and waters drop out. To morph between two chains of one object,
  copy them into separate objects first (`create chA, dimer and chain A`).
- `steps` sets the number of frames (30 by default); `refinement`, `method` and
  `rate` work as in `morph_object`, and `color_segments=1` colours the result
  by rigid segment.
- `morph` runs to completion before it returns and hides the input objects. It
  does not copy object settings or hide surfaces, and it shows no progress
  card.
- Running the same `morph mout, …` command again replaces `mout` once the new
  morph is built. A morph that fails leaves your objects as they were. The
  output cannot be one of the input objects, a group or a selection.

`morph` also takes a single ensemble: `morph ens, 2kpo, state1=0` morphs
through every model and back to model 1 (add `state2=0` to stop at the last
model), with `steps` frames per model. See
[Movies & Scenes](/RayMol/guides/movies/) for building and exporting movies.
