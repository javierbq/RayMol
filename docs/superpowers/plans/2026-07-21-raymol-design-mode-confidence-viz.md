# RayMol Design Mode — Confidence Visualization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS Design mode to RayMol that colors a focus object by per-residue MPNN confidence, dims other objects to semitransparent gray, restores the exact pre-mode visuals on exit, and caches scores per object.

**Architecture:** A new `DesignController` (`ObservableObject`) runs MPNNKit `score()` off the main thread on a serial queue (the MovieExporter thread-split, since MPNN touches only MLX/Metal, not the PyMOL GIL), then writes per-residue coloring back on the main thread through `PyMOLEngine.runCommand`. Residue enumeration, coloring, and visual-state save/restore are Python helpers in a new `raymol_design.py` module (mirroring `appkit_sequence.py`), so they are unit-testable with the existing headless `FakeCmd` harness. The mode is a peer of Move/Measure with mutual exclusion; the focus object is chosen by viewport click.

**Tech Stack:** Swift 6 / SwiftUI, MLX-swift (via the extracted `proteinmpnn-mlx` SPM package), the embedded PyMOL C++/Python core, xcodegen `project.yml` build, Python `unittest` headless harness.

## Global Constraints

- **Read-only slice:** color + transparency only; never change sequences or coordinates. Never mutate the *input* object's identity/coords.
- **macOS-only this slice:** MPNNKit dependency carries a `platforms: [macOS]` SPM filter; all new MPNN code is gated behind a `RAYMOL_MPNN` compile flag; the iOS target must remain unchanged (deployment target 16, no mlx).
- **All build config lives in `swiftui/project.yml`** — never the generated `.pbxproj` (xcodegen is re-run at release time by `make_dmg.sh` and `archive_appstore.sh`).
- **Off-main rule:** MPNN inference runs off the main thread; every PyMOL core read/write happens on the main thread (via `runCommand`/bridge). Never use `runHeavy` (runs on-main) or the MCP/copilot path (30 s/120 s timeouts) for inference.
- **Exact restore invariant:** exiting the mode (or switching to another mode) restores every object's pre-mode per-atom colors and transparency settings verbatim.
- **Cache key = `(object, displayedState, sequenceHash)`**; invalidated on sequence/state change or object deletion; persists across mode enter/exit for the session.
- **Serialize inference:** one MPNN job at a time (memory); a monotonically increasing job token discards superseded results.
- **MPNN alphabet:** `ACDEFGHIKLMNPQRSTVWYX`, index 20 = `X` (nonstandard/unknown). `sequence` is `[Int]` of these indices.

## Interface Contracts (shared by all tasks)

**From the `proteinmpnn-mlx` MPNNKit package (Phase 1, existing — do not modify):**
```swift
public struct MPNNModel {
    public init(packDirectory: URL) throws
    public struct Residue { public init(n: SIMD3<Float>, ca: SIMD3<Float>, c: SIMD3<Float>, o: SIMD3<Float>, chain: Int, resSeq: Int) }
    public enum ScoreMode: Equatable, Sendable { case conditional, unconditional, leaveOneOut }
    public struct ScoreResult { public let logProbs: [[Float]]; public let currentAALogProb: [Float]? }
    public func score(_ residues: [Residue], sequence: [Int]?, mode: ScoreMode, seed: UInt64?) throws -> ScoreResult
    public static var alphabet: [Character] { get }   // "ACDEFGHIKLMNPQRSTVWYX"
}
```

**New Python module `modules/pymol/raymol_design.py`** (all write JSON to `$TMPDIR`, return a short marker):
```python
def enumerate_design_residues(obj: str, state: int) -> str   # -> "DESIGN_RESIDUES:ready"; writes raymol_design_residues.json
def apply_design_coloring(obj: str, values_json_path: str, palette: str, lo: float, hi: float) -> str  # -> "DESIGN_COLOR:ok"
def snapshot_visual_state(objects_csv: str) -> str            # -> "DESIGN_SNAP:ok"; stashes p._design_savedcolor + records transparency to raymol_design_snapshot.json
def dim_object(obj: str, gray_color: str, transparency: float) -> str   # -> "DESIGN_DIM:ok"
def restore_visual_state() -> str                             # -> "DESIGN_RESTORE:ok"; reverses snapshot exactly
```

`enumerate_design_residues` JSON shape:
```json
{"object":"m1","state":1,
 "residues":[{"chain":"A","resi":"12","resn":"ALA","aa":0,
              "n":[x,y,z],"ca":[x,y,z],"c":[x,y,z],"o":[x,y,z],"valid":true}, ...]}
```
`aa` = MPNN alphabet index of the 3-letter `resn` (20 for nonstandard); `valid` = all four backbone atoms present; coords are `null` when absent.

**New Swift types:**
```swift
enum DesignColorMeaning: String, CaseIterable { case nativeFit, certainty }

struct DesignResidue { let chain: String; let resi: String; let resn: String; let aa: Int
                       let backbone: MPNNModel.Residue?; let valid: Bool }   // backbone nil when !valid

struct DesignResidueSet {
    let object: String; let state: Int; let residues: [DesignResidue]
    var validResidues: [MPNNModel.Residue]   // backbone of valid residues, in order
    var nativeSequence: [Int]                // aa of valid residues, in order
    var sequenceHash: Int                    // hash of all residues' aa, order-sensitive
    static func parse(jsonAt url: URL) throws -> DesignResidueSet
}

struct DesignScores { let nativeFit: [Float?]; let certainty: [Float?] }   // per residue (residues.count); nil = masked
struct DesignCacheKey: Hashable { let object: String; let state: Int; let sequenceHash: Int }
final class DesignScoreCache {
    func get(_ key: DesignCacheKey) -> DesignScores?
    func set(_ key: DesignCacheKey, _ scores: DesignScores)
    func invalidate(object: String)
}

enum DesignColor {   // pure normalization
    static let nativeFitDomain: ClosedRange<Float> = (-6.0)...0.0     // log-prob
    static let certaintyDomain: ClosedRange<Float> = 0.0...1.0        // 1 - H/ln(21)
    static func scalar(_ scores: DesignScores, _ meaning: DesignColorMeaning) -> [Float?]
    static func certainty(fromLogProbsRow row: [Float]) -> Float      // 1 - Shannon entropy / ln(21)
}
```

**New engine/controller surface:**
```swift
// PyMOLEngine (add):
@Published var designMode: Bool
func setDesignMode(_ on: Bool)          // clears interactionMode/measureMode when turning on

// DesignController: ObservableObject (new)
@Published var focusObject: String?
@Published var colorMeaning: DesignColorMeaning
@Published var isScoring: Bool
@Published var legendDomain: ClosedRange<Float>?
@Published var errorText: String?
func enter()                            // snapshot visuals, auto-focus if single object
func exit()                             // restore visuals exactly
func focus(_ object: String)            // dim others, score+color this one (cache-aware)
func setMeaning(_ meaning: DesignColorMeaning)
```

---

### Task 1: Extract MPNNKit into the `proteinmpnn-mlx` repo

**Files:**
- Create: new git repo `javierbq/proteinmpnn-mlx` (root `Package.swift`, `Sources/MPNNKit/…`, `Tests/MPNNKitTests/…`, test assets).
- Source: `/Users/jcastellanos/repos/proteinmpnn-ios/MPNNKit/**` (moved to repo root).

**Interfaces:**
- Produces: a tagged SPM package `proteinmpnn-mlx` at `v0.1.0` whose `Package.swift` is at the repo root and whose `MPNNModel` API matches the Interface Contracts.

- [ ] **Step 1: Create the new repo locally from the existing package**

```bash
cd /Users/jcastellanos/repos
git clone --no-local proteinmpnn-ios proteinmpnn-mlx-tmp   # keeps history
cd proteinmpnn-mlx-tmp
git filter-repo --subdirectory-filter MPNNKit               # promote MPNNKit/ to root (install git-filter-repo if needed)
```
Expected: repo root now contains `Package.swift`, `Sources/`, `Tests/`.

- [ ] **Step 2: Verify the package builds and tests pass standalone**

Run: `cd /Users/jcastellanos/repos/proteinmpnn-mlx-tmp && swift test`
Expected: 21/21 pass (same suite as Phase 1). If a test asset (`.safetensors` fixtures, `MPNN.mpnnpack`) is referenced by relative path outside `MPNNKit/`, copy it into the repo and fix the path in `TestFixtures.swift`; re-run until green.

- [ ] **Step 3: Create the GitHub repo and push**

```bash
gh repo create javierbq/proteinmpnn-mlx --private --source=/Users/jcastellanos/repos/proteinmpnn-mlx-tmp --remote=origin --push
cd /Users/jcastellanos/repos/proteinmpnn-mlx-tmp && git tag v0.1.0 && git push origin v0.1.0
```
Expected: repo exists, `main` + `v0.1.0` pushed.

- [ ] **Step 4: Confirm resolvable as an SPM dependency**

Run: `mkdir -p /tmp/spmcheck && cd /tmp/spmcheck && swift package init && printf '\n' ` then add the dependency to a scratch `Package.swift` (`.package(url: "https://github.com/javierbq/proteinmpnn-mlx.git", from: "0.1.0")`) and run `swift package resolve`.
Expected: resolves to `0.1.0` (proves root `Package.swift` + tag work). Remove `/tmp/spmcheck` after.

- [ ] **Step 5: Record the decision**

No commit in RayMol yet. Note the resolved URL + tag for Task 2. (proteinmpnn-ios keeps the Python `port/` oracle tooling; the Swift package's canonical home is now proteinmpnn-mlx.)

---

### Task 2: Wire the MPNNKit dependency into the RayMol macOS build

**Files:**
- Modify: `swiftui/project.yml` (packages, target deps, settings, resources) — anchors `:4-7` (deploymentTarget), `:19-23` (`packages:`), `:26-27` (SWIFT_VERSION/xcodeVersion), `:308-337` (macOS resource postBuildScript), `:393-399` (Sparkle dep template).
- Add: `MPNN.mpnnpack` into the macOS Resources (copy from `proteinmpnn-mlx`/`proteinmpnn-ios` `dist/MPNN.mpnnpack`).
- Create: `swiftui/PyMOLViewer/Shared/MPNNGate.swift` (a tiny smoke-test entry behind `RAYMOL_MPNN`).

**Interfaces:**
- Produces: `import MPNNKit` compiles in the macOS app behind `#if RAYMOL_MPNN`; `MPNNModel(packDirectory:)` can load the bundled pack. A `RAYMOL_MPNN` Swift active-compilation-condition set for macOS only.

- [ ] **Step 1: Add the package and macOS-filtered dependency to `project.yml`**

In the top-level `packages:` block add:
```yaml
  proteinmpnn-mlx:
    url: https://github.com/javierbq/proteinmpnn-mlx.git
    from: 0.1.0
```
In the `PyMOLViewer` target `dependencies:` add (OUTSIDE any `RAYMOL_SPARKLE_BEGIN/END` marker, mirroring the Sparkle entry at `:393-399`):
```yaml
    - package: proteinmpnn-mlx
      product: MPNNKit
      platformFilter: macOS
```

- [ ] **Step 2: Bump toolchain + macOS floor, define `RAYMOL_MPNN` (macOS only)**

In `project.yml` set `options.xcodeVersion: "16.0"`, `settings.SWIFT_VERSION: 6.0`, and macOS `deploymentTarget.macOS: "14.0"` (leave iOS at 16). Add a macOS-only Swift flag using xcodegen conditional settings:
```yaml
    SWIFT_ACTIVE_COMPILATION_CONDITIONS[sdk=macosx*]: "$(inherited) RAYMOL_MPNN"
```

- [ ] **Step 3: Bundle the weights (macOS)**

Copy `MPNN.mpnnpack` into `swiftui/PyMOLViewer/Resources/` and add it as a folder-reference resource for the macOS platform in `project.yml` (mirror how `1ubq.cif` is referenced). Confirm it is a *folder* reference (the pack is a directory).

- [ ] **Step 4: Add the smoke-test gate file**

Create `swiftui/PyMOLViewer/Shared/MPNNGate.swift`:
```swift
#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum MPNNGate {
    /// Bundled pack URL, or nil if missing.
    static var packURL: URL? { Bundle.main.url(forResource: "MPNN", withExtension: "mpnnpack") }
    /// Debug smoke check: pack loads. Not wired to UI.
    static func canLoadModel() -> Bool {
        guard let url = packURL else { return false }
        return (try? MPNNModel(packDirectory: url)) != nil
    }
}
#endif
```

- [ ] **Step 5: Regenerate the project and build macOS**

Run: `cd swiftui && ./build_macos.sh && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, with mlx-swift resolved and linked. (First build resolves the SPM package.)

- [ ] **Step 6: Verify iOS build is unaffected**

Run: `xcodebuild -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, and mlx-swift is NOT linked into the iOS product (the `platformFilter: macOS` kept it out). If iOS tries to resolve mlx, the filter is wrong — fix before proceeding.

- [ ] **Step 7: Commit**

```bash
git add swiftui/project.yml swiftui/PyMOLViewer/Resources/MPNN.mpnnpack swiftui/PyMOLViewer/Shared/MPNNGate.swift
git commit -m "build(design): add macOS-only MPNNKit dependency + weights + RAYMOL_MPNN gate"
```

---

### Task 3: Python residue enumeration helper

**Files:**
- Create: `modules/pymol/raymol_design.py`
- Test: `testing/tests/raymol/design_enumerate.py` (headless `FakeCmd` harness — mirror an existing `testing/tests/**` appkit test).

**Interfaces:**
- Produces: `enumerate_design_residues(obj, state)` writing the JSON documented in Interface Contracts and returning `"DESIGN_RESIDUES:ready"`.

- [ ] **Step 1: Write the failing test**

```python
# design_enumerate.py
import json, os, tempfile
from pymol import cmd, testing

class TestDesignEnumerate(testing.PyMOLTestCase):
    def testGuideOrderAndBackbone(self):
        cmd.reinitialize()
        cmd.fragment('ala', 'm1')            # a tiny residue with N,CA,C,O
        from pymol import raymol_design
        marker = raymol_design.enumerate_design_residues('m1', 1)
        self.assertEqual(marker, 'DESIGN_RESIDUES:ready')
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')
        data = json.load(open(path))
        self.assertEqual(data['object'], 'm1')
        r0 = data['residues'][0]
        self.assertEqual(r0['resn'], 'ALA')
        self.assertEqual(r0['aa'], 0)                 # 'A' -> index 0
        self.assertTrue(r0['valid'])
        for k in ('n', 'ca', 'c', 'o'):
            self.assertEqual(len(r0[k]), 3)
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_enumerate.py`
Expected: FAIL (`No module named raymol_design` or `enumerate_design_residues` missing).

- [ ] **Step 3: Implement `enumerate_design_residues`**

```python
# modules/pymol/raymol_design.py
"""RayMol Design-mode core helpers: residue enumeration, coloring, and
exact visual-state save/restore. Mirrors the appkit_sequence bundled-module
pattern (writes JSON to TMPDIR, returns a short marker)."""
import json, os, tempfile
from pymol import cmd

# 3-letter -> MPNN alphabet index ("ACDEFGHIKLMNPQRSTVWYX", X=20).
_ONE = {'ALA':'A','ARG':'R','ASN':'N','ASP':'D','CYS':'C','GLN':'Q','GLU':'E',
        'GLY':'G','HIS':'H','ILE':'I','LEU':'L','LYS':'K','MET':'M','PHE':'F',
        'PRO':'P','SER':'S','THR':'T','TRP':'W','TYR':'Y','VAL':'V'}
_ALPHABET = "ACDEFGHIKLMNPQRSTVWYX"
_AA_INDEX = {c: i for i, c in enumerate(_ALPHABET)}

def _tmp(name): return os.path.join(tempfile.gettempdir(), name)

def enumerate_design_residues(obj, state):
    state = int(state)
    # Guide atoms give one row per residue in canonical (chain, resv, inscode) order.
    order = []
    cmd.iterate('(%s) and polymer and guide' % obj,
                'order.append((chain, resi, resn))', space={'order': order})
    # Backbone atom coords for the same residues.
    atoms = {}
    def _collect(chain, resi, name, x, y, z):
        atoms.setdefault((chain, resi), {})[name] = (x, y, z)
    cmd.iterate_state(state, '(%s) and polymer and name N+CA+C+O' % obj,
                      '_collect(chain, resi, name, x, y, z)',
                      space={'_collect': _collect})
    residues = []
    for (chain, resi, resn) in order:
        bb = atoms.get((chain, resi), {})
        valid = all(k in bb for k in ('N', 'CA', 'C', 'O'))
        aa = _AA_INDEX.get(_ONE.get(resn, 'X'), 20)
        residues.append({
            'chain': chain, 'resi': resi, 'resn': resn, 'aa': aa, 'valid': valid,
            'n':  list(bb['N'])  if 'N'  in bb else None,
            'ca': list(bb['CA']) if 'CA' in bb else None,
            'c':  list(bb['C'])  if 'C'  in bb else None,
            'o':  list(bb['O'])  if 'O'  in bb else None,
        })
    with open(_tmp('raymol_design_residues.json'), 'w') as f:
        json.dump({'object': obj, 'state': state, 'residues': residues}, f)
    return 'DESIGN_RESIDUES:ready'
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_enumerate.py`
Expected: PASS.

- [ ] **Step 5: Add a missing-backbone test and re-run**

Append to the test class:
```python
    def testMissingBackboneMasked(self):
        cmd.reinitialize(); cmd.fragment('gly', 'm1')
        cmd.remove('m1 and name O')       # drop an O
        from pymol import raymol_design
        raymol_design.enumerate_design_residues('m1', 1)
        import json, os, tempfile
        data = json.load(open(os.path.join(tempfile.gettempdir(), 'raymol_design_residues.json')))
        self.assertFalse(data['residues'][0]['valid'])
        self.assertIsNone(data['residues'][0]['o'])
```
Run the file again; expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_enumerate.py
git commit -m "feat(design): residue enumeration helper (guide order + backbone + AA index + mask)"
```

---

### Task 4: Swift residue parsing, chain mapping, native sequence, sequence hash

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignResidues.swift`
- Test: `swiftui/PyMOLViewerTests/DesignResiduesTests.swift`

**Interfaces:**
- Consumes: the JSON from Task 3.
- Produces: `DesignResidue`, `DesignResidueSet` (with `validResidues`, `nativeSequence`, `sequenceHash`, `static parse(jsonAt:)`) per the Interface Contracts.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RayMol   // module name per project.yml product

final class DesignResiduesTests: XCTestCase {
    private func writeJSON(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("t.json")
        try s.write(to: u, atomically: true, encoding: .utf8); return u
    }
    func testParseMapsChainsAndMasksInvalid() throws {
        let json = """
        {"object":"m1","state":1,"residues":[
          {"chain":"A","resi":"1","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[1,0,0],"c":[2,0,0],"o":[3,0,0]},
          {"chain":"A","resi":"2","resn":"GLY","aa":6,"valid":false,"n":null,"ca":[1,1,1],"c":null,"o":null},
          {"chain":"B","resi":"1","resn":"VAL","aa":19,"valid":true,"n":[0,0,1],"ca":[1,0,1],"c":[2,0,1],"o":[3,0,1]}]}
        """
        let set = try DesignResidueSet.parse(jsonAt: writeJSON(json))
        XCTAssertEqual(set.residues.count, 3)
        XCTAssertEqual(set.validResidues.count, 2)               // masked one dropped
        XCTAssertEqual(set.nativeSequence, [0, 19])              // valid residues' aa, in order
        XCTAssertEqual(set.validResidues[0].chain, 0)            // chain A -> 0
        XCTAssertEqual(set.validResidues[1].chain, 1)            // chain B -> 1 (first-seen order)
        XCTAssertEqual(set.validResidues[1].resSeq, 1)
    }
    func testSequenceHashChangesWithSequence() throws {
        let a = try DesignResidueSet.parse(jsonAt: writeJSON(#"{"object":"m","state":1,"residues":[{"chain":"A","resi":"1","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[0,0,0],"c":[0,0,0],"o":[0,0,0]}]}"#))
        let b = try DesignResidueSet.parse(jsonAt: writeJSON(#"{"object":"m","state":1,"residues":[{"chain":"A","resi":"1","resn":"VAL","aa":19,"valid":true,"n":[0,0,0],"ca":[0,0,0],"c":[0,0,0],"o":[0,0,0]}]}"#))
        XCTAssertNotEqual(a.sequenceHash, b.sequenceHash)
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/DesignResiduesTests 2>&1 | tail -15`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement `DesignResidues.swift`**

```swift
#if RAYMOL_MPNN
import Foundation
import MPNNKit
import simd

struct DesignResidue {
    let chain: String; let resi: String; let resn: String; let aa: Int
    let backbone: MPNNModel.Residue?; let valid: Bool
}

struct DesignResidueSet {
    let object: String; let state: Int; let residues: [DesignResidue]

    var validResidues: [MPNNModel.Residue] { residues.compactMap { $0.backbone } }
    var nativeSequence: [Int] { residues.filter { $0.valid }.map { $0.aa } }
    var sequenceHash: Int {
        var h = Hasher(); for r in residues { h.combine(r.aa) }; return h.finalize()
    }

    static func parse(jsonAt url: URL) throws -> DesignResidueSet {
        struct RawRes: Decodable { let chain: String; let resi: String; let resn: String; let aa: Int; let valid: Bool
                                   let n: [Float]?; let ca: [Float]?; let c: [Float]?; let o: [Float]? }
        struct Raw: Decodable { let object: String; let state: Int; let residues: [RawRes] }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf: url))
        var chainMap: [String: Int] = [:]; var next = 0
        func chainInt(_ s: String) -> Int { if let i = chainMap[s] { return i }; chainMap[s] = next; next += 1; return next - 1 }
        func vec(_ a: [Float]?) -> SIMD3<Float>? { a.map { SIMD3<Float>($0[0], $0[1], $0[2]) } }
        let residues: [DesignResidue] = raw.residues.map { rr in
            var bb: MPNNModel.Residue? = nil
            if rr.valid, let n = vec(rr.n), let ca = vec(rr.ca), let c = vec(rr.c), let o = vec(rr.o) {
                let resSeq = Int(rr.resi.prefix { $0.isNumber || $0 == "-" }) ?? 0
                bb = MPNNModel.Residue(n: n, ca: ca, c: c, o: o, chain: chainInt(rr.chain), resSeq: resSeq)
            }
            return DesignResidue(chain: rr.chain, resi: rr.resi, resn: rr.resn, aa: rr.aa, backbone: bb, valid: bb != nil)
        }
        return DesignResidueSet(object: raw.object, state: raw.state, residues: residues)
    }
}
#endif
```

- [ ] **Step 4: Run the test, verify it passes**

Run the Step-2 command. Expected: PASS (both tests). Note: `sequenceHash` uses `Hasher` — stable within a process run, which is all the cache needs; do not persist it.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignResidues.swift swiftui/PyMOLViewerTests/DesignResiduesTests.swift
git commit -m "feat(design): parse residue JSON -> [MPNNModel.Residue] + chain map + native seq + hash"
```

---

### Task 5: Score cache

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignScoreCache.swift`
- Test: `swiftui/PyMOLViewerTests/DesignScoreCacheTests.swift`

**Interfaces:**
- Consumes: `DesignScores`, `DesignCacheKey`.
- Produces: `DesignScoreCache` (`get`/`set`/`invalidate(object:)`).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RayMol

final class DesignScoreCacheTests: XCTestCase {
    func testHitMissAndInvalidate() {
        let cache = DesignScoreCache()
        let k1 = DesignCacheKey(object: "m1", state: 1, sequenceHash: 42)
        XCTAssertNil(cache.get(k1))
        cache.set(k1, DesignScores(nativeFit: [-1.0], certainty: [0.5]))
        XCTAssertEqual(cache.get(k1)?.nativeFit, [-1.0])
        // Different sequence hash = miss (sequence changed).
        XCTAssertNil(cache.get(DesignCacheKey(object: "m1", state: 1, sequenceHash: 43)))
        // Different state = miss.
        XCTAssertNil(cache.get(DesignCacheKey(object: "m1", state: 2, sequenceHash: 42)))
        cache.invalidate(object: "m1")
        XCTAssertNil(cache.get(k1))
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/DesignScoreCacheTests 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `DesignScoreCache.swift`**

```swift
#if RAYMOL_MPNN
import Foundation

struct DesignScores: Equatable { let nativeFit: [Float?]; let certainty: [Float?] }
struct DesignCacheKey: Hashable { let object: String; let state: Int; let sequenceHash: Int }

final class DesignScoreCache {
    private var store: [DesignCacheKey: DesignScores] = [:]
    func get(_ key: DesignCacheKey) -> DesignScores? { store[key] }
    func set(_ key: DesignCacheKey, _ scores: DesignScores) { store[key] = scores }
    func invalidate(object: String) { store = store.filter { $0.key.object != object } }
}
#endif
```
(`Float?` arrays are `Equatable`, so `DesignScores: Equatable` synthesizes.)

- [ ] **Step 4: Run the test, verify it passes**

Run the Step-2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignScoreCache.swift swiftui/PyMOLViewerTests/DesignScoreCacheTests.swift
git commit -m "feat(design): (object,state,seqHash) score cache"
```

---

### Task 6: Score → color normalization (Swift) + coloring apply (Python)

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignColor.swift`
- Modify: `modules/pymol/raymol_design.py` (add `apply_design_coloring`)
- Test: `swiftui/PyMOLViewerTests/DesignColorTests.swift`; `testing/tests/raymol/design_color.py`

**Interfaces:**
- Consumes: `DesignScores`, `MPNNModel.ScoreResult` (for building `DesignScores`), `DesignColorMeaning`.
- Produces: `DesignColor.certainty(fromLogProbsRow:)`, `DesignColor.scalar(_:_:)`, `DesignColorMeaning`; `raymol_design.apply_design_coloring`.

- [ ] **Step 1: Write the failing Swift test**

```swift
import XCTest
@testable import RayMol

final class DesignColorTests: XCTestCase {
    func testCertaintyPeakedVsFlat() {
        let n = 21
        // Flat distribution -> low certainty (~0); one-hot -> high (~1).
        let flat = [Float](repeating: Float(log(1.0/21.0)), count: n)
        var peak = [Float](repeating: Float(log(1e-6)), count: n); peak[3] = Float(log(1.0 - 20e-6))
        XCTAssertLessThan(DesignColor.certainty(fromLogProbsRow: flat), 0.05)
        XCTAssertGreaterThan(DesignColor.certainty(fromLogProbsRow: peak), 0.95)
    }
    func testScalarSelectsMeaning() {
        let s = DesignScores(nativeFit: [-2.0, nil], certainty: [0.8, nil])
        XCTAssertEqual(DesignColor.scalar(s, .nativeFit), [-2.0, nil])
        XCTAssertEqual(DesignColor.scalar(s, .certainty), [0.8, nil])
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/DesignColorTests 2>&1 | tail -15`
Expected: FAIL.

- [ ] **Step 3: Implement `DesignColor.swift`**

```swift
#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum DesignColorMeaning: String, CaseIterable { case nativeFit, certainty }

enum DesignColor {
    static let nativeFitDomain: ClosedRange<Float> = (-6.0)...0.0
    static let certaintyDomain: ClosedRange<Float> = 0.0...1.0

    /// 1 - Shannon entropy / ln(21), from a log-prob row. 0 = flat, 1 = one-hot.
    static func certainty(fromLogProbsRow row: [Float]) -> Float {
        var h: Float = 0
        for lp in row { let p = expf(lp); if p > 0 { h -= p * lp } }   // H = -sum p ln p
        let hmax = logf(Float(row.count))
        return hmax > 0 ? max(0, min(1, 1 - h / hmax)) : 0
    }

    static func scalar(_ scores: DesignScores, _ meaning: DesignColorMeaning) -> [Float?] {
        meaning == .nativeFit ? scores.nativeFit : scores.certainty
    }

    static func domain(_ meaning: DesignColorMeaning) -> ClosedRange<Float> {
        meaning == .nativeFit ? nativeFitDomain : certaintyDomain
    }
    static func palette(_ meaning: DesignColorMeaning) -> String {
        // native-fit: red(low/bad) -> white -> blue(high/good); certainty: blue(low) -> red(high)
        meaning == .nativeFit ? "red_white_blue" : "blue_white_red"
    }

    /// Build DesignScores from one leaveOneOut ScoreResult, aligned to the full residue list.
    /// `validMask[i]` true where residues[i] contributed a row (in order).
    static func scores(from r: MPNNModel.ScoreResult, validMask: [Bool]) -> DesignScores {
        var nf = [Float?](repeating: nil, count: validMask.count)
        var ce = [Float?](repeating: nil, count: validMask.count)
        var j = 0
        for i in 0..<validMask.count where validMask[i] {
            if let cur = r.currentAALogProb, j < cur.count { nf[i] = cur[j] }
            if j < r.logProbs.count { ce[i] = certainty(fromLogProbsRow: r.logProbs[j]) }
            j += 1
        }
        return DesignScores(nativeFit: nf, certainty: ce)
    }
}
#endif
```

- [ ] **Step 4: Run the Swift test, verify it passes**

Run the Step-2 command. Expected: PASS.

- [ ] **Step 5: Write the failing Python coloring test**

```python
# testing/tests/raymol/design_color.py
import json, os, tempfile
from pymol import cmd, testing

class TestDesignColor(testing.PyMOLTestCase):
    def testAppliesPropertyAndSpectrum(self):
        cmd.reinitialize(); cmd.fragment('ala', 'm1')
        vals = {'A|None|1': 0.5}          # key = chain|segi|resi is fragile; use (chain,resi)
        path = os.path.join(tempfile.gettempdir(), 'raymol_design_vals.json')
        json.dump([{'chain': 'A', 'resi': '1', 'value': 0.5}], open(path, 'w'))
        from pymol import raymol_design
        out = raymol_design.apply_design_coloring('m1', path, 'blue_white_red', 0.0, 1.0)
        self.assertEqual(out, 'DESIGN_COLOR:ok')
        got = []
        cmd.iterate('m1 and guide', 'got.append(p.mpnn_conf)', space={'got': got})
        self.assertAlmostEqual(got[0], 0.5, places=5)
```

- [ ] **Step 6: Run it, verify it fails**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_color.py`
Expected: FAIL (`apply_design_coloring` missing).

- [ ] **Step 7: Implement `apply_design_coloring` in `raymol_design.py`**

```python
def apply_design_coloring(obj, values_json_path, palette, lo, hi):
    rows = json.load(open(values_json_path))            # [{'chain','resi','value'}, ...]
    vmap = {(r['chain'], r['resi']): float(r['value']) for r in rows if r.get('value') is not None}
    def _set(chain, resi):
        v = vmap.get((chain, resi))
        return v if v is not None else None
    # Write per-residue scalar into a custom atom property.
    cmd.alter(obj, 'p.mpnn_conf = _lookup(chain, resi)',
              space={'_lookup': _set})
    # Color only residues that received a value; spectrum over the fixed domain.
    cmd.spectrum('p.mpnn_conf', palette, '(%s) and rep_or_all' % obj if False else obj,
                 minimum=float(lo), maximum=float(hi))
    return 'DESIGN_COLOR:ok'
```
(If `spectrum`'s `minimum/maximum` kwargs are unavailable on this build, fall back to `spectrum('p.mpnn_conf', palette, obj)` and document that auto-scaling is used; the Swift legend then reads the same lo/hi it passed.)

- [ ] **Step 8: Run the Python test, verify it passes**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_color.py`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignColor.swift swiftui/PyMOLViewerTests/DesignColorTests.swift modules/pymol/raymol_design.py testing/tests/raymol/design_color.py
git commit -m "feat(design): score->color normalization (native-fit + neg-entropy certainty) + apply_design_coloring"
```

---

### Task 7: Visual-state save/restore + dim (Python)

**Files:**
- Modify: `modules/pymol/raymol_design.py` (add `snapshot_visual_state`, `dim_object`, `restore_visual_state`)
- Test: `testing/tests/raymol/design_saverestore.py`

**Interfaces:**
- Produces: `snapshot_visual_state(objects_csv)`, `dim_object(obj, gray_color, transparency)`, `restore_visual_state()`.

- [ ] **Step 1: Write the failing test (exact restore)**

```python
# testing/tests/raymol/design_saverestore.py
from pymol import cmd, testing

_TSET = ['cartoon_transparency', 'transparency', 'stick_transparency', 'sphere_transparency']

class TestDesignSaveRestore(testing.PyMOLTestCase):
    def testColorAndTransparencyRestoredExactly(self):
        cmd.reinitialize(); cmd.fragment('ala', 'm1'); cmd.fragment('gly', 'm2')
        cmd.color('red', 'm1'); cmd.color('green', 'm2')
        before1 = []; cmd.iterate('m1', 'before1.append(color)', space={'before1': before1})
        from pymol import raymol_design
        raymol_design.snapshot_visual_state('m1,m2')
        raymol_design.dim_object('m2', 'gray70', 0.7)     # dim m2
        cmd.color('blue', 'm1')                            # recolor m1 (as if scored)
        raymol_design.restore_visual_state()
        after1 = []; cmd.iterate('m1', 'after1.append(color)', space={'after1': after1})
        self.assertEqual(before1, after1)                  # exact color restore
        self.assertAlmostEqual(cmd.get_setting_float('transparency', 'm2'), 0.0, places=5)
        # scratch property removed
        leftover = []; cmd.iterate('m1', 'leftover.append(1 if "_design_savedcolor" in (p.all or {}) else 0)', space={'leftover': leftover})
        self.assertEqual(sum(leftover), 0)
```

- [ ] **Step 2: Run it, verify it fails**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_saverestore.py`
Expected: FAIL.

- [ ] **Step 3: Implement snapshot/dim/restore**

```python
_TRANSP = ['cartoon_transparency', 'transparency', 'stick_transparency',
           'sphere_transparency', 'ribbon_transparency', 'surface_transparency']

def snapshot_visual_state(objects_csv):
    objs = [o for o in objects_csv.split(',') if o]
    settings = {}
    for o in objs:
        cmd.alter(o, 'p._design_savedcolor = color')       # stash per-atom color
        settings[o] = {s: cmd.get_setting_float(s, o) for s in _TRANSP}
    with open(_tmp('raymol_design_snapshot.json'), 'w') as f:
        json.dump({'objects': objs, 'settings': settings}, f)
    return 'DESIGN_SNAP:ok'

def dim_object(obj, gray_color, transparency):
    cmd.color(gray_color, obj)
    for s in _TRANSP:
        cmd.set(s, float(transparency), obj)
    return 'DESIGN_DIM:ok'

def restore_visual_state():
    snap = json.load(open(_tmp('raymol_design_snapshot.json')))
    for o in snap['objects']:
        # restore transparency settings first
        for s, v in snap['settings'][o].items():
            cmd.set(s, float(v), o)
        # restore per-atom color from the stash, then remove the stash property
        cmd.alter(o, 'color = p._design_savedcolor')
        cmd.alter(o, "p.pop('_design_savedcolor', None)")
    cmd.recolor()
    return 'DESIGN_RESTORE:ok'
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_saverestore.py`
Expected: PASS. If `p.pop(...)` in `alter` is unsupported, substitute `cmd.alter(o, "del p['_design_savedcolor']")` guarded by presence, and re-run.

- [ ] **Step 5: Commit**

```bash
git add modules/pymol/raymol_design.py testing/tests/raymol/design_saverestore.py
git commit -m "feat(design): exact visual-state snapshot/dim/restore helpers"
```

---

### Task 8: DesignController (model lifecycle, off-main scoring, orchestration)

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/DesignController.swift`
- Test: `swiftui/PyMOLViewerTests/DesignControllerTests.swift`
- Reference (read for the bridge/threading idiom): `swiftui/PyMOLViewer/Panels/MovieExportSheet.swift:130-167`; `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:776` (`runCommand`).

**Interfaces:**
- Consumes: `PyMOLEngine.runCommand`, `MPNNGate.packURL`, `DesignResidueSet`, `DesignScoreCache`, `DesignColor`, and a scoring closure (injected for testability).
- Produces: `DesignController` per the Interface Contracts, plus `typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult`.

- [ ] **Step 1: Write the failing test (cache-hit path avoids re-scoring; injected scorer)**

```swift
import XCTest
@testable import RayMol

@MainActor
final class DesignControllerTests: XCTestCase {
    func testFocusScoresOnceThenHitsCache() async throws {
        var scoreCalls = 0
        let residueSet = DesignResidueSet(object: "m1", state: 1, residues: [
            DesignResidue(chain: "A", resi: "1", resn: "ALA", aa: 0,
                          backbone: .init(n: .zero, ca: .zero, c: .zero, o: .zero, chain: 0, resSeq: 1), valid: true)])
        let controller = DesignController(
            enumerate: { _, _ in residueSet },
            score: { _, _ in scoreCalls += 1
                     return MPNNModel.ScoreResult(logProbs: [[Float](repeating: Float(log(1.0/21)), count: 21)],
                                                  currentAALogProb: [-1.0]) },
            applyColoring: { _, _, _, _, _ in }, dim: { _ in }, snapshot: { _ in }, restore: { })
        controller.enter()
        await controller.focusAwait("m1")     // test-only awaitable variant of focus(_:)
        XCTAssertEqual(scoreCalls, 1)
        await controller.focusAwait("m1")     // same object/seq/state -> cache hit
        XCTAssertEqual(scoreCalls, 1)
    }
}
```
(This requires `MPNNModel.ScoreResult` to be constructible in tests — it has a public memberwise init from Phase 1. If not, add a public init in the package as a tiny follow-up. `DesignController` takes injectable closures so no real model/Metal is needed.)

- [ ] **Step 2: Run it, verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/DesignControllerTests 2>&1 | tail -20`
Expected: FAIL.

- [ ] **Step 3: Implement `DesignController.swift`**

```swift
#if RAYMOL_MPNN
import Foundation
import MPNNKit
import Combine

@MainActor
final class DesignController: ObservableObject {
    @Published var focusObject: String?
    @Published var colorMeaning: DesignColorMeaning = .nativeFit
    @Published var isScoring = false
    @Published var legendDomain: ClosedRange<Float>?
    @Published var errorText: String?
    @Published private(set) var allObjects: [String] = []

    typealias EnumerateFn = (String, Int) throws -> DesignResidueSet
    typealias ScoreFn = ([MPNNModel.Residue], [Int]) throws -> MPNNModel.ScoreResult
    typealias ColorFn = (_ obj: String, _ values: [(String, String, Float?)], _ palette: String, _ lo: Float, _ hi: Float) -> Void

    private let enumerate: EnumerateFn
    private let score: ScoreFn
    private let applyColoring: ColorFn
    private let dim: (String) -> Void
    private let snapshot: ([String]) -> Void
    private let restore: () -> Void

    private let cache = DesignScoreCache()
    private let queue = DispatchQueue(label: "io.raymol.design.inference")
    private var jobToken = 0
    private var lastSet: [String: DesignResidueSet] = [:]

    init(enumerate: @escaping EnumerateFn, score: @escaping ScoreFn, applyColoring: @escaping ColorFn,
         dim: @escaping (String) -> Void, snapshot: @escaping ([String]) -> Void, restore: @escaping () -> Void) {
        self.enumerate = enumerate; self.score = score; self.applyColoring = applyColoring
        self.dim = dim; self.snapshot = snapshot; self.restore = restore
    }

    func enter() {
        snapshot(allObjects)
        if allObjects.count == 1 { focus(allObjects[0]) }
    }
    func exit() { restore(); focusObject = nil; jobToken += 1 }

    func setMeaning(_ m: DesignColorMeaning) { colorMeaning = m; if let o = focusObject { recolor(o) } }

    func focus(_ object: String) { Task { await focusAwait(object) } }

    func focusAwait(_ object: String) async {
        focusObject = object
        for o in allObjects where o != object { dim(o) }
        do {
            let set = try enumerate(object, currentState(object))
            lastSet[object] = set
            let key = DesignCacheKey(object: object, state: set.state, sequenceHash: set.sequenceHash)
            if cache.get(key) != nil { recolor(object); return }
            isScoring = true; errorText = nil
            let token = { jobToken += 1; return jobToken }()
            let residues = set.validResidues, native = set.nativeSequence
            let scores: DesignScores = try await withCheckedThrowingContinuation { cont in
                queue.async {
                    do { let r = try self.score(residues, native)
                         let mask = set.residues.map { $0.valid }
                         cont.resume(returning: DesignColor.scores(from: r, validMask: mask)) }
                    catch { cont.resume(throwing: error) }
                }
            }
            guard token == jobToken else { return }        // superseded
            cache.set(key, scores)
            isScoring = false
            recolor(object)
        } catch { isScoring = false; errorText = "\(error)" }
    }

    private func recolor(_ object: String) {
        guard let set = lastSet[object] else { return }
        let key = DesignCacheKey(object: object, state: set.state, sequenceHash: set.sequenceHash)
        guard let scores = cache.get(key) else { return }
        let scalar = DesignColor.scalar(scores, colorMeaning)
        let values = zip(set.residues, scalar).map { ($0.chain, $0.resi, $1) }
        let dom = DesignColor.domain(colorMeaning)
        legendDomain = dom
        applyColoring(object, values, DesignColor.palette(colorMeaning), dom.lowerBound, dom.upperBound)
    }

    private func currentState(_ object: String) -> Int { 1 }   // wired to engine.state in Task 10
}
#endif
```

- [ ] **Step 4: Run the test, verify it passes**

Run the Step-2 command. Expected: PASS (`scoreCalls == 1` on the second focus proves the cache hit).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/DesignController.swift swiftui/PyMOLViewerTests/DesignControllerTests.swift
git commit -m "feat(design): DesignController — off-main scoring, job token, cache-aware focus/recolor"
```

---

### Task 9: Design mode state in PyMOLEngine (mutual exclusion)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — add near `measureMode`/`interactionMode` (`:130-136`) and the mutual-exclusion setters (`:1929-1972`).
- Test: `swiftui/PyMOLViewerTests/DesignModeStateTests.swift`

**Interfaces:**
- Produces: `PyMOLEngine.designMode: Bool` (`@Published`) and `func setDesignMode(_:)` that clears `interactionMode`/`measureMode`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import RayMol

@MainActor
final class DesignModeStateTests: XCTestCase {
    func testDesignModeIsMutuallyExclusive() {
        let e = PyMOLEngine.shared          // existing singleton accessor
        e.setInteractionMode(.move)
        e.setDesignMode(true)
        XCTAssertTrue(e.designMode)
        XCTAssertEqual(e.interactionMode, .viewing)      // move cleared
        e.setMeasureMode(.distance)                      // entering measure clears design
        XCTAssertFalse(e.designMode)
    }
}
```
(Adjust `.distance`/`.move`/singleton accessor to the real enum cases/accessor found in `PyMOLEngine.swift`.)

- [ ] **Step 2: Run it, verify it fails**

Run: `cd swiftui && xcodebuild test -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/DesignModeStateTests 2>&1 | tail -15`
Expected: FAIL (`designMode`/`setDesignMode` undefined).

- [ ] **Step 3: Implement the state + setter, and clear design in the others**

Add near the other mode fields:
```swift
    @Published var designMode: Bool = false
    func setDesignMode(_ on: Bool) {
        if on { interactionMode = .viewing; measureMode = nil }
        designMode = on
    }
```
Then, inside the existing `setInteractionMode(_:)` and `setMeasureMode(_:)` bodies, add `designMode = false` when turning those on (mirror how they already clear each other, `:1929-1972`).

- [ ] **Step 4: Run the test, verify it passes**

Run the Step-2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/DesignModeStateTests.swift
git commit -m "feat(design): PyMOLEngine.designMode with mode mutual exclusion"
```

---

### Task 10: UI wiring — overlay, toolbar/menu entry, click-to-focus, engine plumbing

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` — add `designOverlay` (model on `measureOverlay` `:2859-2962`); insert into the overlay chains (`:547-549`); add a toolbar item (model on `macMoveToolbar` `:2575`).
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLApp.swift` — add a Design `CommandMenu` item (model on the Mouse menu `:185-189`).
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — real bridge implementations of the `DesignController` closures (enumerate/score/applyColoring/dim/snapshot/restore) using `runCommand` + `MPNNGate` + the temp-JSON files; wire `currentState` to the engine's displayed state; feed `allObjects`; route a design-mode viewport click to `DesignController.focus`.

**Interfaces:**
- Consumes: everything from Tasks 2–9.
- Produces: a working macOS Design mode (no new public types).

- [ ] **Step 1: Add the real DesignController wiring on PyMOLEngine**

Add a lazily-created `designController` on `PyMOLEngine` whose closures call the Python helpers via `runCommand` and read the temp JSON. Enumerate example:
```swift
#if RAYMOL_MPNN
    lazy var designController: DesignController = DesignController(
        enumerate: { [weak self] obj, state in
            self?.runCommand("from pymol import raymol_design; raymol_design.enumerate_design_residues('\(obj)', \(state))")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("raymol_design_residues.json")
            return try DesignResidueSet.parse(jsonAt: url)
        },
        score: { residues, native in
            guard let url = MPNNGate.packURL else { throw NSError(domain: "design", code: 1) }
            let model = try MPNNModel(packDirectory: url)        // cached: hoist to a stored lazy in impl
            return try model.score(residues, sequence: native, mode: .leaveOneOut, seed: 0)
        },
        applyColoring: { [weak self] obj, values, palette, lo, hi in
            let rows = values.map { ["chain": $0.0, "resi": $0.1, "value": $0.2 as Any] }
            let data = try? JSONSerialization.data(withJSONObject: rows)
            let p = FileManager.default.temporaryDirectory.appendingPathComponent("raymol_design_vals.json")
            try? data?.write(to: p)
            self?.runCommand("from pymol import raymol_design; raymol_design.apply_design_coloring('\(obj)', '\(p.path)', '\(palette)', \(lo), \(hi))")
        },
        dim: { [weak self] obj in self?.runCommand("from pymol import raymol_design; raymol_design.dim_object('\(obj)', 'gray70', 0.7)") },
        snapshot: { [weak self] objs in self?.runCommand("from pymol import raymol_design; raymol_design.snapshot_visual_state('\(objs.joined(separator: ","))')") },
        restore: { [weak self] in self?.runCommand("from pymol import raymol_design; raymol_design.restore_visual_state()") })
#endif
```
Move the `MPNNModel` construction into a stored `lazy var mpnnModel` inside the controller impl so it loads once (per Global Constraints). Populate `designController.allObjects` from the engine's object list when entering the mode.

- [ ] **Step 2: Add `designOverlay` + toolbar + menu**

In `ContentView.swift` add a computed `designOverlay` (split into small subviews per the type-checker constraint) showing: the focus-object name (or "Click an object to design"), a `Picker`/segmented control bound to `engine.designController.colorMeaning` (`nativeFit`/`certainty`) calling `setMeaning`, a `DesignLegend` gradient bar reading `legendDomain`, and a `ProgressView` when `isScoring`. Insert `else if engine.designMode { designOverlay }` into the overlay chains (`:547-549`). Add a macOS toolbar toggle (model on `macMoveToolbar`) calling `engine.setDesignMode(!engine.designMode)`, and on enable call `engine.designController.enter()`, on disable `engine.designController.exit()`. Add the `CommandMenu` item in `PyMOLApp.swift`.

- [ ] **Step 3: Route design-mode viewport click to focus**

Where `longPressPick`/right-click currently produce a `LongPressHit` (`PyMOLEngine.swift:2231`), add: if `designMode` and the gesture was a click (not a drag — reuse the Move-mode `moveDragSlop` dead-zone), call `designController.focus(hit.object)` instead of the confirmation dialog.

- [ ] **Step 4: Build macOS**

Run: `cd swiftui && ./build_macos.sh && xcodegen generate && xcodebuild -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Build iOS (regression)**

Run: `xcodebuild -project PyMOLViewer.xcodeproj -scheme RayMol -destination 'generic/platform=iOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED, no MPNN symbols (gate + platform filter hold).

- [ ] **Step 6: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift swiftui/PyMOLViewer/Shared/PyMOLApp.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(design): Design mode UI — overlay, toolbar/menu, click-to-focus, engine wiring"
```

---

### Task 11: End-to-end functional verification

**Files:**
- Test: none new (manual/functional). Optionally add `testing/tests/raymol/design_smoke.py` if a headless path is feasible.

**Interfaces:**
- Consumes: the whole feature.

- [ ] **Step 1: Host inference smoke (real model)**

On the host, run the macOS app (or a small `swift` harness) and confirm `MPNNGate.canLoadModel()` is true and a `score(.leaveOneOut)` on a loaded small PDB returns finite `currentAALogProb`. Expected: loads, returns finite values.

- [ ] **Step 2: Functional UX (mac-vm-test / host)**

Drive the built app (mac-vm-test skill, or host with MCP live-capture for the UX-only parts): load two objects; enter Design mode → confirm the non-focus object goes semitransparent gray and the focus object is colored; click the other object → focus swaps, colors/gray swap; toggle native-fit ⇄ certainty → recolors instantly (no spinner second time = cache hit); exit mode → both objects return to exact pre-mode colors + transparency. Because the VM GPU can't run mlx, do the coloring/inference leg on the host; the dim/refocus/restore UX can be exercised in the VM with a stubbed score.
Expected: each behavior matches §1 success criteria.

- [ ] **Step 3: Run the full RayMol Python test suite (regression)**

Run: `pymol -ckqy testing/testing.py --run tests/raymol/design_enumerate.py` and the other `tests/raymol/design_*.py`; plus the existing appkit suite.
Expected: all pass.

- [ ] **Step 4: Commit any fixes + final verification note**

```bash
git add -A && git commit -m "test(design): end-to-end functional verification notes + fixes"
```

---

## Self-Review

- **Spec coverage:** §1 scope → Tasks 9–11; §2 infra → Tasks 1–2; §3 off-main path → Task 8; §4 coloring/meanings → Tasks 6, 10; §5 mode/click-to-focus → Tasks 9–10; §6 save/restore → Task 7; §7 cache → Tasks 5, 8; §8 edge cases → Tasks 3 (mask), 4 (chain/resi/state), 6 (domain), 8 (errorText/token); §9 testing → Tasks 3–9 unit + 11 functional; §10 non-goals honored (read-only, macOS-only gate). No gaps.
- **Type consistency:** `MPNNModel.Residue`, `ScoreResult{logProbs,currentAALogProb}`, `DesignResidueSet{validResidues,nativeSequence,sequenceHash}`, `DesignScores{nativeFit,certainty}`, `DesignCacheKey{object,state,sequenceHash}`, `DesignColorMeaning{nativeFit,certainty}`, `DesignController` closures — used identically across Tasks 4–10.
- **Open risks flagged for execution:** (a) `spectrum minimum/maximum` kwargs may not exist on this build (Task 6 Step 7 has a fallback); (b) `ScoreResult` public memberwise init needed for Task 8's test (add to the package if missing); (c) exact `PyMOLEngine` enum cases/singleton accessor and `ContentView` insertion anchors must be confirmed against the real files during execution (line refs are from the recon and may drift).
</content>
