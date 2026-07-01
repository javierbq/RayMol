// MovieBuilderSheet.swift — author camera / state / scene-loop movies (the
// desktop "Movie ▸ Program" builders), native and neutral-labeled. Writes
// mset/mview via appkit_movie.make_movie and plays the result on the TransportBar.
//
// The controls live in the reusable MovieBuilderControls view so they can be
// embedded both in this sheet (transport overflow · SceneCard "Scene loop →")
// and inline in the Movie content tab (MoviePane).

import SwiftUI

// MARK: - Reusable controls

struct MovieBuilderControls: View {
    @EnvironmentObject var engine: PyMOLEngine

    /// Which tab to open on (SceneCard "Scene loop →" opens .scenes).
    var initialTab: Tab = .camera
    /// Called after a successful Build (the sheet dismisses; the pane no-ops).
    var onBuilt: (() -> Void)? = nil

    enum Tab: String, CaseIterable, Identifiable {
        case camera = "Camera", states = "States", scenes = "Scenes"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .camera

    // Camera
    enum CameraMotion: String, CaseIterable, Identifiable {
        case roll = "Roll", rock = "Rock", nutate = "Nutate"
        var id: String { rawValue }
        var kind: String { rawValue.lowercased() }
        var needsAngle: Bool { self != .roll }
    }
    @State private var motion: CameraMotion = .roll
    @State private var axis: String = "y"
    @State private var duration: Double = 8
    @State private var angle: Double = 30
    @State private var cameraLoop = true

    // States
    enum StateMode: String, CaseIterable, Identifiable {
        case loop = "Loop", sweep = "Sweep"
        var id: String { rawValue }
    }
    @State private var stateMode: StateMode = .loop
    @State private var speedFactor = 1          // 1× / ½× / ¼× / ⅛× → 1,2,4,8
    @State private var statePause: Double = 1
    @State private var stateLoop = true

    // Scenes
    @State private var selectedScenes: Set<String> = []
    @State private var sceneSeconds: Double = 4
    @State private var sceneLoop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            // Fixed-height content area so Build & Play sits at the SAME spot for
            // every tab. Kept tight (single dropdown row + toggle + caption) so the
            // whole builder — including Build & Play — fits the short landscape panel.
            Group {
                switch tab {
                case .camera: cameraTab
                case .states: statesTab
                case .scenes: scenesTab
                }
            }
            .frame(height: 116, alignment: .top)

            Divider()
            commonActions

            Button(action: build) {
                Label("Build & Play", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(TimelineTheme.accent)
        }
        .onAppear { tab = initialTab }
    }

    // MARK: Tabs

    private var cameraTab: some View {
        // All four controls on one row (compact dropdowns) so the builder stays
        // short enough that Build & Play fits the landscape panel.
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 8) {
                menuPicker("Motion", $motion, CameraMotion.allCases.map { ($0.rawValue, $0) })
                menuPicker("Axis", $axis, [("X", "x"), ("Y", "y"), ("Z", "z")])
                menuPicker("Duration", $duration, [("4 s", 4), ("8 s", 8), ("16 s", 16), ("32 s", 32)])
                menuPicker("Angle", $angle, [("30°", 30), ("60°", 60), ("90°", 90), ("120°", 120)])
            }
            Toggle("Seamless loop", isOn: $cameraLoop).tint(TimelineTheme.accent)
        }
    }

    private var statesTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 8) {
                menuPicker("Mode", $stateMode, StateMode.allCases.map { ($0.rawValue, $0) })
                menuPicker("Speed", $speedFactor, [("1×", 1), ("½×", 2), ("⅓×", 3), ("¼×", 4), ("⅛×", 8), ("1⁄16×", 16)])
                menuPicker("Pause", $statePause, [("0 s", 0), ("1 s", 1), ("2 s", 2), ("4 s", 4)])
            }
            Toggle("Seamless loop", isOn: $stateLoop).tint(TimelineTheme.accent)
            if engine.playback.frameCount <= 1 && stateMaxStates <= 1 {
                Text("Needs a multi-state object (NMR / trajectory).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var scenesTab: some View {
        // Same 3-row shape as Camera/States (dropdown · toggle · caption) so the
        // height matches. Uses all saved scenes; manage them in the Scenes tab.
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 8) {
                menuPicker("Seconds / scene", $sceneSeconds, [("2 s", 2), ("4 s", 4), ("8 s", 8), ("12 s", 12)])
            }
            Toggle("Loop", isOn: $sceneLoop).tint(TimelineTheme.accent)
            if engine.sceneNames.isEmpty {
                Text("No scenes saved — store scenes in the Scenes tab first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var commonActions: some View {
        HStack(spacing: 16) {
            Button {
                engine.captureKeyframe()
            } label: {
                Label("Capture keyframe", systemImage: "camera.viewfinder")
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                engine.clearMovie()
            } label: {
                Label("Reset movie", systemImage: "trash")
            }
        }
        .font(.system(size: 13))
    }

    // MARK: Build

    private var stateMaxStates: Int { engine.objects.map { $0.stateCount }.max() ?? 1 }

    private func build() {
        switch tab {
        case .camera:
            engine.buildMovie(kind: motion.kind, duration: duration, angle: angle, axis: axis, loop: cameraLoop)
        case .states:
            engine.buildMovie(kind: stateMode == .loop ? "state_loop" : "state_sweep",
                              loop: stateLoop, factor: speedFactor, pause: statePause)
        case .scenes:
            let names = selectedScenes.isEmpty
                ? engine.sceneNames
                : engine.sceneNames.filter { selectedScenes.contains($0) }
            engine.buildMovie(kind: "scenes", loop: sceneLoop, pause: sceneSeconds, scenes: names)
        }
        // Let the build settle, then start playback on the transport bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { engine.play() }
        onBuilt?()
    }

    // MARK: Helpers

    // Compact labelled dropdown — several sit side-by-side in a row. Built from a
    // Menu with a custom label (NOT Picker(.menu)) so the value is forced to a
    // single line that shrinks-to-fit rather than wrapping ("R / oll") when the
    // column is narrow (e.g. when the Dynamic Island insets the landscape panel).
    @ViewBuilder
    private func menuPicker<T: Hashable>(_ title: String, _ value: Binding<T>,
                                         _ opts: [(String, T)]) -> some View {
        let current = opts.first(where: { $0.1 == value.wrappedValue })?.0 ?? ""
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Menu {
                ForEach(opts, id: \.1) { opt in
                    Button(opt.0) { value.wrappedValue = opt.1 }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(current)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(TimelineTheme.accent)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.13)))
                .contentShape(Rectangle())
            }
            // macOS adds its own disclosure chevron to a Menu, which squished the
            // custom label down to "…". Hide it so the value text + custom chevron
            // get the full width. (No-op on iOS, where there's no default indicator.)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sheet wrapper

struct MovieBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Which tab to open on (SceneCard "Scene loop →" opens .scenes).
    var initialTab: MovieBuilderControls.Tab = .camera

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Make Movie").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            ScrollView {
                MovieBuilderControls(initialTab: initialTab, onBuilt: { dismiss() })
                    .padding(16)
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: 420, height: 520)
        #endif
    }
}

// Simple wrapping chip row for multi-select scenes.
private struct FlowChips: View {
    let items: [String]
    let selected: Set<String>
    let onTap: (String) -> Void

    var body: some View {
        // A horizontally scrolling row keeps layout simple and predictable on
        // both platforms (true flow-layout needs iOS 16 Layout; not worth it here).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { name in
                    let sel = selected.contains(name)
                    Button { onTap(name) } label: {
                        Text(name)
                            .font(.system(size: 12, weight: sel ? .bold : .regular))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sel ? TimelineTheme.accent : Color.gray.opacity(0.25))
                            .foregroundColor(sel ? .black : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
