#if RAYMOL_MPNN
import XCTest
@testable import RayMol   // module name per project.yml product

final class DesignResiduesTests: XCTestCase {
    private func writeJSON(_ s: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try s.write(to: u, atomically: true, encoding: .utf8); return u
    }
    func testParseMapsChainsAndMasksInvalid() throws {
        let json = """
        {"object":"m1","state":1,"residues":[
          {"chain":"A","resi":"1","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[1,0,0],"c":[2,0,0],"o":[3,0,0]},
          {"chain":"A","resi":"2","resn":"GLY","aa":6,"valid":false,"n":null,"ca":[1,1,1],"c":null,"o":null},
          {"chain":"B","resi":"1","resn":"VAL","aa":19,"valid":true,"n":[0,0,1],"ca":[1,0,1],"c":[2,0,1],"o":[3,0,1]}]}
        """
        let set = try DesignResidueSet.parse(jsonAt: writeJSON(json))
        XCTAssertEqual(set.residues.count, 3)
        XCTAssertEqual(set.validResidues.count, 2)               // masked one dropped
        XCTAssertEqual(set.nativeSequence, [0, 19])              // valid residues' aa, in order
        XCTAssertEqual(set.validResidues[0].chain, 0)            // chain A -> 0
        XCTAssertEqual(set.validResidues[1].chain, 1)            // chain B -> 1 (first-seen order)
        XCTAssertEqual(set.validResidues[1].resSeq, 1)
    }
    func testInsertionCodeResSeq() throws {
        let json = """
        {"object":"m1","state":1,"residues":[
          {"chain":"A","resi":"100A","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[1,0,0],"c":[2,0,0],"o":[3,0,0]},
          {"chain":"A","resi":"-5","resn":"GLY","aa":6,"valid":true,"n":[0,0,1],"ca":[1,0,1],"c":[2,0,1],"o":[3,0,1]}]}
        """
        let set = try DesignResidueSet.parse(jsonAt: writeJSON(json))
        XCTAssertEqual(set.validResidues.count, 2)
        XCTAssertEqual(set.validResidues[0].resSeq, 100)    // insertion code stripped
        XCTAssertEqual(set.validResidues[1].resSeq, -5)     // negative resSeq preserved
    }
    func testEmptyChainMapsToValidInt() throws {
        let json = #"{"object":"m1","state":1,"residues":[{"chain":"","resi":"1","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[1,0,0],"c":[2,0,0],"o":[3,0,0]}]}"#
        let set = try DesignResidueSet.parse(jsonAt: writeJSON(json))
        XCTAssertEqual(set.validResidues.count, 1)          // residue is kept
        let _ = set.validResidues[0].chain as Int           // chain is a valid Int (compile-time type check)
        XCTAssertEqual(set.validResidues[0].chain, 0)       // first-seen empty chain -> 0
    }
    func testSequenceHashChangesWithSequence() throws {
        let a = try DesignResidueSet.parse(jsonAt: writeJSON(#"{"object":"m","state":1,"residues":[{"chain":"A","resi":"1","resn":"ALA","aa":0,"valid":true,"n":[0,0,0],"ca":[0,0,0],"c":[0,0,0],"o":[0,0,0]}]}"#))
        let b = try DesignResidueSet.parse(jsonAt: writeJSON(#"{"object":"m","state":1,"residues":[{"chain":"A","resi":"1","resn":"VAL","aa":19,"valid":true,"n":[0,0,0],"ca":[0,0,0],"c":[0,0,0],"o":[0,0,0]}]}"#))
        XCTAssertNotEqual(a.sequenceHash, b.sequenceHash)
    }
}
#endif
