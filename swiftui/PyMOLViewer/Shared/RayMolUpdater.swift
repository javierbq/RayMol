#if os(macOS) && !RAYMOL_MAS_RESTRICTED
import Foundation
import Sparkle

/// Wraps Sparkle's standard updater for the Developer-ID / DMG macOS build.
/// Started automatically; reads SUFeedURL / SUPublicEDKey from Info.plist.
/// iOS updates ship through the App Store, so this type is macOS-only.
final class RayMolUpdater: ObservableObject {
    let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → begins scheduled background checks immediately
        // (cadence/consent come from SUEnableAutomaticChecks /
        // SUScheduledCheckInterval in Info.plist).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Triggers a user-initiated check (the "Check for Updates…" menu item).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
#endif
