# Lighting checklist: verifying renders, iOS and the app (#610)

Part of the lighting epic (#610); the spec is
`docs/superpowers/specs/2026-10-02-lighting-epic-design.md`.

**Why this exists:** CI renders nothing on a GPU and builds no C++ tests.
- `raymol-embedded-tests.yml` builds the core on macOS (GLUT flavour, without
  `testing=True`) and runs an explicit list of RayMol Python tests against the
  real `_cmd`, without drawing a frame.
- The upstream `CI` workflow (`build.yml`), which ran the catch2 tests in
  `layerCTest/`, has been disabled since June 2026, and no other workflow
  builds catch2 (Homebrew ships catch2 v3; PyMOL needs v2).
- No job builds the app or the iOS core (`ios-deps-artifact.yml` only
  packages third-party iOS dependencies).

So every claim about pixels, shaders or the app is checked locally with this
procedure. **Each lighting PR copies the results table at the end into its
description and fills in the rows its ticket needs.**

## What CI must cover

- **Python:** add new tests under `testing/tests/raymol/lighting_*.py` to the
  file list in `.github/workflows/raymol-embedded-tests.yml`, which lists
  every file explicitly. A test that isn't listed never runs. Typical
  subjects: rig round-trips, commands and errors, scene store and recall,
  movie blend values.
- **C++:** no workflow builds catch2, so C++ logic (rig maths, angle
  conventions, session lists) is tested from Python. Expose the function the
  renderer or the app bridge calls through a `_cmd` entry, and test it in
  `testing/tests/raymol/lighting_*.py`. #611 does this with
  `_cmd.get_lights_eye`, `_cmd.light_set` and `_cmd.get_lights_json` in
  `lighting_eye.py` and `lighting_rig.py`. Don't add `layerCTest` files for
  lighting: nothing runs them. Keep the maths in functions that take no
  `PyMOLGlobals`, so a future catch2 job could call them directly.
- **Shader sources:** `testing/tests/raymol/metal_shader_sources.py` must keep
  passing. It catches a helper used in one MSL library but defined in another,
  and a `)"` that ends a raw string early.

## Which checks each ticket needs

| Ticket | L1 | L2 | L3 | L4 | L5 | L6 |
| --- | --- | --- | --- | --- | --- | --- |
| #611 rig | ✓ | | | | | |
| #612 commands | ✓ | ✓ | | | | |
| #613 shading | ✓ | ✓ | ✓ | ✓ | | |
| #614 pick | ✓ | | | | ✓ | |
| #615 materials | ✓ | ✓ | ✓ | ✓ | | |
| #616 shadows | ✓ | ✓ | ✓ | ✓ | | ✓ |
| #617 scenes, movies | ✓ | ✓ | | | | |
| #618 air | ✓ | ✓ | ✓ | ✓ | | ✓ |
| #619–#622 controls | | | | | ✓ | |
| #623 iPhone, iPad | | | ✓ | ✓ | ✓ | ✓ (calibration) |
| #624 HDR | ✓ | ✓ | ✓ | ✓ | | ✓ |

## L1. Default render unchanged, byte for byte

The epic's first rule: with no rig, nothing changes.

1. **Build two apps,** following the naming rules in `CLAUDE.md`. Give each its
   own `CFBundleIdentifier`; a copy sharing `io.raymol.RayMol` with a running
   RayMol sits idle and never renders.
   - `RayMol-master.app`, from current master;
   - `RayMol-<issue>.app`, from the branch.
2. **Render the scene set with each app.** The harness is
   `scripts/lighting/render.py`, added by #611 and modelled on
   `scripts/materials_gallery/render.py` (one `open -n` per image,
   `PYMOL_AUTOCMD` plus `PYMOL_AUTOEXPORT=<png>,<w>,<h>,<rt>`, a throwaway first
   render). The scene set is 1rx1 at 1280×720, 16 images:
   - cartoon, surface, sticks, spheres, mesh;
   - a 50% transparent surface (the OIT path);
   - a glass surface;
   - each of those 7 with `metal_raytrace` 0 and 1, at `metal_shadows` 0
     (14 images);
   - plus a shadows scene (cartoon and ligand sticks) at `metal_shadows` 1,
     with `metal_raytrace` 0 and 1 (`shadows_rt0`, `shadows_rt1`).
3. **Render the branch twice:** with no rig, and with a rig present but off
   (lights defined, then switched off). From #612 on that is `lights
   three_point` then `lights off`; before #612, use `cmd.set_lights` with
   `enabled` false.
4. **Compare** decoded RGBA pixels with `render.py --compare <master dir>
   <branch dir>`. **Pass = maximum difference 0 on every image**, for both
   branch runs.

## L2. Lit renders, posted in the PR

- Render the ticket's own scenes with the same harness and post a contact
  sheet in the PR. Ticket scenes include:
  - a 2-light rig on each representation (#613);
  - materials × a 3-light rig (#615);
  - the coloured-shadow test, two coloured lights each shadowing the other
    (#616);
  - a 2-scene movie, first, middle and last frames (#617);
  - haze and dust with ray tracing off and on (#618).
- Use the ticket's done-when as the pass criteria. Where it says two images
  "match" (e.g. air with ray tracing on and off), post both side by side;
  byte equality isn't expected there.
- Pin the dust clock for repeatable images (the prototype's
  `RAYMOL_STUDIO_TIME`, or its replacement).

## L3. iOS shader compile, both SDKs

As in Materials Checklist A, step 1:
1. Extract every `@R"( … )"` literal from
   `layerGraphics/metal/RendererMetal.mm`.
2. Compile each one alone with `xcrun -sdk <sdk> metal -std=metal3.1 -c`,
   for `iphoneos` **and** `iphonesimulator`.
3. Prepend the shared blocks as the call sites do:

| Library | Prepend |
| --- | --- |
| `kVBOSrc` | `kMaterialSrc` |
| `kSphereImpostorSrc`, `kCylinderImpostorSrc` | `kMaterialSrc`, `kMaterialImpostorSrc` |
| `kRTSrc`, `kPostSrc` | `kEyeReconSrc` |

Lighting code lives in `kMaterialSrc` (shading, shadows, outlines) and
`kPostSrc` (air), so both rows change in most rendering tickets. Note that a
runtime shader failure is otherwise silent, apart from an `NSLog`.

## L4. iOS simulator under Metal API validation

As in Materials Checklist A, steps 2–3:
1. Build `libpymol_core.a` (`bash swiftui/build_ios.sh`) and the
   `PyMOLViewer_iOS` scheme.
2. Launch on a simulator with `SIMCTL_CHILD_METAL_DEVICE_WRAPPER_TYPE=1`,
   setting `SIMCTL_CHILD_PYMOL_AUTOCMD` to:
   - show cartoon, sticks, spheres and surface;
   - apply a 3-light rig with one shadowed light;
   - for #618, add haze and dust.
3. Confirm `Metal API Validation Enabled` in the log. **Pass = no validation
   errors** and the lit scene visible.

## L5. App and controls

- **Unit tests:** hit tests (knobs, rings, the radius square, the pitch arc,
  the aim dot) and mode entry and exit go in `swiftui/PyMOLViewerTests`, like
  `InteractionModeExitTests`.
- **macOS:** drive the app with the `mac-vm-test` skill where available (see
  `CLAUDE.md`). Post a short screen recording of the ticket's interactions.
- **iOS:** run in the simulator. Gestures that need a device (pinch, long
  press) are confirmed in #623.

## L6. Performance

- **Mac:** time a 48-frame 1080p movie export with Metal ray tracing on and
  report seconds per frame. Measure:
  - 0, 1 and 3 shadowed lights;
  - 1rx1, a ~10k-atom protein and a large assembly such as a ribosome.

  #616 records these on the issue; #618 and #624 report their own added cost.
- **iOS:** the budget is calibrated **at the end of the epic, in #623** (spec
  §8). Until then, #616 and #618 have to make that calibration a measurement
  plus a choice of defaults, not a code change. They do this by shipping:
  - the iOS fallbacks as switches: shadow-map size, and air at half
    resolution;
  - a GPU-time readout per frame, logged when a debug setting is on.

## Results table (copy into the PR)

| Check | Result | Evidence |
| --- | --- | --- |
| CI: new `lighting_*.py` tests listed in `raymol-embedded-tests.yml` (C++ via `_cmd`) | | |
| L1 default unchanged (no rig / rig off), max difference | | |
| L2 lit renders | | contact sheet |
| L3 shader compile, `iphoneos` + `iphonesimulator` | | |
| L4 simulator, API validation clean | | |
| L5 unit tests + recording | | |
| L6 Mac timings (s/frame) | | |
