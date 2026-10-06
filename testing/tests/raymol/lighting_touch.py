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
        would leave the view (inset by the handle's reach) does another index
        win, and both rings use the same index."""
        text = self.read(GIZMO_MODEL)
        selected = body(text, 'private static func selected(')
        self.assertIsNotNone(selected, 'LightGizmoLayout.selected not found')
        first = selected.find('inner.rightmost ?? aim')
        rule = selected.find('if !inside(handles)')
        self.assertGreaterEqual(first, 0, 'the rightmost placement comes first')
        self.assertGreater(rule, first, 'the in-view rule only replaces it')
        self.assertIn('.insetBy(dx: metrics.handleReach, dy: metrics.handleReach)', selected)
        self.assertIn('inner.samples[k]', selected)

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
        frame; macOS keeps its one-row 15 pt swatches."""
        text = self.read(INSPECTOR)
        for signature in ('private func lightMenu(', 'private func chip(', 'private func header('):
            with self.subTest(signature):
                block = body(text, signature)
                self.assertIsNotNone(block, signature + ' not found')
                self.assertIn('.lightsTouchTarget()', block)
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
