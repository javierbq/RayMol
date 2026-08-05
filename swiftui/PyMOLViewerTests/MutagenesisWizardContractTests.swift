import XCTest
@testable import RayMol

final class MutagenesisWizardContractTests: XCTestCase {
    private let residue = MutagenesisResidue(
        objectName: "6f8p",
        chain: "A",
        name: "ARG",
        number: "159"
    )
    private let modes = [
        MutagenesisResidueMode(id: "current", label: "No mutation"),
        MutagenesisResidueMode(id: "ALA", label: "Alanine")
    ]
    private let rotamers = [
        MutagenesisRotamer(id: "r1", name: "Rotamer 1", probability: 0.6, clashScore: 0.8),
        MutagenesisRotamer(id: "r2", name: "Rotamer 2", probability: 0.4, clashScore: 1.2)
    ]

    private func state(
        phase: MutagenesisWizardPhase,
        selectedModeID: String? = "ALA",
        selectedRotamerID: String? = nil
    ) -> MutagenesisWizardState {
        MutagenesisWizardState(
            phase: phase,
            residueModes: modes,
            selectedModeID: selectedModeID,
            selectedRotamerID: selectedRotamerID
        )
    }

    func testInactiveStateHidesWizardDataAndDisablesCommands() {
        let state = state(phase: .inactive)

        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.residue)
        XCTAssertTrue(state.rotamers.isEmpty)
        XCTAssertEqual(
            state.commandAvailability,
            MutagenesisWizardCommandAvailability(
                canSelectMode: false,
                canSelectRotamer: false,
                canApply: false,
                canClear: false,
                canDone: false
            )
        )
    }

    func testAwaitingResidueKeepsModeAndLifecycleActionsAvailable() {
        let state = state(phase: .awaitingResidue)

        XCTAssertTrue(state.isActive)
        XCTAssertTrue(state.commandAvailability.canSelectMode)
        XCTAssertFalse(state.commandAvailability.canSelectRotamer)
        XCTAssertFalse(state.commandAvailability.canApply)
        XCTAssertTrue(state.commandAvailability.canClear)
        XCTAssertTrue(state.commandAvailability.canDone)
    }

    func testLoadingDisablesSelectionAndApplyButCanBeClearedOrClosed() {
        let state = state(phase: .loading(residue: residue))

        XCTAssertEqual(state.residue, residue)
        XCTAssertFalse(state.commandAvailability.canSelectMode)
        XCTAssertFalse(state.commandAvailability.canSelectRotamer)
        XCTAssertFalse(state.commandAvailability.canApply)
        XCTAssertTrue(state.commandAvailability.canClear)
        XCTAssertTrue(state.commandAvailability.canDone)
    }

    func testReadyStateRequiresAValidRotamerBeforeApply() {
        var state = state(phase: .ready(residue: residue, rotamers: rotamers))

        XCTAssertEqual(state.rotamers, rotamers)
        XCTAssertTrue(state.commandAvailability.canSelectRotamer)
        XCTAssertFalse(state.commandAvailability.canApply)

        state.applyPrototypeAction(.selectRotamer("r2"))

        XCTAssertEqual(state.selectedRotamerID, "r2")
        XCTAssertTrue(state.commandAvailability.canApply)
    }

    func testChangingModeClearsStaleRotamerSelection() {
        var state = state(
            phase: .ready(residue: residue, rotamers: rotamers),
            selectedModeID: "ALA",
            selectedRotamerID: "r1"
        )

        state.applyPrototypeAction(.selectMode("current"))

        XCTAssertEqual(state.selectedModeID, "current")
        XCTAssertNil(state.selectedRotamerID)
        XCTAssertFalse(state.commandAvailability.canApply)
    }

    func testInvalidSelectionsAreIgnoredAndNotDispatched() {
        var actions: [MutagenesisWizardAction] = []
        let controller = MutagenesisWizardPrototypeController(
            state: state(phase: .ready(residue: residue, rotamers: rotamers)),
            actionSink: { actions.append($0) }
        )

        controller.send(.selectMode("NOT_A_MODE"))
        controller.send(.selectRotamer("NOT_A_ROTAMER"))

        XCTAssertEqual(controller.state.selectedModeID, "ALA")
        XCTAssertNil(controller.state.selectedRotamerID)
        XCTAssertTrue(actions.isEmpty)
    }

    func testActionSinkReceivesSelectionAndEnabledCommandsWithoutLiveMutation() {
        var actions: [MutagenesisWizardAction] = []
        let original = state(phase: .ready(residue: residue, rotamers: rotamers))
        let controller = MutagenesisWizardPrototypeController(
            state: original,
            actionSink: { actions.append($0) }
        )

        controller.send(.selectRotamer("r1"))
        controller.send(.apply)

        XCTAssertEqual(actions, [.selectRotamer("r1"), .apply])
        XCTAssertEqual(controller.state.phase, original.phase)
        XCTAssertEqual(controller.state.selectedRotamerID, "r1")
    }

    func testClearAndDoneModelTheLocalLifecycle() {
        var actions: [MutagenesisWizardAction] = []
        let controller = MutagenesisWizardPrototypeController(
            state: state(
                phase: .ready(residue: residue, rotamers: rotamers),
                selectedRotamerID: "r1"
            ),
            actionSink: { actions.append($0) }
        )

        controller.send(.clear)
        XCTAssertEqual(controller.state.phase, .awaitingResidue)
        XCTAssertNil(controller.state.selectedRotamerID)

        controller.send(.done)
        XCTAssertEqual(controller.state.phase, .inactive)
        XCTAssertEqual(actions, [.clear, .done])
    }

    func testErrorStateExposesRecoveryWithoutApply() {
        let state = state(phase: .failed(message: "Rotamer library unavailable"))

        XCTAssertEqual(state.errorMessage, "Rotamer library unavailable")
        XCTAssertFalse(state.commandAvailability.canSelectRotamer)
        XCTAssertFalse(state.commandAvailability.canApply)
        XCTAssertTrue(state.commandAvailability.canClear)
        XCTAssertTrue(state.commandAvailability.canDone)
    }

    func testLayoutPolicyStacksNarrowSurfacesAndSplitsWideSurfaces() {
        XCTAssertEqual(MutagenesisWizardLayoutClass.resolve(availableWidth: 359), .compact)
        XCTAssertEqual(MutagenesisWizardLayoutClass.resolve(availableWidth: 559), .compact)
        XCTAssertEqual(MutagenesisWizardLayoutClass.resolve(availableWidth: 560), .regular)
        XCTAssertEqual(MutagenesisWizardLayoutClass.resolve(availableWidth: 900), .regular)
    }
}
