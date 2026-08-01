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

    struct Document: Codable {
        var version = 1
        var sessionName: String?
        var updatedAt: Date
        var text: String
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
        text = loadDocument(for: normalized)?.text ?? ""
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

    /// Write a portable companion for an exported copy of a session without
    /// rebinding the live document to that temporary export URL.
    func writePortableSidecar(nextTo sessionURL: URL) -> URL? {
        let document = Document(sessionName: sessionURL.lastPathComponent,
                                updatedAt: Date(), text: text)
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
                                updatedAt: Date(), text: text)
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

            TextEditor(text: $notes.text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.12))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Analysis notes")
                .overlay(alignment: .topLeading) {
                    if notes.text.isEmpty {
                        Text("Record observations, hypotheses, residue details, or commands to revisit…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            Text("\(notes.text.count) characters")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { notes.flush() }
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
