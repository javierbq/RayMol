import XCTest
import AppKit
@testable import RayMol

/// Coverage for CopyRouting.perform — the ⌘C arbitration between "copy the
/// selected text" and "copy the viewport image" (#287).
///
/// The bug: "Copy Image to Clipboard" was bound to ⌘C unconditionally at the
/// File-menu level, so it always beat the console log's `.textSelection`
/// copy and overwrote the pasteboard with a rendered viewport PNG.
final class CopyRoutingTests: XCTestCase {

    /// A private pasteboard so the policy tests never touch the developer's
    /// real clipboard.
    private var pb: NSPasteboard!

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: NSPasteboard.Name("io.raymol.tests.copyRouting"))
        pb.clearContents()
    }

    override func tearDown() {
        pb.releaseGlobally()
        pb = nil
        super.tearDown()
    }

    // MARK: - Policy

    /// THE bug: when the focused responder really copies text, ⌘C must stop
    /// there and must NOT go on to render the viewport image over it.
    func testCopiedTextSuppressesImageFallback() {
        var imageCopied = false
        let copiedText = CopyRouting.perform(
            pasteboard: pb,
            sendCopy: { [pb] in
                pb!.clearContents()
                pb!.setString("SELECTED", forType: .string)
                return true
            },
            copyImage: { imageCopied = true })

        XCTAssertTrue(copiedText)
        XCTAssertFalse(imageCopied,
                       "⌘C with a live text selection must not copy the viewport image")
        XCTAssertEqual(pb.string(forType: .string), "SELECTED",
                       "the selected text must survive on the pasteboard")
    }

    /// Nothing in the responder chain claims `copy:` (the viewport has focus) —
    /// the existing image-copy behavior must be untouched.
    func testNoTextResponderFallsBackToImage() {
        var imageCopied = false
        let copiedText = CopyRouting.perform(pasteboard: pb,
                                             sendCopy: { false },
                                             copyImage: { imageCopied = true })

        XCTAssertFalse(copiedText)
        XCTAssertTrue(imageCopied, "⌘C with no text selection must still copy the image")
    }

    /// A focused-but-unselected text field still "handles" `copy:` while writing
    /// nothing. Claiming the action is therefore not proof of a copy — without
    /// the pasteboard check ⌘C would silently do nothing whenever the command
    /// line held focus with no selection.
    func testResponderClaimsCopyButWritesNothingFallsBackToImage() {
        var imageCopied = false
        let copiedText = CopyRouting.perform(pasteboard: pb,
                                             sendCopy: { true },
                                             copyImage: { imageCopied = true })

        XCTAssertFalse(copiedText)
        XCTAssertTrue(imageCopied, "an empty selection must not swallow ⌘C")
    }

    /// Verified against the real app: with the command line focused and nothing
    /// selected, `copy:` DECLARES pasteboard types and writes no data. That
    /// clears the pasteboard and bumps `changeCount`, so a changeCount-only
    /// check reads it as a successful text copy, skips the image fallback, and
    /// leaves the user with an EMPTY clipboard — ⌘C appearing to do nothing.
    /// Only real content on the pasteboard counts as a copy.
    func testResponderThatClearsWithoutWritingFallsBackToImage() {
        pb.setString("previous clipboard contents", forType: .string)

        var imageCopied = false
        let copiedText = CopyRouting.perform(
            pasteboard: pb,
            // Exactly what NSPasteboard.declareTypes does: clears, bumps
            // changeCount, writes nothing.
            sendCopy: { [pb] in
                pb!.declareTypes([.string], owner: nil)
                return true
            },
            copyImage: { imageCopied = true })

        XCTAssertFalse(copiedText, "declaring types without writing is not a copy")
        XCTAssertTrue(imageCopied, "⌘C must not leave an empty clipboard")
    }

    /// The mirror-image trap: if the send is a complete no-op while text from an
    /// EARLIER copy still sits on the pasteboard, a content-only check would
    /// find that stale text and wrongly report a successful copy. The
    /// changeCount guard is what rules this out.
    func testStalePasteboardTextIsNotMistakenForACopy() {
        pb.setString("text copied a while ago", forType: .string)

        var imageCopied = false
        let copiedText = CopyRouting.perform(pasteboard: pb,
                                             sendCopy: { false },
                                             copyImage: { imageCopied = true })

        XCTAssertFalse(copiedText, "stale pasteboard text is not a fresh copy")
        XCTAssertTrue(imageCopied)
    }

    // MARK: - Selector

    /// The policy tests inject `sendCopy`, so they would all pass even if the
    /// real send named the wrong selector — and the wrong one is easy to reach
    /// for: `NSObject.copy()` takes no argument and would be a silent no-op,
    /// making `sendCopy` always report "unhandled" and ⌘C always copy the image.
    ///
    /// A live UI session is needed for the nil-targeted walk (the test host is
    /// never granted key-window status), so this pins the half that can be
    /// checked deterministically: that the selector RayMol sends is the one an
    /// NSText responder implements, and that it copies the selection.
    @MainActor
    func testCopySelectorIsTheOneTextRespondersImplement() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        textView.string = "console line to copy"
        textView.setSelectedRange(NSRange(location: 0, length: 7))   // "console"

        let selector = #selector(NSText.copy(_:))
        XCTAssertTrue(textView.responds(to: selector),
                      "a text responder must implement the selector ⌘C is routed through")

        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSApp.sendAction(selector, to: textView, from: nil))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "console",
                       "the routed selector must copy the selection, not no-op")
    }
}
