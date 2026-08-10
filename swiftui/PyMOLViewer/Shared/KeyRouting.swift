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

    /// The 14 macOS emacs-style control-letter text-editing chords that must
    /// yield to an active text field. CTRL-W and CTRL-G are not in this set.
    /// Compared case-insensitively against charactersIgnoringModifiers.
    private static let textEditingCtrlChars: Set<Character> =
        ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "v", "y"]

    /// `textEditingActive` is true when a text field has focus AND is non-empty
    /// (i.e. the user is actively composing a command). An empty command line
    /// dispatches everything so bindings stay reachable without clicking the
    /// viewport — this mirrors PyMOL's own OrthoArrowsGrabbed rule.
    static func token(keyCode: UInt16,
                      charactersIgnoringModifiers: String?,
                      modifiers: NSEvent.ModifierFlags,
                      textEditingActive: Bool) -> String? {
        // 1. ⌘ belongs to the macOS menus. set_key has no CMD modifier, so an
        //    event carrying ⌘ can never be ours.
        if modifiers.contains(.command) { return nil }

        let ctrl = modifiers.contains(.control)
        let alt = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        // 2. When the user is actively editing text, yield the keys the field
        //    uses for navigation and in-line editing. Modified variants of these
        //    keys are not text-editing gestures, so they still dispatch.
        if textEditingActive {
            // 2a. Unmodified arrows — caret movement and command-line history.
            if arrowKeys.contains(keyCode), !ctrl, !alt, !shift { return nil }
            // 2b. Unmodified Home / End — caret-to-start / caret-to-end.
            if (keyCode == 115 || keyCode == 119), !ctrl, !alt, !shift { return nil }
            // 2c. Bare Control-letter text-editing chords (emacs-style, no Option,
            //     no Shift): A(BOL) B(back) D(del-fwd) E(EOL) F(fwd) H(del-back)
            //     K(kill) L(centre) N(next) O(open) P(prev) T(transpose) V(pgdn)
            //     Y(yank). CTRL-W and CTRL-G are not text-editing keys and still
            //     dispatch.
            if ctrl, !alt, !shift,
               let ch = charactersIgnoringModifiers, ch.count == 1,
               let scalar = ch.unicodeScalars.first, scalar.isASCII,
               textEditingCtrlChars.contains(Character(ch.lowercased())) {
                return nil
            }
        }

        // 3. Special keys carry an optional modifier prefix.
        if let name = specialKeys[keyCode] {
            guard let prefix = modifierPrefix(ctrl: ctrl, alt: alt, shift: shift) else {
                return nil
            }
            return prefix.isEmpty ? name : prefix + "-" + name
        }

        // 4. Letters and digits are only ours when carrying CTRL or ALT.
        //    set_key refuses bare letters and SHFT-<letter> outright, so the
        //    ctrl-or-alt guard also rules those out. Same prefix helper as the
        //    special-key path above, so both agree on what is representable.
        guard ctrl || alt else { return nil }
        guard let prefix = modifierPrefix(ctrl: ctrl, alt: alt, shift: shift),
              !prefix.isEmpty else { return nil }
        guard let ch = charactersIgnoringModifiers, ch.count == 1,
              let scalar = ch.unicodeScalars.first,
              scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) else { return nil }
        return prefix + "-" + ch.uppercased()
    }

    /// PyMOL's modifier prefix for the held combination, or nil when it has no
    /// token at all. modifier_keys is ['', 'SHFT', 'CTRL', 'CTSH', 'ALT'] — it
    /// has no entry for ALT+SHFT or CTRL+ALT, so rather than guess a prefix we
    /// pass those events through. That matters concretely: Option+Shift+arrow is
    /// a macOS text-selection gesture, and degrading it to ALT-left would fire a
    /// binding the user never asked for.
    private static func modifierPrefix(ctrl: Bool, alt: Bool, shift: Bool) -> String? {
        if ctrl && alt { return nil }
        if alt && shift { return nil }
        if alt { return "ALT" }
        if ctrl && shift { return "CTSH" }
        if ctrl { return "CTRL" }
        if shift { return "SHFT" }
        return ""
    }
}
#endif
