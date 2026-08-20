import XCTest
@testable import RayMol

/// Arithmetic for the persisted panel layout (#331 / #332). Every case here is
/// arithmetic on `PanelLayout`'s three constants: defaultConsoleFrac (0.2),
/// maxConsoleFrac (0.4) and the caller-supplied minimum height.
final class PanelLayoutTests: XCTestCase {

    // MARK: - console height from a stored fraction (#331)

    func testDefaultFracIsOneFifth() {
        XCTAssertEqual(PanelLayout.defaultConsoleFrac, 0.2, accuracy: 1e-9)
    }

    func testDefaultFracGivesOneFifthOfTheWindow() {
        // 900pt window, macOS minimum -> 180pt, exactly a fifth.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: PanelLayout.defaultConsoleFrac,
                                      windowHeight: 900, minHeight: 44),
            180, accuracy: 1e-9)
    }

    func testStoredFractionIsHonouredInsideTheBand() {
        // 0.35 is between the 44pt floor and the 0.4 ceiling for a 1000pt window.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.35, windowHeight: 1000, minHeight: 44),
            350, accuracy: 1e-9)
    }

    func testTooSmallFractionIsLiftedToTheMinimum() {
        // 0.01 * 800 = 8pt, below the 44pt macOS minimum.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, minHeight: 44),
            44, accuracy: 1e-9)
        // iOS carries a taller floor (60pt) for the same fraction.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, minHeight: 60),
            60, accuracy: 1e-9)
    }

    func testTooLargeFractionIsCappedAtFortyPercent() {
        // 0.9 * 1000 = 900pt would leave no viewport; the 0.4 ceiling wins.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.9, windowHeight: 1000, minHeight: 44),
            400, accuracy: 1e-9)
    }

    /// The acceptance criterion for restoring into a much smaller window: when the
    /// 40% ceiling falls BELOW the usable minimum, the ceiling still wins, so the
    /// viewport keeps 60% of the window rather than being squeezed away.
    func testCeilingOutranksTheMinimumInATinyWindow() {
        // 0.4 * 100 = 40pt < the 44pt minimum -> 40pt, not 44pt.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.2, windowHeight: 100, minHeight: 44),
            40, accuracy: 1e-9)
    }

    func testNonPositiveWindowHeightFallsBackToTheMinimum() {
        // A GeometryReader's first pass can report 0; don't hand back 0 or NaN.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.2, windowHeight: 0, minHeight: 44),
            44, accuracy: 1e-9)
    }

    func testGarbageStoredFractionFallsBackToTheDefault() {
        // A 0 fraction is what an unset UserDefaults Double reads as, and a
        // negative or non-finite one can only come from corruption.
        for bad in [CGFloat(0), -0.5, .nan, .infinity] {
            XCTAssertEqual(
                PanelLayout.consoleHeight(frac: bad, windowHeight: 900, minHeight: 44),
                180, accuracy: 1e-9,
                "frac \(bad) should fall back to the 1/5 default")
        }
    }

    // MARK: - measured height back to a fraction (#332)

    func testFractionRoundTripsThroughAHeight() {
        let h = PanelLayout.consoleHeight(frac: 0.31, windowHeight: 1000, minHeight: 44)
        XCTAssertEqual(PanelLayout.consoleFrac(height: h, windowHeight: 1000),
                       0.31, accuracy: 1e-9)
    }

    func testMeasuredFractionIsClampedIntoTheStorableBand() {
        // Whatever the splitter reports, never store something that can't be
        // restored: below 1% or above the 0.4 ceiling is clamped on the way in.
        XCTAssertEqual(PanelLayout.consoleFrac(height: 2, windowHeight: 1000),
                       PanelLayout.minStorableFrac, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.consoleFrac(height: 950, windowHeight: 1000),
                       PanelLayout.maxConsoleFrac, accuracy: 1e-9)
    }

    func testMeasuredFractionIgnoresADegenerateWindow() {
        // windowHeight 0 -> keep the default rather than dividing by zero.
        XCTAssertEqual(PanelLayout.consoleFrac(height: 100, windowHeight: 0),
                       PanelLayout.defaultConsoleFrac, accuracy: 1e-9)
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
        // 0 is an unset UserDefaults Double; NaN can only be corruption.
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
