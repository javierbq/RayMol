# Live Design-Trajectory View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user watch an RFD3 design diffuse — the designed chain resolving out of noise beside its fixed target — and keep the recording as a scrubbable multi-state object.

**Architecture:** `Sampler` gains an optional lazy coordinate callback and `FeatSet` exposes the `origin` it already computes. `RFD3JobManager` captures every 4th frame, slices the designed chain's atoms, adds `origin`, and sends them to Python, which seeds a poly-ALA object and appends one state per frame via `cmd.load_coordset`. The result object is untouched: it is still created empty and filled once at the end.

**Tech Stack:** Swift 5.9 / SwiftUI (macOS 14+), mlx-swift 0.31.6, RFD3Kit (rfd3-mlx), embedded CPython 3.13, XCTest, PyMOL's `testing.PyMOLTestCase`.

**Spec:** `docs/superpowers/specs/2026-08-25-design-trajectory-live-view-design.md`

## Global Constraints

- **macOS only.** RFD3Kit is macOS-only. Every Swift symbol added here lives behind `#if os(macOS)`, and anything referenced from `PyMOLEngine.swift` or `ContentView.swift` — which compile on BOTH platforms — must be gated there too. This leak has broken the iOS slice three times (#174, #226/#238).
- **Both slices must compile before any commit that touches Swift.** No CI job compiles Swift at all.
- **Never call the generated chain a "binder"** in any UI string, object name, metric key or metric label. `RFD3RuntimeTests.testNoUserFacingStringCallsTheOutputABinder` greps for it and allows only RFD3Kit's own symbol names (`designBinder`, `binderSequence`, `binderLength`, `binderCACAmeanA`, `binderToHotspotMinA`).
- **rfd3-mlx floor becomes `0.1.2`** — the version that carries `onStepCoords` and `FeatSet.origin`. mlx-swift stays pinned `exact: 0.31.6`, shared with MPNNKit and BoltzMLX; do not bump it.
- **Live view must never fail a design.** Every failure in this feature degrades to "no live view" and the run continues.
- **Capture interval is a named constant**, `RFD3JobManager.trajectoryStepInterval = 4`, never a literal.
- **Trajectory object name** is `"\(resultObjectName)_traj"`, derived from `request.objectName`.
- Python test files must NOT be named `test_*.py` (that routes them to the pytest lane); `testing/tests/generate/` is already a directory entry in CI so new files there run automatically.
- Run Python tests with: `pymol -ckqy testing/testing.py --run testing/tests/generate`
- Run Swift tests with: `cd swiftui && xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation`

---

### Task 1: Upstream — expose `origin` and stream coordinates (rfd3-mlx)

Work in `/Users/jcastellanos/repos/rfd3-ios` (remote `javierbq/rfd3-mlx`), on `main`.

**Files:**
- Modify: `RFD3Kit/Sources/RFD3Kit/Featurizer.swift` (FeatSet at :54-57, `return FeatSet` at :176)
- Modify: `RFD3Kit/Sources/RFD3Kit/Sampler.swift` (`generate` at :49-58, `rollout` at :63-107)
- Modify: `RFD3Kit/Sources/RFD3Kit/RFD3Model.swift` (`Options`, `designBinder`)
- Test: `RFD3Kit/Tests/RFD3KitTests/RFD3TrajectoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FeatSet.origin: SIMD3<Float>`; `RFD3Model.Options.onStepCoords: ((Int, () -> [Float]) -> Void)?`; `Sampler.generate(..., onStepCoords:)`. Tag `0.1.2`.

- [ ] **Step 1: Write the failing test**

Create `RFD3Kit/Tests/RFD3KitTests/RFD3TrajectoryTests.swift`:

```swift
import XCTest
import Foundation
@testable import RFD3Kit

/// The live-trajectory hooks. `origin` and `onStepCoords` exist so a host can place a
/// mid-rollout frame: every coordinate the sampler produces is in a frame translated by
/// `origin`, and without it a frame lands tens of Angstrom from the target.
final class RFD3TrajectoryTests: XCTestCase {

    private func tinyTarget(_ count: Int) -> [PDBResidue] {
        let atoms: [(String, (Float, Float, Float))] = [
            ("N", (0, 0, 0)), ("CA", (1.5, 0, 0)), ("C", (2.4, 1, 0)),
            ("O", (2, 2.1, 0)), ("CB", (1.8, -0.6, 1.3))]
        return (0 ..< count).map { i in
            PDBResidue(chain: "A", resSeq: i + 1, resName: "ALA",
                       atoms: atoms.map { PDBAtom(name: $0.0,
                                                  element: String($0.0.first!),
                                                  xyz: ($0.1.0 + Float(i) * 3.8,
                                                        $0.1.1, $0.1.2)) })
        }
    }

    /// `origin` must be the translation the featurizer actually applied, so that
    /// `motif_pos + origin` puts a target atom back where it was supplied.
    func testOriginIsTheTranslationTheFeaturizerApplied() {
        let target = tinyTarget(6)
        let fset = Featurizer.binderDesign(target: target, hotspots: [2], binderLen: 4)
        let motif = fset.feats["motif_pos"]!.asArray(Float.self)
        let a2t = fset.feats["atom_to_token_map"]!.asArray(Int32.self)
        let asym = fset.feats["asym_id"]!.asArray(Int32.self)
        // First TARGET atom (asym 1). Binder tokens come first, so this is past them.
        var found = false
        for a in 0 ..< a2t.count where asym[Int(a2t[a])] == 1 {
            let restored = SIMD3(motif[a * 3], motif[a * 3 + 1], motif[a * 3 + 2])
                + fset.origin
            // Target residue 0, atom N, is at (0,0,0) by construction above.
            XCTAssertEqual(restored.x, 0, accuracy: 1e-3)
            XCTAssertEqual(restored.y, 0, accuracy: 1e-3)
            XCTAssertEqual(restored.z, 0, accuracy: 1e-3)
            found = true
            break
        }
        XCTAssertTrue(found, "expected at least one target atom")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/jcastellanos/repos/rfd3-ios && swift test --filter RFD3TrajectoryTests`
Expected: FAIL to COMPILE — `value of type 'FeatSet' has no member 'origin'`.

- [ ] **Step 3: Expose `origin` on FeatSet**

In `Featurizer.swift`, replace the `FeatSet` declaration (currently lines 54-57):

```swift
public struct FeatSet {
    public let feats: [String: MLXArray]
    public let coordToBeNoised: MLXArray     // [1, L, 3]
    /// The translation the featurizer applied: every coordinate in `coordToBeNoised` —
    /// and therefore every coordinate the sampler produces — is `input - origin`.
    ///
    /// Public because a host that renders a MID-ROLLOUT frame has no other way to place
    /// it: the final PDB's frame can be recovered from its own target atoms, but a frame
    /// arriving during the run carries no such anchor the host can cheaply match. Without
    /// this a live frame lands tens of Angstrom from the target it was designed against.
    public let origin: SIMD3<Float>
}
```

and the return (currently line 176):

```swift
        return FeatSet(feats: feats, coordToBeNoised: coord,
                       origin: SIMD3(origin.0, origin.1, origin.2))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/jcastellanos/repos/rfd3-ios && swift test --filter RFD3TrajectoryTests`
Expected: PASS.

- [ ] **Step 5: Add the coordinate-stream test**

Append to `RFD3TrajectoryTests.swift`, inside the class:

```swift
    /// The stream fires once per step, carries the reported step index, and hands over a
    /// LAZY accessor — a host that skips a frame must pay no GPU->CPU copy for it.
    func testCoordinateStreamFiresPerStepAndIsLazy() throws {
        guard let pack = ProcessInfo.processInfo.environment["RFD3_PACK"] else {
            throw XCTSkip("set RFD3_PACK to a .rfd3pack directory to run")
        }
        let model = try RFD3Model(packDirectory: URL(fileURLWithPath: pack))
        let atoms: [(String, (Float, Float, Float))] = [
            ("N", (0, 0, 0)), ("CA", (1.5, 0, 0)), ("C", (2.4, 1, 0)), ("O", (2, 2.1, 0))]
        let target = (0 ..< 8).map { i in
            RFD3Model.Residue(resName: "GLY", chain: 0, resSeq: i + 1,
                              atoms: atoms.map { RFD3Model.Atom(
                                  name: $0.0,
                                  xyz: SIMD3($0.1.0 + Float(i) * 3.8, $0.1.1, $0.1.2)) })
        }
        var options = RFD3Model.Options()
        options.binderLength = 4
        options.numTimesteps = 6
        options.hotspots = [2]
        var steps: [Int] = []
        var materialised = 0
        var lastCount = 0
        options.onStepCoords = { step, coords in
            steps.append(step)
            // Materialise only every other frame: the accessor must be what costs, not
            // the callback, or skipping would be pointless.
            if step % 2 == 0 {
                let flat = coords()
                materialised += 1
                lastCount = flat.count
            }
        }
        _ = try model.designBinder(target: target, options: options)
        XCTAssertEqual(steps, Array(1 ... (options.numTimesteps - 1)))
        XCTAssertEqual(materialised, steps.filter { $0 % 2 == 0 }.count)
        XCTAssertGreaterThan(lastCount, 0)
        XCTAssertEqual(lastCount % 3, 0, "a flat [L, 3] array")
    }

    /// A run with no stream installed must be byte-identical to one before this hook
    /// existed. Same discipline the cancel hook was held to; the golden test is the
    /// end-to-end proof and this is the cheap local one.
    func testAnUninstalledStreamCostsNothingAndChangesNothing() throws {
        guard let pack = ProcessInfo.processInfo.environment["RFD3_PACK"] else {
            throw XCTSkip("set RFD3_PACK to a .rfd3pack directory to run")
        }
        let model = try RFD3Model(packDirectory: URL(fileURLWithPath: pack))
        let atoms: [(String, (Float, Float, Float))] = [
            ("N", (0, 0, 0)), ("CA", (1.5, 0, 0)), ("C", (2.4, 1, 0)), ("O", (2, 2.1, 0))]
        let target = (0 ..< 8).map { i in
            RFD3Model.Residue(resName: "GLY", chain: 0, resSeq: i + 1,
                              atoms: atoms.map { RFD3Model.Atom(
                                  name: $0.0,
                                  xyz: SIMD3($0.1.0 + Float(i) * 3.8, $0.1.1, $0.1.2)) })
        }
        func run(withStream: Bool) throws -> String {
            var o = RFD3Model.Options()
            o.binderLength = 4
            o.numTimesteps = 6
            o.hotspots = [2]
            o.seed = 5
            if withStream { o.onStepCoords = { _, _ in } }
            return try model.designBinder(target: target, options: o).binderSequence
        }
        XCTAssertEqual(try run(withStream: false), try run(withStream: true))
    }
```

- [ ] **Step 6: Run to verify the new tests fail**

Run: `cd /Users/jcastellanos/repos/rfd3-ios && RFD3_PACK="$HOME/repos/rfd3-ios/dist/RFD3.rfd3pack" swift test --filter RFD3TrajectoryTests`
Expected: FAIL to COMPILE — `Options` has no member `onStepCoords`.

- [ ] **Step 7: Add `onStepCoords` to Options**

In `RFD3Model.swift`, inside `Options`, directly after the `shouldCancel` property:

```swift
        /// Called after each denoising step with the step index and a LAZY accessor for
        /// the flat `[L, 3]` coordinate array, on the calling thread.
        ///
        /// Lazy on purpose. A host rendering a live view captures roughly one step in
        /// four; an eager `[Float]` would pay a GPU->CPU copy of up to 87 KB on every
        /// step to discard most of them. Calling the accessor is what costs, so the
        /// decision about which frames to keep stays with the host.
        ///
        /// Coordinates are in the featurizer's translated frame — add `FeatSet.origin`
        /// to place them beside the target that was supplied.
        public var onStepCoords: ((Int, () -> [Float]) -> Void)? = nil
```

- [ ] **Step 8: Thread it through the sampler**

In `Sampler.swift`, add the parameter to `generate` (after `shouldCancel`) and to `rollout`, and forward it:

```swift
                         shouldCancel: (() -> Bool)? = nil,
                         onStepCoords: ((Int, () -> [Float]) -> Void)? = nil) throws -> Result {
```

```swift
            try rollout(feats, D: D, coordToBeNoised: coordToBeNoised,
                        onPhase: onPhase, onStep: onStep, shouldCancel: shouldCancel,
                        onStepCoords: onStepCoords)
```

```swift
                         shouldCancel: (() -> Bool)?,
                         onStepCoords: ((Int, () -> [Float]) -> Void)?) throws -> Result {
```

In the loop, immediately after the existing `onStep?(i + 1, nSteps)` call:

```swift
            // AFTER onStep and after the cancel poll, so a cancelled run never emits a
            // frame nothing will draw. `X` is already evaluated by the eval(X) above, so
            // the accessor is a copy, not a GPU sync.
            if let onStepCoords {
                onStepCoords(i + 1, { X[0].asArray(Float.self) })
            }
```

- [ ] **Step 9: Pass it from designBinder**

In `RFD3Model.swift`, in `designBinder`, extend the sampler call:

```swift
            .generate(fset.feats, coordToBeNoised: fset.coordToBeNoised,
                      onStep: { s, t in options.onProgress?(s, t) },
                      shouldCancel: options.shouldCancel,
                      onStepCoords: options.onStepCoords)
```

- [ ] **Step 10: Run the new tests**

Run: `cd /Users/jcastellanos/repos/rfd3-ios && RFD3_PACK="$HOME/repos/rfd3-ios/dist/RFD3.rfd3pack" swift test --filter RFD3TrajectoryTests`
Expected: PASS (3 tests).

- [ ] **Step 11: Run the WHOLE suite including the golden**

Run: `cd /Users/jcastellanos/repos/rfd3-ios && RFD3_PACK="$HOME/repos/rfd3-ios/dist/RFD3.rfd3pack" RFD3_TEST_PDB="$HOME/repos/rfd3-ios/albumin_binder.pdb" swift test`
Expected: all tests pass, 0 failures. The golden `testDesignBinderOutputIsUnchanged` passing is the proof these hooks are output-neutral. If it fails, STOP — the hook has changed the trajectory and the placement in Step 8 is wrong.

- [ ] **Step 12: Update the README**

In `RFD3Kit/README.md`, bump both `from: 0.1.1` occurrences to `0.1.2`, and add after the `shouldCancel` line in the usage block:

```swift
opts.onStepCoords = { step, coords in /* live view; call coords() only when keeping */ }
```

- [ ] **Step 13: Commit and tag**

```bash
cd /Users/jcastellanos/repos/rfd3-ios
git add RFD3Kit/Sources/RFD3Kit/Featurizer.swift RFD3Kit/Sources/RFD3Kit/Sampler.swift \
        RFD3Kit/Sources/RFD3Kit/RFD3Model.swift \
        RFD3Kit/Tests/RFD3KitTests/RFD3TrajectoryTests.swift RFD3Kit/README.md
git commit -m "Expose the rollout's coordinates and the frame they are in

A host cannot render a design as it diffuses: the step callback carries (Int, Int) and
the coordinate tensor never escapes, and every coordinate the sampler produces is in a
frame translated by an origin the featurizer keeps to itself.

Options.onStepCoords hands over the step index and a LAZY accessor for the flat [L, 3]
array. Lazy because a live view keeps roughly one step in four, and an eager array would
copy up to 87 KB per step to discard most of it.

FeatSet.origin exposes the translation already computed. The final PDB's frame can be
recovered from its own target atoms; a mid-rollout frame has no such anchor a host can
cheaply match.

Output-identical when unset: the end-to-end golden passes unchanged.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
git tag -a 0.1.2 -m "0.1.2 — live trajectory hooks

Options.onStepCoords (lazy per-step coordinates) and FeatSet.origin (the frame they are
in). Both additive and output-identical when unused."
git push origin 0.1.2
```

---

### Task 2: Carry a `live_view` flag from the command to the runtime

**Files:**
- Modify: `swiftui/project.yml` (the `RFD3MLX` package entry, `from: 0.1.1`)
- Modify: `modules/pymol/designing.py` (`design_backbone` signature and its submit loop)
- Modify: `modules/pymol/generators/base.py` (`DesignSpec`)
- Modify: `modules/pymol/generators/rfd3.py` (`parse_target`, `submit`'s `extra`)
- Modify: `swiftui/PyMOLViewer/Shared/InferenceJob.swift` (`Request`)
- Test: `testing/tests/generate/generate_runtime.py`

**Interfaces:**
- Consumes: rfd3-mlx `0.1.2` from Task 1.
- Produces: `cmd.design_backbone(..., live_view=0, ...)`; `DesignSpec.live_view: bool`; wire key `live_view`; `InferenceJob.Request.liveView: Bool?`.

- [ ] **Step 1: Write the failing test**

In `testing/tests/generate/generate_runtime.py`, add to `RuntimeSeamTest`:

```python
    def testLiveViewRidesTheWireOnlyWhenAskedFor(self):
        # A presentation flag, not a sampler knob: it changes nothing about the design,
        # so it is a named command parameter like `name` and `n_designs` rather than an
        # entry in option_defaults, and it must be ABSENT-or-false by default so an
        # ordinary run is byte-for-byte what it was.
        request = self.submitted('rfd3')
        self.assertFalse(request.get('live_view', False))
```

- [ ] **Step 2: Run test to verify it passes trivially, then extend `submitted` to take the flag**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate/generate_runtime.py`
Expected: PASS (the key is absent today). Now change the helper `submitted` in that file to accept and forward the flag, replacing its signature line:

```python
    def submitted(self, generator_id, length=20, live_view=False):
```

and its spec construction line `spec = generator.parse_target(structure, length, name='obj')` with:

```python
        spec = generator.parse_target(structure, length, name='obj')
        spec.live_view = live_view
```

then add:

```python
    def testLiveViewIsOnTheWireWhenRequested(self):
        request = self.submitted('rfd3', live_view=True)
        self.assertIs(request['live_view'], True)
```

- [ ] **Step 3: Run to verify the new test fails**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate/generate_runtime.py`
Expected: FAIL — `AttributeError: 'DesignSpec' object has no attribute 'live_view'` (it is a `__slots__` class).

- [ ] **Step 4: Add `live_view` to DesignSpec**

In `modules/pymol/generators/base.py`, in `DesignSpec`, extend `__slots__` and `__init__`:

```python
    __slots__ = ('target', 'length', 'name', 'generator_id', 'design_chain', 'live_view')

    def __init__(self, target, length, name='', generator_id='', design_chain='B',
                 live_view=False):
```

and at the end of `__init__`:

```python
        #: Stream the rollout's coordinates so the run can be watched. PRESENTATION only:
        #: it changes nothing about the design, which is why it is not a sampler knob and
        #: is deliberately absent from `design_key` -- the same design watched and unwatched
        #: is the same design and must key the same.
        self.live_view = bool(live_view)
```

- [ ] **Step 5: Put it on the wire**

In `modules/pymol/generators/rfd3.py`, in `submit`'s `extra` dict, after `'design_chain'`:

```python
                'live_view': spec.live_view,
```

- [ ] **Step 6: Add the design-key invariance test**

In `testing/tests/generate/generate_target.py`, add to `DesignKeyTest`:

```python
    def testWatchingADesignDoesNotChangeItsIdentity(self):
        # live_view is presentation: the same design watched and unwatched is the SAME
        # design and must key the same, or a refold could not be matched back to it and
        # two identical runs would land in two objects.
        before = self.key()
        self.spec.live_view = True
        self.assertEqual(before, self.key())
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate`
Expected: PASS. If the key MOVED, `design_key` is hashing `live_view` — it must not.

- [ ] **Step 8: Add the command parameter**

In `modules/pymol/designing.py`, change `design_backbone`'s signature to:

```python
def design_backbone(generator, target, hotspots, length=60, name='', n_designs=1,
                    diffusion_steps=200, recycling_steps=2, seed=None, live_view=0,
                    quiet=1, _self=cmd):
```

Add to its ARGUMENTS docstring section, after the `seed` entry:

```
    live_view = 0/1: stream the rollout into a scrubbable object named
        <result>_traj, one state per captured frame, so the design can be watched
        as it diffuses. Costs a little main-thread work per frame and leaves an
        extra object behind. {default: 0}
```

In the submit loop, immediately after `design_spec = type(spec)(...)`, set the flag on the per-design copy — the copy is built field by field, so a new field must be carried explicitly or it silently defaults to False:

```python
        design_spec.live_view = bool(int(live_view))
```

- [ ] **Step 9: Add the Request field**

In `swiftui/PyMOLViewer/Shared/InferenceJob.swift`, after `designKey`:

```swift
        /// Stream this run's coordinates so it can be watched (#342 live view). OPTIONAL
        /// like every field around it: absent means off, which is what every Python side
        /// that predates it writes.
        let liveView: Bool?
```

and in `CodingKeys`, extend the design line:

```swift
            case designChain = "design_chain", designKey = "design_key"
            case liveView = "live_view"
```

- [ ] **Step 10: Bump the package floor**

In `swiftui/project.yml`, in the `RFD3MLX` entry, replace `from: 0.1.1` with `from: 0.1.2` and add above it:

```yaml
    # 0.1.2 is a FLOOR: `Options.onStepCoords` and `FeatSet.origin` only exist from there,
    # and RFD3JobManager's live-trajectory path does not compile against 0.1.1.
```

- [ ] **Step 11: Verify both slices compile and the suites pass**

```bash
cd swiftui && xcodegen generate
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
cd .. && pymol -ckqy testing/testing.py --run testing/tests/generate
```
Expected: two `** BUILD SUCCEEDED **`, and `OK` from the Python suite. Confirm `Package.resolved` now shows `rfd3-mlx 0.1.2`.

- [ ] **Step 12: Commit**

```bash
git add swiftui/project.yml swiftui/PyMOLViewer.xcodeproj/project.pbxproj \
        swiftui/PyMOLViewer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        swiftui/PyMOLViewer/Shared/InferenceJob.swift modules/pymol/designing.py \
        modules/pymol/generators/base.py modules/pymol/generators/rfd3.py \
        testing/tests/generate/generate_runtime.py
git commit -m "feat(design): carry a live_view flag from design_backbone to the runtime

A presentation flag, not a sampler knob: it changes nothing about the design, so it is a
named command parameter rather than an option_defaults entry, and it is deliberately
absent from design_key -- the same design watched and unwatched must key the same.

Pins rfd3-mlx 0.1.2, whose onStepCoords and FeatSet.origin the next task needs."
```

---

### Task 3: Slice a frame out of the rollout (pure, testable)

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/RFD3Trajectory.swift`
- Test: `swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift`

**Interfaces:**
- Consumes: nothing at runtime; mirrors `RFD3ResultWriter.emittedAtomNames` and `atomRecord`.
- Produces: `RFD3Trajectory.slotsPerDesignResidue`, `.emittedSlots`, `.frame(flat:length:origin:) -> [SIMD3<Double>]`, `.seedPDB(length:chain:) -> String`, `.shouldCapture(step:interval:total:) -> Bool`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import RayMol

/// Turning a rollout frame into something PyMOL can hold as one state of an object.
///
/// The whole file is pure arithmetic on purpose: the live path cannot be reached from a
/// unit test (it needs a 672 MB pack and a real MLX rollout), so everything that CAN be
/// decided without one is decided here.
final class RFD3TrajectoryTests: XCTestCase {

    /// A synthetic flat [L, 3] array where atom i sits at (i, 0, 0), so any slicing
    /// mistake shows up as a wrong x.
    private func flat(atoms: Int) -> [Float] {
        (0 ..< atoms).flatMap { [Float($0), 0, 0] }
    }

    func testAFrameKeepsFiveAtomsPerDesignedResidue() {
        // The engine lays the designed chain out FIRST, 14 dense slots per residue, and
        // only N/CA/C/O/CB are real -- the same subset the final writer keeps.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14 * 6 + 40),
                                     length: 6, origin: SIMD3(0, 0, 0))
        XCTAssertEqual(f.count, 5 * 6)
    }

    func testAFrameTakesTheDesignedChainAndNotTheTarget() {
        // Residue r's slot s is at atom r*14 + s. Residue 1's CA (slot 1) is atom 15.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14 * 3 + 40),
                                     length: 3, origin: SIMD3(0, 0, 0))
        XCTAssertEqual(f[0].x, 0, accuracy: 1e-6)     // residue 0, N   -> atom 0
        XCTAssertEqual(f[1].x, 1, accuracy: 1e-6)     // residue 0, CA  -> atom 1
        XCTAssertEqual(f[5].x, 14, accuracy: 1e-6)    // residue 1, N   -> atom 14
        XCTAssertEqual(f[6].x, 15, accuracy: 1e-6)    // residue 1, CA  -> atom 15
    }

    func testTheOriginIsAddedSoAFrameLandsOnTheTarget() {
        // Coordinates arrive as `input - origin`; adding it back is what puts the frame
        // beside the structure it is being designed against instead of tens of A away.
        let f = RFD3Trajectory.frame(flat: flat(atoms: 14),
                                     length: 1, origin: SIMD3(10, -5, 2.5))
        XCTAssertEqual(f[0].x, 10, accuracy: 1e-6)
        XCTAssertEqual(f[0].y, -5, accuracy: 1e-6)
        XCTAssertEqual(f[0].z, 2.5, accuracy: 1e-6)
    }

    func testAShortArrayYieldsNoFrameRatherThanCrashing() {
        // A malformed frame must degrade to "no live view", never take the design down.
        XCTAssertTrue(RFD3Trajectory.frame(flat: [1, 2, 3], length: 6,
                                           origin: SIMD3(0, 0, 0)).isEmpty)
    }

    func testTheSeedPDBHasOneResidueOfFiveAtomsPerDesignedResidue() {
        let pdb = RFD3Trajectory.seedPDB(length: 4, chain: "B")
        let atoms = pdb.split(separator: "\n").filter { $0.hasPrefix("ATOM") }
        XCTAssertEqual(atoms.count, 20)
        // Poly-ALA, and that is forced: states of one object share a single atom set, and
        // the sequence head's argmax churns during the rollout, so per-state residue names
        // are not representable.
        XCTAssertTrue(atoms.allSatisfy { $0.contains("ALA") })
        XCTAssertTrue(atoms.allSatisfy { $0.dropFirst(21).first == "B" })
    }

    func testTheCaptureIntervalGivesTheExpectedFrameCount() {
        // Every 4th step of 199, plus the last one so the trajectory ends where the design
        // does rather than three steps short.
        let kept = (1 ... 199).filter {
            RFD3Trajectory.shouldCapture(step: $0, interval: 4, total: 199)
        }
        XCTAssertEqual(kept.first, 4)
        XCTAssertEqual(kept.last, 199)
        XCTAssertEqual(kept.count, 50)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrajectoryTests`
Expected: FAIL to compile — `cannot find 'RFD3Trajectory' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/RFD3Trajectory.swift`:

```swift
#if os(macOS)
import Foundation

/// Turns one frame of an RFD3 rollout into something PyMOL can hold as a state.
///
/// Pure arithmetic, deliberately: the live path itself needs a 672 MB pack and a real MLX
/// rollout to reach, so every decision that can be made without one is made here where a
/// unit test can reach it.
enum RFD3Trajectory {

    /// Dense atom slots the featurizer allocates per DESIGNED residue (`BINDER_SLOTS`:
    /// N, CA, C, O, CB, V0...V8). The designed chain is laid out first, so designed
    /// residue `r`'s slot `s` is atom `r * slotsPerDesignResidue + s`.
    static let slotsPerDesignResidue = 14

    /// The slots that are real atoms rather than placeholders — the same subset
    /// ``RFD3ResultWriter/emittedAtomNames`` keeps, in the same order.
    static let emittedSlots = ["N", "CA", "C", "O", "CB"]

    /// The designed chain's atoms from a flat `[L, 3]` rollout frame, back in the
    /// session's frame.
    ///
    /// Returns empty rather than throwing on a short array: a malformed frame must
    /// degrade to "no live view", never take a design down.
    static func frame(flat: [Float], length: Int,
                      origin: SIMD3<Float>) -> [SIMD3<Double>] {
        let needed = length * slotsPerDesignResidue * 3
        guard length > 0, flat.count >= needed else { return [] }
        var out: [SIMD3<Double>] = []
        out.reserveCapacity(length * emittedSlots.count)
        for residue in 0 ..< length {
            for slot in 0 ..< emittedSlots.count {
                let atom = residue * slotsPerDesignResidue + slot
                let base = atom * 3
                out.append(SIMD3(Double(flat[base] + origin.x),
                                 Double(flat[base + 1] + origin.y),
                                 Double(flat[base + 2] + origin.z)))
            }
        }
        return out
    }

    /// A poly-ALA backbone for the designed chain, used ONCE to give the trajectory
    /// object its atoms. Coordinates are zero; the first real frame overwrites them.
    ///
    /// Poly-ALA is forced, not lazy: states of one object share a single atom set
    /// including residue names, and the sequence head's argmax changes during the rollout
    /// — a residue is LEU at step 40 and VAL at step 80. A fixed identity is also the
    /// honest rendering of "the sequence is not settled yet". The engine allocates CB for
    /// every designed residue, so ALA fits the atom set exactly.
    static func seedPDB(length: Int, chain: String) -> String {
        var lines: [String] = []
        var serial = 1
        for residue in 0 ..< max(length, 0) {
            for name in emittedSlots {
                lines.append(RFD3ResultWriter.atomRecord(
                    serial: serial, name: name, resName: "ALA",
                    chain: chain, resi: String(residue + 1),
                    xyz: SIMD3(0, 0, 0)))
                serial += 1
            }
        }
        lines.append(RFD3ResultWriter.terRecord(serial: serial))
        lines.append("END")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Whether this step's coordinates are worth materialising.
    ///
    /// Every `interval`-th step, plus the final one so the recording ends where the design
    /// does rather than up to `interval - 1` steps short of it.
    static func shouldCapture(step: Int, interval: Int, total: Int) -> Bool {
        guard interval > 0 else { return false }
        return step % interval == 0 || step == total
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swiftui && xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrajectoryTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/RFD3Trajectory.swift \
        swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift \
        swiftui/PyMOLViewer.xcodeproj/project.pbxproj
git commit -m "feat(design): slice a rollout frame into a PyMOL-shaped state

Pure arithmetic, because the live path needs a 672 MB pack and a real rollout to reach:
the designed chain is the first 14*length atoms, of which N/CA/C/O/CB are real, and the
featurizer's origin has to be added back or a frame lands tens of Angstrom off target.

Poly-ALA in the seed is forced rather than lazy -- states of one object share a single
atom set including residue names, and the sequence head's argmax changes mid-rollout."
```

---

### Task 4: Build the trajectory object in Python

**Files:**
- Modify: `modules/pymol/designing.py` (add two functions near `deliver_result`)
- Test: `testing/tests/generate/generate_trajectory.py`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `designing.trajectory_seed(name, pdb, _self=cmd)`, `designing.trajectory_frame(name, coords, _self=cmd)`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/generate/generate_trajectory.py`:

```python
"""The trajectory object a live design builds up, one state per captured frame.

    pymol -ckqy testing/testing.py --run testing/tests/generate/generate_trajectory.py
"""
import os
import sys

from pymol import cmd

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from generate_harness import GeneratorTestCase  # noqa: E402


def _seed_pdb(length=3, chain='B'):
    """A poly-ALA backbone, the shape RFD3Trajectory.seedPDB emits."""
    lines = []
    serial = 1
    for residue in range(length):
        for name in ('N', 'CA', 'C', 'O', 'CB'):
            lines.append(
                'ATOM  %5d  %-3s ALA %s%4d       0.000   0.000   0.000  1.00  0.00'
                '          %2s' % (serial, name, chain, residue + 1, name[0]))
            serial += 1
    lines.append('TER')
    lines.append('END')
    return '\n'.join(lines) + '\n'


class TrajectoryTest(GeneratorTestCase):

    def setUp(self):
        GeneratorTestCase.setUp(self)
        from pymol import designing
        self.designing = designing

    def testSeedingCreatesAOneStateObjectWithTheExpectedAtoms(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=3))
        self.assertIn('traj', cmd.get_names('objects'))
        self.assertEqual(cmd.count_atoms('traj'), 15)
        self.assertEqual(cmd.count_states('traj'), 1)

    def testEachFrameAppendsAStateAndTheAtomCountNeverChanges(self):
        # PyMOL states of one object share an atom set; a frame that changed it would be
        # rejected, and a trajectory that grew atoms would not be scrubbable.
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        for step in range(1, 6):
            coords = [float(step)] * 30          # 10 atoms x 3
            self.designing.trajectory_frame('traj', coords)
        self.assertEqual(cmd.count_states('traj'), 6)
        self.assertEqual(cmd.count_atoms('traj'), 10)

    def testAFrameActuallyMovesTheAtoms(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=1))
        self.designing.trajectory_frame('traj', [7.0, 8.0, 9.0] * 5)
        model = cmd.get_model('traj', state=2)
        self.assertAlmostEqual(model.atom[0].coord[0], 7.0, places=3)
        self.assertAlmostEqual(model.atom[0].coord[2], 9.0, places=3)

    def testAFrameForAnUnknownObjectIsANoOpNotAnError(self):
        # The user may delete the object mid-run, which is legitimate. Live view must
        # degrade to nothing rather than raise into a running design.
        self.designing.trajectory_frame('nosuchobject', [1.0, 2.0, 3.0])
        self.assertNotIn('nosuchobject', cmd.get_names('objects'))

    def testAWrongLengthFrameIsDroppedRatherThanCorrupting(self):
        self.designing.trajectory_seed('traj', _seed_pdb(length=2))
        self.designing.trajectory_frame('traj', [1.0, 2.0])      # not a multiple of 3
        self.designing.trajectory_frame('traj', [1.0] * 300)     # wrong atom count
        self.assertEqual(cmd.count_states('traj'), 1)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate/generate_trajectory.py`
Expected: FAIL — `AttributeError: module 'pymol.designing' has no attribute 'trajectory_seed'`.

- [ ] **Step 3: Write the implementation**

In `modules/pymol/designing.py`, immediately before `def deliver_result(`:

```python
# -- The live trajectory object ------------------------------------------------
#
# A design takes minutes and shows nothing until it ends. With `live_view=1` the runtime
# streams the rollout here, one state per captured frame, into an object BESIDE the result
# rather than into the result itself.
#
# Beside, not into, for a reason worth keeping: two behaviours key off a pending
# placeholder being EMPTY -- session_save drops it from a .pse only if it has no atoms, and
# discard_pending deletes it only if it has no atoms. Populating the placeholder live would
# silently change both, so a cancelled run would leave a half-diffused structure behind and
# a mid-run save would persist one. A separate object needs neither weakened.


def trajectory_seed(name, pdb, _self=cmd):
    """Create the trajectory object from a poly-ALA backbone. Called once, on frame 1.

    Never raises: live view is a nicety, and a design that would have succeeded must not
    fail because a frame could not be drawn. A failure here simply leaves no object, and
    the frames that follow find nothing to append to and are dropped for the same reason.
    """
    try:
        if name in _self.get_names('objects'):
            _self.delete(name)
        _self.read_pdbstr(str(pdb), str(name))
        # Not zoomed and not enabled-exclusively: the run is minutes long and the user is
        # looking at the target. The object appears in the panel; that is enough.
        return True
    except Exception as exc:
        colorprinting.warning(' design: could not start the live view (%s)' % exc)
        return False


def trajectory_frame(name, coords, _self=cmd):
    """Append one captured frame as a new state of `name`.

    `coords` is a FLAT list of floats, three per atom, in the object's original atom
    order -- which is why `load_coordset` is the primitive here rather than `load_coords`:
    it is documented to load in the order the file had, and that order is the one
    `RFD3Trajectory.seedPDB` wrote.

    Never raises, for the reason `trajectory_seed` does not. An unknown object is a no-op
    rather than an error: the user may have deleted it mid-run, which is legitimate.
    """
    try:
        if name not in _self.get_names('objects'):
            return False
        values = list(coords)
        if not values or len(values) % 3:
            return False
        atoms = len(values) // 3
        if atoms != _self.count_atoms(name):
            # A frame whose atom count does not match the object cannot be a state of it.
            # Dropped rather than coerced: a partial frame would silently misplace atoms.
            return False
        frame = [values[i * 3:i * 3 + 3] for i in range(atoms)]
        _self.load_coordset(frame, str(name), _self.count_states(name) + 1)
        return True
    except Exception:
        return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate/generate_trajectory.py`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the whole generate directory for leakage**

Run: `pymol -ckqy testing/testing.py --run testing/tests/generate`
Expected: `OK`. Files share one interpreter, so a new file can break a later one.

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/designing.py testing/tests/generate/generate_trajectory.py
git commit -m "feat(design): build the live trajectory object, one state per frame

Beside the result object rather than inside it: session_save and discard_pending both key
off a pending placeholder being EMPTY, so populating it live would make a cancelled run
leave a half-diffused structure and a mid-run save persist one.

load_coordset rather than load_coords -- it loads in the file's original atom order, which
is the order the seed PDB wrote. Neither function raises: live view is a nicety, and a
design that would have succeeded must not fail because a frame could not be drawn."
```

---

### Task 5: Stream frames from the job manager

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/InferenceJob.swift` (`pythonLiteral` at :384 — it is `private` and this task needs it)
- Modify: `swiftui/PyMOLViewer/Shared/RFD3JobManager.swift` (near `options.onProgress` at :214)
- Test: `swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift` (add to the existing class)

**Interfaces:**
- Consumes: `RFD3Trajectory` (Task 3), `Request.liveView` (Task 2), `Options.onStepCoords` and `FeatSet.origin` (Task 1), `designing.trajectory_seed` / `trajectory_frame` (Task 4).
- Produces: `RFD3JobManager.trajectoryStepInterval`, `RFD3JobManager.trajectoryObjectName(for:)`, `RFD3JobManager.framePython(name:coords:)`, `RFD3JobManager.seedPython(name:pdb:)`.

- [ ] **Step 1: Write the failing test**

Add to `RFD3TrajectoryTests` in `swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift`:

```swift
    func testTheTrajectoryObjectIsNamedAfterTheResult() {
        XCTAssertEqual(RFD3JobManager.trajectoryObjectName(for: "rfd3_design_ab12cd34"),
                       "rfd3_design_ab12cd34_traj")
    }

    func testTheFrameStatementImportsAndEscapesTheName() {
        // runPython lands in a __main__ that is EMPTY in this embedding, so a bare
        // designing.trajectory_frame(...) is a silent NameError -- the same trap the tray's
        // Cancel button hit.
        let source = RFD3JobManager.framePython(name: "it's_a_traj",
                                                coords: [SIMD3(1, 2, 3)])
        XCTAssertTrue(source.contains("from pymol import designing as _d"), source)
        XCTAssertTrue(source.contains("'it\\'s_a_traj'"), source)
        XCTAssertTrue(source.contains("1.000"), source)
    }

    func testAFrameStatementIsFlatAndThreePerAtom() {
        let source = RFD3JobManager.framePython(
            name: "t", coords: [SIMD3(1, 2, 3), SIMD3(4, 5, 6)])
        // Flat, because trajectory_frame takes a flat list and reshapes -- one list of six
        // is cheaper to parse than two lists of three.
        XCTAssertTrue(source.contains("[1.000,2.000,3.000,4.000,5.000,6.000]"), source)
    }

    func testTheCaptureIntervalIsAConstantNotALiteral() {
        XCTAssertEqual(RFD3JobManager.trajectoryStepInterval, 4)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrajectoryTests`
Expected: FAIL to compile — `type 'RFD3JobManager' has no member 'trajectoryObjectName'`.

- [ ] **Step 3: Widen `pythonLiteral` to internal**

`InferenceJob.pythonLiteral` is `private`, so the helpers below cannot call it. Drop the
keyword and say why, rather than writing a second escaper — PyMOL's text parser does not
strip quotes from a `"..."` token and a name with an apostrophe has exactly one correct
escaping, so two copies is two chances to get it wrong:

```swift
    /// Internal rather than private: every surface that hands a name to `runPython` needs
    /// this exact escaping, and a second copy of it would drift.
    static func pythonLiteral(_ value: String) -> String {
```

- [ ] **Step 4: Add the helpers**

In `RFD3JobManager.swift`, immediately after the `pythonModule` declaration (around :36):

```swift
    /// Capture one frame in this many diffusion steps when live view is on.
    ///
    /// Four gives ~50 frames from a 199-step run — about 1.7 s at 30 fps, enough to read
    /// as motion — against 199 round trips that would put roughly 1.2 MB of Python source
    /// through the main thread during a run that is already GPU-saturated.
    static let trajectoryStepInterval = 4

    /// The object a live run streams into: the result's name plus `_traj`.
    static func trajectoryObjectName(for resultName: String) -> String {
        "\(resultName)_traj"
    }

    /// The statement that creates the trajectory object.
    static func seedPython(name: String, pdb: String) -> String {
        "from pymol import designing as _d\n"
        + "_d.trajectory_seed(\(InferenceJob.pythonLiteral(name)), "
        + "\(InferenceJob.pythonLiteral(pdb)))"
    }

    /// The statement that appends one frame.
    ///
    /// Flat, three floats per atom, at millimetre precision — a trajectory is watched, not
    /// measured, and %.3f keeps a 300-atom frame around 7 KB of source instead of 15.
    static func framePython(name: String, coords: [SIMD3<Double>]) -> String {
        var body = ""
        body.reserveCapacity(coords.count * 24)
        for (index, xyz) in coords.enumerated() {
            if index > 0 { body += "," }
            body += String(format: "%.3f,%.3f,%.3f", xyz.x, xyz.y, xyz.z)
        }
        return "from pymol import designing as _d\n"
             + "_d.trajectory_frame(\(InferenceJob.pythonLiteral(name)), [\(body)])"
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrajectoryTests`
Expected: PASS (10 tests).

- [ ] **Step 6: Install the stream in `run`**

In `RFD3JobManager.swift`, in `run`, the featurized set is currently discarded by
`_ = try RFD3Model.preflight(...)`. Bind it so `origin` is reachable — replace that line with:

```swift
            let featSet = try RFD3Model.preflight(target: target, options: options,
                                                  budgetBytes: RFD3SizeGuard.budgetBytes)
```

`designBinder` re-featurizes internally and discards this `FeatSet`, so it is fair to ask
whether its `origin` is the one the run actually uses. It is: the featurizer is
deterministic in `(target, hotspots, binderLength)`, all three of which are identical
between the two calls, and `origin` is derived from the target and hotspot coordinates
alone. The duplicated CPU featurization is the price already paid for a weight-free size
refusal, noted in that call's existing comment.

Then, immediately after the `options.shouldCancel = { ... }` block, add:

```swift
            // Live view (#342). Installed only when asked for, so an ordinary run makes no
            // callback at all and pays nothing. Every failure here degrades to "no live
            // view": a design that would have succeeded must not fail because a frame
            // could not be drawn.
            if request.liveView == true, let objectName = request.objectName,
               !objectName.isEmpty {
                let trajectory = Self.trajectoryObjectName(for: objectName)
                let origin = featSet.origin
                let interval = Self.trajectoryStepInterval
                var seeded = false
                options.onStepCoords = { [weak self] step, materialise in
                    guard let self else { return }
                    // `total` is not passed to this callback, so the final-step rule uses
                    // the requested schedule's last transition: numTimesteps - 1.
                    guard RFD3Trajectory.shouldCapture(
                        step: step, interval: interval,
                        total: max(request.diffusionSteps - 1, 1)) else { return }
                    let coords = RFD3Trajectory.frame(flat: materialise(),
                                                      length: length, origin: origin)
                    guard !coords.isEmpty else { return }
                    if !seeded {
                        seeded = true
                        let pdb = RFD3Trajectory.seedPDB(
                            length: length, chain: request.designChain ?? "B")
                        self.runPythonOnMain(Self.seedPython(name: trajectory, pdb: pdb))
                    }
                    self.runPythonOnMain(Self.framePython(name: trajectory,
                                                          coords: coords))
                }
            }
```

and add this helper as a private method on the class, after `cancelledStatus`:

```swift
    /// Session work, hopped to the main thread. The rollout runs on a background queue and
    /// PyMOL's session may only be touched from the main one — the same rule
    /// `InferenceJob.loadResult` follows.
    private func runPythonOnMain(_ source: String) {
        DispatchQueue.main.async {
            PyMOLEngine.shared.runPython(source)
        }
    }
```

- [ ] **Step 7: Verify both slices compile and the whole Swift suite passes**

```bash
cd swiftui && xcodegen generate
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
```
Expected: `TEST SUCCEEDED` and `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/RFD3JobManager.swift \
        swiftui/PyMOLViewerTests/RFD3TrajectoryTests.swift
git commit -m "feat(design): stream the rollout into the trajectory object

Installed only when live_view is on, so an ordinary run makes no callback and pays
nothing. Every fourth step is materialised -- the accessor is lazy, so skipped steps cost
no GPU-to-CPU copy -- sliced to the designed chain, offset by the featurizer's origin so
it lands on the target, and appended as a state from the main thread.

Every failure degrades to no live view: a design that would have succeeded must not fail
because a frame could not be drawn."
```

---

### Task 6: The toggle on the bar

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/DesignBackboneController.swift`
- Modify: `swiftui/PyMOLViewer/Shared/DesignBackboneBar.swift` (main row, after the count stepper at :102-104)
- Test: `swiftui/PyMOLViewerTests/RFD3TrayTests.swift` (the controller tests live there)

**Interfaces:**
- Consumes: `cmd.design_backbone(..., live_view=)` (Task 2).
- Produces: `DesignBackboneController.liveView: Bool`.

- [ ] **Step 1: Write the failing test**

Add to `RFD3TrayTests` in `swiftui/PyMOLViewerTests/RFD3TrayTests.swift`, in the bar's-command section:

```swift
    @MainActor
    func testLiveViewIsOffByDefaultAndAbsentFromTheCommand() {
        // A 50-state object is a reasonable thing to opt into and an unreasonable thing to
        // be given, so the command carries the flag only when it is on.
        let c = controller()
        XCTAssertFalse(c.liveView)
        XCTAssertFalse(c.command.contains("live_view"))
    }

    @MainActor
    func testLiveViewAppearsInTheCommandWhenOn() {
        let c = controller()
        c.liveView = true
        XCTAssertEqual(c.command,
                       "design_backbone rfd3, target, sele, length=60, live_view=1")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd swiftui && xcodegen generate && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrayTests`
Expected: FAIL to compile — `value of type 'DesignBackboneController' has no member 'liveView'`.

- [ ] **Step 3: Add the property and the command argument**

In `DesignBackboneController.swift`, after `@Published var resultName = ""`:

```swift
    /// Stream the rollout into a scrubbable `<result>_traj` object.
    ///
    /// Persisted and OFF by default: it leaves an extra ~50-state object behind and costs a
    /// little main-thread work per frame, which is a reasonable thing to opt into and an
    /// unreasonable thing to be given.
    @Published var liveView = UserDefaults.standard.bool(forKey: Self.liveViewKey) {
        didSet { UserDefaults.standard.set(liveView, forKey: Self.liveViewKey) }
    }

    static let liveViewKey = "designBackboneLiveView"
```

In the same file, in `command`, immediately before the `seedText` block:

```swift
        if liveView { parts.append("live_view=1") }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation -only-testing:PyMOLViewerTests/RFD3TrayTests`
Expected: PASS.

- [ ] **Step 5: Add the control to the bar**

In `DesignBackboneBar.swift`, in `mainRow`, immediately after the count `Stepper` (its
`.accessibilityIdentifier("designBackbone.count")` line) and before the advanced button:

```swift
            Toggle("Live", isOn: $controller.liveView)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("designBackbone.liveView")
                .help("Watch the chain diffuse: builds a scrubbable "
                      + "<result>_traj object, one state per frame")
```

- [ ] **Step 6: Verify both slices compile and everything passes**

```bash
cd swiftui && xcodegen generate
xcodebuild test -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -destination 'platform=macOS' -skipPackagePluginValidation -skipMacroValidation
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_iOS -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
cd .. && pymol -ckqy testing/testing.py --run testing/tests/generate
```
Expected: `TEST SUCCEEDED`, `** BUILD SUCCEEDED **`, `OK`.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignBackboneController.swift \
        swiftui/PyMOLViewer/Shared/DesignBackboneBar.swift \
        swiftui/PyMOLViewerTests/RFD3TrayTests.swift
git commit -m "feat(design): add the Live toggle to the Design Backbone bar

Off by default and persisted: an extra ~50-state object is a reasonable thing to opt into
and an unreasonable thing to be given. The bar only appends live_view=1 to the command,
so the same run is reproducible by typing it."
```

---

### Task 7: Verify it live, and document it

**Files:**
- Modify: `docs/generators.md` (a subsection after "Cancellation")

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Build and name the dev app**

The core is C++ and `xcodebuild` alone silently links a stale `libpymol_core.a`, so build
it first if any C++ changed; then rename and re-sign, because a dev build must never be
plain `RayMol.app`:

```bash
cd swiftui && bash build_macos.sh          # only if layer*/ changed since the last build
xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
  -destination 'platform=macOS' -configuration Debug -derivedDataPath /tmp/traj/dd \
  -skipPackagePluginValidation -skipMacroValidation build
DST=/tmp/traj/RayMol-traj.app
rm -rf "$DST"; cp -R /tmp/traj/dd/Build/Products/Debug/RayMol.app "$DST"
mv "$DST/Contents/MacOS/RayMol" "$DST/Contents/MacOS/RayMol-traj"
for k in CFBundleExecutable CFBundleName CFBundleDisplayName; do
  plutil -replace $k -string "RayMol-traj" "$DST/Contents/Info.plist"; done
codesign --force --deep --sign - "$DST"
```

- [ ] **Step 2: Run a live design**

```bash
SETUP='fetch 1ao6, async=0;remove not polymer.protein;create target, 1ao6 and chain A and resi 140-179;delete 1ao6;hide everything;show cartoon, target;select sele, target and resi 150+153+157;orient target;design_backbone rfd3, target, sele, length=24, seed=7, live_view=1'
RAYMOL_MCP_ENABLE=1 RAYMOL_MCP_AUTOTRUST=1 PYMOL_AUTOCMD="$SETUP" \
  /tmp/traj/RayMol-traj.app/Contents/MacOS/RayMol-traj > /tmp/traj/live.log 2>&1 &
```

Status files live in the per-user temp dir, NOT `/tmp`:
`$(getconf DARWIN_USER_TEMP_DIR)raymol_predict_status_<job>.json`.

- [ ] **Step 3: Confirm the trajectory grows while the run is going**

While the status file still says `"state":"running"`, over MCP:

```python
from pymol import cmd
print(cmd.count_states('rfd3_design_<key>_traj'), cmd.count_atoms('rfd3_design_<key>_traj'))
```
Expected: the state count rises between two calls; the atom count stays `5 × 24 = 120`.

- [ ] **Step 4: Confirm the result is unaffected**

After the run finishes, over MCP:

```python
from pymol import cmd
from pymol.metrics import store
name = 'rfd3_design_<key>'
a = cmd.get_model('target and name CA').atom
b = cmd.get_model('%s and chain A and name CA' % name).atom
print(max(sum((x-y)**2 for x, y in zip(p.coord, q.coord))**0.5 for p, q in zip(a, b)))
print((store.summaries([name])[name][0]['scalars'] or {}).get('target_drift_max'))
```
Expected: `0.0` and `0.0`. The live view must not perturb the design.

- [ ] **Step 5: Confirm the trajectory is scrubbable and lands on the design**

```python
from pymol import cmd
traj = 'rfd3_design_<key>_traj'
last = cmd.count_states(traj)
a = cmd.get_model(traj, state=last).atom
b = cmd.get_model('rfd3_design_<key> and chain B and name N+CA+C+O+CB').atom
print(len(a), len(b))
print(max(sum((x-y)**2 for x, y in zip(p.coord, q.coord))**0.5 for p, q in zip(a, b)))
```
Expected: equal counts, and a deviation under ~0.05 Å — the last captured frame is the
final structure, which is the check that the offset and slicing agree with the writer.

- [ ] **Step 6: Confirm an ordinary run still builds no trajectory**

Re-run the same command WITHOUT `live_view=1` and confirm no `_traj` object appears.

- [ ] **Step 7: Document it**

In `docs/generators.md`, after the "## Cancellation" section, add:

```markdown
## Watching a design diffuse

`design_backbone ..., live_view=1` — or the **Live** checkbox on the bar — streams the
rollout into a second object, `<result>_traj`, holding the designed chain only, one state
per captured frame. Scrub it with the frame slider or play it with `mplay`.

It is a recording, not a result. It carries no metrics and no design key: the result object
owns the identity, and a poly-ALA backbone claiming to be that design would put a second
thing in the session answering to it. The residues are poly-ALA because states of one
object share a single atom set and the sequence head's argmax changes during the rollout,
so per-state residue names are not representable.

Frames are captured every `RFD3JobManager.trajectoryStepInterval` (4) steps — about 50 from
a 199-step run. The object survives the run, including a cancelled one, and is an ordinary
object you can delete. Off by default: an extra 50-state object is a reasonable thing to
opt into and an unreasonable thing to be given.

Every failure in this path degrades to "no live view" and never fails the design.
```

- [ ] **Step 8: Commit**

```bash
git add docs/generators.md
git commit -m "docs(generators): document the live trajectory view"
```
