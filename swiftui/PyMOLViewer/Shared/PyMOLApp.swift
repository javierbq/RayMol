// PyMOLApp.swift — Cross-platform SwiftUI entry point for macOS and iPadOS

import SwiftUI
#if os(macOS)
import AppKit
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
}
#endif

struct PyMOLApp: App {
    @StateObject private var engine = PyMOLEngine.shared
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
                    if phase == .background { engine.autosaveSession() }
                }
            #endif
        }
    #if os(macOS)
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
                Button("Copy Image to Clipboard") {
                    NotificationCenter.default.post(name: .raymolCopyImage, object: nil)
                }.keyboardShortcut("c", modifiers: .command)
                Divider()
                Button("Clear Session") {
                    NotificationCenter.default.post(name: .raymolClearSession, object: nil)
                }
            }
            // Mouse menu: toggle Move mode (rigid-body object gizmo). ⌃M.
            CommandMenu("Mouse") {
                Button(engine.interactionMode == .move ? "Stop Moving Objects" : "Move Objects") {
                    engine.setInteractionMode(engine.interactionMode == .move ? .viewing : .move)
                }.keyboardShortcut("m", modifiers: .control)
            }
            #if RAYMOL_MPNN
            // Design menu: toggle Design mode (MPNN score/color overlay). ⌃D.
            CommandMenu("Design") {
                Button(engine.designMode ? "Exit Design Mode" : "Enter Design Mode") {
                    engine.setDesignMode(!engine.designMode)
                }.keyboardShortcut("d", modifiers: .control)
            }
            #endif
            // Movie: enter/exit the Timeline (movie studio) mode. Carries the
            // keyboard shortcut; the toolbar clapperboard is the primary control.
            CommandMenu("Movie") {
                Button(engine.timelineMode ? "Exit Timeline" : "Edit Timeline") {
                    NotificationCenter.default.post(name: .raymolToggleTimeline, object: nil)
                }.keyboardShortcut("m", modifiers: [.command, .option])
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
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let ext = url.pathExtension.isEmpty ? "pdb" : url.pathExtension
    // Track an opened .pse as the current document (so ⌘S overwrites it). Capture
    // the ORIGINAL url, never the temp copy loaded below. Covers Finder open +
    // drag-drop, which both funnel here. A non-.pse structure clears the document.
    engine.currentSessionURL = (ext.lowercased() == "pse") ? url : nil
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
}

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
