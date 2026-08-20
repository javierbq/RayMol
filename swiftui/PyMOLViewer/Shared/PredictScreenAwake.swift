#if os(macOS) || os(iOS)
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Holds the screen awake while on-device work that iOS would otherwise interrupt is in
/// flight — a structure prediction, or the weight download that precedes it.
///
/// **This is not a nicety.** A Boltz fold and a 529 MB weight download are both minutes
/// of foreground-only work with no user input, which is precisely the shape iOS treats as
/// idle. When the display sleeps the app is suspended shortly after; suspension revokes
/// GPU access, and MLX work in flight does not survive it. `swiftui/project.yml` records
/// the observed consequence: no boltz run above ~115 tokens had ever completed on a
/// physical device, because iOS suspended the app mid-run. Nothing in RayMol set
/// `isIdleTimerDisabled` before this type.
///
/// It does **not** make the app background-safe, and cannot: there is no background mode
/// that grants Metal compute. Keeping the screen on removes the OS's own reason to
/// suspend us; a user who switches apps or locks the phone by hand still ends the run,
/// which is what ``PredictBackgroundNotice`` warns about.
///
/// The POLICY compiles on both platforms; only the side effect and the banner are
/// iOS-only. That split is deliberate and copies ``DesignSizeGuard``: the unit-test
/// bundle is a macOS target, so a rule written behind `#if os(iOS)` is a rule that can
/// never be tested. ``apply(_:)`` is inert on macOS, which has no idle-timer concept and
/// does not suspend an app for being quiet.
enum PredictScreenAwake {

    /// Whether the screen should be held awake, from the two job feeds.
    ///
    /// Pure and static so the policy is unit-testable without a `UIApplication` or a
    /// live engine — the side effect below is the only untestable part, and it is one
    /// line.
    ///
    /// A prediction counts while it is not terminal. `isError` already covers error,
    /// failed, AND cancelled, so a job the user cancelled releases the screen
    /// immediately rather than holding it until the card is dismissed. Completed jobs
    /// leave `predictionJobs` entirely, so they need no case here.
    static func shouldStayAwake(predictions: [PredictionJobState],
                                weightsFetching: Bool) -> Bool {
        weightsFetching || predictions.contains { !$0.isError }
    }

    /// Apply the decision. Idempotent — assigning the same value is free, so callers may
    /// drive this from an `.onChange` without tracking the previous state themselves.
    /// A no-op on macOS.
    @MainActor
    static func apply(_ stayAwake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = stayAwake
        #endif
    }
}

#if os(iOS)

/// The banner shown while a fold is running, telling the user the one thing that will
/// lose it.
///
/// Separate from the progress tray on purpose. The tray reports *progress*, and it is
/// shared with weight downloads and `ray` renders — all of which survive being
/// backgrounded. This warns about a constraint that is specific to on-device inference,
/// and it needs to be legible at a glance rather than parsed out of a progress card.
struct PredictBackgroundNotice: View {
    @ObservedObject var engine: PyMOLEngine
    @ObservedObject var theme: ThemeManager

    private var running: Bool {
        PredictScreenAwake.shouldStayAwake(predictions: engine.predictionJobs,
                                           weightsFetching: engine.weightsFetch != nil)
    }

    var body: some View {
        if running {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 11))
                Text("Keep RayMol on screen — switching apps or locking the phone "
                     + "ends the fold.")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
        }
    }
}
#endif
#endif
