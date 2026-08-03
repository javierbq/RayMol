// NotesInspectorView.swift — session-linked analysis scratchpad.

import SwiftUI
import UniformTypeIdentifiers
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Plain-text analysis notes associated with the current PyMOL session.
///
/// A portable JSON sidecar is preferred (`sample.raymol-notes.json`). Sandboxed
/// file-provider URLs are not always writable after their picker access ends, so
/// every note is also mirrored into Application Support under a stable URL key.
/// That fallback keeps notes available on iPhone/iPad without requiring broad
/// file-system access.
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

    @discardableResult
    func addViewBookmark(id: UUID = UUID(), title: String, view: [Float],
                         kind: BookmarkKind = .camera,
                         sceneName: String? = nil) -> ViewBookmark? {
        guard view.count == 25 else { return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = ViewBookmark(id: id,
                                    title: cleanTitle.isEmpty ? "Saved view" : cleanTitle,
                                    view: view,
                                    createdAt: portableTimestamp(), kind: kind,
                                    sceneName: sceneName)
        viewBookmarks.append(bookmark)
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += "\(separator)[\(bookmark.title)](raymol-view://\(bookmark.id.uuidString))"
        saveState = .pending
        scheduleSave()
        return bookmark
    }

    @discardableResult
    func addScreenshot(title: String, from sourceURL: URL) -> ScreenshotAsset? {
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
            text += "\(separator)![\(asset.title)](raymol-asset://\(asset.id.uuidString))"
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
        if let sessionURL {
            let portable = assetsDirectory(for: sessionURL).appendingPathComponent(asset.fileName)
            if fileManager.fileExists(atPath: portable.path) { return portable }
            // Share sheets and multi-file document pickers may flatten the
            // companion asset folder. Accept a PNG beside the .pse as well.
            let sibling = sessionURL.deletingLastPathComponent().appendingPathComponent(asset.fileName)
            if fileManager.fileExists(atPath: sibling.path) { return sibling }
        }
        let fallback = fallbackAssetsDirectory(for: sessionURL).appendingPathComponent(asset.fileName)
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
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

    /// Write a portable companion for an exported copy of a session without
    /// rebinding the live document to that temporary export URL.
    func writePortableSidecar(nextTo sessionURL: URL) -> URL? {
        commitActivePage()
        let document = Document(sessionName: sessionURL.lastPathComponent,
                                updatedAt: Date(), text: text,
                                viewBookmarks: viewBookmarks,
                                screenshots: screenshots,
                                notePages: notePages,
                                activePageID: activePageID)
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

    /// Sidecar plus linked image assets for Share and document export flows.
    func portableCompanions(nextTo sessionURL: URL) -> [URL] {
        commitActivePage()
        var urls: [URL] = []
        if let sidecar = writePortableSidecar(nextTo: sessionURL) { urls.append(sidecar) }
        let directory = assetsDirectory(for: sessionURL)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Include the live page explicitly. Before the first session is opened,
        // there is no NotePage to commit into yet, but its screenshots still
        // need to travel with a shared or newly saved session.
        var seenAssetIDs = Set<UUID>()
        let assets = (notePages.flatMap(\.screenshots) + screenshots).filter {
            seenAssetIDs.insert($0.id).inserted
        }
        for asset in assets {
            guard let source = screenshotURL(for: asset) else { continue }
            let destination = directory.appendingPathComponent(asset.fileName)
            if source.standardizedFileURL != destination.standardizedFileURL {
                try? fileManager.removeItem(at: destination)
                try? fileManager.copyItem(at: source, to: destination)
            }
            if fileManager.fileExists(atPath: destination.path) { urls.append(destination) }
        }
        return urls
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

            // The fallback is authoritative in a sandbox. The sidecar is an
            // additional portable copy when the session's directory is writable.
            if let sessionURL {
                let scoped = sessionURL.startAccessingSecurityScopedResource()
                defer { if scoped { sessionURL.stopAccessingSecurityScopedResource() } }
                try? data.write(to: sidecarURL(for: sessionURL), options: .atomic)
                _ = portableCompanions(nextTo: sessionURL)
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

    private func assetsDirectory(for sessionURL: URL) -> URL {
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

struct MarkdownNoteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct AnalysisExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data, .html, .pdf] }
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
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5;max-width:780px;margin:48px auto;padding:0 28px;color:#18202a}h1{border-bottom:2px solid #d9e0e8;padding-bottom:12px}h2{margin-top:32px}.bullet{margin-left:18px}.space{height:10px}figure{margin:28px 0}img{max-width:100%;border-radius:8px}figcaption{color:#657080;font-size:13px;margin-top:6px}</style>
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

        beginPage()
        drawText(title, size: 25, bold: true, spacing: 18)
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
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

private struct AnalysisNoteTemplate: Identifiable {
    let id: String
    let name: String
    let text: String
    static let all: [Self] = [
        .init(id: "observation", name: "Structural observation", text: "# Structural observation\n\n## Context\n\n## Observation\n\n## Interpretation\n\n## Follow-up\n"),
        .init(id: "binding", name: "Binding site", text: "# Binding-site analysis\n\n## Ligand and pose\n\n## Key contacts\n\n- Hydrogen bonds:\n- Hydrophobic contacts:\n- Waters / ions:\n\n## Open questions\n\n#binding-site\n"),
        .init(id: "interface", name: "Protein interface", text: "# Interface analysis\n\n## Chains / partners\n\n## Contact residues\n\n## Hotspot hypothesis\n\n## Validation plan\n\n#interface\n"),
        .init(id: "mutation", name: "Mutation comparison", text: "# Mutation comparison\n\n## Wild type\n\n## Variant\n\n## Structural change\n\n## Functional hypothesis\n\n#mutation\n"),
        .init(id: "glycan", name: "Glycan / PTM", text: "# Glycan or PTM analysis\n\n## Site and chemistry\n\n## Local environment\n\n## Conformational effects\n\n## Evidence\n\n#ptm\n")
    ]
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
    @State private var searchText = ""
    @State private var showingMarkdownExporter = false
    @State private var showingShareHelp = false
    @State private var showingHTMLExporter = false
    @State private var showingPDFExporter = false
    @State private var showingNewPagePrompt = false
    @State private var showingRenamePagePrompt = false
    @State private var pageName = ""
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(sessionLabel, systemImage: notes.sessionURL == nil ? "doc" : "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                .help("Named note documents")
                saveStatus
            }


            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { isPreviewing = true }
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
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
                .help("Heading outline")

                Menu {
                    if notes.tags.isEmpty { Text("Use tags such as #interface") }
                    ForEach(notes.tags, id: \.self) { tag in
                        Button(tag) { searchText = tag }
                    }
                } label: { Image(systemName: "number") }
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
                Menu {
                    Button("Camera Only") { beginViewLink(.camera) }
                    Button("Full Scene") { beginViewLink(.scene) }
                } label: {
                    Label("Insert View Link", systemImage: "camera.viewfinder")
                }
                .disabled(!engine.isReady)
                .help("Insert a camera-only or full-scene link (⌥⌘L)")

                Menu {
                    ForEach(AnalysisNoteTemplate.all) { template in
                        Button(template.name) { appendTemplate(template) }
                    }
                } label: { Image(systemName: "doc.badge.plus") }
                .help("Append an analysis template")

                Menu {
                    Button("Selected Residues") { insertResidueSummary(contacts: false) }
                    Button("Contacts Around Selection") { insertResidueSummary(contacts: true) }
                    Button("Current Measurements") { insertMeasurementSummary() }
                } label: { Image(systemName: "atom") }
                .disabled(!engine.isReady)
                .help("Insert structured scientific data")

                Button { insertMetalScreenshot() } label: {
                    Image(systemName: "camera")
                }
                .disabled(!engine.isReady)
                .help("Insert a Metal-rendered screenshot")

                Menu {
                    Button("Export Clean Markdown…") { showingMarkdownExporter = true }
                    Button("Export HTML with Images…") { showingHTMLExporter = true }
                    Button("Export PDF with Images…") { showingPDFExporter = true }
                    Button("Sharing Notes & Sessions…") { showingShareHelp = true }
                } label: { Image(systemName: "square.and.arrow.up") }

                #if os(macOS)
                Button { openWindow(id: "analysis-notes") } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .help("Open Notes in a detachable window")
                #endif

                Spacer()

                Text(summaryLabel)
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
            Text(pendingKind == .camera
                 ? "Camera links restore orientation, zoom, and clipping."
                 : "Scene links restore the full PyMOL scene. Save the .pse after adding one so the scene travels with the session.")
        }
        .alert("Sharing Analysis Notes", isPresented: $showingShareHelp) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Share Session and Save Session automatically include the .raymol-notes.json sidecar and linked PNG images. Keep the files together. Full-scene links also require the saved .pse because their scene data lives inside the PyMOL session.")
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
        .fileExporter(isPresented: $showingMarkdownExporter,
                      document: MarkdownNoteDocument(text: notes.cleanMarkdown),
                      contentType: .plainText,
                      defaultFilename: markdownFilename) { _ in }
        .fileExporter(isPresented: $showingHTMLExporter,
                      document: AnalysisExportDocument(data: Data(notes.exportHTML().utf8)),
                      contentType: .html,
                      defaultFilename: exportBaseName + ".html") { _ in }
        .fileExporter(isPresented: $showingPDFExporter,
                      document: AnalysisExportDocument(data: notes.exportPDFData()),
                      contentType: .pdf,
                      defaultFilename: exportBaseName + ".pdf") { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformInsertNoteView)) { _ in
            beginViewLink(.camera)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformToggleNotePreview)) { _ in
            isPreviewing.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformFontIncrease)) { _ in
            fontSize = min(28, fontSize + 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .raymolPerformFontDecrease)) { _ in
            fontSize = max(12, fontSize - 1)
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
            VStack(alignment: .leading, spacing: 12) {
            if notes.text.isEmpty {
                Text("Nothing to preview yet.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(renderedNotes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            if !notes.screenshots.isEmpty {
                Divider()
                Text("LINKED IMAGES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(notes.screenshots) { asset in
                    screenshotView(asset)
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

    private var renderedNotes: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let source = filteredNoteText
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
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

    private func beginViewLink(_ kind: AnalysisNotesStore.BookmarkKind) {
        guard let view = engine.captureView() else { return }
        pendingView = view
        pendingKind = kind
        viewName = kind == .camera ? "Camera \(notes.viewBookmarks.count + 1)" : "Scene \(notes.viewBookmarks.count + 1)"
        showingViewNamePrompt = true
    }

    private func insertPendingView() {
        guard let view = pendingView else { return }
        let id = UUID()
        let sceneName = pendingKind == .scene ? "__raymol_note_\(id.uuidString.replacingOccurrences(of: "-", with: ""))" : nil
        if let sceneName { engine.runCommand("scene \(sceneName), store") }
        _ = notes.addViewBookmark(id: id, title: markdownSafe(viewName), view: view,
                                  kind: pendingKind, sceneName: sceneName)
        pendingView = nil
        isPreviewing = true
    }

    private func restore(_ bookmark: AnalysisNotesStore.ViewBookmark) {
        if bookmark.resolvedKind == .scene, let sceneName = bookmark.sceneName {
            engine.runCommand("scene \(sceneName), recall, animate=0.45")
        } else {
            engine.restoreView(bookmark.view)
        }
    }

    private func appendTemplate(_ template: AnalysisNoteTemplate) {
        let separator = notes.text.isEmpty ? "" : (notes.text.hasSuffix("\n\n") ? "" : "\n\n")
        notes.text += separator + template.text
    }

    private func insertMetalScreenshot() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("raymol-note-\(UUID().uuidString).png")
        engine.renderHiResPNG(url.path, width: 1600, height: 1200)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = notes.addScreenshot(title: "Molecular view \(notes.screenshots.count + 1)", from: url)
        try? FileManager.default.removeItem(at: url)
        isPreviewing = true
    }

    private func insertResidueSummary(contacts: Bool) {
        let rows = engine.noteResidues(contacts: contacts)
        let heading = contacts ? "## Contacts around selection (4.0 Å)" : "## Selected residues"
        var lines = [heading, ""]
        if rows.isEmpty {
            lines.append("_No residues found. Create a `sele` selection in the 3D view first._")
        } else {
            lines += rows.map { row in
                let chain = row["chain", default: ""]
                let resi = row["resi", default: ""]
                let resn = row["resn", default: "UNK"]
                let object = row["object", default: ""]
                let label = [resn, chain.isEmpty ? nil : "chain \(chain)", resi].compactMap { $0 }.joined(separator: " ")
                return "- [\(label)](\(residueURL(object: object, chain: chain, resi: resi)))"
            }
        }
        appendMarkdown(lines.joined(separator: "\n") + "\n")
        isPreviewing = true
    }

    private func insertMeasurementSummary() {
        let rows = engine.noteMeasurements()
        var lines = ["## Measurements", ""]
        if rows.isEmpty {
            lines.append("_No RayMol measurements have been created in this run._")
        } else {
            lines += rows.map { row in
                let name = row["name"] as? String ?? "measurement"
                let kind = row["kind"] as? String ?? "distance"
                let value = (row["value"] as? NSNumber)?.doubleValue ?? 0
                let unit = kind == "distance" ? "Å" : "°"
                let picks = (row["picks"] as? [String])?.joined(separator: " → ") ?? ""
                return "- **\(name)** (\(kind)): \(String(format: kind == "distance" ? "%.2f" : "%.1f", value)) \(unit) — \(picks)"
            }
        }
        appendMarkdown(lines.joined(separator: "\n") + "\n")
        isPreviewing = true
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

    private var markdownFilename: String {
        exportBaseName + ".md"
    }

    private var exportBaseName: String {
        let session = notes.sessionURL?.deletingPathExtension().lastPathComponent ?? "RayMol"
        let page = notes.activePageTitle.replacingOccurrences(of: "/", with: "-")
        return "\(session) - \(page)"
    }

    private var summaryLabel: String {
        let matches = searchText.isEmpty ? nil : notes.text.split(separator: "\n").filter { String($0).localizedCaseInsensitiveContains(searchText) }.count
        if let matches { return "\(matches) matches" }
        return "\(notes.viewBookmarks.count) views · \(notes.tags.count) tags"
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
