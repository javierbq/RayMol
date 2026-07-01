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
            LogView(entries: engine.feedbackLog, textColor: logTextColor,
                    font: termFont, bg: bgColor)

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
    let textColor: Color
    let font: Font
    let bg: Color

    private var bgColor: Color { bg }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(font)
                            .foregroundColor(textColor)
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
            .background(bgColor)
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
}

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
