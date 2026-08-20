import XCTest
@testable import RayMol

/// Arithmetic for the persisted panel layout (#331 / #332).
final class PanelLayoutTests: XCTestCase {

    /// The macOS ceiling for the window the VM tests run at (684pt tall).
    private let macMax = PanelLayout.maxConsoleHeight(windowHeight: 684)

    // MARK: - console height from a stored fraction (#331)

    func testDefaultFracIsOneFifth() {
        XCTAssertEqual(PanelLayout.defaultConsoleFrac, 0.2, accuracy: 1e-9)
    }

    func testDefaultFracGivesOneFifthOfTheWindow() {
        // 900pt window -> 180pt, exactly a fifth, well inside the ceiling.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: PanelLayout.defaultConsoleFrac,
                                      windowHeight: 900, minHeight: 44,
                                      maxHeight: PanelLayout.maxConsoleHeight(windowHeight: 900)),
            180, accuracy: 1e-9)
    }

    func testStoredFractionIsHonouredInsideTheBand() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.35, windowHeight: 1000, minHeight: 44,
                                      maxHeight: PanelLayout.maxConsoleHeight(windowHeight: 1000)),
            350, accuracy: 1e-9)
    }

    func testTooSmallFractionIsLiftedToTheMinimum() {
        // 0.01 * 800 = 8pt, below the platform floor.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, minHeight: 44,
                                      maxHeight: 400),
            44, accuracy: 1e-9)
        // iOS carries a taller floor (60pt) for the same fraction.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, minHeight: 60,
                                      maxHeight: 400),
            60, accuracy: 1e-9)
    }

    func testFractionAboveTheCeilingIsCapped() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.9, windowHeight: 684, minHeight: 44,
                                      maxHeight: macMax),
            macMax, accuracy: 1e-9)
    }

    /// The acceptance criterion for restoring into a much smaller window: when the
    /// ceiling falls BELOW the usable minimum, the ceiling still wins, so the
    /// viewport is never squeezed away entirely.
    func testCeilingOutranksTheMinimum() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.5, windowHeight: 100, minHeight: 44,
                                      maxHeight: 20),
            20, accuracy: 1e-9)
    }

    func testNonPositiveWindowHeightFallsBackToTheMinimum() {
        // A GeometryReader's first pass can report 0; don't hand back 0 or NaN.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.2, windowHeight: 0, minHeight: 44,
                                      maxHeight: 200),
            44, accuracy: 1e-9)
    }

    func testGarbageStoredFractionFallsBackToTheDefault() {
        // 0 is what an unset UserDefaults Double reads as; negative or non-finite
        // can only come from corruption.
        for bad in [CGFloat(0), -0.5, .nan, .infinity] {
            XCTAssertEqual(
                PanelLayout.consoleHeight(frac: bad, windowHeight: 900, minHeight: 44,
                                          maxHeight: 500),
                180, accuracy: 1e-9,
                "frac \(bad) should fall back to the 1/5 default")
        }
    }

    // MARK: - the macOS ceiling (#317 must keep working)

    func testCeilingLeavesTheViewportItsMinimum() {
        // 684pt window, 360pt viewport minimum -> the console may reach 324pt,
        // i.e. 47% of the window: plenty for reading a long predict log.
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 684), 324, accuracy: 1e-9)
    }

    func testCeilingNeverExceedsEightyFivePercent() {
        // A tall window would otherwise let the console take all but 360pt.
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 4000),
                       3400, accuracy: 1e-9)
    }

    func testCeilingNeverFallsBelowTheDefaultShare() {
        // Shorter than the viewport minimum: the console still gets its fifth
        // rather than a negative/zero ceiling.
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 300),
                       60, accuracy: 1e-9)
    }

    func testCeilingOfADegenerateWindowIsZero() {
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 0), 0, accuracy: 1e-9)
    }

    // MARK: - measured height back to a fraction (#332)

    func testFractionRoundTripsThroughAHeight() {
        let h = PanelLayout.consoleHeight(frac: 0.31, windowHeight: 1000,
                                          minHeight: 44, maxHeight: 640)
        XCTAssertEqual(PanelLayout.consoleFrac(height: h, windowHeight: 1000),
                       0.31, accuracy: 1e-9)
    }

    func testMeasuredFractionIsClampedIntoTheStorableBand() {
        XCTAssertEqual(PanelLayout.consoleFrac(height: 2, windowHeight: 1000),
                       PanelLayout.minStorableFrac, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.consoleFrac(height: 990, windowHeight: 1000),
                       PanelLayout.maxStorableFrac, accuracy: 1e-9)
    }

    func testMeasuredFractionIgnoresADegenerateWindow() {
        XCTAssertEqual(PanelLayout.consoleFrac(height: 100, windowHeight: 0),
                       PanelLayout.defaultConsoleFrac, accuracy: 1e-9)
    }

    /// The whole point of storing a fraction: a console dragged to 40% of a big
    /// window comes back at 40% of a small one, not at an unusable absolute size.
    func testAFractionRestoresProportionallyIntoASmallerWindow() {
        let stored = PanelLayout.consoleFrac(height: 560, windowHeight: 1400)
        XCTAssertEqual(stored, 0.4, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: stored, windowHeight: 700, minHeight: 44,
                                      maxHeight: PanelLayout.maxConsoleHeight(windowHeight: 700)),
            280, accuracy: 1e-9)
    }

    // MARK: - iPad bottom-panel fraction (#332)

    func testPanelFracPassesThroughInsideItsBand() {
        XCTAssertEqual(PanelLayout.clampPanelFrac(0.53), 0.53, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.clampPanelFrac(0.6), 0.6, accuracy: 1e-9)
    }

    func testPanelFracIsClampedAtBothEnds() {
        XCTAssertEqual(PanelLayout.clampPanelFrac(0.02),
                       PanelLayout.minPanelFrac, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.clampPanelFrac(0.99),
                       PanelLayout.maxPanelFrac, accuracy: 1e-9)
    }

    func testUnsetPanelFracFallsBackToTheDefault() {
        XCTAssertEqual(PanelLayout.clampPanelFrac(0),
                       PanelLayout.defaultPanelFrac, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.clampPanelFrac(.nan),
                       PanelLayout.defaultPanelFrac, accuracy: 1e-9)
    }

    // MARK: - key namespace

    func testEveryKeyIsNamespaced() {
        for key in PanelLayout.allKeys {
            XCTAssertTrue(key.hasPrefix("raymol.panels."), "\(key) is not namespaced")
        }
    }

    func testKeysAreUnique() {
        XCTAssertEqual(Set(PanelLayout.allKeys).count, PanelLayout.allKeys.count)
    }
}
