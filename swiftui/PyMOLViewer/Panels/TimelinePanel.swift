// TimelinePanel.swift — the docked "movie studio" (Timeline mode).
//
// Promotes RayMol's linear frame transport into a composition editor (the PyMOL
// Timeline, adapted to touch + pointer). On iPhone it IS the Movie tab's content
// (the tab bar stays visible — switch tabs to leave, no Done needed); on iPad /
// macOS it docks below the viewport as an explicit mode (with a Done button).
// Reuses TransportBar for playback so the playhead IS the core frame.
//
// ONE unified lane holds both object kinds — camera keyframes (diamonds) and
// scene markers (chips) — on a FIXED-SCALE time ruler (default ~10 s across the
// viewport, zoomable with +/-, and horizontally SCROLLABLE for longer movies).
// Objects are joined by TRANSITIONS (duration + easing) drawn as labeled
// connectors. Editing is item-centric:
//   • ◆ / palette  → append a camera keyframe / scene marker to the end.
//   • tap the ruler → seek to that time;  tap an item → seek to it.
//   • long-press an item → recall / delete;  drag an item past a neighbor →
//     reorder (ripples the timing).
//   • long-press a transition connector → set its duration (preset) + Smooth/
//     Linear easing. Duration drives timing: movie length = Σ transitions.
// Swift owns the ordered list (engine.timelineItems); every edit rebuilds the
// core movie. Produce hands the result to MovieExportSheet.

import SwiftUI

struct TimelinePanel: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject var playback: PlaybackState

    /// Called when the user exits the mode (Done / close). Defaults to flipping
    /// engine.timelineMode so the caller can just drop `TimelinePanel()` in.
    var onExit: (() -> Void)? = nil
    /// Whether to show the Done button. False on iPhone, where the timeline is
    /// the Movie tab and the tab bar handles navigation.
    var showsDone: Bool = true
    /// When set, the header shows an Expand button that opens/collapses the
    /// full-width bottom dock (macOS / iPad right-panel compact view). The button
    /// reflects `engine.timelineMode` (dock open) as its active state.
    var onExpand: (() -> Void)? = nil
    /// Force the narrow (iPhone-style) layout even on macOS/iPad — used for the
    /// right-inspector instance so it fits the ~400pt column instead of rendering
    /// the wide desktop transport that overflows.
    var forceCompact: Bool = false
    /// Gray out (disable) the Expand button. The expanded full-width dock is
    /// landscape-only on iPad, so its entry point is disabled in portrait.
    var expandDisabled: Bool = false

    @State private var showClearConfirm = false
    // Export the authored movie — lives on the top bar (right of the trashcan) so
    // it's always visible in both the docked and expanded panel (issue #142).
    @State private var showExport = false

    // Horizontal zoom: pixels-per-second = (viewportWidth / 10) * zoom, so zoom
    // 1 fits ~10 s across the lane. +/- steps; the lane scrolls when the movie is
    // longer than the viewport.
    @State private var zoom: CGFloat = 1.0

    // Drag-to-reorder: while dragging an item we render it at `dragX` (live) and
    // commit the reorder on release.
    @State private var dragItemID: UUID? = nil
    @State private var dragX: CGFloat = 0

    // Long-press scene management (rename needs a text-entry alert).
    @State private var sceneRenameTarget: String? = nil
    @State private var sceneRenameText: String = ""

    // Template composer (preset builders, folded into the dock).
    @State private var composerKind = "roll"
    @State private var composerAxis = "y"
    @State private var composerDuration: Double = 8
    @State private var composerAngle: Double = 30
    @State private var composerSecPerScene: Double = 3
    @State private var composerStatesObject: String? = nil   // nil = all multi-state objects
    // "Play models" config modal (opened by Append).
    @State private var showStatesSheet = false
    @State private var sheetMode: PyMOLEngine.StatesMode = .sweep
    @State private var sheetFirst = 1
    @State private var sheetLast = 0            // 0 = through the last model
    @State private var sheetDuration: Double = 8

    // Scenes-palette overflow tracking → drives the horizontal-scroll edge fade
    // (issue #131). Set from GeometryReader preferences below.
    @State private var paletteContentW: CGFloat = 0
    @State private var paletteViewportW: CGFloat = 0

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { forceCompact || hSize == .compact }
    #else
    private var isCompact: Bool { forceCompact }
    #endif

    private let laneH: CGFloat = 56
    private let rulerH: CGFloat = 28
    private var labelW: CGFloat { isCompact ? 34 : 90 }   // wide enough for "Scenes" without wrapping
    private let laneSpace = "timelineLane"   // coord space for drag/tap -> frame
    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 8.0

    static let durationPresets: [Double] = [0.5, 1, 2, 5, 8]

    // A laid-out item: its model, order index, and computed timeline frame.
    private struct Laid: Identifiable {
        let item: PyMOLEngine.TimelineItem
        let index: Int
        let frame: Int        // start frame
        let endFrame: Int     // == frame for camera/scene; span end for a states clip
        var id: UUID { item.id }
    }
    private var laidOut: [Laid] {
        let spans = engine.itemSpans()
        return engine.timelineItems.enumerated().compactMap { i, it in
            spans.indices.contains(i)
                ? Laid(item: it, index: i, frame: spans[i].start, endFrame: spans[i].end)
                : nil
        }
    }

    // Symmetric edge-fade for a horizontal scroll region, applied as a `.mask`
    // (matches the floating scene-chip row in ContentView, issue #131). Unlike the
    // opaque trailing overlay above, a mask dissolves the CONTENT to true
    // transparency, so it reads correctly over the timeline's translucent chrome
    // regardless of the backing color AND cues the leading edge once the row has
    // been scrolled off its start. Pass `active` false when the row fits, so a
    // non-overflowing row is never clipped. The gradient runs leading→trailing;
    // masks don't hit-test, so scroll/scrub gestures are untouched.
    private func scrollFadeMask(_ active: Bool) -> LinearGradient {
        LinearGradient(
            stops: active
                ? [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.95),
                    .init(color: .clear, location: 1),
                  ]
                // Fully opaque (no fade) so a row that fits isn't clipped.
                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
            startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(TimelineTheme.accent.opacity(0.35)).frame(height: 1)
            tracksSection
            scenePaletteStrip
            // The transport plays ONLY the authored movie (decoupled from model
            // inspection, which lives in the Object panel). Visible but disabled
            // when the timeline is empty, with a hint on how to build a movie.
            Divider()
            TransportBar(forceCompact: isCompact, inTimeline: true,
                         movieFrames: engine.timelineTotalFrames)
                .disabled(engine.timelineItems.isEmpty)
                .opacity(engine.timelineItems.isEmpty ? 0.45 : 1)
                .help(engine.timelineItems.isEmpty
                      ? "Add a camera keyframe (◆), a scene, or a Play-models clip to build a movie"
                      : "Play the movie")
            Divider().opacity(0.5)
            composer
        }
        .background(TimelineTheme.bar)
        .sheet(isPresented: $showStatesSheet) { statesConfigSheet }
        .sheet(isPresented: $showExport) { MovieExportSheet() }
        .onAppear {
            // Test affordance: auto-open the "Play models" modal so it can be
            // screenshotted on the sim (simctl can't tap). PYMOL_AUTOSTATESHEET=1.
            if ProcessInfo.processInfo.environment["PYMOL_AUTOSTATESHEET"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    composerKind = "states"; showStatesSheet = true
                }
            }
        }
        .confirmationDialog("Clear the timeline?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear timeline", role: .destructive) { engine.clearMovieItems() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename scene", isPresented: Binding(
            get: { sceneRenameTarget != nil },
            set: { if !$0 { sceneRenameTarget = nil } })) {
            TextField("Scene name", text: $sceneRenameText)
            Button("Rename") {
                if let t = sceneRenameTarget { engine.renameScene(t, to: sceneRenameText) }
                sceneRenameTarget = nil
            }
            Button("Cancel", role: .cancel) { sceneRenameTarget = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: isCompact ? 5 : 10) {
            Image(systemName: "clapperboard.fill")
                .font(.system(size: 14))
                .foregroundColor(TimelineTheme.accent)
            if !isCompact {
                Text("Timeline")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TimelineTheme.text)
                    .lineLimit(1).fixedSize()
            }
            Text(lengthLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TimelineTheme.dim)
                .lineLimit(1).fixedSize()
                .lineLimit(1)

            Spacer(minLength: 4)

            addCameraButton
            zoomControl
            trashButton
            exportButton
            if onExpand != nil { expandButton }
            if showsDone { doneButton }
        }
        .padding(.horizontal, isCompact ? 8 : 12)
        .frame(height: 44)
    }

    // Add a camera keyframe of the current view — a plain accent diamond.
    private var addCameraButton: some View {
        Button(action: { engine.captureCameraItem() }) {
            Image(systemName: "plus.diamond.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.accent)
        .accessibilityLabel("Add a camera keyframe of the current view")
        .help("Add a camera keyframe of the current view to the end")
    }

    // Joined -/+ zoom stepper for the time ruler.
    private var zoomControl: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom / 1.6) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }
            .disabled(zoom <= minZoom * 1.001)
            Rectangle().fill(TimelineTheme.subtleFill).frame(width: 1, height: 18)
            Button { setZoom(zoom * 1.6) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 30).contentShape(Rectangle())
            }
            .disabled(zoom >= maxZoom * 0.999)
        }
        .buttonStyle(.plain)
        .foregroundColor(TimelineTheme.text)
        .background(Capsule().fill(TimelineTheme.subtleFill))
        .overlay(Capsule().stroke(TimelineTheme.subtleFill, lineWidth: 0.5))
        .accessibilityLabel("Zoom timeline")
        .help("Zoom the time ruler in / out")
    }

    private func setZoom(_ z: CGFloat) {
        withAnimation(.easeInOut(duration: 0.15)) {
            zoom = min(max(z, minZoom), maxZoom)
        }
    }

    // Clear the whole timeline (confirmed). Replaces the old overflow menu.
    private var trashButton: some View {
        Button { showClearConfirm = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 15))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(engine.timelineItems.isEmpty ? TimelineTheme.dim : TimelineTheme.text)
        .disabled(engine.timelineItems.isEmpty)
        .help("Clear the timeline")
        .accessibilityLabel("Clear timeline")
    }

    // Export the authored movie to a file (MP4 / GIF). Pinned to the top bar,
    // immediately right of the trashcan, so it's always visible in both the
    // docked and expanded panel (issue #142). Disabled on an empty timeline.
    private var exportButton: some View {
        Button { showExport = true } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15))
                .frame(width: 30, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(engine.timelineItems.isEmpty ? TimelineTheme.dim : TimelineTheme.text)
        .disabled(engine.timelineItems.isEmpty)
        .help("Export the movie to a file")
        .accessibilityLabel("Export movie")
    }

    // Open / collapse the full-width bottom dock (compact right-panel view only).
    // Active (accent) while the dock is open (engine.timelineMode).
    private var expandButton: some View {
        let open = engine.timelineMode
        return Button { onExpand?() } label: {
            Image(systemName: open ? "arrow.down.right.and.arrow.up.left"
                                   : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Capsule().fill(open ? TimelineTheme.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(open ? .white : TimelineTheme.text)
        .disabled(expandDisabled)
        .opacity(expandDisabled ? 0.35 : 1)
        .help(expandDisabled
              ? "Rotate to landscape to expand the timeline into a full editor"
              : (open ? "Collapse the full editor" : "Expand into a full editor at the bottom"))
        .accessibilityLabel(open ? "Collapse timeline editor" : "Expand timeline editor")
    }

    // The current movie length, from the sum of transition durations. (Multi-state
    // model inspection lives in the Object panel now — the timeline is authoring.)
    private var lengthLabel: String {
        guard !engine.timelineItems.isEmpty else { return "Empty" }
        let secs = Double(engine.timelineTotalFrames) / max(playback.movieFPS, 1)
        return secs >= 10 ? String(format: "%.0fs", secs) : String(format: "%.1fs", secs)
    }

    private var doneButton: some View {
        Button { (onExit ?? { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = false } })() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(TimelineTheme.accent)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close the timeline editor")
        .accessibilityLabel("Close timeline")
    }

    // MARK: - The unified lane (fixed-scale, scrollable)

    private var tracksSection: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerH)
                HStack(spacing: 6) {
                    Image(systemName: "film").font(.system(size: 13)).foregroundColor(TimelineTheme.accent)
                    if !isCompact {
                        Text("Track").font(.system(size: 11)).foregroundColor(TimelineTheme.text)
                            .lineLimit(1).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: laneH)
                .help("Camera keyframes + scene markers")
                .accessibilityLabel("Timeline track")
            }
            .frame(width: labelW)

            Rectangle().fill(TimelineTheme.subtleFill).frame(width: 1)

            GeometryReader { geo in
                let w = geo.size.width
                let pps = ppsFor(w)
                let cW = contentWidth(w, pps: pps)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ruler(contentW: cW, pps: pps)
                                itemLane(contentW: cW, pps: pps)
                            }
                            playhead(pps: pps)
                            // Invisible follow-anchor centered on the playhead.
                            Color.clear
                                .frame(width: 1, height: rulerH + laneH)
                                .position(x: xFor(playback.currentFrame, pps: pps), y: (rulerH + laneH) / 2)
                                .id("playhead")
                        }
                        .frame(width: cW, height: rulerH + laneH, alignment: .topLeading)
                        .coordinateSpace(name: laneSpace)
                    }
                    // (the seconds playhead is suppressed for a bare ensemble; the
                    // model band carries its own current-model marker)
                    // Bound the scroll view's own height — a horizontal ScrollView is
                    // otherwise vertically greedy and would absorb the panel's slack,
                    // opening gaps above the ruler / below the lane.
                    .frame(height: rulerH + laneH)
                    // Symmetric edge-fade when the lane is longer than the viewport,
                    // so it's obvious the track scrolls horizontally (issue #131) —
                    // trailing at rest, leading too once scrolled off the start.
                    .mask(scrollFadeMask(cW > w + 1))
                    // Follow the playhead during playback (don't fight manual scroll).
                    .onChange(of: playback.currentFrame) { _ in
                        if playback.isPlaying {
                            withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("playhead", anchor: .center) }
                        }
                    }
                }
            }
            .frame(height: rulerH + laneH)
        }
        // Bound the whole track row — the gutter VStack + divider are otherwise
        // vertically greedy and, in a taller pane, would center the ruler/lane
        // inside an over-tall region (empty bands above/below).
        .frame(height: rulerH + laneH)
    }

    // Tick ruler across the whole (scrollable) content width. Tap to seek.
    private func ruler(contentW: CGFloat, pps: CGFloat) -> some View {
        let step = tickStep(pps: pps)
        let count = max(1, Int((Double(contentW / pps) / step).rounded(.up)))
        return ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.white.opacity(0.03))
            ForEach(0...count, id: \.self) { i in
                let t = Double(i) * step
                let x = CGFloat(t) * pps
                if x <= contentW + 1 {
                    Rectangle().fill(TimelineTheme.dim.opacity(0.5))
                        .frame(width: 1, height: 5)
                        .position(x: x, y: rulerH - 3)
                    Text(tickLabel(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TimelineTheme.dim)
                        .fixedSize()
                        .position(x: x + (i == 0 ? 12 : 0), y: rulerH - 14)
                }
            }
        }
        .frame(width: contentW, height: rulerH)
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        // Drag the playhead: live-sync the viewport on every change (scrub drives
        // the core frame immediately), commit + release the scrub lock on end. A
        // zero-distance drag doubles as a tap-to-seek. minimumDistance 0 so the
        // first touch already positions the playhead (no dead zone before drag).
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(laneSpace))
                .onChanged { g in engine.scrub(to: frame(atX: g.location.x, pps: pps)) }
                .onEnded { _ in engine.endScrub() }
        )
    }

    @ViewBuilder
    private func itemLane(contentW: CGFloat, pps: CGFloat) -> some View {
        let items = laidOut
        ZStack(alignment: .topLeading) {
            Rectangle().fill(TimelineTheme.accent.opacity(0.05))
            if items.isEmpty {
                Text("Tap ◆ to add a camera keyframe, or a scene below")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .padding(.leading, 10)
                    .frame(height: laneH, alignment: .leading)
            } else {
                ForEach(items.dropFirst()) { laid in
                    connectorIfSequential(laid, items, pps: pps)
                }
                ForEach(items) { laid in
                    itemNode(laid, pps: pps)
                }
            }
        }
        .frame(width: contentW, height: laneH)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    // A connector only bridges two consecutive SEQUENTIAL items (the transition
    // bar). Frame-anchored items (a camera dropped inside a states clip) are off
    // the sequential chain, so they get no connector.
    @ViewBuilder
    private func connectorIfSequential(_ laid: Laid, _ items: [Laid], pps: CGFloat) -> some View {
        let prevAnchored = items[laid.index - 1].item.atFrame != nil
        if laid.item.atFrame == nil && !prevAnchored {
            connector(laid,
                      prevX: xFor(items[laid.index - 1].frame, pps: pps),
                      curX: xFor(laid.frame, pps: pps))
        }
    }

    // The transition INTO `laid.item` (the gap from the previous item), shown as
    // a bar with its duration; long-press to reconfigure duration + easing.
    private func connector(_ laid: Laid, prevX: CGFloat, curX: CGFloat) -> some View {
        let midX = (prevX + curX) / 2
        let wid = max(curX - prevX, 1)
        let linear = laid.item.transition.linear
        return ZStack {
            Capsule()
                .fill(TimelineTheme.accent.opacity(linear ? 0.18 : 0.28))
                .frame(width: wid, height: 3)
            Text(fmtSeconds(laid.item.transition.seconds))
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(TimelineTheme.bar))
                .overlay(Capsule().stroke(TimelineTheme.accent.opacity(linear ? 0.3 : 0.6),
                                          style: StrokeStyle(lineWidth: 0.75, dash: linear ? [2, 2] : [])))
                .foregroundColor(linear ? TimelineTheme.dim : TimelineTheme.accent)
        }
        .frame(width: max(wid, 34), height: laneH)
        .contentShape(Rectangle())
        .position(x: midX, y: laneH / 2)
        .contextMenu { transitionMenu(laid.item) }
        .help("Transition · \(fmtSeconds(laid.item.transition.seconds)) · \(linear ? "Linear" : "Smooth") — right-click to adjust duration & easing")
        .accessibilityLabel("Transition \(fmtSeconds(laid.item.transition.seconds)) \(linear ? "linear" : "smooth")")
    }

    @ViewBuilder
    private func transitionMenu(_ item: PyMOLEngine.TimelineItem) -> some View {
        Text("Transition · \(fmtSeconds(item.transition.seconds)) · \(item.transition.linear ? "Linear" : "Smooth")")
        Menu("Duration") {
            ForEach(TimelinePanel.durationPresets, id: \.self) { d in
                Button {
                    engine.setTransition(item.id, seconds: d, linear: item.transition.linear)
                } label: {
                    Label(fmtSeconds(d), systemImage: item.transition.seconds == d ? "checkmark" : "clock")
                }
            }
        }
        Button {
            engine.setTransition(item.id, seconds: item.transition.seconds, linear: false)
        } label: { Label("Smooth", systemImage: item.transition.linear ? "circle" : "checkmark") }
        Button {
            engine.setTransition(item.id, seconds: item.transition.seconds, linear: true)
        } label: { Label("Linear", systemImage: item.transition.linear ? "checkmark" : "circle") }
    }

    // A camera keyframe (diamond) or scene marker (chip) at its timeline frame.
    private func itemNode(_ laid: Laid, pps: CGFloat) -> some View {
        let dragging = dragItemID == laid.item.id
        let startX = dragging ? dragX : xFor(laid.frame, pps: pps)
        let w = nodeHitWidth(laid, pps: pps)
        // A states clip is a BLOCK: left edge at its start frame (center = start+w/2).
        // Camera/scene are points centered on their frame.
        let isStates: Bool = { if case .states = laid.item.kind { return true } else { return false } }()
        let cx = isStates ? startX + w / 2 : startX
        return Group {
            switch laid.item.kind {
            case .camera:
                cameraNode(laid, current: laid.frame == playback.currentFrame)
            case .scene(let name):
                sceneNode(name)
            case .states(let spec):
                statesNode(laid, spec: spec, pps: pps)
            }
        }
        .scaleEffect(dragging ? 1.25 : 1)
        .frame(width: w, height: laneH)
        .contentShape(Rectangle())
        .position(x: max(cx, 7), y: laneH / 2)
        // highPriority so a drag on an item reorders instead of scrolling the lane.
        .highPriorityGesture(reorderDrag(laid, pps: pps))
        .onTapGesture { engine.seekToItem(laid.item.id) }
        .contextMenu { itemMenu(laid) }
    }

    private func cameraNode(_ laid: Laid, current: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(current ? TimelineTheme.text : TimelineTheme.accent)
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(45))
            .shadow(color: .black.opacity(0.4), radius: 0.5)
            .accessibilityLabel("Camera keyframe \(laid.index + 1)")
    }

    private func sceneNode(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "photo.fill").font(.system(size: 7))
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(TimelineTheme.accent.opacity(0.75)))
        .foregroundColor(.black)
        .fixedSize()
        .accessibilityLabel("Scene marker \(name)")
    }

    private func nodeHitWidth(_ laid: Laid, pps: CGFloat) -> CGFloat {
        if case .states = laid.item.kind {
            return max(30, xFor(laid.endFrame, pps: pps) - xFor(laid.frame, pps: pps))
        }
        if case .scene = laid.item.kind { return 88 }
        return 30
    }

    // A "Play models" ensemble clip: a block spanning its duration with a few
    // decimated guide ticks (never one per model — a 2000-frame MD stays a block).
    private func statesNode(_ laid: Laid, spec: PyMOLEngine.StatesSpec, pps: CGFloat) -> some View {
        let w = max(30, xFor(laid.endFrame, pps: pps) - xFor(laid.frame, pps: pps))
        let who: String = spec.objects.map {
            $0.count == 1 ? $0[0] : "\($0.count) objects"
        } ?? "\(engine.maxStateCount) models"
        // Show the model range only when it's a subset (e.g. "3–7").
        let rangeSuffix = (spec.firstModel > 1 || (spec.lastModel > 0 && spec.lastModel < engine.maxStateCount))
            ? " \(spec.firstModel)–\(spec.lastModel > 0 ? spec.lastModel : engine.maxStateCount)" : ""
        let label = who + rangeSuffix
        return RoundedRectangle(cornerRadius: 4)
            .fill(TimelineTheme.accent.opacity(0.10))     // discreet — blends with the lane
            .overlay(
                HStack(spacing: 0) {   // ≤ 10 faint guide ticks
                    ForEach(0..<10, id: \.self) { i in
                        if i > 0 { Rectangle().fill(TimelineTheme.accent.opacity(0.18)).frame(width: 1) }
                        Spacer(minLength: 0)
                    }
                }
            )
            .overlay(
                HStack(spacing: 3) {
                    Image(systemName: spec.mode == .loop ? "repeat" : "film.stack").font(.system(size: 8))
                    Text(label).font(.system(size: 10, weight: .medium)).lineLimit(1)
                }
                .foregroundColor(TimelineTheme.text.opacity(0.85))
                .padding(.horizontal, 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(TimelineTheme.accent.opacity(0.45), lineWidth: 0.75))
            .frame(width: w, height: laneH - 16)
            .accessibilityLabel("Play models clip \(label)")
    }

    private func itemMenu(_ laid: Laid) -> some View {
        Group {
            switch laid.item.kind {
            case .camera:
                Text("Camera keyframe \(laid.index + 1) · frame \(laid.frame)")
                Button { engine.seekToItem(laid.item.id) } label: { Label("Go to", systemImage: "arrow.right.to.line") }
                Button(role: .destructive) { engine.deleteItem(laid.item.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            case .scene(let name):
                Text("Scene · \(name) · frame \(laid.frame)")
                Button { engine.recallScene(name) } label: { Label("Recall (preview)", systemImage: "eye") }
                Button(role: .destructive) { engine.deleteItem(laid.item.id) } label: {
                    Label("Remove from timeline", systemImage: "trash")
                }
            case .states(let spec):
                Text("Play models · \(spec.objects?.count.description ?? "all") · frame \(laid.frame)")
                Menu("Motion") {
                    ForEach([PyMOLEngine.StatesMode.sweep, .loop, .lockstep], id: \.self) { m in
                        Button {
                            engine.updateStatesClip(laid.item.id, PyMOLEngine.StatesSpec(
                                objects: spec.objects, mode: m,
                                firstModel: spec.firstModel, lastModel: spec.lastModel,
                                durationSeconds: spec.durationSeconds))
                        } label: { Label(m.rawValue.capitalized, systemImage: spec.mode == m ? "checkmark" : "circle") }
                    }
                }
                Menu("Duration") {
                    ForEach([2.0, 4.0, 8.0, 12.0], id: \.self) { d in
                        Button {
                            engine.updateStatesClip(laid.item.id, PyMOLEngine.StatesSpec(
                                objects: spec.objects, mode: spec.mode,
                                firstModel: spec.firstModel, lastModel: spec.lastModel,
                                durationSeconds: d))
                        } label: { Label("\(Int(d)) s", systemImage: spec.durationSeconds == d ? "checkmark" : "clock") }
                    }
                }
                Button(role: .destructive) { engine.deleteItem(laid.item.id) } label: {
                    Label("Remove from timeline", systemImage: "trash")
                }
            }
        }
    }

    // Drag an item past a neighbor to reorder. Live x tracked in the lane space;
    // on release the target index = # of other items sitting left of the drop.
    private func reorderDrag(_ laid: Laid, pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(laneSpace))
            .onChanged { g in
                if dragItemID == nil { dragItemID = laid.item.id }
                dragX = g.location.x
            }
            .onEnded { _ in
                let dropX = dragX
                dragItemID = nil
                if laid.item.atFrame != nil {
                    // Frame-anchored (camera inside a clip): drag re-times it.
                    engine.setItemAtFrame(laid.item.id, frame(atX: dropX, pps: pps))
                } else {
                    let others = engine.itemFrames().enumerated().filter { $0.offset != laid.index }
                    let target = others.filter { xFor($0.element, pps: pps) < dropX }.count
                    engine.moveItem(from: laid.index, to: target)
                }
            }
    }

    // MARK: - Scene palette (source)

    // Always on screen (even with no saved scenes) so the "drop a scene" affordance
    // is discoverable; shows a hint until scenes exist.
    private var scenePaletteStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack").font(.system(size: 13)).foregroundColor(TimelineTheme.dim)
                if !isCompact {
                    Text("Scenes").font(.system(size: 11)).foregroundColor(TimelineTheme.text)
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: labelW)   // match the track gutter (padding INSIDE) so the divider lines align
            .help("Saved scenes — tap to append to the timeline")
            .accessibilityLabel("Saved scenes")

            Rectangle().fill(TimelineTheme.subtleFill).frame(width: 1)

            if engine.sceneNames.isEmpty {
                Text("Store a scene to drop it onto the timeline")
                    .font(.system(size: 10))
                    .foregroundColor(TimelineTheme.dim)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(engine.sceneNames, id: \.self) { name in
                            paletteChip(name)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(GeometryReader { c in
                        Color.clear.preference(key: PaletteContentWKey.self, value: c.size.width)
                    })
                }
                // Symmetric edge-fade when the chips overflow the row, so it's
                // obvious the scenes palette scrolls horizontally (issue #131) —
                // mirrors the floating scene-chip row's mask in ContentView.
                .background(GeometryReader { v in
                    Color.clear.preference(key: PaletteViewportWKey.self, value: v.size.width)
                })
                .mask(scrollFadeMask(paletteContentW > paletteViewportW + 1))
                .onPreferenceChange(PaletteContentWKey.self) { paletteContentW = $0 }
                .onPreferenceChange(PaletteViewportWKey.self) { paletteViewportW = $0 }
            }
        }
        .frame(height: 40)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }

    private func paletteChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(engine.currentScene == name
                                       ? TimelineTheme.accent : TimelineTheme.subtleFill))
            .foregroundColor(engine.currentScene == name ? .black : TimelineTheme.text)
            .contentShape(Capsule())
            .onTapGesture { engine.appendSceneItem(name) }
            .contextMenu {
                Text(name)
                Button { engine.recallScene(name) } label: { Label("Recall (preview)", systemImage: "eye") }
                Button { engine.appendSceneItem(name) } label: { Label("Add to timeline", systemImage: "plus") }
                Divider()
                Button { engine.updateScene(name) } label: { Label("Reset to current view", systemImage: "arrow.clockwise") }
                Button { sceneRenameText = name; sceneRenameTarget = name } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { engine.deleteScene(name) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    // MARK: - Template composer (folded-in preset builders → Append)
    //
    // Chips + Append lay out on one row where the panel is wide enough; on the
    // narrow docked column (~400pt) they wrap — the chips scroll horizontally on
    // their own line above a full-width Append — so nothing clips (#143).

    private var composer: some View {
        ViewThatFits(in: .horizontal) {
            // Wide: chips + Append share one row, Append pinned on the right.
            HStack(spacing: 8) {
                composerChips
                appendButton
            }
            // Narrow: chips scroll on their own line above a full-width Append so
            // the last parameter (e.g. Duration) is never clipped behind Append.
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    composerChips.padding(.trailing, 4)
                }
                appendButton.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // The parameter chips for the current preset. `.fixedSize()` so ViewThatFits
    // measures their true (un-truncated) width when deciding row vs. wrap.
    private var composerChips: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Camera Roll") { composerKind = "roll" }
                Button("Camera Rock") { composerKind = "rock" }
                Button("Scene loop")  { composerKind = "scenes" }
                // Only meaningful when a multi-state object (NMR/MD) is loaded.
                if engine.maxStateCount > 1 {
                    Button("Play models") { composerKind = "states" }
                }
            } label: { composerChip(composerLabel, composerIcon) }
            .help("Motion preset to append")

            if composerKind == "states" {
                // Just pick which object(s); mode / range / duration are set
                // in the modal opened by Append.
                Menu {
                    Button("All models") { composerStatesObject = nil }
                    ForEach(engine.multiStateObjects(), id: \.name) { o in
                        Button("\(o.name) · \(o.count)") { composerStatesObject = o.name }
                    }
                } label: { composerChip(composerStatesObject ?? "All", "cube.box") }
                .help("Which object(s) to play through their models")
            } else if composerKind == "roll" || composerKind == "rock" {
                Menu {
                    ForEach(["x", "y", "z"], id: \.self) { a in
                        Button(a.uppercased()) { composerAxis = a }
                    }
                } label: { composerChip(composerAxis.uppercased(), "arrow.triangle.2.circlepath") }
                .help("Rotation axis")
                Menu {
                    ForEach([4, 8, 16], id: \.self) { s in Button("\(s) s") { composerDuration = Double(s) } }
                } label: { composerChip("\(Int(composerDuration))s", "clock") }
                .help("Duration of the motion")
                if composerKind == "rock" {
                    Menu {
                        ForEach([30, 60, 90], id: \.self) { a in Button("\(a)°") { composerAngle = Double(a) } }
                    } label: { composerChip("\(Int(composerAngle))°", "angle") }
                    .help("Rock angle (± degrees)")
                }
            } else if composerKind == "scenes" {
                Menu {
                    ForEach([2, 3, 5], id: \.self) { s in Button("\(s) s / scene") { composerSecPerScene = Double(s) } }
                } label: { composerChip("\(Int(composerSecPerScene))s", "clock") }
                .help("Seconds per scene")
            }
        }
        .padding(.vertical, 1)
    }

    private var appendButton: some View {
        Button(action: appendComposer) {
            Label("Append", systemImage: "plus.rectangle.on.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.borderedProminent)
        .tint(TimelineTheme.accent)
        .help("Append this motion to the end of the timeline")
        .disabled(composerKind == "scenes" && engine.sceneNames.isEmpty)
    }

    private func composerChip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8))
        }
        .font(.system(size: 12))
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(TimelineTheme.subtleFill))
        .foregroundColor(TimelineTheme.text)
    }

    // Short chip labels (the video/photo icon conveys "camera") so all of Rock's
    // options — axis, duration, angle — fit without clipping. Full names live in
    // the dropdown menu.
    private var composerLabel: String {
        switch composerKind {
        case "rock": return "Rock"
        case "scenes": return "Scenes"
        case "states": return "Models"
        default: return "Roll"
        }
    }

    private var composerIcon: String {
        switch composerKind {
        case "scenes": return "photo.stack"
        case "states": return "film.stack"
        default: return "video"
        }
    }

    private func appendComposer() {
        switch composerKind {
        case "roll", "rock":
            engine.appendCameraTemplate(kind: composerKind, duration: composerDuration,
                                        axis: composerAxis, angle: composerAngle)
        case "scenes":
            engine.appendScenesTemplate(secondsPerScene: composerSecPerScene)
        case "states":
            // Open the config modal (mode / model range / duration).
            let n = composerStatesObject
                .flatMap { name in engine.multiStateObjects().first { $0.name == name }?.count }
                ?? engine.maxStateCount
            sheetMode = .sweep; sheetFirst = 1; sheetLast = max(2, n); sheetDuration = 8
            showStatesSheet = true
        default: break
        }
    }

    // "Play models" configuration modal. Objects come from the composer dropdown;
    // here the user picks the motion, the model range, and the duration.
    private var statesConfigSheet: some View {
        let n = composerStatesObject
            .flatMap { name in engine.multiStateObjects().first { $0.name == name }?.count }
            ?? engine.maxStateCount
        let target = composerStatesObject ?? "all models"
        // Resolve to a valid range regardless of prior state (0/out-of-range → 1…N),
        // and drive both the steppers and Add from the resolved values.
        let last = (sheetLast < 1 || sheetLast > n) ? n : sheetLast
        let first = min(max(sheetFirst, 1), last)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Play models").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(target) · \(n) models").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            // Motion — a segmented control (no wide dropdown).
            Picker("", selection: $sheetMode) {
                Text("Sweep").tag(PyMOLEngine.StatesMode.sweep)
                Text("Loop").tag(PyMOLEngine.StatesMode.loop)
                Text("Lockstep").tag(PyMOLEngine.StatesMode.lockstep)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Range + duration: one row where it fits (macOS/iPad), wrapping to two
            // rows on a narrow phone (iOS steppers are wider than macOS controls).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    rangeStart(first, last, n); rangeEnd(first, last, n); rangeDuration()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 18) { rangeStart(first, last, n); rangeEnd(first, last, n) }
                    rangeDuration()
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { showStatesSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    engine.appendStatesClip(
                        objects: composerStatesObject.map { [$0] },
                        mode: sheetMode, firstModel: first, lastModel: last,
                        seconds: sheetDuration)
                    showStatesSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 400)
        #else
        .presentationDetents([.height(300)])
        #endif
    }

    // Steppers for the "Play models" modal — reused in the one-row and wrapped
    // (narrow-phone) layouts so both stay in sync.
    @ViewBuilder private func rangeStart(_ first: Int, _ last: Int, _ n: Int) -> some View {
        Stepper("Start \(first)",
                value: Binding(get: { first }, set: { sheetFirst = min($0, last) }),
                in: 1...max(1, n)).fixedSize()
    }
    @ViewBuilder private func rangeEnd(_ first: Int, _ last: Int, _ n: Int) -> some View {
        Stepper("End \(last)",
                value: Binding(get: { last }, set: { sheetLast = max($0, first) }),
                in: 1...max(1, n)).fixedSize()
    }
    @ViewBuilder private func rangeDuration() -> some View {
        Stepper("\(String(format: "%.0f", sheetDuration)) s",
                value: $sheetDuration, in: 1...30, step: 1).fixedSize()
    }

    // MARK: - Playhead / geometry helpers

    private func playhead(pps: CGFloat) -> some View {
        let x = xFor(playback.currentFrame, pps: pps)
        return ZStack(alignment: .top) {
            Rectangle().fill(TimelineTheme.accent).frame(width: 2)
            Triangle().fill(TimelineTheme.accent).frame(width: 10, height: 7).offset(y: -1)
        }
        .frame(width: 10, height: rulerH + laneH, alignment: .top)
        .position(x: max(x, 1), y: (rulerH + laneH) / 2)
        .allowsHitTesting(false)
    }

    // pixels-per-second: zoom 1 fits ~10 s across the viewport.
    private func ppsFor(_ w: CGFloat) -> CGFloat { max(w, 1) / 10 * zoom }

    private var durationSeconds: Double {
        Double(max(engine.timelineTotalFrames - 1, 0)) / max(playback.movieFPS, 1)
    }

    // Content spans the movie, but never less than the viewport (so a short movie
    // still shows a full ruler); a little end pad keeps the last item off the edge.
    private func contentWidth(_ w: CGFloat, pps: CGFloat) -> CGFloat {
        max(w, CGFloat(durationSeconds) * pps + 24)
    }

    private func xFor(_ frame: Int, pps: CGFloat) -> CGFloat {
        let fps = max(playback.movieFPS, 1)
        return CGFloat(max(frame - 1, 0)) / CGFloat(fps) * pps
    }

    private func frame(atX x: CGFloat, pps: CGFloat) -> Int {
        let fps = max(playback.movieFPS, 1)
        let total = max(playback.frameCount, 1)
        let f = 1 + Int((max(x, 0) / pps * CGFloat(fps)).rounded())
        return min(max(f, 1), total)
    }

    // Tick spacing: smallest "nice" step whose on-screen width is >= ~55pt.
    private func tickStep(pps: CGFloat) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for c in candidates where CGFloat(c) * pps >= 55 { return c }
        return candidates.last!
    }

    private func tickLabel(_ t: Double) -> String {
        if t < 1 && t > 0 { return String(format: "%.1fs", t) }
        return "\(Int(t))s"
    }

    private func fmtSeconds(_ s: Double) -> String {
        if s < 1 { return String(format: "%.1fs", s) }
        return s.rounded() == s ? "\(Int(s))s" : String(format: "%.1fs", s)
    }
}

// Scenes-palette width measurement for the horizontal-scroll edge fade (#131):
// content width vs. viewport width decide whether the trailing fade shows.
private struct PaletteContentWKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct PaletteViewportWKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
