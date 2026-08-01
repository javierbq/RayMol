// NotesInspectorView.swift — session-linked analysis scratchpad.

import SwiftUI

/// Plain-text analysis notes associated with the current PyMOL session.
///
/// A portable JSON sidecar is preferred (`sample.raymol-notes.json`). Sandboxed
/// file-provider URLs are not always writable after their picker access ends, so
/// every note is also mirrored into Application Support under a stable URL key.
/// That fallback keeps notes available on iPhone/iPad without requiring broad
/// file-system access.
final class AnalysisNotesStore: ObservableObject {
    static let shared = AnalysisNotesStore()

    struct ViewBookmark: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        let view: [Float]
        let createdAt: Date
    }

    struct Document: Codable {
        var version = 2
        var sessionName: String?
        var updatedAt: Date
        var text: String
        // Optional keeps version-1 sidecars backward compatible.
        var viewBookmarks: [ViewBookmark]?
    }

    @Published var text: String = "" {
        didSet {
            guard !isLoading, text != oldValue else { return }
            saveState = .pending
            scheduleSave()
        }
    }
    @Published private(set) var sessionURL: URL?
    @Published private(set) var saveState: SaveState = .saved
    @Published private(set) var viewBookmarks: [ViewBookmark] = []

    enum SaveState: Equatable {
        case saved
        case pending
        case failed(String)
    }

    private let fileManager: FileManager
    private let fallbackDirectory: URL
    private let debounceInterval: TimeInterval
    private var pendingSave: DispatchWorkItem?
    private var isLoading = false
    private var hasOpenedSession = false

    init(fileManager: FileManager = .default,
         fallbackDirectory: URL? = nil,
         debounceInterval: TimeInterval = 0.6) {
        self.fileManager = fileManager
        self.debounceInterval = debounceInterval
        if let fallbackDirectory {
            self.fallbackDirectory = fallbackDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fallbackDirectory = base
                .appendingPathComponent("RayMol", isDirectory: true)
                .appendingPathComponent("AnalysisNotes", isDirectory: true)
        }
    }

    /// Load notes for a newly opened session. Passing nil selects the persistent
    /// untitled-session scratchpad used before a `.pse` has been saved.
    func openSession(at url: URL?) {
        let normalized = url?.standardizedFileURL
        guard !hasOpenedSession || normalized != sessionURL else { return }
        flush()
        hasOpenedSession = true
        sessionURL = normalized

        isLoading = true
        let document = loadDocument(for: normalized)
        text = document?.text ?? ""
        viewBookmarks = document?.viewBookmarks ?? []
        isLoading = false
        saveState = .saved
    }

    /// Rebind the current text after Save/Save As without loading over it. This is
    /// deliberately different from openSession(at:): an untitled scratchpad must
    /// become the saved session's note when the user first chooses a `.pse` URL.
    func sessionDidSave(to url: URL) {
        pendingSave?.cancel()
        pendingSave = nil
        hasOpenedSession = true
        sessionURL = url.standardizedFileURL
        persist()
    }

    /// Immediately write pending edits. Called before changing sessions and may
    /// also be used at app lifecycle boundaries.
    func flush() {
        guard saveState != .saved else { return }
        pendingSave?.cancel()
        pendingSave = nil
        persist()
    }

    func sidecarURL(for sessionURL: URL) -> URL {
        sessionURL.deletingPathExtension().appendingPathExtension("raymol-notes.json")
    }

    @discardableResult
    func addViewBookmark(title: String, view: [Float]) -> ViewBookmark? {
        guard view.count == 25 else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = ViewBookmark(id: UUID(),
                                    title: cleanTitle.isEmpty ? "Saved view" : cleanTitle,
                                    view: view,
                                    createdAt: Date())
        viewBookmarks.append(bookmark)
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += "\(separator)[\(bookmark.title)](raymol-view://\(bookmark.id.uuidString))"
        saveState = .pending
        scheduleSave()
        return bookmark
    }

    func viewBookmark(for url: URL) -> ViewBookmark? {
        guard url.scheme == "raymol-view" else { return nil }
        let identifier = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: identifier) else { return nil }
        return viewBookmarks.first { $0.id == id }
    }

    /// Write a portable companion for an exported copy of a session without
    /// rebinding the live document to that temporary export URL.
    func writePortableSidecar(nextTo sessionURL: URL) -> URL? {
        let document = Document(sessionName: sessionURL.lastPathComponent,
                                updatedAt: Date(), text: text,
                                viewBookmarks: viewBookmarks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return nil }
        let url = sidecarURL(for: sessionURL)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persist() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func persist() {
        pendingSave?.cancel()
        pendingSave = nil

        let document = Document(sessionName: sessionURL?.lastPathComponent,
                                updatedAt: Date(), text: text,
                                viewBookmarks: viewBookmarks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(document)
            let fallback = fallbackURL(for: sessionURL)
            try fileManager.createDirectory(at: fallbackDirectory,
                                            withIntermediateDirectories: true)
            try data.write(to: fallback, options: .atomic)

            // The fallback is authoritative in a sandbox. The sidecar is an
            // additional portable copy when the session's directory is writable.
            if let sessionURL {
                let scoped = sessionURL.startAccessingSecurityScopedResource()
                defer { if scoped { sessionURL.stopAccessingSecurityScopedResource() } }
                try? data.write(to: sidecarURL(for: sessionURL), options: .atomic)
            }
            saveState = .saved
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    private func loadDocument(for sessionURL: URL?) -> Document? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func decode(_ url: URL) -> Document? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Document.self, from: data)
        }

        var sidecarDocument: Document?
        if let sessionURL {
            let scoped = sessionURL.startAccessingSecurityScopedResource()
            defer { if scoped { sessionURL.stopAccessingSecurityScopedResource() } }
            sidecarDocument = decode(sidecarURL(for: sessionURL))
        }

        let fallbackDocument = decode(fallbackURL(for: sessionURL))
        switch (sidecarDocument, fallbackDocument) {
        case let (sidecar?, fallback?):
            return sidecar.updatedAt >= fallback.updatedAt ? sidecar : fallback
        case let (sidecar?, nil):
            return sidecar
        case let (nil, fallback?):
            return fallback
        case (nil, nil):
            return nil
        }
    }

    private func fallbackURL(for sessionURL: URL?) -> URL {
        guard let sessionURL else {
            return fallbackDirectory.appendingPathComponent("untitled.json")
        }
        return fallbackDirectory.appendingPathComponent("\(stableHash(sessionURL.absoluteString)).json")
    }

    /// Deterministic FNV-1a keeps fallback filenames stable without adding a
    /// CryptoKit deployment dependency.
    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct NotesInspectorView: View {
    @EnvironmentObject private var notes: AnalysisNotesStore
    @EnvironmentObject private var engine: PyMOLEngine
    @AppStorage("analysisNotesFontSize") private var fontSize = 16.0
    @State private var isPreviewing = false
    @State private var showingViewNamePrompt = false
    @State private var viewName = ""
    @State private var pendingView: [Float]?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(sessionLabel, systemImage: notes.sessionURL == nil ? "doc" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                saveStatus
            }

            HStack(spacing: 8) {
                Picker("Note mode", selection: $isPreviewing) {
                    Label("Edit", systemImage: "square.and.pencil").tag(false)
                    Label("Preview", systemImage: "link").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 190)

                Spacer(minLength: 4)

                Button { fontSize = max(12, fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(fontSize <= 12)
                .help("Decrease note text size")

                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)

                Button { fontSize = min(28, fontSize + 1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(fontSize >= 28)
                .help("Increase note text size")
            }

            Group {
                if isPreviewing {
                    preview
                } else {
                    editor
                }
            }
            .background(Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Button {
                    guard let view = engine.captureView() else { return }
                    pendingView = view
                    viewName = "View \(notes.viewBookmarks.count + 1)"
                    showingViewNamePrompt = true
                } label: {
                    Label("Insert View Link", systemImage: "camera.viewfinder")
                }
                .disabled(!engine.isReady)
                .help("Capture the current molecular camera and insert a link")

                Spacer()

                Text("\(notes.text.count) characters · \(notes.viewBookmarks.count) views")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { notes.flush() }
        .alert("Insert View Link", isPresented: $showingViewNamePrompt) {
            TextField("Link name", text: $viewName)
            Button("Insert") { insertPendingView() }
            Button("Cancel", role: .cancel) { pendingView = nil }
        } message: {
            Text("Name the current molecular view. Clicking its link in Preview will return to this camera position.")
        }
    }

    private var editor: some View {
        TextEditor(text: $notes.text)
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .padding(6)
            .accessibilityLabel("Analysis notes")
            .overlay(alignment: .topLeading) {
                if notes.text.isEmpty {
                    Text("Record observations, hypotheses, residue details, or commands to revisit…")
                        .font(.system(size: fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    private var preview: some View {
        ScrollView {
            if notes.text.isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(renderedNotes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: fontSize))
        .padding(12)
        .environment(\.openURL, OpenURLAction { url in
            guard let bookmark = notes.viewBookmark(for: url) else { return .systemAction }
            engine.restoreView(bookmark.view)
            return .handled
        })
    }

    private var renderedNotes: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: notes.text, options: options))
            ?? AttributedString(notes.text)
    }

    private func insertPendingView() {
        guard let view = pendingView else { return }
        _ = notes.addViewBookmark(title: markdownSafe(viewName), view: view)
        pendingView = nil
        isPreviewing = true
    }

    private func markdownSafe(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    private var sessionLabel: String {
        notes.sessionURL?.lastPathComponent ?? "Unsaved session"
    }

    @ViewBuilder private var saveStatus: some View {
        switch notes.saveState {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .pending:
            Label("Saving…", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Not saved", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
