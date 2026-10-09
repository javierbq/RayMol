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
        XCTAssertEqual(interval, 1.0 / AirRedrawGate.activeFPS, accuracy: 1e-12)
        XCTAssertEqual(AirRedrawGate.defaultFPS, 30,
                       "the default cap is 30 Hz (provisional until #623's device runs)")
        if ProcessInfo.processInfo.environment["RAYMOL_AIR_FPS"] == nil {
            XCTAssertEqual(AirRedrawGate.activeFPS, 30, "without RAYMOL_AIR_FPS the cap is the default")
            XCTAssertEqual(interval, 1.0 / 30.0, accuracy: 1e-12)
        }
    }

    // MARK: - Launch switches (#623's calibration)

    func testFPSReadsTheEnvironment() {
        XCTAssertEqual(AirRedrawGate.fps(environment: [:]), 30, "unset: the default")
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": "20"]), 20)
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": "60"]), 60)
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": "1"]), 1, "the lowest cap")
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": "120"]), 120, "the highest cap")
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": "24.5"]), 24.5)
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": " 45 "]), 45,
                       "surrounding spaces are ignored")
        for bad in ["0", "0.5", "120.5", "500", "-30", "x", "", "nan", "inf", "30fps"] {
            XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_FPS": bad]), 30,
                           "'\(bad)' is not a cap in 1...120: the default")
        }
        XCTAssertEqual(AirRedrawGate.fps(environment: ["RAYMOL_AIR_LOG": "60"]), 30,
                       "only RAYMOL_AIR_FPS sets the cap")
        XCTAssertEqual(AirRedrawGate.fpsRange, 1...120)
        XCTAssertEqual(AirRedrawGate.activeFPS,
                       AirRedrawGate.fps(environment: ProcessInfo.processInfo.environment),
                       "the launch's cap is the process environment's")
    }

    func testACapFromTheEnvironmentSetsTheInterval() {
        // The interval is 1 / activeFPS; at a 120 Hz display link a cap of 20
        // or 60 lets that many air frames a second through.
        for cap in [20.0, 60.0] {
            var last = 0.0
            var frames = 0
            for tick in 1...120 {
                let now = Double(tick) / 120
                if AirRedrawGate.due(interval: 1 / cap, now: now, lastFrame: last) {
                    frames += 1
                    last = now
                }
            }
            XCTAssertEqual(frames, Int(cap), "cap \(cap)")
        }
    }

    func testLogEnabledOnlyForOne() {
        XCTAssertTrue(AirRedrawGate.logEnabled(environment: ["RAYMOL_AIR_LOG": "1"]))
        XCTAssertTrue(AirRedrawGate.logEnabled(environment: ["RAYMOL_AIR_LOG": " 1 "]))
        XCTAssertFalse(AirRedrawGate.logEnabled(environment: [:]), "off by default")
        for other in ["0", "", "true", "yes", "2"] {
            XCTAssertFalse(AirRedrawGate.logEnabled(environment: ["RAYMOL_AIR_LOG": other]),
                           "'\(other)'")
        }
        XCTAssertFalse(AirRedrawGate.logEnabled(environment: ["RAYMOL_AIR_FPS": "1"]))
        XCTAssertEqual(AirRedrawGate.logsHolds,
                       AirRedrawGate.logEnabled(environment: ProcessInfo.processInfo.environment))
    }

    func testHoldReasonNamesWhyTheDustIsStill() {
        XCTAssertNil(AirRedrawGate.holdReason(shown), "shown: no hold")
        XCTAssertEqual(AirRedrawGate.holdReason(Activity(active: false, visible: true, lowPower: false)),
                       .inactive)
        XCTAssertEqual(AirRedrawGate.holdReason(Activity(active: true, visible: false, lowPower: false)),
                       .hidden)
        XCTAssertEqual(AirRedrawGate.holdReason(Activity(active: true, visible: true, lowPower: true)),
                       .lowPower)
        // The first failing condition of interval's guard wins.
        XCTAssertEqual(AirRedrawGate.holdReason(Activity(active: false, visible: false, lowPower: true)),
                       .inactive)
        XCTAssertEqual(AirRedrawGate.holdReason(Activity(active: true, visible: false, lowPower: true)),
                       .hidden)
        XCTAssertEqual(AirRedrawGate.HoldReason.lowPower.rawValue, "low_power")
    }

    func testAHoldReasonExactlyWhenTheDustIsStill() {
        for active in [false, true] {
            for visible in [false, true] {
                for lowPower in [false, true] {
                    let activity = Activity(active: active, visible: visible, lowPower: lowPower)
                    XCTAssertEqual(AirRedrawGate.holdReason(activity) == nil,
                                   AirRedrawGate.interval(activity) != nil, "\(activity)")
                }
            }
        }
    }

    func testTheHoldLine() {
        let none = AirRedrawGate.HoldState(reason: nil, lowPowerMode: false, thermalState: .nominal)
        XCTAssertEqual(AirRedrawGate.holdLine(none, fps: 30),
                       "AirRedrawGate: hold=none low_power_mode=0 thermal=nominal fps=30")
        let lpm = AirRedrawGate.HoldState(reason: .lowPower, lowPowerMode: true, thermalState: .fair)
        XCTAssertEqual(AirRedrawGate.holdLine(lpm, fps: 60),
                       "AirRedrawGate: hold=low_power low_power_mode=1 thermal=fair fps=60")
        let hot = AirRedrawGate.HoldState(reason: .lowPower, lowPowerMode: false, thermalState: .critical)
        XCTAssertEqual(AirRedrawGate.holdLine(hot, fps: 24.5),
                       "AirRedrawGate: hold=low_power low_power_mode=0 thermal=critical fps=24.5")
        let away = AirRedrawGate.HoldState(reason: .inactive, lowPowerMode: false, thermalState: .serious)
        XCTAssertEqual(AirRedrawGate.holdLine(away, fps: 30),
                       "AirRedrawGate: hold=inactive low_power_mode=0 thermal=serious fps=30")
        XCTAssertEqual(AirRedrawGate.thermalName(.nominal), "nominal")
        XCTAssertEqual(AirRedrawGate.thermalName(.fair), "fair")
        XCTAssertEqual(AirRedrawGate.thermalName(.serious), "serious")
        XCTAssertEqual(AirRedrawGate.thermalName(.critical), "critical")
    }

    func testAThermalStepInsideAHoldIsANewState() {
        // The coordinator logs when the HoldState changes, so serious to
        // critical (same reason) still gives a line, and the same state twice
        // gives one.
        let serious = AirRedrawGate.HoldState(reason: .lowPower, lowPowerMode: false, thermalState: .serious)
        let critical = AirRedrawGate.HoldState(reason: .lowPower, lowPowerMode: false, thermalState: .critical)
        XCTAssertNotEqual(serious, critical)
        XCTAssertEqual(serious, AirRedrawGate.HoldState(reason: .lowPower, lowPowerMode: false,
                                                        thermalState: .serious))
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
        // lastFrame 0, so `now - lastFrame` is exactly `now` and the boundary
        // compares equal values (no rounding from a subtraction).
        let interval = 1.0 / 30.0
        let last = 0.0
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
