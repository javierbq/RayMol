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
    /// Sequence strip visible. LEGACY on macOS since #419: the strip moved into the
    /// Data drawer's Sequences tab and the macOS layout has no strip slot any more,
    /// so nothing on the Mac reads or writes this. It is still iOS's flag — the
    /// drawer is macOS-only until #420 — which is why it stays in `allKeys` and why
    /// `migrateSequenceStrip` only CONSUMES it rather than deleting it.
    static let sequenceVisibleKey = ns + "sequenceVisible"
    /// Set once `migrateSequenceStrip` has run, so a user who later turns the strip
    /// off on an iPad does not get the drawer re-opened on the next Mac launch.
    static let sequenceMigratedKey = ns + "sequenceStripMigrated"
    /// Data drawer (#417) visible. Written by PyMOLEngine, which owns the flag,
    /// like the sequence strip's. macOS only until #420.
    static let dataDrawerVisibleKey = ns + "dataDrawerVisible"
    /// The user's Data drawer height, as a fraction of the window height. Absent
    /// until they drag its divider, which selects the absolute default.
    static let dataDrawerFracKey = ns + "dataDrawerFrac"
    /// Which drawer tab was showing (#419). Persisted because the sequence strip it
    /// replaced was a remembered pane: without this the strip's migration lands a user
    /// on Sequences exactly once and puts them on Table every launch after.
    static let dataDrawerTabKey = ns + "dataDrawerTab"
    /// The scene-sequence BAND in the drawer's chrome (#456). Its own key, not the
    /// tab's and not the drawer's, because it is its own pane: ⌘2 toggles it whatever
    /// tab is showing, and it is what the sequence strip actually became.
    static let sequenceBandVisibleKey = ns + "sequenceBandVisible"
    /// Set once `migrateSequenceBand` has run. Separate from `sequenceMigratedKey`
    /// because the two migrations answer different questions and a user can arrive
    /// having had one run and not the other — see `sequenceBandMigration`.
    static let sequenceBandMigratedKey = ns + "sequenceBandMigrated"

    /// Every key this type defines — the namespace/uniqueness check in the tests
    /// runs off this list, so a new key must be added here too.
    static let allKeys: [String] = [
        consoleVisibleKey, objectsVisibleKey,
        landscapeConsoleVisibleKey, landscapeObjectsVisibleKey,
        consoleFracKey, inspectorFracKey, panelFracKey, sequenceVisibleKey,
        dataDrawerVisibleKey, dataDrawerFracKey, sequenceMigratedKey, dataDrawerTabKey,
        sequenceBandVisibleKey, sequenceBandMigratedKey,
    ]

    // MARK: - The sequence strip's one-time move into the drawer (#419)

    /// What the first launch after #419 should do with a stored `sequenceVisible`.
    ///
    /// The strip is gone from the macOS layout; leaving it at that would silently take
    /// a visible pane away from everyone who had it on, with no hint that it moved.
    /// So the flag is CONSUMED once: a strip that was showing becomes an open drawer on
    /// the Sequences tab, which is the same content in its new home (spec §8 decision
    /// 2 — with no set open the tab shows exactly what the strip showed).
    ///
    /// A strip that was OFF changes nothing: the drawer keeps whatever visibility it
    /// had, on whatever tab it would have opened on. "Off" is a choice too, and turning
    /// a pane ON for someone who closed it is the same discourtesy in the other
    /// direction.
    ///
    /// Pure, so the policy can be walked without a window or a UserDefaults domain.
    struct SequenceStripMigration: Equatable {
        /// True when the drawer should be visible (either it already was, or the strip
        /// was and this is where it went).
        let drawerVisible: Bool
        /// The tab to open on. `nil` means "leave the default alone".
        let openSequencesTab: Bool
        /// False when the migration had already run, so nothing should be written.
        let didMigrate: Bool

        static let alreadyDone = SequenceStripMigration(drawerVisible: false,
                                                        openSequencesTab: false,
                                                        didMigrate: false)
        /// iOS: the strip is still the sequence view there until #420, so there is
        /// nothing to migrate and — importantly — nothing to WRITE. `drawerVisible`
        /// is not read on that platform (see `restoredDrawerVisible`).
        static let notOnThisPlatform = alreadyDone
    }

    /// `legacyStripVisible` is nil when the key was never written (a fresh install, or
    /// a user who never touched the strip), which is not the same as `false` only in
    /// that neither does anything — both leave the drawer where it was.
    static func sequenceStripMigration(legacyStripVisible: Bool?,
                                       drawerVisible: Bool,
                                       alreadyMigrated: Bool) -> SequenceStripMigration {
        guard !alreadyMigrated else {
            return SequenceStripMigration(drawerVisible: drawerVisible,
                                          openSequencesTab: false, didMigrate: false)
        }
        if legacyStripVisible == true {
            return SequenceStripMigration(drawerVisible: true, openSequencesTab: true,
                                          didMigrate: true)
        }
        return SequenceStripMigration(drawerVisible: drawerVisible,
                                      openSequencesTab: false, didMigrate: true)
    }

    /// Run the migration against a defaults domain and return its answer. Idempotent:
    /// the second call sees `sequenceMigratedKey` and reports "nothing to do".
    ///
    /// The legacy key is READ and then left alone rather than removed: iOS still draws
    /// the strip from it until #420 gives the drawer an iPad and iPhone layout, and a
    /// Mac launch must not reach across and close an iPad's strip. What stops on the
    /// Mac is the WRITING — `PyMOLEngine.sequenceVisible` is an iOS-only property now.
    @discardableResult
    static func migrateSequenceStrip(defaults: UserDefaults = .standard)
        -> SequenceStripMigration {
        let legacy: Bool? = defaults.object(forKey: sequenceVisibleKey) as? Bool
        let answer = sequenceStripMigration(
            legacyStripVisible: legacy,
            drawerVisible: defaults.bool(forKey: dataDrawerVisibleKey),
            alreadyMigrated: defaults.bool(forKey: sequenceMigratedKey))
        guard answer.didMigrate else { return answer }
        defaults.set(true, forKey: sequenceMigratedKey)
        if answer.drawerVisible != defaults.bool(forKey: dataDrawerVisibleKey) {
            defaults.set(answer.drawerVisible, forKey: dataDrawerVisibleKey)
        }
        // The chosen TAB has to be written too (#456 review). `restoredDrawerTab`
        // returns `.sequences` from the answer, but the only thing that ever wrote
        // `dataDrawerTabKey` was `PyMOLEngine.dataDrawerTab`'s `didSet` — and `didSet`
        // does not fire on initialisation, so a migrated user who never touched a tab
        // afterwards had NO stored tab at all. #456 then reads that key to decide
        // whether the sequence view was up, and answered "no" for exactly the people
        // the question is about: the ones #419 had put on Sequences.
        if answer.openSequencesTab {
            defaults.set(DataDrawerTab.sequences.rawValue, forKey: dataDrawerTabKey)
        }
        return answer
    }

    /// The migration, run exactly once per process against the standard defaults —
    /// and ONLY on macOS.
    ///
    /// A `static let` rather than a call at each use site: `PyMOLEngine` reads the
    /// answer from two property initialisers (the drawer's visibility and its tab),
    /// and those run in declaration order, which is not a thing a behaviour should
    /// depend on. Swift initialises this lazily and exactly once, so both see the
    /// same answer whichever runs first.
    ///
    /// The platform gate matters even though iOS has no drawer to migrate INTO: an
    /// ungated call writes `sequenceStripMigrated = true` (and `dataDrawerVisible`)
    /// into iOS defaults at engine init, where `sequenceVisible` defaults TRUE on
    /// iPad. Harmless while #420 is unwritten, and then, the day the drawer gets an
    /// iPad layout, every existing iPad user has the drawer popped open at launch with
    /// the migration already spent and no way to have declined it.
    #if os(macOS)
    static let sequenceStripMigrationResult: SequenceStripMigration =
        migrateSequenceStrip()
    #else
    static let sequenceStripMigrationResult = SequenceStripMigration.notOnThisPlatform
    #endif

    /// The drawer's visibility at launch: on macOS whatever the migration decided
    /// (which is the stored value when there was nothing to migrate), on iOS the
    /// stored value, untouched.
    static func restoredDrawerVisible(defaults: UserDefaults = .standard) -> Bool {
        #if os(macOS)
        return sequenceStripMigrationResult.drawerVisible
        #else
        return defaults.bool(forKey: dataDrawerVisibleKey)
        #endif
    }

    /// The drawer's tab at launch. The migration wins when it fired — that is the
    /// whole of what it does — and otherwise the persisted choice, validated, because
    /// a tab name from a newer build (or a hand-edited plist) must not leave the
    /// drawer on a tab this build cannot draw.
    static func restoredDrawerTab(migration: SequenceStripMigration,
                                  stored: String?) -> DataDrawerTab {
        if migration.openSequencesTab { return .sequences }
        guard let stored, let tab = DataDrawerTab(rawValue: stored), tab.isAvailable else {
            return .table
        }
        return tab
    }

    static func restoredDrawerTab(defaults: UserDefaults = .standard) -> DataDrawerTab {
        restoredDrawerTab(migration: sequenceStripMigrationResult,
                          stored: defaults.string(forKey: dataDrawerTabKey))
    }

    // MARK: - The scene rows become a drawer BAND (#456)

    /// Where a user lands the first time they launch a build in which the scene rows
    /// are a band in the drawer's chrome rather than the top half of the Sequences tab.
    ///
    /// Two views, two nouns: the band shows the sequences of the ENABLED SCENE OBJECTS,
    /// the Sequences tab shows the CONTENTS OF A SET. #419 made them alternatives —
    /// `wantsSequences` was "drawer up AND tab == Sequences" — so you could not watch
    /// the scene sequence while triaging in the Table. They are not alternatives any
    /// more, which means the thing that has to be carried forward is no longer "which
    /// tab" but "was the sequence view up".
    ///
    /// The answer has to be right for a user who has already been migrated ONCE, by
    /// #419, and whose `sequenceVisible` flag is therefore spent. For them the honest
    /// reading of "the sequence view is up" is the drawer standing open on Sequences —
    /// that is the state #419 put them in, and that is where the scene rows were. A
    /// drawer that is CLOSED is not showing anything, whatever tab it remembers.
    ///
    /// Pure, so the policy can be walked without a window or a UserDefaults domain.
    struct SequenceBandMigration: Equatable {
        /// True when the band should be on after this launch.
        let bandVisible: Bool
        /// False when the migration had already run, so nothing should be written.
        let didMigrate: Bool

        static let alreadyDone = SequenceBandMigration(bandVisible: false,
                                                       didMigrate: false)
        /// iOS: the strip is still its own pane there until #420, so there is no band
        /// to migrate into and — importantly — nothing to WRITE.
        static let notOnThisPlatform = alreadyDone
    }

    /// `stripMigration` is #419's answer for this same launch, which is what tells the
    /// two arrival routes apart:
    ///
    ///  * `didMigrate == true` — #419 is firing NOW, so this user comes straight from a
    ///    build with a strip. `openSequencesTab` is exactly "the strip was visible",
    ///    which is exactly what the band should be.
    ///  * `didMigrate == false` — #419's flag is spent (or there was nothing to spend
    ///    it on). The drawer standing OPEN on Sequences is the sequence view being up;
    ///    anything else, including a closed drawer that remembers the tab, is not.
    static func sequenceBandMigration(stripMigration: SequenceStripMigration,
                                      drawerVisible: Bool,
                                      drawerTab: DataDrawerTab,
                                      storedBandVisible: Bool,
                                      alreadyMigrated: Bool) -> SequenceBandMigration {
        guard !alreadyMigrated else {
            return SequenceBandMigration(bandVisible: storedBandVisible, didMigrate: false)
        }
        if stripMigration.didMigrate {
            return SequenceBandMigration(bandVisible: stripMigration.openSequencesTab,
                                         didMigrate: true)
        }
        return SequenceBandMigration(bandVisible: drawerVisible && drawerTab == .sequences,
                                     didMigrate: true)
    }

    /// Run it against a defaults domain and return its answer. Idempotent, like
    /// `migrateSequenceStrip`: the second call sees `sequenceBandMigratedKey`.
    ///
    /// It reads the drawer's visibility and tab AFTER #419's migration has had its
    /// turn — the `stripMigration` argument is that turn — because for a never-migrated
    /// user #419 writes `dataDrawerVisible` and this must not read the pre-write value
    /// and reach the opposite conclusion.
    @discardableResult
    static func migrateSequenceBand(stripMigration: SequenceStripMigration,
                                    defaults: UserDefaults = .standard)
        -> SequenceBandMigration {
        let answer = sequenceBandMigration(
            stripMigration: stripMigration,
            drawerVisible: defaults.bool(forKey: dataDrawerVisibleKey),
            drawerTab: restoredDrawerTab(migration: .alreadyDone,
                                         stored: defaults.string(forKey: dataDrawerTabKey)),
            storedBandVisible: defaults.bool(forKey: sequenceBandVisibleKey),
            alreadyMigrated: defaults.bool(forKey: sequenceBandMigratedKey))
        guard answer.didMigrate else { return answer }
        defaults.set(true, forKey: sequenceBandMigratedKey)
        defaults.set(answer.bandVisible, forKey: sequenceBandVisibleKey)
        return answer
    }

    /// The band migration, run exactly once per process and ONLY on macOS — a
    /// `static let` for `sequenceStripMigrationResult`'s reason, and gated for its
    /// reason too: iOS has no drawer to put a band in until #420, and writing
    /// `sequenceBandMigrated` into an iPad's defaults now would spend a migration that
    /// day's layout still needs.
    #if os(macOS)
    static let sequenceBandMigrationResult: SequenceBandMigration =
        migrateSequenceBand(stripMigration: sequenceStripMigrationResult)
    #else
    static let sequenceBandMigrationResult = SequenceBandMigration.notOnThisPlatform
    #endif

    /// The band's visibility at launch: on macOS whatever the migration decided (which
    /// is the stored value once it has run), on iOS false — there is no band there.
    ///
    /// No `defaults:` parameter, unlike `restoredDrawerVisible`: neither branch would
    /// read it, and a parameter a function ignores is a caller passing a test suite and
    /// silently getting the standard domain's answer (#456 review). The pure function
    /// `sequenceBandMigration` is what tests drive.
    static func restoredSequenceBandVisible() -> Bool {
        #if os(macOS)
        return sequenceBandMigrationResult.bandVisible
        #else
        return false
        #endif
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
    /// predict log") working while still guaranteeing a viewport.
    static let macViewportMinHeight: CGFloat = 360

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

    /// The drawer's own header row ("DATA · <set>  ⌘2 ✕"), and the hairline under it.
    /// Above the band; not part of the tab half.
    static let macDrawerHeaderHeight: CGFloat = 26
    /// `DataDrawer.tabRow` — the tab strip with the filter bar beside it — and the
    /// hairline under it. The first thing in the tab half.
    static let macDrawerTabRowHeight: CGFloat = 24
    /// `SetTableView`'s own chrome: the column header (20), the histogram/brush strip
    /// (16), the footer (24) and their two hairlines.
    static let macDrawerTableChrome: CGFloat = 62
    /// One table row.
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
    /// moved onto its own row — and it was already short of the histogram strip. The
    /// undercount did not show while the whole drawer was one pane; the band divides
    /// that pane, so it is what made it bite.
    static var macDrawerChromeHeight: CGFloat {
        macDrawerHeaderHeight + macDrawerHairline + macDrawerTabRowHeight
            + macDrawerHairline + macDrawerTableChrome
    }
    /// Header + tab row + table chrome + one row; below this the drawer is chrome
    /// and no data.
    static var macMinDrawerHeight: CGFloat { macDrawerChromeHeight + macDrawerRowHeight }

    // MARK: - the scene band inside the drawer (#456)

    /// The hairline (and split divider) between the band and the tab half.
    static let macBandDividerHeight: CGFloat = 1
    /// The band's floor. One block of residues with its ruler; below this the band is
    /// a sliver you cannot read a sequence in, which is the only thing it is for.
    static let macMinBandHeight: CGFloat = 40
    /// What the TAB half needs under the band: its tab row, the table's chrome and
    /// ONE row. The drawer's header is not in it — the band does not take that.
    ///
    /// The name is the contract, and the #456 review caught it not meaning it: as
    /// `macMinDrawerHeight - macDrawerHeaderHeight` it was 70, which is 17pt below the
    /// table's chrome alone, so the band took its ideal, the tab half was left unable
    /// to draw even its footer, and the Table showed its column header and nothing
    /// else — at every window size, with `drawerFits` true throughout so the hint
    /// never fired. A floor that does not fit one row is not a floor.
    static var macMinTabContentHeight: CGFloat {
        macDrawerTabRowHeight + macDrawerHairline + macDrawerTableChrome + macDrawerRowHeight
    }

    /// The band's allowance in an UNTOUCHED drawer: a two-object scene (a target and a
    /// design, which is the ordinary case) at the strip's own ideal height.
    ///
    /// A constant rather than the live object count, because this is the DEFAULT — it
    /// must not move under the user as objects load, for the reason the default is
    /// absolute points rather than a share of the window.
    static var macDefaultBandHeight: CGFloat { sequenceBandIdealHeight(objects: 2) }

    /// The drawer's height on a launch with nothing stored, with the band on: the
    /// plain default PLUS the band's allowance.
    ///
    /// The band takes its height from the tab content in a drawer the USER has sized —
    /// that is the rule, and a stored fraction still wins here. But an untouched
    /// drawer has no such choice to respect, and charging the band against a default
    /// chosen when there was no band is how "turn the sequences on" came to mean "lose
    /// your table" (#456 review). Out of the box the band is free.
    static func defaultDrawerHeight(bandVisible: Bool) -> CGFloat {
        macDefaultDrawerHeight
            + (bandVisible ? macDefaultBandHeight + macBandDividerHeight : 0)
    }

    /// How many table rows the tab half can actually draw in a drawer this tall. The
    /// number the review's regression is stated in — "rows with the band on = 0
    /// everywhere" — so it is the number the tests assert on.
    static func drawerTableRows(drawerHeight: CGFloat, bandObjects: Int?) -> Int {
        var left = drawerHeight - macDrawerHeaderHeight
        if let bandObjects {
            left -= sequenceBandHeight(objects: bandObjects, drawerHeight: drawerHeight)
            left -= macBandDividerHeight
        }
        left -= macDrawerTabRowHeight + macDrawerHairline + macDrawerTableChrome
        guard left > 0 else { return 0 }
        return Int(left / macDrawerRowHeight)
    }

    /// The band's IDEAL height — the sequence strip's own formula, unchanged since
    /// #419 and before that since the strip itself: one block per enabled object
    /// (ruler + residues ≈ 28pt, charged at 30) up to five, plus 30 for the horizontal
    /// scrollbar and padding. The compatibility contract is that a user who had the
    /// strip open sees the same number of rows at the same size in its new home.
    static func sequenceBandIdealHeight(objects: Int) -> CGFloat {
        CGFloat(min(max(objects, 1), 5)) * 30 + 30
    }

    /// The band's height inside a drawer of `drawerHeight`, with a set open under it.
    ///
    /// Its ideal, but never so much that the tab content drops below one row: the BAND
    /// yields, for the reason the drawer yields to the console — the band exists so
    /// that the scene sequence and the candidate table can be read TOGETHER (#456), and
    /// a band that squeezed the table out would be the same "two views compete" failure
    /// in the other direction. Never below `macMinBandHeight` either, because a band
    /// too short to read is worse than the hint that says there is no room.
    static func sequenceBandHeight(objects: Int, drawerHeight: CGFloat) -> CGFloat {
        let room = drawerHeight - macDrawerHeaderHeight - macMinTabContentHeight
                 - macBandDividerHeight
        return max(min(sequenceBandIdealHeight(objects: objects), room), macMinBandHeight)
    }

    /// The drawer's minimum with the band on: its own minimum, plus the band's floor
    /// and the divider. This is what `drawerFits` tests and what the drag divider
    /// clamps to, so the two cannot disagree about whether a window has the room.
    static func minDrawerHeight(bandVisible: Bool) -> CGFloat {
        macMinDrawerHeight + (bandVisible ? macMinBandHeight + macBandDividerHeight : 0)
    }

    /// Height the panes ABOVE the drawer have already claimed in the viewport
    /// column, so the drawer can size itself against what is actually left.
    ///
    /// The sequence strip used to be charged here too, at its ideal height. #419
    /// removed the macOS strip slot — the sequences are a drawer TAB now, so they
    /// take the drawer's own height and cannot compete with it for the column —
    /// which is why a crowded column is now only the console and the rail, and why
    /// the drawer fits in windows where it did not before. #456 moved the scene rows
    /// again — out of the tab, into the drawer's chrome — and that changes nothing
    /// here for the same reason: the band is INSIDE the drawer, so it spends the
    /// drawer's height (`sequenceBandHeight`), not the column's.
    static func drawerColumnUsed(consoleHeight: CGFloat?, topRail: Bool) -> CGFloat {
        var used: CGFloat = 0
        if let consoleHeight { used += consoleHeight + macConsoleDividerHeight }
        if topRail { used += macTopRailHeight }
        // Chrome that is not a pane but still takes column height: the two drag
        // dividers' padding, the MCP "controlling" banner, a docked Predict or
        // Binder bar. An allowance rather than a measurement — a few points of
        // under-use beat a footer off the window.
        return used + macColumnChromeAllowance
    }

    static let macConsoleDividerHeight: CGFloat = 5
    static let macTopRailHeight: CGFloat = 23
    static let macColumnChromeAllowance: CGFloat = 48

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
    /// `bandVisible` raises the bar by the scene band's floor (#456). The hint offers
    /// "Hide Sequences" when it is the band that tipped it over, so the band can never
    /// make the drawer unreachable — there is always a way back that is one click, not
    /// a window resize.
    static func drawerFits(ceiling: CGFloat, bandVisible: Bool = false) -> Bool {
        ceiling >= minDrawerHeight(bandVisible: bandVisible)
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
    /// hard 360pt minimum, so the layout passes the height LEFT after those panes
    /// — the drawer yields, rather than pushing its own bottom rows off the window
    /// in a short one. The stored fraction is still of the whole window, so what
    /// the user dragged to means the same thing whether or not the console is up.
    static func drawerHeight(frac: CGFloat, windowHeight: CGFloat,
                             maxHeight: CGFloat? = nil,
                             bandVisible: Bool = false) -> CGFloat {
        consoleHeight(frac: frac, windowHeight: windowHeight,
                      defaultHeight: defaultDrawerHeight(bandVisible: bandVisible),
                      minHeight: minDrawerHeight(bandVisible: bandVisible),
                      maxHeight: maxHeight ?? maxDrawerHeight(windowHeight: windowHeight))
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
