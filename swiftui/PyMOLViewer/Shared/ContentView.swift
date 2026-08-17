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
    static let raymolCopyImage    = Notification.Name("raymol.menu.copyImage")
    static let raymolToggleTimeline = Notification.Name("raymol.menu.toggleTimeline")
    static let mcpOpenConnectSheet = Notification.Name("raymol.mcp.openConnectSheet")
    // Posted by the macOS app-menu item and the iOS Settings row to open the
    // "What's New" splash on demand; observed in ContentView.body.
    static let raymolShowWhatsNew = Notification.Name("raymol.menu.showWhatsNew")
    static let raymolInsertNoteView = Notification.Name("raymol.notes.insertView")
    static let raymolToggleNotePreview = Notification.Name("raymol.notes.togglePreview")
    static let raymolNotesFontIncrease = Notification.Name("raymol.notes.fontIncrease")
    static let raymolNotesFontDecrease = Notification.Name("raymol.notes.fontDecrease")
    static let raymolPerformInsertNoteView = Notification.Name("raymol.notes.performInsertView")
    static let raymolPerformToggleNotePreview = Notification.Name("raymol.notes.performTogglePreview")
    static let raymolPerformFontIncrease = Notification.Name("raymol.notes.performFontIncrease")
    static let raymolPerformFontDecrease = Notification.Name("raymol.notes.performFontDecrease")
}

#if os(iOS)
// Reports the key window's safe-area insets via UIKit's safeAreaInsetsDidChange,
// which fires at the correct time on rotation (including a landscapeLeft<->Right
// flip, where the size doesn't change but the Dynamic Island moves sides).
private struct SafeAreaReader: UIViewRepresentable {
    var onChange: (UIEdgeInsets) -> Void
    func makeUIView(context: Context) -> Reader { Reader(onChange) }
    func updateUIView(_ uiView: Reader, context: Context) { uiView.onChange = onChange; uiView.report() }
    final class Reader: UIView {
        var onChange: (UIEdgeInsets) -> Void
        init(_ onChange: @escaping (UIEdgeInsets) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        func report() { onChange(window?.safeAreaInsets ?? .zero) }
    }
}
#endif

/// Segments of the adaptive right/bottom inspector switcher:
/// Console = left terminal; Settings = the Display render card).
private enum InspectorTab: String, CaseIterable, Identifiable {
    case objects = "Objects", scenes = "Scenes", movie = "Movie", notes = "Notes", display = "Display"
    var id: String { rawValue }
    /// Matches the iPhone tab-bar symbols (Settings → Display uses the slider icon).
    var systemImage: String {
        switch self {
        case .objects: return "cube"
        case .scenes:  return "rectangle.on.rectangle"
        case .movie:   return "film"
        case .notes:   return "note.text"
        case .display: return "slider.horizontal.3"
        }
    }
    /// One-line description shown under the segmented tab picker.
    var blurb: String {
        switch self {
        case .objects: return "Structures, representations & model playback"
        case .scenes:  return "Store & recall saved views"
        case .movie:   return "Camera keyframes, scenes & model clips"
        case .notes:   return "Session-linked observations & analysis"
        case .display: return "Background, lighting & effects"
        }
    }
}

// MARK: - Per-tab natural-height measurement (portrait "hug content" sizing)
//
// Each portrait pane reports the NATURAL height of its content (measured from
// INSIDE its own scroll/stack, so it's the true content height — not the
// constrained panel frame) keyed by its tab tag. The portrait layout reads the
// active tab's reported height and sizes the bottom panel to hug it (capped).
struct PaneHeightKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

extension View {
    /// Report this view's measured height for `tag` up the preference chain
    /// (used by the portrait panel to hug each tab's natural content height).
    func reportPaneHeight(_ tag: Int) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: PaneHeightKey.self, value: [tag: g.size.height])
        })
    }
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
    @EnvironmentObject private var notes: AnalysisNotesStore
    // "What's New" splash: auto-shows once after a version bump; also opened on
    // demand via the app menu / Settings (see WhatsNewModel / WhatsNewModal).
    @StateObject private var whatsNew = WhatsNewModel()
    @State private var showThemeStudio = false   // inline Theme studio (replaces a panel region)
    @AppStorage("mouseLegendCollapsed") private var mouseLegendCollapsed = false
    // Pending auto-minimize of the expanded mouse legend (fires ~1s after the
    // pointer leaves it); cancelled if the pointer returns.
    @State private var mouseLegendCollapseWork: DispatchWorkItem?
    @State private var showObjectPanel = true
    @State private var showCommandPanel = true

    // ~/.raymolrc first-run migration prompt (RayMol#225): shown once, before
    // raymolrc.load() ever runs, when an existing ~/.pymolrc(.py) could be
    // imported. Declining writes a skip marker so we don't ask again.
    // macOS-only: a startup rc file is a desktop concept, and iOS has no
    // user-visible home directory to put one in (see loadRaymolrcOrOfferMigration).
    #if os(macOS)
    @State private var showRaymolrcMigrationPrompt = false
    #endif

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
    // Local key-down monitor token for the Esc → clear-selection handler
    // (issues #163 + #166). Installed in macOSLayout.onAppear, removed on
    // .onDisappear. NSEvent.addLocalMonitorForEvents (not .onKeyPress, which is
    // macOS 14+) keeps us on the macOS 13 deployment target.
    @State private var escKeyMonitor: Any?
    // Local key-down monitor token for cmd.set_key dispatch (#258). Same
    // rationale as escKeyMonitor above: MetalViewport declines first-responder
    // status (#73), so the viewport never receives keyDown and a monitor is the
    // only way to see keys at all. Installed/removed alongside it.
    @State private var pymolKeyMonitor: Any?
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
        layout
            // What's New splash (both platforms, single hook): once-per-launch
            // auto-show, the manual-open notification, and the sheet itself.
            .onAppear {
                notes.configureEmbeddedPersistence(
                    stage: { engine.stageAnalysisNotes(documentURL: $0, assetsDirectory: $1) },
                    export: { engine.exportAnalysisNotes(documentURL: $0, assetsDirectory: $1) }
                )
                notes.openSession(at: engine.currentSessionURL)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    whatsNew.presentAutoIfNeeded()
                }
            }
            .onChange(of: engine.currentSessionURL) { url in
                notes.openSession(at: url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .raymolShowWhatsNew)) { _ in
                whatsNew.presentManually()
            }
            .onReceive(NotificationCenter.default.publisher(for: .raymolInsertNoteView)) { _ in
                openNotesAndPost(.raymolPerformInsertNoteView)
            }
            .onReceive(NotificationCenter.default.publisher(for: .raymolToggleNotePreview)) { _ in
                openNotesAndPost(.raymolPerformToggleNotePreview)
            }
            .onReceive(NotificationCenter.default.publisher(for: .raymolNotesFontIncrease)) { _ in
                openNotesAndPost(.raymolPerformFontIncrease)
            }
            .onReceive(NotificationCenter.default.publisher(for: .raymolNotesFontDecrease)) { _ in
                openNotesAndPost(.raymolPerformFontDecrease)
            }
            .sheet(isPresented: $whatsNew.isPresented, onDismiss: { whatsNew.didDismiss() }) {
                WhatsNewModal(pages: whatsNew.pages,
                              versionLabel: whatsNew.currentVersion) {
                    whatsNew.isPresented = false
                }
            }
            #if RAYMOL_MPNN
            // Single lifecycle observer for Design mode, shared by macOS and iOS:
            // fires on EVERY designMode transition (rail pill, toolbar button, menu,
            // Move/Measure exclusion) so the scene is always restored on exit
            // regardless of which path caused the change. Hoisted out of the macOS
            // layout in Phase 2d — without it, iOS dims and recolours with no restore.
            .onChange(of: engine.designMode) { on in
                if on {
                    engine.designController.allObjects = engine.objects
                        .filter { !$0.isSelection }.map { $0.name }
                    engine.designController.enter()
                } else {
                    engine.designController.exit()
                }
            }
            #endif
    }

    @ViewBuilder private var layout: some View {
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
        // #284 + #291. One tray for every non-blocking background job, deliberately
        // NOT gated on isBusy: these run on their own threads, so the app is fully
        // usable while they are on screen. Declared after busyOverlay so the tray
        // stays ABOVE the busy scrim -- `predict` is not in heavyLabel, so a fetch
        // and a `ray` genuinely co-occur and the tray's Cancel must stay hittable.
        ProgressTray(items: ProgressItem.tray(weights: engine.weightsFetch,
                                              predictions: engine.predictionJobs)) { item in
            switch item.action {
            case .command(let cmd):    engine.runCommand(cmd)
            case .dismissWeightsFetch: engine.cancelWeightsDownload()
            case .none:                break
            }
        }
        #if RAYMOL_MPNN
        // Design inference blocks input like a long PyMOL op. Rendered by a dedicated
        // view that OBSERVES the controller — see DesignBusyOverlayView.
        if !engine.isBusy && engine.designMode {
            DesignBusyOverlayView(controller: engine.designController)
        }
        #endif
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
            // The minimize button lives in a reserved trailing gutter (top-right),
            // NOT overlaid on the panel: MousePanel's mode Picker uses
            // `maxWidth: .infinity`, so its `.menu` chevron would otherwise run
            // into the corner and blend with / hide the "−" (issue #111). The
            // gutter guarantees the button is a distinct, clearly-separated
            // affordance the picker can't reach.
            ZStack(alignment: .topTrailing) {
                MousePanel()
                    .frame(width: 220)
                    // Reserve space on the right so the picker chevron stops short
                    // of the corner where the minimize button sits.
                    .padding(.trailing, 22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                Button { withAnimation(.easeInOut(duration: 0.15)) { mouseLegendCollapsed = true } } label: {
                    // Two-tone: a strong (primary) minus glyph over a subtly tinted
                    // circle. The old single-tone `.secondary` fill was nearly
                    // invisible against the translucent header (issue #111).
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.primary, Color.primary.opacity(0.18))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Minimize")
            }
            .padding(8)
            .onHover { hovering in
                mouseLegendCollapseWork?.cancel()
                guard !hovering else { return }
                // Auto-minimize ~1s after the pointer leaves the expanded legend.
                let work = DispatchWorkItem {
                    withAnimation(.easeInOut(duration: 0.15)) { mouseLegendCollapsed = true }
                }
                mouseLegendCollapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            }
        }
    }

    // macOS layout body + notification handlers + sheets. Extracted from
    // macOSLayout so the type-checker can resolve each part in isolation
    // (the full inline modifier chain tripped the "unable to type-check in
    // reasonable time" limit — same pattern as macViewport above).
    private var macOSLayoutBase: some View {
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
                    macViewport
                    // The docked bottom transport was removed: movie playback lives
                    // in the Movie tab, model stepping in the Object panel. Only the
                    // full timeline editor still docks here (when expanded).
                    if engine.timelineMode {
                        Divider()
                        TimelinePanel()
                    }
                }
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
                inspectorSwitcher()
                    .frame(width: 340)   // compact; the Movie-tab transport is shrunk (TransportBar kT* consts) to fit rather than widening the column
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
        .alert("Import your PyMOL startup script?", isPresented: $showRaymolrcMigrationPrompt) {
            Button("Import") { confirmRaymolrcMigration() }
            Button("Not Now", role: .cancel) { declineRaymolrcMigration() }
        } message: {
            raymolrcMigrationAlertText
        }
        .toolbar {
            // Leading — Open only.
            macOpenToolbar
            // Trailing — interaction tools (Move · Measure), then view toggles,
            // actions, and status. (Measure moved here from the leading edge; the
            // Timeline/movie toggle was removed — it lives on the Movie menu / ⌥⌘M.
            // Theme moved into the Display segment, mirroring iOS Settings → Themes.)
            macMoveToolbar
            macMeasureToolbar
            #if RAYMOL_MPNN
            macDesignToolbar
            #endif
            panelToggles
            exportMenu
            #if !RAYMOL_MAS_RESTRICTED
            ToolbarItem(placement: .primaryAction) {
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
        .onReceive(NotificationCenter.default.publisher(for: .raymolCopyImage)) { _ in copyImageToClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: .raymolToggleTimeline)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode.toggle() }
        }
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
    }

    private var macOSLayout: some View {
        macOSLayoutBase
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
                // Test affordance: show the in-viewport scene buttons at launch so the
                // overlay can be screenshotted. PYMOL_AUTOSCENEBUTTONS=1.
                if ProcessInfo.processInfo.environment["PYMOL_AUTOSCENEBUTTONS"] != nil {
                    showSceneButtons = true
                }
                // Test affordance: enter Move mode and make PYMOL_AUTOMOVE=<object>
                // the active object so the gizmo can be screenshotted without a tap.
                if let mv = ProcessInfo.processInfo.environment["PYMOL_AUTOMOVE"] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                        engine.setInteractionMode(.move)
                        if !mv.isEmpty { engine.setActiveMoveObject(mv) }
                    }
                }
                installEscKeyMonitor()
                installPyMOLKeyMonitor()
            }
            .onDisappear {
                if let token = escKeyMonitor {
                    NSEvent.removeMonitor(token)
                    escKeyMonitor = nil
                }
                if let token = pymolKeyMonitor {
                    NSEvent.removeMonitor(token)
                    pymolKeyMonitor = nil
                }
            }
    }

    // Esc → back out one level. A local key-down monitor rather than .onKeyPress
    // because the whole main window must catch Esc even when the viewport isn't
    // the SwiftUI focus — MetalViewport deliberately declines first-responder
    // status (issue #73) so the command line stays hot for typing.
    //
    // The ladder, in order (issues #163 + #166, then #235):
    //   (a) a sheet / panel / popover is up (their window is key, not the main
    //       RayMol window) — Esc belongs to it, pass through so it dismisses;
    //   (b) an exclusive interaction mode (Move / Design / Measure) is active —
    //       leave it, then consume;
    //   (c) otherwise — two-stage clear selection, then consume.
    // Non-Esc keys always pass through untouched.
    // NOTE: iOS external-keyboard Esc is a deliberate follow-up (not wired here);
    // the routing itself lives on PyMOLEngine and is platform-neutral, so wiring
    // iOS later is just a key source, not a second policy.
    private func installEscKeyMonitor() {
        guard escKeyMonitor == nil else { return }
        escKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }  // 53 = Esc
            // (a) A modal/sheet/panel/popover owns the interaction → let it handle
            // Esc (dismiss). Detect secondary windows STRUCTURALLY: SwiftUI's
            // NSApp.mainWindow is unreliable (often nil in Window-scene apps), so a
            // `keyWindow != mainWindow` test wrongly swallows Esc on the main window.
            if NSApp.modalWindow != nil { return event }
            if let keyWindow = NSApp.keyWindow {
                // Sheets set isSheet; popovers/NSMenu helpers are NSPanels.
                if keyWindow.isSheet || keyWindow is NSPanel { return event }
            }
            // NOTE: intentionally does NOT defer to a focused text field — Esc
            // acts regardless of keyboard focus (incl. while the command-line box
            // is focused), per product decision. Only true modal/sheet/panel
            // windows above still get Esc for dismissal.
            //
            // (b) Leaving an interaction mode outranks clearing the selection —
            // #166 anticipated exactly this ("exiting a mode should take priority
            // before the selection stages kick in"). Routed through the engine so
            // Esc reuses each mode's own exit path rather than duplicating it.
            if engine.exitActiveInteractionMode() { return nil }
            // (c) No mode was active → the selection stages.
            engine.escapeClearSelection()
            return nil  // consume — don't beep or propagate
        }
    }

    // cmd.set_key dispatch (#258). A local key-down monitor for the same reason
    // the Esc handler is one: MetalViewport deliberately declines
    // first-responder status (#73), so keyDown never reaches the viewport and
    // the app would otherwise never see a key at all.
    //
    // The consume rule is the whole conflict policy: KeyRouting decides whether
    // an event is even a candidate, then we consume it ONLY if a binding
    // actually fired. So an unbound ⌃D falls through to the Design menu item
    // naturally, while a user-bound ⌃D shadows it — no reserved-key table
    // needed. Esc (keyCode 53) never yields a token, so this monitor and the Esc
    // one never contend.
    private func installPyMOLKeyMonitor() {
        guard pymolKeyMonitor == nil else { return }
        pymolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Deliberately mirrors the Esc monitor's modal/sheet/panel guard
            // (installEscKeyMonitor above): if a sheet, alert, or popover is
            // the key window, keys belong to it — pgup/pgdn must not change
            // scenes behind an open Fetch-from-PDB sheet, for example.
            if NSApp.modalWindow != nil { return event }
            if let keyWindow = NSApp.keyWindow {
                if keyWindow.isSheet || keyWindow is NSPanel { return event }
            }

            // Compute two focus flags passed into KeyRouting.token:
            //   textFieldFocused — an editable field is first responder (drives
            //     the Tier A non-US-keyboard yield for ALT/CTSH combos).
            //   textEditingActive — focused AND non-empty (drives Tier B, the
            //     arrows/home/end/ctrl-letter yield while the user is composing).
            // We require the text view to be editable or a field editor: the
            // feedback log uses .textSelection(.enabled), and if SwiftUI's
            // selectable-but-not-editable NSTextView ever becomes first
            // responder its `string` is the entire log, which would silently
            // disable arrows/home/end until focus moved.
            let responder = NSApp.keyWindow?.firstResponder
            var textFieldFocused = false
            var textEditingActive = false
            if let tv = responder as? NSTextView, tv.isEditable || tv.isFieldEditor {
                textFieldFocused = true
                textEditingActive = !tv.string.isEmpty
            } else if let tf = responder as? NSTextField, tf.isEditable {
                textFieldFocused = true
                textEditingActive = !tf.stringValue.isEmpty
            }

            guard let token = KeyRouting.token(
                    keyCode: event.keyCode,
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags,
                    textFieldFocused: textFieldFocused,
                    textEditingActive: textEditingActive) else { return event }
            return engine.invokeKeyBinding(token) ? nil : event
        }
    }

    // The macOS viewport: the Metal view plus its floating overlays and the
    // right-click context menu. Extracted from macOSLayout's body so the
    // type-checker can resolve each in isolation (the inline chain tripped the
    // "unable to type-check in reasonable time" limit).
    @ViewBuilder
    private var macViewport: some View {
        MetalViewport()
            .frame(minWidth: 400, minHeight: 360)
            .layoutPriority(1)
            .overlay(alignment: .top) {
                if engine.measureMode != nil { measureOverlay }
                else if engine.interactionMode == .move { moveOverlay }
            }
            #if RAYMOL_MPNN
            // Design mode overlay: a separate overlay so the #if guard does not
            // break the if-else chain above. Mutually exclusive with move/measure,
            // so only one overlay is ever shown at a time.
            // DesignOverlayView holds @ObservedObject controller: DesignController so
            // colorMeaning / isScoring / focusObject / legendDomain changes re-render
            // the toggle highlight immediately (ContentView doesn't observe the nested OO).
            .overlay(alignment: .top) {
                if engine.designMode {
                    DesignOverlayView(
                        controller: engine.designController,
                        engine: engine,
                        theme: themeManager
                    )
                }
            }
            #endif
            // (The Move-mode gizmo is a 3D CGO object rendered in the Metal
            // scene by metal_move.py; no SwiftUI overlay is needed. Input is
            // hit-tested against the projected geometry in MetalViewport.)
            // Pick-debug crosshair: marks exactly where the last click landed,
            // so a screenshot shows click-vs-selection offset.
            .overlay { debugClickMarker }
            // Debug bullseye (PYMOL_BULLSEYE=1): draws the gizmo hit-test targets +
            // a cursor bullseye so gizmo hover/click↔handle mismatches are visible.
            .overlay {
                if PyMOLEngine.bullseyeEnabled && engine.interactionMode == .move {
                    GizmoBullseyeOverlay(gizmo: engine.gizmo,
                                         cursorNDC: engine.bullseyeCursorNDC,
                                         hovered: engine.hoveredHandle)
                }
            }
            // Mouse-mode legend as a compact floating card at the bottom-trailing
            // corner, so it's reachable even when the right column is collapsed
            // (where MousePanel used to live). Minimizable to free up the view.
            .overlay(alignment: .bottomTrailing) { mouseLegendCard }
            // Opt-in glanceable scene buttons (Scenes inspector → "Show scene
            // buttons in viewport"). The iOS path wires this in viewportView;
            // macOS needs it here too. Flat 12pt bottom padding: the TransportBar
            // docks BELOW the viewport frame (sibling in the VStack), so no
            // transport clearance is needed as on iOS.
            .overlay(alignment: .bottomLeading) {
                bottomLeadingViewportChrome
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .bottom) {
                if showCameraPanel && !engine.objects.isEmpty {
                    CameraDock(engine: engine, onClose: { withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false } })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .gesture(DragGesture().onEnded { v in
                            if v.translation.height > 40 {
                                withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false }
                            }
                        })
                }
            }
            // Empty-state CTA centered in the VIEWPORT (not over the docked
            // timeline below it).
            .overlay { if engine.objects.isEmpty && !showThemeStudio { macEmptyState } }
            // Right-click context menu: a right-click in the viewport picks the
            // atom/residue under the cursor (or empty space) and sets
            // engine.longPressHit; present the same native menu the iOS
            // long-press uses. PyMOL's own pop-up menu is never drawn under this
            // Metal backend (internal_gui=0). In Design mode, clicks route to
            // focus instead (see the #if RAYMOL_MPNN onChange below).
            .confirmationDialog(
                engine.longPressHit?.title ?? "",
                isPresented: Binding(
                    get: { engine.longPressHit != nil && !engine.designMode },
                    set: { if !$0 { engine.longPressHit = nil } }),
                titleVisibility: .visible,
                presenting: engine.longPressHit
            ) { hit in
                longPressActions(hit)
            }
            #if RAYMOL_MPNN
            // Design mode click routing: a click (left or right) sets longPressHit.
            // Routes through the shared handleViewportHit three-way rule so iOS and
            // macOS behave identically — and so region-edit mode is honoured on macOS
            // (the previous direct setPinned call bypassed tapResidue and therefore
            // always pinned even when the user was building a region by clicking).
            // Clears longPressHit so the context-menu dialog never fires in design mode.
            .onChange(of: engine.longPressHit) { hit in
                guard engine.designMode, let hit = hit else { return }
                engine.designController.handleViewportHit(
                    object: hit.obj,
                    chain: hit.chain,
                    resi: hit.resi,
                    hasResidue: !hit.isEmpty)
                engine.longPressHit = nil
            }
            #endif
            .confirmationDialog("Color residue", isPresented: $showLongPressColor,
                                titleVisibility: .visible) {
                longPressColorActions()
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

    // iPad/macOS right-inspector active segment (Objects/Scenes/Movie/Display).
    // Declared outside #if os(iOS) so macOSLayout can also reference inspectorSwitcher.
    @State private var inspectorTab: InspectorTab = .objects
    // Scenes tab: opt-in glanceable scene buttons overlaid on the viewport.
    // Also outside #if os(iOS) since inspectorSwitcher (shared) binds to it.
    @State private var showSceneButtons = false
    // Scene-chip long-press "Rename…" flow (nil = alert hidden).
    @State private var sceneRenameTarget: String? = nil
    @State private var sceneRenameText: String = ""
    @State private var showCameraPanel = false   // viewport Camera overlay (shared macOS/iOS)

    private func openNotesAndPost(_ name: Notification.Name) {
        inspectorTab = .notes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    // Floating scene chips over the viewport (teal/global), shown only when the
    // Scenes tab's "Show scene buttons in viewport" toggle is on. Tap = recall.
    // Declared outside #if os(iOS) so BOTH the iOS viewportView overlay and the
    // macOS macOSLayout viewport overlay can consume it (single source of truth).
    private var sceneButtonsOverlay: some View {
        // Hug the chips: use the plain row when it fits (background wraps it
        // tightly); fall back to a scrolling row capped at 230 when there are
        // too many scenes. (The old fixed maxWidth:230 left dead space.)
        ViewThatFits(in: .horizontal) {
            // Preferred: the plain row, which the background then hugs tightly (no
            // dead space). Falls back to a 230-wide scroller only when the chips
            // genuinely don't fit. (The old outer maxWidth:230 padded the narrow
            // row out to 230 → the dead space.)
            sceneOverlayRow
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { sceneOverlayRow }
                    .frame(width: 230)
                    // Fade both edges so a half-chip dissolves under the pill's
                    // rim — the resting cue that this row scrolls, since the
                    // native scrollbar only shows mid-scroll (issue #131). A
                    // symmetric mask reads correctly over the translucent
                    // material regardless of the backing color.
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.06),
                                .init(color: .black, location: 0.94),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .onAppear { proxy.scrollTo(engine.currentScene, anchor: .center) }
                    .onChange(of: engine.currentScene) { s in
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(s, anchor: .center) }
                    }
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
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

    private var sceneOverlayRow: some View {
        HStack(spacing: 6) {
            ForEach(engine.sceneNames, id: \.self) { name in
                let sel = name == engine.currentScene
                Button {
                    engine.runCommand("scene \(name), recall, animate=1")
                } label: {
                    Text(shortSceneName(name))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .padding(.horizontal, 9).frame(height: 28)
                        .background(sel ? TimelineTheme.accent : Color.white.opacity(0.92))
                        .foregroundColor(sel ? .white : TimelineTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .id(name)
                .contextMenu { sceneChipMenu(name) }
            }
        }
        .padding(6)
    }

    // Shared long-press menu for a scene chip: reset (update to the current
    // view) / rename / delete. (Tapping the chip already recalls, so no Recall.)
    @ViewBuilder
    private func sceneChipMenu(_ name: String) -> some View {
        Text(name)
        Button { engine.updateScene(name) } label: { Label("Reset to current view", systemImage: "arrow.clockwise") }
        Button { sceneRenameText = name; sceneRenameTarget = name } label: { Label("Rename…", systemImage: "pencil") }
        Button(role: .destructive) { engine.deleteScene(name) } label: { Label("Delete", systemImage: "trash") }
    }

    // Overlay chips stay glanceable: cap the displayed name (full name lives in
    // the Scenes tab + the long-press menu) so one long rename can't blow out
    // the row / clip the selected chip.
    private func shortSceneName(_ n: String) -> String {
        n.count > 8 ? String(n.prefix(7)) + "…" : n
    }

    // Long-press / right-click context menu state (shared macOS + iOS): the color
    // sub-sheet toggle + the residue sel it colors. Both platforms present the
    // same menu from engine.longPressHit (iOS long-press, macOS right-click).
    @State private var showLongPressColor = false
    @State private var longPressColorSel: String?

    // Buttons for the long-press / right-click context menu. Empty space →
    // scene-level actions; a hit → residue-scoped actions on hit.sel (an
    // obj/chain/resi selector). Shared by iOS (long-press) and macOS (right-click).
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
            Button("Auto-lock focus") { engine.runCommand(CameraCommands.lockFocus(on: hit.sel)) }
            Button("Color…") { longPressColorSel = hit.sel; showLongPressColor = true }
        }
        Button("Cancel", role: .cancel) {}
    }

    // Color choices for the "Color…" sub-sheet (a few presets + by-element).
    @ViewBuilder
    private func longPressColorActions() -> some View {
        let sel = longPressColorSel ?? ""
        ForEach(["red", "orange", "yellow", "green", "cyan", "blue", "magenta", "white"], id: \.self) { c in
            Button(c.capitalized) { engine.runCommand("color \(c), (\(sel))") }
        }
        Button("By element") { engine.runCommand("python\nfrom pymol import util; util.cnc('(\(sel))')\npython end") }
        Button("Cancel", role: .cancel) {}
    }

    /// True while any MLX Design inference is in flight. Routes through
    /// PyMOLEngine.isDesignCalculating (a @Published property kept in sync via Combine)
    /// so ContentView re-renders and the `.disabled()` modifiers below take effect.
    /// Placed before the #if os(iOS) block so it is visible to both iOS rail toggles
    /// (inside that block) and macOS toolbar items (outside it).
    /// Returns false unconditionally in non-MPNN builds (no design mode exists).
    private var isDesignLocked: Bool {
        #if RAYMOL_MPNN
        return engine.isDesignCalculating
        #else
        return false
        #endif
    }

    #if os(iOS)
    // Default to the Objects tab: a touch user tunes representations far more
    // than they type commands, and it avoids greeting them with console log text.
    @State private var selectedTab = 1
    @State private var showFetch = false
    @State private var fetchID = ""
    // Confirmation for the destructive "Clear session" reset action.
    @State private var showClearSessionConfirm = false
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
    // Currently always off — the explicit toggle was removed; collapse the rail +
    // inspector instead for an immersive view.
    @State private var iosFullScreen = false
    // Settings tab: in-panel drill into the display-settings card.
    @State private var settingsSceneOpen = false
    // Panel fraction to restore after the Theme Studio closes (it temporarily
    // opens to ~60% of the screen so the viewport/studio split matches the spec).
    @State private var fracBeforeThemeStudio: CGFloat? = nil
    private let themeStudioFrac: CGFloat = 0.6
    // Panel share to return to when no detail view is open. While a detail view
    // (SCENE or an object card) is expanded the panel auto-grows to its max so
    // the options are visible; collapsing restores this remembered size.
    @State private var collapsedFrac: CGFloat = 0.53
    // Portrait per-tab "hug content" sizing: natural content height per tab tag,
    // reported via PaneHeightKey. The portrait panel sizes to the active tab's
    // content (capped). (panelFrac/committedFrac above are now iPad-only.)
    @State private var paneHeights: [Int: CGFloat] = [:]
    @State private var didConfigForCompact = false
    @AppStorage("ipadGestureCoachSeen") private var gestureCoachSeen = false
    @State private var showGestureLegend = false

    // Test hook (PYMOL_SKIP_GESTURE_HELP): suppress the first-run gesture-coach
    // overlay entirely. On a fresh simulator gestureCoachSeen defaults to false,
    // so the coach auto-appears once a structure loads and its full-screen dimming
    // background (see gestureCoachOverlay) swallows the very first tap — which
    // makes XCUITests that tap a viewport chip on launch fail. Setting this env
    // var to any value keeps the coach from ever appearing; the manual "Gesture
    // help" button still works.
    private var skipGestureHelp: Bool {
        ProcessInfo.processInfo.environment["PYMOL_SKIP_GESTURE_HELP"] != nil
    }

    // iPhone-LANDSCAPE pane visibility. Separate from the iPad bools (showCommand/
    // Object, which default ON) so iPhone landscape starts MINIMAL —
    // Console + Objects OFF, showing just the viewport (+ the sequence
    // strip if the shared engine.sequenceVisible is on). They persist across
    // rotations (so a pane the user turned on stays on). iPad keeps the show* bools.
    @State private var landConsole = false
    @State private var landObjects = true
    // The actual right-edge window safe-area inset (the Dynamic Island only when
    // it's on the trailing side). Fed by SafeAreaReader via UIKit's
    // safeAreaInsetsDidChange — reliable across a landscapeLeft<->Right flip,
    // unlike geo.safeAreaInsets (which reports the island inset regardless of side).
    @State private var windowTrailingInset: CGFloat = 0
    // The window's BOTTOM safe-area inset (the home indicator). iPhone portrait runs
    // the viewport full-bleed under the safe area, so the collapsed inspector tongue
    // (a .bottom overlay on the viewport) would otherwise land on the system gesture
    // bar. We lift the tongue by this inset. Fed by SafeAreaReader.
    @State private var windowBottomInset: CGFloat = 0
    // In landscape the window reports the island inset SYMMETRICALLY on both sides,
    // so the insets can't tell us which side the island is physically on — the
    // interface orientation does. Verified on-device (iPhone 15 Pro): when the
    // island sits on the RIGHT the interface orientation is .landscapeRight.
    @State private var islandOnRight = false
    // True when the interface is in a portrait orientation. On iPad this gates the
    // expanded-timeline dock (landscape-only): its entry points are disabled and
    // the dock auto-closes on rotation into portrait. Fed by refreshIslandSide().
    @State private var interfacePortrait = false

    private func refreshIslandSide() {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        if let io = scene?.interfaceOrientation {
            interfacePortrait = io.isPortrait
            // Verified on-device (iPhone 15 Pro, yellow bg) AND on-sim (cutout visible
            // inside a debug-colored stripe): the Dynamic Island sits on the physical
            // RIGHT when interfaceOrientation == .landscapeLeft. (The naming is
            // counter-intuitive; trust the empirical mapping, not the enum label.)
            islandOnRight = (io == .landscapeLeft)
        }
        #endif
    }

    // iPhone landscape == compact width + compact height (iPad is regular height in
    // both orientations; iPhone portrait is compact width + regular height).
    private var isPhoneLandscape: Bool { hSize == .compact && vSize == .compact }
    // iPad in portrait (regular width + portrait interface orientation). The
    // expanded timeline dock is landscape-only, so its Expand button + the nav-bar
    // clapperboard toggle are disabled here and the dock auto-closes on rotation.
    private var isPadPortrait: Bool { hSize != .compact && interfacePortrait }
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
                // The Movie tab (tag 2) IS the timeline on iPhone: enter it directly
                // from the tab selection (not just after onChange sets timelineMode),
                // so there's no 1-frame flash of the old builder pane.
                Group {
                    // iPhone: the Movie tab hosts the timeline (the tab bar stays).
                    // iPad: the timeline lives in the right inspector's Movie tab and
                    // optionally docks full-width at the bottom (iPadMacStyleLayout) —
                    // no full-screen takeover, so the inspector stays usable.
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
                    if !gestureCoachSeen && !skipGestureHelp && !engine.objects.isEmpty { gestureCoachOverlay }
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
            .ignoresSafeArea(.container, edges:
                (hSize == .regular && vSize == .regular) ? []      // iPad: standard safe area
                : isPhoneLandscape ? .all                          // iPhone landscape: island letterbox handled inline
                : [.bottom, .horizontal])                          // iPhone portrait: keep the rail/chrome below the status bar + island
            #if os(iOS)
            // Track the real per-side window safe-area inset (correct across a
            // landscapeLeft<->Right flip) for the landscape panel's trailing inset.
            .background {
                SafeAreaReader { insets in
                    if windowTrailingInset != insets.right { windowTrailingInset = insets.right }
                    if windowBottomInset != insets.bottom { windowBottomInset = insets.bottom }
                }
            }
            #endif
            // (Move / Measure bars now dock in the rail stack — see iPhoneLayout,
            // iPhoneLandscapeLayout, and iPadMacStyleLayout — so the former
            // top-safe-area inset that hosted them is gone.)
            // iPad PORTRAIT: large left-aligned nav title. iPhone portrait uses a
            // compact in-content title (see iPhoneLayout) — the iOS large title
            // reserved too much top space on the phone. Landscape has no nav title
            // (it heads the right inspector panel; iPhone landscape hides the nav bar).
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // iPhone landscape hides the nav bar entirely (its toolbar items are
            // re-floated over the viewer) so the right panel content starts at the
            // very top with no nav-bar gap.
            // Nav bar hidden on ALL devices; the title + Open/Save/Export float
            // in-content (iPhone: top row; iPad portrait: top band; landscape: the
            // right inspector header) so nothing wastes a nav-bar row.
            .toolbar(.hidden, for: .navigationBar)
            // Auto-grow the panel when a detail view opens so its options are
            // visible (the panel's ScrollView covers any remaining overflow);
            // restore the user's size when everything collapses.
            .onChange(of: engine.expandedDetail) { detail in
                // The immediate rep-detail poll on expand is fired from
                // PyMOLEngine.expandedDetail's didSet (so every layout — incl.
                // macOS, which has no such observer — populates at once, #107).
                // Here we only drive the iPhone panel auto-grow.
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
            // Move (Move-mode toggle) replaces the Timeline/movie button here: the
            // clapperboard rendered as an unlabeled circle and jumped users into
            // movie mode unexpectedly, so it was removed (movie/timeline stays on
            // the Movie tab / ⌥⌘M). iPad per-pane toggles now live in master's
            // reworked inspector (iosPadPanelMenu retired).
            // Nav bar is hidden on all iOS devices; Open/Save/Export + the title are
            // floated in-content (top row / top band / inspector header) via
            // iosToolPills(), so there's no nav-bar toolbar content here.
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
            // Suppressed in Design mode — taps route to DesignController instead
            // (see handleTap #if RAYMOL_MPNN block) so the action sheet must not fire.
            .confirmationDialog(
                engine.longPressHit?.title ?? "",
                isPresented: Binding(get: { engine.longPressHit != nil && !engine.designMode },
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
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            refreshIslandSide()   // interface orientation is valid immediately (no settle delay)
            // The expanded timeline dock is landscape-only on iPad: collapse it when
            // rotating into portrait so it never lingers behind a disabled toggle.
            if hSize != .compact && interfacePortrait && engine.timelineMode {
                withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = false }
            }
        }
        #endif
        .onAppear {
            #if os(iOS)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            refreshIslandSide()
            #endif
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
                // Test affordance: fully collapse the top stack + inspector so the
                // full-bleed viewport + floating rail can be screenshotted (simctl
                // can't tap the pills). PYMOL_AUTOCOLLAPSE=1.
                if ProcessInfo.processInfo.environment["PYMOL_AUTOCOLLAPSE"] != nil {
                    showCommandPanel = false
                    engine.sequenceVisible = false
                    showObjectPanel = false
                    landConsole = false
                    landObjects = false
                    panelCollapsed = true
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
                    if s == "whatsnew" { whatsNew.presentManually() }
                }
            }
            // Test affordance (screenshot harness): auto-open the Camera control
            // dock so its layout can be captured without a tap (simctl can't
            // synthesize one). Delayed so an AUTOLOAD/AUTOCMD structure is present
            // (the dock only shows when an object exists). PYMOL_AUTOCAMERA=1.
            if ProcessInfo.processInfo.environment["PYMOL_AUTOCAMERA"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = true }
                }
            }
            autoSelectThemeFromEnv()
            if let m = ProcessInfo.processInfo.environment["PYMOL_AUTOMEASURE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    engine.setMeasureMode(MeasureKind(rawValue: m) ?? .distance)
                }
            }
            // Test affordance: enter Move mode and make PYMOL_AUTOMOVE=<object>
            // the active object, so the gizmo can be screenshotted without a tap.
            if let mv = ProcessInfo.processInfo.environment["PYMOL_AUTOMOVE"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                    engine.setInteractionMode(.move)
                    if !mv.isEmpty { engine.setActiveMoveObject(mv) }
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
            #if RAYMOL_MPNN
            // Test affordance (PYMOL_AUTODESIGN="<object>[,<selection>]"): enter
            // Design mode, focus the object, and optionally designate a selection as
            // the region and run one redesign. Logs a grep-able marker on completion.
            // This is the only headless way to drive Design mode; pair with
            // PYMOL_AUTOLOAD to get a structure in first.
            if let d = ProcessInfo.processInfo.environment["PYMOL_AUTODESIGN"] {
                let parts = d.split(separator: ",").map(String.init)
                let objectName = parts.first ?? ""
                let selectionName = parts.count > 1 ? parts[1] : nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    guard !objectName.isEmpty else {
                        NSLog("AUTODESIGN_FAIL: no object given")
                        return
                    }
                    guard DesignAvailability.isSupported else {
                        NSLog("AUTODESIGN_FAIL: Design mode not supported on this OS (requires iOS \(DesignAvailability.minimumIOSMajorVersion)+)")
                        return
                    }
                    engine.setDesignMode(true)
                    let c = engine.designController
                    Task { @MainActor in
                        await c.focusAwait(objectName)
                        guard c.focusObject != nil, !c.focusResidues.isEmpty else {
                            NSLog("AUTODESIGN_FAIL: focus produced no residues for \(objectName)")
                            return
                        }
                        if let sel = selectionName {
                            c.refreshSelections()
                            c.pickSelection(sel)
                            guard c.regionModeActive else {
                                NSLog("AUTODESIGN_FAIL: selection '\(sel)' matched no designable residues")
                                return
                            }
                            await c.redesignSelectionAwait()
                            if let err = c.errorText {
                                NSLog("AUTODESIGN_FAIL: \(err)")
                                return
                            }
                        }
                        let score = c.sequenceScore.map { String(format: "%.4f", $0) } ?? "nil"
                        NSLog("AUTODESIGN_DONE: \(objectName) score=\(score) edits=\(c.editCount)")
                    }
                }
            }
            #endif
        }
        // The Movie tab IS the timeline: on iPhone it renders inside the tab UI
        // (tab bar stays visible — no Done). Keep timelineMode synced to the tab
        // so the TransportBar's timeline styling applies, and reset it on leave.
        .onChange(of: selectedTab) { tab in
            if hSize == .compact {
                withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode = (tab == 2) }
            }
            // Entering the Movie tab = authoring; stop any model-inspection playback.
            if tab == 2 { engine.pause(); engine.stopAllObjectStates() }
        }
        // Programmatic entry (test hooks / "Open in movie"): flipping timelineMode
        // on iPhone jumps to the Movie tab that now HOSTS the timeline.
        .onChange(of: engine.timelineMode) { on in
            if hSize == .compact && on && selectedTab != 2 {
                withAnimation(.easeInOut(duration: 0.2)) { selectedTab = 2 }
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
    // Bottom-panel chrome that must fit ABOVE the reported pure content height:
    // the floating tab bar's footprint + a little breathing room. Tuned on-device.
    private let portraitPanelChrome: CGFloat = 84

    /// Portrait bottom-panel height, per active tab (no drag — heights are policy
    /// driven). Console is a fixed tall pane; Objects/Scenes/Movie HUG their content
    /// up to a per-tab cap (then scroll); Settings is compact at its root and grows
    /// to 3/4 when a detail editor (Display settings / Themes) is open.
    private func portraitPanelHeight(total: CGFloat) -> CGFloat {
        let floor: CGFloat = 150
        // A detail editor open in Settings → 3/4 of the screen.
        if showThemeStudio || (selectedTab == 4 && settingsSceneOpen) {
            return total * 0.75
        }
        // Measured content + chrome, for the hug tabs.
        func hug(_ tag: Int, cap: CGFloat, extra: CGFloat = 0) -> CGFloat {
            let content = paneHeights[tag].map { $0 + extra + portraitPanelChrome }
            return min(max(content ?? cap, floor), cap)
        }
        switch selectedTab {
        case 0:  return total * 0.5                              // Console — fixed tall
        case 1:  // Objects — hug compact; grow to half-screen when a card is expanded.
            return engine.expandedDetail != nil ? total * 0.5 : hug(1, cap: total / 3, extra: 44)
        case 5:  return hug(5, cap: total * 0.5)                 // Scenes
        case 2:  return hug(2, cap: total * 0.72)               // Movie — timeline studio
        case 4:  return total * 0.42                             // Settings root — compact
        default: return total * 0.45
        }
    }

    // iPad-portrait bottom inspector height — mirrors portraitPanelHeight's policy
    // but keyed to the inspector's segmented tab. The Movie tab hugs its measured
    // content (reportPaneHeight(2)); the scroll-based tabs use fixed caps (they
    // fill a sensible fraction rather than collapsing to nothing).
    private func inspectorPortraitHeight(total: CGFloat) -> CGFloat {
        let floor: CGFloat = 150
        // Segmented picker + blurb row + divider sit above the tab content.
        let chrome: CGFloat = 96
        func hug(_ tag: Int, cap: CGFloat) -> CGFloat {
            let content = paneHeights[tag].map { $0 + chrome }
            return min(max(content ?? cap, floor), cap)
        }
        switch inspectorTab {
        case .objects: return engine.expandedDetail != nil ? total * 0.5 : total / 3
        case .scenes:  return hug(5, cap: total * 0.5)
        case .movie:   return hug(2, cap: total * 0.72)
        case .notes:   return total * 0.5
        case .display: return total * 0.5
        }
    }

    // (Retired) iOS full-screen timeline takeover. The timeline now lives in the
    // iPhone Movie tab (iPhoneLayout) and, on iPad, in the right inspector's Movie
    // tab + an optional bottom dock (iPadMacStyleLayout) — no takeover.

    @ViewBuilder
    private func iPhoneLayout(geo: GeometryProxy) -> some View {
        let total = geo.size.height
        let maxTerm = max(140, total * 0.33)
        let clampedTermH = min(max(termH, 60), maxTerm)
        // Mirrors the iPad portrait model on the phone: the rail is pinned on top
        // (Console·Seq·Move·Measure), panes open UNDER it (Console → Seq →
        // Move/Measure bar), and the inspector docks along the bottom headed by the
        // RayMol title. Collapsed → the rail floats over the full-bleed viewport.
        let cTerm = showCommandPanel && !iosFullScreen
        let anyTop = !iosFullScreen && (cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
            || engine.designMode)
        VStack(spacing: 0) {
            // Top row, right under the status bar (nav bar is hidden on iPhone):
            // RayMol title on the left, Open/Save/Export on the right. It takes the
            // panel chrome when a pane is open so the whole top reads as one block;
            // transparent (over the full-bleed viewport) when collapsed.
            HStack {
                Text("RayMol")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(themeManager.active.panelText.color)
                Spacer(minLength: 0)
                iosToolPills()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(anyTop ? themeChromeBg : Color.clear)
            if anyTop {
                topPaneRail(floating: false).background(themeChromeBg)
                Rectangle().fill(hairlineColor).frame(height: 1)
                if cTerm {
                    CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                    termResizeDivider(maxTerm: maxTerm)
                }
                if engine.sequenceVisible {
                    SequencePanel().frame(height: ipadSequenceHeight)
                    Rectangle().fill(hairlineColor).frame(height: 1)
                }
                if engine.interactionMode == .move { moveOverlay }
                else if engine.measureMode != nil { measureOverlay }
                else if engine.designMode { designModeBar }
            }
            viewportView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { if !anyTop { topPaneRail(floating: true) } }
                // Closed → the tongue rides the viewport's bottom edge (tap to
                // reopen). Open → it straddles the seam via the inspector overlay
                // below (which paints on top of both viewport and panel).
                .overlay(alignment: .bottom) {
                    if !showThemeStudio && !iosFullScreen && !showObjectPanel {
                        // Lift the tongue above the home indicator — the viewport is
                        // full-bleed under the bottom safe area, so without this the
                        // tappable pill sits on the system gesture bar.
                        panelTongue(shown: objectsBinding, axis: .horizontal)
                            .padding(.bottom, windowBottomInset)
                    }
                }
            if !iosFullScreen {
                if showThemeStudio {
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(height: portraitPanelHeight(total: total))
                } else if showObjectPanel {
                    Rectangle().fill(hairlineColor).frame(height: 1)
                    inspectorSwitcher(hugContent: true)
                        .frame(height: inspectorPortraitHeight(total: total))
                        .background(themeChromeBg)
                        .overlay(alignment: .top) {
                            panelTongue(shown: objectsBinding, axis: .horizontal, seam: true)
                        }
                        .onPreferenceChange(PaneHeightKey.self) { paneHeights = $0 }
                        .animation(.easeInOut(duration: 0.25), value: inspectorTab)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showObjectPanel)
    }

    // MARK: iPhone landscape — portrait UX, panel docked on the RIGHT

    // Same components as portrait (sequence strip + viewport + the 5-tab control
    // panel), but laid out horizontally: viewport on the left, the panel on the
    // right edge. Full-screen hides the panel; the divider resizes it.
    @ViewBuilder
    private func iPhoneLandscapeLayout(geo: GeometryProxy) -> some View {
        // Right panel uses the SAME width as the portrait panel — i.e. the
        // device's short edge, which in landscape is geo.size.height — so the
        // control content lays out identically in both orientations. (Full-screen
        // hides it; the nav bar is hidden in landscape so the panel starts at top.)
        let panelW = iosFullScreen ? 0 : geo.size.height
        // The Dynamic-Island inset (≈59pt in landscape; 0 on notch-less devices).
        // The window reports it symmetrically, so which physical side it's on comes
        // from islandOnRight (interface orientation).
        let notch = windowTrailingInset
        let maxTerm = max(140, geo.size.height * 0.33)
        let clampedTermH = min(max(termH, 60), maxTerm)
        let cTerm = consoleBinding.wrappedValue && !iosFullScreen
        let anyTop = !iosFullScreen && (cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
            || engine.designMode)
        HStack(spacing: 0) {
            // Left: the molecular viewer (+ optional sequence strip), with the
            // toolbar buttons floating over its top edge. The 3D viewport bleeds
            // full to the left screen edge — including UNDER the island when it's on
            // the left — but the floating control pill is nudged inward by the island
            // width so it isn't hidden behind the cutout.
            VStack(spacing: 0) {
                if anyTop {
                    // Rail docked on chrome, centered over the viewport (the tool
                    // pills now live in the inspector header, not over the viewer).
                    topPaneRail(floating: false).background(themeChromeBg)
                    Rectangle().fill(hairlineColor).frame(height: 1)
                    if cTerm {
                        CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                        termResizeDivider(maxTerm: maxTerm)
                    }
                    if engine.sequenceVisible {
                        SequencePanel().frame(height: ipadSequenceHeight)
                        Rectangle().fill(hairlineColor).frame(height: 1)
                    }
                    if engine.interactionMode == .move { moveOverlay }
                    else if engine.measureMode != nil { measureOverlay }
                    else if engine.designMode { designModeBar }
                }
                viewportView
                    .overlay(alignment: .top) {
                        // Rail centered over the viewport.
                        if !anyTop { topPaneRail(floating: true) }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Open · Save · Export now live in the right inspector panel's header
            // (see inspectorSwitcher) — no longer floating over the viewport.
            // Vertical inspector tongue rides on the seam.
            .overlay(alignment: .trailing) {
                // Only when the inspector is CLOSED (tap to reopen); when open the
                // tongue straddles the seam from the panel side (below). Nudge it in
                // past the Dynamic Island when the island is on the RIGHT, so the
                // full-bleed viewport doesn't hide the tongue behind the cutout.
                if !showThemeStudio && !objectsBinding.wrappedValue {
                    panelTongue(shown: objectsBinding, axis: .vertical)
                        .padding(.trailing, islandOnRight ? notch : 0)
                }
            }

            if !iosFullScreen && (showThemeStudio || objectsBinding.wrappedValue) {
                // Hairline seam between viewport and inspector; the vertical tongue
                // (above) rides on it.
                Rectangle().fill(hairlineColor).frame(width: 1)
                // The panel column is narrowed by the notch on the island-on-RIGHT
                // side so it ends at the black stripe's left edge; .clipped()
                // guarantees nothing paints past it.
                if showThemeStudio {
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(width: panelW - (islandOnRight ? notch : 0), alignment: .leading)
                        .background(themeChromeBg)
                        .clipped()
                } else {
                    inspectorSwitcher()
                        .frame(width: panelW - (islandOnRight ? notch : 0), alignment: .leading)
                        .background(themeChromeBg)
                        .clipped()
                        // Tongue straddles the seam (centered on the hairline), drawn
                        // on top; overlay AFTER .clipped() so it isn't clipped away.
                        .overlay(alignment: .leading) {
                            panelTongue(shown: objectsBinding, axis: .vertical, seam: true)
                        }
                }

                // Island on the RIGHT: solid black letterbox over the cutout, filling the
                // reserved notch width to the window edge (full height via ignoresSafeArea).
                if islandOnRight && notch > 0 {
                    Color.black
                        .frame(width: notch)
                        .ignoresSafeArea(.container, edges: .all)
                }
            }
        }
    }

    // Floating tool pills for iPhone (nav bar hidden): Open · Save · Export. Used in
    // the portrait top row (beside the RayMol title) and the landscape inspector
    // header. Measure + Move live in the top rail; no full-screen toggle.
    @ViewBuilder
    private func iosToolPills() -> some View {
        HStack(spacing: 2) {
            Button { showFileImporter = true } label: {
                Image(systemName: "folder").frame(width: 42, height: 34)
            }
            .accessibilityLabel("Open")
            Button { iosSaveSession() } label: {
                Image(systemName: "arrow.down.doc").frame(width: 42, height: 34)
            }
            .accessibilityLabel("Save session")
            Menu { exportMenuContent } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 42, height: 34)
            }
            .accessibilityLabel("Export")
        }
        .tint(TimelineTheme.accent)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
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
        let rightW: CGFloat = 440                          // landscape side column (roomy for the Movie-tab transport)
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
        // Any top pane open? The rail docks on chrome above the panes; else it
        // floats over the full-bleed viewport. Move & Measure share the bottom slot.
        let anyTop = cTerm || engine.sequenceVisible
            || engine.interactionMode == .move || engine.measureMode != nil
            || engine.designMode

        if landscape {
            // LANDSCAPE (iPad + iPhone landscape): left stack (terminal/sequence/
            // viewport) beside a right side column (Objects + Raymond) — the Mac.
            // iPhone is full-bleed (ignoresSafeArea, for the immersive viewport),
            // so the floating top toolbar overlaps the panels — reserve top space
            // for the side panels there so the toolbar never hides the first
            // object / sequence row (iPad reserves the safe area already).
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if anyTop {
                        // Rail docked on chrome, panes opening under it.
                        topPaneRail(floating: false).background(themeChromeBg)
                        Rectangle().fill(hairlineColor).frame(height: 1)
                        if cTerm {
                            CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                            termResizeDivider(maxTerm: maxTerm)
                        }
                        if engine.sequenceVisible {
                            SequencePanel().frame(height: ipadSequenceHeight)
                            Rectangle().fill(hairlineColor).frame(height: 1)
                        }
                        // Move / Measure bar — bottom of the top stack, mutually
                        // exclusive, on matching chrome.
                        if engine.interactionMode == .move { moveOverlay }
                        else if engine.measureMode != nil { measureOverlay }
                        else if engine.designMode { designModeBar }
                    }
                    viewportView
                        // Collapsed: the rail floats over the full-bleed viewport.
                        .overlay(alignment: .top) {
                            if !anyTop { topPaneRail(floating: true) }
                        }
                    // Expanded timeline docks full-width under the viewport (the
                    // Movie tab's Expand button toggles engine.timelineMode).
                    if engine.timelineMode {
                        Divider()
                        TimelinePanel()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The vertical inspector tongue floats OVER the viewport's trailing
                // edge (transparent) so the VIEWER fills that space instead of a
                // reserved column — matching the portrait bottom tongue. Hidden while
                // Theme Studio is open (it docks directly with its own divider).
                .overlay(alignment: .trailing) {
                    // Closed → tongue on the viewport's trailing edge (tap to
                    // reopen); open → it straddles the seam via the inspector overlay.
                    if !showThemeStudio && !showRight {
                        panelTongue(shown: objectsBinding, axis: .vertical)
                    }
                }
                if showThemeStudio {
                    Divider()
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(width: rightW)
                        .background(themeChromeBg)
                } else if showRight {
                    Rectangle().fill(hairlineColor).frame(width: 1)
                    inspectorSwitcher()
                        .frame(width: rightW)
                        .background(themeChromeBg)
                        .overlay(alignment: .leading) {
                            panelTongue(shown: objectsBinding, axis: .vertical, seam: true)
                        }
                }
            }
        } else {
            // PORTRAIT (iPad): console + sequence ABOVE the viewer; Objects +
            // Raymond panel BELOW it (side-by-side, resizable).
            VStack(spacing: 0) {
                if anyTop {
                    // Docked top band: rail centered + Open/Save/Export trailing. The
                    // title is hidden when open, so panes open right under the rail.
                    topPaneRail(floating: false)
                        .overlay(alignment: .trailing) { iosToolPills().padding(.trailing, 8) }
                        .background(themeChromeBg)
                    Rectangle().fill(hairlineColor).frame(height: 1)
                    if cTerm {
                        CommandPanel(showInput: !RayMolBuild.iosRestricted).frame(height: clampedTermH)
                        termResizeDivider(maxTerm: maxTerm)
                    }
                    if engine.sequenceVisible {
                        SequencePanel().frame(height: ipadSequenceHeight)
                        Rectangle().fill(hairlineColor).frame(height: 1)
                    }
                    if engine.interactionMode == .move { moveOverlay }
                    else if engine.measureMode != nil { measureOverlay }
                    else if engine.designMode { designModeBar }
                }
                viewportView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Collapsed: the top band floats over the full-bleed viewport —
                    // RayMol (left) + rail (center) + Open/Save/Export (right). The
                    // title disappears once a pane opens (the docked band above).
                    .overlay(alignment: .top) {
                        if !anyTop {
                            topPaneRail(floating: true)
                                .overlay(alignment: .leading) {
                                    Text("RayMol")
                                        .font(.system(size: 26, weight: .bold))
                                        .foregroundColor(themeManager.active.panelText.color)
                                        .padding(.leading, 16)
                                }
                                .overlay(alignment: .trailing) { iosToolPills().padding(.trailing, 8) }
                        }
                    }
                    // Bottom inspector tongue rides the seam (only the chevron pill is
                    // hit-testable; the rest passes touches through to the viewport).
                    .overlay(alignment: .bottom) {
                        if !showThemeStudio && !showRight {
                            panelTongue(shown: objectsBinding, axis: .horizontal)
                        }
                    }
                // NOTE: the expanded timeline dock is LANDSCAPE-only. In portrait the
                // timeline is reached via the inspector's Movie tab (below); the
                // Expand button + nav-bar toggle are disabled here (isPadPortrait) and
                // the dock auto-closes on rotation into portrait.
                if showThemeStudio {
                    resizeDivider(landscape: false, total: geo.size.height)
                    ThemeStudioPanel(onClose: { withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = false } })
                        .environmentObject(engine)
                        .environmentObject(themeManager)
                        .frame(height: bottomH)
                        .background(themeChromeBg)
                } else if showRight {
                    // Hairline seam between viewport and the bottom inspector; the
                    // horizontal tongue (above) rides on it.
                    Rectangle().fill(hairlineColor).frame(height: 1)
                    inspectorSwitcher(hugContent: true)
                        .frame(height: inspectorPortraitHeight(total: geo.size.height))
                        .background(themeChromeBg)
                        .overlay(alignment: .top) {
                            panelTongue(shown: objectsBinding, axis: .horizontal, seam: true)
                        }
                        .onPreferenceChange(PaneHeightKey.self) { paneHeights = $0 }
                        .animation(.easeInOut(duration: 0.25), value: inspectorTab)
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
    // Thin themed seam between the viewport and docked panels / the inspector.
    private var hairlineColor: Color { themeManager.active.panelText.color.opacity(0.18) }

    // A small protruding "tongue" handle that shows/hides an adjacent inspector
    // panel. Horizontal (a wide little tab) when the panel docks at the bottom;
    // vertical when it docks on the trailing side. Tapping toggles `shown`; the
    // chevron points the way the panel will move. Stays visible when collapsed so
    // the panel can be pulled back. iPad (regular-width) layout only.
    @ViewBuilder
    private func panelTongue(shown: Binding<Bool>, axis: Axis, seam: Bool = false) -> some View {
        let isShown = shown.wrappedValue
        let chevron = axis == .horizontal
            ? (isShown ? "chevron.down" : "chevron.up")
            : (isShown ? "chevron.right" : "chevron.left")
        let tab = Button {
            withAnimation(.easeInOut(duration: 0.25)) { shown.wrappedValue.toggle() }
        } label: {
            Image(systemName: chevron)
                .font(.system(size: 10, weight: .bold))
                // Match the toggle pills exactly: OFF = subtle fill + outline; ON
                // (panel shown) = solid accent fill + white chevron, so the tongue
                // reads as a sibling of the rail pills and lights up when open.
                .foregroundColor(isShown ? .white : themeManager.active.panelText.color.opacity(0.82))
                .frame(width: axis == .horizontal ? 52 : 16,
                       height: axis == .horizontal ? 16 : 52)
                .background(
                    Capsule()
                        .fill(isShown ? TimelineTheme.accent : themeManager.active.panelText.color.opacity(0.14))
                        .overlay(Capsule().strokeBorder(isShown ? Color.clear : themeManager.active.panelText.color.opacity(0.5), lineWidth: 1))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isShown ? "Hide panel" : "Show panel")
        // Center the little tab within a thin full-width / full-height strip. Only
        // the chevron pill is hit-testable; the rest of the strip passes touches
        // through to the viewport. `seam` shifts the pill toward the viewport by half
        // its size so — when this tongue is attached to the OPEN inspector's near
        // edge (which paints on top) — the pill is centered ON the hairline seam.
        let strip = Group {
            if axis == .horizontal {
                tab.frame(maxWidth: .infinity).padding(.vertical, 1)
            } else {
                tab.frame(maxHeight: .infinity).padding(.horizontal, 1)
            }
        }
        return strip.offset(x: seam && axis == .vertical ? -9 : 0,
                            y: seam && axis == .horizontal ? -9 : 0)
    }

    // Design-mode docked bar for the iOS layouts. Resolves to EmptyView when the
    // feature is compiled out, so the mode chain in all four layouts can reference
    // it unconditionally. iPhone (compact width) gets the same overlay panel as
    // iPad for now — Task 11 swaps the compact branch to DesignCompactPanel.
    @ViewBuilder
    private var designModeBar: some View {
        #if RAYMOL_MPNN
        if hSize == .compact {
            DesignCompactPanel(controller: engine.designController,
                               engine: engine,
                               theme: themeManager)
        } else {
            DesignOverlayView(controller: engine.designController,
                              engine: engine,
                              theme: themeManager)
        }
        #else
        EmptyView()
        #endif
    }

    // The twin-tongue "seam rail" welded to the viewport's TOP edge (iPad). Mirrors
    // the bottom inspector tongue: two labeled pills in FIXED slots — Console (left)
    // + Sequence (right) — each toggling its own pane. Shown = accent fill + chevron
    // up (retract the pane up); hidden = muted outline + chevron down (drop it down).
    // Always drawn, so it's the permanent seam between the top pane-stack and the 3D
    // view — the top mirror of the bottom inspector tongue. iPad layout only.
    //
    // The pinned toggle rail: Console · Seq · Move · Measure · Design. `floating`
    // (nothing open) wraps the pills in a tight blur capsule that hugs them and floats
    // over the full-bleed viewport; when a panel is open the caller docks the rail on
    // matching panel chrome and passes floating:false (bare pills, no capsule).
    @ViewBuilder
    private func topPaneRail(floating: Bool = true, centered: Bool = true) -> some View {
        let pillRow = HStack(spacing: 8) {
            railTongue(icon: "terminal", label: "Console", shown: consoleBinding)
            // No icon — the word "Seq" IS the label. The old `textformat.abc` glyph
            // rendered as a literal "Abc", so the pill read "Abc Seq".
            railTongue(icon: nil, label: "Seq", shown: $engine.sequenceVisible)
            // Move / Measure / Design are mutually-exclusive interaction modes.
            // When RAYMOL_MPNN is active they are disabled while any MLX inference
            // runs so the user cannot silently discard an in-progress calculation.
            // In non-MPNN builds there is no Design mode, so no lock is needed.
            #if RAYMOL_MPNN
            HStack(spacing: 8) {
                railToggle(icon: "move.3d", label: "Move",
                           isOn: engine.interactionMode == .move,
                           action: { engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move) })
                railToggle(icon: "ruler", label: "Measure",
                           isOn: engine.measureMode != nil,
                           action: { engine.setMeasureMode(engine.measureMode == nil ? .distance : nil) })
                if DesignAvailability.isSupported {
                    railToggle(icon: "wand.and.stars", label: "Design",
                               isOn: engine.designMode,
                               action: { engine.setDesignMode(!engine.designMode) })
                }
            }
            .disabled(isDesignLocked)
            #else
            railToggle(icon: "move.3d", label: "Move",
                       isOn: engine.interactionMode == .move,
                       action: { engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move) })
            railToggle(icon: "ruler", label: "Measure",
                       isOn: engine.measureMode != nil,
                       action: { engine.setMeasureMode(engine.measureMode == nil ? .distance : nil) })
            #endif
        }
        .padding(.horizontal, floating ? 8 : 0)
        .padding(.vertical, floating ? 5 : 6)

        // floating → tight frosted capsule hugging the buttons; docked → bare pills
        // on the caller's chrome band. `centered` false left-aligns the row (iPhone
        // landscape, where the floating tool pills occupy the top-right).
        let styled = Group {
            if floating {
                pillRow
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            } else {
                pillRow
            }
        }
        return HStack(spacing: 0) {
            if centered { Spacer(minLength: 0) }
            styled
            Spacer(minLength: 0)
        }
    }

    // `icon` is optional: a tongue whose label already names the pane (Seq) shows the
    // word alone rather than pairing it with a redundant glyph.
    private func railTongue(icon: String?, label: String, shown: Binding<Bool>) -> some View {
        let on = shown.wrappedValue
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { shown.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                // Icon-only in iPhone landscape: the narrow viewport shares its top
                // with the floating Open/Save/Export pills, so labels won't fit. An
                // icon-less tongue keeps its label there — dropping it would leave
                // nothing but a chevron.
                if !isPhoneLandscape || icon == nil {
                    Text(label).font(.system(size: 11, weight: .medium))
                }
                Image(systemName: on ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(on ? .white : themeManager.active.panelText.color.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 16)
            .background(
                Capsule()
                    // OFF = a subtle filled capsule + clear outline so the hidden-pane
                    // pills read against the dark rail (were near-invisible at 0.4 text
                    // on transparent). ON = solid accent fill.
                    .fill(on ? TimelineTheme.accent : themeManager.active.panelText.color.opacity(0.14))
                    .overlay(Capsule().strokeBorder(on ? Color.clear : themeManager.active.panelText.color.opacity(0.5), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) pane, \(on ? "shown" : "hidden")")
    }

    // Same capsule as railTongue but chevron-less, driven by a Bool + action (for
    // mode toggles like Move) rather than a pane show/hide Binding. iPad rail only.
    private func railToggle(icon: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                if !isPhoneLandscape {
                    Text(label).font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(isOn ? .white : themeManager.active.panelText.color.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 16)
            .background(
                Capsule()
                    .fill(isOn ? TimelineTheme.accent : themeManager.active.panelText.color.opacity(0.14))
                    .overlay(Capsule().strokeBorder(isOn ? Color.clear : themeManager.active.panelText.color.opacity(0.5), lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) mode, \(isOn ? "on" : "off")")
    }

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

    // Move-mode toggle (iOS). Mirrors the measure ruler toggle.
    private var iosMoveToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            // iPhone (compact) only — iPad has the Move pill in the top rail
            // (topPaneRail); iPhone landscape floats its own Move control.
            if hSize == .compact {
                Button {
                    engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move)
                } label: {
                    Image(systemName: "move.3d")
                        .foregroundColor(engine.interactionMode == .move ? themeManager.active.accent.color : nil)
                }
                .accessibilityLabel("Move objects")
            }
        }
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

    // (sceneButtonsOverlay moved above, outside #if os(iOS), so macOS can use it.)

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
            // Debug bullseye (PYMOL_BULLSEYE=1): draws the gizmo hit-test targets +
            // a cursor bullseye so click↔selection mismatches are visible on screen.
            .overlay {
                if PyMOLEngine.bullseyeEnabled && engine.interactionMode == .move {
                    GizmoBullseyeOverlay(gizmo: engine.gizmo,
                                         cursorNDC: engine.bullseyeCursorNDC,
                                         hovered: engine.hoveredHandle)
                }
            }
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
            // (The Move-mode gizmo is a 3D CGO object rendered in the Metal scene
            // by metal_move.py; no SwiftUI overlay is needed.)
            // (The floating viewport transport was removed: movie playback lives in
            // the Movie tab, and multi-state model stepping lives in the Object panel.)
            // Opt-in glanceable scene buttons (Scenes tab → "Show scene buttons
            // in viewport"). Sits above the transport when a timeline is present.
            .overlay(alignment: .bottomLeading) {
                bottomLeadingViewportChrome
                    .padding(.leading, 12)
                    // Sit clear ABOVE the floating transport (only present when a
                    // movie exists and we're NOT in timeline mode).
                    .padding(.bottom, 12)
            }
            // Camera control dock: a bottom-docked icon strip (one control open at
            // a time). Same component on iPhone / iPad. Drag down or tap the chip
            // to dismiss.
            .overlay(alignment: .bottom) {
                if showCameraPanel && !engine.objects.isEmpty {
                    CameraDock(engine: engine, onClose: { withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false } })
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .gesture(DragGesture().onEnded { v in
                            if v.translation.height > 40 {
                                withAnimation(.easeOut(duration: 0.22)) { showCameraPanel = false }
                            }
                        })
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
                // Keep the help button clear of the floating transport (timeline mode
                // docks the panel elsewhere, so the viewport is clear then).
                .padding(.bottom, 0)
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
        // Track an opened .pse as the current document, so the Analysis Notes
        // store rebinds and surfaces the notes embedded in THAT session; a
        // non-.pse structure clears it. Without this the panel keeps the
        // previous note and stages it back over the opened session's payload.
        // Published after loadStructure, like macOpenFile / loadOpenedFile.
        engine.currentSessionURL = (ext.lowercased() == "pse") ? url : nil
    }

    // iPad export/share menu (the macOS Export menu lives in the window toolbar;
    // iPadOSLayout has its own NavigationStack toolbar). Renders the Metal frame
    // to a temp PNG/PSE via the shared engine, then copies to the pasteboard or
    // hands off to the system share sheet (Save to Files / Mail / AirDrop / …).
    // Primary entry into Timeline (movie studio) mode on iOS/iPadOS. Persistent
    // top-bar toggle, tinted when active; works before any movie exists.
    // Active when the timeline is showing: iPhone = the Movie tab is selected
    // (the tab bar navigates); iPad/desktop = the docked timelineMode is on.
    private var timelineToggleActive: Bool {
        hSize == .compact ? (selectedTab == 2) : engine.timelineMode
    }

    private var iosTimelineToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            // iPhone only: jumps to the Movie tab. On iPad the timeline lives in the
            // inspector's Movie tab (its Expand button opens the landscape dock), so
            // there is no top-bar clapperboard — the top-right is Console/Sequence/Export.
            if hSize == .compact {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = (selectedTab == 2) ? 1 : 2   // Movie tab hosts the timeline
                    }
                } label: {
                    Image(systemName: timelineToggleActive ? "clapperboard.fill" : "clapperboard")
                }
                .accessibilityLabel("Movie timeline")
                .tint(timelineToggleActive ? TimelineTheme.accent : nil)
            }
        }
    }

    // The Export menu's items — surfaced by iosToolPills() (Export button).
    @ViewBuilder private var exportMenuContent: some View {
        Menu {
            Button("Current View Size") { iosShareImage(scale: 1) }
            Button("2× View") { iosShareImage(scale: 2) }
            // 4K is memory-heavy (esp. ray-traced); skip it on iPhone where the
            // smaller RAM budget makes the export likely to be jettisoned.
            if hSize != .compact {
                Button("4K · 3840 × 2160") { iosShareImage(size: CGSize(width: 3840, height: 2160)) }
            }
        } label: {
            Label("Share Image", systemImage: "photo")
        }
        Button { iosCopyImage() } label: {
            Label("Copy Image", systemImage: "doc.on.clipboard")
        }
        // Export the authored movie; stays tappable even with no movie so it can
        // explain what's missing rather than silently doing nothing.
        Button {
            if engine.playback.frameCount <= 1 { showNoMovieAlert = true }
            else { showExportSheet = true }
        } label: {
            Label("Export Movie…", systemImage: "film")
        }
        #if os(iOS)
        if #available(iOS 16.4, *) {
            Menu { renderOptionToggles } label: {
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
        Menu {
            Button("PDB (.pdb)") { iosShareStructure(ext: "pdb") }
            Button("mmCIF (.cif)") { iosShareStructure(ext: "cif") }
            Button("SDF (.sdf)") { iosShareStructure(ext: "sdf") }
            Button("MOL (.mol)") { iosShareStructure(ext: "mol") }
            Button("MOL2 (.mol2)") { iosShareStructure(ext: "mol2") }
            Button("XYZ (.xyz)") { iosShareStructure(ext: "xyz") }
            Button("PQR (.pqr)") { iosShareStructure(ext: "pqr") }
            Divider()
            Button("VRML (.wrl)") { iosShareStructure(ext: "wrl") }
            Button("POV-Ray (.pov)") { iosShareStructure(ext: "pov") }
        } label: {
            Label("Share Structure", systemImage: "atom")
        }
        Button { iosShareSession() } label: {
            Label("Share Session (.pse)", systemImage: "doc.text")
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
            // Both opaque and transparent go through the METAL offscreen path (same
            // as macOS renderExportPNG): it honors ray_opaque_background (transparent
            // => the post chain rewrites alpha from coverage) and runs the full post
            // chain — including depth-of-field. The old transparent branch used the
            // CPU ray-tracer, which is slow and drops every Metal post-effect (DOF,
            // outline, tone-map). rtFlag still selects hardware-RT AO/shadows.
            engine.runCommand("set ray_opaque_background, \(exportTransparent ? 0 : 1)")
            engine.renderHiResPNG(url.path, width: width, height: height,
                                  rayTraced: exportRayTraced ? 1 : 0)
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
        notes.flush()
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(url.path)''')")
        if FileManager.default.fileExists(atPath: url.path) {
            presentShareSheet(url)
        }
    }

    // Dedicated Save: write the session .pse to a temp file, then present the
    // system document picker in export mode so the user can save it into Files /
    // iCloud. Distinct from Share (which routes through the activity sheet).
    private func iosSaveSession() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RayMol.pse")
        try? FileManager.default.removeItem(at: url)
        notes.flush()
        engine.runPython("from pymol import cmd as _c\n_c.save(r'''\(url.path)''')")
        guard FileManager.default.fileExists(atPath: url.path),
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        if let pop = picker.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(picker, animated: true)
    }

    // Present a UIActivityViewController from the top-most VC, anchored centered
    // (iPad requires a popover source or it throws). Avoids hosting the activity
    // controller inside a SwiftUI .sheet (which crashes without a source view).
    private func presentShareSheet(_ url: URL) {
        presentShareSheet([url])
    }

    private func presentShareSheet(_ urls: [URL]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let av = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }
    #endif

    // SF Symbols has no glyph for "sequence", and `textformat.abc` drew the word
    // "Abc" — it read as a text-formatting control, not the sequence viewer. The
    // macOS toolbar toggle therefore letters its own icon: the word "Seq". Declared
    // outside the iOS #if so the shared toolbar can use it.
    private var seqGlyph: some View {
        Text("Seq").font(.system(size: 11, weight: .semibold))
    }

    // The expanded-timeline dock's Expand button is disabled only in iPad portrait
    // (a landscape-only, iOS concept); always enabled on macOS. Declared outside the
    // iOS #if so the shared inspectorSwitcher can read it on both platforms.
    private var expandDockDisabled: Bool {
        #if os(iOS)
        return isPadPortrait
        #else
        return false
        #endif
    }

    // MARK: Regular-layout inspector switcher (iPad + macOS)
    //
    // The desktop/iPad right inspector mirrors the iPhone bottom tabs as a
    // segmented switcher: Objects · Scenes · Movie · Notes · Display. (Console is the
    // left terminal; Settings → the Display render card.) Each segment swaps in
    // an existing shared view — nothing is rebuilt. Works by touch (iPad) and
    // pointer (macOS); macOS menubar items are additive accelerators.
    @ViewBuilder
    private func inspectorSwitcher(hugContent: Bool = false) -> some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // LANDSCAPE only: RayMol heads the right inspector panel, with Open/Save/
            // Export aligned on the same row (nav bar is hidden, so this is their
            // home — iPhone AND iPad). In portrait the title lives in the top band.
            if !interfacePortrait {
                HStack {
                    Text("RayMol")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(themeManager.active.panelText.color)
                    Spacer(minLength: 0)
                    iosToolPills()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            #endif
            Picker("", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    #if os(iOS)
                    if hSize == .compact {
                        Image(systemName: tab.systemImage)
                            .accessibilityLabel(tab.rawValue)
                            .tag(tab)
                    } else {
                        Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                    }
                    #else
                    Label(tab.rawValue, systemImage: tab.systemImage).tag(tab)
                    #endif
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            HStack(spacing: 8) {
                Text(inspectorTab.blurb)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Clear selection + selection mode — here (shared chrome) so both
                // are reachable from every tab.
                ClearSelectionButton()
                SelectionModeMenu()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()
            // Model playback (Object-panel controls) is for inspecting an ensemble;
            // entering the Movie tab means authoring, so stop any inspection playback.
            switch inspectorTab {
            case .objects:
                ObjectPanel()
            case .scenes:
                ScenesPane(showViewportButtons: $showSceneButtons,
                           onOpenMovie: { inspectorTab = .movie })
            case .movie:
                // The right-panel timeline mimics the iPhone Movie tab; its Expand
                // button toggles the full-width bottom dock (engine.timelineMode) —
                // landscape-only, so it's disabled in iPad portrait (isPadPortrait).
                // forceCompact → the narrow iPhone-style layout that fits the column.
                let movie = TimelinePanel(showsDone: false,
                              onExpand: { withAnimation(.easeInOut(duration: 0.2)) { engine.timelineMode.toggle() } },
                              forceCompact: true,
                              expandDisabled: expandDockDisabled)
                if hugContent {
                    // Portrait bottom dock: hug intrinsic height + report it so the
                    // panel wraps tightly (matches the iPhone Movie tab spacing).
                    movie
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .reportPaneHeight(2)
                        .background(TimelineTheme.bar)
                } else {
                    // Landscape side column: fill the column height (top-aligned) so
                    // the area below the compact panel isn't transparent (desktop
                    // showing through) — the panel otherwise hugs its content.
                    movie
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(TimelineTheme.bar)
                }
            case .notes:
                NotesInspectorView()
            case .display:
                // The SCENE render card (bg/lighting/effects/ray); its
                // "All settings…" opens the shared searchable SettingsSheet. Theme
                // Studio lives here too (moved off the toolbar → matches iOS, where
                // Themes is under Settings).
                ScrollView {
                    VStack(spacing: 14) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showThemeStudio = true }
                        } label: {
                            Label("Theme Studio…", systemImage: "paintpalette")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        #if os(iOS)
                        // Reset / escape-hatch actions, re-homed here from the old
                        // iPhone Settings tab (recenter, reset effects, clear session).
                        // iOS-only: macOS reaches these from its menu bar, and
                        // showClearSessionConfirm is an iOS-only @State.
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
                            Label("Reset…", systemImage: "arrow.counterclockwise.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        #endif
                        SceneCard()
                        // Version footer. The only place a TestFlight tester can
                        // see WHICH beta they are on: betas share their marketing
                        // version with the release they were cut from (App Store
                        // Connect rejects a "-betaN" suffix in the version), so
                        // "1.9.1" alone is ambiguous and "1.9.1-beta27" is not.
                        AppVersionFooter()
                    }
                    .padding(12)
                }
            }
        }
        // Shared panel background so every tab (Objects / Scenes / Movie / Display)
        // matches. ObjectPanel/TimelinePanel paint their own opaque background on
        // top; the Scenes/Display ScrollViews are transparent, so without this they
        // fell through to the window's default chrome (a mismatched dark gray).
        .background(themeManager.active.panelBackground.color)
        // Auto-stop model/movie playback when entering the Movie tab or expanding
        // the timeline dock (you're authoring now, not inspecting the ensemble).
        .onChange(of: inspectorTab) { tab in
            if tab == .movie { engine.pause(); engine.stopAllObjectStates() }
        }
        .onChange(of: engine.timelineMode) { on in
            if on { engine.pause(); engine.stopAllObjectStates() }
        }
    }

    // MARK: - Toolbar

    // Always-available Open/Fetch (the empty-state CTA disappears once a
    // structure is loaded, so this keeps file-open reachable at all times).
    // macOS-only: references the NSOpenPanel/fetch-alert helpers, which don't
    // exist on iOS (iOS uses iosToolPills() + .fileImporter).
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

    private var macMeasureToolbar: some ToolbarContent {
        // Trailing, grouped with Move as the interaction tools (.primaryAction so it
        // sits in the trailing cluster on the right, not the leading edge).
        ToolbarItem(placement: .primaryAction) {
            Button {
                engine.setMeasureMode(engine.measureMode == nil ? .distance : nil)
            } label: {
                Label("Measure", systemImage: engine.measureMode == nil ? "ruler" : "ruler.fill")
            }
            .disabled(isDesignLocked)
            .help("Measure distance / angle / dihedral by tapping atoms")
        }
    }

    // Move-mode toggle (macOS). ⌃M also toggles it (see PyMOLApp commands).
    // .primaryAction (trailing) — grouped with Measure as the interaction tools,
    // and matching its neighbours' placement so SwiftUI doesn't insert a phantom
    // empty slot at a default/primaryAction boundary.
    private var macMoveToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move)
            } label: {
                Label("Move", systemImage: "move.3d")
                    .foregroundColor(engine.interactionMode == .move ? themeManager.active.accent.color : nil)
            }
            .disabled(isDesignLocked)
            .help("Move objects: drag the gizmo to translate / rotate the active object")
        }
    }

    // (Removed: macMovieToolbar. Timeline/movie mode is entered from the Movie
    // menu / ⌥⌘M. The toolbar button rendered as an unlabeled circle and toggled
    // movie mode unexpectedly, so it was removed.)

    #if RAYMOL_MPNN
    // Design-mode toggle (macOS). ⌃D also toggles it (see PyMOLApp commands).
    // .primaryAction (trailing) — grouped with Move/Measure as the interaction tools.
    private var macDesignToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                engine.setDesignMode(!engine.designMode)
            } label: {
                Label("Design", systemImage: engine.designMode ? "flask.fill" : "flask")
                    .foregroundColor(engine.designMode ? themeManager.active.accent.color : nil)
            }
            .disabled(isDesignLocked)
            .help("Design mode: score/color protein residues with MPNN")
        }
    }
    #endif

    // Timeline (movie studio) mode is entered from the Movie menu (⌥⌘M) and the
    // docked transport — there is no toolbar button for it (removed: its icon read
    // as an empty slot in the trailing cluster).

    // The three desktop panes as one consistent toggle group. NOTE the right panel
    // toggle is "Inspector" (sidebar icon), NOT "Objects" — Objects is now a SEGMENT
    // inside the inspector switcher, so the toolbar must not duplicate it.
    private var panelToggles: some ToolbarContent {
        // Explicit .primaryAction keeps these in the trailing cluster next to the
        // other primaryAction items (Timeline, Export, MCP status) so SwiftUI does
        // not insert a phantom empty slot at the default/primaryAction boundary.
        // Fallback if the phantom slot persists: wrap all four trailing items
        // (panelToggles + exportMenu + MCP status) in one ToolbarItemGroup(placement: .primaryAction).
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $showCommandPanel) {
                Label("Console", systemImage: "terminal")
            }
            Toggle(isOn: $engine.sequenceVisible) {
                Label {
                    Text("Sequence")
                } icon: {
                    seqGlyph
                }
            }
            .accessibilityLabel("Sequence")
            Toggle(isOn: $showObjectPanel) {
                Label("Inspector", systemImage: "sidebar.right")
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
                // ⌘C lives on the File-menu command (raymolCopyImage) so the
                // shortcut fires reliably; this toolbar button is for discoverability.
                Button {
                    copyImageToClipboard()
                } label: {
                    Label("Copy Image to Clipboard", systemImage: "doc.on.clipboard")
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
            notes.sessionDidSave(to: url)
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
        notes.sessionDidSave(to: url)
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
        notes.flush()
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(tmp)''')")
        let sessionURL = URL(fileURLWithPath: tmp)
        presentShare(items: [sessionURL])
    }

    private func presentShare(forFileAt path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        presentShare(items: [URL(fileURLWithPath: path)])
    }

    private func presentShare(items: [URL]) {
        guard !items.isEmpty else { return }
        guard let window = NSApp.keyWindow, let anchor = window.contentView else { return }
        let picker = NSSharingServicePicker(items: items)
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

    // Move-mode overlay bar (mirrors measureOverlay): Move/Rotate tool toggle,
    // active-object dropdown, live readout, reset, exit.
    private var moveOverlay: some View {
        HStack(spacing: 10) {
            Image(systemName: "move.3d")
                .foregroundColor(themeManager.active.accent.color)
            Menu {
                let names = engine.objects.filter { !$0.isSelection }.map { $0.name }
                if names.isEmpty {
                    Text("No objects loaded")
                } else {
                    ForEach(names, id: \.self) { n in
                        Button {
                            engine.setActiveMoveObject(n)
                        } label: {
                            if engine.activeMoveObject == n {
                                Label(n, systemImage: "checkmark")
                            } else {
                                Text(n)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "scope")
                    Text(engine.activeMoveObject ?? "Tap an object")
                        .lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.active.panelText.color)
            }

            // Adjust-frame controls: the toggle (macOS: also hold Shift) makes the
            // gizmo grey out and its controls re-anchor the frame (origin + tilt)
            // instead of moving the structure; reset snaps the frame back to the
            // automatic molecular center.
            Button { engine.adjustFrameToggle.toggle() } label: {
                Image(systemName: "gyroscope")
                    .foregroundColor(engine.adjustFrameActive
                        ? themeManager.active.accent.color
                        : themeManager.active.panelText.color)
            }
            .buttonStyle(.plain)
            .disabled(engine.activeMoveObject == nil)
            .help("Adjust the gizmo frame — drag to set its origin & tilt (or hold Shift). Moves the gizmo, not the structure.")

            Button { engine.resetGizmoFrame() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundColor(themeManager.active.panelText.color)
            }
            .buttonStyle(.plain)
            .disabled(engine.activeMoveObject == nil)
            .help("Reset the gizmo frame to the automatic center")

            Spacer(minLength: 0)

            Button { engine.resetActiveMovePosition() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundColor(themeManager.active.panelText.color)
            }
            .buttonStyle(.plain)
            .disabled(engine.activeMoveObject == nil)
            .help("Reset this object's position")

            Button { engine.setInteractionMode(.viewing) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(themeManager.active.panelText.color.opacity(0.6))
            }.buttonStyle(.plain).accessibilityLabel("Exit move mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(themeManager.active.panelBackground.color)
        .tint(themeManager.active.accent.color)
    }

    // MARK: - Initialization

    // Bottom-left viewport shortcut to the Camera overlay.
    private var cameraButton: some View {
        Button { withAnimation(.easeOut(duration: 0.22)) { showCameraPanel.toggle() } } label: {
            Image(systemName: "camera")
                .font(.system(size: 20))
                // Frosted disc (like the mouse-legend button / toolbars) so the chip
                // stays visible on any viewport background. The old translucent-white
                // fill vanished against bright, busy scenes (e.g. dense orange sticks).
                .foregroundStyle(showCameraPanel ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(showCameraPanel ? 0.5 : 0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera settings")
        .accessibilityIdentifier("camera")
    }

    // Bottom-left viewport chrome: optional scene buttons stacked above the camera
    // shortcut. Extracted into its own property so ContentView.body stays within
    // the Swift type-checker's complexity budget.
    @ViewBuilder
    private var bottomLeadingViewportChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showSceneButtons && !engine.sceneNames.isEmpty {
                sceneButtonsOverlay
            }
            if !engine.objects.isEmpty {
                cameraButton
            }
        }
    }

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
        // Dev/testing: suppress the first-boot theme picker so automated launches
        // land straight in the app (e.g. to screenshot a mode). Doesn't persist
        // the first-boot flag, so a normal launch still shows it once.
        // PYMOL_SKIP_FIRSTBOOT_THEME=1.
        if ProcessInfo.processInfo.environment["PYMOL_SKIP_FIRSTBOOT_THEME"] != nil { return }
        guard themeManager.firstBoot else { return }
        // Test affordance: suppress the one-time first-boot Theme Studio so a
        // screenshot/UI test that drives another sheet (e.g. What's New) isn't
        // fighting a second modal for the presentation slot. Still mark it done.
        if ProcessInfo.processInfo.environment["PYMOL_SKIP_FIRSTBOOT_THEME"] != nil {
            themeManager.markFirstBootDone()
            return
        }
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
    // engine is ready (chrome already reflects it via @Published `active`). When a
    // session is being restored/opened at this launch, SKIP the theme's render
    // toggles (metal_outline/raytrace/shadows) — the loaded .pse owns that state,
    // and re-asserting the theme here would clobber it (the theme apply fires on
    // the isReady onChange, i.e. AFTER the synchronous autosave restore).
    private func applyPersistedTheme() {
        themeManager.apply(engine: engine,
                           applyRenderToggles: !engine.suppressLaunchThemeRenderToggles)
        // Outline is off by default in RayMol 1.6.1 and no theme enables it.
        // Force it off unconditionally on launch — independent of the theme's
        // render-toggle suppression AND of the (historically flaky) compiled core
        // default — so a stale core / cached theme can never surface an outline
        // the user didn't ask for. Users can still enable it live (Display ▸
        // Effects); this only governs the default at launch.
        engine.runCommand("set metal_outline, 0")
        // Load ~/.raymolrc(.py) LAST, after the theme defaults above, so a
        // user's startup script can override them (e.g. a custom bg_color) —
        // matching vanilla PyMOL, where .pymolrc runs after all built-in
        // defaults are set. macOS-only (RayMol#225 left iOS as an open
        // question): there is no user-visible ~ on iOS to author an rc file in.
        #if os(macOS)
        loadRaymolrcOrOfferMigration()
        #endif
    }

    // This native app never goes through pymol.invocation's CLI argument
    // parsing, so a pre-existing ~/.pymolrc(.py) is otherwise silently
    // ignored (RayMol#225). The first time no ~/.raymolrc(.py) exists yet
    // and a ~/.pymolrc(.py) is found, ask before importing it rather than
    // copying it silently — the user may not want an old config carried
    // over, or may not recognize ~/.raymolrc if we create it behind their
    // back. Skips the prompt (and loads immediately) once either file
    // exists or the user has already answered once (~/.raymolrc.skip).
    //
    // macOS-only, for two reasons: homeDirectoryForCurrentUser is unavailable
    // on iOS, and more fundamentally a dotfile in ~ is a desktop concept —
    // iOS's ~ is the app container, which the user can neither see nor write
    // to, so an iOS build could only ever no-op here. RayMol#225 explicitly
    // left "whether iOS needs an equivalent (likely app-container-relative)"
    // as an open question; it is deliberately still open.
    #if os(macOS)
    private func loadRaymolrcOrOfferMigration() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let hasRaymolrc = fm.fileExists(atPath: home + "/.raymolrc.py")
            || fm.fileExists(atPath: home + "/.raymolrc")
        let alreadyAsked = fm.fileExists(atPath: home + "/.raymolrc.skip")
        let hasPymolrc = fm.fileExists(atPath: home + "/.pymolrc.py")
            || fm.fileExists(atPath: home + "/.pymolrc")
        if !hasRaymolrc && !alreadyAsked && hasPymolrc {
            showRaymolrcMigrationPrompt = true
            return
        }
        loadRaymolrcAndAudit()
    }

    private func confirmRaymolrcMigration() {
        loadRaymolrcAndAudit(migrateFirst: true)
    }

    // ~/.raymolrc may bind a key RayMol also uses as a menu shortcut; the audit
    // says so once, right after the script runs (#258). ⌃D only exists in
    // RAYMOL_MPNN builds, so tell the audit whether the Design menu is present
    // rather than making Python guess.
    private func loadRaymolrcAndAudit(migrateFirst: Bool = false) {
        #if RAYMOL_MPNN
        let hasDesign = "True"
        #else
        let hasDesign = "False"
        #endif
        // Load first in its own call so a stale raymol_keys import can never
        // abort the rc load (#258 review note).
        let migrate = migrateFirst ? "_raymolrc.migrate(); " : ""
        engine.runPython(
            "from pymol import raymolrc as _raymolrc; "
            + migrate
            + "_raymolrc.load()")
        engine.runPython(
            "from pymol import raymol_keys as _raymol_keys; "
            + "_raymol_keys.audit_shadowed(has_design=\(hasDesign))")
    }

    private func declineRaymolrcMigration() {
        engine.runPython("from pymol import raymolrc as _raymolrc; _raymolrc.decline_migration()")
    }

    private var raymolrcMigrationAlertText: Text {
        Text("RayMol found an existing ~/.pymolrc and can copy it to ~/.raymolrc, RayMol's own startup script, so your customizations still run here.")
    }
    #endif
}

#if RAYMOL_MPNN
// MARK: – Design feature constants

/// Pinned-residue accent color: warm gold/orange, visually distinct from the
/// hover (subtle neutral grey) and the standard accent. Used in the 2-row
/// sequence strip column (Feature 11) and the residue badge chip.
private let designPinnedColor = Color(red: 0.98, green: 0.60, blue: 0.10)

// MARK: – 2-row Design Sequence Strip (Features 10 + 11)

/// Compact horizontally-scrollable strip, one column per residue of the focus
/// object's residue list.
///   Top row:    parent (native) 1-letter code in MPNN alphabet order.
///   Bottom row: edited 1-letter code in the accent color when the residue has
///               been mutated (differs from the native aa), blank otherwise.
///
/// Hover on a column calls the controller's shared setHovered(chain:resi:) /
/// clearHover() path — the same setters the 3D viewport hover uses — so the
/// propensity pills, the residue badge, and the hover sidechain sticks all
/// react identically to hovering here vs. mousing over the structure.
///
/// Tapping a column calls setPinned(chain:resi:), the same path as a viewport
/// click-to-pin, so clicking here pins the same way as clicking in the scene.
///
/// Feature 11: the PINNED column gets a persistent gold/orange border + fill;
/// the HOVERED column gets a transient subtle-grey fill.
// Internal (not private) so DesignCompactPanel.swift can reference it.
struct DesignSequenceStripView: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                seqCols
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
    }

    // Extracted @ViewBuilder so the ForEach body is not nested inside the
    // ScrollView closure — avoids the Swift type-checker "reasonable time" limit.
    @ViewBuilder
    private var seqCols: some View {
        ForEach(Array(controller.focusResidues.enumerated()), id: \.offset) { i, res in
            seqColumn(index: i, residue: res)
        }
    }

    @ViewBuilder
    private func seqColumn(index i: Int, residue: DesignResidue) -> some View {
        let alpha     = DesignColor.mpnnAlphabet
        let editedAA  = i < controller.editedSequence.count
                            ? controller.editedSequence[i] : residue.aa
        let isPinned  = controller.pinnedResidueIndex == i
        let isHovered = controller.hoveredResidueIndex == i
        let parent    = residue.aa >= 0 && residue.aa < alpha.count
                            ? alpha[residue.aa] : "?"
        let isEdit    = editedAA != residue.aa
        let edited    = (isEdit && editedAA >= 0 && editedAA < alpha.count)
                            ? alpha[editedAA] : ""

        VStack(spacing: 0) {
            // Top row: parent (native) AA
            Text(parent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isPinned
                    ? designPinnedColor
                    : theme.active.panelText.color.opacity(0.80))
                .frame(width: 14, height: 14, alignment: .center)
            // Bottom row: edited AA in accent color, or blank when unmutated
            Text(isEdit ? edited : "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.active.accent.color)
                .frame(width: 14, height: 14, alignment: .center)
        }
        .frame(width: 14)
        .padding(.vertical, 1)
        .background(
            isPinned  ? designPinnedColor.opacity(0.18)
          : isHovered ? theme.active.panelText.color.opacity(0.10)
          : Color.clear,
            in: RoundedRectangle(cornerRadius: 2)
        )
        .overlay(
            isPinned
                ? RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(designPinnedColor, lineWidth: 1.0)
                : nil
        )
        .overlay(alignment: .bottom) {
            if controller.selectedResidueIndices.contains(i) {
                Rectangle()
                    .fill(theme.active.accent.color)
                    .frame(height: 2)
            }
        }
        // Keep the column 14 pt wide visually. Grow the hit target vertically only:
        // a horizontal inset (the original approach) made each column's contentShape
        // overlap its neighbour's glyph, causing the front-to-back HStack hit-test
        // to route taps on the right half of column i to residue i+1. Vertical-only
        // growth via .padding(.vertical) stays within the 14 pt frame width and does
        // not shift any horizontal neighbour. The transparent padding is clipped by
        // the ScrollView so it never changes the strip's visible appearance.
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                controller.setHovered(chain: residue.chain, resi: residue.resi)
            } else {
                controller.clearHover()
            }
        }
        // macOS keeps shift-click as a shortcut for building an ad-hoc region.
        // `TapGesture().modifiers(_:)` is unavailable on iOS — this was the single
        // iOS compile error in the whole Design feature. The cross-platform path is
        // controller.regionEditMode, which a plain tap honours (see tapResidue).
        //
        // The shift gesture is DISABLED while regionEditMode is on: in that mode a
        // plain tap already toggles the region, so leaving both active would make
        // correctness depend on SwiftUI suppressing one of them. If it ever failed to,
        // the position would be toggled twice — added then removed — a silent no-op.
        #if os(macOS)
        .highPriorityGesture(
            TapGesture().modifiers(.shift).onEnded {
                controller.toggleRegionResidue(residueIndex: i)
            },
            including: controller.regionEditMode ? .subviews : .all
        )
        #endif
        .onTapGesture {
            controller.tapResidue(residueIndex: i)
        }
        .help({
            var tip = residue.chain.isEmpty ? residue.resi : "\(residue.chain)/\(residue.resi)"
            if !residue.resn.isEmpty { tip += " \(residue.resn)" }
            if isEdit { tip += " → \(edited)" }
            return tip
        }())
    }
}

// MARK: – Region-redesign strip (Phase 2c)

// Selection dropdown + Redesign/Revert + "Redesigning region…" spinner. Its own
// View struct so @ObservedObject re-renders on region-state @Published changes.
private struct DesignRegionStripView: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager
    @State private var showPicker = false

    var body: some View {
        Group {
            if controller.isRedesigning {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Redesigning region…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                controls
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            selectionButton
            stripDivider
            regionEditToggle
            if controller.regionModeActive {
                stripDivider
                Text("palette \(controller.paletteAllowed.filter { $0 < 20 }.count)/20")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
                stripDivider
                temperatureControl
                stripDivider
                redesignButton
            }
            if controller.redesignSnapshot != nil {
                stripDivider
                Button { controller.revertRedesign() } label: {
                    Text("Revert redesign")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Undo the last region redesign (keeps earlier manual edits)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var selectionButton: some View {
        Button {
            controller.refreshSelections()
            showPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "lasso").font(.system(size: 10))
                Text(controller.selectedSelectionName ?? "Select region…")
                    .font(.system(size: 11)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundColor(theme.active.panelText.color.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(theme.active.panelText.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPicker) {
            DesignSelectionPicker(controller: controller,
                                  fontSize: 12,
                                  minWidth: 190,
                                  dismiss: { showPicker = false })
                .presentationCompactAdaptation(.popover)
        }
    }

    // Explicit region-building mode: while on, a plain tap on a sequence column or
    // in the viewport adds/removes that position. This is the touch replacement for
    // shift-click, and the discoverable path on macOS too.
    private var regionEditToggle: some View {
        Button {
            controller.regionEditMode.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.regionEditMode
                        ? "hand.tap.fill" : "hand.tap")
                    .font(.system(size: 10))
                Text("Tap to edit")
                    .font(.system(size: 11,
                                  weight: controller.regionEditMode ? .semibold : .regular))
            }
            .foregroundColor(controller.regionEditMode
                             ? .white : theme.active.panelText.color.opacity(0.85))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(controller.regionEditMode
                        ? theme.active.accent.color
                        : theme.active.panelText.color.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Build a region by tapping positions in the sequence or the structure")
        .accessibilityLabel("Tap to edit region, \(controller.regionEditMode ? "on" : "off")")
    }

    // Prominent call-to-action: solid accent fill + icon so it clearly invites a click.
    private var redesignButton: some View {
        let disabled = controller.paletteAllowed.filter { $0 < 20 }.isEmpty
        return Button { controller.redesignSelection() } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars").font(.system(size: 10, weight: .semibold))
                Text("Redesign selection · \(controller.selectedResidueIndices.count) res")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(disabled ? theme.active.panelText.color.opacity(0.25)
                                 : theme.active.accent.color,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help("Redesign the selected residues; the rest of the sequence is held fixed")
    }

    // Sampling-temperature slider: 0 = greedy (most likely), higher = more diverse.
    private var temperatureControl: some View {
        HStack(spacing: 5) {
            Text("temp").font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.active.panelText.color.opacity(0.5))
            Slider(value: $controller.designTemperature, in: 0...1)
                .frame(width: 72)
                .controlSize(.mini)
            Text(String(format: "%.2f", controller.designTemperature))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.active.panelText.color.opacity(0.65))
                .frame(width: 26, alignment: .leading)
        }
        .help("Sampling temperature: 0 = most likely (greedy), higher = more variation each run")
    }

    private var stripDivider: some View {
        Rectangle().fill(theme.active.panelText.color.opacity(0.2)).frame(width: 0.5, height: 14)
    }
}

// MARK: – Edit-session strip

// Edit-session strip: Auto-repack toggle, needs-repack indicator, compare toggle,
// Keep/Discard, and a readout. Extracted into a dedicated View struct so
// @ObservedObject controller re-renders on every @Published change from the
// edit session (editing, editCount, repackDirty, isRepacking, compareEnabled).
private struct DesignEditStripView: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager

    var body: some View {
        Group {
            if controller.isRepacking {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Repacking sidechains…")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                editControls
            }
        }
    }

    private var editControls: some View {
        HStack(spacing: 8) {
            // ── Auto-repack (always available — a preference for future edits) ──
            Toggle(isOn: $controller.autoRepack) {
                Text("Auto-repack")
                    .font(.system(size: 11))
                    .foregroundColor(theme.active.panelText.color.opacity(0.8))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Automatically repack sidechains after each mutation")

            stripDivider

            // ── Needs-repack indicator + button (disabled until edits are dirty) ──
            Button { controller.repackNow() } label: { repackBadge }
                .buttonStyle(.plain)
                .disabled(!controller.repackDirty || controller.isRepacking)
                .help("Repack sidechains to optimize the current sequence")

            stripDivider

            // ── Sidechains toggle (works on the focused object, edit or not) ──
            Toggle(isOn: Binding(
                get: { controller.showSidechains },
                set: { controller.setShowSidechains($0) }
            )) {
                Text("Sidechains")
                    .font(.system(size: 11))
                    .foregroundColor(theme.active.panelText.color.opacity(0.8))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Show all sidechain sticks (carbons colored by confidence, heteroatoms by element)")

            // ── Compare (needs a working copy — only during an edit session) ──
            if controller.editing {
                stripDivider
                Toggle(isOn: Binding(
                    get: { controller.compareEnabled },
                    set: { controller.setCompare($0) }
                )) {
                    Text("Compare")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.8))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show original structure alongside the edited working copy")

                // Side-by-side toggle (visible + enabled only when compare is on).
                if controller.compareEnabled {
                    stripDivider
                    Toggle(isOn: Binding(
                        get: { controller.sideBySide },
                        set: { controller.setSideBySide($0) }
                    )) {
                        Text("Side-by-side")
                            .font(.system(size: 11))
                            .foregroundColor(theme.active.panelText.color.opacity(0.8))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Grid view: original and design shown in separate panels with own colors (off = overlap, grey ghost)")
                }
            }

            Spacer(minLength: 0)

            // ── Session-only: edit-count readout + Keep / Discard ─────────────
            if controller.editing {
                if let name = controller.workingObject {
                    Text("\(name) · \(controller.editCount) \(controller.editCount == 1 ? "edit" : "edits")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.active.panelText.color.opacity(0.45))
                        .lineLimit(1)
                    stripDivider
                }

                Button {
                    Task { await controller.keepEditsAwait() }
                } label: {
                    Text("Keep")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(theme.active.accent.color.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundColor(theme.active.accent.color)
                }
                .buttonStyle(.plain)

                Button { controller.discardEdits() } label: {
                    Text("Discard")
                        .font(.system(size: 11))
                        .foregroundColor(theme.active.panelText.color.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // Needs-repack pill: accented when dirty (shows edit count), dim otherwise.
    private var repackBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
            Text(controller.repackDirty
                 ? "Repack (\(controller.editCount))"
                 : "Repack")
                .font(.system(size: 11))
        }
        .foregroundColor(controller.repackDirty
                         ? theme.active.accent.color
                         : theme.active.panelText.color.opacity(0.4))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(controller.repackDirty
                    ? theme.active.accent.color.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(theme.active.panelText.color.opacity(0.2))
            .frame(width: 0.5, height: 14)
    }
}

// Error banner for Design mode. `errorText` was previously written in six places
// in DesignController and read nowhere, so every Design failure was silent —
// including a missing weight pack, which is the first thing that goes wrong on a
// new platform. Tap or wait to dismiss.
#if RAYMOL_MPNN
struct DesignErrorBanner: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager

    var body: some View {
        if let text = controller.errorText {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(text)
                    .font(.system(size: 11))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.red.opacity(0.85))
            .contentShape(Rectangle())
            .onTapGesture { controller.clearError() }
            .task(id: text) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                controller.clearError()
            }
            .accessibilityLabel("Design error: \(text). Tap to dismiss.")
        }
    }
}
#endif

// MARK: – Propensity / palette pill row (shared by macOS/iPad overlay and iPhone compact panel)

/// Scrollable row of 20 amino-acid pills shown below the sequence strip.
///
/// In region mode (controller.regionModeActive == true) each pill is an
/// active/inactive toggle that adds or removes an amino acid from the redesign
/// palette — tapping a pill calls controller.togglePalette(_:).
///
/// In hover/pin mode each pill shows the model's propensity for that amino acid
/// at the active residue; tapping calls applyMutationAwait to commit the mutation.
/// When no residue is active every pill renders greyed/disabled so the row
/// stays in the layout without appearing and disappearing.
///
/// Extracted from DesignOverlayView so DesignCompactPanel (iPhone) can reuse it
/// without duplicating the logic. DesignOverlayView now delegates to this struct.
struct DesignPillRow: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var theme: ThemeManager

    var body: some View {
        if controller.regionModeActive {
            paletteRow()
        } else {
            propensityScrollRow()
        }
    }

    // MARK: – Propensity row

    private func propensityScrollRow() -> some View {
        let ap = controller.activePropensity
        let rowMax = ap?.propensities.max() ?? 1.0
        let activeIndex = controller.activeResidueIndex
        let currentAA: Int = {
            if let idx = activeIndex, controller.editing,
               idx < controller.editedSequence.count {
                return controller.editedSequence[idx]
            }
            return ap?.nativeAA ?? -1
        }()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    let hasVal = ap != nil && i < (ap?.propensities.count ?? 0)
                    Button {
                        if let idx = activeIndex {
                            Task { await controller.applyMutationAwait(residueIndex: idx, aa: i) }
                        }
                    } label: {
                        aaPill(index: i,
                               propensity: hasVal ? ap!.propensities[i] : 0,
                               isCurrent: ap != nil && i == currentAA,
                               rowMax: rowMax,
                               enabled: ap != nil)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 5)
    }

    private func aaPill(index: Int,
                        propensity: Float,
                        isCurrent: Bool,
                        rowMax: Float,
                        enabled: Bool) -> some View {
        let letter = index < DesignColor.mpnnAlphabet.count
            ? DesignColor.mpnnAlphabet[index] : "?"
        let intensity = (enabled && rowMax > 0) ? Double(propensity / rowMax) : 0.0
        let showCurrent = enabled && isCurrent
        let pillBG: Color = !enabled
            ? theme.active.panelText.color.opacity(0.04)
            : (showCurrent
                ? theme.active.accent.color
                : theme.active.panelText.color.opacity(0.04 + intensity * 0.22))
        let pillFG: Color = !enabled
            ? theme.active.panelText.color.opacity(0.28)
            : (showCurrent
                ? .white
                : theme.active.panelText.color.opacity(0.6 + intensity * 0.4))
        let valueText: String = {
            if !enabled { return ".0" }
            let s = String(format: "%.2f", propensity)
            return s.hasPrefix("0") ? String(s.dropFirst()) : s
        }()
        return VStack(spacing: 1) {
            Text(letter)
                .font(.system(size: 11,
                              weight: showCurrent ? .bold : .regular,
                              design: .monospaced))
            Text(valueText)
                .font(.system(size: 9, design: .monospaced))
        }
        .foregroundColor(pillFG)
        .frame(width: 30, height: 36)
        .background(pillBG, in: RoundedRectangle(cornerRadius: 5))
        .overlay(
            showCurrent
                ? RoundedRectangle(cornerRadius: 5)
                    .stroke(theme.active.accent.color, lineWidth: 1.5)
                : nil
        )
    }

    // MARK: – Palette row (region mode)

    private func paletteRow() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    Button { controller.togglePalette(i) } label: {
                        palettePill(index: i, active: controller.paletteAllowed.contains(i))
                    }
                    .buttonStyle(.plain)
                    .help(controller.paletteAllowed.contains(i)
                          ? "Allowed during redesign — click to exclude"
                          : "Excluded from redesign — click to allow")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 5)
    }

    private func palettePill(index i: Int, active: Bool) -> some View {
        let letter = i < DesignColor.mpnnAlphabet.count ? DesignColor.mpnnAlphabet[i] : "?"
        return Text(letter)
            .font(.system(size: 12, weight: active ? .bold : .regular, design: .monospaced))
            .foregroundColor(active ? .white : theme.active.panelText.color.opacity(0.32))
            .frame(width: 30, height: 36)
            .background(active
                        ? theme.active.accent.color.opacity(0.85)
                        : theme.active.panelText.color.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(active ? theme.active.accent.color : Color.clear, lineWidth: 1))
    }
}

// Design mode overlay bar (mirrors measureOverlay/moveOverlay): focus-object name,
// coloring meaning segmented control, legend gradient, scoring progress, ? help.
// Extracted into a dedicated View struct so @ObservedObject controller: DesignController
// causes re-renders on every @Published change (colorMeaning, isScoring, focusObject,
// legendDomain) — ContentView itself never re-renders for nested-OO changes.
private struct DesignOverlayView: View {
    @ObservedObject var controller: DesignController
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager
    @State private var showModeHelp = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Error banner (only when something failed) ───────────────
            DesignErrorBanner(controller: controller, theme: theme)
            // ── Main control strip ──────────────────────────────────────
            HStack(spacing: 10) {
                focusLabel
                if let s = controller.sequenceScore {
                    Text(String(format: "score %.2f", s))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.active.panelText.color.opacity(0.55))
                        .help("Mean per-residue native-fit log-probability (higher = better fit)")
                }
                residueIndicator
                if controller.isScoring || controller.isRescoring {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer(minLength: 0)
                meaningPicker
                legendBar
                    .help("Per-residue confidence; domain shown at the ends")
                helpButton
                Button {
                    engine.setDesignMode(false)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(theme.active.panelText.color.opacity(0.6))
                }.buttonStyle(.plain).accessibilityLabel("Exit design mode")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            // ── 2-row sequence strip (Feature 10) ────────────────────────────
            // Shown once residues are available; hidden until first focus completes.
            if !controller.focusResidues.isEmpty {
                Divider().opacity(0.3)
                DesignSequenceStripView(controller: controller, theme: theme)
            }
            // ── Propensity / palette pill row (always present; greyed when no
            //    residue is hovered/pinned so it no longer flickers in and out) ─
            Divider().opacity(0.3)
            DesignPillRow(controller: controller, theme: theme)
            // ── Region-redesign strip (Phase 2c) ─────────────────────────────
            if !controller.focusResidues.isEmpty {
                Divider().opacity(0.3)
                DesignRegionStripView(controller: controller, theme: theme)
            }
            // ── Control strip (always visible once an object is focused; the
            //    session-only controls inside it appear when editing begins) ──
            if !controller.focusResidues.isEmpty {
                Divider().opacity(0.3)
                DesignEditStripView(controller: controller, theme: theme)
            }
        }
        .background(theme.active.panelBackground.color)
        .tint(theme.active.accent.color)
    }

    // Active-residue indicator, shown just to the right of the object name:
    // the residue label (e.g. "A/96 PHE") plus a pin glyph when the residue is
    // pinned. Pinned = gold/orange special color (Feature 11); hover-only = neutral.
    // Empty when nothing is hovered or pinned (no layout jump).
    private var residueIndicator: some View {
        Group {
            if let ap = controller.activePropensity {
                let pinned = controller.pinnedResidueIndex != nil
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(designPinnedColor)
                    }
                    Text(ap.label)
                        .lineLimit(1)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(pinned
                            ? designPinnedColor
                            : theme.active.panelText.color.opacity(0.85))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(pinned
                    ? designPinnedColor.opacity(0.12)
                    : theme.active.panelText.color.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // Focus-object indicator is a dropdown: click a structure in the viewport OR
    // pick one here. Lists the objects the controller can focus; current is checked.
    private var focusLabel: some View {
        Menu {
            ForEach(controller.allObjects, id: \.self) { obj in
                Button {
                    controller.focus(obj)
                } label: {
                    if obj == controller.focusObject {
                        Label(obj, systemImage: "checkmark")
                    } else {
                        Text(obj)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "atom")
                    .foregroundColor(theme.active.accent.color)
                Text(controller.focusObject ?? "Select object to design")
                    .lineLimit(1)
                    .font(.system(size: 12, weight: controller.focusObject != nil ? .semibold : .regular))
                    .foregroundColor(controller.focusObject != nil
                        ? theme.active.panelText.color
                        : theme.active.panelText.color.opacity(0.6))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(theme.active.panelText.color.opacity(0.5))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(controller.allObjects.isEmpty)
    }

    // Two-button toggle visually equivalent to a segmented control but with per-mode
    // .help() tooltips — Picker(.segmented) doesn't reliably surface per-segment
    // tooltips on macOS since the control draws its own chrome.
    private var meaningPicker: some View {
        HStack(spacing: 1) {
            Button { controller.setMeaning(.nativeFit) } label: {
                Text(DesignColorMeaning.nativeFit.label)
                    .font(.system(size: 13))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(controller.colorMeaning == .nativeFit
                        ? theme.active.accent.color.opacity(0.25)
                        : Color.clear)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Native-fit: the model's log-probability for each residue's current amino acid given the rest of the structure (leave-one-out). Low = the model disfavors this residue here — a candidate to mutate.")

            Button { controller.setMeaning(.certainty) } label: {
                Text(DesignColorMeaning.certainty.label)
                    .font(.system(size: 13))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(controller.colorMeaning == .certainty
                        ? theme.active.accent.color.opacity(0.25)
                        : Color.clear)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Certainty: how strongly the model prefers a single amino acid at each position (1 − normalized entropy of its prediction). High = structurally constrained; low = many residues plausible.")
        }
        .background(theme.active.panelBackground.color.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.active.panelText.color.opacity(0.2), lineWidth: 0.5))
        .cornerRadius(7)
        .frame(maxWidth: 180)
    }

    private var legendBar: some View {
        Group {
            if let dom = controller.legendDomain {
                HStack(spacing: 4) {
                    Text(String(format: "%.1f", dom.lowerBound))
                        .font(.system(size: 10)).foregroundColor(theme.active.panelText.color.opacity(0.7))
                    LinearGradient(
                        colors: controller.colorMeaning == .nativeFit
                            ? [.red, .white, .blue]
                            : [.blue, .white, .red],
                        startPoint: .leading, endPoint: .trailing)
                    .frame(width: 60, height: 10)
                    .cornerRadius(3)
                    Text(String(format: "%.1f", dom.upperBound))
                        .font(.system(size: 10)).foregroundColor(theme.active.panelText.color.opacity(0.7))
                }
            }
        }
    }

    // "?" button that pops a brief description of both coloring modes — click-triggered,
    // reliable on macOS (hover .help() is inconsistent across system versions).
    private var helpButton: some View {
        Button { showModeHelp.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .foregroundColor(theme.active.panelText.color.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Design mode help")
        .popover(isPresented: $showModeHelp) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Native fit")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Log-probability of each residue's current amino acid given the rest of the structure (leave-one-out). Low = the model would rather mutate it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Certainty")
                        .font(.system(size: 13, weight: .semibold))
                    Text("How strongly the model prefers a single amino acid at that position (1 − normalized entropy). High = structurally constrained; low = many plausible.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(width: 260)
            .presentationCompactAdaptation(.popover)
        }
    }

}
#endif

#if RAYMOL_MPNN
// Input-blocking overlay for Design-mode inference (redesign / repack).
//
// This MUST be its own View holding the controller as @ObservedObject.
// ContentView observes only `engine`, and DesignController is a NESTED
// ObservableObject — its @Published changes do NOT re-render the parent. Driving
// the overlay from ContentView left it on screen after the work had finished
// (flag already false), blocking input until some unrelated engine change
// happened to force a redraw.
private struct DesignBusyOverlayView: View {
    @ObservedObject var controller: DesignController

    var body: some View {
        if let label = controller.designBusyLabel {
            CalculatingOverlay(label: label)
        }
    }
}
#endif

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
