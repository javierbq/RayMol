import XCTest
import AppKit
@testable import RayMol

/// Coverage for the console log's text model — the half of #406 that can be
/// tested without a mouse.
///
/// The bug: the log rendered one SwiftUI `Text` per line, and
/// `.textSelection(.enabled)` scopes a selection to a single text view, so a
/// drag could never reach past the line it started on and ⌘C could only ever
/// copy that one line. The fix backs the log with one `NSTextView`, which turns
/// "append a line" into an edit against existing text instead of a rebuild —
/// and an edit can get the selection wrong in ways a rebuild cannot.
final class ConsoleLogTests: XCTestCase {

    private let attributes: [NSAttributedString.Key: Any] =
        [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]

    // MARK: - Planning edits

    /// First fill: nothing on screen yet, so everything is new.
    func testFirstFillReplacesTheWholeDocument() {
        XCTAssertEqual(ConsoleLogText.plan(previous: [], current: ["one", "two"]),
                       .replace("one\ntwo"))
    }

    /// The common case, and the one worth protecting: a new output line must be
    /// an APPEND, because appending is what leaves an in-progress selection and
    /// the scroll position alone.
    func testNewLineAppendsRatherThanRebuilding() {
        XCTAssertEqual(ConsoleLogText.plan(previous: ["one", "two"],
                                           current: ["one", "two", "three"]),
                       .append("\nthree"))
    }

    func testUnchangedLogIsNoEdit() {
        XCTAssertEqual(ConsoleLogText.plan(previous: ["one"], current: ["one"]), .none)
    }

    /// PyMOLEngine caps `feedbackLog` at 400 lines by dropping from the FRONT,
    /// so past the cap every new line both trims and appends. Treating that as a
    /// plain append would duplicate the surviving text; treating it as a full
    /// rebuild would drop the user's selection on every single line of output.
    func testCapTrimsTheFrontAndAppendsTheTail() {
        let update = ConsoleLogText.plan(previous: ["one", "two", "three"],
                                         current: ["two", "three", "four"])
        // "one\n" — the dropped line plus its separator.
        XCTAssertEqual(update, .trimThenAppend(dropCharacters: 4, append: "\nfour"))
    }

    /// Repeated lines are ordinary in a console ("PyMOL>fetch 1ubq" twice), and
    /// they are exactly what a naive scan for the overlap gets wrong.
    func testRepeatedLinesPickTheLongestRealOverlap() {
        let update = ConsoleLogText.plan(previous: ["a", "b", "b"],
                                         current: ["b", "b", "c"])
        XCTAssertEqual(update, .trimThenAppend(dropCharacters: 2, append: "\nc"))
    }

    /// Clear Session empties the log.
    func testClearedLogIsReplacedWithNothing() {
        XCTAssertEqual(ConsoleLogText.plan(previous: ["one", "two"], current: []),
                       .replace(""))
    }

    /// Nothing in common — a rebuild is the only correct edit.
    func testUnrelatedLogIsRebuilt() {
        XCTAssertEqual(ConsoleLogText.plan(previous: ["one"], current: ["two", "three"]),
                       .replace("two\nthree"))
    }

    // MARK: - Applying edits

    /// End to end, against a real text view: the log accumulates the same text a
    /// rebuild would produce, one edit at a time.
    func testAppliedEditsMatchARebuild() {
        let textView = makeTextView()
        var rendered: [String] = []
        for entries in [["one"], ["one", "two"], ["one", "two", "three"],
                        ["two", "three", "four"], []] {
            ConsoleLogText.apply(ConsoleLogText.plan(previous: rendered, current: entries),
                                 to: textView, attributes: attributes)
            rendered = entries
            XCTAssertEqual(textView.string, ConsoleLogText.text(for: entries),
                           "incremental edits drifted from the log contents")
        }
    }

    /// THE issue, as close as a test can get to it: with the whole log selected,
    /// the copy that ⌘C routes through (CopyRouting sends this exact selector)
    /// must put every line on the pasteboard, line breaks intact — not just the
    /// one line the old per-`Text` rendering could select.
    @MainActor
    func testSelectAllThenCopyYieldsEveryLine() {
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }

        let textView = makeTextView()
        ConsoleLogText.apply(
            ConsoleLogText.plan(previous: [], current: ["PyMOL>fetch 1ubq",
                                                        " Executive: object \"1ubq\" created.",
                                                        "PyMOL>color cyan"]),
            to: textView, attributes: attributes)

        textView.selectAll(nil)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: textView, from: nil))

        XCTAssertEqual(NSPasteboard.general.string(forType: .string),
                       "PyMOL>fetch 1ubq\n Executive: object \"1ubq\" created.\nPyMOL>color cyan",
                       "⌘C must copy the whole selection across lines, line breaks preserved")
    }

    /// A selection that spans lines has to survive the log filling up, or the
    /// highlight silently slides onto different text mid-drag once the 400-line
    /// cap starts trimming.
    func testSelectionSurvivesACapTrim() {
        let textView = makeTextView()
        ConsoleLogText.apply(.replace("one\ntwo\nthree"), to: textView, attributes: attributes)
        // "two\nthree" — a two-line selection, the thing #406 makes possible.
        textView.setSelectedRange(NSRange(location: 4, length: 9))

        ConsoleLogText.apply(ConsoleLogText.plan(previous: ["one", "two", "three"],
                                                 current: ["two", "three", "four"]),
                             to: textView, attributes: attributes)

        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()),
                       "two\nthree", "the selection must still cover the same text")
    }

    /// The trim can also eat into the selection. What is gone is gone; what
    /// remains must stay selected rather than the range going stale (or out of
    /// bounds, which throws).
    func testSelectionClippedByATrimKeepsWhatSurvived() {
        XCTAssertEqual(ConsoleLogText.shiftSelection(NSRange(location: 1, length: 5), by: 3),
                       NSRange(location: 0, length: 3))
        XCTAssertEqual(ConsoleLogText.shiftSelection(NSRange(location: 10, length: 5), by: 4),
                       NSRange(location: 6, length: 5))
        XCTAssertEqual(ConsoleLogText.shiftSelection(NSRange(location: 0, length: 2), by: 9),
                       NSRange(location: 0, length: 0))
        // An empty selection (just a caret) must not gain a length.
        XCTAssertEqual(ConsoleLogText.shiftSelection(NSRange(location: 3, length: 0), by: 9),
                       NSRange(location: 0, length: 0))
    }

    // MARK: - Text view configuration

    /// Two properties the rest of the app depends on, neither of them visible:
    /// selectable is what makes ⌘C have anything to copy, and NOT editable is
    /// what keeps ContentView's `textFocusFlags()` from reading a focused
    /// console as "the user is typing" — which would strip arrows, home, end and
    /// the ctrl-letter chords from PyMOL's key bindings while the log had focus.
    func testLogTextViewIsSelectableButNotEditable() {
        let textView = makeTextView()
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isFieldEditor)
        XCTAssertTrue(textView.responds(to: #selector(NSText.copy(_:))),
                      "the log must handle the selector CopyRouting offers ⌘C to")
    }

    // MARK: - Helpers

    private func makeTextView() -> NSTextView {
        let scrollView = ConsoleLogText.makeScrollView()
        guard let textView = scrollView.documentView as? NSTextView else {
            XCTFail("the console scroll view must be backed by an NSTextView")
            return NSTextView()
        }
        return textView
    }
}
