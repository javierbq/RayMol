import XCTest
import SwiftUI
@testable import RayMol

/// The Timeline's track row (the ruler over the item lane, beside the "Track"
/// gutter) under both AppKit scroller styles. Legacy scroll bars ("Show scroll
/// bars: Always", or "Automatically" with a mouse attached, as on GitHub's
/// macOS runners and in VMs) put a 17 pt scroller below the lane's content once
/// the lane overflows. The row must grow by that much, so the ruler stays level
/// with the gutter and under the header. Overlay scroll bars leave the row as
/// it was.
///
/// A run gets its host machine's scroller style. To force one, copy the
/// `UnitTests_macOS_*.xctestrun` that `xcodebuild build-for-testing` writes to
/// `<derivedData>/Build/Products/`, keep the copy in that directory, add
/// `CommandLineArguments` `["-AppleShowScrollBars", "Always"]` (legacy) or
/// `"WhenScrolling"` (overlay) to the test target in it, and run
/// `xcodebuild test-without-building -xctestrun <copy>`. Setting the default
/// from inside a running test is too late: the host app already has the
/// system's style.
final class TimelineLaneLayoutTests: XCTestCase {
    private var engine: PyMOLEngine { PyMOLEngine.shared }
    private var savedItems: [PyMOLEngine.TimelineItem] = []
    private var savedUntracked = false
    private var window: NSWindow?
    private let scale: CGFloat = 2          // pixels per point of the drawn panel

    // TimelinePanel's geometry: the 44 pt header and its 1 pt rule, then the
    // track row, the 28 pt ruler over the 56 pt item lane.
    private let rowTop: CGFloat = 45
    private let rulerH: CGFloat = 28
    private let laneH: CGFloat = 56

    override func setUpWithError() throws {
        let deadline = Date().addingTimeInterval(20)
        while !engine.isReady && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard engine.isReady else {
            XCTFail("PyMOLEngine.shared was not ready")
            throw NSError(domain: "PyMOLEngine", code: 1)
        }
        savedItems = engine.timelineItems
        savedUntracked = engine.untrackedMovie
    }

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        engine.clearMovieItems()
        engine.timelineItems = savedItems
        engine.untrackedMovie = savedUntracked
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let s = view as? NSScrollView { found.append(s) }
        for sub in view.subviews { found += scrollViews(sub) }
        return found
    }

    /// Two camera keyframes `seconds` apart. The lane holds about 10 s at zoom 1.
    private func setMovie(seconds: Double) {
        engine.timelineItems = [
            PyMOLEngine.TimelineItem(kind: .camera),
            PyMOLEngine.TimelineItem(kind: .camera, transition: .init(seconds: seconds)),
        ]
    }

    private struct Row {
        var lane: CGRect            // the lane's NSScrollView, host points (y down)
        var clip: CGRect            // its clip view: the ruler + item lane
        var scroller: CGRect?       // the horizontal scroll bar, when AppKit shows it
        var legacy: Bool
        var bar: CGFloat            // the room a legacy scroll bar needs below the lane
        var panelH: CGFloat         // the whole panel's fitting height
        var gutterIconMidY: CGFloat // the gutter's film icon, drawn
    }

    private func measure(_ host: NSHostingView<some View>, _ label: String) throws -> Row {
        host.layoutSubtreeIfNeeded()
        settle(0.8)
        host.layoutSubtreeIfNeeded()
        let lanes = scrollViews(host).filter {
            abs(($0.documentView?.frame.height ?? 0) - (rulerH + laneH)) < 0.5
        }
        XCTAssertEqual(lanes.count, 1, "\(label): one lane scroll view")
        let lane = try XCTUnwrap(lanes.first, "\(label): no lane scroll view")
        let shown = lane.horizontalScroller.flatMap { $0.isHidden ? nil : $0 }
        let legacy = lane.scrollerStyle == .legacy
        let row = Row(
            lane: lane.convert(lane.bounds, to: host),
            clip: lane.contentView.convert(lane.contentView.bounds, to: host),
            scroller: shown.map { $0.convert($0.bounds, to: host) },
            legacy: legacy,
            bar: legacy && shown != nil
                ? NSScroller.scrollerWidth(for: shown!.controlSize, scrollerStyle: .legacy) : 0,
            panelH: host.fittingSize.height,
            gutterIconMidY: try gutterIconMidY(host))
        print("TimelineLaneLayout \(label): style=\(legacy ? "legacy" : "overlay") lane=\(row.lane)"
              + " clip=\(row.clip) scroller=\(row.scroller.map { "\($0)" } ?? "hidden")"
              + " panelH=\(row.panelH) gutterIconMidY=\(row.gutterIconMidY)")
        return row
    }

    /// The vertical middle, in host points, of the gutter's film icon: the
    /// pixels near the accent colour in the gutter's leading 26 pt, below the
    /// header.
    private func gutterIconMidY(_ host: NSView) throws -> CGFloat {
        let w = Int(host.bounds.width * scale), h = Int(host.bounds.height * scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let layer = try XCTUnwrap(host.layer)
        try pixels.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: scale, y: -scale)
            layer.render(in: ctx)
        }
        let accent = try XCTUnwrap(NSColor(TimelineTheme.accent).usingColorSpace(.sRGB))
        var rows: [Int] = []
        for y in Int(rowTop * scale)..<min(Int((rowTop + rulerH + laneH + 20) * scale), h) {
            for x in 0..<Int(26 * scale) {
                let i = (y * w + x) * 4
                let a = max(Double(pixels[i + 3]) / 255, 1e-6)
                let dr = Double(pixels[i]) / 255 / a - Double(accent.redComponent)
                let dg = Double(pixels[i + 1]) / 255 / a - Double(accent.greenComponent)
                let db = Double(pixels[i + 2]) / 255 / a - Double(accent.blueComponent)
                if (dr * dr + dg * dg + db * db).squareRoot() < 0.15 { rows.append(y); break }
            }
        }
        let top = try XCTUnwrap(rows.min(), "no film icon drawn in the gutter")
        return CGFloat(top + rows.max()! + 1) / 2 / scale
    }

    func testTrackRowMakesRoomForALegacyScrollBar() throws {
        let forced = UserDefaults.standard.volatileDomain(
            forName: UserDefaults.argumentDomain)["AppleShowScrollBars"] as? String
        let host = NSHostingView(rootView: TimelinePanel()
            .environmentObject(engine)
            .environmentObject(engine.playback))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        self.window = window
        XCTAssertTrue(host.isFlipped)

        setMovie(seconds: 2)
        let fits = try measure(host, "fits")
        setMovie(seconds: 40)
        let overflows = try measure(host, "overflows")

        // The forced runs really exercise the style they ask for.
        switch forced {
        case "Always": XCTAssertTrue(overflows.legacy, "-AppleShowScrollBars Always: legacy scroll bars")
        case "WhenScrolling": XCTAssertFalse(overflows.legacy, "-AppleShowScrollBars WhenScrolling: overlay")
        default: break
        }
        // A lane that fits shows no scroll bar, in either style.
        XCTAssertNil(fits.scroller, "a 2 s movie fits the lane")
        XCTAssertEqual(fits.bar, 0)
        XCTAssertNotNil(overflows.scroller, "a 40 s movie overflows the lane")
        if overflows.legacy {
            XCTAssertEqual(overflows.bar, 17, accuracy: 0.5)
        } else {
            XCTAssertEqual(overflows.bar, 0)
        }

        for (label, row) in [("fits", fits), ("overflows", overflows)] {
            // The ruler starts right under the header's rule, as the gutter does.
            XCTAssertEqual(row.lane.minY, rowTop, accuracy: 0.5, "\(label): lane top")
            XCTAssertEqual(row.clip.minY, rowTop, accuracy: 0.5, "\(label): ruler top")
            XCTAssertEqual(row.clip.height, rulerH + laneH, accuracy: 0.5, "\(label): ruler + items")
            // The scroll bar, if any, sits below the items, inside the row.
            XCTAssertEqual(row.lane.height, rulerH + laneH + row.bar, accuracy: 0.5, "\(label): row height")
            if row.legacy, let s = row.scroller {
                XCTAssertEqual(s.minY, rowTop + rulerH + laneH, accuracy: 0.5, "\(label): scroll bar top")
                XCTAssertEqual(s.maxY, row.lane.maxY, accuracy: 0.5, "\(label): scroll bar bottom")
            }
            // The gutter's track label stays level with the item lane.
            XCTAssertEqual(row.gutterIconMidY, rowTop + rulerH + laneH / 2, accuracy: 1.5,
                           "\(label): gutter icon level with the items")
        }
        // The row, and so the panel, grows by just the legacy scroll bar: the
        // bar takes room of its own instead of covering the scenes strip.
        XCTAssertEqual(overflows.panelH - fits.panelH, overflows.bar, accuracy: 0.5,
                       "the panel grows by the scroll bar's room")
    }
}
