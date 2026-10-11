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

    // MARK: - consoleBanner (#377)

    // The console's first line must come from the bundle, not a hand-bumped
    // string: the old marker read "v35" for two months of unrelated releases.
    func testConsoleBannerCarriesTheDisplayVersion() {
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.10.0 (27)"),
                       " [build] RayMol 1.10.0 (27)")
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.9.1-beta27"),
                       " [build] RayMol 1.9.1-beta27")
    }

    // A plist missing both keys must still print something a tester can quote,
    // not a trailing-space "RayMol " that looks like a rendering glitch.
    func testConsoleBannerWithoutVersionSaysSo() {
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: ""),
                       " [build] RayMol (unknown version)")
    }

    // The live property must go through the same formatter as the tested one.
    func testLiveConsoleBannerMatchesDisplayVersion() {
        XCTAssertEqual(AppBuildInfo.consoleBanner,
                       AppBuildInfo.consoleBanner(displayVersion: AppBuildInfo.displayVersion,
                                                  coreSHA: AppBuildInfo.coreSHA))
        XCTAssertTrue(AppBuildInfo.consoleBanner.hasPrefix(" [build] RayMol "))
    }

    // The stamped core commit makes a stale-core link visible in the console
    // (#400). Blank/absent stamps must not leave a dangling " core ".
    func testConsoleBannerShowsCoreSHAWhenStamped() {
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.10.0 (27)", coreSHA: "1fc5fc983"),
                       " [build] RayMol 1.10.0 (27) core 1fc5fc983")
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.10.0 (27)", coreSHA: "1fc5fc983-dirty"),
                       " [build] RayMol 1.10.0 (27) core 1fc5fc983-dirty")
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.10.0 (27)", coreSHA: nil),
                       " [build] RayMol 1.10.0 (27)")
        XCTAssertEqual(AppBuildInfo.consoleBanner(displayVersion: "1.10.0 (27)", coreSHA: "  "),
                       " [build] RayMol 1.10.0 (27)")
    }
}

// MARK: - ScriptedLaunchTests (#671)

/// Covers `PyMOLEngine.isScriptedLaunch(environment:)`, which detects whether
/// the scene is being scripted via test affordances (PYMOL_AUTOCMD/PYMOL_AUTOLOAD)
/// so launch-time theme re-assertion does not clobber requested render settings.
final class ScriptedLaunchTests: XCTestCase {

    func testEmptyEnvironmentIsNotScripted() {
        XCTAssertFalse(PyMOLEngine.isScriptedLaunch(environment: [:]))
    }

    func testAutoCmdIsScripted() {
        XCTAssertTrue(PyMOLEngine.isScriptedLaunch(environment: ["PYMOL_AUTOCMD": "set metal_shadows, 0"]))
    }

    func testAutoLoadIsScripted() {
        XCTAssertTrue(PyMOLEngine.isScriptedLaunch(environment: ["PYMOL_AUTOLOAD": "1crn.pdb"]))
    }

    func testUnrelatedEnvironmentVariablesAreNotScripted() {
        let env = [
            "PYMOL_AUTOEXPORT": "out.png,800,600",
            "PYMOL_SKIP_WHATS_NEW": "1",
        ]
        XCTAssertFalse(PyMOLEngine.isScriptedLaunch(environment: env))
    }

    /// The launch-time theme rule itself (#671), as applyPersistedTheme uses it.
    func testLaunchThemePlan() {
        typealias Plan = PyMOLEngine.LaunchThemePlan
        // Fresh launch: the theme sets the toggles and the outline default.
        XCTAssertEqual(PyMOLEngine.launchThemePlan(scripted: false, sessionOwnsRenderState: false),
                       Plan(applyRenderToggles: true, forceOutlineOff: true))
        // Restored/opened session: its toggles win, the outline default still applies.
        XCTAssertEqual(PyMOLEngine.launchThemePlan(scripted: false, sessionOwnsRenderState: true),
                       Plan(applyRenderToggles: false, forceOutlineOff: true))
        // Scripted launch: the script's metal_shadows / metal_raytrace /
        // metal_outline survive the theme (neither toggles nor outline-off).
        XCTAssertEqual(PyMOLEngine.launchThemePlan(scripted: true, sessionOwnsRenderState: false),
                       Plan(applyRenderToggles: false, forceOutlineOff: false))
        XCTAssertEqual(PyMOLEngine.launchThemePlan(scripted: true, sessionOwnsRenderState: true),
                       Plan(applyRenderToggles: false, forceOutlineOff: false))
    }
}

// MARK: - AutosaveRestoreGuardTests (#385)

/// Covers the cold-launch session restore escape hatch (#385): ensuring that an
/// interrupted restore prompts the user rather than blindly retrying and bricking
/// the app on watchdog kills.
final class AutosaveRestoreGuardTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "raymol.tests.385.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Every combination of the four inputs, against a literal table (not the
    /// production expression): skip when scripted, opening a file or no
    /// autosave; otherwise ask after an interrupted restore, else restore.
    func testDecisionTable() {
        typealias A = PyMOLEngine.AutosaveRestoreAction
        // (scripted, openRequested, autosavePresent, interrupted) -> expected
        let table: [(Bool, Bool, Bool, Bool, A)] = [
            (false, false, false, false, .skip),
            (false, false, false, true,  .skip),
            (false, false, true,  false, .restore),
            (false, false, true,  true,  .askStartEmpty),
            (false, true,  false, false, .skip),
            (false, true,  false, true,  .skip),
            (false, true,  true,  false, .skip),
            (false, true,  true,  true,  .skip),
            (true,  false, false, false, .skip),
            (true,  false, false, true,  .skip),
            (true,  false, true,  false, .skip),
            (true,  false, true,  true,  .skip),
            (true,  true,  false, false, .skip),
            (true,  true,  false, true,  .skip),
            (true,  true,  true,  false, .skip),
            (true,  true,  true,  true,  .skip),
        ]
        for (scripted, open, present, interrupted, expected) in table {
            XCTAssertEqual(PyMOLEngine.autosaveRestoreAction(
                scripted: scripted, openRequested: open,
                autosavePresent: present, previousRestoreInterrupted: interrupted),
                expected,
                "scripted=\(scripted) open=\(open) present=\(present) interrupted=\(interrupted)")
        }
    }

    /// A scripted launch (#671) is never prompted, even after an interrupted restore.
    func testScriptedLaunchNeverAsksEvenAfterInterruptedRestore() {
        let action = PyMOLEngine.autosaveRestoreAction(
            scripted: true,
            openRequested: false,
            autosavePresent: true,
            previousRestoreInterrupted: true
        )
        XCTAssertEqual(action, .skip)
    }

    /// A plain launch after an interrupted restore asks instead of retrying.
    func testInterruptedRestoreAsks() {
        let action = PyMOLEngine.autosaveRestoreAction(
            scripted: false,
            openRequested: false,
            autosavePresent: true,
            previousRestoreInterrupted: true
        )
        XCTAssertEqual(action, .askStartEmpty)
    }

    /// The flag is set before the load and survives until the restored scene
    /// has presented both countdown frames: the rep geometry is built on those
    /// frames, so a kill there must still read as interrupted next launch.
    func testFlagClearsOnlyAfterRestoredFramesPresent() {
        XCTAssertFalse(PyMOLEngine.restoreWasInterrupted(in: defaults))
        PyMOLEngine.markRestoreInProgress(in: defaults)
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults))

        var left = PyMOLEngine.restoreFlagCountdown(afterPresenting: 2, defaults: defaults)
        XCTAssertEqual(left, 1)
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults),
                      "first frame (geometry build) must not clear the flag")

        left = PyMOLEngine.restoreFlagCountdown(afterPresenting: left, defaults: defaults)
        XCTAssertNil(left)
        XCTAssertFalse(PyMOLEngine.restoreWasInterrupted(in: defaults))
    }

    /// With nothing pending, a presented frame leaves the flag alone.
    func testCountdownWithNothingPendingIsANoOp() {
        PyMOLEngine.markRestoreInProgress(in: defaults)
        XCTAssertNil(PyMOLEngine.restoreFlagCountdown(afterPresenting: nil, defaults: defaults))
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults))
    }

    /// A kill mid-restore leaves the flag set (the clear never runs), and the
    /// next launch then asks.
    func testKilledMidRestoreLeavesFlagForNextLaunch() {
        defaults.set(true, forKey: PyMOLEngine.restoreInProgressDefaultsKey)
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults))
        let action = PyMOLEngine.autosaveRestoreAction(
            scripted: false,
            openRequested: false,
            autosavePresent: true,
            previousRestoreInterrupted: PyMOLEngine.restoreWasInterrupted(in: defaults)
        )
        XCTAssertEqual(action, .askStartEmpty)
    }

    /// "Start Empty" (via clearAutosave) and a fresh autosave clear the flag.
    func testClearRestoreInProgress() {
        defaults.set(true, forKey: PyMOLEngine.restoreInProgressDefaultsKey)
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults))
        PyMOLEngine.clearRestoreInProgress(in: defaults)
        XCTAssertFalse(PyMOLEngine.restoreWasInterrupted(in: defaults))
    }

    /// A "Try Again" restore that completes clears the flag the killed one left.
    func testSuccessfulRetryClearsLeftoverFlag() {
        defaults.set(true, forKey: PyMOLEngine.restoreInProgressDefaultsKey)
        XCTAssertTrue(PyMOLEngine.restoreWasInterrupted(in: defaults))
        PyMOLEngine.markRestoreInProgress(in: defaults)
        var left: Int? = 2
        while left != nil {
            left = PyMOLEngine.restoreFlagCountdown(afterPresenting: left, defaults: defaults)
        }
        XCTAssertFalse(PyMOLEngine.restoreWasInterrupted(in: defaults))
    }
}
