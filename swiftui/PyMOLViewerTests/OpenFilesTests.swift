import XCTest
@testable import RayMol

// Regression tests for issue #222: `open a.pdb b.pdb c.pdb` from a Terminal (and
// Finder "Open With" multi-select / Dock-icon drop) only loaded the first file.
// macOS delivers all of them via NSApplicationDelegate.application(_:open:) as one
// [URL] array; RayMolAppDelegate forwards that array through handleOpenedURLs.
// These lock in that EVERY url is forwarded — a spy stands in for the real
// loadOpenedFile so the engine/PyMOL core never has to boot.
@MainActor
final class OpenFilesTests: XCTestCase {

    func testAllOpenedURLsAreForwardedInOrder() {
        let urls = ["a.pdb", "b.pdb", "c.pdb"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        var seen: [String] = []
        handleOpenedURLs(urls, into: PyMOLEngine.shared) { url, _ in
            seen.append(url.lastPathComponent)
        }
        // The bug loaded only "a.pdb"; the fix must forward all three, in order.
        XCTAssertEqual(seen, ["a.pdb", "b.pdb", "c.pdb"])
    }

    func testSingleOpenedURLStillForwarded() {
        // A plain Finder double-click delivers a one-element array; it must still
        // load (the delegate now handles single- and multi-file opens uniformly).
        let urls = [URL(fileURLWithPath: "/tmp/only.pse")]
        var seen: [String] = []
        handleOpenedURLs(urls, into: PyMOLEngine.shared) { url, _ in
            seen.append(url.lastPathComponent)
        }
        XCTAssertEqual(seen, ["only.pse"])
    }

    func testEmptyURLListIsNoOp() {
        var called = false
        handleOpenedURLs([], into: PyMOLEngine.shared) { _, _ in called = true }
        XCTAssertFalse(called)
    }
}
