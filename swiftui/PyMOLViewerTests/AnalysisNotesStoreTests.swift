import XCTest
@testable import RayMol

final class AnalysisNotesStoreTests: XCTestCase {
    @MainActor
    func testSavedSessionStagesEmbeddedDocumentAndReloadsRecoveryCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = root.appendingPathComponent("experiment.pse")
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        let writer = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        var stagedDocument: URL?
        writer.configureEmbeddedPersistence(
            stage: { document, _ in stagedDocument = document; return true },
            export: { _, _ in false }
        )
        writer.text = "Chain A moves toward the ligand after minimization."
        writer.sessionDidSave(to: session)

        XCTAssertNotNil(stagedDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDocument?.path ?? ""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.sidecarURL(for: session).path))

        let reader = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        reader.openSession(at: session)
        XCTAssertEqual(reader.text, writer.text)
        XCTAssertEqual(reader.saveState, .saved)
    }

    @MainActor
    func testFirstSaveKeepsUntitledScratchpadText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalysisNotesStore(
            fallbackDirectory: root.appendingPathComponent("fallback", isDirectory: true),
            debounceInterval: 60
        )
        store.text = "Preserve this observation when Save As chooses a session."

        let session = root.appendingPathComponent("saved-session.pse")
        store.sessionDidSave(to: session)

        XCTAssertEqual(store.text, "Preserve this observation when Save As chooses a session.")
        XCTAssertEqual(store.sessionURL, session.standardizedFileURL)
    }

    @MainActor
    func testUntitledScratchpadUsesApplicationSupportFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let writer = AnalysisNotesStore(fallbackDirectory: root, debounceInterval: 60)
        writer.text = "An observation made before the session was named."
        writer.flush()

        let reader = AnalysisNotesStore(fallbackDirectory: root, debounceInterval: 60)
        reader.openSession(at: nil)
        XCTAssertEqual(reader.text, writer.text)
    }

    @MainActor
    func testViewBookmarkPersistsWithClickableNoteLink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = root.appendingPathComponent("interaction.pse")
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        let writer = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        let view = (0..<25).map(Float.init)
        let bookmark = try XCTUnwrap(writer.addViewBookmark(title: "Ligand contact", view: view))
        writer.sessionDidSave(to: session)

        let reader = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        reader.openSession(at: session)
        XCTAssertEqual(reader.viewBookmarks, [bookmark])
        XCTAssertTrue(reader.text.contains("raymol-view://\(bookmark.id.uuidString)"))
        XCTAssertEqual(reader.viewBookmark(for: URL(string: "raymol-view://\(bookmark.id.uuidString)")!), bookmark)
    }

    @MainActor
    func testSceneBookmarkPersistsKindAndSceneName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AnalysisNotesStore(fallbackDirectory: root, debounceInterval: 60)
        let bookmark = try XCTUnwrap(store.addViewBookmark(
            title: "Complete interface", view: (0..<25).map(Float.init),
            kind: .scene, sceneName: "__raymol_note_test"
        ))
        XCTAssertEqual(bookmark.resolvedKind, .scene)
        XCTAssertEqual(bookmark.sceneName, "__raymol_note_test")
        XCTAssertTrue(store.cleanMarkdown.contains("**Scene view:** Complete interface"))
        XCTAssertFalse(store.cleanMarkdown.contains("raymol-view://"))
    }

    @MainActor
    func testHeadingsAndTagsAreDerivedFromMarkdown() {
        let store = AnalysisNotesStore(debounceInterval: 60)
        store.text = "# Binding site\n## Contacts\nLook at #interface and #glycan.\n#interface"

        XCTAssertEqual(store.headings.map(\.title), ["Binding site", "Contacts"])
        XCTAssertEqual(store.tags, ["#glycan", "#interface"])
    }

    @MainActor
    func testScreenshotIsStagedWithEmbeddedDocument() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        let store = AnalysisNotesStore(
            fallbackDirectory: root.appendingPathComponent("fallback", isDirectory: true),
            debounceInterval: 60
        )
        var stagedAssets: [URL] = []
        store.configureEmbeddedPersistence(
            stage: { _, directory in
                stagedAssets = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
                return true
            },
            export: { _, _ in false }
        )
        let asset = try XCTUnwrap(store.addScreenshot(title: "Metal view", from: source))
        store.flush()

        XCTAssertTrue(store.text.contains("raymol-asset://\(asset.id.uuidString)"))
        XCTAssertEqual(stagedAssets.filter { $0.pathExtension == "png" }.count, 1)
        XCTAssertEqual(store.cleanMarkdown, "**Figure:** Metal view")
    }

    @MainActor
    func testMultipleNamedNotesPersistIndependently() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("notebook.pse")
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)

        let writer = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        writer.openSession(at: session)
        writer.renameActivePage("Interface")
        writer.text = "Interface observation"
        let firstID = try XCTUnwrap(writer.activePageID)
        writer.createPage(named: "Mutations")
        writer.text = "Variant observation"
        writer.sessionDidSave(to: session)

        let reader = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        reader.openSession(at: session)
        XCTAssertEqual(reader.notePages.map(\.title), ["Interface", "Mutations"])
        reader.selectPage(firstID)
        XCTAssertEqual(reader.text, "Interface observation")
    }

    @MainActor
    func testHTMLAndPDFExportsHaveExpectedDocumentStructure() {
        let store = AnalysisNotesStore(debounceInterval: 60)
        store.text = "# Interface\nA concise structural observation."

        let html = store.exportHTML()
        let pdf = store.exportPDFData()
        XCTAssertTrue(html.contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<h1>Interface</h1>"))
        XCTAssertTrue(String(data: pdf.prefix(4), encoding: .ascii)?.hasPrefix("%PDF") == true)
        XCTAssertGreaterThan(pdf.count, 500)
        if let path = ProcessInfo.processInfo.environment["RAYMOL_NOTES_PDF_QA"] {
            try? pdf.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
