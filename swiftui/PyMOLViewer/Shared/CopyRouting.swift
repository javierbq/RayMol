#if os(macOS)
import AppKit

/// Arbitrates ⌘C between the two things it can plausibly mean in RayMol: copy
/// the text the user has selected, or copy the rendered viewport image.
///
/// "Copy Image to Clipboard" carries ⌘C as a File-menu command so the shortcut
/// fires from anywhere in the app. A menu command's key equivalent outranks the
/// responder chain, so before #287 it also beat the console log's
/// `.textSelection(.enabled)` copy — selecting log text and pressing ⌘C pasted
/// a PNG of the viewport. Selection now wins, and the image copy is what ⌘C
/// falls back to.
///
/// The policy lives here, injectable and unit-tested, because the menu command
/// itself cannot be exercised from a test (a test cannot press ⌘C).
enum CopyRouting {

    /// Offers ⌘C to the focused text responder first and copies the viewport
    /// image only if no text actually reached the pasteboard.
    ///
    /// - Parameters:
    ///   - pasteboard: pasteboard to watch for a real write. Injectable so
    ///     tests need not touch the user's clipboard.
    ///   - sendCopy: performs a responder-chain `copy:` and reports whether any
    ///     responder claimed the action.
    ///   - copyImage: the viewport-image fallback.
    /// - Returns: `true` when selected text was copied, `false` when this fell
    ///   through to `copyImage`.
    @discardableResult
    static func perform(pasteboard: NSPasteboard = .general,
                        sendCopy: () -> Bool = CopyRouting.sendCopyToResponderChain,
                        copyImage: () -> Void) -> Bool {
        let before = pasteboard.changeCount
        // Two independent things have to be true before this counts as a copy,
        // and each rules out a failure mode seen in the real app:
        //
        //  • changeCount moved — otherwise a send that did nothing at all would
        //    be "confirmed" by text left on the pasteboard by an earlier copy.
        //
        //  • the pasteboard actually holds text — because a focused text field
        //    with an empty selection DOES handle `copy:`, and handles it by
        //    declaring pasteboard types and writing no data. That clears the
        //    pasteboard and bumps changeCount, so trusting changeCount alone
        //    skips the image fallback and leaves the clipboard EMPTY, making ⌘C
        //    look broken.
        if sendCopy(),
           pasteboard.changeCount != before,
           let copied = pasteboard.string(forType: .string),
           !copied.isEmpty {
            return true
        }
        copyImage()
        return false
    }

    /// Sends the standard nil-targeted `copy:` — the same action Edit ▸ Copy
    /// uses — so any focused text responder (console log selection, command
    /// line, sheet text fields) gets first refusal on ⌘C.
    static func sendCopyToResponderChain() -> Bool {
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }
}
#endif
