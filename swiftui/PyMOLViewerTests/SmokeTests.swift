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

    private func requireEngine() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready")
            throw NSError(domain: "PyMOLEngine", code: 1)
        }
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

