import XCTest
@testable import RayMol

final class AnalysisNotesStoreTests: XCTestCase {
    @MainActor
    func testSavedSessionWritesAndReloadsPortableSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalysisNotesStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = root.appendingPathComponent("experiment.pse")
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        let writer = AnalysisNotesStore(fallbackDirectory: fallback, debounceInterval: 60)
        writer.text = "Chain A moves toward the ligand after minimization."
        writer.sessionDidSave(to: session)

        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.sidecarURL(for: session).path))

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
}
