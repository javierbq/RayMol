// ContentView.swift — Main layout: viewport + side panels
// Adapts between macOS (sidebar + inspector) and iPadOS (tab-based panels).

import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
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
    // Default to the Objects tab: a touch user tunes representations far more
    // than they type commands, and it avoids greeting them with console log text.
    @State private var selectedTab = 1
    @State private var showFetch = false
    @State private var fetchID = ""
    // AI Chat is a non-functional placeholder; hide its tab until the backend
    // exists so it doesn't occupy a top-level slot.
    private let kShowChatTab = false

    private var iPadOSLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Main viewport — the star. Empty-state overlay guides first run.
                MetalViewport()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { if engine.objects.isEmpty { emptyStateView } }

                if engine.sequenceVisible {
                    // 64pt fits ~2 object rows; SequencePanel scrolls vertically
                    // beyond that (was 44pt, which clipped a 2nd structure).
                    SequencePanel()
                        .frame(height: 64)
                }

                // Bottom panel area (swipeable tabs)
                TabView(selection: $selectedTab) {
                    CommandPanel()
                        .tabItem { Label("Console", systemImage: "terminal") }
                        .tag(0)

                    ObjectPanel()
                        .tabItem { Label("Objects", systemImage: "cube") }
                        .tag(1)

                    if kShowChatTab {
                        ChatPanel()
                            .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }
                            .tag(2)
                    }
                }
                .frame(height: 250)
            }
            .navigationTitle("PyMOL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { iosOpenToolbar; iosViewToolbar; iosExportToolbar }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: iosImportTypes,
                          allowsMultipleSelection: false) { result in
                iosHandleImport(result)
            }
            .alert("Fetch from PDB", isPresented: $showFetch) {
                TextField("PDB ID (e.g. 1ubq)", text: $fetchID)
                    .textInputAutocapitalization(.never)
                Button("Fetch") { iosFetch() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Download a structure from the RCSB PDB.")
            }
        }
        .preferredColorScheme(.dark)   // consistent dark chrome (no white nav bar)
        .onAppear {
            initializeEngine()
        }
    }

    // First-run / empty state: a black viewport gives no guidance, so overlay a
    // centered call-to-action when nothing is loaded. (ContentUnavailableView is
    // iOS 17+; this is a hand-rolled equivalent for the iOS 16 target.)
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "atom")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No structure loaded")
                .font(.title2).fontWeight(.semibold)
            Text("Open a molecular file or fetch one from the PDB.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    showFileImporter = true
                } label: {
                    Label("Open File…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    fetchID = ""
                    showFetch = true
                } label: {
                    Label("Fetch from PDB…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .allowsHitTesting(true)
    }

    // Toolbar "View" menu: the live display settings (formerly reachable only by
    // leaving the viewport, switching to the Objects tab, and scrolling to the
    // SCENE card). Toggles drive the same metal_* / depth_cue settings.
    private var iosViewToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                iosViewToggle("Ray tracing", "metal_raytrace")
                iosViewToggle("Shadows", "metal_shadows")
                iosViewToggle("Ambient occlusion", "metal_ssao")
                iosViewToggle("Outline", "metal_outline")
                iosViewToggle("MSAA 4×", "metal_msaa")
                iosViewToggle("Depth cue / fog", "depth_cue")
                Divider()
                Toggle(isOn: $engine.sequenceVisible) {
                    Label("Sequence", systemImage: "textformat.abc")
                }
            } label: {
                Label("View", systemImage: "slider.horizontal.3")
            }
        }
    }

    @ViewBuilder
    private func iosViewToggle(_ label: String, _ setting: String) -> some View {
        Toggle(label, isOn: Binding(
            get: { (engine.sceneState.values[setting] ?? 0) != 0 },
            set: { engine.runCommand("set \(setting), \($0 ? 1 : 0)") }))
    }

    private func iosFetch() {
        let id = fetchID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
        guard !id.isEmpty else { return }
        engine.runCommand("fetch \(id), async=0, type=pdb")
    }

    // Open a molecule/session from Files. PyMOL load infers the format from the
    // extension; common molecular types are listed (plus .data so anything is
    // selectable). The picked file is security-scoped, so copy it to a temp path
    // (no spaces) and load via runCommand (which also runs the surface-clip
    // auto-widen and .pse view handling).
    @State private var showFileImporter = false

    private var iosImportTypes: [UTType] {
        let exts = ["pdb", "ent", "cif", "mmcif", "mcif", "sdf", "mol", "mol2",
                    "xyz", "pdbqt", "pqr", "mae", "pse", "ccp4", "mrc", "map",
                    "dx", "mtz", "fasta", "pir"]
        return exts.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private var iosOpenToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showFileImporter = true
            } label: {
                Label("Open", systemImage: "folder")
            }
        }
    }

    private func iosHandleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.isEmpty ? "pdb" : url.pathExtension
        let safe = FileManager.default.temporaryDirectory
            .appendingPathComponent("import_\(UUID().uuidString.prefix(8)).\(ext)")
        try? FileManager.default.removeItem(at: safe)
        guard (try? FileManager.default.copyItem(at: url, to: safe)) != nil else { return }
        let raw = url.deletingPathExtension().lastPathComponent
        var name = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if name.isEmpty { name = "mol" }
        engine.runCommand("load \(safe.path), \(name)")
    }

    // iPad export/share menu (the macOS Export menu lives in the window toolbar;
    // iPadOSLayout has its own NavigationStack toolbar). Renders the Metal frame
    // to a temp PNG/PSE via the shared engine, then copies to the pasteboard or
    // hands off to the system share sheet (Save to Files / Mail / AirDrop / …).
    private var iosExportToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu {
                    Button("Current View Size") { iosShareImage(scale: 1) }
                    Button("2× View") { iosShareImage(scale: 2) }
                    Button("4K · 3840 × 2160") { iosShareImage(size: CGSize(width: 3840, height: 2160)) }
                } label: {
                    Label("Share Image", systemImage: "photo")
                }
                Button {
                    iosCopyImage()
                } label: {
                    Label("Copy Image", systemImage: "doc.on.clipboard")
                }
                Toggle(isOn: $exportRayTraced) {
                    Label("Ray-traced (AO + shadows)", systemImage: "sparkles")
                }
                Divider()
                Button {
                    iosShareSession()
                } label: {
                    Label("Share Session (.pse)", systemImage: "doc.text")
                }
                Toggle(isOn: $engine.sequenceVisible) {
                    Label("Sequence", systemImage: "textformat.abc")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }

    // MARK: iPad export helpers

    private func iosExportWH(scale: CGFloat) -> (Int, Int) {
        var s = engine.viewportPixelSize
        if s.width < 1 || s.height < 1 { s = CGSize(width: 1600, height: 1200) }
        return (Int((s.width * scale).rounded()), Int((s.height * scale).rounded()))
    }

    private func iosRenderPNG(width: Int, height: Int) -> URL? {
        guard width > 0, height > 0 else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PyMOL.png")
        engine.renderHiResPNG(url.path, width: width, height: height,
                              rayTraced: exportRayTraced ? 1 : 0)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func iosShareImage(scale: CGFloat) {
        let (w, h) = iosExportWH(scale: scale)
        if let url = iosRenderPNG(width: w, height: h) { presentShareSheet(url) }
    }

    private func iosShareImage(size: CGSize) {
        if let url = iosRenderPNG(width: Int(size.width), height: Int(size.height)) {
            presentShareSheet(url)
        }
    }

    private func iosCopyImage() {
        let (w, h) = iosExportWH(scale: 2)
        if let url = iosRenderPNG(width: w, height: h),
           let img = UIImage(contentsOfFile: url.path) {
            UIPasteboard.general.image = img
        }
    }

    private func iosShareSession() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PyMOL.pse")
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(url.path)''')")
        if FileManager.default.fileExists(atPath: url.path) { presentShareSheet(url) }
    }

    // Present a UIActivityViewController from the top-most VC, anchored centered
    // (iPad requires a popover source or it throws). Avoids hosting the activity
    // controller inside a SwiftUI .sheet (which crashes without a source view).
    private func presentShareSheet(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
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
                .keyboardShortcut("c", modifiers: .command)
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
