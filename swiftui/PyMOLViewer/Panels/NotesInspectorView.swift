// NotesInspectorView.swift — session-linked analysis scratchpad.

import SwiftUI
import UniformTypeIdentifiers
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Analysis notes associated with the current PyMOL session. The live document
/// is staged locally while editing and embedded into the `.pse` on session save.
/// Legacy `.raymol-notes.json` sidecars remain readable for migration.
final class AnalysisNotesStore: ObservableObject {
    static let shared = AnalysisNotesStore()

    enum BookmarkKind: String, Codable, CaseIterable {
        case camera
        case scene

        var label: String { self == .camera ? "Camera" : "Scene" }
    }

    struct ViewBookmark: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        let view: [Float]
        let createdAt: Date
        // Optional fields preserve version-2 camera-only sidecars.
        var kind: BookmarkKind?
        var sceneName: String?

        var resolvedKind: BookmarkKind { kind ?? .camera }
    }

    struct ScreenshotAsset: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        let fileName: String
        let createdAt: Date
    }

    struct NotePage: Codable, Identifiable, Equatable {
        let id: UUID
        var title: String
        var text: String
        var viewBookmarks: [ViewBookmark]
        var screenshots: [ScreenshotAsset]
    }

    struct Document: Codable {
        var version = 4
        var sessionName: String?
        var updatedAt: Date
        var text: String
        // Optional keeps version-1 sidecars backward compatible.
        var viewBookmarks: [ViewBookmark]?
        var screenshots: [ScreenshotAsset]?
        var notePages: [NotePage]?
        var activePageID: UUID?
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
    @Published private(set) var screenshots: [ScreenshotAsset] = []
    @Published private(set) var notePages: [NotePage] = []
    @Published private(set) var activePageID: UUID?

    /// True when the note holds anything worth carrying into the session file:
    /// text on any page, a linked image, or a view link. Checks the live active
    /// page as well as the committed pages, so it is correct even if called
    /// before commitActivePage(). Used to decide whether an object-less scene is
    /// still worth autosaving on iOS — the .pse is the only durable home a note
    /// has there.
    var hasContent: Bool {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !screenshots.isEmpty || !viewBookmarks.isEmpty { return true }
        return notePages.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !$0.screenshots.isEmpty || !$0.viewBookmarks.isEmpty
        }
    }

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
    private var stageEmbeddedDocument: ((URL, URL) -> Bool)?
    private var exportEmbeddedDocument: ((URL, URL) -> Bool)?

    init(fileManager: FileManager = .default,
         fallbackDirectory: URL? = nil,
         debounceInterval: TimeInterval = 10) {
        self.fileManager = fileManager
        self.debounceInterval = debounceInterval
        if let fallbackDirectory {
            self.fallbackDirectory = fallbackDirectory
        } else {
            self.fallbackDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("RayMol", isDirectory: true)
                .appendingPathComponent("AnalysisNotes", isDirectory: true)
                .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier),
                                        isDirectory: true)
        }
    }

    /// Connect the store to PyMOL's session save/restore extension. Kept as
    /// closures so persistence can be tested without initializing the engine.
    func configureEmbeddedPersistence(
        stage: @escaping (URL, URL) -> Bool,
        export: @escaping (URL, URL) -> Bool
    ) {
        stageEmbeddedDocument = stage
        exportEmbeddedDocument = export
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
        let embeddedDocument = loadEmbeddedDocument(for: normalized)
        let document = embeddedDocument ?? loadDocument(for: normalized)
        if let pages = document?.notePages, !pages.isEmpty {
            notePages = pages
            activePageID = pages.contains { $0.id == document?.activePageID }
                ? document?.activePageID : pages.first?.id
            loadActivePage()
        } else {
            let migrated = NotePage(id: UUID(), title: "Analysis",
                                    text: document?.text ?? "",
                                    viewBookmarks: document?.viewBookmarks ?? [],
                                    screenshots: document?.screenshots ?? [])
            notePages = [migrated]
            activePageID = migrated.id
            text = migrated.text
            viewBookmarks = migrated.viewBookmarks
            screenshots = migrated.screenshots
        }
        isLoading = false
        saveState = .saved
        // Stage legacy sidecars/recovery documents immediately so Share Session
        // can produce a self-contained PSE even before the user edits the note.
        if embeddedDocument == nil, document != nil {
            saveState = .pending
            persist()
        }
    }

    /// Rebind the current text after Save/Save As without loading over it. This is
    /// deliberately different from openSession(at:): an untitled scratchpad must
    /// become the saved session's note when the user first chooses a `.pse` URL.
    func sessionDidSave(to url: URL) {
        pendingSave?.cancel()
        pendingSave = nil
        let oldURL = sessionURL
        hasOpenedSession = true
        sessionURL = url.standardizedFileURL
        migrateFallbackAssets(from: oldURL, to: sessionURL)
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

    var activePageTitle: String {
        notePages.first { $0.id == activePageID }?.title ?? "Analysis"
    }

    func createPage(named title: String) {
        commitActivePage()
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = NotePage(id: UUID(), title: clean.isEmpty ? "New Note" : clean,
                            text: "", viewBookmarks: [], screenshots: [])
        notePages.append(page)
        activePageID = page.id
        loadActivePage()
        saveState = .pending
        scheduleSave()
    }

    func selectPage(_ id: UUID) {
        guard id != activePageID, notePages.contains(where: { $0.id == id }) else { return }
        commitActivePage()
        activePageID = id
        loadActivePage()
    }

    func renameActivePage(_ title: String) {
        guard let index = notePages.firstIndex(where: { $0.id == activePageID }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notePages[index].title = clean.isEmpty ? "Analysis" : clean
        saveState = .pending
        scheduleSave()
    }

    func deleteActivePage() {
        guard notePages.count > 1, let id = activePageID,
              let index = notePages.firstIndex(where: { $0.id == id }) else { return }
        notePages.remove(at: index)
        activePageID = notePages[min(index, notePages.count - 1)].id
        loadActivePage()
        saveState = .pending
        scheduleSave()
    }

    /// Register a view bookmark. `insertsMarkdown: false` records the bookmark
    /// without writing the bare text link, so the caller can compose a richer
    /// marker instead — a thumbnail bound to the link, via addScreenshot's
    /// `linkedBookmarkID`.
    @discardableResult
    func addViewBookmark(id: UUID = UUID(), title: String, view: [Float],
                         kind: BookmarkKind = .camera,
                         sceneName: String? = nil,
                         insertsMarkdown: Bool = true) -> ViewBookmark? {
        guard view.count == 25 else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = ViewBookmark(id: id,
                                    title: cleanTitle.isEmpty ? "Saved view" : cleanTitle,
                                    view: view,
                                    createdAt: portableTimestamp(), kind: kind,
                                    sceneName: sceneName)
        viewBookmarks.append(bookmark)
        if insertsMarkdown {
            appendViewLink(bookmark)
        } else {
            saveState = .pending
            scheduleSave()
        }
        return bookmark
    }

    /// Append the bare text marker for an already registered bookmark.
    func appendViewLink(_ bookmark: ViewBookmark) {
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += "\(separator)[\(bookmark.title)](raymol-view://\(bookmark.id.uuidString))"
        saveState = .pending
        scheduleSave()
    }

    /// Copy a rendered PNG into the note's asset store and insert its marker.
    /// With `linkedBookmarkID` the marker is a linked image —
    /// `[![title](raymol-asset://asset)](raymol-view://bookmark)` — so the
    /// preview's thumbnail restores that camera or scene when clicked.
    @discardableResult
    func addScreenshot(title: String, from sourceURL: URL,
                       linkedBookmarkID: UUID? = nil) -> ScreenshotAsset? {
        let id = UUID()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = ScreenshotAsset(id: id,
                                    title: cleanTitle.isEmpty ? "Molecular view" : cleanTitle,
                                    fileName: "\(id.uuidString).png", createdAt: portableTimestamp())
        do {
            let directory = fallbackAssetsDirectory(for: sessionURL)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(asset.fileName)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: sourceURL, to: destination)
            screenshots.append(asset)
            let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            let image = "![\(asset.title)](raymol-asset://\(asset.id.uuidString))"
            if let linkedBookmarkID {
                text += "\(separator)[\(image)](raymol-view://\(linkedBookmarkID.uuidString))"
            } else {
                text += separator + image
            }
            saveState = .pending
            scheduleSave()
            return asset
        } catch {
            saveState = .failed(error.localizedDescription)
            return nil
        }
    }

    func screenshot(for url: URL) -> ScreenshotAsset? {
        guard url.scheme == "raymol-asset" else { return nil }
        let identifier = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: identifier) else { return nil }
        return screenshots.first { $0.id == id }
    }

    func screenshotURL(for asset: ScreenshotAsset) -> URL? {
        let fallback = fallbackAssetsDirectory(for: sessionURL).appendingPathComponent(asset.fileName)
        if fileManager.fileExists(atPath: fallback.path) { return fallback }

        // Read legacy companion assets for migration, but never write new
        // working files beside the session.
        if let sessionURL {
            let portable = legacyAssetsDirectory(for: sessionURL).appendingPathComponent(asset.fileName)
            if fileManager.fileExists(atPath: portable.path) { return portable }
            let sibling = sessionURL.deletingLastPathComponent().appendingPathComponent(asset.fileName)
            if fileManager.fileExists(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    var headings: [(level: Int, title: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let prefix = line.prefix { $0 == "#" }
            guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first == " " else { return nil }
            return (prefix.count, String(line.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces))
        }
    }

    var tags: [String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_–-"))
        let found = text.components(separatedBy: .whitespacesAndNewlines).compactMap { token -> String? in
            guard token.hasPrefix("#"), token.count > 1 else { return nil }
            let body = token.dropFirst().unicodeScalars.prefix { allowed.contains($0) }
            return body.isEmpty ? nil : "#" + body.map(String.init).joined()
        }
        return Array(Set(found)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Portable, human-readable Markdown with RayMol-only URL schemes removed.
    var cleanMarkdown: String {
        var result = text
        for bookmark in viewBookmarks {
            // Thumbnails bound to this link collapse first: their marker wraps
            // the image markdown, so the bare-link replacement below misses it.
            result = result.replacingOccurrences(
                of: AnalysisNoteMarkers.linkedImagePattern(bookmarkID: bookmark.id),
                with: "**\(bookmark.resolvedKind.label) view:** \(bookmark.title)",
                options: .regularExpression)
            let source = "[\(bookmark.title)](raymol-view://\(bookmark.id.uuidString))"
            result = result.replacingOccurrences(of: source,
                with: "**\(bookmark.resolvedKind.label) view:** \(bookmark.title)")
        }
        for asset in screenshots {
            let source = "![\(asset.title)](raymol-asset://\(asset.id.uuidString))"
            result = result.replacingOccurrences(of: source, with: "**Figure:** \(asset.title)")
        }
        return result
    }

    func exportHTML() -> String {
        AnalysisNotesExporter.html(title: activePageTitle, markdown: text,
                                   bookmarks: viewBookmarks,
                                   screenshots: screenshots,
                                   imageURL: screenshotURL)
    }

    func exportPDFData() -> Data {
        AnalysisNotesExporter.pdf(title: activePageTitle, markdown: text,
                                  bookmarks: viewBookmarks,
                                  screenshots: screenshots,
                                  imageURL: screenshotURL)
    }

    func viewBookmark(for url: URL) -> ViewBookmark? {
        guard url.scheme == "raymol-view" else { return nil }
        let identifier = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: identifier) else { return nil }
        return viewBookmarks.first { $0.id == id }
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

        commitActivePage()
        let document = Document(sessionName: sessionURL?.lastPathComponent,
                                updatedAt: Date(), text: text,
                                viewBookmarks: viewBookmarks,
                                screenshots: screenshots,
                                notePages: notePages,
                                activePageID: activePageID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(document)
            let fallback = fallbackURL(for: sessionURL)
            try fileManager.createDirectory(at: fallbackDirectory,
                                            withIntermediateDirectories: true)
            try data.write(to: fallback, options: .atomic)

            let assets = fallbackAssetsDirectory(for: sessionURL)
            try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
            let staged = stageEmbeddedDocument?(fallback, assets) ?? true
            saveState = staged ? .saved : .failed("Could not stage notes in the PyMOL session")
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

    private func loadEmbeddedDocument(for sessionURL: URL?) -> Document? {
        guard let exportEmbeddedDocument else { return nil }
        let root = fallbackDirectory.appendingPathComponent("Restored", isDirectory: true)
        let documentURL = root.appendingPathComponent("document.json")
        let restoredAssets = root.appendingPathComponent("Assets", isDirectory: true)
        try? fileManager.removeItem(at: root)
        guard exportEmbeddedDocument(documentURL, restoredAssets) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: documentURL),
              let document = try? decoder.decode(Document.self, from: data) else { return nil }

        let liveAssets = fallbackAssetsDirectory(for: sessionURL)
        try? fileManager.createDirectory(at: liveAssets, withIntermediateDirectories: true)
        if let files = try? fileManager.contentsOfDirectory(at: restoredAssets,
                                                             includingPropertiesForKeys: nil) {
            for file in files {
                let destination = liveAssets.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: file, to: destination)
            }
        }
        return document
    }

    private func fallbackURL(for sessionURL: URL?) -> URL {
        guard let sessionURL else {
            return fallbackDirectory.appendingPathComponent("untitled.json")
        }
        return fallbackDirectory.appendingPathComponent("\(stableHash(sessionURL.absoluteString)).json")
    }

    private func commitActivePage() {
        guard let index = notePages.firstIndex(where: { $0.id == activePageID }) else { return }
        notePages[index].text = text
        notePages[index].viewBookmarks = viewBookmarks
        notePages[index].screenshots = screenshots
    }

    private func loadActivePage() {
        guard let page = notePages.first(where: { $0.id == activePageID }) else { return }
        isLoading = true
        text = page.text
        viewBookmarks = page.viewBookmarks
        screenshots = page.screenshots
        isLoading = false
    }

    private func legacyAssetsDirectory(for sessionURL: URL) -> URL {
        let stem = sessionURL.deletingPathExtension().lastPathComponent
        return sessionURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem).raymol-notes-assets", isDirectory: true)
    }

    private func fallbackAssetsDirectory(for sessionURL: URL?) -> URL {
        let key = sessionURL.map { stableHash($0.absoluteString) } ?? "untitled"
        return fallbackDirectory.appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func migrateFallbackAssets(from oldURL: URL?, to newURL: URL?) {
        let source = fallbackAssetsDirectory(for: oldURL)
        let destination = fallbackAssetsDirectory(for: newURL)
        guard source.standardizedFileURL != destination.standardizedFileURL,
              let files = try? fileManager.contentsOfDirectory(at: source,
                                                                includingPropertiesForKeys: nil) else { return }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) { try? fileManager.copyItem(at: file, to: target) }
        }
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

    private func portableTimestamp() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
}

struct AnalysisExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .plainText, .html, .pdf] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum AnalysisNotesExporter {
    static func html(title: String, markdown: String,
                     bookmarks: [AnalysisNotesStore.ViewBookmark],
                     screenshots: [AnalysisNotesStore.ScreenshotAsset],
                     imageURL: (AnalysisNotesStore.ScreenshotAsset) -> URL?) -> String {
        var body = "<h1>\(escape(title))</h1>"
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            if let match = AnalysisNoteMarkdownParser.table(at: index - 1, in: lines),
               case .table(let alignments, let header, let rows) = match.block {
                index += match.lineCount - 1
                func row(_ cells: [String], tag: String) -> String {
                    "<tr>" + zip(cells, alignments).map { cell, alignment in
                        let text = escape(stripRayMolLinks(readable(cell, bookmarks: bookmarks, screenshots: screenshots)))
                        return "<\(tag) style=\"text-align:\(cssAlignment(alignment))\">\(text)</\(tag)>"
                    }.joined() + "</tr>"
                }
                body += "<table><thead>\(row(header, tag: "th"))</thead><tbody>"
                    + rows.map { row($0, tag: "td") }.joined() + "</tbody></table>"
                continue
            }
            if let asset = imageAsset(in: raw, screenshots: screenshots),
               let url = imageURL(asset), let data = try? Data(contentsOf: url) {
                body += "<figure><img src=\"data:image/png;base64,\(data.base64EncodedString())\"><figcaption>\(escape(asset.title))</figcaption></figure>"
                continue
            }
            let line = readable(raw, bookmarks: bookmarks, screenshots: screenshots)
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                body += "<h\(hashes)>\(escape(String(line.dropFirst(hashes + 1))))</h\(hashes)>"
            } else if line.hasPrefix("- ") {
                body += "<p class=\"bullet\">• \(escape(String(line.dropFirst(2))))</p>"
            } else if line.isEmpty {
                body += "<div class=\"space\"></div>"
            } else {
                body += "<p>\(escape(stripRayMolLinks(line)))</p>"
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5;max-width:780px;margin:48px auto;padding:0 28px;color:#18202a}h1{border-bottom:2px solid #d9e0e8;padding-bottom:12px}h2{margin-top:32px}.bullet{margin-left:18px}.space{height:10px}figure{margin:28px 0}img{max-width:100%;border-radius:8px}figcaption{color:#657080;font-size:13px;margin-top:6px}table{border-collapse:collapse;margin:14px 0;font-size:14px;font-variant-numeric:tabular-nums}th,td{border:1px solid #d9e0e8;padding:4px 9px;vertical-align:top}th{background:#f3f6f9}</style>
        </head><body>\(body)</body></html>
        """
    }

    static func pdf(title: String, markdown: String,
                    bookmarks: [AnalysisNotesStore.ViewBookmark],
                    screenshots: [AnalysisNotesStore.ScreenshotAsset],
                    imageURL: (AnalysisNotesStore.ScreenshotAsset) -> URL?) -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return Data() }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }
        let margin: CGFloat = 54
        var y: CGFloat = 0
        var page = 0

        func beginPage() {
            page += 1
            context.beginPDFPage(nil)
            y = mediaBox.height - margin
            drawText(title, size: 10, bold: true, color: CGColor(gray: 0.38, alpha: 1), spacing: 18)
            context.setStrokeColor(CGColor(gray: 0.84, alpha: 1))
            context.move(to: CGPoint(x: margin, y: y)); context.addLine(to: CGPoint(x: mediaBox.width - margin, y: y)); context.strokePath()
            y -= 20
        }
        func endPage() {
            let footer = "RayMol Analysis Notes  •  Page \(page)"
            drawLine(footer, x: margin, baseline: 28, size: 9, bold: false,
                     color: CGColor(gray: 0.45, alpha: 1))
            context.endPDFPage()
        }
        func ensure(_ height: CGFloat) {
            if y - height < margin { endPage(); beginPage() }
        }
        func drawText(_ value: String, size: CGFloat, bold: Bool,
                      color: CGColor = CGColor(gray: 0.08, alpha: 1), spacing: CGFloat = 8) {
            let font = CTFontCreateWithName(bold ? "Helvetica-Bold" as CFString : "Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let width = mediaBox.width - margin * 2
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                           CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            let height = max(ceil(suggested.height) + spacing, size + spacing)
            ensure(height)
            let path = CGPath(rect: CGRect(x: margin, y: y - height + spacing, width: width, height: height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
            y -= height
        }
        func drawLine(_ value: String, x: CGFloat, baseline: CGFloat, size: CGFloat,
                      bold: Bool, color: CGColor) {
            let font = CTFontCreateWithName(bold ? "Helvetica-Bold" as CFString : "Helvetica" as CFString, size, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]))
            context.textPosition = CGPoint(x: x, y: baseline); CTLineDraw(line, context)
        }

        func cellText(_ value: String, bold: Bool, alignment: AnalysisNoteTableAlignment) -> NSAttributedString {
            let font = CTFontCreateWithName(bold ? "Helvetica-Bold" as CFString : "Helvetica" as CFString, 9.5, nil)
            var textAlignment: CTTextAlignment = alignment == .center ? .center : alignment == .trailing ? .right : .left
            let style = withUnsafeBytes(of: &textAlignment) { bytes -> CTParagraphStyle in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: bytes.count,
                                                      value: bytes.baseAddress!)
                return CTParagraphStyleCreate(&setting, 1)
            }
            return NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style
            ])
        }
        func textSize(_ value: NSAttributedString, width: CGFloat) -> CGSize {
            CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(value), CFRange(), nil,
                                                         CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        }
        func drawTable(alignments: [AnalysisNoteTableAlignment], header: [String], rows: [[String]]) {
            let padding: CGFloat = 4
            let cells = ([header] + rows).enumerated().map { index, row in
                row.indices.map { column in
                    cellText(stripRayMolLinks(readable(row[column], bookmarks: bookmarks, screenshots: screenshots)),
                             bold: index == 0, alignment: alignments[column])
                }
            }
            // Columns take their natural width. When the table is wider than the
            // page, columns under an even share keep theirs and the wide ones
            // split what is left in proportion, so only they wrap.
            let available = mediaBox.width - margin * 2
            let natural = header.indices.map { column in
                (cells.map { ceil(textSize($0[column], width: .greatestFiniteMagnitude).width) }.max() ?? 0) + padding * 2
            }
            var widths = natural
            if natural.reduce(0, +) > available {
                let share = available / CGFloat(natural.count)
                let narrow = natural.filter { $0 <= share }.reduce(0, +)
                let wide = natural.filter { $0 > share }.reduce(0, +)
                widths = natural.map { $0 <= share ? $0 : $0 / wide * (available - narrow) }
            }
            let tableWidth = widths.reduce(0, +)

            func drawRow(_ row: [NSAttributedString], isHeader: Bool) {
                let height = row.indices.map {
                    ceil(textSize(row[$0], width: widths[$0] - padding * 2).height)
                }.max().map { $0 + padding * 2 } ?? 0
                if y - height < margin {
                    endPage(); beginPage()
                    if !isHeader { drawRow(cells[0], isHeader: true) }
                }
                if isHeader {
                    context.setFillColor(CGColor(gray: 0.95, alpha: 1))
                    context.fill(CGRect(x: margin, y: y - height, width: tableWidth, height: height))
                }
                var x = margin
                for column in row.indices {
                    let rect = CGRect(x: x + padding, y: y - height, width: widths[column] - padding * 2,
                                      height: height - padding)
                    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(row[column]),
                                                         CFRange(), CGPath(rect: rect, transform: nil), nil), context)
                    x += widths[column]
                }
                y -= height
                context.setStrokeColor(CGColor(gray: isHeader ? 0.7 : 0.86, alpha: 1))
                context.move(to: CGPoint(x: margin, y: y)); context.addLine(to: CGPoint(x: margin + tableWidth, y: y)); context.strokePath()
            }

            y -= 4
            for (index, row) in cells.enumerated() { drawRow(row, isHeader: index == 0) }
            y -= 10
        }

        beginPage()
        drawText(title, size: 25, bold: true, spacing: 18)
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            if let match = AnalysisNoteMarkdownParser.table(at: index - 1, in: lines),
               case .table(let alignments, let header, let rows) = match.block {
                index += match.lineCount - 1
                drawTable(alignments: alignments, header: header, rows: rows)
                continue
            }
            if let asset = imageAsset(in: raw, screenshots: screenshots),
               let url = imageURL(asset), let image = cgImage(at: url) {
                let maxHeight: CGFloat = 270
                let width = mediaBox.width - margin * 2
                let height = min(maxHeight, width * CGFloat(image.height) / CGFloat(image.width))
                ensure(height + 34)
                context.draw(image, in: CGRect(x: margin, y: y - height, width: width, height: height))
                y -= height + 5
                drawText(asset.title, size: 10, bold: false,
                         color: CGColor(gray: 0.38, alpha: 1), spacing: 12)
                continue
            }
            let line = readable(raw, bookmarks: bookmarks, screenshots: screenshots)
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                drawText(String(line.dropFirst(hashes + 1)), size: hashes == 1 ? 21 : max(13, 19 - CGFloat(hashes)), bold: true, spacing: 10)
            } else if line.isEmpty {
                y -= 7
            } else {
                drawText(stripRayMolLinks(line), size: 11.5, bold: false, spacing: 7)
            }
        }
        endPage(); context.closePDF()
        return output as Data
    }

    private static func readable(_ line: String,
                                 bookmarks: [AnalysisNotesStore.ViewBookmark],
                                 screenshots: [AnalysisNotesStore.ScreenshotAsset]) -> String {
        var result = line
        for bookmark in bookmarks {
            result = result.replacingOccurrences(
                of: AnalysisNoteMarkers.linkedImagePattern(bookmarkID: bookmark.id),
                with: "\(bookmark.resolvedKind.label) view: \(bookmark.title)",
                options: .regularExpression)
            result = result.replacingOccurrences(of: "[\(bookmark.title)](raymol-view://\(bookmark.id.uuidString))",
                                                  with: "\(bookmark.resolvedKind.label) view: \(bookmark.title)")
        }
        return result
    }

    private static func imageAsset(in line: String, screenshots: [AnalysisNotesStore.ScreenshotAsset]) -> AnalysisNotesStore.ScreenshotAsset? {
        screenshots.first { line.contains("raymol-asset://\($0.id.uuidString)") }
    }

    private static func stripRayMolLinks(_ value: String) -> String {
        value.replacingOccurrences(of: #"\[([^\]]+)\]\(raymol-residue://[^\)]+\)"#,
                                   with: "$1", options: .regularExpression)
    }

    private static func cssAlignment(_ alignment: AnalysisNoteTableAlignment) -> String {
        switch alignment {
        case .leading: return "left"
        case .center: return "center"
        case .trailing: return "right"
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func cgImage(at url: URL) -> CGImage? {
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return UIImage(contentsOfFile: url.path)?.cgImage
        #endif
    }
}

/// Shared regular-expression fragments for RayMol's private note markers.
enum AnalysisNoteMarkers {
    static let uuid = "[0-9A-Fa-f-]{36}"

    /// A thumbnail bound to a specific view link.
    static func linkedImagePattern(bookmarkID: UUID) -> String {
        #"\[!\[[^\]]*\]\(raymol-asset://\#(uuid)\)\]\(raymol-view://\#(bookmarkID.uuidString)\)"#
    }
}

enum AnalysisNotePreviewBlock: Equatable {
    case markdown(String)
    case image(UUID)
    /// A thumbnail (first id) that restores a view bookmark (second id) on tap.
    case linkedImage(UUID, UUID)
}

enum AnalysisNotePreviewParser {
    // The linked alternative comes first so a wrapped thumbnail is never split
    // into a stray "[" plus a bare image.
    private static let imagePattern =
        #"\[!\[[^\]]*\]\(raymol-asset://(\#(AnalysisNoteMarkers.uuid))\)\]\(raymol-view://(\#(AnalysisNoteMarkers.uuid))\)"#
        + #"|!\[[^\]]*\]\(raymol-asset://(\#(AnalysisNoteMarkers.uuid))\)"#

    /// Split the note into display blocks while preserving the position of each
    /// linked RayMol image. A single structural newline around a standalone image
    /// marker is consumed because the VStack supplies that block separation.
    static func blocks(in markdown: String) -> [AnalysisNotePreviewBlock] {
        guard !markdown.isEmpty,
              let expression = try? NSRegularExpression(pattern: imagePattern) else {
            return markdown.isEmpty ? [] : [.markdown(markdown)]
        }

        let matches = expression.matches(
            in: markdown,
            range: NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
        )
        guard !matches.isEmpty else { return [.markdown(markdown)] }

        var blocks: [AnalysisNotePreviewBlock] = []
        var cursor = markdown.startIndex

        for match in matches {
            guard let markerRange = Range(match.range, in: markdown),
                  let block = imageBlock(match, in: markdown) else { continue }

            let startsLine = markerRange.lowerBound == markdown.startIndex
                || markdown[markdown.index(before: markerRange.lowerBound)] == "\n"
            let endsLine = markerRange.upperBound == markdown.endIndex
                || markdown[markerRange.upperBound] == "\n"
            let standalone = startsLine && endsLine

            var textEnd = markerRange.lowerBound
            if standalone, textEnd > cursor,
               markdown[markdown.index(before: textEnd)] == "\n" {
                textEnd = markdown.index(before: textEnd)
            }
            if cursor < textEnd {
                blocks.append(.markdown(String(markdown[cursor..<textEnd])))
            }

            blocks.append(block)
            cursor = markerRange.upperBound
            if standalone, cursor < markdown.endIndex, markdown[cursor] == "\n" {
                cursor = markdown.index(after: cursor)
            }
        }

        if cursor < markdown.endIndex {
            blocks.append(.markdown(String(markdown[cursor...])))
        }
        return blocks
    }

    private static func imageBlock(_ match: NSTextCheckingResult,
                                   in markdown: String) -> AnalysisNotePreviewBlock? {
        func id(_ group: Int) -> UUID? {
            guard let range = Range(match.range(at: group), in: markdown) else { return nil }
            return UUID(uuidString: String(markdown[range]))
        }
        if let asset = id(1), let bookmark = id(2) { return .linkedImage(asset, bookmark) }
        if let asset = id(3) { return .image(asset) }
        return nil
    }
}

/// One block-level element of a note. `Text` applies only the inline attributes
/// of a parsed `AttributedString`, so block syntax has to be split out and given
/// its own view. Each case carries the inline Markdown of its line untouched —
/// RayMol's private link schemes are inline links and survive the split.
enum AnalysisNoteMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(depth: Int, text: String)
    case numbered(depth: Int, number: String, text: String)
    case quote(text: String)
    case code(lines: [String])
    case rule
    case table(alignments: [AnalysisNoteTableAlignment], header: [String], rows: [[String]])
    case paragraph(text: String)
}

/// Column alignment from a table's delimiter row: `:--`, `:-:` or `--:`.
enum AnalysisNoteTableAlignment: Equatable {
    case leading, center, trailing

    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

enum AnalysisNoteMarkdownParser {
    private static let numberedPattern = #"^(\d{1,9})[.)]\s+(.*)$"#

    /// Split a note segment into block elements, line by line. Consecutive
    /// non-empty lines join into one paragraph so a wrapped sentence stays a
    /// single run; a blank line ends it.
    static func blocks(in markdown: String) -> [AnalysisNoteMarkdownBlock] {
        var blocks: [AnalysisNoteMarkdownBlock] = []
        var paragraph: [String] = []
        var fence: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A fence that is still open when the note ends still renders as
            // code — notes are previewed while they are being typed.
            if trimmed.hasPrefix("```") {
                if let open = fence {
                    blocks.append(.code(lines: open))
                    fence = nil
                } else {
                    flushParagraph()
                    fence = []
                }
                continue
            }
            if fence != nil {
                fence?.append(line)
                continue
            }

            if trimmed.isEmpty { flushParagraph(); continue }

            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flushParagraph()
                blocks.append(.heading(
                    level: hashes,
                    text: String(trimmed.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let match = table(at: index - 1, in: lines) {
                flushParagraph()
                blocks.append(match.block)
                index += match.lineCount - 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }

            if let marker = trimmed.first, "-*+".contains(marker), trimmed.dropFirst().first == " " {
                flushParagraph()
                blocks.append(.bullet(depth: depth(of: line),
                                      text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if let match = trimmed.range(of: numberedPattern, options: .regularExpression) {
                let body = String(trimmed[match])
                let number = body.prefix { $0.isNumber }
                flushParagraph()
                blocks.append(.numbered(
                    depth: depth(of: line),
                    number: String(number),
                    text: String(body.dropFirst(number.count + 1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(trimmed)
        }

        if let open = fence { blocks.append(.code(lines: open)) }
        flushParagraph()
        return blocks
    }

    /// A pipe table starting at `start`: a header row, a delimiter row with the
    /// same column count, then every following line that holds a pipe. Returns
    /// the block and how many lines it spans. A table interrupts a paragraph, so
    /// one typed straight under a sentence still renders. Shared with the
    /// HTML/PDF exporters, which read the note line by line.
    static func table(at start: Int, in lines: [String]) -> (block: AnalysisNoteMarkdownBlock, lineCount: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"),
              let alignments = delimiterAlignments(lines[start + 1]) else { return nil }
        let header = cells(of: lines[start])
        guard header.count == alignments.count else { return nil }

        var rows: [[String]] = []
        var end = start + 2
        while end < lines.count {
            let row = lines[end].trimmingCharacters(in: .whitespaces)
            guard !row.isEmpty, row.contains("|") else { break }
            let values = cells(of: row)
            rows.append((0..<header.count).map { $0 < values.count ? values[$0] : "" })
            end += 1
        }
        return (.table(alignments: alignments, header: header, rows: rows), end - start)
    }

    /// Cells of one table row. One leading and one trailing pipe are optional;
    /// `\|` is a literal pipe inside a cell.
    private static func cells(of line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Alignments of a delimiter row such as `|---:|:--:|`, or nil when the
    /// line is not one. Each cell needs at least one dash.
    private static func delimiterAlignments(_ line: String) -> [AnalysisNoteTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"),
              trimmed.allSatisfy({ "|:- \t".contains($0) }) else { return nil }
        // A bare `---` is a rule, not a one-column table.
        guard trimmed.contains("|") || trimmed.contains(":") else { return nil }
        var alignments: [AnalysisNoteTableAlignment] = []
        for cell in cells(of: trimmed) {
            guard cell.contains("-"), cell.dropFirst().dropLast().allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Three or more of the same rule character, ignoring spaces between them.
    private static func isRule(_ trimmed: String) -> Bool {
        guard let marker = trimmed.first, "-*_".contains(marker) else { return false }
        let body = trimmed.filter { !$0.isWhitespace }
        return body.count >= 3 && body.allSatisfy { $0 == marker }
    }

    /// Nesting level from the leading indent — two spaces or one tab per level.
    private static func depth(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 }
            else if character == "\t" { columns += 2 }
            else { break }
        }
        return min(columns / 2, 4)
    }
}

/// Renders one block of a note. Split out of `NotesInspectorView` so block
/// rendering carries no engine or store dependency: it takes a parsed block and
/// a font size and nothing else, which also makes it renderable on its own.
struct AnalysisNoteBlockView: View {
    let block: AnalysisNoteMarkdownBlock
    let fontSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 7 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let depth, let text):
            listRow(depth: depth, marker: Text(bulletMarker(depth)).foregroundStyle(.secondary), text: text)
        case .numbered(let depth, let number, let text):
            listRow(depth: depth,
                    marker: Text("\(number).").monospacedDigit().foregroundStyle(.secondary),
                    text: text)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 3)
                Text(inlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let lines):
            Text(lines.joined(separator: "\n"))
                .font(.system(size: max(10, fontSize - 1), design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider().padding(.vertical, 3)
        case .table(let alignments, let header, let rows):
            table(alignments: alignments, header: header, rows: rows)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func table(alignments: [AnalysisNoteTableAlignment], header: [String],
                       rows: [[String]]) -> some View {
        let lines = [header] + rows
        return AnalysisNoteTableLayout(alignments: alignments) {
            ForEach(lines.indices, id: \.self) { row in
                ForEach(lines[row].indices, id: \.self) { column in
                    tableCell(lines[row][column], alignment: alignments[column], isHeader: row == 0)
                }
                if row < lines.count - 1 {
                    Divider().opacity(row == 0 ? 1 : 0.5)
                }
            }
        }
        .font(.system(size: max(10, fontSize - 1)))
        .monospacedDigit()
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    private func tableCell(_ text: String, alignment: AnalysisNoteTableAlignment,
                           isHeader: Bool) -> some View {
        Text(inlineMarkdown(text))
            .fontWeight(isHeader ? .semibold : .regular)
            .multilineTextAlignment(alignment.text)
            .textSelection(.enabled)
    }

    private func listRow(depth: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            Text(inlineMarkdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    private func bulletMarker(_ depth: Int) -> String {
        switch depth {
        case 0: return "\u{2022}"
        case 1: return "\u{25E6}"
        default: return "\u{25AA}"
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize * 1.55
        case 2: return fontSize * 1.3
        case 3: return fontSize * 1.14
        default: return fontSize * 1.04
        }
    }

    /// Inline-only parsing, applied per block. It keeps RayMol's `raymol-view`,
    /// `raymol-asset` and `raymol-residue` links intact as inline links, which
    /// the preview's `OpenURLAction` resolves back to a bookmark or selection.
    private func inlineMarkdown(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

/// Lays out a note table: each row's cells, then a divider before the next
/// row. `Grid` sizes wrapping text badly (rows come out far too tall), so the
/// columns are measured here. Columns take their natural width; when the table
/// is wider than the panel, columns under an even share keep theirs and the
/// wide ones split what is left, so only they wrap — the same rule as the PDF.
struct AnalysisNoteTableLayout: Layout {
    let alignments: [AnalysisNoteTableAlignment]
    var columnSpacing: CGFloat = 12
    var rowSpacing: CGFloat = 4

    private struct Metrics {
        var widths: [CGFloat]
        var rowHeights: [CGFloat]
        var dividerHeight: CGFloat
    }

    private var columns: Int { alignments.count }

    private func rowCount(_ subviews: Subviews) -> Int {
        (subviews.count + 1) / (columns + 1)
    }

    private func cell(_ row: Int, _ column: Int, in subviews: Subviews) -> LayoutSubview {
        subviews[row * (columns + 1) + column]
    }

    private func metrics(width: CGFloat?, subviews: Subviews) -> Metrics {
        let rows = rowCount(subviews)
        let natural = (0..<columns).map { column in
            (0..<rows).map { ceil(cell($0, column, in: subviews).sizeThatFits(.unspecified).width) }.max() ?? 0
        }
        var widths = natural
        let available = (width ?? .infinity) - columnSpacing * CGFloat(columns - 1)
        if natural.reduce(0, +) > available {
            let share = available / CGFloat(columns)
            let narrow = natural.filter { $0 <= share }.reduce(0, +)
            let wide = natural.filter { $0 > share }.reduce(0, +)
            widths = natural.map { $0 <= share ? $0 : max(share, $0 / wide * (available - narrow)) }
        }
        let rowHeights = (0..<rows).map { row in
            (0..<columns).map { column in
                cell(row, column, in: subviews)
                    .sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
        let dividerHeight = rows > 1
            ? subviews[columns].sizeThatFits(ProposedViewSize(width: widths.reduce(0, +), height: nil)).height
            : 0
        return Metrics(widths: widths, rowHeights: rowHeights, dividerHeight: dividerHeight)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard columns > 0 else { return .zero }
        let metrics = metrics(width: proposal.width, subviews: subviews)
        let gaps = CGFloat(max(0, metrics.rowHeights.count - 1))
        return CGSize(width: metrics.widths.reduce(0, +) + columnSpacing * CGFloat(columns - 1),
                      height: metrics.rowHeights.reduce(0, +) + gaps * (metrics.dividerHeight + rowSpacing * 2))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard columns > 0 else { return }
        let metrics = metrics(width: bounds.width, subviews: subviews)
        let tableWidth = metrics.widths.reduce(0, +) + columnSpacing * CGFloat(columns - 1)
        var y = bounds.minY
        for row in metrics.rowHeights.indices {
            var x = bounds.minX
            for column in 0..<columns {
                let width = metrics.widths[column]
                let (anchor, anchorX): (UnitPoint, CGFloat) = switch alignments[column] {
                case .leading: (.topLeading, x)
                case .center: (.top, x + width / 2)
                case .trailing: (.topTrailing, x + width)
                }
                cell(row, column, in: subviews).place(at: CGPoint(x: anchorX, y: y), anchor: anchor,
                                                      proposal: ProposedViewSize(width: width, height: nil))
                x += width + columnSpacing
            }
            y += metrics.rowHeights[row]
            if row < metrics.rowHeights.count - 1 {
                y += rowSpacing
                subviews[row * (columns + 1) + columns].place(
                    at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: tableWidth, height: metrics.dividerHeight))
                y += metrics.dividerHeight + rowSpacing
            }
        }
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
    @State private var pendingKind: AnalysisNotesStore.BookmarkKind = .camera
    @AppStorage("analysisNotesViewLinkThumbnail") private var includeViewThumbnail = true
    @State private var searchText = ""
    @State private var showingExporter = false
    @State private var exportData = Data()
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "RayMol Notes"
    @State private var showingNewPagePrompt = false
    @State private var showingRenamePagePrompt = false
    @State private var insertionNotice: String?
    @State private var pageName = ""
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteEditorFocused: Bool
    @State private var showingFullscreen = false
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// True for the copy of this view shown inside the iOS fullscreen cover. The
    /// cover hosts a second instance bound to the same `AnalysisNotesStore`, so
    /// the text, pages and view links are shared; only transient UI state (mode,
    /// search, prompts) is per-instance.
    var isFullscreenCover = false

    /// App-wide note commands (insert view link, toggle preview, font size) are
    /// delivered by NotificationCenter to every live instance. While the cover is
    /// up, the covered instance must stay quiet or each command would be handled
    /// twice (two view-name prompts, preview toggled back off, font stepping by 2).
    static func handlesExternalCommands(isFullscreenCover: Bool, fullscreenPresented: Bool) -> Bool {
        isFullscreenCover || !fullscreenPresented
    }

    private var acceptsExternalCommands: Bool {
        #if os(iOS)
        return Self.handlesExternalCommands(isFullscreenCover: isFullscreenCover,
                                            fullscreenPresented: showingFullscreen)
        #else
        return true
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            content(compactLayout: isCompactLayout(width: geometry.size.width))
        }
    }

    private func content(compactLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if showsSessionLabel {
                    Label(sessionLabel, systemImage: notes.sessionURL == nil ? "doc" : "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(notes.notePages) { page in
                        Button {
                            notes.selectPage(page.id)
                        } label: {
                            if page.id == notes.activePageID { Label(page.title, systemImage: "checkmark") }
                            else { Text(page.title) }
                        }
                    }
                    Divider()
                    Button("New Note…") { pageName = "Note \(notes.notePages.count + 1)"; showingNewPagePrompt = true }
                    Button("Rename Current Note…") { pageName = notes.activePageTitle; showingRenamePagePrompt = true }
                    Button("Delete Current Note", role: .destructive) { notes.deleteActivePage() }
                        .disabled(notes.notePages.count <= 1)
                } label: {
                    Label(notes.activePageTitle, systemImage: "doc.on.doc")
                        .font(.caption).lineLimit(1)
                }
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .help("Named note documents")
                saveStatus
                #if os(iOS)
                fullscreenToggleButton
                #endif
            }


            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(compactLayout ? "Search" : "Search notes", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: compactLayout ? 56 : 90)
                        .onSubmit { isPreviewing = true }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear note search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                Menu {
                    if notes.headings.isEmpty { Text("No Markdown headings") }
                    ForEach(Array(notes.headings.enumerated()), id: \.offset) { _, heading in
                        Button(String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title) {
                            searchText = heading.title
                            isPreviewing = true
                        }
                    }
                } label: { Image(systemName: "list.bullet.indent") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Heading outline")

                Menu {
                    if notes.tags.isEmpty { Text("Use tags such as #interface") }
                    ForEach(notes.tags, id: \.self) { tag in
                        Button(tag) { searchText = tag }
                    }
                } label: { Image(systemName: "number") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Note tags")
            }

            HStack(spacing: 8) {
                Picker("Note mode", selection: $isPreviewing) {
                    Label("Edit", systemImage: "square.and.pencil").tag(false)
                    Label("Preview", systemImage: "link").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 190)
                .help("Switch between editing and rendered preview")

                Spacer(minLength: 4)

                Button { fontSize = max(12, fontSize - 1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(fontSize <= 12)
                .help("Decrease note text size")

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
                    editor(compactLayout: compactLayout)
                }
            }
            .background(Color.primary.opacity(0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                Menu {
                    Button("Image from Current View") { insertMetalScreenshot() }
                    Divider()
                    Button("Camera Link") { beginViewLink(.camera) }
                    Button("Scene Link") { beginViewLink(.scene) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera")
                        Text(compactLayout ? "Insert" : "Insert Image / View")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                }
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(!engine.isReady)
                .help("Insert an image, camera link, or full-scene link")

                Menu {
                    Button("Selected Residues") { insertResidueSummary(contacts: false) }
                    Button("Contacts Around Selection") { insertResidueSummary(contacts: true) }
                    Button("Current Measurements") { insertMeasurementSummary() }
                } label: { Image(systemName: "atom") }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!engine.isReady)
                .help("Insert structured scientific data")

                Menu {
                    Button("Export Clean Markdown…") { beginExport(.plainText) }
                    Button("Export HTML with Images…") { beginExport(.html) }
                    Button("Export PDF with Images…") { beginExport(.pdf) }
                } label: { Image(systemName: "square.and.arrow.up") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Export Analysis Notes")

                #if os(macOS)
                Button { openWindow(id: "analysis-notes") } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open Notes in a detachable window")
                #endif

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, compactLayout ? 4 : 12)
        .padding(.vertical, compactLayout ? 8 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { notes.flush() }
        .sheet(isPresented: $showingViewNamePrompt) { viewLinkPrompt }
        .alert("Nothing to Insert", isPresented: Binding(
            get: { insertionNotice != nil },
            set: { if !$0 { insertionNotice = nil } }
        )) {
            Button("OK", role: .cancel) { insertionNotice = nil }
        } message: {
            Text(insertionNotice ?? "")
        }
        .alert("New Note", isPresented: $showingNewPagePrompt) {
            TextField("Note name", text: $pageName)
            Button("Create") { notes.createPage(named: pageName) }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Rename Note", isPresented: $showingRenamePagePrompt) {
            TextField("Note name", text: $pageName)
            Button("Rename") { notes.renameActivePage(pageName) }
            Button("Cancel", role: .cancel) { }
        }
        .fileExporter(isPresented: $showingExporter,
                      document: AnalysisExportDocument(data: exportData),
                      contentType: exportContentType,
                      defaultFilename: exportFilename) { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformInsertNoteView)) { _ in
            guard acceptsExternalCommands else { return }
            beginViewLink(.camera)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformToggleNotePreview)) { _ in
            guard acceptsExternalCommands else { return }
            isPreviewing.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformFontIncrease)) { _ in
            guard acceptsExternalCommands else { return }
            fontSize = min(28, fontSize + 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformFontDecrease)) { _ in
            guard acceptsExternalCommands else { return }
            fontSize = max(12, fontSize - 1)
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { noteEditorFocused = false }
            }
        }
        .background { if isFullscreenCover { Color(.systemBackground).ignoresSafeArea() } }
        .fullScreenCover(isPresented: $showingFullscreen) {
            NotesInspectorView(isFullscreenCover: true)
                .environmentObject(notes)
                .environmentObject(engine)
        }
        #endif
    }

    #if os(iOS)
    /// Expand the Notes panel to a fullscreen cover (and collapse it back). The
    /// panel is small on iPhone and in the iPad side column; this gives the editor
    /// the whole screen without a second copy of the data.
    private var fullscreenToggleButton: some View {
        Button {
            if isFullscreenCover { dismiss() } else { showingFullscreen = true }
        } label: {
            Image(systemName: isFullscreenCover
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .frame(width: 44, height: 44)   // HIG minimum touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel(isFullscreenCover ? "Collapse notes" : "Expand notes to fullscreen")
        .accessibilityIdentifier("notes-fullscreen-toggle")
    }
    #endif

    private func editor(compactLayout: Bool) -> some View {
        TextEditor(text: $notes.text)
            #if os(iOS)
            .focused($noteEditorFocused)
            #endif
            .font(.system(size: fontSize))
            .scrollContentBackground(.hidden)
            .padding(compactLayout ? 1 : 6)
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
            VStack(alignment: .leading, spacing: 12) {
                if notes.text.isEmpty {
                    Text("Nothing to preview yet.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(previewBlocks.enumerated()), id: \.offset) { _, block in
                        previewBlock(block)
                    }
                }
                if !notes.viewBookmarks.isEmpty {
                    Divider()
                    Text("VIEW LINKS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(notes.viewBookmarks) { bookmark in
                        Button { restore(bookmark) } label: {
                            HStack {
                                Image(systemName: bookmark.resolvedKind == .camera ? "camera.viewfinder" : "rectangle.on.rectangle")
                                Text(bookmark.title).lineLimit(1)
                                Spacer()
                                Text(bookmark.resolvedKind.label)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .font(.system(size: fontSize))
        .padding(12)
        .environment(\.openURL, OpenURLAction { url in
            if let bookmark = notes.viewBookmark(for: url) {
                restore(bookmark)
                return .handled
            }
            if restoreResidue(url) { return .handled }
            return .systemAction
        })
    }

    private var previewBlocks: [AnalysisNotePreviewBlock] {
        AnalysisNotePreviewParser.blocks(in: filteredNoteText)
    }

    @ViewBuilder private func previewBlock(_ block: AnalysisNotePreviewBlock) -> some View {
        switch block {
        case .markdown(let markdown):
            let blocks = AnalysisNoteMarkdownParser.blocks(in: markdown)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    AnalysisNoteBlockView(block: block, fontSize: fontSize)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .image(let id):
            if let asset = notes.screenshots.first(where: { $0.id == id }) {
                screenshotView(asset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                missingImageLabel
            }
        case .linkedImage(let assetID, let bookmarkID):
            if let asset = notes.screenshots.first(where: { $0.id == assetID }) {
                let bookmark = notes.viewBookmarks.first { $0.id == bookmarkID }
                Button { if let bookmark { restore(bookmark) } } label: {
                    VStack(alignment: .leading, spacing: 4) { screenshotView(asset) }
                }
                .buttonStyle(.plain)
                .disabled(bookmark == nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(bookmark.map { "Restore \($0.resolvedKind.label.lowercased()) view: \($0.title)" }
                      ?? "Linked view unavailable")
                .accessibilityLabel(bookmark.map { "Restore view \($0.title)" } ?? asset.title)
            } else {
                missingImageLabel
            }
        }
    }

    private var missingImageLabel: some View {
        Label("Linked image unavailable", systemImage: "photo.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var filteredNoteText: String {
        guard !searchText.isEmpty else { return notes.text }
        return notes.text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { String($0).localizedCaseInsensitiveContains(searchText) }
            .joined(separator: "\n")
    }

    @ViewBuilder private func screenshotView(_ asset: AnalysisNotesStore.ScreenshotAsset) -> some View {
        if let url = notes.screenshotURL(for: asset) {
            #if os(macOS)
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(asset.title).font(.caption).foregroundStyle(.secondary)
            }
            #else
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(asset.title).font(.caption).foregroundStyle(.secondary)
            }
            #endif
        }
    }

    /// A sheet rather than an alert: alerts accept only text fields and buttons,
    /// and the thumbnail option needs a real Toggle.
    private var viewLinkPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert View Link").font(.headline)
            Text(pendingKind == .camera
                 ? "Camera links restore orientation, zoom, and clipping."
                 : "Scene links restore the full PyMOL scene. Save the .pse after adding one so the scene travels with the session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Link name", text: $viewName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitViewLinkPrompt() }

            Toggle("Include image of the view", isOn: $includeViewThumbnail)
                .help("Insert a thumbnail of the current view; clicking it in the preview restores this view")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pendingView = nil
                    showingViewNamePrompt = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Insert") { commitViewLinkPrompt() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
    }

    private func commitViewLinkPrompt() {
        showingViewNamePrompt = false
        insertPendingView()
    }

    private func beginViewLink(_ kind: AnalysisNotesStore.BookmarkKind) {
        guard let view = engine.captureView() else { return }
        pendingView = view
        pendingKind = kind
        viewName = kind == .camera ? "Camera \(notes.viewBookmarks.count + 1)" : "Scene \(notes.viewBookmarks.count + 1)"
        showingViewNamePrompt = true
    }

    private func insertPendingView() {
        guard let view = pendingView else { return }
        pendingView = nil
        let id = UUID()
        let title = markdownSafe(viewName)
        let sceneName = pendingKind == .scene ? "__raymol_note_\(id.uuidString.replacingOccurrences(of: "-", with: ""))" : nil
        if let sceneName { engine.runCommand("scene \(sceneName), store") }
        let thumbnail = includeViewThumbnail ? renderNoteScreenshot() : nil
        guard let bookmark = notes.addViewBookmark(id: id, title: title, view: view,
                                                  kind: pendingKind, sceneName: sceneName,
                                                  insertsMarkdown: thumbnail == nil) else {
            if let thumbnail { try? FileManager.default.removeItem(at: thumbnail) }
            return
        }
        if let thumbnail {
            // Fall back to the bare link if the render could not be filed, so the
            // bookmark never ends up with no marker in the note.
            if notes.addScreenshot(title: title, from: thumbnail, linkedBookmarkID: id) == nil {
                notes.appendViewLink(bookmark)
            }
            try? FileManager.default.removeItem(at: thumbnail)
        }
    }

    /// Render the live view to a temporary PNG. The caller owns the file.
    private func renderNoteScreenshot() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-note-\(UUID().uuidString).png")
        engine.renderHiResPNG(url.path, width: 1600, height: 1200)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func restore(_ bookmark: AnalysisNotesStore.ViewBookmark) {
        if bookmark.resolvedKind == .scene, let sceneName = bookmark.sceneName {
            engine.runCommand("scene \(sceneName), recall, animate=0.45")
        } else {
            engine.restoreView(bookmark.view)
        }
    }

    private func insertMetalScreenshot() {
        guard let url = renderNoteScreenshot() else { return }
        _ = notes.addScreenshot(title: "Molecular view \(notes.screenshots.count + 1)", from: url)
        try? FileManager.default.removeItem(at: url)
    }

    private func insertResidueSummary(contacts: Bool) {
        let rows = engine.noteResidues(contacts: contacts)
        guard !rows.isEmpty else {
            insertionNotice = "Create a `sele` selection in the 3D view first. The note was not changed."
            return
        }
        let heading = contacts ? "## Contacts around selection (4.0 Å)" : "## Selected residues"
        var lines = [heading, ""]
        lines += rows.map { row in
            let chain = row["chain", default: ""]
            let resi = row["resi", default: ""]
            let resn = row["resn", default: "UNK"]
            let object = row["object", default: ""]
            let label = [resn, chain.isEmpty ? nil : "chain \(chain)", resi].compactMap { $0 }.joined(separator: " ")
            return "- [\(label)](\(residueURL(object: object, chain: chain, resi: resi)))"
        }
        appendMarkdown(lines.joined(separator: "\n") + "\n")
    }

    private func insertMeasurementSummary() {
        let rows = engine.noteMeasurements()
        guard !rows.isEmpty else {
            insertionNotice = "Create a RayMol measurement first. The note was not changed."
            return
        }
        var lines = ["## Measurements", ""]
        lines += rows.map { row in
            let name = row["name"] as? String ?? "measurement"
            let kind = row["kind"] as? String ?? "distance"
            let value = (row["value"] as? NSNumber)?.doubleValue ?? 0
            let unit = kind == "distance" ? "Å" : "°"
            let picks = (row["picks"] as? [String])?.joined(separator: " → ") ?? ""
            return "- **\(name)** (\(kind)): \(String(format: kind == "distance" ? "%.2f" : "%.1f", value)) \(unit) — \(picks)"
        }
        appendMarkdown(lines.joined(separator: "\n") + "\n")
    }

    private func appendMarkdown(_ value: String) {
        let separator = notes.text.isEmpty ? "" : (notes.text.hasSuffix("\n\n") ? "" : "\n\n")
        notes.text += separator + value
    }

    private func residueURL(object: String, chain: String, resi: String) -> String {
        var components = URLComponents()
        components.scheme = "raymol-residue"
        components.host = "select"
        components.queryItems = [URLQueryItem(name: "object", value: object),
                                 URLQueryItem(name: "chain", value: chain),
                                 URLQueryItem(name: "resi", value: resi)]
        return components.url?.absoluteString ?? ""
    }

    private func restoreResidue(_ url: URL) -> Bool {
        guard url.scheme == "raymol-residue",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
        guard let object = values["object"], let chain = values["chain"], let resi = values["resi"] else { return false }
        engine.selectNoteResidue(object: object, chain: chain, resi: resi)
        return true
    }

    private func markdownSafe(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    private var sessionLabel: String {
        notes.sessionURL?.lastPathComponent ?? "Unsaved session"
    }

    /// iOS has no document model: Save and Share both export a *copy* through the
    /// document picker / activity sheet, so the app never holds a writable URL and
    /// a note is bound to a file only when one was opened. Showing "Unsaved
    /// session" the rest of the time reads as "your work is at risk", which is
    /// wrong — notes ride inside the iOS autosave .pse. Show the label only when
    /// it can name a real document. macOS keeps it always (⌘S binds a document).
    private var showsSessionLabel: Bool {
        #if os(iOS)
        return notes.sessionURL != nil
        #else
        return true
        #endif
    }

    private func beginExport(_ contentType: UTType) {
        exportContentType = contentType
        switch contentType {
        case .plainText:
            exportData = Data(notes.cleanMarkdown.utf8)
            exportFilename = markdownFilename
        case .html:
            exportData = Data(notes.exportHTML().utf8)
            exportFilename = exportBaseName + ".html"
        default:
            exportData = notes.exportPDFData()
            exportFilename = exportBaseName + ".pdf"
        }
        showingExporter = true
    }

    private var markdownFilename: String {
        exportBaseName + ".md"
    }

    private var exportBaseName: String {
        let session = notes.sessionURL?.deletingPathExtension().lastPathComponent ?? "RayMol"
        let page = notes.activePageTitle.replacingOccurrences(of: "/", with: "-")
        return "\(session) - \(page)"
    }

    private func isCompactLayout(width: CGFloat) -> Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact || width < 430
        #else
        return width < 430
        #endif
    }

    @ViewBuilder private var saveStatus: some View {
        switch notes.saveState {
        case .saved, .pending:
            EmptyView()
        case .failed(let message):
            Label("Not saved", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
