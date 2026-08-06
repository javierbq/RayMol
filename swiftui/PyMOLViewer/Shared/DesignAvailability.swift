#if RAYMOL_MPNN
import Foundation

/// Whether Design mode may be offered on this build and OS.
///
/// Design mode is compiled in for both macOS and iOS (RAYMOL_MPNN), but on iOS
/// the only configuration ever validated on physical hardware is iOS 18 —
/// mlx-swift's Metal path is unverified on iOS 17, which SPM nonetheless
/// resolves. Rather than ship an unverified path or raise the whole app's floor
/// to 18 (which would cost every iOS 17 user the app, not just Design), the
/// feature itself is gated and simply absent below 18.
///
/// See docs/superpowers/specs/2026-07-26-raymol-design-ios-phase2d-design.md §4.
enum DesignAvailability {

    enum Platform { case macOS, iOS }

    /// Minimum iOS major version on which Design mode is offered.
    static let minimumIOSMajorVersion = 18

    /// Pure decision. `platform` is a parameter rather than a `#if` branch so the
    /// macOS test host can verify the iOS rule; a compile-time branch would leave
    /// the iOS arm permanently untested.
    static func isSupported(platform: Platform, osMajorVersion: Int) -> Bool {
        switch platform {
        case .macOS: return true
        case .iOS:   return osMajorVersion >= minimumIOSMajorVersion
        }
    }

    /// The platform this binary was compiled for.
    static var current: Platform {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }

    static var currentOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    /// True when Design mode should be offered. Callers must not build any Design
    /// entry point — rail pill, menu item, docked panel — when this is false.
    static var isSupported: Bool {
        isSupported(platform: current, osMajorVersion: currentOSMajorVersion)
    }
}
#endif
