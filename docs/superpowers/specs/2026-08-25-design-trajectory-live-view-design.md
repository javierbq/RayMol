> **SUPERSEDED (2026-08-28) — this describes an architecture that was not shipped.**
>
> This spec chose "states of a separate object": a `<design object>_traj` holding the
> **designed chain only**, kept after the run so a cancelled trajectory survives. The
> merged implementation does the opposite on both counts. There is no `_traj` object at
> all — `designing.trajectory_seed` streams into the **result object itself**, target and
> generated chain together — and `designing.discard_pending` **deletes** an unfinished
> live object, because a half-diffused poly-ALA backbone under a name that says
> `rfd3_design_<key>` is indistinguishable from a finished design in the object panel and
> in any `.pse` saved afterwards.
>
> So the "mutate the result object in place" row in the table below is what shipped, and
> the invariants argued against it were met another way: the placeholder is read into in
> place rather than deleted and recreated, and `keep_frames=0` leaves a session
> indistinguishable from `live_view=0`. Read this for the problem statement and the
> alternatives considered; read `docs/generators.md` for how live view actually behaves.
> The command is also now `binder_design` rather than `design_backbone`.

# Live view of a design's diffusion trajectory

**Date:** 2026-08-25
**Branch:** `claude/issue-342-rfd3`
**Platforms:** macOS only (RFD3Kit is macOS-only; the iOS slice never links it)
**Depends on:** #342 (the design generator), rfd3-mlx ≥ 0.1.2 (this spec's upstream half)

## Problem

A design takes minutes — 35 s against a 40-residue epitope, ~17 minutes against
full-length albumin — and produces nothing visible until it ends. The progress tray
says `Diffusion 41% · step 77 of 199`, which tells you the run is alive but not what
it is doing. RFdiffusion3's rollout is the interesting part: noise resolving into a
fold, against a fixed target. None of it is currently observable.

The coordinates exist. `Sampler.rollout` holds `X` and refreshes it every step, and
already calls `eval(X)` per step so the values are resident. It simply never escapes:
the step callback carries `(Int, Int)` and nothing else.

## Goal

Watch the designed chain diffuse, live, and keep the recording so it can be replayed
and scrubbed afterwards.

Explicit non-goal: judging a trajectory in order to abort it early. That is a
plausible second use and would impose different requirements (faithful placement is
mandatory, frame rate must support reading a trend, refusal thresholds). It is not
what this is for, and designing for both would compromise the simpler one.

## Approach: the trajectory is a multi-state object

One object per run, `<design object>_traj`, holding the **designed chain only**, one
**state** per captured frame.

This is the PyMOL-native reading of "watch it diffuse", and it is chosen over the two
alternatives for reasons that are not stylistic:

| | |
| :--- | :--- |
| **states of a separate object** (chosen) | scrubbing, replay and `mplay` come free — that is what states and the Timeline already do. Keeps the recording, which is half of what was asked for. Touches no existing lifecycle rule. |
| mutate the result object in place | the literal reading of the request, and the most invasive: it is the only option that gives the pending placeholder atoms, which breaks two invariants (below). Discards the recording the moment the run ends. |
| single-state throwaway preview | smallest change, keeps the invariants, also discards the recording. |

### The invariants that decided it

Two shipped behaviours key off a pending placeholder being **empty**:

- `designing.session_save` drops a pending object from a `.pse` only when
  `count_atoms(name) == 0`, so a mid-run save does not persist an object that can never
  fill.
- `designing.discard_pending` deletes the object only when `count_atoms(name) == 0`, so
  cleanup racing a finished job cannot destroy a real result.

Populating the placeholder live gives it atoms and silently changes what both mean: a
cancelled run would leave a half-diffused structure behind, and a mid-run save would
write one into the session. Both are fixable with a "this is only a preview" flag
threaded through both functions — but a separate object needs neither, and the result
object goes on being created empty and filled once at the end.

## Upstream half (rfd3-mlx 0.1.2)

Two additions, both additive, both in the shape `shouldCancel` already established.

```swift
// Sampler.generate / rollout, and RFD3Model.Options
onStepCoords: ((Int, () -> [Float]) -> Void)?
```

Called after each denoising step with the step index and a **lazy accessor** for the
flat `[L, 3]` coordinate array. Lazy, not the array itself, because the host captures
roughly one step in four: an eager `[Float]` would pay a GPU→CPU copy of up to 87 KB on
every step to throw most of them away. The accessor also keeps the decision about *what*
to copy on the host side, where the frame policy lives.

```swift
// FeatSet
public let origin: SIMD3<Float>
```

The featurizer already computes `origin` (the hotspot centre of mass pushed 10 Å along
the core-to-hotspot normal) and keeps it internal. Every coordinate the sampler produces
is in that translated frame, so a host that cannot see `origin` cannot place a frame.
Exposing it is strictly smaller than the alternative — recovering it per frame from the
target atoms, which is what `RFD3ResultWriter` does at the end and which needs the
target's atom mapping the live path does not otherwise have.

`RFD3ResultWriter` keeps its statistical recovery unchanged. It is a genuine safety net
— its residual is what detects a deformed target — and replacing it with the exposed
`origin` would trade a check for a shortcut.

Both additions must be **output-identical when unset**, verified the way the cancel hook
was: the end-to-end golden test passes unchanged against the shipped pack.

## RayMol half

### Flow

1. The bar's **Live view** toggle is on. `RFD3JobManager` installs `onStepCoords`.
2. Every 4th step, the manager materialises the coordinates, slices the designed
   chain's atoms, adds `origin`, and sends the frame to Python.
3. Frame 1 seeds the object: a poly-ALA PDB of the designed chain, via `read_pdbstr`.
4. Every later frame appends a state via `cmd.load_coordset(coords, obj, state=N)` —
   API-only, and documented to load in *original atom order*, which is the order this
   code emits and therefore controls.
5. The run ends. The trajectory object stays. The result object is created empty and
   filled at the end exactly as it is today.

### Which atoms

The binder tokens come first in the featurizer's layout, 14 dense slots each, so the
designed chain is the first `14 × length` atoms. Of those, the same `N, CA, C, O, CB`
subset the final writer keeps is kept here, giving `5 × length` atoms — constant across
every state, which is what PyMOL requires of one object's states.

### Why poly-ALA

Not laziness. States of one object share a single atom set, including residue names,
and the sequence head's argmax **churns during the rollout** — a residue is LEU at step
40 and VAL at step 80. Per-state residue names are therefore not representable, and a
fixed backbone identity is the honest rendering of "the sequence is not settled yet".
The engine allocates CB for every designed residue regardless, so ALA fits the atom set
exactly.

### Frame rate

Every 4th step: ~50 frames from a 199-step run, about 1.7 s at 30 fps. Enough to read as
motion, against 199 round trips that would put ~1.2 MB of Python source through the main
thread during a run that is already GPU-saturated. The interval is a named constant, not
a literal.

### The toggle

A checkbox on `DesignBackboneBar`, beside the length and count steppers. **Default off**
and persisted (`@AppStorage`): a 50-state object is a reasonable thing to opt into and an
unreasonable thing to be given.

### Lifecycle

The trajectory object survives the run, including a **cancelled** one — a partial
trajectory is arguably the interesting case, and it is an ordinary object the user can
delete. Because the feature is opt-in, nothing accumulates for anyone who did not ask.

The trajectory carries no metrics and no design key. It is a recording, not a result: the
result object owns the identity, the geometry and the provenance, and giving a
poly-ALA backbone a `design_key` would put a second thing in the session claiming to be
that design.

## Error handling

Every failure here must degrade to "no live view", never to a failed design. A run that
would have succeeded must not fail because a frame could not be drawn.

- A frame that cannot be sliced, offset or written is dropped, and the run continues.
- If the seeding frame fails, the trajectory object is never created and later frames
  find no object to append to; they are dropped for the same reason.
- The Python side treats a frame for an unknown object as a no-op rather than an error:
  the object may have been deleted by the user mid-run, which is legitimate.
- Cancellation is unchanged. `shouldCancel` is still polled per step and is checked
  before the frame callback, so a cancelled run does not emit a frame it will not use.

## Testing

**Upstream:** `onStepCoords` fires once per step with the reported step index; the lazy
accessor returns `L × 3` floats; a run with the hook unset is byte-identical to one
without (the golden characterisation test, unchanged); `FeatSet.origin` matches the value
the result writer recovers statistically at the end, which cross-checks the two paths
against each other.

**Swift:** frame slicing returns `5 × length` atoms in the writer's order; the origin
offset places a frame's CA where the final result's CA lands (to float tolerance); the
capture interval yields the expected frame count for a given step count; the poly-ALA
seed PDB parses and has a constant atom set.

**Python:** N frames produce an N-state object with a constant atom count; a frame for an
unknown object is a no-op; the trajectory object is absent when the toggle is off.

**Live:** run a design with the toggle on, confirm the object gains states while the run
progresses, scrub it afterwards, and confirm the result object is unaffected — same
`target_drift_max`, same metrics, same 0.000 Å target deviation as without the toggle.

## Out of scope

- Early-abort judgement (see Goal).
- Showing the target inside the trajectory object. It does not move; duplicating it into
  every state costs memory and says something false about what is being sampled.
- A trajectory for the *sequence* track. The logits evolve too and are arguably as
  interesting, but they are not coordinates and do not belong in a states model.
- iOS.
