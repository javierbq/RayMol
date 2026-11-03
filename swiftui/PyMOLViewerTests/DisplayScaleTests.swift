import XCTest
@testable import RayMol

/// Retina label size: the viewport hands the screen's backing scale to the core
/// as display_scale_factor (PyMOLEngine.syncDisplayScale, called from the render
/// tick). label_size is in points and the core multiplies it by that factor, so
/// with the factor stuck at 1 a Retina display drew every label at half size.
///
/// Live tests against PyMOLEngine.shared: they fail (never skip) when the engine
/// is not ready, and each one restores the host window's own scale.
@MainActor
final class DisplayScaleTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    private static let probePath = NSTemporaryDirectory() + "/display_scale_probe.txt"

    private struct EngineNotReady: Error, CustomStringConvertible {
        var description: String { "PyMOLEngine.shared never became ready" }
    }

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready after 20 s: the display scale test ran nothing")
            throw EngineNotReady()
        }
    }

    /// The viewport's window, whose backing scale the render tick applies.
    private var viewportWindow: NSWindow? {
        NSApp.windows.first { window in
            func hasViewport(_ v: NSView) -> Bool {
                v is PyMOLMTKView || v.subviews.contains(where: hasViewport)
            }
            return window.contentView.map(hasViewport) ?? false
        }
    }

    override func tearDown() {
        if let scale = viewportWindow?.backingScaleFactor {
            engine.syncDisplayScale(scale)
        }
        try? FileManager.default.removeItem(atPath: Self.probePath)
        super.tearDown()
    }

    /// The core's display_scale_factor, read through cmd.get_setting_int.
    private func coreScale() -> Int? {
        let path = Self.probePath
        try? FileManager.default.removeItem(atPath: path)
        engine.runPython(
            "from pymol import cmd as _dst_cmd\n"
            + "with open(r'\(path)', 'w') as _dst_f:\n"
            + "    _dst_f.write(str(_dst_cmd.get_setting_int('display_scale_factor')))\n")
        return (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { Int($0) }
    }

    func testSyncDisplayScaleSetsCoreFactor() throws {
        try requireEngine()
        engine.syncDisplayScale(2)
        XCTAssertEqual(coreScale(), 2)
        engine.syncDisplayScale(1)
        XCTAssertEqual(coreScale(), 1)
        engine.syncDisplayScale(3)
        XCTAssertEqual(coreScale(), 3)
    }

    func testSyncDisplayScaleIgnoresZero() throws {
        try requireEngine()
        engine.syncDisplayScale(2)
        engine.syncDisplayScale(0)
        XCTAssertEqual(coreScale(), 2, "a zero scale (no screen yet) must not reach the core")
    }

    /// End to end: the render tick applies the viewport window's backing scale,
    /// even after something else changed the core's factor.
    func testRenderTickAppliesWindowBackingScale() throws {
        try requireEngine()
        guard let window = viewportWindow else {
            XCTFail("no window hosts the Metal viewport")
            return
        }
        let expected = Int(window.backingScaleFactor.rounded())
        // Push the engine's remembered value off the window's, so the tick has
        // to re-apply it.
        engine.syncDisplayScale(CGFloat(expected == 1 ? 2 : 1))
        let deadline = Date().addingTimeInterval(5)
        while coreScale() != expected && Date() < deadline {
            engine.requestViewportRedraw()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(coreScale(), expected)
    }
}
