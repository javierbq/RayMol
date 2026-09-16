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
        // rail and the Object sequence viewer (the viewport has a hard 360pt
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
    /// OBJECT sequence viewer showing — the four-band column #457 creates.
    ///
    /// The viewer is charged here again, at up to 180pt, because it is a pane of the
    /// column once more. Below some window height the drawer would be chrome with no
    /// rows, and `drawerFits` turns that into the one-line hint, because the drag
    /// divider is clamped to this same ceiling and the user could not have recovered it
    /// by dragging either. The hint offers to close EITHER pane above the drawer, and
    /// the last block here is why both offers have to be there.
    func testDrawerCeilingInACrowdedColumn() {
        // The numbers the #417 review measured, with a five-object viewer.
        XCTAssertEqual(Self.ceiling(window: 900), 154, accuracy: 0.5)
        XCTAssertTrue(PanelLayout.drawerFits(ceiling: Self.ceiling(window: 900)))
        // 854pt gives the drawer 108pt, which is 28pt short of the one-row minimum.
        // It USED to pass, against #417's undercounted 96pt floor; #456's review
        // measured the drawer's real chrome and that constant survives #457 (the
        // undercount had nothing to do with where the sequences live).
        XCTAssertEqual(Self.ceiling(window: 854), 108, accuracy: 0.5)
        XCTAssertFalse(PanelLayout.drawerFits(ceiling: Self.ceiling(window: 854)))
        // The app's own persisted height with everything up: not enough, which is the
        // hint's case and the vertical budget #457 has to answer for.
        for window in [CGFloat(800), 771, 600] {
            XCTAssertFalse(PanelLayout.drawerFits(ceiling: Self.ceiling(window: window)),
                           "a \(window)pt window has"
                           + " \(Self.ceiling(window: window))pt for the drawer, which"
                           + " cannot hold \(PanelLayout.macDrawerChromeHeight)pt of"
                           + " chrome plus a row")
        }
        // Both of the hint's offers are live, and either one ALONE is enough at the two
        // sizes a user actually has — which is why the hint gives the choice rather
        // than naming one pane.
        for window in [CGFloat(771), 854] {
            XCTAssertTrue(PanelLayout.drawerFits(
                ceiling: Self.ceiling(window: window, console: false)),
                          "\(window)pt, Hide Console")
            XCTAssertTrue(PanelLayout.drawerFits(
                ceiling: Self.ceiling(window: window, objects: nil)),
                          "\(window)pt, Hide Sequences")
        }
        // At 600pt neither is enough on its own and BOTH are needed, which the hint
        // also allows — the two buttons are independent, and Close is the third way
        // out. A window that short has 600 - 360 of viewport - 48 of chrome to spend.
        XCTAssertFalse(PanelLayout.drawerFits(
            ceiling: Self.ceiling(window: 600, console: false)))
        XCTAssertFalse(PanelLayout.drawerFits(
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
    /// a pane back above the drawer.
    func testADrawerThatFitsAlwaysDrawsAtLeastOneTableRow() {
        for window in [CGFloat(600), 700, 771, 800, 854, 900, 1200] {
            for console in [true, false] {
                for objects in [nil, 1, 2, 3, 4, 5] as [Int?] {
                    let ceiling = Self.ceiling(window: window, console: console,
                                               objects: objects)
                    guard PanelLayout.drawerFits(ceiling: ceiling) else { continue }
                    let h = PanelLayout.drawerHeight(frac: 0, windowHeight: window,
                                                     maxHeight: ceiling)
                    let rows = PanelLayout.drawerTableRows(drawerHeight: h)
                    XCTAssertGreaterThanOrEqual(
                        rows, 1,
                        "\(window)pt window, console \(console ? "open" : "closed"),"
                        + " viewer \(objects.map { "on with \($0) objects" } ?? "off"):"
                        + " drawer \(h)pt draws \(rows) rows")
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

    /// THE vertical-budget question #457 has to answer: 1332×771 is the app's own
    /// persisted window, and the default state has the console up.
    ///
    /// With the Object viewer showing more than one object there is not room for all
    /// four bands, and the drawer — the pane that yields — shows the "needs more room"
    /// hint. That is a sensible answer rather than a regression only because BOTH ways
    /// out are one click and both are offered on the hint itself; `drawerFits` is
    /// asserted true for each of them.
    func testTheDefaultWindowCannotHoldAllFourBandsAndSaysSo() {
        let window: CGFloat = 771
        // One object: it fits, at exactly one row of the table.
        let one = Self.ceiling(window: window, objects: 1)
        XCTAssertTrue(PanelLayout.drawerFits(ceiling: one))
        XCTAssertEqual(PanelLayout.drawerTableRows(
            drawerHeight: PanelLayout.drawerHeight(frac: 0, windowHeight: window,
                                                   maxHeight: one)), 1)
        // Two or more — a target plus a design, which is the ordinary case — and it
        // does not. The hint fires.
        for objects in 2...5 {
            XCTAssertFalse(
                PanelLayout.drawerFits(ceiling: Self.ceiling(window: window,
                                                             objects: objects)),
                "\(objects) objects at 771pt with the console up")
        }
        // Both of the hint's buttons lead somewhere the drawer fits, at every one of
        // those object counts. A hint that could not be acted on would be the real bug.
        for objects in 2...5 {
            XCTAssertTrue(
                PanelLayout.drawerFits(ceiling: Self.ceiling(window: window,
                                                             console: false,
                                                             objects: objects)),
                "Hide Console with \(objects) objects")
            XCTAssertTrue(
                PanelLayout.drawerFits(ceiling: Self.ceiling(window: window,
                                                             objects: nil)),
                "Hide Sequences with \(objects) objects")
        }
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
    /// ⌘2 off).
    private static func ceiling(window: CGFloat, console: Bool = true,
                                objects: Int? = 5) -> CGFloat {
        let h = console ? PanelLayout.consoleHeight(
            frac: 0, windowHeight: window,
            defaultHeight: PanelLayout.macDefaultConsoleHeight,
            minHeight: PanelLayout.macMinConsoleHeight,
            maxHeight: PanelLayout.maxConsoleHeight(windowHeight: window)) : nil
        return PanelLayout.drawerCeiling(
            windowHeight: window,
            used: PanelLayout.drawerColumnUsed(consoleHeight: h, topRail: true,
                                               sequenceRows: objects))
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
                                                sequenceRows: nil)
        XCTAssertEqual(bare, PanelLayout.macColumnChromeAllowance, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: 130, topRail: false,
                                         sequenceRows: nil),
            bare + 130 + PanelLayout.macConsoleDividerHeight, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: true,
                                         sequenceRows: nil),
            bare + PanelLayout.macTopRailHeight, accuracy: 1e-9)
        // The Object viewer is charged at its IDEAL height (rows × 30 + 30), capped at
        // five rows, which is the same formula the VSplitView is given (#457). Charging
        // its 24pt floor instead overflowed the column by a row, because the split only
        // squeezes the pane when the USER drags it.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 2),
            bare + 90, accuracy: 1e-9)
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 99),
            bare + 180, accuracy: 1e-9)
        // An empty viewer still occupies one row's worth while it is showing.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: nil, topRail: false,
                                         sequenceRows: 0),
            bare + 60, accuracy: 1e-9)
        // All three at once, charged once each — the arithmetic this guards is a pane
        // counted twice, which is what put the drawer's footer off the window.
        XCTAssertEqual(
            PanelLayout.drawerColumnUsed(consoleHeight: 130, topRail: true,
                                         sequenceRows: 3),
            bare + 130 + PanelLayout.macConsoleDividerHeight + PanelLayout.macTopRailHeight
            + 120, accuracy: 1e-9)
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
