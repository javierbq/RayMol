import Foundation

/// The app's own version identity, as a user should read it.
///
/// Why this exists rather than reading `CFBundleShortVersionString` at each call
/// site: a TestFlight beta and the release it was cut from share that string.
/// Betas ride the CURRENT marketing version and are told apart only by the build
/// number, because App Store Connect requires `CFBundleShortVersionString` to be
/// at most three numeric components and rejects a "-beta27" suffix at upload
/// (see scripts/nightly_version.sh for the full rationale). So "which build am I
/// actually running?" cannot be answered by the version alone, and a tester
/// filing a bug needs the answer.
///
/// The beta half comes from `RayMolBetaLabel`, which exists in the Info.plist
/// ONLY for builds produced by Xcode Cloud: swiftui/ci_scripts/ci_post_clone.sh
/// stamps `RAYMOL_BETA_LABEL` and a postBuildScript copies it in. Its presence is
/// therefore the signal "this is a beta" — local, DMG and App Store builds have
/// no such key and display a plain version.
enum AppBuildInfo {

    /// `CFBundleShortVersionString`, e.g. "1.9.1". Empty if somehow absent.
    static var version: String { string(for: "CFBundleShortVersionString") }

    /// `CFBundleVersion`, e.g. "27". Empty if somehow absent.
    static var build: String { string(for: "CFBundleVersion") }

    /// `RayMolBetaLabel`, e.g. "1.9.1-beta27" — `nil` for any non-beta build.
    static var betaLabel: String? { Self.normalizedLabel(string(for: "RayMolBetaLabel")) }

    /// What to show the user, e.g. "1.9.1-beta27" or "1.9.1 (27)".
    static var displayVersion: String {
        Self.displayVersion(version: version, build: build, betaLabel: betaLabel)
    }

    /// True when this build came off the beta pipeline.
    static var isBeta: Bool { betaLabel != nil }

    // MARK: - Pure logic (unit-tested; no Bundle access)

    /// Treat a missing key and a present-but-blank one identically. The
    /// postBuildScript is written to omit the key rather than write "", but a
    /// hand-edited plist or a future change to that script must not produce a
    /// build that claims to be "beta" with nothing after the dash.
    static func normalizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The label wins when present — it already contains the version, so showing
    /// both would read "1.9.1 (27) 1.9.1-beta27". Falls back to the App Store's
    /// own "version (build)" convention, and degrades to whichever half exists if
    /// the Info.plist is incomplete rather than rendering stray parentheses.
    static func displayVersion(version: String, build: String, betaLabel: String?) -> String {
        if let label = normalizedLabel(betaLabel) { return label }
        switch (version.isEmpty, build.isEmpty) {
        case (false, false): return "\(version) (\(build))"
        case (false, true):  return version
        case (true, false):  return "(\(build))"
        case (true, true):   return ""
        }
    }

    // MARK: - Bundle access

    private static func string(for key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
}
