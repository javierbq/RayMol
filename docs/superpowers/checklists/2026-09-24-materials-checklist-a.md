# Checklist A — iOS build and shader compile for the material libraries (#492)

Part of the Materials epic (#503). CI has no Xcode job and the iOS slice needs a
local `deps_ios/`, so a shader change spanning three libraries is otherwise
unverified for iOS. This is the procedure, and the result of running it.

## Procedure

1. **Shader compile, both iOS SDKs.** Extract every `name = @R"( … )";` literal
   from `layerGraphics/metal/RendererMetal.mm` and compile each standalone with
   `xcrun -sdk <sdk> metal -std=metal3.1 -c`, prepending the shared blocks
   exactly as the call sites do:

   | library | prepend |
   |---|---|
   | `kVBOSrc` | `kMaterialSrc` |
   | `kSphereImpostorSrc` | `kMaterialSrc`, `kMaterialImpostorSrc` |
   | `kCylinderImpostorSrc` | `kMaterialSrc`, `kMaterialImpostorSrc` |
   | `kRTSrc`, `kPostSrc` | `kEyeReconSrc` |

   Run for `iphoneos` **and** `iphonesimulator`. A runtime shader failure is
   otherwise silent apart from an `NSLog`.

2. **Build.** `bash swiftui/build_ios.sh` for `libpymol_core.a`, then the
   `PyMOLViewer_iOS` scheme against an iPhone simulator.

3. **Run under Metal API validation**, once per implemented material, with a
   scene that shows cartoon + sticks + spheres + surface so one run exercises
   all three material-bearing libraries:

   ```
   SIMCTL_CHILD_METAL_DEVICE_WRAPPER_TYPE=1 \
   SIMCTL_CHILD_PYMOL_AUTOLOAD="1ubq.cif" \
   SIMCTL_CHILD_PYMOL_AUTOCMD="<show/set commands>" \
     xcrun simctl launch <device> io.raymol.RayMol
   ```

   Confirm `(Metal) Metal API Validation Enabled` appears in the app's log —
   without it the run proves nothing about attachment or sample-count
   mismatches.

4. **Prove the material applied.** Do not infer it from "it did not crash".
   Read the values back from inside the app, e.g. an `open(...).write(...)`
   command in `PYMOL_AUTOCMD` writing `cmd.get('cartoon_material', 'mol')` into
   the app's data container.

## Traps

- `PYMOL_AUTOCMD` pointed at a **host** path silently does nothing: the app
  cannot see `/tmp/...`. Use the bundled resource via `PYMOL_AUTOLOAD` (the
  object is named `mol`) or a path inside the app's data container.
- `pymol_objdetail_*.json`'s `detail` field is populated **only for an expanded
  inspector card**. An empty `detail` is not evidence of an empty session — the
  object list is in `pymol_objpanel_*.json`.
- The `deps_ios/` in the main checkout may carry the directory structure with no
  built static libraries; check for `libfreetype.a` / `libpng16.a` before
  trusting it.
- The simulator GPU lacks MSAA depth-stencil resolve, so `metal_msaa` is ignored
  there. The simulator therefore does **not** exercise the MSAA paths.

## Result — 2026-09-24, `master` at `ba3cb3311`

iPhone 16 Pro simulator, macOS 26.5 / Xcode 26, Apple Silicon.

- Shader compile: **18/18** (9 libraries × macosx + iphoneos), 0 failures. The
  three material libraries also compile for `iphonesimulator`.
- `libpymol_core.a` iOS arm64: 13.7 MB, clean. `PyMOLViewer_iOS`: BUILD
  SUCCEEDED.
- Validated run, all five implemented materials (`default`, `matte`, `marble`,
  `clay`, `rubber`): app alive, object loaded, **0 Metal validation errors** each.
- Materials verifiably applied: `cartoon_material=marble` + `stick_material=clay`
  on one object read back as `cartoon=marble stick=clay sphere=default`.
- **Frame time not captured.** `RAYMOL_GPU_TIMING` produced no file under
  `simctl`, and no trustworthy number was obtained, so none is quoted. The
  simulator is not a device proxy; performance targets belong to #501.
