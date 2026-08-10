import XCTest
@testable import RayMol

/// Coverage for PyMOLEngine.invokeKeyBinding — the synchronous bridge into
/// pymol.internal._invoke_key that carries cmd.set_key dispatch (#258).
///
/// These run against the LIVE engine, so they bind and unbind real keys. F-keys
/// are used throughout because F1–F12 are unbound in PyMOL's 125 defaults,
/// which makes them both safe to claim and usable as negative controls.
@MainActor
final class KeyBindingDispatchTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    override func tearDown() {
        // Release anything a case bound, so the shared singleton stays clean.
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "import pymol as _pm\n"
            + "for _k in ('F7', 'F8', 'F9'):\n"
            + "    _c.key_mappings.pop(_k, None)\n"
            + "if hasattr(_pm, '_t258'): del _pm._t258\n"
            + "_c.set('sphere_scale', 1.0)")
        super.tearDown()
    }

    /// The return value is what tells the monitor whether to consume the event,
    /// so an UNBOUND key must report false — that is the whole mechanism by
    /// which ⌃D still reaches the Design menu item.
    func testUnboundKeyReportsFalse() {
        engine.runPython("from pymol import cmd as _c; _c.key_mappings.pop('F9', None)")
        XCTAssertFalse(engine.invokeKeyBinding("F9"))
    }

    func testBoundPythonCallableFiresAndReportsTrue() {
        engine.runPython(
            "from pymol import cmd as _c\n"
            + "import pymol\n"
            + "pymol._t258 = 0\n"
            + "def _hit():\n"
            + "    import pymol as _p; _p._t258 += 1\n"
            + "_c.set_key('F7', _hit)")
        XCTAssertTrue(engine.invokeKeyBinding("F7"))
        XCTAssertEqual(pythonInt("pymol._t258"), 1)
        XCTAssertTrue(engine.invokeKeyBinding("F7"))
        XCTAssertEqual(pythonInt("pymol._t258"), 2)
    }

    /// set_key also accepts a PyMOL command STRING (since PyMOL 1.6.1), which
    /// _invoke_key routes through cmd.do. Gabriel's script uses callables, but
    /// the 125 built-in defaults are all strings, so this path carries parity.
    func testBoundCommandStringFires() {
        engine.runPython("from pymol import cmd as _c; _c.set_key('F8', 'set sphere_scale, 0.37')")
        XCTAssertTrue(engine.invokeKeyBinding("F8"))
        XCTAssertEqual(pythonFloat("cmd.get_setting_float('sphere_scale')"), 0.37, accuracy: 0.001)
        // sphere_scale is restored to 1.0 in tearDown — do not reset mid-test
        // so an early failure or timeout doesn't leave a non-default value to
        // leak into sibling tests sharing the PyMOLEngine.shared singleton.
    }

    func testUnknownTokenIsHarmless() {
        XCTAssertFalse(engine.invokeKeyBinding("NOT-A-KEY"))
        XCTAssertFalse(engine.invokeKeyBinding(""))
    }

    // Read a value back out of the live interpreter via the engine's own
    // completion channel is not possible, so stash into a file-free global and
    // read it with a tiny eval helper built on runPython + feedback.
    private func pythonInt(_ expr: String) -> Int {
        Int(pythonRepr(expr)) ?? -1
    }
    private func pythonFloat(_ expr: String) -> Double {
        Double(pythonRepr(expr)) ?? .nan
    }
    private func pythonRepr(_ expr: String) -> String {
        let path = NSTemporaryDirectory() + "/t258_probe.txt"
        engine.runPython(
            "from pymol import cmd\n"
            + "import pymol\n"
            + "open(r'\(path)', 'w').write(str(\(expr)))")
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
