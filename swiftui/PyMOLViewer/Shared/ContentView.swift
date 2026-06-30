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

// App Store build configuration. `iosRestricted` is the iOS App Store fallback:
// when the `RAYMOL_IOS_APPSTORE_RESTRICTED` compile flag is set, the iOS build
// hides the command-line input to satisfy App Review guideline 2.5.2
// (no user-supplied/LLM-generated code execution). Default OFF — both surfaces
// ship. macOS is never restricted (the flag is gated to os(iOS)).
enum RayMolBuild {
    static let iosRestricted: Bool = {
        #if os(iOS) && RAYMOL_IOS_APPSTORE_RESTRICTED
        return true
        #else
        return false
        #endif
    }()

    // macOS MCP server gate. The whole MCP feature (local server, run_python,
    // bridge) is incompatible with the Mac App Store sandbox + guideline 2.5.2,
    // so a MAS archive sets RAYMOL_MAS_RESTRICTED to compile it out. Default ON
    // for the Developer-ID build. Gated to os(macOS).
    static let mcpEnabled: Bool = {
        #if os(macOS) && !RAYMOL_MAS_RESTRICTED
        return true
        #else
        return false
        #endif
    }()
}

// macOS File-menu commands (defined on the App scene) post these; ContentView's
// macOS layout observes them and runs the matching open/save/export action, so
// the native menu items share the toolbar's logic + get standard shortcuts.
extension Notification.Name {
    static let raymolOpenFile     = Notification.Name("raymol.menu.openFile")
    static let raymolFetch        = Notification.Name("raymol.menu.fetch")
    static let raymolClearSession = Notification.Name("raymol.menu.clearSession")
    static let raymolSaveSession  = Notification.Name("raymol.menu.saveSession")
    static let raymolSaveSessionAs = Notification.Name("raymol.menu.saveSessionAs")
    static let raymolExportImage  = Notification.Name("raymol.menu.exportImage")
    static let mcpOpenConnectSheet = Notification.Name("raymol.mcp.openConnectSheet")
}

private extension View {
    /// Tighten inter-section spacing on grouped lists (iOS 17+); no-op elsewhere.
    @ViewBuilder func compactListSections() -> some View {
        #if os(iOS)
        if #available(iOS 17.0, *) { self.listSectionSpacing(.compact) }
        else { self }
        #else
        self
        #endif
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: PyMOLEngine
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var showThemeStudio = false   // inline Theme studio (replaces a panel region)
    @AppStorage("mouseLegendCollapsed") private var mouseLegendCollapsed = false
    @State private var showObjectPanel = true
    @State private var showCommandPanel = true

    // Export menu state. exportRayTraced persists across launches; when on, all
    // image exports are ray-traced (AO + shadows) regardless of the live view.
    @AppStorage("exportRayTraced") private var exportRayTraced = true
    // Transparent background for exported images (sets ray_opaque_background=0
    // just before the offscreen render). Persists across launches.
    @AppStorage("exportTransparent") private var exportTransparent = false
    @State private var showCustomSizeSheet = false
    @State private var customWidth = "3840"
    @State private var customHeight = "2160"

    #if os(macOS)
    // macOS empty-state "Fetch from PDB…" alert state (the Open File… path uses an
    // NSOpenPanel directly, so it needs no presentation state).
    @State private var showMacFetch = false
    @State private var macFetchID = ""
    // Drag-and-drop: true while a file is hovered over the viewport (draws a border).
    @State private var isViewportDropTargeted = false
    #endif
    #if os(macOS) && !RAYMOL_MAS_RESTRICTED
    @EnvironmentObject private var mcpManager: MCPServerManager
    @State private var showConnectSheet = false
    #endif

    // Export render-option toggles (shared by the iOS + macOS export menus).
    @ViewBuilder private var renderOptionToggles: some View {
        Toggle(isOn: $exportRayTraced) {
            Label("Ray-traced (AO + shadows)", systemImage: "sparkles")
        }
        Toggle(isOn: $exportTransparent) {
            Label("Transparent background", systemImage: "square.dashed")
        }
    }

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iPadOSLayout
        #endif
    }

    // "Calculating…" overlay: shown (after the engine's 2s reveal delay) while a
    // long op runs, so the app reads as busy rather than frozen. Platform-neutral
    // so both the macOS and iOS layouts can attach it.
    @ViewBuilder private var busyOverlay: some View {
        if engine.isBusy {
            CalculatingOverlay(label: engine.busyLabel)
        }
    }

    // Shared empty-state CTA visuals (atom icon + title + Open/Fetch buttons),
    // used by both the iOS overlay and the macOS overlay so the two platforms
    // read identically. The Open/Fetch actions differ per platform (iOS fileImporter
    // + alert; macOS NSOpenPanel + alert), so they're injected as closures.
    @ViewBuilder
    private func emptyStateContent(title: String,
                                   onOpen: @escaping () -> Void,
                                   onFetch: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "atom")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2).fontWeight(.semibold)
            Text("Open a molecular file or fetch one from the PDB.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    Label("Open File…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onFetch) {
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

    // MARK: - macOS: HSplitView with sidebar

    #if os(macOS)
    // Minimizable mouse-mode legend: full card with a minimize button, or a
    // small mouse button when collapsed (state persists via @AppStorage).
    @ViewBuilder private var mouseLegendCard: some View {
        if mouseLegendCollapsed {
            Button { withAnimation(.easeInOut(duration: 0.15)) { mouseLegendCollapsed = false } } label: {
                Image(systemName: "computermouse")
                    .font(.system(size: 15))
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Show mouse controls")
            .padding(8)
        } else {
            ZStack(alignment: .topTrailing) {
                MousePanel()
                    .frame(width: 220)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                Button { withAnimation(.easeInOut(duration: 0.15)) { mouseLegendCollapsed = true } } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Minimize")
            }
            .padding(8)
        }
    }

    private var macOSLayout: some View {
        // Sequence height cap: 1–5 sequence rows (~26pt each + 8pt padding) so the
        // strip can't grow into the viewport. minHeight is set a few pt below the
        // cap so the VSplitView still hands the user a draggable splitter (a strict
        // min == max would freeze it).
        // Default height fits up to 5 sequence rows; beyond that the panel
        // scrolls (or the user drags the splitter to open it further).
        let seqRows = min(max(engine.sequences.count, 1), 5)
        // Each object block is a ruler(11) + residue(~17) row = ~28pt; +30pt for
        // the always-visible horizontal scrollbar and inter-block/edge padding so
        // the top row isn't clipped when several sequences are shown.
        let seqH = CGFloat(seqRows) * 30 + 30

        return VStack(spacing: 0) {
            #if !RAYMOL_MAS_RESTRICTED
            MCPDrivingBanner()
            #endif
            HSplitView {
            // Left column: terminal on TOP, sequence directly under it, then the
            // 3D viewport, stacked in a VSplitView so each is drag-resizable and
            // each is hideable via the toolbar toggles.
            VSplitView {
                if showCommandPanel {
                    CommandPanel(showInput: !RayMolBuild.iosRestricted)
                        .frame(minHeight: 44, idealHeight: 60, maxHeight: 150)
                }

                if engine.sequenceVisible {
                    SequencePanel()
                        // idealHeight grows with the sequence count (up to 5 rows);
                        // maxHeight stays large so the user can drag the splitter
                        // open further. .id(seqRows) forces the VSplitView to
                        // re-adopt idealHeight when the row count changes (otherwise
                        // a pinned divider keeps the panel at its first-seen height,
                        // hiding sequences loaded later).
                        .frame(minHeight: 24, idealHeight: seqH, maxHeight: 400)
                        .id(seqRows)
                }

                // The viewport takes the remaining (majority of) space, with the
                // Timeline transport docked beneath it whenever there's more than
                // one frame to play (states / trajectory / movie).
                VStack(spacing: 0) {
                    MetalViewport()
                        .frame(minWidth: 400, minHeight: 360)
                        .layoutPriority(1)
                        .overlay(alignment: .top) {
                            if engine.measureMode != nil { measureOverlay }
                        }
                        // Pick-debug crosshair: marks exactly where the last click
                        // landed, so a screenshot shows click-vs-selection offset.
                        .overlay { debugClickMarker }
                        // Mouse-mode legend as a compact floating card at the
                        // bottom-trailing corner, so it's reachable even when the
                        // right column is collapsed (where MousePanel used to live).
                        // Minimizable to a small mouse button to free up the view.
                        .overlay(alignment: .bottomTrailing) { mouseLegendCard }
                    if engine.hasTimeline {
                        Divider()
                        TransportBar()
                    }
                }
                // Empty-state CTA when nothing is loaded (mirrors the iOS overlay).
                .overlay { if engine.objects.isEmpty && !showThemeStudio { macEmptyState } }
                // Drag a .pdb/.cif/.pse/etc. onto the viewport to load it (same
                // path as File ▸ Open / Finder "Open With"). Highlight while hovered.
                .onDrop(of: [.fileURL], isTargeted: $isViewportDropTargeted) { providers in
                    handleViewportDrop(providers)
                }
                .overlay {
                    if isViewportDropTargeted {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(themeManager.active.tabTint.color, lineWidth: 3)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
            }

            // Right column: objects + (chat). Only exists (and only occupies its
            // 300pt width) when at least one of its panels is shown — when both are
            // off the HSplitView collapses to just the left column. The mouse
            // legend moved to the floating viewport overlay (above) so it stays
            // reachable regardless.
            if showThemeStudio {
                // Theme studio takes over the right column; viewport stays live.
                ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                    .environmentObject(engine)
                    .environmentObject(themeManager)
                    .frame(width: 340)
            } else if showObjectPanel {
                VStack(spacing: 0) {
                    if showObjectPanel {
                        ObjectPanel()
                            .frame(minHeight: 150)
                    }
                }
                .frame(width: 300)
            }
        }
        } // end VStack
        .overlay { busyOverlay }
        .alert("Fetch from PDB", isPresented: $showMacFetch) {
            TextField("PDB ID (e.g. 1ubq)", text: $macFetchID)
            Button("Fetch") { macFetch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download a structure from the RCSB PDB.")
        }
        .toolbar {
            macOpenToolbar
            macThemeToolbar
            exportMenu
            macMeasureToolbar
            panelToggles
            #if !RAYMOL_MAS_RESTRICTED
            ToolbarItem(placement: .automatic) {
                MCPStatusView()
            }
            #endif
        }
        // Native File-menu commands → reuse the same actions as the toolbar.
        .onReceive(NotificationCenter.default.publisher(for: .raymolOpenFile)) { _ in macOpenFile() }
        .onReceive(NotificationCenter.default.publisher(for: .raymolFetch)) { _ in macFetchID = ""; showMacFetch = true }
        .onReceive(NotificationCenter.default.publisher(for: .raymolClearSession)) { _ in engine.clearSession() }
        .onReceive(NotificationCenter.default.publisher(for: .raymolSaveSession)) { _ in saveSession() }
        .onReceive(NotificationCenter.default.publisher(for: .raymolSaveSessionAs)) { _ in saveSessionAs() }
        .onReceive(NotificationCenter.default.publisher(for: .raymolExportImage)) { _ in saveImage(size: exportSize(scale: 2)) }
        #if !RAYMOL_MAS_RESTRICTED
        .onReceive(NotificationCenter.default.publisher(for: .mcpOpenConnectSheet)) { _ in
            showConnectSheet = true
        }
        #endif
        .sheet(isPresented: $showCustomSizeSheet) {
            customSizeSheet
        }
        #if !RAYMOL_MAS_RESTRICTED
        .sheet(isPresented: $showConnectSheet) {
            MCPConnectSheet().environmentObject(mcpManager)
        }
        .alert("Allow Claude to control RayMol?", isPresented: Binding(
            get: { mcpManager.pendingApproval },
            set: { if !$0 { mcpManager.pendingApproval = false } })) {
            Button("Stop server", role: .destructive) { mcpManager.denyAndStop() }
            Button("Allow") { mcpManager.approveSession() }
        } message: {
            Text("A local app connected to RayMol and can now run commands, "
                + "run Python, and load structures until you stop it.")
        }
        #endif
        .preferredColorScheme(themeManager.active.resolvedColorScheme)
        .tint(themeManager.active.tabTint.color)
        .onChange(of: engine.isReady) { ready in if ready { applyPersistedTheme() } }
        .onChange(of: showThemeStudio) { open in
            if open { engine.beginThemePreview() } else { engine.endThemePreview() }
        }
        .onAppear {
            initializeEngine()
            maybePresentFirstBootTheme()
            autoSelectThemeFromEnv()
            if ProcessInfo.processInfo.environment["PYMOL_AUTOSHEET"] == "theme" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { showThemeStudio = true }
            }
        }
    }

    // macOS empty-state CTA, mirroring the iOS overlay visuals. "Open File…" uses
    // an NSOpenPanel; "Fetch from PDB…" presents the macFetch alert.
    private var macEmptyState: some View {
        emptyStateContent(
            title: "No structure loaded",
            onOpen: { macOpenFile() },
            onFetch: { macFetchID = ""; showMacFetch = true }
        )
    }

    // Allowed import types — same molecular/map/session extension set the iOS
    // empty-state file picker uses (iosImportTypes), so the two platforms accept
    // identical files.
    private var macImportTypes: [UTType] {
        let exts = ["pdb", "ent", "cif", "mmcif", "mcif", "sdf", "mol", "mol2",
                    "xyz", "pdbqt", "pqr", "mae", "pse", "ccp4", "mrc", "map",
                    "dx", "mtz", "fasta", "pir"]
        return exts.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    // Drag-and-drop: load each dropped file URL through the same path as the Open
    // menu / Finder "Open With" — loadOpenedFile handles security scope, temp copy,
    // name sanitizing, and engine-not-ready retry. A dropped .pse restores a session.
    private func handleViewportDrop(_ providers: [NSItemProvider]) -> Bool {
        let engine = self.engine
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in loadOpenedFile(url, into: engine) }
            }
        }
        return accepted
    }

    // Open a molecule/session via NSOpenPanel and load it. PyMOL infers the format
    // from the extension; the object name is the filename stem (sanitized).
    private func macOpenFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = macImportTypes
        panel.title = "Open Structure"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let raw = url.deletingPathExtension().lastPathComponent
        var name = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        if name.isEmpty { name = "mol" }
        engine.loadStructure(path: url.path, name: name)
        // Track an opened .pse as the current document so ⌘S overwrites it; a
        // non-.pse structure clears the tracked document.
        engine.currentSessionURL = (url.pathExtension.lowercased() == "pse") ? url : nil
    }

    private func macFetch() {
        let id = macFetchID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
        guard !id.isEmpty else { return }
        engine.fetchStructure(id: id)
    }
    #endif

    // MARK: - iPadOS: TabView with panels

    #if os(iOS)
    // Default to the Objects tab: a touch user tunes representations far more
    // than they type commands, and it avoids greeting them with console log text.
    @State private var selectedTab = 1
    @State private var showFetch = false
    @State private var fetchID = ""
    // Confirmation for the destructive "Clear session" reset action.
    @State private var showClearSessionConfirm = false
    // Long-press context menu: the color sub-sheet + the residue sel it colors.
    @State private var showLongPressColor = false
    @State private var longPressColorSel: String?
    // iPhone: the transport floats as a 1-line peek over the viewport and
    // expands in place to the full multi-row control. (Ignored on regular-width
    // iPad, where the bar is always full.)
    @State private var transportExpanded = false
    // Test affordance (PYMOL_AUTOSHEET=builder|export): auto-present a movie
    // sheet so the screenshot harness can capture it (simctl can't tap).
    @State private var showBuilderSheet = false
    @State private var showExportSheet = false
    // Explainer when "Export Movie" is tapped with no animation built yet.
    @State private var showNoMovieAlert = false
    @State private var showSettingsSheet = false
    // The panel + viewport FRAME resize live while dragging the divider, but the
    // Metal DRAWABLE is frozen during the drag (engine.suppressDrawableResize) so
    // the renderer doesn't reallocate all offscreen targets (MSAA/SSAO/shadow/RT/
    // OIT/post) every frame — the choppy/OOM cause. One reshape fires on release.
    // Test affordance (PYMOL_AUTOEXPORTMOVIE="mp4|gif,first,last"): run a headless
    // movie export and copy the result to /tmp so the harness can validate it.
    @StateObject private var exportTester = MovieExporter()

    // Adaptive control surface. Placement + sizing depend on size class AND
    // orientation: a resizable SIDE column only on a regular-width iPad in
    // landscape (where there's horizontal surplus); otherwise — portrait, or any
    // COMPACT-width device (iPhone) — a resizable BOTTOM panel, so the 3D viewport
    // stays maximal. `panelFrac` (committed at each drag end) is the panel's share
    // of the short axis; `panelCollapsed` hides it for a full-bleed viewport.
    @Environment(\.horizontalSizeClass) private var hSize
    // verticalSizeClass distinguishes iPhone orientation: on iPhone, landscape ==
    // vSize.compact, portrait == vSize.regular (iPad is .regular in both). So
    // "iPhone portrait" == hSize.compact && vSize.regular — the only case that
    // keeps the compact bottom-panel layout; everything else (iPad both
    // orientations, iPhone landscape) uses the mac-style layout.
    @Environment(\.verticalSizeClass) private var vSize
    @State private var panelFrac: CGFloat = 0.53
    @State private var committedFrac: CGFloat = 0.53
    @State private var panelCollapsed = false
    // iPhone: full-screen viewport mode (hides the bottom panel + sequence strip).
    // Replaces the old drag-to-collapse; driven by iosPanelToggle.
    @State private var iosFullScreen = false
    // Settings tab: in-panel drill into the display-settings card.
    @State private var settingsSceneOpen = false
    // Scenes tab: opt-in glanceable scene buttons overlaid on the viewport.
    @State private var showSceneButtons = false
    // Panel fraction to restore after the Theme Studio closes (it temporarily
    // opens to ~60% of the screen so the viewport/studio split matches the spec).
    @State private var fracBeforeThemeStudio: CGFloat? = nil
    private let themeStudioFrac: CGFloat = 0.6
    // Panel share to return to when no detail view is open. While a detail view
    // (SCENE or an object card) is expanded the panel auto-grows to its max so
    // the options are visible; collapsing restores this remembered size.
    @State private var collapsedFrac: CGFloat = 0.53
    @State private var didConfigForCompact = false
    @AppStorage("ipadGestureCoachSeen") private var gestureCoachSeen = false
    @State private var showGestureLegend = false
    @State private var showPanePopover = false

    // iPhone-LANDSCAPE pane visibility. Separate from the iPad bools (showCommand/
    // Object, which default ON) so iPhone landscape starts MINIMAL —
    // Console + Objects OFF, showing just the viewport (+ the sequence
    // strip if the shared engine.sequenceVisible is on). They persist across
    // rotations (so a pane the user turned on stays on). iPad keeps the show* bools.
    @State private var landConsole = false
    @State private var landObjects = false

    // iPhone landscape == compact width + compact height (iPad is regular height in
    // both orientations; iPhone portrait is compact width + regular height).
    private var isPhoneLandscape: Bool { hSize == .compact && vSize == .compact }
    // Effective pane bindings: iPhone landscape uses its own minimal-default state;
    // everywhere else (iPad) uses the shared show* bools.
    private var consoleBinding: Binding<Bool> { isPhoneLandscape ? $landConsole : $showCommandPanel }
    private var objectsBinding: Binding<Bool> { isPhoneLandscape ? $landObjects : $showObjectPanel }

    // iPad (regular size class) mac-style layout state. The left column stacks the
    // terminal (CommandPanel) on top, the sequence (SequencePanel) under it, then
    // the viewport — matching the desktop app. `termH` is the resizable terminal
    // height (drag the divider beneath it); the sequence strip auto-sizes to its
    // row count; the right column (Objects / Raymond) has a fixed ideal width.
    @State private var termH: CGFloat = 110
    @State private var committedTermH: CGFloat = 110

    private var iPadOSLayout: some View {
        NavigationStack {
            GeometryReader { geo in
                // iPhone PORTRAIT keeps the compact bottom-panel layout; everything
                // else (iPad both orientations + iPhone LANDSCAPE) uses the mac-style
                // layout (terminal+sequence above the viewport, Objects+Raymond panel).
                let phonePortrait = hSize == .compact && vSize == .regular
                Group {
                    if phonePortrait {
                        iPhoneLayout(geo: geo)
                    } else if isPhoneLandscape {
                        // iPhone landscape mirrors the portrait UX with the same
                        // 5-tab control panel, docked on the RIGHT instead of bottom.
                        iPhoneLandscapeLayout(geo: geo)
                    } else {
                        iPadMacStyleLayout(geo: geo)
                    }
                }
                .overlay(alignment: .center) {
                    if !gestureCoachSeen && !engine.objects.isEmpty { gestureCoachOverlay }
                }
            }
            // Full-bleed on iPhone: the viewport uses every pixel, including under
            // the notch / Dynamic Island and behind the (transparent) nav bar, for
            // an immersive 3D view. iPad keeps the standard safe area so the
            // iPadOS 26 floating-toolbar capsule reserves its space and never
            // overlaps the Objects panel / terminal (it floats over content that
            // ignores the safe area). Ignore only the CONTAINER region (notch/bars)
            // — NOT the keyboard — so keyboard avoidance still pushes the console +
            // command field up above the on-screen keyboard.
            .ignoresSafeArea(.container, edges: (hSize == .regular && vSize == .regular) ? [] : .all)
            // Measurement bar docks in the top safe area (below the status bar /
            // Dynamic Island / nav bar) and insets the viewport while active —
            // NOT a full-bleed overlay, which would slide under the notch.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if engine.measureMode != nil { measureOverlay }
                    // Sequence viewer as a strip below the toolbar / above the
                    // viewport (desktop-style), toggled from Settings → "Show
                    // sequence". iPhone portrait only; iPad stacks it in-column.
                    if hSize == .compact && vSize == .regular
                        && engine.sequenceVisible && !iosFullScreen {
                        SequencePanel()
                            .frame(height: ipadSequenceHeight)
                            .background(themeChromeBg)
                        Divider()
                    }
                }
            }
            .navigationTitle(hSize == .compact ? "" : "RayMol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // Auto-grow the panel when a detail view opens so its options are
            // visible (the panel's ScrollView covers any remaining overflow);
            // restore the user's size when everything collapses.
            .onChange(of: engine.expandedDetail) { detail in
                // Poll the just-expanded object's rep detail immediately so its
                // representation list shows at once (don't wait for the next
                // ~500ms poll tick, which a heavy surface build can delay).
                if detail != nil { engine.refreshExpandedDetail() }
                // Only the iPhone (compact) bottom panel auto-grows; the iPad
                // mac-style right column scrolls its own content at fixed width.
                guard hSize == .compact else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    if detail != nil {
                        panelFrac = 0.6
                        committedFrac = 0.6
                    } else {
                        panelFrac = collapsedFrac
                        committedFrac = collapsedFrac
                    }
                }
            }
            // A full-height tab needs near-full height to be usable, so selecting
            // tab 3 grows the bottom panel to fill; leaving it restores the
            // remembered normal size. Compact (iPhone) only.
            .onChange(of: selectedTab) { tab in
                guard hSize == .compact else { return }
                withAnimation(.easeInOut(duration: 0.22)) {
                    if tab == 3 {
                        panelFrac = 0.92
                        committedFrac = 0.92
                    } else if committedFrac >= 0.85 {
                        panelFrac = collapsedFrac
                        committedFrac = collapsedFrac
                    }
                }
            }
            .toolbar { iosOpenToolbar; iosMeasureToolbar; iosPanelToggle; iosPadPanelMenu; iosExportToolbar }
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
            .alert("Clear session?", isPresented: $showClearSessionConfirm) {
                Button("Clear", role: .destructive) { engine.clearSessionAndAutosave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes all loaded structures and resets the view, effects, and settings to defaults. This can’t be undone.")
            }
            // Long-press context menu: a native action sheet for the atom/residue
            // under the press (or scene-level actions on empty space). Presented
            // when handleLongPress → engine.longPressPick sets engine.longPressHit.
            .confirmationDialog(
                engine.longPressHit?.title ?? "",
                isPresented: Binding(get: { engine.longPressHit != nil },
                                     set: { if !$0 { engine.longPressHit = nil } }),
                titleVisibility: .visible,
                presenting: engine.longPressHit
            ) { hit in
                longPressActions(hit)
            }
            // Color sub-sheet (confirmationDialog buttons can't nest, so "Color…"
            // opens this second sheet for the residue captured in longPressColorSel).
            .confirmationDialog("Color residue", isPresented: $showLongPressColor,
                                titleVisibility: .visible) {
                longPressColorActions()
            }
            .sheet(isPresented: $showGestureLegend) {
                VStack(spacing: 16) {
                    gestureLegendCard
                    Button("Done") { showGestureLegend = false }
                        .buttonStyle(.bordered)
                }
                .padding(24)
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showBuilderSheet) { MovieBuilderSheet() }
            .sheet(isPresented: $showExportSheet) { MovieExportSheet() }
            .sheet(isPresented: $showSettingsSheet) { SettingsSheet() }
        }
        .preferredColorScheme(themeManager.active.resolvedColorScheme)
        .tint(themeManager.active.tabTint.color)
        .onChange(of: engine.isReady) { ready in if ready { applyPersistedTheme() } }
        .onChange(of: showThemeStudio) { open in
            if open {
                engine.beginThemePreview()
                // Mobile: open the studio to a ~60% sheet (viewport ~40% above),
                // matching the spec; restore the prior panel size on close.
                fracBeforeThemeStudio = panelFrac
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelCollapsed = false
                    panelFrac = themeStudioFrac
                }
            } else {
                engine.endThemePreview()
                if let prior = fracBeforeThemeStudio {
                    withAnimation(.easeInOut(duration: 0.2)) { panelFrac = prior }
                    fracBeforeThemeStudio = nil
                }
            }
        }
        .onAppear {
            initializeEngine()
            maybePresentFirstBootTheme()
            // iPhone (compact): start full-screen with the panel collapsed and
            // the 64pt sequence strip off — the controls are a peek to expand.
            if !didConfigForCompact {
                didConfigForCompact = true
                if hSize == .compact {
                    panelCollapsed = true
                    engine.sequenceVisible = false
                } else {
                    // iPad (regular): default to the mac-style arrangement with the
                    // sequence strip visible under the terminal, so the stacked
                    // terminal + sequence sit above the viewport like the desktop.
                    engine.sequenceVisible = true
                }
                // Test affordance (screenshot harness): force the panel open so
                // the responsive layout can be captured without a tap, which
                // simctl can't synthesize. PYMOL_AUTOPANEL=open|closed.
                if let p = ProcessInfo.processInfo.environment["PYMOL_AUTOPANEL"] {
                    panelCollapsed = (p != "open")
                    engine.sequenceVisible = (p == "open")
                }
                // Test affordance: preselect a bottom-panel tab for the screenshot
                // harness (simctl can't tap). PYMOL_AUTOTAB=console|objects|movie|settings.
                if let t = ProcessInfo.processInfo.environment["PYMOL_AUTOTAB"] {
                    switch t {
                    case "console":  selectedTab = 0
                    case "objects":  selectedTab = 1
                    case "movie":    selectedTab = 2
                    case "settings": selectedTab = 4
                    case "scenes":   selectedTab = 5
                    default: break
                    }
                }
                // Test affordance: force the in-viewport scene buttons on.
                if ProcessInfo.processInfo.environment["PYMOL_AUTOSCENEBTN"] != nil {
                    showSceneButtons = true
                }
            }
            if let s = ProcessInfo.processInfo.environment["PYMOL_AUTOSHEET"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if s == "builder" { showBuilderSheet = true }
                    if s == "export" { showExportSheet = true }
                    if s == "settings" { showSettingsSheet = true }
                    if s == "theme" { withAnimation { showThemeStudio = true } }
                }
            }
            autoSelectThemeFromEnv()
            if let m = ProcessInfo.processInfo.environment["PYMOL_AUTOMEASURE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    engine.setMeasureMode(MeasureKind(rawValue: m) ?? .distance)
                }
            }
            if let e = ProcessInfo.processInfo.environment["PYMOL_AUTOEXPORTMOVIE"] {
                let parts = e.split(separator: ",").map(String.init)
                let fmt: MovieExporter.Format = (parts.first == "gif") ? .gif : .mp4
                let f = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                let l = parts.count > 2 ? (Int(parts[2]) ?? 10) : 10
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    exportTester.start(engine: engine, format: fmt, width: 640, height: 360,
                                       first: f, last: l, fps: 15, rayTraced: false)
                }
            }
        }
        .onChange(of: exportTester.finishedURL) { url in
            guard let url = url else { return }
            let dst = URL(fileURLWithPath: "/tmp/pymol_export_test.\(url.pathExtension)")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: url, to: dst)
            NSLog("EXPORTTEST_DONE: \(dst.path)")
        }
    }

    // MARK: iPhone (compact) layout — UNCHANGED

    // The original iPhone arrangement: the 3D viewport fills the screen and a
    // single resizable/collapsible control panel (TabView of Console / Objects /
    // Sequence / Raymond) docks at the bottom. Selecting a tab and dragging the
    // divider behave exactly as before.
    @ViewBuilder
    private func iPhoneLayout(geo: GeometryProxy) -> some View {
        let total = geo.size.height
        let panelSize = min(max(total * panelFrac, 200), total * 0.92)
        VStack(spacing: 0) {
            // The sequence strip (when enabled) docks in the top safe area via
            // .safeAreaInset(edge: .top) at the layout root — NOT here — so it sits
            // below the status bar / nav bar instead of bleeding under the notch.
            viewportView
            if iosFullScreen {
                // Full-screen viewport: bottom panel + sequence hidden, 3D fills.
                EmptyView()
            } else if showThemeStudio {
                // Theme studio takes over the bottom region; viewport stays live above.
                resizeDivider(landscape: false, total: geo.size.height)
                ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                    .environmentObject(engine)
                    .environmentObject(themeManager)
                    .frame(height: panelSize)
            } else {
                resizeDivider(landscape: false, total: geo.size.height)
                panelContent.frame(height: panelSize)
            }
        }
    }

    // MARK: iPhone landscape — portrait UX, panel docked on the RIGHT

    // Same components as portrait (sequence strip + viewport + the 5-tab control
    // panel), but laid out horizontally: viewport on the left, the panel on the
    // right edge. Full-screen hides the panel; the divider resizes it.
    @ViewBuilder
    private func iPhoneLandscapeLayout(geo: GeometryProxy) -> some View {
        let panelW = min(max(geo.size.width * 0.38, 300), 420)
        let topInset: CGFloat = 46                                  // clear the toolbar pills
        let botInset: CGFloat = engine.hasTimeline ? 64 : 8         // clear the transport
        // Explicit height (TabView won't reliably fill a maxHeight frame), so the
        // panel spans full height between the insets and the tab bar sits at the
        // bottom — not stranded mid-screen.
        let panelH = max(geo.size.height - topInset - botInset, 120)
        ZStack(alignment: .topTrailing) {
            // Full-bleed viewport (+ optional sequence strip): the 3D view spans
            // the WHOLE width; the control panel is a frosted-glass overlay on the
            // right so the structure shows through behind it.
            VStack(spacing: 0) {
                if engine.sequenceVisible {
                    SequencePanel().frame(height: ipadSequenceHeight)
                    Divider()
                }
                viewportView
            }

            if !iosFullScreen {
                Group {
                    if showThemeStudio {
                        ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                            .environmentObject(engine)
                            .environmentObject(themeManager)
                    } else {
                        panelTabs
                    }
                }
                .frame(width: panelW, height: panelH, alignment: .top)
                .background(.ultraThinMaterial)                     // frosted glass
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, x: -2, y: 1)
                .padding(.top, topInset)        // flush to the right edge (no trailing pad)
            }
        }
    }

    // MARK: iPad (regular size class) layout — mac-style stack

    // Mirrors the desktop macOSLayout: a left column with the terminal
    // (CommandPanel) on TOP, the sequence (SequencePanel) directly under it (when
    // visible), then the 3D viewport filling the rest; and a right column holding
    // Objects + Raymond. In LANDSCAPE the right column sits beside the left one
    // (like the Mac). In PORTRAIT the same left stack is kept (terminal + sequence
    // ABOVE the viewport, matching the Mac) with the right column as a narrower
    // trailing strip. Panes are shown/hidden via the toolbar's per-pane menu and
    // the terminal height is drag-resizable.
    @ViewBuilder
    private func iPadMacStyleLayout(geo: GeometryProxy) -> some View {
        let landscape = geo.size.width > geo.size.height
        let rightW: CGFloat = 340                          // landscape side column
        let maxTerm = max(140, geo.size.height * 0.33)
        let clampedTermH = min(max(termH, 60), maxTerm)
        // Effective pane visibility: iPhone landscape uses its minimal-default
        // land* state; iPad uses the show* bools (see consoleBinding etc.).
        let cTerm = consoleBinding.wrappedValue
        let cObj  = objectsBinding.wrappedValue
        let showRight = cObj
        // Portrait bottom-panel height (Objects + Raymond below the viewer),
        // resizable via the same divider/panelFrac the iPhone layout uses.
        let bottomH = min(max(geo.size.height * panelFrac, 220), geo.size.height * 0.55)

        if landscape {
            // LANDSCAPE (iPad + iPhone landscape): left stack (terminal/sequence/
            // viewport) beside a right side column (Objects + Raymond) — the Mac.
            // iPhone is full-bleed (ignoresSafeArea, for the immersive viewport),
            // so the floating top toolbar overlaps the panels — reserve top space
            // for the side panels there so the toolbar never hides the first
            // object / sequence row (iPad reserves the safe area already).
            let panelTopInset: CGFloat = isPhoneLandscape ? 46 : 0
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if cTerm {
                        CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                        termResizeDivider(maxTerm: maxTerm)
                    }
                    if engine.sequenceVisible {
                        SequencePanel().frame(height: ipadSequenceHeight)
                        Divider()
                    }
                    viewportView
                }
                // Push the console/sequence below the toolbar only when one is
                // shown; a bare viewport stays full-bleed/immersive.
                .padding(.top, (cTerm || engine.sequenceVisible) ? panelTopInset : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showThemeStudio {
                    Divider()
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(width: rightW)
                        .background(themeChromeBg)
                } else if showRight {
                    Divider()
                    VStack(spacing: 0) {
                        if cObj { ObjectPanel().frame(maxHeight: .infinity) }
                    }
                    // Reserve top space so the floating toolbar doesn't hide the
                    // Objects panel header / first object on iPhone (full-bleed).
                    .padding(.top, panelTopInset)
                    .frame(width: rightW)
                    .background(themeChromeBg)
                }
            }
        } else {
            // PORTRAIT (iPad): console + sequence ABOVE the viewer; Objects +
            // Raymond panel BELOW it (side-by-side, resizable).
            VStack(spacing: 0) {
                if cTerm {
                    CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                    termResizeDivider(maxTerm: maxTerm)
                }
                if engine.sequenceVisible {
                    SequencePanel().frame(height: ipadSequenceHeight)
                    Divider()
                }
                viewportView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showThemeStudio {
                    resizeDivider(landscape: false, total: geo.size.height)
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(height: bottomH)
                        .background(themeChromeBg)
                } else if showRight {
                    resizeDivider(landscape: false, total: geo.size.height)
                    HStack(spacing: 0) {
                        if cObj { ObjectPanel().frame(maxWidth: .infinity) }
                    }
                    .frame(height: bottomH)
                    .background(themeChromeBg)
                }
            }
        }
    }

    // Sequence strip height on iPad: 1–5 sequence rows. ruler(11)+residue(~15)
    // per row + scrollbar/padding allowance so the text isn't clipped, sized to
    // the minimum that fully shows the ruler + sequence.
    private var ipadSequenceHeight: CGFloat {
        let rows = min(max(engine.sequences.count, 1), 5)
        return CGFloat(rows) * 30 + 28
    }

    // Horizontal drag handle under the terminal that resizes its height. Dragging
    // Themed chrome surfaces (so panels/dividers follow the active theme rather
    // than a hardcoded dark gray — e.g. on the Paper/light theme).
    private var themeChromeBg: Color { themeManager.active.panelBackground.color }
    private var dividerBarColor: Color {
        themeManager.active.panelBackground.blended(with: themeManager.active.panelText, 0.12).color
    }
    private var dividerPillColor: Color { themeManager.active.panelText.color.opacity(0.4) }

    // down grows the terminal; committed on release. Clamped to [60, maxTerm].
    @ViewBuilder
    private func termResizeDivider(maxTerm: CGFloat) -> some View {
        ZStack {
            dividerBarColor
            RoundedRectangle(cornerRadius: 2)
                .fill(dividerPillColor)
                .frame(width: 44, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    termH = min(max(committedTermH + v.translation.height, 60), maxTerm)
                }
                .onEnded { _ in committedTermH = termH }
        )
    }

    // Panel show/hide toggle — lets the viewport go full-bleed. In the toolbar
    // (standard inspector-toggle spot) so it never conflicts with the resize
    // divider's drag gesture.
    private var iosMeasureToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                engine.setMeasureMode(engine.measureMode == nil ? .distance : nil)
            } label: {
                Image(systemName: engine.measureMode == nil ? "ruler" : "ruler.fill")
            }
            .tint(TimelineTheme.accent)
            .accessibilityLabel("Measure")
        }
    }

    private var iosPanelToggle: some ToolbarContent {
        // iPhone (compact) only: collapse/expand the single bottom control panel.
        // The iPad mac-style layout uses iosPadPanelMenu (per-pane toggles) instead.
        ToolbarItem(placement: .primaryAction) {
            // iPhone (both orientations) — the tab-panel layout uses a full-screen
            // toggle. iPad uses the mac-style layout with iosPadPanelMenu.
            if hSize == .compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { iosFullScreen.toggle() }
                } label: {
                    Image(systemName: iosFullScreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                }
                .tint(TimelineTheme.accent)
                .accessibilityLabel(iosFullScreen ? "Exit full screen" : "Full-screen viewport")
            }
        }
    }

    // iPad (regular size class): per-pane visibility toggles in a single menu,
    // mirroring the macOS toolbar's panelToggles (Sequence / Objects / Console /
    // Raymond). Lets the user stack the terminal + sequence above the viewport
    // and show/hide the Objects + Raymond right column — the desktop arrangement.
    private var iosPadPanelMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // iPad only (mac-style layout). iPhone — both orientations — uses the
            // 5-tab control panel + the full-screen toggle (iosPanelToggle).
            if hSize == .regular {
                Button {
                    showPanePopover.toggle()
                } label: {
                    Image(systemName: "sidebar.squares.right")
                }
                .accessibilityLabel("Panels")
                // A popover (not a Menu) so it STAYS OPEN while the user flips
                // several panes; it closes on tap-away. presentationCompactAdaptation
                // keeps it a popover on iPhone (instead of expanding to a sheet).
                .popover(isPresented: $showPanePopover, arrowEdge: .top) {
                    if #available(iOS 16.4, *) {
                        panePopoverContent.presentationCompactAdaptation(.popover)
                    } else {
                        panePopoverContent
                    }
                }
            }
        }
    }

    // Pane-visibility list for the iOS toolbar popover. Stays open while toggling;
    // off rows are grayed ("gray out the other options"). Binds to the effective
    // bindings — iPhone landscape flips its own minimal-default land* state, iPad
    // flips the show* bools.
    @ViewBuilder
    private var panePopoverContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            paneRow("Console",  "terminal",                       consoleBinding)
            paneRow("Sequence", "textformat.abc",                 $engine.sequenceVisible)
            paneRow("Objects",  "cube",                           objectsBinding)
        }
        .padding(6)
        .frame(minWidth: 240)
    }

    private func paneRow(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()    // popover stays open → multi-toggle
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(isOn.wrappedValue ? 1 : 0)
                    .frame(width: 16)
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
            .foregroundStyle(isOn.wrappedValue ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7).padding(.horizontal, 8)
    }

    // The 3D viewport — primary in every orientation. Carries the empty-state CTA
    // and a persistent "?" gesture-legend button.
    // True while a cold-launch session restore is showing its last-scene
    // snapshot — suppresses the empty "open a file" state during the reload.
    private var hasRestoreSnapshot: Bool {
        #if os(iOS)
        return engine.restoreSnapshot != nil
        #else
        return false
        #endif
    }

    // Floating scene chips over the viewport (teal/global), shown only when the
    // Scenes tab's "Show scene buttons in viewport" toggle is on. Tap = recall.
    private var sceneButtonsOverlay: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(engine.sceneNames, id: \.self) { name in
                    let sel = name == engine.currentScene
                    Button {
                        engine.runCommand("scene \(name), recall, animate=1")
                    } label: {
                        Text(name)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(sel ? TimelineTheme.accent : Color.white.opacity(0.92))
                            .foregroundColor(sel ? .white : TimelineTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .frame(maxWidth: 230)
    }

    private var viewportView: some View {
        MetalViewport()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Attached here (not the giant body chain) to keep that expression
            // under the Swift type-checker's complexity limit.
            .alert("No movie to export", isPresented: $showNoMovieAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("There’s no animation yet. Open the Movie tab, pick a motion (e.g. Camera → Roll) and tap Build & Play — then Export Movie will render it.")
            }
            .overlay { if engine.objects.isEmpty && !showThemeStudio && !hasRestoreSnapshot { emptyStateView } }
            // Cold-launch restore: cover the viewport with the last-scene snapshot
            // until the reloaded session has rendered (see restoreAutosaveIfAvailable).
            .overlay {
                #if os(iOS)
                if let snap = engine.restoreSnapshot {
                    Image(uiImage: snap)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped().allowsHitTesting(false)
                        .transition(.opacity)
                }
                #endif
            }
            .animation(.easeOut(duration: 0.35), value: hasRestoreSnapshot)
            // Timeline transport: floats over the bottom of the viewport when
            // there's more than one frame. A collapsing peek on iPhone; a pinned
            // full-width bar on iPad.
            .overlay(alignment: .bottom) {
                if engine.hasTimeline { transportOverlay }
            }
            // Opt-in glanceable scene buttons (Scenes tab → "Show scene buttons
            // in viewport"). Sits above the transport when a timeline is present.
            .overlay(alignment: .bottomLeading) {
                if showSceneButtons && !engine.sceneNames.isEmpty {
                    sceneButtonsOverlay
                        .padding(.leading, 12)
                        // Sit clear ABOVE the transport bar (don't overlap it).
                        .padding(.bottom, engine.hasTimeline ? 96 : 12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button { showGestureLegend = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(12)
                }
                .accessibilityLabel("Gesture help")
                // Keep the help button clear of the transport bar.
                .padding(.bottom, engine.hasTimeline ? 56 : 0)
            }
            // Test-only hook (PYMOL_UITEST=1): surface the live selection size
            // so XCUITest can assert tap-to-select / clear behavior. Invisible
            // and non-interactive; absent in normal runs.
            .overlay(alignment: .topLeading) {
                if ProcessInfo.processInfo.environment["PYMOL_UITEST"] == "1" {
                    Text(verbatim: "\(engine.selectedResidueKeys.count)")
                        .accessibilityIdentifier("selectionCount")
                        .opacity(0.02)
                        .allowsHitTesting(false)
                }
            }
            .overlay { busyOverlay }
    }

    // The floating transport. iPhone (compact): a rounded peek that expands in
    // place. iPad (regular): a full-width pinned bar. Floated above the home
    // indicator so it stays tappable on full-bleed layouts.
    private var transportOverlay: some View {
        let compact = hSize == .compact
        return TransportBar(
            compactPeek: compact && !transportExpanded,
            onToggleExpand: compact ? { withAnimation(.easeInOut(duration: 0.2)) { transportExpanded.toggle() } } : nil
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 16 : 0))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 16 : 0)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(compact ? 0.4 : 0), radius: 8, y: 2)
        .padding(.horizontal, compact ? 8 : 0)
        .padding(.bottom, compact ? 28 : 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // Shared control content: Console / Objects / Sequence as exclusive tabs
    // (Sequence is its own tab now — not a strip and not a toolbar/Export item).
    // The 5-tab control panel (no background — callers pick the chrome).
    private var panelTabs: some View {
        TabView(selection: $selectedTab) {
            CommandPanel(showInput: !RayMolBuild.iosRestricted)
                .tabItem { Label("Console", systemImage: "terminal") }.tag(0)
            ObjectPanel()
                .tabItem { Label("Objects", systemImage: "cube") }.tag(1)
            ScenesPane(showViewportButtons: $showSceneButtons,
                       onOpenMovie: { selectedTab = 2 })
                .tabItem { Label("Scenes", systemImage: "rectangle.on.rectangle") }.tag(5)
            MoviePane()
                .tabItem { Label("Movie", systemImage: "film") }.tag(2)
            settingsPane
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(4)
        }
    }

    // Portrait / opaque docked panel.
    private var panelContent: some View {
        panelTabs.background(themeChromeBg)
    }

    // Settings content tab (iPhone). Relocates the former top-bar Theme + Reset
    // controls here, adds the Show-sequence toggle (drives the strip above the
    // viewport), and links to scene/render settings — all in-panel, consistent
    // with the other tabs (no top-level modal).
    @ViewBuilder
    private var settingsPane: some View {
        if settingsSceneOpen {
            // In-panel drill into the SCENE card (moved here fully from the
            // Inspector). A back row returns to the Settings root — no modal.
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { settingsSceneOpen = false }
                    } label: {
                        Label("Settings", systemImage: "chevron.left")
                            .font(.system(size: 15, weight: .medium))
                    }
                    Spacer()
                    Text("Display settings").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                ScrollView {
                    SceneCard().padding(.bottom, 56)
                }
            }
        } else {
            List {
                // Single ungrouped section — no per-item headers for one-row items.
                Section {
                    Toggle(isOn: $engine.sequenceVisible) {
                        Label("Show sequence", systemImage: "textformat.abc")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { settingsSceneOpen = true }
                    } label: {
                        settingsRow("Display settings", "slider.horizontal.3")
                    }
                    Button {
                        if !showThemeStudio { panelCollapsed = false }
                        withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = true }
                    } label: {
                        settingsRow("Themes", "paintpalette")
                    }
                }
                // Reset actions — all on one row.
                Section {
                    HStack(spacing: 8) {
                        settingsResetButton("Reset view", "arrow.counterclockwise") {
                            engine.runCommand("reset")
                        }
                        settingsResetButton("Effects", "circle.lefthalf.filled") {
                            engine.resetEffects()
                        }
                        settingsResetButton("Clear", "trash", danger: true) {
                            showClearSessionConfirm = true
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .compactListSections()
            .environment(\.defaultMinListRowHeight, 38)
            // Clear the floating tab-bar pill so the Reset row stays reachable.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 56) }
        }
    }

    @ViewBuilder
    private func settingsRow(_ title: String, _ icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    // Compact icon+label button; three sit on one row in the Reset section.
    private func settingsResetButton(_ title: String, _ icon: String,
                                     danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 11)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(danger ? Color.red : TimelineTheme.accent)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.opacity(0.13)))
        }
        .buttonStyle(.plain)
    }

    // Draggable splitter between viewport and panel. Drag toward the viewport
    // (up in portrait / left in landscape) grows the panel; committed on release.
    @ViewBuilder
    private func resizeDivider(landscape: Bool, total: CGFloat) -> some View {
        ZStack {
            dividerBarColor
            RoundedRectangle(cornerRadius: 2)
                .fill(dividerPillColor)
                .frame(width: landscape ? 4 : 44, height: landscape ? 44 : 4)
        }
        .frame(width: landscape ? 16 : nil, height: landscape ? nil : 20)
        .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    // Freeze the Metal drawable for the duration of the drag so the
                    // renderer doesn't reallocate all offscreen targets every frame
                    // (the choppy/OOM cause). The panel + viewport frame still
                    // resize live (cheap SwiftUI); the viewport content just scales
                    // until release, when one reshape snaps it crisp.
                    engine.suppressDrawableResize = true
                    let d = landscape ? -v.translation.width : -v.translation.height
                    // Bottom panel can grow to near-full (0.92) so content like AI
                    // Chat can use all the space; the iPad side column stays ≤0.45.
                    panelFrac = min(max(committedFrac + d / total, 0.12), landscape ? 0.45 : 0.92)
                }
                .onEnded { _ in
                    committedFrac = panelFrac
                    if engine.expandedDetail == nil { collapsedFrac = panelFrac }
                    // Resume live drawable sizing → exactly one reshape at the final size.
                    engine.suppressDrawableResize = false
                }
        )
    }

    // MARK: Gesture legend / first-run coaching

    private struct GestureHint: Identifiable {
        let id = UUID(); let icon: String; let title: String; let detail: String
    }
    private var gestureHints: [GestureHint] { [
        .init(icon: "hand.draw", title: "Rotate", detail: "Drag · one finger"),
        .init(icon: "hand.point.up.left", title: "Pan", detail: "Drag · two fingers"),
        .init(icon: "arrow.up.left.and.arrow.down.right.circle", title: "Zoom", detail: "Pinch"),
        .init(icon: "arrow.clockwise", title: "Roll", detail: "Twist · two fingers"),
        .init(icon: "scissors", title: "Clip / slab", detail: "Drag · three fingers"),
        .init(icon: "hand.tap", title: "Select atom", detail: "Tap"),
        .init(icon: "hand.point.up.braille", title: "Menu", detail: "Long-press"),
    ] }

    private var gestureLegendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Touch gestures").font(.headline)
            ForEach(gestureHints) { h in
                HStack(spacing: 10) {
                    Image(systemName: h.icon)
                        .frame(width: 24).foregroundStyle(.tint)
                    Text(h.title).fontWeight(.medium)
                        .frame(width: 78, alignment: .leading)
                    Text(h.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
            }
        }
    }

    private var gestureCoachOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { gestureCoachSeen = true }
            VStack(spacing: 18) {
                gestureLegendCard
                Button("Got it") { gestureCoachSeen = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 440)
            .padding()
        }
    }

    // First-run / empty state: a black viewport gives no guidance, so overlay a
    // centered call-to-action when nothing is loaded. (ContentUnavailableView is
    // iOS 17+; this is a hand-rolled equivalent for the iOS 16 target.)
    private var emptyStateView: some View {
        emptyStateContent(
            title: "No structure loaded",
            onOpen: { showFileImporter = true },
            onFetch: { fetchID = ""; showFetch = true }
        )
    }


    private func iosFetch() {
        let id = fetchID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
        guard !id.isEmpty else { return }
        engine.fetchStructure(id: id)
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
            .tint(TimelineTheme.accent)   // global controls read teal
        }
    }

    private var iosThemeToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if !showThemeStudio { panelCollapsed = false }  // ensure bottom region shows
                    showThemeStudio.toggle()
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .accessibilityLabel("Theme studio")
        }
    }

    // Graduated reset menu (iOS has no File menu, so this is the only escape
    // hatch from a messed-up scene or a persisted bad state). Ordered by blast
    // radius: recenter the camera, reset the post-processing effects, or wipe
    // the whole session. Only the last is destructive → confirmation alert.
    private var iosResetMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { engine.runCommand("reset") } label: {
                    Label("Reset view", systemImage: "arrow.counterclockwise")
                }
                Button { engine.resetEffects() } label: {
                    Label("Reset effects", systemImage: "circle.lefthalf.filled")
                }
                Divider()
                Button(role: .destructive) { showClearSessionConfirm = true } label: {
                    Label("Clear session…", systemImage: "trash")
                }
            } label: {
                Image(systemName: "arrow.counterclockwise.circle")
            }
            .accessibilityLabel("Reset")
        }
    }

    // Buttons for the long-press context menu. Empty space → scene-level actions;
    // a hit → residue-scoped actions on hit.sel (an obj/chain/resi selector).
    @ViewBuilder
    private func longPressActions(_ hit: LongPressHit) -> some View {
        if hit.isEmpty {
            Button("Reset view") { engine.runCommand("reset") }
            Button("Deselect all") { engine.runCommand("deselect") }
        } else {
            Button("Zoom to residue") { engine.runCommand("zoom (\(hit.sel)), animate=1") }
            Button("Select residue") { engine.runCommand("select sele, (?sele) or (\(hit.sel))\nenable sele") }
            Button("Label residue") { engine.runCommand("label first (\(hit.sel)), '\(hit.resn)\(hit.resi)'") }
            Button("Hide residue") { engine.runCommand("hide everything, (\(hit.sel))") }
            Button("Center here") { engine.runCommand("center (\(hit.sel))") }
            Button("Color…") { longPressColorSel = hit.sel; showLongPressColor = true }
        }
        Button("Cancel", role: .cancel) {}
    }

    // Color choices for the long-press "Color…" sub-sheet (a few presets + by-element).
    @ViewBuilder
    private func longPressColorActions() -> some View {
        let sel = longPressColorSel ?? ""
        ForEach(["red", "orange", "yellow", "green", "cyan", "blue", "magenta", "white"], id: \.self) { c in
            Button(c.capitalized) { engine.runCommand("color \(c), (\(sel))") }
        }
        Button("By element") { engine.runCommand("python\nfrom pymol import util; util.cnc('(\(sel))')\npython end") }
        Button("Cancel", role: .cancel) {}
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
        engine.loadStructure(path: safe.path, name: name)
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
                    // 4K is memory-heavy (esp. ray-traced); skip it on iPhone
                    // where the smaller RAM budget makes the export likely to
                    // be jettisoned. iPad keeps the full-resolution option.
                    if hSize != .compact {
                        Button("4K · 3840 × 2160") { iosShareImage(size: CGSize(width: 3840, height: 2160)) }
                    }
                } label: {
                    Label("Share Image", systemImage: "photo")
                }
                Button {
                    iosCopyImage()
                } label: {
                    Label("Copy Image", systemImage: "doc.on.clipboard")
                }
                // Export the authored movie (Movie tab). Stays tappable even with
                // no movie so it can explain what's missing rather than silently
                // doing nothing.
                Button {
                    if engine.playback.frameCount <= 1 { showNoMovieAlert = true }
                    else { showExportSheet = true }
                } label: {
                    Label("Export Movie…", systemImage: "film")
                }
                // Render options in a submenu whose toggles DON'T dismiss the
                // menu (flip both before exporting). dismiss-disabled is iOS-only.
                #if os(iOS)
                if #available(iOS 16.4, *) {
                    Menu {
                        renderOptionToggles
                    } label: {
                        Label("Render Options", systemImage: "slider.horizontal.3")
                    }
                    .menuActionDismissBehavior(.disabled)
                } else {
                    renderOptionToggles
                }
                #else
                renderOptionToggles
                #endif
                Divider()
                // Same format set as the macOS export menu (parity).
                Menu {
                    Button("PDB (.pdb)") { iosShareStructure(ext: "pdb") }
                    Button("mmCIF (.cif)") { iosShareStructure(ext: "cif") }
                    Button("SDF (.sdf)") { iosShareStructure(ext: "sdf") }
                    Button("MOL (.mol)") { iosShareStructure(ext: "mol") }
                    Button("MOL2 (.mol2)") { iosShareStructure(ext: "mol2") }
                    Button("XYZ (.xyz)") { iosShareStructure(ext: "xyz") }
                    Button("PQR (.pqr)") { iosShareStructure(ext: "pqr") }
                    Divider()
                    // 3D models that work on this NO_OPENGL / libxml-off build
                    // (CPU-ray export path). glTF/COLLADA/STL are unavailable.
                    Button("VRML (.wrl)") { iosShareStructure(ext: "wrl") }
                    Button("POV-Ray (.pov)") { iosShareStructure(ext: "pov") }
                } label: {
                    Label("Share Structure", systemImage: "atom")
                }
                Button {
                    iosShareSession()
                } label: {
                    Label("Share Session (.pse)", systemImage: "doc.text")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .tint(TimelineTheme.accent)
        }
    }

    // Write the whole scene to a structure/3D file in the requested format and
    // hand it to the share sheet. cmd.save infers the format from the extension.
    private func iosShareStructure(ext: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RayMol_structure.\(ext)")
        try? FileManager.default.removeItem(at: url)
        engine.runPython("from pymol import cmd as _c\n_c.save(r'''\(url.path)''')")
        if FileManager.default.fileExists(atPath: url.path) { presentShareSheet(url) }
    }

    // MARK: iPad export helpers

    private func iosExportWH(scale: CGFloat) -> (Int, Int) {
        var s = engine.viewportPixelSize
        if s.width < 1 || s.height < 1 { s = CGSize(width: 1600, height: 1200) }
        return (Int((s.width * scale).rounded()), Int((s.height * scale).rounded()))
    }

    // Renders the export PNG through runHeavy so the "Calculating…" overlay shows
    // during the (slow, ray-traced) render, then delivers the file URL on the
    // main thread via `done` (nil if it didn't write).
    private func iosRenderPNG(width: Int, height: Int, done: @escaping (URL?) -> Void) {
        guard width > 0, height > 0 else { done(nil); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RayMol.png")
        try? FileManager.default.removeItem(at: url)
        engine.runHeavy("Rendering image…") {
            if exportTransparent {
                // The Metal fast path bakes the background color (its post chain
                // composites onto bg). For a true transparent PNG, use the CPU
                // ray-tracer, which honors ray_opaque_background. Slower but correct.
                engine.runCommand("set ray_opaque_background, 0")
                engine.runCommand("png \(url.path), width=\(width), height=\(height), ray=1")
            } else {
                engine.runCommand("set ray_opaque_background, 1")
                engine.renderHiResPNG(url.path, width: width, height: height,
                                      rayTraced: exportRayTraced ? 1 : 0)
            }
            done(FileManager.default.fileExists(atPath: url.path) ? url : nil)
        }
    }

    private func iosShareImage(scale: CGFloat) {
        let (w, h) = iosExportWH(scale: scale)
        iosRenderPNG(width: w, height: h) { url in if let url { presentShareSheet(url) } }
    }

    private func iosShareImage(size: CGSize) {
        iosRenderPNG(width: Int(size.width), height: Int(size.height)) { url in
            if let url { presentShareSheet(url) }
        }
    }

    private func iosCopyImage() {
        let (w, h) = iosExportWH(scale: 2)
        iosRenderPNG(width: w, height: h) { url in
            if let url, let img = UIImage(contentsOfFile: url.path) {
                UIPasteboard.general.image = img
            }
        }
    }

    private func iosShareSession() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RayMol.pse")
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

    // Always-available Open/Fetch (the empty-state CTA disappears once a
    // structure is loaded, so this keeps file-open reachable at all times).
    // macOS-only: references the NSOpenPanel/fetch-alert helpers, which don't
    // exist on iOS (iOS uses iosOpenToolbar + .fileImporter).
    #if os(macOS)
    private var macOpenToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Button {
                    macOpenFile()
                } label: { Label("Open File…", systemImage: "folder") }
                .keyboardShortcut("o", modifiers: .command)
                Button {
                    macFetchID = ""; showMacFetch = true
                } label: { Label("Fetch from PDB…", systemImage: "arrow.down.circle") }
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a structure file or fetch from the PDB")
        }
    }
    #endif

    private var macThemeToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio.toggle() }
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }
            .help("Theme studio")
        }
    }

    private var macMeasureToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                engine.setMeasureMode(engine.measureMode == nil ? .distance : nil)
            } label: {
                Label("Measure", systemImage: engine.measureMode == nil ? "ruler" : "ruler.fill")
            }
            .help("Measure distance / angle / dihedral by tapping atoms")
        }
    }

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
                // Render options in a submenu whose toggles DON'T dismiss the
                // menu (flip both before exporting). dismiss-disabled is iOS-only.
                #if os(iOS)
                if #available(iOS 16.4, *) {
                    Menu {
                        renderOptionToggles
                    } label: {
                        Label("Render Options", systemImage: "slider.horizontal.3")
                    }
                    .menuActionDismissBehavior(.disabled)
                } else {
                    renderOptionToggles
                }
                #else
                renderOptionToggles
                #endif

                Divider()

                // Per-format structure submenu (mirrors the mobile export menu).
                Menu {
                    Button("PDB (.pdb)") { saveStructure(ext: "pdb") }
                    Button("mmCIF (.cif)") { saveStructure(ext: "cif") }
                    Button("SDF (.sdf)") { saveStructure(ext: "sdf") }
                    Button("MOL (.mol)") { saveStructure(ext: "mol") }
                    Button("MOL2 (.mol2)") { saveStructure(ext: "mol2") }
                    Button("XYZ (.xyz)") { saveStructure(ext: "xyz") }
                    Button("PQR (.pqr)") { saveStructure(ext: "pqr") }
                    Divider()
                    Button("VRML (.wrl)") { saveStructure(ext: "wrl") }
                    Button("POV-Ray (.pov)") { saveStructure(ext: "pov") }
                } label: {
                    Label("Save Structure", systemImage: "atom")
                }
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

    // Render a PNG to `path` via the Metal fast path. `ray_opaque_background`
    // selects an opaque vs transparent background: when transparent, the
    // offscreen post chain rewrites alpha from depth (background → cut out), so a
    // straight-alpha PNG is produced without falling back to the slow CPU
    // ray-tracer. `rtFlag` still selects hardware-RT AO/shadows for the export.
    // Renders through runHeavy so the "Calculating…" overlay shows; `done` runs
    // on the main thread once written.
    private func renderExportPNG(_ path: String, _ w: Int, _ h: Int,
                                 done: @escaping () -> Void = {}) {
        engine.runHeavy("Rendering image…") {
            engine.runCommand("set ray_opaque_background, \(exportTransparent ? 0 : 1)")
            engine.renderHiResPNG(path, width: w, height: h, rayTraced: rtFlag)
            done()
        }
    }

    private func saveImage(size: CGSize) {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "render.png"
        panel.canCreateDirectories = true
        panel.title = "Save Image (\(w) × \(h))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        renderExportPNG(url.path, w, h)
    }

    private func copyImageToClipboard() {
        let size = exportSize(scale: 2)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_clip.png")
        renderExportPNG(tmp, w, h) {
            guard let img = NSImage(contentsOfFile: tmp) else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([img])
        }
    }

    // ⌘S: overwrite the currently-open .pse with no panel. Falls back to Save As
    // when no document is tracked (never-saved session, or a non-.pse was opened).
    private func saveSession() {
        if let url = engine.currentSessionURL {
            engine.saveSession(to: url)
        } else {
            saveSessionAs()
        }
    }

    // ⇧⌘S: always show the Save panel, prefilled from the tracked document when
    // there is one, then save to the chosen URL and make it the open document.
    private func saveSessionAs() {
        let panel = NSSavePanel()
        if let pse = UTType(filenameExtension: "pse") { panel.allowedContentTypes = [pse] }
        if let current = engine.currentSessionURL {
            panel.directoryURL = current.deletingLastPathComponent()
            panel.nameFieldStringValue = current.lastPathComponent
        } else {
            panel.nameFieldStringValue = "session.pse"
        }
        panel.canCreateDirectories = true
        panel.title = "Save Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.saveSession(to: url)
    }

    // Save the whole scene to a molecular or 3D file. cmd.save infers the format
    // from the extension; the user types the extension (.pdb/.cif/.mol2/.sdf/.xyz
    // /.mae/.pqr molecular, or .wrl/.pov 3D — glTF/COLLADA/STL aren't available
    // on this libxml-off / NO_OPENGL build).
    private func saveStructure(ext: String) {
        let panel = NSSavePanel()
        if let t = UTType(filenameExtension: ext) { panel.allowedContentTypes = [t] }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "structure.\(ext)"
        panel.canCreateDirectories = true
        panel.title = "Save Structure (.\(ext))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.runPython("from pymol import cmd as _c\n_c.save(r'''\(url.path)''')")
    }

    private func shareImage() {
        let size = exportSize(scale: 2)
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pymol_share.png")
        renderExportPNG(tmp, w, h) { presentShare(forFileAt: tmp) }
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

    // MARK: - Measurement overlay (shared)

    // A thin bar over the top of the viewport while measure mode is active:
    // pick the measurement type, see the live prompt/result, clear, or exit.
    // Pick-debug: a cyan crosshair + ring at the exact pixel of the last click,
    // overlaid on the viewport (same top-down coordinate space as the MTKView).
    // Lets a screenshot directly compare where the user clicked vs where the pink
    // selection square rendered. Only present when PYMOL_PICKDEBUG is set.
    @ViewBuilder
    private var debugClickMarker: some View {
        if PyMOLEngine.debugPickEnabled, let p = engine.debugClickPoint {
            ZStack {
                Circle().stroke(Color.cyan, lineWidth: 1.5).frame(width: 22, height: 22)
                Rectangle().fill(Color.cyan).frame(width: 1.5, height: 14)
                Rectangle().fill(Color.cyan).frame(width: 14, height: 1.5)
            }
            .position(p)
            .allowsHitTesting(false)
        }
    }

    private var measureOverlay: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { engine.measureMode ?? .distance },
                set: { engine.setMeasureMode($0) })) {
                Text("Distance").tag(MeasureKind.distance)
                Text("Angle").tag(MeasureKind.angle)
                Text("Dihedral").tag(MeasureKind.dihedral)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            Text(engine.measureStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.active.panelText.color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button { engine.clearMeasurements() } label: {
                Image(systemName: "trash").foregroundColor(themeManager.active.panelText.color)
            }.buttonStyle(.plain).help("Delete all measurements")
            Button { engine.setMeasureMode(nil) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(themeManager.active.panelText.color.opacity(0.6))
            }.buttonStyle(.plain).accessibilityLabel("Exit measure mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(themeManager.active.panelBackground.color)
        .tint(themeManager.active.accent.color)
    }

    // MARK: - Initialization

    private func initializeEngine() {
        guard !engine.isReady else { return }
        let resourcePath = Bundle.main.resourcePath ?? ""
        engine.initialize(resourcePath: resourcePath)
    }

    // Auto-present the Theme studio on the very first launch (first-run theming).
    // Deferred so the engine/window is up before the panel animates in. On
    // iPhone portrait the bottom region is collapsed by default, so un-collapse
    // it too or the inline studio won't be visible.
    // Test affordance (PYMOL_AUTOTHEME=Classic|Paper|Sunset|Dawn): select a built-in
    // preset by name on launch so the screenshot harness can verify each look.
    private func autoSelectThemeFromEnv() {
        guard let name = ProcessInfo.processInfo.environment["PYMOL_AUTOTHEME"] else { return }
        guard let t = themeManager.presets.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { themeManager.select(t, engine: engine) }
    }

    private func maybePresentFirstBootTheme() {
        guard themeManager.firstBoot else { return }
        themeManager.markFirstBootDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.easeInOut(duration: 0.2)) {
                #if os(iOS)
                panelCollapsed = false   // iPhone-portrait bottom region is collapsed by default
                #endif
                showThemeStudio = true
            }
        }
    }

    // Push the persisted theme's molecular/viewport defaults into PyMOL once the
    // engine is ready (chrome already reflects it via @Published `active`).
    private func applyPersistedTheme() {
        themeManager.apply(engine: engine)
    }
}

// Dimmed scrim + centered card shown while a long PyMOL op runs. The scrim
// captures hits so no conflicting command can be issued mid-operation (which
// also keeps the selectively-backgrounded heavy ops correctly ordered).
struct CalculatingOverlay: View {
    let label: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())   // swallow taps/clicks while busy
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(label.isEmpty ? "Calculating…" : label)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

