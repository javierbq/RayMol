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
    // Surface the AI chat in the right column by default (the toolbar toggle can
    // hide it). The backend is wired to the headless ai_chat_swift sink.
    @State private var showChatPanel = true

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
    private var macOSLayout: some View {
        // Sequence height cap: 1–5 sequence rows (~26pt each + 8pt padding) so the
        // strip can't grow into the viewport. minHeight is set a few pt below the
        // cap so the VSplitView still hands the user a draggable splitter (a strict
        // min == max would freeze it).
        let seqRows = min(max(engine.sequences.count, 1), 5)
        let seqH = CGFloat(seqRows) * 26 + 8

        return HSplitView {
            // Left column: terminal on TOP, sequence directly under it, then the
            // 3D viewport, stacked in a VSplitView so each is drag-resizable and
            // each is hideable via the toolbar toggles.
            VSplitView {
                if showCommandPanel {
                    CommandPanel()
                        .frame(minHeight: 44, idealHeight: 80, maxHeight: 300)
                }

                if engine.sequenceVisible {
                    SequencePanel()
                        .frame(minHeight: 24, idealHeight: seqH, maxHeight: seqH)
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
                        // Mouse-mode legend as a compact floating card at the
                        // bottom-trailing corner, so it's reachable even when the
                        // right column is collapsed (where MousePanel used to live).
                        .overlay(alignment: .bottomTrailing) {
                            MousePanel()
                                .frame(width: 220)
                                .background(.ultraThinMaterial,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                                .padding(8)
                        }
                    if engine.hasTimeline {
                        Divider()
                        TransportBar()
                    }
                }
                // Empty-state CTA when nothing is loaded (mirrors the iOS overlay).
                .overlay { if engine.objects.isEmpty { macEmptyState } }
            }

            // Right column: objects + (chat). Only exists (and only occupies its
            // 300pt width) when at least one of its panels is shown — when both are
            // off the HSplitView collapses to just the left column. The mouse
            // legend moved to the floating viewport overlay (above) so it stays
            // reachable regardless.
            if showObjectPanel || showChatPanel {
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
                }
                .frame(width: 300)
            }
        }
        .overlay { busyOverlay }
        .alert("Fetch from PDB", isPresented: $showMacFetch) {
            TextField("PDB ID (e.g. 1ubq)", text: $macFetchID)
            Button("Fetch") { macFetch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Download a structure from the RCSB PDB.")
        }
        .toolbar {
            exportMenu
            ToolbarItem {
                Button {
                    engine.setMeasureMode(engine.measureMode == nil ? .distance : nil)
                } label: {
                    Label("Measure", systemImage: engine.measureMode == nil ? "ruler" : "ruler.fill")
                }
                .help("Measure distance / angle / dihedral by tapping atoms")
            }
            panelToggles
        }
        .sheet(isPresented: $showCustomSizeSheet) {
            customSizeSheet
        }
        .onAppear {
            initializeEngine()
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
        engine.runCommand("load \(url.path), \(name)")
    }

    private func macFetch() {
        let id = macFetchID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "'", with: "")
        guard !id.isEmpty else { return }
        engine.runCommand("fetch \(id), async=0, type=pdb")
    }
    #endif

    // MARK: - iPadOS: TabView with panels

    #if os(iOS)
    // Default to the Objects tab: a touch user tunes representations far more
    // than they type commands, and it avoids greeting them with console log text.
    @State private var selectedTab = 1
    @State private var showFetch = false
    @State private var fetchID = ""
    // iPhone: the transport floats as a 1-line peek over the viewport and
    // expands in place to the full multi-row control. (Ignored on regular-width
    // iPad, where the bar is always full.)
    @State private var transportExpanded = false
    // Test affordance (PYMOL_AUTOSHEET=builder|export): auto-present a movie
    // sheet so the screenshot harness can capture it (simctl can't tap).
    @State private var showBuilderSheet = false
    @State private var showExportSheet = false
    @State private var showSettingsSheet = false
    // Test affordance (PYMOL_AUTOEXPORTMOVIE="mp4|gif,first,last"): run a headless
    // movie export and copy the result to /tmp so the harness can validate it.
    @StateObject private var exportTester = MovieExporter()
    // AI Chat tab. The backend (pymol.ai_chat → Claude/Anthropic) is wired to the
    // headless ai_chat_swift sink, so the chat is functional; surface its tab.
    private let kShowChatTab = true

    // Adaptive control surface. Placement + sizing depend on size class AND
    // orientation: a resizable SIDE column only on a regular-width iPad in
    // landscape (where there's horizontal surplus); otherwise — portrait, or any
    // COMPACT-width device (iPhone) — a resizable BOTTOM panel, so the 3D viewport
    // stays maximal. `panelFrac` (committed at each drag end) is the panel's share
    // of the short axis; `panelCollapsed` hides it for a full-bleed viewport.
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var panelFrac: CGFloat = 0.28
    @State private var committedFrac: CGFloat = 0.28
    @State private var panelCollapsed = false
    // Panel share to return to when no detail view is open. While a detail view
    // (SCENE or an object card) is expanded the panel auto-grows to its max so
    // the options are visible; collapsing restores this remembered size.
    @State private var collapsedFrac: CGFloat = 0.28
    @State private var didConfigForCompact = false
    @AppStorage("ipadGestureCoachSeen") private var gestureCoachSeen = false
    @State private var showGestureLegend = false

    private var iPadOSLayout: some View {
        NavigationStack {
            GeometryReader { geo in
                let compact = hSize == .compact
                let landscape = geo.size.width > geo.size.height
                let side = !compact && landscape   // side column only on a wide iPad
                let total = side ? geo.size.width : geo.size.height
                let panelSize = min(max(total * panelFrac, side ? 280 : 200),
                                    total * (side ? 0.45 : 0.6))
                Group {
                    if side {
                        HStack(spacing: 0) {
                            viewportView
                            if !panelCollapsed {
                                resizeDivider(landscape: true, total: geo.size.width)
                                panelContent.frame(width: panelSize)
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            viewportView
                            if !panelCollapsed {
                                resizeDivider(landscape: false, total: geo.size.height)
                                panelContent.frame(height: panelSize)
                            }
                        }
                    }
                }
                .overlay(alignment: .center) {
                    if !gestureCoachSeen && !engine.objects.isEmpty { gestureCoachOverlay }
                }
            }
            // Full-bleed: the viewport uses every pixel, including under the
            // notch / Dynamic Island and behind the (transparent) nav bar. The
            // toolbar buttons are chrome and stay within the safe area, so they
            // remain tappable and clear of the notch while the 3D view fills
            // behind them. Ignore only the CONTAINER region (notch/bars) — NOT
            // the keyboard — so keyboard avoidance still pushes the console +
            // command field up above the on-screen keyboard.
            .ignoresSafeArea(.container, edges: .all)
            // Measurement bar docks in the top safe area (below the status bar /
            // Dynamic Island / nav bar) and insets the viewport while active —
            // NOT a full-bleed overlay, which would slide under the notch.
            .safeAreaInset(edge: .top, spacing: 0) {
                if engine.measureMode != nil { measureOverlay }
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
            .toolbar { iosOpenToolbar; iosMeasureToolbar; iosPanelToggle; iosExportToolbar }
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
        .preferredColorScheme(.dark)   // consistent dark chrome (no white nav bar)
        .onAppear {
            initializeEngine()
            // iPhone (compact): start full-screen with the panel collapsed and
            // the 64pt sequence strip off — the controls are a peek to expand.
            if !didConfigForCompact {
                didConfigForCompact = true
                if hSize == .compact {
                    panelCollapsed = true
                    engine.sequenceVisible = false
                }
                // Test affordance (screenshot harness): force the panel open so
                // the responsive layout can be captured without a tap, which
                // simctl can't synthesize. PYMOL_AUTOPANEL=open|closed.
                if let p = ProcessInfo.processInfo.environment["PYMOL_AUTOPANEL"] {
                    panelCollapsed = (p != "open")
                    engine.sequenceVisible = (p == "open")
                }
            }
            if let s = ProcessInfo.processInfo.environment["PYMOL_AUTOSHEET"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    if s == "builder" { showBuilderSheet = true }
                    if s == "export" { showExportSheet = true }
                    if s == "settings" { showSettingsSheet = true }
                }
            }
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
            .accessibilityLabel("Measure")
        }
    }

    private var iosPanelToggle: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { panelCollapsed.toggle() }
            } label: {
                Image(systemName: panelCollapsed ? "square.split.1x2" : "square.split.1x2.fill")
            }
            .accessibilityLabel(panelCollapsed ? "Show controls" : "Hide controls")
        }
    }

    // The 3D viewport — primary in every orientation. Carries the empty-state CTA
    // and a persistent "?" gesture-legend button.
    private var viewportView: some View {
        MetalViewport()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { if engine.objects.isEmpty { emptyStateView } }
            // Timeline transport: floats over the bottom of the viewport when
            // there's more than one frame. A collapsing peek on iPhone; a pinned
            // full-width bar on iPad.
            .overlay(alignment: .bottom) {
                if engine.hasTimeline { transportOverlay }
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
    private var panelContent: some View {
        TabView(selection: $selectedTab) {
            CommandPanel()
                .tabItem { Label("Console", systemImage: "terminal") }.tag(0)
            ObjectPanel()
                .tabItem { Label("Objects", systemImage: "cube") }.tag(1)
            SequencePanel()
                .tabItem { Label("Sequence", systemImage: "textformat.abc") }.tag(2)
            if kShowChatTab {
                ChatPanel()
                    .tabItem { Label("AI Chat", systemImage: "bubble.left.and.bubble.right") }.tag(3)
            }
        }
        .background(Color(white: 0.11))
    }

    // Draggable splitter between viewport and panel. Drag toward the viewport
    // (up in portrait / left in landscape) grows the panel; committed on release.
    @ViewBuilder
    private func resizeDivider(landscape: Bool, total: CGFloat) -> some View {
        ZStack {
            Color(white: 0.18)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(0.35))
                .frame(width: landscape ? 4 : 44, height: landscape ? 44 : 4)
        }
        .frame(width: landscape ? 16 : nil, height: landscape ? nil : 20)
        .frame(maxWidth: landscape ? nil : .infinity, maxHeight: landscape ? .infinity : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    let d = landscape ? -v.translation.width : -v.translation.height
                    panelFrac = min(max(committedFrac + d / total, 0.12), 0.6)
                }
                .onEnded { _ in
                    committedFrac = panelFrac
                    // Remember the manual size only while collapsed, so it's what
                    // we restore to after an auto-grown detail view closes.
                    if engine.expandedDetail == nil { collapsedFrac = panelFrac }
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

    // Render a PNG to `path`. Transparent → CPU ray-trace (honors
    // ray_opaque_background; the Metal fast path bakes the bg color via its post
    // chain). Else the Metal fast path with the background color.
    // Renders through runHeavy so the "Calculating…" overlay shows during the
    // (slow, ray-traced) render; `done` runs on the main thread once written.
    private func renderExportPNG(_ path: String, _ w: Int, _ h: Int,
                                 done: @escaping () -> Void = {}) {
        engine.runHeavy("Rendering image…") {
            if exportTransparent {
                engine.runCommand("set ray_opaque_background, 0")
                engine.runCommand("png \(path), width=\(w), height=\(h), ray=1")
            } else {
                engine.runCommand("set ray_opaque_background, 1")
                engine.renderHiResPNG(path, width: w, height: h, rayTraced: rtFlag)
            }
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

    private func saveSession() {
        let panel = NSSavePanel()
        if let pse = UTType(filenameExtension: "pse") { panel.allowedContentTypes = [pse] }
        panel.nameFieldStringValue = "session.pse"
        panel.canCreateDirectories = true
        panel.title = "Save Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        engine.runPython("from pymol import cmd as _c; _c.save(r'''\(url.path)''')")
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
                .foregroundColor(TimelineTheme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Button { engine.clearMeasurements() } label: {
                Image(systemName: "trash").foregroundColor(TimelineTheme.text)
            }.buttonStyle(.plain).help("Delete all measurements")
            Button { engine.setMeasureMode(nil) } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(TimelineTheme.dim)
            }.buttonStyle(.plain).accessibilityLabel("Exit measure mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(TimelineTheme.bar)
        .tint(TimelineTheme.accent)
    }

    // MARK: - Initialization

    private func initializeEngine() {
        guard !engine.isReady else { return }
        let resourcePath = Bundle.main.resourcePath ?? ""
        engine.initialize(resourcePath: resourcePath)
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
