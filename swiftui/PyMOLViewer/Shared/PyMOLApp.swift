// PyMOLApp.swift — Cross-platform SwiftUI entry point for macOS and iPadOS

import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif
#if os(iOS)
import UIKit

// Orientation-lock delegate (test affordance, see forceOrientationIfRequested).
// Default `.all` leaves normal autorotation untouched; the screenshot harness
// narrows the supported set so a forced landscape can't snap back to portrait.
final class OrientationLockDelegate: NSObject, UIApplicationDelegate {
    static var mask: UIInterfaceOrientationMask = .all
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return Self.mask
    }
}
#endif

#if os(macOS)
// macOS delivers files to open through NSApplicationDelegate.application(_:open:)
// as the COMPLETE [URL] array — Terminal `open a.pdb b.pdb c.pdb`, Finder "Open
// With" multi-select, and drag-drop onto the Dock icon all arrive this way.
// SwiftUI's .onOpenURL surfaces only the FIRST of those URLs and silently drops
// the rest, so a multi-file open loaded just one file (issue #222). Implementing
// the delegate method and looping over the whole array is the reliable way to
// receive every file; macOS therefore routes OS opens here instead of .onOpenURL.
final class RayMolAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Called on the main thread; hop to the main actor to reach loadOpenedFile
        // (@MainActor), mirroring ContentView's drag-drop handler.
        Task { @MainActor in handleOpenedURLs(urls, into: PyMOLEngine.shared) }
    }

    /// Drop any pending structure-prediction placeholders on the way out.
    ///
    /// Inference is in-process, so quitting kills the job — the empty object it was
    /// waiting for is meaningless from here on. The session-save task already keeps
    /// placeholders out of an explicitly saved .pse; this covers whatever else reads
    /// object state during teardown, and leaves the last session PyMOL sees clean.
    /// `discard_pending` only deletes objects that are still empty, so a prediction that
    /// finished moments before the quit is never destroyed.
    func applicationWillTerminate(_ notification: Notification) {
        PyMOLEngine.shared.runPython(
            "from pymol import predicting as _p; _p.clear_pending()")
    }
}
#endif

// MARK: - Keyboard shortcut table (#360, #361)

/// The one table behind every discoverable app shortcut: the binding that is
/// REGISTERED and the hint the user SEES both come from these constants, so
/// they cannot drift (#360). macOS registers each tool shortcut on a real
/// menu-bar command (a menu key equivalent is what fires reliably — see the ⌘C
/// note in macCommands); the shared tool-picker rows and pane toggles attach
/// the same constant, which is what renders the hint in their menus and makes
/// the shortcut reach iPadOS hardware keyboards.
///
/// Every ⌃-letter entry must be mirrored in modules/pymol/raymol_keys.py
/// (APP_SHORTCUTS), the launch-time audit that warns when ~/.raymolrc binds
/// over a menu shortcut. ⌘ entries need no mirror: KeyRouting passes ⌘ events
/// straight through to the menus, so a user binding can never shadow them.
enum AppShortcuts {
    // Tool picker (#360): the exclusive viewport modes, one ⌃-mnemonic each —
    // Move / mEasure / Design / Predict / Binder Design — plus Box Select on the
    // same scheme. ⌃E is the first letter of "measure" not already spoken for
    // (⌃M is Move).
    //
    // ⌃B IS BINDER DESIGN, and Box Select is ⌃S (#342). Both are first letters,
    // and the split is the one a user would guess: B for the tool whose name
    // begins with it, S for "select". Box Select held ⌃B first, and when Binder
    // Design landed it took ⌃B too — the two registered the same key equivalent
    // and fought silently, which `AppShortcutsTests.testNoDuplicateBindings`
    // now catches because both live in `all`.
    static let moveTool = KeyboardShortcut("m", modifiers: .control)
    static let measureTool = KeyboardShortcut("e", modifiers: .control)
    static let designTool = KeyboardShortcut("d", modifiers: .control)
    static let predictTool = KeyboardShortcut("p", modifiers: .control)
    static let binderDesignTool = KeyboardShortcut("b", modifiers: .control)
    static let boxSelect = KeyboardShortcut("s", modifiers: .control)

    // Pane toggles (#361): open-if-closed / close-if-open, one numbered ⌘
    // family in the order the panes appear — the rail pills left to right
    // (Console, Seq), then the side panel.
    static let consolePane = KeyboardShortcut("1", modifiers: .command)
    static let sequencePane = KeyboardShortcut("2", modifiers: .command)
    static let sidePanel = KeyboardShortcut("3", modifiers: .command)

    /// Every entry above. The collision test runs off this list, so a new
    /// shortcut must be added here too (same contract as PanelLayout.allKeys).
    static let all: [KeyboardShortcut] = [
        moveTool, measureTool, designTool, predictTool, binderDesignTool, boxSelect,
        consolePane, sequencePane, sidePanel,
    ]

    /// The macOS-style symbol hint ("⌃M", "⌘1") for the surfaces that don't
    /// render one from the registration itself — rail-pill tooltips and
    /// toolsMenuHelp. Menus draw their own glyphs from the attached shortcut.
    static func hint(_ shortcut: KeyboardShortcut) -> String {
        var out = ""
        if shortcut.modifiers.contains(.control) { out += "⌃" }
        if shortcut.modifiers.contains(.option) { out += "⌥" }
        if shortcut.modifiers.contains(.shift) { out += "⇧" }
        if shortcut.modifiers.contains(.command) { out += "⌘" }
        out += String(shortcut.key.character).uppercased()
        return out
    }
}

struct PyMOLApp: App {
    @StateObject private var engine = PyMOLEngine.shared
    @StateObject private var notes = AnalysisNotesStore.shared
    #if os(macOS) && !RAYMOL_MAS_RESTRICTED
    @StateObject private var mcp = MCPServerManager.shared
    @StateObject private var updater = RayMolUpdater()
    #endif
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationLockDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    #endif
    #if os(macOS)
    // Receives OS file-open events (application(_:open:)); see RayMolAppDelegate.
    @NSApplicationDelegateAdaptor(RayMolAppDelegate.self) private var appDelegate
    #endif

    init() {
        #if os(iOS)
        // The object list (and other panels) live in a vertical ScrollView. iOS
        // scroll views default to delaysContentTouches = true, which holds a
        // touch-down for ~150ms to decide whether it's the start of a pan — so a
        // single tap on a Menu/Button inside the scroll view is often swallowed
        // (interpreted as a scroll that never moved) and you have to tap again.
        // This was the cause of the "A" action menu needing multiple taps to
        // open. Delivering touches immediately fixes first-tap responsiveness for
        // every control inside a scroll view, app-wide.
        UIScrollView.appearance().delaysContentTouches = false
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        // Single, unique window (`Window`, not `WindowGroup`): RayMol's engine is
        // one shared PyMOL session, so a second window would only duplicate the
        // same view and stay in sync. `Window` drops the "New Window" command and
        // re-focuses the existing window instead. Per-window sessions: issue #29.
        Window("RayMol", id: "raymol-main") { rootView }
            .windowStyle(.titleBar)
            .defaultSize(width: 1200, height: 800)
            .commands { macCommands }
        Window("Analysis Notes", id: "analysis-notes") {
            NotesInspectorView()
                .environmentObject(engine)
                .environmentObject(notes)
                .frame(minWidth: 440, minHeight: 520)
                .onDisappear { notes.flush() }
        }
        .defaultSize(width: 560, height: 720)
        #else
        WindowGroup { rootView }
        #endif
    }

    // Content of the single window, shared by the macOS `Window` and iOS
    // `WindowGroup`: engine/theme injection, OS file-open, and the iOS
    // orientation + scene-phase hooks.
    @ViewBuilder private var rootView: some View {
        ContentView()
                .environmentObject(engine)
                .environmentObject(engine.playback)
                .environmentObject(ThemeManager.shared)
                .environmentObject(notes)
                .onDisappear { notes.flush() }
            #if os(macOS)
                // Bring the app/window to the front on launch (a GUI app should
                // foreground itself; also lets it be launched from a terminal).
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
                // Window title reflects the open .pse document (falls back to the
                // app name when nothing is tracked).
                .navigationTitle(engine.currentSessionURL?.lastPathComponent ?? "RayMol")
            #endif
            #if os(macOS) && !RAYMOL_MAS_RESTRICTED
                .environmentObject(mcp)
                .onAppear { mcp.bind(engine: engine) }
            #endif
            #if os(iOS)
                // Test affordance (screenshot harness): force device orientation,
                // since simctl can't rotate and System Events keystrokes need
                // Accessibility. PYMOL_AUTOLANDSCAPE=left|right; absent = as-is.
                .onAppear { Self.forceOrientationIfRequested() }
            #endif
                // Open a file handed to RayMol by the OS. iOS delivers a single URL
                // per open (Files / Share-sheet "Open in RayMol") through
                // .onOpenURL. macOS instead routes ALL opens (Finder double-click /
                // "Open With" multi-select / Terminal `open a.pdb b.pdb` / Dock-icon
                // drop) through RayMolAppDelegate.application(_:open:), because
                // .onOpenURL surfaces only the FIRST url of a multi-file open and
                // drops the rest (issue #222). The registered document types (see
                // project.yml) route these here. PyMOL infers the format from the
                // extension; the object name is the sanitized filename stem. Engine
                // init runs in ContentView's .onAppear, so on a cold launch the URL
                // may arrive before the engine is ready — loadOpenedFile retries.
                #if os(iOS)
                .onOpenURL { url in
                    // A launch-to-open-a-file takes precedence over the autosaved
                    // scene: flag it before the (possibly retried) load so the
                    // cold-launch restore doesn't merge the old session underneath.
                    engine.launchOpenRequested = true
                    loadOpenedFile(url, into: engine)
                }
                #endif
            #if os(iOS)
                // iOS purges backgrounded apps to reclaim memory; persist the
                // session on the way out so the next cold launch can resume it.
                // .background (not .inactive) is the debounced signal — .inactive
                // also fires for transient interruptions (app-switcher peek,
                // Control Center) where we don't want to save.
                .onChange(of: scenePhase) { phase in
                    // Grab the viewport snapshot on .inactive (still foreground —
                    // iOS blocks Metal work once .background), then save the full
                    // session on .background. The snapshot is only USED on restore
                    // when a .background autosave actually happened, so capturing
                    // it during transient .inactive (Control Center, switcher peek)
                    // is harmless.
                    if phase == .inactive { engine.captureRestoreSnapshot() }
                    if phase == .background {
                        notes.flush()
                        engine.autosaveSession(keepingNotes: notes.hasContent)
                    }
                }
            #endif
        }
    #if os(macOS)
    // The pane-visibility flags behind the View-menu toggles (#361): the same
    // UserDefaults keys ContentView reads through @AppStorage (defaults must
    // match its declarations), so the menu command, the rail pill, and the
    // tongue all flip one persisted flag and can never disagree.
    @AppStorage(PanelLayout.consoleVisibleKey) private var showCommandPanel = true
    @AppStorage(PanelLayout.objectsVisibleKey) private var showObjectPanel = true

    /// True while any MLX Design inference is in flight. Mirrors ContentView.isDesignLocked
    /// so the macOS menu commands (⌃M, ⌃D) respect the same lock as toolbar and rail buttons.
    private var isDesignLocked: Bool {
        #if RAYMOL_MPNN
        return engine.isDesignCalculating
        #else
        return false
        #endif
    }

    // Native menus (macOS only). File: Open / Fetch / Save / Export. App menu:
    // website + GitHub links, plus Check for Updates on the Developer-ID build.
    // Connect: MCP server control. Buttons post notifications ContentView's macOS
    // layout observes (reusing the toolbar's open/save/export logic).
    @CommandsBuilder private var macCommands: some Commands {
            // Custom About panel: standard panel with clickable website + GitHub
            // links in the credits (replaces the default About menu item).
            CommandGroup(replacing: .appInfo) {
                Button("About RayMol") { showAboutPanel() }
            }
            // "What's New" splash, on demand. Ungated so it's present on every
            // macOS build (incl. Mac App Store); posts .raymolShowWhatsNew, which
            // ContentView's body observes to present the sheet.
            CommandGroup(after: .appInfo) {
                Button("What's New in RayMol") {
                    NotificationCenter.default.post(name: .raymolShowWhatsNew, object: nil)
                }
            }
            #if os(macOS) && !RAYMOL_MAS_RESTRICTED
            // Sparkle auto-update (Developer-ID/DMG build only; the Mac App Store
            // build updates through Apple). Placed in the app menu next to About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            #endif
            // Contact Support: opens the user's default mail client, pre-addressed
            // to support@raymol.io. Lands in the Help menu (the standard macOS spot
            // for support links). NSWorkspace URL-open works in the sandboxed Mac
            // App Store build too, so this isn't gated behind RAYMOL_MAS_RESTRICTED.
            CommandGroup(after: .help) {
                Button("Contact Support…") { contactSupport() }
            }
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .raymolOpenFile, object: nil)
                }.keyboardShortcut("o", modifiers: .command)
                Button("Fetch from PDB…") {
                    NotificationCenter.default.post(name: .raymolFetch, object: nil)
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                // ⌘S overwrites the open .pse with no panel (Save As if never saved).
                Button("Save Session") {
                    NotificationCenter.default.post(name: .raymolSaveSession, object: nil)
                }.keyboardShortcut("s", modifiers: .command)
                // ⇧⌘S always shows the Save panel and updates the tracked document.
                Button("Save Session As…") {
                    NotificationCenter.default.post(name: .raymolSaveSessionAs, object: nil)
                }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Export Image…") {
                    NotificationCenter.default.post(name: .raymolExportImage, object: nil)
                }.keyboardShortcut("e", modifiers: [.command, .shift])
                // ⌘C as a real menu command (not a toolbar-Menu button) so the
                // shortcut fires reliably; mirrors how Export Image works above.
                // A menu key equivalent outranks the responder chain, so route
                // through CopyRouting: a live text selection (console log, command
                // line) copies as text and the image copy is the fallback (#287).
                Button("Copy Image to Clipboard") {
                    CopyRouting.perform {
                        NotificationCenter.default.post(name: .raymolCopyImage, object: nil)
                    }
                }.keyboardShortcut("c", modifiers: .command)
                Divider()
                Button("Clear Session") {
                    NotificationCenter.default.post(name: .raymolClearSession, object: nil)
                }
            }
            // TOOLS — every exclusive interaction mode, in one menu.
            //
            // These six are mutually exclusive: entering any one leaves the other
            // five (see PyMOLEngine's clearing setters and
            // `exitActiveInteractionMode`). Split across four top-level menus --
            // Mouse, Design, Predict, Binder Design -- that relationship was
            // invisible, and a tool's shortcut could only be found by opening the
            // menu it happened to live in. One menu makes the exclusion set legible
            // and puts all six key equivalents on screen together.
            //
            // It also matches the in-app Tools pill, which already carries this
            // exact list (`ContentView.interactionToolItems`) under this exact
            // name, so the menu bar and the pill are now two views of one thing.
            //
            // Shortcuts come from AppShortcuts (#360), so these commands, the pill
            // rows and the tooltips cannot disagree. The registration lives HERE
            // rather than only on the pill because a menu key equivalent is what
            // fires reliably on macOS (see the ⌘C note above).
            CommandMenu("Tools") {
                // The viewport tools first: these three reinterpret a click or a
                // drag, which is what this menu was called "Mouse" for.
                Button(engine.interactionMode == .move ? "Stop Moving Objects" : "Move Objects") {
                    engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.moveTool)
                Button(engine.measureMode != nil ? "Stop Measuring" : "Measure Distances") {
                    engine.setMeasureMode(engine.measureMode == nil ? .distance : nil)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.measureTool)
                // ⌃S — S for "select"; it gave up ⌃B to Binder Design, whose name
                // starts with the letter (#342, #358).
                Button(engine.interactionMode == .boxSelect ? "Stop Box Select" : "Box Select") {
                    engine.setInteractionMode(engine.interactionMode == .boxSelect ? .viewing : .boxSelect)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.boxSelect)

                Divider()

                // Then the tools that raise a bar or an overlay rather than
                // reinterpreting the pointer. Same exclusion set, different shape,
                // which is what the divider says.
                #if RAYMOL_MPNN
                Button(engine.designMode ? "Exit Design Mode" : "Enter Design Mode") {
                    engine.setDesignMode(!engine.designMode)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.designTool)
                #endif
                Button(engine.predictMode ? "Exit Predict Mode" : "Enter Predict Mode") {
                    engine.setPredictMode(!engine.predictMode)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.predictTool)
                #if os(macOS)
                // The item names the TOOL; what it produces is a designed backbone
                // until a refold and an interface gate say otherwise (#342).
                Button(engine.binderDesignMode ? "Exit Binder Design" : "Binder Design…") {
                    engine.setBinderDesignMode(!engine.binderDesignMode)
                }
                .disabled(isDesignLocked)
                .keyboardShortcut(AppShortcuts.binderDesignTool)
                #endif
            }
            // View menu: the pane toggles (#361) — open if closed, close if
            // open. One plain-⌘ family, which KeyRouting passes straight
            // through to the menus, so a ~/.raymolrc binding can never
            // shadow them. The rail pills / tongue flip the same persisted
            // flags (PanelLayout keys / engine.sequenceVisible), so menu and
            // pointer stay in agreement.
            //
            // No longer wrapped in a `Group`: that existed only to make the
            // Design / Predict / Binder Design menus count as one child against
            // @CommandsBuilder's 10-child ceiling, and folding those three into
            // Tools removed the three children it was buying room for. This
            // builder now sits at exactly 10, so the NEXT top-level menu added
            // here needs a `Group` around it and a sibling.
            CommandGroup(after: .sidebar) {
                Button(showCommandPanel ? "Hide Console" : "Show Console") {
                    showCommandPanel.toggle()
                }
                .keyboardShortcut(AppShortcuts.consolePane)
                Button(engine.sequenceVisible ? "Hide Sequence" : "Show Sequence") {
                    engine.sequenceVisible.toggle()
                }
                .keyboardShortcut(AppShortcuts.sequencePane)
                Button(showObjectPanel ? "Hide Side Panel" : "Show Side Panel") {
                    showObjectPanel.toggle()
                }
                .keyboardShortcut(AppShortcuts.sidePanel)
            }
            // Movie: enter/exit the Timeline (movie studio) mode. Carries the
            // keyboard shortcut; the toolbar clapperboard is the primary control.
            CommandMenu("Movie") {
                Button(engine.timelineMode ? "Exit Timeline" : "Edit Timeline") {
                    NotificationCenter.default.post(name: .raymolToggleTimeline, object: nil)
                }.keyboardShortcut("m", modifiers: [.command, .option])
            }
            CommandMenu("Notes") {
                Button("Insert Camera View Link") {
                    NotificationCenter.default.post(name: .raymolInsertNoteView, object: nil)
                }.keyboardShortcut("l", modifiers: [.command, .option])
                Button("Toggle Edit / Preview") {
                    NotificationCenter.default.post(name: .raymolToggleNotePreview, object: nil)
                }.keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Increase Note Font Size") {
                    NotificationCenter.default.post(name: .raymolNotesFontIncrease, object: nil)
                }.keyboardShortcut("+", modifiers: [.command, .option])
                Button("Decrease Note Font Size") {
                    NotificationCenter.default.post(name: .raymolNotesFontDecrease, object: nil)
                }.keyboardShortcut("-", modifiers: [.command, .option])
            }
            #if os(macOS) && !RAYMOL_MAS_RESTRICTED
            CommandMenu("Connect") {
                Toggle("Enable AI control", isOn: Binding(
                    get: { mcp.isRunning }, set: { _ in mcp.toggle() }))
                .keyboardShortcut("m", modifiers: [.control, .command])
                Divider()
                if mcp.isRunning, let port = mcp.port {
                    Text("Listening on 127.0.0.1:\(port)")
                    Text("Clients: \(mcp.clientCount)")
                    Divider()
                }
                Button("Connect an AI app…") {
                    NotificationCenter.default.post(name: .mcpOpenConnectSheet, object: nil)
                }
                Divider()
                Button("Copy connection details") {
                    if let port = mcp.port {
                        let s = "URL: http://127.0.0.1:\(port)/mcp\n"
                            + "Authorization: Bearer \(mcp.token)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                }.disabled(!mcp.isRunning)
            }
            #endif
        }

    // Standard About panel with clickable website + GitHub links in the credits.
    private func showAboutPanel() {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        func link(_ text: String, _ urlString: String) -> NSAttributedString {
            var attrs = base
            if let url = URL(string: urlString) { attrs[.link] = url }
            return NSAttributedString(string: text, attributes: attrs)
        }
        let credits = NSMutableAttributedString(
            string: "Molecular visualization built on the open-source PyMOL engine.\n\n",
            attributes: base)
        credits.append(link("raymol.io", "https://raymol.io"))
        credits.append(NSAttributedString(string: "      ·      ", attributes: base))
        credits.append(link("GitHub", "https://github.com/javierbq/RayMol"))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // Open the default mail client with a message pre-addressed to support.
    private func contactSupport() {
        guard let url = URL(string: "mailto:support@raymol.io") else { return }
        _ = NSWorkspace.shared.open(url)
    }
    #endif

    #if os(iOS)
    private static func forceOrientationIfRequested() {
        guard let v = ProcessInfo.processInfo.environment["PYMOL_AUTOLANDSCAPE"] else { return }
        let orient: UIInterfaceOrientationMask = (v == "right") ? .landscapeRight : .landscapeLeft
        // Narrow supported orientations to a single landscape so the
        // simulated-portrait device can't reassert portrait after the request.
        OrientationLockDelegate.mask = orient
        // Defer so the window scene is foreground-active before the request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orient))
        }
    }
    #endif
}

// Load a file the OS handed to RayMol via .onOpenURL (Finder double-click /
// "Open With" on macOS; Files / Share-sheet "Open in RayMol" on iOS). The OS may
// deliver the URL before the engine has finished initializing (cold launch from a
// file), so retry on the main queue until the engine is ready (capped so a failed
// init never loops forever). The URL may be security-scoped (iOS document picker /
// inbox), so copy it into the temp dir before handing the path to PyMOL, which
// infers the format from the extension. The object name is the sanitized stem.
@MainActor
func loadOpenedFile(_ url: URL, into engine: PyMOLEngine, attempt: Int = 0) {
    guard engine.isReady else {
        guard attempt < 40 else { return }   // ~10s cap (40 × 250ms)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            loadOpenedFile(url, into: engine, attempt: attempt + 1)
        }
        return
    }
    #if os(macOS)
    guard confirmReplaceSessionIfNeeded(opening: url, engine: engine) else { return }
    #endif
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let ext = url.pathExtension.isEmpty ? "pdb" : url.pathExtension
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("open_\(UUID().uuidString.prefix(8)).\(ext)")
    try? FileManager.default.removeItem(at: temp)
    let path: String
    if (try? FileManager.default.copyItem(at: url, to: temp)) != nil {
        path = temp.path
    } else {
        path = url.path   // fall back to the original path (e.g. local macOS file)
    }
    let raw = url.deletingPathExtension().lastPathComponent
    var name = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    if name.isEmpty { name = "mol" }
    engine.loadStructure(path: path, name: name)
    // Publish the original document URL only after PyMOL has restored the PSE,
    // so observers read the newly restored embedded Analysis Notes payload.
    engine.currentSessionURL = (ext.lowercased() == "pse") ? url : nil
}

// Opening a session file REPLACES the whole current session — PyMOL sessions are
// app-global and there is no multi-window support yet (#29), so a Finder
// double-click on a .pse silently wiped whatever was on screen (issue #349).
// True when that destructive replace is about to happen: a session file is being
// opened while objects are loaded. Pure and engine-free so it's unit-testable
// (same pattern as handleOpenedURLs below).
func openWouldReplaceSession(_ url: URL, hasObjects: Bool) -> Bool {
    hasObjects && PyMOLEngine.isSessionFile(url.path)
}

#if os(macOS)
// Stopgap for issue #349 until sessions can open in their own window/tab: before
// a .pse/.psw replaces a non-empty session, offer to save the current one first,
// replace it outright, or cancel the open. Returns false when the open must not
// proceed (Cancel, or a failed/cancelled save).
@MainActor
func confirmReplaceSessionIfNeeded(opening url: URL, engine: PyMOLEngine) -> Bool {
    guard openWouldReplaceSession(url, hasObjects: !engine.objects.isEmpty)
    else { return true }
    let alert = NSAlert()
    alert.messageText = "Replace the current session?"
    alert.informativeText = """
        Opening “\(url.lastPathComponent)” will replace everything in the current \
        session. RayMol can’t open sessions in separate windows yet.
        """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save and Replace…")
    alert.addButton(withTitle: "Replace")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        return saveCurrentSessionForReplace(engine: engine)
    case .alertSecondButtonReturn:
        return true
    default:
        return false
    }
}

// Save the outgoing session before it's replaced, mirroring ⌘S semantics: an open
// document is overwritten silently; an untitled session shows the Save panel.
// Ordering is safe without waiting — cmd.save and the subsequent `load` both run
// synchronously through the bridge on the main actor, in issue order. Returns
// false when the user cancels the panel, which aborts the replace.
@MainActor
private func saveCurrentSessionForReplace(engine: PyMOLEngine) -> Bool {
    let notes = AnalysisNotesStore.shared
    let dest: URL
    if let current = engine.currentSessionURL {
        dest = current
    } else {
        let panel = NSSavePanel()
        if let pse = UTType(filenameExtension: "pse") { panel.allowedContentTypes = [pse] }
        panel.nameFieldStringValue = "session.pse"
        panel.canCreateDirectories = true
        panel.title = "Save Session"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        dest = url
    }
    notes.sessionDidSave(to: dest)
    engine.saveSession(to: dest)
    return true
}
#endif

// Load EVERY URL the OS handed us in one open (multi-file Terminal `open`, Finder
// "Open With" multi-select, Dock-icon drop). Factored out of RayMolAppDelegate so
// the "load them all, not just the first" contract (issue #222) is unit-testable
// without booting the engine: tests pass a spy for `load` (which defaults to
// loadOpenedFile) and assert every URL is forwarded, in order.
@MainActor
func handleOpenedURLs(_ urls: [URL], into engine: PyMOLEngine,
                      load: @MainActor (URL, PyMOLEngine) -> Void = { loadOpenedFile($0, into: $1) }) {
    for url in urls { load(url, engine) }
}
