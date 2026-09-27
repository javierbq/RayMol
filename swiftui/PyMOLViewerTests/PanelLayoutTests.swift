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
        // 684pt window, 280pt viewport minimum (#543) -> the console may reach 404pt,
        // i.e. 59% of the window: plenty for reading a long predict log.
        XCTAssertEqual(PanelLayout.maxConsoleHeight(windowHeight: 684), 404, accuracy: 1e-9)
    }

    /// Javier's #543 decision, pinned: the 3D view's floor is 280, and the view's own
    /// frame reads the same constant (ContentView.macViewport), so this IS the floor.
    func testTheViewportFloorIs280() {
        XCTAssertEqual(PanelLayout.macViewportMinHeight, 280, accuracy: 1e-9)
    }

    func testCeilingNeverExceedsEightyFivePercent() {
        // A tall window would otherwise let the console take all but 280pt.
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

    // MARK: - Data drawer (#417)

    func testDrawerKeysAreRegistered() {
        // The namespace/uniqueness tests below run off allKeys, so a key missing
        // from it would silently escape them.
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.dataDrawerVisibleKey))
        XCTAssertTrue(PanelLayout.allKeys.contains(PanelLayout.dataDrawerFracKey))
    }

    func testUntouchedDrawerIsTheAbsoluteDefault() {
        // Same rule as the console (#331): an unresized drawer is 220pt on a laptop
        // and on a 6K display, not a share of either.
        for window in [CGFloat(900), 1400, 2400] {
            XCTAssertEqual(PanelLayout.drawerHeight(frac: 0, windowHeight: window),
                           PanelLayout.macDefaultDrawerHeight, accuracy: 1e-9)
        }
    }

    func testDrawerHonoursAStoredFractionInsideItsBounds() {
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.3, windowHeight: 1000), 300, accuracy: 1e-9)
        // Too small is lifted to the floor; too large is capped by the same ceiling
        // the console uses, so the viewport keeps its minimum.
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.02, windowHeight: 1000),
                       PanelLayout.macMinDrawerHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.9, windowHeight: 1000),
                       PanelLayout.maxDrawerHeight(windowHeight: 1000), accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.maxDrawerHeight(windowHeight: 684),
                       PanelLayout.maxConsoleHeight(windowHeight: 684), accuracy: 1e-9)
    }

    func testDrawerYieldsToAnExplicitCeiling() {
        // The layout hands the drawer the height LEFT after the console band, the
        // rail and the Object sequence viewer (the viewport has a hard 280pt
        // minimum); the ceiling it passes wins over the default AND over a stored
        // fraction.
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0, windowHeight: 771, maxHeight: 180),
                       180, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.5, windowHeight: 771, maxHeight: 180),
                       180, accuracy: 1e-9)
        // A ceiling under the floor: the floor is lifted, not the other way round —
        // better a cramped drawer than one that draws nothing.
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0, windowHeight: 771, maxHeight: 40),
                       40, accuracy: 1e-9)
    }

    // MARK: - the drawer's ceiling in a real column (#417 review)

    /// The drawer's ceiling with the console at its 130pt default, the rail up and the
    /// OBJECT sequence viewer showing FIVE rows — `drawerColumnUsed` as-is, before the
    /// plan's yield (#543), so these are what the column costs when the viewer keeps
    /// every row. Below some window height the drawer would be chrome with no rows, and
    /// `drawerFits` turns that into the one-line hint.
    func testDrawerCeilingInACrowdedColumn() {
        // 197 under #458's 360pt viewport floor; #543's 280 is 80pt more for the drawer.
        XCTAssertEqual(Self.ceiling(window: 900), 277, accuracy: 0.5)
        XCTAssertEqual(Self.ceiling(window: 854), 231, accuracy: 0.5)
        // The banner is 32pt off the same column while it is up (#458).
        XCTAssertEqual(Self.ceiling(window: 854, banner: true), 199, accuracy: 0.5)
        // 800 used to be the hint with five rows of viewer; it draws now. (771 is 148,
        // short of the 154pt floor #544's run header set — the plan's yield covers it.)
        XCTAssertFalse(PanelLayout.drawerFits(ceiling: Self.ceiling(window: 771)))
        for window in [CGFloat(900), 854, 800] {
            XCTAssertTrue(PanelLayout.drawerFits(ceiling: Self.ceiling(window: window)),
                          "\(window)pt, five-row viewer")
        }
        // The app's own content height (719) is the case the plan's yield exists for:
        // a five-row viewer leaves 96, and a one-row viewer 216.
        XCTAssertEqual(Self.ceiling(window: 719), 96, accuracy: 0.5)
        XCTAssertFalse(PanelLayout.drawerFits(ceiling: Self.ceiling(window: 719)))
        XCTAssertEqual(Self.ceiling(window: 719, objects: 1), 216, accuracy: 0.5)
        // At 600 neither pane alone is enough with five rows up, both together are.
        XCTAssertFalse(PanelLayout.drawerFits(ceiling: Self.ceiling(window: 600)))
        XCTAssertFalse(PanelLayout.drawerFits(
            ceiling: Self.ceiling(window: 600, console: false)))
        XCTAssertTrue(PanelLayout.drawerFits(
            ceiling: Self.ceiling(window: 600, objects: nil)))
        XCTAssertTrue(PanelLayout.drawerFits(
            ceiling: Self.ceiling(window: 600, console: false, objects: nil)))
    }

    // MARK: - the drawer's measured minimums (#456 review, kept by #457)

    /// The constants are MEASURED against the views, and this is where they are held to
    /// it. `macMinTabContentHeight` was `macMinDrawerHeight - macDrawerHeaderHeight` =
    /// 70, which is 17pt below the table's chrome ALONE — so the floor could not draw a
    /// footer, let alone a row. That undercount is independent of where the scene
    /// sequences live, which is why it outlives the band that exposed it.
    func testTheDrawersMinimumsAreItsActualPartsAddedUp() {
        XCTAssertEqual(PanelLayout.macMinTabContentHeight,
                       PanelLayout.macDrawerTabRowHeight + PanelLayout.macDrawerHairline
                       + PanelLayout.macDrawerTableChrome + PanelLayout.macDrawerRowHeight,
                       accuracy: 1e-9)
        XCTAssertGreaterThan(PanelLayout.macMinTabContentHeight,
                             PanelLayout.macDrawerTableChrome,
                             "a floor that cannot fit the table's own chrome is not a floor")
        XCTAssertEqual(PanelLayout.macMinDrawerHeight,
                       PanelLayout.macDrawerHeaderHeight + PanelLayout.macDrawerHairline
                       + PanelLayout.macMinTabContentHeight, accuracy: 1e-9)
        // The same number by the other route: chrome + one row. Two definitions that
        // have to agree, so a constant edited on one side cannot drift from the other.
        XCTAssertEqual(PanelLayout.macMinDrawerHeight,
                       PanelLayout.macDrawerChromeHeight + PanelLayout.macDrawerRowHeight,
                       accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.minDrawerHeight(),
                       PanelLayout.macMinDrawerHeight, accuracy: 1e-9)
    }

    /// #456's review stated its regression in one number — "rows = 0 everywhere" — and
    /// this is that number, now that the band is gone and the drawer is one pane again:
    /// any drawer the layout agrees to draw (`drawerFits`) must draw a row of the table.
    ///
    /// The Object viewer is in the column for every case here (one to five objects), so
    /// what this really asserts is that #457 did not re-break the guarantee by putting
    /// a pane back above the drawer — and, since #458, that neither does a column whose
    /// chrome charge depends on what is on screen. Every combination of the two chrome
    /// flags is swept, because the ceiling is now a different number under each.
    func testADrawerThatFitsAlwaysDrawsAtLeastOneTableRow() {
        for window in [CGFloat(600), 700, 719, 771, 800, 854, 900, 1200] {
            for console in [true, false] {
                for objects in [nil, 0, 1, 2, 3, 4, 5] as [Int?] {
                    for banner in [false, true] {
                        for modeBar in [false, true] {
                            let ceiling = Self.ceiling(window: window, console: console,
                                                       objects: objects, banner: banner,
                                                       modeBar: modeBar)
                            guard PanelLayout.drawerFits(ceiling: ceiling) else { continue }
                            let h = PanelLayout.drawerHeight(frac: 0, windowHeight: window,
                                                             maxHeight: ceiling)
                            let rows = PanelLayout.drawerTableRows(drawerHeight: h)
                            XCTAssertGreaterThanOrEqual(
                                rows, 1,
                                "\(window)pt window, console \(console ? "open" : "closed"),"
                                + " viewer \(objects.map { "on with \($0) objects" } ?? "off"),"
                                + " banner \(banner), docked bar \(modeBar):"
                                + " drawer \(h)pt draws \(rows) rows")
                        }
                    }
                }
            }
        }
    }

    /// And the same for the height the user is actually given out of the box, which is
    /// what "untouched drawer height" in the screenshots means.
    func testTheUntouchedDrawerDrawsFourRows() {
        XCTAssertEqual(PanelLayout.defaultDrawerHeight,
                       PanelLayout.macDefaultDrawerHeight, accuracy: 1e-9)
        // 220 - 114 of chrome = 106, which is four 22pt rows and change. The default's
        // own doc-comment says "four rows"; this is what holds it to that.
        XCTAssertEqual(PanelLayout.drawerTableRows(
            drawerHeight: PanelLayout.defaultDrawerHeight), 4)
        // `defaultDrawerHeight` takes no arguments any more: the Object viewer is not
        // IN the drawer, so turning it on cannot change what the drawer defaults to.
        // Under #456 it could — the band's allowance was added here — which is the
        // whole difference between that arrangement and this one.
        XCTAssertEqual(PanelLayout.drawerTableRows(drawerHeight: PanelLayout.macMinDrawerHeight), 1)
        XCTAssertEqual(PanelLayout.drawerTableRows(
            drawerHeight: PanelLayout.macMinDrawerHeight - 1), 0,
            "a drawer below its floor draws nothing, which is `drawerFits`' case")
    }

    /// THE vertical-budget question, answered (#543): 1332×771 is the app's own
    /// persisted window, its content is 719pt (measured on #458), and the default state
    /// has the console up and the Object viewer on. With a set open the drawer must
    /// draw AT LEAST THREE table rows and no hint, whether one object is enabled or the
    /// five-plus a batch stages.
    ///
    /// Under #458 one object drew one row and two were already the hint. What moved it
    /// is the 280pt floor plus the plan's yield: the viewer gives rows up (to one, here,
    /// now that #544's run header makes three rows 198pt) while the drawer is open, and
    /// scrolls the rest.
    func testTheDefaultWindowDrawsThreeRowsWithTheConsoleAndViewerUp() {
        for content in [CGFloat(719), 771] {
            for objects in 0...6 {
                let plan = Self.plan(window: content, objects: objects)
                XCTAssertTrue(plan.drawerFits, "\(content)pt, \(objects) objects: hint")
                let rows = PanelLayout.drawerTableRows(drawerHeight: plan.drawerHeight ?? 0)
                XCTAssertGreaterThanOrEqual(rows, 3, "\(content)pt, \(objects) objects")
                XCTAssertGreaterThanOrEqual(plan.sequenceRows ?? 0, 1,
                                            "the viewer yields rows, never the pane")
            }
        }
        // The numbers at the app's own window: the viewer is down to one row and the
        // drawer is 216 — three rows under the 132pt of chrome — for any object count.
        for objects in [1, 5] {
            let plan = Self.plan(window: 719, objects: objects)
            XCTAssertEqual(plan.sequenceRows, 1)
            XCTAssertEqual(plan.drawerHeight ?? 0, 216, accuracy: 0.5)
            XCTAssertEqual(PanelLayout.drawerTableRows(drawerHeight: plan.drawerHeight ?? 0), 3)
        }
        // A docked Predict/Binder bar is persistent chrome and IS charged: 72pt more
        // than this column has, so the hint — and Hide Console, its first offer, fixes it.
        XCTAssertFalse(Self.plan(window: 719, objects: 5, modeBar: true).drawerFits)
        XCTAssertTrue(Self.plan(window: 719, console: false, objects: 5,
                                modeBar: true).drawerFits)
    }

    /// The yield is the drawer's, so it happens only while the drawer is OPEN, only as
    /// far as the drawer's comfort height needs, and never when it would buy nothing.
    func testTheObjectViewerYieldsRowsOnlyForAnOpenDrawerThatNeedsThem() {
        // Drawer closed: every row, at any window.
        for window in [CGFloat(600), 719, 1200] {
            XCTAssertEqual(Self.plan(window: window, objects: 5, drawerVisible: false)
                            .sequenceRows, 5, "\(window)pt, drawer closed")
            XCTAssertFalse(Self.plan(window: window, objects: 5, drawerVisible: false)
                            .drawerFits)
        }
        // A tall window has room for both: nothing is given up.
        XCTAssertEqual(Self.plan(window: 1200, objects: 5).sequenceRows, 5)
        XCTAssertEqual(Self.plan(window: 900, objects: 5).sequenceRows, 5)
        // Given up only down to the comfort height (three rows, 198pt): at 771 two rows
        // of viewer buy it (148 → 208; one row would leave 178), so only those two go.
        XCTAssertEqual(Self.plan(window: 771, objects: 5).sequenceRows, 3)
        XCTAssertGreaterThanOrEqual(Self.plan(window: 771, objects: 5).drawerCeiling,
                                    PanelLayout.comfortDrawerHeight(tab: .table))
        // Hidden viewer: nothing to yield, nil stays nil.
        XCTAssertNil(Self.plan(window: 719, objects: nil).sequenceRows)
        // Too short for even a one-row viewer to make room: the hint shows and the
        // viewer keeps its rows, because yielding them would buy nothing.
        let short = Self.plan(window: 600, objects: 5)
        XCTAssertFalse(short.drawerFits)
        XCTAssertEqual(short.sequenceRows, 5)
        XCTAssertNil(short.drawerHeight)
        // Every plan's ceiling is the column's arithmetic at the rows it chose — the
        // pane's ideal height and the drawer's ceiling are one computation.
        for window in [CGFloat(600), 719, 771, 900] {
            for objects in [nil, 0, 1, 3, 5] as [Int?] {
                let plan = Self.plan(window: window, objects: objects)
                XCTAssertEqual(plan.drawerCeiling,
                               Self.ceiling(window: window, objects: plan.sequenceRows),
                               accuracy: 1e-9, "\(window)pt, \(String(describing: objects))")
            }
        }
    }

    /// A drawer the USER dragged short is a drawer they want short: the viewer yields
    /// only toward that height (lifted to the tab's floor), not toward the comfort
    /// height, so their sequence rows are not taken for room they did not ask for.
    func testTheYieldRespectsADraggedDrawerHeight() {
        // 0.2 × 719 = 144, lifted to the Table's 154 floor: three viewer rows keep 156.
        let dragged = Self.plan(window: 719, objects: 5, frac: 0.2)
        XCTAssertEqual(dragged.sequenceRows, 3)
        XCTAssertEqual(dragged.drawerHeight ?? 0, 154, accuracy: 0.5)
        XCTAssertEqual(PanelLayout.yieldTarget(tab: .table, drawerFrac: 0.2, windowHeight: 719),
                       154, accuracy: 1e-9)
        // Untouched is the comfort height; a TALL drag is capped at it too — past it
        // the drawer takes what is left, it does not take rows for it.
        XCTAssertEqual(PanelLayout.yieldTarget(tab: .table, drawerFrac: 0, windowHeight: 719),
                       PanelLayout.comfortDrawerHeight(tab: .table), accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.yieldTarget(tab: .table, drawerFrac: 0.6, windowHeight: 719),
                       PanelLayout.comfortDrawerHeight(tab: .table), accuracy: 1e-9)
        XCTAssertEqual(Self.plan(window: 719, objects: 5, frac: 0.6).sequenceRows, 1)
        // The Plot floor lifts the same fraction further.
        XCTAssertEqual(PanelLayout.yieldTarget(tab: .plot, drawerFrac: 0.2, windowHeight: 719),
                       PanelLayout.minDrawerHeight(tab: .plot), accuracy: 1e-9)
    }

    /// The measured content height at 1332×771 is 719, and this is the before/after of
    /// #543 in one place: the one-object column that was exactly #458's floor (136, one
    /// row) now has the 80pt the viewport floor gave back.
    func testTheMeasuredColumnAtTheAppsOwnWindow() {
        let content: CGFloat = 719
        let one = Self.ceiling(window: content, objects: 1)
        XCTAssertEqual(one, 136 + 80, accuracy: 0.5)
        XCTAssertEqual(PanelLayout.drawerTableRows(
            drawerHeight: PanelLayout.drawerHeight(frac: 0, windowHeight: content,
                                                   maxHeight: one)), 3)
        // Closing the console is the first way out the hint offers, and on its own it
        // gives a five-row viewer and a four-row drawer.
        let closed = Self.plan(window: content, console: false, objects: 5)
        XCTAssertEqual(closed.sequenceRows, 5)
        XCTAssertEqual(PanelLayout.drawerTableRows(drawerHeight: closed.drawerHeight ?? 0), 4)
    }

    /// The Object viewer's height formula, which is the strip's own and has never
    /// changed — not when #419 moved the rows into a tab, not when #456 made them a
    /// band, not when #457 brought the pane back.
    func testTheObjectViewerKeepsTheStripsHeightFormula() {
        XCTAssertEqual(PanelLayout.sequenceStripIdealHeight(objects: 1), 60)
        XCTAssertEqual(PanelLayout.sequenceStripIdealHeight(objects: 2), 90)
        XCTAssertEqual(PanelLayout.sequenceStripIdealHeight(objects: 5), 180)
        XCTAssertEqual(PanelLayout.sequenceStripIdealHeight(objects: 99), 180,
                       "capped at five rows")
        XCTAssertEqual(PanelLayout.sequenceStripIdealHeight(objects: 0), 60,
                       "an empty viewer still occupies one row's worth")
        XCTAssertGreaterThan(PanelLayout.sequenceStripIdealHeight(objects: 5), 130,
                             "the flat 130pt cap #419 briefly used was below what five"
                             + " rows need")
    }

    /// The `.id()` that makes the VSplitView re-adopt the pane's ideal height when an
    /// object loads. It has to change exactly when the ideal height does, and not on
    /// every count, or the divider is reset on every unrelated load.
    func testTheViewersIdentityTracksTheRowsItCharges() {
        XCTAssertEqual(PanelLayout.sequenceStripRows(objects: 0), 1)
        XCTAssertEqual(PanelLayout.sequenceStripRows(objects: 1), 1)
        XCTAssertEqual(PanelLayout.sequenceStripRows(objects: 3), 3)
        XCTAssertEqual(PanelLayout.sequenceStripRows(objects: 5), 5)
        XCTAssertEqual(PanelLayout.sequenceStripRows(objects: 40), 5,
                       "past the five-row cap the ideal height stops moving, so the"
                       + " identity has to stop moving with it")
        for objects in [0, 1, 2, 5, 99] {
            XCTAssertEqual(
                PanelLayout.sequenceStripIdealHeight(objects: objects),
                CGFloat(PanelLayout.sequenceStripRows(objects: objects)) * 30 + 30,
                "the layout's height and its identity are the same formula")
        }
    }

    /// The drawer's ceiling in a real column, the way the layout computes it: console
    /// at its default, rail up, and the Object viewer showing `objects` objects (nil =
    /// ⌘2 off). `banner` and `modeBar` are the chrome that comes and goes (#458);
    /// absent by default, because absent is the ordinary session.
    private static func ceiling(window: CGFloat, console: Bool = true,
                                objects: Int? = 5,
                                banner: Bool = false, modeBar: Bool = false) -> CGFloat {
        let h = console ? PanelLayout.consoleHeight(
            frac: 0, windowHeight: window,
            defaultHeight: PanelLayout.macDefaultConsoleHeight,
            minHeight: PanelLayout.macMinConsoleHeight,
            maxHeight: PanelLayout.maxConsoleHeight(windowHeight: window)) : nil
        return PanelLayout.drawerCeiling(
            windowHeight: window,
            used: PanelLayout.drawerColumnUsed(consoleHeight: h, topRail: true,
                                               sequenceRows: objects,
                                               mcpBanner: banner, dockedModeBar: modeBar))
    }

    /// The column planned the way the layout plans it (`macColumnPlan`), with the same
    /// defaults as `ceiling`: console at 130, rail up, drawer open on the Table, an
    /// untouched drawer height.
    private static func plan(window: CGFloat, console: Bool = true,
                             objects: Int? = 5,
                             modeBar: Bool = false, drawerVisible: Bool = true,
                             tab: DataDrawerTab = .table,
                             frac: CGFloat = 0) -> PanelLayout.MacColumnPlan {
        let h = console ? PanelLayout.consoleHeight(
            frac: 0, windowHeight: window,
            defaultHeight: PanelLayout.macDefaultConsoleHeight,
            minHeight: PanelLayout.macMinConsoleHeight,
            maxHeight: PanelLayout.maxConsoleHeight(windowHeight: window)) : nil
        return PanelLayout.macColumnPlan(windowHeight: window, consoleHeight: h,
                                         topRail: true, sequenceObjects: objects,
                                         dockedModeBar: modeBar,
                                         drawerVisible: drawerVisible, tab: tab,
                                         drawerFrac: frac)
    }

    func testDrawerMinimumCoversItsOwnChromePlusARow() {
        // The floor has to mean "one row is visible", or `drawerFits` would pass a
        // height that shows nothing.
        XCTAssertGreaterThanOrEqual(
            PanelLayout.macMinDrawerHeight - PanelLayout.macDrawerChromeHeight, 22,
            "the drawer's minimum must leave room for at least one 22pt row")
    }

    func testDrawerColumnUsedChargesEachPaneOnce() {
        let bare = PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                                sequenceRows: nil,
                                                mcpBanner: false, dockedModeBar: false)
        XCTAssertEqual(bare, PanelLayout.macColumnChrome(mcpBanner: false,
                                                         dockedModeBar: false),
                       accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: 130, topRail: false,
                                         sequenceRows: nil,
                                         mcpBanner: false, dockedModeBar: false),
            bare + 130 + PanelLayout.macConsoleDividerHeight, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: true,
                                         sequenceRows: nil,
                                         mcpBanner: false, dockedModeBar: false),
            bare + PanelLayout.macTopRailHeight, accuracy: 1e-9)
        // The Object viewer is charged at its IDEAL height (rows × 30 + 30), capped at
        // five rows, which is the same formula the VSplitView is given (#457). Charging
        // its 24pt floor instead overflowed the column by a row, because the split only
        // squeezes the pane when the USER drags it.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 2,
                                         mcpBanner: false, dockedModeBar: false),
            bare + 90, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 99,
                                         mcpBanner: false, dockedModeBar: false),
            bare + 180, accuracy: 1e-9)
        // An empty viewer still occupies one row's worth while it is showing.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 0,
                                         mcpBanner: false, dockedModeBar: false),
            bare + 60, accuracy: 1e-9)
        // All three at once, charged once each — the arithmetic this guards is a pane
        // counted twice, which is what put the drawer's footer off the window.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: 130, topRail: true,
                                         sequenceRows: 3,
                                         mcpBanner: false, dockedModeBar: false),
            bare + 130 + PanelLayout.macConsoleDividerHeight + PanelLayout.macTopRailHeight
            + 120, accuracy: 1e-9)
        // And the chrome flags ride on top of all of it, once each (#458).
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: 130, topRail: true,
                                         sequenceRows: 3,
                                         mcpBanner: true, dockedModeBar: true),
            bare + 130 + PanelLayout.macConsoleDividerHeight + PanelLayout.macTopRailHeight
            + 120 + PanelLayout.macMCPBannerHeight + PanelLayout.macDockedModeBarHeight,
            accuracy: 1e-9)
    }

    // MARK: - chrome charged only when it is on screen (#458)

    /// The allowance was a flat 48pt for "the two drag dividers' padding, the MCP
    /// 'controlling' banner, a docked Predict or Binder bar" — and two of those three
    /// are conditional, so the ordinary session (no banner, nothing docked) paid 48 for
    /// 5pt of divider. This is the arithmetic that stopped it.
    func testTheColumnChromeIsChargedOnlyForTheChromeThatIsThere() {
        let bare = PanelLayout.macColumnChrome(mcpBanner: false, dockedModeBar: false)
        // Nothing on screen is the drawer's own drag divider and nothing else.
        XCTAssertEqual(bare, PanelLayout.macDrawerDividerHeight, accuracy: 1e-9)
        XCTAssertEqual(bare, 5, accuracy: 1e-9)
        // What #458 is worth in the ordinary case: the old flat number, minus this.
        XCTAssertEqual(48 - bare, 43, accuracy: 1e-9)
        XCTAssertGreaterThan(48 - bare, PanelLayout.macDrawerRowHeight,
                             "the returned height has to be worth at least a table row,"
                             + " or the issue is not worth a change")
        // Each conditional term, charged exactly when its view is up.
        XCTAssertEqual(PanelLayout.macColumnChrome(mcpBanner: true, dockedModeBar: false),
                       bare + PanelLayout.macMCPBannerHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.macColumnChrome(mcpBanner: false, dockedModeBar: true),
                       bare + PanelLayout.macDockedModeBarHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.macColumnChrome(mcpBanner: true, dockedModeBar: true),
                       bare + PanelLayout.macMCPBannerHeight
                       + PanelLayout.macDockedModeBarHeight, accuracy: 1e-9)
        // The flat 48 was wrong in BOTH directions: it over-charged the empty column
        // and under-charged a docked bar, which is the case it existed to protect.
        XCTAssertGreaterThan(PanelLayout.macColumnChrome(mcpBanner: false,
                                                          dockedModeBar: true), 48)
    }

    /// The banner comes and goes while an MCP tool runs, so the SAME column has to
    /// answer both ways — and a drawer that fits with the banner up must still fit when
    /// it goes away. Monotonic, never the other way round.
    func testTheBannerOnlyEverCostsTheDrawerHeight() {
        for window in [CGFloat(600), 719, 771, 900, 1200] {
            for objects in [nil, 1, 5] as [Int?] {
                let without = Self.ceiling(window: window, objects: objects)
                let with = Self.ceiling(window: window, objects: objects, banner: true)
                XCTAssertGreaterThanOrEqual(
                    without, with,
                    "\(window)pt: the banner cannot make room, only take it")
                if PanelLayout.drawerFits(ceiling: with) {
                    XCTAssertTrue(PanelLayout.drawerFits(ceiling: without),
                                  "\(window)pt: fits with the banner but not without it")
                }
            }
        }
    }

    // MARK: - tab-aware drawer heights (#543)

    /// Each tab's floor is its views' parts added up — the #456 lesson (a floor of 70
    /// against a real 109) is why these are sums of named constants, and this is what
    /// holds each to its sum.
    func testEachTabsFloorIsItsViewsPartsAddedUp() {
        let above = PanelLayout.macDrawerHeaderHeight + PanelLayout.macDrawerHairline
            + PanelLayout.macDrawerTabRowHeight + PanelLayout.macDrawerHairline
        XCTAssertEqual(PanelLayout.macDrawerAboveTabHeight, above, accuracy: 1e-9)
        XCTAssertEqual(above, 52, accuracy: 1e-9)
        // Table and Sequences keep today's floor: chrome plus one row.
        XCTAssertEqual(PanelLayout.minDrawerHeight(tab: .table),
                       PanelLayout.macMinDrawerHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.minDrawerHeight(tab: .sequences),
                       PanelLayout.macMinDrawerHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.minDrawerHeight(), 154, accuracy: 1e-9)
        // Plot: SetPlotView's controls (24) + hairline + axis strip (18 + 2) + hairline
        // + footer (22) = 68 of chrome, and a plotArea that holds the 58pt hover card
        // inside the 8 + 16 tick gutters.
        XCTAssertEqual(PanelLayout.macPlotChromeHeight, 24 + 1 + 20 + 1 + 22, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.macMinPlotAreaHeight, 24 + 58, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.minDrawerHeight(tab: .plot),
                       above + PanelLayout.macPlotChromeHeight
                       + PanelLayout.macMinPlotAreaHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.minDrawerHeight(tab: .plot), 202, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.plotAreaHeight(
            drawerHeight: PanelLayout.minDrawerHeight(tab: .plot)),
            PanelLayout.macMinPlotAreaHeight, accuracy: 1e-9)
        // Lineage: its header (20) + hairline, and a canvas of two 18pt margins and
        // three 16pt node rows.
        XCTAssertEqual(PanelLayout.minDrawerHeight(tab: .lineage),
                       above + 20 + 1 + 2 * 18 + 3 * 16, accuracy: 1e-9)
        // The chart tabs ask for more than the list tabs, which is the point.
        for tab in [DataDrawerTab.plot, .lineage] {
            XCTAssertGreaterThan(PanelLayout.minDrawerHeight(tab: tab),
                                 PanelLayout.minDrawerHeight(tab: .table), "\(tab)")
            XCTAssertGreaterThan(PanelLayout.preferredDrawerHeight(tab: tab),
                                 PanelLayout.preferredDrawerHeight(tab: .table), "\(tab)")
        }
    }

    /// An untouched drawer: 220 (four rows) on the list tabs, a 180pt chart area on the
    /// chart tabs — and the ceiling still wins.
    func testTheUntouchedDrawerIsTabAware() {
        XCTAssertEqual(PanelLayout.preferredDrawerHeight(tab: .table), 220, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.preferredDrawerHeight(tab: .sequences), 220, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.plotAreaHeight(
            drawerHeight: PanelLayout.preferredDrawerHeight(tab: .plot)), 180, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.preferredDrawerHeight(tab: .plot), 300, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.preferredDrawerHeight(tab: .lineage),
                       52 + 21 + PanelLayout.macPreferredChartAreaHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0, windowHeight: 1400, tab: .plot),
                       300, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0, windowHeight: 1400, maxHeight: 250,
                                                tab: .plot), 250, accuracy: 1e-9)
        // One stored fraction for every tab, lifted to the tab's own floor.
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.17, windowHeight: 1000, tab: .table),
                       170, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.drawerHeight(frac: 0.17, windowHeight: 1000, tab: .plot),
                       202, accuracy: 1e-9)
        // The comfort height the viewer yields to: three rows on the list tabs, the
        // whole preferred chart on the chart tabs.
        XCTAssertEqual(PanelLayout.drawerTableRows(
            drawerHeight: PanelLayout.comfortDrawerHeight(tab: .table)), 3)
        XCTAssertEqual(PanelLayout.comfortDrawerHeight(tab: .plot),
                       PanelLayout.preferredDrawerHeight(tab: .plot), accuracy: 1e-9)
    }

    /// Plot gets its 180pt plot area WHEN THERE IS ROOM — the viewer yields for it too —
    /// and at the default window with the console up it gets what is left, which is
    /// still more than its floor. (The issue's "≥ 180 at 1332×771 with the console up"
    /// is not reachable with a 280pt viewport: 719 − 135 − 23 − 5 − 280 = 276 for the
    /// viewer and the drawer together, and a 180pt plot area is a 300pt drawer.)
    func testThePlotTabGetsItsChartWhenThereIsRoom() {
        for (window, console) in [(CGFloat(900), true), (1000, true), (1200, true),
                                  (719, false), (771, false)] {
            let plan = Self.plan(window: window, console: console, objects: 5, tab: .plot)
            XCTAssertTrue(plan.drawerFits)
            XCTAssertGreaterThanOrEqual(
                PanelLayout.plotAreaHeight(drawerHeight: plan.drawerHeight ?? 0), 180,
                "\(window)pt, console \(console)")
        }
        let tight = Self.plan(window: 719, objects: 5, tab: .plot)
        XCTAssertTrue(tight.drawerFits)
        XCTAssertEqual(tight.sequenceRows, 1, "the viewer gives every row it can")
        XCTAssertEqual(PanelLayout.plotAreaHeight(drawerHeight: tight.drawerHeight ?? 0), 96,
                       accuracy: 0.5)
        // At 771 the Table keeps three viewer rows and the Plot gives up all but one:
        // the yield is tab-aware.
        XCTAssertEqual(Self.plan(window: 771, objects: 5, tab: .table).sequenceRows, 3)
        XCTAssertEqual(Self.plan(window: 771, objects: 5, tab: .plot).sequenceRows, 1)
    }

    /// #456's guarantee under the plan, swept across every flag the column reads and
    /// every tab: a drawer that says it fits draws a table row (list tabs) or a plot
    /// area that holds the hover card (Plot) — and never goes over its ceiling or leaves
    /// the viewport short of its floor.
    func testAPlannedDrawerThatFitsAlwaysDrawsItsTabsMinimum() {
        for window in [CGFloat(600), 650, 700, 719, 771, 800, 854, 900, 1000, 1200] {
            for console in [true, false] {
                for objects in [nil, 0, 1, 2, 3, 4, 5, 9] as [Int?] {
                    do {
                        for modeBar in [false, true] {
                            for tab in DataDrawerTab.allCases {
                                for frac in [CGFloat(0), 0.05, 0.2, 0.6] {
                                    let plan = Self.plan(window: window, console: console,
                                                         objects: objects,
                                                         modeBar: modeBar, tab: tab,
                                                         frac: frac)
                                    let what = "\(window)pt console \(console) objects"
                                        + " \(String(describing: objects))"
                                        + " bar \(modeBar) \(tab) frac \(frac)"
                                    guard plan.drawerFits else {
                                        XCTAssertNil(plan.drawerHeight, what)
                                        continue
                                    }
                                    let h = plan.drawerHeight ?? 0
                                    XCTAssertLessThanOrEqual(h, plan.drawerCeiling + 1e-9, what)
                                    XCTAssertGreaterThanOrEqual(
                                        h, PanelLayout.minDrawerHeight(tab: tab) - 1e-9, what)
                                    switch tab {
                                    case .table, .sequences:
                                        XCTAssertGreaterThanOrEqual(
                                            PanelLayout.drawerTableRows(drawerHeight: h), 1, what)
                                    case .plot:
                                        XCTAssertGreaterThanOrEqual(
                                            PanelLayout.plotAreaHeight(drawerHeight: h),
                                            PanelLayout.macMinPlotAreaHeight - 1e-9, what)
                                    case .lineage:
                                        // Header + hairline, then a canvas of at least
                                        // two margins and three node rows.
                                        XCTAssertGreaterThanOrEqual(
                                            h - PanelLayout.macDrawerAboveTabHeight
                                                - PanelLayout.macLineageHeaderHeight
                                                - PanelLayout.macDrawerHairline,
                                            PanelLayout.macMinLineageAreaHeight - 1e-9, what)
                                    }
                                    if let rows = plan.sequenceRows {
                                        XCTAssertGreaterThanOrEqual(rows, 1, what)
                                        XCTAssertLessThanOrEqual(
                                            rows, PanelLayout.sequenceStripRows(objects: objects!),
                                            what)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The drawer does not fit → the hint → its buttons, Hide Console FIRST (#543).
    func testTheHintOffersHideConsoleFirst() {
        XCTAssertEqual(PanelLayout.drawerNoRoomActions(consoleVisible: true,
                                                       sequenceVisible: true),
                       [.hideConsole, .hideSequences, .close])
        XCTAssertEqual(PanelLayout.drawerNoRoomActions(consoleVisible: true,
                                                       sequenceVisible: false),
                       [.hideConsole, .close])
        XCTAssertEqual(PanelLayout.drawerNoRoomActions(consoleVisible: false,
                                                       sequenceVisible: true),
                       [.hideSequences, .close])
        XCTAssertEqual(PanelLayout.drawerNoRoomActions(consoleVisible: false,
                                                       sequenceVisible: false),
                       [.close])
        // And the first offer is a real way out where the hint shows at the default
        // content height: a docked bar at 719 with the console up.
        let crowded = Self.plan(window: 719, objects: 5, modeBar: true)
        XCTAssertFalse(crowded.drawerFits)
        XCTAssertTrue(Self.plan(window: 719, console: false, objects: 5,
                                modeBar: true).drawerFits, "Hide Console")
    }

    // MARK: - #543 review

    /// #544's run header is 18pt of table chrome on every batch set, and the budget
    /// charges it: the Table's floor is chrome + one row WITH it, so a drawer the
    /// layout calls fitting still draws a row when the run header is up.
    func testTheTableChromeChargesTheRunHeader() {
        XCTAssertEqual(PanelLayout.macDrawerTableChrome,
                       PanelLayout.macTableRunHeaderHeight + PanelLayout.macTableHeaderRowHeight
                       + PanelLayout.macTableHistogramHeight + 2 * PanelLayout.macDrawerHairline
                       + PanelLayout.macTableFooterHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.macDrawerTableChrome, 18 + 20 + 16 + 2 + 24, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.macMinDrawerHeight, 154, accuracy: 1e-9)
        // The window the review found: under 62pt of chrome a 136–153pt drawer "fit"
        // and drew 0 rows once the run header took its 18. Every fitting height now
        // draws one, counting the run header.
        for h in stride(from: PanelLayout.minDrawerHeight(), through: 260, by: 1) {
            let underRunHeader = h - PanelLayout.macDrawerAboveTabHeight
                - PanelLayout.macDrawerTableChrome
            XCTAssertGreaterThanOrEqual(underRunHeader, PanelLayout.macDrawerRowHeight,
                                        "\(h)pt")
            XCTAssertGreaterThanOrEqual(PanelLayout.drawerTableRows(drawerHeight: h), 1)
        }
        // And the comfort height is three rows WITH it.
        XCTAssertEqual(PanelLayout.comfortDrawerHeight(tab: .table), 132 + 3 * 22,
                       accuracy: 1e-9)
    }

    /// The MCP banner flips on every agent command, so it must not change the plan:
    /// the plan takes no banner at all, and the viewport — not the drawer — gives the
    /// banner its height while a tool runs. What is asserted is the whole column: the
    /// drawer the plan draws, the panes above it, the banner and the viewport's
    /// banner-reduced floor still add up inside the window.
    func testTheBannerDoesNotChangeThePlansDrawerDecision() {
        // The review's case: Plot at 719 with the console and viewer up. Charging the
        // banner here gave 184 < 202 and the hint; the plan does not see it.
        let plot = Self.plan(window: 719, objects: 5, tab: .plot)
        XCTAssertTrue(plot.drawerFits)
        XCTAssertEqual(PanelLayout.viewportMinHeight(mcpBanner: true),
                       PanelLayout.macViewportMinHeight - PanelLayout.macMCPBannerHeight,
                       accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.viewportMinHeight(mcpBanner: false),
                       PanelLayout.macViewportMinHeight, accuracy: 1e-9)
        for window in [CGFloat(650), 719, 771, 900, 1200] {
            for console in [true, false] {
                for objects in [nil, 1, 5] as [Int?] {
                    for tab in DataDrawerTab.allCases {
                        let plan = Self.plan(window: window, console: console,
                                             objects: objects, tab: tab)
                        guard let h = plan.drawerHeight else { continue }
                        let c = console ? PanelLayout.consoleHeight(
                            frac: 0, windowHeight: window,
                            defaultHeight: PanelLayout.macDefaultConsoleHeight,
                            minHeight: PanelLayout.macMinConsoleHeight,
                            maxHeight: PanelLayout.maxConsoleHeight(windowHeight: window))
                            : nil
                        let aboveWithBanner = PanelLayout.drawerColumnUsed(
                            consoleHeight: c, topRail: true, sequenceRows: plan.sequenceRows,
                            mcpBanner: true, dockedModeBar: false)
                        XCTAssertLessThanOrEqual(
                            aboveWithBanner + h + PanelLayout.viewportMinHeight(mcpBanner: true),
                            window + 1e-9,
                            "\(window)pt console \(console) \(String(describing: objects)) \(tab)")
                    }
                }
            }
        }
    }

    /// The viewer yields through its maxHeight, not a new identity: the cap is the
    /// planned rows' height while yielding and the usual 400 otherwise.
    func testTheViewersYieldIsAHeightCapNotANewIdentity() {
        XCTAssertEqual(PanelLayout.sequenceStripMaxHeight(plannedRows: 1, objects: 5), 60,
                       accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.sequenceStripMaxHeight(plannedRows: 5, objects: 5),
                       PanelLayout.macMaxSequenceStripHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.sequenceStripMaxHeight(plannedRows: 5, objects: 9),
                       PanelLayout.macMaxSequenceStripHeight, accuracy: 1e-9)
        XCTAssertEqual(PanelLayout.sequenceStripMaxHeight(plannedRows: nil, objects: 3),
                       PanelLayout.macMaxSequenceStripHeight, accuracy: 1e-9)
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
