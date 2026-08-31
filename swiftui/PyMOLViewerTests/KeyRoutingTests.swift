import XCTest
import AppKit
import SwiftUI
@testable import RayMol

/// Coverage for KeyRouting.token — the pure NSEvent-facts → PyMOL key-token
/// classifier behind cmd.set_key dispatch (#258).
///
/// The NSEvent monitor itself lives in ContentView and cannot be unit-tested
/// (a test cannot press a key), so ALL the routing policy lives here in a pure
/// function and is pinned down here instead.
final class KeyRoutingTests: XCTestCase {

    // Convenience: classify with no modifiers, neither field focused nor editing.
    //   focused: true  → textFieldFocused only (empty field, Tier A applies)
    //   editing: true  → textFieldFocused AND textEditingActive (Tier A+B apply)
    private func tok(_ keyCode: UInt16,
                     _ chars: String? = nil,
                     _ mods: NSEvent.ModifierFlags = [],
                     focused: Bool = false,
                     editing: Bool = false) -> String? {
        // editing implies focused
        KeyRouting.token(keyCode: keyCode,
                         charactersIgnoringModifiers: chars,
                         modifiers: mods,
                         textFieldFocused: focused || editing,
                         textEditingActive: editing)
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

    /// modifier_keys has no token for ALT+SHFT or CTRL+ALT, so those pass
    /// through rather than being guessed at. Option+Shift+arrow in particular is
    /// a macOS text-selection gesture and must never fire an ALT- binding.
    func testUnrepresentableModifierCombosPassThrough() {
        XCTAssertNil(tok(116, nil, [.option, .shift]))     // ALT+SHFT special
        XCTAssertNil(tok(116, nil, [.control, .option]))   // CTRL+ALT special
        XCTAssertNil(tok(123, nil, [.option, .shift]))     // Option+Shift+left
        XCTAssertNil(tok(17, "t", [.option, .shift]))      // ALT+SHFT letter
        XCTAssertNil(tok(17, "t", [.control, .option]))    // CTRL+ALT letter
    }

    // MARK: - Tier A: yield when field is focused (even if empty)

    /// ALT-<letter> must yield whenever an editable field is focused, even with
    /// an EMPTY field (textEditingActive = false). This is the Critical bug:
    /// on non-US keyboards Option is the compose modifier — ⌥L = `@` (German),
    /// ⌥5 = `[`, ⌥7 = `|` — and PyMOL's ALT-A…Z defaults map to
    /// editor.attach_amino_acid which creates objects with no pk1.
    func testAltLetterYieldsWhenFieldFocusedEvenEmpty() {
        // focused=true, editing=false (empty field — Tier A, not Tier B)
        XCTAssertNil(tok(0,  "a", [.option], focused: true))   // ALT-A
        XCTAssertNil(tok(11, "b", [.option], focused: true))   // ALT-B
        XCTAssertNil(tok(8,  "c", [.option], focused: true))   // ALT-C
        XCTAssertNil(tok(37, "l", [.option], focused: true))   // ALT-L (German @)
    }

    /// ALT-<digit> must similarly yield when focused (German `[`=⌥5, `}`=⌥9, …).
    func testAltDigitYieldsWhenFieldFocusedEvenEmpty() {
        XCTAssertNil(tok(18, "1", [.option], focused: true))   // ALT-1
        XCTAssertNil(tok(23, "5", [.option], focused: true))   // ALT-5
        XCTAssertNil(tok(25, "9", [.option], focused: true))   // ALT-9
    }

    /// CTSH-<letter> must yield when focused (even empty): ⌃⇧A/E/F/B/N/P are
    /// macOS extend-selection chords and PyMOL binds them to destructive ops
    /// (CTSH-A → redo, CTSH-N → replace N,4,3, etc.).
    func testCtrlShiftLetterYieldsWhenFieldFocusedEvenEmpty() {
        XCTAssertNil(tok(0,  "a", [.control, .shift], focused: true))   // CTSH-A
        XCTAssertNil(tok(14, "e", [.control, .shift], focused: true))   // CTSH-E
        XCTAssertNil(tok(3,  "f", [.control, .shift], focused: true))   // CTSH-F
        XCTAssertNil(tok(11, "b", [.control, .shift], focused: true))   // CTSH-B
        XCTAssertNil(tok(45, "n", [.control, .shift], focused: true))   // CTSH-N
    }

    // MARK: - Tier B: yield when actively editing (focused AND non-empty)

    /// Unmodified arrows yield while editing — they are caret movement / history.
    func testUnmodifiedArrowsYieldWhileEditing() {
        XCTAssertNil(tok(123, nil, [], editing: true))
        XCTAssertNil(tok(124, nil, [], editing: true))
        XCTAssertNil(tok(125, nil, [], editing: true))
        XCTAssertNil(tok(126, nil, [], editing: true))
    }

    /// MODIFIED arrows also yield while editing — ⌥←/⌥→ = word-movement,
    /// ⇧← = extend selection. These are text gestures, not bindings.
    func testModifiedArrowsYieldWhileEditing() {
        XCTAssertNil(tok(123, nil, [.option], editing: true))   // ⌥← word-left
        XCTAssertNil(tok(124, nil, [.option], editing: true))   // ⌥→ word-right
        XCTAssertNil(tok(123, nil, [.shift], editing: true))    // ⇧← extend sel
        XCTAssertNil(tok(126, nil, [.shift], editing: true))    // ⇧↑ extend sel
        XCTAssertNil(tok(123, nil, [.control], editing: true))  // ⌃← (line start on some layouts)
    }

    /// Unmodified Home and End yield while editing — caret-to-start / caret-to-end.
    func testUnmodifiedHomeEndYieldWhileEditing() {
        XCTAssertNil(tok(115, nil, [], editing: true))   // home
        XCTAssertNil(tok(119, nil, [], editing: true))   // end
    }

    /// MODIFIED Home/End also yield while editing — ⇧Home extends selection.
    func testModifiedHomeEndYieldsWhileEditing() {
        XCTAssertNil(tok(115, nil, [.shift], editing: true))    // ⇧Home
        XCTAssertNil(tok(119, nil, [.shift], editing: true))    // ⇧End
        XCTAssertNil(tok(115, nil, [.control], editing: true))  // ⌃Home
    }

    /// The 14 macOS emacs-style CTRL-letter text-editing chords yield while editing.
    func testTextEditingCtrlLettersYieldWhileEditing() {
        // A, E = begin/end of line; H = delete-backward; T = transpose; D = delete-fwd
        XCTAssertNil(tok(0,  "a", [.control], editing: true))   // CTRL-A
        XCTAssertNil(tok(14, "e", [.control], editing: true))   // CTRL-E
        XCTAssertNil(tok(4,  "h", [.control], editing: true))   // CTRL-H
        XCTAssertNil(tok(17, "t", [.control], editing: true))   // CTRL-T
        XCTAssertNil(tok(2,  "d", [.control], editing: true))   // CTRL-D
        XCTAssertNil(tok(11, "b", [.control], editing: true))   // CTRL-B
        XCTAssertNil(tok(3,  "f", [.control], editing: true))   // CTRL-F
        XCTAssertNil(tok(40, "k", [.control], editing: true))   // CTRL-K
        XCTAssertNil(tok(37, "l", [.control], editing: true))   // CTRL-L
        XCTAssertNil(tok(45, "n", [.control], editing: true))   // CTRL-N
        XCTAssertNil(tok(31, "o", [.control], editing: true))   // CTRL-O
        XCTAssertNil(tok(35, "p", [.control], editing: true))   // CTRL-P
        XCTAssertNil(tok(9,  "v", [.control], editing: true))   // CTRL-V
        XCTAssertNil(tok(16, "y", [.control], editing: true))   // CTRL-Y
    }

    /// CTRL-W and CTRL-G are NOT text-editing chords and still dispatch while editing.
    func testNonTextEditingCtrlLettersDispatchWhileEditing() {
        XCTAssertEqual(tok(13, "w", [.control], editing: true), "CTRL-W")
        XCTAssertEqual(tok(5,  "g", [.control], editing: true), "CTRL-G")
    }

    /// pgup, pgdn, insert, and F-keys have no text-field meaning and dispatch
    /// even when both flags are true — these are how user bindings stay reachable
    /// while the command line holds focus.
    func testPageKeysInsertAndFKeysDispatchWhenBothFlagsTrue() {
        XCTAssertEqual(tok(116, nil, [], editing: true), "pgup")
        XCTAssertEqual(tok(121, nil, [], editing: true), "pgdn")
        XCTAssertEqual(tok(114, nil, [], editing: true), "insert")
        XCTAssertEqual(tok(122, nil, [], editing: true), "F1")
        XCTAssertEqual(tok(120, nil, [], editing: true), "F2")
        XCTAssertEqual(tok(111, nil, [], editing: true), "F12")
    }

    // MARK: - Both flags false: everything dispatches as usual

    /// When neither flag is set (viewport has focus or field is empty), arrows
    /// and home/end dispatch normally — no keys are stolen.
    func testSpecialKeysDispatchWhenBothFlagsFalse() {
        XCTAssertEqual(tok(123, nil, [], focused: false), "left")
        XCTAssertEqual(tok(124, nil, [], focused: false), "right")
        XCTAssertEqual(tok(125, nil, [], focused: false), "down")
        XCTAssertEqual(tok(126, nil, [], focused: false), "up")
        XCTAssertEqual(tok(115, nil, [], focused: false), "home")
        XCTAssertEqual(tok(119, nil, [], focused: false), "end")
    }

    /// When flags are false, ALT letters and CTSH letters dispatch normally.
    func testAltAndCtshDispatchWhenBothFlagsFalse() {
        XCTAssertEqual(tok(0,  "a", [.option]),              "ALT-A")
        XCTAssertEqual(tok(18, "1", [.option]),              "ALT-1")
        XCTAssertEqual(tok(11, "b", [.control, .shift]),     "CTSH-B")
    }

    /// When the field is empty (focused=true, editing=false), Tier A still
    /// applies but Tier B does NOT — arrows and CTRL letters dispatch.
    func testArrowsAndCtrlLettersDispatchWhenFocusedButEmpty() {
        // Tier B (arrows/home/end/ctrl-letters) requires editing=true
        XCTAssertEqual(tok(123, nil, [], focused: true), "left")
        XCTAssertEqual(tok(115, nil, [], focused: true), "home")
        XCTAssertEqual(tok(0,  "a", [.control], focused: true), "CTRL-A")
        XCTAssertEqual(tok(17, "t", [.control], focused: true), "CTRL-T")
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

    // MARK: - Selection-mode cycling (Tab / Shift+Tab, #319)

    /// Tab must never yield a set_key token, whatever the modifiers or focus —
    /// otherwise the cycling monitor and the cmd.set_key monitor would both act
    /// on the same event.
    func testTabNeverYieldsAKeyToken() {
        for mods: NSEvent.ModifierFlags in [[], [.shift], [.control], [.option],
                                            [.command], [.control, .shift]] {
            XCTAssertNil(tok(48, "\t", mods))
            XCTAssertNil(tok(48, "\t", mods, focused: true))
            XCTAssertNil(tok(48, "\t", mods, editing: true))
        }
    }

    func testTabCyclesForwardAndShiftTabBack() {
        XCTAssertEqual(KeyRouting.selectionModeStep(keyCode: 48, modifiers: [],
                                                    textEditingActive: false), 1)
        XCTAssertEqual(KeyRouting.selectionModeStep(keyCode: 48, modifiers: [.shift],
                                                    textEditingActive: false), -1)
    }

    /// ⌘⇥ is the app switcher and ⌃⇥ switches tabs — only bare Tab is ours.
    func testModifiedTabPassesThrough() {
        for mods: NSEvent.ModifierFlags in [[.command], [.control], [.option],
                                            [.command, .shift], [.control, .shift],
                                            [.option, .shift]] {
            XCTAssertNil(KeyRouting.selectionModeStep(keyCode: 48, modifiers: mods,
                                                      textEditingActive: false))
        }
    }

    /// Mid-edit, Tab belongs to the field (the command line completes with it).
    /// A focused-but-empty field is NOT mid-edit and still cycles — the command
    /// line holds focus indefinitely once clicked (#73).
    func testTabPassesThroughWhileEditingOnly() {
        XCTAssertNil(KeyRouting.selectionModeStep(keyCode: 48, modifiers: [],
                                                  textEditingActive: true))
        XCTAssertNil(KeyRouting.selectionModeStep(keyCode: 48, modifiers: [.shift],
                                                  textEditingActive: true))
        XCTAssertEqual(KeyRouting.selectionModeStep(keyCode: 48, modifiers: [],
                                                    textEditingActive: false), 1)
    }

    func testNonTabKeysNeverCycle() {
        for keyCode: UInt16 in [53, 36, 51, 123, 17, 48 + 1] {
            XCTAssertNil(KeyRouting.selectionModeStep(keyCode: keyCode, modifiers: [],
                                                      textEditingActive: false))
        }
    }

    /// The mode ring wraps both ways and survives an out-of-range setting value.
    func testSelectionModeRingWraps() {
        let n = SelectionModeMenu.modes.count
        XCTAssertEqual(n, 7)
        XCTAssertEqual((0..<n).map { SelectionModeMenu.nextMode(from: $0, forward: true) },
                       [1, 2, 3, 4, 5, 6, 0])
        XCTAssertEqual((0..<n).map { SelectionModeMenu.nextMode(from: $0, forward: false) },
                       [6, 0, 1, 2, 3, 4, 5])
        XCTAssertTrue((0..<n).contains(SelectionModeMenu.nextMode(from: 42, forward: true)))
        XCTAssertTrue((0..<n).contains(SelectionModeMenu.nextMode(from: -3, forward: false)))
    }
}

/// AppShortcuts (#360, #361) — the one table behind every registered shortcut
/// and every hint the user sees. In the same file as KeyRoutingTests because the
/// two contracts interlock: KeyRouting's pass-through rules are what make the
/// table's ⌘/⌃ split safe.
final class AppShortcutsTests: XCTestCase {

    /// Two commands sharing a key equivalent would fight silently; the table
    /// exists to make that impossible to miss.
    func testNoDuplicateBindings() {
        XCTAssertEqual(Set(AppShortcuts.all).count, AppShortcuts.all.count,
                       "AppShortcuts.all contains a duplicate key equivalent")
    }

    /// The symbol hints tooltips show, in macOS glyph order (⌃⌥⇧⌘).
    func testHintSymbols() {
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.moveTool), "⌃M")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.measureTool), "⌃E")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.designTool), "⌃D")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.predictTool), "⌃P")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.binderDesignTool), "⌃B")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.boxSelect), "⌃S")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.consolePane), "⌘1")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.sequencePane), "⌘2")
        XCTAssertEqual(AppShortcuts.hint(AppShortcuts.sidePanel), "⌘3")
        XCTAssertEqual(
            AppShortcuts.hint(KeyboardShortcut("k", modifiers: [.command, .shift, .option, .control])),
            "⌃⌥⇧⌘K")
    }

    /// Every ⌃-letter shortcut must be mirrored in the Python launch audit
    /// (modules/pymol/raymol_keys.py APP_SHORTCUTS), which warns when a
    /// ~/.raymolrc binding shadows a menu command. Pin the set here so a new ⌃
    /// entry fails this test until the audit table learns it. ⌘ entries need no
    /// mirror — KeyRouting passes ⌘ straight through to the menus.
    func testControlShortcutsMatchPythonAuditTable() {
        let ctrl = AppShortcuts.all.filter { $0.modifiers.contains(.control) }
        XCTAssertEqual(Set(ctrl.map { String($0.key.character) }),
                       ["m", "e", "d", "p", "b", "s"])
    }

    /// The pane toggles are one plain-⌘ family (#361): immune to raymolrc
    /// shadowing, and consistent with each other as the issue asks.
    func testPaneTogglesAreCommandFamily() {
        for s in [AppShortcuts.consolePane, AppShortcuts.sequencePane, AppShortcuts.sidePanel] {
            XCTAssertEqual(s.modifiers, .command)
        }
    }
}
