import XCTest
@testable import RayMol

/// Coverage for `RenderGate` — the per-tick decision the Metal render loop
/// makes (issue #396).
///
/// The loop itself cannot be unit-tested (a test cannot drive a CADisplayLink or
/// a GPU), so the whole decision lives in this pure type and is pinned down
/// here. Two regressions are the point of these tests:
///
///  1. The gate must not *consume* PyMOL's redisplay flag for a tick it then
///     declines to render. The old code cleared the flag and only afterwards
///     asked for a drawable, so a frame that failed to get one dropped the
///     frame AND the request for it — the viewport froze until the next
///     interaction. `.throttle` is a distinct outcome from `.render` precisely
///     so the caller knows not to consume the flag.
///  2. A frame that renders but presents nothing must force the next tick.
final class RenderGateTests: XCTestCase {

    // MARK: - What makes a tick render

    func testStaticSceneSkips() {
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: false, hasRenderedOnce: true,
                              redisplayPending: false, framesInFlight: 0),
            .skip,
            "a static scene must cost only the idle poll — this is the "
            + "battery/thermal win of on-demand rendering")
    }

    func testFirstFrameAlwaysRenders() {
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: false, hasRenderedOnce: false,
                              redisplayPending: false, framesInFlight: 0),
            .render,
            "the first frame must render even with no redisplay flagged, or the "
            + "window starts blank")
    }

    func testForceRedrawBypassesTheFlag() {
        // Wake/activate: the display can discard the drawable's contents while
        // asleep, and an unchanged scene flags no redisplay — so the flag alone
        // would leave a black viewport.
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: true, hasRenderedOnce: true,
                              redisplayPending: false, framesInFlight: 0),
            .render)
    }

    func testPendingRedisplayRenders() {
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: false, hasRenderedOnce: true,
                              redisplayPending: true, framesInFlight: 0),
            .render)
    }

    // MARK: - The in-flight cap

    func testThrottlesAtTheCapRatherThanQueueingFrames() {
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: false, hasRenderedOnce: true,
                              redisplayPending: true,
                              framesInFlight: RenderGate.maxFramesInFlight),
            .throttle,
            "at the cap the loop must skip the tick; handing another frame to a "
            + "queue that cannot retire it is what parked the main thread in "
            + "currentDrawable for ~half of every rotation (#396)")
    }

    func testRendersJustBelowTheCap() {
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: false, hasRenderedOnce: true,
                              redisplayPending: true,
                              framesInFlight: RenderGate.maxFramesInFlight - 1),
            .render,
            "the cap must not starve the GPU — one frame short of it still renders")
    }

    func testThrottleIsDistinctFromSkip() {
        // The caller consumes the redisplay flag only on `.render`. If throttling
        // collapsed into `.skip` that would be fine, but if it collapsed into
        // `.render` the flag would be consumed for a frame never encoded.
        let throttled = RenderGate.decide(
            forceRedraw: false, hasRenderedOnce: true, redisplayPending: true,
            framesInFlight: RenderGate.maxFramesInFlight)
        XCTAssertNotEqual(throttled, .render,
                          "a throttled tick must never be reported as rendering")
    }

    func testAForcedRedrawStillRespectsTheCap() {
        // forceRedraw overrides the *flag*, not the queue: rendering anyway
        // would just block on currentDrawable, which is the bug being fixed.
        // The forced state is sticky, so the next tick renders it.
        XCTAssertEqual(
            RenderGate.decide(forceRedraw: true, hasRenderedOnce: true,
                              redisplayPending: false,
                              framesInFlight: RenderGate.maxFramesInFlight),
            .throttle)
    }

    func testCapLeavesADrawableFree() {
        XCTAssertLessThan(RenderGate.maxFramesInFlight, 3,
                          "CAMetalLayer.maximumDrawableCount is 3; the cap must "
                          + "stay under it so a drawable is free when the frame "
                          + "finally asks for one")
        XCTAssertGreaterThanOrEqual(RenderGate.maxFramesInFlight, 2,
                                    "fewer than two in flight serializes CPU "
                                    + "encoding against GPU execution")
    }

    // MARK: - Recovering from a frame that presented nothing

    func testAPresentedFrameClearsTheForcedRedraw() {
        XCTAssertFalse(RenderGate.forceRedrawAfterRender(presented: true))
    }

    func testAFrameWithNoDrawableForcesTheNextTick() {
        XCTAssertTrue(
            RenderGate.forceRedrawAfterRender(presented: false),
            "the frame rendered into the offscreen targets but reached no screen, "
            + "and its redisplay flag is already consumed — without the forced "
            + "retry the viewport would hold a stale image (#396)")
    }

    // MARK: - Tick rate

    func testRayTracingHalvesTheTickRate() {
        XCTAssertEqual(RenderGate.preferredFPS(rayTracing: false), 120,
                       "ProMotion is still allowed when frames are cheap")
        XCTAssertEqual(RenderGate.preferredFPS(rayTracing: true), 60,
                       "ray-traced frames are GPU-bound well below 120 Hz, so the "
                       + "surplus ticks only cost a PyMOL_Idle each")
    }
}

/// Coverage for `AirRedrawGate` — when the light rig's moving dust (#618) may
/// ask the render loop for a frame on its own.
///
/// The policy is the issue's: animated dust must not keep the GPU busy when the
/// app is inactive or the device is saving power, and runs at a capped rate
/// otherwise. `draw(in:)` only feeds this type the platform's state and passes
/// a due tick to `RenderGate.decide` as a pending redisplay, so these tests pin
/// the whole decision, including how a due tick fares at the in-flight cap.
final class AirRedrawGateTests: XCTestCase {

    private typealias Activity = AirRedrawGate.Activity

    private let shown = Activity(active: true, visible: true, lowPower: false)

    // MARK: - When the dust may tick at all

    func testActiveVisibleTicksAtThirtyHertz() throws {
        let interval = try XCTUnwrap(AirRedrawGate.interval(shown),
                                     "an active, visible app with power to spare animates the dust")
        XCTAssertEqual(interval, 1.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(AirRedrawGate.activeFPS, 30,
                       "the active cap is 30 Hz (provisional until #623's device runs)")
    }

    func testInactiveAppHoldsTheDustStill() {
        XCTAssertNil(AirRedrawGate.interval(Activity(active: false, visible: true, lowPower: false)),
                     "another app frontmost (or the app switcher on iOS): no air ticks")
    }

    func testHiddenWindowHoldsTheDustStill() {
        XCTAssertNil(AirRedrawGate.interval(Activity(active: true, visible: false, lowPower: false)),
                     "a hidden, occluded or miniaturised window: no air ticks")
    }

    func testLowPowerHoldsTheDustStill() {
        XCTAssertNil(AirRedrawGate.interval(Activity(active: true, visible: true, lowPower: true)),
                     "Low Power Mode or a serious thermal state: the dust holds still, "
                     + "not a slower rate (#618's args, Q4)")
    }

    func testEveryStateButShownIsStill() {
        for active in [false, true] {
            for visible in [false, true] {
                for lowPower in [false, true] {
                    let activity = Activity(active: active, visible: visible, lowPower: lowPower)
                    XCTAssertEqual(AirRedrawGate.interval(activity) != nil, activity == shown,
                                   "\(activity)")
                }
            }
        }
    }

    func testLowPowerReadsLowPowerModeAndThermalState() {
        XCTAssertFalse(AirRedrawGate.lowPower(lowPowerMode: false, thermalState: .nominal))
        XCTAssertFalse(AirRedrawGate.lowPower(lowPowerMode: false, thermalState: .fair))
        XCTAssertTrue(AirRedrawGate.lowPower(lowPowerMode: false, thermalState: .serious))
        XCTAssertTrue(AirRedrawGate.lowPower(lowPowerMode: false, thermalState: .critical))
        for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            XCTAssertTrue(AirRedrawGate.lowPower(lowPowerMode: true, thermalState: state),
                          "Low Power Mode alone holds the dust still (\(state.rawValue))")
        }
    }

    // MARK: - When a tick is due

    func testDueAtNinetyFivePercentOfTheInterval() {
        let interval = 1.0 / 30.0
        let last = 100.0
        XCTAssertFalse(AirRedrawGate.due(interval: interval, now: last, lastFrame: last),
                       "no second air frame in the same instant")
        XCTAssertFalse(AirRedrawGate.due(interval: interval, now: last + 0.94 * interval,
                                         lastFrame: last),
                       "before 0.95 of the interval the tick is not due")
        XCTAssertTrue(AirRedrawGate.due(interval: interval, now: last + 0.95 * interval,
                                        lastFrame: last),
                      "at 0.95 of the interval it is, so display-link jitter does not halve the rate")
        XCTAssertTrue(AirRedrawGate.due(interval: interval, now: last + interval, lastFrame: last))
        XCTAssertTrue(AirRedrawGate.due(interval: interval, now: last + 10, lastFrame: last))
        XCTAssertEqual(AirRedrawGate.dueShare, 0.95)
    }

    func testDueAtTheFirstTickAfterStart() {
        // lastFrame starts at 0 on the Coordinator, and CACurrentMediaTime is
        // the host's uptime, so the first allowed tick is due.
        XCTAssertTrue(AirRedrawGate.due(interval: 1.0 / 30.0, now: 5, lastFrame: 0))
    }

    func testDisplayRateTicksGiveAboutThirtyAirFrames() {
        // A 120 Hz display link for one second: the air frames the gate lets
        // through, stamping lastFrame on each, stay at the 30 Hz cap.
        let interval = 1.0 / AirRedrawGate.activeFPS
        var last = 0.0
        var frames = 0
        for tick in 1...120 {
            let now = Double(tick) / 120
            if AirRedrawGate.due(interval: interval, now: now, lastFrame: last) {
                frames += 1
                last = now
            }
        }
        XCTAssertEqual(frames, 30)
    }

    // MARK: - A due tick through RenderGate

    /// What draw(in:) hands RenderGate: `pending || airDue`.
    private func decide(pending: Bool, airDue: Bool, framesInFlight: Int) -> RenderGate.Decision {
        RenderGate.decide(forceRedraw: false, hasRenderedOnce: true,
                          redisplayPending: pending || airDue, framesInFlight: framesInFlight)
    }

    func testADueAirTickRenders() {
        XCTAssertEqual(
            decide(pending: false, airDue: true, framesInFlight: 0),
            .render,
            "draw(in:) passes `pending || airDue`: a due air tick renders like a redisplay")
    }

    func testADueAirTickThrottlesAtTheCap() {
        XCTAssertEqual(
            decide(pending: false, airDue: true, framesInFlight: RenderGate.maxFramesInFlight),
            .throttle,
            "the dust never queues frames past the in-flight cap")
    }

    func testNoAirTickIsAStaticScene() {
        XCTAssertEqual(
            decide(pending: false, airDue: false, framesInFlight: 0),
            .skip,
            "with the dust still (or not due) a static scene costs only the idle poll")
    }
}
