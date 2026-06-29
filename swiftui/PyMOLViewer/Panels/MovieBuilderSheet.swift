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
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .camera: cameraTab
            case .states: statesTab
            case .scenes: scenesTab
            }

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
        VStack(alignment: .leading, spacing: 16) {
            labeled("Motion") {
                Picker("", selection: $motion) {
                    ForEach(CameraMotion.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            labeled("Duration") {
                presetPicker($duration, [("4 s", 4), ("8 s", 8), ("16 s", 16), ("32 s", 32)])
            }
            if motion.needsAngle {
                labeled("Angle") {
                    presetPicker($angle, [("30°", 30), ("60°", 60), ("90°", 90), ("120°", 120)])
                }
            }
            Toggle("Seamless loop", isOn: $cameraLoop).tint(TimelineTheme.accent)
            Text("A 360° camera \(motion.rawValue.lowercased()) authored as interpolated keyframes.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.playback.frameCount <= 1 && stateMaxStates <= 1 {
                Text("Load a multi-state object (NMR ensemble or trajectory) to animate states.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            labeled("Mode") {
                Picker("", selection: $stateMode) {
                    ForEach(StateMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
            }
            labeled("Speed") {
                presetPicker(Binding(get: { Double(speedFactor) },
                                     set: { speedFactor = Int($0) }),
                             [("1×", 1), ("½×", 2), ("¼×", 4), ("⅛×", 8)])
            }
            labeled("Pause") {
                presetPicker($statePause, [("0 s", 0), ("1 s", 1), ("2 s", 2), ("4 s", 4)])
            }
            Toggle("Seamless loop", isOn: $stateLoop).tint(TimelineTheme.accent)
            Text(stateMode == .loop
                 ? "Steps through all states once per cycle."
                 : "Sweeps forward and back through all states.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var scenesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if engine.sceneNames.isEmpty {
                Text("No scenes saved. Store scenes from the SCENE card first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Scenes (tap to include; none = all)")
                    .font(.caption).foregroundStyle(.secondary)
                FlowChips(items: engine.sceneNames, selected: selectedScenes) { name in
                    if selectedScenes.contains(name) { selectedScenes.remove(name) }
                    else { selectedScenes.insert(name) }
                }
            }
            labeled("Seconds / scene") {
                presetPicker($sceneSeconds, [("2 s", 2), ("4 s", 4), ("8 s", 8), ("12 s", 12)])
            }
            Toggle("Loop", isOn: $sceneLoop).tint(TimelineTheme.accent)
            Text("Strings scenes into a movie with interpolated camera transitions.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var commonActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                engine.captureKeyframe()
            } label: {
                Label("Capture camera keyframe @ frame \(engine.playback.currentFrame)",
                      systemImage: "camera.viewfinder")
            }
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
            engine.buildMovie(kind: motion.kind, duration: duration, angle: angle, loop: cameraLoop)
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

    @ViewBuilder
    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func presetPicker(_ value: Binding<Double>, _ opts: [(String, Double)]) -> some View {
        Picker("", selection: value) {
            ForEach(opts, id: \.1) { Text($0.0).tag($0.1) }
        }
        .pickerStyle(.segmented)
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
