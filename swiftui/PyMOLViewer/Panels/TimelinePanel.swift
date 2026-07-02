// TimelinePanel.swift — the docked "movie studio" (Timeline mode).
//
// Promotes RayMol's linear frame transport into a multi-track composition editor
// (the PyMOL 3 Timeline, adapted to touch + pointer). Shown only while
// engine.timelineMode is on; docks below the viewport on macOS and as a bottom
// overlay on iOS. Reuses TransportBar for playback so the playhead IS the core
// frame — this view only adds the tracks above it.
//
// Tracks (drag-and-drop to re-time):
//   • Camera — manual mview keyframes (engine.cameraKeyframes) as diamonds:
//     drag to re-time, tap to seek, long-press to delete; drag the ruler to scrub.
//   • Scenes — scenes placed AS time markers (engine.sceneMarkers), backed by
//     `mview store, scene=` so the camera flies between scenes while reps cut.
//     A palette strip below is the source: drag a chip onto the lane (macOS) or
//     tap to drop it at the playhead (touch); markers then drag to re-time.
// Templates (the MovieBuilderSheet presets) drop a ready-made movie; Produce
// hands the result to MovieExportSheet. Per-segment easing, per-object tracks and
// Record mode are the next phases (see the design study).

import SwiftUI

struct TimelinePanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject var playback: PlaybackState

    /// Called when the user exits the mode (Done / close). Defaults to flipping
    /// engine.timelineMode so the caller can just drop `TimelinePanel()` in.
    var onExit: (() -> Void)? = nil

    @State private var interpLinear = false
    @State private var showBuilder = false
    @State private var showExport = false

    // Drag-to-re-time state: while dragging a diamond or scene marker we render
    // it at `dragToFrame` (live) and commit the move on release.
    private enum DragItem: Equatable { case camera(Int); case scene(Int, String) }
    @State private var dragItem: DragItem? = nil
    @State private var dragToFrame: Int = 1

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    private let laneH: CGFloat = 40
    private let rulerH: CGFloat = 22
    private var labelW: CGFloat { isCompact ? 66 : 96 }
    private let laneSpace = "timelineLane"   // coord space for drag→frame mapping

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TimelineTheme.accent.opacity(0.35)).frame(height: 1)
            tracksSection
            scenePaletteStrip
            Divider()
            TransportBar()
        }
        .background(TimelineTheme.bar)
        .sheet(isPresented: $showBuilder) { MovieBuilderSheet() }
        .sheet(isPresented: $showExport) { MovieExportSheet() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clapperboard.fill")
                .font(.system(size: 14))
                .foregroundColor(TimelineTheme.accent)
            Text("Timeline")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(TimelineTheme.text)
            if !isCompact {
                Text("Composition 0")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TimelineTheme.dim)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            addButton

            if isCompact {
                overflowMenu
            } else {
                interpControl
                lengthMenu
                textButton("Templates", "wand.and.stars") { showBuilder = true }
                textButton("Produce", "film") { showExport = true }
                    .disabled(playback.frameCount <= 1)
            }

            doneButton
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private var addButton: some View {
        Button(action: addKeyframe) {
            Label("Keyframe", systemImage: "plus.diamond.fill")
                .font(.system(size: 12, weight: .semibold))
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.accent)
        .accessibilityLabel("Capture camera keyframe at playhead")
        .help("Capture a camera keyframe at the playhead")
    }

    private var interpControl: some View {
        Picker("", selection: $interpLinear) {
            Text("Smooth").tag(false)
            Text("Linear").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .onChange(of: interpLinear) { linear in
            if !engine.cameraKeyframes.isEmpty { engine.setInterpolation(linear: linear) }
        }
    }

    private var lengthMenu: some View {
        Menu {
            Section("New camera movie") {
                ForEach([5, 10, 20, 30], id: \.self) { s in
                    Button("\(s) s") { engine.newTimeline(seconds: Double(s)) }
                }
            }
            if !engine.cameraKeyframes.isEmpty || playback.frameCount > 1 {
                Divider()
                Button(role: .destructive) { engine.clearMovie() } label: {
                    Label("Clear timeline", systemImage: "trash")
                }
            }
        } label: {
            Label("Length", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12))
        }
        .fixedSize()
        .tint(TimelineTheme.text)
    }

    // Compact: fold Length / Interp / Templates / Produce / Clear into one menu.
    private var overflowMenu: some View {
        Menu {
            Section("New camera movie") {
                ForEach([5, 10, 20, 30], id: \.self) { s in
                    Button("\(s) s") { engine.newTimeline(seconds: Double(s)) }
                }
            }
            Picker("Interpolation", selection: $interpLinear) {
                Text("Smooth").tag(false)
                Text("Linear").tag(true)
            }
            Divider()
            Button { showBuilder = true } label: { Label("Templates…", systemImage: "wand.and.stars") }
            Button { showExport = true } label: { Label("Produce…", systemImage: "film") }
                .disabled(playback.frameCount <= 1)
            if !engine.cameraKeyframes.isEmpty || playback.frameCount > 1 {
                Divider()
                Button(role: .destructive) { engine.clearMovie() } label: {
                    Label("Clear timeline", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundColor(TimelineTheme.text)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .onChange(of: interpLinear) { linear in
            if !engine.cameraKeyframes.isEmpty { engine.setInterpolation(linear: linear) }
        }
    }

    private var doneButton: some View {
        Button { (onExit ?? { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = false } })() } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                Text("Done")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(TimelineTheme.accent))
        }
        .buttonStyle(.plain)
        .help("Exit Timeline mode")
        .accessibilityLabel("Close timeline")
    }

    private func textButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.text)
    }

    // MARK: - Tracks

    private var tracksSection: some View {
        HStack(spacing: 0) {
            // Left: track labels, aligned to the lanes on the right.
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerH)
                trackLabel("Camera", "camera.fill", tint: TimelineTheme.accent)
                trackLabel("Scenes", "photo.stack", tint: TimelineTheme.dim)
            }
            .frame(width: labelW)

            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

            // Right: ruler + lanes + playhead, positioned by frame fraction.
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ruler(width: w)
                        cameraLane(width: w)
                        scenesLane(width: w)
                    }
                    playhead(width: w)
                }
                .coordinateSpace(name: laneSpace)
            }
            .frame(height: rulerH + laneH * 2)
        }
    }

    private func trackLabel(_ title: String, _ icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(tint)
            Text(title)
                .font(.system(size: isCompact ? 10 : 11))
                .foregroundColor(TimelineTheme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    // Ruler doubles as the scrub strip: drag anywhere on it to move the playhead.
    private func ruler(width w: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.03))
            ForEach(0..<5) { i in
                let frac = CGFloat(i) / 4
                Text(timeLabel(frac))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TimelineTheme.dim)
                    .offset(x: min(frac * w + 3, w - 26), y: -4)
            }
        }
        .frame(height: rulerH)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in engine.scrub(to: frame(atX: g.location.x, width: w)) }
                .onEnded { _ in engine.endScrub() }
        )
    }

    private func cameraLane(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(TimelineTheme.accent.opacity(0.05))
            if engine.cameraKeyframes.isEmpty {
                Text(playback.frameCount > 1
                     ? "Scrub, then + to capture a camera keyframe"
                     : "Set a length, then + to capture the first view")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .padding(.leading, 10)
                    .frame(height: laneH, alignment: .leading)
            }
            ForEach(engine.cameraKeyframes, id: \.self) { f in
                keyframeDiamond(f, width: w)
            }
        }
        .frame(height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
        .clipped()
    }

    private func keyframeDiamond(_ f: Int, width w: CGFloat) -> some View {
        let dragging = dragItem == .camera(f)
        let shownFrame = dragging ? dragToFrame : f
        let isCurrent = f == playback.currentFrame
        return RoundedRectangle(cornerRadius: 2)
            .fill(isCurrent ? TimelineTheme.text : TimelineTheme.accent)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.4), radius: 0.5)
            .scaleEffect(dragging ? 1.3 : 1)
            .frame(width: 28, height: laneH)          // larger, easier drag/tap target
            .contentShape(Rectangle())
            .position(x: clampX(xFor(shownFrame, width: w), width: w), y: laneH / 2)
            .gesture(reTimeDrag(width: w, item: { .camera(f) },
                                commit: { to in engine.moveKeyframe(from: f, to: to, linear: interpLinear) }))
            .onTapGesture { engine.seek(to: f) }
            .contextMenu {
                Text("Keyframe · frame \(f)")
                Button(role: .destructive) {
                    engine.deleteKeyframe(at: f, linear: interpLinear)
                } label: { Label("Delete keyframe", systemImage: "trash") }
            }
            .accessibilityLabel("Camera keyframe at frame \(f)")
    }

    // Shared re-time drag for diamonds & scene markers. A small minimumDistance
    // keeps a stationary tap from starting a drag, so tap-to-seek still works.
    // Location is read in the lane coordinate space and mapped to a frame.
    private func reTimeDrag(width w: CGFloat, item: @escaping () -> DragItem,
                            commit: @escaping (Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(laneSpace))
            .onChanged { g in
                if dragItem == nil { dragItem = item() }
                dragToFrame = frame(atX: g.location.x, width: w)
            }
            .onEnded { _ in
                let to = dragToFrame
                dragItem = nil
                commit(to)
            }
    }

    // Time-positioned scene markers (mirrors the camera lane). Markers are placed
    // from the palette strip below; drag to re-time, tap to seek, long-press to
    // remove. On macOS a palette chip can be dropped straight onto a time here.
    private func scenesLane(width w: CGFloat) -> some View {
        let lane = ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.02))
            if engine.sceneMarkers.isEmpty {
                Text(engine.sceneNames.isEmpty
                     ? "Store scenes, then drop them onto the timeline"
                     : (isCompact ? "Tap a scene below to drop it here"
                                  : "Drag a scene from below onto the timeline"))
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .padding(.leading, 10)
                    .frame(height: laneH, alignment: .leading)
            }
            ForEach(engine.sceneMarkers) { m in
                sceneMarkerChip(m, width: w)
            }
        }
        .frame(height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
        .clipped()
        #if os(macOS)
        return lane.dropDestination(for: String.self) { items, location in
            guard let name = items.first else { return false }
            engine.placeScene(name, at: frame(atX: location.x, width: w), linear: interpLinear)
            return true
        }
        #else
        return lane
        #endif
    }

    private func sceneMarkerChip(_ m: PyMOLEngine.SceneMarker, width w: CGFloat) -> some View {
        let dragging = dragItem == .scene(m.frame, m.name)
        let shownFrame = dragging ? dragToFrame : m.frame
        return HStack(spacing: 3) {
            Image(systemName: "photo.fill").font(.system(size: 7))
            Text(m.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(TimelineTheme.accent.opacity(dragging ? 0.95 : 0.7)))
        .foregroundColor(.black)
        .fixedSize()
        .scaleEffect(dragging ? 1.08 : 1)
        .position(x: clampX(xFor(shownFrame, width: w), width: w), y: laneH / 2)
        .gesture(reTimeDrag(width: w, item: { .scene(m.frame, m.name) },
                            commit: { to in engine.moveSceneMarker(m.name, from: m.frame, to: to, linear: interpLinear) }))
        .onTapGesture { engine.seek(to: m.frame) }
        .contextMenu {
            Text("Scene · \(m.name) · frame \(m.frame)")
            Button { engine.recallScene(m.name) } label: { Label("Recall now", systemImage: "eye") }
            Button(role: .destructive) {
                engine.deleteSceneMarker(at: m.frame, linear: interpLinear)
            } label: { Label("Remove from timeline", systemImage: "trash") }
        }
        .accessibilityLabel("Scene marker \(m.name) at frame \(m.frame)")
    }

    // Source palette of saved scenes. Tap to drop at the playhead (all platforms);
    // on macOS also draggable straight onto the Scenes lane at a time position.
    @ViewBuilder private var scenePaletteStrip: some View {
        if !engine.sceneNames.isEmpty {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "photo.stack").font(.system(size: 11)).foregroundColor(TimelineTheme.dim)
                    Text("Scenes").font(.system(size: isCompact ? 10 : 11)).foregroundColor(TimelineTheme.text)
                    Spacer(minLength: 0)
                }
                .frame(width: labelW)
                .padding(.horizontal, 8)

                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(engine.sceneNames, id: \.self) { name in
                            paletteChip(name)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .frame(height: 34)
            .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }

    private func paletteChip(_ name: String) -> some View {
        let chip = Text(name)
            .font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(engine.currentScene == name
                                       ? TimelineTheme.accent : Color.white.opacity(0.12)))
            .foregroundColor(engine.currentScene == name ? .black : TimelineTheme.text)
            .contentShape(Capsule())
            .onTapGesture { dropSceneAtPlayhead(name) }
            .contextMenu {
                Button { engine.recallScene(name) } label: { Label("Recall (preview)", systemImage: "eye") }
                Button { dropSceneAtPlayhead(name) } label: { Label("Add at playhead", systemImage: "plus") }
            }
        #if os(macOS)
        return chip.draggable(name)
        #else
        return chip
        #endif
    }

    private func dropSceneAtPlayhead(_ name: String) {
        if playback.frameCount <= 1 { engine.newTimeline(seconds: 10) }
        engine.placeScene(name, at: playback.currentFrame, linear: interpLinear)
    }

    private func playhead(width w: CGFloat) -> some View {
        let x = clampX(xFor(playback.currentFrame, width: w), width: w)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(TimelineTheme.accent)
                .frame(width: 2)
            Triangle()
                .fill(TimelineTheme.accent)
                .frame(width: 10, height: 7)
                .offset(y: -1)
        }
        .frame(width: 10, height: rulerH + laneH * 2, alignment: .top)
        .offset(x: x - 5)   // center the 10pt-wide head/line box on the frame x
        .allowsHitTesting(false)
    }

    // MARK: - Geometry / helpers

    private func xFor(_ frame: Int, width w: CGFloat) -> CGFloat {
        let count = max(playback.frameCount, 1)
        guard count > 1 else { return 0 }
        let f = min(max(frame, 1), count)
        return CGFloat(f - 1) / CGFloat(count - 1) * w
    }

    private func frame(atX x: CGFloat, width w: CGFloat) -> Int {
        let count = max(playback.frameCount, 1)
        guard w > 0, count > 1 else { return 1 }
        let frac = min(max(x / w, 0), 1)
        return Int((frac * CGFloat(count - 1)).rounded()) + 1
    }

    private func clampX(_ x: CGFloat, width w: CGFloat) -> CGFloat {
        min(max(x, 7), max(w - 7, 7))
    }

    private func timeLabel(_ frac: CGFloat) -> String {
        let fps = max(playback.movieFPS, 0.1)
        let secs = Double(max(playback.frameCount, 1) - 1) / fps * Double(frac)
        return secs >= 10 ? String(format: "%.0fs", secs) : String(format: "%.1fs", secs)
    }

    private func addKeyframe() {
        if playback.frameCount <= 1 { engine.newTimeline(seconds: 10) }
        engine.captureKeyframe(linear: interpLinear)
    }
}

// Small downward-pointing triangle for the playhead head.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
