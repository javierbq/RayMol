// ContentView.swift — Main layout: viewport + side panels
// Adapts between macOS (sidebar + inspector) and iPadOS (tab-based panels).

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var showObjectPanel = true
    @State private var showCommandPanel = true
    @State private var showChatPanel = false

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iPadOSLayout
        #endif
    }

    // MARK: - macOS: HSplitView with sidebar

    #if os(macOS)
    private var macOSLayout: some View {
        HSplitView {
            // Left column: sequence viewer + terminal stacked ABOVE the 3D
            // viewport in a VSplitView so each is drag-resizable, and each is
            // hideable via the toolbar toggles.
            VSplitView {
                if engine.sequenceVisible {
                    SequencePanel()
                        .frame(minHeight: 30, idealHeight: 84, maxHeight: 240)
                }

                if showCommandPanel {
                    CommandPanel()
                        .frame(minHeight: 50, idealHeight: 110, maxHeight: 400)
                }

                // The viewport takes the remaining (majority of) space.
                MetalViewport()
                    .frame(minWidth: 400, minHeight: 360)
                    .layoutPriority(1)
            }

            // Right column: objects + (chat) + mouse legend
            VStack(spacing: 0) {
                if showObjectPanel {
                    ObjectPanel()
                        .frame(minHeight: 150)
                }

                if showChatPanel {
                    Divider()
                    ChatPanel()
                        .frame(minHeight: 200)
                }

                Spacer(minLength: 0)

                MousePanel()
                    .frame(height: 60)
            }
            .frame(width: 300)
        }
        .toolbar {
            panelToggles
        }
        .onAppear {
            initializeEngine()
        }
    }
    #endif

    // MARK: - iPadOS: TabView with panels

    #if os(iOS)
    @State private var selectedTab = 0

    private var iPadOSLayout: some View {
        VStack(spacing: 0) {
            // Main viewport
            MetalViewport()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if engine.sequenceVisible {
                SequencePanel()
                    .frame(height: 44)
            }

            // Bottom panel area (swipeable tabs)
            TabView(selection: $selectedTab) {
                CommandPanel()
                    .tabItem { Label("Console", systemImage: "terminal") }
                    .tag(0)

                ObjectPanel()
                    .tabItem { Label("Objects", systemImage: "cube") }
                    .tag(1)

                ChatPanel()
                    .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(2)
            }
            .frame(height: 250)
        }
        .onAppear {
            initializeEngine()
        }
    }
    #endif

    // MARK: - Toolbar

    private var panelToggles: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $engine.sequenceVisible) {
                Label("Sequence", systemImage: "textformat.abc")
            }
            Toggle(isOn: $showObjectPanel) {
                Label("Objects", systemImage: "cube")
            }
            Toggle(isOn: $showCommandPanel) {
                Label("Console", systemImage: "terminal")
            }
            Toggle(isOn: $showChatPanel) {
                Label("AI Chat", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    // MARK: - Initialization

    private func initializeEngine() {
        guard !engine.isReady else { return }
        let resourcePath = Bundle.main.resourcePath ?? ""
        engine.initialize(resourcePath: resourcePath)
    }
}
