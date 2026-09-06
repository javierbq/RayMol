// CommandPanel.swift — Log viewer + command input for PyMOL
// Replaces modules/pymol/appkit_command_panel.py with pure SwiftUI.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CommandPanel: View {
    // When false, the command-input bar is hidden and only the read-only log
    // shows. Used by the iOS App Store "restricted" build (guideline 2.5.2) to
    // remove the user-facing interpreter while keeping feedback visible.
    var showInput: Bool = true

    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var commandText = ""
    @State private var commandHistory: [String] = []
    @State private var historyIndex = -1

    // Terminal look comes from the active theme.
    private var theme: Theme { themeManager.active }
    private var bgColor: Color { theme.panelBackground.color }
    private var logTextColor: Color { theme.terminalText.color }
    private var promptColor: Color { theme.terminalText.color }
    private var termFont: Font { theme.terminalFont.font }

    var body: some View {
        VStack(spacing: 0) {
            // Scrolling log area
            // Theme values, not resolved Colors/Fonts: the macOS log is an
            // AppKit text view and needs NSColor/NSFont (and Equatable specs to
            // tell a theme change from a new log line). See LogView.
            LogView(entries: engine.feedbackLog, textColor: theme.terminalText,
                    font: theme.terminalFont, bg: theme.panelBackground)

            if showInput {
                Divider()
                    .background(Color.gray.opacity(0.4))

                // Command input bar
                HStack(spacing: 4) {
                    Text("RayMol>")
                        .font(termFont)
                        .foregroundColor(promptColor)

                    CommandTextField(
                        text: $commandText,
                        textColor: logTextColor,
                        bgColor: bgColor,
                        fontSize: CGFloat(theme.terminalFont.size),
                        onSubmit: submitCommand,
                        onUpArrow: historyBack,
                        onDownArrow: historyForward,
                        onComplete: { engine.complete($0) }
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(bgColor)
            }
        }
        .background(bgColor)
    }

    // MARK: - Actions

    private func submitCommand() {
        let trimmed = commandText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        commandHistory.append(trimmed)
        historyIndex = commandHistory.count

        engine.feedbackLog.append("RayMol>\(trimmed)")
        engine.runCommand(trimmed)

        commandText = ""
    }

    private func historyBack() {
        guard !commandHistory.isEmpty, historyIndex > 0 else { return }
        historyIndex -= 1
        commandText = commandHistory[historyIndex]
    }

    private func historyForward() {
        guard !commandHistory.isEmpty else { return }
        historyIndex += 1
        if historyIndex < commandHistory.count {
            commandText = commandHistory[historyIndex]
        } else {
            historyIndex = commandHistory.count
            commandText = ""
        }
    }
}

// MARK: - Log View

private struct LogView: View {
    let entries: [String]
    let textColor: RGBA
    let font: FontSpec
    let bg: RGBA

#if os(macOS)

    // One selectable text view for the whole log — see ConsoleTextView (#406).
    var body: some View {
        ConsoleTextView(entries: entries, textColor: textColor, font: font, bg: bg)
    }

#else

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(font.font)
                            .foregroundColor(textColor.color)
                            .textSelection(.enabled)
                            .id(index)
                    }
                    // Stable bottom anchor — scrolling to this always lands at the
                    // very end (scrolling to the last row index was unreliable with
                    // a LazyVStack and left the log pinned at the top).
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .background(bg.color)
            // Swipe the log down to dismiss the keyboard (and peek at output
            // while typing) — complements the command field's Done button.
            .scrollDismissesKeyboard(.interactively)
            // Initial content (the startup banner) is present before this view
            // appears, so no count change fires for it — scroll on appear too.
            .onAppear { scrollToBottom(proxy, animated: false) }
            .onChange(of: entries.count) { _ in scrollToBottom(proxy) }
        }
    }

    private static let bottomID = "LOG_BOTTOM"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Defer one runloop so the newly appended row is laid out before we
        // scroll, otherwise the proxy stops short of the true bottom.
        DispatchQueue.main.async {
            if animated {
                withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

#endif
}

#if os(macOS)

// MARK: - Console log text view (macOS)

/// The console log rendered as ONE selectable `NSTextView` instead of a SwiftUI
/// `Text` per line (#406).
///
/// `.textSelection(.enabled)` scopes a selection to a single text view, so with
/// a `Text` per line a drag could never reach past the line it started on and
/// ⌘C could only ever copy that one line; the `LazyVStack` compounded it by
/// never materialising the scrolled-away rows. A single text view gets
/// multi-line drag selection, ⇧-click, ⌘A and ⌘C for free, and its `copy:` is
/// exactly the responder `CopyRouting` offers ⌘C to before falling back to the
/// viewport image (#287).
///
/// Deliberately non-editable and not a field editor: `ContentView`'s
/// `textFocusFlags()` counts only editable text views as "the user is typing",
/// so a focused log must NOT look like a text field — otherwise arrows, home,
/// end and the ctrl-letter chords would stop reaching PyMOL's key bindings for
/// as long as the console had focus.
///
/// iOS keeps the per-row rendering above: the report is macOS-only (there is no
/// ⌘C without a hardware keyboard), and the SwiftUI ScrollView there also owns
/// the interactive keyboard dismissal the command field depends on.
private struct ConsoleTextView: NSViewRepresentable {
    let entries: [String]
    let textColor: RGBA
    let font: FontSpec
    let bg: RGBA

    func makeNSView(context: Context) -> NSScrollView {
        // Structure only; the theme lands in updateNSView, which runs once with
        // a nil `styling` right after this.
        ConsoleLogText.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        // Re-style only when the theme actually changed: restyling touches every
        // character and forces a full re-layout, which would undo the point of
        // appending incrementally below.
        let styling = Styling(textColor: textColor, font: font, bg: bg)
        if coordinator.styling != styling {
            coordinator.styling = styling
            scrollView.backgroundColor = bg.nsColor
            textView.backgroundColor = bg.nsColor
            textView.typingAttributes = styling.attributes
            if let storage = textView.textStorage, storage.length > 0 {
                storage.setAttributes(styling.attributes,
                                      range: NSRange(location: 0, length: storage.length))
            }
        }

        let update = ConsoleLogText.plan(previous: coordinator.rendered, current: entries)
        guard update != .none else { return }
        // Follow new output only when the user is already parked at the bottom.
        // Scrolling unconditionally (what the SwiftUI log did) would yank the
        // view away from anyone reading — or mid-drag selecting — older output
        // every time a command printed a line.
        let follow = coordinator.rendered.isEmpty || Self.isScrolledToBottom(scrollView)

        ConsoleLogText.apply(update, to: textView, attributes: styling.attributes)
        coordinator.rendered = entries

        if follow {
            // Deferred a runloop so the appended text is laid out first —
            // scrolling immediately stops short of the true bottom.
            DispatchQueue.main.async { textView.scrollToEndOfDocument(nil) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Holds what the text view currently shows, so each update is a diff
    /// rather than a rebuild. SwiftUI hands `updateNSView` only the new value.
    final class Coordinator {
        var rendered: [String] = []
        var styling: Styling?
    }

    /// The theme-derived look of the log, as value types so "did the theme
    /// change?" is a cheap `==` rather than an NSColor/NSFont comparison.
    struct Styling: Equatable {
        let textColor: RGBA
        let font: FontSpec
        let bg: RGBA

        var attributes: [NSAttributedString.Key: Any] {
            [.font: font.nsFont, .foregroundColor: textColor.nsColor]
        }
    }

    /// Within a point of the end. Slack because the clip view's bounds and the
    /// document height rarely land on exactly the same fractional value.
    private static func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentHeight = scrollView.documentView?.frame.height else { return true }
        return scrollView.contentView.bounds.maxY >= documentHeight - 1
    }
}

// MARK: - Console log text model (macOS)

/// The edit that turns what the console log currently displays into what a new
/// `feedbackLog` value says it should display.
enum ConsoleLogUpdate: Equatable {
    /// Nothing changed.
    case none
    /// Rewrite the whole document — first fill, or a log that was cleared or
    /// rewritten rather than extended.
    case replace(String)
    /// Append at the end. The common case, and the only one that leaves the
    /// user's selection and scroll position completely untouched.
    case append(String)
    /// The log ALSO lost leading lines — `PyMOLEngine` trims the front once the
    /// feedback log passes its 400-line cap. Delete that many UTF-16 units from
    /// the start, then append (which may be empty).
    case trimThenAppend(dropCharacters: Int, append: String)
}

/// Turns `feedbackLog` (an array of lines) into edits for a single text view,
/// and owns the text view those edits land in.
///
/// Split out of `ConsoleTextView` so it can be tested: a test cannot drag-select
/// in a live app, but it CAN plan an edit, apply it to a real text view, select
/// all and copy — which is exactly what #406 is about. The interesting case is
/// the one that is invisible until it bites: a log trimmed at the front must not
/// be mistaken for a log that only grew at the back.
enum ConsoleLogText {

    /// One line per line: the separator IS what makes ⌘C paste as multiple
    /// lines rather than one run-on string.
    static let lineSeparator = "\n"

    static func text(for entries: some Sequence<String>) -> String {
        entries.joined(separator: lineSeparator)
    }

    /// The log's scroll view + text view, configured but unstyled. A factory
    /// rather than inline setup in `makeNSView` so a test can hold the real
    /// thing: an `NSViewRepresentable`'s `Context` cannot be built outside
    /// SwiftUI, which would otherwise put every AppKit-side guarantee here —
    /// selectable, NOT editable, `copy:` reachable — out of reach of a test.
    static func makeScrollView() -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false          // see ConsoleTextView: keeps textFocusFlags() honest
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.drawsBackground = true
        // Matches the .padding(4) the SwiftUI log had.
        textView.textContainerInset = NSSize(width: 4, height: 4)
        // Wrap long lines instead of scrolling sideways, as the Text rows did.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        return scrollView
    }

    /// Performs a planned edit on the log's text view.
    static func apply(_ update: ConsoleLogUpdate, to textView: NSTextView,
                      attributes: [NSAttributedString.Key: Any]) {
        guard let storage = textView.textStorage else { return }
        switch update {
        case .none:
            break
        case .replace(let text):
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        case .append(let text):
            storage.append(NSAttributedString(string: text, attributes: attributes))
        case .trimThenAppend(let dropCharacters, let text):
            let selection = textView.selectedRange()
            storage.beginEditing()
            storage.deleteCharacters(in: NSRange(location: 0, length: dropCharacters))
            if !text.isEmpty {
                storage.append(NSAttributedString(string: text, attributes: attributes))
            }
            storage.endEditing()
            textView.setSelectedRange(shiftSelection(selection, by: dropCharacters))
        }
    }

    /// The smallest edit that takes the view from `previous` to `current`.
    static func plan(previous: [String], current: [String]) -> ConsoleLogUpdate {
        if previous == current { return .none }
        if previous.isEmpty || current.isEmpty { return .replace(text(for: current)) }

        // Longest suffix of `previous` that is still a prefix of `current`: what
        // survived on screen. Anything before it was trimmed off the front,
        // anything after it is new output. Quadratic in the worst case but
        // linear in practice — a wrong overlap dies on its first comparison.
        for overlap in stride(from: min(previous.count, current.count), through: 1, by: -1) {
            guard previous.suffix(overlap).elementsEqual(current.prefix(overlap)) else { continue }
            let added = current.dropFirst(overlap)
            let appended = added.isEmpty ? "" : lineSeparator + text(for: added)
            let dropped = previous.count - overlap
            if dropped == 0 { return .append(appended) }
            // The trimmed lines plus the newline that separated them from the
            // first surviving one.
            let head = text(for: previous.prefix(dropped)) + lineSeparator
            return .trimThenAppend(dropCharacters: (head as NSString).length, append: appended)
        }
        // No overlap at all — the log was replaced wholesale.
        return .replace(text(for: current))
    }

    /// Slides a selection back over a front-trim, giving up whatever part of it
    /// the trim consumed. Without this, hitting the 400-line cap mid-selection
    /// would silently leave the highlight sitting on different text.
    static func shiftSelection(_ range: NSRange, by dropCharacters: Int) -> NSRange {
        let lost = max(0, min(range.length, dropCharacters - range.location))
        return NSRange(location: max(0, range.location - dropCharacters),
                       length: range.length - lost)
    }
}

#endif

// MARK: - Command Text Field (handles up/down arrow keys)

#if os(macOS)

struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var textColor: Color
    var bgColor: Color
    var fontSize: CGFloat
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onComplete: (String) -> String?

    func makeNSView(context: Context) -> NSTextField {
        // Arrow-key history is handled in the delegate's doCommandBy (moveUp:/
        // moveDown:), not via an NSTextField.keyDown override — a focused field's
        // key events are swallowed by the window's field editor, so keyDown never
        // sees the arrows. A plain NSTextField is therefore sufficient.
        let field = NSTextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        field.textColor = NSColor(textColor)
        field.backgroundColor = NSColor(bgColor)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Enter command..."
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // Re-apply theme colors/font (so a live theme switch updates the field).
        nsView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        nsView.textColor = NSColor(textColor)
        nsView.backgroundColor = NSColor(bgColor)
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onUpArrow = onUpArrow
        context.coordinator.onDownArrow = onDownArrow
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandTextField
        var onSubmit: () -> Void
        var onUpArrow: () -> Void
        var onDownArrow: () -> Void

        init(_ parent: CommandTextField) {
            self.parent = parent
            self.onSubmit = parent.onSubmit
            self.onUpArrow = parent.onUpArrow
            self.onDownArrow = parent.onDownArrow
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                      doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                return true
            }
            // Tab → PyMOL CLI completion. Replace the input with the completed
            // string (cursor to end); the ambiguous candidate list, if any, the
            // core prints to the feedback log. Always consume Tab (don't shift
            // keyboard focus out of the field).
            if selector == #selector(NSResponder.insertTab(_:)) {
                let current = textView.string
                if let completed = parent.onComplete(current), completed != current {
                    textView.string = completed
                    parent.text = completed
                    textView.setSelectedRange(NSRange(location: (completed as NSString).length, length: 0))
                }
                return true
            }
            // Up/Down arrows → command history. While the field is focused its key
            // events go to the window's shared field editor (an NSTextView), so a
            // focused NSTextField never sees keyDown for the arrows — they arrive
            // here as moveUp:/moveDown: instead (the same delegate path that makes
            // Return and Tab work). Recall via the history closures, then push the
            // recalled text straight into the field editor (setting the field's
            // stringValue while it is being edited is unreliable — mirror the Tab
            // handling above) and put the caret at the end.
            if selector == #selector(NSResponder.moveUp(_:)) {
                onUpArrow()
                let s = parent.text
                textView.string = s
                textView.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
                return true
            }
            if selector == #selector(NSResponder.moveDown(_:)) {
                onDownArrow()
                let s = parent.text
                textView.string = s
                textView.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
                return true
            }
            return false
        }
    }
}

#else // iOS / iPadOS

// SwiftUI-native field: reliable .onSubmit (the software-keyboard Return/Send
// submits), proper focus, and automatic keyboard avoidance (the UIKit-
// representable version didn't submit, focused unreliably, and got covered by
// the keyboard at the bottom of the panel). A "↑" history button replaces the
// hardware up-arrow (touch keyboards have no arrows; the old UIKeyCommands were
// never actually installed, so nothing usable is lost). Tab-completion is
// offered via a "⇥" button.
struct CommandTextField: View {
    @Binding var text: String
    var textColor: Color
    var bgColor: Color
    var fontSize: CGFloat
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onComplete: (String) -> String?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("Enter command…", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .submitLabel(.send)
                .onSubmit {
                    onSubmit()
                    focused = true   // keep focus so multiple commands can be entered
                }
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(textColor)

            Button {
                if let c = onComplete(text), c != text { text = c }
            } label: { Image(systemName: "arrow.right.to.line").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundColor(.gray)
                .accessibilityLabel("Complete")

            Button { onUpArrow() } label: {
                Image(systemName: "chevron.up").font(.system(size: 13))
            }.buttonStyle(.plain).foregroundColor(.gray).accessibilityLabel("Previous command")

            Button { onDownArrow() } label: {
                Image(systemName: "chevron.down").font(.system(size: 13))
            }.buttonStyle(.plain).foregroundColor(.gray).accessibilityLabel("Next command")

            // Software keyboards have no dismiss key, and .onSubmit re-arms focus
            // for the next command, so there was otherwise no way to close the
            // keyboard. A keyboard-accessory .toolbar(placement:.keyboard) does
            // NOT render for a field nested in a TabView (the console is a
            // panelTabs tab), so use an inline button on the command row.
            // Dismiss via the UIKit responder chain (resignFirstResponder) — the
            // SAME mechanism the log's interactive scroll-dismiss uses. Clearing
            // @FocusState alone made the keyboard bounce straight back up (SwiftUI
            // re-asserts the field's focus inside the TabView); resigning the
            // first responder sticks. SwiftUI then observes the resign and flips
            // `focused` false, which hides this button.
            if focused {
                Button {
                    #if canImport(UIKit)
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    #endif
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 15))
                }.buttonStyle(.plain).foregroundColor(.gray).accessibilityLabel("Dismiss keyboard")
            }
        }
    }
}

#endif

// MARK: - Preview

struct CommandPanel_Previews: PreviewProvider {
    static var previews: some View {
        CommandPanel()
            .environmentObject(previewEngine())
            .frame(height: 300)
            .preferredColorScheme(.dark)
    }

    static func previewEngine() -> PyMOLEngine {
        let engine = PyMOLEngine.shared
        engine.feedbackLog = [
            " PyMOL(TM) Molecular Graphics System, Version 3.1.0",
            " Copyright (c) Schrodinger, LLC.",
            " All Rights Reserved.",
            "",
            " PyMOL is user-supported open-source software.",
            "",
            "PyMOL>fetch 1ubq",
            " Executive: object \"1ubq\" created.",
            "PyMOL>cartoon automatic",
            "PyMOL>color cyan, 1ubq",
        ]
        return engine
    }
}
