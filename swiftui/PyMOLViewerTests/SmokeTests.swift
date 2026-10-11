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
