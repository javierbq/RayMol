# Keyboard Shortcut Dispatch (`cmd.set_key`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `cmd.set_key` bindings and PyMOL's 125 built-in key bindings actually fire in the native macOS RayMol app.

**Architecture:** A pure Swift classifier turns an `NSEvent` key-down into PyMOL's canonical key-token string (`"left"`, `"CTRL-T"`, `"ALT-A"`, `"F1"`). An app-level `NSEvent` local monitor feeds it, then dispatches through a new synchronous bridge call into `pymol.internal._invoke_key`. The monitor consumes the event **iff a binding fired**, which is what lets an unbound `⌃D` still reach the Design menu item while a user-bound `⌃D` shadows it. Nothing in `modules/pymol` needs to change for dispatch — that layer is already correct and verified.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (`NSEvent` local monitor), Objective-C++ bridge (`PyMOLBridge.mm`), CPython C-API under PyMOL's `PAutoBlock` GIL model, XCTest, Python `unittest`.

**Issue:** [RayMol#258](https://github.com/javierbq/RayMol/issues/258)
**Spec:** `docs/superpowers/specs/2026-08-10-keyboard-shortcut-dispatch-design.md`

## Global Constraints

- **macOS only.** All new Swift code is inside `#if os(macOS)`. iPad hardware keyboard is a separate follow-up; do not add `UIKeyCommand`/`pressesBegan` here.
- **Deployment target is macOS 13.** Use `NSEvent.addLocalMonitorForEvents`, **never** `.onKeyPress` (macOS 14+). This is why the existing Esc handler is a monitor.
- **Do not change `PyMOLMTKView.acceptsFirstResponder`.** It is `false` deliberately (issue #73) so the command line stays focused. The whole design exists to work around it.
- **Do not modify `modules/pymol/controlling.py`, `internal.py`, `shortcut_dict.py`, or `cmd.py`.** The Python dispatch layer is already correct.
- **GIL model:** any new C-API code uses `PAutoBlock(G)` / `PAutoUnblock(G, blk)`. Never `PyGILState_Ensure` — mixing it with `PyMOL_Idle`'s manual GIL corrupts interpreter thread state.
- **Token grammar** is exactly `internal.modifier_keys == ['', 'SHFT', 'CTRL', 'CTSH', 'ALT']`. Valid prefixes: bare, `SHFT-`, `CTRL-`, `CTSH-`, `ALT-`. Special key names are lowercase (`left`, `pgup`); function keys keep their case (`F1`).
- **⌘ always passes through.** `set_key` has no CMD modifier and macOS menus own ⌘.
- **Swift test module is imported as `@testable import RayMol`** and test classes are `@MainActor final class ...: XCTestCase`.
- **`PyMOLViewerTests` runs against a LIVE PyMOL engine** via `PyMOLEngine.shared` — a singleton shared across test classes, so every case must restore the state it touched.
- **`F1`–`F12`, `CTRL-D`, and `CTRL-M` are unbound in the 125 defaults** (verified). F-keys are therefore safe test fixtures.

## File Structure

| File | Responsibility |
|---|---|
| **Create** `swiftui/PyMOLViewer/Shared/KeyRouting.swift` | Pure `NSEvent`-facts → PyMOL key token classifier. No engine reference, no AppKit state, no side effects. |
| **Create** `swiftui/PyMOLViewerTests/KeyRoutingTests.swift` | Table-driven coverage of the classifier. |
| **Create** `swiftui/PyMOLViewerTests/KeyBindingDispatchTests.swift` | Live-engine coverage of `invokeKeyBinding`. |
| **Create** `modules/pymol/raymol_keys.py` | App menu-shortcut table + `audit_shadowed()` warning. |
| **Create** `testing/tests/test_raymol_keys.py` | Pure-Python coverage of the audit. |
| **Modify** `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h:53` | Declare `PyMOLBridge_InvokeKey`. |
| **Modify** `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm:263` | Implement it, mirroring `PyMOLBridge_Complete` (line 307). |
| **Modify** `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:2696` | Add `invokeKeyBinding(_:) -> Bool`; later remove dead `key(_:x:y:modifiers:)`. |
| **Modify** `swiftui/PyMOLViewer/Shared/ContentView.swift` | Monitor state (near :185), install/remove (:540, :543), `installPyMOLKeyMonitor()`, audit call (:3230, :3234). |
| **Modify** `swiftui/PyMOLViewer/Shared/MetalViewport.swift` | Remove the dead, `.characters`-based key path. |
| **Modify** `.github/workflows/raymol-embedded-tests.yml:63` | Run the new Python test. |

Task order is dependency order. Tasks 1–3 are independent of each other and each ends green; Task 4 wires them together; Task 5 is cleanup; Task 6 is the regression gate.

---

### Task 1: `KeyRouting` — the pure classifier

**Files:**
- Create: `swiftui/PyMOLViewer/Shared/KeyRouting.swift`
- Test: `swiftui/PyMOLViewerTests/KeyRoutingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `KeyRouting.token(keyCode: UInt16, charactersIgnoringModifiers: String?, modifiers: NSEvent.ModifierFlags, textFieldFocused: Bool) -> String?` — returns a canonical PyMOL key token, or `nil` meaning "pass this event through untouched". Task 4 is its only caller.

**Why `charactersIgnoringModifiers`:** with Control held, `NSEvent.characters` yields the ASCII control code (`Ctrl-T` → `"\u{14}"`); with Option held it yields the composed glyph (`Alt-A` → `"å"`). Only `charactersIgnoringModifiers` gives back the plain letter. The pre-existing dead code in `MetalViewport` reads `.characters` and would have mis-tokenized every `ALT-` binding.

- [ ] **Step 1: Write the failing tests**

Create `swiftui/PyMOLViewerTests/KeyRoutingTests.swift`:

```swift
import XCTest
import AppKit
@testable import RayMol

/// Coverage for KeyRouting.token — the pure NSEvent-facts → PyMOL key-token
/// classifier behind cmd.set_key dispatch (#258).
///
/// The NSEvent monitor itself lives in ContentView and cannot be unit-tested
/// (a test cannot press a key), so ALL the routing policy lives here in a pure
/// function and is pinned down here instead.
final class KeyRoutingTests: XCTestCase {

    // Convenience: classify with no modifiers and nothing focused.
    private func tok(_ keyCode: UInt16,
                     _ chars: String? = nil,
                     _ mods: NSEvent.ModifierFlags = [],
                     focused: Bool = false) -> String? {
        KeyRouting.token(keyCode: keyCode,
                         charactersIgnoringModifiers: chars,
                         modifiers: mods,
                         textFieldFocused: focused)
    }

    // MARK: - Special keys

    func testBareSpecialKeys() {
        XCTAssertEqual(tok(123), "left")
        XCTAssertEqual(tok(124), "right")
        XCTAssertEqual(tok(125), "down")
        XCTAssertEqual(tok(126), "up")
        XCTAssertEqual(tok(116), "pgup")
        XCTAssertEqual(tok(121), "pgdn")
        XCTAssertEqual(tok(115), "home")
        XCTAssertEqual(tok(119), "end")
        XCTAssertEqual(tok(114), "insert")
    }

    func testFunctionKeys() {
        XCTAssertEqual(tok(122), "F1")
        XCTAssertEqual(tok(120), "F2")
        XCTAssertEqual(tok(99),  "F3")
        XCTAssertEqual(tok(118), "F4")
        XCTAssertEqual(tok(96),  "F5")
        XCTAssertEqual(tok(97),  "F6")
        XCTAssertEqual(tok(98),  "F7")
        XCTAssertEqual(tok(100), "F8")
        XCTAssertEqual(tok(101), "F9")
        XCTAssertEqual(tok(109), "F10")
        XCTAssertEqual(tok(103), "F11")
        XCTAssertEqual(tok(111), "F12")
    }

    func testModifiedSpecialKeys() {
        XCTAssertEqual(tok(116, nil, [.shift]), "SHFT-pgup")
        XCTAssertEqual(tok(116, nil, [.control]), "CTRL-pgup")
        XCTAssertEqual(tok(116, nil, [.control, .shift]), "CTSH-pgup")
        XCTAssertEqual(tok(116, nil, [.option]), "ALT-pgup")
    }

    /// modifier_keys has no index 5, so ALT+SHFT is not representable as a
    /// token. Degrade to plain ALT- rather than emit something unmatchable.
    func testAltShiftSpecialDegradesToAlt() {
        XCTAssertEqual(tok(116, nil, [.option, .shift]), "ALT-pgup")
    }

    // MARK: - Focus policy (the command line owns unmodified arrows)

    func testUnmodifiedArrowsYieldToFocusedTextField() {
        XCTAssertNil(tok(123, nil, [], focused: true))
        XCTAssertNil(tok(124, nil, [], focused: true))
        XCTAssertNil(tok(125, nil, [], focused: true))
        XCTAssertNil(tok(126, nil, [], focused: true))
    }

    /// Only the ARROWS yield. pgup/pgdn/home/end/F-keys have no meaning in the
    /// command line, so they dispatch even while it is focused.
    func testNonArrowSpecialsDispatchWhileFocused() {
        XCTAssertEqual(tok(116, nil, [], focused: true), "pgup")
        XCTAssertEqual(tok(121, nil, [], focused: true), "pgdn")
        XCTAssertEqual(tok(115, nil, [], focused: true), "home")
        XCTAssertEqual(tok(122, nil, [], focused: true), "F1")
    }

    /// A MODIFIED arrow is not a caret movement, so it dispatches regardless.
    func testModifiedArrowsDispatchWhileFocused() {
        XCTAssertEqual(tok(123, nil, [.control], focused: true), "CTRL-left")
        XCTAssertEqual(tok(123, nil, [.shift], focused: true), "SHFT-left")
    }

    // MARK: - Letters and digits

    func testControlLetters() {
        XCTAssertEqual(tok(17, "t", [.control]), "CTRL-T")
        XCTAssertEqual(tok(2,  "d", [.control]), "CTRL-D")
        XCTAssertEqual(tok(46, "m", [.control]), "CTRL-M")
    }

    func testAltLettersAndDigits() {
        XCTAssertEqual(tok(0,  "a", [.option]), "ALT-A")
        XCTAssertEqual(tok(18, "1", [.option]), "ALT-1")
    }

    func testControlShiftLetters() {
        XCTAssertEqual(tok(11, "b", [.control, .shift]), "CTSH-B")
    }

    /// The classifier must read charactersIgnoringModifiers. If an
    /// implementation reads .characters it sees "\u{14}" for Ctrl-T and "å" for
    /// Alt-A; neither uppercases into a valid token.
    func testRejectsControlCodesAndComposedGlyphs() {
        XCTAssertNil(tok(17, "\u{14}", [.control]))
        XCTAssertNil(tok(0,  "å",      [.option]))
    }

    // MARK: - Pass-through cases

    /// ⌘ belongs to the macOS menus, and set_key has no CMD modifier.
    func testCommandAlwaysPassesThrough() {
        XCTAssertNil(tok(31, "o", [.command]))
        XCTAssertNil(tok(31, "o", [.command, .shift]))
        XCTAssertNil(tok(46, "m", [.command, .option]))
        XCTAssertNil(tok(46, "m", [.control, .command]))
        XCTAssertNil(tok(123, nil, [.command]))
    }

    /// Bare printables belong to the command line; set_key rejects them too
    /// ("Can't map regular letters"), as it does SHFT-<letter>.
    func testBarePrintablesAndShiftLettersPassThrough() {
        XCTAssertNil(tok(17, "t", []))
        XCTAssertNil(tok(17, "t", [.shift]))
        XCTAssertNil(tok(18, "1", []))
    }

    /// Esc (53) must yield no token so the separate Esc monitor still sees it.
    func testEscapeAndUnknownKeysPassThrough() {
        XCTAssertNil(tok(53))
        XCTAssertNil(tok(36))   // Return
        XCTAssertNil(tok(48))   // Tab
        XCTAssertNil(tok(51))   // Delete
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -skipPackagePluginValidation test 2>&1 | tail -30
```

Expected: FAIL to compile — `cannot find 'KeyRouting' in scope`.

- [ ] **Step 3: Write the implementation**

Create `swiftui/PyMOLViewer/Shared/KeyRouting.swift`:

```swift
#if os(macOS)
import AppKit

/// Translates a macOS key-down into PyMOL's canonical key-token grammar, or to
/// nil meaning "not ours — pass the event through untouched".
///
/// Deliberately pure: no engine reference, no AppKit state reads, no side
/// effects. The NSEvent monitor in ContentView supplies the facts and acts on
/// the result, which keeps ALL of the routing policy unit-testable (a test
/// cannot press a key).
///
/// Token grammar matches pymol.internal.modifier_keys exactly —
/// ['', 'SHFT', 'CTRL', 'CTSH', 'ALT'] — so valid prefixes are bare, SHFT-,
/// CTRL-, CTSH- and ALT-. Special names are lowercase; function keys are not.
enum KeyRouting {

    /// macOS virtual key codes for the keys PyMOL calls "special".
    private static let specialKeys: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up",
        116: "pgup", 121: "pgdn", 115: "home", 119: "end",
        114: "insert",   // "Help" position on a full-size Apple keyboard
        122: "F1", 120: "F2",  99: "F3", 118: "F4",
         96: "F5",  97: "F6",  98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// The four keys the command line needs for caret movement and history.
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    static func token(keyCode: UInt16,
                      charactersIgnoringModifiers: String?,
                      modifiers: NSEvent.ModifierFlags,
                      textFieldFocused: Bool) -> String? {
        // 1. ⌘ belongs to the macOS menus. set_key has no CMD modifier, so an
        //    event carrying ⌘ can never be ours.
        if modifiers.contains(.command) { return nil }

        let ctrl = modifiers.contains(.control)
        let alt = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        // 2. An UNMODIFIED arrow is caret movement / history recall while the
        //    command line holds focus, so it yields. Must precede the
        //    special-key mapping below or it could never fire. Modified arrows
        //    are not caret movements and dispatch regardless.
        if textFieldFocused, arrowKeys.contains(keyCode), !ctrl, !alt, !shift {
            return nil
        }

        // 3. Special keys carry an optional modifier prefix.
        if let name = specialKeys[keyCode] {
            guard let prefix = modifierPrefix(ctrl: ctrl, alt: alt, shift: shift) else {
                return nil
            }
            return prefix.isEmpty ? name : prefix + "-" + name
        }

        // 4. Letters and digits are only ours when carrying CTRL / ALT / CTSH.
        //    set_key refuses bare letters and SHFT-<letter> outright.
        guard ctrl || alt else { return nil }
        guard let ch = charactersIgnoringModifiers, ch.count == 1,
              let scalar = ch.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        let upper = ch.uppercased()
        if ctrl && shift { return "CTSH-" + upper }
        if ctrl { return "CTRL-" + upper }
        return "ALT-" + upper
    }

    /// PyMOL's modifier prefix for a special key. ALT+SHFT has no index in
    /// modifier_keys (it would be 5, past the end), so it degrades to plain
    /// ALT- rather than producing a token nothing can match.
    private static func modifierPrefix(ctrl: Bool, alt: Bool, shift: Bool) -> String? {
        if alt { return "ALT" }
        if ctrl && shift { return "CTSH" }
        if ctrl { return "CTRL" }
        if shift { return "SHFT" }
        return ""
    }
}
#endif
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -skipPackagePluginValidation test -only-testing:PyMOLViewerTests/KeyRoutingTests 2>&1 | tail -20
```

Expected: all `KeyRoutingTests` cases PASS.

- [ ] **Step 5: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/KeyRouting.swift swiftui/PyMOLViewerTests/KeyRoutingTests.swift
git commit -m "feat(keys): pure NSEvent -> PyMOL key-token classifier (#258)"
```

---

### Task 2: Bridge + engine dispatch

**Files:**
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h:53`
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm:263`
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:2696`
- Test: `swiftui/PyMOLViewerTests/KeyBindingDispatchTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `int PyMOLBridge_InvokeKey(const char *key)` (1 = a binding fired, 0 = unbound/error) and `PyMOLEngine.invokeKeyBinding(_ token: String) -> Bool`. Task 4 calls the Swift one.

`_invoke_key` is reached through `pymol.internal`, **not** `cmd`: `cmd` re-exports only `_special`, `_ctrl`, and `_alt`.

- [ ] **Step 1: Write the failing test**

Create `swiftui/PyMOLViewerTests/KeyBindingDispatchTests.swift`:

```swift
import XCTest
@testable import RayMol

/// Coverage for PyMOLEngine.invokeKeyBinding — the synchronous bridge into
/// pymol.internal._invoke_key that carries cmd.set_key dispatch (#258).
///
/// These run against the LIVE engine, so they bind and unbind real keys. F-keys
/// are used throughout because F1–F12 are unbound in PyMOL's 125 defaults,
/// which makes them both safe to claim and usable as negative controls.
@MainActor
final class KeyBindingDispatchTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    override func tearDown() {
        // Release anything a case bound, so the shared singleton stays clean.
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "for _k in ('F7', 'F8', 'F9'):\n"
            + "    _c.key_mappings.pop(_k, None)")
        super.tearDown()
    }

    /// The return value is what tells the monitor whether to consume the event,
    /// so an UNBOUND key must report false — that is the whole mechanism by
    /// which ⌃D still reaches the Design menu item.
    func testUnboundKeyReportsFalse() {
        engine.runPython("from pymol import cmd as _c; _c.key_mappings.pop('F9', None)")
        XCTAssertFalse(engine.invokeKeyBinding("F9"))
    }

    func testBoundPythonCallableFiresAndReportsTrue() {
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "import pymol\n"
            + "pymol._t258 = 0\n"
            + "def _hit():\n"
            + "    import pymol as _p; _p._t258 += 1\n"
            + "_c.set_key('F7', _hit)")
        XCTAssertTrue(engine.invokeKeyBinding("F7"))
        XCTAssertEqual(pythonInt("pymol._t258"), 1)
        XCTAssertTrue(engine.invokeKeyBinding("F7"))
        XCTAssertEqual(pythonInt("pymol._t258"), 2)
    }

    /// set_key also accepts a PyMOL command STRING (since PyMOL 1.6.1), which
    /// _invoke_key routes through cmd.do. Gabriel's script uses callables, but
    /// the 125 built-in defaults are all strings, so this path carries parity.
    func testBoundCommandStringFires() {
        engine.runPython("from pymol import cmd as _c; _c.set_key('F8', 'set sphere_scale, 0.37')")
        XCTAssertTrue(engine.invokeKeyBinding("F8"))
        XCTAssertEqual(pythonFloat("cmd.get_setting_float('sphere_scale')"), 0.37, accuracy: 0.001)
        engine.runCommand("set sphere_scale, 1.0")
    }

    func testUnknownTokenIsHarmless() {
        XCTAssertFalse(engine.invokeKeyBinding("NOT-A-KEY"))
        XCTAssertFalse(engine.invokeKeyBinding(""))
    }

    // Read a value back out of the live interpreter via the engine's own
    // completion channel is not possible, so stash into a file-free global and
    // read it with a tiny eval helper built on runPython + feedback.
    private func pythonInt(_ expr: String) -> Int {
        Int(pythonRepr(expr)) ?? -1
    }
    private func pythonFloat(_ expr: String) -> Double {
        Double(pythonRepr(expr)) ?? .nan
    }
    private func pythonRepr(_ expr: String) -> String {
        let path = NSTemporaryDirectory() + "/t258_probe.txt"
        engine.runPython(
            "from pymol import cmd\n"
            + "import pymol\n"
            + "open(r'\(path)', 'w').write(str(\(expr)))")
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
```

Note: the tempfile probe follows the same pattern the object panel uses to get values out of the embedded interpreter — PyMOL's feedback channel truncates at 1024 chars and is not a reliable return path.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -skipPackagePluginValidation test -only-testing:PyMOLViewerTests/KeyBindingDispatchTests 2>&1 | tail -20
```

Expected: FAIL to compile — `value of type 'PyMOLEngine' has no member 'invokeKeyBinding'`.

- [ ] **Step 3: Declare the bridge function**

In `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h`, immediately after the existing `PyMOLBridge_Key` declaration (line 53):

```c
// Fires a cmd.set_key binding by its canonical PyMOL key token ("left",
// "CTRL-T", "ALT-A", "F1"). Returns 1 if a binding existed and ran, 0 if the
// key is unbound (or on error). The caller uses that answer to decide whether
// to consume the key event: an unbound key must fall through to the macOS menus
// so RayMol's own ⌃M / ⌃D shortcuts keep working (#258).
int PyMOLBridge_InvokeKey(const char *key);
```

- [ ] **Step 4: Implement the bridge function**

In `swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm`, after `PyMOLBridge_Key` (line ~266):

```objc
int PyMOLBridge_InvokeKey(const char *key)
{
    if (!key || !key[0]) return 0;
    PyMOLGlobals *G = SingletonPyMOLGlobals;
    if (!G) return 0;
    int blk = PAutoBlock(G);
    int fired = 0;
    // pymol.internal._invoke_key(key, quiet=1) — the same routine cmd._special
    // and cmd._ctrl funnel through. Reached via pymol.internal because cmd
    // re-exports only _special/_ctrl/_alt, not _invoke_key. quiet=1 suppresses
    // the "No key mapping" print for the (very common) unbound case.
    PyObject *mod = PyImport_ImportModule("pymol.internal");
    if (mod) {
        PyObject *res = PyObject_CallMethod(mod, "_invoke_key", "si", key, 1);
        if (res) {
            fired = PyObject_IsTrue(res) == 1 ? 1 : 0;
            Py_DECREF(res);
        }
        Py_DECREF(mod);
    }
    if (PyErr_Occurred()) {
        // A user's bound function raising must not swallow the keystroke
        // silently; print it like any other PyMOL script error, and report
        // "fired" so the key isn't ALSO handed to a menu.
        PyErr_Print();
        fired = 1;
    }
    PAutoUnblock(G, blk);
    return fired;
}
```

- [ ] **Step 5: Add the engine wrapper**

In `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift`, immediately after the existing `key(_:x:y:modifiers:)` (line ~2696–2699):

```swift
    /// Fire a cmd.set_key binding by canonical PyMOL key token, returning
    /// whether one existed. The caller consumes the key event iff this is true,
    /// which is what lets an unbound ⌃D fall through to the Design menu item
    /// while a user-bound ⌃D shadows it (#258).
    ///
    /// Synchronous and in-process (same model as `complete(_:)`), so the answer
    /// is available while the NSEvent monitor still has to decide.
    func invokeKeyBinding(_ token: String) -> Bool {
        guard isReady, !token.isEmpty else { return false }
        return PyMOLBridge_InvokeKey(token) == 1
    }
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -skipPackagePluginValidation test -only-testing:PyMOLViewerTests/KeyBindingDispatchTests 2>&1 | tail -20
```

Expected: all `KeyBindingDispatchTests` cases PASS.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Bridge/PyMOLBridge.h swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm \
       swiftui/PyMOLViewer/Shared/PyMOLEngine.swift swiftui/PyMOLViewerTests/KeyBindingDispatchTests.swift
git commit -m "feat(keys): synchronous _invoke_key bridge + engine wrapper (#258)"
```

---

### Task 3: Shadow-warning audit

**Files:**
- Create: `modules/pymol/raymol_keys.py`
- Create: `testing/tests/test_raymol_keys.py`
- Modify: `.github/workflows/raymol-embedded-tests.yml:63`

**Interfaces:**
- Consumes: nothing.
- Produces: `raymol_keys.audit_shadowed(has_design=False, _self=None) -> list[str]` — returns the warning lines it printed (so it is testable), and `raymol_keys.APP_SHORTCUTS: dict[str, str]` mapping token → human label. Task 4 calls `audit_shadowed`.

`⌃M` (Move Objects, Mouse menu) and `⌃D` (Design mode, Design menu) are the **only** two RayMol menu shortcuts without ⌘, so they are the only ones a `set_key` binding can shadow. `⌃D` exists only in `RAYMOL_MPNN` builds, which is why the caller passes `has_design`.

- [ ] **Step 1: Write the failing test**

Create `testing/tests/test_raymol_keys.py`:

```python
"""Unit tests for pymol.raymol_keys — headless, no PyMOL core required.

Covers the shadow-warning audit (RayMol#258): when a user's ~/.raymolrc binds a
key that RayMol also uses as a menu shortcut, the user is told once rather than
left wondering why the menu item stopped responding to its key.

Only ⌃M and ⌃D can collide: every other RayMol menu shortcut carries ⌘, and the
classifier passes ⌘ events straight through to the menus.
"""

import os
import sys
import types
import unittest

_MODULES_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, "modules")
)
if "pymol" not in sys.modules or not hasattr(sys.modules["pymol"], "__path__"):
    _pymol_stub = types.ModuleType("pymol")
    _pymol_stub.__path__ = [os.path.join(_MODULES_DIR, "pymol")]
    _pymol_stub.__package__ = "pymol"
    sys.modules["pymol"] = _pymol_stub

from pymol import raymol_keys


class FakeCmd:
    """Just enough cmd surface for the audit: the key_mappings dict."""

    def __init__(self, mappings=None):
        self.key_mappings = dict(mappings or {})


class AuditShadowedTests(unittest.TestCase):

    def test_no_bindings_no_warnings(self):
        self.assertEqual(raymol_keys.audit_shadowed(_self=FakeCmd()), [])

    def test_unrelated_bindings_no_warnings(self):
        fake = FakeCmd({"CTRL-T": "bond;unpick", "left": "_ backward", "F1": "ray"})
        self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])

    def test_warns_for_shadowed_move_shortcut(self):
        fake = FakeCmd({"CTRL-M": "zoom"})
        lines = raymol_keys.audit_shadowed(_self=fake)
        self.assertEqual(len(lines), 1)
        self.assertIn("CTRL-M", lines[0])
        self.assertIn("Move Objects", lines[0])

    def test_design_warning_only_in_design_builds(self):
        fake = FakeCmd({"CTRL-D": "turn x, 5"})
        # Non-MPNN build: there is no Design menu item, so nothing is shadowed.
        self.assertEqual(raymol_keys.audit_shadowed(has_design=False, _self=fake), [])
        lines = raymol_keys.audit_shadowed(has_design=True, _self=fake)
        self.assertEqual(len(lines), 1)
        self.assertIn("CTRL-D", lines[0])
        self.assertIn("Design", lines[0])

    def test_warns_once_per_shadowed_key(self):
        fake = FakeCmd({"CTRL-M": "zoom", "CTRL-D": "turn x, 5"})
        lines = raymol_keys.audit_shadowed(has_design=True, _self=fake)
        self.assertEqual(len(lines), 2)

    def test_empty_binding_is_not_a_shadow(self):
        # cmd.set_key(key, '') is how a binding is CLEARED; it shadows nothing.
        fake = FakeCmd({"CTRL-M": ""})
        self.assertEqual(raymol_keys.audit_shadowed(_self=fake), [])

    def test_missing_key_mappings_is_harmless(self):
        self.assertEqual(raymol_keys.audit_shadowed(_self=object()), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python3 -m unittest discover -s testing/tests -p "test_raymol_keys.py" -v 2>&1 | tail -20
```

Expected: FAIL — `ImportError: cannot import name 'raymol_keys' from 'pymol'`.

- [ ] **Step 3: Write the implementation**

Create `modules/pymol/raymol_keys.py`:

```python
# raymol_keys.py
#
# RayMol delivers cmd.set_key bindings via an NSEvent monitor that consumes a
# key event only when a binding actually fired (RayMol#258). That rule gives the
# user's ~/.raymolrc the last word for free — but it also means a binding can
# quietly take over a key the app itself uses as a menu shortcut, and the user
# would just see the menu item stop responding to its key.
#
# This module names that collision out loud, once, right after ~/.raymolrc runs.
#
# Only these two keys can collide: every other RayMol menu shortcut carries ⌘,
# and the Swift classifier passes ⌘ events straight through to the menus.

# Canonical key token -> the menu command it would shadow.
APP_SHORTCUTS = {
    'CTRL-M': 'Move Objects (Mouse menu)',
    'CTRL-D': 'Enter/Exit Design Mode (Design menu)',
}

# CTRL-D only exists in RAYMOL_MPNN builds, so the caller says whether the
# Design menu is present rather than this module guessing.
_DESIGN_ONLY = ('CTRL-D',)


def audit_shadowed(has_design=False, _self=None):
    '''
    Print one warning per user binding that shadows a RayMol menu shortcut.

    Returns the list of lines printed, so callers and tests can inspect the
    result. Never raises: this runs on the launch path, and a broken audit must
    not take the app's startup with it.
    '''
    if _self is None:
        from pymol import cmd as _self

    mappings = getattr(_self, 'key_mappings', None)
    if not isinstance(mappings, dict):
        return []

    lines = []
    for key, label in sorted(APP_SHORTCUTS.items()):
        if key in _DESIGN_ONLY and not has_design:
            continue
        # An empty mapping is how set_key(key, '') CLEARS a binding.
        if not mappings.get(key):
            continue
        line = (" RayMol: %s is bound by your startup script; it now overrides"
                " the \"%s\" shortcut (the menu item still works by click)."
                % (key, label))
        print(line)
        lines.append(line)
    return lines
```

- [ ] **Step 4: Run test to verify it passes**

```bash
python3 -m unittest discover -s testing/tests -p "test_raymol_keys.py" -v 2>&1 | tail -20
```

Expected: 7 tests, all PASS.

- [ ] **Step 5: Wire the test into CI**

In `.github/workflows/raymol-embedded-tests.yml`, add one line to the `--run` list (after `testing/tests/test_inspector_transparency.py`, currently line 63; keep the trailing `\` continuations correct):

```yaml
              testing/tests/test_raymol_keys.py
```

- [ ] **Step 6: Verify the test runs under the embedded runner**

```bash
.venv/bin/pymol -ckqy testing/testing.py --run testing/tests/test_raymol_keys.py 2>&1 | tail -20
```

Expected: PASS. If the venv pymol is broken, `/opt/homebrew/bin/pymol` works for this pure-Python test — it imports `raymol_keys` from `modules/` by path and needs no `_cmd`.

- [ ] **Step 7: Commit**

```bash
git add modules/pymol/raymol_keys.py testing/tests/test_raymol_keys.py .github/workflows/raymol-embedded-tests.yml
git commit -m "feat(keys): warn when a set_key binding shadows a menu shortcut (#258)"
```

---

### Task 4: Wire the monitor

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/ContentView.swift` (state near :185, install :540, remove :543, new func after `installEscKeyMonitor` :565, audit calls :3230 and :3234)

**Interfaces:**
- Consumes: `KeyRouting.token(keyCode:charactersIgnoringModifiers:modifiers:textFieldFocused:)` (Task 1), `engine.invokeKeyBinding(_:)` (Task 2), `raymol_keys.audit_shadowed(has_design=…)` (Task 3).
- Produces: no new API. This is the integration point.

There is no unit test for this task — a test cannot press a key, which is exactly why Tasks 1–3 hold all the logic. Task 6 is its verification.

- [ ] **Step 1: Add the monitor state**

In `ContentView.swift`, immediately after the `escKeyMonitor` declaration (line 185):

```swift
    // Local key-down monitor token for cmd.set_key dispatch (#258). Same
    // rationale as escKeyMonitor above: MetalViewport declines first-responder
    // status (#73), so the viewport never receives keyDown and a monitor is the
    // only way to see keys at all. Installed/removed alongside it.
    @State private var pymolKeyMonitor: Any?
```

- [ ] **Step 2: Install and remove it alongside the Esc monitor**

At line 540, after `installEscKeyMonitor()`:

```swift
                installPyMOLKeyMonitor()
```

In the `.onDisappear` block (lines 542–547), after the existing `escKeyMonitor` teardown:

```swift
                if let token = pymolKeyMonitor {
                    NSEvent.removeMonitor(token)
                    pymolKeyMonitor = nil
                }
```

- [ ] **Step 3: Add the monitor itself**

After `installEscKeyMonitor()` ends (it begins at line 565), add:

```swift
    // cmd.set_key dispatch (#258). A local key-down monitor for the same reason
    // the Esc handler is one: MetalViewport deliberately declines
    // first-responder status (#73), so keyDown never reaches the viewport and
    // the app would otherwise never see a key at all.
    //
    // The consume rule is the whole conflict policy: KeyRouting decides whether
    // an event is even a candidate, then we consume it ONLY if a binding
    // actually fired. So an unbound ⌃D falls through to the Design menu item
    // naturally, while a user-bound ⌃D shadows it — no reserved-key table
    // needed. Esc (keyCode 53) never yields a token, so this monitor and the Esc
    // one never contend.
    private func installPyMOLKeyMonitor() {
        guard pymolKeyMonitor == nil else { return }
        pymolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Unmodified arrows belong to whatever text field is being edited
            // (caret movement, command history). The window's shared field
            // editor is an NSTextView, which is what a focused NSTextField
            // actually uses — check both.
            let responder = NSApp.keyWindow?.firstResponder
            let focused = responder is NSTextView || responder is NSTextField
            guard let token = KeyRouting.token(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags,
                    textFieldFocused: focused) else { return event }
            return engine.invokeKeyBinding(token) ? nil : event
        }
    }
```

- [ ] **Step 4: Run the audit after `~/.raymolrc` loads**

Replace the body of `loadRaymolrcOrOfferMigration`'s final line (line 3230) and of `confirmRaymolrcMigration` (line 3234) so both go through one helper. Add the helper next to them:

```swift
    // ~/.raymolrc may bind a key RayMol also uses as a menu shortcut; the audit
    // says so once, right after the script runs (#258). ⌃D only exists in
    // RAYMOL_MPNN builds, so tell the audit whether the Design menu is present
    // rather than making Python guess.
    private func loadRaymolrcAndAudit(migrateFirst: Bool = false) {
        #if RAYMOL_MPNN
        let hasDesign = "True"
        #else
        let hasDesign = "False"
        #endif
        let migrate = migrateFirst ? "_raymolrc.migrate(); " : ""
        engine.runPython(
            "from pymol import raymolrc as _raymolrc, raymol_keys as _raymol_keys; "
            + migrate
            + "_raymolrc.load(); "
            + "_raymol_keys.audit_shadowed(has_design=\(hasDesign))")
    }
```

Then line 3230 becomes `loadRaymolrcAndAudit()` and line 3234 becomes `loadRaymolrcAndAudit(migrateFirst: true)`. Leave `declineRaymolrcMigration` (line 3238) untouched — nothing loaded, so there is nothing to audit.

- [ ] **Step 5: Build the app**

The macOS build is **two stages**: `build_macos.sh` builds only `libpymol_core.a`, then `xcodebuild` builds the app against it. No task in this plan touches `layer*/` C++ core, so the core stage is a safeguard rather than a requirement here — but run it anyway, because `xcodebuild` alone will silently link a *stale* `libpymol_core.a` from an earlier checkout with no error at all. It is incremental and cheap when nothing changed:

```bash
cd swiftui && ./build_macos.sh 2>&1 | tail -5 && \
  xcodebuild -project PyMOLViewer.xcodeproj -scheme PyMOLViewer_macOS \
             -skipPackagePluginValidation build 2>&1 | tail -20
```

Expected: `=== Done: …/libpymol_core.a ===` then `BUILD SUCCEEDED`, with no warnings in the new code.

Note that step 4 puts `hasDesign` behind `#if RAYMOL_MPNN`, so both branches must compile. The `PyMOLViewer_macOS` scheme covers whichever configuration this checkout is set to; if the two configurations diverge in this repo, build each.

- [ ] **Step 6: Run the full Swift suite for regressions**

```bash
cd swiftui && xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS -skipPackagePluginValidation test 2>&1 | tail -25
```

Expected: all pre-existing tests still PASS alongside `KeyRoutingTests` and `KeyBindingDispatchTests`. `InteractionModeExitTests` is the one to watch — it covers the Esc routing this monitor sits next to.

- [ ] **Step 7: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/ContentView.swift
git commit -m "feat(keys): dispatch cmd.set_key bindings from an NSEvent monitor (#258)"
```

---

### Task 5: Remove the dead key path

**Files:**
- Modify: `swiftui/PyMOLViewer/Shared/MetalViewport.swift` (comment :107–115, `keyDown` :175–177, `handleKeyDown` :1017–1021)
- Modify: `swiftui/PyMOLViewer/Shared/PyMOLEngine.swift:2696` (remove `key(_:x:y:modifiers:)`)
- Modify: `swiftui/PyMOLViewer/Bridge/PyMOLBridge.h:53` and `PyMOLBridge.mm:263` (remove `PyMOLBridge_Key`)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing. Pure deletion.

This path is unreachable (`acceptsFirstResponder` is `false`) **and** wrong (it reads `.characters`, so it would mis-tokenize every `ALT-` binding). Leaving it invites a future reader to "fix" the dead path instead of the live one. `PyMOL_Key` in `layer5/PyMOL.cpp` stays — that is core code with other callers; only the Swift/bridge shim goes.

- [ ] **Step 1: Confirm nothing else calls it**

```bash
grep -rn "handleKeyDown\|engine\.key(\|PyMOLBridge_Key\|\.key(UInt8" swiftui/PyMOLViewer swiftui/PyMOLViewerTests swiftui/PyMOLViewerUITests | grep -v build_
```

Expected: only the declaration/definition sites listed above. If anything else appears, stop and reassess rather than deleting.

- [ ] **Step 2: Delete the `keyDown` override and `handleKeyDown`**

In `MetalViewport.swift`, remove:

```swift
    override func keyDown(with event: NSEvent) {
        coordinator?.handleKeyDown(event, in: self)
    }
```

and

```swift
        func handleKeyDown(_ event: NSEvent, in view: MTKView) {
            guard let chars = event.characters, let firstChar = chars.first else { return }
            let mods = pymolModifiers(event.modifierFlags.rawValue)
            engine?.key(UInt8(firstChar.asciiValue ?? 0), x: 0, y: 0, modifiers: mods)
        }
```

- [ ] **Step 3: Correct the `acceptsFirstResponder` comment**

The trade-off it describes is no longer the situation. Replace the final sentence of that comment (the "Trade-off: single-key PyMOL shortcuts routed through keyDown -> handleKeyDown no longer fire while the command line holds focus; RayMol is command-line/UI-driven, so keeping the prompt focused is the intended behavior." passage) with:

```swift
    // Keyboard shortcuts do NOT depend on this view's responder status: cmd.set_key
    // bindings are dispatched from an app-level NSEvent monitor in ContentView
    // (installPyMOLKeyMonitor, #258), which sees keys regardless of focus.
```

- [ ] **Step 4: Delete the engine wrapper and the bridge shim**

Remove `PyMOLEngine.key(_:x:y:modifiers:)`, the `PyMOLBridge_Key` declaration in `PyMOLBridge.h`, and its definition in `PyMOLBridge.mm`. Leave `invokeKeyBinding` and `PyMOLBridge_InvokeKey` in place.

**Keep `pymolModifiers(_:)`** (`MetalViewport.swift:501`). It is *not* exclusive to the key path — eight mouse handlers call it (lines 639, 776, 841, 863, 879, 885, 891, 898). Only the call at line 1019, inside `handleKeyDown`, goes away with this deletion.

- [ ] **Step 5: Build and run the full suite**

Two stages again — core, then app/tests:

```bash
cd swiftui && ./build_macos.sh 2>&1 | tail -5 && \
  xcodebuild -project PyMOLViewer.xcodeproj -scheme UnitTests_macOS \
             -skipPackagePluginValidation test 2>&1 | tail -20
```

Expected: builds clean, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add swiftui/PyMOLViewer/Shared/MetalViewport.swift swiftui/PyMOLViewer/Shared/PyMOLEngine.swift \
       swiftui/PyMOLViewer/Bridge/PyMOLBridge.h swiftui/PyMOLViewer/Bridge/PyMOLBridge.mm
git commit -m "refactor(keys): drop the dead, .characters-based key path (#258)"
```

---

### Task 6: Regression + functional verification in a VM

**Files:** none — this is the acceptance gate.

**Interfaces:**
- Consumes: the shipped app from Task 5.
- Produces: a pass/fail record for each item, to be pasted into the PR body.

Use the `mac-vm-test` / `raymol-mac-vm` workflow: build on the host, drive the app in a disposable VM. Launch with `RAYMOL_MCP_AUTOTRUST=1` so the session can drive it, and capture the live frame with `screencapture -l<winid>`.

**Every item runs twice** — once with no `~/.raymolrc`, once with Gabriel's `obj_arrows.py` installed as `~/.raymolrc.py` (it binds `CTRL-D`, so it exercises the shadow path).

- [ ] **Step 1: Confirm the fix (the reported bug)**

With `obj_arrows.py` as `~/.raymolrc.py` and two or more objects loaded:

- [ ] `pgup` / `pgdn` step through objects (`move_up` / `move_down`)
- [ ] `CTRL-T` applies the `gv` representation preset
- [ ] `left` also runs `gv`
- [ ] `CTRL-G`, `CTRL-P`, `CTRL-B` run `align_structure`, `sphere_packing`, `spectrum_b_default`

- [ ] **Step 2: The critical regression — the two ⌘-less menu shortcuts**

- [ ] **No rc:** `⌃M` still toggles Move mode (gizmo appears/disappears)
- [ ] **No rc:** `⌃D` still toggles Design mode (`RAYMOL_MPNN` builds)
- [ ] **With rc:** `⌃D` runs `move_down` instead, the shadow warning appears once in the log, and Design mode still opens from the Design menu by click

This is the single most important item in the plan: it is the only place the consume-iff-fired rule carries the entire conflict policy.

- [ ] **Step 3: ⌘ menu shortcuts unaffected**

- [ ] `⌘O` Open…, `⇧⌘O` Fetch from PDB…
- [ ] `⌘S` Save Session, `⇧⌘S` Save Session As…
- [ ] `⇧⌘E` Export Image…, `⌘C` Copy Image to Clipboard
- [ ] `⌥⌘M` Edit Timeline, `⌃⌘M` Enable AI control

- [ ] **Step 4: Command panel field-editor paths (field focused)**

- [ ] Return submits the command
- [ ] Tab completes
- [ ] `↑` / `↓` recall history
- [ ] `←` / `→` move the caret **within the text**, and do not fire `left`/`right` bindings

A failure here means the focus guard in `KeyRouting` is mis-ordered.

- [ ] **Step 5: The Esc ladder (#163 / #166 / #235)**

- [ ] Esc dismisses an open sheet/panel/popover
- [ ] Esc exits an active Move / Design / Measure mode
- [ ] Esc two-stage clears the selection when no mode is active

- [ ] **Step 6: Sheets and modals**

- [ ] Timeline panel's Cancel (Esc) and default (Return) buttons
- [ ] What's New modal's default (Return) button

- [ ] **Step 7: Newly-live PyMOL defaults (behavior change by design)**

With **no** `~/.raymolrc`, viewport focused:

- [ ] `left` / `right` step movie frames
- [ ] `pgup` / `pgdn` change scenes
- [ ] `home` zooms all
- [ ] None of the above fire while the command line is focused (except `pgup`/`pgdn`/`home`, which have no command-line meaning and are expected to fire)

- [ ] **Step 8: Open the PR**

Push the branch and open a PR into `master` (never push to `master` directly). Body: link `#258`, paste the checklist above with results, and call out the two intentional behavior changes — the 125 defaults going live, and `⌃D` being shadowable by a user's rc.

```bash
git push -u origin HEAD
gh pr create -R javierbq/RayMol --base master --title "fix(keys): dispatch cmd.set_key bindings on macOS (#258)" --body-file /tmp/pr-258.md
```

---

## Self-Review

**Spec coverage:** Classifier → Task 1. Bridge + engine → Task 2. Monitor + focus detection → Task 4. Shadow audit → Task 3. All four policy decisions land: full parity is inherent (the 125 defaults are already in `key_mappings`, so dispatch lights them up — verified in Task 6 step 7); the arrow/focus rule is Task 1 step 3 rule 2 with tests; the conflict rule is the consume-iff-fired return in Task 4 step 3, gated by Task 6 step 2; ⌘ pass-through is rule 1. Both spec non-goals are respected — no wizard `do_key` wiring, no shortcut GUI. The full regression checklist maps 1:1 onto Task 6 steps 2–7.

**Placeholder scan:** No TBDs. Every code step carries real code; every test step carries real assertions; every run step carries a real command with an expected result.

**Type consistency:** `KeyRouting.token(keyCode:charactersIgnoringModifiers:modifiers:textFieldFocused:) -> String?` is identical in Task 1's implementation, Task 1's tests, and Task 4's call site. `invokeKeyBinding(_:) -> Bool` matches across Task 2's implementation, Task 2's tests, and Task 4. `PyMOLBridge_InvokeKey(const char *) -> int` matches header, implementation, and Swift call. `audit_shadowed(has_design=…, _self=…)` matches Task 3's implementation, its tests, and Task 4's Python one-liner.

**One deviation from the spec, deliberate:** the spec's rule 2 says unmodified arrows yield to a focused text field; the plan's tests additionally pin down that non-arrow specials (`pgup`, `home`, F-keys) *do* dispatch while focused, since they have no command-line meaning. This is the spec's intent made explicit, not a change — but it is a behavior worth a reviewer's eye, so it is called out in Task 6 step 7's last item.
