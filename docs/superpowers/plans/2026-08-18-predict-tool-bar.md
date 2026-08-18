# Predict Tool Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS "Predict" interaction tool — a Tools-menu entry that raises a docked bar under the alignment for starting structure-prediction jobs (input, model, per-chain MSA, number of models), mirroring the existing Design tool.

**Architecture:** A new exclusive interaction mode (`predictMode`) on `PyMOLEngine`, a `PredictController` (ObservableObject) that composes `cmd.predict`/`cmd.msa_search` calls and drives a search-then-auto-predict state machine off the engine's already-published `alignments`/`msaSearches`, a `PredictBar` SwiftUI view docked where the Design bar docks, and a Python helper `appkit_predict.emit()` that writes the available predictors and the input's chains to a tempfile (the same tempfile-JSON contract the object panel uses). There is no Python→Swift call path, so Swift drives Python by composing command strings via `runPython` and reads structured data back from tempfile JSON.

**Tech Stack:** Swift / SwiftUI / Combine (macOS), XCTest; Python 3 (PyMOL module layer), `pymol.testing` unittest runner.

**Spec:** `docs/superpowers/specs/2026-08-18-predict-tool-bar-design.md`

## Global Constraints

- **Platform:** macOS only. All new Swift symbols are wrapped `#if os(macOS)` (prediction is compiled `#if os(macOS)`; there is no iOS predict backend).
- **No Python→Swift call path.** Swift issues work as command strings via `PyMOLEngine.runPython(_:)` and reads results from tempfiles named `pymol_<name>_<pid>.json` where the pid is `os.getpid()` on the Python side and `ProcessInfo.processInfo.processIdentifier` on the Swift side.
- **Feedback markers** ride a single line; large payloads ride a tempfile (PyMOL's feedback line caps at ~1024 chars). New marker: `PREDICT_FORM:ready` (and `PREDICT_FORM:err:<msg>`).
- **String → Python literal** escaping must match the existing helper: wrap in single quotes, escape `\` → `\\`, `'` → `\'`, strip newlines (see `BoltzJobManager.pythonLiteral` / `ProgressTray.pythonLiteral`).
- **`n_models`** is 1…20 (`pymol.predicting.MAX_MODELS`).
- **MSA support is per-predictor.** A predictor advertises `supports_msa` (boltz2 True, protenix False). The bar disables "Use MSA" when the selected model does not support it.
- **Size guard is per-predictor.** `predictor` id starting with `protenix` → `ProtenixSizeGuard.decide(tokens:availableBytes:)`; otherwise `PredictSizeGuard.decide(tokens:msaDepth:availableBytes:)`. Both return `PredictSizeGuard.Decision`.
- **Mode exclusivity.** Move / Measure / Design / Predict are mutually exclusive; each setter clears the others and `exitActiveInteractionMode()` leaves whichever is active.
- **Build/verify (macOS, per project memory):** two-stage build — build the core FIRST, THEN `xcodebuild` — and name any dev build with a suffix (never plain `RayMol.app`). Functional UI checks run in a disposable VM via the `mac-vm-test` skill.
- **CI:** the embedded-test runner enumerates test files by hand in `.github/workflows/raymol-embedded-tests.yml`; a new Python test file that is not added there never runs.

---

## File Structure

- **Create** `modules/pymol/appkit_predict.py` — `emit(input_str)` writes `pymol_predict_<pid>.json` (`predictors`, `chains`, `error`) and prints `PREDICT_FORM:ready`. One responsibility: feed the Predict bar.
- **Create** `testing/tests/test_appkit_predict.py` — `pymol.testing.PyMOLTestCase` covering `emit` payload for a literal monomer, a `/` multimer, a loaded object (source object/chain populated), and a bad input (error, no throw).
- **Create** `swiftui/PyMOLViewer/Shared/PredictController.swift` — the form model + pure command composition + the search-then-predict state machine. macOS-only.
- **Create** `swiftui/PyMOLViewer/Shared/PredictBar.swift` — the docked SwiftUI form (+ optional `PredictSettingsSheet`). macOS-only.
- **Create** `swiftui/PyMOLViewerTests/PredictControllerTests.swift` — unit tests for composition + state machine.
- **Modify** `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift` — `predictMode`, `setPredictMode`, the `exitActiveInteractionMode` line, clearing lines in the three other setters, the `predictController` lazy var + Combine wiring, `PREDICT_FORM:` routing in `pollFeedback`, and `parsePredictFormFeedback`.
- **Modify** `swiftui/PyMOLViewer/Shared/ContentView.swift` — Predict entry in `interactionToolItems`, `activeInteractionTool`, `toolsMenuHelp`, and the `predictBar` docking slot(s).
- **Modify** `.github/workflows/raymol-embedded-tests.yml` — add the new Python test to the `--run` list.

---

## Task 1: Python helper `appkit_predict.emit`

**Files:**
- Create: `modules/pymol/appkit_predict.py`
- Test: `testing/tests/test_appkit_predict.py`
- Modify: `.github/workflows/raymol-embedded-tests.yml`

**Interfaces:**
- Consumes: `pymol.predictors.registry.available()`/`get()`, `Predictor.supports_msa`; `pymol.predicting.resolve_input(sequence, quiet, _self)` → `(sequence_str, sources)` where `sources` is a list of `(object, chain)` (empty for a literal); `pymol.predictors.base.parse_chains(sequence_str)` → tuple of `(chain_id, seq)`.
- Produces: file `pymol_predict_<pid>.json` with shape
  `{"predictors":[{"id":str,"msa":bool}], "chains":[{"id":str,"length":int,"object":str,"chain":str}], "error":str|null}`
  and stdout line `PREDICT_FORM:ready` (or `PREDICT_FORM:err:<msg>`). Task 4's `parsePredictFormFeedback` decodes this exact shape.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/test_appkit_predict.py`:

```python
"""Tests for pymol.appkit_predict.emit — the Predict tool bar's data feed.

emit(input) writes pymol_predict_<pid>.json with the registered predictors and the
chains of the input, resolved exactly as `predict` resolves it, and prints the
short marker PREDICT_FORM:ready. Same tempfile-JSON contract as
appkit_inspector.poll_panel(): the payload can exceed PyMOL's ~1KB feedback-line
cap, so it must never ride the feedback line.
"""

import json
import os
import tempfile

from pymol import cmd, testing
from pymol import appkit_predict


def _payload():
    p = os.path.join(tempfile.gettempdir(), 'pymol_predict_%d.json' % os.getpid())
    with open(p) as f:
        return json.load(f)


class TestAppkitPredict(testing.PyMOLTestCase):

    def setUp(self):
        cmd.reinitialize()

    def test_predictors_are_listed_with_msa_capability(self):
        appkit_predict.emit('')
        payload = _payload()
        ids = [p['id'] for p in payload['predictors']]
        self.assertIn('boltz2', ids)
        boltz = next(p for p in payload['predictors'] if p['id'] == 'boltz2')
        self.assertTrue(boltz['msa'])
        self.assertEqual(payload['chains'], [])
        self.assertIsNone(payload['error'])

    def test_literal_monomer_resolves_to_one_chain(self):
        appkit_predict.emit('MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ')
        payload = _payload()
        self.assertEqual(len(payload['chains']), 1)
        c = payload['chains'][0]
        self.assertEqual(c['id'], 'A')
        self.assertEqual(c['length'], 33)
        self.assertEqual(c['object'], '')   # a literal has no source object
        self.assertEqual(c['chain'], '')

    def test_literal_multimer_splits_on_slash(self):
        appkit_predict.emit('MKTAY/GSHMA')
        payload = _payload()
        self.assertEqual([c['id'] for c in payload['chains']], ['A', 'B'])
        self.assertEqual([c['length'] for c in payload['chains']], [5, 5])

    def test_object_input_carries_source_object_and_chain(self):
        cmd.fab('ACDEFG', 'obj1')          # a 6-residue chain-A object
        appkit_predict.emit('obj1')
        payload = _payload()
        self.assertEqual(len(payload['chains']), 1)
        c = payload['chains'][0]
        self.assertEqual(c['object'], 'obj1')
        self.assertEqual(c['chain'], 'A')
        self.assertEqual(c['length'], 6)

    def test_bad_input_is_an_error_not_a_throw(self):
        appkit_predict.emit('not a real selection @@@')
        payload = _payload()
        self.assertEqual(payload['chains'], [])
        self.assertIsNotNone(payload['error'])
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
pymol -ckqy testing/testing.py --run testing/tests/test_appkit_predict.py
```
Expected: FAIL — `ModuleNotFoundError: No module named 'pymol.appkit_predict'`.

- [ ] **Step 3: Write minimal implementation**

Create `modules/pymol/appkit_predict.py`:

```python
"""Feed the macOS Predict tool bar: the registered predictors, and the chains of
an input resolved exactly as `predict` resolves it.

RayMol has no Python->Swift call path, so the bar cannot ask a function for these
values; it triggers `emit(input)` over runPython and reads the JSON this writes,
exactly as the object panel does with `appkit_inspector.poll_panel()`. The payload
can exceed PyMOL's ~1KB feedback-line cap, so it rides a tempfile and only the
short marker PREDICT_FORM:ready rides the feedback line.
"""

import json
import os
import tempfile

from pymol import cmd


def _predictors():
    """[{'id': str, 'msa': bool}] for every registered predictor, sorted by id.

    `msa` is the method's own `supports_msa`: the bar disables the MSA controls for
    a method (e.g. protenix) that would refuse an alignment.
    """
    from pymol.predictors import registry
    out = []
    for pid in registry.available():
        try:
            p = registry.get(pid)
            supports = bool(getattr(p, 'supports_msa', False))
        except Exception:
            supports = False
        out.append({'id': pid, 'msa': supports})
    return out


def _chains(input_str):
    """([{'id','length','object','chain'}], error).

    Resolved through `predict`'s own resolver so the bar shows exactly what would be
    folded, down to how modified residues are substituted. `object`/`chain` are the
    source (object, chain id) each chain was read from -- empty for a literal
    sequence, which has no provenance. Never raises: a bad input is a message in the
    bar, not a crash in the poll (a throw would also leave a stale/zero-byte file).
    """
    text = (input_str or '').strip()
    if not text:
        return [], None
    try:
        from pymol.predicting import resolve_input
        from pymol.predictors.base import parse_chains
        sequence, sources = resolve_input(text, quiet=1, _self=cmd)
        chains = parse_chains(sequence)
        out = []
        for i, (cid, seq) in enumerate(chains):
            obj, chn = (sources[i] if i < len(sources) else ('', ''))
            out.append({'id': cid, 'length': len(seq),
                        'object': obj or '', 'chain': chn or ''})
        return out, None
    except Exception as exc:
        return [], str(exc)


def emit(input_str=''):
    """Write pymol_predict_<pid>.json and print PREDICT_FORM:ready.

    Serialise BEFORE opening the file: open(..., 'w') truncates immediately, so a
    dumps() failure inside the `with` would leave a zero-byte file -- worse than a
    stale one. A process-local filename keeps multiple RayMol windows from
    overwriting each other's payload.
    """
    chains, error = _chains(input_str)
    payload = {'predictors': _predictors(), 'chains': chains, 'error': error}
    try:
        blob = json.dumps(payload)
        p = os.path.join(tempfile.gettempdir(), 'pymol_predict_%d.json' % os.getpid())
        with open(p, 'w') as f:
            f.write(blob)
        print('PREDICT_FORM:ready')
    except Exception as exc:
        print('PREDICT_FORM:err:' + str(exc))
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
pymol -ckqy testing/testing.py --run testing/tests/test_appkit_predict.py
```
Expected: PASS (5 tests). If `cmd.fab` is unavailable in the headless build, replace the object-input test's setup with `cmd.load('testing/data/1oky.pdb', 'obj1')` (any small single-chain PDB in `testing/data/`) and assert on that structure's first chain id and length instead.

- [ ] **Step 5: Add the test to CI**

In `.github/workflows/raymol-embedded-tests.yml`, add this line to the `--run` list (after `test_appkit_ray_overlay.py`):

```yaml
              testing/tests/test_appkit_predict.py \
```

- [ ] **Step 6: Commit**

```bash
git add modules/pymol/appkit_predict.py testing/tests/test_appkit_predict.py .github/workflows/raymol-embedded-tests.yml
git commit -m "feat(predict): appkit_predict.emit feeds the Predict bar (predictors + chains)"
```

---

## Task 2: PredictController pure core (types + command composition)

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/PredictController.swift`
- Test: `swiftui/PyMOLViewerTests/PredictControllerTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by Tasks 3–5): the value types `PredictorInfo`, `PredictChain`, `PredictFormPayload`, `PredictPhase`, `PredictSizeWarning`; and the pure statics `PredictController.pythonLiteral(_:)`, `.predictPython(...)`, `.msaSearchPython(...)`, `.literalChainSequences(_:)`, `.alignmentBaseName(...)`, `.msaSlots(...)`. Exact signatures below.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/PredictControllerTests.swift`:

```swift
#if os(macOS)
import XCTest
@testable import RayMol

final class PredictControllerTests: XCTestCase {

    // MARK: composition

    func testPredictPythonMinimal() {
        let s = PredictController.predictPython(
            predictor: "boltz2", input: "MKTAY", nModels: 1,
            recyclingSteps: 3, diffusionSteps: 200,
            seed: nil, msaDepth: nil, name: nil, msa: nil)
        XCTAssertTrue(s.contains("_c.predict('boltz2', 'MKTAY'"))
        XCTAssertTrue(s.contains("n_models=1"))
        XCTAssertTrue(s.contains("recycling_steps=3"))
        XCTAssertTrue(s.contains("diffusion_steps=200"))
        XCTAssertFalse(s.contains("seed="))       // omitted → fresh per run
        XCTAssertFalse(s.contains("msa_depth="))
        XCTAssertFalse(s.contains("name="))
        XCTAssertFalse(s.contains("msa="))
    }

    func testPredictPythonEscapesSelectionAndAddsOptions() {
        let s = PredictController.predictPython(
            predictor: "boltz2", input: "1ubq and chain A", nModels: 5,
            recyclingSteps: 3, diffusionSteps: 300,
            seed: 42, msaDepth: 256, name: "my pred", msa: "alnA//alnC")
        XCTAssertTrue(s.contains("_c.predict('boltz2', '1ubq and chain A'"))
        XCTAssertTrue(s.contains("n_models=5"))
        XCTAssertTrue(s.contains("diffusion_steps=300"))
        XCTAssertTrue(s.contains("seed=42"))
        XCTAssertTrue(s.contains("msa_depth=256"))
        XCTAssertTrue(s.contains("name='my pred'"))
        XCTAssertTrue(s.contains("msa='alnA//alnC'"))
    }

    func testMsaSearchPythonObjectPath() {
        let s = PredictController.msaSearchPython(
            sequence: "1ubq and chain A", name: "predui_x", target: "1ubq",
            chain: "A", mode: "env", server: "")
        XCTAssertTrue(s.contains("_c.msa_search('1ubq and chain A'"))
        XCTAssertTrue(s.contains("name='predui_x'"))
        XCTAssertTrue(s.contains("target='1ubq'"))
        XCTAssertTrue(s.contains("chain='A'"))
        XCTAssertTrue(s.contains("mode='env'"))
        XCTAssertFalse(s.contains("server="))     // blank → use the setting/default
    }

    func testMsaSearchPythonLiteralPathHasNoTarget() {
        let s = PredictController.msaSearchPython(
            sequence: "MKTAY", name: "predui_y", target: "", chain: "",
            mode: "all", server: "https://msa.internal")
        XCTAssertTrue(s.contains("_c.msa_search('MKTAY'"))
        XCTAssertTrue(s.contains("name='predui_y'"))
        XCTAssertFalse(s.contains("target="))
        XCTAssertFalse(s.contains("chain="))
        XCTAssertTrue(s.contains("mode='all'"))
        XCTAssertTrue(s.contains("server='https://msa.internal'"))
    }

    func testLiteralChainSequencesSplitStripUpper() {
        XCTAssertEqual(PredictController.literalChainSequences(" mkt ay / gshma "),
                       ["MKTAY", "GSHMA"])
    }

    func testMsaSlotsOrderedWithEmptyForUnselected() {
        let chains = [
            PredictChain(id: "A", length: 5, object: "", chain: ""),
            PredictChain(id: "B", length: 5, object: "", chain: ""),
            PredictChain(id: "C", length: 5, object: "", chain: ""),
        ]
        let slots = PredictController.msaSlots(
            orderedChains: chains,
            requested: ["A", "C"],
            nameFor: { "aln\($0.id)" })
        XCTAssertEqual(slots, "alnA//alnC")
    }

    func testFormPayloadDecodes() throws {
        let json = """
        {"predictors":[{"id":"boltz2","msa":true},{"id":"protenix","msa":false}],
         "chains":[{"id":"A","length":129,"object":"1ubq","chain":"A"}],
         "error":null}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(PredictFormPayload.self, from: json)
        XCTAssertEqual(payload.predictors.map(\.id), ["boltz2", "protenix"])
        XCTAssertFalse(payload.predictors[1].msa)
        XCTAssertEqual(payload.chains.first?.length, 129)
        XCTAssertTrue(payload.chains.first!.isFromObject)
        XCTAssertNil(payload.error)
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `swiftui/`):
```bash
xcodebuild test -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/PredictControllerTests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'PredictController' in scope` / unknown types.

- [ ] **Step 3: Write minimal implementation**

Create `swiftui/PyMOLViewer/Shared/PredictController.swift`:

```swift
#if os(macOS)
import Foundation

// MARK: - Wire types (decoded from pymol_predict_<pid>.json; see appkit_predict.emit)

struct PredictorInfo: Codable, Equatable, Identifiable {
    let id: String
    let msa: Bool          // supports_msa: the method can genuinely use an alignment
}

struct PredictChain: Codable, Equatable, Identifiable {
    let id: String         // spec chain id assigned in order: A, B, C, ...
    let length: Int
    let object: String     // source object, "" for a literal sequence
    let chain: String      // source chain id, "" for a literal sequence
    var isFromObject: Bool { !object.isEmpty }
}

struct PredictFormPayload: Codable, Equatable {
    let predictors: [PredictorInfo]
    let chains: [PredictChain]
    let error: String?
}

enum PredictPhase: Equatable {
    case idle
    case searching(remaining: Int)
    case predicting
    case error(String)
}

struct PredictSizeWarning: Equatable {
    let estimatedBytes: Int
    let availableBytes: Int
}

// MARK: - Pure command composition (unit-tested without an engine)

extension PredictController {

    /// A Python single-quoted string literal. Matches BoltzJobManager.pythonLiteral.
    static func pythonLiteral(_ value: String) -> String {
        "'" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "") + "'"
    }

    /// `from pymol import cmd as _c\n_c.predict(...)`. Optional args are omitted when
    /// nil so predict applies its own defaults (notably: no seed → a fresh seed per
    /// run). `msa` is passed only on the literal-sequence path; object inputs let
    /// predict pick up attached alignments.
    static func predictPython(predictor: String, input: String, nModels: Int,
                              recyclingSteps: Int, diffusionSteps: Int,
                              seed: Int?, msaDepth: Int?, name: String?,
                              msa: String?) -> String {
        var args = ["\(pythonLiteral(predictor)), \(pythonLiteral(input))"]
        args.append("n_models=\(nModels)")
        args.append("recycling_steps=\(recyclingSteps)")
        args.append("diffusion_steps=\(diffusionSteps)")
        if let seed { args.append("seed=\(seed)") }
        if let msaDepth { args.append("msa_depth=\(msaDepth)") }
        if let name, !name.isEmpty { args.append("name=\(pythonLiteral(name))") }
        if let msa, !msa.isEmpty { args.append("msa=\(pythonLiteral(msa))") }
        return "from pymol import cmd as _c\n_c.predict(\(args.joined(separator: ", ")))"
    }

    /// `_c.msa_search(...)`. `target`/`chain` are passed only when non-empty (the
    /// object path); a literal sequence lands the alignment unattached under `name`.
    static func msaSearchPython(sequence: String, name: String, target: String,
                                chain: String, mode: String, server: String) -> String {
        var args = ["\(pythonLiteral(sequence))"]
        args.append("name=\(pythonLiteral(name))")
        if !target.isEmpty { args.append("target=\(pythonLiteral(target))") }
        if !chain.isEmpty { args.append("chain=\(pythonLiteral(chain))") }
        args.append("mode=\(pythonLiteral(mode))")
        if !server.isEmpty { args.append("server=\(pythonLiteral(server))") }
        return "from pymol import cmd as _c\n_c.msa_search(\(args.joined(separator: ", ")))"
    }

    /// Per-chain sequences of a literal input: split on '/', strip whitespace,
    /// upper-case — exactly what parse_chains does on the Python side.
    static func literalChainSequences(_ input: String) -> [String] {
        input.split(separator: "/").map {
            $0.replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\t", with: "")
                .uppercased()
        }
    }

    /// `msa=` slots: one '/'-joined entry per chain in order, the alignment name for
    /// a requested chain and empty otherwise (empty folds that chain single-sequence).
    static func msaSlots(orderedChains: [PredictChain], requested: Set<String>,
                         nameFor: (PredictChain) -> String) -> String {
        orderedChains.map { requested.contains($0.id) ? nameFor($0) : "" }
            .joined(separator: "/")
    }

    /// A deterministic, collision-resistant alignment name for a requested chain, so
    /// the running search and the landed alignment share a name the state machine can
    /// match on. Object path keys on (object, source chain); literal path on an FNV
    /// hash of the chain's sequence so a re-run reuses the cached alignment.
    static func alignmentBaseName(for chain: PredictChain,
                                  literalSequence: String?) -> String {
        if chain.isFromObject {
            let obj = sanitize(chain.object)
            let ch = chain.chain.isEmpty ? "x" : sanitize(chain.chain)
            return "predui_\(obj)_\(ch)"
        }
        let seq = literalSequence ?? ""
        return "predui_\(fnvHex(seq))_\(chain.id)"
    }

    static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    /// FNV-1a 32-bit, hex. A fixed hash (not Swift's randomized Hasher) so the name is
    /// stable across launches and a re-run hits msa_search's on-disk cache.
    static func fnvHex(_ s: String) -> String {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return String(format: "%08x", h)
    }
}
```

Then add the class shell (the stored/published state and injected seams filled in Task 3, so this file compiles now):

```swift
import Combine

@MainActor
final class PredictController: ObservableObject {
    // Inputs (bound by PredictBar)
    @Published var inputText = ""
    @Published var predictor = ""
    @Published var useMSA = false
    @Published var msaChains: Set<String> = []
    @Published var nModels = 1
    // Advanced
    @Published var recyclingSteps = 3
    @Published var diffusionSteps = 200
    @Published var seedText = ""        // empty → omit (fresh per run)
    @Published var msaDepthText = ""    // empty → omit (predictor default)
    @Published var msaMode = "env"
    @Published var resultName = ""
    @Published var server = ""

    // Resolved / status (rendered by PredictBar)
    @Published var availablePredictors: [PredictorInfo] = []
    @Published var chains: [PredictChain] = []
    @Published var resolveError: String?
    @Published var phase: PredictPhase = .idle
    @Published var pendingSizeWarning: PredictSizeWarning?

    // Injected seams (default no-ops; PyMOLEngine wires real ones in Task 4).
    var runPythonSeam: (String) -> Void = { _ in }
    var refreshTrigger: (String) -> Void = { _ in }
    var availableBytesProvider: () -> Int = { PredictSizeGuard.availableBytes }

    // Filled in Task 3.
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/PredictControllerTests 2>&1 | tail -20
```
Expected: PASS (all composition tests). The `PredictController` class has no behavior yet — that's fine; these tests hit only the statics and the Codable types.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PredictController.swift swiftui/PyMOLViewerTests/PredictControllerTests.swift
git commit -m "feat(predict): PredictController value types + pure command composition"
```

---

## Task 3: PredictController orchestration (run + search-then-predict state machine)

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PredictController.swift`
- Test: `swiftui/PyMOLViewerTests/PredictControllerTests.swift`

**Interfaces:**
- Consumes: the value types + statics from Task 2; `AlignmentEntry` (`name`,`target`,`chain`) and `MSASearchEntry` (`name`) from `Panels/ObjectPanel.swift`; `PredictSizeGuard`/`ProtenixSizeGuard`.
- Produces (used by Tasks 4–5): instance methods `refresh()`, `loadFormPayload(_ payload:)`, `run()`, `confirmPendingWarning()`, `cancelPendingWarning()`, `cancel()`, and `onEngineState(alignments:searches:)`. The engine calls `loadFormPayload` after reading the tempfile and `onEngineState` from a Combine sink; the bar calls `refresh`/`run`/`cancel`/confirm.

- [ ] **Step 1: Write the failing test**

Append to `PredictControllerTests.swift` (inside the `#if os(macOS)` block):

```swift
@MainActor
final class PredictControllerRunTests: XCTestCase {

    private let gib = 1024 * 1024 * 1024

    private func makeController(captured: NSMutableArray) -> PredictController {
        let c = PredictController()
        c.runPythonSeam = { captured.add($0) }
        c.availableBytesProvider = { 64 * (1024 * 1024 * 1024) }  // never warns
        return c
    }

    private func chain(_ id: String, _ len: Int, obj: String = "", ch: String = "")
        -> PredictChain { PredictChain(id: id, length: len, object: obj, chain: ch) }

    func testRunWithoutMSASubmitsPredictImmediately() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 30)], error: nil))
        c.inputText = "MKTAY"
        c.predictor = "boltz2"
        c.nModels = 3
        c.run()
        XCTAssertEqual(c.phase, .predicting)
        XCTAssertEqual(cmds.count, 1)
        let sent = cmds[0] as! String
        XCTAssertTrue(sent.contains("_c.predict('boltz2', 'MKTAY'"))
        XCTAssertTrue(sent.contains("n_models=3"))
    }

    func testRunWithMSAObjectPathStartsSearchesThenPredicts() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"
        c.predictor = "boltz2"
        c.useMSA = true
        c.msaChains = ["A"]
        c.run()

        // A search started; not predicting yet. The search is chain-SCOPED —
        // msa_search refuses a complex, so per-chain scoping is required even for a
        // single-chain object.
        XCTAssertEqual(c.phase, .searching(remaining: 1))
        XCTAssertEqual(cmds.count, 1)
        XCTAssertTrue((cmds[0] as! String).contains("_c.msa_search('(1ubq) and chain A'"))
        XCTAssertTrue((cmds[0] as! String).contains("target='1ubq'"))
        XCTAssertTrue((cmds[0] as! String).contains("chain='A'"))

        // The alignment lands (name matches predui_1ubq_A, attached to 1ubq/A).
        let landed = AlignmentEntry(id: "aln", name: "predui_1ubq_A", depth: 8,
                                    columns: 60, residues: 60, target: "1ubq", chain: "A")
        c.onEngineState(alignments: [landed], searches: [])

        XCTAssertEqual(c.phase, .predicting)
        XCTAssertEqual(cmds.count, 2)
        // Object path: predict does NOT carry an msa= arg (auto-attach).
        XCTAssertFalse((cmds[1] as! String).contains("msa="))
        XCTAssertTrue((cmds[1] as! String).contains("_c.predict('boltz2', '1ubq'"))
    }

    func testMSALiteralPathPassesSlots() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 5), chain("B", 5)], error: nil))
        c.inputText = "MKTAY/GSHMA"
        c.predictor = "boltz2"
        c.useMSA = true
        c.msaChains = ["A"]              // only chain A gets an MSA
        c.run()
        XCTAssertEqual(c.phase, .searching(remaining: 1))
        let name = PredictController.alignmentBaseName(
            for: c.chains[0], literalSequence: "MKTAY")
        let landed = AlignmentEntry(id: "aln", name: name, depth: 4, columns: 5,
                                    residues: 5, target: "", chain: "")
        c.onEngineState(alignments: [landed], searches: [])
        XCTAssertEqual(c.phase, .predicting)
        XCTAssertTrue((cmds.lastObject as! String).contains("msa='\(name)/'"))  // B empty
    }

    func testSearchThatVanishesWithoutLandingIsAnError() {
        let cmds = NSMutableArray()
        let c = makeController(captured: cmds)
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 60, obj: "1ubq", ch: "A")], error: nil))
        c.inputText = "1ubq"; c.predictor = "boltz2"; c.useMSA = true; c.msaChains = ["A"]
        c.run()
        // No alignment, and no running search with the planned name → it failed/cancelled.
        c.onEngineState(alignments: [], searches: [])
        guard case .error = c.phase else { return XCTFail("expected error phase") }
        XCTAssertEqual(cmds.count, 1)   // predict was never submitted
    }

    func testOversizeRaisesWarningNotSubmit() {
        let cmds = NSMutableArray()
        let c = PredictController()
        c.runPythonSeam = { cmds.add($0) }
        c.availableBytesProvider = { 4 * (1024 * 1024 * 1024) }  // small machine
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true)],
            chains: [chain("A", 500)], error: nil))
        c.inputText = "…500 residues…"; c.predictor = "boltz2"
        c.run()
        XCTAssertNotNil(c.pendingSizeWarning)
        XCTAssertEqual(cmds.count, 0)          // nothing submitted yet
        c.confirmPendingWarning()
        XCTAssertNil(c.pendingSizeWarning)
        XCTAssertEqual(c.phase, .predicting)
        XCTAssertEqual(cmds.count, 1)
    }

    func testPredictorSelectionDefaultsToFirst() {
        let c = PredictController()
        c.loadFormPayload(PredictFormPayload(
            predictors: [PredictorInfo(id: "boltz2", msa: true),
                         PredictorInfo(id: "protenix", msa: false)],
            chains: [], error: nil))
        XCTAssertEqual(c.predictor, "boltz2")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild test -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/PredictControllerRunTests 2>&1 | tail -20
```
Expected: FAIL — `value of type 'PredictController' has no member 'run'` (etc.).

- [ ] **Step 3: Write minimal implementation**

Replace the `// Filled in Task 3.` comment in `PredictController.swift` with the behavior. Add this inside the class:

```swift
    // Per-run plan: the alignment name expected for each requested spec-chain id.
    private var plannedNames: [String: String] = [:]

    // MARK: entering the mode / input changes

    /// Load predictors (input-independent) and clear the form's resolved state.
    func refresh() {
        chains = []
        msaChains = []
        resolveError = nil
        phase = .idle
        pendingSizeWarning = nil
        refreshTrigger("")          // emit('') → predictors only
    }

    /// Re-resolve the current input (called debounced by PredictBar on inputText edits).
    func inputChanged() { refreshTrigger(inputText) }

    /// Apply a decoded pymol_predict_<pid>.json payload.
    func loadFormPayload(_ payload: PredictFormPayload) {
        availablePredictors = payload.predictors
        if predictor.isEmpty || !payload.predictors.contains(where: { $0.id == predictor }) {
            predictor = payload.predictors.first?.id ?? ""
        }
        chains = payload.chains
        resolveError = payload.error
        // Drop any selected MSA chains that no longer exist in the resolved input.
        let ids = Set(payload.chains.map(\.id))
        msaChains = msaChains.intersection(ids)
    }

    // MARK: run

    private var selectedSupportsMSA: Bool {
        availablePredictors.first { $0.id == predictor }?.msa ?? false
    }

    private var tokenCount: Int { chains.reduce(0) { $0 + $1.length } }

    private var effectiveMSADepth: Int {
        if let d = Int(msaDepthText), d > 0 { return d }
        return (useMSA && selectedSupportsMSA && !msaChains.isEmpty)
            ? PredictSizeGuard.maximumMSADepth : 1
    }

    func run() {
        guard !predictor.isEmpty, !chains.isEmpty else {
            phase = .error(resolveError ?? "Nothing to fold — enter a sequence, "
                           + "selection, or object.")
            return
        }
        // Size guard (per predictor). A warn stops for confirmation; a refusal is fatal.
        let decision = predictor.hasPrefix("protenix")
            ? ProtenixSizeGuard.decide(tokens: tokenCount,
                                       availableBytes: availableBytesProvider())
            : PredictSizeGuard.decide(tokens: tokenCount, msaDepth: effectiveMSADepth,
                                      availableBytes: availableBytesProvider())
        switch decision {
        case .ok:
            proceed()
        case let .warn(estimatedBytes, availableBytes):
            pendingSizeWarning = PredictSizeWarning(estimatedBytes: estimatedBytes,
                                                    availableBytes: availableBytes)
        case let .refuse(maxFittingTokens):
            phase = .error("Too large for this machine — at most about "
                           + "\(maxFittingTokens) residues fit.")
        case let .refuseDepth(maxFittingDepth):
            phase = .error("The alignment is too deep for this machine — set "
                           + "msa_depth to at most \(maxFittingDepth).")
        }
    }

    func confirmPendingWarning() { pendingSizeWarning = nil; proceed() }
    func cancelPendingWarning() { pendingSizeWarning = nil; phase = .idle }

    private var useMSAEffective: Bool {
        useMSA && selectedSupportsMSA && !msaChains.isEmpty
    }

    private func proceed() {
        pendingSizeWarning = nil
        guard useMSAEffective else { submitPredict(); return }

        // Plan one alignment name per requested chain; start a search for each that is
        // not already satisfied (object chain already attached, or literal alignment
        // already present is handled on the next onEngineState tick).
        plannedNames = [:]
        let literalSeqs = PredictController.literalChainSequences(inputText)
        var started = 0
        for ch in chains where msaChains.contains(ch.id) {
            let literal = ch.isFromObject ? nil
                : (indexOf(ch).map { $0 < literalSeqs.count ? literalSeqs[$0] : "" } ?? "")
            let name = PredictController.alignmentBaseName(for: ch, literalSequence: literal)
            plannedNames[ch.id] = name
            let sequence = ch.isFromObject
                ? "(\(inputText)) and chain \(ch.chain)"
                : (literal ?? "")
            let cmd = PredictController.msaSearchPython(
                sequence: sequence, name: name,
                target: ch.isFromObject ? ch.object : "",
                chain: ch.isFromObject ? ch.chain : "",
                mode: msaMode, server: server)
            runPythonSeam(cmd)
            started += 1
        }
        phase = .searching(remaining: started)
    }

    private func indexOf(_ ch: PredictChain) -> Int? {
        chains.firstIndex(where: { $0.id == ch.id })
    }

    /// Called from the engine's 500 ms alignment/search poll. Advances or completes
    /// the search-then-predict pipeline.
    func onEngineState(alignments: [AlignmentEntry], searches: [MSASearchEntry]) {
        guard case .searching = phase else { return }
        let searchNames = Set(searches.map(\.name))
        var remaining: [String] = []
        var failed: [String] = []
        for ch in chains where msaChains.contains(ch.id) {
            if isSatisfied(ch, alignments: alignments) { continue }
            let name = plannedNames[ch.id] ?? ""
            if searchNames.contains(name) { remaining.append(ch.id) }  // still running
            else { failed.append(ch.id) }                              // gone, no result
        }
        if !failed.isEmpty {
            phase = .error("MSA search did not complete for chain(s) "
                           + failed.sorted().joined(separator: ", ") + ".")
            return
        }
        if remaining.isEmpty { submitPredict() }
        else { phase = .searching(remaining: remaining.count) }
    }

    /// A requested chain is satisfied once its alignment exists. Object chains match on
    /// attachment to (object, source chain) — which also reuses an alignment the user
    /// attached earlier; literal chains match on the planned alignment name.
    private func isSatisfied(_ ch: PredictChain, alignments: [AlignmentEntry]) -> Bool {
        if ch.isFromObject {
            return alignments.contains { $0.target == ch.object && $0.chain == ch.chain }
        }
        let name = plannedNames[ch.id] ?? ""
        return alignments.contains { $0.name == name }
    }

    private func submitPredict() {
        let seed = Int(seedText)
        let depth = Int(msaDepthText)
        // msa= slots only for the literal path; object inputs auto-use attachments.
        var slots: String? = nil
        if useMSAEffective, let first = chains.first, !first.isFromObject {
            slots = PredictController.msaSlots(
                orderedChains: chains, requested: msaChains,
                nameFor: { plannedNames[$0.id] ?? "" })
        }
        let cmd = PredictController.predictPython(
            predictor: predictor, input: inputText, nModels: nModels,
            recyclingSteps: recyclingSteps, diffusionSteps: diffusionSteps,
            seed: seed, msaDepth: depth,
            name: resultName.isEmpty ? nil : resultName, msa: slots)
        runPythonSeam(cmd)
        phase = .predicting
    }

    func cancel() {
        for name in plannedNames.values {
            runPythonSeam("from pymol import cmd as _c\n_c.msa_cancel(\(PredictController.pythonLiteral(name)))")
        }
        plannedNames = [:]
        phase = .idle
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild test -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/PredictControllerRunTests 2>&1 | tail -30
```
Expected: PASS. If `.searching(remaining:)` equality trips on associated values, confirm `PredictPhase` derives `Equatable` (it does in Task 2).

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PredictController.swift swiftui/PyMOLViewerTests/PredictControllerTests.swift
git commit -m "feat(predict): PredictController run + search-then-predict state machine"
```

---

## Task 4: Engine wiring — predict mode, controller ownership, feedback routing

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`

**Interfaces:**
- Consumes: `PredictController` (Task 3), `runPython`, published `alignments`/`msaSearches`.
- Produces (used by Task 5): `@Published var predictMode: Bool`, `func setPredictMode(_:)`, `var predictController: PredictController`. The `PREDICT_FORM:` marker is routed to `parsePredictFormFeedback`.

- [ ] **Step 1: Add the published flag and the setter (with exclusivity)**

Near `@Published var designMode` (line ~209) add:

```swift
    // Predict tool (macOS): an exclusive interaction mode like Move/Measure/Design,
    // but its "bar" is a form that composes cmd.predict rather than a viewport tool.
    #if os(macOS)
    @Published var predictMode: Bool = false
    #endif
```

After `setDesignMode(_:)` (line ~2184) add:

```swift
    #if os(macOS)
    /// Enter/leave Predict mode. Exclusive with Move/Measure/Design, matching
    /// setDesignMode's entering-branch clears. On entry, refresh the form (loads the
    /// predictor list); on exit, reset any in-flight search/predict tracking.
    func setPredictMode(_ on: Bool) {
        if on {
            if interactionMode == .move { setInteractionMode(.viewing) }
            if measureMode != nil { setMeasureMode(nil) }
            setDesignMode(false)
            predictMode = true
            predictController.refresh()
        } else {
            predictMode = false
        }
    }
    #endif
```

- [ ] **Step 2: Clear predict mode from the other setters and from exit-all**

In `setInteractionMode(_:)` `if mode == .move {` branch (after line ~2499 `setDesignMode(false)`), add:
```swift
            #if os(macOS)
            setPredictMode(false)   // mutually exclusive
            #endif
```
In `setMeasureMode(_:)` `if let k = k {` branch (after line ~2081 `setDesignMode(false)`), add:
```swift
            #if os(macOS)
            setPredictMode(false)   // mutually exclusive
            #endif
```
In `setDesignMode(_:)` `if on {` branch (after line ~2181 `if measureMode != nil { setMeasureMode(nil) }`), add:
```swift
            #if os(macOS)
            setPredictMode(false)   // mutually exclusive
            #endif
```
In `exitActiveInteractionMode()` (after line ~2212 `if measureMode != nil { ... }`), add:
```swift
        #if os(macOS)
        if predictMode { setPredictMode(false); exited = exited || !predictMode }
        #endif
```

- [ ] **Step 3: Own the controller and wire its seams + the Combine pipe**

Near the `lazy var designController` (line ~2244) add:

```swift
    #if os(macOS)
    lazy var predictController: PredictController = {
        let pc = PredictController()
        // Compose work as command strings — the only Python direction available.
        pc.runPythonSeam = { [weak self] code in self?.runPython(code) }
        // Trigger the tempfile-JSON feed; PREDICT_FORM:ready routes back below.
        pc.refreshTrigger = { [weak self] input in
            let lit = PredictController.pythonLiteral(input)
            self?.runPython("from pymol import appkit_predict as _ap\n_ap.emit(\(lit))")
        }
        // Drive the search→predict state machine off the object poll's published state.
        self.$alignments
            .combineLatest(self.$msaSearches)
            .sink { [weak pc] aligns, searches in
                pc?.onEngineState(alignments: aligns, searches: searches)
            }
            .store(in: &self.predictCancellables)
        return pc
    }()

    private var predictCancellables = Set<AnyCancellable>()
    #endif
```

(If `import Combine` / a `Set<AnyCancellable>` is not already at file scope, add `import Combine` at the top — grep first; the engine already uses Combine elsewhere.)

- [ ] **Step 4: Route the feedback marker**

In `pollFeedback()` add a branch after the `PREDICT:` branch (line ~3117):

```swift
                } else if line.hasPrefix("PREDICT_FORM:ready") {
                    #if os(macOS)
                    parsePredictFormFeedback()
                    #endif
                } else if line.hasPrefix("PREDICT_FORM:err") {
                    // swallow — a resolve error is already carried in the JSON payload's
                    // `error` field on a normal `ready`; this only fires if the write
                    // itself failed, which the bar surfaces as a stale form.
```

Add the reader (place it near `parseObjectPanelFeedback`, or in PyMOLEngine.swift; it needs the decoder types from PredictController.swift, which are in-module):

```swift
    #if os(macOS)
    func parsePredictFormFeedback() {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("pymol_predict_\(ProcessInfo.processInfo.processIdentifier).json")
        guard let data = FileManager.default.contents(atPath: path),
              let payload = try? JSONDecoder().decode(PredictFormPayload.self, from: data)
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.predictController.loadFormPayload(payload)
        }
    }
    #endif
```

- [ ] **Step 5: Build the core, then the app, then verify it compiles**

Run (two-stage, per project memory — core FIRST):
```bash
cd swiftui && ./build_macos_core.sh && xcodebuild build -scheme RayMol -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: `BUILD SUCCEEDED`. (Use whatever the repo's core build step is — see `deps_macos`/`build_macos_swiftui` per project memory; the invariant is that `xcodebuild` alone silently links a stale `libpymol_core.a`.)

- [ ] **Step 6: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PyMOLEngine.swift
git commit -m "feat(predict): predictMode + PredictController ownership + PREDICT_FORM routing"
```

---

## Task 5: Tools-menu entry + PredictBar view + docking

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/PredictBar.swift`
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift`

**Interfaces:**
- Consumes: `engine.predictMode`, `engine.setPredictMode`, `engine.predictController` (Task 4); `ThemeManager`.
- Produces: `PredictBar(controller:engine:theme:)` and the `predictBar` docking property; the Tools menu Predict item.

- [ ] **Step 1: Create the bar view**

Create `swiftui/PyMOLViewer/Shared/PredictBar.swift`:

```swift
#if os(macOS)
import SwiftUI

/// Docked Predict form (macOS), raised under the alignment when engine.predictMode is
/// on — the peer of DesignOverlayView. Composes cmd.predict via PredictController.
struct PredictBar: View {
    @ObservedObject var controller: PredictController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            if let w = controller.pendingSizeWarning { sizeWarningRow(w) }
            mainRow
            if controller.useMSA && selectedSupportsMSA && !controller.chains.isEmpty {
                Divider().opacity(0.3)
                msaRow
            }
            if showAdvanced { Divider().opacity(0.3); advancedRow }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
        .onAppear { controller.refresh() }
        .onChange(of: controller.inputText) { _ in controller.inputChanged() }
    }

    private var selectedSupportsMSA: Bool {
        controller.availablePredictors.first { $0.id == controller.predictor }?.msa ?? false
    }

    // Row 1: resolved chains / errors / phase.
    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            switch controller.phase {
            case .idle:
                if let e = controller.resolveError {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundColor(.orange).lineLimit(1)
                } else if !controller.chains.isEmpty {
                    Text(controller.chains.map { "\($0.id)·\($0.length)" }
                            .joined(separator: "  "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.active.panelText.color.opacity(0.6))
                } else {
                    Text("Paste a sequence, a selection, or pick an object.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.5))
                }
            case .searching(let n):
                ProgressView().scaleEffect(0.6)
                Text("Building \(n) alignment\(n == 1 ? "" : "s")…").font(.system(size: 11))
            case .predicting:
                ProgressView().scaleEffect(0.6)
                Text("Prediction submitted — see the progress tray.").font(.system(size: 11))
            case .error(let m):
                Label(m, systemImage: "xmark.octagon").font(.system(size: 11))
                    .foregroundColor(.red).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { engine.setPredictMode(false) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                    .foregroundColor(theme.active.panelText.color.opacity(0.6))
            }
            .buttonStyle(.plain).accessibilityLabel("Close predict")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Row 2: input field + object picker + model + n_models + Use MSA + Advanced + Run.
    private var mainRow: some View {
        HStack(spacing: 8) {
            TextField("sequence / selection", text: $controller.inputText)
                .textFieldStyle(.roundedBorder).frame(minWidth: 160)

            Menu {
                ForEach(engine.objects.filter { !$0.isSelection }, id: \.name) { o in
                    Button(o.name) { controller.inputText = o.name }
                }
            } label: { Image(systemName: "cube") }
            .menuIndicator(.hidden).help("Use a loaded object")

            Picker("", selection: $controller.predictor) {
                ForEach(controller.availablePredictors) { Text($0.id).tag($0.id) }
            }
            .labelsHidden().frame(width: 110)

            Stepper("×\(controller.nModels)", value: $controller.nModels, in: 1...20)
                .fixedSize()

            Toggle("MSA", isOn: $controller.useMSA)
                .toggleStyle(.checkbox).disabled(!selectedSupportsMSA)
                .help(selectedSupportsMSA ? "Search alignments for the chosen chains"
                      : "This model folds single-sequence")

            Button { showAdvanced.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).help("Advanced options")

            Button("Run") { controller.run() }
                .buttonStyle(.borderedProminent)
                .disabled(!canRun)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var canRun: Bool {
        !controller.predictor.isEmpty && !controller.chains.isEmpty
            && controller.resolveError == nil
            && { if case .searching = controller.phase { return false }; return true }()
    }

    // Row 3: which chains get an MSA + a privacy note.
    private var msaRow: some View {
        HStack(spacing: 8) {
            Text("MSA for:").font(.system(size: 11))
                .foregroundColor(theme.active.panelText.color.opacity(0.7))
            ForEach(controller.chains) { ch in
                Toggle(ch.id, isOn: Binding(
                    get: { controller.msaChains.contains(ch.id) },
                    set: { on in
                        if on { controller.msaChains.insert(ch.id) }
                        else { controller.msaChains.remove(ch.id) }
                    }))
                    .toggleStyle(.button).controlSize(.small)
            }
            Spacer(minLength: 0)
            Text("Sequences are sent to \(serverLabel).")
                .font(.system(size: 10)).foregroundColor(.orange.opacity(0.9))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var serverLabel: String {
        controller.server.isEmpty ? "the ColabFold MSA server" : controller.server
    }

    // Row 4 (Advanced): recycling / diffusion / seed / msa_depth / mode / name / server.
    private var advancedRow: some View {
        HStack(spacing: 10) {
            labeled("recycle") { Stepper("\(controller.recyclingSteps)",
                value: $controller.recyclingSteps, in: 1...10).fixedSize() }
            labeled("diffuse") { Stepper("\(controller.diffusionSteps)",
                value: $controller.diffusionSteps, in: 10...500, step: 10).fixedSize() }
            labeled("seed") { TextField("auto", text: $controller.seedText)
                .frame(width: 60).textFieldStyle(.roundedBorder) }
            labeled("depth") { TextField("auto", text: $controller.msaDepthText)
                .frame(width: 60).textFieldStyle(.roundedBorder) }
            labeled("name") { TextField("auto", text: $controller.resultName)
                .frame(width: 90).textFieldStyle(.roundedBorder) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func labeled<V: View>(_ t: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: 3) {
            Text(t).foregroundColor(theme.active.panelText.color.opacity(0.6)); v()
        }
    }
}
#endif
```

- [ ] **Step 2: Add the Predict item to the Tools menu**

In `ContentView.swift` `interactionToolItems` (after the Design block, before the closing of the `@ViewBuilder`, line ~2959), add:

```swift
        #if os(macOS)
        Button {
            engine.setPredictMode(!engine.predictMode)
        } label: {
            if engine.predictMode {
                Label("Predict", systemImage: "checkmark")
            } else {
                Text("Predict")
            }
        }
        #endif
```

In `activeInteractionTool` (line ~2903) add, before `return nil`:

```swift
        #if os(macOS)
        if engine.predictMode { return ("Predict", "atom", "atom") }
        #endif
```

In `toolsMenuHelp` (line ~2964), extend the macOS `tools` string to mention Predict:

```swift
        #if RAYMOL_MPNN
        let tools = "Move objects · Measure distances · Design with MPNN · Predict structures"
        #else
        let tools = "Move objects · Measure distances · Predict structures"
        #endif
```

- [ ] **Step 3: Add the docking property and slot**

In `ContentView.swift`, near `designModeBar` (line ~2060) add:

```swift
    #if os(macOS)
    @ViewBuilder private var predictBar: some View {
        PredictBar(controller: engine.predictController, engine: engine, theme: themeManager)
    }
    #endif
```

Then in the macOS layout's alignment-strip region — the same place `else if engine.designMode { designModeBar }` is chained for the macOS body (find the macOS layout branch; the Design bar is chained there) — add a peer:

```swift
                #if os(macOS)
                else if engine.predictMode { predictBar }
                #endif
```

(Confirm `themeManager` is the ContentView's `ThemeManager` property name at that scope; match how `designModeBar` obtains its theme.)

- [ ] **Step 4: Build and verify it compiles**

Run:
```bash
cd swiftui && ./build_macos_core.sh && xcodebuild build -scheme RayMol -destination 'platform=macOS' 2>&1 | tail -15
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/PredictBar.swift swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "feat(predict): Tools-menu Predict entry + docked PredictBar"
```

---

## Task 6: End-to-end functional verification (macOS VM)

**Files:** none (verification only; fixes land in the relevant task's file).

**Interfaces:** exercises Tasks 1–5 together.

- [ ] **Step 1: Build a suffixed dev app**

Build normally, then rename + re-sign per project memory (never leave a plain `RayMol.app`):

```bash
cd swiftui && ./build_macos_core.sh && xcodebuild build -scheme RayMol -destination 'platform=macOS'
# then apply the RayMol-<suffix> rename + codesign recipe from CLAUDE.md (e.g. RayMol-predict.app)
```

- [ ] **Step 2: Drive it in a disposable VM**

Use the `mac-vm-test` skill. Verify, capturing a screenshot at each step:

1. The Tools menu shows **Predict**; selecting it swaps the toolbar glyph and raises the bar under the alignment.
2. Paste `MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQ` → the status row shows `A·33`; the model picker lists `boltz2` (and `protenix`); set **×2**; click **Run** → the status shows "Prediction submitted" and a card appears in the progress tray. (Weights may download first; that is expected and shown in the tray.)
3. `fetch 1ubq` in the console, type `1ubq` in the bar (or pick it from the object menu), check **MSA**, toggle chain **A**, **Run** → status shows "Building 1 alignment…", an MSA-search row appears in the inspector, and once it lands a predict job follows automatically.
4. Selecting **Move** / **Measure** / **Design**, or pressing **Esc**, exits Predict mode (the bar disappears).

- [ ] **Step 3: Run the full embedded + unit suites**

```bash
pymol -ckqy testing/testing.py --run testing/tests/test_appkit_predict.py
cd swiftui && xcodebuild test -scheme RayMol -destination 'platform=macOS' -only-testing:PyMOLViewerTests/PredictControllerTests -only-testing:PyMOLViewerTests/PredictControllerRunTests 2>&1 | tail -20
```
Expected: all PASS.

- [ ] **Step 4: Commit any fixes and open the PR**

```bash
git add -A && git commit -m "fix(predict): address functional-test findings"   # only if fixes were needed
gh pr create -R javierbq/RayMol --base master --head claude/protein-prediction-ui-10c4ae \
  --title "Predict tool bar (macOS)" \
  --body "Adds a Tools-menu Predict mode with a docked bar under the alignment for starting structure-prediction jobs (input · model · per-chain MSA · n_models). Spec: docs/superpowers/specs/2026-08-18-predict-tool-bar-design.md. Plan: docs/superpowers/plans/2026-08-18-predict-tool-bar.md.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

---

## Self-Review

**1. Spec coverage:**
- Tools-menu entry, exclusive mode, docked bar under the alignment → Tasks 4 (mode) + 5 (menu/bar). ✓
- Input as pasted sequence / selection / object → one field + object menu; `cmd.predict` resolves all three; helper emits chains → Tasks 1, 2, 5. ✓
- Model dropdown from registry → Task 1 (`predictors`) + Task 5 (Picker). ✓
- Use-MSA checkbox + multi-select of chains that need MSA → Task 5 (`msaRow`), gated by `supports_msa` → Tasks 1/3/5. ✓
- `msa_search` creates the alignments; search-then-auto-predict → Task 3 state machine. ✓
- n_models → Task 5 stepper (1…20 constraint) → Task 3 composition. ✓
- Advanced knobs behind a disclosure → Task 5 `advancedRow`. ✓
- Size guard (per predictor) before submit → Task 3 `run()`. ✓
- Privacy note on public MSA server → Task 5 `msaRow`. ✓
- Progress via existing tray/inspector → relies on `predictionJobs`/`alignments`/`msaSearches` (no new surface) → Tasks 3/4. ✓
- Tests: unit (composition + state machine) + Python (`emit`) + functional (VM) → Tasks 2, 3, 1, 6. ✓
- macOS only → every new symbol `#if os(macOS)`. ✓

**2. Placeholder scan:** No TBD/TODO; every code step carries real code. The only hedge is Task 4 Step 5 / Task 6 Step 1 referencing "the repo's core build step" — resolved by the two-stage-build invariant and CLAUDE.md's rename/re-sign recipe, which the executor follows verbatim.

**3. Type consistency:** `PredictorInfo`/`PredictChain`/`PredictFormPayload`/`PredictPhase`/`PredictSizeWarning` are defined once (Task 2) and consumed unchanged (Tasks 3–5). Statics (`predictPython`, `msaSearchPython`, `literalChainSequences`, `msaSlots`, `alignmentBaseName`, `pythonLiteral`) keep identical signatures between definition (Task 2) and use (Task 3, tests). `onEngineState(alignments:searches:)`, `loadFormPayload(_:)`, `run()`, `refresh()`, `cancel()`, `setPredictMode(_:)`, `predictController` are named identically where produced (Tasks 3/4) and consumed (Tasks 4/5). JSON keys (`predictors`/`chains`/`error`, `id`/`length`/`object`/`chain`, `id`/`msa`) match between the Python writer (Task 1) and the Swift `Codable` (Task 2). ✓
