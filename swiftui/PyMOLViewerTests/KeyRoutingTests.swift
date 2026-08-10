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
