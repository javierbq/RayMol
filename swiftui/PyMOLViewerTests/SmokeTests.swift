import XCTest
@testable import RayMol   // module name = PRODUCT_NAME "RayMol"; try `import PyMOLViewer` if this fails

final class SmokeTests: XCTestCase {
    func testHarnessRuns() { XCTAssertEqual(1 + 1, 2) }
}

/// The Background swatch's opacity → `ray_opaque_background` mapping (#378).
/// PyMOL's `bg_rgb` has no alpha, so the picker's opacity slider used to be a
/// dead control; it now drives the same binary export switch as the Share menu.
final class BackgroundOpacityTests: XCTestCase {
    func testFullyOpaqueAndTransparentEndpoints() {
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 1))
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: 0))
    }

    // The underlying setting is binary, so the threshold sits at the midpoint:
    // a nudge off 100% stays opaque, anything under half becomes transparent.
    func testThresholdIsHalf() {
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 0.5))
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: 0.95))
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: 0.49))
    }

    // What the swatch shows must round-trip through the policy.
    func testSwatchAlphaRoundTrips() {
        XCTAssertTrue(BackgroundOpacity.isTransparent(alpha: BackgroundOpacity.alpha(transparent: true)))
        XCTAssertFalse(BackgroundOpacity.isTransparent(alpha: BackgroundOpacity.alpha(transparent: false)))
    }

    func testCommandTogglesRayOpaqueBackground() {
        XCTAssertEqual(BackgroundOpacity.command(transparent: true), "set ray_opaque_background, 0")
        XCTAssertEqual(BackgroundOpacity.command(transparent: false), "set ray_opaque_background, 1")
    }

    // Both affordances must persist under the one key ContentView already uses.
    func testSharesTheExportMenuDefaultsKey() {
        XCTAssertEqual(BackgroundOpacity.defaultsKey, "exportTransparent")
    }
}

/// Metal export: background clear colour when shadows and ray tracing are off (issue #628).
@MainActor
final class ExportBackgroundTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var settingsSaved = false

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready")
            throw NSError(domain: "PyMOLEngine", code: 1)
        }
        // The engine is shared by every live test: save what these tests
        // change so tearDown can put it back.
        engine.runPython(
            "from pymol import cmd as _ebg_c\n"
            + "_ebg_saved = {_k: _ebg_c.get(_k) for _k in ('bg_rgb',\n"
            + "    'ray_opaque_background', 'metal_shadows')}\n")
        settingsSaved = true
    }

    override func tearDown() {
        if settingsSaved {
            engine.runPython(
                "from pymol import cmd as _ebg_c\n"
                + "for _k, _v in globals().pop('_ebg_saved', {}).items():\n"
                + "    _ebg_c.set(_k, _v)\n")
            settingsSaved = false
        }
        super.tearDown()
    }

    private func pngPixels(_ path: String) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (w, h, rgba) : nil
    }

    func testExportBackgroundWhenShadowsAndRaytraceOff() throws {
        try requireEngine()

        for (shadows, rt) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            engine.runPython("""
            from pymol import cmd
            cmd.set('bg_rgb', [0.2, 0.4, 0.6])
            cmd.set('ray_opaque_background', 1)
            cmd.set('metal_shadows', \(shadows))
            """)

            let png = NSTemporaryDirectory() + "issue_628_test_\(shadows)_\(rt).png"
            defer { try? FileManager.default.removeItem(atPath: png) }

            engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)

            guard let (_, _, rgba) = pngPixels(png) else {
                XCTFail("Failed to render or load PNG for shadows=\(shadows), rt=\(rt)")
                continue
            }

            // Top-left corner pixel (0, 0)
            let r = Int(rgba[0])
            let g = Int(rgba[1])
            let b = Int(rgba[2])
            let a = Int(rgba[3])

            // bg_rgb [0.2, 0.4, 0.6] -> [51, 102, 153], opaque alpha -> 255
            XCTAssertEqual(r, 51, accuracy: 2, "Red channel (shadows=\(shadows), rt=\(rt))")
            XCTAssertEqual(g, 102, accuracy: 2, "Green channel (shadows=\(shadows), rt=\(rt))")
            XCTAssertEqual(b, 153, accuracy: 2, "Blue channel (shadows=\(shadows), rt=\(rt))")
            XCTAssertEqual(a, 255, "Alpha channel (shadows=\(shadows), rt=\(rt))")
        }
    }

    func testExportBackgroundConsecutiveColorChange() throws {
        try requireEngine()

        engine.runPython("""
        from pymol import cmd
        cmd.set('ray_opaque_background', 1)
        cmd.set('metal_shadows', 0)
        """)

        // First export: red background [0.8, 0.1, 0.1] -> [204, 25, 25]
        engine.runPython("cmd.set('bg_rgb', [0.8, 0.1, 0.1])")
        let png1 = NSTemporaryDirectory() + "issue_628_consec_1.png"
        defer { try? FileManager.default.removeItem(atPath: png1) }
        engine.renderHiResPNG(png1, width: 400, height: 300, rayTraced: 0)
        guard let (_, _, rgba1) = pngPixels(png1) else {
            XCTFail("Failed to render PNG 1")
            return
        }
        XCTAssertEqual(Int(rgba1[0]), 204, accuracy: 2, "PNG 1 Red channel")
        XCTAssertEqual(Int(rgba1[1]), 25, accuracy: 2, "PNG 1 Green channel")
        XCTAssertEqual(Int(rgba1[2]), 25, accuracy: 2, "PNG 1 Blue channel")

        // Second export immediately: green background [0.1, 0.8, 0.1] -> [25, 204, 25]
        engine.runPython("cmd.set('bg_rgb', [0.1, 0.8, 0.1])")
        let png2 = NSTemporaryDirectory() + "issue_628_consec_2.png"
        defer { try? FileManager.default.removeItem(atPath: png2) }
        engine.renderHiResPNG(png2, width: 400, height: 300, rayTraced: 0)
        guard let (_, _, rgba2) = pngPixels(png2) else {
            XCTFail("Failed to render PNG 2")
            return
        }
        XCTAssertEqual(Int(rgba2[0]), 25, accuracy: 2, "PNG 2 Red channel")
        XCTAssertEqual(Int(rgba2[1]), 204, accuracy: 2, "PNG 2 Green channel")
        XCTAssertEqual(Int(rgba2[2]), 25, accuracy: 2, "PNG 2 Blue channel")
    }

    func testExportBackgroundTransparent() throws {
        try requireEngine()

        engine.runPython("""
        from pymol import cmd
        cmd.set('bg_rgb', [0.2, 0.4, 0.6])
        cmd.set('ray_opaque_background', 0)
        cmd.set('metal_shadows', 0)
        """)

        let png = NSTemporaryDirectory() + "issue_628_transparent.png"
        defer { try? FileManager.default.removeItem(atPath: png) }

        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)

        guard let (_, _, rgba) = pngPixels(png) else {
            XCTFail("Failed to render PNG")
            return
        }

        // Alpha channel must be 0 for transparent background
        XCTAssertEqual(rgba[3], 0, "Alpha channel must be transparent")
    }
}

/// Scripted movie_export at launch when renderer is not yet ready (#654).
@MainActor
final class ScriptedMovieExportTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }

    private func makeRequestJSON(path: String, frames: Int = 10, first: Int = 1, last: Int = 2) -> String {
        """
        {
            "path": "\(path)",
            "frames": \(frames),
            "width": 320,
            "height": 240,
            "format": "png",
            "codec": "",
            "quality": "standard",
            "overrides": {},
            "supersample": 1,
            "fps": 30,
            "ray": 0,
            "bitrate": 0.0,
            "first": \(first),
            "last": \(last)
        }
        """
    }

    func testRendererNeverReadyTimesOut() {
        let savedReady = engine.metalRendererReady
        let savedWait = engine.scriptedExportRendererWait
        defer {
            engine.metalRendererReady = savedReady
            engine.scriptedExportRendererWait = savedWait
        }

        engine.metalRendererReady = { false }
        engine.scriptedExportRendererWait = 0.3
        engine.feedbackLog.removeAll()

        let exportPath = NSTemporaryDirectory() + "test_scripted_export_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: exportPath) }

        let json = makeRequestJSON(path: exportPath, frames: 10, first: 1, last: 2)
        engine.startScriptedMovieExport(json)

        XCTAssertTrue(engine.feedbackLog.contains(where: {
            $0.contains("movie_export: waiting for the renderer (no live frame yet)")
        }), "Expected waiting line at once, got: \(engine.feedbackLog)")

        let exp = expectation(description: "Wait for renderer timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(engine.feedbackLog.contains(where: {
            $0.contains("movie_export: failed: the renderer is not ready (no live frame was drawn; is the window visible?)")
        }), "Expected failure line, got: \(engine.feedbackLog)")

        XCTAssertFalse(engine.scriptedMovieExporter.isExporting)
    }

    func testInvalidRequestFailsImmediatelyWithoutWaiting() {
        let savedReady = engine.metalRendererReady
        let savedWait = engine.scriptedExportRendererWait
        defer {
            engine.metalRendererReady = savedReady
            engine.scriptedExportRendererWait = savedWait
        }

        engine.metalRendererReady = { false }
        engine.scriptedExportRendererWait = 0.3
        engine.feedbackLog.removeAll()

        let exportPath = NSTemporaryDirectory() + "test_scripted_export_\(UUID().uuidString)"
        let json = makeRequestJSON(path: exportPath, frames: 1, first: 1, last: 1)
        engine.startScriptedMovieExport(json)

        XCTAssertTrue(engine.feedbackLog.contains(where: {
            $0.contains("movie_export: there is no movie to export (build one in the Movie tab)")
        }), "Expected 'there is no movie to export' line, got: \(engine.feedbackLog)")

        XCTAssertFalse(engine.feedbackLog.contains(where: {
            $0.contains("waiting for the renderer")
        }), "Expected no waiting line, got: \(engine.feedbackLog)")
    }

    // The recovery path (Copilot review of #766): readiness flips to true
    // after a few polls and exactly one start runs.
    func testWaiterStartsExactlyOnceWhenTheRendererBecomesReady() {
        var polls = 0, started = 0, busy = 0, timedOut = 0
        let done = expectation(description: "start")
        PyMOLEngine.pollUntilReady(
            ready: { polls += 1; return polls >= 3 }, busy: { false },
            deadline: .now() + 5, interval: 0.01,
            onReady: { started += 1; done.fulfill() }, onBusy: { busy += 1 },
            onTimeout: { timedOut += 1 })
        wait(for: [done], timeout: 2)
        let settle = expectation(description: "no more polls")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(polls, 3, "polling stops once ready")
        XCTAssertEqual(busy, 0)
        XCTAssertEqual(timedOut, 0)
    }

    func testWaiterReportsBusyInsteadOfStartingASecondExport() {
        var started = 0
        let done = expectation(description: "busy")
        PyMOLEngine.pollUntilReady(
            ready: { true }, busy: { true }, deadline: .now() + 5, interval: 0.01,
            onReady: { started += 1 }, onBusy: { done.fulfill() }, onTimeout: { XCTFail("timeout") })
        wait(for: [done], timeout: 2)
        XCTAssertEqual(started, 0)
    }

    func testWaiterTimesOutOnceAtTheDeadline() {
        var timedOut = 0
        let done = expectation(description: "timeout")
        PyMOLEngine.pollUntilReady(
            ready: { false }, busy: { false }, deadline: .now() + 0.05, interval: 0.01,
            onReady: { XCTFail("started") }, onBusy: { XCTFail("busy") },
            onTimeout: { timedOut += 1; done.fulfill() })
        wait(for: [done], timeout: 2)
        let settle = expectation(description: "no more polls")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 1)
        XCTAssertEqual(timedOut, 1)
    }

    // A poll that runs after the deadline times out even if the renderer is
    // ready by then (Copilot review of #766): the wait stays bounded.
    func testWaiterTimesOutPastTheDeadlineEvenIfReady() {
        let done = expectation(description: "timeout")
        PyMOLEngine.pollUntilReady(
            ready: { true }, busy: { false }, deadline: .now(), interval: 0.01,
            onReady: { XCTFail("started past the deadline") }, onBusy: { XCTFail("busy") },
            onTimeout: { done.fulfill() })
        wait(for: [done], timeout: 2)
    }
}


/// Metal export: a label is drawn in its own colour (issue #736). Labels draw
/// in the transparent pass, which on Metal is the OIT pass; drawing them there
/// with the scene-pass pipeline (BGRA8, MSAA) wrote undefined values into the
/// OIT targets, so every label came out magenta, or not at all.
@MainActor
final class LabelColorExportTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "_c.delete('lc736a or lc736b or lc736p')\n"
                + "_c.set('bg_rgb', globals().pop('_lc736_bg', [0.0, 0.0, 0.0]))\n"
                + "for _n in globals().pop('_lc736_enabled', []):\n"
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

    private func pngPixels(_ path: String) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? rgba : nil
    }

    /// Pixels of an export (rt 0 and 1) close to `rgb`, and the ones that are
    /// magenta, the colour every label used to come out in.
    private func countLabelPixels(_ rgb: (Int, Int, Int), rt: Int)
        -> (match: Int, magenta: Int) {
        let png = NSTemporaryDirectory() + "issue_736_label_\(rgb.2)_rt\(rt).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)
        guard let px = pngPixels(png) else {
            XCTFail("no export written (rt=\(rt))")
            return (0, 0)
        }
        var match = 0, magenta = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if abs(r - rgb.0) <= 12 && abs(g - rgb.1) <= 12 && abs(b - rgb.2) <= 12 { match += 1 }
            if r > 200 && g < 60 && b > 200 { magenta += 1 }
        }
        return (match, magenta)
    }

    /// A label inside a peeled transparent object (transparency_peel): its own
    /// pass tests against the object's front shell, so the label is drawn in
    /// the ordinary OIT pass instead, behind that shell like any other label.
    func testLabelInsideAPeeledObjectIsDrawn() throws {
        try requireEngine()
        savedView = engine.captureView()
        sceneBuilt = true
        let state = NSTemporaryDirectory() + "issue_736_peel.json"
        defer { try? FileManager.default.removeItem(atPath: state) }
        engine.runPython("""
        from pymol import cmd as _c
        _lc736_enabled = _c.get_names('objects', enabled_only=1)
        _lc736_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        for _n in _lc736_enabled:
            _c.disable(_n)
        _c.pseudoatom('lc736p', pos=[0.0, 0.0, 0.0], label='PEEL')
        _c.show_as('spheres', 'lc736p')
        _c.show('labels', 'lc736p')
        _c.color('white', 'lc736p')
        _c.set('sphere_scale', 5.0, 'lc736p')
        _c.set('sphere_transparency', 0.5, 'lc736p')
        _c.set('transparency_peel', 1, 'lc736p')
        _c.set('label_color', 'red', 'lc736p')
        _c.set('label_size', 40, 'lc736p')
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -40.0, 0.0, 0.0, 0.0, 30.0, 50.0, -20.0))
        import json as _json
        _lc736_peel = _c._cmd.get_frame_peel(_c._COb)
        open(r'\(state)', 'w').write(_json.dumps(
            {'can': bool(_lc736_peel[0]), 'names': list(_lc736_peel[1])}))
        """)
        let peel = try XCTUnwrap(FileManager.default.contents(atPath: state)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(peel["names"] as? [String], ["lc736p"], "the object is not peeled")
        if peel["can"] as? Bool != true {
            throw XCTSkip("this renderer cannot peel")
        }

        for rt in [0, 1] {
            let png = NSTemporaryDirectory() + "issue_736_peel_rt\(rt).png"
            defer { try? FileManager.default.removeItem(atPath: png) }
            engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)
            let px = try XCTUnwrap(pngPixels(png), "no export written (rt=\(rt))")
            // The red glyphs, seen through the half-transparent white shell.
            var red = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if r - g > 60 && r - b > 60 { red += 1 }
            }
            XCTAssertGreaterThan(red, 300, "red label pixels inside the peeled sphere (rt=\(rt))")
        }
    }

    func testPseudoatomLabelsExportInTheirColour() throws {
        try requireEngine()
        savedView = engine.captureView()
        sceneBuilt = true
        // Two pseudoatom labels alone in the scene: one black via label_color
        // and the atom colour (issue #736's EXPOSURE label), one navy via
        // label_color only (its unlit labels were not drawn at all).
        engine.runPython("""
        from pymol import cmd as _c
        _lc736_enabled = _c.get_names('objects', enabled_only=1)
        _lc736_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        for _n in _lc736_enabled:
            _c.disable(_n)
        _c.pseudoatom('lc736a', pos=[0.0, 2.0, 0.0], label='EXPOSURE')
        _c.pseudoatom('lc736b', pos=[0.0, -2.0, 0.0], label='NAVY')
        _c.hide('nonbonded', 'lc736a or lc736b')
        _c.color('black', 'lc736a')
        _c.set('label_color', 'black', 'lc736a')
        _c.set_color('lc736_navy', [0.0, 0.0, 0.35])
        _c.set('label_color', 'lc736_navy', 'lc736b')
        _c.set('label_size', 40, 'lc736a')
        _c.set('label_size', 40, 'lc736b')
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -40.0, 0.0, 0.0, 0.0, 30.0, 50.0, -20.0))
        """)

        for rt in [0, 1] {
            engine.runPython("from pymol import cmd as _c\n_c.set('bg_rgb', [1.0, 1.0, 1.0])")
            let black = countLabelPixels((0, 0, 0), rt: rt)
            XCTAssertGreaterThan(black.match, 800, "black label pixels (rt=\(rt))")
            XCTAssertEqual(black.magenta, 0, "magenta label pixels on white (rt=\(rt))")

            engine.runPython("from pymol import cmd as _c\n_c.set('bg_rgb', [0.0, 0.0, 0.0])")
            let navy = countLabelPixels((0, 0, 89), rt: rt)
            XCTAssertGreaterThan(navy.match, 400, "navy label pixels (rt=\(rt))")
            XCTAssertEqual(navy.magenta, 0, "magenta label pixels on black (rt=\(rt))")
        }
    }
}

/// Issue #639: the Metal renderer ignored per-state matrices (matrix_mode >= 1)
/// because ObjectStatePushAndApplyMatrix never loaded the matrix into the
/// renderer's modelview. A red sphere is stored at local (5, 0, 0); its state
/// matrix turns it 90 degrees about z and lifts it by 10, to world (0, 5, 10).
@MainActor
final class StateMatrixRenderTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "_c.delete('sm639')\n"
                + "_c.set('bg_rgb', globals().pop('_sm639_bg', [0.0, 0.0, 0.0]))\n"
                + "for _n in globals().pop('_sm639_enabled', []):\n"
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _sm639_enabled = _c.get_names('objects', enabled_only=1)
        _sm639_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        for _n in _sm639_enabled:
            _c.disable(_n)
        _c.pseudoatom('sm639', pos=[5.0, 0.0, 0.0])
        _c.alter('sm639', 'vdw=1.0')
        _c.show_as('spheres', 'sm639')
        _c.color('red', 'sm639')
        _c.set('sphere_scale', 1.0, 'sm639')
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.transform_object('sm639', [0.0, -1.0, 0.0, 0.0,
                                      1.0, 0.0, 0.0, 0.0,
                                      0.0, 0.0, 1.0, 10.0,
                                      0.0, 0.0, 0.0, 1.0], homogenous=1)
        _c.alter_state(1, 'sm639', '(x, y, z) = (5.0, 0.0, 0.0)')
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -40.0, 0.0, 0.0, 0.0, 5.0, 100.0, -20.0))
        """)
    }

    /// Count and centroid (pixels, origin top-left) of the red pixels of an
    /// offscreen Metal export.
    private func redBlob(_ tag: String) throws -> (count: Int, x: Double, y: Double) {
        let w = 400, h = 300
        let png = NSTemporaryDirectory() + "issue_639_\(tag).png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: w, height: h, rayTraced: 0)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("no export written (\(tag))")
            return (0, 0, 0)
        }
        XCTAssertEqual(image.width, w)
        XCTAssertEqual(image.height, h)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        var count = 0, sx = 0.0, sy = 0.0
        for i in 0..<(w * h) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2])
            if r > 60 && r - g > 40 && r - b > 40 {
                count += 1
                sx += Double(i % w)
                sy += Double(i / w)
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (count, sx / Double(count), sy / Double(count))
    }

    func testStateMatrixMovesTheSphereOnlyUnderMatrixMode() throws {
        try requireEngine()
        buildScene()

        // Default (matrix_mode -1): the state matrix is not applied; the sphere
        // sits at local (5, 0, 0), right of the view centre.
        let plain = try redBlob("default")
        XCTAssertGreaterThan(plain.count, 500, "the sphere is not drawn")
        XCTAssertGreaterThan(plain.x, 260, "default render: sphere should be right of centre")
        XCTAssertEqual(plain.y, 150, accuracy: 25, "default render: sphere should be vertically centred")

        // matrix_mode 0 is the same as the default.
        engine.runPython("from pymol import cmd as _c\n_c.set('matrix_mode', 0, 'sm639')")
        let zero = try redBlob("mode0")
        XCTAssertEqual(zero.count, plain.count, accuracy: 20)
        XCTAssertEqual(zero.x, plain.x, accuracy: 2)
        XCTAssertEqual(zero.y, plain.y, accuracy: 2)

        // matrix_mode 1: the state matrix moves it to world (0, 5, 10): over
        // the view centre, in the upper half of the image.
        engine.runPython("from pymol import cmd as _c\n_c.set('matrix_mode', 1, 'sm639')")
        let moved = try redBlob("mode1")
        XCTAssertGreaterThan(moved.count, 300, "the moved sphere is not drawn")
        XCTAssertEqual(moved.x, 200, accuracy: 30, "matrix_mode 1: sphere should be over the centre")
        XCTAssertLessThan(moved.y, 110, "matrix_mode 1: sphere should be in the upper half")
    }
}

/// The classic 4096x4096 shadow map is allocated by the first classic shadow
/// pre-pass, not with the renderer's targets (#667).
final class ClassicShadowMapLazyTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython(
                "from pymol import cmd as _c\n"
                + "_c.delete('sm667f or sm667o')\n"
                + "_c.set('metal_shadows', globals().pop('_sm667_shadows', 1))\n"
                + "_c.set('bg_rgb', globals().pop('_sm667_bg', [0.0, 0.0, 0.0]))\n"
                + "for _n in globals().pop('_sm667_enabled', []):\n"
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

    /// A sphere floor with a smaller sphere in front of it, which the classic
    /// shadow map makes cast a shadow on the floor. Shadows start OFF, so a
    /// live-view frame drawn between two steps cannot make the map behind a
    /// test's back (metal_shadows defaults to on).
    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _sm667_enabled = _c.get_names('objects', enabled_only=1)
        _sm667_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _sm667_shadows = _c.get_setting_int('metal_shadows')
        _c.set('metal_shadows', 0)
        for _n in _sm667_enabled:
            _c.disable(_n)
        _c.pseudoatom('sm667f', pos=[0.0, 0.0, 0.0])
        _c.pseudoatom('sm667o', pos=[3.0, 3.0, 18.0])
        _c.show_as('spheres', 'sm667f or sm667o')
        _c.color('white', 'sm667f or sm667o')
        _c.set('sphere_scale', 12.0, 'sm667f')
        _c.set('sphere_scale', 2.5, 'sm667o')
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 40.0, 100.0, -20.0))
        """)
    }

    /// The classic shadow map's size in bytes (0 = not allocated); `release`
    /// drops it first.
    private func shadowMapBytes(release: Bool = false) throws -> Int {
        let out = NSTemporaryDirectory() + "issue_667_bytes.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        open(r'\(out)', 'w').write(str(_c._cmd.get_classic_shadow_map_bytes(_c._COb, \(release ? 1 : 0))))
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no readout written")
        return try XCTUnwrap(Int(text))
    }

    private func render(shadows: Bool) throws -> [UInt8] {
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', \(shadows ? 1 : 0))")
        let png = NSTemporaryDirectory() + "issue_667_\(shadows ? "on" : "off").png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        return rgba
    }

    func testMapIsAllocatedByTheFirstShadowedRenderOnly() throws {
        try requireEngine()
        buildScene()
        // Drop whatever an earlier test in this process left.
        XCTAssertEqual(try shadowMapBytes(release: true), 0)

        _ = try render(shadows: false)
        XCTAssertEqual(try shadowMapBytes(), 0,
                       "a render without shadows allocated the classic map")

        _ = try render(shadows: true)
        let bytes = try shadowMapBytes()
        #if os(macOS)
        XCTAssertEqual(bytes, 4096 * 4096 * 4, "the classic map after a shadowed render")
        #else
        XCTAssertEqual(bytes, 2048 * 2048 * 4, "the classic map after a shadowed render")
        #endif

        // Shadows off again: the map is kept (no re-allocation per toggle).
        _ = try render(shadows: false)
        XCTAssertEqual(try shadowMapBytes(), bytes)
    }

    func testShadowedRenderIsTheSameWithALazyOrAnExistingMap() throws {
        try requireEngine()
        buildScene()

        let plain = try render(shadows: false)
        _ = try shadowMapBytes(release: true)
        let lazy = try render(shadows: true)       // allocates the map
        XCTAssertGreaterThan(try shadowMapBytes(), 0)
        let kept = try render(shadows: true)       // the map exists already
        _ = try shadowMapBytes(release: true)
        let again = try render(shadows: true)      // allocates it anew

        var shadowed = 0
        for i in stride(from: 0, to: plain.count, by: 4) where
            plain[i] != lazy[i] || plain[i + 1] != lazy[i + 1] || plain[i + 2] != lazy[i + 2] {
            shadowed += 1
        }
        XCTAssertGreaterThan(shadowed, 100, "shadows changed no pixels")
        XCTAssertEqual(lazy, kept, "the first shadowed frame differs from a later one")
        XCTAssertEqual(lazy, again, "a re-allocated map renders differently")
        // For a before/after comparison against a build with the eager map.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in lazy { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        print("667-shadowed-hash \(String(hash, radix: 16))")
    }
}

/// MCP capture_viewport renders with the app's Metal Save Image path (#643):
/// `exporting._metal_png` -> `_cmd.metal_png` -> the hook the bridge registers
/// on the instance -> `PyMOLBridge_RenderHiResPNG`. Both the wrapper and the
/// tool itself must give the image `renderHiResPNG` gives, and the tool adds no
/// `Note:` although a rig is on: that note only follows a CPU-traced image.
@MainActor
final class McpCaptureMetalTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('mc643')
            _c.set('bg_rgb', globals().pop('_mc643_bg', [0.0, 0.0, 0.0]))
            _c.set('metal_raytrace', globals().pop('_mc643_rt', 0))
            _c.set_lights(globals().pop('_mc643_lights', None))
            for _n in globals().pop('_mc643_enabled', []):
                _c.enable(_n)
            """)
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
        // The hook says no until the Metal renderer exists (a cold launch
        // before the first live frame, #654): wait for it, as a scripted
        // export does, rather than fail on a host that is still starting.
        while !engine.metalRendererReady() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.metalRendererReady() else {
            throw XCTSkip("no Metal renderer under the test host")
        }
    }

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _mc643_enabled = _c.get_names('objects', enabled_only=1)
        _mc643_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _mc643_rt = _c.get_setting_int('metal_raytrace')
        _mc643_lights = _c.get_lights()
        for _n in _mc643_enabled:
            _c.disable(_n)
        _c.pseudoatom('mc643', pos=[0, 0, 0])
        _c.alter('mc643', 'vdw=2.0')
        _c.show_as('spheres', 'mc643')
        _c.color('red', 'mc643')
        _c.set('bg_rgb', [0, 0, 0])
        _c.set('metal_raytrace', 0)
        _c.set_lights({'enabled': True, 'lights': [{'name': 'key'}]})
        _c.set_view((1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -30, 0, 0, 0, 20, 40, -20))
        """)
    }

    private func pngPixels(_ path: String) -> (width: Int, height: Int, rgba: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return (w, h, rgba)
    }

    func testCaptureViewportMatchesRenderHiResPNG() throws {
        try requireEngine()
        buildScene()

        let a = NSTemporaryDirectory() + "issue_643_a.png"
        let b = NSTemporaryDirectory() + "issue_643_b.png"
        let c = NSTemporaryDirectory() + "issue_643_c.png"
        let r = NSTemporaryDirectory() + "issue_643_r.txt"
        let j = NSTemporaryDirectory() + "issue_643_j.json"

        defer {
            try? FileManager.default.removeItem(atPath: a)
            try? FileManager.default.removeItem(atPath: b)
            try? FileManager.default.removeItem(atPath: c)
            try? FileManager.default.removeItem(atPath: r)
            try? FileManager.default.removeItem(atPath: j)
        }

        // The Save Image render (WYSIWYG ray tracing, like the tool).
        engine.renderHiResPNG(a, width: 400, height: 300, rayTraced: -1)

        // The Python wrapper over the new core entry.
        engine.runPython("""
        from pymol import exporting as _exp
        _res = _exp._metal_png(r'\(b)', 400, 300)
        with open(r'\(r)', 'w') as _f:
            _f.write(repr(_res))
        """)

        // The MCP tool, with this (main) thread standing in as the drain thread
        // so run_on_main runs the body inline.
        engine.runPython("""
        import base64 as _b64
        import json as _json
        import threading as _thr
        import traceback as _tb

        try:
            import raymol_mcp.mainthread as _mt
            import raymol_mcp.tools as _tools
            _saved_ident = _mt._main_ident
            _mt._main_ident = _thr.get_ident()
            try:
                _res = _tools._capture_viewport({'width': 400, 'height': 300})
            finally:
                _mt._main_ident = _saved_ident

            if not _res.get('isError') and _res.get('content'):
                with open(r'\(c)', 'wb') as _f:
                    _f.write(_b64.b64decode(_res['content'][0]['data']))

            _payload = {
                'isError': _res.get('isError', False),
                'types': [item['type'] for item in _res.get('content', [])]
            }
            with open(r'\(j)', 'w') as _f:
                _json.dump(_payload, _f)
        except Exception:
            with open(r'\(j)', 'w') as _f:
                _json.dump({'error': _tb.format_exc()}, _f)
        """)

        let rText = try String(contentsOfFile: r, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(rText, "True")

        guard let jData = FileManager.default.contents(atPath: j),
              let jObj = try? JSONSerialization.jsonObject(with: jData) as? [String: Any] else {
            XCTFail("failed to read or parse json file j")
            return
        }
        if let err = jObj["error"] as? String {
            XCTFail("Python error in capture_viewport: \(err)")
            return
        }
        XCTAssertEqual(jObj["isError"] as? Bool, false)
        XCTAssertEqual(jObj["types"] as? [String], ["image"])

        // Same image from all three routes.
        let pxA = try XCTUnwrap(pngPixels(a), "no export written for a")
        let pxB = try XCTUnwrap(pngPixels(b), "no export written for b")
        let pxC = try XCTUnwrap(pngPixels(c), "no export written for c")

        XCTAssertEqual(pxA.width, 400)
        XCTAssertEqual(pxA.height, 300)
        XCTAssertEqual(pxB.width, 400)
        XCTAssertEqual(pxB.height, 300)
        XCTAssertEqual(pxC.width, 400)
        XCTAssertEqual(pxC.height, 300)

        let totalPixels = 400 * 300
        var redPixels = 0
        for i in 0..<totalPixels {
            let r = Int(pxA.rgba[i * 4])
            let g = Int(pxA.rgba[i * 4 + 1])
            let b = Int(pxA.rgba[i * 4 + 2])
            if r > 60 && r - g > 40 && r - b > 40 {
                redPixels += 1
            }
        }
        XCTAssertGreaterThan(redPixels, 500, "a should have > 500 red pixels")

        var diffB = 0
        var diffC = 0
        for i in 0..<totalPixels {
            let rA = Int(pxA.rgba[i * 4])
            let gA = Int(pxA.rgba[i * 4 + 1])
            let bA = Int(pxA.rgba[i * 4 + 2])

            let rB = Int(pxB.rgba[i * 4])
            let gB = Int(pxB.rgba[i * 4 + 1])
            let bB = Int(pxB.rgba[i * 4 + 2])

            if abs(rA - rB) > 8 || abs(gA - gB) > 8 || abs(bA - bB) > 8 {
                diffB += 1
            }

            let rC = Int(pxC.rgba[i * 4])
            let gC = Int(pxC.rgba[i * 4 + 1])
            let bC = Int(pxC.rgba[i * 4 + 2])

            if abs(rA - rC) > 8 || abs(gA - gC) > 8 || abs(bA - bC) > 8 {
                diffC += 1
            }
        }

        let maxAllowedDiff = Int(Double(totalPixels) * 0.005)
        XCTAssertLessThanOrEqual(diffB, maxAllowedDiff, "b differs from a in \(diffB) pixels (max allowed \(maxAllowedDiff))")
        XCTAssertLessThanOrEqual(diffC, maxAllowedDiff, "c differs from a in \(diffC) pixels (max allowed \(maxAllowedDiff))")
    }
}

/// Studio shadow-map reuse across frames (#666).
final class StudioShadowMapCacheTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('sm666f or sm666o')
            _c.mset()
            _c.frame(1)
            _c.set('metal_shadows', globals().pop('_sm666_shadows', 1))
            _c.set('metal_raytrace', globals().pop('_sm666_raytrace', 0))
            _c.set('bg_rgb', globals().pop('_sm666_bg', [0.0, 0.0, 0.0]))
            _c.set_lights(globals().pop('_sm666_rig', None))
            for _n in globals().pop('_sm666_enabled', []):
                _c.enable(_n)
            """)
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

    private func buildScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _sm666_enabled = _c.get_names('objects', enabled_only=1)
        _sm666_bg = list(_c.get_setting_tuple('bg_rgb')[1])
        _sm666_shadows = _c.get_setting_int('metal_shadows')
        _sm666_raytrace = _c.get_setting_int('metal_raytrace')
        _sm666_rig = _c.get_lights()
        for _n in _sm666_enabled:
            _c.disable(_n)
        _c.pseudoatom('sm666f', pos=[0.0, 0.0, 0.0])
        _c.pseudoatom('sm666o', pos=[3.0, 3.0, 18.0])
        _c.show_as('spheres', 'sm666f or sm666o')
        _c.color('white', 'sm666f or sm666o')
        _c.set('sphere_scale', 12.0, 'sm666f')
        _c.set('sphere_scale', 2.5, 'sm666o')
        _c.create('sm666o', 'sm666o', 1, 2)
        _c.translate([4.0, 0.0, 0.0], 'sm666o', state=2, camera=0)
        _c.mset('1 -2')
        _c.frame(1)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -60.0, 0.0, 0.0, 0.0, 40.0, 100.0, -20.0))
        _c.set('metal_shadows', 1)
        _c.set_lights({'enabled': True, 'lights': [{'name': 'key', 'anchor': 'camera', 'orbit': -30.0, 'pitch': 20.0, 'shadow': True}]})
        """)
    }

    private func passes(forget: Bool = false) throws -> Int {
        let out = NSTemporaryDirectory() + "issue_666_passes.txt"
        defer { try? FileManager.default.removeItem(atPath: out) }
        engine.runPython("""
        from pymol import cmd as _c
        open(r'\(out)', 'w').write(str(_c._cmd.get_light_shadow_map_passes(_c._COb, \(forget ? 1 : 0))))
        """)
        let text = try XCTUnwrap(FileManager.default.contents(atPath: out)
            .flatMap { String(data: $0, encoding: .utf8) }, "no readout written")
        return try XCTUnwrap(Int(text))
    }

    private func render() throws -> [UInt8] {
        let png = NSTemporaryDirectory() + "issue_666_render.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: png) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        XCTAssertTrue(drawn)
        return rgba
    }

    private func differs(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return Int.max }
        var diff = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
                diff += 1
            }
        }
        return diff
    }

    private func assertRerendersAndMatchesUncached(_ change: String, _ label: String) throws {
        let before = try render()
        let p0 = try passes()
        engine.runPython("from pymol import cmd as _c\n" + change)
        let cached = try render()
        let p1 = try passes()
        XCTAssertEqual(p1 - p0, 1, "\(label): the maps were not rendered again")
        _ = try passes(forget: true)
        let fresh = try render()
        XCTAssertEqual(try passes() - p1, 1, "\(label): forgetting the maps did not render them again")
        XCTAssertTrue(cached == fresh,
                      "\(label): the frame differs from an uncached one in \(differs(cached, fresh)) pixels")
        XCTAssertGreaterThan(differs(before, cached), 50, "\(label): the change did not show")
    }

    func testUnchangedSceneRendersTheMapsOnce() throws {
        try requireEngine()
        buildScene()
        _ = try render()
        let p0 = try passes()
        let a = try render()
        let p1 = try passes()
        let b = try render()
        let p2 = try passes()
        XCTAssertEqual(p1 - p0, 0, "an unchanged frame rendered the maps again")
        XCTAssertEqual(p2 - p1, 0, "an unchanged frame rendered the maps again")
        XCTAssertTrue(a == b, "two unchanged frames differ in \(differs(a, b)) pixels")
        _ = try passes(forget: true)
        let c = try render()
        XCTAssertEqual(try passes() - p2, 1, "forgetting the maps did not render them again")
        XCTAssertTrue(c == b, "the uncached frame differs in \(differs(c, b)) pixels")
        engine.runPython("from pymol import cmd as _c\n_c.set('metal_shadows', 0)")
        let plain = try render()
        XCTAssertGreaterThan(differs(plain, b), 100, "shadows were not actually drawn")
    }

    func testCameraTurnRendersTheMapsAgain() throws {
        try requireEngine()
        buildScene()
        try assertRerendersAndMatchesUncached("_c.turn('y', 15)\n", "camera turn")
    }

    func testMovingAnObjectRendersTheMapsAgain() throws {
        try requireEngine()
        buildScene()
        try assertRerendersAndMatchesUncached("_c.translate([0.0, 3.0, 0.0], 'sm666o', camera=0)\n", "moving an object")
    }

    func testRepChangeRendersTheMapsAgain() throws {
        try requireEngine()
        buildScene()
        try assertRerendersAndMatchesUncached("_c.set('sphere_scale', 4.0, 'sm666o')\n", "rep change")
    }

    func testLightChangeRendersTheMapsAgain() throws {
        try requireEngine()
        buildScene()
        try assertRerendersAndMatchesUncached("_r = _c.get_lights()\n_r['lights'][0]['orbit'] = 20.0\n_c.set_lights(_r)\n", "light change")
    }

    func testMovieFrameAdvanceRendersTheMapsAgain() throws {
        try requireEngine()
        buildScene()
        try assertRerendersAndMatchesUncached("_c.frame(2)\n", "movie frame advance")
    }
}

/// Issue #689: Metal exports draw bg_gradient backgrounds and ramp gadgets.
@MainActor
final class BackgroundGradientGadgetExportTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var sceneBuilt = false
    private var savedView: [Float]?

    override func tearDown() {
        if sceneBuilt {
            engine.runPython("""
            from pymol import cmd as _c
            _c.delete('bg689* or gr689*')
            _c.set('bg_gradient', globals().pop('_bg689_bg_gradient', 0))
            _c.set('bg_rgb_top', globals().pop('_bg689_bg_rgb_top', '0x00004D'))
            _c.set('bg_rgb_bottom', globals().pop('_bg689_bg_rgb_bottom', '0x333380'))
            _c.set('ray_opaque_background', globals().pop('_bg689_ray_opaque_background', 1))
            _c.set('metal_tonemap', globals().pop('_bg689_metal_tonemap', 0))
            _c.set('metal_exposure', globals().pop('_bg689_metal_exposure', 1.0))
            _c.set('bg_rgb', globals().pop('_bg689_bg_rgb', [0.0, 0.0, 0.0]))
            for _n in globals().pop('_bg689_enabled', []):
                _c.enable(_n)
            """)
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

    private func prepareScene() {
        savedView = engine.captureView()
        sceneBuilt = true
        engine.runPython("""
        from pymol import cmd as _c
        _bg689_enabled = _c.get_names('objects', enabled_only=1)
        _bg689_bg_rgb = list(_c.get_setting_tuple('bg_rgb')[1])
        _bg689_bg_gradient = _c.get_setting_int('bg_gradient')
        _bg689_bg_rgb_top = _c.get('bg_rgb_top')
        _bg689_bg_rgb_bottom = _c.get('bg_rgb_bottom')
        _bg689_ray_opaque_background = _c.get_setting_int('ray_opaque_background')
        _bg689_metal_tonemap = _c.get_setting_int('metal_tonemap')
        _bg689_metal_exposure = _c.get_setting_float('metal_exposure')
        for _n in _bg689_enabled:
            _c.disable(_n)
        _c.set('ray_opaque_background', 1)
        _c.set('bg_rgb', [0.0, 0.0, 0.0])
        _c.set('metal_tonemap', 0)
        _c.set('metal_exposure', 1.0)
        """)
    }

    private func pngPixels(pngPath: String, width: Int, height: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(
            URL(fileURLWithPath: pngPath) as CFURL, nil), "no export written")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn)
        return rgba
    }

    func testGradientEndsMatchTheSettings() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('bg_gradient', 1)
        _c.set('bg_rgb_top', [0.2, 0.4, 0.8])
        _c.set('bg_rgb_bottom', [0.8, 0.2, 0.1])
        """)
        for rt in [0, 1] {
            let png = NSTemporaryDirectory() + "issue_689_grad_rt\(rt).png"
            defer { try? FileManager.default.removeItem(atPath: png) }
            engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)
            let px = try pngPixels(pngPath: png, width: 400, height: 300)

            // Top row: (x = 200, y = 0)
            let topIdx = (0 * 400 + 200) * 4
            XCTAssertEqual(Int(px[topIdx]), 51, accuracy: 4, "top R (rt=\(rt))")
            XCTAssertEqual(Int(px[topIdx + 1]), 102, accuracy: 4, "top G (rt=\(rt))")
            XCTAssertEqual(Int(px[topIdx + 2]), 204, accuracy: 4, "top B (rt=\(rt))")
            XCTAssertEqual(px[topIdx + 3], 255, "top A (rt=\(rt))")

            // Bottom row: (x = 200, y = 299)
            let botIdx = (299 * 400 + 200) * 4
            XCTAssertEqual(Int(px[botIdx]), 204, accuracy: 4, "bottom R (rt=\(rt))")
            XCTAssertEqual(Int(px[botIdx + 1]), 51, accuracy: 4, "bottom G (rt=\(rt))")
            XCTAssertEqual(Int(px[botIdx + 2]), 25, accuracy: 4, "bottom B (rt=\(rt))")
            XCTAssertEqual(px[botIdx + 3], 255, "bottom A (rt=\(rt))")

            // Middle row: (x = 200, y = 150)
            let midIdx = (150 * 400 + 200) * 4
            let avgR = (51 + 204) / 2
            let avgG = (102 + 51) / 2
            let avgB = (204 + 25) / 2
            XCTAssertEqual(Int(px[midIdx]), avgR, accuracy: 6, "mid R (rt=\(rt))")
            XCTAssertEqual(Int(px[midIdx + 1]), avgG, accuracy: 6, "mid G (rt=\(rt))")
            XCTAssertEqual(Int(px[midIdx + 2]), avgB, accuracy: 6, "mid B (rt=\(rt))")
            XCTAssertEqual(px[midIdx + 3], 255, "mid A (rt=\(rt))")
        }
    }

    func testGradientIsBehindGeometry() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('bg_gradient', 1)
        _c.set('bg_rgb_top', [0.2, 0.4, 0.8])
        _c.set('bg_rgb_bottom', [0.8, 0.2, 0.1])
        _c.pseudoatom('bg689s', pos=[0.0, 0.0, 0.0])
        _c.show_as('spheres', 'bg689s')
        _c.color('white', 'bg689s')
        _c.set('sphere_scale', 6.0, 'bg689s')
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -40.0, 0.0, 0.0, 0.0, 20.0, 80.0, -20.0))
        """)
        let png = NSTemporaryDirectory() + "issue_689_behind.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)
        let px = try pngPixels(pngPath: png, width: 400, height: 300)

        // Corner pixel (0, 0) still ≈ top colour
        let cornerIdx = 0
        XCTAssertEqual(Int(px[cornerIdx]), 51, accuracy: 6, "corner R")
        XCTAssertEqual(Int(px[cornerIdx + 1]), 102, accuracy: 6, "corner G")
        XCTAssertEqual(Int(px[cornerIdx + 2]), 204, accuracy: 6, "corner B")

        // Center pixel (200, 150) is NOT the gradient colour (white sphere drawn)
        let midIdx = (150 * 400 + 200) * 4
        let r = Int(px[midIdx]), g = Int(px[midIdx + 1]), b = Int(px[midIdx + 2])
        let isGradient = abs(r - 127) <= 10 && abs(g - 76) <= 10 && abs(b - 114) <= 10
        XCTAssertFalse(isGradient, "center pixel should be covered by sphere, not gradient")
        XCTAssertGreaterThan(r, 150, "sphere center should be bright")
        XCTAssertGreaterThan(g, 150, "sphere center should be bright")
        XCTAssertGreaterThan(b, 150, "sphere center should be bright")
    }

    func testTransparentExportDropsTheGradient() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('bg_gradient', 1)
        _c.set('bg_rgb_top', [0.2, 0.4, 0.8])
        _c.set('bg_rgb_bottom', [0.8, 0.2, 0.1])
        _c.set('ray_opaque_background', 0)
        """)
        let png = NSTemporaryDirectory() + "issue_689_trans.png"
        defer { try? FileManager.default.removeItem(atPath: png) }
        engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: 0)
        let px = try pngPixels(pngPath: png, width: 400, height: 300)

        let topIdx = (0 * 400 + 200) * 4
        let botIdx = (299 * 400 + 200) * 4
        XCTAssertEqual(px[topIdx + 3], 0, "top row alpha must be 0")
        XCTAssertEqual(px[botIdx + 3], 0, "bottom row alpha must be 0")
    }

    func testRampGadgetIsDrawn() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _c.pseudoatom('gr689p', pos=[0.0, 0.0, 0.0])
        _c.disable('gr689p')
        _c.ramp_new('gr689', 'gr689p', [0, 10], ['red', 'blue'])
        """)

        for rt in [0, 1] {
            let png = NSTemporaryDirectory() + "issue_689_ramp_rt\(rt).png"
            defer { try? FileManager.default.removeItem(atPath: png) }
            engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)
            let px = try pngPixels(pngPath: png, width: 400, height: 300)

            var redCount = 0
            var blueCount = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if r > 200 && g < 60 && b < 60 {
                    redCount += 1
                }
                if b > 200 && r < 60 && g < 60 {
                    blueCount += 1
                }
            }
            XCTAssertGreaterThan(redCount, 100, "red ramp pixels (rt=\(rt))")
            XCTAssertGreaterThan(blueCount, 100, "blue ramp pixels (rt=\(rt))")
        }

        // Also with ray_opaque_background 0: the red pixels have alpha 255
        engine.runPython("from pymol import cmd as _c\n_c.set('ray_opaque_background', 0)")
        let transPng = NSTemporaryDirectory() + "issue_689_ramp_trans.png"
        defer { try? FileManager.default.removeItem(atPath: transPng) }
        engine.renderHiResPNG(transPng, width: 400, height: 300, rayTraced: 0)
        let transPx = try pngPixels(pngPath: transPng, width: 400, height: 300)

        var transRedCount = 0
        var opaqueRedCount = 0
        for i in stride(from: 0, to: transPx.count, by: 4) {
            let r = Int(transPx[i]), g = Int(transPx[i + 1]), b = Int(transPx[i + 2]), a = transPx[i + 3]
            if r > 200 && g < 60 && b < 60 {
                transRedCount += 1
                if a == 255 {
                    opaqueRedCount += 1
                }
            }
        }
        XCTAssertGreaterThan(transRedCount, 100, "transparent export red ramp pixels")
        XCTAssertEqual(opaqueRedCount, transRedCount, "red ramp pixels should have alpha 255")

        // grid_mode: the gadget draws in its own cell, with that cell's unit
        // context (it used to be left zeroed on Metal, and the bar vanished).
        engine.runPython("""
        from pymol import cmd as _c
        _bg689_grid = _c.get_setting_int('grid_mode')
        _c.set('ray_opaque_background', 1)
        _c.enable('gr689p')
        _c.show_as('spheres', 'gr689p')
        _c.set('grid_mode', 1)
        """)
        defer {
            engine.runPython("from pymol import cmd as _c\n_c.set('grid_mode', globals().pop('_bg689_grid', 0))")
        }
        let gridPng = NSTemporaryDirectory() + "issue_689_ramp_grid.png"
        defer { try? FileManager.default.removeItem(atPath: gridPng) }
        engine.renderHiResPNG(gridPng, width: 400, height: 300, rayTraced: 0)
        let gridPx = try pngPixels(pngPath: gridPng, width: 400, height: 300)
        var gridRed = 0, gridBlue = 0
        for i in stride(from: 0, to: gridPx.count, by: 4) {
            let r = Int(gridPx[i]), g = Int(gridPx[i + 1]), b = Int(gridPx[i + 2])
            if r > 200 && g < 60 && b < 60 { gridRed += 1 }
            if b > 200 && r < 60 && g < 60 { gridBlue += 1 }
        }
        XCTAssertGreaterThan(gridRed, 20, "red ramp pixels in grid_mode")
        XCTAssertGreaterThan(gridBlue, 20, "blue ramp pixels in grid_mode")
    }

    func testPlainExportUnchanged() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('bg_gradient', 0)
        _c.pseudoatom('bg689u', pos=[0.0, 0.0, 0.0])
        _c.show_as('spheres', 'bg689u')
        _c.color('white', 'bg689u')
        _c.set('sphere_scale', 6.0, 'bg689u')
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -40.0, 0.0, 0.0, 0.0, 20.0, 80.0, -20.0))
        """)

        let png1 = NSTemporaryDirectory() + "issue_689_plain1.png"
        defer { try? FileManager.default.removeItem(atPath: png1) }
        engine.renderHiResPNG(png1, width: 400, height: 300, rayTraced: 0)
        let bytes1 = try pngPixels(pngPath: png1, width: 400, height: 300)

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in bytes1 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        print("689-plain-hash \(String(hash, radix: 16))")

        // Then set bg_gradient 1, create+delete a ramp gadget, render once, set bg_gradient 0 again and render
        engine.runPython("""
        from pymol import cmd as _c
        _c.set('bg_gradient', 1)
        _c.pseudoatom('gr689tmp', pos=[0.0, 0.0, 0.0])
        _c.disable('gr689tmp')
        _c.ramp_new('gr689r', 'gr689tmp', [0, 10], ['red', 'blue'])
        """)
        let pngTmp = NSTemporaryDirectory() + "issue_689_plaintmp.png"
        defer { try? FileManager.default.removeItem(atPath: pngTmp) }
        engine.renderHiResPNG(pngTmp, width: 400, height: 300, rayTraced: 0)

        engine.runPython("""
        from pymol import cmd as _c
        _c.delete('gr689*')
        _c.set('bg_gradient', 0)
        """)

        let png2 = NSTemporaryDirectory() + "issue_689_plain2.png"
        defer { try? FileManager.default.removeItem(atPath: png2) }
        engine.renderHiResPNG(png2, width: 400, height: 300, rayTraced: 0)
        let bytes2 = try pngPixels(pngPath: png2, width: 400, height: 300)

        XCTAssertEqual(bytes1, bytes2, "render after toggling gradient and gadget must equal first render")
    }

    /// Depth-cue fog fades distant geometry toward the background AT THAT
    /// PIXEL, as GL and the CPU ray tracer do with a gradient, not toward
    /// bg_rgb (black here): the farthest sphere comes out in the gradient's
    /// light mid tone, not dark.
    func testFogFadesTowardTheGradient() throws {
        try requireEngine()
        prepareScene()
        engine.runPython("""
        from pymol import cmd as _c
        _bg689_fog = (_c.get_setting_int('depth_cue'), _c.get_setting_float('fog'),
                      _c.get_setting_float('fog_start'))
        _c.set('bg_gradient', 1)
        _c.set('bg_rgb_top', [0.9, 0.9, 0.9])
        _c.set('bg_rgb_bottom', [0.9, 0.9, 0.9])
        for _i in range(12):
            _c.pseudoatom('bg689f', pos=[(_i - 6) * 4.0, 0.0, -_i * 8.0], state=1)
        _c.show_as('spheres', 'bg689f')
        _c.color('black', 'bg689f')
        _c.set('sphere_scale', 2.0, 'bg689f')
        _c.set('depth_cue', 1)
        _c.set('fog', 1.0)
        _c.set('fog_start', 0.2)
        _c.set_view((1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
                     0.0, 0.0, -50.0, 0.0, 0.0, -30.0, 30.0, 120.0, -20.0))
        """)
        defer {
            engine.runPython("""
            from pymol import cmd as _c
            _f = globals().pop('_bg689_fog', None)
            if _f:
                _c.set('depth_cue', _f[0]); _c.set('fog', _f[1]); _c.set('fog_start', _f[2])
            """)
        }
        for rt in [0, 1] {
            let png = NSTemporaryDirectory() + "issue_689_fog_rt\(rt).png"
            defer { try? FileManager.default.removeItem(atPath: png) }
            engine.renderHiResPNG(png, width: 400, height: 300, rayTraced: rt)
            let px = try pngPixels(pngPath: png, width: 400, height: 300)
            // The nearest black sphere stays dark; the farthest one (right end
            // of the row) is fogged toward the light gradient, not toward the
            // black bg_rgb. Without the gradient fog both would be black.
            let near = (150 * 400 + 70) * 4
            let far = (150 * 400 + 355) * 4
            XCTAssertLessThan(Int(px[near]), 90, "near sphere (rt=\(rt))")
            XCTAssertGreaterThan(Int(px[far]), 120, "far sphere fogs toward the gradient (rt=\(rt))")
        }
    }
}
