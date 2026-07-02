// TransportBar.swift — the unified Timeline transport for states, NMR models,
// trajectory frames and movie frames (all one cmd.frame index in PyMOL).
//
// Familiar desktop VCR transport (|< < play/pause > >|) + a scrubber bound to
// the core frame, a frame counter, a loop toggle, and an overflow menu (FPS,
// show frame rate, Make Movie…, Export Movie…). Playback is core-driven
// (engine.play()/pause() → cmd.mplay/mstop, advanced by the renderer idle tick);
// the bar only scrubs and reflects state. Auto-hidden when there is nothing to
// play (frameCount <= 1) — the caller gates that.
//
// Adaptive: one row on macOS / regular-width iPad; a 1-line "peek" that expands
// to a multi-row control on compact-width iPhone.

import SwiftUI

enum TimelineTheme {
    // Accent for transport / movie / scene controls — follows the ACTIVE THEME's
    // accent (so Build & Play, scene icons, chips, etc. match the rest of the app)
    // rather than a fixed teal. Mirrors SequencePanel's `ThemeManager.shared.active`
    // read. Views that should recolor live on a theme switch already observe
    // ThemeManager; others pick it up on their next render.
    static var accent: Color { ThemeManager.shared.active.accent.color }
    static let bar = Color(.sRGB, red: 0.10, green: 0.11, blue: 0.12, opacity: 0.96)
    static let text = Color(white: 0.88)
    static let dim = Color(white: 0.55)
}

struct TransportBar: View {
    @EnvironmentObject var engine: PyMOLEngine
    // Observe the isolated playback object so frame ticks re-render ONLY this
    // bar (not the inspector/menus, which observe `engine`).
    @EnvironmentObject var playback: PlaybackState

    /// iPhone collapsed state: render the 1-line peek instead of the full bar.
    var compactPeek: Bool = false
    /// Called when the user taps the expand/collapse chevron (iPhone only).
    var onToggleExpand: (() -> Void)? = nil

    @State private var showBuilder = false
    @State private var showExport = false

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private var isCompact: Bool { hSize == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    var body: some View {
        Group {
            if compactPeek {
                peekRow
            } else if isCompact {
                compactFull
            } else {
                regularRow
            }
        }
        .background(TimelineTheme.bar)
        .sheet(isPresented: $showBuilder) { MovieBuilderSheet() }
        .sheet(isPresented: $showExport) { MovieExportSheet() }
    }

    // MARK: - Layouts

    // macOS / regular-width iPad: everything on one line.
    private var regularRow: some View {
        HStack(spacing: 10) {
            transportCluster
            // Timeline mode: the ruler scrubs, so the slider is redundant here.
            if !engine.timelineMode { scrubber }
            counter
            loopButton
            overflowMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    // iPhone expanded: compact rows so 44pt targets all fit. In Timeline mode the
    // ruler is the scrub strip and the panel header owns Templates/Produce, so the
    // scrubber row and Make/Export are dropped here (they'd be redundant) — leaving
    // a tight cluster+counter row and a loop/fps row.
    private var compactFull: some View {
        VStack(spacing: 6) {
            HStack {
                transportCluster
                Spacer(minLength: 0)
                counter
                if let toggle = onToggleExpand {
                    iconButton("chevron.down", size: 16, action: toggle)
                        .accessibilityLabel("Collapse transport")
                }
            }
            if !engine.timelineMode {
                scrubber
            }
            HStack(spacing: 16) {
                loopButton
                fpsMenu
                Spacer(minLength: 0)
                if !engine.timelineMode {
                    Button { showBuilder = true } label: {
                        Label("Make", systemImage: "wand.and.stars").font(.system(size: 12))
                    }
                    Button { showExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 12))
                    }
                }
            }
            .tint(TimelineTheme.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // iPhone collapsed peek: scrub + play in one line, plus an expand chevron.
    private var peekRow: some View {
        HStack(spacing: 10) {
            playPauseButton(size: 20)
            scrubber
            counter
            iconButton("chevron.up", size: 16) { onToggleExpand?() }
                .accessibilityLabel("Expand transport")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    // MARK: - Pieces

    private var transportCluster: some View {
        HStack(spacing: 2) {
            iconButton("backward.end.fill", size: 15) { engine.rewindMovie() }
                .accessibilityLabel("Rewind to start")
            iconButton("backward.fill", size: 15) { engine.stepBackward() }
                .accessibilityLabel("Step back")
            playPauseButton(size: 20)
            iconButton("forward.fill", size: 15) { engine.stepForward() }
                .accessibilityLabel("Step forward")
            iconButton("forward.end.fill", size: 15) { engine.endingMovie() }
                .accessibilityLabel("Go to end")
        }
    }

    private func playPauseButton(size: CGFloat) -> some View {
        Button(action: { engine.togglePlay() }) {
            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(TimelineTheme.accent)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
    }

    private var scrubber: some View {
        Slider(
            value: Binding(
                get: { Double(min(max(playback.currentFrame, 1), max(playback.frameCount, 1))) },
                set: { engine.scrub(to: Int($0.rounded())) }
            ),
            in: 1...Double(max(playback.frameCount, 2)),
            step: 1,
            onEditingChanged: { editing in if !editing { engine.endScrub() } }
        )
        .tint(TimelineTheme.accent)
        .frame(minWidth: 80)
    }

    private var counter: some View {
        Text("\(playback.currentFrame) / \(playback.frameCount)")
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(TimelineTheme.text)
            .lineLimit(1)
            .fixedSize()
    }

    private var loopButton: some View {
        Button(action: { engine.setMovieLoop(!playback.movieLoop) }) {
            Image(systemName: "repeat")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(playback.movieLoop ? TimelineTheme.accent : TimelineTheme.dim)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playback.movieLoop ? "Looping on" : "Looping off")
    }

    private var fpsMenu: some View {
        Menu {
            Picker("Frame rate", selection: Binding(
                get: { playback.movieFPS },
                set: { engine.setMovieFPS($0) })) {
                Text("30 fps").tag(30.0)
                Text("15 fps").tag(15.0)
                Text("5 fps").tag(5.0)
                Text("1 fps").tag(1.0)
                Text("0.3 fps").tag(0.3)
            }
        } label: {
            Label("\(fpsLabel) fps", systemImage: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12))
        }
        .tint(TimelineTheme.accent)
    }

    private var overflowMenu: some View {
        Menu {
            Picker("Frame rate", selection: Binding(
                get: { playback.movieFPS },
                set: { engine.setMovieFPS($0) })) {
                Text("30 fps").tag(30.0)
                Text("15 fps").tag(15.0)
                Text("5 fps").tag(5.0)
                Text("1 fps").tag(1.0)
                Text("0.3 fps").tag(0.3)
            }
            Button { engine.setShowFrameRate(true) } label: {
                Label("Show frame rate", systemImage: "speedometer")
            }
            Divider()
            Button { showBuilder = true } label: {
                Label("Make Movie…", systemImage: "wand.and.stars")
            }
            Button { showExport = true } label: {
                Label("Export Movie…", systemImage: "square.and.arrow.up")
            }
            // Accelerator into the full timeline editor (proposal B). Hidden while
            // already in timeline mode (this bar is embedded there).
            if !engine.timelineMode {
                Divider()
                Button { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = true } } label: {
                    Label("Edit in Timeline", systemImage: "clapperboard")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundColor(TimelineTheme.text)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
    }

    private var fpsLabel: String {
        let f = playback.movieFPS
        return f == f.rounded() ? String(Int(f)) : String(format: "%.1f", f)
    }

    private func iconButton(_ systemName: String, size: CGFloat,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(TimelineTheme.text)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
