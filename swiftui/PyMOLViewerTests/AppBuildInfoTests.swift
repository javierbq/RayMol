import XCTest
@testable import RayMol

/// Covers the pure half of `AppBuildInfo` — the part that decides what a user
/// sees when asked "which build is this?".
///
/// This matters because a TestFlight beta and the release it was cut from share
/// a `CFBundleShortVersionString`: App Store Connect requires at most three
/// numeric components, so betas ride the current version and are separated only
/// by build number. `RayMolBetaLabel` is the sole disambiguator, and getting its
/// presence/absence logic wrong either hides which beta a tester is on or tells
/// a paying App Store user they are running a beta.
final class AppBuildInfoTests: XCTestCase {

    // MARK: - normalizedLabel

    // Absent key. Every local, DMG and App Store build takes this path.
    func testNilLabelIsNotABeta() {
        XCTAssertNil(AppBuildInfo.normalizedLabel(nil))
    }

    // Present-but-blank must be treated as absent. The postBuildScript is written
    // to omit the key entirely, but project.yml carries RAYMOL_BETA_LABEL: "" and
    // one changed `[ -n "$LABEL" ]` guard away this becomes an empty string in the
    // plist — which must NOT read as "beta".
    func testBlankLabelIsNotABeta() {
        XCTAssertNil(AppBuildInfo.normalizedLabel(""))
        XCTAssertNil(AppBuildInfo.normalizedLabel("   "))
        XCTAssertNil(AppBuildInfo.normalizedLabel("\n"))
        XCTAssertNil(AppBuildInfo.normalizedLabel(" \t \n "))
    }

    func testLabelIsTrimmedNotMangled() {
        XCTAssertEqual(AppBuildInfo.normalizedLabel("1.9.1-beta27"), "1.9.1-beta27")
        XCTAssertEqual(AppBuildInfo.normalizedLabel("  1.9.1-beta27\n"), "1.9.1-beta27")
    }

    // MARK: - displayVersion

    // The beta label already contains the version, so it replaces the whole
    // string rather than being appended — otherwise testers read
    // "1.9.1 (27) 1.9.1-beta27".
    func testBetaLabelWinsOverVersionAndBuild() {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.9.1", build: "27", betaLabel: "1.9.1-beta27"),
            "1.9.1-beta27")
    }

    // The App Store's own convention for a non-beta build.
    func testNonBetaUsesVersionAndBuild() {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.9.1", build: "27", betaLabel: nil),
            "1.9.1 (27)")
    }

    // A blank label must fall through to the plain form, not produce "".
    func testBlankLabelFallsThroughToVersion() {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.9.1", build: "27", betaLabel: ""),
            "1.9.1 (27)")
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.9.1", build: "27", betaLabel: "   "),
            "1.9.1 (27)")
    }

    // Incomplete Info.plist: degrade to whichever half exists rather than
    // rendering "1.9.1 ()" or " (27)" at the user.
    func testMissingHalvesDegradeCleanly() {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "1.9.1", build: "", betaLabel: nil),
            "1.9.1")
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "", build: "27", betaLabel: nil),
            "(27)")
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "", build: "", betaLabel: nil),
            "")
    }

    // A beta label must still win when the version keys are missing — it is the
    // more specific fact, and it is complete on its own.
    func testLabelWinsEvenWithEmptyVersionKeys() {
        XCTAssertEqual(
            AppBuildInfo.displayVersion(version: "", build: "", betaLabel: "1.9.1-beta27"),
            "1.9.1-beta27")
    }

    // MARK: - The shipped bundle

    // The app under test is a local build, which must never claim to be a beta.
    // This is the assertion that would catch a non-empty RAYMOL_BETA_LABEL being
    // committed to project.yml — the mistake that would mark every DMG and App
    // Store build as a beta.
    func testLocalBuildIsNotMarkedBeta() {
        XCTAssertNil(AppBuildInfo.betaLabel,
                     "This build carries RayMolBetaLabel=\(AppBuildInfo.betaLabel ?? "nil"). "
                     + "RAYMOL_BETA_LABEL must be empty in the committed project.yml; only "
                     + "ci_post_clone.sh may set it.")
        XCTAssertFalse(AppBuildInfo.isBeta)
    }

    // Whatever the bundle says, the footer must have something to show.
    func testBundleDisplayVersionIsNonEmpty() {
        XCTAssertFalse(AppBuildInfo.displayVersion.isEmpty)
    }
}
