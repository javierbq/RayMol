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

/// Minimal Keychain wrapper for the AI credentials. Each value is stored as a
/// generic password under this app's service so it persists across launches and
/// never touches UserDefaults / disk in cleartext.
///
/// Accounts:
///   - "anthropic_api_key"   — the direct-Anthropic key (saveAPIKey/loadAPIKey)
///   - "ai_provider"         — "anthropic" | "vertex" (the active provider)
///   - "vertex.project"      — GCP project id
///   - "vertex.region"       — GCP region (default "us-east5")
///   - "vertex.model"        — Vertex publisher model id (with @version)
///   - "vertex.token"        — GCP access token / Vertex API key (a fallback secret)
///   - "vertex.sa_key"       — service-account JSON key (on-device token minting)
enum KeychainHelper {
    private static let service = "PyMOLViewer.AI"
    private static let account = "anthropic_api_key"

    // Distinct accounts for the provider choice + Vertex config.
    static let providerAccount = "ai_provider"
    static let vertexProjectAccount = "vertex.project"
    static let vertexRegionAccount = "vertex.region"
    static let vertexModelAccount = "vertex.model"
    static let vertexTokenAccount = "vertex.token"
    // Full service-account JSON key. When present, the backend mints + refreshes
    // Vertex access tokens on-device from it (no expiring gcloud token needed).
    static let vertexSAKeyAccount = "vertex.sa_key"

    // MARK: generic per-account get/set

    /// Upsert a value under `account` (empty string clears it).
    static func setValue(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }   // empty == "clear"
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func value(account: String) -> String {
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
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: Anthropic key (existing API, preserved)

    static func saveAPIKey(_ key: String) { setValue(key, account: account) }
    static func loadAPIKey() -> String { value(account: account) }
}

// MARK: - AI provider model

/// The selectable AI backends. rawValue matches what pymol.ai_chat.set_provider
/// expects ("anthropic" / "vertex").
enum AIProvider: String, CaseIterable, Identifiable {
    case anthropic
    case vertex
    var id: String { rawValue }
    var display: String { self == .anthropic ? "Anthropic" : "Vertex AI" }
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

    // Push the Keychain-stored provider + credentials into the backend once the
    // engine is ready (so the very first message works without re-opening
    // Settings).
    private func deliverStoredKey() {
        AISettings.deliverStored(engine: engine)
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundColor(accentBlue)
                .font(.system(size: 12))

            Text("Raymond")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(red: 0.9, green: 0.9, blue: 0.9))

            Spacer()

            Button(action: { showKeySheet = true }) {
                Image(systemName: engine.aiKeyConfigured ? "key.fill" : "key")
                    .font(.system(size: 11))
                    .foregroundColor(engine.aiKeyConfigured ? accentBlue : Color.gray)
            }
            .buttonStyle(.plain)
            .help("Set AI provider & credentials")

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
                Button("Set AI provider & credentials…") { showKeySheet = true }
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
            TextField("Ask Raymond...", text: $inputText)
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

/// Provider picker + credentials, persisted to the Keychain and pushed to the
/// Python backend. Anthropic → a single key; Vertex AI → project / region /
/// access token / model. Reachable from the ChatPanel header on macOS + iOS.
struct AIKeySheet: View {
    @EnvironmentObject var engine: PyMOLEngine
    @Environment(\.dismiss) private var dismiss

    @State private var provider: AIProvider = .anthropic
    @State private var key: String = ""             // Anthropic key
    @State private var vertexProject: String = ""
    @State private var vertexRegion: String = "us-east5"
    @State private var vertexModel: String = ""
    @State private var vertexToken: String = ""
    @State private var vertexSAKey: String = ""     // service-account JSON

    private let defaultVertexModel = "claude-sonnet-4-5@20250929"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI Provider").font(.headline)
                Spacer()
                Button("Done") { save(); dismiss() }
            }

            Picker("Provider", selection: $provider) {
                ForEach(AIProvider.allCases) { p in
                    Text(p.display).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if provider == .anthropic {
                anthropicFields
            } else {
                vertexFields
            }

            HStack {
                Button("Clear", role: .destructive) {
                    if provider == .anthropic { key = "" }
                    else { vertexToken = ""; vertexSAKey = "" }
                    save()
                    dismiss()
                }
                Spacer()
                Button("Save") { save(); dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { loadFromKeychain() }
    }

    private var anthropicFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Text("Your key is stored locally in the device Keychain and sent only to the Anthropic API. It is never logged or uploaded anywhere else.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var vertexFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Project ID (my-gcp-project)", text: $vertexProject)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Region (us-east5)", text: $vertexRegion)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            // Service-account JSON (preferred): mints + auto-refreshes tokens
            // on-device, so no expiring gcloud token to paste hourly.
            Text("Service Account JSON (recommended)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $vertexSAKey)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 150)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.4)))

            SecureField("Access token (fallback; optional)", text: $vertexToken)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Model (\(defaultVertexModel))", text: $vertexModel)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Text("Paste a service-account JSON key to mint + auto-refresh tokens on-device. Or paste a GCP access token (gcloud auth print-access-token; expires ~1h). Stored only in the device Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadFromKeychain() {
        let saved = KeychainHelper.value(account: KeychainHelper.providerAccount)
        provider = AIProvider(rawValue: saved) ?? .anthropic
        key = KeychainHelper.loadAPIKey()
        vertexProject = KeychainHelper.value(account: KeychainHelper.vertexProjectAccount)
        let region = KeychainHelper.value(account: KeychainHelper.vertexRegionAccount)
        vertexRegion = region.isEmpty ? "us-east5" : region
        vertexModel = KeychainHelper.value(account: KeychainHelper.vertexModelAccount)
        vertexToken = KeychainHelper.value(account: KeychainHelper.vertexTokenAccount)
        vertexSAKey = KeychainHelper.value(account: KeychainHelper.vertexSAKeyAccount)
    }

    private func save() {
        AISettings.persistAndDeliver(
            engine: engine,
            provider: provider,
            anthropicKey: key,
            vertexProject: vertexProject,
            vertexRegion: vertexRegion,
            vertexModel: vertexModel.isEmpty ? defaultVertexModel : vertexModel,
            vertexToken: vertexToken,
            vertexSAKey: vertexSAKey)
    }
}

// MARK: - AI settings persistence + delivery (shared by AIKeySheet + SettingsSheet)

/// One place that writes the AI credentials to the Keychain and pushes them to
/// the Python backend, so the ChatPanel sheet and the Settings sheet stay in
/// sync. Trims inputs, persists, then calls engine.applyAISettings.
enum AISettings {
    static func persistAndDeliver(engine: PyMOLEngine,
                                  provider: AIProvider,
                                  anthropicKey: String,
                                  vertexProject: String,
                                  vertexRegion: String,
                                  vertexModel: String,
                                  vertexToken: String,
                                  vertexSAKey: String = "") {
        let aKey = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
        var region = vertexRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        if region.isEmpty { region = "us-east5" }
        let model = vertexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = vertexToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // The SA JSON is multi-line; only trim the outer whitespace, never the
        // interior (the PEM newlines inside private_key must survive).
        let saKey = vertexSAKey.trimmingCharacters(in: .whitespacesAndNewlines)

        KeychainHelper.setValue(provider.rawValue, account: KeychainHelper.providerAccount)
        KeychainHelper.saveAPIKey(aKey)
        KeychainHelper.setValue(project, account: KeychainHelper.vertexProjectAccount)
        KeychainHelper.setValue(region, account: KeychainHelper.vertexRegionAccount)
        KeychainHelper.setValue(model, account: KeychainHelper.vertexModelAccount)
        KeychainHelper.setValue(token, account: KeychainHelper.vertexTokenAccount)
        KeychainHelper.setValue(saKey, account: KeychainHelper.vertexSAKeyAccount)

        engine.applyAISettings(provider: provider.rawValue,
                               anthropicKey: aKey,
                               vertexProject: project,
                               vertexRegion: region,
                               vertexModel: model,
                               vertexToken: token,
                               vertexSAKey: saKey)
    }

    /// Push whatever is in the Keychain to the backend (called on appear so the
    /// first message works without reopening settings).
    static func deliverStored(engine: PyMOLEngine) {
        let provRaw = KeychainHelper.value(account: KeychainHelper.providerAccount)
        let provider = AIProvider(rawValue: provRaw) ?? .anthropic
        let region = KeychainHelper.value(account: KeychainHelper.vertexRegionAccount)
        persistAndDeliver(
            engine: engine,
            provider: provider,
            anthropicKey: KeychainHelper.loadAPIKey(),
            vertexProject: KeychainHelper.value(account: KeychainHelper.vertexProjectAccount),
            vertexRegion: region.isEmpty ? "us-east5" : region,
            vertexModel: KeychainHelper.value(account: KeychainHelper.vertexModelAccount),
            vertexToken: KeychainHelper.value(account: KeychainHelper.vertexTokenAccount),
            vertexSAKey: KeychainHelper.value(account: KeychainHelper.vertexSAKeyAccount))
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
