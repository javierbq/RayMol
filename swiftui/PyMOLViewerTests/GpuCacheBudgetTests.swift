import XCTest
import CoreGraphics
import ImageIO
@testable import RayMol

/// The Metal renderer's GPU upload cache is bounded (metal_gpu_cache_mb).
///
/// Every rep's CPU vertex buffer gets a Metal copy, and ray tracing extracts
/// its own geometry from the same buffer; both used to live as long as the
/// rep. A multi-state object keeps a rep per state, so playing a 300-state
/// morph on an iPhone kept a copy of every state it had shown (about 13 MB
/// each) until the system ended the app. Past the budget, copies no draw has
/// used for two frames are freed and made again on their next draw -- the
/// renderer's (Metal buffers, ray-tracing geometry) and the cartoons' own
/// shader-ready CGOs alike.
final class GpuCacheBudgetTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?
    private let states = 40

    override func tearDown() {
        if sceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "_c.delete('gcb906')\n"
                + "_c.set('metal_gpu_cache_mb', globals().pop('_gcb_budget', 0))\n"
                + "_c.set('state', globals().pop('_gcb_state', 1))\n"
                + "for _n in globals().pop('_gcb_enabled', []):\n"
                + "    _c.enable(_n)\n")
            sceneBuilt = false
        }
        if let savedView {
            engine.restoreView(savedView, animate: 0)
            self.savedView = nil
        }
        super.tearDown()
    }

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            throw XCTSkip("the PyMOL engine did not come up under the test host")
        }
    }

    /// A 40-residue helix as a cartoon, in `states` states (each its own
    /// coordinate set, so each state builds its own rep and buffers), alone
    /// on screen.
    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _gcb_enabled = _c.get_names('objects', enabled_only=1)
        _gcb_budget = _c.get_setting_int('metal_gpu_cache_mb')
        _gcb_state = _c.get_setting_int('state')
        for _n in _gcb_enabled:
            _c.disable(_n)
        _c.fab('ACDEFGHIKLMNPQRSTVWY' * 2, 'gcb906', ss=1)
        for _s in range(2, \(states) + 1):
            _c.create('gcb906', 'gcb906', 1, _s)
            _c.translate([0.05 * _s, 0.0, 0.0], 'gcb906', state=_s, camera=0)
        _c.hide('everything', 'gcb906')
        _c.show('cartoon', 'gcb906')
        _c.orient('gcb906')
        """)
    }

    private struct Stats {
        var entries = 0, bufferBytes = 0, rtBytes = 0, budgetBytes = 0
        var evictedEntries = 0, evictedBytes = 0
        // Cartoons' shader-ready CGOs (RepCartoonTrimShaderCGOs).
        var cartoonCGOs = 0, cartoonBytes = 0, cartoonReleased = 0
        var held: Int { bufferBytes + rtBytes }
    }

    private func stats(trim: Bool = false) throws -> Stats {
        let out = NSTemporaryDirectory() + "gcb906_stats.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        _d = _c._cmd.get_metal_gpu_cache_stats(_c._COb, \(trim ? 1 : 0))
        open(r'\(out)', 'w').write('' if _d is None else ' '.join(str(_d[k]) for k in (
            'entries', 'buffer_bytes', 'rt_bytes', 'budget_bytes',
            'evicted_entries', 'evicted_bytes', 'cartoon_cgos',
            'cartoon_cgo_bytes', 'cartoon_cgos_released')))
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no readout written")
        let v = text.split(separator: " ").compactMap { Int($0) }
        guard v.count == 9 else { throw XCTSkip("no Metal renderer under the test host") }
        return Stats(entries: v[0], bufferBytes: v[1], rtBytes: v[2], budgetBytes: v[3],
                     evictedEntries: v[4], evictedBytes: v[5], cartoonCGOs: v[6],
                     cartoonBytes: v[7], cartoonReleased: v[8])
    }

    private func setBudget(_ mb: Int) {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_gpu_cache_mb', \(mb))")
    }

    /// Renders `state` offscreen (a full scene frame through beginFrame) and
    /// returns its RGBA pixels.
    @discardableResult
    private func render(state: Int) throws -> [UInt8] {
        engine.runPython("from pymol import cmd as _c\n_c.set('state', \(state))")
        let png = NSTemporaryDirectory() + "gcb906_\(state).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 160, height: 120, rayTraced: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return rgba
    }

    func testStatesNotShownAreFreedPastTheBudget() throws {
        try requireEngine()
        buildScene()

        // No limit: every state shown keeps its copies (the old behaviour).
        setBudget(-1)
        for s in 1...states { try render(state: s) }
        let unlimited = try stats()
        XCTAssertEqual(unlimited.budgetBytes, 0)
        XCTAssertGreaterThanOrEqual(unlimited.entries, states,
                                    "each state shown should have its own upload")
        print("gcb906 unlimited: \(unlimited.entries) entries, "
              + "\(unlimited.bufferBytes) buffer + \(unlimited.rtBytes) RT bytes, "
              + "\(unlimited.cartoonCGOs) cartoon CGOs of \(unlimited.cartoonBytes) bytes "
              + "for \(states) states")
        XCTAssertGreaterThanOrEqual(unlimited.cartoonCGOs, states,
                                    "each state shown should keep its cartoon's shader CGO")

        // A 1 MB budget: the next frame frees what it does not draw.
        setBudget(1)
        try render(state: 1)
        let capped = try stats(trim: true)
        XCTAssertEqual(capped.budgetBytes, 1 << 20)
        // Freed either way: a released cartoon frees its buffers (and the
        // renderer's copies of them) itself; the renderer evicts the rest.
        XCTAssertGreaterThan(
            capped.evictedEntries + capped.cartoonReleased,
            unlimited.evictedEntries + unlimited.cartoonReleased,
            "nothing was freed past the budget")
        XCTAssertLessThan(capped.held, unlimited.held / 4,
                          "the cache still holds \(capped.held) of \(unlimited.held) bytes")
        XCTAssertGreaterThan(capped.cartoonReleased, unlimited.cartoonReleased,
                             "no cartoon released its shader CGO past the budget")
        XCTAssertLessThan(capped.cartoonBytes, unlimited.cartoonBytes / 4,
                          "cartoons still hold \(capped.cartoonBytes) of \(unlimited.cartoonBytes) bytes")

        // Showing the states again stays bounded (one state's copies at a
        // time plus the budget), instead of growing with each state.
        for s in 1...states { try render(state: s) }
        let replayed = try stats(trim: true)
        print("gcb906 capped: \(replayed.held) bytes held after a replay, "
              + "\(replayed.evictedEntries) entries freed in all, cartoons hold "
              + "\(replayed.cartoonBytes) bytes, \(replayed.cartoonReleased) released in all")
        XCTAssertLessThan(replayed.held, unlimited.held / 4)
        XCTAssertLessThan(replayed.cartoonBytes, unlimited.cartoonBytes / 4)
        XCTAssertGreaterThan(replayed.evictedEntries + replayed.cartoonReleased,
                             capped.evictedEntries + capped.cartoonReleased)
    }

    func testAStateDrawsTheSameAfterItsCopiesWereFreed() throws {
        try requireEngine()
        buildScene()
        setBudget(-1)
        try render(state: 1)
        let before = try render(state: 7)   // drawn twice: RT geometry settled

        setBudget(1)
        for s in 1...states where s != 7 { try render(state: s) }
        let freed = try stats(trim: true)
        XCTAssertGreaterThan(freed.cartoonReleased, 0,
                             "state 7's cartoon was not released, so nothing is re-made")

        try render(state: 7)                // uploaded and extracted again
        let after = try render(state: 7)
        XCTAssertEqual(before, after, "a state renders differently once re-uploaded")
    }
}
