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

    // Convenience: classify with no modifiers and not editing.
    // `editing: true` means a text field is focused AND non-empty.
    private func tok(_ keyCode: UInt16,
                     _ chars: String? = nil,
                     _ mods: NSEvent.ModifierFlags = [],
                     editing: Bool = false) -> String? {
        KeyRouting.token(keyCode: keyCode,
                         charactersIgnoringModifiers: chars,
                         modifiers: mods,
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

    // MARK: - Focus policy (textEditingActive: field focused AND non-empty)

    /// Unmodified arrows yield while editing — they are caret movement / history.
    func testUnmodifiedArrowsYieldWhileEditing() {
        XCTAssertNil(tok(123, nil, [], editing: true))
        XCTAssertNil(tok(124, nil, [], editing: true))
        XCTAssertNil(tok(125, nil, [], editing: true))
        XCTAssertNil(tok(126, nil, [], editing: true))
    }

    /// Unmodified Home and End yield while editing — caret-to-start / caret-to-end.
    func testHomeEndYieldWhileEditing() {
        XCTAssertNil(tok(115, nil, [], editing: true))   // home
        XCTAssertNil(tok(119, nil, [], editing: true))   // end
    }

    /// Modified Home/End are not text-navigation gestures, so they still dispatch.
    func testModifiedHomeEndDispatchWhileEditing() {
        XCTAssertEqual(tok(115, nil, [.shift], editing: true), "SHFT-home")
        XCTAssertEqual(tok(119, nil, [.control], editing: true), "CTRL-end")
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

    /// pgup, pgdn, and F-keys have no text-field meaning and dispatch while editing.
    func testPageKeysAndFKeysDispatchWhileEditing() {
        XCTAssertEqual(tok(116, nil, [], editing: true), "pgup")
        XCTAssertEqual(tok(121, nil, [], editing: true), "pgdn")
        XCTAssertEqual(tok(122, nil, [], editing: true), "F1")
    }

    /// When the field is empty (textEditingActive: false), arrows and home/end
    /// dispatch normally — the empty command line does not steal keys.
    func testArrowsAndHomeEndDispatchWhenNotEditing() {
        XCTAssertEqual(tok(123, nil, [], editing: false), "left")
        XCTAssertEqual(tok(124, nil, [], editing: false), "right")
        XCTAssertEqual(tok(125, nil, [], editing: false), "down")
        XCTAssertEqual(tok(126, nil, [], editing: false), "up")
        XCTAssertEqual(tok(115, nil, [], editing: false), "home")
        XCTAssertEqual(tok(119, nil, [], editing: false), "end")
    }

    /// When the field is empty, CTRL text-editing letters dispatch normally.
    func testTextEditingCtrlLettersDispatchWhenNotEditing() {
        XCTAssertEqual(tok(0,  "a", [.control], editing: false), "CTRL-A")
        XCTAssertEqual(tok(17, "t", [.control], editing: false), "CTRL-T")
        XCTAssertEqual(tok(4,  "h", [.control], editing: false), "CTRL-H")
    }

    /// A MODIFIED arrow is not a caret movement, so it dispatches regardless of
    /// editing state.
    func testModifiedArrowsDispatchWhileEditing() {
        XCTAssertEqual(tok(123, nil, [.control], editing: true), "CTRL-left")
        XCTAssertEqual(tok(123, nil, [.shift], editing: true), "SHFT-left")
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
