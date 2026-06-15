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

@main
struct PyMOLApp: App {
    @StateObject private var engine = PyMOLEngine.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(OrientationLockDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(engine.playback)
            #if os(macOS)
                // Bring the app/window to the front on launch (a GUI app should
                // foreground itself; also lets it be launched from a terminal).
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
            #endif
            #if os(iOS)
                // Test affordance (screenshot harness): force device orientation,
                // since simctl can't rotate and System Events keystrokes need
                // Accessibility. PYMOL_AUTOLANDSCAPE=left|right; absent = as-is.
                .onAppear { Self.forceOrientationIfRequested() }
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
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
