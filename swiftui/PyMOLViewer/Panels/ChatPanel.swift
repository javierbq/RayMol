// ChatPanel.swift — AI chat interface for PyMOL (Claude/Anthropic backend)
//
// The conversation engine lives in the embedded Python (pymol.ai_chat): it runs
// the full agentic LLM loop on its own worker thread and reports back via tagged
// feedback lines (AICHAT:/AISTATUS:/AIQUESTIONS:/AIBUSY:/AIDONE:) that
// PyMOLEngine.pollFeedback drains into @Published state. This panel is a thin
// view over that state — it observes PyMOLEngine and sends user messages through
// engine.sendChatMessage. Works on macOS (right column) and iOS (chat tab).

import SwiftUI
#if canImport(Security)
import Security
#endif

// MARK: - Data Models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date

    enum Role { case user, assistant, error }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

// A follow-up question group the assistant can ask (rendered as buttons).
struct ChatQuestion: Identifiable {
    let id = UUID()
    let text: String
    let multiple: Bool        // false = pick one (sends immediately); true = multi-select
    let options: [String]
}

// MARK: - Keychain helper (API key storage, macOS + iOS)

/// Minimal Keychain wrapper for the Anthropic API key. Stored as a generic
/// password under this app's service so it persists across launches and never
/// touches UserDefaults / disk in cleartext.
enum KeychainHelper {
    private static let service = "PyMOLViewer.AI"
    private static let account = "anthropic_api_key"

    static func saveAPIKey(_ key: String) {
        let data = Data(key.utf8)
        // Delete any existing item first, then add (simplest upsert).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }   // empty == "clear the key"
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }
}

// MARK: - Chat Panel

struct ChatPanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var inputText = ""
    @State private var showKeySheet = false
    @FocusState private var isInputFocused: Bool

    private let bgColor = Color(red: 0.149, green: 0.149, blue: 0.161)           // #262629
    private let inputBgColor = Color(red: 0.2, green: 0.2, blue: 0.2)            // #333333
    private let accentBlue = Color(red: 0.29, green: 0.565, blue: 0.851)         // #4A90D9

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().background(Color.gray.opacity(0.3))
            messageList
            if engine.chatBusy { typingIndicator }
            if !engine.chatQuestions.isEmpty { questionArea }
            Divider().background(Color.gray.opacity(0.3))
            inputBar
        }
        .background(bgColor)
        .sheet(isPresented: $showKeySheet) { AIKeySheet() }
        .onAppear { deliverStoredKey() }
    }

    // Push the Keychain-stored key into the backend once the engine is ready
    // (so the very first message works without re-opening Settings).
    private func deliverStoredKey() {
        let key = KeychainHelper.loadAPIKey()
        if !key.isEmpty { engine.setAIKey(key) }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundColor(accentBlue)
                .font(.system(size: 12))

            Text("AI Chat")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))

            Spacer()

            Button(action: { showKeySheet = true }) {
                Image(systemName: engine.aiKeyConfigured ? "key.fill" : "key")
                    .font(.system(size: 11))
                    .foregroundColor(engine.aiKeyConfigured ? accentBlue : Color.gray)
            }
            .buttonStyle(.plain)
            .help("Set Anthropic API key")

            Button(action: { engine.clearChat() }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(Color.gray)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if engine.chatMessages.isEmpty {
                        emptyStateView
                    }
                    ForEach(engine.chatMessages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(bgColor)
            .onChange(of: engine.chatMessages.count) { _ in
                if let last = engine.chatMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundColor(accentBlue.opacity(0.5))

            Text("Ask RayMol AI for help with\nvisualization, analysis, or scripting")
                .font(.system(size: 12))
                .foregroundColor(Color.gray)
                .multilineTextAlignment(.center)

            if !engine.aiKeyConfigured {
                Button("Set Anthropic API key…") { showKeySheet = true }
                    .font(.system(size: 11))
                    .buttonStyle(.plain)
                    .foregroundColor(accentBlue)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            TypingDots()
            Text(engine.chatStatus.isEmpty ? "Thinking..." : engine.chatStatus)
                .font(.system(size: 11))
                .foregroundColor(Color.gray)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(bgColor)
    }

    // MARK: - Follow-up question buttons

    private var questionArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(engine.chatQuestions) { q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))
                    FlowOptions(options: q.options) { opt in
                        engine.answerChatQuestion(opt)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(bgColor)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask RayMol AI...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                #if os(macOS)
                .foregroundColor(Color(nsColor: .white))
                #else
                .foregroundColor(.white)
                #endif
                .focused($isInputFocused)
                .onSubmit { sendCurrentMessage() }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(inputBgColor)
                )

            Button(action: sendCurrentMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(canSend ? accentBlue : accentBlue.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(bgColor)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !engine.chatBusy
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        let text = inputText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = ""
        engine.sendChatMessage(text)
    }
}

// MARK: - API key entry sheet

/// SecureField for the Anthropic key, persisted to the Keychain and pushed to
/// the Python backend. Reachable from the ChatPanel header on macOS + iOS.
struct AIKeySheet: View {
    @EnvironmentObject var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss
    @State private var key: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Anthropic API Key").font(.headline)
                Spacer()
                Button("Done") { save(); dismiss() }
            }
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Text("Your key is stored locally in the device Keychain and sent only to the Anthropic API. It is never logged or uploaded anywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Clear", role: .destructive) {
                    key = ""
                    save()
                    dismiss()
                }
                Spacer()
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear { key = KeychainHelper.loadAPIKey() }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.saveAPIKey(trimmed)
        engine.setAIKey(trimmed)
    }
}

// MARK: - Option buttons (simple wrapping HStacks)

/// A lightweight wrapping layout for the question option buttons (avoids the
/// iOS 16 Layout protocol; chunks options into rows).
private struct FlowOptions: View {
    let options: [String]
    let onTap: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { ri in
                HStack(spacing: 6) {
                    ForEach(rows[ri], id: \.self) { opt in
                        Button(action: { onTap(opt) }) {
                            Text(opt)
                                .font(.system(size: 12))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(red: 0.29, green: 0.565, blue: 0.851).opacity(0.25))
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // Chunk into rows of at most 3 to avoid horizontal overflow in a narrow panel.
    private var rows: [[String]] {
        stride(from: 0, to: options.count, by: 3).map {
            Array(options[$0..<min($0 + 3, options.count)])
        }
    }
}

// MARK: - Message Bubble View

private struct MessageBubbleView: View {
    let message: ChatMessage

    private let userBubbleColor = Color(red: 0.29, green: 0.565, blue: 0.851)  // #4A90D9
    private let assistantTextColor = Color(red: 0.898, green: 0.898, blue: 0.898) // #E5E5E5
    private let errorTextColor = Color(red: 0.878, green: 0.318, blue: 0.318)    // #E05252

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantView
        case .error:
            errorView
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(userBubbleColor)
                )
        }
    }

    private var assistantView: some View {
        HStack {
            FormattedTextView(text: message.content, textColor: assistantTextColor)
                .textSelection(.enabled)
            Spacer(minLength: 40)
        }
    }

    private var errorView: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(errorTextColor)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(errorTextColor)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 40)
        }
    }
}

// MARK: - Formatted Text View (code block support)

private struct FormattedTextView: View {
    let text: String
    let textColor: Color

    private let codeBgColor = Color(red: 0.17, green: 0.17, blue: 0.19)
    private let codeTextColor = Color(red: 0.8, green: 0.9, blue: 0.8)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let content):
                    Text(content)
                        .font(.system(size: 13))
                        .foregroundColor(textColor)
                case .codeBlock(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(codeTextColor)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(codeBgColor)
                        )
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var segments: [TextSegment] {
        var result: [TextSegment] = []
        let parts = text.components(separatedBy: "```")
        for (index, part) in parts.enumerated() {
            let content = index.isMultiple(of: 2) ? part : stripLanguageTag(part)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if index.isMultiple(of: 2) {
                result.append(.text(trimmed))
            } else {
                result.append(.codeBlock(trimmed))
            }
        }
        return result
    }

    private func stripLanguageTag(_ code: String) -> String {
        let lines = code.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count > 1 else { return code }
        let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
        let knownLangs: Set<String> = [
            "python", "py", "pymol", "bash", "sh", "json", "swift", "cpp", "c",
            "javascript", "js", "text", "plain",
        ]
        if knownLangs.contains(firstLine.lowercased()) {
            return String(lines[1])
        }
        return code
    }
}

private enum TextSegment {
    case text(String)
    case codeBlock(String)
}

// MARK: - Typing Dots Animation

private struct TypingDots: View {
    @State private var dotPhase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.gray)
                    .frame(width: 5, height: 5)
                    .opacity(dotOpacity(for: index))
            }
        }
        .onReceive(timer) { _ in
            dotPhase = (dotPhase + 1) % 4
        }
    }

    private func dotOpacity(for index: Int) -> Double {
        if index == dotPhase % 3 { return 1.0 }
        return 0.3
    }
}
