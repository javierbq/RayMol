import XCTest
@testable import RayMol

/// The tempfile channels are shared-$TMPDIR IPC, so the property that keeps two
/// RayMol processes apart is that every name carries this process's pid (#399).
/// These tests pin that, and pin the `Stem.all` list `removeAll()` walks — a
/// channel missing from it leaks a file per run.
final class TempChannelTests: XCTestCase {

    func testPathCarriesThisProcessID() {
        let path = TempChannel.path(TempChannel.Stem.sequence)
        XCTAssertEqual(
            (path as NSString).lastPathComponent,
            "pymol_seq_\(ProcessInfo.processInfo.processIdentifier).json",
            "a pid-less name lets a second RayMol hand this one its sequence rows")
    }

    func testPathLivesInTemporaryDirectory() {
        // Same $TMPDIR Python's tempfile.gettempdir() resolves to, which is what
        // makes this an IPC channel rather than two unrelated files.
        XCTAssertTrue(TempChannel.path(TempChannel.Stem.gizmo)
                        .hasPrefix(NSTemporaryDirectory()))
    }

    func testExtensionIsOverridable() {
        let path = TempChannel.path(TempChannel.Stem.rayOverlay, ext: "png")
        XCTAssertEqual(
            (path as NSString).lastPathComponent,
            "_pymol_ray_overlay_\(ProcessInfo.processInfo.processIdentifier).png")
    }

    func testEveryStemIsListedForCleanup() {
        let listed = Set(TempChannel.Stem.all.map { $0.stem })
        let declared: Set<String> = [
            TempChannel.Stem.sequence, TempChannel.Stem.sequenceSelection,
            TempChannel.Stem.gizmo, TempChannel.Stem.hoverInfo,
            TempChannel.Stem.settings, TempChannel.Stem.rayOverlay,
            TempChannel.Stem.objectPanel, TempChannel.Stem.objectDetail,
            TempChannel.Stem.predictForm, TempChannel.Stem.designForm,
        ]
        XCTAssertEqual(listed, declared,
                       "a channel absent from Stem.all is never cleaned up on quit")
        XCTAssertEqual(TempChannel.Stem.all.count, declared.count,
                       "Stem.all must not list a channel twice")
    }

    func testRemoveAllDeletesThisProcessesChannels() throws {
        for channel in TempChannel.Stem.all {
            let path = TempChannel.path(channel.stem, ext: channel.ext)
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        }
        TempChannel.removeAll()
        for channel in TempChannel.Stem.all {
            let path = TempChannel.path(channel.stem, ext: channel.ext)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                           "\(channel.stem) survived removeAll()")
        }
    }

    /// removeAll() runs on quit, when a channel may never have fired — a missing
    /// file must not be treated as an error.
    func testRemoveAllToleratesMissingFiles() {
        TempChannel.removeAll()
        TempChannel.removeAll()
    }
}
