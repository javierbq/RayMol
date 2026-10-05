# #619 Lights mode and overlay bar: evidence at 241ab0f83

Branch `light/619-lights-mode` @ `241ab0f83`, merge-base with master `aea4e74c6` (#611, #612, #613 merged).
Gate logs are under `/Users/javier/repos/light-tools/logs/619/`. Images are under `/Users/javier/repos/light-tools/out/619/round-1/`.

## Gate runs at HEAD

| Gate | Result | Log |
| --- | --- | --- |
| `gate.sh mac` (macOS core and app; staged `RayMol-light619.app` from 241ab0f83) | PASS | `mac-20261005-121655.log` |
| `gate.sh ios` (iOS core with deps_ios headers, `PyMOLViewer_iOS` simulator compile) | PASS | `ios-20261005-121655.log` |
| `gate.sh py` lighting_mode.py, lighting_commands.py, lighting_rig.py, lighting_bridge.py | PASS: 228 tests, OK, 0 skipped | `py-20261005-121714.log` |
| `gate.sh swift` (full UnitTests_macOS) | PASS: 902 tests, 0 failures, 4 skips (all pre-existing: 3 real-inference MPNN tests, 1 MSA memory sweep) | `swift-20261005-121738.log` (+ `.xcodebuild`) |
| `gate.sh swift -only-testing:PyMOLViewerTests/LightsBarSnapshotTests` (macOS bar PNGs) | PASS (1 test, 10 PNGs) | `swift-20261005-122315.log` |
| `gate.sh sim` iPhone portrait (26E6E8C9) | PASS: API validation enabled, no validation errors | `sim-20261005-121725.log` |
| `gate.sh sim` iPhone landscape (`PYMOL_AUTOLANDSCAPE=left`) | PASS: API validation enabled, no validation errors | `sim-20261005-121859.log` |
| `gate.sh sim` iPad portrait (346B2CF8) | PASS: API validation enabled, no validation errors | `sim-20261005-122013.log` |
| `gate.sh sim` iPad with `PYMOL_AUTOLANDSCAPE=left` | PASS for validation, but the iPad did **not** rotate: the screenshot is portrait (2064x2752). Kept as a second iPad portrait shot in `sim-ipad-autolandscape-not-rotated/` | `sim-20261005-122135.log` |

New Swift classes in the full-suite log, all passed:

| Class | Tests |
| --- | --- |
| LightSelectionTests | 7 |
| LightPaletteTests | 7 |
| LightsControllerTests | 21 |
| LightsActionInvocationTests | 4 |
| LightsModeEngineTests | 5 |
| LightsRevertBridgeTests (live engine) | 10 |
| LightsBarModelTests | 11 |
| LightsBarSnapshotTests | 1 (10 shots) |
| InteractionModeExitTests (4 Lights tests added, plus a Lights row in the Binder table) | 15 |
| DesignIOSPortTests (`testLightsBlockedByIsCalculating` added) | 39 |

Simulator console checks (each `console.log` next to its `sim.png`):

| Run | Preset line | PYMOL_AUTOLIGHTS line | Validation |
| --- | --- | --- | --- |
| iPhone portrait | ` lights: three_point: key, fill, rim (ambient 0.1, classic 0)` | `PYMOL_AUTOLIGHTS: active=true lights=key,fill,rim selected=fill` | Metal API Validation Enabled; no validation errors |
| iPhone landscape | same | same | same |
| iPad portrait | same | same | same |
| iPad (AUTOLANDSCAPE, not rotated) | same | same | same |

## Checklist results table

| Check | Result | Evidence |
| --- | --- | --- |
| CI: new `lighting_*.py` tests listed in `raymol-embedded-tests.yml` (C++ via `_cmd`) | `testing/tests/raymol/lighting_mode.py` is listed. CI: see the CI note below | `.github/workflows/raymol-embedded-tests.yml` line 86; local `gate.sh py` PASS (228 tests) |
| L1 default unchanged (no rig / rig off), max difference | n/a: no core, MSL, bridge or render change | `git diff --stat origin/master...HEAD` (below): only Swift app/test files, `project.pbxproj`, one Python helper, one test file and the workflow list |
| L2 lit renders | n/a for #619 (checklist: #619–#622 need L5 only) | |
| L3 shader compile, `iphoneos` + `iphonesimulator` | n/a: no MSL change | |
| L4 simulator, API validation clean | Not required for #619. All 4 simulator runs ran under `METAL_DEVICE_WRAPPER_TYPE=1`: "Metal API Validation Enabled", no validation errors, lit three_point scene visible | `sim-*/console.log`, `sim-*/sim.png` |
| L5 unit tests + recording | Unit tests PASS (902 tests, the classes above). iOS simulator screenshots: iPhone portrait and landscape, iPad portrait. macOS bar: 10 offscreen PNGs of the app's own view (`cacheDisplay`, no screen capture). The macOS screen recording through `mac-vm-test` is on #610's manual-check list (no host UI driving, VM pools off limits) | `sim-portrait-sheet.png`, `sim-landscape-sheet.png`, `mac-bar-sheet.png`, `mac-bar/*.png` |
| L6 Mac timings (s/frame) | n/a for #619 | |

`git diff --stat origin/master...HEAD`:

```
 .github/workflows/raymol-embedded-tests.yml        |   1 +
 modules/pymol/appkit_lights.py                     | 105 +++
 swiftui/PyMOLViewer.xcodeproj/project.pbxproj      |  24 +
 swiftui/PyMOLViewer/Shared/ContentView.swift       |  80 ++-
 swiftui/PyMOLViewer/Shared/GizmoOverlay.swift      |   7 +
 swiftui/PyMOLViewer/Shared/LightsBar.swift         | 363 ++++++++++
 swiftui/PyMOLViewer/Shared/LightsController.swift  | 431 ++++++++++++
 swiftui/PyMOLViewer/Shared/MetalViewport.swift     |   5 +
 swiftui/PyMOLViewer/Shared/PyMOLApp.swift          |  11 +-
 swiftui/PyMOLViewer/Shared/PyMOLEngine.swift       | 258 ++++++-
 swiftui/PyMOLViewerTests/DesignIOSPortTests.swift  |  33 +
 .../InteractionModeExitTests.swift                 |  70 ++
 swiftui/PyMOLViewerTests/LightsBarTests.swift      | 300 +++++++++
 .../PyMOLViewerTests/LightsControllerTests.swift   | 741 +++++++++++++++++++++
 swiftui/PyMOLViewerTests/LightsModeTests.swift     | 473 +++++++++++++
 testing/tests/raymol/lighting_mode.py              | 465 +++++++++++++
 16 files changed, 3342 insertions(+), 25 deletions(-)
```

No file under `layer*/`, no `.metal`, `.h`, `.cpp` or `.mm`, no `PyMOLBridge*`, `LightRigBridge.swift` or `SettingInfo.h`. The only `MetalViewport.swift` change is the two hover-pick guards.

CI note: not yet green at 241ab0f83, for infrastructure reasons only. The push runs of "RayMol unit tests (embedded)" (run 37362096291) and "iOS pipeline script tests" (run 37362096316) were never picked up: "The job was not acquired by Runner of type hosted even after multiple attempts" (GitHub macOS arm64 capacity). I re-ran both once. The embedded run failed the same way again; the iOS pipeline re-run was still queued when this was written. No test ran or failed. The previous push, 4f86cc473, passed both workflows (runs 37357092665 and 37357092782). 241ab0f83 changes only `lighting_mode.py` among CI-run files (it adds testEveryTopStackNamesLights and LightsBar.swift to the no-Python source check), and `gate.sh py` passes locally at HEAD. The PR's `pull_request` run has to be green before merge.

## Done-when items and scope → evidence (plan §8)

| Item | Evidence | Status |
| --- | --- | --- |
| Done-when: entering and leaving the mode is covered by tests like `InteractionModeExitTests` | InteractionModeExitTests (testExitsLightsMode, testSecondExitAfterLightsIsANoOp, testEnteringLightsLeavesEveryOtherMode, testEveryOtherModeLeavesLights, the Lights row in testEveryOtherExclusiveModeClearsBinderDesign), LightsModeEngineTests (5), DesignIOSPortTests.testLightsBlockedByIsCalculating; all passed in the full suite | Met |
| Done-when: Revert restores the rig | LightsRevertBridgeTests (10, live engine: bridge JSON byte-equal after Revert, including the no-rig and rig-off entries; Revert repeats; re-entering takes a new snapshot); CI `lighting_mode.py` TestRestore | Met |
| Scope: a chip per light, tap selects | LightSelectionTests, LightsControllerTests, LightsBarModelTests; iOS screenshots with `PYMOL_AUTOLIGHTS=fill` show the fill chip selected (accent capsule), with the console line `selected=fill`; mac-bar PNGs 02/06/09 show fill selected | Met |
| Scope: add/remove, preset menu, Re-centre | Controller tests (actions and enablement), CI TestBarCommands and TestPresets, live testRevertRestoresTheRigExactly and testBarCommandsReachTheCore; mac-bar PNGs show + disabled at 6 lights, − / Re-centre / power / Revert disabled with no lights, the Presets menu on the wide bar and folded into the ellipsis menu on the compact bar | Met |
| Scope: Revert (to the entry snapshot) | as above; the bar disables Revert until something changed | Met |
| Scope: Done | testDoneAndEscKeepEdits, testExitsLightsMode; Done is on every bar variant in every screenshot | Met |
| Scope: one selection model shared by the bar, gizmo, orbit view and inspector | One `LightsController` per engine (selection, identity slots, rig mirror, `edit` API through the bridge setters only); LightSelectionTests, LightPaletteTests. Live mirroring across all four is deferred to #620/#621/#622 (listed deferral) | Met (bar side); rest deferred |
| Scope: placement (top on macOS, docked below the panels on iPad) | iPad portrait: the bar sits under the console and sequence panes, above the viewport. iPhone portrait: same, compact layout. iPhone landscape: under the sequence pane, compact layout. macOS: offscreen bar PNGs, CI `testEveryTopStackNamesLights` (3 `anyTop` sites, `macAnyTopPane`, 5 chains). On-screen placement on macOS by eye is on the manual list | Met (macOS by eye: manual list) |
| #610: no Python per drag tick | testEditsUseOnlyTheBridge (fakes), testContinuousEditsRunNoPython (live: `pythonTap` and `commandTap` see 0 lines during 50 edits), CI testControllerAndBarRunNoPython | Met |
| #610: no rig → byte-identical renders | No core, MSL, bridge or render change (diffstat above); testEnterAndLeaveWithNoRigCreatesNoRig | Met (L1 n/a) |
| #610: shippable on macOS and iOS | gate.sh mac and gate.sh ios PASS at HEAD; the app runs on the iPhone and iPad simulators with no validation errors | Met |

## grid_mode decision (hand-off "Decide in #617/#619", #613 F10)

Unchanged: there is no per-cell framing in #619. Re-centre runs `lights recenter`, which frames every enabled object (the whole scene), as rig creation does (spec decision 3). Grid cells share the camera (`SceneSetMetalGridCell` changes only the viewport), so the lights stay consistent across cells. A cell's object far from the centre may fall outside a narrow beam; per-cell framing stays the follow-up already proposed as #613 F10, not a new issue.

## Merge order

Merge after #613. #613 (#644, 0fa890106) and #612 (#645, aea4e74c6) are already on master, so the order holds and the bar's edits change pixels now (the simulator screenshots show the three_point specular highlights).

## #610 manual-check lines (by eye, PR #619)

- macOS: Tools ▸ Enter Lights Mode; the bar at the top of the viewport; chips select; + and −; a preset; Re-centre; On/Off; Revert; Done; Esc (= Done, keeps edits).
- iPad: the bar under the console and sequence panes (also visible in the simulator screenshot).
- VoiceOver: chip labels ("<name> light") and the selected state; the power button's "Lights on/off" value.
- The L5 macOS screen recording (mac-vm-test), not possible here: no host UI driving, VM pools off limits.

## Images for the render inspector

- `mac-bar-sheet.png`: the 10 macOS bar PNGs (`mac-bar/01..10`). Done draws grey rather than accent because the offscreen window is never key.
- `sim-portrait-sheet.png`: iPhone portrait, iPad portrait.
- `sim-landscape-sheet.png`: iPhone landscape, plus the iPad run where AUTOLANDSCAPE did not rotate (portrait).

What I saw on the sheets: the bar docks under the console and sequence panes in every iOS shot; key, fill and rim are blue, orange and green; fill has the accent capsule; iPhone shows the compact bar (+, −, ellipsis, Revert, Done), iPad shows the wide bar (Lights title, Presets, Re-centre, power, Revert, Done); Revert is dimmed because nothing changed since entry; the lit cartoon shows the three_point highlights. macOS: 0 lights shows only the status text with − / Re-centre / power / Revert dimmed; 6 lights dims +; the off rig dims the chips and greys the power icon; the 600 pt 6-light shot switches to the compact layout.
