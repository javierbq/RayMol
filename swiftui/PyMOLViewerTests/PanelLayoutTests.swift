import XCTest
@testable import RayMol

/// Arithmetic for the persisted panel layout (#331 / #332).
final class PanelLayoutTests: XCTestCase {

    /// The macOS ceiling for the window the VM tests run at (684pt tall).
    private let macMax = PanelLayout.maxConsoleHeight(windowHeight: 684)

    // MARK: - the untouched default (#331)

    /// The default is ABSOLUTE, not a share: an untouched console is the same
    /// height on a laptop and on a 6K display, which is what the app has always
    /// done. A fraction-based default grew to 280pt on a large monitor.
    func testUnsetFracYieldsTheAbsoluteDefault() {
        for window in [CGFloat(684), 900, 1400, 2400] {
            XCTAssertEqual(
                PanelLayout.consoleHeight(frac: 0, windowHeight: window,
                                          defaultHeight: PanelLayout.macDefaultConsoleHeight,
                                          minHeight: 44,
                                          maxHeight: PanelLayout.maxConsoleHeight(windowHeight: window)),
                PanelLayout.macDefaultConsoleHeight, accuracy: 1e-9,
                "an untouched console must not scale with a \(window)pt window")
        }
    }

    func testEachPlatformHasItsOwnDefault() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0, windowHeight: 1376,
                                      defaultHeight: PanelLayout.iosDefaultConsoleHeight,
                                      minHeight: PanelLayout.iosMinConsoleHeight,
                                      maxHeight: 454),
            110, accuracy: 1e-9)
    }

    func testGarbageStoredFractionFallsBackToTheDefault() {
        // 0 is what an unset UserDefaults Double reads as; negative or non-finite
        // can only come from corruption.
        for bad in [CGFloat(0), -0.5, .nan, .infinity] {
            XCTAssertEqual(
                PanelLayout.consoleHeight(frac: bad, windowHeight: 900, defaultHeight: 130,
                                          minHeight: 44, maxHeight: 500),
                130, accuracy: 1e-9,
                "frac \(bad) should fall back to the default height")
        }
    }

    func testDefaultIsStillClampedByThePlatformBounds() {
        // A default taller than the ceiling (a very short window) is capped...
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0, windowHeight: 300, defaultHeight: 130,
                                      minHeight: 44,
                                      maxHeight: PanelLayout.maxConsoleHeight(windowHeight: 300)),
            60, accuracy: 1e-9)
        // ...and one below the usable floor is lifted.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0, windowHeight: 900, defaultHeight: 20,
                                      minHeight: 44, maxHeight: 500),
            44, accuracy: 1e-9)
    }

    // MARK: - a size the user chose (#332)

    func testStoredFractionIsHonouredInsideTheBand() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.35, windowHeight: 1000, defaultHeight: 130,
                                      minHeight: 44,
                                      maxHeight: PanelLayout.maxConsoleHeight(windowHeight: 1000)),
            350, accuracy: 1e-9)
    }

    func testStoredFractionBeatsTheDefault() {
        // The whole point: once resized, the default no longer applies.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.1, windowHeight: 900, defaultHeight: 130,
                                      minHeight: 44, maxHeight: 500),
            90, accuracy: 1e-9)
    }

    func testTooSmallFractionIsLiftedToTheMinimum() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, defaultHeight: 130,
                                      minHeight: 44, maxHeight: 400),
            44, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.01, windowHeight: 800, defaultHeight: 130,
                                      minHeight: 60, maxHeight: 400),
            60, accuracy: 1e-9)
    }

    func testFractionAboveTheCeilingIsCapped() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.9, windowHeight: 684, defaultHeight: 130,
                                      minHeight: 44, maxHeight: macMax),
            macMax, accuracy: 1e-9)
    }

    /// The acceptance criterion for restoring into a much smaller window: when the
    /// ceiling falls BELOW the usable minimum, the ceiling still wins, so the
    /// viewport is never squeezed away entirely.
    func testCeilingOutranksTheMinimum() {
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.5, windowHeight: 100, defaultHeight: 130,
                                      minHeight: 44, maxHeight: 20),
            20, accuracy: 1e-9)
    }

    func testNonPositiveWindowHeightFallsBackToTheMinimum() {
        // A GeometryReader's first pass can report 0; don't hand back 0 or NaN.
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: 0.2, windowHeight: 0, defaultHeight: 130,
                                      minHeight: 44, maxHeight: 200),
            44, accuracy: 1e-9)
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

    func testCeilingNeverFallsBelowMinCeilingFrac() {
        // Shorter than the viewport minimum: the console may still take
        // minCeilingFrac rather than facing a negative/zero ceiling.
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 300),
                       60, accuracy: 1e-9)
    }

    func testCeilingOfADegenerateWindowIsZero() {
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 0), 0, accuracy: 1e-9)
    }

    // MARK: - measured height back to a fraction (#332)

    func testFractionRoundTripsThroughAHeight() throws {
        let h = PanelLayout.consoleHeight(frac: 0.31, windowHeight: 1000,
                                          defaultHeight: 130, minHeight: 44, maxHeight: 640)
        XCTAssertEqual(try XCTUnwrap(PanelLayout.consoleFrac(height: h, windowHeight: 1000)),
                       0.31, accuracy: 1e-9)
    }

    func testMeasuredFractionIsClampedIntoTheStorableBand() throws {
        XCTAssertEqual(try XCTUnwrap(PanelLayout.consoleFrac(height: 2, windowHeight: 1000)),
                       PanelLayout.minStorableFrac, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PanelLayout.consoleFrac(height: 990, windowHeight: 1000)),
                       PanelLayout.maxStorableFrac, accuracy: 1e-9)
    }

    func testNothingIsStorableForADegenerateWindow() {
        // nil, not a made-up number: the caller must skip the write entirely.
        XCTAssertNil(PanelLayout.consoleFrac(height: 100, windowHeight: 0))
        XCTAssertNil(PanelLayout.consoleFrac(height: .nan, windowHeight: 800))
    }

    /// The whole point of storing a fraction: a console dragged to 40% of a big
    /// window comes back at 40% of a small one, not at an unusable absolute size.
    func testAFractionRestoresProportionallyIntoASmallerWindow() throws {
        let stored = try XCTUnwrap(PanelLayout.consoleFrac(height: 560, windowHeight: 1400))
        XCTAssertEqual(stored, 0.4, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.consoleHeight(frac: stored, windowHeight: 700,
                                      defaultHeight: 130, minHeight: 44,
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

    // MARK: - macOS inspector width (#350)

    /// Same contract as the console: untouched means the ABSOLUTE default, on
    /// any display.
    func testUnsetInspectorFracYieldsTheAbsoluteDefault() {
        for window in [CGFloat(1000), 1512, 2400] {
            XCTAssertEqual(
                PanelLayout.inspectorWidth(
                    frac: 0, windowWidth: window,
                    maxWidth: PanelLayout.maxInspectorWidth(windowWidth: window)),
                PanelLayout.macDefaultInspectorWidth, accuracy: 1e-9,
                "an untouched inspector must not scale with a \(window)pt window")
        }
    }

    func testStoredInspectorFractionIsHonouredInsideTheBand() {
        XCTAssertEqual(
            PanelLayout.inspectorWidth(
                frac: 0.3, windowWidth: 1600,
                maxWidth: PanelLayout.maxInspectorWidth(windowWidth: 1600)),
            480, accuracy: 1e-9)
    }

    func testInspectorNeverShrinksBelowItsRowChromeMinimum() {
        XCTAssertEqual(
            PanelLayout.inspectorWidth(
                frac: 0.05, windowWidth: 1600,
                maxWidth: PanelLayout.maxInspectorWidth(windowWidth: 1600)),
            PanelLayout.macMinInspectorWidth, accuracy: 1e-9)
    }

    func testInspectorFractionAboveTheCeilingIsCapped() {
        // 1000pt window: ceiling = min(max(1000-480, 200), 500) = 500.
        XCTAssertEqual(
            PanelLayout.inspectorWidth(
                frac: 0.9, windowWidth: 1000,
                maxWidth: PanelLayout.maxInspectorWidth(windowWidth: 1000)),
            500, accuracy: 1e-9)
    }

    func testInspectorCeilingLeavesTheViewportItsMinimum() {
        // 800pt window, 480pt viewport minimum -> the inspector may reach 320pt.
        XCTAssertEqual(PanelLayout.maxInspectorWidth(windowWidth: 800),
                       320, accuracy: 1e-9)
    }

    func testInspectorCeilingNeverExceedsHalfTheWindow() {
        // A wide window would otherwise let the sidebar take all but 480pt.
        XCTAssertEqual(PanelLayout.maxInspectorWidth(windowWidth: 2000),
                       1000, accuracy: 1e-9)
    }

    func testInspectorCeilingNeverFallsBelowMinCeilingFrac() {
        XCTAssertEqual(PanelLayout.maxInspectorWidth(windowWidth: 500),
                       100, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.maxInspectorWidth(windowWidth: 0), 0, accuracy: 1e-9)
    }

    func testInspectorFractionRoundTripsThroughAWidth() throws {
        let w = PanelLayout.inspectorWidth(
            frac: 0.31, windowWidth: 1600,
            maxWidth: PanelLayout.maxInspectorWidth(windowWidth: 1600))
        XCTAssertEqual(try XCTUnwrap(PanelLayout.inspectorFrac(width: w, windowWidth: 1600)),
                       0.31, accuracy: 1e-9)
    }

    func testMeasuredInspectorFractionIsClampedIntoTheStorableBand() throws {
        XCTAssertEqual(try XCTUnwrap(PanelLayout.inspectorFrac(width: 2, windowWidth: 1000)),
                       PanelLayout.minStorableFrac, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(PanelLayout.inspectorFrac(width: 990, windowWidth: 1000)),
                       PanelLayout.maxStorableFrac, accuracy: 1e-9)
    }

    func testNoInspectorFractionIsStorableForADegenerateWindow() {
        XCTAssertNil(PanelLayout.inspectorFrac(width: 340, windowWidth: 0))
        XCTAssertNil(PanelLayout.inspectorFrac(width: .nan, windowWidth: 1000))
    }

    /// The point of storing a fraction: a sidebar dragged to 30% of a wide window
    /// comes back proportional in a narrower one — still clamped by ITS ceiling.
    func testInspectorFractionRestoresProportionallyIntoASmallerWindow() throws {
        let stored = try XCTUnwrap(PanelLayout.inspectorFrac(width: 600, windowWidth: 2000))
        XCTAssertEqual(stored, 0.3, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.inspectorWidth(
                frac: stored, windowWidth: 1200,
                maxWidth: PanelLayout.maxInspectorWidth(windowWidth: 1200)),
            360, accuracy: 1e-9)
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

    /// #623: the iPad float's corner is a namespaced key in the list, and
    /// an absent or unknown stored value reads as the default corner.
    func testTheFloatCornerKeyIsListed() {
        XCTAssertEqual(PanelLayout.lightsOrbitCornerKey, "raymol.panels.lightsOrbitCorner")
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.lightsOrbitCornerKey))
        XCTAssertEqual(LightsFloatCorner.stored(""), .bottomLeading)
        XCTAssertEqual(LightsFloatCorner.stored("xx"), .bottomLeading)
        XCTAssertEqual(LightsFloatCorner.stored("tr"), .topTrailing)
    }
}

// MARK: - iPhone chrome fade (#391)

final class PhoneChromeFadeTests: XCTestCase {
    private let t0: TimeInterval = 1_000_000

    func testJustAfterInteractionControlsAreFullyVisibleAndHitTestable() {
        for dt in [0.0, 1.0, 2.9] {
            let app = PhoneChromeFade.appearance(
                now: t0 + dt,
                lastInteraction: t0,
                gestureActive: false,
                pinned: false
            )
            XCTAssertEqual(app.opacity, 1.0, accuracy: 1e-9)
            XCTAssertTrue(app.isHitTestable)
        }
    }

    func testIdleControlsAreDimmedAndHitTestable() {
        for dt in [PhoneChromeFade.idleDelay, 10.0] {
            let app = PhoneChromeFade.appearance(
                now: t0 + dt,
                lastInteraction: t0,
                gestureActive: false,
                pinned: false
            )
            XCTAssertEqual(app.opacity, PhoneChromeFade.idleOpacity, accuracy: 1e-9)
            XCTAssertTrue(app.isHitTestable)
        }
    }

    func testGestureActiveHidesControlsAndDisablesHitTesting() {
        for dt in [0.0, 10.0] {
            let app = PhoneChromeFade.appearance(
                now: t0 + dt,
                lastInteraction: t0,
                gestureActive: true,
                pinned: false
            )
            XCTAssertEqual(app.opacity, 0.0, accuracy: 1e-9)
            XCTAssertFalse(app.isHitTestable)
        }
    }

    func testPinnedBeatsBothGestureAndIdle() {
        // Pinned while idle
        let idlePinned = PhoneChromeFade.appearance(
            now: t0 + 10.0,
            lastInteraction: t0,
            gestureActive: false,
            pinned: true
        )
        XCTAssertEqual(idlePinned.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(idlePinned.isHitTestable)

        // Pinned during active gesture
        let gesturePinned = PhoneChromeFade.appearance(
            now: t0 + 0.0,
            lastInteraction: t0,
            gestureActive: true,
            pinned: true
        )
        XCTAssertEqual(gesturePinned.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(gesturePinned.isHitTestable)

        // Pinned during active gesture and after idle timeout
        let gestureAndIdlePinned = PhoneChromeFade.appearance(
            now: t0 + 10.0,
            lastInteraction: t0,
            gestureActive: true,
            pinned: true
        )
        XCTAssertEqual(gestureAndIdlePinned.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(gestureAndIdlePinned.isHitTestable)
    }

    func testLastInteractionInTheFutureShowsFully() {
        let app = PhoneChromeFade.appearance(
            now: t0,
            lastInteraction: t0 + 10.0,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(app.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(app.isHitTestable)
    }

    func testNextChange() {
        // Within the delay -> t0 + idleDelay
        let next = PhoneChromeFade.nextChange(
            now: t0 + 1.0,
            lastInteraction: t0,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(next, t0 + PhoneChromeFade.idleDelay)

        // At the deadline -> nil
        XCTAssertNil(PhoneChromeFade.nextChange(
            now: t0 + PhoneChromeFade.idleDelay,
            lastInteraction: t0,
            gestureActive: false,
            pinned: false
        ))

        // After the deadline -> nil
        XCTAssertNil(PhoneChromeFade.nextChange(
            now: t0 + 10.0,
            lastInteraction: t0,
            gestureActive: false,
            pinned: false
        ))

        // Gesture active -> nil
        XCTAssertNil(PhoneChromeFade.nextChange(
            now: t0 + 1.0,
            lastInteraction: t0,
            gestureActive: true,
            pinned: false
        ))

        // Pinned -> nil
        XCTAssertNil(PhoneChromeFade.nextChange(
            now: t0 + 1.0,
            lastInteraction: t0,
            gestureActive: false,
            pinned: true
        ))
    }

    /// A last interaction ahead of `now` (it can't happen on the monotonic clock,
    /// but the rule must stay sane): shown, and the dim is due idleDelay after it.
    func testNextChangeWithAFutureLastInteraction() {
        XCTAssertEqual(PhoneChromeFade.nextChange(now: t0, lastInteraction: t0 + 10,
                                                  gestureActive: false, pinned: false),
                       t0 + 10 + PhoneChromeFade.idleDelay)
    }

    func testSequence() {
        // Touch at t0 -> visible
        let atT0 = PhoneChromeFade.appearance(
            now: t0,
            lastInteraction: t0,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(atT0.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(atT0.isHitTestable)

        // Gesture begins at t0+5 (gestureActive true, lastInteraction t0+5) -> 0
        let tGestureBegin = t0 + 5.0
        let atGestureBegin = PhoneChromeFade.appearance(
            now: tGestureBegin,
            lastInteraction: tGestureBegin,
            gestureActive: true,
            pinned: false
        )
        XCTAssertEqual(atGestureBegin.opacity, 0.0, accuracy: 1e-9)
        XCTAssertFalse(atGestureBegin.isHitTestable)

        // Gesture ends at t0+8 (lastInteraction t0+8, false) -> 1 at t0+8 and t0+10.9, 0.25 at t0+11
        let tGestureEnd = t0 + 8.0
        let atGestureEnd = PhoneChromeFade.appearance(
            now: tGestureEnd,
            lastInteraction: tGestureEnd,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(atGestureEnd.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(atGestureEnd.isHitTestable)

        let atT10_9 = PhoneChromeFade.appearance(
            now: t0 + 10.9,
            lastInteraction: tGestureEnd,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(atT10_9.opacity, 1.0, accuracy: 1e-9)
        XCTAssertTrue(atT10_9.isHitTestable)

        let atT11 = PhoneChromeFade.appearance(
            now: t0 + 11.0,
            lastInteraction: tGestureEnd,
            gestureActive: false,
            pinned: false
        )
        XCTAssertEqual(atT11.opacity, 0.25, accuracy: 1e-9)
        XCTAssertTrue(atT11.isHitTestable)
    }
}
