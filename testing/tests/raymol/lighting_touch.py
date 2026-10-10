"""The Lights tools' touch targets: the source checks of #623.

On iOS every light target is a 44 pt target (spec §9, #623): the orbit
view's lamps, radius square, pitch handle and pitch track, and the gizmo's
knobs, aim dot, ring handles and ring lines are hit within at least 22 pt of
their centre or line. The rule is a floor, max(drawn + slop, 22), not a
bigger slop, so a target already reached farther keeps its reach and macOS
(a floor of 0) is unchanged. The Lights bar, its chips, the cards' header
controls and the gizmo's Shadow chip get 44 pt labels through
lightsTouchTarget(), and the inspector lays its colour swatches out as 44 pt
targets in 6 or 3 columns.

Touch routing (Part 2): a two-finger sequence whose first recognizer begins
on a knob with the fingers at most 120 pt apart is the gizmo's (the pinch
sets that light's radius; the pan and the twist do nothing); a long-press
never begins on a knob, the aim dot or a handle and places a highlight
anywhere else while the gizmo shows (the context menu only when it is
hidden); an option-tap off every target does the same; Move mode's
one-finger pan hit-tests where the finger came down (#702).

The docked tools (Part 3, LightsSheet.swift): placement by size class, the
sheet's heights keyed by the room (the scene keeps 180 pt), the grabber drag
on a cancel-safe @GestureState, the compact rows writing through the
controller's typed API, the pinned canvases outside the rows' ScrollView,
the inspector's header and rows presentations and the fields' focus
preference.

The phone wiring (Part 4, ContentView): the portrait viewport and the sheet
in one unconditional GeometryReader (one MTKView per launch), the console
and sequence strip giving way without their stored flags being written, the
side panel in both landscape slots, the drawable frozen only for a snap
with the safety resets, the focused-field keyboard rule and the DEBUG log
lines.

The iPad float (Part 5, LightsFloatingTools.swift and ContentView): the
orbit card's header as a 44 pt grip on a cancel-safe @GestureState drag that
snaps once on release, the corner remembered in PanelLayout, the clearances
from the help button, the measured bottom-leading chrome and an open
CameraDock, the float after the gizmo site replacing the iOS side column,
and the covered= field of the DEBUG LightsLayout line.

The calibration support (Part 6, MetalViewport.swift): the 30 Hz dust cap
stays the default; RAYMOL_AIR_FPS (1-120) and RAYMOL_AIR_LOG=1 are launch
switches read once in AirRedrawGate, and draw(in:) names none of it (the
hold log runs inside airTickDue; lighting_air_msl.py pins the gate itself).

The real-recognizer UI tests (Part 7, LightsGestureUITests.swift, run by
UITests_iOS on the ticket simulators): a PYMOL_UITEST=1 probe in ContentView
(lightsProbe: the selected light, a camera hash and the rig) and the
viewport's raymol.viewport identifier exist only under that switch, read
without writing, and the UI test file names every gesture it covers.

The behaviour itself is unit-tested in Swift (LightsTouchTargetTests and
LightsTouchRoutingTests, run by UnitTests_macOS with the iOS profile as a
parameter); this file pins, on the sources, that the hit tests use the floor,
that the numbers give every target at least 22 pt on iOS and keep macOS's
reach, that each control site carries the modifier, and the iOS routing's
deciders, delegate and touch-down point (comments stripped; skipped outside
a checkout). lighting_gizmo.py checks each iOS handler's order.

CI builds the GLUT flavour without a GPU, so this reads Swift sources only.

Runs on a RayMol build:
    pymol -ckqy testing/testing.py --run testing/tests/raymol/lighting_touch.py
"""
import os
import re

from pymol import testing

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), os.pardir,
                                     os.pardir, os.pardir))
SHARED = os.path.join('swiftui', 'PyMOLViewer', 'Shared')
TOUCH = os.path.join(SHARED, 'LightsTouch.swift')
ORBIT_MODEL = os.path.join(SHARED, 'LightsOrbitModel.swift')
ORBIT_VIEW = os.path.join(SHARED, 'LightsOrbitView.swift')
GIZMO_MODEL = os.path.join(SHARED, 'LightGizmoModel.swift')
GIZMO_OVERLAY = os.path.join(SHARED, 'LightGizmoOverlay.swift')
BAR = os.path.join(SHARED, 'LightsBar.swift')
INSPECTOR = os.path.join(SHARED, 'LightsInspector.swift')
VIEWPORT = os.path.join(SHARED, 'MetalViewport.swift')
SHEET = os.path.join(SHARED, 'LightsSheet.swift')
CONTENT_VIEW = os.path.join(SHARED, 'ContentView.swift')
FLOAT = os.path.join(SHARED, 'LightsFloatingTools.swift')
ATMOSPHERE_CARD = os.path.join(SHARED, 'LightsAtmosphereCard.swift')
PANEL_LAYOUT = os.path.join(SHARED, 'PanelLayout.swift')
UI_TESTS = os.path.join('swiftui', 'PyMOLViewerUITests', 'LightsGestureUITests.swift')

# Apple's minimum touch target, and the iOS and macOS slops
# (LightsOrbitMetrics.defaultSlop).
MINIMUM = 44.0
IOS_SLOP = 14.0
MAC_SLOP = 6.0


def strip_comments(text):
    """Swift comments removed (as lighting_mode.strip_comments), so a
    comment can neither satisfy nor trip a check."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def body(text, signature):
    """The braces-matched body that follows `signature` (None when absent)."""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find('{', start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


def reach(drawn, slop, minimum):
    """LightsTouch.reach: the drawn size plus the slop, at least half the
    minimum target."""
    return max(drawn + slop, minimum / 2)


class TestTouchSource(testing.PyMOLTestCase):

    def read(self, rel):
        path = os.path.join(ROOT, rel)
        if not os.path.isfile(path):
            # Skipped, not passed: a source check that cannot find its source
            # has checked nothing. Only reached outside a checkout.
            self.skipTest('%s not present; not a repo checkout' % rel)
        with open(path, encoding='utf-8') as handle:
            return strip_comments(handle.read())

    def number(self, text, pattern, what):
        match = re.search(pattern, text)
        self.assertIsNotNone(match, '%s not found' % what)
        return float(match.group(1))

    # --- the rule -------------------------------------------------------------

    def testTheFloorIs44OnIOSAnd0OnMacOS(self):
        """minimumTarget is 44 under #if os(iOS) and 0 otherwise; the reach
        is max(drawn + slop, minimumTarget / 2); the swatches are 44 pt
        targets, six in a row when 6 x 44 fits, else three."""
        text = self.read(TOUCH)
        minimum = body(text, 'static var minimumTarget: CGFloat')
        self.assertIsNotNone(minimum, 'LightsTouch.minimumTarget not found')
        self.assertRegex(minimum, r'#if os\(iOS\)\s*return 44\s*#else\s*return 0\s*#endif')
        rule = body(text, 'static func reach(drawn: CGFloat, slop: CGFloat, minimumTarget: CGFloat)')
        self.assertIsNotNone(rule, 'LightsTouch.reach not found')
        self.assertIn('max(drawn + slop, minimumTarget / 2)', rule)
        self.assertEqual(self.number(text, r'static let swatchTarget: CGFloat = ([0-9.]+)',
                                     'swatchTarget'), MINIMUM)
        columns = body(text, 'static func swatchColumns(width: CGFloat) -> Int')
        self.assertIsNotNone(columns, 'swatchColumns not found')
        self.assertIn('width >= 6 * swatchTarget ? 6 : 3', columns)

    def testTheModifierGrowsOnlyTheHitArea(self):
        """lightsTouchTarget() frames the label at least the minimum target
        (from the environment, the platform's by default) and makes the whole
        frame hit-testable; with a minimum of 0 (macOS) it changes nothing."""
        text = self.read(TOUCH)
        self.assertRegex(text, r'static let defaultValue: CGFloat = LightsTouch\.minimumTarget')
        modifier = body(text, 'func body(content: Content) -> some View')
        self.assertIsNotNone(modifier, 'LightsTouchTargetModifier.body not found')
        self.assertIn('if minimum > 0', modifier)
        self.assertIn('.frame(minWidth: width ? minimum : nil, minHeight: minimum)', modifier)
        self.assertIn('.contentShape(Rectangle())', modifier)

    # --- the orbit view -----------------------------------------------------

    def testOrbitTargetsUseTheFloor(self):
        """Lamps (unselected 6 + 14 = 20), the square (5 + 14 = 19 per axis),
        the pitch handle (7 + 14 = 21) and the track (14) all reach 22 on
        iOS through the layouts' reach; macOS keeps drawn + 6."""
        text = self.read(ORBIT_MODEL)
        drawn = {name: self.number(text, r'static let %s: CGFloat = ([0-9.]+)' % name, name)
                 for name in ('lampRadius', 'selectedLampRadius', 'squareHalfSide', 'handleRadius')}
        for name, size in drawn.items():
            with self.subTest(name):
                self.assertGreaterEqual(reach(size, IOS_SLOP, MINIMUM), MINIMUM / 2)
                self.assertEqual(reach(size, MAC_SLOP, 0), size + MAC_SLOP)
        self.assertGreaterEqual(reach(0, IOS_SLOP, MINIMUM), MINIMUM / 2, 'the track')
        for layout in ('struct OrbitPlanLayout', 'struct PitchArcLayout'):
            with self.subTest(layout):
                block = body(text, layout)
                self.assertIsNotNone(block, layout + ' not found')
                self.assertIn('minimumTarget: CGFloat = LightsTouch.minimumTarget', block)
                self.assertIn('LightsTouch.reach(', block)
        hit = body(text, 'enum OrbitHitTest')
        self.assertIsNotNone(hit, 'OrbitHitTest not found')
        for token in ('layout.lampReach(', 'layout.squareReach', 'layout.handleReach',
                      'layout.trackReach'):
            self.assertIn(token, hit)
        self.assertNotIn('+ layout.slop', hit, 'a reach without the floor')
        self.assertNotIn('<= layout.slop', hit, 'a reach without the floor')

    def testTheSquareAngleKeepsBothProfiles(self):
        """The square's chord needs 2 * max(selected lamp + slop, minimum /
        2): 28 on macOS and 44 on iOS, both as before the floor."""
        text = self.read(ORBIT_MODEL)
        angle = body(text, 'func squareAngle(radius: Double) -> Double')
        self.assertIsNotNone(angle, 'squareAngle not found')
        self.assertIn('max(LightsOrbitMetrics.selectedLampRadius + slop, minimumTarget / 2)', angle)
        selected = self.number(text, r'static let selectedLampRadius: CGFloat = ([0-9.]+)',
                               'selectedLampRadius')
        self.assertEqual(2 * max(selected + MAC_SLOP, 0), 28)
        self.assertEqual(2 * max(selected + IOS_SLOP, MINIMUM / 2), 2 * (selected + IOS_SLOP))

    def testTheOrbitChevronIsATarget(self):
        text = self.read(ORBIT_VIEW)
        button = body(text, 'private var collapseButton: some View')
        self.assertIsNotNone(button, 'collapseButton not found')
        self.assertIn('.lightsTouchTarget()', button)
        self.assertIn('.frame(height: max(Self.headerHeight, touchMinimum))', text)

    # --- the gizmo ------------------------------------------------------------

    def testGizmoTargetsUseTheFloor(self):
        """Knobs (unselected 7 + 14 = 21), the aim dot (4 + 14 = 18), handles
        (4.5 + 14 = 18.5 per axis) and ring lines (half the stroke + 14) all
        reach 22 on iOS; the hit test compares with the metrics' reach, never
        with the bare slop."""
        text = self.read(GIZMO_MODEL)
        metrics = body(text, 'struct LightGizmoMetrics')
        self.assertIsNotNone(metrics, 'LightGizmoMetrics not found')
        sizes = {name: float(value) for name, value in
                 re.findall(r'var (knobRadius|selectedKnobRadius|aimDotRadius|handleHalfSide'
                            r'|outerRingWidth|innerRingWidth): CGFloat = ([0-9.]+)', metrics)}
        self.assertEqual(len(sizes), 6, sizes)
        for name, size in sizes.items():
            drawn = size / 2 if name.endswith('Width') else size
            with self.subTest(name):
                self.assertGreaterEqual(reach(drawn, IOS_SLOP, MINIMUM), MINIMUM / 2)
                self.assertEqual(reach(drawn, MAC_SLOP, 0), drawn + MAC_SLOP)
        self.assertIn('minimumTarget: CGFloat = LightsTouch.minimumTarget', metrics)
        self.assertIn('self.handleSeparation = max(12, minimumTarget)', metrics)
        self.assertIn('LightsTouch.reach(drawn: radius, slop: slop, minimumTarget: minimumTarget)', metrics)
        hit = body(text, 'enum LightGizmoHitTest')
        self.assertIsNotNone(hit, 'LightGizmoHitTest not found')
        for token in ('metrics.reach(knob.radius)', 'metrics.reach(metrics.aimDotRadius)',
                      'metrics.handleReach', 'metrics.ringReach(width: metrics.outerRingWidth)',
                      'metrics.ringReach(width: metrics.innerRingWidth)'):
            self.assertIn(token, hit)
        self.assertIsNone(re.search(r'<=\s*slop\b', hit), 'a reach without the floor')

    def testHandlesStayInTheView(self):
        """#693: the handles go to the rightmost sample first; only when one
        would leave the view (less the chrome insets, inset by the handle's
        reach) does another index win, both rings using the same index, with
        the visible sample nearest the aim dot as the fallback."""
        text = self.read(GIZMO_MODEL)
        selected = body(text, 'private static func selected(')
        self.assertIsNotNone(selected, 'LightGizmoLayout.selected not found')
        first = selected.find('inner.rightmost ?? aim')
        rule = selected.find('if !insideBoth(handles)')
        self.assertGreaterEqual(first, 0, 'the rightmost placement comes first')
        self.assertGreater(rule, first, 'the in-view rule only replaces it')
        self.assertIn('.insetBy(dx: metrics.handleReach, dy: metrics.handleReach)', selected)
        self.assertIn('inner.samples[k]', selected)
        self.assertIn('insets.top', selected)
        self.assertIn('gizmoDistance($0.ring, aim)', selected)

    def testTheOverlayUsesTheReach(self):
        """The knobs' VoiceOver (and XCUITest) frames are their hit areas,
        the chip sits past the selected knob's reach, and the chip's label is
        a 44 pt target on iOS."""
        text = self.read(GIZMO_OVERLAY)
        elements = body(text, 'static func knobElements(')
        self.assertIsNotNone(elements, 'knobElements not found')
        self.assertIn('layout.metrics.reach(knob.radius)', elements)
        self.assertNotIn('metrics.slop', elements)
        chip = body(text, 'static func chipPlacement(')
        self.assertIsNotNone(chip, 'chipPlacement not found')
        self.assertIn('layout.metrics.reach(knob.radius)', chip)
        self.assertNotIn('metrics.slop', chip)
        label = body(text, 'private func chip(_ chip: LightGizmoState.Chip) -> some View')
        self.assertIsNotNone(label, 'the Shadow chip not found')
        self.assertIn('.lightsTouchTarget()', label)

    # --- the controls ---------------------------------------------------------

    def testEveryBarControlIsATarget(self):
        """Add, remove, Presets, Re-centre, power, the overflow menu, Revert
        and Done have 44 pt labels on iOS, the chips are 44 pt tall, and the
        compact bar's spacing drops to 2 with them."""
        text = self.read(BAR)
        for signature in ('private func addButton(', 'private func removeButton(',
                          'private func presetsMenu(', 'private func recentreButton(',
                          'private func powerButton(', 'private func overflowMenu(',
                          'private func revertButton(', 'private var doneButton: some View'):
            with self.subTest(signature):
                block = body(text, signature)
                self.assertIsNotNone(block, signature + ' not found')
                self.assertIn('.lightsTouchTarget()', block)
        revert = body(text, 'private func revertButton(')
        self.assertEqual(revert.count('.lightsTouchTarget()'), 2, 'both Revert labels')
        chip = body(text, 'struct LightChipButton')
        self.assertIsNotNone(chip, 'LightChipButton not found')
        self.assertIn('.lightsTouchTarget(width: false)', chip)
        compact = body(text, 'private func compact(')
        self.assertIsNotNone(compact, 'the compact bar not found')
        self.assertIn('HStack(spacing: touchMinimum > 0 ? 2 : 10)', compact)

    def testInspectorControlsAndSwatches(self):
        """The header's menu, Shadow and Pin chips and chevron are 44 pt
        targets; on iOS the swatches are 44 pt targets in
        LightsTouch.swatchColumns columns and the custom picker has a 44 pt
        frame; macOS keeps its one-row 15 pt swatches. The chips are drawn
        by LightsChip (shared with the Atmosphere card's switch, #726); the
        inspector's chip() forwards to it. The Atmosphere card's chevron
        and Scatter disclosure are 44 pt targets and its rows at least
        44 pt tall."""
        text = self.read(INSPECTOR)
        for signature in ('private func lightMenu(', 'struct LightsChip', 'private func header('):
            with self.subTest(signature):
                block = body(text, signature)
                self.assertIsNotNone(block, signature + ' not found')
                self.assertIn('.lightsTouchTarget()', block)
        forwarder = body(text, 'private func chip(')
        self.assertIsNotNone(forwarder, 'the inspector\'s chip() not found')
        self.assertIn('LightsChip(', forwarder)
        card = self.read(ATMOSPHERE_CARD)
        header = body(card, 'private func header(')
        self.assertIsNotNone(header, 'the Atmosphere header not found')
        self.assertIn('LightsChip(', header)
        self.assertIn('.lightsTouchTarget()', header, 'the chevron')
        disclosure = body(card, 'private func scatterDisclosure(')
        self.assertIsNotNone(disclosure, 'the Scatter disclosure not found')
        self.assertIn('.lightsTouchTarget(width: false)', disclosure)
        row = body(card, 'struct AtmosphereSliderRow')
        self.assertIsNotNone(row, 'AtmosphereSliderRow not found')
        self.assertIn('.frame(minHeight: touchMinimum)', row)
        button = body(card, 'struct LightsSheetAtmosphereButton')
        self.assertIsNotNone(button, 'LightsSheetAtmosphereButton not found')
        self.assertIn('.lightsTouchTarget()', button)
        row = body(text, 'private func touchColourRow(')
        self.assertIsNotNone(row, 'touchColourRow not found')
        self.assertIn('LightsTouch.swatchColumns(width: colourWidth)', row)
        self.assertIn('target: LightsTouch.swatchTarget', row)
        self.assertIn('.frame(minWidth: touchMinimum, minHeight: touchMinimum)', row)
        colour = body(text, 'private func colourRow(')
        self.assertIsNotNone(colour, 'colourRow not found')
        self.assertIn('if touchMinimum > 0', colour)
        self.assertIn('swatchButton(swatch, dot: 15, padding: 2)', colour)

    # --- touch routing (Part 2) ------------------------------------------------

    def testTheTwoFingerRuleIsPure(self):
        """The first recognizer of a sequence decides: the gizmo's only with
        a span of at most 120 pt and a knob at the centroid; later kinds join
        the decided owner, and the sequence resets when all have ended. The
        deciders read the layout only (no controller, no Python)."""
        text = self.read(TOUCH)
        self.assertEqual(self.number(text, r'static let knobPinchMaxSpan: CGFloat = ([0-9.]+)',
                                     'knobPinchMaxSpan'), 120)
        began = body(text, 'mutating func began(_ kind: LightTwoFingerKind')
        self.assertIsNotNone(began, 'LightTwoFingerSequence.began not found')
        self.assertIn('if let owner {', began)
        self.assertIn('span <= LightTouchMetrics.knobPinchMaxSpan, let name = knob(centroid)', began)
        ended = body(text, 'mutating func ended(_ kind: LightTwoFingerKind)')
        self.assertIsNotNone(ended, 'LightTwoFingerSequence.ended not found')
        self.assertIn('if active.isEmpty { owner = nil }', ended)
        press = body(text, 'static func pressPoint(location: CGPoint, translation: CGPoint)')
        self.assertIsNotNone(press, 'pressPoint not found')
        self.assertIn('location.x - translation.x', press)
        self.assertIn('location.y - translation.y', press)
        point = body(text, 'static func isPointTarget(_ target: LightGizmoTarget)')
        self.assertIsNotNone(point, 'isPointTarget not found')
        self.assertIn('case .knob, .aimDot, .outerHandle, .innerHandle: return true', point)
        self.assertIn('case .outerRing, .innerRing, .rings: return false', point)
        self.assertNotRegex(text, r'\bcontroller\.', 'the deciders never touch the controller')
        self.assertNotRegex(text, r'\bengine\b', 'nor the engine')

    def testTheLongPressDelegateDeclinesOnlyPointTargets(self):
        """longPress.delegate is the coordinator; gestureRecognizerShouldBegin
        asks only about a long-press, and declines it only in Lights mode on
        a point target (LightTouchRouter.shouldBeginLongPress); every other
        recognizer begins. Simultaneous recognition is unchanged."""
        viewport = self.read(VIEWPORT)
        make = body(viewport, 'func makeUIView(context: Context) -> MTKView')
        self.assertIsNotNone(make, 'makeUIView not found')
        self.assertIn('longPress.delegate = context.coordinator', make)
        should = body(viewport, 'func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool')
        self.assertIsNotNone(should, 'gestureRecognizerShouldBegin not found')
        self.assertIn('guard g is UILongPressGestureRecognizer, let view = mtkView else { return true }',
                      should)
        self.assertIn('lightGizmoLongPressMayBegin(', should)
        may = body(viewport, 'private func lightGizmoLongPressMayBegin(')
        self.assertIsNotNone(may, 'lightGizmoLongPressMayBegin not found')
        self.assertIn('engine.interactionMode == .lights else { return true }', may)
        self.assertIn('LightTouchRouter.shouldBeginLongPress(', may)
        simultaneous = body(viewport, 'shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool')
        self.assertIsNotNone(simultaneous, 'shouldRecognizeSimultaneouslyWith not found')
        self.assertIn('return isTwoFinger(g) && isTwoFinger(other)', simultaneous)
        long_press = body(viewport, 'private func lightGizmoLongPress(')
        self.assertIsNotNone(long_press, 'lightGizmoLongPress not found')
        self.assertIn('LightTouchRouter.longPress(', long_press)
        self.assertIn('case .contextMenu:\n                return false', long_press)
        self.assertIn('interaction.placeHighlight(at: p, layout: layout)', long_press)

    def testTheKnobPinchOpensByName(self):
        """The iOS pinch opens the radius session on the knob the sequence
        named (LightGizmoInteraction.beginPinch(named:)), never by a second
        hit test, and its changes go through the owner-guarded pinch."""
        viewport = self.read(VIEWPORT)
        pinch = body(viewport, 'private func lightGizmoPinch(')
        self.assertIsNotNone(pinch, 'lightGizmoPinch not found')
        self.assertIn('lightGizmoTwoFinger(.pinch,', pinch)
        self.assertIn('interaction.beginPinch(named: name)', pinch)
        self.assertNotIn('beginPinch(at:', pinch)
        self.assertIn('interaction.pinch(&session, magnification: scale)', pinch)
        two = body(viewport, 'private func lightGizmoTwoFinger(')
        self.assertIsNotNone(two, 'lightGizmoTwoFinger not found')
        self.assertIn('lightTwoFinger.began(kind, centroid: centroid,', two)
        self.assertIn('LightGizmoHitTest.knob(at: p, layout: $0)', two)
        self.assertIn('lightTwoFinger.ended(kind)', two)
        pan = body(viewport, 'func handleTwoFingerPan(')
        self.assertIsNotNone(pan, 'handleTwoFingerPan not found')
        self.assertIn('LightTouchGeometry.pressPoint(location: loc, translation: gesture.translation(in: view))',
                      pan)
        model = self.read(GIZMO_MODEL)
        named = body(model, 'func beginPinch(named name: String) -> OrbitPinchSession?')
        self.assertIsNotNone(named, 'beginPinch(named:) not found')
        self.assertIn('LightsOrbitInteraction(controller: controller).beginPinch()', named)

    def testOptionTapPlacesAHighlight(self):
        """handleTap passes the option key to lightGizmoTap, which places a
        highlight only off every target (LightTouchRouter.optionTap); a tap
        on a target keeps #622's behaviour."""
        viewport = self.read(VIEWPORT)
        tap = body(viewport, 'func handleTap(_ gesture: UITapGestureRecognizer)')
        self.assertIsNotNone(tap, 'handleTap not found')
        self.assertIn('lightGizmoTap(at: p, option: gesture.modifierFlags.contains(.alternate), in: view)', tap)
        self.assertLess(tap.find('lightGizmoTap('), tap.find('engine.pick('))
        routine = body(viewport, 'private func lightGizmoTap(')
        self.assertIsNotNone(routine, 'lightGizmoTap not found')
        option = routine.find('LightTouchRouter.optionTap(at: p, layout: layout)')
        self.assertGreaterEqual(option, 0, 'the option branch')
        self.assertLess(option, routine.find('placeHighlight('))
        self.assertLess(option, routine.find('if case .knob(let name) = target'))

    def testMovePanGrabsWhereTheFingerCameDown(self):
        """#702: Move mode's one-finger pan hit-tests and begins its handle
        drag at the touch-down point (location - translation), not where
        UIKit's slop let .began fire; the camera branch is unchanged."""
        viewport = self.read(VIEWPORT)
        move = body(viewport, 'private func handleMovePan(')
        self.assertIsNotNone(move, 'handleMovePan not found')
        began = move[move.find('case .began:'):move.find('case .changed:')]
        press = began.find('LightTouchGeometry.pressPoint(location: location,')
        self.assertGreaterEqual(press, 0, 'no touch-down point in .began')
        self.assertLess(press, began.find('hitTest(ndc: CGPoint(x: CGFloat(px), y: CGFloat(py))'))
        self.assertIn('engine.gizmoBeginDrag(hnd, ndcX: px, ndcY: py, aspect: aspect)', began)
        self.assertIn('engine.button(PYMOL_BUTTON_LEFT, state: PYMOL_BUTTON_DOWN, x: pt.0, y: pt.1, '
                      'modifiers: 0)', began)
        pan = body(viewport, 'private func lightGizmoPan(')
        self.assertIsNotNone(pan, 'lightGizmoPan not found')
        self.assertIn('LightTouchGeometry.pressPoint(location: location,', pan)

    # --- the docked tools (Part 3) -------------------------------------------

    def testPlacementBySizeClass(self):
        """Compact height docks the tools in the side panel (iPhone
        landscape, the large phones too), then compact width gives the
        bottom sheet, else the iPad float; never by device idiom."""
        text = self.read(SHEET)
        resolve = body(text, 'static func resolve(compactWidth: Bool, compactHeight: Bool)')
        self.assertIsNotNone(resolve, 'LightsToolsPlacement.resolve not found')
        side = resolve.find('if compactHeight { return .sidePanel }')
        sheet = resolve.find('if compactWidth { return .bottomSheet }')
        self.assertGreaterEqual(side, 0)
        self.assertGreater(sheet, side, 'compact height decides first')
        self.assertIn('return .floating', resolve)
        self.assertNotIn('userInterfaceIdiom', text)

    def testTheSheetMetricsAndHeightRule(self):
        """The scene keeps 180 pt; the compact body is 164 pt; the pinned
        plan is 120 to 194 pt beside a 58 to 98 pt arc; expanded is
        max(compact, min(room - 180, content)) and compact is clamped to
        room - 180."""
        text = self.read(SHEET)
        metrics = body(text, 'enum LightsSheetMetrics')
        self.assertIsNotNone(metrics, 'LightsSheetMetrics not found')
        for name, value in (('grabberStrip', 24), ('minimumHeader', 44), ('compactBody', 164),
                            ('compactPlanSide', 164), ('minimumScene', 180), ('minimumRows', 150),
                            ('snapDistance', 40), ('flingDistance', 120), ('keyboardRows', 96),
                            ('colourButtonHeight', 44)):
            with self.subTest(name):
                self.assertEqual(self.number(metrics, r'static let %s: CGFloat = ([0-9.]+)' % name, name),
                                 value)
        self.assertIn('static let pinnedPlanSide: ClosedRange<CGFloat> = 120...194', metrics)
        self.assertIn('static let arcWidth: ClosedRange<CGFloat> = 58...98', metrics)
        layout = body(text, 'static func layout(room: CGFloat, header: CGFloat, bottomInset: CGFloat,')
        self.assertIsNotNone(layout, 'LightsSheetModel.layout not found')
        self.assertIn('let most = room - M.minimumScene', layout)
        self.assertIn('let compact = max(least, min(content, most))', layout)
        self.assertIn('let expanded = max(compact, min(most, expandedContent))', layout)

    def testTheGrabberDragIsCancelSafe(self):
        """The drag's translation is @GestureState (SwiftUI resets it on end
        and on cancel), the drag only moves the drawn sheet over a slot of
        the committed height, and a release snaps once, telling the owner
        before and after (the drawable freeze covers only the snap)."""
        text = self.read(SHEET)
        self.assertRegex(text, r'@GestureState\([^)]*resetTransaction[^@]*private var dragTranslation: CGFloat = 0')
        self.assertIn('.updating($dragTranslation)', text)
        self.assertIn('LightsSheetModel.dragFrame(detent: detent, translation: dragTranslation, heights: heights)',
                      text)
        self.assertIn('.frame(height: frame.slot, alignment: .bottom)', text)
        snap = body(text, 'private func setDetent(_ next: LightsSheetDetent)')
        self.assertIsNotNone(snap, 'setDetent not found')
        before = snap.find('onMoving(true)')
        animate = snap.find('withAnimation(')
        after = snap.find('onMoving(false)')
        self.assertGreaterEqual(before, 0)
        self.assertGreater(animate, before)
        self.assertGreater(after, animate, 'the freeze ends in the completion')
        self.assertIn('} completion: {', snap)
        disappear = text[text.find('.onDisappear {'):]
        self.assertIn('onMoving(false)', disappear[:400], 'the safety reset on disappear')

    def testTheSheetWritesOnlyThroughTheTypedAPI(self):
        """The compact sliders write setIfChanged and the swatches and
        picker setColour (the bridge setters); the canvases write through
        OrbitCanvases (LightsOrbitInteraction). No raw set, step, Python or
        bridge call."""
        text = self.read(SHEET)
        rows = body(text, 'struct LightsCompactRows: View')
        self.assertIsNotNone(rows, 'LightsCompactRows not found')
        self.assertIn('controller.setIfChanged(', rows)
        self.assertIn('@ObservedObject var eye: LightsEyeState', rows)
        palette = body(text, 'struct LightsColourPalette: View')
        self.assertIsNotNone(palette, 'LightsColourPalette not found')
        self.assertEqual(palette.count('controller.setColour('), 2, 'the swatches and the picker')
        writes = set(re.findall(r'controller\.(\w+)\(', text))
        self.assertLessEqual(writes, {'setIfChanged', 'setColour'}, writes)
        for name in ('controller.set(', 'controller.step(', 'beginGesture(', 'runPython', 'PyMOLBridge_'):
            with self.subTest(name):
                self.assertNotIn(name, text)

    def testOnlyTheRowsScroll(self):
        """Expanded: the plan and the arc are pinned above the ScrollView
        that holds the inspector's rows, so the canvases' drags and pinch
        never fight a scroll; the compact body scrolls only when its height
        is clamped."""
        text = self.read(SHEET)
        expanded = body(text, 'private func expandedBody(')
        self.assertIsNotNone(expanded, 'expandedBody not found')
        canvases = expanded.find('OrbitCanvases(')
        scroll = expanded.find('ScrollView(.vertical)')
        self.assertGreaterEqual(canvases, 0)
        self.assertGreater(scroll, canvases)
        self.assertEqual(expanded.count('OrbitCanvases('), 1)
        self.assertIn('presentation: .rows', expanded[scroll:])
        self.assertIn('planSize: canvases.planSize, arcSize: canvases.arcSize', expanded)
        compact = body(text, 'private var compactBody: some View')
        self.assertIsNotNone(compact, 'compactBody not found')
        self.assertIn('showsArc: false', compact)
        self.assertIn('.scrollDisabled(!heights.compactScrolls)', compact)

    def testTheSheetsTargets(self):
        """More/Less is a 44 pt target; the Colour button is 44 pt tall; the
        palette's swatches and picker are 44 pt targets; the grabber is an
        adjustable VoiceOver element."""
        text = self.read(SHEET)
        more = body(text, 'private var moreButton: some View')
        self.assertIsNotNone(more, 'moreButton not found')
        self.assertIn('.lightsTouchTarget()', more)
        colour = body(text, 'private var colourButton: some View')
        self.assertIsNotNone(colour, 'colourButton not found')
        self.assertIn('minHeight: M.colourButtonHeight', colour)
        self.assertIn('.presentationCompactAdaptation(.popover)', colour)
        palette = body(text, 'struct LightsColourPalette: View')
        self.assertIn('.frame(width: LightsTouch.swatchTarget, height: LightsTouch.swatchTarget)', palette)
        self.assertIn('.frame(minWidth: LightsTouch.swatchTarget, minHeight: LightsTouch.swatchTarget)', palette)
        grabber = body(text, 'private var grabber: some View')
        self.assertIsNotNone(grabber, 'grabber not found')
        self.assertIn('.accessibilityAdjustableAction', grabber)
        self.assertIn('.accessibilityIdentifier(LightsSheetState.grabberIdentifier)', grabber)
        # The header's Atmosphere button (#726; a 44 pt target, checked in
        # testInspectorControlsAndSwatches): it expands a compact sheet, then
        # asks the rows to scroll to the Atmosphere section.
        header = body(text, 'private var headerRow: some View')
        self.assertIsNotNone(header, 'headerRow not found')
        self.assertIn('LightsSheetAtmosphereButton(controller: controller, style: style) { revealAtmosphere() }',
                      header)
        self.assertLess(header.find('LightsSheetAtmosphereButton('), header.find('moreButton'),
                        'the Atmosphere button sits before More')
        reveal = body(text, 'private func revealAtmosphere()')
        self.assertIsNotNone(reveal, 'revealAtmosphere not found')
        self.assertIn('if placement == .bottom, detent == .compact { setDetent(.expanded) }', reveal)
        self.assertIn('atmosphereRequest += 1', reveal)

    def testTheKeyboardReaderIsIOSOnly(self):
        """The keyboard's frame notifications are read under #if os(iOS)
        only; UIKit is imported only there."""
        text = self.read(SHEET)
        reader = body(text, 'struct LightsKeyboardTopReader: ViewModifier')
        self.assertIsNotNone(reader, 'LightsKeyboardTopReader not found')
        ios = reader.find('#if os(iOS)')
        notification = reader.find('keyboardWillChangeFrameNotification')
        self.assertGreaterEqual(ios, 0)
        self.assertGreater(notification, ios)
        self.assertRegex(text, r'#if os\(iOS\)\s*import UIKit\s*#endif')
        outside = re.sub(r'#if os\(iOS\).*?#(?:else|endif)', '', text, flags=re.S)
        self.assertNotIn('UIResponder', outside)
        self.assertNotIn('UIApplication', outside)

    def testTheSharedViewsTakeTheSheetsOptions(self):
        """OrbitCanvases takes planSize, arcSize and showsArc (the card's
        sizes by default) and lays out, draws and hit-tests at them; the
        inspector has the card, header and rows presentations (the header
        keeps the notice and the hint, the card keeps its chevron); the
        Orbit and Pitch fields report their focus; the orbit DEBUG gestures
        take the placement's sizes."""
        view = self.read(ORBIT_VIEW)
        canvases = body(view, 'struct OrbitCanvases: View')
        self.assertIsNotNone(canvases, 'OrbitCanvases not found')
        self.assertIn('planSize: CGSize = LightsOrbitMetrics.planSize', canvases)
        self.assertIn('arcSize: CGSize = LightsOrbitMetrics.arcSize', canvases)
        self.assertIn('showsArc: Bool = true', canvases)
        self.assertIn('OrbitCanvas(size: planSize)', canvases)
        self.assertIn('OrbitCanvas(size: arcSize)', canvases)
        self.assertIn('PitchArcLayout(size: arcSize, slop: slop)', canvases)
        self.assertIn('slop: slop, size: planSize)', canvases)
        self.assertNotIn('OrbitCanvas(size: LightsOrbitMetrics.', canvases)
        inspector = self.read(INSPECTOR)
        self.assertRegex(inspector, r'enum LightsInspectorPresentation: Equatable \{\s*case card, header, rows')
        header = body(inspector, 'private func headerBlock(')
        self.assertIsNotNone(header, 'headerBlock not found')
        self.assertIn('header(state, showsChevron: false)', header)
        self.assertIn('noticeRow(notice)', header)
        self.assertIn('shadowsHintRow(state)', header)
        card = body(inspector, 'private func card(')
        self.assertIn('header(state, showsChevron: true)', card)
        field = body(inspector, 'struct LightAngleFieldRow: View')
        self.assertIsNotNone(field, 'LightAngleFieldRow not found')
        self.assertIn('.preference(key: LightsFieldFocusKey.self, value: focused)', field)
        model = self.read(ORBIT_MODEL)
        apply = body(model, 'static func apply(_ gesture: OrbitAutoGesture')
        self.assertIsNotNone(apply, 'OrbitAutoGesture.apply not found')
        self.assertIn('OrbitPlanLayout(size: planSize, extent: state.extent, slop: slop)', apply)
        self.assertIn('PitchArcLayout(size: arcSize, slop: slop)', apply)

    # --- the phone wiring (Part 4) -------------------------------------------

    def testThePortraitViewportKeepsOnePosition(self):
        """iPhoneLayout puts the viewport and the bottom region in one
        unconditional GeometryReader, the sheet first in the bottom region
        while docked (Theme Studio and the inspector after it), with the
        parked tongue hidden meanwhile; a DEBUG line counts the MTKViews
        made, so a simulator log shows one per launch."""
        content = self.read(CONTENT_VIEW)
        phone = body(content, 'private func iPhoneLayout(geo: GeometryProxy)')
        self.assertIsNotNone(phone, 'iPhoneLayout not found')
        self.assertEqual(phone.count('viewportView'), 1)
        self.assertRegex(phone, r'GeometryReader\s*\{\s*lower\s+in\s*VStack\(spacing:\s*0\)\s*\{\s*'
                                r'viewportView\b')
        wrapper = phone.find('GeometryReader { lower in')
        self.assertNotRegex(phone[:wrapper], r'if[^{\n]*\{\s*$', 'the wrapper is unconditional')
        sheet = phone.find('if phoneLightsDocked {')
        studio = phone.find('} else if showThemeStudio {')
        inspector = phone.find('} else if showObjectPanel {')
        self.assertGreater(sheet, wrapper)
        self.assertGreater(studio, sheet)
        self.assertGreater(inspector, studio)
        self.assertIn('!showObjectPanel && !phoneLightsDocked', phone, 'the parked tongue hides')
        tongue = body(content, 'private var bottomTongueShown: Bool')
        self.assertIsNotNone(tongue, 'bottomTongueShown not found')
        self.assertIn('!phoneLightsDocked', tongue)
        viewport = self.read(VIEWPORT)
        make = body(viewport, 'func makeUIView(context: Context) -> MTKView')
        self.assertIsNotNone(make, 'makeUIView not found')
        debug = make.find('#if DEBUG')
        self.assertGreaterEqual(debug, 0)
        self.assertGreater(make.find('NSLog("MetalViewport: makeUIView n='), debug)

    def testThePanesGiveWayWithoutWritingTheirFlags(self):
        """Phone portrait Lights mode hides the console and the sequence
        strip through the effective bindings (LightsPaneRule), which
        iPhoneLayout and the rail's pills read; only the bindings' setters
        (a pill tap) write the stored flags, and the mode's resets write
        only the overrides."""
        content = self.read(CONTENT_VIEW)
        for name, flag, override in (('consoleBinding', 'showCommandPanel', 'lightsShowsConsole'),
                                     ('sequenceBinding', 'engine.sequenceVisible', 'lightsShowsSequence')):
            with self.subTest(name):
                binding = body(content, 'private var %s: Binding<Bool>' % name)
                self.assertIsNotNone(binding, '%s not found' % name)
                self.assertIn('if phoneLightsDocked {', binding)
                self.assertIn('LightsPaneRule.shows(stored: %s' % flag, binding)
                self.assertIn('set: { %s = $0; %s = $0 }' % (override, flag), binding)
        phone = body(content, 'private func iPhoneLayout(geo: GeometryProxy)')
        self.assertIn('let cTerm = consoleBinding.wrappedValue && !iosFullScreen', phone)
        self.assertIn('let showSequence = sequenceBinding.wrappedValue', phone)
        self.assertNotIn('engine.sequenceVisible', phone)
        rail = body(content, 'private func topPaneRail(')
        self.assertIsNotNone(rail, 'topPaneRail not found')
        self.assertIn('shown: consoleBinding', rail)
        self.assertIn('shown: sequenceBinding', rail)
        for signature in ('private func lightsModeChanged(', 'private func endLightsSheetMotion()',
                          'private func observingLightsLayout<', 'private func autoEnterLightsModeFromEnv()'):
            with self.subTest(signature):
                text = body(content, signature)
                self.assertIsNotNone(text, '%s not found' % signature)
                self.assertNotRegex(text, r'showCommandPanel\s*=[^=]')
                self.assertNotRegex(text, r'sequenceVisible\s*=[^=]')
        reset = body(content, 'private func lightsModeChanged(')
        self.assertIn('lightsShowsConsole = false', reset)
        self.assertIn('lightsShowsSequence = false', reset)
        self.assertIn("lightsSheetDetent = mode == .lights ? lightsSheetSeed : .compact", reset)
        seed = body(content, 'private var lightsSheetSeed: LightsSheetDetent')
        # The DEBUG `expand` and (#726) `air` tokens seed it expanded.
        self.assertIn('lightsInspectorExpandOverride || lightsAtmosphereExpandOverride ? .expanded : .compact',
                      seed)
        rule = body(self.read(SHEET), 'static func shows(stored: Bool, override: Bool, docked: Bool)')
        self.assertIsNotNone(rule, 'LightsPaneRule.shows not found')
        self.assertIn('stored && (!docked || override)', rule)

    def testTheSidePanelTakesBothLandscapeSlots(self):
        """On compact height the tools take the trailing slot of
        iPhoneLandscapeLayout and the right column of iPadMacStyleLayout's
        landscape branch (the large phones), whatever the Objects toggle
        says, with the vertical tongue hidden meanwhile."""
        content = self.read(CONTENT_VIEW)
        shown = body(content, 'private var lightsSidePanelShown: Bool')
        self.assertIsNotNone(shown, 'lightsSidePanelShown not found')
        self.assertIn('lightsPlacement == .sidePanel', shown)
        land = body(content, 'private func iPhoneLandscapeLayout(geo: GeometryProxy)')
        self.assertIsNotNone(land, 'iPhoneLandscapeLayout not found')
        self.assertIn('(lightsSidePanelShown || showThemeStudio || objectsBinding.wrappedValue)', land)
        self.assertLess(land.find('if lightsSidePanelShown {'), land.find('} else if showThemeStudio {'))
        self.assertIn('!objectsBinding.wrappedValue && !lightsSidePanelShown', land)
        pad = body(content, 'private func iPadMacStyleLayout(geo: GeometryProxy)')
        self.assertIsNotNone(pad, 'iPadMacStyleLayout not found')
        landscape = pad[:pad.find('} else {')]
        self.assertLess(landscape.find('if lightsSidePanelShown {'), landscape.find('} else if showThemeStudio {'))
        self.assertIn('!showRight && !lightsSidePanelShown', landscape)

    def testTheDrawableFreezesOnlyForTheSnap(self):
        """The sheet's onMoving sets the drawable freeze and the gizmo fade
        together and only on a change; leaving the mode, a placement change
        and the sheet's onDisappear (LightsSheet) reset them."""
        content = self.read(CONTENT_VIEW)
        moving = body(content, 'private func setLightsSheetMoving(_ moving: Bool)')
        self.assertIsNotNone(moving, 'setLightsSheetMoving not found')
        self.assertIn('guard moving != lightsSheetMoving else { return }', moving)
        self.assertIn('engine.suppressDrawableResize = moving', moving)
        sheet = body(content, 'private func lightsSheet(room: CGSize)')
        self.assertIsNotNone(sheet, 'lightsSheet not found')
        self.assertIn('onMoving: { setLightsSheetMoving($0) }', sheet)
        self.assertIn('heights: lightsSheetHeights(room: room)', sheet)
        end = body(content, 'private func endLightsSheetMotion()')
        self.assertIn('setLightsSheetMoving(false)', end)
        self.assertIn('endLightsSheetMotion()', body(content, 'private func lightsModeChanged('))
        observers = body(content, 'private func observingLightsLayout<')
        self.assertIn('.onChange(of: engine.interactionMode) { _, mode in lightsModeChanged(mode) }', observers)
        placement = observers[observers.find('.onChange(of: lightsPlacement, initial: true)'):]
        self.assertGreater(len(placement), 0, 'the placement observer is missing')
        self.assertIn('lightsPlacementSeen = placement', placement[:300])
        self.assertIn('if old != placement { endLightsSheetMotion() }', placement[:300])
        self.assertIn('observingLightsLayout(Group {', content)
        gizmo = body(content, 'private var lightGizmoOverlay: some View')
        self.assertIn('.opacity(lightsSheetMoving ? 0 : 1)', gizmo)
        self.assertEqual(len(re.findall(r'engine\.suppressDrawableResize\s*=\s*moving', content)), 1)

    def testAFocusedLightFieldKeepsTheViewport(self):
        """While an Orbit or Pitch field of the sheet or the side panel has
        the keyboard, the viewport-plus-tools container of each phone layout
        ignores it (an unconditional modifier with a dynamic argument); only
        the tools' onFieldFocus sets the flag (the iPad card's fields keep
        today's keyboard avoidance)."""
        content = self.read(CONTENT_VIEW)
        rule = '.ignoresSafeArea(lightsFieldFocused ? .keyboard : [], edges: .bottom)'
        self.assertEqual(content.count(rule), 3)
        for signature in ('private func iPhoneLayout(geo: GeometryProxy)',
                          'private func iPhoneLandscapeLayout(geo: GeometryProxy)',
                          'private func iPadMacStyleLayout(geo: GeometryProxy)'):
            with self.subTest(signature):
                self.assertIn(rule, body(content, signature))
        self.assertEqual(content.count('onFieldFocus: { lightsFieldFocused = $0 }'), 2)
        self.assertNotIn('onPreferenceChange(LightsFieldFocusKey', content)
        self.assertIn('if lightsFieldFocused { lightsFieldFocused = false }',
                      body(content, 'private func endLightsSheetMotion()'))

    def testThePhoneLogLines(self):
        """A DEBUG LightsLayout line names the tools, the scene, the sheet's
        slot, the panes and the touch floor on each change (iOS only), and
        the orbit DEBUG tokens lay out at the active placement's canvases."""
        content = self.read(CONTENT_VIEW)
        log = body(content, 'private func logLightsLayout(')
        self.assertIsNotNone(log, 'logLightsLayout not found')
        for field in ('LightsLayout: tools=', ' scene=', ' sheet=', ' panes=', ' touch='):
            with self.subTest(field):
                self.assertIn(field, log)
        guard = content.rfind('#if os(iOS) && DEBUG', 0, content.find('private func logLightsLayout('))
        self.assertGreaterEqual(guard, 0)
        self.assertIn('observed.onChange(of: lightsLayoutLogKey)', content)
        sizes = body(content, 'private var lightsOrbitSizes: (plan: CGSize, arc: CGSize)')
        self.assertIsNotNone(sizes, 'lightsOrbitSizes not found')
        self.assertIn('LightsSheetModel.activeCanvases(placement: lightsLivePlacement', sizes)
        # The hook's delayed closures read the placement from State (a
        # captured copy keeps stale size classes).
        live = body(content, 'private var lightsLivePlacement: LightsToolsPlacement')
        self.assertIsNotNone(live, 'lightsLivePlacement not found')
        self.assertIn('return lightsPlacementSeen', live)

    # --- the iPad float (Part 5) ----------------------------------------------

    def testTheGripIsACancelSafeTarget(self):
        """The orbit card's header row (up to its chevron) is the grip: a
        44 pt target carrying the float's drag. The drag's offset is
        @GestureState with an animated reset (a cancel leaves nothing
        behind), measured in the float's own space, and only onEnded picks
        the corner (one snap, LightsFloatLayout.dropCorner on the predicted
        end). The grip's capsule is the VoiceOver element with the move
        actions."""
        text = self.read(FLOAT)
        view = body(text, 'struct LightsFloatingTools: View')
        self.assertIsNotNone(view, 'LightsFloatingTools not found')
        self.assertRegex(view, r'@GestureState\(resetTransaction:[^@]*private var dragOffset: CGSize = \.zero')
        self.assertIn('.updating($dragOffset)', view)
        self.assertIn('coordinateSpace: .named(Self.space)', view)
        self.assertIn('.coordinateSpace(name: Self.space)', view)
        self.assertIn('minimumDistance: LightsFloatMetrics.gripMinimumDistance', view)
        self.assertEqual(self.number(text, r'static let gripMinimumDistance:\s*CGFloat\s*=\s*([0-9.]+)',
                                     'gripMinimumDistance'), 6)
        ended = view[view.find('.onEnded'):]
        self.assertIn('LightsFloatLayout.dropCorner(cardFrame: cardFrame, translation: value.translation,',
                      ended[:400])
        self.assertIn('predicted: value.predictedEndTranslation', ended[:400])
        self.assertNotIn('onChanged', view, 'no drag state outside @GestureState')
        # The card's frame is read outside the drag's offset, so it is the
        # laid-out frame (never per tick) and the drop counts the drag once.
        # A reader applied before `.offset` sits inside it and reports the
        # dragged frame (LightsFloatCardFrameTests pins the behaviour).
        card = view[view.find('LightsOrbitView(controller: controller'):]
        self.assertIn('.lightsFloatCard(offset: dragOffset, space: Self.space)', card[:300])
        self.assertNotIn('.offset(dragOffset)', view)
        modifier = body(text, 'func lightsFloatCard(offset: CGSize, space: String) -> some View')
        self.assertIsNotNone(modifier, 'lightsFloatCard(offset:space:) not found')
        self.assertLess(modifier.find('self.offset(offset)'), modifier.find('LightsFloatFramesKey'))
        orbit = self.read(ORBIT_VIEW)
        region = body(orbit, 'private struct OrbitGripRegion: ViewModifier')
        self.assertIsNotNone(region, 'OrbitGripRegion not found')
        self.assertIn('.lightsTouchTarget(width: false)', region)
        self.assertIn('.gesture(grip.gesture)', region)
        header = body(orbit, 'private func header(_ state: LightsOrbitState)')
        self.assertLess(header.find('.modifier(OrbitGripRegion(grip: grip))'), header.find('collapseButton'),
                        'the chevron keeps its tap, outside the grip')
        handle = body(orbit, 'private func gripHandle(_ grip: LightsOrbitGrip)')
        self.assertIsNotNone(handle, 'gripHandle not found')
        for needle in ('.accessibilityIdentifier(grip.identifier)', '.accessibilityValue(grip.value)',
                       '.accessibilityActions', '.allowsHitTesting(false)'):
            with self.subTest(needle):
                self.assertIn(needle, handle)

    def testTheFloatWritesOnlyThroughTheCards(self):
        """The float file writes nothing itself: no controller call, raw set,
        gesture session, Python or bridge function; the cards' own paths
        (LightsOrbitInteraction, the inspector's typed API) do the edits."""
        text = self.read(FLOAT)
        self.assertEqual(set(re.findall(r'controller\.(\w+)\(', text)), set())
        for name in ('beginGesture(', 'runPython', 'runCommand', 'PyMOLBridge_', 'UserDefaults'):
            with self.subTest(name):
                self.assertNotIn(name, text)

    def testTheCornerIsRemembered(self):
        """PanelLayout.lightsOrbitCornerKey is in allKeys; ContentView keeps
        the corner in @AppStorage (bottom-leading by default), and the DEBUG
        `corner:` token overrides it for one run without storing it."""
        panels = self.read(PANEL_LAYOUT)
        self.assertIn('static let lightsOrbitCornerKey = ns + "lightsOrbitCorner"', panels)
        start = panels.find('static let allKeys: [String] = [')
        self.assertGreaterEqual(start, 0, 'allKeys not found')
        all_keys = panels[start + len('static let allKeys: [String] = ['):panels.find(']', start + 40)]
        self.assertIn('lightsOrbitCornerKey', all_keys)
        text = self.read(FLOAT)
        self.assertIn('static let `default`: LightsFloatCorner = .bottomLeading', text)
        for raw in ('"tl"', '"tr"', '"bl"', '"br"'):
            with self.subTest(raw):
                self.assertIn(raw, text)
        content = self.read(CONTENT_VIEW)
        self.assertRegex(content, r'@AppStorage\(PanelLayout\.lightsOrbitCornerKey\)\s+private var '
                                  r'lightsOrbitCornerStored\s*=\s*LightsFloatCorner\.default\.rawValue')
        binding = body(content, 'private var lightsOrbitCornerBinding: Binding<LightsFloatCorner>')
        self.assertIsNotNone(binding, 'lightsOrbitCornerBinding not found')
        self.assertIn('lightsOrbitCornerOverride = corner', binding)
        self.assertIn('lightsOrbitCornerStored = corner.rawValue', binding)
        hook = body(content, 'private func autoEnterLightsModeFromEnv()')
        self.assertIn('if let corner = edits.corner { lightsOrbitCornerOverride = corner }', hook)

    def testTheFloatClearsTheBottomChrome(self):
        """The bottom-leading chrome and the CameraDock report their heights
        (ViewportChromeHeightsKey) at the viewport's overlay sites; the
        viewport reads them into the float's clearances; the trailing side
        clears the help button or the dock, the leading side the chrome
        plus a gap or the dock."""
        content = self.read(CONTENT_VIEW)
        viewport = body(content, 'private var viewportView')
        self.assertIsNotNone(viewport, 'viewportView not found')
        chrome = viewport.find('bottomLeadingViewportChrome')
        self.assertGreaterEqual(chrome, 0)
        self.assertIn('.reportsViewportChrome(\\.bottomLeading, shown: bottomLeadingChromeShown)',
                      viewport[chrome:chrome + 500])
        dock = viewport.find('CameraDock(engine: engine')
        self.assertGreaterEqual(dock, 0)
        self.assertIn('.reportsViewportChrome(\\.dock)', viewport[dock:dock + 500])
        self.assertIn('.onPreferenceChange(ViewportChromeHeightsKey.self)', viewport)
        self.assertLess(viewport.find('.onPreferenceChange(ViewportChromeHeightsKey.self)'),
                        viewport.find('lightsFloatingTools'))
        site = body(content, 'private var lightsFloatingTools: some View')
        self.assertIsNotNone(site, 'lightsFloatingTools not found')
        self.assertIn('chrome: viewportChrome', site)
        self.assertIn('corner: lightsOrbitCornerBinding', site)
        text = self.read(FLOAT)
        rule = body(text, 'static func bottomClearance(trailing: Bool, chrome: ViewportChromeHeights)')
        self.assertIsNotNone(rule, 'bottomClearance not found')
        self.assertIn('max(LightsFloatMetrics.helpButtonClearance, chrome.dock)', rule)
        self.assertIn('chrome.bottomLeading + LightsFloatMetrics.chromeGap', rule)
        self.assertIn('max(leading, chrome.dock)', rule)

    def testTheFloatReplacesTheIOSColumn(self):
        """viewportView shows the float, for the float placement only, after
        the gizmo site (the cards draw above the gizmo); the side column is
        macOS-only; the iPad inspector starts collapsed; the old iPhone
        seeds and the column's inset are gone."""
        content = self.read(CONTENT_VIEW)
        viewport = body(content, 'private var viewportView')
        gizmo = viewport.find('.overlay { if engine.interactionMode == .lights { lightGizmoOverlay } }')
        self.assertGreaterEqual(gizmo, 0)
        self.assertRegex(viewport, r'lightsPlacement\s*==\s*\.floating\s*\{\s*lightsFloatingTools\s*\}')
        self.assertGreater(viewport.find('lightsFloatingTools'), gizmo)
        self.assertNotIn('lightsSideColumn', viewport)
        for gone in ('lightsOrbitStartsCollapsed', 'lightsSideColumnBottomInset',
                     'LightsSideColumn.helpButtonClearance'):
            with self.subTest(gone):
                self.assertNotIn(gone, content)
        seed = body(content, 'private var lightsInspectorStartsCollapsed: Bool')
        self.assertIn('lightsPlacement == .floating && !lightsInspectorExpandOverride', seed)

    def testTheFloatLogLines(self):
        """The DEBUG LightsLayout line names the knobs under the float's
        cards (covered=, LightsFloatLayout.coveredKnobs at the gizmo's
        layout) and tools= names the float's corner (float:<corner>)."""
        content = self.read(CONTENT_VIEW)
        log = body(content, 'private func logLightsLayout(')
        self.assertIn(' covered=\\(LightsFloatLayout.coveredSummary(covered))', log)
        self.assertIn('LightsFloatLayout.coveredKnobs(layout: engine.lightGizmoLayout(viewSize: scene)', log)
        key = body(content, 'private var lightsLayoutLogKey: LightsLayoutLogKey?')
        self.assertIn('corner: lightsOrbitCorner', key)
        self.assertIn('if lightsPlacement == .floating {', key)
        sheet = self.read(SHEET)
        summary = body(sheet, 'static func toolsSummary(placement: LightsToolsPlacement')
        self.assertIn('case .floating: return "float:\\(corner.rawValue)"', summary)

    # --- calibration support (Part 6) --------------------------------------

    def testTheCalibrationSwitchesStayOutOfDraw(self):
        """AirRedrawGate keeps defaultFPS 30 (no default change); the two
        launch switches are read only through fps(environment:) and
        logEnabled(environment:); draw(in:) and the viewport's other code
        never name them, the hold reason or the hold log."""
        text = self.read(VIEWPORT)
        gate = body(text, 'enum AirRedrawGate')
        self.assertIsNotNone(gate, 'AirRedrawGate not found')
        self.assertEqual(self.number(gate, r'static let defaultFPS: Double = ([0-9.]+)',
                                     'defaultFPS'), 30.0)
        for switch, reader in (('"RAYMOL_AIR_FPS"', 'static func fps(environment:'),
                               ('"RAYMOL_AIR_LOG"', 'static func logEnabled(environment:')):
            with self.subTest(switch):
                self.assertEqual(text.count(switch), 1, 'one read of ' + switch)
                self.assertIn(switch, body(gate, reader))
        draw = body(text, 'func draw(in view: MTKView)')
        self.assertIsNotNone(draw, 'draw(in:) not found')
        for name in ('RAYMOL_AIR', 'activeFPS', 'logsHolds', 'holdReason', 'noteAirHold',
                     'holdLine', 'lastAirHold', 'ProcessInfo'):
            with self.subTest(name):
                self.assertNotIn(name, draw)
        self.assertEqual(text.count('noteAirHold('), 2, 'declared once and called once')

    # --- real-recognizer UI tests (Part 7) ----------------------------------

    def testTheUITestHooksExistOnlyUnderTheSwitch(self):
        """LightsUITestProbe.enabled is PYMOL_UITEST == "1"; the probe is
        built only inside the PYMOL_UITEST overlay and only in Lights mode;
        the viewport's identifier comes from a modifier that leaves the
        viewport untouched when the switch is off; the probe only reads (no
        Python, no light write, no camera write)."""
        content = self.read(CONTENT_VIEW)
        probe = body(content, 'struct LightsUITestProbe: View')
        self.assertIsNotNone(probe, 'LightsUITestProbe not found')
        self.assertIn('static let enabled = ProcessInfo.processInfo.environment["PYMOL_UITEST"] == "1"',
                      probe)
        self.assertIn('static let identifier = "lightsProbe"', probe)
        self.assertIn('static let viewportIdentifier = "raymol.viewport"', probe)
        self.assertIn('TimelineView(.periodic(', probe)
        for write in ('runPython', 'perform(', '.set(', 'setPlacement', 'setColour', 'restoreView',
                      'PyMOLBridge_Set', 'select(name'):
            with self.subTest(write):
                self.assertNotIn(write, probe)
        modifier = body(content, 'struct LightsUITestViewportIdentifier: ViewModifier')
        self.assertIsNotNone(modifier, 'the viewport identifier modifier not found')
        self.assertIn('var enabled: Bool = LightsUITestProbe.enabled', modifier)
        self.assertRegex(modifier, r'if enabled \{\s*content\s*\.accessibilityElement\(children: \.ignore\)'
                                   r'\s*\.accessibilityIdentifier\(LightsUITestProbe\.viewportIdentifier\)'
                                   r'\s*\} else \{\s*content\s*\}')
        viewport = body(content, 'private var viewportView: some View')
        self.assertRegex(viewport, r'MetalViewport\(\)\s*\.modifier\(LightsUITestViewportIdentifier\(\)\)')
        at = viewport.find('if ProcessInfo.processInfo.environment["PYMOL_UITEST"] == "1" {')
        self.assertGreaterEqual(at, 0, 'the PYMOL_UITEST overlay not found')
        hook = viewport[at:]
        site = hook.find('LightsUITestProbe(controller: engine.lightsController')
        self.assertGreater(site, 0, 'the probe is not inside the PYMOL_UITEST overlay')
        self.assertIn('if LightsUITestProbe.enabled && engine.interactionMode == .lights {', hook[:site])
        self.assertEqual(content.count('LightsUITestProbe(controller:'), 1, 'one probe site')
        self.assertEqual(content.count('LightsUITestViewportIdentifier()'), 1, 'one viewport site')

    def testTheUITestsCoverEveryGesture(self):
        """LightsGestureUITests runs the off-target camera gestures, the knob
        pinch and press-hold-drag, the iPhone grabber and the iPad grip,
        reads the probe and the viewport by identifier, and skips (with the
        reason) when a knob is unreachable instead of passing silently."""
        text = self.read(UI_TESTS)
        for name in ('testOffTargetDragRotates', 'testOffTargetPinchZooms', 'testOffTargetTwistRolls',
                     'testKnobPinchChangesOnlyTheRadius', 'testPressHoldDragOnAKnobDrags',
                     'testGrabberDragExpandsTheSheet', 'testGripDragMovesTheFloat'):
            with self.subTest(name):
                self.assertIn('func %s() throws' % name, text)
        for needle in ('"lightsProbe"', '"raymol.viewport"', '"lights.gizmo.knob."',
                       '"lights.sheet.grabber"', '"lights.float.grip"', '"PYMOL_UITEST"',
                       'XCTSkip(', 'press(forDuration: 0.8, thenDragTo:'):
            with self.subTest(needle):
                self.assertIn(needle, text)
        self.assertIn('XCTAssertEqual(after.cam, before.cam, "the knob pinch moved the camera")', text)
