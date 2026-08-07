#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum MPNNGate {
    /// Bundled pack URL, or nil if missing.
    static var packURL: URL? { Bundle.main.url(forResource: "MPNN", withExtension: "mpnnpack") }
}
#endif
