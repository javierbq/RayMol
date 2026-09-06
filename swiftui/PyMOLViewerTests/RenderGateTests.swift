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
