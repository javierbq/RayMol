// PanelLayout.swift — the persisted panel-layout contract shared by the macOS and
// iOS layouts in ContentView (#331 console default, #332 persistence).
//
// Two responsibilities, both deliberately free of SwiftUI:
//
//   1. The UserDefaults key namespace (`raymol.panels.*`). Both platform layouts
//      read the SAME keys through @AppStorage, so a pane's visibility survives a
//      relaunch — and, on a device that runs both idioms, means the same thing.
//   2. The sizing arithmetic. A size the USER chose is stored as a FRACTION of
//      the window dimension, never as absolute points: a height that was sensible
//      in a 1600pt window must not be restored into a 700pt one, where it would
//      leave no viewport. Fractions are clamped on the way in AND on the way out.
//      The untouched DEFAULT is the opposite — absolute points — so a console
//      nobody has resized looks the same on a laptop and on a 6K display.
//
// Everything here is a pure function of its arguments so PanelLayoutTests can
// pin the boundaries without a window.

import CoreGraphics
import Foundation

enum PanelLayout {

    // MARK: - Keys

    private static let ns = "raymol.panels."

    /// Console (CommandPanel) visible. macOS + iPad; iPhone landscape has its own.
    static let consoleVisibleKey = ns + "consoleVisible"
    /// Inspector / Objects panel visible. macOS + iPad.
    static let objectsVisibleKey = ns + "objectsVisible"
    /// iPhone-LANDSCAPE pane visibility, kept separate from the iPad bools so that
    /// layout keeps starting minimal (console off, objects on) — see ContentView.
    static let landscapeConsoleVisibleKey = ns + "landscapeConsoleVisible"
    static let landscapeObjectsVisibleKey = ns + "landscapeObjectsVisible"
    /// The user's console height, as a fraction of the window height. Absent
    /// until they resize it, which is what selects the absolute default (#331).
    static let consoleFracKey = ns + "consoleFrac"
    /// The user's macOS inspector (right column) width, as a fraction of the
    /// window width. Absent until they drag the seam (#350), which is what
    /// selects the absolute default width.
    static let inspectorFracKey = ns + "inspectorFrac"
    /// iPad bottom-panel share of the screen.
    static let panelFracKey = ns + "panelFrac"
    /// The OBJECT sequence viewer's visibility: the pane above the viewport that shows
    /// the sequences of the enabled scene objects. ⌘2's flag, on every platform.
    ///
    /// The single source of truth again (#457). #419 made this iOS-only and migrated it
    /// into the drawer's Sequences TAB; #456 migrated it again into a band in the
    /// drawer's chrome. Both are reverted, because the scene rows are an OBJECT view
    /// and the drawer's Sequences tab is an ENTRY view — two nouns, so two viewers,
    /// independently placed and independently toggled (spec §8 decision 2). Nothing
    /// replaces the two migrations: the drawer has never shipped, so they only ever ran
    /// on dev builds and there is no released state to carry forward.
    static let sequenceVisibleKey = ns + "sequenceVisible"
    /// Data drawer (#417) visible. Written by PyMOLEngine, which owns the flag,
    /// like the sequence strip's. macOS only until #420.
    static let dataDrawerVisibleKey = ns + "dataDrawerVisible"
    /// The user's Data drawer height, as a fraction of the window height. Absent
    /// until they drag its divider, which selects the absolute default.
    static let dataDrawerFracKey = ns + "dataDrawerFrac"
    /// Which drawer tab was showing (#419). Persisted because every other pane in the
    /// window is: a user who works in Plot all day should not be handed the Table on
    /// every launch.
    static let dataDrawerTabKey = ns + "dataDrawerTab"

    /// Every key this type defines — the namespace/uniqueness check in the tests
    /// runs off this list, so a new key must be added here too.
    static let allKeys: [String] = [
        consoleVisibleKey, objectsVisibleKey,
        landscapeConsoleVisibleKey, landscapeObjectsVisibleKey,
        consoleFracKey, inspectorFracKey, panelFracKey, sequenceVisibleKey,
        dataDrawerVisibleKey, dataDrawerFracKey, dataDrawerTabKey,
    ]

    // MARK: - What the drawer restores at launch

    /// The drawer's visibility at launch, on every platform: whatever was stored.
    ///
    /// It used to be `sequenceStripMigrationResult.drawerVisible` on macOS, because
    /// #419 could turn the drawer ON for a user who had the sequence strip up. #457
    /// took the strip's rows back out of the drawer, so the two panes no longer decide
    /// anything about each other and there is nothing to migrate — see
    /// `sequenceVisibleKey` for why no migration replaces the two that were deleted.
    static func restoredDrawerVisible(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dataDrawerVisibleKey)
    }

    /// The drawer's tab at launch: the persisted choice, VALIDATED, because a tab name
    /// from a newer build (or a hand-edited plist) must not leave the drawer on a tab
    /// this build cannot draw.
    static func restoredDrawerTab(stored: String?) -> DataDrawerTab {
        guard let stored, let tab = DataDrawerTab(rawValue: stored), tab.isAvailable else {
            return .table
        }
        return tab
    }

    static func restoredDrawerTab(defaults: UserDefaults = .standard) -> DataDrawerTab {
        restoredDrawerTab(stored: defaults.string(forKey: dataDrawerTabKey))
    }

    // MARK: - Bounds

    /// #331: the console's height on a launch with nothing stored. ABSOLUTE
    /// points, not a share of the window, so it matches what the app has always
    /// shown on any display — a fifth of a large monitor is far more room than the
    /// console needs by default. A size the user drags to IS stored as a fraction
    /// (see `consoleFrac`); only this untouched default is fixed.
    static let macDefaultConsoleHeight: CGFloat = 130
    static let iosDefaultConsoleHeight: CGFloat = 110
    /// Storable band. The floor exists because a user who drags the console shut
    /// is expressing "hidden", which the visibility flag records; storing ~0 here
    /// would instead restore an unusable sliver on the next launch.
    static let minStorableFrac: CGFloat = 0.01
    static let maxStorableFrac: CGFloat = 0.95

    /// Usable console minimums: the macOS pane vs. the iOS drag divider.
    static let macMinConsoleHeight: CGFloat = 44
    static let iosMinConsoleHeight: CGFloat = 60
    /// Floor under the growth ceiling (see `maxConsoleHeight`): in a window too
    /// short to satisfy the viewport minimum, the console may still take this
    /// share rather than collapsing to nothing.
    static let minCeilingFrac: CGFloat = 0.2
    /// The macOS viewport's own minimum. The console may grow until the viewport
    /// is down to this, which is what keeps #317 ("drag it open to read a long
    /// predict log") working while still guaranteeing a viewport. `macViewport`'s
    /// own `.frame(minHeight:)` reads this constant, so the layout's arithmetic and
    /// the view's hard floor are one number.
    ///
    /// 360 until #543 (Javier, 2026-09-26). At the app's persisted 1332×771 with the
    /// console up, 360 left 719 − 135 − 23 − 5 − 360 = 196pt of content for the Object
    /// viewer AND the Data drawer together — a five-object viewer is 180 of that — so
    /// the drawer collapsed to its hint right after a batch landed, which is the moment
    /// it is wanted. 280 is still a real 3D view (39% of that column), not a sliver.
    static let macViewportMinHeight: CGFloat = 280

    static let defaultPanelFrac: CGFloat = 0.53
    static let minPanelFrac: CGFloat = 0.2
    static let maxPanelFrac: CGFloat = 0.8

    // MARK: - macOS Data drawer (#417)

    /// The drawer's height on a launch with nothing stored. ABSOLUTE points, for
    /// the console's reason: an untouched drawer looks the same on a laptop and a
    /// 6K display. 220 is the header, its tab row, the table's chrome and four rows.
    static let macDefaultDrawerHeight: CGFloat = 220

    // MARK: - what the drawer is made of

    // These are MEASURED against the views, not guessed, because everything below is
    // subtraction from them and a constant that is short by one row is a drawer that
    // draws no rows at all (#456 review). Each names its view.

    /// The drawer's own header row ("DATA · <set>  ✕"), and the hairline under it.
    static let macDrawerHeaderHeight: CGFloat = 26
    /// `DataDrawer.tabRow` — the tab strip with the filter bar beside it — and the
    /// hairline under it. The first thing under the header.
    static let macDrawerTabRowHeight: CGFloat = 24
    /// `SetTableView.runHeaderRow` (#544): the run's constants on one line above the
    /// column headers. Shown only when the set HAS constant columns — the ordinary batch
    /// case — and charged ALWAYS (#543 review): the flag lives in a table layout the
    /// column arithmetic does not see, and over-charging 18pt costs a set without one a
    /// little comfort, while under-charging is a floor that draws no row.
    static let macTableRunHeaderHeight: CGFloat = 18
    /// `SetTableView.headerRow` — the column headers.
    static let macTableHeaderRowHeight: CGFloat = 20
    /// `SetTableView.histogramRow` — the per-column histogram/brush strip.
    static let macTableHistogramHeight: CGFloat = 16
    /// `SetTableView.footer`.
    static let macTableFooterHeight: CGFloat = 24
    /// `SetTableView`'s own chrome: the run header (18), the column header (20), the
    /// histogram/brush strip (16), the footer (24) and their two hairlines — 80. The
    /// view reads each of these constants for its frames (#543 review), so the budget
    /// and the view are one set of numbers. 62 before #544's run header.
    static var macDrawerTableChrome: CGFloat {
        macTableRunHeaderHeight + macTableHeaderRowHeight + macTableHistogramHeight
            + macDrawerHairline + macDrawerHairline + macTableFooterHeight
    }
    /// One table row (`SetTableView.rowHeight`, `SetTableRowView`'s frame).
    static let macDrawerRowHeight: CGFloat = 22
    /// A hairline, wherever one separates two of the above.
    static let macDrawerHairline: CGFloat = 1

    /// What the drawer spends before it can show a single row: its header, the tab
    /// row, the table's chrome and the hairlines between them. A drawer given less
    /// than this draws no data at all, which is why `macMinDrawerHeight` is this plus
    /// one row and why a column that cannot afford it shows the hint instead of a
    /// band (#417 review).
    ///
    /// This was 73 until #456's review, which is what it cost BEFORE the tab strip
    /// moved onto its own row — and it was already short of the histogram strip. That
    /// undercount is real and has nothing to do with where the scene sequences live,
    /// so it survives #457 taking the band back out.
    static var macDrawerChromeHeight: CGFloat {
        macDrawerHeaderHeight + macDrawerHairline + macDrawerTabRowHeight
            + macDrawerHairline + macDrawerTableChrome
    }
    /// What the drawer needs BELOW its header: the tab row, the table's chrome and ONE
    /// row. Measured against the views, and the name is the contract — as
    /// `macMinDrawerHeight - macDrawerHeaderHeight` it was 70, which is 17pt below the
    /// table's chrome alone, and a floor that cannot fit one row is not a floor
    /// (#456 review).
    static var macMinTabContentHeight: CGFloat {
        macDrawerTabRowHeight + macDrawerHairline + macDrawerTableChrome + macDrawerRowHeight
    }
    /// Header + a tab half that can draw a row; below this the drawer is chrome and no
    /// data. Built from `macMinTabContentHeight` so the measured constant is the one
    /// doing the work — `macDrawerChromeHeight + macDrawerRowHeight` is the same number
    /// by a different route, and `testTheDrawersMinimumsAreItsActualPartsAddedUp` holds
    /// the two to each other.
    static var macMinDrawerHeight: CGFloat {
        macDrawerHeaderHeight + macDrawerHairline + macMinTabContentHeight
    }

    // MARK: - what the CHART tabs are made of (#543)

    // Table and Sequences keep the floor above: header, tab row, table chrome, one row.
    // Plot and Lineage draw a chart, and a chart the height of a table row is not a
    // chart — the walkthrough's Plot tab was a ~90pt strip. Each constant below names
    // the view (and the line of it) it was read from, the way #456's review held the
    // table's parts to theirs: every drawer floor is a sum of these, so one that is
    // short is a tab that draws its chrome and no chart.

    /// What the drawer spends ABOVE any tab's own view: its header, the tab row and the
    /// two hairlines (`DataDrawer.body` / `tabHalf`). 52pt, on every tab.
    static var macDrawerAboveTabHeight: CGFloat {
        macDrawerHeaderHeight + macDrawerHairline + macDrawerTabRowHeight + macDrawerHairline
    }

    /// `SetPlotView.controls` — the x / y / colour pickers row (`.frame(height: 24)`).
    static let macPlotControlsHeight: CGFloat = 24
    /// `SetPlotView`'s x-axis histogram brush and the padding under it.
    static let macPlotAxisBrushHeight: CGFloat = 18
    static let macPlotAxisBrushBottomPadding: CGFloat = 2
    static var macPlotAxisStripHeight: CGFloat {
        macPlotAxisBrushHeight + macPlotAxisBrushBottomPadding
    }
    /// `SetPlotView.footer` (`.frame(height: 22)`).
    static let macPlotFooterHeight: CGFloat = 22
    /// Everything `SetPlotView` draws that is NOT `plotArea`: controls, hairline, the
    /// axis strip, hairline, footer. `plotArea` is the flexible GeometryReader and gets
    /// whatever of the tab is left over.
    static var macPlotChromeHeight: CGFloat {
        macPlotControlsHeight + macDrawerHairline + macPlotAxisStripHeight
            + macDrawerHairline + macPlotFooterHeight
    }
    /// `SetPlotView.topGutter` / `bottomGutter`: the part of `plotArea` the tick labels
    /// take, outside the plotted rectangle.
    static let macPlotTopGutter: CGFloat = 8
    static let macPlotBottomGutter: CGFloat = 16
    static var macPlotGutterHeight: CGFloat { macPlotTopGutter + macPlotBottomGutter }
    /// `SetPlotView.cardSize.height` (the view reads this): the hover card is drawn INSIDE the plotted
    /// rectangle, so a rectangle shorter than this cannot show it — hover is how a
    /// point is identified, so below that the plot is a picture, not a tool.
    static let macPlotHoverCardHeight: CGFloat = 58
    /// The smallest `plotArea` the Plot tab is drawn at: the hover card inside the
    /// gutters (82pt).
    static var macMinPlotAreaHeight: CGFloat { macPlotGutterHeight + macPlotHoverCardHeight }

    /// `LineageView.header` (`.frame(height: 20)`) and the hairline under it.
    static let macLineageHeaderHeight: CGFloat = 20
    /// `LineageView.margin` (18, above and below the canvas) and `rowHeight` (16); the
    /// view reads these.
    static let macLineageMargin: CGFloat = 18
    static let macLineageRowPitch: CGFloat = 16
    /// The smallest Lineage canvas the tab is drawn at: its two margins and three node
    /// rows (84pt). Three because a node, its parent row and its child row is the least
    /// that shows a lineage rather than a list.
    static var macMinLineageAreaHeight: CGFloat { 2 * macLineageMargin + 3 * macLineageRowPitch }

    /// The chart area a Plot or Lineage tab ASKS for (#543: "at least ~180pt of plot
    /// area"). What the drawer defaults to on those tabs, and what the Object viewer
    /// gives rows up for while the drawer is open — see `macColumnPlan`.
    static let macPreferredChartAreaHeight: CGFloat = 180

    /// The table rows a Table or Sequences drawer asks for before the Object viewer
    /// gives up rows for it (#543's "at least 3 table rows" at the default window):
    /// 132 + 66 = 198pt with the run header.
    /// Below the untouched default's four on purpose: three rows is a usable table,
    /// and the fourth is not worth a sequence row the user can see.
    static let macComfortTableRows = 3

    /// The drawer's FLOOR on `tab`: below it the tab draws chrome and no data, so
    /// `drawerFits` shows the hint and the drag divider will not go under it.
    ///
    /// Table and Sequences keep `macMinDrawerHeight` (one row: 154pt with #544's run
    /// header, 136 before). Plot is
    /// `macDrawerAboveTabHeight + macPlotChromeHeight + macMinPlotAreaHeight` = 202pt;
    /// Lineage `… + macLineageHeaderHeight + hairline + macMinLineageAreaHeight` = 157pt.
    static func minDrawerHeight(tab: DataDrawerTab) -> CGFloat {
        switch tab {
        case .table, .sequences:
            return macMinDrawerHeight
        case .plot:
            return macDrawerAboveTabHeight + macPlotChromeHeight + macMinPlotAreaHeight
        case .lineage:
            return macDrawerAboveTabHeight + macLineageHeaderHeight + macDrawerHairline
                + macMinLineageAreaHeight
        }
    }

    /// The untouched drawer's height on `tab`. Table and Sequences keep 220 (four rows);
    /// Plot and Lineage are sized so the chart area is `macPreferredChartAreaHeight` —
    /// 300pt and 253pt. The ceiling still wins, so this is what the tab gets WHEN THERE
    /// IS ROOM.
    static func preferredDrawerHeight(tab: DataDrawerTab) -> CGFloat {
        switch tab {
        case .table, .sequences:
            return macDefaultDrawerHeight
        case .plot:
            return macDrawerAboveTabHeight + macPlotChromeHeight + macPreferredChartAreaHeight
        case .lineage:
            return macDrawerAboveTabHeight + macLineageHeaderHeight + macDrawerHairline
                + macPreferredChartAreaHeight
        }
    }

    /// The drawer height the Object viewer yields rows to protect (see
    /// `macColumnPlan`): `macComfortTableRows` for the two list tabs, the full preferred
    /// chart for the two chart tabs.
    static func comfortDrawerHeight(tab: DataDrawerTab) -> CGFloat {
        switch tab {
        case .table, .sequences:
            return macDrawerChromeHeight + CGFloat(macComfortTableRows) * macDrawerRowHeight
        case .plot, .lineage:
            return preferredDrawerHeight(tab: tab)
        }
    }

    /// The Plot tab's `plotArea` height in a drawer of `drawerHeight` — what #543's
    /// "plot area ≥ 180pt" is stated in. 0 when the drawer cannot draw one.
    static func plotAreaHeight(drawerHeight: CGFloat) -> CGFloat {
        max(drawerHeight - macDrawerAboveTabHeight - macPlotChromeHeight, 0)
    }

    // MARK: - the OBJECT sequence viewer's own height (#457)

    /// The Object viewer's IDEAL height — the sequence strip's own formula, unchanged
    /// since before #419 moved it and through both of the moves back: one block per
    /// enabled object (ruler + residues ≈ 28pt, charged at 30) up to five, plus 30 for
    /// the horizontal scrollbar and the inter-block padding.
    ///
    /// It lives here rather than inline in the layout because TWO places need the same
    /// number: the pane's `idealHeight`, and `drawerColumnUsed`, which charges the pane
    /// against the column the drawer has to fit in. They were two copies of `rows * 30
    /// + 30` before #419, which is one edit away from a drawer sized against a strip
    /// that is a row taller than the layout thinks.
    static func sequenceStripIdealHeight(objects: Int) -> CGFloat {
        CGFloat(sequenceStripRows(objects: objects)) * 30 + 30
    }

    /// The row count the ideal height is charged at: at least one (an empty viewer is
    /// still a pane), at most five (past that it scrolls, or the user drags it open).
    ///
    /// Also the pane's `.id()`, so a VSplitView re-adopts its ideal height when an
    /// object is loaded or removed — without that a divider the layout has once pinned
    /// keeps its first-seen height and later sequences are simply not visible. It has
    /// to change exactly when the ideal height does, which is why it is this and not
    /// the raw count.
    static func sequenceStripRows(objects: Int) -> Int { min(max(objects, 1), 5) }

    /// The most the Object viewer may take before the user drags it: high enough that
    /// "drag it open to read a long alignment" works, low enough that it cannot eat the
    /// viewport on its own.
    static let macMaxSequenceStripHeight: CGFloat = 400
    /// A few pt under the cap so the VSplitView still hands the user a draggable
    /// splitter — a strict min == max freezes it.
    static let macMinSequenceStripHeight: CGFloat = 24

    /// The drawer's height on a launch with nothing stored.
    ///
    /// No band term any more (#457): the scene rows are their own pane above the
    /// viewport again, so they spend the COLUMN's height (`drawerColumnUsed`) rather
    /// than the drawer's, and an untouched drawer is 220pt whatever the viewer is doing.
    static var defaultDrawerHeight: CGFloat { macDefaultDrawerHeight }

    /// How many table rows the drawer can actually draw at this height. The number
    /// #456's review stated its regression in — "rows = 0 everywhere" — so it stays as
    /// the number the tests assert on, minus the band dimension that is gone.
    static func drawerTableRows(drawerHeight: CGFloat) -> Int {
        let left = drawerHeight - macDrawerChromeHeight
        guard left > 0 else { return 0 }
        return Int(left / macDrawerRowHeight)
    }

    /// The drawer's minimum on the Table: its chrome plus one row. `drawerFits` tests it
    /// and the drag divider clamps to it, so the two cannot disagree about whether a
    /// window has room. Tab-aware since #543 — see `minDrawerHeight(tab:)`.
    static func minDrawerHeight() -> CGFloat { minDrawerHeight(tab: .table) }

    /// Height the panes ABOVE the drawer have already claimed in the viewport
    /// column, so the drawer can size itself against what is actually left.
    ///
    /// `sequenceRows` is the Object viewer's enabled-object count when it is showing
    /// (nil = hidden), charged at its IDEAL height — the same number the VSplitView is
    /// given — not at its 24pt floor: the split only squeezes the pane when the USER
    /// drags it, so sizing against the floor overflowed the column by a row.
    ///
    /// The term was here before #419, went away while the scene rows lived inside the
    /// drawer (#419's tab, #456's band), and is back with the pane (#457). Two viewers
    /// means two claims on the column again, and the drawer is the one that yields.
    ///
    /// `mcpBanner` and `dockedModeBar` say what CHROME is on screen — see
    /// `macColumnChrome`, which is where the conditional part of this sum lives (#458).
    static func drawerColumnUsed(consoleHeight: CGFloat?, topRail: Bool,
                                 sequenceRows: Int?,
                                 mcpBanner: Bool, dockedModeBar: Bool) -> CGFloat {
        var used: CGFloat = 0
        if let consoleHeight { used += consoleHeight + macConsoleDividerHeight }
        if topRail { used += macTopRailHeight }
        if let sequenceRows { used += sequenceStripIdealHeight(objects: sequenceRows) }
        return used + macColumnChrome(mcpBanner: mcpBanner, dockedModeBar: dockedModeBar)
    }

    static let macConsoleDividerHeight: CGFloat = 5
    static let macTopRailHeight: CGFloat = 23

    // MARK: - column chrome that is not a pane (#458)

    // Measured in the running app at its persisted 1332×771 (content height 719pt),
    // the way #456's review measured the drawer's own parts: the constants name a view
    // and the number is what that view actually occupies, not what it might.

    /// `macDrawerDivider` — a 1pt hairline with 2pt of padding above and below. The
    /// only part of the column chrome that is ALWAYS there, because it is drawn by the
    /// very band whose ceiling is being computed. (The console's own divider is not
    /// here; `drawerColumnUsed` charges it with the console.)
    static let macDrawerDividerHeight: CGFloat = 5
    /// `MCPDrivingBanner` while a tool call is running: one caption row and a small
    /// Stop button inside 6pt of vertical padding, plus the green hairline it overlays
    /// on its own bottom edge. Measured on screen with the banner up.
    static let macMCPBannerHeight: CGFloat = 32
    /// A docked `PredictBar` or `BinderDesignBar` plus the `Divider()` under it
    /// (`macViewportStack`), in the two-row form both bars open in: a status row
    /// (~29) and the input row (~36).
    ///
    /// An ALLOWANCE, unlike the two above, and deliberately the generous end of one:
    /// both bars grow optional rows (a size warning, the MSA row, Advanced) and the
    /// status label may wrap to two lines, so there is no single height to measure.
    /// Rounding UP is the safe direction — an over-charged bar costs the drawer some
    /// height it could have had, while an under-charged one over-commits a column
    /// whose viewport has a HARD `macViewportMinHeight` minimum (`macViewport`'s own frame), and that
    /// is the footer-off-the-window case.
    static let macDockedModeBarHeight: CGFloat = 72

    /// What the column spends on chrome that is not a pane, given what is on screen.
    ///
    /// Flat 48pt until #458, defended there as "a few points of under-use beat a
    /// footer off the window". The defence was sound and the number was not: two of
    /// the three things it covered are CONDITIONAL, so with no banner and nothing
    /// docked — the ordinary session — the real cost is the drawer's divider, 5pt, and
    /// 43 of the 48 were reserved for chrome that is not on screen. That is two table
    /// rows at `macDrawerRowHeight`, and at the app's own 1332×771 it was the
    /// difference between a table and the "needs more room" hint.
    ///
    /// The flat number was wrong in the other direction too: 48 does not cover a
    /// docked Predict bar (72) at all, so the one case it was meant to protect was the
    /// one it under-charged. Charging for what is there is both more room in the
    /// common case and more honest in the rare one.
    ///
    /// One flag for both bars: `setPredictMode` and `setBinderDesignMode` clear each
    /// other, so only one can be docked at a time.
    static func macColumnChrome(mcpBanner: Bool, dockedModeBar: Bool) -> CGFloat {
        var chrome = macDrawerDividerHeight
        if mcpBanner { chrome += macMCPBannerHeight }
        if dockedModeBar { chrome += macDockedModeBarHeight }
        return chrome
    }

    /// The most the Data drawer may take, given `used` by the panes above it. The
    /// viewport keeps its own minimum out of what remains, exactly as the console's
    /// ceiling works — the drawer is the pane that yields, because the console and
    /// the strip were there first and resizing them under the user is worse.
    static func drawerCeiling(windowHeight: CGFloat, used: CGFloat) -> CGFloat {
        maxDrawerHeight(windowHeight: max(windowHeight - used, 0))
    }

    /// False when the column cannot give the drawer even one row of data. The band
    /// then shows a one-line hint instead of a table: a stub too short to draw a
    /// row is worse than no band at all, and the drag divider is clamped to this
    /// same ceiling so the user could not have recovered it by dragging either.
    ///
    /// What can tip it over is the two panes ABOVE it — the console and the Object
    /// sequence viewer — which is why the hint offers to close either one (#457). There
    /// is always a way back that is one click rather than a window resize.
    static func drawerFits(ceiling: CGFloat, tab: DataDrawerTab = .table) -> Bool {
        ceiling >= minDrawerHeight(tab: tab)
    }
    /// The drawer shares the viewport's column with the console and may grow until
    /// the viewport is at its minimum — the same bracket `maxConsoleHeight` uses,
    /// so a window that fits the console fits the drawer at the same size.
    static func maxDrawerHeight(windowHeight: CGFloat,
                                viewportMin: CGFloat = macViewportMinHeight) -> CGFloat {
        maxConsoleHeight(windowHeight: windowHeight, viewportMin: viewportMin)
    }

    /// The drawer's height in a window of `windowHeight`: the same arithmetic as
    /// the console's (a stored fraction wins over the absolute default, the
    /// ceiling wins over both), with the drawer's own bounds.
    ///
    /// `maxHeight` overrides the ceiling. The drawer shares its column with the
    /// console, the rail and the sequence strip, and the viewport under them has a
    /// hard `macViewportMinHeight` floor, so the layout passes the height LEFT after those panes
    /// — the drawer yields, rather than pushing its own bottom rows off the window
    /// in a short one. The stored fraction is still of the whole window, so what
    /// the user dragged to means the same thing whether or not the console is up.
    ///
    /// `tab` picks the default and the floor (#543): one stored fraction serves every
    /// tab — it is the height the user dragged the DRAWER to — but a Plot tab lifts it
    /// to its own floor and an untouched one asks for a chart's worth of height.
    static func drawerHeight(frac: CGFloat, windowHeight: CGFloat,
                             maxHeight: CGFloat? = nil,
                             tab: DataDrawerTab = .table) -> CGFloat {
        consoleHeight(frac: frac, windowHeight: windowHeight,
                      defaultHeight: preferredDrawerHeight(tab: tab),
                      minHeight: minDrawerHeight(tab: tab),
                      maxHeight: maxHeight ?? maxDrawerHeight(windowHeight: windowHeight))
    }

    // MARK: - the whole column, planned once (#543)

    /// What the macOS viewport column gives the Object viewer and the Data drawer.
    struct MacColumnPlan: Equatable {
        /// Rows the Object viewer's ideal height is charged at (and its `.id`), or nil
        /// when it is hidden. May be FEWER than `sequenceStripRows(objects:)` while the
        /// drawer is open — the viewer scrolls the rest.
        var sequenceRows: Int?
        /// What the column leaves the drawer after every pane above it.
        var drawerCeiling: CGFloat
        /// Whether the drawer draws (false = the "needs more room" hint).
        var drawerFits: Bool
        /// The drawer's height when it fits; nil when it does not (or is closed).
        var drawerHeight: CGFloat?
    }

    /// The column in one pure function: the Object viewer's rows, the drawer's ceiling,
    /// whether it fits and how tall it is, from the same flags the views read.
    ///
    /// The one policy it adds (#543): while the drawer is OPEN, the Object viewer gives
    /// up rows — down to one, never to nothing — until the drawer has
    /// `comfortDrawerHeight(tab:)`. Without it the default window cannot show a set: a
    /// five-object viewer is 180pt, and at 1332×771 with the console up 280 of viewport
    /// leaves 276 for the viewer and the drawer together. The viewer scrolls the rows
    /// it gave up (it already did past five); the drawer has nowhere to put a row it
    /// cannot draw. If even a one-row viewer leaves too little for the tab's FLOOR the
    /// drawer shows its hint, and then the viewer keeps all its rows, because giving
    /// them up would buy nothing.
    ///
    /// The yield's target respects a height the USER dragged to (#543 review): with a
    /// stored fraction the viewer yields only toward that height (lifted to the tab's
    /// floor) when it is below the comfort height — the user already said how much
    /// drawer they want.
    ///
    /// NO MCP banner term, on purpose (#543 review). The banner is up only while an
    /// agent's tool call runs, i.e. it flips on every command; charging it here swapped
    /// the drawer for its hint and back on each one, destroying the tab's view state
    /// (the plot's axes, colour and brush). So the banner never changes this plan: it
    /// takes its 32pt from the VIEWPORT instead, which may dip that far below its floor
    /// while a tool runs — see `viewportMinHeight(mcpBanner:)`. A docked Predict/Binder
    /// bar is persistent and IS charged.
    ///
    /// `sequenceObjects` is the enabled-object count when the viewer is showing
    /// (nil = hidden); `drawerVisible` false plans the column with no drawer at all.
    static func macColumnPlan(windowHeight: CGFloat, consoleHeight: CGFloat?,
                              topRail: Bool, sequenceObjects: Int?,
                              dockedModeBar: Bool,
                              drawerVisible: Bool, tab: DataDrawerTab,
                              drawerFrac: CGFloat) -> MacColumnPlan {
        let fullRows = sequenceObjects.map { sequenceStripRows(objects: $0) }
        func ceiling(rows: Int?) -> CGFloat {
            drawerCeiling(windowHeight: windowHeight,
                          used: drawerColumnUsed(consoleHeight: consoleHeight,
                                                 topRail: topRail, sequenceRows: rows,
                                                 mcpBanner: false,
                                                 dockedModeBar: dockedModeBar))
        }
        guard drawerVisible else {
            return MacColumnPlan(sequenceRows: fullRows, drawerCeiling: ceiling(rows: fullRows),
                                 drawerFits: false, drawerHeight: nil)
        }
        var rows = fullRows
        if let full = fullRows, full > 1, drawerFits(ceiling: ceiling(rows: 1), tab: tab) {
            let comfort = yieldTarget(tab: tab, drawerFrac: drawerFrac,
                                      windowHeight: windowHeight)
            var r = full
            while r > 1, ceiling(rows: r) < comfort { r -= 1 }
            rows = r
        }
        let c = ceiling(rows: rows)
        guard drawerFits(ceiling: c, tab: tab) else {
            return MacColumnPlan(sequenceRows: rows, drawerCeiling: c,
                                 drawerFits: false, drawerHeight: nil)
        }
        return MacColumnPlan(sequenceRows: rows, drawerCeiling: c, drawerFits: true,
                             drawerHeight: drawerHeight(frac: drawerFrac,
                                                        windowHeight: windowHeight,
                                                        maxHeight: c, tab: tab))
    }

    /// The drawer height the Object viewer yields rows toward: the tab's comfort height,
    /// or — when the user has dragged the drawer (a stored fraction) — the smaller of
    /// that and their height lifted to the tab's floor.
    static func yieldTarget(tab: DataDrawerTab, drawerFrac: CGFloat,
                            windowHeight: CGFloat) -> CGFloat {
        let comfort = comfortDrawerHeight(tab: tab)
        guard drawerFrac.isFinite, drawerFrac > 0, windowHeight.isFinite, windowHeight > 0
        else { return comfort }
        return min(comfort, max(drawerFrac * windowHeight, minDrawerHeight(tab: tab)))
    }

    /// The viewport's floor as the VIEW enforces it: `macViewportMinHeight`, less the
    /// MCP banner while it is up. The banner is transient and is deliberately left out
    /// of the column plan (see `macColumnPlan`), so it is the viewport that gives the
    /// banner its 32pt for the few seconds a tool call runs.
    static func viewportMinHeight(mcpBanner: Bool) -> CGFloat {
        macViewportMinHeight - (mcpBanner ? macMCPBannerHeight : 0)
    }

    /// The Object viewer's `maxHeight` in the split. The pane's `.id` is keyed on its
    /// OBJECT rows only (#543 review: re-identifying it on every column change lost its
    /// shift-click anchor and drag state and re-fetched the sequences), so a yield
    /// cannot re-seat its ideal height; capping the max is what makes the split give
    /// the rows back to the drawer. Not yielding → the usual generous cap.
    static func sequenceStripMaxHeight(plannedRows: Int?, objects: Int) -> CGFloat {
        guard let plannedRows, plannedRows < sequenceStripRows(objects: objects) else {
            return macMaxSequenceStripHeight
        }
        return sequenceStripIdealHeight(objects: plannedRows)
    }

    // MARK: - the hint's ways out (#543)

    /// A button on the "Data drawer needs more room" hint.
    enum DrawerRoomAction: Equatable { case hideConsole, hideSequences, close }

    /// The hint's buttons, in order. The console comes FIRST (#543): it is the pane the
    /// user is least likely to be reading at the moment a set lands, and closing it is
    /// worth more column (135pt) than any Object viewer short of five rows. Each pane is
    /// offered only while it is showing; Close always is.
    static func drawerNoRoomActions(consoleVisible: Bool,
                                    sequenceVisible: Bool) -> [DrawerRoomAction] {
        var actions: [DrawerRoomAction] = []
        if consoleVisible { actions.append(.hideConsole) }
        if sequenceVisible { actions.append(.hideSequences) }
        actions.append(.close)
        return actions
    }

    /// #350: the macOS inspector column's width on a launch with nothing stored.
    /// ABSOLUTE points for the same reason as the console default — an untouched
    /// inspector looks the same on a laptop and on a 6K display. 340 is the width
    /// the narrow-inspector redesign settled on (fits the Movie transport, matches
    /// the Theme Studio column).
    static let macDefaultInspectorWidth: CGFloat = 340
    /// Below this an Objects row is nothing but its fixed chrome — gutter (26) +
    /// five 38pt A/S/H/L/C buttons + chevron/indent — with no room left for even
    /// a short name, so shrinking further only breaks the panel.
    static let macMinInspectorWidth: CGFloat = 280
    /// The macOS viewport's own minimum WIDTH; the inspector may grow until the
    /// viewport is down to this. The horizontal sibling of `macViewportMinHeight`.
    static let macViewportMinWidth: CGFloat = 480

    // MARK: - macOS inspector sizing (#350)

    /// How wide the inspector is allowed to get in a window of `windowWidth`,
    /// given a viewport beside it that needs `viewportMin`. Same bracket shape as
    /// `maxConsoleHeight`: never more than half the window (the viewport must
    /// remain the main event), never less than `minCeilingFrac`.
    static func maxInspectorWidth(windowWidth: CGFloat,
                                  viewportMin: CGFloat = macViewportMinWidth) -> CGFloat {
        guard windowWidth.isFinite, windowWidth > 0 else { return 0 }
        return min(max(windowWidth - viewportMin, windowWidth * minCeilingFrac),
                   windowWidth * 0.5)
    }

    /// The inspector's width in a window of `windowWidth`.
    ///
    /// `frac` is the persisted share and applies only once the user has dragged
    /// the seam themselves; a missing, zero, negative or non-finite value (an
    /// unset UserDefaults Double reads as 0) means "untouched" and yields the
    /// absolute default. The CEILING WINS when it crosses the usable minimum —
    /// in a very narrow window, better a cramped inspector than no viewport.
    static func inspectorWidth(frac: CGFloat, windowWidth: CGFloat,
                               maxWidth: CGFloat) -> CGFloat {
        guard windowWidth.isFinite, windowWidth > 0 else { return macMinInspectorWidth }
        let w = (frac.isFinite && frac > 0) ? frac * windowWidth : macDefaultInspectorWidth
        return min(max(w, macMinInspectorWidth), maxWidth)
    }

    /// The fraction to persist for an inspector measured at `width`, clamped into
    /// the storable band so nothing unrestorable can ever be written. nil for a
    /// degenerate window — there is nothing meaningful to store, so don't write.
    static func inspectorFrac(width: CGFloat, windowWidth: CGFloat) -> CGFloat? {
        guard windowWidth.isFinite, windowWidth > 0, width.isFinite else { return nil }
        return min(max(width / windowWidth, minStorableFrac), maxStorableFrac)
    }

    // MARK: - Console sizing

    /// How tall the console is allowed to get in a window of `windowHeight`, given
    /// a pane below it that needs `viewportMin`.
    ///
    /// Normally that's "everything except the viewport's minimum" — 324pt of a
    /// 684pt window — which is generous enough to read a long log in. Two guards
    /// bracket it: never more than 85% of the window (the viewport must remain a
    /// viewport), and never less than `minCeilingFrac`.
    static func maxConsoleHeight(windowHeight: CGFloat,
                                 viewportMin: CGFloat = macViewportMinHeight) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return 0 }
        return min(max(windowHeight - viewportMin, windowHeight * minCeilingFrac),
                   windowHeight * 0.85)
    }

    /// The console's height in a window of `windowHeight`.
    ///
    /// `frac` is the persisted share, and applies only once the user has sized the
    /// console themselves; a missing, zero, negative or non-finite value (an unset
    /// UserDefaults Double reads as 0) means "untouched" and yields `defaultHeight`
    /// — an absolute size, so an untouched console looks the same on a laptop and
    /// on a 6K display.
    ///
    /// `minHeight` is the platform's usable floor; `maxHeight` the platform's
    /// ceiling (`maxConsoleHeight` on macOS, the layout's own 33% rule on iOS).
    /// The CEILING WINS when the two cross — in a very short window, better a
    /// cramped console than no viewport.
    static func consoleHeight(frac: CGFloat, windowHeight: CGFloat,
                              defaultHeight: CGFloat,
                              minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return minHeight }
        let h = (frac.isFinite && frac > 0) ? frac * windowHeight : defaultHeight
        return min(max(h, minHeight), maxHeight)
    }

    /// The fraction to persist for a console measured at `height`, clamped into
    /// the storable band so nothing unrestorable can ever be written. nil for a
    /// degenerate window — there is nothing meaningful to store, so don't write.
    static func consoleFrac(height: CGFloat, windowHeight: CGFloat) -> CGFloat? {
        guard windowHeight.isFinite, windowHeight > 0, height.isFinite else { return nil }
        return min(max(height / windowHeight, minStorableFrac), maxStorableFrac)
    }

    // MARK: - iPad bottom panel

    /// Clamp a restored iPad panel share into a band that leaves both the panel
    /// and the viewport usable. Zero (unset) or non-finite falls back to default.
    static func clampPanelFrac(_ frac: CGFloat) -> CGFloat {
        guard frac.isFinite, frac > 0 else { return defaultPanelFrac }
        return min(max(frac, minPanelFrac), maxPanelFrac)
    }
}
