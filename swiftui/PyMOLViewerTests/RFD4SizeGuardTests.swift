#if os(macOS)
import XCTest
import RFD4MLX
@testable import RayMol

/// The size guard is the ONLY defence against this method's out-of-memory failure, and that
/// failure is not recoverable: mlx throws `std::runtime_error` from inside a Metal
/// command-buffer completion handler, on a thread with no handler on its stack, so it
/// reaches `std::terminate` and the process dies with SIGABRT. Neither `do`/`catch` nor
/// `withMLXErrorsAsThrows` intercepts it, and on macOS it takes the unsaved session too.
///
/// So the arithmetic is tested through the pure `decide`, on this host, at sizes this host
/// does not have — the same split `RFD3SizeGuard` uses and for the same reason.
final class RFD4SizeGuardTests: XCTestCase {

    /// A machine-independent budget to reason against: 8 GB at RayMol's own fraction.
    private let eightGB = Int(8e9 * RFD4SizeGuard.okFraction)

    func testTheArithmeticIsRFD4BudgetsAndNotACopyOfIt() {
        // The whole policy of this type is that it owns the FRACTION and delegates the
        // CURVE. Pinned because copying the coefficients is the tempting mistake and the
        // one already scheduled to break: the port records which commit to revert if
        // memory ever matters more than speed, and a copied constant would then refuse
        // designs that fit comfortably.
        for tokens in [128, 256, 512, 638] {
            switch RFD4SizeGuard.decide(tokens: tokens, budgetBytes: Int(1e15)) {
            case .ok, .warn:
                break
            case .refuse:
                XCTFail("\(tokens) tokens must fit a 1 PB budget")
            }
        }
        // And the refusal's own "what fits" number is RFD4Budget's, not a re-derivation.
        guard case .refuse(_, _, _, let maxTokens) =
            RFD4SizeGuard.decide(tokens: 20_000, budgetBytes: eightGB) else {
            return XCTFail("20k tokens cannot fit 4 GB")
        }
        XCTAssertEqual(maxTokens, RFD4Budget.maxTokens(budgetBytes: eightGB,
                                                       precision: RFD4SizeGuard.precision))
    }

    func testTheGuardAsksAboutThePrecisionThatShips() {
        // fp16 is what the pack declares and what the loader is handed explicitly, so
        // `RFD4_DTYPE` cannot reinterpret it. Asking for the fp32 curve would predict
        // exactly 2.000x the real peak and refuse half the designs that fit — which is
        // why this guard takes the precision from the port's one declaration of what
        // ships rather than naming `.fp16` itself.
        XCTAssertEqual(RFD4SizeGuard.precision, RFD4Budget.shippingPrecision)
        XCTAssertEqual(RFD4SizeGuard.precision, .fp16)
        let fp16 = RFD4Budget.predictedPeakBytes(tokens: 638, precision: .fp16)
        let fp32 = RFD4Budget.predictedPeakBytes(tokens: 638, precision: .fp32)
        XCTAssertEqual(Double(fp32) / Double(fp16), 2.0, accuracy: 0.01)
        // The documented number, so a change to the curve is visible here rather than
        // only in a refusal a user sees: 638 tokens is 6.62 GB at fp16.
        XCTAssertEqual(Double(fp16) / 1e9, 6.62, accuracy: 0.02)
    }

    func testSizingIsInTokensRatherThanAtoms() {
        // The mistake porting RFD3's policy across: there a design is sized in ATOMS,
        // because RFdiffusion3's cost is driven by an all-atom representation. RFD4's
        // trunk is tokenized by RESIDUE. Inflating `n` by a per-residue atom count and
        // feeding it to a QUADRATIC would refuse essentially everything.
        //
        // 226 tokens is the albumin campaign's largest design. The same system counted in
        // atoms is roughly 5-8x that, and must predict a wildly larger peak — which is
        // the evidence that the two units are not interchangeable.
        let tokens = RFD4Budget.predictedPeakBytes(tokens: 226)
        let asAtoms = RFD4Budget.predictedPeakBytes(tokens: 226 * 6)
        XCTAssertGreaterThan(Double(asAtoms), Double(tokens) * 10)
    }

    func testTheCurveStillPredictsTheCampaignItWasCheckedAgainst() {
        // The one END-TO-END number: 100 designs at 210-230 tokens, fp32, high-water mark
        // 2.79 GB. The guard is built on this fit, so if the fit stops predicting the only
        // real run there is, the guard is predicting the wrong thing.
        let predicted = Double(RFD4Budget.predictedPeakBytes(tokens: 230,
                                                             precision: .fp32)) / 1e9
        XCTAssertGreaterThanOrEqual(predicted, 2.79, "a guard must not under-predict")
        XCTAssertLessThan(predicted, 2.79 * 1.05, "and not by much either")
    }

    func testTheDecisionIsMonotoneInSize() {
        // A larger design must never be MORE acceptable than a smaller one. Cheap to
        // assert, and it is the property a hand-written tier table gets wrong.
        var refused = false
        for tokens in stride(from: 100, through: 3_000, by: 50) {
            let decision = RFD4SizeGuard.decide(tokens: tokens, budgetBytes: eightGB)
            if case .refuse = decision { refused = true } else if refused {
                XCTFail("\(tokens) tokens was accepted after a smaller size was refused")
            }
        }
        XCTAssertTrue(refused, "something in this range must exceed a 4 GB budget")
    }

    func testTheBoundaryRefusesRatherThanRoundsUp() {
        let maxTokens = RFD4Budget.maxTokens(budgetBytes: eightGB,
                                             precision: RFD4SizeGuard.precision)
        if case .refuse = RFD4SizeGuard.decide(tokens: maxTokens, budgetBytes: eightGB) {
            XCTFail("the largest fitting size must not be refused")
        }
        guard case .refuse = RFD4SizeGuard.decide(tokens: maxTokens + 1,
                                                  budgetBytes: eightGB) else {
            return XCTFail("one token past the ceiling must be refused")
        }
    }

    func testTheTiersAreOrderedAndTheBudgetIsAFractionOfThisMachine() {
        XCTAssertLessThan(RFD4SizeGuard.warnFraction, RFD4SizeGuard.okFraction)
        // The same fraction RFD3 allows, and below PredictSizeGuard's wall. The failure is
        // an abort rather than a slowdown, so this is the most conservative of the three.
        XCTAssertEqual(RFD4SizeGuard.okFraction, RFD3SizeGuard.okFraction)
        XCTAssertLessThan(RFD4SizeGuard.okFraction, PredictSizeGuard.warnFraction)
        XCTAssertEqual(RFD4SizeGuard.budgetBytes,
                       Int(Double(RFD4SizeGuard.availableBytes)
                           * RFD4SizeGuard.okFraction))
        XCTAssertGreaterThan(RFD4SizeGuard.budgetBytes, 0)
    }

    func testTheRefusalNamesEveryNumberAUserNeeds() {
        guard case let .refuse(tokens, predicted, budget, maxTokens) =
            RFD4SizeGuard.decide(tokens: 20_000, budgetBytes: eightGB) else {
            return XCTFail("20k tokens cannot fit 4 GB")
        }
        let message = RFD4SizeGuard.refusalMessage(
            tokens: tokens, predictedBytes: predicted, budgetBytes: budget,
            maxTokens: maxTokens)
        // What was asked, what it would cost, and what fits — a refusal a user can act on
        // rather than one they can only read.
        XCTAssertTrue(message.contains("20000"))
        XCTAssertTrue(message.contains("\(maxTokens)"))
        XCTAssertTrue(message.contains("token"))
        // And it says which axis to shrink, in this model's own units.
        XCTAssertTrue(message.contains("One residue is one token"))
    }

    func testTheCacheLimitIsRegisteredUnderItsOwnOwner() {
        // `MLXRuntime` keeps the most conservative ceiling any owner requires, so
        // registering under RFD3's name would overwrite its requirement rather than being
        // arbitrated against it — and whichever ran last would win, silently, by call
        // order. Both runtimes can be resident in one session.
        XCTAssertEqual(RFD4Runtime.cacheLimitOwner, "RFD4")
        XCTAssertNotEqual(RFD4Runtime.cacheLimitOwner, RFD3Runtime.cacheLimitOwner)
        // Larger than RFD3's, because this ceiling spans the whole trajectory rather than
        // a one-off pack read: the RFD4 port sets no limits of its own, where RFD3Kit
        // wraps its rollout in a measured pair and restores them on the way out.
        XCTAssertGreaterThan(RFD4Runtime.cacheLimitBytes, RFD3Runtime.cacheLimitBytes)
    }
}
#endif
