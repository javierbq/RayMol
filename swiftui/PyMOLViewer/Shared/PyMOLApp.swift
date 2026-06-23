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
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(engine.playback)
                .environmentObject(ThemeManager.shared)
            #if os(macOS)
                // Bring the app/window to the front on launch (a GUI app should
                // foreground itself; also lets it be launched from a terminal).
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
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
                // Open a file handed to RayMol by the OS (Finder double-click /
                // "Open With", iOS Files / Share-sheet "Open in RayMol"). The
                // registered document types (see project.yml) route these here.
                // PyMOL infers the format from the extension; the object name is
                // the sanitized filename stem. Engine init runs in ContentView's
                // .onAppear, so on a cold launch the URL may arrive before the
                // engine is ready — loadOpenedFile retries briefly until it is.
                .onOpenURL { url in
                    #if os(iOS)
                    // A launch-to-open-a-file takes precedence over the autosaved
                    // scene: flag it before the (possibly retried) load so the
                    // cold-launch restore doesn't merge the old session underneath.
                    engine.launchOpenRequested = true
                    #endif
                    loadOpenedFile(url, into: engine)
                }
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
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        // Native File menu: Open / Fetch / Save Session / Export Image, with
        // standard shortcuts. Buttons post notifications that ContentView's macOS
        // layout handles (reusing the toolbar's open/save/export logic).
        .commands {
            #if os(macOS) && !RAYMOL_MAS_RESTRICTED
            // Sparkle auto-update (Developer-ID/DMG build only; the Mac App Store
            // build updates through Apple). Placed in the app menu next to About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            #endif
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .raymolOpenFile, object: nil)
                }.keyboardShortcut("o", modifiers: .command)
                Button("Fetch from PDB…") {
                    NotificationCenter.default.post(name: .raymolFetch, object: nil)
                }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Save Session…") {
                    NotificationCenter.default.post(name: .raymolSaveSession, object: nil)
                }.keyboardShortcut("s", modifiers: .command)
                Button("Export Image…") {
                    NotificationCenter.default.post(name: .raymolExportImage, object: nil)
                }.keyboardShortcut("e", modifiers: [.command, .shift])
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
                Button("Connect Claude Code…") {
                    NotificationCenter.default.post(name: .mcpOpenConnectSheet, object: nil)
                }
                Button("Connect Claude for Mac… (soon)") {}.disabled(true)
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
        #endif
    }

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
private func loadOpenedFile(_ url: URL, into engine: PyMOLEngine, attempt: Int = 0) {
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
