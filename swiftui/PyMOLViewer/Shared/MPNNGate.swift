#if RAYMOL_MPNN
import Foundation
import MPNNKit

enum MPNNGate {
    /// Bundled pack URL, or nil if missing.
    static var packURL: URL? { Bundle.main.url(forResource: "MPNN", withExtension: "mpnnpack") }
    /// Debug smoke check: pack loads. Not wired to UI.
    static func canLoadModel() -> Bool {
        guard let url = packURL else { return false }
        return (try? MPNNModel(packDirectory: url)) != nil
    }
}
#endif
