#if RAYMOL_MPNN
import Foundation
import MPNNKit
import simd

struct DesignResidue {
    let chain: String; let resi: String; let resn: String; let aa: Int
    let backbone: MPNNModel.Residue?; let valid: Bool
}

struct DesignResidueSet {
    let object: String; let state: Int; let residues: [DesignResidue]

    var validResidues: [MPNNModel.Residue] { residues.compactMap { $0.backbone } }
    var nativeSequence: [Int] { residues.filter { $0.valid }.map { $0.aa } }
    var sequenceHash: Int {
        var h = Hasher(); for r in residues { h.combine(r.aa) }; return h.finalize()
    }

    static func parse(jsonAt url: URL) throws -> DesignResidueSet {
        struct RawRes: Decodable { let chain: String; let resi: String; let resn: String; let aa: Int; let valid: Bool
                                   let n: [Float]?; let ca: [Float]?; let c: [Float]?; let o: [Float]? }
        struct Raw: Decodable { let object: String; let state: Int; let residues: [RawRes] }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(contentsOf: url))
        var chainMap: [String: Int] = [:]; var next = 0
        func chainInt(_ s: String) -> Int { if let i = chainMap[s] { return i }; chainMap[s] = next; next += 1; return next - 1 }
        func vec(_ a: [Float]?) -> SIMD3<Float>? {
            guard let a, a.count >= 3 else { return nil }
            return SIMD3<Float>(a[0], a[1], a[2])
        }
        let residues: [DesignResidue] = raw.residues.map { rr in
            var bb: MPNNModel.Residue? = nil
            if rr.valid, let n = vec(rr.n), let ca = vec(rr.ca), let c = vec(rr.c), let o = vec(rr.o) {
                let resSeq = Int(rr.resi.prefix { $0.isNumber || $0 == "-" }) ?? 0
                bb = MPNNModel.Residue(n: n, ca: ca, c: c, o: o, chain: chainInt(rr.chain), resSeq: resSeq)
            }
            return DesignResidue(chain: rr.chain, resi: rr.resi, resn: rr.resn, aa: rr.aa, backbone: bb, valid: bb != nil)
        }
        return DesignResidueSet(object: raw.object, state: raw.state, residues: residues)
    }
}
#endif
