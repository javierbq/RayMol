#if os(macOS)
import XCTest
import RFD3Kit
@testable import RayMol

/// The size guard is the ONLY defence against this method's out-of-memory failure, and that
/// failure is not recoverable: mlx throws `std::runtime_error` from inside a Metal
/// command-buffer completion handler, on a thread with no handler on its stack, so it
/// reaches `std::terminate` and the process dies with SIGABRT. Neither `do`/`catch` nor
/// `withMLXErrorsAsThrows` intercepts it, and on macOS it takes the unsaved session too.
///
/// So the arithmetic is tested through the pure `decide`, on this host, at sizes this host
/// does not have — the same split `DesignSizeGuard` uses and for the same reason.
final class RFD3SizeGuardTests: XCTestCase {

    /// A machine-independent budget to reason against: 8 GB at RayMol's own fraction.
    private let eightGB = Int(8e9 * RFD3SizeGuard.okFraction)

    func testTheArithmeticIsRFD3BudgetsAndNotACopyOfIt() {
        // The whole policy of this type is that it owns the FRACTION and delegates the
        // CURVE. Pinned because copying the coefficients is the tempting mistake and the
        // one already scheduled to break: row-blocking the motif distance embedding
        // upstream takes the quadratic term from ~995 to ~62 bytes per atom squared, and a
        // copied constant would then refuse designs that fit comfortably.
        for atoms in [1_000, 2_500, 5_000, 7_268] {
            switch RFD3SizeGuard.decide(atoms: atoms, budgetBytes: Int(1e15)) {
            case .ok, .warn:
                break
            case .refuse:
                XCTFail("\(atoms) atoms must fit a 1 PB budget")
            }
        }
        // And the refusal's own "what fits" number is RFD3Budget's, not a re-derivation.
        guard case .refuse(_, _, _, let maxAtoms) =
            RFD3SizeGuard.decide(atoms: 100_000, budgetBytes: eightGB) else {
            return XCTFail("100k atoms cannot fit 4 GB")
        }
        XCTAssertEqual(maxAtoms, RFD3Budget.maxAtoms(budgetBytes: eightGB))
    }

    func testTheDecisionIsMonotoneInSize() {
        // A larger design must never be MORE acceptable than a smaller one. Cheap to
        // assert, and it is the property a hand-written tier table gets wrong.
        var refused = false
        for atoms in stride(from: 500, through: 12_000, by: 500) {
            let decision = RFD3SizeGuard.decide(atoms: atoms, budgetBytes: eightGB)
            if case .refuse = decision { refused = true } else if refused {
                XCTFail("\(atoms) atoms was accepted after a smaller size was refused")
            }
        }
        XCTAssertTrue(refused, "something in this range must exceed a 4 GB budget")
    }

    func testTheBoundaryRefusesRatherThanRoundsUp() {
        let maxAtoms = RFD3Budget.maxAtoms(budgetBytes: eightGB)
        if case .refuse = RFD3SizeGuard.decide(atoms: maxAtoms, budgetBytes: eightGB) {
            XCTFail("the largest fitting size must not be refused")
        }
        guard case .refuse = RFD3SizeGuard.decide(atoms: maxAtoms + 1,
                                                 budgetBytes: eightGB) else {
            return XCTFail("one atom past the ceiling must be refused")
        }
    }

    func testRayMolIsMoreConservativeThanTheEngineAndThePredictGuard() {
        // Deliberate, and the direction matters: RFD3Budget's 0.60 was measured on a bare
        // CLI with no renderer and one design per process, and PredictSizeGuard's 0.75 wall
        // guards a failure that is slow rather than fatal. This one aborts the process.
        XCTAssertLessThan(RFD3SizeGuard.okFraction, RFD3Budget.defaultMemoryFraction)
        XCTAssertLessThan(RFD3SizeGuard.okFraction, PredictSizeGuard.warnFraction)
        XCTAssertLessThan(RFD3SizeGuard.warnFraction, RFD3SizeGuard.okFraction)
    }

    func testTheBudgetIsAFractionOfThisMachine() {
        XCTAssertEqual(RFD3SizeGuard.budgetBytes,
                       Int(Double(RFD3SizeGuard.availableBytes) * RFD3SizeGuard.okFraction))
        XCTAssertGreaterThan(RFD3SizeGuard.budgetBytes, 0)
    }

    func testTheRefusalNamesEveryNumberAUserNeeds() {
        guard case .refuse(let atoms, let predicted, let budget, let maxAtoms) =
            RFD3SizeGuard.decide(atoms: 20_000, budgetBytes: eightGB) else {
            return XCTFail("20k atoms cannot fit 4 GB")
        }
        let message = RFD3SizeGuard.refusalMessage(
            atoms: atoms, predictedBytes: predicted, budgetBytes: budget,
            maxAtoms: maxAtoms)
        // What was asked, what it would cost, what fits, and what to do about it. A refusal
        // missing any of these leaves the user guessing at a number only this code knows.
        XCTAssertTrue(message.contains("20000"), message)
        XCTAssertTrue(message.contains("\(maxAtoms)"), message)
        XCTAssertTrue(message.contains("GB"), message)
        XCTAssertTrue(message.lowercased().contains("target"), message)
    }

    // MARK: The engine's own guard, weight-free

    func testPreflightRefusesAnOverBudgetDesignWithNoModelPackPresent() throws {
        // `RFD3Model.preflight` is static and weight-free for exactly this reason: an
        // over-budget design must be refused before a 672 MB pack is read and, above all,
        // before any GPU work. Asserted with no pack anywhere near this process.
        let atoms: [(String, (Float, Float, Float))] = [
            ("N", (0, 0, 0)), ("CA", (1.5, 0, 0)), ("C", (2.4, 1, 0)), ("O", (2, 2.1, 0))]
        let target = (0 ..< 40).map { index in
            RFD3Model.Residue(resName: "GLY", chain: 0, resSeq: index + 1,
                              atoms: atoms.map { RFD3Model.Atom(
                                  name: $0.0,
                                  xyz: SIMD3($0.1.0 + Float(index) * 3.8, $0.1.1, $0.1.2)) })
        }
        var options = RFD3Model.Options()
        options.binderLength = 60
        options.hotspots = [10]
        XCTAssertThrowsError(
            try RFD3Model.preflight(target: target, options: options, budgetBytes: 1)
        ) { error in
            guard case RFD3ModelError.inputTooLarge(_, _, let predicted, let budget) = error
            else {
                return XCTFail("expected .inputTooLarge, got \(error)")
            }
            XCTAssertEqual(budget, 1)
            XCTAssertGreaterThan(predicted, 1)
            // And the refusal must NAME the budget, since its numbers are its whole value.
            XCTAssertTrue((error as? RFD3ModelError)?.description.contains("budget")
                          ?? false)
        }
    }

    func testPreflightAdmitsADesignThatFitsThisMachinesBudget() throws {
        // The other half: a small design must pass the same static, weight-free path, so
        // the refusal above is a size decision rather than "preflight always throws".
        let atoms: [(String, (Float, Float, Float))] = [
            ("N", (0, 0, 0)), ("CA", (1.5, 0, 0)), ("C", (2.4, 1, 0)), ("O", (2, 2.1, 0))]
        let target = (0 ..< 20).map { index in
            RFD3Model.Residue(resName: "GLY", chain: 0, resSeq: index + 1,
                              atoms: atoms.map { RFD3Model.Atom(
                                  name: $0.0,
                                  xyz: SIMD3($0.1.0 + Float(index) * 3.8, $0.1.1, $0.1.2)) })
        }
        var options = RFD3Model.Options()
        options.binderLength = 20
        options.hotspots = [5]
        _ = try RFD3Model.preflight(target: target, options: options,
                                    budgetBytes: RFD3SizeGuard.budgetBytes)
    }
}
#endif
