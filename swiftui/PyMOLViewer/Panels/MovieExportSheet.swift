// MovieExportSheet.swift — render the Timeline to a movie file with in-app
// encoding (MP4 via AVAssetWriter, GIF via ImageIO) — no ffmpeg needed.
//
// Pipeline: pause playback, then per frame set cmd.frame(N) and capture the full
// Metal pipeline offscreen via engine.renderHiResPNG (the known-good capture path
// — NOT cmd.mpng, which uses a GL framebuffer path unavailable on this backend),
// load the PNG and stream it into the encoder. Frames are written/released one at
// a time so memory stays bounded. Result is shared (iOS) or saved (macOS).

import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Exporter

// NOT @MainActor: the per-frame core render (renderHiResPNG) + AV/GIF encode run
// on `renderQueue` so they don't block the UI (#58 L-59). @Published mutations
// are explicitly hopped back to the main thread; loop control (idx/isExporting)
// is only touched on the main thread (in renderNext / start / finish).
final class MovieExporter: ObservableObject {
    enum Format: String, CaseIterable, Identifiable { case mp4 = "MP4", gif = "GIF"; var id: String { rawValue } }

    // Serial: frames render + encode one at a time, off the main thread.
    private let renderQueue = DispatchQueue(label: "io.raymol.movieexport", qos: .userInitiated)

    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var finishedURL: URL?
    @Published var errorText: String?

    private weak var engine: PyMOLEngine?
    private var format: Format = .mp4
    private var width = 1280, height = 720
    private var first = 1, last = 1, fps = 30, rayTraced = 0
    private var idx = 0
    private var frameDir: URL?
    private var outURL: URL?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var gifDest: CGImageDestination?

    private var total: Int { max(last - first + 1, 1) }

    func start(engine: PyMOLEngine, format: Format, width: Int, height: Int,
               first: Int, last: Int, fps: Int, rayTraced: Bool) {
        guard !isExporting else { return }
        self.engine = engine
        self.format = format
        // H.264 requires even dimensions.
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
        self.first = max(1, min(first, last))
        self.last = max(self.first, last)
        self.fps = max(1, fps)
        self.rayTraced = rayTraced ? 1 : 0
        self.idx = self.first
        self.progress = 0
        self.errorText = nil
        self.finishedURL = nil

        let tmp = FileManager.default.temporaryDirectory
        frameDir = tmp.appendingPathComponent("pymol_frames_\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: frameDir!, withIntermediateDirectories: true)
        outURL = tmp.appendingPathComponent("RayMol_movie.\(format == .mp4 ? "mp4" : "gif")")
        try? FileManager.default.removeItem(at: outURL!)

        guard setupEncoder() else {
            errorText = "Could not initialize the \(format.rawValue) encoder."
            cleanup(); return
        }

        engine.pause()           // stop core-driven advance during capture
        // Claim the core for the exporter: the live draw loop + feedback poll now
        // skip (they gate on this), so renderHiResPNG can run off-main exclusively.
        engine.exportRenderActive = true
        isExporting = true
        renderNext()
    }

    private func setupEncoder() -> Bool {
        guard let outURL = outURL else { return false }
        switch format {
        case .mp4:
            guard let w = try? AVAssetWriter(outputURL: outURL, fileType: .mp4) else { return false }
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                ])
            guard w.canAdd(input) else { return false }
            w.add(input)
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: .zero)
            writer = w; videoInput = input; self.adaptor = adaptor
            return true
        case .gif:
            guard let dest = CGImageDestinationCreateWithURL(
                outURL as CFURL, UTType.gif.identifier as CFString, total, nil) else { return false }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(dest, props as CFDictionary)
            gifDest = dest
            return true
        }
    }

    // Drives one frame per cycle. Loop control (idx/isExporting/progress) is only
    // touched here on the MAIN thread; the heavy per-frame work — set frame +
    // renderHiResPNG (a blocking GPU render that reshapes the core) + encode —
    // runs on renderQueue OFF the main thread, so the UI stays responsive even
    // for slow ray-traced frames. The live draw loop + feedback poll are gated
    // by engine.exportRenderActive, so the exporter is the sole core user. (#58 L-59)
    private func renderNext() {
        guard isExporting, let engine = engine, let frameDir = frameDir else { return }
        if idx > last { finish(); return }
        let captureIdx = idx, w = width, h = height, rt = rayTraced
        let png = frameDir.appendingPathComponent("f\(captureIdx).png")
        // cmd.frame is a Python call — it MUST run on the main thread. The
        // embedded interpreter uses PyMOL's PAutoBlock (a single shared thread
        // state), NOT PyGILState_Ensure, so driving it from another queue
        // corrupts the Python heap (verified: SIGSEGV in _PyObject_Malloc).
        // Only the heavy, Python-FREE C++ render + encode go off-main. The frame
        // is fully set here before the render is dispatched, so there's no overlap
        // (and the next frame is only set after this one's render completes).
        engine.runPython("from pymol import cmd as _c\n_c.frame(\(captureIdx))")
        renderQueue.async { [weak self, weak engine] in
            guard let self = self, let engine = engine else { return }
            // Off main, exclusive core access (live draw loop + feedback poll are
            // gated by exportRenderActive). renderOneOffscreen is pure C++/Metal —
            // it runs SceneUpdate to rebuild the just-set frame's reps, blocks on
            // the GPU, and writes the PNG — no Python, so it's safe off the main
            // thread and the UI stays responsive during the slow (RT) render.
            engine.renderHiResPNG(png.path, width: w, height: h, rayTraced: rt)
            if let cg = self.loadCGImage(png) { self.appendFrame(cg, frameIndex: captureIdx) }   // encode off-main
            try? FileManager.default.removeItem(at: png)
            DispatchQueue.main.async {
                guard self.isExporting else { return }
                self.progress = Double(captureIdx - self.first + 1) / Double(self.total)
                self.idx += 1
                self.renderNext()
            }
        }
    }

    // Runs on renderQueue (off main). `frameIndex` is passed in rather than read
    // from `self.idx` (which the main thread mutates) so there's no cross-thread
    // read of the loop counter.
    private func appendFrame(_ cg: CGImage, frameIndex: Int) {
        switch format {
        case .mp4:
            guard let input = videoInput, let adaptor = adaptor else { return }
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 200 { usleep(2000); tries += 1 }
            if let pb = pixelBuffer(from: cg) {
                let t = CMTime(value: Int64(frameIndex - first), timescale: Int32(fps))
                adaptor.append(pb, withPresentationTime: t)
            }
        case .gif:
            guard let dest = gifDest else { return }
            // renderHiResPNG produces a transparent background (molecule alpha=1,
            // bg alpha=0). GIF would collapse that to its background color, so
            // flatten onto opaque black first (matching the MP4 pixel-buffer path).
            let opaque = flattenedOpaque(cg) ?? cg
            let props = [kCGImagePropertyGIFDictionary:
                            [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]]
            CGImageDestinationAddImage(dest, opaque, props as CFDictionary)
        }
    }

    // Composite a (possibly transparent) frame onto opaque black.
    private func flattenedOpaque(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func finish() {
        switch format {
        case .mp4:
            videoInput?.markAsFinished()
            writer?.finishWriting { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.writer?.status == .completed { self.complete(self.outURL) }
                    else { self.errorText = self.writer?.error?.localizedDescription ?? "Encoding failed."; self.cleanup() }
                }
            }
        case .gif:
            if let dest = gifDest, CGImageDestinationFinalize(dest) { complete(outURL) }
            else { errorText = "GIF encoding failed."; cleanup() }
        }
    }

    private func complete(_ url: URL?) {
        finishedURL = url
        isExporting = false
        progress = 1
        engine?.exportRenderActive = false   // hand the core back to the live loop
        if let d = frameDir { try? FileManager.default.removeItem(at: d) }
    }

    private func cleanup() {
        isExporting = false
        engine?.exportRenderActive = false   // hand the core back to the live loop
        if let d = frameDir { try? FileManager.default.removeItem(at: d) }
        writer = nil; videoInput = nil; adaptor = nil; gifDest = nil
    }

    // Safety net: if the sheet is dismissed mid-export and the exporter is
    // released, never leave the core flag stuck true (that would freeze the live
    // viewport). The in-flight renderQueue frame finishes harmlessly.
    deinit { engine?.exportRenderActive = false }

    // MARK: helpers

    private func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB, attrs, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - Reusable controls

// The export form (presented by MovieExportSheet from the top Export menu /
// transport overflow). Self-contained (owns its MovieExporter). Renders the
// full timeline — no frame-range picker.
struct MovieExportControls: View {
    @EnvironmentObject var engine: PyMOLEngine
    @StateObject private var exporter = MovieExporter()

    private struct SizePreset: Identifiable { let id = UUID(); let name: String; let w: Int; let h: Int }
    private let presets = [SizePreset(name: "720p", w: 1280, h: 720),
                           SizePreset(name: "480p", w: 854, h: 480),
                           SizePreset(name: "360p", w: 640, h: 360)]

    @State private var format: MovieExporter.Format = .mp4
    @State private var presetIdx = 0
    @State private var rayMode = false

    private var frameCount: Int { max(engine.playback.frameCount, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            labeled("Format") {
                Picker("", selection: $format) {
                    ForEach(MovieExporter.Format.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            labeled("Size") {
                Picker("", selection: $presetIdx) {
                    ForEach(presets.indices, id: \.self) { i in
                        Text("\(presets[i].name)  ·  \(presets[i].w)×\(presets[i].h)").tag(i)
                    }
                }.pickerStyle(.segmented)
            }
            Toggle(isOn: $rayMode) {
                Label("Ray-traced frames (slow)", systemImage: "sparkles")
            }.tint(TimelineTheme.accent)
            if rayMode {
                Text("Ray-tracing every frame is much slower.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("\(frameCount) frames at \(Int(engine.playback.movieFPS.rounded())) fps.")
                .font(.caption).foregroundStyle(.secondary)

            if exporter.isExporting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: exporter.progress)
                        .tint(TimelineTheme.accent)
                    Text("Rendering frame \(Int(exporter.progress * Double(frameCount)))/\(frameCount)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let err = exporter.errorText {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Button(action: runExport) {
                Label(exporter.isExporting ? "Rendering…" : "Render & Export",
                      systemImage: "film")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(TimelineTheme.accent)
            .disabled(exporter.isExporting || engine.playback.frameCount <= 1)
        }
        .onChange(of: exporter.finishedURL) { url in
            if let url = url { deliver(url) }
        }
    }

    private func runExport() {
        let p = presets[presetIdx]
        exporter.start(engine: engine, format: format, width: p.w, height: p.h,
                       first: 1, last: frameCount, fps: Int(engine.playback.movieFPS.rounded()),
                       rayTraced: rayMode)
    }

    // MARK: deliver result

    private func deliver(_ url: URL) {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
        #else
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        if let ct = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [ct] }
        panel.canCreateDirectories = true
        panel.title = "Save Movie"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        #endif
    }

    @ViewBuilder
    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Sheet wrapper

struct MovieExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Export Movie").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }.padding(16)

            ScrollView {
                MovieExportControls().padding(16)
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 420, height: 480)
        #endif
    }
}

// MARK: - Movie content tab

// The Movie content tab authors an animation (camera / state / scene movie)
// that plays on the transport. Rendering to a file lives in the top Export
// menu → "Export Movie" (enabled once there's something to play), so this pane
// is purely the builder.
struct MoviePane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                MovieBuilderControls(initialTab: Self.initialTabFromEnv)
            }
            .padding(16)
            // Clear the floating tab-bar pill so the controls stay reachable.
            .padding(.bottom, 56)
        }
    }

    // Test affordance: preselect the builder tab for the screenshot harness
    // (simctl can't tap). PYMOL_AUTOMOVIETAB=camera|states|scenes.
    private static var initialTabFromEnv: MovieBuilderControls.Tab {
        switch ProcessInfo.processInfo.environment["PYMOL_AUTOMOVIETAB"] {
        case "states": return .states
        case "scenes": return .scenes
        default: return .camera
        }
    }
}
