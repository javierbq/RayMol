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

    /// The four arrow key codes.
    private static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    /// The 14 macOS emacs-style control-letter text-editing chords that must
    /// yield to an active text field. CTRL-W and CTRL-G are not in this set.
    /// Compared case-insensitively against charactersIgnoringModifiers.
    private static let textEditingCtrlChars: Set<Character> =
        ["a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "v", "y"]

    /// Classifies an NSEvent key-down into a PyMOL key token, or returns nil
    /// meaning "pass the event through untouched".
    ///
    /// Two separate focus booleans implement a two-tier yield policy designed to
    /// protect both non-US keyboard users and text-editing workflows:
    ///
    /// **Tier A — yield whenever `textFieldFocused` (content irrelevant):**
    ///   • `ALT-<letter>` and `ALT-<digit>` → nil.
    ///     On macOS, Option is the compose modifier: German `@`=⌥L, `[`=⌥5,
    ///     `]`=⌥6, `{`=⌥8, `}`=⌥9, `|`=⌥7; Spanish `|`=⌥1, `@`=⌥2, `#`=⌥3.
    ///     PyMOL's defaults bind every `ALT-A…Z`/`ALT-0…9` to editor commands
    ///     (`editor.attach_amino_acid`, `attach_fragment`) that create objects and
    ///     enter edit mode when pk1 is absent. Without this guard a German user
    ///     typing `@script.pml` would spawn a `leu` object. Upstream PyMOL hit
    ///     the same problem and patched one symptom (`layer1/Ortho.cpp:836`).
    ///   • `CTSH-<letter>` → nil.
    ///     ⌃⇧A/E/F/B/N/P are macOS extend-selection chords; PyMOL binds many of
    ///     those (`CTSH-A` → `redo`, `CTSH-N` → `replace N,4,3`, etc.).
    ///
    /// **Tier B — yield when `textEditingActive` (field focused AND non-empty):**
    ///   • ANY arrow key regardless of modifiers → nil.
    ///     ⌥← / ⌥→ are word-movement, ⇧← extends selection; every modified
    ///     arrow is a text-navigation gesture while editing.
    ///   • ANY `home`/`end` regardless of modifiers → nil.
    ///     ⇧Home extends selection; these have no binding meaning mid-typing.
    ///   • `CTRL-<A B D E F H K L N O P T V Y>` with no Option → nil.
    ///     The macOS emacs-style editing chords (begin/end of line, delete, etc.).
    ///
    /// **Never yield** (no text-field meaning at any time):
    ///   `pgup`, `pgdn`, `insert`, `F1`–`F12` — these dispatch even mid-typing.
    ///
    /// - Parameters:
    ///   - textFieldFocused: An editable text field (or its field editor) is
    ///     currently first responder, regardless of content. Drives Tier A.
    ///   - textEditingActive: `textFieldFocused` AND the field is non-empty.
    ///     Drives Tier B. Always false when `textFieldFocused` is false.
    static func token(keyCode: UInt16,
                      charactersIgnoringModifiers: String?,
                      modifiers: NSEvent.ModifierFlags,
                      textFieldFocused: Bool,
                      textEditingActive: Bool) -> String? {
        // 1. ⌘ belongs to the macOS menus. set_key has no CMD modifier, so an
        //    event carrying ⌘ can never be ours.
        if modifiers.contains(.command) { return nil }

        let ctrl = modifiers.contains(.control)
        let alt = modifiers.contains(.option)
        let shift = modifiers.contains(.shift)

        // 2. Tier A: yield unconditionally while any editable field is focused,
        //    because these combos produce literal characters on non-US keyboards
        //    OR map to destructive PyMOL commands (see doc-comment above).
        if textFieldFocused {
            // ALT-<letter> / ALT-<digit>: compose modifier on non-US keyboards.
            if alt, !ctrl, !shift,
               let ch = charactersIgnoringModifiers, ch.count == 1,
               let scalar = ch.unicodeScalars.first,
               scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                return nil
            }
            // CTSH-<letter>: extend-selection chords on macOS (⌃⇧A, ⌃⇧E, …).
            if ctrl, !alt, shift,
               let ch = charactersIgnoringModifiers, ch.count == 1,
               let scalar = ch.unicodeScalars.first, scalar.isASCII,
               CharacterSet.letters.contains(scalar) {
                return nil
            }
        }

        // 3. Tier B: yield while actively editing (field focused AND non-empty).
        if textEditingActive {
            // 3a. ANY arrow — caret movement, word-jump (⌥←/→), or extend
            //     selection (⇧←/→). Every modified arrow is a text gesture.
            if arrowKeys.contains(keyCode) { return nil }
            // 3b. ANY home/end — caret-to-start / caret-to-end, and ⇧Home/End
            //     for extend-selection. All variants belong to the text field.
            if keyCode == 115 || keyCode == 119 { return nil }
            // 3c. Bare Control-letter text-editing chords (emacs-style, no Option,
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

        // 4. Special keys carry an optional modifier prefix.
        if let name = specialKeys[keyCode] {
            guard let prefix = modifierPrefix(ctrl: ctrl, alt: alt, shift: shift) else {
                return nil
            }
            return prefix.isEmpty ? name : prefix + "-" + name
        }

        // 5. Letters and digits are only ours when carrying CTRL or ALT.
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
