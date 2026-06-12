// ContentView.swift — Main layout: viewport + side panels
// Adapts between macOS (sidebar + inspector) and iPadOS (tab-based panels).

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject var engine: PyMOLEngine
    @State private var showObjectPanel = true
    @State private var showCommandPanel = true
    @State private var showChatPanel = false

    // Export menu state. exportRayTraced persists across launches; when on, all
    // image exports are ray-traced (AO + shadows) regardless of the live view.
    @AppStorage("exportRayTraced") private var exportRayTraced = true
    @State private var showCustomSizeSheet = false
    @State private var customWidth = "3840"
    @State private var customHeight = "2160"

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
            exportMenu
            panelToggles
        }
        .sheet(isPresented: $showCustomSizeSheet) {
            customSizeSheet
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

    // MARK: - Export menu (macOS)

    #if os(macOS)
    private var exportMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu {
                    Button("Current View Size") { saveImage(size: exportSize(scale: 1)) }
                    Button("2× View") { saveImage(size: exportSize(scale: 2)) }
                    Button("4K · 3840 × 2160") {
                        saveImage(size: CGSize(width: 3840, height: 2160))
                    }
                    Divider()
                    Button("Custom…") { showCustomSizeSheet = true }
                } label: {
                    Label("Save Image", systemImage: "photo")
                }
                Button {
                    copyImageToClipboard()
                } label: {
                    Label("Copy Image to Clipboard", systemImage: "doc.on.clipboard")
                }
                Toggle(isOn: $exportRayTraced) {
                    Label("Ray-traced (AO + shadows)", systemImage: "sparkles")
                }

                Divider()

                Button {
                    saveSession()
                } label: {
                    Label("Save Session (.pse)…", systemImage: "doc.text")
                }
                Menu {
                    Button("Image…") { shareImage() }
                    Button("Session…") { shareSession() }
                } label: {
                    Label("Share", systemImage: "paperplane")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Save / share an image or session")
        }
    }

    private var customSizeSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Image Size").font(.headline)
            HStack(spacing: 8) {
                Text("Width")
                TextField("Width", text: $customWidth).frame(width: 70)
                Text("×").foregroundStyle(.secondary)
                Text("Height")
                TextField("Height", text: $customHeight).frame(width: 70)
                Text("px").foregroundStyle(.secondary)
            }
            Toggle("Ray-traced (AO + shadows)", isOn: $exportRayTraced)
            HStack {
                Spacer()
                Button("Cancel") { showCustomSizeSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save…") {
                    let w = Int(customWidth) ?? 0, h = Int(customHeight) ?? 0
                    showCustomSizeSheet = false
                    guard w > 0, h > 0 else { return }
                    // Defer past the sheet dismissal before opening the modal save panel.
                    DispatchQueue.main.async {
                        saveImage(size: CGSize(width: w, height: h))
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // Current viewport size in backing pixels × scale (falls back to 1600×1200
    // before the first frame establishes a drawable size).
    private func exportSize(scale: CGFloat) -> CGSize {
        var s = engine.viewportPixelSize
        if s.width < 1 || s.height < 1 { s = CGSize(width: 1600, height: 1200) }
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    private var rtFlag: Int { exportRayTraced ? 1 : 0 }

    private func saveImage(size: CGSize) {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "render.png"
        panel.canCreateDirectories = true
        panel.title = "Save Image (\(w) × \(h))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.renderHiResPNG(url.path, width: w, height: h, rayTraced: rtFlag)
    }

    private func copyImageToClipboard() {
        let size = exportSize(scale: 2)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_clip.png")
        engine.renderHiResPNG(tmp, width: w, height: h, rayTraced: rtFlag)
        guard let img = NSImage(contentsOfFile: tmp) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    private func saveSession() {
        let panel = NSSavePanel()
        if let pse = UTType(filenameExtension: "pse") { panel.allowedContentTypes = [pse] }
        panel.nameFieldStringValue = "session.pse"
        panel.canCreateDirectories = true
        panel.title = "Save Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(url.path)''')")
    }

    private func shareImage() {
        let size = exportSize(scale: 2)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_share.png")
        engine.renderHiResPNG(tmp, width: w, height: h, rayTraced: rtFlag)
        presentShare(forFileAt: tmp)
    }

    private func shareSession() {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_share.pse")
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(tmp)''')")
        presentShare(forFileAt: tmp)
    }

    private func presentShare(forFileAt path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let window = NSApp.keyWindow, let anchor = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }
    #endif

    // MARK: - Initialization

    private func initializeEngine() {
        guard !engine.isReady else { return }
        let resourcePath = Bundle.main.resourcePath ?? ""
        engine.initialize(resourcePath: resourcePath)
    }
}
