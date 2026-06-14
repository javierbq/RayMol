// CommandPanel.swift — Log viewer + command input for PyMOL
// Replaces modules/pymol/appkit_command_panel.py with pure SwiftUI.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct CommandPanel: View {
    @EnvironmentObject var engine: PyMOLEngine

    @State private var commandText = ""
    @State private var commandHistory: [String] = []
    @State private var historyIndex = -1

    private let bgColor = Color(red: 0.118, green: 0.118, blue: 0.118) // #1E1E1E
    private let logTextColor = Color(red: 0, green: 1, blue: 0) // #00FF00
    private let inputTextColor = Color.white
    private let promptColor = Color(red: 0, green: 1, blue: 0)

    var body: some View {
        VStack(spacing: 0) {
            // Scrolling log area
            LogView(entries: engine.feedbackLog, textColor: logTextColor)

            Divider()
                .background(Color.gray.opacity(0.4))

            // Command input bar
            HStack(spacing: 4) {
                Text("PyMOL>")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(promptColor)

                CommandTextField(
                    text: $commandText,
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
        .background(bgColor)
    }

    // MARK: - Actions

    private func submitCommand() {
        let trimmed = commandText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        commandHistory.append(trimmed)
        historyIndex = commandHistory.count

        engine.feedbackLog.append("PyMOL>\(trimmed)")
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

    private let bgColor = Color(red: 0.118, green: 0.118, blue: 0.118)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(textColor)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .background(bgColor)
            .onChange(of: entries.count) { _ in
                if let last = entries.indices.last {
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Command Text Field (handles up/down arrow keys)

#if os(macOS)

struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onComplete: (String) -> String?

    func makeNSView(context: Context) -> NSTextField {
        let field = CommandNSTextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.textColor = .white
        field.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "Enter command..."
        field.cell?.sendsActionOnEndEditing = false
        field.onUpArrow = onUpArrow
        field.onDownArrow = onDownArrow
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onUpArrow = onUpArrow
        context.coordinator.onDownArrow = onDownArrow
        context.coordinator.parent = self
        if let cmdField = nsView as? CommandNSTextField {
            cmdField.onUpArrow = onUpArrow
            cmdField.onDownArrow = onDownArrow
        }
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
            return false
        }
    }
}

/// NSTextField subclass that intercepts up/down arrow key events.
private class CommandNSTextField: NSTextField {
    var onUpArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow
            onUpArrow?()
            return
        case 125: // Down arrow
            onDownArrow?()
            return
        default:
            break
        }
        super.keyDown(with: event)
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
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)

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
