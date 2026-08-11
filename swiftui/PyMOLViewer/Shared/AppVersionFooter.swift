import SwiftUI

/// Small footer identifying the running build, shown at the bottom of the
/// Display/Settings pane on both platforms.
///
/// It earns its place on iOS specifically: TestFlight betas carry the same
/// `CFBundleShortVersionString` as the release they were cut from (App Store
/// Connect will not accept a "-betaN" suffix there), so without this a tester
/// reporting a bug has no way to say which beta they are on. See `AppBuildInfo`.
struct AppVersionFooter: View {
    /// e.g. "1.9.1-beta27" on a beta, "1.9.1 (27)" everywhere else.
    private var label: String { AppBuildInfo.displayVersion }

    var body: some View {
        // Empty only if the Info.plist lost both version keys — render nothing
        // rather than a bare "RayMol" that looks like a truncated string.
        if !label.isEmpty {
            Text(verbatim: "RayMol \(label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Testers paste this into bug reports; make it selectable rather
                // than something they have to transcribe from a screenshot.
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
                .accessibilityIdentifier("app-version-footer")
        }
    }
}
