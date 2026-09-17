#if os(macOS) && RAYMOL_MPNN
import XCTest
import MPNNKit
@testable import RayMol

/// The `mpnn` runtime seam (#453): a sequence-design request decodes, is routed to exactly
/// one manager, is refused by name when it is malformed, and composes a result document in
/// the shape `designing_sequences._read_result` reads.
///
/// Payloads are built as JSON and decoded through `InferenceJob.parseRequest`, never with
/// the memberwise initialiser: the thing under test is the wire contract with
/// `pymol.designers`, and a hand-built struct would only prove the decoder agrees with
/// itself.
///
/// Nothing here runs inference. `MPNNModel.design` needs the bundled pack and a GPU, which
/// is what `DesignInferenceSmokeTests` is for; what IS testable headlessly is every
/// decision made before and after the model call, and those are the ones a Python/Swift
/// skew breaks.
final class MPNNRuntimeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mpnn-runtime-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The manager is a singleton, so an injected closure left behind would run in
        // whatever test came next.
        MPNNJobManager.shared.designFn = nil
        MPNNJobManager.shared.scoreFn = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// A backbone file in the shape `raymol_design.enumerate_design_residues` writes,
    /// which is what `pymol.designers.mpnn._write_backbone` writes too -- the whole point
    /// of that path being a path rather than an inline array.
    private func writeBackbone(_ name: String, count: Int = 3,
                               invalidAt: Int? = nil) throws -> String {
        var residues: [[String: Any]] = []
        for index in 0..<count {
            let valid = index != invalidAt
            var residue: [String: Any] = [
                "chain": "A", "resi": "\(index + 1)", "resn": "ALA",
                "aa": 0, "valid": valid,
            ]
            for (key, offset) in [("n", 0.0), ("ca", 1.5), ("c", 2.4), ("o", 3.1)] {
                residue[key] = valid
                    ? [Double(index) * 3.8 + offset, 0.0, 0.0] as Any
                    : NSNull()
            }
            residues.append(residue)
        }
        let url = dir.appendingPathComponent("\(name).json")
        try JSONSerialization.data(
            withJSONObject: ["object": "bb", "state": 1, "residues": residues])
            .write(to: url)
        return url.path
    }

    /// Exactly the keys `host.submit` writes for a sequence designer -- note that
    /// `recycling_steps` and `diffusion_steps` are ABSENT, which is the change #453 made
    /// to the shared `Request`.
    private func writeRequest(job: String, runtime: String? = "mpnn",
                              backbonePath: String?,
                              nSequences: Int? = 4,
                              temperature: Double? = 0.2,
                              fixedPositions: [Int]? = nil,
                              omit: String? = nil) throws -> InferenceJob.Request {
        var payload: [String: Any] = [
            "job_id": job,
            "weights_dir": "",
            "chains": [],
            "seed": 11,
            "out_path": dir.appendingPathComponent("\(job).json").path,
            "status_path": dir.appendingPathComponent("\(job)-status.json").path,
            "metrics_path": dir.appendingPathComponent("\(job)-metrics.json").path,
        ]
        if let runtime { payload["runtime"] = runtime }
        if let backbonePath { payload["backbone_path"] = backbonePath }
        if let nSequences { payload["n_sequences"] = nSequences }
        if let temperature { payload["temperature"] = temperature }
        if let fixedPositions { payload["fixed_positions"] = fixedPositions }
        if let omit { payload["omit"] = omit }
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        return try InferenceJob.parseRequest(at: url)
    }

    // MARK: The wire

    func testASequenceDesignRequestDecodesEveryFieldItAdds() throws {
        let path = try writeBackbone("bb")
        let request = try writeRequest(job: "mpnn-wire", backbonePath: path,
                                       fixedPositions: [1], omit: "C")
        XCTAssertEqual(request.runtime, "mpnn")
        XCTAssertEqual(request.backbonePath, path)
        XCTAssertEqual(request.nSequences, 4)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.fixedPositions, [1])
        XCTAssertEqual(request.omit, "C")
        XCTAssertEqual(request.seed, 11)
    }

    /// The reason the schedule fields became optional: a designer has no diffusion
    /// schedule to send, and a non-optional field would make every `mpnn` request a
    /// "malformed prediction request" for every runtime at once.
    func testARequestWithNoScheduleStillDecodesAndFallsBackToTheDefaults() throws {
        let request = try writeRequest(job: "mpnn-noschedule",
                                       backbonePath: try writeBackbone("bb2"))
        XCTAssertNil(request.recyclingStepsRaw)
        XCTAssertNil(request.diffusionStepsRaw)
        XCTAssertEqual(request.recyclingSteps, InferenceJob.Request.defaultRecyclingSteps)
        XCTAssertEqual(request.diffusionSteps, InferenceJob.Request.defaultDiffusionSteps)
    }

    /// A schedule that IS sent still wins, so nothing about a prediction changed.
    func testAScheduleThatIsSentIsTheOneUsed() throws {
        let job = "mpnn-schedule"
        let payload: [String: Any] = [
            "job_id": job, "weights_dir": "", "chains": [], "seed": 0,
            "recycling_steps": 5, "diffusion_steps": 42,
            "out_path": dir.appendingPathComponent("\(job).pdb").path,
            "status_path": dir.appendingPathComponent("\(job)-status.json").path,
        ]
        let url = dir.appendingPathComponent("raymol_predict_req_\(job).json")
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let request = try InferenceJob.parseRequest(at: url)
        XCTAssertEqual(request.recyclingSteps, 5)
        XCTAssertEqual(request.diffusionSteps, 42)
    }

    // MARK: Routing

    func testTheRouterHandsAnMpnnRequestToTheMpnnManager() {
        let claimed = InferenceRouter.runtimes.filter {
            type(of: $0).runtimeName == MPNNJobManager.runtimeName
        }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertTrue(claimed.first === MPNNJobManager.shared)
    }

    func testACancelMarkerReachesTheMpnnManager() {
        let jobID = "mpnn-cancel-\(UUID().uuidString.prefix(8))"
        XCTAssertFalse(MPNNJobManager.shared.cancelRequestedForTesting.contains(jobID))
        InferenceRouter.handle(marker: "PREDICT:cancel:\(jobID)")
        XCTAssertTrue(MPNNJobManager.shared.cancelRequestedForTesting.contains(jobID))
    }

    func testTheManagerNamesTheSequenceDesignPythonSurface() {
        // Not `designing`: a designed sequence has no object, so it shares no pending
        // table with a generated backbone. Getting this wrong would call
        // `designing.discard_pending` on a name that is the user's own object.
        XCTAssertEqual(MPNNJobManager.pythonModule, "designing_sequences")
    }

    // MARK: Preflight

    func testAForeignRuntimeIsRefusedByName() throws {
        let request = try writeRequest(job: "mpnn-foreign", runtime: "rfd3",
                                       backbonePath: try writeBackbone("bb3"))
        let refusal = try XCTUnwrap(MPNNJobManager.preflight(request))
        XCTAssertEqual(refusal.state, "failed")
        XCTAssertTrue(refusal.error?.contains("'rfd3'") == true, refusal.error ?? "")
    }

    func testARequestWithNoBackboneIsRefused() throws {
        let request = try writeRequest(job: "mpnn-nobb", backbonePath: nil)
        let refusal = try XCTUnwrap(MPNNJobManager.preflight(request))
        XCTAssertTrue(refusal.error?.contains("needs a backbone") == true,
                      refusal.error ?? "")
    }

    func testABackboneFileThatIsNotThereIsRefused() throws {
        let request = try writeRequest(
            job: "mpnn-missing",
            backbonePath: dir.appendingPathComponent("nope.json").path)
        let refusal = try XCTUnwrap(MPNNJobManager.preflight(request))
        XCTAssertTrue(refusal.error?.contains("is not there") == true, refusal.error ?? "")
    }

    func testAnOverLargeSequenceCountIsRefused() throws {
        let request = try writeRequest(job: "mpnn-toomany",
                                       backbonePath: try writeBackbone("bb4"),
                                       nSequences: MPNNJobManager.maxSequences + 1)
        let refusal = try XCTUnwrap(MPNNJobManager.preflight(request))
        XCTAssertTrue(refusal.error?.contains("n_sequences") == true, refusal.error ?? "")
    }

    func testAWellFormedRequestPassesPreflight() throws {
        let request = try writeRequest(job: "mpnn-ok",
                                       backbonePath: try writeBackbone("bb5"))
        // Only when the pack ships with the test host; otherwise the one refusal left is
        // the missing pack, which is itself the right answer.
        if MPNNGate.packURL == nil {
            let refusal = try XCTUnwrap(MPNNJobManager.preflight(request))
            XCTAssertTrue(refusal.error?.contains("model pack") == true,
                          refusal.error ?? "")
        } else {
            XCTAssertNil(MPNNJobManager.preflight(request))
        }
    }

    // MARK: Fixed positions cross the gap between two arrays

    /// The wire numbers positions against EVERY enumerated residue; the model sees only
    /// the ones with a complete backbone. A fixed position naming a residue that did not
    /// survive is dropped rather than shifted -- shifting it would hold a different
    /// residue than the user picked.
    func testFixedPositionsAreRemappedOntoTheValidResiduesOnly() throws {
        let path = try writeBackbone("bb-gap", count: 4, invalidAt: 1)
        let backbone = try DesignResidueSet.parse(jsonAt: URL(fileURLWithPath: path))
        XCTAssertEqual(backbone.residues.count, 4)
        XCTAssertEqual(backbone.validResidues.count, 3)
        // Wire 0 -> valid 0; wire 2 -> valid 1; wire 1 is the gap and is dropped.
        XCTAssertEqual(MPNNJobManager.fixedInValidOrder(wire: [0, 2], backbone: backbone),
                       [0, 1])
        XCTAssertEqual(MPNNJobManager.fixedInValidOrder(wire: [1], backbone: backbone),
                       [])
        XCTAssertEqual(MPNNJobManager.fixedInValidOrder(wire: [], backbone: backbone), [])
    }

    // MARK: The result document

    func testTheResultDocumentIsTheShapePythonReads() throws {
        let path = try writeBackbone("bb-doc", count: 4, invalidAt: 2)
        let backbone = try DesignResidueSet.parse(jsonAt: URL(fileURLWithPath: path))
        // Three valid residues; the sample designs ALA, CYS, ASP over them.
        let indices = [0, 1, 2]
        let scores = DesignScores(
            nativeFit: [-0.5, -1.5, nil, -2.5],
            certainty: [0.9, 0.8, nil, 0.7],
            propensities: [nil, nil, nil, nil])
        let document = MPNNJobManager.composeResult(
            backbone: backbone,
            samples: [MPNNJobManager.Sample(number: 1, seed: 11, temperature: 0.2,
                                            indices: indices, scores: scores)],
            elapsed: 1.25)

        XCTAssertEqual(document["designer"] as? String, "mpnn")
        let index = try XCTUnwrap(document["index"] as? [[String]])
        XCTAssertEqual(index, [["A", "1"], ["A", "2"], ["A", "3"], ["A", "4"]])

        let sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
        XCTAssertEqual(sequences.count, 1)
        let sample = sequences[0]
        XCTAssertEqual(sample["n"] as? Int, 1)
        // The chain string covers EVERY residue, with the native letter at the gap, so it
        // is the sequence a later `predict` folds.
        let chains = try XCTUnwrap(sample["chains"] as? [String: String])
        XCTAssertEqual(chains["A"], "ACAD")
        // The arrays are index-aligned and the unscored residue is null, not zero.
        let arrays = try XCTUnwrap(sample["arrays"] as? [String: [Any]])
        let certainty = try XCTUnwrap(arrays["certainty"])
        XCTAssertEqual(certainty.count, 4)
        XCTAssertTrue(certainty[2] is NSNull, "\(certainty)")
        XCTAssertEqual(try XCTUnwrap(arrays["native_fit"])[0] as? Double, -0.5)
        // Recovery counts DESIGNED positions only: 3 designed, of which A at position 0
        // matches the native ALA.
        let scalars = try XCTUnwrap(sample["scalars"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(scalars["sequence_recovery"] as? Double),
                       1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(scalars["mean_certainty"] as? Double),
                       0.8, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(scalars["mean_native_fit"] as? Double),
                       -1.5, accuracy: 1e-6)
        XCTAssertEqual(scalars["temperature"] as? Double, 0.2)
    }

    /// The document has to survive JSONSerialization: `NSNull` in an array is the one
    /// thing that would not, and it is exactly what an unscored residue is written as.
    func testTheResultDocumentSerialises() throws {
        let path = try writeBackbone("bb-ser", count: 2, invalidAt: 0)
        let backbone = try DesignResidueSet.parse(jsonAt: URL(fileURLWithPath: path))
        let document = MPNNJobManager.composeResult(
            backbone: backbone,
            samples: [MPNNJobManager.Sample(
                number: 1, seed: 0, temperature: 0,
                indices: [4],
                scores: DesignScores(nativeFit: [nil, -1.0], certainty: [nil, 0.5],
                                     propensities: [nil, nil]))],
            elapsed: 0.1)
        let data = try JSONSerialization.data(withJSONObject: document)
        let round = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((round["sequences"] as? [[String: Any]])?.count, 1)
    }

    func testAnAlphabetIndexOutsideTheAlphabetReadsAsX() {
        XCTAssertEqual(MPNNJobManager.letter(for: 0), MPNNModel.alphabet[0])
        XCTAssertEqual(MPNNJobManager.letter(for: -1), "X")
        XCTAssertEqual(MPNNJobManager.letter(for: 99), "X")
    }

    // MARK: Recovery counts DESIGNED positions only (#453 review, finding 3)

    /// `MPNNModel.design` returns the NATIVE letter at a fixed position, so counting held
    /// residues as designed scored every one of them as recovered: a 3-of-10 region read
    /// >= 0.7 whatever the model wrote.
    func testHeldPositionsAreOutsideTheRecoveryDenominator() throws {
        let path = try writeBackbone("bb-fixed", count: 4)
        let backbone = try DesignResidueSet.parse(jsonAt: URL(fileURLWithPath: path))
        // Every residue is native ALA (aa 0). The model "designs" ALA at the two held
        // positions (as it must) and CYS at the two free ones — so nothing was recovered.
        let sample = MPNNJobManager.Sample(
            number: 1, seed: 0, temperature: 0.1, indices: [0, 0, 1, 1],
            scores: DesignScores(nativeFit: [nil, nil, nil, nil],
                                 certainty: [nil, nil, nil, nil],
                                 propensities: [nil, nil, nil, nil]))

        let held = MPNNJobManager.composeResult(backbone: backbone, samples: [sample],
                                                fixed: [0, 1], elapsed: 0)
        let scalars = try XCTUnwrap(
            ((held["sequences"] as? [[String: Any]])?[0]["scalars"]) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(scalars["sequence_recovery"] as? Double), 0.0,
                       accuracy: 1e-9)

        // ...and with nothing held, the same sample recovers the two ALAs: 2 of 4.
        let free = MPNNJobManager.composeResult(backbone: backbone, samples: [sample],
                                                fixed: [], elapsed: 0)
        let freeScalars = try XCTUnwrap(
            ((free["sequences"] as? [[String: Any]])?[0]["scalars"]) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(freeScalars["sequence_recovery"] as? Double), 0.5,
                       accuracy: 1e-9)
    }

    /// Holding EVERYTHING leaves no denominator at all, so the column is absent rather
    /// than 1.0 or a division by zero. (`design_sequences` refuses this case on the
    /// Python side; the document must still be well formed if it ever arrives.)
    func testHoldingEverythingLeavesNoRecoveryColumn() throws {
        let path = try writeBackbone("bb-allfixed", count: 2)
        let backbone = try DesignResidueSet.parse(jsonAt: URL(fileURLWithPath: path))
        let document = MPNNJobManager.composeResult(
            backbone: backbone,
            samples: [MPNNJobManager.Sample(
                number: 1, seed: 0, temperature: 0, indices: [0, 0],
                scores: DesignScores(nativeFit: [nil, nil], certainty: [nil, nil],
                                     propensities: [nil, nil]))],
            fixed: [0, 1], elapsed: 0)
        let scalars = try XCTUnwrap(
            ((document["sequences"] as? [[String: Any]])?[0]["scalars"]) as? [String: Any])
        XCTAssertNil(scalars["sequence_recovery"])
    }

    // MARK: run() end to end, on injected inference (#453 review, finding 5)

    /// Install doubles for the two model calls and record what `run` hands them.
    /// `MPNNModel.DesignResult` and `.ScoreResult` are both public inits, so these are
    /// real values rather than mocks.
    private final class Recorder {
        var seeds: [UInt64?] = []
        var fixed: [Set<Int>] = []
        var omits: [[Set<Int>]?] = []
        var temperatures: [Float] = []
        var scoredSequences: [[Int]] = []
    }

    @discardableResult
    private func installDoubles(_ recorder: Recorder, letters: [Int]) -> Recorder {
        MPNNJobManager.shared.designFn = { residues, options in
            recorder.seeds.append(options.seed)
            recorder.fixed.append(options.fixedPositions)
            recorder.omits.append(options.omit)
            recorder.temperatures.append(options.temperature)
            return Array(letters.prefix(residues.count))
        }
        MPNNJobManager.shared.scoreFn = { residues, sequence in
            recorder.scoredSequences.append(sequence)
            return MPNNModel.ScoreResult(
                logProbs: Array(repeating: Array(repeating: Float(-3), count: 21),
                                count: residues.count),
                currentAALogProb: Array(repeating: Float(-1.25), count: residues.count))
        }
        return recorder
    }

    private func status(of request: InferenceJob.Request) throws -> InferenceJob.Status {
        try JSONDecoder().decode(
            InferenceJob.Status.self,
            from: Data(contentsOf: URL(fileURLWithPath: request.statusPath)))
    }

    func testRunWritesADocumentPythonCanRead() throws {
        let recorder = Recorder()
        installDoubles(recorder, letters: [1, 1, 1])
        let request = try writeRequest(job: "mpnn-run",
                                       backbonePath: try writeBackbone("bb-run", count: 3),
                                       nSequences: 3, temperature: 0.4)
        MPNNJobManager.shared.runForTesting(request)

        // A DISTINCT seed per sample, derived from the request's one seed — otherwise
        // every sample of a run is the same draw.
        XCTAssertEqual(recorder.seeds, [11, 12, 13])
        XCTAssertEqual(recorder.temperatures, [0.4, 0.4, 0.4])
        // Scored against the sequence just designed, not against the native one.
        XCTAssertEqual(recorder.scoredSequences, [[1, 1, 1], [1, 1, 1], [1, 1, 1]])

        let done = try status(of: request)
        XCTAssertEqual(done.state, "done")
        XCTAssertEqual(done.resultPath, request.outPath)
        XCTAssertNotNil(done.elapsedSeconds)

        let document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: request.outPath)))
            as? [String: Any])
        XCTAssertEqual(document["designer"] as? String, "mpnn")
        let sequences = try XCTUnwrap(document["sequences"] as? [[String: Any]])
        XCTAssertEqual(sequences.count, 3)
        XCTAssertEqual(sequences.map { $0["n"] as? Int }, [1, 2, 3])
        XCTAssertEqual(sequences.map { $0["seed"] as? UInt64 }, [11, 12, 13])
        // The product is there, on every record — the key `designing_sequences` now
        // refuses a record for lacking.
        for sample in sequences {
            let chains = try XCTUnwrap(sample["chains"] as? [String: String])
            XCTAssertEqual(chains["A"], "CCC")
        }
        let arrays = try XCTUnwrap(sequences[0]["arrays"] as? [String: [Any]])
        XCTAssertEqual(arrays["native_fit"]?.count, 3)
        XCTAssertEqual(arrays["certainty"]?.count, 3)
    }

    /// Wire positions are remapped onto the array the model sees, and the held ones stay
    /// out of the recovery denominator — the two halves of finding 3, through `run`.
    func testRunRemapsFixedPositionsAndHonoursThemInRecovery() throws {
        let recorder = Recorder()
        // Backbone of 4 with a gap at 1, so valid order is wire 0, 2, 3 -> 0, 1, 2.
        // Every residue is native ALA (0). The double writes ALA at the HELD position —
        // as the model does, which is the whole trap — and CYS (1) at the two free ones.
        // Free-only recovery is therefore 0/2; counting the held one would give 1/3.
        installDoubles(recorder, letters: [0, 1, 1])
        let request = try writeRequest(
            job: "mpnn-fixed-run",
            backbonePath: try writeBackbone("bb-fixed-run", count: 4, invalidAt: 1),
            nSequences: 1, fixedPositions: [0, 1])
        MPNNJobManager.shared.runForTesting(request)

        // Wire 0 -> valid 0; wire 1 is the gap and is dropped.
        XCTAssertEqual(recorder.fixed, [[0]])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: request.outPath)))
            as? [String: Any])
        let scalars = try XCTUnwrap(
            ((document["sequences"] as? [[String: Any]])?[0]["scalars"]) as? [String: Any])
        // Neither free position was recovered; the held one is outside the fraction, so
        // this is 0.0 and not the 1/3 that counting it would give.
        XCTAssertEqual(try XCTUnwrap(scalars["sequence_recovery"] as? Double), 0.0,
                       accuracy: 1e-9)
    }

    func testRunTurnsOmitLettersIntoPerPositionAlphabetIndices() throws {
        let recorder = Recorder()
        installDoubles(recorder, letters: [0, 0, 0])
        let request = try writeRequest(job: "mpnn-omit-run",
                                       backbonePath: try writeBackbone("bb-omit", count: 3),
                                       nSequences: 1, omit: "CW")
        MPNNJobManager.shared.runForTesting(request)
        let omit = try XCTUnwrap(recorder.omits.first ?? nil)
        XCTAssertEqual(omit.count, 3)
        let expected = Set(["C", "W"].compactMap { MPNNModel.alphabet.firstIndex(of: Character($0)) })
        XCTAssertEqual(Set(omit), [expected])
    }

    func testRunWithNoOmitSendsNoOmitTable() throws {
        let recorder = Recorder()
        installDoubles(recorder, letters: [0, 0, 0])
        let request = try writeRequest(job: "mpnn-noomit-run",
                                       backbonePath: try writeBackbone("bb-noomit", count: 3),
                                       nSequences: 1)
        MPNNJobManager.shared.runForTesting(request)
        XCTAssertNil(recorder.omits.first ?? nil)
    }

    /// The cancel arm BEFORE any work: a campaign queues one job per backbone on a serial
    /// queue, so most of a thousand sit here and must fall out without reading anything.
    func testACancelBeforeTheJobStartsSettlesWithoutCallingTheModel() throws {
        let recorder = Recorder()
        installDoubles(recorder, letters: [0, 0, 0])
        let request = try writeRequest(job: "mpnn-cancel-run",
                                       backbonePath: try writeBackbone("bb-cancel", count: 3))
        MPNNJobManager.shared.cancel(jobID: request.jobID)
        MPNNJobManager.shared.runForTesting(request)

        XCTAssertTrue(recorder.seeds.isEmpty, "the model ran for a cancelled job")
        let settled = try status(of: request)
        XCTAssertEqual(settled.state, "cancelled")
        XCTAssertEqual(settled.phase, "queued")
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.outPath))
    }

    /// A model that throws settles `failed` with the error TEXT, not the useless
    /// "The operation couldn't be completed" that `localizedDescription` gives an enum.
    func testAModelFailureSettlesFailedWithTheErrorText() throws {
        let boom = NSError(domain: "mpnn.test", code: 7,
                           userInfo: [NSLocalizedDescriptionKey: "no residues"])
        MPNNJobManager.shared.designFn = { _, _ in throw boom }
        MPNNJobManager.shared.scoreFn = { _, _ in
            MPNNModel.ScoreResult(logProbs: [], currentAALogProb: nil)
        }
        let request = try writeRequest(job: "mpnn-throw-run",
                                       backbonePath: try writeBackbone("bb-throw", count: 3))
        MPNNJobManager.shared.runForTesting(request)
        let settled = try status(of: request)
        XCTAssertEqual(settled.state, "failed")
        XCTAssertEqual(settled.error, String(describing: boom))
    }

    /// A backbone whose every residue lacks an atom is refused rather than designed as an
    /// empty sequence — which is what would land as an entry that looks like a result.
    func testABackboneWithNoCompleteResidueIsRefused() throws {
        let recorder = Recorder()
        installDoubles(recorder, letters: [])
        let path = try writeBackbone("bb-empty", count: 1, invalidAt: 0)
        let request = try writeRequest(job: "mpnn-empty-run", backbonePath: path)
        MPNNJobManager.shared.runForTesting(request)
        XCTAssertTrue(recorder.seeds.isEmpty)
        let settled = try status(of: request)
        XCTAssertEqual(settled.state, "failed")
        XCTAssertTrue(settled.error?.contains("N, CA, C and O") == true,
                      settled.error ?? "")
    }
}
#endif
