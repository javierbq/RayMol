#if os(macOS) || os(iOS)
import Foundation

/// Whether the Predict tool may be offered on this build, OS, and environment.
///
/// The peer of ``DesignAvailability``, and deliberately a separate type: the two
/// features answer to different constraints. Design's only question is the iOS
/// version; Predict additionally has to refuse the iOS Simulator, and does so for a
/// reason that is not a version at all.
///
/// Three gates, all of which must pass on iOS:
///
/// 1. **Not the Simulator.** MLX cannot run there — its allocator is Metal-backed
///    regardless of the compute device, and `MTLSimDevice` rejects the private-storage
///    heaps it builds (`MLXRuntime.deviceConfigured` documents the exact assertion and
///    the two workarounds that were tried and did not help). A prediction started in
///    the Simulator has no outcome except an abort, so the tool must be absent rather
///    than dead-on-arrival. BoltzMLX is still LINKED for the Simulator so that slice
///    keeps compiling — availability is the runtime gate, not the link.
/// 2. **iOS 18+**, for the same reason `DesignAvailability` uses: mlx-swift's Metal
///    path has only ever been validated on iOS 18 hardware, and SPM will happily
///    resolve against the iOS 17 deployment target boltz-mlx declares.
/// 3. Nothing else. Memory is NOT a gate here — that is ``PredictSizeGuard``'s job,
///    per input, and it is why this type deliberately does not consult
///    `os_proc_available_memory()`. A device-wide "is there enough RAM" answer would
///    be wrong for both a 60-residue peptide and a 900-residue target.
///
/// `PyMOLBridge.mm` applies the SAME rule when it decides whether to export
/// `RAYMOL_PREDICT_HOST`, so the Python half refuses in step with the UI. The two
/// must agree: if this type said yes where the bridge said no, the Predict tool would
/// open onto a form whose every Run reports the predictor unavailable.
enum PredictAvailability {

    enum Platform { case macOS, iOS }

    /// Minimum iOS major version on which Predict is offered. Same floor, same
    /// reasoning, as ``DesignAvailability/minimumIOSMajorVersion`` — but a separate
    /// constant, because raising one of these should not silently raise the other.
    static let minimumIOSMajorVersion = 18

    /// Pure decision. `platform`, `osMajorVersion`, and `isSimulator` are parameters
    /// rather than `#if` branches so the macOS test host can verify the iOS rules; a
    /// compile-time branch would leave the iOS arms permanently untested.
    static func isSupported(platform: Platform, osMajorVersion: Int,
                            isSimulator: Bool) -> Bool {
        switch platform {
        case .macOS:
            return true
        case .iOS:
            return !isSimulator && osMajorVersion >= minimumIOSMajorVersion
        }
    }

    /// The platform this binary was compiled for.
    static var current: Platform {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }

    static var currentOSMajorVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static var currentIsSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// True when the Predict tool should be offered. Callers must not build any
    /// Predict entry point — Tools menu item, docked bar, keyboard path — when this
    /// is false.
    static var isSupported: Bool {
        isSupported(platform: current, osMajorVersion: currentOSMajorVersion,
                    isSimulator: currentIsSimulator)
    }
}
#endif
